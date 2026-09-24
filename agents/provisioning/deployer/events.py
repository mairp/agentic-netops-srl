"""The three audit events the deployer decides (T100; data-model.md §16, FR-078, AD-18, AD-59).

A submission, a removal and an out-of-band detection are the deployer's — the supervisor decides
confirmations, declines and refusals. Each is emitted as a **span event on the request trace**
(:func:`common.tracing.emit_span_event` via :meth:`AuditEvent.span_event`) — that stored event is
the record — and **mirrored as a Kubernetes Event** in the intent namespace, the only Events the
tier publishes. A mirror that fails is logged and never fails the request: a Kubernetes Event is
never the record. An out-of-band detection also increments
``agentic_netops_agent_out_of_band_changes_total{change}`` (data-model.md §21).
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from datetime import datetime
from typing import Any

from common import metrics
from common.schemas.audit import AuditEvent, ResourceRef
from common.tracing import emit_span_event
from provisioning.deployer.kube import FIELD_MANAGER, INTENT_NAMESPACE, KubeClient, KubeError
from provisioning.deployer.stamp import rfc3339

log = logging.getLogger("agentic_netops.deployer.events")

K8S_REASONS = {
    "submit": ("IntentSubmitted", "Normal"),
    "remove": ("IntentRemovalRequested", "Normal"),
    "out_of_band": ("OutOfBandChange", "Warning"),
}


class AuditEmitter:
    """Emits the deployer's audit events: span event, Kubernetes Event, and the counter."""

    def __init__(self, kube: Callable[[], KubeClient], *, now: Callable[[], datetime],
                 span: Any | None = None) -> None:
        self._kube = kube
        self.now = now
        self.span = span
        self.emitted: list[AuditEvent] = []

    async def emit(self, event_type: str, *, correlation_id: str, thread_id: str,
                   principal: str, resources: list[ResourceRef], reason: str | None,
                   message: str, submitted_spec_sha256: str | None = None,
                   live_spec_sha256: str | None = None) -> AuditEvent:
        event = AuditEvent(event_type=event_type, correlation_id=correlation_id,  # type: ignore[arg-type]
                           thread_id=thread_id, principal=principal, at=self.now(),
                           resources=resources, reason=reason, stage="deployer",
                           submitted_spec_sha256=submitted_spec_sha256,
                           live_spec_sha256=live_spec_sha256)
        name, attributes = event.span_event()
        emit_span_event(name, attributes, span=self.span)
        self.emitted.append(event)
        if event_type == "out_of_band" and reason in ("modified", "deleted"):
            metrics.record_out_of_band(reason)
        await self._mirror(event, message)
        return event

    async def _mirror(self, event: AuditEvent, message: str) -> None:
        reason, kind = K8S_REASONS[event.event_type]
        at = rfc3339(event.at)
        target = event.resources[0] if event.resources else None
        involved: dict[str, Any] = {"kind": "Network", "namespace": INTENT_NAMESPACE,
                                    "apiVersion": "fabric.agentic-netops.io/v1alpha1"}
        if target is not None:
            involved["name"] = target.name
            if target.uid:
                involved["uid"] = target.uid
        body = {
            "apiVersion": "v1", "kind": "Event",
            "metadata": {"generateName": f"{involved.get('name', 'intent')}.",
                         "namespace": INTENT_NAMESPACE,
                         "labels": {"agentic-netops.io/correlation-id": event.correlation_id,
                                    "agentic-netops.io/tier": "intent"},
                         "annotations": {"agentic-netops.io/intent-thread-id": event.thread_id,
                                         "agentic-netops.io/intent-principal": event.principal,
                                         "agentic-netops.io/audit-event-type":
                                             event.event_type}},
            "involvedObject": involved, "reason": reason, "type": kind,
            "message": message[:1024],
            "source": {"component": FIELD_MANAGER},
            "reportingComponent": FIELD_MANAGER, "reportingInstance": FIELD_MANAGER,
            "firstTimestamp": at, "lastTimestamp": at, "count": 1,
        }
        try:
            await self._kube().create_event(body)
        except KubeError as exc:  # the span event is the record; the mirror is best effort
            log.warning("Kubernetes Event mirror of %s failed: %s", event.event_type, exc)


__all__ = ["K8S_REASONS", "AuditEmitter"]
