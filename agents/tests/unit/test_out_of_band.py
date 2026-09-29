"""T094 — out-of-band detection (FR-105, CD-04, R-40, AD-58; data-model.md §15, §16, §21).

On every status or removal request the deployer re-reads the live ``Network``: a ``spec`` whose
canonical-JSON hash no longer equals the submitted-spec annotation is *modified outside the
intent tier*; an absence the tier did not cause is *deleted outside the intent tier*. Either way
the report's ``out_of_band`` is set, the live state is reported, an ``out_of_band`` audit event is
emitted, ``agentic_netops_agent_out_of_band_changes_total{change}`` is incremented, and **nothing is
written** to the ``Network``.

The removal-of-a-modified-service flow (AD-58) is asserted twice: at the deployer's boundary — the
detecting (status) request deletes nothing and names the modification, ``remove`` deletes only with
the second confirmation — and end to end, driving the supervisor graph over this deployer and the
fake API server: zero deletes on the detecting turn, the statement in confirmation 1's payload and
prompt, a decline at either confirmation leaving the object untouched, the delete issued only
after the second.
"""

from __future__ import annotations

import copy
import json
from typing import Any

import pytest
from pydantic import BaseModel

import common.transport as t
from common import metrics
from common.exceptions import WorkerFailedError
from provisioning.deployer.stamp import SPEC_HASH_ANNOTATION, canonical_json, spec_sha256
from tests.unit.conftest import Env, span_events
from tests.unit.conftest import FakeClock as SupervisorClock
from tests.unit.deployer_fakes import CID, CONFIRM, NETWORK, Rig

pytestmark = pytest.mark.usefixtures("fresh_telemetry")

# A fixed spec and its pinned digest: the canonical-JSON form is keys sorted, no insignificant
# whitespace, UTF-8, numbers in shortest round-trip form (CD-04). A change of form changes this.
PINNED_SPEC = {
    "description": "Service 4b7e19c2a05d3f6 (mac-vrf)",
    "bridgeDomains": [{"name": "bd-4b7e19c2a05d3f6", "vlan": 120, "l2vni": 10021,
                       "evpn": {"routeTargets": {"import": ["target:65000:10021"],
                                                 "export": ["target:65000:10021"]}}}],
    "attachments": [{"node": "leaf01", "attachment": "ethernet-1/1", "vlan": 120},
                    {"node": "leaf02", "attachment": "ethernet-1/1", "vlan": 120}],
}
PINNED_DIGEST = "1ca31d5b166b48932bd51ea1fa581b924d80341caea1a1bb854bea739217f539"


async def _submitted(rig: Rig) -> None:
    rig.converge_at(rig.clock.now + 5)
    assert (await rig.create()).status == "COMPLETED"


def _modify(rig: Rig) -> None:
    """``kubectl edit`` behind the tier's back: the spec changes, the annotation does not."""
    rig.api.networks[NETWORK]["spec"]["attachments"][1]["attachment"] = "ethernet-1/3"


def _gets(rig: Rig, since: int) -> list[dict[str, Any]]:
    return [r for r in rig.api.requests[since:] if r["method"] == "GET"
            and r["path"].endswith(f"/networks/{NETWORK}")]


def test_the_canonical_json_hash_form_is_pinned() -> None:
    assert canonical_json(PINNED_SPEC).startswith(b'{"attachments":[{"attachment":"ethernet-1/1"')
    assert b" " not in canonical_json({"a": [1, 2], "b": {"c": "d"}})
    assert canonical_json({"t": "é"}) == '{"t":"é"}'.encode()  # UTF-8, not \\u-escaped
    assert canonical_json({"x": 0.1}) == b'{"x":0.1}'  # shortest round-trip number form
    assert spec_sha256(PINNED_SPEC) == PINNED_DIGEST
    reordered = dict(reversed(list(PINNED_SPEC.items())))
    assert spec_sha256(reordered) == PINNED_DIGEST  # key order never matters


async def test_every_status_request_re_reads_the_live_object() -> None:
    rig = Rig()
    await _submitted(rig)
    for _ in range(3):
        mark = len(rig.api.requests)
        report = await rig.status()
        assert len(_gets(rig, mark)) == 1  # read now, never a remembered answer
        assert report.state == "converged" and report.out_of_band is None
    rig.api.set_ready(NETWORK, "False", "NotConverged", "targets not Ready: leaf02")
    assert (await rig.status()).state == "progressing"  # the live state, not the remembered one


async def test_every_removal_request_re_reads_the_live_object_before_deleting() -> None:
    rig = Rig()
    await _submitted(rig)
    rig.clock.at(rig.clock.now + 5, lambda: rig.api.finalize(NETWORK))
    mark = len(rig.api.requests)
    await rig.remove()
    methods = [r["method"] for r in rig.api.requests[mark:] if "/networks" in r["path"]]
    assert methods[0] == "GET" and methods.index("DELETE") > 0


async def test_a_modified_spec_is_reported_modified_outside_the_tier_with_zero_writes(
        fresh_telemetry: Any) -> None:
    rig = Rig()
    await _submitted(rig)
    _modify(rig)
    writes = len(rig.api.network_writes())
    before = metrics.value(metrics.OUT_OF_BAND_CHANGES, change="modified")
    report = await rig.status()
    assert report.out_of_band == "modified"
    message = report.message or ""
    assert message.startswith(f"Network/{NETWORK} was modified outside the intent tier")
    assert "Live state:" in message and "converged" in message.split("Live state:")[1]
    live = report.live or {}
    assert live["specSha256"] == spec_sha256(rig.api.networks[NETWORK]["spec"])
    assert live["submittedSpecSha256"] != live["specSha256"]
    assert live["conditions"][0]["type"] == "Ready"
    assert metrics.value(metrics.OUT_OF_BAND_CHANGES, change="modified") == before + 1
    (event,) = [a for n, a in span_events(fresh_telemetry) if n == "audit.out_of_band"]
    assert event["audit.reason"] == "modified" and event["audit.correlation_id"] == CID
    assert event["audit.principal"] == "alice"
    assert event["audit.live_spec_sha256"] == live["specSha256"]  # both hashes (data-model §16)
    assert event["audit.submitted_spec_sha256"] == live["submittedSpecSha256"]
    assert len(rig.api.network_writes()) == writes  # zero writes
    assert rig.api.events[-1]["reason"] == "OutOfBandChange"  # the mirror is an Event, not a write
    assert SPEC_HASH_ANNOTATION in rig.api.networks[NETWORK]["metadata"]["annotations"]


async def test_a_modified_spec_is_reported_with_its_live_description() -> None:
    rig = Rig()
    await _submitted(rig)
    remembered = rig.api.networks[NETWORK]["spec"].get("description")
    rig.api.networks[NETWORK]["spec"]["description"] = "edited by hand"  # quickstart §26
    report = await rig.status()
    assert report.out_of_band == "modified"
    live_part = (report.message or "").split("Live state:")[1]
    assert '"edited by hand"' in live_part  # the live record, as it reads now
    assert not remembered or remembered not in live_part  # never the remembered one


async def test_an_absence_the_tier_did_not_cause_is_deleted_outside_the_tier(
        fresh_telemetry: Any) -> None:
    rig = Rig()
    await _submitted(rig)
    rig.api.networks.clear()  # removed with cluster tooling, finalizer and all
    writes = len(rig.api.network_writes())
    before = metrics.value(metrics.OUT_OF_BAND_CHANGES, change="deleted")
    report = await rig.status(tier_removed=False)
    assert report.out_of_band == "deleted" and report.state == "absent"
    assert "deleted outside the intent tier" in (report.message or "")
    assert metrics.value(metrics.OUT_OF_BAND_CHANGES, change="deleted") == before + 1
    assert [a["audit.reason"] for n, a in span_events(fresh_telemetry)
            if n == "audit.out_of_band"] == ["deleted"]
    assert len(rig.api.network_writes()) == writes  # never re-created


async def test_an_absence_the_tier_caused_is_not_out_of_band(fresh_telemetry: Any) -> None:
    rig = Rig()
    await _submitted(rig)
    rig.api.networks.clear()
    before = metrics.value(metrics.OUT_OF_BAND_CHANGES, change="deleted")
    report = await rig.status(tier_removed=True)
    assert report.out_of_band is None and report.state == "absent"
    assert metrics.value(metrics.OUT_OF_BAND_CHANGES, change="deleted") == before
    assert not [n for n, _ in span_events(fresh_telemetry) if n == "audit.out_of_band"]


async def test_the_counter_is_incremented_per_change_label() -> None:
    rig = Rig()
    await _submitted(rig)
    _modify(rig)
    m0 = metrics.value(metrics.OUT_OF_BAND_CHANGES, change="modified")
    d0 = metrics.value(metrics.OUT_OF_BAND_CHANGES, change="deleted")
    await rig.status()
    await rig.status()
    rig.api.networks.clear()
    await rig.status()
    assert metrics.value(metrics.OUT_OF_BAND_CHANGES, change="modified") == m0 + 2
    assert metrics.value(metrics.OUT_OF_BAND_CHANGES, change="deleted") == d0 + 1


async def test_a_status_request_never_writes_to_a_network_in_any_state() -> None:
    rig = Rig()
    await _submitted(rig)
    writes = len(rig.api.network_writes())
    for mutate in (lambda: None,
                   lambda: rig.api.set_ready(NETWORK, "Unknown", "VerificationFailed", "leaf02"),
                   lambda: _modify(rig),
                   lambda: rig.api._delete(NETWORK),
                   lambda: rig.api.networks.clear()):
        before = len(rig.api.network_writes())
        mutate()
        mark = len(rig.api.requests)
        await rig.status()
        after = [r for r in rig.api.requests[mark:]
                 if r["method"] != "GET" and "/networks" in r["path"]]
        assert after == []
        assert len(rig.api.network_writes()) == before  # (the test's own mutations aside)
    assert all(w["method"] in ("PATCH", "DELETE") for w in rig.api.network_writes()[writes:])


async def test_removal_of_a_modified_service_detecting_turn_deletes_nothing() -> None:
    """The deployer half of AD-58: the detecting request (status, before confirmation 1)
    deletes nothing and yields the statement for confirmation 1's payload; a removal without
    confirmation 2 — a decline at either point — leaves the object untouched; the delete is
    issued only with the second confirmation."""
    rig = Rig()
    await _submitted(rig)
    _modify(rig)
    detecting = await rig.status()
    assert rig.api.calls("DELETE") == []
    assert detecting.out_of_band == "modified"
    statement = detecting.message or ""
    assert "modified outside the intent tier" in statement  # what confirmation 1 carries
    untouched = dict(rig.api.networks[NETWORK])
    for declined in ({"decided": "decline", "principal": "alice"}, None):
        payload: dict[str, Any] = {"operation": "remove", "network": NETWORK,
                                   "principal": "alice"}
        if declined is not None:
            payload["confirmation_2"] = declined
        refused = await rig.call(payload)
        assert refused.status == "FAILED" and "second confirmation" in (refused.message or "")
        assert rig.api.calls("DELETE") == []
        assert rig.api.networks[NETWORK] == untouched
    rig.clock.at(rig.clock.now + 5, lambda: rig.api.finalize(NETWORK))
    removed = await rig.call({"operation": "remove", "network": NETWORK, "principal": "alice",
                              "confirmation_2": CONFIRM})
    assert len(rig.api.calls("DELETE")) == 1
    assert removed.status == "COMPLETED" and removed.out_of_band == "modified"
    assert "modified outside the intent tier" in (removed.message or "")


# --------------------------------------------------------------------------------------------------
# the whole flow through the supervisor graph (T101), over this deployer and the fake API server
# --------------------------------------------------------------------------------------------------


class _DeployerBridge(t.TransportClient):
    """A ``TransportClient`` whose deployer is the real stage over the fake API server."""

    def __init__(self, settings: Any, rig: Rig) -> None:  # no gateway: nothing to discover
        self.settings = settings
        self.rig = rig
        self.ops: list[str] = []

    async def call(self, skill: str, data: Any, *, expect: type[BaseModel] | None,
                   marker: str | None, correlation_id: str | None, thread_id: str | None,
                   idempotency_key: str | None = None, operation: str = "create",
                   text: str = "", idempotent: bool = True) -> t.CallResult:
        assert skill == "deploy-network-service", skill  # a removal asks no other worker
        payload = dict(data or {})
        self.ops.append(str(payload.get("operation")))
        reply = await self.rig.deployer.handle(t.StageMessage(
            kind="stage", skill=skill, correlation_id=correlation_id, thread_id=thread_id,
            idempotency_key=idempotency_key, operation=operation, data=payload, text=text))
        meta = (reply.metadata or {}).get("x-agentic-netops") or {}
        if meta.get("status") != "ok":
            raise WorkerFailedError("deployer", str(meta.get("reason")))
        value, source = t.extract_payload(reply, expect, marker, "deployer")
        return t.CallResult("deployer", skill, value, "ok", source)


@pytest.mark.parametrize("decline_at", [None, "confirmation_1", "confirmation_2"])
async def test_removal_of_a_modified_service_through_the_supervisor(
        env: Env, decline_at: str | None) -> None:
    from supervisors.provisioning.graph.graph import Supervisor

    rig = Rig()
    await _submitted(rig)
    _modify(rig)
    settings = env.settings()
    bridge = _DeployerBridge(settings, rig)
    supervisor = Supervisor(settings, bridge, llm=None, clock=SupervisorClock(),
                            checkpoint_path=env.checkpoint)
    try:
        await supervisor.open()
        await supervisor.registry.record_service(  # type: ignore[union-attr]
            NETWORK, construct="mac-vrf", correlation_id=CID)

        async def turn(text: str, thread_id: str | None = None) -> list[dict[str, Any]]:
            return [c async for c in supervisor.turn(text, principal="alice",
                                                     thread_id=thread_id)]

        untouched = copy.deepcopy(rig.api.networks[NETWORK])
        first = await turn(f"Please remove {NETWORK}")
        thread_id = first[0]["thread_id"]
        assert bridge.ops == ["status"] and rig.api.calls("DELETE") == []  # detecting turn
        stage = [c for c in first if c["type"] == "stage"][-1]
        assert stage["out_of_band"] == "modified"
        assert "modified outside the intent tier" in json.dumps(stage["payload"])
        prompt = [c for c in first if c["type"] == "confirmation_request"][-1]["prompt"]
        assert "modified outside the intent tier" in prompt
        second = await turn("decline" if decline_at == "confirmation_1" else "confirm",
                            thread_id)
        assert rig.api.calls("DELETE") == []
        if decline_at != "confirmation_1":
            await turn("decline" if decline_at == "confirmation_2" else "confirm", thread_id)
        if decline_at is not None:
            assert rig.api.calls("DELETE") == [] and "remove" not in bridge.ops
            assert rig.api.networks[NETWORK] == untouched
            assert second
            return
        assert bridge.ops[-1] == "remove" and len(rig.api.calls("DELETE")) == 1
    finally:
        await supervisor.close()
