#!/usr/bin/env bash
# device_metrics.sh — install the device metric collector (FR-089, FR-086, FR-107; AD-82 decision
# 2026-09-21-state-source in docs/decisions/live-findings.md).
#
#   device_metrics::render [MGMT_CIDR]   the gNMIc ConfigMap monitoring/device-metrics-gnmic on
#                                        stdout: one target per node at its management address of
#                                        MGMT_CIDR (scripts/lib/onboarding.sh — the same addresses
#                                        the DiscoveryRule onboards), named after the node, which
#                                        is the `source` label every exported series carries
#   device_metrics::ensure               apply the ConfigMap (ownership-labelled) and
#                                        deploy/observability/device-metrics server-side; restart
#                                        gNMIc only when its configuration changed; wait for both
#                                        Deployments, bounded; then read the collector's Prometheus
#                                        endpoint once through evidence_run and require a sample
#                                        from every node (a node the collector cannot read fails
#                                        naming it)
#
# The subscriptions are the Fabric read-back's applied-side leaves (internal/verify/collector.go
# maps each requested path onto the series this configuration exports) plus G7's EVPN series,
# which T129/T130 later alert on. String states are exported as integers — gNMIc's OTLP output
# drops every string value — by the event processors G7 qualified (tests/gate/observed/
# telemetry-series.json); the reader maps them back with the same tables.
#
# env: MGMT_CIDR, KUBECTL, KUBE_CONTEXT, DEVICE_METRICS_TIMEOUT (s, 180), EVIDENCE_DIR

# shellcheck source-path=SCRIPTDIR
[[ -n "${__AGENTIC_NETOPS_DEVICE_METRICS_SH:-}" ]] && return 0
__AGENTIC_NETOPS_DEVICE_METRICS_SH=1

DEVICE_METRICS_LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_METRICS_ROOT="$(cd -- "$DEVICE_METRICS_LIB/../.." && pwd)"
# shellcheck source=log.sh
source "$DEVICE_METRICS_LIB/log.sh"
# shellcheck source=k8s_wait.sh
source "$DEVICE_METRICS_LIB/k8s_wait.sh"
# shellcheck source=ownership.sh
source "$DEVICE_METRICS_LIB/ownership.sh"
# shellcheck source=onboarding.sh
source "$DEVICE_METRICS_LIB/onboarding.sh"
# shellcheck source=evidence.sh
source "$DEVICE_METRICS_LIB/evidence.sh"

DEVICE_METRICS_NS="monitoring"
DEVICE_METRICS_GNMI_PORT=57400
# The subscribed paths: the Fabric read-back's applied-side leaves, the force-release finding
# presence leaves, and G7's EVPN series (received-routes, bgp-evpn instance).
DEVICE_METRICS_PATHS=(
  "/interface[name=*]/oper-state"
  "/interface[name=*]/subinterface[index=*]/oper-state"
  "/tunnel-interface[name=*]/vxlan-interface[index=*]/oper-state"
  "/network-instance[name=*]/oper-state"
  "/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/session-state"
  "/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=*]/oper-state"
  "/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=*]/received-routes"
  "/network-instance[name=default]/route-table/ipv4-unicast/route/active"
  "/network-instance[name=default]/route-table/ipv6-unicast/route/active"
  "/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/evi"
  "/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/oper-state"
)

device_metrics::_k() { k8s_wait::_kubectl "$@"; }
# the applied gNMIc configuration (empty when there is none yet)
device_metrics::_gnmic_config() {
  device_metrics::_k get configmap device-metrics-gnmic -n "$DEVICE_METRICS_NS" -o jsonpath='{.data.gnmic\.yaml}' 2>/dev/null || true
}

device_metrics::render() {
  local cidr="${1:-${MGMT_CIDR:-172.25.25.0/24}}" hosts name addr targets="" paths="" p
  hosts="$(onboarding::hosts "$cidr")" || return 1
  while read -r name addr; do
    [[ -n "$name" ]] && targets+="      ${name}: {address: \"${addr}:${DEVICE_METRICS_GNMI_PORT}\"}"$'\n'
  done <<<"$hosts"
  for p in "${DEVICE_METRICS_PATHS[@]}"; do paths+="          - \"${p}\""$'\n'; done
  cat <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: device-metrics-gnmic
  namespace: ${DEVICE_METRICS_NS}
  labels: {app.kubernetes.io/name: device-metrics-gnmic, app.kubernetes.io/part-of: agentic-netops, $(ownership::key): "$(ownership::value)"}
data:
  gnmic.yaml: |
    skip-verify: true
    encoding: json_ietf
    log: true
    targets:
${targets}    subscriptions:
      device-state:
        mode: stream
        stream-mode: sample
        sample-interval: 10s
        paths:
${paths}    outputs:
      device-metrics:
        type: otlp
        endpoint: device-metrics.${DEVICE_METRICS_NS}.svc:4317
        protocol: grpc
        metric-prefix: ""
        append-subscription-name: false
        strip-leading-underscore: true
        strings-as-attributes: false
        counter-patterns: []
        event-processors: [session-state-to-int, oper-state-to-int, active-to-int, state-as-int]
    processors:
      session-state-to-int:
        event-strings:
          value-names: [".*session-state$"]
          transforms:
            - replace: {apply-on: value, old: "^established$", new: "5"}
            - replace: {apply-on: value, old: "^openconfirm$", new: "4"}
            - replace: {apply-on: value, old: "^opensent$", new: "3"}
            - replace: {apply-on: value, old: "^active$", new: "2"}
            - replace: {apply-on: value, old: "^connect$", new: "1"}
            - replace: {apply-on: value, old: "^idle$", new: "0"}
      oper-state-to-int:
        event-strings:
          value-names: [".*oper-state$"]
          transforms:
            - replace: {apply-on: value, old: "^up$", new: "1"}
            - replace: {apply-on: value, old: "^down$", new: "0"}
      active-to-int:
        event-strings:
          value-names: [".*/active$"]
          transforms:
            - replace: {apply-on: value, old: "^true$", new: "1"}
            - replace: {apply-on: value, old: "^false$", new: "0"}
      # gNMIc's otlp output skips every string value, a digit string included (v0.47.0), so the
      # mapped state leaves are converted to integers or they are never exported
      state-as-int:
        event-convert:
          value-names: [".*session-state$", ".*oper-state$", ".*/active$"]
          type: int
YAML
}

device_metrics::ensure() {
  local timeout="${DEVICE_METRICS_TIMEOUT:-180}" before after
  log::info "device metric collector (gNMIc → OpenTelemetry Collector) in ${DEVICE_METRICS_NS}"
  device_metrics::_k get namespace "$DEVICE_METRICS_NS" -o name >/dev/null 2>&1 \
    || { log::error "device_metrics: namespace ${DEVICE_METRICS_NS} is missing — scripts/lib/lab_secrets.sh creates it with the collector's credentials"; return 1; }
  device_metrics::_k get secret srl-credentials -n "$DEVICE_METRICS_NS" -o name >/dev/null 2>&1 \
    || { log::error "device_metrics: ${DEVICE_METRICS_NS}/srl-credentials is missing (scripts/lib/lab_secrets.sh)"; return 1; }
  before="$(device_metrics::_gnmic_config | sha256sum)"
  device_metrics::render "${MGMT_CIDR:-172.25.25.0/24}" \
    | device_metrics::_k apply --server-side --field-manager=agentic-netops-provision -f - >/dev/null \
    || { log::error "device_metrics: applying ConfigMap device-metrics-gnmic failed"; return 1; }
  after="$(device_metrics::_gnmic_config | sha256sum)"
  device_metrics::_k apply --server-side --field-manager=agentic-netops-provision -k "$DEVICE_METRICS_ROOT/deploy/observability/device-metrics" >/dev/null \
    || { log::error "device_metrics: applying deploy/observability/device-metrics failed"; return 1; }
  if [[ "$before" != "$after" ]] && device_metrics::_k get pods -n "$DEVICE_METRICS_NS" -l app.kubernetes.io/name=device-metrics-gnmic -o name 2>/dev/null | grep -q .; then
    device_metrics::_k rollout restart deployment/device-metrics-gnmic -n "$DEVICE_METRICS_NS" >/dev/null || return 1
  fi
  local d
  for d in device-metrics-otel device-metrics-gnmic; do
    device_metrics::_k rollout status "deployment/$d" -n "$DEVICE_METRICS_NS" --timeout="${timeout}s" >/dev/null \
      || { log::error "device_metrics: deployment/$d not rolled out within ${timeout}s — see: kubectl -n ${DEVICE_METRICS_NS} logs deploy/$d"; return 1; }
  done
  device_metrics::wait_samples "$timeout"
}

# device_metrics::wait_samples <timeout> — every node has at least one sample in the collector
# (bounded; the last read is captured through evidence_run).
device_metrics::wait_samples() {
  local timeout="$1" deadline missing name addr out
  deadline=$((SECONDS + timeout))
  evidence::ensure_dir || return 1
  while :; do
    out="$(device_metrics::_k exec -n "$DEVICE_METRICS_NS" deploy/device-metrics-gnmic -- \
        wget -q -O - "http://device-metrics.${DEVICE_METRICS_NS}.svc:8889/metrics" 2>/dev/null \
      || device_metrics::_k get --raw "/api/v1/namespaces/${DEVICE_METRICS_NS}/services/device-metrics:8889/proxy/metrics" 2>/dev/null || true)"
    missing=""
    while read -r name addr; do
      [[ -n "$name" ]] || continue
      grep -q "source=\"${name}\"" <<<"$out" || missing+=" $name"
    done < <(onboarding::hosts "${MGMT_CIDR:-172.25.25.0/24}")
    if [[ -z "$missing" ]]; then
      local id="device-metrics.samples" n=1
      while [[ -e "$EVIDENCE_DIR/$id.json" ]]; do n=$((n + 1)); id="device-metrics.samples-${n}"; done
      evidence_run "$id" -- "${KUBECTL:-kubectl}" ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} get --raw \
        "/api/v1/namespaces/${DEVICE_METRICS_NS}/services/device-metrics:8889/proxy/metrics" >/dev/null || true
      log::info "device metric collector: samples from every node"
      return 0
    fi
    if (( SECONDS >= deadline )); then
      log::error "device_metrics: no sample from${missing} within ${timeout}s — see: kubectl -n ${DEVICE_METRICS_NS} logs deploy/device-metrics-gnmic"
      return 1
    fi
    sleep 5
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  case "${1:-ensure}" in
    ensure) device_metrics::ensure ;;
    render) device_metrics::render "${2:-}" ;;
    *) log::error "device_metrics: usage: device_metrics.sh [ensure|render [MGMT_CIDR]]"; exit 2 ;;
  esac
fi
