"""AuditEvent and ResourceRef (T081; data-model.md §15, §16, FR-078, FR-102, AD-40, AD-53).

``ResourceRef.ready`` is the ``Ready`` condition's **status string as the cluster reports it** —
``"True"``, ``"False"``, ``"Unknown"`` — or ``None`` before the watch has read a ``Ready``
condition; never a boolean (strict: ``True`` is refused). ``reason`` is always present when
``ready`` is ``"False"`` or ``"Unknown"``.

An ``AuditEvent`` always carries the authenticated principal (FR-102); ``refuse`` and ``decline``
carry no resources. It is emitted as a span event on the request trace
(:func:`common.tracing.emit_span_event`) — see :meth:`AuditEvent.span_event`.
"""

from __future__ import annotations

import json
from datetime import datetime
from typing import Any, Literal

from pydantic import Field, model_validator

from common.schemas._base import StrictModel

Ready = Literal["True", "False", "Unknown"]
EventType = Literal["confirm", "decline", "submit", "refuse", "remove", "out_of_band"]
CORRELATION_ID_PATTERN = r"^[0-9a-f]{32}$"


class ResourceRef(StrictModel):
    apiVersion: str = Field(min_length=1)
    kind: str = Field(min_length=1)
    namespace: str = Field(min_length=1)
    name: str = Field(min_length=1)
    uid: str | None = None
    ready: Ready | None = None
    reason: str | None = None

    @model_validator(mode="after")
    def _reason_beside_not_true(self) -> ResourceRef:
        if self.ready in ("False", "Unknown") and not self.reason:
            raise ValueError(f"ready={self.ready!r} requires the condition's reason")
        return self

    @property
    def ref(self) -> str:
        return f"{self.kind}/{self.name}"


class AuditEvent(StrictModel):
    event_type: EventType
    correlation_id: str = Field(pattern=CORRELATION_ID_PATTERN)
    thread_id: str = Field(min_length=1)
    principal: str = Field(min_length=1)
    at: datetime
    resources: list[ResourceRef] = Field(default_factory=list)
    reason: str | None = None
    stage: str | None = None
    # FR-078 / data-model.md §16: a submission (and a removal) carries the submitted-spec hash; an
    # out-of-band event carries both hashes while the object still exists.
    submitted_spec_sha256: str | None = None
    live_spec_sha256: str | None = None

    @model_validator(mode="after")
    def _no_resources_on_refuse_or_decline(self) -> AuditEvent:
        if self.event_type in ("refuse", "decline") and self.resources:
            raise ValueError(f"a {self.event_type} event carries no resources")
        return self

    @classmethod
    def from_json(cls, data: dict[str, Any] | str | bytes) -> AuditEvent:
        """Validate a JSON-decoded event strictly, ``at`` as an RFC 3339 string (JSON mode)."""
        raw = data if isinstance(data, str | bytes) else json.dumps(data)
        return cls.model_validate_json(raw, strict=True)

    def span_event(self) -> tuple[str, dict[str, Any]]:
        """The span event this audit event is emitted as: ``audit.<event_type>`` + attributes."""
        attrs: dict[str, Any] = {
            "audit.event_type": self.event_type,
            "audit.correlation_id": self.correlation_id,
            "audit.thread_id": self.thread_id,
            "audit.principal": self.principal,
            "audit.at": self.at.isoformat(),
            "audit.resources": [r.model_dump_json(exclude_none=True) for r in self.resources],
        }
        if self.reason is not None:
            attrs["audit.reason"] = self.reason
        if self.stage is not None:
            attrs["audit.stage"] = self.stage
        if self.submitted_spec_sha256 is not None:
            attrs["audit.submitted_spec_sha256"] = self.submitted_spec_sha256
        if self.live_spec_sha256 is not None:
            attrs["audit.live_spec_sha256"] = self.live_spec_sha256
        return f"audit.{self.event_type}", attrs


__all__ = ["AuditEvent", "EventType", "Ready", "ResourceRef"]
