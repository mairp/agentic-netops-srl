#!/usr/bin/env bash
# tests/integration/observability_verify.sh — the pipeline's health, single path, staleness and
# outage behaviour, live (T134; FR-086, FR-089, FR-091, NFR-005, SC-034, SC-036, SC-037; AD-55,
# AD-62; quickstart.md §21). Behind `make verify-metrics`.
#
#   targets     every scrape job of the stack has at least one active target and every one is up —
#               devices, otel-collector, gnmic-self (not optional: without it stages 1 and 2 have no
#               evidence), srl-provider, sdc, prometheus — and the devices job carries series of
#               every qualified device source (every spine and leaf)
#   duplicates  zero duplicate subscription series: the loaded DuplicateDeviceSeries expression
#               (read from /api/v1/rules, never retyped) returns nothing
#   stale       a series whose source stopped reporting goes stale and reads ABSENT, never at its
#               last value — on the link alerts_fire.sh takes down (OV_LEAF OV_LINK): gNMIc is
#               scaled to 0 and that link's interface series must read empty within the collector's
#               metric_expiration + scrape (OV_STALE_WAIT); gNMIc scaled back, the series returns.
#               (A maintenance disable keeps the device REPORTING oper-state 0, so it is not the
#               stale case; the stopped source is.)
#   outage      the collector scaled to 0 (a telemetry outage): a scratch mac-vrf (vt-scratch-obs-…)
#               applied during it is still rendered and Applied — configuration unblocked — while
#               its status is Degraded=True (the reason, VerificationFailed or TelemetryUnavailable,
#               recorded); after recovery the gap is visible: the collector-health dashboard's
#               queue / refused / send-failed queries and gNMIc's output error counters, evaluated
#               over the outage window, show a non-zero value (its size recorded); the scratch
#               service is Ready again and deleted, its removal read back
#   sink        one sink down while the other stays healthy: Prometheus scaled to 0 while the
#               collector keeps serving its endpoint and the provider's read-back keeps the Fabric
#               Ready=True at every poll (OV_SINK_HOLD); Prometheus restored and ready
# Every fault restored from the exit trap (scales, the scratch service). Negative controls first.
#
# Usage: observability_verify.sh run | targets | duplicates | stale | outage | sink
# Environment: OV_LEAF (leaf01), OV_LINK (ethernet-1/49), OV_STALE_WAIT (s, 120), OV_OUTAGE_WAIT
#   (s, 300), OV_SINK_HOLD (s, 60), OV_JOBS ("devices otel-collector gnmic-self srl-provider sdc
#   prometheus"), OV_GAP_QUERIES (override: newline-separated PromQL, else the collector-health
#   dashboard's), plus suite.sh's and obs.sh's.
set -euo pipefail

OV_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/suite.sh
source "$OV_HERE/lib/suite.sh"
# shellcheck source=lib/obs.sh
source "$OV_HERE/lib/obs.sh"

: "${OV_LEAF:=leaf01}"
: "${OV_LINK:=ethernet-1/49}"
: "${OV_STALE_WAIT:=120}"
: "${OV_OUTAGE_WAIT:=300}"
: "${OV_SINK_HOLD:=60}"
: "${OV_JOBS:=devices otel-collector gnmic-self srl-provider sdc prometheus}"
OV_SCRATCH="vt-scratch-obs-$(date +%s | tail -c 6)"
OV_SCRATCH_APPLIED=""
OV_IFACE_SERIES="srl_nokia_interfaces:interface_oper_state"
OV_NEG_DONE=0

ov::negatives() {
  [[ "$OV_NEG_DONE" == 0 ]] || return 0
  obs::neg OV-targets obs::chk_targets_up vt-scratch-no-such-job || true
  obs::neg OV-sources obs::chk_sources "{job=\"devices\",__name__=~\"srl_nokia_.+\"}" vt-scratch-no-such-node || true
  obs::neg OV-no-duplicates obs::chk_empty 'vector(1)' || true
  obs::neg OV-absent obs::chk_absent_within 'vector(1)' 1 || true
  obs::neg OV-present obs::chk_present_within 'vt_scratch_no_such_series' 1 || true
  obs::neg OV-fabric-hold obs::chk_fabric_ready_hold "$FABRIC_NAMESPACE" vt-scratch-no-such-fabric 1 || true
  obs::neg OV-fabric-ready obs::chk_fabric_ready "$FABRIC_NAMESPACE" vt-scratch-no-such-fabric 1 || true
  obs::neg OV-gap obs::chk_present_within 'vt_scratch_no_such_series > 0' 1 || true
  obs::neg OV-collector-serving ov::chk_collector_serving vt-scratch-no-such-service || true
  suite::neg OV-applied cond "$SVC_NS" vt-scratch-never-applied 5 Applied=True || true
  suite::neg OV-degraded cond "$SVC_NS" vt-scratch-never-applied 5 Degraded=True || true
  suite::neg OV-scratch-ready cond "$SVC_NS" vt-scratch-never-applied 5 Ready=True || true
  OV_NEG_DONE=1
}

ov::begin() {
  suite::init observability-verify || return $?
  ov::negatives
}

# ------------------------------------------------------------------ targets and sources
ov::targets() {
  local rc=0
  # shellcheck disable=SC2086  # the jobs are words
  obs::check OV.targets OV-targets --readiness -- obs::chk_targets_up $OV_JOBS >/dev/null || rc=$?
  suite::judge "$rc" "every job up: ${OV_JOBS}" "a job has no target or a target down: $(grep -h '^FAIL' "$EVIDENCE_DIR/$OBS_LAST_ID.stdout" 2>/dev/null | paste -sd';')"
  rc=0
  # shellcheck disable=SC2046  # the devices are words
  obs::check OV.sources OV-sources --readiness -- obs::chk_sources "{job=\"devices\",__name__=~\"srl_nokia_.+\"}" $(lab::devices) >/dev/null || rc=$?
  suite::judge "$rc" "the devices job carries series of every device source ($(lab::devices | paste -sd' '))" "a device source is missing from the devices job"
}

# ------------------------------------------------------------------ duplicates
ov::duplicates() {
  local expr rc=0
  expr="$(obs::rule_query DuplicateDeviceSeries)" || expr=""
  [[ -n "$expr" ]] || { suite::fail "the DuplicateDeviceSeries rule is not loaded (make wait-observability)"; return 0; }
  obs::check OV.duplicates OV-no-duplicates --readiness -- obs::chk_empty "$expr" >/dev/null || rc=$?
  suite::judge "$rc" "zero duplicate subscription series (DuplicateDeviceSeries expression empty)" "duplicate device series present: $(suite::summary "$OBS_LAST_ID")"
}

# ------------------------------------------------------------------ stale → absent
ov::stale() {
  local sel rc last
  sel="${OV_IFACE_SERIES}{source=\"${OV_LEAF}\",interface_name=\"$(obs::normalize_iface "$OV_LINK")\"}"
  rc=0; obs::check OV.stale.before OV-present --readiness -- obs::chk_present_within "$sel" 60 >/dev/null || rc=$?
  [[ "$rc" -eq 0 ]] || { suite::fail "stale: ${sel} is not present before the source stops"; return 0; }
  last="$(obs::prom_vector "$sel" | jq -c '[.[].value[1]]')"
  obs::scale "$OBS_NS" device-metrics-gnmic 0 || { suite::fail "stale: scaling gNMIc to 0"; return 0; }
  rc=0; obs::check OV.stale.absent OV-absent --readiness -- obs::chk_absent_within "$sel" "$OV_STALE_WAIT" >/dev/null || rc=$?
  suite::judge "$rc" "stale: ${sel} reads ABSENT after its source stopped (last value ${last} not carried)" \
    "stale: ${sel} still reads a value ${OV_STALE_WAIT}s after its source stopped"
  obs::scale_restore "$OBS_NS" device-metrics-gnmic || suite::fail "stale: restoring gNMIc"
  rc=0; obs::check OV.stale.back OV-present --readiness -- obs::chk_present_within "$sel" "$OV_STALE_WAIT" >/dev/null || rc=$?
  suite::judge "$rc" "stale: ${sel} returns once gNMIc reports again" "stale: ${sel} did not return after gNMIc was restored"
}

# ------------------------------------------------------------------ telemetry outage
ov::delete_scratch() {
  [[ -n "$OV_SCRATCH_APPLIED" ]] || return 0
  gate::run OV.scratch-delete -- lab::kubectl -n "$SVC_NS" delete "$SUITE_NET_RES" "$OV_SCRATCH" --ignore-not-found --wait=true --timeout=180s >/dev/null || return 1
  lab::kubectl -n "$SVC_NS" get "$SUITE_NET_RES" "$OV_SCRATCH" -o name >/dev/null 2>&1 && { log::error "$OV_SCRATCH still present"; return 1; }
  OV_SCRATCH_APPLIED=""
  log::info "$OV_SCRATCH deleted (read back)"
}

# ov::gap_queries — the collector-health dashboard's gap queries (queue, refused, send-failed, errors)
ov::gap_queries() {
  if [[ -n "${OV_GAP_QUERIES:-}" ]]; then printf '%s\n' "$OV_GAP_QUERIES"; return 0; fi
  local d
  d="$(obs::dashboard 'collector.?health')" || return 1
  obs::dashboard_queries "" <<<"$d" | cut -f2 | grep -iE 'refused|send_failed|queue|error|fail|drop' || true
}

ov::outage() {
  local t0 t1 rc reason q max sizes="[]" any=1 step
  ov::gap_queries >/dev/null || { suite::fail "outage: the collector-health dashboard cannot be read through the Grafana API"; }
  obs::scale "$OBS_NS" device-metrics-otel 0 || { suite::fail "outage: scaling the collector to 0"; return 0; }
  t0="$(date +%s)"
  suite::on_exit ov::delete_scratch
  OV_SCRATCH_APPLIED=1
  suite::apply_macvrf "$OV_SCRATCH" 193 10193 || { suite::fail "outage: applying ${OV_SCRATCH}"; }
  rc=0; suite::check OV.outage.applied OV-applied --readiness -- cond "$SVC_NS" "$OV_SCRATCH" "$OV_OUTAGE_WAIT" Applied=True >/dev/null || rc=$?
  suite::judge "$rc" "outage: ${OV_SCRATCH} rendered and Applied with the collector down (configuration unblocked)" "outage: ${OV_SCRATCH} not Applied during the outage"
  rc=0; suite::check OV.outage.degraded OV-degraded --readiness -- cond "$SVC_NS" "$OV_SCRATCH" "$OV_OUTAGE_WAIT" Degraded=True >/dev/null || rc=$?
  reason="$(lab::kubectl -n "$SVC_NS" get "$SUITE_NET_RES" "$OV_SCRATCH" -o json | jq -r '[.status.conditions[]? | select(.type == "Degraded")] | first | .reason // "?"')"
  suite::judge "$rc" "outage: status Degraded=True/${reason}" "outage: ${OV_SCRATCH} not Degraded=True during the outage (Degraded reason ${reason})"
  case "$reason" in VerificationFailed|TelemetryUnavailable) ;; *) [[ "$rc" -eq 0 ]] && suite::fail "outage: Degraded reason ${reason}, expected VerificationFailed or TelemetryUnavailable" ;; esac
  obs::scale_restore "$OBS_NS" device-metrics-otel || suite::fail "outage: restoring the collector"
  t1="$(date +%s)"
  rc=0; suite::check OV.outage.recovered OV-scratch-ready --readiness -- cond "$SVC_NS" "$OV_SCRATCH" "$OV_OUTAGE_WAIT" Ready=True >/dev/null || rc=$?
  suite::judge "$rc" "outage: ${OV_SCRATCH} Ready=True after recovery" "outage: ${OV_SCRATCH} not Ready=True after recovery"
  # the gap: evaluated over the outage window (plus one minute each side), once Prometheus has scraped the recovered stages
  sleep 60
  step=15
  while IFS= read -r q; do
    [[ -n "$q" ]] || continue
    max="$(obs::prom_range "$q" "$((t0 - 60))" "$(date +%s)" "$step" 2>/dev/null \
      | jq '[.[].values[]?[1] | tonumber? // 0] | max // 0')" || max="unreadable"
    sizes="$(jq -c --arg q "$q" --arg m "$max" '. + [{query: $q, max_over_window: $m}]' <<<"$sizes")"
    [[ "$max" != unreadable ]] && awk -v m="$max" 'BEGIN { exit !(m > 0) }' && any=0
  done < <(ov::gap_queries 2>/dev/null || true)
  suite::fields OV.outage.gap "$(jq -cn --argjson s "$sizes" --argjson t0 "$t0" --argjson t1 "$t1" --arg r "$reason" \
    '{criterion: "SC-037", outage_start: ($t0 | todate), outage_end: ($t1 | todate), degraded_reason: $r, gap_queries: $s}')"
  suite::judge "$any" "outage: the gap is visible after recovery (collector-health queries non-zero over the window: evidence OV.outage.gap)" \
    "outage: no collector-health queue/refused/send-failed/error query shows the gap over the outage window"
  ov::delete_scratch || suite::fail "outage: deleting ${OV_SCRATCH}"
}

# ------------------------------------------------------------------ one sink down
# ov::chk_collector_serving <service> — the collector's Prometheus endpoint (<service>:8889) serves device samples
ov::chk_collector_serving() {
  local out
  out="$(lab::kubectl get --raw "/api/v1/namespaces/${OBS_NS}/services/$1:8889/proxy/metrics" 2>/dev/null)" || { echo "FAIL collector endpoint $1:8889 unreadable"; echo 'SUMMARY {"device_samples":0}'; return 1; }
  local n; n="$(grep -c '^srl_nokia_' <<<"$out" || true)"
  echo "SUMMARY {\"device_samples\":${n:-0}}"
  [[ "${n:-0}" -gt 0 ]]
}

ov::sink() {
  local rc
  obs::scale "$OBS_NS" prometheus 0 || { suite::fail "sink: scaling Prometheus to 0"; return 0; }
  rc=0; obs::check OV.sink.fabric-hold OV-fabric-hold --readiness -- obs::chk_fabric_ready_hold "$FABRIC_NAMESPACE" "$FABRIC_NAME" "$OV_SINK_HOLD" >/dev/null || rc=$?
  suite::judge "$rc" "sink: Fabric Ready=True at every poll for ${OV_SINK_HOLD}s with Prometheus down (read-back healthy)" "sink: the Fabric left Ready=True while only Prometheus was down"
  rc=0; obs::check OV.sink.collector OV-collector-serving --readiness -- ov::chk_collector_serving device-metrics >/dev/null || rc=$?
  suite::judge "$rc" "sink: the collector keeps serving device series with Prometheus down" "sink: the collector stopped serving while only Prometheus was down"
  obs::scale_restore "$OBS_NS" prometheus || suite::fail "sink: restoring Prometheus"
  rc=0; obs::check OV.sink.prom-back OV-present --readiness -- obs::chk_present_within 'up{job="devices"} == 1' "$OV_OUTAGE_WAIT" >/dev/null || rc=$?
  suite::judge "$rc" "sink: Prometheus back and scraping the devices job" "sink: Prometheus not scraping again after restore"
}

main() {
  local sub="${1:-}"
  case "$sub" in
    run) ov::begin || return $?; ov::targets; ov::duplicates; ov::stale; ov::outage; ov::sink ;;
    targets) ov::begin || return $?; ov::targets ;;
    duplicates) ov::begin || return $?; ov::duplicates ;;
    stale) ov::begin || return $?; ov::stale ;;
    outage) ov::begin || return $?; ov::outage ;;
    sink) ov::begin || return $?; ov::sink ;;
    *) echo "Usage: $0 run | targets | duplicates | stale | outage | sink" >&2; return 2 ;;
  esac
  suite::finish observability-verify
}

main "$@"
