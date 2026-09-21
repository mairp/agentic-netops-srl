#!/usr/bin/env bash
# envtest reach test (T025; FR-020, AD-28): every directory under tests/envtest/
# that contains Go files is reached by the command `make test-envtest` runs
# (scripts/ci/test_envtest.sh: go test -tags envtest ./tests/envtest/...). The
# runner's --list mode prints what that command reaches, from the same package
# pattern and tags as the real run. Offline: `go list` only.
#
# Negative control: a throwaway module (temp dir, stdlib only) with one envtest
# package and one whose files carry a different build tag — so the envtest
# command cannot reach it — must fail naming that directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RUNNER="$ROOT/scripts/ci/test_envtest.sh"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

if ! command -v go >/dev/null; then echo "FAIL go not on PATH"; exit 1; fi

# go_dirs <root> — absolute dirs under <root>/tests/envtest holding a .go file
# (skipping what the go tool itself skips: testdata, _*, .*).
go_dirs() {
  [[ -d "$1/tests/envtest" ]] || return 0
  (cd "$1" && find tests/envtest \( -name testdata -o -name '_*' -o -name '.*' \) -prune \
    -o -type f -name '*.go' -printf '%h\n' | sort -u | while read -r d; do (cd "$d" && pwd); done) | LC_ALL=C sort
}

# reach_check <root> — "UNREACHED <dir>" per unreached directory; exit 1 if any.
reach_check() {
  local root="$1" listed d rc=0
  listed="$(bash "$RUNNER" --root "$root" --list)" || { echo "test_envtest.sh --list failed"; return 1; }
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    grep -qxF -- "$d" <<<"$listed" || { echo "UNREACHED ${d#"$root"/} — not reached by go test -tags envtest ./tests/envtest/..."; rc=1; }
  done < <(go_dirs "$root")
  return "$rc"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fx="$TMP/mod"
mkdir -p "$fx/tests/envtest/api" "$fx/tests/envtest/controllers" "$fx/tests/envtest/api/testdata"
printf 'module example.com/fx\n\ngo 1.22\n' >"$fx/go.mod"
printf '//go:build envtest\n\npackage api\n\nimport "testing"\n\nfunc TestX(t *testing.T) {}\n' >"$fx/tests/envtest/api/x_test.go"
printf '//go:build integration\n\npackage controllers\n\nimport "testing"\n\nfunc TestY(t *testing.T) {}\n' >"$fx/tests/envtest/controllers/y_test.go"
printf 'package ignored\n' >"$fx/tests/envtest/api/testdata/z.go"
out="$(GOTOOLCHAIN=local GOFLAGS=-mod=mod reach_check "$fx")"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qx 'UNREACHED tests/envtest/controllers — .*' <<<"$out" && [[ "$(grep -c UNREACHED <<<"$out")" -eq 1 ]]; then
  pass "negative control: a tests/envtest directory the envtest command cannot reach fails, named"
else
  fail "negative control: a tests/envtest directory the envtest command cannot reach fails, named (rc=$rc)" "$out"
fi
sed -i 's|//go:build integration|//go:build envtest|' "$fx/tests/envtest/controllers/y_test.go"
out="$(GOTOOLCHAIN=local GOFLAGS=-mod=mod reach_check "$fx")"; rc=$?
[[ "$rc" -eq 0 ]] && pass "fixture: with the envtest tag, both directories are reached" \
  || fail "fixture: with the envtest tag, both directories are reached" "$out"

n="$(go_dirs "$ROOT" | wc -l)"
out="$(reach_check "$ROOT")"; rc=$?
[[ "$rc" -eq 0 ]] && pass "every directory with Go files under tests/envtest/ is reached by make test-envtest ($n directories)" \
  || fail "every directory with Go files under tests/envtest/ is reached by make test-envtest" "$out"

echo "envtest_reach_test: $fails failure(s)"
[ "$fails" -eq 0 ]
