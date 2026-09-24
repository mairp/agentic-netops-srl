#!/usr/bin/env bash
# tests/integration/alerts_fire.sh — the alerts of data-model.md §21 fired and cleared live (T134;
# FR-087, FR-107, FR-108, SC-035, AD-43, AD-48, AD-57, AD-59, AD-60, AD-64, AD-77). Behind
# `make test-alerts`. A fault-making suite under FR-108, following T043's convention as T167 does:
# it starts with leftovers::scan and refuses while a leftover is present on any node; every fault it
# makes that is not intent (the leaf cut from the management network) is written to
# declared-faults.json BEFORE it is made (suite::mgmt_cut), removed by this script and its removal read
# back (suite::mgmt_restore); the declarative changes (the Fabric.spec.maintenance[] entry, overlay.
# reflectorClients: false, the negative Network, the scaled-down gNMIc) are intent a leftover scan
# cannot find, so each is put back from the exit trap whether its wait was met, timed out or the run
# was interrupted — and a wait that times out fails the run AFTER restoring, never before.
#
#   0. the rule unit test FIRST (tests/unit/alerts/rules_test.sh: promtool from the pinned image) —
#      recorded as "rule-unit-test", never as a live firing; its "not run" (exit 77) is a FAILURE
#      here: this suite runs on a lab whose gate wrote tests/gate/observed/telemetry-series.json.
#      It is the only proof of OtlpDataPointsRejected, DuplicateDeviceSeries and EvpnRoutesLost's
#      no-fire half (AD-48, AD-59)
#   1. link: AF_LEAF's AF_LINK admin-disabled through Fabric.spec.maintenance[] (intent) →
#      FabricLinkDown fires (BGPSessionDown recorded); the entry removed and read back → both clear
#   2. failed reconciliation: examples/constructs/negative/vlan-unclaimed-band.yaml applied
#      (Accepted=False/AllocationConflict) → ReconciliationFailed fires; deleted → clears
#   3. EvpnRoutesLost, only on a lab carrying a Network spanning both leaves (US2's examples):
#      Fabric.spec.overlay.reflectorClients: false — the admitted reflection-stopping control (AD-77;
#      T134's text names interASVPN: false, which on this platform is configuration-integrity only and
#      observed NOT to stop reflection) — fires; patched back to true, read back (Fabric Ready=True)
#      → clears. No spanning service → NOT RUN, never passed (the run fails naming it)
#   4. ReverificationStalled: AF_CUT_LEAF cut from the management network (declared fault) → fires
#      after one re-verification + one reconciliation interval while the object it names reports
#      Ready=Unknown/VerificationFailed; DeviceTelemetryTargetDown recorded; reconnection read back → clears
#   5. a stopped stage: deploy/device-metrics-gnmic scaled to 0 → OtlpExportFailing and/or
#      DeviceSubscriptionStalled fire; scaled back and read back → clear
# Per alert: fired_at, cleared_at and mode (live | rule-unit-test | not-run) recorded as evidence
# fields (AF.alerts). Negative controls first: every readiness wait is shown to fail on an alert
# that does not exist.
#
# Usage: alerts_fire.sh run
# Environment: AF_LEAF (leaf01), AF_LINK (ethernet-1/49), AF_CUT_LEAF (leaf02), AF_ALERT_WAIT (s, 300:
#   the bound of a firing/clearing wait beyond the fault's own interval), AF_REVERIFY_INTERVAL (unset:
#   the configured interval; else a test value ≥ 30 s set on the provider and restored on exit),
#   AF_NEGATIVE (examples/constructs/negative/vlan-unclaimed-band.yaml), AF_RULES_TEST
#   (tests/unit/alerts/rules_test.sh), plus suite.sh's and obs.sh's.
set -euo pipefail

AF_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/suite.sh
source "$AF_HERE/lib/suite.sh"
# shellcheck source=lib/obs.sh
source "$AF_HERE/lib/obs.sh"

: "${AF_LEAF:=leaf01}"
: "${AF_LINK:=ethernet-1/49}"
: "${AF_CUT_LEAF:=leaf02}"
: "${AF_ALERT_WAIT:=300}"
: "${AF_NEGATIVE:=$SUITE_ROOT/examples/constructs/negative/vlan-unclaimed-band.yaml}"
: "${AF_RULES_TEST:=$SUITE_ROOT/tests/unit/alerts/rules_test.sh}"
AF_NOSUCH="VtScratchNoSuchAlert"
AF_RESULTS="[]"
AF_REFLECT_SAVED=""
AF_NEG_NAME=""
AF_NEG_NS=""

# af::record <alert> <mode> <fired_at|""> <cleared_at|""> <note>
af::record() {
  AF_RESULTS="$(jq -c --arg a "$1" --arg m "$2" --arg f "$3" --arg c "$4" --arg n "$5" \
    '. + [{alert: $a, mode: $m, fired_at: (if $f == "" then null else ($f | tonumber | todate) end),
           cleared_at: (if $c == "" then null else ($c | tonumber | todate) end), note: $n}]' <<<"$AF_RESULTS")"
}

# af::fire_clear <alert> <fault text> <fire timeout> — wait firing (records fired_at into AF_FIRED)
af::fire() {
  local rc=0
  obs::check "AF.${1}.firing" AF-alert-firing --readiness -- obs::chk_alert "$1" firing "$3" >/dev/null || rc=$?
  AF_FIRED="${OBS_MET_AT:-}"
  suite::judge "$rc" "${1} fired after ${OBS_WAITED:-?}s (${2})" "${1} did not fire within ${3}s (${2})"
  return "$rc"
}
af::clear() {
  local rc=0
  obs::check "AF.${1}.cleared" AF-alert-cleared --readiness -- obs::chk_alert "$1" inactive "$2" >/dev/null || rc=$?
  AF_CLEARED="${OBS_MET_AT:-}"
  suite::judge "$rc" "${1} cleared after ${OBS_WAITED:-?}s" "${1} did not clear within ${2}s"
  return "$rc"
}

af::negatives() {
  obs::neg AF-alert-firing obs::chk_alert "$AF_NOSUCH" firing 1 || true
  # inactive is what a non-existent alert reads: the clearing check's control is an alert that is
  # firing by construction — none exists before a fault, so the control is an unreadable endpoint
  OBS_PROM_PROXY_SAVED="$OBS_PROM_PROXY"
  OBS_PROM_PROXY="/api/v1/namespaces/${OBS_NS}/services/vt-scratch-no-such-prometheus:9090/proxy"
  obs::neg AF-alert-cleared obs::chk_alert "$AF_NOSUCH" inactive 1 || true
  OBS_PROM_PROXY="$OBS_PROM_PROXY_SAVED"
  obs::neg AF-fabric-ready obs::chk_fabric_ready "$FABRIC_NAMESPACE" vt-scratch-no-such-fabric 1 || true
  FABRIC_NAME=vt-scratch-no-such-fabric obs::neg AF-stalled-pre-ready af::chk_all_ready 1 || true
}

# ------------------------------------------------------------------ 0: the rule unit test
af::rule_unit_test() {
  local rc=0
  if [[ ! -f "$AF_RULES_TEST" ]]; then
    suite::fail "rule unit test: ${AF_RULES_TEST#"$SUITE_ROOT"/} is missing (T130)"
    af::record "*" rule-unit-test "" "" "missing"; return 0
  fi
  gate::run AF.rule-unit-test -- bash "$AF_RULES_TEST" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) suite::ok "rule unit test: every one of the ten fires, clears and holds silent where it must (promtool, pinned image)"
       local a; for a in "${OBS_ALERTS[@]}"; do af::record "$a" rule-unit-test "" "" "tests/unit/alerts/rules_test.sh passed"; done ;;
    77) suite::fail "rule unit test: NOT RUN (exit 77) — on a lab whose gate wrote tests/gate/observed/telemetry-series.json a not-run rule test is a failure" ;;
    *) suite::fail "rule unit test: FAILED (exit ${rc}; evidence AF.rule-unit-test)" ;;
  esac
}

# ------------------------------------------------------------------ 1: link down through maintenance[]
af::link() {
  local f1="" f2="" c1="" c2="" wait="$AF_ALERT_WAIT" fired_link=1 fired_bgp=1
  suite::maint_add "$AF_LEAF" "$AF_LINK" || { suite::fail "maintenance[] patch for ${AF_LEAF} ${AF_LINK} refused"; return 0; }
  af::fire FabricLinkDown "${AF_LEAF} ${AF_LINK} admin-disabled through Fabric.spec.maintenance[]" "$wait" && { fired_link=0; f1="$AF_FIRED"; }
  # BGPSessionDown: the underlay session over that link (recorded; FabricLinkDown is the one required)
  local rc=0
  obs::check AF.BGPSessionDown.firing AF-alert-firing --readiness -- obs::chk_alert BGPSessionDown firing 60 >/dev/null || rc=$?
  if [[ "$rc" -eq 0 ]]; then fired_bgp=0; f2="$OBS_MET_AT"; log::info "BGPSessionDown fired as well"
  else log::info "BGPSessionDown did not fire within 60s of FabricLinkDown (recorded)"; fi
  suite::maint_restore || suite::fail "maintenance[] restoration"
  obs::check AF.link.fabric-ready AF-fabric-ready --readiness -- obs::chk_fabric_ready "$FABRIC_NAMESPACE" "$FABRIC_NAME" "$wait" >/dev/null \
    || suite::fail "Fabric ${FABRIC_NAME} not Ready=True after the maintenance entry was removed"
  if [[ "$fired_link" -eq 0 ]]; then af::clear FabricLinkDown "$wait" && c1="$AF_CLEARED"; fi
  if [[ "$fired_bgp" -eq 0 ]]; then af::clear BGPSessionDown "$wait" && c2="$AF_CLEARED"; fi
  af::record FabricLinkDown "$([[ $fired_link -eq 0 ]] && echo live || echo failed)" "$f1" "$c1" "maintenance[] ${AF_LEAF} ${AF_LINK}"
  af::record BGPSessionDown "$([[ $fired_bgp -eq 0 ]] && echo live || echo not-fired)" "$f2" "$c2" "maintenance[] ${AF_LEAF} ${AF_LINK} (recorded)"
}

# ------------------------------------------------------------------ 2: a failed reconciliation
af::delete_negative() {
  [[ -n "$AF_NEG_NAME" ]] || return 0
  gate::run AF.negative-delete -- lab::kubectl -n "$AF_NEG_NS" delete "$SUITE_NET_RES" "$AF_NEG_NAME" --ignore-not-found --wait=true --timeout=120s >/dev/null || return 1
  lab::kubectl -n "$AF_NEG_NS" get "$SUITE_NET_RES" "$AF_NEG_NAME" -o name >/dev/null 2>&1 && { log::error "$AF_NEG_NAME still present"; return 1; }
  AF_NEG_NAME=""
  log::info "the negative Network is gone (read back)"
}

af::reconcile() {
  local f="" c="" name ns
  name="$(yq -r 'select(.kind == "Network") | .metadata.name' "$AF_NEGATIVE" | head -1)"
  ns="$(yq -r 'select(.kind == "Network") | .metadata.namespace' "$AF_NEGATIVE" | head -1)"
  if lab::kubectl -n "$ns" get "$SUITE_NET_RES" "$name" -o name >/dev/null 2>&1; then
    suite::fail "ReconciliationFailed: ${ns}/${name} already exists (not this run's) — not touched"; af::record ReconciliationFailed failed "" "" "fixture already present"; return 0
  fi
  AF_NEG_NAME="$name"; AF_NEG_NS="$ns"
  suite::on_exit af::delete_negative
  gate::run AF.negative-apply -- lab::kubectl apply -f "$AF_NEGATIVE" >/dev/null || { suite::fail "applying ${AF_NEGATIVE#"$SUITE_ROOT"/} failed"; return 0; }
  if af::fire ReconciliationFailed "${ns}/${name} refused (AllocationConflict)" "$AF_ALERT_WAIT"; then f="$AF_FIRED"; fi
  af::delete_negative || suite::fail "deleting ${ns}/${name}"
  if [[ -n "$f" ]]; then af::clear ReconciliationFailed "$AF_ALERT_WAIT" && c="$AF_CLEARED"; fi
  af::record ReconciliationFailed "$([[ -n "$f" ]] && echo live || echo failed)" "$f" "$c" "examples/constructs/negative/${AF_NEGATIVE##*/}"
}

# ------------------------------------------------------------------ 3: EvpnRoutesLost
af::reflect_restore() {
  [[ -n "$AF_REFLECT_SAVED" ]] || return 0
  gate::run AF.reflector-clients-restore -- lab::kubectl -n "$FABRIC_NAMESPACE" patch "$SUITE_FABRIC_RES" "$FABRIC_NAME" --type=merge \
    -p "$(jq -cn --argjson v "$AF_REFLECT_SAVED" '{spec: {overlay: {reflectorClients: $v}}}')" >/dev/null || return 1
  [[ "$(lab::kubectl -n "$FABRIC_NAMESPACE" get "$SUITE_FABRIC_RES" "$FABRIC_NAME" -o json | jq -c '.spec.overlay.reflectorClients')" == "$AF_REFLECT_SAVED" ]] \
    || { log::error "Fabric.spec.overlay.reflectorClients did not read back as restored"; return 1; }
  AF_REFLECT_SAVED=""
  log::info "Fabric.spec.overlay.reflectorClients restored and read back"
}

af::evpn() {
  local spanning f="" c="" nets
  nets="$(lab::kubectl get "$SUITE_NET_RES" -A -o json 2>/dev/null)" || nets='{"items":[]}'
  # shellcheck disable=SC2046  # the leaves are words
  spanning="$(obs::spanning_networks $(lab::leaves) <<<"$nets" | head -1)"
  if [[ -z "$spanning" ]]; then
    suite::fail "EvpnRoutesLost NOT RUN: no Network carrying a bridge domain or router spans every leaf (apply US2's examples) — never counted as passed"
    af::record EvpnRoutesLost not-run "" "" "no spanning service"; return 0
  fi
  log::info "EvpnRoutesLost: spanning service ${spanning}; declarative fault Fabric.spec.overlay.reflectorClients=false (AD-77; interASVPN is configuration-integrity only on this platform)"
  AF_REFLECT_SAVED="$(lab::kubectl -n "$FABRIC_NAMESPACE" get "$SUITE_FABRIC_RES" "$FABRIC_NAME" -o json | jq -c '.spec.overlay.reflectorClients // true')"
  suite::on_exit af::reflect_restore
  gate::run AF.reflector-clients-false -- lab::kubectl -n "$FABRIC_NAMESPACE" patch "$SUITE_FABRIC_RES" "$FABRIC_NAME" --type=merge \
    -p '{"spec":{"overlay":{"reflectorClients":false}}}' >/dev/null || { suite::fail "patching reflectorClients=false refused"; return 0; }
  if af::fire EvpnRoutesLost "reflection stopped (reflectorClients=false) with ${spanning} spanning both leaves" "$AF_ALERT_WAIT"; then f="$AF_FIRED"; fi
  af::reflect_restore || suite::fail "restoring reflectorClients"
  obs::check AF.evpn.fabric-ready AF-fabric-ready --readiness -- obs::chk_fabric_ready "$FABRIC_NAMESPACE" "$FABRIC_NAME" "$AF_ALERT_WAIT" >/dev/null \
    || suite::fail "Fabric ${FABRIC_NAME} not Ready=True after reflectorClients was restored"
  if [[ -n "$f" ]]; then af::clear EvpnRoutesLost "$AF_ALERT_WAIT" && c="$AF_CLEARED"; fi
  af::record EvpnRoutesLost "$([[ -n "$f" ]] && echo live || echo failed)" "$f" "$c" "reflectorClients=false over ${spanning} (AD-77)"
}

# ------------------------------------------------------------------ 4: ReverificationStalled
# af::chk_stalled_objects_unknown — the firing ReverificationStalled instances name at least one
# object that reports Ready=Unknown/VerificationFailed right now
af::chk_stalled_objects_unknown() {
  local alerts objs o kind ns name st found=0
  alerts="$(obs::prom_get /api/v1/alerts)" || { echo "FAIL /api/v1/alerts unreadable"; return 1; }
  objs="$(jq -r '.data.alerts[]? | select(.labels.alertname == "ReverificationStalled" and .state == "firing")
    | "\(.labels.kind // "") \(.labels.namespace // "") \(.labels.name // "")"' <<<"$alerts" | sort -u)"
  while read -r kind ns name; do
    [[ -n "$name" ]] || continue
    case "$kind" in Network) o="$SUITE_NET_RES" ;; Fabric) o="$SUITE_FABRIC_RES" ;; *) continue ;; esac
    st="$(lab::kubectl -n "$ns" get "$o" "$name" -o json 2>/dev/null | jq -r '[(.status.conditions // [])[] | select(.type == "Ready")] | first | "\(.status)/\(.reason)"')"
    echo "${kind} ${ns}/${name} Ready=${st}"
    [[ "$st" == Unknown/VerificationFailed ]] && found=1
  done <<<"$objs"
  jq -cn --arg o "$objs" --argjson f "$found" '{stalled_objects: ($o | split("\n") | map(select(. != ""))), unknown_verification_failed: ($f == 1)}' | sed 's/^/SUMMARY /'
  [[ "$found" -eq 1 ]]
}

# af::chk_all_ready <timeout_s> — the Fabric and every Network of SVC_NS report Ready=True (polled)
af::chk_all_ready() {
  local t0 notready fab nets
  t0="$(date +%s)"
  while :; do
    # an unreadable object is never read as Ready
    fab="$(lab::kubectl -n "$FABRIC_NAMESPACE" get "$SUITE_FABRIC_RES" "$FABRIC_NAME" -o json 2>/dev/null)" || fab='{"kind":"Fabric","metadata":{"name":"'"$FABRIC_NAME"' (unreadable)"}}'
    nets="$(lab::kubectl -n "$SVC_NS" get "$SUITE_NET_RES" -o json 2>/dev/null | jq -c '.items')" || nets='[{"kind":"Network","metadata":{"name":"(list unreadable)"}}]'
    notready="$(jq -rn --argjson f "$fab" --argjson n "$nets" '[$f] + $n | .[] | select(([.status.conditions[]? | select(.type == "Ready") | .status] | first) != "True") | "\(.kind)/\(.metadata.name)"' | paste -sd' ')"
    [[ -z "$notready" ]] && { echo "PASS every object Ready=True after $(( $(date +%s) - t0 ))s"; return 0; }
    (( $(date +%s) - t0 >= $1 )) && { echo "FAIL not Ready=True: ${notready}"; return 1; }
    sleep "$OBS_POLL"
  done
}

af::stalled() {
  local f="" c="" ft="" ct="" bound rc
  if [[ -n "${AF_REVERIFY_INTERVAL:-}" ]]; then suite::set_reverify "$AF_REVERIFY_INTERVAL" || { suite::fail "setting REVERIFY_INTERVAL=${AF_REVERIFY_INTERVAL}"; return 0; }; fi
  suite::intervals
  bound=$((SUITE_REVERIFY_S + SUITE_RECONCILE_S + AF_ALERT_WAIT))
  # Ready=Unknown/VerificationFailed is what a pass that cannot run reports for an object that HAD
  # reported Ready at its generation (AD-40, controllers/network/readiness.go); an object still
  # converging back from the previous step (EvpnRoutesLost's reflectorClients restore, the provider
  # restarted for REVERIFY_INTERVAL) reports Ready=False/NotConverged instead. So the cut is made only
  # once the Fabric and every Network of the services namespace are Ready=True again (bounded)
  rc=0; obs::check AF.stalled.pre-ready AF-stalled-pre-ready --readiness -- af::chk_all_ready "$bound" >/dev/null || rc=$?
  suite::judge "$rc" "before the cut: the Fabric and every Network are Ready=True" "before the cut: not every object returned to Ready=True within ${bound}s"
  [[ "$rc" -eq 0 ]] || { af::record ReverificationStalled failed "" "" "objects not Ready before the cut"; return 0; }
  suite::mgmt_cut "$AF_CUT_LEAF" "vt-scratch-af-mgmt-${AF_CUT_LEAF}" || { suite::fail "could not cut ${AF_CUT_LEAF}"; return 0; }
  # DeviceTelemetryTargetDown during the cut (recorded)
  rc=0; obs::check AF.DeviceTelemetryTargetDown.firing AF-alert-firing --readiness -- obs::chk_alert DeviceTelemetryTargetDown firing "$AF_ALERT_WAIT" >/dev/null || rc=$?
  [[ "$rc" -eq 0 ]] && ft="$OBS_MET_AT"
  if af::fire ReverificationStalled "${AF_CUT_LEAF} cut from the management network; bound ${SUITE_REVERIFY_S}s + ${SUITE_RECONCILE_S}s" "$bound"; then
    f="$AF_FIRED"
    rc=0; obs::check AF.stalled.object-unknown AF-stalled-unknown -- af::chk_stalled_objects_unknown >/dev/null || rc=$?
    suite::judge "$rc" "ReverificationStalled fired while the object it names reports Ready=Unknown/VerificationFailed" \
      "no object named by the firing ReverificationStalled reports Ready=Unknown/VerificationFailed"
  fi
  suite::mgmt_restore "$AF_CUT_LEAF" || suite::fail "reconnection of ${AF_CUT_LEAF}"
  if [[ -n "$f" ]]; then af::clear ReverificationStalled "$bound" && c="$AF_CLEARED"; fi
  if [[ -n "$ft" ]]; then
    rc=0; obs::check AF.DeviceTelemetryTargetDown.cleared AF-alert-cleared --readiness -- obs::chk_alert DeviceTelemetryTargetDown inactive "$AF_ALERT_WAIT" >/dev/null || rc=$?
    [[ "$rc" -eq 0 ]] && ct="$OBS_MET_AT"
  fi
  af::record ReverificationStalled "$([[ -n "$f" ]] && echo live || echo failed)" "$f" "$c" "management cut of ${AF_CUT_LEAF} (declared fault)"
  af::record DeviceTelemetryTargetDown "$([[ -n "$ft" ]] && echo live || echo not-fired)" "$ft" "$ct" "during the management cut of ${AF_CUT_LEAF} (recorded)"
}

# ------------------------------------------------------------------ 5: a stopped stage
af::stage() {
  local a f c any=1
  obs::scale "$OBS_NS" device-metrics-gnmic 0 || { suite::fail "scaling device-metrics-gnmic to 0"; return 0; }
  declare -A fired=()
  for a in OtlpExportFailing DeviceSubscriptionStalled; do
    if obs::check "AF.${a}.firing" AF-alert-firing --readiness -- obs::chk_alert "$a" firing "$AF_ALERT_WAIT" >/dev/null; then
      fired[$a]="$OBS_MET_AT"; any=0; log::info "${a} fired with gNMIc stopped"
    else log::info "${a} did not fire within ${AF_ALERT_WAIT}s with gNMIc stopped (recorded)"; fi
  done
  suite::judge "$any" "a stopped stage (gNMIc scaled to 0) is alertable" "neither OtlpExportFailing nor DeviceSubscriptionStalled fired with gNMIc stopped"
  obs::scale_restore "$OBS_NS" device-metrics-gnmic || suite::fail "restoring device-metrics-gnmic"
  for a in OtlpExportFailing DeviceSubscriptionStalled; do
    f="${fired[$a]:-}"; c=""
    if [[ -n "$f" ]]; then af::clear "$a" "$AF_ALERT_WAIT" && c="$AF_CLEARED"; fi
    af::record "$a" "$([[ -n "$f" ]] && echo live || echo not-fired)" "$f" "$c" "device-metrics-gnmic scaled to 0"
  done
}

af::run() {
  suite::init alerts-fire || return $?
  suite::refuse_on_leftovers alerts-fire || return $?
  af::rule_unit_test
  local missing
  missing="$(for a in "${OBS_ALERTS[@]}"; do [[ -n "$(obs::rule_query "$a" 2>/dev/null)" ]] || printf '%s ' "$a"; done)"
  if [[ -n "$missing" ]]; then
    suite::fail "Prometheus does not have the alert rule(s) ${missing}loaded (make wait-observability)"
    suite::finish alerts-fire; return 1
  fi
  af::negatives
  af::link
  af::reconcile
  af::evpn
  af::stalled
  af::stage
  suite::fields AF.alerts "$(jq -cn --argjson r "$AF_RESULTS" '{criterion: "SC-035", alerts: $r}')"
  log::info "per-alert record: $(jq -c '[.[] | "\(.alert)=\(.mode)"]' <<<"$AF_RESULTS")"
  suite::finish alerts-fire
}

main() {
  case "${1:-}" in
    run) af::run ;;
    *) echo "Usage: $0 run" >&2; return 2 ;;
  esac
}

main "$@"
