#!/usr/bin/env bash
# scripts/lib/device_metrics.sh suite (T058; FR-086, FR-100, FR-107, AD-82). Offline: only the
# render is exercised, no cluster is touched.
#
# Proves, one behaviour per check:
#   - the rendered gNMIc configuration subscribes every DEVICE_METRICS_PATHS entry, once, for one
#     target per node of MGMT_CIDR;
#   - it carries the service read-back's keyed leaves (T058): oper-down-reasons, the multicast
#     destination and VTEP indexes, the bgp-vpn RD/RT origins, every instance's route table;
#   - every entry of the reason and origin tables is rendered as its own anchored replace, codes
#     are unique within each table, and the catch-all to 0 comes last (an unforeseen reason is
#     exported, never dropped);
#   - the string leaves and the uint64 indexes are converted to integers (gNMIc's OTLP output drops
#     strings), and the processors are all listed on the output;
#   - the rendered document is YAML whose embedded gnmic.yaml is YAML too (when PyYAML exists).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$ROOT/scripts/lib/device_metrics.sh"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

out="$(bash "$LIB" render 172.25.25.0/24 2>&1)" || { fail "render" "$out"; echo "1 failure"; exit 1; }

# 1. every path subscribed exactly once; one target per node
missing=""
while IFS= read -r p; do
  n="$(grep -cF -- "          - \"${p}\"" <<<"$out")"
  [[ "$n" == 1 ]] || missing+="${p} (${n})"$'\n'
done < <(bash -c "source '$LIB'; printf '%s\n' \"\${DEVICE_METRICS_PATHS[@]}\"")
if [[ -z "$missing" ]]; then pass "every DEVICE_METRICS_PATHS entry subscribed once"; else fail "paths not subscribed once" "$missing"; fi
targets="$(grep -cE '^      (spine|leaf)[0-9]+: \{address: "172\.25\.25\.[0-9]+:57400"\}$' <<<"$out")"
if [[ "$targets" == 4 ]]; then pass "one target per node"; else fail "targets: $targets" "$out"; fi

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

# 4. conversions and the processor list
conv="$(awk '/^      state-as-int:/{on=1} on&&/value-names/{print; exit}' <<<"$out")"
bad=""
for v in '".*session-state$"' '".*oper-state$"' '".*/active$"' '".*oper-down-reason$"' '".*not-programmed-reason$"' \
  '".*route-distinguisher-origin$"' '".*route-target-origin$"' '".*destination-index$"' '".*vtep/index$"' \
  '".*/programming-complete$"' '".*/statistics/incomplete$"' '".*/statistics/matched-packets$"'; do
  grep -qF -- "$v" <<<"$conv" || bad+="$v"$'\n'
done
if [[ -z "$bad" ]]; then pass "state-as-int converts every string leaf and uint64 index"; else fail "state-as-int misses" "$bad"; fi
if grep -qF 'event-processors: [session-state-to-int, oper-state-to-int, active-to-int, acl-bool-to-int, reason-to-int, origin-to-int, state-as-int]' <<<"$out"; then
  pass "processors listed on the output, conversion last"
else
  fail "processor list" "$(grep event-processors <<<"$out")"
fi

# 5. YAML
if python3 -c 'import yaml' 2>/dev/null; then
  if msg="$(python3 -c 'import sys,yaml; d=yaml.safe_load(sys.stdin); g=yaml.safe_load(d["data"]["gnmic.yaml"]); assert g["subscriptions"]["device-state"]["paths"]; assert "reason-to-int" in g["processors"]' <<<"$out" 2>&1)"; then
    pass "rendered ConfigMap and its gnmic.yaml parse"
  else
    fail "YAML" "$msg"
  fi
else
  pass "YAML parse skipped (no PyYAML)"
fi

# 6. freshness (live-findings 2026-09-21-collector-freshness): a withdrawn invariant must leave the
#    exporter within SC-044's bound — sample every 5 s, expiry exactly four sample intervals (20 s)
si="$(grep -oE 'sample-interval: [0-9]+s' <<<"$out" | grep -oE '[0-9]+')"
exp="$(grep -oE 'metric_expiration: [0-9]+s' "$ROOT/deploy/observability/otel-collector/otel-collector.yaml" | grep -oE '[0-9]+')"
if [[ "$si" == 5 && "$exp" == 20 && $(( si * 4 )) -eq "$exp" ]]; then
  pass "freshness: sample-interval ${si}s, metric_expiration ${exp}s (four intervals, at most 20 s)"
else
  fail "freshness: sample-interval '${si}' / metric_expiration '${exp}' (want 5 s / 20 s)"
fi

if [[ "$fails" -gt 0 ]]; then echo "$fails failure(s)"; exit 1; fi
echo "all passed"
