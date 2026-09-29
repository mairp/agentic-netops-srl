#!/usr/bin/env bash
set -euo pipefail
# Redact any https://claude.ai/... URL from commit messages and file blobs across all refs.
# Requires git-filter-repo installed and available on PATH.

: "${REMOTE_URL:=origin}"

if ! command -v git >/dev/null || ! command -v git filter-repo >/dev/null 2>&1; then
  echo "git and git-filter-repo are required" >&2
  exit 1
fi

# Prepare replace patterns
cat > /tmp/replace-claude-patterns.txt <<'PAT'
regex:https?://claude\.ai/[^\s<>")]+ ==> [redacted-claude-link]
PAT

# Rewrite all heads and tags
GIT_FILTER_REPO_ARGS=(
  --force
  --refs refs/heads/* refs/tags/*
  --replace-text /tmp/replace-claude-patterns.txt
  --message-callback 'import re; return re.sub(rb"https?://claude\\.ai/[^\s<>\")]+", b"[redacted-claude-link]", message)'
)

printf "About to rewrite history to redact claude.ai URLs. This will force-push.\n" >&2
read -r -p "Type 'yes' to continue: " ans
if [[ "$ans" != "yes" ]]; then
  echo "Aborted." >&2
  exit 1
fi

git filter-repo "${GIT_FILTER_REPO_ARGS[@]}"

echo "Force-pushing rewritten history..." >&2
# Push back to the same remote; you may prefer a fork/backup.
git push --force --all "$REMOTE_URL"
git push --force --tags "$REMOTE_URL"

echo "Done."
