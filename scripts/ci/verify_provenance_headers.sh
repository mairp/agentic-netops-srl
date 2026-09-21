#!/usr/bin/env bash
# verify_provenance_headers.sh — `make verify-provenance-headers` (T025; SC-017(b),
# FR-094, NFR-003; quickstart §23): every vendored asset carries a provenance
# header naming its upstream source, its pinned version and its digest.
#
# Vendored assets — every file under:
#   deploy/cert-manager/  deploy/kuid/  deploy/sdc/     (T035: upstream install artefacts)
#   deploy/observability/grafana/dashboards/            (T132: dashboards)
#   any vendor/ or vendored/ directory under deploy/, lab/, docs/, ui/public/
# except .gitkeep, kustomization.y(a)ml and README.md (first-party glue).
#
# The header:
#   text files   a line within the first 20 carrying
#                  provenance: source=<url|first-party> version=<pinned version> digest=sha256:<64 hex>
#                behind whatever comment marker the format has (#, //, <!-- -->, /* */)
#   *.json       a top-level "provenance" object {"source", "version", "digest"}
#                (JSON has no comments)
#   binary       a sidecar <file>.provenance holding the text-file line
# `digest` may be omitted only when source=first-party (an asset authored here in
# a vendored location has no upstream digest; it still names its version). A
# version of `latest`, a branch-like version (main, master, HEAD) or a malformed
# digest fails.
#
# Usage: verify_provenance_headers.sh [--root <dir>]      Exit: 0 ok, 1 findings, 2 usage.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$(cd -- "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "verify_provenance_headers: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

exec python3 - "$ROOT" <<'PY'
import json, os, re, sys

root = sys.argv[1]
ROOTS = ("deploy/cert-manager/", "deploy/kuid/", "deploy/sdc/", "deploy/observability/grafana/dashboards/")
VENDOR_UNDER = ("deploy/", "lab/", "docs/", "ui/public/")
EXEMPT = {".gitkeep", "kustomization.yaml", "kustomization.yml", "README.md"}
HEADER = re.compile(r"provenance:\s*(.*)")
FIELD = re.compile(r"\b(source|version|digest)=(\S+)")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
FLOATING = {"latest", "main", "master", "head", "stable", "edge", "nightly"}

def vendored(rel):
    if rel.startswith(ROOTS):
        return True
    parts = rel.split("/")
    return rel.startswith(VENDOR_UNDER) and any(p in ("vendor", "vendored") for p in parts[:-1])

assets = []
for base, dirs, names in os.walk(root):
    dirs[:] = [d for d in dirs if d not in ("node_modules", ".git")]
    for n in names:
        rel = os.path.relpath(os.path.join(base, n), root)
        if n in EXEMPT or n.endswith(".provenance") or not vendored(rel):
            continue
        assets.append(rel)
assets.sort()

fails = []
def judge(rel, fields, where):
    src, ver, dig = fields.get("source"), fields.get("version"), fields.get("digest")
    bad = []
    if not src:
        bad.append("no source")
    if not ver:
        bad.append("no version")
    elif ver.strip("\"'").lower() in FLOATING:
        bad.append(f"floating version '{ver}'")
    if src != "first-party":
        if not dig:
            bad.append("no digest")
        elif not DIGEST.match(dig.strip("\"'")):
            bad.append(f"malformed digest '{dig}' (want sha256:<64 hex>)")
    if bad:
        fails.append(f"FAIL {rel}: provenance header ({where}) incomplete: {', '.join(bad)}")

for rel in assets:
    p = os.path.join(root, rel)
    raw = open(p, "rb").read()
    if rel.endswith(".json"):
        try:
            doc = json.loads(raw)
        except ValueError as e:
            fails.append(f"FAIL {rel}: not valid JSON ({e}); cannot carry a provenance object")
            continue
        prov = doc.get("provenance") if isinstance(doc, dict) else None
        if not isinstance(prov, dict):
            fails.append(f"FAIL {rel}: no provenance header (top-level \"provenance\": {{source, version, digest}})")
            continue
        judge(rel, {k: str(v) for k, v in prov.items() if k in ("source", "version", "digest")}, "\"provenance\" object")
        continue
    if b"\x00" in raw[:8192]:
        side = p + ".provenance"
        if not os.path.isfile(side):
            fails.append(f"FAIL {rel}: binary asset without a {os.path.basename(rel)}.provenance sidecar")
            continue
        head, where = open(side, encoding="utf-8", errors="replace").read().splitlines()[:20], "sidecar"
    else:
        head, where = raw.decode("utf-8", "replace").splitlines()[:20], "header"
    line = next((l for l in head if HEADER.search(l)), None)
    if line is None:
        fails.append(f"FAIL {rel}: no provenance header in its first 20 lines "
                     "(provenance: source=<url> version=<version> digest=sha256:<hex>)")
        continue
    judge(rel, dict(FIELD.findall(HEADER.search(line).group(1))), where)

for f in fails:
    print(f)
if fails:
    print(f"verify-provenance-headers: FAIL {len(fails)} of {len(assets)} vendored asset(s) under {root}")
    sys.exit(1)
print(f"verify-provenance-headers: PASS {len(assets)} vendored asset(s) under {root}")
PY
