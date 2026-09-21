#!/usr/bin/env bash
# client_setup_test.sh — lab/clients/setup.sh with a fake `ip` (T032; FR-002, RD-10, R-11).
#
# Asserts: eth1 and every VLAN subinterface eth1.<vlan> get MTU 9348; VLANs come from arguments or
# CLIENT_VLANS; addresses are assigned per subinterface (IPv4 and IPv6); a re-run creates nothing
# twice and adds no address twice; malformed entries are refused; POSIX sh (runs under `sh`).
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; sed 's/^/    | /' "$T/calls" 2>/dev/null | tail -n 12; fi; }

cat >"$T/ip" <<'EOF'
#!/bin/sh
echo "ip $*" >>"$FAKE_DIR/calls"
case "$1 $2" in
  "link show") [ -e "$FAKE_DIR/links/$4" ] ;;
  "link add") touch "$FAKE_DIR/links/$6" ;;
  "addr show") [ -e "$FAKE_DIR/addrs/$4" ] && sed 's/^/    inet /; s/$/ scope global/' "$FAKE_DIR/addrs/$4"; exit 0 ;;
  "addr add") echo "$3" >>"$FAKE_DIR/addrs/$5" ;;
  "-6 addr") echo "$4" >>"$FAKE_DIR/addrs/$6" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T/ip"
reset() { rm -rf "$T/links" "$T/addrs"; mkdir -p "$T/links" "$T/addrs"; touch "$T/links/eth1"; : >"$T/calls"; }
run() { set +e; FAKE_DIR="$T" IP="$T/ip" sh "$ROOT/lab/clients/setup.sh" "$@" >"$T/out" 2>&1; rc=$?; set -e; }

reset
run
check "no VLANs: exits 0" '[[ $rc -eq 0 ]]'
check "no VLANs: eth1 gets MTU 9348 and is brought up" 'grep -qx "ip link set dev eth1 mtu 9348" "$T/calls" && grep -qx "ip link set dev eth1 up" "$T/calls"'

reset
run 1001 1002=10.10.2.11/24,fd00:2::11/64
check "args: exits 0" '[[ $rc -eq 0 ]]'
check "args: eth1.1001 and eth1.1002 created as VLAN subinterfaces of eth1" \
  'grep -qx "ip link add link eth1 name eth1.1001 type vlan id 1001" "$T/calls" && grep -qx "ip link add link eth1 name eth1.1002 type vlan id 1002" "$T/calls"'
check "args: every subinterface gets MTU 9348" \
  'grep -qx "ip link set dev eth1.1001 mtu 9348" "$T/calls" && grep -qx "ip link set dev eth1.1002 mtu 9348" "$T/calls"'
check "args: eth1 itself gets MTU 9348" 'grep -qx "ip link set dev eth1 mtu 9348" "$T/calls"'
check "args: IPv4 and IPv6 addresses assigned to the subinterface" \
  'grep -qx "ip addr add 10.10.2.11/24 dev eth1.1002" "$T/calls" && grep -qx "ip -6 addr add fd00:2::11/64 dev eth1.1002" "$T/calls"'
check "no MTU other than 9348 is ever set" '! grep "mtu" "$T/calls" | grep -qv "mtu 9348$"'

: >"$T/calls"
run 1001 1002=10.10.2.11/24,fd00:2::11/64
check "re-run: exits 0" '[[ $rc -eq 0 ]]'
check "re-run: nothing created twice" '! grep -q "link add" "$T/calls"'
check "re-run: no address added twice" '! grep -q "addr add" "$T/calls"'
check "re-run: the MTU is re-asserted" 'grep -qx "ip link set dev eth1.1002 mtu 9348" "$T/calls"'

reset
set +e; FAKE_DIR="$T" IP="$T/ip" CLIENT_VLANS="1100 1200=10.12.0.5/24" sh "$ROOT/lab/clients/setup.sh" >"$T/out" 2>&1; rc=$?; set -e
check "env: CLIENT_VLANS is honoured" '[[ $rc -eq 0 ]] && grep -q "name eth1.1100 type vlan id 1100" "$T/calls" && grep -qx "ip addr add 10.12.0.5/24 dev eth1.1200" "$T/calls"'

reset
set +e; FAKE_DIR="$T" IP="$T/ip" CLIENT_VLANS="none" sh "$ROOT/lab/clients/setup.sh" >"$T/out" 2>&1; rc=$?; set -e
check "env: CLIENT_VLANS=none (the topology default) means no VLAN" '[[ $rc -eq 0 ]] && ! grep -q "link add" "$T/calls" && grep -qx "ip link set dev eth1 mtu 9348" "$T/calls"'

for badv in 0 4095 abc 12x; do
  reset; run "$badv"
  check "refuse: VLAN entry '$badv'" '[[ $rc -ne 0 ]]'
done
reset; rm -f "$T/links/eth1"; run 1001
check "refuse: no eth1 (access link not wired)" '[[ $rc -ne 0 ]] && grep -q "eth1 does not exist" "$T/out"'

if command -v shellcheck >/dev/null 2>&1; then
  check "posix: shellcheck -s sh clean" 'shellcheck -s sh "$ROOT/lab/clients/setup.sh"'
fi

printf '\nclient_setup_test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
