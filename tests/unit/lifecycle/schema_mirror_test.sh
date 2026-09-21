#!/usr/bin/env bash
# Schema mirror test (T184; AD-75, NFR-003, FR-098).
#
# scripts/lib/schema_mirror.sh against a fixture lock whose deviation patch is a local repository
# (so the test is offline) and a fake `git` that wraps the real one:
#   1. a clone whose checked-out commit differs from the lock (fake git reports another HEAD)
#      → non-zero NAMING BOTH COMMITS, and nothing served: no seed tarball, no ConfigMap write,
#      no apply, no image build (the fake kubectl's call log holds no create/apply/rollout)
#   2. the negative control: the real checkout → the seed holds ONE ref, refs/tags/<commit> at
#      <commit>, served over git's own local transport from the unpacked seed, receive-pack off
#   3. a lock with no mirror tagged after the commit is refused naming AD-75
#   4. the committed lock names a mirror tagged after compatibilitySet.deviationPatch.commit,
#      the committed Schema loads that URL by tag, the Deployment is read-only and bounded, and
#      the image's entrypoint refuses a seed whose ref is not the locked commit
# shellcheck disable=SC2015  # `cond && pass … || fail …` is safe: pass always returns 0
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
SM="$ROOT/scripts/lib/schema_mirror.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; FAILS=$((FAILS + 1)); }

REAL_GIT="$(command -v git)"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.invalid; git config --global user.name t
git config --global init.defaultBranch main

# upstream: a local repository with two commits; the lock pins the FIRST (not the branch head)
UP="$TMP/upstream"
git init -q "$UP"
echo a >"$UP/f"; git -C "$UP" add f; git -C "$UP" commit -q -m one
PINNED="$(git -C "$UP" rev-parse HEAD)"
echo b >"$UP/f"; git -C "$UP" commit -q -am two
OTHER="$(git -C "$UP" rev-parse HEAD)"

lock() {  # <file> <mirror ref>
  cat >"$1" <<EOF
compatibilitySet:
  deviationPatch:
    part: 3
    repository: file://$UP
    commit: $PINNED
  schema:
    part: 4
    repositories:
      - repoURL: file://$UP
        kind: hash
        ref: $PINNED
        mirror:
          repoURL: http://schema-mirror.sdc-system.svc.cluster.local/git/srlinux-yang-patch.git
          kind: tag
          ref: $2
EOF
}
lock "$TMP/lock.yaml" "$PINNED"

# fake git: the real git, except `rev-parse HEAD` may be made to report FAKE_GIT_HEAD
cat >"$TMP/git" <<EOF
#!/usr/bin/env bash
echo "git \$*" >>"$TMP/git.log"
if [[ -n "\${FAKE_GIT_HEAD:-}" && "\${*: -2}" == "rev-parse HEAD" ]]; then echo "\$FAKE_GIT_HEAD"; exit 0; fi
exec "$REAL_GIT" "\$@"
EOF
# fake kubectl: records every call, answers nothing
cat >"$TMP/kubectl" <<EOF
#!/usr/bin/env bash
echo "kubectl \$*" >>"$TMP/kubectl.log"
exit 1
EOF
chmod +x "$TMP/git" "$TMP/kubectl"
export GIT="$TMP/git" KUBECTL="$TMP/kubectl" SCHEMA_MIRROR_LOCK="$TMP/lock.yaml" EVIDENCE_DIR="$TMP/evidence"

# 1 — the checked-out commit differs from the lock → stop naming both, nothing served
: >"$TMP/kubectl.log"
out="$(FAKE_GIT_HEAD="$OTHER" bash "$SM" ensure 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF "$OTHER" <<<"$out" && grep -qF "$PINNED" <<<"$out" && grep -qF "nothing served" <<<"$out" \
   && ! grep -qE "kubectl .*(create|apply|rollout|exec)" "$TMP/kubectl.log" && ! ls "$TMP"/schema_mirror.* >/dev/null 2>&1; then
  pass "head differing from the lock: non-zero naming both commits ($PINNED, $OTHER); no ConfigMap, apply, rollout or image"
else fail "differing head (rc=$rc)" "$out
$(cat "$TMP/kubectl.log")"; fi

# 2 — negative control: the real checkout → one ref, refs/tags/<commit>, served read-only
W="$TMP/work"; mkdir -p "$W"
tarp="$(bash "$SM" prepare "$W" 2>"$TMP/prep.err")"; rc=$?
if [[ "$rc" -eq 0 && -f "$tarp" ]]; then
  mkdir -p "$TMP/srv"; tar -C "$TMP/srv" -xf "$tarp"
  refs="$(git --git-dir="$TMP/srv/srlinux-yang-patch.git" for-each-ref --format='%(refname) %(objectname)')"
  ls_remote="$(git ls-remote "file://$TMP/srv/srlinux-yang-patch.git")"
  rp="$(git --git-dir="$TMP/srv/srlinux-yang-patch.git" config http.receivepack)"
  if [[ "$refs" == "refs/tags/$PINNED $PINNED" && "$ls_remote" == "$PINNED"$'\t'"refs/tags/$PINNED" && "$rp" == false ]] \
     && ! git --git-dir="$TMP/srv/srlinux-yang-patch.git" cat-file -e "$OTHER" 2>/dev/null; then
    pass "locked checkout: the seed carries only refs/tags/$PINNED at $PINNED (not the branch head), receive-pack off"
  else fail "seed content" "refs=$refs ls-remote=$ls_remote receivepack=$rp"; fi
else fail "prepare with the real checkout (rc=$rc)" "$(cat "$TMP/prep.err")"; fi
tar1="$(sha256sum <"$tarp" | cut -d' ' -f1)"
tarp2="$(bash "$SM" prepare "$TMP/work2" 2>/dev/null)"
[[ "$(sha256sum <"$tarp2" | cut -d' ' -f1)" == "$tar1" ]] && pass "the seed is reproducible: two prepares, one SHA-256" \
  || fail "seed not reproducible"

# 3 — a lock with no mirror named after the commit is refused (AD-75)
lock "$TMP/lock-bad.yaml" "$OTHER"
out="$(SCHEMA_MIRROR_LOCK="$TMP/lock-bad.yaml" bash "$SM" prepare "$TMP/work3" 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && grep -qF "AD-75" <<<"$out" && [[ ! -e "$TMP/work3/repo.tar" ]] \
  && pass "a lock whose mirror tag is not the pinned commit is refused naming AD-75" || fail "bad mirror tag (rc=$rc)" "$out"

# 4 — the committed artefacts agree with each other
L="$ROOT/versions.lock.yaml"
commit="$(yq -r '.compatibilitySet.deviationPatch.commit' "$L")"
murl="$(yq -r '.compatibilitySet.schema.repositories[] | select(.repoURL == "https://github.com/sdcio/srlinux-yang-patch") | .mirror.repoURL' "$L")"
mref="$(yq -r '.compatibilitySet.schema.repositories[] | select(.repoURL == "https://github.com/sdcio/srlinux-yang-patch") | .mirror.ref' "$L")"
skind="$(yq -r ".spec.repositories[] | select(.repoURL == \"$murl\") | .kind" "$ROOT/deploy/sdc/onboarding/schema.yaml")"
sref="$(yq -r ".spec.repositories[] | select(.repoURL == \"$murl\") | .ref" "$ROOT/deploy/sdc/onboarding/schema.yaml")"
[[ "$mref" == "$commit" && "$skind" == tag && "$sref" == "$commit" ]] \
  && pass "lock mirror tag == part 3 commit, and deploy/sdc/onboarding/schema.yaml loads $murl by that tag" \
  || fail "committed mirror/schema disagree" "commit=$commit mirror=$murl@$mref schema=$skind:$sref"
D="$ROOT/deploy/sdc/schema-mirror/deployment.yaml"
[[ "$(yq -r '.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem' "$D")" == true \
   && "$(yq -r '.spec.template.spec.containers[0].resources.limits.memory' "$D")" != null \
   && "$(yq -r '.spec.template.spec.containers[0].resources.requests.cpu' "$D")" != null \
   && "$(yq -r '.spec.template.spec.containers[0].imagePullPolicy' "$D")" == Never ]] \
  && pass "mirror Deployment: read-only root, explicit requests and limits, never pulled" || fail "mirror Deployment shape"
grep -qF 'git-receive-pack' "$ROOT/docker/schema-mirror/lighttpd.conf" && grep -qF 'url.access-deny' "$ROOT/docker/schema-mirror/lighttpd.conf" \
  && pass "the mirror's HTTP server refuses receive-pack" || fail "lighttpd.conf does not refuse receive-pack"
# the entrypoint refuses a seed whose only ref is not the locked commit (run with a stub lighttpd)
mkdir -p "$TMP/ep/bin"; printf '#!/bin/sh\necho SERVING\n' >"$TMP/ep/bin/lighttpd"; chmod +x "$TMP/ep/bin/lighttpd"
ep() { (cd "$TMP/ep" && sed 's#/srv/git#'"$TMP"'/ep/srv#g' "$ROOT/docker/schema-mirror/entrypoint.sh" >ep.sh \
  && PATH="$TMP/ep/bin:$PATH" SEED="$tarp" LOCKED_COMMIT="$1" sh ep.sh 2>&1); }
out="$(ep "$OTHER")"; rc=$?
[[ "$rc" -ne 0 ]] && grep -qF "refusing to serve" <<<"$out" && grep -qF "$OTHER" <<<"$out" && ! grep -q SERVING <<<"$out" \
  && pass "entrypoint: a seed whose ref is not LOCKED_COMMIT is refused, nothing served" || fail "entrypoint wrong commit (rc=$rc)" "$out"
rm -rf "$TMP/ep/srv"; out="$(ep "$PINNED")"; rc=$?
[[ "$rc" -eq 0 ]] && grep -q SERVING <<<"$out" && pass "entrypoint: the locked seed is served (negative control)" || fail "entrypoint locked (rc=$rc)" "$out"

if [[ "$FAILS" -gt 0 ]]; then echo "schema_mirror_test: $FAILS FAILED"; exit 1; fi
echo "schema_mirror_test: PASS"
