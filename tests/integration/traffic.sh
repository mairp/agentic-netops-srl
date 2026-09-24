#!/usr/bin/env bash
# tests/integration/traffic.sh — the traffic suite (T065; SC-005, CR-009, R-35, NFR-013, FR-108;
# quickstart.md §12 and its G6 payload boundary).
#
# Over the four hand-written construct Networks (examples/constructs/, ns agentic-netops-services)
# and the two Linux endpoints (client01 behind leaf01, client02 behind leaf02, one access link eth1,
# VLAN subinterfaces eth1.<vlan> at the tenant IP MTU 9348 — lab/clients/setup.sh):
#
#   L2          cross-leaf over lab-macvrf (VLAN 120): client01 <-> client02, IPv4 and IPv6, same subnet
#   L3          intra-ip-vrf over lab-ipvrf-a (VLAN 130): 10.130.1.0/24 (leaf01) <-> 10.130.2.0/24
#               (leaf02) through each leaf's gateway (.1), IPv4 and IPv6; and the same inside
#               lab-ipvrf-b (VLAN 140), the positive half of the isolation check
#   isolation   lab-ipvrf-a -> lab-ipvrf-b: a host route on client01 sends the other instance's
#               address into lab-ipvrf-a's gateway; it MUST NOT be answered (distinct L3VNIs / RTs)
#   MTU         ICMP payload 9320 (IPv4) and 9300 (IPv6) with DF set pass, on the L2 and the L3
#               path; one byte more fails (DF: never fragmented, locally or on the way)
#   counters    each passing probe moves the keyed subinterface counters of THIS service on both
#               leaves (ingress leaf in-packets, egress leaf out-packets) by at least the number of
#               probes sent — movement only, NEVER a rate
#
# `traffic.sh gateway` is the anycast-gateway reachability case of User Story 8 (T118; FR-032,
# acceptance scenario 1 "the gateway is reachable from the attached ports"), run on its own over
# the mac-vrf with an anycast gateway (examples/constructs/macvrf-gateway.yaml, lab-macvrf-gateway,
# VLAN 160, gateway 10.160.0.1/24 + 2001:db8:160::1/64): on both leaves the bridged AND the routed
# instance (macvrf-/ipvrf-lab-macvrf-gateway) oper-state up; from EACH attached port (client01 on
# leaf01, client02 on leaf02) the gateway answers in each declared family — every leaf answers
# locally, the gateway is distributed — and both clients resolve it to the ONE anycast MAC the
# fabric-constant virtual-router-id derives (00:00:5e:00:01:01, vrid 1); and the bridged half still
# carries client01 <-> client02 across the fabric. Its negative controls, recorded failing first:
#   TR-gw-reach   the gateway answers    (a) a gateway address on lab-vlan's VLAN 110, a service with
#                                        no gateway  (b) on VLAN 199, no service at all
#   TR-gw-mac     the anycast MAC        the same two (no neighbour entry resolves)
#   TR-instance   instance oper-state up (a) spine01 (stock)  (b) an instance that does not exist
#   TR-reach, TR-counters  as for the main run, for the bridged half's cross-leaf flow
#
# Order (NFR-013, SC-040): leftovers::scan first (the suite writes client-side scratch links), the
# Networks' Ready=True read as a precondition, then EVERY check's negative control — against a
# stock node and against a service that does not exist — recorded failing through
# evidence_negative_control before any pass of that check is run (evidence_run --readiness):
#   TR-instance   instance oper-state up         (a) spine01 (stock)  (b) an instance that does not exist
#   TR-reach      reachability                   (a) VLAN 110 to leaf02, which carries no service for it
#                                                (lab-vlan is leaf01-only)  (b) VLAN 199, no service at all
#   TR-mtu        the boundary payload passes    the same two, at the boundary payload
#   TR-isolated   a pair must NOT be reachable   an intra-instance pair (which is reachable)
#   TR-mtu-over   one byte more fails            the boundary payload (which passes)
#   TR-counters   keyed counters moved           (a) spine01 (stock)  (b) a subinterface no service owns
# then RUNS (3) consecutive runs; the suite passes only if every run is clean.
#
# Client-side changes are verification tooling under tests/ only (FR-108): the service
# subinterfaces are brought up by the endpoint's own /setup.sh (idempotent); addresses and routes
# this run adds are removed by the exit trap; the negative-control links are named
# vt-scratch-<vlan> (findable by leftovers::scan) and removed with the removal read back. Probes run
# in the client's network namespace with the host's iputils ping (`-M do`: DF set) — busybox ping,
# the only one in the endpoint image, cannot set DF. No Network, Fabric or Config is written.
#
# Usage: traffic.sh [run|once|negative-controls|gateway]      (default: run)
#        traffic.sh _instance_up <node> <instance>…                       (the checks, run-captured)
#        traffic.sh _reach|_unreach <client> <4|6> <dst> <payload>
#        traffic.sh _gwmac <client> <vlan> <gateway address> <mac>
#        traffic.sh _counters <node> <iface> <index>
#        traffic.sh _moved <in-node> <out-node> <iface> <index> <in-before> <out-before> <min>
# Environment: EVIDENCE_DIR, CLUSTER_NAME, LAB_NAME, SRL_USER, SRL_PASS, RUNS (3), TR_COUNT (3 probes),
#   TR_WAIT (60 s: the window a passing probe is retried in), TR_GW_NETWORK (lab-macvrf-gateway),
#   TR_GW_VLAN (160), TR_GW4 / TR_GW6 (10.160.0.1 / 2001:db8:160::1), TR_GW_MAC (00:00:5e:00:01:01), TR_NEG_WAIT (10 s: the same window
#   for a negative control, recorded in its argv), TR_SERVICES_NS (agentic-netops-services),
#   DOCKER / KUBECTL / GNMIC / NSENTER / PING overrides (tests put fakes on PATH).
# Exit: 0 every run clean; 1 a check failed (named); 2 usage; 3 refused (leftovers, precondition,
#   a negative control that passed).
set -euo pipefail

TR_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TR_ROOT="$(cd -- "$TR_HERE/../.." && pwd)"
TR_SELF="$TR_HERE/$(basename -- "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/lab.sh
source "$TR_ROOT/tests/lib/lab.sh"
# shellcheck source=../../scripts/lib/log.sh
source "$TR_ROOT/scripts/lib/log.sh"
# shellcheck source=../../scripts/lib/evidence.sh
source "$TR_ROOT/scripts/lib/evidence.sh"
LOG_PHASE="${LOG_PHASE:-traffic}"

: "${RUNS:=3}" "${TR_COUNT:=3}" "${TR_WAIT:=60}" "${TR_NEG_WAIT:=10}" "${TR_SERVICES_NS:=agentic-netops-services}"
: "${TR_COUNTER_WAIT:=20}" "${TR_COUNTER_INTERVAL:=2}"   # bounded re-read of lagging counters (tr::moved)
TR_MTU=9348          # the tenant IP MTU every endpoint interface carries (lab/clients/setup.sh)
TR_PAYLOAD4=9320     # 9320 + 8 ICMP + 20 IPv4 = 9348
TR_PAYLOAD6=9300     # 9300 + 8 ICMP + 40 IPv6 = 9348
TR_NETWORKS="lab-macvrf lab-ipvrf-a lab-ipvrf-b"
TR_STOCK_NODE="spine01"
TR_ABSENT_INSTANCE="macvrf-does-not-exist"
TR_PORT="ethernet-1/1"   # both clients' access port (lab/topology.clab.yml)
TR_FAILS=()
# the anycast-gateway case (`traffic.sh gateway`, T118)
: "${TR_GW_NETWORK:=lab-macvrf-gateway}" "${TR_GW_VLAN:=160}" "${TR_GW4:=10.160.0.1}" "${TR_GW6:=2001:db8:160::1}"
: "${TR_GW_MAC:=00:00:5e:00:01:01}"   # 00:00:5e:00:01:<vrid>: the fabric-constant virtual-router-id 1

# The plan: <vlan> <client01 addrs> <client02 addrs>; the gateways are .1 / ::1 of each leaf's prefix
# (examples/constructs/README.md). The macvrf is one L2 segment, so both clients share its subnet.
tr::addrs() {   # <client> <vlan>: the client's addresses on eth1.<vlan>
  case "$1:$2" in
    client01:120) echo "10.120.0.11/24,2001:db8:120::11/64" ;;
    client02:120) echo "10.120.0.12/24,2001:db8:120::12/64" ;;
    client01:130) echo "10.130.1.10/24,2001:db8:130:1::10/64" ;;
    client02:130) echo "10.130.2.10/24,2001:db8:130:2::10/64" ;;
    client01:140) echo "10.140.1.10/24,2001:db8:140:1::10/64" ;;
    client02:140) echo "10.140.2.10/24,2001:db8:140:2::10/64" ;;
    client01:"$TR_GW_VLAN") echo "10.${TR_GW_VLAN}.0.11/24,2001:db8:${TR_GW_VLAN}::11/64" ;;
    client02:"$TR_GW_VLAN") echo "10.${TR_GW_VLAN}.0.12/24,2001:db8:${TR_GW_VLAN}::12/64" ;;
  esac
}
# routes <client> <vlan>: "<prefix> <gateway>" per family
tr::routes() {
  case "$1:$2" in
    client01:130) echo "10.130.2.0/24 10.130.1.1"; echo "2001:db8:130:2::/64 2001:db8:130:1::1" ;;
    client02:130) echo "10.130.1.0/24 10.130.2.1"; echo "2001:db8:130:1::/64 2001:db8:130:2::1" ;;
    client01:140) echo "10.140.2.0/24 10.140.1.1"; echo "2001:db8:140:2::/64 2001:db8:140:1::1" ;;
    client02:140) echo "10.140.1.0/24 10.140.2.1"; echo "2001:db8:140:1::/64 2001:db8:140:2::1" ;;
  esac
}
# the negative-control segments: scratch links, never a service's
TR_SCRATCH_STOCK_VLAN=110    # lab-vlan's VLAN: on leaf01 only, so leaf02 is a stock node for it
TR_SCRATCH_ABSENT_VLAN=199   # naming band, no service anywhere
TR_UNDO=()                   # commands the exit trap runs, newest first

usage() { sed -n '/^# Usage:/,/^set -euo/p' "$TR_SELF" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }
tr::fail() { TR_FAILS+=("$1"); log::error "FAIL $1"; }
tr::ok()   { log::info "PASS $1"; }
tr::id() {
  local stem="$1" id n=1
  id="$stem"
  while [[ -e "$EVIDENCE_DIR/$id.json" ]]; do n=$((n + 1)); id="${stem}-${n}"; done
  printf '%s' "$id"
}

# ---------------------------------------------------------------- the checks (run-captured)

tr::gnmic_state() {   # <node> <path>: the values of a state get, as JSON; absent -> exit 1
  local out
  lab::export_creds || return 1
  lab::gnmic_argv "$1" || return 1
  out="$("${LAB_ARGV[@]}" get --type state --path "$2")" || return 1
  jq -ce "$(lab::jq_lib)"' gvalues | if length == 0 then error("absent") else .[0] | strip end' <<<"$out" 2>/dev/null \
    || { echo "absent: $1 $2" >&2; return 1; }
}

tr::instance_up() {   # <node> <instance>…: every named instance oper-state up
  local node="$1" ni v rc=0; shift
  for ni in "$@"; do
    v="$(tr::gnmic_state "$node" "/network-instance[name=${ni}]/oper-state")" || { rc=1; continue; }
    v="$(jq -r 'if type == "object" then (.["oper-state"] // .[]) else . end' <<<"$v")"
    echo "$node network-instance $ni oper-state: $v"
    [[ "$v" == up ]] || rc=1
  done
  return "$rc"
}

tr::counters() {   # prints "<in-packets> <out-packets>"
  local v
  v="$(tr::gnmic_state "$1" "/interface[name=$2]/subinterface[index=$3]/statistics")" || return 1
  jq -er "$(lab::jq_lib)"' unwrap("statistics") | "\(.["in-packets"] | num) \(.["out-packets"] | num)"' <<<"$v"
}

# The device refreshes subinterface statistics with a lag: observed live (phase 4 pass 3), a flow's
# packets appear in the NEXT flow's read. So the counters are re-read every TR_COUNTER_INTERVAL
# seconds for at most TR_COUNTER_WAIT until both have moved by <min>; the threshold is unchanged and
# a counter that never moves within the bound still fails — movement, never a rate.
tr::moved() {   # <ingress node> <egress node> <iface> <index> <in-packets before> <out-packets before> <min>
  local n1="$1" n2="$2" ifc="$3" idx="$4" b1="$5" b2="$6" min="$7" now1 now2 _x rc deadline
  deadline=$((SECONDS + TR_COUNTER_WAIT))
  while :; do
    rc=0
    now1="$(tr::counters "$n1" "$ifc" "$idx")" || return 1
    now2="$(tr::counters "$n2" "$ifc" "$idx")" || return 1
    read -r now1 _x <<<"$now1"; read -r _x now2 <<<"$now2"
    [[ $((now1 - b1)) -ge "$min" ]] || rc=1
    [[ $((now2 - b2)) -ge "$min" ]] || rc=1
    [[ "$rc" -eq 0 || "$SECONDS" -ge "$deadline" ]] && break
    sleep "$TR_COUNTER_INTERVAL"
  done
  echo "$n1 $ifc.$idx in-packets: before $b1 now $now1 moved $((now1 - b1)) (required >= $min)"
  echo "$n2 $ifc.$idx out-packets: before $b2 now $now2 moved $((now2 - b2)) (required >= $min)"
  return "$rc"
}

tr::pid() { lab::docker inspect -f '{{.State.Pid}}' "$(lab::container "$1")"; }

# tr::ping <client> <4|6> <dst> <payload> — DF-set probes from the client's namespace; prints the
# received count last
tr::ping() {
  local pid out rc=0 rx
  pid="$(tr::pid "$1")" || return 2
  out="$("${NSENTER:-nsenter}" -t "$pid" -n "${PING:-ping}" "-$2" -M "do" -c "$TR_COUNT" -i 0.3 -W 2 -s "$4" "$3" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  rx="$(grep -oE '[0-9]+ (packets )?received' <<<"$out" | grep -oE '^[0-9]+' | tail -1)"
  echo "received=${rx:-0} of ${TR_COUNT} (ping exit ${rc})"
  TR_RX="${rx:-0}"
}

tr::reach() {   # every probe answered, retried within TR_WAIT (ARP/ND, DAD)
  local deadline=$((SECONDS + TR_WAIT))
  while :; do
    TR_RX=0; tr::ping "$@" || true
    [[ "$TR_RX" -eq "$TR_COUNT" ]] && return 0
    [[ $SECONDS -ge $deadline ]] && return 1
    sleep 2
  done
}

tr::unreach() {  # no probe answered
  TR_RX=0; tr::ping "$@" || return 1
  [[ "$TR_RX" -eq 0 ]]
}

# tr::gwmac <client> <vlan> <gateway> <mac> — the client resolved the gateway address on eth1.<vlan>
# (or a scratch link on that VLAN) to the anycast MAC: one probe first so the entry exists
tr::gwmac() {
  local c="$1" vlan="$2" gw="$3" want="$4" fam=4 dev got
  [[ "$gw" == *:* ]] && fam=6
  dev="eth1.${vlan}"   # the service subinterface, or the negative control's scratch link on that VLAN
  tr::cexec "$c" ip link show dev "${LAB_SCRATCH_PREFIX}${vlan}" >/dev/null 2>&1 && dev="${LAB_SCRATCH_PREFIX}${vlan}"
  TR_RX=0; tr::ping "$c" "$fam" "$gw" 56 >/dev/null || true
  got="$(tr::cexec "$c" ip -"$fam" neigh show "$gw" dev "$dev" 2>/dev/null | grep -oiE 'lladdr [0-9a-f:]{17}' | awk '{print tolower($2)}' | head -1)"
  echo "$c $dev neighbour $gw lladdr: ${got:-none} (want $want)"
  [[ -n "$got" && "$got" == "$(tr '[:upper:]' '[:lower:]' <<<"$want")" ]]
}

# ---------------------------------------------------------------- client plumbing (tests/ only)

tr::cexec() { local c="$1"; shift; lab::docker exec "$(lab::container "$c")" "$@"; }

tr::undo() { TR_UNDO=("$*" "${TR_UNDO[@]}"); }
tr::cleanup() {
  local u rc=$?
  set +e
  for u in "${TR_UNDO[@]}"; do eval "$u" >/dev/null 2>&1; done
  TR_UNDO=()
  return "$rc"
}

tr::has_addr() { tr::cexec "$1" ip addr show dev "$2" 2>/dev/null | grep -q " ${3} "; }
tr::add_addr() {   # <client> <dev> <addr/len>; removed on exit when this run added it
  local fam=""
  [[ "$3" == *:* ]] && fam="-6"
  tr::has_addr "$1" "$2" "$3" && return 0
  tr::cexec "$1" ip $fam addr add "$3" dev "$2"
  tr::undo "tr::cexec $1 ip $fam addr del $3 dev $2"
}
tr::add_route() {   # <client> <prefix> <gw> <dev>
  local fam=""
  [[ "$2" == *:* ]] && fam="-6"
  tr::cexec "$1" ip $fam route show "$2" 2>/dev/null | grep -q . && return 0
  tr::cexec "$1" ip $fam route add "$2" via "$3" dev "$4"
  tr::undo "tr::cexec $1 ip $fam route del $2 via $3 dev $4"
}

tr::setup_service() {   # <client> <vlan> <addrs>
  local c="$1" vlan="$2" addrs="$3" list p g
  tr::cexec "$c" sh /setup.sh "$vlan" >/dev/null   # the endpoint's own setup: eth1.<vlan>, MTU 9348, up
  IFS=, read -ra list <<<"$addrs"
  for p in "${list[@]}"; do tr::add_addr "$c" "eth1.$vlan" "$p"; done
  while read -r p g; do
    [[ -n "$p" ]] && tr::add_route "$c" "$p" "$g" "eth1.$vlan"
  done < <(tr::routes "$c" "$vlan")
}

tr::scratch_link() {   # <client> <vlan> <addr/len>: vt-scratch-<vlan>, removed with the removal read back
  local c="$1" vlan="$2" name="${LAB_SCRATCH_PREFIX}$2"
  if ! tr::cexec "$c" ip link show dev "$name" >/dev/null 2>&1; then
    tr::cexec "$c" ip link add link eth1 name "$name" type vlan id "$vlan"
  fi
  tr::undo "tr::remove_scratch $c $name"
  tr::cexec "$c" ip link set dev "$name" mtu "$TR_MTU"
  tr::cexec "$c" ip link set dev "$name" up
  tr::has_addr "$c" "$name" "$3" || tr::cexec "$c" ip addr add "$3" dev "$name"
}
tr::remove_scratch() {
  tr::cexec "$1" ip link del "$2" || true
  if tr::cexec "$1" ip link show dev "$2" >/dev/null 2>&1; then
    log::error "scratch link $2 still present on $1 after removal"; return 1
  fi
  log::info "scratch link $2 removed from $1 (read back absent)"
}

# ---------------------------------------------------------------- suite

tr::precondition() {
  local n st rc=0
  for n in $TR_NETWORKS; do
    st="$(lab::kubectl -n "$TR_SERVICES_NS" get networks.fabric.agentic-netops.io "$n" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [[ "$st" != True ]]; then
      log::error "precondition: Network ${TR_SERVICES_NS}/${n} is not Ready=True (${st:-absent})"; rc=3
    fi
  done
  return "$rc"
}

# run-captured check wrappers
tr::neg() {   # <check> <check-args…>: must fail; a pass refuses the suite (exit 3)
  local chk="$1" rc=0; shift
  evidence_negative_control "$chk" -- env TR_WAIT="$TR_NEG_WAIT" bash "$TR_SELF" "$@" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) log::info "negative control $chk failed as required: $*" ;;
    4) log::error "negative control of $chk PASSED (the check is defective): $*"; return 3 ;;
    *) log::error "negative control of $chk could not be recorded (exit $rc): $*"; return 3 ;;
  esac
}
tr::chk() {   # <check> <what> <check-args…>: a readiness-flagged, run-captured pass
  local chk="$1" what="$2" id; shift 2
  id="$(tr::id "TR.${TR_RUN}.${chk}")"
  if evidence_run "$id" --check "$chk" --readiness --records SC-005 -- bash "$TR_SELF" "$@" >/dev/null 2>&1; then
    tr::ok "run ${TR_RUN}: $what"
  else
    tr::fail "run ${TR_RUN}: $what [evidence ${id}]"
    tail -n 3 "$EVIDENCE_DIR/${id}.stdout" 2>/dev/null | sed 's/^/    | /' >&2 || true
  fi
}

tr::negative_controls() {
  log::phase TrafficNegativeControls
  local s="$TR_SCRATCH_STOCK_VLAN" a="$TR_SCRATCH_ABSENT_VLAN"
  tr::scratch_link client01 "$s" "10.${s}.0.11/24"; tr::scratch_link client02 "$s" "10.${s}.0.12/24"
  tr::scratch_link client01 "$a" "10.${a}.0.11/24"; tr::scratch_link client02 "$a" "10.${a}.0.12/24"
  tr::neg TR-instance _instance_up "$TR_STOCK_NODE" macvrf-lab-macvrf || return 3
  tr::neg TR-instance _instance_up leaf01 "$TR_ABSENT_INSTANCE" || return 3
  tr::neg TR-reach _reach client01 4 "10.${s}.0.12" 56 || return 3
  tr::neg TR-reach _reach client01 4 "10.${a}.0.12" 56 || return 3
  tr::neg TR-mtu _reach client01 4 "10.${s}.0.12" "$TR_PAYLOAD4" || return 3
  tr::neg TR-mtu _reach client01 4 "10.${a}.0.12" "$TR_PAYLOAD4" || return 3
  tr::neg TR-isolated _unreach client01 4 10.130.2.10 56 || return 3
  tr::neg TR-mtu-over _unreach client01 4 10.130.2.10 "$TR_PAYLOAD4" || return 3
  tr::neg TR-counters _moved "$TR_STOCK_NODE" spine02 "$TR_PORT" 120 0 0 1 || return 3
  tr::neg TR-counters _moved leaf01 leaf02 "$TR_PORT" "$a" 0 0 1 || return 3
  local c v; for c in client01 client02; do for v in "$s" "$a"; do tr::remove_scratch "$c" "${LAB_SCRATCH_PREFIX}$v" || return 1; done; done
}

# tr::flow <what> <vlan> <fam> <dst> <payload> — a passing probe client01 -> dst and its counters
tr::flow() {
  local what="$1" vlan="$2" fam="$3" dst="$4" pl="$5" b1 b2 i1 o2 _x
  b1="$(tr::counters leaf01 "$TR_PORT" "$vlan" 2>/dev/null)" || { tr::fail "run ${TR_RUN}: counters of ${TR_PORT}.${vlan} unreadable on leaf01"; return 0; }
  b2="$(tr::counters leaf02 "$TR_PORT" "$vlan" 2>/dev/null)" || { tr::fail "run ${TR_RUN}: counters of ${TR_PORT}.${vlan} unreadable on leaf02"; return 0; }
  read -r i1 _x <<<"$b1"; read -r _x o2 <<<"$b2"
  local chk=TR-reach; [[ "$pl" -gt 56 ]] && chk=TR-mtu
  tr::chk "$chk" "$what (IPv${fam}, payload ${pl}, DF)" _reach client01 "$fam" "$dst" "$pl"
  tr::chk TR-counters "$what: ${TR_PORT}.${vlan} leaf01 in-packets / leaf02 out-packets moved" \
    _moved leaf01 leaf02 "$TR_PORT" "$vlan" "$i1" "$o2" "$TR_COUNT"
}

tr::once() {
  log::phase "TrafficRun${TR_RUN}"
  local n
  for n in leaf01 leaf02; do
    tr::chk TR-instance "$n: macvrf-lab-macvrf, ipvrf-lab-ipvrf-a, ipvrf-lab-ipvrf-b oper-state up" \
      _instance_up "$n" macvrf-lab-macvrf ipvrf-lab-ipvrf-a ipvrf-lab-ipvrf-b
  done
  tr::flow "L2 cross-leaf lab-macvrf"      120 4 10.120.0.12         56
  tr::flow "L2 cross-leaf lab-macvrf"      120 6 2001:db8:120::12    56
  tr::flow "L3 intra lab-ipvrf-a"          130 4 10.130.2.10         56
  tr::flow "L3 intra lab-ipvrf-a"          130 6 2001:db8:130:2::10  56
  tr::flow "L3 intra lab-ipvrf-b"          140 4 10.140.2.10         56
  tr::flow "MTU boundary L2 lab-macvrf"    120 4 10.120.0.12         "$TR_PAYLOAD4"
  tr::flow "MTU boundary L2 lab-macvrf"    120 6 2001:db8:120::12    "$TR_PAYLOAD6"
  tr::flow "MTU boundary L3 lab-ipvrf-a"   130 4 10.130.2.10         "$TR_PAYLOAD4"
  tr::flow "MTU boundary L3 lab-ipvrf-a"   130 6 2001:db8:130:2::10  "$TR_PAYLOAD6"
  tr::chk TR-mtu-over "L2 IPv4 payload $((TR_PAYLOAD4 + 1)) with DF fails" _unreach client01 4 10.120.0.12 $((TR_PAYLOAD4 + 1))
  tr::chk TR-mtu-over "L2 IPv6 payload $((TR_PAYLOAD6 + 1)) with DF fails" _unreach client01 6 2001:db8:120::12 $((TR_PAYLOAD6 + 1))
  tr::chk TR-mtu-over "L3 IPv4 payload $((TR_PAYLOAD4 + 1)) with DF fails" _unreach client01 4 10.130.2.10 $((TR_PAYLOAD4 + 1))
  tr::chk TR-mtu-over "L3 IPv6 payload $((TR_PAYLOAD6 + 1)) with DF fails" _unreach client01 6 2001:db8:130:2::10 $((TR_PAYLOAD6 + 1))
  # isolation: the other instance's addresses steered into lab-ipvrf-a's gateway by host routes
  tr::cexec client01 ip route add 10.140.2.10/32 via 10.130.1.1 dev eth1.130 2>/dev/null || true
  tr::cexec client01 ip -6 route add 2001:db8:140:2::10/128 via 2001:db8:130:1::1 dev eth1.130 2>/dev/null || true
  tr::chk TR-isolated "lab-ipvrf-a cannot reach lab-ipvrf-b (IPv4)" _unreach client01 4 10.140.2.10 56
  tr::chk TR-isolated "lab-ipvrf-a cannot reach lab-ipvrf-b (IPv6)" _unreach client01 6 2001:db8:140:2::10 56
  tr::cexec client01 ip route del 10.140.2.10/32 via 10.130.1.1 dev eth1.130 2>/dev/null || true
  tr::cexec client01 ip -6 route del 2001:db8:140:2::10/128 via 2001:db8:130:1::1 dev eth1.130 2>/dev/null || true
}

tr::suite() {
  local runs="$1" r clean=0
  evidence::ensure_dir >/dev/null || return 3
  lab::export_creds || return 3
  trap tr::cleanup EXIT
  trap 'exit 130' INT TERM
  # shellcheck source=../lib/leftovers.sh
  source "$TR_ROOT/tests/lib/leftovers.sh"
  if ! leftovers::scan; then
    log::error "traffic suite REFUSED to start: leftovers present (listed above); run leftovers::remove explicitly"
    return 3
  fi
  tr::precondition || return 3
  local v
  for v in 120 130 140; do
    tr::setup_service client01 "$v" "$(tr::addrs client01 "$v")"
    tr::setup_service client02 "$v" "$(tr::addrs client02 "$v")"
  done
  tr::undo "tr::cexec client01 ip route del 10.140.2.10/32 via 10.130.1.1 dev eth1.130"
  tr::undo "tr::cexec client01 ip -6 route del 2001:db8:140:2::10/128 via 2001:db8:130:1::1 dev eth1.130"
  tr::negative_controls || return 3
  [[ "$runs" -eq 0 ]] && { log::info "negative controls recorded (evidence: $EVIDENCE_DIR)"; return 0; }
  for ((r = 1; r <= runs; r++)); do
    TR_RUN="$r"; local before=${#TR_FAILS[@]}
    tr::once
    if [[ ${#TR_FAILS[@]} -eq "$before" ]]; then clean=$((clean + 1)); log::info "run $r clean"; else log::error "run $r NOT clean"; fi
  done
  if [[ ${#TR_FAILS[@]} -gt 0 ]]; then
    log::error "traffic suite FAILED (${clean}/${runs} clean runs): ${TR_FAILS[*]}"
    return 1
  fi
  log::info "traffic suite passed: ${runs} consecutive clean runs (evidence: $EVIDENCE_DIR)"
}

# ---------------------------------------------------------------- the anycast gateway (T118)

tr::gw_negative_controls() {
  log::phase TrafficGatewayNegativeControls
  local s="$TR_SCRATCH_STOCK_VLAN" a="$TR_SCRATCH_ABSENT_VLAN" v
  for v in "$s" "$a"; do
    tr::scratch_link client01 "$v" "10.${v}.0.11/24"; tr::scratch_link client02 "$v" "10.${v}.0.12/24"
  done
  tr::neg TR-instance _instance_up "$TR_STOCK_NODE" "macvrf-${TR_GW_NETWORK}" "ipvrf-${TR_GW_NETWORK}" || return 3
  tr::neg TR-instance _instance_up leaf01 "$TR_ABSENT_INSTANCE" || return 3
  tr::neg TR-gw-reach _reach client01 4 "10.${s}.0.1" 56 || return 3   # lab-vlan: no gateway
  tr::neg TR-gw-reach _reach client01 4 "10.${a}.0.1" 56 || return 3   # no service at all
  tr::neg TR-gw-mac _gwmac client01 "$s" "10.${s}.0.1" "$TR_GW_MAC" || return 3
  tr::neg TR-gw-mac _gwmac client01 "$a" "10.${a}.0.1" "$TR_GW_MAC" || return 3
  # the bridged half's cross-leaf flow (tr::flow): reachability and keyed counters
  tr::neg TR-reach _reach client01 4 "10.${s}.0.12" 56 || return 3
  tr::neg TR-reach _reach client01 4 "10.${a}.0.12" 56 || return 3
  tr::neg TR-counters _moved "$TR_STOCK_NODE" spine02 "$TR_PORT" "$TR_GW_VLAN" 0 0 1 || return 3
  tr::neg TR-counters _moved leaf01 leaf02 "$TR_PORT" "$a" 0 0 1 || return 3
  local c; for c in client01 client02; do for v in "$s" "$a"; do tr::remove_scratch "$c" "${LAB_SCRATCH_PREFIX}$v" || return 1; done; done
}

tr::gw_once() {
  log::phase "TrafficGatewayRun${TR_RUN}"
  local n c v=$TR_GW_VLAN
  for n in leaf01 leaf02; do
    tr::chk TR-instance "$n: macvrf-${TR_GW_NETWORK} (bridged) and ipvrf-${TR_GW_NETWORK} (routed) oper-state up" \
      _instance_up "$n" "macvrf-${TR_GW_NETWORK}" "ipvrf-${TR_GW_NETWORK}"
  done
  for c in client01 client02; do
    tr::chk TR-gw-reach "$c: the anycast gateway ${TR_GW4} answers from its attached port (IPv4)" _reach "$c" 4 "$TR_GW4" 56
    tr::chk TR-gw-reach "$c: the anycast gateway ${TR_GW6} answers from its attached port (IPv6)" _reach "$c" 6 "$TR_GW6" 56
    tr::chk TR-gw-mac "$c: ${TR_GW4} resolves to the anycast MAC ${TR_GW_MAC}" _gwmac "$c" "$v" "$TR_GW4" "$TR_GW_MAC"
    tr::chk TR-gw-mac "$c: ${TR_GW6} resolves to the anycast MAC ${TR_GW_MAC}" _gwmac "$c" "$v" "$TR_GW6" "$TR_GW_MAC"
  done
  tr::flow "L2 cross-leaf ${TR_GW_NETWORK}" "$v" 4 "10.${v}.0.12" 56
  tr::flow "L2 cross-leaf ${TR_GW_NETWORK}" "$v" 6 "2001:db8:${v}::12" 56
}

tr::gw_suite() {
  local runs="$1" r clean=0
  evidence::ensure_dir >/dev/null || return 3
  lab::export_creds || return 3
  trap tr::cleanup EXIT
  trap 'exit 130' INT TERM
  # shellcheck source=../lib/leftovers.sh
  source "$TR_ROOT/tests/lib/leftovers.sh"
  if ! leftovers::scan; then
    log::error "traffic suite (gateway) REFUSED to start: leftovers present (listed above); run leftovers::remove explicitly"
    return 3
  fi
  TR_NETWORKS="$TR_GW_NETWORK" tr::precondition || return 3
  tr::setup_service client01 "$TR_GW_VLAN" "$(tr::addrs client01 "$TR_GW_VLAN")"
  tr::setup_service client02 "$TR_GW_VLAN" "$(tr::addrs client02 "$TR_GW_VLAN")"
  tr::gw_negative_controls || return 3
  for ((r = 1; r <= runs; r++)); do
    TR_RUN="$r"; local before=${#TR_FAILS[@]}
    tr::gw_once
    if [[ ${#TR_FAILS[@]} -eq "$before" ]]; then clean=$((clean + 1)); log::info "gateway run $r clean"; else log::error "gateway run $r NOT clean"; fi
  done
  if [[ ${#TR_FAILS[@]} -gt 0 ]]; then
    log::error "traffic suite (gateway) FAILED (${clean}/${runs} clean runs): ${TR_FAILS[*]}"
    return 1
  fi
  log::info "traffic suite (gateway) passed: ${runs} consecutive clean runs (evidence: $EVIDENCE_DIR)"
}

# ---------------------------------------------------------------- dispatch

TR_RUN=0
cmd="${1:-run}"
[[ $# -gt 0 ]] && shift
case "$cmd" in
  run)               [[ $# -eq 0 ]] || usage; tr::suite "$RUNS" ;;
  once)              [[ $# -eq 0 ]] || usage; tr::suite 1 ;;
  negative-controls) [[ $# -eq 0 ]] || usage; tr::suite 0 ;;
  gateway)           [[ $# -eq 0 ]] || usage; tr::gw_suite "$RUNS" ;;
  _gwmac)            [[ $# -eq 4 ]] || usage; tr::gwmac "$@" ;;
  _instance_up)      [[ $# -ge 2 ]] || usage; tr::instance_up "$@" ;;
  _reach)            [[ $# -eq 4 ]] || usage; tr::reach "$@" ;;
  _unreach)          [[ $# -eq 4 ]] || usage; tr::unreach "$@" ;;
  _counters)         [[ $# -eq 3 ]] || usage; tr::counters "$@" ;;
  _moved)            [[ $# -eq 7 ]] || usage; tr::moved "$@" ;;
  -h|--help|help)    usage ;;
  *)                 usage ;;
esac
