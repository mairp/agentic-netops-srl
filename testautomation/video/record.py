#!/usr/bin/env python3
"""Deterministic screen-recording driver for the agentic-netops-srl intent-tier walkthrough.

Ported from the predecessor's driver (/root/agentic-netops/testautomation/video/record.py, T157),
changing only what the platform forces (contracts/readme-and-walkthrough.md §3):

  * the operator console requires a login (FR-102). The driver reads the generated
    `operator-credentials` Secret into memory and logs in BEFORE ffmpeg starts, so no frame and
    no log line carries a credential; the password is never printed, logged or written;
  * native SR Linux port names (`ethernet-1/1`), and the three frozen prompts of
    docs/DEMO_VIDEO.md — the driver refuses to start when its prompts differ from that file;
  * the leaf proof is read-only `sr_cli` `info from state` reads (leafproof.py) in place of
    `redis-cli` / `vtysh` / `bridge`;
  * the console is the predecessor's layout (agent-topology canvas above the conversation), so
    the canvas-fit assertion is kept: the canvas is zoomed OUT until the whole topology
    (supervisor, three workers, controllers, fabric) lies inside the canvas viewport; and the
    card the viewer must read lies inside the viewport.

Framing rules kept as they are (2026-09-07, the predecessor's fixed driver):
  * the terminal is never CSS-zoomed; ttyd's own fontSize sizes xterm to the 1920x1080 page,
    and the xterm screen box must lie inside the viewport, otherwise the take fails;
  * every terminal command waits for the shell prompt to come back (read from xterm's buffer
    through window.term) before the screenshot and the next command;
  * every element the viewer must read is asserted inside the 1920x1080 viewport.

It never edits cluster or device state; everything it runs is `kubectl get` and `sr_cli`
`info from state`.

Usage:
  record.py --take final                  # one take: prompts A,B,C of docs/DEMO_VIDEO.md
  record.py --smoke --take smoke          # framing, prompt validation, identifiers free; no video
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import leafproof as lp  # noqa: E402
import prompts as fp  # noqa: E402

BASE = Path(__file__).resolve().parent
REPO = BASE.parents[1]
TAKES = BASE / "takes"
SHOTS = BASE / "shots"

UI_URL = os.environ.get("UI_URL", "http://127.0.0.1:13000/")
HEALTH_URL = os.environ.get("SUPERVISOR_HEALTH_URL", "http://127.0.0.1:19090/v1/health")
TTYD_PORT = os.environ.get("TTYD_PORT", "7681")
TTYD_URL = f"http://127.0.0.1:{TTYD_PORT}/"
DISPLAY = os.environ.get("RECORD_DISPLAY", ":116")  # its own display, never a shared one
AGENTS_NS = "agentic-netops-agents"
INTENT_NS = "agentic-netops-intent"
NETS = "networks.fabric.agentic-netops.io"
PROMPT_RE = r"operator@netops:.*\$ ?$"
KC_COLS = ("NAME:.metadata.name,"
           "CONSTRUCT:'.metadata.annotations.agentic-netops\\.io/service-type',"
           "PRINCIPAL:'.metadata.annotations.agentic-netops\\.io/intent-principal',"
           "READY:'.status.conditions[?(@.type==\"Ready\")].status',"
           "REASON:'.status.conditions[?(@.type==\"Ready\")].reason'")
CLOSING_CMD = f"kubectl -n {INTENT_NS} get {NETS} -o custom-columns={KC_COLS}"
STEP_S = float(os.environ.get("RECORD_STEP_SECONDS", "1800"))


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def log(msg: str) -> None:
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def host(cmd: str, timeout: int = 120) -> tuple[int, str]:
    """Run cmd on the host (the source of truth). Returns (rc, combined output)."""
    p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout + (("\n[stderr] " + p.stderr) if p.stderr.strip() else "")).rstrip()


def kjson(*args: str) -> dict:
    p = subprocess.run(["kubectl", *args, "-o", "json"], capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        raise TakeFailure(f"kubectl {' '.join(args)}: {p.stderr.strip()[:300]}")
    return json.loads(p.stdout)


def operator_login() -> tuple[str, str]:
    """The generated operator credential, read into memory only (never printed or written)."""
    s = kjson("-n", AGENTS_NS, "get", "secret", "operator-credentials")
    return (base64.b64decode(s["data"]["username"]).decode(),
            base64.b64decode(s["data"]["password"]).decode())


def term_commands(net: str, cid: str) -> list[str]:
    return [
        f"kubectl -n {INTENT_NS} get {NETS} -l agentic-netops.io/correlation-id={cid} -o custom-columns={KC_COLS}",
        f"kubectl -n {INTENT_NS} get events --field-selector involvedObject.name={net}",
        f"kubectl -n {INTENT_NS} get {NETS} {net} -o jsonpath='{{.spec}}' | python3 -m json.tool | head -40",
    ]


def spec_ids(net: dict) -> tuple[int | None, str]:
    """The VNI the leaf reads key on, and the VLAN, from the Network's own spec."""
    spec = net.get("spec", {}) or {}
    vni = None
    for bd in spec.get("bridgeDomains", []) or []:
        vni = bd.get("l2vni") or vni
    for r in spec.get("routers", []) or []:
        vni = r.get("l3vni") or vni
    vlans = sorted({str(a.get("vlan")) for a in spec.get("attachments", []) or [] if a.get("vlan")})
    return vni, (vlans[0] if vlans else "")


def vteps() -> dict[str, str]:
    out = {}
    for leaf in lp.LEAVES:
        _, o = host(lp.vtep_read(leaf))
        out[leaf] = lp.parse_vtep(o)
    return out


class TakeFailure(Exception):
    pass


class Driver:
    def __init__(self, args):
        self.args = args
        self.take = args.take
        self.meta: dict = {"take": self.take, "started_utc": now_iso(), "prompts": [],
                           "overview_secs": args.overview, "gap_secs": args.gap, "cmd_wait": args.cmd_wait}
        self.proc: dict = {}
        self.shot_idx = 0

    # ---------- infrastructure ----------
    def start_xvfb(self):
        sock = Path(f"/tmp/.X11-unix/X{DISPLAY.lstrip(':')}")
        if sock.exists():
            log(f"Xvfb {DISPLAY} already running; reusing")
            return
        self.proc["xvfb"] = subprocess.Popen(
            ["Xvfb", DISPLAY, "-screen", "0", "1920x1080x24", "-nolisten", "tcp"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        for _ in range(50):
            if sock.exists():
                break
            time.sleep(0.2)
        log(f"Xvfb {DISPLAY} started")

    def start_ttyd(self):
        subprocess.run(["pkill", "-f", f"ttyd -p {TTYD_PORT}"], capture_output=True)
        time.sleep(0.5)
        ps1 = "\\[\\e[32m\\]operator@netops\\[\\e[0m\\]:\\w$ "
        kubeconfig = os.environ.get("KUBECONFIG", str(Path.home() / ".kube" / "config"))
        self.proc["ttyd"] = subprocess.Popen(
            ["ttyd", "-p", TTYD_PORT, "-i", "lo", "-W",
             "-t", "fontSize=24",   # 135x39 on a 1920x1080 page; never CSS-zoom the page
             "-t", 'theme={"background":"#0d1117"}',
             "env", "-i", f"PS1={ps1}", f"KUBECONFIG={kubeconfig}", f"PATH={os.environ.get('PATH', '')}",
             f"HOME={Path.home()}", "TERM=xterm-256color",
             "bash", "--norc", "--noprofile"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        time.sleep(1.5)
        log(f"ttyd started on 127.0.0.1:{TTYD_PORT}")

    def start_ffmpeg(self, out: Path):
        if self.args.no_record:
            return
        self.proc["ffmpeg"] = subprocess.Popen(
            ["ffmpeg", "-y", "-f", "x11grab", "-video_size", "1920x1080",
             "-framerate", "30", "-i", DISPLAY, "-c:v", "libx264", "-preset", "veryfast",
             "-crf", "20", "-pix_fmt", "yuv420p", str(out)],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log(f"ffmpeg recording -> {out.name}")

    def stop_ffmpeg(self):
        f = self.proc.pop("ffmpeg", None)
        if not f:
            return
        try:
            f.stdin.write(b"q")
            f.stdin.flush()
        except Exception:
            pass
        try:
            f.wait(timeout=20)
        except subprocess.TimeoutExpired:
            f.send_signal(signal.SIGINT)
            try:
                f.wait(timeout=15)
            except subprocess.TimeoutExpired:
                f.kill()
        log("ffmpeg stopped")

    def cleanup(self):
        self.stop_ffmpeg()
        if "ttyd" in self.proc:
            self.proc.pop("ttyd").terminate()
        x = self.proc.pop("xvfb", None)
        if x is not None and self.args.stop_xvfb:
            x.terminate()

    def write_meta(self):
        TAKES.mkdir(parents=True, exist_ok=True)
        (TAKES / f"meta-{self.take}.json").write_text(json.dumps(self.meta, indent=1))

    # ---------- console helpers ----------
    def shot(self, page, tag: str):
        self.shot_idx += 1
        SHOTS.mkdir(parents=True, exist_ok=True)
        p = SHOTS / f"{self.take}-{tag}-{self.shot_idx:02d}.png"
        page.screenshot(path=str(p))
        log(f"shot {p.name}")
        return p

    def frame_check(self, page, tag: str, locators: dict, fatal: bool = True):
        """Mechanical framing check: every named element's bounding box must sit fully inside
        the 1920x1080 viewport — nothing clipped, nothing off-screen."""
        problems = []
        for label, loc in locators.items():
            box = loc.bounding_box() if loc.count() else None
            if not box:
                problems.append(f"{label}: not found")
                continue
            x, y, w, h = box["x"], box["y"], box["width"], box["height"]
            if not (x >= -1 and y >= -1 and x + w <= 1921 and y + h <= 1081):
                problems.append(f"{label}: box ({x:.0f},{y:.0f},{w:.0f}x{h:.0f}) outside viewport")
        self.meta.setdefault("console_frames", []).append({tag: {"ok": not problems, "problems": problems}})
        if problems:
            msg = f"framing[{tag}]: {'; '.join(problems)}"
            if fatal:
                raise TakeFailure(msg)
            log(f"WARN {msg}")
        else:
            log(f"framing[{tag}]: ok")

    def show(self, page, loc, tag: str, fatal: bool = True):
        """Bring the card the viewer must read into the viewport (the conversation scrolls; a card
        below the fold passes nothing) and assert it is framed."""
        try:
            loc.scroll_into_view_if_needed(timeout=5000)
        except Exception:
            pass
        time.sleep(0.6)
        self.frame_check(page, tag, {tag: loc}, fatal=fatal)

    def wait_healthy(self, page):
        deadline = time.time() + 90
        while time.time() < deadline:
            try:
                r = page.request.get(HEALTH_URL, timeout=5000)
                if r.ok:
                    return True
            except Exception:
                pass
            time.sleep(1.5)
        raise TakeFailure(f"supervisor {HEALTH_URL} never reported healthy")

    def login(self, u):
        """FR-102: log in before anything is recorded. The credential lives in this function's
        locals only; the page keeps it in memory (T123) and the form is gone before ffmpeg starts."""
        user, password = operator_login()
        u.goto(UI_URL, wait_until="domcontentloaded")
        u.get_by_test_id("login-form").wait_for(timeout=60_000)
        u.get_by_test_id("login-username").fill(user)
        u.get_by_test_id("login-password").fill(password)
        u.get_by_test_id("login-submit").click()
        u.get_by_test_id("prompt-input").wait_for(timeout=60_000)
        del password
        if u.get_by_test_id("login-form").count() != 0:
            raise TakeFailure("login form still present after login")
        self.meta["operator_username"] = user
        log("console logged in (credential not logged)")

    # ---------- canvas helpers (the predecessor's, unchanged) ----------
    @staticmethod
    def canvas_boxes(u) -> tuple[list, list]:
        return u.evaluate(
            "(() => { const v = document.querySelector('.graph-viewport'); const f = document.querySelector('.topology-flow');"
            " const rv = v.getBoundingClientRect(), rf = f.getBoundingClientRect();"
            " return [[rv.x, rv.y, rv.width, rv.height], [rf.x, rf.y, rf.width, rf.height]]; })()")

    def canvas_fits(self, u, margin: float = 6.0) -> bool:
        (vx, vy, vw, vh), (fx, fy, fw, fh) = self.canvas_boxes(u)
        return (fx >= vx - margin and fy >= vy - margin and fx + fw <= vx + vw + margin
                and fy + fh <= vy + vh + margin and vx >= 0 and vy >= 0 and vx + vw <= 1921 and vy + vh <= 1081)

    def fit_canvas(self, u, tag: str):
        """Zoom the agent canvas OUT until the whole topology lies inside the canvas viewport.
        Fails the take if it cannot be made to fit at the minimum zoom."""
        zout = u.get_by_label("Zoom out canvas")
        for _ in range(16):
            if self.canvas_fits(u) or zout.is_disabled():
                break
            zout.click()
            time.sleep(0.55)
        (vx, vy, vw, vh), (fx, fy, fw, fh) = self.canvas_boxes(u)
        zoom = u.get_by_label("Reset canvas view").inner_text().strip()
        ok = self.canvas_fits(u)
        self.meta.setdefault("canvas_frames", []).append(
            {tag: {"viewport": [vx, vy, vw, vh], "flow": [fx, fy, fw, fh], "zoom": zoom, "ok": ok}})
        if not ok:
            raise TakeFailure(f"framing[{tag}-canvas]: topology {[fx, fy, fw, fh]} does not fit the canvas "
                              f"viewport {[vx, vy, vw, vh]} at zoom {zoom}")
        log(f"framing[{tag}-canvas]: ok (zoom {zoom}, flow {fw:.0f}x{fh:.0f} in viewport {vw:.0f}x{vh:.0f})")

    # ---------- terminal helpers ----------
    @staticmethod
    def term_lines(t) -> list[str]:
        """Every line of xterm's active buffer (ttyd exposes window.term)."""
        return t.evaluate(
            "(() => { const b = window.term && window.term.buffer.active; if (!b) return null;"
            " const out = []; for (let i = 0; i < b.length; i++) {"
            " const l = b.getLine(i); out.push(l ? l.translateToString(true) : ''); } return out; })()") or []

    def term_frame_check(self, t, tag: str):
        """The xterm screen must be fully inside the 1920x1080 page and fill it: no CSS zoom, no
        clipped columns on either edge."""
        t.evaluate("window.dispatchEvent(new Event('resize'))")
        time.sleep(0.4)
        x, y, w, h = t.evaluate(
            "(() => { const e = document.querySelector('.xterm-screen'); const r = e.getBoundingClientRect();"
            " return [r.x, r.y, r.width, r.height]; })()")
        cols, rows = t.evaluate("window.term ? [window.term.cols, window.term.rows] : [0, 0]")
        ok = x >= 0 and y >= 0 and x + w <= 1920.5 and y + h <= 1080.5 and w >= 0.95 * 1920 and h >= 0.9 * 1080
        self.meta.setdefault("terminal_frames", []).append(
            {tag: {"box": [x, y, w, h], "cols": cols, "rows": rows, "ok": ok}})
        if not ok:
            raise TakeFailure(f"framing[{tag}-terminal]: xterm screen box {[x, y, w, h]} cols={cols} rows={rows}"
                              " is clipped or does not fill the page")
        log(f"framing[{tag}-terminal]: ok ({cols}x{rows}, box {x:.0f},{y:.0f},{w:.0f}x{h:.0f})")

    def term_type(self, t, cmd: str):
        t.bring_to_front()
        time.sleep(0.5)
        t.mouse.click(960, 540)
        time.sleep(0.3)
        t.keyboard.type(cmd, delay=35)
        t.keyboard.press("Enter")

    def term_wait_prompt(self, t, lines_before: int, timeout: float) -> bool:
        """Wait until the shell prompt is back as the last line of the buffer AND the buffer has
        grown past the typed command line, i.e. the command finished and its output is on screen."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            lines = [l for l in self.term_lines(t) if l.strip()]
            last = lines[-1] if lines else ""
            if len(lines) >= lines_before + 2 and re.search(PROMPT_RE, last):
                return True
            time.sleep(0.25)
        return False

    def run_terminal_cmd(self, t, cmd: str, evidence: dict, key: str) -> tuple[int, str]:
        lines_before = sum(1 for l in self.term_lines(t) if l.strip())
        self.term_type(t, cmd)
        returned = self.term_wait_prompt(t, lines_before, timeout=max(30.0, self.args.cmd_wait * 4))
        time.sleep(self.args.cmd_wait)          # hold the output for the viewer
        self.shot(t, key)
        rc, out = host(cmd)
        screen = "\n".join(l for l in self.term_lines(t) if l.strip())
        evidence["commands"][key] = {"cmd": cmd, "rc": rc, "output": out,
                                     "prompt_returned_on_screen": returned, "screen_tail": screen[-1200:]}
        if not returned:
            log(f"WARN {key}: shell prompt did not return within the wait; output may be incomplete on screen")
        if rc != 0:
            log(f"WARN host rc={rc} for {key}")
        return rc, out

    def term_clear(self, t, tag: str):
        self.term_type(t, "clear")
        time.sleep(1.2)
        self.term_frame_check(t, tag)

    # ---------- per-prompt flow ----------
    def new_conversation(self, u):
        b = u.get_by_test_id("new-thread")
        if b.count() and b.is_enabled():
            b.click()
            time.sleep(1.0)

    FINALS_AFTER_DIVIDER_JS = (
        "() => { const t = document.querySelector('[data-testid=\"transcript\"]');"
        " if (!t) return 0;"
        " const d = t.querySelectorAll('[data-testid=\"thread-divider\"]');"
        " const last = d.length ? d[d.length - 1] : null;"
        " return Array.from(t.querySelectorAll('[data-testid=\"final\"]')).filter(f =>"
        " !last || (last.compareDocumentPosition(f) & Node.DOCUMENT_POSITION_FOLLOWING)).length; }")

    def finals_after_divider(self, u) -> int:
        """Outcome cards in the current conversation (after the last thread divider)."""
        return int(u.evaluate(self.FINALS_AFTER_DIVIDER_JS))

    def wait_confirmation(self, u, stage: str, before: int):
        """The next confirmation of `stage`. A turn that ends without one (the model asked a
        question instead) fails the take — the wording is frozen and is never retried."""
        loc = u.locator(f'[data-testid="confirmation"][data-stage="{stage}"]')
        started = time.time()
        idle_since = None
        while time.time() - started < STEP_S:
            if loc.count() > before:
                return loc.nth(before)
            if u.get_by_test_id("error-card").count():
                raise TakeFailure(f"{stage}: error card: {u.get_by_test_id('error-card').last.inner_text()[:300]}")
            # the turn is over (send enabled, not streaming) for 5 s and no confirmation came
            if time.time() - started > 5 and self.idle(u):
                idle_since = idle_since or time.time()
                if time.time() - idle_since > 5:
                    tail = u.get_by_test_id("transcript").inner_text()[-400:]
                    raise TakeFailure(f"{stage}: turn ended without a {stage} confirmation: {tail}")
            else:
                idle_since = None
            time.sleep(1.0)
        raise TakeFailure(f"{stage}: no confirmation within {STEP_S:.0f}s")

    @staticmethod
    def idle(u) -> bool:
        return bool(u.evaluate(
            "() => { const b = document.querySelector('[data-testid=\"prompt-send\"]');"
            " return !!b && !b.disabled && !document.querySelector('[data-streaming=\"true\"]'); }"))

    def run_prompt(self, u, t, pid: str, prompt: str, construct: str) -> dict:
        ev: dict = {"id": pid, "prompt": prompt, "construct": construct,
                    "t_enter": None, "t_deployed": None, "seconds_enter_to_deployed": None,
                    "correlation_id": None, "network": None, "ready_condition": None,
                    "dom_outcome_text": None, "failure_reason_present": None, "commands": {}}
        log(f"--- prompt {pid}: {prompt}")
        u.bring_to_front()
        time.sleep(0.6)
        self.new_conversation(u)
        # The console's new-thread keeps the transcript and appends a divider
        # (ui/src/chat/Conversation.tsx newThread): only an outcome card after
        # the last divider belongs to this conversation.
        if self.finals_after_divider(u) != 0:
            raise TakeFailure("stale outcome card present after the last thread divider")
        composer = u.get_by_test_id("prompt-input")
        self.show(u, composer, f"{pid}-before")
        composer.click()
        time.sleep(0.4)
        u.keyboard.type(prompt, delay=45)
        time.sleep(0.5)
        self.shot(u, f"{pid}-typed")
        self.frame_check(u, f"{pid}-typed", {"Request": composer})
        n_map = u.locator('[data-testid="confirmation"][data-stage="mapper"]').count()
        n_alloc = u.locator('[data-testid="confirmation"][data-stage="allocator"]').count()
        n_final = u.get_by_test_id("final").count()
        n_err = u.get_by_test_id("error-card").count()
        u.get_by_test_id("prompt-send").click()
        ev["t_enter"] = time.time()
        ev["t_enter_utc"] = now_iso()
        self.meta["prompts"].append(ev)   # a failed prompt is still captured
        log(f"sent ({pid})")

        mapper = self.wait_confirmation(u, "mapper", n_map)
        # the conversation has expanded and the canvas shrank: keep the whole topology in frame
        self.fit_canvas(u, f"{pid}-mapper")
        interp = u.locator('[data-testid="stage-card"][data-stage="mapper"]').last
        self.show(u, interp if interp.count() else mapper, f"{pid}-mapper")
        self.show(u, mapper, f"{pid}-mapper-confirm")
        time.sleep(1.5)
        self.shot(u, f"{pid}-mapper")
        mapper.get_by_test_id("confirm-button").click()
        log(f"mapper confirmed ({pid})")

        alloc = self.wait_confirmation(u, "allocator", n_alloc)
        self.show(u, alloc, f"{pid}-allocator")
        time.sleep(1.5)
        self.shot(u, f"{pid}-allocator")
        chip = u.get_by_test_id("correlation-chip").last
        m = re.search(r"[0-9a-f]{32}", (chip.get_attribute("data-correlation-id") or "") if chip.count() else "")
        ev["correlation_id"] = m.group(0) if m else None
        alloc.get_by_test_id("confirm-button").click()
        log(f"allocator confirmed ({pid})")

        final = u.get_by_test_id("final")
        deadline = time.time() + STEP_S
        while time.time() < deadline:
            if u.get_by_test_id("error-card").count() > n_err:
                ev["failure_reason_present"] = True
                ev["dom_outcome_text"] = u.get_by_test_id("error-card").last.inner_text()
                self.shot(u, f"{pid}-FAILED")
                raise TakeFailure(f"{pid}: error card appeared: {ev['dom_outcome_text'][:300]}")
            if final.count() > n_final and self.idle(u):
                status = final.last.get_attribute("data-status")
                txt = final.last.inner_text()
                ev["final_status"] = status
                if status == "COMPLETED":
                    ev["t_deployed"] = time.time()
                    ev["dom_outcome_text"] = txt
                    break
                ev["dom_outcome_text"] = txt
                self.shot(u, f"{pid}-FAILED")
                raise TakeFailure(f"{pid}: outcome {status}, not deployed: {txt[:300]}")
            time.sleep(1)
        else:
            self.shot(u, f"{pid}-FAILED")
            raise TakeFailure(f"{pid}: timeout waiting for the deployed outcome")
        ev["seconds_enter_to_deployed"] = round(ev["t_deployed"] - ev["t_enter"], 1)
        ev["failure_reason_present"] = False
        log(f"{pid} deployed in {ev['seconds_enter_to_deployed']}s: {ev['dom_outcome_text'][:160]}")
        self.show(u, final.last, f"{pid}-outcome")
        time.sleep(2.5)  # hold the outcome card
        self.shot(u, f"{pid}-outcome")

        cid = ev["correlation_id"]
        if not cid:
            raise TakeFailure(f"{pid}: no correlation id on the page")
        items = kjson("-n", INTENT_NS, "get", NETS, "-l", f"agentic-netops.io/correlation-id={cid}")["items"]
        if len(items) != 1:
            raise TakeFailure(f"{pid}: {len(items)} Networks carry correlation={cid}")
        netobj = items[0]
        net = netobj["metadata"]["name"]
        ev["network"] = net
        log(f"{pid} correlation={cid} network={net}")

        # terminal proof: kubectl, then inside the leaf. `clear` puts this prompt's proof at the
        # top of the screen; the page is never CSS-zoomed.
        self.term_clear(t, pid)
        for i, cmd in enumerate(term_commands(net, cid), 1):
            self.run_terminal_cmd(t, cmd, ev, f"{pid}-cmd{i}")
        vni, vlan = spec_ids(netobj)
        reads = lp.reads(construct, net, vlan=vlan, vni=vni, prefix=fp.PREFIX.get(pid, ""),
                         vteps=vteps() if construct == "mac-vrf" else None)
        ev["leaf_reads"] = []
        for j, rd in enumerate(reads, 1):
            if j == 1 or (j - 1) % 4 == 0:
                self.term_clear(t, f"{pid}-leaf{j}")
            rc, out = self.run_terminal_cmd(t, rd.cmd, ev, f"{pid}-leaf{j}")
            ok, why = lp.judge(rd, rc, out)
            ev["leaf_reads"].append({"leaf": rd.leaf, "fact": rd.fact, "cmd": rd.cmd, "shown": ok, "why": why})

        # cluster truth
        nj = kjson("-n", INTENT_NS, "get", NETS, net)
        conds = nj.get("status", {}).get("conditions", []) or []
        ev["ready_condition"] = next((c for c in conds if c.get("type") == "Ready"), None)
        ev["network_spec"] = nj.get("spec")
        evs = kjson("-n", INTENT_NS, "get", "events", "--field-selector", f"involvedObject.name={net}")
        ev["events"] = [e.get("reason") for e in evs.get("items", [])]
        if not ev["ready_condition"] or ev["ready_condition"].get("status") != "True":
            raise TakeFailure(f"{pid}: Ready condition is not True: {ev['ready_condition']}")
        return ev

    # ---------- smoke ----------
    def smoke_checks(self) -> dict:
        """The three prompts validated against the site inventory and the offline translator, and
        every single-use identifier confirmed free — before any take."""
        res: dict = {"prompts": {}, "identifiers": {}, "ok": True}
        # the site inventory the translator sidecar is given (configMapKeyRef site-inventory)
        env = {k: v for k, v in (kjson("-n", AGENTS_NS, "get", "configmap", "site-inventory").get("data") or {}).items()
               if k.startswith("FABRIC_")}
        nodes = json.loads(env.get("FABRIC_NODE_MAP", "{}") or "{}")
        ports = json.loads(env.get("FABRIC_PORT_MAP", "{}") or "{}")
        res["site_inventory"] = {"nodes": sorted(nodes), "ports": ports}
        translator = REPO / "bin" / "migration-translator"
        rc, out = host(f"cd {REPO} && make -s build-migration-cli")
        if rc != 0:
            raise TakeFailure(f"build-migration-cli: {out[:300]}")
        for pid in fp.ORDER:
            prompt = fp.PROMPTS[pid]
            ends = fp.endpoints(prompt)
            known = [(n, p) for n, p in ends if n in nodes and p in (ports.get(n) or [])]
            intent = fp.normalized_intent(pid, int(env.get("FABRIC_ASN", "65000") or 65000))
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
                json.dump(intent, f)
            p = subprocess.run([str(translator), "--file", f.name], capture_output=True, text=True,
                               env={**os.environ, **env})
            os.unlink(f.name)
            ok = bool(ends) and len(known) == len(ends) and p.returncode == 0
            res["prompts"][pid] = {"prompt": prompt, "construct": fp.CONSTRUCT[pid], "endpoints": ends,
                                   "in_site_inventory": len(known) == len(ends),
                                   "translator_rc": p.returncode, "translator_stderr": p.stderr[:400],
                                   "translated_kind": "Network" if "kind: Network" in p.stdout else None,
                                   "ok": ok}
            res["ok"] &= ok
        # identifiers single-use: no Network anywhere carries them, no subinterface exists yet
        allnets = kjson("get", NETS, "-A")["items"]
        blob = json.dumps([n.get("spec") for n in allnets])
        for v in fp.VLANS:
            on_spec = bool(re.search(rf'"vlan":\s*{v}\b', blob))
            leaf_hits = []
            for leaf, cmd in lp.free_reads([v]):
                rc, o = host(cmd)
                if rc == 0 and re.search(rf"subinterface {v}\b|index {v}\b", o):
                    leaf_hits.append(leaf)
            free = not on_spec and not leaf_hits
            res["identifiers"][f"vlan {v}"] = {"on_a_network_spec": on_spec, "subinterface_on": leaf_hits, "free": free}
            res["ok"] &= free
        for pfx in fp.PREFIX.values():
            used = pfx in blob
            res["identifiers"][pfx] = {"on_a_network_spec": used, "free": not used}
            res["ok"] &= not used
        return res

    def run(self):
        TAKES.mkdir(parents=True, exist_ok=True)
        SHOTS.mkdir(parents=True, exist_ok=True)
        drift = fp.drift_from_doc()
        if drift:
            raise SystemExit(f"prompts differ from docs/DEMO_VIDEO.md: {drift}")
        if not self.args.smoke and list(TAKES.glob("*.mp4")):
            raise SystemExit(f"a take already exists in {TAKES}: one take; a second needs new identifiers "
                             "and a human decision")
        self.start_xvfb()
        self.start_ttyd()
        os.environ["DISPLAY"] = DISPLAY

        from playwright.sync_api import sync_playwright
        with sync_playwright() as pw:
            browser = pw.chromium.launch(
                headless=False,
                args=["--no-sandbox", "--kiosk", "--window-size=1920,1080", "--window-position=0,0",
                      "--disable-dev-shm-usage", "--hide-scrollbars"])
            self.meta["browser"] = {"name": "chromium", "version": browser.version}
            ctx = browser.new_context(no_viewport=True)
            u = ctx.new_page()
            t = ctx.new_page()
            self.wait_healthy(u)
            self.login(u)                       # before anything is recorded (FR-102)
            t.goto(TTYD_URL, wait_until="domcontentloaded")
            time.sleep(3.0)
            cdp = ctx.new_cdp_session(u)
            win = cdp.send("Browser.getWindowForTarget")
            cdp.send("Browser.setWindowBounds", {"windowId": win["windowId"], "bounds": {"windowState": "fullscreen"}})
            time.sleep(1.5)
            log("pages loaded, supervisor healthy, logged in, fullscreen")
            t.bring_to_front()
            time.sleep(0.8)
            self.term_frame_check(t, "startup")
            u.bring_to_front()

            if self.args.smoke:
                self.show(u, u.get_by_test_id("prompt-input"), "smoke-console")
                self.fit_canvas(u, "smoke-canvas")
                self.frame_check(u, "smoke-console", {"Request": u.get_by_test_id("prompt-input"),
                                                      "New conversation": u.get_by_test_id("new-thread")})
                self.shot(u, "smoke-console")
                self.term_clear(t, "smoke")
                smoke_ev = {"commands": {}}
                cmds = [CLOSING_CMD, lp.vtep_read("leaf01"), lp.vtep_read("leaf02")]
                cmds += [c for _, c in lp.free_reads(fp.VLANS[:1])]
                for i, cmd in enumerate(cmds, 1):
                    self.run_terminal_cmd(t, cmd, smoke_ev, f"smoke-cmd{i}")
                self.meta["smoke"] = smoke_ev
                self.meta["smoke_checks"] = self.smoke_checks()
                self.meta["finished_utc"] = now_iso()
                self.write_meta()
                browser.close()
                bad = [k for k, v in smoke_ev["commands"].items() if not v["prompt_returned_on_screen"]]
                ok = self.meta["smoke_checks"]["ok"]
                log(f"SMOKE DONE: terminal frames {len(self.meta.get('terminal_frames', []))} ok, "
                    f"console frames {len(self.meta.get('console_frames', []))} ok, "
                    f"prompts+identifiers {'ok' if ok else 'FAIL'}, "
                    f"commands without a returned prompt: {bad or 'none'}")
                return 0 if (not bad and ok) else 1

            out = TAKES / f"{self.take}.mp4"
            self.start_ffmpeg(out)
            rec_t0 = time.time()
            try:
                if self.args.overview > 0:
                    self.show(u, u.get_by_test_id("prompt-input"), "overview")
                    self.fit_canvas(u, "overview")
                    self.shot(u, "overview-layout")
                    settle = self.args.overview - (time.time() - rec_t0)
                    if settle > 0:
                        time.sleep(settle)
                for pid in fp.ORDER:
                    self.run_prompt(u, t, pid, fp.PROMPTS[pid], fp.CONSTRUCT[pid])
                    u.bring_to_front()
                    time.sleep(0.6)
                    if pid != fp.ORDER[-1]:
                        log(f"settling gap {self.args.gap}s")
                        time.sleep(self.args.gap)
                self.term_clear(t, "closing")
                self.run_terminal_cmd(t, CLOSING_CMD, {"commands": self.meta.setdefault("closing", {})}, "closing")
                time.sleep(self.args.closing_hold)
            except TakeFailure as e:
                self.meta["failed"] = str(e)
                raise
            finally:
                self.stop_ffmpeg()
                self.meta["finished_utc"] = now_iso()
                self.meta["record_wall_secs"] = round(time.time() - rec_t0, 1)
                self.write_meta()
                browser.close()
        dur = [p["seconds_enter_to_deployed"] for p in self.meta["prompts"]]
        log(f"DONE take={self.take} prompts={len(dur)} enter->deployed={dur} wall={self.meta.get('record_wall_secs')}s")
        return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--take", required=True)
    ap.add_argument("--gap", type=float, default=6.0)
    ap.add_argument("--cmd-wait", type=float, default=2.5)
    ap.add_argument("--overview", type=float, default=10.0)
    ap.add_argument("--closing-hold", type=float, default=5.0)
    ap.add_argument("--no-record", action="store_true", help="drive without ffmpeg (dry run)")
    ap.add_argument("--smoke", action="store_true",
                    help="framing, prompt validation and identifiers-free checks only; no prompts sent, no video")
    ap.add_argument("--stop-xvfb", action="store_true")
    args = ap.parse_args()
    if args.smoke:
        args.no_record = True
    d = Driver(args)
    rc = 0
    try:
        rc = d.run()
    except TakeFailure as e:
        log(f"TAKE FAILED: {e}")
        d.meta["failed"] = str(e)
        d.write_meta()
        rc = 1
    except Exception as e:
        log(f"ERROR: {type(e).__name__}: {e}")
        d.meta["failed"] = f"{type(e).__name__}: {e}"
        d.write_meta()
        rc = 2
    finally:
        d.cleanup()
    sys.exit(rc)


if __name__ == "__main__":
    main()
