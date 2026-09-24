"""The supervisor's audit events (T101; FR-078, FR-102, data-model.md §16, AD-18, AD-59).

The supervisor decides three audit events and emits exactly those: **confirm**, **decline** and
**refuse**. A submission, a removal and an out-of-band detection are the deployer's — it decided
them, so it alone emits them — and this module refuses to emit one, so that no event is emitted by
two processes and SC-030's equal-count reconciliation holds.

Every event is a **span event on the request trace** (``audit.<event_type>``) through
:func:`common.tracing.emit_span_event` — the process's one exporter, whose analytics store keeps
the record. It carries the principal authenticated on *this* request, the thread's correlation
identifier and, for a confirmation, the resource it leads to. The supervisor holds no cluster
permission and publishes no Kubernetes Event: there is no cluster client anywhere in this package.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from langgraph.runtime import Runtime

from common.schemas.audit import AuditEvent, ResourceRef
from common.tracing import emit_span_event
from supervisors.provisioning.graph.context import (
    INTENT_NAMESPACE,
    NETWORK_API_VERSION,
    SupervisorContext,
)
from supervisors.provisioning.graph.state import ServiceRequestState

SUPERVISOR_EVENTS: frozenset[str] = frozenset({"confirm", "decline", "refuse"})
DEPLOYER_EVENTS: frozenset[str] = frozenset({"submit", "remove", "out_of_band"})


class NotTheSupervisorsEvent(ValueError):
    """An audit event another process decides (the deployer's), asked of the supervisor."""


def network_ref(name: str) -> dict[str, Any]:
    """The ``ResourceRef`` of ``Network/<name>`` in the intent namespace (data-model.md §15)."""
    return {"apiVersion": NETWORK_API_VERSION, "kind": "Network", "namespace": INTENT_NAMESPACE,
            "name": name}


def build_event(event_type: str, *, correlation_id: str, thread_id: str, principal: str,
                stage: str | None = None, reason: str | None = None,
                resources: list[dict[str, Any]] | None = None) -> AuditEvent:
    if event_type not in SUPERVISOR_EVENTS:
        raise NotTheSupervisorsEvent(
            f"the supervisor does not emit {event_type!r} audit events: "
            f"{'the deployer decides them' if event_type in DEPLOYER_EVENTS else 'unknown type'}")
    return AuditEvent(
        event_type=event_type,  # type: ignore[arg-type]
        correlation_id=correlation_id, thread_id=thread_id, principal=principal,
        at=datetime.now(UTC),
        resources=[ResourceRef.model_validate(r, strict=True) for r in resources or []],
        reason=reason, stage=stage)


def emit_audit(runtime: Runtime[SupervisorContext], state: ServiceRequestState, event_type: str,
               *, stage: str | None = None, reason: str | None = None,
               resources: list[dict[str, Any]] | None = None) -> AuditEvent:
    """Emit one supervisor audit event as a span event on this turn's request span."""
    event = build_event(event_type, correlation_id=state["correlation_id"],
                        thread_id=state["thread_id"], principal=state["turn_principal"],
                        stage=stage, reason=reason, resources=resources)
    name, attributes = event.span_event()
    emit_span_event(name, attributes, span=runtime.context.span)
    return event


__all__ = [
    "DEPLOYER_EVENTS",
    "SUPERVISOR_EVENTS",
    "NotTheSupervisorsEvent",
    "build_event",
    "emit_audit",
    "network_ref",
]
