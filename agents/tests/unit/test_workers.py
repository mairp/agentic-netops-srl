"""The three worker server shells and their agent cards (T084; FR-071, FR-074, §14)."""

from __future__ import annotations

import asyncio
import importlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

import httpx
import pytest
from a2a.types import AgentCard

import common.transport as t
from common.exceptions import TransportAuthenticationError, WorkerFailedError
from config.settings import load_settings

AGENTS = Path(__file__).resolve().parents[2]
REPO = AGENTS.parent
TRACKED = REPO / "deploy" / "agents" / "cards"

WORKERS = {
    "mapper": ("devnet/provisioning/network-mapping", "map-network-request", 9092),
    "allocator": ("devnet/provisioning/network-allocator", "allocate-network-service", 9091),
    "deployer": ("devnet/provisioning/network-deployer", "deploy-network-service", 9093),
}
CID = "4bf92f3577b34da6a3ce929d0e0e4736"


def _card(worker: str) -> dict[str, Any]:
    return importlib.import_module(f"provisioning.{worker}.card").card()


@pytest.mark.parametrize("worker", list(WORKERS))
def test_card_identity_and_skill(worker: str) -> None:
    card_id, skill, _port = WORKERS[worker]
    card = _card(worker)
    assert card["id"] == card_id
    assert [s["id"] for s in card["skills"]] == [skill]
    assert card["x-agentic-netops-worker"] == worker
    assert card["capabilities"]["streaming"] is False
    for key in ("name", "description", "version"):
        assert isinstance(card[key], str) and card[key]
    # a2a-sdk AgentCard-compatible: the pinned model accepts it.
    AgentCard.model_validate({k: v for k, v in card.items()
                              if k not in ("id", "x-agentic-netops-worker")})
    parsed = t.Card.from_dict(card)
    assert (parsed.topic, parsed.worker, parsed.skills) == (card_id, worker, (skill,))


@pytest.mark.parametrize("worker", list(WORKERS))
def test_tracked_card_equals_the_module_output(worker: str) -> None:
    out = subprocess.run(  # noqa: S603 — the interpreter running this test, a fixed module
        [sys.executable, "-m", f"provisioning.{worker}.card"], cwd=AGENTS, check=True,
        capture_output=True, text=True).stdout
    tracked = TRACKED / f"{worker}.json"
    assert tracked.exists(), f"{tracked.relative_to(REPO)} missing"
    assert tracked.read_text() == out, (
        f"{tracked.relative_to(REPO)} differs from `python -m provisioning.{worker}.card`")
    assert json.loads(out) == _card(worker)


def test_tracked_cards_are_exactly_the_three() -> None:
    assert sorted(p.name for p in TRACKED.glob("*.json")) == [
        "allocator.json", "deployer.json", "mapper.json"]
    assert sorted(c.worker for c in t.load_cards(TRACKED)) == ["allocator", "deployer", "mapper"]


@pytest.mark.parametrize("worker", list(WORKERS))
def test_worker_ports(worker: str) -> None:
    from provisioning.worker import worker_settings

    assert worker_settings(worker).port == WORKERS[worker][2]


# --------------------------------------------------------------------------------------------------
# the server shell
# --------------------------------------------------------------------------------------------------


def _inputs(tmp_path: Path) -> dict[str, str]:
    env = {}
    for name, var in (("site-inventory", "SITE_INVENTORY_DIR"),
                      ("fabric-qualification", "FABRIC_QUALIFICATION_DIR"),
                      ("llm-provider", "LLM_PROVIDER_DIR")):
        directory = tmp_path / name
        directory.mkdir()
        (directory / "data").write_text("x")
        env[var] = str(directory)
    return env


class Sleeps:
    def __init__(self) -> None:
        self.calls: list[float] = []

    async def __call__(self, seconds: float) -> None:
        self.calls.append(seconds)
        await asyncio.sleep(0)


async def _settle(app: Any, predicate: Any) -> None:
    for _ in range(200):
        if predicate():
            return
        await asyncio.sleep(0)
    raise AssertionError("condition never reached")


async def _get(app: Any, path: str) -> httpx.Response:
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),
                                 base_url="http://worker") as client:
        return await client.get(path)


@pytest.mark.parametrize("worker", list(WORKERS))
async def test_registers_over_the_transport_and_reports_deep_health(
        worker: str, tmp_path: Path) -> None:
    server = importlib.import_module(f"provisioning.{worker}.server")
    gateway = t.InMemoryGateway("gw", "pw")
    settings = load_settings({"AGENT_COMPONENT": worker, **_inputs(tmp_path)})
    app = server.create_app(settings=settings, sleep=Sleeps(),
                            backend_factory=lambda: gateway.connect(("gw", "pw"),
                                                                    identity=WORKERS[worker][0]))
    assert (await _get(app, "/health")).json() == {"status": "ok"}
    async with app.router.lifespan_context(app):
        await _settle(app, lambda: app.state.worker.registered)
        assert WORKERS[worker][0] in gateway.registered()
        response = await _get(app, "/v1/health")
        assert response.status_code == 200, response.json()
        assert response.json()["status"] == "ok" and response.json()["worker"] == worker


async def test_deep_health_names_what_is_missing(tmp_path: Path) -> None:
    from provisioning.mapper.server import create_app

    env = _inputs(tmp_path)
    env["FABRIC_QUALIFICATION_DIR"] = str(tmp_path / "absent")
    settings = load_settings({"AGENT_COMPONENT": "mapper", **env})
    app = create_app(settings=settings, sleep=Sleeps(),
                     backend_factory=lambda: (_ for _ in ()).throw(
                         TransportAuthenticationError("unauthenticated registration")))
    response = await _get(app, "/v1/health")  # before any registration attempt
    assert response.status_code == 503
    assert response.json()["missing"] == ["transport registration", "fabric-qualification"]
    assert (await _get(app, "/health")).status_code == 200  # liveness is unaffected


async def test_registration_retries_with_backoff_until_it_succeeds(tmp_path: Path) -> None:
    from provisioning.deployer.server import create_app

    gateway = t.InMemoryGateway("gw", "pw")
    attempts: list[int] = []

    def factory() -> Any:
        attempts.append(1)
        credentials = ("gw", "pw") if len(attempts) >= 3 else ("gw", "old-password")
        return gateway.connect(credentials, identity=WORKERS["deployer"][0])

    sleeps = Sleeps()
    settings = load_settings({"AGENT_COMPONENT": "deployer", **_inputs(tmp_path)})
    app = create_app(settings=settings, sleep=sleeps, backend_factory=factory)
    async with app.router.lifespan_context(app):
        await _settle(app, lambda: app.state.worker.registered)
    assert len(attempts) == 3
    assert sleeps.calls == [1.0, 2.0]


@pytest.mark.parametrize("worker", list(WORKERS))
async def test_stage_request_is_a_terminal_failure_until_user_story_4(
        worker: str, tmp_path: Path) -> None:
    server = importlib.import_module(f"provisioning.{worker}.server")
    gateway = t.InMemoryGateway("gw", "pw")
    cards = tmp_path / "cards"
    cards.mkdir()
    (cards / f"{worker}.json").write_text(json.dumps(_card(worker)))
    settings = load_settings({"AGENT_COMPONENT": worker, "AGENT_CARDS_DIR": str(cards),
                              **_inputs(tmp_path)})
    app = server.create_app(settings=settings, sleep=Sleeps(),
                            backend_factory=lambda: gateway.connect(("gw", "pw"),
                                                                    identity=WORKERS[worker][0]))
    async with app.router.lifespan_context(app):
        await _settle(app, lambda: app.state.worker.registered)
        client = t.TransportClient(settings, gateway.connect(("gw", "pw"), identity="a/b/c"),
                                   sleep=Sleeps())
        assert await client.health() == {worker: "ok"}
        with pytest.raises(WorkerFailedError) as caught:
            await client.call(WORKERS[worker][1], {"text": "x"}, expect=None, marker=None,
                              correlation_id=CID, thread_id="t-1")
    assert str(caught.value) == (
        f"worker failed: {worker} — stage logic not implemented until User Story 4")
