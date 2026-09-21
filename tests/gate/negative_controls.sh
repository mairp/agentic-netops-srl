#!/usr/bin/env bash
# tests/gate/negative_controls.sh — a negative control for every gate readiness check (T045;
# NFR-013, SC-040, R-26).
#
# Every readiness check of the gate (tests/gate/lib/checks.sh, called by the gNN_*.sh items through
# gate::ready) is run here against a system WITHOUT what it checks — a stock node, or a service that
# does not exist — and shown to FAIL, recorded with evidence_negative_control. evidence_run refuses
# a readiness pass of a check id whose failing control is not already in the run's EVIDENCE_DIR,
# and refuses every run of a check whose control PASSED (the check is defective). So a pass is
# admitted only after its check has been seen to fail.
#
# Two kinds of control:
#   stock controls   run by run_gate.sh before the gate writes anything (`negative_controls.sh
#                    stock [G…]`): every readiness check of the selected items against the stock
#                    lab — no BGP, no EVPN instance, no gate filter, no scratch VLAN, no gate Config;
#                    G9's keyed ACL check is also run against the device's OWN stock filters, and
#                    G10's against a valid Config (the rejection check must fail on it)
#   mid-item controls  that need the gate's own scratch to exist, called by the item at the point
#                    the control is meaningful:
#                      negctl::G8_no_inter_as_vpn — G8 with inter-as-vpn REMOVED from the
#                        reflectors: sessions up, instances on both leaves, and no Type 2/3/5
#                        received through the spines (the "established with zero EVPN routes"
#                        signature, research Open item 4)
#                      negctl::G6_mid — the refusal checks fed the VALID value (accepted ⇒ fail)
#                      negctl::G7_no_series — the series check before gNMIc runs
#
# Usage:  negative_controls.sh stock [G1 G2 …]     (default: every item)
#         negative_controls.sh list
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"
# shellcheck source=g01_capabilities.sh
source "$GATE_HERE/g01_capabilities.sh"
# shellcheck source=g10_schema_rejects.sh
source "$GATE_HERE/g10_schema_rejects.sh"

negctl::_leaf()  { lab::leaves | sed -n "${1:-1}p"; }
negctl::_spine() { lab::spines | head -1; }

negctl::G1() {
  gate::negative G1-capabilities capabilities "$(negctl::_leaf)" "$G1_MODELS" vt-scratch-nonexistent-model
}
negctl::G2() {
  gate::negative G2-identity-leaf  identity "$(negctl::_spine)" "v${GATE_PINNED_VERSION}" "${G2_LEAF_TYPE:-7220 IXR-D2L}"
  gate::negative G2-identity-spine identity "$(negctl::_leaf)"  "v${GATE_PINNED_VERSION}" "${G2_SPINE_TYPE:-7220 IXR-D3L}"
}
negctl::G3() {
  # srv6 is absent on every license-free 7220 type (evidence/01 §2.4): the feature check must fail
  gate::negative G3-features features "$(negctl::_leaf)" srv6
}
negctl::G4() {
  gate::negative G4-readback value_equals "$(negctl::_leaf)" CONFIG "/interface[name=${G4_PORT:-ethernet-1/58}]/description" '"vt-scratch-g4"'
  gate::negative G4-durable startup_contains "$(negctl::_leaf)" vt-scratch-g4
  gate::negative G4-inter-as-vpn-state value_equals "$(negctl::_spine)" STATE \
    "/network-instance[name=default]/protocols/bgp/afi-safi[afi-safi-name=srl_nokia-common:evpn]/evpn/inter-as-vpn" true
}
negctl::G5() {
  gate::negative G5-cc-pending value_equals "$(negctl::_leaf)" CONFIG "/interface[name=${G5_PORT:-ethernet-1/57}]/description" '"vt-scratch-g5-cc"'
  gate::negative G5-other-survives value_equals "$(negctl::_leaf)" CONFIG "/interface[name=${G5_OTHER_PORT:-ethernet-1/56}]/description" '"vt-scratch-g5-other"'
}
negctl::G6() {
  local leaf c1 c2
  leaf="$(negctl::_leaf)"; c1="$(lab::clients | sed -n 1p)"; c2="$(lab::clients | sed -n 2p)"
  gate::negative G6-mtu value_equals "$leaf" CONFIG "/interface[name=ethernet-1/49]/mtu" 9412
  gate::negative G6-irb-up value_equals "$leaf" STATE "/interface[name=irb0]/subinterface[index=${SCRATCH_VLAN}]/oper-state" '"up"'
  gate::negative G6-payload ping "$c1" 4 "$(scratch::client_addr4 "$c2")" 9320 ok
}
# the refusal checks, fed the valid value on the scratch fabric: accepted ⇒ the check fails
negctl::G6_mid() {
  local leaf="$1" port="$2" irb="$3"
  gate::negative G6-reject set_rejected "$leaf" "/interface[name=${port}]/mtu" 9412 9412
  gate::negative G6-tenant-refused tenant_mtu_refused "$leaf" "$irb" 9348 9348
}
negctl::G7() {
  local leaf cl
  leaf="$(negctl::_leaf)"
  CHECK_WAIT=0 gate::negative G7-sample subscribe_sample "$leaf" 20 \
    "/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/session-state" \
    "/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=*]/received-routes"
  # on-change: subscribed to one leaf while ANOTHER is disturbed — no update may be claimed
  cl="$(gate::cleanup_path "$leaf" ethernet-1/53)"
  gate::negative G7-onchange subscribe_onchange "$leaf" "/interface[name=ethernet-1/52]/description" \
    "/interface[name=ethernet-1/53]/description" '"vt-scratch-g7-ctl"' "DELETE:${cl}"
}
negctl::G7_no_series() {
  CHECK_WAIT=0 gate::negative G7-series otel_series "$1" vt-scratch-otel 8889 "${G7_REQUIRED_SERIES[@]}"
}
negctl::G8() {
  local l1 l2 s1 spines lbs=()
  l1="$(negctl::_leaf 1)"; l2="$(negctl::_leaf 2)"; s1="$(negctl::_spine)"
  spines="$(scratch::spine_loopbacks_csv)"
  mapfile -t lbs < <(g08::other_loopbacks "$l1")
  gate::negative G8-sessions bgp_sessions "$l1" --evpn-up "$spines"
  gate::negative G8-loopbacks route_active "$l1" default ipv4 '^bgp$' "${lbs[@]}"
  gate::negative G8-received-zero evpn_received "$l1" zero "$spines"
  gate::negative G8-received-nonzero evpn_received "$l1" nonzero "$spines"
  gate::negative G8-reflector reflector "$s1"
  gate::negative G8-ping ping "$(lab::clients | sed -n 1p)" 4 "${SCRATCH_GW4%/*}" - ok
  gate::negative G8-type3 evpn_route "$l2" 3 "$(scratch::loopback "$l1")" "$spines"
  gate::negative G8-type2 evpn_route "$l2" 2 "$(scratch::loopback "$l1")" "$spines"
  gate::negative G8-type5-v4 evpn_route "$l2" 5 "$(scratch::loopback "$l1")" "$spines" 198.18.0.1
  gate::negative G8-type5-v6 evpn_route "$l2" 5 "$(scratch::loopback "$l1")" "$spines" 2001:db8:ffff::1
  gate::negative G8-t5-installed route_active "$l2" "$SCRATCH_IPVRF" ipv4 'bgp-evpn' 198.18.0.1/32
}
# G8 with inter-as-vpn removed: on the gate's own fabric, sessions up, instances on both leaves,
# the reflectors NOT carrying inter-as-vpn — nothing may arrive through the spines
negctl::G8_no_inter_as_vpn() {
  local a b s spines
  spines="$(scratch::spine_loopbacks_csv)"
  a="$(negctl::_leaf 1)"; b="$(negctl::_leaf 2)"
  for s in $(lab::spines); do
    gate::negative G8-reflector reflector "$s"
  done
  CHECK_WAIT="$GATE_WAIT_NEG" gate::negative G8-type3 evpn_route "$b" 3 "$(scratch::loopback "$a")" "$spines"
  CHECK_WAIT=0 gate::negative G8-type2 evpn_route "$b" 2 "$(scratch::loopback "$a")" "$spines"
  CHECK_WAIT=0 gate::negative G8-type5-v4 evpn_route "$b" 5 "$(scratch::loopback "$a")" "$spines" 198.18.0.1
  CHECK_WAIT=0 gate::negative G8-type5-v6 evpn_route "$b" 5 "$(scratch::loopback "$a")" "$spines" 2001:db8:ffff::1
  CHECK_WAIT=0 gate::negative G8-t5-installed route_active "$b" "$SCRATCH_IPVRF" ipv4 'bgp-evpn' 198.18.0.1/32
  CHECK_WAIT=0 gate::negative G8-received-nonzero evpn_received "$b" nonzero "$spines"
}
negctl::G9() {
  local leaf ifid out stock n t s
  leaf="$(negctl::_leaf)"; ifid="${SCRATCH_ACCESS_PORT}.${SCRATCH_VLAN}"
  # the device's OWN stock filters (containerlab ships CPM filters on every node): the keyed check
  # must not be satisfiable by any of them
  out="$(gate::dev "NEG.G9.stock-filters" "$leaf" get --type config --path /acl 2>/dev/null)" || out="[]"
  stock="$(jq -r "$(lab::jq_lib)"' gvalues | .[0] // {} | strip | unwrap("acl")
            | (.["acl-filter"] // [])[] | "\(.name) \(.type) \([(.entry // [])[] | .["sequence-id"]] | first // 10)"' <<<"$out" 2>/dev/null | head -4)"
  if [[ -z "$stock" ]]; then
    log::warn "[negative-control] G9: $leaf lists no stock acl-filter in running; the stock-filter control runs against the containerlab CPM filter names"
    stock=$'cpm ipv4 10\ncpm ipv6 10'
  fi
  while read -r n t s; do
    [[ -n "$n" ]] || continue
    gate::negative G9-acl-applied acl_applied "$leaf" "$n" "$t" "$ifid" input "$s"
    gate::negative G9-acl-applied acl_applied "$leaf" "$n" "$t" "mgmt0.0" input "$s"
  done <<<"$stock"
  # the gate's own filter on the stock node (a service that does not exist)
  gate::negative G9-acl-applied acl_applied "$leaf" vt-scratch-g9-in4 ipv4 "$ifid" input 10,65535
  gate::negative G9-bare-binding value_equals "$leaf" CONFIG "/acl/interface[interface-id=${ifid}]/interface-ref/interface" "\"${SCRATCH_ACCESS_PORT}\""
}
negctl::G10() {
  if ! g10::resolve_target; then
    log::error "[negative-control] G10: no SDC Target for ${G10_NODE}: controls not recorded (G10 will be refused)"
    return 1
  fi
  gate::negative G10-accepts sdc_accepts "$(g10::manifest liveness)"
  gate::negative G10-rejects sdc_rejects "$(g10::manifest valid)"
}
negctl::G12() { :; }   # an observation, no readiness check
negctl::G13() {
  gate::negative G13-intent-on-device value_equals "$(negctl::_leaf)" CONFIG "/interface[name=${G13_PORT:-ethernet-1/55}]/description" '"vt-scratch-g13-intent"'
}

negctl::stock() {
  local items=("$@") i rc=0
  [[ ${#items[@]} -gt 0 ]] || items=(G1 G2 G3 G4 G5 G6 G7 G8 G9 G10 G12 G13)
  for i in "${items[@]}"; do
    declare -F "negctl::${i}" >/dev/null || continue
    log::info "[negative-control] ${i}: running its checks against the stock lab — each MUST fail"
    GATE_ITEM="NEG.${i}" "negctl::${i}" || rc=1
  done
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  # the items' constants (ports, required series, the G8 helpers)
  for f in "$GATE_HERE"/g0[2-9]_*.sh "$GATE_HERE"/g1[23]_*.sh; do
    # shellcheck disable=SC1090
    source "$f"
  done
  gate::init || exit 3
  case "${1:-stock}" in
    stock) shift || true; negctl::stock "$@" ;;
    list) declare -F | sed -n 's/^declare -f negctl::\(G[0-9_a-z]*\)$/\1/p' ;;
    *) echo "usage: $0 stock [G…] | list" >&2; exit 2 ;;
  esac
fi
