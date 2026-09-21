#!/usr/bin/env bash
# GateReady on a re-run (scripts/provision.sh; AD-82 decision 2026-09-21-gate-rerun, SC-002).
#
# provision::gate_record_matches decides whether a lab that already carries the platform fabric may
# reuse the published qualification record instead of re-running the gate on non-stock nodes:
#   1. a pass by this gate code for this cluster, lab and device image → reused (exit 0)
#   2. each single difference — result fail, another cluster, another lab, another device digest,
#      an unknown device digest, another gate code, no record — refuses (exit 1) naming it
#   3. a record published before the gate carried its code hash (no gate_tree_sha256) refuses
# and tests/gate/lib/tree_hash.sh: the hash ignores tests/gate/observed/ and changes with one byte
# of a gate script.
# shellcheck disable=SC2015
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
FAILS=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '    %s\n' "$2"; FAILS=$((FAILS + 1)); }
# shellcheck source=../../../scripts/provision.sh
source "$ROOT/scripts/provision.sh"
set +e
PROVIDER_NS=agentic-netops-system
D="sha256:$(printf 'a%.0s' {1..64})"; T="$(printf 'b%.0s' {1..64})"
rec() { jq -n --arg r "$1" --arg c "$2" --arg l "$3" --arg d "$4" --arg t "$5" \
  '{cluster: $c, lab: $l, gate: {result: $r, finished_utc: "2026-09-21T11:00:00Z", evidence_dir: ".evidence/x/y", device_image_digest: $d, gate_tree_sha256: $t}}'; }

out="$(provision::gate_record_matches "$(rec pass agentic-netops lab1 "$D" "$T")" agentic-netops lab1 "$D" "$T")"; rc=$?
[[ "$rc" -eq 0 ]] && grep -qF "pass of 2026-09-21T11:00:00Z" <<<"$out" && pass "this gate's pass for this lab is reused" || fail "matching record (rc=$rc)" "$out"

check() { # <name> <record json> <expected text> [cluster lab digest tree]
  local out rc
  out="$(provision::gate_record_matches "$2" "${4:-agentic-netops}" "${5:-lab1}" "${6-$D}" "${7:-$T}")"; rc=$?
  [[ "$rc" -eq 1 ]] && grep -qF "$3" <<<"$out" && pass "$1 refuses naming it" || fail "$1 (rc=$rc)" "$out"
}
check "a failed gate"          "$(rec fail agentic-netops lab1 "$D" "$T")" "not pass"
check "another cluster"        "$(rec pass other lab1 "$D" "$T")"          "cluster other"
check "another lab"            "$(rec pass agentic-netops lab2 "$D" "$T")" "lab lab2"
check "another device image"   "$(rec pass agentic-netops lab1 sha256:cc "$T")" "device image digest sha256:cc"
check "an unknown device image" "$(rec pass agentic-netops lab1 "$D" "$T")" "unknown" agentic-netops lab1 ""
check "another gate code"      "$(rec pass agentic-netops lab1 "$D" deadbeef)" "gate code deadbeef"
check "no record"              ""                                          "no published record"
check "a record without gate code" "$(rec pass agentic-netops lab1 "$D" "$T" | jq 'del(.gate.gate_tree_sha256)')" "gate code absent"

# tree hash: observed/ ignored, a gate script byte counts
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/tests/gate/observed" "$TMP/tests/lib"; echo a >"$TMP/tests/gate/g01.sh"; echo l >"$TMP/tests/lib/lab.sh"
source "$ROOT/tests/gate/lib/tree_hash.sh"
h1="$(gate::tree_hash "$TMP")"; echo x >"$TMP/tests/gate/observed/serialization.json"; h2="$(gate::tree_hash "$TMP")"
echo b >"$TMP/tests/gate/g01.sh"; h3="$(gate::tree_hash "$TMP")"
[[ "$h1" == "$h2" && "$h1" != "$h3" && "$h1" =~ ^[0-9a-f]{64}$ ]] && pass "gate code hash: observed/ ignored, one changed script byte changes it" || fail "tree hash $h1 $h2 $h3"

if [[ "$FAILS" -gt 0 ]]; then echo "gate_rerun_test: $FAILS FAILED"; exit 1; fi
echo "gate_rerun_test: PASS"
