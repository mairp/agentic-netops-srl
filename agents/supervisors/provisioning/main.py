"""The supervisor's HTTP surface (T085; contracts/supervisor-http.md, FR-050 to FR-057, FR-074,
FR-102, D-34): ``python -m supervisors.provisioning.main`` (port 9090).

Exactly five routes, and no WebSocket:

=========================  ==============  ===================================================
``POST /agent/prompt/stream``  credential  NDJSON stream (``application/x-ndjson``)
``GET /suggested-prompts``     credential  construct-vocabulary prompts on the real inventory
``GET /transport/config``      credential  ``{"transport": "SLIM", "endpoint": …}``
``GET /health``                none        liveness — never touches the transport
``GET /v1/health``             none        readiness — probes each worker found via the cards
=========================  ==============  ===================================================

On a pipeline-reaching route the credential is decided first — before the body is read, before a
thread identifier exists. The body is strict: an unknown field (``principal`` above all) is refused
``400`` naming it, because the principal is the authenticated username and nothing else.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from common.exceptions import EndpointError
from common.guards.redaction import redact
from common.telemetry import get_telemetry
from common.transport import SlimTransport, Transport, TransportClient, load_cards
from config.settings import Settings, load_settings
from supervisors.provisioning.auth import OperatorAuthenticator
from supervisors.provisioning.graph.graph import Supervisor, UnknownThreadError
from supervisors.provisioning.prompts import suggested_prompts

log = logging.getLogger("agentic_netops.supervisor.http")

SUPERVISOR_IDENTITY = "devnet/provisioning/supervisor"
NDJSON = "application/x-ndjson"
UUID = r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"


class PromptRequest(BaseModel):
    """The request body. There is no ``principal`` field — by design (FR-102)."""

    model_config = ConfigDict(extra="forbid", strict=True)

    prompt: str = Field(min_length=1, max_length=8000)
    thread_id: str | None = Field(default=None, pattern=UUID)


def _error(status_code: int, reason: str, **extra: Any) -> JSONResponse:
    return JSONResponse({"type": "error", "status": "FAILED", "reason": reason, **extra},
                        status_code=status_code)


def _body_error(exc: ValidationError) -> JSONResponse:
    unknown = [str(e["loc"][-1]) for e in exc.errors() if e.get("type") == "extra_forbidden"]
    if unknown:
        reason = (f"unknown field(s): {', '.join(unknown)} — the request body carries no "
                  "identity; the principal is the authenticated username")
        return _error(400, reason, fields=unknown)
    first = exc.errors()[0]
    where = ".".join(str(p) for p in first.get("loc", ())) or "body"
    return _error(400, f"invalid request body: {where}: {first.get('msg')}", fields=[where])


def _default_llm(settings: Settings) -> Any | None:
    """The model client from the mounted llm-provider Secret; absent Secret → static answers.
    A gateway declared without a base URL refuses to start (FR-106)."""
    if not (settings.llm_provider_dir / "LLM_MODEL").exists():
        log.info("no llm-provider Secret at %s: informational answers are static",
                 settings.llm_provider_dir)
        return None
    from common.llm import LLMClient

    return LLMClient(settings.llm_provider_dir, timeout=settings.model_call_timeout_seconds,
            reasoning_effort=settings.model_reasoning_effort)


def create_app(settings: Settings | None = None, *,
               backend: Transport | None = None,
               backend_factory: Callable[[], Transport] | None = None,
               llm: Any | None = None,
               sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
               clock: Callable[[], float] = time.monotonic) -> FastAPI:
    settings = settings or load_settings()
    settings.require_slim()
    if llm is None:
        llm = _default_llm(settings)

    def make_client() -> TransportClient:
        chosen = backend or (backend_factory() if backend_factory else
                             SlimTransport(settings, SUPERVISOR_IDENTITY))
        return TransportClient(settings, chosen)

    supervisor = Supervisor(settings, make_client, llm=llm, clock=clock)
    authenticator = OperatorAuthenticator(settings.operator_credentials_dir,
                                          delay_seconds=settings.auth_failure_delay_seconds,
                                          sleep=sleep)

    app = FastAPI(title="agentic-netops supervisor", docs_url=None, redoc_url=None,
                  openapi_url=None)
    app.state.settings = settings
    app.state.supervisor = supervisor
    app.state.telemetry = get_telemetry()

    @app.post("/agent/prompt/stream")
    async def prompt_stream(request: Request) -> Any:
        principal = await authenticator.authenticate(request)  # first: before any thread
        if not isinstance(principal, str):
            return principal
        try:
            body = PromptRequest.model_validate(json.loads(await request.body() or b"null"),
                                                strict=True)
        except json.JSONDecodeError as exc:
            return _error(400, f"invalid request body: not JSON ({exc.msg})")
        except ValidationError as exc:
            return _body_error(exc)
        if body.thread_id is not None and not await supervisor.has_thread(body.thread_id):
            return _error(404, f"unknown thread {body.thread_id}")

        async def stream() -> AsyncIterator[bytes]:
            try:
                async for chunk in supervisor.turn(body.prompt, principal=principal,
                                                   thread_id=body.thread_id):
                    yield (json.dumps(chunk, ensure_ascii=False, separators=(",", ":"))
                           + "\n").encode()
            except UnknownThreadError as exc:
                yield (json.dumps({"type": "error", "status": "FAILED", "reason": str(exc)})
                       + "\n").encode()

        return StreamingResponse(stream(), media_type=NDJSON)

    @app.get("/suggested-prompts")
    async def prompts(request: Request) -> Any:
        principal = await authenticator.authenticate(request)
        if not isinstance(principal, str):
            return principal
        return suggested_prompts(settings.site_inventory_dir, settings.fabric_qualification_dir)

    @app.get("/transport/config")
    async def transport_config(request: Request) -> Any:
        principal = await authenticator.authenticate(request)
        if not isinstance(principal, str):
            return principal
        return {"transport": "SLIM", "endpoint": settings.transport_endpoint}

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}  # liveness: never touches the transport (SC-024)

    @app.get("/v1/health")
    async def deep_health() -> JSONResponse:
        body: dict[str, Any] = {"status": "ok", "transport": "SLIM",
                                "endpoint": settings.transport_endpoint, "workers": {}}
        try:
            workers = await supervisor.client().health()
        except Exception as exc:  # the transport itself: every worker is unreachable
            log.warning("deep health: transport unavailable: %s", exc)
            workers = {card.worker: "unreachable"
                       for card in load_cards(settings.agent_cards_dir)}
            body["reason"] = f"transport unavailable: {redact(str(exc)) or type(exc).__name__}"
        body["workers"] = workers
        healthy = bool(workers) and all(v == "ok" for v in workers.values())
        if not workers:
            body["reason"] = f"no agent cards found in {settings.agent_cards_dir}"
        if not healthy:
            body["status"] = "degraded"
        return JSONResponse(body, status_code=200 if healthy else 503)

    return app


def main() -> None:
    import uvicorn

    from common import logging as tier_logging
    from common.telemetry import init_telemetry

    settings = load_settings()
    tier_logging.configure("supervisor")
    init_telemetry("supervisor", endpoint=settings.otlp_endpoint)
    try:
        app = create_app(settings)
    except EndpointError as exc:
        log.error("refusing to start: %s", exc)
        raise SystemExit(2) from exc
    # No access log: uvicorn writes it outside the request, where its correlation id is not known;
    # the request's own first line ("request accepted: ...") carries it instead (§27, NFR-014).
    uvicorn.run(app, host="0.0.0.0", port=settings.port, log_config=None,  # noqa: S104
                access_log=False)


if __name__ == "__main__":
    main()
