#!/usr/bin/env bash
# sc_partition_test.sh — the success-criteria partition and the acceptance runner's plan (T175,
# T151; SC-025, NFR-006, NFR-013, FR-108). Offline: the leftover scan is a fake
# (ACCEPTANCE_LEFTOVERS_SCAN), kubectl is a fake (KUBECTL), every identity evidence.sh needs is
# stubbed through EVIDENCE_*, and everything is written under a temp directory.
#
#   P1  tests/e2e/sc_partition.yaml validates against spec.md: every `- **SC-NNN**` exactly once
#       (criteria[] + retired[]), no control-plane check (nor the control-plane half of a `both`
#       criterion) reaching for a tier workload (deny-list: tier_denylist.txt beside this file),
#       every refs / run file and `make` target it names exists (and is implemented)
#   P2  the fixtures under testdata/ each FAIL, naming the offender: a missing SC, a duplicate SC,
#       control-plane checks reaching for the tier (one of them the half of a `both`), a missing ref
#   P3  a leftover refuses the start, non-zero, naming it; nothing is planned or run
#   P4  ACCEPTANCE_DRY_RUN=1 CONTROL_PLANE_ONLY=1: no lifecycle step, no cycle; assert-tier-absent
#       first of the live checks; every tier criterion `not run: tier absent`, every tier half of a
#       `both` too; manual `not run: manual (Txxx)`; retired `retired (tombstone)`; the denominator;
#       nothing executed (make / kubectl / go / docker / uv fakes on PATH record any call)
#   P5  ACCEPTANCE_DRY_RUN=1 full: ACCEPTANCE_CYCLES cycles, each deploy → control-plane live →
#       deploy-tier → tier live → destroy; offline before the first cycle; closing last
#   P6  report: not run is never passed; one failing control-plane check fails its criterion, the
#       aggregate (SC-025) and the run; all run ones passing is PASS 100%
#   P7  --assert-tier-absent: tier namespaces present → fail, naming them; absent → ok; kubectl
#       unreadable → fail (closed)
#   P8  the executor, for real on a fixture partition: evidence_run records per scope, the SKIP of a
#       `requires: tier-absent` check when the tier is present, verify-evidence over its own dirs
# shellcheck disable=SC2016,SC2034 # the check strings are eval'd; rc/want are read inside them
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
HELPER="$ROOT/tests/e2e/lib/sc_partition.py"
ACC="$ROOT/tests/e2e/acceptance.sh"
SPEC="$ROOT/specs/004-agentic-netops-composite/spec.md"
DENY="$HERE/tier_denylist.txt"
TD="$HERE/testdata"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; [[ -n "${out:-}" ]] && printf '%s\n' "$out" | tail -n 15 | sed 's/^/    | /'; fi; }

validate() { python3 "$HELPER" --partition "$1" validate --spec "$SPEC" --denylist "$DENY" --root "$ROOT" 2>&1; }

# specs/ is local to the working copy (.gitignore). Where it is absent, the checks that read spec.md
# (P1 validation, P2 fixtures) cannot run; the deny-list check and every other part still do.
if [[ -f "$SPEC" ]]; then
# ---------------------------------------------------------------- P1 the real partition
out="$(validate "$ROOT/tests/e2e/sc_partition.yaml")"; rc=$?
check "P1 tests/e2e/sc_partition.yaml validates (every SC once, no control-plane check reaches the tier, refs/run files exist)" \
  '[[ $rc -eq 0 ]] && grep -q "^sc_partition: OK" <<<"$out"'
n_spec="$(grep -cE '^- \*\*SC-[0-9]{3}\*\*' "$SPEC")"
n_part="$(python3 "$HELPER" list | grep -c '^SC-')"
out="spec $n_spec, partition $n_part"
check "P1 spec.md's $n_spec success criteria and the partition's criteria + retired agree in number" '[[ $n_spec -gt 0 && $n_spec -eq $n_part ]]'
out=""
check "P1 the deny-list is not empty and names the tier namespaces" \
  'grep -qx agentic-netops-agents "$DENY" && grep -qx -- --with-intent-tier "$DENY"'

# ---------------------------------------------------------------- P2 fixtures
out="$(validate "$TD/missing_sc.yaml")"; rc=$?
check "P2 a missing SC fails, naming it (SC-037)" '[[ $rc -ne 0 ]] && grep -q "^FAIL SC-037: defined in spec.md but missing" <<<"$out"'
out="$(validate "$TD/duplicate_sc.yaml")"; rc=$?
check "P2 a duplicate SC fails, naming it (SC-005)" '[[ $rc -ne 0 ]] && grep -q "^FAIL SC-005: appears 2 times" <<<"$out"'
out="$(validate "$TD/cp_reaches_tier.yaml")"; rc=$?
check "P2 a control-plane check reaching the tier fails, naming it and the token (test-idempotence, --with-intent-tier)" \
  '[[ $rc -ne 0 ]] && grep -q "^FAIL check test-idempotence: a control-plane check reaches for the tier (deny-list: --with-intent-tier)" <<<"$out"'
check "P2 the control-plane half of a both criterion reaching the tier fails, naming it (verify-acl, SC-014)" \
  'grep -q "^FAIL check verify-acl: a control-plane check reaches for the tier (deny-list: agentic-netops-agents)" <<<"$out"'
out="$(validate "$TD/missing_ref.yaml")"; rc=$?
check "P2 a refs file that does not exist fails, naming the check and the file" \
  '[[ $rc -ne 0 ]] && grep -q "^FAIL check test-alerts: refs file .tests/unit/alerts/no_such_rules_test.sh. does not exist" <<<"$out"'
# a tier check may name the tier (the deny-list is for the control-plane side only)
out="$(validate "$ROOT/tests/e2e/sc_partition.yaml")"
check "P2 negative: tier checks naming tier workloads (tier-e2e, provision-tier) are not flagged" \
  '! grep -qE "check (tier-e2e|provision-tier|constructs-e2e):" <<<"$out"'

else
  echo "NOTE specs/ is absent from this working copy (local, git-ignored): P1/P2 spec comparisons run wherever the specification is present"
  check "P1 the deny-list is not empty and names the tier namespaces" \
    'grep -qx agentic-netops-agents "$DENY" && grep -qx -- --with-intent-tier "$DENY"'
fi

# ---------------------------------------------------------------- fakes: nothing may execute
FAKEBIN="$T/bin"; CALLS="$T/calls"; mkdir -p "$FAKEBIN"; : >"$CALLS"
for c in make kubectl go docker uv containerlab kind; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s"\nexit 0\n' "$c" "$CALLS" >"$FAKEBIN/$c"
  chmod +x "$FAKEBIN/$c"
done
acc() { env PATH="$FAKEBIN:$PATH" ACCEPTANCE_EVIDENCE_BASE="$T/ev-dry" "$@" bash "$ACC" 2>&1; }

# ---------------------------------------------------------------- P3 a leftover refuses the start
: >"$CALLS"
out="$(acc ACCEPTANCE_DRY_RUN=1 \
  ACCEPTANCE_LEFTOVERS_SCAN='echo "LEFTOVER vt-scratch-object leaf01 /interface[name=ethernet-1/9] = vt-scratch-probe"; exit 1')"; rc=$?
check "P3 a leftover refuses the start, non-zero, naming node and leftover" \
  '[[ $rc -ne 0 ]] && grep -q "REFUSED to start" <<<"$out" && grep -q "acceptance:   LEFTOVER vt-scratch-object leaf01 .*vt-scratch-probe" <<<"$out"'
check "P3 nothing planned or run after the refusal" '! grep -q "acceptance plan" <<<"$out" && [[ ! -s $CALLS ]]'
out="$(acc ACCEPTANCE_LEFTOVERS_SCAN='exit 1' CONTROL_PLANE_ONLY=1)"; rc=$?
check "P3 a failing scan (without LEFTOVER lines) also refuses" '[[ $rc -ne 0 ]] && grep -q "REFUSED to start" <<<"$out" && [[ ! -s $CALLS ]]'

# ---------------------------------------------------------------- P4 the control-plane-only plan
: >"$CALLS"
out="$(acc ACCEPTANCE_DRY_RUN=1 CONTROL_PLANE_ONLY=1 ACCEPTANCE_LEFTOVERS_SCAN='echo "leftovers: clean (fake)" >&2')"; rc=$?
cp_plan="$out"
steps="$(grep -E '^  \[[0-9]+\] ' <<<"$out")"
check "P4 dry run exits 0 and prints steps" '[[ $rc -eq 0 && -n $steps ]]'
check "P4 no lifecycle step and no cycle in a control-plane-only plan" \
  '! awk "{print \$2, \$3}" <<<"$steps" | grep -qE "lifecycle:|^cycle-" && ! grep -qE "scripts/(provision|off)\.sh" <<<"$steps"'
check "P4 nothing executed by the dry run (no make/kubectl/go/docker/uv call)" '[[ ! -s $CALLS ]]'
first_live="$(grep -m1 ' live:' <<<"$steps" | awk '{print $4}')"
out="$first_live"
check "P4 assert-tier-absent is the first live check" '[[ $first_live == assert-tier-absent ]]'
check "P4 no tier check is planned (no step reaches the tier)" \
  '! grep -qE "live:tier|--with-intent-tier|cd agents|tests/e2e/(tier_e2e|chat_surface|trace_e2e|adversarial|auth_audit|degradation)" <<<"$steps"'
check "P4 closing: verify-evidence and verify-pins --no-pending" \
  'grep -qE "closing +closing +verify-evidence +make verify-evidence" <<<"$steps" && grep -q "verify_pins.sh --no-pending" <<<"$steps"'
out="$cp_plan"
missing=""
while read -r id side _; do
  case "$side" in
    tier) grep -qxF "$id [tier] not run: tier absent" <<<"$cp_plan" || missing+=" $id" ;;
    both) grep -qE "^$id \[both\] control-plane half: .*; tier half: not run: tier absent$" <<<"$cp_plan" || missing+=" $id(both)" ;;
    retired) grep -q "^$id retired (tombstone)" <<<"$cp_plan" || missing+=" $id(retired)" ;;
  esac
done < <(python3 "$HELPER" list | grep '^SC-')
n_tier="$(python3 "$HELPER" list | grep -c '^SC-[0-9]* tier ')"
check "P4 every tier criterion ($n_tier) and tier half reported 'not run: tier absent'; retired as tombstones" '[[ -z $missing && $n_tier -gt 0 ]]'
[[ -n "$missing" ]] && printf '    | missing:%s\n' "$missing"
check "P4 a manual check is reported 'not run: manual (T153)' (SC-013)" 'grep -qxF "SC-013 [control-plane] not run: manual (T153)" <<<"$cp_plan"'
n_cpc="$(python3 "$HELPER" list | grep -cE '^SC-[0-9]+ (control-plane|both) ')"
check "P4 the summary states the denominator: $n_cpc control-plane criteria" \
  'grep -q "^control-plane criteria (denominator): $n_cpc " <<<"$cp_plan"'
check "P4 no criterion is reported PASS by a dry run" '! grep -qE "^SC-[0-9]+ .*PASS" <<<"$cp_plan"'

# ---------------------------------------------------------------- P5 the full plan
: >"$CALLS"
out="$(acc ACCEPTANCE_DRY_RUN=1 ACCEPTANCE_CYCLES=2 ACCEPTANCE_LEFTOVERS_SCAN=true)"; rc=$?
steps="$(grep -E '^  \[[0-9]+\] ' <<<"$out" | awk '{print $2, $3, $4}')"
order="$(awk '{k=$2; sub(/\+.*/, "", k); print $1, k}' <<<"$steps" | uniq)"
want="offline offline
cycle-1 lifecycle:deploy
cycle-1 lifecycle:redeploy
cycle-1 live:control-plane
cycle-1 lifecycle:deploy-tier
cycle-1 live:tier
cycle-1 lifecycle:destroy
cycle-1 lifecycle:redestroy
cycle-2 lifecycle:deploy
cycle-2 lifecycle:redeploy
cycle-2 live:control-plane
cycle-2 lifecycle:deploy-tier
cycle-2 live:tier
cycle-2 lifecycle:destroy
cycle-2 lifecycle:redestroy
closing closing"
out="$order"
check "P5 full plan: offline once, 2 cycles of deploy → control-plane → deploy-tier → tier → destroy, closing last" \
  '[[ $rc -eq 0 && "$order" == "$want" && ! -s $CALLS ]]'
out="$(ACCEPTANCE_CYCLES=0 acc ACCEPTANCE_DRY_RUN=1 ACCEPTANCE_CYCLES=0 ACCEPTANCE_LEFTOVERS_SCAN=true)"; rc=$?
check "P5 ACCEPTANCE_CYCLES=0 is refused" '[[ $rc -eq 2 ]]'

# ---------------------------------------------------------------- P6 the report
python3 "$HELPER" plan --mode control-plane-only >"$T/cp.plan"
awk -F'\t' -v OFS='\t' '{print $1, $2, 0}' "$T/cp.plan" >"$T/allpass.tsv"
out="$(python3 "$HELPER" report --mode control-plane-only --plan "$T/cp.plan" --results "$T/allpass.tsv")"; rc=$?
check "P6 all run control-plane checks passing → PASS 100%, not-run criteria not counted as passed" \
  '[[ $rc -eq 0 ]] && grep -qE "^PASS: ([0-9]+)/\1 \(100%\) of the run control-plane criteria passed" <<<"$out" && grep -q "not run (never counted as passed): 5 " <<<"$out"'
awk -F'\t' -v OFS='\t' '{print $1, $2, ($2 == "test-idempotence" ? 1 : 0)}' "$T/cp.plan" >"$T/onefail.tsv"
out="$(python3 "$HELPER" report --mode control-plane-only --plan "$T/cp.plan" --results "$T/onefail.tsv")"; rc=$?
check "P6 one failing control-plane check fails SC-006, the aggregate SC-025 and the run" \
  '[[ $rc -ne 0 ]] && grep -q "^SC-006 \[control-plane\] FAIL (test-idempotence exit 1)" <<<"$out" && grep -q "^SC-025 .*aggregate: control-plane criteria failed: SC-006" <<<"$out" && grep -q "^FAIL: " <<<"$out"'
grep -v 'test-reverify' "$T/allpass.tsv" >"$T/skip.tsv"
printf 'standing\ttest-reverify\tSKIP\ttier present\n' >>"$T/skip.tsv"
out="$(python3 "$HELPER" report --mode control-plane-only --plan "$T/cp.plan" --results "$T/skip.tsv")"
check "P6 a skipped check is 'not run', never passed (SC-044)" 'grep -q "^SC-044 \[control-plane\] not run: test-reverify skipped: tier present" <<<"$out"'
out="$(python3 "$HELPER" report --mode control-plane-only --plan "$T/cp.plan" --results /dev/null)"; rc=$?
check "P6 nothing run is a failure, never a silent pass" '[[ $rc -ne 0 ]] && grep -q "run: 0; passed: 0" <<<"$out"'

# ---------------------------------------------------------------- P7 --assert-tier-absent
FK="$T/fake_kubectl"
cat >"$FK" <<'EOF'
#!/usr/bin/env bash
[[ "${FAKE_NS_FAIL:-0}" == 1 ]] && { echo "The connection to the server was refused" >&2; exit 1; }
printf 'namespace/%s\n' kube-system agentic-netops-system ${FAKE_NS_EXTRA:-}
EOF
chmod +x "$FK"
out="$(KUBECTL="$FK" FAKE_NS_EXTRA="agentic-netops-agents agentic-netops-intent" bash "$ACC" --assert-tier-absent 2>&1)"; rc=$?
check "P7 tier namespaces present → fail, naming them" '[[ $rc -ne 0 ]] && grep -q "present on .*agentic-netops-agents agentic-netops-intent" <<<"$out"'
out="$(KUBECTL="$FK" bash "$ACC" --assert-tier-absent 2>&1)"; rc=$?
check "P7 tier absent → ok" '[[ $rc -eq 0 ]] && grep -q "OK the intent tier is absent" <<<"$out"'
out="$(KUBECTL="$FK" FAKE_NS_FAIL=1 bash "$ACC" --assert-tier-absent 2>&1)"; rc=$?
check "P7 namespaces unreadable → fail closed" '[[ $rc -ne 0 ]] && grep -q "fail closed" <<<"$out"'

# ---------------------------------------------------------------- P8 the executor on a fixture
exec_acc() {
  env KUBECTL="$FK" ACCEPTANCE_PARTITION="$TD/exec_partition.yaml" ACCEPTANCE_LEFTOVERS_SCAN=true \
    ACCEPTANCE_STANDING_CHECK=true \
    ACCEPTANCE_EVIDENCE_BASE="$T/$1/ev" ACCEPTANCE_WORK_DIR="$T/$1/work" \
    EVIDENCE_CLUSTER=fixture EVIDENCE_CLUSTER_UID=00000000-fixture EVIDENCE_LAB=fixture-lab \
    EVIDENCE_DEVICE_IMAGE_DIGEST="sha256:$(printf '0%.0s' {1..64})" "${@:2}" bash "$ACC" 2>&1
}
out="$(exec_acc x1 CONTROL_PLANE_ONLY=1 FAKE_NS_EXTRA=agentic-netops-agents)"; rc=$?
check "P8 control-plane-only, tier present: assert-tier-absent fails, the tier-absent check is SKIPPED (not run), the run fails" \
  '[[ $rc -ne 0 ]] && grep -q "^SC-906 \[control-plane\] FAIL (assert-tier-absent exit 1)" <<<"$out" && grep -q "^SC-903 \[control-plane\] not run: absent-only skipped: tier present" <<<"$out"'
check "P8 the tier criterion, the tier half, the manual check, the lifecycle part and the tombstone are reported" \
  'grep -qxF "SC-902 [tier] not run: tier absent" <<<"$out" && grep -qxF "SC-904 [both] control-plane half: PASS; tier half: not run: tier absent" <<<"$out" && grep -qxF "SC-905 [control-plane] not run: manual (T999)" <<<"$out" && grep -q "^SC-907 \[control-plane\] not run: lifecycle step deploy (cycles only)" <<<"$out" && grep -q "^SC-900 retired (tombstone)" <<<"$out"'
check "P8 evidence recorded per scope (offline, standing) and verify-evidence ran over each of them" \
  '[[ -f $T/x1/ev/offline/acceptance.ok-offline.json && -f $T/x1/ev/standing/acceptance.ok-live.json && -f $T/x1/ev/closing/acceptance.verify-evidence.offline.json && -f $T/x1/ev/closing/acceptance.verify-evidence.standing.json ]]'
out="$(exec_acc x2 CONTROL_PLANE_ONLY=1)"; rc=$?
check "P8 control-plane-only, tier absent, all run checks pass → exit 0, PASS 100%, verify-evidence over its dirs passed" \
  '[[ $rc -eq 0 ]] && grep -q "^PASS: 4/4 (100%) of the run control-plane criteria passed" <<<"$out" && grep -q "^-- ok verify-evidence" <<<"$out" && ! grep -q "^-- FAIL" <<<"$out"'
out="$(exec_acc x3 ACCEPTANCE_CYCLES=2)"; rc=$?
check "P8 full mode: 2 cycles recorded in their own evidence directories, tier checks after the deploy" \
  '[[ $rc -eq 0 && -f $T/x3/ev/cycle-1/acceptance.deploy.json && -f $T/x3/ev/cycle-2/acceptance.tier-live.json ]] && grep -qxF "SC-902 [tier] PASS" <<<"$out"'
out="$(exec_acc x4 ACCEPTANCE_CYCLES=1 ACC_FIXTURE_OK_LIVE_RC=1)"; rc=$?
check "P8 full mode: a failing live check fails its criteria and the run" \
  '[[ $rc -ne 0 ]] && grep -q "^SC-901 \[control-plane\] FAIL (ok-live exit 1)" <<<"$out"'

# ---------------------------------------------------------------- P9 a standing lab refuses the cycles
out="$(exec_acc x5 ACCEPTANCE_CYCLES=1 ACCEPTANCE_STANDING_CHECK='echo "STANDING kind cluster agentic-netops"; exit 1')"; rc=$?
check "P9 full mode on a standing lab → refused non-zero naming it, nothing run, nothing torn down" \
  '[[ $rc -ne 0 ]] && grep -q "STANDING kind cluster agentic-netops" <<<"$out" && grep -q "REFUSED to start: the cycles are CLEAN" <<<"$out" && [[ ! -e $T/x5/ev/offline && ! -e $T/x5/ev/cycle-1 ]]'
out="$(exec_acc x6 CONTROL_PLANE_ONLY=1 ACCEPTANCE_STANDING_CHECK='echo "STANDING kind cluster agentic-netops"; exit 1')"; rc=$?
check "P9 negative: control-plane-only runs on the standing lab (no standing refusal)" \
  '[[ $rc -eq 0 ]] && ! grep -q "REFUSED to start" <<<"$out"'

# ---------------------------------------------------------------- P10 one retry per step (2026-09-27-t151-one-retry)
out="$(exec_acc x7 ACCEPTANCE_CYCLES=1 ACC_FIXTURE_FLAKY="$T/x7/state")"; rc=$?
row="$(awk -F'\t' '$2 == "flaky-live"' "$T/x7/work/results.tsv")"
check "P10 a step failing once and passing its re-run → ok-after-retry, counted as passed, run exits 0" \
  '[[ $rc -eq 0 && "$row" == $'"'"'cycle-1\tflaky-live\t0\tok-after-retry\tfirst-exit=1'"'"' ]] && grep -qxF "SC-901 [control-plane] PASS" <<<"$out"'
check "P10 both attempts keep their evidence: the first (exit 1) and <id>.retry1 (exit 0)" \
  'jq -e ".exit_status == 1" "$T/x7/ev/cycle-1/acceptance.flaky-live.json" >/dev/null && jq -e ".exit_status == 0" "$T/x7/ev/cycle-1/acceptance.flaky-live.retry1.json" >/dev/null'
check "P10 the report lists the step by name as ok-after-retry" \
  'grep -q "^steps passed only on their one re-run (ok-after-retry): 1: cycle-1/flaky-live (first-exit=1)" <<<"$out"'
check "P10 verify-evidence accepts the pair and shows it" \
  'grep -q "^-- ok verify-evidence" <<<"$out" && grep -qh "^ok-after-retry: acceptance.flaky-live (first attempt exit 1; re-run exit 0)" "$T"/x7/ev/closing/acceptance.verify-evidence.cycle-1*.stdout'
check "P10 other steps record plain ok" 'grep -qP "^cycle-1\tok-live\t0\tok$" "$T/x7/work/results.tsv"'
out="$(exec_acc x8 ACCEPTANCE_CYCLES=1 ACC_FIXTURE_FLAKY="$T/x8/state" ACC_FIXTURE_FLAKY_RC2=4)"; rc=$?
check "P10 a step failing twice → FAIL (final rc, first-exit recorded), its criterion and the run fail" \
  '[[ $rc -ne 0 ]] && grep -qP "^cycle-1\tflaky-live\t4\tFAIL\tfirst-exit=1$" "$T/x8/work/results.tsv" && grep -q "^SC-901 \[control-plane\] FAIL (flaky-live exit 4)" <<<"$out"'
out="$(exec_acc x9 ACCEPTANCE_CYCLES=1 ACC_FIXTURE_FLAKY="$T/x9/state" ACCEPTANCE_STEP_RETRIES=0)"; rc=$?
check "P10 ACCEPTANCE_STEP_RETRIES=0 → no re-run, FAIL, no .retry1 record" \
  '[[ $rc -ne 0 && ! -e $T/x9/ev/cycle-1/acceptance.flaky-live.retry1.json ]] && grep -qP "^cycle-1\tflaky-live\t1\tFAIL$" "$T/x9/work/results.tsv"'
out="$(exec_acc x10 ACCEPTANCE_STEP_RETRIES=2)"; rc=$?
check "P10 ACCEPTANCE_STEP_RETRIES above 1 is refused (one retry is the most T151 admits)" '[[ $rc -eq 2 ]]'

# ---------------------------------------------------------------- P11 re-run only the failures (standing lab)
out="$(exec_acc x11 ACCEPTANCE_ONLY=ok-live ACCEPTANCE_STANDING_CHECK='echo "STANDING kind cluster agentic-netops"; exit 1')"; rc=$?
check "P11 ACCEPTANCE_ONLY on a standing lab: only the named step, no deploy/destroy, verify-evidence over it, exit 0" \
  '[[ $rc -eq 0 ]] && [[ "$(cut -f2 "$T/x11/work/results.tsv" | tr "\n" " ")" == "ok-live verify-evidence " ]] && [[ -f $T/x11/ev/standing/acceptance.ok-live.json && ! -e $T/x11/ev/cycle-1 ]] && grep -q "a delta — T151 evidence, linked to: none" <<<"$out"'
printf 'cycle-1\tok-live\t0\tok\ncycle-2\tflaky-live\t3\tFAIL\tfirst-exit=1\ncycle-2\ttier-live\tSKIP\tdeploy-tier failed\n' >"$T/prev.tsv"
out="$(exec_acc x12 ACCEPTANCE_RERUN_FROM="$T/prev.tsv")"; rc=$?
check "P11 ACCEPTANCE_RERUN_FROM re-runs exactly the steps recorded FAIL" \
  '[[ $rc -eq 0 ]] && [[ "$(cut -f2 "$T/x12/work/results.tsv" | tr "\n" " ")" == "flaky-live verify-evidence " ]]'
out="$(exec_acc x13 ACCEPTANCE_ONLY=ok-live ACC_FIXTURE_OK_LIVE_RC=1)"; rc=$?
check "P11 a re-run step that still fails (after its one retry) → exit non-zero" '[[ $rc -ne 0 ]] && grep -q "FAIL" "$T/x13/work/report.txt"'
out="$(exec_acc x14 ACCEPTANCE_ONLY=deploy)"; rc=$?
check "P11 a lifecycle step is refused (a re-run never deploys or destroys)" '[[ $rc -eq 2 ]] && grep -q "lifecycle step" <<<"$out" && [[ ! -e $T/x14/ev/standing ]]'
out="$(exec_acc x15 ACCEPTANCE_ONLY=no-such-step)"; rc=$?
check "P11 an unknown step is refused, naming it" '[[ $rc -eq 2 ]] && grep -q "no step .no-such-step." <<<"$out"'

# ---------------------------------------------------------------- P12 a delta is linked to its failed step (2026-09-28-t151-delta)
check "P12 the FROM= delta records acceptance.delta-of linking flaky-live to cycle-2/FAIL of prev.tsv" \
  'jq -e ".exit_status == 0" "$T/x12/ev/standing/acceptance.delta-of.json" >/dev/null && grep -qP "^flaky-live\t$T/prev.tsv\tcycle-2\tFAIL$" "$T/x12/ev/standing/acceptance.delta-of.stdout"'
check "P12 verify-evidence prints the link for the delta step" \
  'grep -qh "^delta: flaky-live re-verifies cycle-2/flaky-live (FAIL) of $T/prev.tsv" "$T"/x12/ev/closing/acceptance.verify-evidence.standing*.stdout'
cp -r "$T/x12/ev/standing" "$T/x12-unlinked"
python3 - "$T/x12-unlinked" <<'PYX'
import json, sys, hashlib, os
d = sys.argv[1]
# a fixture: the link list rewritten WITHOUT the step, record re-hashed as if captured so (no post-edit)
open(os.path.join(d, "acceptance.delta-of.stdout"), "w").write("other-step\tnone\tnone\tnone\n")
r = json.load(open(os.path.join(d, "acceptance.delta-of.json")))
r["raw_output"]["stdout"]["sha256"] = hashlib.sha256(open(os.path.join(d, "acceptance.delta-of.stdout"), "rb").read()).hexdigest()
r.pop("record_sha256", None)
r["record_sha256"] = hashlib.sha256(json.dumps(r, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
json.dump(r, open(os.path.join(d, "acceptance.delta-of.json"), "w"), indent=2, sort_keys=True)
PYX
out="$(bash "$ROOT/scripts/lib/verify_evidence.sh" "$T/x12-unlinked" 2>&1)"; rc=$?
check "P12 negative: a delta step with no link line fails verify-evidence, naming the step" \
  '[[ $rc -ne 0 ]] && grep -q "flaky-live is not linked to the failed cycle step" <<<"$out"'

# ---------------------------------------------------------------- P13 close a stopped run (2026-09-28-t151-cycle-from-walk)
exec_acc x16 ACCEPTANCE_CYCLES=1 >/dev/null
mkdir -p "$T/x16/ev/cycle-2"
out="$(exec_acc x16c ACCEPTANCE_CLOSE_OVER="$T/x16/ev" ACCEPTANCE_CLOSE_EXCLUDE="cycle-2=stopped as it began" ACCEPTANCE_WORK_DIR="$T/x16c/work" ACCEPTANCE_LEFTOVERS_SCAN=false)"; rc=$?
check "P13 close over a stopped run: verify-evidence per run dir, the excluded dir recorded with its reason, no leftovers scan, exit 0" \
  '[[ $rc -eq 0 ]] && grep -qP "\tverify-evidence.cycle-1\t0\tok$" "$T/x16c/work/results.tsv" && grep -qP "\tverify-evidence.cycle-2\tEXCLUDED\tEXCLUDED\tstopped as it began$" "$T/x16c/work/results.tsv" && grep -q "^close: PASS" <<<"$out"'
check "P13 the close delta is run-captured in its own closing-delta directory under the run's base" \
  'ls -d "$T"/x16/ev/closing-delta-*/ >/dev/null 2>&1 && ls "$T"/x16/ev/closing-delta-*/acceptance.verify-evidence.cycle-1.json >/dev/null 2>&1'
out="$(exec_acc x16d ACCEPTANCE_CLOSE_OVER="$T/x16/ev" ACCEPTANCE_WORK_DIR="$T/x16d/work")"; rc=$?
check "P13 negative: without the exclusion the empty stopped cycle fails the close" '[[ $rc -ne 0 ]] && grep -q "^close: FAIL" <<<"$out"'
out="$(exec_acc x16e ACCEPTANCE_CLOSE_OVER="$T/x16/ev" ACCEPTANCE_CLOSE_EXCLUDE="cycle-2=" ACCEPTANCE_WORK_DIR="$T/x16e/work")"; rc=$?
check "P13 an exclusion with no reason is refused (never silent)" '[[ $rc -eq 2 ]] && grep -q "carries no reason" <<<"$out"'

printf '\nsc_partition_test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
