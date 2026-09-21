#!/usr/bin/env bash
# verify-upstream-artefacts suite (T035; FR-098, FR-009, NFR-003).
#
# Every case is a miniature repository root built in a temp dir (so no planted
# stand-in ever sits in this tree for the real check to find); the checker runs
# on it with --root/--lock and must give the verdict the case was planted for,
# NAMING THE FILE:
#   clean tree (vendored sdcio CRD + kuid APIService with valid headers, a
#     first-party CRD in fabric.agentic-netops.io, pinned images)      passes
#   first-party CRD in inv.sdcio.dev under config/crd/                  fails naming it
#   first-party APIService in ipam.be.kuid.dev under deploy/            fails naming it
#   first-party CRD in acme.cert-manager.io                             fails naming it
#   a vendored file edited after fetch (sha256 no longer matches)       fails naming it
#   a vendored file without its provenance header                       fails naming it
#   an sdcio CRD vendored under deploy/kuid/ (wrong project)            fails naming it
#   a first-party Go package declaring +groupName=config.sdcio.dev      fails naming it
#   a kustomization image that is not a versions.lock.yaml pin          fails naming it
#   substitute-shape (the first-party allocation authority, FR-098/FR-104):
#     a clean substitute (IdentifierPool/IdentifierClaim CRDs, pools, Role on
#       fabric.agentic-netops.io)                                        passes
#     an object in vlan.be.kuid.dev under deploy/allocation/            fails naming it
#     a first-party object named like a kuid kind (VLANIndex) in its own group fails naming it
#     a conditional CRD whose names.kind is IPClaim                      fails naming it
#     a first-party claim Role granting on ipam.be.kuid.dev              fails naming it
# Finally the checker passes on this repository itself. Offline; python3 + PyYAML.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
VU="$ROOT/scripts/ci/verify_upstream_artefacts.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

CS_COMMIT=bcc56b045a689032c5123a9f50bcf56ed8c630dc
KD_COMMIT=7528e81528c2e9f586b6fe657907424ad93c7ead
PIN_API="ghcr.io/sdcio/config-server-api-server:v0.0.58@sha256:bd5d312512ad7484eadb6b8e43ef550f647034abdead80429b8ba17d74041f9e"

# lock <root> — the lock keys the checker reads.
lock() {
  cat >"$1/versions.lock.yaml" <<YAML
compatibilitySet:
  deviceConfiguration:
    configServer: {repository: https://github.com/sdcio/config-server, tag: v0.0.58, commit: "$CS_COMMIT"}
    images:
      apiServer: {pinned: "$PIN_API"}
  allocationAuthorityRelease:
    kuid: {repository: https://github.com/kuidio/kuid, tag: v0.0.13, commit: "$KD_COMMIT"}
platform:
  certManager: {version: v1.20.4}
YAML
}

# vend <root> <sdc|kuid> <rel path under upstream/> — stdin is the upstream body.
vend() {
  local r="$1" proj="$2" rel="$3" body sum src ver commit
  body="$(mktemp -p "$TMP")"; cat >"$body"
  sum="$(sha256sum "$body" | cut -d' ' -f1)"
  case "$proj" in
    sdc)  src="https://raw.githubusercontent.com/sdcio/config-server/$CS_COMMIT/artifacts/$rel"; ver=v0.0.58; commit=$CS_COMMIT ;;
    kuid) src="https://raw.githubusercontent.com/kuidio/kuid/$KD_COMMIT/artifacts/$rel"; ver=v0.0.13; commit=$KD_COMMIT ;;
  esac
  mkdir -p "$(dirname "$r/deploy/$proj/upstream/$rel")"
  {
    printf '# provenance: source=%s version=%s commit=%s digest=sha256:%s\n' "$src" "$ver" "$commit" "$sum"
    printf '# vendored-by: scripts/lib/fetch_upstream.sh\n# --- end of provenance header ---\n'
    cat "$body"
  } >"$r/deploy/$proj/upstream/$rel"
}

crd() { printf 'apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\nmetadata:\n  name: %s\nspec:\n  group: %s\n  names: {kind: X, plural: xs}\n  scope: Namespaced\n' "$1" "$2"; }
apisvc() { printf 'apiVersion: apiregistration.k8s.io/v1\nkind: APIService\nmetadata:\n  name: v1alpha1.%s\nspec:\n  group: %s\n  version: v1alpha1\n' "$1" "$1"; }

# clean <root> — a tree that passes.
clean() {
  local r="$1"; mkdir -p "$r/config/crd" "$r/deploy/sdc" "$r/deploy/kuid"
  lock "$r"
  crd schemas.inv.sdcio.dev inv.sdcio.dev | vend "$r" sdc inv.sdcio.dev_schemas.yaml
  apisvc ipam.be.kuid.dev | vend "$r" kuid apiservice-ipam.yaml
  crd fabrics.fabric.agentic-netops.io fabric.agentic-netops.io >"$r/config/crd/fabric.yaml"
  printf 'resources: [upstream/inv.sdcio.dev_schemas.yaml]\nimages:\n- name: ghcr.io/sdcio/config-server-api-server\n  newTag: "%s"\n' "${PIN_API#*:}" >"$r/deploy/sdc/kustomization.yaml"
  printf 'resources: [upstream/apiservice-ipam.yaml]\n' >"$r/deploy/kuid/kustomization.yaml"
}

# expect <case root> <want-rc> <label> [<fixed string the output must contain>…]
expect() {
  local dir="$1" want="$2" label="$3"; shift 3
  local out rc p n
  out="$(bash "$VU" --root "$dir" 2>&1)"; rc=$?
  if [[ "$rc" -ne "$want" ]]; then fail "$label (rc=$rc, want $want)" "$out"; return; fi
  for p in "$@"; do grep -qF -- "$p" <<<"$out" || { fail "$label (output lacks '$p')" "$out"; return; }; done
  if [[ "$want" -ne 0 ]]; then
    n="$(grep -c '^FAIL' <<<"$out")"
    [[ "$n" -eq $# ]] || { fail "$label ($n FAIL line(s), want $#)" "$out"; return; }
  fi
  pass "$label"
}

c="$TMP/clean"; clean "$c"
expect "$c" 0 "clean tree: vendored upstream CRD/APIService with valid headers, first-party CRD in own group, pinned image" \
  "verify-upstream-artefacts: PASS 2 vendored file(s)"

c="$TMP/crd-sdcio"; clean "$c"; crd targets.inv.sdcio.dev inv.sdcio.dev >"$c/config/crd/inv.sdcio.dev_targets.yaml"
expect "$c" 1 "first-party CRD in inv.sdcio.dev under config/crd fails naming the file" \
  "FAIL [upstream-origin] config/crd/inv.sdcio.dev_targets.yaml:1: CustomResourceDefinition targets.inv.sdcio.dev in upstream API group inv.sdcio.dev: it originates in this repository"

c="$TMP/apisvc-kuid"; clean "$c"; mkdir -p "$c/deploy/agentic-netops"
{ printf 'apiVersion: v1\nkind: Namespace\nmetadata: {name: x}\n---\n'; apisvc ipam.be.kuid.dev; } >"$c/deploy/agentic-netops/allocator-api.yaml"
expect "$c" 1 "first-party APIService in ipam.be.kuid.dev fails naming the file and line" \
  "FAIL [upstream-origin] deploy/agentic-netops/allocator-api.yaml:5: APIService v1alpha1.ipam.be.kuid.dev in upstream API group ipam.be.kuid.dev"

c="$TMP/crd-acme"; clean "$c"; mkdir -p "$c/examples"; crd orders.acme.cert-manager.io acme.cert-manager.io >"$c/examples/orders.yaml"
expect "$c" 1 "first-party CRD in acme.cert-manager.io fails naming the file" \
  "FAIL [upstream-origin] examples/orders.yaml:1: CustomResourceDefinition orders.acme.cert-manager.io"

c="$TMP/tampered"; clean "$c"; printf '  # locally patched\n' >>"$c/deploy/sdc/upstream/inv.sdcio.dev_schemas.yaml"
expect "$c" 1 "vendored file edited after fetch fails naming the file (content changed, and its CRD no longer counts as upstream)" \
  "FAIL [vendored] deploy/sdc/upstream/inv.sdcio.dev_schemas.yaml:1: content changed" \
  "FAIL [upstream-origin] deploy/sdc/upstream/inv.sdcio.dev_schemas.yaml:4: CustomResourceDefinition schemas.inv.sdcio.dev in upstream API group inv.sdcio.dev: it is in the vendored tree but its provenance header does not verify"

c="$TMP/no-header"; clean "$c"; printf 'apiVersion: v1\nkind: Namespace\nmetadata: {name: sdc-system}\n' >"$c/deploy/sdc/upstream/ns.yaml"
expect "$c" 1 "vendored file without its provenance header fails naming the file" \
  "FAIL [vendored] deploy/sdc/upstream/ns.yaml:1: no provenance header"

c="$TMP/wrong-project"; clean "$c"; crd targets.inv.sdcio.dev inv.sdcio.dev | vend "$c" kuid smuggled.yaml
expect "$c" 1 "sdcio CRD vendored under deploy/kuid/ fails naming the file" \
  "FAIL [upstream-origin] deploy/kuid/upstream/smuggled.yaml:4: CustomResourceDefinition targets.inv.sdcio.dev in upstream API group inv.sdcio.dev: it is vendored under deploy/kuid/ but the group belongs to deploy/sdc/"

c="$TMP/go-group"; clean "$c"; mkdir -p "$c/api/sdc/v1alpha1"
printf '// Package v1alpha1 is a look-alike.\n// +groupName=config.sdcio.dev\npackage v1alpha1\n' >"$c/api/sdc/v1alpha1/doc.go"
expect "$c" 1 "first-party Go package declaring +groupName=config.sdcio.dev fails naming the file" \
  "FAIL [go-group] api/sdc/v1alpha1/doc.go:2: first-party Go API declares upstream group config.sdcio.dev"

c="$TMP/image-pin"; clean "$c"; sed -i 's/newTag: "v0.0.58@/newTag: "v0.0.57@/' "$c/deploy/sdc/kustomization.yaml"
expect "$c" 1 "kustomization image that is not a lock pin fails naming the file" \
  "FAIL [image-pin] deploy/sdc/kustomization.yaml: image 'ghcr.io/sdcio/config-server-api-server:v0.0.57@sha256:"

# substitute-shape — the first-party allocation authority never is, nor imitates, kuid.
substitute() {  # substitute <root> — a clean first-party authority tree
  local r="$1"
  mkdir -p "$r/deploy/allocation/pools" "$r/config/crd/conditional" "$r/config/rbac/claims/first-party"
  crd identifierpools.fabric.agentic-netops.io fabric.agentic-netops.io | sed 's/kind: X, plural: xs/kind: IdentifierPool, plural: identifierpools/' >"$r/config/crd/conditional/pools.yaml"
  printf 'apiVersion: fabric.agentic-netops.io/v1alpha1\nkind: IdentifierPool\nmetadata: {name: fabric01-vlan, namespace: agentic-netops-allocation}\nspec: {type: vlan, range: {start: 1000, end: 4000}}\n' >"$r/deploy/allocation/pools/vlan.yaml"
  printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: Role\nmetadata: {name: srl-provider-claims, namespace: agentic-netops-allocation}\nrules:\n- apiGroups: [fabric.agentic-netops.io]\n  resources: [identifierclaims]\n  verbs: [get, list, watch, create, delete]\n' >"$r/config/rbac/claims/first-party/role.yaml"
}
c="$TMP/sub-clean"; clean "$c"; substitute "$c"
expect "$c" 0 "substitute-shape: a clean first-party authority (own group, own kinds) passes" "verify-upstream-artefacts: PASS"

c="$TMP/sub-group"; clean "$c"; substitute "$c"
printf -- '---\napiVersion: vlan.be.kuid.dev/v1alpha1\nkind: VLANIndex\nmetadata: {name: fabric01-vlan}\nspec: {minID: 1000, maxID: 4000}\n' >>"$c/deploy/allocation/pools/vlan.yaml"
expect "$c" 1 "substitute-shape: a kuid VLANIndex under deploy/allocation/ fails naming the file, the group and the kind" \
  "FAIL [substitute-shape] deploy/allocation/pools/vlan.yaml:6: VLANIndex fabric01-vlan is in the kuid API group vlan.be.kuid.dev" \
  "FAIL [substitute-shape] deploy/allocation/pools/vlan.yaml:6: VLANIndex fabric01-vlan is named like a kuid kind"

c="$TMP/sub-lookalike"; clean "$c"; substitute "$c"
printf 'apiVersion: fabric.agentic-netops.io/v1alpha1\nkind: GENIDIndex\nmetadata: {name: fabric01-vni}\n' >"$c/deploy/allocation/pools/vni.yaml"
expect "$c" 1 "substitute-shape: a first-party object shaped like a kuid kind (GENIDIndex in its own group) fails naming it" \
  "FAIL [substitute-shape] deploy/allocation/pools/vni.yaml:1: GENIDIndex fabric01-vni is named like a kuid kind"

c="$TMP/sub-crd"; clean "$c"; substitute "$c"
crd ipclaims.fabric.agentic-netops.io fabric.agentic-netops.io | sed 's/kind: X, plural: xs/kind: IPClaim, plural: ipclaims/' >"$c/config/crd/conditional/claims.yaml"
expect "$c" 1 "substitute-shape: a conditional CRD whose names.kind is a kuid kind fails naming it" \
  "FAIL [substitute-shape] config/crd/conditional/claims.yaml:1: CustomResourceDefinition ipclaims.fabric.agentic-netops.io names.kind 'IPClaim'" \
  "FAIL [substitute-shape] config/crd/conditional/claims.yaml:1: CustomResourceDefinition ipclaims.fabric.agentic-netops.io names.plural 'ipclaims'"

c="$TMP/sub-rbac"; clean "$c"; substitute "$c"
printf -- '- apiGroups: [ipam.be.kuid.dev]\n  resources: [ipclaims]\n  verbs: [get]\n' >>"$c/config/rbac/claims/first-party/role.yaml"
expect "$c" 1 "substitute-shape: the first-party claim Role granting on ipam.be.kuid.dev fails naming it" \
  "FAIL [substitute-shape] config/rbac/claims/first-party/role.yaml:8: Role srl-provider-claims grants on the kuid API group ipam.be.kuid.dev"

# The repository itself.
out="$(bash "$VU" 2>&1)"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "this repository: $(tail -n1 <<<"$out" | cut -c1-110)"; else fail "this repository (rc=$rc)" "$out"; fi

echo "verify_upstream_test: $([[ $fails -eq 0 ]] && echo PASS || echo "FAIL ($fails)")"
[[ "$fails" -eq 0 ]]
