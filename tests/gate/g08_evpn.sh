#!/usr/bin/env bash
# tests/gate/g08_evpn.sh — G8, the substantive gate item: BGP EVPN behaviour — Type 2, 3 and 5
# routes actually exchanged THROUGH THE ROUTE-REFLECTING SPINES, in both address families, including
# an IPv6 anycast gateway and an IPv6 Type-5 route end to end, and the spines' inter-as-vpn setting —
# because sessions up with zero EVPN routes is the failure signature this item exists to catch. It
# also observes what the Fabric read-back rests on (AD-31): the per-neighbour EVPN family oper-state
# populated on this node type, the per-neighbour EVPN received-route counters zero before any
# service and non-zero after the first spanning one, and every node's loopback active in every
# other node's route table (T043; quickstart.md §1, research Open items 4, 5).
#
# At GateReady nothing is rendered by the provider, so G8 builds its OWN scratch fabric
# (tests/gate/lib/scratch_fabric.sh; plan.md P2: "what shows on this image that the setting is what
# lets routes through is G8 on scratch configuration") and removes it, removal read back:
#   g08::setup       snapshot every root, refuse a non-stock node, underlay + overlay (no
#                    inter-as-vpn yet)
#   g08::pre         sessions established + EVPN oper-state up per overlay neighbour, loopbacks
#                    active everywhere, EVPN received-routes ZERO (no service yet)
#   g08::tenant      the dual-stack anycast-gateway mac-vrf + ip-vrf on both leaves, clients up
#   g08::negative    the negative control: inter-as-vpn absent → no Type 2/3/5 through the spines
#                    (negative_controls.sh negctl::G8_no_inter_as_vpn)
#   g08::reflectors  inter-as-vpn set on the reflectors; G4's config-only read-back; reflector check
#   g08::post        data plane (anycast gateway v4/v6, L2 across, Type-5 v4/v6 end to end), the
#                    routes through the spines, installed Type-5 routes, received-routes NON-ZERO
#   (G6, G7, G9, G12 run here, on this fabric)
#   g08::teardown    clients down, one removal transaction per node, read back against the snapshot
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then exec bash "$GATE_HERE/run_gate.sh" --only G8 "$@"; fi
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"

G8_SETUP=0          # 1 once any scratch was written (run_gate.sh's exit trap tears down on 1)
G8_DEGRADED=0       # the underlay never came up: later checks still run, read once, no long waits

g08::win() { if [[ "$G8_DEGRADED" == 1 ]]; then echo 0; else echo "$1"; fi; }
g08::overlay_peers() { if lab::is_spine "$1"; then scratch::leaf_loopbacks_csv; else scratch::spine_loopbacks_csv; fi; }
g08::other_loopbacks() { local n; for n in $(lab::devices); do [[ "$n" == "$1" ]] || printf '%s/32\n' "$(scratch::loopback "$n")"; done; }

g08::setup() {
  gate::item_begin G8 "BGP EVPN through the reflecting spines: Type 2/3/5, IPv6 anycast gateway and IPv6 Type-5"
  local node rc
  for node in $(lab::devices); do
    scratch::snapshot_node "$node" gate G08
    rc=0; scratch::precheck "$node" || rc=$?
    gate::item_check "stock-node:${node}" "$rc" "$node carries no fabric of its own before the gate writes scratch"
  done
  if jq -e 'any(.checks[]; .status == "fail")' "$EVIDENCE_DIR/gate/items/G8.json" >/dev/null; then
    G8_DEGRADED=1
    gate::item_check "underlay-applied" 1 "not applied: a device is not a stock node (nothing written)" ""
    return 1
  fi
  G8_SETUP=1
  for node in $(lab::devices); do
    rc=0; scratch::apply "$node" "G08.underlay.${node}" scratch::underlay_updates "$node" >/dev/null || rc=$?
    gate::item_check "underlay-applied:${node}" "$rc" "scratch underlay + overlay committed on $node (one transaction)"
  done
}

g08::pre() {
  local node rc peers
  for node in $(lab::devices); do
    peers="$(g08::overlay_peers "$node")"
    rc=0; CHECK_WAIT="$(g08::win "$GATE_WAIT_BGP")" gate::ready "G08.sessions.${node}" G8-sessions bgp_sessions "$node" --evpn-up "$peers" || rc=$?
    gate::item_check "sessions-and-evpn-oper-state:${node}" "$rc" "every session established on $node; EVPN family oper-state up (populated) on overlay neighbours $peers"
    [[ "$rc" -eq 0 ]] || G8_DEGRADED=1
  done
  for node in $(lab::devices); do
    local -a lbs=(); mapfile -t lbs < <(g08::other_loopbacks "$node")
    rc=0; CHECK_WAIT="$(g08::win 60)" gate::ready "G08.loopbacks.${node}" G8-loopbacks route_active "$node" default ipv4 '^bgp$' "${lbs[@]}" || rc=$?
    gate::item_check "loopbacks-active:${node}" "$rc" "every other node's system0.0 loopback is active in ${node}'s route table"
  done
  for node in $(lab::leaves); do
    rc=0; gate::ready "G08.received-zero.${node}" G8-received-zero evpn_received "$node" zero "$(scratch::spine_loopbacks_csv)" || rc=$?
    gate::item_check "received-routes-zero-before-service:${node}" "$rc" "per-neighbour EVPN received-routes read 0 on $node before any EVPN instance exists"
  done
}

g08::tenant() {
  local leaf c rc
  for leaf in $(lab::leaves); do
    rc=0; scratch::apply "$leaf" "G08.tenant.${leaf}" scratch::tenant_updates "$leaf" >/dev/null || rc=$?
    gate::item_check "tenant-applied:${leaf}" "$rc" "scratch anycast-gateway mac-vrf + ip-vrf committed on $leaf"
  done
  for c in $(lab::clients); do
    rc=0; scratch::client_up "$c" >/dev/null || rc=$?
    gate::item_check "client-up:${c}" "$rc" "$c on VLAN ${SCRATCH_VLAN} (${SCRATCH_CLIENT_IF}, MTU ${SCRATCH_TENANT_MTU})"
  done
}

g08::negative() {
  # traffic first, so a Type-2 would exist to be (not) reflected
  local c1 c2
  c1="$(lab::clients | sed -n 1p)"; c2="$(lab::clients | sed -n 2p)"
  bash "$GATE_CHECKS" ping "$c1" 4 "$(scratch::client_addr4 "$c2")" - ok >/dev/null 2>&1 || true
  bash "$GATE_CHECKS" ping "$c1" 4 "${SCRATCH_GW4%/*}" - ok >/dev/null 2>&1 || true
  negctl::G8_no_inter_as_vpn
}

g08::reflectors() {
  local s rc
  for s in $(lab::spines); do
    rc=0; scratch::apply "$s" "G08.inter-as-vpn.${s}" scratch::inter_as_vpn_updates >/dev/null || rc=$?
    gate::item_check "inter-as-vpn-set:${s}" "$rc" "inter-as-vpn true committed on reflector $s"
  done
  if declare -F g04::inter_as_vpn >/dev/null && [[ " ${GATE_SELECTED:-G4} " == *" G4 "* ]]; then
    g04::inter_as_vpn
    GATE_ITEM=G8
  fi
  for s in $(lab::spines); do
    rc=0; gate::ready "G08.reflector.${s}" G8-reflector reflector "$s" || rc=$?
    gate::item_check "reflector-settings:${s}" "$rc" "inter-as-vpn and route-reflector client read back true on $s (configuration-integrity)"
  done
}

g08::post() {
  local a b ia ib rc c1 c2 w
  w="$(g08::win "$GATE_WAIT_ROUTES")"
  c1="$(lab::clients | sed -n 1p)"; c2="$(lab::clients | sed -n 2p)"
  # data plane — generates the Type-2 routes too
  rc=0; CHECK_WAIT="$w" gate::ready "G08.ping.gw4" G8-ping ping "$c1" 4 "${SCRATCH_GW4%/*}" - ok || rc=$?
  gate::item_check "anycast-gateway-ipv4" "$rc" "$c1 reaches the IPv4 anycast gateway ${SCRATCH_GW4%/*}"
  rc=0; CHECK_WAIT="$w" gate::ready "G08.ping.gw6" G8-ping ping "$c1" 6 "${SCRATCH_GW6%/*}" - ok || rc=$?
  gate::item_check "property:anycast-gateway-ipv6" "$rc" "$c1 reaches the IPv6 anycast gateway ${SCRATCH_GW6%/*}"
  rc=0; CHECK_WAIT="$w" gate::ready "G08.ping.l2v4" G8-ping ping "$c1" 4 "$(scratch::client_addr4 "$c2")" - ok || rc=$?
  gate::item_check "l2-across-ipv4" "$rc" "$c1 reaches $c2 across the mac-vrf (IPv4)"
  rc=0; CHECK_WAIT="$w" gate::ready "G08.ping.l2v6" G8-ping ping "$c1" 6 "$(scratch::client_addr6 "$c2")" - ok || rc=$?
  gate::item_check "l2-across-ipv6" "$rc" "$c1 reaches $c2 across the mac-vrf (IPv6)"
  bash "$GATE_CHECKS" ping "$c2" 4 "$(scratch::client_addr4 "$c1")" - ok >/dev/null 2>&1 || true
  bash "$GATE_CHECKS" ping "$c2" 6 "$(scratch::client_addr6 "$c1")" - ok >/dev/null 2>&1 || true
  # the routes, each way, received through a reflecting spine
  local spines; spines="$(scratch::spine_loopbacks_csv)"
  for a in $(lab::leaves); do
    for b in $(lab::leaves); do
      [[ "$a" == "$b" ]] && continue
      ia="$(scratch::leaf_index "$a")"
      rc=0; CHECK_WAIT="$w" gate::ready "G08.type3.${b}" G8-type3 evpn_route "$b" 3 "$(scratch::loopback "$a")" "$spines" || rc=$?
      gate::item_check "type3:${a}->${b}" "$rc" "$b received ${a}'s Type-3 (IMET) through a reflecting spine"
      rc=0; CHECK_WAIT="$w" gate::ready "G08.type2.${b}" G8-type2 evpn_route "$b" 2 "$(scratch::loopback "$a")" "$spines" || rc=$?
      gate::item_check "type2:${a}->${b}" "$rc" "$b received ${a}'s Type-2 (MAC/IP) through a reflecting spine"
      rc=0; CHECK_WAIT="$w" gate::ready "G08.type5v4.${b}" G8-type5-v4 evpn_route "$b" 5 "$(scratch::loopback "$a")" "$spines" "198.18.0.${ia}" || rc=$?
      gate::item_check "type5-ipv4:${a}->${b}" "$rc" "$b received ${a}'s IPv4 Type-5 198.18.0.${ia}/32 through a reflecting spine"
      rc=0; CHECK_WAIT="$w" gate::ready "G08.type5v6.${b}" G8-type5-v6 evpn_route "$b" 5 "$(scratch::loopback "$a")" "$spines" "2001:db8:ffff::${ia}" || rc=$?
      gate::item_check "property:ipv6-type5-received:${a}->${b}" "$rc" "$b received ${a}'s IPv6 Type-5 2001:db8:ffff::${ia}/128 through a reflecting spine"
      rc=0; CHECK_WAIT="$w" gate::ready "G08.t5v4-installed.${b}" G8-t5-installed route_active "$b" "$SCRATCH_IPVRF" ipv4 'bgp-evpn' "198.18.0.${ia}/32" || rc=$?
      gate::item_check "type5-ipv4-installed:${b}" "$rc" "the IPv4 Type-5 route is active in ${b}'s ip-vrf route table"
      rc=0; CHECK_WAIT="$w" gate::ready "G08.t5v6-installed.${b}" G8-t5-installed route_active "$b" "$SCRATCH_IPVRF" ipv6 'bgp-evpn' "2001:db8:ffff::${ia}/128" || rc=$?
      gate::item_check "property:ipv6-type5-installed:${b}" "$rc" "the IPv6 Type-5 route is active in ${b}'s ip-vrf route table"
    done
  done
  # end to end through the Type-5 routes: client of leaf01's side → leaf02's ip-vrf prefix
  ib="$(scratch::leaf_index "$(lab::leaves | sed -n 2p)")"
  rc=0; CHECK_WAIT="$w" gate::ready "G08.ping.t5v4" G8-ping ping "$c1" 4 "198.18.0.${ib}" - ok || rc=$?
  gate::item_check "type5-ipv4-end-to-end" "$rc" "$c1 reaches 198.18.0.${ib} routed over the IPv4 Type-5 route"
  rc=0; CHECK_WAIT="$w" gate::ready "G08.ping.t5v6" G8-ping ping "$c1" 6 "2001:db8:ffff::${ib}" - ok || rc=$?
  gate::item_check "property:ipv6-type5-end-to-end" "$rc" "$c1 reaches 2001:db8:ffff::${ib} routed over the IPv6 Type-5 route"
  for a in $(lab::leaves); do
    rc=0; CHECK_WAIT="$w" gate::ready "G08.received-nonzero.${a}" G8-received-nonzero evpn_received "$a" nonzero "$spines" || rc=$?
    gate::item_check "received-routes-nonzero-after-service:${a}" "$rc" "per-neighbour EVPN received-routes non-zero on $a once an instance spans both leaves"
  done
  # a reflector is not a tunnel endpoint
  for a in $(lab::spines); do
    rc=0; gate::record "G08.no-tenant.${a}" G8-no-tenant no_tenant "$a" || rc=$?
    gate::item_check "spine-terminates-no-vxlan:${a}" "$rc" "$a carries no mac-vrf, ip-vrf or vxlan-interface"
  done
}

g08::teardown() {
  [[ "$G8_SETUP" == 1 ]] || { gate::item_resume G8; gate::item_end || true; return 0; }
  local prev="${GATE_ITEM:-}" node c rc
  gate::item_resume G8
  for c in $(lab::clients); do
    rc=0; scratch::client_down "$c" >/dev/null || rc=$?
    gate::item_check "client-down:${c}" "$rc" "scratch VLAN interface removed from $c"
  done
  for node in $(lab::devices); do
    rc=0; scratch::restore_node "$node" G08 >/dev/null || rc=$?
    gate::item_check "removal:${node}" "$rc" "one removal transaction on $node (named scratch deleted, every root back to its snapshot)"
  done
  for node in $(lab::devices); do
    rc=0; scratch::verify_restored "$node" G08 || rc=$?
    gate::item_check "removal-readback:${node}" "$rc" "$node reads back equal to its pre-gate snapshot, no vt-scratch- value left"
  done
  G8_SETUP=0
  gate::item_end || true
  [[ -n "$prev" && "$prev" != G8 ]] && GATE_ITEM="$prev"
  return 0
}
