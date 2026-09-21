#!/usr/bin/env bash
# tests/gate/g12_serialization.sh — G12: the exact JSON serialization the device returns for every
# rendered value — identityrefs above all, the afi-safi-name key of the BGP family paths among them —
# observed from a real Get BEFORE any golden is frozen, and written to the tracked
# tests/gate/observed/serialization.json (T043; AD-31, AD-64; research Open item 1, R-36;
# evidence/02 §2.5).
#
# Runs while G8's scratch fabric exists, so every construct kind has a live instance to read: the
# network-instance types (default, mac-vrf, ip-vrf), the subinterface and vxlan-interface types,
# the BGP afi-safi names (global, group and per-neighbour state), the route-table route-type key,
# the EVPN encapsulation, route targets and RD origin, the anycast-gateway flags, an empty leaf, a
# leaf-list, an MTU and the counters (whose VALUES are volatile: only their JSON type is recorded, so
# an unchanged observation is an unchanged file). No timestamp, no run id.
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then exec bash "$GATE_HERE/run_gate.sh" --only G12 "$@"; fi
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"

# <name>|<node-role>|<datastore>|<path>|<volatile 0/1>
g12::reads() {
  local v="$SCRATCH_VLAN" l2="$SCRATCH_L2VNI" l3="$SCRATCH_L3VNI" sp1
  sp1="$(scratch::loopback "$(lab::spines | head -1)")"
  cat <<EOF2
ni-type-default|leaf|CONFIG|/network-instance[name=default]/type|0
ni-type-mac-vrf|leaf|CONFIG|/network-instance[name=${SCRATCH_MACVRF}]/type|0
ni-type-ip-vrf|leaf|CONFIG|/network-instance[name=${SCRATCH_IPVRF}]/type|0
subif-type-bridged|leaf|CONFIG|/interface[name=${SCRATCH_ACCESS_PORT}]/subinterface[index=${v}]/type|0
vxlan-if-type-bridged|leaf|CONFIG|/tunnel-interface[name=${SCRATCH_TUNNEL}]/vxlan-interface[index=${l2}]/type|0
vxlan-if-type-routed|leaf|CONFIG|/tunnel-interface[name=${SCRATCH_TUNNEL}]/vxlan-interface[index=${l3}]/type|0
bgp-afi-safi-global|leaf|CONFIG|/network-instance[name=default]/protocols/bgp/afi-safi[afi-safi-name=*]/afi-safi-name|0
bgp-afi-safi-group|leaf|CONFIG|/network-instance[name=default]/protocols/bgp/group[group-name=${SCRATCH_GROUP_OVERLAY}]/afi-safi[afi-safi-name=*]/afi-safi-name|0
bgp-afi-safi-neighbor-state|leaf|STATE|/network-instance[name=default]/protocols/bgp/neighbor[peer-address=${sp1}]/afi-safi[afi-safi-name=*]/afi-safi-name|0
bgp-evpn-oper-state-neighbor|leaf|STATE|/network-instance[name=default]/protocols/bgp/neighbor[peer-address=${sp1}]/afi-safi[afi-safi-name=srl_nokia-common:evpn]/oper-state|0
bgp-evpn-received-routes|leaf|STATE|/network-instance[name=default]/protocols/bgp/neighbor[peer-address=${sp1}]/afi-safi[afi-safi-name=srl_nokia-common:evpn]/received-routes|1
bgp-session-state|leaf|STATE|/network-instance[name=default]/protocols/bgp/neighbor[peer-address=${sp1}]/session-state|0
inter-as-vpn-state|spine|STATE|/network-instance[name=default]/protocols/bgp/afi-safi[afi-safi-name=srl_nokia-common:evpn]/evpn/inter-as-vpn|0
rr-client-state|spine|STATE|/network-instance[name=default]/protocols/bgp/group[group-name=${SCRATCH_GROUP_OVERLAY}]/route-reflector/client|0
route-type-default-bgp|leaf|STATE|/network-instance[name=default]/route-table/ipv4-unicast/route[ipv4-prefix=${sp1}/32][route-type=*][route-owner=*][id=*][origin-network-instance=*]/route-type|0
route-type-ipvrf-evpn|leaf|STATE|/network-instance[name=${SCRATCH_IPVRF}]/route-table/ipv4-unicast/route[ipv4-prefix=198.18.0.2/32][route-type=*][route-owner=*][id=*][origin-network-instance=*]/route-type|0
evpn-encapsulation|leaf|CONFIG|/network-instance[name=${SCRATCH_MACVRF}]/protocols/bgp-evpn/bgp-instance[id=1]/encapsulation-type|0
evpn-evi|leaf|CONFIG|/network-instance[name=${SCRATCH_MACVRF}]/protocols/bgp-evpn/bgp-instance[id=1]/evi|0
route-target-export|leaf|CONFIG|/network-instance[name=${SCRATCH_MACVRF}]/protocols/bgp-vpn/bgp-instance[id=1]/route-target/export-rt|0
rd-origin|leaf|STATE|/network-instance[name=${SCRATCH_MACVRF}]/protocols/bgp-vpn/bgp-instance[id=1]/route-distinguisher/route-distinguisher-origin|0
irb-anycast-gw-v4|leaf|CONFIG|/interface[name=irb0]/subinterface[index=${v}]/ipv4/address[ip-prefix=${SCRATCH_GW4}]/anycast-gw|0
irb-primary-empty-leaf|leaf|CONFIG|/interface[name=irb0]/subinterface[index=${v}]/ipv4/address[ip-prefix=${SCRATCH_GW4}]/primary|0
irb-anycast-gw-v6|leaf|CONFIG|/interface[name=irb0]/subinterface[index=${v}]/ipv6/address[ip-prefix=${SCRATCH_GW6}]/anycast-gw|0
irb-anycast-gw-mac-origin|leaf|STATE|/interface[name=irb0]/subinterface[index=${v}]/anycast-gw/anycast-gw-mac-origin|0
nd-learn-unsolicited|leaf|CONFIG|/interface[name=irb0]/subinterface[index=${v}]/ipv6/neighbor-discovery/learn-unsolicited|0
leaf-list-export-policy|leaf|CONFIG|/network-instance[name=default]/protocols/bgp/group[group-name=${SCRATCH_GROUP_UNDERLAY}]/export-policy|0
admin-state-enum|leaf|CONFIG|/interface[name=${SCRATCH_ACCESS_PORT}]/admin-state|0
port-mtu-uint16|leaf|CONFIG|/interface[name=${SCRATCH_ACCESS_PORT}]/mtu|0
vlan-id|leaf|CONFIG|/interface[name=${SCRATCH_ACCESS_PORT}]/subinterface[index=${v}]/vlan/encap/single-tagged/vlan-id|0
counter-uint64|leaf|STATE|/interface[name=${SCRATCH_ACCESS_PORT}]/statistics/in-octets|1
EOF2
}

g12::run() {
  gate::item_begin G12 "Exact JSON serialization from a real Get (identityrefs, afi-safi-name)"
  local leaf spine name role ds path vol node out entries="[]" rc
  leaf="$(lab::leaves | head -1)"; spine="$(lab::spines | head -1)"
  while IFS='|' read -r name role ds path vol; do
    [[ -n "$name" ]] || continue
    node="$leaf"; [[ "$role" == spine ]] && node="$spine"
    rc=0; out="$(gate::dev "G12.${name}" "$node" get --type "$ds" --path "$path" 2>/dev/null)" || rc=$?
    entries="$(jq -c --arg n "$name" --arg r "$role" --arg ds "$ds" --arg p "$path" --argjson vol "$vol" --argjson rc "$rc" \
      --argjson resp "$(jq -c . <<<"${out:-null}" 2>/dev/null || echo null)" '
      . + [{name: $n, node_role: $r, datastore: $ds, path_requested: $p,
            ok: ($rc == 0),
            updates: [($resp // [])[]? | .updates[]? | {path: .Path,
                       values: [.values | to_entries[] | {key: .key, json_type: (.value | type),
                                 value: (if $vol == 1 then null else .value end)}]}]}]' <<<"$entries")"
    rc=$(( rc == 0 ? 0 : 1 ))
    gate::item_check "read:${name}" "$rc" "$ds $path"
  done < <(g12::reads)
  local obs
  obs="$(jq -n --argjson e "$entries" '
    def val(n): [$e[] | select(.name == n) | .updates[]?.values[]?.value] | first;
    def qualified(v): (v | type) == "string" and (v | test("^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$"));
    {schema: "agentic-netops.gate.serialization/v1",
     encoding: "JSON_IETF",
     summary: {
       identityref_values_module_qualified: (qualified(val("ni-type-mac-vrf"))),
       network_instance_type_mac_vrf: val("ni-type-mac-vrf"),
       network_instance_type_ip_vrf: val("ni-type-ip-vrf"),
       network_instance_type_default: val("ni-type-default"),
       subinterface_type_bridged: val("subif-type-bridged"),
       vxlan_interface_type_routed: val("vxlan-if-type-routed"),
       afi_safi_name_evpn: ([$e[] | select(.name | startswith("bgp-afi-safi")) | .updates[]?.values[]?.value | ((.. | objects | .["afi-safi-name"]? | strings), strings) | select(test("evpn$"))] | unique),
       route_type_bgp: val("route-type-default-bgp"),
       route_type_ip_vrf_evpn: val("route-type-ipvrf-evpn"),
       empty_leaf_primary: val("irb-primary-empty-leaf"),
       uint64_counter_json_type: ([$e[] | select(.name == "counter-uint64") | .updates[]?.values[]?.json_type] | first),
       uint32_counter_json_type: ([$e[] | select(.name == "bgp-evpn-received-routes") | .updates[]?.values[]?.json_type] | first)},
     reads: $e}')"
  rc=0; jq -e '.summary.network_instance_type_mac_vrf != null and (.summary.afi_safi_name_evpn | length > 0)' <<<"$obs" >/dev/null || rc=1
  gate::item_check "identityref-form-observed" "$rc" "identityref form: $(jq -c '.summary | {network_instance_type_mac_vrf, afi_safi_name_evpn, route_type_bgp}' <<<"$obs")" ""
  gate::observed serialization.json "$obs" || gate::item_check "observed-file" 1 "serialization.json refused"
  gate::item_observe summary "$(jq -c .summary <<<"$obs")"
  gate::item_end
}
