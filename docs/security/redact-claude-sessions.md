Title: Redact Claude session links from the entire Git history

Goal
- Permanently remove any Claude session URL (e.g., https://claude.ai/code/session_...) from every commit message and every file blob across all branches and tags.
- Remove any <conversation>...</conversation> blocks that include a claude.ai link.
- Also sanitize PR descriptions containing such links.

What this will remove
- Any URL starting with https://claude.ai/ (case-insensitive), including code/session_* links.
- Only the URL is redacted; normal code references to providers (e.g., anthropic/claude) are preserved.

Safe plan
1) Fresh mirror clone (recommended):
   git clone --mirror https://github.com/<owner>/<repo>.git <repo>.git
   cd <repo>.git

2) Dry-run scan to assess scope (optional but recommended):
   git log --all --grep='claude.ai' -i --oneline
   git log --all -G 'claude\.ai' --oneline
   git grep -n --all-match -i -e 'claude\.ai' || true

3) Run the redaction (commit messages + blobs):
   # Create replace patterns file
   cat > replace-claude-patterns.txt <<'PAT'
   regex:https?://claude\.ai/[^\s<>")]+ ==> [redacted-claude-link]
   # Keep it strictly domain-scoped; do NOT replace plain words like "claude" to avoid breaking code.
   PAT

   # Rewrite (all refs) with git-filter-repo: remove URLs and redact <conversation> blocks with claude.ai links
   git filter-repo \
     --force \
     --refs refs/heads/* refs/tags/* \
     --replace-text replace-claude-patterns.txt \
     --message-callback 'import re; return re.sub(rb"https?://claude\\.ai/[^\s<>\")]+", b"[redacted-claude-link]", message)' \
     --blob-callback 'import re; d = blob.data
if b"claude.ai" in d:
    d = re.sub(re.compile(br"(?is)<conversation>.*?claude\\.ai.*?</conversation>"), b"[redacted-conversation]", d)
    d = re.sub(br"https?://claude\\.ai/[^\s<>\")]+", b"[redacted-claude-link]", d)
    blob.data = d'

4) Force-push rewritten history (DANGEROUS: invalidates all commit SHAs):
   git push --force --all origin
   git push --force --tags origin

5) Close or sanitize impacted PRs (server-side):
   # Example with GitHub CLI
   gh pr edit 3 --body 'Removed link to external conversation. [redacted]'
   gh pr close 3 --delete-branch

6) Prevent future leaks
   - Add a pre-commit hook or CI check that fails when claude.ai URLs are present in diffs or commit messages.

Notes
- A full history rewrite will close or invalidate open PRs and require re-cloning for collaborators. Coordinate before running.
- Untracked files in your working directory are not touched by filter-repo.
