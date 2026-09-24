"""The root request span and the span-event helper (T080; data-model.md §7, §16, AD-57).

The **root request span**'s trace identifier *is* the correlation identifier: 32 lowercase hex
characters, the one T085 puts on every chunk and T099/T100 label claims and ``Network``s with. A
thread continued in a later request turn keeps its correlation identifier — it is immutable once
set — so the later turn's request span is opened *in that trace* (same trace id, new span).

:func:`emit_span_event` is how audit events (T101's ``audit.py``, T100's deployer events) are
emitted: as span events on the request span, through the process's one exporter
(:mod:`common.telemetry`). Every attribute passes the FR-079 redaction first.

T135 extends this file — both of the above unchanged (AD-57) — with the child spans that make
**one trace per request** (FR-090, FR-093, NFR-009), every one of them in the trace whose id is the
correlation identifier:

``stage.<stage>`` (:func:`stage_span`; ``stage`` ∈ supervisor, mapper, allocator, deployer)
    One per stage node run of the supervisor graph. Attributes ``agentic_netops.stage``,
    ``agentic_netops.outcome``, ``agentic_netops.correlation_id``; on failure status ERROR and
    ``agentic_netops.failure.reason``, and — when a payload failed validation —
    ``agentic_netops.failure.payload`` (JSON, redacted) and ``agentic_netops.failure.errors``
    (:func:`mark_failure`). The graph code sets ``agentic_netops.failed_stage`` on the root span.
``worker.call`` (:func:`worker_call_span`, supervisor side)
    ``agentic_netops.worker``, ``agentic_netops.skill``, ``agentic_netops.attempts``,
    ``agentic_netops.outcome``; the W3C ``traceparent`` of this span rides the request metadata
    (:func:`inject_traceparent`).
``worker.handle`` (:func:`worker_handle_span`, worker side)
    Opened as a child of the propagated ``traceparent`` — or, without one, in the trace of the
    request's correlation identifier — so every worker's spans land in the supervisor's trace
    through that worker's own one exporter.
``model.call`` (:func:`model_call_span`)
    ``gen_ai.system``, ``gen_ai.request.model``, ``gen_ai.prompt`` (the messages as JSON),
    ``gen_ai.completion``, ``gen_ai.usage.input_tokens`` / ``output_tokens`` and, when the library
    reports one, ``gen_ai.usage.cost``: prompt, model identity and response recoverable after
    redaction (NFR-009).
``convergence`` (:func:`convergence_span`, the deployer's watch)
    ``k8s.network.name``, ``k8s.network.namespace``, ``agentic_netops.ready``,
    ``agentic_netops.reason``, ``agentic_netops.outcome``, ``agentic_netops.duration_seconds``.

Every attribute passes the FR-079 redaction (:func:`~common.guards.redaction.redact_mapping`).
"""

from __future__ import annotations

import json
import re
import secrets
import time
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass, field
from typing import Any

from opentelemetry import context as otel_context
from opentelemetry import trace
from opentelemetry.trace import (
    NonRecordingSpan,
    SpanContext,
    SpanKind,
    Status,
    StatusCode,
    TraceFlags,
)
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

from common.guards.redaction import redact, redact_mapping, redact_transcript
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


# --------------------------------------------------------------------------------------------------
# T135: the child spans of one request's trace (FR-090, FR-092, FR-093, NFR-009)
# --------------------------------------------------------------------------------------------------

STAGE_SPAN_PREFIX = "stage."
WORKER_CALL_SPAN = "worker.call"
WORKER_HANDLE_SPAN = "worker.handle"
MODEL_CALL_SPAN = "model.call"
CONVERGENCE_SPAN = "convergence"

ATTR_STAGE = "agentic_netops.stage"
ATTR_OUTCOME = "agentic_netops.outcome"
ATTR_CORRELATION_ID = "agentic_netops.correlation_id"
ATTR_NODE = "agentic_netops.node"
ATTR_FAILURE_REASON = "agentic_netops.failure.reason"
ATTR_FAILURE_PAYLOAD = "agentic_netops.failure.payload"
ATTR_FAILURE_ERRORS = "agentic_netops.failure.errors"
ATTR_FAILURE_STAGE = "agentic_netops.failure.stage"
ATTR_FAILED_STAGE = "agentic_netops.failed_stage"  # on the root span only
ATTR_WORKER = "agentic_netops.worker"
ATTR_SKILL = "agentic_netops.skill"
ATTR_ATTEMPTS = "agentic_netops.attempts"
ATTR_DURATION = "agentic_netops.duration_seconds"
ATTR_READY = "agentic_netops.ready"
ATTR_REASON = "agentic_netops.reason"
ATTR_NETWORK_NAME = "k8s.network.name"
ATTR_NETWORK_NAMESPACE = "k8s.network.namespace"
GEN_AI_SYSTEM = "gen_ai.system"
GEN_AI_REQUEST_MODEL = "gen_ai.request.model"
GEN_AI_RESPONSE_MODEL = "gen_ai.response.model"
GEN_AI_PROMPT = "gen_ai.prompt"
GEN_AI_COMPLETION = "gen_ai.completion"
GEN_AI_INPUT_TOKENS = "gen_ai.usage.input_tokens"
GEN_AI_OUTPUT_TOKENS = "gen_ai.usage.output_tokens"
GEN_AI_COST = "gen_ai.usage.cost"

TRACEPARENT = "traceparent"
# The stage outcomes that fail the stage (span status ERROR). A refusal ends the request FAILED at
# that stage, so it is one (SC-038 reads the refusing stage from the trace); ``declined`` (the
# operator's decision), ``clarification`` and ``in_progress`` are not.
FAILURE_OUTCOMES: frozenset[str] = frozenset({"failed", "unreachable", "status_unknown",
                                              "refused"})

_propagator = TraceContextTextMapPropagator()


def _tracer() -> Any:
    return get_telemetry().tracer("agentic-netops.request")


def set_attributes(span: Any, attributes: Mapping[str, Any]) -> None:
    """Set ``attributes`` on ``span`` after the FR-079 redaction."""
    span.set_attributes(_attrs(redact_mapping(dict(attributes))))


def _json(value: Any) -> str:
    if isinstance(value, str):
        return value
    try:
        return json.dumps(value, sort_keys=True, default=str)
    except (TypeError, ValueError):
        return str(value)


def mark_failure(span: Any, stage: str | None, reason: str, payload: Any = None,
                 errors: Any = None) -> None:
    """Mark ``span`` failed: status ERROR, the reason and — when a payload failed validation —
    that payload (JSON) and the validation errors, all redacted."""
    reason = redact(str(reason or "failed"))
    span.set_status(Status(StatusCode.ERROR, reason))
    attrs: dict[str, Any] = {ATTR_FAILURE_REASON: reason}
    if stage:
        attrs[ATTR_FAILURE_STAGE] = stage
    if payload is not None:
        attrs[ATTR_FAILURE_PAYLOAD] = redact(_json(payload))
    if errors is not None:
        attrs[ATTR_FAILURE_ERRORS] = redact(_json(errors))
    set_attributes(span, attrs)


@contextmanager
def _child(name: str, attributes: Mapping[str, Any], *, context: Any = None,
           kind: SpanKind = SpanKind.INTERNAL) -> Iterator[Any]:
    """A child span of ``context`` (default: the ambient context), attached while it runs."""
    span = _tracer().start_span(name, context=context, kind=kind,
                                attributes=_attrs(redact_mapping(dict(attributes))))
    token = otel_context.attach(trace.set_span_in_context(span))
    try:
        yield span
    except BaseException as exc:
        span.record_exception(exc)
        if isinstance(exc, Exception):
            span.set_status(Status(StatusCode.ERROR, redact(f"{type(exc).__name__}: {exc}")))
        raise
    finally:
        otel_context.detach(token)
        span.end()


def _parent_context(parent: Any) -> Any:
    return trace.set_span_in_context(parent) if parent is not None else None


def _correlation_context(correlation_id: str | None) -> Any:
    """A remote parent in the trace of ``correlation_id`` (the request_span rule), or None."""
    if not is_correlation_id(correlation_id):
        return None
    parent = SpanContext(trace_id=int(str(correlation_id), 16),
                         span_id=int.from_bytes(secrets.token_bytes(8), "big") or 1,
                         is_remote=True, trace_flags=TraceFlags(TraceFlags.SAMPLED))
    return trace.set_span_in_context(NonRecordingSpan(parent))


# ------------------------------------------------------------------------------------ stage spans


@dataclass
class StageSpan:
    """One stage node run: its span, the outcome it recorded and whether it failed."""

    span: Any
    stage: str
    correlation_id: str | None
    started: float = field(default_factory=time.monotonic)
    outcome: str | None = None
    failed: bool = False
    failed_stage: str | None = None
    reason: str | None = None

    def record_outcome(self, outcome: str, stage: str | None = None) -> None:
        self.outcome = outcome
        set_attributes(self.span, {ATTR_OUTCOME: outcome})
        if outcome in FAILURE_OUTCOMES and not self.failed:
            self.fail(f"{stage or self.stage}: {outcome}", stage=stage)

    def fail(self, reason: str, *, stage: str | None = None, payload: Any = None,
             errors: Any = None) -> None:
        """Mark this stage failed (a later reason replaces an earlier one; a payload stays)."""
        self.failed = True
        self.failed_stage = stage or self.failed_stage or self.stage
        self.reason = reason
        mark_failure(self.span, self.failed_stage, reason, payload, errors)

    @property
    def duration(self) -> float:
        return max(time.monotonic() - self.started, 0.0)


_current_stage: ContextVar[StageSpan | None] = ContextVar("agentic_netops_stage", default=None)


def current_stage() -> StageSpan | None:
    """The stage span of the stage node running in this context, if any."""
    return _current_stage.get()


def note_stage_outcome(stage: str, outcome: str) -> None:
    """Record ``outcome`` on the running stage span (called by ``metrics.record_stage``)."""
    current = _current_stage.get()
    if current is not None:
        current.record_outcome(outcome, stage)


@contextmanager
def stage_span(stage: str, *, correlation_id: str | None, parent: Any = None,
               node: str | None = None,
               attributes: Mapping[str, Any] | None = None) -> Iterator[StageSpan]:
    """``stage.<stage>``: a child of ``parent`` (the root request span, held unattached by the
    supervisor), else of the ambient context; attached while it runs, so worker and model calls
    made inside are its children."""
    attrs = {ATTR_STAGE: stage, ATTR_CORRELATION_ID: correlation_id, ATTR_NODE: node,
             **dict(attributes or {})}
    with _child(f"{STAGE_SPAN_PREFIX}{stage}", attrs,
                context=_parent_context(parent)) as span:
        current = StageSpan(span, stage, correlation_id)
        token = _current_stage.set(current)
        try:
            yield current
        except Exception as exc:
            if not current.failed:
                current.fail(f"internal error: {type(exc).__name__}")
            raise
        finally:
            _current_stage.reset(token)
            set_attributes(span, {ATTR_DURATION: current.duration})


# ------------------------------------------------------------------------------ worker spans


def inject_traceparent(carrier: dict[str, Any] | None = None) -> dict[str, Any]:
    """The W3C ``traceparent`` of the current span, into ``carrier`` (returned)."""
    carrier = {} if carrier is None else carrier
    _propagator.inject(carrier)
    return carrier


def traceparent() -> str | None:
    return inject_traceparent().get(TRACEPARENT)


@contextmanager
def worker_call_span(worker: str, skill: str, *, correlation_id: str | None = None,
                     attributes: Mapping[str, Any] | None = None) -> Iterator[Any]:
    """``worker.call``: the supervisor side of one worker call, a child of the ambient context
    (the stage span); falls back to the correlation identifier's trace when there is none."""
    ctx = None
    if not trace.get_current_span().get_span_context().is_valid:
        ctx = _correlation_context(correlation_id)
    attrs = {ATTR_WORKER: worker, ATTR_SKILL: skill, ATTR_CORRELATION_ID: correlation_id,
             **dict(attributes or {})}
    with _child(WORKER_CALL_SPAN, attrs, context=ctx, kind=SpanKind.CLIENT) as span:
        yield span


@contextmanager
def worker_handle_span(worker: str, skill: str, *, traceparent_value: str | None,
                       correlation_id: str | None = None,
                       attributes: Mapping[str, Any] | None = None) -> Iterator[Any]:
    """``worker.handle``: the worker side, a child of the propagated ``traceparent`` — or, when
    none came, of the correlation identifier's trace — so it shares the supervisor's trace."""
    ctx = None
    if traceparent_value:
        ctx = _propagator.extract({TRACEPARENT: str(traceparent_value)})
        if not trace.get_current_span(ctx).get_span_context().is_valid:
            ctx = None
    if ctx is None:
        ctx = _correlation_context(correlation_id)
    attrs = {ATTR_WORKER: worker, ATTR_SKILL: skill, ATTR_CORRELATION_ID: correlation_id,
             **dict(attributes or {})}
    with _child(WORKER_HANDLE_SPAN, attrs, context=ctx, kind=SpanKind.SERVER) as span:
        token = _current_worker.set(span)
        try:
            yield span
        finally:
            _current_worker.reset(token)


_current_worker: ContextVar[Any] = ContextVar("agentic_netops_worker_handle", default=None)


@contextmanager
def worker_operation_span(name: str, *, correlation_id: str,
                          attributes: Mapping[str, Any] | None = None) -> Iterator[RequestSpan]:
    """A worker's own operation span: a child of the ``worker.handle`` span it answers under, so
    the operation (and the convergence below it) hangs off the supervisor's call in one connected
    trace; with no ``worker.handle`` (a direct call) it is :func:`request_span` in that trace."""
    if current_worker_span() is None:
        with request_span(name, correlation_id=correlation_id, attributes=attributes) as rs:
            yield rs
        return
    attrs = {ATTR_CORRELATION_ID: correlation_id, **dict(attributes or {})}
    with _child(name, attrs) as span:
        yield RequestSpan(span, format_trace_id(span.get_span_context().trace_id))


def current_worker_span() -> Any:
    """The ``worker.handle`` span of the request this worker is answering, if any."""
    return _current_worker.get()


def mark_worker_failure(stage: str, reason: str, payload: Any = None, errors: Any = None) -> None:
    """Worker side: mark the ``worker.handle`` span — and the current span, when a worker opened
    its own below it — failed, with the payload that failed validation when there is one."""
    targets = [current_worker_span(), trace.get_current_span()]
    seen: set[int] = set()
    for span in targets:
        if span is None or id(span) in seen or not span.get_span_context().is_valid:
            continue
        seen.add(id(span))
        mark_failure(span, stage, reason, payload, errors)


# --------------------------------------------------------------------------------- model call


@contextmanager
def model_call_span(*, provider: str | None, model: str | None,
                    messages: Any) -> Iterator[Any]:
    """``model.call``: provider, model and the prompt (the messages, redacted) on open; the
    response and usage are added with :func:`record_model_response`."""
    prompt = messages
    if isinstance(messages, list | tuple) and all(isinstance(m, Mapping) for m in messages):
        prompt = redact_transcript(messages)
    attrs = {GEN_AI_SYSTEM: provider, GEN_AI_REQUEST_MODEL: model,
             GEN_AI_PROMPT: redact(_json(prompt))}
    with _child(MODEL_CALL_SPAN, attrs, kind=SpanKind.CLIENT) as span:
        yield span


def record_model_response(span: Any, *, completion: str | None, model: str | None = None,
                          input_tokens: int | None = None, output_tokens: int | None = None,
                          cost: float | None = None) -> None:
    set_attributes(span, {GEN_AI_COMPLETION: completion, GEN_AI_RESPONSE_MODEL: model,
                          GEN_AI_INPUT_TOKENS: input_tokens, GEN_AI_OUTPUT_TOKENS: output_tokens,
                          GEN_AI_COST: cost, ATTR_OUTCOME: "succeeded"})


# -------------------------------------------------------------------------------- convergence


@contextmanager
def convergence_span(name: str | None, namespace: str | None, *,
                     attributes: Mapping[str, Any] | None = None) -> Iterator[Any]:
    """``convergence``: the deployer's watch of one or more ``Network`` objects; the result is
    added with :func:`record_convergence`."""
    attrs = {ATTR_NETWORK_NAME: name, ATTR_NETWORK_NAMESPACE: namespace,
             **dict(attributes or {})}
    started = time.monotonic()
    with _child(CONVERGENCE_SPAN, attrs) as span:
        try:
            yield span
        finally:
            set_attributes(span, {ATTR_DURATION: max(time.monotonic() - started, 0.0)})


def record_convergence(span: Any, *, outcome: str, ready: str | None, reason: str | None,
                       message: str | None = None, failed: bool = False) -> None:
    set_attributes(span, {ATTR_OUTCOME: outcome, ATTR_READY: ready, ATTR_REASON: reason})
    if failed:
        mark_failure(span, "deployer", message or outcome)


__all__ = [
    "ATTR_FAILED_STAGE",
    "ATTR_FAILURE_ERRORS",
    "ATTR_FAILURE_PAYLOAD",
    "ATTR_FAILURE_REASON",
    "CONVERGENCE_SPAN",
    "FAILURE_OUTCOMES",
    "MODEL_CALL_SPAN",
    "TRACEPARENT",
    "WORKER_CALL_SPAN",
    "WORKER_HANDLE_SPAN",
    "RequestSpan",
    "StageSpan",
    "convergence_span",
    "current_correlation_id",
    "current_stage",
    "current_worker_span",
    "emit_span_event",
    "format_trace_id",
    "inject_traceparent",
    "is_correlation_id",
    "mark_failure",
    "mark_worker_failure",
    "model_call_span",
    "note_stage_outcome",
    "record_convergence",
    "record_model_response",
    "request_span",
    "set_attributes",
    "stage_span",
    "traceparent",
    "worker_call_span",
    "worker_handle_span",
    "worker_operation_span",
]
