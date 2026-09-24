"""The provisioning workers' shared server shell (T084; FR-071, FR-074).

Each worker (``provisioning.{mapper,allocator,deployer}.server``) is this shell with its own card:

* ``GET /health`` — trivial liveness, touches nothing;
* ``GET /v1/health`` — deep: ``200`` when the worker is registered on the transport and its mounted
  inputs are readable, ``503`` naming what is missing;
* a background task that registers the worker on SLIM under its card id, retrying with
  exponential backoff (1 s doubling, capped at 30 s) until it succeeds — an authentication refusal
  is logged as such and retried too, so a rotated gateway Secret heals without a restart;
* the stage handler: until User Story 4 brings the stage logic, a real stage request is answered
  with a terminal failure naming that (``worker failed: <name> — stage logic not implemented until
  User Story 4``); health probes are answered by :func:`common.transport.serve`.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
from collections.abc import AsyncIterator, Awaitable, Callable
from pathlib import Path
from typing import Any

from fastapi import FastAPI
from fastapi.responses import JSONResponse

from common import logging as tier_logging
from common.exceptions import TransportAuthenticationError
from common.transport import (
    Card,
    SlimTransport,
    StageMessage,
    Transport,
    WorkerHandler,
    reply_failed,
    serve,
)
from config.settings import Settings, load_settings

log = logging.getLogger("agentic_netops.worker")

NOT_IMPLEMENTED = "stage logic not implemented until User Story 4"
BACKOFF_CAP_SECONDS = 30.0


def not_implemented_handler(worker: str) -> WorkerHandler:
    async def handler(request: StageMessage) -> Any:
        log.info("%s: stage request refused: %s", worker, NOT_IMPLEMENTED)
        return reply_failed(NOT_IMPLEMENTED)

    return handler


def _readable_dir(path: Path) -> bool:
    try:
        return path.is_dir() and os.access(path, os.R_OK | os.X_OK) and any(
            not p.name.startswith(".") for p in path.iterdir())
    except OSError:
        return False


def worker_settings(worker: str) -> Settings:
    env = dict(os.environ)
    env.setdefault("AGENT_COMPONENT", worker)
    return load_settings(env)


class WorkerState:
    def __init__(self) -> None:
        self.registered = False
        self.last_error: str | None = None
        self.attempts = 0
        self.backend: Transport | None = None


def create_worker_app(card: dict[str, Any], *, settings: Settings | None = None,
                      backend_factory: Callable[[], Transport] | None = None,
                      handler: WorkerHandler | None = None,
                      sleep: Callable[[float], Awaitable[None]] = asyncio.sleep) -> FastAPI:
    parsed = Card.from_dict(card)
    worker = parsed.worker
    settings = settings or worker_settings(worker)
    handler = handler or not_implemented_handler(worker)
    factory = backend_factory or (lambda: SlimTransport(settings, parsed.id))
    state = WorkerState()
    inputs = {
        "site-inventory": settings.site_inventory_dir,
        "fabric-qualification": settings.fabric_qualification_dir,
        "llm-provider": settings.llm_provider_dir,
    }

    async def register_loop() -> None:
        delay = 1.0
        while not state.registered:
            state.attempts += 1
            backend = None
            try:
                backend = factory()
                await serve(card, handler, backend,
                            auth_check_timeout=settings.transport_auth_check_seconds)
                state.backend = backend
                state.registered = True
                state.last_error = None
                log.info("%s registered on %s at %s as %s", worker, "SLIM",
                         settings.transport_endpoint, parsed.id)
                return
            except TransportAuthenticationError as exc:
                state.last_error = f"transport authentication refused: {exc}"
            except Exception as exc:
                state.last_error = f"transport registration failed: {exc}"
            if backend is not None:  # never keep a refused connection's listeners around
                with contextlib.suppress(Exception):
                    await backend.close()
            log.warning("%s: %s; retrying in %g s", worker, state.last_error, delay)
            await sleep(delay)
            delay = min(delay * 2, BACKOFF_CAP_SECONDS)

    @contextlib.asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        task = asyncio.create_task(register_loop())
        app.state.registration = task
        try:
            yield
        finally:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
            if state.backend is not None:
                with contextlib.suppress(Exception):
                    await state.backend.close()

    app = FastAPI(title=f"agentic-netops {worker}", lifespan=lifespan, docs_url=None,
                  redoc_url=None, openapi_url=None)
    app.state.worker = state
    app.state.card = card
    app.state.settings = settings

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/v1/health")
    async def deep_health() -> JSONResponse:
        missing = [name for name, path in inputs.items() if not _readable_dir(path)]
        if not state.registered:
            refused = (state.last_error or "").startswith("transport authentication refused")
            missing.insert(0, "transport registration (authentication refused)" if refused
                           else "transport registration")
        body: dict[str, Any] = {
            "status": "ok" if not missing else "degraded",
            "worker": worker,
            "card": parsed.id,
            "transport": "SLIM",
            "endpoint": settings.transport_endpoint,
            "registered": state.registered,
            "inputs": {name: _readable_dir(path) for name, path in inputs.items()},
        }
        if missing:
            body["missing"] = missing
            if state.last_error and not state.registered:
                body["reason"] = state.last_error
        return JSONResponse(body, status_code=200 if not missing else 503)

    return app


def run(card: dict[str, Any]) -> None:
    """The entry point of ``python -m provisioning.<worker>.server``."""
    import uvicorn

    worker = Card.from_dict(card).worker
    settings = worker_settings(worker)
    tier_logging.configure(worker)
    from common.telemetry import init_telemetry

    init_telemetry(worker, endpoint=settings.otlp_endpoint)
    uvicorn.run(create_worker_app(card, settings=settings), host="0.0.0.0",  # noqa: S104
                port=settings.port, log_config=None)
