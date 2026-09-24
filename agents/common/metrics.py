"""The tier metric series, on the one exporter (T080; data-model.md §21, AD-50, AD-54, AD-66).

Every tier metric name starts with the literal prefix ``agentic_netops_agent_`` — the predecessor
tier's, carried unchanged, and what the fabric collector's filter admits — and :func:`register`
**refuses** a name that does not (:class:`~common.exceptions.MetricNameError`).

The three series of this story (T135 adds the rest and redefines none of these):

``agentic_netops_agent_stage_requests_total{stage,outcome}``
    FR-092's per-stage request-outcome counter, from which the per-stage success rate is computed.
    ``outcome`` is the closed set :data:`STAGE_OUTCOMES`; only ``converged`` and ``succeeded``
    are successes. ``STATUS_UNKNOWN`` is recorded as ``status_unknown`` — never converged — and a
    removal whose turn ends at ``PROVISIONING`` as ``in_progress`` — neither converged nor failed
    (FR-054, AD-54, AD-63).
``agentic_netops_agent_auth_refusals_total``
    FR-102: incremented for every request refused for want of a valid operator credential.
``agentic_netops_agent_out_of_band_changes_total{change}``
    FR-105: ``change`` ∈ ``modified``, ``deleted``.

T135's series (every name the same prefix; AD-66):

``agentic_netops_agent_stage_duration_seconds{stage,outcome}``
    Histogram: the latency of one stage node run, by the outcome it recorded (FR-092).
``agentic_netops_agent_confirmations_total{confirmation,decision}``
    ``confirmation`` ∈ ``first``, ``second``; ``decision`` ∈ ``confirmed``, ``declined``.
``agentic_netops_agent_refused_unsafe_total{class}``
    Requests the guards classified unsafe and refused; ``class`` the closed refusal-class set of
    :class:`~common.guards.refusals.RefusalClass`.
``agentic_netops_agent_worker_calls_total{worker,outcome}``
    Supervisor-side worker calls; ``outcome`` ∈ ``succeeded``, ``failed``, ``unreachable``.
``agentic_netops_agent_model_calls_total{model,outcome}``,
``agentic_netops_agent_model_tokens_total{model,kind}``,
``agentic_netops_agent_model_cost_usd_total{model}``
    Model calls (``outcome`` ∈ ``succeeded``, ``failed``), their token usage (``kind`` ∈
    ``input``, ``output``) and — when the library reports it — their cost.
``agentic_netops_agent_service_info{network,namespace,correlation_id,construct}``
    Observable gauge, always 1: one series per tier-submitted ``Network`` the deployer currently
    knows of (:func:`sync_service_info`, :func:`set_service_info`, :func:`forget_service_info`)
    — bounded by the services, and the fabric-side join key of a request's trace (FR-093).

:func:`record_stage` also records the outcome on the running stage span
(:func:`common.tracing.note_stage_outcome`).

:func:`value` reads a series back in-process (the telemetry's in-memory reader), which is what the
unit tests assert on.
"""

from __future__ import annotations

import threading
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Any

from common import tracing
from common.exceptions import MetricNameError
from common.guards.refusals import RefusalClass
from common.provisioning_states import WorkflowStatus
from common.telemetry import Telemetry, get_telemetry

PREFIX = "agentic_netops_agent_"

STAGE_REQUESTS = "agentic_netops_agent_stage_requests_total"
AUTH_REFUSALS = "agentic_netops_agent_auth_refusals_total"
OUT_OF_BAND_CHANGES = "agentic_netops_agent_out_of_band_changes_total"
# T135
STAGE_DURATION = "agentic_netops_agent_stage_duration_seconds"
CONFIRMATIONS = "agentic_netops_agent_confirmations_total"
REFUSED_UNSAFE = "agentic_netops_agent_refused_unsafe_total"
WORKER_CALLS = "agentic_netops_agent_worker_calls_total"
MODEL_CALLS = "agentic_netops_agent_model_calls_total"
MODEL_TOKENS = "agentic_netops_agent_model_tokens_total"
MODEL_COST = "agentic_netops_agent_model_cost_usd_total"
SERVICE_INFO = "agentic_netops_agent_service_info"

COUNTER, HISTOGRAM, GAUGE = "counter", "histogram", "observable_gauge"

STAGES: frozenset[str] = frozenset({"supervisor", "mapper", "allocator", "deployer"})

# The closed outcome set of the per-stage counter.
STAGE_OUTCOMES: frozenset[str] = frozenset({
    "converged",       # the deployer observed the change in effect (COMPLETED / VERIFIED)
    "succeeded",       # a non-deploying stage returned a valid answer (mapped, allocated, informed)
    "failed",          # a terminal failure: worker failed, schema reject, bounded exit
    "unreachable",     # worker unreachable — retryable, the thread stays resumable
    "in_progress",     # a removal still Deleting at the bound: final PROVISIONING (AD-63)
    "status_unknown",  # STATUS_UNKNOWN: the outcome could not be observed (FR-054)
    "refused",         # refused by the guards, or unsupported / unqualified properties
    "declined",        # the operator declined at a confirmation
    "clarification",   # the interpretation asks for missing fields
})
SUCCESS_OUTCOMES: frozenset[str] = frozenset({"converged", "succeeded"})
CHANGES: frozenset[str] = frozenset({"modified", "deleted"})
CONFIRMATION_POINTS: frozenset[str] = frozenset({"first", "second"})
DECISIONS: frozenset[str] = frozenset({"confirmed", "declined"})
REFUSAL_CLASSES: frozenset[str] = frozenset(c.value for c in RefusalClass)
CALL_OUTCOMES: frozenset[str] = frozenset({"succeeded", "failed", "unreachable"})
MODEL_OUTCOMES: frozenset[str] = frozenset({"succeeded", "failed"})
TOKEN_KINDS: frozenset[str] = frozenset({"input", "output"})
SERVICE_INFO_LABELS = ("network", "namespace", "correlation_id", "construct")


def outcome_for_status(status: str, *, removal: bool = False) -> str:
    """The stage outcome a final workflow status stands for. STATUS_UNKNOWN is never converged."""
    match WorkflowStatus(status):
        case WorkflowStatus.COMPLETED | WorkflowStatus.VERIFIED:
            return "converged"
        case WorkflowStatus.STATUS_UNKNOWN:
            return "status_unknown"
        case WorkflowStatus.FAILED:
            return "failed"
        case WorkflowStatus.PROVISIONING | WorkflowStatus.CONFIGURED:
            return "in_progress"
        case _:
            return "in_progress" if removal else "succeeded"


@dataclass(frozen=True)
class Series:
    name: str
    description: str
    labels: tuple[str, ...]
    allowed: dict[str, frozenset[str]]
    kind: str = COUNTER
    unit: str = ""


@dataclass
class _Registered:
    series: Series
    counter: Any  # the instrument: a counter, a histogram or an observable gauge


_lock = threading.Lock()
_registry: dict[str, Series] = {}
# id(telemetry) -> (telemetry, name -> instrument); the identity check survives id() reuse.
_bound: dict[int, tuple[Telemetry, dict[str, _Registered]]] = {}


def register(name: str, description: str, labels: Iterable[str] = (),
             allowed: dict[str, Iterable[str]] | None = None, *, kind: str = COUNTER,
             unit: str = "") -> Series:
    """Register a series (a counter by default; ``kind`` also ``histogram`` or
    ``observable_gauge``). Refuses a name without the literal tier prefix."""
    if not isinstance(name, str) or not name.startswith(PREFIX):
        raise MetricNameError(
            f"metric name {name!r} does not start with the tier prefix {PREFIX!r} "
            "(data-model.md §21); refusing to register it"
        )
    if kind not in (COUNTER, HISTOGRAM, GAUGE):
        raise ValueError(f"metric {name!r}: unknown instrument kind {kind!r}")
    series = Series(name, description, tuple(labels),
                    {k: frozenset(v) for k, v in (allowed or {}).items()}, kind, unit)
    with _lock:
        existing = _registry.get(name)
        if existing is not None and existing != series:
            raise MetricNameError(f"metric {name!r} is already registered differently")
        _registry[name] = series
    return series


def registered_names() -> list[str]:
    return sorted(_registry)


register(STAGE_REQUESTS, "Per-stage request outcomes of the intent tier (FR-092).",
         ("stage", "outcome"), {"stage": STAGES, "outcome": STAGE_OUTCOMES})
register(AUTH_REFUSALS, "Requests refused for want of a valid operator credential (FR-102).")
register(OUT_OF_BAND_CHANGES, "Tier-created services changed outside the tier (FR-105).",
         ("change",), {"change": CHANGES})
# T135
register(STAGE_DURATION, "Latency of one stage node run of the intent tier (FR-092).",
         ("stage", "outcome"), {"stage": STAGES, "outcome": STAGE_OUTCOMES}, kind=HISTOGRAM,
         unit="s")
register(CONFIRMATIONS, "Operator decisions at the two confirmations (FR-092).",
         ("confirmation", "decision"), {"confirmation": CONFIRMATION_POINTS, "decision": DECISIONS})
register(REFUSED_UNSAFE, "Requests the guards classified unsafe and refused (FR-092).",
         ("class",), {"class": REFUSAL_CLASSES})
register(WORKER_CALLS, "Supervisor-side worker calls by outcome (FR-092).",
         ("worker", "outcome"), {"outcome": CALL_OUTCOMES})
register(MODEL_CALLS, "Model calls by model and outcome (FR-092, NFR-009).",
         ("model", "outcome"), {"outcome": MODEL_OUTCOMES})
register(MODEL_TOKENS, "Model token usage by model and kind (FR-092).",
         ("model", "kind"), {"kind": TOKEN_KINDS})
register(MODEL_COST, "Model cost in USD, when the model library reports it (FR-092).",
         ("model",), unit="USD")
register(SERVICE_INFO, "One series per tier-submitted Network: the fabric-side join key (FR-093).",
         SERVICE_INFO_LABELS, kind=GAUGE)


def _instrument(name: str, telemetry: Telemetry | None = None) -> _Registered:
    telemetry = telemetry or get_telemetry()
    series = _registry.get(name)
    if series is None:
        raise MetricNameError(f"metric {name!r} is not registered")
    with _lock:
        entry = _bound.get(id(telemetry))
        if entry is None or entry[0] is not telemetry:
            entry = (telemetry, {})
            _bound[id(telemetry)] = entry
        bound = entry[1]
        if name not in bound:
            meter = telemetry.meter("agentic-netops.metrics")
            if series.kind == HISTOGRAM:
                instrument = meter.create_histogram(name, unit=series.unit,
                                                    description=series.description)
            elif series.kind == GAUGE:
                instrument = meter.create_observable_gauge(
                    name, callbacks=[_gauge_callback(name)], unit=series.unit,
                    description=series.description)
            else:
                instrument = meter.create_counter(name, unit=series.unit,
                                                  description=series.description)
            bound[name] = _Registered(series, instrument)
        return bound[name]


def _check(series: Series, labels: dict[str, str]) -> None:
    name = series.name
    if set(labels) != set(series.labels):
        raise ValueError(f"{name} takes labels {series.labels}, got {tuple(sorted(labels))}")
    for key, value in labels.items():
        allowed = series.allowed.get(key)
        if allowed is not None and value not in allowed:
            raise ValueError(f"{name}: {key}={value!r} is outside the closed set {sorted(allowed)}")


def increment(name: str, amount: float = 1, **labels: str) -> None:
    reg = _instrument(name)
    if reg.series.kind != COUNTER:
        raise ValueError(f"{name} is a {reg.series.kind}, not a counter")
    _check(reg.series, labels)
    reg.counter.add(amount, attributes=labels)


def observe(name: str, amount: float, **labels: str) -> None:
    """Record one measurement of histogram ``name``."""
    reg = _instrument(name)
    if reg.series.kind != HISTOGRAM:
        raise ValueError(f"{name} is a {reg.series.kind}, not a histogram")
    _check(reg.series, labels)
    reg.counter.record(amount, attributes=labels)


def record_stage(stage: str, outcome: str) -> None:
    increment(STAGE_REQUESTS, stage=stage, outcome=outcome)
    tracing.note_stage_outcome(stage, outcome)


def record_stage_duration(stage: str, outcome: str, seconds: float) -> None:
    observe(STAGE_DURATION, max(float(seconds), 0.0), stage=stage, outcome=outcome)


def record_confirmation(confirmation: str, decision: str) -> None:
    """``confirmation`` ``first`` | ``second`` (or ``confirmation_1`` | ``confirmation_2``)."""
    point = {"confirmation_1": "first", "confirmation_2": "second"}.get(confirmation,
                                                                         confirmation)
    increment(CONFIRMATIONS, confirmation=point, decision=decision)


def record_refused_unsafe(refusal_class: str) -> None:
    increment(REFUSED_UNSAFE, **{"class": str(refusal_class)})


def record_worker_call(worker: str, outcome: str) -> None:
    increment(WORKER_CALLS, worker=worker, outcome=outcome)


def record_model_call(model: str, outcome: str, *, input_tokens: int | None = None,
                      output_tokens: int | None = None, cost: float | None = None) -> None:
    increment(MODEL_CALLS, model=model, outcome=outcome)
    if input_tokens:
        increment(MODEL_TOKENS, input_tokens, model=model, kind="input")
    if output_tokens:
        increment(MODEL_TOKENS, output_tokens, model=model, kind="output")
    if cost:
        increment(MODEL_COST, float(cost), model=model)


# ------------------------------------------------------------------------ the service-info gauge

# (namespace, network) -> labels. Bounded by the services: one entry per tier-submitted Network
# the deployer has seen, dropped when it is seen gone.
_services: dict[tuple[str, str], dict[str, str]] = {}


def _gauge_callback(name: str) -> Any:
    from opentelemetry.metrics import Observation

    def callback(_options: Any) -> list[Any]:
        if name != SERVICE_INFO:
            return []
        with _lock:
            entries = [dict(v) for v in _services.values()]
        return [Observation(1, attributes=e) for e in entries]

    return callback


def set_service_info(network: str, namespace: str, correlation_id: str,
                     construct: str | None) -> None:
    """Add or refresh the ``service_info`` series of one tier-submitted ``Network``."""
    _instrument(SERVICE_INFO)
    labels = {"network": network, "namespace": namespace, "correlation_id": correlation_id,
              "construct": construct or "unknown"}
    with _lock:
        _services[(namespace, network)] = labels


def forget_service_info(network: str, namespace: str) -> None:
    with _lock:
        _services.pop((namespace, network), None)


def sync_service_info(entries: Iterable[tuple[str, str, str, str | None]]) -> None:
    """Replace the cache with exactly ``entries`` (``network, namespace, correlation_id,
    construct``) — a full listing of the tier-submitted Networks."""
    _instrument(SERVICE_INFO)
    fresh = {(ns, net): {"network": net, "namespace": ns, "correlation_id": cid,
                         "construct": construct or "unknown"}
             for net, ns, cid, construct in entries}
    with _lock:
        _services.clear()
        _services.update(fresh)


def service_info() -> list[dict[str, str]]:
    with _lock:
        return sorted((dict(v) for v in _services.values()),
                      key=lambda e: (e["namespace"], e["network"]))


def record_auth_refusal() -> None:
    increment(AUTH_REFUSALS)


def record_out_of_band(change: str) -> None:
    increment(OUT_OF_BAND_CHANGES, change=change)


def value(name: str, **labels: str) -> float:
    """The current value of series ``name`` summed over points whose labels include ``labels``."""
    telemetry = get_telemetry()
    _instrument(name, telemetry)
    data = telemetry.metric_reader.get_metrics_data()
    total = 0.0
    if data is None:
        return total
    for resource_metrics in data.resource_metrics:
        for scope_metrics in resource_metrics.scope_metrics:
            for metric in scope_metrics.metrics:
                if metric.name != name:
                    continue
                for point in metric.data.data_points:
                    attrs = dict(point.attributes or {})
                    if all(attrs.get(k) == v for k, v in labels.items()):
                        total += point.value if hasattr(point, "value") else point.count
    return total


def histogram(name: str, **labels: str) -> tuple[int, float]:
    """``(count, sum)`` of histogram ``name`` over points whose labels include ``labels``."""
    telemetry = get_telemetry()
    _instrument(name, telemetry)
    data = telemetry.metric_reader.get_metrics_data()
    count, total = 0, 0.0
    if data is None:
        return count, total
    for resource_metrics in data.resource_metrics:
        for scope_metrics in resource_metrics.scope_metrics:
            for metric in scope_metrics.metrics:
                if metric.name != name:
                    continue
                for point in metric.data.data_points:
                    attrs = dict(point.attributes or {})
                    if all(attrs.get(k) == v for k, v in labels.items()):
                        count += point.count
                        total += point.sum
    return count, total


def success_rate(stage: str) -> float | None:
    """FR-092's per-stage success rate: successes over all outcomes of ``stage``."""
    counts = {o: value(STAGE_REQUESTS, stage=stage, outcome=o) for o in STAGE_OUTCOMES}
    total = sum(counts.values())
    if total == 0:
        return None
    return sum(counts[o] for o in SUCCESS_OUTCOMES) / total


__all__ = [
    "AUTH_REFUSALS",
    "CHANGES",
    "CONFIRMATIONS",
    "MODEL_CALLS",
    "MODEL_COST",
    "MODEL_TOKENS",
    "OUT_OF_BAND_CHANGES",
    "PREFIX",
    "REFUSAL_CLASSES",
    "REFUSED_UNSAFE",
    "SERVICE_INFO",
    "STAGES",
    "STAGE_DURATION",
    "STAGE_OUTCOMES",
    "STAGE_REQUESTS",
    "SUCCESS_OUTCOMES",
    "WORKER_CALLS",
    "forget_service_info",
    "histogram",
    "increment",
    "observe",
    "outcome_for_status",
    "record_auth_refusal",
    "record_confirmation",
    "record_model_call",
    "record_out_of_band",
    "record_refused_unsafe",
    "record_stage",
    "record_stage_duration",
    "record_worker_call",
    "register",
    "registered_names",
    "service_info",
    "set_service_info",
    "success_rate",
    "sync_service_info",
    "value",
]
