#!/usr/bin/env bash
# schema_mirror.sh — the in-cluster git mirror of the deviation patch repository (T184; AD-75,
# NFR-003, FR-098, FR-015).
#
# config-server v0.0.58 fetches every non-branch Schema ref as a TAG, and sdcio/srlinux-yang-patch
# has no tags, so the commit versions.lock.yaml pins (compatibilitySet.deviationPatch) cannot be
# loaded from upstream. This script serves exactly that commit from the cluster, under a tag named
# after it, and nothing else:
#
#   1. prepare  clone compatibilitySet.deviationPatch.repository on the host, check out the locked
#               commit and ASSERT the checked-out commit equals the lock — on any difference it
#               stops non-zero naming both commits, with nothing served; then build a bare
#               repository whose ONE ref is refs/tags/<commit> and assert that too;
#   2. publish  write it, with the locked commit, into the ownership-labelled ConfigMap
#               sdc-system/schema-mirror-repo (skipped when the ConfigMap already carries the
#               locked commit and the mirror serves it: an unchanged re-run writes nothing);
#   3. serve    build the first-party image schema-mirror (scripts/lib/image_build.sh: every FROM
#               by locked digest, content-hash tag, kind load) and apply deploy/sdc/schema-mirror;
#               the container asserts the seed's one ref against the locked commit again and
#               refuses to start otherwise (docker/schema-mirror/entrypoint.sh);
#   4. check    `git ls-remote` through the mirror's own HTTP endpoint, inside its pod, through
#               evidence_run: exactly `<commit>\trefs/tags/<commit>`.
#
# The mirror URL and tag are versions.lock.yaml compatibilitySet.schema.repositories[].mirror, and
# deploy/sdc/onboarding/schema.yaml loads the patch from there (make sdc-onboard refuses a branch).
#
# Usage: schema_mirror.sh [ensure|prepare <workdir>]
#   env: KUBECTL, KUBE_CONTEXT, GIT (client; tests), SCHEMA_MIRROR_LOCK (default versions.lock.yaml),
#        SCHEMA_MIRROR_TIMEOUT (s, 180), CLUSTER_NAME, EVIDENCE_DIR
# Exit: 0 served; 1 refused or failed; 2 usage.

# shellcheck source-path=SCRIPTDIR
[[ -n "${__AGENTIC_NETOPS_SCHEMA_MIRROR_SH:-}" ]] && return 0
__AGENTIC_NETOPS_SCHEMA_MIRROR_SH=1

SCHEMA_MIRROR_LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_MIRROR_ROOT="$(cd -- "$SCHEMA_MIRROR_LIB/../.." && pwd)"
# shellcheck source=log.sh
source "$SCHEMA_MIRROR_LIB/log.sh"
# shellcheck source=k8s_wait.sh
source "$SCHEMA_MIRROR_LIB/k8s_wait.sh"
# shellcheck source=ownership.sh
source "$SCHEMA_MIRROR_LIB/ownership.sh"
# shellcheck source=evidence.sh
source "$SCHEMA_MIRROR_LIB/evidence.sh"

SCHEMA_MIRROR_NS="sdc-system"
SCHEMA_MIRROR_NAME="schema-mirror"
SCHEMA_MIRROR_CONFIGMAP="schema-mirror-repo"
SCHEMA_MIRROR_REPO="srlinux-yang-patch"
SCHEMA_MIRROR_FIELD_MANAGER="agentic-netops-provision"

schema_mirror::_git() { "${GIT:-git}" "$@"; }
schema_mirror::_k() { k8s_wait::_kubectl "$@"; }
schema_mirror::_lock() { printf '%s' "${SCHEMA_MIRROR_LOCK:-$SCHEMA_MIRROR_ROOT/versions.lock.yaml}"; }

# schema_mirror::locked — "<repository>\t<commit>\t<mirror repoURL>\t<mirror ref>" from the lock.
schema_mirror::locked() {
  local lock out
  lock="$(schema_mirror::_lock)"
  out="$(yq -r '.compatibilitySet as $c | ($c.schema.repositories[] | select(.repoURL == $c.deviationPatch.repository)) as $r
      | [$c.deviationPatch.repository, $c.deviationPatch.commit, ($r.mirror.repoURL // ""), ($r.mirror.ref // "")] | @tsv' "$lock" 2>/dev/null)" || true
  local repo commit murl mref
  IFS=$'\t' read -r repo commit murl mref <<<"$out"
  if [[ -z "$repo" || ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    log::error "schema_mirror: $lock has no compatibilitySet.deviationPatch repository and full commit"; return 1
  fi
  if [[ -z "$murl" || "$mref" != "$commit" ]]; then
    log::error "schema_mirror: $lock compatibilitySet.schema.repositories[] has no mirror of $repo tagged $commit (AD-75)"; return 1
  fi
  printf '%s\t%s\t%s\t%s\n' "$repo" "$commit" "$murl" "$mref"
}

# schema_mirror::prepare <workdir> — clone, assert the locked commit, build the one-ref bare
# repository; prints the path of the seed tarball.
schema_mirror::prepare() {
  local work="${1:?usage: schema_mirror::prepare <workdir>}" repo commit murl mref head refs
  IFS=$'\t' read -r repo commit murl mref < <(schema_mirror::locked) || return 1
  [[ -n "$commit" ]] || return 1
  rm -rf "$work/src" "$work/out"; mkdir -p "$work/out"
  log::info "schema_mirror: cloning $repo"
  schema_mirror::_git clone --quiet --no-checkout "$repo" "$work/src" \
    || { log::error "schema_mirror: cloning $repo failed — nothing served"; return 1; }
  schema_mirror::_git -C "$work/src" -c advice.detachedHead=false checkout --quiet --detach "$commit" \
    || { log::error "schema_mirror: $repo has no commit $commit (versions.lock.yaml compatibilitySet.deviationPatch.commit) — nothing served"; return 1; }
  head="$(schema_mirror::_git -C "$work/src" rev-parse HEAD)" || head="unreadable"
  if [[ "$head" != "$commit" ]]; then
    log::error "schema_mirror: the checked-out commit of $repo is $head, versions.lock.yaml pins $commit — refusing to serve anything else; nothing served"
    return 1
  fi
  schema_mirror::_git init --quiet --bare "$work/out/${SCHEMA_MIRROR_REPO}.git" || return 1
  schema_mirror::_git -C "$work/src" push --quiet "$work/out/${SCHEMA_MIRROR_REPO}.git" "${commit}:refs/tags/${commit}" \
    || { log::error "schema_mirror: writing refs/tags/$commit into the mirror repository failed — nothing served"; return 1; }
  refs="$(schema_mirror::_git --git-dir="$work/out/${SCHEMA_MIRROR_REPO}.git" for-each-ref --format='%(refname) %(objectname)')"
  if [[ "$refs" != "refs/tags/${commit} ${commit}" ]]; then
    log::error "schema_mirror: the mirror repository carries '$(tr '\n' ';' <<<"$refs")', expected only refs/tags/$commit at $commit — nothing served"
    return 1
  fi
  schema_mirror::_git --git-dir="$work/out/${SCHEMA_MIRROR_REPO}.git" config http.receivepack false || return 1
  tar -C "$work/out" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf "$work/repo.tar" "${SCHEMA_MIRROR_REPO}.git" || return 1
  log::info "schema_mirror: $repo at $commit ready to serve as refs/tags/$commit"
  printf '%s\n' "$work/repo.tar"
}

# schema_mirror::served <commit> — the running mirror serves exactly refs/tags/<commit> (evidence).
schema_mirror::served() {
  local commit="$1" out id="schema-mirror.ls-remote" n=1
  evidence::ensure_dir || return 1
  while [[ -e "$EVIDENCE_DIR/$id.json" ]]; do n=$((n + 1)); id="schema-mirror.ls-remote-${n}"; done
  out="$(evidence_run "$id" -- "${KUBECTL:-kubectl}" ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} exec -n "$SCHEMA_MIRROR_NS" \
      "deploy/$SCHEMA_MIRROR_NAME" -- git ls-remote "http://127.0.0.1:8080/git/${SCHEMA_MIRROR_REPO}.git" 2>/dev/null)" || return 1
  [[ "$out" == "${commit}"$'\t'"refs/tags/${commit}" ]]
}

# schema_mirror::ensure — prepare (when needed), publish, serve, check. Idempotent.
schema_mirror::ensure() {
  local repo commit murl mref have timeout="${SCHEMA_MIRROR_TIMEOUT:-180}" work tar changed=false
  IFS=$'\t' read -r repo commit murl mref < <(schema_mirror::locked) || return 1
  [[ -n "$commit" ]] || return 1
  log::info "schema mirror: $repo @ $commit → $murl (tag $mref)"
  have="$(schema_mirror::_k get configmap "$SCHEMA_MIRROR_CONFIGMAP" -n "$SCHEMA_MIRROR_NS" -o jsonpath='{.data.locked-commit}' 2>/dev/null || true)"
  if [[ "$have" != "$commit" ]]; then
    work="$(mktemp -d "${TMPDIR:-/tmp}/schema_mirror.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" RETURN
    tar="$(schema_mirror::prepare "$work")" || return 1
    schema_mirror::_k create configmap "$SCHEMA_MIRROR_CONFIGMAP" -n "$SCHEMA_MIRROR_NS" \
        --from-file=repo.tar="$tar" --from-literal=locked-commit="$commit" --dry-run=client -o yaml \
      | schema_mirror::_k label --local -f - "$(ownership::key)=$(ownership::value)" -o yaml \
      | schema_mirror::_k apply --server-side --force-conflicts --field-manager="$SCHEMA_MIRROR_FIELD_MANAGER" -f - >/dev/null \
      || { log::error "schema_mirror: writing ConfigMap $SCHEMA_MIRROR_NS/$SCHEMA_MIRROR_CONFIGMAP failed"; return 1; }
    changed=true
  else
    log::info "schema mirror: ConfigMap $SCHEMA_MIRROR_CONFIGMAP already carries $commit — not rewritten"
  fi
  declare -F image_build::build >/dev/null || source "$SCHEMA_MIRROR_LIB/image_build.sh"
  local ref
  ref="$(image_build::build "$SCHEMA_MIRROR_NAME" deploy/sdc/schema-mirror)" || { log::error "schema_mirror: building the schema-mirror image failed"; return 1; }
  [[ "$ref" == "${SCHEMA_MIRROR_NAME}:"* ]] || { log::error "schema_mirror: image_build printed '$ref'"; return 1; }
  schema_mirror::_k apply --server-side --field-manager="$SCHEMA_MIRROR_FIELD_MANAGER" -k "$SCHEMA_MIRROR_ROOT/deploy/sdc/schema-mirror" >/dev/null \
    || { log::error "schema_mirror: applying deploy/sdc/schema-mirror failed"; return 1; }
  if [[ "$changed" == true ]]; then
    schema_mirror::_k rollout restart "deployment/$SCHEMA_MIRROR_NAME" -n "$SCHEMA_MIRROR_NS" >/dev/null || return 1
  fi
  schema_mirror::_k rollout status "deployment/$SCHEMA_MIRROR_NAME" -n "$SCHEMA_MIRROR_NS" --timeout="${timeout}s" >/dev/null \
    || { log::error "schema_mirror: deployment/$SCHEMA_MIRROR_NAME not rolled out within ${timeout}s — see: kubectl -n $SCHEMA_MIRROR_NS logs deploy/$SCHEMA_MIRROR_NAME"; return 1; }
  schema_mirror::served "$commit" \
    || { log::error "schema_mirror: the mirror does not serve exactly refs/tags/$commit"; return 1; }
  log::info "schema mirror: serving refs/tags/$commit (read back through git ls-remote)"
}

schema_mirror::main() {
  case "${1:-ensure}" in
    ensure) schema_mirror::ensure ;;
    prepare) shift; schema_mirror::prepare "${1:?usage: schema_mirror.sh prepare <workdir>}" ;;
    -h|--help) sed -n '2,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) log::error "schema_mirror: unknown command '$1'"; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  schema_mirror::main "$@"
fi
