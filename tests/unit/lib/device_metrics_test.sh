#!/usr/bin/env bash
# scripts/lib/device_metrics.sh suite (T058; FR-086, FR-100, FR-107, AD-82). Offline: only the
# render is exercised, no cluster is touched.
#
# Proves, one behaviour per check:
#   - the rendered gNMIc configuration subscribes every path of the generated subscriptions file
#     (deploy/observability/gnmic/subscriptions.yaml, from the path register — T128), once, in its
#     subscription, for one target per node of MGMT_CIDR — or of DEVICE_METRICS_TARGETS_FILE;
#   - it carries the service read-back's keyed leaves (T058): oper-down-reasons, the multicast
#     destination and VTEP indexes, the bgp-vpn RD/RT origins, every instance's route table; and
#     the gateway read-back's (T116): anycast-gw MAC origin, address status, EVPN RIB used-route;
#   - every entry of the reason and origin tables is rendered as its own anchored replace, codes
#     are unique within each table, and the catch-all to 0 comes last (an unforeseen reason is
#     exported, never dropped);
#   - the string leaves and the uint64 indexes are converted to integers (gNMIc's OTLP output drops
#     strings), and the processors are all listed on the output;
#   - the rendered document is YAML whose embedded gnmic.yaml is YAML too (when PyYAML exists);
#   - gnmic-self's api-server is on :7890 with metrics; the device certificate is verified with the
#     lab CA by default and DEVICE_METRICS_TLS_VERIFY=0 switches it off (anything else is refused);
#   - the read-back's subscription samples every 5 s against the collector's 20 s expiry.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$ROOT/scripts/lib/device_metrics.sh"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

out="$(bash "$LIB" render 172.25.25.0/24 2>&1)" || { fail "render" "$out"; echo "1 failure"; exit 1; }

# 1. every path of the generated subscriptions file subscribed exactly once; one target per node
SUBS="$ROOT/deploy/observability/gnmic/subscriptions.yaml"
missing=""
n_paths=0
while IFS= read -r p; do
  n_paths=$((n_paths + 1))
  n="$(grep -cF -- "          - \"${p}\"" <<<"$out")"
  [[ "$n" == 1 ]] || missing+="${p} (${n})"$'\n'
done < <(sed -n 's/^      - "\(.*\)"$/\1/p' "$SUBS")
if [[ -z "$missing" && "$n_paths" -ge 40 ]]; then pass "every generated subscription path subscribed once ($n_paths)"; else fail "paths not subscribed once ($n_paths read)" "$missing"; fi
if diff <(sed -n '/^subscriptions:$/,$p' "$SUBS" | sed 's/^/    /') \
    <(awk '/^    subscriptions:$/{on=1} on&&/^    outputs:$/{exit} on' <<<"$out") >/dev/null; then
  pass "subscriptions section embedded verbatim"
else
  fail "subscriptions section differs from $SUBS"
fi
targets="$(grep -cE '^      (spine|leaf)[0-9]+: \{address: "172\.25\.25\.[0-9]+:57400"\}$' <<<"$out")"
if [[ "$targets" == 4 ]]; then pass "one target per node"; else fail "targets: $targets" "$out"; fi
tf="$(mktemp)"
trap 'rm -f "$tf"' EXIT
printf '%s\n' '# T131 targets' 'leaf01 10.9.0.1' '- leaf02: 10.9.0.2:57401' 'spine01: {address: "10.9.0.3"}' >"$tf"
tout="$(DEVICE_METRICS_TARGETS_FILE="$tf" bash "$LIB" render 2>&1)"
if grep -qxF '      leaf01: {address: "10.9.0.1:57400"}' <<<"$tout" && grep -qxF '      leaf02: {address: "10.9.0.2:57401"}' <<<"$tout" \
  && grep -qxF '      spine01: {address: "10.9.0.3:57400"}' <<<"$tout" && [[ "$(grep -c ': {address: ' <<<"$tout")" == 3 ]]; then
  pass "DEVICE_METRICS_TARGETS_FILE replaces the MGMT_CIDR targets"
else
  fail "DEVICE_METRICS_TARGETS_FILE" "$(grep 'address:' <<<"$tout")"
fi
printf '%s\n' 'leaf01 10.9.0.1 extra' >"$tf"
if DEVICE_METRICS_TARGETS_FILE="$tf" bash "$LIB" render >/dev/null 2>&1; then fail "a malformed targets file was accepted"; else pass "a malformed targets file is refused"; fi

# 2. the service read-back's keyed leaves
want=(
  "/interface[name=*]/subinterface[index=*]/oper-down-reason"
  "/network-instance[name=*]/oper-down-reason"
  "/network-instance[name=*]/interface[name=*]/oper-state"
  "/network-instance[name=*]/vxlan-interface[name=*]/oper-state"
  "/tunnel-interface[name=*]/vxlan-interface[index=*]/bridge-table/multicast-destinations/destination[vtep=*][vni=*]/destination-index"
  "/tunnel-interface[name=*]/vxlan-interface[index=*]/bridge-table/multicast-destinations/destination[vtep=*][vni=*]/not-programmed-reason"
  "/tunnel/vxlan-tunnel/vtep[address=*]/index"
  "/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/oper-down-reason"
  "/network-instance[name=*]/protocols/bgp-vpn/bgp-instance[id=*]/route-distinguisher/route-distinguisher-origin"
  "/network-instance[name=*]/protocols/bgp-vpn/bgp-instance[id=*]/route-target/export-route-target-origin"
  "/network-instance[name=*]/protocols/bgp-vpn/bgp-instance[id=*]/route-target/import-route-target-origin"
  "/network-instance[name=*]/route-table/ipv4-unicast/route/active"
  "/network-instance[name=*]/route-table/ipv6-unicast/route/active"
  # the access-list read-back (T108): the programming gate, per-entry TCAM by direction, statistics
  "/acl/datapath-programming/forwarding-complex[slot-id=*][complex-id=*]/programming-complete"
  "/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/tcam-entries/forwarding-complex[complex-identifier=*]/single-instance"
  "/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/tcam-entries/forwarding-complex[complex-identifier=*]/input-total"
  "/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/tcam-entries/forwarding-complex[complex-identifier=*]/output-total"
  "/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/statistics/matched-packets"
  "/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/statistics/incomplete"
  # the anycast-gateway read-back (T116)
  "/interface[name=*]/subinterface[index=*]/anycast-gw/anycast-gw-mac-origin"
  "/interface[name=*]/subinterface[index=*]/ipv4/address[ip-prefix=*]/status"
  "/interface[name=*]/subinterface[index=*]/ipv6/address[ip-prefix=*]/status"
  "/network-instance[name=default]/bgp-rib/afi-safi[afi-safi-name=evpn]/evpn/rib-in-out/rib-in-post/ip-prefix-route[route-distinguisher=*][ethernet-tag-id=*][ip-prefix-length=*][ip-prefix=*][neighbor=*][path-id=*]/used-route"
)
absent=""
for p in "${want[@]}"; do grep -qF -- "- \"${p}\"" <<<"$out" || absent+="$p"$'\n'; done
if [[ -z "$absent" ]]; then pass "service read-back leaves subscribed"; else fail "service read-back leaves not subscribed" "$absent"; fi

# 3. the reason and origin tables: one anchored replace each, unique codes, catch-all last
check_table() {
  local proc="$1" arr="$2" block entries dup bad="" e
  block="$(awk -v p="      ${proc}:" '$0==p{on=1;next} on&&/^      [a-z#]/{on=0} on' <<<"$out")"
  entries="$(bash -c "source '$LIB'; printf '%s\n' \"\${${arr}[@]}\"")"
  while IFS= read -r e; do
    grep -qF -- "old: \"^${e#*:}\$\", new: \"${e%%:*}\"}" <<<"$block" || bad+="$e"$'\n'
  done <<<"$entries"
  dup="$(cut -d: -f1 <<<"$entries" | sort | uniq -d)"
  [[ -z "$dup" ]] || bad+="duplicate codes: $dup"$'\n'
  dup="$(cut -d: -f2- <<<"$entries" | sort | uniq -d)"
  [[ -z "$dup" ]] || bad+="duplicate values: $dup"$'\n'
  grep -q 'replace:' <<<"$(tail -n1 <<<"$block")" && grep -qF 'old: "^[^0-9].*$", new: "0"}' <<<"$(tail -n1 <<<"$block")" \
    || bad+="catch-all to 0 is not the last transform"$'\n'
  if [[ -z "$bad" ]]; then pass "$proc renders $arr"; else fail "$proc" "$bad"; fi
}
check_table reason-to-int DEVICE_METRICS_REASONS
check_table origin-to-int DEVICE_METRICS_ORIGINS
check_table address-status-to-int DEVICE_METRICS_ADDRESS_STATUSES
check_table anycast-origin-to-int DEVICE_METRICS_ANYCAST_ORIGINS
check_table admin-state-to-int DEVICE_METRICS_ADMIN_STATES
check_table app-state-to-int DEVICE_METRICS_APP_STATES

# 4. conversions and the processor list
conv="$(awk '/^      state-as-int:/{on=1} on&&/value-names/{print; exit}' <<<"$out")"
bad=""
for v in '".*session-state$"' '".*oper-state$"' '".*/active$"' '".*oper-down-reason$"' '".*not-programmed-reason$"' \
  '".*route-distinguisher-origin$"' '".*route-target-origin$"' '".*destination-index$"' '".*vtep/index$"' \
  '".*/programming-complete$"' '".*/statistics/incomplete$"' '".*/statistics/matched-packets$"' \
  '".*/used-route$"' '".*address/status$"' '".*anycast-gw-mac-origin$"'; do
  grep -qF -- "$v" <<<"$conv" || bad+="$v"$'\n'
done
if [[ -z "$bad" ]]; then pass "state-as-int converts every string leaf and uint64 index"; else fail "state-as-int misses" "$bad"; fi
if grep -qF 'event-processors: [session-state-to-int, oper-state-to-int, active-to-int, acl-bool-to-int, rib-bool-to-int, reason-to-int, origin-to-int, address-status-to-int, anycast-origin-to-int, admin-state-to-int, app-state-to-int, state-as-int, counters-as-int]' <<<"$out"; then
  pass "processors listed on the output, conversions last"
else
  fail "processor list" "$(grep event-processors <<<"$out")"
fi

# 5. YAML
if python3 -c 'import yaml' 2>/dev/null; then
  if msg="$(python3 -c 'import sys,yaml; d=yaml.safe_load(sys.stdin); g=yaml.safe_load(d["data"]["gnmic.yaml"]); assert g["subscriptions"]["device-state"]["paths"]; assert len(g["subscriptions"]) <= 3; assert "reason-to-int" in g["processors"]' <<<"$out" 2>&1)"; then
    pass "rendered ConfigMap and its gnmic.yaml parse"
  else
    fail "YAML" "$msg"
  fi
else
  pass "YAML parse skipped (no PyYAML)"
fi

# 6. freshness (live-findings 2026-09-21-collector-freshness): a withdrawn invariant must leave the
#    exporter within SC-044's bound — the read-back's subscription (device-state) samples every 5 s,
#    expiry exactly four sample intervals (20 s)
si="$(awk '/^      device-state:$/{on=1} on&&/sample-interval:/{print; exit}' <<<"$out" | grep -oE '[0-9]+')"
exp="$(grep -oE 'metric_expiration: [0-9]+s' "$ROOT/deploy/observability/otel-collector/otel-collector.yaml" | grep -oE '[0-9]+')"
if [[ "$si" == 5 && "$exp" == 20 && $(( si * 4 )) -eq "$exp" ]]; then
  pass "freshness: device-state sample-interval ${si}s, metric_expiration ${exp}s (four intervals, at most 20 s)"
else
  fail "freshness: sample-interval '${si}' / metric_expiration '${exp}' (want 5 s / 20 s)"
fi
# and every other subscription within the expiry (at least two samples per window)
slow="$(grep -oE 'sample-interval: [0-9]+s' <<<"$out" | grep -oE '[0-9]+' | sort -n | tail -n1)"
if [[ -n "$slow" && $(( slow * 2 )) -le "$exp" ]]; then pass "every subscription samples within half the expiry (${slow}s)"; else fail "slowest sample-interval '${slow}' vs metric_expiration '${exp}'"; fi

# 7. gnmic-self and TLS
if grep -qxF '    api-server:' <<<"$out" && grep -qxF '      address: ":7890"' <<<"$out" && grep -qxF '      enable-metrics: true' <<<"$out"; then
  pass "api-server :7890 with metrics (gnmic-self)"
else
  fail "api-server" "$(grep -A2 'api-server' <<<"$out")"
fi
if grep -qxF '    tls-ca: /etc/gnmic-tls/ca.crt' <<<"$out" && grep -qxF '    skip-verify: false' <<<"$out"; then
  pass "device certificate verified with the lab CA by default"
else
  fail "TLS default" "$(grep -E 'skip-verify|tls-ca' <<<"$out")"
fi
off="$(DEVICE_METRICS_TLS_VERIFY=0 bash "$LIB" render 2>&1)"
if grep -qxF '    skip-verify: true' <<<"$off" && ! grep -q 'tls-ca' <<<"$off"; then pass "DEVICE_METRICS_TLS_VERIFY=0 skips verification"; else fail "TLS off" "$(grep -E 'skip-verify|tls-ca' <<<"$off")"; fi
if DEVICE_METRICS_TLS_VERIFY=maybe bash "$LIB" render >/dev/null 2>&1; then fail "DEVICE_METRICS_TLS_VERIFY=maybe accepted"; else pass "an unknown DEVICE_METRICS_TLS_VERIFY is refused"; fi

if [[ "$fails" -gt 0 ]]; then echo "$fails failure(s)"; exit 1; fi
echo "all passed"
