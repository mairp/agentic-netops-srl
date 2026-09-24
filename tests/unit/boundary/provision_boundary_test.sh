#!/usr/bin/env bash
# tests/unit/boundary/provision_boundary_test.sh — IntentTierReady's boundary step in
# scripts/provision.sh (T073; FR-075, SC-029, CR-007), offline: provision.sh is SOURCED from a copy
# of the tree (its test hook defines the phases and runs nothing) and the phase is called against a
# fake kubectl / docker, with the probe suite replaced by a stub that records when it ran:
#   1  probes pass → the boundary is applied (namespaces, ServiceAccounts, intent-writer, the claim
#      Role, the policies, the admission policy), the probes run AFTER every apply, and the phase
#      STILL fails, naming what is not built (the tier's workloads, T088) — never a silent pass;
#      nothing under deploy/agents/ is applied
#   2  probes fail → the phase fails naming the boundary step; no agent workload applied
#   3  an apply failure → the probes never run; the phase fails
#   4  the phase is not in the default phase list: only --with-intent-tier runs it, after the rest
#   5  negative control: a phase that returned 0 would be caught by the same assertion
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok()  { printf 'PASS %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 15 | sed 's/^/    /'; }

TR="$T/tree"
mkdir -p "$TR/scripts" "$TR/deploy/agents" "$TR/tests/integration" "$TR/bin" "$TR/state"
cp -r "$ROOT/scripts/lib" "$TR/scripts/lib"
cp "$ROOT/scripts/provision.sh" "$TR/scripts/provision.sh"
rm -f "$TR/scripts/lib/intent_secrets.sh"
cp -r "$ROOT/deploy/rbac" "$TR/deploy/rbac"
cp "$ROOT/versions.lock.yaml" "$TR/versions.lock.yaml"
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: supervisor}\n' >"$TR/deploy/agents/supervisor.yaml"
cat >"$TR/tests/integration/boundary_probes.sh" <<'EOF'
echo "PROBES run" >>"$FAKE_STATE/calls.log"
exit "${FAKE_PROBES_RC:-0}"
EOF
cat >"$TR/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
S="$FAKE_STATE"
if [[ "$*" == *" apply "* ]]; then
  f=""; prev=""; for a in "$@"; do [[ "$prev" == -f ]] && f="$a"; prev="$a"; done
  [[ "$f" == - ]] && { cat >/dev/null; f="(stdin)"; }
  echo "APPLY ${f#"$TREE"/}" >>"$S/calls.log"
  [[ -n "${FAKE_APPLY_FAIL:-}" && "$f" == *"$FAKE_APPLY_FAIL"* ]] && exit 1
  exit 0
fi
echo "kubectl $*" >>"$S/calls.log"
case "$*" in
  *"get endpointslices"*) echo '{"items":[{"ports":[{"name":"https","port":6443}],"endpoints":[{"addresses":["172.30.0.3"],"conditions":{"ready":true}}]}]}' ;;
  *"get configmap kubeadm-config"*) jq -n '{data: {ClusterConfiguration: "networking:\n  podSubnet: 10.244.0.0/16\n  serviceSubnet: 10.96.0.0/16\n"}}' ;;
  *"get validatingadmissionpolicy deny-tier-force-release -o json"*) echo '{"metadata":{"generation":1},"status":{"observedGeneration":1}}' ;;
  *"get validatingadmissionpolicybinding"*) echo ok ;;
  *) exit 1 ;;
esac
EOF
cat >"$TR/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"$FAKE_STATE/calls.log"
[[ "$1 $2" == "network inspect" ]] && { echo '[{"IPAM":{"Config":[{"Subnet":"172.25.25.0/24"}]}}]'; exit 0; }
exit 1
EOF
chmod +x "$TR/bin/kubectl" "$TR/bin/docker"

phase() { # runs provision::phase_IntentTierReady in a subshell; sets out rc calls
  : >"$TR/state/calls.log"
  out="$(cd "$TR" && PATH="$TR/bin:$PATH" FAKE_STATE="$TR/state" TREE="$TR" RBAC_WAIT_TIMEOUT=2 EVIDENCE_DIR="$T/ev" bash -c '
    source scripts/provision.sh
    provision::defaults
    provision::phase_IntentTierReady' 2>&1)"; rc=$?
  calls="$(cat "$TR/state/calls.log")"
}
seq_of() { grep -E '^(APPLY|PROBES)' <<<"$calls"; }
# judge_phase <rc> <out> — the phase's verdict when the probes passed: non-zero, naming T088
judge_phase() { [[ "$1" -ne 0 ]] && grep -q 'not built yet' <<<"$2" && grep -q 'T088' <<<"$2" && grep -q 'was NOT installed' <<<"$2"; }

# 1
phase
if judge_phase "$rc" "$out"; then ok "probes pass → the phase still FAILS naming what is not built (T088), never a silent pass"; else bad "phase verdict with passing probes (rc=$rc)" "$out"; fi
s="$(seq_of)"
if [[ "$(head -1 <<<"$s")" == "APPLY deploy/rbac/namespaces.yaml" && "$(tail -1 <<<"$s")" == "PROBES run" ]] \
   && grep -q 'APPLY deploy/rbac/claims/first-party/role.yaml' <<<"$s" && grep -q 'APPLY deploy/rbac/deny-tier-force-release.yaml' <<<"$s" \
   && grep -q 'APPLY (stdin)' <<<"$s"; then
  ok "the boundary is applied (namespaces first … admission policy), then the probes run last"
else bad "boundary step order" "$s"; fi
grep -q 'deploy/agents' <<<"$calls" && bad "an agent workload was applied" "$calls" || ok "nothing under deploy/agents/ is applied: no agent workload before or after the probes"
grep -q 'T072 not present' <<<"$out" && ok "the absent secret library is named in the phase output" || bad "secrets absence not named" "$out"
# 5 negative control of judge_phase
judge_phase 0 "$out" && bad "negative control: a phase returning 0 was judged a correct refusal" || ok "negative control: a phase returning 0 is caught by the same assertion"

# 2
FAKE_PROBES_RC=1 phase
[[ $rc -ne 0 ]] && grep -q 'the boundary step failed' <<<"$out" && grep -q 'a denial was NOT observed' <<<"$out" \
  && ok "probes fail → the phase fails naming the boundary step and the unobserved denial" || bad "failing probes" "$out"
grep -q 'deploy/agents' <<<"$calls" && bad "an agent workload was applied after a failed boundary" || ok "a failed boundary creates no agent workload"

# 3
FAKE_APPLY_FAIL="(stdin)" phase
[[ $rc -ne 0 ]] && ! grep -q '^PROBES' <<<"$calls" && ok "an apply failure fails the phase before the probes" || bad "apply failure" "$calls"

# 4
phases="$(cd "$TR" && bash -c 'source scripts/provision.sh; printf "%s " "${PROVISION_PHASES[@]}"')"
[[ "$phases" != *IntentTierReady* ]] && ok "IntentTierReady is not in the default phase list ($phases)" || bad "default phases carry IntentTierReady"
grep -qE 'if \[\[ "\$with_tier" == true \]\]; then' "$ROOT/scripts/provision.sh" && grep -q 'provision::phase_IntentTierReady ||' "$ROOT/scripts/provision.sh" \
  && ok "only --with-intent-tier runs it, after every default phase" || bad "flag wiring"
grep -q 'IntentTierReady  (--with-intent-tier) its boundary step first' "$ROOT/scripts/provision.sh" \
  && ok "the header documents the boundary step and the still-failing rest" || bad "header docs"

echo "provision_boundary_test: $fails failure(s)"
[[ "$fails" -eq 0 ]]
