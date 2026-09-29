#!/usr/bin/env bash
# purge-order suite (T152): tests/e2e/lib/purge_order.py over synthetic call logs of
# `off.sh --purge-intent-tier` — the good order of scenario 4b passes, and each misordering the
# removability proof must catch fails naming its rule; scenario 4a fails on any scale or exec.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PO="$ROOT/tests/e2e/lib/purge_order.py"
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
A=20260925T000000Z-abcd1234
C="--context kind-agentic-netops"
N="networks.fabric.agentic-netops.io"

# good 4b: ts 100.. strictly increasing; the artefacts are written at 110 and 118
good() {
  cat <<LOG
100.0	$C get namespaces -o name
101.0	$C get $N -n agentic-netops-intent -o json
102.0	$C -n agentic-netops-agents get deployment supervisor -o name
103.0	$C -n agentic-netops-agents scale deployment supervisor --replicas=0
104.0	$C -n agentic-netops-agents scale deployment ui --replicas=0
105.0	$C -n agentic-netops-agents scale deployment deployer --replicas=0
106.0	$C get $N -n agentic-netops-intent -o json
107.0	$C exec -n agentic-netops-agents clickhouse-0 -- bash -c q
112.0	$C -n agentic-netops-intent delete $N svc-a svc-b --wait=false
113.0	$C get $N -n agentic-netops-intent -o json
114.0	$C get $N -n agentic-netops-intent -o json
115.0	$C -n agentic-netops-agents delete statefulset clickhouse --ignore-not-found --wait=false
119.0	$C delete secret operator-credentials -n agentic-netops-agents --ignore-not-found --wait=false
120.0	$C delete validatingadmissionpolicybinding deny-tier-force-release
121.0	$C delete validatingadmissionpolicy deny-tier-force-release
122.0	$C delete namespace agentic-netops-intent --ignore-not-found --wait=false
LOG
}
mkev() {  # mkev <dir> <export mtime> <usernames mtime> <relist json>
  mkdir -p "$1"
  : >"$1/audit-export-$A.ndjson.gz"; touch -d "@$2" "$1/audit-export-$A.ndjson.gz"
  echo '{}' >"$1/operator-usernames-$A.json"; touch -d "@$3" "$1/operator-usernames-$A.json"
  printf '%s\n' "$4" >"$1/tier-purge-relist-$A.stdout"
}
run() { python3 "$PO" remove --calllog "$1" --evidence-dir "$2" --attempt "$A" --networks svc-a,svc-b >"$TMP/out" 2>&1; }

good >"$TMP/good.tsv"; mkev "$TMP/ev" 110 118 '{"items":[]}'
run "$TMP/good.tsv" "$TMP/ev"; rc=$?
[[ $rc -eq 0 ]] && pass "good 4b order passes" || { fail "good 4b order rc=$rc"; cat "$TMP/out"; }

expect_fail() {  # expect_fail <name> <rule> <calllog> <evdir>
  run "$3" "$4"; local rc=$?
  if [[ $rc -eq 1 ]] && grep -q "^FAIL $2 " "$TMP/out"; then pass "$1 fails $2"; else fail "$1 (rc=$rc, no FAIL $2)"; cat "$TMP/out"; fi
}
# R1: a mutating call before the scale-down
good | sed 's/^101.0\t.*/101.0\t'"$C"' -n agentic-netops-intent delete '"$N"' svc-a/' >"$TMP/r1.tsv"
expect_fail "delete before the quiesce" R1 "$TMP/r1.tsv" "$TMP/ev"
# R2: the export (exec) before the deployer is scaled down
good | awk -F'\t' 'BEGIN{OFS="\t"} $1=="105.0"{$1="107.5"} $1=="107.0"{$1="105.0"} {print}' | sort -n >"$TMP/r2.tsv"
expect_fail "export before the deployer's scale-down" R2 "$TMP/r2.tsv" "$TMP/ev"
# R3: a tier Network not deleted
good | sed 's/ svc-a svc-b / svc-a /' >"$TMP/r3.tsv"
expect_fail "a submitted Network left out of the delete" R3 "$TMP/r3.tsv" "$TMP/ev"
# R4: the export written after the store went
mkev "$TMP/ev4" 116 118 '{"items":[]}'
expect_fail "export written after the store deletion" R4 "$TMP/good.tsv" "$TMP/ev4"
# R5: the usernames record written after the Secret went
mkev "$TMP/ev5" 110 119.5 '{"items":[]}'
expect_fail "usernames record after the Secret deletion" R5 "$TMP/good.tsv" "$TMP/ev5"
# R6: the re-list not empty
mkev "$TMP/ev6" 110 118 '{"items":[{"metadata":{"name":"svc-a"}}]}'
expect_fail "namespace deleted after a non-empty re-list" R6 "$TMP/good.tsv" "$TMP/ev6"
# R7: the policy binding never deleted
good | grep -v validatingadmissionpolicybinding >"$TMP/r7.tsv"
expect_fail "policy binding left" R7 "$TMP/r7.tsv" "$TMP/ev"

# 4a
printf '100.0\t%s get %s -n agentic-netops-intent -o json\n' "$C" "$N" >"$TMP/a-good.tsv"
python3 "$PO" refused --calllog "$TMP/a-good.tsv" >/dev/null && pass "4a: list-only refusal passes" || fail "4a good"
{ cat "$TMP/a-good.tsv"; printf '101.0\t%s -n agentic-netops-agents scale deployment supervisor --replicas=0\n' "$C"; } >"$TMP/a-scale.tsv"
python3 "$PO" refused --calllog "$TMP/a-scale.tsv" >"$TMP/out" && fail "4a: a scale passed" || { grep -q '^FAIL A2' "$TMP/out" && pass "4a: a scale fails A2" || fail "4a: scale not A2"; }
{ cat "$TMP/a-good.tsv"; printf '101.0\t%s exec -n agentic-netops-agents clickhouse-0 -- q\n' "$C"; } >"$TMP/a-exec.tsv"
python3 "$PO" refused --calllog "$TMP/a-exec.tsv" >"$TMP/out" && fail "4a: an export passed" || { grep -q '^FAIL A3' "$TMP/out" && pass "4a: an export fails A3" || fail "4a: exec not A3"; }

[[ $fails -eq 0 ]] && echo "purge_order: all passed" || echo "purge_order: $fails failed"
exit $((fails > 0))
