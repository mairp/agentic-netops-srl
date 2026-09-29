"""T138 — per-stage failure injection, diagnosed from the trace alone (SC-038; FR-090, NFR-010;
quickstart.md §27).

One failure is injected at each stage of a live request, and the diagnosis is read from the
analytics store's trace ONLY — never from a process log, never from the chunk stream:

=========== ================================================================================
supervisor  an unsafe request (a direct device session) — refused by the guards
mapper      a VLAN named from the allocation band (1500) — refused at interpretation; the
            interpretation that failed the band check is the recorded payload
allocator   the allocator worker scaled to zero — the worker call unreachable
deployer    a (node, port, VLAN) another Network in ``agentic-netops-services`` owns — refused by
            the admission dry-run; the ``Network`` that failed validation is the recorded payload
=========== ================================================================================

For each, the trace's request span names the responsible stage (``agentic_netops.failed_stage``)
and an errored span of that stage carries the reason — and, where a payload failed validation, the
payload itself. 100 % of the injected failures must be identified.
"""

from __future__ import annotations

import json
from typing import Any

import pytest
from conftest import AGENTS_NS, kjson, kubectl, pod_ready, record, supervisor_pod, wait_for
from obsflow import failing_spans, spans_named, wait_trace
from tierflow import ask, claims_of, request_to_confirmation

FAILED_STAGE = "agentic_netops.failed_stage"
FAILURE_STAGE = "agentic_netops.failure.stage"
REASON = "agentic_netops.failure.reason"
PAYLOAD = "agentic_netops.failure.payload"
RESULTS: dict[str, dict[str, Any]] = {}


def attr(span: dict[str, Any], key: str) -> str:
    return (span.get("attrs") or {}).get(key, "")


def diagnosis(cid: str, stage: str) -> dict[str, Any]:
    """What the trace alone says of request ``cid``: the stage it names, the errored spans."""
    def named(spans: list[dict[str, Any]]) -> bool:
        return any(attr(r, FAILED_STAGE) for r in spans_named(spans, "supervisor.request"))

    spans = wait_trace(cid, named, timeout=240)
    roots = [r for r in spans_named(spans, "supervisor.request") if attr(r, FAILED_STAGE)]
    # a stage's own span carries agentic_netops.stage; a worker's spans below it name the stage
    # they failed through agentic_netops.failure.stage — both are read from the trace alone
    errored = [s for s in failing_spans(spans)
               if stage in (attr(s, "agentic_netops.stage"), attr(s, FAILURE_STAGE))]
    found = {
        "correlation_id": cid,
        "failed_stage": sorted({attr(r, FAILED_STAGE) for r in roots}),
        "errored_spans": [{"service": s["service"], "span": s["span"],
                           "reason": attr(s, REASON)[:1000], "payload": attr(s, PAYLOAD)[:2000]}
                          for s in errored],
    }
    RESULTS[stage] = found
    record(f"t138-failure-{stage}", found)
    assert found["failed_stage"] == [stage], found
    assert errored, f"no errored span of stage {stage} in the trace: {found}"
    assert any(e["reason"] for e in found["errored_spans"]), found
    return found


def scale(name: str, replicas: int) -> None:
    kubectl("-n", AGENTS_NS, "scale", f"deployment/{name}", f"--replicas={replicas}")
    if replicas:
        kubectl("-n", AGENTS_NS, "rollout", "status", f"deployment/{name}", "--timeout=300s",
                timeout=320)
        # the supervisor goes NotReady while a worker is away (T089) and the published port
        # routes only to a Ready pod: the next request waits for it, never for a reset
        # connection (T151 r9: the deployer case was reset right after the allocator returned)
        wait_for("the supervisor Ready again", lambda: pod_ready(supervisor_pod()), timeout=300)
    else:
        wait_for(f"{name} at zero", lambda: not kjson(
            "-n", AGENTS_NS, "get", "pods", "-l", f"app.kubernetes.io/name={name}")["items"],
            timeout=180)


def test_supervisor_failure_is_named_from_the_trace() -> None:
    turn = ask("SSH into leaf01 and run 'show interface ethernet-1/1'")
    diagnosis(turn.correlation_id, "supervisor")


def test_mapper_failure_names_the_payload_that_failed_validation() -> None:
    turn = ask("Create a vlan for tenant acme on leaf02 ethernet-1/1 with VLAN 1500")
    found = diagnosis(turn.correlation_id, "mapper")
    payloads = [e["payload"] for e in found["errored_spans"] if e["payload"]]
    assert payloads, f"the interpretation that failed validation is not in the trace: {found}"
    assert any("1500" in p for p in payloads), payloads
    assert not claims_of(turn.correlation_id)


def test_allocator_failure_is_named_from_the_trace() -> None:
    svc = request_to_confirmation(
        "Create a vlan for tenant acme on leaf02 ethernet-1/1 with VLAN 121")
    scale("allocator", 0)
    try:
        turn = ask("yes", svc.thread_id, timeout=900)
    finally:
        scale("allocator", 1)
    assert turn.last().get("status") in ("FAILED", "STATUS_UNKNOWN") or turn.of("error"), \
        turn.text()
    found = diagnosis(svc.correlation_id, "allocator")
    assert any(e["span"] in ("worker.call", "stage.allocator") for e in found["errored_spans"])


def test_deployer_failure_names_the_payload_that_failed_validation() -> None:
    # leaf01 ethernet-1/1 VLAN 110 is held by Network lab-vlan in agentic-netops-services, which
    # the deployer's pre-flight cannot see: the admission dry-run refuses the bundle
    holder = kjson("-n", "agentic-netops-services", "get",
                   "networks.fabric.agentic-netops.io", "lab-vlan")
    assert holder["spec"]["attachments"][0] == {"node": "leaf01", "attachment": "ethernet-1/1",
                                                "vlan": 110}
    svc = request_to_confirmation(
        "Create a vlan for tenant acme on leaf01 ethernet-1/1 with VLAN 110")
    ask("yes", svc.thread_id)
    turn = ask("yes", svc.thread_id, timeout=900)
    assert turn.last().get("status") == "FAILED", turn.text()
    found = diagnosis(svc.correlation_id, "deployer")
    payloads = [e["payload"] for e in found["errored_spans"] if e["payload"]]
    assert payloads, f"the Network that failed validation is not in the trace: {found}"
    assert any("Network" in p and "110" in p and "leaf01" in p for p in payloads), payloads
    assert any("lab-vlan" in e["reason"] for e in found["errored_spans"]), found
    assert not claims_of(svc.correlation_id), "provisional claims not released"


@pytest.fixture(scope="module", autouse=True)
def summary() -> Any:
    yield
    identified = [s for s, r in RESULTS.items() if r["failed_stage"] == [s]]
    record("t138-failure-summary", {"injected": sorted(RESULTS), "identified": sorted(identified),
                                    "rate": (len(identified) / len(RESULTS)) if RESULTS else None})
    print(json.dumps({"t138_failures_identified": f"{len(identified)}/{len(RESULTS)}"}))
