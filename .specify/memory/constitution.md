<!--
SYNC IMPACT REPORT
==================
Version change: 1.0.0 → 1.1.0
Bump rationale: MINOR. The "Additional Constraints and Standards" section is
materially changed for a new target platform (Nokia SR Linux replaces SONiC).
No principle is added, removed or redefined, and no governance rule changes,
so this is not MAJOR; it is more than wording, so it is not PATCH.

Modified principles: none. Principles I–VI are unchanged word for word.

Modified sections (Additional Constraints and Standards):
  - Technology stack: SONiC 202505 / FRR 10.3 / containerlab `sonic-vs`
      → Nokia SR Linux 25.7.1 (native BGP/EVPN), containerlab `nokia_srlinux`,
        SDC (sdcio) as the device-configuration layer, KUID as the allocation
        authority; Kubernetes node image pinned by digest in the lock file.
  - Network policy: underlay Jumbo MTU 9216 / payload 9166 (IPv4) / 9162 (IPv6)
      / ~9120 with 3 SRv6 SIDs
      → fabric port MTU 9412 / underlay IP MTU 9398 / tenant IP MTU 9348, IPv4
        tunnel endpoints only; acceptance probes 9320 (IPv4) and 9300 (IPv6)
        ICMP payload. SRv6 arithmetic removed (SRv6 is out of scope on this
        platform; specs/004 RD-04).
  - Known limitation: the FRR IPv6 IRB Type-5 defect is removed (no FRR).
      Replaced by: IPv6 anycast gateway / IPv6 Type-5 origination is unproven
      upstream and is a capability-gate item; same Ready=False obligation.
  - Added: "Evidence" constraint (run-captured evidence, negative controls),
      recording the lesson of the predecessor's disputed approval records.

Added sections: none.  Removed sections: none.

Templates requiring updates:
  ✅ .specify/templates/plan-template.md   (Principle VI gate: MTU numbers)
  ✅ .specify/templates/tasks-template.md  (Tests category: MTU numbers)
  ✅ .specify/templates/spec-template.md   (reviewed; no platform-specific text)
  ✅ .specify/memory/constitution.md       (this file)
  ⚠ README.md — no repository README exists yet in agentic-netops-srl; when one
     is written its "Known limitations" and "Policies enforced in CI" sections
     must state the MTU, pinning and IPv6 gateway facts encoded here.

Evidence for the numbers and the platform facts:
  specs/004-agentic-netops-composite/evidence/01-lab-platform.md §8 (MTU,
  measured in research on SR Linux 26.7.2 — re-observed on the 25.7.1 pin by
  the capability gate before it is relied on), 02-evpn-constructs.md §1, §5.

Follow-up TODOs: none. No placeholder tokens remain.

---- previous report (1.0.0), kept for history ----
Version change: (none) → 1.0.0
Rationale: Initial ratification. No prior constitution existed at
.specify/memory/constitution.md; the file is created from
.specify/templates/constitution-template.md with all placeholders filled.

Modified principles: none (initial adoption)

Added sections:
  - Core Principles I–VI
      I.   Truthful, Closed-Loop Reporting
      II.  Intent Tier Drives the Network, With Explicit Safety Gates
      III. Declarative, Deterministic Operations
      IV.  Observability-First
      V.   Reproducibility and Supply-Chain Pinning
      VI.  Verification and Test Discipline
  - Additional Constraints and Standards
  - Development Workflow and Quality Gates
  - Governance

Removed sections: none

Template slots: the template ships five principle slots; a sixth
(VI. Verification and Test Discipline) was added as the template permits,
with heading hierarchy preserved.

Templates requiring updates:
  ✅ .specify/templates/plan-template.md   (Constitution Check gates filled)
  ✅ .specify/templates/spec-template.md   (constitution-mandated constraints noted)
  ✅ .specify/templates/tasks-template.md  (principle-driven task categories noted)
  ✅ .specify/memory/constitution.md       (this file)
  ✅ README.md — reviewed; existing "Known limitations" and "Policies enforced
     in CI" sections already state the MTU, pinning, and IPv6 Type-5 facts this
     constitution encodes. No edit required.

Follow-up TODOs: none. No placeholder tokens remain.
-->

# agentic-netops Constitution

## Core Principles

### I. Truthful, Closed-Loop Reporting

The system MUST report only success it has observed.

- A deployment is reported as "submitted" only after every apply has succeeded.
- `Ready=True` MUST reflect current live fabric state verified on devices, never
  historical success or a prior reconciliation result.
- Convergence MUST be re-verified on a schedule (~5 minutes); detected drift MUST
  be repaired.
- Status conditions MUST name the specific missing invariants (routes, VTEPs,
  BGP sessions, data path) rather than reporting ambiguous or partial success.

Rationale: an operator acting on a false "healthy" is worse off than one acting
on an honest failure. Every claim this system makes is a claim someone will trust
without re-checking.

### II. Intent Tier Drives the Network, With Explicit Safety Gates

The multi-agent intent tier (supervisor, mapper, allocator, deployer) is the
first-class control plane, not a convenience layer over it.

- Provisioning MUST require two explicit human confirmations.
- One-shot requests MUST NOT provision under any circumstance.
- Inputs referencing non-existent nodes or ports MUST be rejected up front, and
  the rejection MUST enumerate concrete valid alternatives.
- The tier MUST NOT present or provision a service type the operator did not ask
  for.
- All actions MUST be auditable and written for operator clarity.

Rationale: an agent that can change a fabric must be harder to trigger by
accident than by intent, and must fail loudly on bad input rather than guessing.

### III. Declarative, Deterministic Operations

Every change MUST follow the same deterministic transaction:
translate → server-side dry-run → apply → rollback on failure → convergence watch.

- Reconciliation MUST be idempotent and deterministic: identical intent yields
  identical cluster state.
- Unrenderable objects MUST NOT be stranded on the cluster; a failed translation
  leaves nothing behind.
- Teardown MUST be idempotent and safe to re-run.

Rationale: a transaction that can be replayed and rolled back is a transaction an
operator can reason about at 3 a.m.

### IV. Observability-First

End-to-end telemetry is mandatory, not an add-on: gNMI → Prometheus → Grafana.

- Logs MUST be structured and meaningful; controller conditions MUST be surfaced,
  not buried.
- Observability MUST be sufficient to verify underlay and overlay health (BGP,
  EVPN Type-2/3/5, remote VTEPs, data path) and to diagnose regressions quickly.
- A change that alters what can be observed MUST update dashboards and docs in the
  same change.

Rationale: Principle I is only enforceable if the evidence for a health claim is
collectable and visible.

### V. Reproducibility and Supply-Chain Pinning

All images and binaries MUST be pinned in `versions.lock.yaml`, and CI MUST
enforce those pins via `make verify-pins`.

- Intent-tier images MUST have a local build step.
- Known exceptions MUST be explicitly warned at provisioning time and tolerated
  only where documented with a remediation plan.
- Builds MUST be reproducible; deviations MUST fail fast with actionable errors
  rather than degrading silently.

Rationale: an unpinned dependency turns every future failure into an
un-bisectable one.

### VI. Verification and Test Discipline

Integration tests (`fabric_verify` for BGP, EVPN, and data path) and unit tests
MUST protect core behavior.

- Acceptance tests MUST size packets per the Jumbo MTU policy below.
- Any change affecting convergence semantics or published contracts MUST update
  or extend the tests that cover them.
- A gate MUST NOT be waived to make a run pass; if a gate cannot hold, the
  limitation is documented and the affected service reports `Ready=False`.

Rationale: the guarantees in Principles I and III are only as real as the tests
that would catch their absence.

## Additional Constraints and Standards

**Technology stack**: Nokia SR Linux 25.7.1 (native BGP and EVPN) on containerlab
with the `nokia_srlinux` kind; Kubernetes on Kind with the node image pinned by
digest; SDC (sdcio) as the device-configuration layer over gNMI; KUID as the
allocation authority; gNMIc, OpenTelemetry collector, Prometheus, Grafana. The
device image, its YANG model tag, the device-configuration schema definition and
the first-party mapping version are pinned together as one compatibility set.

**Network policy**: fabric port Jumbo MTU 9412 (the emulated platform's maximum)
with underlay IP MTU 9398. VXLAN tunnel endpoints are IPv4; the effective tenant
IP MTU is 9348 for both tenant address families, and endpoint interfaces MUST be
set to it. Tests MUST size packets accordingly to avoid fragmentation: the
largest passing ICMP payload is 9320 (IPv4) and 9300 (IPv6), and one byte more
MUST fail. These values are re-observed by the capability gate on the pinned
image before any test relies on them. Tests MUST NOT assert throughput: the
containerized dataplane forwards only a few thousand packets per second.

**Known limitation**: an IPv6 anycast gateway and IPv6 Type-5 origination have no
published reference on this platform and are therefore a capability-gate item
rather than an assumption. Where the gate or a service's read-back shows the
IPv6 Type-5 route missing, the affected service MUST report `Ready=False` with
explicit rationale naming the missing route rather than claiming success.

**Evidence**: a gate or acceptance result counts only as evidence captured by the
run that claims it — command, time, exit status, image digest and lab identity
with the raw output — and a readiness check counts only after it has been shown
to fail on a stock fabric. Hand-authored proof is non-conforming.

**Secrets and LLM configuration**: credentials MUST NEVER be committed. A base URL
MUST be set for gateway providers (e.g. Compass/Core42) so the OpenAI default is
not silently used. Re-provisioning MUST preserve an existing Secret's base URL
unless it is explicitly changed.

**Safety**: endpoints naming nodes or ports that do not exist MUST be refused, and
the refusal MUST enumerate the valid names.

## Development Workflow and Quality Gates

Every PR MUST:

- Pass tests.
- Pass `make verify-pins`.
- Update docs and dashboards when observability changes.
- Include operator-facing rationale for any behavior change.

Additional gates:

- Deterministic apply and truthful reporting are quality gates: a deployment MUST
  NOT claim success before observation, and controllers MUST set precise
  conditions.
- Any pinned-image exception MUST be documented and MUST carry a remediation plan.
- Changes to agent behavior affecting confirmations, refusal logic, or transaction
  phases MUST be reviewed by an operator and tested in the lab before merge.

## Governance

This Constitution supersedes ad-hoc practices for this repository. Compliance is
required for acceptance.

**Versioning**: semantic versioning applies to this governance document.

- MAJOR: breaking governance changes, or removing/redefining principles.
- MINOR: adding or materially expanding a principle or section.
- PATCH: clarifications, wording, and typo fixes with no semantic change.

**Amendments**: proposed via PR carrying a side-by-side diff, rationale, and any
required migration notes. The PR MUST include the updated version, an updated
`LAST_AMENDED_DATE`, and a sync impact summary.

**Compliance review**: reviewers MUST check principle compliance, CI policy
adherence, observability signals, and the test coverage relevant to the change.

**Template sync**: after any amendment, the Spec, Plan, and Tasks templates MUST
be updated to reflect newly mandatory constraints (observability, versioning,
testing, safety gates).

**Version**: 1.1.0 | **Ratified**: 2026-09-05 | **Last Amended**: 2026-09-20
