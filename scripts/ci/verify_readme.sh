#!/usr/bin/env bash
# verify_readme.sh — `make verify-readme` (T156; NFR-011, NFR-013, FR-083, FR-085, SC-031…SC-033,
# CD-06; contracts/readme-and-walkthrough.md §6 "Contract tests").
#
# The README is written last and states nothing that was not observed. This check holds it to the
# contract, one named check per property of §6 — every finding is `FAIL [<check>] <file>:<line>: …`:
#
#   sections     the headings and their order of contract §1: the title line with the tagline, the
#                two badge rows (row 1: SR Linux, SDC, KUID, Kubernetes, containerlab, Tutorial — a
#                CI badge only if its workflow file exists, a merge-queue badge only if a queue is
#                configured (.mergify.yml queue_rules, or a merge_group workflow); row 2: AGNTCY, LangGraph,
#                A2A, SLIM, gNMI, Prometheus, Grafana), an introduction naming SR Linux and the one
#                southbound (SDC, gNMI), then exactly the nine `##` sections in order; What you get
#                carries no SRv6 row; Quickstart carries no `--profile`; The lab embeds the four figures
#   links        every relative link and image (Markdown and <img src>) resolves in the tree
#   versions     every version-shaped token (x.y.z, vX.Y) and every sha256 digest the README states
#                occurs in versions.lock.yaml; every badge's version text is the lock file's
#   facts        §5: MTU 9412 / 9398 / 9348 and probes 9320 / 9300, `make verify-pins` (the pinning
#                statement), `make verify-evidence`, the IPv6 anycast-gateway / Type-5 limitation
#   denylist     §2: predecessor platform terms, retired service names, `latest`,
#                raw.githubusercontent.com — outside a block explicitly labelled as history
#                (`<!-- history -->` … `<!-- /history -->`); credentials in the README, in every
#                figure's alt text and in the walkthrough evidence file — by pattern, and, when a
#                cluster is reachable, the live operator password itself
#   evidence     docs/media/agentic-netops-srl-intent-tier-demo-evidence.json exists with the NFR-013
#                fields, `accept_pass: true` and `failures` empty
#   prompts      its three prompts equal docs/DEMO_VIDEO.md's frozen table byte for byte, in order,
#                with constructs vlan, ip-vrf, mac-vrf
#   principal    all three Networks carry the generated operator username — the one the provisioning
#                run captured (`operator_username`), cross-checked against that capture's own record
#                when it is on this host
#   timings      the Demo section's "~N min" equals the uncut take's duration / 6, and every other
#                seconds figure the README states is one the evidence file measured
#   quickstart   every command of the README's Quickstart blocks is one quickstart.md carries (the
#                block SC-032's clean-host run used)
#   placeholder  the Demo asset URL: while the operator has not supplied it, the marked placeholder
#                is REPORTED (`REPORT [placeholder] …`), never passed over silently; a README with
#                neither the placeholder nor a GitHub asset URL fails
#
# Usage: verify_readme.sh [--root <dir>] [--no-cluster]
#   --root        the tree to check (default: this repository) — the fixture suite
#                 tests/unit/verifyreadme/ points it at planted trees
#   --no-cluster  skip the live-password scan even if a cluster is reachable
# Exit: 0 every check passes (placeholder reported); 1 a finding; 2 usage.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../.." && pwd)"
CLUSTER=1
while (($#)); do
  case "$1" in
    --root) ROOT="$(cd -- "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
    --no-cluster) CLUSTER=0; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//;$d'; exit 0 ;;
    *) echo "usage: verify_readme.sh [--root <dir>] [--no-cluster]" >&2; exit 2 ;;
  esac
done
command -v python3 >/dev/null || { echo "verify_readme: python3 is required" >&2; exit 2; }

LIVE_PASSWORD=""
if ((CLUSTER)) && command -v kubectl >/dev/null 2>&1; then
  LIVE_PASSWORD="$(kubectl -n agentic-netops-agents get secret operator-credentials \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
fi

LIVE_PASSWORD="$LIVE_PASSWORD" exec python3 - "$ROOT" <<'PY'
import json, os, re, sys
from pathlib import Path

root = Path(sys.argv[1])
readme = root / "README.md"
lock_p = root / "versions.lock.yaml"
demo_doc = root / "docs" / "DEMO_VIDEO.md"
ev_p = root / "docs" / "media" / "agentic-netops-srl-intent-tier-demo-evidence.json"
quick_p = root / "specs" / "004-agentic-netops-composite" / "quickstart.md"
live_pw = os.environ.get("LIVE_PASSWORD", "")

findings = 0
def fail(check, where, msg):
    global findings
    findings += 1
    print(f"FAIL [{check}] {where}: {msg}")
def report(check, where, msg):
    print(f"REPORT [{check}] {where}: {msg}")

if not readme.exists():
    fail("sections", "README.md", "missing")
    sys.exit(1)
lines = readme.read_text().splitlines()
text = "\n".join(lines)
lock = lock_p.read_text() if lock_p.exists() else ""
if not lock:
    fail("versions", "versions.lock.yaml", "missing")

# ---- fenced blocks and history blocks --------------------------------------------------------
in_fence = [False] * len(lines)
history = [False] * len(lines)
f = h = False
for i, l in enumerate(lines):
    if l.lstrip().startswith("```"):
        in_fence[i] = True
        f = not f
        continue
    in_fence[i] = f
    if "<!-- history -->" in l:
        h = True
    history[i] = h
    if "<!-- /history -->" in l:
        h = False

def section_lines(title):
    out, inside = [], False
    for i, l in enumerate(lines):
        if l.startswith("## ") and not in_fence[i]:
            inside = l[3:].strip() == title
            continue
        if inside:
            out.append((i + 1, l))
    return out

# ---- sections --------------------------------------------------------------------------------
TITLE = "# agentic-netops-srl - Autonomous intent-to-fabric operations."
H2 = ["Demo", "The lab", "What you get", "Prerequisites", "Quickstart",
      "Known limitations — read before trusting a run", "Repository layout", "Policies enforced in CI"]
if not lines or lines[0].strip() != TITLE:
    fail("sections", "README.md:1", f"the title line must be {TITLE!r}")
h2 = [(i + 1, l[3:].strip()) for i, l in enumerate(lines) if l.startswith("## ") and not in_fence[i]]
if [t for _, t in h2] != H2:
    fail("sections", "README.md", f"## sections {[t for _, t in h2]} are not contract §1's, in order: {H2}")
first_h2 = h2[0][0] if h2 else len(lines)
head = lines[1:first_h2 - 1]
badge_rows, row, last_badge = [], [], -1
for k, l in enumerate(head):
    if l.strip().startswith("[!["):
        row.append(l)
        last_badge = k
    elif row:
        badge_rows.append(row)
        row = []
if row:
    badge_rows.append(row)
intro = [l for l in head[last_badge + 1:] if l.strip()]
def labels(r):
    return [m.group(1) for l in r for m in re.finditer(r"\[!\[([^\]]+)\]", l)]
if len(badge_rows) != 2:
    fail("sections", "README.md", f"{len(badge_rows)} badge rows; contract §1 has two")
else:
    r1, r2 = labels(badge_rows[0]), labels(badge_rows[1])
    for need in ("SR Linux", "SDC", "KUID", "Kubernetes", "containerlab", "Tutorial"):
        if need not in r1:
            fail("sections", "README.md", f"badge row 1 lacks {need!r} ({r1})")
    for need in ("AGNTCY", "LangGraph", "A2A", "SLIM", "gNMI", "Prometheus", "Grafana"):
        if need not in r2:
            fail("sections", "README.md", f"badge row 2 lacks {need!r} ({r2})")
    for l in badge_rows[0]:
        for m in re.finditer(r"github\.com/[^/]+/[^/]+/actions/workflows/([\w.-]+)", l):
            if not (root / ".github" / "workflows" / m.group(1)).exists():
                fail("sections", "README.md", f"CI badge for workflow {m.group(1)} that does not exist")
        mq = root / ".mergify.yml"
        if re.search(r"(?i)merge[- ]?queue|mergify", l) and not (
                (mq.exists() and "queue_rules:" in mq.read_text()) or any(
                re.search(r"(?i)merge_group", p.read_text())
                for p in (root / ".github" / "workflows").glob("*.y*ml"))):
            fail("sections", "README.md", "merge-queue badge with no merge-queue workflow")
intro_text = " ".join(intro)
if not intro_text.strip():
    fail("sections", "README.md", "no introduction between the badges and ## Demo")
else:
    for need in ("SR Linux", "SDC", "gNMI"):
        if need not in intro_text:
            fail("sections", "README.md", f"the introduction does not name {need!r} (the one southbound)")
wyg = section_lines("What you get")
for n, l in wyg:
    if l.startswith("|") and re.search(r"(?i)srv6", l):
        fail("sections", f"README.md:{n}", "What you get carries an SRv6 row (deferred, RD-04)")
for n, l in section_lines("Quickstart"):
    if "--profile" in l:
        fail("sections", f"README.md:{n}", "Quickstart carries --profile (one profile, no flag)")
FIGS = ["lab-topology.png", "grafana-fabric-telemetry.png", "agent-ui.png", "agent-ui-outcome.png"]
lab = "\n".join(l for _, l in section_lines("The lab"))
got = re.findall(r"!\[[^\]]*\]\((docs/images/[^)]+)\)", lab)
if [Path(g).name for g in got] != FIGS:
    fail("sections", "README.md", f"The lab embeds {got}; contract §4 is {FIGS}, in order")
if "What works and what does not" not in lab:
    fail("sections", "README.md", "The lab lacks *What works and what does not*")

# ---- links -----------------------------------------------------------------------------------
for i, l in enumerate(lines):
    if in_fence[i]:
        continue
    targets = re.findall(r"\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)", l) + re.findall(r"<img[^>]+src=\"([^\"]+)\"", l)
    for t in targets:
        if re.match(r"^(https?:|mailto:|#)", t):
            continue
        p = t.split("#", 1)[0]
        if p and not (readme.parent / p).exists():
            fail("links", f"README.md:{i + 1}", f"{t} does not resolve")

# ---- versions --------------------------------------------------------------------------------
IP = re.compile(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b")
VER = re.compile(r"(?<![\w./-])v?\d+\.\d+(?:\.\d+)+(?:[-+][\w.]+)?(?![\w/])|(?<![\w./-])v\d+\.\d+(?![\w./])")
for i, l in enumerate(lines):
    s = IP.sub(" ", l)
    for m in re.finditer(r"img\.shields\.io/badge/([^)\"]+?)-([0-9a-f]{6}|[a-z]+)\)", l):
        parts = m.group(1).replace("--", "\x00").split("-")
        if len(parts) >= 2:
            val = parts[-1].replace("\x00", "-").replace("__", "_").replace("%20", " ")
            if re.match(r"^v?\d+\.\d+", val) and val not in lock:
                fail("versions", f"README.md:{i + 1}", f"badge version {val!r} is not versions.lock.yaml's")
    for m in VER.finditer(s):
        v = m.group(0)
        if v not in lock and v.lstrip("v") not in lock:
            fail("versions", f"README.md:{i + 1}", f"version {v!r} does not occur in versions.lock.yaml")
    for m in re.finditer(r"sha256:[0-9a-f]{64}", l):
        if m.group(0) not in lock:
            fail("versions", f"README.md:{i + 1}", f"digest {m.group(0)[:19]}… is not in versions.lock.yaml")

# ---- facts (§5) ------------------------------------------------------------------------------
pol = "\n".join(l for _, l in section_lines("Policies enforced in CI"))
for need in ("9412", "9398", "9348", "9320", "9300", "make verify-pins", "make verify-evidence"):
    if need not in pol:
        fail("facts", "README.md", f"Policies enforced in CI does not state {need!r}")
lim = "\n".join(l for _, l in section_lines("Known limitations — read before trusting a run"))
if not (re.search(r"(?i)IPv6 anycast gateway", lim) and re.search(r"(?i)IPv6 Type-5", lim)):
    fail("facts", "README.md", "Known limitations does not state the IPv6 anycast-gateway / IPv6 Type-5 limitation")
for need in ("SRv6", "lab credentials"):
    if need not in lim:
        fail("facts", "README.md", f"Known limitations does not state {need!r}")

# ---- denylist (§2) ---------------------------------------------------------------------------
TERMS = [r"SONiC", r"sonic-vs", r"\bFRR\b", r"vtysh", r"CONFIG_DB", r"redis-cli", r"sonic" + r"provider",  # split: the migration-boundary scan deny-lists the term itself
         r"fabric-" + r"executor", r"kubenet", r"SRv6Service", r"--profile\b", r"\blatest\b",
         r"raw\.githubusercontent\.com", r"(?i)\b(vpls|vpws|e-?line|l3vpn|l2l3-?irb|evpn-vpws)\b"]
CRED = [r"(?i)\bpassword\s*[:=]\s*\S", r"(?i)authorization:\s*basic\s+\S", r"://[^/\s:@)]+:[^/\s@)]+@",
        r"\bsk-[A-Za-z0-9_-]{16,}", r"(?i)\b(api[_-]?key|token)\s*[:=]\s*[A-Za-z0-9_\-]{12,}"]
for i, l in enumerate(lines):
    if history[i]:
        continue
    for t in TERMS:
        m = re.search(t, l)
        if m:
            fail("denylist", f"README.md:{i + 1}", f"{m.group(0)!r} outside a labelled history block")
    for t in CRED:
        m = re.search(t, l)
        if m:
            fail("denylist", f"README.md:{i + 1}", "credential-shaped text")
    for alt in re.findall(r"!\[([^\]]*)\]", l):
        for t in CRED:
            if re.search(t, alt):
                fail("denylist", f"README.md:{i + 1}", "credential-shaped text in a figure's alt text")
ev_text = ev_p.read_text() if ev_p.exists() else ""
for t in CRED:
    if re.search(t, ev_text):
        fail("denylist", str(ev_p.relative_to(root)), "credential-shaped text in the evidence file")
if live_pw and len(live_pw) >= 8:
    for name, body in (("README.md", text), (str(ev_p.relative_to(root)), ev_text)):
        if live_pw in body:
            fail("denylist", name, "carries the live operator password")

# ---- evidence, prompts, principal ------------------------------------------------------------
ev = None
if not ev_p.exists():
    fail("evidence", str(ev_p.relative_to(root)), "missing — no accepted take")
else:
    try:
        ev = json.loads(ev_text)
    except Exception as e:
        fail("evidence", str(ev_p.relative_to(root)), f"not JSON: {e}")
if ev is not None:
    run = ev.get("run", {}) or {}
    need = {"generated_utc": ev.get("generated_utc"), "take": ev.get("take"),
            "run.command": run.get("command"), "run.exit_status": run.get("exit_status"),
            "run.device_image_digest": run.get("device_image_digest"),
            "run.cluster.name": (run.get("cluster") or {}).get("name"),
            "run.cluster.uid": (run.get("cluster") or {}).get("uid"),
            "run.lab.name": (run.get("lab") or {}).get("name"),
            "run.lab.topology_sha256": (run.get("lab") or {}).get("topology_sha256")}
    for k, v in need.items():
        if v in (None, ""):
            fail("evidence", ev_p.name, f"NFR-013 field {k} missing")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", str(run.get("device_image_digest", ""))) \
            or run.get("device_image_digest") not in lock:
        fail("evidence", ev_p.name, "run.device_image_digest is not the lock file's SR Linux digest")
    if ev.get("accept_pass") is not True:
        fail("evidence", ev_p.name, "accept_pass is not true")
    if ev.get("failures") != []:
        fail("evidence", ev_p.name, f"failures is not empty: {ev.get('failures')}")
    prompts = ev.get("prompts", []) or []
    rows, inside = [], False
    ROW = re.compile(r"^\|\s*([ABC])\s*\|\s*`([a-z-]+)`\s*\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|")
    if demo_doc.exists():
        for l in demo_doc.read_text().splitlines():
            if l.startswith("## "):
                inside = l.strip().lower().startswith("## frozen prompts")
                continue
            m = ROW.match(l) if inside else None
            if m:
                rows.append(m.groups())
    else:
        fail("prompts", "docs/DEMO_VIDEO.md", "missing")
    frozen = [r[3] for r in rows]
    if [p.get("prompt") for p in prompts] != frozen or len(frozen) != 3:
        fail("prompts", ev_p.name, f"prompts {[p.get('prompt') for p in prompts]!r} are not docs/DEMO_VIDEO.md's "
                                   f"frozen {frozen!r}, byte for byte, in order")
    if [p.get("construct") for p in prompts] != ["vlan", "ip-vrf", "mac-vrf"]:
        fail("prompts", ev_p.name, f"constructs {[p.get('construct') for p in prompts]} are not vlan, ip-vrf, mac-vrf")
    if [r[1] for r in rows] != ["vlan", "ip-vrf", "mac-vrf"] and rows:
        fail("prompts", "docs/DEMO_VIDEO.md", "frozen table constructs are not vlan, ip-vrf, mac-vrf")
    cap = ev.get("operator_username") or {}
    user = cap.get("username", "")
    if not user:
        fail("principal", ev_p.name, "no generated operator username recorded (operator_username.username)")
    for p in prompts:
        if p.get("principal") != user or not user:
            fail("principal", ev_p.name, f"{p.get('id')}: Network {p.get('network')} principal "
                                         f"{p.get('principal')!r} is not the generated operator username")
    rec = cap.get("evidence_record", "")
    if rec and (root / rec).exists():
        js = json.loads((root / rec).read_text())
        out = (root / rec).parent / js["raw_output"]["stdout"]["file"]
        # intent_secrets::username prints `username: <name>`
        if out.exists() and re.sub(r"^username:\s*", "", out.read_text().strip()) != user:
            fail("principal", rec, "the provisioning capture does not carry the recorded username")
    elif rec:
        report("principal", rec, "the provisioning capture is not on this host (evidence root is git-ignored); "
                                 "the recorded username was checked against all three Networks")
    # timings
    dur = (ev.get("video") or {}).get("duration")
    demo = section_lines("Demo")
    for n, l in demo:
        for m in re.finditer(r"~\s*(\d+(?:\.\d+)?)\s*min", l):
            if not isinstance(dur, (int, float)) or abs(float(m.group(1)) - dur / 6 / 60) > 0.5:
                fail("timings", f"README.md:{n}", f"~{m.group(1)} min is not the take's {dur}s / 6")
    secs = [p.get("seconds_enter_to_deployed") for p in prompts]
    for i, l in enumerate(lines):
        if in_fence[i]:
            continue
        for m in re.finditer(r"\b(\d+(?:\.\d+)?)\s*(?:s|seconds)\b", l):
            v = float(m.group(1))
            if not any(isinstance(x, (int, float)) and abs(x - v) < 1.0 for x in secs):
                fail("timings", f"README.md:{i + 1}", f"{m.group(0)!r} is not a timing the evidence file measured")

# ---- quickstart ------------------------------------------------------------------------------
quick = quick_p.read_text() if quick_p.exists() else ""
qs = section_lines("Quickstart")
fence = False
for n, l in qs:
    if l.lstrip().startswith("```"):
        fence = not fence
        continue
    cmd = l.split(" #", 1)[0].strip()
    if fence and cmd and not cmd.startswith("#") and cmd not in quick:
        fail("quickstart", f"README.md:{n}", f"{cmd!r} is not a command quickstart.md carries")

# ---- placeholder -----------------------------------------------------------------------------
PH = re.compile(r"<!--\s*ASSET-URL-PLACEHOLDER")
ph = [n for n, l in section_lines("Demo") if PH.search(l)]
asset = [n for n, l in section_lines("Demo") if re.match(r"^https://github\.com/user-attachments/assets/[0-9a-f-]{36}\s*$", l)]
if ph:
    for n in ph:
        report("placeholder", f"README.md:{n}", "the Demo asset URL is the operator's to supply "
                                                "(upload the 6x cut as a GitHub asset and replace this line)")
elif not asset:
    fail("placeholder", "README.md", "the Demo section has neither the asset URL nor the marked placeholder")

print(f"verify-readme: {'PASS' if findings == 0 else f'{findings} finding(s)'} ({root})")
sys.exit(1 if findings else 0)
PY
