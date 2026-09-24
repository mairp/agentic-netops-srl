"""The intent tier's exception hierarchy (T080; D-23, FR-072 to FR-074, FR-106, NFR-010).

Correctly spelled and **wired in**: the predecessor's orphaned, misspelled module is replaced by
this one, and every error below is raised by the code that detects it — the transport raises the two
worker-failure classes and the authentication error, the settings raise the bounds error, the model
client raises the endpoint error, the supervisor's submission stage raises the submission refusal.

Every class carries an operator-facing message that names the dependency or the worker, because
the message is what the stream shows (FR-074, NFR-010).
"""

from __future__ import annotations


class AgenticNetopsError(Exception):
    """Base of every error the tier raises on purpose."""


# --------------------------------------------------------------------------------------------------
# configuration
# --------------------------------------------------------------------------------------------------


class ConfigurationError(AgenticNetopsError):
    """A setting or a mounted input cannot be used; the process refuses to start."""


class BoundsConfigurationError(ConfigurationError):
    """A data-model.md §25 bound is unparseable, out of range, or breaks the start-up invariant

    ``convergence timeout < deployer call timeout < request deadline <= 300 s``.
    """


class EndpointError(ConfigurationError):
    """There is no endpoint a model call may go to (FR-106).

    The message names what is missing: the declared gateway, or the ``BASE_URL`` of the mounted
    ``llm-provider`` Secret. Re-exported as :class:`common.llm.EndpointError`.
    """


class MetricNameError(ConfigurationError, ValueError):
    """A metric name without the tier prefix ``agentic_netops_agent_`` (data-model.md §21)."""


# --------------------------------------------------------------------------------------------------
# transport (contracts/a2a-transport.md)
# --------------------------------------------------------------------------------------------------


class TransportError(AgenticNetopsError):
    """The agent-to-agent transport itself failed."""


class TransportConfigurationError(TransportError, ConfigurationError):
    """The transport is not SLIM, or its endpoint is missing: raised, never fallen back from
    (D-27)."""


class TransportAuthenticationError(TransportError):
    """The SLIM gateway refused the registration or connection for want of valid credentials."""


class WorkerError(AgenticNetopsError):
    """A worker call did not produce a usable answer. ``worker`` names the worker."""

    retryable: bool = False

    def __init__(self, worker: str, message: str) -> None:
        super().__init__(message)
        self.worker = worker


class WorkerUnreachableError(WorkerError):
    """``worker unreachable: <name>`` — topic unresolved, transport error or timeout, no answer.

    Retryable, and the thread stays resumable. ``after_send`` is true when the request had
    already been handed to the transport when the failure happened: for a submission that means
    its outcome is **unknown** (FR-054), which the supervisor reports as ``STATUS_UNKNOWN``.
    """

    retryable = True

    def __init__(self, worker: str, *, after_send: bool = False, cause: str | None = None) -> None:
        super().__init__(worker, f"worker unreachable: {worker}")
        self.after_send = after_send
        self.cause = cause


class WorkerFailedError(WorkerError):
    """``worker failed: <name> — <reason>`` — the worker answered with an error or an
    out-of-contract payload. Terminal for the stage; never retried."""

    retryable = False

    def __init__(self, worker: str, reason: str) -> None:
        super().__init__(worker, f"worker failed: {worker} — {reason}")
        self.reason = reason


# --------------------------------------------------------------------------------------------------
# supervisor
# --------------------------------------------------------------------------------------------------


class AuthenticationRequiredError(AgenticNetopsError):
    """No or a wrong operator credential (FR-102). Refused before any thread exists."""

    def __init__(self, detail: str = "authentication required") -> None:
        super().__init__(detail)
        self.detail = detail


class SubmissionRefusedError(AgenticNetopsError):
    """The submission invariant of data-model.md §7: status APPROVED and a confirm on the second
    confirmation, enforced in the submission stage and not merely in routing (FR-055)."""


class BoundedExitError(AgenticNetopsError):
    """The iteration cap or the wall-clock deadline ended the request turn (FR-053)."""


__all__ = [
    "AgenticNetopsError",
    "AuthenticationRequiredError",
    "BoundedExitError",
    "BoundsConfigurationError",
    "ConfigurationError",
    "EndpointError",
    "MetricNameError",
    "SubmissionRefusedError",
    "TransportAuthenticationError",
    "TransportConfigurationError",
    "TransportError",
    "WorkerError",
    "WorkerFailedError",
    "WorkerUnreachableError",
]
