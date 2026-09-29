#!/usr/bin/env python3
"""credential_scan.py — the checks behind scripts/ci/credential_scan.sh (T147; SC-031, SC-050,
FR-079, NFR-014, R-38). Invoke it through the shell script; its usage is documented there.

Two subcommands, stdlib only (no tier virtualenv needed):

  scan  [--secrets-from-file F]... [--secret-env NAME]... [--max-violations N] PATH...
        The credential scan. The pattern set is the tier's ONE FR-079 list,
        agents/common/guards/redaction.py, loaded by file path (never copied): a hit is exactly
        a span its ``redact`` would change (the semantics of ``find_credentials``), plus a JSON key
        its ``redact_mapping`` treats as a credential carrying a non-redacted string value, plus any
        exact known secret value. Every redaction marker the tier writes — ``***`` (Python,
        scripts/lib/intent_secrets.sh), ``[REDACTED]`` and its URL-escaped form ``%5BREDACTED%5D``
        (Go, internal/telemetry/jsonlog) — is a redacted value, never a hit. A hit is reported as
        ``<file>:<line>: <pattern name>``; the matched text is NEVER printed.

  shape [--expect-workloads a,b,...] [--max-violations N] DIR
        The NFR-014 log shape (data-model.md §27) of DIR/<workload>[@<pod>][.previous].log[.gz].
"""

from __future__ import annotations

import argparse
import base64
import gzip
import importlib.util
import json
import os
import re
import sys
import urllib.parse
from collections.abc import Iterator
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
REDACTION_PY = Path(os.environ.get("CREDENTIAL_SCAN_REDACTION_PY",
                                   ROOT / "agents" / "common" / "guards" / "redaction.py"))


def usage_error(message: str) -> None:
    """A usage or input error: exit 2, never a verdict."""
    print(message, file=sys.stderr)
    sys.exit(2)


def _load_redaction() -> Any:
    spec = importlib.util.spec_from_file_location("_fr079_redaction", REDACTION_PY)
    if spec is None or spec.loader is None:
        usage_error(f"credential-scan: cannot load the FR-079 pattern set from {REDACTION_PY}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


R = _load_redaction()
MARKER: str = R.MARKER
# The other markers the tier writes, folded to MARKER before scanning (Go jsonlog.Redacted and
# what net/url makes of it inside userinfo).
MARKER_VARIANTS = re.compile(r"\[REDACTED\]|%5BREDACTED%5D", re.IGNORECASE)

# ------------------------------------------------------------------------------------ input
def iter_files(paths: list[str]) -> Iterator[Path]:
    for p in paths:
        path = Path(p)
        if path.is_dir():
            yield from sorted(f for f in path.rglob("*") if f.is_file())
        elif path.is_file():
            yield path
        else:
            usage_error(f"credential-scan: no such file or directory: {p}")


def read_text(path: Path) -> str | None:
    """The file's text (gunzipped when .gz); None for a binary file."""
    raw = path.read_bytes()
    if path.suffix == ".gz" or raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    if b"\x00" in raw[:8192]:
        return None
    return raw.decode("utf-8", "replace")


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


# --------------------------------------------------------------------------- credential scan
# A credential-named field whose VALUE is not a credential (live-findings 2026-09-26-t151r7,
# decision listed under AD-82): an absent value (None/null/false/empty), a nested object or a
# reference (`secret: {secretName: …}`, `${VAR}`) and a YANG module or identity name
# (`aaa-password:srl_nokia-aaa-password`, `urn:…`). Everything else a pattern matches is a hit —
# a device account's password hash included: evidence writers redact it at capture
# (live-findings 2026-09-25-leftover-scan-redaction). redact() is unchanged.
_BENIGN_VALUE = re.compile(
    r"""^(?:none|null|nil|true|false|-|)$"""
    r"""|^[{\[]|^\$\{|^\$\("""
    r"""|^(?:urn:|srl_nokia-|ietf-|openconfig-|iana-)""",
    re.IGNORECASE,
)
_PAIR_VALUE = re.compile(r"""[=:]\s*["']?(.*)$""", re.DOTALL)


# A code reference to the credential rather than its value — `api_key=endpoint.api_key` in a
# source line of an exception's stack trace: a dotted attribute path whose last part is itself a
# credential name.
_CODE_REF = re.compile(r"^[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+\)?$")
_CRED_TAIL = re.compile(r"(?i)(?:^|[._])" + R._CRED_NAME + r"\)?$")


def benign(name: str, matched: str) -> bool:
    """True for a credential-pair or credential-key match whose value is not a credential."""
    if name == "credential-pair":
        m = _PAIR_VALUE.search(matched)
        if not m:
            return False
        value = m.group(1).strip()
        return bool(_BENIGN_VALUE.search(value)
                    or (_CODE_REF.search(value) and _CRED_TAIL.search(value)))
    if name.startswith("credential-key"):
        return bool(_BENIGN_VALUE.search(matched.strip()))
    return False


def pattern_hits(text: str) -> list[tuple[int, str]]:
    """``find_credentials`` with positions: (line, pattern name) per span ``redact`` would change.

    Each pattern runs on the text the previous ones left, exactly as ``redact`` does; a replaced
    span keeps its newlines so later line numbers stay true (a PEM block collapses otherwise).
    """
    hits: list[tuple[int, str]] = []
    for name, pattern, replacement in R._PATTERNS:  # the one FR-079 list
        out: list[str] = []
        pos = 0
        for m in pattern.finditer(text):
            new = m.expand(replacement)
            if new != m.group(0) and not benign(name, m.group(0)):
                hits.append((line_of(text, m.start()), name))
                new += "\n" * max(0, m.group(0).count("\n") - new.count("\n"))
            out.append(text[pos:m.start()])
            out.append(new)
            pos = m.end()
        out.append(text[pos:])
        text = "".join(out)
    return hits


def _walk_json(value: Any, path: str = "") -> Iterator[tuple[str, Any]]:
    if isinstance(value, dict):
        for k, v in value.items():
            yield str(k), v
            yield from _walk_json(v, f"{path}.{k}")
    elif isinstance(value, list):
        for v in value:
            yield from _walk_json(v, path)


def _key_hit(key: str, value: Any) -> bool:
    if not isinstance(value, str) or value == "" or not R._SENSITIVE_KEY.search(key):
        return False
    if benign("credential-key", value):
        return False
    return MARKER not in value  # redact_mapping would replace it: a credential left in place


def json_key_hits(text: str, path: Path) -> list[tuple[int, str]]:
    """Credential-named JSON keys with a live string value (the ``redact_mapping`` rule)."""
    hits: list[tuple[int, str]] = []
    stripped = text.lstrip()
    if path.suffix in (".json",) or path.name.endswith(".json.gz"):
        if stripped[:1] in "{[":
            try:
                doc = json.loads(text)
            except ValueError:
                doc = None
            if doc is not None:
                for key, value in _walk_json(doc):
                    if _key_hit(key, value):
                        m = re.search(r'"' + re.escape(key) + r'"\s*:', text)
                        hits.append((line_of(text, m.start()) if m else 1, f"credential-key:{key}"))
                return hits
    for n, line in enumerate(text.split("\n"), 1):
        s = line.strip()
        if not s.startswith("{"):
            continue
        try:
            obj = json.loads(s)
        except ValueError:
            continue
        for key, value in _walk_json(obj):
            if _key_hit(key, value):
                hits.append((n, f"credential-key:{key}"))
    return hits


def load_secrets(files: list[str], envs: list[str]) -> list[tuple[str, str]]:
    """(source label, value) — the label names where it came from, never what it is."""
    secrets: list[tuple[str, str]] = []
    for f in files:
        for i, line in enumerate(Path(f).read_text(encoding="utf-8").splitlines(), 1):
            value = line.rstrip("\r")
            if value.strip():
                secrets.append((f"{f}#{i}", value))
    for name in envs:
        value = os.environ.get(name, "")
        if not value:
            usage_error(f"credential-scan: --secret-env {name}: the variable is unset or empty")
        secrets.append((f"${name}", value))
    for label, value in secrets:
        if len(value) < 6:
            usage_error(f"credential-scan: known secret {label} is shorter than 6 characters; "
                             "matching it would be noise, not a check")
    return secrets


def secret_forms(value: str) -> list[str]:
    forms = {value, urllib.parse.quote(value, safe=""), urllib.parse.quote_plus(value, safe=""),
             base64.b64encode(value.encode()).decode().rstrip("=")}
    return [f for f in forms if len(f) >= 6]


def cmd_scan(args: argparse.Namespace) -> int:
    secrets = [(label, secret_forms(v)) for label, v in load_secrets(args.secrets_from_file,
                                                                     args.secret_env)]
    files = lines = 0
    skipped: list[str] = []
    hits: list[str] = []
    for path in iter_files(args.paths):
        text = read_text(path)
        if text is None:
            skipped.append(str(path))
            continue
        files += 1
        lines += text.count("\n") + (0 if text.endswith("\n") or not text else 1)
        found: list[tuple[int, str]] = []
        for label, forms in secrets:
            for form in forms:
                start = text.find(form)
                while start >= 0:
                    found.append((line_of(text, start), f"known-secret {label}"))
                    start = text.find(form, start + 1)
        folded = MARKER_VARIANTS.sub(MARKER, text)
        found += pattern_hits(folded)
        found += json_key_hits(folded, path)
        # Self-check against the module's own scan: both must agree on "any hit at all".
        own = ("known-secret", "credential-key")
        module = [(n, t) for n, t in R.find_credentials(folded) if not benign(n, t)]
        if bool(module) != any(not n.startswith(own) for _, n in found):
            print(f"credential-scan: INTERNAL disagreement with find_credentials on {path}",
                  file=sys.stderr)
            return 2
        for n, name in sorted(set(found)):
            hits.append(f"{path}:{n}: {name}")
    for s in skipped:
        print(f"credential-scan: note: binary file not scanned: {s}")
    if files == 0:
        print("credential-scan: FAIL no text file under the given path(s): zero files scanned is "
              "not zero hits")
        return 1
    for h in hits[: args.max_violations]:
        print(f"credential-scan: FAIL {h}")
    if len(hits) > args.max_violations:
        print(f"credential-scan: ... and {len(hits) - args.max_violations} more hit(s)")
    verdict = "FAIL" if hits else "PASS"
    print(f"credential-scan: {verdict} {files} file(s), {lines} line(s), "
          f"{len(secrets)} known secret(s), {len(hits)} hit(s)")
    return 1 if hits else 0


# ----------------------------------------------------------------------------- log shape
# Workload (file name) → the component its lines must carry (data-model.md §27). The
# allocation authority runs the srl-provider binary, so its lines say srl-provider.
WORKLOADS = {
    "srl-provider": "srl-provider",
    "allocation-authority": "srl-provider",
    "intent-translator": "intent-translator",
    "supervisor": "supervisor",
    "mapper": "mapper",
    "allocator": "allocator",
    "deployer": "deployer",
}
INTENT_TIER = {"supervisor", "mapper", "allocator", "deployer", "intent-translator"}
LEVELS = {"debug", "info", "warn", "error"}
TS = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|\+00:00)$")
CORRELATION_ID = re.compile(r"^[0-9a-f]{32}$")

# What makes a line part of a request (§27: "on every line of a request"). A line is inferred to
# belong to one when any of these holds; each is documented in credential_scan.sh.
PROBE_PATHS = re.compile(r"^/(?:v1/)?(?:health|healthz|livez|readyz|ready|metrics)(?:[/?]|$)")
ACCESS = re.compile(r'"(GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS) (\S+) HTTP/[\d.]+"')
CLIENT_CALL = re.compile(r"^HTTP Request: (POST|PUT|PATCH|DELETE) ")
SERVICE_ID = re.compile(r"(?<![0-9A-Za-z])[0-9a-f]{15}(?![0-9A-Za-z])")
REQUEST_MSG = re.compile(r"^model call \d+:|\battempt \d+ of \d+\b|/v1/translate\b")


def request_reason(obj: dict[str, Any]) -> str | None:
    if obj.get("thread_id"):
        return "carries thread_id"
    msg = obj.get("msg") if isinstance(obj.get("msg"), str) else ""
    m = ACCESS.search(msg)
    if m and m.group(1) not in ("GET", "HEAD", "OPTIONS") and not PROBE_PATHS.match(m.group(2)):
        return f"serves {m.group(1)} {m.group(2).split('?')[0]}"
    if CLIENT_CALL.search(msg):
        return "makes a mutating call"
    if REQUEST_MSG.search(msg):
        return "is a model call, a worker retry or a translation"
    for key, value in obj.items():
        if key in ("correlation_id", "thread_id", "ts"):
            continue
        blob = value if isinstance(value, str) else json.dumps(value) if isinstance(
            value, (list, dict)) else ""
        if SERVICE_ID.search(blob):
            return f"names a service identifier in {key}"
    return None


MASK: list[str] = []  # known-secret forms masked out of every excerpt


def excerpt(line: str) -> str:
    clean = R.redact(MARKER_VARIANTS.sub(MARKER, line))
    for form in MASK:
        clean = clean.replace(form, MARKER)
    return re.sub(r"[\x00-\x1f\x7f]", "?", clean)[:120]


def shape_violations(obj: Any, component: str) -> list[str]:
    if not isinstance(obj, dict):
        return ["not one JSON object"]
    bad: list[str] = []
    ts = obj.get("ts")
    if not isinstance(ts, str) or not TS.match(ts):
        bad.append("ts missing or not UTC RFC 3339")
    if obj.get("level") not in LEVELS:
        bad.append("level missing or not debug|info|warn|error")
    if obj.get("component") != component:
        bad.append(f"component is {obj.get('component')!r}, want {component!r}")
    if not isinstance(obj.get("msg"), str) or not obj["msg"].strip():
        bad.append("msg missing or empty")
    for key in ("kind", "namespace", "name"):
        if key in obj and not isinstance(obj[key], str):
            bad.append(f"{key} is not a string")
    if "correlation_id" in obj and not (isinstance(obj["correlation_id"], str)
                                        and CORRELATION_ID.match(obj["correlation_id"])):
        bad.append("correlation_id is not 32 lowercase hex")
    if "thread_id" in obj and component not in INTENT_TIER:
        bad.append("thread_id outside the intent tier")
    if not bad and "correlation_id" not in obj:
        why = request_reason(obj)
        if why:
            bad.append(f"request line without correlation_id (it {why})")
    return bad


LOG_NAME = re.compile(r"^(?P<workload>[a-z0-9-]+)(?:@[^/]+?)?(?:\.previous)?\.log(?:\.gz)?$")


def cmd_shape(args: argparse.Namespace) -> int:
    for _label, value in load_secrets(args.secrets_from_file, args.secret_env):
        MASK.extend(sorted(secret_forms(value), key=len, reverse=True))
    base = Path(args.dir)
    if not base.is_dir():
        print(f"log-shape: FAIL {base} is not a directory")
        return 1
    expect = [w for w in (args.expect_workloads or ",".join(WORKLOADS)).split(",") if w]
    unknown = [w for w in expect if w not in WORKLOADS]
    if unknown:
        usage_error(f"log-shape: unknown workload(s) {unknown}; known: {sorted(WORKLOADS)}")
    per: dict[str, list[int]] = {}  # workload → [files, lines, request lines, violations]
    violations: list[str] = []
    for path in sorted(base.iterdir()):
        m = LOG_NAME.match(path.name) if path.is_file() else None
        if not m:
            continue
        workload = m.group("workload")
        if workload not in WORKLOADS:
            print(f"log-shape: note: {path.name} is not a first-party workload log; "
                  "not shape-checked")
            continue
        text = read_text(path) or ""
        stats = per.setdefault(workload, [0, 0, 0, 0])
        stats[0] += 1
        lines = text.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        for n, line in enumerate(lines, 1):
            stats[1] += 1
            try:
                obj = json.loads(line)
            except ValueError:
                problems = ["not one JSON object"]
                obj = None
            else:
                problems = shape_violations(obj, WORKLOADS[workload])
            if isinstance(obj, dict) and ("correlation_id" in obj or request_reason(obj)):
                stats[2] += 1
            if problems:
                stats[3] += 1
                violations.append(f"{path}:{n}: {'; '.join(problems)} | {excerpt(line)}")
    missing = [w for w in expect if w not in per]
    for w in sorted(per):
        f, n, req, bad = per[w]
        print(f"log-shape: {w}: {f} file(s), {n} line(s), {req} request line(s), "
              f"{bad} violation(s)")
    for w in missing:
        print(f"log-shape: FAIL {w}: no log file (expected {w}.log or {w}@<pod>.log)")
    for v in violations[: args.max_violations]:
        print(f"log-shape: FAIL {v}")
    if len(violations) > args.max_violations:
        print(f"log-shape: ... and {len(violations) - args.max_violations} more violation(s)")
    total = sum(s[1] for s in per.values())
    ok = not violations and not missing
    print(f"log-shape: {'PASS' if ok else 'FAIL'} {len(per)} workload(s), {total} line(s), "
          f"{len(violations)} violation(s)")
    return 0 if ok else 1


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="credential_scan.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan")
    s.add_argument("--secrets-from-file", action="append", default=[])
    s.add_argument("--secret-env", action="append", default=[])
    s.add_argument("--max-violations", type=int, default=50)
    s.add_argument("paths", nargs="+")
    h = sub.add_parser("shape")
    h.add_argument("--expect-workloads", default="")
    h.add_argument("--max-violations", type=int, default=50)
    h.add_argument("--secrets-from-file", action="append", default=[])
    h.add_argument("--secret-env", action="append", default=[])
    h.add_argument("dir")
    args = ap.parse_args(argv)
    return cmd_scan(args) if args.cmd == "scan" else cmd_shape(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
