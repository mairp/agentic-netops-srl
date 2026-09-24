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


def test_the_three_series_of_t080_are_kept_all_prefixed() -> None:
    # T135 adds series beside these three and redefines none of them (AD-50).
    assert {
        "agentic_netops_agent_stage_requests_total",
        "agentic_netops_agent_auth_refusals_total",
        "agentic_netops_agent_out_of_band_changes_total",
    } <= set(metrics.registered_names())
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


# --------------------------------------------------------------------------------------------------
# T135: the series added beside the three (data-model.md §21, AD-50, AD-66)
# --------------------------------------------------------------------------------------------------

T135_SERIES = {
    "agentic_netops_agent_stage_duration_seconds": "histogram",
    "agentic_netops_agent_confirmations_total": "counter",
    "agentic_netops_agent_refused_unsafe_total": "counter",
    "agentic_netops_agent_worker_calls_total": "counter",
    "agentic_netops_agent_model_calls_total": "counter",
    "agentic_netops_agent_model_tokens_total": "counter",
    "agentic_netops_agent_model_cost_usd_total": "counter",
    "agentic_netops_agent_service_info": "observable_gauge",
}


def test_t135_series_are_registered_prefixed_and_the_three_unchanged() -> None:
    assert set(T135_SERIES) <= set(metrics.registered_names())
    assert all(n.startswith(metrics.PREFIX) for n in metrics.registered_names())
    for name, kind in T135_SERIES.items():
        assert metrics._registry[name].kind == kind, name
    # the three of T080, exactly as they were
    stage = metrics._registry[metrics.STAGE_REQUESTS]
    assert (stage.labels, stage.kind) == (("stage", "outcome"), "counter")
    assert metrics._registry[metrics.AUTH_REFUSALS].labels == ()
    assert metrics._registry[metrics.OUT_OF_BAND_CHANGES].labels == ("change",)


@pytest.mark.parametrize("kind", ["histogram", "observable_gauge"])
def test_register_refuses_an_unprefixed_histogram_or_gauge(kind: str) -> None:
    with pytest.raises(MetricNameError, match="agentic_netops_agent_"):
        metrics.register("stage_duration_seconds", "x", kind=kind)
    assert "stage_duration_seconds" not in metrics.registered_names()


def test_every_metric_name_constant_of_the_module_carries_the_prefix() -> None:
    tree = ast.parse((AGENTS / "common" / "metrics.py").read_text())
    names = [n.value for n in ast.walk(tree)
             if isinstance(n, ast.Constant) and isinstance(n.value, str)
             and n.value.startswith(("agentic_netops", "Agentic"))
             and not n.value.startswith("agentic-netops")]
    assert set(T135_SERIES) <= set(names)
    assert all(n.startswith("agentic_netops_agent_") for n in names), names


def test_stage_duration_histogram_and_success_rate_from_stage_requests() -> None:
    metrics.record_stage_duration("mapper", "succeeded", 1.5)
    metrics.record_stage_duration("mapper", "succeeded", 0.5)
    metrics.record_stage_duration("mapper", "failed", 3.0)
    assert metrics.histogram(metrics.STAGE_DURATION, stage="mapper", outcome="succeeded") == (
        2, 2.0)
    assert metrics.histogram(metrics.STAGE_DURATION, stage="mapper")[0] == 3
    # the success rate stays computed from the one per-stage counter, never from the histogram
    assert metrics.success_rate("mapper") is None
    metrics.record_stage("mapper", "succeeded")
    metrics.record_stage("mapper", "failed")
    assert metrics.success_rate("mapper") == 0.5
    with pytest.raises(ValueError, match="closed set"):
        metrics.record_stage_duration("mapper", "COMPLETED", 1.0)
    with pytest.raises(ValueError, match="not a counter"):
        metrics.increment(metrics.STAGE_DURATION, stage="mapper", outcome="succeeded")


def test_confirmation_refusal_worker_and_model_counters() -> None:
    metrics.record_confirmation("confirmation_1", "confirmed")
    metrics.record_confirmation("second", "declined")
    assert metrics.value(metrics.CONFIRMATIONS, confirmation="first", decision="confirmed") == 1
    assert metrics.value(metrics.CONFIRMATIONS, confirmation="second", decision="declined") == 1
    with pytest.raises(ValueError, match="closed set"):
        metrics.record_confirmation("third", "confirmed")
    metrics.record_refused_unsafe("unknown-tool")
    assert metrics.value(metrics.REFUSED_UNSAFE, **{"class": "unknown-tool"}) == 1
    with pytest.raises(ValueError, match="closed set"):
        metrics.record_refused_unsafe("rude")
    metrics.record_worker_call("allocator", "unreachable")
    assert metrics.value(metrics.WORKER_CALLS, worker="allocator", outcome="unreachable") == 1
    metrics.record_model_call("openai/gpt-4o", "succeeded", input_tokens=10, output_tokens=3,
                              cost=0.5)
    metrics.record_model_call("openai/gpt-4o", "failed")
    assert metrics.value(metrics.MODEL_CALLS, model="openai/gpt-4o") == 2
    assert metrics.value(metrics.MODEL_TOKENS, model="openai/gpt-4o", kind="input") == 10
    assert metrics.value(metrics.MODEL_TOKENS, model="openai/gpt-4o", kind="output") == 3
    assert metrics.value(metrics.MODEL_COST, model="openai/gpt-4o") == 0.5


def test_service_info_is_one_series_per_network_and_bounded_by_them() -> None:
    metrics.sync_service_info([("migr-a", "ns", "a" * 32, "vlan"),
                               ("migr-b", "ns", "b" * 32, None)])
    metrics.set_service_info("migr-a", "ns", "a" * 32, "vlan")  # a refresh adds nothing
    assert metrics.value(metrics.SERVICE_INFO) == 2
    assert metrics.value(metrics.SERVICE_INFO, network="migr-b", construct="unknown") == 1
    metrics.forget_service_info("migr-b", "ns")
    assert [e["network"] for e in metrics.service_info()] == ["migr-a"]
    metrics.sync_service_info([])
    assert metrics.value(metrics.SERVICE_INFO) == 0
