#!/usr/bin/env bash
# tests/gate/g01_capabilities.sh — G1: gNMI Capabilities — the native srl_nokia-* model set at the
# pinned release, at the pinned revision dates (tests/gate/expected/g01-models.tsv, read from the
# pinned YANG tag), and the JSON_IETF encoding (T043; quickstart.md §1, evidence/01 §7 G1).
#
# Sourced by run_gate.sh, which calls g01::run after the stock negative controls
# (negative_controls.sh negctl::G1). Executed directly it runs `run_gate.sh --only G1`.
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then exec bash "$GATE_HERE/run_gate.sh" --only G1 "$@"; fi
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"

G1_MODELS="$GATE_HERE/expected/g01-models.tsv"

g01::run() {
  gate::item_begin G1 "gNMI Capabilities: pinned srl_nokia-* model set and JSON_IETF"
  local node rc
  for node in $(lab::devices); do
    rc=0; gate::ready "G01.capabilities.${node}" G1-capabilities capabilities "$node" "$G1_MODELS" || rc=$?
    gate::item_check "capabilities:${node}" "$rc" "$node advertises every pinned model at its pinned revision and JSON_IETF"
  done
  gate::item_observe pinned_models_file "$(jq -Rn --arg f "tests/gate/expected/g01-models.tsv" '$f')"
  gate::item_end
}
