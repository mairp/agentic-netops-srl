#!/usr/bin/env bash
# tests/integration/target_failure.sh — one leaf cut from the management network (T064; SC-008,
# AD-40, AD-54, AD-62, AD-71, FR-108). Behind `make test-target-failure`.
#
# What it asserts: with a mac-vrf spanning both leaves Ready (TF_NETWORK, default lab-macvrf in
# agentic-netops-services), TF_LEAF is cut from MGMT_NETWORK — a declared injected fault, written to
# declared-faults.json BEFORE it is made, the run having started with leftovers::scan. Within two
# reconciliation intervals (SC-008's 30 s at the 15 s default) the service reports
# Degraded=True/VerificationFailed and Ready=Unknown/VerificationFailed, both naming TF_LEAF, the
# healthy leaf still reported per target (status.renderedConfigs) — and Ready is asserted neither
# True nor False at EVERY poll from that first Unknown until reconnection (the Ready=True of the
# seconds before the platform can know of the cut is not a finding). It RECORDS what the bound rests
# on, as evidence fields: the measured time from the cut to the Target's own not-Ready transition
# and to the first Unknown; a latency beyond the bound fails SC-008 naming the layer's measured
# latency, never waived (Open item 20). A service applied during the outage (vt-scratch-tf-outage),
# never having been Ready, stays Ready=False; Ready=True returns after reconnection, and the scratch
# service is deleted with its removal read back. Every result goes through evidence_run, each
# readiness check after its failing negative control.
#
# Usage: target_failure.sh run
# Environment: TF_NETWORK (lab-macvrf), TF_LEAF (leaf02), TF_HOLD (60 s after the first Unknown),
#   TF_RECOVER_WAIT (default: one re-verification + one reconciliation interval), plus suite.sh's.
set -euo pipefail

TF_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/suite.sh
source "$TF_HERE/lib/suite.sh"

: "${TF_NETWORK:=lab-macvrf}"
: "${TF_LEAF:=leaf02}"
: "${TF_HOLD:=60}"
TF_SCRATCH="vt-scratch-tf-outage"
TF_ABSENT="vt-scratch-never-ready"

tf::healthy() { lab::leaves | grep -vxF "$TF_LEAF" | head -1; }

tf::run() {
  suite::init target-failure || return $?
  suite::refuse_on_leftovers target-failure || return $?
  suite::intervals
  local bound=$((2 * SUITE_RECONCILE_S)) recover="${TF_RECOVER_WAIT:-$((SUITE_REVERIFY_S + SUITE_RECONCILE_S))}"
  local healthy target rc id s cut stop pid tn_id uh_id
  healthy="$(tf::healthy)"
  target="$(gate::target_of "$TF_LEAF" | awk '{print $2}')"
  [[ -n "$target" ]] || { log::error "no SDC Target for $TF_LEAF in $LAB_TARGET_NS"; return 1; }

  # negative controls first (NFR-013)
  suite::neg TF-ready cond "$SVC_NS" "$TF_ABSENT" 5 Ready=True || true
  suite::neg TF-unknown unknown_hold "$SVC_NS" "$TF_ABSENT" "$(date +%s)" 5 /dev/null 1 "$TF_LEAF" || true
  suite::neg TF-never-ready cond_hold "$SVC_NS" "$TF_NETWORK" 2 Ready=False || true   # it is Ready now

  rc=0; suite::check TF.ready TF-ready --readiness -- cond "$SVC_NS" "$TF_NETWORK" "$recover" Ready=True || rc=$?
  [[ "$rc" -eq 0 ]] || { suite::fail "$TF_NETWORK is not Ready=True before the cut"; suite::finish target-failure; return 1; }

  # the cut: declared first, then made; the Target and the service watched from the same instant
  stop="$EVIDENCE_DIR/tf-reconnect.signal"; rm -f "$stop"
  suite::mgmt_cut "$TF_LEAF" "vt-scratch-tf-mgmt-${TF_LEAF}" || { suite::fail "could not cut $TF_LEAF"; suite::finish target-failure; return 1; }
  cut="$(date +%s)"
  tn_id="$(gate::id TF.target-notready)"
  evidence_run "$tn_id" --check TF-target-notready -- bash "$SVC_CHECKS" target_notready "$LAB_TARGET_NS" "$target" "$cut" "$recover" >/dev/null 2>&1 &
  local tn_pid=$!
  uh_id="$(gate::id TF.unknown)"
  evidence_run "$uh_id" --check TF-unknown --readiness -- bash "$SVC_CHECKS" unknown_hold "$SVC_NS" "$TF_NETWORK" \
    "$cut" "$bound" "$stop" "$((recover * 4 + TF_HOLD))" "$TF_LEAF" "$healthy" >/dev/null 2>&1 &
  pid=$!

  # a service applied during the outage, never Ready, stays Ready=False
  suite::apply_macvrf "$TF_SCRATCH" 190 10190 || suite::fail "could not apply $TF_SCRATCH during the outage"
  suite::on_exit tf::delete_scratch
  rc=0; suite::check TF.outage-service TF-never-ready --readiness -- cond_hold "$SVC_NS" "$TF_SCRATCH" "$((2 * SUITE_RECONCILE_S))" Ready=False || rc=$?
  suite::judge "$rc" "$TF_SCRATCH applied during the outage stays Ready=False" "$TF_SCRATCH was not Ready=False throughout the outage"

  # hold after the first Unknown, then signal the watcher and reconnect
  wait "$tn_pid" || true
  # phase 1 of the watcher ends inside the bound; then the hold
  sleep "$bound"
  sleep "$TF_HOLD"
  touch "$stop"
  rc=0; wait "$pid" || rc=$?
  suite::mgmt_restore "$TF_LEAF" || suite::fail "reconnection of $TF_LEAF"
  local reconnect; reconnect="$(date +%s)"

  local tsum usum tnr fu
  tsum="$(suite::summary "$tn_id")"; usum="$(suite::summary "$uh_id")"
  tnr="$(jq -r '.target_notready_seconds // "null"' <<<"${tsum:-null}")"
  fu="$(jq -r '.first_unknown_seconds // "null"' <<<"${usum:-null}")"
  suite::fields TF.latencies "$(jq -cn --arg leaf "$TF_LEAF" --arg t "$target" --argjson tn "$tnr" --argjson fu "$fu" \
    --argjson b "$bound" --argjson r "$SUITE_RECONCILE_S" --argjson c "$cut" --argjson rc "$reconnect" \
    '{criterion: "SC-008", leaf: $leaf, target: $t, reconciliation_interval_seconds: $r, bound_seconds: $b,
      cut_epoch: $c, reconnect_epoch: $rc, cut_to_target_not_ready_seconds: $tn, cut_to_first_unknown_seconds: $fu}')"
  if [[ "$rc" -eq 0 ]]; then
    suite::ok "Ready=Unknown/VerificationFailed + Degraded=True naming $TF_LEAF at t+${fu}s (bound ${bound}s), never True/False until reconnection"
  elif [[ "$fu" == null ]]; then
    suite::fail "SC-008: no Unknown within ${bound}s of the cut; the layer's measured Target not-Ready latency was ${tnr}s"
  else
    suite::fail "SC-008: $(grep -h '^FAIL' "$EVIDENCE_DIR/$uh_id.stdout" | tail -1)"
  fi

  rc=0; suite::check TF.recovered TF-ready --readiness -- cond "$SVC_NS" "$TF_NETWORK" "$recover" Ready=True || rc=$?
  suite::judge "$rc" "Ready=True again after reconnection" "$TF_NETWORK not Ready=True within ${recover}s of reconnection"
  suite::finish target-failure
}

tf::delete_scratch() {
  lab::kubectl -n "$SVC_NS" get "$SUITE_NET_RES" "$TF_SCRATCH" >/dev/null 2>&1 || return 0
  gate::run "TF.delete-scratch" -- lab::kubectl -n "$SVC_NS" delete "$SUITE_NET_RES" "$TF_SCRATCH" --wait=true --timeout=300s >/dev/null || return 1
  leftovers::scan >/dev/null || { log::error "$TF_SCRATCH removal did not read back clean"; return 1; }
}

main() {
  case "${1:-}" in
    run) tf::run ;;
    *) echo "usage: $0 run" >&2; return 2 ;;
  esac
}

main "$@"
