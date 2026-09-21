#!/usr/bin/env bash
# scripts/ci/test_shell.sh behaviour (T025; FR-020, AD-57), on fixture trees
# built in a temp dir (never under tests/unit/, so the real runner does not
# find the planted suites):
#   - it discovers nested tests/unit/**/*_test.sh by glob and runs them in order;
#   - it stops at the FIRST non-zero exit, naming the suite, with its status;
#     a later suite does not run;
#   - it writes its executed list, and --list prints the same discovery.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RUNNER="$ROOT/scripts/ci/test_shell.sh"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
suite() {  # suite <tree> <rel> <body>
  mkdir -p "$(dirname "$1/$2")"; printf '#!/usr/bin/env bash\n%s\n' "$3" >"$1/$2"
}

t="$TMP/stop"
suite "$t" tests/unit/a/a_test.sh 'touch "$MARK/a"; exit 0'
suite "$t" tests/unit/b/nested/b_test.sh 'touch "$MARK/b"; exit 3'
suite "$t" tests/unit/c/c_test.sh 'touch "$MARK/c"; exit 0'
suite "$t" tests/unit/c/helper.sh 'touch "$MARK/helper"'
mkdir -p "$TMP/mark"
out="$(MARK="$TMP/mark" TEST_SHELL_EXECUTED_LIST="$TMP/stop.list" bash "$RUNNER" --root "$t" 2>&1)"; rc=$?
if [[ "$rc" -eq 3 ]] && grep -q 'test_shell: FAIL tests/unit/b/nested/b_test.sh (exit 3)' <<<"$out" \
  && [[ -e "$TMP/mark/a" && -e "$TMP/mark/b" && ! -e "$TMP/mark/c" && ! -e "$TMP/mark/helper" ]] \
  && [[ "$(cat "$TMP/stop.list")" == $'tests/unit/a/a_test.sh\ntests/unit/b/nested/b_test.sh' ]]; then
  pass "stops at the first failing suite naming it (exit 3), later suite not run, executed list = a, b"
else
  fail "stops at the first failing suite naming it" "$out"$'\n'"list: $(cat "$TMP/stop.list" 2>&1)"
fi

t="$TMP/ok"
suite "$t" tests/unit/z/z_test.sh 'exit 0'
suite "$t" tests/unit/a/deep/er/a_test.sh 'exit 0'
suite "$t" tests/unit/m/m_test.sh '[[ -f "$TEST_SHELL_EXECUTED_LIST" ]]'
out="$(env -u TEST_SHELL_EXECUTED_LIST bash "$RUNNER" --root "$t" 2>&1)"; rc=$?
listed="$(bash "$RUNNER" --root "$t" --list)"
if [[ "$rc" -eq 0 ]] && grep -q 'test_shell: PASS 3 suite(s)' <<<"$out" \
  && [[ "$(cat "$t/bin/test_shell.executed")" == "$listed" ]] \
  && [[ "$listed" == $'tests/unit/a/deep/er/a_test.sh\ntests/unit/m/m_test.sh\ntests/unit/z/z_test.sh' ]]; then
  pass "all pass: every nested suite found by the glob runs; default executed list equals --list"
else
  fail "all pass: every nested suite found by the glob runs; executed list equals --list" "$out"$'\n'"listed: $listed"
fi

t="$TMP/empty"; mkdir -p "$t/tests/unit"
out="$(bash "$RUNNER" --root "$t" 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && grep -q 'no suite matched' <<<"$out" && pass "no suite found is a failure, never a silent pass" \
  || fail "no suite found is a failure (rc=$rc)" "$out"

code="$(grep -vE '^[[:space:]]*#' "$RUNNER")"          # the runner's code, comments dropped
if grep -qF 'tests/unit/**/*_test.sh' <<<"$code" && ! grep -oE '[A-Za-z0-9_./*-]*_test\.sh' <<<"$code" | grep -qvxF 'tests/unit/**/*_test.sh'; then
  pass "the runner names no suite: its only suite reference is the glob tests/unit/**/*_test.sh"
else
  fail "the runner names no suite" "$(grep -nE '[a-z_]+_test\.sh' "$RUNNER")"
fi

echo "test_shell_runner_test: $fails failure(s)"
[ "$fails" -eq 0 ]
