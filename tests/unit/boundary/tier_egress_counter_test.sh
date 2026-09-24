#!/usr/bin/env bash
# tests/unit/boundary/tier_egress_counter_test.sh — SC-028's per-source counter
# (tests/integration/lib/tier_egress_counter.sh, T073; AD-19, research §Open items 16), offline
# against a fake docker (node containers, nftables, iptables) and a fake kubectl (the tier pods):
#   1  the front end is OBSERVED and recorded: iptables' back end (legacy), the rule counts, every
#      nftables base chain, the policy engine's chains and where source translation happens
#   2  install: only the nodes of THIS cluster (label io.x-k8s.kind.cluster=<cluster>; another
#      cluster's node is never touched); the nft program counts sources in the tier pods' addresses
#      toward MGMT_CIDR, every protocol (all + tcp + udp counters, no port match), on the prerouting
#      hook at a priority ahead of every policy chain and of source translation
#   3  refusals (exit 3): a policy-engine chain AHEAD of the counting point; a node with no
#      nftables (the fallback — per-pod drop counters — named, never a count on the management
#      network); no tier pod address to count
#   4  read sums the nodes; --reset zeroes after reading; check passes only at or above --min —
#      its negative control, a counter that has not moved, fails
#   5  remove deletes the table and READS the removal back (a delete that does not take fails)
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEC="$ROOT/tests/integration/lib/tier_egress_counter.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok()  { printf 'PASS %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 12 | sed 's/^/    /'; }

mkdir -p "$T/bin" "$T/s"
export FAKE_STATE="$T/s"
cat >"$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
S="$FAKE_STATE"
echo "docker $*" >>"$S/calls.log"
TBL=agentic-netops-tier-egress
case "$1" in
  ps) lbl=""; for a in "$@"; do [[ "$a" == label=io.x-k8s.kind.cluster=* ]] && lbl="${a#label=io.x-k8s.kind.cluster=}"; done
      cat "$S/nodes.$lbl" 2>/dev/null; exit 0 ;;
  exec) shift; [[ "$1" == -i ]] && shift; node="$1"; shift
        case "$*" in
          "iptables --version") echo "iptables v1.8.9 (legacy)" ;;
          "readlink -f /usr/sbin/iptables") echo /usr/sbin/xtables-legacy-multi ;;
          "iptables-legacy-save") printf -- '-A KUBE-A\n-A KUBE-B\n-A KIND-MASQ-AGENT -j MASQUERADE\n' ;;
          "iptables-nft-save") : ;;
          "iptables-legacy -t nat -S POSTROUTING") echo '-A POSTROUTING -j KIND-MASQ-AGENT' ;;
          "iptables-legacy -t nat -S") echo '-A KIND-MASQ-AGENT -j MASQUERADE' ;;
          "nft -j list ruleset") [[ -f "$S/no-nft" ]] && exit 127; cat "$S/ruleset.json" ;;
          "nft -f -") [[ -f "$S/no-nft" ]] && exit 127; cat >"$S/$node.nft"; touch "$S/$node.table"; echo "0 0 0" >"$S/$node.counts" ;;
          "nft list table inet $TBL") [[ -f "$S/$node.table" ]] ;;
          "nft -j list counters table inet $TBL")
             [[ -f "$S/$node.table" ]] || exit 1
             read -r a t u <"$S/$node.counts"
             printf '{"nftables":[{"metainfo":{}},{"counter":{"family":"inet","name":"tier_all","table":"%s","packets":%s,"bytes":0}},{"counter":{"family":"inet","name":"tier_tcp","table":"%s","packets":%s,"bytes":0}},{"counter":{"family":"inet","name":"tier_udp","table":"%s","packets":%s,"bytes":0}}]}\n' "$TBL" "$a" "$TBL" "$t" "$TBL" "$u" ;;
          "nft reset counters table inet $TBL") echo "0 0 0" >"$S/$node.counts" ;;
          "nft delete table inet $TBL") [[ -f "$S/sticky" ]] || rm -f "$S/$node.table" ;;
          *) echo "fake docker: unexpected exec $*" >&2; exit 99 ;;
        esac ;;
  *) echo "fake docker: unexpected $*" >&2; exit 99 ;;
esac
EOF
cat >"$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$FAKE_STATE/calls.log"
if [[ "$*" == *"get pods -A -l agentic-netops.io/tier=intent -o json"* ]]; then cat "$FAKE_STATE/pods.json"; exit 0; fi
echo "fake kubectl: unexpected $*" >&2; exit 99
EOF
chmod +x "$T/bin/docker" "$T/bin/kubectl"
export PATH="$T/bin:$PATH" CLUSTER_NAME=agentic-netops MGMT_CIDR=172.25.25.0/24
printf 'agentic-netops-control-plane\nagentic-netops-worker\n' >"$T/s/nodes.agentic-netops"
printf 'agentflow-005-control-plane\n' >"$T/s/nodes.agentflow-005"
ruleset() { # <policy prerouting prio>
  jq -n --argjson p "$1" '{nftables: [{metainfo: {}},
    {table: {family: "inet", name: "kindnet-network-policies"}},
    {chain: {family: "inet", table: "kindnet-network-policies", name: "postrouting", hook: "postrouting", prio: 95, type: "filter"}},
    {chain: {family: "inet", table: "kindnet-network-policies", name: "prerouting", hook: "prerouting", prio: $p, type: "filter"}}]}' >"$T/s/ruleset.json"
}
ruleset -95
jq -n '{items: [
  {metadata: {name: "a"}, spec: {}, status: {podIP: "10.244.0.41", podIPs: [{ip: "10.244.0.41"}]}},
  {metadata: {name: "b"}, spec: {}, status: {podIP: "10.244.0.42"}},
  {metadata: {name: "h"}, spec: {hostNetwork: true}, status: {podIP: "172.30.0.3"}},
  {metadata: {name: "p"}, spec: {}, status: {}}]}' >"$T/s/pods.json"
run() { out="$(bash "$TEC" "$@" 2>&1)"; rc=$?; }

# 1. observe
run observe
if [[ $rc -eq 0 ]] && jq -e '.nodes | length == 2' <<<"$out" >/dev/null && jq -e '
    .nodes[0].iptables_backend == "legacy" and .nodes[0].legacy_rule_count == 3 and .nodes[0].iptables_nft_rule_count == 0
    and (.nodes[0].policy_engine_chains | length == 2) and (.nodes[0].source_translation.iptables_legacy_nat | length > 0)
    and .nodes[0].counting_point.ahead_of_policy and (.decision | startswith("nftables counter"))' <<<"$out" >/dev/null; then
  ok "observe records the front end: iptables legacy, rule counts, the policy engine's nftables chains, source translation"
else bad "observe" "$out"; fi

# 2. install
run install
if [[ $rc -eq 0 ]]; then ok "install succeeds with the policy engine at prerouting -95 / postrouting 95"; else bad "install" "$out"; fi
prog="$(cat "$T/s/agentic-netops-control-plane.nft" 2>/dev/null)"
[[ -f "$T/s/agentic-netops-worker.nft" && ! -f "$T/s/agentflow-005-control-plane.nft" ]] \
  && ok "installed on every node of this cluster and on no other cluster's node" || bad "node selection" "$(cat "$T/s/calls.log")"
grep -q 'elements = { 10.244.0.41, 10.244.0.42 }' <<<"$prog" && ! grep -q '172.30.0.3' <<<"$prog" \
  && ok "the counter matches exactly the tier pods' addresses (hostNetwork and address-less pods excluded)" || bad "tier address set" "$prog"
grep -q 'hook prerouting priority -350' <<<"$prog" && ok "counting point: prerouting at -350, ahead of the policy chains and of source translation" || bad "priority" "$prog"
if grep -q 'ip daddr 172.25.25.0/24 counter name "tier_all"' <<<"$prog" && grep -q 'meta l4proto tcp counter name "tier_tcp"' <<<"$prog" \
   && grep -q 'meta l4proto udp counter name "tier_udp"' <<<"$prog" && ! grep -qE 'dport|sport' <<<"$prog"; then
  ok "every protocol is counted toward MGMT_CIDR (all/tcp/udp), no port match"
else bad "counter rules" "$prog"; fi
jq -e '.tier_pod_ips == ["10.244.0.41","10.244.0.42"] and .observation.nodes[0].node == "agentic-netops-control-plane"' <<<"$out" >/dev/null \
  && ok "install prints the addresses counted and the front-end observation (evidence)" || bad "install output" "$out"

# 4. read / check / reset
echo "7 5 2" >"$T/s/agentic-netops-control-plane.counts"; echo "3 3 0" >"$T/s/agentic-netops-worker.counts"
run read
jq -e '.total == {all: 10, tcp: 8, udp: 2} and .nodes["agentic-netops-worker"].all == 3' <<<"$out" >/dev/null && ok "read sums the nodes: all 10, tcp 8, udp 2" || bad "read" "$out"
run check --proto udp --min 2; [[ $rc -eq 0 ]] && grep -q 'COUNTER udp=2 >= 2: moved' <<<"$out" && ok "check --proto udp --min 2 passes at 2" || bad "check udp" "$out"
run check --proto udp --min 3; [[ $rc -ne 0 ]] && ok "check --proto udp --min 3 fails at 2" || bad "check udp min 3 passed" "$out"
run read --reset; jq -e '.total.all == 10 and .reset_after_read' <<<"$out" >/dev/null && ok "read --reset prints the values read" || bad "read --reset" "$out"
run check; [[ $rc -ne 0 ]] && grep -q 'NOT moved' <<<"$out" && ok "negative control: after --reset the counter has not moved and check fails" || bad "check after reset passed" "$out"
run check --proto icmp; [[ $rc -eq 2 ]] && ok "check refuses an unknown protocol (usage)" || bad "check --proto icmp" "$out"

# 5. remove
touch "$T/s/sticky"; run remove
[[ $rc -ne 0 ]] && grep -q 'still present' <<<"$out" && ok "a removal that does not take is read back and fails" || bad "sticky remove" "$out"
rm -f "$T/s/sticky"; run remove
[[ $rc -eq 0 && ! -f "$T/s/agentic-netops-control-plane.table" ]] && grep -q 'read back absent' <<<"$out" && ok "remove deletes the table and reads the removal back" || bad "remove" "$out"
run status; [[ $rc -eq 0 ]] && ok "status: absent everywhere after removal" || bad "status" "$out"

# 3. refusals
ruleset -400; run install
[[ $rc -eq 3 ]] && grep -q 'REFUSED: no counting point' <<<"$out" && ok "a policy chain ahead of the counting point is refused (exit 3)" || bad "policy ahead" "$out"
ruleset -95; touch "$T/s/no-nft"; run install
[[ $rc -eq 3 ]] && grep -q "per-pod drop counters" <<<"$out" && grep -q "never a count on the management network" <<<"$out" \
  && ok "no nftables: refused, naming the per-pod drop-counter fallback, never a management-network count" || bad "no nft" "$out"
rm -f "$T/s/no-nft"; jq '.items = []' "$T/s/pods.json" >"$T/s/p2" && mv "$T/s/p2" "$T/s/pods.json"; run install
[[ $rc -eq 3 ]] && grep -q 'nothing to count' <<<"$out" && ok "no tier pod address: refused (a counter that could only read zero is no evidence)" || bad "no pods" "$out"
CLUSTER_NAME=absent-cluster run observe; [[ $rc -eq 2 ]] && ok "no node of the cluster: usage failure, nothing touched" || bad "no node" "$out"

echo "tier_egress_counter_test: $fails failure(s)"
[[ "$fails" -eq 0 ]]
