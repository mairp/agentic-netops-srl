# Implementation Plan: Agentic NetOps on Nokia SR Linux — Composite Platform

**Branch**: `004-agentic-netops-composite` | **Date**: 2026-09-20 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/004-agentic-netops-composite/spec.md`

**Phase 0**: [research.md](./research.md) | **Phase 1**: [data-model.md](./data-model.md),
[contracts/](./contracts/), [quickstart.md](./quickstart.md) |
**Merge and retarget record**: [traceability.md](./traceability.md),
[platform-coupling.md](./platform-coupling.md), [evidence/](./evidence/)

This plan merges three source plans into one and retargets the result to Nokia SR Linux. The task
list generated from it is [tasks.md](./tasks.md).

**Refresh record — 2026-09-20.** This plan was re-run after the clarify session of the same day
([spec.md](./spec.md) §Clarifications). It now carries **FR-102** (authenticated operator),
**FR-103** (deletion blocks on an unreachable target), **FR-104** (allocator gate failure and the
recorded substitution), **FR-105** (out-of-band change detection), **SC-042**, **SC-043** and the
rescoped **SC-030**, designed in [research.md](./research.md) §12 as `CD-01`…`CD-05`; and, by
operator instruction, a final delivery phase **P12** whose **last task** writes the repository
`README.md` as the SR Linux counterpart of the predecessor's, with the predecessor's 6× recorded
walkthrough re-shot on this platform (`CD-06`, C-22). Three pre-clarification statements
contradicted the clarified specification and were corrected rather than carried: a deletion
*timeout*, a caller-asserted `principal`, and a runtime allocator "lease fallback". No identifier
was renumbered.

**Analysis remediation record — 2026-09-20.** The cross-artifact analysis run after task generation
was closed the same day ([spec.md](./spec.md) §Analysis remediation; [research.md](./research.md)
§13, `AD-01`…`AD-08`). This plan now carries **FR-106** (the model-provider Secret: a declared
gateway needs a base URL, and re-provisioning preserves it), **FR-107** and **SC-044** (scheduled
re-verification, five minutes by default), **FR-108** (the boundary around verification tooling —
RD-02 is unchanged), the exact verb sets of **FR-075**, the build-input pinning of first-party
images under **NFR-003**, `Fabric.spec.maintenance[]`, one table of default bounds
([data-model.md](./data-model.md) §25), risk **R-43**, and the execution order recorded under
§Delivery phases. No identifier was renumbered.

**Second analysis pass — 2026-09-20.** A re-run of the analysis found no constitution conflict and
full task coverage, and thirteen smaller findings, closed the same day ([spec.md](./spec.md)
§Analysis remediation, second pass; [research.md](./research.md) §13, `AD-09`…`AD-15`; two of them
operator decisions). This plan now carries **FR-109** and **SC-045** (the provider adopts or makes
the VNI claims of a `Network` that arrives without the tier — the allocation authority arbitrates,
gate item G11 is widened to observe a stated-value claim), **NFR-014** (structured logs, the carrier
Principle IV's log rule lacked), the one admitted pin exception stated as such (NFR-003), the
drift policy as a provider setting with no default (FR-015), risk **R-44**, and three passages about
the force-release admission probe brought into line with the execution order of `AD-08`. No
identifier was renumbered.

**Third analysis pass — 2026-09-20.** A third run found no constitution conflict, full task coverage
and fifteen findings, two of them high and both seams the second pass had opened; all were closed the
same day at the operator's instruction ([spec.md](./spec.md) §Analysis remediation, third pass;
[research.md](./research.md) §13, `AD-16`…`AD-22`; `AD-16` and `AD-17` are design choices recorded
with their alternatives). This plan now carries **FR-109 widened and SC-046** (the provider adopts
and releases the tier's VLAN claims, so every claim of a submitted service has one release owner),
the **closed drift-policy set of one** (FR-015), the **audit record** as the trace-borne event in the
analytics store with Kubernetes Events as a deployer-side mirror only (FR-078), the **per-source
measuring point of SC-028**, **one tagging mode per port** (FR-034), **host-side tooling pins**
(NFR-003, [data-model.md](./data-model.md) §28), risk **R-45**, and ten live identifiers its
component inventory had never cited. No identifier was renumbered.

**Fourth analysis pass — 2026-09-20.** A fourth run found no constitution conflict, full task
coverage and fifteen findings, two of them high; all were closed the same day at the operator's
instruction ([spec.md](./spec.md) §Analysis remediation, fourth pass; [research.md](./research.md)
§13, `AD-23`…`AD-30`; `AD-23`, `AD-26` and `AD-27` are design choices recorded with their
alternatives). This plan now carries **`Fabric` readiness without a route count** — sessions, the
EVPN family's own operational state, the allocated loopbacks reachable, and the reflecting spines'
`inter-as-vpn` and `route-reflector client` read back as a configuration-integrity check that is
stated as one, route exchange being each spanning service's invariant (FR-100, SC-004, AD-31); the **audit record exported unconditionally
before anything removes its store**, with a named discard flag as the only way past a failed export
(FR-078); **allocated identifiers immutable once accepted** (FR-109); the **tier's removal refusing while the
services it submitted exist, and deleting them only when asked — quiesced, bounded and never
forced**, with hand-applied services in the control-plane-owned namespace `agentic-netops-services`
(NFR-006); the **allocated-VLAN collision
refused by name** (FR-062); **make targets and CI jobs for every offline suite** (FR-020); the
optional **`MigrationPlan` brought into line** with FR-012 and given an install rule and a host
(FR-048); the generated **`grafana-admin`** credential (FR-096); the measured node footprint
(NFR-004); risks **R-46** and **R-47**; and task **T174**. No identifier was renumbered and no
requirement was added.

**Operator review — 2026-09-20.** After the fourth pass the five design choices the analysis had made
without the operator, and both reviewer-owned checklists, were researched by independent agents
([review/2026-09-20/](./review/2026-09-20/), `DECISION-SHEET.md`) and **decided by the operator**
([spec.md](./spec.md) §Operator review; [research.md](./research.md) §13, `AD-31`…`AD-39`). This plan
now carries: `Fabric` readiness with its reflection read stated as configuration integrity, three
further keyed reads and an evidence-only post-render probe (`AD-31`); sticky three-part claim adoption,
the finalizer set at apply, and the submitted-check moved to the deployer with FR-075 unwidened
(`AD-32`); **disjoint VLAN bands** — named 100–999, allocated 1000–4000 — in place of the fourth
pass's collision refusal (`AD-33`); the drift-policy set closed at `revertive` on a corrected
rationale, stated in one place, with gate item **G13** (`AD-34`); a tier removal that **refuses while
tier-submitted services exist unless `--remove-services`**, quiescing first (`AD-35`); a specified
audit export (`AD-36`); the checklist closures (`AD-37`…`AD-39`) with **SC-047…SC-050**; risk **R-48**
and task **T175**. No identifier was renumbered; no checklist item was ticked.

**Fifth analysis pass — 2026-09-21.** One constitution conflict and twelve high findings, most in the
operator review's own propagation ([spec.md](./spec.md) §Fifth pass; [research.md](./research.md) §13,
`AD-40`…`AD-50`). Four are **operator decisions**: a re-verification that could not run sets
`Ready=Unknown/VerificationFailed` (`AD-40`); the naming band is enforced at the mapper and the
translator stays structural (`AD-41`); VNI and VLAN claims are adopted on label, deterministic name
and value alike (`AD-42`); SC-004's negative control is the declarative fault
`Fabric.spec.overlay.interASVPN: false` (`AD-43`; its field is `overlay.reflectorClients: false` as
decided in `AD-77`). Two are reversible choices: finalization resolves
adoption before it releases (`AD-44`), and the analytics store is installed with the tier, ahead of
its first reader (`AD-45`). `AD-46`…`AD-50` are closures; **CR-009** and **CR-010** were added. No
task, requirement, success criterion, risk or gate item was added or renumbered.

**Sixth analysis pass — 2026-09-21.** No constitution conflict; six high findings, second-order
effects of the fifth pass ([spec.md](./spec.md) §Sixth pass; `AD-51`…`AD-60`). Three are **operator
decisions**: an `ip-vrf` attachment's VLAN is named or absent and never allocated (`AD-51`); the
validating webhook fails closed (`AD-52`); an object being deleted reports `Ready=False/Deleting` at
once (`AD-53`). `AD-54`…`AD-60` are closures. One reason code (`Deleting` on `Ready`) was added; no
identifier was added or renumbered; 46 of the 48 risks are live (R-03 is live, `AD-59`).

**Seventh analysis pass — 2026-09-21, and the end of the review loop.** No constitution conflict and one
high finding: the fail-closed webhook evaluates a create and a `spec`-changing update only, so
finalization and the force-release are never refused by it (`AD-61`). `AD-62`…`AD-67` are closures;
`AD-63` is a reversible choice — a removal asked of the tier ends when the object is gone, or reports
what it still waits for. No identifier was added. With no critical or high finding left, readiness is
decided by a deterministic gate over the artifacts, and the remainder is settled at implementation.

**Eighth analysis pass — 2026-09-21, bounded.** Gate green, no constitution conflict, three high
findings closed. By **operator decision** the leaves two services would share — an access port's
`admin-state` and `vlan-tagging`, `irb0`'s `admin-state` — are rendered by the fabric's priority-10
`Config`, the port's tagging mode is declared in the inventory (`untaggedAccessPorts`), and a
subinterface's access-list `interface-ref` is rendered with the subinterface, so FR-015's same-leaf
refusal is a backstop and no longer refuses two services on one port (`AD-68`). Every generated
`Config` lives in `agentic-netops-system` and a service's carries no owner reference (`AD-69`). T047
follows T052's gate run (`AD-70`). The pass's seven medium findings were then closed in `AD-71` — a
pending first-party image, the owner of the SC-004 recording rule, `sdc-lite` named and pinned, a
purge that scales down what exists, both modes of `delete_unreachable.sh`, a finding whose node has
left the inventory (a recorded choice), and the layer's target-loss latency measured — and its low
findings in `AD-72`. The operator then ratified the five choices the passes had made on their own
recommendation (`AD-73`), so none remains unratified. No identifier
was added; Open items 19 and 20 were.

## Summary

Build one open-source, Kubernetes-native platform in which an operator describes a datacenter
service in plain language and a multi-agent intent tier turns that description into declarative
fabric intent, which a first-party declarative control plane reconciles onto a containerlab
**Nokia SR Linux** EVPN/VXLAN fabric and an end-to-end telemetry pipeline observes.

The platform has three layers and one boundary:

```text
natural language ─► intent tier ─► declarative intent ─► control plane ─► SR Linux fabric
                         │                  │
                         └── cannot cross ──┘   the tier never touches a device;
                                                its identity cannot express the action
```

The operator vocabulary is four datacenter constructs — `vlan`, `mac-vrf`, `ip-vrf`, `acl`. Two of
them are the device's own names for its bridged and routed network-instance types, and that
alignment is a requirement (FR-099), not a coincidence. The retired service-provider names survive
as input aliases on the migration path and as recorded provenance, never as something an operator
can ask for. Symmetric IRB is a `mac-vrf` carrying an anycast gateway, not a fifth type.

The control path is one path, with no alternative:

```text
intent tier ─► Network (fabric.agentic-netops.io/v1alpha1)
            ─► agentic-netops-srl-provider ─► SDC Config ─► gNMI 57400 ─► SR Linux
```

with **KUID as the allocation authority** — IP, ASN, VLAN and VNI claims, consumed through its
served `Index`/`Claim`/`Entry` APIs and never re-implemented. Every other device identifier is a
deterministic function of an allocated value, the service identifier or a fabric-wide constant
(FR-012).

**What the predecessor got wrong, and what this plan does instead.** The three source features
describe a SONiC deployment whose recorded southbound was a host-side executor driving the device's
configuration store directly, outside the cluster that was specified as the sole application
runtime, and whose "upstream" fabric control plane was in fact hand-written look-alike CRDs
installed into upstream API groups. Both are history, not design: this repository is greenfield and
contains no implementation. This plan carries the *lesson* in three places — one southbound with no
escape hatch (FR-007 with no exception, FR-014, FR-015), no look-alike CRDs in any upstream group
(FR-098), and evidence integrity for every gate and acceptance result (NFR-013). The record itself
lives in [spec.md](./spec.md) §Inherited acceptance record and in
[platform-coupling.md](./platform-coupling.md); nothing here re-litigates it, and no section of this
plan carries a live divergence.

## Technical Context

**Control-plane language**: Go, at the current stable toolchain pinned in `versions.lock.yaml`,
selected by the pinned Kubernetes and controller-runtime compatibility matrix — stated in `go.mod`,
recorded from there in the lock file, and `make verify-pins` fails when the two differ (AD-50). The
predecessor's `1.22.5` pin is not inherited. Packages: `pkg/migration`, `pkg/fabricapi`, `pkg/register`,
`pkg/sdc`, `pkg/kuid`, `internal/render/srl`, `internal/verify`, `internal/webhook`,
`controllers/fabric`, `controllers/network`,
`controllers/migration`, `cmd/srl-provider`, `cmd/migration-translator`, `cmd/intent-translator`.

**Intent-tier language**: Python `>=3.13,<4.0` on `python:3.13.0-slim`, under `agents/`. Unchanged
by the retarget.

**Browser app**: Vite/React on `node:20-alpine`, under `ui/`. Unchanged by the retarget.

**Platform**: a Linux host — x86-64 with SSSE3, kernel ≥ 4.10 — a Docker-compatible runtime, a
pinned Kind cluster and node image, and containerlab. **No KVM and no nested virtualization**, and
one lab profile only: no flag selects a device profile, and the predecessor's `--profile` split does
not exist. Budget ≈ 2 vCPU and 2 GiB per network node (1.4–1.8 GiB RSS idle measured in research,
re-observed at P0).

**Primary dependencies**, as the nine-part compatibility set plus the observability set
([evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md) §7, RD-01, RD-11):

1. SR Linux `ghcr.io/nokia/srlinux:25.7.1` @
   `sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402`;
2. `nokia/srlinux-yang-models` tag `v25.7.1` = commit `badcf9977fe672437907cdae7daebb27a1361c36`;
3. `sdcio/srlinux-yang-patch` pinned **by hash** `7410316d34f1d393b82889c0caa1b5acef80fb60`
   (branch `v25.7`; a branch ref is mutable and forbidden); as decided (AD-75), `config-server v0.0.58`
   reads a `hash` ref as a tag and the repository has no tags, so the locked commit is served by an
   **in-cluster git mirror** (`schema-mirror` in `sdc-system`), asserted equal to the locked commit and
   exposed under a tag named after it, and the `Schema` references the mirror by that tag — the lock
   still records the upstream repository and commit; the same mirror serves the first-party deviation
   module `agentic-netops-tunnel-deviations.yang` at a content-pinned tag (AD-82
   `2026-09-21-feature-guarded-must`), and a changed `Schema` costs one data-server restart (AD-82
   `2026-09-21-schema-reload`);
4. the SDC `Schema` CR definition — `provider: srl.nokia.sdcio.dev`, `version: 25.7.1`,
   `models: [srl_nokia/models]`, `includes: [ietf, openconfig]`, `excludes: ['.*tools.*']`;
5. the device-configuration layer (sdcio) — `config-server v0.0.58` (api-server and controller
   images) and `data-server v0.0.72` (re-pinned from `v0.0.66`, which never reverted drift — AD-80),
   by digest, with **cert-manager as a pinned prerequisite** for its aggregated API server; this
   release serves no state datastore, so every applied-side read comes from the device metric
   collector (part 8; AD-82 `2026-09-21-state-source`);
6. the allocation authority the lock selects — on this lab the **first-party substitute**
   (`IdentifierPool`/`IdentifierClaim` in `fabric.agentic-netops.io`, namespace
   `agentic-netops-allocation`, run by the provider binary with `SRL_PROVIDER_ROLE=allocation-authority`;
   `allocationAuthority.kind: first-party`), adopted after G11 failed on kuid and passed on it (AD-74);
   the documented alternative the lock can select, never coexisting (CD-03), is KUID
   `kuid-server v0.0.13` @
   `sha256:d6fdae78cc5ba4d14655ef2e77bc3c38eb8201679b52aef56bf550e332800608`;
7. containerlab `0.79.0`;
8. gNMIc `0.47.0`, with its native `type: otlp` output, as the sole device metric collector;
9. the provider's mapping version `srl-mapping v0.1.0`, stamped on every generated `Config` and
   asserted against parts 1–4.

Observability set: an upstream OpenTelemetry Collector, Prometheus, Grafana with
`andrewbmchugh-flow-panel 1.20.1`, and `clab-io-draw` pinned by tag and digest as the topology-asset
generator. Kubernetes: `kind v0.27.0` on the reference host, node image pinned by digest in the lock
file. Intent tier: `agntcy-app-sdk==0.4.5`, `a2a-sdk==0.3.0`, `ghcr.io/agntcy/slim:0.6.1`,
`langgraph>=0.4.1`, `langgraph-supervisor`, `litellm[proxy]==1.75.3`, `langchain-litellm>=0.3.0`,
`ioa-observe-sdk==1.0.24`, `agntcy-identity-service-sdk==0.0.7`, `pydantic>=2.11.4`,
FastAPI/uvicorn/starlette, `langgraph-checkpoint-sqlite`. Every reference above is pinned by digest
or commit in `versions.lock.yaml`; where a digest is not quoted here it is pinned by digest in the
lock file at P0 and resolved by `make verify-pins`.

**Storage**: the Kubernetes API for desired and status state; in-cluster volumes for the
device-configuration layer's state, the metrics store, the supervisor's checkpointer and the
agent-analytics store. No host application database is added.

**Southbound**: exactly one path — the provider renders a `Config`, the device-configuration layer
validates it against the pinned schema and applies it over **gNMI with JSON_IETF and TLS on port
57400** as a transaction that rolls back on rejection. gNMI Set writes the running datastore only;
persistence comes from `/system/configuration/auto-save` set in the bootstrap configuration. There
is no executor, no host-side component, no raw-store client, no whole-config write path and no
escape hatch. SSH, JSON-RPC, NETCONF and the plaintext gNMI port the image also exposes are never
used by the platform. The intent tier holds no southbound of any kind. The tools that *check* the
platform — the capability gate, fault and drift injection, the walkthrough's read-only device proofs
— are not on this path and nothing depends on them; FR-108 bounds them (run-captured, scratch or a
declared fault only, self-removing, lab operator credentials, never reachable from the tier), and
`make verify-boundaries` fails a device client invoked from anywhere else (AD-03).

**Model access**: LiteLLM, provider selected by a model-name prefix carried in a Secret, so a
provider switch is a Secret change rather than a code change. The Secret is generated and **merged,
never replaced**: a declared gateway with no base URL is refused before any tier workload exists,
a re-provisioning run that omits the base URL keeps the stored one, and the endpoint model calls
will use is printed at provisioning and logged by every agent at start-up — redacted, on both, of
any credential the base URL embeds (FR-079). The endpoint is resolved from the mounted Secret on
every model call, so an agent whose Secret loses its base URL while running stops calling the model
and says so, rather than falling back to the library default (FR-106, AD-01, AD-49).

**Device targets**: SR Linux 25.7.1 on containerlab kind `nokia_srlinux` — **two `ixr-d3l`
spines** (`spine01`, `spine02`) and **two `ixr-d2l` leaves** (`leaf01`, `leaf02`), both licence-free
types carrying the full EVPN-VXLAN feature set, plus **two Linux clients** (`client01` behind
leaf01, `client02` behind leaf02) that take part in several services at once over VLAN
subinterfaces on their single link. Interfaces are named natively — `ethernet-1/N` everywhere,
`e1-N` on the Linux side.

**Testing**: Go unit and golden tests; CRD structural schema, CEL and server-side dry-run against a
real schema; controller envtest; **SDC schema validation of every golden render**; the native-first
path-register guard; per-construct render assertions; the **capability gate G1–G13** with a
**recorded negative control for every readiness check** (NFR-013); containerlab integration, traffic
and failure tests including the **ACL enforcement probe** (SC-041); Python contract, graph-routing
and corpus tests (a phrasing corpus and an adversarial corpus); RBAC and NetworkPolicy denial
probes; live-cluster end-to-end runs; and a tier-absent control-plane gate run.

**Reference scale**: one operator and a small number of concurrent conversations; 2 spines, 2
leaves, 2 Linux clients; at least one local `vlan`, one `mac-vrf` with an L2VNI, one `mac-vrf`
carrying an anycast gateway into an `ip-vrf`, two isolated `ip-vrf` instances, and an access list in
each of its two shapes — as a service and as a property of one.

**Network policy and MTU** (RD-10): 7220 IXR port MTU maximum **9412**; fabric links `mtu 9412`;
underlay `ip-mtu 9398`; tenant IP MTU over VXLAN **9348** (`port MTU − 64`), which client interfaces
MUST also be set to because containerlab's veth default of 9500 blackholes TCP; IRB subinterface
`ip-mtu` set explicitly, because the device performs no VXLAN MTU check. Acceptance probes size ICMP
payloads at **9320 (IPv4)** and **9300 (IPv6)** — those pass, one byte more does not. The VXLAN
tunnel endpoint is IPv4-only. These numbers were measured in research and are re-observed at P0 as
gate item G6.

**Constraints**: immutable version pins carried forward, never bumped opportunistically; exact
image, schema and mapping qualification as one nine-part compatibility set; **no look-alike CRD in
any upstream API group**, ever, and no fallback to one when an upstream artefact cannot be fetched
(FR-098); **two `Config` objects that can touch the same device leaf never share a priority** —
fabric configs at priority 10, service configs at 20, and an overlap is a conflict refused at
validation rather than an ordering left to the layer — a leaf being a non-key leaf, and the leaves
two services would share (an access port's `admin-state` and `vlan-tagging`, `irb0`'s `admin-state`)
being rendered by the fabric config from the inventory's declared tagging mode (`AD-68`); every
generated `Config` lives in `agentic-netops-system`, a service's carrying no owner reference
(`AD-69`); a **native-first path register**, with every
rendered and subscribed path native `srl_nokia` unless the register records a justified exception;
no silent semantic loss; scoped field ownership; no second translation implementation; one emission
per telemetry signal; no credential literal in any manifest; deterministic YAML so golden files are
a real contract; a privileged lab runtime as a documented trust boundary; no proprietary runtime
anywhere in the dependency graph; and **no test ever asserts throughput**, which the containerized
dataplane (≈ 1–5 kpps per node) does not provide.

**Constraints added by the 2026-09-20 clarifications** (CD-01…CD-04): **no principal is ever a name
the caller asserts** — both operator surfaces authenticate against a generated Secret and an
unauthenticated request is refused before a thread exists (FR-102); **no timer ever releases an
identifier or removes a service object** — deletion blocks on an unreachable target and the only
other exit is an annotated, admission-guarded, durably recorded force-release that the intent tier's
identities cannot perform (FR-103); **exactly one allocation authority per lab, selected by the lock
file and never by the provisioning script** (FR-104); and **the cluster, not the conversation, is
the record of a service** — the tier detects and reports an out-of-band change and never reverts,
re-creates or overwrites (FR-105).

**Constraints added by the 2026-09-20 analysis** (AD-01…AD-07): **`Ready=True` is re-verified on a
schedule, never remembered** — the same two-sided read-back every five minutes by default, with the
last-verified time in status and in a metric (FR-107); **a first-party image is pinned by its build
inputs** — every `FROM` by registry-resolved digest, every dependency lock file by hash, a
content-hash tag, a never-pull policy, and the built image ID in the run's evidence (NFR-003,
[data-model.md](./data-model.md) §26); and **every bound has one stated default**
([data-model.md](./data-model.md) §25), with `convergence timeout < deployer call timeout < request
deadline` asserted at start-up.

**Constraints added by the second analysis pass** (AD-09…AD-15): **every VNI on a `Network` is backed
by a bound claim before anything is rendered, whichever way the object arrived** — the provider
adopts the tier's claim by correlation label or claims the stated value itself through `pkg/kuid`,
and a value held elsewhere is `Accepted=False/AllocationConflict`, never re-chosen (FR-109); **two
ranges, two names** — the *device range* `1..65535` is the CRD's CEL rule, the *allocation band* is
the VNI index's own range and is enforced by the translator and by the authority; **first-party
workloads log one JSON object per line** with the correlation identifier where one exists (NFR-014);
**exactly one pin exception is admitted** and the lock file has no field for another (NFR-003); and
**the drift policy has no default** — the provider refuses to start without `DRIFT_POLICY`, which lab
provisioning sets to `revertive` (FR-015).

**Constraints added by the third analysis pass** (AD-16…AD-21): **every claim of a submitted service
has one release owner, the provider** — it adopts the tier's VLAN claim by the same rule as its VNI
claims and releases both at finalization, the tier releasing only provisional claims (FR-109), with
the operator's amendments of `AD-32` making adoption a once-per-value decision that matches on
correlation label, deterministic claim name **and** a value the object carries — VNI and VLAN
claims alike, under the one naming scheme `<namespace>.<name>.<role>` (`AD-42`), and resolved at
finalization for an object deleted before it was ever reconciled (`AD-44`) — placing the
finalizer at apply time, and giving the *deployer* — never the allocator — the job of saying which
correlation identifiers are still provisional, so FR-075 is untouched; **the drift-policy set is closed at `revertive`** — the device-configuration layer's
non-revertive mode holds the deviation for an operator to accept or revert rather than repairing it
itself, a shape this feature does not build, so it is not an admissible value (FR-015; rationale
corrected by AD-34); **the audit record is the trace-borne event in the agent-analytics store**, and only the
deployer mirrors the events it decides as Kubernetes Events (FR-078); **"zero device sessions" is
counted per source inside the cluster nodes**, never on the management network (SC-028); **an
untagged and a tagged attachment never share a port** (FR-034); and **host-side test and recording
tooling is pinned in the lock file** (NFR-003).

**Operator authentication**: HTTP Basic verified by the supervisor against the generated Secret
`operator-credentials`, mounted read-only; the two probe routes stay open; both surfaces are
published on `127.0.0.1` only. Lab credentials, stated as not production-safe (FR-019, CD-01).

## Constitution Check

*GATE: must pass before Phase 0 research; re-checked after Phase 1 design.*

**Source**: `.specify/memory/constitution.md` **v1.1.0**, ratified 2026-09-05, amended 2026-09-20
for the SR Linux platform (technology stack, MTU policy, and the replacement of the retired
IPv6-IRB limitation by the IPv6 anycast-gateway / IPv6 Type-5 gate item).

**This is a greenfield repository with no implementation, no cluster and no fabric.** There is
nothing here to have passed or failed. The gate below therefore evaluates the *specification* — what
it obliges the build to do — and says so where an obligation exists precisely because the
predecessor's deployment did the opposite.

| # | Principle | Verdict | Reason |
|---|---|---|---|
| **I** | Truthful, closed-loop reporting | **PASS** | Readiness is two-sided for **every** construct — the written side (`Config` applied, no deviation, content present in the running datastore) **and** the applied side (the device's own state, read — as decided, the pinned `data-server v0.0.72` serving no state datastore — through the device metric collector, FR-086's second device client; AD-82 `2026-09-21-state-source`) — and every applied-side read is **keyed to this service's own objects**: filter name, type and entry; instance, subinterface, tunnel and EVPN-instance oper-state; the remote VTEPs and EVPN routes the service requires (FR-100, FR-042). Partial success is never aggregate Ready (FR-018); conditions name the missing invariant and surface the device's own reason (NFR-005, CR-001). The predecessor's applied-side access-list check was switch-wide and so passed on a stock fabric; **that defect is closed by construction here** — a fabric-wide or device-wide count is not admissible evidence under FR-042/FR-100, so the check cannot be written that way. No claim of observation is made: nothing has been run in this repository, and NFR-013's negative control is what will show the check can fail before any pass counts. The clarifications extend the same rule to two places it did not reach: a status or removal answer is built from the **live** object and says so when it no longer matches what the tier submitted, never from the remembered one (FR-105); and a deletion that cannot be read back from an unreachable device is reported as blocked with the device named for as long as that is true, never as complete (FR-103) — the tier holds to the same rule: a removal it was asked for is reported complete only once the object is observed gone, and otherwise as in progress with what is outstanding named, never on the strength of an accepted delete (FR-069, AD-63) — and the object being deleted reports `Ready=False/Deleting` from the moment its finalization starts, in every deletion, so that no `Ready=True` outlives the service it described and no read-back is asked to decide what a deletion already has (operator decision, AD-53). The schedule the principle names is a requirement of its own: every Ready object is re-read every five minutes by default, a missing invariant sets `Ready=False`, and a stalled schedule is visible in status and alertable (FR-107, SC-044). **The pass that cannot run is where the principle bites hardest, and it is met by a third state rather than by either of the two that lie**: with a required target unreachable, a read timed out, or the device metric collector holding no sample for a node or not answering (AD-82 `2026-09-21-state-source`), an object that had reported Ready goes to `Ready=Unknown/VerificationFailed` with `Degraded=True/VerificationFailed` naming the target, at that pass — not `Ready=False`, which would report an invariant lost that nobody observed to be lost, and not a standing `Ready=True`, which is precisely the "prior reconciliation result" the principle forbids. `lastVerifiedTime` does not advance, the next pass that runs settles it either way, and nothing above — the tier's watch and its status answers included — reads `Unknown` as success (operator decision, AD-40; FR-054, FR-067). The `Fabric`'s own readiness is held to the same keyed-evidence rule and **never a fabric-wide route count**, which would be unkeyed and — before any service exists — unsatisfiable, the kind of check that ends up weakened to pass (AD-23). It reads as true operational state its interfaces, its sessions, the EVPN family's own `oper-state` per neighbour and the presence of every other node's allocated loopback in this node's route table; it reads the reflecting spines' `inter-as-vpn` and `route-reflector client` as a **configuration-integrity** check and says so, because both are configuration leaves — read, as decided, from the configuration datastore, SR Linux 25.7.1 not mirroring them into state (AD-76) — and neither shows that reflection works — the behavioural proof is G8, T051's post-render probe and the first spanning service (AD-31). The closing README is bound by the same principle: it is written last, and every claim in it and every "deployed" in its recording is re-verified from cluster JSON by the acceptance script (CD-06). |
| **II** | Intent tier drives the network, with explicit safety gates | **PASS** | Two explicit human confirmations (FR-055, CR-002) with a decline path that releases every provisional claim (FR-056); no one-shot provisioning; unknown nodes and ports refused up front with the valid names enumerated (FR-034, FR-059, CR-003); a construct or property the capability gate has not qualified refused **at interpretation**, by name, before anything is claimed or created (FR-097); no service type presented or provisioned that the operator did not ask for — the proposal is the named construct and what its profile allocates, a gateway adds only the declared address families, and a gateway-less `mac-vrf` creates no routed instance and claims no L3 identifier (CR-002; FR-024, FR-029, FR-032, FR-062) — and a variable that belongs to another construct refused rather than ignored (FR-033); the evaluation order and usable priority range stated at the first confirmation, and unmatched-traffic behaviour stated rather than implied (FR-039, FR-041); every action auditable (FR-078), in a record that is exported before anything — shutdown or the tier's own removal — deletes the store that holds it (AD-24) — **under a principal the platform authenticated, never one the caller asserted**, with an unauthenticated request refused before a thread exists, a model is called or an identifier is claimed (FR-102, SC-042). An out-of-band edit is detected and reported but never "repaired": any further change is a new request with its own two confirmations (FR-105). The force-release break-glass is denied to both tier identities by admission policy, so the identity that reads operator text cannot release an identifier a device may still carry (FR-103, CD-02). |
| **III** | Declarative, deterministic operations | **PASS** | Every change follows translate → server-side dry-run → apply → rollback on failure → convergence watch (FR-065 to FR-067, CR-004) — the server-side dry-run of every object, any rejection aborting the bundle, is a MUST of FR-066. "Dry-run" is now two real things: Kubernetes server-side dry-run against a first-party CRD that has a **real structural schema and CEL rules**, and the device-configuration layer's own schema validation before any gNMI Set (RD-02). Reconciliation is idempotent (NFR-001, SC-006), teardown is re-runnable (FR-010, SC-003), all-or-nothing validation means an unrenderable object is never stranded (FR-045, FR-066, SC-015), and a rejected device transaction rolls back and fails **its own** transaction only — nothing poisons a later commit. Teardown of a service stays safe to re-run when a device is away: finalization blocks with every allocation held and completes by itself on the device's return — no timeout path exists (FR-103, SC-043). |
| **IV** | Observability-first | **PASS** | The mandated path is gNMIc → OTLP → OpenTelemetry Collector → Prometheus → Grafana (FR-087 to FR-089, FR-094, CR-005), with gNMIc's own `/metrics` scraped so every pipeline stage has evidence. Structured logs are NFR-014 — one JSON object per line from every first-party workload, carrying the resource identity and the correlation identifier where one exists, redacted — and surfaced conditions are NFR-005. Every subscribed path carries its derived metric name, labels and stream mode in the path register (FR-017), and a change that alters what can be observed updates the dashboards in the same change (FR-096). The tier adds one emission with collector-side fan-out (FR-091), not a second pipeline. |
| **V** | Reproducibility and supply-chain pinning | **PASS — by obligation, nothing observed yet** | No deployment exists here to violate the principle. The specification states it in the strengthened form the predecessor's record demands: **NFR-003** forbids a placeholder or synthetic digest outright, forbids `latest`, a floating minor tag and a branch reference *wherever a reference can appear* — including inside the `Schema` CR, Grafana plugin installs and generator images — and requires the pin check to **resolve every digest against its registry**, so an unpullable pin fails before provisioning rather than during it; intent-tier images have a local build step and live in the same lock file — and because a locally built image has no registry digest to resolve, a first-party image is pinned by what *can* be resolved, its `FROM` digests and its dependency lock files, tagged by content hash and identified per run in evidence (AD-05). **FR-017** binds the nine-part compatibility set; **CR-006** carries the gate into every PR. The predecessor's placeholder digests and unpinned `:latest` tier images are the reason those clauses are worded that way — see [spec.md](./spec.md) §Inherited acceptance record. Which allocation authority a lab runs is part of the compatibility set, selected by the lock file alone, warned at provisioning when it is the substitute, and checked by `make verify-compat` to be the only one installed (FR-104, CD-03) — the "known exception, explicitly warned, with a remediation plan" clause of this principle, applied, and the **only** exception this specification admits: the lock file has no field in which another could be declared, so anything else the pin check cannot hold fails rather than warns (AD-12). The first evidence is P0's `make verify-pins`; until it runs, this is an obligation and is reported as one. |
| **VI** | Verification and test discipline | **PASS — by obligation, nothing observed yet** | Coverage is specified (FR-020, the G1–G13 capability gate in FR-004, and the verification strategy below), and acceptance packets follow the amended MTU policy (CR-009: 9320/9300 payload boundary, reachability and counters only, never throughput), and the IPv6 gateway and IPv6 Type-5 limitation is a gate item with a `Ready=False` obligation (CR-010). **NFR-013** makes every gate and acceptance result evidence captured by the run that claims it — command, UTC time, exit status, image digest, cluster and lab identity, with the raw output — declares a hand-authored or post-edited proof non-conforming, and requires a **recorded negative control**: a check counts only once it has been shown to fail on a stock fabric. **SC-040** measures that. **CR-007** keeps "a gate MUST NOT be waived to make a run pass": a capability the gate cannot qualify is refused by name (FR-097) or reported `Ready=False`, never relaxed. The predecessor's three disputed approval records — an inverted success check, a hard-coded metric cell, and gate proofs contradicted by genuine captures in the same folder — are exactly why NFR-013 and SC-040 exist. Nothing has been verified here yet. |

**Additional constraints.** The constitution's *Secrets and LLM configuration* constraint is carried
by CR-008: no credential literal in any manifest (FR-019), redaction everywhere (FR-079), generated
operator credentials (FR-102), and the model-provider Secret's base-URL rules (FR-106). Its *Safety*
and *Network policy* constraints are carried by CR-003 and by CR-009 — the MTU envelope and the
probe sizes, re-observed by G6 — its *Known limitation* by CR-010; its *Evidence*
constraint by NFR-013 — under which the verification tooling of FR-108 is itself run-captured.

**Post-design re-check, 2026-09-20 refresh.** Re-evaluated after the Phase 1 artefacts were
regenerated for CD-01…CD-06. The refresh *removed* three latent conflicts with Principles I–III
(a deletion timeout, a caller-asserted principal, a silent allocator fallback) and introduced none.
P12 adds documentation and a recording, both bound by Principle I and the Evidence constraint, and
discharges the constitution's pending README sync item (MTU, pinning and IPv6-gateway facts).

**Re-check after the analysis remediation, 2026-09-20.** The analysis found one constitution
constraint with no requirement (the LLM base URL — now FR-106, CR-008) and one carried only by a task
clause (scheduled re-verification — now FR-107, SC-044). Both are closed by requirements, a measure
and tasks; neither needed a principle reinterpreted. The development-workflow gates — operator-facing
rationale on every PR, and operator review plus a lab test for any change to confirmations, refusal
logic or transaction phases — are given a mechanism in Setup: a PR template and a CODEOWNERS file
over the supervisor graph, the guards and the deployer.

**Re-check after the second analysis pass, 2026-09-20.** No principle was in conflict. Principle IV's
structured-log rule had been attributed to NFR-005, which does not state it; it is now NFR-014, with
tasks. Principle V's exception clause is now explicit about how many exceptions exist. FR-109 extends
Principle I's reach rather than touching it: a `Network` is not rendered on an identifier the
allocation authority has not bound.

Six of six pass. **No principle failure is carried and no exception is requested.** Principles V and
VI are marked as obligations rather than as results deliberately: this repository has produced no
run, and reporting either as satisfied would be the Principle I failure the specification was
written to prevent. Complexity Tracking below records the two justified complexities of the design
itself.

## Architecture

One picture: fabric, control plane, construct vocabulary and intent tier together. The southbound is
drawn once, because there is only one.

```text
      scripts/provision.sh [--with-intent-tier]   ·   scripts/off.sh [--purge-intent-tier [--remove-services]] [--discard-audit-record]
                                       │
                owned, labelled Docker network  agentic-netops-mgmt  (MGMT_CIDR)
      ┌────────────────────────────────┴─────────────────────────────────┐
      ▼                                                                  ▼
┌───────────────────────── Kind cluster: agentic-netops ─────────────────────────────┐
│                                                                                    │
│ ns agentic-netops-agents — INTENT TIER — deny-all NetworkPolicy baseline           │
│ ┌────────────────────────────────────────────────────────────────────────────────┐ │
│ │ browser ─► ui :3000 ─NDJSON─► supervisor :9090  (graph + durable checkpointer) │ │
│ │                                     │  A2A over SLIM gateway :46357            │ │
│ │           ┌─────────────────────────┼─────────────────────────┐                │ │
│ │           ▼                         ▼                         ▼                │ │
│ │     mapper :9092             allocator :9091            deployer :9093         │ │
│ │     construct + vars         per-construct claim        ACL binding pre-flight │ │
│ │     + optional acl           profile (VLAN, VNI)        + translator sidecar   │ │
│ │           ▲                         ▲                         ▲     :8090      │ │
│ │           └────────────┬────────────┴─────────────────────────┘                │ │
│ │      read-only ConfigMap mounts, no ConfigMap RBAC:                            │ │
│ │           site-inventory   ·   fabric-qualification                            │ │
│ │                                                                                │ │
│ │     agent-otel-collector :4318 ──► clickhouse :8123  (agent analytics)         │ │
│ └──────────┬──────────────────┬────────────────────────────────────┬────────────┘ │
│   claims   │   OTLP fan-out   │                      apply Network │              │
│            ▼                  ▼                                    ▼              │
│ ┌────────────────┐  ┌──────────────────────┐  ┌──────────────────────────────┐    │
│ │ ns agentic-    │  │ ns monitoring        │  │ ns agentic-netops-intent     │    │
│ │  netops-alloc- │  │ otel-collector :4317 │  │ Network                      │    │
│ │  ation         │  │        │             │  │  fabric.agentic-netops.io    │    │
│ │ first-party    │  │        ▼             │  │   /v1alpha1                  │    │
│ │ IdentifierPool/│  │ Prometheus ─► Grafana│  │  vlans[]  bridgeDomains[]    │    │
│ │  Claim (AD-74) │  │        ▲  (flow panel│  │  routers[]  accessLists[]    │    │
│ │ (kuid: the     │  │        │   + topology│  │  attachments[]               │    │
│ │  lock's alt.)  │  │        │   assets)   │  └──────────────┬───────────────┘    │
│ │ (create/delete,│  │   gNMIc 0.47.0       │                 │ watch (cluster-    │
│ │  never update) │  │   sole device        │                 │ wide)              │
│ └───────▲────────┘  │   collector ──OTLP──►│                 ▼                    │
│         │ claims    └──────────▲───────────┘  ┌──────────────────────────────┐    │
│         │                      │              │ ns agentic-netops-system     │    │
│         └──────────────────────┼──────────────┤ Fabric (fabric.agentic-…)    │    │
│                                │              │ fabric-qualification (source)│    │
│                                │              │ agentic-netops-srl-provider  │    │
│                                │              │  controllers/fabric  prio 10 │    │
│                                │              │  controllers/network prio 20 │    │
│                                │              └──────────────┬───────────────┘    │
│                                │  Subscribe                  │ Config             │
│                                │              ┌──────────────▼───────────────┐    │
│                                │              │ ns sdc-system  (+cert-manager│    │
│                                │              │ ns as prerequisite)          │    │
│                                │              │ config-server v0.0.58        │    │
│                                │              │  Schema · TargetConnection/  │    │
│                                │              │  SyncProfile · DiscoveryRule │    │
│                                │              │  Target · Config · Running-  │    │
│                                │              │  Config · Deviation          │    │
│                                │              │ data-server v0.0.72          │    │
│                                │              └──────────────┬───────────────┘    │
└────────────────────────────────┼─────────────────────────────┼────────────────────┘
                                 │ gNMI/TLS 57400              │ gNMI/TLS 57400
     ╳ NetworkPolicy denies every intent-tier pod egress to the whole management CIDR
       on every port alike — the documented set is enumerated once in
       contracts/kubernetes-objects.md §Identity contract
                                 │                             │
┌────────────────────────────────▼─────────────────────────────▼────────────────────┐
│ containerlab · lab agentic-netops-fabric · network nodes and clients only         │
│                                                                                   │
│  spine01 ixr-d3l  ethernet-1/1→leaf01  ethernet-1/2→leaf02   IP transit + EVPN RR │
│  spine02 ixr-d3l  ethernet-1/1→leaf01  ethernet-1/2→leaf02   RR clients (AD-77),  │
│        ╲   ╲              ╱   ╱                              never a tenant VTEP  │
│         ╲   ╲            ╱   ╱   leaf uplinks  ethernet-1/49→spine01              │
│          ╲   ╲          ╱   ╱                  ethernet-1/50→spine02              │
│  leaf01 ixr-d2l          leaf02 ixr-d2l    VTEPs: system0.0 · vxlan0 ·            │
│     │ ethernet-1/1          │ ethernet-1/1        mac-vrf / ip-vrf · irb0.<vlan>  │
│  client01 eth1.<vlan>    client02 eth1.<vlan>   Linux endpoints, interface MTU    │
│                                                 9348                              │
└───────────────────────────────────────────────────────────────────────────────────┘
```

One namespace is not drawn: **`agentic-netops-services`**, which the provider's install creates for
`Network`s applied with cluster tooling. It sits beside `agentic-netops-intent` under the same
cluster-wide watch, no tier identity can write to it, and the tier's removal never touches it
(AD-26, AD-35). As decided, three placements differ from what the boxes suggest: the onboarding set
the layer consumes — `Schema`, `TargetConnectionProfile`, `TargetSyncProfile`, `DiscoveryRule`, the
layer's copy of `srl-credentials` — and therefore every `Target` live in `agentic-netops-system`,
because `config-server v0.0.58` applies only `Config`s in the Target's own namespace, while the
layer's own workloads and the schema mirror (`schema-mirror`, AD-75) stay in `sdc-system` (AD-82
`2026-09-21-target-namespace`); the allocation box is the authority the lock selects — on this lab
the first-party substitute, kuid being the alternative the lock can select and never coexisting
(AD-74, CD-03); and gNMIc and its OTel Collector → Prometheus exporter are also the source of every
applied-side (state) read of the provider's read-back — the pinned `data-server v0.0.72` serves no
state datastore — installed at `TargetsReady`, before `FabricReady` (AD-82
`2026-09-21-state-source`).

Seven properties of this picture are load-bearing:

1. **The tier's only write arrow into the fabric is `apply` into the intent namespace.** There is
   no arrow from any agent to the device-configuration layer, to gNMI, or to the management
   network. The `╳` is a NetworkPolicy, the management CIDR is the real containerlab subnet, and the
   denial covers **every port** — including the plaintext gNMI port the lab image exposes and never
   uses (FR-075, R-34).
2. **The southbound is drawn once, because there is one.** `provider → Config → SDC → gNMI 57400 →
   SR Linux`, with the device-configuration layer as the only component that writes device
   configuration. Everything except the network nodes and the Linux clients runs inside Kind, with
   no exception (FR-007, FR-014, FR-015).
3. **Telemetry has one emission point and one fan-out point.** gNMIc is the sole device collector
   and exports OTLP; agents emit once to the tier collector, which forwards to the fabric collector
   *and* writes the analytics store. Subscription-based ingestion in the device-configuration layer
   is disabled for the same series, and the two clients share one explicitly sized gRPC session
   limit on the device (FR-086, R-33).
4. **The construct vocabulary is introduced once, at the mapper, and folded on entry.** Every layer
   below consumes the canonical form; the retired names never survive past `Canonicalize`.
5. **Every arrow the tier draws across a namespace it does not own is narrowed to one resource** —
   claims in the allocation namespace (create and delete, never update), OTLP in the observability
   namespace, `Network` in the intent namespace.
6. **The site inventory and the qualification record reach the tier as read-only mounts, not as
   API access.** The gate writes `fabric-qualification` into `agentic-netops-system` as the source of
   truth; the tier phase of provisioning copies it and `site-inventory` into
   `agentic-netops-agents`, where they are mounted read-only. No ConfigMap permission is added to
   either tier identity.
7. **Both arrows into the supervisor — from the browser app and from a programmatic client — carry
   an authenticated operator, and the supervisor verifies it before the graph is entered.** The
   credential is a generated Secret mounted read-only; only the two probe routes are open; both
   surfaces are published on the loopback address only (FR-102, CD-01). The picture does not change:
   authentication is a property of an existing arrow, not a new component.

## Component inventory

| # | Component | Owns | Key requirements |
|---|---|---|---|
| C-01 | Compatibility manifest (`versions.lock.yaml`) | One machine-readable lock for the nine-part compatibility set — device image digest, YANG model tag and commit, deviation-patch commit, `Schema` CR definition, device-configuration release, allocation-authority release, containerlab, the collector, the mapping version — with part 6 recording **which** allocation authority is installed (`kuid`, or `first-party` with its decision record and the failed-gate evidence it answers; CD-03) — plus Kind and its node image, cert-manager, the observability stack, the dashboard plugin, the topology generator and the **first-party image block** (the provider's image and the six intent-tier images, each pinned by its `FROM` digests and dependency-lock hashes — [data-model.md](./data-model.md) §26); and `make verify-pins`, which resolves every registry digest against its registry and checks every first-party Dockerfile and dependency lock against the lock file; and the **host-tooling block** — the browser-automation package, its browser build and the walkthrough's capture tools, checked against the host before the suite that uses them ([data-model.md](./data-model.md) §28, AD-21) | NFR-003, FR-017, FR-104, CR-006 |
| C-02 | Containerlab fabric (`lab/`) | The six-node topology in native interface naming, the single lab profile, bootstrap configuration limited to management reachability, the gNMI TLS profile, `auto-save` persistence and an explicitly sized gRPC session limit, and the clean teardown path | FR-001, FR-002, FR-010, NFR-004 |
| C-03 | Kind cluster and management network | The sole application runtime, the declarative cluster config, the owned labelled Docker network with a configurable CIDR and an overlap preflight against every existing Docker network and the pod and service CIDRs | FR-006, FR-007, FR-008 |
| C-04 | In-cluster platform installation | Pinned manifests and charts in dependency order — cert-manager, the allocation authority, the device-configuration layer, the provider, the observability stack — plus `Schema`, connection and sync profiles, Secrets and the discovery rule that generates device targets — all in `agentic-netops-system` (AD-82 `2026-09-21-target-namespace`), the `Schema` loading the pinned commit from the in-cluster schema mirror in `sdc-system` (AD-75) — the device metric collector at `TargetsReady` (AD-82 `2026-09-21-state-source`), and the default `Fabric`. Fails rather than falling back to a hand-written stand-in when an upstream artefact cannot be fetched. Installs **exactly one** allocation authority, the one the lock file names, warns when it is the substitute, and stops with gate item G11 named rather than choosing another (CD-03) | FR-009, FR-019, FR-098, FR-104 |
| C-05 | SR Linux provider (`controllers/fabric`, `controllers/network`) | The two reconcilers of the one binary `agentic-netops-srl-provider`: `Fabric` → per-node fabric `Config` at priority 10 (interfaces, `system0`, underlay eBGP, EVPN overlay sessions, routing policy, `vxlan0`), `Network` → per-(service, node) `Config` at priority 20. Dependency waits — a `Network`'s wait on the `Fabric` being that it exists and is Accepted, never that it is Ready (data-model.md §19, AD-55) — compatibility-set validation, the canonical intermediate model, native path rendering, stable hashing, server-side apply, priority-collision refusal, status propagation from two-sided read-back, the applied side read through the device metric collector (AD-82 `2026-09-21-state-source`) — the `Fabric`'s applied side being its own interfaces, its sessions, the EVPN family's own `oper-state` on each and the allocated loopbacks active in the route table, beside a stated configuration-integrity read of `inter-as-vpn` and `route-reflector client` on the reflecting spines — from the running configuration through the device-configuration layer, neither leaf being mirrored into state on 25.7.1 (AD-76) — never an EVPN route count (AD-23, AD-31) — and finalization that **blocks on an unreachable target with every allocation held**, honours the annotated force-release, and records and later clears the durable `Fabric.status.findings[]` entry (CD-02); **scheduled re-verification** of every Ready object at the re-verification interval, with `status.lastVerifiedTime` and its metric (AD-02); the `Fabric`'s `maintenance[]` rendered as interface `admin-state` (AD-06); **the VNI claims of a `Network`** — adopted on correlation label, deterministic claim name and value together when the tier made them (AD-42), otherwise made for the stated value through `pkg/kuid` under a deterministic name, with `AllocationConflict` when the authority refuses, and released with the rest at finalization (AD-09); **the tier's VLAN claim adopted by the same three-part rule and released with them, adoption being resolved first at finalization for a value not yet recorded (AD-44) — never created — so the provider is the one release owner of a submitted service's claims** (AD-16); an allocation-authority **error** treated as a wait and never as an answer — no `AllocationConflict`, nothing read as "nothing adoptable", the finalizer kept and nothing released until the authority answers (AD-56); the drift policy read from a setting with no default and a closed value set of one, `revertive`, stated on every `Config` (AD-13, AD-17); a single-target outage never blocking status for healthy targets; **the validating admission webhook (`internal/webhook`), served by this same binary and registered `failurePolicy: Fail` on `CREATE` and `UPDATE` of `networks`, never on `DELETE`** — while the provider is down no `Network` create or update is admitted, so every cross-object admission rule always holds, and a removal still goes through and waits on the finalizer (AD-52); its handler evaluates the rules on a `CREATE` and on an `UPDATE` that changes `spec`, and admits unread an `UPDATE` that leaves `spec` unchanged — a finalizer, a label, an annotation, the force-release included — and any `UPDATE` of a deleting object, so finalization and the force-release are never refused by the platform's own webhook (AD-61); structured JSON logs (NFR-014) | FR-011, FR-012, FR-014, FR-015, FR-016, FR-017, FR-018, FR-100, FR-101, FR-103, FR-107, FR-109, NFR-002, NFR-014 |
| C-06 | *Retired by the SR Linux retarget (RD-04) — the SRv6 service controller is deferred with the SRv6 service; see [spec.md](./spec.md) §Deferred scope.* | — | — |
| C-07 | Construct vocabulary and the one translator (`pkg/migration`) | `Canonicalize`, the alias table, all-or-nothing validation, per-construct render, deterministic YAML emission, provenance annotations, and the CI assertion that `mac-vrf` and `ip-vrf` still match the device's own network-instance type names; no dependency on a proprietary controller, orchestrator or element driver anywhere in it or in what it emits, enforced by `make verify-boundaries` | FR-024 to FR-034, FR-044 to FR-049, FR-060, FR-099 |
| C-08 | Access-list render and verification (`internal/render/srl/acl`) | `/acl/acl-filter[name][type]` and its entries with `sequence-id := priority` unchanged, the reserved terminal entry for a declared default action, `/acl/interface[interface-id]` binding with `interface-ref{interface,subinterface}` always written, the derived device-safe filter names, the subinterface-keyed exclusivity refusal, the keyed two-sided read-back, and binding-before-filter withdrawal | FR-035 to FR-043, FR-100 |
| C-09 | Path register (`pkg/register`, `pkg/sdc`) | The **native-first** statement of every path the platform writes and every path it subscribes to: native `srl_nokia` by default, a recorded justification for each exception (none today), and for each subscribed path the derived metric name, labels and stream mode — CI-guarded so a new construct cannot pass uncovered | FR-017, FR-089 |
| C-10 | SLIM transport gateway | The authenticated message transport on `:46357`, TLS with client-certificate verification, gateway password from a generated Secret; workers discovered at call time from their published capability descriptors, and every worker call under a per-call timeout and a bounded retry that tells *unreachable* from *failed* | FR-070 to FR-073 |
| C-11 | Supervisor | Five HTTP routes, the orchestration graph, the bounded iteration and deadline, the durable checkpointer, the classifier and the injection mitigations, the liveness/readiness split, and **operator authentication in front of the graph** — Basic against the mounted `operator-credentials` Secret on the three pipeline-reaching routes, the authenticated username as the only principal, a strict request schema that refuses a caller-supplied `principal` (CD-01); the audit events it decides — confirmation, decline, refusal — emitted as span events on the request trace and **never** as Kubernetes Events, since it holds no cluster permission (AD-18); the model provider selected by configuration alone, and each unavailable dependency named as itself | FR-050 to FR-057, FR-074, FR-076, FR-077, FR-078, FR-102, NFR-008, NFR-010 |
| C-12 | Mapper | Interpretation against the published schema, the construct catalogue, the qualification-record check that refuses an unqualified construct or property by name, missing-field and unsupported-property terminal outcomes, and the **naming band**: a VLAN an operator names outside `100–999` is refused here, before any claim, with both bands stated, the VLAN a standalone `acl` names being a reference and exempt (AD-41, AD-47). The interpretation schema floors a VLAN at `0` and carries no upper bound, so a named VLAN below `100`, in `1000–4000` or anywhere above `4000` — `4095` and `5000` as much as `4050` — reaches this refusal and none fails schema validation with neither band stated (AD-56, AD-61); `service_id` is a DNS-1123 label of at most 15 characters (AD-56) | FR-058, FR-059, FR-061, FR-062, FR-034, FR-097 |
| C-13 | Allocator | Per-construct claim profiles against the allocation authority — VLAN and L2VNI/L3VNI only — the normalized service-intent contract, the derived identifiers shown exactly as they will be rendered, memoized re-assignment; every claim it creates — VLAN **and VNI** — named `<intent-namespace>.migr-<serviceId>.<role>`, the one scheme the provider adopts on (AD-42), a VLAN claim's role naming the `vlans[]` or `bridgeDomains[]` entry and nothing else. **No VLAN is ever claimed for an `ip-vrf`**: its attachment VLANs are named or absent (AD-51). Claims go through one adapter seam so the recorded substitute of CD-03 changes nothing above it; **no local lease or pool exists** — an unreachable authority is a bounded retry and then a named terminal failure. It releases a claim only while the claim is **provisional** — decline, rollback, never submitted; a submitted service's claims are the provider's (AD-16) | FR-056, FR-060, FR-062, FR-063, FR-104 |
| C-14 | Deployer and translator sidecar | The access-list binding pre-flight and the one-owner scan for a second owner of a (node, port, VLAN) — both VLANs in such a conflict being **named** ones, because the bands are disjoint and an allocated VLAN can never equal a named one (AD-33), and both scans covering the intent namespace only, with the cross-object webhook as the arbiter for a holder in `agentic-netops-services`; translate → stamp → server-side dry-run of every object (FR-066) → **apply with the provider's finalizer already set**, so a submitted object is never finalizer-less (AD-32) → label-selector rollback → convergence watch, status query and removal; the **provisional-claim determination** — the deployer, and only the deployer, decides which correlation identifiers the allocator may release, because it is the one tier identity that may read a `Network` (FR-075, AD-32); the **submitted-spec hash** taken from the dry-run result and stamped once, and the re-read on every status or removal request that reports an out-of-band modification or deletion from the live object, audits it, counts it and writes nothing (CD-04); removal deletes the `Network` and releases no claim, **and is watched until the object is gone under the convergence timeout — `COMPLETED` when it is, a turn ending at `PROVISIONING` and saying "in progress" with what is outstanding when it is not, never an accepted delete reported as a removal (AD-63)**; every `progress` chunk carrying `Ready`'s status string and reason (AD-62); the three audit events it decides — submission, removal, out-of-band — mirrored as Kubernetes Events beside the span event that is the record (AD-18) | FR-064 to FR-069, FR-043, FR-078, FR-105 |
| C-15 | Cluster identity — RBAC and NetworkPolicy | The two narrow ServiceAccounts, the two Roles with their verbs stated exactly (`get, list, watch, create, update, patch, delete` on `networks.fabric.agentic-netops.io` plus Event creation in the intent namespace; `get, list, watch, create, delete` on VLAN and GENID claims in the allocation namespace with no update or patch — AD-04), the deny-all baseline, the scoped egress policy that makes the whole management CIDR unreachable on every port, the generated `operator-credentials` Secret, and the `ValidatingAdmissionPolicy` that denies both tier identities the force-release annotation (CD-01, CD-02). Nothing here touches a control-plane schema, controller or reconciliation contract | FR-075, FR-079, FR-102, FR-103, NFR-007 |
| C-16 | Chat UI | Per-stage labelled rendering, both refusable confirmations, live convergence, the correlation-identifier chip, and the login form that holds credentials in memory only (CD-01) | FR-080 to FR-082, FR-102 |
| C-17 | Telemetry pipeline | gNMIc as the sole device collector with its OTLP output and its own scraped health endpoint — also, through the OTel Collector's Prometheus exporter, the source of every applied-side read of the provider's read-back, installed at `TargetsReady` (AD-82 `2026-09-21-state-source`); one agent emission fanned out by the tier collector to the fabric collector and the analytics store; the registered native metric set; the dashboards — behind the generated `grafana-admin` credential, with no anonymous or default-administrator access — and the generated topology assets; the analytics store as the **audit record** and the home of every model call's prompt, model identity and response (AD-18) | FR-086 to FR-096, FR-078, NFR-009 |
| C-18 | Lifecycle scripts | One up path and one down path for the whole platform, tier included, both idempotent, ownership-checked and free of any device-profile flag **and of any allocator-selecting flag**; the up path generates the operator credentials and the down path removes them with the other generated Secrets; the up path **merges** the model-provider Secret, refuses a declared gateway with no base URL, and prints the endpoint model calls will use (AD-01); the down path and the tier's removal **export the audit record before anything deletes its store**, unconditionally, stopping with the store intact on a failed export unless `--discard-audit-record` is given (AD-24); the export is newline-delimited JSON written through the evidence capture under a per-attempt identifier, bounded by `AUDIT_EXPORT_TIMEOUT_SECONDS`, with a stated failure set (AD-36); the tier's removal lists the services the tier submitted and **stops non-zero while any exist unless `--remove-services` is given**, and with it scales the tier's request-accepting workloads down first, takes the authoritative list **after** that scale-down, deletes what it lists, waits a bounded time for their finalizers, and stops naming the blocked `Network` and its target — never force-releasing (AD-26, AD-35); on every path past the refusal the scale-down precedes the export, a non-empty list after it without the flag falls back to the refusal, the operator usernames are captured before the credential goes, and a re-run skips a verified export or adds one, never rewriting (AD-46); the full teardown needs no such flag because it destroys the environment, and still exports the audit record first; **neither down path deletes anything under the lab's evidence root** — `--preserve-evidence` only adds the optional teardown-time capture (FR-010, AD-64); the host-resource preflight extended before the tier phase so the tier fits the single-host envelope without displacing the fabric | FR-010, FR-102, FR-104, FR-106, NFR-011, NFR-012 |
| C-19 | Documentation set | The construct reference stating what each renders in the device's own object names and how rules are ordered, the tutorial, the operator and operations guides, the runbooks — including the **force-release procedure** and what it can orphan (FR-103) and how to retrieve and rotate the operator credentials (FR-102) — and the guided prompts validated against the site inventory | FR-083, FR-084, FR-085, FR-102, FR-103, NFR-011 |
| C-20 | Fabric API (`api/fabric/v1alpha1`) | The first-party group `fabric.agentic-netops.io/v1alpha1` with structural OpenAPI schemas and no `x-kubernetes-preserve-unknown-fields` on `spec`: **`Fabric`** (node roles, underlay pools referencing allocation indices, the ASN plan, the fabric-wide overlay AS, the MTU policy, the route-reflecting spines, the site inventory of attachable ports, and the optional `maintenance[]` administrative-state list) and **`Network`** (the service intent object: `vlans[]`, `bridgeDomains[]`, `routers[]`, `accessLists[]`, `attachments[]`). No per-device intermediate Kind; no second fabric-intent API; nothing installed into an upstream group. Allocated identifiers — VNIs and the service VLAN — are immutable once the object is accepted, by CEL transition rules (AD-25). `Fabric.status.findings[]` is the durable record of a force-release. The optional `MigrationPlan` is generated under `config/crd/optional/`, outside the default kustomization; its controller is part of the provider binary, registers only when the CRD is served, and never creates or modifies a `Network` (AD-29). The kinds `IdentifierPool` and `IdentifierClaim` are **defined in this group and installed only under the recorded substitution of CD-03** | FR-012, FR-013, FR-098, FR-103, FR-104 |
| C-21 | Capability gate and qualification record | The G1–G13 gate run against the pinned image and emulated types, its run-captured evidence and its negative controls, and the per-construct, per-property qualification record published read-only for the intent tier. **G11** covers both claim forms the platform uses — a dynamic claim and a claim for a stated value, with a second claim for the same value refused **naming the holder** (AD-09) — and four properties the claim design rests on: which value a dynamic claim returns, that none is ever below the index's `minID` (AD-33), that a claim's `metadata.labels` are selectable through the authority's API — kuid's aggregated API, or the first-party substitute's served kinds that run on this lab (AD-32, AD-74), and that a claim reports its value in status. A failing **G11** stops provisioning with the item named; its captured failure is the evidence a substitution decision must cite. The gate is verification tooling under FR-108: its scratch configuration is its own, removed by it, with the removal read back before the default `Fabric` is applied. The three qualifications P0 names beside the gate — the transport's TLS key names, the OTLP resource shape, and that `ValidatingAdmissionPolicy` is served — are run and captured with it | FR-004, FR-097, FR-104, FR-108, FR-109, NFR-013, SC-040 |
| C-22 | Repository README and recorded walkthrough (`README.md`, `docs/images/`, `docs/media/`, `docs/DEMO_VIDEO.md`, `testautomation/video/`, `scripts/video-accelerate.sh`) | **The last thing built.** The root `README.md` as the SR Linux counterpart of the predecessor's, section for section; its four figures captured from the live lab; the predecessor's walkthrough — `vlan`, `ip-vrf` with its prefix, `mac-vrf` across both leaves, each proven with `kubectl` and inside the SR Linux leaf — re-recorded by the ported driver, accepted by the ported acceptance script from cluster JSON, cut to 6× by frame-dropping, with its machine evidence checked in. See [contracts/readme-and-walkthrough.md](./contracts/readme-and-walkthrough.md) | NFR-011, NFR-013, FR-083, FR-085, SC-031, SC-032, SC-033; CD-06 |

## Project structure

### Documentation (this feature)

```text
specs/004-agentic-netops-composite/
├── spec.md
├── plan.md                  # this file
├── research.md              # merged decisions D-01…D-37 + retarget decisions RD-01…RD-15
│                            # + clarification decisions CD-01…CD-06 + analysis decisions AD-01…AD-82 (AD-31…AD-43, AD-51…AD-53, AD-68 and AD-73 are operator decisions; AD-73 ratifies AD-44, AD-45, AD-63 and the choices inside AD-68 and AD-71)
├── data-model.md
├── quickstart.md
├── tasks.md                 # generated from this plan; T-ids stable, README.md is its last task
├── traceability.md          # composite id ↔ source id, both directions
├── platform-coupling.md     # the retargeting seam, coupling by coupling
├── evidence/                # the retarget research reports the decisions rest on
│   ├── 01-lab-platform.md   02-evpn-constructs.md   03-acl.md
│   ├── 04-srv6.md           05-kubenet-sdc-kuid.md  06-telemetry-visualization.md
│   └── README.md
├── contracts/
│   ├── crd-api.md  reconciliation.md
│   ├── a2a-transport.md  supervisor-http.md  kubernetes-objects.md  translator-api.md
│   ├── construct-vocabulary.md  network-spec.md  acl-render-contract.md
│   ├── kuid-claim-profiles.md
│   ├── readme-and-walkthrough.md   # the closing deliverable (C-22, P12)
│   ├── interpretation.schema.json
│   └── normalized-service-intent.schema.json
├── review/2026-09-20/       # the operator review: seven research reports + DECISION-SHEET.md (AD-31…AD-39)
└── checklists/              # reviewer-owned; an agent never ticks an item in either
    ├── requirements.md      # the whole specification
    └── clarify-delta.md     # the post-clarify delta (FR-102…FR-109, NFR-014, SC-042…SC-050, CR-008)
```

`checklists/clarify-delta.md` is the review vehicle for the delta identifiers — FR-102…FR-109,
NFR-014, SC-042…SC-050 and CR-008 — which `checklists/requirements.md` carries no item for, so that
no identifier is reviewed by neither checklist. Both are reviewer-owned and neither is ticked here.

[tasks.md](./tasks.md) was generated from this plan on 2026-09-20. Every checkbox in it is `[ ]`.

### Source code (repository root)

```text
api/
├── fabric/v1alpha1/             # Fabric, Network — fabric.agentic-netops.io
└── v1alpha1/                    # optional MigrationPlan — agentic-netops.io
cmd/
├── srl-provider/                # agentic-netops-srl-provider (the one controller binary)
├── migration-translator/
└── intent-translator/           # Go HTTP wrapper over pkg/migration, loopback sidecar
controllers/{fabric,network,migration}/
pkg/
├── migration/                   # THE translator: constructs.go, input.go, translate.go,
│                                # parse.go, acl.go
├── fabricapi/                   # typed read side: VLANs(), BridgeDomains(), Routers(),
│                                # AccessLists(), Attachments()
├── register/                    # native-first path register + its CI guard
├── sdc/                         # typed client for the device-configuration APIs
└── kuid/                        # the one claim-adapter seam over the allocation authority (C-13, CD-03)
internal/
├── model/                       # canonical intermediate model
├── render/srl/                  # native srl_nokia render; render/srl/acl
├── verify/                      # two-sided, keyed read-back (FR-100, FR-042), first and scheduled (FR-107)
├── webhook/                     # the cross-object admission rules of contracts/crd-api.md
├── topologyview/  status/  telemetry/
config/{crd,rbac,kind}/          # first-party CRDs and cluster assets; the provider's Deployment is deploy/agentic-netops/
lab/{topology.clab.yml,bootstrap/,clients/}
deploy/{cert-manager,kuid,sdc,rbac,agentic-netops,observability,agents}/
agents/                          # Python intent tier
├── config/  common/{llm.py,provisioning_states.py,exceptions.py,schemas/}
├── supervisors/provisioning/{main.py,suggested_prompts.json,prompts/,graph/}
├── provisioning/{mapper,allocator,deployer}/
└── tests/{unit,corpus/phrasings,corpus/adversarial,e2e}/
ui/                              # browser chat surface
docker/Dockerfile.*
examples/{fabric,constructs,migrations}/   # constructs/negative/ holds the one fixture built to be refused
tests/{unit,golden,envtest,gate,integration,e2e,lib}/   # lib/ holds leftovers.sh, the FR-108 leftover scan every verification tool starts with (T043)
scripts/{provision.sh,off.sh,video-accelerate.sh,lib/,ci/}   # ci/ holds the verify-* checks behind make
.github/{workflows/ci.yaml,pull_request_template.md,CODEOWNERS}
docs/                            # operator, operations and runbook set (C-19), plus:
├── reference/  operations/      # the construct reference, the qualification record; transport security
├── DEMO_VIDEO.md                # the take procedure and the frozen prompts (C-22)
├── decisions/                   # recorded operator decisions, e.g. allocator-substitution.md (CD-03)
├── images/                      # the README's four figures, captured from the live lab
└── media/                       # the walkthrough's machine evidence (JSON); the video itself is a
                                 # GitHub asset, not a repository file
testautomation/video/            # record.py (driver), accept.py, check_framing.py — ported from the
                                 # predecessor; takes and logs are git-ignored, the sources are tracked
versions.lock.yaml  Makefile  TUTORIAL.md
README.md                        # written LAST — P12's final task (C-22)
```

**Structure decision**: no new top-level structure is introduced by the consolidation, and the
retarget renames rather than adds. `api/fabric/v1alpha1/` holds the first-party fabric API group — fabric intent, service intent and
the conditional allocation kinds — and `api/v1alpha1/` holds the only other first-party group there
may be, the optional `MigrationPlan`'s (FR-013, AD-11);
`pkg/fabricapi/` is its typed read side and is the only consumer-facing view of it; every device
path is rendered under `internal/render/srl/` and nowhere else, which is how FR-014's "single
renderer" is enforced structurally rather than by convention. There is no `config/upstream/`: an
upstream project's artefacts are installed from that project's own pinned release under `deploy/`,
never re-authored here (FR-098). Run-captured gate and acceptance evidence is written by the run
that produces it under a run-scoped directory named with the cluster and lab identity (NFR-013); it
is never hand-edited and never checked in as a substitute for a run. The gate's **observed files** under `tests/gate/observed/` are not that evidence but build inputs derived from it — the serialization the goldens are frozen against, the series names the alert rules are built from, the management ports, what G13 saw — and they **are** tracked: committed after the gate run that wrote them, carrying no run-specific field, so the offline jobs that read them need no lab and a changed observation shows as a diff (T043, AD-64). The Python tier's own `config/`
package lives at `agents/config/` and never at the repository-root `config/`, which belongs to the
Go CRD and cluster assets.


**Make targets are an interface, and the quickstart names them.** [quickstart.md](./quickstart.md)
drives the platform through `make` targets that wrap the two lifecycle scripts and the test suites
without reimplementing their phases. The ones that carry a requirement of their own:

| Target | Carries |
|---|---|
| `verify-pins` | NFR-003 — every registry pin resolved against its registry; placeholder, floating and branch references fail; every first-party Dockerfile `FROM` and dependency lock checked against the lock file, and a first-party image referenced by a mutable tag fails |
| `verify-upstream-artefacts` | FR-098 — every CRD and API service in an upstream group comes from that project's pinned artefact |
| `verify-render-schema` | FR-015, FR-020 — every golden device render validates offline against the pinned device schema — through a prefix-normalised copy when the pinned `sdc-lite v0.4.0` refuses the observed prefixed identityref form inside a `must`, the golden untouched, the defect named and a wrong-identity golden still failing (AD-81) |
| `verify-compat` | FR-017, FR-104 — the nine-part compatibility set published by the provider matches the lock file, and **exactly one** allocation authority — the one the lock file names — is installed; every running first-party workload carries the current tree's content-hash tag and the image ID this run's build recorded (NFR-003) |
| `verify-boundaries`, `verify-provenance-headers` | SC-017, FR-049 — the three deny-list boundaries and the vendored-artefact provenance headers; FR-108 — no device client invoked outside the gate, the test suites and the walkthrough tooling; **FR-013 — no second workflow, pipeline or job engine: no `CronJob` and no engine kind, chart or image in any manifest or in the lock file, and the provider's ServiceAccount the only identity with a mutating verb on `config.sdcio.dev` resources (T025, with planted fixtures; its runtime half is T152's inventory)**; **FR-019, CR-008 — no credential literal in any manifest under `deploy/`**, which is the check that makes that rule enforced rather than asserted, with its own planted fixture: a `stringData` password in a manifest under a fixture `deploy/` tree fails it naming the file (T025, AD-67) |
| `verify-evidence` | NFR-013, SC-040 — run-captured evidence with a negative control for every readiness check |
| `verify-readme` | C-22 — the README's section order matches the contract; every relative link and image resolves; every version it states equals the lock file; the MTU, pinning and IPv6-gateway facts are present; no retired service name and no predecessor platform term appears; the walkthrough evidence file exists with `accept_pass: true` |
| `test-envtest`, `test-agents`, `test-ui` | FR-020 — the API and controller suites against a test control plane, the intent tier's unit tests and the chat surface's unit tests; with `test-static` they are every suite that needs no lab, and all four run on every pull request (AD-28) |
| `verify-metrics`, `verify-topology-view`, `verify-evpn-service-view`, `test-alerts` | SC-034 to SC-037 — the observability checks [quickstart.md](./quickstart.md) §21 names |
| `test-static`, `test-idempotence`, `test-managed-drift`, `test-unmanaged-path`, `test-target-failure`, `test-service-delete`, `test-delete-unreachable`, `test-reverify`, `test-provider-claims`, `test-acceptance` | FR-020 and the success criteria each is named for in the verification strategy below. `test-static` runs the Go unit and golden tests, the path-register guard **and every offline shell suite under `tests/unit/`** — SC-048's among them — with a reach assertion, so no suite a task writes is run by nothing (AD-50). None of them needs a lab; one needs a container runtime and one pull of the pinned Prometheus image — T130's `promtool` rule test, which reads its series names from the committed `tests/gate/observed/telemetry-series.json` and reports "not run", never a pass, until the gate has written it (AD-59, AD-64). It also carries **FR-099** — `pkg/migration/device_names_test.go` (T096) asserts that `mac-vrf` and `ip-vrf` equal the network-instance type identities in the pinned `srl_nokia` model, which is what "asserted in CI against the pinned device model" names |

## Delivery phases

**One ordering, not three concatenated.** The binding constraint inherited from the intent-tier
plan survives intact: **the safety boundary is built and proven before any agent is deployed.**
That ordering is the only one in which the structural half of the safety story cannot be
retrofitted, and it is why the safety phase precedes every agent phase even though the agents are
useless without the fabric beneath them. Phase numbers are stable; P4 is retired in place.

**Numbers are identities, not a schedule.** The phases are *executed* in the order the quickstart
and [tasks.md](./tasks.md) use: **P0 → P2 → P3 → P1 → P6 → P7 → P5 → P8 → P9 → P10 → P11 → P12**,
with P5's offline half available as soon as the translator core exists. P1 runs as the first step of
the tier phase, after the control plane, because its admission probe needs the `Network` CRD, its
NetworkPolicy probe needs the real management CIDR, and a control plane that is complete with no
tier present is NFR-006. The invariant is untouched and is enforced mechanically: the provisioning
script creates no tier workload until every denial has been observed (AD-08). **P12 is
last by instruction and by principle**: the README and its recording describe a platform that has
passed P11, not one that is expected to.

### P0 — Pin and qualify

Freeze the whole compatibility manifest, including the intent-tier block, by digest, and prove it is
real: **`make verify-pins` resolves every digest against its registry**, rejects a placeholder or
synthetic digest, and rejects a branch, `latest` or floating-minor reference anywhere one can appear
— including the `Schema` CR's repository refs (which name the in-cluster schema mirror by a tag named after the locked commit, never a branch — AD-75), the Grafana plugin install and the topology-generator
image (NFR-003). Provision the pinned Kind cluster and launch device nodes.

Then run the **capability gate** against the pinned image and the emulated types, before any design
depends on it (FR-004, RD-12). "Before any design depends on it" is about the default `Fabric` and
every service, not about the installs three items need: **G10** validates against the
device-configuration layer's schema, **G11** claims against the allocation authority, and **G13**
applies a gate-owned scratch `Config` through that layer to a Ready target (FR-108's named
exception to FR-013), so the
provisioning script installs the in-cluster stack and onboards the targets first and runs the gate
after `TargetsReady` and before `FabricReady` — G11 alone being evaluated earlier, as soon as the
authority is installed (below). Nothing the gate needs is rendered by the provider — G13's scratch
`Config` is the gate's own, labelled, at a priority no platform `Config` uses:

| Item | What it qualifies |
|---|---|
| **G1** | gNMI Capabilities: the `srl_nokia-*` model set at the pinned release, JSON_IETF encoding |
| **G2** | Version and platform identity: `25.7.1`, `7220 IXR-D2L` and `7220 IXR-D3L`; **plus the observed management listening ports**, against which the FR-075 denial probe set is reconciled |
| **G3** | Platform feature set the constructs depend on: vxlan, evpn, anycast-gw, acl features present |
| **G4** | gNMI Set, read-back, and durable persistence through `auto-save` — including the **config-only** leaves (`inter-as-vpn`, `route-reflector client`) read back through `--type config` on every reflecting spine, because the `Fabric`'s configuration-integrity check reads them from the configuration datastore (AD-31, as decided in AD-76); whether `--type state` mirrors them is **recorded** (`config_only_leaves_mirrored_in_state`, observed `false` on 25.7.1), never a pass criterion (AD-76) |
| **G5** | Transactional rollback of a rejected change; the failure is confined to its own transaction |
| **G6** | The MTU envelope of RD-10 — 9412 / 9398 / 9348, and the 9320 (IPv4) and 9300 (IPv6) payload boundary. As decided (AD-78), the commit-time refusal one byte above is asserted for the **port MTU** (9413 refused) and the routed `ip-mtu` (9399 refused) only; the device accepts an IRB `ip-mtu` of 9349, which is **recorded** (`tenant_ip_mtu_9349_commit`), and the tenant boundary is the data-plane probe (9320 / 9300 pass, 9321 / 9301 fail). No number changes |
| **G7** | Subscribe in `sample` mode, and an on-change probe — and, with the collector shape qualified alongside, the generated metric names the `EvpnRoutesLost` guard depends on, recorded to `tests/gate/observed/telemetry-series.json` for T130 to read (AD-31, AD-48). The device-metric pipeline's rules and dashboards are P9's; its gNMIc and collector are installed at `TargetsReady` as the read-back's state source (AD-82 `2026-09-21-state-source`), but the gate does not rest on them, so the names are observed as the OTLP shape is: a throwaway Pod pair of the **pinned** gNMIc and collector images in a scratch namespace, under the lab operator's device credentials (FR-108), while G8's scratch EVPN instances exist; the file records the naming-relevant settings beside the names, P9's manifests ship exactly those settings, `ObservabilityReady` re-checks the live names against the file before the alert rules load, and the pair is removed with the removal read back (AD-55) |
| **G8** | EVPN behaviour: Type 2, 3 and 5 actually exchanged through the route-reflecting spines **including the reflection negative control** — sessions up with zero EVPN routes is the failure signature; as decided (AD-77), removing `inter-as-vpn` was observed **not** to stop reflection on 25.7.1 (`interASVPNRemovedReflectionContinues: true`) and removing `route-reflector client` — `Fabric.spec.overlay.reflectorClients: false` — was observed to stop it (`reflectorClientsFalseStopsReflection: true`, `tests/gate/observed/reflection-control.json`), which admits it as SC-004's control — and **IPv6 anycast gateway with an IPv6 Type-5 route observed end to end**, for which no published example exists. It also observes what the `Fabric`'s own read-back rests on (AD-31): that the per-neighbour EVPN family `oper-state` is populated on this emulated node type, that the per-neighbour EVPN received-route counters read zero before any service and non-zero after the first spanning one, and that every node's allocated `system0.0` loopback is present and active in every other node's route table |
| **G9** | Access-list programming, keyed applied-side read-back in each direction, whether **egress binding qualifies on this profile**, and whether a binding entry carrying an `interface-ref` and **no filter** is accepted (`AD-68`, Open item 19). As decided (AD-79, AD-82 `2026-09-21-acl-binding-state`), 25.7.1 mirrors no part of `/acl/interface` into state: A1–A3 are the keyed binding in **running**, each entry's TCAM on the bound direction only and programming complete, and **A4 is the binding shown applied by traffic** — traffic entering on exactly the bound subinterface raises the filter's own entry-10 `matched-packets` (keyed by filter name, type and sequence-id) above a baseline read before it (`chk_acl_matched`, negative control `G9-acl-matched`); the keyed binding in state and the per-subinterface entry list are recorded, never judged. `acl.egress` is published **unqualified** — the pinned data-server refuses the egress binding's `must` though the render satisfies it, G9 having passed egress device-direct only — so an egress list is refused by name at interpretation (FR-097) |
| **G10** | That the deviated schema still **rejects** the invalid configurations the platform relies on being rejected — re-run on the schema carrying the first-party deviation module (AD-82 `2026-09-21-feature-guarded-must`), its liveness case being `port mtu 10000`, since the data-server's dry-run does not check union-typed vlan-id or enums |
| **G11** | An allocation **claim round-trip**, in both forms the platform uses, plus **the six observations (a)–(f)** the claim design rests on and cannot read from a dormant project with confidence — enumerated once, in `contracts/kuid-claim-profiles.md` §6, which is the one list and the one count (AD-56): a dynamic claim reports its allocated value in status (`status.id`) and **which value it is** — whether the authority allocates the lowest free value or an arbitrary one is unknown from source, and it decides nothing here but is recorded rather than guessed; a dynamic claim is **never handed a value below the index's `minID`**, which is what keeps the allocation band out of the naming band (AD-33); a claim for a **stated value** binds that value and a second claim for it is refused **naming the holder**, which is where `AllocationConflict` gets its holder from (FR-109); a claim's **`metadata.labels` are selectable** through the authority's API (kuid's aggregated API, or the first-party substitute's kinds), which every claim-selector diff in this design depends on (SC-026, SC-045, SC-046); a claim **deleted frees its value synchronously** — a stated-value claim is deleted and an immediate second claim for the same value binds — which is what the finalizer's release step rests on (`contracts/reconciliation.md` Rule 8 step 6, AD-47); and the authority's API is healthy on the pinned Kind. As decided (AD-74), G11 failed on `kuid-server v0.0.13` and passed on the first-party substitute (2026-09-21), which is what runs on this lab |
| **G12** | The exact **identityref JSON serialization** the device returns from a real Get, the `afi-safi-name` key of the BGP family paths among them — **golden files are not frozen before this** (AD-31). Observed: module-prefixed (RFC 7951) identityrefs, the form the goldens freeze, as decided (AD-81) |
| **G13** | What a managed-path deviation leaves **observable** under the revertive policy the platform runs: drift injected on a path a gate-owned scratch `Config` owns, then whether a `Deviation` with reason `NOT_APPLIED` is visible long enough to be asserted, or whether the layer reapplies first and the only durable witness is the restored value read back from the device. **The drift check of SC-007 asserts what this item observed, and nothing it did not** (AD-34) |

Qualify alongside the gate: the **TLS key names the pinned transport gateway accepts** for a
cert-bearing server, and the **OTLP resource and attribute shape** the tier's instrumentation emits,
so the collector schema and the metric naming are built against reality rather than against a guess.
The provider's watch scope is **not** a qualification item — it is first-party configuration (R-15).

Every gate item is captured by the run that claims it, with its command, UTC time, exit status,
image digest and cluster and lab identity, and every readiness check carries a **negative control**
showing it fails on a stock fabric before its pass is admitted (NFR-013, SC-040). The per-construct,
per-property result is published as the read-only qualification record the intent tier consults
(FR-097, C-21).

**G11 needs only the cluster and the allocation authority, so it is evaluated as soon as the
authority is installed — before the device-configuration layer and the provider — and its captured
result is carried into the gate record. If G11 fails, provisioning stops there, non-zero, naming
G11, and installs nothing above it** (FR-104, CD-03). The script offers no flag that selects another allocator. The one way forward is an
operator decision recorded in `docs/decisions/allocator-substitution.md`, citing the run-captured
G11 failure by path and SHA-256, and a lock-file change to `allocationAuthority.kind: first-party`;
only then is the substitute built, in the first-party API group, and the upstream authority is not
installed at all. `make verify-pins` refuses the `first-party` selection without both references.
On this lab that way forward has been taken: G11 failed on `kuid-server v0.0.13` and the first-party
substitute was adopted and passed G11 (AD-74), so it is the authority that runs; kuid remains the
alternative the lock can select, never coexisting with it.

Also qualified here: that `ValidatingAdmissionPolicy` is served at the pinned Kubernetes minor,
since P1's force-release denial depends on it (research §Open items, 12). The transport TLS key
names and the OTLP shape are research §Open items 13 and 14; all three are captured with the gate's
evidence, in this phase, not deferred to the phase that consumes them.

This phase may change how a decision is implemented; **it may not weaken a requirement**. A failing
item is fixed or the affected construct or property is recorded unqualified and refused by name —
never relaxed to let a check pass (CR-007).

### P1 — Safety boundary, before any agent exists

Create the tier namespaces, the two ServiceAccounts, both Roles, both RoleBindings and every
NetworkPolicy. Run the denial probes against bare pods holding each identity and observe every
denial: every forbidden verb on both identities, and a dial from a tier pod to a device management
address on **every port the image is documented to expose** — the set stated once in
[contracts/kubernetes-objects.md](./contracts/kubernetes-objects.md) §Identity contract, TCP and the
one UDP port alike, including the plaintext gNMI port and the vendor automation ports the platform
never uses. The UDP row is recorded, not asserted, by the dial: SC-028's per-source counter is what
asserts it. The set is reconciled here against G2's observed listening ports, and a listening port it
does not carry fails this step. Run the secret generator so no credential is ever a literal in a
manifest — **including the operator credentials** (`operator-credentials`: a username and an
always-generated password; FR-102, CD-01) — a rule `make verify-boundaries` enforces over every
manifest under `deploy/` on every pull request (T025).

Install the `ValidatingAdmissionPolicy` that denies either tier identity any request setting or
changing the force-release annotation (FR-103, CD-02). Its **probe** runs here, in this phase's
boundary step, beside the RBAC and NetworkPolicy denials: a bare pod holding the deployer identity
attempts the annotation on a scratch `Network` and is refused while a cluster admin is not. That is
possible because this phase is *executed* after P3 (AD-08), so the `Network` CRD and both identities
exist when it runs; it is re-run with every other denial at P11.

The same step installs SC-028's **per-source packet counter** inside the cluster nodes and records
its positive control: the probe's own dial from a tier-labelled pod must move it, or the counter is
not admitted as evidence for the adversarial run at P11 (AD-19, research §Open items, 16).

At the end of this phase the guardrail exists and is proven, and **no agent has been deployed.**

### P2 — Fabric foundation

Through the provisioning script: launch the **six-node** topology — `spine01`, `spine02`, `leaf01`,
`leaf02`, `client01`, `client02` — on the owned management network, with the overlap preflight
passing before anything is created.

Install the in-cluster stack in dependency order: **cert-manager → the allocation authority the lock
selects (on this lab the first-party substitute, AD-74; KUID the alternative) → SDC → the provider**, each
from its own pinned artefact, failing rather than falling back to a stand-in (FR-098). Onboard the
device targets: `Schema`, the target connection and sync profiles, the credentials Secret, the
`DiscoveryRule` that generates the four `Target` objects, and all four reaching Ready — the
onboarding set and the `Target`s in `agentic-netops-system` (AD-82 `2026-09-21-target-namespace`),
the `Schema` loading the pinned commit from the in-cluster schema mirror in `sdc-system` (AD-75).
At `TargetsReady` the device metric collector (gNMIc → OTel Collector → Prometheus exporter) is
installed, since it is the read-back's state source (AD-82 `2026-09-21-state-source`).

Apply the default **`Fabric`**. The `Fabric` reconciler claims the underlay addressing and ASNs from
the allocation authority and renders one priority-10 `Config` per node: interfaces and their MTUs,
`system0.0` as VTEP source and router-id, dual-stack per-link eBGP underlay, the iBGP EVPN overlay
to both route-reflecting spines with `inter-as-vpn` set and `route-reflector client` rendered from
`Fabric.spec.overlay.reflectorClients` (AD-77), the underlay routing policy, and `vxlan0`; the port
MTU is rendered on every access port too (AD-82 `2026-09-21-access-port-mtu`).

Gate: the underlay and overlay sessions establish, the EVPN family is negotiated on each overlay
session — read from the family's own `oper-state` per neighbour, not inferred from `session-state` —
every other node's allocated `system0.0` loopback is present and active in each node's route table,
**and `inter-as-vpn` and `route-reflector client` read back from both reflecting spines equal to what
the `Fabric` declares** (`true` on the default `Fabric`).
Those last two are **configuration** leaves, read — as decided — from the running configuration,
SR Linux 25.7.1 not mirroring them into state (AD-76), so the read is a
configuration-integrity check and is recorded as one; what shows on this image that the setting is
what lets routes through is G8 on scratch configuration, and then T051's post-render probe on the
rendered fabric — reported under FR-108, never an input to readiness (AD-31).
No EVPN route is counted here: the default `Fabric` carries no service, the gate's scratch
instances are gone, and zero routes is the correct state. The route half of SC-004 is P3's — the
first service spanning both leaves either shows its routes or reports `Ready=False/RoutesMissing`
(R-37, R-46, AD-23, AD-31).

### P3 — Provider, constructs and service rendering

Complete deterministic rendering and lifecycle semantics for all four constructs, natively
(`srl_nokia` paths only, RD-08):

- **`vlan`** — a `mac-vrf` network-instance with **no** vxlan-interface, **no** bgp-evpn and **no**
  bgp-vpn, plus its bridged subinterfaces; its own list in the object so "local" is never encoded as
  "the overlay fields are missing";
- **`mac-vrf`** — bridged subinterfaces `ethernet-1/N.<vlan>`, the L2VNI vxlan-interface of type
  `bridged`, `bgp-evpn bgp-instance 1`, and `bgp-vpn` route targets rendered **explicitly** from the
  fabric-wide overlay AS and the VNI, never left for the device to derive per leaf;
- **`ip-vrf`** — routed subinterfaces, the L3VNI vxlan-interface of type `routed`, the interface-less
  Type-5 model, and the declared prefixes;
- **anycast gateway** — `irb0.<vlan>` with `anycast-gw` addresses and the fabric-constant
  virtual-router-id, attached to **both** the bridged and the routed instance, with an explicit
  `ip-mtu`, in the declared address families only, and no `primary` leaf rendered — the device makes
  the only IPv4 address primary (AD-82 `2026-09-24-irb-primary`);
- **`acl`** — the filter, its entries with `sequence-id := priority` unchanged, the reserved terminal
  entry when a default action is declared, and the subinterface binding with `interface-ref` always
  written.

Implement the **keyed two-sided read-back** for every construct (FR-100) and for access lists
(FR-042): written side from the `Config` and the running datastore, applied side from the device's
state — read, as decided, through the device metric collector, the pinned data-server serving no
state datastore (AD-82 `2026-09-21-state-source`) — keyed to this service's own objects — instance, subinterface, tunnel and EVPN
instance oper-state, remote VTEPs and EVPN routes once the service spans more than one leaf, gateway
state where declared, and for a filter its keyed binding in running (25.7.1 mirrors no part of
`/acl/interface` into state — AD-82 `2026-09-21-acl-binding-state`) and its per-entry programmed state and counters.
A fabric-wide count is never admissible.

**Scheduled re-verification** (FR-107, AD-02) lands with the read-back it repeats: both reconcilers
requeue every Ready object at the re-verification interval, advance `status.lastVerifiedTime` on every
pass that ran — a miss included, because that pass completed its read-back (AD-54) — and set
`Ready=False` naming the invariant on a miss — writing no `Config` when nothing
differs. A pass that cannot run — target unreachable, read timed out, the collector holding no sample
for a node or not answering (AD-82 `2026-09-21-state-source`), or a Ready-at-current-generation
`Network`'s `Config` no longer confirmed by the layer with nothing written this reconcile (AD-82
`2026-09-24-layer-before-target`) — sets
`Ready=Unknown/VerificationFailed` and `Degraded=True/VerificationFailed` naming the target and
advances nothing; it never sets `Ready=False` and never leaves `Ready=True` standing (AD-40); a
`Network` held at `Ready=Unknown` retries at the reconciliation interval (AD-82
`2026-09-24-unknown-retry`). The
interval has a 30 s floor, and a value below it or one that cannot be parsed refuses the
provider's start ([data-model.md](./data-model.md) §25).

**The VNI claims of a `Network`** (FR-109, AD-09) land with the dependency gate they feed: before
anything is rendered the reconciler resolves every `l2vni` and `l3vni` to a bound claim — adopting
the one that carries the object's correlation label, bears the deterministic claim name derived from
the object and reports that value — the three things together, for a VNI claim as for a VLAN claim
(AD-42) — which is the tier's, or
else claiming exactly that value through `pkg/kuid` under a name derived from the object's namespace,
name and the field's role, labelled with the object. The authority arbitrates: a value held by
another owner, or outside the allocation band, is `Accepted=False/AllocationConflict` naming the
value and the holder or the band, nothing is rendered and no other value is tried. No webhook
duplicates that arbitration. The VLAN half is decided **by band** (AD-33), because a `Network`
cannot say whether its VLAN was named or allocated: one in the naming band `100–999` is claimed on
neither path and the one-owner rule covers it; one in the allocation band `1000–4000` must be backed
by an adoptable claim, which the provider **adopts** — never creates — so that it, and not the tier,
releases it (AD-16, AD-32), and one that no claim backs is `AllocationConflict` naming the VLAN and
both bands. The provider's identity holds `get, list, watch, delete` on VLAN claims for exactly that
and no `create`.
Finalization releases adopted and created claims alike, after the read-back, as it already did.

The provider reads its **drift policy** from `DRIFT_POLICY`, which has no default: it refuses to
start without one, states it on every `Config` as `spec.revertive: true` — never leaving the field
absent for the layer's own global default to supply — and lab provisioning sets `revertive`
(FR-015, AD-13). The value set is closed at that one exact string — unset, empty and anything else
refuse the start alike (AD-17), and what a production deployment selects is the same value,
selected by it (AD-34). It logs one JSON object per line (NFR-014).

Add the path-register entries so the CI guard covers the new constructs instead of silently passing.
Prove control plane, idempotence, failure status, drift under the revertive drift policy, and
deletion order — binding before filter before the subinterface owner.

**Deletion while a target is unreachable** (FR-103, CD-02) lands here with the finalizer it belongs
to: the object is `Ready=False/Deleting` from the moment finalization starts — in every deletion,
never `Ready=Unknown` and never a `Ready=True` left standing (operator decision, AD-53) —
configuration is removed from reachable targets, `Deleting=True/TargetUnreachable` names the
rest — a node whose `Target` is Ready but which the collector-based data-path probe
(`ReachabilityMaxAge` 30 s) finds unreachable counting as unreachable (AD-82
`2026-09-24-delete-unreachable`) — every claim stays bound, no timer exists on the path, and removal completes unaided when the
target returns and the removal has been read back. The force-release annotation, its `Warning`
Event, the `Fabric.status.findings[]` entry that outlives the service, the scheduled read-back that
clears it, and the `OwnershipConflict` refusal of a colliding render while it is open are built and
envtest-covered in the same phase. `make test-delete-unreachable` also **observes** — it does not
assume — what the device-configuration layer does with a `Config` deleted during the outage.

Gate: the first `mac-vrf` spanning both leaves shows its Type 2 and Type 3 routes received through
the spines and an `ip-vrf` its Type 5 — the route half of SC-004, keyed to those services — with a
negative control that is a **declarative fault** (AD-43, its field as decided in AD-77): `Fabric.spec.overlay.reflectorClients` is set `false`, the
fabric reconciler renders `route-reflector client` false on both reflecting spines, the service reports `RoutesMissing`
within one re-verification interval plus one reconciliation interval while the `Fabric` reports
`Ready=False/NotConverged` naming the spines and the setting, and the field is set back to `true` and the
restoration read back before the positive assertion is admitted — intent, so nothing reverts it and
no device session is opened for it; allocated
identifiers are immutable on an accepted object (AD-25); every construct has render assertions; every golden render passes **SDC schema validation** — goldens freezing the observed module-prefixed RFC 7951 identityref form, `sdc-lite v0.4.0` validating a prefix-normalised copy with the defect named and a wrong-identity negative control, the layer's own validation seeing the true form (AD-81);
the register guard passes; a priority collision between two `Config` objects that could touch the
same leaf is refused at validation; a service deleted with a leaf unreachable holds every allocation
across at least ten reconciliation intervals and finishes with no operator action when the leaf
returns (SC-043); a force-release with an empty reason is refused and one with a reason is honoured
— its denial to the tier's identities is P1's probe, because those identities do not exist yet when
this phase is executed (AD-08); a `Network` applied with no tier present has every VNI bound before
its first `Config` exists, and a second one naming a held VNI is refused naming the holder (SC-045);
and **golden files are frozen only after gate item G12** has shown what the device actually returns.

### P4 — *Retired*

*Retired by the SR Linux retarget (RD-04) — the SRv6 service phase is deferred with the SRv6
service; see [spec.md](./spec.md) §Deferred scope. The phase number is not reused.*

### P5 — Migration compatibility

The alias fold on entry, all-or-nothing rejection of unmapped source properties, the provenance
annotations in the deterministic emission order with one owner per key (FR-101), and the
source-scoped constraints. The legacy-versus-construct equivalence test compares the emitted `spec:`
blocks between the two vocabularies directly, so an accidental change fails even when both golden
files move together.

### P6 — Transport, workers and the supervisor

The transport gateway with TLS, using the key names P0 qualified; the three worker servers with
their capability descriptors and registration; the supervisor with its five routes, its graph and
its durable checkpointer. Liveness on the trivial route, readiness on the deep one. The classifier
and the injection mitigations land here — the behavioural half of the safety story ships with the
first agent that reads operator text, never later. **So does operator authentication** (FR-102,
CD-01): the supervisor is never deployed in a form that accepts an anonymous prompt. The handler
verifies the Basic credential against the mounted Secret and returns `401` before a thread
identifier is minted; the request schema is strict and refuses a caller-supplied `principal`; the
authenticated username is the principal on every audit event and both `Decision` records.

**The analytics store and the tier collector land here too** (AD-45), ahead of every agent workload
in the tier phase: the store is the audit record (FR-078, AD-18), P7's audit reconciliation reads it
and the tier's removal exports it, so it is deployed with the first workload that can write to it
rather than with the dashboards of P9. The collector has one exporter at this point — the store;
P9 adds the forward to the fabric collector.

Demonstrable: the tier brings up — the analytics store and its collector Ready before any agent —
each agent's health is individually legible, a stopped worker is named rather than fatal, and an
unauthenticated request to each pipeline-reaching route is refused with zero threads, zero model
calls and zero claims.

### P7 — Submission and convergence

The translator sidecar; the deployer's tools; the per-construct claim profiles — VLAN and VNI only —
and their release on decline; the qualification record consulted at interpretation so an unqualified
construct or property is refused by name before anything is claimed (FR-097); the access-list
binding pre-flight keyed on (node, interface, subinterface, direction, address family); dry-run then
apply with label-selector rollback; the convergence watch; correlation-identifier stamping. The
golden-file equivalence check between agent-produced and hand-authored intent runs here.

**The cluster is the record** (FR-105, CD-04): the deployer computes the submitted-spec hash from
the server-side dry-run result and applies the dry-run object plus exactly that one annotation; on
every status or removal request it re-reads the object and, on a mismatch or an absence it did not
cause, says the service was modified or deleted outside the tier, reports the live state, emits an
`out_of_band` audit event, increments `agentic_netops_agent_out_of_band_changes_total`, and writes nothing. A
removal of a modified service is never executed by the turn that detects the modification. A removal
deletes the `Network` and **releases no claim**: the claims of a submitted service — VLAN and VNI —
were adopted by the provider, whose finalizer releases them after the read-back (AD-16). **The
removal is watched until the object is gone**, under the convergence timeout of a creation: gone
within it, the request ends `COMPLETED`; still present at it, the turn ends at `PROVISIONING`
saying the removal is in progress and naming what the object's `Deleting` condition says is
outstanding — never a success, never a failure, no status minted, nothing force-released — and a
later status request reads the live object. An accepted delete is never reported as a removal
(FR-069, AD-63). A creation watch that sees `Ready=False/Deleting` ends as a failure naming the
deletion and, no tier removal being recorded, as deleted outside the tier (FR-067, FR-105). Every
`progress` chunk carries `Ready`'s status string and reason as the cluster reports them, emitted
by the deployer and streamed unaltered by the supervisor (AD-62). Audit
events are span events on the request trace, stored in the analytics store — deployed at P6, so it
exists before the first of them (AD-45) — which is the record;
the deployer mirrors the three it decides as Kubernetes Events (AD-18).

**The two VLAN bands are disjoint** (AD-33), so an allocated VLAN can never equal a VLAN another
service named and the collision AD-27 refused cannot arise. An operator names only from `100–999` —
the **mapper** refuses a named VLAN outside it at interpretation, before anything is claimed,
stating both bands (AD-41) — and the authority allocates only from `1000–4000`, and only for a
`vlan` or a `mac-vrf` whose operator named none: an `ip-vrf` attachment's VLAN is named or absent
and never allocated (AD-51). The translator
sidecar keeps only the structural `100–4000` check: it runs after the allocator, on an input in
which a named VLAN and an allocated one are the same integer, and no provenance field is added to
tell them apart. The VLAN a standalone `acl` names is a reference to another service's
subinterface and is held to neither band (AD-47). What the pre-flight still refuses is the genuine
case: two services asking for the same (node, port, VLAN), both of them named, with the incumbent
service given by name and the provisional claims released; the cross-object webhook refuses the same
case at the dry-run and is the arbiter, because the pre-flight sees the intent namespace only
(FR-062, FR-034). It is the arbiter **at all times**, because it fails closed (`failurePolicy: Fail`,
AD-52): while the provider that serves it is down the dry-run itself fails, and the deployer reports
that as the cluster API dependency being unavailable — naming the admission webhook, retried under
the worker-call retry rule and never worded as a refusal of the request (NFR-010).

**The deployer decides what the allocator may release** (AD-32): a claim is provisional only while
its `Network` does not exist, and the deployer is the one tier identity that may read a `Network`,
so it names the releasable correlation identifiers and the allocator deletes only those. The
allocator reads no `Network` and FR-075's verb sets are unchanged. The deployer also applies every
submitted `Network` **with the provider's finalizer already set**, so no window exists in which an
object can be deleted outright and leave its claims with no release owner.

Demonstrable: a request runs through to a confirmed resource assignment — first here, because P6
ships the worker servers as shells and the mapper's and allocator's stage logic lands in this phase
(T084, T098, T099) — each of the four constructs provisioned end to end from natural language and
reaching Ready, the audit reconciliation — tier-originated changes against confirmations **and** submitted
hashes, out-of-band changes counted separately (SC-030) — the decline check, and the claim
life-cycle of a service whose VLAN was allocated: adopted while it lives, gone after either kind of
removal (SC-046).

### P8 — Chat surface

The browser app as a cluster workload with service-DNS wiring, per-stage rendering, both
confirmations — including the statement of evaluation order, usable priority range and
unmatched-traffic behaviour at the first one — live convergence, and the correlation-identifier chip.
The login form precedes everything: credentials are held in memory only, never in `localStorage` or
a cookie, and the app renders nothing of the pipeline until the supervisor has accepted them
(FR-102).

### P9 — Observability

The device collector pipeline: gNMIc subscribing to the registered native path set, exporting OTLP
to the in-cluster collector, with its own `/metrics` scraped as pipeline-health evidence. As decided,
gNMIc and the collector's Prometheus exporter are installed earlier, at `TargetsReady`, because they
are the read-back's state source (AD-82 `2026-09-21-state-source`; gNMIc sampling every 5 s, the
exporter dropping a series not refreshed within 20 s — AD-82 `2026-09-21-collector-freshness`); this
phase completes those two directories (TLS profile, gNMIc self-scrape, tier filter), and Prometheus,
Grafana and the rules stay at `ObservabilityReady`. The tier
collector — deployed at P6 with the analytics store and its generated credentials (AD-45) — gains
its second exporter here, the forward to the fabric collector, so one emission reaches both sinks.
The dashboards and
their alerts: fabric, orchestration, **EVPN service-path** — the leaf-to-leaf tunnel path of a
`mac-vrf` or `ip-vrf`, per-VTEP tunnel statistics, per-VNI MAC counts, and the hit counters of any
access list bound to it — physical topology, collector health and intent tier. The topology SVG and
panel YAML are generated by the pinned generator from the same containerlab inventory in the same
provisioning step as the collector's target list, joining on exactly two registered labels, `source`
and the normalized `interface_name`. Every asset is vendored, pinned and served from inside the
cluster. The bidirectional correlation-identifier links close the loop.

### P10 — Operator surfaces and one vocabulary

The guided prompts validated against the site inventory, the refusal alternatives, the read-time
construct derivation for services that predate the vocabulary, and the documentation pass —
including what each construct renders in the device's own object names, how rules are ordered, and
what happens to unmatched traffic. No retired name outside an explicitly labelled migration or
provenance context. The runbook gains the two procedures the clarifications require: **force-release**
— when it is justified, the annotation and its reason, what it may orphan, and how the finding is
cleared (FR-103) — and **operator credentials** — where they are, how to read them, how to rotate
them, and that they are lab credentials (FR-102). The repository `README.md` is **not** written
here: it is P12's.

### P11 — Hardening, evidence and removability

The phrasing and adversarial corpora; the legible-degradation cases, each naming its own dependency;
the runbook; the credential scan; a clean deploy/test/destroy cycle, with failed steps re-verified as a delta while every automated suite passes (operator decision 2026-09-28); and the removability run, on a lab provisioned again
`--with-intent-tier` after the last of those cycles has left nothing standing (AD-57) —
purge the tier — first without `--remove-services`, which must refuse non-zero having deleted
nothing, then with it — then a full control-plane gate run with the tier absent. Given the flag the
purge scales the tier's request-accepting workloads down, takes its authoritative list after that,
exports the audit record and removes the services the tier submitted through ordinary
finalization, bounded and never forced (AD-24, AD-26, AD-35); services in
`agentic-netops-services` are still there afterwards. With the store and the operator credential
gone, the audit reconciliation is then run in its file-source mode over the exported file and the
usernames record alone — the read-back that makes the export a record (FR-078, AD-46). The flag is given in this
run because those services exist only for it and the namespace cannot go while they are in it — not
because SC-025 needs it: the control-plane gates run against `agentic-netops-services`.

Four acceptance items land here and gate the phase:

- the **evidence-integrity audit (SC-040)** — every gate and acceptance artefact in the run carries
  its command, UTC time, exit status, image digest and cluster and lab identity; no artefact is
  hand-authored or post-edited; and every readiness check has a recorded negative control that failed
  on a stock fabric;
- the **ACL enforcement probe (SC-041)** — for one access list in each direction the pinned profile
  qualified, a probe the list denies is dropped, a probe it permits passes, and the per-entry match
  counters of exactly those entries move accordingly. Readiness still never depends on traffic;
- the **authentication audit (SC-042)** — every pipeline-reaching route attempted on both surfaces
  with no credential and with a wrong one: all refused, with zero threads, zero model calls and zero
  claims, and every audit event's principal reconciled against the usernames the run used — captured
  into the run's evidence at bring-up and again before the operator credential is removed, so the
  same reconciliation still runs from the exported file once the store and the Secret are gone
  (AD-46);
- the **delete-while-unreachable run (SC-043)** on the live lab — allocations held and the target
  named for at least ten reconciliation intervals, unaided completion on return, and one
  force-release leaving its durable finding naming the device and the released identifiers.

### P12 — Repository README and the recorded walkthrough *(final phase)*

Entered only from a lab that has passed P11 — and P11 ends with the tier removed, so the phase begins
by provisioning it again `--with-intent-tier` on the same pinned artefacts, the operator `username`
that run captures being the one the take's three `Network`s are checked against (T159, AD-57). It produces **C-22** and nothing else, under
[contracts/readme-and-walkthrough.md](./contracts/readme-and-walkthrough.md) and CD-06. In order:

1. **Port the recording tooling** from the predecessor — `testautomation/video/record.py`,
   `accept.py`, `check_framing.py`, `scripts/video-accelerate.sh` — changing only what the platform
   forces: the console login performed **before** recording starts, the native port names, and the
   leaf proof, which becomes read-only `sr_cli` `info from state` reads in place of `redis-cli`,
   `vtysh` and `bridge`. The framing assertions (whole topology visible on the canvas, terminal not
   clipped, prompt returned before the next command) are kept as they are.
2. **Freeze the take procedure** in `docs/DEMO_VIDEO.md`: pre-flight, smoke, record, accept,
   report, and the hard rules — read-only on devices and cluster, no driver edits mid-take, no
   retry with different wording, identifiers single-use.
3. **Smoke** (`record.py --smoke`): framing proven in about a minute, the three prompts validated
   against the site inventory and the offline translator, the identifiers confirmed free.
4. **Record one take**, silent, 1920×1080, uncut: the same three services in the same order as the
   predecessor's — a **`vlan`** (170, leaf01, tenant acme), an **`ip-vrf`** with its prefix
   (10.53.0.0/24, tenant initech), a **`mac-vrf`** stretched across both leaves (vlan152, tenant
   blue) — each typed as plain language into the operator console, confirmed at the mapper and at
   the allocator, reported deployed, then proven in the terminal with `kubectl` (the `Network`
   `Ready`, its events, its spec) and inside the SR Linux leaf (the network instance, its
   subinterface, the L3VNI and the Type-5 route for the `ip-vrf`, the VNI and the remote VTEP on
   **both** leaves for the `mac-vrf`).
5. **Accept** (`accept.py`): every "deployed" claim re-verified from `kubectl` JSON; evidence
   written to `docs/media/agentic-netops-srl-intent-tier-demo-evidence.json` with the NFR-013
   fields and `accept_pass: true`. A take that fails is deleted and reported verbatim — never
   embedded, never re-cut to hide the failure.
6. **Cut to 6×** with `video-accelerate.sh` — frames dropped, not blended, so text stays crisp.
7. **Capture the four figures** from the same live lab into `docs/images/`: the fabric topology,
   the fabric telemetry dashboard, the operator console mid-run, and the deployment outcome.
8. **Write `README.md` — the last task of the plan.** The predecessor's sections in the
   predecessor's order, every fact this platform's and every one of them observed: versions from
   `versions.lock.yaml`, timings and durations from the evidence file, *What works and what does
   not* and **Known limitations** from P11's results and the qualification record (including
   anything the gate left unqualified, and the constitution's MTU, pinning and IPv6-gateway facts),
   the repository layout from the tree as built. `make verify-readme` gates it.

**One step is the operator's, not the build's**: uploading the 6× cut as a GitHub asset and pasting
its URL under **Demo**. It is outward-facing, so it is prepared and handed over, not performed. Until
then the README carries the evidence link and a clearly marked placeholder line, and
`make verify-readme` reports the placeholder rather than passing over it. Badge URLs are resolved
from the real `origin`; none is invented, and a CI or merge-queue badge appears only if that
workflow exists.

## Verification strategy

Every success criterion maps to a runnable check. Every check's result is captured by the run that
produces it, under NFR-013.

| SC | Check |
|---|---|
| SC-001 | Clean-host lab launch driven only by the documented quickstart; all six containerlab nodes up and all four device targets Ready |
| SC-002 | Clean-host provisioning run: Kind, every required in-cluster application, all four targets and the default `Fabric` Ready with no undocumented manual step; a second run produces no destructive change |
| SC-003 | Shutdown from Ready, from partial and from already-absent states; ownership-scoped deletion verified; the second run is a no-op |
| SC-004 | Underlay eBGP (IPv4 and IPv6) and overlay iBGP EVPN session state **plus** Type 2, 3 and 5 route presence in both address families for the services that require them; a run on established sessions alone counts as failed (R-37). Two observations, both required: the session half with `inter-as-vpn` and `route-reflector client` read back from the configuration datastore on the default `Fabric` (`make verify-fabric-control-plane`; AD-76), and the route half keyed to the first services that span both leaves (`make verify-services`) — never a fabric-wide count, and never asserted on a fabric that carries no service (AD-23). `FabricReady` on its own is **never** SC-004 evidence: `make verify-evidence` — T012's script, which the acceptance script ends by running over its own run (`AD-71`) — refuses to record SC-004 until both observations and the route half's negative control are present in the evidence directory (AD-31). That control is declarative — `Fabric.spec.overlay.reflectorClients` set `false` and restored, the service's `RoutesMissing` observed within SC-044's bound — so the revertive policy cannot race it (AD-43; the field as decided in AD-77, removing `inter-as-vpn` having been observed by G8 not to stop reflection) |
| SC-005 | Cross-leaf L2, intra-`ip-vrf` L3, anycast-gateway reachability, inter-instance isolation, and the tenant MTU boundary as payload probes — 9320 (IPv4) and 9300 (IPv6) pass, one byte more fails — over a full clean run, with failed steps re-verifiable as a delta after their fix while every automated suite passes (operator decision 2026-09-28; a step that fails may be re-run **once** within its cycle and counts as passed only if the re-run passes; both attempts are recorded, and a step that fails twice fails the cycle (operator decision 2026-09-27)). Reachability, isolation and counter movement only; **throughput is never asserted** |
| SC-006 | Second reconcile of unchanged intent produces zero `Config` spec writes and zero gNMI Set mutations |
| SC-007 | Drift injected on a managed path is restored under the revertive drift policy, witnessed the way gate item **G13** observed it to be witnessable — by the recorded `Deviation` where one is durably visible, otherwise by the restored value read back from the device; an unmanaged path is neither overwritten nor claimed |
| SC-008 | Injected target and schema failures produce per-target `Degraded` within two reconciliation intervals with no aggregate Ready: a service still converging stays `Ready=False`, and one that had reported Ready before its target was cut reports `Ready=Unknown/VerificationFailed` naming it — asserted as *not True and not False* (AD-40); the bound is met by the layer's `Config` status, not the `Target`, which the pinned layer kept Ready through the cut (AD-82 `2026-09-24-layer-before-target`) |
| SC-009 | *Retired by the SR Linux retarget (RD-04) — SRv6 acceptance is deferred; see [spec.md](./spec.md) §Deferred scope.* |
| SC-010 | *Retired by the SR Linux retarget (RD-04) — SRv6 status visibility is deferred; see [spec.md](./spec.md) §Deferred scope.* |
| SC-011 | One prompt per construct, end to end, all four converging on the fabric |
| SC-012 | Every construct request with its required variables reaches either a converged service or a refusal naming the missing or invalid variable — never a state where objects exist and nothing converges; plus the offline translator loop over one input file per construct |
| SC-013 | A reader of only the four cited device references — the vendor's published 25.7 documentation for bridged instances and VLAN subinterfaces, for Layer 2 EVPN-VXLAN, for Layer 3 EVPN-VXLAN with IRB and anycast gateway, and for access lists — provisions each construct without a translation table |
| SC-014 | Access list provisioned both as a service and alongside one; after convergence, per-node read-back of the written configuration **and** the device's own applied view of that filter, keyed by filter name, type and entry, in the order the operator declared |
| SC-015 | The refusal fixture set: wrong-construct variable; duplicate priority; duplicate rule name; a rule claiming the reserved position 65535; a **reserved filter name** (`system`, `capture`); a prefix in the wrong address family; an L4 port on a protocol other than TCP or UDP; a **MAC list, refused as out of scope**; a **standalone access list on an attachment that does not exist**, naming the missing subinterface; an **egress list on a profile the gate did not qualify for egress** (on this lab every egress list, `acl.egress` being published unqualified); a **second list on the same subinterface, direction and address family**; binding to a network instance, a VLAN as such, an IRB interface or fabric-wide; a list referenced by name instead of stating its rules; no rules; no endpoints; an unknown construct; a **VLAN outside the platform's `100–4000`**, refused by the translator with both bands stated, and a **named VLAN outside the naming band `100–999`**, refused by the mapper at interpretation with both bands stated and before any claim (AD-41) — below `100`, in `1000–4000`, in `4001–4094` and above `4094` alike, the interpretation schema flooring a VLAN at `0` and carrying no upper bound (AD-56, AD-61); mismatched endpoint VLANs; unknown node; unknown port. Every one exits non-zero with named causes and emits nothing |
| SC-016 | Golden render and hash identical across repeated runs; **every golden render validated against the pinned device schema** — offline through a prefix-normalised copy, the golden keeping the observed prefixed identityref form (AD-81); every unsupported fixture rejected before any downstream object exists |
| SC-017 | Repository-wide CI deny-list over the three boundaries with the allowed contexts enumerated, plus the mechanical reference-artifact checks: no `raw.githubusercontent.com` in any dashboard, panel or datasource; every Grafana plugin install carries an explicit version; the topology generator is never invoked at `latest` or with the version omitted; every vendored asset carries a provenance header |
| SC-018 | Legacy-versus-construct equivalence: the emitted `spec:` blocks compared directly between the two vocabularies, byte for byte |
| SC-019 | A scripted operator session driven only through the chat surface provisions a supported L2 construct and a supported L3 construct with no knowledge of the resource schemas |
| SC-020 | ≥20 varied phrasings with expert-labelled expected readings; ≥90% correct on first attempt, every remaining case asking a clarifying question rather than proceeding |
| SC-021 | Agent-produced normalized intent fed through the same translator as the hand-authored path; the emitted `spec:` diffed against the golden files for every construct |
| SC-022 | The same corpus run against two distinct model providers with only a Secret changed |
| SC-023 | Wall-clock from the approved transition to converged, ≤5 minutes on the reference lab, operator confirmation time excluded |
| SC-024 | Scale one worker to zero; the deep health route names it, nothing is submitted, thread state survives, the request resumes on scale-up |
| SC-025 | Purge the tier, then a full control-plane gate run with the tier absent; 100% pass. **The denominator is defined, not implied**: `tests/e2e/sc_partition.yaml` (T175) assigns every live success criterion to exactly one of `control-plane`, `tier` or `both`; `make test-acceptance CONTROL_PLANE_ONLY=1` runs the `control-plane` set and the control-plane half of `both`, and reports every `tier` criterion by id as "not run: tier absent" — never skipped silently, never counted as passed; `tests/unit/acceptance/sc_partition_test.sh` fails on a criterion of spec.md that is missing from the partition or listed twice, and on a `control-plane` check that reaches for a tier workload |
| SC-026 | Decline at each confirmation point; zero fabric resources and zero claims under the correlation label, verified by comparing allocation state before and after |
| SC-027 | The unsupported-construct corpus: every request refused with the specific unsupported properties named, and zero fabric resources created |
| SC-028 | The adversarial corpus, ≥30 cases across direct device commands, shell/CLI requests, instructions injected in operator text, instructions injected in worker output, confirmation-bypass attempts and tool-name confusion. Refusal asserted; **zero device sessions asserted per source** — a packet counter inside each cluster node, ahead of the NetworkPolicy drop and of any source translation, matching intent-tier pod addresses toward the management CIDR, whose delta over the corpus run is zero and whose **positive control** is the boundary probe's dial from a tier-labelled pod moving it (AD-19; never a counter on the management network, which the device-configuration layer and the collector cross by design); and for the injection class a proposal byte-identical to the same request without the injected text |
| SC-029 | Authorization probes for every forbidden verb against both tier identities, plus a dial from a tier pod to a device management address on **every** port the image is documented to expose — the single list in [contracts/kubernetes-objects.md](./contracts/kubernetes-objects.md) §Identity contract, reconciled against G2's observed listening set. Every TCP dial denied; the UDP one recorded and asserted by SC-028's counter |
| SC-030 | The audit event stream reconciled against the resources the tier created **and their submitted-spec hashes**; counts equal, no tier-originated resource without a matching confirmation. Out-of-band edits and deletions injected with cluster tooling: 100% detected on the next status or removal request, reported as out-of-band, counted separately in the tier metric, and — asserted from `managedFields` and `resourceVersion` — answered with **zero** tier writes (FR-105) |
| SC-031 | Every trace, log and transcript from the SC-020 and SC-028 corpora scanned for credential patterns; zero hits |
| SC-032 | A clean-host run of [quickstart.md](./quickstart.md) by someone who did not build the platform — a person, or a fresh agent session under the operator's delegation (operator decision 2026-09-27) — with every agent confirmed healthy, within 30 minutes; the run follows the quickstart up to and including §27a and stops before §28, whose tooling is P12's (T153, AD-64) |
| SC-033 | Every operator-facing surface searched for retired service names; only explicitly labelled migration or provenance hits, including in how pre-vocabulary services are reported |
| SC-034 | Metric-store target health for the provider, the device-configuration layer, the device metric collector **including its own health endpoint**, the telemetry collector and every qualified device telemetry source; dashboards load the fabric and orchestration views with no manual datasource setup |
| SC-035 | A link or BGP failure and a failed reconciliation each firing their specified alert — `FabricLinkDown` or `BGPSessionDown`, and `ReconciliationFailed`, from the one alert table of [data-model.md](./data-model.md) §21 (FR-087) — during the acceptance run, and then clearing; `EvpnRoutesLost` fired and cleared the same way by AD-43's declarative fault (`Fabric.spec.overlay.reflectorClients: false` as decided in AD-77, restored from an exit trap as every declarative fault is — AD-60, AD-64) on a lab with a spanning service; and **every** rule of the ten — the `EvpnRoutesLost` guard's no-fire half, `OtlpDataPointsRejected` and `DuplicateDeviceSeries` among them, which have no declared live provocation — fired, cleared and held silent by T130's rule unit test (`promtool test rules` from the pinned Prometheus image, `tests/unit/alerts/`), recorded as a rule test and never as a live firing (AD-59) |
| SC-036 | Physical-topology and **EVPN service-path** views: node, link and interface identifiers compared against the live containerlab inventory and against direct metric queries, under normal traffic and a forced link failure, joining on exactly the two registered labels |
| SC-037 | Runtime inspection of the device metric path; zero duplicate subscription series, with subscription-based ingestion disabled in the device-configuration layer for the same series; a detectable alert when any pipeline stage stops exporting |
| SC-038 | Per-stage failure injection with the responsible stage named from the trace alone, without reading process logs |
| SC-039 | The correlation-identifier link followed in both directions — fabric telemetry view to the conversation that created the service and back — with no timestamp filter in either query |
| SC-040 | Evidence-integrity audit of the whole run: every gate and acceptance artefact carries its command, UTC time, exit status, image digest and cluster and lab identity alongside its raw output; no artefact is hand-authored or post-edited; and every readiness check has a recorded negative control showing it **fails** on a stock fabric that does not carry what it checks for |
| SC-041 | ACL enforcement probe, for one list in each direction the pinned profile qualified: the denied probe is dropped, the permitted probe passes, and the per-entry match counters of exactly those entries move accordingly. Readiness does not depend on it |
| SC-042 | Every pipeline-reaching route on the chat surface and the programmatic surface attempted with no credential and with a wrong one: 100% refused, and a thread count, a model-call count and a claim-selector diff taken before and after all read zero. The audit stream of SC-030 reconciled against **the usernames the run used** — while the tier runs, the distinct set T148 derives from the tier-phase captures written through `evidence_run`, a set of more than one member recorded as invalidating the measure; once it is gone, the usernames record the export step wrote, where `username_unchanged` is read — that field exists nowhere else, so nothing reads it before the export (AD-55) — never against the Secret alone, which the tier's removal deletes: every principal is a username that existed when the event was recorded. Taken twice — against the store while the tier runs (T148) and, in the reconciliation's file-source mode, against the exported file once it is gone (T152; AD-46). A request carrying a `principal` field is refused by name |
| SC-043 | `make test-delete-unreachable`: a service spanning both leaves is deleted with one leaf cut from the management network — a link-level cut (fault kind `mgmt-link-down`, reverted by `host-link-up`), never `docker network disconnect` (AD-82 `2026-09-21-mgmt-cut`). For at least ten reconciliation intervals the object remains, `Deleting` names the leaf, **`Ready` is `False/Deleting` at every poll from the deletion on — never `True`, never `Unknown` (AD-53)** — and a claim-selector diff shows 100% of its allocations still bound; on reconnection removal completes with zero operator action and the claims release. A second run force-releases instead — **first with an empty reason, which is refused with a `Warning` Event and releases zero identifiers by claim-selector diff**, then with a stated one — and asserts the Event, the `Fabric.status.findings[]` entry naming the device and the identifiers — present during the outage while the `Fabric`'s `Degraded` reason is still `VerificationFailed`, `StaleConfigurationPossible` being the reason from the first pass after the leaf returns (AD-54) — and its clearance only after a clean read-back |
| SC-044 | `make test-reverify`: with a service spanning both leaves Ready and its intent untouched, one leaf's uplinks are administratively disabled through `Fabric.spec.maintenance[]` — which is what takes its overlay sessions down. Within one re-verification interval plus one reconciliation interval the service reports `Ready=False/RoutesMissing` naming the missing remote tunnel endpoint or route; on removal of the maintenance entry it returns to `Ready=True` within the same bound; `status.lastVerifiedTime` advances on every interval throughout; zero `Config` spec writes are caused by the schedule itself. **The cannot-run half**: the same leaf is instead cut from the management network (link-level, AD-82 `2026-09-21-mgmt-cut`); at the first pass that cannot read it — or sooner, when the reconciler sees the target not Ready between two passes — as decided, the layer no longer confirming the service's `Config` (AD-82 `2026-09-24-layer-before-target`) — within SC-008's 30 s of the cut — the service reports `Ready=Unknown` and `Degraded=True`, both `VerificationFailed` naming the leaf, and **from that first `Unknown` until reconnection** no poll shows `Ready=False` and none shows `Ready=True` (the polls are anchored there — AD-62), `status.lastVerifiedTime` stops advancing, and `Ready=True` returns at the first pass after reconnection (AD-40). Run with the interval overridden to a test value — never below the 30 s floor — **and** once at the five-minute default |
| SC-045 | `make test-provider-claims`, run with no intent tier installed: a `mac-vrf` spanning both leaves and an `ip-vrf` are applied with `kubectl`; a claim-selector diff shows one bound claim per VNI, labelled with the `Network`, **before** its first `Config` exists; a second `Network` naming the same L2VNI is `Accepted=False/AllocationConflict` naming the value and the first `Network`, with zero `Config`s; `examples/constructs/negative/vlan-unclaimed-band.yaml` — a VLAN in the allocation band with no claim, kept in a subdirectory the wholesale `kubectl apply -f examples/constructs/` does not descend into — is `Accepted=False/AllocationConflict` naming the VLAN and both bands, again with zero `Config`s, while the examples' naming-band VLANs are accepted with zero VLAN claims (AD-50); after deletion the selector is empty. Negative control first: the check fails for a `Network` whose claim was deleted by hand |
| SC-046 | With the tier installed, a `mac-vrf` requested with **no VLAN named**: while it exists a claim-selector query on its correlation label returns its VLAN claim and its VNI claim, both listed in `status.claimRefs` as `adopted`; removed **through the tier**, the selector is empty once the `Network` is gone and the tier deleted no claim (asserted from the claims' deletion being the provider's, after the read-back); a second such service deleted with **`kubectl delete`** ends the same way; and a third is deleted with `kubectl` **as soon as the deployer reports the apply, with the provider's pod killed at the same moment** — after the apply and never before it, because the fail-closed webhook refuses an apply while the provider is down and leaves only the delete uninterrupted (AD-52) — the selector is empty once the provider is back and the `Network` is gone, whether or not the deletion beat the first reconcile, which the run records and does not assert: the deterministic proof that finalization adopts before it releases is the envtest case (AD-44); an attachment carrying the allocated VLAN is removed from the first `mac-vrf` while it lives and its VLAN claim stays `adopted` until finalization; and an `ip-vrf` requested with an attachment that names no VLAN shows **zero** VLAN claims under its correlation label, none ever being allocated for one (AD-51). Negative control first: the check fails for a service whose VLAN claim was relabelled by hand so that it cannot be adopted |
| SC-047 | `make verify-compat` (T050) asserts exactly one allocation authority in the running cluster — under `kuid` neither first-party allocation CRD is served, under `first-party` no `*.be.kuid.dev` APIService exists — and G11's early hook is run with the authority made to fail by T044's `tests/unit/lifecycle/g11_stop_test.sh` (a fake `kubectl`, the round-trip failing in each of its two forms): provisioning stops non-zero naming G11 with zero applications installed above it and no flag offering another allocator. Negative control first: the one-authority assertion fails against a cluster where both are present |
| SC-048 | `tests/unit/lifecycle/intent_secrets_test.sh` and `agents/tests/unit/test_llm_endpoint.py` (T168): a re-provisioning run that sets model and key leaves the stored base URL byte-identical; only the named clearing input removes it; a declared gateway with no base URL exits non-zero with zero tier objects created; and every provisioning and start-up line naming the endpoint is scanned for credential characters, with a base URL carrying embedded userinfo as the fixture. Negative control first: the byte-identical check fails against a whole-object Secret replace |
| SC-049 | `make verify-boundaries` (T025) over the whole repository, with the fixture in `tests/unit/verifyboundaries/` as its negative control: a device client invoked from a file outside `tests/`, `testautomation/` and quoted command blocks fails the check naming the file — a `gnmic` line planted under `scripts/lib/` among the fixtures, which is why the `LabReady` wait is a credential-less port accept and not a gNMI call (T034, AD-57). Beside it, `run_gate.sh` (T043) reads back the removal of its own scratch configuration on every node before it reports, so `FabricReady` never starts on a dirty device |
| SC-050 | The log-shape half of the credential scan (T147) over every trace, log and transcript of the acceptance runs: 100% of first-party lines parse as one JSON object carrying the data-model §27 fields, 100% of lines belonging to a request carry its correlation id, zero lines carry a credential. Negative control first: the shape check fails against a line with a missing field and the scan fails against a planted credential |

Layer coverage beyond the success criteria:

| Layer | Verification |
|---|---|
| API | CRD structural schema, CEL and webhook rules, server-side dry-run against a real schema, status and finalizer tests; **the webhook fails closed** — the shipped configuration states `failurePolicy: Fail` on `CREATE` and `UPDATE` and does not list `DELETE`, and with its endpoint unreachable in envtest a `Network` create and an update are refused while a delete is accepted (T056); the deployer classes a dry-run that failed for that reason as the cluster API dependency being unavailable, retried and then reported as that, never as a validation refusal (T092, T146; AD-52); **and what the webhook does not evaluate** — on a deleting `Network` whose node has left the `Fabric` inventory the force-release annotation and the finalizer's removal are admitted, a metadata-only `UPDATE` of a live object is admitted, a `spec`-changing `UPDATE` is still evaluated, and with the endpoint unreachable all of them are refused, the exemption being the handler's (T056; AD-61) |
| Vocabulary | Alias folding, `typeKey` equivalence, the wrong-construct refusal table, the construct list in refusals, and the CI assertion that the two device-named constructs still match the pinned model |
| Translation | Table and golden tests for every construct and every legacy alias, supported and unsupported |
| Rendering | **Golden SR Linux JSON validated against the pinned device schema**, plus stable hashes and names, version-mismatch handling, per-construct render assertions, and the native-first assertion that no rendered path leaves the register |
| Path register | The CI guard exercised by the actual render and subscription functions, so a new construct or a new metric cannot pass uncovered |
| Controller | envtest for waits, retries, idempotence, ownership, status, restart and deletion |
| Device transactions | Targets and `Config` objects Ready, invalid schema rejected before any write, transaction rollback confined to its own transaction, deviation recorded and an overruled platform-owned path treated as terminal, and a priority collision refused at validation |
| Capability gate | G1–G13, each with run-captured evidence and, where it is a readiness check, a recorded negative control; the per-construct qualification record round-tripped into a refusal |
| Fabric | Underlay and overlay neighbours, Type 2/3/5 routes, network-instance, VNI, EVI and route-target state, remote VTEP presence |
| Traffic | Cross-leaf L2, intra-`ip-vrf` L3 and anycast-gateway IRB, inter-instance isolation, the MTU payload boundary, and the ACL permit/deny probe with its counter deltas — never a rate |
| Contracts (tier) | Schema round-trip and rejection tests for every contract; strictness matched between the Python model and the Go parser |
| Graph | Node-level routing tests for each conditional edge, the iteration guard, and the wall-clock deadline |
| Checkpointer | Supervisor killed mid-request with an assignment confirmed; the thread resumes and nothing double-submits |
| Transport | An unauthenticated registration attempt refused |
| Atomicity | A rejection injected on the second object of a bundle; the first deleted and the rollback set reported |
| Telemetry | Exactly one exporter configured per agent process, and both sinks carrying the same trace identifier; the register guard refusing a subscribed path whose label set is not closed and bounded; a series whose source stopped reporting going stale rather than holding its last value |
| Failure | Link and BGP loss, target outage, partial apply, drift, telemetry outage |
| Runtime placement | Every platform application Ready in the cluster and none in a Compose or standalone form |
| Lifecycle | Provisioning twice (idempotence) and shutdown twice (no-op second run), with and without the tier |
| Reproducibility | `make verify-pins` resolving every digest, then one clean deploy, test and destroy run on the pinned artifacts, failed steps re-verifiable as a delta after their fix while every automated suite passes (operator decision 2026-09-28; a step that fails may be re-run **once** within its cycle and counts as passed only if the re-run passes; both attempts are recorded, and a step that fails twice fails the cycle (operator decision 2026-09-27)) |
| Authentication | Handler-level tests that a refused request mints no thread identifier; constant-time comparison; the strict schema refusing `principal`; the Secret re-read on rotation |
| Admission | The force-release annotation denied to both tier identities and allowed to a cluster admin, probed in P1's boundary step beside the RBAC and NetworkPolicy denials — executed after P3, so the `Network` CRD exists (AD-08) — and re-run at P11 |
| Allocation authority | `make verify-compat` asserting exactly one authority installed and that it is the lock file's; `make verify-pins` refusing `first-party` without a decision record and failed-gate evidence that resolve |
| Model-provider Secret | A declared gateway with no base URL refused before any tier workload exists; a re-provisioning run that omits the base URL leaves the stored one byte-identical; the explicit clear honoured; the effective endpoint printed **with zero credential characters on the provisioning lines as on the start-up lines** (embedded-userinfo fixture); an agent refusing to start on a gateway Secret without a base URL; **a running agent whose Secret loses its base URL making no further model call and never dialling the library default**; **the manifests of all four agents mounting `llm-provider` as a read-only volume and none referencing it through `secretKeyRef` or `envFrom`, without which the running-agent rule cannot be observed (T087, asserted by T168's manifest half — AD-54)** — T168, T072, T080 (FR-106, SC-048, AD-49) |
| Scheduled re-verification | envtest with a fake clock: the requeue fires at the interval, a withdrawn invariant flips Ready off with its reason code, `lastVerifiedTime` advances on every pass that ran — the one that found the invariant missing included (AD-54) — no `Config` write results; **an unreachable target gives `Ready=Unknown/VerificationFailed` and `Degraded=True/VerificationFailed` naming it, never False and never a standing True, with `lastVerifiedTime` frozen, and the first pass after it returns gives `Ready=True`** (T028, T054; AD-40); `cmd/srl-provider/reverifyinterval_test.go` (written by T028, made to pass by T042 — AD-59) asserts that `REVERIFY_INTERVAL` below the 30 s floor, and an unparseable one, each refuse the start naming the variable, while unset takes the five-minute default; the live run is SC-044 (FR-107) |
| Verification-tooling boundary | The CI check fails a device client invoked outside `tests/`, `testautomation/` and the quoted commands of the docs; the gate's scratch removal is read back before `FabricReady`. **The interrupted tool**: scratch objects carry the reserved `vt-scratch-` name prefix — which no golden may contain — the gate-owned scratch `Config` its label, every scratch namespace the gate starts — G7's throwaway Pod pair, T166's Pods — the same label (AD-60, AD-64), and every declared injected fault is written to `declared-faults.json` before it is made; `leftovers::scan` (`tests/lib/leftovers.sh`, T043) runs first in the gate, in T051's probe, in every fault-making suite of T064, T167 and T134 — `alerts_fire.sh` cuts a leaf from the management network and impairs a link, and declares both before it makes them (AD-57) — and once in `make test-acceptance`, and **refuses the start naming the node and the leftover**; `tests/unit/gate/leftover_scan_test.sh` plants one of each kind — a `vt-scratch-` instance, a gate-labelled `Config`, a gate-labelled scratch namespace and a node missing from the management network — probed on the data path, carrier and TCP accept on the gNMI port, the cut itself being link-level (AD-82 `2026-09-21-mgmt-cut`) — four (AD-64) — and asserts each refusal, and that a clean lab starts (FR-108, AD-49) |
| First-party images | Fixture Dockerfiles with a tag-only `FROM`, a `FROM` digest that differs from the lock, a dependency lock whose hash differs, and a manifest with a mutable first-party tag — each fails `make verify-pins`; `make verify-compat` fails a workload whose image ID is not this run's build (NFR-003) |
| Provider-side claims | envtest: a `Network` with no adoptable claim gets one claim per VNI for exactly the stated value, deterministically named and labelled, before any `Config`; a bound claim carrying the object's correlation label, bearing the deterministic name for that field **and** reporting the value is adopted and none is created, while a label-and-value match under any other name is not — VNI and VLAN claims by the one three-part rule (AD-42); a held value or one outside the allocation band is `Accepted=False/AllocationConflict` with zero `Config`s; both kinds released at finalization; a **VLAN** claim is adopted on the same three things for a VLAN the object carries and released with them, none is ever created; a VLAN in `100–999` stays unclaimed and one in `1000–4000` that no adoptable claim backs is `AllocationConflict` naming the VLAN and both bands (AD-33), an `accessLists`-only object's attachment VLAN being a reference that needs no claim (AD-47); a claim once `adopted` stays listed and is never re-evaluated — a `mac-vrf` whose VLAN was allocated keeps it after an attachment carrying it is removed (AD-32); an `ip-vrf` attachment carrying a VLAN in `1000–4000` is `AllocationConflict`, no claim being adoptable behind it by construction (AD-51); with the `pkg/kuid` fake **erroring**, nothing is rendered, no `AllocationConflict` is recorded and the pass retries, and a deleting object keeps its finalizer and every claim until the fake answers (AD-56); and an object deleted **before its first reconcile** has its claims adopted at finalization and then released, none orphaned (AD-44). The live runs are SC-045 and SC-046 (FR-109) |
| Structured logs | Every first-party workload's log stream parsed line by line as JSON with the NFR-014 fields; the correlation identifier present on every line of a request; run over the corpora by the credential scan's harness (NFR-014) |
| Pin exceptions | A lock file declaring any exception other than the recorded allocator substitution fails `make verify-pins`; the substitution is warned by name on every provisioning run (NFR-003) |
| Drift policy | The provider refuses to start with `DRIFT_POLICY` unset, empty, `non-revertive`, `Revertive` or `true` — the closed set is the exact string `revertive` — naming the variable and the admissible value; every generated `Config` states the policy in its `revertive` field rather than leaving it absent, which the generated-`Config` assertions of T028 (`Fabric`) and T054 (`Network`) check — it is a `Config.spec` field, not rendered payload — because an absent field inherits the layer's global default; lab and production alike select `revertive`. **What the policy never does is fight an overruling intent**: an `OVERRULED` deviation on a platform-owned path is FR-015's terminal error — `Applied=False/OwnershipConflict` naming the path and the overruling intent, never reapplied — built by T059 and asserted by T054 with a fake `Deviation{reason: OVERRULED}`; T064's live drift suite asserts it only if gate item G13 recorded such a deviation as producible and otherwise reports it "not demonstrated live; envtest-covered" (FR-015, AD-17, AD-34, AD-66) |
| Tagging mode | An attachment in a mode other than the one the `Fabric` inventory declares for its port refused listing the ports declared in the mode asked for (`AD-68`); an untagged and a tagged attachment on one (node, port) refused in one object by CEL and across two by the webhook, naming the port and both services; refused by the deployer's pre-flight before anything is created; a standalone access list on the existing attachment is not a second mode (FR-034, AD-20) |
| Audit record | Every confirmation, decline, submission, refusal, removal and out-of-band event present in the analytics store as a span event on its request trace; the supervisor publishes no Kubernetes Event and holds no permission to; the deployer's three mirrored Events carry the same correlation identifier; the reconciliations of SC-030 and SC-042 read the store and never an Event — and, once the store is gone, the exported file: the audit reconciliation's **file-source mode** runs the stream half of both from the exported newline-delimited JSON and the usernames record alone, reporting the live-object half as not run, and the removability run ends with it; the store's trace tables carry **no expiry** and are exported by the evidence capture before anything removes them (FR-078, AD-18, AD-24, AD-36, AD-46) |
| Host tooling | A ranged browser-automation version, an installed browser revision that differs from the locked package's, and a missing or different capture tool each fail `make verify-pins` naming the entry; the versions a run used are in its evidence (NFR-003, AD-21) |
| Offline suites | `make test-static test-envtest test-agents test-ui` are every suite that needs no lab; the CI workflow runs all four on every pull request, and a test asserts that every directory under `tests/envtest/` is reached by `test-envtest`; `test-static` also runs every offline **shell** suite, `tests/unit/**/*_test.sh`, and a second reach test fails naming a `*_test.sh` outside the live directories that it did not run (FR-020, AD-28, AD-50) |
| Immutable identifiers | envtest updates of an accepted `Network`: a changed `l2vni`, `l3vni` or service VLAN refused naming the field; a removed attachment accepted; an added attachment accepted when it carries a naming-band VLAN, none, or an allocation-band VLAN **the object already carries** — a `mac-vrf` whose VLAN was allocated gains an attachment on that same VLAN — and refused, naming the VLAN and both bands, when it brings an allocation-band VLAN the object does not already carry (AD-47), an `ip-vrf` gaining an attachment on VLAN `1500` among them (AD-51), while an `accessLists`-only object gaining one is accepted, outside the rule (AD-56); a `metadata.name` or a list-entry name of 64 characters refused, the bound that keeps every claim name inside 253 (AD-56); no second claim ever made for one role (FR-109, AD-25, AD-32, AD-33) |
| Audit export and tier removal | Against a fake `kubectl` and a fake store: the export runs before the store is deleted on both down paths, requested or not, carries the NFR-013 fields and a per-attempt identifier, and honours its own bound; a failed export — unqueryable store, query error, unwritable artefact, short row count — stops with the store intact, while an absent store is skipped and an empty one succeeds; `--discard-audit-record` is printed and recorded; the purge **refuses non-zero, deleting nothing, while tier-submitted `Network`s exist and `--remove-services` was not given**; with it the only call before the scale-down is the refusal-decision list, a read — the request-accepting workloads are scaled down before the **authoritative** list and before the export, exactly the `Network`s of that list are deleted; with no flag and an empty first list the scale-down still precedes the export, and with no flag and a `Network` that lands between the two lists the purge falls back to the refusal, deleting and exporting nothing; the usernames record is written before the operator credential is removed; a re-run skips a *verified* export found under the lab's evidence root, capturing the skip, and adds a new artefact otherwise, never rewriting one (`data-model.md` §16); a file planted under that root is byte-identical after the purge and after the full teardown (T174, T029); and on the **up** path `tier_phase_order_test.sh` asserts from the call log that the analytics store and the tier collector are applied and waited Ready after the denial probes and before any agent workload (AD-45, AD-64); one still `Deleting` after the wait stops the purge non-zero naming it and its target, the namespace is not deleted until a re-list is empty, and nothing is force-released (FR-078, NFR-006, SC-042, AD-24, AD-26, AD-35, AD-36, AD-46) |
| Default bounds | Each default of [data-model.md](./data-model.md) §25 asserted, each override honoured, and the start-up ordering assertion refusing an inconsistent override |
| Closing deliverable | `make verify-readme` (section order, links, lock-file versions, constitution facts, deny-list terms, evidence `accept_pass`), plus the walkthrough's own `accept.py` — the recording is accepted from cluster JSON, never from a frame |

## Risk register

Numbering is continuous and stable; every risk keeps its source attribution. `001:plan` rows are
cited by their position in that plan's unnumbered risk table. Rows the retarget retired keep a
tombstone.

| # | Risk | Mitigation | Source |
|---|---|---|---|
| R-01 | Published upstream examples and the current CRDs differ | Pin a full release or commit; validate every manifest against it; never mix API shapes; do not assume a served version is the storage version | `001:plan` risk 1 |
| R-02 | One first-party provider is the only renderer of every device path, so a render defect has no second opinion and no upstream to inherit fixes from | Keep the provider narrow and its render surface in one package; version the mapping (`srl-mapping v0.1.0`) and assert it against compatibility-set parts 1–4; golden files frozen only after G12; the path register makes an uncovered path a CI failure; contribute upstream after qualification | `001:plan` risk 2, RD-03 |
| R-03 | The licence-free emulated types do not model a property a construct depends on | One profile only, so there is no "use the other one" escape: the capability gate records the property unqualified per construct and the platform refuses it by name at interpretation (FR-097), never relaxing the gate | `001:plan` risk 3, RD-01 |
| R-04 | *Retired by the SR Linux retarget (RD-04) — the SRv6 dataplane risk is deferred with the SRv6 service.* | — | — |
| R-05 | Standard-model coverage is incomplete: the device's own deviation files mark OpenConfig EVPN, the EVPN address families, VXLAN encapsulation and the FDB `not-supported`, and the pinned schema carries native models only | Native-first by requirement (FR-017, RD-08): every rendered and subscribed path is native unless the register records a justified exception, and the register is CI-guarded | `001:plan` risk 5 |
| R-06 | Duplicate controller ownership of one path | Explicit source-of-truth table, scoped paths, a dedicated field manager, distinct `Config` priorities with a collision refused at validation, priority tests | `001:plan` risk 6 |
| R-07 | Source MPLS semantics lack equivalents | Allow-list mappings; reject the whole request; limited equivalence only by opt-in | `001:plan` risk 7 |
| R-08 | The lab runtime needs privileged containers, and four network nodes plus the cluster crowd a single host | Document the trust boundary and the footprint: no KVM and no nested virtualization are required, ≈2 vCPU and 2 GiB per node (1.4–1.8 GiB RSS idle measured in research, re-observed at P0); the host-resource preflight fails before any mutation | `001:plan` risk 8, RD-01 |
| R-09 | Duplicate telemetry and cardinality blow-up | One ingestion path per signal; subscription ingestion disabled in the configuration layer for the same series; bounded labels; CI query assertions | `001:plan` risk 9 |
| R-10 | Topology and metric labels do not join | Generate topology assets and the collector target list from the same containerlab inventory in the same step; join on exactly two registered labels, `source` and the normalized `interface_name`; CI parity and query tests | `001:plan` risk 10 |
| R-11 | VXLAN overhead breaks traffic, silently and asymmetrically | Set the whole envelope explicitly — fabric links 9412, underlay `ip-mtu` 9398, tenant 9348, client interfaces 9348 because the veth default blackholes TCP, and IRB `ip-mtu` explicit because the device performs no VXLAN MTU check — and prove the 9320/9300 payload boundary as gate item G6 before any service acceptance | `001:plan` risk 11, RD-10 |
| R-12 | The shared Docker management network is over-broad or collides with an existing one | A dedicated labelled network with a configurable CIDR (default `172.25.25.0/24`), exact ownership checks, and an overlap preflight against every existing Docker network and the pod and service CIDRs that fails naming the collision; the topology never sets the management MTU, which half-applies silently | `001:plan` risk 12, RD-01 |
| R-13 | The centralized cluster exhausts host resources | Document requests, limits and volume sizing; fail preflight before any mutation | `001:plan` risk 13 |
| R-14 | The pinned transport image may not expose client-CA verification, leaving the transport authenticated only by a shared password | Qualify at P0 against the pinned image; the documented fallback (server-side TLS, gateway password, NetworkPolicy) is an accepted risk with the production delta named — production must front the transport with a mesh providing workload identity | `002:plan` R-01 |
| R-15 | The provider's watch scope must cover objects the tier submits in a namespace the provider does not live in | Not a qualification item: with a first-party provider this is first-party configuration — the `Network` reconciler watches cluster-wide by design, set in the provider's own deployment, changing no schema and no contract | `002:plan` R-02, RD-03 |
| R-16 | The tier's identity extends into the allocation namespace, which it does not own | The Role is limited to VLAN and GENID claims with create and delete and deliberately no update or patch; no access to indices or Secrets; every claim carries the correlation label so its footprint is enumerable | `002:plan` R-03 |
| R-17 | A single-writer checkpointer pins the supervisor to one replica | Accepted under lab-scale concurrency; a recreate strategy prevents two writers; the migration to a multi-writer store is recorded as the revisit trigger | `002:plan` R-04 |
| R-18 | Model quality drifts and interpretations regress, especially across a provider switch | Safety is specified not to depend on it: both confirmation gates, schema validation, the qualification-record check and unsupported-construct rejection hold regardless. The phrasing corpus runs per provider so a regression is visible rather than silent | `002:plan` R-05 |
| R-19 | The tier dashboard needs a mount on the fabric dashboards workload, which is a control-plane file | The patch is two lines applied by the tier flag and reverted by the purge flag; it changes no controller, schema or reconciliation contract, and the removability run proves the revert | `002:plan` R-06 |
| R-20 | Prompt injection succeeds despite the stacked mitigations | Defence in depth is structural, not textual: even a fully successful injection cannot make the tier act on a device, because the identity and the network policy cannot express the action | `002:plan` R-07 |
| R-21 | Kubernetes has no multi-object transaction, so "atomic" is a construction that can still fail mid-rollback | Dry-run first catches the overwhelming majority before any mutation; the correlation label makes the rollback set exact and re-runnable, including after a restart; a failed rollback is reported as failed with the surviving objects named, never as success | `002:plan` R-08 |
| R-22 | The polyglot tree doubles the build and CI surface | Additive only: new jobs and new images, no change to the Go job or the Go tree; deleting the tier deletes its jobs | `002:plan` R-09 |
| R-23 | The analytics store and the extra agent pods displace fabric workloads on the single-host lab | Explicit requests and limits on every tier pod; single replica everywhere; the host-resource preflight extends before the tier phase mutates anything | `002:plan` R-10 |
| R-24 | Two collectors could drift into two instrumentations | The conformance test is mechanical: assert exactly one exporter is configured per agent process. Fan-out is collector configuration, never a second SDK | `002:plan` R-11 |
| R-25 | *Retired by the SR Linux retarget (RD-02) — the whole-config write hazard that justified a second write path belonged to the predecessor platform's configuration store and has no counterpart here; there is one southbound and no raw-store path.* | — | — |
| R-26 | A rule sits in the configuration store that the device never programmed, so the filter matches nothing | **Closed by construction.** Every applied-side path is keyed by filter name, type and entry and split by direction, so a device-wide or fabric-wide count cannot be written as evidence (FR-042, FR-100). The documented hazard that remains is the opposite one: a stock fabric already carries the device's own control-plane filter entries, so any check must be shown to fail on that stock fabric before its pass counts (NFR-013, SC-040). Dataplane enforcement is demonstrated separately in acceptance (SC-041), never as readiness | `003:plan` R-02, RD-05 |
| R-27 | Regenerating the golden files hides a real change in the rendered intent | The legacy-versus-construct equivalence test compares the emitted `spec:` blocks between vocabularies directly, so an accidental change fails even when both goldens moved together | `003:plan` R-03 |
| R-28 | An operator names a VLAN the platform cannot give them, so the service is unprovisionable for a reason nobody stated | No VLAN band is **derived** any more — SR Linux derives none, which is what RD-09 settled. What exists instead is a **chosen** partition of the platform's VLAN space (AD-33): an operator names from `100–999` and the allocation index manages `1000–4000`. A named VLAN outside `100–999`, and any VLAN outside `100–4000`, is refused at validation **with both bands stated**, before submission and before any claim; the naming band is enforced on the tier path by the **mapper, at interpretation** — the translator sees a bare integer after allocation and checks the structural `100–4000` only (AD-41) — and on the cluster-tooling path by the band rule of FR-109, and the index's own `minID` keeps the authority out of it | `003:plan` R-04, RD-09, AD-33, AD-41 |
| R-29 | Two services binding a filter to the same place at the same stage have platform-undefined evaluation order | The unit of exclusivity is (node, interface, subinterface, direction, address family), because the platform accepts one filter of a type per subinterface per direction. A second is refused at the deployer pre-flight naming the holder; two services may still share a physical port on different subinterfaces or different address families; the renderer never rewrites another filter's binding | `003:plan` R-05, RD-05 |
| R-30 | The suggested prompts drift from the site's real port map and advertise ports that do not exist | The quickstart validates every suggested prompt against the site inventory; a unit test asserts each prompt's nodes and ports are in it | `003:plan` R-06 |
| R-31 | The allocation authority is dormant upstream (last release 2024-12-27), so a defect found at P0 has no upstream fix | Pin `kuid-server v0.0.13` by digest and qualify it at P0 as gate item G11 — a claim reports its allocated value in status and the aggregated API is healthy on the pinned Kind. **A G11 failure stops provisioning with the item named; the script never selects another allocator.** The named fallback — a first-party allocator behind the **same claim semantics**, its kinds in the first-party API group and never in the upstream one — is adopted only by a recorded operator decision citing the failed gate evidence, selected through the lock file, warned on every provisioning run, and never installed beside the upstream authority (FR-104, CD-03). **Realised**: G11 failed on `kuid-server v0.0.13` (2026-09-21) and the first-party substitute was adopted by that recorded path and passed G11 (AD-74); it is the authority that runs on this lab, kuid remaining the alternative the lock can select | RD-03, CD-03, AD-74 |
| R-32 | The schema deviation patch the configuration layer applies could weaken validation, letting an invalid configuration reach the device | Gate item G10: the deviated schema is shown to still **reject** the invalid configurations the platform relies on being rejected. A failure here is a gate failure, not a tolerated delta | RD-12 |
| R-33 | The device's gRPC session limit (default 20) is shared by the configuration layer and the metric collector, so one can starve the other | Size the limit explicitly in the bootstrap configuration for both clients together, and keep subscription ingestion disabled in the configuration layer for series the collector already carries (FR-086) | RD-01, RD-11 |
| R-34 | The lab image also exposes a plaintext management port the platform never uses, which a mis-scoped policy could leave reachable | The NetworkPolicy denies the **whole management CIDR on every port**, not an allow-list of the ports in use, and the P1 denial probe dials the plaintext port explicitly alongside the encrypted one and the shell (FR-075, SC-029) | RD-01 |
| R-35 | The containerized dataplane forwards at roughly 1–5 kpps per node, so a test that asserts a rate is flaky by construction | No test asserts throughput. Traffic tests assert reachability, isolation and counter movement only (FR-020, SC-005), and the limit is documented as a property of the lab (NFR-004) | RD-01 |
| R-36 | The JSON serialization the device returns for identityref-typed values may differ from what the renderer emits, so an idempotent reconcile looks like a change | Gate item G12 observes the exact form from a real Get, and **golden files are frozen only afterwards** — in the observed module-prefixed form, the offline validator checking a prefix-normalised copy (AD-81); the idempotence check (SC-006) is what would catch a later drift | RD-12 |
| R-37 | A route-reflecting spine that is not a tunnel endpoint silently rejects every EVPN route unless it is configured to carry them, producing "sessions up, zero routes" | Gate item G8 includes the check explicitly, and on 25.7.1 it did **not** reproduce the assumption: with `inter-as-vpn` removed reflection continued, while removing `route-reflector client` stopped it (AD-77). The fabric render still sets `inter-as-vpn` on the reflecting spines from `Fabric.spec.overlay.interASVPN`, which the default `Fabric` states `true`, under the configuration-integrity check (declared equals read back); the setting that stops reflection is `Fabric.spec.overlay.reflectorClients` (default `true`, rendered as `route-reflector client`), whose `false` sets the `Fabric` `Ready=False/NotConverged` naming the spines and the setting (AD-43, as decided in AD-77), and SC-004 refuses to count established sessions alone as a pass | RD-01, RD-12, AD-77 |
| R-38 | The operator credentials are HTTP Basic over plaintext, so anything on the path can read them | Both surfaces are published on the loopback address only; the password is always generated and never defaulted; the chat surface holds it in memory only; the trace and transcript credential scan (SC-031) covers the `Authorization` header; and the runbook and the README state that these are lab credentials with the production delta named — an identity provider and TLS in front of both surfaces (FR-019) | CD-01 |
| R-39 | A force-release frees identifiers a device may still carry, so the next service can collide with stale configuration | The finding on the `Fabric` outlives the service and names the device, the identifiers and the rendered object names; a render that would produce one of those names on that node is refused while the finding is open; the finding clears only after a read-back shows the objects gone; the tier's identities are denied the annotation by admission policy. What the device-configuration layer does on the target's return is observed at P3, not assumed | CD-02 |
| R-40 | The submitted-spec hash reports a false out-of-band change — because the hash was taken before defaulting, or because a later CRD revision adds a default that changes what an old object reads back as | The hash is taken from the server-side dry-run result, the form a read returns; the provider never writes `spec` and no mutating webhook exists on the group; and adding or changing a default within `v1alpha1` is treated as a breaking schema change that ships with a re-stamp note. A unit test pins the canonical form | CD-04 |
| R-41 | The recording shows a success the cluster did not have — a frame is persuasive in a way a log line is not | Acceptance is from `kubectl` JSON by `accept.py`, never from a frame; the evidence file carries the NFR-013 fields; a take that fails acceptance is deleted; the driver is read-only on devices and cluster and is not edited mid-take; the README's claims are gated by `make verify-readme` | CD-06 |
| R-42 | "Exactly the same" walkthrough drifts from the predecessor's, or carries a predecessor fact into this README | The three prompts are tabulated against the predecessor's word for word with the one forced change explained (CD-06); the README contract fixes the section order; `make verify-readme` deny-lists predecessor platform terms and checks every stated version against the lock file; the recording never shows a credential, because login precedes recording | CD-06 |
| R-43 | A first-party workload runs an image the current tree did not build — a stale image left in the Kind node from an earlier build, under a tag that still resolves | The tag **is** the content hash of the build context, so a changed tree cannot resolve to an old image; the policy is never-pull, so nothing is fetched from anywhere; the image ID of every build is written to the run's evidence and `make verify-compat` compares it with what each workload is actually running (NFR-003, [data-model.md](./data-model.md) §26) | AD-05 |
| R-44 | The pinned allocation authority may not behave as the claim design assumes — it may not bind a claim for a **stated** value, may bind two, may not name the holder when it refuses, may not let a claim's labels be selected on, may allocate an arbitrary value rather than the lowest free one, may hand out a value below its index's `minID`, or may not free a deleted claim's value as the DELETE returns | None of it is assumed: gate item **G11** observes all of it — the six observations (a)–(f) of `contracts/kuid-claim-profiles.md` §6, the one list and the one count (AD-56), a second claim that binds and a refusal that names no holder being the two ways (b) fails — each with a negative control, before the provider relies on any of them. The allocation-order and `minID` ones are what the naming band of AD-33 rests on, the synchronous release is what the finalizer's release step rests on (AD-47), and the label one is what every claim-selector diff in this design rests on (SC-026, SC-045, SC-046). A failure of any is a G11 failure and takes FR-104's path — provisioning stops with the item named. Adoption is by correlation label, deterministic claim name **and** reported value, VNI and VLAN alike (AD-42), so a mislabelled claim is never adopted for a value it does not hold (FR-109) | AD-09, AD-32, AD-33, AD-42, AD-47 |
| R-45 | The provider's identity now reaches VLAN claims, and adopts by label — so a claim mislabelled with a service's correlation identifier, by the allocator or by anyone applying an object that copies another service's label, could be adopted and later released with that service | Adoption takes **three** things together (AD-32) — for a VNI claim exactly as for a VLAN claim, under the one naming scheme `<namespace>.<name>.<role>` (AD-42): the correlation label, the **deterministic claim name** derived from the object — so a spoof needs the right name as well as the right label — and a reported value the named entry actually carries — `spec.vlans[].vlan` or `spec.bridgeDomains[].vlan` for a VLAN, an attachment's VLAN never being matched on its own because none is ever allocated for an `ip-vrf` (AD-51), and `bridgeDomains[].l2vni` or `routers[].l3vni` for a VNI. A copied label alone adopts nothing, which is the case CHK033 raised. The provider holds no `create`, `update` or `patch` on VLAN claims, so it can release what it adopted and nothing more; `status.claimRefs` names every adopted claim, so the footprint is enumerable before and after; and no identity gains a verb to make this safe (FR-075, FR-109, SC-046) | AD-16, AD-32, AD-42 |
| R-46 | The `Fabric` no longer asserts route exchange, so a rendered fabric whose reflection is broken in some way the setting does not show would report `Ready` until the first spanning service arrives | The `Fabric`'s read-back includes `inter-as-vpn` **and** `route-reflector client` from every reflecting spine — a configuration-integrity check, not a behavioural one, since both are configuration leaves — read from the configuration datastore, 25.7.1 not mirroring them into state (AD-76) — and it is stated as such wherever it appears; the behavioural proof is G8 with its negative control on scratch configuration, then **T051's post-render probe on the rendered fabric** — scratch EVPN instances, the Type-3 route observed through the spines, removed and read back, reported under FR-108 and never an input to `Fabric.status`; the first `Network` spanning two leaves cannot report `Ready` without its own routes and names them when they are missing; P3's gate withdraws reflection declaratively — `Fabric.spec.overlay.reflectorClients: false` as decided in AD-77, rendered on both reflecting spines — and requires `RoutesMissing` within SC-044's bound before it restores it (AD-43); the `EvpnRoutesLost` alert covers a later loss, **guarded so that it cannot fire until one EVI is present on at least two leaves** (AD-48) — unguarded it would fire throughout the window AD-23 declares healthy, which is what T130 now builds. A fabric-wide count was never keyed evidence and could not have been satisfied before a service existed (FR-100, SC-004) | AD-23, AD-31, AD-76, AD-77 |
| R-47 | Removing the tier could delete the services it submitted, which an operator may not expect of a "tier" flag — the predecessor's purge left them alone, and each of them was created under two operator confirmations — and a finalizer blocked on an unreachable target could hang the removal | The removal **lists** the `Network`s and **refuses, non-zero and having deleted nothing, while any exist**: deleting them takes `--remove-services`, a word of its own, and the runbook says so (AD-35). With the flag the tier's request-accepting workloads are scaled down first, so nothing new lands and no audit event is written after the export — the list of what is deleted is taken after that scale-down, the scale-down precedes the export on every path past the refusal, and without the flag a non-empty list after it falls back to the refusal (AD-46); services applied with cluster tooling live in `agentic-netops-services` and are untouched either way; the wait is bounded (`TIER_PURGE_WAIT_SECONDS`, 300 s) and ends in a non-zero stop naming the `Network` and its target with the rest of the tier in place; the namespace goes only once a re-list returns empty; nothing is force-released; the audit record is exported first, so the removal never destroys the evidence of who asked for what (NFR-006, FR-103, FR-078) | AD-24, AD-26, AD-35, AD-46 |
| R-48 | Revertive mode may repair a drifted path before any `Deviation` object can be observed, so a drift test that asserts the artefact is flaky or never passes — and one that asserts nothing proves nothing | Gate item **G13** observes, on the pinned device-configuration release, what revertive mode leaves observable and for how long, and records it; the drift suite asserts only what G13 recorded — the deviation where one is observable, otherwise the restoration read back from device state with the injected value gone — and never an artefact that may be raced away. If G13 shows neither is observable the drift check is recorded unqualified and SC-007 is reported as not demonstrated, never waived (CR-007). The risk is SC-007's alone: SC-004's route-half negative control was exposed to the same race while it was a device-side edit, and is now a declarative fault that nothing reverts (AD-43) | AD-34, AD-43 |

## Complexity Tracking

**The Constitution Check has no FAIL rows, and this plan requests no exception.** What follows is
not a violation record; it is the two places where the design is deliberately more complex than the
obvious alternative, recorded so a reviewer can disagree with the reasoning rather than discover it.

| Complexity | Why it is taken | Simpler alternative rejected because |
|---|---|---|
| **A first-party fabric API and a first-party provider** (`fabric.agentic-netops.io/v1alpha1`, `agentic-netops-srl-provider`) instead of adopting the upstream fabric control plane, while still reusing the upstream device-configuration layer and allocation authority unchanged | RD-03, an operator decision. The four constructs need an API that can express a local bridge domain, an anycast gateway, explicit route targets and an access list; the platform needs structural schemas so the server-side dry-run in Principle III is a real gate rather than a formality; and FR-013 permits exactly one first-party group for fabric and service intent — the optional `MigrationPlan` group being the only other — precisely so that this does not multiply | The upstream fabric control plane has had no release in roughly 22 months, targets a device release two years older than the pin, does not compile against the pinned device-configuration release, and cannot express access lists, an anycast gateway, a local VLAN or explicit route targets. Adopting it plus a gap controller for the rest would create a **second translation path**, which FR-060 forbids by name and which is the defect the one-translator rule exists to prevent. Its SR Linux render templates are cited as a reference design instead |
| **Depending on an allocation authority that is dormant upstream** (KUID `kuid-server v0.0.13`) rather than allocating first-party from the start | It is the allocation contract the specification already describes — served `Index`/`Claim`/`Entry` APIs for IP, ASN, VLAN and VNI, with claims the tier can create and delete but never update — and FR-013 forbids introducing a duplicate allocation CRD alongside it. FR-062 is explicit that the platform requests identifiers and is **not** an allocation authority. The dormancy is carried as **R-31** with gate item G11 deciding it at P0. If G11 fails, provisioning stops; the named first-party fallback is adopted only by a recorded operator decision, lives in the first-party API group, and replaces the upstream authority rather than standing beside it (FR-104, CD-03). As decided (AD-74), G11 failed on the pinned kuid and that fallback is what runs on this lab; kuid stays the alternative the lock can select | Building the allocator first-party from the start would make the platform the allocation authority before any evidence says the upstream one fails, and would have to be designed, claimed against and tested twice if the upstream one turns out to work. The fallback costs nothing until it is needed because the claim semantics above it do not change — only the group and kind the adapter addresses — and the decision is made in the open, on the record, rather than silently at build time |

Two items — R-14 (transport client-CA verification) and R-31 (the allocation authority) — are
qualification gates rather than open questions: each has a chosen design, a stated fallback and a P0
check that decides between them before P1 is executed — for R-31 the deciding is the operator's and is
recorded (FR-104), never the script's. The remaining judgement calls the retarget made
where the evidence supported more than one answer are listed in [spec.md](./spec.md)
§Clarification candidates and are deliberately not re-decided here.
