#!/usr/bin/env bash
# tree_hash.sh — gate::tree_hash: the SHA-256 identity of the capability gate's own code.
#
# Every tracked-looking file under tests/gate/ (the item scripts, lib/, expected/) and tests/lib/,
# excluding tests/gate/observed/ (what the gate WROTE, not what it IS), contributes the line
# `<repo-relative path> NUL <sha256>`; the sorted lines are hashed. The gate record carries it as
# `gate_tree_sha256` and the published qualification record as `gate.gate_tree_sha256`, so
# scripts/provision.sh's GateReady can tell a record made by THIS gate from one made by another
# (a changed check never inherits an old pass).
[[ -n "${__AGENTIC_NETOPS_GATE_TREE_HASH_SH:-}" ]] && return 0
__AGENTIC_NETOPS_GATE_TREE_HASH_SH=1

gate::tree_hash() {
  local root="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)}"
  (
    cd "$root" || exit 1
    find tests/gate tests/lib -type f ! -path 'tests/gate/observed/*' ! -name '*~' -print0 \
      | LC_ALL=C sort -z \
      | while IFS= read -r -d '' f; do printf '%s\0%s\n' "$f" "$(sha256sum -- "$f" | cut -d' ' -f1)"; done
  ) | sha256sum | cut -d' ' -f1
}
