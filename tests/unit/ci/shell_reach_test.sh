#!/usr/bin/env bash
# Shell-suite reach test (T025; FR-020, AD-28, AD-50, AD-57).
#
# Fails naming any *_test.sh in the tree that the runner scripts/ci/test_shell.sh
# does not execute — outside the live directories tests/{gate,integration,e2e}
# (they need a lab and have their own targets) and outside what is not this
# repository's code: the upstream reference checkouts config-server/,
# data-server/, kuid/, sdcio-docs/, and node_modules/, .venv/, .git/, specs/,
# .specstride/, .mixture-of-loops/.
#
# Recursion: this suite is itself run by the runner, so it never runs the
# runner for real. It reads the runner's executed list through the runner's own
# list-only mode (`test_shell.sh --list`, the same discovery function the run
# loop iterates); and when it IS being run by the runner, it also checks that
# its own path is in the executed list the runner exported
# (TEST_SHELL_EXECUTED_LIST), i.e. that the list it compared is the one in use.
#
# Negative control: a fixture tree (built in a temp dir, so its planted suites
# are never found by the real runner) with suites outside tests/unit/ must make
# the check fail naming exactly those files.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RUNNER="$ROOT/scripts/ci/test_shell.sh"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

# every_suite <root> — every *_test.sh the reach rule covers, relative, sorted.
every_suite() {
  (cd "$1" && find . \
    \( -path ./tests/gate -o -path ./tests/integration -o -path ./tests/e2e \
       -o -path ./config-server -o -path ./data-server -o -path ./kuid -o -path ./sdcio-docs \
       -o -path ./specs -o -path ./.specstride -o -path ./.mixture-of-loops -o -path ./.git \
       -o -name node_modules -o -name .venv \) -prune \
    -o -type f -name '*_test.sh' -print | sed 's|^\./||' | LC_ALL=C sort)
}

# reach_check <root> — prints each unreached suite as "UNREACHED <path>"; exit 1 if any.
reach_check() {
  local root="$1" listed all rc=0 s
  listed="$(bash "$RUNNER" --root "$root" --list)" || { echo "runner --list failed"; return 1; }
  all="$(every_suite "$root")"
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    if ! grep -qxF -- "$s" <<<"$listed"; then
      echo "UNREACHED $s — not in scripts/ci/test_shell.sh's executed list"
      rc=1
    fi
  done <<<"$all"
  return "$rc"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- negative control: planted suites the runner cannot reach
fx="$TMP/tree"
plant() { mkdir -p "$(dirname "$fx/$1")"; printf '#!/usr/bin/env bash\nexit 0\n' >"$fx/$1"; }
plant tests/unit/a/a_test.sh
plant tests/unit/deep/er/b_test.sh
plant tests/other/orphan_test.sh
plant scripts/lib/stray_test.sh
plant tests/gate/live_test.sh
plant tests/integration/live_test.sh
plant tests/e2e/live_test.sh
plant ui/node_modules/pkg/vendored_test.sh
plant config-server/upstream_test.sh
mkdir -p "$fx/scripts/ci" && cp "$RUNNER" "$fx/scripts/ci/test_shell.sh"
out="$(reach_check "$fx")"; rc=$?
unreached="$(sed -n 's/^UNREACHED \([^ ]*\).*/\1/p' <<<"$out" | tr '\n' ' ')"
if [[ "$rc" -ne 0 && "$unreached" == "scripts/lib/stray_test.sh tests/other/orphan_test.sh " ]]; then
  pass "negative control: suites outside tests/unit/ fail the check, each named (live dirs, node_modules, upstream ignored)"
else
  fail "negative control: suites outside tests/unit/ fail the check, each named (rc=$rc, got '$unreached')" "$out"
fi
rm -rf "$fx/tests/other" "$fx/scripts/lib"
out="$(reach_check "$fx")"; rc=$?
[[ "$rc" -eq 0 ]] && pass "fixture: with the strays removed, nested tests/unit suites are all reached" \
  || fail "fixture: with the strays removed, nested tests/unit suites are all reached" "$out"

# --- the real tree
out="$(reach_check "$ROOT")"; rc=$?
if [[ "$rc" -eq 0 ]]; then
  pass "every *_test.sh in this repository (outside tests/{gate,integration,e2e} and vendored trees) is in the runner's executed list ($(every_suite "$ROOT" | wc -l) suites)"
else
  fail "every *_test.sh in this repository is in the runner's executed list" "$out"
fi

# --- under the runner: the list it exported contains this suite
if [[ -n "${TEST_SHELL_EXECUTED_LIST:-}" ]]; then
  if grep -qxF "tests/unit/ci/shell_reach_test.sh" "$TEST_SHELL_EXECUTED_LIST" 2>/dev/null; then
    pass "run by the runner: this suite is in its executed list ($TEST_SHELL_EXECUTED_LIST)"
  else
    fail "run by the runner: this suite is in its executed list ($TEST_SHELL_EXECUTED_LIST)"
  fi
fi

echo "shell_reach_test: $fails failure(s)"
[ "$fails" -eq 0 ]
