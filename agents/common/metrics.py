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

:func:`value` reads a series back in-process (the telemetry's in-memory reader), which is what the
unit tests assert on.
"""

from __future__ import annotations

import threading
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Any

from common.exceptions import MetricNameError
from common.provisioning_states import WorkflowStatus
from common.telemetry import Telemetry, get_telemetry

PREFIX = "agentic_netops_agent_"

STAGE_REQUESTS = "agentic_netops_agent_stage_requests_total"
AUTH_REFUSALS = "agentic_netops_agent_auth_refusals_total"
OUT_OF_BAND_CHANGES = "agentic_netops_agent_out_of_band_changes_total"

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


@dataclass
class _Registered:
    series: Series
    counter: Any


_lock = threading.Lock()
_registry: dict[str, Series] = {}
# id(telemetry) -> (telemetry, name -> instrument); the identity check survives id() reuse.
_bound: dict[int, tuple[Telemetry, dict[str, _Registered]]] = {}


def register(name: str, description: str, labels: Iterable[str] = (),
             allowed: dict[str, Iterable[str]] | None = None) -> Series:
    """Register a counter series. Refuses a name without the literal tier prefix."""
    if not isinstance(name, str) or not name.startswith(PREFIX):
        raise MetricNameError(
            f"metric name {name!r} does not start with the tier prefix {PREFIX!r} "
            "(data-model.md §21); refusing to register it"
        )
    series = Series(name, description, tuple(labels),
                    {k: frozenset(v) for k, v in (allowed or {}).items()})
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
            counter = telemetry.meter("agentic-netops.metrics").create_counter(
                name, description=series.description
            )
            bound[name] = _Registered(series, counter)
        return bound[name]


def increment(name: str, amount: int = 1, **labels: str) -> None:
    reg = _instrument(name)
    series = reg.series
    if set(labels) != set(series.labels):
        raise ValueError(f"{name} takes labels {series.labels}, got {tuple(sorted(labels))}")
    for key, value in labels.items():
        allowed = series.allowed.get(key)
        if allowed is not None and value not in allowed:
            raise ValueError(f"{name}: {key}={value!r} is outside the closed set {sorted(allowed)}")
    reg.counter.add(amount, attributes=labels)


def record_stage(stage: str, outcome: str) -> None:
    increment(STAGE_REQUESTS, stage=stage, outcome=outcome)


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
                        total += point.value
    return total


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
    "OUT_OF_BAND_CHANGES",
    "PREFIX",
    "STAGES",
    "STAGE_OUTCOMES",
    "STAGE_REQUESTS",
    "SUCCESS_OUTCOMES",
    "increment",
    "outcome_for_status",
    "record_auth_refusal",
    "record_out_of_band",
    "record_stage",
    "register",
    "registered_names",
    "success_rate",
    "value",
]
