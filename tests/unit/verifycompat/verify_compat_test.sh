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
#   * a standing lab (no build in this run, no COMPAT_BUILD_EVIDENCE_DIR): the provisioning run's
#     records stamped with the live cluster's UID count; another cluster's never do
#   * the provider not running                                                   → the provider
#   * first-party selected: the allocation authority (agentic-netops-allocation/allocation-authority,
#     the provider's image) is held to the same content-hash rule, and not running → named
# The suite runs on a fixture lock that selects kuid unless a case selects first-party.
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
  yq -i '.allocationAuthority = {"kind": "kuid"}' "$t/versions.lock.yaml"
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
  # what the provider publishes (cmd/srl-provider/wiring.go publishCompatibility): the parts it
  # read from the lock baked into its image, and the nine-part identifier (internal/compat)
  local lock_compat id
  lock_compat="$(yq -o=json '.compatibilitySet' "$t/versions.lock.yaml" | jq -S -c .)"
  id="$(jq -r '"1=\(.deviceImage.repository):\(.deviceImage.tag)@\(.deviceImage.digest);2=\(.yangModels.repository)@\(.yangModels.tag)/\(.yangModels.commit);3=\(.deviationPatch.repository)@\(.deviationPatch.commit);4=\(.schema.provider)/\(.schema.version);5=config-server@\(.deviceConfiguration.configServer.tag),data-server@\(.deviceConfiguration.dataServer.tag);6=kuid-server@\(.allocationAuthorityRelease.kuidServer.tag);7=containerlab@\(.containerlab.version);8=gnmic@\(.gnmic.version);9=srl-mapping@\(.srlMapping.version)"' <<<"$lock_compat")"
  jq -n --arg c "$(jq -c --arg id "$id" '. + {identifier: $id}' <<<"$lock_compat")" --arg id "$id" \
    '{kind: "ConfigMap", data: {"compatibility-set.json": $c, identifier: $id}}' \
    >"$t/kube/configmap-srl-provider-compatibility-set.json"
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
  "$t/kube/configmap-srl-provider-compatibility-set.json" >"$t/x" && mv "$t/x" "$t/kube/configmap-srl-provider-compatibility-set.json"
expect_fail "published set with part 5 changed" "$t" 'part 5 \(deviceConfiguration\)'

t="$TMP/id"; make_tree "$t"
jq '.data.identifier |= sub("data-server@[^,;]*"; "data-server@v0.0.66")' "$t/kube/configmap-srl-provider-compatibility-set.json" >"$t/x" && mv "$t/x" "$t/kube/configmap-srl-provider-compatibility-set.json"
expect_fail "published identifier names another data-server" "$t" "does not name the lock's data-server@"

t="$TMP/noid"; make_tree "$t"
jq 'del(.data.identifier)' "$t/kube/configmap-srl-provider-compatibility-set.json" >"$t/x" && mv "$t/x" "$t/kube/configmap-srl-provider-compatibility-set.json"
expect_fail "no published identifier" "$t" 'publishes no identifier'

t="$TMP/extra"; make_tree "$t"
jq '.data["compatibility-set.json"] |= (fromjson | .srlMapping.version = "v0.2.0" | tojson)' \
  "$t/kube/configmap-srl-provider-compatibility-set.json" >"$t/x" && mv "$t/x" "$t/kube/configmap-srl-provider-compatibility-set.json"
expect_fail "published set with part 9 changed" "$t" 'part 9 \(srlMapping\)'

t="$TMP/nocm"; make_tree "$t"; rm "$t/kube/configmap-srl-provider-compatibility-set.json"
expect_fail "no compatibility set published by the provider" "$t" 'srl-provider-compatibility-set .*cannot be read'

t="$TMP/config"; make_tree "$t"
jq '.items[0].metadata.annotations["agentic-netops.io/compatibility-set"] = "sha256:old"' "$t/kube/configs.config.sdcio.dev.json" >"$t/x" \
  && mv "$t/x" "$t/kube/configs.config.sdcio.dev.json"
expect_fail "a provider Config stamped with another set" "$t" 'Config agentic-netops-system/fabric01.leaf01 stamped sha256:old, not the provider'"'"'s published identifier'

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
jq --arg img "srl-provider:$HASH" --arg iid "docker.io/library/srl-provider@$IMGID" '.items += [
  {metadata: {namespace: "agentic-netops-allocation", name: "allocation-authority-5c8b-xyz12"},
   spec: {containers: [{name: "allocation-authority", image: $img}]},
   status: {phase: "Running", containerStatuses: [{name: "allocation-authority", imageID: $iid}]}}]' \
  "$t/kube/pods.json" >"$t/x" && mv "$t/x" "$t/kube/pods.json"
rc=0; run "$t" || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'exactly one allocation authority — first-party' "$t/out"; then
  pass "first-party selected, no kuid APIService → one authority holds"
else
  fail "first-party alone should pass (rc=$rc)" "$(cat "$t/out")"
fi

# ------------------------------------------------------------------ first-party: the authority's workload
fp_tree() {  # fp_tree <dir> <authority image> <authority imageID> — first-party selected, CRDs, no kuid
  make_tree "$1"
  yq -i '.allocationAuthority = {"kind": "first-party", "decisionRecord": "docs/decisions/allocator-substitution.md", "failedGateEvidence": {"path": "x", "sha256": "y"}}' "$1/versions.lock.yaml"
  for c in identifierpools identifierclaims; do echo "crd/$c" >"$1/kube/crd-$c.fabric.agentic-netops.io.name"; done
  rm -f "$1"/kube/apiservice*.name
  [[ -n "$2" ]] && jq --arg img "$2" --arg iid "$3" '.items += [
    {metadata: {namespace: "agentic-netops-allocation", name: "allocation-authority-5c8b-xyz12"},
     spec: {containers: [{name: "allocation-authority", image: $img}]},
     status: {phase: "Running", containerStatuses: [{name: "allocation-authority", imageID: $iid}]}}]' \
    "$1/kube/pods.json" >"$1/x" && mv "$1/x" "$1/kube/pods.json"
  return 0
}
t="$TMP/fp-ok"; fp_tree "$t" "srl-provider:$HASH" "docker.io/library/srl-provider@$IMGID"
rc=0; run "$t" || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'PASS images: workload agentic-netops-allocation/allocation-authority-5c8b-xyz12 container allocation-authority runs srl-provider:0123456789ab' "$t/out"; then
  pass "first-party: the allocation authority runs the tree's srl-provider content hash and the recorded image ID"
else
  fail "first-party healthy lab should pass with the authority's workload checked (rc=$rc)" "$(cat "$t/out")"
fi
t="$TMP/fp-tag"; fp_tree "$t" "srl-provider:dev" "docker.io/library/srl-provider@$IMGID"
expect_fail "first-party: the allocation authority running a tag other than the content hash" "$t" \
  'workload agentic-netops-allocation/allocation-authority-5c8b-xyz12 container allocation-authority runs srl-provider:dev'
t="$TMP/fp-missing"; fp_tree "$t" "" ""
expect_fail "first-party: the allocation authority not running" "$t" 'allocation authority agentic-netops-allocation/allocation-authority, which runs the srl-provider image, is not running'

# ------------------------------------------------------------------ images
t="$TMP/tag"; make_tree "$t"; pods "$t" "srl-provider:dev" "docker.io/library/srl-provider@$IMGID" Running
expect_fail "provider running a tag other than the content hash" "$t" 'workload agentic-netops-system/srl-provider-7d9f-abcde container manager runs srl-provider:dev, not srl-provider:0123456789ab'

t="$TMP/imgid"; make_tree "$t"; pods "$t" "srl-provider:$HASH" "docker.io/library/srl-provider@$OTHERID" Running
expect_fail "provider running an image ID the build did not record" "$t" "workload agentic-netops-system/srl-provider-7d9f-abcde container manager runs image ID ${OTHERID}"

t="$TMP/norecord"; make_tree "$t"; rm "$t/evidence/image-build.srl-provider.${HASH:0:12}.json"
expect_fail "no image ID recorded in this run's evidence" "$t" 'records no image ID for srl-provider:0123456789ab'

# the standing lab (CONTROL_PLANE_ONLY on T152's re-provisioned lab): the build records live in the
# provisioning run's directory, named by COMPAT_BUILD_EVIDENCE_DIR (T152 r8)
t="$TMP/buildrun"; make_tree "$t"; mkdir -p "$t/provisioning"
mv "$t/evidence/image-build.srl-provider.${HASH:0:12}".* "$t/provisioning/"
rc=0; ( cd "$t" && PATH="$t/bin:$PATH" STUB_KUBE="$t/kube" KUBECTL="$t/bin/kubectl" EVIDENCE_DIR="$t/evidence" \
    COMPAT_BUILD_EVIDENCE_DIR="$t/provisioning" CLUSTER_NAME=agentic-netops bash scripts/ci/verify_compat.sh ) >"$t/out" 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "PASS images: workload agentic-netops-system/srl-provider-7d9f-abcde runs\|PASS images: workload agentic-netops-system/srl-provider-7d9f-abcde container manager runs srl-provider:${HASH}" "$t/out"; then
  pass "build record read from the provisioning run (COMPAT_BUILD_EVIDENCE_DIR) when this run holds none"
else
  fail "build record in COMPAT_BUILD_EVIDENCE_DIR should satisfy the image-ID check (rc=$rc)" "$(cat "$t/out")"
fi
expect_fail "the same tree without COMPAT_BUILD_EVIDENCE_DIR" "$t" 'records no image ID for srl-provider:0123456789ab'

# a quickstart walk's closing CONTROL_PLANE_ONLY pass (acceptance-20260928T103226Z): the lab was
# provisioned by an earlier run (§1), later runs of the walk built nothing (§20 tier purge /
# re-provision), the acceptance run's own directory holds no build record, and no
# COMPAT_BUILD_EVIDENCE_DIR is named. The records of the run that provisioned THIS cluster
# (stamped with its kube-system UID) are found under the lab's evidence root; records of another
# cluster of the same name never count.
LIVE_UID="c104c133-935b-4e84-858e-057fee49dcb0"
OLD_UID="0aba14ea-5923-4c7d-9fb7-4db1601d4903"
record_at() {  # record_at <dir> <name> <image-id> <utc> <cluster-uid> [suffix]
  local d="$1" id="image-build.$2.${HASH:0:12}${6:-}"
  mkdir -p "$d"; echo "$3" >"$d/$id.stdout"; : >"$d/$id.stderr"
  jq -n --arg o "$id.stdout" --arg t "$4" --arg u "$5" '{kind: "run", exit_status: 0, utc_time: $t,
      cluster: {name: "agentic-netops", uid: $u}, raw_output: {stdout: {file: $o}}}' >"$d/$id.json"
}
walk_tree() {  # walk_tree <dir> — provider + schema-mirror running; build records only in the §1 run
  local t="$1" lab="$1/evroot/agentic-netops_agentic-netops-fabric"
  make_tree "$t"; rm -f "$t/evidence"/image-build.*
  jq -n --arg u "$LIVE_UID" '{kind: "Namespace", metadata: {name: "kube-system", uid: $u}}' >"$t/kube/namespace-kube-system.json"
  jq --arg img "schema-mirror:$HASH" --arg iid "docker.io/library/schema-mirror@$IMGID" '.items += [
    {metadata: {namespace: "sdc-system", name: "schema-mirror-78786b4c74-xrhwf"},
     spec: {containers: [{name: "schema-mirror", image: $img}]},
     status: {phase: "Running", containerStatuses: [{name: "schema-mirror", imageID: $iid}]}}]' \
    "$t/kube/pods.json" >"$t/x" && mv "$t/x" "$t/kube/pods.json"
  record_at "$lab/20260928T095353Z" srl-provider "$IMGID" 2026-09-28T09:58:20Z "$LIVE_UID"
  record_at "$lab/20260928T095353Z" schema-mirror "$IMGID" 2026-09-28T09:58:27Z "$LIVE_UID"
  mkdir -p "$lab/20260928T103054Z" "$lab/20260928T103204Z" "$lab/acceptance-20260928T103226Z/standing"
  # an earlier lab of the same name, same content hash, another image ID — and a NEWER record
  record_at "$lab/20260929T120000Z-other" schema-mirror "$OTHERID" 2026-09-29T12:00:00Z "$OLD_UID"
  record_at "$lab/20260929T120000Z-other" srl-provider "$OTHERID" 2026-09-29T12:00:00Z "$OLD_UID"
}
walk_run() {  # walk_run <tree> — as acceptance.sh runs it: EVIDENCE_DIR = its standing dir
  local lab="$1/evroot/agentic-netops_agentic-netops-fabric"
  ( cd "$1" && PATH="$1/bin:$PATH" STUB_KUBE="$1/kube" KUBECTL="$1/bin/kubectl" \
      EVIDENCE_DIR="$lab/acceptance-20260928T103226Z/standing" EVIDENCE_ROOT="$1/evroot" \
      CLUSTER_NAME=agentic-netops LAB_NAME=agentic-netops-fabric bash scripts/ci/verify_compat.sh ) >"$1/out" 2>&1
}
walk_fail() {  # walk_fail <label> <tree> <pattern>
  local rc=0; walk_run "$2" || rc=$?
  if [[ "$rc" -eq 1 ]] && grep -qE -- "$3" "$2/out"; then
    pass "$1 → fails naming it: $(grep -E -- "$3" "$2/out" | head -n1 | sed 's/.*FAIL //' | cut -c1-110)"
  else
    fail "$1 → should fail (rc=1) naming /$3/ (rc=$rc)" "$(cat "$2/out")"
  fi
}
t="$TMP/walk"; walk_tree "$t"
rc=0; walk_run "$t" || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "PASS images: workload sdc-system/schema-mirror-78786b4c74-xrhwf container schema-mirror runs schema-mirror:${HASH} (${IMGID})" "$t/out" \
   && grep -q "PASS images: workload agentic-netops-system/srl-provider-7d9f-abcde container manager runs srl-provider:${HASH} (${IMGID})" "$t/out"; then
  pass "standing lab, no COMPAT_BUILD_EVIDENCE_DIR: the build records of the run that provisioned this cluster are found"
else
  fail "the walk's closing acceptance pass should find this cluster's build records (rc=$rc)" "$(cat "$t/out")"
fi
t="$TMP/walk-stale"; walk_tree "$t"
jq --arg iid "docker.io/library/schema-mirror@$OTHERID" '(.items[] | select(.metadata.name | startswith("schema-mirror")) | .status.containerStatuses[0].imageID) = $iid' \
  "$t/kube/pods.json" >"$t/x" && mv "$t/x" "$t/kube/pods.json"
walk_fail "standing lab: schema-mirror runs the image ID another cluster's build recorded" "$t" \
  "workload sdc-system/schema-mirror-78786b4c74-xrhwf container schema-mirror runs image ID ${OTHERID}, not ${IMGID}"
t="$TMP/walk-foreign"; walk_tree "$t"
rm -rf "$t/evroot/agentic-netops_agentic-netops-fabric/20260928T095353Z"
walk_fail "standing lab: only another cluster recorded a build of this content hash" "$t" \
  "workload sdc-system/schema-mirror-78786b4c74-xrhwf container schema-mirror: .*records no image ID for schema-mirror:${HASH}, and no run of this lab \\(cluster uid ${LIVE_UID}\\)"
t="$TMP/walk-nouid"; walk_tree "$t"; rm "$t/kube/namespace-kube-system.json"
walk_fail "standing lab: the cluster's identity cannot be read" "$t" "records no image ID for schema-mirror:${HASH}.*cluster uid unreadable"
t="$TMP/walk-tag"; walk_tree "$t"
jq '(.items[] | select(.metadata.name | startswith("schema-mirror")) | .spec.containers[0].image) = "schema-mirror:dev"' \
  "$t/kube/pods.json" >"$t/x" && mv "$t/x" "$t/kube/pods.json"
walk_fail "standing lab: schema-mirror running a tag other than the content hash" "$t" \
  "workload sdc-system/schema-mirror-78786b4c74-xrhwf container schema-mirror runs schema-mirror:dev, not schema-mirror:${HASH}"

t="$TMP/norun"; make_tree "$t"; pods "$t" "srl-provider:$HASH" "docker.io/library/srl-provider@$IMGID" Pending
expect_fail "provider not running" "$t" 'provider agentic-netops-system/srl-provider|no running first-party workload'

echo
if [[ "$fails" -eq 0 ]]; then echo "verify_compat_test: all checks passed"; exit 0; fi
echo "verify_compat_test: ${fails} check(s) failed"; exit 1
