#!/usr/bin/env bash
# test_shell.sh — run every offline shell suite (T025; FR-020, AD-28, AD-57).
#
# The suites are whatever the glob tests/unit/**/*_test.sh finds — never a list
# kept here: a list goes stale with the next task that writes a suite, and the
# reach test (tests/unit/ci/shell_reach_test.sh) is what proves nothing in the
# tree was left out. None of them needs a lab.
#
# Each suite runs as `bash <suite>` from the repository root, in glob (sorted)
# order. The run stops at the FIRST non-zero exit, naming the suite and its exit
# status, and exits with that status.
#
# The executed list — one repository-relative path per line, written before a
# suite starts — goes to $TEST_SHELL_EXECUTED_LIST (default:
# <root>/bin/test_shell.executed; bin/ is git-ignored). Its path is printed and
# exported to the suites, so a suite run BY this runner can read it.
#
# Usage: test_shell.sh [--root <dir>] [--list]
#   --root <dir>  the tree to discover in (default: this repository) — fixtures
#   --list        list-only: print what the run would execute, in order, one
#                 path per line, and run nothing (the reach test's view of the
#                 runner: the same discovery function feeds both modes)
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
list_only=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$(cd -- "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
    --list) list_only=true; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "test_shell: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# discover — the one discovery both modes use: the glob, sorted, relative.
discover() {
  local f
  (
    cd "$ROOT"
    shopt -s globstar nullglob
    for f in tests/unit/**/*_test.sh; do
      [[ -f "$f" ]] && printf '%s\n' "$f"
    done
  ) | LC_ALL=C sort
}

mapfile -t suites < <(discover)

if [[ "$list_only" == true ]]; then
  printf '%s\n' "${suites[@]}"
  exit 0
fi

if [[ ${#suites[@]} -eq 0 ]]; then
  echo "test_shell: FAIL no suite matched tests/unit/**/*_test.sh under $ROOT" >&2
  exit 1
fi

executed="${TEST_SHELL_EXECUTED_LIST:-$ROOT/bin/test_shell.executed}"
mkdir -p "$(dirname "$executed")"
: >"$executed"
export TEST_SHELL_EXECUTED_LIST="$executed"
echo "test_shell: ${#suites[@]} suite(s) under $ROOT; executed list: $executed"

n=0
for s in "${suites[@]}"; do
  n=$((n + 1))
  printf '%s\n' "$s" >>"$executed"
  echo "=== [$n/${#suites[@]}] $s"
  rc=0
  (cd "$ROOT" && bash "$s") || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "test_shell: FAIL $s (exit $rc) — stopping at the first failing suite" >&2
    exit "$rc"
  fi
  echo "--- ok $s"
done
echo "test_shell: PASS ${#suites[@]} suite(s)"
