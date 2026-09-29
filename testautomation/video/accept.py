#!/usr/bin/env python3
"""Acceptance of the agentic-netops-srl walkthrough take (machine-checked, T161).

Ported from the predecessor's accept.py (/root/agentic-netops/testautomation/video/accept.py):
it reads takes/meta-<take>.json written by record.py, re-verifies every success criterion from
live machine output — ffprobe, `kubectl` JSON and the read-only `sr_cli` `info from state` reads
of leafproof.py — never from pixels, and writes data-model.md §24's WalkthroughEvidence to
docs/media/agentic-netops-srl-intent-tier-demo-evidence.json with the NFR-013 identity fields.

`accept_pass: true` is the only thing that admits a take, and only with `failures` empty. A take
that fails is deleted (--delete-on-fail, the default) and its failures reported verbatim; it is
never embedded, re-cut or retried with different wording.

Usage: accept.py --take final [--keep-on-fail]
Exit 0 iff every mandatory criterion passes.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import leafproof as lp  # noqa: E402
import prompts as fp  # noqa: E402

BASE = Path(__file__).resolve().parent
REPO = BASE.parents[1]
TAKES = BASE / "takes"
SHOTS = BASE / "shots"
EVIDENCE = REPO / "docs" / "media" / "agentic-netops-srl-intent-tier-demo-evidence.json"
EVIDENCE_ROOT = REPO / ".evidence"
INTENT_NS = "agentic-netops-intent"
NETS = "networks.fabric.agentic-netops.io"
PRINCIPAL = "agentic-netops.io/intent-principal"
CLUSTER = os.environ.get("KIND_CLUSTER", "agentic-netops")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def host(cmd: str, timeout: int = 120) -> tuple[int, str]:
    p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout + p.stderr).strip()


def kjson(*args: str) -> dict | None:
    p = subprocess.run(["kubectl", *args, "-o", "json"], capture_output=True, text=True, timeout=60)
    return json.loads(p.stdout) if p.returncode == 0 else None


def check(failures: list[str], name: str, ok: bool, detail: str = "") -> bool:
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
    if not ok:
        failures.append(f"{name}: {detail}")
    return ok


def ffprobe(path: Path) -> dict:
    rc, out = host(f"ffprobe -v error -select_streams v:0 -show_entries stream=width,height "
                   f"-show_entries format=duration -of json {path}")
    if rc != 0:
        return {"error": out}
    js = json.loads(out)
    return {"width": js["streams"][0]["width"], "height": js["streams"][0]["height"],
            "duration": float(js["format"]["duration"])}


def ready_condition(net: dict) -> dict | None:
    return next((c for c in net.get("status", {}).get("conditions", []) or []
                 if isinstance(c, dict) and c.get("type") == "Ready"), None)


def run_identity() -> dict:
    """The NFR-013 fields: device image digest, cluster and lab identity."""
    digest, window = "", 0
    for line in (REPO / "versions.lock.yaml").read_text().splitlines():  # evidence.sh's rule
        if "srlinux" in line:
            window = 8
        if window > 0:
            m = re.search(r"sha256:[0-9a-f]{64}", line)
            if m:
                digest = m.group(0)
                break
            window -= 1
    ns = kjson("get", "namespace", "kube-system") or {}
    topo = REPO / "lab" / "topology.clab.yml"
    return {"device_image_digest": digest,
            "cluster": {"name": CLUSTER, "uid": ns.get("metadata", {}).get("uid", "")},
            "lab": {"name": lp.LAB, "topology_sha256": hashlib.sha256(topo.read_bytes()).hexdigest()}}


def username_capture() -> dict:
    """The generated operator username as the latest provisioning run captured it through
    evidence_run (T088, T159): the principal all three Networks must carry."""
    recs = sorted(EVIDENCE_ROOT.glob("*/*/operator-username-*.json"),
                  key=lambda p: json.loads(p.read_text()).get("utc_time", ""))
    if not recs:
        return {}
    rec = recs[-1]
    js = json.loads(rec.read_text())
    out = rec.parent / js["raw_output"]["stdout"]["file"]
    # intent_secrets::username prints `username: <name>` (T160 take 2 compared the whole line)
    text = out.read_text().strip()
    m = re.fullmatch(r"(?:username:\s*)?(\S+)", text)
    return {"username": m.group(1) if m else "", "evidence_record": str(rec.relative_to(REPO)),
            "record_sha256": js.get("record_sha256", ""), "utc_time": js.get("utc_time", "")}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--take", default="final")
    ap.add_argument("--keep-on-fail", action="store_true", help="do not delete a failed take (never for the real take)")
    args = ap.parse_args()
    meta_path = TAKES / f"meta-{args.take}.json"
    video = TAKES / f"{args.take}.mp4"
    failures: list[str] = []
    evidence: dict = {"generated_utc": now_iso(), "take": args.take,
                      "run": {"command": " ".join(["testautomation/video/accept.py", *sys.argv[1:]]),
                              "exit_status": None, **run_identity()},
                      "video": {}, "prompts": []}

    print("== frozen prompts ==")
    drift = fp.drift_from_doc()
    check(failures, "driver prompts equal docs/DEMO_VIDEO.md", not drift, "; ".join(drift))

    print("== video file ==")
    check(failures, f"{video.name} exists", video.exists(), str(video))
    if video.exists():
        info = ffprobe(video)
        evidence["video"] = info
        check(failures, "ffprobe parses", "error" not in info, str(info))
        if "width" in info:
            check(failures, "width 1920", info["width"] == 1920, str(info["width"]))
            check(failures, "height 1080", info["height"] == 1080, str(info["height"]))
            check(failures, "duration > 0 (recorded, uncut)", info.get("duration", 0) > 0, str(info.get("duration")))
        rc, out = host(f"ffmpeg -v error -i {video} -frames:v 30 -f null - 2>&1 | head -5")
        check(failures, "decodes (first 30 frames)", rc == 0 and not out, out[:200])
    mp4s = sorted(p.name for p in TAKES.glob("*.mp4"))
    check(failures, f"{video.name} is the only take", mp4s == [video.name], str(mp4s))

    print("== the take ==")
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    check(failures, "the driver reported no failure", not meta.get("failed"), str(meta.get("failed")))
    for fr in meta.get("terminal_frames", []) + meta.get("console_frames", []):
        for tag, v in fr.items():
            check(failures, f"framing {tag}", bool(v.get("ok")), json.dumps(v)[:160])
    noprompt = [k for p in meta.get("prompts", []) for k, c in p.get("commands", {}).items()
                if not c.get("prompt_returned_on_screen")]
    check(failures, "commands without a returned prompt: none", not noprompt, str(noprompt))

    cap = username_capture()
    evidence["operator_username"] = cap
    check(failures, "the generated operator username was captured by provisioning (T088)",
          bool(cap.get("username")), cap.get("evidence_record", "no operator-username-* record"))
    check(failures, "the console was logged in as that username before recording",
          meta.get("operator_username") == cap.get("username"), "")

    print("== prompts ==")
    prompts = meta.get("prompts", [])
    check(failures, "exactly the three frozen prompts, in order",
          [(p.get("id"), p.get("prompt"), p.get("construct")) for p in prompts]
          == [(i, fp.PROMPTS[i], fp.CONSTRUCT[i]) for i in fp.ORDER],
          str([p.get("id") for p in prompts]))
    for ev in prompts:
        pid, cid, construct = ev.get("id"), ev.get("correlation_id"), ev.get("construct", "")
        print(f"-- {pid}")
        pe: dict = {"id": pid, "prompt": ev.get("prompt"), "construct": construct,
                    "correlation_id": cid, "checked_utc": now_iso()}
        dom = ev.get("dom_outcome_text") or ""
        check(failures, f"{pid} console final status COMPLETED", ev.get("final_status") == "COMPLETED",
              str(ev.get("final_status")))
        check(failures, f"{pid} no error card in the console", ev.get("failure_reason_present") is False,
              str(ev.get("failure_reason_present")))
        shots = sorted(SHOTS.glob(f"{args.take}-{pid}-outcome-*.png"))
        check(failures, f"{pid} outcome screenshot exists", bool(shots), str([s.name for s in shots]))
        secs = ev.get("seconds_enter_to_deployed")
        check(failures, f"{pid} Enter->deployed seconds recorded", isinstance(secs, (int, float)), str(secs))
        pe.update({"seconds_enter_to_deployed": secs, "dom_outcome_text": dom, "t_enter_utc": ev.get("t_enter_utc"),
                   "outcome_screenshots": [s.name for s in shots]})

        # cluster truth, re-verified now from kubectl JSON
        lst = kjson("-n", INTENT_NS, "get", NETS, "-l", f"agentic-netops.io/correlation-id={cid}") if cid else None
        items = (lst or {}).get("items", [])
        check(failures, f"{pid} exactly one Network carries the correlation-id label", len(items) == 1,
              cid or "no correlation id")
        if len(items) != 1:
            evidence["prompts"].append(pe)
            continue
        net = items[0]
        name = net["metadata"]["name"]
        ann = net["metadata"].get("annotations", {}) or {}
        pe["network"] = name
        check(failures, f"{pid} the Network the driver proved is this one", ev.get("network") == name,
              f"{ev.get('network')} vs {name}")
        cond = ready_condition(net)
        pe["ready_condition"] = cond
        check(failures, f"{pid} Ready=True at the current generation",
              bool(cond) and cond.get("status") == "True"
              and cond.get("observedGeneration", net["metadata"].get("generation")) == net["metadata"].get("generation"),
              json.dumps(cond))
        evs = kjson("-n", INTENT_NS, "get", "events", "--field-selector", f"involvedObject.name={name}") or {}
        pe["event_reasons"] = [e.get("reason") for e in evs.get("items", [])]
        pe["service_type"] = ann.get("agentic-netops.io/service-type", "")
        check(failures, f"{pid} construct is {construct}", pe["service_type"] == construct, pe["service_type"])
        pe["principal"] = ann.get(PRINCIPAL, "")
        check(failures, f"{pid} principal is the generated operator username",
              bool(pe["principal"]) and pe["principal"] == cap.get("username"), pe["principal"])
        spec = net.get("spec", {})
        blob = json.dumps(spec)
        want_vlan = fp.VLAN[pid]
        check(failures, f"{pid} spec carries VLAN {want_vlan}", re.search(rf'"vlan": {want_vlan}\b', blob) is not None, "")
        if pid in fp.PREFIX:
            check(failures, f"{pid} spec carries {fp.PREFIX[pid]}", fp.PREFIX[pid] in blob, "")

        # leaf truth, re-verified now from the same read-only reads the take typed
        vni = None
        for bd in spec.get("bridgeDomains", []) or []:
            vni = bd.get("l2vni") or vni
        for r in spec.get("routers", []) or []:
            vni = r.get("l3vni") or vni
        vteps = {leaf: lp.parse_vtep(host(lp.vtep_read(leaf))[1]) for leaf in lp.LEAVES}
        reads = lp.reads(construct, name, vlan=want_vlan, vni=vni, prefix=fp.PREFIX.get(pid, ""), vteps=vteps)
        pe["leaf_pass"] = {}
        pe["commands"] = {}
        for j, rd in enumerate(reads, 1):
            rc, out = host(rd.cmd)
            ok, why = lp.judge(rd, rc, out)
            check(failures, f"{pid} {rd.fact}", ok, why)
            pe["leaf_pass"].setdefault(rd.leaf, True)
            pe["leaf_pass"][rd.leaf] &= ok
            pe["commands"][f"{pid}-leaf{j}"] = {"cmd": rd.cmd, "rc": rc, "fact": rd.fact, "shown": ok}
        cmds = ev.get("commands", {})
        check(failures, f"{pid} terminal commands captured during the take", len(cmds) >= 3 + len(reads),
              str(len(cmds)))
        taken = [c for c in ev.get("leaf_reads", []) if not c.get("shown")]
        check(failures, f"{pid} every leaf read on screen showed its fact", not taken,
              "; ".join(f"{c['fact']}: {c['why']}" for c in taken))
        for k, c in cmds.items():
            pe["commands"].setdefault(k, {"cmd": c["cmd"], "rc": c["rc"]})
        evidence["prompts"].append(pe)

    closing = (meta.get("closing", {}) or {}).get("closing", {})
    evidence["closing_listing"] = closing.get("output", "")

    # no credential in the evidence (login precedes recording)
    text = json.dumps(evidence)
    cred = re.search(r"(?i)password|authorization:\s*basic|://[^/\s:@]+:[^/\s@]+@", text)
    check(failures, "no credential in the evidence", cred is None, cred.group(0) if cred else "")

    evidence["accept_pass"] = not failures
    evidence["failures"] = failures
    evidence["run"]["exit_status"] = 0 if not failures else 1
    if not failures:
        EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
        EVIDENCE.write_text(json.dumps(evidence, indent=1) + "\n")
        print(f"\nevidence -> {EVIDENCE.relative_to(REPO)}")
        print("ACCEPT: PASS")
        return 0
    # a failed take is deleted and reported verbatim — never embedded, re-cut or retried
    report = TAKES / f"failed-{args.take}.json"
    report.write_text(json.dumps(evidence, indent=1) + "\n")
    if video.exists() and not args.keep_on_fail:
        video.unlink()
        print(f"\nfailed take deleted: {video.name}")
    print(f"failure report -> {report}")
    print(f"ACCEPT: FAIL ({len(failures)} problems)")
    for f in failures:
        print(f"  - {f}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
