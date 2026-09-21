#!/usr/bin/env bash
# verify-compat suite (T050; FR-017, FR-104, NFR-003, R-43, SC-047).
#
# Runs scripts/ci/verify_compat.sh from a copy of the tree against a stub kubectl that answers
# from JSON files, and a stub image_build.sh (content hash + the image ID "recorded" in the
# run's evidence). The healthy lab passes; each defect below is a negative control that must
# fail, NAMING what is wrong:
#   * a part of the published compatibility set differs from versions.lock.yaml  → the part
#   * the published id differs                                                   → the id
#   * a provider Config stamped with another compatibility set                   → the Config
#   * kuid selected while the IdentifierPool/IdentifierClaim CRDs exist          → the CRDs
#   * first-party selected while a *.be.kuid.dev APIService exists               → the APIService
#   * a first-party workload whose tag is not the tree's content hash            → the workload
#   * a first-party workload whose image ID is not the one the build recorded    → the workload
#   * no image ID recorded in this run's evidence                                → the workload
#   * the provider not running                                                   → the provider
# Offline: no cluster, no docker.
# shellcheck disable=SC2015  # `cond && pass … || fail …` is safe: pass always returns 0
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 25 | sed 's/^/    /'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HASH="0123456789ab"
IMGID="sha256:$(printf 'a%.0s' {1..64})"
OTHERID="sha256:$(printf 'b%.0s' {1..64})"

# make_tree <dir> — scripts/ci/verify_compat.sh + libs + lock, stub image_build, stub kubectl
make_tree() {
  local t="$1"
  mkdir -p "$t/scripts/ci" "$t/bin" "$t/kube" "$t/evidence"
  cp -r "$ROOT/scripts/lib" "$t/scripts/lib"
  cp "$ROOT/scripts/ci/verify_compat.sh" "$t/scripts/ci/"
  cp "$ROOT/versions.lock.yaml" "$t/versions.lock.yaml"
  cat >"$t/scripts/lib/image_build.sh" <<EOF
image_build::content_hash() { echo "$HASH"; }
EOF
  record_build "$t" "$IMGID"
  # the stub answers `get <what> [name] ... -o json|name` from kube/<what>[-<name>].json|.name
  cat >"$t/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
K="${STUB_KUBE:?}"
a=(); while [[ $# -gt 0 ]]; do case "$1" in --context) shift 2 ;; *) a+=("$1"); shift ;; esac; done
set -- "${a[@]}"
[[ "$1" == get ]] || exit 0
what="$2"; name=""; [[ -n "${3:-}" && "$3" != -* ]] && name="$3"
fmt=json; [[ " $* " == *" -o name "* ]] && fmt=name
f="$K/${what}${name:+-$name}.$fmt"
[[ -f "$f" ]] && { cat "$f"; exit 0; }
echo "Error from server (NotFound): $what \"$name\" not found" >&2; exit 1
EOF
  chmod +x "$t/bin/kubectl"
  local lock_compat id
  lock_compat="$(yq -o=json '.compatibilitySet' "$t/versions.lock.yaml" | jq -S -c .)"
  id="sha256:$(printf '%s' "$lock_compat" | sha256sum | awk '{print $1}')"
  jq -n --arg c "$lock_compat" --arg id "$id" '{kind: "ConfigMap", data: {"compatibility-set.json": $c, id: $id}}' \
    >"$t/kube/configmap-srl-provider-compat.json"
  jq -n --arg id "$id" '{items: [
     {metadata: {namespace: "agentic-netops-system", name: "fabric01.leaf01", annotations: {"agentic-netops.io/compatibility-set": $id}}},
     {metadata: {namespace: "sdc-system", name: "someone-elses", annotations: {}}}]}' >"$t/kube/configs.config.sdcio.dev.json"
  local s
  for s in v1alpha1.vlan.be.kuid.dev v1alpha1.genid.be.kuid.dev v1alpha1.ipam.be.kuid.dev v1alpha1.as.be.kuid.dev; do
    echo "apiservice.apiregistration.k8s.io/$s" >"$t/kube/apiservice-$s.name"
  done
  printf 'apiservice.apiregistration.k8s.io/v1alpha1.%s.be.kuid.dev\n' vlan genid ipam as >"$t/kube/apiservice.name"
  pods "$t" "srl-provider:$HASH" "docker.io/library/srl-provider@$IMGID" Running
}

record_build() {  # record_build <tree> <image-id> — the evidence record image_build::build writes
  local t="$1"
  echo "$2" >"$t/evidence/image-build.srl-provider.${HASH:0:12}.stdout"
  : >"$t/evidence/image-build.srl-provider.${HASH:0:12}.stderr"
  jq -n '{kind: "run", exit_status: 0, utc_time: "2026-09-21T10:00:00Z",
          raw_output: {stdout: {file: "image-build.srl-provider.'"${HASH:0:12}"'.stdout"}}}' \
    >"$t/evidence/image-build.srl-provider.${HASH:0:12}.json"
}

pods() {  # pods <tree> <image> <imageID> <phase>
  jq -n --arg img "$2" --arg iid "$3" --arg ph "$4" '{items: [
    {metadata: {namespace: "agentic-netops-system", name: "srl-provider-7d9f-abcde"},
     spec: {containers: [{name: "manager", image: $img}]},
     status: {phase: $ph, containerStatuses: [{name: "manager", imageID: $iid}]}},
    {metadata: {namespace: "sdc-system", name: "config-server-0"},
     spec: {containers: [{name: "api", image: "ghcr.io/sdcio/config-server-api-server:v0.0.58@sha256:bd5d"}]},
     status: {phase: "Running", containerStatuses: [{name: "api", imageID: "ghcr.io/sdcio/x@sha256:1"}]}}]}' >"$1/kube/pods.json"
}

run() {  # run <tree> — exit status; output in <tree>/out
  ( cd "$1" && PATH="$1/bin:$PATH" STUB_KUBE="$1/kube" KUBECTL="$1/bin/kubectl" EVIDENCE_DIR="$1/evidence" \
      CLUSTER_NAME=agentic-netops bash scripts/ci/verify_compat.sh ) >"$1/out" 2>&1
}

expect_fail() {  # expect_fail <label> <tree> <pattern>
  local rc=0; run "$2" || rc=$?
  if [[ "$rc" -eq 1 ]] && grep -qE -- "$3" "$2/out"; then
    pass "$1 → fails naming it: $(grep -E -- "$3" "$2/out" | head -n1 | sed 's/.*FAIL //' | cut -c1-110)"
  else
    fail "$1 → should fail (rc=1) naming /$3/ (rc=$rc)" "$(cat "$2/out")"
  fi
}

# ------------------------------------------------------------------ healthy
t="$TMP/ok"; make_tree "$t"
rc=0; run "$t" || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'PASS images: workload agentic-netops-system/srl-provider-7d9f-abcde' "$t/out"; then
  pass "healthy lab: compatibility set, one authority (kuid) and the provider image all hold"
else
  fail "healthy lab should pass (rc=$rc)" "$(cat "$t/out")"
fi
grep -q 'config-server-0' "$t/out" && fail "an upstream (pinned) workload was treated as first-party" \
  || pass "upstream workloads are not held to the first-party content-hash rule"

# ------------------------------------------------------------------ compat
t="$TMP/part5"; make_tree "$t"
jq '.data["compatibility-set.json"] |= (fromjson | .deviceConfiguration.configServer.tag = "v0.0.57" | tojson)' \
  "$t/kube/configmap-srl-provider-compat.json" >"$t/x" && mv "$t/x" "$t/kube/configmap-srl-provider-compat.json"
expect_fail "published set with part 5 changed" "$t" 'part 5 \(deviceConfiguration\)'

t="$TMP/id"; make_tree "$t"
jq '.data.id = "sha256:deadbeef"' "$t/kube/configmap-srl-provider-compat.json" >"$t/x" && mv "$t/x" "$t/kube/configmap-srl-provider-compat.json"
expect_fail "published id differs" "$t" "published id 'sha256:deadbeef'"

t="$TMP/nocm"; make_tree "$t"; rm "$t/kube/configmap-srl-provider-compat.json"
expect_fail "no published compatibility set" "$t" 'srl-provider-compat .*cannot be read'

t="$TMP/config"; make_tree "$t"
jq '.items[0].metadata.annotations["agentic-netops.io/compatibility-set"] = "sha256:old"' "$t/kube/configs.config.sdcio.dev.json" >"$t/x" \
  && mv "$t/x" "$t/kube/configs.config.sdcio.dev.json"
expect_fail "a provider Config stamped with another set" "$t" 'Config agentic-netops-system/fabric01.leaf01 stamped sha256:old'

# ------------------------------------------------------------------ authority
t="$TMP/two-kuid"; make_tree "$t"
echo "customresourcedefinition.apiextensions.k8s.io/identifierclaims.fabric.agentic-netops.io" >"$t/kube/crd-identifierclaims.fabric.agentic-netops.io.name"
expect_fail "kuid selected with the IdentifierClaim CRD present" "$t" 'two allocation authorities .*identifierclaims.fabric.agentic-netops.io'

t="$TMP/kuid-absent"; make_tree "$t"; rm "$t/kube/apiservice-v1alpha1.vlan.be.kuid.dev.name"
expect_fail "kuid selected but not installed" "$t" 'APIService v1alpha1.vlan.be.kuid.dev is not installed'

t="$TMP/two-fp"; make_tree "$t"
yq -i '.allocationAuthority = {"kind": "first-party", "decisionRecord": "docs/decisions/allocator-substitution.md", "failedGateEvidence": {"path": "x", "sha256": "y"}}' "$t/versions.lock.yaml"
for c in identifierpools identifierclaims; do echo "crd/$c" >"$t/kube/crd-$c.fabric.agentic-netops.io.name"; done
expect_fail "first-party selected with a *.be.kuid.dev APIService present" "$t" 'two allocation authorities — first-party is selected and .*be.kuid.dev'
rm "$t/kube/apiservice.name"
rc=0; run "$t" || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'exactly one allocation authority — first-party' "$t/out"; then
  pass "first-party selected, no kuid APIService → one authority holds"
else
  fail "first-party alone should pass (rc=$rc)" "$(cat "$t/out")"
fi

# ------------------------------------------------------------------ images
t="$TMP/tag"; make_tree "$t"; pods "$t" "srl-provider:dev" "docker.io/library/srl-provider@$IMGID" Running
expect_fail "provider running a tag other than the content hash" "$t" 'workload agentic-netops-system/srl-provider-7d9f-abcde container manager runs srl-provider:dev, not srl-provider:0123456789ab'

t="$TMP/imgid"; make_tree "$t"; pods "$t" "srl-provider:$HASH" "docker.io/library/srl-provider@$OTHERID" Running
expect_fail "provider running an image ID the build did not record" "$t" "workload agentic-netops-system/srl-provider-7d9f-abcde container manager runs image ID ${OTHERID}"

t="$TMP/norecord"; make_tree "$t"; rm "$t/evidence/image-build.srl-provider.${HASH:0:12}.json"
expect_fail "no image ID recorded in this run's evidence" "$t" 'records no image ID for srl-provider:0123456789ab'

t="$TMP/norun"; make_tree "$t"; pods "$t" "srl-provider:$HASH" "docker.io/library/srl-provider@$IMGID" Pending
expect_fail "provider not running" "$t" 'provider agentic-netops-system/srl-provider|no running first-party workload'

echo
if [[ "$fails" -eq 0 ]]; then echo "verify_compat_test: all checks passed"; exit 0; fi
echo "verify_compat_test: ${fails} check(s) failed"; exit 1
