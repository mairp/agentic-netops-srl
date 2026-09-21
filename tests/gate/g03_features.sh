#!/usr/bin/env bash
# tests/gate/g03_features.sh — G3: the platform feature set the constructs depend on, read from
# /system/features on every device: vxlan, evpn, evpn-vxlan-mac-vrf, evpn-vxlan-ifl, bridged,
# acl-subinterface-entry-statistics, acl-if-output-shared-tcam-entries, config-sub-if-l2-mtu
# (quickstart.md §1). An absence is recorded and fails the item — never silently tolerated. The
# features known to be absent on these types (srv6, srv6-dt2, mpls, vxlan-v6) are recorded as
# observed, not failed (evidence/01 §7 G3).
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then exec bash "$GATE_HERE/run_gate.sh" --only G3 "$@"; fi
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"

G3_REQUIRED=(vxlan evpn evpn-vxlan-mac-vrf evpn-vxlan-ifl bridged acl-subinterface-entry-statistics
             acl-if-output-shared-tcam-entries config-sub-if-l2-mtu)
G3_EXPECTED_ABSENT=(srv6 srv6-dt2 mpls vxlan-v6)

g03::run() {
  gate::item_begin G3 "Platform feature set the constructs depend on"
  local node rc out have absent_obs="{}" f
  for node in $(lab::devices); do
    rc=0; gate::ready "G03.features.${node}" G3-features features "$node" "${G3_REQUIRED[@]}" || rc=$?
    gate::item_check "features:${node}" "$rc" "$node advertises ${G3_REQUIRED[*]}"
    out="$(gate::dev "G03.features-list.${node}" "$node" get --type state --path /system/features 2>/dev/null)" || out="[]"
    have="$(jq -c "$(lab::jq_lib)"' gvalues | .[0] // [] | unwrap("features") | if type == "object" then .features else . end | aslist' <<<"$out" 2>/dev/null || echo '[]')"
    local present=()
    for f in "${G3_EXPECTED_ABSENT[@]}"; do jq -e --arg f "$f" 'index($f) != null' <<<"$have" >/dev/null && present+=("$f"); done
    absent_obs="$(jq -c --arg n "$node" --argjson c "$(jq 'length' <<<"$have")" --argjson p "$(printf '%s\n' "${present[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
      '. + {($n): {feature_count: $c, expected_absent_but_present: $p}}' <<<"$absent_obs")"
  done
  gate::item_observe features "$absent_obs"
  gate::item_end
}
