#!/usr/bin/env python3
"""Pin check and pin resolver for versions.lock.yaml (T010; NFR-003, CR-006, AD-05, AD-12, AD-21,
AD-49, AD-50, AD-71; data-model.md §23, §26, §28).

Invoked through scripts/lib/verify_pins.sh (``verify``) and scripts/lib/resolve_pins.sh
(``resolve``); see those wrappers for the operator-facing options.

Resolution is real, never a shape check:
  * an image digest resolves when ``skopeo inspect --raw docker://<repo>@<digest>`` returns a
    manifest whose SHA-256 is that digest;
  * a tag's commit resolves when ``git ls-remote`` shows ``refs/tags/<tag>`` (peeled) at it;
  * a bare commit resolves when it is a ref tip or ``git fetch --depth=1 <repo> <sha>`` fetches it;
  * a release asset checksum resolves when the release's own checksum file states it;
  * a Grafana plugin resolves when grafana.com serves that version with that package hash.
Results are cached for one run; ``PINS_CACHE_DIR`` (optional) additionally caches positive
results on disk, keyed by the exact query — the test suite uses it, nothing else sets it.

Allocator decision record (docs/decisions/allocator-substitution.md, FR-104, AD-49) — parseable
format, one section per event, in any order:

    ## 2026-10-01 adoption
    Reason: <why the upstream authority was substituted>

    ## 2026-11-15 return
    Reason: <why the upstream authority is used again>

A heading ``## <YYYY-MM-DD> adoption|return`` opens an entry; every entry needs its date and a
non-empty ``Reason:`` line. The latest-dated entry (file order breaks ties) is the record's state.
``allocationAuthority.kind: kuid`` requires the file to be absent or its state to be ``return``;
``kind: first-party`` requires the state ``adoption`` plus ``decisionRecord`` pointing at the file
and ``failedGateEvidence: {path, sha256}`` naming an existing file with that hash.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
import urllib.error
import urllib.request

import yaml

DECISION_RECORD = "docs/decisions/allocator-substitution.md"

# Paths (relative to --root) that are not part of the project: upstream reference checkouts,
# spec/tooling scratch, installed dependencies, and this checker's own fixtures and sources.
# The reference scan and the docker/ scan never look inside them.
SCAN_EXCLUDED_DIRS = [
    ".git",
    "config-server",
    "data-server",
    "kuid",
    "sdcio-docs",
    "specs",
    ".specify",
    ".specstride",
    # offline unit suites carry deliberate bad references as fixtures (e.g. srl-provider:dev in
    # verify_compat_test.sh); they are test data, never a manifest a workload is deployed from
    "tests/unit",
    ".mixture-of-loops",
    "prompts",
    "testautomation",   # spec-derived test-plan scaffolding (quotes tasks.md text), not project files
    "agents/.venv",
    "ui/node_modules",
    "ui/dist",
    "bin",
    ".evidence",
    ".cache",
    "scripts/lib/pins",
    "tests/unit/verifypins",
]
SCAN_EXCLUDED_FILES = [
    "versions.lock.yaml",
    "scripts/lib/verify_pins.sh",
    "scripts/lib/resolve_pins.sh",
]
# Dependency lock files are hashed, never scanned for image references.
SCAN_EXCLUDED_BASENAMES = {"go.sum", "uv.lock", "package-lock.json"}
# The files that can reference an image: manifests, scripts, Makefiles, Dockerfiles, compose files.
SCAN_SUFFIXES = (".yaml", ".yml", ".json", ".sh", ".bash", ".py", ".mk", ".tpl", ".jsonnet")
SCAN_BASENAME_RE = re.compile(r"^(Makefile|GNUmakefile|Dockerfile.*|.*\.Dockerfile|docker-compose.*)$")

REQUIRED_FIRST_PARTY = ["srl-provider", "supervisor", "mapper", "allocator", "deployer",
                        "intent-translator", "ui"]
REQUIRED_KEYS = [
    "goToolchain.go", "goToolchain.toolchain",
    "compatibilitySet.deviceImage", "compatibilitySet.yangModels", "compatibilitySet.deviationPatch",
    "compatibilitySet.schema", "compatibilitySet.schema.provider", "compatibilitySet.schema.version",
    "compatibilitySet.schema.models", "compatibilitySet.schema.includes",
    "compatibilitySet.schema.repositories",
    "compatibilitySet.deviceConfiguration", "compatibilitySet.allocationAuthorityRelease",
    "compatibilitySet.containerlab", "compatibilitySet.gnmic", "compatibilitySet.srlMapping",
    "allocationAuthority.kind",
    "platform.kind.release", "platform.kind.nodeImage", "platform.certManager", "platform.sdcLite",
    "platform.clickhouse", "platform.slim",
    "observability.otelCollector", "observability.prometheus", "observability.grafana",
    "observability.grafanaPlugins", "observability.topologyGenerator",
    "hostTooling.browserAutomation", "hostTooling.capture", "firstPartyImages",
]

EXACT_TAG_RE = re.compile(r"^v?\d+\.\d+\.\d+(?:[.\-+][0-9A-Za-z.\-+]*)?$")
# Release tags may carry a component prefix (e.g. ``slim-v0.6.1``).
EXACT_RELEASE_TAG_RE = re.compile(r"^(?:[A-Za-z][\w\-]*-)?v?\d+\.\d+\.\d+(?:[.\-+][0-9A-Za-z.\-+]*)?$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
SHA1_RE = re.compile(r"^[0-9a-f]{40}$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
RANGED_RE = re.compile(r"[<>~^*=!,|\s]|^latest$|\bx\b", re.I)
# Debian/RPM versions legitimately contain ':', '~' and '+'; a range starts with an operator.
CAPTURE_RANGED_RE = re.compile(r"^(>=|<=|>|<|~=|~>|\^|=)|[*\s,|]|^latest$|\.x$", re.I)
EXCEPTION_KEY_RE = re.compile(
    r"(?i)(^allow|exception|waiver|unpinned|skip|ignore|insecure|bypass|no[_\-]?verify|exempt|permissive)")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

TIMEOUT = int(os.environ.get("PINS_TIMEOUT", "90"))


# --------------------------------------------------------------------------------------------
# helpers


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run(cmd: list[str], timeout: int = TIMEOUT, env: dict | None = None) -> tuple[int, bytes, bytes]:
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, env=env)
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return 127, b"", f"{cmd[0]}: not found".encode()
    except subprocess.TimeoutExpired:
        return 124, b"", f"timed out after {timeout}s".encode()


# A transport failure (connection refused/reset, timeout, 429/5xx) is retried; an answer from the
# registry or repository (unknown manifest, missing ref, 404) is final and is never retried away.
TRANSIENT_RE = re.compile(
    r"(?i)connection (refused|reset)|timed? ?out|temporar|TLS handshake|EOF|too many requests|\b429\b|"
    r"\b50[0234]\b|service unavailable|bad gateway|could not resolve host|no such host|network is unreachable|failed to connect|could not connect|unable to access|connection closed|i/o timeout|broken pipe")
RETRIES = int(os.environ.get("PINS_RETRIES", "4"))


def run_net(cmd: list[str], timeout: int = TIMEOUT, env: dict | None = None) -> tuple[int, bytes, bytes]:
    for attempt in range(RETRIES):
        rc, out, err = run(cmd, timeout=timeout, env=env)
        if rc == 0 or not TRANSIENT_RE.search(err.decode(errors="replace")) or attempt == RETRIES - 1:
            return rc, out, err
        time.sleep(2 * (attempt + 1))
    return rc, out, err


def normalize_image_repo(ref: str) -> str:
    """docker reference normalisation: golang -> docker.io/library/golang."""
    first = ref.split("/", 1)[0]
    if "/" not in ref:
        return f"docker.io/library/{ref}"
    if "." in first or ":" in first or first == "localhost":
        if first in ("index.docker.io", "registry-1.docker.io"):
            ref = "docker.io/" + ref.split("/", 1)[1]
        if ref.startswith("docker.io/") and ref.count("/") == 1:
            ref = "docker.io/library/" + ref.split("/", 1)[1]
        return ref
    return f"docker.io/{ref}"


def github_slug(url: str) -> str | None:
    m = re.match(r"^https://github\.com/([^/]+/[^/]+?)(?:\.git)?/?$", url or "")
    return m.group(1) if m else None


def short_err(b: bytes) -> str:
    s = b.decode(errors="replace").strip().splitlines()
    s = [x for x in s if x.strip()]
    msg = s[-1] if s else "no output"
    msg = re.sub(r'^time="[^"]*" level=\w+ msg="?', "", msg).rstrip('"')
    # skopeo repeats the reference it was given; keep what the registry said
    msg = re.sub(r'^Error parsing image name \\?"[^"\\]*\\?":\s*', "", msg)
    return msg[:220]


# --------------------------------------------------------------------------------------------
# resolver: every network lookup, cached per run (and positively on disk when PINS_CACHE_DIR is set)


class Resolver:
    def __init__(self) -> None:
        self._mem: dict[str, tuple[bool, str]] = {}
        self._lock = threading.Lock()
        self._inflight: dict[str, threading.Event] = {}
        self.cache_dir = os.environ.get("PINS_CACHE_DIR") or None
        if self.cache_dir:
            os.makedirs(self.cache_dir, exist_ok=True)
        self.count = 0

    def _cached(self, key: str, fn):
        with self._lock:
            if key in self._mem:
                return self._mem[key]
            ev = self._inflight.get(key)
            owner = ev is None
            if owner:
                ev = threading.Event()
                self._inflight[key] = ev
        if not owner:
            ev.wait()
            return self._mem[key]
        res = None
        path = None
        if self.cache_dir:
            path = os.path.join(self.cache_dir, hashlib.sha256(key.encode()).hexdigest())
            if os.path.exists(path):
                with open(path) as f:
                    res = (True, f.read())
        if res is None:
            self.count += 1
            res = fn()
            if res[0] and path:
                with open(path, "w") as f:
                    f.write(res[1])
        with self._lock:
            self._mem[key] = res
            ev.set()
        return res

    # images ---------------------------------------------------------------------------------
    def image_digest_resolves(self, repo: str, digest: str) -> tuple[bool, str]:
        repo = normalize_image_repo(repo)

        def fn():
            rc, out, err = run_net(["skopeo", "inspect", "--raw", f"docker://{repo}@{digest}"])
            if rc != 0:
                return False, f"digest does not resolve in {repo.split('/')[0]}: {short_err(err)}"
            got = "sha256:" + hashlib.sha256(out).hexdigest()
            if got != digest:
                return False, f"registry returned a manifest with digest {got}"
            return True, digest

        return self._cached(f"image-digest|{repo}@{digest}", fn)

    def image_tag_digest(self, repo: str, tag: str) -> tuple[bool, str]:
        repo = normalize_image_repo(repo)

        def fn():
            rc, out, err = run_net(["skopeo", "inspect", "--raw", f"docker://{repo}:{tag}"])
            if rc != 0:
                return False, f"tag does not resolve: {short_err(err)}"
            return True, "sha256:" + hashlib.sha256(out).hexdigest()

        # tags move: never cached on disk
        with self._lock:
            if f"tag|{repo}:{tag}" in self._mem:
                return self._mem[f"tag|{repo}:{tag}"]
        res = fn()
        with self._lock:
            self._mem[f"tag|{repo}:{tag}"] = res
        return res

    def image_tags(self, repo: str) -> list[str]:
        repo = normalize_image_repo(repo)
        rc, out, err = run_net(["skopeo", "list-tags", f"docker://{repo}"], timeout=300)
        if rc != 0:
            return []
        return json.loads(out).get("Tags", [])

    # git ------------------------------------------------------------------------------------
    def ls_remote(self, url: str) -> tuple[bool, str]:
        def fn():
            rc, out, err = run_net(["git", "ls-remote", url], env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
            if rc != 0:
                return False, f"repository does not resolve: {short_err(err)}"
            return True, out.decode()

        # Ref tips move, so this is cached for one run — and on disk only under PINS_CACHE_DIR,
        # which only the test suite sets, for the length of its own run.
        return self._cached(f"ls-remote|{url}", fn)

    def refs(self, url: str) -> tuple[bool, dict[str, str] | str]:
        ok, out = self.ls_remote(url)
        if not ok:
            return False, out
        refs = {}
        for line in out.splitlines():
            if "\t" in line:
                sha, name = line.split("\t", 1)
                refs[name] = sha
        return True, refs

    def tag_commit(self, url: str, tag: str) -> tuple[bool, str]:
        ok, refs = self.refs(url)
        if not ok:
            return False, refs  # type: ignore[return-value]
        peeled = refs.get(f"refs/tags/{tag}^{{}}") or refs.get(f"refs/tags/{tag}")
        if peeled:
            return True, peeled
        if f"refs/heads/{tag}" in refs:
            return False, f"'{tag}' is a branch, not a tag"
        return False, f"tag {tag} does not exist in {url}"

    def commit_exists(self, url: str, sha: str) -> tuple[bool, str]:
        def fn():
            ok, refs = self.refs(url)
            if not ok:
                return False, refs
            if sha in refs.values():
                return True, sha
            d = tempfile.mkdtemp(prefix="pins-git-")
            try:
                env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
                run(["git", "init", "-q", d], env=env)
                rc, _, err = run_net(["git", "-C", d, "fetch", "-q", "--depth=1", url, sha], env=env)
                if rc != 0:
                    return False, f"commit does not resolve in {url}: {short_err(err)}"
                rc, out, _ = run(["git", "-C", d, "cat-file", "-t", sha], env=env)
                if rc != 0 or out.strip() != b"commit":
                    return False, f"{sha} is not a commit in {url}"
                return True, sha
            finally:
                shutil.rmtree(d, ignore_errors=True)

        return self._cached(f"commit|{url}|{sha}", fn)

    # releases, plugins ------------------------------------------------------------------------
    def http_get(self, url: str) -> tuple[bool, bytes | str]:
        headers = {"User-Agent": "agentic-netops-verify-pins"}
        req = urllib.request.Request(url, headers=headers)
        last = ""
        for attempt in range(RETRIES):
            try:
                with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                    return True, r.read()
            except urllib.error.HTTPError as e:
                last = f"HTTP {e.code} for {url}"
                if e.code not in (429, 500, 502, 503, 504):
                    return False, last
            except Exception as e:  # noqa: BLE001 — transport failure: retried
                last = f"{url}: {e}"
            if attempt < RETRIES - 1:
                time.sleep(2 * (attempt + 1))
        return False, last

    def release_asset_sha(self, repo_url: str, tag: str, checksum_file: str, asset: str) -> tuple[bool, str]:
        slug = github_slug(repo_url)

        def fn():
            if not slug:
                return False, f"not a GitHub repository URL: {repo_url}"
            url = f"https://github.com/{slug}/releases/download/{tag}/{checksum_file}"
            ok, body = self.http_get(url)
            if not ok:
                return False, f"release checksum file does not resolve: {body}"
            lines = body.decode(errors="replace").splitlines()  # type: ignore[union-attr]
            for line in lines:
                parts = line.split()
                if len(parts) >= 2 and parts[-1].lstrip("*") == asset and HEX64_RE.match(parts[0]):
                    return True, parts[0]
            if len(lines) == 1 and len(lines[0].split()) == 1 and HEX64_RE.match(lines[0].strip()):
                return True, lines[0].strip()
            return False, f"{checksum_file} of {tag} lists no {asset}"

        return self._cached(f"asset|{repo_url}|{tag}|{checksum_file}|{asset}", fn)

    def kind_default_node_image(self, commit: str) -> tuple[bool, str]:
        def fn():
            url = f"https://raw.githubusercontent.com/kubernetes-sigs/kind/{commit}/pkg/apis/config/defaults/image.go"
            ok, body = self.http_get(url)
            if not ok:
                return False, str(body)
            m = re.search(r'"kindest/node:(v[^"@]+)@(sha256:[0-9a-f]{64})"', body.decode())  # type: ignore[union-attr]
            if not m:
                return False, "no default node image in kind's defaults/image.go"
            return True, f"{m.group(1)}@{m.group(2)}"

        return self._cached(f"kind-default|{commit}", fn)

    def grafana_plugin_sha(self, plugin: str, version: str) -> tuple[bool, str]:
        def fn():
            ok, body = self.http_get(f"https://grafana.com/api/plugins/{plugin}/versions/{version}")
            if not ok:
                return False, f"grafana.com has no {plugin} {version}: {body}"
            data = json.loads(body)
            if data.get("version") != version:
                return False, f"grafana.com returned version {data.get('version')}"
            pkgs = data.get("packages") or {}
            pkg = pkgs.get("any") or pkgs.get("linux-amd64")
            if not pkg or not pkg.get("sha256"):
                return False, "grafana.com lists no package hash for this version"
            return True, pkg["sha256"]

        return self._cached(f"grafana|{plugin}|{version}", fn)


# --------------------------------------------------------------------------------------------
# lock-file walking


def keyfmt(path: list) -> str:
    """['a', 'b', '[x]', 0] -> a.b[x][0]: a list item is shown by its name/id/tool or index."""
    out = ""
    for p in path:
        if isinstance(p, str) and not p.startswith("["):
            out += ("." if out else "") + p
        elif isinstance(p, str):
            out += p
        else:
            out += f"[{p}]"
    return out


def list_label(item, idx):
    if isinstance(item, dict):
        for k in ("name", "id", "tool"):
            if isinstance(item.get(k), str) and item.get(k):
                return f"[{item[k]}]"
    return idx


def walk(node, path=None):
    """Yield (path, node) for every dict/list node; list paths use the item's name/id/tool."""
    path = path or []
    yield path, node
    if isinstance(node, dict):
        for k, v in node.items():
            if isinstance(v, (dict, list)):
                yield from walk(v, path + [str(k)])
    elif isinstance(node, list):
        for i, v in enumerate(node):
            if isinstance(v, (dict, list)):
                yield from walk(v, path + [list_label(v, i)])


def get(d, dotted):
    cur = d
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def s(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"  # as the lock file spells it
    return "" if v is None else str(v)


# --------------------------------------------------------------------------------------------
# host probes (data-model.md §28). Injectable honestly: PINS_HOST_PATH is the PATH searched for
# capture tools (default $PATH); PLAYWRIGHT_BROWSERS_PATH is Playwright's own variable;
# PINS_AGENTS_VENV is the tier's virtualenv (default <root>/agents/.venv).


def host_path() -> str:
    return os.environ.get("PINS_HOST_PATH", os.environ.get("PATH", ""))


def probe_tool_version(tool: str) -> tuple[str | None, str]:
    exe = shutil.which(tool, path=host_path())
    if not exe:
        return None, f"{tool} is not installed on this host (searched {host_path()})"
    patterns = {
        "ffmpeg": [(["-version"], r"^ffmpeg version (\S+)")],
        "Xvfb": [(["-version"], r"X\.Org X Server (\S+)"), (["-version"], r"^Xvfb version (\S+)")],
    }.get(tool, [(["--version"], r"(\d+\.\d+[\w.\-+:~]*)")])
    for args, rx in patterns:
        rc, out, err = run([exe] + args, timeout=20)
        text = (out + b"\n" + err).decode(errors="replace")
        m = re.search(rx, text, re.M)
        if m:
            return m.group(1), exe
    # The binary does not report a version itself (Debian's Xvfb): ask the package manager that
    # installed it.
    real = os.path.realpath(exe)
    if shutil.which("dpkg-query"):
        rc, out, _ = run(["dpkg-query", "-S", real], timeout=20)
        if rc == 0 and b":" in out:
            pkg = out.decode().split(":", 1)[0].split(",")[0].strip()
            rc, ver, _ = run(["dpkg-query", "-W", "-f=${Version}", pkg], timeout=20)
            if rc == 0 and ver.strip():
                return ver.decode().strip(), exe
    if shutil.which("rpm"):
        rc, out, _ = run(["rpm", "-qf", "--qf", "%{VERSION}-%{RELEASE}", real], timeout=20)
        if rc == 0 and out.strip():
            return out.decode().strip(), exe
    return None, f"{exe} reports no version this checker can read"


def venv_site_packages(root: str) -> list[str]:
    venv = os.environ.get("PINS_AGENTS_VENV") or os.path.join(root, "agents", ".venv")
    return sorted(glob.glob(os.path.join(venv, "lib", "python*", "site-packages")))


def installed_package_version(root: str, package: str) -> tuple[str | None, str | None]:
    for sp in venv_site_packages(root):
        for meta in glob.glob(os.path.join(sp, f"{package}-*.dist-info", "METADATA")):
            with open(meta, errors="replace") as f:
                for line in f:
                    if line.startswith("Version:"):
                        return line.split(":", 1)[1].strip(), sp
    return None, None


def package_browser_revision(site_packages: str, browser: str) -> str | None:
    p = os.path.join(site_packages, "playwright", "driver", "package", "browsers.json")
    if not os.path.exists(p):
        return None
    with open(p) as f:
        data = json.load(f)
    for b in data.get("browsers", []):
        if b.get("name") == browser:
            return str(b.get("revision"))
    return None


def browsers_dir(site_packages: str | None) -> str:
    v = os.environ.get("PLAYWRIGHT_BROWSERS_PATH")
    if v == "0" and site_packages:
        return os.path.join(site_packages, "playwright", "driver", "package", ".local-browsers")
    if v:
        return v
    return os.path.join(os.path.expanduser("~"), ".cache", "ms-playwright")


def pyproject_spec(path: str, package: str) -> list[str]:
    with open(path, "rb") as f:
        data = tomllib.load(f)
    specs = []
    pools = [data.get("project", {}).get("dependencies", [])]
    pools += list((data.get("project", {}).get("optional-dependencies") or {}).values())
    pools += list((data.get("dependency-groups") or {}).values())
    for pool in pools:
        for dep in pool:
            if isinstance(dep, str) and re.match(rf"^\s*{re.escape(package)}(\[[^\]]*\])?\s*([<>=!~;@ ]|$)", dep, re.I):
                specs.append(dep.strip())
    return specs


def uvlock_package(path: str, package: str) -> tuple[str | None, bool]:
    with open(path, "rb") as f:
        data = tomllib.load(f)
    for p in data.get("package", []):
        if p.get("name") == package:
            hashed = any(str(w.get("hash", "")).startswith("sha256:") for w in p.get("wheels", []))
            hashed = hashed or str((p.get("sdist") or {}).get("hash", "")).startswith("sha256:")
            return p.get("version"), hashed
    return None, False


# --------------------------------------------------------------------------------------------
# Dockerfile parsing


def parse_dockerfile(path: str) -> list[dict]:
    """Return the external images a Dockerfile builds from: every FROM that is not an earlier
    stage, and every COPY --from=<image> that is not a stage, in order."""
    with open(path, errors="replace") as f:
        raw = f.read()
    raw = re.sub(r"\\\r?\n", " ", raw)
    stages: set[str] = set()
    out = []
    for n, line in enumerate(raw.splitlines(), 1):
        t = line.strip()
        if not t or t.startswith("#"):
            continue
        m = re.match(r"(?i)^FROM\s+(.*)$", t)
        if m:
            toks = [x for x in m.group(1).split() if not x.startswith("--")]
            if not toks:
                continue
            img = toks[0]
            if len(toks) >= 3 and toks[1].lower() == "as":
                alias = toks[2].lower()
            else:
                alias = None
            if img.lower() not in stages and img.lower() != "scratch":
                out.append({"image": img, "line": n, "kind": "FROM"})
            if alias:
                stages.add(alias)
            continue
        m = re.match(r"(?i)^(COPY|ADD)\s+.*--from=(\S+)", t)
        if m:
            src = m.group(2)
            if src.lower() not in stages and not src.isdigit():
                out.append({"image": src, "line": n, "kind": "COPY --from"})
    return out


def split_image_ref(img: str) -> tuple[str, str | None, str | None]:
    digest = None
    if "@" in img:
        img, digest = img.split("@", 1)
    tag = None
    last = img.rsplit("/", 1)[-1]
    if ":" in last:
        img, tag = img.rsplit(":", 1)
    return img, tag, digest


# --------------------------------------------------------------------------------------------
# tree scans


def scan_files(root: str):
    root = os.path.abspath(root)
    excluded = {os.path.normpath(os.path.join(root, d)) for d in SCAN_EXCLUDED_DIRS}
    excluded_files = {os.path.normpath(os.path.join(root, f)) for f in SCAN_EXCLUDED_FILES}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if os.path.normpath(os.path.join(dirpath, d)) not in excluded
                       # containerlab's runtime lab directory (lab/clab-<lab>/): git-ignored, device-generated
                       and not (os.path.basename(dirpath) == "lab" and d.startswith("clab-"))]
        for fn in filenames:
            full = os.path.normpath(os.path.join(dirpath, fn))
            if full in excluded_files or fn in SCAN_EXCLUDED_BASENAMES:
                continue
            if fn.endswith(SCAN_SUFFIXES) or SCAN_BASENAME_RE.match(fn):
                yield full


def find_image_references(root: str, name: str, own_dockerfile: str | None):
    """Yield (relpath, lineno, kind, tag, text) for each reference to first-party image `name`.
    kind is 'dockerfile' (its Dockerfile named), 'tagged' (name:tag), 'digest' (name@sha256) or
    'bare' (an image: field naming it with no tag, i.e. implicit latest)."""
    n = re.escape(name)
    df_re = re.compile(rf"(?<![\w.\-])Dockerfile\.{n}(?![\w.\-])")
    ref_re = re.compile(rf"(?<![\w.\-]){n}(?::([^\s\"'@,\]\)}}]+)|@sha256:[0-9a-f]{{64}})")
    bare_re = re.compile(rf"^\s*-?\s*image:\s*[\"']?(?:[\w.\-]+(?::\d+)?/)*{n}[\"']?\s*(#.*)?$")
    for path in scan_files(root):
        rel = os.path.relpath(path, root)
        if own_dockerfile and os.path.normpath(rel) == os.path.normpath(own_dockerfile):
            continue
        try:
            with open(path, errors="replace") as f:
                lines = f.readlines()
        except OSError:
            continue
        for i, line in enumerate(lines, 1):
            if line.lstrip().startswith("#") and not os.path.basename(path).startswith("Dockerfile"):
                continue  # a comment describing the tag form (<name>:<contentHash>), not a reference
            if df_re.search(line):
                yield rel, i, "dockerfile", None, line.strip()
            for m in ref_re.finditer(line):
                start = m.start()
                if start >= 2 and line[start - 2:start] == "//":
                    continue  # a URL host (http://mapper:8080), not an image
                tag = m.group(1)
                if tag is not None and re.fullmatch(r"\d{1,5}", tag):
                    continue  # host:port, not an image tag
                yield rel, i, ("tagged" if tag is not None else "digest"), tag, line.strip()
            if bare_re.match(line):
                yield rel, i, "bare", None, line.strip()


def docker_dir_dockerfiles(root: str) -> list[str]:
    d = os.path.join(root, "docker")
    out = []
    if not os.path.isdir(d):
        return out
    for dirpath, _, filenames in os.walk(d):
        for fn in filenames:
            if fn.startswith("Dockerfile") or fn.endswith((".Dockerfile", ".dockerfile")):
                out.append(os.path.relpath(os.path.join(dirpath, fn), root))
    return sorted(out)


def parse_decision_record(path: str) -> tuple[list[dict], list[str]]:
    entries, problems = [], []
    cur = None
    with open(path, errors="replace") as f:
        for n, line in enumerate(f, 1):
            m = re.match(r"^##\s+(.*)$", line.rstrip())
            if m:
                head = m.group(1).strip()
                em = re.match(r"^(?:(\S+)\s+)?(adoption|return)\b", head, re.I)
                if em:
                    cur = {"date": em.group(1), "event": em.group(2).lower(), "line": n, "reason": ""}
                    entries.append(cur)
                else:
                    cur = None
                continue
            if cur is not None:
                rm = re.match(r"^\s*Reason:\s*(.*)$", line)
                if rm and rm.group(1).strip():
                    cur["reason"] = rm.group(1).strip()
    for e in entries:
        label = f"{e['event']} entry at line {e['line']}"
        if not e["date"] or not DATE_RE.match(e["date"]):
            problems.append(f"{label} has no date (expected '## YYYY-MM-DD {e['event']}')")
        if not e["reason"]:
            problems.append(f"{label} states no reason (expected a 'Reason:' line)")
    return entries, problems


def record_state(entries: list[dict]) -> str | None:
    dated = [(e["date"] or "", i, e) for i, e in enumerate(entries) if e["date"] and DATE_RE.match(e["date"])]
    if not dated:
        return entries[-1]["event"] if entries else None
    dated.sort(key=lambda x: (x[0], x[1]))
    return dated[-1][2]["event"]


def read_go_mod(root: str) -> tuple[str | None, str | None]:
    p = os.path.join(root, "go.mod")
    if not os.path.exists(p):
        return None, None
    go = tc = None
    with open(p) as f:
        for line in f:
            m = re.match(r"^go\s+(\S+)", line)
            if m:
                go = m.group(1)
            m = re.match(r"^toolchain\s+(\S+)", line)
            if m:
                tc = m.group(1)
    if go and not tc:
        tc = "go" + go
    return go, tc


# --------------------------------------------------------------------------------------------
# verify


class Verifier:
    def __init__(self, lock_path: str, root: str, no_pending: bool, host_tooling: bool):
        self.lock_path = lock_path
        self.lock_label = os.path.relpath(lock_path, root) if os.path.abspath(lock_path).startswith(os.path.abspath(root) + os.sep) else lock_path
        self.root = root
        self.no_pending = no_pending
        self.host_tooling = host_tooling
        self.failures: list[str] = []
        self.pending: list[str] = []
        self.jobs: list = []
        self.res = Resolver()
        self._flock = threading.Lock()

    def fail(self, key, ref, reason, file=None):
        with self._flock:
            self.failures.append(f"FAIL {file or self.lock_label}: {key}: {ref}: {reason}")

    def job(self, fn):
        self.jobs.append(fn)

    # --- rules ------------------------------------------------------------------------------
    def check_exceptions(self, node, path=None):
        path = path or []
        if isinstance(node, dict):
            for k, v in node.items():
                if EXCEPTION_KEY_RE.search(str(k)):
                    self.fail(keyfmt(path + [str(k)]), s(v) if not isinstance(v, (dict, list)) else "<block>",
                              "declares a pin exception; the lock file has no exception field — the recorded "
                              "allocator substitution is the only exception NFR-003 admits (AD-12)")
                self.check_exceptions(v, path + [str(k)])
        elif isinstance(node, list):
            for i, v in enumerate(node):
                self.check_exceptions(v, path + [list_label(v, i)])

    def check_required(self, lock):
        for k in REQUIRED_KEYS:
            if get(lock, k) in (None, "", [], {}):
                self.fail(k, "-", "required entry missing from the lock file")
        names = [e.get("name") for e in (lock.get("firstPartyImages") or []) if isinstance(e, dict)]
        for n in REQUIRED_FIRST_PARTY:
            if n not in names:
                self.fail(f"firstPartyImages[{n}]", "-", "first-party image has no lock entry")

    def check_versions(self, lock):
        for path, node in walk(lock):
            if not isinstance(node, dict) or (path and path[0] == "hostTooling"):
                continue
            if "version" in node and not isinstance(node["version"], (dict, list)):
                v = s(node["version"])
                if not v:
                    self.fail(keyfmt(path + ["version"]), "-", "version missing")
                elif not EXACT_RELEASE_TAG_RE.match(v):
                    self.fail(keyfmt(path + ["version"]), v, "not an exact release version (latest, a floating or ranged version is forbidden)")

    def check_image(self, path, node, first_party_from=False):
        key = keyfmt(path)
        repo = s(node.get("ref") if first_party_from else node.get("repository"))
        tag = s(node.get("tag"))
        digest = s(node.get("digest"))
        if not repo:
            self.fail(key + (".ref" if first_party_from else ".repository"), "-", "image repository missing")
            return
        ref = f"{repo}:{tag or '<no tag>'}@{digest or '<no digest>'}"
        if not tag:
            self.fail(key + ".tag", ref, "image version (tag) omitted — an image is pinned by tag and digest")
        elif tag == "latest":
            self.fail(key + ".tag", ref, "'latest' is forbidden")
        elif not EXACT_TAG_RE.match(tag):
            self.fail(key + ".tag", ref, "floating or non-release tag — pin an exact MAJOR.MINOR.PATCH release")
        if not digest:
            self.fail(key + ".digest", ref, "digest unresolved — run scripts/lib/resolve_pins.sh")
        elif not DIGEST_RE.match(digest):
            self.fail(key + ".digest", ref, "not a sha256 digest")
        else:
            def j(repo=repo, digest=digest, key=key, ref=ref):
                ok, why = self.res.image_digest_resolves(repo, digest)
                if not ok:
                    self.fail(key + ".digest", ref, why)
            self.job(j)
        if "pinned" in node and not first_party_from:
            want = f"{repo}:{tag}@{digest}"
            if s(node["pinned"]) != want:
                self.fail(key + ".pinned", s(node["pinned"]) or "<empty>", f"does not equal {want}")

    def check_git(self, path, node):
        key = keyfmt(path)
        url = s(node.get("repository"))
        commit = s(node.get("commit"))
        tag = node.get("tag")
        if not url:
            self.fail(key + ".repository", "-", "repository missing")
            return
        if "branch" in node:
            self.fail(key + ".branch", s(node["branch"]), "branch references are forbidden")
        ref = f"{url}@{tag or commit or '<none>'}"
        if tag is not None:
            tag = s(tag)
            if not tag:
                self.fail(key + ".tag", ref, "release tag omitted")
            elif not EXACT_RELEASE_TAG_RE.match(tag):
                self.fail(key + ".tag", ref, "floating or non-release tag")
        if not commit:
            self.fail(key + ".commit", ref, "commit unresolved — run scripts/lib/resolve_pins.sh")
            return
        if not SHA1_RE.match(commit):
            self.fail(key + ".commit", f"{url}@{commit}", "not a full commit hash")
            return

        def j():
            if tag:
                ok, got = self.res.tag_commit(url, tag)
                if not ok:
                    self.fail(key + ".tag", f"{url}@{tag}", got)
                elif got != commit:
                    self.fail(key + ".commit", f"{url}@{commit}", f"tag {tag} is at {got}")
            else:
                ok, why = self.res.commit_exists(url, commit)
                if not ok:
                    self.fail(key + ".commit", f"{url}@{commit}", why)
        self.job(j)

        if "asset" in node or "checksumFile" in node or "assetSha256" in node:
            asset, cfile, want = s(node.get("asset")), s(node.get("checksumFile")), s(node.get("assetSha256"))
            aref = f"{url} {tag} {asset}"
            if not (asset and cfile):
                self.fail(key + ".asset", aref, "asset and checksumFile are both required")
            elif not want:
                self.fail(key + ".assetSha256", aref, "asset checksum unresolved — run scripts/lib/resolve_pins.sh")
            else:
                def ja():
                    ok, got = self.res.release_asset_sha(url, s(tag), cfile, asset)
                    if not ok:
                        self.fail(key + ".assetSha256", aref, got)
                    elif got != want:
                        self.fail(key + ".assetSha256", aref, f"release checksum is {got}, lock records {want}")
                self.job(ja)

    def check_schema(self, lock):
        schema = get(lock, "compatibilitySet.schema") or {}
        repos = schema.get("repositories") or []
        parts = {s(get(lock, "compatibilitySet.yangModels.repository")): get(lock, "compatibilitySet.yangModels") or {},
                 s(get(lock, "compatibilitySet.deviationPatch.repository")): get(lock, "compatibilitySet.deviationPatch") or {}}
        for i, r in enumerate(repos):
            key = f"compatibilitySet.schema.repositories[{i}]"
            url, kind, ref = s(r.get("repoURL")), s(r.get("kind")), s(r.get("ref"))
            full = f"{url}@{kind}:{ref}"
            if not url or not ref:
                self.fail(key, full, "repoURL and ref are required")
                continue
            if kind == "branch":
                self.fail(key + ".kind", full, "branch reference in the Schema CR — pin by tag or commit hash")
                continue
            if kind not in ("tag", "hash"):
                self.fail(key + ".kind", full, "kind must be tag or hash")
                continue
            part = parts.get(url, {})
            mirror = r.get("mirror")
            if mirror is not None:
                # AD-75: an in-cluster mirror of the pinned commit, served ONLY under a tag named
                # after that commit; it is populated from repoURL, which is what is resolved below.
                mkey, mm = key + ".mirror", mirror if isinstance(mirror, dict) else {}
                murl, mkind, mref = s(mm.get("repoURL")), s(mm.get("kind")), s(mm.get("ref"))
                mfull = f"{murl}@{mkind}:{mref}"
                if not re.match(r"^http://[a-z0-9-]+\.[a-z0-9-]+\.svc\.cluster\.local/", murl):
                    self.fail(mkey + ".repoURL", mfull, "a Schema mirror is an in-cluster Service URL (http://<svc>.<ns>.svc.cluster.local/…)")
                if mkind != "tag":
                    self.fail(mkey + ".kind", mfull, "a Schema mirror serves the pinned commit under a tag — kind must be tag")
                if kind != "hash" or mref != ref:
                    self.fail(mkey + ".ref", mfull, f"the mirror's tag must be named after the pinned commit {ref} (kind hash)")

            def j(url=url, kind=kind, ref=ref, key=key, full=full, part=part):
                if kind == "tag":
                    ok, got = self.res.tag_commit(url, ref)
                    if not ok:
                        self.fail(key + ".ref", full, got)
                    elif part.get("commit") and got != part.get("commit"):
                        self.fail(key + ".ref", full, f"tag is at {got}, the compatibility set pins {part.get('commit')}")
                else:
                    if not SHA1_RE.match(ref):
                        self.fail(key + ".ref", full, "kind hash needs a full commit hash")
                        return
                    ok, why = self.res.commit_exists(url, ref)
                    if not ok:
                        self.fail(key + ".ref", full, why)
                    elif part.get("commit") and ref != part.get("commit"):
                        self.fail(key + ".ref", full, f"the compatibility set pins {part.get('commit')}")
            self.job(j)

    def check_plugins(self, lock):
        for i, p in enumerate(get(lock, "observability.grafanaPlugins") or []):
            pid = s(p.get("id")) or str(i)
            key = f"observability.grafanaPlugins[{pid}]"
            ver, sha = s(p.get("version")), s(p.get("sha256"))
            if not p.get("id"):
                self.fail(key + ".id", "-", "plugin id missing")
                continue
            if not ver:
                self.fail(key + ".version", pid, "Grafana plugin has no version")
                continue
            if not sha:
                self.fail(key + ".sha256", f"{pid}@{ver}", "plugin package hash unresolved — run scripts/lib/resolve_pins.sh")
                continue

            def j(pid=pid, ver=ver, sha=sha, key=key):
                ok, got = self.res.grafana_plugin_sha(pid, ver)
                if not ok:
                    self.fail(key + ".version", f"{pid}@{ver}", got)
                elif got != sha:
                    self.fail(key + ".sha256", f"{pid}@{ver}", f"grafana.com package hash is {got}, lock records {sha}")
            self.job(j)

    def check_kind_node(self, lock):
        node = get(lock, "platform.kind.nodeImage") or {}
        commit = s(get(lock, "platform.kind.release.commit"))
        if node.get("source") != "kind-default" or not SHA1_RE.match(commit):
            return

        def j():
            ok, got = self.res.kind_default_node_image(commit)
            if not ok:
                self.fail("platform.kind.nodeImage", "kind@" + commit, got)
                return
            tag, digest = got.split("@")
            if s(node.get("tag")) != tag or s(node.get("digest")) != digest:
                self.fail("platform.kind.nodeImage", f"{s(node.get('tag'))}@{s(node.get('digest'))}",
                          f"the pinned kind release's default node image is kindest/node:{tag}@{digest}")
        self.job(j)

    def check_allocator(self, lock):
        aa = lock.get("allocationAuthority") or {}
        kind = s(aa.get("kind"))
        rec_path = os.path.join(self.root, DECISION_RECORD)
        entries, problems, state = [], [], None
        if os.path.exists(rec_path):
            entries, problems = parse_decision_record(rec_path)
            state = record_state(entries)
            for p in problems:
                self.fail("allocationAuthority", DECISION_RECORD, p, file=DECISION_RECORD)
        if kind not in ("kuid", "first-party"):
            self.fail("allocationAuthority.kind", kind or "<empty>", "must be kuid or first-party")
            return
        extra = [k for k in aa if k not in ("kind", "decisionRecord", "failedGateEvidence")]
        for k in extra:
            self.fail(f"allocationAuthority.{k}", s(aa[k]), "unknown key in the allocation-authority block (data-model.md §23)")
        if kind == "kuid":
            for k in ("decisionRecord", "failedGateEvidence"):
                if k in aa:
                    self.fail(f"allocationAuthority.{k}", s(aa[k]), "only allowed when kind is first-party")
            if state == "adoption":
                self.fail("allocationAuthority.kind", "kuid",
                          f"{DECISION_RECORD} records an adoption of the substitute and no later dated return entry "
                          "(FR-104: the return is recorded like the adoption)")
            return
        # first-party
        dr = aa.get("decisionRecord")
        if not dr:
            self.fail("allocationAuthority.decisionRecord", "<missing>", "kind first-party requires the decision record")
        elif os.path.normpath(s(dr)) != DECISION_RECORD or not os.path.exists(os.path.join(self.root, s(dr))):
            self.fail("allocationAuthority.decisionRecord", s(dr), f"does not resolve to a committed {DECISION_RECORD}")
        elif state != "adoption":
            self.fail("allocationAuthority.decisionRecord", s(dr), "the decision record's latest entry is not an adoption")
        fge = aa.get("failedGateEvidence")
        if not isinstance(fge, dict) or not fge.get("path") or not fge.get("sha256"):
            self.fail("allocationAuthority.failedGateEvidence", s(fge) or "<missing>",
                      "kind first-party requires {path, sha256} of the failed G11 evidence")
        else:
            p = s(fge["path"])
            full = p if os.path.isabs(p) else os.path.join(self.root, p)
            if not os.path.isfile(full):
                self.fail("allocationAuthority.failedGateEvidence.path", p, "evidence file does not exist")
            elif sha256_file(full) != s(fge["sha256"]).removeprefix("sha256:"):
                self.fail("allocationAuthority.failedGateEvidence.sha256", s(fge["sha256"]),
                          f"differs from the file's SHA-256 {sha256_file(full)}")

    def check_go(self, lock):
        go, tc = read_go_mod(self.root)
        lgo, ltc = s(get(lock, "goToolchain.go")), s(get(lock, "goToolchain.toolchain"))
        if go is None:
            self.fail("goToolchain", "go.mod", "go.mod not found under the tree root")
            return
        if lgo != go:
            self.fail("goToolchain.go", lgo or "<empty>", f"lock file records go {lgo or '<empty>'}, go.mod states go {go} (AD-50)")
        if ltc != tc:
            self.fail("goToolchain.toolchain", ltc or "<empty>", f"lock file records {ltc or '<empty>'}, go.mod states {tc} (AD-50)")
        want = (tc or "").removeprefix("go")
        for e in lock.get("firstPartyImages") or []:
            for i, f in enumerate(e.get("from") or []):
                if normalize_image_repo(s(f.get("ref"))) == "docker.io/library/golang" and s(f.get("tag")):
                    if not s(f.get("tag")).startswith(want + "-") and s(f.get("tag")) != want:
                        self.fail(f"firstPartyImages[{e.get('name')}].from[{i}].tag", s(f.get("tag")),
                                  f"golang base does not match the recorded toolchain {tc}")

    def check_first_party(self, lock):
        entries = [e for e in (lock.get("firstPartyImages") or []) if isinstance(e, dict)]
        locked_dfs = {os.path.normpath(s(e.get("dockerfile"))) for e in entries}
        for df in docker_dir_dockerfiles(self.root):
            if os.path.normpath(df) not in locked_dfs:
                self.fail("firstPartyImages", df, "Dockerfile under docker/ has no firstPartyImages entry", file=df)
        for e in entries:
            name = s(e.get("name"))
            key = f"firstPartyImages[{name}]"
            for forbidden in ("digest", "image", "imageId", "tag"):
                if forbidden in e:
                    self.fail(f"{key}.{forbidden}", s(e[forbidden]), "a locally built image has no registry digest or tag in the lock file (AD-05)")
            df = s(e.get("dockerfile"))
            if not df:
                self.fail(f"{key}.dockerfile", "-", "dockerfile missing")
                continue
            froms = e.get("from") or []
            if not froms:
                self.fail(f"{key}.from", "-", "no FROM pinned")
            for i, f in enumerate(froms):
                self.check_image(["firstPartyImages", f"[{name}]", "from", i], f, first_party_from=True)
            present = os.path.isfile(os.path.join(self.root, df))
            for i, d in enumerate(e.get("dependencyLocks") or []):
                p, want = s(d.get("path")), s(d.get("sha256"))
                full = os.path.join(self.root, p)
                dkey = f"{key}.dependencyLocks[{p or i}].sha256"
                if not os.path.isfile(full):
                    if present:
                        self.fail(dkey, p, "dependency lock file missing from the tree")
                    continue
                got = sha256_file(full)
                if not want:
                    self.fail(dkey, p, "sha256 unresolved — run scripts/lib/resolve_pins.sh")
                elif want.removeprefix("sha256:") != got:
                    self.fail(dkey, p, f"file SHA-256 is {got}, lock records {want}")
            refs = list(find_image_references(self.root, name, df))
            if not present:
                self.pending.append(name)
                if self.no_pending:
                    self.fail(key, df, "pending — Dockerfile absent; --no-pending admits no pending entry")
                seen = set()
                for rel, ln, kind, tag, text in refs:
                    if (rel, ln) not in seen:
                        seen.add((rel, ln))
                        self.fail(key, f"{rel}:{ln}", f"references image {name} while its Dockerfile {df} is absent (pending): {text[:120]}", file=rel)
                continue
            if not os.path.isdir(os.path.join(self.root, s(e.get("context")) or ".")):
                self.fail(f"{key}.context", s(e.get("context")), "build context does not exist")
            self.check_dockerfile(key, df, froms)
            for rel, ln, kind, tag, text in refs:
                if kind == "bare":
                    self.fail(key, f"{rel}:{ln}", f"references {name} with no tag (implicit latest): {text[:120]}", file=rel)
                elif kind == "tagged" and "$" not in tag and not HEX64_RE.match(tag):
                    self.fail(key, f"{rel}:{ln}", f"references {name}:{tag} — a first-party image is referenced only by its content-hash tag: {text[:120]}", file=rel)

    def check_dockerfile(self, key, df, froms):
        found = parse_dockerfile(os.path.join(self.root, df))
        if len(found) != len(froms):
            self.fail(f"{key}.from", df, f"Dockerfile has {len(found)} external image(s), the lock file pins {len(froms)}", file=df)
        for i, fr in enumerate(found):
            img = fr["image"]
            where = f"{df}:{fr['line']}"
            if "$" in img:
                self.fail(f"{key}.from[{i}]", img, f"{fr['kind']} at {where} uses a build argument — every FROM is <ref>@sha256:<digest>", file=df)
                continue
            repo, tag, digest = split_image_ref(img)
            if not digest:
                self.fail(f"{key}.from[{i}]", img, f"{fr['kind']} at {where} is not pinned by digest (<ref>@sha256:<digest>)", file=df)
                continue
            if i >= len(froms):
                continue
            want = froms[i]
            if normalize_image_repo(repo) != normalize_image_repo(s(want.get("ref"))):
                self.fail(f"{key}.from[{i}].ref", img, f"{where} names {repo}, the lock file pins {want.get('ref')}", file=df)
            # The Dockerfile may name the exact tag or the line it was resolved from (track:); the
            # digest, which must equal the lock's, is what pins it.
            if tag is not None and tag not in (s(want.get("tag")), s(want.get("track")) or None):
                self.fail(f"{key}.from[{i}].tag", img, f"{where} tag {tag} differs from the lock file's {want.get('tag')}", file=df)
            if digest != s(want.get("digest")):
                self.fail(f"{key}.from[{i}].digest", img, f"{where} digest differs from the lock file's {want.get('digest') or '<empty>'}", file=df)
            elif not DIGEST_RE.match(digest):
                self.fail(f"{key}.from[{i}].digest", img, "not a sha256 digest", file=df)

    def check_host_tooling(self, lock):
        ba = get(lock, "hostTooling.browserAutomation") or {}
        pkg, ver = s(ba.get("package")), s(ba.get("version"))
        key = "hostTooling.browserAutomation"
        if not pkg:
            self.fail(key + ".package", "-", "package missing")
            return
        if not ver:
            self.fail(key + ".version", pkg, "version not recorded — run scripts/lib/resolve_pins.sh")
        elif RANGED_RE.search(ver) or not re.match(r"^\d+(\.\d+)*$", ver):
            self.fail(key + ".version", f"{pkg} {ver}", "browser-automation version is ranged or inexact")
        pp = s(ba.get("pyproject"))
        if pp:
            full = os.path.join(self.root, pp)
            if not os.path.isfile(full):
                self.fail(key + ".pyproject", pp, "file missing from the tree")
            else:
                specs = pyproject_spec(full, pkg)
                if not specs:
                    self.fail(key + ".pyproject", pp, f"{pkg} is not declared there")
                for sp in specs:
                    m = re.match(rf"(?i)^{re.escape(pkg)}\s*==\s*([0-9][\w.]*)\s*$", sp)
                    if not m:
                        self.fail(key + ".version", f"{pp}: {sp}", "browser-automation package is ranged, not an exact == pin")
                    elif ver and m.group(1) != ver:
                        self.fail(key + ".version", f"{pp}: {sp}", f"differs from the lock file's {ver}")
        lf = s(ba.get("lockFile"))
        if not lf:
            self.fail(key + ".lockFile", "-", "lockFile missing")
        elif not os.path.isfile(os.path.join(self.root, lf)):
            self.fail(key + ".lockFile", lf, "file missing from the tree")
        else:
            lver, hashed = uvlock_package(os.path.join(self.root, lf), pkg)
            if not lver:
                self.fail(key + ".lockFile", lf, f"{pkg} is not locked there")
            else:
                if ver and lver != ver:
                    self.fail(key + ".version", f"{lf}: {pkg} {lver}", f"differs from the lock file's {ver}")
                if not hashed:
                    self.fail(key + ".lockFile", lf, f"{pkg} is not hash-locked")
        if not self.host_tooling:
            return
        # --host-tooling: what the host actually has
        rev = s(ba.get("browserRevision"))
        browser = s(ba.get("browser")) or "chromium"
        if not rev:
            self.fail(key + ".browserRevision", browser, "browser revision not recorded — run scripts/lib/resolve_pins.sh --host-tooling")
        inst, sp = installed_package_version(self.root, pkg)
        if not inst:
            self.fail(key + ".version", pkg, "package is not installed in the tier's virtualenv on this host")
        else:
            if ver and inst != ver:
                self.fail(key + ".version", f"{pkg} {inst}", f"installed version differs from the locked {ver}")
            fixed = package_browser_revision(sp, browser)
            if not fixed:
                self.fail(key + ".browserRevision", browser, f"installed {pkg} states no {browser} revision")
            elif rev and fixed != rev:
                self.fail(key + ".browserRevision", rev, f"the locked package fixes {browser} revision {fixed}")
            if fixed:
                bdir = os.path.join(browsers_dir(sp), f"{browser}-{fixed}")
                if not os.path.isdir(bdir):
                    have = sorted(os.path.basename(x) for x in glob.glob(os.path.join(browsers_dir(sp), f"{browser}-*")))
                    self.fail(key + ".browserRevision", f"{browser}-{fixed}",
                              f"installed browser revision differs: {bdir} absent (installed: {', '.join(have) or 'none'})")
        for i, c in enumerate(get(lock, "hostTooling.capture") or []):
            tool, rec = s(c.get("tool")), s(c.get("version"))
            ck = f"hostTooling.capture[{tool or i}].version"
            if not tool:
                self.fail(f"hostTooling.capture[{i}].tool", "-", "tool missing")
                continue
            if not rec:
                self.fail(ck, tool, "version not recorded — run scripts/lib/resolve_pins.sh --host-tooling")
            elif CAPTURE_RANGED_RE.search(rec):
                self.fail(ck, f"{tool} {rec}", "recorded version is ranged")
            obs, where = probe_tool_version(tool)
            if obs is None:
                self.fail(ck, tool, f"capture tool missing: {where}")
            elif rec and obs != rec:
                self.fail(ck, f"{tool} {obs}", f"host version differs from the recorded {rec} ({where})")

    # --- main -------------------------------------------------------------------------------
    def run(self) -> int:
        if not os.path.isfile(self.lock_path):
            print(f"FAIL {self.lock_path}: -: -: lock file not found")
            return 1
        try:
            with open(self.lock_path) as f:
                lock = yaml.safe_load(f)
        except yaml.YAMLError as e:
            print(f"FAIL {self.lock_label}: -: -: not valid YAML: {e}")
            return 1
        if not isinstance(lock, dict):
            print(f"FAIL {self.lock_label}: -: -: not a mapping")
            return 1
        self.check_exceptions(lock)
        self.check_required(lock)
        self.check_versions(lock)
        for path, node in walk(lock):
            if not isinstance(node, dict) or not path:
                continue
            if path[0] == "firstPartyImages" or path[0] == "hostTooling":
                continue
            if "digest" in node:
                self.check_image(path, node)
            elif "commit" in node:
                self.check_git(path, node)
            elif "tag" in node and not (len(path) >= 3 and path[1] == "schema"):
                self.fail(keyfmt(path), s(node.get("repository")) + ":" + s(node.get("tag")),
                          "pinned by tag only — an image needs its digest, a release its commit")
        self.check_schema(lock)
        self.check_plugins(lock)
        self.check_kind_node(lock)
        self.check_allocator(lock)
        self.check_go(lock)
        self.check_first_party(lock)
        self.check_host_tooling(lock)
        workers = int(os.environ.get("PINS_JOBS", "8"))
        with cf.ThreadPoolExecutor(max_workers=workers) as ex:
            for fut in [ex.submit(j) for j in self.jobs]:
                fut.result()
        for name in self.pending:
            print(f"pending: {name} — Dockerfile absent")
        for line in self.failures:
            print(line)
        if self.failures:
            print(f"verify-pins: FAILED — {len(self.failures)} failure(s), {len(self.jobs)} registry/repository lookups, "
                  f"{len(self.pending)} pending ({self.lock_label})")
            return 1
        print(f"verify-pins: OK — {len(self.jobs)} registry/repository lookups resolved, {len(self.pending)} pending"
              f"{', host tooling checked' if self.host_tooling else ''} ({self.lock_label})")
        return 0


# --------------------------------------------------------------------------------------------
# resolve: fill unresolved fields from registries/repositories/the tree/the host, via yq


def yq_path(path: list) -> str:
    out = ""
    for p in path:
        out += f"[{p}]" if isinstance(p, int) else "." + (p if re.match(r"^[A-Za-z_]\w*$", p) else f'"{p}"')
    return out


class ResolveFailed(Exception):
    pass


class Resolve:
    def __init__(self, lock_path: str, root: str, host_tooling: bool):
        self.lock_path, self.root, self.host_tooling = lock_path, root, host_tooling
        self.res = Resolver()
        self.updates: list[tuple[list, str]] = []
        self.problems: list[str] = []

    def set(self, path, value, current):
        if s(current) != value:
            self.updates.append((path, value))
            print(f"resolved {keyfmt(path)} = {value}")

    def unresolved(self, path, why):
        self.problems.append(f"UNRESOLVED {keyfmt(path)}: {why}")

    def walk_idx(self, node, path=None):
        path = path or []
        yield path, node
        if isinstance(node, dict):
            for k, v in node.items():
                if isinstance(v, (dict, list)):
                    yield from self.walk_idx(v, path + [k])
        elif isinstance(node, list):
            for i, v in enumerate(node):
                if isinstance(v, (dict, list)):
                    yield from self.walk_idx(v, path + [i])

    def image(self, path, node, repo_key):
        repo = s(node.get(repo_key))
        tag = s(node.get("tag"))
        if not tag and node.get("track"):
            tag = self.track_to_tag(path, repo, s(node.get("track")))
            if tag:
                self.set(path + ["tag"], tag, node.get("tag"))
        if not repo or not tag:
            return
        digest = s(node.get("digest"))
        if not digest:
            ok, got = self.res.image_tag_digest(repo, tag)
            if not ok:
                self.unresolved(path + ["digest"], f"{repo}:{tag}: {got}")
                return
            digest = got
            self.set(path + ["digest"], digest, node.get("digest"))
        if "pinned" in node:
            self.set(path + ["pinned"], f"{repo}:{tag}@{digest}", node.get("pinned"))

    def track_to_tag(self, path, repo, track):
        """Resolve a floating line (e.g. node's 20-alpine) to the exact release tag the registry
        currently serves under it: the highest MAJOR.MINOR.PATCH tag of that line with the same
        manifest digest."""
        ok, dig = self.res.image_tag_digest(repo, track)
        if not ok:
            self.unresolved(path + ["tag"], f"{repo}:{track}: {dig}")
            return None
        m = re.match(r"^(\d+)(?:\.(\d+))?(-.*)?$", track)
        if not m:
            self.unresolved(path + ["tag"], f"cannot read the version line of track {track}")
            return None
        prefix = m.group(1) + ("." + m.group(2) if m.group(2) else "")
        suffix = m.group(3) or ""
        rx = re.compile(rf"^{re.escape(prefix)}(\.\d+)+{re.escape(suffix)}$")
        cands = [t for t in self.res.image_tags(repo) if rx.match(t) and EXACT_TAG_RE.match(t)]
        cands.sort(key=lambda t: [int(x) for x in re.findall(r"\d+", t.removesuffix(suffix))], reverse=True)
        for t in cands[:12]:
            ok, d = self.res.image_tag_digest(repo, t)
            if ok and d == dig:
                return t
        self.unresolved(path + ["tag"], f"no exact tag of {repo} shares the digest of {track} ({dig})")
        return None

    def run(self) -> int:
        with open(self.lock_path) as f:
            lock = yaml.safe_load(f)
        go, tc = read_go_mod(self.root)
        if go:
            gt = lock.get("goToolchain") or {}
            if not s(gt.get("go")):
                self.set(["goToolchain", "go"], go, gt.get("go"))
            elif s(gt.get("go")) != go:
                print(f"note: goToolchain.go {gt.get('go')} differs from go.mod {go}; clear it to re-record")
            if not s(gt.get("toolchain")):
                self.set(["goToolchain", "toolchain"], tc, gt.get("toolchain"))
            elif s(gt.get("toolchain")) != tc:
                print(f"note: goToolchain.toolchain {gt.get('toolchain')} differs from go.mod {tc}; clear it to re-record")
            tc_rec = s(gt.get("toolchain")) or tc
        else:
            tc_rec = ""
        # golang base tags derive from the recorded toolchain (data-model.md §26)
        for i, e in enumerate(lock.get("firstPartyImages") or []):
            for j, fr in enumerate(e.get("from") or []):
                if normalize_image_repo(s(fr.get("ref"))) == "docker.io/library/golang" and not s(fr.get("tag")) and tc_rec:
                    fr["tag"] = tc_rec.removeprefix("go") + "-alpine"
                    self.set(["firstPartyImages", i, "from", j, "tag"], fr["tag"], "")
        # git commits and release assets first (kind's node image depends on kind's commit)
        for path, node in self.walk_idx(lock):
            if not isinstance(node, dict) or not path or path[0] in ("firstPartyImages", "hostTooling"):
                continue
            if "commit" in node and node.get("tag") and not s(node.get("commit")):
                ok, got = self.res.tag_commit(s(node.get("repository")), s(node["tag"]))
                if ok:
                    node["commit"] = got
                    self.set(path + ["commit"], got, "")
                else:
                    self.unresolved(path + ["commit"], got)
            if "assetSha256" in node and not s(node.get("assetSha256")):
                ok, got = self.res.release_asset_sha(s(node.get("repository")), s(node.get("tag")),
                                                     s(node.get("checksumFile")), s(node.get("asset")))
                if ok:
                    self.set(path + ["assetSha256"], got, "")
                else:
                    self.unresolved(path + ["assetSha256"], got)
        kn = get(lock, "platform.kind.nodeImage")
        if isinstance(kn, dict) and kn.get("source") == "kind-default" and not s(kn.get("digest")):
            commit = s(get(lock, "platform.kind.release.commit"))
            ok, got = self.res.kind_default_node_image(commit) if commit else (False, "kind commit unresolved")
            if ok:
                tag, digest = got.split("@")
                kn["tag"], kn["digest"] = tag, digest
                self.set(["platform", "kind", "nodeImage", "tag"], tag, "")
                self.set(["platform", "kind", "nodeImage", "digest"], digest, "")
            else:
                self.unresolved(["platform", "kind", "nodeImage"], got)
        for path, node in self.walk_idx(lock):
            if not isinstance(node, dict) or not path or path[0] == "hostTooling":
                continue
            if path[0] == "firstPartyImages":
                if len(path) == 4 and path[2] == "from":
                    self.image(path, node, "ref")
                continue
            if "digest" in node:
                self.image(path, node, "repository")
        for i, p in enumerate(get(lock, "observability.grafanaPlugins") or []):
            if p.get("id") and p.get("version") and not s(p.get("sha256")):
                ok, got = self.res.grafana_plugin_sha(s(p["id"]), s(p["version"]))
                if ok:
                    self.set(["observability", "grafanaPlugins", i, "sha256"], got, "")
                else:
                    self.unresolved(["observability", "grafanaPlugins", i, "sha256"], got)
        # dependency locks: always computed from the tree
        for i, e in enumerate(lock.get("firstPartyImages") or []):
            for j, d in enumerate(e.get("dependencyLocks") or []):
                full = os.path.join(self.root, s(d.get("path")))
                if os.path.isfile(full):
                    self.set(["firstPartyImages", i, "dependencyLocks", j, "sha256"], sha256_file(full), d.get("sha256"))
                else:
                    self.unresolved(["firstPartyImages", i, "dependencyLocks", j, "sha256"], f"{d.get('path')} not in the tree")
        # the browser-automation package version: recorded from its lock file
        ba = get(lock, "hostTooling.browserAutomation") or {}
        if ba.get("package") and ba.get("lockFile") and os.path.isfile(os.path.join(self.root, s(ba["lockFile"]))):
            lver, _ = uvlock_package(os.path.join(self.root, s(ba["lockFile"])), s(ba["package"]))
            if lver:
                self.set(["hostTooling", "browserAutomation", "version"], lver, ba.get("version"))
            else:
                self.unresolved(["hostTooling", "browserAutomation", "version"], f"{ba['package']} not in {ba['lockFile']}")
        if self.host_tooling:
            self.resolve_host(lock)
        self.apply()
        for p in self.problems:
            print(p)
        print(f"resolve-pins: {len(self.updates)} field(s) written, {len(self.problems)} left unresolved ({self.lock_path})")
        return 1 if self.problems else 0

    def resolve_host(self, lock):
        ba = get(lock, "hostTooling.browserAutomation") or {}
        pkg, browser = s(ba.get("package")), s(ba.get("browser")) or "chromium"
        inst, sp = installed_package_version(self.root, pkg)
        lver = s(ba.get("version"))
        if ba.get("lockFile") and os.path.isfile(os.path.join(self.root, s(ba["lockFile"]))):
            lver = uvlock_package(os.path.join(self.root, s(ba["lockFile"])), pkg)[0] or lver
        if not inst:
            self.unresolved(["hostTooling", "browserAutomation", "browserRevision"], f"{pkg} not installed in the tier's virtualenv")
        elif inst != lver:
            self.unresolved(["hostTooling", "browserAutomation", "browserRevision"],
                            f"installed {pkg} {inst} is not the locked {lver}; install the locked version first")
        else:
            rev = package_browser_revision(sp, browser)
            if rev:
                self.set(["hostTooling", "browserAutomation", "browserRevision"], rev, ba.get("browserRevision"))
            else:
                self.unresolved(["hostTooling", "browserAutomation", "browserRevision"], f"{pkg} states no {browser} revision")
        for i, c in enumerate(get(lock, "hostTooling.capture") or []):
            obs, where = probe_tool_version(s(c.get("tool")))
            if obs:
                self.set(["hostTooling", "capture", i, "version"], obs, c.get("version"))
            else:
                self.unresolved(["hostTooling", "capture", i, "version"], where)

    def apply(self):
        if not self.updates:
            return
        if not shutil.which("yq"):
            raise ResolveFailed("yq (mikefarah v4) is required to write the lock file preserving comments")
        for path, value in self.updates:
            env = {**os.environ, "PINS_VALUE": value}
            expr = f"{yq_path(path)} = strenv(PINS_VALUE)"
            rc, _, err = run(["yq", "-i", expr, self.lock_path], env=env)
            if rc != 0:
                raise ResolveFailed(f"yq failed on {expr}: {short_err(err)}")


def main() -> int:
    ap = argparse.ArgumentParser(prog="pins.py")
    ap.add_argument("mode", choices=["verify", "resolve"])
    ap.add_argument("--lock")
    ap.add_argument("--root")
    ap.add_argument("--no-pending", action="store_true")
    ap.add_argument("--host-tooling", action="store_true")
    a = ap.parse_args()
    root = os.path.abspath(a.root or os.getcwd())
    lock = os.path.abspath(a.lock) if a.lock else os.path.join(root, "versions.lock.yaml")
    if a.mode == "verify":
        return Verifier(lock, root, a.no_pending, a.host_tooling).run()
    try:
        return Resolve(lock, root, a.host_tooling).run()
    except ResolveFailed as e:
        print(f"resolve-pins: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
