#!/usr/bin/env bash
# verify_boundaries.sh — `make verify-boundaries` (T025; SC-017, SC-049, FR-049,
# FR-085, FR-094, NFR-003, FR-007, FR-108, FR-019, CR-008, FR-013; quickstart §23).
#
# Checks, each failing NAMING THE FILE (and line) — `FAIL [<check>] <file>:<line>: …`:
#
#   migration          SC-017(a)/FR-049: no proprietary vendor controller,
#                      orchestrator, controller product, fabric-automation product,
#                      element driver or retired system name (boundaries.denylist).
#   retired-service    FR-085: retired service names in documentation only in a
#                      labelled context (alias/migration/provenance/historical/retired).
#   placement          SC-017(c)/FR-007: no Compose file, no Compose invocation.
#   reference-artefact SC-017(b)/FR-094/NFR-003, the mechanical checks of quickstart §23:
#                      no raw.githubusercontent.com / github …/raw|releases/latest in a
#                      dashboard, panel or datasource (deploy/observability/, any
#                      dashboards/ dir) unless on a `provenance:` line; every Grafana
#                      plugin install (GF_INSTALL_PLUGINS / GF_PLUGINS_PREINSTALL)
#                      carries an explicit version; the topology generator is never
#                      invoked at `latest` or with its version omitted
#                      (--drawio-version <digits>); no `:latest` / `tag: latest`
#                      image under deploy/, config/, lab/, docker/ or in the lock file.
#                      (Provenance headers on vendored assets: verify_provenance_headers.sh.)
#   device-client      FR-108/SC-049: gnmic, gnmi_cli, sr_cli, sshpass, ssh to a
#                      management address (clab-*, an IPv4 literal, *mgmt*), or
#                      `docker exec … clab-…` invoked from any file outside tests/,
#                      testautomation/ and quoted command blocks of Markdown under
#                      docs/ and specs/ (Markdown elsewhere: its fenced blocks are
#                      scanned; comment lines are not invocations). The device metric
#                      collector's own configuration, deploy/observability/gnmic/, is
#                      a platform component (FR-089), not verification tooling.
#   credential-literal FR-019/CR-008: every manifest under deploy/ (*.yaml, *.yml,
#                      *.json) — a literal password, token, API key or device
#                      credential as a key's value (stringData, data, any spec), an
#                      env entry's `value`, inside a data/stringData blob, or an
#                      args/command argument. Accepted: secretKeyRef / valueFrom, a
#                      projected volume (never a literal), or a generator placeholder:
#                      ${VAR}, $(VAR), {{ … }}, <…>, __NAME__, or empty.
#   orchestration      FR-013 (orchestration.denylist): no CronJob or workflow /
#                      pipeline / job-engine kind, chart or image under deploy/,
#                      config/ or in versions.lock.yaml; and across first-party
#                      Role/ClusterRole (deploy/sdc/ — the device-configuration
#                      layer's vendored RBAC — excepted by path) only the provider's
#                      ServiceAccount is bound to a mutating verb on config.sdcio.dev.
#
# Scope: every file under --root except what is not this repository's code or is
# the allowed context of the lists (see boundaries.denylist's header): specs/,
# .specstride/, .specify/, .mixture-of-loops/, prompts/, config-server/,
# data-server/, kuid/, sdcio-docs/, bin/, .evidence/, .git/, any node_modules/,
# .venv/, dist/, __pycache__/, *_cache/ directory; this script, its deny-lists and
# tests/unit/verifyboundaries/ (the planted negative controls). Binary files and
# files over 4 MiB are skipped.
#
# Usage: verify_boundaries.sh [--root <dir>] [--denylist <file>] [--orchestration-denylist <file>]
# Exit: 0 no finding; 1 findings; 2 usage.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../.." && pwd)"
DENY="$HERE/boundaries.denylist"
ORCH="$HERE/orchestration.denylist"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$(cd -- "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
    --denylist) DENY="${2:?}"; shift 2 ;;
    --orchestration-denylist) ORCH="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "verify_boundaries: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
command -v python3 >/dev/null || { echo "verify_boundaries: python3 is required" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "verify_boundaries: python3 PyYAML is required" >&2; exit 2; }

exec python3 - "$ROOT" "$DENY" "$ORCH" <<'PY'
import base64, json, os, re, sys
import yaml

root, deny_file, orch_file = sys.argv[1:4]
findings = []
counts = {}

def finding(check, rel, line, msg):
    findings.append((check, rel, line, msg))

# ---------------------------------------------------------------- the tree
EXCL_TOP = {"specs", ".specstride", ".specify", ".mixture-of-loops", "prompts",
            "config-server", "data-server", "kuid", "sdcio-docs", "bin", ".evidence", ".git"}
EXCL_ANY = {"node_modules", ".venv", "dist", "__pycache__", ".pytest_cache", ".ruff_cache", ".mypy_cache"}
SELF = {"scripts/ci/verify_boundaries.sh", "scripts/ci/boundaries.denylist",
        "scripts/ci/orchestration.denylist"}
SELF_DIRS = ("tests/unit/verifyboundaries/",)

files = []
for base, dirs, names in os.walk(root):
    relbase = os.path.relpath(base, root)
    relbase = "" if relbase == "." else relbase + "/"
    dirs[:] = sorted(d for d in dirs
                     if d not in EXCL_ANY and not (relbase == "" and d in EXCL_TOP)
                     # containerlab's runtime lab directory (device-generated config, certs): git-ignored
                     and not (relbase == "lab/" and d.startswith("clab-")))
    for n in sorted(names):
        rel = relbase + n
        if rel in SELF or rel.startswith(SELF_DIRS):
            continue
        files.append(rel)

_text = {}
def text(rel):
    if rel not in _text:
        p = os.path.join(root, rel)
        try:
            if os.path.getsize(p) > 4 * 1024 * 1024:
                _text[rel] = None
            else:
                b = open(p, "rb").read()
                _text[rel] = None if b"\x00" in b[:8192] else b.decode("utf-8", "replace")
        except OSError:
            _text[rel] = None
    return _text[rel]

def lines(rel):
    t = text(rel)
    return [] if t is None else t.splitlines()

def is_md(rel):
    return rel.lower().endswith((".md", ".markdown"))

def fenced(rel):
    """(lineno, line) of the lines inside ``` / ~~~ fences of a Markdown file."""
    out, fence = [], None
    for i, l in enumerate(lines(rel), 1):
        s = l.lstrip()
        m = re.match(r"(`{3,}|~{3,})", s)
        if m:
            if fence is None:
                fence = m.group(1)[0] * len(m.group(1)); continue
            if s.startswith(fence):
                fence = None; continue
        if fence is not None:
            out.append((i, l))
    return out

COMMENT = re.compile(r"^\s*(#|//|/\*|\*|--\s)")

# ---------------------------------------------------------------- deny-lists
def load_denylist(path):
    out = {}
    for n, l in enumerate(open(path, encoding="utf-8"), 1):
        l = l.rstrip("\n")
        if not l.strip() or l.lstrip().startswith("#"):
            continue
        parts = l.split(None, 1)
        if len(parts) != 2:
            sys.exit(f"verify_boundaries: {path}:{n}: malformed line")
        out.setdefault(parts[0], []).append((parts[1].strip(), re.compile(parts[1].strip(), re.I)))
    return out

deny = load_denylist(deny_file)
orch = load_denylist(orch_file)

def any_of(entries):
    """One alternation over a category, so a clean line costs one search."""
    return re.compile("|".join(f"(?:{s})" for s, _ in entries), re.I) if entries else re.compile(r"(?!)")
ANY = {cat: any_of(v) for cat, v in deny.items()}

# ---------------------------------------------------------------- (a) migration
for rel in files:
    for i, l in enumerate(lines(rel), 1):
        if not ANY["migration"].search(l):
            continue
        for src, rx in deny.get("migration", []):
            if rx.search(l):
                finding("migration", rel, i, f"migration-boundary term /{src}/ (FR-049, SC-017a): {l.strip()[:120]}")
counts["migration"] = len(files)

# ---------------------------------------------------------------- FR-085 retired service names
LABEL = re.compile(r"alias|migration|provenance|historical|history|retired", re.I)
docs = [f for f in files if is_md(f) or f.startswith("docs/")]
for rel in docs:
    heading = ""
    for i, l in enumerate(lines(rel), 1):
        if re.match(r"^\s{0,3}#{1,6}\s", l):
            heading = l
        if not ANY["retired-service"].search(l):
            continue
        for src, rx in deny.get("retired-service", []):
            if rx.search(l) and not LABEL.search(l) and not LABEL.search(heading):
                finding("retired-service", rel, i,
                        f"retired service name /{src}/ outside a labelled migration-alias or provenance context (FR-085)")
counts["retired-service"] = len(docs)

# ---------------------------------------------------------------- (c) placement
COMPOSE_FILE = re.compile(r"(^|/)((docker-)?compose(\.[\w-]+)?\.ya?ml|[\w-]+\.compose\.ya?ml)$", re.I)
for rel in files:
    if COMPOSE_FILE.search(rel):
        finding("placement", rel, 1, "a Compose file: platform applications run in Kubernetes only (FR-007, SC-017c)")
    if is_md(rel):
        continue
    for i, l in enumerate(lines(rel), 1):
        if COMMENT.match(l):
            continue
        for src, rx in deny.get("placement", []):
            if rx.search(l):
                finding("placement", rel, i, f"outside-Kubernetes deployment /{src}/ (FR-007, SC-017c)")
counts["placement"] = len(files)

# ---------------------------------------------------------------- (b) reference-artefact
RAW = re.compile(r"raw\.githubusercontent\.com|github\.com/.+/(raw|releases/latest)", re.I)
dash = [f for f in files if f.startswith("deploy/observability/") or "/dashboards/" in "/" + f]
for rel in dash:
    for i, l in enumerate(lines(rel), 1):
        if RAW.search(l) and "provenance:" not in l:
            finding("reference-artefact", rel, i,
                    "dashboard/panel/datasource resolves from a third-party repository at run time (FR-094, SC-017b)")

PLUGIN_VAR = re.compile(r"(GF_INSTALL_PLUGINS|GF_PLUGINS_PREINSTALL)\b\s*[=:]?\s*(.*)")
VERSIONED = re.compile(r"^\s*[\w.-]+(\s+|@)v?\d+\.\d+\.\d+\S*\s*$|^\s*https?://\S+;[\w.-]+\s*$")
def check_plugins(rel, i, value):
    value = value.strip().strip("'\"")
    if not value:
        return
    for p in [x for x in value.split(",") if x.strip()]:
        if not VERSIONED.match(p) or "latest" in p:
            finding("reference-artefact", rel, i,
                    f"Grafana plugin install without an explicit version: '{p.strip()}' (SC-017b, NFR-003)")
for rel in files:
    if is_md(rel):
        continue
    ls = lines(rel)
    for i, l in enumerate(ls, 1):
        m = PLUGIN_VAR.search(l)
        if not m or COMMENT.match(l):
            continue
        rest = m.group(2).strip()
        if rest.startswith(("value:", "- value:")) or not rest or rest in ('"', "'"):
            # YAML env entry: the value is on this line after `value:` or on the next one.
            nxt = ls[i] if i < len(ls) else ""
            v = re.search(r"value:\s*(.*)", rest) or re.search(r"^\s*value:\s*(.*)", nxt)
            if v:
                check_plugins(rel, i, v.group(1))
        else:
            check_plugins(rel, i, rest)

GEN_CALL = re.compile(r"\bclab(?:\s+|\S*/containerlab\s+)graph\b.*--drawio\b|\bclab2drawio\b")
GEN_PIN = re.compile(r"--drawio-version[= ]v?\d")
for rel in files:
    if is_md(rel):
        continue
    for i, l in enumerate(lines(rel), 1):
        if COMMENT.match(l):
            continue
        if "drawio-version" in l and not GEN_PIN.search(l):
            finding("reference-artefact", rel, i, "topology generator version is `latest` or omitted (--drawio-version <version>; NFR-003)")
        elif GEN_CALL.search(l) and not GEN_PIN.search(l):
            finding("reference-artefact", rel, i, "topology generator invoked without --drawio-version <version> (its default is latest; NFR-003)")

LATEST = re.compile(r"(?<![\w.-])[\w./-]*[\w-]:latest\b|\btag:\s*[\"']?latest[\"']?\s*$", re.I)
for rel in files:
    if not (rel.startswith(("deploy/", "config/", "lab/", "docker/")) or rel == "versions.lock.yaml"):
        continue
    for i, l in enumerate(lines(rel), 1):
        if not COMMENT.match(l) and LATEST.search(l):
            finding("reference-artefact", rel, i, "image at `latest` — every artefact is pinned (NFR-003)")
counts["reference-artefact"] = len(files)

# ---------------------------------------------------------------- FR-108 device clients
CLIENT = re.compile(r"(?:^|[\s;&|(`]|\$\()(gnmic|gnmi_cli|sr_cli|sshpass)(?=\s|$)")
SSH = re.compile(r"(?:^|[\s;&|(`]|\$\()ssh\s+(?=.*?(clab-|\b\d{1,3}(?:\.\d{1,3}){3}\b|mgmt))", re.I)
DOCKER_EXEC = re.compile(r"\bdocker\s+exec\b.*\bclab-")
GO_EXEC = re.compile(r"exec\.Command(?:Context)?\([^)]*\"(gnmic|gnmi_cli|sr_cli|sshpass|ssh)\"|\"docker\",\s*\"exec\"[^)]*clab-")
PY_EXEC = re.compile(r"(subprocess\.\w+|os\.system|Popen)\(.*[\[\(,]\s*['\"](gnmic|gnmi_cli|sr_cli|sshpass|ssh)(['\"]|\s)")
YAML_CMD = re.compile(r"^\s*(?:-\s*)?(?:(?:command|args)\s*:\s*)?\[?\s*['\"]?(gnmic|gnmi_cli|sr_cli|sshpass)['\"]?\s*(?:,|\]|$)")
def exempt_client(rel):
    return (rel.startswith(("tests/", "testautomation/", "deploy/observability/gnmic/"))
            or ((rel.startswith(("docs/", "specs/"))) and is_md(rel)))
scanned = 0
for rel in files:
    if exempt_client(rel) or text(rel) is None:
        continue
    scanned += 1
    cand = fenced(rel) if is_md(rel) else list(enumerate(lines(rel), 1))
    for i, l in cand:
        if not is_md(rel) and COMMENT.match(l):
            continue
        m = (CLIENT.search(l) or SSH.search(l) or DOCKER_EXEC.search(l) or GO_EXEC.search(l)
             or PY_EXEC.search(l) or (rel.endswith((".yaml", ".yml")) and YAML_CMD.search(l)))
        if m:
            finding("device-client", rel, i,
                    f"device client invoked outside tests/, testautomation/ and quoted docs/specs command blocks (FR-108, SC-049): {l.strip()[:120]}")
counts["device-client"] = scanned

# ---------------------------------------------------------------- YAML helpers
def yaml_docs(rel):
    """[(node|None)] composed documents, or None when the file does not parse."""
    t = text(rel)
    if t is None:
        return None
    try:
        if rel.endswith(".json"):
            return [yaml.compose(t, Loader=yaml.SafeLoader)]
        return list(yaml.compose_all(t, Loader=yaml.SafeLoader))
    except yaml.YAMLError:
        return None

def to_py(node):
    try:
        return yaml.SafeLoader(" ").construct_document(node) if node is not None else None
    except Exception:
        return None

def scalar(node):
    return node.value if isinstance(node, yaml.ScalarNode) else None

def mapping(node):
    """{key: (keynode, valnode)} of a MappingNode."""
    if not isinstance(node, yaml.MappingNode):
        return {}
    return {k.value: (k, v) for k, v in node.value if isinstance(k, yaml.ScalarNode)}

def line_of(node):
    return node.start_mark.line + 1

manifests = [f for f in files if f.startswith(("deploy/", "config/")) and f.endswith((".yaml", ".yml", ".json"))]

# ---------------------------------------------------------------- FR-019 / CR-008 credential literals
PLACEHOLDER = re.compile(r"^(\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$\([A-Za-z_][A-Za-z0-9_]*\)|\{\{.*\}\}|<[^<>]+>|__[A-Z0-9_]+__|)$", re.S)
CRED_SUFFIX = ("password", "passwd", "passphrase", "token", "apikey", "api_key", "api-key", "secretkey",
               "secret_key", "secret-key", "accesskey", "access_key", "access-key", "privatekey",
               "private_key", "private-key", "clientsecret", "client_secret", "client-secret",
               "credential", "credentials")
def cred_key(k):
    k = str(k).lower()
    return k in ("pwd", "pass") or k.endswith(CRED_SUFFIX)
CRED_ENV = re.compile(r"password|passwd|pwd|token|api[-_]?key|secret|credential|private[-_]?key|access[-_]?key", re.I)
BLOB = re.compile(r"(?im)^\s*[\"']?[\w.-]*(password|passwd|token|api[-_]?key|secret[-_]?key|credential)[\w.-]*[\"']?\s*[:=]\s*[\"']?([^\s\"',]+)")
# A flag whose NAME ENDS in the credential word carries the credential itself;
# --password-file=/path, --token-path … point at a mounted Secret and pass.
ARG = re.compile(r"--?[\w-]*(password|passwd|token|api-?key|secret|credential)s?(?:=|\s+)[\"']?([^\s\"']+)", re.I)
ARG_FLAG = re.compile(r"^--?[\w-]*(password|passwd|token|api-?key|secret|credential)s?$", re.I)
def literal(v):
    return v is not None and not PLACEHOLDER.match(str(v).strip())

def scan_blob(rel, node, where, decoded=None):
    s = decoded if decoded is not None else scalar(node)
    if not s:
        return
    for m in BLOB.finditer(s):
        if literal(m.group(2)):
            finding("credential-literal", rel, line_of(node),
                    f"literal credential inside {where} (FR-019, CR-008): use a secretKeyRef, a projected volume or a generator placeholder")
            return

def walk_cred(rel, node, path, in_data=False, secret_data=False):
    if isinstance(node, yaml.MappingNode):
        m = mapping(node)
        # env entry: {name: *PASSWORD*, value: literal}
        if "name" in m and "value" in m and CRED_ENV.search(str(scalar(m["name"][1]) or "")):
            v = scalar(m["value"][1])
            if literal(v):
                finding("credential-literal", rel, line_of(m["value"][1]),
                        f"env {scalar(m['name'][1])} carries a literal value (FR-019, CR-008): use valueFrom.secretKeyRef")
        for k, (kn, vn) in m.items():
            p = f"{path}.{k}" if path else str(k)
            if isinstance(vn, yaml.ScalarNode) and vn.tag.endswith((":str", ":int")) and cred_key(k) and literal(vn.value) \
                    and not (isinstance(vn.value, str) and vn.value.lower() in ("true", "false")):
                finding("credential-literal", rel, line_of(vn),
                        f"literal credential in '{p}' (FR-019, CR-008): use a secretKeyRef, a projected volume or a generator placeholder")
            elif in_data and isinstance(vn, yaml.ScalarNode):
                dec = None
                if secret_data:
                    try:
                        dec = base64.b64decode(vn.value, validate=False).decode("utf-8", "replace")
                    except Exception:
                        dec = None
                scan_blob(rel, vn, f"'{p}'", dec)
            if k in ("args", "command") and isinstance(vn, yaml.SequenceNode):
                items = [scalar(x) for x in vn.value]
                for j, it in enumerate(items):
                    if it is None:
                        continue
                    a = ARG.search(it)
                    if a and literal(a.group(2)):
                        finding("credential-literal", rel, line_of(vn.value[j]),
                                f"literal credential in argument '{it[:60]}' (FR-019, CR-008)")
                    elif ARG_FLAG.match(it) and j + 1 < len(items) and literal(items[j + 1]) \
                            and not str(items[j + 1]).startswith("-"):
                        finding("credential-literal", rel, line_of(vn.value[j + 1]),
                                f"literal credential after argument '{it}' (FR-019, CR-008)")
            walk_cred(rel, vn, p, in_data or k in ("data", "stringData", "binaryData"),
                      secret_data or k in ("data", "binaryData"))
    elif isinstance(node, yaml.SequenceNode):
        for j, x in enumerate(node.value):
            walk_cred(rel, x, f"{path}[{j}]", in_data, secret_data)

LINE_CRED = re.compile(r"^\s*[\"']?[\w.-]*(password|passwd|token|api[-_]?key|secret[-_]?key|credential)[\"']?\s*:\s*[\"']?([^\s\"'#]+)", re.I)
cred_files = [f for f in files if f.startswith("deploy/") and f.endswith((".yaml", ".yml", ".json"))]
for rel in cred_files:
    docs_ = yaml_docs(rel)
    if docs_ is None:   # a template that does not parse: line scan
        for i, l in enumerate(lines(rel), 1):
            m = LINE_CRED.search(l)
            if m and literal(m.group(2)):
                finding("credential-literal", rel, i, "literal credential (FR-019, CR-008)")
        continue
    for d in docs_:
        if d is None:
            continue
        kind = scalar(mapping(d).get("kind", (None, None))[1]) if isinstance(d, yaml.MappingNode) else None
        walk_cred(rel, d, "", False, False)
counts["credential-literal"] = len(cred_files)

# ---------------------------------------------------------------- FR-013 orchestration
deny_kinds, deny_groups = set(), set()
for src, _ in orch.get("kind", []):
    deny_kinds.add(src)
for src, _ in orch.get("group", []):
    deny_groups.add(src)
img_rx = [(s, re.compile(s, re.I)) for s, _ in orch.get("image", [])]
chart_rx = [(s, re.compile(r"^(?:" + s + r")$", re.I)) for s, _ in orch.get("chart", [])]
prov = [s for s, _ in orch.get("provider-serviceaccount", [])]
if len(prov) != 1 or "/" not in prov[0]:
    sys.exit("verify_boundaries: orchestration.denylist must name exactly one provider-serviceaccount <ns>/<name>")
prov_ns, prov_name = prov[0].split("/", 1)

def check_images_charts(rel, node, parent_key=None, in_chart_list=False):
    if isinstance(node, yaml.MappingNode):
        for k, (kn, vn) in mapping(node).items():
            s = scalar(vn)
            if s is not None:
                if k in ("image", "repository", "repo", "repoURL"):
                    for src, rx in img_rx:
                        if rx.search(s):
                            finding("orchestration", rel, line_of(vn), f"workflow/pipeline/job-engine image '{s}' (/{src}/; FR-013)")
                if k == "chart" or (k == "name" and in_chart_list):
                    for src, rx in chart_rx:
                        if rx.match(s.split("/")[-1]):
                            finding("orchestration", rel, line_of(vn), f"workflow/pipeline/job-engine chart '{s}' (FR-013)")
            check_images_charts(rel, vn, k, k in ("helmCharts", "dependencies"))
    elif isinstance(node, yaml.SequenceNode):
        for x in node.value:
            check_images_charts(rel, x, parent_key, in_chart_list)

rbac_roles, rbac_bindings = [], []
for rel in manifests:
    docs_ = yaml_docs(rel)
    if docs_ is None:
        for i, l in enumerate(lines(rel), 1):
            if re.match(r"^\s*kind:\s*[\"']?CronJob\b", l):
                finding("orchestration", rel, i, "kind CronJob: no second job engine (FR-013)")
        continue
    for d in docs_:
        if not isinstance(d, yaml.MappingNode):
            continue
        m = mapping(d)
        kind = scalar(m.get("kind", (None, None))[1]) or ""
        api = scalar(m.get("apiVersion", (None, None))[1]) or ""
        group = api.split("/")[0] if "/" in api else ""
        if kind in deny_kinds or f"{group}/{kind}" in deny_kinds or group in deny_groups:
            finding("orchestration", rel, line_of(m["kind"][1]) if "kind" in m else line_of(d),
                    f"kind {kind} ({api or 'no apiVersion'}): no second workflow, pipeline or job engine (FR-013)")
        check_images_charts(rel, d)
        if rel.startswith("deploy/sdc/"):
            continue   # the device-configuration layer's own vendored RBAC, excepted by path
        if group == "rbac.authorization.k8s.io" and kind in ("Role", "ClusterRole"):
            rbac_roles.append((rel, line_of(d), kind, to_py(d) or {}))
        if group == "rbac.authorization.k8s.io" and kind in ("RoleBinding", "ClusterRoleBinding"):
            rbac_bindings.append((rel, line_of(d), kind, to_py(d) or {}))
counts["orchestration"] = len(manifests)

lock = "versions.lock.yaml"
if lock in files:
    try:
        ldata = yaml.safe_load(text(lock) or "")
    except yaml.YAMLError:
        ldata = None
    def strings(o):
        if isinstance(o, dict):
            for k, v in o.items():
                yield from strings(k); yield from strings(v)
        elif isinstance(o, list):
            for v in o:
                yield from strings(v)
        elif isinstance(o, str):
            yield o
    lines_lock = lines(lock)
    def lineno(s):
        for i, l in enumerate(lines_lock, 1):
            if s in l:
                return i
        return 1
    for s in set(strings(ldata)):
        if s == "CronJob":
            finding("orchestration", lock, lineno(s), "CronJob in the lock file (FR-013)")
        if any(rx.search(s) for _, rx in img_rx):
            finding("orchestration", lock, lineno(s), f"workflow/pipeline/job-engine image '{s}' (FR-013)")
        elif any(rx.match(s.split("/")[-1]) for _, rx in chart_rx):
            finding("orchestration", lock, lineno(s), f"workflow/pipeline/job-engine chart '{s}' (FR-013)")

MUTATING = {"create", "update", "patch", "delete", "deletecollection", "*"}
def mutates_config(role):
    for r in role.get("rules") or []:
        groups = set(r.get("apiGroups") or [])
        verbs = set(v.lower() for v in (r.get("verbs") or []))
        if ("config.sdcio.dev" in groups or "*" in groups) and verbs & MUTATING:
            return True
    return False

mut = {}
for rel, ln, kind, role in rbac_roles:
    if not mutates_config(role):
        continue
    md = role.get("metadata") or {}
    mut[(kind, md.get("namespace"), md.get("name"))] = (rel, ln)
    labels = md.get("labels") or {}
    if any(k.startswith("rbac.authorization.k8s.io/aggregate-to-") for k in labels):
        finding("orchestration", rel, ln,
                f"{kind} {md.get('name')} holds a mutating verb on config.sdcio.dev and is aggregated into a built-in role (FR-013)")
for rel, ln, kind, b in rbac_bindings:
    ref = b.get("roleRef") or {}
    md = b.get("metadata") or {}
    key_ns = md.get("namespace") if ref.get("kind") == "Role" else None
    hit = mut.get((ref.get("kind"), key_ns, ref.get("name")))
    if hit is None and ref.get("kind") == "Role":   # namespace set by kustomize: match by name
        hit = next((v for (k, ns, n), v in mut.items() if k == "Role" and n == ref.get("name")), None)
    if hit is None:
        continue
    for s in b.get("subjects") or []:
        ok = (s.get("kind") == "ServiceAccount" and s.get("name") == prov_name
              and s.get("namespace") in (None, "", prov_ns))
        if not ok:
            who = f"{s.get('kind')} {(s.get('namespace') + '/') if s.get('namespace') else ''}{s.get('name')}"
            finding("orchestration", rel, ln,
                    f"{kind} {md.get('name')} gives {who} a mutating verb on config.sdcio.dev via "
                    f"{ref.get('kind')} {ref.get('name')} ({hit[0]}:{hit[1]}) — only {prov_ns}/{prov_name} may hold one (FR-013)")

# ---------------------------------------------------------------- report
order = ["migration", "retired-service", "placement", "reference-artefact", "device-client",
         "credential-literal", "orchestration"]
for check, rel, ln, msg in sorted(set(findings), key=lambda f: (order.index(f[0]), f[1], f[2])):
    print(f"FAIL [{check}] {rel}:{ln}: {msg}")
by = {c: sum(1 for f in set(findings) if f[0] == c) for c in order}
for c in order:
    print(f"verify-boundaries: {c:<19} {'FAIL' if by[c] else 'ok  '} {by[c]} finding(s) over {counts.get(c, 0)} file(s)")
if findings:
    print(f"verify-boundaries: FAIL {len(set(findings))} finding(s) under {root}")
    sys.exit(1)
print(f"verify-boundaries: PASS under {root}")
PY
