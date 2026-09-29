"""T146 — the intent tier degrades legibly: every lost dependency is reported naming ITSELF
(NFR-010, AD-52; spec.md §Edge cases "Intent tier"; data-model.md §17, §25;
contracts/supervisor-http.md — the ``error`` chunk of the dependency-failure class).

Each case injects one fault into the RUNNING lab, drives one operator turn through the supervisor's
HTTP surface, and asserts from the ``error``/``final`` chunks alone that the failure names the
dependency that was actually lost — and that no OTHER dependency is blamed and no generic
"internal error" stands in for it:

======================= ==========================================================================
case                    fault (every one put back in a ``finally`` and the restoration read back)
======================= ==========================================================================
tier prompt bound       a prompt past the supervisor's own 8000-character bound (the tier-side form
                        of a context-window overflow): refused 400 naming the prompt, no thread,
                        no model call
provider unreachable    ``llm-provider`` Secret ``BASE_URL`` merge-patched to a name that does not
                        resolve (``.invalid``); a create request (mapper's model call) and an
                        informational one (the supervisor's own model call)
provider rate-limited   ``BASE_URL`` → the scratch fake provider answering 429
provider timeout        ``BASE_URL`` → the fake holding every call past the worker call timeout
schema-invalid output   ``BASE_URL`` → the fake answering 200 with prose, every time: the mapper's
                        one corrective retry is spent (exactly two model calls)
context-window overflow ``BASE_URL`` → the fake answering OpenAI's ``context_length_exceeded``
transport down          ``slim`` scaled to zero
stale worker descriptor the ``agent-cards`` ConfigMap's mapper card re-pointed at a topic no worker
                        registers (the card is read at call time — ``TransportClient.resolve`` —
                        so the stale descriptor is live without a supervisor restart, and so is
                        its repair)
cluster API unavailable ``agentic-netops-system/srl-provider`` scaled to zero after both
                        confirmations: the fail-closed admission webhook
                        (``networks.fabric.agentic-netops.io``) is unreachable, the deployer's
                        server-side dry-run fails → the cluster API dependency naming the admission
                        webhook, nothing applied, the claims still provisional, the thread resumed
                        after the restore and the service removed through the tier (AD-52)
======================= ==========================================================================

Before/after: the ``Network`` set in ``agentic-netops-intent`` and the claim set are identical
around every fault (the cluster case: identical around the fault, and back to the start after the
resumed service is removed). Every case writes its chunks and read-backs through ``record()``
under ``$EVIDENCE_DIR/t089/t146-*.json`` — before its assertions, so a red case is evidence too.

The fake provider (cases rate-limit, timeout, schema-invalid, overflow) is a Pod in the scratch
namespace ``vt-scratch-t146-degradation``, labelled ``agentic-netops.io/gate-owned=true`` so
``leftovers::scan`` (T043) refuses the next gate while an interrupted run leaves it behind. It runs
the mapper's own locally built image (never pulled) with a stdlib HTTP server that reads the
request body and drops it and logs nothing — the provider API key the agents send as a bearer
token is never written anywhere. The tier's ``allow-egress-scoped`` policy drops the pod CIDR, so
the one opening this suite makes is an ADDITIVE NetworkPolicy
``vt-scratch-t146-fake-provider-egress`` in ``agentic-netops-agents`` — mapper and supervisor pods
to that namespace on TCP 8080 only, labelled gate-owned — deleted with the namespace and read back
absent; no existing policy is edited.

Run through ``tests/e2e/degradation_e2e.sh`` (``leftovers::scan`` first, then ``evidence_run``).
"""

from __future__ import annotations

import base64
import contextlib
import json
import re
import subprocess
from collections.abc import Iterator
from typing import Any

import pytest
from conftest import (
    AGENTS_NS,
    CONTEXT,
    INTENT_NS,
    WORKERS,
    claim_names,
    http,
    kjson,
    kubectl,
    model_call_count,
    network_names,
    pod_forward,
    record,
    restart_count,
    supervisor_pod,
    thread_count,
    wait_for,
)
from tierflow import (
    Turn,
    claims_of,
    confirm_interpretation,
    network,
    operator_login,
    remove,
    request_to_confirmation,
    wait_gone,
)

FABRIC_NS = "agentic-netops-system"
PROVIDER = "srl-provider"
WEBHOOK_SERVICE = "srl-provider-webhook"
WEBHOOK_NAME = "networks.fabric.agentic-netops.io"  # provisioning/deployer/kube.py WEBHOOK_NAME
LLM_SECRET = "llm-provider"  # noqa: S105 — the Secret's name, not a credential
LLM_MOUNT = "/var/run/secrets/agentic-netops/llm-provider"
CARDS_CONFIGMAP = "agent-cards"
CARDS_MOUNT = "/etc/agentic-netops/agent-cards"
MAPPER_CARD = "mapper.json"
# the workloads that mount llm-provider and call a model (deploy/agents/{supervisor,mapper}.yaml)
MODEL_CALLERS = ("mapper", "supervisor")

GATE_LABEL = {"agentic-netops.io/gate-owned": "true"}  # tests/lib/lab.sh LAB_GATE_SELECTOR
SCRATCH_NS = "vt-scratch-t146-degradation"
FAKE_NAME = "vt-scratch-t146-fake-provider"
FAKE_POLICY = "vt-scratch-t146-fake-provider-egress"
FAKE_PORT = 8080
# unroutable by construction: the .invalid TLD never resolves (RFC 6761)
UNREACHABLE_BASE_URL = "http://vt-scratch-t146-llm-provider.invalid/v1"
# past WORKER_CALL_TIMEOUT_SECONDS x (1 + WORKER_CALL_RETRIES) + backoff = 60 x 3 + 3 s (§25)
FAKE_HOLD_SECONDS = 420
TIER_PROMPT_BOUND = 8000  # supervisors/provisioning/main.py PromptRequest.prompt max_length

# One request per case, each on a VLAN no other suite of the lab holds (the model cases never get
# past interpretation, so they claim nothing).
MODEL_PROMPT = "Create a vlan for tenant acme on leaf02 ethernet-1/1 with VLAN 125"
INFO_PROMPT = "What constructs can I ask for?"
TRANSPORT_PROMPT = "Create a vlan for tenant acme on leaf02 ethernet-1/1 with VLAN 124"
STALE_PROMPT = "Create a vlan for tenant acme on leaf02 ethernet-1/1 with VLAN 126"
# a mac-vrf with no VLAN named: the allocator claims a VLAN and an L2VNI before the second
# confirmation, so "the claims still provisional, exactly as they were" has claims to hold (a
# named-band vlan claims nothing, and the check would be vacuous)
CLUSTER_PROMPT = "Create a mac-vrf for tenant acme on leaf01 ethernet-1/1 and leaf02 ethernet-1/1"

# --------------------------------------------------------------------------------------------------
# the dependency vocabulary: what "names the model provider / the transport / the cluster API" is
# --------------------------------------------------------------------------------------------------

DEPENDENCIES: dict[str, re.Pattern[str]] = {
    "model provider": re.compile(
        r"\bmodel (?:call|endpoint|provider|output|answer)\b|\bllm-provider\b|\bBASE_URL\b"
        r"|\blitellm\b|context.?(?:window|length)|rate.?limit", re.IGNORECASE),
    "transport": re.compile(r"\btransport\b|\bSLIM\b", re.IGNORECASE),
    "cluster API": re.compile(r"\bcluster API\b|\badmission webhook\b", re.IGNORECASE),
    "worker": re.compile(r"\bworker unreachable\b", re.IGNORECASE),
}
# the supervisor's catch-all (supervisors/provisioning/graph/graph.py) — anchored, so the API
# server's own "Internal error occurred: failed calling webhook" inside a named failure is not it
GENERIC = re.compile(r"(?m)^internal error: \w+\s*$|failed inside the supervisor",
                     re.IGNORECASE)


def failure_text(chunks: list[dict[str, Any]]) -> str:
    """What the operator is told went wrong: the ``reason``/``message`` of every ``error`` and
    ``final`` chunk — never a stage payload, which may quote any word."""
    return "\n".join(str(c[k]) for c in chunks if c.get("type") in ("error", "final")
                     for k in ("reason", "message") if c.get(k))


def assert_names(own: str, text: str, *, forbid: tuple[str, ...], also: str | None = None) -> None:
    """``text`` names dependency ``own`` (and matches ``also`` when given), blames none of
    ``forbid`` and is not the generic failure. The degradation cases' single judgement — the
    driver's negative control runs it over a generic failure and must see it fail."""
    assert text.strip(), "no error or final chunk said anything"
    assert DEPENDENCIES[own].search(text), f"the failure does not name the {own}:\n{text}"
    if also is not None:
        assert re.search(also, text, re.IGNORECASE), f"the failure lacks /{also}/:\n{text}"
    blamed = [d for d in forbid if DEPENDENCIES[d].search(text)]
    assert not blamed, f"the {own} failure blames {blamed} instead:\n{text}"
    assert not GENERIC.search(text), f"a generic failure stands in for the {own}:\n{text}"


# --------------------------------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------------------------------


def snapshot() -> dict[str, list[str]]:
    return {"networks": sorted(network_names(INTENT_NS)), "claims": sorted(claim_names())}


def turn(prompt: str, thread_id: str | None = None, *, base: str | None = None,
         timeout: float = 600) -> tuple[int, list[dict[str, Any]], str | None]:
    """One operator turn, tolerant of a stream the server broke off: ``(status, chunks, broken)``
    where ``broken`` names what cut the stream short (a failure the operator would see as a
    generic one — asserted against by the caller)."""
    body: dict[str, Any] = {"prompt": prompt}
    if thread_id:
        body["thread_id"] = thread_id
    try:
        resp = http("POST", "/agent/prompt/stream", auth=operator_login(), body=body,
                    timeout=timeout, base=base)
    except Exception as exc:  # an IncompleteRead, a reset: the stream did not end in a chunk
        return 0, [], f"{type(exc).__name__}: {exc}"
    try:
        return resp.status, resp.chunks(), None
    except ValueError as exc:
        return resp.status, [], f"unparseable stream: {exc}: {resp.body[:400]!r}"


def running_pod(name: str, namespace: str = AGENTS_NS) -> str:
    pods = kjson("-n", namespace, "get", "pods", "-l", f"app.kubernetes.io/name={name}")["items"]
    live = [p["metadata"]["name"] for p in pods
            if not p["metadata"].get("deletionTimestamp") and p["status"].get("phase") == "Running"]
    assert live, f"no running {name} pod in {namespace}"
    return live[0]


def mounted(component: str, path: str) -> str | None:
    """The file ``path`` as the running ``component`` container sees it now (None: unreadable)."""
    try:
        return kubectl("-n", AGENTS_NS, "exec", running_pod(component), "-c", component, "--",
                       "cat", path, timeout=60)
    except AssertionError:
        return None


def kapply(doc: dict[str, Any]) -> None:
    proc = subprocess.run(["kubectl", "--context", CONTEXT, "apply", "-f", "-"],  # noqa: S603, S607
                          input=json.dumps(doc), capture_output=True, text=True, timeout=120)
    assert proc.returncode == 0, f"kubectl apply failed: {proc.stderr.strip()}"


def kpatch(namespace: str, kind: str, name: str, patch: dict[str, Any]) -> None:
    kubectl("-n", namespace, "patch", kind, name, "--type", "merge", "-p", json.dumps(patch))


def scale(namespace: str, name: str, replicas: int) -> None:
    kubectl("-n", namespace, "scale", f"deployment/{name}", f"--replicas={replicas}")
    if replicas:
        kubectl("-n", namespace, "rollout", "status", f"deployment/{name}", "--timeout=300s",
                timeout=320)
    else:
        wait_for(f"{namespace}/{name} at zero", lambda: not kjson(
            "-n", namespace, "get", "pods", "-l", f"app.kubernetes.io/name={name}")["items"],
                 timeout=180)


def replicas(namespace: str, name: str) -> int:
    return int(kjson("-n", namespace, "get", "deployment", name)["spec"].get("replicas", 1))


def deep_health(base: str | None = None) -> tuple[int, dict[str, Any]]:
    try:
        resp = http("GET", "/v1/health", base=base, timeout=30)
    except OSError as exc:
        return 0, {"error": str(exc)}
    try:
        return resp.status, resp.json()
    except ValueError:
        return resp.status, {"raw": resp.body[:400].decode(errors="replace")}


def all_ok(base: str | None) -> bool:
    status, body = deep_health(base)
    return status == 200 and body.get("workers") == {w: "ok" for w in WORKERS}


def errors_of(chunks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [c for c in chunks if c.get("type") == "error"]


def thread_of(chunks: list[dict[str, Any]]) -> str | None:
    return next((c["thread_id"] for c in chunks if c.get("thread_id")), None)


def correlation_of(chunks: list[dict[str, Any]]) -> str | None:
    return next((c["correlation_id"] for c in chunks if c.get("correlation_id")), None)


def decline_if_asked(thread_id: str, chunks: list[dict[str, Any]],
                     base: str | None = None) -> list[dict[str, Any]]:
    """Leave nothing behind: a pending first confirmation is declined (nothing was claimed)."""
    if any(c.get("type") == "confirmation_request" for c in chunks):
        _status, declined, _broken = turn("no", thread_id, base=base)
        return declined
    return []


# --------------------------------------------------------------------------------------------------
# the model provider: BASE_URL of the mounted llm-provider Secret, re-read on every call (FR-106)
# --------------------------------------------------------------------------------------------------


def _b64(value: str) -> str:
    return base64.b64encode(value.encode()).decode()


def _mounted_base_urls() -> dict[str, str | None]:
    return {c: (mounted(c, f"{LLM_MOUNT}/BASE_URL") or "").strip() or None
            for c in MODEL_CALLERS}


@contextlib.contextmanager
def provider_base_url(url: str, case: str) -> Iterator[None]:
    """``BASE_URL`` of the ``llm-provider`` Secret set to ``url`` by merge patch — that one key,
    nothing else — for the ``with`` body, and the original bytes put back and read back (the
    Secret object and the file in every model-calling container) whatever happened."""
    original_b64 = kjson("-n", AGENTS_NS, "get", "secret", LLM_SECRET)["data"].get("BASE_URL")
    assert original_b64, "the llm-provider Secret carries no BASE_URL to degrade"
    original = base64.b64decode(original_b64).decode().strip()
    restored: dict[str, Any] = {}
    try:
        kpatch(AGENTS_NS, "secret", LLM_SECRET, {"data": {"BASE_URL": _b64(url)}})
        # the kubelet refreshes a Secret volume on its sync period (~60 s): the fault is live only
        # once every model-calling container reads the new value
        wait_for(f"BASE_URL={url} mounted in {MODEL_CALLERS}",
                 lambda: set(_mounted_base_urls().values()) == {url}, timeout=240, every=5)
        yield
    finally:
        kpatch(AGENTS_NS, "secret", LLM_SECRET, {"data": {"BASE_URL": original_b64}})
        secret_back = kjson("-n", AGENTS_NS, "get", "secret", LLM_SECRET)["data"].get("BASE_URL")
        wait_for("the original BASE_URL mounted again",
                 lambda: set(_mounted_base_urls().values()) == {original}, timeout=240, every=5)
        restored = {"secret_bytes_equal": secret_back == original_b64,
                    "mounted_equal": set(_mounted_base_urls().values()) == {original}}
        record(f"t146-{case}-restore", {"fault": f"llm-provider BASE_URL -> {url}",
                                        **restored})
        assert restored["secret_bytes_equal"] and restored["mounted_equal"], restored


# The fake provider: an OpenAI-compatible endpoint whose first path segment selects the failure.
# It reads and drops each request body, keeps a per-mode hit count and logs nothing (no header —
# the provider key arrives as a bearer token — and no prompt is ever written).
FAKE_SERVER = r"""
import json, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOLD = __HOLD__
HITS = {}
LOCK = threading.Lock()
PROSE = ("I would rather describe that service in prose than as JSON: it is a VLAN for tenant "
         "acme. (vt-scratch-t146: deliberately schema-invalid)")


def completion(path):
    if path.rstrip("/").endswith("/responses"):
        return {"id": "resp-vt-scratch-t146", "object": "response", "status": "completed",
                "model": "vt-scratch-t146", "output": [{"type": "message", "role": "assistant",
                "id": "msg-vt", "status": "completed",
                "content": [{"type": "output_text", "text": PROSE, "annotations": []}]}],
                "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}
    return {"id": "chatcmpl-vt-scratch-t146", "object": "chat.completion", "created": 0,
            "model": "vt-scratch-t146", "choices": [{"index": 0, "finish_reason": "stop",
            "message": {"role": "assistant", "content": PROSE}}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}


class Fake(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, code, body, headers=()):
        data = json.dumps(body).encode()
        try:
            self.send_response(code)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            for key, value in headers:
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(data)
        except OSError:
            pass

    def do_GET(self):
        if self.path == "/healthz":
            return self.send(200, {"ok": True})
        if self.path == "/stats":
            with LOCK:
                return self.send(200, dict(HITS))
        return self.send(404, {"error": {"message": "not found"}})

    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        mode = self.path.strip("/").split("/", 1)[0]
        with LOCK:
            HITS[mode] = HITS.get(mode, 0) + 1
        if mode == "ratelimit":
            return self.send(429, {"error": {"message": "Rate limit reached for requests "
                                             "(vt-scratch-t146 fake provider)",
                                             "type": "requests", "param": None,
                                             "code": "rate_limit_exceeded"}},
                             [("retry-after", "1")])
        if mode == "timeout":
            time.sleep(HOLD)
            return self.send(504, {"error": {"message": "held past the caller's timeout"}})
        if mode == "overflow":
            return self.send(400, {"error": {
                "message": "This model's maximum context length is 8192 tokens. However, your "
                           "messages resulted in 200000 tokens. Please reduce the length of the "
                           "messages.",
                "type": "invalid_request_error", "param": "messages",
                "code": "context_length_exceeded"}})
        if mode == "invalid":
            return self.send(200, completion(self.path))
        return self.send(404, {"error": {"message": "unknown mode " + mode}})


ThreadingHTTPServer(("0.0.0.0", __PORT__), Fake).serve_forever()
""".replace("__HOLD__", str(FAKE_HOLD_SECONDS)).replace("__PORT__", str(FAKE_PORT))


def _fake_documents(image: str) -> list[dict[str, Any]]:
    labels = {**GATE_LABEL, "app.kubernetes.io/name": FAKE_NAME}
    return [
        {"apiVersion": "v1", "kind": "Namespace",
         "metadata": {"name": SCRATCH_NS, "labels": GATE_LABEL}},
        {"apiVersion": "v1", "kind": "Pod",
         "metadata": {"name": FAKE_NAME, "namespace": SCRATCH_NS, "labels": labels},
         "spec": {
             "automountServiceAccountToken": False,
             "securityContext": {"runAsNonRoot": True, "runAsUser": 10001, "runAsGroup": 10001,
                                 "seccompProfile": {"type": "RuntimeDefault"}},
             "containers": [{
                 "name": "fake", "image": image, "imagePullPolicy": "Never",
                 "command": ["python", "-c", FAKE_SERVER],
                 "ports": [{"containerPort": FAKE_PORT, "name": "http"}],
                 "readinessProbe": {"httpGet": {"path": "/healthz", "port": FAKE_PORT},
                                    "periodSeconds": 2},
                 "resources": {"requests": {"cpu": "10m", "memory": "32Mi"},
                               "limits": {"cpu": "200m", "memory": "128Mi"}},
                 "securityContext": {"allowPrivilegeEscalation": False,
                                     "readOnlyRootFilesystem": True,
                                     "capabilities": {"drop": ["ALL"]}}}]}},
        {"apiVersion": "v1", "kind": "Service",
         "metadata": {"name": FAKE_NAME, "namespace": SCRATCH_NS, "labels": labels},
         "spec": {"selector": {"app.kubernetes.io/name": FAKE_NAME},
                  "ports": [{"name": "http", "port": FAKE_PORT, "targetPort": FAKE_PORT}]}},
        # additive: opens the model callers to the scratch namespace on 8080 and nothing else
        {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
         "metadata": {"name": FAKE_POLICY, "namespace": AGENTS_NS, "labels": GATE_LABEL},
         "spec": {"podSelector": {"matchExpressions": [{"key": "app.kubernetes.io/name",
                                                        "operator": "In",
                                                        "values": list(MODEL_CALLERS)}]},
                  "policyTypes": ["Egress"],
                  "egress": [{"to": [{"namespaceSelector": {"matchLabels": {
                      "kubernetes.io/metadata.name": SCRATCH_NS}}}],
                              "ports": [{"protocol": "TCP", "port": FAKE_PORT}]}]}},
    ]


def fake_url(mode: str) -> str:
    return f"http://{FAKE_NAME}.{SCRATCH_NS}.svc:{FAKE_PORT}/{mode}/v1"


def fake_hits() -> dict[str, int]:
    raw = kubectl("get", "--raw", f"/api/v1/namespaces/{SCRATCH_NS}/services/"
                  f"{FAKE_NAME}:{FAKE_PORT}/proxy/stats")
    return json.loads(raw or "{}")


def _reaches_fake(component: str) -> bool:
    script = ("import urllib.request,sys;"
              f"sys.exit(0 if urllib.request.urlopen('http://{FAKE_NAME}.{SCRATCH_NS}.svc:"
              f"{FAKE_PORT}/healthz',timeout=5).status==200 else 1)")
    try:
        kubectl("-n", AGENTS_NS, "exec", running_pod(component), "-c", component, "--",
                "python", "-c", script, timeout=60)
        return True
    except AssertionError:
        return False


@pytest.fixture(scope="module")
def fake_provider() -> Iterator[None]:
    """The scratch fake provider, reachable from both model callers — then gone, read back."""
    image = kjson("-n", AGENTS_NS, "get", "deployment", "mapper")["spec"]["template"]["spec"][
        "containers"][0]["image"]
    try:
        for doc in _fake_documents(image):
            kapply(doc)
        kubectl("-n", SCRATCH_NS, "wait", f"pod/{FAKE_NAME}", "--for=condition=Ready",
                "--timeout=180s", timeout=200)
        wait_for("the fake provider reachable from mapper and supervisor",
                 lambda: all(_reaches_fake(c) for c in MODEL_CALLERS), timeout=120, every=5)
        yield
    finally:
        kubectl("-n", AGENTS_NS, "delete", "networkpolicy", FAKE_POLICY, "--ignore-not-found")
        kubectl("delete", "namespace", SCRATCH_NS, "--ignore-not-found", "--wait=true",
                "--timeout=180s", timeout=200)
        left = {
            "networkpolicy": kubectl("-n", AGENTS_NS, "get", "networkpolicy", FAKE_POLICY,
                                     "--ignore-not-found", "-o", "name").strip(),
            "namespace": kubectl("get", "namespace", SCRATCH_NS, "--ignore-not-found", "-o",
                                 "name").strip(),
        }
        record("t146-fake-provider-removed", {"image": image, "left": left})
        assert left == {"networkpolicy": "", "namespace": ""}, f"scratch left behind: {left}"


def model_case(case: str, url: str, *, also: str, mode: str | None = None,
               expect_hits: int | None = None) -> None:
    """One model-provider fault around one create request: the mapper's model call fails."""
    before = snapshot()
    hits_before = fake_hits() if mode else {}
    with provider_base_url(url, case):
        status, chunks, broken = turn(MODEL_PROMPT)
        hits = fake_hits() if mode else {}
    after = snapshot()
    text = failure_text(chunks)
    calls = (hits.get(mode, 0) - hits_before.get(mode, 0)) if mode else None
    record(f"t146-{case}", {"fault": url, "status": status, "broken": broken, "chunks": chunks,
                            "failure_text": text, "fake_provider_calls": calls,
                            "before": before, "after": after})
    assert status == 200 and broken is None, f"stream {status} broken={broken}"
    assert errors_of(chunks), f"no error chunk:\n{json.dumps(chunks, indent=1)}"
    assert all(e.get("stage") == "mapper" for e in errors_of(chunks)), errors_of(chunks)
    assert_names("model provider", text, forbid=("transport", "cluster API", "worker"),
                 also=also)
    if mode:
        assert calls, f"the fake provider saw no {mode} call: the fault was never exercised"
    if expect_hits is not None:
        assert calls == expect_hits, f"{calls} model calls, expected {expect_hits}"
    assert after == before, "a model-provider failure changed the Network or claim set"


# --------------------------------------------------------------------------------------------------
# 8a — the tier's own bound on what reaches a model
# --------------------------------------------------------------------------------------------------


def test_prompt_past_the_tier_bound_is_refused_naming_the_prompt() -> None:
    before, threads, calls = snapshot(), thread_count(), model_call_count()
    status, chunks, broken = turn("Create a vlan for tenant acme. " +
                                  "x" * (TIER_PROMPT_BOUND + 1))
    text = "\n".join(str(c.get("reason", "")) for c in chunks)
    after = {"threads": thread_count(), "model_calls": model_call_count(), **snapshot()}
    record("t146-tier-prompt-bound", {"status": status, "broken": broken, "chunks": chunks,
                                      "before": {"threads": threads, "model_calls": calls,
                                                 **before}, "after": after})
    assert status == 400 and broken is None, (status, broken, chunks)
    assert re.search(r"\bprompt\b", text) and str(TIER_PROMPT_BOUND) in text, text
    blamed = [d for d, rx in DEPENDENCIES.items() if rx.search(text)]
    assert not blamed, f"the tier's own bound blamed {blamed}: {text}"
    assert after == {"threads": threads, "model_calls": calls, **before}


# --------------------------------------------------------------------------------------------------
# 1-4, 8b — the model provider
# --------------------------------------------------------------------------------------------------


def test_model_provider_unreachable_is_named() -> None:
    model_case("provider-unreachable", UNREACHABLE_BASE_URL,
               also=r"connect|unreachable|resolve|name or service|APIConnectionError")


def test_model_provider_unreachable_is_named_on_an_informational_turn() -> None:
    """The supervisor's own model call (the informational answer) — no stage, no claim."""
    before = snapshot()
    with provider_base_url(UNREACHABLE_BASE_URL, "provider-unreachable-informational"):
        status, chunks, broken = turn(INFO_PROMPT)
    text = failure_text(chunks)
    record("t146-provider-unreachable-informational", {
        "fault": UNREACHABLE_BASE_URL, "status": status, "broken": broken, "chunks": chunks,
        "failure_text": text, "before": before, "after": snapshot()})
    assert status == 200 and broken is None, f"stream {status} broken={broken}"
    assert errors_of(chunks), f"no error chunk:\n{json.dumps(chunks, indent=1)}"
    assert_names("model provider", text, forbid=("transport", "cluster API", "worker"))
    assert snapshot() == before


def test_model_provider_rate_limit_is_named(fake_provider) -> None:
    model_case("provider-rate-limited", fake_url("ratelimit"), mode="ratelimit",
               also=r"rate.?limit|\b429\b")


def test_model_provider_timeout_is_named(fake_provider) -> None:
    model_case("provider-timeout", fake_url("timeout"), mode="timeout",
               also=r"time[sd]?.?out|timed out")


def test_repeated_schema_invalid_model_output_is_named(fake_provider) -> None:
    # exactly the first answer and the one corrective retry (provisioning/mapper/agent.py)
    model_case("schema-invalid-output", fake_url("invalid"), mode="invalid", expect_hits=2,
               also=r"schema-invalid model output")


def test_model_context_window_overflow_is_named(fake_provider) -> None:
    model_case("context-window-overflow", fake_url("overflow"), mode="overflow",
               also=r"context.?(?:window|length)")


# --------------------------------------------------------------------------------------------------
# 5 — the transport
# --------------------------------------------------------------------------------------------------


@pytest.fixture
def forward() -> Iterator[tuple[dict[str, Any], str]]:
    """The supervisor pod and a port-forward straight to it: a lost worker or transport takes the
    supervisor NotReady and out of its Service, so the turn is sent to the pod itself."""
    pod = supervisor_pod()
    with pod_forward(pod["metadata"]["name"]) as base:
        yield pod, base


def _restore_transport(base: str) -> dict[str, Any]:
    """slim back to its replica count; the tier must re-join unaided. When it does not, the lab is
    restored by restarting the agents — recorded, and the test still fails on it."""
    scale(AGENTS_NS, "slim", 1)
    try:
        wait_for("every worker ok again after the transport returned",
                 lambda: all_ok(base), timeout=300, every=5)
        return {"rejoined_unaided": True}
    except AssertionError:
        pass
    for name in (*WORKERS, "supervisor"):
        kubectl("-n", AGENTS_NS, "rollout", "restart", f"deployment/{name}")
    for name in (*WORKERS, "supervisor"):
        kubectl("-n", AGENTS_NS, "rollout", "status", f"deployment/{name}", "--timeout=300s",
                timeout=320)
    wait_for("every worker ok after the agents' restart", lambda: all_ok(None), timeout=300)
    return {"rejoined_unaided": False, "restored_by": "rollout restart of the agents"}


def test_transport_down_is_named(forward) -> None:
    pod, base = forward
    pod_name, restarts = pod["metadata"]["name"], restart_count(pod)
    assert replicas(AGENTS_NS, "slim") == 1
    before = snapshot()
    restore: dict[str, Any] = {}
    health: tuple[int, dict[str, Any]] = (0, {})
    try:
        scale(AGENTS_NS, "slim", 0)
        wait_for("/v1/health degraded", lambda: deep_health(base)[0] == 503, timeout=180)
        health = deep_health(base)
        status, chunks, broken = turn(TRANSPORT_PROMPT, base=base)
        during = snapshot()
    finally:
        restore = _restore_transport(base)
        restore["slim_replicas"] = replicas(AGENTS_NS, "slim")
    text = failure_text(chunks)
    thread = thread_of(chunks)
    resumed: list[dict[str, Any]] = []
    declined: list[dict[str, Any]] = []
    if thread and restore["rejoined_unaided"]:
        _s, resumed, _b = turn("continue", thread, base=base)
        declined = decline_if_asked(thread, resumed, base)
    now = supervisor_pod()
    record("t146-transport-down", {
        "fault": "deployment/slim scaled to 0", "deep_health": health, "status": status,
        "broken": broken, "chunks": chunks, "failure_text": text, "restore": restore,
        "resumed": resumed, "declined": declined, "before": before, "during": during,
        "after": snapshot(), "supervisor": {"pod": pod_name, "restarts": restarts,
                                            "now": now["metadata"]["name"],
                                            "now_restarts": restart_count(now)}})
    assert status == 200 and broken is None, f"stream {status} broken={broken}"
    assert errors_of(chunks) and all(e.get("retryable") is True for e in errors_of(chunks)), \
        chunks
    assert_names("transport", text, forbid=("model provider", "cluster API"))
    assert during == before, "a transport failure changed the Network or claim set"
    assert restore["rejoined_unaided"], f"the tier did not re-join the transport: {restore}"
    assert now["metadata"]["name"] == pod_name and restart_count(now) == restarts
    assert {c.get("thread_id") for c in resumed} == {thread}, "the thread did not resume"
    assert not DEPENDENCIES["transport"].search(failure_text(resumed)), resumed
    assert snapshot() == before


# --------------------------------------------------------------------------------------------------
# 7 — a stale worker descriptor
# --------------------------------------------------------------------------------------------------


@contextlib.contextmanager
def stale_mapper_card() -> Iterator[str]:
    """The mapper's card in the agent-cards ConfigMap re-pointed at a topic no worker registers
    (the worker itself untouched: it registers under its own id), then the original bytes back and
    read back in the ConfigMap and in the supervisor's mount."""
    original = kjson("-n", AGENTS_NS, "get", "configmap", CARDS_CONFIGMAP)["data"][MAPPER_CARD]
    card = json.loads(original)
    stale_id = card["id"] + "-vt-scratch-t146-stale"
    stale = json.dumps({**card, "id": stale_id, "url": f"slim://{stale_id}"}, indent=2,
                       sort_keys=True) + "\n"
    path = f"{CARDS_MOUNT}/{MAPPER_CARD}"
    try:
        kpatch(AGENTS_NS, "configmap", CARDS_CONFIGMAP, {"data": {MAPPER_CARD: stale}})
        wait_for("the stale card mounted in the supervisor",
                 lambda: mounted("supervisor", path) == stale, timeout=240, every=5)
        yield stale_id
    finally:
        kpatch(AGENTS_NS, "configmap", CARDS_CONFIGMAP, {"data": {MAPPER_CARD: original}})
        wait_for("the original card mounted again",
                 lambda: mounted("supervisor", path) == original, timeout=240, every=5)
        back = kjson("-n", AGENTS_NS, "get", "configmap", CARDS_CONFIGMAP)["data"][MAPPER_CARD]
        restored = {"configmap_bytes_equal": back == original,
                    "mounted_equal": mounted("supervisor", path) == original}
        record("t146-stale-descriptor-restore", {"stale_id": stale_id, **restored})
        assert all(restored.values()), restored


def test_stale_worker_descriptor_is_named(forward) -> None:
    pod, base = forward
    pod_name, restarts = pod["metadata"]["name"], restart_count(pod)
    before = snapshot()
    with stale_mapper_card() as stale_id:
        wait_for("/v1/health naming the mapper unreachable",
                 lambda: deep_health(base)[1].get("workers") == {
                     "mapper": "unreachable", "allocator": "ok", "deployer": "ok"}, timeout=180)
        health = deep_health(base)
        status, chunks, broken = turn(STALE_PROMPT, base=base)
        during = snapshot()
    wait_for("every worker ok with the card repaired", lambda: all_ok(base), timeout=240)
    text = failure_text(chunks)
    thread = thread_of(chunks)
    resumed: list[dict[str, Any]] = []
    declined: list[dict[str, Any]] = []
    if thread:
        _s, resumed, _b = turn("continue", thread, base=base)
        declined = decline_if_asked(thread, resumed, base)
    now = supervisor_pod()
    record("t146-stale-descriptor", {
        "fault": f"agent-cards {MAPPER_CARD} id -> {stale_id}", "deep_health": health,
        "status": status, "broken": broken, "chunks": chunks, "failure_text": text,
        "resumed": resumed, "declined": declined, "before": before, "during": during,
        "after": snapshot(), "supervisor": {"pod": pod_name, "restarts": restarts,
                                            "now": now["metadata"]["name"],
                                            "now_restarts": restart_count(now)}})
    assert status == 200 and broken is None, f"stream {status} broken={broken}"
    assert_names("worker", text, forbid=("model provider", "cluster API"), also=r"\bmapper\b")
    assert all(e.get("retryable") is True for e in errors_of(chunks)), chunks
    assert "transport unavailable" not in json.dumps(health[1]), health
    assert during == before
    # the repaired card is found at call time: the same thread resumes, the same supervisor
    # process, no restart — nothing cached the stale descriptor
    assert now["metadata"]["name"] == pod_name and restart_count(now) == restarts
    assert {c.get("thread_id") for c in resumed} == {thread}, "the thread did not resume"
    assert not DEPENDENCIES["worker"].search(failure_text(resumed)), resumed
    assert any(c.get("stage") == "mapper" for c in resumed), resumed
    assert snapshot() == before


# --------------------------------------------------------------------------------------------------
# 6 — the cluster API, in its AD-52 form: the fail-closed admission webhook unreachable
# --------------------------------------------------------------------------------------------------


def _webhook_endpoints() -> int:
    eps = kjson("-n", FABRIC_NS, "get", "endpoints", WEBHOOK_SERVICE)
    return sum(len(s.get("addresses") or []) for s in eps.get("subsets") or [])


def _fabrics_ready() -> bool:
    items = kjson("get", "fabrics.fabric.agentic-netops.io", "-A").get("items") or []
    return bool(items) and all(
        any(c.get("type") == "Ready" and c.get("status") == "True"
            for c in (f.get("status") or {}).get("conditions") or [])
        for f in items)


def _claim_values(cid: str) -> list[str]:
    return sorted(f"{c['metadata']['name']}={(c.get('status') or {}).get('value')}"
                  for c in claims_of(cid))


def test_cluster_api_unavailable_names_the_admission_webhook() -> None:
    policy = kjson("get", "validatingwebhookconfigurations", "srl-provider-network-validation")
    assert [(w["name"], w["failurePolicy"]) for w in policy["webhooks"]] == [(WEBHOOK_NAME,
                                                                              "Fail")]
    # the cases before this one take the supervisor out of its Service; it starts from the Service
    # answering again with every worker ok — the lab as an operator reaches it
    wait_for("the supervisor Service answering with every worker ok",
             lambda: all_ok(None), timeout=300, every=5)
    start = snapshot()
    want = replicas(FABRIC_NS, PROVIDER)
    svc = request_to_confirmation(CLUSTER_PROMPT)
    confirm_interpretation(svc)
    cid, thread = svc.correlation_id, svc.thread_id
    held = _claim_values(cid)
    before = snapshot()
    restore: dict[str, Any] = {}
    try:
        scale(FABRIC_NS, PROVIDER, 0)
        wait_for("the admission webhook without endpoints", lambda: _webhook_endpoints() == 0,
                 timeout=120)
        status, chunks, broken = turn("yes", thread, timeout=900)
        during = {**snapshot(), "held": _claim_values(cid)}
    finally:
        scale(FABRIC_NS, PROVIDER, want)
        wait_for("the admission webhook answering again", lambda: _webhook_endpoints() >= 1,
                 timeout=300)
        # the restarted provider re-reconciles and re-verifies everything it owns; the resumed
        # thread is driven once the Fabric reads Ready=True again, not into that restart — a
        # service created while it settles can miss its convergence bound for reasons that are
        # the restart's, not this case's (T151 r10 cycle 1)
        wait_for("the Fabric Ready=True after the provider's restart", _fabrics_ready,
                 timeout=600, every=10)
        restore = {"replicas": replicas(FABRIC_NS, PROVIDER), "want": want,
                   "webhook_endpoints": _webhook_endpoints(), "fabrics_ready": _fabrics_ready()}
    text = failure_text(chunks)
    record("t146-cluster-api-unavailable", {
        "fault": f"{FABRIC_NS}/{PROVIDER} scaled to 0", "correlation_id": cid,
        "thread_id": thread, "status": status, "broken": broken, "chunks": chunks,
        "failure_text": text, "claims_held": held, "before": before, "during": during,
        "restore": restore})
    assert restore["replicas"] == want and restore["webhook_endpoints"] >= 1, restore
    assert status == 200 and broken is None, f"stream {status} broken={broken}"
    errors = errors_of(chunks)
    assert errors and all(e.get("stage") == "deployer" and e.get("retryable") is True
                          for e in errors), chunks
    assert not any(c.get("type") == "final" and c.get("status") == "COMPLETED" for c in chunks)
    assert_names("cluster API", text, forbid=("model provider", "transport", "worker"),
                 also=r"admission webhook")
    assert WEBHOOK_NAME in text, f"the webhook is not named: {text}"
    assert re.search(r"nothing was applied", text), text
    # nothing applied; the claims still provisional, exactly as they were
    assert network(f"migr-{svc.interpretation['service_id']}") is None
    assert {k: during[k] for k in ("networks", "claims")} == before
    assert held and during["held"] == held, f"claims moved: {held} -> {during['held']}"

    # the thread is resumable: the same thread, re-driven after the restore, converges
    resumed: list[Turn] = []
    status2, chunks2, broken2 = turn("continue", thread, timeout=900)
    resumed.append(Turn(chunks2, 0.0, 0.0))
    if any(c.get("type") == "confirmation_request" for c in chunks2):
        _s, more, _b = turn("yes", thread, timeout=900)
        resumed.append(Turn(more, 0.0, 0.0))
    created = next((r["name"] for t in resumed for c in t.chunks
                    for r in c.get("resources") or [] if r.get("kind") == "Network"), None)
    final = resumed[-1].last() if resumed[-1].chunks else {}
    removal_final: dict[str, Any] = {}
    try:
        assert status2 == 200 and broken2 is None, (status2, broken2)
        assert {c.get("thread_id") for t in resumed for c in t.chunks} == {thread}
        assert final.get("status") == "COMPLETED", "\n".join(t.text() for t in resumed)
        assert not DEPENDENCIES["cluster API"].search(
            "\n".join(failure_text(t.chunks) for t in resumed))
    finally:
        if created:
            removal = remove(created)
            removal_final = removal[-1].last() if removal[-1].chunks else {}
            wait_gone(created)
        wait_for("the request's claims released", lambda: not claims_of(cid), timeout=300)
        record("t146-cluster-api-resumed", {
            "resumed": [t.chunks for t in resumed], "network": created,
            "removal_final": removal_final, "after": snapshot(), "start": start})
    assert snapshot() == start, "the cluster case left a Network or a claim behind"
