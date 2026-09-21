#!/bin/sh
# setup.sh — Linux endpoint setup, exec'd by containerlab inside client01/client02
# (T032; FR-002, RD-10, R-11, evidence/01 §8.2 and §9.4).
#
# One access link (eth1) per endpoint; the endpoint joins several services at once through VLAN
# subinterfaces eth1.<vlan> on that single link. Every interface this script touches — eth1 and
# every subinterface — is set to MTU 9348, the tenant IP MTU: containerlab's 9500 veth default makes
# ping pass while TCP blackholes (the overlay drops the oversize frame and no ICMP "frag needed"
# comes back), which is the failure a ping-only test never sees.
#
# Usage: sh /setup.sh [<vlan>[=<addr>[,<addr>…]] …]
#   With no arguments the entries are read from CLIENT_VLANS (space separated; the topology
#   passes CLIENT01_VLANS / CLIENT02_VLANS through; `none` — the topology default — means no VLAN). An entry is a VLAN id 1–4094,
#   optionally followed by `=` and one or more comma-separated IPv4/IPv6 addresses with prefix
#   (e.g. 1001=10.10.1.11/24,fd00:1::11/64) assigned to eth1.<vlan>.
#   Idempotent: re-running converges (existing subinterfaces are kept, the MTU re-asserted,
#   addresses already present are left alone). Nothing is ever deleted.
#
# Environment: CLIENT_IFACE (default eth1), CLIENT_MTU (default 9348), IP (the ip binary; tests).
# POSIX sh on purpose: the endpoint image is a minimal Alpine with busybox, no bash.
set -eu

IFACE="${CLIENT_IFACE:-eth1}"
MTU="${CLIENT_MTU:-9348}"
IP="${IP:-ip}"

log() { printf 'client-setup: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

case "$MTU" in ''|*[!0-9]*) die "CLIENT_MTU must be a number, got '$MTU'" ;; esac

"$IP" link show dev "$IFACE" >/dev/null 2>&1 || die "interface $IFACE does not exist (is the access link wired?)"
"$IP" link set dev "$IFACE" mtu "$MTU"
"$IP" link set dev "$IFACE" up
log "$IFACE mtu $MTU up"

# "none" is the topology's default: containerlab's envsubst leaves an EMPTY default unexpanded.
if [ "$#" -eq 0 ] && [ -n "${CLIENT_VLANS:-}" ] && [ "${CLIENT_VLANS}" != none ]; then
  # shellcheck disable=SC2086 # word splitting of the list is the point
  set -- $CLIENT_VLANS
fi

for entry in "$@"; do
  vlan="${entry%%=*}"
  addrs=""
  case "$entry" in *=*) addrs="${entry#*=}" ;; esac
  case "$vlan" in ''|*[!0-9]*) die "VLAN id must be a number, got '$vlan'" ;; esac
  if [ "$vlan" -lt 1 ] || [ "$vlan" -gt 4094 ]; then die "VLAN id $vlan outside 1–4094"; fi
  sub="$IFACE.$vlan"
  if ! "$IP" link show dev "$sub" >/dev/null 2>&1; then
    "$IP" link add link "$IFACE" name "$sub" type vlan id "$vlan"
    log "created $sub"
  fi
  "$IP" link set dev "$sub" mtu "$MTU"
  "$IP" link set dev "$sub" up
  log "$sub mtu $MTU up"
  old_ifs="$IFS"; IFS=','
  for a in $addrs; do
    IFS="$old_ifs"
    [ -n "$a" ] || continue
    if "$IP" addr show dev "$sub" 2>/dev/null | grep -q " ${a} "; then
      continue
    fi
    case "$a" in
      *:*) "$IP" -6 addr add "$a" dev "$sub" ;;
      *)   "$IP" addr add "$a" dev "$sub" ;;
    esac
    log "$sub address $a"
  done
  IFS="$old_ifs"
done
