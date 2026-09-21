#!/usr/bin/env bash
# inventory.sh suite (T038; FR-012): the infra Node/Endpoint/Link inventory generated from the
# containerlab topology. Offline; python3 + PyYAML.
#   the fixture lab renders 4 Node (SR Linux only, no client), 10 Endpoint, 4 Link with the
#     platform, version, roles, ports and link names of the reference lab
#   every spec field is a field of kuid v0.0.13 infra.kuid.dev (NodeSpec / EndpointSpec /
#     LinkSpec / PartitionEndpointID) — nothing invented
#   the extended link form with eS-N spelling, in another order, renders the same objects
#   generation is deterministic and writes a header naming its input and the input's sha256
#   an SR Linux link interface that is not ethernet-S/N fails naming it; no file is written
#   the committed deploy/kuid/indices/inventory.yaml is the generation of lab/topology.clab.yml
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
FX="$HERE/fixtures"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# shellcheck source=../../../scripts/lib/inventory.sh
source "$ROOT/scripts/lib/inventory.sh"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

inventory::render "$FX/topology.clab.yml" fixture >"$TMP/short.yaml" 2>"$TMP/err" || fail "render fixture" "$(cat "$TMP/err")"

# check <label> <python assertion body over `docs`>
check() {
  local label="$1" body="$2" out
  if out="$(python3 - "$TMP/short.yaml" <<PY 2>&1
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
$body
PY
)"; then pass "$label"; else fail "$label" "$out"; fi
}

check "fixture lab: 4 Node (no client), 10 Endpoint, 4 Link, all infra.kuid.dev/v1alpha1 in kuid-system" '
from collections import Counter
c = Counter(d["kind"] for d in docs)
assert c == {"Node": 4, "Endpoint": 10, "Link": 4}, c
assert all(d["apiVersion"] == "infra.kuid.dev/v1alpha1" and d["metadata"]["namespace"] == "kuid-system" for d in docs)
assert not any("client" in d["metadata"]["name"] for d in docs), "a client became infra"'

check "nodes: provider, platform type, version from the image tag, role from the label or the name" '
s = by[("Node", "spine02")]["spec"]
assert s["provider"] == "srl.nokia.sdcio.dev" and s["platformType"] == "ixr-d3l" and s["version"] == "25.7.1", s
assert s["labels"]["agentic-netops.io/role"] == "spine" and s["partition"] == "fabric01" and s["site"] == "agentic-netops-fabric", s
assert by[("Node", "leaf01")]["spec"]["platformType"] == "ixr-d2l"'

check "endpoints: ethernet-S/N -> moduleBay S, port N; fabric vs access role" '
e = by[("Endpoint", "leaf01-ethernet-1-49")]["spec"]
assert (e["moduleBay"], e["port"], e["endpoint"], e["name"], e["node"]) == (1, 49, 0, "ethernet-1/49", "leaf01"), e
assert e["labels"]["agentic-netops.io/endpoint-role"] == "fabric"
a = by[("Endpoint", "leaf02-ethernet-1-1")]["spec"]
assert a["labels"]["agentic-netops.io/endpoint-role"] == "access", a
assert ("Endpoint", "spine02-ethernet-1-2") in by'

check "links: one per SR Linux pair, both ends as PartitionEndpointID" '
l = by[("Link", "leaf01-ethernet-1-49.spine01-ethernet-1-1")]["spec"]
assert [(x["node"], x["port"]) for x in l["endpoints"]] == [("leaf01", 49), ("spine01", 1)], l
assert ("Link", "leaf02-ethernet-1-50.spine02-ethernet-1-2") in by'

# kuid v0.0.13 field names (apis/infra/v1alpha1/{node,endpoint,link}_types.go, apis/id/v1alpha1/id.go,
# apis/common/v1alpha1/labels.go).
check "every spec field is a kuid v0.0.13 infra.kuid.dev field" '
ID = {"partition", "region", "site", "node"}
EP = ID | {"moduleBay", "module", "port", "adaptor", "endpoint", "name"}
ALLOWED = {"Node": ID | {"rack", "position", "location", "provider", "platformType", "version", "labels"},
           "Endpoint": EP | {"labels", "speed", "vlanTagging"},
           "Link": {"internal", "endpoints", "labels", "bfd", "ospf", "isis", "bgp"}}
REQUIRED = {"Node": ID | {"provider", "platformType"}, "Endpoint": ID | {"port", "endpoint"}, "Link": {"endpoints"}}
for d in docs:
    k, s = d["kind"], d["spec"]
    assert set(s) <= ALLOWED[k], (k, set(s) - ALLOWED[k])
    assert REQUIRED[k] <= set(s), (k, REQUIRED[k] - set(s))
    for e in s.get("endpoints", []):
        assert set(e) <= EP and {"partition", "region", "site", "node", "port", "endpoint"} <= set(e), e'

inventory::render "$FX/topology-extended.clab.yml" fixture >"$TMP/ext.yaml" 2>"$TMP/err" || fail "render extended fixture" "$(cat "$TMP/err")"
if diff <(sed 1,4d "$TMP/short.yaml") <(sed 1,4d "$TMP/ext.yaml") >/dev/null; then
  pass "extended link form, eS-N spelling, other order: the same objects"
else fail "extended form differs" "$(diff <(sed 1,4d "$TMP/short.yaml") <(sed 1,4d "$TMP/ext.yaml") | head -20)"; fi

inventory::generate "$FX/topology.clab.yml" "$TMP/out/inventory.yaml" 2>/dev/null
sum="$(sha256sum "$FX/topology.clab.yml" | cut -d' ' -f1)"
rel="tests/unit/inventory/fixtures/topology.clab.yml"   # generate names a repository file by its relative path
if cmp -s <(inventory::render "$FX/topology.clab.yml" "$rel") "$TMP/out/inventory.yaml" \
   && head -n1 "$TMP/out/inventory.yaml" | grep -qxF "# provenance: source=first-party version=v0.1.0" \
   && sed -n 2p "$TMP/out/inventory.yaml" | grep -qF "GENERATED by scripts/lib/inventory.sh from $rel (sha256:$sum)"; then
  pass "deterministic generation with a header naming the input and its sha256"
else fail "generate header/determinism" "$(head -n3 "$TMP/out/inventory.yaml")"; fi

sed 's#"leaf01:ethernet-1/49"#"leaf01:mgmt0"#' "$FX/topology.clab.yml" >"$TMP/bad.clab.yml"
out="$(inventory::generate "$TMP/bad.clab.yml" "$TMP/bad/inventory.yaml" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF "leaf01:mgmt0 is not an SR Linux ethernet-S/N" <<<"$out" && [[ ! -e "$TMP/bad/inventory.yaml" ]]; then
  pass "a non-ethernet SR Linux link interface fails naming it; no file written"
else fail "bad interface (rc=$rc)" "$out"; fi

if [[ -f "$ROOT/lab/topology.clab.yml" ]]; then
  if diff <(inventory::render "$ROOT/lab/topology.clab.yml" lab/topology.clab.yml) "$ROOT/deploy/kuid/indices/inventory.yaml" >/dev/null; then
    pass "deploy/kuid/indices/inventory.yaml is the generation of lab/topology.clab.yml"
  else fail "deploy/kuid/indices/inventory.yaml is stale: re-run scripts/lib/inventory.sh" \
    "$(diff <(inventory::render "$ROOT/lab/topology.clab.yml" lab/topology.clab.yml) "$ROOT/deploy/kuid/indices/inventory.yaml" | head -10)"; fi
else
  fail "lab/topology.clab.yml is missing: the committed inventory has no input"
fi

echo "inventory_test: $([[ $fails -eq 0 ]] && echo PASS || echo "FAIL ($fails)")"
[[ "$fails" -eq 0 ]]
