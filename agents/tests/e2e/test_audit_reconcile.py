"""T103 — audit reconciliation (quickstart.md §19; SC-030 tier-originated half, SC-042; FR-078,
FR-102; data-model.md §16, AD-18, AD-36, AD-46, AD-55).

The stream is read from the agent-analytics store (ClickHouse span events ``audit.*``) — NEVER
from Kubernetes Events. Two halves:

* **stream half** — every ``submit`` and ``remove`` event is matched by a recorded
  ``confirmation_2`` ``confirm`` event with the same correlation identifier, principal and resource,
  and carries the submitted-spec hash (a removal's equal to that resource's submission); every
  principal is one of the usernames the run used;
* **live-object half** — every Network the tier created that still exists has a submission in the
  stream whose hash equals its ``intent-submitted-spec-sha256`` annotation, counts equal, and the
  tier wrote nothing to it after an ``out_of_band`` event.

**File-source mode** (``--audit-export <artefact>`` or ``AUDIT_EXPORT=<artefact>``): the stream
half runs from the exported ``audit-export-<attempt>.ndjson.gz`` and the usernames record beside it
(``operator-usernames-<attempt>.stdout``, whose ``username_unchanged`` is read there and only
there) ALONE — neither the store nor the cluster is touched — and the live-object half is reported
skipped, "not run: objects removed", never passed.
"""

from __future__ import annotations

import gzip
import json
import os
import re
import time
from datetime import datetime
from pathlib import Path
from typing import Any

import pytest
from conftest import REPO

SPEC_HASH_ANNOTATION = "agentic-netops.io/intent-submitted-spec-sha256"
CORRELATION_LABEL = "agentic-netops.io/correlation-id"
DEPLOYER_MANAGER = "agentic-netops-intent-deployer"
LAB_EVIDENCE_ROOT = REPO / ".evidence" / "agentic-netops_agentic-netops-fabric"
SETTLE_SECONDS = 45  # a turn's supervisor span (the confirm) ends after the deployer's (the submit)


def export_path(config: pytest.Config) -> Path | None:
    value = config.getoption("--audit-export", default=None) or os.environ.get("AUDIT_EXPORT")
    return Path(value) if value else None


@pytest.fixture(scope="module")
def artefact(request: pytest.FixtureRequest) -> Path | None:
    return export_path(request.config)


# --------------------------------------------------------------------------------------------------
# the two sources of the stream
# --------------------------------------------------------------------------------------------------


def events_from_export(path: Path) -> list[dict[str, Any]]:
    """Audit span events out of the exported rows (one otel_traces row per line)."""
    opener = gzip.open if path.suffix == ".gz" else open
    found: list[dict[str, Any]] = []
    with opener(path, "rt") as fh:  # type: ignore[operator]
        for line in fh:
            if not line.strip():
                continue
            row = json.loads(line)
            names = row.get("Events.Name") or []
            attrs = row.get("Events.Attributes") or []
            for name, a in zip(names, attrs, strict=True):
                if name.startswith("audit."):
                    found.append({"name": name, "attrs": a, "service": row.get("ServiceName")})
    return found


def usernames_record(path: Path) -> dict[str, Any]:
    m = re.fullmatch(r"audit-export-(.+)\.ndjson(\.gz)?", path.name)
    assert m, f"{path.name} is not an audit-export-<attempt>.ndjson.gz artefact"
    rec = path.parent / f"operator-usernames-{m.group(1)}.stdout"
    assert rec.is_file(), f"no usernames record beside the export: {rec}"
    return json.loads(rec.read_text())


def captured_usernames() -> set[str]:
    """The tier-phase username captures (``operator-username-*``) under the lab's evidence root —
    the usernames the run used, derived from the captures themselves while the tier is up."""
    names: set[str] = set()
    for f in LAB_EVIDENCE_ROOT.glob("*/operator-username-*.stdout"):
        for line in f.read_text().splitlines():
            if line.startswith("username:"):
                names.add(line.split(":", 1)[1].strip())
    return names


def resources_of(event: dict[str, Any]) -> list[dict[str, Any]]:
    raw = event["attrs"].get("audit.resources") or "[]"
    items = json.loads(raw) if isinstance(raw, str) else raw
    return [json.loads(r) if isinstance(r, str) else r for r in items]


def names_of(event: dict[str, Any]) -> set[str]:
    return {r["name"] for r in resources_of(event) if r.get("kind") == "Network"}


# --------------------------------------------------------------------------------------------------
# the stream half — pure functions of the event list
# --------------------------------------------------------------------------------------------------


def unconfirmed(events: list[dict[str, Any]]) -> list[str]:
    """Every submit/remove without a confirmation_2 confirm of the same correlation id, principal
    and resource."""
    confirms = [e["attrs"] for e in events if e["name"] == "audit.confirm"
                and str(e["attrs"].get("audit.reason", "")).startswith("confirmation_2 ")]
    problems = []
    for e in events:
        if e["name"] not in ("audit.submit", "audit.remove"):
            continue
        a = e["attrs"]
        kind = "removal" if e["name"] == "audit.remove" else "request"
        match = [c for c in confirms
                 if c.get("audit.correlation_id") == a.get("audit.correlation_id")
                 and c.get("audit.principal") == a.get("audit.principal")
                 and str(c.get("audit.reason", "")).endswith(f" {kind}")
                 and (names_of({"attrs": c}) & names_of(e) or not names_of({"attrs": c}))]
        if not match:
            problems.append(f"{e['name']} cid={a.get('audit.correlation_id')} "
                            f"principal={a.get('audit.principal')} {sorted(names_of(e))}")
    return problems


def hash_problems(events: list[dict[str, Any]]) -> list[str]:
    """Every submission carries its submitted-spec hash; a removal's equals its submission's."""
    submitted: dict[str, str] = {}
    problems = []
    for e in events:
        if e["name"] != "audit.submit":
            continue
        h = e["attrs"].get("audit.submitted_spec_sha256")
        if not h:
            problems.append(f"audit.submit {sorted(names_of(e))} cid="
                            f"{e['attrs'].get('audit.correlation_id')} carries no "
                            "audit.submitted_spec_sha256")
        for n in names_of(e):
            if h:
                submitted[n] = h
    for e in events:
        if e["name"] != "audit.remove":
            continue
        h = e["attrs"].get("audit.submitted_spec_sha256")
        for n in names_of(e):
            if not h:
                problems.append(f"audit.remove {n} carries no audit.submitted_spec_sha256")
            elif n in submitted and submitted[n] != h:
                problems.append(f"audit.remove {n}: hash {h} != submitted {submitted[n]}")
    return problems


def outside(events: list[dict[str, Any]], usernames: set[str]) -> set[str]:
    return {str(e["attrs"].get("audit.principal")) for e in events} - usernames


def record(name: str, payload: Any) -> None:
    evidence = os.environ.get("EVIDENCE_DIR")
    if evidence:
        path = Path(evidence) / "t103" / f"{name}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n")


# --------------------------------------------------------------------------------------------------
# the stream, from whichever source this run has
# --------------------------------------------------------------------------------------------------


def window(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The run's window: ``AUDIT_SINCE`` (an ISO-8601 UTC instant) keeps the events whose
    ``audit.at`` is at or after it — the reconciliation of one run's own decisions, recorded
    with the result; unset keeps every event."""
    since = os.environ.get("AUDIT_SINCE")
    if not since:
        return events
    floor = datetime.fromisoformat(since.replace("Z", "+00:00")).timestamp()
    return [e for e in events if e["attrs"].get("audit.at") and datetime.fromisoformat(
        str(e["attrs"]["audit.at"]).replace("Z", "+00:00")).timestamp() >= floor]


@pytest.fixture(scope="module")
def stream(artefact: Path | None) -> dict[str, Any]:
    if artefact is not None:
        assert artefact.is_file(), f"no export at {artefact}"
        rec = usernames_record(artefact)
        events = window(events_from_export(artefact))
        out = {"source": str(artefact), "since": os.environ.get("AUDIT_SINCE"), "events": events,
               "usernames": set(rec.get("usernames") or []),
               "username_unchanged": rec.get("username_unchanged")}
        record("audit-reconcile-file", {**out, "usernames": sorted(out["usernames"]),
                                        "counts": _counts(events)})
        return out
    import tierflow as tf  # the store is touched in live mode only

    events = window(tf.audit_events())
    # an unmatched submission may be the in-flight turn of another run: settle once and re-read
    if unconfirmed(events):
        time.sleep(SETTLE_SECONDS)
        events = window(tf.audit_events())
    names = captured_usernames()
    out = {"source": "store:otel.otel_traces", "since": os.environ.get("AUDIT_SINCE"),
           "events": events, "usernames": names,
           "username_unchanged": None}
    record("audit-reconcile-live", {**out, "usernames": sorted(names), "counts": _counts(events)})
    return out


def _counts(events: list[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for e in events:
        counts[e["name"]] = counts.get(e["name"], 0) + 1
    return counts


def test_stream_holds_submissions_and_removals(stream: dict[str, Any]) -> None:
    names = {e["name"] for e in stream["events"]}
    assert {"audit.submit", "audit.remove", "audit.confirm"} <= names, _counts(stream["events"])


def test_every_submission_and_removal_has_its_confirmation(stream: dict[str, Any]) -> None:
    problems = unconfirmed(stream["events"])
    assert not problems, "without a matching confirmation_2:\n" + "\n".join(problems)


def test_every_submission_and_removal_carries_the_submitted_spec_hash(
        stream: dict[str, Any]) -> None:
    problems = hash_problems(stream["events"])
    assert not problems, f"{len(problems)} hash problem(s):\n" + "\n".join(problems)


def test_every_principal_is_a_username_the_run_used(stream: dict[str, Any]) -> None:
    usernames = stream["usernames"]
    assert usernames, "no usernames record / capture to reconcile against"
    if stream["username_unchanged"] is not None:  # file mode: read from the record alone
        assert stream["username_unchanged"] is True, (
            f"username_unchanged is false ({sorted(usernames)}): SC-042's measure is invalid")
    else:
        assert len(usernames) == 1, f"more than one captured username: {sorted(usernames)}"
    extra = outside(stream["events"], usernames)
    assert not extra, f"principals outside the usernames the run used: {sorted(extra)}"


# --------------------------------------------------------------------------------------------------
# the live-object half — store and cluster
# --------------------------------------------------------------------------------------------------


def test_live_objects_reconcile_with_the_stream(artefact: Path | None,
                                                stream: dict[str, Any]) -> None:
    if artefact is not None:
        pytest.skip("not run: objects removed")
    import tierflow as tf

    principals_now = tf.operator_login()[0]
    assert principals_now in stream["usernames"], "the live Secret's username was not captured"
    submitted: dict[str, dict[str, Any]] = {}
    for e in stream["events"]:
        if e["name"] == "audit.submit":
            for n in names_of(e):
                submitted[n] = e["attrs"]
    oob_at: dict[str, float] = {}
    for e in stream["events"]:
        if e["name"] == "audit.out_of_band" and e["attrs"].get("audit.reason") == "modified":
            for n in names_of(e):
                oob_at[n] = max(oob_at.get(n, 0.0),
                                datetime.fromisoformat(e["attrs"]["audit.at"]).timestamp())

    def tier_created() -> dict[str, dict[str, Any]]:
        from conftest import INTENT_NS, kjson

        items = kjson("-n", INTENT_NS, "get", "networks.fabric.agentic-netops.io",
                      "--show-managed-fields")["items"]
        return {o["metadata"]["name"]: o for o in items
                if any(m.get("manager") == DEPLOYER_MANAGER
                       for m in o["metadata"].get("managedFields") or [])
                and not o["metadata"].get("deletionTimestamp")}

    live = tier_created()
    missing = [n for n in live if n not in submitted]
    if missing:  # an apply whose trace is not stored yet
        time.sleep(SETTLE_SECONDS)
        stream["events"] = window(tf.audit_events())
        return test_live_objects_reconcile_with_the_stream(artefact, stream)
    problems = []
    for n, obj in live.items():
        a = submitted[n]
        annotation = obj["metadata"].get("annotations", {}).get(SPEC_HASH_ANNOTATION)
        label = obj["metadata"].get("labels", {}).get(CORRELATION_LABEL)
        if a.get("audit.correlation_id") != label:
            problems.append(f"{n}: stream cid {a.get('audit.correlation_id')} != label {label}")
        if a.get("audit.submitted_spec_sha256") != annotation:
            problems.append(f"{n}: stream hash {a.get('audit.submitted_spec_sha256')} != "
                            f"annotation {annotation}")
        if n in oob_at:
            late = [m for m in obj["metadata"].get("managedFields") or []
                    if m.get("manager") == DEPLOYER_MANAGER and m.get("time")
                    and datetime.fromisoformat(m["time"].replace("Z", "+00:00")).timestamp()
                    > oob_at[n]]
            if late:
                problems.append(f"{n}: the tier wrote after its out_of_band event: {late}")
    nets = tf.networks()
    still = {n for n in submitted if n in nets
             and not nets[n]["metadata"].get("deletionTimestamp")}
    record("audit-reconcile-live-objects", {"live_tier_created": sorted(live),
                                            "submitted_still_existing": sorted(still),
                                            "problems": problems})
    assert set(live) == still, (
        f"counts differ: tier-created {sorted(live)} vs submitted-and-existing {sorted(still)}")
    assert not problems, "\n".join(problems)
