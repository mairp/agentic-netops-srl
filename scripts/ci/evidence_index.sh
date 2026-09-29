#!/usr/bin/env bash
# evidence_index.sh — T154 (SC-040, NFR-013): the P11 run index.
#
# usage: evidence_index.sh --out <index.json> [--exclude <run-dir>=<reason>]... <run-dir>...
#
# Runs `verify_evidence.sh` over every run directory given and writes one JSON
# index: per run its directory, the verifier's exit status and last line, and
# per record its id, kind, check id, exit status, UTC time and record_sha256 —
# the hashes the verifier has just re-checked, so the index names exactly what
# was audited. The index is written only as a whole (tmp + mv). Exit 1 when any
# run fails verification — the index is still written, carrying the failure,
# because a run that failed is recorded, never dropped (SC-040). Exit 2: usage.
# --exclude lists a run directory that is deliberately not audited — a cycle
# stopped before it wrote anything, say — under `excluded` with its stated
# reason and its record count, so an exclusion is visible, never silent. An
# empty reason, a missing directory, or a directory both excluded and audited is
# a usage error.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="${VERIFY_EVIDENCE:-$ROOT/scripts/lib/verify_evidence.sh}"

usage() { echo "usage: evidence_index.sh --out <index.json> [--exclude <run-dir>=<reason>]... <run-dir>..." >&2; exit 2; }
out=""
if [[ "${1:-}" == "--out" ]]; then out="${2:-}"; shift 2 || true; fi
vtmp="$(mktemp -d)"; trap 'rm -rf "$vtmp"' EXIT
: >"$vtmp/excluded.tsv"
while [[ "${1:-}" == "--exclude" ]]; do
  spec="${2:-}"; shift 2 || usage
  xd="${spec%%=*}"; why="${spec#*=}"
  [[ "$spec" == *=* && -n "$xd" && -n "${why// /}" ]] || { echo "evidence-index: FAIL --exclude ${spec}: a directory and a non-empty reason are required" >&2; exit 2; }
  [[ -d "$xd" ]] || { echo "evidence-index: FAIL excluded ${xd} is not a directory" >&2; exit 2; }
  printf '%s\t%s\n' "$(realpath "$xd")" "$why" >>"$vtmp/excluded.tsv"
done
[[ -n "$out" && $# -ge 1 ]] || usage
for d in "$@"; do
  if [[ -d "$d" ]] && cut -f1 "$vtmp/excluded.tsv" | grep -qxF "$(realpath "$d")"; then
    echo "evidence-index: FAIL ${d} is both excluded and audited" >&2; exit 2
  fi
done
i=0
for d in "$@"; do
  [[ -d "$d" ]] || { echo "evidence-index: FAIL ${d} is not a directory" >&2; exit 2; }
  rc=0; bash "$VERIFY" "$d" >"$vtmp/$i.out" 2>&1 || rc=$?
  printf '%s\t%s\n' "$d" "$rc" >>"$vtmp/runs.tsv"
  i=$((i + 1))
done

python3 - "$vtmp" "$out" <<'PY'
import datetime, json, os, sys
vtmp, out = sys.argv[1], sys.argv[2]
runs, failed = [], 0
for n, line in enumerate(open(os.path.join(vtmp, "runs.tsv"))):
    d, rc = line.rstrip("\n").split("\t"); rc = int(rc)
    lines = [l for l in open(os.path.join(vtmp, f"{n}.out")).read().splitlines() if l.strip()]
    recs = []
    for f in sorted(os.listdir(d)):
        if not f.endswith(".json"):
            continue
        try:
            r = json.load(open(os.path.join(d, f)))
        except Exception:
            continue
        if not isinstance(r, dict) or r.get("schema") != "agentic-netops.evidence/v1":
            continue
        recs.append({k: r.get(k) for k in ("id", "kind", "check_id", "exit_status", "utc_time", "record_sha256")})
    failed += rc != 0
    runs.append({
        "evidence_dir": os.path.relpath(os.path.abspath(d)),
        "verify_evidence_exit": rc,
        "verify_evidence_verdict": lines[-1] if lines else "",
        "records": recs,
        "record_count": len(recs),
        "negative_controls": sum(1 for r in recs if r["kind"] == "negative_control"),
    })
excluded = []
for line in open(os.path.join(vtmp, "excluded.tsv")):
    d, why = line.rstrip("\n").split("\t", 1)
    n = sum(1 for f in os.listdir(d) if f.endswith(".json"))
    excluded.append({"evidence_dir": os.path.relpath(d), "reason": why, "json_files": n, "audited": False})
idx = {
    "schema": "agentic-netops.p11-evidence-index/v1",
    "excluded": excluded,
    "generated_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "generator": "scripts/ci/evidence_index.sh",
    "runs": runs,
    "all_verified": failed == 0,
}
tmp = out + ".tmp"
os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
with open(tmp, "w") as fh:
    json.dump(idx, fh, indent=2, sort_keys=True); fh.write("\n")
os.replace(tmp, out)
print(f"evidence-index: {len(runs)} run(s), {failed} failed verification, {len(excluded)} excluded with a reason -> {out}")
sys.exit(1 if failed else 0)
PY
