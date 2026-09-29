#!/usr/bin/env bash
# verify_evidence.sh — `make verify-evidence` (T012, NFR-013, SC-040, SC-004).
#
# Walks ONE run's EVIDENCE_DIR (as written by scripts/lib/evidence.sh) and fails,
# naming the file, on:
#   1. any record missing an NFR-013 field (NFR013_FIELDS below) or carrying a
#      malformed one;
#   2. a post-edit: a record whose record_sha256 no longer matches its own
#      canonical content, or a raw output / attachment whose sha256 no longer
#      matches what the record captured, or a referenced file that is gone;
#   3. a hand-placed artefact: any file in the directory that no record
#      references (a proof nobody's run captured);
#   4. any readiness check without a recorded FAILING negative control for its
#      check id, captured no later than the check itself — and any negative
#      control that passed, which makes its check defective (SC-040);
#   5. the SC-004 recording rule — this script's and no other's (AD-31, AD-71):
#      a directory that records SC-004 at all fails unless it holds
#        (a) the session half   — a run recording SC-004:session, exit 0;
#        (b) the route half     — a run recording SC-004:route, exit 0;
#        (c) the route half's negative control — a failing negative control for
#            the route half's check id;
#      each with its NFR-013 fields. Fabric readiness alone, or established
#      sessions alone, is never SC-004 evidence.
#
# Which directory: the first argument, else $EVIDENCE_DIR, else the newest run
# directory under .evidence/<cluster>_<lab>/ (EVIDENCE_ROOT overrides
# .evidence). No run, or an empty one, is a failure — never a silent pass.
#
# Exit: 0 all checks pass; 1 a check failed; 2 usage / no evidence to verify.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() { echo "usage: verify_evidence.sh [EVIDENCE_DIR]" >&2; }

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[[ $# -le 1 ]] || { usage; exit 2; }

dir="${1:-${EVIDENCE_DIR:-}}"
if [[ -z "$dir" ]]; then
  eroot="${EVIDENCE_ROOT:-$ROOT/.evidence}"
  # Run directories are .evidence/<cluster>_<lab>/<UTC run id>[-N]/; the run id
  # sorts by time, so the newest is the last in name order across all labs.
  if [[ -d "$eroot" ]]; then
    dir="$(find "$eroot" -mindepth 2 -maxdepth 2 -type d -printf '%f\t%p\n' 2>/dev/null \
      | LC_ALL=C sort | tail -n 1 | cut -f2)"
  fi
  if [[ -z "$dir" ]]; then
    echo "verify-evidence: FAIL no evidence run found under ${eroot} (set EVIDENCE_DIR or pass a run directory)" >&2
    exit 2
  fi
fi
if [[ ! -d "$dir" ]]; then
  echo "verify-evidence: FAIL ${dir} is not a directory" >&2
  exit 2
fi

echo "verify-evidence: ${dir}"
exec python3 - "$dir" <<'PY'
import hashlib, json, os, re, sys

d = sys.argv[1]
fails = []
def fail(f, msg): fails.append(f"FAIL {f}: {msg}")

# The NFR-013 fields: command, UTC time, exit status, device image digest,
# cluster identity, lab identity, raw output (+ its hash) — plus what makes a
# record verifiable (id, kind, check id, record hash). Dotted = nested.
NFR013_FIELDS = [
    "schema", "id", "kind", "check_id", "command", "utc_time", "exit_status",
    "device_image_digest", "cluster.name", "cluster.uid", "lab.name",
    "raw_output.stdout.file", "raw_output.stdout.sha256",
    "raw_output.stderr.file", "raw_output.stderr.sha256", "record_sha256",
]
UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
HEX = re.compile(r"^[0-9a-f]{64}$")

def get(o, dotted):
    for k in dotted.split("."):
        if not isinstance(o, dict) or k not in o:
            return None
        o = o[k]
    return o

def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def canonical(rec):
    body = {k: v for k, v in rec.items() if k != "record_sha256"}
    # Same bytes as `jq -S -c` for the records evidence.sh writes.
    return json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False)

all_files = set()
for base, dirs, files in os.walk(d):
    for f in files:
        all_files.add(os.path.relpath(os.path.join(base, f), d))
records = {}
for f in sorted(all_files):
    if not f.endswith(".json"):
        continue
    try:
        rec = json.load(open(os.path.join(d, f)))
    except Exception as e:
        # A JSON file that is not a record is an unreferenced artefact (below).
        continue
    if isinstance(rec, dict) and str(rec.get("schema", "")).startswith("agentic-netops.evidence/"):
        records[f] = rec

if not records:
    print(f"FAIL {d}: no evidence records (an empty run proves nothing)")
    sys.exit(1)

referenced = set(records)
valid = {}
for f, rec in records.items():
    ok = True
    for field in NFR013_FIELDS:
        v = get(rec, field)
        if v is None or v == "" or v == []:
            fail(f, f"missing NFR-013 field '{field}'"); ok = False
    cmd = rec.get("command")
    if cmd is not None and not (isinstance(cmd, list) and cmd and all(isinstance(x, str) for x in cmd)):
        fail(f, "field 'command' is not a non-empty argv list"); ok = False
    if rec.get("utc_time") and not UTC.match(str(rec["utc_time"])):
        fail(f, f"field 'utc_time' is not a UTC timestamp: {rec['utc_time']!r}"); ok = False
    if "exit_status" in rec and not (isinstance(rec["exit_status"], int) and not isinstance(rec["exit_status"], bool)):
        fail(f, "field 'exit_status' is not an integer"); ok = False
    if rec.get("device_image_digest") and not DIGEST.match(str(rec["device_image_digest"])):
        fail(f, f"field 'device_image_digest' is not sha256:<64 hex>"); ok = False
    if rec.get("kind") not in (None, "run", "negative_control"):
        fail(f, f"unknown kind {rec.get('kind')!r}"); ok = False
    # Post-edit of the record itself.
    rs = rec.get("record_sha256")
    if rs:
        if hashlib.sha256(canonical(rec).encode()).hexdigest() != rs:
            fail(f, "record content changed after capture (record_sha256 mismatch: post-edit)"); ok = False
    # Post-edit or loss of the raw output and attachments.
    files = []
    for stream in ("stdout", "stderr"):
        ref = get(rec, f"raw_output.{stream}")
        if isinstance(ref, dict):
            files.append((f"raw {stream}", ref.get("file"), ref.get("sha256")))
    for a in rec.get("attachments") or []:
        if isinstance(a, dict):
            files.append(("attachment", a.get("file"), a.get("sha256")))
    rdir = os.path.dirname(f)
    for what, name, want in files:
        if not name:
            continue
        rel = os.path.normpath(os.path.join(rdir, name))
        referenced.add(rel)
        p = os.path.join(d, rel)
        if not os.path.isfile(p):
            fail(f, f"{what} '{rel}' is missing"); ok = False
        elif not (want and HEX.match(str(want))) or sha(p) != want:
            fail(f, f"{what} '{rel}' content hash changed after capture (post-edit)"); ok = False
    if ok:
        valid[f] = rec

# The declared-faults ledger (tests/lib/leftovers.sh) is append-only and never attached itself: it
# is admitted when it is byte-identical to the newest snapshot a valid record attached beside it
# (declared-faults.d/NNNN-<id>.json); anything else is a hand edit or an unrecorded append.
for f in sorted(all_files - referenced):
    if os.path.basename(f) == "declared-faults.json":
        sdir = os.path.join(os.path.dirname(f), "declared-faults.d")
        snaps = sorted(r for r in referenced
                       if os.path.dirname(r) == sdir and r in {os.path.normpath(os.path.join(os.path.dirname(v), a.get("file", "")))
                                                              for v, rec in valid.items() for a in (rec.get("attachments") or []) if isinstance(a, dict)})
        if snaps and sha(os.path.join(d, snaps[-1])) == sha(os.path.join(d, f)):
            continue
        fail(f, "declared-faults ledger differs from its newest recorded snapshot (or has none): an unrecorded append or a post-edit")
        continue
    fail(f, "not referenced by any evidence record (hand-placed artefact; NFR-013 admits only run-captured proof)")

# Negative controls, by check id (valid records only).
controls = {}
for f, rec in valid.items():
    if rec.get("kind") == "negative_control":
        controls.setdefault(rec.get("check_id"), []).append((f, rec))
        if rec.get("exit_status") == 0:
            fail(f, f"negative control for '{rec.get('check_id')}' passed on a system without what it checks: "
                    "the check is defective (NFR-013)")

def failing_control_before(check, t):
    for f, rec in controls.get(check, []):
        if rec.get("exit_status") != 0 and str(rec.get("utc_time")) <= str(t):
            return f
    return None

for f, rec in valid.items():
    if rec.get("kind") == "run" and rec.get("readiness") is True:
        if not failing_control_before(rec.get("check_id"), rec.get("utc_time")):
            fail(f, f"readiness check '{rec.get('check_id')}' has no recorded failing negative control "
                    "captured before it (SC-040)")

# SC-004 recording rule (AD-31, AD-71). Every record naming SC-004 counts as
# recording it; its parts are judged on valid records only.
def recs_with(part, pool):
    return [(f, r) for f, r in pool.items() if r.get("kind") == "run" and part in (r.get("records") or [])]
names_sc004 = [f for f, r in records.items() if any(str(x).split(":")[0] == "SC-004" for x in (r.get("records") or []))]
if names_sc004:
    session = [(f, r) for f, r in recs_with("SC-004:session", valid) if r.get("exit_status") == 0]
    route = [(f, r) for f, r in recs_with("SC-004:route", valid) if r.get("exit_status") == 0]
    where = f"{d} (SC-004)"
    if not session:
        fail(where, "records SC-004 without the session half (a passing run recording SC-004:session)")
    if not route:
        fail(where, "records SC-004 without the route half (a passing run recording SC-004:route)")
    elif not any(failing_control_before(r.get("check_id"), r.get("utc_time")) for _, r in route):
        fail(where, "records SC-004 without the route half's negative control "
                    f"(a failing negative control for check '{route[0][1].get('check_id')}')")

# ok-after-retry (operator decision 2026-09-27-t151-one-retry): a step re-run once is recorded
# under <id>.retry1 beside its failed first attempt <id>. Both are ordinary records and both are
# kept; the pair is admitted and SHOWN, never hidden — and a retry that failed as well is shown too.
by_id = {r.get("id"): r for r in records.values() if isinstance(r, dict)}
for rid in sorted(i for i in by_id if isinstance(i, str) and i.endswith(".retry1")):
    first = by_id.get(rid[: -len(".retry1")])
    fx = first.get("exit_status") if first else "absent"
    rx = by_id[rid].get("exit_status")
    word = "ok-after-retry" if rx == 0 else "FAIL-after-retry"
    print(f"{word}: {rid[: -len('.retry1')]} (first attempt exit {fx}; re-run exit {rx})")

# a delta (operator decision 2026-09-28-t151-delta): a directory holding the run-captured record
# acceptance.delta-of is a re-run of failed cycle steps; every acceptance.<check> step record in it
# must be linked there to the results.tsv and step it re-verifies — the link is printed, and a step
# with no link line fails (a delta nobody can trace to its failure proves nothing about T151)
link = by_id.get("acceptance.delta-of")
if isinstance(link, dict):
    lf = os.path.join(d, ((link.get("raw_output") or {}).get("stdout") or {}).get("file") or "")
    linked = {}
    try:
        for ln in open(lf):
            parts = ln.rstrip("\n").split("\t")
            if len(parts) >= 4:
                linked[parts[0]] = parts[1:4]
    except OSError:
        fail(f"{d} (delta)", "acceptance.delta-of names no readable link list")
    for rid in sorted(i for i in by_id if isinstance(i, str) and i.startswith("acceptance.")):
        if rid == "acceptance.delta-of" or rid.endswith(".sealed") or rid.startswith("acceptance.verify-evidence"):
            continue
        chk = rid[len("acceptance."):]
        chk = chk[: -len(".retry1")] if chk.endswith(".retry1") else chk
        if chk not in linked:
            fail(f"{d} (delta)", f"step {chk} is not linked to the failed cycle step it re-verifies")
        else:
            src, scope, outcome = linked[chk]
            print(f"delta: {chk} re-verifies {scope}/{chk} ({outcome}) of {src}")
for line in fails:
    print(line)
n = len(records)
if fails:
    print(f"verify-evidence: {len(fails)} failure(s) over {n} record(s)")
    sys.exit(1)
print(f"verify-evidence: PASS {n} record(s)")
PY
