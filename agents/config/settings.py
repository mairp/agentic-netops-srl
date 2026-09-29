"""Environment-driven settings of every intent-tier agent (T080; data-model.md §25, D-27).

Every bound data-model.md §25 names is a setting here with that table's default, read from the
environment of the workload that owns it — never a constant a change of value would need a rebuild
for. :func:`load_settings` asserts the start-up invariant

    convergence timeout < deployer call timeout < request deadline <= 300 s (SC-023)

and raises :class:`~common.exceptions.BoundsConfigurationError` naming the variables when an
override breaks it, so an override can never silently make a bound unreachable.

The transport endpoint is read from ``TRANSPORT_SERVER_ENDPOINT`` **only** — the long name; the
README's short name is read by nothing (D-27).
"""

from __future__ import annotations

import math
import os
from collections.abc import Mapping
from dataclasses import dataclass, field, replace
from pathlib import Path

from common.exceptions import BoundsConfigurationError, TransportConfigurationError

DEFAULT_TRANSPORT = "SLIM"
DEFAULT_TRANSPORT_ENDPOINT = "http://slim.agentic-netops-agents.svc:46357"
DEFAULT_OTLP_ENDPOINT = "http://agent-otel-collector.agentic-netops-agents.svc:4318"

# §25 defaults, stated here once for the code (data-model.md §25 is the specification).
DEFAULT_MAX_ITERATIONS = 3
DEFAULT_REQUEST_DEADLINE_SECONDS = 300.0
DEFAULT_WORKER_CALL_TIMEOUT_SECONDS = 60.0
DEFAULT_DEPLOYER_CALL_TIMEOUT_SECONDS = 210.0
DEFAULT_WORKER_CALL_RETRIES = 2
DEFAULT_WORKER_CALL_BACKOFF_SECONDS = 1.0
DEFAULT_CONVERGENCE_TIMEOUT_SECONDS = 150.0
# One model call, the library's own retries included: below the worker call timeout, so a provider
# that holds a call is reported by the worker that made it, naming the model provider, before the
# supervisor's call to that worker times out (NFR-010).
DEFAULT_MODEL_CALL_TIMEOUT_SECONDS = 45.0
# The reasoning effort asked of a reasoning model on every call; dropped by the client for a model
# that takes no such parameter, so it is provider-neutral (NFR-008). "low" keeps a reasoning
# model's interpretation inside the model call timeout above (T144 live: gpt-5 took up to 57 s at
# its own default, 14-18 s at "low"). An empty value asks for the provider's own default.
DEFAULT_MODEL_REASONING_EFFORT = "low"
MODEL_REASONING_EFFORTS = frozenset({"", "minimal", "low", "medium", "high"})
# SC-023's five minutes: the request deadline may be lowered, never raised past it.
SC023_CEILING_SECONDS = 300.0

DEFAULT_AUTH_FAILURE_DELAY_SECONDS = 1.0
# How long the SLIM authentication round trip waits for its echo (the gateway's refusal is silent).
DEFAULT_TRANSPORT_AUTH_CHECK_SECONDS = 5.0

COMPONENT_PORTS = {"supervisor": 9090, "allocator": 9091, "mapper": 9092, "deployer": 9093}


@dataclass(frozen=True)
class Settings:
    component: str = "supervisor"
    transport: str = DEFAULT_TRANSPORT
    transport_endpoint: str = DEFAULT_TRANSPORT_ENDPOINT
    slim_gateway_dir: Path = Path("/var/run/secrets/agentic-netops/slim-gateway")
    slim_tls_dir: Path = Path("/var/run/secrets/agentic-netops/slim-tls")
    llm_provider_dir: Path = Path("/var/run/secrets/agentic-netops/llm-provider")
    operator_credentials_dir: Path = Path("/var/run/secrets/agentic-netops/operator-credentials")
    agent_cards_dir: Path = Path("/etc/agentic-netops/agent-cards")
    site_inventory_dir: Path = Path("/etc/agentic-netops/site-inventory")
    fabric_qualification_dir: Path = Path("/etc/agentic-netops/fabric-qualification")
    checkpoint_path: Path = Path("/var/lib/supervisor/checkpoints.sqlite")
    otlp_endpoint: str = DEFAULT_OTLP_ENDPOINT
    port: int = 9090
    # data-model.md §25
    max_iterations: int = DEFAULT_MAX_ITERATIONS
    request_deadline_seconds: float = DEFAULT_REQUEST_DEADLINE_SECONDS
    worker_call_timeout_seconds: float = DEFAULT_WORKER_CALL_TIMEOUT_SECONDS
    deployer_call_timeout_seconds: float = DEFAULT_DEPLOYER_CALL_TIMEOUT_SECONDS
    worker_call_retries: int = DEFAULT_WORKER_CALL_RETRIES
    worker_call_backoff_seconds: float = DEFAULT_WORKER_CALL_BACKOFF_SECONDS
    convergence_timeout_seconds: float = DEFAULT_CONVERGENCE_TIMEOUT_SECONDS
    model_call_timeout_seconds: float = DEFAULT_MODEL_CALL_TIMEOUT_SECONDS
    model_reasoning_effort: str = DEFAULT_MODEL_REASONING_EFFORT
    # FR-102: the fixed cost of a failed authentication attempt.
    auth_failure_delay_seconds: float = DEFAULT_AUTH_FAILURE_DELAY_SECONDS
    # The bound of common.transport.check_transport_auth (slim-live.md).
    transport_auth_check_seconds: float = DEFAULT_TRANSPORT_AUTH_CHECK_SECONDS
    extra: Mapping[str, str] = field(default_factory=dict, compare=False, repr=False)

    def with_overrides(self, **changes: object) -> Settings:
        """A copy with ``changes`` applied and the start-up invariant re-asserted."""
        updated = replace(self, **changes)  # type: ignore[arg-type]
        assert_bounds(updated)
        return updated

    def require_slim(self) -> None:
        """The call helpers hard-require SLIM and raise rather than fall back (D-27)."""
        if self.transport != DEFAULT_TRANSPORT:
            raise TransportConfigurationError(
                f"transport {self.transport!r} is not supported: the intent tier's message "
                f"transport is {DEFAULT_TRANSPORT} and nothing falls back from it"
            )
        if not self.transport_endpoint:
            raise TransportConfigurationError(
                "TRANSPORT_SERVER_ENDPOINT is empty: the SLIM data-plane endpoint is required"
            )


# --------------------------------------------------------------------------------------------------
# parsing
# --------------------------------------------------------------------------------------------------


def _number(env: Mapping[str, str], name: str, default: float, *, integer: bool,
            minimum: float) -> float:
    raw = env.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        value = int(raw.strip()) if integer else float(raw.strip())
    except ValueError:
        kind = "an integer" if integer else "a number of seconds"
        raise BoundsConfigurationError(f"{name}={raw!r} is not {kind}") from None
    if isinstance(value, float) and not math.isfinite(value):
        raise BoundsConfigurationError(f"{name}={raw!r} is not a finite number")
    if value < minimum:
        raise BoundsConfigurationError(f"{name}={raw!r} is below its floor of {minimum:g}")
    return value


def _reasoning_effort(env: Mapping[str, str]) -> str:
    value = env.get("MODEL_REASONING_EFFORT", DEFAULT_MODEL_REASONING_EFFORT).strip().lower()
    if value not in MODEL_REASONING_EFFORTS:
        raise ValueError(f"MODEL_REASONING_EFFORT={value!r} is not one of "
                         f"{sorted(e for e in MODEL_REASONING_EFFORTS if e)} or empty")
    return value


def assert_bounds(settings: Settings) -> None:
    """The start-up assertion of data-model.md §25."""
    c = settings.convergence_timeout_seconds
    d = settings.deployer_call_timeout_seconds
    r = settings.request_deadline_seconds
    if not (c < d < r <= SC023_CEILING_SECONDS):
        raise BoundsConfigurationError(
            "inconsistent bounds: DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS "
            f"({c:g}) < DEPLOYER_CALL_TIMEOUT_SECONDS ({d:g}) < "
            f"SUPERVISOR_REQUEST_DEADLINE_SECONDS ({r:g}) <= {SC023_CEILING_SECONDS:g} must hold "
            "(data-model.md §25); refusing to start"
        )
    if settings.max_iterations < 1:
        raise BoundsConfigurationError("SUPERVISOR_MAX_ITERATIONS must be at least 1")
    if settings.worker_call_retries < 0:
        raise BoundsConfigurationError("WORKER_CALL_RETRIES must not be negative")


def assert_model_bound(settings: Settings) -> None:
    """A model call is bounded below the worker call that contains it, so a provider that holds a
    call is reported by the worker that made it, naming the model provider (NFR-010). Asserted at
    start-up from the environment; a test override of one bound alone is not a deployment."""
    if not settings.model_call_timeout_seconds < settings.worker_call_timeout_seconds:
        raise BoundsConfigurationError(
            f"inconsistent bounds: MODEL_CALL_TIMEOUT_SECONDS "
            f"({settings.model_call_timeout_seconds:g}) < WORKER_CALL_TIMEOUT_SECONDS "
            f"({settings.worker_call_timeout_seconds:g}) must hold (NFR-010); refusing to start"
        )


def load_settings(env: Mapping[str, str] | None = None) -> Settings:
    """Read the settings from ``env`` (default ``os.environ``) and assert the §25 invariant."""
    env = dict(os.environ if env is None else env)
    component = env.get("AGENT_COMPONENT", "supervisor").strip() or "supervisor"

    def path(name: str, default: Path) -> Path:
        value = env.get(name, "").strip()
        return Path(value) if value else default

    base = Settings()
    port_default = COMPONENT_PORTS.get(component, 9090)
    settings = Settings(
        component=component,
        transport=env.get("DEFAULT_MESSAGE_TRANSPORT", DEFAULT_TRANSPORT).strip()
        or DEFAULT_TRANSPORT,
        # The long name, and only the long name (D-27).
        transport_endpoint=env.get("TRANSPORT_SERVER_ENDPOINT", DEFAULT_TRANSPORT_ENDPOINT).strip()
        or DEFAULT_TRANSPORT_ENDPOINT,
        slim_gateway_dir=path("SLIM_GATEWAY_DIR", base.slim_gateway_dir),
        slim_tls_dir=path("SLIM_TLS_DIR", base.slim_tls_dir),
        llm_provider_dir=path("LLM_PROVIDER_DIR", base.llm_provider_dir),
        operator_credentials_dir=path("OPERATOR_CREDENTIALS_DIR", base.operator_credentials_dir),
        agent_cards_dir=path("AGENT_CARDS_DIR", base.agent_cards_dir),
        site_inventory_dir=path("SITE_INVENTORY_DIR", base.site_inventory_dir),
        fabric_qualification_dir=path("FABRIC_QUALIFICATION_DIR", base.fabric_qualification_dir),
        checkpoint_path=path("SUPERVISOR_CHECKPOINT_PATH", base.checkpoint_path),
        otlp_endpoint=env.get("OTEL_EXPORTER_OTLP_ENDPOINT", DEFAULT_OTLP_ENDPOINT).strip()
        or DEFAULT_OTLP_ENDPOINT,
        port=int(_number(env, "PORT", port_default, integer=True, minimum=1)),
        max_iterations=int(_number(env, "SUPERVISOR_MAX_ITERATIONS", DEFAULT_MAX_ITERATIONS,
                                   integer=True, minimum=1)),
        request_deadline_seconds=_number(env, "SUPERVISOR_REQUEST_DEADLINE_SECONDS",
                                         DEFAULT_REQUEST_DEADLINE_SECONDS, integer=False,
                                         minimum=1),
        worker_call_timeout_seconds=_number(env, "WORKER_CALL_TIMEOUT_SECONDS",
                                            DEFAULT_WORKER_CALL_TIMEOUT_SECONDS, integer=False,
                                            minimum=1),
        deployer_call_timeout_seconds=_number(env, "DEPLOYER_CALL_TIMEOUT_SECONDS",
                                              DEFAULT_DEPLOYER_CALL_TIMEOUT_SECONDS,
                                              integer=False, minimum=1),
        worker_call_retries=int(_number(env, "WORKER_CALL_RETRIES", DEFAULT_WORKER_CALL_RETRIES,
                                        integer=True, minimum=0)),
        worker_call_backoff_seconds=_number(env, "WORKER_CALL_BACKOFF_SECONDS",
                                            DEFAULT_WORKER_CALL_BACKOFF_SECONDS, integer=False,
                                            minimum=0),
        convergence_timeout_seconds=_number(env, "DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS",
                                            DEFAULT_CONVERGENCE_TIMEOUT_SECONDS, integer=False,
                                            minimum=1),
        model_call_timeout_seconds=_number(env, "MODEL_CALL_TIMEOUT_SECONDS",
                                           DEFAULT_MODEL_CALL_TIMEOUT_SECONDS, integer=False,
                                           minimum=1),
        model_reasoning_effort=_reasoning_effort(env),
        auth_failure_delay_seconds=_number(env, "OPERATOR_AUTH_FAILURE_DELAY_SECONDS",
                                           DEFAULT_AUTH_FAILURE_DELAY_SECONDS, integer=False,
                                           minimum=0),
        transport_auth_check_seconds=_number(env, "SLIM_AUTH_CHECK_TIMEOUT_SECONDS",
                                             DEFAULT_TRANSPORT_AUTH_CHECK_SECONDS, integer=False,
                                             minimum=0.001),
        extra=env,
    )
    assert_bounds(settings)
    assert_model_bound(settings)
    return settings


__all__ = [
    "COMPONENT_PORTS",
    "DEFAULT_TRANSPORT_ENDPOINT",
    "Settings",
    "assert_bounds",
    "load_settings",
]
