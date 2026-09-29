"""The mapper's server (T084 shell, T098 stage): ``python -m provisioning.mapper.server``.

FastAPI on its port (settings: AGENT_COMPONENT=mapper), ``GET /health``, ``GET /v1/health``, the
registration on SLIM under the card id, and the stage handler of :mod:`provisioning.mapper.agent`
(skill ``map-network-request``).
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI

from common.transport import WorkerHandler
from config.settings import Settings
from provisioning.mapper.agent import Mapper
from provisioning.mapper.card import card
from provisioning.worker import create_worker_app, run, worker_settings


def create_app(**kwargs: Any) -> FastAPI:
    settings = kwargs.pop("settings", None) or worker_settings("mapper")
    if kwargs.get("handler") is None:
        kwargs["handler"] = Mapper(settings).handle
    return create_worker_app(card(), settings=settings, **kwargs)


def _handler(settings: Settings) -> WorkerHandler:
    # Start-up constructs the model client: a gateway declared without a base URL refuses to
    # start, and the effective endpoint is logged once (FR-106); every call re-reads the Secret.
    from common.llm import LLMClient

    return Mapper(settings, llm=LLMClient(settings.llm_provider_dir,
                                          timeout=settings.model_call_timeout_seconds,
            reasoning_effort=settings.model_reasoning_effort)).handle


def main() -> None:
    run(card(), handler_factory=_handler)


if __name__ == "__main__":
    main()
