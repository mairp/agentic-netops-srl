"""The supervisor graph's nodes and the routing of each conditional edge (T085; FR-050 to FR-055,
FR-073, FR-074, FR-092, data-model.md §7, §17, §25, AD-49, AD-54, AD-62, AD-63).

One request turn (one POST) runs ``intake → guard → supervisor ⇄ {mapper, allocator, deployer,
decide} → … → END``. The router (:func:`plan_next`) is a pure function of the state, the bounds
and the clock, so every conditional edge is unit-testable on its own:

* ``guard``      → ``supervisor`` | END (refused: the US6 guards classify every request before
  any model or worker call; an unsafe one never reaches either);
* ``supervisor`` → ``mapper`` | ``allocator`` | ``deployer`` | ``decide`` | ``await`` |
  ``inform`` | ``bounded_exit`` | END;
* ``decide``     → ``supervisor`` (a confirm) | END (a decline).

Bounds (data-model.md §25): at most ``SUPERVISOR_MAX_ITERATIONS`` worker dispatches per request
turn and ``SUPERVISOR_REQUEST_DEADLINE_SECONDS`` of request time, operator confirmation time
excluded (the clock only runs while a turn is being processed). Either ends the turn with an
explicit final ``FAILED`` chunk whose message names the bound — never a hang.

Every chunk carries the correlation identifier and a status of the closed set; every stage
outcome is counted on ``agentic_netops_agent_stage_requests_total``; ``STATUS_UNKNOWN`` and a
removal ending at ``PROVISIONING`` are never counted converged; the deployer's ``progress``
entries are streamed with ``ready`` and ``reason`` unaltered.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from langgraph.graph import END
from langgraph.runtime import Runtime

from common import metrics
from common.exceptions import (
    EndpointError,
    SubmissionRefusedError,
    WorkerFailedError,
    WorkerUnreachableError,
)
from common.guards import build_prompt, classify, neutralize, redact
from common.guards.classifier import RequestClass
from common.guards.refusals import CONSTRUCT_SUMMARY, CONSTRUCTS, SUBMISSION
from common.provisioning_states import WorkflowStatus as S
from common.schemas.audit import AuditEvent, ResourceRef
from common.schemas.interpretation import MARKER as MAPPED_MARKER
from common.schemas.interpretation import Interpretation
from common.schemas.normalized_service_intent import MARKER as DEPLOYMENT_MARKER
from common.schemas.normalized_service_intent import NormalizedServiceIntent
from common.schemas.stream import DeploymentReport, build_chunk
from common.tracing import emit_span_event
from common.transport import TransportClient
from config.settings import Settings
from supervisors.provisioning.graph.state import Bounds, ServiceRequestState, decision

log = logging.getLogger("agentic_netops.supervisor.graph")

MAP_SKILL = "map-network-request"
ALLOCATE_SKILL = "allocate-network-service"
DEPLOY_SKILL = "deploy-network-service"
INTENT_NAMESPACE = "agentic-netops-intent"
NETWORK_API_VERSION = "fabric.agentic-netops.io/v1alpha1"

__all__ = [
    "Bounds",
    "SupervisorContext",
    "check_submission_allowed",
    "parse_decision",
    "plan_next",
    "route_after_decide",
    "route_after_guard",
    "route_from_supervisor",
]


@dataclass
class SupervisorContext:
    """Run-scoped context of one request turn: never checkpointed."""

    settings: Settings
    client: TransportClient
    llm: Any | None
    clock: Callable[[], float]
    span: Any


# --------------------------------------------------------------------------------------------------
# pure helpers: decisions, routing
# --------------------------------------------------------------------------------------------------

_CONFIRM = frozenset({"confirm", "confirmed", "yes", "y", "approve", "approved", "ok", "okay",
                      "proceed", "go ahead"})
_DECLINE = frozenset({"decline", "declined", "no", "n", "cancel", "reject", "abort", "stop"})
_REMOVAL = re.compile(r"\b(?:remove|delete|tear down|teardown|decommission|destroy)\b",
                      re.IGNORECASE)


def parse_decision(text: str) -> str | None:
    """``confirm`` / ``decline`` when the reply is exactly one of the decision words, else None.

    Deliberately literal: a reply that says more than a decision is not taken as one."""
    folded = re.sub(r"[\s.!]+$", "", text.strip().lower())
    folded = re.sub(r"\s+", " ", folded)
    if folded in _CONFIRM:
        return "confirm"
    if folded in _DECLINE:
        return "decline"
    return None


def operation_of(text: str) -> str:
    return "remove" if _REMOVAL.search(text) else "create"


def _elapsed(state: ServiceRequestState, now: float) -> float:
    """Request time consumed: earlier turns' time plus this turn's so far."""
    started = state.get("turn_started")
    return float(state.get("active_base") or 0.0) + (now - float(started)
                                                     if started is not None else 0.0)


def plan_next(state: ServiceRequestState, bounds: Bounds, now: float) -> tuple[str, dict[str, Any]]:
    """The router: where the turn goes next, and the state that goes with it."""
    if state.get("turn_done"):
        return END, {}
    elapsed = _elapsed(state, now)
    if not state.get("turn_consumed") and state.get("awaiting"):
        return ("decide" if parse_decision(state.get("turn_text", "")) else "await"), {}
    pending = state.get("pending")
    starting = not state.get("turn_consumed") and state.get("turn_class") == "provisionable"
    if pending or starting:
        if elapsed > bounds.request_deadline_seconds:
            return "bounded_exit", {"exit_reason": "deadline"}
        if int(state.get("iteration_count") or 0) >= bounds.max_iterations:
            return "bounded_exit", {"exit_reason": "iterations"}
        target = pending or "mapper"
        return target, {"pending": target, "turn_consumed": True,
                        "iteration_count": int(state.get("iteration_count") or 0) + 1}
    if not state.get("turn_consumed"):
        return "inform", {"turn_consumed": True}
    return END, {}


def route_after_guard(state: ServiceRequestState) -> str:
    return END if state.get("next") == "refused" else "supervisor"


def route_from_supervisor(state: ServiceRequestState) -> str:
    return state.get("next") or END


def route_after_decide(state: ServiceRequestState) -> str:
    return state.get("next") or END


def check_submission_allowed(state: ServiceRequestState) -> None:
    """data-model.md §7's invariant, enforced in the submission stage itself (FR-055)."""
    status = state.get("workflow_status")
    second = state.get("confirmation_2") or {}
    if status not in (S.APPROVED, S.PROVISIONING):
        raise SubmissionRefusedError(
            f"submission refused: the request is {status}, not APPROVED")
    if second.get("decided") != "confirm":
        raise SubmissionRefusedError(
            "submission refused: no second confirmation (confirm) is recorded on this thread")


# --------------------------------------------------------------------------------------------------
# emission helpers
# --------------------------------------------------------------------------------------------------


def _emit(runtime: Runtime[SupervisorContext], state: ServiceRequestState, kind: str,
          **fields: Any) -> None:
    chunk = build_chunk(type=kind, correlation_id=state["correlation_id"],
                        thread_id=state["thread_id"], **fields)
    runtime.stream_writer(json.loads(chunk.line()))


def _audit(runtime: Runtime[SupervisorContext], state: ServiceRequestState, event_type: str, *,
           stage: str | None = None, reason: str | None = None,
           resources: list[dict[str, Any]] | None = None) -> None:
    event = AuditEvent(
        event_type=event_type,  # type: ignore[arg-type]
        correlation_id=state["correlation_id"], thread_id=state["thread_id"],
        principal=state["turn_principal"], at=datetime.now(UTC),
        resources=[ResourceRef.model_validate(r, strict=True) for r in resources or []],
        reason=reason, stage=stage)
    name, attributes = event.span_event()
    emit_span_event(name, attributes, span=runtime.context.span)


def _active(runtime: Runtime[SupervisorContext], state: ServiceRequestState) -> float:
    return _elapsed(state, runtime.context.clock())


def _log(state: ServiceRequestState, level: int, msg: str, *args: Any) -> None:
    log.log(level, msg, *args, extra={"correlation_id": state.get("correlation_id"),
                                      "thread_id": state.get("thread_id")})


def _network(state: ServiceRequestState) -> str:
    assignment = state.get("assignment") or {}
    interpretation = state.get("interpretation") or {}
    service_id = assignment.get("serviceId") or interpretation.get("service_id") or "unknown"
    return f"migr-{service_id}"


# --------------------------------------------------------------------------------------------------
# nodes
# --------------------------------------------------------------------------------------------------


async def intake(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    now = runtime.context.clock()
    updates: dict[str, Any] = {
        "turn_started": now, "iteration_count": 0, "turn_done": False, "turn_consumed": False,
        "turn_class": None, "next": "", "exit_reason": None,
    }
    if state.get("new_thread"):
        updates.update(
            principal=state["turn_principal"], original_text=state["turn_text"],
            workflow_status=S.RECEIVED_REQUEST.value, confirmation_1=None, confirmation_2=None,
            claimed_ids=[], released_ids=[], interpretation=None, assignment=None,
            submitted_resources=[], operation=operation_of(state["turn_text"]), pending=None,
            awaiting=None, submission_key=None, converged=False, active_seconds=0.0,
            deadline=None)
    updates["active_base"] = float(updates.get("active_seconds", state.get("active_seconds"))
                                   or 0.0)
    status = updates.get("workflow_status") or state.get("workflow_status") or "RECEIVED_REQUEST"
    _emit(runtime, state, "status", status=status, stage="supervisor")
    return updates


async def guard(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    """The US6 guards, in front of everything: classify; an unsafe request is refused here."""
    verdict = classify(state["turn_text"])
    if verdict.request_class == RequestClass.UNSUPPORTED_OR_UNSAFE:
        refusal = verdict.refusal
        message = refusal.message if refusal else "Refused."
        _audit(runtime, state, "refuse", stage="supervisor",
               reason=f"{verdict.refusal_class}: {message}")
        metrics.record_stage("supervisor", "refused")
        _emit(runtime, state, "final", status=S.FAILED.value, message=message)
        updates: dict[str, Any] = {"next": "refused", "turn_done": True, "turn_consumed": True,
                                   "turn_class": verdict.request_class.value}
        if state.get("new_thread"):
            updates["workflow_status"] = S.FAILED.value
        return updates
    updates = {"turn_class": verdict.request_class.value, "next": "supervisor"}
    in_flight = state.get("awaiting") or state.get("pending")
    if verdict.request_class == RequestClass.PROVISIONABLE and not in_flight:
        # A new request on this thread: the pipeline starts over (data-model.md §7).
        now = runtime.context.clock()
        updates.update(
            original_text=state["turn_text"], workflow_status=S.VALIDATED.value,
            operation=operation_of(state["turn_text"]), confirmation_1=None,
            confirmation_2=None, interpretation=None, assignment=None, submitted_resources=[],
            submission_key=None, converged=False, active_seconds=0.0, active_base=0.0,
            turn_started=now,
            deadline=datetime.fromtimestamp(
                datetime.now(UTC).timestamp() + runtime.context.settings.request_deadline_seconds,
                UTC).isoformat())
        _emit(runtime, state, "status", status=S.VALIDATED.value, stage="supervisor")
    return updates


async def supervisor(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    now = runtime.context.clock()
    target, updates = plan_next(state, Bounds.from_settings(runtime.context.settings), now)
    updates["next"] = target
    updates["active_seconds"] = _elapsed(state, now)
    return updates


async def await_decision(state: ServiceRequestState,
                         runtime: Runtime[SupervisorContext]) -> dict:
    """A reply that is not a decision while one is awaited: ask again, change nothing."""
    first = state.get("awaiting") == "confirmation_1"
    stage = "mapper" if first else "allocator"
    what = ("the interpretation" if first else
            "the assignment (nothing is submitted without this confirmation)")
    _emit(runtime, state, "confirmation_request", stage=stage,
          status=state.get("workflow_status") or S.MAPPED.value,
          prompt=f"Awaiting your confirmation of {what}: reply confirm or decline.")
    return {"turn_done": True, "turn_consumed": True}


async def decide(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    which = state["awaiting"]
    decided = parse_decision(state["turn_text"]) or "decline"
    record = decision(decided, state["turn_principal"])  # this request's principal (FR-102)
    stage = "mapper" if which == "confirmation_1" else "allocator"
    updates: dict[str, Any] = {which: record, "awaiting": None, "turn_consumed": True}
    if decided == "confirm":
        _audit(runtime, state, "confirm", stage=stage)
        if which == "confirmation_1":
            updates.update(pending="allocator", next="supervisor")
        else:
            updates.update(pending="deployer", next="supervisor",
                           workflow_status=S.APPROVED.value)
            _emit(runtime, state, "status", status=S.APPROVED.value, stage="supervisor")
        return updates
    # A decline is a clean terminal state: claims released first, the thread stays resumable.
    released = list(state.get("claimed_ids") or [])
    _audit(runtime, state, "decline", stage=stage)
    metrics.record_stage(stage, "declined")
    point = "interpretation" if which == "confirmation_1" else "assignment"
    _emit(runtime, state, "final", status=S.FAILED.value,
          message=(f"declined at the {point}: nothing was submitted"
                   f"{' and every claimed identifier was released' if released else ''}; "
                   "send an amended request on this thread to continue"))
    updates.update(pending=None, workflow_status=S.FAILED.value, claimed_ids=[],
                   released_ids=list(state.get("released_ids") or []) + released,
                   turn_done=True, next=END)
    return updates


INFORM_INSTRUCTIONS = (
    "You answer an operator's question about the intent tier of a datacenter fabric. The tier "
    "offers four constructs — vlan, mac-vrf, ip-vrf and acl — each submitted as a Network "
    "through the tier and confirmed twice. Answer briefly, in that vocabulary. Never propose a "
    "device command, a device session or a tool call."
)


def _content(response: Any) -> str:
    try:
        choice = response["choices"][0]["message"]["content"]
    except (TypeError, KeyError, IndexError):
        try:
            choice = response.choices[0].message.content
        except (AttributeError, IndexError):
            choice = str(response)
    return str(choice or "")


def static_answer() -> str:
    listed = "; ".join(f"{c} — {CONSTRUCT_SUMMARY[c]}" for c in CONSTRUCTS)
    return (f"The constructs are: {listed}. Each is declared as {SUBMISSION}; the interpretation "
            "and the assignment are each shown to you and confirmed before anything is written.")


async def inform(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    """An informational answer. The model is called only here, behind the guards: the request
    was classified by the guard node, and it reaches the model only as neutralized, redacted,
    delimited data (FR-077, FR-079)."""
    llm = runtime.context.llm
    status = state.get("workflow_status")
    final_status = status if status in (S.COMPLETED, S.FAILED, S.STATUS_UNKNOWN,
                                        S.PROVISIONING) else S.COMPLETED.value
    if llm is None:
        answer = static_answer()
    else:
        prompt = build_prompt(INFORM_INSTRUCTIONS, operator_text=state["turn_text"])
        messages = [{"role": "system", "content": prompt.system},
                    {"role": "user", "content": prompt.data}]
        try:
            answer = redact(_content(await asyncio.to_thread(llm.complete, messages)))
        except EndpointError as exc:
            metrics.record_stage("supervisor", "failed")
            _emit(runtime, state, "error", stage="supervisor", status=S.FAILED.value,
                  reason=f"model endpoint unavailable: {exc}", retryable=True)
            return {"turn_done": True}
    metrics.record_stage("supervisor", "succeeded")
    _emit(runtime, state, "final", status=final_status, message=answer)
    updates: dict[str, Any] = {"turn_done": True}
    if state.get("workflow_status") in (S.RECEIVED_REQUEST, None):
        updates["workflow_status"] = S.COMPLETED.value
    return updates


async def bounded_exit(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    settings = runtime.context.settings
    stage = state.get("pending") or "supervisor"
    if state.get("exit_reason") == "iterations":
        message = (f"bounded exit: the iteration cap of {settings.max_iterations} supervisor "
                   f"iterations in this request turn was reached while {stage} had not finished")
    else:
        message = (f"bounded exit: the request deadline of "
                   f"{settings.request_deadline_seconds:g} s (operator confirmation time "
                   f"excluded) was reached; {stage} did not complete within it")
    if state.get("submission_key"):
        message += (f"; the submitted Network/{_network(state)} in {INTENT_NAMESPACE} is the "
                    "record — ask for its status")
    _log(state, logging.WARNING, "%s", message)
    metrics.record_stage("supervisor", "failed")
    _emit(runtime, state, "final", status=S.FAILED.value, message=message)
    return {"workflow_status": S.FAILED.value, "pending": None, "awaiting": None,
            "turn_done": True, "active_seconds": _active(runtime, state)}


def _past_deadline(runtime: Runtime[SupervisorContext], state: ServiceRequestState) -> bool:
    return _active(runtime, state) > runtime.context.settings.request_deadline_seconds


def _deadline_passed(runtime: Runtime[SupervisorContext], state: ServiceRequestState,
                     stage: str) -> dict:
    """An answer that arrives after the deadline is not shown for confirmation: the router
    ends the turn with the bounded exit (the stage stays named as the one that ran late)."""
    _log(state, logging.WARNING, "%s answered after the request deadline", stage)
    return {"pending": stage, "active_seconds": _active(runtime, state)}


def _unreachable(runtime: Runtime[SupervisorContext], state: ServiceRequestState, stage: str,
                 exc: WorkerUnreachableError) -> dict:
    metrics.record_stage(stage, "unreachable")
    _log(state, logging.WARNING, "%s (%s)", exc, exc.cause)
    _emit(runtime, state, "error", stage=stage, status=S.FAILED.value, reason=str(exc),
          retryable=True)
    # The thread stays resumable: the stage stays pending, the status unchanged.
    return {"turn_done": True, "active_seconds": _active(runtime, state)}


def _failed(runtime: Runtime[SupervisorContext], state: ServiceRequestState, stage: str,
            reason: str, outcome: str = "failed", out_of_band: str | None = None) -> dict:
    metrics.record_stage(stage, outcome)
    _log(state, logging.WARNING, "%s", reason)
    _emit(runtime, state, "error", stage=stage, status=S.FAILED.value, reason=reason,
          retryable=False, out_of_band=out_of_band)
    _emit(runtime, state, "final", status=S.FAILED.value, message=reason)
    return {"workflow_status": S.FAILED.value, "pending": None, "awaiting": None,
            "turn_done": True, "active_seconds": _active(runtime, state)}


async def mapper(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    ctx = runtime.context
    kept, _found = neutralize(state.get("original_text") or state["turn_text"], "operator")
    try:
        result = await ctx.client.call(
            MAP_SKILL, {"text": redact(kept), "operation": state.get("operation", "create")},
            text=redact(kept), expect=Interpretation, marker=MAPPED_MARKER,
            correlation_id=state["correlation_id"], thread_id=state["thread_id"],
            idempotency_key=f"{state['thread_id']}:map", operation=state.get("operation",
                                                                              "create"))
    except WorkerUnreachableError as exc:
        return _unreachable(runtime, state, "mapper", exc)
    except WorkerFailedError as exc:
        return _failed(runtime, state, "mapper", str(exc))
    if _past_deadline(runtime, state):
        return _deadline_passed(runtime, state, "mapper")
    interpretation: Interpretation = result.data
    conflict = interpretation.terminal_conflict()
    if conflict:
        return _failed(runtime, state, "mapper", f"worker failed: mapper — {conflict}")
    active = _active(runtime, state)
    if interpretation.unsupported_properties:
        named = ", ".join(interpretation.unsupported_properties)
        _audit(runtime, state, "refuse", stage="mapper", reason=named)
        return {**_failed(runtime, state, "mapper",
                          f"unsupported or unqualified: {named}; nothing was claimed",
                          outcome="refused"), "interpretation": interpretation.to_wire()}
    if interpretation.missing_fields:
        metrics.record_stage("mapper", "clarification")
        _emit(runtime, state, "final", status=S.RECEIVED_REQUEST.value,
              message=("clarification needed: " + ", ".join(interpretation.missing_fields)
                       + " — reply on this thread with the missing details"))
        return {"workflow_status": S.RECEIVED_REQUEST.value, "pending": None,
                "turn_done": True, "active_seconds": active}
    wire = interpretation.to_wire()
    metrics.record_stage("mapper", "succeeded")
    _emit(runtime, state, "stage", stage="mapper", status=S.MAPPED.value, payload=wire)
    prompt = "Confirm this interpretation?"
    if interpretation.acl is not None:
        unmatched = ("accepted by the device's own default"
                     if interpretation.acl.default_action is None
                     else f"{interpretation.acl.default_action} by the terminal entry")
        prompt += (" Rules are evaluated in ascending priority number, first match wins; "
                   f"unmatched traffic is {unmatched}.")
    _emit(runtime, state, "confirmation_request", stage="mapper", status=S.MAPPED.value,
          prompt=prompt, refusable=True)
    return {"interpretation": wire, "workflow_status": S.MAPPED.value, "pending": None,
            "awaiting": "confirmation_1", "turn_done": True, "active_seconds": active}


async def allocator(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    ctx = runtime.context
    interpretation = state.get("interpretation") or {}
    try:
        result = await ctx.client.call(
            ALLOCATE_SKILL, {"interpretation": interpretation,
                             "operation": state.get("operation", "create")},
            expect=NormalizedServiceIntent, marker=DEPLOYMENT_MARKER,
            correlation_id=state["correlation_id"], thread_id=state["thread_id"],
            idempotency_key=f"{state['thread_id']}:allocate",
            operation=state.get("operation", "create"))
    except WorkerUnreachableError as exc:
        return _unreachable(runtime, state, "allocator", exc)
    except WorkerFailedError as exc:
        return _failed(runtime, state, "allocator", str(exc))
    if _past_deadline(runtime, state):
        return _deadline_passed(runtime, state, "allocator")
    assignment: NormalizedServiceIntent = result.data
    if assignment.type != interpretation.get("service_type"):
        return _failed(runtime, state, "allocator",
                       f"worker failed: allocator — construct {assignment.type} does not match "
                       f"the confirmed interpretation's {interpretation.get('service_type')}")
    wire = assignment.to_wire()
    metrics.record_stage("allocator", "succeeded")
    _emit(runtime, state, "stage", stage="allocator", status=S.ALLOCATED.value, payload=wire)
    verb = "Remove" if state.get("operation") == "remove" else "Deploy"
    _emit(runtime, state, "confirmation_request", stage="allocator", status=S.ALLOCATED.value,
          prompt=f"{verb} this service?", refusable=True)
    return {"assignment": wire, "workflow_status": S.ALLOCATED.value, "pending": None,
            "awaiting": "confirmation_2", "turn_done": True,
            "active_seconds": _active(runtime, state)}


def _unknown_message(ctx: SupervisorContext, state: ServiceRequestState) -> str:
    return (f"outcome unknown: the {ctx.client.transport} transport at {ctx.client.endpoint} "
            "was lost after the submission was sent to the deployer, so this request's outcome "
            f"cannot be observed. The live object is the record: Network/{_network(state)} in "
            f"namespace {INTENT_NAMESPACE} — ask for its status and the tier re-reads it.")


async def deployer(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    ctx = runtime.context
    try:
        check_submission_allowed(state)
    except SubmissionRefusedError as exc:
        return _failed(runtime, state, "deployer", str(exc), outcome="refused")
    operation = state.get("operation", "create")
    key = state.get("submission_key") or f"{state['thread_id']}:{operation}:{_network(state)}"
    first_call = state.get("workflow_status") == S.APPROVED
    base: dict[str, Any] = {"submission_key": key}
    try:
        result = await ctx.client.call(
            DEPLOY_SKILL, {"assignment": state.get("assignment"), "operation": operation,
                           "principal": state["turn_principal"]},
            expect=DeploymentReport, marker=None, correlation_id=state["correlation_id"],
            thread_id=state["thread_id"], idempotency_key=key, operation=operation,
            idempotent=False)
    except WorkerUnreachableError as exc:
        if exc.after_send:
            # The submission may have landed: its outcome cannot be observed (FR-054).
            metrics.record_stage("deployer", "status_unknown")
            message = _unknown_message(ctx, state)
            _log(state, logging.ERROR, "%s", message)
            _emit(runtime, state, "final", status=S.STATUS_UNKNOWN.value, message=message)
            return {**base, "workflow_status": S.STATUS_UNKNOWN.value, "pending": None,
                    "converged": False, "turn_done": True,
                    "active_seconds": _active(runtime, state)}
        return {**base, **_unreachable(runtime, state, "deployer", exc)}
    except WorkerFailedError as exc:
        return {**base, **_failed(runtime, state, "deployer", str(exc))}
    report: DeploymentReport = result.data
    resources = [r.model_dump(mode="json", exclude_none=True) for r in report.resources]
    if first_call:
        _emit(runtime, state, "stage", stage="deployer", status=S.PROVISIONING.value,
              resources=[{"kind": r.kind, "name": r.name} for r in report.resources] or
              [{"kind": "Network", "name": _network(state)}])
    for event in report.progress:  # ready and reason exactly as the deployer read them (AD-62)
        _emit(runtime, state, "progress", status=event.status, resource=event.resource,
              ready=event.ready, reason=event.reason)
    base.update(submitted_resources=resources or state.get("submitted_resources") or [],
                active_seconds=_active(runtime, state))
    removal = report.operation == "remove" or operation == "remove"
    if report.watch == "continue" and report.status == S.PROVISIONING:
        return {**base, "workflow_status": S.PROVISIONING.value, "pending": "deployer"}
    status = report.status
    if status == S.COMPLETED or (status == S.VERIFIED and not removal):
        metrics.record_stage("deployer", "converged")
        _emit(runtime, state, "final", status=S.COMPLETED.value,
              message=report.message or (f"Network/{_network(state)} "
                                         f"{'removed' if removal else 'is Ready'}"))
        return {**base, "workflow_status": S.COMPLETED.value, "pending": None,
                "converged": True, "turn_done": True}
    if status == S.PROVISIONING:
        # A removal still Deleting at the bound: in progress — neither converged nor failed.
        metrics.record_stage("deployer", "in_progress")
        _emit(runtime, state, "final", status=S.PROVISIONING.value,
              message=report.message or (f"removal in progress: Network/{_network(state)} is "
                                         "still being deleted; a status request reports it from "
                                         "the live object"))
        return {**base, "workflow_status": S.PROVISIONING.value, "pending": None,
                "converged": False, "turn_done": True}
    if status == S.STATUS_UNKNOWN:
        metrics.record_stage("deployer", "status_unknown")
        _emit(runtime, state, "final", status=S.STATUS_UNKNOWN.value,
              message=report.message or _unknown_message(ctx, state))
        return {**base, "workflow_status": S.STATUS_UNKNOWN.value, "pending": None,
                "converged": False, "turn_done": True}
    reason = report.message or f"the deployer reported {status}"
    return {**base, **_failed(runtime, state, "deployer", reason,
                              out_of_band=report.out_of_band), "converged": False}
