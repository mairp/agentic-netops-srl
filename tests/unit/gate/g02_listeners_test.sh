#!/usr/bin/env bash
# tests/unit/gate/g02_listeners_test.sh — G2's management-port observation with bind scope (T043;
# SC-029, R-34; live-findings 2026-09-24-loopback-listeners), offline: g02::parse_listeners and
# g02::observation are driven with a recorded `ss -Hltun` listing of the pinned image's srbase-mgmt
# namespace (addresses and ports as observed on 25.7.1), with no device and no gate plumbing.
#   1  every socket keeps its bind address and scope: 127.0.0.1 / ::1 → loopback; 0.0.0.0, ::, * →
#      any; anything else (incl. a `%iface`-scoped address) → specific
#   2  network_listeners = the non-loopback sockets over every device, by transport/port;
#      loopback_listeners = the loopback-only ones; 53/tcp, 53/udp, 199/tcp land in the latter
#   3  a port bound to loopback on one device and to any address on another is a network listener
#      (the exemption is per socket, never per port number)
#   4  a device whose listing was unavailable is named in listeners_unavailable
#   5  `listening` counts a service that is oper-up although its admin-state was not in the state read
#   negative control: the same listing with 199 bound to 0.0.0.0 moves 199 into network_listeners
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
ok()  { printf 'PASS %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 12 | sed 's/^/    /'; }

# shellcheck disable=SC2034
__AGENTIC_NETOPS_TESTS_GATE_SH=1   # the gate plumbing is not needed by the two pure functions
# shellcheck source=../../gate/g02_version_platform.sh
source "$ROOT/tests/gate/g02_version_platform.sh"

SS='udp UNCONN 0      0      127.0.0.1:53    0.0.0.0:*
udp UNCONN 0      0        0.0.0.0:161   0.0.0.0:*
udp UNCONN 0      0          [::1]:53       [::]:*
udp UNCONN 0      0           [::]:161      [::]:*
tcp LISTEN 0      128      0.0.0.0:830   0.0.0.0:*
tcp LISTEN 0      128      0.0.0.0:22    0.0.0.0:*
tcp LISTEN 0      4096   127.0.0.1:199   0.0.0.0:*
tcp LISTEN 0      32     127.0.0.1:53    0.0.0.0:*
tcp LISTEN 0      128         [::]:830      [::]:*
tcp LISTEN 0      2048           *:443         *:*
tcp LISTEN 0      2048           *:80          *:*
tcp LISTEN 0      128         [::]:22       [::]:*
tcp LISTEN 0      4096           *:57400       *:*
tcp LISTEN 0      4096           *:57401       *:*
tcp LISTEN 0      32         [::1]:53       [::]:*
tcp LISTEN 0      4096           *:50052       *:*'

p="$(g02::parse_listeners <<<"$SS")"
[[ "$(jq length <<<"$p")" -eq 16 ]] && ok "16 sockets parsed with their addresses" || bad "socket count" "$p"
jq -e 'map(select(.port == 53 or .port == 199)) | all(.scope == "loopback")' <<<"$p" >/dev/null \
  && ok "53 (dnsmasq) and 199 (SMUX) bound to 127.0.0.1 / ::1 are loopback" || bad "loopback scope" "$p"
jq -e 'map(select(.port == 80 or .port == 161 or .port == 22)) | all(.scope == "any")' <<<"$p" >/dev/null \
  && ok "*, 0.0.0.0 and :: are any" || bad "any scope" "$p"
q="$(printf 'tcp LISTEN 0 1 10.1.2.3%%mgmt0:8080 0.0.0.0:*\ntcp LISTEN 0 1 [fe80::1%%mgmt0]:9090 [::]:*\ntcp LISTEN 0 1 [::ffff:127.0.0.1]:7000 [::]:*\n' | g02::parse_listeners)"
jq -e '(.[] | select(.port == 8080) | .address == "10.1.2.3" and .scope == "specific")
       and (.[] | select(.port == 9090) | .address == "fe80::1" and .scope == "specific")
       and (.[] | select(.port == 7000) | .scope == "loopback")' <<<"$q" >/dev/null \
  && ok "an interface-scoped or mapped address keeps its scope (specific / loopback)" || bad "specific scope" "$q"

svc='[{"service":"ssh","port":22,"transport":"tcp","admin_state":"unknown","oper_state":"up"},{"service":"netconf","port":null,"transport":"tcp","admin_state":"unknown","oper_state":"up"},{"service":"grpc","port":57400,"transport":"tcp","admin_state":"unknown","oper_state":"down"}]'
nodes="$(jq -n --argjson l "$p" --argjson s "$svc" '{leaf01: {role: "leaf", services: $s, mgmt_namespace_listeners: $l},
  spine01: {role: "spine", services: $s, mgmt_namespace_listeners: $l}, leaf02: {role: "leaf", services: [], mgmt_namespace_listeners: "unavailable"}}')"
o="$(g02::observation 25.7.1 "$nodes")"
nl="$(jq -c '[.network_listeners[] | "\(.transport)/\(.port)"]' <<<"$o")"
[[ "$nl" == '["tcp/22","tcp/80","tcp/443","tcp/830","tcp/50052","tcp/57400","tcp/57401","udp/161"]' ]] \
  && ok "network_listeners: the non-loopback sockets by transport/port ($nl)" || bad "network_listeners" "$nl"
ll="$(jq -c '[.loopback_listeners[] | "\(.transport)/\(.port)"]' <<<"$o")"
[[ "$ll" == '["tcp/53","tcp/199","udp/53"]' ]] && ok "loopback_listeners: 53/tcp, 199/tcp, 53/udp" || bad "loopback_listeners" "$ll"
[[ "$(jq -c .listeners_unavailable <<<"$o")" == '["leaf02"]' ]] && ok "a device whose listing was unavailable is named" || bad "listeners_unavailable" "$o"
[[ "$(jq -c '[.listening[] | "\(.transport)/\(.port)"]' <<<"$o")" == '["tcp/22"]' ]] \
  && ok "listening: an oper-up service counts although admin-state was not in the state read (and a down one does not)" || bad "listening" "$(jq -c .listening <<<"$o")"
jq -e '.nodes.leaf01.mgmt_namespace_listeners[0] | has("address") and has("scope")' <<<"$o" >/dev/null && ok "the per-node listing keeps address and scope" || bad "per-node listing"
# 3: loopback on one device, any on another → a network listener
p2="$(sed 's/127.0.0.1:199/0.0.0.0:199/' <<<"$SS" | g02::parse_listeners)"
o2="$(g02::observation 25.7.1 "$(jq -n --argjson a "$p" --argjson b "$p2" '{leaf01: {services: [], mgmt_namespace_listeners: $a}, leaf02: {services: [], mgmt_namespace_listeners: $b}}')")"
jq -e 'any(.network_listeners[]; .port == 199) and any(.loopback_listeners[]; .port == 199)' <<<"$o2" >/dev/null \
  && ok "negative control: 199 bound to 0.0.0.0 on one device is a network listener (the exemption is per socket)" || bad "per-socket exemption" "$o2"
jq -e '(.network_listeners | length) > 0 and .schema == "agentic-netops.gate.mgmt-ports/v1"' "$ROOT/tests/gate/observed/mgmt-ports.json" >/dev/null \
  && ok "the committed observation carries network_listeners (written by the bind-scope G2)" || bad "committed observation predates bind scope"

echo "g02_listeners_test: $fails failure(s)"
[[ "$fails" -eq 0 ]]
