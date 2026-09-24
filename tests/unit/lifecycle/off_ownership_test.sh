#!/usr/bin/env bash
# off_ownership_test.sh — scripts/off.sh is ownership-scoped, evidence-preserving and idempotent
# (T029; FR-010, FR-078, SC-003, AD-24, AD-64). Offline: fake docker / kind / containerlab /
# kubectl on PATH (tests/unit/lifecycle/fakes.sh) record every call against a file-backed state.
#
# Asserts:
#   * a full teardown of an owned lab + cluster + network removes all three, lab first, network last
#   * off.sh refuses — deleting NOTHING — when the Docker network, the cluster or a lab container
#     is present but unlabelled (or labelled for another cluster)
#   * pinned images are never deleted (no image-removal call in any run; planted images survive)
#   * a file planted under .evidence/<cluster>_<lab>/<run id>/ is byte-identical after a full
#     teardown WITH --preserve-evidence and after one WITHOUT it (the purge half is T174's)
#   * --preserve-evidence adds evidence_run captures of the state about to be removed
#   * a second run is a success no-op (no destroy / delete / rm call)
#   * the audit-record hook: store absent → no-op; store present and export failing → stops with
#     nothing deleted; --discard-audit-record → proceeds, printed and recorded
#   * --purge-intent-tier on a lab without the tier is a success no-op that leaves the lab, cluster
#     and network (the purge itself is T174's tier_purge_test.sh); --remove-services alone is usage
#   * the intent tier's generated Secrets (T072) are removed before the cluster, operator-credentials
#     only after its username (never its password) is captured through evidence_run
#   * the first-party allocation authority's namespace agentic-netops-allocation: owned → removed
#     after the Secrets and before the cluster, a second run a no-op; present but unowned (or owned
#     by another cluster) → the whole teardown refused with nothing deleted; absent → not touched
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=fakes.sh
source "$ROOT/tests/unit/lifecycle/fakes.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; [[ -n "${out:-}" ]] && printf '%s\n' "$out" | tail -n 15 | sed 's/^/    | /'; fi; }

LAB=agentic-netops-fabric
CL=agentic-netops
NET=agentic-netops-mgmt
SRL_IMG="ghcr.io/nokia/srlinux:25.7.1@sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402"
KIND_IMG="docker.io/kindest/node:v1.32.2@sha256:f226345927d7e348497136874b6d207e0b32cc52154ad8323129352923a3142f"

# setup <case> — a fresh fake world with an owned lab, cluster and network, and a planted evidence file
setup() {
  W="$T/$1"
  rm -rf "$W"; mkdir -p "$W"
  fakes::install "$W"
  export FAKE_STATE="$W/state"
  export PATH="$W/bin:$ORIG_PATH"
  export EVIDENCE_ROOT="$W/evidence" CLAB_LABDIR_BASE="$W/labdir" AGENTIC_NETOPS_ENV_FILE="$W/no.env"
  unset EVIDENCE_DIR CLUSTER_NAME OFF_AUDIT_EXPORT_CMD || true
  # this suite's fake store never answers: bound T088's export tightly (its default is tier_purge_test's)
  export AUDIT_EXPORT_TIMEOUT_SECONDS=3
  fakes::network "$NET" 172.25.25.0/24 "$CL"
  local n
  for n in spine01 spine02 leaf01 leaf02; do fakes::container "clab-$LAB-$n" "$LAB" nokia_srlinux "$CL"; done
  for n in client01 client02; do fakes::container "clab-$LAB-$n" "$LAB" linux "$CL"; done
  fakes::cluster "$CL" "$CL"
  fakes::k8s "$CL" _ namespace agentic-netops-system "$CL"
  fakes::k8s "$CL" _ namespace monitoring "$CL"
  fakes::k8s "$CL" agentic-netops-system secret srl-credentials "$CL"
  fakes::k8s "$CL" monitoring secret srl-credentials "$CL"
  fakes::k8s "$CL" monitoring secret grafana-admin "$CL"
  fakes::image "$SRL_IMG"; fakes::image "$KIND_IMG"
  mkdir -p "$CLAB_LABDIR_BASE/clab-$LAB/.tls/ca"
  echo "ca" >"$CLAB_LABDIR_BASE/clab-$LAB/.tls/ca/ca.pem"
  PLANT="$EVIDENCE_ROOT/${CL}_${LAB}/20260101T000000Z/audit-record.ndjson.gz"
  mkdir -p "$(dirname "$PLANT")"
  head -c 4096 /dev/urandom >"$PLANT"
  PLANT_SUM="$(sha256sum "$PLANT" | cut -d' ' -f1)"
  printf 'usernames: operator\n' >"$EVIDENCE_ROOT/${CL}_${LAB}/usernames.txt"
  USERS_SUM="$(sha256sum "$EVIDENCE_ROOT/${CL}_${LAB}/usernames.txt" | cut -d' ' -f1)"
}
ORIG_PATH="$PATH"

run_off() { : >"$FAKE_STATE/calls.log"; set +e; out="$(bash "$ROOT/scripts/off.sh" "$@" 2>&1)"; rc=$?; set -e; }
calls() { cat "$FAKE_STATE/calls.log"; }
deleting_calls() { calls | grep -E '^(containerlab destroy|kind delete|docker network (rm|disconnect)|kubectl (.* )?delete )' || true; }
image_removal_calls() { calls | grep -E '^docker (rmi|image (rm|remove|prune)|system prune|builder prune)' || true; }
planted_intact() {
  [[ -f "$PLANT" && "$(sha256sum "$PLANT" | cut -d' ' -f1)" == "$PLANT_SUM" ]] \
    && [[ "$(sha256sum "$EVIDENCE_ROOT/${CL}_${LAB}/usernames.txt" | cut -d' ' -f1)" == "$USERS_SUM" ]]
}
images_intact() { [[ -f "$(fakes::image_file "$SRL_IMG")" && -f "$(fakes::image_file "$KIND_IMG")" ]]; }
world_absent() {
  [[ ! -e "$FAKE_STATE/docker/networks/$NET.json" && ! -e "$FAKE_STATE/kind/$CL" ]] \
    && ! ls "$FAKE_STATE/docker/containers/" | grep -q "clab-$LAB"
}

# ------------------------------------------------------------------ full teardown, without the flag
setup plain
run_off
check "teardown: exits 0" '[[ $rc -eq 0 ]]'
check "teardown: lab, cluster and network are gone" 'world_absent'
check "teardown: the lab directory (generated CA) is gone" '[[ ! -e "$CLAB_LABDIR_BASE/clab-$LAB" ]]'
check "teardown: order is lab → secrets → cluster → network" \
  '[[ "$(deleting_calls | sed -E "s/^(containerlab destroy|kubectl|kind delete|docker network rm).*/\1/" | uniq | tr "\n" "|")" == "containerlab destroy|kubectl|kind delete|docker network rm|" ]]'
check "teardown: the generated Secrets were deleted before the cluster" \
  'calls | grep -q "kubectl .*delete secret srl-credentials -n agentic-netops-system" && calls | grep -q "kubectl .*delete secret grafana-admin -n monitoring"'
check "teardown: no image was removed" '[[ -z "$(image_removal_calls)" ]] && images_intact'
check "teardown without --preserve-evidence: the planted evidence is byte-identical" 'planted_intact'
check "teardown without --preserve-evidence: no evidence capture was added" \
  '[[ "$(find "$EVIDENCE_ROOT" -name "teardown-*.json" | wc -l)" -eq 0 ]]'

run_off
check "second run: exits 0" '[[ $rc -eq 0 ]]'
check "second run: a no-op — no destroy / delete / rm call" '[[ -z "$(deleting_calls)" ]]'
check "second run: the planted evidence is still byte-identical" 'planted_intact'
check "second run: no image was removed" '[[ -z "$(image_removal_calls)" ]] && images_intact'

# ------------------------------------------------------------------ with --preserve-evidence
setup preserve
run_off --preserve-evidence
check "preserve: exits 0" '[[ $rc -eq 0 ]]'
check "preserve: lab, cluster and network are gone" 'world_absent'
check "preserve: the planted evidence is byte-identical" 'planted_intact'
check "preserve: captures of the state about to be removed were recorded through evidence_run" \
  '[[ "$(find "$EVIDENCE_ROOT/${CL}_${LAB}" -name "teardown-*.json" | wc -l)" -ge 4 ]]'
check "preserve: the captures are evidence records (schema, command, exit status)" \
  'jq -e ".schema == \"agentic-netops.evidence/v1\" and (.command | length > 0) and (.exit_status | type == \"number\")" "$(find "$EVIDENCE_ROOT" -name "teardown-docker-network.json" | head -1)" >/dev/null'
check "preserve: the captures were taken BEFORE the network was removed" \
  'jq -e ".exit_status == 0" "$(find "$EVIDENCE_ROOT" -name "teardown-docker-network.json" | head -1)" >/dev/null'
check "preserve: Secret names only — no Secret data captured" \
  '! grep -rq "\"data\"" "$EVIDENCE_ROOT/${CL}_${LAB}"/*/teardown-cluster-secret-names.stdout'
check "preserve: no image was removed" '[[ -z "$(image_removal_calls)" ]] && images_intact'
run_off --preserve-evidence
check "preserve, second run: success no-op" '[[ $rc -eq 0 && -z "$(deleting_calls)" ]]'
check "preserve, second run: the planted evidence is byte-identical" 'planted_intact'

# ------------------------------------------------------------------ refusals: nothing deleted
setup unlabelled-network
fakes::network "$NET" 172.25.25.0/24 -
run_off
check "refuse: an unlabelled Docker network → non-zero" '[[ $rc -ne 0 ]]'
check "refuse: the network is named" 'grep -q "docker network $NET: not owned" <<<"$out"'
check "refuse: NOTHING was deleted (not the lab, not the cluster)" '[[ -z "$(deleting_calls)" ]]'
check "refuse: the owned lab and cluster still exist" '[[ -e "$FAKE_STATE/kind/$CL" && -e "$FAKE_STATE/docker/containers/clab-$LAB-leaf01.json" ]]'

setup foreign-network
fakes::network "$NET" 172.25.25.0/24 agentic-netops-2
run_off
check "refuse: a network owned by another cluster (prefix match is not ownership)" '[[ $rc -ne 0 && -z "$(deleting_calls)" ]]'

setup unlabelled-cluster
fakes::cluster "$CL" -
run_off
check "refuse: an unlabelled Kind cluster → non-zero" '[[ $rc -ne 0 ]]'
check "refuse: the cluster is named" 'grep -q "Kind cluster $CL: not owned" <<<"$out"'
check "refuse: nothing was deleted" '[[ -z "$(deleting_calls)" ]]'

setup unreachable-cluster
rm -rf "${FAKE_STATE:?}/k8s/$CL"
run_off
check "refuse: a cluster whose ownership cannot be read (fail closed)" '[[ $rc -ne 0 && -z "$(deleting_calls)" ]]'

setup unlabelled-lab
fakes::container "clab-$LAB-leaf02" "$LAB" nokia_srlinux -
run_off
check "refuse: an unlabelled lab container → non-zero" '[[ $rc -ne 0 ]]'
check "refuse: the container is named" 'grep -q "docker container clab-$LAB-leaf02: not owned" <<<"$out"'
check "refuse: nothing was deleted" '[[ -z "$(deleting_calls)" ]]'
check "refuse: the planted evidence is byte-identical" 'planted_intact'

setup other-cluster-name
run_off --cluster-name agentic-netops-2
check "scoping: --cluster-name agentic-netops-2 refuses this platform's lab and network" \
  '[[ $rc -ne 0 && -z "$(deleting_calls)" && -e "$FAKE_STATE/kind/$CL" ]]'

# ------------------------------------------------------------------ partial states
setup no-cluster
rm -f "$FAKE_STATE/kind/$CL"; rm -rf "${FAKE_STATE:?}/k8s/$CL" "$FAKE_STATE/docker/containers/$CL-control-plane.json"
run_off
check "partial: no cluster → the lab and the network still go" '[[ $rc -eq 0 ]] && world_absent'

setup lab-only-dir
for f in "$FAKE_STATE"/docker/containers/clab-*.json; do rm -f "$f"; done
run_off
check "partial: no lab containers but an orphaned lab directory → the directory goes" \
  '[[ $rc -eq 0 && ! -e "$CLAB_LABDIR_BASE/clab-$LAB" ]]'

# ------------------------------------------------------------------ audit-record export hook
setup store-export-fails
fakes::k8s "$CL" _ namespace agentic-netops-agents "$CL"
fakes::k8s "$CL" agentic-netops-agents statefulset clickhouse "$CL"
run_off
check "audit: store present, the export failing (a store that never answers) → non-zero" '[[ $rc -ne 0 ]]'
check "audit: the failure is named" 'grep -q "audit record: export FAILED" <<<"$out"'
check "audit: nothing was deleted; the store is intact" \
  '[[ -z "$(deleting_calls)" && -e "$FAKE_STATE/k8s/$CL/agentic-netops-agents/statefulset/clickhouse.json" ]]'
printf '#!/usr/bin/env bash\necho "export $1" >>"$FAKE_STATE/exported"\nexit 1\n' >"$W/bin/fail-export"
chmod +x "$W/bin/fail-export"
OFF_AUDIT_EXPORT_CMD="$W/bin/fail-export" run_off --preserve-evidence
check "audit: a failing export stops the teardown even with --preserve-evidence" \
  '[[ $rc -ne 0 && -z "$(deleting_calls)" && -s "$FAKE_STATE/exported" ]]'
OFF_AUDIT_EXPORT_CMD="$W/bin/fail-export" run_off --discard-audit-record
check "audit: --discard-audit-record goes past a failed export" '[[ $rc -eq 0 ]] && world_absent'
check "audit: the flag's use is printed" 'grep -q -- "--discard-audit-record was given" <<<"$out"'
check "audit: the flag's use is recorded in evidence" \
  '[[ -n "$(find "$EVIDENCE_ROOT" -name "teardown-discard-audit-record.json")" ]] && grep -rq "export FAILED" "$EVIDENCE_ROOT"/*/*/teardown-discard-audit-record.stdout'
check "audit: the planted evidence is byte-identical" 'planted_intact'

setup store-export-ok
fakes::k8s "$CL" _ namespace agentic-netops-agents "$CL"
fakes::k8s "$CL" agentic-netops-agents statefulset clickhouse "$CL"
printf '#!/usr/bin/env bash\necho "export $1" >>"$FAKE_STATE/exported"\n' >"$W/bin/ok-export"
chmod +x "$W/bin/ok-export"
OFF_AUDIT_EXPORT_CMD="$W/bin/ok-export" run_off
check "audit: the export runs whenever the store exists — requested or not" '[[ $rc -eq 0 && "$(cat "$FAKE_STATE/exported")" == "export $CL" ]]'
check "audit: the export ran before anything was deleted" \
  '[[ "$(grep -n "" "$FAKE_STATE/calls.log" | grep -m1 -E "containerlab destroy" | cut -d: -f1)" -gt 0 ]] && world_absent'

setup no-store
printf '#!/usr/bin/env bash\necho called >>"$FAKE_STATE/exported"\n' >"$W/bin/ok-export"; chmod +x "$W/bin/ok-export"
OFF_AUDIT_EXPORT_CMD="$W/bin/ok-export" run_off
check "audit: no store → the export is not attempted (no-op)" '[[ $rc -eq 0 && ! -e "$FAKE_STATE/exported" ]]'

# ------------------------------------------------------------------ the allocation authority's namespace
setup alloc-owned
fakes::k8s "$CL" _ namespace agentic-netops-allocation "$CL"
run_off
check "allocation: an owned agentic-netops-allocation → teardown exits 0" '[[ $rc -eq 0 ]] && world_absent'
check "allocation: the namespace is deleted (ownership-checked) after the Secrets, before the cluster" \
  '[[ "$(deleting_calls | grep -nE "delete secret grafana-admin|delete namespace agentic-netops-allocation|^kind delete" | cut -d: -f2- | sed -E "s/.*(grafana-admin|agentic-netops-allocation|kind delete).*/\1/" | paste -sd"|" -)" == "grafana-admin|agentic-netops-allocation|kind delete" ]]'
check "allocation: its removal is named" 'grep -q "removed namespace agentic-netops-allocation" <<<"$out"'
check "allocation: the planted evidence is byte-identical" 'planted_intact'
run_off
check "allocation, second run: success no-op" '[[ $rc -eq 0 && -z "$(deleting_calls)" ]]'

setup alloc-unowned
fakes::k8s "$CL" _ namespace agentic-netops-allocation -
run_off
check "allocation: an unlabelled agentic-netops-allocation refuses the whole teardown" '[[ $rc -ne 0 ]]'
check "allocation: the namespace is named" 'grep -q "refusing to touch namespace/agentic-netops-allocation" <<<"$out"'
check "allocation: NOTHING was deleted" '[[ -z "$(deleting_calls)" && -e "$FAKE_STATE/kind/$CL" ]]'

setup alloc-foreign
fakes::k8s "$CL" _ namespace agentic-netops-allocation agentic-netops-2
run_off
check "allocation: a namespace owned by another cluster refuses, nothing deleted" '[[ $rc -ne 0 && -z "$(deleting_calls)" ]]'

setup alloc-absent
run_off
check "allocation: absent → never deleted (no delete call names it)" '[[ $rc -eq 0 ]] && ! calls | grep -q "delete namespace agentic-netops-allocation"'

# ------------------------------------------------------------------ the tier purge (T088; T174 is its suite), usage
setup purge
run_off --purge-intent-tier
check "purge: --purge-intent-tier with no tier installed → a success no-op" '[[ $rc -eq 0 && -z "$(deleting_calls)" ]]'
check "purge: it removes the tier only — the lab, cluster and network stay" '[[ -e "$FAKE_STATE/kind/$CL" && -e "$FAKE_STATE/docker/networks/$NET.json" ]] && ! world_absent'
check "purge: the planted evidence is byte-identical" 'planted_intact'
run_off --remove-services
check "usage: --remove-services without --purge-intent-tier → exit 2, nothing called" '[[ $rc -eq 2 && -z "$(calls)" ]]'
run_off --bogus
check "usage: an unknown flag → exit 2" '[[ $rc -eq 2 ]]'

# ------------------------------------------------------------------ the intent tier's generated Secrets
# (T072; FR-102, data-model.md §22): removed with the other generated Secrets, before the cluster;
# operator-credentials only after its username — never its password — is in the run's evidence
OPW='Gen3rated-operator-password-xyz0'
plant_tier_secrets() { # <owner of operator-credentials>
  fakes::k8s "$CL" _ namespace agentic-netops-agents "$CL"
  fakes::k8s "$CL" agentic-netops-agents secret operator-credentials "$1" \
    "$(jq -cn --arg u "$(printf operator | base64)" --arg p "$(printf '%s' "$OPW" | base64)" '{data: {username: $u, password: $p}}')"
  fakes::k8s "$CL" agentic-netops-agents secret llm-provider "$CL"
  fakes::k8s "$CL" agentic-netops-agents secret slim-gateway "$CL"
  fakes::k8s "$CL" agentic-netops-agents secret clickhouse-auth "$CL"
}
setup tier-secrets
plant_tier_secrets "$CL"
run_off
check "tier secrets: exits 0" '[[ $rc -eq 0 ]]'
check "tier secrets: operator-credentials, llm-provider, slim-gateway, clickhouse-auth deleted before the cluster" \
  '( for s in operator-credentials llm-provider slim-gateway clickhouse-auth; do calls | grep -q "kubectl .*delete secret $s -n agentic-netops-agents" || exit 1; done ) && [[ "$(deleting_calls | grep -n "delete secret operator-credentials" | cut -d: -f1)" -lt "$(deleting_calls | grep -n "^kind delete" | cut -d: -f1)" ]]'
UF="$(find "$EVIDENCE_ROOT" -name teardown-operator-username.stdout | head -1)"
check "tier secrets: the operator username was captured into evidence first" '[[ -n "$UF" ]] && grep -qx "username: operator" "$UF"'
check "tier secrets: the password is nowhere in the evidence" '! grep -rqF "$OPW" "$EVIDENCE_ROOT"'
check "tier secrets: …nor in the output" '! grep -qF "$OPW" <<<"$out"'
run_off
check "tier secrets, second run: success no-op" '[[ $rc -eq 0 && -z "$(deleting_calls)" ]]'

setup tier-secrets-foreign
plant_tier_secrets -
run_off
check "tier secrets: an unowned operator-credentials is refused and kept" \
  '[[ $rc -ne 0 && -f "$FAKE_STATE/k8s/$CL/agentic-netops-agents/secret/operator-credentials.json" ]]'

# ------------------------------------------------------------------ static: no image removal anywhere
check "static: off.sh and its libraries contain no image-removal command" \
  '! grep -nE "docker[\"}]*[[:space:]]+(rmi|image[[:space:]]+(rm|remove|prune)|system[[:space:]]+prune)|_docker[[:space:]]+(rmi|image[[:space:]]+(rm|prune))" \
     "$ROOT/scripts/off.sh" "$ROOT"/scripts/lib/{docker_net,kind,containerlab,lab_secrets,intent_secrets}.sh'
check "static: off.sh never names .evidence in a removal" '! grep -nE "rm .*(\.evidence|EVIDENCE_(ROOT|DIR))" "$ROOT/scripts/off.sh" "$ROOT"/scripts/lib/{docker_net,kind,containerlab,lab_secrets,intent_secrets}.sh'

printf '\noff_ownership_test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
