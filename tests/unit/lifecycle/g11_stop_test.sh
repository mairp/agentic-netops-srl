#!/usr/bin/env bash
# G11 stop test (T044, T048; FR-104, FR-109, CD-03, AD-49, R-31, SC-047; data-model.md §23).
#
# Drives scripts/provision.sh's AppsReady phase — sourced from a copy of the tree, so the
# real gate.sh and the real tests/gate/g11_allocation_claim.sh run — against a fake kubectl
# (tests/unit/lifecycle/fake_kubectl) whose allocation authority is made to fail:
#   1. the dynamic claim never reports a value          → non-zero, G11 named, zero applies
#   2. the stated-value claim binds a different value   → non-zero, G11 named, zero applies
#      ("zero applies" = the recorded call log holds no apply of the device-configuration
#      layer deploy/sdc, of the provider — its settings, its image build, deploy/agentic-netops — or of observability)
#   3. no flag or environment variable of provision.sh selects another allocator
#   4. negative control: a healthy fake authority → G11 passes (observations (a)–(f) held)
#      and AppsReady goes on to install SDC and the provider (DRIFT_POLICY=revertive)
# and T048's change-of-authority stop (AD-49):
#   5. a lock file selecting first-party over a cluster whose kuid holds one bound claim →
#      non-zero naming the service resting on it; neither authority touched (no apply, no
#      delete); the substitute is warned by name
#   6. the same with no bound claim → proceeds (kuid removed before the switch)
#   7. the reverse direction: kuid selected over an installed first-party holding no bound
#      claim → proceeds: first-party removed, kuid installed, G11 run, the rest installed; and
#      holding a bound IdentifierClaim → stops naming the service, neither authority touched
# and, on the recorded substitute (lock kind first-party, T180/T181):
#   8. a healthy fake first-party authority → the srl-provider image is built and its tag written
#      into deploy/allocation too, deploy/allocation applied, G11 passes against identifierclaims in
#      agentic-netops-allocation (observations (a)–(f), authority.kind first-party), then the pools,
#      the device-configuration layer (SDC), the provider's first-party claim Role and the provider;
#      the substitute is warned by name with its decision record and failed-gate evidence
#   9. a failing fake first-party authority (dynamic claim never reports a value; stated claim
#      binds a different value) → non-zero NAMING G11, zero applies above the authority (no pools,
#      no SDC, no claim Role, no provider)
#  10. in every first-party run the call log shows NO apply under deploy/kuid/
# The kuid cases run on a copy of the tree whose lock selects kind: kuid (a fixture lock); the
# first-party cases on one whose lock selects first-party with both references.
# Offline and fast: no docker, no network, no cluster; every wait and read-back is bounded
# by small values passed through the environment.
# shellcheck disable=SC2015  # `cond && pass … || fail …` is safe: pass always returns 0
set -uo pipefail
# the fake authority settles at once: no wait between the read-back's consecutive clean reads
export G11_SETTLE_INTERVAL=0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 30 | sed 's/^/    /'; }

for tool in jq yq sha256sum realpath; do
  command -v "$tool" >/dev/null || { echo "FAIL prerequisite: $tool not on PATH"; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fp_lock() {  # fp_lock <tree> — select the substitute, with both references
  yq -i '.allocationAuthority = {"kind": "first-party", "decisionRecord": "docs/decisions/allocator-substitution.md",
         "failedGateEvidence": {"path": "docs/decisions/allocator-substitution/g11-observations.json", "sha256": "0000000000000000000000000000000000000000000000000000000000000000"}}' "$1/versions.lock.yaml"
}

# make_tree <dir> [kuid|first-party] — a copy of the parts of the tree AppsReady reads, with stub
# A1 libraries (image build and kind image load), empty kustomizations and a fixture lock that
# selects the given authority (default kuid).
make_tree() {
  local t="$1" kind="${2:-kuid}"
  mkdir -p "$t/scripts" "$t/tests/gate" "$t/tests/lib" "$t/bin"
  cp -r "$ROOT/scripts/lib" "$t/scripts/lib"
  cp "$ROOT/scripts/provision.sh" "$t/scripts/provision.sh"
  cp "$ROOT/tests/gate/g11_allocation_claim.sh" "$t/tests/gate/"
  cp "$ROOT/tests/lib/lab.sh" "$t/tests/lib/"
  cp "$ROOT/versions.lock.yaml" "$t/versions.lock.yaml"
  local d
  for d in deploy/cert-manager deploy/kuid deploy/kuid/indices deploy/sdc deploy/sdc/onboarding deploy/agentic-netops \
           deploy/observability deploy/allocation deploy/allocation/pools config/rbac/claims/kuid config/rbac/claims/first-party; do
    mkdir -p "$t/$d"
    printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n' >"$t/$d/kustomization.yaml"
  done
  printf 'images:\n- name: srl-provider\n  newTag: unbuilt\n' >>"$t/deploy/allocation/kustomization.yaml"
  case "$kind" in
    kuid) yq -i '.allocationAuthority = {"kind": "kuid"}' "$t/versions.lock.yaml" ;;
    first-party) fp_lock "$t" ;;
  esac
  cat >"$t/scripts/lib/image_build.sh" <<'EOF'
image_build::content_hash() { echo "0123456789ab"; }
image_build::build() { echo "build $1" >>"$FAKE_KUBE_STATE/calls"; echo "$1:0123456789ab"; }
image_build::set_image() {
  echo "set_image ${1#"$PWD"/} $2 $3" >>"$FAKE_KUBE_STATE/calls"
  IB_NAME="$2" IB_TAG="$3" yq -i '(.images[] | select(.name == strenv(IB_NAME))).newTag = strenv(IB_TAG)' "$1"
}
EOF
  cat >"$t/scripts/lib/kind.sh" <<'EOF'
kind::load_image() { echo "kind load $2 into $1" >>"$FAKE_KUBE_STATE/calls"; }
EOF
  rm -f "$t/scripts/lib/preflight.sh" "$t/scripts/lib/containerlab.sh" "$t/scripts/lib/docker_net.sh" "$t/scripts/lib/lab_secrets.sh"
  cp "$HERE/fake_kubectl" "$t/bin/kubectl"
  chmod +x "$t/bin/kubectl"
}

# run_apps <tree> <authority-mode> — AppsReady in a subshell; stdout+stderr to <tree>/out
run_apps() {
  local t="$1" mode="$2"
  mkdir -p "$t/state"
  (
    cd "$t" || exit 99
    export PATH="$t/bin:$PATH" KUBECTL="$t/bin/kubectl" FAKE_KUBE_STATE="$t/state" FAKE_AUTHORITY="$mode"
    export EVIDENCE_DIR="$t/evidence" EVIDENCE_LAB=agentic-netops-fabric EVIDENCE_CLUSTER_UID=fake-uid
    export CLUSTER_NAME=agentic-netops G11_POLL_ATTEMPTS=2 G11_POLL_INTERVAL=0 PROVISION_WAIT_TIMEOUT=2
    unset LOG_PHASE
    # shellcheck disable=SC1091
    source scripts/provision.sh
    provision::defaults
    evidence::ensure_dir
    provision::phase_AppsReady
  ) >"$t/out" 2>&1
}

# applies_above_authority <tree> — apply lines for the seed indices/pools, SDC, the provider (its
# claim Role, settings, deploy/agentic-netops — and, on kuid, its image build: on first-party the
# authority itself runs that image, so its build is below the authority) and observability
applies_above_authority() {
  grep -E '^kubectl .*\bapply\b' "$1/state/calls" 2>/dev/null \
    | grep -E 'deploy/kuid/indices|deploy/allocation/pools|deploy/sdc|deploy/agentic-netops$|config/rbac/claims|deploy/observability|monitoring' || true
  grep -E '^kubectl .*\bcreate\b.*(srl-provider-settings|srl-provider-compat)' "$1/state/calls" 2>/dev/null || true
  if [[ "$(yq -r .allocationAuthority.kind "$1/versions.lock.yaml")" == kuid ]]; then
    grep -E '^build srl-provider' "$1/state/calls" 2>/dev/null || true
  fi
}
# kuid_applies <tree> — any apply under deploy/kuid/
kuid_applies() { grep -E '^kubectl .*\bapply\b.*deploy/kuid' "$1/state/calls" 2>/dev/null || true; }

# ------------------------------------------------------------------ 1, 2: G11 fails → stop
for mode in no-value wrong-value; do
  t="$TMP/$mode"; make_tree "$t"
  rc=0; run_apps "$t" "$mode" || rc=$?
  if [[ "$rc" -ne 0 ]] && grep -q 'G11 FAILED' "$t/out"; then
    pass "$mode: AppsReady exits non-zero ($rc) naming G11"
  else
    fail "$mode: AppsReady should exit non-zero naming G11 (rc=$rc)" "$(cat "$t/out")"
  fi
  above="$(applies_above_authority "$t")"
  if [[ -z "$above" ]]; then
    pass "$mode: the call log shows zero applies for SDC, the provider and observability"
  else
    fail "$mode: something above the authority was installed after G11 failed" "$above"
  fi
  if grep -qE '^kubectl .*apply .*-k .*/deploy/kuid$' "$t/state/calls" && grep -qE '^kubectl .*apply .*-k .*/deploy/cert-manager$' "$t/state/calls"; then
    pass "$mode: cert-manager and the authority were installed before G11 ran"
  else
    fail "$mode: expected cert-manager and deploy/kuid applies before G11" "$(cat "$t/state/calls")"
  fi
  if jq -e '.result == "fail" and (.failures | length > 0)' "$t/evidence/g11-observations.json" >/dev/null 2>&1; then
    pass "$mode: g11-observations.json records the failure: $(jq -r '.failures[0]' "$t/evidence/g11-observations.json" | cut -c1-90)"
  else
    fail "$mode: g11-observations.json missing or not a failure" "$(cat "$t/evidence/g11-observations.json" 2>&1)"
  fi
  if [[ -z "$(find "$t/state/objects" -type f 2>/dev/null)" ]]; then
    pass "$mode: G11's scratch objects were removed after the failure"
  else
    fail "$mode: scratch objects left behind" "$(find "$t/state/objects" -type f)"
  fi
done
case_f="$(jq -r '.failures | join(" ")' "$TMP/no-value/evidence/g11-observations.json" 2>/dev/null)"
[[ "$case_f" == *"no value"*"terminal"* ]] && pass "no-value: the claim reporting no value is recorded as terminal (R-31)" \
  || fail "no-value: failure should say the claim reported no value and is terminal" "$case_f"
case_f="$(jq -r '.failures | join(" ")' "$TMP/wrong-value/evidence/g11-observations.json" 2>/dev/null)"
[[ "$case_f" == *"(a)"*"did not bind exactly"* ]] && pass "wrong-value: observation (a) is the failure recorded" \
  || fail "wrong-value: failure should name observation (a)" "$case_f"

# ------------------------------------------------------------------ 3: no allocator selector
PROV="$ROOT/scripts/provision.sh"
flags="$(sed -n '/^provision::main()/,/^}/p' "$PROV" | grep -oE '^\s+(-[-a-zA-Z=*|]+)\)' | tr -d ' )' | sort -u | paste -sd' ' -)"
if [[ "$flags" == "--cluster-name --cluster-name=* --with-intent-tier -h|--help" ]]; then
  pass "provision.sh's argument parser admits only --cluster-name, --with-intent-tier, --help ($flags)"
else
  fail "provision.sh's argument parser admits unexpected flags" "$flags"
fi
if sed -n '/^provision::main()/,/^}/p' "$PROV" | grep -iqE 'alloc|authority|kuid|first-party|profile'; then
  fail "provision.sh's argument parser mentions an allocator or a profile"
else
  pass "no flag of provision.sh selects an allocator or a device profile"
fi
envsel="$(cat "$PROV" "$ROOT/scripts/lib/gate.sh" "$ROOT/tests/gate/g11_allocation_claim.sh" \
  | grep -v '^\s*#' | grep -oE '\$\{?[A-Z][A-Z0-9_]*(ALLOC|AUTHORITY|KUID|PROFILE|LOCK)[A-Z0-9_]*' | sort -u || true)"
if [[ -z "$envsel" ]]; then
  pass "no environment variable of provision.sh, gate.sh or the G11 script selects an allocator or a lock file"
else
  fail "an environment variable could select an allocator or a lock file" "$envsel"
fi

# ------------------------------------------------------------------ 4: negative control
t="$TMP/healthy"; make_tree "$t"
rc=0; run_apps "$t" healthy || rc=$?
if [[ "$rc" -eq 0 ]]; then pass "healthy: AppsReady completes (G11 passed)"; else fail "healthy: AppsReady should pass (rc=$rc)" "$(cat "$t/out")"; fi
obs="$t/evidence/g11-observations.json"
if jq -e '.result == "pass" and .aggregated_api.healthy and .observations.a.held and .observations.b.held
          and .observations.c.recorded and .observations.c.allocation == "lowest-free" and .observations.d.held
          and .observations.e.held and .observations.f.held and .round_trip.released and .cleanup.removed' "$obs" >/dev/null 2>&1; then
  pass "healthy: observations (a)–(f), the round trip and the cleanup are recorded in g11-observations.json"
else
  fail "healthy: g11-observations.json incomplete" "$(jq . "$obs" 2>&1)"
fi
if jq -e '.observations.b.refusal_message | test("vt-scratch-g11-stated-a")' "$obs" >/dev/null 2>&1; then
  pass "healthy: (b)'s refusal names the holder: $(jq -r .observations.b.refusal_message "$obs")"
else
  fail "healthy: (b)'s refusal text should name the holder" "$(jq .observations.b "$obs" 2>&1)"
fi
nc_ok=true
for c in g11-min-id g11-label-selector g11-stated-value g11-stated-conflict g11-release-synchronous; do
  jq -e '.kind == "negative_control" and .negative_control_failed == true' "$t/evidence/$c.negative-control.json" >/dev/null 2>&1 || { nc_ok=false; echo "    missing/failed: $c"; }
done
[[ "$nc_ok" == true ]] && pass "healthy: every negative control (d, e spec.labels, a out-of-index, b, f) is recorded and failed" \
  || fail "healthy: negative controls not all recorded as failing"
if ve="$(bash "$ROOT/scripts/lib/verify_evidence.sh" "$t/evidence" 2>&1)"; then
  pass "healthy: G11's evidence verifies (make verify-evidence): $(tail -n1 <<<"$ve" | sed 's/^verify-evidence: //')"
else
  fail "healthy: G11's evidence does not verify" "$ve"
fi
above="$(applies_above_authority "$t")"
if grep -q 'deploy/sdc' <<<"$above" && grep -q 'deploy/agentic-netops$' <<<"$above"; then
  pass "healthy: AppsReady goes on to install SDC and the provider"
else
  fail "healthy: SDC and the provider should be applied after G11 passed" "$(cat "$t/state/calls")"
fi
if grep -qE 'create configmap srl-provider-settings .*--from-literal=drift-policy=revertive' "$t/state/calls"; then
  pass "healthy: DRIFT_POLICY=revertive is written explicitly (ConfigMap srl-provider-settings)"
else
  fail "healthy: drift-policy=revertive was not written"
fi
order="$(grep -nE 'srl-provider-settings|apply .*-k .*/deploy/agentic-netops$' "$t/state/calls" | head -n1)"
[[ "$order" == *srl-provider-settings* ]] && pass "healthy: the drift policy is written before the provider is applied" \
  || fail "healthy: the provider was applied before its drift policy" "$order"
order="$(grep -nE '^build srl-provider|apply .*-k .*/deploy/agentic-netops$' "$t/state/calls" | cut -d: -f2- | paste -sd'|' -)"
if [[ "$order" == "build srl-provider|"*"deploy/agentic-netops" ]]; then
  pass "healthy: the provider image is built from the tree (image_build::build) before deploy/agentic-netops is applied"
else
  fail "healthy: expected image_build::build srl-provider, then apply -k deploy/agentic-netops" "$order"
fi
if grep -E '^kubectl .*\bapply\b' "$t/state/calls" | grep -v -- '--server-side' | grep -q .; then
  fail "healthy: an apply was not server-side" "$(grep -E '^kubectl .*\bapply\b' "$t/state/calls" | grep -v -- '--server-side')"
else
  pass "healthy: every apply is server-side"
fi
if grep -q 'deploy/observability' "$t/state/calls"; then fail "healthy: AppsReady touched observability (it is ObservabilityReady's)"; else pass "healthy: AppsReady does not install observability"; fi

# ------------------------------------------------------------------ 5: change of authority, bound claim
bound_one='{"items": [
  {"kind": "VLANClaim", "metadata": {"name": "agentic-netops-services.svc-a.vlan-v1", "namespace": "kuid-system",
    "labels": {"agentic-netops.io/network-namespace": "agentic-netops-services", "agentic-netops.io/network-name": "svc-a"}},
   "spec": {"index": "vlan"}, "status": {"id": 1001, "conditions": [{"type": "Ready", "status": "True"}]}},
  {"kind": "GENIDClaim", "metadata": {"name": "pending", "namespace": "kuid-system", "labels": {}},
   "spec": {"index": "vni"}, "status": {}}]}'

t="$TMP/change-bound"; make_tree "$t" first-party
mkdir -p "$t/state"; touch "$t/state/installed-kuid"; printf '%s\n' "$bound_one" >"$t/state/bound-kuid.json"
rc=0; run_apps "$t" healthy || rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'Network agentic-netops-services/svc-a rests on VLANClaim kuid-system/agentic-netops-services.svc-a.vlan-v1' "$t/out"; then
  pass "change (bound): stops non-zero naming the service resting on the bound claim"
else
  fail "change (bound): should stop naming Network agentic-netops-services/svc-a (rc=$rc)" "$(cat "$t/out")"
fi
grep -q 'pending' "$t/out" && fail "change (bound): an unbound claim was listed as bound" || pass "change (bound): an unbound claim is not listed"
grep -q 'removed first' "$t/out" && pass "change (bound): says the services are removed first and re-created after" \
  || fail "change (bound): the remedy is not stated"
touched="$(grep -E '^kubectl .*\b(apply|delete)\b' "$t/state/calls" || true)"
[[ -z "$touched" ]] && pass "change (bound): neither authority touched — zero applies, zero deletes" \
  || fail "change (bound): something was applied or deleted" "$touched"
grep -q 'ALLOCATION AUTHORITY SUBSTITUTED' "$t/out" && grep -q 'IdentifierPool/IdentifierClaim' "$t/out" \
  && pass "change (bound): the first-party substitute is warned by name" || fail "change (bound): substitute not warned by name"

# ------------------------------------------------------------------ 6: change of authority, none bound
t="$TMP/change-none"; make_tree "$t" first-party
mkdir -p "$t/state"; touch "$t/state/installed-kuid"
jq '.items |= map(select(.metadata.name == "pending"))' <<<"$bound_one" >"$t/state/bound-kuid.json"
rc=0; run_apps "$t" healthy || rc=$?
if grep -q 'proceeding with the change of authority' "$t/out" && grep -qE '^kubectl .*delete -k .*/deploy/kuid( |$)' "$t/state/calls"; then
  pass "change (none bound): proceeds — kuid removed before the switch"
else
  fail "change (none bound): should proceed and remove kuid" "$(cat "$t/out")"
fi
if grep -qE '^kubectl .*apply .*-k .*/deploy/allocation$' "$t/state/calls" && [[ "$rc" -eq 0 ]] \
   && jq -e '.result == "pass" and .authority.kind == "first-party"' "$t/evidence/g11-observations.json" >/dev/null 2>&1; then
  pass "change (none bound): the substitute is installed, faces G11 on its own claims and passes; AppsReady completes"
else
  fail "change (none bound): expected deploy/allocation applied, G11 passed on first-party (rc=$rc)" "$(cat "$t/out")"
fi
after_delete="$(sed -n '/delete -k .*\/deploy\/kuid\( \|$\)/,$p' "$t/state/calls" | grep -E '^kubectl .*\bapply\b.*deploy/kuid' || true)"
[[ -z "$after_delete" ]] && pass "change (none bound): after kuid's removal nothing under deploy/kuid/ is applied again" \
  || fail "change (none bound): deploy/kuid applied after the switch to first-party" "$after_delete"


# ------------------------------------------------------------------ 7: reverse direction
t="$TMP/change-reverse"; make_tree "$t"
mkdir -p "$t/state"; touch "$t/state/installed-fp"
echo '{"items": [{"kind": "IdentifierClaim", "metadata": {"name": "x", "namespace": "agentic-netops-allocation"}, "status": {}}]}' >"$t/state/bound-fp.json"
rc=0; run_apps "$t" healthy || rc=$?
if [[ "$rc" -eq 0 ]] && grep -qE '^kubectl .*delete crd identifierpools.fabric.agentic-netops.io identifierclaims.fabric.agentic-netops.io' "$t/state/calls" \
   && grep -qE '^kubectl .*apply .*-k .*/deploy/kuid$' "$t/state/calls"; then
  pass "change (reverse, none bound): first-party removed, kuid installed, G11 passed, AppsReady completed"
else
  fail "change (reverse, none bound): expected first-party removal then kuid (rc=$rc)" "$(cat "$t/out")"
fi
t2="$TMP/change-reverse-bound"; make_tree "$t2"; mkdir -p "$t2/state"; touch "$t2/state/installed-fp"
echo '{"items": [{"kind": "IdentifierClaim", "metadata": {"name": "x", "namespace": "agentic-netops-allocation", "labels": {"agentic-netops.io/correlation-id": "c-42"}}, "status": {"value": "1003"}}]}' >"$t2/state/bound-fp.json"
rc=0; run_apps "$t2" healthy || rc=$?
touched="$(grep -E '^kubectl .*\b(apply|delete)\b' "$t2/state/calls" || true)"
if [[ "$rc" -ne 0 ]] && grep -q 'intent-tier service correlation-id c-42 rests on IdentifierClaim' "$t2/out" && [[ -z "$touched" ]]; then
  pass "change (reverse, bound): stops naming the service, neither authority touched"
else
  fail "change (reverse, bound): should stop naming correlation-id c-42 with nothing touched (rc=$rc)" "$(cat "$t2/out"; echo "$touched")"
fi

# ------------------------------------------------------------------ 8: first-party, healthy
t="$TMP/fp-healthy"; make_tree "$t" first-party
rc=0; run_apps "$t" healthy || rc=$?
if [[ "$rc" -eq 0 ]]; then pass "first-party healthy: AppsReady completes (G11 passed on the substitute)"; else fail "first-party healthy: AppsReady should pass (rc=$rc)" "$(cat "$t/out")"; fi
calls_seq="$(grep -nE '^build srl-provider|^set_image deploy/allocation/kustomization.yaml srl-provider|apply .*-k .*/deploy/allocation$|create -f .*vt-scratch-g11|apply .*-k .*/deploy/allocation/pools$|apply .*-k .*/deploy/sdc$|apply .*-k .*/config/rbac/claims/first-party$|apply .*-k .*/deploy/agentic-netops$' "$t/state/calls" \
  | sed -E 's/^[0-9]+:(build srl-provider|set_image deploy\/allocation).*/\1/; s/^[0-9]+:.*create -f .*vt-scratch-g11.*/G11/; s/^[0-9]+:.*-k .*\/(deploy\/allocation\/pools|deploy\/allocation|deploy\/sdc|config\/rbac\/claims\/first-party|deploy\/agentic-netops)$/\1/' | uniq | paste -sd'>' -)"
want_seq="build srl-provider>set_image deploy/allocation>deploy/allocation>G11>deploy/allocation/pools>deploy/sdc>build srl-provider>config/rbac/claims/first-party>deploy/agentic-netops"
if [[ "$calls_seq" == "$want_seq" ]]; then
  pass "first-party healthy: image built, its tag written into deploy/allocation, authority applied, G11, pools, SDC, claim Role, provider — in that order"
else
  fail "first-party healthy: AppsReady order" "got:  $calls_seq"$'\n'"want: $want_seq"
fi
if grep -q '^set_image deploy/allocation/kustomization.yaml srl-provider 0123456789ab$' "$t/state/calls" \
   && [[ "$(yq -r '.images[] | select(.name == "srl-provider") | .newTag' "$t/deploy/allocation/kustomization.yaml")" == 0123456789ab ]]; then
  pass "first-party healthy: deploy/allocation runs the very tag the provider build produced (srl-provider:0123456789ab)"
else
  fail "first-party healthy: deploy/allocation's images: newTag is not the built tag" "$(cat "$t/deploy/allocation/kustomization.yaml")"
fi
grep -qE '^kubectl .*label namespace agentic-netops-allocation agentic-netops.io/owned-by=agentic-netops --overwrite' "$t/state/calls" \
  && pass "first-party healthy: agentic-netops-allocation carries this cluster's ownership label" \
  || fail "first-party healthy: the allocation namespace was not ownership-labelled"
obs="$t/evidence/g11-observations.json"
if jq -e '.result == "pass" and .authority.kind == "first-party" and .namespace == "agentic-netops-allocation"
          and .aggregated_api.healthy and .observations.a.held and .observations.b.held
          and .observations.c.recorded and .observations.c.allocation == "lowest-free" and .observations.d.held
          and .observations.e.held and .observations.f.held and .round_trip.released and .cleanup.removed
          and .round_trip.vlan.status_value == 1000' "$obs" >/dev/null 2>&1; then
  pass "first-party healthy: g11-observations.json records authority.kind first-party and (a)–(f), round trip, cleanup"
else
  fail "first-party healthy: g11-observations.json incomplete" "$(jq . "$obs" 2>&1)"
fi
if jq -e '.observations.b.refusal_message | test("held by claim agentic-netops-allocation/vt-scratch-g11-stated-a")' "$obs" >/dev/null 2>&1 \
   && jq -e '.observations.b.refusal_reason == "Conflict" and .observations.a.negative_control.refused_reason == "OutOfRange"' "$obs" >/dev/null 2>&1; then
  pass "first-party healthy: (b) refused Conflict naming <namespace>/<holder>; (a)'s control refused OutOfRange"
else
  fail "first-party healthy: refusal reasons/holder" "$(jq '.observations.a, .observations.b' "$obs" 2>&1)"
fi
nc_ok=true
for c in g11-min-id g11-label-selector g11-stated-value g11-stated-conflict g11-release-synchronous; do
  jq -e '.kind == "negative_control" and .negative_control_failed == true' "$t/evidence/$c.negative-control.json" >/dev/null 2>&1 || { nc_ok=false; echo "    missing/failed: $c"; }
done
[[ "$nc_ok" == true ]] && pass "first-party healthy: every negative control (d, e annotation, a out-of-pool, b, f) is recorded and failed" \
  || fail "first-party healthy: negative controls not all recorded as failing"
if grep -q '^  annotations:' "$t/evidence/g11-speclabel-claim.stdout" 2>/dev/null && ! sed -n '/^  labels:/,/^  annotations:/p' "$t/evidence/g11-speclabel-claim.stdout" | grep -q g11-probe; then
  pass "first-party healthy: (e)'s control writes the label as an annotation (IdentifierClaim has no spec.labels)"
else
  fail "first-party healthy: (e)'s control claim" "$(cat "$t/evidence/g11-speclabel-claim.stdout" 2>&1 | head -20)"
fi
if grep -hE '^kubectl .*(create|apply|delete|get) ' "$t/state/calls" | grep -E 'identifier|vt-scratch' | grep -vq -- '--context kind-agentic-netops'; then
  fail "first-party healthy: a G11 kubectl call without the cluster context"
else
  pass "first-party healthy: every G11 kubectl call names the cluster context"
fi
rec_ok=true
for f in "$t"/evidence/g11-*.json; do
  case "$f" in */g11-observations.json) continue ;; esac
  jq -e '.schema == "agentic-netops.evidence/v1"' "$f" >/dev/null 2>&1 || { rec_ok=false; echo "    not an evidence record: $f"; }
done
if [[ "$rec_ok" == true ]] && ve="$(bash "$ROOT/scripts/lib/verify_evidence.sh" "$t/evidence" 2>&1)"; then
  pass "first-party healthy: every G11 call is run-captured evidence and verifies: $(tail -n1 <<<"$ve" | sed 's/^verify-evidence: //')"
else
  fail "first-party healthy: G11's evidence does not verify" "${ve:-}"
fi
labels_ok="$(yq -r '[.metadata.name, .metadata.labels["agentic-netops.io/gate-owned"]] | join(" ")' "$t/evidence/g11-pools.yaml" 2>/dev/null | grep -v '^$' | sort | paste -sd, -)"
[[ "$labels_ok" == "vt-scratch-g11-narrow true,vt-scratch-g11-vlan true,vt-scratch-g11-vni true" ]] \
  && pass "first-party healthy: the scratch pools are vt-scratch-g11-* and gate-owned (agentic-netops.io/gate-owned=true)" \
  || fail "first-party healthy: scratch pool names/labels" "$labels_ok"
if [[ -z "$(find "$t/state/objects" -type f 2>/dev/null)" ]]; then
  pass "first-party healthy: G11's scratch pools and claims were removed (read back)"
else
  fail "first-party healthy: scratch objects left behind" "$(find "$t/state/objects" -type f)"
fi
[[ -z "$(kuid_applies "$t")" ]] && pass "first-party healthy: the call log shows NO apply under deploy/kuid/" || fail "first-party healthy: deploy/kuid applied" "$(kuid_applies "$t")"
grep -q 'config/rbac/claims/kuid' "$t/state/calls" && fail "first-party healthy: the kuid claim Role was applied" \
  || pass "first-party healthy: only the first-party claim Role is applied (config/rbac/claims/first-party)"
if grep -q 'ALLOCATION AUTHORITY SUBSTITUTED' "$t/out" && grep -q 'decision record: docs/decisions/allocator-substitution.md' "$t/out" \
   && grep -q 'failed G11 evidence: docs/decisions/allocator-substitution/g11-observations.json' "$t/out"; then
  pass "first-party healthy: the substitute is warned by name with its decision record and failed-gate evidence"
else
  fail "first-party healthy: substitute warning incomplete" "$(grep -i substitut "$t/out")"
fi

# ------------------------------------------------------------------ 9: first-party, failing
for mode in no-value wrong-value; do
  t="$TMP/fp-$mode"; make_tree "$t" first-party
  rc=0; run_apps "$t" "$mode" || rc=$?
  if [[ "$rc" -ne 0 ]] && grep -q 'G11 FAILED' "$t/out"; then
    pass "first-party $mode: AppsReady exits non-zero ($rc) naming G11"
  else
    fail "first-party $mode: AppsReady should exit non-zero naming G11 (rc=$rc)" "$(cat "$t/out")"
  fi
  above="$(applies_above_authority "$t")"
  [[ -z "$above" ]] && pass "first-party $mode: zero applies above the authority (no pools, SDC, claim Role, provider, observability)" \
    || fail "first-party $mode: something above the authority was installed after G11 failed" "$above"
  grep -qE '^kubectl .*apply .*-k .*/deploy/allocation$' "$t/state/calls" \
    && pass "first-party $mode: the substitute was installed before G11 ran" || fail "first-party $mode: deploy/allocation not applied"
  if jq -e '.result == "fail" and .authority.kind == "first-party" and (.failures | length > 0)' "$t/evidence/g11-observations.json" >/dev/null 2>&1; then
    pass "first-party $mode: g11-observations.json records the failure on first-party: $(jq -r '.failures[0]' "$t/evidence/g11-observations.json" | cut -c1-90)"
  else
    fail "first-party $mode: g11-observations.json missing or not a first-party failure" "$(cat "$t/evidence/g11-observations.json" 2>&1)"
  fi
  [[ -z "$(find "$t/state/objects" -type f 2>/dev/null)" ]] && pass "first-party $mode: scratch pools and claims removed after the failure" \
    || fail "first-party $mode: scratch objects left behind" "$(find "$t/state/objects" -type f)"
  [[ -z "$(kuid_applies "$t")" ]] && pass "first-party $mode: the call log shows NO apply under deploy/kuid/" || fail "first-party $mode: deploy/kuid applied"
done
case_f="$(jq -r '.failures | join(" ")' "$TMP/fp-no-value/evidence/g11-observations.json" 2>/dev/null)"
[[ "$case_f" == *"status.value"*"terminal"* ]] && pass "first-party no-value: the claim reporting no status.value is recorded as terminal (R-31)" \
  || fail "first-party no-value: failure should say the claim reported no value and is terminal" "$case_f"
case_f="$(jq -r '.failures | join(" ")' "$TMP/fp-wrong-value/evidence/g11-observations.json" 2>/dev/null)"
[[ "$case_f" == *"(a)"*"did not bind exactly"* ]] && pass "first-party wrong-value: observation (a) is the failure recorded" \
  || fail "first-party wrong-value: failure should name observation (a)" "$case_f"

# ------------------------------------------------------------------ 10: no deploy/kuid in any first-party run
all_fp=""
for d in change-bound change-none fp-healthy fp-no-value fp-wrong-value; do
  [[ "$d" == change-none ]] && continue   # the switch deletes deploy/kuid first (checked above)
  all_fp+="$(kuid_applies "$TMP/$d")"
done
[[ -z "$all_fp" ]] && pass "no first-party run applied anything under deploy/kuid/" || fail "a first-party run applied deploy/kuid" "$all_fp"

echo
if [[ "$fails" -eq 0 ]]; then echo "g11_stop_test: all checks passed"; exit 0; fi
echo "g11_stop_test: ${fails} check(s) failed"; exit 1
