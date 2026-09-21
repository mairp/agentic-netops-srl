#!/usr/bin/env bash
# tests/gate/g09_acl.sh — G9: access-list programming with KEYED applied-side read-back in each
# direction, whether EGRESS filtering qualifies on this platform at all, and whether a binding entry
# carrying an interface-ref and NO filter is accepted (AD-68, research Open items 2, 3, 19)
# (T043; quickstart.md §1, §12; evidence/03 §5–§7).
#
# Runs on G8's scratch bridged subinterface ethernet-1/1.3990 of the first leaf. Every check is keyed
# by filter name, type, entry and direction (acl_applied in lib/checks.sh), so no stock filter can
# satisfy it — which negative_controls.sh negctl::G9 shows against the device's own stock filters.
#   1. the bare binding: /acl/interface[interface-id=ethernet-1/1.3990]/interface-ref with no filter
#      — accepted or refused is recorded; refused, the item fails (Open item 19: the gate stops and
#      the fallback is a recorded change)
#   2. ingress: an IPv4 and an IPv6 filter (statistics-per-entry, entries 10 and the reserved 65535)
#      bound input — TCAM on input only, per-subinterface entries listed, programming complete
#   3. egress: an IPv4 filter with subinterface-specific output-only bound output — its result is
#      the qualification PROPERTY egress-acl (published per property, refused by name when
#      unqualified; not an item failure)
#   4. removal, read back
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then exec bash "$GATE_HERE/run_gate.sh" --only G9 "$@"; fi
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"

G9_IN4="vt-scratch-g9-in4"; G9_IN6="vt-scratch-g9-in6"; G9_OUT4="vt-scratch-g9-out4"

g09::filter() { # <name> <type> <proto-leaf> <proto> [subinterface-specific]
  local b="/acl/acl-filter[name=$1][type=$2]"
  printf '%s\t%s\n' "$b/statistics-per-entry" true \
    "$b/description" "$(scratch::_q "vt-scratch-g9")" \
    "$b/entry[sequence-id=10]/match/$2/$3" "$4" \
    "$b/entry[sequence-id=10]/action/accept" '{}' \
    "$b/entry[sequence-id=65535]/action/accept" '{}'
  [[ -n "${5:-}" ]] && printf '%s\t%s\n' "$b/subinterface-specific" "$(scratch::_q "$5")"
  return 0
}
g09::ingress_updates() {
  local ifid="$1" b="/acl/interface[interface-id=$1]"
  g09::filter "$G9_IN4" ipv4 protocol 1
  g09::filter "$G9_IN6" ipv6 next-header 58
  printf '%s\t%s\n' \
    "$b/input/acl-filter[name=${G9_IN4}][type=ipv4]/name" "$(scratch::_q "$G9_IN4")" \
    "$b/input/acl-filter[name=${G9_IN6}][type=ipv6]/name" "$(scratch::_q "$G9_IN6")"
}
g09::egress_updates() {
  local b="/acl/interface[interface-id=$1]"
  g09::filter "$G9_OUT4" ipv4 protocol 1 output-only
  printf '%s\t%s\n' "$b/output/acl-filter[name=${G9_OUT4}][type=ipv4]/name" "$(scratch::_q "$G9_OUT4")"
}
g09::bare_updates() {
  local port="${1%.*}" idx="${1##*.}" b="/acl/interface[interface-id=$1]"
  printf '%s\t%s\n' "$b/interface-ref/interface" "$(scratch::_q "$port")" "$b/interface-ref/subinterface" "$idx"
}

g09::run() {
  gate::item_begin G9 "ACL programming, keyed applied-side read-back per direction, egress qualification"
  local leaf ifid rc
  leaf="$(lab::leaves | head -1)"
  ifid="${SCRATCH_ACCESS_PORT}.${SCRATCH_VLAN}"

  # 1. interface-ref and no filter
  rc=0; scratch::apply "$leaf" "G09.bare-binding" g09::bare_updates "$ifid" >/dev/null || rc=$?
  gate::item_check "binding-without-filter-accepted" "$rc" "a binding entry for $ifid carrying interface-ref and no filter is $( [[ $rc -eq 0 ]] && echo accepted || echo REFUSED )"
  gate::item_observe binding_without_filter_accepted "$( [[ $rc -eq 0 ]] && echo true || echo false )"
  if [[ "$rc" -eq 0 ]]; then
    rc=0; gate::ready "G09.bare-binding.readback" G9-bare-binding value_equals "$leaf" CONFIG "/acl/interface[interface-id=${ifid}]/interface-ref/interface" "\"${SCRATCH_ACCESS_PORT}\"" || rc=$?
    gate::item_check "binding-without-filter-readback" "$rc" "the bare binding's interface-ref reads back from running"
  fi

  # 2. ingress, IPv4 and IPv6, under that binding
  rc=0; scratch::apply "$leaf" "G09.ingress" g09::ingress_updates "$ifid" >/dev/null || rc=$?
  gate::item_check "ingress-committed" "$rc" "IPv4 + IPv6 filters bound input on $ifid (one transaction)"
  rc=0; CHECK_WAIT=60 gate::ready "G09.in4" G9-acl-applied acl_applied "$leaf" "$G9_IN4" ipv4 "$ifid" input 10,65535 || rc=$?
  gate::item_check "ingress-ipv4-applied" "$rc" "$G9_IN4/ipv4 in TCAM on input only, per-subinterface entries listed"
  rc=0; CHECK_WAIT=60 gate::ready "G09.in6" G9-acl-applied acl_applied "$leaf" "$G9_IN6" ipv6 "$ifid" input 10,65535 || rc=$?
  gate::item_check "ingress-ipv6-applied" "$rc" "$G9_IN6/ipv6 in TCAM on input only, per-subinterface entries listed"

  # 3. egress — a qualification property
  local erc=0 msg
  scratch::apply "$leaf" "G09.egress" g09::egress_updates "$ifid" >/dev/null || erc=$?
  if [[ "$erc" -ne 0 ]]; then
    msg="the device refused an output binding on $ifid (see the G09.egress evidence record)"
  else
    CHECK_WAIT=60 gate::ready "G09.out4" G9-acl-applied acl_applied "$leaf" "$G9_OUT4" ipv4 "$ifid" output 10,65535 || erc=$?
    msg="$G9_OUT4/ipv4 bound output: TCAM on output only, per-subinterface entries listed"
  fi
  gate::item_check "property:egress-acl" "$erc" "$msg"
  gate::item_observe egress_qualified "$( [[ $erc -eq 0 ]] && echo true || echo false )"

  # 4. removal, read back
  rc=0; gate::dev "G09.remove" "$leaf" set --delete "/acl/interface[interface-id=${ifid}]" \
    --delete "/acl/acl-filter[name=${G9_IN4}][type=ipv4]" --delete "/acl/acl-filter[name=${G9_IN6}][type=ipv6]" \
    --delete "/acl/acl-filter[name=${G9_OUT4}][type=ipv4]" >/dev/null || rc=$?
  gate::item_check "removed" "$rc" "the scratch filters and the binding removed"
  rc=0; gate::record "G09.removed.binding" G9-bare-binding absent "$leaf" CONFIG "/acl/interface[interface-id=${ifid}]" || rc=$?
  gate::item_check "removed-readback" "$rc" "the binding is gone from running"
  gate::item_end
}
