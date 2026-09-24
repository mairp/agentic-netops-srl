"""The supervisor's HTTP surface (T077; contracts/supervisor-http.md, FR-102, FR-074, AD-49, CD-01).

Written before the supervisor (T085) and run failing first. Drives the ASGI app in-process with
the in-memory SLIM stand-in and fake workers (conftest.py): the pipeline-reaching routes refuse no
and wrong credentials before a thread is minted; the comparison is constant-time and a failure
costs a fixed delay; the body is strict (``principal`` refused 400, naming it); a rotated Secret
takes effect without a restart; a thread confirmed by a second operator records the second name;
``/health`` never touches the transport; ``/v1/health`` names the unavailable worker.
"""

from __future__ import annotations

import hmac
import json
from typing import Any

import httpx
import pytest
from fastapi.routing import APIRoute
from starlette.routing import WebSocketRoute

import common.transport as t
from common import metrics
from common.guards.classifier import RequestClass, classify
from common.provisioning_states import ALL_STATUSES
from common.schemas.stream import parse_chunk
from supervisors.provisioning.main import create_app
from tests.unit.conftest import (
    CARD_IDS,
    GATEWAY_CREDENTIALS,
    Env,
    FakeLLM,
    FakeWorkers,
    basic,
    span_events,
)

pytestmark = pytest.mark.usefixtures("fresh_telemetry")

REALM = 'Basic realm="agentic-netops"'
REFUSAL_BODY = {"type": "error", "status": "FAILED", "reason": "authentication required"}
PROMPT = ("Extend vlan 100 as a mac-vrf across leaf01 ethernet-1/1 and leaf02 ethernet-1/1 "
          "for tenant blue")
ALICE = basic("alice", "alice-pass-1")
PIPELINE_ROUTES = [("POST", "/agent/prompt/stream"), ("GET", "/suggested-prompts"),
                   ("GET", "/transport/config")]
RETIRED = ("VPLS", "VPWS", "L3VPN", "L2L3-IRB", "E-LINE", "ELINE", "EVPN-VPWS")


class Sleeps:
    def __init__(self) -> None:
        self.calls: list[float] = []

    async def __call__(self, seconds: float) -> None:
        self.calls.append(seconds)


class Harness:
    def __init__(self, env: Env, **settings_env: str) -> None:
        self.env = env
        self.gateway = t.InMemoryGateway(*GATEWAY_CREDENTIALS)
        self.workers = FakeWorkers(self.gateway)
        self.llm = FakeLLM()
        self.sleeps = Sleeps()
        self.backends_created = 0
        self.settings = env.settings(**settings_env)

        def factory() -> Any:
            self.backends_created += 1
            return self.gateway.connect(GATEWAY_CREDENTIALS, identity="devnet/provisioning/sup")

        self.app = create_app(self.settings, backend_factory=factory, llm=self.llm,
                              sleep=self.sleeps)

    @property
    def supervisor(self) -> Any:
        return self.app.state.supervisor

    def client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app),
                                 base_url="http://supervisor")

    async def request(self, method: str, path: str, headers: dict[str, str] | None = None,
                      body: Any = None) -> httpx.Response:
        async with self.client() as client:
            if body is None:
                return await client.request(method, path, headers=headers)
            return await client.request(method, path, headers=headers,
                                        content=json.dumps(body).encode(),
                                        )

    async def stream(self, prompt: str, headers: dict[str, str],
                     thread_id: str | None = None) -> list[dict[str, Any]]:
        body: dict[str, Any] = {"prompt": prompt}
        if thread_id:
            body["thread_id"] = thread_id
        response = await self.request("POST", "/agent/prompt/stream", headers, body)
        assert response.status_code == 200, response.text
        assert response.headers["content-type"].startswith("application/x-ndjson")
        return [json.loads(line) for line in response.text.splitlines() if line.strip()]

    async def zero_effects(self) -> None:
        assert self.supervisor.threads_minted == 0
        assert await self.supervisor.thread_count() == 0
        assert self.llm.calls == []
        assert self.gateway.requests == []  # no worker call, so no claim either
        assert self.workers.cluster.creations == []


@pytest.fixture
async def harness(env: Env) -> Any:
    h = Harness(env)
    await h.workers.start()
    yield h
    await h.supervisor.close()


# --------------------------------------------------------------------------------------------------
# exactly five routes, no WebSocket
# --------------------------------------------------------------------------------------------------


def test_exactly_five_routes_and_no_websocket(env: Env) -> None:
    app = Harness(env).app
    routes = {(method, r.path) for r in app.routes if isinstance(r, APIRoute)
              for method in r.methods - {"HEAD"}}
    assert routes == {("POST", "/agent/prompt/stream"), ("GET", "/suggested-prompts"),
                      ("GET", "/transport/config"), ("GET", "/health"), ("GET", "/v1/health")}
    assert not [r for r in app.routes if isinstance(r, WebSocketRoute)]
    assert len([r for r in app.routes if hasattr(r, "path")]) == 5  # no docs, no openapi


# --------------------------------------------------------------------------------------------------
# 401 before a thread id is minted
# --------------------------------------------------------------------------------------------------

BAD_CREDENTIALS = {
    "none": {},
    "wrong-password": basic("alice", "not-it"),
    "wrong-username": basic("mallory", "alice-pass-1"),
    "malformed": {"Authorization": "Basic !!!not-base64"},
    "other-scheme": {"Authorization": "Bearer alice-pass-1"},
}


@pytest.mark.parametrize(("method", "path"), PIPELINE_ROUTES)
@pytest.mark.parametrize("credential", list(BAD_CREDENTIALS))
async def test_no_or_wrong_credential_is_refused_before_a_thread_exists(
        harness: Harness, method: str, path: str, credential: str) -> None:
    before = metrics.value(metrics.AUTH_REFUSALS)
    body = {"prompt": PROMPT} if method == "POST" else None
    response = await harness.request(method, path, BAD_CREDENTIALS[credential], body)
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == REALM
    assert response.json() == REFUSAL_BODY
    await harness.zero_effects()
    assert span_events(harness.app.state.telemetry) == []  # no AuditEvent
    assert metrics.value(metrics.AUTH_REFUSALS) == before + 1
    assert harness.sleeps.calls == [harness.settings.auth_failure_delay_seconds]


async def test_a_refused_body_carrying_principal_is_401_not_400(harness: Harness) -> None:
    response = await harness.request("POST", "/agent/prompt/stream", {},
                                     {"prompt": PROMPT, "principal": "alice"})
    assert response.status_code == 401  # the credential is decided first
    await harness.zero_effects()


async def test_fixed_failure_delay_default_and_override(env: Env) -> None:
    assert Harness(env).settings.auth_failure_delay_seconds == 1.0
    h = Harness(env, OPERATOR_AUTH_FAILURE_DELAY_SECONDS="2.5")
    await h.request("GET", "/transport/config", basic("alice", "x"))
    await h.request("GET", "/transport/config", {})
    assert h.sleeps.calls == [2.5, 2.5]
    await h.request("GET", "/transport/config", ALICE)
    assert h.sleeps.calls == [2.5, 2.5]  # a success costs nothing


async def test_comparison_is_constant_time(harness: Harness,
                                           monkeypatch: pytest.MonkeyPatch) -> None:
    compared: list[tuple[bytes, bytes]] = []
    real = hmac.compare_digest

    def spy(a: Any, b: Any) -> bool:
        compared.append((a, b))
        return real(a, b)

    monkeypatch.setattr(hmac, "compare_digest", spy)
    await harness.request("GET", "/transport/config", basic("mallory", "wrong"))
    # Both the username and the password are compared, even when the username is already wrong.
    assert len(compared) == 2
    assert {bytes(a) for a, _ in compared} == {b"mallory", b"wrong"}
    compared.clear()
    assert (await harness.request("GET", "/transport/config", ALICE)).status_code == 200
    assert len(compared) == 2


# --------------------------------------------------------------------------------------------------
# strict body
# --------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("field", ["principal", "user", "confirmed"])
async def test_an_unknown_body_field_is_refused_400_naming_it(harness: Harness,
                                                              field: str) -> None:
    response = await harness.request("POST", "/agent/prompt/stream", ALICE,
                                     {"prompt": PROMPT, field: "alice"})
    assert response.status_code == 400
    body = response.json()
    assert body["type"] == "error" and body["status"] == "FAILED"
    assert field in body["reason"]
    await harness.zero_effects()


@pytest.mark.parametrize("body", [{}, {"prompt": ""}, {"prompt": 7}, ["prompt"],
                                  {"prompt": "x", "thread_id": "not-a-uuid"}])
async def test_a_malformed_body_is_refused_400(harness: Harness, body: Any) -> None:
    response = await harness.request("POST", "/agent/prompt/stream", ALICE, body)
    assert response.status_code == 400
    await harness.zero_effects()


# --------------------------------------------------------------------------------------------------
# the stream
# --------------------------------------------------------------------------------------------------


async def test_ndjson_stream_carries_the_correlation_id_on_every_chunk(harness: Harness) -> None:
    chunks = await harness.stream(PROMPT, ALICE)
    ids = {c.get("correlation_id") for c in chunks}
    assert len(ids) == 1
    (cid,) = ids
    assert isinstance(cid, str) and len(cid) == 32 and cid == cid.lower()
    for chunk in chunks:
        parse_chunk(chunk)
        assert chunk["status"] in ALL_STATUSES
    assert [c["type"] for c in chunks][-1] == "confirmation_request"
    assert harness.supervisor.threads_minted == 1


# --------------------------------------------------------------------------------------------------
# Secret rotation and the principal of each decision
# --------------------------------------------------------------------------------------------------


async def test_secret_rotation_takes_effect_without_restart(harness: Harness) -> None:
    assert (await harness.request("GET", "/transport/config", ALICE)).status_code == 200
    harness.env.set_operator("alice", "alice-pass-2")
    assert (await harness.request("GET", "/transport/config", ALICE)).status_code == 401
    rotated = basic("alice", "alice-pass-2")
    assert (await harness.request("GET", "/transport/config", rotated)).status_code == 200


async def test_the_second_operator_confirming_is_recorded_not_the_first(harness: Harness) -> None:
    tel = harness.app.state.telemetry
    chunks = await harness.stream(PROMPT, ALICE)
    thread_id = chunks[0]["thread_id"]
    cid = chunks[0]["correlation_id"]

    harness.env.set_operator("bob", "bob-pass-1")  # the Secret's history: alice, then bob
    bob = basic("bob", "bob-pass-1")
    assert (await harness.request("GET", "/transport/config", ALICE)).status_code == 401
    chunks = await harness.stream("confirm", bob, thread_id)
    assert {c["correlation_id"] for c in chunks} == {cid}  # the thread keeps its correlation id

    confirms = [attrs for name, attrs in span_events(tel) if name == "audit.confirm"]
    assert len(confirms) == 1
    assert confirms[0]["audit.principal"] == "bob"
    assert confirms[0]["audit.thread_id"] == thread_id
    state = await harness.supervisor.state(thread_id)
    assert state["confirmation_1"]["principal"] == "bob"
    assert state["principal"] == "alice"  # who opened it — never inherited by a decision

    harness.env.set_operator("carol", "carol-pass-1")
    carol = basic("carol", "carol-pass-1")
    await harness.stream("confirm", carol, thread_id)
    state = await harness.supervisor.state(thread_id)
    assert state["confirmation_2"]["principal"] == "carol"
    principals = [attrs["audit.principal"] for name, attrs in span_events(tel)
                  if name == "audit.confirm"]
    assert principals == ["bob", "carol"]


async def test_an_unknown_thread_is_refused(harness: Harness) -> None:
    response = await harness.request(
        "POST", "/agent/prompt/stream", ALICE,
        {"prompt": "confirm", "thread_id": "8a1d2c3b-4e5f-4a6b-8c7d-9e0f1a2b3c4d"})
    assert response.status_code == 404
    assert response.json()["status"] == "FAILED"


# --------------------------------------------------------------------------------------------------
# /health, /v1/health, /transport/config
# --------------------------------------------------------------------------------------------------


async def test_health_never_touches_the_transport(harness: Harness) -> None:
    for _ in range(3):
        response = await harness.request("GET", "/health")
        assert response.status_code == 200 and response.json() == {"status": "ok"}
    assert harness.backends_created == 0
    assert harness.gateway.requests == []
    harness.gateway.stop(CARD_IDS["mapper"][0])
    assert (await harness.request("GET", "/health")).status_code == 200


async def test_deep_health_200_when_every_worker_answers(harness: Harness) -> None:
    response = await harness.request("GET", "/v1/health")
    assert response.status_code == 200
    assert response.json() == {
        "status": "ok", "transport": "SLIM",
        "endpoint": "http://slim.agentic-netops-agents.svc:46357",
        "workers": {"mapper": "ok", "allocator": "ok", "deployer": "ok"}}


@pytest.mark.parametrize("stopped", ["mapper", "allocator", "deployer"])
async def test_deep_health_503_names_the_unavailable_worker(harness: Harness,
                                                            stopped: str) -> None:
    harness.gateway.stop(CARD_IDS[stopped][0])
    response = await harness.request("GET", "/v1/health")
    assert response.status_code == 503
    body = response.json()
    assert body["status"] == "degraded"
    assert body["transport"] == "SLIM"
    assert body["workers"][stopped] == "unreachable"
    assert [w for w, s in body["workers"].items() if s != "ok"] == [stopped]
    # liveness is not readiness: the supervisor stays alive, its threads intact
    assert (await harness.request("GET", "/health")).status_code == 200


async def test_deep_health_without_cards_is_503(harness: Harness) -> None:
    for card in harness.env.cards.iterdir():
        card.unlink()
    response = await harness.request("GET", "/v1/health")
    assert response.status_code == 503 and response.json()["workers"] == {}


async def test_transport_config(harness: Harness) -> None:
    response = await harness.request("GET", "/transport/config", ALICE)
    assert response.json() == {"transport": "SLIM",
                               "endpoint": "http://slim.agentic-netops-agents.svc:46357"}


# --------------------------------------------------------------------------------------------------
# /suggested-prompts
# --------------------------------------------------------------------------------------------------


async def test_suggested_prompts_cover_the_constructs_on_the_real_inventory(
        harness: Harness) -> None:
    response = await harness.request("GET", "/suggested-prompts", ALICE)
    assert response.status_code == 200
    prompts = response.json()["prompts"]
    shapes = {p["shape"] for p in prompts}
    assert shapes == {"vlan", "mac-vrf", "ip-vrf", "gateway", "acl", "acl-on-service"}
    leaves = {"leaf01", "leaf02"}
    ports = {"ethernet-1/1", "ethernet-1/2", "ethernet-1/3", "ethernet-1/4"}
    for prompt in prompts:
        text = prompt["prompt"]
        assert any(leaf in text for leaf in leaves), text
        assert any(port in text for port in ports), text
        assert "spine" not in text
        assert not any(r.lower() in text.lower() for r in RETIRED), text
        assert "egress" not in text  # acl.egress is unqualified in the record
        verdict = classify(text)
        assert verdict.request_class == RequestClass.PROVISIONABLE, (text, verdict)


async def test_suggested_prompts_follow_the_qualification_record(harness: Harness) -> None:
    (harness.env.qualification / "mac-vrf.anycast-gateway-ipv4").write_text("unqualified")
    (harness.env.qualification / "ip-vrf").unlink()  # absent is unqualified
    prompts = (await harness.request("GET", "/suggested-prompts", ALICE)).json()["prompts"]
    assert {p["shape"] for p in prompts} == {"vlan", "mac-vrf", "acl", "acl-on-service"}


async def test_suggested_prompts_without_inventory_serve_nothing_invented(
        harness: Harness) -> None:
    (harness.env.inventory / "inventory.json").unlink()
    response = await harness.request("GET", "/suggested-prompts", ALICE)
    assert response.status_code == 200
    assert response.json()["prompts"] == []
    assert "inventory" in response.json()["note"]
