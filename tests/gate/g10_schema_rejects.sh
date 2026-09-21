#!/usr/bin/env bash
# tests/gate/g10_schema_rejects.sh — G10: the DEVIATED device schema the device-configuration layer
# validates against (the pinned sdcio/srlinux-yang-patch commit) still REJECTS the invalid
# configurations the platform relies on being rejected (T043; research Open item 6, R-32;
# evidence/02 §12 item 6, evidence/05 §3.5).
#
# How: a server-side dry-run create of a gate-owned Config (kubectl create --dry-run=server). In
# config-server v0.0.58 that runs the data-server's TransactionSet{DryRun: true} against the
# target's schema (apis/config/handlers/confighandler.go DryRunCreateFn → RunDryRunTransaction), so
# the deviated schema judges the payload and NOTHING is written — no object is persisted, no
# device transaction happens. Each manifest is named vt-scratch-g10-* and carries the gate label.
#
# The must-reject set is exactly the nodes the pinned patch touches, plus the one AD rule evidence/02
# §12 item 6 names — each is a `must` the device itself enforces:
#   r1 ipv4 enabled on a bridged subinterface           (patch: ipv4/admin-state must, rewritten)
#   r2 ipv6 enabled on a bridged subinterface           (patch: ipv6/admin-state must, rewritten)
#   r3 subinterface type bridged on system0             (patch: subinterface/type musts)
#   r4 a vxlan-interface in network-instance default    (patch: vxlan-interface must, rewritten)
#   r5 a network-instance naming a vxlan-interface that does not exist (patch: added must)
#   r6 a bgp-evpn bgp-instance with no bgp-vpn bgp-instance in the same instance (patch: leafref)
#   r7 anycast-gw true on an IRB address without the anycast-gw container (evidence/02 §5.2 must)
#   r8 two IPv4 addresses on system0.0                  (patch: added must)
# Controls: a VALID Config must be accepted (the dry-run reaches the target and validates), and a
# YANG range violation (port mtu 10000, outside the model's 1450..9500) must be refused (the
# validator is live). Observed on data-server v0.0.66 (pass 37): its dry-run enforces the range of a
# plain integer leaf and refuses an unknown leaf, but does NOT check an enumeration value
# (admin-state "bogus" accepted) nor the union-typed single-tagged vlan-id (5000 and "abc" both
# accepted) — so the liveness control uses the mtu range, which the validator does check.
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then exec bash "$GATE_HERE/run_gate.sh" --only G10 "$@"; fi
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"

: "${G10_NODE:=leaf01}"
: "${G10_PRIORITY:=5}"
G10_CASES=(r1 r2 r3 r4 r5 r6 r7 r8 liveness)

# g10::value <case> — the Config's spec.config[0].value (path "/"), JSON
g10::value() {
  local IF='"srl_nokia-interfaces:'
  case "$1" in
    valid)    echo '{"interface":[{"name":"ethernet-1/54","description":"vt-scratch-g10-valid"}]}' ;;
    liveness) echo '{"interface":[{"name":"ethernet-1/54","description":"vt-scratch-g10-liveness","mtu":10000}]}' ;;
    r1) echo '{"interface":[{"name":"ethernet-1/54","description":"vt-scratch-g10-r1","subinterface":[{"index":0,"type":'"${IF}"'bridged","ipv4":{"admin-state":"enable"}}]}]}' ;;
    r2) echo '{"interface":[{"name":"ethernet-1/54","description":"vt-scratch-g10-r2","subinterface":[{"index":0,"type":'"${IF}"'bridged","ipv6":{"admin-state":"enable"}}]}]}' ;;
    r3) echo '{"interface":[{"name":"system0","description":"vt-scratch-g10-r3","subinterface":[{"index":0,"type":'"${IF}"'bridged"}]}]}' ;;
    r4) echo '{"tunnel-interface":[{"name":"vxlan0","vxlan-interface":[{"index":19994,"type":'"${IF}"'bridged","ingress":{"vni":19994}}]}],"network-instance":[{"name":"default","type":"srl_nokia-network-instance:default","vxlan-interface":[{"name":"vxlan0.19994"}]}]}' ;;
    r5) echo '{"network-instance":[{"name":"vt-scratch-g10-r5","type":"srl_nokia-network-instance:mac-vrf","vxlan-interface":[{"name":"vxlan0.19995"}]}]}' ;;
    r6) echo '{"tunnel-interface":[{"name":"vxlan0","vxlan-interface":[{"index":19996,"type":'"${IF}"'bridged","ingress":{"vni":19996}}]}],"network-instance":[{"name":"vt-scratch-g10-r6","type":"srl_nokia-network-instance:mac-vrf","vxlan-interface":[{"name":"vxlan0.19996"}],"protocols":{"bgp-evpn":{"bgp-instance":[{"id":1,"encapsulation-type":"vxlan","vxlan-interface":"vxlan0.19996","evi":19996}]}}}]}' ;;
    r7) echo '{"interface":[{"name":"irb0","description":"vt-scratch-g10-r7","subinterface":[{"index":3997,"ipv4":{"admin-state":"enable","address":[{"ip-prefix":"203.0.113.65/26","anycast-gw":true}]}}]}]}' ;;
    r8) echo '{"interface":[{"name":"system0","description":"vt-scratch-g10-r8","subinterface":[{"index":0,"ipv4":{"admin-state":"enable","address":[{"ip-prefix":"192.0.2.201/32"},{"ip-prefix":"192.0.2.202/32"}]}}]}]}' ;;
  esac
}

# g10::manifest <case> — writes the manifest; prints its path. Needs G10_TARGET_NS / G10_TARGET.
g10::manifest() {
  local c="$1" f
  f="$(gate::manifest "g10-${c}.json")"
  jq -n --arg n "vt-scratch-g10-${c}" --arg ns "$G10_TARGET_NS" --arg t "$G10_TARGET" \
    --arg k "$LAB_GATE_LABEL_KEY" --arg v "$LAB_GATE_LABEL_VALUE" --argjson p "$G10_PRIORITY" \
    --argjson val "$(g10::value "$c")" \
    '{apiVersion: "config.sdcio.dev/v1alpha1", kind: "Config",
      metadata: {name: $n, namespace: $ns,
                 labels: {($k): $v, "config.sdcio.dev/targetName": $t, "config.sdcio.dev/targetNamespace": $ns}},
      spec: {priority: $p, revertive: true, config: [{path: "/", value: $val}]}}' >"$f"
  printf '%s' "$f"
}

g10::resolve_target() {
  local t
  t="$(gate::target_of "$G10_NODE")" || t=""
  [[ -n "$t" ]] || return 1
  G10_TARGET_NS="${t%% *}"; G10_TARGET="${t##* }"
}

g10::run() {
  gate::item_begin G10 "The deviated schema still rejects the must-reject set"
  local rc c
  if ! g10::resolve_target; then
    gate::item_check "target-resolved" 1 "no SDC Target found for $G10_NODE (kubectl get targets.config.sdcio.dev -n $LAB_TARGET_NS)" ""
    gate::item_end; return 1
  fi
  gate::item_observe target "$(jq -cn --arg ns "$G10_TARGET_NS" --arg n "$G10_TARGET" '{namespace: $ns, name: $n}')"
  rc=0; gate::ready "G10.valid" G10-accepts sdc_accepts "$(g10::manifest valid)" || rc=$?
  gate::item_check "valid-accepted" "$rc" "a valid gate Config passes the server-side dry-run (the dry-run reaches the target and validates)"
  local rejected=() accepted=()
  for c in "${G10_CASES[@]}"; do
    rc=0; gate::ready "G10.${c}" G10-rejects sdc_rejects "$(g10::manifest "$c")" || rc=$?
    gate::item_check "rejects:${c}" "$rc" "must-reject case ${c} refused by the deviated schema"
    if [[ "$rc" -eq 0 ]]; then rejected+=("$c"); else accepted+=("$c"); fi
  done
  gate::item_observe rejected "$(printf '%s\n' "${rejected[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  gate::item_observe accepted_by_schema "$(printf '%s\n' "${accepted[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  # a dry-run persists nothing — read it back
  rc=0; gate::run "G10.nothing-persisted" -- sh -c "! ${KUBECTL:-kubectl} --context ${KUBE_CONTEXT:-kind-${CLUSTER_NAME}} get configs.config.sdcio.dev -A -o name | grep vt-scratch-g10" >/dev/null || rc=$?
  gate::item_check "nothing-persisted" "$rc" "no vt-scratch-g10 Config exists after the dry-runs"
  gate::item_end
}
