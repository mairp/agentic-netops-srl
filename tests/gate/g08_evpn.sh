#!/usr/bin/env bash
# tests/gate/g08_evpn.sh — G8, the substantive gate item: BGP EVPN behaviour — Type 2, 3 and 5
# routes actually exchanged THROUGH THE ROUTE-REFLECTING SPINES, in both address families, including
# an IPv6 anycast gateway and an IPv6 Type-5 route end to end, and the spines' reflector settings
# (configuration-integrity, read from the configuration datastore, AD-76) — because sessions up with
# zero EVPN routes is the failure signature this item exists to catch. It also observes what the
# Fabric read-back rests on (AD-31): the per-neighbour EVPN family oper-state populated on this node
# type, the per-neighbour EVPN received-route counters zero before any service and non-zero after the
# first spanning one, and every node's loopback active in every other node's route table (T043,
# T187; quickstart.md §1, research Open items 4, 5).
#
# At GateReady nothing is rendered by the provider, so G8 builds its OWN scratch fabric
# (tests/gate/lib/scratch_fabric.sh; plan.md P2: "what shows on this image that the setting is what
# lets routes through is G8 on scratch configuration") and removes it, removal read back:
#   g08::setup       snapshot every root, refuse a non-stock node, underlay + overlay (reflectors
#                    with route-reflector client true; no inter-as-vpn yet)
#   g08::pre         sessions established + EVPN oper-state up per overlay neighbour, loopbacks
#                    active everywhere, EVPN received-routes ZERO (no service yet)
#   g08::tenant      the dual-stack anycast-gateway mac-vrf + ip-vrf on both leaves, clients up
#   g08::reflectors  inter-as-vpn set on the reflectors; G4 part B (both config-only leaves read with
#                    --type config, the state mirror recorded); the reflector check (config)
#   g08::negative    SC-004's negative control, the DECLARED reflection-stopping change of AD-77:
#                    `route-reflector client false` on every reflector's overlay group — what
#                    Fabric.spec.overlay.reflectorClients: false renders (T186). With routes first
#                    shown reflected (precondition), the change applied, a bounded wait for the
#                    withdrawal (GATE_WAIT_WITHDRAW), every session still established, then NO
#                    Type 2/3/5 on the other leaf through the spines (negative_controls.sh
#                    negctl::G8_reflector_clients_false; each check MUST fail). Admitted only if
#                    OBSERVED: otherwise G8 fails with reflector-clients-false-stops-reflection
#                    naming why (AD-77: SC-004 then has no negative control). Recorded as
#                    reflectorClientsFalseStopsReflection. Then, with client restored, inter-as-vpn
#                    REMOVED is run as a RECORDED OBSERVATION only — does reflection continue? —
#                    interASVPNRemovedReflectionContinues (observed on 25.7.1: yes); it is no
#                    longer a control (AD-77). Both go to the tracked
#                    tests/gate/observed/reflection-control.json and the item record.
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
    gate::item_check "reflector-settings:${s}" "$rc" "inter-as-vpn and route-reflector client read back true on $s from the configuration datastore (configuration-integrity, AD-76)"
  done
}

# g08::negative — SC-004's negative control (AD-77), then the recorded inter-as-vpn observation
g08::negative() {
  local a b s n c1 c2 spines rc pre=1 stopped=1 observed=false continues=false reason=""
  a="$(lab::leaves | sed -n 1p)"; b="$(lab::leaves | sed -n 2p)"
  c1="$(lab::clients | sed -n 1p)"; c2="$(lab::clients | sed -n 2p)"
  spines="$(scratch::spine_loopbacks_csv)"
  # traffic first, so a Type-2 exists to be reflected (and then not)
  bash "$GATE_CHECKS" ping "$c1" 4 "$(scratch::client_addr4 "$c2")" - ok >/dev/null 2>&1 || true
  bash "$GATE_CHECKS" ping "$c1" 4 "${SCRATCH_GW4%/*}" - ok >/dev/null 2>&1 || true

  # 0. precondition: reflection IS happening with every setting in place — stopping nothing proves
  #    nothing
  rc=0; CHECK_WAIT="$(g08::win "$GATE_WAIT_ROUTES")" gate::record "G08.control.reflected-before.${b}" G8-control-precondition \
    evpn_route "$b" 3 "$(scratch::loopback "$a")" "$spines" || rc=$?
  gate::item_check "reflection-control-precondition" "$rc" "$b holds ${a}'s Type-3 through a reflecting spine before the declared change (a stop is observable)"
  [[ "$rc" -eq 0 ]] || { pre=0; reason+="no route was reflected before the change (precondition); "; }

  # 1. the declared change: route-reflector client false on every reflector's overlay group
  for s in $(lab::spines); do
    rc=0; scratch::apply "$s" "G08.rr-client-false.${s}" scratch::reflector_client_updates false >/dev/null || rc=$?
    gate::item_check "reflector-clients-false-applied:${s}" "$rc" "route-reflector client false committed on ${s}'s overlay group (≙ Fabric.spec.overlay.reflectorClients: false)"
    [[ "$rc" -eq 0 ]] || { stopped=0; reason+="the change was not accepted on $s; "; }
  done

  # 2. a bounded wait for the withdrawal, so the control does not race it
  rc=0; CHECK_WAIT="$(g08::win "$GATE_WAIT_WITHDRAW")" gate::record "G08.control.withdrawn.${b}" G8-control-withdrawn \
    evpn_route_withdrawn "$b" 3 "$(scratch::loopback "$a")" "$spines" || rc=$?
  [[ "$rc" -eq 0 ]] || { stopped=0; reason+="${a}'s Type-3 still held on $b through the spines ${GATE_WAIT_WITHDRAW}s after the change; "; }

  # 3. every session still established, EVPN up: the stop must be reflection, not a lost session
  for n in $(lab::devices); do
    rc=0; gate::record "G08.control.sessions.${n}" G8-sessions bgp_sessions "$n" --evpn-up "$(g08::overlay_peers "$n")" || rc=$?
    [[ "$rc" -eq 0 ]] || { stopped=0; reason+="sessions or EVPN oper-state not all up on $n during the control; "; }
  done

  # 4. the negative controls themselves — each MUST fail
  negctl::G8_reflector_clients_false "$a" "$b" || { stopped=0; reason+="a Type-2/3/5 check (or the reflector check) PASSED with route-reflector client false — see the negative-control records; "; }

  [[ "$pre" -eq 1 && "$stopped" -eq 1 ]] && observed=true
  gate::item_observe reflectorClientsFalseStopsReflection "$observed"
  if [[ "$observed" == true ]]; then
    gate::item_check "reflector-clients-false-stops-reflection" 0 "OBSERVED: route-reflector client false on every reflector stops reflection — no Type-2/3/5 from $a on $b through the spines, every session established; the declarative control (Fabric.spec.overlay.reflectorClients: false) is admitted as SC-004's negative control (AD-77)" ""
  else
    gate::item_check "reflector-clients-false-stops-reflection" 1 "the declarative control was NOT observed to stop reflection (route-reflector client false ≙ Fabric.spec.overlay.reflectorClients: false): ${reason}SC-004 has no admitted negative control, so no EVPN pass is admitted (AD-77, NFR-013)" ""
  fi

  # 5. RECORDED OBSERVATION (not a pass criterion, AD-77): inter-as-vpn removed — does reflection
  #    continue? Removed while client is still false, so nothing is re-reflected in between; then
  #    client restored and the Type-3 watched for.
  for s in $(lab::spines); do
    rc=0; gate::dev "G08.inter-as-vpn.remove.${s}" "$s" set --delete "$(scratch::inter_as_vpn_updates | cut -f1)" >/dev/null || rc=$?
    gate::item_check "inter-as-vpn-removed:${s}" "$rc" "inter-as-vpn removed from $s for the recorded observation"
  done
  for s in $(lab::spines); do
    rc=0; scratch::apply "$s" "G08.rr-client-true.${s}" scratch::reflector_client_updates true >/dev/null || rc=$?
    gate::item_check "reflector-clients-restored:${s}" "$rc" "route-reflector client true committed back on $s"
  done
  rc=0; CHECK_WAIT="$(g08::win "$GATE_WAIT_ROUTES")" gate::record "G08.obs.no-inter-as-vpn.${b}" G8-obs-no-inter-as-vpn \
    evpn_route "$b" 3 "$(scratch::loopback "$a")" "$spines" || rc=$?
  [[ "$rc" -eq 0 ]] && continues=true
  gate::item_observe interASVPNRemovedReflectionContinues "$continues"
  for s in $(lab::spines); do
    rc=0; scratch::apply "$s" "G08.inter-as-vpn.restore.${s}" scratch::inter_as_vpn_updates >/dev/null || rc=$?
    gate::item_check "inter-as-vpn-restored:${s}" "$rc" "inter-as-vpn true committed back on $s"
  done

  gate::observed reflection-control.json "$(jq -n --argjson o "$observed" --argjson c "$continues" '{
    reflectorClientsFalseStopsReflection: $o,
    interASVPNRemovedReflectionContinues: $c,
    control: "route-reflector client false on every reflecting spine overlay group (Fabric.spec.overlay.reflectorClients: false), every session established; no Type-2/3/5 received through the spines",
    observation: "inter-as-vpn removed from every reflecting spine with route-reflector client true: Type-3 still received through the spines (recorded, not a control)",
    decision: "AD-77"}')" || true
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
