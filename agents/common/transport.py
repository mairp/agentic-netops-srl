"""The agent-to-agent transport (T083; contracts/a2a-transport.md, FR-070 to FR-074, FR-065, D-27
to D-29).

Three layers:

**Backends** — anything with the small :class:`Transport` protocol
(``request(topic, message, timeout) -> reply``, ``register(topic, handler)``, ``close()``):

* :class:`SlimTransport` — the real one, on ``slim_bindings`` (the pinned SLIM 0.6 bindings the
  ``agntcy_app_sdk`` SLIM transport is built on). Its connect configuration is built in exactly one
  function, :func:`slim_client_config` — TLS with the in-cluster CA and basic auth from the
  ``slim-gateway`` Secret — so the key names can be corrected in one place. A refusal of the
  credentials is raised as :class:`~common.exceptions.TransportAuthenticationError`
  (:func:`map_slim_error`).
* :class:`InMemoryGateway` / :class:`InMemoryTransport` — the in-process stand-in the unit tests
  use; it keeps the gateway behaviours the contract relies on (a registration without the
  gateway's credentials is refused; an unregistered or stopped topic is unreachable; a hanging
  worker times out).

**The client** — :class:`TransportClient`: resolves a skill to a topic through the agent cards in
``AGENT_CARDS_DIR`` **at call time** (it holds no worker list: a new card file is a new worker with
no code change); applies the per-call timeout (60 s; 210 s for the deploy skill, which contains the
convergence watch) and the bounded retry (2 retries, exponential backoff from 1 s) to the
*unreachable* class only; reports ``worker unreachable: <name>`` (retryable, the thread stays
resumable) and ``worker failed: <name> — <reason>`` (terminal) apart; and validates the payload
before any use — the data part is authoritative, the comment marker compatibility only.

**The worker side** — :func:`serve` registers a worker under its card id and answers stage
requests and health probes.

Messages are A2A ``Message`` objects (the pinned a2a-sdk): a text part carrying the human-readable
summary and the compatibility marker, and a data part carrying the structured object.
"""

from __future__ import annotations

import asyncio
import contextlib
import hmac
import json
import logging
import re
import uuid
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass, field
from datetime import timedelta
from pathlib import Path
from typing import Any, Protocol, runtime_checkable
from urllib.parse import urlsplit, urlunsplit

from a2a.types import DataPart, Message, Part, Role, TextPart
from pydantic import BaseModel, ValidationError

from common.exceptions import (
    TransportAuthenticationError,
    TransportConfigurationError,
    TransportError,
    WorkerFailedError,
    WorkerUnreachableError,
)
from common.guards.redaction import redact
from config.settings import (
    DEFAULT_TRANSPORT_AUTH_CHECK_SECONDS,
    DEFAULT_TRANSPORT_ENDPOINT,
    Settings,
)

log = logging.getLogger("agentic_netops.transport")

DEFAULT_ENDPOINT = DEFAULT_TRANSPORT_ENDPOINT
TRANSPORT = "SLIM"
# The one skill whose call contains the convergence watch, and so takes the deployer timeout.
DEPLOY_SKILL = "deploy-network-service"
KIND_STAGE = "stage"
KIND_HEALTH = "health-probe"
META = "x-agentic-netops"
WORKER_FIELD = "x-agentic-netops-worker"
DEFAULT_PROBE_TIMEOUT_SECONDS = 3.0

Handler = Callable[[bytes], Awaitable[bytes]]


class DeliveryError(TransportError):
    """The backend could not deliver or could not get an answer. ``after_send`` is true when the
    request had already been handed to the transport."""

    def __init__(self, message: str, *, after_send: bool) -> None:
        super().__init__(message)
        self.after_send = after_send


@runtime_checkable
class Transport(Protocol):
    kind: str
    endpoint: str

    async def request(self, topic: str, message: bytes, timeout: float) -> bytes: ...  # noqa: ASYNC109

    async def register(self, topic: str, handler: Handler) -> None: ...

    async def close(self) -> None: ...


# --------------------------------------------------------------------------------------------------
# agent cards (FR-071, data-model.md §14)
# --------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Card:
    id: str
    worker: str
    skills: tuple[str, ...]
    raw: Mapping[str, Any] = field(compare=False, repr=False)

    @property
    def topic(self) -> str:
        """The routable ``org/namespace/local_name`` — the registration and addressing topic."""
        return self.id

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> Card:
        card_id = raw.get("id")
        if not isinstance(card_id, str) or len(card_id.split("/")) != 3 or not all(
                card_id.split("/")):
            raise ValueError(f"card id {card_id!r} is not a routable org/namespace/local_name")
        skills = tuple(s["id"] for s in raw.get("skills", []) if isinstance(s, Mapping)
                       and isinstance(s.get("id"), str))
        worker = raw.get(WORKER_FIELD) or card_id.rsplit("/", 1)[-1]
        return cls(card_id, str(worker), skills, raw)


def load_cards(directory: Path) -> list[Card]:
    """Every card in ``directory`` (one JSON file each), read now. Unreadable files are skipped."""
    cards: list[Card] = []
    try:
        entries = sorted(Path(directory).iterdir())
    except (FileNotFoundError, NotADirectoryError, PermissionError):
        return cards
    for entry in entries:
        if entry.name.startswith(".") or entry.suffix != ".json" or not entry.is_file():
            continue
        try:
            cards.append(Card.from_dict(json.loads(entry.read_text(encoding="utf-8"))))
        except (OSError, ValueError, KeyError, TypeError) as exc:
            log.warning("agent card %s skipped: %s", entry.name, exc)
    return cards


# --------------------------------------------------------------------------------------------------
# messages (two parts: text + data; D-29)
# --------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class StageMessage:
    """A request as a worker's handler sees it."""

    kind: str
    skill: str
    correlation_id: str | None
    thread_id: str | None
    idempotency_key: str | None
    operation: str
    data: dict[str, Any] | None
    text: str


def _parts(text: str, data: Mapping[str, Any] | None) -> list[Part]:
    parts = [Part(root=TextPart(text=text))]
    if data is not None:
        parts.append(Part(root=DataPart(data=dict(data))))
    return parts


def build_request(kind: str, skill: str, data: Mapping[str, Any] | None, *, text: str = "",
                  correlation_id: str | None = None, thread_id: str | None = None,
                  idempotency_key: str | None = None, operation: str = "create") -> Message:
    meta = {"kind": kind, "skill": skill, "correlation_id": correlation_id,
            "thread_id": thread_id, "idempotency_key": idempotency_key, "operation": operation}
    return Message(message_id=uuid.uuid4().hex, role=Role.user, parts=_parts(text, data),
                   context_id=thread_id, metadata={META: meta})


def reply_ok(text: str, data: Mapping[str, Any] | BaseModel | None = None) -> Message:
    """A worker's answer: the summary (with the compatibility marker) and the data part."""
    if isinstance(data, BaseModel):
        data = data.model_dump(mode="json", by_alias=True, exclude_unset=True)
    return Message(message_id=uuid.uuid4().hex, role=Role.agent, parts=_parts(text, data),
                   metadata={META: {"status": "ok"}})


def reply_failed(reason: str) -> Message:
    """A worker's error answer: terminal for the stage, never retried."""
    return Message(message_id=uuid.uuid4().hex, role=Role.agent,
                   parts=_parts(f"error: {reason}", None),
                   metadata={META: {"status": "error", "reason": reason}})


def encode(message: Message) -> bytes:
    return json.dumps(message.model_dump(mode="json", by_alias=True, exclude_none=True),
                      separators=(",", ":")).encode()


def decode(raw: bytes) -> Message:
    return Message.model_validate(json.loads(raw))


def _meta(message: Message) -> dict[str, Any]:
    meta = (message.metadata or {}).get(META)
    return meta if isinstance(meta, dict) else {}


def _text_and_data(message: Message) -> tuple[str, list[Any]]:
    texts: list[str] = []
    datas: list[Any] = []
    for part in message.parts:
        root = part.root
        if isinstance(root, TextPart):
            texts.append(root.text)
        elif isinstance(root, DataPart):
            datas.append(root.data)
    return "\n".join(texts), datas


def _marker_object(text: str, marker: str) -> dict[str, Any]:
    """The object carried by ``<!-- MARKER: {...} -->``; raises ValueError if absent/partial."""
    opener = re.compile(r"<!--\s*" + re.escape(marker) + r"\s*:")
    starts = opener.findall(text)
    if not starts:
        raise ValueError(f"no data part and no {marker} marker")
    if len(starts) > 1:
        raise ValueError(f"the {marker} marker appears {len(starts)} times")
    match = re.search(r"<!--\s*" + re.escape(marker) + r"\s*:(.*?)-->", text, re.DOTALL)
    if match is None:
        raise ValueError(f"the {marker} marker is truncated")
    try:
        value = json.loads(match.group(1))
    except json.JSONDecodeError as exc:
        raise ValueError(f"the {marker} marker does not hold JSON: {exc.msg}") from None
    if not isinstance(value, dict):
        raise ValueError(f"the {marker} marker does not hold an object")
    return value


def _validation_summary(exc: ValidationError) -> str:
    errors = exc.errors()
    first = errors[0] if errors else {"loc": (), "msg": str(exc)}
    where = ".".join(str(p) for p in first.get("loc", ())) or "payload"
    more = f" (+{len(errors) - 1} more)" if len(errors) > 1 else ""
    return f"out-of-contract payload: {where}: {first.get('msg')}{more}"


def extract_payload(message: Message, expect: type[BaseModel] | None, marker: str | None,
                    worker: str) -> tuple[Any, str | None]:
    """The receiver rule of contracts/a2a-transport.md: read the data part when present,
    otherwise parse the marker — and either way validate against ``expect`` before any use.
    Returns ``(payload, source)``; raises :class:`WorkerFailedError`."""
    text, datas = _text_and_data(message)
    if len(datas) > 1:
        raise WorkerFailedError(worker, f"out-of-contract payload: {len(datas)} data parts")
    if datas:
        obj, source = datas[0], "data"
    elif marker is not None:
        try:
            obj, source = _marker_object(text, marker), "marker"
        except ValueError as exc:
            raise WorkerFailedError(worker, f"out-of-contract payload: {exc}") from None
    elif expect is None:
        return None, None
    else:
        raise WorkerFailedError(worker, "out-of-contract payload: no data part")
    if expect is None:
        if not isinstance(obj, dict):
            raise WorkerFailedError(worker, "out-of-contract payload: data part is not an object")
        return obj, source
    try:
        return expect.model_validate(obj, strict=True), source
    except ValidationError as exc:
        raise WorkerFailedError(worker, _validation_summary(exc)) from None


# --------------------------------------------------------------------------------------------------
# the authentication round trip (slim-live.md)
# --------------------------------------------------------------------------------------------------


async def check_transport_auth(backend: Any, topic: str, *,
                               timeout: float = DEFAULT_TRANSPORT_AUTH_CHECK_SECONDS  # noqa: ASYNC109
                               ) -> None:
    """Prove the gateway accepted this process's credentials, or raise
    :class:`TransportAuthenticationError` naming the endpoint.

    The pinned SLIM gateway refuses a wrong or missing basic-auth credential *silently*:
    ``connect()`` and ``subscribe()`` return normally, the gateway answers the data-plane stream
    with HTTP 401, and every later message is dropped. So the only proof is a round trip: a second,
    independent connection with the same client configuration (``backend.echo_probe``) sends a
    probe to ``topic`` — the name this process has just registered — and the listener behind it
    answers. No answer within ``timeout`` (``SLIM_AUTH_CHECK_TIMEOUT_SECONDS``, default 5 s) is the
    refusal."""
    probe = encode(build_request(KIND_HEALTH, "transport-auth-check", None))
    endpoint = getattr(backend, "endpoint", DEFAULT_ENDPOINT)
    try:
        async with asyncio.timeout(timeout):
            await backend.echo_probe(topic, probe, timeout)
    except (TimeoutError, DeliveryError, OSError) as exc:
        raise TransportAuthenticationError(
            f"transport authentication refused by {endpoint}: no echo from {topic} within "
            f"{timeout:g} s — the SLIM gateway drops the messages of an unauthenticated "
            f"connection ({type(exc).__name__})") from None


async def _echo(message: bytes) -> bytes:
    """The listener of a client's own name: answers the authentication probe with itself."""
    return message


# --------------------------------------------------------------------------------------------------
# the client
# --------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class CallResult:
    worker: str
    topic: str
    data: Any
    text: str
    source: str | None


class TransportClient:
    """The supervisor's call helper: SLIM only, cards at call time, bounded retry."""

    def __init__(self, settings: Settings, backend: Transport, *,
                 sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
                 cards_dir: Path | None = None,
                 probe_timeout: float = DEFAULT_PROBE_TIMEOUT_SECONDS) -> None:
        settings.require_slim()  # raises rather than falls back (D-27)
        if getattr(backend, "kind", None) != TRANSPORT:
            raise TransportConfigurationError(
                f"backend {type(backend).__name__} is not a {TRANSPORT} transport")
        self.settings = settings
        self.backend = backend
        self.sleep = sleep
        self.cards_dir = Path(cards_dir or settings.agent_cards_dir)
        self.probe_timeout = probe_timeout
        self._authenticated = False
        self._echo_registered = False
        self._auth_lock = asyncio.Lock()

    async def ensure_authenticated(self) -> None:
        """Once per client: register a temporary echo listener on this client's own name and run
        :func:`check_transport_auth` against it. Raises :class:`TransportAuthenticationError`;
        a failure is not cached, so the next call checks again (a rotated Secret heals)."""
        if self._authenticated:
            return
        identity = getattr(self.backend, "identity", None)
        if identity is None or not hasattr(self.backend, "echo_probe"):
            self._authenticated = True  # a backend without a gateway to prove (tests)
            return
        async with self._auth_lock:
            if self._authenticated:
                return
            if not self._echo_registered:
                await self.backend.register(identity, _echo)
                self._echo_registered = True
            await check_transport_auth(self.backend, identity,
                                       timeout=self.settings.transport_auth_check_seconds)
            self._authenticated = True

    @property
    def transport(self) -> str:
        return TRANSPORT

    @property
    def endpoint(self) -> str:
        return self.settings.transport_endpoint

    def discover(self) -> list[Card]:
        return load_cards(self.cards_dir)

    def resolve(self, skill: str) -> Card:
        """The card offering ``skill``, read now. None: the worker is unreachable, by skill."""
        for card in self.discover():
            if skill in card.skills:
                return card
        raise WorkerUnreachableError(skill, cause=f"no agent card offers skill {skill!r}")

    def timeout_for(self, skill: str) -> float:
        if skill == DEPLOY_SKILL:
            return self.settings.deployer_call_timeout_seconds
        return self.settings.worker_call_timeout_seconds

    async def call(self, skill: str, data: Mapping[str, Any] | None, *,
                   expect: type[BaseModel] | None, marker: str | None,
                   correlation_id: str | None, thread_id: str | None,
                   idempotency_key: str | None = None, operation: str = "create",
                   text: str = "", idempotent: bool = True) -> CallResult:
        """Call the worker offering ``skill``. Raises :class:`WorkerUnreachableError` (after the
        bounded retry; ``after_send`` set when a non-idempotent request may have been delivered)
        or :class:`WorkerFailedError` (never retried)."""
        card = self.resolve(skill)
        try:
            await self.ensure_authenticated()
        except TransportAuthenticationError as exc:
            raise WorkerUnreachableError(card.worker, cause=str(exc)) from exc
        timeout = self.timeout_for(skill)
        payload = encode(build_request(KIND_STAGE, skill, data, text=text,
                                       correlation_id=correlation_id, thread_id=thread_id,
                                       idempotency_key=idempotency_key, operation=operation))
        attempts = 1 + self.settings.worker_call_retries
        after_send = False
        cause = None
        for attempt in range(attempts):
            # A non-idempotent request (a submission) is sent only to a worker that answers a
            # probe first: SLIM reports an unregistered topic as silence, not as an error, and a
            # silent submission would otherwise be indistinguishable from one lost after
            # delivery (STATUS_UNKNOWN). A worker that does not answer is unreachable, unsent.
            if not idempotent and not await self.probe(card):
                after_send, cause = False, "health probe unanswered before sending"
            else:
                try:
                    async with asyncio.timeout(timeout):
                        raw = await self.backend.request(card.topic, payload, timeout)
                    break
                except TimeoutError:
                    after_send, cause = True, f"no answer within {timeout:g} s"
                except DeliveryError as exc:
                    after_send, cause = exc.after_send, str(exc)
                except TransportAuthenticationError as exc:
                    raise WorkerUnreachableError(card.worker, cause=str(exc)) from exc
                except (TransportError, OSError) as exc:
                    after_send, cause = False, str(exc)
            log.warning("worker unreachable: %s (attempt %d of %d): %s", card.worker,
                        attempt + 1, attempts, redact(cause or ""))
            if after_send and not idempotent:
                raise WorkerUnreachableError(card.worker, after_send=True, cause=cause)
            if attempt + 1 < attempts:
                await self.sleep(self.settings.worker_call_backoff_seconds * (2 ** attempt))
        else:
            raise WorkerUnreachableError(card.worker, after_send=after_send, cause=cause)
        try:
            reply = decode(raw)
        except (ValueError, ValidationError) as exc:
            raise WorkerFailedError(card.worker, f"undecodable reply: {exc}") from None
        meta = _meta(reply)
        if meta.get("status") != "ok":
            raise WorkerFailedError(card.worker, str(meta.get("reason") or "the worker failed"))
        value, source = extract_payload(reply, expect, marker, card.worker)
        text_out, _ = _text_and_data(reply)
        return CallResult(card.worker, card.topic, value, text_out, source)

    async def probe(self, card: Card) -> bool:
        """One health probe, no retry: the readiness answer must be prompt."""
        message = encode(build_request(KIND_HEALTH, card.skills[0] if card.skills else "",
                                       None))
        try:
            async with asyncio.timeout(self.probe_timeout):
                raw = await self.backend.request(card.topic, message, self.probe_timeout)
            return _meta(decode(raw)).get("status") == "ok"
        except Exception as exc:  # any failure of a probe is "unreachable"
            log.info("health probe of %s failed: %s", card.worker, redact(str(exc)))
            return False

    async def health(self) -> dict[str, str]:
        """``{worker: "ok" | "unreachable"}`` for every card found now (FR-074)."""
        cards = self.discover()
        if cards:
            await self.ensure_authenticated()  # raises TransportAuthenticationError
        results = await asyncio.gather(*(self.probe(c) for c in cards))
        return {c.worker: ("ok" if ok else "unreachable") for c, ok in zip(cards, results,
                                                                              strict=True)}


# --------------------------------------------------------------------------------------------------
# the worker side
# --------------------------------------------------------------------------------------------------

WorkerHandler = Callable[[StageMessage], Awaitable[Message]]


async def serve(card: Mapping[str, Any] | Card, handler: WorkerHandler, backend: Transport, *,
                auth_check_timeout: float = DEFAULT_TRANSPORT_AUTH_CHECK_SECONDS) -> Card:
    """Register the worker on the transport under its card id; answer stage requests through
    ``handler`` and health probes directly. A handler exception is answered as a failure.

    After registering, :func:`check_transport_auth` proves the registration by a round trip to
    the card id; a silently refused registration raises :class:`TransportAuthenticationError`."""
    card = card if isinstance(card, Card) else Card.from_dict(card)

    async def dispatch(raw: bytes) -> bytes:
        try:
            request = decode(raw)
        except (ValueError, ValidationError) as exc:
            return encode(reply_failed(f"undecodable request: {exc}"))
        meta = _meta(request)
        if meta.get("kind") == KIND_HEALTH:
            return encode(reply_ok("ok", {"status": "ok", "worker": card.worker}))
        text, datas = _text_and_data(request)
        message = StageMessage(
            kind=str(meta.get("kind") or KIND_STAGE), skill=str(meta.get("skill") or ""),
            correlation_id=meta.get("correlation_id"), thread_id=meta.get("thread_id"),
            idempotency_key=meta.get("idempotency_key"),
            operation=str(meta.get("operation") or "create"),
            data=datas[0] if datas else None, text=text)
        try:
            reply = await handler(message)
        except Exception as exc:
            log.exception("stage handler of %s failed", card.worker)
            reply = reply_failed(redact(str(exc)) or type(exc).__name__)
        return encode(reply)

    await backend.register(card.topic, dispatch)
    if hasattr(backend, "echo_probe"):
        await check_transport_auth(backend, card.topic, timeout=auth_check_timeout)
    return card


# --------------------------------------------------------------------------------------------------
# the in-memory stand-in (unit tests)
# --------------------------------------------------------------------------------------------------


class InMemoryGateway:
    """An in-process SLIM gateway: basic auth, topics, stoppable registrations.

    Like the pinned gateway, it refuses a wrong or missing credential *silently*: ``connect``
    succeeds, but that connection's registrations are dropped and its messages are never answered
    (a :class:`TimeoutError`, immediately, instead of waiting the bound)."""

    def __init__(self, username: str = "slim", password: str = "slim") -> None:  # noqa: S107
        self._username = username
        self._password = password
        self._handlers: dict[str, Handler] = {}
        self._stopped: set[str] = set()
        # Topics whose connection drops right after a stage message was delivered (a health probe
        # still answers): the "transport lost after submission" case.
        self.drop_after_send: set[str] = set()
        self.requests: list[tuple[str, bytes]] = []

    def connect(self, credentials: tuple[str, str] | None, *, identity: str) -> InMemoryTransport:
        user, password = credentials or ("", "")
        ok_user = hmac.compare_digest(user.encode(), self._username.encode())
        ok_pass = hmac.compare_digest(password.encode(), self._password.encode())
        return InMemoryTransport(self, identity, authenticated=bool(ok_user and ok_pass),
                                 credentials=credentials)

    def registered(self) -> set[str]:
        return set(self._handlers) - self._stopped

    def stop(self, topic: str) -> None:
        self._stopped.add(topic)

    def start(self, topic: str) -> None:
        self._stopped.discard(topic)

    async def deliver(self, topic: str, message: bytes, timeout: float,  # noqa: ASYNC109
                      *, record: bool = True) -> bytes:
        handler = self._handlers.get(topic)
        if handler is None or topic in self._stopped:
            raise DeliveryError(f"no route to {topic}", after_send=False)
        if record:
            self.requests.append((topic, message))
        async with asyncio.timeout(timeout):
            reply = await handler(message)
        if topic in self.drop_after_send and not _is_probe(message):
            raise DeliveryError(f"connection to {topic} lost after send", after_send=True)
        return reply


def _is_probe(message: bytes) -> bool:
    try:
        return _meta(decode(message)).get("kind") == KIND_HEALTH
    except (ValueError, ValidationError):
        return False


class InMemoryTransport:
    kind = TRANSPORT

    def __init__(self, gateway: InMemoryGateway, identity: str,
                 endpoint: str = DEFAULT_ENDPOINT, *, authenticated: bool = True,
                 credentials: tuple[str, str] | None = None) -> None:
        self.gateway = gateway
        self.identity = identity
        self.endpoint = endpoint
        self.authenticated = authenticated
        self._credentials = credentials
        self._topics: list[str] = []

    async def request(self, topic: str, message: bytes, timeout: float) -> bytes:  # noqa: ASYNC109
        if not self.authenticated:
            raise TimeoutError  # the gateway dropped it: no answer, ever
        return await self.gateway.deliver(topic, message, timeout)

    async def echo_probe(self, topic: str, message: bytes,
                         timeout: float) -> bytes:  # noqa: ASYNC109
        """A second connection with the same credentials sends ``message`` to ``topic``."""
        checker = self.gateway.connect(self._credentials, identity=f"{self.identity}-authcheck")
        if not checker.authenticated:
            raise TimeoutError
        return await self.gateway.deliver(topic, message, timeout, record=False)

    async def register(self, topic: str, handler: Handler) -> None:
        if not self.authenticated:
            return  # silently dropped, as the gateway does
        self.gateway._handlers[topic] = handler
        self._topics.append(topic)

    async def close(self) -> None:
        for topic in self._topics:
            self.gateway._handlers.pop(topic, None)
        self._topics.clear()


# --------------------------------------------------------------------------------------------------
# SLIM (slim_bindings 0.6.3)
# --------------------------------------------------------------------------------------------------

_AUTH_REFUSAL = re.compile(
    r"unauthenticated|unauthori[sz]ed|\b401\b|\b403\b|authentication|permission denied"
    r"|invalid credentials|forbidden", re.IGNORECASE)


def map_slim_error(exc: BaseException, *, after_send: bool) -> TransportError:
    """Map a slim_bindings exception: a credential refusal is the authentication error."""
    message = redact(str(exc))
    if _AUTH_REFUSAL.search(message):
        return TransportAuthenticationError(f"SLIM gateway refused the credentials: {message}")
    return DeliveryError(message or type(exc).__name__, after_send=after_send)


def _read_secret(directory: Path, key: str) -> str:
    try:
        value = (directory / key).read_text(encoding="utf-8").strip()
    except OSError:
        value = ""
    if not value:
        raise TransportAuthenticationError(
            f"SLIM gateway credentials unreadable: no {key} in {directory}; an unauthenticated "
            "connection is never attempted")
    return value


def tls_endpoint(endpoint: str) -> str:
    """``http://host:port`` → ``https://host:port``: slim_bindings speaks TLS only to an https
    endpoint, while the contract's variable carries ``http://`` (slim-live.md). Host and port
    are kept — the host is the name the server certificate is verified against."""
    parts = urlsplit(endpoint if "://" in endpoint else f"http://{endpoint}")
    scheme = "https" if parts.scheme in ("http", "https") else parts.scheme
    return urlunsplit((scheme, parts.netloc, parts.path, parts.query, parts.fragment))


def slim_client_config(settings: Settings) -> dict[str, Any]:
    """The slim_bindings client connect configuration — built here and nowhere else.

    Exactly the shape proven live (slim-live.md): the endpoint with scheme ``https``, TLS against
    the in-cluster CA (``slim-tls``'s ``ca.crt``), and basic auth from the ``slim-gateway`` Secret
    (R-14 fallback: the pinned release verifies no client certificate)."""
    settings.require_slim()
    return {
        "endpoint": tls_endpoint(settings.transport_endpoint),
        "tls": {"ca_file": str(settings.slim_tls_dir / "ca.crt")},
        "auth": {"basic": {"username": _read_secret(settings.slim_gateway_dir, "username"),
                           "password": _read_secret(settings.slim_gateway_dir, "password")}},
    }


def _pyname(topic: str) -> Any:
    import slim_bindings

    org, namespace, local = topic.split("/")
    return slim_bindings.PyName(org, namespace, local)


class SlimTransport:
    """The SLIM backend. ``identity`` is this process's routable name (a worker's card id)."""

    kind = TRANSPORT

    def __init__(self, settings: Settings, identity: str, *,
                 config_factory: Callable[[Settings], dict[str, Any]] = slim_client_config
                 ) -> None:
        settings.require_slim()
        if len(identity.split("/")) != 3:
            raise TransportConfigurationError(f"{identity!r} is not org/namespace/local_name")
        self.settings = settings
        self.identity = identity
        self.endpoint = settings.transport_endpoint
        self._config_factory = config_factory
        self._slim: Any = None
        self._lock = asyncio.Lock()
        self._tasks: set[asyncio.Task[Any]] = set()

    async def _open(self, identity: str) -> tuple[Any, dict[str, Any]]:
        """A new local-service Slim instance named ``identity``, connected with the one client
        configuration. (``Slim.new`` needs a writable ``$HOME``; the images set ``HOME=/tmp``.)"""
        import slim_bindings

        config = self._config_factory(self.settings)
        secret = config["auth"]["basic"]["password"]
        provider = slim_bindings.PyIdentityProvider.SharedSecret(identity=identity,
                                                                 shared_secret=secret)
        verifier = slim_bindings.PyIdentityVerifier.SharedSecret(identity=identity,
                                                                 shared_secret=secret)
        try:
            slim = await slim_bindings.Slim.new(_pyname(identity), provider, verifier,
                                                local_service=True)
            await slim.connect(config)
        except Exception as exc:
            raise map_slim_error(exc, after_send=False) from exc
        return slim, config

    async def connect(self) -> Any:
        async with self._lock:
            if self._slim is None:
                self._slim, _config = await self._open(self.identity)
            return self._slim

    async def echo_probe(self, topic: str, message: bytes,
                         timeout: float) -> bytes:  # noqa: ASYNC109
        """The round trip of :func:`check_transport_auth`: a second Slim instance
        (``local_service=True``) with the same configuration sends ``message`` point-to-point to
        ``topic`` and waits for the echo. On a refused credential ``get_message`` never returns."""
        import slim_bindings

        org, namespace, local = self.identity.split("/")
        checker, config = await self._open(f"{org}/{namespace}/{local}-authcheck")
        session = None
        try:
            remote = _pyname(topic)
            await checker.set_route(remote)
            session = await checker.create_session(
                slim_bindings.PySessionConfiguration.PointToPoint(
                    peer_name=remote, max_retries=2, timeout=timedelta(seconds=1),
                    mls_enabled=False))
            await session.publish(message)
            async with asyncio.timeout(timeout):
                _ctx, reply = await session.get_message()
            return bytes(reply)
        except TimeoutError:
            raise
        except Exception as exc:
            raise map_slim_error(exc, after_send=True) from exc
        finally:
            if session is not None:
                with contextlib.suppress(Exception):
                    await checker.delete_session(session)
            with contextlib.suppress(Exception):
                await checker.disconnect(config["endpoint"])

    async def request(self, topic: str, message: bytes, timeout: float) -> bytes:  # noqa: ASYNC109
        import slim_bindings

        slim = await self.connect()
        sent = False
        session = None
        try:
            remote = _pyname(topic)
            await slim.set_route(remote)
            session = await slim.create_session(
                slim_bindings.PySessionConfiguration.PointToPoint(
                    peer_name=remote, max_retries=2, timeout=timedelta(seconds=2),
                    mls_enabled=True))
            await session.publish(message)
            sent = True
            async with asyncio.timeout(timeout):
                _ctx, reply = await session.get_message()
            return bytes(reply)
        except TimeoutError:
            raise
        except Exception as exc:
            raise map_slim_error(exc, after_send=sent) from exc
        finally:
            if session is not None:
                try:
                    await slim.delete_session(session)
                except Exception as exc:  # a closed session is not an error of the call
                    log.debug("delete_session: %s", exc)

    async def register(self, topic: str, handler: Handler) -> None:
        if topic != self.identity:
            raise TransportConfigurationError(
                f"a SLIM worker registers under its own card id {self.identity!r}, not {topic!r}")
        slim = await self.connect()  # connect() subscribes the local name
        task = asyncio.create_task(self._listen(slim, handler))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _listen(self, slim: Any, handler: Handler) -> None:
        while True:
            try:
                session = await slim.listen_for_session()
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                log.error("SLIM listen_for_session failed: %s", redact(str(exc)))
                await asyncio.sleep(1)
                continue
            task = asyncio.create_task(self._answer(session, handler))
            self._tasks.add(task)
            task.add_done_callback(self._tasks.discard)

    async def _answer(self, session: Any, handler: Handler) -> None:
        while True:
            try:
                ctx, raw = await session.get_message()
            except asyncio.CancelledError:
                raise
            except Exception:
                return  # the peer closed the session
            reply = await handler(bytes(raw))
            try:
                await session.publish_to(ctx, reply)
            except Exception as exc:
                log.warning("SLIM reply failed: %s", redact(str(exc)))
                return

    async def close(self) -> None:
        for task in list(self._tasks):
            task.cancel()
        if self._slim is not None:
            try:
                await self._slim.disconnect(tls_endpoint(self.endpoint))
            except Exception as exc:
                log.debug("SLIM disconnect: %s", exc)
            self._slim = None


__all__ = [
    "DEFAULT_ENDPOINT",
    "DEPLOY_SKILL",
    "KIND_HEALTH",
    "KIND_STAGE",
    "CallResult",
    "Card",
    "DeliveryError",
    "InMemoryGateway",
    "InMemoryTransport",
    "SlimTransport",
    "StageMessage",
    "Transport",
    "TransportClient",
    "build_request",
    "check_transport_auth",
    "decode",
    "encode",
    "extract_payload",
    "load_cards",
    "map_slim_error",
    "reply_failed",
    "reply_ok",
    "serve",
    "slim_client_config",
    "tls_endpoint",
]
