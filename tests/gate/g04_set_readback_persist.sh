#!/usr/bin/env bash
# tests/gate/g04_set_readback_persist.sh — G4: gNMI Set, read-back from the config datastore, and
# durable persistence through /system/configuration/auto-save — plus the CONFIG-ONLY leaves the
# Fabric's configuration-integrity check depends on, inter-as-vpn and route-reflector client, read
# back from the CONFIGURATION datastore (AD-31 as amended by AD-76) (T043, T187; quickstart.md §1,
# evidence/01 §7 G4).
#
#   part A (g04::run, leaf01): auto-save on (its prior value remembered), a scratch description
#     vt-scratch-g4 on an unused port, read back from running (readiness), found in the saved
#     startup configuration (readiness: durability), removed and its removal found in running and in
#     the startup configuration, auto-save put back as it was.
#   part B (g04::inter_as_vpn, called by G8 once the scratch reflectors carry inter-as-vpn and
#     route-reflector client): both leaves read back true with --type config on every spine
#     (readiness; negative control negctl::G4 reads the same paths on a stock spine and must fail),
#     and — RECORDED, never a pass criterion (AD-76) — whether --type state mirrors them: SR Linux
#     25.7.1 was observed not to (state carries config-false leaves only). The observation is
#     config_only_leaves_mirrored_in_state {<spine>: {inter_as_vpn: bool, route_reflector_client: bool}}.
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then exec bash "$GATE_HERE/run_gate.sh" --only G4 "$@"; fi
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"

: "${G4_NODE:=leaf01}"
: "${G4_PORT:=ethernet-1/58}"
G4_VALUE="vt-scratch-g4"
G4_IAV_PATH="/network-instance[name=default]/protocols/bgp/afi-safi[afi-safi-name=srl_nokia-common:evpn]/evpn/inter-as-vpn"
g04::rrc_path() { printf '/network-instance[name=default]/protocols/bgp/group[group-name=%s]/route-reflector/client' "$SCRATCH_GROUP_OVERLAY"; }
G4_TITLE="gNMI Set, read-back and auto-save persistence; config-only leaves read from the configuration datastore"

g04::run() {
  gate::item_begin G4 "$G4_TITLE"
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

# g04::_mirrored <node> <path> — "true" when --type state returns the leaf with a value, else
# "false" (an observation; the raw response is in the run's evidence)
g04::_mirrored() {
  local node="$1" path="$2" out leaf="${2##*/}"
  out="$(gate::dev "G04.state-mirror.${node}.${leaf}" "$node" get --type state --path "$path" 2>/dev/null)" || { echo false; return 0; }
  jq -r "$(lab::jq_lib)"' gvalues | map(select(. != null and . != {} and . != [])) | if length > 0 then "true" else "false" end' <<<"$out" 2>/dev/null || echo false
}

# g04::inter_as_vpn — part B, while the scratch reflectors carry both leaves (called from G8)
g04::inter_as_vpn() {
  local prev="${GATE_ITEM:-}" s rc rrc obs="{}" m1 m2
  rrc="$(g04::rrc_path)"
  gate::item_resume G4 "$G4_TITLE"
  for s in $(lab::spines); do
    rc=0; gate::ready "G04.inter-as-vpn.config.${s}" G4-inter-as-vpn-config value_equals "$s" CONFIG "$G4_IAV_PATH" true || rc=$?
    gate::item_check "inter-as-vpn-config:${s}" "$rc" "config-only inter-as-vpn reads back true from the configuration datastore on $s (configuration-integrity, AD-76)"
    rc=0; gate::ready "G04.rr-client.config.${s}" G4-rr-client-config value_equals "$s" CONFIG "$rrc" true || rc=$?
    gate::item_check "rr-client-config:${s}" "$rc" "config-only route-reflector client reads back true from the configuration datastore on $s (configuration-integrity, AD-76)"
    # RECORDED, not a pass criterion: does the state datastore mirror them? (observed: no)
    m1="$(g04::_mirrored "$s" "$G4_IAV_PATH")"; m2="$(g04::_mirrored "$s" "$rrc")"
    obs="$(jq -c --arg s "$s" --argjson a "$m1" --argjson b "$m2" '.[$s] = {inter_as_vpn: $a, route_reflector_client: $b}' <<<"$obs")"
  done
  gate::item_observe config_only_leaves_mirrored_in_state "$obs"
  gate::item_end || true
  [[ -n "$prev" ]] && GATE_ITEM="$prev"
  return 0
}
