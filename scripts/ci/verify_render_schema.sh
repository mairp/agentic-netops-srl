#!/usr/bin/env bash
# scripts/ci/verify_render_schema.sh — `make verify-render-schema` (T047; FR-015, FR-020, R-36, AD-71).
#
# Validates every fabric golden render under tests/golden/fabric/ offline against the pinned
# device Schema (deploy/sdc/onboarding/schema.yaml = versions.lock.yaml compatibilitySet part 4)
# with the device-configuration layer's own schema tooling: `sdc-lite config validate`, at the
# release versions.lock.yaml pins under hostTooling/sdcLite (asset SHA-256 checked before use).
#
#   scripts/ci/verify_render_schema.sh [--golden-dir <dir>]
#
# Each golden is loaded as its own intent (priority 10, json_ietf) into a scratch sdc-lite target
# holding only the schema, then validated; the run fails naming every golden with a validation
# error and prints the errors. No lab and no cluster: the schema repositories are fetched at the
# pinned tag/commit (the patch repository's commit is checked out locally and handed to sdc-lite
# as a file:// tag, because sdc-lite v0.4.0 resolves only tags). Nothing is written into the tree.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
GOLDEN_DIR="$ROOT/tests/golden/fabric"
SCHEMA="$ROOT/deploy/sdc/onboarding/schema.yaml"
LOCK="$ROOT/versions.lock.yaml"
CACHE="${VRS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/agentic-netops/verify-render-schema}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --golden-dir) GOLDEN_DIR="$2"; shift 2 ;;
    *) echo "usage: $0 [--golden-dir <dir>]" >&2; exit 2 ;;
  esac
done

die() { echo "verify-render-schema: FAIL $*" >&2; exit 1; }
command -v yq >/dev/null || die "yq is required"
command -v git >/dev/null || die "git is required"

lk() { yq -r "$1" "$LOCK"; }
tag="$(lk ".platform.sdcLite.release.tag")"
asset="$(lk ".platform.sdcLite.release.asset")"
want="$(lk ".platform.sdcLite.release.assetSha256")"
repo="$(lk ".platform.sdcLite.release.repository")"
[[ -n "$tag" && "$tag" != null && -n "$want" && "$want" != null ]] || die "versions.lock.yaml pins no sdcLite release"

mkdir -p "$CACHE"
bin="$CACHE/sdc-lite-$tag/sdc-lite"
if [[ ! -x "$bin" ]]; then
  tmp="$(mktemp -d)"
  curl -sSLf -o "$tmp/$asset" "$repo/releases/download/$tag/$asset" || die "cannot fetch sdc-lite $tag ($asset)"
  got="$(sha256sum "$tmp/$asset" | cut -d' ' -f1)"
  [[ "$got" == "$want" ]] || die "sdc-lite $asset SHA-256 is $got, the lock file pins $want"
  mkdir -p "$(dirname "$bin")"; tar -xzf "$tmp/$asset" -C "$(dirname "$bin")" sdc-lite; rm -rf "$tmp"
fi

# The schema, with every commit-pinned (kind: hash) repository checked out locally as a tag.
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cp "$SCHEMA" "$work/schema.yaml"
n="$(yq -r '.spec.repositories | length' "$SCHEMA")"
for ((i = 0; i < n; i++)); do
  kind="$(yq -r ".spec.repositories[$i].kind" "$SCHEMA")"
  [[ "$kind" == hash ]] || continue
  url="$(yq -r ".spec.repositories[$i].repoURL" "$SCHEMA")"; ref="$(yq -r ".spec.repositories[$i].ref" "$SCHEMA")"
  d="$CACHE/repo-${ref}"
  if [[ ! -d "$d/.git" ]]; then
    git clone -q "$url" "$d" || die "cannot clone $url"
  fi
  git -C "$d" checkout -q "$ref" || die "$url has no commit $ref"
  git -C "$d" tag -f vt-pin >/dev/null
  REPO="file://$d" I="$i" yq -i '.spec.repositories[env(I)].repoURL = strenv(REPO) | .spec.repositories[env(I)].kind = "tag" | .spec.repositories[env(I)].ref = "vt-pin"' "$work/schema.yaml"
done

export HOME="$work/home"; mkdir -p "$HOME"   # sdc-lite keeps its targets under ~/.cache/sdc-lite
fails=()
shopt -s nullglob
goldens=("$GOLDEN_DIR"/*.json)
[[ ${#goldens[@]} -gt 0 ]] || die "no golden under $GOLDEN_DIR"
for g in "${goldens[@]}"; do
  node="$(basename "$g" .json)"; t="render-$node"
  "$bin" schema load -t "$t" -f "$work/schema.yaml" >"$work/$node.schema.log" 2>&1 \
    || { cat "$work/$node.schema.log" >&2; die "schema load failed for $node"; }
  "$bin" config load -t "$t" --file "$g" --file-format json_ietf --intent-name "fabric-$node" --priority 10 \
    >"$work/$node.load.log" 2>&1 || { cat "$work/$node.load.log" >&2; fails+=("$node: load"); continue; }
  if "$bin" config validate -t "$t" >"$work/$node.validate.log" 2>&1 && ! grep -q '^Errors:' "$work/$node.validate.log"; then
    echo "verify-render-schema: PASS $node"
  else
    sed "s/^/  [$node] /" "$work/$node.validate.log" >&2
    fails+=("$node")
  fi
done
if [[ ${#fails[@]} -gt 0 ]]; then
  die "golden render(s) not valid against the pinned Schema: ${fails[*]}"
fi
echo "verify-render-schema: PASS ${#goldens[@]} golden render(s) valid against srl.nokia.sdcio.dev 25.7.1 (sdc-lite $tag)"
