#!/usr/bin/env bash
# scripts/lib/evidence.sh suite (T011; NFR-013, SC-040). Offline: every
# identity is stubbed through the environment (EVIDENCE_*), kubectl is a stub
# on PATH, and everything is written under a temp directory.
#
# Proves, one behaviour per check:
#   - evidence_run writes <EVIDENCE_DIR>/<id>.json plus the raw stdout/stderr,
#     carrying the command, UTC time, exit status, device image digest, cluster
#     identity and containerlab lab identity, and returns the command's status;
#   - EVIDENCE_DIR defaults to .evidence/<cluster>_<lab>/<UTC run id>/ under the
#     repository root, and .evidence/ is git-ignored;
#   - evidence_negative_control records a run that MUST fail: a failing control
#     is recorded and admits a later readiness pass; a passing one returns 4;
#   - a readiness pass of a check id WITHOUT a recorded failing negative control
#     is refused (exit 3) and its command never runs; so is any run of a check
#     whose negative control passed (defective check).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$ROOT/scripts/lib/evidence.sh"
DIGEST=sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
# kubectl stub: the cluster is unreachable offline.
printf '#!/usr/bin/env bash\necho "stub kubectl: no cluster" >&2\nexit 1\n' >"$TMP/bin/kubectl"
chmod +x "$TMP/bin/kubectl"

# lib <snippet> — run a snippet with the library sourced and identities stubbed.
lib() {
  env -u EVIDENCE_DIR -u CLUSTER_NAME -u LAB_NAME PATH="$TMP/bin:$PATH" \
    EVIDENCE_ROOT="$TMP/evidence" EVIDENCE_CLUSTER=kind-t EVIDENCE_CLUSTER_UID=uid-1234 \
    EVIDENCE_LAB=clab-t EVIDENCE_DEVICE_IMAGE_DIGEST="$DIGEST" EVIDENCE_TOPOLOGY=/nonexistent \
    bash -c "set -uo pipefail; source '$LIB'; $1"
}

# --- 1. the record and the raw output
out="$(lib 'evidence_run bgp-sessions -- sh -c "echo established 8/8; echo warn >&2; exit 0" >/dev/null 2>&1
  echo "rc=$?"; echo "dir=$EVIDENCE_DIR"; ls "$EVIDENCE_DIR"')"
dir="$(sed -n 's/^dir=//p' <<<"$out")"
if grep -qx 'rc=0' <<<"$out" && [[ -f "$dir/bgp-sessions.json" && -f "$dir/bgp-sessions.stdout" && -f "$dir/bgp-sessions.stderr" ]]; then
  pass "evidence_run writes <EVIDENCE_DIR>/<id>.json and the raw stdout/stderr"
else
  fail "evidence_run writes <EVIDENCE_DIR>/<id>.json and the raw stdout/stderr" "$out"
fi
rec="$dir/bgp-sessions.json"
if [[ -f "$rec" ]] && jq -e --arg d "$DIGEST" '
    .command == ["sh","-c","echo established 8/8; echo warn >&2; exit 0"]
    and (.utc_time | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and .exit_status == 0 and .device_image_digest == $d
    and .cluster.name == "kind-t" and .cluster.uid == "uid-1234" and .lab.name == "clab-t"
    and .raw_output.stdout.file == "bgp-sessions.stdout" and (.raw_output.stdout.sha256 | length) == 64' \
    "$rec" >/dev/null; then
  pass "record carries command, UTC time, exit status, image digest, cluster and lab identity"
else
  fail "record carries command, UTC time, exit status, image digest, cluster and lab identity" "$(cat "$rec" 2>&1)"
fi
if [[ "$(cat "$dir/bgp-sessions.stdout" 2>/dev/null)" == "established 8/8" \
  && "$(sha256sum "$dir/bgp-sessions.stdout" | cut -d' ' -f1)" == "$(jq -r .raw_output.stdout.sha256 "$rec")" ]]; then
  pass "raw stdout captured verbatim and hashed into the record"
else
  fail "raw stdout captured verbatim and hashed into the record"
fi

out="$(lib 'evidence_run failing -- sh -c "echo nope; exit 5" 2>/dev/null; echo "rc=$?"; jq -r .exit_status "$EVIDENCE_DIR/failing.json"')"
if grep -qx 'nope' <<<"$out" && grep -qx 'rc=5' <<<"$out" && grep -qx '5' <<<"$out"; then
  pass "a failing command: output replayed, status returned and recorded (5)"
else
  fail "a failing command: output replayed, status returned and recorded (5)" "$out"
fi

# --- 2. EVIDENCE_DIR default and .gitignore
out="$(env -u EVIDENCE_DIR -u EVIDENCE_ROOT -u CLUSTER_NAME -u LAB_NAME PATH="$TMP/bin:$PATH" \
  EVIDENCE_CLUSTER=unit-cluster-$$ EVIDENCE_CLUSTER_UID=u EVIDENCE_LAB=unit-lab \
  EVIDENCE_DEVICE_IMAGE_DIGEST="$DIGEST" bash -c "source '$LIB'; evidence::ensure_dir && echo \"\$EVIDENCE_DIR\"")"
if [[ "$out" =~ ^$ROOT/\.evidence/unit-cluster-$$_unit-lab/[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$ ]]; then
  pass "EVIDENCE_DIR defaults to <repo>/.evidence/<cluster>_<lab>/<UTC run id>/"
else
  fail "EVIDENCE_DIR defaults to <repo>/.evidence/<cluster>_<lab>/<UTC run id>/ (got '$out')"
fi
rm -rf "$ROOT/.evidence/unit-cluster-$$_unit-lab"
rmdir "$ROOT/.evidence" 2>/dev/null || true
if grep -qxF '.evidence/' "$ROOT/.gitignore"; then
  pass ".evidence/ is git-ignored"
else
  fail ".evidence/ is git-ignored"
fi

# --- 3. negative controls and the refusal
marker="$TMP/ran"
out="$(lib "evidence_run fabric-ready --readiness -- touch '$marker' 2>&1; echo rc=\$?; ls \"\$EVIDENCE_DIR\"")"
if grep -qx 'rc=3' <<<"$out" && grep -q "has no recorded failing negative control" <<<"$out" \
  && [[ ! -e "$marker" ]] && ! grep -q 'fabric-ready.json' <<<"$out"; then
  pass "REFUSAL: readiness pass without a failing negative control -> exit 3, command not run, nothing recorded"
else
  fail "REFUSAL: readiness pass without a failing negative control -> exit 3, command not run, nothing recorded" "$out"
fi

out="$(lib 'evidence_negative_control fabric-ready -- sh -c "echo 0/8 established; exit 1" >/dev/null 2>&1; echo nc=$?
  jq -r ".kind, .check_id, .exit_status, .negative_control_failed" "$EVIDENCE_DIR/fabric-ready.negative-control.json"
  evidence_run fabric-ready --readiness -- echo 8/8 >/dev/null; echo run=$?')"
if grep -qx 'nc=0' <<<"$out" && [[ "$(sed -n 2,5p <<<"$out" | tr '\n' ' ')" == "negative_control fabric-ready 1 true " ]] \
  && grep -qx 'run=0' <<<"$out"; then
  pass "a failing negative control is recorded (kind, check id, exit 1, failed=true) and admits the later pass"
else
  fail "a failing negative control is recorded and admits the later pass" "$out"
fi

out="$(lib "evidence_negative_control route-half -- true 2>&1; echo nc=\$?
  jq -r .negative_control_failed \"\$EVIDENCE_DIR/route-half.negative-control.json\"
  evidence_run route-half --readiness -- touch '$marker' 2>&1; echo ready=\$?
  evidence_run route-half-plain --check route-half -- touch '$marker' 2>&1; echo plain=\$?")"
if grep -qx 'nc=4' <<<"$out" && grep -qx 'false' <<<"$out" && grep -q 'check is defective' <<<"$out" \
  && grep -qx 'ready=3' <<<"$out" && grep -qx 'plain=3' <<<"$out" && [[ ! -e "$marker" ]]; then
  pass "a negative control that PASSES returns 4, is recorded as not failed, and every later run of the check is refused"
else
  fail "a negative control that PASSES returns 4 and every later run of the check is refused" "$out"
fi

out="$(lib "evidence_negative_control other -- false 2>/dev/null; evidence_run mine --check mine --readiness -- touch '$marker' 2>&1; echo rc=\$?")"
if grep -qx 'rc=3' <<<"$out" && [[ ! -e "$marker" ]]; then
  pass "a negative control of ANOTHER check id does not admit the pass"
else
  fail "a negative control of ANOTHER check id does not admit the pass" "$out"
fi

out="$(lib "evidence_run r --records SC-004:route -- touch '$marker' 2>&1; echo rc=\$?")"
if grep -qx 'rc=3' <<<"$out" && [[ ! -e "$marker" ]]; then
  pass "SC-004's route half is a readiness check: refused without its negative control"
else
  fail "SC-004's route half is a readiness check: refused without its negative control" "$out"
fi

# --- 4. identity is never omitted
out="$(env -u EVIDENCE_DIR -u EVIDENCE_LAB -u LAB_NAME PATH="$TMP/bin:$PATH" EVIDENCE_ROOT="$TMP/e2" \
  EVIDENCE_DEVICE_IMAGE_DIGEST="$DIGEST" EVIDENCE_TOPOLOGY=/nonexistent \
  bash -c "source '$LIB'; evidence_run x -- touch '$marker' 2>&1; echo rc=\$?")"
if grep -qx 'rc=3' <<<"$out" && grep -q 'lab identity unknown' <<<"$out" && [[ ! -e "$marker" ]]; then
  pass "no containerlab lab identity: capture refused, command not run"
else
  fail "no containerlab lab identity: capture refused, command not run" "$out"
fi
out="$(lib 'unset EVIDENCE_CLUSTER_UID; evidence_run u -- true; jq -r .cluster.uid "$EVIDENCE_DIR/u.json"')"
if [[ "$out" == unavailable ]]; then
  pass "unreachable cluster (stub kubectl fails): uid recorded as 'unavailable', never omitted"
else
  fail "unreachable cluster: uid recorded as 'unavailable' (got '$out')"
fi

# --- 5. the negative-control lookup reads only candidate records, and still decides by content
# A run record whose command merely MENTIONS the check id (the pre-filter's superset) is not its
# negative control: the readiness run stays refused.
out="$(lib 'evidence_run mention -- sh -c "echo \"cx-ready\"; exit 1" >/dev/null 2>&1
  evidence_run r2 --check cx-ready --readiness -- true 2>&1; echo rc=$?')"
if grep -qx 'rc=3' <<<"$out" && grep -q 'no recorded failing negative control' <<<"$out"; then
  pass "a record that only mentions the check id is not its negative control (content decides)"
else
  fail "a record that only mentions the check id is not its negative control (content decides)" "$out"
fi
# 400 unrelated records: the lookup is one grep, not one jq per record (T153/SC-032 tier-phase time).
out="$(lib 'for i in $(seq 1 400); do evidence_run "bulk-$i" -- true >/dev/null 2>&1; done
  evidence_negative_control cy -- false >/dev/null 2>&1
  s=$(date +%s%N); evidence_run r3 --check cy --readiness -- true >/dev/null 2>&1; echo rc=$?
  echo ms=$(( ($(date +%s%N) - s) / 1000000 ))')"
ms="$(sed -n 's/^ms=//p' <<<"$out")"
if grep -qx 'rc=0' <<<"$out" && [[ -n "$ms" && "$ms" -lt 1500 ]]; then
  pass "readiness run among 400 records admitted in ${ms} ms (< 1500)"
else
  fail "readiness run among 400 records admitted quickly (< 1500 ms)" "$out"
fi

# --- 6. evidence_seal: what a run wrote beside its record is sealed, and verify-evidence then passes
VE="$(cd "$(dirname "$LIB")" && pwd)/verify_evidence.sh"
out="$(lib 'evidence::ensure_dir; mkdir -p "$EVIDENCE_DIR/t089"
  evidence_run step -- sh -c "echo m >\"$EVIDENCE_DIR/t089/m.json\"; echo s >\"$EVIDENCE_DIR/scratch.yaml\"" >/dev/null 2>&1
  echo "[]" >"$EVIDENCE_DIR/declared-faults.json"
  : >"$EVIDENCE_DIR/inflight.stdout"
  bash "'"$VE"'" "$EVIDENCE_DIR" >/dev/null 2>&1; echo before=$?
  evidence_seal step.sealed; echo seal=$?
  jq -r ".attachments[].file" "$EVIDENCE_DIR/step.sealed.json" | sort | tr "\n" " "; echo
  rm -f "$EVIDENCE_DIR/declared-faults.json" "$EVIDENCE_DIR/inflight.stdout"
  bash "'"$VE"'" "$EVIDENCE_DIR" >/dev/null 2>&1; echo after=$?
  n=$(ls "$EVIDENCE_DIR"/*.json | wc -l); evidence_seal again; echo again=$? n=$n now=$(ls "$EVIDENCE_DIR"/*.json | wc -l)')"
if grep -q '^before=[1-9]' <<<"$out" && grep -qx 'seal=0' <<<"$out" \
   && grep -qx 'scratch.yaml t089/m.json ' <<<"$out" && grep -qx 'after=0' <<<"$out"; then
  pass "evidence_seal attaches the unreferenced files (not the ledger, not an in-flight output); verify-evidence then passes"
else
  fail "evidence_seal attaches the unreferenced files and verify-evidence then passes" "$out"
fi
if grep -Eq '^again=0 n=([0-9]+) now=\1$' <<<"$out"; then
  pass "evidence_seal with nothing unreferenced writes no record"
else
  fail "evidence_seal with nothing unreferenced writes no record" "$out"
fi

echo "evidence_test: $fails failure(s)"
[ "$fails" -eq 0 ]
