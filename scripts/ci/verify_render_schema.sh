#!/usr/bin/env bash
# scripts/ci/verify_render_schema.sh — `make verify-render-schema` (T047, T063, T187; FR-015, FR-020,
# R-36, AD-71, AD-81).
#
# Validates every fabric golden render under tests/golden/fabric/ and every service golden render
# under tests/golden/services/ offline against the pinned device Schema
# (deploy/sdc/onboarding/schema.yaml = versions.lock.yaml compatibilitySet part 4) with the
# device-configuration layer's own schema tooling: `sdc-lite config validate`, at the release
# versions.lock.yaml pins under platform.sdcLite (asset SHA-256 checked before use).
#
#   scripts/ci/verify_render_schema.sh [--golden-dir <dir>] [--service-golden-dir <dir>] [--schema <file>]
#                                      [--control-golden <file>] [--service-control-golden <file>]
#     --golden-dir              the fabric goldens, <node>.json (default tests/golden/fabric)
#     --service-golden-dir      the service goldens, <service>-<node>.json (default tests/golden/services)
#     --schema                  the Schema manifest (default deploy/sdc/onboarding/schema.yaml; the
#                               offline unit test hands it one with no commit-pinned repository)
#     --control-golden          the fabric negative control (default the wrong-identity fixture below)
#     --service-control-golden  the service negative control (default the wrong-service-type fixture)
#
# Each fabric golden is loaded as its own intent (priority 10, json_ietf) into a scratch sdc-lite
# target holding only the schema, then validated. A service golden cannot be validated alone — its
# subinterfaces sit on ports whose port-level leaves, irb0 and the tunnel-interface vxlan0 are the
# fabric Config's (AD-68) — so each one is validated LAYERED as the device-configuration layer holds
# it: the fabric golden of the same node (<node> from the file name) as intent fabric-<target> at
# priority 10 and the service golden as intent service-<target> at priority 20, on one target. The
# run fails naming every golden with a validation error and prints the errors. A STANDALONE
# access-list golden (T107/T113: a document carrying only srl_nokia-acl:acl and no interface-ref —
# its binding sits beneath the /acl/interface entry whose interface-ref the Config that owns the
# subinterface writes, AD-68) is validated layered as the layer holds it on the device: the fabric
# golden of its node at priority 10, then EVERY service golden of the same node that renders the
# interface-ref of a subinterface it binds (the owner, found by interface-id) at priority 20, then
# the standalone list at priority 20 — so the binding meets its filter AND the subinterface its
# owner created. A standalone golden binding a subinterface no service golden of its node owns
# FAILS, named. No lab and no
# cluster: the schema repositories are fetched at the pinned tag/commit (a commit-pinned repository
# — `kind: hash`, or the in-cluster mirror of AD-75, which is mapped back to the upstream repository
# and commit versions.lock.yaml records for it — is checked out locally and handed to sdc-lite as a
# file:// tag, because sdc-lite v0.4.0 resolves only tags). Nothing is written into the tree.
#
# Two sdc-lite v0.4.0 defects are recognised by their exact signature, never by a blanket waiver:
#  (1) The identityref form (AD-81, research Open item 21). The goldens freeze the RFC 7951
#      module-prefixed identityrefs G12 observed (`srl_nokia-common:ipv4-unicast`). sdc-lite v0.4.0
#      refuses them inside a `must` that compares the bare name.
#  (2) Feature-guarded must statements (T063). The pinned YANG guards some `must` statements with
#      the vendor extension `srl_nokia-ext:if-feature "not srl_nokia-feat:<feature>"` — the must
#      applies only on a platform WITHOUT the feature (tunnel-interface vxlan-interface type
#      `not(.='srl_nokia-if:bridged')` without evpn-vxlan-mac-vrf, `not(.='srl_nokia-if:routed')`
#      without evpn-vxlan-ifl). sdc-lite v0.4.0 ignores the extension and applies the must anyway,
#      refusing every EVPN vxlan-interface. An error is excused as this defect only when its
#      must-statement is, verbatim, one guarded that way in the YANG sdc-lite itself loaded AND the
#      feature is one gate item G3 requires every device to advertise (tests/gate/g03_features.sh
#      G3_REQUIRED) — so the must does not apply on the pinned platform. Every excused error is
#      printed. The two vxlan-interface musts are now DELETED from the loaded schema by the
#      first-party deviation module (deploy/sdc/schema-deviations, served as Schema repository 3;
#      live-findings 2026-09-21-feature-guarded-must), and a must a loaded `deviate delete` names
#      is never excused: a refusal by it means the deviation was not honoured and FAILS.
# A golden (or a layered pair) is therefore judged:
#   1. AS IS. Clean, or refused only by excused feature-guarded musts (2) → PASS.
#   2. Refused, and EVERY other error is a must-statement comparing one of the golden's (or the
#      pair's) own identityref names in bare form (1) → a COPY is validated whose string VALUES of
#      the form srl_nokia-<module>:<identity> have the `<module>:` prefix removed (keys and every
#      other value untouched; the golden itself is never modified — its SHA-256 is re-checked; a
#      layered pair is normalised on both files). Clean but for excused (2) → PASS, printed as
#      validated on a normalised copy with the defect named.
#   3. Anything else — any error that is neither signature, or the copy still refused → FAIL.
# The negative controls run on every invocation. A fabric golden carrying a WRONG identity
# (tests/unit/verifyrenderschema/fixtures/wrong-identity/leaf01.json, `srl_nokia-common:ipv4-unicats`)
# MUST fail through the same judgement AND its normalised copy, validated directly, MUST fail too. A
# service golden whose vxlan-interface carries a valid identity of the WRONG kind
# (tests/unit/verifyrenderschema/fixtures/wrong-service-type/macvrf-leaf01.json,
# `srl_nokia-interfaces:local-mirror-dest` — the very leaf whose feature-guarded musts are excused)
# MUST fail layered through the same judgement AND on its normalised pair with the excuse applied.
# If either passes, the normalisation, the excuse (or the validator) hides a wrong value and the
# whole run FAILS (NFR-013). Each workaround is removed when a pinned sdc-lite validates the goldens
# unmodified (Open item 21).
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
GOLDEN_DIR="$ROOT/tests/golden/fabric"
SERVICE_DIR="$ROOT/tests/golden/services"
SCHEMA="$ROOT/deploy/sdc/onboarding/schema.yaml"
CONTROL="$ROOT/tests/unit/verifyrenderschema/fixtures/wrong-identity/leaf01.json"
SERVICE_CONTROL="$ROOT/tests/unit/verifyrenderschema/fixtures/wrong-service-type/macvrf-leaf01.json"
G3_SCRIPT="$ROOT/tests/gate/g03_features.sh"
LOCK="$ROOT/versions.lock.yaml"
CACHE="${VRS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/agentic-netops/verify-render-schema}"
# the identityref VALUE form normalised on the copy (never a key: jq's walk leaves keys alone)
IDREF_RE='^srl_nokia-[a-z-]+:[a-z0-9-]+$'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --golden-dir) GOLDEN_DIR="$2"; shift 2 ;;
    --schema) SCHEMA="$2"; shift 2 ;;
    --service-golden-dir) SERVICE_DIR="$2"; shift 2 ;;
    --control-golden) CONTROL="$2"; shift 2 ;;
    --service-control-golden) SERVICE_CONTROL="$2"; shift 2 ;;
    *) echo "usage: $0 [--golden-dir <dir>] [--service-golden-dir <dir>] [--schema <file>] [--control-golden <file>] [--service-control-golden <file>]" >&2; exit 2 ;;
  esac
done

die() { echo "verify-render-schema: FAIL $*" >&2; exit 1; }
command -v yq >/dev/null || die "yq is required"
command -v jq >/dev/null || die "jq is required"
command -v git >/dev/null || die "git is required"
[[ -f "$SCHEMA" ]] || die "no Schema manifest at $SCHEMA"
[[ -f "$CONTROL" ]] || die "no negative-control golden at $CONTROL"
[[ -f "$SERVICE_CONTROL" ]] || die "no service negative-control golden at $SERVICE_CONTROL"
[[ -f "$G3_SCRIPT" ]] || die "no G3 feature list at $G3_SCRIPT"

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
  if [[ "$url" != *://* ]]; then
    # the first-party, in-tree deviation repository (deploy/sdc/schema-deviations): built as the
    # mirror builds it, one deterministic commit, asserted equal to the lock's
    d="$work/tree-repo-$i"
    got="$(bash -c 'source "$1"; schema_mirror::deviations_build "$2" "$3"' _ "$ROOT/scripts/lib/schema_mirror.sh" "$ROOT/$url" "$d.git")" \
      || die "cannot build the in-tree repository $url"
    [[ "$got" == "$ref" ]] || die "$url builds to commit $got, versions.lock.yaml and the Schema pin $ref"
    git clone -q "$d.git" "$d" 2>/dev/null && git -C "$d" -c core.warnAmbiguousRefs=false -c advice.detachedHead=false checkout -q "$ref^{commit}" || die "cannot check out $url at $ref"
    git -C "$d" tag -f vt-pin >/dev/null
    REPO="file://$d" I="$i" yq -i '.spec.repositories[env(I)].repoURL = strenv(REPO) | .spec.repositories[env(I)].kind = "tag" | .spec.repositories[env(I)].ref = "vt-pin"' "$work/schema.yaml"
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

# vrs::validate <file> <target> <log> [<base> [<owner>…]] — 0 clean, 1 refused (errors in <log>), 2 not
# loadable. With <base> (the fabric golden of the node), the pair is loaded layered on one target as
# the layer holds it: <base> as intent fabric-<target> at priority 10, each <owner> (the service
# goldens owning the subinterfaces a standalone access list binds) as owner<i>-<target> at 20, and
# <file> as service-<target> at 20.
vrs::validate() {
  local f="$1" t="$2" log="$3" base="${4:-}" o i=0
  shift 3; [[ $# -gt 0 ]] && shift
  "$bin" schema load -t "$t" -f "$work/schema.yaml" >"$log.schema" 2>&1 \
    || { cat "$log.schema" >&2; die "schema load failed for $t"; }
  if [[ -n "$base" ]]; then
    "$bin" config load -t "$t" --file "$base" --file-format json_ietf --intent-name "fabric-$t" --priority 10 \
      >"$log" 2>&1 || return 2
    # the owners of the subinterfaces a standalone access list binds, each its own intent (AD-68)
    for o in "$@"; do
      "$bin" config load -t "$t" --file "$o" --file-format json_ietf --intent-name "owner$i-$t" --priority 20 \
        >"$log" 2>&1 || return 2
      i=$((i + 1))
    done
    "$bin" config load -t "$t" --file "$f" --file-format json_ietf --intent-name "service-$t" --priority 20 \
      >"$log" 2>&1 || return 2
  else
    "$bin" config load -t "$t" --file "$f" --file-format json_ietf --intent-name "fabric-$t" --priority 10 \
      >"$log" 2>&1 || return 2
  fi
  if "$bin" config validate -t "$t" >"$log" 2>&1 && ! grep -q '^Errors:' "$log"; then
    return 0
  fi
  return 1
}

# vrs::idrefs <file…> — the distinct string values of the identityref form, one per line
vrs::idrefs() {
  jq -r --arg re "$IDREF_RE" '[.. | strings | select(test($re))] | unique[]' "$@" | sort -u
}

# vrs::normalise <in> <out> — the copy: identityref prefixes removed from VALUES only
vrs::normalise() {
  jq --arg re "$IDREF_RE" 'walk(if type == "string" and test($re) then sub("^srl_nokia-[a-z-]+:"; "") else . end)' "$1" >"$2"
}

# vrs::errors <log> — sdc-lite's validation errors, one per line
vrs::errors() {
  sed 's/error path:/\nerror path:/g' "$1" | grep '^error path:' || true
}

# vrs::guarded — "<must expression><TAB><feature>" of every must statement in the schema sdc-lite
# loaded that is guarded by `srl_nokia-ext:if-feature "not srl_nokia-feat:<feature>"` (it applies
# only WITHOUT the feature) for a feature gate item G3 requires every device to advertise. Built
# once, from the YANG files sdc-lite itself fetched; only single-line must statements with a
# single-feature guard qualify (anything else is never excused).
vrs::guarded() {
  local out="$work/guarded.tsv" d="$HOME/.cache/sdc-lite/schemas"
  if [[ ! -f "$out" ]]; then
    sed -n '/^G3_REQUIRED=(/,/)/p' "$G3_SCRIPT" | sed 's/G3_REQUIRED=//' | tr '()' '  ' | tr -s ' \t' '\n' \
      | grep -v '^$' | sort -u >"$work/g3-features"
    [[ -s "$work/g3-features" ]] || die "no G3_REQUIRED feature list in $G3_SCRIPT"
    : >"$work/guarded.all"
    if [[ -d "$d" ]]; then
      # shellcheck disable=SC2016  # awk program, not shell
      find "$d" -name '*.yang' -print0 | xargs -0 -r awk '
        # a must on one line, or spanning lines (joined with single spaces, e.g. the egress
        # acl-filter must of srl_nokia-acl, T107); whitespace is collapsed for the comparison
        /^[ \t]*must[ \t]+["\047].*["\047][ \t]*\{[ \t]*$/ {
          l = $0; sub(/^[ \t]*must[ \t]+/, "", l); sub(/[ \t]*\{[ \t]*$/, "", l)
          q = substr(l, 1, 1)
          if (length(l) > 1 && substr(l, length(l), 1) == q) { expr = substr(l, 2, length(l) - 2); gsub(/[ \t]+/, " ", expr); inm = 1 }
          next
        }
        /^[ \t]*must[ \t]+["\047]/ && !inacc {
          l = $0; sub(/^[ \t]*must[ \t]+/, "", l); q = substr(l, 1, 1); acc = substr(l, 2)
          if (index(acc, q) == 0) { sub(/[ \t]+$/, "", acc); inacc = 1 }
          next
        }
        inacc {
          l = $0; sub(/^[ \t]+/, "", l); sub(/[ \t]+$/, "", l); i = index(l, q)
          if (i == 0) { acc = acc " " l; next }
          inacc = 0
          rest = substr(l, i + 1); sub(/^[ \t]*/, "", rest)
          if (rest == "{") { expr = acc " " substr(l, 1, i - 1); gsub(/[ \t]+/, " ", expr); inm = 1 }
          next
        }
        inm && /^[ \t]*\}[ \t]*$/ { inm = 0; next }
        inm && /^[ \t]*srl_nokia-ext:if-feature[ \t]+"not srl_nokia-feat(ures)?:[a-z0-9-]+";[ \t]*$/ {
          f = $0; sub(/^[^"]*"not srl_nokia-feat(ures)?:/, "", f); sub(/".*$/, "", f); print expr "\t" f
        }' >>"$work/guarded.all"
    fi
    # a must a loaded deviation module DELETES (`deviate delete { must "<expr>" … }`, the first-party
    # deploy/sdc/schema-deviations) is never excused: the deviated schema no longer carries it, so
    # a refusal by it means the deviation was not honoured — that FAILS
    : >"$work/deviated.musts"
    if [[ -d "$d" ]]; then
      # shellcheck disable=SC2016  # awk program, not shell
      { grep -rlZ --include='*.yang' 'deviate delete' "$d" || true; } | xargs -0 -r awk '
        /deviate[ \t]+delete/ { indel = 1 }
        indel && /^[ \t]*must[ \t]+["\047].*["\047]/ {
          l = $0; sub(/^[ \t]*must[ \t]+/, "", l); sub(/[ \t]*[{;][ \t]*$/, "", l)
          q = substr(l, 1, 1); if (length(l) > 1 && substr(l, length(l), 1) == q) print substr(l, 2, length(l) - 2)
        }' | sort -u >"$work/deviated.musts"
    fi
    awk -F'\t' 'NR == FNR { g3[$1] = 1; next } g3[$2]' "$work/g3-features" "$work/guarded.all" \
      | awk -F'\t' -v devf="$work/deviated.musts" 'BEGIN { while ((getline l < devf) > 0) dev[l] = 1 } !dev[$1]' | sort -u >"$out"
  fi
  cat "$out"
}

# vrs::split_excused <errors> <rest-out> <excused-out> — the errors that are a feature-guarded must
# the pinned platform's features switch off go to <excused-out>, annotated; every other to <rest-out>
vrs::split_excused() {
  local errs="$1" rest="$2" exc="$3" e expr f hit
  : >"$rest"; : >"$exc"
  vrs::guarded >"$work/guarded.cur"
  while IFS= read -r e; do
    e="${e%"${e##*[![:space:]]}"}"
    [[ -n "$e" ]] || continue
    hit=""
    while IFS=$'\t' read -r expr f; do
      [[ -n "$expr" && "$(tr -s ' \t' '  ' <<<"$e")" == *"must-statement [$expr]"* ]] && { hit="$f"; break; }
    done <"$work/guarded.cur"
    if [[ -n "$hit" ]]; then
      echo "$e — guarded by srl_nokia-ext:if-feature \"not srl_nokia-feat:$hit\"; G3 requires $hit on every device" >>"$exc"
    else
      echo "$e" >>"$rest"
    fi
  done <"$errs"
}

# vrs::defect_signature <errors> <bare-name…> — 0 when every error in <errors> is a must-statement
# that compares one of the bare names (sdc-lite's refusal of the prefixed form), and there is one
vrs::defect_signature() {
  local errsf="$1"; shift
  local e alt="" b
  for b in "$@"; do alt+="${alt:+|}${b//./\\.}"; done
  [[ -n "$alt" && -s "$errsf" ]] || return 1
  while IFS= read -r e; do
    grep -q 'must-statement' <<<"$e" || return 1
    grep -qE "'(${alt})'" <<<"$e" || return 1
  done <"$errsf"
  return 0
}

# vrs::refused <log> <name> — 0 when <log> holds validation errors of which at least one is NOT an
# excused feature-guarded must (the excused ones are listed in $work/<name>.excused)
vrs::refused() {
  local log="$1" name="$2"
  vrs::errors "$log" >"$work/$name.errs"
  vrs::split_excused "$work/$name.errs" "$work/$name.rest" "$work/$name.excused"
  [[ -s "$work/$name.rest" || ! -s "$work/$name.errs" ]]
}

vrs::print_excused() {
  local name="$1"
  [[ -s "$work/$name.excused" ]] || return 0
  echo "  [$name] excused ($(wc -l <"$work/$name.excused") feature-guarded must(s) sdc-lite $tag applies although the pinned platform's features switch them off):"
  sed "s/^/  [$name]   /" "$work/$name.excused"
}

# vrs::judge <file> <name> [<base> [<owner>…]] — prints the verdict; 0 PASS as is, 10 PASS on the
# normalised copy, 11 PASS as is once feature-guarded musts are excused, 1 FAIL (errors printed on
# stderr). With <base>, the golden is judged layered on it (a service golden on its node's fabric
# golden), and on each <owner> between the two (a standalone access list on its owners).
vrs::judge() {
  local f="$1" name="$2" base="${3:-}" rc=0 sum_before sum_after copy bcopy="" bare=() ids on="" o
  shift 2; [[ $# -gt 0 ]] && shift
  local owners=("$@") ocopies=()
  local files=("$f"); [[ -n "$base" ]] && files+=("$base") && on=" (layered on ${base#"$ROOT"/}"
  for o in "${owners[@]}"; do files+=("$o"); on+=" + ${o#"$ROOT"/}"; done
  [[ -n "$on" ]] && on+=")"
  sum_before="$(sha256sum "${files[@]}" | cut -d' ' -f1 | paste -sd' ')"
  vrs::validate "$f" "render-$name" "$work/$name.log" "$base" "${owners[@]}" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    echo "verify-render-schema: PASS $name$on"
    return 0
  fi
  if [[ "$rc" -eq 2 ]]; then
    sed "s/^/  [$name] load: /" "$work/$name.log" >&2
    return 1
  fi
  if ! vrs::refused "$work/$name.log" "$name"; then
    echo "verify-render-schema: PASS $name$on — refused only by feature-guarded must(s) sdc-lite $tag applies unconditionally (upstream defect, T063)"
    vrs::print_excused "$name"
    return 11
  fi
  ids="$(vrs::idrefs "${files[@]}")"
  if [[ -n "$ids" ]]; then mapfile -t bare < <(cut -d: -f2- <<<"$ids" | sort -u); fi
  if [[ ${#bare[@]} -eq 0 ]] || ! vrs::defect_signature "$work/$name.rest" "${bare[@]}"; then
    sed "s/^/  [$name] /" "$work/$name.log" >&2
    return 1
  fi
  copy="$work/norm/$name.json"
  vrs::normalise "$f" "$copy"
  if [[ -n "$base" ]]; then bcopy="$work/norm/$name.base.json"; vrs::normalise "$base" "$bcopy"; fi
  for o in "${owners[@]}"; do ocopies+=("$work/norm/$name.owner${#ocopies[@]}.json"); vrs::normalise "$o" "${ocopies[-1]}"; done
  rc=0; vrs::validate "$copy" "render-$name-normalised" "$work/$name.normalised.log" "$bcopy" "${ocopies[@]}" || rc=$?
  sum_after="$(sha256sum "${files[@]}" | cut -d' ' -f1 | paste -sd' ')"
  [[ "$sum_before" == "$sum_after" ]] || die "$f changed while it was validated (a golden is never modified)"
  if [[ "$rc" -eq 0 ]] || { [[ "$rc" -eq 1 ]] && ! vrs::refused "$work/$name.normalised.log" "$name.normalised"; }; then
    echo "verify-render-schema: PASS $name$on — on an identityref-normalised COPY: sdc-lite $tag refuses the RFC 7951 prefixed form inside a must (upstream defect, AD-81, research Open item 21); the golden is unmodified; normalised: $(paste -sd' ' <<<"$ids")"
    [[ "$rc" -eq 0 ]] || vrs::print_excused "$name.normalised"
    return 10
  fi
  echo "  [$name] refused as is (sdc-lite's prefixed-identityref defect) and STILL refused on the normalised copy:" >&2
  sed "s/^/  [$name] normalised: /" "$work/$name.normalised.log" >&2
  return 1
}

# vrs::standalone_acl <golden> — 0 when the golden is a standalone access list: it carries
# srl_nokia-acl:acl alone and no interface-ref (it owns no subinterface, AD-68)
vrs::standalone_acl() {
  jq -e 'keys == ["srl_nokia-acl:acl"] and ([.. | objects | select(has("interface-ref"))] | length == 0)' "$1" >/dev/null 2>&1
}

# vrs::owners <golden> <node> <array-name> — fills <array-name> with the service goldens of <node>
# (other than <golden>) that render the interface-ref of a subinterface <golden> binds; fails,
# naming the interface-id, when a bound subinterface has no owner among them
vrs::owners() {
  local g="$1" node="$2" id o found missing=""
  local -n _out="$3"
  _out=()
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    found=""
    for o in "$SERVICE_DIR"/*-"$node".json; do
      [[ "$o" == "$g" ]] && continue
      if jq -e --arg id "$id" '[."srl_nokia-acl:acl".interface[]? | select(."interface-id" == $id and has("interface-ref"))] | length > 0' "$o" >/dev/null 2>&1; then
        found="$o"; break
      fi
    done
    if [[ -z "$found" ]]; then missing+=" $id"; continue; fi
    [[ " ${_out[*]} " == *" $found "* ]] || _out+=("$found")
  done < <(jq -r '."srl_nokia-acl:acl".interface[]?."interface-id"' "$g")
  if [[ -n "$missing" ]]; then
    echo "  [$(basename "$g" .json)] a standalone access list binds${missing}, which no service golden of $node owns (renders the interface-ref of) — nothing to layer it on" >&2
    return 1
  fi
}

fails=(); normalised=0; excused=0
tally() {
  [[ "$1" =~ ^(0|10|11)$ && ( -s "$work/$2.excused" || -s "$work/$2.normalised.excused" ) ]] && excused=$((excused + 1))
  case "$1" in
    0) ;;
    10) normalised=$((normalised + 1)) ;;
    11) ;;
    *) fails+=("$2") ;;
  esac
}
shopt -s nullglob
goldens=("$GOLDEN_DIR"/*.json)
[[ ${#goldens[@]} -gt 0 ]] || die "no golden under $GOLDEN_DIR"
for g in "${goldens[@]}"; do
  node="$(basename "$g" .json)"
  rc=0; vrs::judge "$g" "$node" || rc=$?
  tally "$rc" "$node"
done

# every service golden, layered on the fabric golden of its node (<service>-<node>.json)
services=("$SERVICE_DIR"/*.json)
[[ ${#services[@]} -gt 0 ]] || die "no service golden under $SERVICE_DIR"
for g in "${services[@]}"; do
  name="$(basename "$g" .json)"; node="${name##*-}"
  if [[ "$name" == "$node" || ! -f "$GOLDEN_DIR/$node.json" ]]; then
    echo "  [$name] no fabric golden $GOLDEN_DIR/$node.json to layer it on (a service golden is named <service>-<node>.json)" >&2
    fails+=("$name"); continue
  fi
  owners=()
  if vrs::standalone_acl "$g"; then
    if ! vrs::owners "$g" "$node" owners; then fails+=("$name"); continue; fi
  fi
  rc=0; vrs::judge "$g" "$name" "$GOLDEN_DIR/$node.json" "${owners[@]}" || rc=$?
  tally "$rc" "$name"
done

# the negative control: a wrong identity must still fail through the same judgement
crc=0; vrs::judge "$CONTROL" "negative-control" >"$work/control.out" || crc=$?
if [[ "$crc" -eq 0 || "$crc" -eq 10 || "$crc" -eq 11 ]]; then
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

# the service negative control: a vxlan-interface type of the wrong kind, layered on its node's
# fabric golden, must fail through the same judgement — and on its normalised pair with the
# feature-guarded excuse applied: neither the normalisation nor the excuse may hide it
sname="$(basename "$SERVICE_CONTROL" .json)"; snode="${sname##*-}"; sbase="$GOLDEN_DIR/$snode.json"
[[ "$sname" != "$snode" && -f "$sbase" ]] || die "service negative control ${SERVICE_CONTROL#"$ROOT"/}: no fabric golden $sbase to layer it on"
crc=0; vrs::judge "$SERVICE_CONTROL" "service-negative-control" "$sbase" >"$work/service-control.out" 2>&1 || crc=$?
if [[ "$crc" -eq 0 || "$crc" -eq 10 || "$crc" -eq 11 ]]; then
  cat "$work/service-control.out" >&2
  die "service negative control PASSED: ${SERVICE_CONTROL#"$ROOT"/} carries a wrong vxlan-interface type and was accepted$([[ "$crc" -eq 10 ]] && echo ' on the normalised copy')$([[ "$crc" -eq 11 ]] && echo ' once feature-guarded musts were excused') — the normalisation, the excuse or the validator hides a wrong value (NFR-013)"
fi
vrs::normalise "$SERVICE_CONTROL" "$work/norm/service-negative-control.json"
vrs::normalise "$sbase" "$work/norm/service-negative-control.base.json"
nrc=0; vrs::validate "$work/norm/service-negative-control.json" "render-service-negative-control-normalised" \
  "$work/service-negative-control.normalised.log" "$work/norm/service-negative-control.base.json" || nrc=$?
if [[ "$nrc" -eq 0 ]] || { [[ "$nrc" -eq 1 ]] && ! vrs::refused "$work/service-negative-control.normalised.log" "service-negative-control.direct"; }; then
  die "service negative control PASSED on its identityref-normalised pair$([[ "$nrc" -eq 1 ]] && echo ' once feature-guarded musts were excused'): ${SERVICE_CONTROL#"$ROOT"/} carries a wrong vxlan-interface type — the normalisation or the excuse hides it (NFR-013)"
fi
echo "verify-render-schema: service negative control — ${SERVICE_CONTROL#"$ROOT"/} layered on ${sbase#"$ROOT"/} refused as is AND on its normalised pair with feature-guarded musts excused, as it must be"

if [[ ${#fails[@]} -gt 0 ]]; then
  die "golden render(s) not valid against the pinned Schema: ${fails[*]}"
fi
echo "verify-render-schema: PASS $((${#goldens[@]} + ${#services[@]})) golden render(s) valid against srl.nokia.sdcio.dev 25.7.1 (sdc-lite $tag): ${#goldens[@]} fabric, ${#services[@]} service layered on its node's fabric golden$([[ "$normalised" -gt 0 ]] && echo "; ${normalised} validated on an identityref-normalised copy (AD-81)")$([[ "$excused" -gt 0 ]] && echo "; ${excused} with feature-guarded musts excused (T063)")"
