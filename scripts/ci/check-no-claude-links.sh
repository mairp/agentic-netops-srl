#!/usr/bin/env bash
set -euo pipefail

# Fail if any claude.ai URL appears in the current tree or in the HEAD commit message.
PATTERN='https?://claude\.ai/'

# Scan repository tree (tracked files). Exclude typical vendored/ignored directories just in case.
TREE_MATCHES="$(git grep -nI -E "$PATTERN" -- . || true)"
if [[ -n "$TREE_MATCHES" ]]; then
  echo "Found claude.ai URLs in repository tree:" >&2
  echo "$TREE_MATCHES" >&2
  exit 1
fi

# Scan last commit message (useful on push workflows).
MSG_MATCHES="$(git log -1 --pretty=%B | grep -niE "$PATTERN" || true)"
if [[ -n "$MSG_MATCHES" ]]; then
  echo "Found claude.ai URLs in HEAD commit message:" >&2
  echo "$MSG_MATCHES" >&2
  exit 1
fi

echo "No claude.ai URLs found." >&2
