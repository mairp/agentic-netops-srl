"""Tier metrics on the one exporter (T080; data-model.md §21, R-24, AD-54, AD-63, AD-66)."""

from __future__ import annotations

import ast
from collections.abc import Iterator
from pathlib import Path

import pytest

from common import metrics, telemetry
from common.exceptions import MetricNameError

AGENTS = Path(__file__).resolve().parents[2]


@pytest.fixture(autouse=True)
def fresh_telemetry() -> Iterator[None]:
    telemetry.reset_for_tests()
    telemetry.init_telemetry("supervisor", otlp=False)
    yield
    telemetry.reset_for_tests()


def test_exactly_three_series_all_prefixed() -> None:
    assert metrics.registered_names() == sorted([
        "agentic_netops_agent_stage_requests_total",
        "agentic_netops_agent_auth_refusals_total",
        "agentic_netops_agent_out_of_band_changes_total",
    ])
    assert all(n.startswith("agentic_netops_agent_") for n in metrics.registered_names())


@pytest.mark.parametrize("name", ["stage_requests_total", "agentic_netops_stage_total",
                                  "Agentic_netops_agent_x", "", "agentic-netops-agent_x"])
def test_register_refuses_a_name_without_the_prefix(name: str) -> None:
    with pytest.raises(MetricNameError, match="agentic_netops_agent_"):
        metrics.register(name, "x")
    assert name not in metrics.registered_names()


def test_every_metric_name_literal_in_the_module_carries_the_prefix() -> None:
    tree = ast.parse((AGENTS / "common" / "metrics.py").read_text())
    names = [n.value for n in ast.walk(tree)
             if isinstance(n, ast.Constant) and isinstance(n.value, str)
             and n.value.endswith("_total")]
    assert names and all(n.startswith("agentic_netops_agent_") for n in names), names


def test_stage_counter_counts_by_stage_and_outcome() -> None:
    metrics.record_stage("mapper", "succeeded")
    metrics.record_stage("mapper", "succeeded")
    metrics.record_stage("deployer", "converged")
    assert metrics.value(metrics.STAGE_REQUESTS, stage="mapper", outcome="succeeded") == 2
    assert metrics.value(metrics.STAGE_REQUESTS, stage="deployer", outcome="converged") == 1
    assert metrics.value(metrics.STAGE_REQUESTS, stage="allocator") == 0


def test_stage_outcome_set_is_closed() -> None:
    with pytest.raises(ValueError, match="closed set"):
        metrics.record_stage("deployer", "COMPLETED")
    with pytest.raises(ValueError, match="closed set"):
        metrics.record_stage("translator", "converged")


def test_status_unknown_is_never_converged() -> None:
    assert metrics.outcome_for_status("STATUS_UNKNOWN") == "status_unknown"
    metrics.record_stage("deployer", metrics.outcome_for_status("STATUS_UNKNOWN"))
    assert metrics.value(metrics.STAGE_REQUESTS, stage="deployer", outcome="converged") == 0
    assert metrics.value(metrics.STAGE_REQUESTS, stage="deployer", outcome="status_unknown") == 1
    assert metrics.success_rate("deployer") == 0.0


def test_removal_ending_provisioning_is_in_progress() -> None:
    outcome = metrics.outcome_for_status("PROVISIONING", removal=True)
    assert outcome == "in_progress"
    assert outcome not in ("converged", "failed")
    metrics.record_stage("deployer", outcome)
    metrics.record_stage("deployer", "converged")
    assert metrics.success_rate("deployer") == 0.5


def test_auth_refusals_and_out_of_band_counters() -> None:
    metrics.record_auth_refusal()
    metrics.record_auth_refusal()
    metrics.record_out_of_band("modified")
    assert metrics.value(metrics.AUTH_REFUSALS) == 2
    assert metrics.value(metrics.OUT_OF_BAND_CHANGES, change="modified") == 1
    assert metrics.value(metrics.OUT_OF_BAND_CHANGES, change="deleted") == 0
    with pytest.raises(ValueError, match="closed set"):
        metrics.record_out_of_band("drifted")


def test_one_exporter_per_process() -> None:
    telemetry.reset_for_tests()
    first = telemetry.init_telemetry("supervisor", endpoint="http://127.0.0.1:9", otlp=True)
    second = telemetry.init_telemetry("supervisor", endpoint="http://127.0.0.1:9", otlp=True)
    third = telemetry.init_telemetry("mapper", otlp=True)
    assert first is second is third
    assert telemetry.exporters_created == 1
    # The metrics ride that one bundle.
    metrics.record_auth_refusal()
    assert metrics.value(metrics.AUTH_REFUSALS) == 1
