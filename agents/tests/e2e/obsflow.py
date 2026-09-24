"""Read side of the US12 e2e suites (T138): the two sinks and the dashboards, read-only.

* the **agent-analytics store** (ClickHouse) — the conversation trace, row per span, read from
  inside its pod with the container's own credentials (:func:`tierflow.store_query`);
* the **fabric observability stack** — Prometheus through the API server's service proxy (no
  port-forward, no credential), its series and the exemplars the fabric collector's span metrics
  carry (their ``trace_id`` is the correlation identifier);
* **Grafana** through a loopback port-forward with the generated administrator of
  ``monitoring/grafana-admin`` (never echoed): the dashboards' link templates and the datasource
  queries a click on them runs.

Nothing here writes to either sink; the fault the sink-down cases make is scoped to one
Deployment's or one StatefulSet's replica count and is put back from a ``finally``.
"""

from __future__ import annotations

import base64
import contextlib
import json
import re
import socket
import subprocess
import time
import urllib.parse
import urllib.request
from collections.abc import Iterator
from typing import Any

from conftest import CONTEXT, kjson, kubectl, wait_for
from tierflow import store_query

MONITORING_NS = "monitoring"
PROM_PROXY = f"/api/v1/namespaces/{MONITORING_NS}/services/prometheus:9090/proxy"
CORRELATION_LABEL = "agentic-netops.io/correlation-id"
# the span-metrics connector's calls counter, exported without a unit suffix (the recorded
# translation_strategy UnderscoreEscapingWithoutSuffixes of the fabric collector)
SPAN_CALLS = "agentic_netops_agent_spans_calls"
SERVICE_INFO = "agentic_netops_agent_service_info"
STAGES = ("supervisor", "mapper", "allocator", "deployer")


# --------------------------------------------------------------------------------------------------
# the analytics sink: the conversation trace
# --------------------------------------------------------------------------------------------------

TRACE_SQL = (
    "SELECT toString(Timestamp) AS ts, ServiceName AS service, SpanName AS span, "
    "SpanId AS span_id, "
    "ParentSpanId AS parent, StatusCode AS status, StatusMessage AS status_message, "
    "SpanAttributes AS attrs, Events.Name AS events, intDiv(Duration, 1000000) AS ms "
    "FROM otel.otel_traces WHERE TraceId = '{cid}' ORDER BY Timestamp FORMAT JSONEachRow")


def trace(correlation_id: str) -> list[dict[str, Any]]:
    """Every span of the trace ``correlation_id`` in the analytics store, oldest first."""
    assert re.fullmatch(r"[0-9a-f]{32}", correlation_id), correlation_id
    return store_query(TRACE_SQL.format(cid=correlation_id))


def wait_trace(correlation_id: str, predicate: Any, timeout: float = 180) -> list[dict[str, Any]]:
    """The trace once ``predicate(spans)`` holds (spans reach the store in batches)."""
    found: list[dict[str, Any]] = []

    def ready() -> bool:
        nonlocal found
        found = trace(correlation_id)
        return bool(predicate(found))

    wait_for(f"trace {correlation_id} in the analytics store", ready, timeout=timeout, every=5)
    return found


def spans_named(spans: list[dict[str, Any]], name: str) -> list[dict[str, Any]]:
    return [s for s in spans if s["span"] == name]


def failing_spans(spans: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [s for s in spans if s["status"] in ("Error", "STATUS_CODE_ERROR")]


def root(spans: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return spans_named(spans, "supervisor.request")


# --------------------------------------------------------------------------------------------------
# the fabric sink: Prometheus
# --------------------------------------------------------------------------------------------------


def _prom(path: str) -> Any:
    out = kubectl("get", "--raw", f"{PROM_PROXY}{path}", timeout=60)
    body = json.loads(out)
    assert body.get("status") == "success", body
    return body["data"]


def prom_query(expr: str) -> list[dict[str, Any]]:
    return _prom("/api/v1/query?" + urllib.parse.urlencode({"query": expr}))["result"]


def prom_value(expr: str) -> float:
    """The sum of an instant vector (0.0 when empty)."""
    return sum(float(r["value"][1]) for r in prom_query(expr))


def prom_exemplar_trace_ids(expr: str, since_s: float = 3600) -> set[str]:
    """Every ``trace_id`` among the exemplars of ``expr`` over the last ``since_s`` seconds."""
    now = time.time()
    data = _prom("/api/v1/query_exemplars?" + urllib.parse.urlencode(
        {"query": expr, "start": f"{now - since_s:.0f}", "end": f"{now:.0f}"}))
    ids: set[str] = set()
    for series in data or []:
        for ex in series.get("exemplars") or []:
            tid = (ex.get("labels") or {}).get("trace_id")
            if tid:
                ids.add(tid)
    return ids


def fabric_sink_has_trace(correlation_id: str, timeout: float = 180) -> bool:
    """Wait until the fabric sink holds an exemplar carrying ``correlation_id``."""
    wait_for(f"exemplar trace_id={correlation_id} in Prometheus",
             lambda: correlation_id in prom_exemplar_trace_ids(SPAN_CALLS),
             timeout=timeout, every=5)
    return True


def service_info(network: str) -> list[dict[str, Any]]:
    return [r["metric"] for r in prom_query(f'{SERVICE_INFO}{{network="{network}"}}')]


# --------------------------------------------------------------------------------------------------
# Grafana
# --------------------------------------------------------------------------------------------------


class Grafana:
    def __init__(self, base: str, auth: tuple[str, str]) -> None:
        self.base = base
        self._auth = "Basic " + base64.b64encode(f"{auth[0]}:{auth[1]}".encode()).decode()

    def call(self, method: str, path: str, body: Any = None) -> Any:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method,  # noqa: S310
                                     headers={"Authorization": self._auth,
                                              "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as resp:  # noqa: S310
            return json.loads(resp.read() or b"null")

    def dashboard(self, uid: str) -> dict[str, Any]:
        return self.call("GET", f"/api/dashboards/uid/{uid}")["dashboard"]

    def sql(self, datasource_uid: str, raw_sql: str) -> list[dict[str, Any]]:
        """Run ``raw_sql`` through the datasource as a panel would; rows as dicts."""
        body = {"queries": [{"refId": "A", "datasource": {"uid": datasource_uid},
                             "rawSql": raw_sql, "format": "table", "rawQuery": True,
                             "editorMode": "code"}],
                "from": "now-30d", "to": "now"}
        out = self.call("POST", "/api/ds/query", body)
        rows: list[dict[str, Any]] = []
        for frame in out["results"]["A"].get("frames") or []:
            names = [f["name"] for f in frame["schema"]["fields"]]
            cols = frame["data"]["values"]
            for i in range(len(cols[0]) if cols else 0):
                rows.append({n: cols[j][i] for j, n in enumerate(names)})
        return rows


@contextlib.contextmanager
def grafana() -> Iterator[Grafana]:
    secret = kjson("-n", MONITORING_NS, "get", "secret", "grafana-admin")
    auth = (base64.b64decode(secret["data"]["admin-user"]).decode(),
            base64.b64decode(secret["data"]["admin-password"]).decode())
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        local = sock.getsockname()[1]
    proc = subprocess.Popen(  # noqa: S603
        ["kubectl", "--context", CONTEXT, "-n", MONITORING_NS, "port-forward",  # noqa: S607
         "svc/grafana", f"{local}:3000", "--address", "127.0.0.1"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    gf = Grafana(f"http://127.0.0.1:{local}", auth)

    def answers() -> bool:
        try:
            gf.call("GET", "/api/health")
            return True
        except OSError:
            return False

    try:
        wait_for("Grafana port-forward", answers, timeout=60, every=1)
        yield gf
    finally:
        proc.terminate()
        proc.wait(timeout=10)


def panels(dashboard: dict[str, Any]) -> Iterator[dict[str, Any]]:
    for p in dashboard.get("panels") or []:
        yield p
        yield from p.get("panels") or []


def panel_links(panel: dict[str, Any]) -> list[dict[str, Any]]:
    """Every data link a panel defines — field defaults and overrides alike."""
    fc = panel.get("fieldConfig") or {}
    links = list((fc.get("defaults") or {}).get("links") or [])
    for ov in fc.get("overrides") or []:
        for prop in ov.get("properties") or []:
            if prop.get("id") == "links":
                links.extend(prop.get("value") or [])
    return links


TIME_MARKERS = ("from=", "to=", "__url_time_range", "time=", "time.window", "__from", "__to")


def link_to(links: list[dict[str, Any]], uid: str) -> dict[str, Any]:
    for link in links:
        if f"/d/{uid}" in link.get("url", ""):
            return link
    raise AssertionError(f"no data link to dashboard {uid} among {links}")


def render_link(url: str, values: dict[str, str]) -> str:
    """Substitute ``${__data.fields.X}`` / ``${__value.raw}`` / ``$var`` the way a click does."""
    def field(m: re.Match[str]) -> str:
        return urllib.parse.quote(values[m.group(1)], safe="")
    url = re.sub(r"\$\{__data\.fields\.\"?([A-Za-z0-9_.]+)\"?(?::[a-z]+)?\}", field, url)
    for key, val in values.items():
        url = url.replace("${" + key + "}", val).replace("$" + key, val)
    return url


def query_params(url: str) -> dict[str, list[str]]:
    return urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)


__all__ = ["Grafana", "fabric_sink_has_trace", "grafana", "link_to", "panel_links", "panels",
           "prom_exemplar_trace_ids", "prom_query", "prom_value", "query_params", "render_link",
           "service_info", "trace", "wait_trace"]
