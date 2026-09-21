#!/usr/bin/env bash
# inventory.sh — the allocation authority's infra inventory, generated from the containerlab
# topology (T038; FR-012).
#
# Reads lab/topology.clab.yml and writes deploy/kuid/indices/inventory.yaml: kuid v0.0.13
# infra.kuid.dev/v1alpha1 objects in kuid-system —
#   Node      one per SR Linux node (kind nokia_srlinux / srl): provider srl.nokia.sdcio.dev,
#             platformType = the containerlab type (ixr-d3l / ixr-d2l), version = the image tag;
#             spec.labels carry the fabric and the role (the node's agentic-netops.io/role
#             label, else its name prefix spine/leaf)
#   Endpoint  one per SR Linux interface that appears in a link: port N and moduleBay S of
#             ethernet-S/N, endpoint 0, name ethernet-S/N; an interface facing a Linux client
#             is labelled role access (its far end is not infra), a fabric interface role fabric
#   Link      one per link between two SR Linux nodes, its two endpoints by PartitionEndpointID
# Linux clients are not infra Nodes: they are the service endpoints, not fabric.
# Every endpoint and node is keyed partition fabric01, region lab, site <topology name>.
# Output is deterministic (sorted); the file's header names its input and that input's sha256,
# and tests/unit/inventory checks the committed file is the generation of the committed topology.
# Interface names are accepted in both containerlab spellings (ethernet-1/49 and e1-49), and
# links in both the short (`endpoints: ["a:x", "b:y"]`) and extended
# (`endpoints: [{node, interface}, …]`) forms. Parsing uses python3 + PyYAML.
#
#   inventory::generate <topology> <out>      write the inventory manifest
#   inventory::render <topology> [<label>]    print it (<label> is the input path in the header)
#
# The first-party allocation authority's seed pools (T179; FR-104, FR-012, AD-33, AD-74) are
# generated from the SAME seeds as kuid's — deploy/kuid/indices/{ipam,as,vlan,genid}.yaml — so the
# two authorities' seeds cannot drift: every IdentifierPool (fabric.agentic-netops.io/v1alpha1, in
# agentic-netops-allocation) has the name, the range or prefix and the labels of its kuid index.
#   IPIndex (one prefix)  → type ip,   prefix          → deploy/allocation/pools/ipam.yaml
#   ASIndex               → type asn,  range min–max   → deploy/allocation/pools/as.yaml
#   VLANIndex             → type vlan, range min–max   → deploy/allocation/pools/vlan.yaml
#   GENIDIndex            → type vni,  range min–max   → deploy/allocation/pools/vni.yaml
# Each file's header names its input and that input's sha256 (no timestamp); tests/unit/inventory
# checks the committed pools are this generation.
#   inventory::generate_pools <indices-dir> <out-dir>   write the four pool files
#   inventory::render_pools <indices-dir> <ipam|as|vlan|vni> [<label-dir>]   print one of them
#
# Usage (as a script): inventory.sh [--topology <file>] [--out <file>]
#                      inventory.sh --pools [--indices <dir>] [--pools-out <dir>]

[[ -n "${__AGENTIC_NETOPS_INVENTORY_SH:-}" ]] && return 0
__AGENTIC_NETOPS_INVENTORY_SH=1

INVENTORY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
INVENTORY_PARTITION="fabric01"
INVENTORY_REGION="lab"
INVENTORY_NAMESPACE="kuid-system"
INVENTORY_POOLS_NAMESPACE="agentic-netops-allocation"
INVENTORY_POOL_FILES=(ipam as vlan vni)

inventory::render() {
  local topo="${1:?usage: inventory::render <topology> [<label>]}" label="${2:-$1}"
  [[ -f "$topo" ]] || { echo "inventory: topology $topo not found" >&2; return 1; }
  python3 - "$topo" "$label" "$INVENTORY_PARTITION" "$INVENTORY_REGION" "$INVENTORY_NAMESPACE" <<'PY'
import hashlib, re, sys
import yaml

topo_path, label, partition, region, namespace = sys.argv[1:6]
raw = open(topo_path, "rb").read()
topo = yaml.safe_load(raw) or {}
site = topo.get("name") or sys.exit("inventory: the topology has no name")
t = topo.get("topology") or {}
kinds = t.get("kinds") or {}
nodes = t.get("nodes") or {}
SRL = {"nokia_srlinux", "srl"}

def die(msg):
    sys.exit(f"inventory: {msg}")

def iface(name, node):
    m = re.fullmatch(r"(?:ethernet-(\d+)/(\d+)|e(\d+)-(\d+))", name)
    if not m:
        die(f"{node}:{name} is not an SR Linux ethernet-S/N (or eS-N) interface")
    slot, port = (m.group(1), m.group(2)) if m.group(1) else (m.group(3), m.group(4))
    return int(slot), int(port)

srl = {}
for name, n in sorted(nodes.items()):
    n = n or {}
    kind = n.get("kind") or (t.get("defaults") or {}).get("kind")
    if kind not in SRL:
        continue
    image = n.get("image") or (kinds.get(kind) or {}).get("image") or ""
    m = re.search(r":([0-9][^@:/]*)(?:@|$)", image)
    if not m:
        die(f"{name}: cannot read the SR Linux version from image '{image}'")
    role = (n.get("labels") or {}).get("agentic-netops.io/role") or re.sub(r"\d+$", "", name)
    if role not in ("spine", "leaf"):
        die(f"{name}: role '{role}' is neither spine nor leaf")
    ntype = n.get("type") or die(f"{name}: no containerlab type (the platform)")
    srl[name] = {"type": ntype, "version": m.group(1), "role": role}
if not srl:
    die("the topology has no SR Linux node")

def ends(link):
    eps = link.get("endpoints") or []
    out = []
    for e in eps:
        if isinstance(e, str):
            node, _, ifn = e.partition(":")
        else:
            node, ifn = e.get("node"), e.get("interface")
        if not node or not ifn:
            die(f"malformed link endpoint {e!r}")
        out.append((node, ifn))
    if len(out) != 2:
        die(f"a link must have two endpoints, got {eps!r}")
    return out

endpoints, links = {}, []
def ep_name(node, slot, port):
    return f"{node}-ethernet-{slot}-{port}"
def ep_id(node, slot, port):
    return {"partition": partition, "region": region, "site": site, "node": node,
            "moduleBay": slot, "port": port, "endpoint": 0, "name": f"ethernet-{slot}/{port}"}

for link in t.get("links") or []:
    (a, ai), (b, bi) = ends(link)
    sides = [(a, ai, b), (b, bi, a)]
    for node, ifn, far in sides:
        if node not in srl:
            continue
        slot, port = iface(ifn, node)
        role = "fabric" if far in srl else "access"
        key = ep_name(node, slot, port)
        if key in endpoints:
            die(f"{node}:{ifn} appears in two links")
        endpoints[key] = (node, slot, port, role)
    if a in srl and b in srl:
        pa, pb = sorted([(a,) + iface(ai, a), (b,) + iface(bi, b)])
        links.append((pa, pb))

docs = []
LAB = {"agentic-netops.io/fabric": partition}
for name, n in sorted(srl.items()):
    docs.append({"apiVersion": "infra.kuid.dev/v1alpha1", "kind": "Node",
                 "metadata": {"name": name, "namespace": namespace},
                 "spec": {"partition": partition, "region": region, "site": site, "node": name,
                          "provider": "srl.nokia.sdcio.dev", "platformType": n["type"], "version": n["version"],
                          "labels": dict(LAB, **{"agentic-netops.io/role": n["role"]})}})
for key in sorted(endpoints):
    node, slot, port, role = endpoints[key]
    spec = ep_id(node, slot, port)
    spec["labels"] = dict(LAB, **{"agentic-netops.io/endpoint-role": role})
    docs.append({"apiVersion": "infra.kuid.dev/v1alpha1", "kind": "Endpoint",
                 "metadata": {"name": key, "namespace": namespace}, "spec": spec})
for pa, pb in sorted(links):
    docs.append({"apiVersion": "infra.kuid.dev/v1alpha1", "kind": "Link",
                 "metadata": {"name": f"{ep_name(*pa)}.{ep_name(*pb)}", "namespace": namespace},
                 "spec": {"endpoints": [ep_id(*pa), ep_id(*pb)], "labels": dict(LAB)}})

print("# provenance: source=first-party version=v0.1.0")
print(f"# GENERATED by scripts/lib/inventory.sh from {label} (sha256:{hashlib.sha256(raw).hexdigest()}) — do not edit;")
print("# re-run `scripts/lib/inventory.sh` after changing the topology. kuid v0.0.13 infra.kuid.dev/v1alpha1:")
print(f"# {sum(d['kind'] == 'Node' for d in docs)} Node, {sum(d['kind'] == 'Endpoint' for d in docs)} Endpoint, "
      f"{sum(d['kind'] == 'Link' for d in docs)} Link (T038; FR-012).")
print(yaml.safe_dump_all(docs, sort_keys=False, default_flow_style=False, explicit_start=True), end="")
PY
}

inventory::generate() {
  local topo="${1:?usage: inventory::generate <topology> <out>}" out="${2:?usage: inventory::generate <topology> <out>}" label tmp
  label="$topo"
  [[ "$topo" == "$INVENTORY_ROOT/"* ]] && label="${topo#"$INVENTORY_ROOT/"}"
  tmp="$(mktemp "${TMPDIR:-/tmp}/inventory.XXXXXX")"
  if ! inventory::render "$topo" "$label" >"$tmp"; then
    rm -f "$tmp"; return 1
  fi
  mkdir -p "$(dirname "$out")"
  mv "$tmp" "$out"
  chmod 0644 "$out"
  echo "inventory: wrote $out from $label" >&2
}

# inventory::render_pools <indices-dir> <ipam|as|vlan|vni> [<label-dir>] — one pool file on stdout.
inventory::render_pools() {
  local dir="${1:?usage: inventory::render_pools <indices-dir> <ipam|as|vlan|vni> [<label-dir>]}" which="${2:?}" label="${3:-$1}"
  local src
  case "$which" in
    ipam) src=ipam.yaml ;; as) src=as.yaml ;; vlan) src=vlan.yaml ;; vni) src=genid.yaml ;;
    *) echo "inventory: unknown pool file '$which' (ipam | as | vlan | vni)" >&2; return 1 ;;
  esac
  [[ -f "$dir/$src" ]] || { echo "inventory: kuid index seed $dir/$src not found" >&2; return 1; }
  python3 - "$dir/$src" "${label%/}/$src" "$which" "$INVENTORY_POOLS_NAMESPACE" <<'PY'
import hashlib, sys
import yaml

path, label, which, namespace = sys.argv[1:5]
raw = open(path, "rb").read()
docs = [d for d in yaml.safe_load_all(raw) if d]

def die(msg):
    sys.exit(f"inventory: {label}: {msg}")

KINDS = {"ipam": ("IPIndex", "ip"), "as": ("ASIndex", "asn"), "vlan": ("VLANIndex", "vlan"), "vni": ("GENIDIndex", "vni")}
want_kind, ptype = KINDS[which]
pools, summary = [], []
for d in docs:
    kind, name = d.get("kind"), (d.get("metadata") or {}).get("name")
    if kind != want_kind:
        die(f"holds a {kind}, expected only {want_kind}")
    if not name:
        die(f"a {kind} has no metadata.name")
    spec = d.get("spec") or {}
    if ptype == "ip":
        prefixes = spec.get("prefixes") or []
        if len(prefixes) != 1 or not prefixes[0].get("prefix"):
            die(f"IPIndex {name} must carry exactly one prefix (an IdentifierPool has one), got {prefixes!r}")
        labels = dict(prefixes[0].get("labels") or {})
        pspec = {"type": ptype, "prefix": str(prefixes[0]["prefix"])}
        summary.append(f"{name} {ptype} {pspec['prefix']}")
    else:
        lo, hi = spec.get("minID"), spec.get("maxID")
        if not isinstance(lo, int) or not isinstance(hi, int) or lo > hi:
            die(f"{kind} {name} has no integer minID <= maxID (got {lo!r}, {hi!r})")
        labels = dict(spec.get("labels") or {})
        pspec = {"type": ptype, "range": {"start": lo, "end": hi}}
        summary.append(f"{name} {ptype} {lo}–{hi}")
    md = {"name": name, "namespace": namespace}
    if labels:
        md["labels"] = dict(sorted(labels.items()))
    pools.append({"apiVersion": "fabric.agentic-netops.io/v1alpha1", "kind": "IdentifierPool", "metadata": md, "spec": pspec})
if not pools:
    die(f"holds no {want_kind}")

print("# provenance: source=first-party version=v0.1.0")
print(f"# GENERATED by scripts/lib/inventory.sh --pools from {label} (sha256:{hashlib.sha256(raw).hexdigest()}) — do not edit;")
print("# re-run `scripts/lib/inventory.sh --pools` after changing the kuid index seeds. The first-party allocation")
print("# authority's seed pools carry exactly the kuid indices' names, ranges and labels, so the two authorities'")
print("# seeds cannot drift (T179; FR-104, FR-012, AD-33). fabric.agentic-netops.io/v1alpha1 IdentifierPool:")
for line in summary:
    print(f"#   {line}")
print(yaml.safe_dump_all(pools, sort_keys=False, default_flow_style=False, explicit_start=True, allow_unicode=True), end="")
PY
}

# inventory::generate_pools <indices-dir> <out-dir> — write ipam.yaml, as.yaml, vlan.yaml, vni.yaml.
inventory::generate_pools() {
  local dir="${1:?usage: inventory::generate_pools <indices-dir> <out-dir>}" out="${2:?usage: inventory::generate_pools <indices-dir> <out-dir>}"
  local label="$dir" which tmp
  [[ "$dir" == "$INVENTORY_ROOT/"* ]] && label="${dir#"$INVENTORY_ROOT/"}"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/pools.XXXXXX")"
  for which in "${INVENTORY_POOL_FILES[@]}"; do
    if ! inventory::render_pools "$dir" "$which" "$label" >"$tmp/$which.yaml"; then
      rm -rf "$tmp"; return 1
    fi
  done
  mkdir -p "$out"
  for which in "${INVENTORY_POOL_FILES[@]}"; do
    mv "$tmp/$which.yaml" "$out/$which.yaml"
    chmod 0644 "$out/$which.yaml"
  done
  rm -rf "$tmp"
  echo "inventory: wrote ${INVENTORY_POOL_FILES[*]/%/.yaml} under $out from $label" >&2
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  topo="$INVENTORY_ROOT/lab/topology.clab.yml"
  out="$INVENTORY_ROOT/deploy/kuid/indices/inventory.yaml"
  pools=false
  indices="$INVENTORY_ROOT/deploy/kuid/indices"
  pools_out="$INVENTORY_ROOT/deploy/allocation/pools"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --topology) topo="${2:?}"; shift 2 ;;
      --out) out="${2:?}"; shift 2 ;;
      --pools) pools=true; shift ;;
      --indices) indices="${2:?}"; shift 2 ;;
      --pools-out) pools_out="${2:?}"; shift 2 ;;
      -h|--help) sed -n '2,/^\[\[ -n/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
      *) echo "inventory: unknown argument '$1'" >&2; exit 2 ;;
    esac
  done
  if [[ "$pools" == true ]]; then
    inventory::generate_pools "$indices" "$pools_out"
  else
    inventory::generate "$topo" "$out"
  fi
fi
