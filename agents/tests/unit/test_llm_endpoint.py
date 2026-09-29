"""The model endpoint rule, Python half (T168; FR-106, FR-079, SC-048, AD-49, AD-50, AD-54, AD-67).

Written with the shell half (tests/unit/lifecycle/intent_secrets_test.sh) so the rule has one test
author, but it **passes with T080** (US7), which creates ``agents/common/llm.py``, and — for the
manifest half — **with T087**, which authors ``deploy/agents/*.yaml`` (AD-50). Until then each test
is a strict expected failure: it fails because what it tests is absent, and the moment that file
exists the marker lifts and the test must pass. US6 closes on the shell half alone.

The interface T080 implements, fixed here:

``common.llm.EndpointError(Exception)``
    Raised when there is no endpoint a model call may go to. Its message names what is missing:
    the declared gateway (by the Secret's ``GATEWAY`` value) or the missing ``BASE_URL``.

``common.llm.load_endpoint(secret_dir: pathlib.Path) -> Endpoint``
    Reads the mounted ``llm-provider`` Secret — one file per key: ``LLM_MODEL``, ``API_KEY``,
    ``BASE_URL`` and, for a shared gateway, ``GATEWAY`` (contracts/kubernetes-objects.md). A
    ``GATEWAY`` with an absent or empty ``BASE_URL`` raises ``EndpointError`` naming the gateway.

``common.llm.LLMClient(secret_dir: pathlib.Path, *, transport: Callable[..., Any] | None = None)``
    Construction is agent start-up: it calls ``load_endpoint`` (so a gateway without a base URL
    refuses to start) and logs, through the standard ``logging`` module (propagating, INFO or
    above), one line naming the effective endpoint — the base URL redacted by
    ``common.guards.redaction.redact`` (FR-079), or the provider's own default stated as such.
    ``transport`` is the injection seam for the call to the model; it is invoked as
    ``transport(base_url=<str|None>, model=<str>, api_key=<str>, messages=<list>)`` and its
    return value is returned by ``complete``. The default transport is LiteLLM with ``api_base``
    passed explicitly.

``LLMClient.complete(messages: list[dict]) -> Any``
    Re-reads the mounted Secret on **every** call, never a value cached at start-up. If the
    Secret carried a base URL at start-up (or declares a gateway) and carries none now, it makes
    no model call, dials no host, and raises ``EndpointError`` naming the missing ``BASE_URL`` —
    it never lets the library fall back to its default endpoint.
"""

from __future__ import annotations

import importlib
import logging
import socket
from collections.abc import Iterator
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

import pytest
import yaml

AGENTS = Path(__file__).resolve().parents[2]
REPO = AGENTS.parent
LLM_PY = AGENTS / "common" / "llm.py"
AGENT_MANIFESTS = [REPO / "deploy" / "agents" / f"{a}.yaml"
                   for a in ("supervisor", "mapper", "allocator", "deployer")]

# The one fixture the shell half shares (AD-67): embedded userinfo in the base URL.
FIXTURE_BASE_URL = "https://user:s3cret@gateway.example/v1"
FIXTURE_API_KEY = "sk-test-0123456789abcdefghijklmn"
GATEWAY = "corp-gateway"

XFAIL_REASON = (
    "passes with T080/T087 (AD-50): agents/common/llm.py / deploy/agents/*.yaml not built yet"
)

needs_llm = pytest.mark.xfail(condition=not LLM_PY.exists(), reason=XFAIL_REASON, strict=True)


def _needs_manifest(path: Path) -> pytest.MarkDecorator:
    return pytest.mark.xfail(condition=not path.exists(), reason=XFAIL_REASON, strict=True)


# --------------------------------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------------------------------


def _write_secret(directory: Path, **keys: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    for key, value in keys.items():
        (directory / key).write_text(value)
    return directory


@pytest.fixture
def llm() -> Any:
    return importlib.import_module("common.llm")


class RecordingTransport:
    """A fake model transport that records the host of every call and never touches a network."""

    def __init__(self) -> None:
        self.hosts: list[str | None] = []

    def __call__(self, *, base_url: str | None, model: str, api_key: str,
                 messages: list[dict[str, Any]]) -> dict[str, Any]:
        self.hosts.append(urlsplit(base_url).hostname if base_url else None)
        return {"choices": [{"message": {"role": "assistant", "content": "ok"}}]}


@pytest.fixture
def dials(monkeypatch: pytest.MonkeyPatch) -> Iterator[list[Any]]:
    """Record — and refuse — every socket connection, so a library default is never dialled."""
    attempts: list[Any] = []

    def refuse_connect(self: socket.socket, address: Any) -> None:
        attempts.append(address)
        raise OSError(f"test forbids network access: {address!r}")

    def refuse_create(address: Any, *args: Any, **kwargs: Any) -> socket.socket:
        attempts.append(address)
        raise OSError(f"test forbids network access: {address!r}")

    monkeypatch.setattr(socket.socket, "connect", refuse_connect)
    monkeypatch.setattr(socket.socket, "connect_ex", refuse_connect)
    monkeypatch.setattr(socket, "create_connection", refuse_create)
    yield attempts


# --------------------------------------------------------------------------------------------------
# (a) a declared gateway without a base URL refuses to start
# --------------------------------------------------------------------------------------------------


@needs_llm
@pytest.mark.parametrize("base_url", [None, "", "\n"])
def test_gateway_without_base_url_refuses_to_start(
    llm: Any, tmp_path: Path, base_url: str | None, dials: list[Any]
) -> None:
    keys = {"LLM_MODEL": "openai/gpt-4o", "API_KEY": FIXTURE_API_KEY, "GATEWAY": GATEWAY}
    if base_url is not None:
        keys["BASE_URL"] = base_url
    secret = _write_secret(tmp_path / "llm-provider", **keys)
    transport = RecordingTransport()

    with pytest.raises(llm.EndpointError, match=GATEWAY):
        llm.load_endpoint(secret)
    with pytest.raises(llm.EndpointError, match=GATEWAY):
        llm.LLMClient(secret, transport=transport)
    assert transport.hosts == []
    assert dials == []


# --------------------------------------------------------------------------------------------------
# (b) start-up names the effective endpoint, redacted of credentials
# --------------------------------------------------------------------------------------------------


@needs_llm
def test_startup_logs_the_effective_endpoint_redacted(
    llm: Any, tmp_path: Path, caplog: pytest.LogCaptureFixture,
    capsys: pytest.CaptureFixture[str], dials: list[Any],
) -> None:
    secret = _write_secret(
        tmp_path / "llm-provider",
        LLM_MODEL="openai/gpt-4o", API_KEY=FIXTURE_API_KEY, BASE_URL=FIXTURE_BASE_URL,
        GATEWAY=GATEWAY,
    )
    with caplog.at_level(logging.DEBUG):
        llm.LLMClient(secret, transport=RecordingTransport())
    captured = capsys.readouterr()
    output = "\n".join([caplog.text, captured.out, captured.err])

    naming = [line for line in output.splitlines() if "gateway.example" in line]
    assert naming, f"no start-up line names the endpoint host; got:\n{output}"
    for line in naming:
        assert "s3cret" not in line and "user:" not in line, line
    assert "s3cret" not in output
    assert FIXTURE_API_KEY not in output
    assert dials == []


@needs_llm
def test_startup_states_the_provider_default_as_such(
    llm: Any, tmp_path: Path, caplog: pytest.LogCaptureFixture,
    capsys: pytest.CaptureFixture[str],
) -> None:
    secret = _write_secret(
        tmp_path / "llm-provider", LLM_MODEL="openai/gpt-4o", API_KEY=FIXTURE_API_KEY
    )
    with caplog.at_level(logging.DEBUG):
        llm.LLMClient(secret, transport=RecordingTransport())
    captured = capsys.readouterr()
    output = "\n".join([caplog.text, captured.out, captured.err]).lower()
    assert "default" in output, "start-up must state that the provider's own default is in use"
    assert FIXTURE_API_KEY.lower() not in output


# --------------------------------------------------------------------------------------------------
# (c) the running agent whose Secret loses its base URL (AD-49)
# --------------------------------------------------------------------------------------------------


@needs_llm
@pytest.mark.parametrize("gateway", [None, GATEWAY], ids=["no-gateway", "gateway"])
def test_running_agent_that_loses_its_base_url_stops_calling_the_model(
    llm: Any, tmp_path: Path, gateway: str | None, dials: list[Any]
) -> None:
    keys = {"LLM_MODEL": "openai/gpt-4o", "API_KEY": FIXTURE_API_KEY,
            "BASE_URL": FIXTURE_BASE_URL}
    if gateway:
        keys["GATEWAY"] = gateway
    secret = _write_secret(tmp_path / "llm-provider", **keys)
    transport = RecordingTransport()
    client = llm.LLMClient(secret, transport=transport)

    client.complete([{"role": "user", "content": "hello"}])
    assert transport.hosts == ["gateway.example"]

    (secret / "BASE_URL").unlink()  # the mounted Secret loses its base URL while running

    with pytest.raises(llm.EndpointError, match="BASE_URL"):
        client.complete([{"role": "user", "content": "hello again"}])
    # The next model call was not made, and nothing — least of all the library default — was
    # dialled.
    assert transport.hosts == ["gateway.example"]
    assert dials == []


# --------------------------------------------------------------------------------------------------
# (d) the manifest half (AD-54): llm-provider only as a read-only volume, in every agent
# --------------------------------------------------------------------------------------------------

SECRET = "llm-provider"  # noqa: S105 — the Secret's name, not a credential


def _walk(node: Any) -> Iterator[tuple[str, Any]]:
    if isinstance(node, dict):
        for key, value in node.items():
            yield key, value
            yield from _walk(value)
    elif isinstance(node, list):
        for item in node:
            yield from _walk(item)


def manifest_violations(path: Path) -> list[str]:
    """Every way ``path`` breaks the rule; empty when it mounts llm-provider correctly."""
    name = path.name
    docs = [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]
    problems: list[str] = []

    for key, value in _walk(docs):
        if key == "secretKeyRef" and isinstance(value, dict) and value.get("name") == SECRET:
            problems.append(f"{name}: references {SECRET} through secretKeyRef")
        if key == "envFrom" and isinstance(value, list):
            for source in value:
                ref = (source or {}).get("secretRef") or {}
                if ref.get("name") == SECRET:
                    problems.append(f"{name}: references {SECRET} through envFrom")

    deployments = [d for d in docs if d.get("kind") == "Deployment"]
    if not deployments:
        problems.append(f"{name}: carries no Deployment")
    for deployment in deployments:
        dname = deployment.get("metadata", {}).get("name", "?")
        pod = deployment.get("spec", {}).get("template", {}).get("spec", {})
        volumes = {v.get("name") for v in pod.get("volumes", []) or []
                   if (v.get("secret") or {}).get("secretName") == SECRET}
        if not volumes:
            problems.append(f"{name}: Deployment {dname} has no volume of Secret {SECRET}")
            continue
        mounts = [m for c in (pod.get("containers", []) or []) + (pod.get("initContainers", [])
                  or []) for m in c.get("volumeMounts", []) or [] if m.get("name") in volumes]
        if not mounts:
            problems.append(f"{name}: Deployment {dname} does not mount Secret {SECRET}")
        for mount in mounts:
            if mount.get("readOnly") is not True:
                problems.append(
                    f"{name}: Deployment {dname} mounts {SECRET} at {mount.get('mountPath')} "
                    "without readOnly: true"
                )
    return problems


@pytest.mark.parametrize(
    "manifest",
    [pytest.param(p, marks=_needs_manifest(p), id=p.name) for p in AGENT_MANIFESTS],
)
def test_agent_manifest_mounts_llm_provider_read_only(manifest: Path) -> None:
    assert manifest.exists(), f"{manifest.relative_to(REPO)} does not exist"
    problems = manifest_violations(manifest)
    assert not problems, "\n".join(problems)


# The checker itself, against fixtures — runs today, so the manifest half is not vacuous.

_GOOD = """
apiVersion: apps/v1
kind: Deployment
metadata: {name: mapper}
spec:
  template:
    spec:
      containers:
        - name: mapper
          volumeMounts:
            - {name: llm, mountPath: /var/run/secrets/llm-provider, readOnly: true}
      volumes:
        - name: llm
          secret: {secretName: llm-provider}
"""


@pytest.mark.parametrize(
    ("mutation", "expected"),
    [
        (lambda s: s, None),
        (lambda s: s.replace(", readOnly: true", ""), "without readOnly: true"),
        (lambda s: s.replace("readOnly: true", "readOnly: false"), "without readOnly: true"),
        (lambda s: s.replace("secretName: llm-provider", "secretName: other"), "has no volume"),
        (
            lambda s: s.replace(
                "          volumeMounts:",
                "          envFrom:\n            - secretRef: {name: llm-provider}\n"
                "          volumeMounts:",
            ),
            "through envFrom",
        ),
        (
            lambda s: s.replace(
                "          volumeMounts:",
                "          env:\n            - name: API_KEY\n              valueFrom:\n"
                "                secretKeyRef: {name: llm-provider, key: API_KEY}\n"
                "          volumeMounts:",
            ),
            "through secretKeyRef",
        ),
        (lambda s: s.replace("kind: Deployment", "kind: StatefulSet"), "carries no Deployment"),
    ],
    ids=["good", "no-readonly", "readonly-false", "no-volume", "envfrom", "secretkeyref",
         "no-deployment"],
)
def test_manifest_checker_names_the_file_and_the_violation(
    tmp_path: Path, mutation: Any, expected: str | None
) -> None:
    path = tmp_path / "mapper.yaml"
    path.write_text(mutation(_GOOD))
    problems = manifest_violations(path)
    if expected is None:
        assert problems == []
    else:
        assert problems, "the checker accepted a violating manifest"
        assert all(p.startswith("mapper.yaml: ") for p in problems)
        assert any(expected in p for p in problems), problems


# --------------------------------------------------------------------------------------------------
# the model call's own bound (NFR-010, T146): below the worker call, the library's retries off
# --------------------------------------------------------------------------------------------------


def test_the_model_call_bound_reaches_the_transport(tmp_path: Path) -> None:
    secret = tmp_path / "llm-provider"
    secret.mkdir()
    (secret / "LLM_MODEL").write_text("openai/gpt-4o-mini")
    (secret / "API_KEY").write_text("sk-test")
    (secret / "BASE_URL").write_text("https://gateway.example/v1")
    seen: list[dict[str, Any]] = []

    def transport(**kwargs: Any) -> Any:
        seen.append(kwargs)
        return {"choices": [{"message": {"content": "ok"}}]}

    from common.llm import LLMClient

    LLMClient(secret, transport=transport, timeout=45.0).complete([{"role": "user",
                                                                    "content": "x"}])
    LLMClient(secret, transport=transport).complete([{"role": "user", "content": "x"}])
    assert seen[0]["timeout"] == 45.0
    assert "timeout" not in seen[1]


def test_litellm_is_called_with_the_bound_and_no_retries(monkeypatch: Any) -> None:
    import litellm

    from common.llm import litellm_transport

    seen: dict[str, Any] = {}
    monkeypatch.setattr(litellm, "completion", lambda **kw: seen.update(kw) or "r")
    litellm_transport(base_url="https://gateway.example/v1", model="openai/m", api_key="k",
                      messages=[], timeout=45.0)
    assert (seen["timeout"], seen["max_retries"], seen["num_retries"]) == (45.0, 0, 0)
    assert seen["api_base"] == "https://gateway.example/v1"


def test_the_reasoning_effort_reaches_the_transport_only_when_set(tmp_path: Path) -> None:
    secret = tmp_path / "llm-provider"
    secret.mkdir()
    (secret / "LLM_MODEL").write_text("openai/gpt-5")
    (secret / "API_KEY").write_text("sk-test")
    (secret / "BASE_URL").write_text("https://gateway.example/v1")
    seen: list[dict[str, Any]] = []

    def transport(**kwargs: Any) -> Any:
        seen.append(kwargs)
        return {"choices": [{"message": {"content": "ok"}}]}

    from common.llm import LLMClient

    LLMClient(secret, transport=transport, reasoning_effort="low").complete(
        [{"role": "user", "content": "x"}])
    LLMClient(secret, transport=transport, reasoning_effort="").complete(
        [{"role": "user", "content": "x"}])
    assert seen[0]["reasoning_effort"] == "low"
    assert "reasoning_effort" not in seen[1]


@pytest.mark.parametrize("model,allowed", [("openai/gpt-5", True), ("anthropic/claude", False)])
def test_litellm_is_asked_for_the_effort_and_drops_it_where_unsupported(
        monkeypatch: Any, model: str, allowed: bool) -> None:
    """NFR-008: the setting never makes a provider change more than a change of the Secret — a
    model that takes no reasoning effort has it dropped, never refused."""
    import litellm

    from common.llm import litellm_transport

    seen: dict[str, Any] = {}
    monkeypatch.setattr(litellm, "completion", lambda **kw: seen.update(kw) or "r")
    litellm_transport(base_url=None, model=model, api_key="k", messages=[],
                      reasoning_effort="low")
    assert (seen["reasoning_effort"], seen["drop_params"]) == ("low", True)
    assert ("allowed_openai_params" in seen) is allowed
    seen.clear()
    litellm_transport(base_url=None, model=model, api_key="k", messages=[])
    assert "reasoning_effort" not in seen and "drop_params" not in seen


# (e) every agent's START-UP constructs the model client (FR-106, T168): the allocator and the
# deployer make no model call, yet each logs its effective endpoint and refuses a gateway declared
# without a base URL, like the supervisor and the mapper (T153 r3: only two of four logged it)
@needs_llm
@pytest.mark.parametrize("worker", ["allocator", "deployer"])
def test_worker_startup_logs_endpoint_and_refuses_gateway_without_base_url(
    worker: str, tmp_path: Path, caplog: pytest.LogCaptureFixture, monkeypatch: pytest.MonkeyPatch,
) -> None:
    import dataclasses

    server = importlib.import_module(f"provisioning.{worker}.server")
    if worker == "allocator":
        class _Cfg:
            vlan_pool = vni_pool = "x"
            def describe(self) -> str: return "fake"
        class _Alloc:
            def __init__(self, _s: Any) -> None: pass
            def adapter(self) -> Any: return type("A", (), {"config": _Cfg()})()
            def handle(self, *_a: Any) -> None: return None
        monkeypatch.setattr(server, "Allocator", _Alloc)
    else:
        monkeypatch.setattr(server, "make_handler", lambda _s: (lambda *_a: None))
    settings = importlib.import_module("config.settings").Settings()

    good = _write_secret(tmp_path / "good", LLM_MODEL="openai/gpt-4o", API_KEY=FIXTURE_API_KEY,
                         BASE_URL=FIXTURE_BASE_URL)
    with caplog.at_level(logging.INFO):
        server._handler(dataclasses.replace(settings, llm_provider_dir=good))
    lines = [r.getMessage() for r in caplog.records if "model endpoint" in r.getMessage()]
    assert lines and "gateway.example" in lines[0] and "s3cret" not in caplog.text

    bad = _write_secret(tmp_path / "bad", LLM_MODEL="openai/gpt-4o", API_KEY=FIXTURE_API_KEY,
                        GATEWAY=GATEWAY)
    with pytest.raises(importlib.import_module("common.llm").EndpointError, match=GATEWAY):
        server._handler(dataclasses.replace(settings, llm_provider_dir=bad))
