#!/bin/sh
# schema-mirror entrypoint (T184; AD-75): unpack the bare repositories the ConfigMap carries,
# refuse to serve unless the seed holds EXACTLY the two expected repositories and each one's ONLY
# ref is refs/tags/<its locked commit> pointing at that commit, then serve them read-only over git
# smart HTTP.
#   SEED               the tarball of <REPO>.git and <DEVIATIONS_REPO>.git (default /seed/repo.tar)
#   LOCKED_COMMIT      the commit versions.lock.yaml pins (compatibilitySet.deviationPatch.commit)
#   REPO               the served patch repository name (default srlinux-yang-patch)
#   DEVIATIONS_COMMIT  the deterministic commit of deploy/sdc/schema-deviations the lock pins
#                      (compatibilitySet.schema.repositories[] with the in-tree repoURL)
#   DEVIATIONS_REPO    the served first-party deviation repository (default agentic-netops-deviations)
set -eu
SEED="${SEED:-/seed/repo.tar}"
REPO="${REPO:-srlinux-yang-patch}"
DEVIATIONS_REPO="${DEVIATIONS_REPO:-agentic-netops-deviations}"
fail() { echo "schema-mirror: $*" >&2; exit 1; }
full() {  # <name> <value>
  case "$2" in
    *[!0-9a-f]*|'') fail "$1 '$2' is not a full commit hash — refusing to serve" ;;
  esac
  [ "${#2}" -eq 40 ] || fail "$1 '$2' is not a full commit hash — refusing to serve"
}
full LOCKED_COMMIT "${LOCKED_COMMIT:-}"
full DEVIATIONS_COMMIT "${DEVIATIONS_COMMIT:-}"
[ -f "$SEED" ] || fail "no seed repository at $SEED — refusing to serve"
mkdir -p /srv/git
tar -C /srv/git -xf "$SEED"
have="$(ls -A /srv/git | sort | tr '\n' ' ')"
want="$(printf '%s\n' "${REPO}.git" "${DEVIATIONS_REPO}.git" | sort | tr '\n' ' ')"
[ "$have" = "$want" ] || fail "seed holds '${have% }', expected exactly '${want% }' — refusing to serve"
assert() {  # <repo> <commit>
  dir="/srv/git/$1.git"
  [ -d "$dir" ] || fail "seed does not hold $1.git — refusing to serve"
  refs="$(git --git-dir="$dir" for-each-ref --format='%(refname) %(objectname)')"
  w="refs/tags/$2 $2"
  [ "$refs" = "$w" ] || fail "refs of $1.git are '$(echo "$refs" | tr '\n' ';')', the lock pins '${w}' — refusing to serve"
  git --git-dir="$dir" config http.receivepack false
  git --git-dir="$dir" config http.uploadpack true
}
assert "$REPO" "$LOCKED_COMMIT"
assert "$DEVIATIONS_REPO" "$DEVIATIONS_COMMIT"
echo "schema-mirror: serving ${REPO}.git at refs/tags/${LOCKED_COMMIT} and ${DEVIATIONS_REPO}.git at refs/tags/${DEVIATIONS_COMMIT} (read-only)"
exec lighttpd -D -f /etc/schema-mirror/lighttpd.conf
