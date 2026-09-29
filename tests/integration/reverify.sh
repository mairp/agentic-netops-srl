#!/usr/bin/env bash
# tests/integration/reverify.sh — the live scheduled re-verification check (T167; plan.md SC-044,
# FR-107, NFR-013, AD-40, AD-54, AD-55, AD-62, FR-108). Behind `make test-reverify`.
#
# With a mac-vrf in agentic-netops-services (RV_NETWORK, default lab-macvrf — re-verification is
# the provider's behaviour, so no intent tier is installed) spanning both leaves Ready and its
# Network untouched:
#   maintenance half, run once with REVERIFY_INTERVAL at a test value (RV_TEST_INTERVAL, never below
#     the 30 s floor) and once at the five-minute default: RV_LEAF's uplinks are taken down
#     DECLARATIVELY through Fabric.spec.maintenance[] (removed again from the exit trap, so a
#     timed-out wait fails the run with the fabric already restored); asserted: Ready=False/
#     RoutesMissing naming the leaf or its loopback within one re-verification + one reconciliation
#     interval, status.lastVerifiedTime advancing on every interval, zero Config spec writes caused
#     by the schedule, and Ready=True again within the same bound after the entry is removed.
#   cannot-run half: RV_LEAF is cut from the management network instead — a declared injected fault,
#     recorded in declared-faults.json before it is made, the script having started with
#     leftovers::scan, the uplinks left up — and the service reports Ready=Unknown and
#     Degraded=True, both VerificationFailed naming the leaf, no later than the first pass that
#     cannot read it (one re-verification + one reconciliation interval), and within SC-008's two
#     reconciliation intervals of the Target's own not-Ready transition; no Ready=False and no
#     Ready=True at any poll from that first Unknown until reconnection; lastVerifiedTime not
#     advancing; Ready=True at the first pass after reconnection.
# Negative control first: the check fails for a service that was never Ready. All through evidence_run.
#
# Usage: reverify.sh run | maintenance <test|default> | mgmt-cut
# Environment: RV_NETWORK (lab-macvrf), RV_LEAF (leaf01), RV_UPLINKS (the leaf's fabricPorts from the
#   Fabric inventory), RV_TEST_INTERVAL (120s), RV_INTERVALS (2), RV_HOLD (one re-verification
#   interval), plus suite.sh's.
set -euo pipefail

RV_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/suite.sh
source "$RV_HERE/lib/suite.sh"

: "${RV_NETWORK:=lab-macvrf}"
: "${RV_LEAF:=leaf01}"
: "${RV_TEST_INTERVAL:=120s}"   # the bound (interval + one reconciliation interval) must cover the
                                   # device's own overlay reconvergence after the uplinks return: 66 s
                                   # observed (live-findings 2026-09-24-overlay-reconvergence); still
                                   # far below the 5 min default and above the 30 s floor
: "${RV_INTERVALS:=2}"
RV_ABSENT="vt-scratch-never-ready"
RV_NEG_DONE=0

rv::uplinks() {
  if [[ -n "${RV_UPLINKS:-}" ]]; then tr -s ' ' '\n' <<<"$RV_UPLINKS"; return 0; fi
  lab::kubectl -n "$FABRIC_NAMESPACE" get "$SUITE_FABRIC_RES" "$FABRIC_NAME" -o json \
    | jq -r --arg n "$RV_LEAF" '.spec.inventory[]? | select(.node == $n) | .fabricPorts[]?'
}

# rv::naming — the regex a RoutesMissing message must match: the leaf's name or its loopback
rv::naming() {
  local lb
  lb="$(lab::kubectl -n "$FABRIC_NAMESPACE" get "$SUITE_FABRIC_RES" "$FABRIC_NAME" -o json | jq -r --arg n "$RV_LEAF" '
    ([(.status.allocations // [])[] | select(.node == $n and ((.purpose // "") | test("loopback|system"))) | .value] | first)
    // ([.spec.nodes[] | select(.name == $n) | .systemIPv4] | first) // "" | split("/")[0]')"
  if [[ -n "$lb" ]]; then printf '%s|%s' "$RV_LEAF" "${lb//./\\.}"; else printf '%s' "$RV_LEAF"; fi
}

rv::begin() {
  suite::init reverify || return $?
  suite::refuse_on_leftovers reverify || return $?
  suite::intervals
}

rv::negatives() {
  [[ "$RV_NEG_DONE" == 0 ]] || return 0
  suite::neg RV-ready cond "$SVC_NS" "$RV_ABSENT" 5 Ready=True || true
  suite::neg RV-lvt lvt_advancing "$SVC_NS" "$RV_ABSENT" 1 5 0 || true
  suite::neg RV-routes-missing cond "$SVC_NS" "$RV_ABSENT" 5 "Ready=False/RoutesMissing" || true
  suite::neg RV-unknown unknown_hold "$SVC_NS" "$RV_ABSENT" "$(date +%s)" 5 /dev/null 1 "$RV_LEAF" || true
  local bogus="$EVIDENCE_DIR/rv-gens-bogus.txt"
  echo "vt-scratch-no-such-config 0" >"$bogus"
  suite::neg RV-no-writes gens_equal "$bogus" "$LAB_TARGET_NS" "$SVC_NS" "$RV_NETWORK" || true
  RV_NEG_DONE=1
}

# rv::maintenance <test|default>
rv::maintenance() {
  local mode="$1" bound rc gens ups naming
  case "$mode" in
    test) suite::set_reverify "$RV_TEST_INTERVAL" || return $? ;;
    default) suite::set_reverify default || return $? ;;
    *) echo "usage: $0 maintenance <test|default>" >&2; return 2 ;;
  esac
  bound=$((SUITE_REVERIFY_S + SUITE_RECONCILE_S))
  rv::negatives
  rc=0; suite::check "RV.${mode}.ready" RV-ready --readiness -- cond "$SVC_NS" "$RV_NETWORK" "$bound" Ready=True >/dev/null || rc=$?
  [[ "$rc" -eq 0 ]] || { suite::fail "[$mode] $RV_NETWORK not Ready=True"; return 0; }
  gens="$EVIDENCE_DIR/rv-${mode}-gens.txt"
  bash "$SVC_CHECKS" gens "$LAB_TARGET_NS" "$SVC_NS" "$RV_NETWORK" >"$gens"
  evidence_run "$(gate::id "RV.${mode}.gens-before")" --attach "${gens#"$EVIDENCE_DIR"/}" -- cat "$gens" >/dev/null
  rc=0; suite::check "RV.${mode}.lvt-healthy" RV-lvt --readiness -- lvt_advancing "$SVC_NS" "$RV_NETWORK" "$RV_INTERVALS" "$SUITE_REVERIFY_S" "$SUITE_RECONCILE_S" >/dev/null || rc=$?
  suite::judge "$rc" "[$mode] lastVerifiedTime advanced on every interval (healthy)" "[$mode] lastVerifiedTime did not advance on every interval"

  mapfile -t ups < <(rv::uplinks)
  [[ ${#ups[@]} -gt 0 ]] || { suite::fail "no fabricPorts for $RV_LEAF in the Fabric inventory"; return 0; }
  naming="$(rv::naming)"
  suite::maint_add "$RV_LEAF" "${ups[@]}" || { suite::fail "[$mode] maintenance[] patch refused"; return 0; }
  rc=0; suite::check "RV.${mode}.routes-missing" RV-routes-missing --readiness -- cond "$SVC_NS" "$RV_NETWORK" "$bound" \
    "Ready=False/RoutesMissing~${naming}" >/dev/null || rc=$?
  suite::judge "$rc" "[$mode] Ready=False/RoutesMissing naming ${RV_LEAF} within ${bound}s" "[$mode] no Ready=False/RoutesMissing naming ${RV_LEAF} within ${bound}s"
  rc=0; suite::check "RV.${mode}.lvt-degraded" RV-lvt --readiness -- lvt_advancing "$SVC_NS" "$RV_NETWORK" "$RV_INTERVALS" "$SUITE_REVERIFY_S" "$SUITE_RECONCILE_S" >/dev/null || rc=$?
  suite::judge "$rc" "[$mode] lastVerifiedTime advanced on every interval (RoutesMissing)" "[$mode] lastVerifiedTime stalled while RoutesMissing"
  suite::maint_restore || suite::fail "[$mode] maintenance[] restoration"
  rc=0; suite::check "RV.${mode}.recovered" RV-ready --readiness -- cond "$SVC_NS" "$RV_NETWORK" "$bound" Ready=True >/dev/null || rc=$?
  suite::judge "$rc" "[$mode] Ready=True again within ${bound}s of removing the entry" "[$mode] not Ready=True within ${bound}s of removing the entry"
  rc=0; suite::check "RV.${mode}.no-writes" RV-no-writes --readiness -- gens_equal "$gens" "$LAB_TARGET_NS" "$SVC_NS" "$RV_NETWORK" >/dev/null || rc=$?
  suite::judge "$rc" "[$mode] zero Config spec writes caused by the schedule" "[$mode] a Config spec write happened during the scheduled passes"
}

rv::mgmt_cut() {
  suite::set_reverify "$RV_TEST_INTERVAL" || return $?
  rv::negatives
  local bound=$((SUITE_REVERIFY_S + SUITE_RECONCILE_S)) rc target cut stop uh_id tn_id tn_pid pid healthy hold="${RV_HOLD:-$SUITE_REVERIFY_S}"
  healthy="$(lab::leaves | grep -vxF "$RV_LEAF" | head -1)"
  target="$(gate::target_of "$RV_LEAF" | awk '{print $2}')"
  [[ -n "$target" ]] || { suite::fail "no SDC Target for $RV_LEAF"; return 0; }
  rc=0; suite::check RV.cut.ready RV-ready --readiness -- cond "$SVC_NS" "$RV_NETWORK" "$bound" Ready=True >/dev/null || rc=$?
  [[ "$rc" -eq 0 ]] || { suite::fail "[mgmt-cut] $RV_NETWORK not Ready=True"; return 0; }

  stop="$EVIDENCE_DIR/rv-reconnect.signal"; rm -f "$stop"
  suite::mgmt_cut "$RV_LEAF" "vt-scratch-rv-mgmt-${RV_LEAF}" || { suite::fail "could not cut $RV_LEAF"; return 0; }
  cut="$(date +%s)"
  tn_id="$(gate::id RV.cut.target-notready)"
  evidence_run "$tn_id" --check RV-target-notready -- bash "$SVC_CHECKS" target_notready "$LAB_TARGET_NS" "$target" "$cut" "$bound" >/dev/null 2>&1 &
  tn_pid=$!
  uh_id="$(gate::id RV.cut.unknown)"
  evidence_run "$uh_id" --check RV-unknown --readiness -- bash "$SVC_CHECKS" unknown_hold "$SVC_NS" "$RV_NETWORK" \
    "$cut" "$bound" "$stop" "$((bound + hold + 60))" "$RV_LEAF" "$healthy" >/dev/null 2>&1 &
  pid=$!
  wait "$tn_pid" || true
  # The reconnection signal comes at cut + bound + hold, measured from the cut and never from the
  # end of the Target watch above: that watch can run its whole bound (the Target's not-Ready
  # transition lags a management cut — Open item 20), and a sleep taken after it pushed the signal
  # past unknown_hold's own limit of bound + hold + 60 (T151 r7 cycle 1, live-findings
  # 2026-09-26-t151r7).
  local left=$((cut + bound + hold - $(date +%s)))
  (( left > 0 )) && sleep "$left"
  touch "$stop"
  rc=0; wait "$pid" || rc=$?
  suite::mgmt_restore "$RV_LEAF" || suite::fail "[mgmt-cut] reconnection of $RV_LEAF"

  local tsum usum tnr fu adv tight
  tsum="$(suite::summary "$tn_id")"; usum="$(suite::summary "$uh_id")"
  tnr="$(jq -r '.target_notready_seconds // "null"' <<<"${tsum:-null}")"
  fu="$(jq -r '.first_unknown_seconds // "null"' <<<"${usum:-null}")"
  # `//` would read a recorded `false` as absent (jq's alternative treats false like null).
  adv="$(jq -r '.last_verified_advanced | if . == null then "null" else tostring end' <<<"${usum:-null}")"
  suite::judge "$rc" "[mgmt-cut] Ready=Unknown + Degraded=True VerificationFailed naming $RV_LEAF at t+${fu}s (bound ${bound}s), neither True nor False until reconnection" \
    "[mgmt-cut] $(grep -h '^FAIL' "$EVIDENCE_DIR/$uh_id.stdout" 2>/dev/null | tail -1)"
  # AD-62: within two reconciliation intervals of the Target's own not-Ready when that came sooner
  if [[ "$tnr" != null && "$fu" != null ]]; then
    tight=$((tnr + 2 * SUITE_RECONCILE_S))
    if (( fu > tight && tight < bound )); then
      suite::fail "[mgmt-cut] first Unknown at t+${fu}s, later than two reconciliation intervals after the Target went not-Ready (t+${tnr}s)"
    fi
  fi
  rc=0; [[ "$adv" == false ]] || rc=1
  suite::judge "$rc" "[mgmt-cut] lastVerifiedTime did not advance while the leaf was unreadable" \
    "[mgmt-cut] lastVerifiedTime advanced (or was not recorded: $adv) while the leaf was unreadable"
  suite::fields RV.cut.latencies "$(jq -cn --arg leaf "$RV_LEAF" --argjson tn "$tnr" --argjson fu "$fu" --argjson b "$bound" \
    --argjson rv "$SUITE_REVERIFY_S" --argjson r "$SUITE_RECONCILE_S" \
    '{criterion: "SC-044", leaf: $leaf, reverify_interval_seconds: $rv, reconciliation_interval_seconds: $r, bound_seconds: $b,
      cut_to_target_not_ready_seconds: $tn, cut_to_first_unknown_seconds: $fu}')"
  rc=0; suite::check RV.cut.recovered RV-ready --readiness -- cond "$SVC_NS" "$RV_NETWORK" "$bound" Ready=True >/dev/null || rc=$?
  suite::judge "$rc" "[mgmt-cut] Ready=True at the first pass after reconnection" "[mgmt-cut] not Ready=True within ${bound}s of reconnection"
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    run) rv::begin || return $?; rv::maintenance test; rv::maintenance default; rv::mgmt_cut; suite::finish reverify ;;
    maintenance)
      [[ "${1:-}" == test || "${1:-}" == default ]] || { echo "usage: $0 maintenance <test|default>" >&2; return 2; }
      rv::begin || return $?; rv::maintenance "$1"; suite::finish reverify ;;
    mgmt-cut) rv::begin || return $?; rv::mgmt_cut; suite::finish reverify ;;
    *) echo "usage: $0 run | maintenance <test|default> | mgmt-cut" >&2; return 2 ;;
  esac
}

main "$@"
