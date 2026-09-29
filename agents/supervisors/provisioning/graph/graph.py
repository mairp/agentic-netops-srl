"""The supervisor's LangGraph ``StateGraph`` and the service that runs it (T085; FR-050 to FR-055,
SC-024, data-model.md §7, §16, §25).

:func:`build_graph` wires the nodes of :mod:`.nodes`; :class:`Supervisor` compiles it on the
durable SQLite checkpointer (``SUPERVISOR_CHECKPOINT_PATH``, the ``supervisor-checkpoint`` PVC) and
runs one request turn per :meth:`Supervisor.turn`, streaming the NDJSON chunk objects the nodes
write. Every turn runs inside the request span whose trace id is the thread's correlation id; a
new thread's id is minted here, and only here — after authentication, which the HTTP layer decides
before calling in.

A process killed mid-request loses nothing that was checkpointed: a new process on the same SQLite
file finds the thread where the last completed node left it, and a turn on it resumes the pending
stage. A submission carries an idempotency key derived from the thread, so a resumed submission is
the same submission, never a second one.

Every stage node run is a ``stage.<stage>`` span, a child of the turn's request span, and one
measurement of ``agentic_netops_agent_stage_duration_seconds{stage,outcome}`` (T135): the outcome
is the one the node recorded on ``agentic_netops_agent_stage_requests_total``. A stage that fails
sets ``agentic_netops.failed_stage`` on the root request span. The two routing nodes (``intake``,
``supervisor``) carry no span of their own.
"""

from __future__ import annotations

import asyncio
import functools
import logging
import time
import uuid
from collections.abc import AsyncIterator, Callable
from pathlib import Path
from typing import Any

from langgraph.graph import END, START, StateGraph
from langgraph.runtime import Runtime

from common import logging as tier_logging
from common import metrics
from common.exceptions import AgenticNetopsError
from common.provisioning_states import WorkflowStatus
from common.schemas.stream import build_chunk
from common.tracing import ATTR_FAILED_STAGE, request_span, stage_span
from common.transport import TransportClient
from config.settings import Settings, assert_bounds
from supervisors.provisioning.graph import nodes
from supervisors.provisioning.graph.nodes import SupervisorContext
from supervisors.provisioning.graph.registry import TierRegistry
from supervisors.provisioning.graph.state import ServiceRequestState

log = logging.getLogger("agentic_netops.supervisor")

NODES: dict[str, Callable[..., Any]] = {
    "intake": nodes.intake,
    "guard": nodes.guard,
    "supervisor": nodes.supervisor,
    "decide": nodes.decide,
    "await": nodes.await_decision,
    "inform": nodes.inform,
    "bounded_exit": nodes.bounded_exit,
    "mapper": nodes.mapper,
    "allocator": nodes.allocator,
    "lookup": nodes.lookup,
    "deployer": nodes.deployer,
    "release": nodes.release,
}


# The pipeline stage each stage node runs as (data-model.md §21's ``stage``); the routing nodes
# ``intake`` and ``supervisor`` are not listed and run without a stage span.
NODE_STAGES: dict[str, str] = {
    "guard": "supervisor",
    "decide": "supervisor",
    "await": "supervisor",
    "inform": "supervisor",
    "bounded_exit": "supervisor",
    "release": "supervisor",
    "mapper": "mapper",
    "allocator": "allocator",
    "lookup": "deployer",
    "deployer": "deployer",
}


def _default_outcome(node: str, updates: Any) -> str:
    """The outcome of a node run that recorded none: a stage left pending is in progress."""
    if isinstance(updates, dict) and updates.get("pending") == node:
        return "in_progress"
    return "succeeded"


def traced(node: str, fn: Callable[..., Any]) -> Callable[..., Any]:
    """``fn`` run inside its ``stage.<stage>`` span, its duration measured (T135)."""
    stage = NODE_STAGES.get(node)
    if stage is None:
        return fn

    @functools.wraps(fn)
    async def run(state: ServiceRequestState, runtime: Runtime[SupervisorContext]) -> Any:
        root = getattr(runtime.context, "span", None)
        updates: Any = None
        with stage_span(stage, correlation_id=state.get("correlation_id"), parent=root,
                        node=node) as current:
            try:
                updates = await fn(state, runtime)
            except Exception as exc:
                current.fail(f"internal error: {type(exc).__name__}")
                raise
            finally:
                outcome = current.outcome or ("failed" if current.failed
                                              else _default_outcome(node, updates))
                metrics.record_stage_duration(stage, outcome, current.duration)
                if current.failed and root is not None:
                    root.set_attribute(ATTR_FAILED_STAGE, current.failed_stage or stage)
        return updates

    return run


class UnknownThreadError(AgenticNetopsError):
    def __init__(self, thread_id: str) -> None:
        super().__init__(f"unknown thread {thread_id}")
        self.thread_id = thread_id


def build_graph() -> StateGraph:
    graph = StateGraph(ServiceRequestState, context_schema=SupervisorContext)
    for name, fn in NODES.items():
        graph.add_node(name, traced(name, fn))
    graph.add_edge(START, "intake")
    graph.add_edge("intake", "guard")
    graph.add_conditional_edges("guard", nodes.route_after_guard, ["supervisor", END])
    graph.add_conditional_edges(
        "supervisor", nodes.route_from_supervisor,
        ["mapper", "allocator", "lookup", "deployer", "decide", "await", "inform",
         "bounded_exit", END])
    graph.add_conditional_edges("decide", nodes.route_after_decide,
                                ["supervisor", "release", END])
    for worker in ("mapper", "allocator", "lookup", "deployer"):
        graph.add_edge(worker, "supervisor")
    for terminal in ("await", "inform", "bounded_exit", "release"):
        graph.add_edge(terminal, END)
    return graph


class Supervisor:
    """The supervisor graph on its durable checkpointer."""

    def __init__(self, settings: Settings,
                 client: TransportClient | Callable[[], TransportClient], *,
                 llm: Any | None = None, clock: Callable[[], float] = time.monotonic,
                 checkpoint_path: Path | None = None) -> None:
        assert_bounds(settings)  # an inconsistent override refuses to start (§25)
        self.settings = settings
        self._client = client
        self.llm = llm
        self.clock = clock
        self.checkpoint_path = Path(checkpoint_path or settings.checkpoint_path)
        self.threads_minted = 0
        self._conn: Any = None
        self._graph: Any = None
        self.registry: TierRegistry | None = None
        self._open_lock = asyncio.Lock()
        self._thread_locks: dict[str, asyncio.Lock] = {}

    # ------------------------------------------------------------------------------ lifecycle

    def client(self) -> TransportClient:
        if not isinstance(self._client, TransportClient):
            self._client = self._client()
        return self._client

    async def open(self) -> Any:
        async with self._open_lock:
            if self._graph is None:
                import aiosqlite
                from langgraph.checkpoint.sqlite.aio import AsyncSqliteSaver

                self.checkpoint_path.parent.mkdir(parents=True, exist_ok=True)
                self._conn = await aiosqlite.connect(str(self.checkpoint_path))
                saver = AsyncSqliteSaver(self._conn)
                await saver.setup()
                registry = TierRegistry(self._conn)
                await registry.setup()
                self.registry = registry
                self._graph = build_graph().compile(checkpointer=saver)
            return self._graph

    async def close(self) -> None:
        if self._conn is not None:
            await self._conn.close()
        self._conn = None
        self._graph = None
        self.registry = None

    # ------------------------------------------------------------------------------ queries

    @staticmethod
    def _config(thread_id: str) -> dict[str, Any]:
        return {"configurable": {"thread_id": thread_id}}

    async def state(self, thread_id: str) -> dict[str, Any]:
        graph = await self.open()
        snapshot = await graph.aget_state(self._config(thread_id))
        return dict(snapshot.values or {})

    async def has_thread(self, thread_id: str) -> bool:
        return bool((await self.state(thread_id)).get("correlation_id"))

    async def thread_count(self) -> int:
        await self.open()
        async with self._conn.execute(
                "SELECT COUNT(DISTINCT thread_id) FROM checkpoints") as cursor:
            row = await cursor.fetchone()
        return int(row[0]) if row else 0

    # ------------------------------------------------------------------------------ a turn

    async def turn(self, text: str, *, principal: str,
                   thread_id: str | None = None) -> AsyncIterator[dict[str, Any]]:
        """Run one request turn; yield its chunks. ``principal`` is the authenticated username
        of *this* request — the only principal any decision it carries records."""
        graph = await self.open()
        new = thread_id is None
        correlation_id = None
        if new:
            thread_id = str(uuid.uuid4())
            self.threads_minted += 1
        else:
            values = await self.state(thread_id)  # type: ignore[arg-type]
            correlation_id = values.get("correlation_id")
            if not correlation_id:
                raise UnknownThreadError(thread_id)  # type: ignore[arg-type]
        lock = self._thread_locks.setdefault(thread_id, asyncio.Lock())
        async with lock:
            with request_span("supervisor.request", correlation_id=correlation_id,
                              attributes={"thread_id": thread_id, "principal": principal},
                              attach=False) as span:
                tier_logging.bind_correlation_id(span.correlation_id)  # §27: every line after
                log.info("request accepted: POST /agent/prompt/stream on thread %s (%s)",
                         thread_id, "new" if new else "continued",
                         extra={"thread_id": thread_id, "correlation_id": span.correlation_id})
                context = SupervisorContext(self.settings, self.client(), self.llm, self.clock,
                                            span.span, self.registry)
                turn_input = {"thread_id": thread_id, "correlation_id": span.correlation_id,
                              "turn_text": text, "turn_principal": principal, "new_thread": new}
                try:
                    async for chunk in graph.astream(turn_input, self._config(thread_id),
                                                     context=context, stream_mode="custom",
                                                     durability="sync"):
                        yield chunk
                except Exception as exc:  # never a hang, never a silent end
                    log.exception("supervisor turn failed",
                                  extra={"correlation_id": span.correlation_id,
                                         "thread_id": thread_id})
                    for kind, fields in (
                            ("error", {"stage": "supervisor",
                                       "reason": f"internal error: {type(exc).__name__}"}),
                            ("final", {"message": "the request turn failed inside the "
                                                  "supervisor; the thread is kept"})):
                        yield build_chunk(type=kind, correlation_id=span.correlation_id,
                                          thread_id=thread_id, status=WorkflowStatus.FAILED.value,
                                          **fields).model_dump(mode="json", exclude_none=True)

    async def run_node_for_test(self, thread_id: str, node: str) -> list[dict[str, Any]]:
        """Diagnostic: run one node against the stored state, bypassing routing and persisting
        nothing — how the suite proves the submission invariant lives in the stage itself."""
        state = await self.state(thread_id)
        state.update(turn_principal=state.get("principal", ""), turn_text="",
                     turn_started=self.clock(), active_base=state.get("active_seconds", 0.0))
        chunks: list[dict[str, Any]] = []
        with request_span("supervisor.diagnostic", correlation_id=state["correlation_id"],
                          attach=False) as span:
            runtime = Runtime(context=SupervisorContext(self.settings, self.client(), self.llm,
                                                        self.clock, span.span, self.registry),
                              stream_writer=chunks.append)
            await NODES[node](state, runtime)
        return chunks


__all__ = ["NODES", "NODE_STAGES", "Supervisor", "UnknownThreadError", "build_graph", "traced"]
