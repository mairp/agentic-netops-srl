"""T111 — the mapper's access-list review (contracts/construct-vocabulary.md §3.1 §5,
acl-render-contract.md §2 §3; FR-035 to FR-041, FR-097; AD-47).

An ``acl`` rides optionally on any construct and is required on ``service_type: acl``. Every
refusal names the offending rule by its path; a priority outside ``1-65534`` states the evaluation
order and the usable range; a Layer 2 list is refused as out of scope (never "the device lacks
it"); an egress list is refused by name when the qualification record does not show
``acl.egress`` qualified; the VLAN an ``acl`` endpoint names is a reference, exempt from the
naming band and held to ``100-4000``. A refusal reaches no allocator and makes no claim.
"""

from __future__ import annotations

import copy
from pathlib import Path
from typing import Any

import pytest

from common.schemas.interpretation import Interpretation
from provisioning.mapper import acl as acl_mod
from tests.unit.test_mapper_refusals import FakeLLM, Pipeline, Site
from tests.unit.test_mapper_stage import interpretation, raw

RULES = [
    {"name": "allow-https", "priority": 100, "action": "permit", "protocol": "tcp",
     "source_prefix": "10.0.0.0/24", "destination_port": "443"},
    {"name": "deny-telnet", "priority": 200, "action": "deny", "protocol": "tcp",
     "destination_port": "23"},
]


def acl(**overrides: Any) -> dict[str, Any]:
    body: dict[str, Any] = {"stage": "ingress", "type": "ipv4", "rules": copy.deepcopy(RULES)}
    body.update(overrides)
    return body


def standalone(vlan: int | None = 310, **acl_overrides: Any) -> dict[str, Any]:
    return raw("acl", endpoints=[("leaf01", "ethernet-1/1", vlan)], acl=acl(**acl_overrides))


def on_macvrf(**acl_overrides: Any) -> dict[str, Any]:
    return raw("mac-vrf", acl=acl(**acl_overrides))


async def causes(tmp_path: Path, body: dict[str, Any], **kw: Any) -> list[str]:
    interp = await interpretation(tmp_path, body, **kw)
    assert interp.missing_fields == []
    return interp.unsupported_properties


# ---- accepted -------------------------------------------------------------------------------


@pytest.mark.parametrize("build", [standalone, on_macvrf], ids=["standalone", "on-mac-vrf"])
async def test_a_well_formed_list_is_accepted_on_any_construct(tmp_path: Path, build: Any
                                                               ) -> None:
    interp = await interpretation(tmp_path, build())
    assert interp.unsupported_properties == [] and interp.missing_fields == []
    assert interp.acl is not None
    assert [r.priority for r in interp.acl.rules] == [100, 200]
    assert interp.acl.evaluation_order == "ascending-first-match"
    assert interp.acl.unmatched_traffic == "accept-platform-default"


@pytest.mark.parametrize(("default", "unmatched"), [("deny", "deny"), ("permit", "permit"),
                                                    (None, "accept-platform-default")])
async def test_unmatched_traffic_follows_the_declared_default_never_the_model(
        tmp_path: Path, default: str | None, unmatched: str) -> None:
    # the model claims the opposite; the platform sets it from the default action
    body = standalone(default_action=default, unmatched_traffic="deny" if default is None
                      else "accept-platform-default")
    text = ("an ingress acl on leaf01 ethernet-1/1 vlan 310 for tenant blue"
            + (f" and {default} the rest" if default else ""))
    interp = await interpretation(tmp_path, body, text=text)
    assert interp.unsupported_properties == []
    assert interp.acl is not None and interp.acl.unmatched_traffic == unmatched


@pytest.mark.parametrize("text", [
    "an ipv6 ingress acl permitting tcp 22 on leaf01 ethernet-1/1 vlan 310; "
    "nothing else is filtered",
    "an ingress acl on leaf01 ethernet-1/1 vlan 310 that permits https",
])
async def test_a_default_action_the_operator_did_not_state_is_dropped(tmp_path: Path, text: str
                                                                      ) -> None:
    # T144 live finding: "nothing else is filtered" came back as a declared permit default
    interp = await interpretation(tmp_path, standalone(default_action="permit"), text=text)
    assert interp.acl is not None and interp.acl.default_action is None
    assert interp.acl.unmatched_traffic == "accept-platform-default"


@pytest.mark.parametrize("text", ["deny the rest", "drop everything else",
                                  "denies all other traffic", "everything else is dropped",
                                  "default deny", "block all", "otherwise drop"])
def test_default_written_reads_the_operators_forms(text: str) -> None:
    from provisioning.mapper.agent import default_written
    assert default_written(
        f"an ingress acl on leaf01 ethernet-1/1 vlan 310 that permits tcp 22, {text}")


@pytest.mark.parametrize(("rules", "family"), [
    ([{"action": "permit", "protocol": "tcp", "source_prefix": "192.168.10.0/24",
       "destination_port": "22"}], "ipv4"),
    ([{"action": "deny", "protocol": "udp", "source_prefix": "2001:db8::/48"}], "ipv6"),
    ([{"action": "permit", "protocol": "icmpv6"}], "ipv6"),
])
def test_an_unstated_family_is_the_family_the_request_states(rules: list[dict[str, Any]],
                                                              family: str) -> None:
    # T144 live finding: acl.type 'unknown' refused a list whose prefix states its family
    data: dict[str, Any] = {"acl": {"type": "unknown", "stage": "ingress", "rules": rules}}
    assert acl_mod.prepare(data) == []
    assert data["acl"]["type"] == family and "acl.type" not in (data.get("missing_fields") or [])


def test_a_family_nothing_states_is_asked_for() -> None:
    data: dict[str, Any] = {"acl": {"type": None, "stage": "ingress",
                                    "rules": [{"action": "permit", "protocol": "tcp",
                                               "destination_port": "443"}]}}
    assert acl_mod.prepare(data) == []
    assert "acl.type" in data["missing_fields"]


def test_any_port_and_any_prefix_placeholders_are_absent() -> None:
    # T144 live finding: ports "0" and prefixes "::/0" on an icmpv6 rule with no stated port
    data: dict[str, Any] = {"acl": {"type": "ipv6", "rules": [{
        "action": "permit", "protocol": "icmpv6", "source_prefix": "::/0",
        "destination_prefix": "::/0", "source_port": "0", "destination_port": 0}]}}
    assert acl_mod.prepare(data) == []
    assert not {"source_prefix", "destination_prefix", "source_port",
                "destination_port"} & data["acl"]["rules"][0].keys()


@pytest.mark.parametrize("prefix", ["0::/0", "0.0.0.0/0", "::/0", " 0:0::/0 ", "0.0.0.0/00"])
def test_every_zero_length_prefix_is_absent(prefix: str) -> None:
    # T151 r9 live finding: '0::/0' as the destination of a rule the operator gave none
    data: dict[str, Any] = {"acl": {"type": "ipv6", "stage": "ingress", "rules": [{
        "action": "permit", "protocol": "tcp", "source_prefix": "2001:db8:100::/48",
        "destination_prefix": prefix, "destination_port": "22"}]}}
    assert acl_mod.prepare(data) == []
    rule = data["acl"]["rules"][0]
    assert "destination_prefix" not in rule and rule["source_prefix"] == "2001:db8:100::/48"


def test_a_non_zero_prefix_is_kept() -> None:
    data: dict[str, Any] = {"acl": {"type": "ipv4", "stage": "ingress", "rules": [{
        "action": "deny", "protocol": "udp", "destination_prefix": "10.0.0.0/8"}]}}
    acl_mod.prepare(data)
    assert data["acl"]["rules"][0]["destination_prefix"] == "10.0.0.0/8"


def test_a_derived_label_names_only_what_the_rule_states() -> None:
    # T151 r9 live finding: 'deny-udp-10-0-9-0-24-unknown-unknown-unknown' — the label was built
    # from the model's placeholders before they were removed
    data: dict[str, Any] = {"acl": {"type": "ipv4", "stage": "ingress", "rules": [{
        "action": "deny", "protocol": "udp", "source_prefix": "10.0.9.0/24",
        "source_port": "unknown", "destination_prefix": "0.0.0.0/0",
        "destination_port": "161"}]}}
    acl_mod.prepare(data)
    assert data["acl"]["rules"][0]["name"] == "deny-udp-10-0-9-0-24-161"


def test_the_prompt_reads_a_number_after_the_protocol_as_the_destination_port() -> None:
    from provisioning.mapper import prompts
    assert '"udp 161"' in prompts.RULES and "destination_port" in prompts.RULES.split("9.")[-1]


@pytest.mark.parametrize("rule", [
    {"action": "deny", "protocol": "mac", "source_prefix": "00:11:22:33:44:55"},
    {"action": "deny", "protocol": "any", "source_mac": "00:11:22:33:44:55"},
])
def test_a_layer2_match_is_refused_by_name(rule: dict[str, Any]) -> None:
    # T144 live finding: a MAC acl failed schema validation instead of being refused by name
    data = standalone(type="ipv4", rules=[{"name": "a", "priority": 10, **rule}])
    found = acl_mod.prepare(data)
    assert any("Layer 2" in c for c in found)
    Interpretation.parse({**data, "service_id": "abc"})


@pytest.mark.parametrize(("spelling", "family"), [("l3", "ipv4"), ("ip", "ipv4"),
                                                  ("IPv4", "ipv4"), ("l3v6", "ipv6"),
                                                  ("ipv6", "ipv6"), ("L3V6", "ipv6")])
async def test_operator_type_spellings_fold_to_the_two_families(
        tmp_path: Path, spelling: str, family: str) -> None:
    rules = [{"name": "any", "priority": 10, "action": "permit"}]
    interp = await interpretation(tmp_path, standalone(type=spelling, rules=rules))
    assert interp.unsupported_properties == []
    assert interp.acl is not None and interp.acl.type == family


async def test_icmpv6_is_accepted_and_folded_to_the_devices_spelling(tmp_path: Path) -> None:
    rules = [{"name": "nd", "priority": 10, "action": "permit", "protocol": "icmpv6",
              "source_prefix": "2001:db8::/64"}]
    interp = await interpretation(tmp_path, standalone(type="ipv6", rules=rules))
    assert interp.unsupported_properties == []
    assert interp.acl is not None and interp.acl.rules[0].protocol == "icmp6"


# ---- refused, naming the rule ---------------------------------------------------------------


async def test_a_duplicate_priority_is_refused_naming_both_rules(tmp_path: Path) -> None:
    rules = [*RULES, {"name": "deny-ssh", "priority": 100, "action": "deny",
                      "protocol": "tcp", "destination_port": "22"}]
    found = await causes(tmp_path, standalone(rules=rules))
    assert len(found) == 1, found
    assert found[0].startswith("acl.rules[2].priority: 100 is already the priority of rule "
                               "'allow-https' (acl.rules[0]); priorities must be distinct")
    assert "ascending priority number, first match wins" in found[0]


async def test_a_duplicate_rule_name_is_refused_naming_the_rule(tmp_path: Path) -> None:
    rules = [*RULES, {"name": "allow-https", "priority": 300, "action": "permit"}]
    assert await causes(tmp_path, standalone(rules=rules)) == [
        "acl.rules[2].name: rule 'allow-https' is named twice (acl.rules[0] and this one); "
        "rule names must be distinct within one list"]


@pytest.mark.parametrize("priority", [0, 65535, 65536, 70000])
async def test_a_priority_outside_the_usable_range_states_the_order_and_the_range(
        tmp_path: Path, priority: int) -> None:
    rules = [RULES[0], {"name": "late", "priority": priority, "action": "deny"}]
    pipeline = Pipeline(Site(tmp_path), FakeLLM(standalone(rules=rules)))
    interp, assignment = await pipeline.run("an acl")
    assert len(pipeline.mapper.llm().calls) == 1  # no schema retry: the mapper answers
    found = interp.unsupported_properties
    assert len(found) == 1, found
    assert found[0].startswith(f"acl.rules[1].priority: {priority} ")
    assert "rules are evaluated in ascending priority number, first match wins" in found[0]
    assert "1\u201365534" in found[0]
    if priority == 65535:
        assert "reserved" in found[0] and "default action" in found[0]
    assert assignment is None and pipeline.allocator_calls == []
    assert pipeline.kube.creates() == 0


@pytest.mark.parametrize(("field", "prefix", "family"), [
    ("source_prefix", "2001:db8::/64", "ipv6"), ("destination_prefix", "10.1.0.0/16", "ipv4")])
async def test_a_prefix_in_the_other_family_is_refused_naming_the_rule(
        tmp_path: Path, field: str, prefix: str, family: str) -> None:
    list_type = "ipv4" if family == "ipv6" else "ipv6"
    rules = [{"name": "r", "priority": 10, "action": "deny", field: prefix}]
    found = await causes(tmp_path, standalone(type=list_type, rules=rules))
    assert found == [f"acl.rules[0].{field}: {prefix} is an {family} prefix in an {list_type} "
                     "access list; a prefix must be in the list's own address family, or the "
                     "entry would be programmed and never match"]


@pytest.mark.parametrize("protocol", ["icmp", "sctp", 1, None])
async def test_an_l4_port_on_anything_but_tcp_or_udp_is_refused(
        tmp_path: Path, protocol: Any) -> None:
    rule: dict[str, Any] = {"name": "odd", "priority": 10, "action": "deny",
                            "destination_port": "80"}
    if protocol is not None:
        rule["protocol"] = protocol
    found = await causes(tmp_path, standalone(rules=[rule]))
    assert len(found) == 1 and found[0].startswith(
        "acl.rules[0].destination_port: a port match needs protocol tcp or udp")
    assert "'odd'" in found[0]


@pytest.mark.parametrize("protocol", ["tcp", "udp", 6, 17])
async def test_an_l4_port_on_tcp_or_udp_is_accepted(tmp_path: Path, protocol: Any) -> None:
    rules = [{"name": "p", "priority": 10, "action": "permit", "protocol": protocol,
              "source_port": "1024-65535", "destination_port": "53"}]
    assert await causes(tmp_path, standalone(rules=rules)) == []


async def test_a_port_that_is_no_port_is_refused(tmp_path: Path) -> None:
    rules = [{"name": "p", "priority": 10, "action": "permit", "protocol": "tcp",
              "destination_port": "99999"}]
    assert await causes(tmp_path, standalone(rules=rules)) == [
        "acl.rules[0].destination_port: '99999' is not a port: ports are 0\u201365535"]


@pytest.mark.parametrize("spelling", ["mac", "MAC", "l2"])
async def test_a_layer2_list_is_refused_as_out_of_scope_not_as_a_device_gap(
        tmp_path: Path, spelling: str) -> None:
    rules = [{"name": "r", "priority": 10, "action": "deny"}]
    pipeline = Pipeline(Site(tmp_path), FakeLLM(standalone(type=spelling, rules=rules)))
    interp, assignment = await pipeline.run("a mac acl")
    assert len(pipeline.mapper.llm().calls) == 1
    (cause,) = interp.unsupported_properties
    assert cause.startswith(f"acl.type: a Layer 2 ({spelling}) access list is out of this "
                            "platform's declared scope")
    lowered = cause.lower()
    for device_gap in ("lack", "does not support", "doesn't support", "not supported by the "
                       "device", "cannot", "unavailable"):
        assert device_gap not in lowered, cause
    assert assignment is None and pipeline.kube.creates() == 0


async def test_an_unknown_family_is_refused_listing_the_families(tmp_path: Path) -> None:
    rules = [{"name": "r", "priority": 10, "action": "deny"}]
    assert await causes(tmp_path, standalone(type="ipx", rules=rules)) == [
        "acl.type: 'ipx' is not an address family this construct carries; an access list is "
        "ipv4 or ipv6 (l3 and ip fold to ipv4, l3v6 to ipv6)"]


@pytest.mark.parametrize("name", ["system", "capture", "System"])
async def test_the_reserved_list_names_are_refused(tmp_path: Path, name: str) -> None:
    found = await causes(tmp_path, standalone(name=name))
    assert found == [f"acl.name: '{name}' is reserved on this platform for the device's own "
                     "system and packet-capture filters; name the list anything else"]


async def test_every_cause_is_collected_at_once(tmp_path: Path) -> None:
    rules = [{"name": "a", "priority": 10, "action": "deny", "source_prefix": "2001:db8::/64"},
             {"name": "a", "priority": 10, "action": "deny", "protocol": "icmp",
              "destination_port": "80"}]
    found = await causes(tmp_path, standalone(rules=rules))
    assert [c.split(":")[0] for c in found] == [
        "acl.rules[0].source_prefix", "acl.rules[1].priority", "acl.rules[1].name",
        "acl.rules[1].destination_port"]


# ---- the qualification record: egress by name (FR-097) --------------------------------------


@pytest.mark.parametrize("record", [["unqualified"], []], ids=["unqualified", "absent"])
async def test_egress_is_refused_by_name_when_the_record_does_not_show_it(
        tmp_path: Path, record: list[str]) -> None:
    qualified = ["vlan", "mac-vrf", "acl", "acl.ingress-ipv4"]
    site = Site(tmp_path, qualified=qualified,
                unqualified=["acl.egress"] if record else [])
    pipeline = Pipeline(site, FakeLLM(on_macvrf(stage="egress")))
    interp, assignment = await pipeline.run("a mac-vrf with an egress acl")
    (cause,) = interp.unsupported_properties
    assert cause.startswith("acl.stage: an egress access-list binding is not shown as "
                            "qualified in the fabric qualification record (acl.egress)")
    assert assignment is None and pipeline.kube.creates() == 0


async def test_egress_is_accepted_when_the_record_shows_it(tmp_path: Path) -> None:
    interp = await interpretation(tmp_path, standalone(stage="egress"))
    assert interp.unsupported_properties == []


# ---- the acl endpoint's VLAN: a reference, 100-4000 (AD-47) ---------------------------------


@pytest.mark.parametrize("vlan", [100, 310, 999, 1000, 1500, 4000])
async def test_an_acl_endpoint_vlan_is_a_reference_anywhere_in_100_to_4000(
        tmp_path: Path, vlan: int) -> None:
    pipeline = Pipeline(Site(tmp_path), FakeLLM(standalone(vlan=vlan)))
    interp, assignment = await pipeline.run("an acl on leaf02 ethernet-1/1")
    assert interp.unsupported_properties == []
    assert assignment is not None and assignment["endpoints"][0]["vlan"] == vlan
    assert pipeline.kube.creates() == 0  # a standalone acl claims nothing


@pytest.mark.parametrize("vlan", [0, 50, 99, 4001, 4094, 4095, 5000])
async def test_an_acl_endpoint_vlan_outside_100_to_4000_is_refused_stating_both_bands(
        tmp_path: Path, vlan: int) -> None:
    pipeline = Pipeline(Site(tmp_path), FakeLLM(standalone(vlan=vlan)))
    interp, assignment = await pipeline.run("an acl")
    (cause,) = interp.unsupported_properties
    assert cause.startswith(f"endpoints[0].vlan: {vlan} lies outside the VLAN space "
                            "100\u20134000")
    assert "100\u2013999" in cause and "1000\u20134000" in cause
    assert assignment is None and pipeline.kube.creates() == 0


async def test_an_acl_endpoint_naming_no_vlan_is_the_untagged_subinterface(
        tmp_path: Path) -> None:
    interp = await interpretation(tmp_path, standalone(vlan=None))
    assert interp.unsupported_properties == [] and interp.endpoints[0].vlan is None


# ---- the pre-schema pass in isolation --------------------------------------------------------


def test_prepare_leaves_a_schema_valid_refusal() -> None:
    data = standalone(type="mac", rules=[{"name": "a", "priority": 65534, "action": "deny"},
                                         {"name": "b", "priority": 65535, "action": "deny"}])
    found = acl_mod.prepare(data)
    assert len(found) == 2 and data["unsupported_properties"] == found
    # stand-ins in range and unused, so the refused interpretation still validates
    assert data["acl"]["rules"][1]["priority"] == 65533
    Interpretation.parse({**data, "service_id": "abc"})


def test_fold_type_is_the_contract_table() -> None:
    assert {s: acl_mod.fold_type(s) for s in ("l3", "ip", "ipv4", "l3v6", "ipv6", "mac")} == {
        "l3": "ipv4", "ip": "ipv4", "ipv4": "ipv4", "l3v6": "ipv6", "ipv6": "ipv6", "mac": None}


@pytest.mark.parametrize("placeholder", ["unknown", "any", "N/A", "", "not stated"])
def test_a_placeholder_for_an_unstated_match_field_is_absent(placeholder: str) -> None:
    # T114 live finding: the model wrote 'unknown' for the prefix and ports of an icmpv6 rule.
    data: dict[str, Any] = {"acl": {"type": "ipv6", "rules": [{
        "name": "allow-nd", "priority": 10, "action": "permit", "protocol": "icmpv6",
        "source_prefix": "2001:db8:310::/64", "destination_prefix": placeholder,
        "source_port": placeholder, "destination_port": placeholder}]}}
    assert acl_mod.prepare(data) == []
    rule = data["acl"]["rules"][0]
    assert rule["source_prefix"] == "2001:db8:310::/64"
    assert not {"destination_prefix", "source_port", "destination_port"} & rule.keys()


async def test_an_unstated_match_field_the_model_lists_as_missing_is_no_question(
        tmp_path: Path) -> None:
    # T114 live finding: the model listed the unstated prefixes/ports of the rules as missing.
    body = standalone(rules=[{"name": "nd", "priority": 10, "action": "permit",
                              "protocol": "icmp"}])
    body["missing_fields"] = ["acl.rules[0].destination_prefix", "acl.rules[0].source_port",
                              "acl.rules[0].source_prefix", "acl.rules[0].destination_port"]
    interp = await interpretation(tmp_path, body)
    assert interp.missing_fields == [] and interp.unsupported_properties == []


async def test_a_genuinely_missing_field_beside_them_is_still_asked_for(tmp_path: Path) -> None:
    body = standalone()
    body["missing_fields"] = ["acl.rules[0].destination_prefix", "tenant"]
    interp = await interpretation(tmp_path, body)
    assert interp.missing_fields == ["tenant"]


async def test_a_stated_family_the_model_lists_as_missing_is_no_question(tmp_path: Path) -> None:
    # T153 §11e: the prompt wrote an IPv4 prefix; the model still listed acl.type as missing.
    body = standalone(rules=[{"name": "web", "priority": 10, "action": "permit", "protocol": "tcp",
                              "source_prefix": "10.0.0.0/24", "destination_port": "443"}])
    body["acl"].pop("type", None)
    body["missing_fields"] = ["acl.type"]
    interp = await interpretation(tmp_path, body)
    assert interp.missing_fields == []
