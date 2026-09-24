"""The supervisor graph's nodes and the routing of each conditional edge (T085, T101; FR-050 to
FR-057, FR-069, FR-073, FR-074, FR-092, FR-105, data-model.md §7, §16, §17, §25, AD-49, AD-54,
AD-58, AD-59, AD-62, AD-63).

One request turn (one POST) runs ``intake → guard → supervisor ⇄ {mapper, allocator, lookup,
deployer, decide} → … → END``. The router (:func:`plan_next`) is a pure function of the state,
the bounds and the clock, so every conditional edge is unit-testable on its own:

* ``guard``      → ``supervisor`` | END (refused: the US6 guards classify every request before
  any model or worker call; an unsafe one never reaches either — or a removal that names no
  service, answered with what to name);
* ``supervisor`` → ``mapper`` | ``allocator`` | ``lookup`` | ``deployer`` | ``decide`` |
  ``await`` | ``inform`` | ``bounded_exit`` | END;
* ``decide``     → ``supervisor`` (a confirm that moves the pipeline on) | ``release`` (a decline
  of a creation) | END (a removal's first confirm, or its decline).

The three request shapes (:mod:`.confirmations` holds the confirmations and the decline path):

* **create** — ``mapper`` → confirmation 1 → ``allocator`` → confirmation 2 → ``deployer``
  (``create``). A decline at either → ``release`` (deployer ``release_gate``, then allocator
  ``release`` of what the gate names) → END; the thread stays amendable.
* **remove** — the text names ``migr-<sid>``, the bare service id, or a service created on this
  thread: ``lookup`` (deployer ``status``, read-only) → confirmation 1 (the live state, and a
  modification outside the tier stated in its prompt and payload) → confirmation 2 → ``deployer``
  (``remove``). Nothing is deleted on the turn that reads the object.
* **status** — a question naming a service: ``lookup`` (deployer ``status``) answers it, no
  confirmation, no pipeline, nothing changed (FR-057, FR-069).

Every ``status`` request carries ``tier_removed`` from the durable registry of the removals the
tier issued (:mod:`.registry`). The supervisor audits only confirm, decline and refuse
(:mod:`.audit`); submission, removal and out-of-band are the deployer's.

Bounds (data-model.md §25): at most ``SUPERVISOR_MAX_ITERATIONS`` worker dispatches per request
turn and ``SUPERVISOR_REQUEST_DEADLINE_SECONDS`` of request time, operator confirmation time
excluded. Either ends the turn with an explicit final ``FAILED`` chunk naming the bound.
"""

from __future__ import annotations

import asyncio
import logging
import re
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
from common.guards.refusals import CONSTRUCT_SUMMARY, CONSTRUCTS, SUBMISSION, RefusalClass
from common.provisioning_states import ALL_STATUSES
from common.provisioning_states import WorkflowStatus as S
from common.schemas.interpretation import MARKER as MAPPED_MARKER
from common.schemas.interpretation import Interpretation
from common.schemas.normalized_service_intent import MARKER as DEPLOYMENT_MARKER
from common.schemas.normalized_service_intent import NormalizedServiceIntent
from common.schemas.stream import DeploymentReport
from supervisors.provisioning.graph.audit import emit_audit
from supervisors.provisioning.graph.confirmations import (
    UNREPORTED_CONSTRUCT,
    assignment_prompt,
    await_decision,
    decide,
    interpretation_prompt,
    out_of_band_statement,
    parse_decision,
    release,
    release_provisional,
    release_updates,
    removal_prompt_1,
    shown_interpretation,
)
from supervisors.provisioning.graph.context import (
    ALLOCATE_SKILL,
    DEPLOY_SKILL,
    INTENT_NAMESPACE,
    MAP_SKILL,
    NETWORK_API_VERSION,
    SupervisorContext,
    construct_of,
    emit,
    log_for,
    network_of,
)
from supervisors.provisioning.graph.state import Bounds, ServiceRequestState
from supervisors.provisioning.prompts import render

__all__ = [
    "ALLOCATE_SKILL",
    "DEPLOY_SKILL",
    "INTENT_NAMESPACE",
    "MAP_SKILL",
    "NETWORK_API_VERSION",
    "Bounds",
    "SupervisorContext",
    "await_decision",
    "check_submission_allowed",
    "decide",
    "named_service",
    "parse_decision",
    "plan_next",
    "release",
    "route_after_decide",
    "route_after_guard",
    "route_from_supervisor",
]

_REMOVAL = re.compile(r"\b(?:remove|delete|tear down|teardown|decommission|destroy)\b",
                      re.IGNORECASE)
_NETWORK_NAME = re.compile(r"\bmigr-([0-9a-f]{15})\b")
_SERVICE_ID = re.compile(r"(?<![0-9a-z-])([0-9a-f]{15})(?![0-9a-z-])")
_STATUS_ASK = re.compile(r"\b(?:status|state|converged|ready|health|healthy|progress)\b",
                         re.IGNORECASE)
_OUT_OF_BAND = frozenset({"modified", "deleted"})


# --------------------------------------------------------------------------------------------------
# pure helpers: request shape, routing
# --------------------------------------------------------------------------------------------------


def operation_of(text: str) -> str:
    return "remove" if _REMOVAL.search(text) else "create"


def named_service(text: str) -> str | None:
    """The ``Network`` a request names: ``migr-<15 hex>``, or a bare 15-hex service id."""
    folded = text.lower()
    match = _NETWORK_NAME.search(folded) or _SERVICE_ID.search(folded)
    return f"migr-{match.group(1)}" if match else None


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
    status_query = state.get("turn_kind") == "status"
    starting = not state.get("turn_consumed") and (
        state.get("turn_class") == "provisionable" or status_query)
    if pending or starting:
        if elapsed > bounds.request_deadline_seconds:
            return "bounded_exit", {"exit_reason": "deadline"}
        if int(state.get("iteration_count") or 0) >= bounds.max_iterations:
            return "bounded_exit", {"exit_reason": "iterations"}
        first = "lookup" if status_query or state.get("operation") == "remove" else "mapper"
        target = pending or first
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
# helpers
# --------------------------------------------------------------------------------------------------


def _active(runtime: Runtime[SupervisorContext], state: ServiceRequestState) -> float:
    return _elapsed(state, runtime.context.clock())


def _known_construct(state: ServiceRequestState, network: str) -> str | None:
    for service in reversed(state.get("created") or []):
        if service.get("network") == network:
            return service.get("construct")
    return None


def _last_created(state: ServiceRequestState) -> str | None:
    created = state.get("created") or []
    return created[-1].get("network") if created else None


# --------------------------------------------------------------------------------------------------
# nodes
# --------------------------------------------------------------------------------------------------


async def intake(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    now = runtime.context.clock()
    updates: dict[str, Any] = {
        "turn_started": now, "iteration_count": 0, "turn_done": False, "turn_consumed": False,
        "turn_class": None, "turn_kind": None, "turn_target": None, "next": "",
        "exit_reason": None,
    }
    if state.get("new_thread"):
        updates.update(
            principal=state["turn_principal"], original_text=state["turn_text"],
            workflow_status=S.RECEIVED_REQUEST.value, confirmation_1=None, confirmation_2=None,
            claimed_ids=[], released_ids=[], interpretation=None, assignment=None,
            submitted_resources=[], operation=operation_of(state["turn_text"]), pending=None,
            awaiting=None, submission_key=None, converged=False, active_seconds=0.0,
            deadline=None, target=None, target_construct=None, allocated=False,
            decline_point=None, created=[])
    updates["active_base"] = float(updates.get("active_seconds", state.get("active_seconds"))
                                   or 0.0)
    status = updates.get("workflow_status") or state.get("workflow_status") or "RECEIVED_REQUEST"
    emit(runtime, state, "status", status=status, stage="supervisor")
    return updates


def _refuse(runtime: Runtime[SupervisorContext], state: ServiceRequestState, message: str,
            reason: str, request_class: str) -> dict:
    emit_audit(runtime, state, "refuse", stage="supervisor", reason=reason)
    metrics.record_stage("supervisor", "refused")
    emit(runtime, state, "final", status=S.FAILED.value, message=message)
    updates: dict[str, Any] = {"next": "refused", "turn_done": True, "turn_consumed": True,
                               "turn_class": request_class}
    if state.get("new_thread"):
        updates["workflow_status"] = S.FAILED.value
    return updates


def _new_request(runtime: Runtime[SupervisorContext], state: ServiceRequestState,
                 operation: str) -> dict[str, Any]:
    """A new request on this thread: the pipeline starts over (data-model.md §7)."""
    now = runtime.context.clock()
    return dict(
        original_text=state["turn_text"], workflow_status=S.VALIDATED.value,
        operation=operation, confirmation_1=None, confirmation_2=None, interpretation=None,
        assignment=None, submitted_resources=[], submission_key=None, converged=False,
        active_seconds=0.0, active_base=0.0, turn_started=now, target=None,
        target_construct=None, decline_point=None,
        deadline=datetime.fromtimestamp(
            datetime.now(UTC).timestamp() + runtime.context.settings.request_deadline_seconds,
            UTC).isoformat())


async def guard(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    """The US6 guards, in front of everything: classify; an unsafe request is refused here.
    Then the request's shape: a creation, a removal of a named service, or a status question."""
    text = state["turn_text"]
    verdict = classify(text)
    named = named_service(text)
    in_flight = state.get("awaiting") or state.get("pending")
    request_class = verdict.request_class
    if request_class == RequestClass.UNSUPPORTED_OR_UNSAFE:
        # A request about a named service names no construct, and is not a construct request:
        # only the unsupported-construct rule may be set aside for it, never a safety rule.
        if not (named and verdict.refusal_class == RefusalClass.UNSUPPORTED_CONSTRUCT):
            refusal = verdict.refusal
            message = refusal.message if refusal else "Refused."
            return _refuse(runtime, state, message, f"{verdict.refusal_class}: {message}",
                           request_class.value)
        request_class = RequestClass.INFORMATIONAL
    updates: dict[str, Any] = {"turn_class": request_class.value, "next": "supervisor"}
    if in_flight:
        return updates
    removal = bool(_REMOVAL.search(text))
    if removal and (named or request_class == RequestClass.PROVISIONABLE):
        target = named or _last_created(state)
        if target is None:
            metrics.record_stage("supervisor", "clarification")
            emit(runtime, state, "final", status=S.RECEIVED_REQUEST.value,
                 message=render("removal-target-missing"))
            return {**updates, "turn_done": True, "turn_consumed": True}
        updates.update(_new_request(runtime, state, "remove"), target=target,
                       target_construct=_known_construct(state, target),
                       turn_class=RequestClass.PROVISIONABLE.value, turn_kind="remove")
        emit(runtime, state, "status", status=S.VALIDATED.value, stage="supervisor")
        return updates
    if request_class != RequestClass.PROVISIONABLE:
        target = named or (_last_created(state) if _STATUS_ASK.search(text) else None)
        if target is not None:
            updates.update(turn_kind="status", turn_target=target)
        return updates
    updates.update(_new_request(runtime, state, "create"), turn_kind="create")
    emit(runtime, state, "status", status=S.VALIDATED.value, stage="supervisor")
    return updates


async def supervisor(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    now = runtime.context.clock()
    target, updates = plan_next(state, Bounds.from_settings(runtime.context.settings), now)
    updates["next"] = target
    updates["active_seconds"] = _elapsed(state, now)
    return updates


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
    return render("informational-fallback", constructs=listed, submission=SUBMISSION)


def inform_instructions() -> str:
    """The informational system prompt (``prompts/informational.md``)."""
    return render("informational")


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
        prompt = build_prompt(inform_instructions(), operator_text=state["turn_text"])
        messages = [{"role": "system", "content": prompt.system},
                    {"role": "user", "content": prompt.data}]
        try:
            answer = redact(_content(await asyncio.to_thread(llm.complete, messages)))
        except EndpointError as exc:
            metrics.record_stage("supervisor", "failed")
            emit(runtime, state, "error", stage="supervisor", status=S.FAILED.value,
                 reason=f"model endpoint unavailable: {exc}", retryable=True)
            return {"turn_done": True}
    metrics.record_stage("supervisor", "succeeded")
    emit(runtime, state, "final", status=final_status, message=answer)
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
        message += (f"; the submitted Network/{network_of(state)} in {INTENT_NAMESPACE} is the "
                    "record — ask for its status")
    log_for(state, logging.WARNING, "%s", message)
    metrics.record_stage("supervisor", "failed")
    emit(runtime, state, "final", status=S.FAILED.value, message=message)
    return {"workflow_status": S.FAILED.value, "pending": None, "awaiting": None,
            "turn_done": True, "active_seconds": _active(runtime, state)}


def _past_deadline(runtime: Runtime[SupervisorContext], state: ServiceRequestState) -> bool:
    return _active(runtime, state) > runtime.context.settings.request_deadline_seconds


def _deadline_passed(runtime: Runtime[SupervisorContext], state: ServiceRequestState,
                     stage: str) -> dict:
    """An answer that arrives after the deadline is not shown for confirmation: the router
    ends the turn with the bounded exit (the stage stays named as the one that ran late)."""
    log_for(state, logging.WARNING, "%s answered after the request deadline", stage)
    return {"pending": stage, "active_seconds": _active(runtime, state)}


def _unreachable(runtime: Runtime[SupervisorContext], state: ServiceRequestState, stage: str,
                 exc: WorkerUnreachableError) -> dict:
    metrics.record_stage(stage, "unreachable")
    log_for(state, logging.WARNING, "%s (%s)", exc, exc.cause)
    emit(runtime, state, "error", stage=stage, status=S.FAILED.value, reason=str(exc),
         retryable=True)
    # The thread stays resumable: the stage stays pending, the status unchanged.
    return {"turn_done": True, "active_seconds": _active(runtime, state)}


def _failed(runtime: Runtime[SupervisorContext], state: ServiceRequestState, stage: str,
            reason: str, outcome: str = "failed", out_of_band: str | None = None,
            message: str | None = None) -> dict:
    metrics.record_stage(stage, outcome)
    log_for(state, logging.WARNING, "%s", reason)
    emit(runtime, state, "error", stage=stage, status=S.FAILED.value, reason=reason,
         retryable=False, out_of_band=out_of_band)
    emit(runtime, state, "final", status=S.FAILED.value, message=message or reason)
    return {"workflow_status": S.FAILED.value, "pending": None, "awaiting": None,
            "turn_done": True, "active_seconds": _active(runtime, state)}


async def mapper(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    ctx = runtime.context
    kept, _found = neutralize(state.get("original_text") or state["turn_text"], "operator")
    try:
        result = await ctx.client.call(
            MAP_SKILL, {"text": redact(kept), "operation": "create"},
            text=redact(kept), expect=Interpretation, marker=MAPPED_MARKER,
            correlation_id=state["correlation_id"], thread_id=state["thread_id"],
            idempotency_key=f"{state['thread_id']}:map", operation="create")
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
        # Complete, self-explanatory causes: emitted verbatim; nothing is claimed (the
        # allocator is never called) and nothing is submitted.
        causes = list(interpretation.unsupported_properties)
        emit_audit(runtime, state, "refuse", stage="mapper", reason="; ".join(causes))
        return {**_failed(runtime, state, "mapper", "; ".join(causes), outcome="refused",
                          message=render("refused", causes="\n".join(causes))),
                "interpretation": interpretation.to_wire()}
    if interpretation.missing_fields:
        metrics.record_stage("mapper", "clarification")
        emit(runtime, state, "final", status=S.RECEIVED_REQUEST.value,
             message=render("clarification", fields=", ".join(interpretation.missing_fields)))
        return {"workflow_status": S.RECEIVED_REQUEST.value, "pending": None,
                "turn_done": True, "active_seconds": active}
    wire = interpretation.to_wire()
    metrics.record_stage("mapper", "succeeded")
    emit(runtime, state, "stage", stage="mapper", status=S.MAPPED.value,
         payload=shown_interpretation(wire))
    emit(runtime, state, "confirmation_request", stage="mapper", status=S.MAPPED.value,
         prompt=interpretation_prompt(wire), refusable=True)
    return {"interpretation": wire, "workflow_status": S.MAPPED.value, "pending": None,
            "awaiting": "confirmation_1", "turn_done": True, "active_seconds": active}


async def allocator(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    # From the first call on, claims may exist under this correlation id until released.
    return {**await _allocate(state, runtime), "allocated": True}


async def _allocate(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    ctx = runtime.context
    interpretation = state.get("interpretation") or {}
    try:
        result = await ctx.client.call(
            ALLOCATE_SKILL, {"operation": "create", "interpretation": interpretation},
            expect=NormalizedServiceIntent, marker=DEPLOYMENT_MARKER,
            correlation_id=state["correlation_id"], thread_id=state["thread_id"],
            idempotency_key=f"{state['thread_id']}:allocate", operation="create")
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
    emit(runtime, state, "stage", stage="allocator", status=S.ALLOCATED.value, payload=wire)
    emit(runtime, state, "confirmation_request", stage="allocator", status=S.ALLOCATED.value,
         prompt=assignment_prompt(wire), refusable=True)
    return {"assignment": wire, "workflow_status": S.ALLOCATED.value, "pending": None,
            "awaiting": "confirmation_2", "turn_done": True,
            "claimed_ids": [{"correlation_id": state["correlation_id"]}],
            "active_seconds": _active(runtime, state)}


# --------------------------------------------------------------------------------------------------
# lookup: the deployer's read-only status of a named service (status question, removal preflight)
# --------------------------------------------------------------------------------------------------


def _status_answer(data: Any) -> dict[str, Any]:
    """The deployer's ``status`` answer, read leniently (its extended report fields — ``state``,
    ``out_of_band``, ``message`` — are optional to this reader) and checked where it matters."""
    data = data if isinstance(data, dict) else {}
    status = data.get("status")
    oob = data.get("out_of_band")
    live = data.get("live") if isinstance(data.get("live"), dict) else {}
    labels = next((x for x in (data.get("labels"), live.get("labels")) if isinstance(x, dict)), {})
    construct = (data.get("construct") or data.get("service_type")
                 or labels.get("agentic-netops.io/service-type"))
    return {
        "status": status if status in ALL_STATUSES else S.STATUS_UNKNOWN.value,
        "state": data.get("state") if isinstance(data.get("state"), str) else None,
        "out_of_band": oob if oob in _OUT_OF_BAND else None,
        "message": data.get("message") if isinstance(data.get("message"), str) else None,
        "construct": construct if construct in CONSTRUCTS else None,
        "progress": [p for p in data.get("progress") or [] if isinstance(p, dict)],
    }


async def lookup(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    """Ask the deployer for the live object (read-only). A status question is answered here and
    ends; a removal gets its first confirmation from what the live object says (FR-105, AD-58)."""
    ctx = runtime.context
    status_query = state.get("turn_kind") == "status"
    network = str(state.get("turn_target") if status_query else state.get("target"))
    tier_removed = bool(ctx.registry is not None and await ctx.registry.removed(network))
    try:
        result = await ctx.client.call(
            DEPLOY_SKILL, {"operation": "status", "network": network,
                           "tier_removed": tier_removed, "principal": state["turn_principal"]},
            expect=None, marker=None, correlation_id=state["correlation_id"],
            thread_id=state["thread_id"], idempotency_key=f"{state['thread_id']}:status",
            operation="status")
    except WorkerUnreachableError as exc:
        updates = _unreachable(runtime, state, "deployer", exc)
        return {**updates, "pending": None} if status_query else updates
    except WorkerFailedError as exc:
        if status_query:
            metrics.record_stage("supervisor", "failed")
            emit(runtime, state, "error", stage="deployer", status=S.FAILED.value,
                 reason=str(exc), retryable=False)
            return {"pending": None, "turn_done": True}
        return _failed(runtime, state, "deployer", str(exc))
    answer = _status_answer(result.data)
    construct = (answer["construct"] or _known_construct(state, network)
                 or (await ctx.registry.construct(network) if ctx.registry is not None else None))
    live = answer["message"] or f"Network/{network} is {answer['state'] or answer['status']}."
    payload: dict[str, Any] = {
        "network": network, "namespace": INTENT_NAMESPACE,
        "construct": construct or UNREPORTED_CONSTRUCT, "status": answer["status"],
        "state": answer["state"], "outOfBand": answer["out_of_band"], "tierRemoved": tier_removed,
        "message": live,
    }
    resource = f"Network/{network}"
    if status_query:
        metrics.record_stage("supervisor", "succeeded")
        emit(runtime, state, "stage", stage="deployer", status=answer["status"],
             resource=resource, out_of_band=answer["out_of_band"], payload=payload, message=live)
        for event in answer["progress"]:  # ready and reason as the deployer read them (AD-62)
            if (event.get("status") in ALL_STATUSES and event.get("resource")
                    and event.get("ready") in (None, "True", "False", "Unknown")):
                emit(runtime, state, "progress", status=event["status"],
                     resource=event["resource"], ready=event.get("ready"),
                     reason=event.get("reason"))
        emit(runtime, state, "final", status=answer["status"], message=live)
        return {"pending": None, "turn_done": True, "active_seconds": _active(runtime, state)}
    if _past_deadline(runtime, state):
        return _deadline_passed(runtime, state, "lookup")
    if answer["state"] in ("absent", "removing"):
        # Nothing to delete (gone, or already being deleted): the removal is not asked for.
        reason = f"removal of {resource} not started: {live}"
        emit(runtime, state, "stage", stage="deployer", status=answer["status"],
             resource=resource, out_of_band=answer["out_of_band"], payload=payload, message=live)
        emit_audit(runtime, state, "refuse", stage="deployer", reason=reason)
        return _failed(runtime, state, "deployer", reason, outcome="refused")
    statement = out_of_band_statement(network, answer["out_of_band"])
    payload["statement"] = statement
    metrics.record_stage("deployer", "succeeded")
    emit(runtime, state, "stage", stage="deployer", status=S.VALIDATED.value, resource=resource,
         out_of_band=answer["out_of_band"], payload=payload, message=statement or live)
    emit(runtime, state, "confirmation_request", stage="deployer", status=S.VALIDATED.value,
         prompt=removal_prompt_1(network, construct, live, answer["out_of_band"]),
         refusable=True)
    return {"target_construct": construct, "workflow_status": S.VALIDATED.value,
            "pending": None, "awaiting": "confirmation_1", "turn_done": True,
            "active_seconds": _active(runtime, state)}


# --------------------------------------------------------------------------------------------------
# deployer: create or remove, after the second confirmation only
# --------------------------------------------------------------------------------------------------


def _unknown_message(ctx: SupervisorContext, state: ServiceRequestState) -> str:
    return (f"outcome unknown: the {ctx.client.transport} transport at {ctx.client.endpoint} "
            "was lost after the submission was sent to the deployer, so this request's outcome "
            f"cannot be observed. The live object is the record: Network/{network_of(state)} in "
            f"namespace {INTENT_NAMESPACE} — ask for its status and the tier re-reads it.")


async def deployer(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    ctx = runtime.context
    try:
        check_submission_allowed(state)
    except SubmissionRefusedError as exc:
        return _failed(runtime, state, "deployer", str(exc), outcome="refused")
    operation = state.get("operation", "create")
    removal = operation == "remove"
    network = network_of(state)
    key = state.get("submission_key") or f"{state['thread_id']}:{operation}:{network}"
    first_call = state.get("workflow_status") == S.APPROVED
    base: dict[str, Any] = {"submission_key": key}
    second = dict(state.get("confirmation_2") or {})
    if removal:
        payload: dict[str, Any] = {"operation": "remove", "network": network,
                                   "principal": state["turn_principal"], "confirmation_2": second}
    else:
        payload = {"operation": "create", "assignment": state.get("assignment"),
                   "principal": state["turn_principal"], "confirmation_2": second}
    if removal and first_call and ctx.registry is not None:
        # Recorded before the delete is sent: a delete whose answer is lost is still the tier's.
        await ctx.registry.record_removal(network, correlation_id=state["correlation_id"],
                                          principal=state["turn_principal"])
    if not removal and first_call and ctx.registry is not None:
        await ctx.registry.record_service(network, construct=construct_of(state) or "",
                                          correlation_id=state["correlation_id"])
    if not removal and first_call:
        created = [s for s in state.get("created") or [] if s.get("network") != network]
        base["created"] = [*created, {"network": network,
                                      "construct": construct_of(state) or ""}]
    try:
        result = await ctx.client.call(
            DEPLOY_SKILL, payload, expect=DeploymentReport, marker=None,
            correlation_id=state["correlation_id"], thread_id=state["thread_id"],
            idempotency_key=key, operation=operation, idempotent=False)
    except WorkerUnreachableError as exc:
        if exc.after_send:
            # The submission may have landed: its outcome cannot be observed (FR-054).
            metrics.record_stage("deployer", "status_unknown")
            message = _unknown_message(ctx, state)
            log_for(state, logging.ERROR, "%s", message)
            emit(runtime, state, "final", status=S.STATUS_UNKNOWN.value, message=message)
            return {**base, "workflow_status": S.STATUS_UNKNOWN.value, "pending": None,
                    "converged": False, "turn_done": True,
                    "active_seconds": _active(runtime, state)}
        if removal and first_call and ctx.registry is not None:
            await ctx.registry.forget_removal(network)  # provably never sent
        base.pop("created", None)
        return {**base, **_unreachable(runtime, state, "deployer", exc)}
    except WorkerFailedError as exc:
        if removal and first_call and ctx.registry is not None:
            await ctx.registry.forget_removal(network)
        return {**base, **_failed(runtime, state, "deployer", str(exc))}
    report: DeploymentReport = result.data
    if report.retryable and report.status == S.FAILED and not report.submitted:
        # A dependency of the deployer (the cluster API, its admission webhook, the translator
        # sidecar) is unavailable: nothing was applied, so nothing is rolled back and the claims
        # stay provisional — the thread is resumable exactly as for an unreachable worker (AD-52).
        if removal and first_call and ctx.registry is not None:
            await ctx.registry.forget_removal(network)
        base.pop("created", None)
        metrics.record_stage("deployer", "unreachable")
        reason = report.message or f"deployer dependency unavailable: {report.dependency}"
        log_for(state, logging.WARNING, "%s", reason)
        emit(runtime, state, "error", stage="deployer", status=S.FAILED.value, reason=reason,
             retryable=True)
        return {**base, "turn_done": True, "active_seconds": _active(runtime, state)}
    resources = [r.model_dump(mode="json", exclude_none=True) for r in report.resources]
    if first_call:
        emit(runtime, state, "stage", stage="deployer", status=S.PROVISIONING.value,
             resources=[{"kind": r.kind, "name": r.name} for r in report.resources] or
             [{"kind": "Network", "name": network}])
    for event in report.progress:  # ready and reason exactly as the deployer read them (AD-62)
        emit(runtime, state, "progress", status=event.status, resource=event.resource,
             ready=event.ready, reason=event.reason)
    base.update(submitted_resources=resources or state.get("submitted_resources") or [],
                active_seconds=_active(runtime, state))
    removal = report.operation == "remove" or removal
    if report.watch == "continue" and report.status == S.PROVISIONING:
        return {**base, "workflow_status": S.PROVISIONING.value, "pending": "deployer"}
    status = report.status
    if status == S.COMPLETED or (status == S.VERIFIED and not removal):
        metrics.record_stage("deployer", "converged")
        emit(runtime, state, "final", status=S.COMPLETED.value,
             message=report.message or (f"Network/{network} "
                                        f"{'removed' if removal else 'is Ready'}"))
        return {**base, "workflow_status": S.COMPLETED.value, "pending": None,
                "converged": True, "turn_done": True}
    if status == S.PROVISIONING:
        # A removal still Deleting at the bound: in progress — neither converged nor failed.
        metrics.record_stage("deployer", "in_progress")
        emit(runtime, state, "final", status=S.PROVISIONING.value,
             message=report.message or (f"removal in progress: Network/{network} is "
                                        "still being deleted; a status request reports it from "
                                        "the live object"))
        return {**base, "workflow_status": S.PROVISIONING.value, "pending": None,
                "converged": False, "turn_done": True}
    if status == S.STATUS_UNKNOWN:
        metrics.record_stage("deployer", "status_unknown")
        emit(runtime, state, "final", status=S.STATUS_UNKNOWN.value,
             message=report.message or _unknown_message(ctx, state))
        return {**base, "workflow_status": S.STATUS_UNKNOWN.value, "pending": None,
                "converged": False, "turn_done": True}
    # A terminal failure — a degraded fabric's missing invariant, the convergence timeout — is
    # reported as the deployer read it from the Network, never guessed beforehand.
    reason = report.message or f"the deployer reported {status}"
    extra: dict[str, Any] = {}
    if not removal and (not report.submitted or report.rolled_back):
        # Refused before apply, or rolled back: the request's claims are provisional unless the
        # release gate finds a Network still carrying its correlation id (FR-056, AD-32).
        what, clean, released = await release_provisional(state, runtime)
        reason = f"{reason}; {what}"
        extra = release_updates(state, clean, released)
    return {**base, **_failed(runtime, state, "deployer", reason,
                              out_of_band=report.out_of_band), "converged": False, **extra}
