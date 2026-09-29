"""Live fixtures of the intent-tier e2e suites (T089, quickstart.md §10, §16, §25).

These suites drive the RUNNING lab — `kind-agentic-netops` with `provision.sh --with-intent-tier`
done — and never a fake. They are opt-in (``AGENTIC_NETOPS_E2E=1``) so the offline `make
test-agents` run (tests/unit) never reaches for a cluster; run through
``tests/e2e/tier_e2e.sh``, which wraps each in ``evidence_run``. When ``EVIDENCE_DIR`` is set each
measurement is also written there as JSON, so the numbers are a record and not only an assertion.
"""

from __future__ import annotations

import base64
import contextlib
import json
import os
import socket
import subprocess
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

REPO = Path(__file__).resolve().parents[3]
CONTEXT = os.environ.get("KUBE_CONTEXT", "kind-agentic-netops")
AGENTS_NS = "agentic-netops-agents"
INTENT_NS = "agentic-netops-intent"
SUPERVISOR_URL = os.environ.get("SUPERVISOR_URL", "http://127.0.0.1:19090")
AGENT_DEPLOYMENTS = ("supervisor", "mapper", "allocator", "deployer")
WORKERS = ("mapper", "allocator", "deployer")



def pytest_addoption(parser: pytest.Parser) -> None:
    parser.addoption("--audit-export", action="store", default=None,
                     help="T103 file-source mode: reconcile the audit stream from this exported "
                          "audit-export-<attempt>.ndjson.gz and the usernames record beside it, "
                          "touching neither the store nor the cluster")


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    if os.environ.get("AGENTIC_NETOPS_E2E") == "1":
        return
    skip = pytest.mark.skip(reason="live e2e suite: set AGENTIC_NETOPS_E2E=1 on a provisioned "
                                   "lab (tests/e2e/tier_e2e.sh does)")
    for item in items:
        if "tests/e2e" in str(item.fspath):
            item.add_marker(skip)


def kubectl(*args: str, check: bool = True, timeout: float = 120) -> str:
    proc = subprocess.run(["kubectl", "--context", CONTEXT, *args],  # noqa: S603, S607
                          capture_output=True, text=True, timeout=timeout)
    if check and proc.returncode != 0:
        raise AssertionError(f"kubectl {' '.join(args)} failed rc={proc.returncode}: "
                             f"{proc.stderr.strip()}")
    return proc.stdout


def kjson(*args: str) -> Any:
    return json.loads(kubectl(*args, "-o", "json"))


def record(name: str, payload: Any) -> None:
    """Write one measurement into the run's evidence directory when there is one."""
    evidence = os.environ.get("EVIDENCE_DIR")
    if evidence:
        path = Path(evidence) / "t089" / f"{name}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


@dataclass
class Response:
    status: int
    headers: dict[str, str]
    body: bytes

    def json(self) -> Any:
        return json.loads(self.body)

    def chunks(self) -> list[dict[str, Any]]:
        return [json.loads(line) for line in self.body.decode().splitlines() if line.strip()]


def http(method: str, path: str, *, auth: tuple[str, str] | None = None,
         body: Any = None, timeout: float = 400, base: str | None = None) -> Response:
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request((base or SUPERVISOR_URL) + path, data=data,  # noqa: S310
                                     method=method)
    if data is not None:
        request.add_header("content-type", "application/json")
    if auth is not None:
        token = base64.b64encode(f"{auth[0]}:{auth[1]}".encode()).decode()
        request.add_header("authorization", f"Basic {token}")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as resp:  # noqa: S310
            return Response(resp.status, {k.lower(): v for k, v in resp.headers.items()},
                            resp.read())
    except urllib.error.HTTPError as exc:
        return Response(exc.code, {k.lower(): v for k, v in exc.headers.items()}, exc.read())


@contextlib.contextmanager
def pod_forward(pod: str, port: int = 9090) -> Iterator[str]:
    """A loopback port-forward straight to one supervisor pod, whatever its readiness — the
    Service (and so the published NodePort) only routes to a Ready pod."""
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        local = sock.getsockname()[1]
    proc = subprocess.Popen(  # noqa: S603
        ["kubectl", "--context", CONTEXT, "-n", AGENTS_NS, "port-forward",  # noqa: S607
         f"pod/{pod}", f"{local}:{port}", "--address", "127.0.0.1"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    base = f"http://127.0.0.1:{local}"
    try:
        wait_for(f"port-forward to {pod}", lambda: _answers(base), timeout=30, every=0.5)
        yield base
    finally:
        proc.terminate()
        proc.wait(timeout=10)


def _answers(base: str) -> bool:
    try:
        return http("GET", "/health", base=base, timeout=3).status == 200
    except OSError:
        return False


def wait_for(what: str, predicate: Callable[[], bool], timeout: float = 300,
             every: float = 3) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(every)
    raise AssertionError(f"timed out after {timeout:.0f}s waiting for {what}")


@pytest.fixture(scope="session")
def operator() -> tuple[str, str]:
    """The generated operator login, read from the Secret — never invented (quickstart §10)."""
    secret = kjson("-n", AGENTS_NS, "get", "secret", "operator-credentials")
    data = secret["data"]
    return (base64.b64decode(data["username"]).decode(),
            base64.b64decode(data["password"]).decode())


def supervisor_pod() -> dict[str, Any]:
    pods = kjson("-n", AGENTS_NS, "get", "pods", "-l", "app.kubernetes.io/name=supervisor")
    running = [p for p in pods["items"] if not p["metadata"].get("deletionTimestamp")]
    assert len(running) == 1, f"expected one supervisor pod, found {len(running)}"
    return running[0]


def pod_ready(pod: dict[str, Any]) -> bool:
    return any(c["type"] == "Ready" and c["status"] == "True"
               for c in pod.get("status", {}).get("conditions", []))


def restart_count(pod: dict[str, Any]) -> int:
    return sum(c.get("restartCount", 0) for c in pod["status"].get("containerStatuses", []))


def thread_count() -> int:
    """Distinct threads in the supervisor's durable checkpointer (PVC supervisor-checkpoint)."""
    pod = supervisor_pod()["metadata"]["name"]
    script = ("import os,sqlite3;p=os.environ.get('SUPERVISOR_CHECKPOINT_PATH',"
              "'/var/lib/supervisor/checkpoints.sqlite');"
              "print(0 if not os.path.exists(p) else (lambda c: c.execute("
              "\"SELECT COUNT(DISTINCT thread_id) FROM checkpoints\").fetchone()[0] "
              "if c.execute(\"SELECT name FROM sqlite_master WHERE name='checkpoints'\")"
              ".fetchone() else 0)(sqlite3.connect(p)))")
    return int(kubectl("-n", AGENTS_NS, "exec", pod, "-c", "supervisor", "--", "python", "-c",
                       script).strip())


def model_call_count() -> int:
    """Model calls the supervisor made in its current container: common/llm.py logs one
    ``model call N`` line per call."""
    pod = supervisor_pod()["metadata"]["name"]
    logs = kubectl("-n", AGENTS_NS, "logs", pod, "-c", "supervisor", timeout=60)
    return sum(1 for line in logs.splitlines() if '"model call ' in line)


def claim_names() -> set[str]:
    """Every allocation claim in the cluster, whichever authority the lock file installed."""
    names: set[str] = set()
    for resource in ("identifierclaims.fabric.agentic-netops.io", "vlanclaims.vlan.be.kuid.dev",
                     "genidclaims.genid.be.kuid.dev"):
        jsonpath = ("jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}"
                    '{"\\n"}{end}')
        out = kubectl("get", resource, "-A", "-o", jsonpath, check=False)
        names.update(f"{resource}:{line}" for line in out.splitlines() if line.strip())
    return names


def network_names(namespace: str = INTENT_NS) -> set[str]:
    out = kubectl("-n", namespace, "get", "networks.fabric.agentic-netops.io", "-o", "name",
                  check=False)
    return {line for line in out.splitlines() if line.strip()}


def auth_refusals_total() -> float | None:
    """``agentic_netops_agent_auth_refusals_total`` as the tier's analytics store holds it — its
    newest cumulative data point (the collector exports metrics to ClickHouse); None when no point
    exists yet."""
    query = ("SELECT argMax(Value, TimeUnix) FROM otel.otel_metrics_sum "
             "WHERE MetricName = 'agentic_netops_agent_auth_refusals_total' FORMAT TabSeparated")
    out = kubectl("-n", AGENTS_NS, "exec", "clickhouse-0", "--", "bash", "-c",
                  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" '
                  f'--query "{query}"', check=False)
    out = out.strip()
    if not out or out == "\\N":
        return None
    try:
        return float(out)
    except ValueError:
        return None


@pytest.fixture(scope="session")
def traced_service() -> Iterator[Any]:
    """US12 (T138): one tier-created service, driven through both confirmations and converged —
    the request whose one trace the trace and link suites read — removed through the tier at the
    end of the session."""
    from tierflow import provision, remove, wait_gone

    svc = provision(TRACED_PROMPT)
    try:
        yield svc
    finally:
        if svc.network:
            remove(svc.network)
            wait_gone(svc.network)


# VLAN 173 on leaf02 ethernet-1/1: naming band, a VLAN no lab example holds (examples/constructs use
# 110-160, lab-macvrf holding 120 on both leaves — the r7 collision); no other e2e prompt names it
TRACED_PROMPT = "Create a vlan for tenant acme on leaf02 ethernet-1/1 with VLAN 173"
