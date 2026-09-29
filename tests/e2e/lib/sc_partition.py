#!/usr/bin/env python3
"""sc_partition.py — reads tests/e2e/sc_partition.yaml for tests/e2e/acceptance.sh (T175, T151;
SC-025, NFR-006, NFR-013) and for tests/unit/acceptance/sc_partition_test.sh.

Subcommands (all take --partition <yaml>, default: the one beside this directory):

  list      one line per criterion / additional / retired entry:  <id> <side> <checks…>
  validate  --spec <spec.md> --denylist <file> [--root <dir>]
            fails (exit 1), one `FAIL <offender>: <why>` line each, when
              - a success criterion of spec.md (`- **SC-NNN**`) is missing from the partition,
                appears more than once (criteria[] and retired[] together), or the partition
                names one spec.md does not define; a criterion spec.md marks *Retired* is live;
              - an entry's side / checks shape is wrong, or names a check checks{} lacks;
              - a check lacks run (non-manual), has an unknown stage, a lifecycle step missing;
              - a check a control-plane criterion (or the control-plane half of a `both` one, or a
                control-plane `additional`) runs reaches for a tier workload: its `run` — and, for
                `make <target>`, that target's recipe — contains a deny-list token;
              - a file a check names (refs[], and the script / test paths of its run, resolved
                after any leading `cd <dir> &&`) does not exist, or a `make <target>` is missing
                from the Makefile or still `not implemented`.
  plan      --mode full|control-plane-only [--cycles N]
            the ordered steps, one TSV line each:
              <scope> <check> <kind> <attach|-> <run>
            scope: offline | cycle-<n> | standing | closing ; kind: offline | lifecycle:<step> |
            live:control-plane | live:tier | closing ; flags in kind after '+': +tier-absent
  report    --mode … --plan <plan.tsv> --results <results.tsv> [--plan-only]
            results TSV: <scope> <check> <rc> [ok|ok-after-retry|FAIL [first-exit=<rc>]]
                         or  <scope> <check> SKIP <reason>
            (ok-after-retry: failed once, passed on its one re-run — counted as passed and
            listed by name; operator decision 2026-09-27-t151-one-retry)
            prints every criterion's status (PASS | FAIL | not run: <reason> | retired
            (tombstone)), the additional requirements, and the summary with its denominator.
            Exit 0 only if no criterion counted by the mode failed (control-plane-only: 100% of
            the RUN control-plane criteria passed, at least one ran). Not run is never passed.
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import sys
from collections import OrderedDict, defaultdict

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
DEFAULT_PARTITION = os.path.join(ROOT, "tests", "e2e", "sc_partition.yaml")

SIDES = ("control-plane", "tier", "both")
STAGES = ("offline", "lifecycle", "live", "closing")
STEPS = ("deploy", "redeploy", "deploy-tier", "destroy", "redestroy")
STEP_ORDER_PRE = ("deploy", "redeploy")
STEP_ORDER_POST = ("destroy", "redestroy")
SPEC_SC = re.compile(r"^- \*\*(SC-\d{3})\*\*:?(.*)$")


def load(path):
    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f) or {}
    doc.setdefault("retired", [])
    doc.setdefault("criteria", [])
    doc.setdefault("additional", [])
    doc.setdefault("checks", {})
    return doc


def halves(entry):
    """(control-plane checks, tier checks) of a criterion / additional entry."""
    side = entry.get("side")
    if side == "both":
        return list(entry.get("control_plane") or []), list(entry.get("tier") or [])
    if side == "control-plane":
        return list(entry.get("checks") or []), []
    if side == "tier":
        return [], list(entry.get("checks") or [])
    return [], []


# ------------------------------------------------------------------------------------------- sets

def check_sets(doc):
    """(control-plane check ids, tier check ids) — every check each side references."""
    cp, tier = OrderedDict(), OrderedDict()
    for e in doc["criteria"] + doc["additional"]:
        c, t = halves(e)
        for x in c:
            cp[x] = True
        for x in t:
            tier[x] = True
    return cp, tier


def plan(doc, mode, cycles):
    checks = doc["checks"]
    cp, tier = check_sets(doc)
    order = list(checks.keys())
    steps = []

    def attach_of(c):
        a = checks[c].get("attach") or []
        return ",".join(a) if a else "-"

    def emit(scope, cid, kind):
        steps.append((scope, cid, kind, attach_of(cid), checks[cid]["run"]))

    def live_kind(cid, side):
        k = "live:" + side
        if checks[cid].get("requires") == "tier-absent":
            k += "+tier-absent"
        return k

    def stage(c):
        return checks[c].get("stage")

    manual = {c for c in order if checks[c].get("mode") == "manual"}
    referenced = [c for c in order if (c in cp or c in tier) and c not in manual]
    if mode == "control-plane-only":
        wanted = [c for c in referenced if c in cp]
        for c in wanted:
            if stage(c) == "offline":
                emit("offline", c, "offline")
        live = [c for c in wanted if stage(c) == "live"]
        first = [c for c in live if checks[c].get("only") == "control-plane-only"]
        for c in first + [c for c in live if c not in first]:
            emit("standing", c, live_kind(c, "control-plane"))
    else:
        for c in referenced:
            if stage(c) == "offline":
                emit("offline", c, "offline")
        by_step = defaultdict(list)
        for c in referenced:
            if stage(c) == "lifecycle":
                by_step[checks[c].get("step")].append(c)
        cp_live = [c for c in referenced if c in cp and stage(c) == "live"
                   and checks[c].get("only") != "control-plane-only"]
        tier_live = [c for c in referenced if c in tier and c not in cp and stage(c) == "live"]
        for n in range(1, cycles + 1):
            scope = f"cycle-{n}"
            for s in STEP_ORDER_PRE:
                for c in by_step[s]:
                    emit(scope, c, "lifecycle:" + s)
            for c in cp_live:
                emit(scope, c, live_kind(c, "control-plane"))
            for c in by_step["deploy-tier"]:
                emit(scope, c, "lifecycle:deploy-tier")
            for c in tier_live:
                emit(scope, c, live_kind(c, "tier"))
            for s in STEP_ORDER_POST:
                for c in by_step[s]:
                    emit(scope, c, "lifecycle:" + s)
    for c in order:
        if stage(c) == "closing" and c not in manual:
            emit("closing", c, "closing")
    return steps


# --------------------------------------------------------------------------------------- validate

def spec_criteria(spec):
    ids, retired = [], set()
    with open(spec, encoding="utf-8") as f:
        for line in f:
            m = SPEC_SC.match(line.rstrip("\n"))
            if m:
                ids.append(m.group(1))
                if m.group(2).strip().startswith("*Retired"):
                    retired.add(m.group(1))
    return ids, retired


def read_denylist(path):
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = re.sub(r"\s+#.*$", "", line).strip()
            if line and not line.startswith("#"):
                out.append(line)
    return out


def make_recipes(root):
    """target -> recipe text (the lines after `target:` up to the next non-recipe line)."""
    recipes = {}
    path = os.path.join(root, "Makefile")
    if not os.path.isfile(path):
        return recipes
    cur = None
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^([A-Za-z0-9_.-]+):(?!=)", line)
            if m:
                cur = m.group(1)
                recipes[cur] = ""
                continue
            if cur and line.startswith("\t"):
                recipes[cur] += line
            elif cur and line.strip() and not line.startswith("\t"):
                cur = None
    return recipes


PATHISH = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_./-]*/[A-Za-z0-9_.-]+\.(sh|py|ya?ml|json)$")


def run_files(run):
    """repository-relative files a run command names (after a leading `cd <dir> &&`)."""
    base = ""
    files = []
    for seg in re.split(r"&&|;|\|\|", run):
        try:
            toks = shlex.split(seg)
        except ValueError:
            toks = seg.split()
        if toks and toks[0] == "cd" and len(toks) > 1:
            base = os.path.normpath(os.path.join(base, toks[1]))
            continue
        for t in toks:
            if "$" in t or "=" in t:
                continue
            if PATHISH.match(t):
                files.append(os.path.normpath(os.path.join(base, t)) if base else t)
    return files


def make_targets(run):
    out = []
    for seg in re.split(r"&&|;|\|\|", run):
        toks = seg.split()
        if toks and toks[0] == "make":
            out += [t for t in toks[1:] if not t.startswith("-") and "=" not in t]
    return out


def validate(doc, spec, denylist, root):
    fails = []
    checks = doc["checks"]
    spec_ids, spec_retired = spec_criteria(spec)
    seen = defaultdict(list)
    for where in ("criteria", "retired"):
        for e in doc[where]:
            seen[e.get("id")].append(where)
    for sc in spec_ids:
        n = len(seen.get(sc, []))
        if n == 0:
            fails.append(f"FAIL {sc}: defined in spec.md but missing from the partition (criteria[] / retired[])")
        elif n > 1:
            fails.append(f"FAIL {sc}: appears {n} times in the partition ({', '.join(seen[sc])}) — exactly once")
    for sc in seen:
        if sc not in spec_ids:
            fails.append(f"FAIL {sc}: in the partition but not a success criterion of spec.md")
    for e in doc["criteria"]:
        if e.get("id") in spec_retired:
            fails.append(f"FAIL {e.get('id')}: spec.md marks it Retired — it belongs under retired[]")

    for where in ("criteria", "additional"):
        for e in doc[where]:
            i, side = e.get("id"), e.get("side")
            if side not in SIDES:
                fails.append(f"FAIL {i}: side '{side}' is not one of {', '.join(SIDES)}")
                continue
            if side == "both":
                if not e.get("control_plane") or not e.get("tier") or e.get("checks"):
                    fails.append(f"FAIL {i}: a `both` criterion names control_plane: and tier: (and no checks:)")
            elif not e.get("checks") or e.get("control_plane") or e.get("tier"):
                fails.append(f"FAIL {i}: a `{side}` criterion names checks: only")
            if e.get("aggregate") not in (None, "control-plane"):
                fails.append(f"FAIL {i}: aggregate '{e.get('aggregate')}' is not control-plane")
            c, t = halves(e)
            for x in c + t:
                if x not in checks:
                    fails.append(f"FAIL {i}: names check '{x}', which checks{{}} does not define")

    recipes = make_recipes(root)
    deny = denylist
    cp, _ = check_sets(doc)
    for cid, c in checks.items():
        c = c or {}
        manual = c.get("mode") == "manual"
        if c.get("mode") not in (None, "manual"):
            fails.append(f"FAIL check {cid}: mode '{c.get('mode')}' is not manual")
        if manual and not c.get("task"):
            fails.append(f"FAIL check {cid}: a manual check names its task:")
        if not manual:
            if not c.get("run"):
                fails.append(f"FAIL check {cid}: no run:")
            if c.get("stage") not in STAGES:
                fails.append(f"FAIL check {cid}: stage '{c.get('stage')}' is not one of {', '.join(STAGES)}")
            if c.get("stage") == "lifecycle" and c.get("step") not in STEPS:
                fails.append(f"FAIL check {cid}: lifecycle step '{c.get('step')}' is not one of {', '.join(STEPS)}")
        if c.get("requires") not in (None, "tier-absent"):
            fails.append(f"FAIL check {cid}: requires '{c.get('requires')}' is not tier-absent")
        if c.get("only") not in (None, "control-plane-only"):
            fails.append(f"FAIL check {cid}: only '{c.get('only')}' is not control-plane-only")
        run = c.get("run") or ""
        for ref in c.get("refs") or []:
            if not os.path.exists(os.path.join(root, ref)):
                fails.append(f"FAIL check {cid}: refs file '{ref}' does not exist")
        for fpath in run_files(run):
            if not os.path.exists(os.path.join(root, fpath)):
                fails.append(f"FAIL check {cid}: run names '{fpath}', which does not exist")
        for t in make_targets(run):
            if t not in recipes:
                fails.append(f"FAIL check {cid}: run calls `make {t}`, which the Makefile does not define")
            elif "not_implemented" in recipes[t]:
                fails.append(f"FAIL check {cid}: run calls `make {t}`, which is still `not implemented`")
        if cid in cp:
            text = run + "\n" + "".join(recipes.get(t, "") for t in make_targets(run))
            hits = [d for d in deny if d.lower() in text.lower()]
            if hits:
                fails.append(f"FAIL check {cid}: a control-plane check reaches for the tier "
                             f"(deny-list: {', '.join(hits)}) — run: {run}")
    return fails


# ----------------------------------------------------------------------------------------- report

def read_tsv(path):
    rows = []
    if path and os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if line:
                    rows.append(line.split("\t"))
    return rows


def report(doc, mode, plan_rows, result_rows, plan_only):
    checks = doc["checks"]
    cp_only = mode == "control-plane-only"
    expected = defaultdict(int)
    for r in plan_rows:
        expected[r[1]] += 1
    ran = defaultdict(list)      # check -> [rc]
    skipped = defaultdict(list)  # check -> [reason]
    retried = []                 # "<scope>/<check> (first-exit=N)" — passed on the one re-run
    for r in result_rows:
        if len(r) >= 4 and r[2] == "SKIP":
            skipped[r[1]].append(r[3])
        elif len(r) >= 3:
            ran[r[1]].append(r[2])
            if len(r) >= 4 and r[3] == "ok-after-retry":
                retried.append(f"{r[0]}/{r[1]}" + (f" ({r[4]})" if len(r) >= 5 and r[4] else ""))

    def check_status(cid, side):
        c = checks.get(cid) or {}
        if c.get("mode") == "manual":
            return "notrun", f"manual ({c.get('task', '?')})"
        if cp_only and side == "tier":
            return "notrun", "tier absent"
        if expected[cid] == 0:
            if c.get("stage") == "lifecycle":
                return "notrun", f"lifecycle step {cid} (cycles only)"
            if c.get("only") == "control-plane-only":
                return "notrun", f"{cid} runs only under CONTROL_PLANE_ONLY=1"
            return "notrun", f"{cid} not in this plan"
        if plan_only:
            return "planned", f"{cid} x{expected[cid]}"
        bad = [rc for rc in ran[cid] if rc != "0"]
        if bad:
            return "fail", f"{cid} exit {','.join(sorted(set(bad)))}"
        if skipped[cid]:
            return "notrun", f"{cid} skipped: {'; '.join(sorted(set(skipped[cid])))}"
        if len(ran[cid]) < expected[cid]:
            return "notrun", f"{cid} not reached ({len(ran[cid])}/{expected[cid]} runs)"
        return "pass", cid

    def half_status(cids, side):
        if not cids:
            return None
        if cp_only and side == "tier":
            return "notrun", "tier absent"
        sts = [check_status(c, side) for c in cids]
        for want in ("fail", "notrun", "planned"):
            hit = [d for s, d in sts if s == want]
            if hit:
                if want == "notrun" and all(d.startswith("manual") for d in hit):
                    return want, hit[0]
                return want, "; ".join(hit)
        return "pass", ""

    def combine(a, b):
        parts = [p for p in (a, b) if p]
        for want in ("fail", "notrun", "planned"):
            if any(p[0] == want for p in parts):
                return want
        return "pass"

    def label(st):
        s, d = st
        return {"pass": "PASS", "fail": f"FAIL ({d})", "planned": f"would run: {d}"}.get(
            s, f"not run: {d}")

    rows = []  # (id, side, cp_status, tier_status, overall, aggregate)
    for e in doc["criteria"]:
        c, t = halves(e)
        cs, ts = half_status(c, "control-plane"), half_status(t, "tier")
        rows.append([e["id"], e["side"], cs, ts, combine(cs, ts), e.get("aggregate")])
    # SC-025-style aggregate: fails when any OTHER control-plane criterion (or half) failed
    failed_cp = [r[0] for r in rows if r[2] and r[2][0] == "fail"]
    for r in rows:
        if r[5] == "control-plane":
            others = [x for x in failed_cp if x != r[0]]
            if others and not plan_only:
                r[2] = ("fail", (r[2][1] + "; " if r[2][0] == "fail" else "")
                        + "aggregate: control-plane criteria failed: " + ", ".join(others))
                r[4] = "fail"

    title = "acceptance plan" if plan_only else "acceptance result"
    print(f"== {title} ({mode})")
    for r in rows:
        i, side, cs, ts = r[0], r[1], r[2], r[3]
        if side == "both":
            line = f"{i} [both] control-plane half: {label(cs)}; tier half: {label(ts)}"
        else:
            line = f"{i} [{side}] {label(cs or ts)}"
        print(line)
    for e in doc["retired"]:
        print(f"{e['id']} retired (tombstone) — {e.get('reason', '')}")
    add_fail = []
    if doc["additional"]:
        print("-- additional requirements (not counted in the criteria denominator)")
        for e in doc["additional"]:
            c, t = halves(e)
            st = half_status(c or t, "control-plane" if c else "tier")
            print(f"{e['id']} [{e['side']}] {label(st)}")
            if st[0] == "fail" and (e["side"] != "tier" or not cp_only):
                add_fail.append(e["id"])

    cp_rows = [r for r in rows if r[2]]
    n_cp = sum(1 for r in cp_rows if r[1] == "control-plane")
    n_both = len(cp_rows) - n_cp
    tier_rows = [r for r in rows if r[1] == "tier"]
    if cp_only:
        counted = [(r[0], r[2][0]) for r in cp_rows]
    else:
        counted = [(r[0], r[4]) for r in rows]
    passed = [i for i, s in counted if s == "pass"]
    failed = [i for i, s in counted if s == "fail"]
    notrun = [i for i, s in counted if s == "notrun"]
    planned = [i for i, s in counted if s == "planned"]
    run_n = len(passed) + len(failed)
    print("== summary")
    if cp_only:
        print(f"control-plane criteria (denominator): {len(cp_rows)} "
              f"({n_cp} control-plane + {n_both} control-plane halves of both)")
        print(f"tier criteria: {len(tier_rows)} not run: tier absent; tier halves of both: {n_both} not run: tier absent")
    else:
        print(f"criteria (denominator): {len(rows)} ({n_cp} control-plane, {len(tier_rows)} tier, {n_both} both)")
    print(f"retired: {len(doc['retired'])} (tombstone, not counted)")
    if plan_only:
        print(f"planned: {len(planned)}; not run by this plan: {len(notrun)} ({', '.join(notrun) or '-'})")
        return 0
    print(f"run: {run_n}; passed: {len(passed)}; failed: {len(failed)} ({', '.join(failed) or '-'}); "
          f"not run (never counted as passed): {len(notrun)} ({', '.join(notrun) or '-'})")
    if add_fail:
        print(f"additional requirements failed: {', '.join(add_fail)}")
    print(f"steps passed only on their one re-run (ok-after-retry): {len(retried)}"
          + (": " + "; ".join(retried) if retried else ""))
    ok = not failed and not add_fail and run_n > 0
    pct = (100 * len(passed) // run_n) if run_n else 0
    scope = "of the run control-plane criteria" if cp_only else "of the run criteria"
    print(f"{'PASS' if ok else 'FAIL'}: {len(passed)}/{run_n} ({pct}%) {scope} passed")
    return 0 if ok else 1


# ------------------------------------------------------------------------------------------- main

def main(argv):
    ap = argparse.ArgumentParser(prog="sc_partition.py")
    ap.add_argument("--partition", default=DEFAULT_PARTITION)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    v = sub.add_parser("validate")
    v.add_argument("--spec", required=True)
    v.add_argument("--denylist", required=True)
    v.add_argument("--root", default=ROOT)
    p = sub.add_parser("plan")
    p.add_argument("--mode", choices=("full", "control-plane-only"), required=True)
    p.add_argument("--cycles", type=int, default=3)
    r = sub.add_parser("report")
    r.add_argument("--mode", choices=("full", "control-plane-only"), required=True)
    r.add_argument("--plan", required=True)
    r.add_argument("--results", default="")
    r.add_argument("--plan-only", action="store_true")
    a = ap.parse_args(argv)
    doc = load(a.partition)

    if a.cmd == "list":
        for e in doc["criteria"] + doc["additional"]:
            c, t = halves(e)
            print(e["id"], e["side"], " ".join(c + (["|"] if c and t else []) + t))
        for e in doc["retired"]:
            print(e["id"], "retired")
        return 0
    if a.cmd == "validate":
        fails = validate(doc, a.spec, read_denylist(a.denylist), a.root)
        for f in fails:
            print(f)
        if fails:
            print(f"sc_partition: {len(fails)} problem(s) in {a.partition}")
            return 1
        print(f"sc_partition: OK {a.partition}")
        return 0
    if a.cmd == "plan":
        if a.cycles < 1:
            print("sc_partition: --cycles must be >= 1", file=sys.stderr)
            return 2
        for s in plan(doc, a.mode, a.cycles):
            print("\t".join(s))
        return 0
    if a.cmd == "report":
        return report(doc, a.mode, read_tsv(a.plan), read_tsv(a.results), a.plan_only)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
