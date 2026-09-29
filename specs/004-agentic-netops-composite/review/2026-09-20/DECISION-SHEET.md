# Decision sheet — review of 2026-09-20

**Scope**: the five design choices an analysis agent made without asking the operator (AD-16, AD-17,
AD-23, AD-26, AD-27; AD-24 reviewed beside AD-26), and both reviewer-owned checklists. Seven research
agents, one report each, in this directory. **Nothing in the specification was changed and no
checkbox was ticked.** Every proposal below is a proposal; the reports carry the `file:line` and URL
citations. Two of the agents' claims were spot-checked by the coordinating session: T093's guard
(`tasks.md:335`) does require a `Network` read the allocator agent does not have, and no file outside
this directory was modified.

## 1. Verdicts on the five choices

| Decision | Verdict | What stands | What the research overturned |
|---|---|---|---|
| **AD-23** `Fabric` readiness without a route count | Ratify with amendments (A1–A7) | The premise is true: SR Linux originates EVPN routes only from an instance with `bgp-evpn`, so zero routes at `FabricReady` is correct | `inter-as-vpn` is a **config leaf**: reading it "from state" proves application, not reflection — R-46's wording is wrong. The read-back misses `route-reflector/client` and the EVPN family's per-neighbour `oper-state`. The `EvpnRoutesLost` alert fires on exactly the state AD-23 blesses. Quickstart §4 lacks the family command, §8 the negative control |
| **AD-16** provider is the one release owner of a submitted service's claims | Ratify with amendments (P1–P5 required) | The principle; KUID v0.0.13 verified from source: `spec.id` / `status.id`, duplicate static claim refused at CREATE naming the holder, synchronous release, namespaced claims | Three holes: (1) an `ip-vrf`'s allocated VLAN lives only in mutable `attachments[].vlan`, so adoption can lapse and leak; (2) no finalizer between apply and first reconcile — a delete while the provider is down orphans the claims; (3) **T093's "refuse release if the `Network` exists" needs a read FR-075 denies the allocator** — the same widening AD-27 refused |
| **AD-27** allocated-VLAN collision refused by name | Ratify with amendments (P10–P12) **plus one open operator choice (P13)** | The refusal is the only outcome for a holder in `agentic-netops-services`; unreachable in the frozen walkthrough | Per-port indices do not help (named VLANs are unclaimed either way). Unconsidered structural fix: **split the band** — allocate from 1000–4000, name from 100–999 — makes the collision impossible with no RBAC change. Whether KUID allocates lowest-first (→ G11) decides if the collision is rare or routine |
| **AD-17** drift policy closed at `revertive` | Ratify the mechanism, **correct the rationale** | Required, no default, one value: the only thing that enforces FR-015's "never inherited from the lab". Maps to the real field `Config.spec.revertive` (`*bool`, no CRD default) | "SDC's only other behaviour is accepting the device's value" is **false** at the pin: non-revertive records a deviation the operator can revert (`DeviationClear`). So "needs a constitution amendment" goes. **T036 is unimplementable** — none of the four onboarding CRs has a revertive field. **T064 may assert a `Deviation` that revertive mode never leaves behind** (proposed gate item G13) |
| **AD-26** tier removal deletes its services | Ratify the machinery, **reverse the default** | List-first, export-first, bounded 300 s script wait, never force-release, the `agentic-netops-services` namespace | No requirement asked for the deletion and its carriers were amended to justify it; the predecessor's uninstall deliberately left services alone and its postmortem records a surprise incident fixed by an opt-in gate. Recommended: **refuse while tier-submitted services exist unless `--remove-services`**. Also: quiesce supervisor/UI/deployer before the wait |
| **AD-24** audit export before store removal | Ratify with amendments | The principle | Format, failure definition, timeout, re-run idempotence against SC-040's post-edit check, and how SC-030/SC-042 reconcile from the exported file are all unspecified |

## 2. Decisions that are the operator's

1. **AD-26 default** — (a) delete services on purge *(current)*; (c) refuse unless `--remove-services` *(recommended by the research)*; (b) keep services and the namespace.
2. **AD-27 VLAN bands** — keep one shared 100–4000 range with refusal-by-name *(current)*; or split: named 100–999, allocated 1000–4000 *(removes the edge case; costs the freedom to name a VLAN ≥ 1000 and one rewritten sentence in R-28's wake)*. Optional either way: a pre-confirmation occupied-VLAN exclusion through the deployer (no FR-075 widening).
3. **AD-17** — keep the closed set of one with the rationale corrected *(recommended)*; or admit `non-revertive` + `DeviationClear` now; or hard-wire revertive.
4. **AD-23** — ratify with A1–A7 *(recommended)*; or the canary EVPN instance.
5. **AD-16** — ratify with P1–P5. For hole (3) one of two things must move: the guard off the allocator (recommended: the deployer, which can read `Network`s, tells the release path), or FR-075 widened.
6. From the checklists: promote the force-release guard rules and the open-finding `OwnershipConflict` into FR-103 (CHK002); whether FR-104 / FR-106 / FR-108 / NFR-014 deliberately have no success criterion (CHK027); name the probe-route exception inside FR-102; require claims to carry labels naming the adopting object (CHK033 — overlaps AD-16 P5 / R-45).

## 3. Checklist triage (nothing ticked)

| Checklist | Items | Supported / answered | Partial | Open / not supported | Stale | Judgement |
|---|---|---|---|---|---|---|
| `requirements.md` part A (CHK001–090) | 90 | 80 | 8 | 0 | 1 | 1 |
| `requirements.md` part B (CHK091–135) | 45 | 33 | 10 | 0 | 1 | 1 |
| `clarify-delta.md` | 40 | 5 | 23 | 7 | — | 5 |

Highest-value open items: **CHK033** (a `kubectl`-applied object copying a correlation label can adopt
another service's claim — the one reachable correctness defect); **CHK028** (SC-011, 019, 027, 033,
034, 035 name no verification method); **CHK128** (the denied-port enumeration disagrees three ways;
SNMP 161 and 50052/57410/57411 are documented open and never probed); **CHK006** (`VerificationFailed`
listed, never defined; a re-verification that cannot run has no outcome); **CHK035/clarify** (FR-106
"print the endpoint" vs FR-079 redaction for a credential-bearing base URL); **CHK026** (FR-109,
NFR-003, FR-078, FR-015 each bundle 5+ obligations — propose an obligations index, no renumbering);
**CHK083** (`STATUS_UNKNOWN` never stated as not-a-success); **CHK110/CHK135** ("asserted in CI" with
no carrier). Stale items to reword in the checklist itself (reviewer's file): CHK020, CHK097, and the
`## Readiness result` block. **Coverage gap**: CR-008 is reviewed by neither checklist; SC-045/SC-046
only through a range.

## 4. New unknowns to observe at the capability gate

G8: whether `inter-as-vpn` is required at all; EVPN family `oper-state` populated on the emulated node.
G4: whether `--type state` returns config-only leaves. G11: whether KUID dynamic allocation is
lowest-first; where the correlation label must sit for label-selector listing. Proposed **G13**: what
`Deviation` artefact, if any, revertive mode leaves for T064 to assert.

## 5. Reports

`AD-23-fabric-readiness.md` · `AD-16-AD-27-claims.md` · `AD-17-drift-policy.md` ·
`AD-26-AD-24-tier-removal.md` · `checklist-requirements-part-A.md` ·
`checklist-requirements-part-B.md` · `checklist-clarify-delta.md`

## 6. Outcome — decided and applied 2026-09-20

The operator answered §2: **AD-26 → refuse unless `--remove-services`**; **AD-27 → split the VLAN bands**
(named 100–999, allocated 1000–4000); **AD-17 → keep `{revertive}`, correct the rationale**; **apply all
recommended amendments** (AD-23 with A1–A7, AD-16 with P1–P9 and the submitted-check moved to the
deployer, AD-24's export design, the checklist shortlist). Each research agent applied its own
amendments through a locked editor; decisions are `AD-31`…`AD-39` in `research.md` §13; each report
ends with an "Applied 2026-09-20" log. Added: SC-047…SC-050, gate item G13, risk R-48, task T175.
Pre-edit snapshot: `specs/.archive/004-pre-review-remediation-5-2026-09-20.tar.gz`. Both checklists are
untouched and unticked. **Left for the reviewer**: CHK127 / CHK128(a) (they require MTU numbers and
addresses in `spec.md`, which CHK001 forbids — an item-versus-item conflict); the stale checklist
items CHK020, CHK097 and the `## Readiness result` block; CR-008 is reviewed by neither checklist.
**Not done, by decision**: no cluster-wide `Network` read for the deployer (the admission webhook is
the authority; FR-075 unwidened).
