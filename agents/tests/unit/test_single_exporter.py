"""One emission, two sinks (T136; FR-091, R-24, FR-078).

Every agent process has exactly ONE exporter endpoint — the intent tier's collector — and the
fan-out to the two sinks lives in that collector, never in an agent:

- each of ``deploy/agents/{supervisor,mapper,allocator,deployer}.yaml`` gives its agent container
  exactly one ``OTEL_EXPORTER_OTLP_ENDPOINT``, and it is the tier collector's OTLP/HTTP Service
  (read from ``agent-otel-collector.yaml``, never retyped) — not the fabric collector, not the
  store; no container sets any other ``OTEL_EXPORTER_OTLP_*ENDPOINT``;
- ``common.telemetry.init_telemetry`` called again and again builds exactly one exporter pipeline;
- the collector's traces AND metrics pipelines list exactly the two exporters ``clickhouse`` and
  ``otlp/fabric``, logs ``clickhouse`` alone, and ``clickhouse`` keeps ``ttl: 0`` — the audit
  record's tables carry no TTL (FR-078).

Each manifest predicate has a negative control: it refuses a mutated copy.
"""

from __future__ import annotations

import copy
import re
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
import yaml

from common import telemetry

AGENTS = Path(__file__).resolve().parents[2]
DEPLOY = AGENTS.parent / "deploy" / "agents"
AGENT_NAMES = ("supervisor", "mapper", "allocator", "deployer")
COLLECTOR = DEPLOY / "agent-otel-collector.yaml"
FABRIC_ENDPOINT = "device-metrics.monitoring.svc:4317"
ENDPOINT_VAR = re.compile(r"^OTEL_EXPORTER_OTLP(_[A-Z]+)?_ENDPOINT$")


def _docs(path: Path) -> list[dict[str, Any]]:
    return [d for d in yaml.safe_load_all(path.read_text()) if d]


def _one(path: Path, kind: str, name: str | None = None) -> dict[str, Any]:
    found = [
        d
        for d in _docs(path)
        if d["kind"] == kind and (name is None or d["metadata"]["name"] == name)
    ]
    assert len(found) == 1, f"{path.name}: want one {kind} {name or ''}, got {len(found)}"
    return found[0]


def _tier_collector_endpoint() -> str:
    svc = _one(COLLECTOR, "Service", "agent-otel-collector")
    port = next(p["port"] for p in svc["spec"]["ports"] if p["name"] == "otlp-http")
    return f"http://{svc['metadata']['name']}.{svc['metadata']['namespace']}.svc:{port}"


def _collector_config() -> dict[str, Any]:
    cm = _one(COLLECTOR, "ConfigMap", "agent-otel-collector-config")
    return yaml.safe_load(cm["data"]["config.yaml"])


# ------------------------------------------------------------- one endpoint per agent process


def endpoint_problems(agent: str, deployment: dict[str, Any], want: str) -> list[str]:
    msgs: list[str] = []
    spec = deployment["spec"]["template"]["spec"]
    containers = spec.get("initContainers", []) + spec["containers"]
    for c in containers:
        endpoints = [e for e in c.get("env", []) if ENDPOINT_VAR.match(e["name"])]
        if c["name"] == agent:
            names = [e["name"] for e in endpoints]
            if names != ["OTEL_EXPORTER_OTLP_ENDPOINT"]:
                msgs.append(f"{agent}: want exactly one OTEL_EXPORTER_OTLP_ENDPOINT, got {names}")
            for e in endpoints:
                if e.get("value") != want:
                    msgs.append(
                        f"{agent}: {e['name']}={e.get('value')!r}, want the tier collector {want}"
                    )
        elif endpoints:
            msgs.append(f"{agent}: container {c['name']} sets {[e['name'] for e in endpoints]}")
        for e in endpoints:
            v = str(e.get("value", ""))
            if "device-metrics" in v or "clickhouse" in v:
                msgs.append(f"{agent}: {c['name']} exports past the tier collector to {v}")
    if agent not in [c["name"] for c in containers]:
        msgs.append(f"{agent}: no container named {agent}")
    return msgs


@pytest.mark.parametrize("agent", AGENT_NAMES)
def test_each_agent_has_exactly_one_exporter_endpoint(agent: str) -> None:
    want = _tier_collector_endpoint()
    assert want == "http://agent-otel-collector.agentic-netops-agents.svc:4318"
    dep = _one(DEPLOY / f"{agent}.yaml", "Deployment", agent)
    assert endpoint_problems(agent, dep, want) == []

    # negative controls: a second endpoint, a direct export to either sink, one on a sidecar
    def mutated(fn: Any) -> dict[str, Any]:
        bad = copy.deepcopy(dep)
        fn(bad["spec"]["template"]["spec"])
        return bad

    def main(spec: dict[str, Any]) -> dict[str, Any]:
        return next(c for c in spec["containers"] if c["name"] == agent)

    for bad in (
        mutated(
            lambda s: main(s)["env"].append(
                {"name": "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "value": want}
            )
        ),
        mutated(
            lambda s: next(
                e for e in main(s)["env"] if e["name"] == "OTEL_EXPORTER_OTLP_ENDPOINT"
            ).update(value=f"http://{FABRIC_ENDPOINT}")
        ),
        mutated(
            lambda s: next(
                e for e in main(s)["env"] if e["name"] == "OTEL_EXPORTER_OTLP_ENDPOINT"
            ).update(value="http://clickhouse.agentic-netops-agents.svc:8123")
        ),
        mutated(
            lambda s: s["containers"].append(
                {"name": "sidecar", "env": [{"name": "OTEL_EXPORTER_OTLP_ENDPOINT", "value": want}]}
            )
        ),
        mutated(
            lambda s: main(s)["env"].remove(
                next(e for e in main(s)["env"] if e["name"] == "OTEL_EXPORTER_OTLP_ENDPOINT")
            )
        ),
    ):
        assert endpoint_problems(agent, bad, want), "negative control accepted"


# ------------------------------------------------------------- one exporter pipeline per process


@pytest.fixture
def fresh_telemetry() -> Iterator[None]:
    telemetry.reset_for_tests()
    yield
    telemetry.reset_for_tests()


@pytest.mark.usefixtures("fresh_telemetry")
def test_init_telemetry_builds_exactly_one_exporter_pipeline() -> None:
    endpoint = _tier_collector_endpoint()
    bundles = [
        telemetry.init_telemetry("supervisor", endpoint=endpoint, otlp=True) for _ in range(5)
    ]
    bundles.append(telemetry.init_telemetry("mapper", endpoint=f"http://{FABRIC_ENDPOINT}"))
    bundles.append(telemetry.get_telemetry())
    assert all(b is bundles[0] for b in bundles)
    assert telemetry.exporters_created == 1
    assert bundles[0].otlp is True
    assert bundles[0].endpoint == endpoint  # the later endpoint never adds a second pipeline


# ------------------------------------------------------------- the fan-out lives in the collector


def fanout_problems(cfg: dict[str, Any]) -> list[str]:
    msgs: list[str] = []
    exporters = cfg.get("exporters") or {}
    if sorted(exporters) != ["clickhouse", "otlp/fabric"]:
        msgs.append(
            f"collector exporters {sorted(exporters)}, want exactly clickhouse and otlp/fabric"
        )
    ch = exporters.get("clickhouse") or {}
    if ch.get("ttl", "absent") != 0 or any("ttl" in k and k != "ttl" for k in ch):
        msgs.append(
            f"clickhouse ttl {ch.get('ttl', 'absent')!r}: the audit record carries no TTL (FR-078)"
        )
    if ch.get("create_schema") is not True:
        msgs.append("clickhouse create_schema must stay true (T087)")
    fab = exporters.get("otlp/fabric") or {}
    if fab.get("endpoint") != FABRIC_ENDPOINT:
        msgs.append(f"otlp/fabric endpoint {fab.get('endpoint')!r}, want {FABRIC_ENDPOINT}")
    pipelines = (cfg.get("service") or {}).get("pipelines") or {}
    want = {
        "traces": ["clickhouse", "otlp/fabric"],
        "metrics": ["clickhouse", "otlp/fabric"],
        "logs": ["clickhouse"],
    }
    if sorted(pipelines) != sorted(want):
        msgs.append(f"collector pipelines {sorted(pipelines)}, want {sorted(want)}")
    for name, exps in want.items():
        got = (pipelines.get(name) or {}).get("exporters")
        if got != exps:
            msgs.append(f"pipeline {name} exports to {got}, want {exps}")
    return msgs


def test_collector_fans_one_emission_out_to_two_sinks() -> None:
    cfg = _collector_config()
    assert fanout_problems(cfg) == []

    def mutated(fn: Any) -> dict[str, Any]:
        bad = copy.deepcopy(cfg)
        fn(bad)
        return bad

    for bad in (
        mutated(lambda c: c["exporters"]["clickhouse"].update(ttl="720h")),
        mutated(lambda c: c["exporters"]["clickhouse"].update(ttl_days=3)),
        mutated(lambda c: c["exporters"].pop("otlp/fabric")),
        mutated(lambda c: c["exporters"].update(debug={})),
        mutated(lambda c: c["service"]["pipelines"]["metrics"].update(exporters=["clickhouse"])),
        mutated(lambda c: c["service"]["pipelines"]["traces"].update(exporters=["otlp/fabric"])),
        mutated(lambda c: c["service"]["pipelines"]["logs"]["exporters"].append("otlp/fabric")),
        mutated(lambda c: c["exporters"]["otlp/fabric"].update(endpoint="clickhouse:4317")),
    ):
        assert fanout_problems(bad), "negative control accepted"


# ------------------------------------------------------------- the metric push outruns expiration

FABRIC_COLLECTOR = (AGENTS.parent / "deploy" / "observability" / "otel-collector"
                    / "otel-collector.yaml")


def _seconds(text: str) -> float:
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(ms|s|m)", str(text).strip())
    assert m, f"unparsed duration {text!r}"
    return float(m.group(1)) * {"ms": 0.001, "s": 1, "m": 60}[m.group(2)]


def test_metric_export_interval_is_below_the_fabric_expiration(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A tier series reaches Prometheus through the fabric collector's recorded ``prometheus``
    exporter, which drops it ``metric_expiration`` after its last point: the agents must push
    more often than that, or the series reads absent between pushes (FR-092, FR-093)."""
    cm = _one(FABRIC_COLLECTOR, "ConfigMap", "device-metrics-otel")
    expiration = _seconds(yaml.safe_load(cm["data"]["config.yaml"])["exporters"]["prometheus"]
                          ["metric_expiration"])
    monkeypatch.delenv("OTEL_METRIC_EXPORT_INTERVAL", raising=False)
    assert telemetry.metric_export_interval_ms() / 1000 < expiration
    # negative control: the SDK default (60 s) would not be
    monkeypatch.setenv("OTEL_METRIC_EXPORT_INTERVAL", "60000")
    assert not telemetry.metric_export_interval_ms() / 1000 < expiration
    monkeypatch.setenv("OTEL_METRIC_EXPORT_INTERVAL", "not-a-number")
    assert telemetry.metric_export_interval_ms() == telemetry.METRIC_EXPORT_INTERVAL_MS
