#!/usr/bin/env bash
# verify_upstream_artefacts.sh — `make verify-upstream-artefacts` (T035; FR-098, FR-009, NFR-003).
#
# FR-098: no CRD or API service may be installed into an upstream project's API group unless
# it is that project's own pinned, unmodified artefact. Checks, each failing NAMING THE FILE
# (`FAIL [<check>] <file>[:<line>]: …`):
#
#   upstream-origin   every CustomResourceDefinition and APIService whose group is an
#                     upstream group — cert-manager.io, acme.cert-manager.io (any
#                     *.cert-manager.io), *.sdcio.dev, *.kuid.dev — lives in a VENDORED file
#                     (deploy/{cert-manager,sdc,kuid}/upstream/) that passes `vendored` below
#                     AND belongs to the project that owns the group (sdcio.dev → deploy/sdc,
#                     kuid.dev → deploy/kuid, cert-manager.io → deploy/cert-manager). Anywhere
#                     else in this repository — config/crd, a first-party manifest, an example —
#                     it is a first-party stand-in for an upstream API and fails.
#   go-group          no first-party Go package declares `+groupName=<upstream group>` (the
#                     marker a CRD generator turns into a look-alike API).
#   vendored          every file under deploy/{cert-manager,sdc,kuid}/upstream/ carries the
#                     header scripts/lib/fetch_upstream.sh writes —
#                       # provenance: source=<url> version=<v> commit=<sha> digest=sha256:<hex>
#                       …
#                       # --- end of provenance header ---
#                     within its first 20 lines; the source is that project's own release or
#                     tag (github.com/cert-manager/cert-manager/releases/download/<v>/,
#                     raw.githubusercontent.com/sdcio/config-server/<commit>/,
#                     raw.githubusercontent.com/kuidio/kuid/<commit>/); version and commit
#                     are the ones versions.lock.yaml pins; and the sha256 of the bytes after
#                     the end marker still equals the recorded digest (the file is unmodified).
#   substitute-shape  nothing of the first-party allocation authority — every file under
#                     deploy/allocation/, config/crd/conditional/, config/rbac/allocation/ and
#                     config/rbac/claims/first-party/ — declares an object in any *.kuid.dev
#                     group (its apiVersion, a CRD's spec.group or an APIService's spec.group),
#                     an object or CRD whose kind is named like a kuid kind (IPIndex, ASIndex,
#                     VLANIndex, GENIDIndex, IPClaim, …, IPEntry, … — any
#                     (IP|AS|VLAN|GENID|EXTCOMM)(Index|Claim|Entry)), or an RBAC rule on a
#                     *.kuid.dev group: the substitute is never in, and never shaped to imitate,
#                     an upstream API group (FR-098, FR-104; data-model.md §23)
#   image-pin         every `images:` entry of deploy/{cert-manager,sdc,kuid}/kustomization.yaml
#                     is `<name>:<newTag>` equal to a `pinned:` value of versions.lock.yaml, and
#                     no kustomization there pulls a remote resource (http[s]:// or github.com/).
#
# Scope: every file under --root except what is not this repository's code — the upstream
# reference checkouts config-server/, data-server/, kuid/, sdcio-docs/ (at the root), specs/,
# .specstride/, .specify/, .mixture-of-loops/, prompts/, bin/, .evidence/, .git/, and any
# node_modules/, .venv/, dist/, __pycache__/, *_cache/ directory.
#
# Usage: verify_upstream_artefacts.sh [--root <dir>] [--lock <file>]
# Exit: 0 no finding; 1 findings; 2 usage or missing prerequisite.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$(cd -- "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
    --lock) LOCK="${2:?--lock needs a file}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "verify_upstream_artefacts: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[[ -n "$LOCK" ]] || LOCK="$ROOT/versions.lock.yaml"
command -v python3 >/dev/null || { echo "verify_upstream_artefacts: python3 is required" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "verify_upstream_artefacts: python3 PyYAML is required" >&2; exit 2; }
[[ -f "$LOCK" ]] || { echo "verify_upstream_artefacts: lock file $LOCK not found" >&2; exit 2; }

exec python3 - "$ROOT" "$LOCK" <<'PY'
import hashlib, os, re, sys
import yaml

root, lock_path = sys.argv[1], sys.argv[2]
lock = yaml.safe_load(open(lock_path)) or {}
findings = []
def fail(check, rel, line, msg):
    findings.append(f"FAIL [{check}] {rel}{':' + str(line) if line else ''}: {msg}")

def dig(d, path):
    for k in path.split("."):
        if not isinstance(d, dict) or k not in d:
            return None
        d = d[k]
    return d

# project -> (owner of groups, source prefix template, version, commit)
cm_ver = str(dig(lock, "platform.certManager.version") or "")
cm_tag = cm_ver if cm_ver.startswith("v") else "v" + cm_ver
cs = dig(lock, "compatibilitySet.deviceConfiguration.configServer") or {}
kd = dig(lock, "compatibilitySet.allocationAuthorityRelease.kuid") or {}
PROJECTS = {
    "cert-manager": {"groups": re.compile(r"(^|\.)cert-manager\.io$"),
                     "source": f"https://github.com/cert-manager/cert-manager/releases/download/{cm_tag}/",
                     "version": cm_tag, "commit": None},
    "sdc": {"groups": re.compile(r"(^|\.)sdcio\.dev$"),
            "source": f"https://raw.githubusercontent.com/sdcio/config-server/{cs.get('commit', '')}/",
            "version": cs.get("tag"), "commit": cs.get("commit")},
    "kuid": {"groups": re.compile(r"(^|\.)kuid\.dev$"),
             "source": f"https://raw.githubusercontent.com/kuidio/kuid/{kd.get('commit', '')}/",
             "version": kd.get("tag"), "commit": kd.get("commit")},
}
def owner_of(group):
    for p, spec in PROJECTS.items():
        if spec["groups"].search(group or ""):
            return p
    return None

SKIP_TOP = {"specs", ".specstride", ".specify", ".mixture-of-loops", "prompts", "config-server",
            "data-server", "kuid", "sdcio-docs", "bin", ".evidence", ".git"}
SKIP_ANY = {"node_modules", ".venv", "dist", "__pycache__", ".git"}
files = []
for base, dirs, names in os.walk(root):
    relbase = os.path.relpath(base, root)
    if relbase == ".":
        dirs[:] = [d for d in dirs if d not in SKIP_TOP]
    dirs[:] = [d for d in dirs if d not in SKIP_ANY and not d.endswith("_cache")]
    for n in names:
        files.append(os.path.normpath(os.path.join(relbase, n)))
files.sort()

# ------------------------------------------------------------------ vendored
HEADER_END = "# --- end of provenance header ---"
FIELD = re.compile(r"\b(source|version|commit|digest)=(\S+)")
def vendored_project(rel):
    m = re.match(r"^deploy/(cert-manager|sdc|kuid)/upstream/", rel)
    return m.group(1) if m else None

vendored_ok = {}
for rel in files:
    proj = vendored_project(rel)
    if not proj:
        continue
    raw = open(os.path.join(root, rel), "rb").read()
    lines = raw.split(b"\n")
    end = next((i for i, l in enumerate(lines[:20]) if l.decode("utf-8", "replace").rstrip("\r") == HEADER_END), None)
    prov = next((l.decode("utf-8", "replace") for l in lines[:20] if b"provenance:" in l), None)
    if end is None or prov is None:
        fail("vendored", rel, 1, "no provenance header (a `# provenance: source=… version=… commit=… digest=sha256:…` "
             f"line and `{HEADER_END}` within the first 20 lines) — vendor it with scripts/lib/fetch_upstream.sh")
        continue
    f = dict(FIELD.findall(prov))
    spec = PROJECTS[proj]
    bad = []
    src = f.get("source", "")
    if not src.startswith(spec["source"]) or spec["source"].endswith("//"):
        bad.append(f"source '{src or '-'}' is not {spec['source']}… (the project's own pinned release/tag)")
    if f.get("version") != spec["version"]:
        bad.append(f"version '{f.get('version', '-')}' is not the pinned {spec['version']}")
    if spec["commit"] and f.get("commit") != spec["commit"]:
        bad.append(f"commit '{f.get('commit', '-')}' is not the pinned {spec['commit']}")
    if not re.fullmatch(r"[0-9a-f]{40}", f.get("commit", "")):
        bad.append("no commit=<40 hex>")
    body = b"\n".join(lines[end + 1:])
    got = "sha256:" + hashlib.sha256(body).hexdigest()
    if f.get("digest") != got:
        bad.append(f"content changed: sha256 of the upstream bytes is {got}, the header records {f.get('digest', '-')}")
    if bad:
        fail("vendored", rel, 1, "; ".join(bad))
    else:
        vendored_ok[rel] = proj

# ------------------------------------------------------------------ upstream-origin
def docs_of(rel):
    try:
        text = open(os.path.join(root, rel), encoding="utf-8").read()
    except (UnicodeDecodeError, OSError):
        return None, None
    try:
        return text, list(yaml.compose_all(text, Loader=getattr(yaml, "CSafeLoader", yaml.SafeLoader)))
    except yaml.YAMLError:
        return text, None

def scalar(n):
    return n.value if isinstance(n, yaml.ScalarNode) else None
def child(n, key):
    if isinstance(n, yaml.MappingNode):
        for k, v in n.value:
            if scalar(k) == key:
                return v
    return None

KIND_LINE = re.compile(r"^\s*kind:\s*[\"']?(CustomResourceDefinition|APIService)[\"']?\s*$", re.M)
GROUP_LINE = re.compile(r"^\s*group:\s*[\"']?([a-z0-9.-]+)[\"']?\s*$", re.M)
for rel in files:
    if not rel.endswith((".yaml", ".yml", ".json")):
        continue
    text, docs = docs_of(rel)
    if text is None or ("CustomResourceDefinition" not in text and "APIService" not in text):
        continue
    hits = []   # (line, kind, name, group)
    if docs is None:   # a template that does not parse: line scan
        if KIND_LINE.search(text):
            for m in GROUP_LINE.finditer(text):
                if owner_of(m.group(1)):
                    hits.append((text.count("\n", 0, m.start()) + 1, "CustomResourceDefinition/APIService", "?", m.group(1)))
    else:
        for d in docs:
            kind = scalar(child(d, "kind"))
            if kind not in ("CustomResourceDefinition", "APIService"):
                continue
            group = scalar(child(child(d, "spec"), "group"))
            name = scalar(child(child(d, "metadata"), "name")) or "?"
            if owner_of(group):
                hits.append((d.start_mark.line + 1, kind, name, group))
    for line, kind, name, group in hits:
        want = owner_of(group)
        have = vendored_ok.get(rel)
        if have == want:
            continue
        if vendored_project(rel) == want and rel not in vendored_ok:
            why = "it is in the vendored tree but its provenance header does not verify (see [vendored])"
        elif vendored_project(rel):
            why = f"it is vendored under deploy/{vendored_project(rel)}/ but the group belongs to deploy/{want}/"
        else:
            why = "it originates in this repository, not in the upstream project's pinned artefact"
        fail("upstream-origin", rel, line,
             f"{kind} {name} in upstream API group {group}: {why} (FR-098 — a first-party stand-in for an upstream API is forbidden)")

# ------------------------------------------------------------------ go-group
GROUPNAME = re.compile(r"\+groupName=([a-z0-9.-]+)")
for rel in files:
    if not rel.endswith(".go"):
        continue
    try:
        for i, l in enumerate(open(os.path.join(root, rel), encoding="utf-8", errors="replace"), 1):
            m = GROUPNAME.search(l)
            if m and owner_of(m.group(1)):
                fail("go-group", rel, i, f"first-party Go API declares upstream group {m.group(1)} (FR-098)")
    except OSError:
        pass

# ------------------------------------------------------------------ substitute-shape
SUBSTITUTE_ROOTS = ("deploy/allocation/", "config/crd/conditional/", "config/rbac/allocation/",
                    "config/rbac/claims/first-party/")
KUID_GROUP = re.compile(r"(^|\.)kuid\.dev$")
KUID_KIND = re.compile(r"^(IP|AS|VLAN|GENID|EXTCOMM)(Index|Claim|Entry)(List)?$", re.I)
def group_of_api_version(av):
    av = str(av or "")
    return av.split("/", 1)[0] if "/" in av else ""
for rel in files:
    if not rel.startswith(SUBSTITUTE_ROOTS) or not rel.endswith((".yaml", ".yml", ".json")):
        continue
    try:
        text = open(os.path.join(root, rel), encoding="utf-8").read()
        docs = list(yaml.compose_all(text, Loader=getattr(yaml, "CSafeLoader", yaml.SafeLoader)))
    except (UnicodeDecodeError, OSError, yaml.YAMLError) as e:
        fail("substitute-shape", rel, None, f"cannot be parsed, so it cannot be shown free of *.kuid.dev objects: {e}")
        continue
    for d in docs:
        if not isinstance(d, yaml.MappingNode):
            continue
        line = d.start_mark.line + 1
        kind = scalar(child(d, "kind")) or ""
        name = scalar(child(child(d, "metadata"), "name")) or "?"
        av_group = group_of_api_version(scalar(child(d, "apiVersion")))
        if KUID_GROUP.search(av_group):
            fail("substitute-shape", rel, line, f"{kind or 'object'} {name} is in the kuid API group {av_group} (FR-098)")
        if KUID_KIND.match(kind):
            fail("substitute-shape", rel, line, f"{kind} {name} is named like a kuid kind (FR-098: the substitute never imitates kuid)")
        if kind in ("CustomResourceDefinition", "APIService"):
            spec = child(d, "spec")
            g = scalar(child(spec, "group")) or ""
            if KUID_GROUP.search(g):
                fail("substitute-shape", rel, line, f"{kind} {name} serves the kuid API group {g} (FR-098)")
            for key in ("kind", "listKind", "singular", "plural"):
                v = scalar(child(child(spec, "names"), key)) or ""
                if KUID_KIND.match(v) or re.match(r"^(ip|as|vlan|genid|extcomm)(index|indices|indexes|claims?|entry|entries)$", v, re.I):
                    fail("substitute-shape", rel, line, f"{kind} {name} names.{key} '{v}' is named like a kuid kind (FR-098)")
        if kind in ("Role", "ClusterRole"):
            rules = child(d, "rules")
            for r in (rules.value if isinstance(rules, yaml.SequenceNode) else []):
                ag = child(r, "apiGroups")
                for g in (ag.value if isinstance(ag, yaml.SequenceNode) else []):
                    if KUID_GROUP.search(scalar(g) or ""):
                        fail("substitute-shape", rel, r.start_mark.line + 1,
                             f"{kind} {name} grants on the kuid API group {scalar(g)} — the substitute's identities touch only fabric.agentic-netops.io (FR-104)")

# ------------------------------------------------------------------ image-pin
pinned = set()
def collect(n):
    if isinstance(n, dict):
        for k, v in n.items():
            if k == "pinned" and isinstance(v, str):
                pinned.add(v)
            collect(v)
    elif isinstance(n, list):
        for x in n:
            collect(x)
collect(lock)
for proj in PROJECTS:
    rel = f"deploy/{proj}/kustomization.yaml"
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        if any(vendored_project(f) == proj for f in files):
            fail("image-pin", rel, None, "missing: the vendored upstream/ tree is applied through it")
        continue
    k = yaml.safe_load(open(p)) or {}
    for r in (k.get("resources") or []):
        if re.match(r"^(https?://|github\.com/|git@)", str(r)):
            fail("image-pin", rel, None, f"remote resource '{r}' — upstream artefacts are vendored, never fetched at apply time")
    for img in (k.get("images") or []):
        name = img.get("newName") or img.get("name")
        ref = f"{name}:{img.get('newTag')}" if img.get("newTag") else f"{name}@{img.get('digest')}"
        if ref not in pinned:
            fail("image-pin", rel, None, f"image '{ref}' is not a `pinned:` value of versions.lock.yaml")

for f in findings:
    print(f)
checked = len(vendored_ok) + sum(1 for f in findings if "[vendored]" in f)
if findings:
    print(f"verify-upstream-artefacts: FAIL {len(findings)} finding(s); {checked} vendored file(s) under {root}")
    sys.exit(1)
print(f"verify-upstream-artefacts: PASS {checked} vendored file(s) verified; no upstream-group CRD/APIService originates outside them under {root}")
PY
