#!/usr/bin/env bash
# evidence-index suite (T154, SC-040): the index over verify-evidence's fixtures.
# A good run is indexed with its records and exit 0; a post-edited run is indexed
# with its failure and the script exits 1 (recorded, never dropped); no run is usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
IDX="$ROOT/scripts/ci/evidence_index.sh"
FX="$ROOT/tests/unit/verifyevidence/fixtures"
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

bash "$IDX" --out "$TMP/good.json" "$FX/good" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "good run indexed rc=0" || fail "good run rc=$rc"
python3 - "$TMP/good.json" <<'PY' && pass "good index: all_verified, records with hashes" || fail "good index content"
import json, sys
i = json.load(open(sys.argv[1]))
assert i["all_verified"] is True and len(i["runs"]) == 1
r = i["runs"][0]
assert r["verify_evidence_exit"] == 0 and r["record_count"] > 0
assert all(x["record_sha256"] for x in r["records"])
PY

bash "$IDX" --out "$TMP/mixed.json" "$FX/good" "$FX/post-edit-record" >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && pass "post-edited run fails the index rc=1" || fail "mixed rc=$rc"
python3 - "$TMP/mixed.json" <<'PY' && pass "failed run recorded, not dropped" || fail "mixed index content"
import json, sys
i = json.load(open(sys.argv[1]))
assert i["all_verified"] is False and len(i["runs"]) == 2
assert i["runs"][1]["verify_evidence_exit"] != 0
PY

bash "$IDX" --out "$TMP/x.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 && ! -e "$TMP/x.json" ]] && pass "no run is usage, nothing written" || fail "usage rc=$rc"

mkdir -p "$TMP/stopped"
bash "$IDX" --out "$TMP/ex.json" --exclude "$TMP/stopped=cycle stopped before its first step" "$FX/good" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "an excluded empty run does not fail the index rc=0" || fail "exclude rc=$rc"
python3 - "$TMP/ex.json" <<'PY' && pass "the exclusion is listed with its reason, never silent" || fail "exclude index content"
import json, sys
i = json.load(open(sys.argv[1]))
assert i["all_verified"] is True and len(i["runs"]) == 1
(x,) = i["excluded"]
assert x["reason"] == "cycle stopped before its first step" and x["audited"] is False
assert x["evidence_dir"].endswith("stopped")
PY
bash "$IDX" --out "$TMP/ex2.json" "$TMP/stopped" >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && pass "the same empty run, not excluded, fails the index rc=1" || fail "unexcluded empty rc=$rc"
bash "$IDX" --out "$TMP/ex3.json" --exclude "$TMP/stopped=" "$FX/good" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 && ! -e "$TMP/ex3.json" ]] && pass "an exclusion with no reason is usage, nothing written" || fail "empty reason rc=$rc"
bash "$IDX" --out "$TMP/ex4.json" --exclude "$FX/good=why" "$FX/good" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 && ! -e "$TMP/ex4.json" ]] && pass "a run both excluded and audited is usage" || fail "both rc=$rc"

[[ $fails -eq 0 ]] && echo "evidence-index: all PASS" || { echo "evidence-index: $fails FAIL"; exit 1; }
