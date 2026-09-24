"""T091, the mapper's half — the naming band is the mapper's (contracts/kuid-claim-profiles.md §2
rule 1; construct-vocabulary.md §5; data-model.md §8; FR-028, FR-033, FR-034, FR-062, CR-003,
SC-015; AD-33, AD-41, AD-47, AD-51, AD-56, AD-61).

T115/T117, the gateway's interpretation half (FR-032, FR-097, CR-002, CR-010; AD-58): a ``mac-vrf``
whose gateway declares IPv6, against a qualification record that does not show
``mac-vrf.anycast-gateway-ipv6`` qualified, is refused at interpretation naming that property, the
allocator never reached and nothing claimed — and accepted with one L2VNI and one L3VNI claim when
the record qualifies it; only the gateway families the operator wrote survive interpretation, and
the gateway stays a property of ``mac-vrf`` in the catalogue, never a construct of its own.

Each fixture under ``testdata/interpretation/`` holds the model's raw interpretation output and the
expected outcome. A ``vlan``, ``mac-vrf`` or ``ip-vrf`` interpretation naming a VLAN in
``1000-4000``, below ``100``, in ``4001-4094`` or beyond (``4095``, ``5000``) passes schema
validation — the schema floors a VLAN at 0 and has no upper bound, so that the mapper and not the
schema answers — and is refused at interpretation stating both bands and that ``1000-4000`` is the
allocation authority's to hand out; the allocator stage is never reached and no claim is made.
"""

from __future__ import annotations

import ipaddress
import json
import re
from pathlib import Path
from typing import Any

import pytest
from pydantic import ValidationError

import common.transport as t
from common.schemas.interpretation import Interpretation
from config.settings import load_settings
from provisioning.allocator.agent import Allocator
from provisioning.mapper import catalogue as catalogue_mod
from provisioning.mapper import prompts
from provisioning.mapper.agent import Mapper, generate_service_id, written_addresses
from tests.unit.test_allocator_fakes import FakeKube

FIXTURES = Path(__file__).parent / "testdata" / "interpretation"
CID = "0af7651916cd43dd8448eb211c80319c"
HEX15 = re.compile(r"^[0-9a-f]{15}$")
INVENTORY = {
    "fabricASN": 65000,
    "nodes": [
        {"name": "leaf01", "role": "leaf",
         "accessPorts": ["ethernet-1/1", "ethernet-1/2", "ethernet-1/3"],
         "untaggedAccessPorts": ["ethernet-1/3"]},
        {"name": "leaf02", "role": "leaf", "accessPorts": ["ethernet-1/1", "ethernet-1/2"],
         "untaggedAccessPorts": []},
        {"name": "spine01", "role": "spine", "accessPorts": [], "untaggedAccessPorts": []},
    ],
}
QUALIFIED = ["vlan", "vlan.bridged-subinterface", "mac-vrf", "mac-vrf.anycast-gateway-ipv4",
             "mac-vrf.anycast-gateway-ipv6", "ip-vrf", "ip-vrf.evpn-type5-ipv4",
             "ip-vrf.evpn-type5-ipv6", "acl", "acl.ingress-ipv4", "acl.ingress-ipv6",
             "acl.egress"]


def fixture(name: str) -> dict[str, Any]:
    return json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))


REFUSE = sorted(p.stem for p in FIXTURES.glob("refuse_vlan_named_*.json"))
REFUSE_CASES = [(name, construct, vlan) for name in REFUSE
                for construct in ("vlan", "mac-vrf", "ip-vrf")
                for vlan in fixture(name)["vlans"]]


class FakeLLM:
    """Answers every model call with the next scripted text (the last one repeats)."""

    def __init__(self, *answers: str | dict[str, Any]) -> None:
        self.answers = [a if isinstance(a, str) else json.dumps(a) for a in answers]
        self.calls: list[list[dict[str, Any]]] = []

    def complete(self, messages: list[dict[str, Any]]) -> dict[str, Any]:
        self.calls.append(messages)
        text = self.answers[min(len(self.calls), len(self.answers)) - 1]
        return {"choices": [{"message": {"role": "assistant", "content": text}}]}


class Site:
    def __init__(self, root: Path, inventory: dict[str, Any] | None = None,
                 qualified: list[str] | None = None, unqualified: list[str] = ()) -> None:
        self.inventory = root / "site-inventory"
        self.qualification = root / "fabric-qualification"
        self.inventory.mkdir(exist_ok=True)
        self.qualification.mkdir(exist_ok=True)
        (self.inventory / "inventory.json").write_text(json.dumps(inventory or INVENTORY))
        for key in QUALIFIED if qualified is None else qualified:
            (self.qualification / key).write_text("qualified")
        for key in unqualified:
            (self.qualification / key).write_text("unqualified")

    def settings(self, component: str) -> Any:
        return load_settings({"AGENT_COMPONENT": component,
                              "SITE_INVENTORY_DIR": str(self.inventory),
                              "FABRIC_QUALIFICATION_DIR": str(self.qualification),
                              "MAPPER_CATALOGUE_DIR": str(self.inventory.parent / "no-catalogue")})


def stage(skill: str, payload: dict[str, Any]) -> t.StageMessage:
    return t.StageMessage(kind="stage", skill=skill, correlation_id=CID, thread_id="thread-1",
                          idempotency_key=None, operation=payload.get("operation", "create"),
                          data=payload, text="")


def data_of(reply: t.Message) -> dict[str, Any]:
    meta = reply.metadata["x-agentic-netops"]
    assert meta["status"] == "ok", meta.get("reason")
    return next(p.root.data for p in reply.parts if isinstance(p.root, t.DataPart))


class Pipeline:
    """The supervisor's routing rule between the two stages, with a spy on the allocator:
    a refusal or a clarification ends the request; only an interpretation reaches allocation."""

    def __init__(self, site: Site, llm: FakeLLM) -> None:
        self.kube = FakeKube()
        self.mapper = Mapper(site.settings("mapper"), llm=llm)
        self.allocator = Allocator(site.settings("allocator"), adapter=self.kube.adapter())
        self.allocator_calls: list[t.StageMessage] = []

    async def run(self, text: str) -> tuple[Interpretation, dict[str, Any] | None]:
        reply = await self.mapper.handle(stage("map-network-request",
                                               {"text": text, "operation": "create"}))
        wire = data_of(reply)
        interp = Interpretation.parse(wire)  # what the supervisor validates: it passes
        if interp.unsupported_properties or interp.missing_fields:
            return interp, None
        request = stage("allocate-network-service",
                        {"operation": "create", "interpretation": wire})
        self.allocator_calls.append(request)
        return interp, data_of(await self.allocator.handle(request))


def model_output(fx: dict[str, Any], construct: str, vlan: int | None) -> dict[str, Any]:
    out = json.loads(json.dumps(fx["model_output"][construct]))
    for ep in out["endpoints"]:
        ep["vlan"] = vlan
    return out


# --------------------------------------------------------------------------------------------------
# the naming band (AD-41)
# --------------------------------------------------------------------------------------------------


@pytest.mark.parametrize(("name", "construct", "vlan"), REFUSE_CASES)
async def test_a_named_vlan_outside_the_naming_band_is_refused_at_interpretation(
        tmp_path: Path, name: str, construct: str, vlan: int) -> None:
    fx = fixture(name)
    raw = model_output(fx, construct, vlan)
    # the schema lets it through: the mapper, not schema validation, answers (AD-61)
    Interpretation.parse({**raw, "service_id": "abc"})
    pipeline = Pipeline(Site(tmp_path), FakeLLM(raw))
    interp, assignment = await pipeline.run(fx["request_text"][construct].format(v=vlan))
    assert len(pipeline.mapper.llm().calls) == 1  # valid on the first answer: no retry
    causes = [c for c in interp.unsupported_properties if c.startswith("endpoints[0].vlan: ")]
    assert causes, interp.unsupported_properties
    for needle in fx["expect"]["cause_contains"]:
        assert needle in causes[0], (needle, causes[0])
    assert f": {vlan} " in causes[0]
    assert interp.missing_fields == []
    # the allocator stage is never reached and nothing is claimed
    assert assignment is None and pipeline.allocator_calls == []
    assert pipeline.kube.requests == [] and pipeline.kube.creates() == 0


@pytest.mark.parametrize("construct", ["vlan", "mac-vrf", "ip-vrf"])
@pytest.mark.parametrize("vlan", [100, 555, 999])
async def test_a_named_vlan_in_the_naming_band_is_accepted_and_never_claimed(
        tmp_path: Path, construct: str, vlan: int) -> None:
    fx = fixture("refuse_vlan_named_in_allocation_band")
    pipeline = Pipeline(Site(tmp_path), FakeLLM(model_output(fx, construct, vlan)))
    interp, assignment = await pipeline.run(fx["request_text"][construct].format(v=vlan))
    assert interp.unsupported_properties == [] and interp.missing_fields == []
    assert assignment is not None and {e["vlan"] for e in assignment["endpoints"]} == {vlan}
    assert pipeline.kube.vlan_claims() == []


async def test_ipvrf_untagged_no_vlan_is_accepted_and_allocates_no_vlan(tmp_path: Path) -> None:
    fx = fixture("accept_ipvrf_untagged_no_vlan")
    pipeline = Pipeline(Site(tmp_path), FakeLLM(fx["model_output"]))
    interp, assignment = await pipeline.run(fx["request_text"])
    assert interp.unsupported_properties == []
    assert interp.missing_fields == fx["expect"]["missing_fields"] == []
    assert interp.endpoints[0].vlan is None
    assert assignment is not None and "vlan" not in assignment["endpoints"][0]
    assert len(pipeline.kube.vlan_claims()) == fx["expect"]["vlan_claims_created"] == 0
    assert len(pipeline.kube.vni_claims()) == fx["expect"]["l3vni_claims_created"] == 1


async def test_a_standalone_acl_naming_an_allocated_vlan_is_accepted(tmp_path: Path) -> None:
    fx = fixture("accept_acl_references_allocated_vlan")
    pipeline = Pipeline(Site(tmp_path), FakeLLM(fx["model_output"]))
    interp, assignment = await pipeline.run(fx["request_text"])
    assert interp.unsupported_properties == [] and interp.missing_fields == []
    assert [e.vlan for e in interp.endpoints] == fx["expect"]["endpoint_vlans"] == [1500]
    assert assignment is not None and assignment["endpoints"][0]["vlan"] == 1500
    assert pipeline.kube.creates() == fx["expect"]["claims_created"] == 0


# --------------------------------------------------------------------------------------------------
# the service identifier (AD-56, AD-61)
# --------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("bad", ["Abc", "a" * 16, "a.b", "", "-ab", "ab-", "a_b", "ÄBC"])
def test_a_service_id_that_is_not_a_short_dns_label_fails_the_schema(bad: str) -> None:
    fx = fixture("accept_ipvrf_untagged_no_vlan")
    with pytest.raises(ValidationError, match="service_id"):
        Interpretation.parse({**fx["model_output"], "service_id": bad})


def test_a_short_dns_label_passes_the_schema() -> None:
    fx = fixture("accept_ipvrf_untagged_no_vlan")
    for good in ("a", "a1-b2", "a" * 15, generate_service_id()):
        Interpretation.parse({**fx["model_output"], "service_id": good})


def test_the_generated_identifier_is_15_hex_characters_over_many_runs() -> None:
    ids = {generate_service_id() for _ in range(2000)}
    assert len(ids) == 2000
    assert all(HEX15.match(i) for i in ids)


@pytest.mark.parametrize("tenant", ["blue", "acme-prod", "t" + "x" * 61 + "z",
                                    "abc", "deadbeef"])
async def test_the_mapper_generates_the_identifier_whatever_the_model_and_tenant_say(
        tmp_path: Path, tenant: str) -> None:
    fx = fixture("accept_ipvrf_untagged_no_vlan")
    raw = {**fx["model_output"], "tenant": tenant, "service_id": tenant[:15]}
    site = Site(tmp_path)
    seen = set()
    for _ in range(25):
        mapper = Mapper(site.settings("mapper"), llm=FakeLLM(raw))
        reply = await mapper.handle(stage("map-network-request", {"text": "x"}))
        interp = Interpretation.parse(data_of(reply))
        assert interp.tenant == tenant
        assert HEX15.match(interp.service_id), interp.service_id
        assert interp.service_id != tenant[:15]
        if len(tenant) > 15 or not re.fullmatch(r"[0-9a-f]+", tenant):
            assert tenant not in interp.service_id
        seen.add(interp.service_id)
    assert len(seen) == 25  # random, not a function of the request
    assert len(tenant) != 63 or len(interp.service_id) == 15


# --------------------------------------------------------------------------------------------------
# the anycast gateway, a property of mac-vrf (T115, T117; FR-032, FR-097, CR-002, CR-010; AD-58)
# --------------------------------------------------------------------------------------------------


def l3vni_claims(kube: FakeKube) -> list[dict[str, Any]]:
    return [o for o in kube.vni_claims() if ".l3vni-" in o["metadata"]["name"]]


def l2vni_claims(kube: FakeKube) -> list[dict[str, Any]]:
    return [o for o in kube.vni_claims() if ".l2vni-" in o["metadata"]["name"]]


def gateway_site(root: Path, fx: dict[str, Any], *, qualify_ipv6: bool) -> Site:
    record = fx["qualification"]
    if qualify_ipv6:
        return Site(root, qualified=record["qualified"] + record["unqualified"])
    return Site(root, qualified=record["qualified"], unqualified=record["unqualified"])


async def test_an_unqualified_ipv6_gateway_is_refused_before_anything_is_claimed(
        tmp_path: Path) -> None:
    fx = fixture("refuse_gateway_ipv6_unqualified")
    expect = fx["expect"]
    assert expect["outcome"] == "refuse"
    pipeline = Pipeline(gateway_site(tmp_path, fx, qualify_ipv6=False), FakeLLM(fx["model_output"]))
    interp, assignment = await pipeline.run(fx["request_text"])
    (cause,) = interp.unsupported_properties  # the IPv6 family alone: IPv4 is qualified
    assert cause.startswith(f"{expect['property']}: ")
    assert expect["qualification_key"] in cause
    for needle in expect["cause_contains"]:
        assert needle in cause, (needle, cause)
    assert interp.missing_fields == expect["missing_fields"] == []
    # refused at interpretation: the allocator stage is never reached, nothing is claimed (AD-58)
    assert assignment is None
    assert len(pipeline.allocator_calls) == expect["allocator_calls"] == 0
    assert pipeline.kube.requests == []
    assert pipeline.kube.creates() == expect["claims_created"] == 0


async def test_the_same_gateway_is_accepted_when_the_record_qualifies_ipv6(tmp_path: Path) -> None:
    fx = fixture("refuse_gateway_ipv6_unqualified")
    control = fx["negative_control"]
    pipeline = Pipeline(gateway_site(tmp_path, fx, qualify_ipv6=True), FakeLLM(fx["model_output"]))
    interp, assignment = await pipeline.run(fx["request_text"])
    assert control["outcome"] == "accept"
    assert interp.unsupported_properties == [] and interp.missing_fields == []
    assert interp.service_type == "mac-vrf" and interp.anycast_gateway is not None
    assert assignment is not None and len(pipeline.allocator_calls) == 1
    kube = pipeline.kube
    assert len(kube.vlan_claims()) == control["vlan_claims_created"] == 0  # VLAN 130 is named
    assert len(l2vni_claims(kube)) == control["l2vni_claims_created"] == 1
    assert len(l3vni_claims(kube)) == control["l3vni_claims_created"] == 1
    assert assignment["anycastGateway"] == control["anycast_gateway"]
    assert {e["vlan"] for e in assignment["endpoints"]} == {130}


def macvrf_gateway(ipv4: str | None, ipv6: str | None) -> dict[str, Any]:
    out = json.loads(json.dumps(fixture("refuse_gateway_ipv6_unqualified")["model_output"]))
    out["anycast_gateway"] = {"ipv4": ipv4, "ipv6": ipv6}
    return out


async def test_an_unrequested_gateway_family_is_never_added(tmp_path: Path) -> None:
    # the operator wrote an IPv4 gateway only; the model added an IPv6 one: it is dropped, so it
    # is neither refused (the record leaves IPv6 unqualified) nor configured (FR-032)
    site = Site(tmp_path, unqualified=["mac-vrf.anycast-gateway-ipv6"],
                qualified=[k for k in QUALIFIED if k != "mac-vrf.anycast-gateway-ipv6"])
    pipeline = Pipeline(site, FakeLLM(macvrf_gateway("10.31.0.1/24", "2001:db8:31::1/64")))
    interp, assignment = await pipeline.run(
        "a mac-vrf for tenant acme on leaf01 ethernet-1/1 and leaf02 ethernet-1/1 vlan 131 "
        "with anycast gateway 10.31.0.1/24.")
    assert interp.unsupported_properties == [] and interp.missing_fields == []
    assert interp.anycast_gateway is not None
    assert interp.anycast_gateway.ipv4 == "10.31.0.1/24" and interp.anycast_gateway.ipv6 is None
    assert assignment is not None
    assert assignment["anycastGateway"] == {"gatewayIPv4": "10.31.0.1/24"}
    assert len(l3vni_claims(pipeline.kube)) == 1


@pytest.mark.parametrize("written", ["2001:DB8:30::1/64", "2001:db8:30:0:0:0:0:1/64",
                                     "2001:0db8:0030::0001"])
async def test_an_ipv6_gateway_address_is_compared_by_value(tmp_path: Path, written: str) -> None:
    interp, _ = await Pipeline(Site(tmp_path), FakeLLM(macvrf_gateway(None, "2001:db8:30::1/64"))
                               ).run(f"mac-vrf acme leaf01/leaf02 e1/1 vlan 130, gateway {written}")
    assert interp.unsupported_properties == [] and interp.missing_fields == []
    assert interp.anycast_gateway is not None
    assert interp.anycast_gateway.ipv6 == "2001:db8:30::1/64"


async def test_a_gateway_asked_for_without_an_address_is_a_missing_field(tmp_path: Path) -> None:
    pipeline = Pipeline(Site(tmp_path), FakeLLM(macvrf_gateway("10.30.0.1/24", None)))
    interp, assignment = await pipeline.run(
        "a mac-vrf with an anycast gateway on leaf01 ethernet-1/1 and leaf02 ethernet-1/1 "
        "vlan 130 for tenant acme")
    assert interp.unsupported_properties == []
    assert interp.missing_fields == ["anycast_gateway.ipv4 or anycast_gateway.ipv6"]
    assert assignment is None and pipeline.kube.creates() == 0


async def test_a_gateway_the_request_never_mentions_is_removed(tmp_path: Path) -> None:
    # no gateway asked for: no routed instance and no L3 identifier (kuid-claim-profiles.md §2)
    pipeline = Pipeline(Site(tmp_path), FakeLLM(macvrf_gateway("10.32.0.1/24", None)))
    interp, assignment = await pipeline.run(
        "extend vlan 132 as a mac-vrf across leaf01 ethernet-1/1 and leaf02 ethernet-1/1 "
        "for tenant acme")
    assert interp.unsupported_properties == [] and interp.missing_fields == []
    assert interp.anycast_gateway is None and interp.service_type == "mac-vrf"
    assert assignment is not None
    assert "anycastGateway" not in assignment and "l3vni" not in assignment
    assert l3vni_claims(pipeline.kube) == [] and len(l2vni_claims(pipeline.kube)) == 1


def test_written_addresses_normalise_both_families() -> None:
    found = written_addresses("gw 10.30.0.1/24, and 2001:DB8:30:0::1/64. leaf01 ethernet-1/1 ::1.")
    assert found == {ipaddress.ip_address("10.30.0.1"), ipaddress.ip_address("2001:db8:30::1"),
                     ipaddress.ip_address("::1")}


# ---- the catalogue: the gateway is a property of mac-vrf, never a construct -------------------


def test_the_catalogue_describes_the_gateway_as_a_property_of_macvrf_only() -> None:
    cat = catalogue_mod.load(None)
    gateway = cat.gateway()
    assert gateway["belongs_to"] == "mac-vrf"
    assert "unrequested family is never added" in gateway["declared_families_only"]
    assert "no routed instance and no L3 identifier" in gateway["absent"]
    assert cat.gateway_families() == {"ipv4": "mac-vrf.anycast-gateway-ipv4",
                                      "ipv6": "mac-vrf.anycast-gateway-ipv6"}
    assert cat.gateway_qualification_key("ipv6") == "mac-vrf.anycast-gateway-ipv6"
    for c in cat.constructs:
        if c["name"] != "mac-vrf":
            assert "anycast_gateway" not in (c.get("properties") or {})


def test_the_catalogue_advertises_no_gateway_or_irb_construct() -> None:
    cat = catalogue_mod.load(None)
    names = [c["name"] for c in cat.constructs]
    assert names == ["vlan", "mac-vrf", "ip-vrf", "acl"]
    assert not [n for n in names if re.search(r"irb|l2l3|gateway", n)]
    # the IRB spellings are input-only aliases that fold onto mac-vrf, never a type of their own
    for spelling in ("IRB", "L2L3-IRB", "l2l3 irb"):
        assert cat.fold(spelling) == ("mac-vrf", "L2L3-IRB")
    assert cat.fold("gateway") is None and cat.fold("anycast-gateway") is None
    text = prompts.instructions(cat, None)
    assert not re.search(r"^- (?:irb|l2l3|gateway|anycast)", text, re.MULTILINE)


@pytest.mark.parametrize("breakage", ["on-ipvrf", "absent", "wrong-key"])
def test_a_catalogue_that_moves_or_misnames_the_gateway_is_refused(breakage: str) -> None:
    raw = json.loads(catalogue_mod.PACKAGED.read_text(encoding="utf-8"))
    macvrf, ipvrf = raw["constructs"][1], raw["constructs"][2]
    if breakage == "on-ipvrf":
        ipvrf["properties"] = {"anycast_gateway": macvrf["properties"]["anycast_gateway"]}
    elif breakage == "absent":
        del macvrf["properties"]
    else:
        macvrf["properties"]["anycast_gateway"]["families"]["ipv6"] = "mac-vrf.gw6"
    with pytest.raises(catalogue_mod.CatalogueError, match="anycast_gateway"):
        catalogue_mod.parse(json.dumps(raw), source="test")
