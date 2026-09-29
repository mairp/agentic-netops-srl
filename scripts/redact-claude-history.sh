#!/usr/bin/env bash
set -euo pipefail
# Redact any https://claude.ai/... URL and any <conversation>...</conversation> block that contains a claude.ai link
# from commit messages and file blobs across all refs. Requires git-filter-repo on PATH.

: "${REMOTE_URL:=origin}"

if ! command -v git >/dev/null 2>&1 || ! git filter-repo --version >/dev/null 2>&1; then
  echo "git and git-filter-repo are required" >&2
  exit 1
fi

# Prepare replace patterns for simple URL replacements (blobs + commit messages)
cat > /tmp/replace-claude-patterns.txt <<'PAT'
regex:https?://claude\.ai/[^\s<>")]+ ==> [redacted-claude-link]
PAT

# Rewrite all heads and tags
GIT_FILTER_REPO_ARGS=(
  --force
  --refs refs/heads/* refs/tags/*
  --replace-text /tmp/replace-claude-patterns.txt
  --message-callback 'import re; return re.sub(rb"https?://claude\\.ai/[^\s<>\")]+", b"[redacted-claude-link]", message)'
  --blob-callback 'import re; d = blob.data
if b"claude.ai" in d:
    # Remove any <conversation>...</conversation> block that contains a claude.ai link (multiline)
    d = re.sub(re.compile(br"(?is)<conversation>.*?claude\\.ai.*?</conversation>"), b"[redacted-conversation]", d)
    # Also replace any remaining claude.ai URLs (defense in depth)
    d = re.sub(br"https?://claude\\.ai/[^\s<>\")]+", b"[redacted-claude-link]", d)
    blob.data = d'
)

printf "About to rewrite history to redact claude.ai links and conversations. This will force-push.\n" >&2
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