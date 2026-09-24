"""The supervisor graph: routing, bounded exits, the closed status set, STATUS_UNKNOWN, a removal
in progress, and checkpoint resume (T079; FR-053, FR-054, FR-055, SC-024, data-model.md §7, §17,
§25, AD-49, AD-54, AD-62, AD-63).

Written before the supervisor graph (T085) and run failing first. The graph is driven directly
(``Supervisor.turn``) over the in-memory SLIM stand-in with fake workers that do return
interpretations, assignments and deployment reports, and a fake clock.
"""

from __future__ import annotations

from typing import Any

import pytest

import common.transport as t
from common import metrics
from common.exceptions import BoundsConfigurationError, SubmissionRefusedError
from common.provisioning_states import ALL_STATUSES
from common.schemas.stream import parse_chunk
from supervisors.provisioning.graph import nodes
from supervisors.provisioning.graph.graph import Supervisor
from tests.unit.conftest import (
    GATEWAY_CREDENTIALS,
    NETWORK,
    Env,
    FakeClock,
    FakeCluster,
    FakeLLM,
    FakeWorkers,
    Killed,
    continue_report,
    removal_in_progress_report,
    span_events,
)

pytestmark = pytest.mark.usefixtures("fresh_telemetry")

PROMPT = ("Extend vlan 100 as a mac-vrf across leaf01 ethernet-1/1 and leaf02 ethernet-1/1 "
          "for tenant blue")
REMOVAL = "Remove the mac-vrf migr-3f2b9c0d1e4a5b6 of tenant blue"


class Rig:
    """One supervisor process: its settings, fake workers, clock and model client."""

    def __init__(self, env: Env, *, gateway: t.InMemoryGateway | None = None,
                 cluster: FakeCluster | None = None, clock: FakeClock | None = None,
                 **settings_env: str) -> None:
        self.env = env
        self.settings = env.settings(**settings_env)
        self.gateway = gateway or t.InMemoryGateway(*GATEWAY_CREDENTIALS)
        self.clock = clock or FakeClock()
        self.workers = FakeWorkers(self.gateway, self.clock, cluster)
        self.llm = FakeLLM()
        backend = self.gateway.connect(GATEWAY_CREDENTIALS, identity="devnet/provisioning/sup")

        async def no_sleep(_seconds: float) -> None:
            return None

        client = t.TransportClient(self.settings, backend, sleep=no_sleep)
        self.supervisor = Supervisor(self.settings, client, llm=self.llm, clock=self.clock)
        self.chunks: list[dict[str, Any]] = []

    async def turn(self, text: str, thread_id: str | None = None,
                   principal: str = "alice") -> list[dict[str, Any]]:
        out = [c async for c in self.supervisor.turn(text, principal=principal,
                                                     thread_id=thread_id)]
        for chunk in out:
            parse_chunk(chunk)  # strict: closed status set, correlation id, ready strings
            assert chunk["status"] in ALL_STATUSES
        self.chunks.extend(out)
        return out

    async def to_approved(self, prompt: str = PROMPT) -> str:
        first = await self.turn(prompt)
        thread_id = first[0]["thread_id"]
        await self.turn("confirm", thread_id)
        return thread_id


@pytest.fixture
async def rig(env: Env) -> Any:
    r = Rig(env)
    await r.workers.start()
    yield r
    await r.supervisor.close()


def finals(chunks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [c for c in chunks if c["type"] == "final"]


def stage_count(stage: str, outcome: str) -> float:
    return metrics.value(metrics.STAGE_REQUESTS, stage=stage, outcome=outcome)


# --------------------------------------------------------------------------------------------------
# the happy path, both confirmations, the chunk shapes
# --------------------------------------------------------------------------------------------------


async def test_two_confirmations_then_submission(rig: Rig) -> None:
    first = await rig.turn(PROMPT)
    assert [c["type"] for c in first] == ["status", "status", "stage", "confirmation_request"]
    assert [c["status"] for c in first] == ["RECEIVED_REQUEST", "VALIDATED", "MAPPED", "MAPPED"]
    thread_id = first[0]["thread_id"]
    assert rig.workers.requests["allocator"] == []

    second = await rig.turn("confirm", thread_id)
    assert [c["type"] for c in second][-2:] == ["stage", "confirmation_request"]
    assert second[-2]["stage"] == "allocator" and second[-2]["status"] == "ALLOCATED"
    assert rig.workers.requests["deployer"] == []  # no submission without the second confirm

    third = await rig.turn("confirm", thread_id)
    assert finals(third)[-1]["status"] == "COMPLETED"
    assert rig.workers.cluster.creations == [NETWORK]
    assert stage_count("deployer", "converged") == 1
    for stage in ("mapper", "allocator"):
        assert stage_count(stage, "succeeded") == 1
    state = await rig.supervisor.state(thread_id)
    assert state["workflow_status"] == "COMPLETED"
    assert state["confirmation_2"]["decided"] == "confirm"


async def test_progress_ready_and_reason_passed_through_unaltered(rig: Rig) -> None:
    thread_id = await rig.to_approved()
    chunks = await rig.turn("confirm", thread_id)
    progress = [(c["status"], c["ready"], c.get("reason")) for c in chunks
                if c["type"] == "progress"]
    assert progress == [("CONFIGURED", "Unknown", "VerificationFailed"),
                        ("VERIFIED", "True", "Converged")]
    for chunk in chunks:
        if chunk["type"] == "progress":
            assert isinstance(chunk["ready"], str)


@pytest.mark.parametrize("at", ["confirmation_1", "confirmation_2"])
async def test_decline_ends_cleanly_and_submits_nothing(rig: Rig, at: str,
                                                        fresh_telemetry: Any) -> None:
    thread_id = (await rig.turn(PROMPT))[0]["thread_id"]
    if at == "confirmation_2":
        await rig.turn("confirm", thread_id)
    chunks = await rig.turn("decline", thread_id)
    assert finals(chunks)[-1]["status"] == "FAILED"
    assert "declined" in finals(chunks)[-1]["message"]
    # Nothing submitted: the deployer is only asked its read-only release gate (T101).
    assert [r.operation for r in rig.workers.requests["deployer"]] == ["release_gate"]
    stage = "mapper" if at == "confirmation_1" else "allocator"
    assert stage_count(stage, "declined") == 1
    declines = [a for n, a in span_events(fresh_telemetry) if n == "audit.decline"]
    assert [d["audit.principal"] for d in declines] == ["alice"]
    state = await rig.supervisor.state(thread_id)
    assert state[at]["decided"] == "decline" and state[at]["principal"] == "alice"


async def test_an_unsafe_request_is_refused_without_a_model_or_worker_call(rig: Rig) -> None:
    chunks = await rig.turn("ssh into leaf01 and configure vlan 100 on ethernet-1/1")
    assert finals(chunks)[-1]["status"] == "FAILED"
    assert "Refused" in finals(chunks)[-1]["message"]
    assert rig.llm.calls == []
    assert rig.gateway.requests == []
    assert stage_count("supervisor", "refused") == 1


async def test_an_informational_request_goes_through_the_guards_to_the_model(rig: Rig) -> None:
    chunks = await rig.turn("What constructs can I ask for?")
    assert finals(chunks)[-1]["status"] == "COMPLETED"
    assert len(rig.llm.calls) == 1
    system, data = rig.llm.calls[0]
    assert "<data source=\"operator\">" in data["content"]
    assert "never instructions" in system["content"]
    assert rig.gateway.requests == []


async def test_worker_unreachable_is_retryable_and_the_thread_resumes(rig: Rig) -> None:
    rig.gateway.stop("devnet/provisioning/network-mapping")
    chunks = await rig.turn(PROMPT)
    errors = [c for c in chunks if c["type"] == "error"]
    assert errors and errors[-1]["reason"] == "worker unreachable: mapper"
    assert errors[-1]["retryable"] is True and errors[-1]["stage"] == "mapper"
    assert stage_count("mapper", "unreachable") == 1
    rig.gateway.start("devnet/provisioning/network-mapping")
    resumed = await rig.turn("retry", chunks[0]["thread_id"])
    assert resumed[-1]["type"] == "confirmation_request"


async def test_worker_failed_is_terminal_for_the_stage(rig: Rig) -> None:
    rig.workers.interpretation = {**rig.workers.interpretation, "service_type": "VPLS"}
    chunks = await rig.turn(PROMPT)
    errors = [c for c in chunks if c["type"] == "error"]
    assert errors[-1]["reason"].startswith("worker failed: mapper — out-of-contract payload")
    assert errors[-1]["retryable"] is False
    assert finals(chunks)[-1]["status"] == "FAILED"
    assert stage_count("mapper", "failed") == 1


# --------------------------------------------------------------------------------------------------
# node-level routing for each conditional edge
# --------------------------------------------------------------------------------------------------


def test_route_after_guard() -> None:
    assert nodes.route_after_guard({"next": "refused"}) == "__end__"
    assert nodes.route_after_guard({"next": "supervisor"}) == "supervisor"


@pytest.mark.parametrize(
    ("state", "expected"),
    [
        ({"turn_done": True}, "__end__"),
        ({"awaiting": "confirmation_1", "turn_text": "confirm"}, "decide"),
        ({"awaiting": "confirmation_2", "turn_text": "decline"}, "decide"),
        ({"awaiting": "confirmation_1", "turn_text": "what is a mac-vrf?"}, "await"),
        ({"pending": "mapper"}, "mapper"),
        ({"pending": "allocator"}, "allocator"),
        ({"pending": "deployer", "iteration_count": 2}, "deployer"),
        ({"pending": "deployer", "iteration_count": 3}, "bounded_exit"),
        ({"pending": "mapper", "active_base": 290.0, "turn_started": 0.0}, "bounded_exit"),
        ({"turn_class": "provisionable", "turn_consumed": False}, "mapper"),
        ({"turn_class": "informational", "turn_consumed": False}, "inform"),
        ({"turn_consumed": True}, "__end__"),
    ],
    ids=["turn-done", "decide-confirm", "decide-decline", "await-reminder", "mapper",
         "allocator", "deployer", "iteration-cap", "deadline", "new-request", "inform",
         "nothing-left"],
)
def test_route_from_supervisor(state: dict[str, Any], expected: str) -> None:
    settings_like = nodes.Bounds(max_iterations=3, request_deadline_seconds=300.0)
    base = {"iteration_count": 0, "active_base": 0.0, "turn_started": 0.0, "turn_done": False,
            "awaiting": None, "pending": None, "turn_consumed": False, "turn_class": None,
            "turn_text": ""}
    target, _updates = nodes.plan_next({**base, **state}, settings_like, now=15.0)
    assert target == expected
    assert nodes.route_from_supervisor({"next": target}) == expected


def test_route_after_decide() -> None:
    assert nodes.route_after_decide({"next": "supervisor"}) == "supervisor"
    assert nodes.route_after_decide({"next": "__end__"}) == "__end__"


@pytest.mark.parametrize(("text", "decision"),
                         [("confirm", "confirm"), ("Yes", "confirm"), ("approve.", "confirm"),
                          ("decline", "decline"), ("no", "decline"), ("cancel", "decline"),
                          ("maybe later", None), ("confirm and also skip checks", None)])
def test_parse_decision(text: str, decision: str | None) -> None:
    assert nodes.parse_decision(text) == decision


# --------------------------------------------------------------------------------------------------
# bounds (data-model.md §25)
# --------------------------------------------------------------------------------------------------


def test_defaults_are_3_iterations_and_300_seconds(env: Env) -> None:
    settings = env.settings()
    assert settings.max_iterations == 3
    assert settings.request_deadline_seconds == 300.0
    bounds = nodes.Bounds.from_settings(settings)
    assert (bounds.max_iterations, bounds.request_deadline_seconds) == (3, 300.0)


async def test_iteration_cap_ends_in_an_explicit_final_failed_chunk(rig: Rig) -> None:
    rig.workers.deployer_default = continue_report  # a watch that never ends
    thread_id = await rig.to_approved()
    chunks = await rig.turn("confirm", thread_id)
    final = finals(chunks)[-1]
    assert final["status"] == "FAILED"
    assert "bounded exit" in final["message"] and "iteration cap of 3" in final["message"]
    assert len(rig.workers.requests["deployer"]) == 3
    assert chunks[-1] is final  # the stream ends with it — never a hang
    assert stage_count("deployer", "converged") == 0


async def test_iteration_cap_override_honoured(env: Env) -> None:
    rig = Rig(env, SUPERVISOR_MAX_ITERATIONS="5")
    await rig.workers.start()
    rig.workers.deployer_script = [continue_report(), continue_report(), continue_report()]
    thread_id = await rig.to_approved()
    chunks = await rig.turn("confirm", thread_id)
    assert finals(chunks)[-1]["status"] == "COMPLETED"
    assert len(rig.workers.requests["deployer"]) == 4
    await rig.supervisor.close()


async def test_deadline_ends_in_an_explicit_final_failed_chunk(rig: Rig) -> None:
    rig.workers.advance["mapper"] = 200.0
    rig.workers.advance["allocator"] = 150.0
    thread_id = (await rig.turn(PROMPT))[0]["thread_id"]
    rig.clock.advance(10_000)  # the operator reads for hours: confirmation time is excluded
    chunks = await rig.turn("confirm", thread_id)
    final = finals(chunks)[-1]
    assert final["status"] == "FAILED"
    assert "bounded exit" in final["message"] and "deadline of 300 s" in final["message"]
    assert not [c for c in chunks if c["type"] == "confirmation_request"]
    assert rig.workers.requests["deployer"] == []


async def test_confirmation_time_is_excluded_from_the_deadline(rig: Rig) -> None:
    rig.workers.advance["mapper"] = 100.0
    rig.workers.advance["allocator"] = 100.0
    thread_id = (await rig.turn(PROMPT))[0]["thread_id"]
    rig.clock.advance(5_000)
    await rig.turn("confirm", thread_id)
    rig.clock.advance(5_000)
    chunks = await rig.turn("confirm", thread_id)
    assert finals(chunks)[-1]["status"] == "COMPLETED"


async def test_deadline_override_honoured(env: Env) -> None:
    rig = Rig(env, SUPERVISOR_REQUEST_DEADLINE_SECONDS="250")
    await rig.workers.start()
    rig.workers.advance["mapper"] = 200.0
    rig.workers.advance["allocator"] = 60.0
    thread_id = (await rig.turn(PROMPT))[0]["thread_id"]
    chunks = await rig.turn("confirm", thread_id)
    assert "deadline of 250 s" in finals(chunks)[-1]["message"]
    await rig.supervisor.close()


@pytest.mark.parametrize("env_override", [
    {"DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS": "220"},
    {"DEPLOYER_CALL_TIMEOUT_SECONDS": "320", "SUPERVISOR_REQUEST_DEADLINE_SECONDS": "300"},
    {"SUPERVISOR_REQUEST_DEADLINE_SECONDS": "180"},
])
def test_an_inconsistent_override_is_refused_at_start_up(env: Env,
                                                         env_override: dict[str, str]) -> None:
    with pytest.raises(BoundsConfigurationError):
        env.settings(**env_override)


def test_the_supervisor_refuses_inconsistent_settings(env: Env) -> None:
    import dataclasses

    broken = dataclasses.replace(env.settings(), convergence_timeout_seconds=500.0)
    gateway = t.InMemoryGateway(*GATEWAY_CREDENTIALS)
    client = t.TransportClient(env.settings(), gateway.connect(GATEWAY_CREDENTIALS,
                                                               identity="a/b/c"))
    with pytest.raises(BoundsConfigurationError):
        Supervisor(broken, client)


# --------------------------------------------------------------------------------------------------
# STATUS_UNKNOWN is never a success (FR-054, AD-49)
# --------------------------------------------------------------------------------------------------


async def test_transport_dropped_after_submission_ends_status_unknown(rig: Rig) -> None:
    thread_id = await rig.to_approved()
    rig.gateway.drop_after_send.add("devnet/provisioning/network-deployer")
    chunks = await rig.turn("confirm", thread_id)
    final = finals(chunks)[-1]
    assert final["status"] == "STATUS_UNKNOWN"
    message = final["message"]
    assert "unknown" in message.lower()
    assert "SLIM" in message and rig.settings.transport_endpoint in message  # the lost dependency
    assert NETWORK in message and "agentic-netops-intent" in message  # the live object
    assert not [c for c in chunks if c["status"] in ("VERIFIED", "COMPLETED")]
    assert stage_count("deployer", "converged") == 0
    assert stage_count("deployer", "status_unknown") == 1
    assert metrics.success_rate("deployer") == 0.0
    state = await rig.supervisor.state(thread_id)
    assert state["workflow_status"] == "STATUS_UNKNOWN"
    assert state["converged"] is False  # the convergence watch was not satisfied
    assert len(rig.workers.requests["deployer"]) == 1  # and it was not resubmitted blindly


# --------------------------------------------------------------------------------------------------
# a removal whose turn ends in progress (AD-63)
# --------------------------------------------------------------------------------------------------


async def test_a_removal_ending_provisioning_is_in_progress(rig: Rig) -> None:
    rig.workers.deployer_default = removal_in_progress_report
    thread_id = await rig.to_approved(REMOVAL)
    assert (await rig.supervisor.state(thread_id))["operation"] == "remove"
    chunks = await rig.turn("confirm", thread_id)
    # The status read of the first turn, then the removal after the second confirmation (T101).
    assert [r.operation for r in rig.workers.requests["deployer"]] == ["status", "remove"]
    final = finals(chunks)[-1]
    assert final["status"] == "PROVISIONING"
    assert "removal in progress" in final["message"]
    assert not [c for c in chunks if c["type"] == "error"]
    assert not [c for c in chunks if c["status"] in ("CONFIGURED", "VERIFIED", "COMPLETED")]
    progress = [c for c in chunks if c["type"] == "progress"]
    assert [(c["ready"], c["reason"]) for c in progress] == [("False", "Deleting")]
    assert stage_count("deployer", "in_progress") == 1
    assert stage_count("deployer", "converged") == 0
    assert stage_count("deployer", "failed") == 0


# --------------------------------------------------------------------------------------------------
# the submission invariant, in the submission stage itself (FR-055)
# --------------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "state",
    [
        {"workflow_status": "ALLOCATED", "confirmation_2": None},
        {"workflow_status": "APPROVED", "confirmation_2": None},
        {"workflow_status": "APPROVED",
         "confirmation_2": {"decided": "decline", "at": "2026-09-24T10:00:00+00:00",
                            "principal": "alice"}},
        {"workflow_status": "MAPPED",
         "confirmation_2": {"decided": "confirm", "at": "2026-09-24T10:00:00+00:00",
                            "principal": "alice"}},
    ],
    ids=["allocated", "no-confirmation", "declined", "wrong-status"],
)
def test_submission_refused_unless_approved_and_confirmed(state: dict[str, Any]) -> None:
    with pytest.raises(SubmissionRefusedError):
        nodes.check_submission_allowed(state)


async def test_the_deployer_node_refuses_even_when_routed_to(rig: Rig) -> None:
    thread_id = (await rig.turn(PROMPT))[0]["thread_id"]
    await rig.turn("confirm", thread_id)  # ALLOCATED, awaiting the second confirmation
    chunks = await rig.supervisor.run_node_for_test(thread_id, "deployer")
    assert finals(chunks)[-1]["status"] == "FAILED"
    assert "submission refused" in finals(chunks)[-1]["message"]
    assert rig.workers.requests["deployer"] == []


# --------------------------------------------------------------------------------------------------
# the checkpointer: killed mid-request with an assignment confirmed (FR-053, SC-024)
# --------------------------------------------------------------------------------------------------


async def test_killed_mid_request_resumes_without_double_submission(env: Env) -> None:
    gateway = t.InMemoryGateway(*GATEWAY_CREDENTIALS)
    cluster = FakeCluster()
    first = Rig(env, gateway=gateway, cluster=cluster)
    await first.workers.start()
    thread_id = await first.to_approved()
    first.workers.kill_deployer = True  # the deployer receives the submission; we die waiting
    with pytest.raises(Killed):
        await first.turn("confirm", thread_id)
    assert cluster.creations == [NETWORK]
    await first.supervisor.close()
    await gateway.connect(GATEWAY_CREDENTIALS, identity="x/y/z").close()

    # A new process on the same SQLite file, the same workers still registered.
    second = Rig(env, gateway=gateway, cluster=cluster)
    second.workers = first.workers  # the running deployer keeps its cluster
    state = await second.supervisor.state(thread_id)
    assert state["workflow_status"] == "APPROVED"
    assert state["confirmation_2"]["decided"] == "confirm"
    chunks = await second.turn("continue", thread_id)
    assert finals(chunks)[-1]["status"] == "COMPLETED"
    assert not [c for c in chunks if c["type"] == "confirmation_request"]  # no re-confirmation
    assert cluster.creations == [NETWORK]  # nothing double-submitted
    keys = {r.idempotency_key for r in first.workers.requests["deployer"]}
    assert len(keys) == 1 and thread_id in next(iter(keys))
    # And a further turn on the finished thread does not submit again.
    await second.turn("continue", thread_id)
    assert cluster.creations == [NETWORK]
    assert len(first.workers.requests["deployer"]) == 2
    await second.supervisor.close()
