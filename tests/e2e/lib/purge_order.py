#!/usr/bin/env python3
"""purge_order.py — T152's order assertions over one `off.sh --purge-intent-tier` run (User Story 7
scenarios 4a/4b; FR-078, AD-24, AD-26, AD-35, AD-36, AD-46).

The run is observed through a call log written by tests/e2e/lib/kubectl_calllog.sh — one line per
kubectl invocation, `<epoch seconds.nanoseconds>\t<argv joined by spaces>` — plus the run's
evidence directory. Nothing here talks to a cluster.

  purge_order.py refused --calllog F
      scenario 4a: no mutating call, no scale, no exec (the export's only verb) — so no workload
      was scaled and no export ran — and the refusal-decision list was taken (one Networks list).
  purge_order.py remove --calllog F --evidence-dir D --attempt A --networks n1,n2 [--stderr S]
      scenario 4b, in order:
        R1 before the first `scale`, no mutating call and no exec, and exactly one Networks list
           (the refusal-decision list): the only call before the scale-down;
        R2 supervisor, ui and deployer scaled down (ui may be reported absent in S — AD-71)
           before the authoritative list (the first Networks list after a scale) and before the
           export's first exec;
        R3 the delete of the tier-submitted Networks names every one of --networks and comes
           after the authoritative list;
        R4 the audit export artefact audit-export-<A>.ndjson.gz exists and was last written
           before the store's StatefulSet was deleted;
        R5 the usernames record operator-usernames-<A>.json exists and was written before the
           operator-credentials Secret was deleted;
        R6 the intent namespace was deleted only after a re-list (the last Networks list before
           that delete) — and tier-purge-relist-<A>.stdout lists no item;
        R7 the deny-tier-force-release policy and its binding were deleted.
Prints `PASS <rule> …` / `FAIL <rule> …`; exits 1 on any FAIL, 2 on a usage error.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

INTENT_NS = "agentic-netops-intent"
NETWORKS = "networks.fabric.agentic-netops.io"
MUTATING = {"apply", "create", "delete", "patch", "replace", "scale", "annotate", "label", "set",
            "rollout", "edit", "cordon", "drain", "taint"}
QUIESCE = ("supervisor", "ui", "deployer")
STORE = os.environ.get("AUDIT_STORE_STATEFULSET", "clickhouse")
SECRET = "operator-credentials"
VAP = "deny-tier-force-release"


class Call:
    def __init__(self, idx: int, ts: float, argv: list[str]):
        self.idx, self.ts, self.argv = idx, ts, argv

    @property
    def verb(self) -> str:
        skip_value = {"--context", "-n", "--namespace", "--request-timeout", "-c", "--kubeconfig"}
        it = iter(self.argv)
        for a in it:
            if a in skip_value:
                next(it, None)
                continue
            if a.startswith("-"):
                continue
            return a
        return ""

    def has(self, *words: str) -> bool:
        return all(w in self.argv for w in words)

    def __str__(self) -> str:
        return f"#{self.idx} {' '.join(self.argv)}"


def load(path: Path) -> list[Call]:
    calls = []
    for n, line in enumerate(path.read_text().splitlines()):
        if not line.strip():
            continue
        ts, _, rest = line.partition("\t")
        calls.append(Call(n, float(ts), rest.split()))
    return calls


def is_networks_list(c: Call) -> bool:
    return c.verb == "get" and NETWORKS in c.argv and INTENT_NS in c.argv


class Report:
    def __init__(self) -> None:
        self.failed = False

    def judge(self, ok: bool, rule: str, text: str) -> None:
        print(f"{'PASS' if ok else 'FAIL'} {rule} {text}")
        self.failed |= not ok


def refused(calls: list[Call], r: Report) -> None:
    mut = [c for c in calls if c.verb in MUTATING]
    r.judge(not mut, "A1", "no mutating call in the refused purge"
            + ("" if not mut else ": " + "; ".join(map(str, mut))))
    scales = [c for c in calls if c.verb == "scale"]
    r.judge(not scales, "A2", "no tier workload was scaled")
    execs = [c for c in calls if c.verb == "exec"]
    r.judge(not execs, "A3", "no export ran (no exec against the store)")
    lists = [c for c in calls if is_networks_list(c)]
    r.judge(len(lists) >= 1, "A4", f"the refusal-decision list was taken ({len(lists)} Networks list(s))")


def remove(calls: list[Call], evd: Path, attempt: str, networks: list[str], stderr: str, r: Report) -> None:
    scales = [c for c in calls if c.verb == "scale"]
    if not scales:
        r.judge(False, "R1", "no scale call at all — the quiesce never happened")
        return
    first_scale = scales[0].idx
    before = [c for c in calls if c.idx < first_scale]
    bad = [c for c in before if c.verb in MUTATING or c.verb == "exec"]
    lists_before = [c for c in before if is_networks_list(c)]
    r.judge(not bad and len(lists_before) == 1, "R1",
            f"before the scale-down: {len(lists_before)} Networks list (the refusal-decision list), "
            f"{len(bad)} mutating/exec call(s); reads before it: "
            + "; ".join(str(c) for c in before if c.verb not in MUTATING))

    auth = next((c for c in calls if is_networks_list(c) and c.idx > first_scale), None)
    first_exec = next((c for c in calls if c.verb == "exec"), None)
    for d in QUIESCE:
        sc = next((c for c in scales if "deployment" in c.argv and d in c.argv), None)
        if sc is None:
            absent = f"deployment {d} absent" in stderr
            r.judge(absent, "R2", f"{d}: {'reported absent (already at zero, AD-71)' if absent else 'never scaled down'}")
            continue
        ok = auth is not None and sc.idx < auth.idx and (first_exec is None or sc.idx < first_exec.idx)
        r.judge(ok, "R2", f"{d} scaled down at {sc} — before the authoritative list "
                f"({auth or 'MISSING'}) and before the export ({first_exec or 'no exec'})")
    r.judge(first_exec is not None, "R2", f"the export ran after the scale-down ({first_exec or 'no exec'})")

    dele = next((c for c in calls if c.verb == "delete" and NETWORKS in c.argv), None)
    missing = [n for n in networks if dele is None or n not in dele.argv]
    r.judge(dele is not None and auth is not None and dele.idx > auth.idx and not missing, "R3",
            f"the tier-submitted Networks {networks} listed and deleted by name ({dele or 'NO DELETE'})"
            + (f"; missing {missing}" if missing else ""))

    art = evd / f"audit-export-{attempt}.ndjson.gz"
    store_del = next((c for c in calls if c.verb == "delete" and "statefulset" in c.argv and STORE in c.argv), None)
    ok = art.is_file() and store_del is not None and art.stat().st_mtime_ns / 1e9 < store_del.ts
    r.judge(ok, "R4", f"export {art.name} {'exists' if art.is_file() else 'MISSING'}, written "
            f"{art.stat().st_mtime_ns / 1e9 if art.is_file() else '-'} < store deleted "
            f"{store_del.ts if store_del else 'NEVER'}")

    rec = evd / f"operator-usernames-{attempt}.json"
    sec_del = next((c for c in calls if c.verb == "delete" and "secret" in c.argv and SECRET in c.argv), None)
    ok = rec.is_file() and sec_del is not None and rec.stat().st_mtime_ns / 1e9 < sec_del.ts
    r.judge(ok, "R5", f"usernames record {rec.name} {'exists' if rec.is_file() else 'MISSING'}, written "
            f"{rec.stat().st_mtime_ns / 1e9 if rec.is_file() else '-'} < {SECRET} deleted "
            f"{sec_del.ts if sec_del else 'NEVER'}")

    ns_del = next((c for c in calls if c.verb == "delete" and "namespace" in c.argv and INTENT_NS in c.argv), None)
    relist = None
    if ns_del is not None:
        relist = next((c for c in reversed(calls) if c.idx < ns_del.idx and is_networks_list(c)), None)
    out = evd / f"tier-purge-relist-{attempt}.stdout"
    empty = False
    if out.is_file():
        try:
            empty = not json.loads(out.read_text() or "{}").get("items")
        except json.JSONDecodeError:
            empty = False
    r.judge(ns_del is not None and relist is not None and empty, "R6",
            f"namespace {INTENT_NS} deleted at {ns_del or 'NEVER'} after the re-list {relist or 'MISSING'}"
            f", whose record {out.name} lists {'no item' if empty else 'ITEMS or is missing'}")

    vap = [c for c in calls if c.verb == "delete" and VAP in c.argv]
    kinds = {k for c in vap for k in ("validatingadmissionpolicy", "validatingadmissionpolicybinding") if k in c.argv}
    r.judge(len(kinds) == 2, "R7", f"{VAP} policy and binding deleted ({sorted(kinds)})")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=("refused", "remove"))
    p.add_argument("--calllog", required=True, type=Path)
    p.add_argument("--evidence-dir", type=Path)
    p.add_argument("--attempt")
    p.add_argument("--networks", default="")
    p.add_argument("--stderr", type=Path)
    a = p.parse_args()
    if not a.calllog.is_file():
        print(f"FAIL no call log {a.calllog}")
        return 1
    calls = load(a.calllog)
    r = Report()
    if a.mode == "refused":
        refused(calls, r)
    else:
        if not (a.evidence_dir and a.attempt):
            print("usage: remove needs --evidence-dir and --attempt", file=sys.stderr)
            return 2
        stderr = a.stderr.read_text() if a.stderr and a.stderr.is_file() else ""
        remove(calls, a.evidence_dir, a.attempt, [n for n in a.networks.split(",") if n], stderr, r)
    return 1 if r.failed else 0


if __name__ == "__main__":
    sys.exit(main())
