# The recorded walkthrough — frozen take procedure

This is the procedure for the one recording the README's **Demo** section embeds
([contracts/readme-and-walkthrough.md](../specs/004-agentic-netops-composite/contracts/readme-and-walkthrough.md)
§3, T158–T162). It is the SR Linux counterpart of the predecessor's `docs/DEMO_VIDEO_RETAKE.md`,
scenario for scenario. It is frozen: the take is run exactly as written here, and nothing below is
changed while a take is in progress.

**What the take shows.** One silent 1920×1080 recording of the intent tier end to end. Three
services are provisioned from plain-language prompts typed into the operator console. Each is
confirmed through the mapper and the allocator, reported deployed, then proven in the terminal with
`kubectl` (the `Network` `Ready`, its events, its spec) and inside the SR Linux leaf with read-only
`sr_cli` `info from state` reads. The take is cut to **6×**. It has no captions and no overlays,
there are no cuts before acceleration, and frames are dropped, not blended.

**Tooling** (all under `testautomation/video/`, ported from the predecessor's by T157):

| File | Role |
|---|---|
| `record.py` | the driver: Xvfb + ttyd + a headed Chromium (Playwright) with two tabs, the console and the terminal; records the display with `ffmpeg` x11grab; `--smoke` proves framing, validates the prompts and confirms the identifiers free without recording |
| `prompts.py` | the three prompts below; the driver and `accept.py` refuse to run when they differ from this file's table by one byte |
| `leafproof.py` | the read-only leaf reads of §"Leaf proof", and the fact each must show |
| `accept.py` | acceptance from the cluster and the leaves, never from a frame; writes `docs/media/agentic-netops-srl-intent-tier-demo-evidence.json` (data-model.md §24) |
| `check_framing.py` | pixel statistics over the screenshots (a blank-screen detector), unchanged from the predecessor |
| `scripts/video-accelerate.sh` | the 6× cut: `setpts=PTS/6` at 30 fps, frames dropped, not blended |

Takes, screenshots and the driver's raw `meta-<take>.json` land in `testautomation/video/{takes,shots}/`,
which are git-ignored. Only the evidence file is committed, and it is written by `accept.py`.

## Frozen prompts

Same order, same tenants and same constructs as the predecessor. The driver refuses to start when its
prompts differ from the last column below. The identifiers in the last column are the **third take's**
(see *Second take* and *Third take — new identifiers* below). The first take used 170 / 253 / `10.53.0.0/24` / 152 and
failed at B on a driver defect; the second used 171 / 254 / `10.54.0.0/24` / 153 and failed acceptance on three
acceptance-tooling defects.

| # | Construct | Predecessor | This platform |
|---|---|---|---|
| A | `vlan` | `Provision a vlan 170 on leaf01 ethernet1 for tenant acme` | `Provision a vlan 172 on leaf01 ethernet-1/1 for tenant acme` |
| B | `ip-vrf` | `Deploy an ip-vrf between leaf01 wan1 and leaf02 wan1 for tenant initech with prefix 10.53.0.0/24` | `Deploy an ip-vrf between leaf01 ethernet-1/1 vlan 255 and leaf02 ethernet-1/1 vlan 255 for tenant initech with prefix 10.55.0.0/24` |
| C | `mac-vrf` | `Extend vlan152 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue` | `Extend vlan154 as a mac-vrf across leaf01 ethernet-1/1 and leaf02 ethernet-1/1 for tenant blue` |

A and C change the port name only: `ethernet1` becomes the device's native `ethernet-1/1`. The
identifiers differ from the predecessor's only because of the second- and third-take decisions below.

**B is the one forced change.** The predecessor's site had a routed port `wan1` on each leaf. This
site has no `wan1`. Each leaf has one access port, `ethernet-1/1` (`lab/topology.clab.yml`), and a
routed attachment is a VLAN subinterface of that port (data-model.md §10). So B names the port and
the VLAN of its subinterface, `vlan 255`, on both leaves (`vlan 253` in the first take, `vlan 254` in the second). Everything
else in B is the predecessor's word for word: the construct, the two leaves and the tenant. The
prefix is the third take's single-use replacement, described below. The smoke step validates
all three prompts against the site inventory and the offline translator before the take. If B's
wording must move again, it moves here with its reason, never silently in the driver.

**Identifiers are single-use**: VLANs 170, 152 and 253 and the prefix `10.53.0.0/24` belong to the
first take, VLANs 171, 153 and 254 and the prefix `10.54.0.0/24` to the second, and VLANs 172, 154 and 255
and the prefix `10.55.0.0/24` to the third. All the VLANs lie
in the naming band `100–999`, and every prompt names its VLAN, so the take allocates no VLAN. Any
further take needs new identifiers, also from `100–999`, and a human decision.

### Second take — new identifiers (R-41)

The first take failed at prompt B with `TAKE FAILED: stale outcome card present`. The failure was a
driver defect: the console keeps the transcript across threads, and `record.py` counted A's outcome
card as B's. The take was deleted and reported verbatim
(`.specstride/features/004-agentic-netops-composite/gates/T160-TAKE-FAILURE-REPORT.md`). R-41 requires
new identifiers and a human decision for a second take. The operator (Marlon Paz, 2026-09-29) decided
the following in `OPERATOR-DECISION-P16.md`, recorded as `2026-09-29-p16-retake` in
`docs/decisions/live-findings.md`:

| | First take | Second take |
|---|---|---|
| A `vlan`, leaf01, acme | VLAN 170 | VLAN 171 |
| B `ip-vrf`, initech | VLAN 253, `10.53.0.0/24` | VLAN 254, `10.54.0.0/24` |
| C `mac-vrf`, both leaves, blue | VLAN 152 | VLAN 153 |

The first take's `Network` (`migr-8f2b136c7ce948a`, VLAN 170) was deleted and its claims released
before the second take. Between the takes, one driver change was approved: `record.py` counts an
outcome or error card only if it follows the last thread divider (`FINALS_AFTER_DIVIDER_JS`) and was
added after Enter was pressed. The wording of the prompts is unchanged apart from the identifiers.

### Third take — new identifiers (R-41)

The second take recorded all three prompts to `COMPLETED`, but `accept.py` rejected it with 12 problems
(`ACCEPT: FAIL (12 problems)`). All of them were acceptance-tooling defects: the operator-username capture
was compared as a whole `username: operator` line, the vxlan interface was read from `interface *` where
25.7.1 lists it under `vxlan-interface *`, and the flooding list was matched as `vtep <ip>` where the device
prints `destination <ip> vni <n>`. The take was deleted by `accept.py` and reported verbatim
(`.specstride/features/004-agentic-netops-composite/gates/T160-TAKE2-FAILURE-REPORT.md`); it was not re-cut.
The operator (Marlon Paz, 2026-09-29) decided the third take in `OPERATOR-DECISION-P16-TAKE3.md`, recorded as
`2026-09-29-p16-take3` in `docs/decisions/live-findings.md`:

| | Second take | Third take |
|---|---|---|
| A `vlan`, leaf01, acme | VLAN 171 | VLAN 172 |
| B `ip-vrf`, initech | VLAN 254, `10.54.0.0/24` | VLAN 255, `10.55.0.0/24` |
| C `mac-vrf`, both leaves, blue | VLAN 153 | VLAN 154 |

The second take's three `Network`s (`migr-2e23de85544b4fa`, `migr-83ff5f4f10c84ab`, `migr-0970b301c5ae422`)
were deleted and their claims released before the third take. The approved between-takes changes are to
the acceptance tooling only: `accept.py` parses the `username:` value of the capture, and `leafproof.py`
reads `vxlan-interface *` and matches `destination <ip>` in the flooding list.

## Hard rules

- **Read-only.** The driver runs `kubectl get` and `sr_cli` `info from state` reads only. It
  changes nothing on a device or in the cluster. The only writes during a take are the three
  services the operator console submits, under the operator's two confirmations each.
- **No driver edits mid-take.** `record.py`, `accept.py`, `leafproof.py`, `prompts.py`, the UI, the
  agents and the deployments are not edited between the smoke and the report.
- **No retry with different wording.** A take that fails is deleted and reported verbatim. It is
  never embedded, re-cut or retried with other words.
- **Identifiers are single-use**: 170 / 152 / 253 / `10.53.0.0/24` (first take), 171 / 153 / 254 /
  `10.54.0.0/24` (second take) and 172 / 154 / 255 / `10.55.0.0/24` (third take). Any further take needs
  new ones and a human decision.
- **Login precedes recording.** The driver reads the generated `operator-credentials` Secret into
  memory and logs the console in before `ffmpeg` starts. No frame and no log line carries a
  credential, and the password is never printed or written.
- **Truth comes from the cluster.** A service is "deployed" only when `accept.py` reads `Ready=True`
  from `kubectl` JSON and each leaf read shows its fact. Screenshots are for framing, never for pass
  or fail.

## Procedure

Run every step from the repository root. `PY=agents/.venv/bin/python` is the tier's virtualenv,
which holds the locked Playwright.

### 1. Pre-flight

1. The tier stands, re-provisioned on the pinned artefacts (T159):
   `MGMT_CIDR=172.25.25.0/24 ./scripts/provision.sh --cluster-name agentic-netops --with-intent-tier`.
   The run is idempotent: it builds the whole lab if nothing stands, or only the tier if the control
   plane does. That run captures the `operator-credentials` `username` through `evidence_run` as
   `operator-username-<attempt>`. That capture is the username the three `Network`s are checked
   against.
2. Every agent is healthy: `curl -fsS http://127.0.0.1:19090/v1/health` returns `200`.
3. The host tools are the pinned ones: `bash scripts/lib/verify_pins.sh --host-tooling`. It fails
   naming a capture tool (`ffmpeg`, `Xvfb`, `ttyd`) that is missing or at a different version, and
   the browser-automation package or browser revision if either differs.
4. No take exists yet: `ls testautomation/video/takes/*.mp4` lists nothing.

### 2. Smoke — about a minute, no video

    $PY testautomation/video/record.py --smoke --take smoke

It must exit 0 and end with `prompts+identifiers ok, commands without a returned prompt: none`.
The smoke proves the following, and `takes/meta-smoke.json` records each:

- **Framing**: the xterm screen fills the 1920×1080 page unclipped, and the console's composer is
  inside the viewport.
- **The prompts are valid**: each prompt's nodes and ports are in the site inventory (the
  deployer's `FABRIC_NODE_MAP`/`FABRIC_PORT_MAP`), and the normalized intent each must become is
  accepted by the offline translator `bin/migration-translator`.
- **The identifiers are free**: no `Network` in any namespace carries VLAN 172, 154 or 255 or
  `10.55.0.0/24`, and neither leaf has subinterface `ethernet-1/1.172`, `.154` or `.255`.

The leaf reads below were fixed from what each printed on the pinned release (contract §3.2, T159).

### 3. Record — one take

    setsid nohup $PY testautomation/video/record.py --take final > testautomation/video/takes/record-final.log 2>&1 &

The take ends with a line starting `DONE take=final prompts=3`. If it prints `TAKE FAILED`, read
`failed` and the framing entries in `takes/meta-final.json`, delete `takes/final.mp4`, and stop.
Then report the failure verbatim.

### 4. Accept

    $PY testautomation/video/accept.py --take final

It must print no `FAIL` line and end `ACCEPT: PASS`. It re-verifies each of the following from live
machine output and writes the evidence file with `accept_pass: true` and `failures` empty:

- the video (1920×1080, decodes);
- each prompt's `Network` by its correlation label: `Ready=True` at the current generation, its
  events, its construct, and the generated operator username as its principal;
- every leaf read.

A failing take is **deleted** by `accept.py` and reported verbatim from `takes/failed-final.json`.

### 5. Cut and hand over

    scripts/video-accelerate.sh testautomation/video/takes/final.mp4 testautomation/video/takes/final-6x.mp4 6

The cut's measured duration is recorded with `ffprobe` beside the evidence. **Uploading the cut as a
GitHub asset and pasting its URL under the README's Demo section is the operator's step**, because
it is outward-facing. The README carries a marked placeholder until then, and `make verify-readme`
reports it.

### 6. Report

Report exactly these, and nothing else:

- the three prompts and their Enter-to-deployed seconds (from the evidence file);
- the uncut and cut durations;
- each prompt's leaf facts;
- every terminal and console frame entry of `meta-final.json`, each of which must be `ok`;
- every command whose `prompt_returned_on_screen` is false, which must be none;
- the paths of the take, the cut, the evidence file and the log.

## Leaf proof

Each service is proven in the terminal first with `kubectl`, then inside the leaf. The `kubectl`
reads are the same for all three:

    kubectl -n agentic-netops-intent get networks.fabric.agentic-netops.io -l agentic-netops.io/correlation-id=<cid> -o custom-columns=NAME:…,CONSTRUCT:…,PRINCIPAL:…,READY:…,REASON:…
    kubectl -n agentic-netops-intent get events --field-selector involvedObject.name=<network>
    kubectl -n agentic-netops-intent get networks.fabric.agentic-netops.io <network> -o jsonpath='{.spec}' | python3 -m json.tool | head -40

`<sid>` is the service identifier, the `Network` name without its `migr-` prefix. `<vni>` is the
VNI the `Network` spec carries. Leaf containers are `clab-agentic-netops-fabric-leaf01` and
`-leaf02`. Every line is typed exactly as below (`leafproof.py`):

| Service | Leaf | Command | Shows |
|---|---|---|---|
| A `vlan` | leaf01 | `docker exec clab-agentic-netops-fabric-leaf01 sr_cli "info from state network-instance vlan-<sid> oper-state"` | the bridged network instance of the vlan is `oper-state up` |
| | leaf01 | `docker exec clab-agentic-netops-fabric-leaf01 sr_cli "info from state network-instance vlan-<sid> interface *"` | it holds `ethernet-1/1.172` |
| | leaf01 | `docker exec clab-agentic-netops-fabric-leaf01 sr_cli "info from state network-instance vlan-<sid> vxlan-interface *"` | it prints nothing: **no** `vxlan0.*` interface |
| | leaf01 | `docker exec clab-agentic-netops-fabric-leaf01 sr_cli "info from state interface ethernet-1/1 subinterface 172 oper-state"` | subinterface `ethernet-1/1.172` is up |
| B `ip-vrf` | each leaf | `docker exec clab-agentic-netops-fabric-<leaf> sr_cli "info from state network-instance ipvrf-<sid> oper-state"` | the `ip-vrf` instance is up |
| | each leaf | `docker exec clab-agentic-netops-fabric-<leaf> sr_cli "info from state network-instance ipvrf-<sid> interface *"` | it holds routed `ethernet-1/1.255` |
| | each leaf | `docker exec clab-agentic-netops-fabric-<leaf> sr_cli "info from state network-instance ipvrf-<sid> vxlan-interface *"` | it holds `vxlan-interface vxlan0.<vni>` |
| | leaf01 | `docker exec clab-agentic-netops-fabric-leaf01 sr_cli "info from state tunnel-interface vxlan0 vxlan-interface <vni>"` | `type routed`, ingress `vni <vni>` |
| | each leaf | `docker exec clab-agentic-netops-fabric-<leaf> sr_cli "info from state network-instance ipvrf-<sid> route-table ipv4-unicast route 10.55.0.0/24 id * route-type * route-owner * origin-network-instance * active"` | `10.55.0.0/24` is an active route in the instance's route table (`active true`) |
| | leaf02 | `docker exec clab-agentic-netops-fabric-leaf02 sr_cli "info from state network-instance default bgp-rib afi-safi evpn evpn rib-in-out rib-in-post ip-prefix-route * ethernet-tag-id * ip-prefix-length 24 ip-prefix 10.55.0.0/24 neighbor * path-id *"` | the EVPN IP-prefix (Type-5) route for `10.55.0.0/24` is received |
| C `mac-vrf` | each leaf | `docker exec clab-agentic-netops-fabric-<leaf> sr_cli "info from state network-instance macvrf-<sid> oper-state"` | the `mac-vrf` instance is up |
| | each leaf | `docker exec clab-agentic-netops-fabric-<leaf> sr_cli "info from state network-instance macvrf-<sid> interface *"` | it holds `ethernet-1/1.154` |
| | each leaf | `docker exec clab-agentic-netops-fabric-<leaf> sr_cli "info from state network-instance macvrf-<sid> vxlan-interface *"` | it holds `vxlan-interface vxlan0.<vni>` |
| | each leaf | `docker exec clab-agentic-netops-fabric-<leaf> sr_cli "info from state network-instance macvrf-<sid> protocols bgp-evpn bgp-instance 1"` | the EVPN instance carries `evi <vni>` |
| | each leaf | `docker exec clab-agentic-netops-fabric-<leaf> sr_cli "info from state tunnel-interface vxlan0 vxlan-interface <vni> bridge-table multicast-destinations"` | the other leaf's VTEP (its `system0.0` address) is a flooding destination: `destination <vtep> vni <vni>` |

The other leaf's VTEP address is read once, with
`docker exec clab-agentic-netops-fabric-<leaf> sr_cli "info from state interface system0 subinterface 0 ipv4 address *"`.

## Framing — kept from the predecessor's fixed driver

These rules are kept from the predecessor's driver:

- The terminal is sized by ttyd's `fontSize` (24 px on the 1920×1080 page) and never by CSS zoom.
  The take fails if the xterm screen box is clipped or does not fill the page.
- The driver waits for the shell prompt to return before it screenshots or types the next command.
  `commands without a returned prompt` must be none.
- Every element the viewer must read (the composer, the mapper's interpretation and both
  confirmations, the outcome card) is scrolled into view and asserted inside the 1920×1080 viewport.

**Forced by this platform**: the operator console has no agent-topology canvas, so the predecessor's
"the whole topology fits the canvas" assertion has nothing to apply to. It becomes the viewport
assertion above, applied to the conversation card of each stage. The console also requires a login,
which happens before recording starts.
