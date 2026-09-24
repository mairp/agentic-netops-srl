"""T098 — the mapper stage beyond the naming band: model output validated strictly with one retry,
the site inventory, the declared tagging mode (CR-003, AD-68), the qualification record (FR-097),
one construct per request, exact missing fields, unsupported claims, and the catalogue ConfigMap."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
import yaml

from common.schemas.interpretation import Interpretation
from provisioning.mapper import catalogue as catalogue_mod
from provisioning.mapper import prompts
from provisioning.mapper.agent import Mapper, canonical_port, extract_json
from tests.unit.test_mapper_refusals import FakeLLM, Site, data_of, stage

REPO = Path(__file__).resolve().parents[3]


def raw(kind: str = "mac-vrf", endpoints: list[tuple[str, str, int | None]] | None = None,
        **extra: Any) -> dict[str, Any]:
    eps = endpoints or [("leaf01", "ethernet-1/1", 100), ("leaf02", "ethernet-1/1", 100)]
    body: dict[str, Any] = {
        "service_id": "", "service_type": kind, "tenant": "blue",
        "endpoints": [{"site_or_node": n, "attachment": p, "vlan": v} for n, p, v in eps],
        "missing_fields": [], "unsupported_properties": []}
    if kind == "ip-vrf":
        body["ipv4_prefixes"] = ["10.50.0.0/24"]
    body.update(extra)
    return body


async def interpret(tmp_path: Path, *answers: Any, text: str = "a request",
                    site: Site | None = None) -> tuple[Any, FakeLLM]:
    llm = FakeLLM(*answers)
    mapper = Mapper((site or Site(tmp_path)).settings("mapper"), llm=llm)
    reply = await mapper.handle(stage("map-network-request", {"text": text,
                                                              "operation": "create"}))
    return reply, llm


async def interpretation(tmp_path: Path, *answers: Any, **kw: Any) -> Interpretation:
    reply, _ = await interpret(tmp_path, *answers, **kw)
    return Interpretation.parse(data_of(reply))


def failure(reply: Any) -> str:
    meta = reply.metadata["x-agentic-netops"]
    assert meta["status"] == "error"
    return meta["reason"]


# ---- the model's output ----------------------------------------------------------------------


async def test_schema_invalid_output_gets_exactly_one_retry(tmp_path: Path) -> None:
    reply, llm = await interpret(tmp_path, "not json at all", "```json\n" + json.dumps(raw())
                                 + "\n```")
    interp = Interpretation.parse(data_of(reply))
    assert len(llm.calls) == 2 and interp.unsupported_properties == []
    assert "not a valid Interpretation" in llm.calls[1][-1]["content"]


async def test_schema_invalid_output_twice_fails_naming_it(tmp_path: Path) -> None:
    bad = raw(unknown_field=1)
    reply, llm = await interpret(tmp_path, bad, {**raw(), "service_type": "l2vpn"})
    reason = failure(reply)
    assert reason.startswith("schema-invalid model output (after one retry)")
    assert len(llm.calls) == 2


async def test_the_operator_text_reaches_the_model_only_as_data(tmp_path: Path) -> None:
    text = "extend vlan 100 across leaf01 ethernet-1/1 and leaf02 ethernet-1/1 for tenant blue"
    _, llm = await interpret(tmp_path, raw(), text=text)
    system, user = llm.calls[0]
    assert system["role"] == "system" and text not in system["content"]
    assert user["content"].startswith('<data source="operator">') and text in user["content"]
    assert "leaf01: ethernet-1/1, ethernet-1/2, ethernet-1/3" in system["content"]
    assert "spine01" not in system["content"]


def test_json_is_extracted_from_prose_and_fences() -> None:
    assert extract_json('Sure:\n```json\n{"a": {"b": 1}}\n```') == {"a": {"b": 1}}
    with pytest.raises(ValueError):
        extract_json("no object here")


async def test_a_model_failure_is_a_terminal_failure(tmp_path: Path) -> None:
    class Broken:
        def complete(self, messages: list[dict[str, Any]]) -> Any:
            raise RuntimeError("the llm-provider Secret no longer carries BASE_URL")

    mapper = Mapper(Site(tmp_path).settings("mapper"), llm=Broken())
    reason = failure(await mapper.handle(stage("map-network-request", {"text": "x"})))
    assert reason.startswith("model call failed") and "BASE_URL" in reason


async def test_only_create_is_the_mappers(tmp_path: Path) -> None:
    _, llm = await interpret(tmp_path, raw())
    mapper = Mapper(Site(tmp_path).settings("mapper"), llm=llm)
    assert "not the mapper's" in failure(await mapper.handle(
        stage("map-network-request", {"text": "x", "operation": "remove"})))
    assert "text" in failure(await mapper.handle(stage("map-network-request", {"text": " "})))


# ---- the site inventory ----------------------------------------------------------------------


async def test_unknown_node_is_refused_enumerating_the_attachment_nodes(tmp_path: Path) -> None:
    interp = await interpretation(tmp_path, raw(endpoints=[("leaf09", "ethernet-1/1", 100),
                                                          ("leaf02", "ethernet-1/1", 100)]))
    assert interp.unsupported_properties == [
        "endpoints[0].site_or_node: 'leaf09' is not a node of this site; its attachment nodes "
        "are leaf01, leaf02"]


async def test_a_spine_is_never_an_attachment_point(tmp_path: Path) -> None:
    interp = await interpretation(tmp_path, raw(endpoints=[("spine01", "ethernet-1/1", 100),
                                                          ("leaf02", "ethernet-1/1", 100)]))
    assert interp.unsupported_properties[0].startswith(
        "endpoints[0].site_or_node: spine01 is a spine, and spines are not attachment points")
    assert "leaf01, leaf02" in interp.unsupported_properties[0]


async def test_unknown_port_is_refused_enumerating_the_nodes_ports(tmp_path: Path) -> None:
    interp = await interpretation(tmp_path, raw(endpoints=[("leaf01", "ethernet-9/9", 100),
                                                          ("leaf02", "ethernet-1/1", 100)]))
    assert interp.unsupported_properties == [
        "endpoints[0].attachment: leaf01 has no access port 'ethernet-9/9'; its access ports are "
        "ethernet-1/1, ethernet-1/2, ethernet-1/3"]


async def test_names_are_folded_to_the_devices_own(tmp_path: Path) -> None:
    interp = await interpretation(tmp_path, raw(endpoints=[("LEAF01", "Ethernet1/2", 100),
                                                          ("leaf02", "e1-1", 100)]))
    assert interp.unsupported_properties == []
    assert [(e.site_or_node, e.attachment) for e in interp.endpoints] == [
        ("leaf01", "ethernet-1/2"), ("leaf02", "ethernet-1/1")]
    assert canonical_port("eth-1/49") == "ethernet-1/49"


# ---- the declared tagging mode (CR-003, AD-68) -----------------------------------------------


async def test_a_tagged_endpoint_on_an_untagged_port_lists_the_tagged_ports(
        tmp_path: Path) -> None:
    interp = await interpretation(tmp_path, raw(endpoints=[("leaf01", "ethernet-1/3", 100),
                                                          ("leaf02", "ethernet-1/1", 100)]))
    assert interp.unsupported_properties == [
        "endpoints[0]: leaf01 ethernet-1/3 is declared untagged, and a mac-vrf attachment naming "
        "a VLAN is tagged; the ports declared tagged on leaf01 are ethernet-1/1, ethernet-1/2"]


async def test_an_untagged_ipvrf_endpoint_on_a_tagged_port_lists_the_untagged_ports(
        tmp_path: Path) -> None:
    interp = await interpretation(tmp_path, raw("ip-vrf", endpoints=[
        ("leaf01", "ethernet-1/1", None), ("leaf02", "ethernet-1/2", None)]))
    assert interp.unsupported_properties == [
        "endpoints[0]: leaf01 ethernet-1/1 is declared tagged, and an ip-vrf endpoint naming no "
        "VLAN asks for the untagged subinterface; the ports declared untagged on leaf01 are "
        "ethernet-1/3 — or name a VLAN from the naming band 100\u2013999",
        "endpoints[1]: leaf02 ethernet-1/2 is declared tagged, and an ip-vrf endpoint naming no "
        "VLAN asks for the untagged subinterface; the ports declared untagged on leaf02 are "
        "none — or name a VLAN from the naming band 100\u2013999"]


async def test_a_vlan_to_be_allocated_is_tagged_too(tmp_path: Path) -> None:
    interp = await interpretation(tmp_path, raw("vlan", endpoints=[
        ("leaf01", "ethernet-1/3", None)]))
    assert "is declared untagged" in interp.unsupported_properties[0]


# ---- the qualification record (FR-097) -------------------------------------------------------


async def test_an_unqualified_property_is_refused_by_name(tmp_path: Path) -> None:
    site = Site(tmp_path, unqualified=["acl.egress", "mac-vrf.anycast-gateway-ipv6"])
    body = raw(endpoints=[("leaf01", "ethernet-1/1", 100)],
               anycast_gateway={"ipv6": "2001:db8::1/64"},
               acl={"stage": "egress", "type": "ipv4",
                    "rules": [{"name": "r", "priority": 10, "action": "deny"}]})
    interp = await interpretation(tmp_path, body, site=site,
                                  text="a mac-vrf with gateway 2001:db8::1/64 and an egress acl")
    assert interp.unsupported_properties == [
        "anycast_gateway.ipv6: the IPv6 anycast gateway is not shown as qualified in the fabric "
        "qualification record (mac-vrf.anycast-gateway-ipv6), which records it as 'unqualified'; "
        "it is refused before anything is claimed",
        "acl.stage: an egress access-list binding is not shown as qualified in the fabric "
        "qualification record (acl.egress), which records it as 'unqualified'; it is refused "
        "before anything is claimed"]


async def test_a_construct_the_record_does_not_carry_is_refused(tmp_path: Path) -> None:
    site = Site(tmp_path, qualified=["vlan"])
    interp = await interpretation(tmp_path, raw(), site=site)
    assert interp.unsupported_properties == [
        "service_type: the mac-vrf construct is not shown as qualified in the fabric "
        "qualification record (mac-vrf), which does not record it; it is refused before "
        "anything is claimed"]


async def test_the_record_is_read_from_qualification_json_too(tmp_path: Path) -> None:
    site = Site(tmp_path, qualified=[])
    (site.qualification / "qualification.json").write_text(json.dumps({"constructs": {
        "mac-vrf": {"qualified": True, "properties": {}}}}))
    interp = await interpretation(tmp_path, raw(), site=site)
    assert interp.unsupported_properties == []


# ---- one construct, unsupported claims, missing fields ---------------------------------------


async def test_two_constructs_in_one_request_are_refused_naming_both(tmp_path: Path) -> None:
    body = raw(unsupported_properties=[
        "request: one construct per request - you asked for a MAC VRF and an IP-VRF"])
    interp = await interpretation(tmp_path, body)
    assert interp.unsupported_properties == [
        "request: one construct per request — you asked for mac-vrf and ip-vrf; send one"]


async def test_an_unsupported_claim_in_the_request_is_named(tmp_path: Path) -> None:
    interp = await interpretation(
        tmp_path, raw(), text="extend vlan 100 as a mac-vrf with traffic engineering")
    assert interp.unsupported_properties[0].startswith("traffic engineering: not supported")
    assert interp.missing_fields == []


async def test_missing_fields_are_asked_for_by_exact_path_never_defaulted(
        tmp_path: Path) -> None:
    body = raw(endpoints=[("leaf01", "ethernet-1/1", 100)], tenant="unknown")
    interp = await interpretation(tmp_path, body)
    assert interp.unsupported_properties == []
    assert interp.missing_fields == ["tenant", "endpoints[1]"]


async def test_a_placeholder_endpoint_is_asked_for_not_validated(tmp_path: Path) -> None:
    body = raw("ip-vrf", endpoints=[("unknown", "unknown", None)],
               missing_fields=["endpoints[0].site_or_node", "endpoints[0].attachment"])
    interp = await interpretation(tmp_path, body)
    assert interp.unsupported_properties == []
    assert interp.missing_fields == ["endpoints[0].site_or_node", "endpoints[0].attachment"]


async def test_ipvrf_without_prefixes_asks_for_them(tmp_path: Path) -> None:
    body = raw("ip-vrf", endpoints=[("leaf01", "ethernet-1/1", 200)], ipv4_prefixes=[])
    interp = await interpretation(tmp_path, body)
    assert interp.missing_fields == ["ipv4_prefixes or ipv6_prefixes"]


async def test_a_refusal_wins_over_a_clarification(tmp_path: Path) -> None:
    body = raw(endpoints=[("leaf01", "ethernet-1/1", 1500)], tenant="unknown")
    interp = await interpretation(tmp_path, body)
    assert interp.unsupported_properties and interp.missing_fields == []


async def test_two_named_vlans_on_one_bridge_domain_are_refused(tmp_path: Path) -> None:
    interp = await interpretation(tmp_path, raw(endpoints=[("leaf01", "ethernet-1/1", 100),
                                                          ("leaf02", "ethernet-1/1", 200)]))
    assert interp.unsupported_properties == [
        "endpoints[].vlan: the request names VLANs 100 and 200; a mac-vrf is one broadcast "
        "domain, so every endpoint shares one VLAN"]


async def test_a_migration_alias_is_folded(tmp_path: Path) -> None:
    interp = await interpretation(tmp_path, raw("ip-vrf", source_service_type="VPLS"))
    assert interp.service_type == "mac-vrf" and interp.source_service_type == "VPLS"


async def test_the_reply_carries_the_marker_and_the_data_part(tmp_path: Path) -> None:
    reply, _ = await interpret(tmp_path, raw())
    data = data_of(reply)
    text = next(p.root.text for p in reply.parts if hasattr(p.root, "text"))
    assert f"Interpretation {data['service_id']}: a mac-vrf for tenant blue" in text
    assert "<!-- MAPPED_JSON: " in text


# ---- the catalogue ---------------------------------------------------------------------------


def test_the_packaged_catalogue_equals_the_configmap() -> None:
    doc = yaml.safe_load((REPO / "deploy/agents/mapper-catalogue.yaml").read_text())
    assert doc["kind"] == "ConfigMap" and doc["metadata"]["name"] == "mapper-catalogue"
    assert list(doc["data"]) == [catalogue_mod.CATALOGUE_KEY]
    assert doc["data"][catalogue_mod.CATALOGUE_KEY] == catalogue_mod.PACKAGED.read_text()


def test_the_catalogue_is_the_four_constructs_and_folds_their_names() -> None:
    cat = catalogue_mod.load(None)
    assert [c["name"] for c in cat.constructs] == ["vlan", "mac-vrf", "ip-vrf", "acl"]
    assert cat.fold("MAC VRF") == ("mac-vrf", None)
    assert cat.fold("ip_vrf") == ("ip-vrf", None)
    assert cat.fold("E-LINE") == ("mac-vrf", "VPWS")
    assert cat.fold("srv6") is None
    text = prompts.instructions(cat, None)
    for c in ("vlan", "mac-vrf", "ip-vrf", "acl"):
        assert f"- {c}: " in text


def test_a_mounted_catalogue_is_read_and_a_widening_one_refused(tmp_path: Path) -> None:
    mounted = json.loads(catalogue_mod.PACKAGED.read_text())
    mounted["constructs"][0]["examples"] = ["mounted example"]
    (tmp_path / "catalogue.json").write_text(json.dumps(mounted))
    assert catalogue_mod.load(tmp_path).constructs[0]["examples"] == ["mounted example"]
    mounted["constructs"].append({"name": "srv6"})
    (tmp_path / "catalogue.json").write_text(json.dumps(mounted))
    with pytest.raises(catalogue_mod.CatalogueError, match="exactly the four constructs"):
        catalogue_mod.load(tmp_path)


async def test_an_unreadable_site_inventory_fails_the_stage(tmp_path: Path) -> None:
    site = Site(tmp_path)
    (site.inventory / "inventory.json").unlink()
    reply, llm = await interpret(tmp_path, raw(), site=site)
    assert failure(reply).startswith("site inventory unreadable") and llm.calls == []
