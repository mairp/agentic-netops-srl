#!/usr/bin/env bash
# verify-evidence suite (T011, T012; NFR-013, SC-040, SC-004 / AD-31, AD-71).
#
# 1. Every committed fixture under fixtures/ gets the verdict it was built for,
#    naming the file and the reason.
# 2. The fixtures are rebuilt through scripts/lib/evidence.sh into a temp dir
#    and give the same verdicts (the library and the verifier agree).
# 3. evidence.sh's own rules: the default EVIDENCE_DIR shape, identity from the
#    lock and topology files, refusal of a readiness pass without a failing
#    negative control (the command is not even run), a passing negative control
#    reported as a defective check, no overwrite, no capture without a digest.
# 4. verify_evidence.sh with no run to verify fails; the newest run is chosen.
# No lab, no cluster.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
VERIFY="$ROOT/scripts/lib/verify_evidence.sh"
LIB="$ROOT/scripts/lib/evidence.sh"
DIGEST=sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# expect <label> <dir> <want-rc> [<grep -E pattern the output must contain>…]
expect() {
  local label="$1" dir="$2" want="$3"; shift 3
  local out rc
  out="$(bash "$VERIFY" "$dir" 2>&1)"; rc=$?
  if [[ "$rc" -ne "$want" ]]; then
    fail "$label (rc=$rc, want $want)"; printf '%s\n' "$out" | sed 's/^/    /'; return
  fi
  local p
  for p in "$@"; do
    if ! grep -qE -- "$p" <<<"$out"; then
      fail "$label (output lacks /$p/)"; printf '%s\n' "$out" | sed 's/^/    /'; return
    fi
  done
  pass "$label"
}

verdicts() {
  local base="$1" tag="$2"
  expect "$tag good: complete run incl. SC-004 both halves + route negative control passes" "$base/good" 0 'PASS 5 record'
  expect "$tag missing-field: record without device_image_digest fails naming file and field" \
    "$base/missing-field" 1 "FAIL cluster-nodes.json: missing NFR-013 field 'device_image_digest'"
  expect "$tag post-edit-output: raw output edited after capture fails" \
    "$base/post-edit-output" 1 "FAIL fabric-sessions.json: raw stdout 'fabric-sessions.stdout' content hash changed after capture"
  expect "$tag post-edit-record: record JSON edited after capture fails" \
    "$base/post-edit-record" 1 "FAIL service-routes.negative-control.json: record content changed after capture"
  expect "$tag hand-placed: unreferenced artefact fails naming it" \
    "$base/hand-placed" 1 'FAIL handwritten-proof.json: not referenced by any evidence record'
  expect "$tag readiness-without-nc: readiness check without failing negative control fails (SC-040)" \
    "$base/readiness-without-nc" 1 "FAIL targets-ready.json: readiness check 'targets-ready' has no recorded failing negative control"
  expect "$tag nc-passed: a negative control that passed marks the check defective" \
    "$base/nc-passed" 1 "negative control for 'targets-ready' passed"
  expect "$tag sc004-missing-session: SC-004 without the session half fails" \
    "$base/sc004-missing-session" 1 'SC-004.*without the session half'
  expect "$tag sc004-missing-route: SC-004 without the route half fails" \
    "$base/sc004-missing-route" 1 'SC-004.*without the route half \('
  expect "$tag sc004-missing-route-nc: SC-004 without the route half's negative control fails" \
    "$base/sc004-missing-route-nc" 1 "SC-004.*without the route half's negative control"
}

# --- 1. committed fixtures
verdicts "$HERE/fixtures" "fixture"

# --- 2. rebuilt through the library
if bash "$HERE/make_fixtures.sh" "$TMP/rebuilt" >/dev/null 2>&1; then
  pass "make_fixtures.sh rebuilds every case through evidence.sh"
  verdicts "$TMP/rebuilt" "rebuilt"
else
  fail "make_fixtures.sh rebuilds every case through evidence.sh"
fi

# --- 3. evidence.sh rules
# run_lib <script> — run a snippet with the library sourced, identity from env.
run_lib() {
  env -u EVIDENCE_DIR -u CLUSTER_NAME -u LAB_NAME EVIDENCE_ROOT="$TMP/root" \
    EVIDENCE_CLUSTER_UID=uid-test EVIDENCE_DEVICE_IMAGE_DIGEST="$DIGEST" EVIDENCE_LAB=lab-t \
    EVIDENCE_TOPOLOGY=/nonexistent PATH="$PATH" \
    bash -c "set -uo pipefail; source '$LIB'; $1"
}

out="$(run_lib 'evidence_run probe -- true >/dev/null; echo "$EVIDENCE_DIR"')"
if [[ "$out" =~ ^$TMP/root/agentic-netops_lab-t/[0-9]{8}T[0-9]{6}Z$ ]]; then
  pass "default EVIDENCE_DIR is <root>/<cluster>_<lab>/<UTC run id>"
else
  fail "default EVIDENCE_DIR is <root>/<cluster>_<lab>/<UTC run id> (got '$out')"
fi

out="$(run_lib 'evidence_run a -- true; evidence_run b -- true; ls "$EVIDENCE_DIR"/*.json | wc -l')"
[[ "$out" == 2 ]] && pass "one process writes one run directory across calls" \
  || fail "one process writes one run directory across calls (got $out records)"

out="$(run_lib 'evidence_run echo1 -- sh -c "echo to-out; echo to-err >&2; exit 7" 2>/dev/null; echo "rc=$?"; jq -r ".exit_status, .command[0], .cluster.uid, .lab.name, .device_image_digest" "$EVIDENCE_DIR/echo1.json"')"
if grep -q '^to-out$' <<<"$out" && grep -q '^rc=7$' <<<"$out" && grep -q '^7$' <<<"$out" \
  && grep -q '^uid-test$' <<<"$out" && grep -q '^lab-t$' <<<"$out" && grep -qF "$DIGEST" <<<"$out"; then
  pass "evidence_run replays output, returns the command's status and records the NFR-013 fields"
else
  fail "evidence_run replays output, returns the command's status and records the NFR-013 fields"; echo "$out" | sed 's/^/    /'
fi

marker="$TMP/should-not-exist"
out="$(run_lib "evidence_run ready --readiness -- touch '$marker' 2>&1; echo rc=\$?")"
if grep -q 'rc=3' <<<"$out" && grep -q "has no recorded failing negative control" <<<"$out" && [[ ! -e "$marker" ]]; then
  pass "readiness pass refused without a failing negative control; command not run"
else
  fail "readiness pass refused without a failing negative control; command not run"; echo "$out" | sed 's/^/    /'
fi

out="$(run_lib "evidence_run r --records SC-004:route -- touch '$marker' 2>&1; echo rc=\$?")"
if grep -q 'rc=3' <<<"$out" && [[ ! -e "$marker" ]]; then
  pass "SC-004:route implies readiness: refused without its negative control"
else
  fail "SC-004:route implies readiness: refused without its negative control"; echo "$out" | sed 's/^/    /'
fi

out="$(run_lib 'evidence_negative_control ready -- false 2>/dev/null; echo nc=$?; evidence_run ready --readiness -- true; echo run=$?; bash '"'$VERIFY'"' "$EVIDENCE_DIR" >/dev/null; echo verify=$?')"
if grep -q 'nc=0' <<<"$out" && grep -q 'run=0' <<<"$out" && grep -q 'verify=0' <<<"$out"; then
  pass "failing negative control admits the later readiness pass, and the run verifies"
else
  fail "failing negative control admits the later readiness pass, and the run verifies"; echo "$out" | sed 's/^/    /'
fi

out="$(run_lib 'evidence_negative_control ready -- true 2>&1; echo nc=$?; evidence_run ready --readiness -- true 2>&1; echo run=$?')"
if grep -q 'nc=4' <<<"$out" && grep -q 'check is defective' <<<"$out" && grep -q 'run=3' <<<"$out"; then
  pass "a passing negative control returns 4 (defective check) and the pass stays refused"
else
  fail "a passing negative control returns 4 (defective check) and the pass stays refused"; echo "$out" | sed 's/^/    /'
fi

out="$(run_lib 'evidence_negative_control c -- false 2>/dev/null; evidence_negative_control c -- false 2>/dev/null; ls "$EVIDENCE_DIR" | grep -c "json$"')"
[[ "$out" == 2 ]] && pass "repeated negative controls are kept side by side (-N suffix), none overwritten" \
  || fail "repeated negative controls are kept side by side (got $out)"

out="$(run_lib 'evidence_run x -- true; evidence_run x -- true 2>&1; echo rc=$?')"
grep -q 'rc=3' <<<"$out" && grep -q 'never overwritten' <<<"$out" && pass "an existing record is never overwritten" \
  || fail "an existing record is never overwritten"

out="$(env -u EVIDENCE_DIR EVIDENCE_ROOT="$TMP/root2" EVIDENCE_LAB=l EVIDENCE_CLUSTER_UID=u \
  EVIDENCE_LOCK_FILE=/nonexistent bash -c "source '$LIB'; evidence_run d -- touch '$marker' 2>&1; echo rc=\$?")"
if grep -q 'rc=3' <<<"$out" && grep -q 'device image digest unavailable' <<<"$out" && [[ ! -e "$marker" ]]; then
  pass "no device image digest: capture refused, command not run"
else
  fail "no device image digest: capture refused, command not run"; echo "$out" | sed 's/^/    /'
fi

# Identity from the files: digest from a lock file, lab from a topology, cluster
# uid "unavailable" when kubectl cannot reach the cluster (fake kubectl fails).
mkdir -p "$TMP/bin" "$TMP/ident"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/kubectl"; chmod +x "$TMP/bin/kubectl"
cat >"$TMP/ident/lock.yaml" <<EOF
images:
  - name: srlinux
    ref: ghcr.io/nokia/srlinux:25.7.1
    digest: $DIGEST
  - name: other
    digest: sha256:$(printf '0%.0s' {1..64})
EOF
printf 'name: my-lab\ntopology:\n  nodes: {}\n' >"$TMP/ident/topo.clab.yml"
out="$(env -u EVIDENCE_DIR -u EVIDENCE_LAB -u LAB_NAME -u EVIDENCE_CLUSTER_UID -u EVIDENCE_DEVICE_IMAGE_DIGEST \
  PATH="$TMP/bin:$PATH" EVIDENCE_ROOT="$TMP/root3" EVIDENCE_LOCK_FILE="$TMP/ident/lock.yaml" \
  EVIDENCE_TOPOLOGY="$TMP/ident/topo.clab.yml" CLUSTER_NAME=c1 \
  bash -c "source '$LIB'; evidence_run i -- true; jq -r '.device_image_digest, .lab.name, .cluster.name, .cluster.uid, (.lab.topology_sha256|length)' \"\$EVIDENCE_DIR/i.json\"; echo \"\$EVIDENCE_DIR\"")"
if [[ "$(sed -n 1p <<<"$out")" == "$DIGEST" && "$(sed -n 2p <<<"$out")" == my-lab && "$(sed -n 3p <<<"$out")" == c1 \
  && "$(sed -n 4p <<<"$out")" == unavailable && "$(sed -n 5p <<<"$out")" == 64 && "$(sed -n 6p <<<"$out")" == "$TMP/root3/c1_my-lab/"* ]]; then
  pass "identity read from lock and topology; unreachable cluster uid recorded as 'unavailable'"
else
  fail "identity read from lock and topology; unreachable cluster uid recorded as 'unavailable'"; echo "$out" | sed 's/^/    /'
fi

# --- 4. directory selection
out="$(env -u EVIDENCE_DIR EVIDENCE_ROOT="$TMP/none" bash "$VERIFY" 2>&1)"; rc=$?
[[ "$rc" -eq 2 ]] && grep -q 'no evidence run found' <<<"$out" && pass "no run to verify fails clearly (exit 2)" \
  || fail "no run to verify fails clearly (rc=$rc)"
mkdir -p "$TMP/empty/c_l/20260101T000000Z"
out="$(bash "$VERIFY" "$TMP/empty/c_l/20260101T000000Z" 2>&1)"; rc=$?
[[ "$rc" -eq 1 ]] && grep -q 'no evidence records' <<<"$out" && pass "an empty run directory fails (proves nothing)" \
  || fail "an empty run directory fails (rc=$rc)"
mkdir -p "$TMP/sel/c_l"
cp -r "$HERE/fixtures/missing-field" "$TMP/sel/c_l/20260101T000000Z"
cp -r "$HERE/fixtures/good" "$TMP/sel/c_l/20260102T000000Z"
out="$(env -u EVIDENCE_DIR EVIDENCE_ROOT="$TMP/sel" bash "$VERIFY" 2>&1)"; rc=$?
[[ "$rc" -eq 0 ]] && grep -q '20260102T000000Z' <<<"$out" && pass "no argument: the newest run under the evidence root is verified" \
  || fail "no argument: the newest run under the evidence root is verified (rc=$rc)"

# --- 4. the declared-faults ledger (tests/lib/leftovers.sh): admitted when byte-identical to its
# newest recorded snapshot, never attached itself (T151 r8: appends read as post-edits)
L="$TMP/ledger/c_l/20260103T000000Z"; mkdir -p "$L/declared-faults.d"
snap() { # <n> — append one fault to the ledger and record a snapshot, as declare_fault does
  jq -n --arg n "$1" '{schema: "agentic-netops.declared-faults/v1", faults: [range(0; ($n|tonumber)) | {id: "f\(.)"}]}' >"$L/declared-faults.json"
  cp "$L/declared-faults.json" "$L/declared-faults.d/000$1-f.json"
  env EVIDENCE_DIR="$L" EVIDENCE_CLUSTER_UID=uid-test EVIDENCE_DEVICE_IMAGE_DIGEST="$DIGEST" EVIDENCE_LAB=lab-t EVIDENCE_TOPOLOGY=/nonexistent \
    bash -c "source '$LIB'; evidence_run declared-fault.f.$1 --attach declared-faults.d/000$1-f.json -- cat '$L/declared-faults.d/000$1-f.json' >/dev/null"
}
snap 1; snap 2
out="$(bash "$VERIFY" "$L" 2>&1)"; rc=$?
[[ "$rc" -eq 0 ]] && pass "ledger equal to its newest snapshot is admitted, earlier snapshots intact" \
  || { fail "ledger equal to its newest snapshot is admitted (rc=$rc)"; echo "$out" | sed 's/^/    /'; }
jq '.faults += [{id: "unrecorded"}]' "$L/declared-faults.json" >"$L/x" && mv "$L/x" "$L/declared-faults.json"
out="$(bash "$VERIFY" "$L" 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && grep -q 'declared-faults ledger differs' <<<"$out" && pass "an unrecorded append to the ledger fails" \
  || fail "an unrecorded append to the ledger fails (rc=$rc)"

echo "verifyevidence_test: $fails failure(s)"
[ "$fails" -eq 0 ]
