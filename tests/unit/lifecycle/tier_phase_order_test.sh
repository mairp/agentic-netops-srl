#!/usr/bin/env bash
# tier_phase_order_test.sh — the up path's install order of the IntentTierReady phase (T174's second
# file, for T088; FR-078, NFR-012, AD-45, AD-64; data-model.md §16). Offline: scripts/provision.sh
# is SOURCED (its test hook defines the phases and runs nothing) and provision::phase_IntentTierReady
# is called against the fake kubectl of tier_fakes.sh; T073's boundary step (rbac::boundary, which
# applies the boundary and runs the denial probes) and T169's image builds are replaced by stubs that
# record when they ran; the manifests are a fixture set of deploy/agents/ (INTENT_TIER_MANIFEST_DIR).
#
#   O1  clickhouse and agent-otel-collector are applied and waited Ready AFTER the denial probes and
#       BEFORE the first apply of any agent workload (supervisor, mapper, allocator, deployer); slim
#       between them; the four images built before any agent workload; ui neither built nor applied
#   O2  a store that never becomes Ready stops the phase non-zero with no agent workload applied
#       (and a collector that never becomes Ready likewise)
#   O3  failing denial probes: nothing of the tier's workloads applied
#   O4  the preflight: the fabric threshold plus the requests SUMMED from the manifests (never typed:
#       a fixture change moves the named sum); a shortfall fails before any mutation, naming it
#   O5  site-inventory written from the Fabric's inventory (roles joined from spec.nodes);
#       fabric-qualification copied from agentic-netops-system
#   O6  the supervisor published on 127.0.0.1 only: NodePort 30990 asserted, the URL stated; a
#       different NodePort fails the phase
#   O7  the operator-credentials username — never the password — captured through evidence_run
#       (operator-username-<attempt>) on every provisioning run
# shellcheck disable=SC2034,SC2207 # the variables are read inside check's eval strings
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=fakes.sh
source "$ROOT/tests/unit/lifecycle/fakes.sh"
# shellcheck source=tier_fakes.sh
source "$ROOT/tests/unit/lifecycle/tier_fakes.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; [[ -n "${out:-}" ]] && printf '%s\n' "$out" | tail -n 12 | sed 's/^/    | /'; fi; }

CL=agentic-netops LAB=agentic-netops-fabric AG=agentic-netops-agents IN=agentic-netops-intent SYS=agentic-netops-system
OPW='Op3rator-password-never-shown-7x'
ORIG_PATH="$PATH"

deploy_yaml() { # <name> <cpu> <mem> [replicas] [kind]
  cat <<EOF
apiVersion: apps/v1
kind: ${5:-Deployment}
metadata:
  name: $1
  namespace: $AG
  labels: {app.kubernetes.io/name: $1, agentic-netops.io/tier: intent}
spec:
  replicas: ${4:-1}
  template:
    spec:
      containers:
        - name: $1
          image: $1:0000
          resources:
            requests: {cpu: "$2", memory: "$3"}
            limits: {cpu: "1", memory: "1Gi"}
---
apiVersion: v1
kind: Service
metadata: {name: $1, namespace: $AG}
spec: {ports: [{port: 80}]}
EOF
}
# fixture manifests: requests 500m+100m+100m+4x250m = 1700m CPU; 1Gi+128Mi+64Mi+4x256Mi = 2240 MiB
manifests() { # <dir> [supervisor replicas] [supervisor nodePort]
  local d="$1" sr="${2:-1}" np="${3:-30990}"
  mkdir -p "$d"
  deploy_yaml clickhouse 500m 1Gi 1 StatefulSet >"$d/clickhouse.yaml"
  { printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: agent-otel-collector-config, namespace: %s}\ndata: {}\n---\n' "$AG"
    deploy_yaml agent-otel-collector 0.1 128Mi; } >"$d/agent-otel-collector.yaml"
  { printf 'apiVersion: cert-manager.io/v1\nkind: Issuer\nmetadata: {name: slim-selfsigned, namespace: %s}\nspec: {selfSigned: {}}\n---\n' "$AG"
    deploy_yaml slim 100m 64Mi; } >"$d/slim.yaml"
  { printf 'apiVersion: v1\nkind: PersistentVolumeClaim\nmetadata: {name: supervisor-checkpoint, namespace: %s}\nspec: {resources: {requests: {storage: 1Gi}}}\n---\n' "$AG"
    deploy_yaml supervisor 250m 256Mi "$sr" | sed "s/ports: \[{port: 80}\]/type: NodePort, ports: [{port: 9090, nodePort: $np}]/"; } >"$d/supervisor.yaml"
  local w
  for w in mapper allocator deployer; do deploy_yaml "$w" 250m 256Mi >"$d/$w.yaml"; done
  printf 'apiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata: {name: allow-otlp-to-collector, namespace: %s}\nspec: {podSelector: {}}\n' "$AG" >"$d/networkpolicies-workloads.yaml"
  cat >"$d/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - networkpolicies-workloads.yaml
  - clickhouse.yaml
  - agent-otel-collector.yaml
  - slim.yaml
  - supervisor.yaml
  - mapper.yaml
  - allocator.yaml
  - deployer.yaml
EOF
}

setup() { # <case>
  W="$T/$1"
  rm -rf "$W"; mkdir -p "$W"
  fakes::install "$W"
  tier_fakes::install "$W"
  export FAKE_STATE="$W/state" PATH="$W/bin:$ORIG_PATH" EVIDENCE_ROOT="$W/evidence" AGENTIC_NETOPS_ENV_FILE="$W/no.env"
  unset EVIDENCE_DIR CLUSTER_NAME || true
  local n
  for n in spine01 spine02 leaf01 leaf02; do fakes::container "clab-$LAB-$n" "$LAB" nokia_srlinux "$CL"; done
  for n in client01 client02; do fakes::container "clab-$LAB-$n" "$LAB" linux "$CL"; done
  fakes::cluster "$CL" "$CL"
  fakes::k8s "$CL" _ namespace "$SYS" "$CL"
  fakes::k8s "$CL" _ namespace "$AG" "$CL"      # the boundary step's (stubbed here)
  fakes::k8s "$CL" _ namespace "$IN" "$CL"
  fakes::k8s "$CL" "$AG" secret operator-credentials "$CL" \
    "$(jq -cn --arg u "$(printf operator | base64)" --arg p "$(printf '%s' "$OPW" | base64)" '{data: {username: $u, password: $p}}')"
  tier_fakes::obj "$CL" "$SYS" fabric '{"apiVersion":"fabric.agentic-netops.io/v1alpha1","kind":"Fabric","metadata":{"name":"fabric01","namespace":"agentic-netops-system"},
    "spec":{"nodes":[{"name":"leaf01","role":"leaf"},{"name":"leaf02","role":"leaf"},{"name":"spine01","role":"spine"}],
            "inventory":[{"node":"leaf01","accessPorts":["ethernet-1/1","ethernet-1/2"],"untaggedAccessPorts":["ethernet-1/2"],"fabricPorts":["ethernet-1/49"]},
                         {"node":"leaf02","accessPorts":["ethernet-1/1"],"fabricPorts":["ethernet-1/49"]},
                         {"node":"spine01","accessPorts":[],"fabricPorts":["ethernet-1/1"]}]}}'
  fakes::k8s "$CL" "$SYS" configmap fabric-qualification "$CL" '{"data":{"qualification.json":"{\"gate\":{\"result\":\"pass\"}}","vlan":"qualified"}}'
  MAN="$W/agents"; manifests "$MAN"
  printf 'MemTotal: 67108864 kB\nMemAvailable: 67108864 kB\n' >"$W/meminfo"
}

# phase — provision::phase_IntentTierReady with the boundary step and the image builds stubbed
phase() {
  : >"$FAKE_STATE/calls.log"
  out="$(cd "$ROOT" && INTENT_TIER_MANIFEST_DIR="$MAN" PREFLIGHT_MEMINFO="${MEMINFO:-$W/meminfo}" PREFLIGHT_NPROC="${NPROC:-16}" \
    INTENT_TIER_WAIT_TIMEOUT=5 bash -c '
      source scripts/provision.sh
      source scripts/lib/rbac.sh
      provision::defaults
      rbac::boundary() { echo "PROBES boundary applied, denial probes run" >>"$FAKE_STATE/calls.log"; return "${FAKE_PROBES_RC:-0}"; }
      image_build::build() { echo "BUILD $1 $2" >>"$FAKE_STATE/calls.log"; printf "%s:%064d\n" "$1" 0; }
      provision::phase_IntentTierReady' 2>&1)"
  rc=$?
}
L() { cat "$FAKE_STATE/calls.log"; }
line_of() { grep -nE -m1 -- "$1" "$FAKE_STATE/calls.log" | cut -d: -f1; }
lt() { [[ -n "$1" && -n "$2" && "$1" -lt "$2" ]]; }
AGENT_APPLY='^APPLY Deployment/(supervisor|mapper|allocator|deployer)$'
cm() { jq -r --arg k "$2" '.data[$k]' "$FAKE_STATE/k8s/$CL/$AG/configmap/$1.json"; }

# ================================================================== O1 — the order
setup order
phase
check "O1 the phase succeeds on a healthy fake" '[[ $rc -eq 0 ]]'
p="$(line_of '^PROBES')"
a_ch="$(line_of '^APPLY StatefulSet/clickhouse$')"; a_col="$(line_of '^APPLY Deployment/agent-otel-collector$')"
w_ch="$(line_of '^kubectl .* rollout status statefulset/clickhouse')"; w_col="$(line_of '^kubectl .* rollout status deployment/agent-otel-collector')"
a_slim="$(line_of '^APPLY Deployment/slim$')"
a_agent="$(line_of "$AGENT_APPLY")"
check "O1 the denial probes run before anything of the tier's workloads is applied" '[[ -n "$p" ]] && ! head -n "$p" "$FAKE_STATE/calls.log" | grep -q "^APPLY"'
check "O1 clickhouse and agent-otel-collector are applied AFTER the denial probes" 'lt "$p" "$a_ch" && lt "$p" "$a_col"'
check "O1 …and waited Ready after being applied" 'lt "$a_ch" "$w_ch" && lt "$a_col" "$w_col"'
check "O1 …both waited Ready BEFORE the first apply of any agent workload" 'lt "$w_ch" "$a_agent" && lt "$w_col" "$a_agent"'
check "O1 slim (the transport) comes after the store is Ready and before the agents" 'lt "$w_ch" "$a_slim" && lt "$a_slim" "$a_agent"'
check "O1 every agent workload is applied (supervisor, mapper, allocator, deployer)" \
  '[[ "$(grep -cE "$AGENT_APPLY" "$FAKE_STATE/calls.log")" -eq 4 ]]'
check "O1 the four images are built through image_build::build <name> <kustomization dir> before any agent workload" \
  '[[ "$(grep -c "^BUILD .* $MAN$" "$FAKE_STATE/calls.log")" -eq 4 ]] && lt "$(line_of "^BUILD deployer")" "$a_agent" && lt "$p" "$(line_of "^BUILD")"'
check "O1 ui is neither built nor applied (no Deployment until T126)" '! grep -qE "^BUILD ui|APPLY Deployment/ui" "$FAKE_STATE/calls.log"'
check "O1 the agents are waited Ready" 'grep -qE "rollout status deployment/supervisor" "$FAKE_STATE/calls.log" && grep -qE "rollout status deployment/deployer" "$FAKE_STATE/calls.log"'

# ================================================================== O5 — site inventory, qualification
check "O5 site-inventory is applied after the probes" 'lt "$p" "$(line_of "^APPLY ConfigMap/site-inventory$")"'
check "O5 site-inventory inventory.json is derived from the Fabric's spec.inventory with roles from spec.nodes" \
  '[[ "$(cm site-inventory inventory.json | jq -cS .)" == "$(jq -cS . <<<"{\"nodes\":[{\"name\":\"leaf01\",\"role\":\"leaf\",\"accessPorts\":[\"ethernet-1/1\",\"ethernet-1/2\"],\"untaggedAccessPorts\":[\"ethernet-1/2\"]},{\"name\":\"leaf02\",\"role\":\"leaf\",\"accessPorts\":[\"ethernet-1/1\"],\"untaggedAccessPorts\":[]},{\"name\":\"spine01\",\"role\":\"spine\",\"accessPorts\":[],\"untaggedAccessPorts\":[]}]}")" ]]'
check "O5 fabric-qualification is copied from agentic-netops-system into agentic-netops-agents, data unchanged" \
  '[[ "$(jq -cS .data "$FAKE_STATE/k8s/$CL/$AG/configmap/fabric-qualification.json")" == "$(jq -cS .data "$FAKE_STATE/k8s/$CL/$SYS/configmap/fabric-qualification.json")" ]]'

# ================================================================== O6 — published on loopback only
check "O6 the supervisor NodePort 30990 is asserted and the loopback URL stated" 'grep -q "30990" <<<"$out" && grep -q "http://127.0.0.1:19090" <<<"$out"'

# ================================================================== O7 — the username capture
UF="$(find "$EVIDENCE_ROOT" -name 'operator-username-*.stdout' | head -1)"
check "O7 the operator username is captured through evidence_run (operator-username-<attempt>)" \
  '[[ -n "$UF" ]] && grep -qx "username: operator" "$UF" && jq -e ".exit_status == 0" "${UF%.stdout}.json" >/dev/null'
check "O7 the password is never captured, printed or passed" '! grep -rqF "$OPW" "$EVIDENCE_ROOT" && ! grep -qF "$OPW" <<<"$out" && ! grep -qF "$OPW" "$FAKE_STATE/calls.log"'
phase
check "O7 …on every provisioning run (a second run adds a second capture)" '[[ $rc -eq 0 && "$(find "$EVIDENCE_ROOT" -name "operator-username-*.json" | wc -l)" -eq 2 ]]'

# ================================================================== O2 — a store that never becomes Ready
setup store-never-ready
mkdir -p "$FAKE_STATE/never-ready"; touch "$FAKE_STATE/never-ready/statefulset-clickhouse"
phase
check "O2 a store that never becomes Ready stops the phase non-zero" '[[ $rc -ne 0 ]]'
check "O2 …with no agent workload applied (nor slim)" '! grep -qE "$AGENT_APPLY|^APPLY Deployment/slim$" "$FAKE_STATE/calls.log"'
check "O2 …naming the store" 'grep -q "clickhouse" <<<"$out"'
setup collector-never-ready
mkdir -p "$FAKE_STATE/never-ready"; touch "$FAKE_STATE/never-ready/deployment-agent-otel-collector"
phase
check "O2 a collector that never becomes Ready stops the phase with no agent workload applied" '[[ $rc -ne 0 ]] && ! grep -qE "$AGENT_APPLY" "$FAKE_STATE/calls.log"'

# ================================================================== O3 — the probes fail
setup probes-fail
FAKE_PROBES_RC=1 phase
check "O3 failing denial probes: non-zero, nothing of the tier's workloads applied, no image built" \
  '[[ $rc -ne 0 ]] && ! grep -q "^APPLY" "$FAKE_STATE/calls.log" && ! grep -q "^BUILD" "$FAKE_STATE/calls.log"'

# ================================================================== O4 — the preflight
setup preflight-ok
phase
check "O4 the preflight names the tier's summed requests (1700m CPU, 2240 MiB) computed from the manifests" 'grep -q "1700m" <<<"$out" && grep -q "2240 MiB" <<<"$out"'
setup preflight-short
printf 'MemTotal: 2097152 kB\nMemAvailable: 1024000 kB\n' >"$W/meminfo"
phase
check "O4 a shortfall fails the phase non-zero" '[[ $rc -ne 0 ]]'
check "O4 …before any mutation: no boundary step, no apply, no build" '! grep -qE "^(PROBES|APPLY|BUILD)" "$FAKE_STATE/calls.log" && ! grep -qE "^kubectl .* (apply|delete|scale|create|patch) " "$FAKE_STATE/calls.log"'
check "O4 …naming the shortfall (1000 MiB available, 2240 MiB required, 1240 MiB short)" 'grep -q "1240 MiB short" <<<"$out" && grep -q "2240 MiB" <<<"$out"'
setup preflight-cpu-short
NPROC=1 phase
check "O4 a CPU shortfall is named too (2 vCPU for 1700m, 1 available)" '[[ $rc -ne 0 ]] && grep -q "1 vCPU short" <<<"$out" && ! grep -q "^PROBES" "$FAKE_STATE/calls.log"'
setup preflight-not-typed
manifests "$MAN" 3
phase
check "O4 the sum is computed, never typed: three supervisor replicas move it to 2200m / 2752 MiB" 'grep -q "2200m" <<<"$out" && grep -q "2752 MiB" <<<"$out"'

# ================================================================== O6 — a wrong NodePort
setup wrong-nodeport
manifests "$MAN" 1 31990
phase
check "O6 a supervisor NodePort other than 30990 (the only one Kind publishes, on 127.0.0.1) fails the phase" '[[ $rc -ne 0 ]] && grep -q "30990" <<<"$out"'

printf '\ntier_phase_order_test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
