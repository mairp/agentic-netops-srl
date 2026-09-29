#!/usr/bin/env bash
# fabric_examples_unique_test.sh — examples/fabric/ declares each Fabric exactly once, and the default
# Fabric declares the untagged access port the lab's topology wires (client02 eth2 — leaf02
# ethernet-1/2, AD-68). T151 r8: a second manifest of fabric01 without untaggedAccessPorts was applied
# after the default one and removed the port, failing claim-lifecycle's untagged ip-vrf case.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail=0
dups="$(yq -r 'select(.kind == "Fabric") | (.metadata.namespace // "agentic-netops-system") + "/" + .metadata.name' "$ROOT"/examples/fabric/*.yaml | grep -v "^---$" | sort | uniq -d)"
if [[ -n "$dups" ]]; then echo "FAIL examples/fabric/ declares a Fabric more than once: $dups"; fail=1; else echo "ok   each Fabric declared once"; fi
u="$(yq -r 'select(.kind == "Fabric") | .spec.inventory[] | select(.node == "leaf02") | .untaggedAccessPorts[]?' "$ROOT/examples/fabric/default-fabric.yaml")"
if [[ "$u" == "ethernet-1/2" ]]; then echo "ok   leaf02 ethernet-1/2 declared untagged"; else echo "FAIL default Fabric: leaf02 untaggedAccessPorts = '${u}'"; fail=1; fi
# negative control: a duplicate is detected
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp "$ROOT/examples/fabric/default-fabric.yaml" "$tmp/a.yaml"; cp "$tmp/a.yaml" "$tmp/b.yaml"
if [[ -n "$(yq -r 'select(.kind == "Fabric") | .metadata.name' "$tmp"/*.yaml | grep -v "^---$" | sort | uniq -d)" ]]; then
  echo "ok   negative control: a planted duplicate is detected"; else echo "FAIL negative control"; fail=1; fi
exit "$fail"
