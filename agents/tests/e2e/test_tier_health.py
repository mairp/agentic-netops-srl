"""T089 — the intent tier is healthy beside the control plane, live (quickstart.md §10, §16;
NFR-012, SC-024, FR-074).

* every agent healthy with no manual step — the four agent Deployments, the transport, the
  analytics store and its collector Ready; ``/health`` and ``/v1/health`` answer; the transport
  endpoint reads ``:46357``;
* the NFR-012 measure — the tier's summed requests and limits read from the RUNNING pods, beside
  T052's measured per-node footprint and the host's CPU and memory, the first two fitting under the
  third;
* the fabric undisturbed — every fabric workload, all four targets and the ``Fabric`` Ready, zero
  fabric pods evicted, restarted or OOM-killed since the tier phase began; negative control: the
  same check fails against a fabric Deployment scaled to zero;
* a worker scaled to zero is named on ``/v1/health``, the supervisor goes NotReady and is not
  restarted, nothing is submitted, and the thread resumes on scale-up (SC-024).

The purge half of T089 is ``tests/e2e/tier_purge_live.sh``, run after these by
``tests/e2e/tier_e2e.sh`` because it removes the tier and ends by provisioning it again.
"""

from __future__ import annotations

import json
import os
import re
from datetime import datetime
from typing import Any

import pytest
from conftest import (
    AGENT_DEPLOYMENTS,
    AGENTS_NS,
    INTENT_NS,
    REPO,
    WORKERS,
    claim_names,
    http,
    kjson,
    kubectl,
    network_names,
    pod_forward,
    pod_ready,
    record,
    restart_count,
    supervisor_pod,
    thread_count,
    wait_for,
)

TIER_WORKLOADS = {"deployment": (*AGENT_DEPLOYMENTS, "slim", "agent-otel-collector"),
                  "statefulset": ("clickhouse",)}
FABRIC_NAMESPACES = ("agentic-netops-system", "sdc-system", "agentic-netops-allocation",
                     "kuid-system", "cert-manager")
FABRIC_NS = "agentic-netops-system"


# --------------------------------------------------------------------------------------------------
# every agent healthy with no manual step
# --------------------------------------------------------------------------------------------------


def _ready(kind: str, name: str) -> bool:
    obj = kjson("-n", AGENTS_NS, "get", kind, name)
    want = obj["spec"].get("replicas", 1)
    return want >= 1 and obj.get("status", {}).get("readyReplicas", 0) == want


def test_every_agent_healthy_with_no_manual_step(operator) -> None:
    states = {f"{kind}/{name}": _ready(kind, name)
              for kind, names in TIER_WORKLOADS.items() for name in names}
    live = http("GET", "/health")
    deep = http("GET", "/v1/health")
    transport = http("GET", "/transport/config", auth=operator)
    record("tier-health", {"workloads": states, "health": live.json(), "deep": deep.json(),
                           "deep_status": deep.status, "transport": transport.json()})
    assert all(states.values()), states
    assert live.status == 200 and live.json() == {"status": "ok"}
    assert deep.status == 200, deep.json()
    body = deep.json()
    assert body["status"] == "ok" and body["transport"] == "SLIM"
    assert body["workers"] == {w: "ok" for w in WORKERS}
    assert body["endpoint"].endswith(":46357")
    assert transport.json()["endpoint"].endswith(":46357")


# --------------------------------------------------------------------------------------------------
# NFR-012: the tier's requests and limits, the fabric's measured footprint, the host
# --------------------------------------------------------------------------------------------------

_CPU = re.compile(r"^(\d+(?:\.\d+)?)(m?)$")
_MEM = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "K": 10**3, "M": 10**6, "G": 10**9}


def cpu_cores(value: str) -> float:
    match = _CPU.match(str(value))
    assert match, f"unparseable CPU quantity {value!r}"
    number = float(match.group(1))
    return number / 1000 if match.group(2) else number


def mem_bytes(value: str) -> int:
    value = str(value)
    for suffix in sorted(_MEM, key=len, reverse=True):
        if value.endswith(suffix):
            return int(float(value[: -len(suffix)]) * _MEM[suffix])
    return int(float(value))


def _tier_sums() -> dict[str, Any]:
    pods = kjson("-n", AGENTS_NS, "get", "pods")["items"]
    sums = {"requests": {"cpu": 0.0, "memory": 0}, "limits": {"cpu": 0.0, "memory": 0}}
    per_pod = {}
    for pod in pods:
        if pod["status"].get("phase") != "Running":
            continue
        name = pod["metadata"]["name"]
        per_pod[name] = []
        for c in pod["spec"]["containers"]:
            res = c.get("resources", {})
            for bound in ("requests", "limits"):
                got = res.get(bound, {})
                assert "cpu" in got and "memory" in got, \
                    f"{name}/{c['name']} declares no explicit {bound} (T087)"
                sums[bound]["cpu"] += cpu_cores(got["cpu"])
                sums[bound]["memory"] += mem_bytes(got["memory"])
            per_pod[name].append({c["name"]: res})
    return {"sums": sums, "pods": per_pod}


def _latest_footprint() -> tuple[str, dict[str, Any]]:
    found = sorted((REPO / ".evidence").glob("*/*/footprint.summary.stdout"))
    assert found, "no T052 footprint measurement under .evidence/ (footprint.summary)"
    path = found[-1]
    return str(path.relative_to(REPO)), json.loads(path.read_text())


def _host() -> dict[str, Any]:
    meminfo = {}
    with open("/proc/meminfo") as fh:
        for line in fh:
            key, value = line.split(":", 1)
            meminfo[key] = int(value.split()[0]) * 1024
    return {"cpus": os.cpu_count(), "mem_total": meminfo["MemTotal"],
            "mem_available_now": meminfo["MemAvailable"]}


def test_nfr012_tier_and_fabric_fit_under_the_host() -> None:
    tier = _tier_sums()
    source, footprint = _latest_footprint()
    nodes = footprint["nodes"]
    fabric_mem = sum(n["charged_mib_mean"] for n in nodes) * 2**20
    fabric_cpu = sum(n["cpu_percent_max"] for n in nodes) / 100.0
    host = _host()
    need_cpu = tier["sums"]["limits"]["cpu"] + fabric_cpu
    need_mem = tier["sums"]["limits"]["memory"] + fabric_mem
    record("nfr012", {"tier": tier, "footprint_source": source,
                      "fabric": {"nodes": len(nodes), "memory_bytes": fabric_mem,
                                 "cpu_cores": fabric_cpu},
                      "host": host, "need": {"cpu_cores": need_cpu, "memory_bytes": need_mem}})
    assert tier["sums"]["requests"]["cpu"] > 0 and tier["sums"]["requests"]["memory"] > 0
    assert need_cpu <= host["cpus"], f"tier limits + fabric footprint {need_cpu:.2f} CPU > host"
    assert need_mem <= host["mem_total"], "tier limits + fabric footprint exceed host memory"


# --------------------------------------------------------------------------------------------------
# the fabric is undisturbed by the tier (and the check can fail)
# --------------------------------------------------------------------------------------------------


def _tier_phase_start() -> datetime:
    ns = kjson("get", "namespace", AGENTS_NS)
    return datetime.fromisoformat(ns["metadata"]["creationTimestamp"].replace("Z", "+00:00"))


def fabric_disturbances(since: datetime) -> list[str]:
    """Everything that says the fabric is not as it was: [] means undisturbed."""
    problems: list[str] = []
    existing = set(kubectl("get", "namespaces", "-o", "name").split())
    for ns in FABRIC_NAMESPACES:
        if f"namespace/{ns}" not in existing:
            continue
        for kind in ("deployments", "statefulsets"):
            for obj in kjson("-n", ns, "get", kind)["items"]:
                want = obj["spec"].get("replicas", 1)
                ready = obj.get("status", {}).get("readyReplicas", 0) or 0
                if want < 1 or ready < want:
                    problems.append(f"{kind}/{ns}/{obj['metadata']['name']} ready {ready}/{want}")
        for pod in kjson("-n", ns, "get", "pods")["items"]:
            name = f"pod/{ns}/{pod['metadata']['name']}"
            status = pod.get("status", {})
            if status.get("reason") == "Evicted":
                problems.append(f"{name} evicted")
            for c in status.get("containerStatuses", []):
                last = (c.get("lastState") or {}).get("terminated") or {}
                if last.get("reason") == "OOMKilled":
                    problems.append(f"{name}/{c['name']} OOM-killed")
                finished = last.get("finishedAt")
                if finished and datetime.fromisoformat(finished.replace("Z", "+00:00")) >= since:
                    problems.append(f"{name}/{c['name']} restarted at {finished}")
    for target in kjson("-n", FABRIC_NS, "get", "targets.config.sdcio.dev")["items"]:
        conds = {c["type"]: c["status"] for c in target.get("status", {}).get("conditions", [])}
        if conds.get("Ready") != "True":
            problems.append(f"target/{target['metadata']['name']} not Ready")
    fabrics = kjson("-n", FABRIC_NS, "get", "fabrics.fabric.agentic-netops.io")["items"]
    if not fabrics:
        problems.append("no Fabric")
    for fab in fabrics:
        conds = {c["type"]: c["status"] for c in fab.get("status", {}).get("conditions", [])}
        if conds.get("Ready") != "True":
            problems.append(f"fabric/{fab['metadata']['name']} not Ready")
    return problems


def test_fabric_undisturbed_after_the_tier_phase() -> None:
    since = _tier_phase_start()
    targets = kjson("-n", FABRIC_NS, "get", "targets.config.sdcio.dev")["items"]
    problems = fabric_disturbances(since)
    record("fabric-undisturbed", {"since": since.isoformat(), "targets": len(targets),
                                  "problems": problems})
    assert len(targets) == 4
    assert problems == []


def test_fabric_check_negative_control_fails_on_a_scaled_down_fabric_deployment() -> None:
    since = _tier_phase_start()
    deploy = "srl-provider"
    kubectl("-n", FABRIC_NS, "scale", f"deployment/{deploy}", "--replicas=0")
    try:
        wait_for(f"{deploy} scaled to zero", lambda: not kjson(
            "-n", FABRIC_NS, "get", "deployment", deploy).get("status", {}).get("readyReplicas"),
                 timeout=120)
        problems = fabric_disturbances(since)
        record("fabric-undisturbed-negative-control", {"scaled": deploy, "problems": problems})
        assert any(deploy in p for p in problems), problems
    finally:
        kubectl("-n", FABRIC_NS, "scale", f"deployment/{deploy}", "--replicas=1")
        kubectl("-n", FABRIC_NS, "rollout", "status", f"deployment/{deploy}", "--timeout=300s",
                timeout=320)
    wait_for("the fabric undisturbed again after the control",
             lambda: fabric_disturbances(since) == [], timeout=300, every=10)


# --------------------------------------------------------------------------------------------------
# a worker is down (quickstart §16, SC-024)
# --------------------------------------------------------------------------------------------------


def _deep_workers(base: str | None = None) -> tuple[int, dict[str, str]]:
    try:
        resp = http("GET", "/v1/health", base=base, timeout=30)
    except OSError:  # the published port has nothing behind it while the supervisor is NotReady
        return 0, {}
    return resp.status, resp.json().get("workers", {})


@pytest.fixture
def mapper_scaled_down():
    kubectl("-n", AGENTS_NS, "scale", "deployment/mapper", "--replicas=0")
    try:
        yield
    finally:
        kubectl("-n", AGENTS_NS, "scale", "deployment/mapper", "--replicas=1")
        kubectl("-n", AGENTS_NS, "rollout", "status", "deployment/mapper", "--timeout=300s",
                timeout=320)


@pytest.fixture
def supervisor_forward():
    """The supervisor pod, and a port-forward straight to it that survives its NotReady window."""
    pod = supervisor_pod()
    with pod_forward(pod["metadata"]["name"]) as base:
        yield pod, base


def test_a_worker_scaled_to_zero_is_named_and_the_thread_resumes(operator, supervisor_forward,
                                                                 mapper_scaled_down) -> None:
    pod, forward = supervisor_forward
    pod_name, restarts = pod["metadata"]["name"], restart_count(pod)
    networks, claims = network_names(INTENT_NS), claim_names()

    wait_for("/v1/health to name the mapper unreachable",
             lambda: _deep_workers(forward) == (503, {"mapper": "unreachable", "allocator": "ok",
                                               "deployer": "ok"}), timeout=180)
    wait_for("the supervisor NotReady", lambda: not pod_ready(supervisor_pod()), timeout=120)

    threads_before = thread_count()
    # NotReady takes the supervisor out of its Service's endpoints, so the published NodePort has
    # nothing behind it; the turn is sent to the pod itself (a port-forward ignores readiness),
    # which is what shows the stopped worker named rather than fatal.
    first = http("POST", "/agent/prompt/stream", auth=operator, base=forward,
                 body={"prompt": "Provision a vlan 121 on leaf01 ethernet-1/1 for tenant acme"})
    assert first.status == 200, first.body[:300]
    chunks = first.chunks()
    thread_id = chunks[0]["thread_id"]
    correlation = chunks[0]["correlation_id"]
    assert all(c.get("correlation_id") == correlation for c in chunks), chunks
    errors = [c for c in chunks if c.get("type") == "error"]
    assert errors and "worker unreachable: mapper" in errors[-1]["reason"], chunks
    assert errors[-1]["retryable"] is True
    assert thread_count() == threads_before + 1

    # nothing was submitted and nothing claimed; the supervisor was not restarted
    assert network_names(INTENT_NS) == networks
    assert claim_names() == claims
    now = supervisor_pod()
    assert now["metadata"]["name"] == pod_name and restart_count(now) == restarts

    # scale back up: the deep check recovers, the supervisor goes Ready, the thread resumes
    kubectl("-n", AGENTS_NS, "scale", "deployment/mapper", "--replicas=1")
    wait_for("/v1/health 200 with every worker ok",
             lambda: _deep_workers(forward) == (200, {w: "ok" for w in WORKERS}), timeout=300)
    wait_for("the supervisor Ready again", lambda: pod_ready(supervisor_pod()), timeout=120)
    again = http("POST", "/agent/prompt/stream", auth=operator,
                 body={"prompt": "continue", "thread_id": thread_id})
    assert again.status == 200, again.body[:300]
    resumed = again.chunks()
    assert {c["thread_id"] for c in resumed} == {thread_id}
    assert {c["correlation_id"] for c in resumed} == {correlation}, "thread state not intact"
    # the pending stage was retried: the mapper answered this time (reachable); until US4 brings
    # its stage logic its answer is the terminal "not implemented" failure — never "unreachable"
    reasons = " ".join(str(c.get("reason", "")) + str(c.get("message", "")) for c in resumed)
    assert "worker unreachable" not in reasons, resumed
    assert "mapper" in reasons, resumed
    assert thread_count() == threads_before + 1, "a continuation must not mint a thread"
    assert network_names(INTENT_NS) == networks and claim_names() == claims
    final = supervisor_pod()
    assert final["metadata"]["name"] == pod_name and restart_count(final) == restarts
    record("worker-down", {"thread_id": thread_id, "correlation_id": correlation,
                           "first_turn": chunks, "resumed_turn": resumed,
                           "supervisor_pod": pod_name, "restarts": restarts})
