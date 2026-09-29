#!/usr/bin/env bash
# gate_record_negs_test.sh — run_gate::record's negative-control collection must survive a run
# directory holding no negative-control record. T151 r8 cycle 3 / T152 r7: `[[ -f ]] && jq` on the
# unmatched glob returned 1, and under `set -euo pipefail` the gate died before writing
# gate-record.json and sealing its artefacts (69 "not referenced" failures in verify-evidence).
# The test executes the line as it stands in tests/gate/run_gate.sh.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
line="$(grep -E '^\s*negs="\$\(for f in "\$EVIDENCE_DIR"/\*\.negative-control\*\.json' "$ROOT/tests/gate/run_gate.sh")"
[[ -n "$line" ]] || { echo "FAIL the negs line was not found in run_gate.sh"; exit 1; }
fail=0
run() { EVIDENCE_DIR="$1" bash -c "set -euo pipefail; f() { local negs; ${line}; printf '%s' \"\$negs\"; }; f"; }
empty="$(mktemp -d)"; one="$(mktemp -d)"; trap 'rm -rf "$empty" "$one"' EXIT
if out="$(run "$empty")" && [[ "$out" == "[]" ]]; then echo "ok   no negative-control record: [] and the gate goes on"; else echo "FAIL empty run directory killed the record step (out='${out:-}')"; fail=1; fi
jq -n '{check_id: "G6-mtu", id: "G6.nc", negative_control_failed: true}' >"$one/G6.negative-control.json"
if out="$(run "$one")" && [[ "$(jq -r '.[0].check' <<<"$out")" == "G6-mtu" ]]; then echo "ok   one negative-control record collected"; else echo "FAIL one record not collected (out='${out:-}')"; fail=1; fi
# negative control: the old form dies on the empty directory
old='negs="$(for f in "$EVIDENCE_DIR"/*.negative-control*.json; do [[ -f "$f" ]] && echo x; done | jq -s -c ".")"'
if EVIDENCE_DIR="$empty" bash -c "set -euo pipefail; f() { local negs; ${old}; }; f" 2>/dev/null; then echo "FAIL negative control: the old form survived"; fail=1; else echo "ok   negative control: the old form dies"; fi
exit "$fail"
