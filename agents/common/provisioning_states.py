"""The closed workflow-status set (T080; data-model.md §17, D-24, FR-054).

No status outside :class:`WorkflowStatus` may appear anywhere — the operator stream and the chat
surface included. ``STATUS_UNKNOWN`` is **never** a success: it never satisfies a convergence
watch, is never counted as converged, and is never reported as completed. A removal that ends at
``PROVISIONING`` is in progress — neither converged nor failed (AD-63).
"""

from __future__ import annotations

from enum import StrEnum
from typing import Literal


class WorkflowStatus(StrEnum):
    RECEIVED_REQUEST = "RECEIVED_REQUEST"
    VALIDATED = "VALIDATED"
    MAPPED = "MAPPED"
    ALLOCATED = "ALLOCATED"
    APPROVED = "APPROVED"
    PROVISIONING = "PROVISIONING"
    CONFIGURED = "CONFIGURED"
    VERIFIED = "VERIFIED"
    COMPLETED = "COMPLETED"
    FAILED = "FAILED"
    STATUS_UNKNOWN = "STATUS_UNKNOWN"


# The same set as a typing Literal, for the strict stream models (common.schemas.stream).
StatusLiteral = Literal[
    "RECEIVED_REQUEST",
    "VALIDATED",
    "MAPPED",
    "ALLOCATED",
    "APPROVED",
    "PROVISIONING",
    "CONFIGURED",
    "VERIFIED",
    "COMPLETED",
    "FAILED",
    "STATUS_UNKNOWN",
]

ALL_STATUSES: frozenset[str] = frozenset(s.value for s in WorkflowStatus)

# Terminal for the pipeline: the request turn stops here. STATUS_UNKNOWN stops the pipeline without
# being an outcome anybody observed.
TERMINAL: frozenset[WorkflowStatus] = frozenset(
    {WorkflowStatus.COMPLETED, WorkflowStatus.FAILED, WorkflowStatus.STATUS_UNKNOWN}
)

# The only statuses that mean the change was observed in effect.
CONVERGED: frozenset[WorkflowStatus] = frozenset(
    {WorkflowStatus.VERIFIED, WorkflowStatus.COMPLETED}
)


def parse_status(value: str) -> WorkflowStatus:
    """Return ``value`` as a member of the closed set, or raise ``ValueError`` naming it."""
    try:
        return WorkflowStatus(value)
    except ValueError:
        raise ValueError(
            f"{value!r} is not a workflow status; the closed set is "
            f"{', '.join(s.value for s in WorkflowStatus)}"
        ) from None


def is_valid_status(value: object) -> bool:
    return isinstance(value, str) and value in ALL_STATUSES


def is_converged(status: str) -> bool:
    """True only for ``COMPLETED`` and ``VERIFIED``: never STATUS_UNKNOWN or PROVISIONING."""
    return is_valid_status(status) and WorkflowStatus(status) in CONVERGED


def is_failed(status: str) -> bool:
    return status == WorkflowStatus.FAILED


def is_unknown(status: str) -> bool:
    return status == WorkflowStatus.STATUS_UNKNOWN


def is_in_progress(status: str) -> bool:
    """A submitted change not yet observed complete — the removal still ``Deleting`` (AD-63)."""
    return status == WorkflowStatus.PROVISIONING


def is_terminal(status: str) -> bool:
    return is_valid_status(status) and WorkflowStatus(status) in TERMINAL


__all__ = [
    "ALL_STATUSES",
    "CONVERGED",
    "TERMINAL",
    "StatusLiteral",
    "WorkflowStatus",
    "is_converged",
    "is_failed",
    "is_in_progress",
    "is_terminal",
    "is_unknown",
    "is_valid_status",
    "parse_status",
]
