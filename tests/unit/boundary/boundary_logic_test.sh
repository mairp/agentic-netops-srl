#!/usr/bin/env bash
# tests/unit/boundary/boundary_logic_test.sh — the judging logic of tests/integration/boundary_probes.sh
# (T066, T073; FR-075, FR-103, SC-029, R-34, AD-49), offline: the suite is SOURCED (its live run
# only starts when executed), and every function that decides a verdict is driven with fixtures.
#
#   1  `can-i --list` parsing and the exact comparison: the deployer's table in the intent namespace
#      equals its allow-list after the default filter; an extra rule (Secrets), a missing verb, an
#      extra verb, a non-default non-resource URL, a resource-name-scoped rule and a namespace-wide
#      grant to every service account each FAIL naming it (negative controls); the cluster admin's
#      table fails; a namespace holding only the defaults compares equal to {}
#   2  the reconciliation against G2's observation: loopback-only listeners are recorded, never
#      failures; a non-loopback listener the contract list does not carry fails NAMING the port
#      (also on a specific non-loopback address); an observation without bind scope, or with a
#      device whose listing was unavailable, is refused
#   3  bp::expect: each mode passes exactly on its own verdict (timeout only on 124, not on a
#      completed or refused dial; no/yes on the answer; http on the status; admission-denied only
#      on the named policy's refusal, not on an RBAC Forbidden)
#   4  the allow-list and the denial table follow the lock file's authority (T182): first-party →
#      identifierclaims in agentic-netops-allocation, kuid → vlanclaims + genidclaims in kuid-system;
#      the denial table carries every class of the contract's table
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok()  { printf 'PASS %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 12 | sed 's/^/    /'; }

# shellcheck source=../../integration/boundary_probes.sh
source "$ROOT/tests/integration/boundary_probes.sh"
set +e

# ---------------------------------------------------------------- 1. can-i --list
HDR='Resources                                       Non-Resource URLs                      Resource Names   Verbs'
row() { printf '%-48s%-39s%-17s%s\n' "$1" "$2" "$3" "$4"; }
defaults() {
  row selfsubjectreviews.authentication.k8s.io '[]' '[]' '[create]'
  row selfsubjectaccessreviews.authorization.k8s.io '[]' '[]' '[create]'
  row selfsubjectrulesreviews.authorization.k8s.io '[]' '[]' '[create]'
  local u
  for u in /.well-known/openid-configuration/ /.well-known/openid-configuration /api/\* /api /apis/\* /apis /healthz /livez \
           /openapi/\* /openapi /openid/v1/jwks/ /openid/v1/jwks /readyz /version/ /version; do
    row '' "[$u]" '[]' '[get]'
  done
}
DEPLOYER_WANT="$(bp::expected_rules deployer agentic-netops-intent first-party)"
table_ok() { echo "$HDR"; row networks.fabric.agentic-netops.io '[]' '[]' '[get list watch create update patch delete]'; row events '[]' '[]' '[create]'; defaults; }
cmp_list() { bp::parse_list | bp::compare_list "$1" 2>&1; }

out="$(table_ok | cmp_list "$DEPLOYER_WANT")" && ok "deployer's --list in the intent namespace equals the allow-list after the default filter" \
  || bad "deployer's exact table rejected" "$out"
grep -q 'FILTERED 18 default rule' <<<"$out" && ok "the 18 default rules are counted as filtered" || bad "default filter count" "$out"
out="$({ table_ok; row secrets '[]' '[]' '[get]'; } | cmp_list "$DEPLOYER_WANT")" \
  && bad "negative control: an extra Secrets rule compared equal" || { grep -q 'UNEXPECTED secrets get' <<<"$out" && ok "negative control: an extra Secrets rule fails, named" || bad "extra rule not named" "$out"; }
out="$({ echo "$HDR"; row networks.fabric.agentic-netops.io '[]' '[]' '[get list watch create update delete]'; row events '[]' '[]' '[create]'; defaults; } | cmp_list "$DEPLOYER_WANT")" \
  && bad "negative control: a missing patch verb compared equal" || ok "negative control: a missing verb (patch) fails"
out="$({ table_ok; row events '[]' '[]' '[list]'; } | cmp_list "$DEPLOYER_WANT")" \
  && bad "negative control: an extra verb on events compared equal" || ok "negative control: an extra verb on events fails"
out="$({ table_ok; row '' '[/metrics]' '[]' '[get]'; } | cmp_list "$DEPLOYER_WANT")" \
  && bad "negative control: a non-default non-resource URL compared equal" || ok "negative control: a non-default non-resource URL (/metrics) fails"
out="$({ table_ok; row secrets '[]' '[operator-credentials]' '[get]'; } | cmp_list "$DEPLOYER_WANT")" \
  && bad "negative control: a resource-name-scoped Secret grant compared equal" || ok "negative control: a resource-name-scoped rule fails"
out="$({ echo "$HDR"; defaults; row configmaps '[]' '[]' '[get list]'; } | cmp_list '{}')" \
  && bad "negative control: a namespace-wide grant to every service account compared equal to nothing" \
  || ok "negative control: a grant every service account holds in a namespace is NOT filtered (the filter is a fixed list)"
out="$({ echo "$HDR"; row '*.*' '[]' '[]' '[*]'; row '' '[*]' '[]' '[*]'; defaults; } | cmp_list "$DEPLOYER_WANT")" \
  && bad "negative control: the cluster admin's table compared equal" || ok "negative control: the cluster admin's table fails"
out="$({ echo "$HDR"; defaults; } | cmp_list '{}')" && ok "a namespace with only the defaults compares equal to no rule" || bad "defaults-only table rejected" "$out"
out="$({ echo "$HDR"; defaults; } | cmp_list "$DEPLOYER_WANT")" && bad "a missing allow-list compared equal" || { grep -q MISSING <<<"$out" && ok "the allow-list absent from the listing fails as MISSING" || bad "missing not named" "$out"; }
printf 'not a table\n' | bp::parse_list >/dev/null 2>&1 && bad "a non-table was parsed" || ok "output that is not a can-i --list table is refused"
# through bp::expect list, as the suite runs it
table_ok >"$T/list.txt"
bp::expect list "$DEPLOYER_WANT" -- cat "$T/list.txt" >/dev/null 2>&1 && ok "expect list passes on the exact table" || bad "expect list"
bp::expect list '{}' -- cat "$T/list.txt" >/dev/null 2>&1 && bad "expect list {} passed on the deployer's table" || ok "expect list {} fails on a table carrying rules"

# ---------------------------------------------------------------- 2. reconciliation
cat >"$T/contract.md" <<'EOF'
the lab image exposes
**TCP 22, 80, 443, 830, 50052, 57400, 57401, 57410 and 57411, and UDP 161**. The platform
EOF
export BP_CONTRACT="$T/contract.md"
mk_obs() { # <extra network_listeners json array> [loopback json array] [unavailable json array]
  jq -n --argjson extra "$1" --argjson lo "${2:-[]}" --argjson un "${3:-[]}" '
    {network_listeners: ([{transport:"tcp",port:22,addresses:["0.0.0.0","::"]},{transport:"tcp",port:57400,addresses:["*"]},
                          {transport:"udp",port:161,addresses:["0.0.0.0"]}] + $extra),
     loopback_listeners: $lo, listeners_unavailable: $un}'
}
mk_obs '[]' '[{"transport":"tcp","port":53,"addresses":["127.0.0.1","::1"]},{"transport":"tcp","port":199,"addresses":["127.0.0.1"]},{"transport":"udp","port":53,"addresses":["127.0.0.1"]}]' >"$T/obs-ok.json"
out="$(bp::reconcile "$T/obs-ok.json" 2>&1)" && ok "loopback-only 53/tcp, 53/udp, 199/tcp are recorded, not failures" || bad "loopback listeners failed the reconciliation" "$out"
grep -q 'LOOPBACK-ONLY tcp/199' <<<"$out" && grep -q 'DOCUMENTED-NOT-LISTENING tcp/57410' <<<"$out" \
  && ok "the reconciliation records loopback-only and documented-not-listening ports" || bad "reconciliation record lines" "$out"
mk_obs '[{"transport":"tcp","port":23,"addresses":["0.0.0.0"]}]' >"$T/obs-23.json"
out="$(bp::reconcile "$T/obs-23.json" 2>&1)" && bad "negative control: a listening tcp/23 not in the list passed" \
  || { grep -q 'UNCOVERED tcp/23' <<<"$out" && ok "negative control: a non-loopback listener the list does not carry fails, naming tcp/23" || bad "tcp/23 not named" "$out"; }
mk_obs '[{"transport":"udp","port":162,"addresses":["10.1.2.3"]}]' >"$T/obs-specific.json"
out="$(bp::reconcile "$T/obs-specific.json" 2>&1)" && bad "a listener on a specific non-loopback address was exempted" \
  || { grep -q 'UNCOVERED udp/162' <<<"$out" && ok "a specific non-loopback address is not exempt (udp/162 named)" || bad "udp/162 not named" "$out"; }
jq 'del(.network_listeners)' "$T/obs-ok.json" >"$T/obs-old.json"
bp::reconcile "$T/obs-old.json" >/dev/null 2>&1 && bad "an observation without bind scope was accepted" || ok "an observation without network_listeners (pre-bind-scope G2) is refused"
mk_obs '[]' '[]' '["leaf01"]' >"$T/obs-un.json"
bp::reconcile "$T/obs-un.json" >/dev/null 2>&1 && bad "an observation with an unlisted device was accepted" || ok "an observation naming an unavailable device listing is refused"
if [[ -f "$ROOT/tests/gate/observed/mgmt-ports.json" ]]; then
  out="$(bp::reconcile "$ROOT/tests/gate/observed/mgmt-ports.json" 2>&1)" && ok "the committed G2 observation reconciles against the fixture contract" \
    || bad "the committed G2 observation does not reconcile" "$out"
fi

# ---------------------------------------------------------------- 3. bp::expect
e() { bp::expect "$@" >/dev/null 2>&1; }
e timeout -- sh -c 'exit 124' && ok "expect timeout: exit 124 passes" || bad "expect timeout 124"
e timeout -- sh -c 'exit 1' && bad "expect timeout passed a refused connection (exit 1)" || ok "expect timeout: a refused dial (exit 1) fails"
e timeout -- true && bad "expect timeout passed a completed connection" || ok "expect timeout: a completed dial (exit 0) fails"
e no -- sh -c 'echo no; exit 1' && ok "expect no: 'no' passes" || bad "expect no"
e no -- sh -c 'echo yes' && bad "expect no passed 'yes'" || ok "expect no: 'yes' fails"
e no -- sh -c 'echo "error: connection refused" >&2; exit 1' && bad "expect no passed an error with no answer" || ok "expect no: an error with no answer fails (fail-closed)"
e yes -- sh -c 'echo yes' && ok "expect yes: 'yes' passes" || bad "expect yes"
e yes -- sh -c 'echo no; exit 1' && bad "expect yes passed 'no'" || ok "expect yes: 'no' fails"
e http 403 -- echo 403 && ok "expect http 403: 403 passes" || bad "expect http 403"
e http 403 -- echo 200 && bad "expect http 403 passed 200" || ok "expect http 403: 200 fails"
VAPMSG="Error from server (Forbidden): error when creating \"x.yaml\": networks.fabric.agentic-netops.io \"vt-scratch-force-release\" is forbidden: ValidatingAdmissionPolicy 'deny-tier-force-release' with binding 'deny-tier-force-release' denied request: the intent tier identity may not set"
RBACMSG='Error from server (Forbidden): networks.fabric.agentic-netops.io is forbidden: User "system:serviceaccount:agentic-netops-agents:intent-allocator" cannot create resource "networks"'
printf '%s\n' "$VAPMSG" >"$T/vap.txt"; printf '%s\n' "$RBACMSG" >"$T/rbac.txt"
e admission-denied -- sh -c "cat '$T/vap.txt' >&2; exit 1" && ok "expect admission-denied: the policy's refusal passes" || bad "expect admission-denied"
e admission-denied -- sh -c "cat '$T/rbac.txt' >&2; exit 1" && bad "expect admission-denied passed an RBAC Forbidden" || ok "expect admission-denied: an RBAC refusal is not the admission policy's"
e admission-denied -- true && bad "expect admission-denied passed an accepted request" || ok "expect admission-denied: an accepted request fails"
e accepted -- true && ok "expect accepted: exit 0 passes" || bad "expect accepted"
e accepted -- false && bad "expect accepted passed a refusal" || ok "expect accepted: a refusal fails"

# ---------------------------------------------------------------- 4. authority-following tables
[[ "$(bp::expected_rules allocator agentic-netops-allocation first-party)" == '{"identifierclaims.fabric.agentic-netops.io":["get","list","watch","create","delete"]}' ]] \
  && ok "first-party: the allocator's allow-list is identifierclaims in agentic-netops-allocation" || bad "first-party allocator rules"
[[ "$(bp::expected_rules allocator kuid-system kuid | jq -c 'keys')" == '["genidclaims.genid.be.kuid.dev","vlanclaims.vlan.be.kuid.dev"]' ]] \
  && ok "kuid: the allocator's allow-list is vlanclaims + genidclaims in kuid-system" || bad "kuid allocator rules"
[[ "$(bp::expected_rules allocator agentic-netops-intent first-party)" == '{}' && "$(bp::expected_rules deployer agentic-netops-system first-party)" == '{}' ]] \
  && ok "no rule outside each identity's one namespace (the allocator has none on networks)" || bad "rules outside the namespace"
D="$(bp::denials first-party)"
need=(
  "both|get|secrets|-A" "both|get|secrets/operator-credentials|-n agentic-netops-agents" "both|get|configmaps/site-inventory|-n agentic-netops-agents"
  "both|create|pods/exec|-A" "both|get|nodes|-A" "both|create|fabrics.fabric.agentic-netops.io|-A" "both|create|configs.config.sdcio.dev|-A"
  "both|create|configsets.config.sdcio.dev|-A" "both|get|targets.config.sdcio.dev|-A" "both|get|targets.inv.sdcio.dev|-A" "both|get|schemas.inv.sdcio.dev|-A"
  "both|create|ipclaims.ipam.be.kuid.dev|-A" "both|create|asclaims.as.be.kuid.dev|-A"
  "both|update|identifierclaims.fabric.agentic-netops.io|-n agentic-netops-allocation" "both|patch|identifierclaims.fabric.agentic-netops.io|-n agentic-netops-allocation"
  "deployer|update|networks.fabric.agentic-netops.io|-n agentic-netops-system" "deployer|get|networks.fabric.agentic-netops.io|-n agentic-netops-services"
  "allocator|get|networks.fabric.agentic-netops.io|-n agentic-netops-intent" "allocator|list|networks.fabric.agentic-netops.io|-A"
)
miss=""; for n in "${need[@]}"; do grep -qxF "$n" <<<"$D" || miss+="$n"$'\n'; done
[[ -z "$miss" ]] && ok "the denial table carries every class of the contract's table (${#need[@]} anchors)" || bad "denial table misses rows" "$miss"
grep -qxF "both|update|vlanclaims.vlan.be.kuid.dev|-n kuid-system" <<<"$(bp::denials kuid)" \
  && ok "kuid: update on the selected authority's claims is probed" || bad "kuid claim update not probed"
grep -E '^(both|deployer|allocator)\|' <<<"$D" | grep -vqE '^(both|deployer|allocator)\|[a-z]+\|[a-z0-9./-]+\|(-A|-n [a-z0-9-]+)$' \
  && bad "a malformed denial row" || ok "every denial row is well-formed (who|verb|resource|scope)"
[[ "$(bp::cid BP.deny deployer get pods/exec "-A")" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && ok "check ids are valid evidence ids" || bad "check id"

echo "boundary_logic_test: $fails failure(s)"
[[ "$fails" -eq 0 ]]
