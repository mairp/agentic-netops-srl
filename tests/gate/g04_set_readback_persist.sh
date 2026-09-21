#!/usr/bin/env bash
# tests/gate/g04_set_readback_persist.sh — G4: gNMI Set, read-back from the config datastore, and
# durable persistence through /system/configuration/auto-save — plus one CONFIG-ONLY leaf,
# inter-as-vpn, read back through --type state, on which the Fabric's configuration-integrity check
# depends (AD-31) (T043; quickstart.md §1, evidence/01 §7 G4).
#
#   part A (g04::run, leaf01): auto-save on (its prior value remembered), a scratch description
#     vt-scratch-g4 on an unused port, read back from running (readiness), found in the saved
#     startup configuration (readiness: durability), removed and its removal found in running and in
#     the startup configuration, auto-save put back as it was.
#   part B (g04::inter_as_vpn, called by run_gate.sh during G8 once the scratch reflectors carry
#     inter-as-vpn): the leaf read back through --type state on every spine (readiness).
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then exec bash "$GATE_HERE/run_gate.sh" --only G4 "$@"; fi
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"

: "${G4_NODE:=leaf01}"
: "${G4_PORT:=ethernet-1/58}"
G4_VALUE="vt-scratch-g4"
G4_IAV_PATH="/network-instance[name=default]/protocols/bgp/afi-safi[afi-safi-name=srl_nokia-common:evpn]/evpn/inter-as-vpn"

g04::run() {
  gate::item_begin G4 "gNMI Set, read-back and auto-save persistence; a config-only leaf through --type state"
  local n="$G4_NODE" rc prior cleanup desc="/interface[name=${G4_PORT}]/description" out
  out="$(gate::dev "G04.auto-save.prior" "$n" get --type config --path /system/configuration/auto-save 2>/dev/null)" || out="[]"
  prior="$(jq -c "$(lab::jq_lib)"' gvalues | .[0] // null | unwrap("auto-save") | if type == "object" then .["auto-save"] else . end' <<<"$out" 2>/dev/null || echo null)"
  gate::item_observe auto_save_before_gate "$prior"
  cleanup="$(gate::cleanup_path "$n" "$G4_PORT")"

  rc=0; gate::dev "G04.auto-save.set" "$n" set --delimiter "$LAB_SET_DELIM" --update "$(lab::upd /system/configuration/auto-save true)" >/dev/null || rc=$?
  gate::item_check "auto-save-set" "$rc" "Set /system/configuration/auto-save true accepted"
  rc=0; gate::record "G04.auto-save.readback" G4-auto-save value_equals "$n" CONFIG /system/configuration/auto-save true || rc=$?
  gate::item_check "auto-save-readback" "$rc" "auto-save reads back true from running"

  rc=0; gate::dev "G04.set" "$n" set --delimiter "$LAB_SET_DELIM" --update "$(lab::upd "$desc" "\"$G4_VALUE\"")" >/dev/null || rc=$?
  gate::item_check "set" "$rc" "Set $desc = $G4_VALUE accepted"
  rc=0; gate::ready "G04.readback" G4-readback value_equals "$n" CONFIG "$desc" "\"$G4_VALUE\"" || rc=$?
  gate::item_check "readback" "$rc" "$desc reads back exactly from the config datastore"
  rc=0; CHECK_WAIT=30 gate::ready "G04.durable" G4-durable startup_contains "$n" "$G4_VALUE" || rc=$?
  gate::item_check "durable" "$rc" "the saved startup configuration carries the value (auto-save made the Set durable)"

  rc=0; gate::dev "G04.remove" "$n" set --delete "$cleanup" >/dev/null || rc=$?
  gate::item_check "remove" "$rc" "scratch value removed ($cleanup)"
  rc=0; CHECK_WAIT=15 gate::record "G04.removed" G4-readback absent "$n" CONFIG "$desc" || rc=$?
  gate::item_check "removed-readback" "$rc" "removal read back from running"
  rc=0; CHECK_WAIT=30 gate::record "G04.removed-durable" G4-durable startup_lacks "$n" "$G4_VALUE" || rc=$?
  gate::item_check "removed-durable" "$rc" "removal read back from the saved startup configuration"

  # put auto-save back exactly as it was before the gate
  if [[ "$prior" == true ]]; then
    gate::item_observe auto_save_restored '"left true (it was true before the gate)"'
  else
    rc=0; gate::dev "G04.auto-save.restore" "$n" set --delete /system/configuration/auto-save >/dev/null || rc=$?
    gate::item_check "auto-save-restored" "$rc" "auto-save put back to its prior value (${prior})"
  fi
  gate::item_end
}

# g04::inter_as_vpn — part B, while the scratch reflectors carry inter-as-vpn (called from G8)
g04::inter_as_vpn() {
  local prev="${GATE_ITEM:-}" s rc
  gate::item_resume G4 "gNMI Set, read-back and auto-save persistence; a config-only leaf through --type state"
  for s in $(lab::spines); do
    rc=0; gate::ready "G04.inter-as-vpn.state.${s}" G4-inter-as-vpn-state value_equals "$s" STATE "$G4_IAV_PATH" true || rc=$?
    gate::item_check "inter-as-vpn-state:${s}" "$rc" "config-only inter-as-vpn reads back true through --type state on $s"
  done
  gate::item_end || true
  [[ -n "$prev" ]] && GATE_ITEM="$prev"
  return 0
}
