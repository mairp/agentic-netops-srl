#!/usr/bin/env bash
# verify_no_session_links.sh — no AI-assistant conversation link is published with this repository.
#
# Fails, naming every hit, when a tracked file or a commit message carries an AI-assistant
# conversation URL or session trailer. Commit messages are every commit reachable in this checkout (CI's
# checkout is shallow, so there it is the commit under test); tracked files are the working tree's.
# `Co-Authored-By:` attribution is not a link and is not refused.
#
#   verify_no_session_links.sh [root]      exit 0 clean, 1 on any hit
#
# The vendor name is spelled in octal escapes so this file never matches itself or a name search.
set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$root"

vendor="$(printf '\143\154\141\165\144\145')"   # the assistant vendor's name, lower case
host="${vendor}\\.ai"
url_re="https?://([a-z0-9-]+\.)?${host}(/|\b)"
trailer_re="^[[:space:]]*${vendor}-session:"   # matched case-insensitively (grep -i)

hits=0
tree="$(git grep -nIiE "$url_re|$trailer_re" -- . || true)"
if [[ -n "$tree" ]]; then
  printf 'FAIL tracked file carries a session link:\n%s\n' "$tree" >&2
  hits=1
fi

while IFS= read -r c; do
  msg="$(git log -1 --format=%B "$c" | grep -nIiE "$url_re|$trailer_re" || true)"
  if [[ -n "$msg" ]]; then
    printf 'FAIL commit %s message carries a session link:\n%s\n' "${c:0:12}" "$msg" >&2
    hits=1
  fi
done < <(git rev-list HEAD)

if [[ "$hits" -ne 0 ]]; then
  echo "verify-no-session-links: FAIL" >&2
  exit 1
fi
echo "verify-no-session-links: PASS (tree and $(git rev-list --count HEAD) commit message(s))"
