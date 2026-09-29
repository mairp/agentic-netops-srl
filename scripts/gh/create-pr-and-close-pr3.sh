#!/usr/bin/env bash
# Create a remote branch and PR with local changes using only the GitHub CLI (gh API),
# then label+close PR #3 and ask Mergify to queue this PR.
# No git push or remote manipulation beyond gh API.
set -euo pipefail

OWNER=${OWNER:-mairp}
REPO=${REPO:-agentic-netops-srl}
BRANCH=${BRANCH:-chore/secure-remove-claude}
BASE_BRANCH=${BASE_BRANCH:-main}
PR_TITLE=${PR_TITLE:-"security: redact Claude sessions; add CI link guard; enable auto-queue"}
PR_BODY_FILE=${PR_BODY_FILE:-}

if ! command -v gh >/dev/null; then
  echo "gh CLI is required" >&2; exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  # gh auth status will still use its stored token if available
  gh auth status -h github.com >/dev/null || { echo "gh is not authenticated" >&2; exit 1; }
fi

# Resolve latest main commit and base tree
MAIN_REF_JSON=$(gh api -H "Accept: application/vnd.github+json" repos/$OWNER/$REPO/git/refs/heads/$BASE_BRANCH)
MAIN_SHA=$(printf '%s' "$MAIN_REF_JSON" | jq -r .object.sha)
COMMIT_JSON=$(gh api -H "Accept: application/vnd.github+json" repos/$OWNER/$REPO/git/commits/$MAIN_SHA)
BASE_TREE_SHA=$(printf '%s' "$COMMIT_JSON" | jq -r .tree.sha)

# Helper to create a blob from a file path; returns blob sha
mkblob() {
  local path="$1"; local mode="${2:-100644}"; local enc="base64"; local b64
  [[ -f "$path" ]] || { echo "missing file: $path" >&2; return 2; }
  # respect executable bit for scripts
  if [[ -x "$path" ]]; then mode=100755; fi
  b64=$(base64 -w0 "$path")
  local sha
  sha=$(gh api -X POST -H "Accept: application/vnd.github+json" repos/$OWNER/$REPO/git/blobs -f content="$b64" -f encoding="$enc" --jq .sha)
  printf '%s %s' "$sha" "$mode"
}

# Files we changed locally that should be in the PR
mapfile -t FILES < <(printf '%s\n' \
  docs/security/redact-claude-sessions.md \
  scripts/redact-claude-history.sh \
  scripts/ci/check-no-claude-links.sh \
  .github/workflows/ci.yaml \
  .mergify.yml)

# Build tree entries
TREE_ENTRIES=()
for f in "${FILES[@]}"; do
  read -r SHA MODE < <(mkblob "$f")
  TREE_ENTRIES+=("{\"path\": \"$f\", \"mode\": \"$MODE\", \"type\": \"blob\", \"sha\": \"$SHA\"}")
done
TREE_JSON=$(printf '{"base_tree":"%s","tree":[%s]}' "$BASE_TREE_SHA" "$(IFS=,; echo "${TREE_ENTRIES[*]}")")
NEW_TREE_SHA=$(gh api -X POST -H "Accept: application/vnd.github+json" repos/$OWNER/$REPO/git/trees --input - --jq .sha <<<"$TREE_JSON")

NEW_COMMIT_SHA=$(gh api -X POST -H "Accept: application/vnd.github+json" \
  repos/$OWNER/$REPO/git/commits -f message="$PR_TITLE" -f tree="$NEW_TREE_SHA" -f parents[]="$MAIN_SHA" --jq .sha)

# Create or update branch ref
if gh api -X POST -H "Accept: application/vnd.github+json" repos/$OWNER/$REPO/git/refs -f ref="refs/heads/$BRANCH" -f sha="$NEW_COMMIT_SHA" >/dev/null 2>&1; then
  echo "Created remote branch $BRANCH"
else
  echo "Branch exists; forcing update"
  gh api -X PATCH -H "Accept: application/vnd.github+json" repos/$OWNER/$REPO/git/refs/heads/$BRANCH -f sha="$NEW_COMMIT_SHA" -f force=true >/dev/null
fi

# Create PR using REST (avoids GraphQL if flaky)
if [[ -z "$PR_BODY_FILE" ]]; then
  PR_BODY_FILE=$(mktemp)
  cat >"$PR_BODY_FILE" <<'BODY'
This PR prepares safe redaction and CI enforcement:

- docs/security/redact-claude-sessions.md: step-by-step plan + commands to remove any https://claude.ai/... URL and <conversation> blocks across the entire history using git-filter-repo.
- scripts/redact-claude-history.sh: an interactive helper script to run the rewrite and force-push.
- CI: scripts/ci/check-no-claude-links.sh enforced early in each job.
- Mergify: pull_request_rules added to auto-queue eligible PRs targeting main.

Follow-up ops (post-merge):
1) Run the rewrite to purge any exposed Claude session links from all refs.
2) Close PR #3 and delete its branch (contains a Claude conversation link; must not merge).
3) Ensure CI passes, let Mergify merge follow-ups, then make the repo public.
BODY
fi
PR_NUMBER=$(gh api -X POST -H "Accept: application/vnd.github+json" \
  repos/$OWNER/$REPO/pulls \
  -f title="$PR_TITLE" -f head="$BRANCH" -f base="$BASE_BRANCH" \
  --input "$PR_BODY_FILE" --jq .number)
PR_URL="https://github.com/$OWNER/$REPO/pull/$PR_NUMBER"
echo "PR created: $PR_URL"

# Label + close PR #3, delete its branch
if gh api -H "Accept: application/vnd.github+json" repos/$OWNER/$REPO/pulls/3 >/dev/null 2>&1; then
  gh api -X POST -H "Accept: application/vnd.github+json" repos/$OWNER/$REPO/issues/3/labels -f labels='["do-not-merge"]' >/dev/null || true
  gh api -X PATCH -H "Accept: application/vnd.github+json" repos/$OWNER/$REPO/pulls/3 -f state=closed >/dev/null || true
  PR3_HEAD=$(gh api -H "Accept: application/vnd.github+json" repos/$OWNER/$REPO/pulls/3 --jq .head.ref || echo "")
  if [[ -n "$PR3_HEAD" && "$PR3_HEAD" != "null" ]]; then
    gh api -X DELETE -H "Accept: application/vnd.github+json" repos/$OWNER/$REPO/git/refs/heads/$PR3_HEAD >/dev/null || true
  fi
fi

# Ask Mergify to queue the new PR
gh api -X POST -H "Accept: application/vnd.github+json" \
  repos/$OWNER/$REPO/issues/$PR_NUMBER/comments \
  -f body='@mergifyio queue' >/dev/null || true

echo "All done: $PR_URL"
