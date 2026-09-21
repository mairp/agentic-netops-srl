#!/usr/bin/env bash
# verify-boundaries / verify-provenance-headers suite (T025; SC-017, SC-049,
# FR-108, FR-019, CR-008, FR-013, FR-049, FR-085, FR-094, NFR-003; AD-49, AD-57, AD-67).
#
# Each fixture under fixtures/boundaries/<case>/ and fixtures/provenance/<case>/
# is a miniature repository root; the checkers run on it with --root and must
# give the verdict the case was planted for, NAMING THE FILE (and the check).
# The three added checks each have a planted failure and its passing twin:
#   FR-019/CR-008  a stringData password under deploy/ fails naming the file;
#                  the same credential behind a secretKeyRef (and a projected
#                  volume, a generator placeholder) passes
#   FR-013         a planted CronJob fails naming the file; a Role granting
#                  `create` on configs to another ServiceAccount fails naming the
#                  file; the provider's own binding (and deploy/sdc/ vendored RBAC) passes
#   FR-108         a gnmic invocation in scripts/lib/ fails naming that file;
#                  the same line under tests/ (and in a docs/ fenced block) passes
# Finally both checkers pass on this repository itself. Offline; python3 + PyYAML.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
VB="$ROOT/scripts/ci/verify_boundaries.sh"
VP="$ROOT/scripts/ci/verify_provenance_headers.sh"
FB="$HERE/fixtures/boundaries"
FP="$HERE/fixtures/provenance"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

# expect <checker> <fixture-root> <want-rc> <label> [<fixed string the output must contain>…]
expect() {
  local checker="$1" dir="$2" want="$3" label="$4"; shift 4
  local out rc p
  out="$(bash "$checker" --root "$dir" 2>&1)"; rc=$?
  if [[ "$rc" -ne "$want" ]]; then fail "$label (rc=$rc, want $want)" "$out"; return; fi
  for p in "$@"; do
    grep -qF -- "$p" <<<"$out" || { fail "$label (output lacks '$p')" "$out"; return; }
  done
  if [[ "$want" -ne 0 ]]; then
    # every FAIL line is one of the expected ones: a fixture fails for its planted reason only
    local n_fail n_want; n_fail="$(grep -c '^FAIL' <<<"$out")"; n_want=$#
    [[ "$n_fail" -eq "$n_want" ]] || { fail "$label ($n_fail FAIL line(s), want $n_want)" "$out"; return; }
  fi
  pass "$label"
}

# --- FR-019 / CR-008: credential literals under deploy/
expect "$VB" "$FB/cred-stringdata-literal" 1 "credential: stringData password under deploy/ fails naming the file" \
  "FAIL [credential-literal] deploy/agentic-netops/device-credentials.yaml:9: literal credential in 'stringData.password'"
expect "$VB" "$FB/cred-secretkeyref" 0 "credential: same credential via secretKeyRef, projected volume, generator placeholder passes"
expect "$VB" "$FB/cred-env-and-args-literal" 1 "credential: literal env value and argument fail, each naming its file" \
  "FAIL [credential-literal] deploy/agents/tier-worker.yaml:13: env LLM_API_KEY carries a literal value" \
  "FAIL [credential-literal] deploy/observability/collector.yaml:11: literal credential after argument '--password'"

# --- FR-013: orchestration boundary
expect "$VB" "$FB/cronjob" 1 "orchestration: a planted CronJob fails naming the file" \
  "FAIL [orchestration] deploy/agentic-netops/reverify-cronjob.yaml:2: kind CronJob"
expect "$VB" "$FB/rbac-other-sa" 1 "orchestration: Role granting create on configs to another ServiceAccount fails naming the file" \
  "FAIL [orchestration] config/rbac/sequencer-role.yaml:11: RoleBinding config-writer gives ServiceAccount agentic-netops-system/fabric-sequencer a mutating verb on config.sdcio.dev"
expect "$VB" "$FB/rbac-provider-only" 0 "orchestration: provider SA's mutating binding, a read-only binding and vendored deploy/sdc/ RBAC pass"
expect "$VB" "$FB/engine-image-and-lock" 1 "orchestration: an engine image in a manifest and in versions.lock.yaml fail, each named" \
  "FAIL [orchestration] deploy/agentic-netops/sequencer.yaml:10: workflow/pipeline/job-engine image 'quay.io/argoproj/workflow-controller:v3.6.4'" \
  "FAIL [orchestration] versions.lock.yaml:3: workflow/pipeline/job-engine image 'docker.io/apache/airflow'"

# --- FR-108: device clients (SC-049)
expect "$VB" "$FB/device-client-scripts-lib" 1 "device client: gnmic under scripts/lib/ fails naming that file" \
  "FAIL [device-client] scripts/lib/labready.sh:3:"
expect "$VB" "$FB/device-client-under-tests" 0 "device client: the same gnmic line under tests/ and in a docs/ fenced block passes"
expect "$VB" "$FB/device-client-ssh-docker" 1 "device client: docker exec clab-… sr_cli and sshpass/ssh to a mgmt address fail" \
  "FAIL [device-client] hack/debug.sh:2:" "FAIL [device-client] hack/debug.sh:3:"
expect "$VB" "$FB/device-client-readme-fence" 1 "device client: a fenced command block outside docs/ and specs/ fails" \
  "FAIL [device-client] README.md:4:"

# --- SC-017 (a)(c) and FR-085
expect "$VB" "$FB/migration-term" 1 "migration boundary: the NOS vendor's fabric-automation product fails (FR-049)" \
  "FAIL [migration] docs/decisions/0001-controller.md:3:"
expect "$VB" "$FB/retired-name-unlabelled" 1 "retired service name outside a labelled context fails (FR-085)" \
  "FAIL [retired-service] docs/operations/services.md:3:"
expect "$VB" "$FB/retired-name-labelled" 0 "retired service names under a migration-alias heading or labelled line pass"
expect "$VB" "$FB/placement-compose" 1 "placement boundary: a Compose file fails" \
  "FAIL [placement] deploy/docker-compose.yml:1:"

# --- SC-017 (b) reference-artefact mechanical checks
expect "$VB" "$FB/dashboard-raw-url" 1 "reference artefact: raw.githubusercontent.com in a dashboard fails" \
  "FAIL [reference-artefact] deploy/observability/grafana/dashboards/fabric.json:3:"
expect "$VB" "$FB/plugin-unversioned" 1 "reference artefact: a Grafana plugin without a version fails, naming the plugin" \
  "FAIL [reference-artefact] deploy/observability/grafana/grafana.yaml:12: Grafana plugin install without an explicit version: 'nokia-topology-panel'"
expect "$VB" "$FB/plugin-versioned" 0 "reference artefact: every plugin versioned passes"
expect "$VB" "$FB/generator-latest" 1 "reference artefact: generator with version omitted or latest fails" \
  "FAIL [reference-artefact] scripts/topology.sh:2:" "FAIL [reference-artefact] scripts/topology.sh:3:"
expect "$VB" "$FB/generator-pinned" 0 "reference artefact: generator at --drawio-version 0.2.4 passes"
expect "$VB" "$FB/image-latest" 1 "reference artefact: an image at latest fails" \
  "FAIL [reference-artefact] lab/topology.clab.yml:6:"
expect "$VB" "$FB/clean" 0 "a clean tree passes (a comment naming gnmic is not an invocation)"

# --- provenance headers on vendored assets
expect "$VP" "$FP/missing-header" 1 "provenance: vendored manifest without a header fails naming it" \
  "FAIL deploy/cert-manager/cert-manager.yaml: no provenance header"
expect "$VP" "$FP/no-digest" 1 "provenance: header without a digest fails" \
  "FAIL deploy/kuid/kuid-server.yaml: provenance header (header) incomplete: no digest"
expect "$VP" "$FP/floating-version" 1 "provenance: a branch as version fails" \
  "FAIL deploy/sdc/config-server.yaml: provenance header (header) incomplete: floating version 'main'"
expect "$VP" "$FP/dashboard-no-provenance" 1 "provenance: a dashboard without a provenance object fails" \
  "FAIL deploy/observability/grafana/dashboards/fabric.json: no provenance header"
expect "$VP" "$FP/good" 0 "provenance: header, first-party dashboard, vendored dashboard pass; kustomization.yaml exempt" \
  "PASS 3 vendored asset(s)"

# --- the real tree
expect "$VB" "$ROOT" 0 "make verify-boundaries passes on this repository" "verify-boundaries: PASS"
expect "$VP" "$ROOT" 0 "make verify-provenance-headers passes on this repository" "verify-provenance-headers: PASS"

echo "verify_boundaries_test: $fails failure(s)"
[ "$fails" -eq 0 ]
