# Feature Specification: Agentic NetOps on Nokia SR Linux — Composite Platform

**Feature Branch**: `004-agentic-netops-composite`

**Created**: 2026-09-20

**Status**: Draft

**Input**: Consolidate features 001, 002 and 003 into one specification describing the whole system
as a single feature, **and retarget it from SONiC to Nokia SR Linux**: a Kubernetes-native agentic
network-operations platform whose multi-agent intent tier turns natural language into declarative
datacenter-construct intent, reconciled over gNMI onto a containerlab SR Linux EVPN/VXLAN fabric and
observed end to end. **This is the only specification used for deployment.** Features 001–003 are
its history, not its siblings.

This document was produced in two passes. The first was a **merge, not a redesign**: every
requirement traced to a line in one of the three source specifications. The second is the **SR Linux
retarget**: every place the merge was bound to SONiC was resolved against evidence, the six
decisions the merge left open were made, and the six gaps it recorded were closed. Requirement
identifiers are stable across both passes — a requirement retired by the retarget keeps its number
and a one-line tombstone; a requirement the retarget adds takes the next free number (FR-097
onward). Every identifier's origin is in [traceability.md](./traceability.md); every SONiC
coupling's resolution is in [platform-coupling.md](./platform-coupling.md); the decisions and their
evidence are RD-01 to RD-15 in [research.md](./research.md) §11, backed by the reports under
[evidence/](./evidence/).

## Provenance

This specification consolidates three features. None was edited by this one, and this document is
additive. **The three source folders no longer sit beside it**: on 2026-09-20, after the retarget,
they were archived unmodified to `specs/.archive/001-003-sources-2026-09-20.tar.gz` and removed from
`specs/`, because this specification is the only one used for deployment. Every source citation in
this document, in [traceability.md](./traceability.md) and in `specs/README.md` — a source
identifier such as `001:FR-016`, a file and line such as `002/research.md:231`, or a row of a
`reconciliation-2026-09-19.md` sheet — resolves against that archive.

| Source | Title | Milestone | Branch | Created | Status at consolidation |
| --- | --- | --- | --- | --- | --- |
| 001 | Agentic NetOps SONiC EVPN/VXLAN Fabric | **M1 — declarative control plane** | `001-agentic-netops-sonic-evpn-fabric` | 2026-08-28 | Draft. Never formally closed; last approved phase `5a8eb118` (2026-08-29). Phase 8 rejected, no phase 9 gate |
| 002 | AGNTCY Intent Tier | **M2 — multi-agent intent tier** | `002-agntcy-intent-tier` | 2026-09-01 | Draft. Merged at `580ade19` (2026-09-03) with its acceptance record in dispute |
| 003 | Datacenter Service Constructs | **M3 — datacenter construct vocabulary** | `003-datacenter-service-constructs` | 2026-09-05 | Draft. Closed at `7d236e3a` (2026-09-06); two gates rest on fabricated evidence |

Milestone scopes are as `specs/README.md` derives them: M1 is the fabric, its resources and the
controllers that reconcile them; M2 is the conversational supervisor and three worker agents
above the M1 boundary, plus the chat surface and agent-tier observability; M3 is the four
datacenter constructs replacing the service-provider service names end to end, plus the access
list the tier did not have.

**The scope boundary between M1 and M2 is dissolved by this document.** M1 §"Non-goals — the
multi-agent intent tier" and M2 §"Relationship to feature 001" existed to describe that boundary.
They are recorded here as history and are **not** carried forward as live constraints. What does
survive the dissolution is the **dependency direction**: the intent tier depends on the control
plane and never the reverse, and the tier must remain removable with every control-plane gate
still passing. That is a real property of the system, not an artefact of two documents being
separate, and it is carried as **NFR-006** and **NFR-007**, measured by **SC-025**.

**The target platform changed after the merge.** The three sources specify a SONiC fabric. This
document specifies a Nokia SR Linux fabric and is written for a new, greenfield repository that
contains no implementation. Nothing in the sources' SONiC-specific design is carried as a live
constraint; what is carried is every platform-neutral requirement, the safety boundary intact, and
the lessons of the inherited acceptance record below.

M3 completes M2's operator-facing vocabulary and service catalogue. Where M2 and M3 disagree,
M3's form is the one this document carries; each such supersession is recorded in
[traceability.md](./traceability.md).

Identifiers are renumbered flat and continuous here. The three sources collide — `FR-001` exists
three times, `SC-001` three times, `T001` three times — so a bare number in any source is not
evidence of which specification it belongs to. Every composite identifier maps to its source, in
both directions, in [traceability.md](./traceability.md).

## Inherited acceptance record

Constitution Principle I — "The system MUST report only success it has observed" — governs how
this document reports on itself, not only what it describes. `specs/README.md` is explicit that a
registry repeating an approval without its contradiction is the failure Principle I names. This
composite therefore inherits the approvals **and** their contradictions together.

**These records describe the SONiC-era deployment in the predecessor repository, not this one.**
This repository contains no implementation, no cluster and no fabric; there is nothing here to
have passed or failed. The records travel with this document for one reason: each is a way a
platform of exactly this shape has already reported success it had not observed, and each is
answered below by a requirement that makes the same failure mechanically harder to repeat.

**Status is `Draft`.** All three sources say Draft. So does this one.

**No task is complete.** `specs/README.md`: "No `tasks.md` in this repository marks a single task
done: every checkbox in all three task lists is `[ ]` (001 T001–T091, 002 T001–T468,
003 T001–T088)." This specification's own [tasks.md](./tasks.md), generated on 2026-09-20, holds to
the same rule: every checkbox in it is `[ ]`, and none may be ticked without evidence captured by
the run that claims it (NFR-013).

**Three approval records are under dispute and travel with this document, and the retarget
research found a fourth contradiction:**

| Approval | What it asserts | Contradiction recorded against it |
| --- | --- | --- |
| M1 phases 1, 2, 3, 5 and 7 (`b749ec1f`, `3742d404`, `3eb8c775`, `41b6816c`, `5a8eb118`) | Pins immutable; a profile passed the EVPN+SRv6 gate; Kubenet/KUID/SDC healthy; SRv6 services converge; metrics healthy and alerts firing | 001 reconciliation sheet rows 77–80 and 82: `versions.lock.yaml:64-65` carries synthetic placeholder digests; the profile approved at phase 2 pinned an image that "ships no gNMI server at all"; the phase-3 manifests carried four placeholder digests and ImagePullBackOff; SRv6 was never conformant (gNMI Set blocked); Prometheus "held only scrape metadata; every Grafana panel 'No data'" and the alert rules never loaded |
| M2 phase 11 acceptance report (`docs/INTENT_TIER_ACCEPTANCE_REPORT.md`) | SC-003 and SC-004 passed; "Decision: Go"; the tier-absent gates verified in CI | 002 sheet rows 137–138: the SC-003 check is **inverted** — `agents/tests/simulation/report.py:191-193` asserts a refusal *ceiling* (`refusal_rate <= 0.5`) where the criterion demands 100% refusal; `report.py:294` hard-codes the SC-004 cell as the literal `"0.00%"`; and the CI job runs pins, register and unit tests only, so the "full gate run" was never performed |
| M3 GATE4 (T044a) and GATE8 (T082, T083, T088) | `Ready=True` across six objects; ACL rows present on both leaves; pins unchanged | 003 sheet rows 81 and 85–88: the T044a ASIC_DB proof is contradicted by the genuine capture of the same leaf taken in the same folder; four `.ready.json` files contradict genuine pretty-printed captures of the same objects showing `ApplyFailed`, `GCU exit 1` and `SchemaMismatch`; one of the six `Network` objects (`phase8-4e-acl-ingress`) **never existed** in the genuine capture; and the T088 pin proof lists digests (`sha256:1111…`–`6666…`) that appear in no commit, while the live files carry mutable `:latest` tags |
| M1 phase 3 (`3eb8c775`), restated: "Kubenet/KUID/SDC healthy" | The upstream fabric control plane, allocation authority and device-configuration layer were installed and healthy | Retarget research, [evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md) §0: the predecessor's install scripts fetch CRD paths that do not exist upstream and **silently fall back to hand-written look-alike CRDs in look-alike API groups** (`network.kubenet.dev`, `id.kuid.dev`, `sdc.sdcio.dev`); its lock file pins a device-configuration repository that returns 404; and the `Network` shape the whole data model rested on was a first-party invention presented as an upstream API. No upstream control plane ever ran |

**What each record becomes in this specification:**

| Failure recorded | Answered by |
|---|---|
| Placeholder and synthetic digests; mutable `:latest` images with no warning | NFR-003 (strengthened: every digest is resolved against its registry by the pin check; placeholder digests and mutable references are forbidden) |
| Gate proofs hand-authored or contradicted by genuine captures in the same folder; a hard-coded metric cell; an inverted success check | NFR-013 (evidence integrity: proofs are machine-captured by the run that claims them, and a check must be shown to fail on a stock fabric before its pass counts) and SC-040 |
| An applied-side check that passed on an empty fabric because it was switch-wide | FR-042 and FR-100 (every applied-side read is keyed to this service's own objects) |
| Look-alike CRDs standing in for upstream APIs | FR-013 and FR-098 |
| A specified southbound that never ran, replaced by a host-side executor | FR-014, FR-015 and FR-007 with no exception (RD-02) |

**What cannot be verified at all.** On 2026-09-19/20 the runtime was absent — there was no
`agentic-netops` Kind cluster and no containerlab fabric on the host — leaving **53 rows across
the three reconciliation sheets `unverifiable`**. Every statement this specification makes about
live behaviour therefore rests on evidence that could not be re-observed at consolidation time.
No claim in this document should be read as a report of observed success.

The three `reconciliation-2026-09-19.md` sheets are **evidence, not specification**. Their rows
are not folded into this document; they are cited only where a source claim and a recorded
finding disagree.

## Scope and interpretation

This specification describes the system **on Nokia SR Linux**. Every network device in the reference
lab is an SR Linux container launched by containerlab; every device change travels one path — a
first-party provider renders device configuration, the device-configuration layer validates and
applies it over gNMI, and readiness is set only from state read back off the device. How each
SONiC-specific coupling of the merged specification was resolved is recorded row by row in
[platform-coupling.md](./platform-coupling.md); the decisions are summarized in §Retarget decisions.

"Replace a vendor router with an SR Linux node" means replace its **logical role and supported
service intent** with an SR Linux leaf, border leaf or spine. It does not mean SR Linux runs on
arbitrary router hardware, nor that every WAN/MPLS feature has an EVPN equivalent. The system covers
a containerlab fabric and only the constructs and mappings listed here. The network operating system
is a vendor image, freely pullable for lab use; the **control plane is not**: the platform contains
no proprietary controller, no vendor fabric-automation product, no device package and no
vendor-specific orchestration dependency (FR-049).

**This document names components by role, not by product.** "The device-configuration layer", "the
allocation authority", "the metrics store", "the telemetry pipeline" and "the device metric
collector" are roles; which project fills each is a pinned choice, and the mapping is in
[plan.md](./plan.md) §Technical Context, where the compatibility set names all nine parts. The
requirements are written this way deliberately — a requirement that names a product cannot outlive it
— so a reader who wants the product names should read the two together, and no other file may
introduce a third name for the same role.

The operator vocabulary is closed at four datacenter constructs — `vlan`, `mac-vrf`, `ip-vrf`,
`acl`. Two of them, `mac-vrf` and `ip-vrf`, are the device's own names for its bridged and routed
network instances, and that alignment is a requirement (FR-099), not a coincidence. The
service-provider names the platform once advertised survive only as **input aliases** on the
migration path and as recorded provenance; they are never advertised as a type an operator can ask
for.

**Why named products appear in the requirements.** A requirement here may name the device
operating system, the topology tool, the cluster distribution or a telemetry component. That is not
an implementation detail leaking upward: this feature *is* one pinned reference lab, those artefacts
are its subject, and each is a member of the single qualified compatibility set (FR-017) that the
pin check resolves (NFR-003). A requirement names one only where the obligation is about that
artefact — the profile that must pass the capability gate, the layer that owns device transactions,
the store a metric must be readable from. Where an obligation is platform-neutral it is stated
neutrally, by role rather than by product, exactly as the merge left it; `platform-coupling.md`
classifies every such binding and says which class it belongs to.

Two words are reserved and never interchangeable. **Drift** is a deviation on a device path the
platform owns, detected by the device-configuration layer and repaired under FR-015. An
**out-of-band change** is an edit or a deletion made to a service intent object outside the intent
tier, detected and reported but never reverted (FR-105). Neither term is ever used for the other.

**SRv6 is out of scope for this feature.** No licence-free SR Linux container type can originate or
terminate an SRv6 service, and no SR Linux release models the explicit segment lists, steering
policy or per-SID counters the merged specification required (RD-04). The affected identifiers are
retired with tombstones and listed in §Deferred scope.

## Clarifications

### Session 2026-09-20

- Q: Which way do access-list rule priorities run — the device's direction, the predecessor's, or no operator-visible numbers at all? → A: Ascending priority number, first match wins, rendered unchanged as the device's entry sequence number (FR-039 as written; the predecessor's "higher number wins" is not preserved and no inversion is applied on render).
- Q: How is the requesting principal that FR-078 and SC-030 depend on established on the chat and programmatic surfaces? → A: Both surfaces require a login against operator credentials generated into a Kubernetes Secret at provisioning; the principal is the authenticated username; anonymous requests are refused before they reach the pipeline.
- Q: What is the finalization policy when a service is deleted while one of its devices is unreachable? → A: The finalizer blocks indefinitely with a condition naming the unreachable target and keeps the allocations claimed; removal completes on its own when the target returns; the only exit is an explicit, documented operator force-release that is recorded durably. No timer ever releases an identifier.
- Q: What happens if the dormant upstream allocation authority fails its capability-gate item, and where may the named fallback live? → A: The failure stops provisioning with the failing item named; the fallback is adopted only by a recorded operator decision; it is a first-party allocator whose claim kinds live in the first-party API group, never in the upstream project's group; the upstream authority is then not installed, so the two never coexist.
- Q: What does the intent tier do when a service it created is later modified or deleted directly with cluster tooling, and does SC-030 count that as an unconfirmed change? → A: Detect and report, never revert — the tier stamps a hash of the spec it submitted, re-reads the object on every status or remove request and says plainly when it was changed or deleted outside the tier; it never reverts, re-creates or overwrites. SC-030 covers tier-originated changes; out-of-band changes are counted and reported separately, not as violations.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Launch and verify a reproducible lab (Priority: P1)

A developer launches all network nodes from one pinned containerlab topology: two SR Linux spines,
two SR Linux leaves and two Linux endpoints, one behind each leaf. The fabric forms a dual-stack
routed underlay and a BGP EVPN control plane; the leaves terminate VXLAN tenant services. A Kind
cluster hosts the complete control and observability plane. No hypervisor, nested virtualization
or device licence is required.

**Why this priority**: nothing else in this specification is demonstrable without it.

**Independent Test**: deploy the topology from a clean host, pass the capability gate — whose own
scratch L2 and L3 instances are what prove Type 2, 3 and 5 exchange without any other story —
converge the default fabric, and prove underlay and EVPN session state with the EVPN family
negotiated on every overlay session and the reflecting spines' reflection setting read back from
the device's configuration datastore — a configuration-integrity check, as decided (AD-76), since the
pinned image does not mirror those leaves into state. A fabric that carries no service yet has no EVPN route to exchange: route exchange
through the *rendered* fabric is proven by the first service that spans both leaves, in User Story
2. Cross-leaf connectivity and routed-instance isolation of *provisioned*
constructs are proven by User Story 2, which owns the service reconciler.

**Acceptance Scenarios**:

1. **Given** the pinned topology and image digest, **When** containerlab deploys, **Then** all
   six nodes start, management addresses are reachable, and every SR Linux node is a managed
   device target.
2. **Given** the default fabric intent, **When** reconciliation converges, **Then** routed
   leaf-spine links are up and **every node's allocated system loopback is present and active in
   every other node's route table**, all underlay and EVPN sessions establish with the EVPN family
   negotiated — read from the family's own operational state per neighbour, not inferred from the
   session — **the reflecting spines' reflection settings are read back as declared** — `route-reflector
   client` enabled by default (`Fabric.spec.overlay.reflectorClients`) and `inter-as-vpn` equal to
   what the fabric declares (AD-77) — a configuration-integrity check, read from the configuration
   datastore because the pinned image does not mirror those leaves into state (AD-76), with the
   capability gate (G8) and the post-render probe having shown on this image that routes are
   exchanged with `route-reflector client` and are not without it (AD-77) — spines do not terminate tenant VXLAN,
   and leaves use their system loopback as the VTEP source. No EVPN route count is asserted here:
   none exists until a service does (FR-100).
3. **Given** an image that lacks a required gNMI capability, YANG path, platform feature or EVPN
   behaviour, **When** capability qualification runs, **Then** the suite fails early and names the
   missing capability; it never weakens or skips an acceptance check.
4. **Given** a clean qualified host, **When** the operator runs the provisioning script, **Then**
   it idempotently creates the named Kind cluster, the shared management network, the
   containerlab topology and every platform application in dependency order, refusing up front if
   the management address space overlaps an existing network.
5. **Given** a running or partially running lab, **When** the operator runs the shutdown script,
   **Then** it captures requested evidence and idempotently removes containerlab, the Kind
   cluster, generated secrets and owned Docker networks without deleting pinned images or
   unrelated resources.

---

### User Story 2 - Reconcile the fabric declaratively (Priority: P1)

An operator manages the fabric design and its services through Kubernetes resources. The
allocation authority issues every shared identifier; a single first-party provider renders
validated SR Linux configuration for each device; the device-configuration layer applies it over
gNMI and continuously reconciles it.

**Why this priority**: this replaces proprietary orchestration and establishes one observable,
idempotent source-of-truth workflow.

**Independent Test**: apply the same intent twice, update one attachment, introduce drift on a
managed path, and delete the service. Reconciliation stays idempotent, changes only owned
configuration, restores drift under the revertive drift policy, and removes owned configuration
cleanly.

**Acceptance Scenarios**:

1. **Given** ready allocations, schemas and targets, **When** a fabric design or a service intent
   object is applied, **Then** the provider deterministically creates one configuration resource
   per affected device and reports `Rendered`, `Validated`, `Applied` and `Ready`.
2. **Given** the same generation reconciled repeatedly, **When** no desired state changes,
   **Then** no configuration churn or identifier reallocation occurs.
3. **Given** an unreachable target or a rejected path, **When** application fails, **Then** the
   owning resource becomes `Degraded`, exposes the per-device error, and never reports a false
   `Ready`.
4. **Given** manual drift on an owned path, **When** the deviation is detected, **Then** the
   desired value is restored under the revertive drift policy, and the deviation is recorded in
   whatever form gate item G13 observed that policy to leave visible.
5. **Given** deletion, **When** finalization runs, **Then** only configuration and allocations
   owned by that intent are released; shared fabric configuration remains intact.

---

### User Story 3 - *Retired: end-to-end SRv6 service*

*Retired by the SR Linux retarget (RD-04) and deferred to a future feature. No licence-free SR Linux
container type can originate or terminate an SRv6 service, and no SR Linux release models explicit
segment lists, steering policy or per-SID counters, so the story's capture-proven ordered-SID
acceptance is unsatisfiable on any profile this lab can pin. The number is kept so that
[traceability.md](./traceability.md) and every earlier reference stay resolvable. See §Deferred
scope and [evidence/04-srv6.md](./evidence/04-srv6.md).*

---

### User Story 4 - Ask for a construct by its datacenter name (Priority: P1)

An operator who knows this fabric describes what they want in the vocabulary the fabric's own
documentation uses — "extend vlan 100 as a mac-vrf across leaf01 and leaf02 for tenant acme",
"give tenant acme an ip-vrf carrying 10.10.0.0/24 on leaf01 ethernet-1/1 vlan 200" — typed in plain language
into a chat surface. The system interprets it, proposes concrete fabric parameters for review,
and on explicit confirmation creates the service, reporting when it is actually Ready. No mental
translation into service-provider names is required at any point, and nothing the operator is
shown uses a retired name.

**Why this priority**: this is the platform's entire reason for existing. Every other story
supports, guards or observes it.

**Independent Test**: submit one prompt per construct naming only datacenter terms and the
required variables. Assert each reaches a converged service, that the resulting fabric resources
match what an equivalent hand-authored request produces, and that no operator-visible artifact
presents a retired service name as a type the operator asked for or could ask for. A retired name
shown as recorded provenance on a service that arrived in that vocabulary is not a failure.

**Acceptance Scenarios**:

1. **Given** a healthy fabric and a plain-language request naming a construct, two endpoints and
   a tenant, **When** it is submitted, **Then** the system returns a structured interpretation
   naming construct, tenant, endpoints and a generated service identifier, and asks for
   confirmation before changing anything.
2. **Given** a returned interpretation, **When** the operator confirms it, **Then** the system
   assigns the concrete fabric resources — the allocated overlay identifiers and attachment VLANs,
   and the import/export route targets derived from them — and presents the complete proposed
   service for a second explicit confirmation.
3. **Given** a confirmed assignment, **When** the operator approves deployment, **Then** exactly
   one declarative service resource is submitted and the system reports progress until it reports
   Ready or a terminal failure.
4. **Given** a request for a `mac-vrf` on vlan 100 across both leaves, **When** it converges,
   **Then** one L2VNI is allocated, VLAN 100 is carried as named and claims nothing, and both
   attachments land in the same bridge domain — on the device, one `mac-vrf` network instance per leaf carrying that VNI.
5. **Given** a request for a `vlan` on one attachment with no mention of extending it, **Then**
   a local bridge domain is provisioned on that node only and no VNI or route targets are
   allocated.
6. **Given** a construct written with different casing or punctuation (`IP-VRF`, `ip_vrf`,
   `MAC VRF`), **Then** the same construct resolves rather than an unknown-service error.
7. **Given** a construct named with a variable that construct does not have (an L2VNI on a
   `vlan`, a gateway on an `ip-vrf`), **Then** the request is refused before anything is created,
   naming both the offending property and the construct that does carry it.
8. **Given** a request the fabric cannot express (a transport-engineering or pseudowire-OAM
   construct), **When** it is interpreted, **Then** the specific unsupported properties are
   named, no assignment is proposed, and nothing is submitted.
9. **Given** an ambiguous request missing a required detail, **When** it is interpreted, **Then**
   the system asks for exactly the missing detail rather than inventing a value or failing.

---

### User Story 5 - Filter a service with an access list (Priority: P1)

An operator needs traffic on a service constrained — "permit tcp 443 from 10.0.0.0/24, deny
everything else" — either as a filter attached to a service provisioned in the same request, or
as a standalone access list bound to named ports of a service that already exists. The tier accepts
the rules, validates them, renders them onto the fabric and verifies they are programmed.

**Why this priority**: without it the construct set is not holistic and only three quarters of the
cited device references are covered.

**Independent Test**: submit a prompt asking for a service with an access list, and a prompt
asking for a standalone access list on named ports. Assert the rules are programmed on the fabric
with the intended actions and in the intended order, that a malformed rule set is refused with the
offending rule named, and that a deny rule demonstrably drops a probe a permit rule passes.

**Acceptance Scenarios**:

1. **Given** a request for any construct that also states filter rules, **When** it is
   provisioned, **Then** the service converges **and** the access list is bound to that service's
   own attachment subinterfaces.
2. **Given** a request for a standalone access list naming ports, and those ports already carry an
   attachment of an existing service, **When** it is provisioned, **Then** the list is bound to
   those attachments' subinterfaces and no overlay identifiers are allocated.
3. **Given** a rule set where two rules share one priority, **Then** the request is refused
   naming the colliding rules, because which of a permit and a deny wins must never be decided
   arbitrarily.
4. **Given** a rule whose prefix is in a different address family than the list it belongs to,
   **Then** it is refused naming the rule, rather than rendering a rule that can never match.
5. **Given** an access list that declares a default action, **Then** unmatched traffic on the
   bound attachments is treated as the operator declared. **Given** one that declares none,
   **Then** the confirmation states plainly that unmatched traffic is accepted by the platform's
   own default, so the operator never learns it from the fabric.
6. **Given** a request that would bind a list to an attachment another service already bound one
   to in the same direction and address family, **Then** it is refused before anything is created,
   naming the service that holds the binding.
7. **Given** a standalone access list naming a port and VLAN that no service has attached, **Then**
   it is refused before anything is created, naming the missing attachment — an access list never
   creates the interface it filters.
8. **Given** any proposed access list, **When** the interpretation is shown for confirmation,
   **Then** it states the evaluation order in words: rules are evaluated in ascending priority
   number and the first match wins.

---

### User Story 6 - Refuse to bypass the declarative control plane (Priority: P1)

An operator, or a misbehaving agent, attempts to make the intent tier act directly on a device —
by asking it to "just SSH in and fix leaf01", by requesting a configuration push, or through a
prompt that tries to redirect the deployer. The system declines and the fabric is unchanged.

**Why this priority**: this is the guardrail that makes the intent tier safe to have at all. It
must hold from the first line of code, not be retrofitted.

**Independent Test**: submit a corpus of direct-action requests and injection attempts. Verify
zero device sessions are opened, zero configuration paths are written outside the reconciliation
path, and every attempt is refused with an explanation. Verify that neither of the tier's two
cluster identities can express the forbidden action even if an agent tried.

**Acceptance Scenarios**:

1. **Given** any request to configure, log into, or run a command on a device, **When** it is
   processed, **Then** the system declines, explains that changes flow through declarative
   intent, and offers the equivalent supported request.
2. **Given** an instruction embedded in user-supplied text that attempts to redirect an agent,
   **When** it is processed, **Then** it is treated as data and not as instruction, and the
   resulting proposal is unchanged from the same request without the injected text.
3. **Given** the intent tier's cluster identity, **When** its permissions are enumerated,
   **Then** its two identities can act only on the service intent resources in the intent namespace
   (the deployer: create, read, update, patch and delete) and on allocation claims in the allocation
   namespace (the allocator agent: create, read and delete, never update or patch), and neither can read
   device credentials, modify controller-owned resources, or reach the device management network.
4. **Given** an agent that returns a malformed or out-of-contract payload, **When** the next
   stage receives it, **Then** the payload is rejected against a schema before any cluster
   submission, and the failure is reported rather than partially applied.

---

### User Story 7 - Run the intent tier beside the control plane (Priority: P1)

A person who did not build the system — or a fresh agent session that has not read the implementation, run under the operator's delegation (operator decision 2026-09-27) — brings up the whole stack — fabric plus intent tier — on a
clean host, and can tell within minutes whether each agent is healthy and reachable.

**Why this priority**: the tier is worthless if it cannot be deployed and diagnosed alongside the
existing lab.

**Independent Test**: from a clean host, run the documented bring-up. Verify every agent reports
healthy, the transport is established, each worker is discoverable, and the tier's removal refuses
while the services it submitted are still there and — asked in the same command to remove them —
leaves no orphaned workload and no claimed identifier.

**Acceptance Scenarios**:

1. **Given** a clean host and the documented prerequisites, **When** the bring-up runs, **Then**
   the intent tier starts alongside the fabric workloads and every agent reports healthy without
   manual intervention.
2. **Given** a running tier, **When** a health check is requested, **Then** it distinguishes "the
   process is alive" from "the transport is established and every worker answered", and names
   which worker failed when one does.
3. **Given** one worker stopped, **When** a request needing that worker arrives, **Then** the
   supervisor reports the specific unavailable capability, leaves the conversation resumable, and
   submits no partial service.
4. The tier's removal, in two parts. *(Split into 4a and 4b by the fifth analysis pass of
   2026-09-21, AD-46: the one scenario carried two outcomes and a test could assert neither. The
   number is kept, so no later scenario is renumbered.)*
   - **4a.** **Given** a running tier and services it submitted still present, **When** the tier's
     removal is run **without** asking for their removal, **Then** it stops non-zero naming each of
     those services and the two documented continuations, having changed nothing: no service is
     deleted, no tier workload is scaled down or stopped, no audit export runs, and every one of
     those services is still present and still ready (NFR-006).
   - **4b.** **Given** the same tier with every target reachable, **When** the removal is run
     **asking for their removal in the same command**, **Then**, in this order (NFR-006, AD-72),
     the tier's request-accepting workloads are scaled down, the services the tier submitted are
     listed, the audit record is exported — before its store is removed (FR-078) — and those
     services are removed through ordinary finalization within a bounded wait; then all tier
     workloads stop, no workload and no claimed identifier is left — none
     for a submitted service and none for an in-flight request — and the control plane — its
     controllers, the fabric design and every service it still holds — is unaffected (NFR-006). A
     teardown that destroys the whole environment needs no such request and still exports the audit
     record first.

---

### User Story 8 - Get a gateway without asking for a different service (Priority: P2)

An operator who wants a subnet bridged across the fabric *and* routed asks for a `mac-vrf` with
an anycast gateway. They do not learn a fifth service name for the combination; the gateway is a
property of the L2 construct, pointing into the routed one.

**Why this priority**: expressing this as composition rather than a fifth type is what makes the
construct set closed and holistic, but the capability itself already exists.

**Independent Test**: submit a prompt asking for a `mac-vrf` with a gateway address; assert the
service converges with both the bridge domain and the routed instance, and that the operator was
never asked to name a separate service type.

**Acceptance Scenarios**:

1. **Given** a request for a `mac-vrf` with a gateway address, **When** it is provisioned,
   **Then** both the bridge domain and the routed instance converge and the gateway is reachable
   from the attached ports.
2. **Given** a gateway naming only one address family, **Then** only that family is configured —
   an unrequested family is never added.
3. **Given** a `mac-vrf` with no gateway, **Then** no routed instance is created and no L3
   identifier is allocated.

---

### User Story 9 - Brownfield intents keep being accepted (Priority: P2)

A migration source that still describes its services in the retired service-provider vocabulary
continues to be accepted and translated. The service it produces is named and reported as a
datacenter construct, and the record says which source vocabulary it arrived in. Unmapped source
properties are rejected before any device is touched.

**Why this priority**: the migration path is an existing working capability whose whole purpose is
reading brownfield definitions. Regressing it would trade one working thing for another.

**Independent Test**: submit the existing service-provider-shaped inputs unchanged; assert each
still validates, translates and converges to the same fabric outcome, that the resulting service
reports a datacenter construct as its type, and that an unmapped source property rejects the
whole translation before any downstream resource is created.

**Acceptance Scenarios**:

1. **Given** an input in the retired vocabulary, **When** it is translated, **Then** it produces
   the same fabric outcome it did before the vocabulary changed.
2. **Given** such an input, **When** the resulting service is inspected, **Then** its type is the
   datacenter construct and its provenance records the vocabulary it arrived in.
3. **Given** a service that converged before the vocabulary changed and whose stored record names
   a retired type, **When** it is listed or inspected, **Then** it is reported by its construct
   and its stored record is left untouched.
4. **Given** such an input relying on a constraint specific to its source vocabulary, **Then**
   that constraint is still enforced for that input, and is **not** imposed on a request that
   names the construct directly.
5. **Given** a transport-engineering, pseudowire-OAM, multicast or unmapped-QoS property, **When**
   it is validated, **Then** the exact unsupported fields are reported and no downstream intent or
   device configuration resource is created.

---

### User Story 10 - Converse through an operator chat surface (Priority: P2)

An operator uses a browser chat interface rather than an API client: they see the conversation,
the proposed interpretation, the assigned resources, the confirmation prompts, and live progress
as the service converges.

**Why this priority**: the chat surface is how the capability is demonstrated, but the stories
above are fully testable through the programmatic surface without it.

**Independent Test**: drive one complete supported request end to end through the browser only.
Verify each stage renders, both confirmations are refusable, refusal cancels cleanly, and a
failure surfaces a readable reason rather than a stack trace.

**Acceptance Scenarios**:

1. **Given** the chat surface, **When** an operator submits a request, **Then** the
   interpretation, assignment and deployment stages are each shown as distinct, labelled steps
   with their structured payloads readable.
2. **Given** a confirmation prompt, **When** the operator declines, **Then** the workflow stops,
   nothing is submitted, any provisionally claimed identifier is released, and the operator can
   amend the request and continue in the same conversation.
3. **Given** a service being deployed, **When** its resource changes state, **Then** the surface
   reflects progress toward Ready without a manual reload.
4. **Given** any stage failure, **When** it occurs, **Then** the surface shows which stage failed
   and why, in operator-readable terms, with a correlation identifier usable to find the trace.

---

### User Story 11 - Observe control and data-plane health (Priority: P2)

An operator uses dashboards backed by the metrics store to see device interface, BGP and EVPN
health alongside orchestration and reconciliation health. A common collection and processing path
carries controller metrics and traces.

**Why this priority**: Principle I is only enforceable if the evidence for a health claim is
collectable and visible.

**Independent Test**: break one leaf-spine link and force one failed reconciliation. Relevant
metrics appear in the metrics store, dashboards remain queryable, and alerts identify both
failures.

**Acceptance Scenarios**:

1. **Given** device gNMI subscriptions, **When** devices publish state, **Then** the in-cluster
   collector exports metrics through the pipeline to the metrics store without a duplicate
   subscription series for the same target and path.
2. **Given** instrumented controllers, **When** reconciliation occurs, **Then** latency, result,
   retry, queue and error metrics are scrapeable and traces carry resource identity.
3. **Given** stored metrics and generated topology metadata, **When** the dashboards start,
   **Then** provisioned topology and service-path views show link state and utilization, traffic
   direction, BGP/EVPN and VXLAN tunnel state, configuration and deviation state, and pipeline
   failures.
4. **Given** telemetry collection is unavailable, **When** reconciliation continues, **Then**
   configuration is not blocked, observability status is degraded, and buffered or dropped data is
   visible after recovery; where the device metric collector itself is unavailable, the read-back
   whose applied side it supplies (AD-82 `2026-09-21-state-source`, FR-100) reports `Ready=Unknown`
   with the reason `VerificationFailed`, never a stale or absent value.

---

### User Story 12 - Observe and explain what the agents did (Priority: P2)

After a request, an operator or reviewer reconstructs exactly what happened: which agent handled
each stage, what each produced, how long each took, which model was consulted, where the time
went, and how the resulting resource behaved.

**Why this priority**: multi-agent systems are opaque by default, and this tier sits directly
upstream of fabric changes. Attribution is required for trust and for debugging.

**Independent Test**: run one successful and one deliberately failing request. Verify each is
recoverable as a single correlated trace spanning all stages, that agent-tier telemetry joins the
fabric telemetry on a shared correlation identifier, and that the failing run identifies the
responsible stage.

**Acceptance Scenarios**:

1. **Given** a completed request, **When** its trace is retrieved, **Then** it is a single
   correlated record covering interpretation, assignment, submission and convergence, with
   per-stage timing and outcome.
2. **Given** a request that produced a fabric resource, **When** the trace is inspected, **Then**
   it carries a correlation identifier that also appears on the resulting resource, letting a
   reviewer join agent activity to reconciliation and device telemetry.
3. **Given** a period of activity, **When** tier metrics are queried, **Then** request volume,
   per-stage success rate and latency, confirmation and refusal counts, refused-unsafe-request
   counts, and model-call cost or token usage are all available.
4. **Given** a failed request, **When** its trace is inspected, **Then** the failing stage, the
   payload that failed validation, and the error are identifiable without reading process logs.
5. **Given** telemetry from the fabric and the tier, **When** an operator investigates one
   service, **Then** both are reachable from a single view without manual correlation by
   timestamp.

---

### User Story 13 - One vocabulary everywhere (Priority: P3)

Everything an operator reads about provisioning — the guided prompts and examples the chat
surface offers, the refusal and clarification messages, the tutorial, the operations and
reference documentation — uses the construct names and nothing else. An operator cannot learn the
retired vocabulary from this system.

**Why this priority**: documentation drift is what re-teaches the wrong vocabulary. It ranks last
only because it depends on the other stories being settled.

**Independent Test**: search every operator-facing surface for the retired service names; assert
the only occurrences are in explicit migration or provenance contexts that say so.

**Acceptance Scenarios**:

1. **Given** the chat surface's suggested prompts, **Then** every example names a construct.
2. **Given** a request the tier cannot satisfy, **Then** the refusal offers the nearest construct
   by its construct name.
3. **Given** the provisioning documentation, **Then** it documents the four constructs, their
   variables, what each renders on the fabric, and the migration aliases as aliases.

---

### Edge Cases

**Fabric, allocation and reconciliation**

- Allocation collision or exhaustion for an IP, ASN, VLAN or VNI; a VNI outside the range the
  device's EVPN instance identifier can carry.
- Topology changes after service allocation, including removed or renamed interfaces: the affected
  service goes `Ready=False` naming the attachment that no longer resolves, its allocations stay
  claimed, and nothing is re-allocated or silently moved to another port.
- A service references an endpoint, target, schema or secret that is absent or not ready.
- The device accepts a configuration into its running datastore but never programs it — visible
  only as the absence of the corresponding state, which is why readiness reads state (FR-100).
- Every underlay and overlay session is established and no EVPN route is exchanged, because a
  route-reflecting spine that is not itself a tunnel endpoint drops the routes it should reflect —
  on the pinned image, as decided (AD-77), a spine whose overlay group lacks `route-reflector
  client` (`reflectorClients: false`); removing `inter-as-vpn` was observed not to stop reflection.
  Caught four times over: by the capability gate on scratch configuration, by the fabric design's
  read-back of the spines' reflection settings — which shows they are applied, not that reflection
  works — by the post-render probe on the rendered fabric, and by the first service spanning two
  leaves, which reports `Ready=False` naming the routes it lacks (FR-100). A fabric with no service on it has no
  EVPN route to exchange, and that alone is never the failure.
- The device-configuration layer and the device metric collector together exhaust the device's
  management session limit.
- One target succeeds and another fails; aggregate status must remain degraded and identify both.
- An operator edits an owned path versus an unrelated unmanaged path.
- The provider restarts between render and transaction confirmation.
- A scheduled re-verification cannot run because the target is unreachable or the read times out:
  the object reports `Ready=Unknown` and `Degraded`, both with the reason `VerificationFailed` and
  the target named, at that pass; the last-verified time does not advance; `Ready` is never set
  False, so no invariant is declared lost, and never left True, so no earlier pass is remembered as
  a current one. The next pass that runs settles it either way (FR-107).
- The re-verification schedule stops advancing while the provider stays up: the last-verified time
  ages past one re-verification interval plus one reconciliation interval and raises its alert,
  because a `Ready=True` nobody re-read is not evidence (FR-107, FR-087).
- The pinned upstream allocation authority fails its capability-gate item: provisioning stops
  non-zero naming the item, nothing above the authority is installed, and no flag selects another —
  the only way on is a recorded operator decision adopting the first-party substitute (FR-104).
- Verification tooling is interrupted after writing scratch configuration or a declared injected
  fault and before removing it: the leftover is named or labelled, the next gate or acceptance run
  refuses to start while it is present on any node, and it is never assumed to have been cleaned up
  (FR-108).
- A service intent object is deleted in the window between its creation and the provider's first
  reconcile, so before the provider could place its finalizer: an object the intent tier submitted
  carries the finalizer from the moment it is applied and therefore still blocks — and because a
  finalizer releases nothing by itself, finalization first adopts, by the same three-part rule, the
  claims the object never had the chance to record, and only then releases them, so nothing is
  orphaned; an object applied with cluster tooling and then deleted before the provider's first
  reconcile — the provider slow, or gone down after the apply was admitted — is deleted outright,
  and the identifiers it named — which the operator chose, not the authority — are left to the
  operator. It cannot have been *applied* while the provider was down: admission fails closed, so
  that apply is refused, and only the deletion, which is not intercepted, goes through (FR-109,
  FR-034).
- A service intent object applied with cluster tooling names a VNI the allocation authority has
  already bound to another service, or one outside the allocation band: `Accepted=False` names the
  value and the holder or the band, nothing is rendered, and no other value is chosen (FR-109).
- VXLAN overhead causes traffic loss despite control-plane convergence; an endpoint left at an
  MTU above the tenant MTU black-holes TCP while ping succeeds.
- Deletion occurs while a target is unreachable: finalization blocks with the target named, the
  object reports `Ready=False` with the reason `Deleting` from the moment finalization starts —
  never `Ready=True` and never `Ready=Unknown` (AD-53) — allocations stay claimed, removal completes when the target returns, and the only other exit is
  the documented operator force-release — never a timer (FR-103).

**Constructs and access lists**

- An operator names a construct the tier does not have: the refusal lists the constructs that do
  exist.
- An operator asks for two constructs in one message: the tier says plainly that it handles one
  construct per request, names both it read, provisions neither and claims nothing until the
  operator sends one — never silently drops one. An interpretation carries one construct (FR-058);
  a gateway (FR-032) or an access list stated with a service (FR-036) is a property of that one
  construct and is not a second one.
- A construct named with the right variables but the fabric has no such node or port: refused
  before anything is created, with the valid names listed.
- A `vlan` asked for on a VLAN id outside the band an operator may name from: refused with **both
  bands stated** — `100–999` to name from, `1000–4000` the allocation authority's, and nothing
  outside `100–4000` at all — at interpretation, before anything is claimed (FR-062).
- A standalone `acl` is asked for on a subinterface whose VLAN the authority allocated, so the VLAN
  the request names lies in `1000–4000`: accepted on both paths. That VLAN is a reference to a
  subinterface another service created, not a VLAN of the `acl`'s own, so the naming band does not
  refuse it and no claim is looked for behind it; it must still resolve to a subinterface that
  exists (FR-062, FR-109, FR-037).
- A service intent object applied with cluster tooling carries a VLAN in the allocation band
  `1000–4000` that no adoptable claim backs: `Accepted=False/AllocationConflict` names the VLAN and
  both bands, and nothing is rendered. The object cannot say whether its VLAN was named or
  allocated, so the band decides (FR-109).
- An attachment carrying a VLAN in the allocation band **that the object does not already carry**
  is **added** to an accepted service intent object: refused as immutable in effect, naming the VLAN
  and both bands — its claims are fixed and nothing would claim the new value; an attachment
  carrying a VLAN in the naming band, or none, may still be added, and so may one carrying the
  allocated VLAN the service already has — a `mac-vrf` whose VLAN was allocated gains a port on
  that same VLAN, whose claim is already adopted (FR-109).
- An attachment whose allocated VLAN backs an adopted claim is **removed** from an accepted service
  — a `vlan` or a `mac-vrf`, the only constructs whose VLAN is ever allocated:
  the claim stays adopted, held and listed in status until finalization; nothing is released early
  and no reconcile un-adopts it (FR-109, FR-103).
- An `ip-vrf` is asked for with an attachment that names no VLAN: it is the untagged subinterface,
  and no VLAN is allocated for it — an `ip-vrf` attachment's VLAN is named or absent. One applied
  with cluster tooling carrying an attachment VLAN in `1000–4000` is
  `Accepted=False/AllocationConflict` naming the VLAN and both bands: no claim could back it
  (FR-109, FR-062).
- The allocation authority errors or cannot be reached while the provider resolves a service's
  claims, or while it finalizes one: not "nothing adoptable", and not an allocation conflict. The
  object waits and the pass is retried with backoff; a deleting object keeps its finalizer and
  every claim, and removal completes unaided when the authority answers (FR-109, FR-103).
- Two services asking for the same node, port and VLAN: refused before anything is created, naming
  the service that holds the attachment.
- The allocation authority hands the tier a VLAN another service already attached **by name** on
  the requested port: **this cannot occur.** The band an operator may name from (`100–999`) and the
  band the authority allocates from (`1000–4000`) are disjoint, so no allocated value is ever a
  value someone was allowed to name. The one-owner rule still refuses two services asking for the
  same (node, port, VLAN) — the case above — but in such a conflict both VLANs are named ones
  (FR-062).
- A VNI, or the VLAN of a `vlan` or `mac-vrf`, is edited on a service intent object that was already
  accepted: refused by the API as immutable, naming the field. Changing an allocated identifier is
  a removal and a new service, so no claim is ever superseded while its service lives (FR-109).
- A `mac-vrf` whose endpoints name different VLANs: refused — one bridge domain is one broadcast
  domain.
- Two attachments that need conflicting tagging modes on one port — one untagged, one tagged,
  whether in one service or two: refused before anything is created, naming the port and both
  services, because tagging is a property of the port and not of the attachment (FR-034).
  *Amended by AD-68*: the port's mode is declared in the fabric design's site inventory, so an
  attachment asking for the other mode is refused first, listing the ports declared in the mode it
  asked for; the two-service refusal is the backstop across a change of that declaration.
- An access list bound to an attachment that already carries one from another service in the same
  direction and address family: refused before anything is created, naming the service that holds
  the binding. Nothing is displaced, and no filter is created whose effective behaviour the tier
  cannot state. An IPv4 and an IPv6 list on one attachment do not conflict.
- A standalone access list naming an attachment no service has created: refused, naming it.
- A service being removed while another service's standalone access list is still bound to its
  attachment: finalization waits and names the holder rather than leaving a dangling binding.
- An access list named with a name the device reserves for its own filters: refused by name.
- An egress access list requested on a profile whose egress filtering was not qualified: refused
  at interpretation naming the unqualified property (FR-097).
- An access list naming a port range or protocol the fabric cannot match: refused with the
  property named.
- An access list with no rules, or with rules but no binding points: refused with the missing part
  named.
- A legacy-vocabulary input whose source-specific constraint is violated: still refused on that
  constraint, not silently relaxed by the rename.

**Intent tier**

- A request names an endpoint, node or interface that does not exist in the topology.
- A request is confirmed, then the topology changes before submission completes: the server-side
  dry-run refuses the attachment that no longer resolves, nothing is submitted, every provisional
  claim is released, and the refusal lists the valid names.
- The model provider is unreachable, rate-limits, or times out mid-pipeline.
- A model gateway is declared with no base URL, or a running agent's Secret loses the one it had:
  provisioning refuses before any tier workload is created, and a running agent stops calling the
  model and names the missing base URL rather than falling back to the library's default endpoint
  (FR-106).
- The model returns text that is not valid against the stage's output schema, repeatedly.
- The model returns a confident but wrong interpretation that passes schema validation — caught
  only by the operator at a confirmation point.
- A worker is reachable but returns an out-of-contract payload.
- Two concurrent conversations request overlapping identifiers or the same service name: the
  allocation authority arbitrates, so exactly one conversation holds the value and the other fails
  with the conflicting value named (FR-062); a second service under an existing name is refused,
  reporting that the earlier service exists (FR-063).
- The same request is submitted twice, or resubmitted after a supervisor restart.
- The supervisor restarts mid-request, with an assignment confirmed but not yet submitted.
- A resource is submitted successfully but never reaches Ready.
- Submission partially succeeds across multiple resources.
- An operator declines after identifiers have been provisionally claimed.
- User-supplied text contains an embedded instruction targeting an agent.
- A request would be valid but the fabric is degraded from a control-plane fault: the tier cannot
  read fabric status and does not guess at it; the request runs through both confirmations, the
  service reports `Ready=False` naming the missing invariant (FR-100), and the tier reports a
  terminal failure or the convergence timeout (FR-067) — never converged.
- The transport is established but a worker's descriptor is stale or absent.
- Conversation history grows past the model's context window mid-thread.
- A service the tier created is later modified or deleted directly with cluster tooling: the tier
  detects it on the next status or removal request, says so, reports live state and changes nothing
  (FR-105).
- A removal asked of the tier is still not finished when the convergence timeout elapses — a leaf
  it touches is unreachable, or another service's access list still holds its subinterface: the
  turn ends saying the removal is in progress and naming what is outstanding, never "removed" and
  never "failed"; nothing is force-released and nothing is retried by the tier; the finalizer
  completes it unaided, and a later status request says where it stands (FR-069, FR-103, AD-63).
- The intent tier is removed while services it submitted are still running: the removal's first
  list is a read that decides only this — it lists them and stops non-zero, having changed nothing,
  until the operator asks for their removal in the same command (NFR-006).
- The intent tier is removed **with** that flag while a service it submitted cannot finalize because
  a target is unreachable: the removal scales the tier's request-accepting workloads down, takes —
  **after** the scale-down — the list of the services it will delete, exports the audit record,
  deletes them, waits a bounded time, then stops non-zero
  naming the service and the target with the rest of the tier still in place — or, where what holds
  the deletion is another service's binding on its attachment, the holder (AD-72). It never
  force-releases; re-running it completes once the target returns (NFR-006, FR-103).
- A service the tier submitted is created after the removal has taken its list: the list that
  decides what is deleted is taken **after** the scale-down, so the surface that would accept it is
  already gone; only the first, refusal-deciding list precedes the scale-down, and that one deletes
  nothing. The removal deletes the namespace only after a re-list returns empty (NFR-006).
- The intent tier is removed **without** that flag and its first list is empty: the removal
  proceeds, and it still scales the tier's request-accepting workloads down **before** it exports
  the audit record, so that no audit event is written after the export. Should a list taken after
  the scale-down not be empty — a service landed between the two — the removal falls back to the
  refusal: non-zero, naming it and the two continuations, having deleted nothing and exported
  nothing, with the request-accepting workloads left scaled down and re-provisioning named as what
  brings them back (NFR-006).
- A request reaches the chat or programmatic surface with no credentials, or with credentials that
  do not match the generated operator Secret: refused before a thread exists (FR-102).

**Observability**

- Telemetry cardinality, duplicate collection, stale series, or collector outage: the label set of
  every registered metric is closed and bounded in the path register (FR-017), a duplicate series is
  a failure (SC-037), and a series whose source stopped reporting goes stale and is shown as absent,
  never at its last value.
- Telemetry backpressure: one sink is unavailable while the other is healthy.
- Topology metadata differs from deployed links, or a dashboard query references a missing or
  renamed node, interface, service or metric label.

## Requirements *(mandatory)*

Requirements are numbered flat and continuous, grouped by concern so that the numbering itself
reads as an architecture: lab and lifecycle first, then the declarative control plane, then the
vocabulary that sits on top of it, then the intent tier that speaks that vocabulary, then the
boundary that keeps the tier safe, then what an operator sees and what the system reports about
itself. Every identifier's source is in [traceability.md](./traceability.md).

Four requirements carry several separable obligations under one number — FR-015, FR-078, FR-109 and
NFR-003. They are not split and not renumbered; each is instead enumerated clause by clause, with
the task and the test that assert that clause, in [traceability.md](./traceability.md)
§Obligations index. The `(a)`, `(b)` labels used there are index labels inside that file, not
identifiers: nothing cites them as requirements, and the requirement is always the whole of
FR-015, FR-078, FR-109 or NFR-003. FR-107 is indexed there the same way since the fifth analysis
pass of 2026-09-21 (AD-49), which found clauses of it with no task, and FR-108 since the seventh
(AD-65), its clauses having been added by three passes and enumerated by none.

### Functional Requirements

#### 1. Lab, topology and lifecycle

- **FR-001**: All emulated network devices MUST be Nokia SR Linux nodes launched by containerlab
  with the `nokia_srlinux` kind; endpoint hosts MAY be Linux containers. Leaves and spines MUST use
  licence-free emulated hardware types that carry the full EVPN-VXLAN feature set; a type that lacks
  VXLAN MUST NOT be used for any role.
- **FR-002**: The reference topology MUST contain two spines, two leaves and two Linux endpoints
  (one behind each leaf), with a pinned containerlab version, a pinned image version and immutable
  digest, an interface map in the device's own interface naming, a management network, resource
  requirements and a clean teardown procedure. Endpoints MUST be able to take part in several
  services at once over VLAN subinterfaces on their single link, so that L2, L3 and isolation tests
  need no further nodes, and endpoint interface MTU MUST be set to the tenant MTU the fabric
  actually carries.
- **FR-003**: *Retired by the SR Linux retarget (RD-04) — the dedicated SRv6 endpoints are removed
  with the SRv6 service. The dual-stack underlay obligation this requirement also carried is
  preserved in FR-011. See §Deferred scope.*
- **FR-004**: The device image MUST pass a capability gate before any end-to-end test runs. The gate
  MUST verify, on the pinned image and emulated types: gNMI Capabilities (the native model set at
  the pinned release and JSON_IETF encoding), version and platform identity, the platform feature
  set the constructs depend on, gNMI Set with read-back and durable persistence, transactional
  rollback of a rejected change, the MTU envelope, Subscribe, BGP EVPN behaviour — Type 2, 3 and 5
  routes actually exchanged through the route-reflecting spines, in both address families including
  an IPv6 anycast gateway — access-list programming with keyed applied-side read-back in each
  direction, that the device-configuration layer's schema still rejects the invalid configurations
  the platform relies on being rejected, an allocation claim round-trip, the exact JSON
  serialization the device returns for every rendered value, and what a managed-path deviation
  leaves observable under the drift policy the platform runs — which decides what the drift check
  of FR-015 and SC-007 may assert. A failed capability is never skipped and never weakened; its
  result is recorded per construct (FR-097). As decided on the pinned image: the MTU envelope's
  commit-time refusal one byte above is asserted for the port MTU and the routed IP MTU, while the
  tenant boundary is asserted on the data plane — the device accepts a tenant IP MTU one byte above
  at commit, which is recorded as an observation (AD-78); the access-list read-back keys the binding
  in the running datastore and each entry's programming on the bound direction only, and shows the
  binding applied by traffic entering on exactly the bound subinterface raising the filter's own
  entry's match counter above a baseline — the device mirroring no part of the binding into state,
  which is recorded and never judged (AD-82 `2026-09-21-acl-binding-state`); and egress filtering,
  which the device-configuration layer refuses to bind although the render satisfies it, is
  published unqualified (FR-097).
- **FR-005**: *Retired by the SR Linux retarget (RD-04) — the SRv6 compatibility gate is removed
  with the SRv6 service. See §Deferred scope.*
- **FR-006**: The Kubernetes distribution MUST be a pinned Kind release and node image. The
  cluster MUST have a stable name, a declarative cluster configuration, documented resource
  limits, and management connectivity to the containerlab nodes.
- **FR-007**: The allocation authority, the device-configuration layer and its prerequisites, the SR
  Linux provider, the migration translator, the device metric collector, the telemetry pipeline, the
  metrics store, the dashboards, their operator resources and every intent-tier workload MUST run
  inside the Kind cluster. Separate host containers, host-side executors or Compose stacks for any
  of these are forbidden, **without exception**: no platform component outside the cluster may read
  or write device configuration, and no provisioning, reconciliation, readiness or lifecycle outcome
  may depend on anything that does. The tools that *check* the platform are not platform components;
  what they may and may not do is FR-108.
- **FR-008**: Containerlab MUST remain responsible only for SR Linux nodes and Linux traffic
  endpoints. The provisioning script MUST connect Kind nodes and containerlab management interfaces
  through a dedicated, explicitly owned Docker management network whose address space is
  configurable, does not overlap the cluster pod or service networks, and is checked against every
  existing Docker network before anything is created; an overlap MUST fail preflight with the
  colliding network named.
- **FR-009**: Platform applications MUST be installed declaratively with pinned manifests or
  charts, namespaced by function, and waited on in dependency order. Application state, Secrets,
  RBAC, dashboards, rules and datasources MUST be managed through Kubernetes APIs.
- **FR-010**: The provisioning and shutdown scripts MUST be the primary lifecycle interface for the
  whole platform, including the intent tier. Both MUST be non-interactive by default, idempotent,
  fail fast with actionable diagnostics, accept the cluster name, the management address space, the
  intent-tier selection, the removal of the tier's submitted services, the discarding of the audit
  record and the preservation of captured evidence through documented flags or environment, and
  refuse to delete resources they do not own. **Neither script ever deletes anything under the
  lab's evidence root** (`.evidence/<cluster>_<lab>/`), with or without a flag — the exported audit
  record lives there (FR-078) and a later run looks there for it; the evidence-preservation flag
  only **adds** the optional capture of the state a teardown is about to remove. A flag whose effect is destructive beyond the thing
  the command is named for MUST be its own flag and MUST NOT be implied by another; a run that would
  need one and was not given it stops with the flag named. There is one lab profile; no flag selects
  a device profile. *(The evidence root never deleted, and what the preservation flag adds, by the
  seventh analysis pass of 2026-09-21, AD-64.)*

#### 2. Declarative control plane, reconciliation and rendering

- **FR-011**: The fabric MUST use a routed Clos underlay, reachable system loopbacks, a BGP EVPN
  overlay, leaf VTEPs and VXLAN encapsulation; spines MUST remain IP transit and control-plane nodes
  rather than tenant VTEPs, and a spine that reflects EVPN routes without being a tunnel endpoint
  MUST be configured so that it actually propagates them. The underlay and the tenant address
  families MUST be dual-stack; the VXLAN tunnel endpoint itself is IPv4, because that is the only
  tunnel source the platform supports, and no requirement may assume an IPv6 tunnel endpoint.
- **FR-012**: The platform's fabric design resource and the allocation authority MUST own topology
  roles, abstract network intent, and the allocation of IP addresses, ASNs, VLANs and VNIs. Every
  other device identifier — the EVPN instance identifier, route targets, route distinguishers,
  subinterface, tunnel-interface and integrated-routing interface indices and network-instance names
  — MUST be a deterministic function of an allocated value, the service identifier or a fabric-wide
  constant, so that it is reconstructable and never separately allocated. Route targets MUST be
  rendered explicitly from the fabric-wide overlay AS and the VNI; a device-derived route target
  MUST NOT be relied on, because it differs per leaf.
- **FR-013**: The platform MUST reuse the pinned upstream device-configuration APIs (`Schema`,
  `Target`, `Config` and their companions) and the pinned upstream allocation and inventory APIs
  unchanged, and MUST NOT introduce duplicate device-configuration or allocation CRDs — the single
  exception being the recorded allocator substitution of FR-104, which replaces the upstream
  allocation authority rather than standing beside it. Fabric and
  service intent MUST be expressed in exactly one first-party API group with structural schemas — a
  fabric design Kind and the `Network` service intent Kind — because no maintained upstream fabric
  API can express the four constructs. No second fabric-intent API, and no per-device intermediate
  Kind between the `Network` and the device configuration resource, may be added. Controllers
  reconciling these objects are the **only** orchestration of fabric change: no second workflow,
  pipeline or job engine may sequence, retry, schedule or gate a device change, and no change may
  reach a device except by a controller reconciling one of these objects (FR-014, FR-015) — the one
  named exception being the capability gate's labelled scratch configuration resource, which is
  verification tooling, carries no fabric or service intent and is bounded by FR-108. The optional
  `MigrationPlan` (FR-048) is the one first-party Kind outside that group: it sits in its own group,
  carries no fabric or service intent, and is the only other first-party group there may be.
  *(The gate-tooling exception named by the fifth analysis pass of 2026-09-21, AD-48.)*
- **FR-014**: A single first-party SR Linux provider MUST translate the fabric design and each ready
  `Network` into deterministic, schema-version-aware device configuration resources — one per
  affected device per source object — and MUST be the only renderer of any device path: underlay,
  overlay, bridged and routed instances, integrated routing, anycast gateway and access lists alike.
- **FR-015**: The device-configuration layer MUST validate rendered configuration against the pinned
  device schema before any device write, apply it over gNMI as a transaction that rolls back on
  rejection, and expose intended, running, applied and deviation state. It MUST be the only
  component that writes device configuration. Lab mode MUST enable an explicit revertive drift
  policy; production drift policy MUST be selected explicitly and MUST NOT be inherited from the
  lab: the policy is a provider setting with **no default**, stated on every device configuration
  resource the provider generates — it is the boolean revertive field of that resource, never left
  absent for the layer's own default to supply — and a provider started without one refuses to
  start. The set of drift policies is **closed and has exactly one member, `revertive`** — a
  not-applied deviation on an owned path is reapplied and the restoration is verified — because
  constitution Principle I requires detected drift to be repaired and `revertive` is the only
  repairing policy this platform implements. The device-configuration layer also offers a
  non-revertive mode, in which a deviation is recorded and held for the operator either to accept
  as active or to revert; the revert is repair, so that shape is not forbidden, it is simply out of
  scope here — the platform builds neither the status shape a held deviation needs nor the path
  that clears one. Any other value, in any spelling or casing, is unknown and refuses the start
  exactly as an absent one does. Admitting a second policy is a change to this requirement that
  names the value and brings its repair procedure, its status shape, its tests and its runbook
  entry with it; a policy that does not repair at all may not be admitted while Principle I
  stands.
  Configuration resources that could touch the same device leaf MUST NOT share a priority: such
  an overlap is a conflict refused at validation, never an ordering left to the layer to resolve,
  and an overruled platform-owned path is a terminal error.
  - *Amended by AD-68* (operator decision): a leaf in this rule is a **non-key** leaf, and the
    configuration is built so that no two service resources share one. The leaves two services
    would share — an access port's administrative state and tagging mode, and the integrated-routing
    interface's own administrative state — MUST be rendered by the fabric's configuration resource,
    at the fabric priority, from the fabric design; a service resource MUST NOT write above the
    subinterfaces it creates; and the reference that ties an access-list binding to a subinterface
    MUST be rendered by the resource that renders that subinterface, a standalone access list writing
    only its own filter binding beneath it. The refusal stays as the backstop it describes.
- **FR-016**: Generated resources MUST use owner references, stable names, generation hashes,
  server-side apply, scoped field ownership and finalizers, so that update and deletion affect
  only platform-owned paths.
  - *Amended by AD-69*: an owner reference is used **where owner and dependent share a namespace**
    — a fabric's configuration resources and their `Fabric`. A service's configuration resources
    live in the provider's namespace and their service intent object never does, so they MUST NOT
    carry one: a cross-namespace owner is read as an absent owner and the dependent is collected,
    which would withdraw the service from the device. They are tied to their source by its
    identifier and removed by its finalizer (FR-103); a resource of the derived name that belongs to
    another source is never overwritten.
- **FR-017**: The provider MUST render, and the collector MUST subscribe to, the device's native
  YANG paths by default, because the platform's standard-model coverage excludes EVPN and VXLAN.
  Every rendered and every subscribed path MUST be covered by the path register, which states per
  path whether the native or a standard model was chosen and carries a recorded justification for
  every exception to the native default; for a subscribed path it also records the derived metric
  name, labels and stream mode. The register MUST be CI-guarded so that a new construct cannot pass
  uncovered. The device image digest, the YANG model tag, the device-configuration layer's schema
  definition and its deviation patch (pinned by commit, never by branch), the device-configuration
  and allocation releases, containerlab, the collector and the provider's mapping version MUST be
  pinned and published as one compatibility set.
- **FR-018**: Reconciliation MUST wait for dependencies, retry transient errors with bounded
  exponential backoff, classify terminal validation errors, publish Kubernetes Events, and
  propagate per-device conditions without partial success ever being reported as ready. The
  reconciliation interval and the backoff bounds have stated defaults
  ([data-model.md](./data-model.md) §25) and are configuration, not code.
- **FR-019**: Secrets, certificates and credentials MUST be stored in Kubernetes Secrets; RBAC
  MUST grant each controller only its required resources and verbs; lab defaults MUST never be
  presented as production-safe. No credential MAY appear as a literal in any deployment manifest —
  the only admissible forms are a reference to a Secret, a projected volume, or a placeholder a
  generator fills at provisioning — and that rule MUST be carried by a repository-wide check that
  runs on every pull request, not by review alone, so that it fails a commit rather than a run.
- **FR-020**: Tests MUST cover translation golden files, CRD schema validation, controller
  idempotence and finalizers, device-configuration schema validation of every golden render,
  containerlab BGP/EVPN/VXLAN and traffic behaviour, the capability gate, access-list ordering and
  enforcement, topology-display parity, drift, failure, telemetry and teardown. Traffic tests MUST
  assert reachability, isolation and counter movement and MUST NOT assert throughput, which the
  containerized dataplane does not provide. Every suite that needs no lab — unit, golden, API and
  controller tests against a test control plane, the intent tier's unit tests and the chat
  surface's — MUST have a make target and MUST run on every pull request; a suite that exists and
  is wired to nothing protects nothing.
- **FR-021**: *Retired by the SR Linux retarget (RD-04) — the `SRv6Service` API is deferred to a
  future feature. See §Deferred scope.*
- **FR-022**: *Retired by the SR Linux retarget (RD-04) — SRv6 locator and SID allocation and
  rendering is deferred to a future feature. See §Deferred scope.*
- **FR-023**: *Retired by the SR Linux retarget (RD-04) — end-to-end SRv6 verification is deferred
  to a future feature. See §Deferred scope.*
- **FR-097**: The capability gate MUST record, per construct and per gated property, whether the
  pinned image and emulated types qualified it, and MUST publish that record where the intent tier
  can read it. A request for a construct or property the record does not show as qualified MUST be
  refused at interpretation, naming what is unqualified, before any identifier is claimed or any
  resource created. *(New in the retarget; closes GAP-1.)*
- **FR-098**: No CRD or API service MAY be installed into an upstream project's API group unless it
  is that project's own pinned, unmodified artefact. A first-party stand-in for an upstream API — a
  look-alike Kind in a look-alike group — is forbidden, and the provisioning script MUST fail rather
  than fall back to one when an upstream artefact cannot be fetched. *(New in the retarget; answers
  the inherited acceptance record.)*
- **FR-100**: Readiness of every construct MUST be set from a two-sided read-back: the written side
  — the configuration resource is applied with no deviation and its content is present in the
  device's running datastore — **and** the applied side — the device's own state for the objects
  this service created: instance, subinterface, tunnel and EVPN instance operational state, the
  remote tunnel endpoints and EVPN routes the service requires once it spans more than one leaf, and
  the gateway state where one is declared. Every applied-side read MUST be keyed to this service's
  own objects; a fabric-wide or device-wide count is never evidence. As decided (AD-82
  `2026-09-21-state-source`), the pinned device-configuration layer serves no state datastore, so
  every applied-side read — the fabric design's and every service's — comes from the device metric
  collector (FR-089, FR-086's second client): a node with no sample, or a collector that does not
  answer, is a read-back that cannot run (`Ready=Unknown`, `VerificationFailed`, FR-107), never an
  absent value; samples are taken every 5 s and a series not refreshed within 20 s is dropped (AD-82
  `2026-09-21-collector-freshness`). The fabric design's own
  readiness follows the same rule for the objects *it* creates — interfaces, underlay and overlay
  sessions established with the EVPN family negotiated (read from the family's own operational
  state per neighbour), and every other node's allocated loopback present and active in this node's
  route table — beside a read-back of the reflecting spines' reflection settings that MUST be
  stated as a **configuration-integrity** check rather than as applied-side evidence, those settings
  — `inter-as-vpn` and `route-reflector client` — being configuration read, as decided (AD-76), from
  the configuration datastore (the running configuration through the device-configuration layer),
  because the pinned image does not mirror them into state; `route-reflector client` renders
  `Fabric.spec.overlay.reflectorClients` and `inter-as-vpn` renders `overlay.interASVPN`, each read
  back equal to what is declared; `interASVPN` is not a convergence rule of its own beyond that
  check, while `reflectorClients: false` makes the fabric design report `Ready=False`
  (`NotConverged`) naming each spine and the setting (AD-77). It MUST NOT count EVPN routes: until a
  service spans two leaves there are none, so route exchange is an invariant of each such service
  and never of the fabric design. A status condition MUST name
  the missing invariant and surface the device's own reason when it gives one. *(New in the
  retarget; closes GAP-6. FR-042 states the same obligation for access lists.)*
- **FR-103**: When a service is deleted while a device it touches is unreachable, finalization MUST
  block — unreachable including, as decided (AD-82 `2026-09-24-delete-unreachable`), a node whose
  `Target` is still Ready but for which the collector-based data-path probe has no sample within
  30 s, which is then named under `Deleting=True` with the reason `TargetUnreachable`: the service intent object remains with a condition naming each unreachable target, the
  configuration already removable from reachable devices is removed, and **every allocation the
  service holds stays claimed** until the removal of its configuration has been read back from every
  affected device. No timeout MAY release an identifier or remove the object; when the target
  returns, removal MUST complete without operator action. From the moment finalization starts —
  in every deletion, whether or not a target is unreachable — the object MUST report `Ready=False`
  with the reason `Deleting`, beside the deletion condition that says what is outstanding: a
  service being removed is no longer offered, so nothing is read back to decide that, and it MUST
  NOT report `Ready=True` or `Ready=Unknown` while it is being removed. The only other exit is an explicit
  operator force-release — a documented annotation on the service intent object carrying a stated
  reason — which MUST publish a Kubernetes Event and MUST record a durable finding on the fabric
  design resource naming the service, the device and the identifiers released, stating that the
  device may still carry stale configuration; that finding outlives the service object and is
  cleared only after the device has been read back without the stale objects. The force-release
  MUST be refused when its reason is empty, MUST be ignored — with an Event and nothing released —
  on an object that is not both deleting and blocked on an unreachable target, and MUST NOT be
  settable by any intent-tier identity, which FR-075's verbs alone cannot express. While a finding
  is open, a render that would reproduce one of the device objects it names on that device MUST be
  refused, and the fabric design MUST report **degraded, not not-Ready**, so that possible stale
  configuration is visible without stopping the fabric. Each unreachable target is named
  individually and recorded as one finding per service and device; removing the device from the
  fabric design completes nothing and releases nothing, so a device that never returns leaves the
  force-release as the only exit. The force-release
  procedure MUST be in the runbook (NFR-011). *(New; clarification 2026-09-20; guard rules, the
  open-finding consequence and the never-returning target added by the operator review of
  2026-09-20; the readiness of an object being deleted added by the operator decision of the sixth
  analysis pass of 2026-09-21, AD-53.)*
  - *Amended by AD-71*: a finding whose device has since been removed from the fabric design can
    never be read clean, so it is never cleared; it stays on record and MUST NOT count toward the
    degraded report while that device is absent from the design — the report describes the fabric
    that exists — and counts again, and clears like any other, if the device returns.
- **FR-104**: If the pinned upstream allocation authority fails its capability-gate item (FR-004 —
  the allocation claim round-trip), provisioning MUST stop with the failing item named; the
  provisioning script MUST NOT select another allocator on its own. The one permitted substitution
  is a first-party allocation authority — a substitute for the upstream one, not to be confused with
  the intent tier's allocator agent, which only requests identifiers — adopted by an explicit
  operator decision that is recorded — with the
  failed gate evidence it answers (NFR-013) — before anything is installed. Its claim kinds MUST
  live in the first-party fabric API group (FR-013) and MUST NOT be served in, or imitate,
  the upstream project's API group (FR-098). It MUST honour the same claim semantics the platform
  relies on — IP, ASN, VLAN and VNI pools; a claim reports its allocated value in status; the intent
  tier may create and delete a claim but never update one — so that FR-012, FR-062 and the
  assignment contract are unchanged above it. Exactly one allocation authority MUST be installed in
  a lab: the upstream one and the substitute never coexist, and which one is installed MUST be
  recorded in the compatibility set (FR-017) and warned at provisioning time. A substitution MUST be
  adopted on a lab that holds no bound claim; where one is held, the services resting on it are
  enumerated and re-created after the switch, because no claim survives a change of authority.
  Returning to the upstream authority is the same decision in reverse and MUST be recorded the same
  way. As decided (AD-74), the pinned upstream authority failed this gate item, the substitution is
  adopted and is what runs on this lab: `IdentifierPool` and `IdentifierClaim` in
  `fabric.agentic-netops.io`, in the namespace `agentic-netops-allocation`, served by the provider
  binary in its allocation-authority role and selected in the lock file
  (`allocationAuthority.kind: first-party`), which passed the same gate item; the upstream authority
  remains the documented alternative the lock can select, never installed beside it. *(New; clarification
  2026-09-20; the substitution's preconditions and the return path added by the operator review of
  2026-09-20.)*
- **FR-107**: Convergence MUST be re-verified on a schedule, not only when something changes. For the
  fabric design and for every service that has reported Ready, the provider MUST re-run the two-sided
  read-back of FR-100 (and FR-042 for access lists) at a re-verification interval whose default is
  five minutes and which is configuration, not code; a value below the stated minimum, or one that
  cannot be parsed, MUST refuse the provider's start rather than fall back to the default
  ([data-model.md](./data-model.md) §25). An object that has never reported Ready is outside the
  schedule — it is already being reconciled toward readiness — and "has reported Ready" is read
  **at the object's current generation**: one updated to a new generation that has not yet been
  applied is converging again and reports `Ready=False`, not `Ready=Unknown`, when a target cannot
  be reached, although it was Ready at the generation before (AD-62) — and an object held in deletion stays
  inside it **only as a requeue**: its finalizer is retried at the same interval (FR-103), no
  read-back is run to decide its readiness, and it reports `Ready=False` with the reason `Deleting`
  from the moment finalization starts — never `Ready=Unknown`, whatever the reachability of its
  targets (AD-53). A re-verification that finds an invariant
  missing MUST set `Ready=False` naming it, so that a lost invariant is reported no later than one
  re-verification interval plus one reconciliation interval after it was lost (the bound SC-044
  measures) — `Ready=True` is never a memory of an earlier pass — and drift it finds on an owned path MUST be repaired under the selected drift
  policy (FR-015). A pass that **could not run** — the target was unreachable or the read timed out —
  is neither a lost invariant nor a kept one: it MUST set **`Ready=Unknown`** with the reason
  `VerificationFailed`, at that pass and not after any further wait, together with `Degraded=True`
  under the same reason naming the target, and the time of the last successful re-verification MUST
  NOT advance. It MUST NOT set `Ready=False`, because an outage is not evidence that an invariant is
  gone, and it MUST NOT leave `Ready=True` standing, because a `Ready=True` nobody could re-read is
  exactly the memory of an earlier pass this requirement forbids (constitution Principle I). The
  same outcome applies when the reconciler, between two scheduled passes, observes that a required
  target of an object that had reported Ready is no longer reachable — that is a read-back that
  cannot run, and it is what keeps SC-008's bound. As decided (AD-82
  `2026-09-24-layer-before-target`), "no longer reachable" is read from the device-configuration
  layer's own configuration resource status — an object Ready at its current generation, nothing
  written in this reconcile, whose configuration resource the layer no longer confirms — and not
  from the `Target`, which the pinned layer was observed to keep Ready through a whole management
  cut. An object held at `Ready=Unknown` retries its read-back at the reconciliation interval, not
  the re-verification interval (AD-82 `2026-09-24-unknown-retry`); a retry that still cannot run
  changes nothing. The next pass that runs returns `Ready=True` if
  both sides pass and sets `Ready=False` naming the invariant if one is missing; `Ready=Unknown` is
  never a success to anything that reads it (FR-054, FR-067). The time of the last
  successful re-verification MUST be visible in status and as a
  metric — *successful* meaning that the pass **ran**, that is, completed its read-back, whatever
  it found: a pass that finds an invariant missing advances it, and only a pass that could not run
  does not (AD-54) — so that a stalled schedule is itself detectable; a `Ready=True` older than the bound above
  MUST raise an alert (FR-087) rather than only be visible — during an outage what the operator
  sees is `Ready=Unknown` with the target named, and the alert remains the guard for a schedule
  that stopped while `Ready=True` stood. Re-verification adds no client of the
  device management server: it reads the running configuration the device-configuration layer
  already holds and, as decided (AD-82 `2026-09-21-state-source`), the state the device metric
  collector already samples — the pinned layer serving no state datastore — which
  is why FR-086 sizes that limit for two clients and not three. *(New; analysis 2026-09-20; the
  cannot-run outcome, the schedule's scope, the interval's floor and the stalled-schedule alert
  added by the operator review of 2026-09-20; the cannot-run outcome changed from "leave `Ready`
  where it stands" to `Ready=Unknown` by the operator decision of the fifth analysis pass of
  2026-09-21, AD-40; the deleting object's place in the schedule and the meaning of "successful"
  stated by the sixth analysis pass of 2026-09-21, AD-53 and AD-54; "has reported Ready" scoped to
  the current generation by the seventh analysis pass of 2026-09-21, AD-62; carries
  constitution Principle I's scheduled re-verification.)*
- **FR-108**: Verification tooling is not a platform component and is never a change path. The
  capability gate (FR-004), the fault- and drift-injection steps of the acceptance suites (FR-020)
  and the read-only device proofs of the recorded walkthrough MAY open a management session to a lab
  device from the operator's host — or, for a gate item that has to observe a pinned telemetry
  client, from a throwaway Pod the gate starts in a scratch namespace it labels, passes the lab
  operator's device credentials to for its lifetime only, and removes — under all of these conditions: every such invocation is
  run-captured evidence (NFR-013); anything it writes is scratch configuration or a declared injected
  fault, removed by the tool that wrote it, with the removal read back before the run continues —
  with one exception by class: a fault injected on a path the platform manages is **drift**, which
  the platform itself restores under the drift policy of FR-015, so there the injecting tool removes
  nothing and instead reads the restoration back before the run continues (the drift check of
  SC-007 is the case; SC-004's negative control is not one, being declarative); it
  uses the lab operator's device credentials, never a platform workload's identity, and is never
  installed as a long-running process; it is not reachable from, or invocable by, the intent tier
  (FR-075); and no service, fabric or lifecycle outcome depends on it — provisioning a service,
  converging the fabric and setting readiness use only the path of FR-014 and FR-015 — with, as
  decided (AD-82 `2026-09-21-state-source`), readiness's applied-side reads taken from the platform's
  own device metric collector (FR-089, FR-100), not from verification tooling. A device client
  invoked from anywhere in the repository other than the gate, the test suites and the walkthrough
  tooling MUST fail the boundary check in CI. Three terms are used exactly: **scratch configuration**
  is configuration a check writes solely for its own observation, which no service, fabric or
  readiness outcome reads — and it includes the one case that is not a device session at all: a
  **gate-owned scratch configuration resource**, which the capability gate applies through the
  device-configuration layer to observe that layer's own behaviour (what a managed-path deviation
  leaves visible, FR-004). It MUST be labelled as gate-owned, MUST carry a priority no platform
  resource uses, MUST touch only a path no fabric or service renders, and MUST be removed by the
  gate, the removal read back both as the cluster object gone and as its content gone from the
  device's running datastore. It is the named exception, for gate tooling only, to FR-013's rule
  that no change reaches a device except by a controller reconciling a first-party object;
  **a declared injected fault** is a change a suite names in the run's
  evidence before it makes it, so that the failure it produces is expected rather than discovered;
  **a device client** is any invocation that opens a management session to a device, which is what
  the boundary check matches. Because a tool can die between writing and removing, everything of the
  first two kinds MUST be named or labelled so that a later run can find it, and a gate or
  acceptance run MUST refuse to start while such a leftover is present on any node — or, for the
  gate-owned scratch configuration resource and the gate's labelled scratch namespace, in the
  cluster — rather than assume the tool that wrote it survived. The scratch namespace is on that
  list because a gate that died mid-item would otherwise leave a throwaway Pod holding the lab
  operator's device credentials and a management session against the limit FR-086 sizes. *(New; analysis 2026-09-20; states the boundary FR-007
  and FR-015 draw around the platform, without widening either; the three definitions and the
  leftover rule added by the operator review of 2026-09-20; the drift-class exception and the
  gate-owned scratch configuration resource added by the fifth analysis pass of 2026-09-21,
  AD-48; the gate's labelled scratch namespace named in the leftover rule, which until then only
  T043's scan carried, by the seventh analysis pass of 2026-09-21, AD-65.)*
- **FR-109**: Every VNI a service intent object carries MUST be backed by a bound claim in the
  allocation authority before any device configuration is rendered for it, whichever way the object
  arrived. Where a bound claim carrying the object's correlation label, bearing the name derived
  deterministically from the object for that field, already reports that value — the intent-tier
  path (FR-062) — the provider MUST adopt it and create nothing. **All three MUST agree, for a VNI
  claim exactly as for a VLAN claim**: a claim that matches on label and value under any other name
  MUST NOT be adopted, so that an object copying another service's correlation label adopts none of
  its claims; and the intent tier MUST name every claim it creates — VLAN and VNI — by the one
  scheme the provider names its own by, namespace, object name and the field's role. Where none does — an
  object applied with cluster tooling — the provider MUST claim exactly that value from the VNI index,
  through the same claim adapter the fabric design's own claims use, under a name derived
  deterministically from the object and labelled with it, so that the claim is reconstructable and
  releasable. A value the authority reports as held by another owner, or as outside the allocation
  band, MUST set `Accepted=False` naming the value and the holder or the band, with nothing rendered;
  the provider MUST NOT choose another value. Adopted and created claims alike are released only by
  finalization, after the removal has been read back (FR-103). So that no claim is ever superseded
  while its service lives, the identifiers a claim backs are **fixed once the object is accepted**:
  its VNIs, and the VLAN of its `vlan` or `mac-vrf` entry, MUST be immutable — the API refuses the
  edit naming the field, and changing one is a removal and a new service. Attachments MAY be added
  and removed, except that an attachment **added** to an accepted object MUST NOT carry a VLAN in
  the allocation band **that the object does not already carry** — that is, the VLAN of its `vlan`
  or `mac-vrf` entry, the only place an allocated VLAN lives — because nothing would claim a new one; an
  allocation-band VLAN the object already carries is already claimed, so a `vlan` or `mac-vrf` whose
  VLAN was allocated MAY still gain an attachment on that same VLAN; an object carrying access
  lists and nothing else is outside this rule, its attachment VLAN being a reference (below).
  **Adoption is decided once per value**: a claim
  recorded as adopted stays adopted, held and listed, until finalization, whatever attachments are
  removed meanwhile, and is never re-evaluated or released early. A VLAN an operator names — necessarily one in the naming band `100–999`
  (FR-062) — is claimed on neither path: its exclusivity is the one-owner rule of FR-034. A VLAN in
  the **allocation band** `1000–4000` is a different thing: it MUST be backed by a bound claim
  carrying the object's correlation label, bearing the name derived deterministically from the
  object, and reporting the VLAN of the `vlan` or `mac-vrf` entry that name names. **An `ip-vrf`
  attachment's VLAN is named or absent, and MUST NOT be allocated**: the intent tier claims no VLAN
  for an `ip-vrf` — an attachment that names none is the untagged subinterface — so an `ip-vrf`
  attachment carrying a VLAN in the allocation band has no adoptable claim by construction and is
  refused like any other. The provider MUST adopt such a claim exactly as it adopts the tier's VNI claims —
  it creates nothing, records the claim as adopted, holds it for as long as the service exists and
  releases it only by finalization — and MUST refuse an object carrying an allocation-band VLAN that
  no such claim backs, `Accepted=False` naming the VLAN and both bands, with nothing rendered. **The
  band decides**, because a service intent object cannot say whether its VLAN was named or
  allocated. The one VLAN the band does not decide is the one a standalone `acl` carries on its
  attachment: it is a **reference** to a subinterface another service created, the claim behind it —
  where there is one — is that service's, and an object carrying access lists and nothing else MUST
  be accepted with no claim looked for, whichever band the VLAN lies in. Every
  claim a submitted service rests on therefore has **one release owner, the provider**, whichever way
  the service is later removed; the intent tier releases a claim only while it is still provisional
  — on decline, on rollback and for a request that was never submitted (FR-056, FR-066). For that
  ownership to hold from the first instant, a service intent object the intent tier submits MUST
  carry the provider's finalizer **from the moment it is applied**, so that no window exists in
  which it can be deleted outright and leave its claims with no owner; an object applied with
  cluster tooling takes the finalizer from the provider's first reconcile instead — and because
  admission fails closed (FR-034), neither kind of object can be applied while the provider is
  down, so the one finalizer-less window is an object applied with cluster tooling and deleted
  before that first reconcile; a deletion is not intercepted and goes through whether or not the
  provider is up. A finalizer holds
  the object and releases nothing by itself, so **finalization MUST resolve adoption before it
  releases**: for every value a deleting object carries that is not yet recorded among its claims,
  the provider MUST first apply the same three-part adoption rule and record what it adopts, and
  only then release — so that an object deleted before its first reconcile leaves no claim behind.
  It MUST NOT create a claim on a deleting object. An allocation authority that **errors or
  cannot be reached** — as opposed to one that answers that no such claim exists — has not
  answered: the provider MUST NOT read it as "nothing adoptable" and MUST NOT report it as an
  allocation conflict. Before a render it is a dependency wait; in finalization the finalizer MUST
  stay and nothing MUST be released; both are retried with bounded backoff, and neither is given
  a deadline. So that every claim name the one scheme forms is a valid object name, the service
  intent object's name and the names of its `vlan`, `mac-vrf` and routed-instance entries MUST each
  be bounded to a 63-character label, and the intent tier's service identifier to a 15-character
  one. Which correlation identifiers are still
  provisional is the **deployer's** to determine — the requirement is FR-075's, stated there once —
  with the allocator agent deleting only the claims it is told to delete and reading no service
  intent object at all, so the exact verb sets of FR-075 are unchanged. That the pinned allocation
  authority binds a claim for a stated value, refuses a second one naming the holder, reports a
  claim's value in its status, allows a claim's labels to be selected on, never allocates below its
  index's lower bound, and frees a deleted claim's value as the deletion returns, is part of its
  capability-gate item (FR-004) and is never assumed. *(New; analysis 2026-09-20, second pass;
  gives the tier-less allocation path of FR-012 an owner. Widened by the third pass to the tier's
  VLAN claims, which had no release owner once a service was submitted. Extended by the fifth
  analysis pass of 2026-09-21: one three-part adoption rule for VNI and VLAN claims, AD-42;
  adoption resolved at finalization, AD-44; the added-attachment rule scoped to a VLAN the object
  does not already carry, and the standalone `acl`'s VLAN as a reference, AD-47. By the sixth
  analysis pass of 2026-09-21: an `ip-vrf` attachment's VLAN as named or absent and never
  allocated, AD-51; an authority error as a wait and never an answer, the standalone `acl`'s
  exemption from the added-attachment rule, and the bounded claim name, AD-56. The
  finalizer-less window restated for an admission that fails closed by the sixth analysis pass of
  2026-09-21, AD-52.)*

#### 3. Construct vocabulary and semantics

- **FR-024**: The platform MUST express its provisionable services as exactly four constructs —
  `vlan`, `mac-vrf`, `ip-vrf`, `acl` — and MUST NOT advertise any retired service-provider
  service name as a type an operator can ask for.
- **FR-025**: The platform MUST resolve a construct name regardless of case, hyphenation,
  underscoring or spacing.
- **FR-026**: Every operator-visible artifact of a provisioning exchange — the interpretation,
  the confirmations, the status, the refusals, the telemetry and the audit record — MUST name the
  construct, never a retired service name.
- **FR-027**: A service that converged before the vocabulary changed MUST also be reported by its
  construct, derived when it is read. Its stored record MUST NOT be rewritten — no converged
  service is written to for a naming change — and the vocabulary it was created in remains
  available as provenance.
- **FR-028**: A request naming an unknown construct MUST be refused with the available constructs
  listed.
- **FR-029**: `vlan` MUST provision a local bridge domain — a bridged instance on one node and the
  attachment subinterfaces that belong to it — and MUST NOT allocate a VNI or route targets, nor
  render any tunnel or EVPN configuration. It MUST remain its own construct and its own list in the
  service intent object even though the device realizes it with the same instance type as a
  `mac-vrf`, so that "local" is never encoded as "the overlay fields are missing".
- **FR-030**: `mac-vrf` MUST provision a bridge domain extended over the fabric by an L2VNI with
  EVPN route targets, for exactly two attachments or for more, without those being different
  constructs.
- **FR-031**: `ip-vrf` MUST provision a routed instance — a VRF with an L3VNI and route targets —
  advertising the prefixes the operator declared.
- **FR-032**: A `mac-vrf` MUST accept an anycast gateway that places the bridge domain's gateway
  inside a routed instance, and this composition MUST be the only way symmetric IRB is expressed.
  The gateway MUST NOT widen what was asked for: only the address families the operator declared are
  configured — an unrequested family is never added — and a `mac-vrf` requested with no gateway
  MUST NOT create a routed instance or allocate an L3 identifier (FR-062). *(The two MUST NOTs —
  User Story 8's scenarios 2 and 3, until now carried only by the data model — added by the fifth
  analysis pass of 2026-09-21, AD-50; they carry constitution Principle II's "never a service type
  the operator did not ask for", CR-002.)*
- **FR-033**: A construct given a variable belonging to a different construct MUST be refused,
  naming both the property and the construct that carries it — never silently ignored.
- **FR-034**: Every constraint the fabric enforces per service type — one service VLAN per bridge
  domain, the VNI band and its containment within the range the device's EVPN instance identifier
  can carry, the naming band `100–999` a named VLAN must come from, refused with both bands stated
  (FR-062), one owner per node, port and VLAN, one
  tagging mode per port (an untagged attachment and a tagged one never share a port; *amended by
  AD-68*: the mode is the one the site inventory **declares** for the port, tagged unless declared
  untagged, and an attachment asking for the other is refused listing the ports declared in the mode
  it asked for), and site
  inventory validation — MUST be enforced per construct with the cause stated in construct terms.
  Site inventory validation refuses a node or a port the inventory does not contain **listing the
  valid names**, on the tier path and at admission alike (CR-003). The constraints enforced at
  admission **MUST fail closed**: while the component that evaluates them cannot be reached, a
  create or an update of a service intent object MUST be refused rather than admitted unchecked, so
  that every admission rule holds at all times and none is left to an after-the-fact
  `Accepted=False`; a deletion is never intercepted, so removal does not depend on that component
  being up. A request refused for that reason is a failure of the cluster API dependency and is
  reported as one (NFR-010) — never as a refusal of what was asked, with no rule and no valid
  alternative to name. Those constraints govern what a service intent object **says**: they MUST be
  evaluated when it is created and when an update changes its `spec`, and an update that leaves
  `spec` unchanged — a finalizer, a label or an annotation, the force-release annotation of FR-103
  included — or that reaches an object already being deleted MUST be admitted without re-evaluating
  them, so that finalization, the force-release and the removal of a service whose attachment no
  longer resolves are never refused by the platform's own admission; who may set the force-release
  annotation is guarded where it always was (FR-103) and is not widened by this. *(The enumeration, which CR-003
  required and none of its carriers stated, added by the fifth analysis pass of 2026-09-21, AD-50;
  the VLAN constraint restated by the same pass as the naming band of FR-062, AD-47; admission
  failing closed by the operator decision of the sixth analysis pass of 2026-09-21, AD-52; what
  admission evaluates and what it admits unread by the seventh analysis pass of 2026-09-21, AD-61.)*
- **FR-099**: The construct names `mac-vrf` and `ip-vrf` MUST remain identical to the device's own
  names for its bridged and routed network-instance types, asserted in CI against the pinned device
  model, so that an operator who reads the device documentation and an operator who reads this
  platform's documentation learn the same two words. `vlan` and `acl` are operator vocabulary and
  are documented with the device objects they render. *(New in the retarget; RD-06.)*

#### 4. Access lists

- **FR-035**: The platform MUST accept an access list as a construct in its own right, bound to the
  attachments named by its endpoints. Every access list belongs to exactly one service and is
  withdrawn with it; the name an operator gives a list is a label for reading, not an identity other
  services can reference. A standalone access list binds to attachments that another service has
  already created on the named node, port and VLAN; it MUST be refused, naming the missing
  attachment, when none exists, and it MUST NOT create an interface or subinterface of its own.
- **FR-036**: The platform MUST accept an access list as a property of a `vlan`, `mac-vrf` or
  `ip-vrf` request, bound to that service's own attachment subinterfaces. A request that names an
  existing list instead of stating its rules MUST be refused, stating that a service carries its own
  rules; two services MAY use the same label without sharing anything.
- **FR-037**: The attachment subinterface is the only binding point in scope: an operator names a
  node, a port and optionally a VLAN, which resolves through the site inventory to one subinterface
  (the untagged subinterface when no VLAN is named). An access list MUST NOT be bindable to a
  network instance, to a VLAN as such, to an integrated-routing interface or fabric-wide, and a
  request asking for one MUST be refused stating that the list binds to named attachments.
- **FR-038**: An access list MUST declare a stage (ingress or egress) and an address family (IPv4 or
  IPv6), and MUST carry at least one rule. A Layer 2 (MAC) list MUST be refused as out of scope —
  the construct is defined over address families — rather than as something the device lacks.
- **FR-039**: A rule MUST declare a name, a distinct priority and an action of permit or deny, and
  MAY constrain IP protocol, source and destination prefix, and source and destination L4 port or
  port range. Rules MUST be evaluated in **ascending priority number with the first match winning**,
  which is the device's own evaluation order, and the priority MUST be rendered as the device's
  entry sequence number unchanged so that what the operator wrote is what the device shows. The last
  position in the evaluation order is reserved for the default action and is not available to a
  rule; the evaluation order and the usable range MUST be stated to the operator at the first
  confirmation. The provider MUST NOT invert, renumber or otherwise remap an operator's priority on
  render, and no operator-facing surface may describe a higher number as winning. *(Direction
  confirmed by clarification, 2026-09-20.)*
- **FR-040**: The platform MUST refuse a rule set with duplicate priorities, duplicate rule names, a
  rule claiming the reserved default-action position, a prefix in the wrong address family for the
  list, an L4 port on a protocol other than TCP or UDP, a list name the device reserves for its own
  filters, a match or action outside the supported set, or a value outside its valid range — each
  naming the offending rule, and for the reserved position, stating the range that is usable. Any IP
  protocol the device can match, including ICMPv6, MUST be accepted.
- **FR-041**: An access list MAY declare a default action for unmatched traffic; when declared it
  MUST be rendered explicitly rather than left implied, as a terminal match-all entry at the
  reserved last position so that it is evaluated after every rule the operator wrote, whatever
  priorities those carry. The device's own behaviour for unmatched traffic is to accept it;
  therefore when no default action is declared, the confirmation shown to the operator MUST state
  that unmatched traffic will be accepted, and the platform MUST NOT describe such a list as
  restrictive beyond its explicit rules.
- **FR-042**: The platform MUST verify a rendered access list on the fabric the same way it verifies
  every other construct (FR-100) — by reading back both the configuration it wrote and the device's
  own applied view of the filter — and MUST report the service unconverged if either is absent. The
  applied view is the device's state for **this** filter: the binding present on the intended
  subinterface in the intended direction, and every entry reported as programmed for that direction,
  each read through a path keyed by this filter's name, address family and entry. As decided (AD-82
  `2026-09-21-acl-binding-state`), the pinned image mirrors no part of the binding into state, so the
  keyed binding is read from the running datastore in the intended direction and not the other,
  and the applied side is each entry programmed on the bound direction only (read through the
  device metric collector, FR-100); the binding in state and the per-subinterface entry list are
  recorded, never judged. FR-100's
  rule that a device-wide count is never evidence is the rule here too — it is stated there, once —
  and this is the case that shows why: a stock device already carries filters of its own. A
  property the platform has not observed MUST NOT be reported as converged. Readiness MUST NOT
  depend on passing traffic; dataplane enforcement is demonstrated separately, in acceptance
  (SC-041).
- **FR-043**: A request that would bind an access list to an attachment subinterface another service
  has already bound one to, in the same direction and for the same address family, MUST be refused
  before anything is created, naming the service that holds the binding; the platform supports one
  filter of an address family per subinterface per direction, so a second is unsupported, not merely
  ambiguous. An existing binding is never displaced, never merged into, and never joined by a second
  list. A service that is being removed still holds its bindings until it is gone, and the refusal
  says so. Withdrawal MUST remove the binding before the filter, and a service whose attachment
  still carries another service's access list MUST NOT finalize until that list is withdrawn,
  surfacing the holder by name. *(Closes GAP-4.)*

#### 5. Migration compatibility and provenance

- **FR-044**: The platform MUST maintain a migration alias catalogue that folds each retired
  service-provider vocabulary name onto the construct it becomes — multipoint L2VPN and its
  point-to-point variant onto `mac-vrf` with an L2VNI, the routed VPN name onto `ip-vrf` with a
  routed instance, L3VNI and route targets, and the integrated L2/L3 name onto `mac-vrf` with an
  anycast gateway. Inputs in the retired vocabulary MUST continue to be accepted, folded on entry
  before any validator or translator sees them, and MUST produce the same fabric outcome as
  before the vocabulary changed. A folded name MUST NOT appear in any output as a type.
- **FR-045**: Translation MUST be deterministic and MUST reject unmapped or lossy source
  properties before any device mutation; unsupported features MUST be enumerated in status. Raw
  device CLI is never an accepted translation input. Limited equivalence — a point-to-point
  service represented by a dedicated L2VNI — requires explicit opt-in and a durable status
  finding.
- **FR-046**: A service that arrived in the retired vocabulary MUST record which vocabulary it
  arrived in, distinct from the construct it became. That record — the provenance annotations on the
  service intent object — is the **single** provenance record for both construct provenance and
  migration provenance; no second record of the same fact may exist. *(Closes GAP-2.)*
- **FR-047**: Constraints that belong to a source vocabulary rather than to the construct MUST
  continue to apply to inputs arriving in that vocabulary, and MUST NOT be imposed on requests
  that name the construct directly.
- **FR-048**: Migration provenance MUST be carried as labels and annotations on the generated
  service intent object (FR-046). If an auditable cutover workflow is required, the implementation
  MAY add only the proposed `MigrationPlan.agentic-netops.io/v1alpha1` CRD defined in the API
  contract; a `MigrationPlan` references the service intent object's provenance rather than
  restating it, and records the construct the service became alongside the source vocabulary it
  arrived in. It is not installed unless asked for; its controller records and MUST NOT create or
  modify a service intent object; and it carries no route target, VLAN or VNI policy of its own —
  those are derived or allocated exactly as FR-012 says, for a migrated service as for any other.
- **FR-049**: No runtime requirement, resource, image, configuration or documentation under this
  platform MAY depend on a proprietary vendor controller, network services orchestrator, network
  controller product, vendor fabric-automation product, proprietary network element driver, or the
  retired system name. The network operating system image is the one vendor artefact in the
  dependency graph; nothing that manages it may be.

#### 6. Intent tier: conversation, interpretation and assignment

- **FR-050**: The platform MUST accept a network service request as free-form natural language
  and classify it into one of: a provisionable service request, an informational question, or an
  unsupported or unsafe request.
- **FR-051**: The platform MUST orchestrate a fixed pipeline of four specialist stages —
  conversation and routing, interpretation, resource assignment, and submission — where each stage
  has a single responsibility and a schema-validated output contract.
- **FR-052**: The platform MUST maintain conversation state per thread so an operator can refine a
  request across several messages without restating it, and MUST scope every stage's work to the
  thread it belongs to.
- **FR-053**: The platform MUST bound orchestration work per request with an iteration limit and a
  wall-clock timeout, and MUST report a bounded exit as an explicit outcome rather than hanging. Both
  bounds have stated defaults ([data-model.md](./data-model.md) §25) and are configuration, not code.
- **FR-054**: The platform MUST record and expose a workflow status for every request drawn from a
  closed set covering at minimum: received, interpreted, assigned, approved, submitting, converged
  and failed. The set also carries an **indeterminate** status for a request whose outcome the
  platform cannot observe — a transport or state loss mid-request — and that status MUST NEVER be
  reported as a success: it is neither converged nor confirmed, it never satisfies a convergence
  watch (FR-067), it is never counted as a converged request in the per-stage success rate
  (FR-092), and what the operator is told instead is that the outcome is unknown, which
  dependency was lost (NFR-010) and that the service's live state is the record (FR-105). The full
  enumeration is in [data-model.md](./data-model.md) §17, and no status outside it may appear
  anywhere. The same rule holds one layer down: a service intent object reporting `Ready=Unknown`
  (FR-107) is not a converged service, and a status answer built from it says its readiness is
  unknown and names the target that could not be read. *(The success-rate clause, which `AD-37`
  recorded and this text did not carry, and the `Ready=Unknown` sentence added by the fifth
  analysis pass of 2026-09-21, AD-49 and AD-40.)*
- **FR-055**: The platform MUST obtain explicit operator confirmation after interpretation and
  again after resource assignment, and MUST NOT submit anything to the cluster without the second
  confirmation.
- **FR-056**: The platform MUST allow an operator to decline at either confirmation point, and on
  decline MUST release any provisionally claimed identifier and leave the fabric unchanged.
- **FR-057**: The platform MUST answer informational questions about the fabric and its own
  capabilities — the status of an existing service among them (FR-069) — without entering the
  provisioning pipeline, and so without a confirmation: nothing is changed by an answer.
- **FR-058**: The platform MUST convert a natural-language request into a structured
  interpretation containing at minimum the construct, the tenant, the endpoint list and a
  generated service identifier, and MUST validate that interpretation against a published schema
  before proceeding.
- **FR-059**: The platform MUST identify the specific missing or ambiguous fields in an
  under-specified request and ask for them, rather than substituting defaults for service-defining
  values.
- **FR-060**: The platform MUST assign concrete fabric resources for a supported interpretation —
  overlay identifiers, attachment VLANs and the derived import/export route targets — and
  MUST emit them in the normalized service-intent contract that the single translation
  implementation already consumes, **so that no second translation implementation exists**. Intent
  becomes fabric intent in exactly one place; the access-list render is a field on the same fabric
  intent object, not a second path.
- **FR-061**: The platform MUST detect and reject a request whose construct or properties have no
  equivalent in the target fabric, naming the exact unsupported properties, and MUST NOT produce a
  partial assignment for it.
- **FR-062**: The platform MUST obtain every allocated identifier — VLANs and VNIs — from the
  existing allocation authority rather than generating one locally, MUST claim only what the
  requested construct's profile allocates, MUST treat "this construct claims nothing" as a success
  rather than an error, and MUST surface an allocation collision or exhaustion as a request failure
  with the conflicting value named. Identifiers the platform derives rather than allocates (FR-012)
  MUST be shown in the assignment exactly as they will be rendered, so the second confirmation
  covers them too. **The VLAN space MUST be split into two disjoint bands**, so that a value the
  authority allocates can never be a value an operator named: `100–999` is the **naming band**, the
  only band an operator may name a VLAN from, and nobody claims it; `1000–4000` is the **allocation
  band**, the VLAN index's own range, from which every allocated VLAN comes and in which every
  value is claimed. **A VLAN is allocated only for a `vlan` or a `mac-vrf` whose operator named
  none**: an `ip-vrf` attachment's VLAN is named or absent — absent being the untagged
  subinterface — and the platform MUST NOT allocate one (FR-109). A named VLAN outside `100–999`, and any VLAN outside `100–4000`, MUST be refused
  with **both bands stated** — one below `100`, one in `1000–4000` and one above `4000` alike, so
  the published interpretation schema MUST NOT bound a named VLAN from above and MUST floor it only
  at zero — every integer an operator can type, `0`, `4095` and `5000` included, reaches the mapper —
  and never turn one of them away itself with neither band stated. On the intent-tier path the naming band MUST be enforced **at
  interpretation, by the mapper, before any claim exists** — the one point at which a VLAN is known
  to have been *named*. The translator runs after the allocator, on an input in which a named VLAN
  and an allocated one are the same integer: it MUST check the structural `100–4000` only, and no
  provenance field is added to the normalized service intent to let it do more. The VLAN a
  standalone `acl` names is a **reference** to a subinterface another service created, not a VLAN
  of its own, and is exempt from the naming band (and, for an object applied with cluster tooling,
  from the claim rule of FR-109). Because the bands do not overlap, an allocated VLAN can never collide
  with a named one and the platform MUST NOT try another value silently in any case; two services
  asking for the same (node, port, VLAN) — necessarily two **named** VLANs — are still refused by
  the one-owner rule of FR-034 before anything is created, naming the VLAN, the port and the holder.
  A claim is the tier's to release only while it is provisional: once the service it backs has been
  submitted, the provider holds it and releases it (FR-109). Which correlation identifiers are
  still provisional is the **deployer's** to determine and never the allocator agent's, which reads
  no service intent object at all — that requirement is FR-075's, stated there once and cited here.
  *(Extended by the fifth analysis pass of 2026-09-21: where the naming band is enforced, AD-41;
  the standalone `acl`'s VLAN as a reference, AD-47. By the sixth analysis pass of 2026-09-21:
  no VLAN is allocated for an `ip-vrf`, AD-51; the interpretation schema's bounds are structural,
  so that the mapper's refusal is the one an operator reads, AD-56. By the seventh analysis pass of
  2026-09-21: the interpretation schema carries no upper bound at all, a VLAN of `4095` or above
  having still failed schema validation with neither band stated, AD-61.)*
- **FR-063**: The platform MUST produce a byte-identical assignment for a re-submitted identical
  request within a thread, or explicitly report that the earlier service already exists.
- **FR-106**: The model-provider configuration — the model name, the API key and the base URL — MUST
  live in one generated Kubernetes Secret and nowhere else. A model gateway (a shared endpoint that
  fronts one or more providers) MUST be declared as one at provisioning, and a declared gateway with
  no base URL MUST be refused before any tier workload is created, so that the gateway library's
  built-in default endpoint is never used silently. Re-provisioning MUST preserve the base URL an
  existing Secret carries unless the operator explicitly supplies a different one or explicitly
  clears it; omitting it from a later run is neither. The Secret MUST be written key by key — an
  omitted key keeps the value the Secret carries and is never deleted — and clearing the base URL
  MUST take a named input of its own, so that no ordinary run can drop it by accident.
  Provisioning output and every agent's start-up
  log MUST name the endpoint model calls will go to — the base URL, or the provider's own default
  stated as such — **with any credential the base URL embeds redacted under FR-079**, so that naming
  the endpoint never prints a secret and redaction never hides which endpoint is in use. An agent
  whose Secret declares a gateway without a base URL MUST refuse to
  start, and one whose Secret loses its base URL while it is running MUST stop calling the model and
  report the missing base URL rather than fall back to the library default. *(New; analysis
  2026-09-20; carries the constitution's secrets and LLM-configuration
  constraint; key-by-key writing, the redaction rule and the running-agent case added by the
  operator review of 2026-09-20.)*

#### 7. Intent tier: submission, convergence and inter-agent transport

- **FR-064**: The platform MUST express every agent-originated fabric change exclusively as a
  declarative service intent resource submitted to the cluster API.
- **FR-065**: The platform MUST validate a resource against its schema and reject it locally
  before submission, so a malformed agent output cannot reach the cluster.
- **FR-066**: The platform MUST submit a request's resources atomically — either every resource
  for that service is created or none is — and MUST report a partial-submission failure with the
  resources that were rolled back. Every object of a submission MUST pass a **server-side dry-run**
  before anything is applied, and any rejection aborts the whole bundle with the rejecting object
  named and nothing mutated; FR-065's local validation comes before it and never replaces it, because
  only the API server evaluates the structural schema, the cross-object rules and admission
  ([contracts/kubernetes-objects.md](./contracts/kubernetes-objects.md) §Submission contract).
  *(The server-side dry-run — the constitution's own word for this step, until now normative only
  in the contract and in T092 — stated here by the fifth analysis pass of 2026-09-21, AD-50.)*
- **FR-067**: The platform MUST watch each submitted resource until it reports Ready, reports a
  terminal failure, or a convergence timeout elapses, and MUST report which of the three occurred.
  `Ready=Unknown` (FR-107) is none of the three and is never read as Ready: a watch that sees it
  keeps watching until one of them occurs. A watch that sees `Ready=False` with the reason
  `Deleting` (FR-103) — the object deleted under it — has seen a terminal failure: it ends naming
  the deletion, and, the tier having asked for no removal of that object, reports it as deleted
  outside the tier (FR-105). A **removal's** watch is a different watch with different endings, and
  FR-069 states them. *(The `Ready=Unknown` sentence added by the fifth
  analysis pass of 2026-09-21, AD-40; the `Deleting` sentence and the pointer to the removal's
  watch by the seventh analysis pass of 2026-09-21, AD-63.)*
  The convergence timeout has a stated default ([data-model.md](./data-model.md) §25) that fits inside
  SC-023's five minutes.
- **FR-068**: The platform MUST stamp each submitted resource with the correlation identifier of
  the originating request.
- **FR-069**: The platform MUST support querying the status of an existing service and removing a
  service it created. **Removal is a change** and is subject to the same two-confirmation requirement
  as creation (FR-055). **A status query changes nothing and takes no confirmation**: it is answered
  as an informational request (FR-057), from the live object (FR-105), without entering the
  interpretation, assignment or submission stages. It is still asked by an authenticated operator
  (FR-102) and carried on a request trace under that principal (FR-090), and an out-of-band change
  it detects is an audit event (FR-078). **A removal ends when the object is observed gone, or says
  what it is still waiting for**: after both confirmations the platform MUST delete the service
  intent object and watch it until it no longer exists, bounded by the same convergence timeout as
  a creation (FR-067; [data-model.md](./data-model.md) §25). Gone within the bound, the removal MUST
  be reported complete. Still present at the bound, the turn MUST end reporting the removal as **in
  progress** — never as a success and never as a failure — naming what the object's deletion
  condition says is outstanding (the unreachable target or the holding service, by name), and
  saying that it completes without operator action when that ends, or by the operator force-release
  that is never the tier's to set (FR-103); a later status query answers from the live object. An
  accepted delete is never reported as a completed removal, because the platform has not observed
  one (constitution Principle I). Both endings use the closed status set of FR-054 as it stands
  ([data-model.md](./data-model.md) §17). *(The confirmation requirement scoped to removal by the
  fifth analysis pass of 2026-09-21, AD-50: "each" had put two confirmations in front of a read;
  the removal's watch and its two endings stated by the seventh analysis pass of 2026-09-21,
  AD-63.)*
- **FR-070**: The platform MUST carry supervisor-to-worker communication over a message transport
  using a published agent-to-agent protocol, so workers are independently addressable processes
  rather than in-process function calls.
- **FR-071**: Each worker MUST publish a capability descriptor the supervisor discovers at
  runtime, so adding or replacing a worker does not require changing the supervisor.
- **FR-072**: The platform MUST authenticate the transport and MUST NOT accept an unauthenticated
  worker registration.
- **FR-073**: The platform MUST apply a per-call timeout and a bounded retry with backoff to
  worker calls, and MUST distinguish "worker unreachable" from "worker returned a failure" in what
  it reports. The timeout, the retry count and the backoff have stated defaults
  ([data-model.md](./data-model.md) §25).
- **FR-074**: The platform MUST report which specific worker is unavailable when one is, and MUST
  keep the conversation resumable rather than discarding thread state.
- **FR-105**: The cluster, not the conversation, is the record of a service. At submission the
  intent tier MUST stamp the service intent object with a hash of the `spec` it submitted —
  computed from the server-side dry-run result, so that the stored hash is comparable with a later
  read ([contracts/network-spec.md](./contracts/network-spec.md) §3) — under an
  annotation key it owns (FR-101). On every status or removal request (FR-069) — and when a
  convergence watch it already holds open sees the object being deleted (FR-067, AD-63) — it MUST re-read the
  object and, where the live `spec` no longer matches that hash or the object no longer exists, MUST
  state plainly that the service was modified or deleted outside the tier, reporting the live state
  and never the remembered one. The tier MUST NOT revert, re-create or overwrite such a service; any
  further change is a new request with its own two confirmations: a removal asked of a service
  already found modified outside the tier MUST NOT be executed by the turn that detects it — the
  modification is stated at that request's first confirmation, and the removal proceeds only
  through both confirmations. The comparison is over `spec` alone, so an edit to a label
  or an annotation, the hash annotation's own key included, is not an out-of-band change. Detection
  is deliberately **on demand** — there is no continuous watch — and it works from any thread,
  because the hash is on the object and not in the conversation. Each detected out-of-band change
  MUST be recorded as an auditable event and counted in a tier metric. *(New; clarification
  2026-09-20; the hash's source, the `spec`-only scope, the refused removal and the on-demand,
  any-thread rule added by the operator review of 2026-09-20; the removal of a modified service
  restated as the data model has it — stated at the first confirmation, executed only through both
  — by the sixth analysis pass of 2026-09-21, AD-58; a deletion seen by an open convergence watch
  counted as a detection — it is a read the tier is already making, not a continuous watch — by the
  seventh analysis pass of 2026-09-21, AD-63.)*

#### 8. Safety boundary

*These five requirements are the block a reviewer reads on its own. They are contiguous and
unbroken by design, and the delivery sequence in [plan.md](./plan.md) builds and proves them
before any agent is deployed.*

- **FR-075**: The intent tier MUST NOT open a device session, issue a device command, or write
  device configuration by any path. **This is an absolute constraint, not a default.** It MUST be
  enforced structurally and not only behaviourally. The tier's workloads run in their own namespace
  and hold exactly two cluster identities with any permission at all: the **deployer**, which may
  create, read, update, patch and delete service intent objects — and publish Events — in the intent
  namespace and nowhere else (delete is what rollback, FR-066, and removal, FR-069, need, and patch
  is what server-side apply needs; neither update nor patch reaches the operator's force-release
  annotation, which admission denies to both tier identities whatever their verbs, FR-103); and the
  **allocator agent**, which may create, read and delete — never update or patch — allocation claims
  in the allocation namespace and nothing else there (FR-062). The allocator agent MUST hold **no
  verb on service intent objects in any namespace**: where the release path needs to know whether a
  service has been submitted, the **deployer** MUST determine it and name the releasable correlation
  identifiers, and the allocator MUST delete only what it is told to — the one statement of that
  rule, which FR-062 and FR-109 cite. Every other tier workload
  holds no cluster permission. No tier identity has access to device credentials, controller-owned
  resources, the fabric design, the device-configuration or inventory APIs, or the device
  management network **on any port and any protocol** — the encrypted management port, the plaintext
  management port the lab image also exposes, the shell, the monitoring port, the ports the image
  reserves for the vendor's automation product whether or not it is used, and every other
  programmatic interface alike — so that the forbidden action cannot be expressed even by an agent
  that tried. The denial MUST be attemptable: the probe set MUST be **every port the pinned image is
  documented to expose**, stated in one place and cited everywhere else, never the set the platform
  itself uses, and it MUST be reconciled against the ports the image is observed to listen on
  (FR-004) rather than taken from a research report — as decided (AD-82
  `2026-09-24-loopback-listeners`), every socket not bound only to loopback; a loopback-only
  listener is recorded with its bind scope and is never a probe target. *(The deployer's `patch`, which the identity
  contract always granted and server-side apply needs, and the single statement of who determines
  what is provisional, written in by the fifth analysis pass of 2026-09-21, AD-47.)*
- **FR-076**: The platform MUST refuse any request to act directly on a device and MUST respond by
  naming the supported declarative equivalent.
- **FR-077**: The platform MUST treat all user-supplied text and all worker-returned text as data,
  never as instructions to itself, and MUST produce an unchanged proposal for a request whose text
  carries an embedded instruction.
- **FR-078**: The platform MUST record every confirmation, decline, submission, removal, refusal
  and detected out-of-band change (FR-105) as an auditable event carrying the requesting principal,
  the request correlation identifier and the resulting resource. A refusal here is one given to an
  authenticated operator; a request refused for want of a valid credential (FR-102) has no principal
  to record, never reaches the pipeline, and is counted in a metric and logged instead. **The record is the audit event carried on the request's trace and kept in the
  agent-analytics store** (FR-091) — for this purpose the explicitly added store FR-088 asks for. It
  MUST be kept in that store, with no expiry, for as long as the store exists, and MUST be exported
  with the run's evidence **before anything removes the store** — the shutdown script and the intent
  tier's removal alike, unconditionally and not only when evidence capture was asked for. The export
  MUST be written through the run-captured evidence path (NFR-013), so that it carries the command,
  its UTC time, its exit status, the device image digest and the cluster and lab identity beside the
  data; it MUST be newline-delimited JSON, one object per stored row with the field names the store
  holds, compressed, and it MUST be captured under an identifier unique to the attempt, so that a
  re-run after a stopped removal adds an artefact rather than rewriting one the evidence audit has
  already hashed (SC-040). A re-run MUST NOT repeat an export the lab's evidence already holds
  whole: where an earlier attempt's export is still **verified** the re-run skips the export and
  records that it did, naming the artefact it relied on, and in every other case it adds a new one.
  What *verified* means, and how a re-run finds an earlier attempt's artefact, is stated once, in
  [data-model.md](./data-model.md) §16. An export **fails** when the store is present but cannot be queried within
  the export bound, when the query errors, when the artefact cannot be written or when fewer rows are
  written than the store reported; a store that was never installed is skipped, and a store that
  returns no rows is a successful export of an empty record. A removal
  whose export fails MUST stop with the store intact; the only way past is an explicit, named
  discard flag whose use is printed and recorded in the run's evidence. After the export the
  evidence file is the record: it carries, per event, the principal, the correlation identifier, the
  resource reference and the submitted-spec hash, so that the stream half of SC-030 and SC-042 can be
  reconciled from the file alone once the store is gone — and that reconciliation MUST be run
  against the exported file after the removal, because a record nothing has read back is not yet one.
  The operator usernames the run used MUST be captured with the run's evidence — the username only,
  never the password — before anything removes the operator credential, so that SC-042's half of
  that reconciliation depends on neither the store nor the Secret outliving the removal. The half of
  SC-030 that compares the stream against live objects MUST be run before the store and those
  objects are removed. *(The read-back, the usernames capture and the re-run rule by the fifth
  analysis pass of 2026-09-21, AD-46.)* A Kubernetes Event MAY mirror an audit
  event for cluster-side visibility, published only by an identity FR-075 permits to publish Events;
  an Event expires, and is never the record.
- **FR-079**: The platform MUST redact credentials and secrets from every prompt, log, trace and
  chat transcript. Redaction happens where the text is produced, so the audit-record export of
  FR-078 is a copy of already-redacted material and MUST NOT depend on a second pass at export time;
  the exported artefact is nonetheless covered by the credential scan that covers traces, because it
  is where those traces leave the cluster.

#### 9. Operator surface

- **FR-080**: The platform MUST provide a browser chat surface that renders each pipeline stage as
  a distinct labelled step with its structured payload readable.
- **FR-081**: The chat surface MUST present both confirmation points as explicit, refusable
  actions and MUST reflect convergence progress without a manual reload.
- **FR-082**: The chat surface MUST display a stage failure in operator-readable terms with the
  correlation identifier needed to retrieve the full trace.
- **FR-083**: The provisioning documentation MUST describe the four constructs, the variables each
  requires and accepts, what each renders on the device in the device's own object names, how
  access-list rules are ordered and what happens to unmatched traffic, and what remains unsupported.
- **FR-084**: Guided prompts, examples and refusal alternatives offered to operators MUST use
  construct names, and every prompt's nodes and ports MUST resolve against the site's real
  inventory.
- **FR-085**: The retired service names MUST appear in documentation only where they are
  identified as migration aliases or historical provenance.
- **FR-102**: The chat surface and the programmatic surface MUST both require an authenticated
  operator on every route that can reach the pipeline. The one exception is a liveness or readiness
  probe route — one that creates no thread, calls no model and claims no identifier — because a
  probe credential would be a credential literal in a manifest. Operator credentials MUST be generated into a Kubernetes Secret by the provisioning
  script and never committed, and removed by the shutdown script with the other generated secrets.
  The **password** MUST always be generated — never defaulted, and never accepted from a flag, the
  environment or a file; the **username** MAY take a documented default that the operator can
  override, because it identifies and does not authenticate. The requesting principal recorded on every audit event (FR-078), on every
  confirmation decision and on the submitted service intent object MUST be the authenticated
  username, never a name the caller asserts. An unauthenticated request MUST be refused before it
  reaches the pipeline — no thread is created, no model is called and no identifier is claimed.
  Rotating the credential MUST take effect without restarting a workload, and a thread continued
  under a different credential MUST record that credential's username on the decision it carries
  rather than inherit the first; the credential's shape, the refusal's form and the fixed
  failed-attempt delay are in [data-model.md](./data-model.md) §22.
  These are lab credentials and MUST NOT be presented as production-safe (FR-019); one operator is
  the reference scale, and multi-operator use is the recorded trigger for replacing them with an
  identity provider. *(New;
  clarification 2026-09-20; the probe-route exception, rotation and the continued thread added by
  the operator review of 2026-09-20.)*

#### 10. Observability

- **FR-086**: The device-configuration layer remains the configuration and drift plane and MUST NOT
  enable overlapping subscription-based metric ingestion for any device series collected by the
  device metric collector. The device metrics pipeline is defined in FR-089. Both are clients of the
  same device management server, whose session limit MUST be sized explicitly for the two together.
  They stay two: the scheduled re-verification adds no third client, a rule FR-107 states and owns.
- **FR-087**: The observability stack MUST include an upstream OpenTelemetry Collector, a
  Prometheus metrics store and Grafana, with a provisioned datasource, dashboards and actionable
  alerts. **The required alert set is enumerated once, by name, in
  [data-model.md](./data-model.md) §21** — link down, BGP session down, EVPN routes lost, failed
  reconciliation, stalled re-verification (FR-107), each pipeline stage stopped or refusing, and a
  duplicated device series — and "actionable" means each rule carries a severity, the identity of
  what failed and what the operator looks at next. *(The set named, so that SC-035's "specified
  alert" is decidable, by the fifth analysis pass of 2026-09-21, AD-50.)*
- **FR-088**: Prometheus MUST be the metrics store. This specification MUST NOT claim the
  OpenTelemetry Collector stores telemetry. Durable logs and traces are out of scope unless a log
  store and a trace store are added explicitly.
- **FR-089**: Device telemetry MUST use one selected pipeline. An in-cluster gNMIc subscribes over
  gNMI, in the device's native models, to the registered device path set — interface administrative
  and operational state, interface traffic rate and statistics, subinterface statistics, BGP
  neighbour session state and per-address-family route counts including the EVPN family,
  network-instance operational state, EVPN instance state, VXLAN tunnel endpoint state and counters,
  bridge-table MAC counts, route-table and tunnel-table summaries, per-entry access-list counters,
  and platform CPU, memory and application health. gNMIc exports OTLP metrics to the in-cluster
  OpenTelemetry Collector; the collector exposes normalized metrics for Prometheus; the collector's
  own health metrics are scraped so that every pipeline stage has evidence. Subscription-based
  ingestion for those same device series is disabled by FR-086, which owns that rule. For every
  registered path the derived metric name, label names and stream mode MUST be recorded in the path
  register (FR-017), and the topology and service views MUST join on the registered labels rather
  than on labels emergent from collector normalization.
- **FR-090**: The platform MUST emit a single correlated trace per request spanning every stage,
  each worker call, each model call, and the resulting resource convergence.
- **FR-091**: The platform MUST emit telemetry once at the source and fan it out to the
  destinations, rather than instrumenting the same activity twice. Two sinks are in scope: the
  fabric observability stack, and a dedicated agent-analytics store for per-conversation and
  per-model analysis. A single emission path feeding both is required; two independent
  instrumentations of the same activity are non-conforming.
- **FR-092**: The platform MUST expose per-stage request counts, success rate and latency
  distribution; confirmation and decline counts; refused-unsafe-request counts; and model call
  count with token usage or cost.
- **FR-093**: Agent-tier telemetry MUST carry the same correlation identifier as the fabric
  resource it produced, so agent activity, reconciliation and device telemetry join without
  timestamp correlation.
- **FR-094**: Grafana MUST provide a physical topology view and an EVPN service-path view: topology
  metadata generated from the containerlab inventory, link colour and width driven by state and
  utilization, traffic direction, node health, and drill-down from physical links to the service —
  the leaf-to-leaf tunnel path of a `mac-vrf` or `ip-vrf`, its tunnel endpoint state and counters,
  its MAC and route counts, and the hit counters of any access list bound to it. The join between
  topology assets and metrics MUST be exactly two registered labels: the node name and the
  normalized interface name (registered as `source` and `interface_name`). The published telemetry
  lab whose exposition pattern this view is drawn from is a **visualization and generator reference
  only**. Its panel schema, cell-identifier convention, metric-to-cell join contract and
  topology-generator tooling MAY be reused. Every reused artefact — dashboard plugin, generator
  image, panel configuration, topology drawing, dashboard definition — MUST be vendored into this
  repository, pinned by version or immutable digest in the lock file, and served to Grafana from
  inside the cluster. No panel, dashboard or datasource may resolve a configuration, image or asset
  from that lab's repository, branch or registry at run time, and no component of that lab's
  deployment stack may be adopted as a runtime of this platform.
- **FR-095**: The platform MUST provide a dashboard showing intent-tier health and per-stage
  behaviour alongside the fabric dashboards.
- **FR-096**: The provisioning script MUST generate or update the containerlab topology metadata,
  the topology panel resources **and the device metric collector's target list** from the same
  containerlab inventory in the same step, before readiness. Dashboards, topology assets, queries,
  plugins and the generator tooling MUST be pinned and provisioned inside the cluster without
  anonymous or admin-default access: the dashboards' administrator credential is generated into a
  Kubernetes Secret at provisioning and removed at shutdown like every other (FR-019).
- **FR-101**: Metadata stamped on the service intent object MUST have one owner per key. The
  translator owns the translation and provenance keys; the intent tier owns the correlation label,
  the tier label, the submitted-spec hash (FR-105) and the audit annotations; neither writes the
  other's keys, and the emission order of all keys is fixed. The provider MUST NOT stamp the service
  intent object at all: its source identity, generation, render hash, compatibility set and mapping
  version belong on the device configuration resources it generates. *(New in the retarget; closes
  GAP-3.)*

### Non-Functional Requirements

- **NFR-001**: Reapplying unchanged intent MUST produce zero device configuration changes.
- **NFR-002**: A single-device outage MUST NOT block status reporting for healthy targets. The
  telemetry path is likewise never in the configuration path: a failure anywhere in it — collector,
  pipeline or metrics store — MUST be observable as a failure of its own and MUST NOT block, delay or
  alter rendering, reconciliation, readiness or teardown, which read device state directly (FR-015,
  FR-100). Such a failure MAY set `Degraded` while network readiness stands, with the reason
  distinguishing the two. As decided (AD-82 `2026-09-21-state-source`), the pinned
  device-configuration layer serves no state datastore, so readiness's applied side is read from the
  device metric collector (gNMIc through the OpenTelemetry Collector's exporter), installed with the
  targets rather than with the rest of the observability stack; a failure of that part of the path
  is therefore a read-back that cannot run — `Ready=Unknown` with `VerificationFailed` (FR-107),
  never a false `Ready=True` or `Ready=False` — while the metrics store, dashboards and alert rules
  stay out of the readiness path and a failure there alters nothing above.
- **NFR-003**: All images, charts, CRDs, API services, YANG models, schema patches, dashboard
  plugins, generator tools and upstream repositories MUST be pinned to a release tag backed by an
  immutable digest or to a commit; `latest`, a floating minor tag and a branch reference are
  forbidden wherever a reference can appear, including inside the device-configuration layer's
  schema definition — where, as decided (AD-75), the pinned schema commit, which upstream carries
  under no tag, is served from an in-cluster git mirror asserted equal to the locked commit and
  exposed under a tag named after it (the lock still recording the upstream repository and commit),
  and the first-party schema-deviation module is served by the same mirror at a content-pinned tag
  (AD-82 `2026-09-21-feature-guarded-must`). A placeholder or synthetic digest is forbidden, and the pin check MUST resolve
  every digest against its registry so that an unpullable pin fails before provisioning rather than
  during it. Intent-tier images MUST have a local build step and MUST be pinned in the same lock
  file as everything else; any exception MUST be warned at provisioning time and documented with a
  remediation plan. This specification admits exactly **one** such exception — the recorded
  allocator substitution of FR-104, warned by name on every provisioning run, its decision record
  being its remediation plan. Anything else the pin check cannot hold is a failure, never a warning,
  and the lock file has no field in which another exception could be declared; admitting one is a
  change to this requirement that names it, its warning and its remediation plan. Host-side test and
  recording tooling that ships in no image — the browser-automation package, the browser build it
  drives, and the screen-capture and video tools of the recorded walkthrough — is pinned like
  everything else and is not an exception: the package by exact version and hash in the tier's
  dependency lock, the browser by the build that package version fixes, and each host tool by the
  version the lock file records, which the pin check compares with the host before the suite that
  uses it runs. None of it is a platform component and none of it runs in the cluster.
  A first-party image — the provider's and the intent tier's — is built locally and
  exists in no registry, so it is pinned by its **build inputs**, which *are* resolvable: every
  `FROM` by a registry-resolved digest recorded in the lock file, and every dependency set by the
  hash of its lock file. It MUST be tagged with the content hash of its build context — never
  `latest` and never a reusable tag — loaded into the cluster and run with a never-pull policy, and
  the identity of the image each build produced MUST be recorded in that run's evidence and checked
  against the running workloads. The pin check MUST fail a first-party image whose `FROM` is not a
  locked digest, whose dependency lock file does not match its locked hash, or which any manifest
  references by a mutable tag.
- **NFR-004**: The reference lab MUST be reproducible on a documented Linux host with a container
  runtime and no hypervisor: the documentation MUST state the CPU instruction-set, kernel, memory
  and CPU requirements of the device image, the measured per-node footprint — observed by a
  clean-host run and taken from its evidence, never quoted from research — and the limits of the
  containerized dataplane — in particular its packet-rate ceiling — that acceptance tests must
  respect.
- **NFR-005**: Every reconcile outcome MUST be discoverable through conditions, Events and metrics
  without consulting controller logs alone.
- **NFR-006**: The intent tier MUST be deployable and removable independently of the declarative
  control plane. Removing it MUST leave every control-plane acceptance gate passing. This is a
  property of the system, not of the documents: the dependency arrow points from the tier to the
  control plane and never back. The services the tier submitted live in the tier's intent namespace,
  and removing the tier does **not** remove them unless the operator asks for that in the same
  command: the removal first lists them — a read that decides only whether to go on — and, while
  any exist, stops non-zero naming each one and the two documented continuations, having changed
  nothing. Given the removal-of-services flag it deletes them as any operator would — the tier's
  request-accepting workloads are scaled down first so that nothing new lands, the list of what
  will be deleted is taken **after** that scale-down, the audit record is exported (FR-078), the
  removal waits a bounded time for their finalization, and where one is blocked (FR-103) it stops
  non-zero naming the service and **what its deletion awaits** — the unreachable target, or the
  service that holds a binding on its attachment (AD-72) — with the rest of the tier still in place. It MUST NOT
  force-release. On **every** path that goes past the refusal — the flag given, or no flag and
  nothing to refuse over — the scale-down MUST precede the audit export, so that no audit event is
  written after it; and without the flag, a list taken after the scale-down that is not empty MUST
  fall back to the refusal, having deleted nothing and exported nothing, with re-provisioning named
  as what restores the scaled-down workloads. A teardown that
  destroys the whole environment removes everything with it and needs no such flag; it still exports
  the audit record first. Services applied with cluster tooling elsewhere are not the tier's and are
  untouched. *(Default reversed by an operator decision, 2026-09-20 — AD-35. The two lists told
  apart, and the scale-down put before the export on every path, by the fifth analysis pass of
  2026-09-21, AD-46.)*
- **NFR-007**: The intent tier MUST NOT modify any control-plane resource schema, controller or
  reconciliation contract. Any needed change is a control-plane change, specified as one.
- **NFR-008**: Model provider choice MUST be configurable without code change, and the platform
  MUST remain functional when switched between at least two providers.
- **NFR-009**: Every model interaction MUST be reproducible for review: the prompt, the model
  identity and the response MUST be recoverable from the trace for any request.
- **NFR-010**: The intent tier MUST degrade legibly. When the model provider, the transport or the
  cluster API is unavailable, it MUST report that specific dependency as the cause rather than a
  generic failure.
- **NFR-011**: Bring-up, teardown and per-stage failure diagnosis MUST be documented to one
  runbook standard across the fabric and the tier, sufficient for someone who did not build either.
- **NFR-012**: The intent tier MUST run within the resource envelope of the existing single-host
  lab without displacing the fabric workloads. The envelope is what the host-resource preflight
  checks, not an adjective: the fabric phase's threshold — the per-node CPU and memory headroom for
  each SR Linux node plus the cluster's own budget, stated in [quickstart.md](./quickstart.md)
  §Prerequisites and enforced before anything is created (NFR-004) — **extended, before the tier
  phase mutates anything, by the sum of the requests the tier's workloads declare**; every tier
  workload MUST declare requests and limits, so that the sum exists. The measure is a comparison of
  recorded values, none of them quoted from research: the per-node footprint the clean-host run
  measured (NFR-004) plus the tier's summed requests fits under the host's available CPU and
  memory, and "without displacing" means that **after the tier is Ready every fabric workload, all
  four device targets and the fabric design are still Ready, with no fabric pod evicted, restarted
  or killed for memory** — re-checked by the tier's health acceptance and recorded in its evidence
  (NFR-013). *(The envelope and its measure stated by the fifth analysis pass of 2026-09-21, AD-50;
  no figure is added here that a run has not produced.)*
- **NFR-013**: Every gate and acceptance result MUST be evidence captured by the run that claims it:
  the command, its UTC time, its exit status, the device image digest and the cluster and lab
  identity recorded together with the raw output. A hand-authored or post-edited proof is
  non-conforming. A readiness or acceptance check counts only after it has been shown to **fail**
  against a stock fabric that does not carry the thing it checks for; a check that passes on an
  empty fabric is a defect, not a result. *(New in the retarget; answers the inherited acceptance
  record.)*
- **NFR-014**: Every first-party workload — the provider, the translator and every intent-tier
  process — MUST write structured logs: one JSON object per line carrying a UTC timestamp, a level,
  the component, a message and, wherever one exists, the resource identity and the request
  correlation identifier (FR-068), redacted under FR-079. The field names, the level set, the
  timestamp format and the stream a consumer reads are fixed in one place,
  [data-model.md](./data-model.md) §27, and nowhere else. A log line is a diagnostic aid and never
  the only record of an outcome (NFR-005). The lifecycle scripts log with a consistent level and
  phase prefix and need not emit JSON: they are read by the operator watching a run, not by a log
  consumer, and every outcome they report is also a condition, an Event or a metric — so
  constitution Principle IV's structured-log rule is carried where a consumer exists to read it.
  *(New; analysis 2026-09-20, second pass; carries constitution
  Principle IV's structured-log rule; the deferral to §27 and the reasoned script exclusion added by
  the operator review of 2026-09-20.)*

### Constitution-Mandated Requirements

Derived from `.specify/memory/constitution.md` v1.1.0 (ratified 2026-09-05, amended 2026-09-20 for
the SR Linux platform). Each row names the
composite requirements that carry it, so the gate check in [plan.md](./plan.md) has something to
point at.

- **CR-001**: The platform MUST report readiness only from live, verified fabric state, and MUST
  name any missing invariant (routes, VTEPs, BGP sessions, data path) in its status conditions
  rather than reporting ambiguous success, re-verifying it on a schedule rather than remembering it.
  (Principle I; carried by FR-018, FR-042, FR-067, FR-100, FR-107, NFR-005, NFR-013)
- **CR-002**: Any provisioning path **through the intent tier** MUST require two explicit human
  confirmations and MUST NOT provision from a one-shot request. An operator applying a service
  intent object directly with cluster tooling is acting under their own cluster authority, not
  through the tier, and is outside this rule. The tier MUST NOT present or provision a service type
  the operator did not ask for: what it proposes is the construct the request named and what that
  construct's profile allocates, nothing beside it. (Principle II; the confirmations carried by
  FR-055, FR-056; the asked-for type by FR-024, FR-029, FR-032, FR-059, FR-062)
- **CR-003**: Inputs naming non-existent nodes or ports MUST be refused up front, and the refusal
  MUST enumerate valid alternatives. (Principle II; carried by FR-034, FR-059, FR-061, FR-097 — the
  enumeration itself by FR-034's site-inventory validation, asserted by T056 at admission, by T091
  in the refusal fixtures and by T098 in the mapper)
- **CR-004**: Changes MUST be applied as translate → server-side dry-run → apply → rollback on
  failure → convergence watch; reconciliation and teardown MUST be idempotent, and unrenderable
  objects MUST NOT be stranded. (Principle III; carried by FR-010, FR-015, FR-016, FR-018, FR-045,
  FR-065, FR-066, FR-067, NFR-001 — the device transaction's rollback on rejection by FR-015, and
  the translation that leaves nothing behind by FR-045.) *(FR-015 and FR-045, which the plan's gate
  row already cited, added to the carriers by the seventh analysis pass of 2026-09-21, AD-65.)*
- **CR-005**: The platform MUST emit the gNMI → Prometheus → Grafana telemetry needed to verify
  underlay and overlay health, and its logs MUST be structured and its controller conditions
  surfaced. (Principle IV; carried by FR-087, FR-088, FR-089, FR-094, NFR-005, NFR-014)
- **CR-006**: New images and binaries MUST be pinned in the lock file; any exception MUST be
  documented with a remediation plan and warned at provisioning time — and exactly one is admitted,
  the recorded allocator substitution. (Principle V; carried by NFR-003, FR-017, FR-098, FR-104)
- **CR-007**: A gate MUST NOT be waived to make a run pass; a capability that cannot hold is
  documented and the affected service reports `Ready=False` or is refused by name. (Principle VI;
  carried by FR-004, FR-097, NFR-013)
- **CR-008**: Credentials MUST never be committed; a declared model gateway MUST have a base URL so
  that the library default is never used silently; and re-provisioning MUST preserve an existing
  Secret's base URL unless it is explicitly changed. (Additional Constraints — Secrets and LLM
  configuration; carried by FR-019, FR-079, FR-102, FR-106)
- **CR-009**: The fabric MUST run the constitution's Jumbo MTU envelope — fabric port MTU **9412**
  (as decided, AD-82 `2026-09-21-access-port-mtu`: the port MTU on every port the fabric owns,
  fabric links and access ports alike, with the tenant IP MTU on every routed service subinterface
  and 9412 as the L2 MTU on every bridged one), underlay IP MTU **9398**, tenant IP MTU **9348** for both tenant address families, the VXLAN
  tunnel endpoint being IPv4 — and endpoint interfaces MUST be set to 9348. Acceptance tests MUST
  size their packets to it: the largest passing ICMP payload is **9320** (IPv4) and **9300** (IPv6),
  and one byte more MUST fail. Tests MUST NOT assert throughput. The five numbers are re-observed on
  the pinned image by capability-gate item G6 before any test relies on them; a number G6 does not
  reproduce is a failed gate item (CR-007), never a quietly adjusted probe. As decided (AD-78), G6
  asserts the commit-time refusal one byte above for the port MTU (9413) and the routed IP MTU
  (9399) only; the tenant boundary is the data-plane probe above, and the device's acceptance of a
  tenant IP MTU of 9349 at commit is recorded as an observation, not a refusal. (Additional Constraints
  — Network policy; carried by FR-002, FR-004, FR-020, SC-005; tasks T032, T043, T065.) *(New;
  fifth analysis pass of 2026-09-21, AD-50 — the numbers lived in the plan, the data model and the
  tasks, and nowhere in this document.)*
- **CR-010**: An IPv6 anycast gateway and IPv6 Type-5 origination have no published reference on
  this platform and MUST be treated as a capability-gate item, never as an assumption: the gate
  records whether the pinned image qualified them (FR-004, FR-097), and an unqualified IPv6 gateway
  is refused by name. Where the gate or a service's own read-back shows the IPv6 Type-5 route
  missing, the affected service MUST report `Ready=False` with a condition naming the missing route
  (FR-100) rather than claim success. (Additional Constraints — Known limitation; carried by
  FR-004, FR-097, FR-100; built by tasks T046, T116, T117 and tested by T115 — the read-back case
  with the IPv6 Type-5 route absent, and the unqualified-IPv6-gateway refusal fixture.) *(New;
  fifth analysis pass of 2026-09-21, AD-50; the testers named by the sixth analysis pass of
  2026-09-21, AD-58.)*

### Key Entities

Full field-level detail is in [data-model.md](./data-model.md).

- **Fabric design**: the first-party resource describing node roles, underlay addressing and ASN
  plan, the fabric-wide overlay AS, the MTU policy, the route-reflecting spines and the site
  inventory of attachable ports. Exactly one per fabric.
- **Inventory**: the allocation authority's node, link and endpoint records, aligned with the
  containerlab topology.
- **Network**: the first-party service intent object, carrying `vlans`, `bridgeDomains`,
  `routers`, `accessLists` and `attachments`. One per service, owned and reconciled by the control
  plane. It is the only *fabric intent* the intent tier writes — stamped by the tier with the
  originating correlation identifier — and, with the allocation claims the allocator agent makes
  (FR-062, FR-075), the only thing the tier creates outside itself.
- **Device target and configuration**: the device-configuration layer's schemas, target profiles,
  targets, configs, running state and deviations. One configuration resource per source object per
  affected device.
- **SR Linux provider**: the single controller that renders the fabric design and every `Network`
  into device configuration and sets readiness from read-back; it is not an independent source of
  truth.
- **Qualification record**: the capability gate's per-construct, per-property result, published
  read-only for the intent tier.
- **MigrationPlan**: the optional CRD recording normalized source intent, target `Network`,
  unsupported features, approval and cutover policy, and verification status.
- **Construct**: one of the four things an operator can ask for. A name, a required variable set,
  an optional set and a rendered outcome.
- **Service request (conversation thread)**: a durable operator-initiated conversation carrying the
  original text, the running workflow status, both confirmation decisions, the claimed identifiers
  and the correlation identifier that ties every downstream artifact together.
- **Interpretation**: the structured reading of a request — construct, tenant, endpoints, optional
  gateway and access list, generated service identifier — schema-validated, and the artifact the
  operator confirms first.
- **Resource assignment (normalized service intent)**: the concrete fabric parameters derived from
  an interpretation, expressed in the one contract the single translator consumes. The artifact
  the operator confirms second.
- **Attachment point**: a node and a port a service lands on, plus the VLAN or routed-instance
  context that applies to it. On the device it is one subinterface of that port — the untagged one
  when no VLAN is named — and it has exactly one owning service.
- **Anycast gateway**: the gateway addresses a `mac-vrf` carries and the routed instance they live
  in. Its presence is what makes the service a symmetric-IRB service.
- **Access list**: a named, staged, address-family-scoped, ordered set of rules and the attachment
  points it is bound to. Owned by exactly one service, created and withdrawn with it. Its name is
  a label, unique only within its own service.
- **Access-list rule**: a name, a distinct priority that is also its position in the evaluation
  order — ascending, first match wins, the last position reserved for the default action — an
  action, and the match conditions that select traffic.
- **Provenance record**: for a service that arrived in a non-construct vocabulary — including one
  that converged before the vocabulary changed — the vocabulary it arrived in and the construct it
  is reported as. Derived on read for pre-existing services; never written back to them.
- **Worker capability descriptor**: the runtime-discoverable declaration of what a worker does and
  how it is addressed, letting the supervisor route without compile-time knowledge.
- **Claim reference**: the allocation-authority claim object backing a value in an assignment, with
  its index, allocated value and release time.
- **Request trace**: the single correlated observability record spanning every stage, worker call,
  model call and convergence outcome for one request.
- **Audit event**: the immutable record of a confirmation, decline, submission, removal, refusal
  or detected out-of-band change, with
  principal — the authenticated operator username (FR-102) — correlation identifier and resulting
  resource. Carried on the request trace and kept in the agent-analytics store, which is the record
  (FR-078); a Kubernetes Event may mirror it and is not.
- **Force-release finding**: the durable record a force-release leaves on the fabric design — the
  service, the device, the identifiers released and the device objects that may still be there. It
  outlives the service object, refuses a render that would reproduce those objects, and clears only
  after the device has read back without them (FR-103; [data-model.md](./data-model.md) §3a).
- **Operator credential**: the generated username and password a request authenticates with, held
  in one Kubernetes Secret; the username is the principal on every audit event (FR-102;
  [data-model.md](./data-model.md) §22).
- **Path register**: the one statement of every device path the platform renders or subscribes to —
  the model chosen, the justification for any exception to the native default and, for a subscribed
  path, the derived metric name, labels and stream mode — guarded in CI (FR-017;
  [data-model.md](./data-model.md) §21, [plan.md](./plan.md) §Component inventory).
- **Compatibility set**: the pins that are qualified together and published as one — device image
  digest, YANG model tag, schema definition and deviation patch, the device-configuration and
  allocation releases with the allocation authority selected, containerlab, the collector and the
  provider's mapping version — held in the lock file (FR-017, FR-104, NFR-003;
  [data-model.md](./data-model.md) §23, §26).
- **Evidence record**: what a run captures for every gate and acceptance result — the command, its
  UTC time, its exit status, the device image digest and the cluster and lab identity beside the
  raw output — with the negative control recorded for each readiness check; never hand-authored
  (NFR-013, SC-040; [quickstart.md](./quickstart.md) §1, and [data-model.md](./data-model.md) §24
  for the recorded walkthrough's).
- **Log record**: one JSON object per line from every first-party workload, with the fixed field
  set, level set and timestamp format (NFR-014; [data-model.md](./data-model.md) §27).

## Success Criteria *(mandatory)*

### Measurable Outcomes

Every criterion below carries the negative control NFR-013 requires: it counts only once the check
has been shown to **fail** against a system that does not carry the thing it asserts. The rule is
stated here once and is not repeated per criterion; SC-040 audits it.

**Lab and lifecycle**

- **SC-001**: From a clean qualified host, the reference lab deploys all six nodes and all four
  device targets reach Ready using only the documented quickstart.
- **SC-002**: On a clean qualified host, the provisioning script reaches Ready for the Kind cluster,
  all required in-cluster applications, all four SR Linux targets and the default fabric without
  undocumented manual steps; running it again produces no destructive change.
- **SC-003**: The shutdown script succeeds from both fully provisioned and partially failed
  states, leaves no platform-owned cluster, containerlab or network resources, and succeeds again
  as a no-op.

**Declarative control plane and reconciliation**

- **SC-004**: 100% of expected underlay and EVPN BGP sessions establish, the required Type 2, 3 and
  5 routes appear for the services that require them in both address families, and no run counts as
  passed on established sessions alone — nor on fabric readiness alone, and not until the route
  half's negative control has been observed to fail. The session half, with the reflecting spines' reflection
  setting, is observed on the default fabric; the route half is observed with the first services
  that require it — a fabric that carries no service yet has no EVPN route to show, and the
  criterion is met only when both halves are. That negative control is a **declarative** fault: the
  reflection setting is withdrawn in the fabric design itself and rendered through the one
  southbound, the spanning service reports `Ready=False` naming the routes it lacks within the
  bound SC-044 measures while the fabric design reports not-Ready naming the spines and the
  setting, and the setting is restored and the restoration read back before the pass is admitted.
  It is never a device-side edit, which the revertive drift policy would race (FR-015) and which
  one spine could not show while the other still reflected. *(The control's mechanism stated by
  the fifth analysis pass of 2026-09-21, AD-43.)*
- **SC-005**: Cross-leaf L2 reachability, intra-routed-instance L3 routing, anycast-gateway
  reachability, inter-instance isolation and the tenant MTU boundary — the largest payload passes,
  one byte more does not — pass in a full clean lab run (a failed step may then be re-verified as a delta: fixed, and re-run on its own (`make test-acceptance-rerun`) against a lab built from the fixed tree, without repeating the steps that already passed, provided every automated suite passes on the final tree (`go build`, `go test` incl. envtest, `make test-static`, the agents' unit tests and the test-automation plan `testautomation/004-agentic-netops-composite/TEST_PLAN.md`) (operator decision 2026-09-28, supersedes 'three consecutive clean cycles'); within a run, a step that fails may be re-run **once** within its cycle and counts as passed only if the re-run passes; both attempts are recorded, and a step that fails twice fails the cycle (operator decision 2026-09-27)), asserting reachability
  and never throughput.
- **SC-006**: Applying unchanged intent twice changes zero device configuration specs and produces
  zero gNMI mutations on the second reconciliation.
- **SC-007**: Drift on a managed path is restored under the revertive drift policy — witnessed as
  gate item G13 observed it to be witnessable, by the recorded deviation where one is durably
  visible and otherwise by the restored value read back from the device — and drift on an unmanaged
  path is neither overwritten nor claimed.
- **SC-008**: A device or schema failure produces `Degraded` status and a target-specific reason
  within two reconciliation intervals — 30 s at the 15 s default interval
  ([data-model.md](./data-model.md) §25) — with no false aggregate Ready state: an object that had
  reported Ready and whose target can no longer be read reports `Ready=Unknown`, never a standing
  `Ready=True` and never a `Ready=False` that would declare an invariant lost (FR-107). *(The
  `Ready=Unknown` clause added by the fifth analysis pass of 2026-09-21, AD-40.)*
- **SC-043**: A service deleted while one of its leaves is unreachable keeps 100% of its allocations
  claimed and names the unreachable target for as long as the outage lasts — held for at least ten
  reconciliation intervals in the acceptance test with no release — and completes removal with zero
  operator action once the leaf returns; a force-release with a stated reason leaves a durable
  finding naming the device and the released identifiers, a force-release with an empty reason
  releases zero identifiers, and the finding clears only after that device has read back without
  the objects it names. *(New; clarification 2026-09-20; measures FR-103; the empty-reason and
  clearance halves added by the operator review of 2026-09-20.)*
- **SC-044**: A service that has reported Ready and then loses an applied-side invariant with no
  change to its intent — its remote tunnel endpoint or its EVPN routes withdrawn by a fault injected
  elsewhere in the fabric — reports `Ready=False` naming that invariant within one re-verification
  interval plus one reconciliation interval, and returns to `Ready=True` within the same bound once
  the fault is removed; the last-re-verified time in status advances on every interval in between.
  With the leaf instead cut from the management network — a re-verification that cannot run — the
  service reports `Ready=Unknown` and `Degraded=True`, both `VerificationFailed` naming that target,
  at the first pass that cannot read it — or sooner, when the reconciler sees the target not Ready
  between two passes, which SC-008 bounds at two reconciliation intervals after the cut — and
  **from that first `Ready=Unknown` until the leaf is reconnected** at no poll `Ready=False` and at
  no poll `Ready=True`; the last-re-verified time stops advancing; and `Ready=True` returns at
  the first pass after the leaf is reachable again.
  *(New; analysis 2026-09-20; measures FR-107; the cannot-run half added by the fifth analysis pass
  of 2026-09-21, AD-40; the polls anchored on the first `Ready=Unknown` — the `Ready=True` of the
  seconds before the platform can know of the cut is not a remembered one — by the seventh analysis
  pass of 2026-09-21, AD-62.)*
- **SC-045**: For a service intent object applied with cluster tooling and no intent tier present,
  100% of its VNIs are backed by a bound claim labelled with that object before its first device
  configuration resource exists; a second object naming a VNI already held is refused
  `Accepted=False` naming the value and the holder, with zero device configuration resources
  created; an object carrying a VLAN in the allocation band that no adoptable claim backs is refused
  `Accepted=False` naming the VLAN and both bands, again with zero device configuration resources,
  while one carrying a VLAN in the naming band is accepted with zero VLAN claims; and after deletion
  zero claims labelled with the object remain — verified by a claim-selector diff on
  `metadata.labels` before, during and after. *(New; analysis 2026-09-20, second pass; measures
  FR-109.)*
- **SC-046**: A service provisioned through the intent tier with no VLAN named — so that its VLAN
  was allocated, from the allocation band — records 100% of the claims carrying its correlation
  label, VLAN and VNI alike, as adopted while it exists, and leaves zero of them after removal, both
  when it is removed through the tier and when it is deleted with cluster tooling — a deletion that
  arrives before the provider has reconciled the object at all included, finalization adopting
  before it releases; a claim that matches on label and value under any other name is adopted for
  neither a VNI nor a VLAN; a `mac-vrf` whose VLAN was allocated and from which an attachment
  carrying that VLAN is removed while it lives still lists its VLAN claim as adopted until
  finalization; an `ip-vrf` provisioned with an attachment that names no VLAN has zero VLAN claims
  under its correlation label — none is ever allocated for it; and the tier deletes no claim of it on any path — verified by a claim-selector diff
  on `metadata.labels` before, during and after each removal. *(New; analysis 2026-09-20, third pass; measures the adoption half
  of FR-109. The name clause and the early-deletion clause added by the fifth analysis pass of
  2026-09-21, AD-42, AD-44. The held-claim clause restated on a `mac-vrf`, and the `ip-vrf` clause
  made a zero-claim one, by the sixth analysis pass of 2026-09-21, AD-51.)*
- **SC-009**: *Retired by the SR Linux retarget (RD-04) — SRv6 acceptance is deferred with the SRv6
  service. See §Deferred scope.*
- **SC-010**: *Retired by the SR Linux retarget (RD-04) — SRv6 status visibility is deferred with
  the SRv6 service. See §Deferred scope.*

**Construct vocabulary**

- **SC-011**: An operator can provision each of the four constructs by naming only the construct
  and its variables in a single request, and all four converge on the fabric — verified by one
  prompt per construct driven end to end through the tier, each asserted against the converged
  fabric objects it produced.
- **SC-012**: 100% of requests that name a construct and supply its required variables reach a
  converged service or a refusal that names a missing or invalid variable — none reach a state
  where objects exist but nothing converges. *Clarified by AD-72*: the criterion is measured on a
  fabric that is itself Ready; on a degraded fabric a confirmed request that cannot converge ends as
  the degraded-fabric edge case says — the object created, `Ready=False` naming what is missing,
  then the terminal failure or the timeout — which is a truthful outcome and not a breach of this
  criterion.
- **SC-013**: A newcomer — a person, or a fresh agent session under the operator's delegation (operator decision 2026-09-27) — who has read only the four cited device references — the device vendor's
  published documentation for bridged instances and VLAN subinterfaces, for Layer 2 EVPN-VXLAN, for
  Layer 3 EVPN-VXLAN with integrated routing and anycast gateway, and for access lists — can
  successfully provision each construct without consulting a translation table. For `mac-vrf` and
  `ip-vrf` the construct name is the word those references use.

**Access lists**

- **SC-014**: An access list can be provisioned both as a service and alongside a service, and after
  convergence its rules are readable back off every bound node — both as the configuration the
  platform wrote and as the device's own programmed state for that filter, keyed by that filter — in
  the order the operator declared.
- **SC-015**: Every invalid construct request is refused before anything is created on the fabric,
  and the refusal names the cause.

**Migration compatibility and provenance**

- **SC-016**: Every supported fixture renders the expected stable device configuration; every
  unsupported fixture is rejected before any downstream configuration is created.
- **SC-017**: A repository-wide CI deny-list enforces three boundaries with no matches outside the
  allowed contexts. (a) *Migration boundary* (FR-049): no dependency on a proprietary vendor
  controller, network services orchestrator, network controller product, proprietary network
  element driver, or the retired system name. (b) *Reference-artifact boundary* (FR-094, NFR-003): no runtime
  dependency on a third-party reference lab repository in the dependency graph — no image, chart,
  plugin, panel configuration, topology asset or dashboard resolved from such a repository's
  branch, release feed or registry at run time, and no unpinned installation of one; such
  repositories may be reused as visualization and generator patterns, and their artefacts may be
  vendored when pinned and carrying a provenance header. (c) *Placement boundary* (FR-007): no
  Compose or outside-Kubernetes deployment of platform applications. Allowed contexts: the "Scope
  and interpretation" section and this success criterion in this document, the corresponding rows
  of [platform-coupling.md](./platform-coupling.md), and citations in
  [research.md](./research.md).
- **SC-018**: Every service the platform could provision before the vocabulary changed can still
  be provisioned after it, with the same fabric outcome, and the emitted `spec:` block is
  byte-identical between the two vocabularies.

**Intent tier: conversation, interpretation and assignment**

- **SC-019**: An operator with no knowledge of the resource schemas can provision a supported L2
  construct and a supported L3 construct end to end using only natural language and the
  confirmation prompts — verified by a scripted operator session driven through the chat surface
  alone, with no resource schema consulted and no cluster tooling used.
- **SC-020**: For a corpus of at least 20 varied phrasings of supported requests, at least 90%
  produce an interpretation an expert reviewer judges correct on first attempt; every remaining
  case asks a clarifying question rather than proceeding on a wrong reading.
- **SC-021**: A resource assignment produced by the agents is equivalent to one hand-authored from
  the same intent, for every supported construct, verified against the single translation path's
  expected outputs.
- **SC-022**: The platform operates correctly against at least two distinct model providers with
  configuration change only.

**Intent tier: submission, convergence and transport**

- **SC-023**: A complete supported request reaches a converged service within 5 minutes on the
  reference lab, with the operator's own confirmation time excluded.
- **SC-024**: With one worker stopped, the platform names the unavailable capability, submits
  nothing, and resumes correctly once the worker returns — with the thread's state intact.
- **SC-025**: Removing the intent tier entirely leaves 100% of control-plane acceptance gates
  passing, demonstrated by a full gate run with the tier absent.
- **SC-026**: Declining at either confirmation point leaves zero fabric resources and zero
  identifiers claimed, verified by comparing allocation state before and after.

**Safety boundary**

- **SC-027**: 100% of requests naming an unsupported construct are refused with the specific
  unsupported properties named, and produce zero fabric resources — verified by running the
  dedicated unsupported-construct corpus and comparing fabric state before and after each refusal.
- **SC-028**: 100% of attempts to make the tier act directly on a device are refused, with zero
  device sessions opened, measured across a dedicated adversarial corpus including embedded
  instructions in user text. "Zero sessions" is measured **per source**: zero packets from any
  intent-tier pod toward the management address space, counted inside the cluster nodes ahead of the
  policy drop and of any source address translation — so that the device-configuration layer's and
  the metric collector's legitimate sessions are not in the count — by a counter first shown to move
  when a tier-labelled pod dials a device (NFR-013).
- **SC-029**: Both of the tier's cluster identities are demonstrably unable to read device
  credentials, modify controller-owned resources, or reach the device management network — verified
  by attempting each, as each identity, and observing denial, across the whole documented port set
  (FR-075) and not only the port the platform uses. A connection-oriented attempt counts when it is
  observed to time out; a connectionless one cannot, because no reply is indistinguishable from a
  silent server, so it is **recorded** and the denial is asserted instead by SC-028's per-source
  packet counter, which counts every protocol. A port the image is observed to listen on that the
  probe set does not cover is a failure of this criterion.
- **SC-030**: Zero tier-originated fabric changes occur without a recorded operator confirmation,
  verified by reconciling the audit event stream against the set of resources the tier created and
  their submitted-spec hashes. A change made to such a resource outside the tier is not a violation:
  100% of those injected in the acceptance test — the injected set being `spec` edits and deletions
  made with cluster tooling, which is the set FR-105 detects — are detected, reported to the
  operator as out-of-band and counted separately, and the tier writes nothing in response (FR-105).
- **SC-031**: Each request's prompts, model identity and responses are recoverable for review,
  with zero credentials or secrets present in any trace, log or transcript, verified by scanning
  the corpora of SC-020 and SC-028.

**Operator surface**

- **SC-032**: A person who did not build the tier — or a fresh agent session that has not read the implementation, run under the operator's delegation (operator decision 2026-09-27) — brings up the full stack from a clean host using
  only the written procedure, and confirms every agent healthy, within 30 minutes.
- **SC-033**: No operator-facing surface — prompts, messages, status, documentation — presents a
  retired service name as something an operator can ask for, including when reporting services
  that converged before the vocabulary changed — verified by a repository-wide vocabulary scan over
  the suggested prompts, the refusal strings, the chat surface's bundle, the documentation, the
  dashboards and the reporting of pre-vocabulary services, run as part of the boundary check, whose
  only permitted hits are explicitly labelled migration or provenance contexts.
- **SC-042**: 100% of unauthenticated requests to the chat surface and to the programmatic surface
  are refused with zero threads created, zero model calls and zero identifiers claimed, and every
  audit event's principal matches an operator credential that existed when the event was recorded —
  verified by attempting each surface without credentials and by reconciling the audit stream of
  SC-030 against the set of operator usernames the run used — the principal is the username, so a
  password rotation does not invalidate an earlier event, while changing the username mid-run
  invalidates the measure and the run records that it did not. That set, and the record that the
  username did not change, are captured with the run's evidence at the tier's bring-up and again
  before anything removes the operator credential (FR-078), so the measure is taken against the
  captured usernames and not against a Secret that the tier's removal deletes — and it is taken
  twice: against the store while the tier runs, and against the exported file once it is gone.
  *(New; clarification 2026-09-20; measures FR-102; the rotation qualification added by the operator
  review of 2026-09-20; where the usernames are captured, by the fifth analysis pass of 2026-09-21,
  AD-46.)*

**Observability**

- **SC-034**: The metrics store has healthy targets for the provider, the device-configuration
  layer, the device metric collector — including its own health endpoint — the telemetry collector
  and all qualified device telemetry sources; the dashboards load the provisioned fabric and
  orchestration views without manual datasource setup — verified by querying target health for each
  of those sources by name and by loading each provisioned view on a freshly provisioned lab.
- **SC-035**: A link or BGP failure and a failed reconciliation each trigger their specified alert
  — the one [data-model.md](./data-model.md) §21 names for it (FR-087) —
  during the acceptance test — verified by injecting each fault in turn during the acceptance run
  and observing the named alert fire and then clear. Every other alert of that required set is
  shown to fire and to clear as well: live, where the platform has a declared way to make the
  fault, and otherwise by a unit test of the rule over synthetic series, which is recorded as a
  rule test and never as a live firing; [data-model.md](./data-model.md) §21 says which is which.
  *(The rest of the set by the sixth analysis pass of 2026-09-21, AD-59.)*
- **SC-036**: The dashboards load provisioned physical-topology and EVPN service-path views whose
  node and link set exactly matches the containerlab metadata and whose state, utilization and
  counter values match direct metric queries during normal traffic and a forced link failure.
- **SC-037**: Runtime inspection proves device series flow only through the single collector
  pipeline to the metrics store, with zero duplicate subscription series and a detectable alert
  when any pipeline stage stops exporting.
- **SC-038**: Every request is recoverable as one correlated trace naming the responsible stage,
  and 100% of failed requests identify their failing stage without reading process logs.
- **SC-039**: An operator can move from a fabric telemetry view of a service to the agent
  conversation that created it, and back, without correlating by timestamp.

**Evidence and enforcement** *(new in the retarget)*

- **SC-040**: Every capability-gate item and every acceptance result is backed by run-captured
  evidence carrying its command, time, exit status, image digest and lab identity, and each
  readiness check has a recorded negative control showing it fails on a stock fabric. *(New in the
  retarget; measures NFR-013 and FR-004.)*
- **SC-041**: For one access list in each direction the pinned profile qualifies, a probe the list
  denies is dropped and a probe it permits passes, and the per-entry match counters of exactly those
  entries move accordingly. *(New in the retarget; demonstrates enforcement without making readiness
  depend on traffic.)*
- **SC-047**: Exactly one allocation authority is installed in every run: under the upstream
  selection no first-party allocation kind is served, under the recorded substitution no upstream
  allocation API service exists, and a run whose allocation capability-gate item fails stops
  non-zero naming that item with zero applications installed above the authority. *(New; operator
  review 2026-09-20; measures FR-104.)*
- **SC-048**: The model-provider Secret survives re-provisioning: a run that sets the model and the
  key but not the base URL leaves the stored base URL byte-identical, only the named clearing input
  removes it, a declared gateway with no base URL creates zero tier workloads, and every
  provisioning line and start-up line that names the endpoint carries zero credential characters.
  *(New; operator review 2026-09-20; measures FR-106.)*
- **SC-049**: No device client is invoked from outside the gate, the test suites and the walkthrough
  tooling — asserted repository-wide with a fixture that fails the check — and every gate run reads
  back the removal of its own scratch configuration before it reports, so the fabric never starts on
  a dirty device. *(New; operator review 2026-09-20; measures FR-108.)*
- **SC-050**: 100% of log lines from every first-party workload parse as one JSON object carrying
  the fields of [data-model.md](./data-model.md) §27, 100% of lines belonging to a request carry its
  correlation identifier, and zero lines carry a credential. *(New; operator review 2026-09-20;
  measures NFR-014.)*

## Analysis remediation — 2026-09-20

The cross-artifact analysis run after task generation found one constitution constraint with no
requirement, one carried by a single task clause, and three places where an absolute statement in
this document did not match what the design does. Each was fixed here rather than in the design,
because in each case the design was right and the sentence was loose. Nothing was renumbered and
nothing was retired; how each is built is `AD-01`…`AD-08` in [research.md](./research.md) §13.

| What changed | Why |
|---|---|
| **FR-106**, **CR-008** *(new)* | The constitution's LLM-configuration constraint — a declared gateway needs a base URL, re-provisioning preserves it — existed only in the quickstart and one contract row |
| **FR-107**, **SC-044** *(new)*; CR-001 carrier list | Constitution Principle I's scheduled re-verification had no requirement, no interval and no measure |
| **FR-108** *(new)*; FR-007 reworded | "No component outside the cluster may read or write device configuration" also described the capability gate, drift injection and the walkthrough's device proofs. FR-007 now governs the *platform* without exception, and FR-108 bounds the tools that check it. RD-02 is unchanged: there is still one southbound and nothing depends on anything else |
| FR-075 and User Story 6 scenario 3 reworded | They said "create, read and update" in "its own namespace"; rollback (FR-066) and removal (FR-069) need delete, and the design has two identities across two namespaces. The verb sets are now exact, so the denial probes have an allow-list to be exact against |
| NFR-003 extended | "Resolve every digest against its registry" could never hold for an image that is built locally. First-party images are pinned by their build inputs and identified per run in evidence |
| CR-002 scoped to the intent tier | Read literally it forbade `kubectl apply` of a service intent object, which User Story 2 is built on |
| FR-018, FR-053, FR-067, FR-073 | Each named a bound with no value; the defaults are now in [data-model.md](./data-model.md) §25 |
| Four edge cases given outcomes | Concurrency, topology change (twice) and a degraded fabric were listed without an expected result, so no test could assert one |
| FR-089, FR-094, FR-104, User Story 1's independent test, the task-list sentence | Wording only: a duplicated rule now points at its owner, the two join labels are named, the substitute allocation authority is distinguished from the allocator agent, User Story 1 no longer needs User Story 2 to be tested, and this document no longer says it has no `tasks.md` |

### Second pass — 2026-09-20

A re-run of the same analysis after the first remediation found no constitution conflict and full
task coverage, and thirteen smaller things: one path with no owner, one constitution rule with no
carrier, passages left stale by the execution order of `AD-08`, and wording. Two were put to the
operator and answered the same day (*operator* below). Nothing was renumbered and nothing was
retired; the decisions are `AD-09`…`AD-15` in [research.md](./research.md) §13.

| What changed | Why |
|---|---|
| **FR-109**, **SC-045** *(new)*; an edge case | *Operator.* A service intent object applied with cluster tooling carried VNIs nobody claimed: the provider waited for bound claims and released them, and only the intent tier's allocator agent created any. The provider now adopts the tier's claim or claims the stated value itself; the authority, not a webhook, arbitrates a collision |
| **NFR-014** *(new)*; CR-005 carrier list | Constitution Principle IV's "logs MUST be structured" was attributed to NFR-005, which does not say it, and to no task |
| FR-013 and FR-104 reworded | *Operator.* "The single first-party API group" was said while the optional `MigrationPlan` sits in a second one. One group carries fabric intent, service intent and the conditional allocation kinds; the `MigrationPlan` group is the only other. Nothing moved |
| NFR-003 and CR-006 extended | "Any exception MUST be warned" had a mechanism for one exception and no statement about the rest. Exactly one is admitted — FR-104's; anything else fails the pin check |
| FR-015 extended | The production half of the drift-policy rule had no mechanism: the policy is now a provider setting with no default |
| SC-008, the Observability edge case | Wording only: "(default 30s)" read as the interval rather than the bound; cardinality and stale series had no stated outcome |
| Two tables and two sub-headings | Formatting only: a blank line had orphaned the rows after it; two bold sub-headings had fused into the list item above them |

### Third pass — 2026-09-20

A third run found no constitution conflict, full task coverage and fifteen findings, two of them
high: both were seams the second pass had opened. All were closed the same day at the operator's
instruction; two closures are design choices the operator may reverse, and are marked *choice*.
Nothing was renumbered and nothing was retired; the decisions are `AD-16`…`AD-22` in
[research.md](./research.md) §13.

| What changed | Why |
|---|---|
| FR-109 widened, FR-062 extended, **SC-046** *(new)* | *Choice.* The second pass gave the VNI claims of a service a release owner and left the tier's **VLAN** claims without one: the provider held nothing on VLAN claims and the tier released only on decline, rollback and purge, so every removed service leaked its allocated VLAN. The provider now adopts the tier's VLAN claim as it adopts its VNI claims and releases it at finalization. A VLAN an operator names is still claimed by nobody. **Ratified by the operator on 2026-09-20 with amendments (`AD-32`)**: adoption is decided once per value and survives the object ceasing to carry it; the fields adoption matches against are named and an adoptable claim must also bear a deterministic name; a tier-submitted object carries the finalizer from the moment it is applied, so no window exists in which its claims have no owner; the deployer, not the allocator, decides which correlation identifiers are still provisional, so FR-075 is not widened; and every claim label the platform relies on lives in `metadata.labels` |
| FR-015 extended | *Choice.* "Unset or unknown refuses to start" named no known values but `revertive`. The set is closed at one member; a second is a change to the requirement. **Rationale corrected by the operator decision of 2026-09-20 (AD-34): the layer's non-revertive mode records a deviation the operator may accept *or revert*, and the revert is repair — so the second policy is out of scope, not unconstitutional, and the "constitution amendment" claim this row originally carried is withdrawn** |
| FR-078 and the *Audit event* entity extended | The audit event was "emitted as a Kubernetes Event" by a supervisor that holds no cluster permission, and called immutable while Events expire. The record is the trace-borne event in the agent-analytics store, retained for the life of the lab and exported with the evidence; an Event is a mirror only |
| SC-028 extended | "A packet counter on the management CIDR" also counts the device-configuration layer and the collector, which dial devices by design. The count is per source, inside the cluster nodes, with a positive control |
| FR-034 extended; an edge case | The data model refused conflicting tagging modes on one port with no requirement, contract rule or test behind it |
| NFR-003 extended | The browser-automation package, its browser and the walkthrough's capture tools were in no lock file |
| *Network* and *Fabric service resource* merged; SC-029, User Story 6, FR-030, User Story 5 | Wording: one object had two entity entries, both saying it was the only thing the tier creates, which the allocator agent's claims contradict; "identity" was singular where there are two; two sentences said the opposite of what they meant. Two fused lines re-wrapped |

### Fourth pass — 2026-09-20

A fourth run found no constitution conflict, full task coverage and fifteen findings, two of them
high: a readiness rule the default fabric could never satisfy, and an audit record that a documented
step deleted. All were closed the same day at the operator's instruction; three closures are design
choices the operator may reverse, and are marked *choice*. Nothing was renumbered, nothing was
retired and no requirement was added; the decisions are `AD-23`…`AD-30` in
[research.md](./research.md) §13.

| What changed | Why |
|---|---|
| User Story 1 (independent test, scenario 2), FR-100, SC-004, an edge case | *Choice.* The fabric design was `Ready` only with "EVPN routes actually exchanged", but it converges before any service exists and after the gate's scratch instances are gone, so there is no route to exchange and provisioning could never pass `FabricReady` without weakening the check. Fabric readiness is now sessions established with the EVPN family negotiated **and the reflecting spines' reflection setting read back from state**; route exchange is an invariant of each service that spans two leaves, which is where FR-100 already keyed it. A fabric-wide route count was the kind of evidence FR-100 forbids. **Ratified by the operator on 2026-09-20 with amendments (`AD-31`)**: the spine read-back is stated as a configuration-integrity check and gains `route-reflector client`; the applied side gains the EVPN family's own per-neighbour operational state and the allocated loopbacks active in each node's route table; a post-render probe under FR-108 proves reflection on the rendered fabric without gating readiness; and fabric readiness alone is never SC-004 evidence |
| FR-078, User Story 7 scenario 4, an assumption | The audit record was to live "for the life of the lab environment", in a store inside the namespace the tier's removal deletes while the lab runs on, with evidence capture optional. The export is now unconditional before anything removes the store; a failed export stops the removal; the only way past is a named, recorded discard flag |
| FR-109 extended; an edge case | A VNI or service VLAN edited on an accepted object had no claim rule: the old claim was held until deletion and the new one made beside it. Allocated identifiers are immutable once accepted; attachments may still change |
| NFR-006, User Story 7 scenario 4; an edge case | *Choice.* Removing the tier deletes its intent namespace and with it every service the tier submitted, which no requirement said; and a service that cannot finalize (FR-103) left the removal hanging with no outcome. The removal lists the services first, waits a bounded time, and stops naming the service and the target — never force-releasing. **Superseded in part by the operator decision of 2026-09-20 (AD-35): the machinery stands, the default is reversed — the removal deletes nothing until asked, and scales the tier's request-accepting workloads down before it does** |
| FR-062 extended; an edge case | *Choice.* Named VLANs are claimed by nobody and allocated VLANs come from the same range, so the authority can allocate a VLAN already attached on the requested port. The one-owner rule refuses it by name and says how to avoid it; no value is retried silently. **Superseded by the operator decision of 2026-09-20 (`AD-33`): the two kinds of VLAN get disjoint bands** — an operator may name only from `100–999`, the authority allocates only from `1000–4000` — so the collision is structurally impossible and its refusal path is withdrawn with it. "Named VLANs are never claimed" stands; the one-owner rule stands for two services naming the same (node, port, VLAN) |
| FR-020 extended | The controller and API suites and the chat surface's unit test had no make target and no CI job — the shape of the predecessor's disputed "full gate run" |
| FR-048 extended | The optional `MigrationPlan` carried a route-target preservation policy FR-012 cannot honour, was "disabled by default" with nothing that disabled it, and named no host for its controller |
| FR-102 reworded | "Never defaulted" sat beside a default username. The password is never defaulted; the username may be |
| FR-107 reworded | "Within that interval" against SC-044's interval plus one reconciliation interval; the requirement now states the measured bound |
| FR-078 and the *Audit event* entity | Four event kinds were listed where the design has six; "every refusal" now excludes the unauthenticated one, which has no principal |
| FR-096, NFR-004 | The dashboards' administrator credential had no generator; the measured footprint had no run that measures it |

### Operator review — 2026-09-20

After the fourth pass the operator had the five design choices the analysis passes had made without
them — `AD-16`, `AD-17`, `AD-23`, `AD-26`, `AD-27` — and both reviewer-owned checklists researched by
independent agents against the pinned upstream sources. The reports and the decision sheet are in
[review/2026-09-20/](./review/2026-09-20/). **The operator decided each one**; these are decisions, no
longer choices. They are `AD-31`…`AD-36` in [research.md](./research.md) §13; the checklist closures
that needed no decision are `AD-37`…`AD-39`. Four success criteria were added (SC-047…SC-050), one
capability-gate item (G13), one task (T175) and one risk (R-48); nothing was renumbered or retired,
and no checklist item was ticked.

| What the operator decided | What it changed |
|---|---|
| **`AD-23` ratified, amended** (`AD-31`) | The premise was verified against the pinned model: no EVPN route exists before an EVPN instance does. But `inter-as-vpn` is a configuration leaf, so reading it back proves it was applied, not that reflection works — the requirement now says so. The fabric read-back gains the EVPN family's operational state per session, `route-reflector client`, and reachability of the loopbacks the fabric allocated; a post-render reflection probe is captured as evidence and never gates readiness (FR-108); the routes-lost alert is silent by design on a fabric that carries no service. User Story 1, FR-100, SC-004 |
| **`AD-16` ratified, amended** (`AD-32`) | Adoption is decided once and is sticky; it needs the label, the deterministic claim name and a value the object carries, which closes adoption by a copied label. The finalizer is set at apply, so a delete while the provider is down orphans nothing. Whether a service was submitted is the **deployer's** to say — the allocator agent reads no service intent object and FR-075 is not widened. FR-109, FR-062 |
| **Named and allocated VLANs get disjoint bands** (`AD-33`, replacing `AD-27`'s refusal) | An operator names a VLAN from 100–999; the allocation authority allocates from 1000–4000. The collision the fourth pass refused by name cannot occur. For an object applied with cluster tooling the rule is by value: a VLAN in the allocation band must be backed by an adoptable claim. FR-062, FR-034, FR-109 |
| **Drift-policy set stays closed at `revertive`, rationale corrected** (`AD-34`) | The device-configuration layer's other mode records a deviation the operator can revert — that is repair, so it is out of scope for this feature, not forbidden by the constitution. The policy is stated in one place, the provider setting, and lands on every generated configuration resource; the onboarding resources have no such field. New gate item **G13** observes what a drift test may assert. FR-015, FR-004, SC-007 |
| **The tier's removal deletes no service until it is asked to** (`AD-35`, reversing `AD-26`'s default) | The removal lists the services the tier submitted and refuses while any exist, unless `--remove-services` is given; with it, the tier is quiesced first, then the fourth pass's machinery runs unchanged. A whole-lab teardown is exempt. NFR-006, FR-010, User Story 7 |
| **The audit export has a format, a bound and a defined failure** (`AD-36`) | FR-078 now says what is exported, where, within what time, what "failed" means, that a re-run never trips the post-edit check, and how SC-030 and SC-042 reconcile from the file once the store is gone. FR-078, FR-079 |
| Requirements-checklist closures (`AD-37`, `AD-38`) | Six success criteria name their verification method; an obligations index in [traceability.md](./traceability.md) separates the MUSTs bundled in FR-015, FR-078, FR-109 and NFR-003; an indeterminate workflow status is never a success (FR-054); a second workflow engine is forbidden by name (FR-013); the denied management ports are one list, observed at the gate rather than remembered (FR-075, SC-029); every "asserted in CI" names its carrier |

#### Clarify-delta closures (`AD-39`)

The post-clarify delta checklist was triaged before implement and its closures put to the operator.
The design choices the review settled are in [research.md](./research.md) §13 `AD-31`…`AD-38`; the
closures that needed no design decision are `AD-39`, and are the rows below. Four success criteria
were added — the first since the third pass — for the four delta requirements that had none;
nothing was renumbered and no other identifier was added.

| What changed | Why |
|---|---|
| FR-103 extended; four edge cases added | The rules bounding the force-release — a non-empty reason, honoured only on an object both deleting and blocked on an unreachable target, settable by no tier identity — and the open-finding consequence — a render that would reproduce a named object is refused, the fabric design reports degraded and not not-Ready — lived only in the contracts, while FR-075 grants the deployer `update` on a `Network`. A device that never returns now has a stated outcome |
| FR-107 extended; `VerificationFailed` defined | A re-verification that *could not run* had no outcome and the reason code was listed and never defined; it reports `Degraded` naming the target and leaves `Ready` where it stands. The schedule's scope (never-Ready out, deleting in), a floor under the interval, and an alert for the stalled schedule the requirement only called "detectable" |
| FR-102 extended | "Both surfaces MUST require an authenticated operator" stood against two unauthenticated probe routes; the exception is named by its property. Rotation without restart and a thread continued under another credential are requirements, not contract rows |
| FR-106 extended | The Secret is written key by key, clearing the base URL takes its own named input, an agent that loses it while running stops rather than falling back, and the endpoint it prints is redacted of any credential the URL embeds — FR-106 and FR-079 could not both be satisfied as written |
| FR-108 extended | "Scratch configuration", "a declared injected fault" and "a device client" are defined where they are used, and tooling that dies between writing and removing leaves something a later run finds and refuses to start over |
| FR-105 extended | The hash's representation (the server-side dry-run result), the `spec`-only scope of the comparison, the removal asked of an already-modified service, and that detection is on demand and works from any thread |
| FR-104, FR-086, NFR-014, SC-030, SC-042, SC-043 extended; §Scope and interpretation | A substitution's preconditions and its return path; re-verification adds no third client to the session limit; NFR-014 names where its field contract lives and gives its script exclusion a reason; SC-030 names its injected set; SC-042 reconciles usernames, not passwords; SC-043 measures the two halves of FR-103 it did not |
| **SC-047**, **SC-048**, **SC-049**, **SC-050** *(new)* | FR-104, FR-106, FR-108 and NFR-014 had no success criterion and no record that the absence was meant. Each is measured by tasks that already exist, so coverage is complete without a new one |
| §Measurable Outcomes preamble | NFR-013's negative control was named per readiness check and by none of SC-042…SC-046; it is stated once for every criterion instead |

### Fifth pass — 2026-09-21

The fifth cross-artifact analysis read the operator review's own propagation and found **one
constitution conflict**, twelve high findings and thirty-five lesser ones — most of them where
`AD-37`…`AD-39` had extended a requirement "with no new task". Four were put to the operator before
any edit and **decided by the operator** (`AD-40`…`AD-43`); two are choices made on the analysis's
recommendation, reversible, with the alternative recorded (`AD-44`, `AD-45`); the rest are closures
(`AD-46`…`AD-50`). All are in [research.md](./research.md) §13. Two constitution-mandated
requirements were added (CR-009, CR-010); no functional requirement, success criterion, risk, gate
item or task was added, retired or renumbered, and no checklist item was ticked.

| What was decided or closed | What it changed |
|---|---|
| **A re-verification that could not run sets `Ready=Unknown`** (`AD-40`, operator) | FR-107 had said such a pass "MUST leave `Ready` where it stands", which leaves `Ready=True` resting on an earlier pass for as long as an outage lasts — what constitution Principle I forbids. It now sets `Ready=Unknown/VerificationFailed` at that pass, with `Degraded` naming the target; never `False`, because an outage is not evidence an invariant is gone. The combinations of `Degraded=True` beside `Ready=True` are a closed list of two. FR-107, FR-054, FR-067, SC-008, SC-044 |
| **The naming band is enforced at the mapper** (`AD-41`, operator) | The translator's input is the allocator's output, a bare integer produced after claiming, so it could never tell a named VLAN from an allocated one. The mapper refuses a named VLAN outside `100–999` before any claim exists; the translator keeps the structural `100–4000` check only; no provenance field is added. FR-062, FR-034 |
| **VNI and VLAN claims are adopted on the same three things** (`AD-42`, operator) | Label, deterministic claim name and carried value, under the one naming scheme the provider's own claims already use; adoption by a copied label is closed for VNIs as it was for VLANs. FR-109, SC-046 |
| **SC-004's negative control is a declarative fault** (`AD-43`, operator) | `Fabric.spec.overlay.interASVPN` set `false` — both reflecting spines stop reflecting while every session stays established — in place of a device-side removal the revertive policy could repair before the service next looked, and which one spine alone could never have made visible. As decided (AD-77, 2026-09-21) the field is `Fabric.spec.overlay.reflectorClients: false`: with `inter-as-vpn` removed the spines still reflected (G8), so `interASVPN: false` is no control; AD-43's declarative mechanism is unchanged. SC-004 |
| Finalization resolves adoption before it releases (`AD-44`) | A finalizer set at apply did not by itself give the claims of a never-reconciled object a release owner: release covers `status.claimRefs`, empty until the first reconcile. FR-109, SC-046 |
| The analytics store is deployed before the first test that reads it (`AD-45`) | The store is the audit record, and User Story 4's reconciliation read a store User Story 12 deployed. It and the agent collector are now installed with the tier, first. FR-078 |
| Tier removal and the audit export (`AD-46`) | The export is read back — the stream half of SC-030 and SC-042 reconciles from the file alone; the usernames a run used are captured before the credential goes; the scale-down precedes the export on every path; a re-run's skip-or-add rule and "verified" are defined once; User Story 7 scenario 4 is 4a and 4b. FR-078, NFR-006, SC-042 |
| Claims and the VLAN bands (`AD-47`) | The deployer's `patch` verb is stated where the exact verb set is (FR-075); an attachment may be added on the allocated VLAN a service already carries; a standalone access list's VLAN is a reference, exempt from both band rules; a named VLAN is no longer described as allocated (User Story 4 scenario 4); G11 observes synchronous release. FR-075, FR-109, FR-062, FR-034 |
| Fabric readiness, drift policy and the gate (`AD-48`) | Every generated configuration resource's explicit revertive field has an assertion; a fault on a managed path is restored by the platform and read back by the tool that made it; the gate's scratch configuration resource is FR-013's one named exception; the routes-lost alert waits for one EVI on two leaves. FR-108, FR-013, FR-015 |
| The clarify-delta requirements' uncovered clauses (`AD-49`) | Every MUST `AD-39` added now has a task that tests it — FR-107's floor and refusal to start, FR-108's leftover scan, FR-106's running agent, SC-047's failing gate, FR-104's return path, FR-054's unknown status, FR-013's single engine, FR-103's and FR-102's remaining cases — and the stalled-schedule metric has one name |
| The task list's structure, and the constitution's carriers (`AD-50`) | Four `[P]` markers that shared a file are gone; the refused example left the directory applied as a whole; offline shell suites are run by `make test-static`; metrics modules are created where they are first asserted. **CR-009** (the MTU envelope and probe sizes) and **CR-010** (the IPv6 Type-5 limitation) carry two constitution constraints the specification had not stated; CR-002 and CR-004 now state "never a service type not asked for" and "server-side dry-run"; a status query takes no confirmation (FR-069); NFR-012's envelope and FR-087's alert set are decidable |

### Sixth pass — 2026-09-21

The sixth analysis found **no constitution conflict**, six high findings and some thirty-five lesser
ones — almost all second-order effects of the fifth pass's decisions. Three were put to the operator
before any edit and **decided by the operator** (`AD-51`…`AD-53`); the rest are closures
(`AD-54`…`AD-60`). All are in [research.md](./research.md) §13. One reason code was added
(`Deleting`, on `Ready`); no requirement, success criterion, risk, gate item or task was added,
retired or renumbered, and no checklist item was ticked.

| What was decided or closed | What it changed |
|---|---|
| **An `ip-vrf` attachment's VLAN is named or absent — never allocated** (`AD-51`, operator) | No request shape let an operator ask for a tagged attachment without naming its VLAN, and an attachment has no name to build `AD-42`'s deterministic claim name from. The allocator never claims a VLAN for an `ip-vrf`; an `ip-vrf` attachment VLAN in `1000–4000` is always `AllocationConflict`. FR-062, FR-109, SC-046 |
| **The validating webhook fails closed** (`AD-52`, operator) | `failurePolicy: Fail`, on create and update, never delete: while the provider is down nothing is admitted and every admission rule always holds. "Applied while the provider is down" became "deleted before the provider's first reconcile"; a dry-run that cannot reach the webhook is a retryable dependency failure, not a refusal. FR-034, FR-109 |
| **An object being deleted reports `Ready=False/Deleting` at once** (`AD-53`, operator) | Nothing said what `Ready` reports during a deletion that may block for ever on an unreachable target, and the likely build left `Ready=True` standing. FR-103, FR-107 |
| Re-verification and readiness (`AD-54`) | The last-verified time advances on every pass that *ran*, whatever it found, and freezes only on one that could not; the order of reasons on the fabric design's one `Degraded` condition; the between-passes rule on the service side; the model-provider Secret is mounted, never injected; the per-object series goes when the object does |
| The fabric dependency, the gate's series names, the tier's removal (`AD-55`) | A service depends on the fabric design being Accepted, never Ready — in every rule that stated the dependency; gate item G7 observes the pinned telemetry client in a throwaway Pod pair; who reads the usernames record and when; the verified-export test tells one store from another |
| Claims and the VLAN bands (`AD-56`) | An allocation-authority *error* is a requeue, never "no claim"; the schemas' structural VLAN range is the resource's; claim names are bounded at 197 of 253 characters; one list of what G11 observes |
| The task list's ordering (`AD-57`) | The request span is created where the correlation identifier first needs it; re-provisioning between the acceptance cycles, the removability proof and the walkthrough is stated; `LabReady` waits on a port accept, not a device client; the alert check declares its faults |
| The specification and the constitution's carriers (`AD-58`) | CR-010 has a tester; FR-105's removal of a modified service proceeds through both confirmations |
| Vocabulary, alerts and the traceability tables (`AD-59`) | The submission audit event is the deployer's alone; all ten required alerts are shown to fire and clear, live or by a rule unit test that is never reported as a live firing; R-03 is live — 46 of 48 risks |
| What the editors left at their edges (`AD-60`) | FR-108 names the gate's throwaway Pod; the leftover scan reads scratch namespaces; a declarative fault is restored from an exit trap; the stream's `ready` is a three-valued string |

### Seventh pass — 2026-09-21

The seventh analysis found **no constitution conflict and one high finding** — a consequence of
`AD-52` — and four of its six slices carried nothing above medium. Its decisions are `AD-61`…`AD-67` in
[research.md](./research.md) §13; none needed the operator, and `AD-63` is a choice made on the
analysis's recommendation, reversible, with the alternative recorded. No requirement, success
criterion, risk, gate item or task was added, retired or renumbered, and no checklist item was ticked.
**This pass closed the review loop**: with no critical and no high finding left, readiness is from here
on decided by a deterministic gate over the artifacts — identifiers, coverage, references, totals —
and what remains at medium and below is settled where implementation meets it (`/speckit-converge`).

| What was decided or closed | What it changed |
|---|---|
| **The fail-closed webhook evaluates a create and a `spec`-changing update — never a metadata-only update or a deleting object** (`AD-61`) | Finalizer removal and the force-release annotation are updates; an unscoped fail-closed webhook would have refused them on an object whose attachment no longer resolves, leaving FR-103's only exit shut. The force-release's own guards are unchanged. Also: every VLAN an operator can type reaches the both-bands refusal; the service identifier's generation rule is stated once. FR-034, FR-062 |
| Readiness and the stream (`AD-62`) | The stream's readiness value is the three-valued status string on the server side too; "had reported Ready" means at the current generation; the never-True-never-False polls are anchored to the first `Unknown`; the order of reasons on `Degraded` is total |
| **A removal asked of the tier ends when the object is gone, or says what it is still waiting for** (`AD-63`, choice) | Nothing said when a removal turn ends. It watches until the object is gone within the convergence bound, else reports the removal in progress naming what the deletion condition awaits — never a success it has not observed. FR-069, FR-067 |
| The lab's lifecycle and the verification tooling (`AD-64`) | A teardown never deletes the evidence root; each phase that ends torn down ends provisioned again; every declarative fault is restored from an exit trap; the four leftover kinds each have a fixture; the offline job's one container-runtime need is stated |
| The specification's indexes and carriers (`AD-65`) | FR-108 has an obligations index, with its five untested clauses recorded as open carriers rather than invented tests; FR-109's two unindexed clauses are indexed |
| Names, commands and an uncovered clause (`AD-66`) | One tier metric prefix and one per-stage counter name, taken from the predecessor's code; the quickstart's test commands point where the tests are and treat "no tests to run" as a failure; FR-015's overruled-path clause has a builder and a test |
| The task list (`AD-67`) | Forward notes where a task uses what a later one creates; the redaction the provisioning script shares with the agents is kept equal by a fixture |

### Eighth pass — 2026-09-21

Run **bounded**, under the exit rule the seventh pass set: the deterministic gate, green, and four
read-only slices briefed for critical and high findings only, each claim re-read against the text
before it counted. **No constitution conflict**; the constitution slice and this specification's own
slice carried nothing above medium. Three high findings stood and are closed by `AD-68`…`AD-70` in
[research.md](./research.md) §13. `AD-68` is an **operator decision** — option (a) of three put to
the operator; `AD-69` and `AD-70` are closures. No requirement, success criterion, risk, gate item or
task was added, retired or renumbered; two open items (19, 20) were added; no checklist item was ticked.

| What was decided or closed | What it changed |
|---|---|
| **A leaf two services would share belongs to the fabric's configuration; a service's writes only beneath what it keys** (`AD-68`, operator) | FR-015 refuses two same-priority resources on one leaf, and every tagged service wrote its port's administrative state and tagging mode — so the rule refused the platform's own examples on a lab with one access port per leaf. Those leaves, and the integrated-routing interface's, are the fabric's; the port's tagging mode is declared in the site inventory; a binding's subinterface reference is rendered with the subinterface. It also removes the priority-10 / priority-20 meeting on an access port under maintenance. FR-015, FR-034 |
| Generated configuration lives in the provider's namespace, and a service's carries no owner reference (`AD-69`) | The contract's exemplar carried a cross-namespace owner reference, which Kubernetes reads as an absent owner: the resource would have been collected and the service withdrawn from the device. Removal is the finalizer's, as FR-103 already had it. FR-016 |
| The fabric golden files are frozen after the first gate run (`AD-70`) | T047 sat before the provisioning script and the first live run, and could not have read the observed serialization it freezes against. It moves after T052 and keeps its id |
| The pass's medium findings, closed at the operator's request (`AD-71`; one point a recorded choice) | A locked first-party image with no Dockerfile yet is *pending* and fails anything that references it; the SC-004 recording rule has one owner, the evidence check; the offline render validator is named and pinned; the tier purge scales down what exists; the unreachable-deletion suite is built with both its modes; **a force-release finding whose device has left the fabric design stays on record and stops counting toward degraded** (choice); the layer's latency in noticing a lost target is measured, and a miss fails SC-008 naming it. FR-103, NFR-003, SC-004, SC-008, SC-043. Open item 20 added |
| The pass's low findings (`AD-72`) | Six requirements cited only through a range are cited by id, on the tasks that build them; SC-012 says it is measured on a Ready fabric; User Story 7 scenario 4b is written in the order NFR-006 fixes; a purge stopped by a held deletion names what holds it, a target or a holder |
| **The operator ratified the five choices the passes had made on their own recommendation** (`AD-73`) | `AD-44`, `AD-45`, `AD-63`, the declared tagging mode inside `AD-68` and point 6 of `AD-71` are operator decisions from here on, as written; no unratified choice remains in the record |

## Retarget decisions

The merged specification left six decisions open for the pass that moved it to a new platform.
They are made here. Each is recorded in full — decision, rationale, evidence, alternatives
rejected — as RD-01 to RD-15 in [research.md](./research.md) §11; the two marked *operator* were
put to the operator on 2026-09-20 and answered.

| # | Was open | Decided | Carried by |
|---|---|---|---|
| 1 | **Southbound** — restore the specified path or keep an executor escape hatch | The only southbound is provider → device-configuration resource → gNMI → device. No executor, no host-side component, no second write path. The hazard that justified the escape hatch was specific to the previous platform's configuration store and does not exist here (RD-02) | FR-007, FR-014, FR-015 |
| 2 | **Provider ownership** — upstream as-is, first-party, or upstream plus a gap controller | *Operator.* A first-party fabric API and a single first-party provider. The upstream fabric control plane is dormant, targets a device release two years old, no longer builds against the device-configuration layer, and cannot express access lists, an anycast gateway, a local bridge domain or explicit route targets; a gap controller would be a second translation path by this specification's own definition. The device-configuration layer and the allocation authority are reused unchanged (RD-03) | FR-012, FR-013, FR-014, FR-098 |
| 3 | **SRv6** — keep, gate, or defer | *Operator.* Deferred to a future feature. See §Deferred scope (RD-04) | tombstones |
| 4 | **Access-list binding point** | The attachment subinterface. The unit of exclusivity is subinterface, direction and address family; a standalone list binds only to an attachment that already exists; evaluation is ascending priority, first match wins, with the platform's implicit accept made explicit to the operator (RD-05) | FR-035 to FR-043 |
| 5 | **Construct vocabulary** | The alignment of `mac-vrf` and `ip-vrf` with the device's own instance types is a requirement. `vlan` remains its own construct — more necessary than before, because the device realizes it with the same instance type as `mac-vrf` (RD-06) | FR-029, FR-099 |
| 6 | **The visualization boundary** | Re-scoped from "no runtime artefact of that lab's operating system" — now the target — to a reference-artifact boundary: reuse patterns, vendor and pin artefacts, resolve nothing from a third-party repository at run time (RD-07) | FR-094, SC-017(b) |

Decisions the retarget had to make that the merge did not foresee: the release pin and single lab
profile (RD-01), native-first paths (RD-08), derived identifiers and the removal of the
route-target index (RD-09), the MTU envelope (RD-10), the telemetry path set and generator
(RD-11), the rewritten capability gate (RD-12), two-sided read-back for every construct (RD-13),
the gap closures (RD-14) and the preventive requirements drawn from the inherited acceptance
record (RD-15).

## Gaps closed by the retarget

The merge recorded six gaps and numbered none of them, because inventing a rule there would have
been a redesign. The retarget is a redesign of exactly those seams, so each is closed by a
requirement.

| Gap | Closed by |
|---|---|
| GAP-1 — a construct whose render path the fabric has not qualified | FR-097: qualification is recorded per construct and property; an unqualified one is refused at interpretation by name |
| GAP-2 — construct provenance and migration provenance as two unrelated records | FR-046 (FR-048 references it, and adds no second record): one provenance record, on the service intent object |
| GAP-3 — three actors stamping one object with no precedence | FR-101: one owner per key; the provider stamps the configuration resources, not the service intent object |
| GAP-4 — the binding conflict checked by one actor and enforced by another | FR-043: a service being removed holds its bindings until it is gone; binding is withdrawn before filter; finalization names a foreign holder |
| GAP-5 — the tier could write a resource kind the vocabulary cannot name | Closed by deferral: the SRv6 service kind no longer exists and the tier's identity is granted the service intent kind only (FR-075, [contracts/kubernetes-objects.md](./contracts/kubernetes-objects.md)) |
| GAP-6 — two-sided read-back stated only for access lists | FR-100: every construct |

## Deferred scope

Retired identifiers keep their numbers and a one-line tombstone in place. They are carried to a
future feature (working title *SRv6 services*), which this specification does not create.

| Retired | What it was |
|---|---|
| US3 | Provision and observe an end-to-end SRv6 service |
| FR-003, FR-005 | Dedicated SRv6 endpoints; the SRv6 compatibility gate |
| FR-021, FR-022, FR-023 | The SRv6 service API; locator and SID allocation and rendering; end-to-end SRv6 verification |
| SC-009, SC-010 | SRv6 acceptance; SRv6 status visibility |

**What would reopen it**: a pinnable, licensable device profile that originates and terminates
SRv6 services and models explicit segment lists and per-segment counters. The evidence that none
exists today is in [evidence/04-srv6.md](./evidence/04-srv6.md).

## Clarification candidates

Defaults chosen by the retarget where the evidence supported more than one answer. Each is a live
requirement as written; each is a good question for a clarification pass.

1. **Access-list priority direction.** *Resolved 2026-09-20 (§Clarifications): confirmed as
   written.* Ascending priority number, first match wins, rendered
   unchanged as the device's sequence number (FR-039). This is the device's direction and the
   reverse of the predecessor platform's. The alternative — keep "higher number wins" for operators
   and invert on render — preserves a habit at the cost of a device view that contradicts the
   request.
2. **Where an unqualified construct is refused.** At interpretation (FR-097). The alternative is to
   accept it and let convergence fail, which creates objects that never converge.
3. **The enforcement probe.** In acceptance, never in readiness (SC-041). The alternative is to
   keep enforcement unclaimed and unchecked, as the merged specification did when the dataplane
   could not demonstrate it.
4. **The allocation authority is dormant upstream.** *Resolved 2026-09-20 (§Clarifications):
   confirmed, and the failure branch is now FR-104 — a gate failure stops provisioning, the
   fallback is adopted only by recorded operator decision, and it lives in the first-party API
   group.* Reused unchanged and qualified at the first
   delivery phase, with a named first-party fallback behind the same claim contract (RD-03). The
   alternative is to build the allocator first-party from the start.
5. **The default management address space.** Configurable, with an overlap preflight (FR-008); the
   default the predecessor used collides with an existing network on the reference host.

## Assumptions

- The target is a lab and reference architecture, not proof that a containerized network operating
  system matches any production ASIC or hardware platform. The containerized dataplane has a
  packet-rate ceiling — 1000 PPS documented for the unlicensed container, ~5 kpps measured in
  research (`platform-coupling.md` PC-S-10) — which NFR-004 requires to be re-stated from what the
  clean-host run observes rather than quoted from that research; nothing here measures
  performance.
- The lab runtime is a **privileged** one and that is a trust boundary, not an oversight: the
  emulated network nodes need privileged containers and host network namespace access, so anyone who
  can start the lab can already reach the host. It is documented as a boundary rather than defended
  against, it is why nothing in this platform is presented as production-safe (FR-019), and it is the
  one host-level privilege the platform takes — no hypervisor, no nested virtualization and no
  hardware-acceleration device is required or used (NFR-004).
- The Kind cluster is a disposable lab control plane. Required evidence must be exported before
  teardown; volume persistence is scoped to the lifetime of that environment unless the operator
  uses the documented evidence-preservation option. The audit record is the one export that is
  never optional (FR-078).
- **Where the upstream dependency state is recorded.** The state of every reused upstream project
  as it was found — which are current, which are dormant, and each one's last release — is in
  [research.md](./research.md) §11 and, per coupling, in `platform-coupling.md` PC-S-01 and PC-S-15,
  with the repository-by-repository dates in [evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md).
  No requirement here assumes an upstream fix will arrive; the consequence of a dormant dependency
  is a pin, a gate item and a recorded fallback, never a wait.
- One release of the device-configuration layer and one release of the allocation authority are
  selected during implementation and only their served APIs are used, installed from their own
  pinned artefacts. If the allocation authority fails its gate item, the consequence is FR-104: a
  stop and a recorded operator decision, never a silent substitute.
- The device image is publicly pullable without registration for lab, demonstration, test and CI
  use, and can be pinned by digest. The release chosen is the newest for which every part of the
  compatibility set has a matching artefact, not the newest the vendor publishes. If the pinned
  image fails the capability gate, the gate's failing item is fixed or the affected construct is
  reported unqualified; the gate is not relaxed.
- Production migration is performed service by service with parallel validation; automated cutover
  of a live legacy network is out of scope.
- EVPN multihoming, IPv6 VXLAN tunnel endpoints (which the platform does not support), SRv6 in any
  form, service chaining, multicast VPN and feature-exact QoS or OAM translation are out of scope.
- The render contract per construct is new for this platform and is fixed by golden files whose
  serialization is frozen only after the capability gate has observed what the device returns. As
  decided (AD-81), G12 observed module-prefixed (RFC 7951) identityrefs and the goldens freeze that
  form; the offline validator's refusal of it is handled on a normalised copy of its input only.
- A local `vlan` is worth having as its own construct even though it does not leave the node,
  because it is one of the four cited references and it is the base the other L2 construct extends.
  The consequence is that it is carried as its own construct and its own list on the service intent
  object, never as a `mac-vrf` with its overlay fields absent (FR-029), and it claims no overlay
  identifier.
- Access lists are rendered and verified through the same declarative apply-and-read-back
  discipline every other construct uses, and no new class of device interaction is introduced.
  Enforcement is demonstrated in acceptance by a probe and the matching counters; it is never a
  condition of readiness, and any property the platform has not observed is reported as unverified
  rather than claimed.
- Access lists bind to attachment subinterfaces only — which is how the platform expresses a
  filter on a port and VLAN. Binding to a network instance, an integrated-routing interface or
  fabric-wide is out of scope.
- Access-list scope is stage, address family, prefixes, IP protocol, L4 ports, permit and deny.
  Layer 2 (MAC) lists, TCP flags, DSCP, TTL and fragment matching, ICMP type and code, logging,
  mirroring, rate limiting, control-plane and system filters and policy-based forwarding are out
  of scope and refused by name.
- One construct per request is the shape of a provisioning exchange; a request naming two
  constructs is handled by the existing clarification path rather than a new multi-service
  transaction.
- Confirmation is human. Unattended or policy-driven auto-approval is out of scope and would
  require its own specification.
- Lab-scale concurrency: a single operator with a small number of concurrent conversations on the
  single-host lab, not a production multi-tenant service. The consequence is that concurrency is
  arbitrated rather than engineered for: two conversations that reach for one identifier or one
  attachment are resolved by the allocation authority and the one-owner rule, and the loser fails
  with the conflicting value named (FR-062, FR-034) — no queue, no fair-share and no throughput
  target is specified, and none may be assumed.
- Model quality is not a system guarantee. Interpretation accuracy is bounded by the model; the two
  confirmation gates, schema validation and unsupported-construct rejection are the controls that
  make an imperfect interpretation safe. SC-020 measures quality, but the safety properties
  (SC-027 through SC-030) do not depend on it.
- Two telemetry sinks, one emission. The fabric observability stack remains authoritative for
  fabric health; the agent-analytics store is additive. Two parallel instrumentations of the same
  activity are a defect.
- Identifier allocation stays with the existing authority. The intent tier requests identifiers; it
  is not an allocation authority and holds no allocation state of its own.
- The service intent object keeps the list names the merged specification used (`vlans`,
  `bridgeDomains`, `routers`, `accessLists`, `attachments`) so that the translator contract, the
  tier's contracts and the golden-file shape are stable; the construct vocabulary is the operator
  vocabulary, and the object's field names are its render shape.
