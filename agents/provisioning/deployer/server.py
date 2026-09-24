"""The deployer's server shell (T084): ``python -m provisioning.deployer.server``.

FastAPI on its port (settings: AGENT_COMPONENT=deployer), ``GET /health``, ``GET /v1/health``,
and the registration on SLIM under the card id; stage logic arrives with User Story 4.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI

from provisioning.deployer.card import card
from provisioning.worker import create_worker_app, run


def create_app(**kwargs: Any) -> FastAPI:
    return create_worker_app(card(), **kwargs)


def main() -> None:
    run(card())


if __name__ == "__main__":
    main()
