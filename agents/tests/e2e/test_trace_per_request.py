"""T138 — one correlated trace per request, in both sinks (SC-038; FR-090, FR-091, FR-092, FR-093,
NFR-009; quickstart.md §27).

One service is driven through both confirmations (``traced_service``). Its correlation
identifier — the ``agentic-netops.io/correlation-id`` label of the ``Network`` it produced — is
the trace id, and:

a. the **analytics store** holds that one trace spanning every stage, every worker call (the call
   on the supervisor's side and its handling in the worker's own process, parent-linked), every
   model call — prompt, model identity and response recoverable, redacted — and the convergence;
b. the **fabric stack** holds the same trace id — as the exemplar of the span metrics the fabric
   collector derives from the one forwarded emission — and the join series
   ``agentic_netops_agent_service_info`` carrying it beside the ``Network``'s name;
c. the tier series reach the fabric stack through that one emission (per-stage outcomes and
   latency, confirmations, model calls with token usage);
d. **one sink down while the other stays healthy is visible**: with the fabric collector scaled to
   zero the trace still lands in the store and the tier collector's queue for ``otlp/fabric`` is
   seen growing in Prometheus; with the store scaled to zero the trace id still reaches the fabric
   stack and the ``clickhouse`` queue is seen growing; each sink is restored and the held trace
   delivered to it afterwards — nothing lost.
"""

from __future__ import annotations

import json
import time
from typing import Any

import pytest
from conftest import AGENTS_NS, kjson, kubectl, record, wait_for
from obsflow import (
    CORRELATION_LABEL,
    MONITORING_NS,
    SPAN_CALLS,
    fabric_sink_has_trace,
    prom_exemplar_trace_ids,
    prom_value,
    service_info,
    spans_named,
    trace,
    wait_trace,
)
from tierflow import ask, network, operator_login

WORKERS = ("mapper", "allocator", "deployer")


def attr(span: dict[str, Any], key: str) -> str:
    return (span.get("attrs") or {}).get(key, "")


def complete(spans: list[dict[str, Any]]) -> bool:
    names = {s["span"] for s in spans}
    return {"convergence", "stage.deployer", "model.call"} <= names


@pytest.fixture(scope="module")
def conversation(traced_service: Any) -> dict[str, Any]:
    cid = traced_service.correlation_id
    spans = wait_trace(cid, complete)
    record("t138-trace-per-request", {"correlation_id": cid, "network": traced_service.network,
                                      "spans": [{k: s[k] for k in ("service", "span", "status")}
                                                for s in spans]})
    return {"svc": traced_service, "cid": cid, "spans": spans}


def test_the_trace_id_is_the_networks_correlation_label(conversation: dict[str, Any]) -> None:
    svc = conversation["svc"]
    obj = network(svc.network)
    assert obj is not None, f"Network {svc.network} not found"
    assert obj["metadata"]["labels"][CORRELATION_LABEL] == conversation["cid"]
    # every turn of the request is in that one trace: its request spans share the trace id
    assert len(spans_named(conversation["spans"], "supervisor.request")) >= len(svc.turns)


def test_one_trace_spans_every_stage(conversation: dict[str, Any]) -> None:
    spans = conversation["spans"]
    for stage in ("supervisor", "mapper", "allocator", "deployer"):
        found = spans_named(spans, f"stage.{stage}")
        assert found, f"no stage.{stage} span in trace {conversation['cid']}"
        assert all(attr(s, "agentic_netops.stage") == stage for s in found)


def test_every_worker_call_is_in_the_trace_on_both_sides(conversation: dict[str, Any]) -> None:
    spans = conversation["spans"]
    by_id = {s["span_id"]: s for s in spans}
    for worker in WORKERS:
        calls = [s for s in spans_named(spans, "worker.call")
                 if attr(s, "agentic_netops.worker") == worker]
        assert calls, f"no worker.call to {worker}"
        handled = [s for s in spans_named(spans, "worker.handle") if s["service"] == worker]
        assert handled, f"no worker.handle span emitted by the {worker} process"
        # the worker's span is a child of the supervisor's call span: one trace, not two
        assert any(by_id.get(h["parent"], {}).get("span") == "worker.call" for h in handled), \
            f"{worker}'s worker.handle is not parented on a worker.call span"
    # a connected tree: every parent referenced is in the trace (a continued thread's roots aside)
    orphans = [s for s in spans if s["parent"] and s["parent"] not in by_id
               and s["span"] != "supervisor.request"]
    assert not orphans, [(o["service"], o["span"]) for o in orphans]


def test_model_calls_are_reproducible_from_the_trace(conversation: dict[str, Any]) -> None:
    calls = spans_named(conversation["spans"], "model.call")
    assert calls, "no model.call span"
    _, password = operator_login()
    for call in calls:
        assert attr(call, "gen_ai.request.model"), call["attrs"]
        prompt = attr(call, "gen_ai.prompt")
        assert prompt and json.loads(prompt), "prompt not recoverable"
        assert attr(call, "gen_ai.completion"), "response not recoverable"
        assert password not in json.dumps(call["attrs"]), "a credential reached the trace"
    assert any("acme" in attr(c, "gen_ai.prompt") for c in calls), \
        "the operator's request is not in any recorded prompt"


def test_convergence_is_in_the_trace(conversation: dict[str, Any]) -> None:
    conv = spans_named(conversation["spans"], "convergence")
    assert conv, "no convergence span"
    assert any(attr(c, "k8s.network.name") == conversation["svc"].network for c in conv)
    assert any(attr(c, "agentic_netops.outcome") == "converged" for c in conv), \
        [c["attrs"] for c in conv]


def test_both_sinks_carry_the_same_trace_id(conversation: dict[str, Any]) -> None:
    cid = conversation["cid"]
    assert trace(cid), "analytics store lost the trace"
    assert fabric_sink_has_trace(cid)
    wait_for("service_info in Prometheus",
             lambda: bool(service_info(conversation["svc"].network)), timeout=180, every=5)
    info = service_info(conversation["svc"].network)
    assert {i["correlation_id"] for i in info} == {cid}, info
    record("t138-both-sinks", {"correlation_id": cid, "analytics_spans": len(trace(cid)),
                               "fabric_exemplar": True, "service_info": info})


def test_tier_series_reach_the_fabric_stack(conversation: dict[str, Any]) -> None:
    exprs = {
        "stage_requests": "sum(agentic_netops_agent_stage_requests_total)",
        "stage_latency": "sum(agentic_netops_agent_stage_duration_seconds_count)",
        "confirmations": 'sum(agentic_netops_agent_confirmations_total{decision="confirmed"})',
        "model_calls": "sum(agentic_netops_agent_model_calls_total)",
        "model_tokens": "sum(agentic_netops_agent_model_tokens_total)",
        "worker_calls": "sum(agentic_netops_agent_worker_calls_total)",
    }
    values: dict[str, float] = {}

    def all_present() -> bool:
        values.update({k: prom_value(e) for k, e in exprs.items()})
        return all(v > 0 for v in values.values())

    wait_for("tier series in Prometheus", all_present, timeout=180, every=10)
    record("t138-tier-series", values)


# --------------------------------------------------------------------------------------------------
# d. one sink down while the other stays healthy
# --------------------------------------------------------------------------------------------------


def queue(exporter: str) -> float:
    return prom_value(f'otelcol_exporter_queue_size{{job="agent-otel-collector",'
                      f'exporter="{exporter}"}}')


def sent(exporter: str) -> float:
    return prom_value(f'sum(otelcol_exporter_sent_spans{{job="agent-otel-collector",'
                      f'exporter="{exporter}"}})')


def scale(kind: str, name: str, ns: str, replicas: int) -> None:
    kubectl("-n", ns, "scale", f"{kind}/{name}", f"--replicas={replicas}")
    if replicas:
        kubectl("-n", ns, "rollout", "status", f"{kind}/{name}", "--timeout=300s", timeout=320)
    else:
        wait_for(f"{kind}/{name} scaled to zero",
                 lambda: not kjson("-n", ns, "get", "pods", "-l",
                                   f"app.kubernetes.io/name={name}")["items"],
                 timeout=180)


def informational_request() -> str:
    turn = ask("What constructs can I ask for?")
    return turn.correlation_id


def test_fabric_sink_down_is_visible_and_the_store_stays_healthy() -> None:
    before = sent("clickhouse")
    scale("deployment", "device-metrics-otel", MONITORING_NS, 0)
    try:
        cid = informational_request()
        wait_trace(cid, lambda s: bool(spans_named(s, "supervisor.request")))
        wait_for("otlp/fabric queue growing while the fabric collector is down",
                 lambda: queue("otlp/fabric") > 0, timeout=180, every=10)
        down = {"otlp_fabric_queue": queue("otlp/fabric"), "clickhouse_sent_delta":
                sent("clickhouse") - before, "correlation_id": cid}
        assert down["clickhouse_sent_delta"] > 0, down
        assert cid not in prom_exemplar_trace_ids(SPAN_CALLS), "fabric sink cannot have it yet"
    finally:
        scale("deployment", "device-metrics-otel", MONITORING_NS, 1)
    # the held emission is delivered once the sink is back: nothing lost, nothing emitted twice
    assert fabric_sink_has_trace(cid, timeout=300)
    wait_for("otlp/fabric queue drained", lambda: queue("otlp/fabric") == 0, timeout=300,
             every=10)
    record("t138-fabric-sink-down", {**down, "delivered_after_restore": True})


def test_store_down_is_visible_and_the_fabric_sink_stays_healthy() -> None:
    scale("statefulset", "clickhouse", AGENTS_NS, 0)
    t0 = time.monotonic()
    try:
        cid = informational_request()
        assert fabric_sink_has_trace(cid, timeout=120)
        wait_for("clickhouse queue growing while the store is down",
                 lambda: queue("clickhouse") > 0, timeout=120, every=10)
        down = {"clickhouse_queue": queue("clickhouse"), "correlation_id": cid,
                "fabric_exemplar": True}
    finally:
        scale("statefulset", "clickhouse", AGENTS_NS, 1)
    down["store_down_seconds"] = round(time.monotonic() - t0, 1)
    # the collector retries for up to 300 s: the held spans land once the store is back
    wait_trace(cid, lambda s: bool(spans_named(s, "supervisor.request")), timeout=300)
    record("t138-store-down", {**down, "delivered_after_restore": True})
