#!/usr/bin/env bash
# fetch_upstream.sh — vendor the pinned upstream install artefacts (T035; FR-098, FR-009, NFR-003).
#
# Fetches each project's install artefacts FROM THAT PROJECT'S OWN RELEASE OR TAG, at the
# version versions.lock.yaml pins, verifies the bytes against what the project itself
# publishes, and writes them — unmodified, behind a provenance header — under:
#
#   deploy/cert-manager/upstream/   cert-manager release asset `cert-manager.yaml`
#                                   (platform.certManager.version; verified against the
#                                   sha256 digest GitHub publishes for the release asset)
#   deploy/sdc/upstream/            sdcio/config-server `artifacts/…` at the tag commit
#                                   (compatibilitySet.deviceConfiguration.configServer)
#   deploy/kuid/upstream/           kuidio/kuid `artifacts/…` at the tag commit
#                                   (compatibilitySet.allocationAuthorityRelease.kuid)
#
# For a tag, the tag must resolve (peeled) to the commit the lock records, and every file is
# checked against the git blob id the tag's tree lists for it. Neither config-server v0.0.58
# nor kuid v0.0.13 publishes its manifests as a release asset (their releases carry binaries
# only), so the raw files of `artifacts/` at the tag commit ARE the published artefact.
# What is NOT vendored, and why (the kustomization in each dir is the only glue):
#   * kform input files (artifacts/in/, configmap-input-vars.yaml) — template inputs naming
#     `:latest` images, not Kubernetes objects; images are pinned by kustomize instead;
#   * the static TLS Secrets (artifacts/secret.yaml) — a private key published in a repo; the
#     serving certificates are issued by cert-manager (first-party Certificate in each dir);
#   * kuid's apiservice-vxlan.yaml — the vxlan backend does not exist at v0.0.13 and the
#     server's own config does not enable the group (an unavailable APIService breaks
#     discovery); prometheus/, monitor/, token/ — optional add-ons this platform does not use.
#
# The header written at the top of every vendored file (verify_provenance_headers.sh and
# verify_upstream_artefacts.sh read it):
#   # provenance: source=<url fetched> version=<tag> commit=<tag commit> digest=sha256:<sha256 of the upstream bytes>
#   # vendored-by: scripts/lib/fetch_upstream.sh … (never edit; re-run the fetcher)
#   # --- end of provenance header ---
#   <the upstream bytes, unmodified>
#
# Failure: the fetcher FAILS NAMING THE ARTEFACT it could not fetch or verify, and writes
# nothing — every artefact of the run is fetched into a temporary directory and verified
# first; only when all of them are good are the upstream/ directories replaced. There is no
# fallback and no stand-in (FR-098).
#
# Usage: fetch_upstream.sh [--root <dir>] [--lock <file>] [--only cert-manager|sdc|kuid]
#   CURL overrides the client (tests); GITHUB_TOKEN, when set, authenticates API calls.
# Exit: 0 all fetched and written; 1 an artefact could not be fetched or verified; 2 usage.
set -euo pipefail

FU_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
FU_LOCK=""
FU_ONLY=""
FU_HEADER_END="# --- end of provenance header ---"

# The vendored set, relative to each repository's root at the tag.
FU_SDC_PATHS=(
  artifacts/ns.yaml
  artifacts/inv.sdcio.dev_discoveryrules.yaml
  artifacts/inv.sdcio.dev_discoveryvendorprofiles.yaml
  artifacts/inv.sdcio.dev_rollouts.yaml
  artifacts/inv.sdcio.dev_schemas.yaml
  artifacts/inv.sdcio.dev_subscriptions.yaml
  artifacts/inv.sdcio.dev_targetconnectionprofiles.yaml
  artifacts/inv.sdcio.dev_targetsyncprofiles.yaml
  artifacts/inv.sdcio.dev_workspaces.yaml
  artifacts/apiservice.yaml
  artifacts/certmanager/clusterissuer.yaml
  artifacts/configmap-data-server.yaml
  artifacts/deployment-apiserver.yaml
  artifacts/deployment-controller.yaml
  artifacts/statefulset-data-server.yaml
  artifacts/pv-config-server-store.yaml
  artifacts/pv-data-server-schemadb.yaml
  artifacts/pv-schema-server-schema.yaml
  artifacts/pv-workspace-store.yaml
  artifacts/rbac-cluster-role-api-server.yaml
  artifacts/rbac-cluster-role-binding-api-server.yaml
  artifacts/rbac-cluster-role-binding-auth-delegator.yaml
  artifacts/rbac-cluster-role-binding-controller.yaml
  artifacts/rbac-cluster-role-binding-data-server-controller.yaml
  artifacts/rbac-cluster-role-binding-metrics.yaml
  artifacts/rbac-cluster-role-controller.yaml
  artifacts/rbac-cluster-role-data-server-controller.yaml
  artifacts/rbac-cluster-role-metrics.yaml
  artifacts/rbac-cluster-role-metrics_reader.yaml
  artifacts/rbac-role-binding-auth-reader.yaml
  artifacts/rbac-role.yaml
  artifacts/sa-apiserver.yaml
  artifacts/sa-controller.yaml
  artifacts/sa-dataserver.yaml
  artifacts/service-apiserver.yaml
  artifacts/service-data-server.yaml
  artifacts/service-metrics.yaml
  artifacts/service-schema-server.yaml
  artifacts/service-target-metrics.yaml
  artifacts/allow-apiserver-extension-traffic.yaml
  artifacts/allow-metrics-traffic.yaml
)
FU_KUID_PATHS=(
  artifacts/ns.yaml
  artifacts/apiservice-as.yaml
  artifacts/apiservice-extcomm.yaml
  artifacts/apiservice-genid.yaml
  artifacts/apiservice-infra.yaml
  artifacts/apiservice-ipam.yaml
  artifacts/apiservice-vlan.yaml
  artifacts/configmap-config.yaml
  artifacts/deployment.yaml
  artifacts/pv-config-server-store.yaml
  artifacts/rbac-cluster-role-binding-auth-delegator.yaml
  artifacts/rbac-cluster-role-binding-controller-permissions.yaml
  artifacts/rbac-cluster-role-controller-permissions.yaml
  artifacts/rbac-role-binding-auth-reader.yaml
  artifacts/rbac-role-binding.yaml
  artifacts/rbac-role.yaml
  artifacts/sa.yaml
  artifacts/service-api-server.yaml
  artifacts/service-metrics.yaml
)
FU_CERT_MANAGER_ASSET="cert-manager.yaml"

# fetch_upstream::_py <subcommand> <args…> — JSON/YAML/hash helpers.
fetch_upstream::_py() {
  python3 - "$@" <<'PY'
import hashlib, json, sys
cmd, args = sys.argv[1], sys.argv[2:]
def load_json(p):
    with open(p, "rb") as f:
        return json.load(f)
if cmd == "lockget":               # <lock> <dotted.path>
    import yaml
    node = yaml.safe_load(open(args[0]))
    for k in args[1].split("."):
        if not isinstance(node, dict) or k not in node:
            sys.exit(f"key {args[1]} missing")
        node = node[k]
    if node in (None, ""):
        sys.exit(f"key {args[1]} empty")
    print(node)
elif cmd == "tagref":              # <ref json> -> "<type> <sha>"
    d = load_json(args[0])
    if isinstance(d, list):        # a prefix match returns a list; an exact ref is an object
        sys.exit("tag is ambiguous or absent (the API answered with a list of refs)")
    print(d["object"]["type"], d["object"]["sha"])
elif cmd == "tagobj":              # <annotated tag json> -> "<type> <sha>"
    d = load_json(args[0])
    print(d["object"]["type"], d["object"]["sha"])
elif cmd == "treeblob":            # <tree json> <path> -> blob sha
    d = load_json(args[0])
    if d.get("truncated"):
        sys.exit("tree listing is truncated")
    for t in d.get("tree", []):
        if t.get("path") == args[1] and t.get("type") == "blob":
            print(t["sha"]); sys.exit(0)
    sys.exit(f"{args[1]} is not present in the tag's tree")
elif cmd == "asset":               # <release json> <asset name> -> "<url> <digest>"
    d = load_json(args[0])
    for a in d.get("assets", []):
        if a.get("name") == args[1]:
            print(a.get("browser_download_url", ""), a.get("digest") or "-"); sys.exit(0)
    sys.exit(f"the release has no asset named {args[1]}")
elif cmd == "blobsha":             # <file> -> git blob id (sha1 of "blob <len>\0<bytes>")
    b = open(args[0], "rb").read()
    print(hashlib.sha1(b"blob %d\0" % len(b) + b).hexdigest())
elif cmd == "sha256":
    print(hashlib.sha256(open(args[0], "rb").read()).hexdigest())
else:
    sys.exit(f"unknown helper {cmd}")
PY
}

# fetch_upstream::_fail <artefact> <url> <reason> — the one failure message: names the artefact.
fetch_upstream::_fail() {
  echo "fetch_upstream: FAIL artefact '$1' could not be fetched from $2: $3 — nothing was written (no stand-in is ever used, FR-098)" >&2
  return 1
}

# fetch_upstream::_get <out> <url> — one GET; non-2xx fails (curl -f).
fetch_upstream::_get() {
  local out="$1" url="$2"
  local -a auth=()
  if [[ -n "${GITHUB_TOKEN:-}" && "$url" == https://api.github.com/* ]]; then
    auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  "${CURL:-curl}" -fsSL --retry 2 --connect-timeout 20 "${auth[@]}" -o "$out" "$url"
}

# fetch_upstream::_resolve_tag <artefact> <owner/repo> <tag> <workdir> — prints the peeled commit.
fetch_upstream::_resolve_tag() {
  local art="$1" repo="$2" tag="$3" work="$4" url typ sha
  url="https://api.github.com/repos/${repo}/git/ref/tags/${tag}"
  fetch_upstream::_get "$work/ref.json" "$url" 2>"$work/err" \
    || { fetch_upstream::_fail "$art" "$url" "$(tail -n1 "$work/err" 2>/dev/null || true)"; return 1; }
  read -r typ sha < <(fetch_upstream::_py tagref "$work/ref.json" 2>"$work/err") \
    || { fetch_upstream::_fail "$art" "$url" "$(tail -n1 "$work/err")"; return 1; }
  if [[ "$typ" == "tag" ]]; then   # annotated tag: peel it
    url="https://api.github.com/repos/${repo}/git/tags/${sha}"
    fetch_upstream::_get "$work/tag.json" "$url" 2>"$work/err" \
      || { fetch_upstream::_fail "$art" "$url" "$(tail -n1 "$work/err" 2>/dev/null || true)"; return 1; }
    read -r typ sha < <(fetch_upstream::_py tagobj "$work/tag.json")
  fi
  [[ "$typ" == "commit" && "$sha" =~ ^[0-9a-f]{40}$ ]] \
    || { fetch_upstream::_fail "$art" "$url" "tag does not peel to a commit (got $typ $sha)"; return 1; }
  printf '%s\n' "$sha"
}

# fetch_upstream::_write <dest> <body> <source> <version> <commit> — header + unmodified bytes.
fetch_upstream::_write() {
  local dest="$1" body="$2" src="$3" ver="$4" commit="$5" sum
  sum="$(fetch_upstream::_py sha256 "$body")"
  mkdir -p "$(dirname "$dest")"
  {
    printf '# provenance: source=%s version=%s commit=%s digest=sha256:%s\n' "$src" "$ver" "$commit" "$sum"
    printf '# vendored-by: scripts/lib/fetch_upstream.sh (T035, FR-098) - the bytes after the end marker are the upstream artefact, unmodified; never edit them, re-run the fetcher\n'
    printf '%s\n' "$FU_HEADER_END"
    cat "$body"
  } >"$dest"
}

# fetch_upstream::cert_manager <stage dir> <work dir>
fetch_upstream::cert_manager() {
  local stage="$1" work="$2" ver repo=cert-manager/cert-manager commit url dl digest got art
  ver="$(fetch_upstream::_py lockget "$FU_LOCK" platform.certManager.version)" \
    || { echo "fetch_upstream: FAIL platform.certManager.version is not in $FU_LOCK" >&2; return 1; }
  [[ "$ver" == v* ]] || ver="v$ver"   # the release tag is v-prefixed
  art="cert-manager:${FU_CERT_MANAGER_ASSET}@${ver}"
  commit="$(fetch_upstream::_resolve_tag "$art" "$repo" "$ver" "$work")" || return 1
  url="https://api.github.com/repos/${repo}/releases/tags/${ver}"
  fetch_upstream::_get "$work/release.json" "$url" 2>"$work/err" \
    || { fetch_upstream::_fail "$art" "$url" "$(tail -n1 "$work/err" 2>/dev/null || true)"; return 1; }
  read -r dl digest < <(fetch_upstream::_py asset "$work/release.json" "$FU_CERT_MANAGER_ASSET" 2>"$work/err") \
    || { fetch_upstream::_fail "$art" "$url" "$(tail -n1 "$work/err")"; return 1; }
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || { fetch_upstream::_fail "$art" "$url" "the release publishes no sha256 digest for the asset; it cannot be verified"; return 1; }
  fetch_upstream::_get "$work/asset" "$dl" 2>"$work/err" \
    || { fetch_upstream::_fail "$art" "$dl" "$(tail -n1 "$work/err" 2>/dev/null || true)"; return 1; }
  got="sha256:$(fetch_upstream::_py sha256 "$work/asset")"
  [[ "$got" == "$digest" ]] \
    || { fetch_upstream::_fail "$art" "$dl" "sha256 mismatch: fetched $got, the release publishes $digest"; return 1; }
  fetch_upstream::_write "$stage/cert-manager/$FU_CERT_MANAGER_ASSET" "$work/asset" "$dl" "$ver" "$commit"
  echo "fetch_upstream: ok $art ($got, tag commit $commit)" >&2
}

# fetch_upstream::_tag_tree <project> <stage> <work> <lock prefix> <paths…>
fetch_upstream::_tag_tree() {
  local proj="$1" stage="$2" work="$3" prefix="$4"; shift 4
  local repo_url repo tag want commit url path blob got raw
  if ! { repo_url="$(fetch_upstream::_py lockget "$FU_LOCK" "$prefix.repository")" \
      && tag="$(fetch_upstream::_py lockget "$FU_LOCK" "$prefix.tag")" \
      && want="$(fetch_upstream::_py lockget "$FU_LOCK" "$prefix.commit")"; }; then
    echo "fetch_upstream: FAIL $prefix.{repository,tag,commit} incomplete in $FU_LOCK" >&2; return 1
  fi
  repo="${repo_url#https://github.com/}"; repo="${repo%.git}"
  commit="$(fetch_upstream::_resolve_tag "$proj:tag $tag" "$repo" "$tag" "$work")" || return 1
  [[ "$commit" == "$want" ]] \
    || { fetch_upstream::_fail "$proj:tag $tag" "https://github.com/$repo" "tag peels to $commit, the lock records $want"; return 1; }
  url="https://api.github.com/repos/${repo}/git/trees/${commit}?recursive=1"
  fetch_upstream::_get "$work/tree.json" "$url" 2>"$work/err" \
    || { fetch_upstream::_fail "$proj:tree@$tag" "$url" "$(tail -n1 "$work/err" 2>/dev/null || true)"; return 1; }
  for path in "$@"; do
    raw="https://raw.githubusercontent.com/${repo}/${commit}/${path}"
    blob="$(fetch_upstream::_py treeblob "$work/tree.json" "$path" 2>"$work/err")" \
      || { fetch_upstream::_fail "$proj:$path@$tag" "$raw" "$(tail -n1 "$work/err")"; return 1; }
    fetch_upstream::_get "$work/file" "$raw" 2>"$work/err" \
      || { fetch_upstream::_fail "$proj:$path@$tag" "$raw" "$(tail -n1 "$work/err" 2>/dev/null || true)"; return 1; }
    got="$(fetch_upstream::_py blobsha "$work/file")"
    [[ "$got" == "$blob" ]] \
      || { fetch_upstream::_fail "$proj:$path@$tag" "$raw" "git blob id mismatch: fetched $got, the tag's tree lists $blob"; return 1; }
    fetch_upstream::_write "$stage/$proj/${path#artifacts/}" "$work/file" "$raw" "$tag" "$commit"
  done
  echo "fetch_upstream: ok $proj — $# artefact(s) of $repo@$tag ($commit)" >&2
}

fetch_upstream::sdc() {
  fetch_upstream::_tag_tree sdc "$1" "$2" compatibilitySet.deviceConfiguration.configServer "${FU_SDC_PATHS[@]}"
}
fetch_upstream::kuid() {
  fetch_upstream::_tag_tree kuid "$1" "$2" compatibilitySet.allocationAuthorityRelease.kuid "${FU_KUID_PATHS[@]}"
}

# fetch_upstream::_install <stage> <project> — replace deploy/<project>/upstream/ with the staged tree.
fetch_upstream::_install() {
  local stage="$1" proj="$2" dest new old
  dest="$FU_ROOT/deploy/$proj/upstream"
  new="$FU_ROOT/deploy/$proj/.upstream.new.$$"; old="$FU_ROOT/deploy/$proj/.upstream.old.$$"
  mkdir -p "$FU_ROOT/deploy/$proj"
  rm -rf "$new" "$old"
  cp -R "$stage/$proj" "$new"
  [[ -d "$dest" ]] && mv "$dest" "$old"
  mv "$new" "$dest"
  rm -rf "$old"
}

fetch_upstream::main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root) FU_ROOT="$(cd -- "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
      --lock) FU_LOCK="${2:?--lock needs a file}"; shift 2 ;;
      --only) FU_ONLY="${2:?--only needs cert-manager|sdc|kuid}"; shift 2 ;;
      -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; return 0 ;;
      *) echo "fetch_upstream: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  [[ -n "$FU_LOCK" ]] || FU_LOCK="$FU_ROOT/versions.lock.yaml"
  [[ -f "$FU_LOCK" ]] || { echo "fetch_upstream: lock file $FU_LOCK not found" >&2; return 2; }
  local -a projects=(cert-manager sdc kuid)
  if [[ -n "$FU_ONLY" ]]; then
    case "$FU_ONLY" in cert-manager|sdc|kuid) projects=("$FU_ONLY") ;;
      *) echo "fetch_upstream: --only takes cert-manager, sdc or kuid, not '$FU_ONLY'" >&2; return 2 ;; esac
  fi
  local tmp p
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/fetch_upstream.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp' '$FU_ROOT'/deploy/*/.upstream.new.$$" EXIT
  mkdir -p "$tmp/stage" "$tmp/work"
  for p in "${projects[@]}"; do
    mkdir -p "$tmp/stage/$p"
    case "$p" in
      cert-manager) fetch_upstream::cert_manager "$tmp/stage" "$tmp/work" || return 1 ;;
      sdc) fetch_upstream::sdc "$tmp/stage" "$tmp/work" || return 1 ;;
      kuid) fetch_upstream::kuid "$tmp/stage" "$tmp/work" || return 1 ;;
    esac
  done
  # Every artefact is fetched and verified: only now is anything in the tree replaced.
  for p in "${projects[@]}"; do
    fetch_upstream::_install "$tmp/stage" "$p"
    echo "fetch_upstream: wrote deploy/$p/upstream/ ($(find "$FU_ROOT/deploy/$p/upstream" -type f | wc -l) file(s))" >&2
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  fetch_upstream::main "$@"
fi
