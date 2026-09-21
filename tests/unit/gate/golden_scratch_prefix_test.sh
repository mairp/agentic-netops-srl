#!/usr/bin/env bash
# (T043 i; FR-108, AD-49) No golden under tests/golden/ contains the reserved scratch prefix
# vt-scratch-: scratch configuration is the verification tooling's, never a platform render's, and a
# render that emitted the prefix would make every leftover scan refuse a clean lab.
# Negative control first: a planted golden carrying the prefix must FAIL the same check.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../lib/leftovers.sh
source "$ROOT/tests/lib/leftovers.sh"

fails=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/golden/srl"
printf '{"srl_nokia-network-instance:network-instance":[{"name":"vt-scratch-macvrf"}]}\n' >"$TMP/golden/srl/leaf01.json"
if out="$(leftovers::check_goldens "$TMP/golden")"; then
  echo "FAIL negative control: a planted golden carrying vt-scratch- passed the check"; fails=$((fails + 1))
elif grep -q 'leaf01.json' <<<"$out"; then
  echo "PASS negative control: a planted golden carrying vt-scratch- fails the check, naming the file"
else
  echo "FAIL negative control did not name the file: $out"; fails=$((fails + 1))
fi

n="$(find "$ROOT/tests/golden" -type f ! -name .gitkeep 2>/dev/null | wc -l)"
if out="$(leftovers::check_goldens "$ROOT/tests/golden")"; then
  echo "PASS no golden under tests/golden/ carries vt-scratch- (${n} golden file(s) checked)"
else
  echo "$out"; fails=$((fails + 1))
fi
[[ "$fails" -eq 0 ]] || exit 1
