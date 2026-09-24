#!/usr/bin/env bash
# verify_vocabulary.sh — the vocabulary scan of `make verify-boundaries` (T142; SC-033,
# FR-083, FR-084, FR-085, FR-026, FR-027, FR-028; contracts/construct-vocabulary.md §1, §2, §7;
# quickstart §14, §22).
#
# One vocabulary everywhere: every operator-facing surface names the four constructs — vlan,
# mac-vrf, ip-vrf, acl — and a retired service name (VPLS, VPWS, E-Line, L3VPN, L2L3-IRB,
# EVPN-VPWS) appears only as a LABELLED migration alias or provenance. Each finding names its
# file and line: `FAIL [<surface>] <file>:<line>: …`.
#
# Surfaces, each scanned under --root:
#   prompts      agents/supervisors/provisioning/suggested_prompts.json — the six shapes; every
#                prompt's construct is one of the four and named in its text; zero retired names
#                (labels do not excuse a hit here: a suggestion is an offer).
#   refusals     the strings refusals are built from: agents/common/guards/*.py,
#                agents/supervisors/provisioning/{prompts/*.md,*.py,graph/*.py},
#                deploy/agents/supervisor-prompts.yaml, agents/provisioning/{mapper,allocator,
#                deployer}/*.py and catalogue files, deploy/agents/mapper-catalogue.yaml, and the
#                Go refusal producers pkg/migration/*.go, internal/webhook/*.go,
#                controllers/{network,migration}/*.go (tests excluded). A hit passes only in a
#                labelled context — the line itself or one of the 8 lines above it says alias /
#                migration / provenance / historical / retired / arrived / arrival / source
#                (the recorded arrival vocabulary is provenance by definition).
#   ui           the chat surface: ui/src/** and, when built, ui/dist/** (the bundle). Zero
#                retired names — the chat surface has no migration context.
#   docs         README.md, TUTORIAL.md, docs/**/*.md, examples/**/*.md: a hit passes only when
#                its own line, or the nearest Markdown heading above it, is labelled as above.
#   dashboards   every Grafana dashboard JSON (deploy/**/dashboards/*.json): zero retired names.
#   reporting    how pre-vocabulary services are reported: agents/provisioning/deployer/status.py
#                and pkg/fabricapi/construct.go by the labelled rule of `refusals`; and, run, the
#                read-time derivation tests — `go test ./pkg/fabricapi -run TestConstruct` (a
#                retired stored type reported by its construct, its vocabulary as provenance, the
#                record never written) and, where the tier's environment exists, the Python twin
#                agents/tests/unit/test_status_construct.py. "no tests to run" is a failure.
#   nearest      refusals offer the nearest construct BY ITS CONSTRUCT NAME: the translator CLI
#                built from ./cmd/migration-translator is run on the refusal fixtures —
#                refuse_unknown_construct lists the four construct names in contract order;
#                refuse_wrong_var_l2vni_on_vlan and refuse_wrong_var_gateway_on_ipvrf name
#                mac-vrf, the construct that carries the variable; no cause names a retired name;
#                and the guards' CONSTRUCTS tuple is exactly the four in order.
#
# Files under a migrations/ directory (examples/migrations/: MigrationPlan provenance records)
# are a labelled migration context in their entirety and are not scanned.
#
# Usage: verify_vocabulary.sh [--root <dir>] [--no-run] [--no-derivation-tests]
#   --no-run               skip both run checks (reporting's tests, nearest's translator)
#   --no-derivation-tests  skip reporting's go/pytest run only — for the fixture suite
#                          tests/unit/verifyvocabulary/, whose planted trees hold no Go module
#                          and which drives `nearest` with a fake VOCAB_TRANSLATOR.
# Env:  VOCAB_TRANSLATOR=<binary>  use this translator instead of building one.
# Exit: 0 no finding; 1 findings; 2 usage.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../.." && pwd)"
RUN=1
DERIV=1
while (($#)); do
  case "$1" in
    --root) ROOT="$(cd -- "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
    --no-run) RUN=0; shift ;;
    --no-derivation-tests) DERIV=0; shift ;;
    *) echo "usage: verify_vocabulary.sh [--root <dir>] [--no-run] [--no-derivation-tests]" >&2; exit 2 ;;
  esac
done
command -v python3 >/dev/null || { echo "verify_vocabulary: python3 is required" >&2; exit 2; }

findings=0
fail() { echo "FAIL [$1] $2"; findings=$((findings + 1)); }

# --- the static surfaces --------------------------------------------------------------------
static_out="$(python3 - "$ROOT" <<'PY'
import json, pathlib, re, sys

root = pathlib.Path(sys.argv[1])
RETIRED = re.compile(r"\b(vpls|vpws|e-?line|l3vpn|l2l3-?irb|evpn-vpws)\b", re.IGNORECASE)
LABEL = re.compile(r"alias|migration|provenance|historical|history|retired|arrived|arrival|\bsource",
                   re.IGNORECASE)
HEADING = re.compile(r"^\s{0,3}#{1,6}\s")
CONSTRUCTS = ("vlan", "mac-vrf", "ip-vrf", "acl")
SHAPES = {"vlan", "mac-vrf", "ip-vrf", "gateway", "acl", "acl-on-service"}
SKIP_DIRS = {"node_modules", ".venv", "__pycache__", ".git", "migrations"}
out = []
counts = {}


def fail(surface, path, line, msg):
    out.append(f"FAIL [{surface}] {path.relative_to(root)}:{line}: {msg}")


def files(patterns):
    seen = []
    for pattern in patterns:
        for p in sorted(root.glob(pattern)):
            if not p.is_file() or set(p.relative_to(root).parts) & SKIP_DIRS:
                continue
            if p.name.endswith(("_test.go", ".test.ts", ".test.tsx")) or p.name.startswith("test_"):
                continue
            if p not in seen:
                seen.append(p)
    return seen


def lines(p):
    try:
        return p.read_text(encoding="utf-8").splitlines()
    except (UnicodeDecodeError, OSError):
        return []


def strict(surface, paths):
    counts[surface] = len(paths)
    for p in paths:
        for i, line in enumerate(lines(p), 1):
            m = RETIRED.search(line)
            if m:
                fail(surface, p, i, f"retired service name {m.group(0)!r} on an operator surface that has no migration context")


def labelled_code(surface, paths):
    counts[surface] = counts.get(surface, 0) + len(paths)
    for p in paths:
        text = lines(p)
        for i, line in enumerate(text, 1):
            m = RETIRED.search(line)
            if m and not any(LABEL.search(t) for t in text[max(0, i - 9):i]):
                fail(surface, p, i, f"retired service name {m.group(0)!r} outside a labelled migration-alias/provenance context")


def labelled_docs(surface, paths):
    counts[surface] = len(paths)
    for p in paths:
        heading, fenced = "", False
        for i, line in enumerate(lines(p), 1):
            if line.lstrip().startswith("```"):
                fenced = not fenced
            if not fenced and HEADING.match(line):
                heading = line
            m = RETIRED.search(line)
            if m and not (LABEL.search(line) or LABEL.search(heading)):
                fail(surface, p, i, f"retired service name {m.group(0)!r} not identified as a migration alias or provenance (FR-085)")


# prompts
sp = root / "agents/supervisors/provisioning/suggested_prompts.json"
counts["prompts"] = 1
if not sp.is_file():
    out.append("FAIL [prompts] agents/supervisors/provisioning/suggested_prompts.json: missing")
else:
    try:
        entries = json.loads(sp.read_text(encoding="utf-8"))["prompts"]
    except (ValueError, KeyError, TypeError) as e:
        entries = []
        fail("prompts", sp, 1, f"not a suggestion document: {e}")
    shapes = {e.get("shape") for e in entries if isinstance(e, dict)}
    if entries and shapes != SHAPES:
        fail("prompts", sp, 1, f"shapes {sorted(s for s in shapes if s)} are not the six of the contract {sorted(SHAPES)}")
    for n, e in enumerate(entries):
        text, construct = str(e.get("prompt", "")), e.get("construct")
        where = next((i for i, l in enumerate(lines(sp), 1) if text and text in l), 1)
        if construct not in CONSTRUCTS:
            fail("prompts", sp, where, f"prompts[{n}] construct {construct!r} is not one of {', '.join(CONSTRUCTS)}")
        elif construct not in re.findall(r"[a-z0-9-]+", text.lower()):
            fail("prompts", sp, where, f"prompts[{n}] does not name its construct {construct!r}")
    for i, line in enumerate(lines(sp), 1):
        m = RETIRED.search(line)
        if m:
            fail("prompts", sp, i, f"retired service name {m.group(0)!r} in a suggestion")

REPORTING = files(["agents/provisioning/deployer/status.py", "pkg/fabricapi/construct.go"])
labelled_code("refusals", [p for p in files([
    "agents/common/guards/*.py",
    "agents/supervisors/provisioning/*.py", "agents/supervisors/provisioning/graph/*.py",
    "agents/supervisors/provisioning/prompts/*.md", "deploy/agents/supervisor-prompts.yaml",
    "agents/provisioning/mapper/*.py", "agents/provisioning/mapper/*.json",
    "agents/provisioning/allocator/*.py", "agents/provisioning/deployer/*.py",
    "deploy/agents/mapper-catalogue.yaml",
    "pkg/migration/*.go", "internal/webhook/*.go",
    "controllers/network/*.go", "controllers/migration/*.go",
]) if p not in REPORTING])
strict("ui", files(["ui/src/**/*", "ui/dist/**/*", "ui/index.html"]))
labelled_docs("docs", files(["README.md", "TUTORIAL.md", "docs/**/*.md", "examples/**/*.md"]))
strict("dashboards", files(["deploy/**/dashboards/*.json", "deploy/**/grafana/**/*.json"]))
labelled_code("reporting", REPORTING)

# the guards' construct list, in contract order
rp = root / "agents/common/guards/refusals.py"
if rp.is_file():
    m = re.search(r"^CONSTRUCTS[^=]*=\s*\(([^)]*)\)", rp.read_text(encoding="utf-8"), re.MULTILINE)
    got = tuple(re.findall(r'"([^"]+)"', m.group(1))) if m else ()
    if got != CONSTRUCTS:
        fail("nearest", rp, 1, f"refusal CONSTRUCTS {got} is not {CONSTRUCTS} in contract order")

for line in out:
    print(line)
print("SCANNED " + " ".join(f"{k}={v}" for k, v in counts.items()))
PY
)"
while IFS= read -r line; do
  case "$line" in
    FAIL*) echo "$line"; findings=$((findings + 1)) ;;
    SCANNED*) echo "verify_vocabulary: ${line#SCANNED } files" ;;
  esac
done <<<"$static_out"

# --- the run checks ---------------------------------------------------------------------------
if ((RUN)); then
  cd "$ROOT"
  if ((DERIV)); then
  go_out="$(go test ./pkg/fabricapi -run 'TestConstruct' -count=1 -v 2>&1)" && go_rc=0 || go_rc=$?
  if ((go_rc != 0)) || grep -q 'no tests to run' <<<"$go_out" || ! grep -q '^--- PASS: TestConstructIsDerivedAtReadTimeFromTheStoredRecord' <<<"$go_out"; then
    fail reporting "pkg/fabricapi/construct_test.go: read-time construct derivation did not pass (rc=$go_rc)"
    tail -20 <<<"$go_out" | sed 's/^/  /'
  else
    echo "verify_vocabulary: reporting — $(grep -c '^--- PASS' <<<"$go_out") pkg/fabricapi TestConstruct* PASS"
  fi
  if [[ -x agents/.venv/bin/python ]]; then
    py_out="$(cd agents && .venv/bin/python -m pytest -q tests/unit/test_status_construct.py 2>&1)" && py_rc=0 || py_rc=$?
    if ((py_rc != 0)); then
      fail reporting "agents/tests/unit/test_status_construct.py: pre-vocabulary reporting did not pass (rc=$py_rc)"
      tail -20 <<<"$py_out" | sed 's/^/  /'
    else
      echo "verify_vocabulary: reporting — agents/tests/unit/test_status_construct.py $(tail -1 <<<"$py_out")"
    fi
  else
    echo "verify_vocabulary: reporting — Python twin not run here (no agents/.venv); make test-agents runs it"
  fi
  fi

  tr="${VOCAB_TRANSLATOR:-}"
  if [[ -z "$tr" ]]; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    tr="$tmp/migration-translator"
    go build -o "$tr" ./cmd/migration-translator
  fi
  fx=tests/unit/testdata/migration
  nearest() { # <fixture> <python predicate over causes> <description>
    local err
    if "$tr" --file "$fx/$1.json" >/dev/null 2>"${tmp:-/tmp}/vocab.err"; then
      fail nearest "$fx/$1.json: the translator accepted a request it must refuse"; return
    fi
    err="$(cat "${tmp:-/tmp}/vocab.err")"
    if python3 -c '
import json, re, sys
causes = json.loads(sys.argv[1])["causes"]
text = " ".join(causes)
if re.search(r"\b(vpls|vpws|e-?line|l3vpn|l2l3-?irb|evpn-vpws)\b", text, re.I):
    sys.exit(1)
sys.exit(0 if eval(sys.argv[2]) else 1)' "$err" "$2"; then
      echo "verify_vocabulary: nearest — $1: $3"
    else
      fail nearest "$fx/$1.json: refusal does not $3: $err"
    fi
  }
  nearest refuse_unknown_construct \
    're.search(r"vlan, mac-vrf, ip-vrf, acl", text) is not None' \
    "list the four construct names in contract order"
  nearest refuse_wrong_var_l2vni_on_vlan '"mac-vrf" in text' "offer mac-vrf by its construct name"
  nearest refuse_wrong_var_gateway_on_ipvrf '"mac-vrf" in text' "offer mac-vrf by its construct name"
fi

if ((findings)); then
  echo "verify_vocabulary: FAIL — $findings finding(s)"
  exit 1
fi
echo "verify_vocabulary: PASS — one vocabulary on every operator-facing surface (SC-033)"
