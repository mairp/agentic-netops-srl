#!/bin/sh
# schema-mirror entrypoint (T184; AD-75): unpack the one-ref bare repository the ConfigMap
# carries, refuse to serve unless its ONLY ref is refs/tags/<LOCKED_COMMIT> pointing at
# LOCKED_COMMIT, then serve it read-only over git smart HTTP.
#   SEED        the tarball of <REPO>.git (default /seed/repo.tar)
#   LOCKED_COMMIT  the commit versions.lock.yaml pins (compatibilitySet.deviationPatch.commit)
#   REPO        the served repository name (default srlinux-yang-patch)
set -eu
SEED="${SEED:-/seed/repo.tar}"
REPO="${REPO:-srlinux-yang-patch}"
fail() { echo "schema-mirror: $*" >&2; exit 1; }
case "${LOCKED_COMMIT:-}" in
  *[!0-9a-f]*|'') fail "LOCKED_COMMIT '${LOCKED_COMMIT:-}' is not a full commit hash — refusing to serve" ;;
esac
[ "${#LOCKED_COMMIT}" -eq 40 ] || fail "LOCKED_COMMIT '${LOCKED_COMMIT}' is not a full commit hash — refusing to serve"
[ -f "$SEED" ] || fail "no seed repository at $SEED — refusing to serve"
mkdir -p /srv/git
tar -C /srv/git -xf "$SEED"
dir="/srv/git/${REPO}.git"
[ -d "$dir" ] || fail "seed does not hold ${REPO}.git — refusing to serve"
refs="$(git --git-dir="$dir" for-each-ref --format='%(refname) %(objectname)')"
want="refs/tags/${LOCKED_COMMIT} ${LOCKED_COMMIT}"
[ "$refs" = "$want" ] || fail "refs of ${REPO}.git are '$(echo "$refs" | tr '\n' ';')', the lock pins '${want}' — refusing to serve"
git --git-dir="$dir" config http.receivepack false
git --git-dir="$dir" config http.uploadpack true
echo "schema-mirror: serving ${REPO}.git at refs/tags/${LOCKED_COMMIT} (read-only)"
exec lighttpd -D -f /etc/schema-mirror/lighttpd.conf
