#!/usr/bin/env bash
# acceptance.sh — `make test-acceptance`: the success criteria, measured by the checks
# tests/e2e/sc_partition.yaml assigns them (T151, T175; plan.md §Verification strategy; SC-025,
# NFR-006, NFR-013, FR-108).
#
#   0. leftovers::scan (tests/lib/leftovers.sh) FIRST: any leftover refuses the start, non-zero,
#      naming it — nothing is cleaned up (FR-108).
#   Default (full) mode:
#   0b. a CLEAN deploy needs nothing standing: the run refuses to start, non-zero, naming what
#      stands, while the Kind cluster kind-<cluster> or any containerlab node of the lab exists —
#      it never tears a standing lab down itself (run scripts/off.sh first);
#   1. the offline checks, once;
#   2. ACCEPTANCE_CYCLES (default 3) cycles of
#        deploy → redeploy → control-plane live checks → deploy-tier → tier live checks →
#        destroy → redestroy
#      (a failed deploy skips that cycle's live checks — reported, never passed — and the destroy
#      steps still run; a failed deploy-tier skips the tier checks);
#   3. closing: make verify-evidence over each of the run's evidence directories, and
#      scripts/lib/verify_pins.sh --no-pending;
#   4. the report: every criterion PASS | FAIL | not run: <why> | retired (tombstone), and the
#      summary with its denominator. Exit 0 only when no criterion failed and something ran.
#   CONTROL_PLANE_ONLY=1 (SC-025 — the tier-absent pass on the STANDING lab): no lifecycle step,
#      no cycles; the offline and live checks of the control-plane criteria and the control-plane
#      halves of `both` ones, assert-tier-absent first (a present tier skips every
#      `requires: tier-absent` check, reported); every tier criterion (and tier half) reported
#      `not run: tier absent`, manual checks `not run: manual (Txxx)`, lifecycle-only parts
#      `not run: lifecycle step … (cycles only)`; passes only if 100% of the run control-plane
#      criteria pass. Then the same closing steps.
#   ACCEPTANCE_DRY_RUN=1: after the leftover scan, print the plan — every step, in order, and what
#      each criterion would be reported as — and execute nothing.
#
# Every check runs as `bash -c "<run>"` from the repository root through evidence_run (id
# acceptance.<check>), with EVIDENCE_DIR = <base>/<scope>: preflight (the scan), offline,
# cycle-<n> | standing, closing. <base> = ACCEPTANCE_EVIDENCE_BASE, default
# ${EVIDENCE_ROOT:-.evidence}/<cluster>_<lab>/acceptance-<UTC run id>. The plan, the results and
# the report go to ACCEPTANCE_WORK_DIR (default bin/acceptance/<run id>) — never into an evidence
# directory (verify-evidence admits no hand-placed file).
#
# One retry (operator decision 2026-09-27-t151-one-retry; SC-005): a step that fails is re-run ONCE
#   in the same cycle, under its own evidence id (<id>.retry1) so the first attempt's evidence is
#   kept; it counts as passed only if the re-run passes. results.tsv records, per step,
#   `<scope> <check> <final rc> ok|ok-after-retry|FAIL [first-exit=<rc>]`, and the report lists
#   every ok-after-retry step by name. ACCEPTANCE_STEP_RETRIES (0 or 1, default 1). A deploy step
#   (lifecycle) is retried like any other — provisioning is idempotent — and closing steps are not.
# Re-run only the failures — a DELTA, which IS T151 evidence (operator decision 2026-09-28-t151-delta):
#   ACCEPTANCE_ONLY=<check,…> or
#   ACCEPTANCE_RERUN_FROM=<results.tsv> (every step it records as FAIL) runs just those live and
#   offline checks once against the STANDING lab — no deploy, no destroy, no cycles, no criteria
#   report — then verify-evidence over what it wrote; exit 0 only if every named step passed.
#   `make test-acceptance-rerun ONLY=… | FROM=…`. A lifecycle step named there is refused. Each
#   delta is LINKED to the failed cycle step it re-verifies: FROM= links every step to that
#   results.tsv; with ONLY=, ACCEPTANCE_DELTA_OF=<results.tsv> names the run whose failure it
#   re-verifies (else the link reads "none"). The link is the run-captured record
#   acceptance.delta-of (`<check> <results.tsv> <scope> <outcome>` per line), which
#   verify-evidence requires for every step record of a delta directory and prints.
# Close a stopped run — a DELTA of its closing steps (operator decision 2026-09-28-t151-cycle-from-walk):
#   ACCEPTANCE_CLOSE_OVER=<evidence base> runs the closing steps (verify-evidence over each of that
#   base's run directories, verify_pins --no-pending) against a run that was stopped before its own
#   end; ACCEPTANCE_CLOSE_EXCLUDE="<dir>=<reason>;…" leaves out a directory (a cycle stopped as it
#   began), each exclusion recorded with its reason in results.tsv — an exclusion with no reason is
#   refused. No live step, no lab needed, no leftovers scan (nothing is deployed or probed).
# Environment: CONTROL_PLANE_ONLY, ACCEPTANCE_CYCLES, ACCEPTANCE_DRY_RUN, ACCEPTANCE_PARTITION
#   (default tests/e2e/sc_partition.yaml), ACCEPTANCE_EVIDENCE_BASE, ACCEPTANCE_WORK_DIR,
#   ACCEPTANCE_LEFTOVERS_SCAN (test hook: a command run by `bash -c` INSTEAD of leftovers::scan;
#   its stdout's LEFTOVER lines and exit status are treated exactly like the scan's),
#   ACCEPTANCE_STANDING_CHECK (test hook: a command run by `bash -c` INSTEAD of the standing-lab
#   check; its STANDING lines and a non-zero exit refuse the full-mode start), CLUSTER_NAME,
#   ACCEPTANCE_PROVIDER_LABEL (the corpora's provider label).
#
# Usage: acceptance.sh                      the run (mode from the environment)
#        acceptance.sh --assert-tier-absent  exit 0 iff no intent-tier namespace exists on
#                                            kind-<cluster> (fails closed when unreadable)
set -uo pipefail

ACC_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ACC_HELPER="$ACC_ROOT/tests/e2e/lib/sc_partition.py"
ACC_PARTITION="${ACCEPTANCE_PARTITION:-$ACC_ROOT/tests/e2e/sc_partition.yaml}"
ACC_TIER_NAMESPACES=(agentic-netops-agents agentic-netops-intent)

acc::log() { printf 'acceptance: %s\n' "$*" >&2; }

# acc::assert_tier_absent — the SC-025 precondition of a control-plane-only pass.
acc::assert_tier_absent() {
  local ctx="${KUBE_CONTEXT:-kind-${CLUSTER_NAME:-agentic-netops}}" out ns present=()
  if ! out="$("${KUBECTL:-kubectl}" --context "$ctx" --request-timeout=10s get namespaces -o name 2>&1)"; then
    printf '%s\n' "$out" >&2
    acc::log "FAIL cannot list the namespaces of $ctx — the tier's absence is unproven (fail closed)"
    return 1
  fi
  for ns in "${ACC_TIER_NAMESPACES[@]}"; do
    grep -qx "namespace/$ns" <<<"$out" && present+=("$ns")
  done
  if [[ ${#present[@]} -gt 0 ]]; then
    acc::log "FAIL the intent tier is present on $ctx: namespace(s) ${present[*]}"
    return 1
  fi
  acc::log "OK the intent tier is absent on $ctx (no namespace ${ACC_TIER_NAMESPACES[*]})"
}

case "${1:-}" in
  "") ;;
  --assert-tier-absent) acc::assert_tier_absent; exit $? ;;
  -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *) acc::log "unknown argument '$1'"; exit 2 ;;
esac

# shellcheck source=../../scripts/lib/evidence.sh
source "$ACC_ROOT/scripts/lib/evidence.sh"
# shellcheck source=../lib/leftovers.sh
source "$ACC_ROOT/tests/lib/leftovers.sh"

mode=full
[[ "${CONTROL_PLANE_ONLY:-0}" == 1 ]] && mode=control-plane-only
retries="${ACCEPTANCE_STEP_RETRIES:-1}"
if ! [[ "$retries" =~ ^[01]$ ]]; then
  acc::log "ACCEPTANCE_STEP_RETRIES must be 0 or 1, got '$retries' (one retry is the most T151 admits)"
  exit 2
fi
only=()
if [[ -n "${ACCEPTANCE_RERUN_FROM:-}" ]]; then
  if [[ ! -r "$ACCEPTANCE_RERUN_FROM" ]]; then acc::log "ACCEPTANCE_RERUN_FROM: cannot read '$ACCEPTANCE_RERUN_FROM'"; exit 2; fi
  mapfile -t only < <(awk -F'\t' '$1 != "closing" && ($4 == "FAIL" || ($3 != "0" && $3 != "SKIP" && $4 == "")) {print $2}' \
    "$ACCEPTANCE_RERUN_FROM" | sort -u)
  if [[ ${#only[@]} -eq 0 ]]; then acc::log "ACCEPTANCE_RERUN_FROM: no failed step in $ACCEPTANCE_RERUN_FROM — nothing to re-run"; exit 0; fi
fi
if [[ -n "${ACCEPTANCE_ONLY:-}" ]]; then
  IFS=',' read -r -a _o <<<"$ACCEPTANCE_ONLY"
  only+=("${_o[@]}")
fi
[[ ${#only[@]} -gt 0 ]] && mode=rerun
[[ -n "${ACCEPTANCE_CLOSE_OVER:-}" ]] && mode=close
delta_of="${ACCEPTANCE_RERUN_FROM:-${ACCEPTANCE_DELTA_OF:-none}}"
cycles="${ACCEPTANCE_CYCLES:-3}"
if ! [[ "$cycles" =~ ^[1-9][0-9]*$ ]]; then
  acc::log "ACCEPTANCE_CYCLES must be a positive integer, got '$cycles'"
  exit 2
fi
dry=false
[[ "${ACCEPTANCE_DRY_RUN:-0}" == 1 ]] && dry=true

run_id="$(date -u +%Y%m%dT%H%M%SZ)"
unset EVIDENCE_DIR   # the run owns its evidence directories
# every cycle generates new device credentials: a check reads them from the lab that stands
# (lab::export_creds), never a value this shell inherited from an earlier lab
unset SRL_USER SRL_PASS GNMIC_USERNAME GNMIC_PASSWORD
if [[ "$mode" == close ]]; then
  base="${ACCEPTANCE_CLOSE_OVER%/}"
  [[ -d "$base" ]] || { acc::log "ACCEPTANCE_CLOSE_OVER: no evidence base '$base'"; exit 2; }
elif [[ -n "${ACCEPTANCE_EVIDENCE_BASE:-}" ]]; then
  base="$ACCEPTANCE_EVIDENCE_BASE"
else
  lab_id="$(evidence::lab_name 2>/dev/null)" || lab_id="${LAB_NAME:-agentic-netops-fabric}"
  base="${EVIDENCE_ROOT:-$ACC_ROOT/.evidence}/$(evidence::cluster_name)_${lab_id}/acceptance-${run_id}"
fi
if [[ "$dry" == true ]]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
else
  work="${ACCEPTANCE_WORK_DIR:-$ACC_ROOT/bin/acceptance/$run_id}"
  mkdir -p "$work"
fi

# ---------------------------------------------------------------- close mode (a stopped run's closing)
if [[ "$mode" == close ]]; then
  results="$work/results.tsv"; : >"$results"
  scope="closing-delta-${run_id}"
  declare -A excl=()
  if [[ -n "${ACCEPTANCE_CLOSE_EXCLUDE:-}" ]]; then
    IFS=';' read -r -a _ex <<<"$ACCEPTANCE_CLOSE_EXCLUDE"
    for e in "${_ex[@]}"; do
      [[ -z "$e" ]] && continue
      if [[ "$e" != *=* || -z "${e#*=}" ]]; then
        acc::log "ACCEPTANCE_CLOSE_EXCLUDE: '$e' carries no reason — an exclusion is recorded with its reason, never silent"; exit 2
      fi
      excl["${e%%=*}"]="${e#*=}"
    done
  fi
  full="$work/plan.full.tsv"
  python3 "$ACC_HELPER" --partition "$ACC_PARTITION" plan --mode full --cycles 1 >"$full" \
    || { acc::log "cannot plan from $ACC_PARTITION"; exit 2; }
  awk -F'\t' '$1 == "closing"' "$full" >"$work/plan.tsv"
  dirs=()
  for d in "$base"/*/; do
    d="${d%/}"; n="$(basename "$d")"
    [[ "$n" == closing* ]] && continue
    if [[ -n "${excl[$n]:-}" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$scope" "verify-evidence.$n" EXCLUDED EXCLUDED "${excl[$n]}" >>"$results"
      echo "-- EXCLUDED $n: ${excl[$n]}"; continue
    fi
    dirs+=("$d")
  done
  for n in "${!excl[@]}"; do [[ -d "$base/$n" ]] || { acc::log "ACCEPTANCE_CLOSE_EXCLUDE: no directory '$n' under $base"; exit 2; }; done
  [[ ${#dirs[@]} -eq 0 ]] && { acc::log "close: no run directory to verify under $base"; exit 2; }
  crc=0
  while IFS=$'\t' read -r _s check _k _a run; do
    if [[ "$run" == *verify-evidence* ]]; then
      for d in "${dirs[@]}"; do
        ( cd "$ACC_ROOT" && export EVIDENCE_DIR="$base/$scope" && evidence::ensure_dir >/dev/null \
          && evidence_run "acceptance.$check.$(basename "$d")" -- env "EVIDENCE_DIR=$d" bash -c "$run" ); r=$?
        printf '%s\t%s\t%s\t%s\n' "$scope" "$check.$(basename "$d")" "$r" "$([[ $r -eq 0 ]] && echo ok || echo FAIL)" >>"$results"
        [[ $r -eq 0 ]] || crc=1
      done
    else
      ( cd "$ACC_ROOT" && export EVIDENCE_DIR="$base/$scope" && evidence::ensure_dir >/dev/null \
        && evidence_run "acceptance.$check" -- bash -c "$run" ); r=$?
      printf '%s\t%s\t%s\t%s\n' "$scope" "$check" "$r" "$([[ $r -eq 0 ]] && echo ok || echo FAIL)" >>"$results"
      [[ $r -eq 0 ]] || crc=1
    fi
  done <"$work/plan.tsv"
  # the closing delta's own directory, verified last (it holds only run-captured records)
  ( cd "$ACC_ROOT" && EVIDENCE_DIR="$base/$scope" bash scripts/lib/verify_evidence.sh ); r=$?
  printf '%s\t%s\t%s\t%s\n' "$scope" "verify-evidence.$scope" "$r" "$([[ $r -eq 0 ]] && echo ok || echo FAIL)" >>"$results"
  [[ $r -eq 0 ]] || crc=1
  { echo "== acceptance close (delta of the closing steps of $base)"
    while IFS=$'\t' read -r sc ck frc oc dt; do printf '%-30s %-44s %s%s\n' "$sc" "$ck" "$oc" "${dt:+ ($dt)}"; done <"$results"
    echo "close: $([[ $crc -eq 0 ]] && echo PASS || echo FAIL)"; } | tee "$work/report.txt"
  acc::log "evidence: $base/$scope; results, report: $work"
  exit "$crc"
fi

# ---------------------------------------------------------------- 0. leftovers first (FR-108)
acc::scan() {
  if [[ -n "${ACCEPTANCE_LEFTOVERS_SCAN:-}" ]]; then
    bash -c "$ACCEPTANCE_LEFTOVERS_SCAN"
  else
    # shellcheck disable=SC2030 # the scan's evidence directory, for the scan only
    # run under evidence_run so the preflight directory always holds the scan's own record — on a
    # clean host the scan reads nothing through evidence_run and left an empty, failing directory
    # (T151 r8 closing verify-evidence: "no evidence records")
    ( export EVIDENCE_DIR="$base/preflight"; evidence::ensure_dir || exit 3
      rc=0; evidence_run acceptance.leftovers-scan -- leftovers::scan || rc=$?
      cat "$EVIDENCE_DIR/acceptance.leftovers-scan.stdout" 2>/dev/null; exit "$rc" )
  fi
}
scan_out="$(acc::scan)"; scan_rc=$?
[[ -n "$scan_out" ]] && printf '%s\n' "$scan_out"
if [[ "$scan_rc" -ne 0 ]]; then
  leftovers_found="$(grep '^LEFTOVER ' <<<"$scan_out" || true)"
  acc::log "REFUSED to start: leftovers::scan failed (exit $scan_rc)${leftovers_found:+ — leftover(s) present:}"
  [[ -n "$leftovers_found" ]] && while IFS= read -r l; do printf 'acceptance:   %s\n' "$l" >&2; done <<<"$leftovers_found"
  acc::log "nothing was run and nothing was cleaned up; run leftovers::remove explicitly (FR-108)"
  exit 1
fi

# ---------------------------------------------------------------- 0b. a clean deploy (full mode)
# acc::standing — print one STANDING line per standing part of the lab; non-zero when any stands.
acc::standing() {
  if [[ -n "${ACCEPTANCE_STANDING_CHECK:-}" ]]; then
    bash -c "$ACCEPTANCE_STANDING_CHECK"; return $?
  fi
  local cluster="${CLUSTER_NAME:-agentic-netops}" lab n=0 c
  lab="$(evidence::lab_name 2>/dev/null)" || lab="${LAB_NAME:-agentic-netops-fabric}"
  if kind get clusters 2>/dev/null | grep -qxF -- "$cluster"; then
    echo "STANDING kind cluster $cluster"; n=$((n + 1))
  fi
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    echo "STANDING containerlab node $c (lab $lab)"; n=$((n + 1))
  done < <(docker ps -a --filter "label=containerlab=$lab" --format '{{.Names}}' 2>/dev/null)
  [[ "$n" -eq 0 ]]
}
if [[ "$mode" == full && "$dry" == false ]]; then
  if ! standing_out="$(acc::standing)"; then
    [[ -n "$standing_out" ]] && while IFS= read -r l; do printf 'acceptance:   %s\n' "$l" >&2; done <<<"$standing_out"
    acc::log "REFUSED to start: the cycles are CLEAN deploy → test → destroy cycles and a lab is standing (SC-005);"
    acc::log "nothing was run and nothing was torn down; remove it with scripts/off.sh first"
    exit 1
  fi
fi

# ---------------------------------------------------------------- the plan
plan="$work/plan.tsv"
results="$work/results.tsv"
if [[ "$mode" == rerun ]]; then
  # the named steps, once, on the standing lab: taken from a one-cycle full plan, in its order
  full="$work/plan.full.tsv"
  if ! python3 "$ACC_HELPER" --partition "$ACC_PARTITION" plan --mode full --cycles 1 >"$full"; then
    acc::log "cannot plan from $ACC_PARTITION"; exit 2
  fi
  : >"$plan"
  for c in "${only[@]}"; do
    row="$(awk -F'\t' -v c="$c" '$2 == c && $1 != "closing" {print; exit}' "$full")"
    if [[ -z "$row" ]]; then acc::log "ACCEPTANCE_ONLY: no step '$c' in the plan"; exit 2; fi
    if [[ "$(cut -f3 <<<"$row")" == lifecycle:* ]]; then
      acc::log "ACCEPTANCE_ONLY: '$c' is a lifecycle step — a re-run never deploys or destroys (run the cycles)"; exit 2
    fi
  done
  awk -F'\t' -v OFS='\t' -v list=",$(IFS=,; echo "${only[*]}")," \
    '$1 != "closing" && index(list, "," $2 ",") && !seen[$2]++ {$1 = "standing"; print}' "$full" >>"$plan"
  awk -F'\t' '$1 == "closing" && $2 == "verify-evidence"' "$full" >>"$plan"
elif ! python3 "$ACC_HELPER" --partition "$ACC_PARTITION" plan --mode "$mode" --cycles "$cycles" >"$plan"; then
  acc::log "cannot plan from $ACC_PARTITION"
  exit 2
fi
: >"$results"

if [[ "$dry" == true ]]; then
  if [[ "$mode" == full ]]; then
    echo "== acceptance plan: mode $mode, $cycles cycle(s) — dry run, nothing executed"
  else
    echo "== acceptance plan: mode $mode (standing lab, no lifecycle step) — dry run, nothing executed"
  fi
  n=0
  while IFS=$'\t' read -r scope check kind attach run; do
    n=$((n + 1))
    printf '  [%d] %-9s %-32s %-36s %s%s\n' "$n" "$scope" "$kind" "$check" "$run" \
      "$([[ "$attach" != - ]] && printf ' (attach %s)' "$attach")"
  done <"$plan"
  python3 "$ACC_HELPER" --partition "$ACC_PARTITION" report --mode "$mode" --plan "$plan" --plan-only
  exit 0
fi

# ---------------------------------------------------------------- execution
evidence_dirs=()
if [[ "$mode" == rerun ]]; then
  # the delta's link to the failed cycle step it re-verifies, as a run-captured record (T151 delta)
  links="$work/delta-of.tsv"; : >"$links"
  while IFS=$'\t' read -r _s c _k _a _r; do
    [[ "$_s" == closing ]] && continue
    if [[ -r "$delta_of" ]]; then
      row="$(awk -F'\t' -v c="$c" '$2 == c && $1 != "closing" && ($4 == "FAIL" || ($3 != "0" && $3 != "SKIP" && $4 == "")) {print $1"\t"($4 == "" ? "FAIL" : $4); exit}' "$delta_of")"
      printf '%s\t%s\t%s\n' "$c" "$delta_of" "${row:-none	not-failed}" >>"$links"
    else
      printf '%s\t%s\t%s\t%s\n' "$c" none none none >>"$links"
    fi
  done <"$plan"
  ( cd "$ACC_ROOT" && export EVIDENCE_DIR="$base/standing" && evidence::ensure_dir >/dev/null \
    && evidence_run acceptance.delta-of -- cat "$links" >/dev/null )
  acc::note_dir "$base/standing"
fi
acc::note_dir() {
  local d
  for d in "${evidence_dirs[@]}"; do [[ "$d" == "$1" ]] && return 0; done
  evidence_dirs+=("$1")
}
acc::result() { printf '%s\n' "$(IFS=$'\t'; echo "$*")" >>"$results"; }

# acc::run <scope> <evidence-id> <check> <attach|-> <run> [VAR=value…] — through evidence_run
acc::run() {
  local scope="$1" id="$2" check="$3" attach="$4" run="$5"; shift 5
  local d="$base/$scope" a expanded rc=0
  # A second provisioning run in one cycle (provision-rerun, provision-tier) re-issues every
  # evidence id the first one wrote, and evidence is never overwritten — so it gets a sibling
  # directory of its own, as every provisioning run outside acceptance does (NFR-013).
  [[ -n "${ACC_OWN_DIR:-}" ]] && d="$base/${scope}.${check}"
  local -a opts=()
  if [[ "$attach" != - ]]; then
    IFS=',' read -r -a _atts <<<"$attach"
    for a in "${_atts[@]}"; do
      expanded="$(A="$a" bash -c 'eval "printf %s \"$A\""')"
      opts+=(--attach "$expanded")
    done
  fi
  acc::note_dir "$d"
  echo "== [$scope] $check: $run"
  acc::_attempt "$d" "$id" "$run" "$@" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    acc::result "$scope" "$check" 0 ok; echo "-- ok $check"; return 0
  fi
  if [[ "$retries" -lt 1 || "$scope" == closing ]]; then
    acc::result "$scope" "$check" "$rc" FAIL; echo "-- FAIL $check (exit $rc)"; return "$rc"
  fi
  # one retry, same cycle, its own evidence id — the first attempt's evidence stays (T151 one-retry)
  local first="$rc"; rc=0
  echo "-- FAIL $check (exit $first) — re-running it once (ACCEPTANCE_STEP_RETRIES=1)"
  acc::_attempt "$d" "$id.retry1" "$run" "$@" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    acc::result "$scope" "$check" 0 ok-after-retry "first-exit=$first"
    echo "-- ok-after-retry $check (first attempt exit $first, evidence $id; re-run $id.retry1)"
    return 0
  fi
  acc::result "$scope" "$check" "$rc" FAIL "first-exit=$first"
  echo "-- FAIL $check (exit $first, re-run exit $rc)"
  return "$rc"
}

# acc::_attempt <evidence dir> <evidence id> <run> [VAR=value…] — one attempt, in a subshell
acc::_attempt() {
  local d="$1" id="$2" run="$3"; shift 3
  (
    cd "$ACC_ROOT" || exit 3
    # shellcheck disable=SC2031 # each check's own evidence directory, in its subshell
    export EVIDENCE_DIR="$d"
    rc=0
    evidence_run "$id" "${opts[@]}" -- env "$@" bash -c "$run" || rc=$?
    # what the step wrote beside its own record — a suite's measurements, its scratch manifests —
    # sealed by one run-captured record, so the closing audit finds nothing unreferenced (T151 r9)
    evidence_seal "$id.sealed" || echo "acceptance: sealing the artefacts of $id failed" >&2
    exit "$rc"
  )
}

deploy_failed="" tier_failed="" tier_present=false
closing=()
while IFS=$'\t' read -r scope check kind attach run; do
  if [[ "$scope" == closing ]]; then
    closing+=("$check"$'\t'"$attach"$'\t'"$run")
    continue
  fi
  case "$kind" in
    lifecycle:deploy)
      deploy_failed="" tier_failed=""
      acc::run "$scope" "acceptance.$check" "$check" "$attach" "$run" || deploy_failed="$scope"
      continue ;;
    lifecycle:deploy-tier)
      if [[ "$deploy_failed" == "$scope" ]]; then
        acc::result "$scope" "$check" SKIP "deploy failed in $scope"; tier_failed="$scope"; continue
      fi
      ACC_OWN_DIR=1 acc::run "$scope" "acceptance.$check" "$check" "$attach" "$run" || tier_failed="$scope"
      continue ;;
    lifecycle:redeploy)
      ACC_OWN_DIR=1 acc::run "$scope" "acceptance.$check" "$check" "$attach" "$run" || true
      continue ;;
    lifecycle:*|offline)
      acc::run "$scope" "acceptance.$check" "$check" "$attach" "$run" || true
      continue ;;
  esac
  # live checks
  if [[ "$deploy_failed" == "$scope" ]]; then
    acc::result "$scope" "$check" SKIP "deploy failed in $scope"; continue
  fi
  if [[ "$kind" == live:tier* && "$tier_failed" == "$scope" ]]; then
    acc::result "$scope" "$check" SKIP "deploy-tier failed in $scope"; continue
  fi
  if [[ "$kind" == *+tier-absent && "$tier_present" == true ]]; then
    acc::result "$scope" "$check" SKIP "tier present (assert-tier-absent failed)"; continue
  fi
  if ! acc::run "$scope" "acceptance.$check" "$check" "$attach" "$run"; then
    [[ "$check" == assert-tier-absent ]] && tier_present=true
  fi
done <"$plan"

# ---------------------------------------------------------------- closing (the run's own end)
[[ -d "$base/preflight" ]] && evidence_dirs=("$base/preflight" "${evidence_dirs[@]}")
for entry in "${closing[@]}"; do
  IFS=$'\t' read -r check attach run <<<"$entry"
  if [[ "$run" == *verify-evidence* ]]; then
    for d in "${evidence_dirs[@]}"; do
      [[ "$d" == "$base/closing" ]] && continue
      acc::run closing "acceptance.$check.$(basename "$d")" "$check" "$attach" "$run" "EVIDENCE_DIR=$d" || true
    done
  else
    acc::run closing "acceptance.$check" "$check" "$attach" "$run" || true
  fi
done

# ---------------------------------------------------------------- the report
if [[ "$mode" == rerun ]]; then
  echo "== acceptance re-run (standing lab; a delta — T151 evidence, linked to: $delta_of)"
  while IFS=$'\t' read -r scope check frc outcome detail; do
    printf '%-9s %-36s %s%s\n' "$scope" "$check" "${outcome:-$frc}" "${detail:+ ($detail)}"
  done <"$results" | tee "$work/report.txt"
  rc=0; awk -F'\t' '$3 != "0" {bad = 1} END {exit bad}' "$results" || rc=1
  acc::log "evidence: $base; plan, results, report: $work"
  exit "$rc"
fi
rc=0
python3 "$ACC_HELPER" --partition "$ACC_PARTITION" report --mode "$mode" --plan "$plan" --results "$results" \
  >"$work/report.txt" || rc=1
cat "$work/report.txt"
acc::log "evidence: $base (${#evidence_dirs[@]} director(ies) verified); plan, results, report: $work"
exit "$rc"
