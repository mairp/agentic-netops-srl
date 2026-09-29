#!/usr/bin/env bash
# observability_phase.sh — the ObservabilityReady phase: install the observability stack and load
# its alert rules only after the live pipeline was re-checked against the gate's observation
# (T134; FR-087, FR-089, FR-094, FR-096; AD-50, AD-55, AD-64; quickstart.md §1, §21).
#
#   observability_phase::run      the phase (scripts/provision.sh provision::phase_ObservabilityReady):
#     1. T131's generator step into a run directory (observability::generate <dir>, scripts/lib/
#        observability.sh): the gNMIc target list, the topology SVG / panel YAML, the topology
#        recording rules — all from the same containerlab inventory, in the same step
#     2. the device collector re-rendered from that same target list (device_metrics::ensure with
#        DEVICE_METRICS_TARGETS_FILE=<dir>/gnmic-targets.txt, scripts/lib/device_metrics.sh, T128)
#     3. deploy/observability/prometheus applied WITHOUT the alert rules (its rules/ are a separate
#        kustomization, applied in 6), then T131's assets (observability::install_assets <dir>),
#        then T132's Grafana assets (grafana_assets::ensure, scripts/lib/grafana_assets.sh) and
#        deploy/observability/grafana; Prometheus, Grafana, the collector and gNMIc waited Ready
#        (bounded) and Prometheus's /-/ready read through the API server's service proxy
#     4. [INTEGRATOR HOOK] the provider's otlp-endpoint setting (OBS_PROVIDER_OTLP_ENDPOINT)
#     5. the RE-CHECK (observability_phase::recheck), run-captured through evidence_run
#        (observability.recheck): a failure stops the phase non-zero naming every absent series and
#        every differing setting; the alert rules are then NEVER applied (AD-55)
#     6. only then deploy/observability/prometheus/rules applied, POST /-/reload, and a bounded wait
#        until Prometheus lists the ten alert rules of data-model.md §21 (observability.rules-loaded)
#   observability_phase::recheck  the re-check alone:
#     * every series name of the gate's observation (OBS_SERIES_FILE, default the committed
#       tests/gate/observed/telemetry-series.json: all_series[] and series.*[].name) queried from the
#       INSTALLED Prometheus as count({__name__="<name>"}) through
#       /api/v1/namespaces/monitoring/services/prometheus:9090/proxy/api/v1/query — polled, bounded
#       (OBS_RECHECK_TIMEOUT), until every required name answers; an absent name is named;
#       a query Prometheus cannot answer is a failure too, never read as present
#     * the bgp-evpn bgp-instance series (series.bgp_evpn_instance_evi / _oper_state) are required
#       only once a service exists — a Network carrying a bridge domain or a router in any namespace;
#       before that their absence is reported "not yet observable" and the re-check goes on
#     * the shipped naming-relevant settings compared with the file's `settings`: every recorded key
#       of settings.gnmic_otlp_output (except event-processors: processor NAMES are not naming-
#       relevant) against every `type: otlp` output of ConfigMap monitoring/device-metrics-gnmic
#       (gnmic.yaml), and every recorded key of settings.collector_prometheus_exporter against every
#       prometheus exporter of ConfigMap monitoring/device-metrics-otel (config.yaml); a key missing
#       live, or a value that differs, is named with both values
#   observability_phase::wait     `make wait-observability`: Prometheus, Grafana, the collector and
#                                 gNMIc rolled out, /-/ready, and the ten rules listed — bounded, no mutation
#
# Prints one `SUMMARY <json>` line per re-check. Nothing of this stack is part of AppsReady (AD-50).
#
# env: OBS_SERIES_FILE, OBS_RUN_DIR (default a fresh /tmp directory — never inside EVIDENCE_DIR,
#   whose unreferenced files verify-evidence refuses), OBS_WAIT_TIMEOUT (s, 300), OBS_RECHECK_TIMEOUT
#   (s, 180), OBS_RECHECK_INTERVAL (s, 10), OBS_RULES_TIMEOUT (s, 180), OBS_RULES_INTERVAL (s, 5),
#   OBS_PROVIDER_OTLP_ENDPOINT, KUBECTL, KUBE_CONTEXT, EVIDENCE_DIR
# shellcheck source-path=SCRIPTDIR

[[ -n "${__AGENTIC_NETOPS_OBSERVABILITY_PHASE_SH:-}" ]] && return 0
__AGENTIC_NETOPS_OBSERVABILITY_PHASE_SH=1

OBS_PHASE_LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OBS_PHASE_ROOT="$(cd -- "$OBS_PHASE_LIB/../.." && pwd)"
# shellcheck source=log.sh
source "$OBS_PHASE_LIB/log.sh"
# shellcheck source=k8s_wait.sh
source "$OBS_PHASE_LIB/k8s_wait.sh"
# shellcheck source=evidence.sh
source "$OBS_PHASE_LIB/evidence.sh"

OBS_NS="monitoring"
OBS_PROM_PROXY="/api/v1/namespaces/${OBS_NS}/services/prometheus:9090/proxy"
OBS_FIELD_MANAGER="agentic-netops-provision"
# The required alert set, by the names of data-model.md §21 (FR-087).
OBS_ALERT_NAMES=(FabricLinkDown BGPSessionDown EvpnRoutesLost ReconciliationFailed ReverificationStalled
  DeviceTelemetryTargetDown DeviceSubscriptionStalled OtlpExportFailing OtlpDataPointsRejected DuplicateDeviceSeries)
# The stack's workloads, all in monitoring: T130's two and AD-82's pipeline (T129).
OBS_DEPLOYMENTS=(prometheus grafana device-metrics-otel device-metrics-gnmic)

observability_phase::k() { k8s_wait::_kubectl "$@"; }
observability_phase::series_file() { printf '%s' "${OBS_SERIES_FILE:-$OBS_PHASE_ROOT/tests/gate/observed/telemetry-series.json}"; }

# observability_phase::_eid <stem> — a fresh evidence id (evidence is never overwritten)
observability_phase::_eid() {
  local id="$1" n=1
  while [[ -e "$EVIDENCE_DIR/$id.json" ]]; do n=$((n + 1)); id="${1}-${n}"; done
  printf '%s' "$id"
}

# observability_phase::_apply_k <dir> — server-side apply of one kustomization of the tree
observability_phase::_apply_k() {
  local dir="$OBS_PHASE_ROOT/$1"
  [[ -f "$dir/kustomization.yaml" ]] || { log::error "no kustomization.yaml in $1 (the stack is not built in this tree)"; return 1; }
  log::info "apply --server-side -k $1"
  observability_phase::k apply --server-side --field-manager="$OBS_FIELD_MANAGER" -k "$dir" >/dev/null
}

# observability_phase::prom_get <path under the Prometheus proxy, starting with /> — a GET through
# the API server's service proxy (no port-forward, no ingress)
observability_phase::prom_get() { observability_phase::k get --raw "${OBS_PROM_PROXY}$1"; }

# observability_phase::series_names <file> — every observed series name, unique
observability_phase::series_names() {
  jq -r '[(.all_series // [])[], ((.series // {})[][]?.name)] | map(select(. != null and . != "")) | unique[]' "$1"
}

# observability_phase::instance_names <file> — the bgp-evpn bgp-instance series (the guard's series)
observability_phase::instance_names() {
  jq -r '[(.series.bgp_evpn_instance_evi // [])[].name, (.series.bgp_evpn_instance_oper_state // [])[].name]
         | map(select(. != null)) | unique[]' "$1"
}

# observability_phase::service_present — 0 when a service exists (a Network with a bridge domain or a
# router in any namespace, i.e. something that can carry an EVPN instance), 1 when none, 2 unreadable
observability_phase::service_present() {
  local json
  json="$(observability_phase::k get networks.fabric.agentic-netops.io -A -o json 2>/dev/null)" || return 2
  jq -e . >/dev/null 2>&1 <<<"$json" || return 2
  jq -e '[.items[]? | select(((.spec.bridgeDomains // []) | length) > 0 or ((.spec.routers // []) | length) > 0)] | length > 0' \
    >/dev/null <<<"$json" && return 0
  return 1
}

# observability_phase::series_present <name> — 0 present (count > 0), 1 absent, 2 query failed
observability_phase::series_present() {
  local q out
  q="$(jq -rn --arg n "$1" '"count({__name__=\"" + $n + "\"})" | @uri')"
  out="$(observability_phase::prom_get "/api/v1/query?query=${q}" 2>/dev/null)" || return 2
  jq -e '.status == "success"' >/dev/null 2>&1 <<<"$out" || return 2
  jq -e '[.data.result[]? | .value[1] | tonumber] | any(. > 0)' >/dev/null 2>&1 <<<"$out" && return 0
  return 1
}

# observability_phase::_cm_yaml <configmap> <key> — the key's YAML as JSON (rc 1 when unreadable)
observability_phase::_cm_yaml() {
  local cm
  cm="$(observability_phase::k get configmap "$1" -n "$OBS_NS" -o json 2>/dev/null)" || return 1
  jq -er --arg k "$2" '.data[$k] // empty' <<<"$cm" | yq -o=json '.' 2>/dev/null
}

# observability_phase::settings_diff <file> — one line per differing naming-relevant setting
# ("setting <where> <key>: live <v>, recorded <v>"); rc 0 none differ, 1 some differ
observability_phase::settings_diff() {
  local file="$1" rec live bad=0 lines
  # gNMIc's otlp output(s) — every recorded key except the processor names
  rec="$(jq -c '(.settings.gnmic_otlp_output // {}) | del(.["event-processors"])' "$file")"
  if [[ "$rec" != "{}" ]]; then
    if ! live="$(observability_phase::_cm_yaml device-metrics-gnmic gnmic.yaml)" || [[ -z "$live" ]]; then
      echo "setting gNMIc otlp output: ConfigMap ${OBS_NS}/device-metrics-gnmic (gnmic.yaml) could not be read"; bad=1
    else
      if ! lines="$(jq -r --argjson rec "$rec" '
        [(.outputs // {}) | to_entries[] | select(.value.type == "otlp")] as $outs
        | if ($outs | length) == 0 then "setting gNMIc otlp output: no output of type otlp in ConfigMap device-metrics-gnmic (recorded type otlp)"
          else $outs[] as $o | $rec | to_entries[] | .key as $k | .value as $v
            | select((($o.value | has($k)) | not) or ($o.value[$k] != $v))
            | "setting gNMIc otlp output \($o.key) \($k): live \(if ($o.value | has($k)) then ($o.value[$k] | tojson) else "absent" end), recorded \($v | tojson) (settings.gnmic_otlp_output)"
          end' <<<"$live")"; then
        lines="setting gNMIc otlp output: ConfigMap ${OBS_NS}/device-metrics-gnmic (gnmic.yaml) could not be compared"
      fi
      [[ -n "$lines" ]] && { printf '%s\n' "$lines"; bad=1; }
    fi
  fi
  # the collector's Prometheus exporter(s)
  rec="$(jq -c '.settings.collector_prometheus_exporter // {}' "$file")"
  if [[ "$rec" != "{}" ]]; then
    if ! live="$(observability_phase::_cm_yaml device-metrics-otel config.yaml)" || [[ -z "$live" ]]; then
      echo "setting collector prometheus exporter: ConfigMap ${OBS_NS}/device-metrics-otel (config.yaml) could not be read"; bad=1
    else
      if ! lines="$(jq -r --argjson rec "$rec" '
        [(.exporters // {}) | to_entries[] | select(.key == "prometheus" or (.key | startswith("prometheus/")))] as $exps
        | if ($exps | length) == 0 then "setting collector prometheus exporter: no prometheus exporter in ConfigMap device-metrics-otel"
          else $exps[] as $e | ($e.value // {}) as $ev | $rec | to_entries[] | .key as $k | .value as $v
            | select((($ev | has($k)) | not) or ($ev[$k] != $v))
            | "setting collector exporter \($e.key) \($k): live \(if ($ev | has($k)) then ($ev[$k] | tojson) else "absent" end), recorded \($v | tojson) (settings.collector_prometheus_exporter)"
          end' <<<"$live")"; then
        lines="setting collector prometheus exporter: ConfigMap ${OBS_NS}/device-metrics-otel (config.yaml) could not be compared"
      fi
      [[ -n "$lines" ]] && { printf '%s\n' "$lines"; bad=1; }
    fi
  fi
  return "$bad"
}

# observability_phase::recheck — the gate's observation against the live pipeline (AD-55); stdout is
# the verdict (captured by evidence_run in the phase), rc 0 pass / 1 mismatch or unreadable
observability_phase::recheck() {
  local file names=() instances=() svc=1 name st deadline absent=() failed=() excused=() diffs rc=0
  file="$(observability_phase::series_file)"
  if [[ ! -f "$file" ]]; then
    echo "FAIL series file ${file#"$OBS_PHASE_ROOT"/}: not found — the capability gate (G7) writes tests/gate/observed/telemetry-series.json; no guard is loaded on unobserved names"
    return 1
  fi
  mapfile -t names < <(observability_phase::series_names "$file")
  mapfile -t instances < <(observability_phase::instance_names "$file")
  [[ ${#names[@]} -gt 0 ]] || { echo "FAIL series file ${file#"$OBS_PHASE_ROOT"/}: records no series name"; return 1; }
  svc=0; observability_phase::service_present || svc=$?
  if [[ "$svc" -eq 2 ]]; then
    echo "FAIL services: networks.fabric.agentic-netops.io could not be listed; whether the bgp-evpn bgp-instance series must exist is unknown"
    return 1
  fi
  echo "series file ${file#"$OBS_PHASE_ROOT"/}: ${#names[@]} name(s); a service carrying an EVPN instance $([[ "$svc" -eq 0 ]] && echo exists || echo "does not exist yet")"

  deadline=$((SECONDS + ${OBS_RECHECK_TIMEOUT:-180}))
  while :; do
    absent=(); failed=(); excused=()
    for name in "${names[@]}"; do
      st=0; observability_phase::series_present "$name" || st=$?
      case "$st" in
        0) ;;
        2) failed+=("$name") ;;
        *) if [[ "$svc" -eq 1 ]] && printf '%s\n' "${instances[@]}" | grep -qxF -- "$name"; then excused+=("$name"); else absent+=("$name"); fi ;;
      esac
    done
    [[ ${#absent[@]} -eq 0 && ${#failed[@]} -eq 0 ]] && break
    (( SECONDS >= deadline )) && break
    sleep "${OBS_RECHECK_INTERVAL:-10}"
  done
  for name in "${names[@]}"; do
    if printf '%s\n' "${absent[@]}" "${failed[@]}" "${excused[@]}" | grep -qxF -- "$name"; then continue; fi
    echo "PASS series ${name}: present in Prometheus"
  done
  for name in "${excused[@]}"; do
    echo "NOT YET OBSERVABLE series ${name}: absent while no service exists (no Network carries a bridge domain or a router) — not a mismatch"
  done
  for name in "${absent[@]}"; do
    echo "FAIL series ${name}: absent from Prometheus (count({__name__=\"${name}\"}) empty after ${OBS_RECHECK_TIMEOUT:-180}s)"; rc=1
  done
  for name in "${failed[@]}"; do
    echo "FAIL series ${name}: could not query Prometheus for it (${OBS_PROM_PROXY}/api/v1/query)"; rc=1
  done
  if diffs="$(observability_phase::settings_diff "$file")"; then
    echo "PASS settings: gNMIc's otlp output and the collector's Prometheus exporter equal the recorded ones"
  else
    printf '%s\n' "$diffs" | sed 's/^/FAIL /'; rc=1
  fi
  jq -cn --arg f "${file#"$OBS_PHASE_ROOT"/}" --argjson svc "$([[ "$svc" -eq 0 ]] && echo true || echo false)" \
    --arg r "$([[ "$rc" -eq 0 ]] && echo pass || echo fail)" --arg a "${absent[*]}" --arg q "${failed[*]}" \
    --arg e "${excused[*]}" --arg d "${diffs:-}" '
    def words: split(" ") | map(select(. != ""));
    {series_file: $f, service_present: $svc, result: $r, absent: ($a | words), unqueryable: ($q | words),
     not_yet_observable: ($e | words), settings_differ: ($d | split("\n") | map(select(. != "")))}' | sed 's/^/SUMMARY /'
  return "$rc"
}

# observability_phase::rules_missing — the alert names of the ten Prometheus does not list (stdout);
# rc 2 when /api/v1/rules cannot be read
observability_phase::rules_missing() {
  local out
  out="$(observability_phase::prom_get /api/v1/rules 2>/dev/null)" || return 2
  jq -e '.status == "success"' >/dev/null 2>&1 <<<"$out" || return 2
  jq -r --args '[.data.groups[]?.rules[]? | select(.type == "alerting") | .name] as $have
    | $ARGS.positional[] | select(. as $n | $have | index($n) | not)' "${OBS_ALERT_NAMES[@]}" <<<"$out"
}

# observability_phase::reload — POST /-/reload (Prometheus runs with --web.enable-lifecycle)
observability_phase::reload() {
  observability_phase::k create --raw "${OBS_PROM_PROXY}/-/reload" -f /dev/null >/dev/null 2>&1 \
    || observability_phase::k exec -n "$OBS_NS" deploy/prometheus -- wget -q -O /dev/null --post-data= http://localhost:9090/-/reload >/dev/null 2>&1
}

# observability_phase::wait_rules <reload:true|false> — bounded until the ten are listed. A mounted
# ConfigMap reaches the pod only after the kubelet's sync, so the reload is repeated while waiting.
observability_phase::wait_rules() {
  local reload="$1" deadline missing="" rc
  deadline=$((SECONDS + ${OBS_RULES_TIMEOUT:-180}))
  while :; do
    [[ "$reload" == true ]] && { observability_phase::reload || log::warn "POST /-/reload was not accepted (retrying)"; }
    rc=0; missing="$(observability_phase::rules_missing)" || rc=$?
    [[ "$rc" -eq 0 && -z "$missing" ]] && return 0
    (( SECONDS >= deadline )) && break
    sleep "${OBS_RULES_INTERVAL:-5}"
  done
  if [[ "$rc" -ne 0 ]]; then
    log::error "Prometheus's /api/v1/rules could not be read within ${OBS_RULES_TIMEOUT:-180}s"
  else
    log::error "Prometheus does not list the alert rule(s) $(tr '\n' ' ' <<<"$missing")within ${OBS_RULES_TIMEOUT:-180}s (ConfigMap ${OBS_NS}/prometheus-rules)"
  fi
  log::error "  next: ${KUBECTL:-kubectl} --context ${KUBE_CONTEXT:-kind-${CLUSTER_NAME:-agentic-netops}} -n ${OBS_NS} logs deploy/prometheus | grep -i rule"
  return 1
}

# observability_phase::wait_ready — the four workloads rolled out and Prometheus /-/ready, bounded
observability_phase::wait_ready() {
  local t="${OBS_WAIT_TIMEOUT:-300}" d
  for d in "${OBS_DEPLOYMENTS[@]}"; do
    k8s_wait::rollout "$OBS_NS" "deployment/$d" "$t" || return 1
  done
  k8s_wait::until "$t" 2 "Prometheus ${OBS_NS}/prometheus answering /-/ready" -- observability_phase::prom_get /-/ready || return 1
}

# observability_phase::provider_otlp_hook — the provider's otlp-endpoint setting (T133/T134): the
# provider's traces go to the collector of T129 directly, and that export's health is the
# telemetry-health input Degraded=True/TelemetryUnavailable is set from (data-model.md §18). Default
# OBS_PROVIDER_OTLP_ENDPOINT=http://device-metrics.monitoring.svc:4317 (the collector's OTLP gRPC
# port); `none` writes nothing. A fresh lab left it unset before, so its provider exported nothing
# and reported telemetry healthy through a collector outage (T151 r5 cycle 1, verify-metrics). The
# value is written as `otlp-endpoint` into agentic-netops-system/srl-provider-settings and, when it
# changed, the provider is restarted (its environment is read at start) and the rollout read back.
observability_phase::provider_otlp_hook() {
  local want="${OBS_PROVIDER_OTLP_ENDPOINT-http://device-metrics.monitoring.svc:4317}" have
  [[ -n "$want" && "$want" != none ]] || { log::info "provider otlp-endpoint: not set (OBS_PROVIDER_OTLP_ENDPOINT=${want:-empty})"; return 0; }
  # an OTLP endpoint URL: the provider's exporter (otlptracegrpc.WithEndpointURL) takes the scheme as
  # the transport security — `http://` is plaintext to the in-cluster collector; a bare host:port is
  # not a URL and every export fails (observed live, phase 12)
  if [[ "$want" != http://* && "$want" != https://* ]]; then
    log::error "OBS_PROVIDER_OTLP_ENDPOINT must be an http:// or https:// URL (got ${want})"; return 1
  fi
  have="$(observability_phase::k get configmap srl-provider-settings -n agentic-netops-system \
    -o jsonpath='{.data.otlp-endpoint}' 2>/dev/null)" || have=""
  if [[ "$have" == "$want" ]]; then log::info "provider otlp-endpoint: ${want} (no change)"; return 0; fi
  log::info "provider otlp-endpoint: ${want} (was ${have:-unset}); restarting the provider to read it"
  observability_phase::k patch configmap srl-provider-settings -n agentic-netops-system --type merge \
    -p "$(jq -cn --arg e "$want" '{data: {"otlp-endpoint": $e}}')" >/dev/null || return 1
  observability_phase::k rollout restart deployment/srl-provider -n agentic-netops-system >/dev/null || return 1
  observability_phase::k rollout status deployment/srl-provider -n agentic-netops-system --timeout=300s >&2
}

# observability_phase::_need <function> <library> — source scripts/lib/<library>.sh when the
# function is not defined yet (the offline suite defines stubs first), then require it
observability_phase::_need() {
  if ! declare -F "$1" >/dev/null && [[ -f "$OBS_PHASE_LIB/$2.sh" ]]; then
    # shellcheck disable=SC1090
    source "$OBS_PHASE_LIB/$2.sh"
  fi
  declare -F "$1" >/dev/null && return 0
  log::error "$1 is not available: scripts/lib/$2.sh is missing or does not define it"
  return 1
}

observability_phase::run() {
  local dir rc targets
  evidence::ensure_dir || return 1
  observability_phase::_need observability::generate observability || return 1
  observability_phase::_need observability::install_assets observability || return 1
  observability_phase::_need device_metrics::ensure device_metrics || return 1
  observability_phase::_need grafana_assets::ensure grafana_assets || return 1
  dir="${OBS_RUN_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/agentic-netops-observability.XXXXXX")}"
  mkdir -p "$dir"

  # 1. the generator step: one inventory, one step (T131, FR-094)
  log::info "generating the topology assets and the gNMIc target list into ${dir}"
  observability::generate "$dir" || { log::error "the generator step (observability::generate) failed"; return 1; }
  targets="$dir/gnmic-targets.txt"
  [[ -s "$targets" ]] || { log::error "the generator step wrote no gNMIc target list (${targets})"; return 1; }

  # 2. the device collector, re-rendered from the same target list
  DEVICE_METRICS_TARGETS_FILE="$targets" device_metrics::ensure \
    || { log::error "the device metric collector (device_metrics::ensure) failed with the generated target list"; return 1; }

  # 3. the stack, WITHOUT the alert rules
  observability_phase::_apply_k deploy/observability/prometheus || return 1
  observability::install_assets "$dir" || { log::error "installing the generated assets (observability::install_assets) failed"; return 1; }
  grafana_assets::ensure || { log::error "the Grafana assets (grafana_assets::ensure) failed"; return 1; }
  observability_phase::_apply_k deploy/observability/grafana || return 1
  observability_phase::wait_ready || return 1

  # 4. INTEGRATOR HOOK — the provider's OTLP endpoint
  observability_phase::provider_otlp_hook || { log::error "writing the provider's otlp-endpoint setting failed"; return 1; }

  # 5. the re-check: nothing is loaded on a series that does not exist (AD-55)
  rc=0; evidence_run "$(observability_phase::_eid observability.recheck)" -- observability_phase::recheck || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log::error "ObservabilityReady STOPPED: the live pipeline does not match the gate's observation (above);" \
      "the alert rules were NOT loaded. Next: compare deploy/observability/ with tests/gate/observed/telemetry-series.json (AD-55)"
    return 1
  fi

  # 6. only now the rules, then the reload and the read-back of the ten
  observability_phase::_apply_k deploy/observability/prometheus/rules || return 1
  observability_phase::wait_rules true || return 1
  evidence_run "$(observability_phase::_eid observability.rules-loaded)" -- observability_phase::prom_get /api/v1/rules >/dev/null \
    || { log::error "capturing the loaded rules failed"; return 1; }
  log::info "observability stack Ready: the ten alert rules are loaded"
}

# observability_phase::wait — `make wait-observability` (read-only, bounded)
observability_phase::wait() {
  observability_phase::wait_ready || return 1
  observability_phase::wait_rules false || return 1
  log::info "observability Ready: ${OBS_DEPLOYMENTS[*]} rolled out, Prometheus ready, the ten alert rules loaded"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  : "${KUBE_CONTEXT:=kind-${CLUSTER_NAME:-agentic-netops}}"
  export KUBE_CONTEXT
  case "${1:-}" in
    wait) observability_phase::wait ;;
    recheck) observability_phase::recheck ;;
    *) log::error "usage: observability_phase.sh wait|recheck (the install runs from scripts/provision.sh)"; exit 2 ;;
  esac
fi
