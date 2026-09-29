"""The deployer's server (T084, T100): ``python -m provisioning.deployer.server``.

FastAPI on its port (settings: AGENT_COMPONENT=deployer), ``GET /health``, ``GET /v1/health``,
the registration on SLIM under the card id, and the stage handler of
:mod:`provisioning.deployer.agent` (create, remove, status, release_gate).
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI

from common.transport import WorkerHandler
from config.settings import Settings
from provisioning.deployer.agent import make_handler
from provisioning.deployer.card import card
from provisioning.worker import create_worker_app, run, worker_settings


def create_app(**kwargs: Any) -> FastAPI:
    if "handler" not in kwargs:
        settings = kwargs.get("settings") or worker_settings("deployer")
        kwargs["settings"] = settings
        kwargs["handler"] = make_handler(settings)
    return create_worker_app(card(), **kwargs)


def _handler(settings: Settings) -> WorkerHandler:
    # Start-up constructs the model client, as every agent does: a gateway declared without a base
    # URL refuses to start and the effective endpoint is logged once (FR-106, T168). The deployer
    # makes no model call; the mounted llm-provider Secret is checked and reported all the same.
    from common.llm import LLMClient

    LLMClient(settings.llm_provider_dir)
    return make_handler(settings)


def main() -> None:
    run(card(), handler_factory=_handler)


if __name__ == "__main__":
    main()
