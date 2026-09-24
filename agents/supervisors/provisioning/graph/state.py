"""Per-thread state of the supervisor graph (T085; data-model.md §7 ServiceRequest).

The durable fields are the ``ServiceRequest`` of §7, checkpointed by the SQLite checkpointer and
keyed by thread. The ``turn_*`` fields belong to one request turn (one POST) and are reset by the
intake node; ``pending``/``awaiting`` say where the pipeline stands between turns.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Literal, TypedDict

Decided = Literal["confirm", "decline"]
Operation = Literal["create", "remove"]
Awaiting = Literal["confirmation_1", "confirmation_2"]
PendingStage = Literal["mapper", "allocator", "deployer"]


class Decision(TypedDict):
    """``{decided, at, principal}`` — the principal authenticated on the request carrying it."""

    decided: Decided
    at: str
    principal: str


def decision(decided: Decided, principal: str, at: datetime | None = None) -> Decision:
    return Decision(decided=decided, at=(at or datetime.now(UTC)).isoformat(),
                    principal=principal)


class ServiceRequestState(TypedDict, total=False):
    # data-model.md §7
    thread_id: str
    correlation_id: str
    principal: str
    original_text: str
    workflow_status: str
    iteration_count: int
    deadline: str | None
    confirmation_1: Decision | None
    confirmation_2: Decision | None
    claimed_ids: list[dict[str, Any]]
    released_ids: list[dict[str, Any]]
    interpretation: dict[str, Any] | None
    assignment: dict[str, Any] | None
    submitted_resources: list[dict[str, Any]]
    # where the pipeline stands between turns
    operation: Operation
    pending: PendingStage | None
    awaiting: Awaiting | None
    submission_key: str | None
    converged: bool
    active_seconds: float  # request time consumed so far, confirmation time excluded
    # this request turn
    new_thread: bool
    turn_text: str
    turn_principal: str
    turn_class: str | None
    turn_consumed: bool
    turn_done: bool
    turn_started: float
    active_base: float
    next: str
    exit_reason: str | None


@dataclass(frozen=True)
class Bounds:
    """The two supervisor bounds of data-model.md §25 the router applies."""

    max_iterations: int
    request_deadline_seconds: float

    @classmethod
    def from_settings(cls, settings: Any) -> Bounds:
        return cls(settings.max_iterations, settings.request_deadline_seconds)
