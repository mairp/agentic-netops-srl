#!/usr/bin/env bash
# device_metrics.sh — install the device metric collector (FR-089, FR-086, FR-107; AD-82 decision
# 2026-09-21-state-source in docs/decisions/live-findings.md).
#
#   device_metrics::render [MGMT_CIDR]   the gNMIc ConfigMap monitoring/device-metrics-gnmic on
#                                        stdout: one target per node at its management address of
#                                        MGMT_CIDR (scripts/lib/onboarding.sh — the same addresses
#                                        the DiscoveryRule onboards) or of DEVICE_METRICS_TARGETS_FILE,
#                                        named after the node, which is the `source` label every
#                                        exported series carries
#   device_metrics::ensure               apply the ConfigMap (ownership-labelled) and
#                                        deploy/observability/device-metrics server-side; restart
#                                        gNMIc only when its configuration changed; wait for both
#                                        Deployments, bounded; then read the collector's Prometheus
#                                        endpoint once through evidence_run and require a sample
#                                        from every node (a node the collector cannot read fails
#                                        naming it)
#
# The subscriptions are NOT listed here (T128): they are the path register's (pkg/register
# SubscribeEntries — the union of FR-089's path set and every path the provider's read-back reads,
# internal/verify/collector.go mapping each requested path onto the series this configuration
# exports), generated into deploy/observability/gnmic/subscriptions.yaml by
# internal/telemetry/gnmic_config.go and embedded here verbatim, so the register and the collector
# cannot drift. String states are exported as integers — gNMIc's OTLP output drops every string
# value — by the event processors G7 qualified (tests/gate/observed/telemetry-series.json); the
# reader maps them back with the same tables. internal/telemetry/gnmic_config_test.go holds these
# processors to the register: every registered leaf the pinned YANG types as a JSON string
# (enumeration, uint64, …) is converted here, or it would never be exported.
#
# TLS (T129): the device's gNMI certificate is verified with the lab CA (monitoring/srl-credentials
# key ca.crt, mounted at /etc/gnmic-tls) unless DEVICE_METRICS_TLS_VERIFY is off — the switch stays
# until the device certificates' SANs are verified to carry the management addresses.
#
# env: MGMT_CIDR, KUBECTL, KUBE_CONTEXT, DEVICE_METRICS_TIMEOUT (s, 180), EVIDENCE_DIR,
#      DEVICE_METRICS_TLS_VERIFY (1|0, default 1),
#      DEVICE_METRICS_TARGETS_FILE (optional; replaces the MGMT_CIDR addresses: one target per line,
#      `<name> <address>[:port]` or the YAML forms `<name>: <address>[:port]` /
#      `<name>: {address: "<address>[:port]"}`; `#` comments; T131's generator writes it)

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
# The subscriptions section, generated from the path register (T128) — never edited here.
DEVICE_METRICS_SUBSCRIPTIONS_FILE="$DEVICE_METRICS_ROOT/deploy/observability/gnmic/subscriptions.yaml"
# the gNMIc api-server (gnmic-self: /metrics and health, scraped by Prometheus job gnmic-self) and
# where the deployment mounts the lab CA (monitoring/srl-credentials key ca.crt)
DEVICE_METRICS_API_ADDRESS=":7890"
DEVICE_METRICS_TLS_CA="/etc/gnmic-tls/ca.crt"

# The integer encodings of the enumerated string leaves beyond the three state tables below
# ("<code>:<value>"; internal/verify/collector.go decodeValue carries the same tables, and
# internal/verify/collector_test.go checks the two agree against this script's render). Every
# enum of SR Linux 25.7.1's oper-down-reason leaves the subscriptions above reach (subinterface,
# network-instance, its interface and vxlan-interface, tunnel vxlan-interface, bgp-evpn instance)
# and of the multicast destination's not-programmed-reason. Code 0 is any value not in the
# table, so an unforeseen reason is still exported (present), never dropped as absent.
DEVICE_METRICS_REASONS=(
  1:admin-disabled 2:admin-down 3:associated-ip-vrf-down 4:associated-mac-vrf-down
  5:bgp-vpn-instance-oper-down 6:cfm-ccm-defect 7:egress-hash-failed
  8:esi-label-required-in-ethernet-segment 9:ethernet-segment-multiple-subinterfaces
  10:evpn-mh-standby 11:ingress-hash-failed 12:interface-ref-missing 13:ip-addr-missing
  14:ip-addr-overlap 15:ip-mtu-larger-than-oper-mac-vrf-mtu 16:ip-mtu-resource-exceeded
  17:ip-mtu-too-large 18:ip-vrf-association-missing 19:irb-mac-address-not-programmed
  20:l2-mtu-too-large 21:mac-dup-detected 22:mac-failed 23:mac-vrf-association-missing
  24:missing-xdp-state 25:mpls-mtu-resource-exceeded 26:mpls-mtu-too-large 27:multicast-limit
  28:net-inst-down 29:network-instance-oper-down 30:no-destination-index 31:no-evi
  32:no-ip-config 33:no-irb-hardware-resources 34:no-local-attachment-circuit 35:no-mcid
  36:no-mpls-label 37:no-nexthop-address 38:no-remote-attachment-circuit
  39:no-underlay-egress-next-hop-resources 40:no-vxlan-interface 41:other 42:port-down
  43:stp-not-forwarding 44:subif-down 45:tag-set-not-resolved 46:vrf-type-mismatch
  47:vxlan-if-default-net-inst-source-address-missing 48:vxlan-if-default-net-inst-source-if-down
  49:vxlan-tunnel-down 50:vxlan_interface_no_source_ip_address 51:associations-oper-down
  52:no-associations
)
# the bgp-vpn instance's route-distinguisher-origin / {export,import}-route-target-origin
DEVICE_METRICS_ORIGINS=(
  1:auto-derived-from-evi 2:auto-derived-from-system-ip:0 3:manual 4:none
  5:auto-derived-from-esi-bytes-1-6 6:from-export-policy 7:from-import-policy
)
# an interface address's status (srl_nokia-interfaces-ip, both families; T116)
DEVICE_METRICS_ADDRESS_STATUSES=(
  1:preferred 2:deprecated 3:invalid 4:inaccessible 5:unknown 6:tentative 7:duplicate 8:optimistic
)
# an IRB subinterface's anycast-gw-mac-origin (T116; the gateway renders no anycast-gw-mac, so
# the device reports vrid-auto-derived)
DEVICE_METRICS_ANYCAST_ORIGINS=(
  1:configured 2:vrid-auto-derived
)
# FR-089's interface admin-state (T128; srl_nokia-common admin-state)
DEVICE_METRICS_ADMIN_STATES=(
  1:enable 2:disable
)
# FR-089's application health: an SR Linux application's state (T128; srl_nokia-app-mgmt
# application-state-type on 25.7.1)
DEVICE_METRICS_APP_STATES=(
  1:running 2:starting 3:waiting-for-config 4:stopped 5:error
)

# device_metrics::_transforms <code:value>… — gNMIc event-strings replace transforms, one per
# value (anchored; every tabled value is [a-z0-9_:-] only, so none needs regex escaping), then
# the catch-all to 0
device_metrics::_transforms() {
  local e
  for e in "$@"; do
    printf '            - replace: {apply-on: value, old: "^%s$", new: "%s"}\n' "${e#*:}" "${e%%:*}"
  done
  printf '            - replace: {apply-on: value, old: "^[^0-9].*$", new: "0"}\n'
}

device_metrics::_k() { k8s_wait::_kubectl "$@"; }
# the applied gNMIc configuration (empty when there is none yet)
device_metrics::_otel_config() {
  device_metrics::_k get configmap device-metrics-otel -n "$DEVICE_METRICS_NS" -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true
}

device_metrics::_gnmic_config() {
  device_metrics::_k get configmap device-metrics-gnmic -n "$DEVICE_METRICS_NS" -o jsonpath='{.data.gnmic\.yaml}' 2>/dev/null || true
}

# device_metrics::_hosts [MGMT_CIDR] — the targets, `<name> <address>` per line: from
# DEVICE_METRICS_TARGETS_FILE when set, else the node addresses of MGMT_CIDR
device_metrics::_hosts() {
  local f="${DEVICE_METRICS_TARGETS_FILE:-}"
  if [[ -z "$f" ]]; then
    onboarding::hosts "${1:-${MGMT_CIDR:-172.25.25.0/24}}"
    return
  fi
  [[ -r "$f" ]] || { log::error "device_metrics: DEVICE_METRICS_TARGETS_FILE $f is not readable"; return 1; }
  local out
  out="$(sed -e 's/#.*$//' -e 's/^[[:space:]]*-[[:space:]]*//' -e 's/[{}"'"'"']//g' -e 's/address:[[:space:]]*//' \
      -e 's/:[[:space:]]\{1,\}/ /' "$f" | awk 'NF == 2 {print $1, $2} NF != 0 && NF != 2 {bad = 1} END {exit bad}')" \
    || { log::error "device_metrics: DEVICE_METRICS_TARGETS_FILE $f: a line is not <name> <address>"; return 1; }
  [[ -n "$out" ]] || { log::error "device_metrics: DEVICE_METRICS_TARGETS_FILE $f names no target"; return 1; }
  printf '%s\n' "$out"
}

# device_metrics::_tls — the TLS settings: the lab CA verifies the device certificate unless
# DEVICE_METRICS_TLS_VERIFY is off
device_metrics::_tls() {
  case "${DEVICE_METRICS_TLS_VERIFY:-1}" in
    1 | true | yes | on) printf 'skip-verify: false\n    tls-ca: %s\n' "$DEVICE_METRICS_TLS_CA" ;;
    0 | false | no | off) printf 'skip-verify: true\n' ;;
    *) log::error "device_metrics: DEVICE_METRICS_TLS_VERIFY '${DEVICE_METRICS_TLS_VERIFY}' is not 1 or 0"; return 1 ;;
  esac
}

# device_metrics::_subscriptions — the generated subscriptions section, indented into gnmic.yaml
device_metrics::_subscriptions() {
  local f="$DEVICE_METRICS_SUBSCRIPTIONS_FILE"
  grep -qx 'subscriptions:' "$f" 2>/dev/null \
    || { log::error "device_metrics: $f has no subscriptions section — regenerate: go test ./internal/telemetry -run TestGnmicSubscriptionsGolden -update"; return 1; }
  sed -n '/^subscriptions:$/,$p' "$f" | sed 's/^/    /'
}

device_metrics::render() {
  local cidr="${1:-${MGMT_CIDR:-172.25.25.0/24}}" hosts name addr targets="" subs tls reasons origins statuses anycast admin apps
  hosts="$(device_metrics::_hosts "$cidr")" || return 1
  while read -r name addr; do
    [[ -n "$name" ]] || continue
    [[ "$addr" == *:* ]] || addr+=":${DEVICE_METRICS_GNMI_PORT}"
    targets+="      ${name}: {address: \"${addr}\"}"$'\n'
  done <<<"$hosts"
  subs="$(device_metrics::_subscriptions)" || return 1
  tls="$(device_metrics::_tls)" || return 1
  reasons="$(device_metrics::_transforms "${DEVICE_METRICS_REASONS[@]}")"
  origins="$(device_metrics::_transforms "${DEVICE_METRICS_ORIGINS[@]}")"
  statuses="$(device_metrics::_transforms "${DEVICE_METRICS_ADDRESS_STATUSES[@]}")"
  anycast="$(device_metrics::_transforms "${DEVICE_METRICS_ANYCAST_ORIGINS[@]}")"
  admin="$(device_metrics::_transforms "${DEVICE_METRICS_ADMIN_STATES[@]}")"
  apps="$(device_metrics::_transforms "${DEVICE_METRICS_APP_STATES[@]}")"
  cat <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: device-metrics-gnmic
  namespace: ${DEVICE_METRICS_NS}
  labels: {app.kubernetes.io/name: device-metrics-gnmic, app.kubernetes.io/part-of: agentic-netops, $(ownership::key): "$(ownership::value)"}
data:
  gnmic.yaml: |
    ${tls}
    encoding: json_ietf
    log: true
    api-server:
      address: "${DEVICE_METRICS_API_ADDRESS}"
      enable-metrics: true
    targets:
${targets}${subs}
    outputs:
      device-metrics:
        type: otlp
        endpoint: device-metrics.${DEVICE_METRICS_NS}.svc:4317
        protocol: grpc
        metric-prefix: ""
        append-subscription-name: false
        strip-leading-underscore: true
        strings-as-attributes: false
        counter-patterns: []
        # the output's own counters (gnmic_otlp_output_number_of_{sent,failed}_events_total,
        # gnmic_otlp_output_rejected_data_points_total) on the api-server's /metrics — what makes an
        # export gap visible on the collector-health dashboard (T129/T134, SC-037); not naming-relevant
        enable-metrics: true
        event-processors: [session-state-to-int, oper-state-to-int, active-to-int, acl-bool-to-int, rib-bool-to-int, reason-to-int, origin-to-int, address-status-to-int, anycast-origin-to-int, admin-state-to-int, app-state-to-int, state-as-int, counters-as-int]
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
      # the access-list booleans (T108): the datapath programming gate and a statistics entry's
      # incomplete flag
      acl-bool-to-int:
        event-strings:
          value-names: [".*/programming-complete$", ".*/statistics/incomplete$"]
          transforms:
            - replace: {apply-on: value, old: "^true$", new: "1"}
            - replace: {apply-on: value, old: "^false$", new: "0"}
      # an EVPN RIB route's used-route (T116: the gateway's Type-5 routes)
      rib-bool-to-int:
        event-strings:
          value-names: [".*/used-route$"]
          transforms:
            - replace: {apply-on: value, old: "^true$", new: "1"}
            - replace: {apply-on: value, old: "^false$", new: "0"}
      reason-to-int:
        event-strings:
          value-names: [".*oper-down-reason$", ".*not-programmed-reason$"]
          transforms:
${reasons}
      origin-to-int:
        event-strings:
          value-names: [".*route-distinguisher-origin$", ".*route-target-origin$"]
          transforms:
${origins}
      address-status-to-int:
        event-strings:
          value-names: [".*address/status$"]
          transforms:
${statuses}
      anycast-origin-to-int:
        event-strings:
          value-names: [".*anycast-gw-mac-origin$"]
          transforms:
${anycast}
      # FR-089's interface admin-state and application health (T128)
      admin-state-to-int:
        event-strings:
          value-names: [".*:interface/admin-state$"]
          transforms:
${admin}
      app-state-to-int:
        event-strings:
          value-names: [".*app-management/application/state$"]
          transforms:
${apps}
      # gNMIc's otlp output skips every string value, a digit string included (v0.47.0), so the
      # mapped state leaves are converted to integers or they are never exported — and so are the
      # uint64 indexes (the VTEP's and the multicast destination's), which JSON_IETF encodes as
      # strings (RFC 7951 §6.1; observed on 25.7.1) — and an access-list entry's matched-packets
      # (uint64) with its booleans; its uint16 TCAM counts are converted too, a no-op on a number; and
      # the gateway read-back's used-route, address status and anycast-gw-mac-origin (T116); and
      # FR-089's interface admin-state and application state (T128)
      state-as-int:
        event-convert:
          value-names: [".*session-state$", ".*oper-state$", ".*/active$", ".*oper-down-reason$", ".*not-programmed-reason$", ".*route-distinguisher-origin$", ".*route-target-origin$", ".*destination-index$", ".*vtep/index$", ".*/programming-complete$", ".*/statistics/incomplete$", ".*/statistics/matched-packets$", ".*/single-instance$", ".*/input-total$", ".*/output-total$", ".*/used-route$", ".*address/status$", ".*anycast-gw-mac-origin$", ".*:interface/admin-state$", ".*app-management/application/state$"]
          type: int
      # FR-089's 64-bit counters and gauges (T128), which JSON_IETF encodes as strings: interface,
      # subinterface and VTEP statistics, the interface traffic rate, bridge-table MAC counts, the
      # route- and tunnel-table totals and platform memory — scoped to the numeric leaves only, so
      # no date-and-time leaf (last-clear) is ever handed to the conversion
      counters-as-int:
        event-convert:
          value-names: [".*statistics/[a-z-]*(packets|octets|transitions)$", ".*/traffic-rate/(in|out)-bps$", ".*statistics/(total|active|failed)-entries$", ".*/mac-type/(total|active|failed)-entries$", ".*statistics/total-routes$", ".*statistics/total-tunnels$", ".*memory/(free|physical|reserved)$"]
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
  local otel_before otel_after
  otel_before="$(device_metrics::_otel_config | sha256sum)"
  device_metrics::_k apply --server-side --field-manager=agentic-netops-provision -k "$DEVICE_METRICS_ROOT/deploy/observability/device-metrics" >/dev/null \
    || { log::error "device_metrics: applying deploy/observability/device-metrics failed"; return 1; }
  otel_after="$(device_metrics::_otel_config | sha256sum)"
  # a plain ConfigMap does not roll its Deployment: a changed collector config (e.g. metric_expiration)
  # is loaded only by a restart
  if [[ "$otel_before" != "$otel_after" ]] && device_metrics::_k get pods -n "$DEVICE_METRICS_NS" -l app.kubernetes.io/name=device-metrics-otel -o name 2>/dev/null | grep -q .; then
    device_metrics::_k rollout restart deployment/device-metrics-otel -n "$DEVICE_METRICS_NS" >/dev/null || return 1
  fi
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
    done < <(device_metrics::_hosts "${MGMT_CIDR:-172.25.25.0/24}")
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
