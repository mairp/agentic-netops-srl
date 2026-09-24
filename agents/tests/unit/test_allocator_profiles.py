"""T093 — the allocator's claim profiles (contracts/kuid-claim-profiles.md §2-§5; FR-056, FR-060,
FR-062, FR-063, FR-075, FR-109; AD-16, AD-32, AD-33, AD-42, AD-51).

Every test runs against a fake Kubernetes API (``test_allocator_fakes.FakeKube``) with the pool
arbitration of the allocation authority, for **both** authorities the adapter serves — first-party
``identifierclaims`` and kuid ``vlanclaims``/``genidclaims``.
"""

from __future__ import annotations

import asyncio
import json
import random
import re
from pathlib import Path
from typing import Any

import pytest

import common.transport as t
from common.schemas.interpretation import Interpretation
from common.schemas.normalized_service_intent import NormalizedServiceIntent
from config.settings import load_settings
from provisioning.allocator import profiles
from provisioning.allocator.agent import Allocator
from provisioning.allocator.kuid_adapter import FIRST_PARTY, KUID, VNI, AuthorityConfig
from tests.unit.test_allocator_fakes import FakeKube

SID = "4b7e19c2a05d3f6"
CID = "0af7651916cd43dd8448eb211c80319c"
OTHER_CID = "4bf92f3577b34da6a3ce929d0e0e4736"
ASN = 65000
CLAIM_NAME = re.compile(
    r"^agentic-netops-intent\.migr-(?P<sid>[0-9a-z-]{1,15})\."
    r"(?P<role>vlan-(?:vlan|bd)-(?P=sid)|l2vni-bd-(?P=sid)|l3vni-vrf-(?P=sid))$")


def interpretation(kind: str, *, vlan: int | None = None, sid: str = SID, gateway: bool = False,
                   endpoints: int = 2, **extra: Any) -> dict[str, Any]:
    eps = []
    for i in range(endpoints):
        ep: dict[str, Any] = {"site_or_node": f"leaf0{i + 1}", "attachment": "ethernet-1/1"}
        if vlan is not None:
            ep["vlan"] = vlan
        eps.append(ep)
    body: dict[str, Any] = {"service_id": sid, "service_type": kind, "tenant": "blue",
                            "endpoints": eps}
    if gateway:
        body["anycast_gateway"] = {"ipv4": "10.10.0.1/24"}
    if kind == "ip-vrf":
        body["ipv4_prefixes"] = ["10.50.0.0/24"]
    if kind == "acl":
        body["acl"] = {"stage": "ingress", "type": "ipv4", "default_action": "deny",
                       "rules": [{"name": "https", "priority": 100, "action": "permit",
                                  "protocol": "tcp", "destination_port": "443"}]}
    body.update(extra)
    return body


@pytest.fixture(params=[FIRST_PARTY, KUID])
def kube(request: pytest.FixtureRequest) -> FakeKube:
    return FakeKube(authority=request.param)


@pytest.fixture
def inventory_dir(tmp_path: Path) -> Path:
    d = tmp_path / "site-inventory"
    d.mkdir()
    (d / "inventory.json").write_text(json.dumps({
        "fabricASN": ASN,
        "nodes": [{"name": "leaf01", "role": "leaf", "accessPorts": ["ethernet-1/1"],
                   "untaggedAccessPorts": []},
                  {"name": "leaf02", "role": "leaf", "accessPorts": ["ethernet-1/1"],
                   "untaggedAccessPorts": []}]}))
    return d


def allocator(kube: FakeKube, inventory_dir: Path, sleeps: list[float] | None = None,
              **adapter_kwargs: Any) -> Allocator:
    settings = load_settings({"AGENT_COMPONENT": "allocator",
                              "SITE_INVENTORY_DIR": str(inventory_dir),
                              "ALLOCATION_AUTHORITY": kube.authority})
    return Allocator(settings, adapter=kube.adapter(sleeps, **adapter_kwargs))


def stage(payload: dict[str, Any], cid: str | None = CID) -> t.StageMessage:
    return t.StageMessage(kind="stage", skill="allocate-network-service", correlation_id=cid,
                          thread_id="thread-1", idempotency_key=None,
                          operation=payload.get("operation", "create"), data=payload, text="")


def data_of(reply: t.Message) -> dict[str, Any]:
    meta = reply.metadata["x-agentic-netops"]
    assert meta["status"] == "ok", meta.get("reason")
    parts = [p.root for p in reply.parts if isinstance(p.root, t.DataPart)]
    assert len(parts) == 1
    return parts[0].data


def failure(reply: t.Message) -> str:
    meta = reply.metadata["x-agentic-netops"]
    assert meta["status"] == "error", "expected a terminal failure"
    return meta["reason"]


async def create(alloc: Allocator, interp: dict[str, Any], cid: str = CID) -> t.Message:
    return await alloc.handle(stage({"operation": "create", "interpretation": interp}, cid))


def assert_claims_well_formed(kube: FakeKube, sid: str = SID, cid: str = CID) -> None:
    """Labels in metadata.labels, the one naming scheme, against the translator's entry names."""
    entries = profiles.entry_names(sid)
    for obj in kube.claims():
        meta = obj["metadata"]
        assert meta["labels"] == {"agentic-netops.io/correlation-id": cid,
                                  "agentic-netops.io/tier": "intent"}
        assert "labels" not in obj["spec"] and "selector" not in obj["spec"]  # AD-32
        m = CLAIM_NAME.match(meta["name"])
        assert m, meta["name"]
        role = m["role"]
        entry = role.split("-", 1)[1]
        assert entry in entries.values()
        if kube.pool_of(obj) == "fabric01-vlan":
            assert role.startswith("vlan-") and entry in (entries["vlans"],
                                                          entries["bridgeDomains"])
        else:
            assert role in (f"l2vni-{entries['bridgeDomains']}", f"l3vni-{entries['routers']}")
        if kube.authority == FIRST_PARTY:
            assert obj["apiVersion"] == "fabric.agentic-netops.io/v1alpha1"
            assert obj["kind"] == "IdentifierClaim" and "requested" not in obj["spec"]
        else:
            assert obj["kind"] in ("VLANClaim", "GENIDClaim") and "id" not in obj["spec"]


# --------------------------------------------------------------------------------------------------
# §2 profiles
# --------------------------------------------------------------------------------------------------


async def test_vlan_claims_a_vlan_only(kube: FakeKube, inventory_dir: Path) -> None:
    out = data_of(await create(allocator(kube, inventory_dir), interpretation("vlan")))
    assert [o["metadata"]["name"] for o in kube.claims()] == [
        f"agentic-netops-intent.migr-{SID}.vlan-vlan-{SID}"]
    assert kube.vni_claims() == []
    vlan = out["endpoints"][0]["vlan"]
    assert 1000 <= vlan <= 4000 and {e["vlan"] for e in out["endpoints"]} == {vlan}
    assert "routeTargets" not in out and "l2vni" not in out and "l3vni" not in out
    assert_claims_well_formed(kube)


async def test_vlan_with_a_named_vlan_claims_nothing_and_succeeds(kube: FakeKube,
                                                                   inventory_dir: Path) -> None:
    out = data_of(await create(allocator(kube, inventory_dir), interpretation("vlan", vlan=120)))
    assert kube.claims() == [] and kube.creates() == 0
    assert [e["vlan"] for e in out["endpoints"]] == [120, 120]


async def test_macvrf_claims_vlan_and_l2vni(kube: FakeKube, inventory_dir: Path) -> None:
    out = data_of(await create(allocator(kube, inventory_dir), interpretation("mac-vrf")))
    names = sorted(o["metadata"]["name"] for o in kube.claims())
    assert names == sorted([f"agentic-netops-intent.migr-{SID}.vlan-bd-{SID}",
                            f"agentic-netops-intent.migr-{SID}.l2vni-bd-{SID}"])
    assert 10000 <= out["l2vni"] <= 20000 and "l3vni" not in out
    target = f"target:65000:{out['l2vni']}"
    assert out["routeTargets"] == {"importRT": [target], "exportRT": [target]}
    assert 1000 <= out["endpoints"][0]["vlan"] <= 4000
    assert_claims_well_formed(kube)


async def test_macvrf_with_a_named_vlan_claims_only_the_l2vni(kube: FakeKube,
                                                              inventory_dir: Path) -> None:
    out = data_of(await create(allocator(kube, inventory_dir), interpretation("mac-vrf", vlan=100)))
    assert kube.vlan_claims() == []
    assert [o["metadata"]["name"] for o in kube.claims()] == [
        f"agentic-netops-intent.migr-{SID}.l2vni-bd-{SID}"]
    assert [e["vlan"] for e in out["endpoints"]] == [100, 100]


async def test_macvrf_with_a_gateway_also_claims_the_l3vni(kube: FakeKube,
                                                           inventory_dir: Path) -> None:
    out = data_of(await create(allocator(kube, inventory_dir),
                               interpretation("mac-vrf", vlan=100, gateway=True, endpoints=1)))
    assert sorted(o["metadata"]["name"] for o in kube.claims()) == sorted([
        f"agentic-netops-intent.migr-{SID}.l2vni-bd-{SID}",
        f"agentic-netops-intent.migr-{SID}.l3vni-vrf-{SID}"])
    assert out["l3vni"] != out["l2vni"]
    assert out["anycastGateway"] == {"gatewayIPv4": "10.10.0.1/24"}
    assert out["routeTargets"]["importRT"] == [f"target:65000:{out['l2vni']}"]
    assert_claims_well_formed(kube)


# ---- the gateway, a property of mac-vrf: the L3VNI only with a declared gateway (T117) ---------


def l3vni_claims(kube: FakeKube) -> list[dict[str, Any]]:
    return [o for o in kube.vni_claims() if ".l3vni-" in o["metadata"]["name"]]


@pytest.mark.parametrize("vlan", [None, 130])
async def test_a_gatewayless_macvrf_claims_no_l3_identifier(kube: FakeKube, inventory_dir: Path,
                                                            vlan: int | None) -> None:
    body = interpretation("mac-vrf", vlan=vlan)
    assert "anycast_gateway" not in body
    out = data_of(await create(allocator(kube, inventory_dir), body))
    roles = sorted(o["metadata"]["name"].rsplit(".", 1)[1] for o in kube.claims())
    expected = [f"l2vni-bd-{SID}"] + ([f"vlan-bd-{SID}"] if vlan is None else [])
    assert roles == sorted(expected)
    assert l3vni_claims(kube) == [] and len(kube.vlan_claims()) == (1 if vlan is None else 0)
    assert "l3vni" not in out and "anycastGateway" not in out
    assert profiles.gateway_families(Interpretation.parse(body)) == {}
    assert [c.field for c in profiles.plan(Interpretation.parse(body))] == (
        ["vlan", "l2vni"] if vlan is None else ["l2vni"])


@pytest.mark.parametrize(("gateway", "expected"), [
    ({"ipv4": "10.31.0.1/24"}, {"gatewayIPv4": "10.31.0.1/24"}),
    ({"ipv6": "2001:db8:31::1/64"}, {"gatewayIPv6": "2001:db8:31::1/64"}),
    ({"ipv4": "10.30.0.1/24", "ipv6": None}, {"gatewayIPv4": "10.30.0.1/24"}),
    ({"ipv4": "10.30.0.1/24", "ipv6": "2001:db8:30::1/64"},
     {"gatewayIPv4": "10.30.0.1/24", "gatewayIPv6": "2001:db8:30::1/64"}),
], ids=["ipv4-only", "ipv6-only", "ipv6-null", "both"])
async def test_a_gateway_claims_one_l3vni_and_carries_only_its_declared_families(
        kube: FakeKube, inventory_dir: Path, gateway: dict[str, Any],
        expected: dict[str, str]) -> None:
    body = interpretation("mac-vrf", vlan=130, anycast_gateway=gateway)
    out = data_of(await create(allocator(kube, inventory_dir), body))
    assert kube.vlan_claims() == []  # VLAN 130 is named
    assert len(l3vni_claims(kube)) == 1 and len(kube.vni_claims()) == 2
    assert out["anycastGateway"] == expected  # an unrequested family is never added
    assert 10000 <= out["l3vni"] <= 20000 and out["l3vni"] != out["l2vni"]
    assert_claims_well_formed(kube)


async def test_a_gateway_declaring_no_family_is_never_allocated(kube: FakeKube,
                                                                inventory_dir: Path) -> None:
    body = interpretation("mac-vrf", vlan=130, anycast_gateway={"ipv4": None, "ipv6": None})
    reason = failure(await create(allocator(kube, inventory_dir), body))
    assert "anycast_gateway" in reason and "no address family" in reason
    assert kube.creates() == 0


@pytest.mark.parametrize("vlan", [None, 200])
async def test_ipvrf_claims_an_l3vni_and_never_a_vlan(kube: FakeKube, inventory_dir: Path,
                                                      vlan: int | None) -> None:
    out = data_of(await create(allocator(kube, inventory_dir),
                               interpretation("ip-vrf", vlan=vlan, endpoints=1)))
    assert kube.vlan_claims() == []  # zero VLAN claims, named or not (AD-51)
    if kube.authority == KUID:
        assert not [p for m, p in kube.requests if m == "POST" and p.endswith("/vlanclaims")]
    assert [o["metadata"]["name"] for o in kube.claims()] == [
        f"agentic-netops-intent.migr-{SID}.l3vni-vrf-{SID}"]
    ep = out["endpoints"][0]
    assert ep["vrf"] == f"vrf-{SID}"
    if vlan is None:
        assert "vlan" not in ep  # the untagged subinterface
    else:
        assert ep["vlan"] == vlan  # carried as named
    assert out["routeTargets"] == {"importRT": [f"target:65000:{out['l3vni']}"],
                                   "exportRT": [f"target:65000:{out['l3vni']}"]}
    assert out["addressFamilies"] == {"ipv4Prefixes": ["10.50.0.0/24"]}
    NormalizedServiceIntent.parse(out)


async def test_acl_claims_nothing_and_releasing_nothing_is_a_success(
        kube: FakeKube, inventory_dir: Path) -> None:
    alloc = allocator(kube, inventory_dir)
    out = data_of(await create(alloc, interpretation("acl", vlan=1500, endpoints=1)))
    assert kube.claims() == [] and kube.creates() == 0
    assert out["endpoints"] == [{"node": "leaf01", "attachment": "ethernet-1/1", "vlan": 1500}]
    assert out["acl"]["defaultAction"] == "deny"
    assert out["acl"]["rules"][0]["destinationPort"] == "443"
    released = data_of(await alloc.handle(stage({"operation": "release",
                                                 "correlation_ids": [CID]})))
    assert released == {"released": [], "correlation_ids": [CID]}


# --------------------------------------------------------------------------------------------------
# §4 failure modes
# --------------------------------------------------------------------------------------------------


async def test_exhaustion_names_the_pool_and_its_range_and_leaves_no_claim(
        kube: FakeKube, inventory_dir: Path) -> None:
    kube.pools["fabric01-vni"] = (10000, 10000)
    kube.held["fabric01-vni"] = {10000: "someone.else.l2vni-bd-x"}
    reason = failure(await create(allocator(kube, inventory_dir), interpretation("mac-vrf")))
    assert "exhausted" in reason and "10000-10000" in reason and "L2VNI" in reason
    assert kube.claims() == []  # the VLAN this call claimed was rolled back


async def test_a_held_stated_value_is_refused_naming_the_value(kube: FakeKube) -> None:
    adapter = kube.adapter()
    labels = profiles.labels(CID)
    await adapter.create(VNI, "agentic-netops-intent.migr-a.l2vni-bd-a", labels, stated=10050)
    refused = await adapter.wait_bound(
        await adapter.create(VNI, "agentic-netops-intent.migr-b.l2vni-bd-b", labels,
                             stated=10050))
    assert refused.ready is False and refused.reason == "Conflict"
    assert "10050" in refused.message and "migr-a" in refused.message


@pytest.mark.parametrize("fault", ["connect", "server"])
async def test_unreachable_authority_bounded_retry_then_named_failure_no_local_lease(
        kube: FakeKube, inventory_dir: Path, fault: str) -> None:
    if fault == "connect":
        kube.always_down = True
    else:
        kube.server_errors = 10**6
    sleeps: list[float] = []
    reason = failure(await create(allocator(kube, inventory_dir, sleeps),
                                  interpretation("mac-vrf")))
    assert reason.startswith("allocation authority unreachable")
    assert kube.authority in reason and kube.namespace in reason
    assert "no local lease" in reason
    assert len(kube.requests) == 3  # the first attempt and 2 retries — then it stops
    assert sleeps == [1.0, 2.0]  # data-model.md §25: backoff from 1 s
    assert kube.claims() == []


async def test_a_transient_outage_within_the_bound_is_ridden_out(kube: FakeKube,
                                                                 inventory_dir: Path) -> None:
    kube.down = 2
    out = data_of(await create(allocator(kube, inventory_dir), interpretation("vlan")))
    assert 1000 <= out["endpoints"][0]["vlan"] <= 4000


async def test_a_pending_claim_is_polled_until_bound(kube: FakeKube, inventory_dir: Path) -> None:
    kube.pending_reads = 3
    sleeps: list[float] = []
    out = data_of(await create(allocator(kube, inventory_dir, sleeps, poll_interval=0.25),
                               interpretation("ip-vrf", endpoints=1)))
    assert out["l3vni"] == 10000 and sleeps.count(0.25) == 4


async def test_a_claim_that_never_binds_is_terminal(kube: FakeKube, inventory_dir: Path) -> None:
    kube.pending_reads = 10**6
    now = [0.0]

    def clock() -> float:
        now[0] += 1.0
        return now[0]

    reason = failure(await create(allocator(kube, inventory_dir, bind_timeout=5.0, clock=clock),
                                  interpretation("ip-vrf", endpoints=1)))
    assert "reported no allocated value" in reason
    assert kube.claims() == []


async def test_two_concurrent_threads_same_stated_value_exactly_one_binds(kube: FakeKube) -> None:
    labels_a, labels_b = profiles.labels(CID), profiles.labels(OTHER_CID)
    a, b = kube.adapter(), kube.adapter()

    async def claim(adapter: Any, name: str, labels: dict[str, str]) -> Any:
        return await adapter.wait_bound(await adapter.create(VNI, name, labels, stated=10077))

    results = await asyncio.gather(
        claim(a, "agentic-netops-intent.migr-aaa.l2vni-bd-aaa", labels_a),
        claim(b, "agentic-netops-intent.migr-bbb.l2vni-bd-bbb", labels_b))
    bound = [r for r in results if r.ready is True]
    refused = [r for r in results if r.ready is False]
    assert len(bound) == 1 and len(refused) == 1
    assert bound[0].value == 10077 and "10077" in refused[0].message


async def test_two_concurrent_threads_racing_for_the_last_vni_exactly_one_binds(
        kube: FakeKube, inventory_dir: Path) -> None:
    kube.pools["fabric01-vni"] = (10000, 10000)
    replies = await asyncio.gather(
        create(allocator(kube, inventory_dir), interpretation("ip-vrf", sid="aaa", endpoints=1),
               CID),
        create(allocator(kube, inventory_dir), interpretation("ip-vrf", sid="bbb", endpoints=1),
               OTHER_CID))
    ok = [r for r in replies if r.metadata["x-agentic-netops"]["status"] == "ok"]
    failed = [r for r in replies if r.metadata["x-agentic-netops"]["status"] == "error"]
    assert len(ok) == 1 and len(failed) == 1
    assert data_of(ok[0])["l3vni"] == 10000 and "10000" in failure(failed[0])
    assert len(kube.claims()) == 1


async def test_a_second_service_under_an_existing_name_is_refused(kube: FakeKube,
                                                                  inventory_dir: Path) -> None:
    alloc = allocator(kube, inventory_dir)
    first = data_of(await create(alloc, interpretation("mac-vrf"), CID))
    before = json.dumps(kube.claims(), sort_keys=True)
    reason = failure(await create(alloc, interpretation("mac-vrf"), OTHER_CID))
    assert f"migr-{SID} already exists" in reason and CID in reason
    assert json.dumps(kube.claims(), sort_keys=True) == before  # the earlier one is untouched
    assert first["l2vni"] >= 10000


async def test_concurrent_threads_under_one_name_exactly_one_holds_it(
        kube: FakeKube, inventory_dir: Path) -> None:
    replies = await asyncio.gather(
        create(allocator(kube, inventory_dir), interpretation("ip-vrf", endpoints=1), CID),
        create(allocator(kube, inventory_dir), interpretation("ip-vrf", endpoints=1), OTHER_CID))
    statuses = sorted(r.metadata["x-agentic-netops"]["status"] for r in replies)
    assert statuses == ["error", "ok"]
    assert "already exists" in failure(next(
        r for r in replies if r.metadata["x-agentic-netops"]["status"] == "error"))
    assert len(kube.claims()) == 1


async def test_no_fabric_asn_fails_before_anything_is_claimed(kube: FakeKube,
                                                              tmp_path: Path) -> None:
    d = tmp_path / "inv"
    d.mkdir()
    (d / "inventory.json").write_text(json.dumps({"nodes": []}))
    reason = failure(await create(allocator(kube, d), interpretation("mac-vrf")))
    assert "fabricASN" in reason and kube.requests == []


async def test_a_named_vlan_outside_the_naming_band_is_never_claimed(kube: FakeKube,
                                                                     inventory_dir: Path) -> None:
    reason = failure(await create(allocator(kube, inventory_dir),
                                  interpretation("mac-vrf", vlan=1500)))
    assert "100\u2013999" in reason and "1000\u20134000" in reason and kube.requests == []


async def test_a_refusal_or_clarification_is_not_allocated(kube: FakeKube,
                                                           inventory_dir: Path) -> None:
    body = interpretation("vlan", unsupported_properties=["x: no"])
    assert "not an interpretation to allocate" in failure(
        await create(allocator(kube, inventory_dir), body))
    assert "correlation identifier" in failure(
        await create(allocator(kube, inventory_dir), interpretation("vlan"), cid=None))
    assert "not a valid Interpretation" in failure(
        await create(allocator(kube, inventory_dir), {"service_type": "vlan"}))
    assert kube.requests == []


# --------------------------------------------------------------------------------------------------
# derived values, determinism, release
# --------------------------------------------------------------------------------------------------


async def test_route_targets_are_exactly_as_rendered(kube: FakeKube, inventory_dir: Path) -> None:
    out = data_of(await create(allocator(kube, inventory_dir), interpretation("mac-vrf", vlan=100)))
    assert out["l2vni"] == 10000
    assert out["routeTargets"] == {"importRT": ["target:65000:10000"],
                                   "exportRT": ["target:65000:10000"]}


async def test_reassignment_within_a_thread_is_byte_identical(kube: FakeKube,
                                                             inventory_dir: Path) -> None:
    alloc = allocator(kube, inventory_dir)
    body = interpretation("mac-vrf", gateway=True)
    first = await create(alloc, body)
    creates = kube.creates()
    # a fresh allocator (a restarted worker) finds the same claims by label and name
    second = await create(allocator(kube, inventory_dir), body)
    assert kube.creates() == creates  # nothing claimed again
    def body(reply: t.Message) -> bytes:
        return t.encode(reply.model_copy(update={"message_id": "-"}))

    assert body(first) == body(second)  # summary, marker and data part, byte for byte


async def test_release_on_decline_removes_every_provisional_claim_and_reads_no_network(
        kube: FakeKube, inventory_dir: Path) -> None:
    alloc = allocator(kube, inventory_dir)
    data_of(await create(alloc, interpretation("mac-vrf", gateway=True)))
    data_of(await create(alloc, interpretation("vlan", sid="other"), OTHER_CID))
    assert len(kube.claims()) == 4
    kube.requests.clear()
    released = data_of(await alloc.handle(stage({"operation": "release",
                                                 "correlation_ids": [CID]})))
    assert sorted(released["released"]) == sorted([
        f"agentic-netops-intent.migr-{SID}.vlan-bd-{SID}",
        f"agentic-netops-intent.migr-{SID}.l2vni-bd-{SID}",
        f"agentic-netops-intent.migr-{SID}.l3vni-vrf-{SID}"])
    assert released["correlation_ids"] == [CID]
    # the label-selector diff: nothing of the declined request is left; the other is untouched
    assert [o["metadata"]["labels"]["agentic-netops.io/correlation-id"]
            for o in kube.claims()] == [OTHER_CID]
    # no Network read of any kind (the fake raises on one); only claim list and delete
    assert {m for m, _ in kube.requests} <= {"GET", "DELETE"}
    assert all("claims" in p and "networks" not in p for _, p in kube.requests)


async def test_rollback_releases_what_the_failed_call_claimed(kube: FakeKube,
                                                              inventory_dir: Path) -> None:
    kube.pools["fabric01-vni"] = (10000, 10000)
    kube.held["fabric01-vni"] = {10000: "held"}
    reason = failure(await create(allocator(kube, inventory_dir), interpretation("mac-vrf")))
    assert "exhausted" in reason
    # the VLAN claim made before the L2VNI was refused is released: no partial assignment
    assert kube.claims() == [] and kube.held["fabric01-vlan"] == {}
    assert ("DELETE", next(p for m, p in kube.requests if m == "POST")
            + f"/agentic-netops-intent.migr-{SID}.vlan-bd-{SID}") in kube.requests


async def test_release_rejects_a_malformed_request(kube: FakeKube, inventory_dir: Path) -> None:
    alloc = allocator(kube, inventory_dir)
    assert "correlation_ids" in failure(await alloc.handle(stage({"operation": "release"})))
    assert "correlation_ids" in failure(await alloc.handle(
        stage({"operation": "release", "correlation_ids": ["a,b=c"]})))
    assert kube.requests == []


# --------------------------------------------------------------------------------------------------
# AD-33: the bands never meet
# --------------------------------------------------------------------------------------------------


async def test_named_and_allocated_vlans_never_intersect(kube: FakeKube,
                                                         inventory_dir: Path) -> None:
    rng = random.Random(20260924)  # noqa: S311 — a reproducible property run, not a secret
    named: set[int] = set()
    allocated: set[int] = set()
    for i in range(60):
        sid = f"p{i:03d}"
        cid = f"{i:032x}"
        kind = rng.choice(["vlan", "mac-vrf"])
        vlan = rng.randint(100, 999) if rng.random() < 0.5 else None
        out = data_of(await create(allocator(kube, inventory_dir),
                                   interpretation(kind, vlan=vlan, sid=sid), cid))
        value = out["endpoints"][0]["vlan"]
        if vlan is None:
            allocated.add(value)
            assert 1000 <= value <= 4000
        else:
            named.add(value)
            assert value == vlan
    claimed_vlans = {int(o["status"].get("value", o["status"].get("id")))
                     for o in kube.vlan_claims()}
    assert claimed_vlans == allocated  # a named VLAN is never claimed
    assert named and allocated and not named & allocated
    assert all(100 <= v <= 999 for v in named)


def test_the_adapter_reads_its_authority_from_the_environment() -> None:
    assert AuthorityConfig.from_env({}) == AuthorityConfig(
        FIRST_PARTY, "agentic-netops-allocation", "fabric01-vlan", "fabric01-vni")
    kuid = AuthorityConfig.from_env({"ALLOCATION_AUTHORITY": "kuid", "VLAN_POOL": "v"})
    assert (kuid.namespace, kuid.vlan_pool, kuid.vni_pool) == ("kuid-system", "v", "fabric01-vni")
    with pytest.raises(Exception, match="neither"):
        AuthorityConfig.from_env({"ALLOCATION_AUTHORITY": "lease"})


def test_claim_names_fit_and_follow_the_one_scheme() -> None:
    sid = "a" * 15
    for p in profiles.plan(Interpretation.parse(
            interpretation("mac-vrf", sid=sid, gateway=True))):
        assert len(p.name) <= 253 and CLAIM_NAME.match(p.name)
