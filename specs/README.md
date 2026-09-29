# Specification registry

> **2026-09-20:** the folders for 001, 002 and 003 described below are archived at
> `specs/.archive/001-003-sources-2026-09-20.tar.gz` and no longer present under `specs/`. Only
> 004 is live. This registry is kept as their record.

One row per feature specification in this repository, with what it delivers, where it
closed, what it supersedes, and which deployment surfaces it owns.

This file is the project's registry. Two things read it:

- **A reader** asking which specification is current, what state it is in, and whether
  its recorded status can be trusted.
- **The ownership ladder** of `/spec-reconcile` (rung 3), which uses the **Completes**
  column below to decide, when two specifications both name a surface, that the
  specification completing the milestone owns the **runtime behaviour** while the
  earlier one keeps the **schema and the shape** of the file.

Created 2026-09-20, from the specification texts and the git history cited in each cell.
It records no status that a cited artefact does not carry. Where the loop's own approval
records assert something the reconciliation sheets found untrue, this file states the
approval **and** the contradiction, rather than repeating the approval alone.

`specs/` is gitignored, so this registry is untracked, like every other spec-kit artefact
here.

## Milestones

The milestones are **derived** for this registry: no specification declares an `M`
identifier. Each is the scope its specification states in its own words, and the
citation is that statement.

| Milestone | Scope | Owned by | Stated at |
| --- | --- | --- | --- |
| **M1 — declarative control plane** | The SONiC EVPN/VXLAN fabric, its resources, and the controllers that reconcile them. Explicitly excludes the intent tier. | 001 | `001/spec.md:21` "This specification covers the **declarative control plane only**: the fabric, its resources, and the controllers that reconcile them" |
| **M2 — multi-agent intent tier** | A conversational supervisor and three worker agents turning natural language into declarative fabric intent, above the M1 boundary, plus the chat surface and agent-tier observability. | 002 | `002/spec.md:6-11` "Restore the multi-agent intent tier that the subject project … and that feature 001 did not carry forward" |
| **M3 — datacenter construct vocabulary** | The four datacenter constructs (`vlan`, `mac-vrf`, `ip-vrf`, `acl`) replacing the service-provider service names end to end, and the ACL construct the tier did not have. | 003 | `003/spec.md:13` "The tier today advertises four **service-provider** service names" and `003/spec.md:249` "constructs — `vlan`, `mac-vrf`, `ip-vrf`, `acl` — and MUST NOT advertise any" |

**Completes.** 002 does not complete M1; it layers above it (`001/spec.md:19-24` names the
intent tier a non-goal of M1, and 002 restores it as M2). 003 completes **M2's
operator-facing vocabulary and its service catalogue**: it replaces the four names the
tier advertises and adds the `acl` construct, so the **runtime behaviour** of the
construct vocabulary, the interpretation schema and the ACL render belongs to 003, while
002 keeps the **shape** of the intent path it introduced (the A2A transport, the
supervisor HTTP surface, the Kubernetes objects of the tier).

## The specifications

| Id | Title | Branch | Created | Closed at | Recorded gate state | Status |
| --- | --- | --- | --- | --- | --- | --- |
| **001** | Agentic NetOps SONiC EVPN/VXLAN Fabric | `001-agentic-netops-sonic-evpn-fabric` | 2026-08-28 | **Never formally closed.** Last approved phase is `5a8eb118` (2026-08-29, "wiggum: phase 7 approved — Telemetry and operations (US4)") | Phases 1–7 approved; phase 8 has `GATE8-FEEDBACK.md` and no approval; no phase 9 gate | **Open.** `spec.md:5` still says Draft. Its reconciliation found 42 claims that never held |
| **002** | AGNTCY Intent Tier | `002-agntcy-intent-tier` | 2026-09-01 | `580ade19` (2026-09-03, "Merge 002-agntcy-intent-tier: one source of truth"). The branch still exists locally | Phases 1–11 approved, `b749ec1f`…`279bf88b` (2026-09-01/02) | **Merged, with its acceptance record in dispute.** `spec.md:5` says Draft |
| **003** | Datacenter Service Constructs | `003-datacenter-service-constructs` | 2026-09-05 | `7d236e3a` (2026-09-06 15:22), landed in the same minute as `GATE8-APPROVED` | Phases 1–8 approved (`.wiggum/features/003-datacenter-service-constructs/gates`) | **Latest closed specification.** `spec.md:7` says Draft; two of its gates rest on fabricated evidence |
| **004** | Agentic NetOps on Nokia SR Linux — Composite Platform | `004-agentic-netops-composite` (no git branch: this repository is not under version control) | 2026-09-20 | **Not closed.** No implementation exists in this repository | No gate has run. `tasks.md` exists (T001–T175, generated 2026-09-20); every checkbox in it is `[ ]`. Two reviewer-owned checklists gate implementation and are fully unticked: `checklists/requirements.md` and `checklists/clarify-delta.md` | **Draft — the only specification used for deployment.** Consolidates 001–003 and retargets them from SONiC to SR Linux. `spec.md` says Draft and claims no observed result |

No `tasks.md` in this repository marks a single task done: every checkbox in all three
task lists is `[ ]` (001 T001–T091, 002 T001–T468, 003 T001–T088). Completion is asserted
only by the gate records and the phase-approval commits above, which is why those are the
rows a reconciliation checks.

## 004 — the composite, and the only deployment target

Added 2026-09-20. Feature 004 is not a fourth milestone beside M1–M3: it **consolidates all three
into one specification and retargets the platform from SONiC to Nokia SR Linux**, for a new
greenfield repository (`agentic-netops-srl`) that contains specifications only.

- **What it supersedes.** For deployment purposes, all of 001, 002 and 003. They are history and
  the source side of `004/traceability.md`; nothing is implemented from them here.
- **Where 001–003 went.** Archived unmodified on 2026-09-20 to
  `specs/.archive/001-003-sources-2026-09-20.tar.gz` (40 files, verified by extraction and
  recursive diff before removal) and **removed from `specs/`**. Every `001/…`, `002/…` and `003/…`
  path in this registry, including the three reconciliation sheets, resolves against that archive.
- **What it carries forward honestly.** The three approval records under dispute below travel with
  it (`004/spec.md` §Inherited acceptance record), together with a fourth contradiction found
  during the retarget research: the predecessor never ran the upstream fabric control plane,
  allocation authority or device-configuration layer at all — its install scripts fell back to
  hand-written look-alike CRDs in look-alike API groups (`004/evidence/05-kubenet-sdc-kuid.md` §0).
- **What it decides.** The six decisions the consolidation left open and the six gaps it recorded
  are closed: `004/spec.md` §Retarget decisions and §Gaps closed by the retarget; the record is
  RD-01…RD-15 in `004/research.md` §11, with row-by-row coupling resolutions in
  `004/platform-coupling.md` and the research evidence under `004/evidence/`.
- **What it retires.** SRv6 (001's US5 and its requirements) is deferred to a future feature that
  does not exist yet; the identifiers keep tombstones in 004.
- **Surfaces owned.** None are deployed. When implementation starts, 004 owns every surface listed
  for 001–003 below, under the SR Linux names its plan gives them.
- **Baseline.** The pre-retarget (SONiC-era) text of the composite is preserved at
  `specs/.archive/004-composite-sonic-baseline-2026-09-20.tar.gz`, because this repository has no
  version history to recover it from.
- **Spec-kit state.** `.specify/feature.json` points at `specs/004-agentic-netops-composite`, and the
  constitution was amended to v1.1.0 on 2026-09-20 for the platform change.

## Identifier ranges

Task numbering restarts at `T001` in every `tasks.md`, and the requirement ranges overlap:

| Id | Tasks | Requirements | Success criteria |
| --- | --- | --- | --- |
| 001 | T001–T091 | FR-001–FR-033, NFR-001–NFR-005 | SC-001–SC-016 |
| 002 | T001–T468 | FR-001–FR-039, NFR-001–NFR-007 | SC-001–SC-016 |
| 003 | T001–T088 | FR-001–FR-024 (26 with lettered ids) | SC-001–SC-007 |
| 004 | T001–T175 (none done) | FR-001–FR-109 (5 of them retired tombstones), NFR-001–NFR-014, CR-001–CR-010 | SC-001–SC-050 (2 retired tombstones) |

**A bare task or requirement number is therefore not evidence of which specification a
commit belongs to.** Write it specification-qualified — `002 T314`, or the `001:FR-0xx`
form `002/spec.md:47` adopts — or name the specification in the commit subject.

## Supersedes

Each row is a claim of an earlier specification that a later one replaced, with the
citation that says so. These are the rows a reconciliation marks `superseded` rather than
`drifted`.

| Superseded claim | By | Evidence |
| --- | --- | --- |
| `002/contracts/supervisor-http.md:88-91` `GET /suggested-prompts` for the four service names | 003 | Served prompts moved to the constructs in `d14f3e1b`, `12144252` (2026-09-06); `003/spec.md:249` forbids advertising the old names |
| `002/contracts/normalized-service-intent.schema.json:11` `type` enum `VPLS`/`VPWS`/`L3VPN`/`IRB`, "not extensible" | 003 | `agents/common/schemas/interpretation.py:25-35` is `vlan`/`mac-vrf`/`ip-vrf`/`acl`, legacy names folded; `003/contracts/construct-vocabulary.md` |
| `002/contracts/normalized-service-intent.schema.json:36` `endpoints.minItems: 2` | 003 | `003/research.md` Decision 11 sets vlan/ip-vrf/acl at one endpoint |
| `002/research.md:231-235` KUID claims against `id.kuid.dev` | 003 | `003/contracts/kuid-claim-profiles.md`; the code targets the served `*.be.kuid.dev` groups |
| `002` runbook vocabulary (`docs/INTENT_TIER_RUNBOOK.md:3`) | 003 | Runbook rewritten to the constructs |

001 has no superseded claims recorded. Its intent-tier exclusion (`001/spec.md:19-24`) was
not superseded; it was **answered** by 002, which took the excluded scope as M2.

## Surfaces owned

Where a deployed fact names one of these surfaces and no claim covers it, this column is
the rung-1/rung-3 answer.

| Id | Surfaces |
| --- | --- |
| 001 | The containerlab fabric and `lab/`; `deploy/kubenet`, `deploy/kuid`, `deploy/sdc`, `deploy/gnmi`, `deploy/rbac`, `deploy/agentic-netops`; `config/crd`, `config/kind`; the SONiC provider and its controllers; `versions.lock.yaml` outside `intent_tier:`; observability for the fabric; `contracts/crd-api.md`, `contracts/reconciliation.md` |
| 002 | `deploy/agents/*`; `agents/` (supervisor, workers, common, corpora); `docker/Dockerfile.*`; `ui/`; `cmd/intent-translator`; `versions.lock.yaml` `intent_tier:`; the tier's Kubernetes objects, A2A/SLIM transport and supervisor HTTP surface |
| 003 | The construct vocabulary and interpretation schema; `pkg/migration` construct translation and `cmd/migration-translator`; the ACL render in `pkg/fabricplan` and `pkg/render`; KUID claim profiles; the suggested-prompt vocabulary; `controllers/sonicprovider/network_controller.go` dispatch of construct-typed objects |

The `fabric-compat-pins` ConfigMap (`scripts/provision.sh:230-252`) is the one surface
both 001 and 002 name. It resolved to **002** by the rung-3 rule above, recorded as row
150 of the 002 sheet.

## Reconciliation sheets

Each sheet is one run of `/spec-reconcile` against the deployment as read on its date.

| Id | Sheet | Rows | Blocking | Note |
| --- | --- | --- | --- | --- |
| 001 | `001-agentic-netops-sonic-evpn-fabric/reconciliation-2026-09-19.md` | 96 | 36, 77, 78, 79, 80, 82 | 30 hold, 42 never held, 19 unverifiable |
| 002 | `002-agntcy-intent-tier/reconciliation-2026-09-19.md` | 150 | 137, 138, 146 | 90 hold, 18 never held, 26 unverifiable, 5 superseded |
| 003 | `003-datacenter-service-constructs/reconciliation-2026-09-19.md` | 94 | 19, 53, 54, 81, 85, 86, 87, 88 | 65 hold, 16 never held, 8 unverifiable |

On 2026-09-19/20 the runtime was absent — no `agentic-netops` Kind cluster and no
containerlab fabric on the host — so 53 rows across the three sheets are `unverifiable`
until the lab is rebuilt.

## Approval records under dispute

Recorded here because a registry that repeats an approval without its contradiction is
the failure Principle I of `.specify/memory/constitution.md` names. Each row is an
approval this repository carries, followed by what the reconciliation found against it.

| Approval record | What it asserts | Contradiction |
| --- | --- | --- |
| 001 phases 1, 2, 3, 5, 7 (`b749ec1f`, `3742d404`, `3eb8c775`, `41b6816c`, `5a8eb118`) | Pins immutable; a profile passed the EVPN+SRv6 gate; Kubenet/KUID/SDC healthy; SRv6 services converge; metrics healthy and alerts firing | 001 sheet rows 77, 78, 79, 80, 82: placeholder digests, an image with no gNMI server, SRv6 never conformant, alert rules that never loaded |
| 002 phase 11 acceptance report (`docs/INTENT_TIER_ACCEPTANCE_REPORT.md`) | SC-003 and SC-004 passed; "Go"; SC-013 verified in the tier-absent CI job | 002 sheet rows 137, 138: the SC-003 check is inverted (`agents/tests/simulation/report.py:191-193`), the SC-004 cell is the literal `0.00%` (`:294`), and the CI job runs pins, register and unit tests only |
| 003 GATE4 (T044a) and GATE8 (T082, T083, T088) | Ready=True across six objects; ACL rows on both leaves; pins unchanged | 003 sheet rows 81, 85, 86, 87, 88: proofs contradicted by genuine captures in the same folder, a Network object that never existed, and digest pins present in no commit |

## Adding a specification

A new row here is part of closing a feature, not an afterthought:

1. Add the row to **The specifications** with the close commit and the honest gate state.
2. Add its milestone to **Milestones**, and say in **Completes** which earlier milestone
   it completes, if any — that is the cell the ownership ladder reads.
3. Add its task and requirement ranges to **Identifier ranges**.
4. List anything it supersedes, with the citation.
5. List the surfaces it owns.
6. Link its reconciliation sheet once one exists.
