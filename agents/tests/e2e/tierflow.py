"""Operator-side driver of the live pipeline for the US4 e2e suites (T103, T173).

Every call is one ``POST /agent/prompt/stream`` as the generated operator, exactly what an operator
sends; nothing here reaches past the supervisor's HTTP surface except the read-only cluster checks
the suites make through ``kubectl``.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any

from conftest import AGENTS_NS, INTENT_NS, http, kjson, kubectl

ALLOCATION_NS = "agentic-netops-allocation"
CORRELATION_LABEL = "agentic-netops.io/correlation-id"


def operator_login() -> tuple[str, str]:
    import base64

    secret = kjson("-n", AGENTS_NS, "get", "secret", "operator-credentials")
    return (base64.b64decode(secret["data"]["username"]).decode(),
            base64.b64decode(secret["data"]["password"]).decode())


@dataclass
class Turn:
    chunks: list[dict[str, Any]]
    started: float
    ended: float

    @property
    def thread_id(self) -> str:
        return next(c["thread_id"] for c in self.chunks if c.get("thread_id"))

    @property
    def correlation_id(self) -> str:
        return next(c["correlation_id"] for c in self.chunks if c.get("correlation_id"))

    def last(self) -> dict[str, Any]:
        return self.chunks[-1]

    def of(self, kind: str) -> list[dict[str, Any]]:
        return [c for c in self.chunks if c.get("type") == kind]

    def stage_payload(self, stage: str) -> dict[str, Any] | None:
        for c in self.chunks:
            if c.get("type") == "stage" and c.get("stage") == stage and "payload" in c:
                return c["payload"]
        return None

    def confirmation(self) -> dict[str, Any] | None:
        found = self.of("confirmation_request")
        return found[-1] if found else None

    def text(self) -> str:
        import json

        return "\n".join(json.dumps(c, sort_keys=True) for c in self.chunks)


def ask(prompt: str, thread_id: str | None = None, *, login: tuple[str, str] | None = None,
        timeout: float = 600) -> Turn:
    body: dict[str, Any] = {"prompt": prompt}
    if thread_id:
        body["thread_id"] = thread_id
    started = time.monotonic()
    resp = http("POST", "/agent/prompt/stream", auth=login or operator_login(), body=body,
                timeout=timeout)
    ended = time.monotonic()
    assert resp.status == 200, f"stream answered {resp.status}: {resp.body[:400]!r}"
    return Turn(resp.chunks(), started, ended)


@dataclass
class Service:
    """One service driven through both confirmations."""

    prompt: str
    turns: list[Turn] = field(default_factory=list)
    network: str | None = None
    interpretation: dict[str, Any] | None = None
    assignment: dict[str, Any] | None = None
    approval_to_converged_s: float | None = None

    @property
    def thread_id(self) -> str:
        return self.turns[0].thread_id

    @property
    def correlation_id(self) -> str:
        return self.turns[0].correlation_id


def request_to_confirmation(prompt: str, *, attempts: int = 3) -> Service:
    """Send the request; answer nothing. Retries a fresh thread when the model asks for a
    clarification (the model is real, its phrasing is not under test here)."""
    last: Turn | None = None
    for _ in range(attempts):
        turn = ask(prompt)
        last = turn
        conf = turn.confirmation()
        if conf and conf.get("stage") == "mapper":
            svc = Service(prompt, [turn])
            svc.interpretation = turn.stage_payload("mapper")
            return svc
    raise AssertionError(f"no first confirmation for {prompt!r}; last turn:\n"
                         f"{last.text() if last else ''}")


def confirm_interpretation(svc: Service) -> Turn:
    turn = ask("yes", svc.thread_id)
    svc.turns.append(turn)
    svc.assignment = turn.stage_payload("allocator")
    conf = turn.confirmation()
    assert conf and conf.get("stage") == "allocator", f"no second confirmation:\n{turn.text()}"
    return turn


def approve_deployment(svc: Service) -> Turn:
    turn = ask("yes", svc.thread_id, timeout=900)
    svc.turns.append(turn)
    for c in turn.chunks:
        for r in c.get("resources") or []:
            if r.get("kind") == "Network":
                svc.network = r["name"]
    final = turn.last()
    if final.get("status") == "COMPLETED":
        svc.approval_to_converged_s = turn.ended - turn.started
    return turn


def provision(prompt: str) -> Service:
    svc = request_to_confirmation(prompt)
    confirm_interpretation(svc)
    turn = approve_deployment(svc)
    assert turn.last().get("status") == "COMPLETED", f"not converged:\n{turn.text()}"
    return svc


def remove(network: str) -> list[Turn]:
    """A removal through the tier: the request, then both confirmations."""
    turns = [ask(f"Remove the service {network}")]
    for _ in range(2):
        if not turns[-1].confirmation():
            break
        turns.append(ask("yes", turns[-1].thread_id, timeout=900))
    return turns


def status(network: str) -> Turn:
    return ask(f"What is the status of {network}?")


def networks() -> dict[str, dict[str, Any]]:
    items = kjson("-n", INTENT_NS, "get", "networks.fabric.agentic-netops.io")["items"]
    return {i["metadata"]["name"]: i for i in items}


def network(name: str) -> dict[str, Any] | None:
    return networks().get(name)


def claims(selector: str | None = None) -> list[dict[str, Any]]:
    args = ["-n", ALLOCATION_NS, "get", "identifierclaims.fabric.agentic-netops.io"]
    if selector:
        args += ["-l", selector]
    return kjson(*args)["items"]


def claims_of(correlation_id: str) -> list[dict[str, Any]]:
    return claims(f"{CORRELATION_LABEL}={correlation_id}")


def claim_snapshot() -> set[str]:
    return {f"{c['metadata']['name']}={(c.get('status') or {}).get('value')}"
            for c in claims()}


def wait_gone(name: str, timeout: float = 300) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if network(name) is None:
            return
        time.sleep(3)
    raise AssertionError(f"Network/{name} still present after {timeout:.0f}s")


def delete_with_kubectl(name: str) -> None:
    kubectl("-n", INTENT_NS, "delete", "networks.fabric.agentic-netops.io", name,
            "--wait=false")


# --------------------------------------------------------------------------------------------------
# the analytics store (ClickHouse): the audit record and the tier metrics — read-only (T103)
# --------------------------------------------------------------------------------------------------


def store_query(sql: str, timeout: float = 120) -> list[dict[str, Any]]:
    """Rows of one read-only query to the agent-analytics store, asked from inside its pod with the
    container's own credentials (never read onto the host); ``sql`` must end in FORMAT
    JSONEachRow. The query goes on stdin so no quoting reaches a shell."""
    import json
    import subprocess

    from conftest import CONTEXT

    proc = subprocess.run(  # noqa: S603
        ["kubectl", "--context", CONTEXT, "-n", AGENTS_NS, "exec", "-i",  # noqa: S607
         "clickhouse-0", "-c", "clickhouse", "--", "bash", "-c",
         'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD"'],
        input=sql, capture_output=True, text=True, timeout=timeout)
    assert proc.returncode == 0, f"store query failed rc={proc.returncode}: {proc.stderr[-400:]}"
    return [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]


AUDIT_EVENTS_SQL = (
    "SELECT toString(Timestamp) AS span_ts, ServiceName AS service, TraceId AS trace_id, "
    "e.1 AS name, e.2 AS attrs FROM otel.otel_traces "
    "ARRAY JOIN arrayZip(Events.Name, Events.Attributes) AS e "
    "WHERE startsWith(e.1, 'audit.') ORDER BY Timestamp FORMAT JSONEachRow")


def audit_events() -> list[dict[str, Any]]:
    """Every audit span event in the store: ``{span_ts, service, trace_id, name, attrs}``."""
    return store_query(AUDIT_EVENTS_SQL)


def out_of_band_total(change: str) -> float:
    """``agentic_netops_agent_out_of_band_changes_total{change}`` as the store holds it: the
    newest cumulative point per emitting process summed (0 when none exists yet)."""
    # one cumulative series per emitting process: a restarted process starts a new series at 0
    # with a new StartTimeUnix, so the newest point of EVERY series is summed, never only the
    # newest process's
    base = ("SELECT ServiceName AS s, StartTimeUnix AS st, argMax(Value, TimeUnix) AS v "
            "FROM otel.otel_metrics_sum "
            "WHERE MetricName = 'agentic_netops_agent_out_of_band_changes_total' AND ")
    where = {"modified": "Attributes['change'] = 'modified'",
             "deleted": "Attributes['change'] = 'deleted'"}[change]
    rows = store_query(base + where + " GROUP BY s, st FORMAT JSONEachRow")
    return float(sum(r["v"] for r in rows))
