#!/usr/bin/env bash
# Rewrite history locally to redact Claude session links and <conversation> blocks,
# then update remote refs using GitHub CLI (gh api) instead of git push.
# Requires: git, git-filter-repo, gh, jq
set -euo pipefail

OWNER=${OWNER:-mairp}
REPO=${REPO:-agentic-netops-srl}
REMOTE_HOST=${REMOTE_HOST:-github.com}

if ! command -v gh >/dev/null; then echo "gh CLI is required" >&2; exit 1; fi
if ! command -v jq >/dev/null; then echo "jq is required" >&2; exit 1; fi
if ! git filter-repo --version >/dev/null 2>&1; then echo "git-filter-repo is required" >&2; exit 1; fi

# Confirm
echo "This will rewrite local history and then force-update remote refs via GitHub API for $OWNER/$REPO." >&2
read -r -p "Type 'yes' to continue: " ans
[[ "$ans" == "yes" ]] || { echo "Aborted." >&2; exit 1; }

# Redaction: same logic as scripts/redact-claude-history.sh
cat > /tmp/replace-claude-patterns.txt <<'PAT'
regex:https?://claude\.ai/[^\s<>")]+ ==> [redacted-claude-link]
PAT

git filter-repo \
  --force \
  --refs refs/heads/* refs/tags/* \
  --replace-text /tmp/replace-claude-patterns.txt \
  --message-callback 'import re; return re.sub(rb"https?://claude\\.ai/[^\s<>\")]+", b"[redacted-claude-link]", message)' \
  --blob-callback 'import re; d = blob.data
if b"claude.ai" in d:
    d = re.sub(re.compile(br"(?is)<conversation>.*?claude\\.ai.*?</conversation>"), b"[redacted-conversation]", d)
    d = re.sub(br"https?://claude\\.ai/[^\s<>\")]+", b"[redacted-claude-link]", d)
    blob.data = d'

# Update remote refs via GitHub API
update_ref() {
  local refname="$1" sha="$2"
  local path="repos/$OWNER/$REPO/git/refs/${refname}"
  # Try PATCH (update); if 422/404 then try create (POST)
  if gh api -X PATCH -H "Accept: application/vnd.github+json" "$path" -f sha="$sha" -f force=true >/dev/null 2>&1; then
    echo "Updated $refname -> $sha"
    return 0
  fi
  if gh api -X POST -H "Accept: application/vnd.github+json" "repos/$OWNER/$REPO/git/refs" -f ref="refs/${refname}" -f sha="$sha" >/dev/null 2>&1; then
    echo "Created $refname -> $sha"
    return 0
  fi
  echo "Failed to update $refname" >&2
  return 1
}

# Heads
while read -r ref sha; do
  # ref like refs/heads/main
  short=${ref#refs/}
  update_ref "$short" "$sha"
done < <(git for-each-ref --format='%(refname) %(objectname)' refs/heads/)

# Tags (annotated or lightweight). Use the tag object (rev-parse returns tag object ID when annotated).
while read -r ref sha; do
  short=${ref#refs/}
  update_ref "$short" "$sha"
done < <(git for-each-ref --format='%(refname) %(objectname)' refs/tags/)

echo "Remote refs updated via gh api. Consider closing/reopening PRs if needed."