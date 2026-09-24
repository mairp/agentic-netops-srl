"""The two confirmations, their wording and what a decline does (T101; FR-051, FR-055, FR-056,
FR-069, FR-105, data-model.md §7, AD-58).

* **create**: the interpretation is confirmation 1 (after the mapper), the assignment is
  confirmation 2 (after the allocator); nothing is submitted without the second.
* **remove**: the live object, read by the deployer's read-only ``status`` operation, is
  confirmation 1 — a service modified outside the intent tier says so in that confirmation's
  prompt **and** payload — and "Remove this service?" is confirmation 2; the delete is issued only
  after it.

A decline is a clean terminal state, never an error: for a creation the claims of the request are
released through the deployer's release gate and then the allocator (the :func:`release` node) and
the thread stays amendable; for a removal the object is left untouched. Every confirmation and
decline is audited by :mod:`.audit` with the principal of the request that carried it.

All operator-facing wording comes from the prompt files (:mod:`supervisors.provisioning.prompts`),
in construct vocabulary only, and every confirmation names its construct (FR-026).
"""

from __future__ import annotations

import logging
import re
from typing import Any

from langgraph.graph import END
from langgraph.runtime import Runtime

from common import metrics
from common.exceptions import WorkerFailedError, WorkerUnreachableError
from common.provisioning_states import WorkflowStatus as S
from supervisors.provisioning.graph.audit import emit_audit, network_ref
from supervisors.provisioning.graph.context import (
    ALLOCATE_SKILL,
    DEPLOY_SKILL,
    INTENT_NAMESPACE,
    SupervisorContext,
    construct_of,
    emit,
    log_for,
    network_of,
)
from supervisors.provisioning.graph.state import ServiceRequestState, decision
from supervisors.provisioning.prompts import render

UNREPORTED_CONSTRUCT = "construct not reported"

_CONFIRM = frozenset({"confirm", "confirmed", "yes", "y", "approve", "approved", "ok", "okay",
                      "proceed", "go ahead"})
_DECLINE = frozenset({"decline", "declined", "no", "n", "cancel", "reject", "abort", "stop"})


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


# --------------------------------------------------------------------------------------------------
# the wording and the payloads
# --------------------------------------------------------------------------------------------------


def shown_interpretation(wire: dict[str, Any]) -> dict[str, Any]:
    """The interpretation as the operator is shown it: the arrival vocabulary a migration alias
    records is provenance, never a type, and is not shown (FR-026, FR-085)."""
    return {k: v for k, v in wire.items() if k != "source_service_type"}


def unmatched_statement(default_action: Any) -> str:
    """What happens to traffic no rule matches, in words (FR-041, T111). With no default action
    declared the device's own default ACCEPTS it, and the list is never described as restrictive:
    it acts only on what its rules match. A declared default is the terminal entry at 65535."""
    if default_action == "deny":
        return ("dropped by the declared default action, a terminal deny entry at the reserved "
                "position 65535")
    if default_action == "permit":
        return ("accepted by the declared default action, a terminal permit entry at the "
                "reserved position 65535")
    return ("accepted by the device's own default, because no default action is declared: the "
            "list acts only on the traffic its rules match")


def interpretation_prompt(wire: dict[str, Any]) -> str:
    """The first confirmation. When the request carries an access list it states the evaluation
    order (ascending priority number, first match wins), the usable range 1-65534 and what
    happens to unmatched traffic (FR-039, FR-041)."""
    prompt = render("confirm-interpretation", construct=wire.get("service_type"))
    acl = wire.get("acl")
    if isinstance(acl, dict):
        default = acl.get("default_action")
        if default is None and acl.get("unmatched_traffic") in ("permit", "deny"):
            default = acl.get("unmatched_traffic")
        prompt += " " + render("acl-evaluation", unmatched=unmatched_statement(default))
    return prompt


def assignment_prompt(wire: dict[str, Any]) -> str:
    return render("confirm-assignment", construct=wire.get("type"),
                  network=f"migr-{wire.get('serviceId')}")


def out_of_band_statement(network: str, out_of_band: str | None) -> str | None:
    """The FR-105 statement a removal's first confirmation carries, or None."""
    if out_of_band == "modified":
        return render("out-of-band-modified", network=network)
    return None


def removal_prompt_1(network: str, construct: str | None, live: str,
                     out_of_band: str | None) -> str:
    statement = out_of_band_statement(network, out_of_band)
    prompt = render("confirm-removal-1", construct=construct or UNREPORTED_CONSTRUCT,
                    network=network, namespace=INTENT_NAMESPACE, live=live).rstrip()
    return f"{statement} {prompt}" if statement else prompt


def removal_prompt_2(network: str, construct: str | None) -> str:
    return render("confirm-removal-2", network=network,
                  construct=construct or UNREPORTED_CONSTRUCT)


def _stage_of(state: ServiceRequestState, which: str) -> str:
    if state.get("operation") == "remove":
        return "deployer"
    return "mapper" if which == "confirmation_1" else "allocator"


# --------------------------------------------------------------------------------------------------
# nodes
# --------------------------------------------------------------------------------------------------


async def await_decision(state: ServiceRequestState,
                         runtime: Runtime[SupervisorContext]) -> dict:
    """A reply that is not a decision while one is awaited: ask again, change nothing."""
    first = state.get("awaiting") == "confirmation_1"
    construct = construct_of(state) or UNREPORTED_CONSTRUCT
    if state.get("operation") == "remove":
        what = (f"the removal of the {construct} service Network/{network_of(state)}"
                + ("" if first else " (nothing is deleted without this confirmation)"))
    else:
        what = (f"the {construct} interpretation" if first else
                f"the {construct} assignment (nothing is submitted without this confirmation)")
    emit(runtime, state, "confirmation_request", stage=_stage_of(state, state["awaiting"]),
         status=state.get("workflow_status") or S.MAPPED.value,
         prompt=render("awaiting", what=what))
    return {"turn_done": True, "turn_consumed": True}


async def decide(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    which = state["awaiting"]
    decided = parse_decision(state["turn_text"]) or "decline"
    record = decision(decided, state["turn_principal"])  # this request's principal (FR-102)
    removal = state.get("operation") == "remove"
    stage = _stage_of(state, which)
    network = network_of(state)
    construct = construct_of(state)
    updates: dict[str, Any] = {which: record, "awaiting": None, "turn_consumed": True}
    # T135: agentic_netops_agent_confirmations_total{confirmation=first|second,decision}.
    metrics.record_confirmation(which, "confirmed" if decided == "confirm" else "declined")
    if decided == "confirm":
        emit_audit(runtime, state, "confirm", stage=stage, resources=[network_ref(network)],
                   reason=f"{which} of the {construct or UNREPORTED_CONSTRUCT} "
                          f"{'removal' if removal else 'request'}")
        if which == "confirmation_1" and removal:
            # No worker in between: the second confirmation of a removal is asked at once.
            emit(runtime, state, "confirmation_request", stage="deployer",
                 status=state.get("workflow_status") or S.VALIDATED.value,
                 prompt=removal_prompt_2(network, construct), refusable=True)
            updates.update(awaiting="confirmation_2", turn_done=True, next=END)
        elif which == "confirmation_1":
            updates.update(pending="allocator", next="supervisor")
        else:
            updates.update(pending="deployer", next="supervisor",
                           workflow_status=S.APPROVED.value)
            emit(runtime, state, "status", status=S.APPROVED.value, stage="supervisor")
        return updates
    emit_audit(runtime, state, "decline", stage=stage,
               reason=f"declined at {which} of Network/{network}")
    metrics.record_stage(stage, "declined")
    point = "interpretation" if which == "confirmation_1" else "assignment"
    updates.update(pending=None, workflow_status=S.FAILED.value, decline_point=which)
    if removal:
        point = "first confirmation" if which == "confirmation_1" else "second confirmation"
        emit(runtime, state, "final", status=S.FAILED.value,
             message=render("declined-removal", point=point, network=network,
                            construct=construct or UNREPORTED_CONSTRUCT))
        updates.update(turn_done=True, next=END)
        return updates
    updates.update(next="release", decline_point=point)
    return updates


def _names(values: Any) -> list[str]:
    return [v for v in values or [] if isinstance(v, str) and v]


async def release_provisional(state: ServiceRequestState,
                              runtime: Runtime[SupervisorContext]) -> tuple[str, bool, list[str]]:
    """Release this request's provisional claims: the deployer's release gate names which
    correlation identifiers hold no ``Network`` (it alone may read one), and the allocator deletes
    the claims labelled with those — never any other (FR-056, FR-075, FR-109). Returns the
    operator sentence, whether the release was clean, and the released claim names."""
    ctx = runtime.context
    cid = state["correlation_id"]
    thread = state["thread_id"]
    claimed = bool(state.get("allocated"))
    released: list[str] = []
    try:
        gate = await ctx.client.call(
            DEPLOY_SKILL, {"operation": "release_gate", "correlation_ids": [cid]},
            expect=None, marker=None, correlation_id=cid, thread_id=thread,
            idempotency_key=f"{thread}:release_gate", operation="release_gate")
        answer = gate.data if isinstance(gate.data, dict) else {}
        releasable = [c for c in _names(answer.get("releasable")) if c == cid]
        refused = [r for r in answer.get("refused") or [] if isinstance(r, dict)]
        if claimed and releasable:
            result = await ctx.client.call(
                ALLOCATE_SKILL, {"operation": "release", "correlation_ids": releasable},
                expect=None, marker=None, correlation_id=cid, thread_id=thread,
                idempotency_key=f"{thread}:release", operation="release")
            data = result.data if isinstance(result.data, dict) else {}
            released = _names(data.get("released"))
        if not claimed:
            what = "nothing had been claimed, so nothing was released"
        elif released:
            what = "released " + ", ".join(released)
        elif refused:
            held = ", ".join(f"Network/{r.get('network')}" for r in refused)
            what = (f"nothing was released: the identifiers of correlation id {cid} are held by "
                    f"{held}, which the release gate refused to free")
        elif releasable:
            what = "no claim carried this request's correlation id, so nothing was released"
        else:
            what = "nothing was released: the release gate named nothing releasable"
        clean = not refused
    except (WorkerUnreachableError, WorkerFailedError) as exc:
        log_for(state, logging.WARNING, "release of provisional claims did not complete: %s", exc)
        what = (f"the release did not complete ({exc}); any claim labelled with correlation id "
                f"{cid} is kept until a release on this thread succeeds")
        clean = False
    return what, clean, released


def release_updates(state: ServiceRequestState, clean: bool, released: list[str]) -> dict[str, Any]:
    updates: dict[str, Any] = {
        "claimed_ids": [] if clean else list(state.get("claimed_ids") or []),
        "released_ids": list(state.get("released_ids") or []) + [{"name": n} for n in released],
    }
    if clean:
        updates["allocated"] = False
    return updates


async def release(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> dict:
    """After a decline of a creation: release the request's provisional claims (see
    :func:`release_provisional`), then end the turn with the decline stated."""
    what, clean, released = await release_provisional(state, runtime)
    emit(runtime, state, "final", status=S.FAILED.value,
         message=render("declined", point=state.get("decline_point") or "confirmation",
                        construct=construct_of(state) or UNREPORTED_CONSTRUCT, released=what))
    return {"turn_done": True, **release_updates(state, clean, released)}


__all__ = [
    "UNREPORTED_CONSTRUCT",
    "assignment_prompt",
    "await_decision",
    "decide",
    "interpretation_prompt",
    "out_of_band_statement",
    "parse_decision",
    "release",
    "release_provisional",
    "release_updates",
    "removal_prompt_1",
    "removal_prompt_2",
    "shown_interpretation",
    "unmatched_statement",
]
