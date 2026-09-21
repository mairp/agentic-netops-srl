#!/usr/bin/env bash
# tests/gate/lib/scratch_fabric.sh — the capability gate's own scratch fabric (T043 G6–G9, G12;
# FR-108) and the post-render probe's scratch EVPN instance (T051 d).
#
# At GateReady the provider-rendered fabric does not exist yet (FabricReady is after GateReady), and
# plan.md P2 says what shows reflection on this image "is G8 on scratch configuration". So G8 builds
# a scratch underlay + overlay + tenant of its own, observes what it must, and removes all of it with
# the removal read back — FabricReady never starts on a dirty device.
#
# The scratch plan mirrors the default Fabric (examples/fabric/fabric01.yaml) so that what G8 observes
# is what the rendered fabric will rest on:
#   loopbacks (system0.0)  spine01 10.0.0.11, spine02 10.0.0.12, leaf01 10.0.0.1, leaf02 10.0.0.2
#   underlay eBGP          spines AS 65100 (both), leaves 65101/65102, numbered /31s from
#                          198.51.100.0/24 (TEST-NET-2: never a platform allocation), port MTU 9412,
#                          routed ip-mtu 9398; the spines accept their own AS once (allow-own-as 1)
#                          so each spine learns the other spine's loopback through a leaf
#   overlay iBGP EVPN      fabric AS 65000 on the overlay group (local-as), both spines route
#                          reflectors (route-reflector client true); inter-as-vpn is set on the
#                          spines as a SEPARATE step (G8 removes it again for a recorded
#                          observation), and route-reflector client is flipped to false and back
#                          for SC-004's negative control (AD-77)
#   tenant (leaves)        mac-vrf vt-scratch-macvrf (VLAN 3990 on ethernet-1/1, L2VNI/EVI 13990)
#                          with a dual-stack anycast gateway irb0.3990 (203.0.113.1/26,
#                          2001:db8:3990::1/64, ip-mtu 9348) in ip-vrf vt-scratch-ipvrf
#                          (L3VNI/EVI 13991); each leaf also puts lo9.0 (198.18.0.<n>/32,
#                          2001:db8:ffff::<n>/128) in the ip-vrf, the per-leaf prefix whose Type-5
#                          route the OTHER leaf must receive and install — IPv4 and IPv6
#   clients                a VLAN interface vt-scratch-3990 on eth1 (MTU 9348) with 203.0.113.1<n>/26
#                          and 2001:db8:3990::1<n>/64, routes to the per-leaf prefixes via the gateway
#
# Leftover convention (tests/lib/leftovers.sh): every named object is vt-scratch-…; every unnamed
# object the gate creates (interface, subinterface, BGP neighbour) carries description
# vt-scratch-g8, so a dead gate's leftovers are found by the scan.
#
# Removal is snapshot-exact: before writing, the config of every root object the gate will touch
# (each interface, network-instance default, tunnel-interface vxlan0) is read and stored under
# $SCRATCH_SNAPSHOT_DIR/<node>/; removal is ONE atomic Set per node — delete every named scratch
# object, and for every root either delete it (absent before) or replace it with its snapshot —
# followed by a read-back that the root equals its snapshot and no vt-scratch- value remains.
#
# Functions (all device calls through gate::dev → evidence_run):
#   scratch::loopback <node>        scratch::asn <node>          scratch::leaf_index <leaf>
#   scratch::underlay_updates <node>            PATH<TAB>JSON lines
#   scratch::inter_as_vpn_updates              (spines, the separate step)
#   scratch::reflector_client_updates <true|false>  (spines: G8's declared reflection control)
#   scratch::tenant_updates <leaf>
#   scratch::probe_updates <leaf> <evi> <l2vni>  (T051's minimal instance on the rendered fabric)
#   scratch::roots <node> <plan>     scratch::named_deletes <node> <plan>
#   scratch::snapshot_node <node> <plan> <tag>   scratch::apply <node> <tag> <updates-fn> [args]
#   scratch::restore_node <node> <tag> [plan]    scratch::verify_restored <node> <tag> [plan]
#   scratch::precheck <node>         scratch::client_up <client>  scratch::client_down <client>

[[ -n "${__AGENTIC_NETOPS_SCRATCH_FABRIC_SH:-}" ]] && return 0
__AGENTIC_NETOPS_SCRATCH_FABRIC_SH=1

SCRATCH_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../lib/lab.sh
source "$SCRATCH_ROOT/tests/lib/lab.sh"

: "${SCRATCH_FABRIC_ASN:=65000}"
: "${SCRATCH_SPINE_ASN:=65100}"
: "${SCRATCH_LEAF_ASN_BASE:=65100}"      # leaf n → 65100+n
: "${SCRATCH_P2P_NET:=198.51.100}"       # /24, TEST-NET-2
: "${SCRATCH_VLAN:=3990}"
: "${SCRATCH_L2VNI:=13990}"
: "${SCRATCH_L3VNI:=13991}"
: "${SCRATCH_TUNNEL:=vxlan0}"
: "${SCRATCH_MACVRF:=vt-scratch-macvrf}"
: "${SCRATCH_IPVRF:=vt-scratch-ipvrf}"
: "${SCRATCH_DESC:=vt-scratch-g8}"
: "${SCRATCH_GW4:=203.0.113.1/26}"
: "${SCRATCH_GW6:=2001:db8:3990::1/64}"
: "${SCRATCH_LO_IF:=lo9}"
: "${SCRATCH_PORT_MTU:=9412}"
: "${SCRATCH_IP_MTU:=9398}"
: "${SCRATCH_TENANT_MTU:=9348}"
: "${SCRATCH_ACCESS_PORT:=ethernet-1/1}"
SCRATCH_CLIENT_IF="vt-scratch-${SCRATCH_VLAN}"   # 15 characters: the Linux interface-name limit
SCRATCH_POLICY="vt-scratch-loopbacks"
SCRATCH_GROUP_UNDERLAY="vt-scratch-underlay"
SCRATCH_GROUP_OVERLAY="vt-scratch-overlay"

scratch::_idx() { # index of $1 in the list $2 (1-based)
  local i=0 n
  for n in $2; do i=$((i + 1)); [[ "$n" == "$1" ]] && { echo "$i"; return 0; }; done
  return 1
}
scratch::leaf_index()  { scratch::_idx "$1" "$LAB_LEAVES"; }
scratch::spine_index() { scratch::_idx "$1" "$LAB_SPINES"; }

# the default Fabric's stated loopbacks; SCRATCH_LOOPBACK_<node> overrides
scratch::loopback() {
  local var="SCRATCH_LOOPBACK_${1}" i
  if [[ -n "${!var:-}" ]]; then printf '%s' "${!var}"; return; fi
  if lab::is_spine "$1"; then i="$(scratch::spine_index "$1")"; printf '10.0.0.%s' $((10 + i))
  else i="$(scratch::leaf_index "$1")"; printf '10.0.0.%s' "$i"; fi
}
scratch::asn() {
  if lab::is_spine "$1"; then printf '%s' "$SCRATCH_SPINE_ASN"
  else printf '%s' $((SCRATCH_LEAF_ASN_BASE + $(scratch::leaf_index "$1"))); fi
}
scratch::loopbacks_except() { # every device loopback but $1's, one per line
  local n; for n in $(lab::devices); do [[ "$n" == "$1" ]] || scratch::loopback "$n"; echo; done | sed '/^$/d'
}
scratch::spine_loopbacks_csv() { local n o=""; for n in $(lab::spines); do o+="${o:+,}$(scratch::loopback "$n")"; done; printf '%s' "$o"; }
scratch::leaf_loopbacks_csv()  { local n o=""; for n in $(lab::leaves); do o+="${o:+,}$(scratch::loopback "$n")"; done; printf '%s' "$o"; }

# link <spine-index> <leaf-index> → "<spine-port> <spine-addr> <leaf-port> <leaf-addr>"
scratch::link() {
  local s="$1" l="$2" nl idx
  nl="$(wc -w <<<"$LAB_LEAVES")"
  idx=$(( (s - 1) * nl + (l - 1) ))
  printf 'ethernet-1/%s %s.%s ethernet-1/%s %s.%s\n' "$l" "$SCRATCH_P2P_NET" $((2 * idx)) $((48 + s)) "$SCRATCH_P2P_NET" $((2 * idx + 1))
}

scratch::_q() { jq -cn --arg v "$1" '$v'; }   # a JSON string

# --------------------------------------------------------------------------- updates (PATH\tJSON)

scratch::_port() { # <port> <addr/31|""> — routed fabric port
  local port="$1" addr="$2"
  printf '%s\t%s\n' \
    "/interface[name=${port}]/admin-state" '"enable"' \
    "/interface[name=${port}]/description" "$(scratch::_q "$SCRATCH_DESC")" \
    "/interface[name=${port}]/mtu" "$SCRATCH_PORT_MTU" \
    "/interface[name=${port}]/subinterface[index=0]/admin-state" '"enable"' \
    "/interface[name=${port}]/subinterface[index=0]/description" "$(scratch::_q "$SCRATCH_DESC")" \
    "/interface[name=${port}]/subinterface[index=0]/ip-mtu" "$SCRATCH_IP_MTU" \
    "/interface[name=${port}]/subinterface[index=0]/ipv4/admin-state" '"enable"' \
    "/interface[name=${port}]/subinterface[index=0]/ipv4/address[ip-prefix=${addr}]/ip-prefix" "$(scratch::_q "$addr")" \
    "/network-instance[name=default]/interface[name=${port}.0]/name" "$(scratch::_q "${port}.0")"
}

scratch::_neighbor() { # <peer> <group> <peer-as|""> <local-address|"">
  local peer="$1" group="$2" pas="$3" la="$4" b="/network-instance[name=default]/protocols/bgp/neighbor[peer-address=$1]"
  printf '%s\t%s\n' "$b/peer-group" "$(scratch::_q "$group")" "$b/description" "$(scratch::_q "$SCRATCH_DESC")"
  [[ -n "$pas" ]] && printf '%s\t%s\n' "$b/peer-as" "$pas"
  [[ -n "$la" ]] && printf '%s\t%s\n' "$b/transport/local-address" "$(scratch::_q "$la")"
  return 0
}

# scratch::underlay_updates <node> — ports, system0, default instance, policy, eBGP, iBGP EVPN
scratch::underlay_updates() {
  local node="$1" lb asn bgp="/network-instance[name=default]/protocols/bgp" s l sp sa lp la n
  lb="$(scratch::loopback "$node")"; asn="$(scratch::asn "$node")"
  printf '%s\t%s\n' \
    "/network-instance[name=default]/type" '"srl_nokia-network-instance:default"' \
    "/network-instance[name=default]/admin-state" '"enable"' \
    "/interface[name=system0]/admin-state" '"enable"' \
    "/interface[name=system0]/description" "$(scratch::_q "$SCRATCH_DESC")" \
    "/interface[name=system0]/subinterface[index=0]/admin-state" '"enable"' \
    "/interface[name=system0]/subinterface[index=0]/description" "$(scratch::_q "$SCRATCH_DESC")" \
    "/interface[name=system0]/subinterface[index=0]/ipv4/admin-state" '"enable"' \
    "/interface[name=system0]/subinterface[index=0]/ipv4/address[ip-prefix=${lb}/32]/ip-prefix" "$(scratch::_q "${lb}/32")" \
    "/network-instance[name=default]/interface[name=system0.0]/name" '"system0.0"' \
    "/routing-policy/prefix-set[name=${SCRATCH_POLICY}]/prefix[ip-prefix=10.0.0.0/24][mask-length-range=32..32]/ip-prefix" '"10.0.0.0/24"' \
    "/routing-policy/policy[name=${SCRATCH_POLICY}]/statement[name=10]/match/prefix/prefix-set" "$(scratch::_q "$SCRATCH_POLICY")" \
    "/routing-policy/policy[name=${SCRATCH_POLICY}]/statement[name=10]/action/policy-result" '"accept"' \
    "$bgp/admin-state" '"enable"' \
    "$bgp/autonomous-system" "$asn" \
    "$bgp/router-id" "$(scratch::_q "$lb")" \
    "$bgp/afi-safi[afi-safi-name=srl_nokia-common:ipv4-unicast]/admin-state" '"enable"' \
    "$bgp/afi-safi[afi-safi-name=srl_nokia-common:evpn]/admin-state" '"enable"' \
    "$bgp/group[group-name=${SCRATCH_GROUP_UNDERLAY}]/export-policy" "[$(scratch::_q "$SCRATCH_POLICY")]" \
    "$bgp/group[group-name=${SCRATCH_GROUP_UNDERLAY}]/import-policy" "[$(scratch::_q "$SCRATCH_POLICY")]" \
    "$bgp/group[group-name=${SCRATCH_GROUP_UNDERLAY}]/afi-safi[afi-safi-name=srl_nokia-common:ipv4-unicast]/admin-state" '"enable"' \
    "$bgp/group[group-name=${SCRATCH_GROUP_UNDERLAY}]/afi-safi[afi-safi-name=srl_nokia-common:evpn]/admin-state" '"disable"' \
    "$bgp/group[group-name=${SCRATCH_GROUP_OVERLAY}]/peer-as" "$SCRATCH_FABRIC_ASN" \
    "$bgp/group[group-name=${SCRATCH_GROUP_OVERLAY}]/local-as/as-number" "$SCRATCH_FABRIC_ASN" \
    "$bgp/group[group-name=${SCRATCH_GROUP_OVERLAY}]/afi-safi[afi-safi-name=srl_nokia-common:evpn]/admin-state" '"enable"' \
    "$bgp/group[group-name=${SCRATCH_GROUP_OVERLAY}]/afi-safi[afi-safi-name=srl_nokia-common:ipv4-unicast]/admin-state" '"disable"'
  if lab::is_spine "$node"; then
    s="$(scratch::spine_index "$node")"
    printf '%s\t%s\n' \
      "$bgp/group[group-name=${SCRATCH_GROUP_UNDERLAY}]/as-path-options/allow-own-as" 1 \
      "$bgp/group[group-name=${SCRATCH_GROUP_OVERLAY}]/route-reflector/client" true
    for n in $(lab::leaves); do
      l="$(scratch::leaf_index "$n")"
      read -r sp sa lp la < <(scratch::link "$s" "$l")
      scratch::_port "$sp" "${sa}/31"
      scratch::_neighbor "$la" "$SCRATCH_GROUP_UNDERLAY" "$(scratch::asn "$n")" ""
      scratch::_neighbor "$(scratch::loopback "$n")" "$SCRATCH_GROUP_OVERLAY" "" "$lb"
    done
  else
    l="$(scratch::leaf_index "$node")"
    for n in $(lab::spines); do
      s="$(scratch::spine_index "$n")"
      read -r sp sa lp la < <(scratch::link "$s" "$l")
      scratch::_port "$lp" "${la}/31"
      scratch::_neighbor "$sa" "$SCRATCH_GROUP_UNDERLAY" "$SCRATCH_SPINE_ASN" ""
      scratch::_neighbor "$(scratch::loopback "$n")" "$SCRATCH_GROUP_OVERLAY" "" "$lb"
    done
  fi
}

# the separate step on the reflectors — a rendered setting under the configuration-integrity check;
# its removal is a RECORDED observation of G8, no longer a control (AD-77)
scratch::inter_as_vpn_updates() {
  printf '%s\t%s\n' "/network-instance[name=default]/protocols/bgp/afi-safi[afi-safi-name=srl_nokia-common:evpn]/evpn/inter-as-vpn" true
}

# scratch::reflector_client_updates <true|false> — route-reflector client on the reflector's overlay
# group, AS STATED: false is what Fabric.spec.overlay.reflectorClients: false renders (T186), the
# declared change G8 must observe to stop reflection before SC-004's control is admitted (AD-77)
scratch::reflector_client_updates() {
  printf '%s\t%s\n' "/network-instance[name=default]/protocols/bgp/group[group-name=${SCRATCH_GROUP_OVERLAY}]/route-reflector/client" "$1"
}

# scratch::_evpn_instance <ni> <type mac-vrf|ip-vrf> <vni> <vxlan-type bridged|routed>
scratch::_evpn_instance() {
  local ni="$1" type="$2" vni="$3" vt="$4" b="/network-instance[name=$1]"
  local tb="/tunnel-interface[name=${SCRATCH_TUNNEL}]/vxlan-interface[index=${vni}]"
  printf '%s\t%s\n' \
    "$tb/type" "$(scratch::_q "srl_nokia-interfaces:${vt}")" \
    "$tb/ingress/vni" "$vni" \
    "$b/type" "$(scratch::_q "srl_nokia-network-instance:${type}")" \
    "$b/admin-state" '"enable"' \
    "$b/description" "$(scratch::_q "$SCRATCH_DESC")" \
    "$b/vxlan-interface[name=${SCRATCH_TUNNEL}.${vni}]/name" "$(scratch::_q "${SCRATCH_TUNNEL}.${vni}")" \
    "$b/protocols/bgp-evpn/bgp-instance[id=1]/admin-state" '"enable"' \
    "$b/protocols/bgp-evpn/bgp-instance[id=1]/encapsulation-type" '"vxlan"' \
    "$b/protocols/bgp-evpn/bgp-instance[id=1]/vxlan-interface" "$(scratch::_q "${SCRATCH_TUNNEL}.${vni}")" \
    "$b/protocols/bgp-evpn/bgp-instance[id=1]/evi" "$vni" \
    "$b/protocols/bgp-vpn/bgp-instance[id=1]/route-target/export-rt" "$(scratch::_q "target:${SCRATCH_FABRIC_ASN}:${vni}")" \
    "$b/protocols/bgp-vpn/bgp-instance[id=1]/route-target/import-rt" "$(scratch::_q "target:${SCRATCH_FABRIC_ASN}:${vni}")"
}

# scratch::tenant_updates <leaf> — the dual-stack anycast-gateway mac-vrf + ip-vrf of G8
scratch::tenant_updates() {
  local leaf="$1" n ap="$SCRATCH_ACCESS_PORT" v="$SCRATCH_VLAN" irb="/interface[name=irb0]/subinterface[index=${SCRATCH_VLAN}]"
  n="$(scratch::leaf_index "$leaf")"
  printf '%s\t%s\n' \
    "/interface[name=${ap}]/admin-state" '"enable"' \
    "/interface[name=${ap}]/description" "$(scratch::_q "$SCRATCH_DESC")" \
    "/interface[name=${ap}]/vlan-tagging" true \
    "/interface[name=${ap}]/mtu" "$SCRATCH_PORT_MTU" \
    "/interface[name=${ap}]/subinterface[index=${v}]/type" '"srl_nokia-interfaces:bridged"' \
    "/interface[name=${ap}]/subinterface[index=${v}]/admin-state" '"enable"' \
    "/interface[name=${ap}]/subinterface[index=${v}]/description" "$(scratch::_q "$SCRATCH_DESC")" \
    "/interface[name=${ap}]/subinterface[index=${v}]/l2-mtu" "$SCRATCH_PORT_MTU" \
    "/interface[name=${ap}]/subinterface[index=${v}]/vlan/encap/single-tagged/vlan-id" "$v" \
    "/interface[name=irb0]/admin-state" '"enable"' \
    "/interface[name=irb0]/description" "$(scratch::_q "$SCRATCH_DESC")" \
    "$irb/admin-state" '"enable"' \
    "$irb/description" "$(scratch::_q "$SCRATCH_DESC")" \
    "$irb/ip-mtu" "$SCRATCH_TENANT_MTU" \
    "$irb/anycast-gw/virtual-router-id" 1 \
    "$irb/ipv4/admin-state" '"enable"' \
    "$irb/ipv4/address[ip-prefix=${SCRATCH_GW4}]/anycast-gw" true \
    "$irb/ipv4/address[ip-prefix=${SCRATCH_GW4}]/primary" '[null]' \
    "$irb/ipv4/arp/learn-unsolicited" true \
    "$irb/ipv4/arp/host-route/populate[route-type=dynamic]/route-type" '"dynamic"' \
    "$irb/ipv4/arp/evpn/advertise[route-type=dynamic]/route-type" '"dynamic"' \
    "$irb/ipv6/admin-state" '"enable"' \
    "$irb/ipv6/address[ip-prefix=${SCRATCH_GW6}]/anycast-gw" true \
    "$irb/ipv6/address[ip-prefix=${SCRATCH_GW6}]/primary" '[null]' \
    "$irb/ipv6/neighbor-discovery/learn-unsolicited" '"global"' \
    "$irb/ipv6/neighbor-discovery/host-route/populate[route-type=dynamic]/route-type" '"dynamic"' \
    "$irb/ipv6/neighbor-discovery/evpn/advertise[route-type=dynamic]/route-type" '"dynamic"' \
    "/interface[name=${SCRATCH_LO_IF}]/admin-state" '"enable"' \
    "/interface[name=${SCRATCH_LO_IF}]/description" "$(scratch::_q "$SCRATCH_DESC")" \
    "/interface[name=${SCRATCH_LO_IF}]/subinterface[index=0]/admin-state" '"enable"' \
    "/interface[name=${SCRATCH_LO_IF}]/subinterface[index=0]/description" "$(scratch::_q "$SCRATCH_DESC")" \
    "/interface[name=${SCRATCH_LO_IF}]/subinterface[index=0]/ipv4/admin-state" '"enable"' \
    "/interface[name=${SCRATCH_LO_IF}]/subinterface[index=0]/ipv4/address[ip-prefix=198.18.0.${n}/32]/ip-prefix" "$(scratch::_q "198.18.0.${n}/32")" \
    "/interface[name=${SCRATCH_LO_IF}]/subinterface[index=0]/ipv6/admin-state" '"enable"' \
    "/interface[name=${SCRATCH_LO_IF}]/subinterface[index=0]/ipv6/address[ip-prefix=2001:db8:ffff::${n}/128]/ip-prefix" "$(scratch::_q "2001:db8:ffff::${n}/128")"
  scratch::_evpn_instance "$SCRATCH_MACVRF" mac-vrf "$SCRATCH_L2VNI" bridged
  scratch::_evpn_instance "$SCRATCH_IPVRF" ip-vrf "$SCRATCH_L3VNI" routed
  printf '%s\t%s\n' \
    "/network-instance[name=${SCRATCH_MACVRF}]/interface[name=${ap}.${v}]/name" "$(scratch::_q "${ap}.${v}")" \
    "/network-instance[name=${SCRATCH_MACVRF}]/interface[name=irb0.${v}]/name" "$(scratch::_q "irb0.${v}")" \
    "/network-instance[name=${SCRATCH_IPVRF}]/interface[name=irb0.${v}]/name" "$(scratch::_q "irb0.${v}")" \
    "/network-instance[name=${SCRATCH_IPVRF}]/interface[name=${SCRATCH_LO_IF}.0]/name" "$(scratch::_q "${SCRATCH_LO_IF}.0")"
}

# scratch::probe_updates <leaf> <evi> — T051 (d): one scratch mac-vrf with no attachment, enough
# for the leaf to originate a Type-3 (IMET) route on the provider-rendered fabric
scratch::probe_updates() {
  local vni="${2:?evi}"
  scratch::_evpn_instance "vt-scratch-probe-${vni}" mac-vrf "$vni" bridged
}

# --------------------------------------------------------------------------- roots and deletes

# scratch::roots <node> <plan: gate|probe> — the root objects whose pre-state is snapshotted
scratch::roots() {
  local node="$1" plan="${2:-gate}" s l n sp sa lp la
  if [[ "$plan" == probe ]]; then
    lab::is_leaf "$node" && echo "/tunnel-interface[name=${SCRATCH_TUNNEL}]"
    return 0
  fi
  echo "/network-instance[name=default]"
  echo "/interface[name=system0]"
  if lab::is_spine "$node"; then
    s="$(scratch::spine_index "$node")"
    for n in $(lab::leaves); do
      read -r sp sa lp la < <(scratch::link "$s" "$(scratch::leaf_index "$n")"); echo "/interface[name=${sp}]"
    done
  else
    l="$(scratch::leaf_index "$node")"
    for n in $(lab::spines); do
      read -r sp sa lp la < <(scratch::link "$(scratch::spine_index "$n")" "$l"); echo "/interface[name=${lp}]"
    done
    echo "/interface[name=${SCRATCH_ACCESS_PORT}]"
    echo "/interface[name=irb0]"
    echo "/interface[name=${SCRATCH_LO_IF}]"
    echo "/tunnel-interface[name=${SCRATCH_TUNNEL}]"
  fi
}

# scratch::named_deletes <node> <plan> [evi] — named scratch objects (deleting what is absent is a
# no-op on this platform, so the list is unconditional)
scratch::named_deletes() {
  local node="$1" plan="${2:-gate}" evi="${3:-}"
  if [[ "$plan" == probe ]]; then
    lab::is_leaf "$node" && [[ -n "$evi" ]] && echo "/network-instance[name=vt-scratch-probe-${evi}]"
    return 0
  fi
  echo "/routing-policy/policy[name=${SCRATCH_POLICY}]"
  echo "/routing-policy/prefix-set[name=${SCRATCH_POLICY}]"
  if lab::is_leaf "$node"; then
    echo "/network-instance[name=${SCRATCH_MACVRF}]"
    echo "/network-instance[name=${SCRATCH_IPVRF}]"
    echo "/acl/interface[interface-id=${SCRATCH_ACCESS_PORT}.${SCRATCH_VLAN}]"
    echo "/acl/acl-filter[name=vt-scratch-g9-in4][type=ipv4]"
    echo "/acl/acl-filter[name=vt-scratch-g9-in6][type=ipv6]"
    echo "/acl/acl-filter[name=vt-scratch-g9-out4][type=ipv4]"
  fi
}

scratch::_rootkey() { # a filesystem-safe name for a root path
  sed -e 's|^/||' -e 's|[][/=]|_|g' <<<"$1"
}

: "${SCRATCH_SNAPSHOT_DIR:=}"
scratch::_snapdir() {
  local d="${SCRATCH_SNAPSHOT_DIR:-${EVIDENCE_DIR:?EVIDENCE_DIR unset}/gate/scratch}"
  printf '%s/%s' "$d" "$1"
}

# gate::dev is provided by tests/gate/lib/gate.sh; fall back to a plain evidence_run
scratch::_dev() {
  if declare -F gate::dev >/dev/null; then gate::dev "$@"; return; fi
  local id="$1" node="$2"; shift 2
  lab::gnmic_argv "$node"
  evidence_run "$id" -- "${LAB_ARGV[@]}" "$@"
}

# scratch::snapshot_node <node> <plan> <tag> — read and store each root's config (null = absent)
scratch::snapshot_node() {
  local node="$1" plan="$2" tag="$3" dir root out val
  dir="$(scratch::_snapdir "$node")"
  mkdir -p "$dir"
  while read -r root; do
    [[ -n "$root" ]] || continue
    out="$(scratch::_dev "${tag}.snapshot.${node}.$(scratch::_rootkey "$root")" "$node" get --type config --path "$root" 2>/dev/null)" || out="[]"
    val="$(jq -c "$(lab::jq_lib)"' gvalues | .[0] // null' <<<"$out" 2>/dev/null || echo null)"
    [[ "$val" == "{}" ]] && val=null
    printf '%s\n' "$val" >"$dir/$(scratch::_rootkey "$root").json"
    printf '%s\n' "$root" >>"$dir/roots.txt"
  done < <(scratch::roots "$node" "$plan")
  sort -u -o "$dir/roots.txt" "$dir/roots.txt"
  printf '%s\n' "$plan" >"$dir/plan"
}

# scratch::precheck <node> — refuse to build on a device that already carries a fabric: the gate
# runs before FabricReady; a BGP instance or a routed fabric port already configured means the
# device is not the stock node the gate qualifies, and overwriting it is not the gate's to do
scratch::precheck() {
  local node="$1" dir f bad=""
  dir="$(scratch::_snapdir "$node")"
  f="$dir/$(scratch::_rootkey "/network-instance[name=default]").json"
  if [[ -f "$f" ]] && jq -e "$(lab::jq_lib)"' strip | (.protocols.bgp // null) != null' "$f" >/dev/null 2>&1; then
    bad+="network-instance default already runs BGP; "
  fi
  if [[ -n "$bad" ]]; then echo "scratch: $node is not a stock node: $bad" >&2; return 1; fi
  return 0
}

# scratch::apply <node> <evidence-id> <updates-fn> [args…] — one atomic Set of the plan's updates
scratch::apply() {
  local node="$1" id="$2" fn="$3"; shift 3
  local -a argv=()
  local p v
  while IFS=$'\t' read -r p v; do
    [[ -n "$p" ]] || continue
    argv+=(--update "$(lab::upd "$p" "$v")")
  done < <("$fn" "$@")
  [[ ${#argv[@]} -gt 0 ]] || return 0
  scratch::_dev "$id" "$node" set --delimiter "$LAB_SET_DELIM" "${argv[@]}"
}

# scratch::restore_node <node> <tag> [evi] — the single removal transaction
scratch::restore_node() {
  local node="$1" tag="$2" evi="${3:-}" dir plan root key f
  dir="$(scratch::_snapdir "$node")"
  [[ -f "$dir/roots.txt" ]] || { echo "scratch: no snapshot for $node in $dir — nothing to restore" >&2; return 1; }
  plan="$(cat "$dir/plan" 2>/dev/null || echo gate)"
  local -a argv=()
  while read -r p; do [[ -n "$p" ]] && argv+=(--delete "$p"); done < <(scratch::named_deletes "$node" "$plan" "$evi")
  while read -r root; do
    [[ -n "$root" ]] || continue
    key="$(scratch::_rootkey "$root")"; f="$dir/$key.json"
    if [[ ! -s "$f" ]] || [[ "$(cat "$f")" == null ]]; then
      argv+=(--delete "$root")
    else
      argv+=(--replace-path "$root" --replace-file "$f")
    fi
  done <"$dir/roots.txt"
  scratch::_dev "${tag}.restore.${node}" "$node" set "${argv[@]}"
}

# scratch::verify_restored <node> <tag> — every root reads back equal to its snapshot and no
# vt-scratch- value remains anywhere in the running datastore
scratch::verify_restored() {
  local node="$1" tag="$2" dir root key f out now want bad=0
  dir="$(scratch::_snapdir "$node")"
  while read -r root; do
    [[ -n "$root" ]] || continue
    key="$(scratch::_rootkey "$root")"; f="$dir/$key.json"
    out="$(scratch::_dev "${tag}.readback.${node}.${key}" "$node" get --type config --path "$root" 2>/dev/null)" || out="[]"
    now="$(jq -cS "$(lab::jq_lib)"' gvalues | .[0] // null | if . == {} then null else (strip) end' <<<"$out" 2>/dev/null || echo null)"
    want="$(jq -cS "$(lab::jq_lib)"' if . == {} then null else (strip) end' "$f" 2>/dev/null || echo null)"
    if [[ "$now" != "$want" ]]; then
      echo "scratch: $node $root differs from its pre-gate snapshot after removal" >&2
      diff <(jq -S . <<<"$want") <(jq -S . <<<"$now") >&2 || true
      bad=1
    fi
  done <"$dir/roots.txt"
  out="$(scratch::_dev "${tag}.readback.${node}.all" "$node" get --type config --path / 2>/dev/null)" || { echo "scratch: $node datastore unreadable" >&2; return 1; }
  if grep -q "$LAB_SCRATCH_PREFIX" <<<"$out"; then
    echo "scratch: $node still carries vt-scratch- configuration:" >&2
    grep -o "\"[^\"]*${LAB_SCRATCH_PREFIX}[^\"]*\"" <<<"$out" | sort -u | head -20 >&2
    bad=1
  fi
  return "$bad"
}

# --------------------------------------------------------------------------- clients

scratch::client_addr4() { local i; i="$(scratch::_idx "$1" "$LAB_CLIENTS")"; printf '203.0.113.%s' $((10 + i)); }
scratch::client_addr6() { local i; i="$(scratch::_idx "$1" "$LAB_CLIENTS")"; printf '2001:db8:3990::%s' $((10 + i)); }

# scratch::client_up <client> — the client's VLAN interface on eth1 (tenant MTU), addresses, and
# routes to the per-leaf ip-vrf prefixes through the anycast gateway
scratch::client_up() {
  local c="$1" script
  script="set -e
ip link add link eth1 name ${SCRATCH_CLIENT_IF} type vlan id ${SCRATCH_VLAN}
ip link set dev ${SCRATCH_CLIENT_IF} mtu ${SCRATCH_TENANT_MTU}
echo 0 > /proc/sys/net/ipv6/conf/${SCRATCH_CLIENT_IF}/accept_dad
ip link set dev ${SCRATCH_CLIENT_IF} up
ip addr add $(scratch::client_addr4 "$c")/26 dev ${SCRATCH_CLIENT_IF}
ip -6 addr add $(scratch::client_addr6 "$c")/64 dev ${SCRATCH_CLIENT_IF}
ip route add 198.18.0.0/24 via ${SCRATCH_GW4%/*} dev ${SCRATCH_CLIENT_IF}
ip -6 route add 2001:db8:ffff::/64 via ${SCRATCH_GW6%/*} dev ${SCRATCH_CLIENT_IF}
ip link show dev eth1
ip link show dev ${SCRATCH_CLIENT_IF}"
  evidence_run "$(gate::id "G08.client-up.${c}" 2>/dev/null || echo "G08.client-up.${c}")" -- \
    lab::docker exec "$(lab::container "$c")" sh -c "$script"
}

scratch::client_down() {
  local c="$1"
  evidence_run "$(gate::id "G08.client-down.${c}" 2>/dev/null || echo "G08.client-down.${c}")" -- \
    lab::docker exec "$(lab::container "$c")" sh -c "ip link del ${SCRATCH_CLIENT_IF} 2>/dev/null || true; ! ip -o link show | grep -q ${SCRATCH_CLIENT_IF}"
}
