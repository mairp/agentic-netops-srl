#!/usr/bin/env bash
# tests/unit/boundary/rbac_test.sh — scripts/lib/rbac.sh, the boundary step's apply and run order
# (T073; FR-075, FR-103, FR-109, AD-32, T182), offline, on a copy of the parts of the tree it reads,
# against a fake kubectl (records every call and every applied manifest) and a fake docker (the
# management network):
#   1  render: the scoped egress policy is templated from the REAL docker subnet, drops the whole
#      MGMT_CIDR, the cluster's pod and service subnets and the API server's endpoints with no port
#      list and no protocol, and inside the cluster admits only the tier's own namespace and the
#      cluster DNS on 53; the API server
#      policy opens exactly the endpoint /32 on its port to the two identity pods; no placeholder is
#      left; the four policies of T070 and nothing else
#   2  refusals, each with ZERO applies: MGMT_CIDR differing from the docker network; no readable
#      docker network; unreadable pod/service subnets; an API server endpoint inside the management CIDR; a policy that does not
#      type-check cleanly stops after its own apply
#   3  apply order: namespaces → ServiceAccounts → intent-writer → the claim Role → the policies →
#      the admission policy → the tier's Secrets (T072, when its library exists; its absence is
#      named, never silent). The claim Role is the one the lock file selects: first-party →
#      claims/first-party (agentic-netops-allocation), kuid → claims/kuid (kuid-system)
#   4  boundary: the probes run AFTER every apply; a probe failure is non-zero naming the denial;
#      an apply failure never reaches the probes
# The order check is itself shown able to fail (negative control on a reordered call log).
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok()  { printf 'PASS %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 15 | sed 's/^/    /'; }
for tool in jq yq python3; do command -v "$tool" >/dev/null || { echo "FAIL prerequisite: $tool"; exit 1; }; done

# make_tree <dir> <first-party|kuid> [with-secrets]
make_tree() {
  local t="$1"
  mkdir -p "$t/scripts" "$t/deploy" "$t/tests/integration" "$t/bin" "$t/state"
  cp -r "$ROOT/scripts/lib" "$t/scripts/lib"
  rm -f "$t/scripts/lib/intent_secrets.sh"
  cp -r "$ROOT/deploy/rbac" "$t/deploy/rbac"
  cp "$ROOT/versions.lock.yaml" "$t/versions.lock.yaml"
  case "$2" in
    kuid) yq -i '.allocationAuthority = {"kind": "kuid"}' "$t/versions.lock.yaml" ;;
    first-party) yq -i '.allocationAuthority.kind = "first-party"' "$t/versions.lock.yaml" ;;
  esac
  if [[ "${3:-}" == with-secrets ]]; then
    cat >"$t/scripts/lib/intent_secrets.sh" <<'EOF'
intent_secrets::ensure_all() { echo "SECRETS ensure_all" >>"$FAKE_STATE/calls.log"; [[ -z "${FAKE_SECRETS_FAIL:-}" ]]; }
EOF
  fi
  cat >"$t/tests/integration/boundary_probes.sh" <<'EOF'
echo "PROBES run" >>"$FAKE_STATE/calls.log"
exit "${FAKE_PROBES_RC:-0}"
EOF
  cat >"$t/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
S="$FAKE_STATE"
args="$*"
if [[ "$args" == *" apply "* ]]; then
  n=$(( $(ls "$S" | grep -c '^apply-') + 1 ))
  f=""; prev=""
  for a in "$@"; do [[ "$prev" == -f ]] && f="$a"; prev="$a"; done
  if [[ "$f" == - ]]; then cat >"$S/apply-$(printf %02d "$n").yaml"; echo "APPLY - (stdin)" >>"$S/calls.log"
  else cp "$f" "$S/apply-$(printf %02d "$n").yaml"; echo "APPLY ${f#"$TREE"/}" >>"$S/calls.log"; fi
  [[ -n "${FAKE_APPLY_FAIL:-}" && "$f" == *"$FAKE_APPLY_FAIL"* ]] && { echo "fake apply failure" >&2; exit 1; }
  exit 0
fi
echo "kubectl $args" >>"$S/calls.log"
case "$args" in
  *"get endpointslices -n default -l kubernetes.io/service-name=kubernetes -o json"*)
    jq -n --arg a "${FAKE_APISERVER:-172.30.0.3}" '{items: [{ports: [{name: "https", port: 6443, protocol: "TCP"}], endpoints: [{addresses: [$a], conditions: {ready: true}}]}]}' ;;
  *"get configmap kubeadm-config -n kube-system -o json"*)
    [[ -n "${FAKE_NO_KUBEADM:-}" ]] && exit 1
    jq -n '{data: {ClusterConfiguration: "apiVersion: kubeadm.k8s.io/v1beta4\nnetworking:\n  dnsDomain: cluster.local\n  podSubnet: 10.244.0.0/16\n  serviceSubnet: 10.96.0.0/16\n"}}' ;;
  *"get validatingadmissionpolicy deny-tier-force-release -o json"*)
    if [[ -n "${FAKE_VAP_WARN:-}" ]]; then
      echo '{"metadata":{"generation":1},"status":{"observedGeneration":1,"typeChecking":{"expressionWarnings":[{"fieldRef":"spec.validations[0].expression","warning":"no such key: annotation"}]}}}'
    else echo '{"metadata":{"generation":1},"status":{"observedGeneration":1,"typeChecking":{}}}'; fi ;;
  *"get validatingadmissionpolicybinding deny-tier-force-release -o name"*) echo validatingadmissionpolicybinding.admissionregistration.k8s.io/deny-tier-force-release ;;
  *) echo "fake kubectl: unexpected $args" >&2; exit 99 ;;
esac
EOF
  cat >"$t/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"$FAKE_STATE/calls.log"
if [[ "$1 $2" == "network inspect" && "$3" == "agentic-netops-mgmt" && -z "${FAKE_NO_NET:-}" ]]; then
  jq -n --arg s "${FAKE_SUBNET:-172.25.25.0/24}" '[{Name: "agentic-netops-mgmt", IPAM: {Config: [{Subnet: "fd00::/64"}, {Subnet: $s}]}}]'; exit 0
fi
echo "Error: No such network: $3" >&2; exit 1
EOF
  chmod +x "$t/bin/kubectl" "$t/bin/docker"
}

# go <tree> <cmd…> — run rbac.sh in the tree with its fakes, fresh state; sets out rc
go() {
  local t="$1"; shift
  rm -rf "$t/state" "$t/ev"; mkdir -p "$t/state"; : >"$t/state/calls.log"
  out="$(cd "$t" && PATH="$t/bin:$PATH" FAKE_STATE="$t/state" TREE="$t" CLUSTER_NAME=agentic-netops RBAC_WAIT_TIMEOUT=2 \
    EVIDENCE_LAB=unit-lab EVIDENCE_ROOT="$t/ev" EVIDENCE_DIR= \
    bash "$t/scripts/lib/rbac.sh" "$@" 2>&1)"; rc=$?
  calls="$(cat "$t/state/calls.log")"
}
applies() { grep -c '^APPLY' <<<"$calls"; }

# order_ok <calls> — the applies (and the secrets/probes markers) in the required order
order_ok() {
  local want=("APPLY deploy/rbac/namespaces.yaml" "APPLY deploy/rbac/serviceaccounts.yaml" "APPLY deploy/rbac/roles.yaml"
              "APPLY deploy/rbac/claims/" "APPLY - (stdin)" "APPLY deploy/rbac/deny-tier-force-release.yaml")
  local seq w i=0
  seq="$(grep -E '^(APPLY|SECRETS|PROBES)' <<<"$1")"
  for w in "${want[@]}"; do
    i=$((i + 1))
    [[ "$(sed -n "${i}p" <<<"$seq")" == "$w"* ]] || { echo "position $i: want '$w', got '$(sed -n "${i}p" <<<"$seq")'"; return 1; }
  done
}

FP="$T/fp"; make_tree "$FP" first-party with-secrets
KU="$T/ku"; make_tree "$KU" kuid
NS="$T/ns"; make_tree "$NS" first-party

# ---- 1. render
go "$FP" render
if [[ $rc -eq 0 ]]; then
  doc() { yq -o=json "select(.metadata.name == \"$1\")" <<<"$out"; }
  names="$(yq -r 'select(.kind == "NetworkPolicy") | .metadata.name' <<<"$out" | grep -v '^---$' | sort | paste -sd' ' -)"
  [[ "$names" == "allow-egress-scoped apiserver-egress-cluster-clients deny-all-by-default slim-ingress" ]] \
    && ok "exactly the four NetworkPolicies of T070" || bad "policy names: $names"
  doc allow-egress-scoped | jq -e '.spec.podSelector == {} and .spec.policyTypes == ["Egress"] and (.spec.egress | length) == 3
      and .spec.egress[0].to == [{ipBlock: {cidr: "0.0.0.0/0", except: ["172.25.25.0/24", "10.244.0.0/16", "10.96.0.0/16", "172.30.0.3/32"]}}]
      and (.spec.egress[0] | has("ports") | not)' >/dev/null \
    && ok "allow-egress-scoped: 0.0.0.0/0 except the whole MGMT_CIDR (from the docker network), the pod and service subnets and the API server; no port list, no protocol" \
    || bad "allow-egress-scoped" "$(doc allow-egress-scoped)"
  doc allow-egress-scoped | jq -e '.spec.egress[1] == {to: [{podSelector: {}}]}
      and .spec.egress[2] == {to: [{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": "kube-system"}}, podSelector: {matchLabels: {"k8s-app": "kube-dns"}}}],
                              ports: [{protocol: "UDP", port: 53}, {protocol: "TCP", port: 53}]}
      and ([.spec.egress[] | .to[] | select(.ipBlock)] | length) == 1' >/dev/null \
    && ok "inside the cluster only the tier's own namespace and the cluster DNS (53 UDP/TCP); no other ipBlock opens anything" \
    || bad "allow-egress-scoped in-cluster rules" "$(doc allow-egress-scoped)"
  doc deny-all-by-default | jq -e '.spec.podSelector == {} and .spec.policyTypes == ["Ingress","Egress"] and (.spec | has("ingress") or has("egress") | not)' >/dev/null \
    && ok "deny-all-by-default: every pod, ingress and egress, no rule" || bad "deny-all-by-default"
  doc slim-ingress | jq -e '.spec.podSelector.matchLabels == {"app.kubernetes.io/name": "slim"} and .spec.ingress == [{from: [{podSelector: {matchLabels: {"agentic-netops.io/tier": "intent"}}}], ports: [{protocol: "TCP", port: 46357}]}]' >/dev/null \
    && ok "slim-ingress: 46357/TCP from tier-labelled pods only" || bad "slim-ingress" "$(doc slim-ingress)"
  doc apiserver-egress-cluster-clients | jq -e '.spec.podSelector.matchExpressions == [{key: "agentic-netops.io/identity", operator: "In", values: ["intent-deployer","intent-allocator"]}]
      and .spec.egress == [{to: [{ipBlock: {cidr: "172.30.0.3/32"}}], ports: [{protocol: "TCP", port: 6443}]}]' >/dev/null \
    && ok "apiserver-egress-cluster-clients: the two identity pods only, the endpoint /32 on 6443" || bad "apiserver policy" "$(doc apiserver-egress-cluster-clients)"
  grep -v '^#' <<<"$out" | grep -q '__' && bad "a placeholder survived rendering" || ok "no placeholder left in the rendered policies"
else
  bad "render failed" "$out"
fi
FAKE_SUBNET=10.99.0.0/24 MGMT_CIDR= go "$FP" render
yq -o=json 'select(.metadata.name == "allow-egress-scoped")' <<<"$out" | jq -e '.spec.egress[0].to[0].ipBlock.except[0] == "10.99.0.0/24"' >/dev/null \
  && ok "the CIDR follows the real docker network (10.99.0.0/24), never a default" || bad "subnet not followed" "$out"

# ---- 2. refusals with zero applies
MGMT_CIDR=172.25.26.0/24 go "$FP" apply
[[ $rc -ne 0 && $(applies) -eq 0 ]] && grep -q 'MGMT_CIDR=172.25.26.0/24 but the docker network' <<<"$out" \
  && ok "MGMT_CIDR differing from the docker network is refused, zero applies" || bad "cidr mismatch" "$out"
FAKE_NO_NET=1 go "$FP" apply
[[ $rc -ne 0 && $(applies) -eq 0 ]] && grep -q 'never assumed' <<<"$out" && ok "no readable docker network: refused, zero applies" || bad "no network" "$out"
FAKE_APISERVER=172.25.25.128 go "$FP" apply
[[ $rc -ne 0 && $(applies) -eq 0 ]] && grep -q 'inside the management CIDR' <<<"$out" \
  && ok "an API server endpoint inside the management CIDR is refused, zero applies" || bad "apiserver inside cidr" "$out"
FAKE_NO_KUBEADM=1 go "$FP" apply
[[ $rc -ne 0 && $(applies) -eq 0 ]] && grep -q 'pod and service subnets' <<<"$out" \
  && ok "unreadable pod/service subnets: refused, zero applies (never a guess)" || bad "no kubeadm-config" "$out"
FAKE_VAP_WARN=1 go "$FP" apply
[[ $rc -ne 0 ]] && grep -q 'does not type-check cleanly' <<<"$out" && ! grep -q '^SECRETS' <<<"$calls" \
  && ok "an admission policy with a type-check warning stops the apply before the Secrets" || bad "vap warning" "$out"

# ---- 3. order, authority, secrets
go "$FP" apply
if [[ $rc -eq 0 ]] && why="$(order_ok "$calls")"; then ok "apply order: namespaces, SAs, intent-writer, claim Role, policies, admission policy"; else bad "apply order" "${why:-}$out"; fi
grep -q '^APPLY deploy/rbac/claims/first-party/role.yaml' <<<"$calls" && ! grep -q 'claims/kuid' <<<"$calls" \
  && ok "first-party lock → deploy/rbac/claims/first-party/role.yaml only" || bad "first-party claim role" "$calls"
[[ "$(grep -E '^(APPLY|SECRETS)' <<<"$calls" | tail -1)" == "SECRETS ensure_all" ]] && ok "T072's intent_secrets::ensure_all runs after the boundary objects" || bad "secrets step" "$calls"
grep -q 'server-side' <<<"$(cat "$ROOT/scripts/lib/rbac.sh")" && ok "every apply is server-side under one field manager" || bad "server-side"
bad_log="$(sed 's/APPLY deploy\/rbac\/roles.yaml/APPLY deploy\/rbac\/XX/; s/APPLY deploy\/rbac\/serviceaccounts.yaml/APPLY deploy\/rbac\/roles.yaml/' <<<"$calls")"
order_ok "$bad_log" >/dev/null && bad "negative control: a reordered call log passed the order check" || ok "negative control: the order check fails on a reordered call log"
go "$KU" apply
grep -q '^APPLY deploy/rbac/claims/kuid/role.yaml' <<<"$calls" && ! grep -q 'claims/first-party' <<<"$calls" \
  && ok "kuid lock → deploy/rbac/claims/kuid/role.yaml only (T182's seam)" || bad "kuid claim role" "$calls"
grep -q 'T072 not present: scripts/lib/intent_secrets.sh is absent' <<<"$out" && [[ $rc -eq 0 ]] \
  && ok "without T072's library the Secrets step is named as not done, never silent" || bad "absent secrets lib" "$out"
FAKE_SECRETS_FAIL=1 go "$FP" apply
[[ $rc -ne 0 ]] && grep -q "secret step" <<<"$out" && ok "a failing Secrets step fails the apply" || bad "secrets failure" "$out"

# ---- 4. boundary
go "$FP" boundary
if [[ $rc -eq 0 && "$(grep -E '^(APPLY|SECRETS|PROBES)' <<<"$calls" | tail -1)" == "PROBES run" ]] && order_ok "$calls" >/dev/null; then
  ok "boundary: every apply, then the probes, last"
else bad "boundary order" "$calls"; fi
rec="$(find "$FP/ev" -name rbac.apply.json | head -1)"
[[ -n "$rec" ]] && jq -e '.exit_status == 0 and (.command | index("apply") != null)' "$rec" >/dev/null \
  && ok "boundary: the apply is run-captured (evidence_run rbac.apply) in the run's evidence directory" || bad "apply not captured" "$(find "$FP/ev" | head)"
FAKE_PROBES_RC=1 go "$FP" boundary
[[ $rc -ne 0 ]] && grep -q 'a denial was NOT observed' <<<"$out" && ok "a probe failure aborts non-zero naming the unobserved denial" || bad "probe failure" "$out"
FAKE_APPLY_FAIL=roles.yaml go "$FP" boundary
[[ $rc -ne 0 ]] && ! grep -q '^PROBES' <<<"$calls" && ok "an apply failure never reaches the probes" || bad "apply failure reached probes" "$calls"
go "$FP" bogus; [[ $rc -eq 2 ]] && ok "unknown command: usage, exit 2" || bad "usage" "$out"

echo "rbac_test: $fails failure(s)"
[[ "$fails" -eq 0 ]]
