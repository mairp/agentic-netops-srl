#!/usr/bin/env bash
# tests/integration/lib/tier_egress_counter.sh — SC-028's per-source packet counter (T073; SC-028,
# SC-029, AD-19, research §Open items 16; quickstart.md §15 "How zero device sessions is counted").
#
# "Zero device sessions" is counted per SOURCE, inside every cluster node — never on the management
# network, where the device-configuration layer and the metric collector dial devices by design and
# a pod's source address has already been translated to the node's. The counter matches packets
# whose source is an intent-tier pod address (pods labelled TIER_SELECTOR) and whose destination is
# in MGMT_CIDR, of EVERY protocol — so it is also the assertion behind the UDP row of the boundary
# probe, which the dial itself can only record — and it sits ahead of the NetworkPolicy drop and of
# any source translation.
#
# The packet-filter front end is OBSERVED on each node, never assumed (Open item 16), and printed
# as JSON by `observe` and `install`: the iptables binary and the back end it is linked to, the
# rule counts of the legacy and nft back ends, every nftables base chain (table, hook, priority —
# the NetworkPolicy engine's among them) and whether source translation (MASQUERADE/SNAT) is
# programmed, and where. The counter is an nftables table of its own (TABLE) with one base chain on
# the prerouting hook at priority COUNTER_PRIORITY (-350: after defragmentation at -400, ahead of
# the raw table at -300, conntrack at -200, destination NAT at -100, every NetworkPolicy chain and
# every source NAT at +100). `install` refuses (exit 3) when that point is not ahead of every
# policy-engine chain the node carries; and when a node has no nftables at all it refuses naming the
# fallback — the policy engine's own per-pod drop counters — which this tool does not implement for
# an engine it has not observed. It never falls back to a count on the management network.
#
# Usage: tier_egress_counter.sh <command>
#   observe                 the front-end observation of every node (JSON), nothing changed
#   install                 observe; then (re)create the counter table on every node with the
#                           CURRENT tier pod addresses (re-run after tier pods change; a re-install
#                           starts the counters at zero). Prints {observation, tier_pod_ips, ...}
#   read [--reset]          per-node and total packet counts {all, tcp, udp} (JSON); --reset zeroes
#                           them after reading (the printed values are the ones read)
#   check [--proto all|tcp|udp] [--min N]
#                           read; exit 0 when the total for the protocol is >= N (default all, 1)
#   remove                  delete the table on every node and read the removal back
#   status                  per node: installed or absent (exit 0 when absent everywhere)
#
# Environment: CLUSTER_NAME (agentic-netops — the nodes are the containers labelled
#   io.x-k8s.kind.cluster=<cluster>, so another cluster on the host is never touched), MGMT_CIDR
#   (172.25.25.0/24), TIER_SELECTOR (agentic-netops.io/tier=intent), KUBE_CONTEXT
#   (kind-<cluster>), KUBECTL / DOCKER (fakes in tests), COUNTER_TABLE, COUNTER_PRIORITY.
# Exit: 0 ok; 1 check not met / removal not read back; 2 usage or no node; 3 refused (no counting
# point ahead of the policy drop, no nftables, or no tier pod address to count).
# This is a node-side counter, not a device client: FR-108 does not govern it (AD-19).
set -euo pipefail

: "${CLUSTER_NAME:=agentic-netops}"
: "${MGMT_CIDR:=172.25.25.0/24}"
: "${TIER_SELECTOR:=agentic-netops.io/tier=intent}"
: "${COUNTER_TABLE:=agentic-netops-tier-egress}"
: "${COUNTER_PRIORITY:=-350}"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-${CLUSTER_NAME}}"

tec::err() { printf 'tier_egress_counter: %s\n' "$*" >&2; }
tec::docker() { "${DOCKER:-docker}" "$@"; }
tec::kubectl() { "${KUBECTL:-kubectl}" --context "$KUBE_CONTEXT" "$@"; }

# tec::nodes — the cluster's node containers, sorted
tec::nodes() {
  tec::docker ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" --format '{{.Names}}' | LC_ALL=C sort
}

tec::_need_nodes() {
  TEC_NODES=()
  mapfile -t TEC_NODES < <(tec::nodes)
  if [[ ${#TEC_NODES[@]} -eq 0 ]]; then
    tec::err "no node container labelled io.x-k8s.kind.cluster=${CLUSTER_NAME}"; return 2
  fi
}

# tec::observe_node <node> — the front-end observation of one node (JSON)
tec::observe_node() {
  local n="$1" ver link legacy nftsave ruleset legacy_nat have_nft=true
  ver="$(tec::docker exec "$n" iptables --version 2>/dev/null)" || ver=""
  link="$(tec::docker exec "$n" readlink -f /usr/sbin/iptables 2>/dev/null)" || link=""
  legacy="$(tec::docker exec "$n" iptables-legacy-save 2>/dev/null | grep -c '^-A' || true)"
  nftsave="$(tec::docker exec "$n" iptables-nft-save 2>/dev/null | grep -c '^-A' || true)"
  legacy_nat="$(tec::docker exec "$n" iptables-legacy -t nat -S POSTROUTING 2>/dev/null; tec::docker exec "$n" iptables-legacy -t nat -S 2>/dev/null | grep -E -- '-j (MASQUERADE|SNAT)' || true)"
  ruleset="$(tec::docker exec "$n" nft -j list ruleset 2>/dev/null)" || { ruleset='{"nftables":[]}'; have_nft=false; }
  jq -n --arg node "$n" --arg ver "$ver" --arg link "$link" --arg legacy "${legacy:-0}" --arg nftsave "${nftsave:-0}" \
    --arg nat "$legacy_nat" --argjson rs "$ruleset" --argjson have_nft "$have_nft" \
    --arg table "$COUNTER_TABLE" --argjson prio "$COUNTER_PRIORITY" '
    ([$rs.nftables[]? | select(.chain) | .chain | select(.hook != null) | select(.table != $table)
      | {family, table, name, hook, prio, type}]) as $chains
    | ([$rs.nftables[]? | select(.rule) | .rule | select(.table != $table)
        | select((.expr // []) | tostring | test("\"(masquerade|snat)\""))
        | {family, table, chain}] | unique) as $nft_snat
    | ([$chains[] | select(.table | test("network-polic|netpol|policy"; "i"))]) as $policy
    | {node: $node, iptables_version: $ver, iptables_binary: $link,
       iptables_backend: (if ($ver | test("legacy")) then "legacy" elif ($ver | test("nf_tables")) then "nf_tables" else "unknown" end),
       legacy_rule_count: ($legacy | tonumber), iptables_nft_rule_count: ($nftsave | tonumber),
       nftables_available: $have_nft,
       nftables_base_chains: $chains,
       policy_engine_chains: $policy,
       source_translation: {
         iptables_legacy_nat: ($nat | split("\n") | map(select(test("MASQUERADE|SNAT")))),
         nftables: $nft_snat,
         hook: "postrouting", priority: 100},
       counting_point: {front_end: "nftables", table: ("inet " + $table), hook: "prerouting", priority: $prio,
         ahead_of_policy: ([$policy[] | select(.prio <= $prio and (.hook | IN("prerouting","input","forward","output","postrouting")))] | length == 0),
         ahead_of_source_translation: ($prio < 100)}}'
}

# tec::observe — every node's observation as {nodes: [...], decision}
tec::observe() {
  tec::_need_nodes || return $?
  local n obs="[]" o
  for n in "${TEC_NODES[@]}"; do
    o="$(tec::observe_node "$n")" || return 1
    obs="$(jq -c --argjson o "$o" '. + [$o]' <<<"$obs")"
  done
  jq -n --argjson nodes "$obs" --arg cidr "$MGMT_CIDR" --arg sel "$TIER_SELECTOR" '
    {schema: "agentic-netops.tier-egress-counter.observation/v1", mgmt_cidr: $cidr, tier_selector: $sel,
     nodes: $nodes,
     decision: (if all($nodes[]; .nftables_available and .counting_point.ahead_of_policy and .counting_point.ahead_of_source_translation)
                then "nftables counter on the prerouting hook, ahead of the policy drop and of source translation"
                elif any($nodes[]; .nftables_available | not)
                then "REFUSED: a node has no nftables front end; the fallback is the policy engine'"'"'s per-pod drop counters (not implemented for an unobserved engine), never a count on the management network"
                else "REFUSED: no counting point ahead of every policy-engine chain" end)}'
}

# tec::tier_ips — the IPv4 addresses of the pods TIER_SELECTOR selects (not hostNetwork), one per line
tec::tier_ips() {
  tec::kubectl get pods -A -l "$TIER_SELECTOR" -o json \
    | jq -r '.items[] | select((.spec.hostNetwork // false) | not) | (.status.podIPs // [{ip: .status.podIP}])[] | .ip // empty
             | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$"))' | LC_ALL=C sort -u
}

tec::_script() { # <ips-csv> — the nft script (table recreated atomically)
  cat <<EOF
table inet ${COUNTER_TABLE}
delete table inet ${COUNTER_TABLE}
table inet ${COUNTER_TABLE} {
  comment "agentic-netops SC-028 per-source counter: intent-tier pod sources toward ${MGMT_CIDR}, every protocol"
  set tier4 { type ipv4_addr; elements = { $1 } }
  counter tier_all { }
  counter tier_tcp { }
  counter tier_udp { }
  chain tier_egress {
    type filter hook prerouting priority ${COUNTER_PRIORITY}; policy accept;
    ip saddr @tier4 ip daddr ${MGMT_CIDR} counter name "tier_all"
    ip saddr @tier4 ip daddr ${MGMT_CIDR} meta l4proto tcp counter name "tier_tcp"
    ip saddr @tier4 ip daddr ${MGMT_CIDR} meta l4proto udp counter name "tier_udp"
  }
}
EOF
}

tec::install() {
  local obs ips csv n
  tec::_need_nodes || return $?
  obs="$(tec::observe)" || return $?
  if ! jq -e '.decision | startswith("nftables counter")' <<<"$obs" >/dev/null; then
    printf '%s\n' "$obs"
    tec::err "$(jq -r .decision <<<"$obs")"
    return 3
  fi
  ips="$(tec::tier_ips)" || { tec::err "cannot list the tier pods (${TIER_SELECTOR})"; return 1; }
  if [[ -z "$ips" ]]; then
    printf '%s\n' "$obs"
    tec::err "no pod selected by ${TIER_SELECTOR} has an address: nothing to count (create the tier pods first)"
    return 3
  fi
  csv="$(paste -sd, <<<"$ips" | sed 's/,/, /g')"
  [[ ${#TEC_NODES[@]} -gt 0 ]] || { tec::err "no node to install on"; return 2; }
  for n in "${TEC_NODES[@]}"; do
    tec::_script "$csv" | tec::docker exec -i "$n" nft -f - || { tec::err "installing the counter on ${n} failed"; return 1; }
    tec::docker exec "$n" nft list table inet "$COUNTER_TABLE" >/dev/null 2>&1 \
      || { tec::err "the counter table is not present on ${n} after install"; return 1; }
  done
  jq -n --argjson obs "$obs" --arg ips "$ips" --arg table "$COUNTER_TABLE" --argjson prio "$COUNTER_PRIORITY" \
    --arg script "$(tec::_script "$csv")" '
    {installed: true, table: ("inet " + $table), hook: "prerouting", priority: $prio,
     tier_pod_ips: ($ips | split("\n") | map(select(length > 0))), nft_script: $script, observation: $obs}'
}

tec::_read_node() { # <node> — {all, tcp, udp}
  local out
  out="$(tec::docker exec "$1" nft -j list counters table inet "$COUNTER_TABLE" 2>/dev/null)" \
    || { tec::err "no counter table on $1 (install first)"; return 1; }
  jq -c '[.nftables[]? | select(.counter) | .counter | {key: (.name | ltrimstr("tier_")), value: .packets}] | from_entries
         | {all: (.all // 0), tcp: (.tcp // 0), udp: (.udp // 0)}' <<<"$out"
}

tec::read() {
  local reset=false n c nodes="{}"
  [[ "${1:-}" == --reset ]] && reset=true
  tec::_need_nodes || return $?
  for n in "${TEC_NODES[@]}"; do
    c="$(tec::_read_node "$n")" || return 1
    nodes="$(jq -c --arg n "$n" --argjson c "$c" '. + {($n): $c}' <<<"$nodes")"
  done
  if [[ "$reset" == true ]]; then
    for n in "${TEC_NODES[@]}"; do
      tec::docker exec "$n" nft reset counters table inet "$COUNTER_TABLE" >/dev/null || { tec::err "reset failed on $n"; return 1; }
    done
  fi
  jq -n --argjson nodes "$nodes" --argjson reset "$reset" --arg cidr "$MGMT_CIDR" '
    {mgmt_cidr: $cidr, nodes: $nodes, reset_after_read: $reset,
     total: {all: ([$nodes[].all] | add // 0), tcp: ([$nodes[].tcp] | add // 0), udp: ([$nodes[].udp] | add // 0)}}'
}

tec::check() {
  local proto=all min=1 out got
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --proto) proto="${2:?--proto needs all|tcp|udp}"; shift 2 ;;
      --min) min="${2:?--min needs a number}"; shift 2 ;;
      *) tec::err "check: unknown argument $1"; return 2 ;;
    esac
  done
  [[ "$proto" =~ ^(all|tcp|udp)$ && "$min" =~ ^[0-9]+$ ]] || { tec::err "check: --proto all|tcp|udp, --min N"; return 2; }
  out="$(tec::read)" || return 1
  printf '%s\n' "$out"
  got="$(jq -r --arg p "$proto" '.total[$p]' <<<"$out")"
  if (( got >= min )); then
    echo "COUNTER ${proto}=${got} >= ${min}: moved"
    return 0
  fi
  echo "COUNTER ${proto}=${got} < ${min}: NOT moved"
  return 1
}

tec::status() {
  tec::_need_nodes || return $?
  local n rc=0
  for n in "${TEC_NODES[@]}"; do
    if tec::docker exec "$n" nft list table inet "$COUNTER_TABLE" >/dev/null 2>&1; then
      echo "$n installed"; rc=1
    else
      echo "$n absent"
    fi
  done
  return "$rc"
}

tec::remove() {
  tec::_need_nodes || return $?
  local n
  for n in "${TEC_NODES[@]}"; do
    if tec::docker exec "$n" nft list table inet "$COUNTER_TABLE" >/dev/null 2>&1; then
      tec::docker exec "$n" nft delete table inet "$COUNTER_TABLE" || { tec::err "delete failed on $n"; return 1; }
    fi
  done
  tec::status || { tec::err "the counter table is still present after removal"; return 1; }
  echo "counter removed and read back absent on every node"
}

tec::main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    observe) tec::observe ;;
    install) tec::install ;;
    read)    tec::read "$@" ;;
    check)   tec::check "$@" ;;
    remove)  tec::remove ;;
    status)  tec::status ;;
    -h|--help|help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' ;;
    *) tec::err "usage: tier_egress_counter.sh observe|install|read [--reset]|check [--proto p] [--min N]|remove|status"; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  tec::main "$@"
fi
