"""Settings (T080; data-model.md §25, D-27): defaults, overrides, the start-up invariant."""

from __future__ import annotations

from pathlib import Path

import pytest

from common.exceptions import BoundsConfigurationError, TransportConfigurationError
from config.settings import Settings, load_settings

BOUNDS = {
    "SUPERVISOR_MAX_ITERATIONS": ("max_iterations", 3),
    "SUPERVISOR_REQUEST_DEADLINE_SECONDS": ("request_deadline_seconds", 300.0),
    "WORKER_CALL_TIMEOUT_SECONDS": ("worker_call_timeout_seconds", 60.0),
    "DEPLOYER_CALL_TIMEOUT_SECONDS": ("deployer_call_timeout_seconds", 210.0),
    "WORKER_CALL_RETRIES": ("worker_call_retries", 2),
    "WORKER_CALL_BACKOFF_SECONDS": ("worker_call_backoff_seconds", 1.0),
    "DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS": ("convergence_timeout_seconds", 150.0),
    "MODEL_CALL_TIMEOUT_SECONDS": ("model_call_timeout_seconds", 45.0),
}


def test_section_25_defaults() -> None:
    settings = load_settings({})
    for attribute, default in BOUNDS.values():
        assert getattr(settings, attribute) == default, attribute
    assert settings.auth_failure_delay_seconds == 1.0


def test_default_paths_and_endpoints() -> None:
    s = load_settings({})
    assert s.transport == "SLIM"
    assert s.transport_endpoint == "http://slim.agentic-netops-agents.svc:46357"
    assert s.otlp_endpoint == "http://agent-otel-collector.agentic-netops-agents.svc:4318"
    assert s.slim_gateway_dir == Path("/var/run/secrets/agentic-netops/slim-gateway")
    assert s.llm_provider_dir == Path("/var/run/secrets/agentic-netops/llm-provider")
    assert s.operator_credentials_dir == Path(
        "/var/run/secrets/agentic-netops/operator-credentials")
    assert s.agent_cards_dir == Path("/etc/agentic-netops/agent-cards")
    assert s.site_inventory_dir == Path("/etc/agentic-netops/site-inventory")
    assert s.fabric_qualification_dir == Path("/etc/agentic-netops/fabric-qualification")
    assert s.checkpoint_path == Path("/var/lib/supervisor/checkpoints.sqlite")


@pytest.mark.parametrize(("component", "port"),
                         [("supervisor", 9090), ("allocator", 9091), ("mapper", 9092),
                          ("deployer", 9093)])
def test_component_ports(component: str, port: int) -> None:
    assert load_settings({"AGENT_COMPONENT": component}).port == port


def test_overrides_are_honoured() -> None:
    s = load_settings({
        "SUPERVISOR_MAX_ITERATIONS": "5",
        "SUPERVISOR_REQUEST_DEADLINE_SECONDS": "280",
        "WORKER_CALL_TIMEOUT_SECONDS": "30",
        "MODEL_CALL_TIMEOUT_SECONDS": "20",
        "DEPLOYER_CALL_TIMEOUT_SECONDS": "200",
        "WORKER_CALL_RETRIES": "0",
        "WORKER_CALL_BACKOFF_SECONDS": "0.5",
        "DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS": "120",
    })
    assert (s.max_iterations, s.request_deadline_seconds, s.worker_call_timeout_seconds,
            s.deployer_call_timeout_seconds, s.worker_call_retries,
            s.worker_call_backoff_seconds, s.convergence_timeout_seconds) == (
        5, 280.0, 30.0, 200.0, 0, 0.5, 120.0)


@pytest.mark.parametrize(
    "env",
    [
        {"DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS": "210"},            # convergence == deployer call
        {"DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS": "250"},            # convergence > deployer call
        {"DEPLOYER_CALL_TIMEOUT_SECONDS": "300"},                   # deployer call == deadline
        {"SUPERVISOR_REQUEST_DEADLINE_SECONDS": "200"},             # deadline < deployer call
        {"SUPERVISOR_REQUEST_DEADLINE_SECONDS": "400"},             # past SC-023's five minutes
        {"DEPLOYER_CALL_TIMEOUT_SECONDS": "100"},                   # deployer call < convergence
    ],
    ids=["conv-eq-call", "conv-gt-call", "call-eq-deadline", "deadline-lt-call",
         "deadline-past-sc023", "call-lt-conv"],
)
def test_inconsistent_override_refused_at_start_up(env: dict[str, str]) -> None:
    with pytest.raises(BoundsConfigurationError, match="DEPLOYER_CALL_TIMEOUT_SECONDS"):
        load_settings(env)


@pytest.mark.parametrize(
    ("env", "name"),
    [
        ({"SUPERVISOR_MAX_ITERATIONS": "three"}, "SUPERVISOR_MAX_ITERATIONS"),
        ({"SUPERVISOR_MAX_ITERATIONS": "0"}, "SUPERVISOR_MAX_ITERATIONS"),
        ({"WORKER_CALL_RETRIES": "-1"}, "WORKER_CALL_RETRIES"),
        ({"WORKER_CALL_TIMEOUT_SECONDS": "nan"}, "WORKER_CALL_TIMEOUT_SECONDS"),
    ],
)
def test_unparseable_bound_refused_naming_the_variable(env: dict[str, str], name: str) -> None:
    with pytest.raises(BoundsConfigurationError, match=name):
        load_settings(env)


def test_with_overrides_reasserts_the_invariant() -> None:
    s = load_settings({})
    assert s.with_overrides(max_iterations=7).max_iterations == 7
    with pytest.raises(BoundsConfigurationError):
        s.with_overrides(convergence_timeout_seconds=500.0)


def test_transport_endpoint_long_name_only() -> None:
    env = {"TRANSPORT_SERVER_ENDPOINT": "http://slim.example:46357"}
    assert load_settings(env).transport_endpoint == "http://slim.example:46357"
    # The README's short name and other near-misses are read by nothing (D-27).
    for short in ("TRANSPORT_ENDPOINT", "SLIM_ENDPOINT", "TRANSPORT_SERVER", "SLIM_SERVER"):
        assert load_settings({short: "http://wrong:1"}).transport_endpoint == (
            "http://slim.agentic-netops-agents.svc:46357")


def test_non_slim_transport_raises_rather_than_falls_back() -> None:
    settings = load_settings({"DEFAULT_MESSAGE_TRANSPORT": "NATS"})
    with pytest.raises(TransportConfigurationError, match="NATS"):
        settings.require_slim()
    Settings().require_slim()  # the default is SLIM and passes


@pytest.mark.parametrize("env", [
    {"MODEL_CALL_TIMEOUT_SECONDS": "60"},                                  # == worker call
    {"MODEL_CALL_TIMEOUT_SECONDS": "90"},                                  # > worker call
    {"WORKER_CALL_TIMEOUT_SECONDS": "30"},                                 # worker below default
])
def test_a_model_call_bound_not_below_the_worker_call_refuses_the_start(
        env: dict[str, str]) -> None:
    """NFR-010: a provider holding a call must be reported by the worker that made it, naming the
    model provider, before the supervisor's call to that worker times out."""
    with pytest.raises(BoundsConfigurationError, match="MODEL_CALL_TIMEOUT_SECONDS"):
        load_settings(env)


def test_a_model_call_bound_below_the_worker_call_starts() -> None:
    s = load_settings({"MODEL_CALL_TIMEOUT_SECONDS": "59", "WORKER_CALL_TIMEOUT_SECONDS": "60"})
    assert s.model_call_timeout_seconds == 59.0


def test_the_model_reasoning_effort_defaults_low_and_is_a_closed_set() -> None:
    assert load_settings({}).model_reasoning_effort == "low"
    assert load_settings({"MODEL_REASONING_EFFORT": ""}).model_reasoning_effort == ""
    assert load_settings({"MODEL_REASONING_EFFORT": "High"}).model_reasoning_effort == "high"
    with pytest.raises(ValueError, match="MODEL_REASONING_EFFORT"):
        load_settings({"MODEL_REASONING_EFFORT": "turbo"})
