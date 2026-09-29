"""The agent-to-agent transport client (T078; contracts/a2a-transport.md, FR-070 to FR-074, FR-065).

Written before ``agents/common/transport.py`` (T083) and run failing first. Everything here runs
against the in-memory SLIM stand-in of the module (:class:`InMemoryGateway`), which keeps the
gateway's two behaviours the contract depends on — a registration without the gateway's
credentials is refused, and a topic nobody registered is unreachable — and an injected sleep, so
no test waits for a backoff.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

import pytest

import common.transport as t  # fails collection until T083 exists (written test-first)
from common.exceptions import (
    TransportAuthenticationError,
    TransportConfigurationError,
    WorkerFailedError,
    WorkerUnreachableError,
)
from common.schemas.interpretation import MARKER as MAPPED_MARKER
from common.schemas.interpretation import Interpretation
from config.settings import load_settings

AGENTS = Path(__file__).resolve().parents[2]
REPO = AGENTS.parent
CID = "4bf92f3577b34da6a3ce929d0e0e4736"

INTERPRETATION = {
    "service_id": "3f2b9c0d1e4a5b6",
    "service_type": "mac-vrf",
    "tenant": "blue",
    "endpoints": [
        {"site_or_node": "leaf01", "attachment": "ethernet-1/1", "vlan": 100},
        {"site_or_node": "leaf02", "attachment": "ethernet-1/1", "vlan": 100},
    ],
}

CARDS = {
    "mapper": ("devnet/provisioning/network-mapping", "map-network-request"),
    "allocator": ("devnet/provisioning/network-allocator", "allocate-network-service"),
    "deployer": ("devnet/provisioning/network-deployer", "deploy-network-service"),
}


def card(card_id: str, skill: str, worker: str | None = None) -> dict[str, Any]:
    body: dict[str, Any] = {
        "id": card_id,
        "name": card_id.rsplit("/", 1)[-1],
        "description": f"test card for {skill}",
        "version": "0.1.0",
        "url": f"slim://{card_id}",
        "capabilities": {"streaming": False},
        "defaultInputModes": ["application/json"],
        "defaultOutputModes": ["application/json"],
        "skills": [{"id": skill, "name": skill, "description": skill, "tags": ["test"]}],
    }
    if worker:
        body["x-agentic-netops-worker"] = worker
    return body


@pytest.fixture
def cards_dir(tmp_path: Path) -> Path:
    directory = tmp_path / "agent-cards"
    directory.mkdir()
    for worker, (card_id, skill) in CARDS.items():
        (directory / f"{worker}.json").write_text(json.dumps(card(card_id, skill, worker)))
    return directory


@pytest.fixture
def gateway_dir(tmp_path: Path) -> Path:
    directory = tmp_path / "slim-gateway"
    directory.mkdir()
    (directory / "username").write_text("slim-gw\n")
    (directory / "password").write_text("gw-pass-123\n")
    return directory


@pytest.fixture
def settings(tmp_path: Path, cards_dir: Path, gateway_dir: Path) -> Any:
    tls = tmp_path / "slim-tls"
    tls.mkdir()
    (tls / "ca.crt").write_text("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n")
    return load_settings({
        "AGENT_CARDS_DIR": str(cards_dir),
        "SLIM_GATEWAY_DIR": str(gateway_dir),
        "SLIM_TLS_DIR": str(tls),
    })


class Sleeps:
    def __init__(self) -> None:
        self.calls: list[float] = []

    async def __call__(self, seconds: float) -> None:
        self.calls.append(seconds)


@pytest.fixture
def sleeps() -> Sleeps:
    return Sleeps()


@pytest.fixture
def gateway() -> Any:
    return t.InMemoryGateway("slim-gw", "gw-pass-123")


def _creds() -> tuple[str, str]:
    return ("slim-gw", "gw-pass-123")


async def _worker(gateway: Any, name: str, handler: Any) -> Any:
    card_id, skill = CARDS[name]
    backend = gateway.connect(_creds(), identity=card_id)
    await t.serve(card(card_id, skill, name), handler, backend)
    return backend


def _ok_mapper(data: dict[str, Any] | None = None, text: str | None = None,
               with_data: bool = True) -> Any:
    async def handler(request: Any) -> Any:
        payload = INTERPRETATION if data is None else data
        body = text if text is not None else (
            f"Mapped your request.\n<!-- {MAPPED_MARKER}: {json.dumps(payload)} -->")
        return t.reply_ok(body, payload if with_data else None)
    return handler


def _client(settings: Any, gateway: Any, sleeps: Sleeps, **kwargs: Any) -> Any:
    backend = gateway.connect(_creds(), identity="devnet/provisioning/supervisor")
    return t.TransportClient(settings, backend, sleep=sleeps, **kwargs)


async def _call(client: Any, skill: str = "map-network-request", **kwargs: Any) -> Any:
    kwargs.setdefault("expect", Interpretation)
    kwargs.setdefault("marker", MAPPED_MARKER)
    return await client.call(skill, {"text": "extend vlan 100"}, correlation_id=CID,
                             thread_id="thread-1", **kwargs)


# --------------------------------------------------------------------------------------------------
# endpoint and transport (D-27)
# --------------------------------------------------------------------------------------------------


def test_endpoint_default_is_the_long_name_on_46357(gateway: Any, sleeps: Sleeps,
                                                    cards_dir: Path) -> None:
    settings = load_settings({"AGENT_CARDS_DIR": str(cards_dir)})
    client = t.TransportClient(settings, gateway.connect(_creds(), identity="x/y/z"), sleep=sleeps)
    assert client.endpoint == "http://slim.agentic-netops-agents.svc:46357"
    assert client.transport == "SLIM"
    assert t.DEFAULT_ENDPOINT == "http://slim.agentic-netops-agents.svc:46357"


def test_endpoint_from_transport_server_endpoint(gateway: Any, sleeps: Sleeps,
                                                gateway_dir: Path) -> None:
    settings = load_settings({"TRANSPORT_SERVER_ENDPOINT": "http://slim.test:46357",
                              "TRANSPORT_ENDPOINT": "http://short-name:1",
                              "SLIM_GATEWAY_DIR": str(gateway_dir)})
    client = t.TransportClient(settings, gateway.connect(_creds(), identity="x/y/z"), sleep=sleeps)
    assert client.endpoint == "http://slim.test:46357"
    # slim_bindings speaks TLS only to an https endpoint: same host and port, scheme rewritten
    assert t.slim_client_config(settings)["endpoint"] == "https://slim.test:46357"


def test_a_non_slim_transport_raises_rather_than_falling_back(gateway: Any) -> None:
    settings = load_settings({"DEFAULT_MESSAGE_TRANSPORT": "NATS"})
    with pytest.raises(TransportConfigurationError, match="NATS"):
        t.TransportClient(settings, gateway.connect(_creds(), identity="x/y/z"))
    with pytest.raises(TransportConfigurationError):
        t.SlimTransport(settings, identity="devnet/provisioning/supervisor")


def test_slim_client_config_is_tls_with_the_ca_and_basic_auth(settings: Any) -> None:
    config = t.slim_client_config(settings)
    assert config["endpoint"] == t.tls_endpoint(settings.transport_endpoint)
    assert config["endpoint"].startswith("https://")
    assert "insecure" not in config["tls"]
    assert config["tls"]["ca_file"] == str(settings.slim_tls_dir / "ca.crt")
    assert config["auth"]["basic"] == {"username": "slim-gw", "password": "gw-pass-123"}


def test_slim_client_config_without_gateway_credentials_refuses(tmp_path: Path) -> None:
    settings = load_settings({"SLIM_GATEWAY_DIR": str(tmp_path / "absent")})
    with pytest.raises(TransportAuthenticationError, match="username"):
        t.slim_client_config(settings)


# --------------------------------------------------------------------------------------------------
# authentication (FR-072)
# --------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("credentials", [None, ("slim-gw", "wrong"), ("intruder", "gw-pass-123")],
                         ids=["none", "wrong-password", "wrong-user"])
async def test_unauthenticated_registration_is_refused(gateway: Any, credentials: Any) -> None:
    with pytest.raises(TransportAuthenticationError):
        backend = gateway.connect(credentials, identity=CARDS["mapper"][0])
        await t.serve(card(*CARDS["mapper"], "mapper"), _ok_mapper(), backend)
    assert CARDS["mapper"][0] not in gateway.registered()


@pytest.mark.parametrize("message", ["status: Unauthenticated, message: invalid credentials",
                                     "HTTP status client error (401 Unauthorized)",
                                     "authentication failed"])
def test_slim_binding_auth_refusal_maps_to_the_transport_authentication_error(
        message: str) -> None:
    mapped = t.map_slim_error(RuntimeError(message), after_send=False)
    assert isinstance(mapped, TransportAuthenticationError)


def test_slim_binding_other_errors_map_to_delivery_errors() -> None:
    mapped = t.map_slim_error(RuntimeError("connection refused"), after_send=True)
    assert isinstance(mapped, t.DeliveryError) and mapped.after_send is True


# --------------------------------------------------------------------------------------------------
# discovery at call time (FR-071)
# --------------------------------------------------------------------------------------------------


async def test_card_ids_resolved_at_call_time(settings: Any, gateway: Any,
                                              sleeps: Sleeps) -> None:
    client = _client(settings, gateway, sleeps)
    assert {c.id: c.worker for c in client.discover()} == {
        cid: worker for worker, (cid, _) in CARDS.items()}
    assert client.resolve("map-network-request").topic == "devnet/provisioning/network-mapping"
    assert client.resolve("allocate-network-service").topic == (
        "devnet/provisioning/network-allocator")
    assert client.resolve("deploy-network-service").topic == "devnet/provisioning/network-deployer"


async def test_a_new_card_file_is_a_new_worker_with_no_code_change(
        settings: Any, gateway: Any, sleeps: Sleeps, cards_dir: Path) -> None:
    client = _client(settings, gateway, sleeps)
    with pytest.raises(WorkerUnreachableError):
        client.resolve("audit-network-service")
    new_id = "devnet/provisioning/network-auditor"
    (cards_dir / "auditor.json").write_text(json.dumps(card(new_id, "audit-network-service")))
    backend = gateway.connect(_creds(), identity=new_id)
    await t.serve(card(new_id, "audit-network-service"), _ok_mapper(), backend)
    result = await _call(client, "audit-network-service")
    assert result.worker == "network-auditor"  # no x-agentic-netops-worker: the local name
    assert isinstance(result.data, Interpretation)


async def test_a_replaced_card_moves_the_topic(settings: Any, gateway: Any, sleeps: Sleeps,
                                               cards_dir: Path) -> None:
    client = _client(settings, gateway, sleeps)
    replacement = "devnet/provisioning/network-mapping-v2"
    (cards_dir / "mapper.json").write_text(
        json.dumps(card(replacement, "map-network-request", "mapper")))
    backend = gateway.connect(_creds(), identity=replacement)
    await t.serve(card(replacement, "map-network-request", "mapper"), _ok_mapper(), backend)
    result = await _call(client)
    assert result.topic == replacement


def test_the_client_holds_no_worker_list() -> None:
    source = (AGENTS / "common" / "transport.py").read_text()
    for card_id, _skill in CARDS.values():
        assert card_id not in source
    assert "network-mapping" not in source and "network-allocator" not in source


def test_cards_with_unreadable_or_hidden_files_are_skipped(cards_dir: Path) -> None:
    (cards_dir / "broken.json").write_text("{not json")
    (cards_dir / "..data").mkdir()
    (cards_dir / "notes.txt").write_text("ignored")
    assert sorted(c.worker for c in t.load_cards(cards_dir)) == ["allocator", "deployer", "mapper"]


# --------------------------------------------------------------------------------------------------
# timeout, retry and backoff (FR-073, data-model.md §25)
# --------------------------------------------------------------------------------------------------


class RecordingBackend:
    """A backend whose answers are scripted: 'unreachable', 'timeout', 'after-send' or bytes."""

    kind = "SLIM"

    def __init__(self, script: list[Any]) -> None:
        self.script = list(script)
        self.calls: list[tuple[str, float]] = []
        self.endpoint = "http://slim.agentic-netops-agents.svc:46357"

    async def request(self, topic: str, message: bytes, timeout: float) -> bytes:  # noqa: ASYNC109
        self.calls.append((topic, timeout))
        step = self.script.pop(0) if self.script else "unreachable"
        if step == "unreachable":
            raise t.DeliveryError("no route to topic", after_send=False)
        if step == "timeout":
            raise TimeoutError
        if step == "after-send":
            raise t.DeliveryError("connection lost", after_send=True)
        return step

    async def register(self, topic: str, handler: Any) -> None:  # pragma: no cover
        raise NotImplementedError

    async def close(self) -> None:
        return None


def _ok_bytes(data: dict[str, Any] | None = None) -> bytes:
    return t.encode(t.reply_ok("ok", data or INTERPRETATION))


async def test_per_call_timeout_defaults(settings: Any, sleeps: Sleeps) -> None:
    backend = RecordingBackend([_ok_bytes(), _ok_bytes()])
    client = t.TransportClient(settings, backend, sleep=sleeps)
    await _call(client)
    await client.call("deploy-network-service", {"x": 1}, correlation_id=CID, thread_id="t",
                      expect=None, marker=None)
    assert backend.calls == [("devnet/provisioning/network-mapping", 60.0),
                             ("devnet/provisioning/network-deployer", 210.0)]


async def test_per_call_timeout_overrides_honoured(settings: Any, sleeps: Sleeps) -> None:
    backend = RecordingBackend([_ok_bytes(), _ok_bytes()])
    overridden = settings.with_overrides(worker_call_timeout_seconds=30.0,
                                         deployer_call_timeout_seconds=200.0)
    client = t.TransportClient(overridden, backend, sleep=sleeps)
    await _call(client)
    await client.call("deploy-network-service", {}, correlation_id=CID, thread_id="t",
                      expect=None, marker=None)
    assert [timeout for _, timeout in backend.calls] == [30.0, 200.0]


@pytest.mark.parametrize("failure", ["unreachable", "timeout"])
async def test_unreachable_is_retried_twice_with_backoff_1_then_2(
        settings: Any, sleeps: Sleeps, failure: str) -> None:
    backend = RecordingBackend([failure, failure, _ok_bytes()])
    client = t.TransportClient(settings, backend, sleep=sleeps)
    result = await _call(client)
    assert len(backend.calls) == 3
    assert sleeps.calls == [1.0, 2.0]
    assert result.data.service_id == INTERPRETATION["service_id"]


async def test_unreachable_after_the_retries_is_reported_and_retryable(
        settings: Any, sleeps: Sleeps) -> None:
    backend = RecordingBackend(["unreachable"] * 5)
    client = t.TransportClient(settings, backend, sleep=sleeps)
    with pytest.raises(WorkerUnreachableError) as caught:
        await _call(client)
    assert str(caught.value) == "worker unreachable: mapper"
    assert caught.value.retryable is True
    assert len(backend.calls) == 3 and sleeps.calls == [1.0, 2.0]


async def test_retry_override_honoured(settings: Any, sleeps: Sleeps) -> None:
    backend = RecordingBackend(["unreachable"] * 5)
    client = t.TransportClient(settings.with_overrides(worker_call_retries=0), backend,
                               sleep=sleeps)
    with pytest.raises(WorkerUnreachableError):
        await _call(client)
    assert len(backend.calls) == 1 and sleeps.calls == []


async def test_a_returned_failure_is_never_retried(settings: Any, sleeps: Sleeps) -> None:
    backend = RecordingBackend([t.encode(t.reply_failed("tenant is required"))])
    client = t.TransportClient(settings, backend, sleep=sleeps)
    with pytest.raises(WorkerFailedError) as caught:
        await _call(client)
    assert str(caught.value) == "worker failed: mapper — tenant is required"
    assert caught.value.retryable is False
    assert len(backend.calls) == 1 and sleeps.calls == []


async def test_a_submission_lost_after_send_is_not_retried(settings: Any, sleeps: Sleeps) -> None:
    probe_ok = t.encode(t.reply_ok("ok", {"status": "ok"}))
    backend = RecordingBackend([probe_ok, "after-send", _ok_bytes()])
    client = t.TransportClient(settings, backend, sleep=sleeps)
    with pytest.raises(WorkerUnreachableError) as caught:
        await client.call("deploy-network-service", {}, correlation_id=CID, thread_id="t",
                          expect=None, marker=None, idempotent=False)
    assert caught.value.after_send is True
    assert str(caught.value) == "worker unreachable: deployer"
    assert len(backend.calls) == 2  # the probe, then the one send — never a second send
    assert sleeps.calls == []


async def test_a_submission_to_a_silent_worker_is_unreachable_and_unsent(
        settings: Any, gateway: Any, sleeps: Sleeps) -> None:
    sent: list[Any] = []

    async def deployer(request: Any) -> Any:
        sent.append(request)
        return t.reply_ok("ok", {"status": "COMPLETED"})

    await _worker(gateway, "deployer", deployer)
    gateway.stop(CARDS["deployer"][0])
    client = _client(settings, gateway, sleeps)
    with pytest.raises(WorkerUnreachableError) as caught:
        await client.call("deploy-network-service", {}, correlation_id=CID, thread_id="t",
                          expect=None, marker=None, idempotent=False)
    assert caught.value.after_send is False  # nothing was sent: not an unknown outcome
    assert sent == [] and sleeps.calls == [1.0, 2.0]


async def test_a_missing_card_is_unreachable(settings: Any, sleeps: Sleeps,
                                             cards_dir: Path) -> None:
    (cards_dir / "mapper.json").unlink()
    backend = RecordingBackend([_ok_bytes()])
    client = t.TransportClient(settings, backend, sleep=sleeps)
    with pytest.raises(WorkerUnreachableError, match="worker unreachable: map-network-request"):
        await _call(client)
    assert backend.calls == []


async def test_worker_stopped_is_named_unreachable_over_the_fake_gateway(
        settings: Any, gateway: Any, sleeps: Sleeps) -> None:
    await _worker(gateway, "mapper", _ok_mapper())
    client = _client(settings, gateway, sleeps)
    gateway.stop(CARDS["mapper"][0])
    with pytest.raises(WorkerUnreachableError, match="worker unreachable: mapper"):
        await _call(client)
    gateway.start(CARDS["mapper"][0])
    assert (await _call(client)).worker == "mapper"  # resumable: the same call now succeeds


async def test_a_hanging_worker_times_out_as_unreachable(settings: Any, gateway: Any,
                                                         sleeps: Sleeps) -> None:
    async def hang(request: Any) -> Any:
        await asyncio.sleep(3600)

    await _worker(gateway, "mapper", hang)
    client = _client(settings.with_overrides(worker_call_timeout_seconds=0.01,
                                             worker_call_retries=0), gateway, sleeps)
    with pytest.raises(WorkerUnreachableError, match="worker unreachable: mapper"):
        await _call(client)


# --------------------------------------------------------------------------------------------------
# payload carriage: data part authoritative, validate before use (FR-065, D-29)
# --------------------------------------------------------------------------------------------------


async def test_data_part_is_authoritative_over_the_marker(settings: Any, gateway: Any,
                                                          sleeps: Sleeps) -> None:
    other = {**INTERPRETATION, "tenant": "red"}
    text = f"summary\n<!-- {MAPPED_MARKER}: {json.dumps(other)} -->"
    await _worker(gateway, "mapper", _ok_mapper(INTERPRETATION, text=text))
    result = await _call(_client(settings, gateway, sleeps))
    assert result.data.tenant == "blue"
    assert result.source == "data"


async def test_a_truncated_marker_is_ignored_when_the_data_part_is_valid(
        settings: Any, gateway: Any, sleeps: Sleeps) -> None:
    text = f"summary\n<!-- {MAPPED_MARKER}: {json.dumps(INTERPRETATION)[:40]}"
    await _worker(gateway, "mapper", _ok_mapper(INTERPRETATION, text=text))
    result = await _call(_client(settings, gateway, sleeps))
    assert result.data.service_type == "mac-vrf"


async def test_marker_is_parsed_and_validated_when_there_is_no_data_part(
        settings: Any, gateway: Any, sleeps: Sleeps) -> None:
    await _worker(gateway, "mapper", _ok_mapper(with_data=False))
    result = await _call(_client(settings, gateway, sleeps))
    assert result.source == "marker"
    assert isinstance(result.data, Interpretation)


@pytest.mark.parametrize(
    ("data", "text", "with_data"),
    [
        ({**INTERPRETATION, "principal": "alice"}, None, True),
        ({**INTERPRETATION, "service_type": "VPLS"}, None, True),
        (INTERPRETATION, f"<!-- {MAPPED_MARKER}: {json.dumps(INTERPRETATION)[:40]}", False),
        (INTERPRETATION, (f"<!-- {MAPPED_MARKER}: {json.dumps(INTERPRETATION)} -->\n"
                          f"<!-- {MAPPED_MARKER}: {json.dumps(INTERPRETATION)} -->"), False),
        (INTERPRETATION, "no marker and no data part", False),
        ({**INTERPRETATION, "service_type": "VPLS"},
         f"<!-- {MAPPED_MARKER}: {json.dumps(INTERPRETATION)} -->", True),
    ],
    ids=["data-unknown-field", "data-retired-name", "marker-truncated", "marker-duplicated",
         "neither", "invalid-data-valid-marker"],
)
async def test_an_out_of_contract_payload_is_a_terminal_worker_failure(
        settings: Any, gateway: Any, sleeps: Sleeps, data: dict[str, Any], text: str | None,
        with_data: bool) -> None:
    await _worker(gateway, "mapper", _ok_mapper(data, text=text, with_data=with_data))
    with pytest.raises(WorkerFailedError, match=r"^worker failed: mapper — "):
        await _call(_client(settings, gateway, sleeps))
    assert sleeps.calls == []  # never retried


# --------------------------------------------------------------------------------------------------
# worker-side serve() and health probes (FR-074)
# --------------------------------------------------------------------------------------------------


async def test_health_names_each_worker(settings: Any, gateway: Any, sleeps: Sleeps) -> None:
    for name in ("mapper", "allocator"):
        await _worker(gateway, name, _ok_mapper())
    client = _client(settings, gateway, sleeps)
    assert await client.health() == {"mapper": "ok", "allocator": "ok",
                                     "deployer": "unreachable"}
    assert sleeps.calls == []  # a probe is not retried


async def test_serve_turns_a_handler_exception_into_a_worker_failure(
        settings: Any, gateway: Any, sleeps: Sleeps) -> None:
    async def broken(request: Any) -> Any:
        raise RuntimeError("boom")

    await _worker(gateway, "mapper", broken)
    with pytest.raises(WorkerFailedError, match="worker failed: mapper — boom"):
        await _call(_client(settings, gateway, sleeps))


async def test_serve_passes_the_request_fields_to_the_handler(settings: Any, gateway: Any,
                                                              sleeps: Sleeps) -> None:
    seen: list[Any] = []

    async def record(request: Any) -> Any:
        seen.append(request)
        return t.reply_ok("ok", INTERPRETATION)

    await _worker(gateway, "mapper", record)
    await _call(_client(settings, gateway, sleeps), idempotency_key="thread-1:create")
    (request,) = seen
    assert request.skill == "map-network-request"
    assert request.correlation_id == CID
    assert request.thread_id == "thread-1"
    assert request.idempotency_key == "thread-1:create"
    assert request.data == {"text": "extend vlan 100"}


# --------------------------------------------------------------------------------------------------
# the transport itself down: named as the transport, and re-joined unaided (NFR-010, T146)
# --------------------------------------------------------------------------------------------------


class GatewayBackend(RecordingBackend):
    """A scripted backend whose gateway can be taken away and brought back."""

    def __init__(self, script: list[Any]) -> None:
        super().__init__(script)
        self.up = True
        self.closed = 0

    async def gateway_reachable(self) -> bool:
        return self.up

    async def close(self) -> None:
        self.closed += 1


async def test_transport_down_is_named_as_the_transport(settings: Any, sleeps: Sleeps) -> None:
    backend = GatewayBackend(["unreachable"] * 5)
    backend.up = False
    client = t.TransportClient(settings, backend, sleep=sleeps)
    with pytest.raises(WorkerUnreachableError) as caught:
        await _call(client)
    text = str(caught.value)
    assert text.startswith("worker unreachable: mapper — transport unavailable: ")
    assert "SLIM gateway at http://slim.agentic-netops-agents.svc:46357" in text
    assert caught.value.retryable is True


async def test_a_silent_worker_behind_a_live_gateway_does_not_blame_the_transport(
        settings: Any, sleeps: Sleeps) -> None:
    """The negative control of the case above: the gateway answers, one worker does not."""
    backend = GatewayBackend(["unreachable"] * 5)
    client = t.TransportClient(settings, backend, sleep=sleeps)
    with pytest.raises(WorkerUnreachableError) as caught:
        await _call(client)
    assert str(caught.value) == "worker unreachable: mapper"
    assert backend.closed == 0


async def test_the_client_reconnects_once_the_gateway_is_back(settings: Any,
                                                               sleeps: Sleeps) -> None:
    backend = GatewayBackend(["unreachable"] * 3 + [_ok_bytes()])
    backend.up = False
    client = t.TransportClient(settings, backend, sleep=sleeps)
    with pytest.raises(WorkerUnreachableError):
        await _call(client)
    assert backend.closed == 0  # nothing to reconnect to yet
    backend.up = True
    result = await _call(client)
    assert backend.closed == 1  # the dead connection dropped, a new one opened on use
    assert result.data.service_id == INTERPRETATION["service_id"]


async def test_health_names_the_transport_when_the_gateway_is_gone(settings: Any,
                                                                   sleeps: Sleeps) -> None:
    backend = GatewayBackend([])
    backend.up = False
    client = t.TransportClient(settings, backend, sleep=sleeps)
    with pytest.raises(t.DeliveryError, match=r"SLIM gateway .* accepts no connection"):
        await client.health()
    backend.up = True
    backend.script = [t.encode(t.reply_ok("ok", {"status": "ok"}))] * 3
    health = await client.health()
    assert backend.closed == 1 and set(health.values()) == {"ok"}


async def test_every_worker_silent_reconnects_on_the_next_check(settings: Any,
                                                                sleeps: Sleeps) -> None:
    """A gateway that restarted between two checks: reachable, but it forgot this process."""
    backend = GatewayBackend(["unreachable"] * 3)
    client = t.TransportClient(settings, backend, sleep=sleeps)
    assert set((await client.health()).values()) == {"unreachable"}
    backend.script = [t.encode(t.reply_ok("ok", {"status": "ok"}))] * 3
    assert set((await client.health()).values()) == {"ok"}
    assert backend.closed == 1
