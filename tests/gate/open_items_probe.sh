#!/usr/bin/env bash
# tests/gate/open_items_probe.sh — the three observations T155 still lacks (research.md §Open items
# 3, 8 and 17), made on a standing lab that carries a service, as verification tooling under FR-108.
#
#   item 3   Is /acl/interface[interface-id]/interface-ref derived from the interface-id key? A
#            scratch binding is written WITHOUT interface-ref on a scratch subinterface; running
#            (config) and state are read back and what the device holds under interface-ref is
#            recorded. The platform always writes interface-ref (AD-68), so nothing depends on it.
#   item 8   Which forwarding-table augment a containerised node populates: one Get of
#            /platform/linecard/forwarding-complex/fib-table and one of
#            /platform/control/forwarding-plane/fib-table on a leaf carrying a service, recorded
#            (populated or empty, with the device's own answer).
#   item 17  Does the pinned release accept an untagged subinterface beside a tagged one on one port?
#            One scratch commit of both on a port no platform object uses, read back (config and
#            oper-state) and removed. The platform keeps refusing the mix (FR-034, AD-20) whatever
#            this records; a change to that is a recorded change, never this script's.
#
# Conventions (T043): the run starts with leftovers::scan and refuses on any leftover; every
# scratch name carries the vt-scratch- prefix (the port's and subinterfaces' descriptions, the filter);
# the scratch port must be absent from running before the probe, and the whole interface entry and
# every /acl object the probe wrote are deleted in one transaction and read back absent before it
# reports. Every device call goes through evidence_run (gate::dev). It RECORDS what it saw — neither
# answer fails it; only an unreadable device, a scratch port already in use, or a removal that does
# not read back does (exit 1).
#
# Output: $EVIDENCE_DIR/open-items/observations.json (attached to the closing record).
# Env: OI_LEAF (default: the first leaf), OI_PORT (default ethernet-1/10 — no link, no inventory),
#      OI_VLAN (default 3994), CLUSTER_NAME, LAB_NAME, EVIDENCE_DIR.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gate.sh
source "$HERE/lib/gate.sh"
# shellcheck source=../lib/leftovers.sh
source "$GATE_REPO_ROOT/tests/lib/leftovers.sh"

export GATE_ITEM=OI
gate::init || { log::error "open-items: evidence or device credentials unavailable"; exit 1; }
OI_LEAF="${OI_LEAF:-$(lab::leaves | head -1)}"
OI_PORT="${OI_PORT:-ethernet-1/10}"
OI_VLAN="${OI_VLAN:-3994}"
OI_FILTER="vt-scratch-oi3"
OUT="$EVIDENCE_DIR/open-items"; mkdir -p "$OUT"
IFC="/interface[name=${OI_PORT}]"
BIND="/acl/interface[interface-id=${OI_PORT}.${OI_VLAN}]"
FILT="/acl/acl-filter[name=${OI_FILTER}][type=ipv4]"
JQ="$(lab::jq_lib)"

# oi::get <id> <type> <path> — the values of one Get as JSON (null when absent or unreadable)
oi::get() {
  local out
  out="$(gate::dev "$1" "$OI_LEAF" get --type "$2" --path "$3" 2>/dev/null)" || { echo null; return 1; }
  jq -c "$JQ"' gvalues | if length == 0 then null else (.[0] | strip) end' <<<"$out" 2>/dev/null || echo null
}
# oi::set <id> <upd…> — one atomic Set; prints the device's answer on failure; returns its status
oi::set() {
  local id="$1"; shift
  local -a argv=() p
  for p in "$@"; do argv+=(--update "$p"); done
  gate::dev "$id" "$OI_LEAF" set --delimiter "$LAB_SET_DELIM" "${argv[@]}" >/dev/null 2>"$OUT/$id.err"
}
oi::err() { tr '\n' ' ' <"$OUT/$1.err" 2>/dev/null | cut -c1-600; }
oi::q() { jq -cn --arg v "$1" '$v'; }

removed=false
oi::remove() {
  [[ "$removed" == true ]] && return 0
  gate::dev OI.remove "$OI_LEAF" set --delete "$BIND" --delete "$FILT" --delete "$IFC" >/dev/null 2>&1 || true
  local b f i
  b="$(oi::get OI.gone.binding config "$BIND")"; f="$(oi::get OI.gone.filter config "$FILT")"
  i="$(oi::get OI.gone.port config "$IFC")"
  if [[ "$b" == null && "$f" == null && ( "$i" == null || "$i" == '{}' ) ]]; then
    removed=true; log::info "[OI] scratch removed from ${OI_LEAF} and read back absent"
    return 0
  fi
  log::error "[OI] scratch NOT removed from ${OI_LEAF}: binding=${b} filter=${f} port=${i}"
  return 1
}

# ------------------------------------------------------------------ 0. clean start
if ! leftovers::scan; then log::error "open-items: a leftover is present — refusing to start"; exit 1; fi
pre="$(oi::get OI.pre.port config "$IFC")"
if [[ "$pre" != null && "$pre" != '{}' ]]; then
  log::error "open-items: ${OI_LEAF} ${OI_PORT} already carries configuration — not a scratch port: ${pre}"
  exit 1
fi
trap 'oi::remove || true' EXIT

# ------------------------------------------------------------------ 17. untagged beside tagged
rc17=0
oi::set OI.i17.commit \
  "$(lab::upd "$IFC/admin-state" '"enable"')" \
  "$(lab::upd "$IFC/description" '"vt-scratch-oi17"')" \
  "$(lab::upd "$IFC/vlan-tagging" 'true')" \
  "$(lab::upd "$IFC/subinterface[index=0]/type" '"bridged"')" \
  "$(lab::upd "$IFC/subinterface[index=0]/description" '"vt-scratch-oi17-untagged"')" \
  "$(lab::upd "$IFC/subinterface[index=0]/vlan/encap/untagged" '{}')" \
  "$(lab::upd "$IFC/subinterface[index=${OI_VLAN}]/type" '"bridged"')" \
  "$(lab::upd "$IFC/subinterface[index=${OI_VLAN}]/description" '"vt-scratch-oi17-tagged"')" \
  "$(lab::upd "$IFC/subinterface[index=${OI_VLAN}]/vlan/encap/single-tagged/vlan-id" "$OI_VLAN")" || rc17=$?
cfg0=null; cfgT=null; st0=null; stT=null
if [[ "$rc17" -eq 0 ]]; then
  sleep 5
  cfg0="$(oi::get OI.i17.cfg.untagged config "$IFC/subinterface[index=0]/vlan")"
  cfgT="$(oi::get OI.i17.cfg.tagged config "$IFC/subinterface[index=${OI_VLAN}]/vlan")"
  st0="$(oi::get OI.i17.state.untagged state "$IFC/subinterface[index=0]/oper-state")"
  stT="$(oi::get OI.i17.state.tagged state "$IFC/subinterface[index=${OI_VLAN}]/oper-state")"
else
  # the mix refused: the tagged subinterface alone, so item 3 still has a subinterface to bind to
  oi::set OI.i17.tagged-only \
    "$(lab::upd "$IFC/admin-state" '"enable"')" \
    "$(lab::upd "$IFC/description" '"vt-scratch-oi17"')" \
    "$(lab::upd "$IFC/vlan-tagging" 'true')" \
    "$(lab::upd "$IFC/subinterface[index=${OI_VLAN}]/type" '"bridged"')" \
    "$(lab::upd "$IFC/subinterface[index=${OI_VLAN}]/description" '"vt-scratch-oi17-tagged"')" \
    "$(lab::upd "$IFC/subinterface[index=${OI_VLAN}]/vlan/encap/single-tagged/vlan-id" "$OI_VLAN")" || true
fi
item17="$(jq -cn --argjson rc "$rc17" --arg err "$(oi::err OI.i17.commit)" --arg node "$OI_LEAF" --arg port "$OI_PORT" \
  --argjson c0 "$cfg0" --argjson cT "$cfgT" --argjson s0 "$st0" --argjson sT "$stT" --arg vlan "$OI_VLAN" '{
  question: "Does the pinned release accept an untagged subinterface beside tagged ones on one port?",
  node: $node, port: $port, subinterfaces: ["\($port).0 untagged", "\($port).\($vlan) single-tagged \($vlan)"],
  commit_accepted: ($rc == 0), device_answer: (if $rc == 0 then null else $err end),
  readback: {untagged_config: $c0, tagged_config: $cT, untagged_oper_state: $s0, tagged_oper_state: $sT},
  answer: (if $rc != 0 then "refused by the device at commit"
           elif ($c0 != null and $cT != null) then "accepted: both subinterfaces committed and read back from running"
           else "accepted at commit, but not both read back" end)}')"

# ------------------------------------------------------------------ 3. binding without interface-ref
rc3=0
oi::set OI.i3.commit \
  "$(lab::upd "$FILT/description" '"vt-scratch-oi3"')" \
  "$(lab::upd "$FILT/entry[sequence-id=10]/action/accept" '{}')" \
  "$(lab::upd "$FILT/entry[sequence-id=10]/match/ipv4/protocol" '"icmp"')" \
  "$(lab::upd "$BIND/input/acl-filter[name=${OI_FILTER}][type=ipv4]" '{}')" || rc3=$?
b_cfg=null; b_state=null
if [[ "$rc3" -eq 0 ]]; then
  sleep 5
  b_cfg="$(oi::get OI.i3.cfg config "$BIND")"
  b_state="$(oi::get OI.i3.state state "$BIND")"
fi
item3="$(jq -cn --argjson rc "$rc3" --arg err "$(oi::err OI.i3.commit)" --arg node "$OI_LEAF" \
  --arg id "${OI_PORT}.${OI_VLAN}" --argjson c "$b_cfg" --argjson s "$b_state" '{
  question: "Is /acl/interface[interface-id]/interface-ref auto-derived from the interface-id key?",
  node: $node, interface_id: $id, written: "input acl-filter only — no interface-ref",
  commit_accepted: ($rc == 0), device_answer: (if $rc == 0 then null else $err end),
  running_config: $c, state: $s,
  interface_ref_in_running: (($c // {})["interface-ref"] // null),
  interface_ref_in_state: (($s // {})["interface-ref"] // null),
  answer: (if $rc != 0 then "a binding without interface-ref is refused at commit"
           elif (($c // {})["interface-ref"] // null) != null then "derived: running carries an interface-ref the probe did not write"
           elif (($s // {})["interface-ref"] // null) != null then "derived in state only: running carries none, state does"
           else "not derived: neither running nor state carries an interface-ref" end)}')"

# ------------------------------------------------------------------ remove, read back
rm_rc=0; oi::remove || rm_rc=$?
trap - EXIT

# ------------------------------------------------------------------ 8. fib-table augments
lc="$(oi::get OI.i8.linecard state "/platform/linecard/forwarding-complex/fib-table")" || true
cp="$(oi::get OI.i8.control state "/platform/control/forwarding-plane/fib-table")" || true
nis="$(lab::kubectl get networks.fabric.agentic-netops.io -A -o json 2>/dev/null \
  | jq -c --arg n "$OI_LEAF" '[.items[] | select(any(.spec.attachments[]?; .node == $n)) | "\(.metadata.namespace)/\(.metadata.name)"]' 2>/dev/null || echo '[]')"
pop() { jq -c 'if . == null or . == {} or . == [] then false else true end' <<<"$1"; }
item8="$(jq -cn --arg node "$OI_LEAF" --argjson svc "$nis" --argjson lc "$lc" --argjson cp "$cp" \
  --argjson lcp "$(pop "$lc")" --argjson cpp "$(pop "$cp")" '{
  question: "Which forwarding-table augment does a containerised node populate — linecard or control?",
  node: $node, services_on_node: $svc,
  linecard_forwarding_complex_fib_table: {populated: $lcp, value: $lc},
  control_forwarding_plane_fib_table: {populated: $cpp, value: $cp},
  answer: ([if $lcp then "linecard forwarding-complex fib-table populated" else "linecard forwarding-complex fib-table empty" end,
            if $cpp then "control forwarding-plane fib-table populated" else "control forwarding-plane fib-table empty" end] | join("; "))}')"

jq -n --argjson i3 "$item3" --argjson i8 "$item8" --argjson i17 "$item17" --argjson rm "$([[ $rm_rc -eq 0 ]] && echo true || echo false)" \
  --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{utc_time: $t, item3: $i3, item8: $i8, item17: $i17, scratch_removed_and_read_back: $rm}' >"$OUT/observations.json"
gate::run OI.record --attach "open-items/observations.json" -- jq -e '.scratch_removed_and_read_back' "$OUT/observations.json" >/dev/null
jq -r '"item 3: \(.item3.answer)\nitem 8: \(.item8.answer)\nitem 17: \(.item17.answer)"' "$OUT/observations.json"
evidence_seal OI.sealed || true
[[ "$rm_rc" -eq 0 ]]
