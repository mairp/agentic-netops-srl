"""The supervisor pipeline and its audit events (T101; FR-051, FR-055…FR-057, FR-069, FR-078,
FR-105, CR-002, data-model.md §7, §16, AD-18, AD-58, AD-59).

The graph is driven through ``Supervisor.turn`` with fake workers behind a fake
``TransportClient`` that records every call. Asserted here:

* exactly which audit span events the supervisor emits — confirm, decline and refuse, each with
  the principal authenticated on the request that carried it, the correlation id and (for a
  confirmation) the resulting resource — and that it never emits submit, remove or out_of_band,
  which are the deployer's;
* no deployer create or remove before the second confirmation; a decline asks the deployer's
  release gate and then the allocator to release what the gate named; a refusal claims nothing;
* a removal reads the live object first, states a modification outside the tier at the first
  confirmation (prompt and payload), deletes nothing on that turn and only deletes after the
  second confirmation; a status question takes no confirmation and changes nothing;
* no module under ``agents/supervisors`` imports a Kubernetes client or creates an Event;
* no retired service name appears in any chunk, and every confirmation names its construct.
"""

from __future__ import annotations

import ast
import re
from pathlib import Path
from typing import Any

import pytest
from pydantic import BaseModel

import common.transport as t
from common.exceptions import WorkerFailedError
from common.guards.refusals import CONSTRUCTS
from common.provisioning_states import ALL_STATUSES
from common.schemas.stream import parse_chunk
from supervisors.provisioning.graph import audit
from supervisors.provisioning.graph.graph import Supervisor
from tests.unit.conftest import ASSIGNMENT, INTERPRETATION, Env, FakeClock, span_events

pytestmark = pytest.mark.usefixtures("fresh_telemetry")

AGENTS = Path(__file__).resolve().parents[2]
SUPERVISORS = AGENTS / "supervisors"
SID = INTERPRETATION["service_id"]
NETWORK = f"migr-{SID}"
PROMPT = ("Extend vlan 100 as a mac-vrf across leaf01 ethernet-1/1 and leaf02 ethernet-1/1 "
          "for tenant blue")
TWO_CONSTRUCTS = "request: one construct per request — you asked for mac-vrf and ip-vrf; send one"
BAND = ("endpoints[0].vlan: 1500 lies in the allocation band 1000\u20134000, which is the "
        "allocation authority's to hand out; name a VLAN from the naming band 100\u2013999, or "
        "name none and one is allocated")
RETIRED = re.compile(r"\b(?:VPLS|VPWS|E-?Line|L3VPN|L2L3-?IRB)\b", re.IGNORECASE)
DEPLOYER_ONLY = {"audit.submit", "audit.remove", "audit.out_of_band"}
MODIFIED_MESSAGE = (f"Network/{NETWORK} was modified outside the intent tier: its spec hash is "
                    "ab12, not the submitted cd34. Live state: it is Ready (converged).")


def network_ref() -> dict[str, Any]:
    return {"apiVersion": "fabric.agentic-netops.io/v1alpha1", "kind": "Network",
            "namespace": "agentic-netops-intent", "name": NETWORK}


class FakeClient(t.TransportClient):
    """A ``TransportClient`` whose workers are functions: every call recorded, the answer
    validated against ``expect`` exactly as the real receiver rule does."""

    def __init__(self, settings: Any) -> None:  # no gateway, no cards: nothing to discover
        self.settings = settings
        self.calls: list[dict[str, Any]] = []
        self.interpretation: dict[str, Any] = dict(INTERPRETATION)
        self.status_answer: dict[str, Any] = {
            "operation": "status", "status": "COMPLETED", "state": "converged",
            "message": f"Network/{NETWORK} is Ready (converged).",
            "resources": [{**network_ref(), "ready": "True", "reason": "Converged"}]}
        self.create_report: dict[str, Any] = {
            "operation": "create", "status": "COMPLETED",
            "resources": [{**network_ref(), "ready": "True", "reason": "Converged"}],
            "progress": [{"status": "VERIFIED", "resource": f"Network/{NETWORK}",
                          "ready": "True", "reason": "Converged"}]}
        self.fail: dict[str, str] = {}

    def ops(self, skill: str | None = None) -> list[tuple[str, str]]:
        return [(c["skill"], c["operation"]) for c in self.calls
                if skill is None or c["skill"] == skill]

    def deployer_writes(self) -> list[str]:
        return [op for skill, op in self.ops("deploy-network-service")
                if op in ("create", "remove")]

    async def call(self, skill: str, data: Any, *, expect: type[BaseModel] | None,
                   marker: str | None, correlation_id: str | None, thread_id: str | None,
                   idempotency_key: str | None = None, operation: str = "create",
                   text: str = "", idempotent: bool = True) -> t.CallResult:
        payload = dict(data or {})
        self.calls.append({"skill": skill, "operation": payload.get("operation", operation),
                           "transport_operation": operation, "data": payload,
                           "correlation_id": correlation_id, "thread_id": thread_id})
        worker = skill.split("-")[0]
        if self.fail.get(skill) == payload.get("operation"):
            raise WorkerFailedError(worker, "the worker failed")
        answer = self._answer(skill, payload, correlation_id or "")
        value: Any = expect.model_validate(answer, strict=True) if expect else answer
        return t.CallResult(worker, skill, value, "ok", "data")

    def _answer(self, skill: str, payload: dict[str, Any], cid: str) -> dict[str, Any]:
        op = payload.get("operation")
        if skill == "map-network-request":
            return self.interpretation
        if skill == "allocate-network-service":
            if op == "release":
                return {"released": [f"agentic-netops-intent.{NETWORK}.vlan-vlan-{SID}",
                                     f"agentic-netops-intent.{NETWORK}.l2vni-bd-{SID}"],
                        "correlation_ids": payload["correlation_ids"]}
            return dict(ASSIGNMENT)
        if op == "status":
            return self.status_answer
        if op == "release_gate":
            return {"operation": "release_gate", "status": "COMPLETED",
                    "releasable": payload["correlation_ids"], "refused": []}
        if op == "remove":
            return {"operation": "remove", "status": "COMPLETED",
                    "progress": [{"status": "PROVISIONING", "resource": f"Network/{NETWORK}",
                                  "ready": "False", "reason": "Deleting"}],
                    "message": f"Network/{NETWORK} removed"}
        return self.create_report


class Rig:
    def __init__(self, env: Env) -> None:
        self.settings = env.settings()
        self.client = FakeClient(self.settings)
        self.supervisor = Supervisor(self.settings, self.client, llm=None, clock=FakeClock(),
                                     checkpoint_path=env.checkpoint)
        self.chunks: list[dict[str, Any]] = []

    async def seed(self) -> None:
        """The service as the tier submitted it on an earlier thread (the durable record)."""
        await self.supervisor.open()
        await self.supervisor.registry.record_service(  # type: ignore[union-attr]
            NETWORK, construct="mac-vrf", correlation_id="b" * 32)

    async def turn(self, text: str, thread_id: str | None = None,
                   principal: str = "alice") -> list[dict[str, Any]]:
        out = [c async for c in self.supervisor.turn(text, principal=principal,
                                                     thread_id=thread_id)]
        for chunk in out:
            parse_chunk(chunk)
            assert chunk["status"] in ALL_STATUSES
        self.chunks.extend(out)
        return out


@pytest.fixture
async def rig(env: Env) -> Any:
    r = Rig(env)
    yield r
    # Every chunk any scenario produced: construct vocabulary only (FR-026, FR-085).
    for chunk in r.chunks:
        assert not RETIRED.search(str(chunk)), chunk
    assert_confirmations_name_the_construct(r.chunks)
    await r.supervisor.close()


def assert_confirmations_name_the_construct(chunks: list[dict[str, Any]]) -> None:
    for i, chunk in enumerate(chunks):
        if chunk["type"] != "confirmation_request":
            continue
        assert any(c in chunk["prompt"] for c in CONSTRUCTS), chunk["prompt"]
        before = [c for c in chunks[:i] if c["type"] == "stage" and c.get("payload")]
        if before and before[-1]["stage"] == chunk["stage"]:
            payload = before[-1]["payload"]
            named = (payload.get("service_type") or payload.get("type")
                     or payload.get("construct"))
            assert named in CONSTRUCTS, payload


def audits(tel: Any) -> list[tuple[str, dict[str, Any]]]:
    return span_events(tel)


def finals(chunks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [c for c in chunks if c["type"] == "final"]


def confirmations(chunks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [c for c in chunks if c["type"] == "confirmation_request"]


def assert_supervisor_only(tel: Any) -> None:
    names = {name for name, _ in audits(tel)}
    assert not names & DEPLOYER_ONLY, names
    assert names <= {"audit.confirm", "audit.decline", "audit.refuse"}


# --------------------------------------------------------------------------------------------------
# create: confirm, confirm, deploy
# --------------------------------------------------------------------------------------------------


async def test_confirm_confirm_deploy(rig: Rig, fresh_telemetry: Any) -> None:
    first = await rig.turn(PROMPT)
    thread_id, cid = first[0]["thread_id"], first[0]["correlation_id"]
    assert rig.client.ops() == [("map-network-request", "create")]
    assert confirmations(first)[-1]["prompt"].startswith("Confirm this mac-vrf interpretation?")

    second = await rig.turn("confirm", thread_id, principal="bob")
    assert rig.client.ops()[-1] == ("allocate-network-service", "create")
    assert rig.client.deployer_writes() == []  # nothing submitted before confirmation 2
    assert confirmations(second)[-1]["prompt"].startswith("Deploy this mac-vrf service")

    third = await rig.turn("confirm", thread_id, principal="carol")
    assert finals(third)[-1]["status"] == "COMPLETED"
    assert rig.client.deployer_writes() == ["create"]
    create = rig.client.calls[-1]["data"]
    assert create["assignment"]["serviceId"] == SID
    assert create["principal"] == "carol"
    assert create["confirmation_2"]["decided"] == "confirm"
    assert create["confirmation_2"]["principal"] == "carol"

    events = audits(fresh_telemetry)
    assert [n for n, _ in events] == ["audit.confirm", "audit.confirm"]
    assert [a["audit.principal"] for _, a in events] == ["bob", "carol"]  # the turn's principal
    assert [a["audit.stage"] for _, a in events] == ["mapper", "allocator"]
    for _, attrs in events:
        assert attrs["audit.correlation_id"] == cid
        assert attrs["audit.thread_id"] == thread_id
        assert any(f'"name":"{NETWORK}"' in r for r in attrs["audit.resources"])
    assert_supervisor_only(fresh_telemetry)


async def test_a_degraded_fabric_runs_both_confirmations_and_reports_the_failure(
        rig: Rig, fresh_telemetry: Any) -> None:
    failure = (f"Network/{NETWORK} did not converge within 150 s: Ready=False/"
               "InvariantMissing — leaf02: EVPN route for the L2VNI 10021 not received")
    rig.client.create_report = {"operation": "create", "status": "FAILED", "message": failure,
                                "resources": [{**network_ref(), "ready": "False",
                                               "reason": "InvariantMissing"}]}
    thread_id = (await rig.turn(PROMPT))[0]["thread_id"]
    await rig.turn("confirm", thread_id)
    chunks = await rig.turn("confirm", thread_id)
    assert len(confirmations(rig.chunks)) == 2  # never refused on a guess
    assert finals(chunks)[-1]["status"] == "FAILED"
    assert finals(chunks)[-1]["message"] == failure
    assert [n for n, _ in audits(fresh_telemetry)] == ["audit.confirm", "audit.confirm"]


async def test_a_webhook_outage_leaves_the_thread_resumable_and_releases_nothing(
        rig: Rig, fresh_telemetry: Any) -> None:
    """AD-52: a dry-run the API server fails because the admission webhook is unreachable is the
    cluster API dependency's failure, not a refusal — retryable error, stage kept pending, no
    release; resent on the same thread once the dependency is back, it submits."""
    rig.client.create_report = {
        "operation": "create", "status": "FAILED", "submitted": False, "retryable": True,
        "dependency": "cluster API: admission webhook networks.fabric.agentic-netops.io",
        "message": "cluster API dependency unavailable: the admission webhook "
                   "networks.fabric.agentic-netops.io could not be reached; nothing was applied"}
    thread_id = (await rig.turn(PROMPT))[0]["thread_id"]
    await rig.turn("confirm", thread_id)
    chunks = await rig.turn("confirm", thread_id)
    errors = [c for c in chunks if c["type"] == "error"]
    assert errors and errors[-1]["retryable"] is True
    assert "admission webhook" in errors[-1]["reason"]
    assert not [c for c in chunks if c["type"] == "final" and c["status"] == "FAILED"]
    assert ("deploy-network-service", "release_gate") not in rig.client.ops()
    assert ("allocate-network-service", "release") not in rig.client.ops()
    state = await rig.supervisor.state(thread_id)
    assert state["pending"] == "deployer"
    # The dependency returns: the same thread resumes and submits exactly once more.
    rig.client.create_report = {
        "operation": "create", "status": "COMPLETED",
        "resources": [{**network_ref(), "ready": "True", "reason": "Converged"}],
        "progress": [{"status": "VERIFIED", "resource": f"Network/{NETWORK}",
                      "ready": "True", "reason": "Converged"}]}
    resumed = await rig.turn("continue", thread_id)
    assert finals(resumed)[-1]["status"] == "COMPLETED"
    assert rig.client.deployer_writes() == ["create", "create"]
    assert_supervisor_only(fresh_telemetry)


@pytest.mark.parametrize("report", [
    {"operation": "create", "status": "FAILED", "submitted": False,
     "causes": ["holder: Network agentic-netops-services/lab-macvrf"],
     "message": "dry-run refused: (leaf01, ethernet-1/1, 100) is held by "
                "Network agentic-netops-services/lab-macvrf"},
    {"operation": "create", "status": "FAILED", "submitted": True,
     "rolled_back": [f"Network/{NETWORK}"], "survivors": [],
     "message": "apply failed; rolled back Network/" + NETWORK},
], ids=["refused-before-apply", "rolled-back"])
async def test_a_create_that_never_stands_releases_its_provisional_claims(
        rig: Rig, report: dict[str, Any]) -> None:
    rig.client.create_report = report
    thread_id = (await rig.turn(PROMPT))[0]["thread_id"]
    await rig.turn("confirm", thread_id)
    chunks = await rig.turn("confirm", thread_id)
    assert rig.client.ops()[-2:] == [("deploy-network-service", "release_gate"),
                                     ("allocate-network-service", "release")]
    final = finals(chunks)[-1]
    assert final["status"] == "FAILED"
    assert f"l2vni-bd-{SID}" in final["message"]


async def test_a_converged_create_releases_nothing(rig: Rig) -> None:
    thread_id = (await rig.turn(PROMPT))[0]["thread_id"]
    await rig.turn("confirm", thread_id)
    await rig.turn("confirm", thread_id)
    assert ("allocate-network-service", "release") not in rig.client.ops()
    assert ("deploy-network-service", "release_gate") not in rig.client.ops()


# --------------------------------------------------------------------------------------------------
# declines
# --------------------------------------------------------------------------------------------------


async def test_decline_at_confirmation_1(rig: Rig, fresh_telemetry: Any) -> None:
    thread_id = (await rig.turn(PROMPT))[0]["thread_id"]
    chunks = await rig.turn("decline", thread_id, principal="bob")
    final = finals(chunks)[-1]
    assert final["status"] == "FAILED"
    assert "nothing was submitted" in final["message"]
    assert "nothing had been claimed" in final["message"]
    assert rig.client.ops() == [("map-network-request", "create"),
                                ("deploy-network-service", "release_gate")]
    assert rig.client.ops("allocate-network-service") == []  # nothing was claimed
    events = audits(fresh_telemetry)
    assert [n for n, _ in events] == ["audit.decline"]
    attrs = events[0][1]
    assert attrs["audit.principal"] == "bob"
    assert attrs["audit.correlation_id"] == chunks[0]["correlation_id"]
    assert list(attrs["audit.resources"]) == []  # a decline carries no resources (§16)
    assert NETWORK in attrs["audit.reason"]
    assert_supervisor_only(fresh_telemetry)


async def test_decline_at_confirmation_2_releases_through_the_gate(
        rig: Rig, fresh_telemetry: Any) -> None:
    first = await rig.turn(PROMPT)
    thread_id, cid = first[0]["thread_id"], first[0]["correlation_id"]
    await rig.turn("confirm", thread_id)
    chunks = await rig.turn("decline", thread_id)
    assert rig.client.ops() == [("map-network-request", "create"),
                                ("allocate-network-service", "create"),
                                ("deploy-network-service", "release_gate"),
                                ("allocate-network-service", "release")]
    gate, release = rig.client.calls[-2]["data"], rig.client.calls[-1]["data"]
    assert gate["correlation_ids"] == [cid]
    assert release["correlation_ids"] == [cid]  # exactly what the gate named releasable
    assert rig.client.deployer_writes() == []
    final = finals(chunks)[-1]
    assert final["status"] == "FAILED"
    assert "nothing was submitted" in final["message"]
    assert f"l2vni-bd-{SID}" in final["message"]  # what was released is named
    assert [n for n, _ in audits(fresh_telemetry)] == ["audit.confirm", "audit.decline"]
    state = await rig.supervisor.state(thread_id)
    assert state["confirmation_2"]["decided"] == "decline"
    assert state["claimed_ids"] == []

    # The thread stays amendable: a new request on it starts over.
    amended = await rig.turn(PROMPT.replace("vlan 100", "vlan 110"), thread_id)
    assert confirmations(amended)[-1]["stage"] == "mapper"
    assert rig.client.ops()[-1] == ("map-network-request", "create")
    assert_supervisor_only(fresh_telemetry)


async def test_a_gate_that_refuses_releases_nothing(rig: Rig) -> None:
    thread_id = (await rig.turn(PROMPT))[0]["thread_id"]
    await rig.turn("confirm", thread_id)
    original = rig.client._answer

    def refusing(skill: str, payload: dict[str, Any], cid: str) -> dict[str, Any]:
        if payload.get("operation") == "release_gate":
            return {"operation": "release_gate", "status": "COMPLETED", "releasable": [],
                    "refused": [{"correlation_id": cid, "network": "migr-0123456789abcde"}]}
        return original(skill, payload, cid)

    rig.client._answer = refusing  # type: ignore[method-assign]
    chunks = await rig.turn("decline", thread_id)
    assert ("allocate-network-service", "release") not in rig.client.ops()
    assert "Network/migr-0123456789abcde" in finals(chunks)[-1]["message"]


# --------------------------------------------------------------------------------------------------
# refusals at interpretation
# --------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("causes", [[TWO_CONSTRUCTS], [BAND]], ids=["two-constructs", "band"])
async def test_a_mapper_refusal_is_verbatim_and_claims_nothing(
        rig: Rig, fresh_telemetry: Any, causes: list[str]) -> None:
    rig.client.interpretation = {**INTERPRETATION, "unsupported_properties": causes}
    chunks = await rig.turn(PROMPT)
    final = finals(chunks)[-1]
    assert final["status"] == "FAILED"
    for cause in causes:
        assert cause in final["message"]  # verbatim: the causes are complete
    assert "Nothing was claimed" in final["message"]
    errors = [c for c in chunks if c["type"] == "error"]
    assert errors[-1]["stage"] == "mapper" and errors[-1]["reason"] == "; ".join(causes)
    assert rig.client.ops() == [("map-network-request", "create")]  # the allocator never ran
    assert not confirmations(chunks)
    events = audits(fresh_telemetry)
    assert [n for n, _ in events] == ["audit.refuse"]
    assert events[0][1]["audit.reason"] == "; ".join(causes)
    assert events[0][1]["audit.principal"] == "alice"
    assert_supervisor_only(fresh_telemetry)


async def test_an_unsafe_request_is_refused_and_audited(rig: Rig, fresh_telemetry: Any) -> None:
    chunks = await rig.turn(f"ssh into leaf01 and remove {NETWORK}")
    assert finals(chunks)[-1]["status"] == "FAILED"
    assert rig.client.calls == []
    assert [n for n, _ in audits(fresh_telemetry)] == ["audit.refuse"]


# --------------------------------------------------------------------------------------------------
# removal
# --------------------------------------------------------------------------------------------------


async def test_removal_takes_both_confirmations(rig: Rig, fresh_telemetry: Any) -> None:
    await rig.seed()
    first = await rig.turn(f"Remove {NETWORK}")
    thread_id, cid = first[0]["thread_id"], first[0]["correlation_id"]
    assert rig.client.ops() == [("deploy-network-service", "status")]
    status = rig.client.calls[0]["data"]
    assert status == {"operation": "status", "network": NETWORK, "tier_removed": False,
                      "principal": "alice"}
    assert rig.client.deployer_writes() == []
    assert confirmations(first)[-1]["stage"] == "deployer"
    assert NETWORK in confirmations(first)[-1]["prompt"]
    assert "mac-vrf" in confirmations(first)[-1]["prompt"]  # from the tier's own record
    assert [c for c in first if c["type"] == "stage"][-1]["payload"]["construct"] == "mac-vrf"

    second = await rig.turn("confirm", thread_id, principal="bob")
    assert confirmations(second)[-1]["prompt"].startswith("Remove this service?")
    assert rig.client.deployer_writes() == []  # nothing deleted before confirmation 2

    third = await rig.turn("confirm", thread_id, principal="carol")
    assert rig.client.deployer_writes() == ["remove"]
    remove = rig.client.calls[-1]["data"]
    assert remove["network"] == NETWORK and remove["principal"] == "carol"
    assert remove["confirmation_2"] == {**remove["confirmation_2"], "decided": "confirm",
                                        "principal": "carol"}
    assert finals(third)[-1]["status"] == "COMPLETED"

    events = audits(fresh_telemetry)
    assert [n for n, _ in events] == ["audit.confirm", "audit.confirm"]
    assert [a["audit.principal"] for _, a in events] == ["bob", "carol"]
    assert all(a["audit.correlation_id"] == cid and a["audit.stage"] == "deployer"
               for _, a in events)
    assert all(any(NETWORK in r for r in a["audit.resources"]) for _, a in events)
    assert_supervisor_only(fresh_telemetry)

    # The tier recorded its own removal: a later status request says so to the deployer.
    assert await rig.supervisor.registry.removed(NETWORK)  # type: ignore[union-attr]
    await rig.turn(f"What is the status of {NETWORK}?")
    assert rig.client.calls[-1]["data"]["tier_removed"] is True


async def test_the_tier_removal_record_survives_a_restart(env: Env) -> None:
    first = Rig(env)
    await first.seed()
    thread_id = (await first.turn(f"Remove {SID}"))[0]["thread_id"]  # the bare service id
    await first.turn("confirm", thread_id)
    await first.turn("confirm", thread_id)
    await first.supervisor.close()
    second = Rig(env)
    await second.turn(f"status of {NETWORK}")
    assert second.client.calls[-1]["data"] == {"operation": "status", "network": NETWORK,
                                                "tier_removed": True, "principal": "alice"}
    await second.supervisor.close()


async def test_removal_of_a_service_created_on_this_thread(rig: Rig) -> None:
    thread_id = (await rig.turn(PROMPT))[0]["thread_id"]
    await rig.turn("confirm", thread_id)
    await rig.turn("confirm", thread_id)
    chunks = await rig.turn("Remove the mac-vrf created on this thread", thread_id)
    assert rig.client.calls[-1]["data"]["network"] == NETWORK
    assert "mac-vrf" in confirmations(chunks)[-1]["prompt"]


async def test_removal_naming_no_service_asks_for_one(rig: Rig, fresh_telemetry: Any) -> None:
    chunks = await rig.turn("Remove the mac-vrf of tenant blue on leaf01 ethernet-1/1")
    assert rig.client.calls == []
    assert "Name the service to remove" in finals(chunks)[-1]["message"]
    assert audits(fresh_telemetry) == []


@pytest.mark.parametrize("decline_at", [None, "confirmation_1", "confirmation_2"])
async def test_removal_of_a_modified_service(rig: Rig, fresh_telemetry: Any,
                                             decline_at: str | None) -> None:
    await rig.seed()
    rig.client.status_answer = {**rig.client.status_answer, "out_of_band": "modified",
                                "message": MODIFIED_MESSAGE}
    first = await rig.turn(f"Please remove {NETWORK}")
    thread_id = first[0]["thread_id"]
    # The detecting turn deletes nothing.
    assert rig.client.deployer_writes() == []
    stage = [c for c in first if c["type"] == "stage"][-1]
    assert stage["out_of_band"] == "modified"
    statement = stage["payload"]["statement"]
    assert "modified outside the intent tier" in statement
    assert stage["payload"]["outOfBand"] == "modified"
    assert "modified outside the intent tier" in confirmations(first)[-1]["prompt"]

    if decline_at == "confirmation_1":
        await rig.turn("decline", thread_id)
        assert rig.client.deployer_writes() == []
        assert [n for n, _ in audits(fresh_telemetry)] == ["audit.decline"]
        return
    await rig.turn("confirm", thread_id)
    assert rig.client.deployer_writes() == []
    if decline_at == "confirmation_2":
        chunks = await rig.turn("decline", thread_id)
        assert rig.client.deployer_writes() == []
        assert "untouched" in finals(chunks)[-1]["message"]
        assert ("deploy-network-service", "release_gate") not in rig.client.ops()
        assert [n for n, _ in audits(fresh_telemetry)] == ["audit.confirm", "audit.decline"]
        return
    await rig.turn("confirm", thread_id)
    assert rig.client.deployer_writes() == ["remove"]  # only after the second confirmation
    assert_supervisor_only(fresh_telemetry)


async def test_removal_of_an_absent_service_is_refused_without_a_delete(
        rig: Rig, fresh_telemetry: Any) -> None:
    rig.client.status_answer = {"operation": "status", "status": "COMPLETED", "state": "absent",
                                "out_of_band": "deleted",
                                "message": f"Network/{NETWORK} was deleted outside the intent "
                                           "tier: it no longer exists."}
    chunks = await rig.turn(f"Remove {NETWORK}")
    assert rig.client.deployer_writes() == []
    assert not confirmations(chunks)
    assert [c for c in chunks if c["type"] == "stage"][-1]["out_of_band"] == "deleted"
    assert "deleted outside the intent tier" in finals(chunks)[-1]["message"]
    assert [n for n, _ in audits(fresh_telemetry)] == ["audit.refuse"]


# --------------------------------------------------------------------------------------------------
# status question: no confirmation, no pipeline, nothing written
# --------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("out_of_band", [None, "modified"])
async def test_status_query(rig: Rig, fresh_telemetry: Any, out_of_band: str | None) -> None:
    if out_of_band:
        rig.client.status_answer = {**rig.client.status_answer, "out_of_band": out_of_band,
                                    "message": MODIFIED_MESSAGE}
    chunks = await rig.turn(f"What is the status of {NETWORK}?")
    assert rig.client.ops() == [("deploy-network-service", "status")]
    assert not confirmations(chunks)
    stage = [c for c in chunks if c["type"] == "stage"][-1]
    assert stage["resource"] == f"Network/{NETWORK}"
    assert stage.get("out_of_band") == out_of_band
    assert finals(chunks)[-1]["message"] == rig.client.status_answer["message"]
    assert audits(fresh_telemetry) == []  # informational: nothing decided, nothing audited
    state = await rig.supervisor.state(chunks[0]["thread_id"])
    assert state["confirmation_1"] is None and state["confirmation_2"] is None


async def test_status_of_the_service_created_on_this_thread(rig: Rig) -> None:
    thread_id = (await rig.turn(PROMPT))[0]["thread_id"]
    await rig.turn("confirm", thread_id)
    await rig.turn("confirm", thread_id)
    chunks = await rig.turn("what is its status?", thread_id)
    assert rig.client.calls[-1]["data"]["network"] == NETWORK
    assert finals(chunks)[-1]["status"] == "COMPLETED"
    assert rig.client.deployer_writes() == ["create"]  # nothing further written


# --------------------------------------------------------------------------------------------------
# the supervisor emits only its own three events and publishes no Kubernetes Event
# --------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("event_type", ["submit", "remove", "out_of_band"])
def test_audit_refuses_the_deployers_events(event_type: str) -> None:
    with pytest.raises(audit.NotTheSupervisorsEvent):
        audit.build_event(event_type, correlation_id="a" * 32, thread_id="t", principal="alice")


def test_audit_builds_its_own_three() -> None:
    for event_type in ("confirm", "decline", "refuse"):
        event = audit.build_event(event_type, correlation_id="a" * 32, thread_id="t",
                                  principal="alice")
        assert event.span_event()[0] == f"audit.{event_type}"
    assert audit.SUPERVISOR_EVENTS == {"confirm", "decline", "refuse"}


KUBE_MODULES = ("kubernetes", "kubernetes_asyncio", "kr8s", "lightkube", "pykube", "kopf")
EVENT_MARKERS = re.compile(r"create_namespaced_event|events\.k8s\.io|CoreV1Event|EventsV1Event"
                           r"|\"kind\":\s*\"Event\"|kind=\"Event\"")


def test_no_kubernetes_client_or_event_under_supervisors() -> None:
    files = sorted(SUPERVISORS.rglob("*.py"))
    assert files
    for path in files:
        source = path.read_text(encoding="utf-8")
        tree = ast.parse(source, filename=str(path))
        for node in ast.walk(tree):
            names: list[str] = []
            if isinstance(node, ast.Import):
                names = [a.name for a in node.names]
            elif isinstance(node, ast.ImportFrom) and node.module:
                names = [node.module]
            for name in names:
                assert name.split(".")[0] not in KUBE_MODULES, f"{path}: imports {name}"
                assert not name.startswith("provisioning.deployer"), f"{path}: imports {name}"
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and \
                    node.func.id == "__import__":
                raise AssertionError(f"{path}: dynamic import")
        assert not EVENT_MARKERS.search(source), f"{path}: creates a Kubernetes Event"
