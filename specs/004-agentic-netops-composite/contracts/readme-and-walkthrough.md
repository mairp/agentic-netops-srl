# Contract: the repository README and the recorded walkthrough

**Feature**: `004-agentic-netops-composite` | **Carries**: NFR-011, NFR-013, FR-083, FR-085,
SC-031, SC-032, SC-033, and the constitution's pending README sync item | **Decision**: CD-06 |
**Component**: C-22 | **Phase**: P12 — **the last task of the plan**

**Consumers**: whoever writes `README.md`; `make verify-readme`; the walkthrough driver and its
acceptance script; the operator who uploads the recording.

**Reference**: the predecessor's `/root/agentic-netops/README.md` and its recording tooling
(`testautomation/video/record.py`, `accept.py`, `check_framing.py`, `docs/DEMO_VIDEO_RETAKE.md`,
`scripts/video-accelerate.sh`). This contract reproduces that README **section for section** and
that recording **scenario for scenario**, on SR Linux. It is an interface because it is the first
thing anyone reads and the only place a reader sees the loop close without running it.

**The rule above every other rule here**: the README is written last, and it states nothing that
was not observed — by P11's evidence, by the lock file, or by the walkthrough's own evidence file
(constitution Principle I and the Evidence constraint). A predecessor fact is never carried over
because it used to be true of a different platform.

---

## 1. Section order — fixed

The predecessor's, in the predecessor's order. `make verify-readme` checks headings and order.

| # | Section | Predecessor content | This platform |
|---|---|---|---|
| 1 | `# agentic-netops-srl - Autonomous intent-to-fabric operations.` | title and tagline | the same tagline; the repository's real name |
| 2 | Badges, two rows | CI, merge queue, SONiC, FRR, Kubernetes, containerlab, Tutorial · AGNTCY, LangGraph, A2A, SLIM, gNMI, Prometheus, Grafana | row 1: CI and merge queue **only if those workflows exist**; **SR Linux `25.7.1`**, **SDC**, **KUID** in place of SONiC and FRR; Kubernetes; containerlab `nokia_srlinux`; Tutorial. Row 2 unchanged. Every version badge links to `versions.lock.yaml` and its text equals the lock file |
| 3 | Introduction | intent → agents → controllers → fabric, "kept that way"; "the agent tier is not an add-on"; "everything below is self-contained" | the same three paragraphs with "a live **SR Linux** EVPN/VXLAN fabric" and the one southbound named: provider → SDC `Config` → gNMI |
| 4 | `## Demo` | the 6× walkthrough, what it shows, the embedded asset, the evidence link | §3 below |
| 5 | `## The lab` | four figures with a paragraph each, then **What works and what does not** | §4 below |
| 6 | `## What you get` | four-row table: fabric, controllers, observability, intent tier | fabric: 2 `ixr-d3l` spines, 2 `ixr-d2l` leaves, 2 Linux clients. Controllers: the first-party fabric API and `agentic-netops-srl-provider`, SDC, KUID — **no SRv6 row** (deferred, RD-04). Observability: gNMIc → OTLP → collector → Prometheus → Grafana. Intent tier: unchanged in shape |
| 7 | `## Prerequisites` | the dependencies document and its two traps | the host requirements (x86-64 with SSSE3, no KVM, ≈2 vCPU / 2 GiB per node), and this platform's traps: the **management-CIDR overlap preflight** and the **operator login** (where the generated credentials are and how to read them) |
| 8 | `## Quickstart` | provision, verify, tear down; then "add the agent tier" with the `.env` provider block | the same two blocks with this platform's commands — **no `--profile` flag** — plus the line that reads the operator credentials from the generated Secret |
| 9 | `## Known limitations — read before trusting a run` | real, reproduced, documented | §5 below |
| 10 | `## Repository layout` | annotated tree | the tree **as built** |
| 11 | `## Policies enforced in CI` | Jumbo MTU; supply chain | §5 below |

Length and voice follow the predecessor's: about two hundred lines, plain declarative sentences, no
marketing adjectives, every claim followed by where to check it.

## 2. What must not appear

`make verify-readme` deny-lists, outside a sentence explicitly labelled as history:

- any predecessor platform term — `SONiC`, `sonic-vs`, `FRR`, `vtysh`, `CONFIG_DB`, `redis-cli`,
  `sonicprovider`, `fabric-executor`, `kubenet`, `SRv6Service`, `--profile`;
- any retired service name presented as something an operator can ask for (SC-033);
- any version, digest, timing or count that is not in `versions.lock.yaml`, in the walkthrough
  evidence file, or in P11's run-captured evidence;
- any credential, including in a figure or a frame (SC-031);
- `latest`, a floating tag, or a `raw.githubusercontent.com` URL.

## 3. The Demo section and the recording

**The scenario is the predecessor's, unchanged**: one silent 1920×1080 recording of the intent tier
end to end — three services provisioned from plain-language prompts typed into the operator console,
each confirmed through the mapper and the allocator, each reported deployed, each then proven in the
terminal with `kubectl` and inside the leaf — cut to **6×**. No captions, no overlays, no cuts
before acceleration; frames are dropped, not blended.

### 3.1 Prompts — frozen in `docs/DEMO_VIDEO.md`

| # | Construct | Predecessor | This platform |
|---|---|---|---|
| A | `vlan` | `Provision a vlan 170 on leaf01 ethernet1 for tenant acme` | `Provision a vlan 172 on leaf01 ethernet-1/1 for tenant acme` |
| B | `ip-vrf` | `Deploy an ip-vrf between leaf01 wan1 and leaf02 wan1 for tenant initech with prefix 10.53.0.0/24` | `Deploy an ip-vrf between leaf01 ethernet-1/1 vlan 255 and leaf02 ethernet-1/1 vlan 255 for tenant initech with prefix 10.55.0.0/24` |
| C | `mac-vrf` | `Extend vlan152 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue` | `Extend vlan154 as a mac-vrf across leaf01 ethernet-1/1 and leaf02 ethernet-1/1 for tenant blue` |

Same order, same tenants, same identifiers. A and C change the port name only. **B is the one
forced change**: this site has no `wan1` — its access ports are `leaf01 ethernet-1/1` and
`leaf02 ethernet-1/1`, and a routed attachment is a VLAN subinterface of that port
([../data-model.md](../data-model.md) §10). The smoke step validates all three against the site
inventory and the offline translator **before** the take; if B's wording must move again, it moves
in `docs/DEMO_VIDEO.md` with the reason, never silently in the driver. Identifiers 170, 152, 253 and
`10.53.0.0/24` are single-use: a second take needs new ones and a human decision.

**Second take (operator decision 2026-09-29, R-41).** The first take (170 / 253 / `10.53.0.0/24` /
152) failed at B on a driver defect and was deleted and reported verbatim. The operator chose new
identifiers for the second take — A VLAN 171, B VLAN 254 with `10.54.0.0/24`, C VLAN 153 — which the
table above carries in its last column (`docs/decisions/live-findings.md` `2026-09-29-p16-retake`).
The wording is otherwise unchanged. All three replacements lie in the naming band `100–999`.

**Third take (operator decision 2026-09-29, R-41).** The second take recorded A, B and C to
completion but failed acceptance on three acceptance-tooling defects; it was deleted by `accept.py`
and reported verbatim. The operator chose new identifiers for the third take — A VLAN 172, B VLAN 255
with `10.55.0.0/24`, C VLAN 154 — which the table above now carries in its last column
(`OPERATOR-DECISION-P16-TAKE3.md`; `docs/decisions/live-findings.md` `2026-09-29-p16-take3`). The
171 / 254 / `10.54.0.0/24` / 153 set is spent with the first take's.

**All three VLANs stay valid under the band split (AD-33).** 152, 170 and 253 lie in the naming band
`100–999`, and all three prompts **name** their VLAN, so the take allocates no VLAN at all and the
allocation band `1000–4000` is never drawn from. Nothing in the frozen scenario changes. A second
take must pick its replacements from `100–999` as well — a VLAN of 1000 or above is refused as the
authority's to hand out (FR-062) — and, because no VLAN is allocated here, the adoption and release
path of FR-109 is proven by `agents/tests/e2e/test_claim_lifecycle.py` and quickstart §26a rather
than by the recording.

### 3.2 On-screen proof — the same facts, read from SR Linux

Read-only throughout: `kubectl get` and `sr_cli` `info from state` reads. The driver changes
nothing on a device or in the cluster.

| Service | `kubectl` | Inside the leaf (predecessor → this platform) |
|---|---|---|
| A `vlan` | the `Network` `Ready=True`, its events, its spec | `redis-cli` VLAN key and `bridge vlan show` → the bridged network instance for the service with oper-state up, its subinterface `ethernet-1/1.172`, and **no** vxlan-interface on it |
| B `ip-vrf` | the same | tenant VRF, L3VNI and Type-5 route in `vtysh` → the `ip-vrf` network instance up, its routed subinterface, its vxlan-interface and VNI, and the EVPN IP-prefix route for `10.55.0.0/24` in its route table |
| C `mac-vrf` | the same | the VNI tunnel map on both leaves → **on both leaves**: the `mac-vrf` instance up, subinterface `ethernet-1/1.154`, its vxlan-interface and VNI, the EVPN instance, and the remote VTEP of the other leaf |

The exact `sr_cli` command lines are fixed in `docs/DEMO_VIDEO.md` after the smoke step has shown
what each prints on the pinned release; they are not guessed here.

### 3.3 Framing — kept from the predecessor's fixed driver

The whole topology fits the canvas viewport, asserted before every prompt and at the mapper stage;
the terminal is sized by font size, never by CSS zoom, and the take fails if the terminal screen is
clipped; the driver waits for the shell prompt to return before it screenshots or types the next
command, and `commands without a returned prompt` must be none; `--smoke` proves all three in about
a minute.

**New on this platform**: the console requires a login (FR-102). The driver logs in **before
recording starts**, so no frame and no log line carries a credential.

### 3.4 Acceptance — from the cluster, never from a frame

`accept.py` re-verifies every "deployed" claim from `kubectl` JSON and writes
`docs/media/agentic-netops-srl-intent-tier-demo-evidence.json`
([../data-model.md](../data-model.md) §24) with the NFR-013 fields. **`accept_pass: true` is the
only thing that admits a take.** A failed take is deleted and reported verbatim; it is not retried
with different wording, and the driver is not edited mid-take. Screenshots are for framing, never
for pass or fail.

### 3.5 What the section says

One paragraph in the predecessor's form — *Full walkthrough (~N min, 6x) — the intent tier end to
end: three services…* — with `N` taken from the cut's measured duration; then the embedded asset;
then the sentence *Every "deployed" claim in the recording was re-verified from `kubectl` JSON; the
collected evidence is in* with the link to the evidence file.

**The asset URL is the operator's to supply.** The predecessor embeds a GitHub user-attachment URL,
which exists only after a manual upload; that upload is outward-facing and is handed over, not
performed. Until it is supplied the README carries a marked placeholder line, and
`make verify-readme` **reports** it rather than passing silently.

## 4. The lab section

Four figures, captured from the **same live lab** that produced the accepted take, into
`docs/images/` under the predecessor's file names:

| File | Shows | Paragraph states |
|---|---|---|
| `lab-topology.png` | the Clos: two spines, two leaves, two clients, in native port names | the underlay and overlay in one sentence each |
| `grafana-fabric-telemetry.png` | the fabric dashboard with live data | the pipeline as built: gNMIc subscribes to native paths, exports OTLP to the collector, Prometheus stores, Grafana renders |
| `agent-ui.png` | the operator console mid-run, **logged in**, workers reachable, the mapper's interpretation shown before anything is allocated | that the scenario cards are what the supervisor serves on `GET /suggested-prompts`, in construct vocabulary, naming only ports this site has |
| `agent-ui-outcome.png` | the end of the same transaction | that `submitted` exists only because every apply succeeded, and what the console says when convergence is still in flight at the watch bound |

**What works and what does not** follows the figures, as in the predecessor, and is written from
P11's results: which constructs converge from plain language and when that was observed; what
`Ready=True` means here (the two-sided, keyed read-back, re-verified on a schedule); what is refused
before anything is submitted; that a one-shot request does not provision, and why; that both
surfaces require a login; that an out-of-band change is reported and never reverted; that a deletion
with a device away blocks rather than times out. **Anything the capability gate left unqualified is
named here as refused by name**, not omitted.

## 5. Known limitations and Policies — the constitution's sync item

The constitution's sync report defers these to the README's first writing; P12 discharges them.

**Known limitations** must state, with where each is recorded:

- IPv6 anycast gateway and IPv6 Type-5 origination: a capability-gate item, and what the gate
  observed; a service whose IPv6 Type-5 route is missing reports `Ready=False` naming it.
- Egress access lists: qualified or refused by name, per gate item G9.
- The containerized dataplane forwards a few thousand packets per second: nothing here asserts
  throughput.
- The allocation authority is dormant upstream; which authority this lab runs, and — if it is the
  substitute — the decision record.
- Operator credentials are lab credentials.
- SRv6 is deferred.
- Any pinned image with no local build step, with its remediation plan (Principle V).

**Policies enforced in CI** must state:

- **Jumbo MTU** — fabric port 9412, underlay IP 9398, tenant IP 9348 and endpoint interfaces set to
  it; acceptance probes 9320 (IPv4) and 9300 (IPv6) pass and one byte more fails.
- **Supply chain** — `make verify-pins` resolves every digest against its registry and fails on any
  drift, placeholder, floating tag or branch reference.
- **Evidence** — a result counts only as captured by the run that claims it, with a negative control
  for every readiness check (`make verify-evidence`).

## 6. Contract tests

| Property | Required proof |
|---|---|
| Section order | `make verify-readme` matches §1's headings, in order |
| No dead references | every relative link and image path resolves in the tree |
| Versions are the lock file's | every version the README states equals `versions.lock.yaml` |
| Constitution facts present | the MTU numbers, the pinning statement and the IPv6-gateway limitation of §5 |
| Deny-list | §2, including the credential scan over the README, the figures' alt text and the evidence file |
| The recording was accepted | the evidence file exists, carries the NFR-013 fields, and has `accept_pass: true` with `failures` empty |
| The prompts are the frozen ones | the evidence file's three prompts equal `docs/DEMO_VIDEO.md` byte for byte, in order, with constructs `vlan`, `ip-vrf`, `mac-vrf` |
| The principal is authenticated | all three `Network`s carry the generated operator username |
| The placeholder is visible | while no asset URL is supplied, the check reports the placeholder |
| Clean-host claim | the Quickstart block is the one SC-032's run used |
