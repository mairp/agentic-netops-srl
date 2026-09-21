#!/usr/bin/env bash
# tests/gate/g06_mtu.sh — G6: the MTU envelope — port MTU 9412, routed ip-mtu 9398, tenant IP MTU
# 9348 — with the device's own refusal one byte above the PLATFORM limits, and the tenant boundary
# proven on the data plane: ICMP payload 9320 (IPv4) and 9300 (IPv6) pass, one byte more fails
# (T043, T187; CR-009; AD-78; quickstart.md §1, §12 "The MTU boundary probe"; evidence/01 §8).
#
# Runs while G8's scratch fabric is in place (run_gate.sh orders it): the fabric ports carry
# mtu 9412 / ip-mtu 9398 and the scratch anycast gateway irb0.3990 ip-mtu 9348, with the clients on
# the scratch VLAN at the tenant MTU (as quickstart §12 prescribes). One byte above:
#   port mtu 9413 (the platform maximum) and routed ip-mtu 9399 — the device must reject the commit
#     (restored if it does not); negative control negctl::G6_mid feeds the VALID value, which the
#     refusal check must report as accepted (fail);
#   tenant 9349 on the IRB — NOT a commit-time assertion (AD-78): the tenant value is arithmetic,
#     the device accepts it and keeps the IRB up (observed on 25.7.1). What the device does is
#     RECORDED (observation tenant_ip_mtu_9349_commit), the tenant MTU written back; the tenant
#     boundary is the data-plane probe below, whose 9320/9300 passes and 9321/9301 failures are
#     the assertion.
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then exec bash "$GATE_HERE/run_gate.sh" --only G6 "$@"; fi
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"

g06::run() {
  gate::item_begin G6 "MTU envelope 9412/9398/9348, port/routed refusal one byte above, tenant payload boundary 9320/9300"
  local leaf rc out port irb c1 c2 dst4 dst6
  leaf="$(lab::leaves | head -1)"
  port="ethernet-1/$((48 + 1))"
  irb="/interface[name=irb0]/subinterface[index=${SCRATCH_VLAN}]"
  out="$(gate::dev "G06.system-mtu" "$leaf" get --type state --path /system/mtu 2>/dev/null)" || out="[]"
  gate::item_observe system_mtu "$(jq -c "$(lab::jq_lib)"' gvalues | .[0] // null | if . == null then null else (strip | unwrap("mtu")) end' <<<"$out" 2>/dev/null || echo null)"

  rc=0; gate::ready "G06.port-mtu" G6-mtu value_equals "$leaf" CONFIG "/interface[name=${port}]/mtu" 9412 || rc=$?
  gate::item_check "port-mtu-9412" "$rc" "port mtu 9412 committed on $leaf $port"
  rc=0; gate::ready "G06.ip-mtu" G6-mtu value_equals "$leaf" CONFIG "/interface[name=${port}]/subinterface[index=0]/ip-mtu" 9398 || rc=$?
  gate::item_check "ip-mtu-9398" "$rc" "routed ip-mtu 9398 committed on $leaf ${port}.0"
  rc=0; gate::ready "G06.tenant-mtu" G6-mtu value_equals "$leaf" CONFIG "${irb}/ip-mtu" 9348 || rc=$?
  gate::item_check "tenant-mtu-9348" "$rc" "tenant IP MTU 9348 committed on $leaf irb0.${SCRATCH_VLAN}"
  rc=0; CHECK_WAIT=30 gate::ready "G06.tenant-irb-up" G6-irb-up value_equals "$leaf" STATE "${irb}/oper-state" '"up"' || rc=$?
  gate::item_check "tenant-irb-up-at-9348" "$rc" "the IRB is operationally up at ip-mtu 9348"

  # the negative controls of the port and routed refusal checks, on this same scratch fabric: the VALID value
  # must make each check fail (accepted, not refused) — negative_controls.sh negctl::G6_mid
  negctl::G6_mid "$leaf" "$port"
  rc=0; gate::ready "G06.reject-port" G6-reject set_rejected "$leaf" "/interface[name=${port}]/mtu" 9413 9412 || rc=$?
  gate::item_check "port-mtu-9413-rejected" "$rc" "port mtu 9413 refused by the device"
  rc=0; gate::ready "G06.reject-ip" G6-reject set_rejected "$leaf" "/interface[name=${port}]/subinterface[index=0]/ip-mtu" 9399 9398 || rc=$?
  gate::item_check "ip-mtu-9399-rejected" "$rc" "routed ip-mtu 9399 refused by the device"
  # tenant 9349 at commit: an OBSERVATION (AD-78) — recorded, never a pass criterion; the only
  # failure is a tenant MTU that could not be written back (a leftover)
  local pid obs
  pid="$(gate::id "G06.tenant-9349-commit")"
  rc=0; evidence_run "$pid" -- bash "$GATE_CHECKS" mtu_commit_probe "$leaf" "$irb" 9349 9348 >/dev/null 2>&1 || rc=$?
  gate::item_check "tenant-9349-probe-restored" "$rc" "irb ip-mtu 9349 tried at commit and the tenant MTU 9348 back in place (the response is an observation)" "$pid"
  obs="$(sed -n 's/^OBSERVATION //p' "$EVIDENCE_DIR/${pid}.stdout" 2>/dev/null | tail -1)"
  gate::item_observe tenant_ip_mtu_9349_commit "$(jq -c . <<<"${obs:-null}" 2>/dev/null || echo null)"

  # payload boundary client01 → client02 across the scratch mac-vrf (the L2 VXLAN path)
  local c1 c2
  c1="$(lab::clients | sed -n 1p)"; c2="$(lab::clients | sed -n 2p)"
  dst4="$(scratch::client_addr4 "$c2")"; dst6="$(scratch::client_addr6 "$c2")"
  out="$(gate::run "G06.client-mtu.${c1}" -- lab::docker exec "$(lab::container "$c1")" ip -o link show 2>/dev/null)" || out=""
  gate::item_observe client_links "$(grep -E 'eth1|vt-scratch' <<<"$out" | sed -E 's/.*: ([^:]+): .* mtu ([0-9]+).*/\1 mtu \2/' | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  rc=0; CHECK_WAIT=30 gate::ready "G06.payload-v4" G6-payload ping "$c1" 4 "$dst4" 9320 ok || rc=$?
  gate::item_check "payload-ipv4-9320-passes" "$rc" "ping -M do -s 9320 $c1 → $dst4 passes"
  rc=0; gate::record "G06.payload-v4-over" G6-payload ping "$c1" 4 "$dst4" 9321 fail || rc=$?
  gate::item_check "payload-ipv4-9321-fails" "$rc" "ping -M do -s 9321 fails"
  rc=0; CHECK_WAIT=30 gate::ready "G06.payload-v6" G6-payload ping "$c1" 6 "$dst6" 9300 ok || rc=$?
  gate::item_check "payload-ipv6-9300-passes" "$rc" "ping -6 -M do -s 9300 $c1 → $dst6 passes"
  rc=0; gate::record "G06.payload-v6-over" G6-payload ping "$c1" 6 "$dst6" 9301 fail || rc=$?
  gate::item_check "payload-ipv6-9301-fails" "$rc" "ping -6 -M do -s 9301 fails"
  gate::item_end
}
