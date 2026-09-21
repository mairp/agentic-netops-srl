#!/usr/bin/env bash
# scripts/ci/verify_render_schema.sh — `make verify-render-schema` (T047, T187; FR-015, FR-020, R-36,
# AD-71, AD-81).
#
# Validates every fabric golden render under tests/golden/fabric/ offline against the pinned
# device Schema (deploy/sdc/onboarding/schema.yaml = versions.lock.yaml compatibilitySet part 4)
# with the device-configuration layer's own schema tooling: `sdc-lite config validate`, at the
# release versions.lock.yaml pins under platform.sdcLite (asset SHA-256 checked before use).
#
#   scripts/ci/verify_render_schema.sh [--golden-dir <dir>] [--schema <file>] [--control-golden <file>]
#     --schema          the Schema manifest (default deploy/sdc/onboarding/schema.yaml; the offline
#                       unit test hands it one with no commit-pinned repository)
#     --control-golden  the negative control (default the wrong-identity fixture below)
#
# Each golden is loaded as its own intent (priority 10, json_ietf) into a scratch sdc-lite target
# holding only the schema, then validated; the run fails naming every golden with a validation
# error and prints the errors. No lab and no cluster: the schema repositories are fetched at the
# pinned tag/commit (a commit-pinned repository — `kind: hash`, or the in-cluster mirror of
# AD-75, which is mapped back to the upstream repository and commit versions.lock.yaml records
# for it — is checked out locally and handed to sdc-lite as a file:// tag, because sdc-lite
# v0.4.0 resolves only tags). Nothing is written into the tree.
#
# The identityref form (AD-81, research Open item 21). The goldens freeze the RFC 7951
# module-prefixed identityrefs G12 observed (`srl_nokia-common:ipv4-unicast`). sdc-lite v0.4.0
# refuses them inside a `must` that compares the bare name. A golden is therefore judged:
#   1. AS IS. Clean → PASS.
#   2. Refused, and EVERY error is a must-statement comparing one of the golden's own identityref
#      names in bare form (the upstream defect's signature) → a COPY is validated whose string
#      VALUES of the form srl_nokia-<module>:<identity> have the `<module>:` prefix removed (keys
#      and every other value untouched; the golden itself is never modified — its SHA-256 is
#      re-checked). Clean → PASS, printed as validated on a normalised copy with the defect named.
#   3. Anything else — any error that is not that signature, or the copy still refused → FAIL.
# The negative control runs on every invocation: a golden carrying a WRONG identity
# (tests/unit/verifyrenderschema/fixtures/wrong-identity/leaf01.json, `srl_nokia-common:ipv4-unicats`)
# MUST fail through the same judgement AND its normalised copy, validated directly, MUST fail too. If
# either passes, the normalisation (or the validator) hides a wrong identity and the whole run FAILS
# (NFR-013). The normalisation is removed
# when a pinned sdc-lite validates the goldens unmodified (Open item 21).
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
GOLDEN_DIR="$ROOT/tests/golden/fabric"
SCHEMA="$ROOT/deploy/sdc/onboarding/schema.yaml"
CONTROL="$ROOT/tests/unit/verifyrenderschema/fixtures/wrong-identity/leaf01.json"
LOCK="$ROOT/versions.lock.yaml"
CACHE="${VRS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/agentic-netops/verify-render-schema}"
# the identityref VALUE form normalised on the copy (never a key: jq's walk leaves keys alone)
IDREF_RE='^srl_nokia-[a-z-]+:[a-z0-9-]+$'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --golden-dir) GOLDEN_DIR="$2"; shift 2 ;;
    --schema) SCHEMA="$2"; shift 2 ;;
    --control-golden) CONTROL="$2"; shift 2 ;;
    *) echo "usage: $0 [--golden-dir <dir>] [--schema <file>] [--control-golden <file>]" >&2; exit 2 ;;
  esac
done

die() { echo "verify-render-schema: FAIL $*" >&2; exit 1; }
command -v yq >/dev/null || die "yq is required"
command -v jq >/dev/null || die "jq is required"
command -v git >/dev/null || die "git is required"
[[ -f "$SCHEMA" ]] || die "no Schema manifest at $SCHEMA"
[[ -f "$CONTROL" ]] || die "no negative-control golden at $CONTROL"

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

# The schema, with every commit-pinned repository checked out locally as a tag. A repository the
# Schema loads from the in-cluster mirror (AD-75) is fetched from the upstream repository the lock
# records beside that mirror, at the commit the lock records — asserted equal to the Schema's ref.
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cp "$SCHEMA" "$work/schema.yaml"
n="$(yq -r '.spec.repositories | length' "$SCHEMA")"
for ((i = 0; i < n; i++)); do
  kind="$(yq -r ".spec.repositories[$i].kind" "$SCHEMA")"
  url="$(yq -r ".spec.repositories[$i].repoURL" "$SCHEMA")"; ref="$(yq -r ".spec.repositories[$i].ref" "$SCHEMA")"
  upstream="$(U="$url" yq -r '.. | select(type == "!!map" and has("mirror")) | select(.mirror.repoURL == strenv(U)) | .repoURL + " " + .ref' "$LOCK" | head -1)"
  if [[ -n "$upstream" ]]; then
    read -r url lref <<<"$upstream"
    [[ "$lref" == "$ref" ]] || die "Schema repository $i ($ref) is served from the mirror but versions.lock.yaml records commit $lref for it"
  elif [[ "$kind" != hash ]]; then
    continue
  fi
  d="$CACHE/repo-${ref}"
  if [[ ! -d "$d/.git" ]]; then
    git clone -q "$url" "$d" || die "cannot clone $url"
  fi
  git -C "$d" checkout -q "$ref" || die "$url has no commit $ref"
  git -C "$d" tag -f vt-pin >/dev/null
  REPO="file://$d" I="$i" yq -i '.spec.repositories[env(I)].repoURL = strenv(REPO) | .spec.repositories[env(I)].kind = "tag" | .spec.repositories[env(I)].ref = "vt-pin"' "$work/schema.yaml"
done

export HOME="$work/home"; mkdir -p "$HOME"   # sdc-lite keeps its targets under ~/.cache/sdc-lite
mkdir -p "$work/norm"

# vrs::validate <file> <target> <log> — 0 clean, 1 refused (errors in <log>), 2 not loadable
vrs::validate() {
  local f="$1" t="$2" log="$3"
  "$bin" schema load -t "$t" -f "$work/schema.yaml" >"$log.schema" 2>&1 \
    || { cat "$log.schema" >&2; die "schema load failed for $t"; }
  "$bin" config load -t "$t" --file "$f" --file-format json_ietf --intent-name "fabric-$t" --priority 10 \
    >"$log" 2>&1 || return 2
  if "$bin" config validate -t "$t" >"$log" 2>&1 && ! grep -q '^Errors:' "$log"; then
    return 0
  fi
  return 1
}

# vrs::idrefs <file> — the distinct string values of the identityref form, one per line
vrs::idrefs() {
  jq -r --arg re "$IDREF_RE" '[.. | strings | select(test($re))] | unique[]' "$1"
}

# vrs::normalise <in> <out> — the copy: identityref prefixes removed from VALUES only
vrs::normalise() {
  jq --arg re "$IDREF_RE" 'walk(if type == "string" and test($re) then sub("^srl_nokia-[a-z-]+:"; "") else . end)' "$1" >"$2"
}

# vrs::defect_signature <log> <bare-name…> — 0 when every error in <log> is a must-statement that
# compares one of the bare names (sdc-lite's refusal of the prefixed form), and there is one
vrs::defect_signature() {
  local log="$1"; shift
  local errs e alt="" b
  for b in "$@"; do alt+="${alt:+|}${b//./\\.}"; done
  [[ -n "$alt" ]] || return 1
  errs="$(sed 's/error path:/\nerror path:/g' "$log" | grep '^error path:' || true)"
  [[ -n "$errs" ]] || return 1
  while IFS= read -r e; do
    grep -q 'must-statement' <<<"$e" || return 1
    grep -qE "'(${alt})'" <<<"$e" || return 1
  done <<<"$errs"
  return 0
}

# vrs::judge <file> <name> — prints the verdict; 0 PASS as is, 10 PASS on the normalised copy,
# 1 FAIL (errors printed on stderr)
vrs::judge() {
  local f="$1" name="$2" rc=0 sum_before sum_after copy bare=() ids
  sum_before="$(sha256sum "$f" | cut -d' ' -f1)"
  vrs::validate "$f" "render-$name" "$work/$name.log" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    echo "verify-render-schema: PASS $name"
    return 0
  fi
  if [[ "$rc" -eq 2 ]]; then
    sed "s/^/  [$name] load: /" "$work/$name.log" >&2
    return 1
  fi
  ids="$(vrs::idrefs "$f")"
  if [[ -n "$ids" ]]; then mapfile -t bare < <(cut -d: -f2- <<<"$ids" | sort -u); fi
  if [[ ${#bare[@]} -eq 0 ]] || ! vrs::defect_signature "$work/$name.log" "${bare[@]}"; then
    sed "s/^/  [$name] /" "$work/$name.log" >&2
    return 1
  fi
  copy="$work/norm/$name.json"
  vrs::normalise "$f" "$copy"
  rc=0; vrs::validate "$copy" "render-$name-normalised" "$work/$name.normalised.log" || rc=$?
  sum_after="$(sha256sum "$f" | cut -d' ' -f1)"
  [[ "$sum_before" == "$sum_after" ]] || die "$f changed while it was validated (the golden is never modified)"
  if [[ "$rc" -eq 0 ]]; then
    echo "verify-render-schema: PASS $name — on an identityref-normalised COPY: sdc-lite $tag refuses the RFC 7951 prefixed form inside a must (upstream defect, AD-81, research Open item 21); the golden is unmodified; normalised: $(paste -sd' ' <<<"$ids")"
    return 10
  fi
  echo "  [$name] refused as is (sdc-lite's prefixed-identityref defect) and STILL refused on the normalised copy:" >&2
  sed "s/^/  [$name] normalised: /" "$work/$name.normalised.log" >&2
  return 1
}

fails=(); normalised=0
shopt -s nullglob
goldens=("$GOLDEN_DIR"/*.json)
[[ ${#goldens[@]} -gt 0 ]] || die "no golden under $GOLDEN_DIR"
for g in "${goldens[@]}"; do
  node="$(basename "$g" .json)"
  rc=0; vrs::judge "$g" "$node" || rc=$?
  case "$rc" in
    0) ;;
    10) normalised=$((normalised + 1)) ;;
    *) fails+=("$node") ;;
  esac
done

# the negative control: a wrong identity must still fail through the same judgement
crc=0; vrs::judge "$CONTROL" "negative-control" >"$work/control.out" || crc=$?
if [[ "$crc" -eq 0 || "$crc" -eq 10 ]]; then
  cat "$work/control.out" >&2
  die "negative control PASSED: ${CONTROL#"$ROOT"/} carries a wrong identity and was accepted$([[ "$crc" -eq 10 ]] && echo ' on the normalised copy') — the normalisation or the validator hides a wrong identity (NFR-013)"
fi
# … and its normalised copy, validated directly whatever the judgement above did with it: the
# normalisation itself must never turn a wrong identity into a valid one
vrs::normalise "$CONTROL" "$work/norm/negative-control.json"
nrc=0; vrs::validate "$work/norm/negative-control.json" "render-negative-control-normalised" "$work/negative-control.normalised.log" || nrc=$?
if [[ "$nrc" -eq 0 ]]; then
  die "negative control PASSED on its identityref-normalised copy: ${CONTROL#"$ROOT"/} carries a wrong identity — the normalisation hides it (NFR-013)"
fi
echo "verify-render-schema: negative control — ${CONTROL#"$ROOT"/} (identityrefs: $(vrs::idrefs "$CONTROL" | paste -sd' ' -)) refused as is AND on its normalised copy, as it must be"

if [[ ${#fails[@]} -gt 0 ]]; then
  die "golden render(s) not valid against the pinned Schema: ${fails[*]}"
fi
echo "verify-render-schema: PASS ${#goldens[@]} golden render(s) valid against srl.nokia.sdcio.dev 25.7.1 (sdc-lite $tag)$([[ "$normalised" -gt 0 ]] && echo "; ${normalised} validated on an identityref-normalised copy (AD-81)")"
