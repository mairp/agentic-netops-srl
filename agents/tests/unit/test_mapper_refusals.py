"""T091, the mapper's half — the naming band is the mapper's (contracts/kuid-claim-profiles.md §2
rule 1; construct-vocabulary.md §5; data-model.md §8; FR-028, FR-033, FR-034, FR-062, CR-003,
SC-015; AD-33, AD-41, AD-47, AD-51, AD-56, AD-61).

Each fixture under ``testdata/interpretation/`` holds the model's raw interpretation output and the
expected outcome. A ``vlan``, ``mac-vrf`` or ``ip-vrf`` interpretation naming a VLAN in
``1000-4000``, below ``100``, in ``4001-4094`` or beyond (``4095``, ``5000``) passes schema
validation — the schema floors a VLAN at 0 and has no upper bound, so that the mapper and not the
schema answers — and is refused at interpretation stating both bands and that ``1000-4000`` is the
allocation authority's to hand out; the allocator stage is never reached and no claim is made.
"""

from __future__ import annotations

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
from provisioning.mapper.agent import Mapper, generate_service_id
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
