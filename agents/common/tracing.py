"""The root request span and the span-event helper (T080; data-model.md §7, §16, AD-57).

The **root request span**'s trace identifier *is* the correlation identifier: 32 lowercase hex
characters, the one T085 puts on every chunk and T099/T100 label claims and ``Network``s with. A
thread continued in a later request turn keeps its correlation identifier — it is immutable once
set — so the later turn's request span is opened *in that trace* (same trace id, new span).

:func:`emit_span_event` is how audit events (T101's ``audit.py``, T100's deployer events) are
emitted: as span events on the request span, through the process's one exporter
(:mod:`common.telemetry`). Every attribute passes the FR-079 redaction first.

T135 extends this file with the stage, worker-call, model-call and convergence spans.
"""

from __future__ import annotations

import re
import secrets
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Any

from opentelemetry import context as otel_context
from opentelemetry import trace
from opentelemetry.trace import NonRecordingSpan, SpanContext, TraceFlags

from common.guards.redaction import redact_mapping
from common.telemetry import get_telemetry

CORRELATION_ID = re.compile(r"^[0-9a-f]{32}$")


def format_trace_id(trace_id: int) -> str:
    return format(trace_id, "032x")


def is_correlation_id(value: object) -> bool:
    return isinstance(value, str) and bool(CORRELATION_ID.match(value)) and value != "0" * 32


@dataclass
class RequestSpan:
    span: Any
    correlation_id: str

    def event(self, name: str, attributes: Mapping[str, Any] | None = None) -> None:
        emit_span_event(name, attributes, span=self.span)


@contextmanager
def request_span(name: str = "agent.request", *, correlation_id: str | None = None,
                 attributes: Mapping[str, Any] | None = None,
                 attach: bool = True) -> Iterator[RequestSpan]:
    """Open the request span; yield it with its correlation identifier.

    With ``correlation_id`` (a continued thread) the span is opened in that trace; without, it is
    a new root and its fresh trace identifier becomes the correlation identifier. ``attach=False``
    leaves the ambient context alone — for a span held across the yields of an async generator,
    whose events are then emitted with ``span=`` explicitly.
    """
    tracer = get_telemetry().tracer("agentic-netops.request")
    parent_ctx = None
    if correlation_id is not None:
        if not is_correlation_id(correlation_id):
            raise ValueError(f"not a correlation identifier (32 lowercase hex): {correlation_id!r}")
        parent = SpanContext(
            trace_id=int(correlation_id, 16),
            span_id=int.from_bytes(secrets.token_bytes(8), "big") or 1,
            is_remote=True,
            trace_flags=TraceFlags(TraceFlags.SAMPLED),
        )
        parent_ctx = trace.set_span_in_context(NonRecordingSpan(parent))
    attrs = redact_mapping(dict(attributes or {}))
    span = tracer.start_span(name, context=parent_ctx, attributes=_attrs(attrs))
    cid = format_trace_id(span.get_span_context().trace_id)
    span.set_attribute("correlation_id", cid)
    token = otel_context.attach(trace.set_span_in_context(span)) if attach else None
    try:
        yield RequestSpan(span, cid)
    except BaseException as exc:
        span.record_exception(exc)
        raise
    finally:
        if token is not None:
            otel_context.detach(token)
        span.end()


def current_correlation_id() -> str | None:
    ctx = trace.get_current_span().get_span_context()
    return format_trace_id(ctx.trace_id) if ctx.is_valid else None


def _attrs(attributes: Mapping[str, Any]) -> dict[str, Any]:
    """OpenTelemetry attribute values: str/bool/int/float or homogeneous sequences; None dropped."""
    out: dict[str, Any] = {}
    for key, value in attributes.items():
        if value is None:
            continue
        if isinstance(value, str | bool | int | float):
            out[key] = value
        elif isinstance(value, list | tuple) and all(isinstance(v, str) for v in value):
            out[key] = list(value)
        else:
            import json

            out[key] = json.dumps(value, sort_keys=True, default=str)
    return out


def emit_span_event(name: str, attributes: Mapping[str, Any] | None = None, *,
                    span: Any | None = None) -> None:
    """Add a redacted span event ``name`` to ``span`` (default: the current span)."""
    target = span if span is not None else trace.get_current_span()
    target.add_event(name, attributes=_attrs(redact_mapping(dict(attributes or {}))))


__all__ = [
    "RequestSpan",
    "current_correlation_id",
    "emit_span_event",
    "format_trace_id",
    "is_correlation_id",
    "request_span",
]
