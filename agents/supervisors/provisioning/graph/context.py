"""What every supervisor node shares: the run-scoped context, the chunk writer and the names of the
objects the tier works with (T085, T101; contracts/supervisor-http.md, data-model.md §15, §17).

Split out of :mod:`.nodes` so that :mod:`.confirmations` and :mod:`.audit` use the same writer
without importing the node module that imports them.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from langgraph.runtime import Runtime

from common.schemas.stream import build_chunk
from common.transport import TransportClient
from config.settings import Settings
from supervisors.provisioning.graph.state import ServiceRequestState

log = logging.getLogger("agentic_netops.supervisor.graph")

MAP_SKILL = "map-network-request"
ALLOCATE_SKILL = "allocate-network-service"
DEPLOY_SKILL = "deploy-network-service"
INTENT_NAMESPACE = "agentic-netops-intent"
NETWORK_API_VERSION = "fabric.agentic-netops.io/v1alpha1"


@dataclass
class SupervisorContext:
    """Run-scoped context of one request turn: never checkpointed.

    ``registry`` is the durable record of the services the tier submitted and the removals it
    issued (:class:`~supervisors.provisioning.graph.registry.TierRegistry`)."""

    settings: Settings
    client: TransportClient
    llm: Any | None
    clock: Callable[[], float]
    span: Any
    registry: Any | None = None


def emit(runtime: Runtime[SupervisorContext], state: ServiceRequestState, kind: str,
         **fields: Any) -> None:
    """Write one validated chunk to the operator stream."""
    chunk = build_chunk(type=kind, correlation_id=state["correlation_id"],
                        thread_id=state["thread_id"], **fields)
    runtime.stream_writer(json.loads(chunk.line()))


def log_for(state: ServiceRequestState, level: int, msg: str, *args: Any) -> None:
    log.log(level, msg, *args, extra={"correlation_id": state.get("correlation_id"),
                                      "thread_id": state.get("thread_id")})


def network_of(state: ServiceRequestState) -> str:
    """The ``Network`` this request is about: the removal target, else the created service's."""
    if state.get("operation") == "remove" and state.get("target"):
        return str(state["target"])
    assignment = state.get("assignment") or {}
    interpretation = state.get("interpretation") or {}
    service_id = assignment.get("serviceId") or interpretation.get("service_id") or "unknown"
    return f"migr-{service_id}"


def construct_of(state: ServiceRequestState) -> str | None:
    """The construct this request is about, in construct vocabulary (FR-026)."""
    if state.get("operation") == "remove":
        return state.get("target_construct")
    assignment = state.get("assignment") or {}
    interpretation = state.get("interpretation") or {}
    return assignment.get("type") or interpretation.get("service_type")


__all__ = [
    "ALLOCATE_SKILL",
    "DEPLOY_SKILL",
    "INTENT_NAMESPACE",
    "MAP_SKILL",
    "NETWORK_API_VERSION",
    "SupervisorContext",
    "construct_of",
    "emit",
    "log_for",
    "network_of",
]
