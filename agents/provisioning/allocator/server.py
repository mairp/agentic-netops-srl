"""The allocator's server (T084 shell, T099 stage): ``python -m provisioning.allocator.server``.

FastAPI on its port (settings: AGENT_COMPONENT=allocator), ``GET /health``, ``GET /v1/health``,
the registration on SLIM under the card id, and the stage handler of
:mod:`provisioning.allocator.agent` (skill ``allocate-network-service``).
"""

from __future__ import annotations

import logging
from typing import Any

from fastapi import FastAPI

from common.transport import WorkerHandler
from config.settings import Settings
from provisioning.allocator.agent import Allocator
from provisioning.allocator.card import card
from provisioning.worker import create_worker_app, run, worker_settings


def create_app(**kwargs: Any) -> FastAPI:
    settings = kwargs.pop("settings", None) or worker_settings("allocator")
    if kwargs.get("handler") is None:
        kwargs["handler"] = Allocator(settings).handle
    return create_worker_app(card(), settings=settings, **kwargs)


def _handler(settings: Settings) -> WorkerHandler:
    # Start-up resolves the allocation authority: an ALLOCATION_AUTHORITY that is neither
    # first-party nor kuid refuses to start rather than fail the first request.
    allocator = Allocator(settings)
    config = allocator.adapter().config
    logging.getLogger("agentic_netops.allocator").info(
        "allocation authority: %s (VLAN pool %s, VNI pool %s)", config.describe(),
        config.vlan_pool, config.vni_pool)
    return allocator.handle


def main() -> None:
    run(card(), handler_factory=_handler)


if __name__ == "__main__":
    main()
