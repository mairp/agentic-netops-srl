#!/usr/bin/env bash
# session_links_test.sh — scripts/ci/verify_no_session_links.sh refuses a session link in a tracked
# file or in any commit message, and passes a clean history (Co-Authored-By alone is not a link).
# Every link below is assembled from parts so this suite never matches the guard itself.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
GUARD="$ROOT/scripts/ci/verify_no_session_links.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    | /'; }

LINK="https://claude"".ai/code/session_0123456789abcdef"
TRAILER="Claude""-Session: $LINK"

repo() {
  local d="$T/$1"
  git init -q "$d"
  git -C "$d" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty \
    -m "feat: a change" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
  printf '%s\n' "$d"
}
commit() { git -C "$1" -c user.email=t@example.invalid -c user.name=t commit -q "${@:2}"; }

d="$(repo clean)"; echo "plain text" >"$d/a.md"; git -C "$d" add a.md; commit "$d" -m "docs: a"
out="$(bash "$GUARD" "$d" 2>&1)" && pass "a clean tree and history pass (Co-Authored-By is not a link)" \
  || fail "a clean tree and history pass" "$out"

d="$(repo file)"; echo "see $LINK" >"$d/a.md"; git -C "$d" add a.md; commit "$d" -m "docs: a"
out="$(bash "$GUARD" "$d" 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && grep -q "tracked file carries a session link" <<<"$out" && grep -q "a.md" <<<"$out" \
  && pass "a tracked file with a link fails, naming the file" || fail "a tracked file with a link fails" "$out"

d="$(repo trailer)"; commit "$d" --allow-empty -m "fix: b" -m "$TRAILER"; commit "$d" --allow-empty -m "fix: c"
out="$(bash "$GUARD" "$d" 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && grep -q "message carries a session link" <<<"$out" \
  && pass "a session trailer in an earlier commit message fails" || fail "an earlier commit's trailer fails" "$out"

out="$(bash "$GUARD" "$ROOT" 2>&1)" && pass "this repository passes" || fail "this repository passes" "$out"

echo "session_links_test: $fails failure(s)"
[[ "$fails" -eq 0 ]]
