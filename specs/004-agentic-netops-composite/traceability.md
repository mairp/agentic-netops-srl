# Traceability: composite ↔ source

**Feature**: `004-agentic-netops-composite` | **Date**: 2026-09-20

This specification was produced in **two passes**, and this file has to survive both.

1. The **merge** consolidated features 001, 002 and 003 into one document. Every composite
   identifier traced to a line in one of the three source specifications.
2. The **SR Linux retarget** moved that document from SONiC to Nokia SR Linux. It changed the
   *text* of many requirements, retired a few outright and added others, but it **renumbered
   nothing**. A requirement retired by the retarget keeps its number and its source mapping; a
   requirement the retarget added takes the next free number and has no source.

So a source identifier still resolves here after both passes, and a composite identifier still
tells you where it came from — or says plainly that it came from the retarget and from nowhere
else. Two tables, one per direction.

- **Forward** — one row per composite identifier, with the source line or lines it came from,
  whether it is carried verbatim, and any note. **No composite identifier is absent from it**,
  including the identifiers the retarget added and the identifiers it retired.
- **Reverse** — one row per source identifier, so a reader holding `002:FR-029` can find where it
  went. **Every functional requirement, non-functional requirement, success criterion, user story,
  research decision and risk across all three sources appears in it**, including those that were
  merged away, superseded, or retired by the retarget.

**Where the sources are.** The three source folders were archived unmodified on 2026-09-20 to
`specs/.archive/001-003-sources-2026-09-20.tar.gz` and removed from `specs/`. Every source
identifier, file-and-line citation and reconciliation-sheet row in this file resolves against that
archive (`tar xzf` it anywhere; the folder names inside are the original ones). This repository has
no version history, so the archive is the only copy kept here; an identical copy also sits in the
predecessor repository at `/root/agentic-netops/specs/`, outside version control there too.

Source identifiers use the qualified form the sources themselves adopted: `001:FR-0xx`,
`002:NFR-0xx`, `003:SC-0xx`, `002:D-04` for `002/research.md` Decision 4, and `003:plan R-02` for a
row of that plan's risk table. `001:plan risk N` cites a row of an unnumbered table by its position.
Retarget decisions are cited as `RD-01` to `RD-15` and live in [research.md](./research.md) §11;
platform coupling rows are cited as `PC-xx` and live in
[platform-coupling.md](./platform-coupling.md).

**Disposition vocabulary** (reverse table — what happened to a *source* identifier)

| Value | Meaning |
|---|---|
| `carried` | The requirement survives as one composite requirement |
| `merged` | It is stated once, jointly with another source requirement, at the strongest wording |
| `superseded` | A later specification replaced the claim; **only the superseding form is carried** |
| `retired-by-retarget` | The composite identifier it resolves to is tombstoned. The number still resolves, the obligation is carried to a future feature, and the retiring decision is named. **Added by the retarget**; it is not `dropped-with-reason`, because nothing is silently gone |
| `dropped-with-reason` | It does not survive as a requirement, and the reason is stated. Used nowhere |

**Verbatim vocabulary** (forward table — what happened to a *composite* identifier)

| Value | Meaning |
|---|---|
| `yes` | The obligation is unchanged in substance and near-unchanged in words, through both passes |
| `adapted` | The merge moved the wording without moving the obligation — a product name generalised to its role, a cross-reference renumbered, a clause absorbed from a sibling contract |
| `merged` | Two or more sources are stated as one |
| `retargeted` | **Added by the retarget.** The source mapping stands; the requirement's text was rewritten for SR Linux. The note says what changed and names the RD decision that changed it. Where the row was also a merge, the note states that the merge is unchanged |
| `retired` | **Added by the retarget.** The identifier keeps its number, its source mapping and a one-line tombstone in [spec.md](./spec.md); the obligation is carried to a future feature |
| `new (retarget)` | **Added by the retarget.** The identifier has no source line — it exists because of a decision (RD-xx) or a gap (GAP-x) the merge recorded but could not close. Source is `—`, and the note names what it came from |
| `revised` | (decisions only) The decision stands and its content changed; the note names the RD decision that revised it |
| `rewritten` / `closed` | (risks only) The risk survives with new content, or is closed by construction and kept so its lesson is not lost |

Every `adapted`, `merged`, `retargeted`, `retired`, `revised` and `new (retarget)` row says what
changed and why.

## Forward — composite id → source

### Functional requirements

| Composite | Source | Verbatim? | Note |
| --- | --- | --- | --- |
| FR-001 | `001:FR-001` | retargeted | RD-01 — SR Linux nodes launched with the `nokia_srlinux` kind; leaves and spines must use licence-free types carrying the full EVPN-VXLAN feature set, and a type without VXLAN is barred from every role |
| FR-002 | `001:FR-002` | retargeted | RD-01, RD-04, RD-10 — six nodes (the two SRv6 endpoints go with FR-003); interface map in the device's own `ethernet-1/N` naming; endpoints multiplex services over VLAN subinterfaces on one link; endpoint interface MTU set to the tenant MTU |
| FR-003 | `001:FR-027` | retired | **Retired by RD-04 — carried to a future feature.** The source mapping is kept so `001:FR-027` still resolves. The dual-stack underlay obligation this requirement also carried is preserved in FR-011 |
| FR-004 | `001:FR-003` | retargeted | RD-12 — the gate's content is replaced by items G1–G13; the SRv6 items are deleted rather than translated, and the result is recorded per construct for FR-097 |
| FR-005 | `001:FR-028` | retired | **Retired by RD-04 — carried to a future feature.** `001:FR-028` still resolves here |
| FR-006 | `001:FR-021` | yes | — |
| FR-007 | `001:FR-023` | retargeted | RD-02 — the host-side exception is deleted; the placement rule is now absolute ("without exception"), and the SR Linux provider is named in the covered set |
| FR-008 | `001:FR-024` | retargeted | RD-01 — the management address space becomes configurable and is checked against every existing Docker network in preflight, because the inherited default collides on the reference host |
| FR-009 | `001:FR-025` | yes | — |
| FR-010 | `001:FR-022` | retargeted | RD-01 — one lab profile; the device-profile flag is deleted from the lifecycle scripts; neither script deletes anything under the lab's evidence root, and the evidence-preservation flag only adds the optional teardown-time capture (`AD-64`) |
| FR-011 | `001:FR-004` | retargeted | RD-04, RD-01 — absorbs the dual-stack underlay clause salvaged from retired FR-003, and states that the VXLAN tunnel endpoint is IPv4-only so no requirement can assume otherwise |
| FR-012 | `001:FR-005` | retargeted | RD-09 — the derived-identifier list is restated in SR Linux terms; route targets are rendered explicitly from the fabric-wide overlay AS, and a device-derived route target must not be relied on |
| FR-013 | `001:FR-006` | retargeted | RD-03 — upstream device-configuration and allocation APIs are reused unchanged; fabric and service intent live in exactly one first-party API group with structural schemas; no per-device intermediate Kind. The ban on a second workflow, pipeline or job engine (`AD-37`) is carried by `make verify-boundaries` (T025) and the runtime inventory of T152 (`AD-49`) |
| FR-014 | `001:FR-007` | retargeted | RD-03 — a single first-party SR Linux provider is the only renderer of any device path, underlay to access list |
| FR-015 | `001:FR-008` | retargeted | RD-02 — made concrete; two configuration resources that could touch the same device leaf may not share a priority, and an overruled platform-owned path is a terminal error |
| FR-016 | `001:FR-009` | yes | — |
| FR-017 | `001:FR-013` + `003:D-08` | retargeted | RD-08, RD-01 — native-first: the register's default inverts and every exception carries a recorded justification; the compatibility set becomes nine parts and the schema deviation patch is pinned by commit. **The merge is unchanged**: `003:D-08`'s path-register clause is still stated inside this requirement |
| FR-018 | `001:FR-014` | yes | — |
| FR-019 | `001:FR-015` | yes | — |
| FR-020 | `001:FR-019` | retargeted | RD-01 — the test list is restated for this platform, and traffic tests must assert reachability, isolation and counter movement and never throughput |
| FR-021 | `001:FR-026` | retired | **Retired by RD-04 — carried to a future feature.** `001:FR-026` still resolves here |
| FR-022 | `001:FR-029` | retired | **Retired by RD-04 — carried to a future feature.** `001:FR-029` still resolves here |
| FR-023 | `001:FR-030` | retired | **Retired by RD-04 — carried to a future feature.** `001:FR-030` still resolves here |
| FR-024 | `003:FR-001` | yes | — |
| FR-025 | `003:FR-002` | yes | — |
| FR-026 | `003:FR-003` | yes | — |
| FR-027 | `003:FR-003a` | yes | **Lettered id folded into the flat sequence.** 003 inserted FR-003a into a settled list; the composite renumbers it as an ordinary requirement |
| FR-028 | `003:FR-004` | yes | — |
| FR-029 | `003:FR-005` | retargeted | RD-06 — "a VLAN and its port membership" becomes "a local bridge domain and its subinterfaces"; it stays its own construct and its own list precisely because the device realizes it with the same instance type as `mac-vrf` |
| FR-030 | `003:FR-006` | retargeted | RD-06 — "a VLAN extended over the fabric" becomes "a bridge domain extended over the fabric", matching the device's own term |
| FR-031 | `003:FR-007` | yes | — |
| FR-032 | `003:FR-008` | yes | The composition rule is unchanged. **AD-50** (fifth pass, 2026-09-21) adds the two MUST NOTs of User Story 8's scenarios 2 and 3 — no unrequested address family; no routed instance and no L3 identifier without a gateway — which only the data model carried. Tasks T115–T118 |
| FR-033 | `003:FR-009` | yes | — |
| FR-034 | `003:FR-010` | retargeted | RD-09 — the derived routed-instance VLAN band is gone; the constraint that replaces it is that the VNI band stays inside the range the device's EVPN instance identifier can carry. **AD-52** (sixth pass, 2026-09-21; operator decision) — the constraints enforced at admission fail closed: with the evaluating component unreachable a create or update is refused, a deletion is never intercepted, and the refusal is a cluster-API dependency failure (NFR-010), not a refusal of the request. **AD-61** (seventh pass, 2026-09-21) — those constraints are evaluated on a create and on an update that changes `spec`; an update that leaves `spec` unchanged (a finalizer, a label, an annotation, the force-release included) or that reaches a deleting object is admitted without re-evaluation, so finalization and the force-release are never refused by the platform's own admission |
| FR-035 | `003:FR-011` | retargeted | RD-05 — a standalone list binds to an attachment another service has already created, is refused by name when none exists, and never creates an interface or subinterface of its own |
| FR-036 | `003:FR-012` | retargeted | RD-05 — "that service's own attachment ports" becomes "that service's own attachment subinterfaces" |
| FR-037 | `003:FR-012a` | retargeted | RD-05 — the binding point is the attachment subinterface, resolved from node + port (+ VLAN) through the site inventory. **Answers open decision 4** |
| FR-038 | `003:FR-013` | retargeted | RD-05 — a Layer 2 (MAC) list is refused as out of scope, because the construct is defined over address families, rather than as something the device lacks |
| FR-039 | `003:FR-014` | retargeted | RD-05 — ascending priority, first match wins, rendered unchanged as the device's entry sequence number; the reserved slot is **the last position in the evaluation order**, not the lowest number (see [platform-coupling.md](./platform-coupling.md) PC-N-05) |
| FR-040 | `003:FR-015` | retargeted | RD-05 — the ICMPv6 refusal is reverted; refusals are added for a device-reserved filter name and for a rule claiming the reserved default-action position |
| FR-041 | `003:FR-016` | retargeted | RD-05 — the device's implicit behaviour for unmatched traffic is accept, so an undeclared default action must be stated to the operator and the list must not be described as restrictive beyond its rules |
| FR-042 | `003:FR-017` | retargeted | RD-05, RD-13 — applied-side read-back keyed by filter name, family and entry; a device-wide count is never evidence; enforcement moves to acceptance (SC-041). The merge's carried defect is closed by construction, not merely recorded |
| FR-043 | `003:FR-018` | retargeted | RD-05, RD-14 — the unit of exclusivity becomes subinterface + direction + address family, the refusal's reason becomes a platform limit, and deletion ordering is added. **Closes GAP-4** |
| FR-044 | `001:FR-010` + `003:FR-019` | merged | 003 reframes 001's translation catalogue as the migration alias table. Stated once, in construct terms, with the retired names shown as the aliases they are (satisfies 003:FR-024's allowed-context rule) |
| FR-045 | `001:FR-011` | adapted | Absorbs the raw-CLI prohibition and the limited-equivalence opt-in from `001:contracts/reconciliation.md` Rule 1 |
| FR-046 | `003:FR-020` | retargeted | RD-14 — one provenance record, the annotations on the service intent object, and no second record of the same fact. **Closes GAP-2** |
| FR-047 | `003:FR-021` | yes | — |
| FR-048 | `001:FR-012` | retargeted | RD-14 — a `MigrationPlan` references the service intent object's provenance rather than restating it, and records the construct alongside the source vocabulary |
| FR-049 | `001:FR-020` | retargeted | RD-07 — the boundary now names the NOS vendor's own fabric-automation product as a proprietary vendor controller, and says the image is the one vendor artefact permitted in the dependency graph. The concrete strings stay in SC-017(a) and platform-coupling.md |
| FR-050 | `002:FR-001` | yes | — |
| FR-051 | `002:FR-002` | yes | — |
| FR-052 | `002:FR-003` | yes | — |
| FR-053 | `002:FR-004` | yes | — |
| FR-054 | `002:FR-005` | yes | **AD-37** (operator review, 2026-09-20) adds the indeterminate status that is never a success; **AD-49** and **AD-40** (fifth pass, 2026-09-21) add the success-rate clause `AD-37` had recorded and the rule that a `Network` reporting `Ready=Unknown` is not a converged service. The closed set itself is unchanged |
| FR-055 | `002:FR-006` | yes | — |
| FR-056 | `002:FR-007` | yes | — |
| FR-057 | `002:FR-008` | yes | **AD-50** (fifth pass, 2026-09-21) names the status of an existing service among the informational questions (FR-069), answered without entering the pipeline and so without a confirmation |
| FR-058 | `002:FR-009` | adapted | "service type" → "the construct", per 003's vocabulary closure; the published schema is now `contracts/interpretation.schema.json` |
| FR-059 | `002:FR-010` | yes | — |
| FR-060 | `002:FR-011` + `003:D-01` + `003:plan gate C1` | retargeted | RD-09, RD-03 — what is emitted changes: derived import/export route targets and attachment VLANs, with the route distinguisher removed. **The merge is unchanged** — `002:FR-011` + `003:D-01` + `003:plan gate C1` are still stated once as the one-translator rule |
| FR-061 | `002:FR-012` | adapted | "service type" → "construct" |
| FR-062 | `002:FR-013` + `003:contracts/kuid-claim-profiles.md` | retargeted | RD-09 — the claim set narrows to VLANs and VNIs, and derived identifiers must be shown in the assignment so the second confirmation covers them. **The merge is unchanged**: 003's claim profiles and "claiming nothing is a success" are still folded in here |
| FR-063 | `002:FR-014` | yes | — |
| FR-064 | `002:FR-015` | yes | — |
| FR-065 | `002:FR-017` | yes | — |
| FR-066 | `002:FR-018` | yes | **AD-50** (fifth pass, 2026-09-21) states the server-side dry-run of every object before anything is applied — the constitution's own word for the step, until then normative only in the submission contract and T092 |
| FR-067 | `002:FR-019` | yes | **AD-40** (fifth pass, 2026-09-21) — `Ready=Unknown` (FR-107) is none of the three outcomes and is never read as Ready; a watch that sees it keeps watching. **AD-63** (seventh pass, 2026-09-21) — a watch that sees `Ready=False/Deleting` has seen a terminal failure, reported as deleted outside the tier (FR-105); a removal's watch is FR-069's (T100, T092) |
| FR-068 | `002:FR-020` | yes | — |
| FR-069 | `002:FR-021` | yes | **AD-50** (fifth pass, 2026-09-21) scopes the confirmation requirement to removal; a status query is informational (FR-057), answered from the live object with no confirmation. **AD-63** (seventh pass, 2026-09-21) — a removal is watched until the object is gone, bounded by the convergence timeout: gone is `COMPLETED`, still present ends the turn at `PROVISIONING` as in progress with what is outstanding named, never a success and never a failure; an accepted delete is never reported as a removal (T100 builds, T092 asserts both endings) |
| FR-070 | `002:FR-022` | yes | — |
| FR-071 | `002:FR-023` | yes | — |
| FR-072 | `002:FR-024` | yes | — |
| FR-073 | `002:FR-025` | yes | — |
| FR-074 | `002:FR-026` | yes | — |
| FR-075 | `002:FR-016` + `002:FR-029` + `003:plan gate C2` | retargeted | RD-01, RD-02 — the denial covers the device management network **on every port**, naming the plaintext management port the lab image also exposes. **The merge is unchanged**: `002:FR-016` and `002:FR-029` still resolve here as one rule with its enforcement |
| FR-076 | `002:FR-027` | yes | — |
| FR-077 | `002:FR-028` | yes | — |
| FR-078 | `002:FR-030` | yes | The obligation to record every decision is unchanged; what the record *is* was stated by later passes — **AD-18** (the trace-borne event in the agent-analytics store), **AD-24** and **AD-36** (exported before anything removes the store; the export's format, bound and failure) and **AD-46** (fifth pass, 2026-09-21: the export read back, the usernames captured, the re-run's skip-or-add rule). Clause by clause in §Obligations index |
| FR-079 | `002:FR-031` | yes | — |
| FR-080 | `002:FR-032` | yes | — |
| FR-081 | `002:FR-033` | yes | — |
| FR-082 | `002:FR-034` | yes | — |
| FR-083 | `003:FR-022` | retargeted | RD-05, RD-06 — the documentation must state what each construct renders in the device's own object names, how rules are ordered, and what happens to unmatched traffic |
| FR-084 | `003:FR-023` | adapted | **Supersession applied.** 003 replaces the four service-provider names `002:contracts/supervisor-http.md:88-91` served from `GET /suggested-prompts`; only the construct form is carried. Also absorbs 003 R-06's site-port-map clause |
| FR-085 | `003:FR-024` | yes | — |
| FR-086 | `001:FR-016` | retargeted | RD-11 — both clients share one device gRPC server whose session limit must be sized explicitly for the two together |
| FR-087 | `001:FR-017` | yes | **AD-50** (fifth pass, 2026-09-21) — the required alert set is enumerated once in data-model §21 and cited by name, so SC-035's "specified alert" is decidable |
| FR-088 | `001:FR-018` | yes | — |
| FR-089 | `001:FR-031` | retargeted | RD-11, RD-04 — the SRv6 policy and MySID paths are deleted, not translated; the registered SR Linux native path set replaces the list, the pipeline is named end to end, and metric name, labels and stream mode are recorded in the register |
| FR-090 | `002:FR-035` | yes | — |
| FR-091 | `002:FR-036` | yes | — |
| FR-092 | `002:FR-037` | yes | — |
| FR-093 | `002:FR-038` | yes | — |
| FR-094 | `001:FR-032` | retargeted | RD-07, RD-11, RD-04 — the SRv6 service-path view becomes the **EVPN** service-path view; the visualization boundary becomes a reference-artifact boundary; the join contract is exactly two registered labels. Carried in [platform-coupling.md](./platform-coupling.md) PC-20 |
| FR-095 | `002:FR-039` | yes | — |
| FR-096 | `001:FR-033` | retargeted | RD-11 — topology assets **and the collector's target list** are generated from one containerlab inventory in one provisioning step, with plugins and generator pinned |
| FR-097 | — | new (retarget) | **GAP-1, RD-14** (gate content RD-12) — the capability gate records qualification per construct and per gated property and publishes it where the tier can read it; an unqualified construct or property is refused at interpretation, by name, before anything is claimed or created |
| FR-098 | — | new (retarget) | **RD-03, RD-15** — no CRD or API service may be installed into an upstream project's API group unless it is that project's own pinned, unmodified artefact, and provisioning must fail rather than fall back to a look-alike. Answers the look-alike-CRD finding in the inherited acceptance record |
| FR-099 | — | new (retarget) | **RD-06** — the `mac-vrf` / `ip-vrf` vocabulary alignment with the device's own network-instance types is asserted in CI against the pinned device model, so the alignment is a requirement rather than a coincidence |
| FR-100 | — | new (retarget) | **GAP-6, RD-13** — two-sided, keyed read-back for **every** construct: written side plus the device's own state for the objects this service created, with the missing invariant named. FR-042 states the same obligation for access lists |
| FR-101 | — | new (retarget) | **GAP-3, RD-14** — one owner per metadata key on the service intent object, fixed emission order, and the provider stamps the device configuration resources rather than the service intent object |
| FR-102 | — | new (clarification 2026-09-20) | Operator authentication on the chat and programmatic surfaces: credentials generated into a Secret at provisioning, the audit principal is the authenticated username, an unauthenticated request is refused before the pipeline. Gives FR-078 and SC-030 a verifiable principal |
| FR-103 | — | new (clarification 2026-09-20) | Deletion while a target is unreachable: finalization blocks with the target named, allocations stay claimed, no timer releases an identifier, and the only other exit is a documented operator force-release leaving a durable finding. Replaces the edge case's unspecified "timeout and manual-recovery policy". An object being deleted reports `Ready=False/Deleting` from the moment finalization starts, in every deletion (operator decision `AD-53`, 2026-09-21) |
| FR-104 | — | new (clarification 2026-09-20) | **RD-03, R-31** — the allocation-authority failure branch: a failed gate item stops provisioning; the first-party substitute is adopted only by recorded operator decision, lives in the first-party API group (never the upstream group, FR-098), and never coexists with the upstream authority. FR-013 names it as its single exception. Measured by **SC-047** (operator review 2026-09-20), which also records the substitution's preconditions and its return path — carried since the fifth pass by `contracts/kuid-claim-profiles.md` §7, `data-model.md` §23, T048's no-bound-claim stop and T009's return-entry fixture, with SC-047's failing-G11 run given a runner in T044 (`AD-49`) |
| FR-105 | — | new (clarification 2026-09-20) | A tier-created service changed outside the tier: submitted-spec hash stamped under a tier-owned key (FR-101), detect and report on every status or removal request, never revert, re-create or overwrite. SC-030 is scoped to tier-originated changes. **AD-58** (sixth pass, 2026-09-21) restates the removal of a modified service as the data model has it: the modification is stated at that request's first confirmation and the removal proceeds only through both (T094). **AD-63** (seventh pass, 2026-09-21) — a deletion seen by an open convergence watch is a detection too (T100, T092) |
| FR-106 | — | new (analysis 2026-09-20) | **AD-01** — the constitution's secrets and LLM-configuration constraint, which had no requirement: the model-provider Secret is generated and merged, never replaced; a declared gateway with no base URL is refused; re-provisioning preserves the stored base URL; the effective endpoint is always stated, redacted of any credential it embeds (FR-079). Carried by CR-008; measured by **SC-048** (operator review 2026-09-20); the running-agent case and the redaction of the provisioning lines given their tasks — T080, T072, T168 — by the fifth pass (`AD-49`) |
| FR-107 | — | new (analysis 2026-09-20) | **AD-02** — constitution Principle I's scheduled re-verification: the two-sided read-back of FR-100 repeated every five minutes by default for the fabric design and every Ready service; a missing invariant sets `Ready=False`; a pass that could not run sets `Ready=Unknown/VerificationFailed`, never `Ready=False` and never a standing `Ready=True` (operator decision `AD-40`, 2026-09-21, replacing the operator review's "leave `Ready` where it stands"); the last-verified time is in status and in a metric. Measured by SC-044; its clauses are enumerated in §Obligations index |
| FR-108 | — | new (analysis 2026-09-20) | **AD-03** — the boundary around verification tooling: the capability gate, fault and drift injection and the walkthrough's read-only proofs may touch a lab device from the operator's host — or, for gate item G7, from a throwaway Pod the gate starts in a labelled scratch namespace and removes (`AD-60`) — only as run-captured, self-removing, outcome-independent checks. FR-007 and FR-015 are not widened; RD-02 stands. Measured by **SC-049** (operator review 2026-09-20), which also fixes the three definitions and the leftover rule — whose naming convention and start-up scan are T043's `tests/lib/leftovers.sh`, called by T051, T064, T167 and T151 (`AD-49`) and by T134's `alerts_fire.sh`, the fault-making suite that list had missed (`AD-57`); the `LabReady` wait is a credential-less port accept, never a device client under `scripts/`, with a planted `gnmic` fixture in T025 (`AD-57`); the scan finds four kinds of leftover — a `vt-scratch-` object, the gate-labelled `Config`, a gate-labelled scratch namespace (G7's pair, T166's Pods) and a declared fault still in place — and T043's fixture plants one of each (`AD-64`); the leftover rule of the requirement itself names the gate's labelled scratch namespace, which until then only T043's scan carried, and the requirement is enumerated clause by clause in §Obligations index (`AD-65`, seventh pass) |
| FR-109 | — | new (analysis 2026-09-20, second pass) | **AD-09** — *operator*. Every VNI on a service intent object is backed by a bound claim before anything is rendered, whichever way the object arrived: the provider adopts the tier's claim by correlation label and value, or claims the stated value itself; the authority arbitrates a collision (`AllocationConflict`); released only by finalization. Gives the tier-less path of FR-012 an owner; measured by SC-045. **AD-52** (sixth pass, 2026-09-21) restates the finalizer-less window for an admission that fails closed: no object is applied while the provider is down, so the window is an object applied with cluster tooling and deleted before the provider's first reconcile |

### Non-functional requirements

| Composite | Source | Verbatim? | Note |
| --- | --- | --- | --- |
| NFR-001 | `001:NFR-001` | yes | — |
| NFR-002 | `001:NFR-002` | yes | — |
| NFR-003 | `001:NFR-003` | retargeted | RD-15 — placeholder and synthetic digests are forbidden and the pin check must resolve every digest against its registry; branch references are forbidden wherever a reference can appear, including inside the device-configuration layer's schema definition. The merge's note that "the deployment does not meet it" describes the predecessor repository, not this one |
| NFR-004 | `001:NFR-004` | retargeted | RD-01 — no hypervisor and no nested virtualization; the documentation must state the instruction-set, kernel and footprint requirements and the containerized dataplane's packet-rate ceiling as a limit acceptance tests must respect |
| NFR-005 | `001:NFR-005` | yes | — |
| NFR-006 | `002:NFR-001` | adapted | Kept as a requirement and restated as a property of the system rather than of the two documents, per the consolidation rule that removability survives the merge |
| NFR-007 | `002:NFR-002` | yes | — |
| NFR-008 | `002:NFR-003` | yes | — |
| NFR-009 | `002:NFR-004` | yes | — |
| NFR-010 | `002:NFR-005` | yes | — |
| NFR-011 | `002:NFR-006` | adapted | "to the same runbook standard as feature 001" → "to one runbook standard across the fabric and the tier", since there is now one document |
| NFR-012 | `002:NFR-007` | yes | **AD-50** (fifth pass, 2026-09-21) — the envelope is the host-resource preflight's threshold extended by the tier's summed requests, and "without displacing" is the fabric's Ready state re-checked after the tier starts; T087, T088, T089 with T052's measured footprint. No figure added |
| NFR-013 | — | new (retarget) | **RD-15** — evidence integrity: every gate and acceptance result is captured by the run that claims it, and a check counts only after it has been shown to fail on a stock fabric. Drawn from the inherited acceptance record, not from a source requirement |
| NFR-014 | — | new (analysis 2026-09-20, second pass) | **AD-14** — constitution Principle IV's structured-log rule, which had no carrier: one JSON object per line from every first-party workload, with resource identity and correlation identifier, redacted. Carried into CR-005; measured by **SC-050** (operator review 2026-09-20) |

### Success criteria

| Composite | Source | Verbatim? | Note |
| --- | --- | --- | --- |
| SC-001 | `001:SC-001` | retargeted | RD-01 — eight nodes becomes six, and all four device targets must reach Ready |
| SC-002 | `001:SC-011` | retargeted | RD-01 — the four targets are SR Linux targets |
| SC-003 | `001:SC-012` | adapted | Product names generalised |
| SC-004 | `001:SC-002` | retargeted | RD-12 — both address families are required, and no run counts as passed on established sessions alone (that is exactly the G8 failure signature) |
| SC-005 | `001:SC-003` | retargeted | RD-10, RD-06 — adds anycast-gateway reachability and the tenant MTU boundary (largest payload passes, one byte more does not), and states that the test asserts reachability and never throughput |
| SC-006 | `001:SC-005` | yes | — |
| SC-007 | `001:SC-006` | yes | **AD-34** (operator review, 2026-09-20) — the restoration is witnessed as gate item G13 observed it to be witnessable: by the recorded deviation where one is durably visible, otherwise by the restored value read back. The outcome measured is unchanged |
| SC-008 | `001:SC-007` | yes | **AD-40** (fifth pass, 2026-09-21) — an object that had reported Ready and whose target can no longer be read reports `Ready=Unknown`, never a standing `Ready=True` and never `Ready=False`. **AD-15** (second pass, 2026-09-20) had already made the two-interval bound read as its 30 s (data-model §25) |
| SC-009 | `001:SC-013` | retired | **Retired by RD-04 — carried to a future feature.** `001:SC-013` still resolves here |
| SC-010 | `001:SC-014` | retired | **Retired by RD-04 — carried to a future feature.** `001:SC-014` still resolves here |
| SC-011 | `003:SC-001` | yes | — |
| SC-012 | `003:SC-002` | yes | — |
| SC-013 | `003:SC-007` | retargeted | RD-06 — the four cited device references are now the SR Linux ones, and the criterion adds that for `mac-vrf` and `ip-vrf` the construct name is the word those references use |
| SC-014 | `003:SC-003` | retargeted | RD-05 — "wherever the platform exposes one" is dropped, because this platform exposes a programmed-state view unconditionally; the read-back is keyed by filter and the rules must read back in the declared order |
| SC-015 | `003:SC-004` | yes | — |
| SC-016 | `001:SC-004` | yes | — |
| SC-017 | `001:SC-010` | retargeted | RD-07 — boundary (b) is re-scoped from a visualization boundary to a **reference-artifact** boundary; (a) and (c) are unchanged. The three boundaries and their allowed contexts are otherwise carried intact |
| SC-018 | `003:SC-006` | adapted | Absorbs the byte-identical `spec:` clause 003's quickstart and R-03 attach to it |
| SC-019 | `002:SC-001` | adapted | "a supported L2 service and a supported L3 service" → the construct form |
| SC-020 | `002:SC-002` | yes | — |
| SC-021 | `002:SC-007` | adapted | "for every supported service type" → "for every supported construct" |
| SC-022 | `002:SC-015` | yes | — |
| SC-023 | `002:SC-008` | yes | — |
| SC-024 | `002:SC-012` | yes | — |
| SC-025 | `002:SC-013` | adapted | "feature-001 acceptance gates" → "control-plane acceptance gates". The dispute against its acceptance record is carried in spec.md §Inherited acceptance record |
| SC-026 | `002:SC-014` | yes | — |
| SC-027 | `002:SC-003` | yes | The dispute against its acceptance record — an inverted check asserting a ceiling where this criterion demands 100% — is carried in spec.md §Inherited acceptance record |
| SC-028 | `002:SC-004` | yes | The dispute against its acceptance record — a hard-coded `0.00%` cell — is carried in spec.md §Inherited acceptance record |
| SC-029 | `002:SC-005` | yes | — |
| SC-030 | `002:SC-006` | yes | — |
| SC-031 | `002:SC-016` | adapted | Corpus references renumbered to SC-020 and SC-028 |
| SC-032 | `002:SC-011` | yes | — |
| SC-033 | `003:SC-005` | yes | — |
| SC-034 | `001:SC-008` | retargeted | RD-04, RD-11 — the SRv6 controller target is removed with the SRv6 scope; the device metric collector's own health endpoint is added, without which the pipeline stages have no evidence |
| SC-035 | `001:SC-009` | yes | **AD-50** (fifth pass, 2026-09-21) — "their specified alert" is the one data-model §21 names for each fault (FR-087), and the method is stated: each fault injected in turn, the named alert observed to fire and then clear |
| SC-036 | `001:SC-015` | retargeted | RD-11, RD-04 — the SRv6 service-path view becomes the EVPN service-path view; the exact-match requirement is unchanged |
| SC-037 | `001:SC-016` | adapted | Product names generalised |
| SC-038 | `002:SC-009` | yes | — |
| SC-039 | `002:SC-010` | yes | — |
| SC-040 | — | new (retarget) | **RD-15** — measures NFR-013 and FR-004: run-captured evidence for every gate item and a recorded negative control for every readiness check |
| SC-041 | — | new (retarget) | **RD-05** — the access-list enforcement probe: a denied probe drops, a permitted probe passes, and the per-entry counters of exactly those entries move |
| SC-042 | — | new (clarification 2026-09-20) | Measures FR-102 — unauthenticated requests refused with zero threads, model calls and claims; every audit principal matches a generated operator credential |
| SC-043 | — | new (clarification 2026-09-20) | Measures FR-103 — allocations held for the length of the outage, removal completes unaided when the leaf returns, a force-release with a stated reason leaves a durable finding, **one with an empty reason releases zero identifiers**, and the finding clears only after a clean read-back (T055, T149) |
| SC-044 | — | new (analysis 2026-09-20) | Measures FR-107 — a Ready service that loses an applied-side invariant with no change of intent reports `Ready=False` naming it within one re-verification interval plus one reconciliation interval, and recovers within the same bound; with the leaf cut from the management network instead it reports `Ready=Unknown/VerificationFailed`, never False and never a standing True (`AD-40`; T167) — the "never" polls running from the first `Unknown`, which SC-008 bounds, until reconnection (`AD-62`) |
| SC-045 | — | new (analysis 2026-09-20, second pass) | Measures FR-109 — with no intent tier present, every VNI of an applied service intent object has a bound, labelled claim before its first device configuration resource; a held VNI is refused naming the holder with zero configuration resources; zero claims remain after deletion |
| SC-046 | — | new (analysis 2026-09-20, third pass) | Measures the adoption half of FR-109 — a tier-provisioned service whose VLAN was allocated records its VLAN and VNI claims as adopted while it exists and leaves none after removal, through the tier or with cluster tooling (AD-16). **Extended by AD-32**: a service from which an attachment carrying its allocated VLAN is removed still lists its VLAN claim as adopted until finalization, and every selector is over `metadata.labels`. **Restated by AD-51**: that clause is measured on a `mac-vrf` — no VLAN is ever allocated for an `ip-vrf`, whose clause is now that one requested with an attachment naming no VLAN shows zero VLAN claims |
| SC-047 | — | new (operator review 2026-09-20) | Measures FR-104 — exactly one allocation authority is installed in every run, and a failed allocation capability-gate item stops provisioning non-zero naming that item with nothing installed above the authority (T044, T050) |
| SC-048 | — | new (operator review 2026-09-20) | Measures FR-106 — the model-provider Secret survives re-provisioning byte-identically, only a named input clears the base URL, a declared gateway without one creates zero tier workloads, and every line naming the endpoint is credential-free (T168) |
| SC-049 | — | new (operator review 2026-09-20) | Measures FR-108 — no device client is invoked outside the gate, the test suites and the walkthrough tooling, asserted repository-wide with a failing fixture, and every gate run reads back the removal of its own scratch configuration (T025, T043) |
| SC-050 | — | new (operator review 2026-09-20) | Measures NFR-014 — every first-party log line parses as one JSON object carrying the data-model §27 fields, every line of a request carries its correlation identifier, and none carries a credential (T147) |

### Constitution-mandated requirements

These carry no source-specification identifier: they are derived from
`.specify/memory/constitution.md` v1.1.0 and restate composite requirements against a principle, so
their "source" is the principle and their content is the requirements they name. They are listed
here so that no composite identifier is absent from this table.

| Composite | Source | Verbatim? | Note |
| --- | --- | --- | --- |
| CR-001 | Constitution Principle I | retargeted | RD-13, RD-15 — the carried-by list is repaired: retired FR-023 is removed, FR-100 and NFR-013 are added |
| CR-002 | Constitution Principle II | yes | The two-confirmation rule is unchanged. **AD-50** (fifth pass, 2026-09-21) adds the principle's other tier clause, which no row carried — never present or provision a service type the operator did not ask for — with its carriers FR-024, FR-029, FR-032, FR-059, FR-062 |
| CR-003 | Constitution Principle II | retargeted | RD-14 — FR-097 added to the carried-by list, since an unqualified construct is now also refused up front. **AD-50** (fifth pass, 2026-09-21) names the carrier of the enumeration itself — FR-034's site-inventory validation, with T056, T091 and T098. **AD-52** (sixth pass, 2026-09-21) makes "at admission alike" hold at all times: the webhook that enumerates the valid names fails closed (T056, T061) |
| CR-004 | Constitution Principle III | yes | The sequence is unchanged. What "dry-run" means is made concrete by RD-02; **AD-50** (fifth pass, 2026-09-21) restores the constitution's own "server-side dry-run" to the row and makes it a MUST of FR-066; **AD-65** (seventh pass, 2026-09-21) adds FR-015 — the device transaction's rollback on rejection — and FR-045 — the translation that leaves nothing behind — to CR-004's carriers, which the plan's Principle III row already cited |
| CR-005 | Constitution Principle IV | yes | — |
| CR-006 | Constitution Principle V | retargeted | RD-15 — FR-017 and FR-098 added to the carried-by list |
| CR-007 | Constitution Principle VI | new (retarget) | **RD-12, RD-15** — a gate MUST NOT be waived to make a run pass; a capability that cannot hold is documented and the affected service reports `Ready=False` or is refused by name |
| CR-008 | Constitution §Additional Constraints — Secrets and LLM configuration | new (analysis 2026-09-20) | **AD-01** — credentials never committed; a declared gateway needs a base URL; re-provisioning preserves it. Carried by FR-019, FR-079, FR-102, FR-106 |
| CR-009 | Constitution v1.1.0 §Additional Constraints — Network policy | new (analysis 2026-09-21, fifth pass) | **AD-50** — fabric port MTU 9412, underlay IP MTU 9398, tenant IP MTU 9348 on endpoint interfaces, acceptance probes 9320 (IPv4) / 9300 (IPv6) with one byte more failing, no throughput assertion; re-observed by gate item G6 before any test relies on them. Carried by FR-002, FR-004, FR-020, SC-005; tasks T032, T043, T065 |
| CR-010 | Constitution v1.1.0 §Additional Constraints — Known limitation | new (analysis 2026-09-21, fifth pass) | **AD-50** — an IPv6 anycast gateway and IPv6 Type-5 origination are a capability-gate item; where the gate or a service's read-back shows the IPv6 Type-5 route missing the service reports `Ready=False` naming the route. Carried by FR-004, FR-097, FR-100; tasks T046, T116, T117. **AD-58** (sixth pass, 2026-09-21) names its testers: T115's read-back case with the IPv6 Type-5 route absent (`Ready=False/RoutesMissing` naming it) and its `refuse_gateway_ipv6_unqualified` fixture, made to pass by T116 and T117 |

### User stories

| Composite | Source | Verbatim? | Note |
| --- | --- | --- | --- |
| US1 — Launch and verify a reproducible lab (P1) | `001:US3` | yes | — |
| US2 — Reconcile the fabric declaratively (P1) | `001:US2` | yes | — |
| US3 — *Retired: end-to-end SRv6 service* | `001:US5` | retired | **Retired by RD-04 — carried to a future feature.** `001:US5` still resolves here. No licence-free SR Linux container type can originate or terminate an SRv6 service, so the story's capture-proven ordered-SID acceptance is unsatisfiable on any pinnable profile |
| US4 — Ask for a construct by its datacenter name (P1) | `003:US1` + `002:US1` | merged | **The same journey in the composite.** 002:US1 is "provision a service by describing it"; 003:US1 is "ask for a construct by its datacenter name". Once the vocabulary is closed at four constructs they are one story, so their nine acceptance scenarios are merged with no scenario dropped |
| US5 — Filter a service with an access list (P1) | `003:US2` | adapted | Gains the cross-service binding-conflict scenario from 003's Edge Cases, which US2 implied but did not list |
| US6 — Refuse to bypass the declarative control plane (P1) | `002:US2` | yes | — |
| US7 — Run the intent tier beside the control plane (P1) | `002:US3` | yes | — |
| US8 — Get a gateway without asking for a different service (P2) | `003:US3` | yes | — |
| US9 — Brownfield intents keep being accepted (P2) | `003:US4` + `001:US1` | merged | **001:US1 becomes the brownfield story.** 001:US1 is "translate supported MPLS VPN intent" — under 003's vocabulary that path is exactly the migration-alias path 003:US4 describes. Merged; 001:US1's unsupported-feature rejection scenario is carried as scenario 5 so nothing is lost |
| US10 — Converse through an operator chat surface (P2) | `002:US4` | yes | — |
| US11 — Observe control and data-plane health (P2) | `001:US4` | adapted | Product names generalised |
| US12 — Observe and explain what the agents did (P2) | `002:US5` | yes | — |
| US13 — One vocabulary everywhere (P3) | `003:US5` | yes | — |

### Research decisions

| Composite | Source | Verbatim? | Note |
| --- | --- | --- | --- |
| D-01 | `001:D-06` | revised | Two-tier containerlab qualification. **Revised by RD-01**: there is one container profile and no VM tier, so the two-tier structure is gone and what survives is the obligation to qualify the pinned profile before use |
| D-02 | `001:D-09` | revised | Kind as the single application runtime. **Revised by RD-02**: the carried tension with the host-side executor is not resolved by argument — the executor is deleted, so FR-007 has no exception left to carry |
| D-03 | `002:D-15` | yes | Polyglot build and CI |
| D-04 | `001:D-01` | revised | Reuse the upstream fabric and allocation APIs. **Revised by RD-03**: the allocation and device-configuration APIs are reused unchanged from their own pinned artefacts; the upstream *fabric* API is reference design only. The tutorial-versus-main-branch version skew this decision named is confirmed by `evidence/05-kubenet-sdc-kuid.md` §0 |
| D-05 | `001:D-02` | revised | The device-configuration layer as the only transaction layer; its rejection of an agent device session is the origin of the safety boundary. **Revised by RD-02**, and corrected: the predecessor never ran that layer at all (`evidence/05-kubenet-sdc-kuid.md` §0), so this is the first implementation rather than a restoration |
| D-06 | `001:D-03` | revised | A narrow device provider. **Revised by RD-03**: the "material integration gap" this decision recorded inverts and then re-opens — upstream does ship an SR Linux provider, but a dormant one that cannot express the four constructs. The answer is a first-party provider, not a gap controller |
| D-07 | `001:D-10` | yes | Direct reconciliation first; review workflows later |
| D-08 | `001:D-07` | retired | **Retired by RD-04.** Capability-gated SRv6 VPN service. `001:D-07` still resolves here; the decision and everything numbered from it are carried to a future feature. See [spec.md](./spec.md) §Deferred scope |
| D-09 | `003:D-08` | revised | Register coverage, not a second render path. **Revised by RD-08**: the register survives and its default inverts to native-first, with a recorded justification required for every OpenConfig exception (none today) |
| D-10 | `003:D-01` | yes | The construct set closed at four; legacy names are input aliases |
| D-11 | `003:D-03` | revised | A local `vlan` is its own list. **Revised by RD-06**: the reasoning strengthens rather than weakens — on this platform a `vlan` and a `mac-vrf` render to the same device instance type, so keeping them as separate lists is what stops "local" being encoded as "the overlay fields are missing" |
| D-12 | `003:D-02` | retired | **Retired by RD-02.** Access-list rows are raw-store writes, never whole-config. `003:D-02` still resolves here. The decision is an argument about a configuration store that does not exist on this platform, and the hazard that motivated it (PC-12) has no analogue |
| D-13 | `003:D-05` | revised | One access-list table per service, derived device name. **Revised by RD-05**: the determinism property is kept; the derivation rationale (a 2–64 character device name rule) is replaced by a sanitiser and a reserved-name refusal |
| D-14 | `003:D-06` | revised | Pre-flight refusal plus a non-destructive renderer; GAP-4 attached. **Revised by RD-05**: both mechanisms are kept, the unit of exclusivity becomes the subinterface, and the rationale becomes a stated platform limit rather than an absence of defined ordering |
| D-15 | `003:D-10` | revised | The match set is the pinned image's, and the two corrections. **Revised by RD-05**: the discipline is kept and the whole match table is replaced; correction #2 (the ICMPv6 refusal) is **reverted** for this platform, correction #1 (no MAC list) is kept with a new reason — scope, not capability |
| D-16 | `003:D-04` | revised | Two-sided verification. **Revised by RD-05 and RD-13**: the mechanism is replaced by keyed reads of the device's running and state datastores, and the carried defect is closed **by construction** rather than merely recorded, then generalised to every construct by FR-100 |
| D-17 | `001:D-05` | adapted | Translate services, not device CLI. The mapping table is re-expressed in construct terms with the retired names labelled as migration aliases |
| D-18 | `001:D-04` | adapted | Optional migration-audit CRD; GAP-2 is attached |
| D-19 | `003:D-09` | yes | Source-scoped constraints stay scoped |
| D-20 | `002:D-01` | revised | The pinned tier stack. **Revised by RD-15**: the digest-pinning clause the predecessor did not meet is now enforced by a pin check that resolves every digest against its registry (NFR-003) |
| D-21 | `002:D-05` | yes | A durable checkpointer on a volume |
| D-22 | `002:D-11` | revised | **Supersession applied** (see below). **Revised by RD-09**: the served claim groups are unchanged; the claim *set* narrows to VLAN and VNI indices, and the route-target index is removed |
| D-23 | `002:D-14` | yes | Correct or drop the defects the fidelity analysis found |
| D-24 | `002:D-16` | yes | Workflow status vocabulary |
| D-25 | `003:D-07` | revised | Claim profiles per construct, not new indices. **Revised by RD-09**: `evi`, the route targets, the route distinguisher, the subinterface, tunnel and IRB indices and the instance names are all **derived**, never claimed |
| D-26 | `003:D-11` | yes | **Supersession applied.** One construct per request and a one-endpoint minimum; `002:contracts/normalized-service-intent.schema.json:36` `endpoints.minItems: 2` is replaced |
| D-27 | `002:D-02` | yes | The transport port and variable name are the code's |
| D-28 | `002:D-06` | yes | Mutual TLS on the transport gateway |
| D-29 | `002:D-07` | yes | Markers kept, structured data authoritative |
| D-30 | `002:D-04` | yes | The loopback translator sidecar |
| D-31 | `002:D-09` | adapted | Correlation identifier as a label; GAP-3 is attached |
| D-32 | `002:D-10` | yes | Dry-run then apply, label-selector rollback |
| D-33 | `002:D-12` | yes | The tier submits into its own namespace |
| D-34 | `002:D-03` | yes | Newline-delimited JSON stream, not a WebSocket |
| D-35 | `002:D-13` | yes | The chat surface is the existing browser app |
| D-36 | `001:D-08` | revised | Device collector → pipeline → metrics store. **Revised by RD-07 and RD-11**: the visualization boundary this row flagged as inverting is re-scoped to a reference-artifact boundary, and the exposition gains a named generator and a two-label join contract |
| D-37 | `002:D-08` | revised | One emission, fanned out by a tier-owned collector. **Revised by RD-11** only in its filter list, which must admit the SR Linux native metric prefixes as well as the agent prefix |
| RD-01 | — | new (retarget) | Platform, pin and topology: SR Linux 25.7.1 pinned by digest, containerlab `nokia_srlinux` with licence-free leaf/spine types, one lab profile, six nodes, device-native interface naming, the management network and its ports |
| RD-02 | — | new (retarget) | Southbound. **Answers open decision 1**: provider → device-configuration resource → gNMI → device, with no executor and no escape hatch. Retires D-12 and R-25 |
| RD-03 | — | new (retarget) | Control-plane ownership. **Answers open decision 2** (operator): a first-party fabric API and a single first-party provider; the device-configuration layer and the allocation authority reused unchanged from their own pinned artefacts; the upstream fabric control plane as reference design only. Revises D-04, D-05, D-06 |
| RD-04 | — | new (retarget) | SRv6. **Answers open decision 3** (operator): deferred to a future feature. Retires US3, FR-003, FR-005, FR-021, FR-022, FR-023, SC-009, SC-010, D-08, R-04 and platform-coupling rows PC-04 and PC-05 |
| RD-05 | — | new (retarget) | Access lists. **Answers open decision 4**: subinterface binding; exclusivity by subinterface, direction and address family; identity sequence-id with ascending, first-match-wins evaluation; the implicit accept made explicit; keyed two-sided verification. Revises D-13, D-14, D-15, D-16 |
| RD-06 | — | new (retarget) | Construct vocabulary. **Answers open decision 5**: the `mac-vrf` / `ip-vrf` alignment becomes a requirement (FR-099) and `vlan` stays its own construct and its own list. Revises D-11 |
| RD-07 | — | new (retarget) | The deny-list's second boundary. **Answers open decision 6**: re-scoped from an operating-system boundary to a reference-artifact boundary. Revises D-36 |
| RD-08 | — | new (retarget) | Path register: native-first, register retained and CI-guarded, every OpenConfig exception justified. Revises D-09 |
| RD-09 | — | new (retarget) | Identifier derivation and claim profiles: what is claimed, what is derived, the removal of the route-target index, and the VNI-inside-EVI-range constraint that replaces the routed-VLAN band. Revises D-22, D-25 |
| RD-10 | — | new (retarget) | The MTU envelope, and the constitution amendment that carries it |
| RD-11 | — | new (retarget) | Telemetry and visualization: the pipeline, the registered native path set, the topology generator and the two-label join contract. Revises D-36, D-37 |
| RD-12 | — | new (retarget) | The capability gate rewritten as items G1–G13, including the IPv6 anycast-gateway / RT5 item, the identityref serialization item and, by AD-34, the deviation-observability item |
| RD-13 | — | new (retarget) | Two-sided, keyed read-back for every construct. Carried by FR-100; **closes GAP-6** |
| RD-14 | — | new (retarget) | The gap closures: GAP-1 → FR-097, GAP-2 → FR-046/FR-048, GAP-3 → FR-101, GAP-4 → FR-043, GAP-5 → closed by RD-04, GAP-6 → FR-100 |
| RD-15 | — | new (retarget) | Preventive requirements drawn from the inherited acceptance record: NFR-013 evidence integrity, NFR-003 strengthened, and the greenfield re-evaluation of the constitution check. Revises D-20 |
| CD-01 | — | new (plan refresh 2026-09-20) | Operator authentication: HTTP Basic verified by the supervisor against the generated `operator-credentials` Secret; the caller-asserted `principal` field is removed. Carries FR-102, SC-042 |
| CD-02 | — | new (plan refresh 2026-09-20) | Deletion blocks on an unreachable target with no timer; annotated, admission-guarded force-release; durable `Fabric.status.findings[]`. Carries FR-103, SC-043. **Withdraws** the deletion timeout of `contracts/reconciliation.md` Rule 8 and `data-model.md` §19 |
| CD-03 | — | new (plan refresh 2026-09-20) | A failed G11 stops provisioning; the first-party substitute is selected only through the lock file under a recorded decision, lives in the first-party group and never coexists. Carries FR-104; revises R-31. **Withdraws** the run-time lease fallback of `contracts/kuid-claim-profiles.md` §4 |
| CD-04 | — | new (plan refresh 2026-09-20) | The submitted-spec hash taken from the server-side dry-run result, stamped once; detect and report, never revert. Carries FR-105 and the rescoped SC-030 |
| CD-05 | — | new (plan refresh 2026-09-20) | Access-list priority direction confirmed as already designed (FR-039, RD-05); no change |
| CD-06 | — | new (operator instruction 2026-09-20) | The last deliverable: the repository `README.md` modelled section for section on the predecessor's `/root/agentic-netops/README.md`, with the predecessor's 6× walkthrough re-recorded on SR Linux. Component C-22, phase P12, `contracts/readme-and-walkthrough.md`. Discharges the constitution's pending README sync item |
| AD-01 | — | new (analysis 2026-09-20) | The model-provider Secret is merged, never replaced; a declared gateway needs a base URL. Carries FR-106, CR-008 |
| AD-02 | — | new (analysis 2026-09-20) | Scheduled re-verification is a requeue of the same read-back, five minutes by default. Carries FR-107, SC-044; extends RD-13 |
| AD-03 | — | new (analysis 2026-09-20) | FR-007 governs the platform without exception; verification tooling is bounded by FR-108. **Does not revise RD-02** |
| AD-04 | — | new (analysis 2026-09-20) | The tier's two verb sets stated exactly in FR-075, matching the identity contract. Extends D-33 |
| AD-05 | — | new (analysis 2026-09-20) | A first-party image is pinned by its build inputs and identified per run in evidence. Extends NFR-003; adds R-43 |
| AD-06 | — | new (analysis 2026-09-20) | `Fabric.spec.maintenance[]` defined as the declarative administrative-state knob the quickstart already used |
| AD-07 | — | new (analysis 2026-09-20) | One table of default bounds (`data-model.md` §25): Rule 7's control-plane values, the predecessor tier's intent-tier values (D-20) |
| AD-08 | — | new (analysis 2026-09-20) | Execution order P0, P2, P3, then P1 inside the tier phase; phase numbers unchanged; the no-agent-before-denials invariant enforced by the provisioning script |
| AD-09 | — | new (analysis 2026-09-20, second pass) | *Operator.* The provider adopts or makes the VNI claims of a `Network` that arrives without the tier; the authority arbitrates. Carries FR-109, SC-045; widens gate item G11. **Amended by AD-42**: a tier VNI claim is adopted on label, deterministic name and value |
| AD-10 | — | new (analysis 2026-09-20, second pass) | Two ranges, two names: the device range `1..65535` (CEL) and the allocation band (translator, authority). Clarifies FR-034; no requirement changed |
| AD-11 | — | new (analysis 2026-09-20, second pass) | *Operator.* One first-party group for fabric, service intent and allocation kinds; the optional `MigrationPlan` group is the only other. FR-013 and FR-104 reworded; nothing moved |
| AD-12 | — | new (analysis 2026-09-20, second pass) | Exactly one pin exception is admitted — FR-104's recorded substitution; the lock file has no field for another. Extends NFR-003, CR-006 |
| AD-13 | — | new (analysis 2026-09-20, second pass) | The drift policy has no default: `DRIFT_POLICY` is required and stated on every `Config`, in its `revertive` field. Extends FR-015; rationale corrected by AD-34 |
| AD-14 | — | new (analysis 2026-09-20, second pass) | First-party workloads log one JSON object per line. Carries NFR-014 |
| AD-15 | — | new (analysis 2026-09-20, second pass) | Closures with no design decision: the admission-probe timing in the plan, telemetry cardinality and stale series, the deliberately untasked substitute controller, the `intent-translator` build, SC-008's wording, table and heading formatting |
| AD-16 | — | new (analysis 2026-09-20, third pass) | *Choice.* The provider adopts and releases the tier's VLAN claims by the label-and-value rule of AD-09 and never creates one; the tier releases only provisional claims. Widens FR-109, extends FR-062; carries SC-046, R-45. **Amended by AD-32**, and by **AD-42**, which makes the rule three-part for VNI and VLAN claims alike |
| AD-17 | — | new (analysis 2026-09-20, third pass) | *Choice.* The drift-policy set is closed with one member, `revertive`; the device-configuration layer's non-revertive mode is not an admissible value here. Extends FR-015; amends AD-13. **Rationale corrected by AD-34** — non-revertive holds the deviation for an operator to accept *or revert*, so the second policy is out of scope, not unconstitutional |
| AD-18 | — | new (analysis 2026-09-20, third pass) | The audit record is the trace-borne event in the agent-analytics store; only the deployer mirrors the events it decides as Kubernetes Events. Extends FR-078 |
| AD-19 | — | new (analysis 2026-09-20, third pass) | SC-028's "zero device sessions" is counted per source inside the cluster nodes, with a positive control. Open item 16 |
| AD-20 | — | new (analysis 2026-09-20, third pass) | One tagging mode per port gets a carrier: FR-034, a CEL rule, a webhook rule, the deployer pre-flight. Open item 17 |
| AD-21 | — | new (analysis 2026-09-20, third pass) | Host-side test and recording tooling is pinned in the lock file (`data-model.md` §28). Extends NFR-003 |
| AD-22 | — | new (analysis 2026-09-20, third pass) | Closures with no design decision: one closed condition set, the untagged-binding fixtures, the merged *Network* entity, wording, task ownership of `ClaimValue` and `logging.go`, ten identifiers added to the plan's inventory |
| AD-23 | — | new (analysis 2026-09-20, fourth pass) | *Choice.* `Fabric` readiness reads its own sessions, the EVPN family and `inter-as-vpn` on the reflecting spines, never an EVPN route count; route exchange is each spanning service's invariant, and SC-004 takes two observations. Rewords User Story 1, FR-100, SC-004; carries R-46 |
| AD-24 | — | new (analysis 2026-09-20, fourth pass) | The audit record is exported unconditionally before anything removes its store; a failed export stops the removal; `--discard-audit-record` is the only way past and is recorded. Extends FR-078; carries T174 |
| AD-25 | — | new (analysis 2026-09-20, fourth pass) | Allocated identifiers — VNIs and the service VLAN — are immutable once a `Network` is accepted, by CEL transition rules. Extends FR-109 |
| AD-26 | — | new (analysis 2026-09-20, fourth pass) | *Choice.* Removing the tier removes the services it submitted — listed first, bounded wait, never force-released; hand-applied `Network`s live in the control-plane-owned `agentic-netops-services`. Extends NFR-006; carries R-47, T174 |
| AD-27 | — | new (analysis 2026-09-20, fourth pass) | *Choice.* An allocated VLAN already attached by name on the requested port is refused by name at the pre-flight; no other value is tried. Extends FR-062. **Superseded by AD-33**, which makes the collision impossible |
| AD-28 | — | new (analysis 2026-09-20, fourth pass) | Every offline suite has a make target and a CI job (`test-envtest`, `test-agents`, `test-ui` beside `test-static`); the four observability targets of quickstart §21 are in the Makefile. Extends FR-020 |
| AD-29 | — | new (analysis 2026-09-20, fourth pass) | The optional `MigrationPlan` loses `preserveRouteTargets`, is generated outside the default kustomization, and its controller — in the provider binary, registered only when the CRD is served — never creates a `Network`. Extends FR-048 |
| AD-30 | — | new (analysis 2026-09-20, fourth pass) | Closures with no design decision: FR-102's password-versus-username wording, FR-107's bound, FR-078's six event kinds and the unauthenticated refusal, the `grafana-admin` Secret, the measured footprint, the gate's place after the installs it needs, `clarify-delta.md` named, the plan's SC-044 wording |
| AD-31 | — | new (operator decision 2026-09-20) | *Operator decision.* `AD-23` ratified with amendments, no canary: the reflecting spines' `inter-as-vpn` and `route-reflector client` read-back is stated as a configuration-integrity check everywhere it appears; the `Fabric`'s applied side gains the EVPN family's own per-neighbour `oper-state` and the allocated loopbacks active in each node's route table; T051 gains a post-render reflection probe under FR-108 that reports and never gates; `FabricReady` alone is never SC-004 evidence; `EvpnRoutesLost` is guarded against a service-less fabric. Rewords User Story 1 scenario 2, FR-100, SC-004; amends G4, G7, G8, G12, R-46, T041, T043, T051, T052, T130. Report: `review/2026-09-20/AD-23-fabric-readiness.md` |
| AD-32 | — | new (operator decision 2026-09-20) | *Operator decision.* `AD-16` ratified with amendments: adoption is decided **once per value** and survives the object ceasing to carry it; the predicate reads `spec.vlans[].vlan`, `spec.bridgeDomains[].vlan` and `spec.attachments[].vlan` and an added attachment may not carry an allocation-band VLAN; a tier-submitted `Network` carries the provider's finalizer **from apply**; the **deployer**, never the allocator, decides which correlation identifiers are still provisional, so FR-075 is not widened; every claim label lives in `metadata.labels` and an adoptable VLAN claim bears a deterministic name, which closes CHK033 and strengthens R-45. Rewords FR-109, FR-062, FR-075, SC-045, SC-046; amends `kuid-claim-profiles.md` §3/§5/§6/§8, `reconciliation.md` Rule 3/Rule 8, `kubernetes-objects.md`, `crd-api.md`, `data-model.md` §11/§12/§20, plan C-14/C-21/P0/P7/R-44/R-45, quickstart §26/§26a, T017, T019, T044, T055, T060, T069, T089, T092, T093, T100, T112, T141, T170, T171, T173. Report: `review/2026-09-20/AD-16-AD-27-claims.md`. **Amended by AD-42** (the name is part of the rule for VNI claims too), **AD-44** (finalization adopts before it releases) and **AD-51** (the predicate reads two fields, `spec.vlans[].vlan` and `spec.bridgeDomains[].vlan` — `spec.attachments[].vlan` is never matched on its own, no VLAN being allocated for an `ip-vrf`; note added by AD-61) |
| AD-33 | — | new (operator decision 2026-09-20) | *Operator decision.* `AD-27` superseded: named and allocated VLANs get **disjoint bands** — an operator names only from `100–999`, the VLAN index allocates only from `1000–4000` — so the collision AD-27 refused is structurally impossible and its refusal path is withdrawn. The rule is stated **by value**, because a `Network` cannot say which kind its VLAN is; the structural CEL rule stays `100..4000` and never tries to tell them apart. "Named VLANs are never claimed" stands; the one-owner rule stays for two **named** VLANs on one (node, port). R-28 rewritten as a *chosen* partition, not a derived band. Rewords FR-062, FR-109; amends `kuid-claim-profiles.md` §1/§2/§4, `crd-api.md`, `reconciliation.md` Rule 3, `kubernetes-objects.md`, `readme-and-walkthrough.md` §3.1, `data-model.md`, `platform-coupling.md` PC-15, plan C-14/C-21/P0/P7/R-28/R-44, quickstart §26/§26a and the diagnosis table, T014, T017, T038, T044, T062, T091, T092, T093, T112, T141, T170, T171, T173. Report: `review/2026-09-20/AD-16-AD-27-claims.md`. **Amended by AD-41** (the mapper, not the translator, enforces the naming band on the tier path) and **AD-47** (the `acl` reference; the added-attachment rule scoped) |
| AD-34 | — | new (operator decision 2026-09-20) | *Operator decision.* `AD-17` ratified with amendments: the mechanism stands — `DRIFT_POLICY` required, no default, closed set of one, `revertive`, landing on the `revertive` field of every generated `Config` — and its rationale is corrected everywhere. The layer's non-revertive mode records a deviation the operator may accept *or revert*, and the revert is repair, so a second policy is **out of scope, not forbidden**; every "needs a constitution amendment" claim on the drift policy is withdrawn. T036 loses its drift-policy clause (none of the four onboarding CRs has a revertive field), so the policy is stated in one place only. Adds gate item **G13** — what a revertive-mode deviation leaves observable — which decides what SC-007's drift check may assert. Rewords FR-015, FR-004, SC-007, User Story 2; amends `reconciliation.md` Rule 6, `crd-api.md`, `data-model.md` §25, T036, T042, T043, T064, T141. Report: `review/2026-09-20/AD-17-drift-policy.md` |
| AD-35 | — | new (operator decision 2026-09-20) | *Operator decision.* `AD-26` ratified with amendments: the machinery stands — list first, audit export first, bounded `TIER_PURGE_WAIT_SECONDS` script wait, non-zero stop naming the blocked `Network` and its target, never a force-release, `agentic-netops-services` for hand-applied `Network`s — and the **default is reversed**. `off.sh --purge-intent-tier` refuses non-zero, deleting nothing, while tier-submitted services exist; `--remove-services` deletes them and first scales `supervisor`, `ui` and `deployer` down, deleting the namespace only once a re-list is empty and removing the `deny-tier-force-release` policy with the identities it names; a full teardown needs no flag and still exports the audit record. Rewords NFR-006, User Story 7 scenario 4, FR-010, the intent-tier edge cases; amends `data-model.md` §2/§25, `kubernetes-objects.md`, quickstart §19/§24/§27/§27a, plan C-18/P11/R-47, T064, T088, T112, T141, T152, T167, T174. Report: `review/2026-09-20/AD-26-AD-24-tier-removal.md` |
| AD-36 | — | new (operator decision 2026-09-20) | *Operator decision.* `AD-24` ratified with amendments: the export is compressed newline-delimited JSON written through the evidence capture under `EVIDENCE_DIR` with the NFR-013 fields and an identifier unique to the attempt (so a re-run cannot rewrite an artefact SC-040 has hashed); it fails on an unqueryable store, a query error, an unwritable artefact or a short row count, skips an absent store and succeeds on an empty one, and is bounded by the new `AUDIT_EXPORT_TIMEOUT_SECONDS` (design value 120 s, owned by `off.sh`). Redaction stays at emission (FR-079); the stream half of SC-030/SC-042 reconciles from the exported file once the store is gone. Extends FR-078, FR-079, `data-model.md` §16/§25, `kubernetes-objects.md`, quickstart §19/§24, plan C-18, T049, T088, T136, T141, T152, T174. Report: `review/2026-09-20/AD-26-AD-24-tier-removal.md` |
| AD-37 | — | new (operator review 2026-09-20) | *Operator review.* Requirements-checklist closures, first half: six success criteria name their verification method (SC-011, SC-019, SC-027, SC-033, SC-034, SC-035); the obligations index below; an indeterminate workflow status is never a success (FR-054); a second workflow engine is forbidden by name (FR-013) |
| AD-38 | — | new (operator review 2026-09-20) | *Operator review.* Requirements-checklist closures, second half: the denied management ports are one list, observed at gate item G2 and cited everywhere (FR-075, SC-029); every "asserted in CI" names its make target and task; containerlab's pin cites its evidence and the mapping version is stated as first-party (RD-01) |
| AD-39 | — | new (operator review 2026-09-20) | *Operator review.* The clarify-delta closures that needed no design decision: FR-103's force-release guard rules and open-finding consequence, FR-107's cannot-run outcome, schedule scope, interval floor and stalled-schedule alert, FR-102's probe-route exception, FR-106's key-by-key writing and redacted endpoint, FR-108's three definitions and leftover rule, FR-105's hash source and `spec`-only scope, FR-104's substitution preconditions, NFR-014's deferral to §27, and SC-047 to SC-050. Carries SC-047, SC-048, SC-049, SC-050 |
| AD-40 | — | new (operator decision 2026-09-21, fifth pass) | *Operator decision.* A scheduled re-verification that could not run — target unreachable, read timed out — sets `Ready=Unknown/VerificationFailed` at that pass, with `Degraded=True/VerificationFailed` naming the target and `lastVerifiedTime` not advancing; never `Ready=False`, never `Ready=True` left standing (constitution Principle I). `Degraded=True` beside `Ready=True` is a closed list of two. Amends `AD-39`. FR-107, FR-054, FR-067, SC-008, SC-044 |
| AD-41 | — | new (operator decision 2026-09-21, fifth pass) | *Operator decision.* On the tier path the naming band `100–999` is enforced by the **mapper**, at interpretation and before any claim exists; the translator keeps only the structural `100–4000` check, because its input — the allocator's output — cannot tell a named VLAN from an allocated one, and **no provenance field** is added to the normalized service intent. Amends `AD-33`'s "the translator enforces the naming band". FR-062, FR-034; T091 (the fixture moves to its mapper half), T095, T098 |
| AD-42 | — | new (operator decision 2026-09-21, fifth pass) | *Operator decision.* VNI and VLAN claims alike are adopted on correlation label, deterministic claim name **and** carried value, under the one naming scheme `<namespace>.<name>.<role>`, which the allocator now uses for its VNI claims too; a label-and-value match under any other name adopts nothing. Amends `AD-09` and `AD-32`. FR-109, SC-046, R-45; T093, T099, T170, T171, T173 |
| AD-43 | — | new (operator decision 2026-09-21, fifth pass) | *Operator decision.* SC-004's route-half negative control is a declarative fault — `Fabric.spec.overlay.interASVPN` set `false`, rendered on both reflecting spines through the one southbound, the spanning service's `RoutesMissing` observed within SC-044's bound, the field restored and the restoration read back — never a device-side edit the revertive policy would race and one spine could not show. The `Fabric` reports `Ready=False/NotConverged` naming the spines and the setting while it lasts; no reason code, rule or identifier is added. SC-004, FR-108, FR-013, R-46, R-48 |
| AD-44 | — | new (analysis 2026-09-21, fifth pass) | *Choice — ratified by the operator, AD-73.* Finalization resolves adoption — the same three-part rule — for every carried value not yet in `status.claimRefs` **before** it releases, and never claims on a deleting object, so a tier-submitted `Network` deleted before its first reconcile orphans nothing. Rejected: the deployer writing `status.claimRefs` at apply, because the tier holds no status write. FR-109, SC-046; T055, T060, T170, T171, T173 |
| AD-45 | — | new (analysis 2026-09-21, fifth pass) | *Ratified by the operator, AD-73.* The analytics store and the tier collector are built by T087 and installed by T088 before any agent workload (US7, plan P6), not by T136 in US12: the store is the audit record, and T101's events, T103's SC-030 reconciliation and the tier removal's export all read it before US12 exists. T136 extends the collector with its second exporter. Reversible; the rejected alternative — moving the audit reconciliation to Phase 15 — is recorded. No identifier added |
| AD-46 | — | new (analysis 2026-09-21, fifth pass) | Fifth-pass closures on the tier's removal and the audit export, none needing the operator: the export is **read back** — `test_audit_reconcile.py` gains a file-source mode and T152 ends with it (FR-078); SC-042 is reconciled against **the usernames the run used**, captured into evidence at the tier phase and again before the operator credential is removed (T088, T049); the removal's two lists are told apart — the refusal-decision list, the quiesce, then the authoritative list — and the scale-down precedes the export on **every** path past the refusal, a non-empty list after it without the flag falling back to the refusal (NFR-006); the re-run rule is stated once, in `data-model.md` §16 — skip a *verified* export found under the lab's evidence root, add otherwise, never rewrite; User Story 7 scenario 4 split into 4a and 4b with its number kept; R-47's row here, the plan's "Audit record" row and its architecture banner brought up to `AD-35`/`AD-24`. Extends NFR-006, FR-078, SC-042; T049, T088, T103, T141, T148, T152, T174 |
| AD-47 | — | new (analysis 2026-09-21, fifth pass) | Fifth-pass closures on claims and the VLAN bands: FR-075 and US6 scenario 3 name the deployer's `patch`; VLAN 100 in US4 scenario 4, quickstart §11 and the `network-spec` exemplar is a **named** VLAN and claims nothing; the added-attachment rule refuses only an allocation-band VLAN the object does not already carry; pre-`AD-33` "range the authority manages" wording replaced by the naming band with both bands stated; the VLAN a standalone `acl` names is a **reference**, exempt from both band rules; G11 observes that a deleted claim's value is freed synchronously; the provisional-determination MUST stated once, in FR-075. FR-034, FR-062, FR-075, FR-109, R-44; T014, T017, T044, T091, T105, T106, T170, T171 |
| AD-48 | — | new (analysis 2026-09-21, fifth pass) | Fifth-pass closures on fabric readiness, the drift policy and the gate: the stated `spec.revertive: true` asserted by T028 and T054, with T036 only the negative assertion; FR-108's drift-class exception; the gate-owned scratch `Config` of G13 defined in FR-108 as the named exception to FR-013, its cleanup read back in the cluster as well as on the node; the `EvpnRoutesLost` guard conditioned on one EVI on at least two leaves; G7 recording the series names that guard reads; Open item 18 for G13's unknown; three stale texts. FR-013, FR-015, FR-108, R-46, R-48 |
| AD-49 | — | new (analysis 2026-09-21, fifth pass) | The clarify-delta requirements' uncovered clauses: every MUST `AD-39` added has a task that tests it (FR-107's floor and start refusal, FR-108's leftover scan, FR-106's running agent and SC-048's redaction, SC-047's failing gate and FR-104's return path, FR-054's unknown status, FR-013's single engine, FR-103's and FR-102's remaining cases, SC-043's empty reason); one name for the stalled-schedule metric; the denied-port copies kept honest by a test; T175's partition named in SC-025's row |
| AD-50 | — | new (analysis 2026-09-21, fifth pass) | Fifth-pass closures, **task-list half**: the refused fixture moved to `examples/constructs/negative/` and is run by T172 for SC-045's VLAN half; four tasks lost a `[P]` they could not honour (T005, T012, T016, T036) and the parallel lists, the US1 example and the serial-files list follow; `metrics.py` and `metrics.go` are created by the first task whose test needs them (T080, T059); the Go toolchain is selected by T002, recorded by T008 and compared by `make verify-pins`; namespace `monitoring` is created by T037 and the observability install order is stated once, in quickstart §1; `make test-static` runs every offline shell suite with a reach assertion (completing AD-28); `config/manager` and `examples/services/` left the tree. **Constitution-carrier half**: CR-002 states "never a service type not asked for" with FR-032's two MUST NOTs; CR-004 and FR-066 say *server-side* dry-run; **CR-009** (MTU envelope, probe sizes, no throughput assertion) and **CR-010** (IPv6 Type-5 limitation) added; CR-003 names the carrier of the enumeration (FR-034); a status query takes no confirmation (FR-069, FR-057); NFR-012's envelope and FR-087's alert set are decidable; six key entities added. Two CR identifiers added, no other |
| AD-51 | — | new (operator decision 2026-09-21, sixth pass) | *Operator decision.* On an `ip-vrf` an attachment's VLAN is **named** by the operator, from `100–999` and claiming nothing, or **absent**, the untagged subinterface; the allocator never allocates one. A VLAN claim's role `vlan-<entry>` therefore names a `vlans[]` or `bridgeDomains[]` entry and nothing else, the adoption predicate reads those two fields, an `ip-vrf` attachment VLAN in `1000–4000` is `AllocationConflict` by construction, and the added-attachment rule reads `spec` alone. A `tagged: true` request shape with a `vlan-<node>-<port>` claim role rejected. SC-046's held-claim clause is measured on a `mac-vrf` and gains a zero-VLAN-claim clause for an `ip-vrf`. Amends `AD-32`, `AD-42`, `AD-47`. FR-062, FR-109, SC-046, two edge cases; kuid-claim-profiles.md §2, §4, §5, §8, reconciliation.md Rule 3, crd-api.md, construct-vocabulary.md §3, network-spec.md §2, both JSON schemas; data-model §9–§12, §18, §20; plan C-13, P7, R-45 and three verification rows; quickstart §26a; T014, T017, T091, T093, T098, T099, T170, T171, T173 |
| AD-52 | — | new (operator decision 2026-09-21, sixth pass) | *Operator decision.* The validating admission webhook **fails closed** — `failurePolicy: Fail` on `CREATE` and `UPDATE` of `networks`, never on `DELETE`, no `timeoutSeconds` stated. The provider serves it, so while the provider is down no `Network` create or update is admitted and every admission rule always holds (FR-034, CR-003 "at admission alike"); a delete is not intercepted, so removal still works and waits on the finalizer. A dry-run the API server fails for that reason is the cluster API dependency being unavailable (NFR-010), retried and reported as that, never a validation refusal. Every "applied while the provider is down" sentence is reworded to what can happen — applied, then deleted before the provider's first reconcile. `Ignore` with an after-the-fact `Accepted=False` rejected. Amends AD-32 and AD-44. FR-034, FR-109, an edge case; crd-api.md, kubernetes-objects.md, reconciliation.md Rule 8, kuid-claim-profiles.md §3; data-model §3; plan C-05, P7, the API layer row and the SC-046 row; quickstart §26a and §Diagnosing a failure; T056, T061, T092, T100, T146, T173 |
| AD-53 | — | new (operator decision 2026-09-21, sixth pass) | *Operator decision.* An object being deleted reports **`Ready=False` with the new reason `Deleting`, at once** — from the moment finalization starts (Rule 8 step 1), in every deletion, whatever the reachability of its targets — beside `Deleting=True/<reason>`; nothing is read back to decide it, the re-verification schedule keeps a deleting object only as the finalizer's requeue and never sets `Ready=Unknown` on it, and the tier's status answer says "being removed", never "failed". `Deleting` on `Ready` is the sixth pass's one vocabulary addition. Rejected: following `AD-40` (False or Unknown by reachability). FR-103, FR-107 |
| AD-54 | — | new (analysis 2026-09-21, sixth pass) | Sixth-pass closures on re-verification and readiness, none needing a decision: `lastVerifiedTime` and `reverify_last_success_timestamp_seconds` advance on **every pass that ran**, whatever it found, and freeze only on a pass that could not run — "success" in the metric's name means the pass completed; the per-object series is removed when finalization starts; on the `Fabric`'s one `Degraded` condition `VerificationFailed` is the reason while a required target cannot be read and `StaleConfigurationPossible` from the first pass that runs with a finding still open, the finding in `status.findings[]` throughout; the between-passes rule reaches the `Network` side (T054, T059) and `target_failure.sh` states its SC-008 assertion; T080 creates the per-stage request-outcome counter T079 asserts before US12; T087 mounts `llm-provider` read-only in all four agent Deployments, never `secretKeyRef`/`envFrom`, asserted by T168. FR-107, FR-103, FR-106, FR-054, FR-092, SC-008, SC-044 |
| AD-55 | — | new (analysis 2026-09-21, sixth pass) | Sixth-pass closures on the fabric dependency, the gate's series names and the tier's removal: a `Network` waits on a `Fabric` that **exists and is Accepted, never on one that is Ready** — Rule 3 item 2, the `data-model.md` §3 row and the §19 diagram brought to §19's statement, T059 stating it and T054 testing it; **G7 observes the generated series names through a throwaway pair of the pinned gNMIc and collector images**, the pipeline not being installed when the gate runs, records the naming-relevant settings beside them, T129 ships those settings and T134 re-checks the live names before T130's rules load; `username_unchanged` is read only by T152's file-source run, T148 deriving the set and its cardinality from the tier-phase captures; the `agent-otel-collector` row says one exporter from US7 and the second from US12; T155 closes Open items 1–18; a *verified* export is identified by the store's row count **and** newest-row timestamp (`data-model.md` §16, T174). FR-078, FR-100, FR-107, FR-108, SC-004, SC-042, SC-044 |
| AD-56 | — | new (analysis 2026-09-21, sixth pass) | Sixth-pass closures on claims and the VLAN bands, none needing a decision: an allocation-authority **error** is a wait and never an answer — not "nothing adoptable", not `AllocationConflict`, the finalizer kept under the existing reason `RemovingConfiguration` with nothing released, no reason code minted; both JSON schemas bound a VLAN structurally at `1–4094` so the mapper states both bands for `4001–4094` too, with a new mapper fixture; `data-model.md` §9 requires a claim behind every *allocated* VLAN and every VNI only; the standalone `acl`'s exemption from the added-attachment rule reaches FR-109, T014 and T017; `status.claimRefs[]` has one field list, in crd-api.md §Status; §18's `AllocationConflict` names the VLAN case; G11's observations have **one list and one count**, the six of kuid-claim-profiles.md §6; the translator contract no longer names the allocator as a caller; and `metadata.name`, the list-entry names and the service identifier are bounded so every claim name fits in 253. Amends `AD-47`. FR-062, FR-109, two edge cases; kuid-claim-profiles.md §4–§6, §8, reconciliation.md Rule 3 and Rule 8, crd-api.md, both JSON schemas, translator-api.md, construct-vocabulary.md §5, network-spec.md §1; data-model §8, §9, §12, §18–§20; plan C-05, C-12, G11, R-44 and three verification rows; quickstart §6, the gate and diagnosis tables; Open item 15; T013, T014, T017, T044, T055, T060, T091, T098, T170, T171 |
| AD-57 | — | new (analysis 2026-09-21, sixth pass) | Sixth-pass closures on the task list's ordering, none needing the operator: T080 creates `agents/common/tracing.py` — the root request span whose trace id is the correlation id, and the span-event helper the audit events of US4 go through — and T135 extends it; T152 runs on a lab re-provisioned `--with-intent-tier` after T151's last destroy and T159 re-provisions the tier T152 removed, the `username` captured by that run being the one the take is checked against (quickstart §24, §28; plan P11, P12); the `LabReady` wait of T034 is a credential-less port accept on `57400`, never a device client under `scripts/`, with a planted `gnmic` fixture in T025 (FR-108 and SC-049 unchanged); T134's `alerts_fire.sh` follows FR-108's leftover convention as T167 does (`AD-49` amended); plan P3 states `AD-42`'s three-part adoption; `tests/lib/` joins plan's tree and T001; the US7 prose names US2 as the graph does; T025 describes the shell suites by the glob; T042's `metrics.go` clause and T088's bracket corrected. No identifier added, `[P]` count unchanged at 84 |
| AD-58 | — | new (analysis 2026-09-21, sixth pass) | Sixth-pass closures on the specification and the constitution's carriers, none needing a decision: **CR-010 gains its testers** — T115's fake-state read-back case (IPv6 gateway declared, IPv6 Type-5 absent → `Ready=False/RoutesMissing` naming the route) and its `refuse_gateway_ipv6_unqualified` interpretation fixture, made to pass by T116 and T117; FR-105's removal of a modified service restated as the data model has it — stated at the request's first confirmation, executed only through both — and asserted by T094; Key Entities cites plan §Component inventory; the quickstart's G6 row gains the 9320/9300 payload boundary that plan G6, T043 and CR-009 already state; and the forward table's eight reworded `yes` rows (FR-054, FR-057, FR-066, FR-067, FR-078, SC-007, SC-008, SC-035) carry the AD note their neighbours do, the flags unchanged because `yes` is defined over the merge and the retarget |
| AD-59 | — | new (analysis 2026-09-21, sixth pass) | Sixth-pass closures on vocabulary, alerts and the traceability tables, none needing a decision: an unqualified construct or property is an `unsupported_properties` entry — `data-model.md` §8's `unqualified_properties` is gone, because the closed interpretation schema cannot carry it; each audit event is emitted by **one** process — T101 states the supervisor's three (confirmation, decline, refusal) and names the deployer's (submission, removal, out-of-band, T100), so SC-030's equal-count reconciliation holds; **every alert of the required ten is shown to fire and to clear** — live where the platform has a declared fault, `EvpnRoutesLost` by `AD-43`'s `interASVPN: false` among them, and by T130's rule unit test (`promtool test rules` from the pinned Prometheus image, written before the rules) for every rule, the only proof for `OtlpDataPointsRejected`, `DuplicateDeviceSeries` and the `EvpnRoutesLost` guard's no-fire half, never reported as a live firing; **R-03 is live** — rewritten by RD-01, as the plan has carried it since the retarget — so live risks are 46 of 48; the Obligations index names T085/T080 and T077 for FR-078(b), and `driftpolicy_test.go` and `reverifyinterval_test.go` are written test-first in T028 and made to pass by T042; the audit export's one file name, `audit-export-<attempt>.ndjson.gz`, is stated in `data-model.md` §16; quickstart §27 cites §15, and the namespace table lists `agentic-netops-services`. Extends SC-035; amends `data-model.md` §8/§16/§21, plan SC-035 and the re-verification row, quickstart §21/§27, `kubernetes-objects.md`, T028, T042, T088, T101, T130, T134 |
| AD-60 | — | new (analysis 2026-09-21, sixth pass) | What the six editors of the sixth pass left at their edges: FR-108 names the gate's throwaway Pod; the leftover scan reads gate-labelled scratch namespaces; a declarative fault is restored from an exit trap; the control-plane-only acceptance run is one pass on the standing lab and the teardown follows quickstart §28; the stream's `ready` is the three-valued status string; an `accessLists`-only object is never an owner under the one-owner rule. No identifier added |
| AD-61 | — | new (analysis 2026-09-21, seventh pass) | The fail-closed webhook of `AD-52` **evaluates its rules on a `CREATE` and on an `UPDATE` that changes `spec`** on an object with no deletion timestamp, and admits unread an `UPDATE` that leaves `spec` unchanged — a finalizer, a label, an annotation, the force-release included — and any `UPDATE` of a deleting object; the registration is unchanged, the exemption is the handler's first step, and the guard on the force-release annotation (the `deny-tier-force-release` policy, the provider's honouring rules) is untouched. Closes the seventh pass's one high finding: Rule 8 step 7, FR-103's force-release on a device that has left the `Fabric` inventory and the deletion of a service whose attachment no longer resolves were each an `UPDATE` the platform's own webhook would have refused. Also closed: the interpretation schema's `vlan` is floored at `0` with no upper bound, so `4095` and above reach the mapper's both-bands refusal (fixture `refuse_vlan_named_not_a_vlan`); T055, T060 and Rule 8 step 6 carry the `mac-vrf` attachment-removed case in place of one `AD-51` made unreachable; the `AD-32` row notes `AD-51`; and the `service_id` generation rule is stated once (`data-model.md` §8) — a **choice**, the predecessor tier's: 15 lower-case hexadecimal characters of a random UUID, never built from the tenant — with the examples of quickstart §11/§12, `network-spec.md` §6 and `crd-api.md` following it. Amends FR-034, FR-062; `crd-api.md`, `reconciliation.md` Rule 8, `interpretation.schema.json`, `construct-vocabulary.md` §5, `network-spec.md` §6, `data-model.md` §3/§8, plan C-05/C-12 and two verification rows, quickstart §6/§11/§12, T055, T056, T060, T061, T091, T098. Amends `AD-52` by a note |
| AD-62 | — | new (analysis 2026-09-21, seventh pass) | Seventh-pass closures on readiness and the stream: `ResourceRef.ready` is the `Ready` status string with its `reason`, emitted by the deployer (T100), streamed unaltered (T085), asserted (T092) and rendered (T125) — amending `AD-60`, which had reached the contract and the client only; "had reported Ready" is read at the current generation, so an updated object whose target is away is `Ready=False/NotConverged`, not `Unknown` (FR-107, data-model.md §18; T059, T054); SC-044's "never True, never False" polls run from the first `Unknown` until reconnection (T064, T167); a `Fabric` has no held deletion (T040); `ReverificationStalled` fires on the age of the last pass that ran, whatever `Ready` says (`contracts/crd-api.md`, quickstart §21); the `Degraded` reasons have a total order ending in `TelemetryUnavailable`, with `PartialFailure` and `TelemetryUnavailable` given builders and asserters (T040, T059, T133; T028, T054). No identifier added |
| AD-63 | — | new (analysis 2026-09-21, seventh pass) | *Ratified by the operator, AD-73.* A removal asked of the tier is watched until the object is gone, under the convergence timeout of a creation: gone within it is `COMPLETED`; still present at it the turn ends at `PROVISIONING`, saying the removal is in progress and naming what the `Deleting` condition says is outstanding — never a success, never a failure, no status minted, nothing force-released; a creation watch that sees `Ready=False/Deleting` ends as a failure naming the deletion and as deleted outside the tier (FR-069, FR-067, FR-105; data-model.md §17; `contracts/supervisor-http.md`, `contracts/kubernetes-objects.md`; T100, T092, T079, T085, T125). Coordinator's choice on recommendation; reversible. No identifier added |
| AD-64 | — | new (analysis 2026-09-21, seventh pass) | Seventh-pass closures on the lab's lifecycle and the verification tooling, none needing a decision: `off.sh` **never deletes anything under the lab's evidence root**, on the full teardown or the tier's purge, and `--preserve-evidence` only adds the optional teardown-time capture (FR-010, T049; asserted by T029 and T174); T052 ends with the lab provisioned again, because US2 and US6 start from a standing lab; quickstart §25–§27a run after §11 and before §24's block, or after §28's step 0; T134's two declarative changes are restored from an exit trap as T064's and T167's are (`AD-60` amended); the leftover fixture plants a **fourth** kind, a gate-labelled scratch namespace, T166's scratch namespaces carry that label with the removal read back, `ObservabilityReady`'s series-name and settings re-check gets `observability_recheck_test.sh`, and `AD-45`'s install order gets `tier_phase_order_test.sh` inside T174; T153 stops before §28 and tears down; T103 takes its live-store export by invoking `audit_export.sh` stand-alone, and a usernames record an earlier export left is never read for the running tier; the offline job needs a container runtime and one pull of the pinned Prometheus image, and the gate's observed files under `tests/gate/observed/` are committed after the gate run, the rule test reporting "not run" until they exist. No identifier added |
| AD-65 | — | new (analysis 2026-09-21, seventh pass) | Seventh-pass closures on the specification's indexes and carriers, none needing a decision: §Obligations index is **redated to the seventh pass** and says what each pass added to it, having still claimed to reflect the operator review of 2026-09-20 under rows that cite `AD-51`…`AD-56`; every row re-read against its requirement in both directions — FR-109(i) gains the two clauses that had no row (no claim created on a deleting object, T060/T170; nothing applied while the provider is down, `AD-52`, T061/T056/T173), FR-015 gains **(h)**, the overruled platform-owned path (T059/T054, `AD-66`), FR-078(f) states what a failed export is, FR-107(c) and (f) carry the current-generation reading (`AD-62`) and the between-passes case (`AD-54`); **FR-108 is indexed**, eleven rows, five of them recording a clause that a task states and no test would fail without; FR-108's leftover rule names **the gate's labelled scratch namespace**, which only T043's scan carried; CR-004's carriers gain **FR-015 and FR-045**, which the plan's Principle III row already cited. Amends FR-108, CR-004 and the Requirements preamble; traceability rows CR-004 and FR-108 and §Obligations index. No identifier added |
| AD-66 | — | new (analysis 2026-09-21, seventh pass) | Seventh-pass closures on names, commands and an uncovered clause, none needing a decision: the tier metric prefix is the literal `agentic_netops_agent_` and FR-092's per-stage outcome counter is `agentic_netops_agent_stage_requests_total{stage,outcome}`, both stated once in `data-model.md` §21 and **following the predecessor's `agents/common/metrics.py`, read and not run** — the two counters CD-01 and CD-04 named become `agentic_netops_agent_auth_refusals_total` and `agentic_netops_agent_out_of_band_changes_total{change}`, and T129's filter matches the literal prefix; quickstart §7, §22 and §24 run `go test` against the packages that hold the tests (`./pkg/migration`, `./tests/unit/...`), T119 and T096 name the functions, and `no tests to run` is a failure of the step; FR-015's overruled-path clause gains its builder (T059), its envtest (T054, a fake `Deviation{reason: OVERRULED}` → `Applied=False/OwnershipConflict`, never reapplied) and index row FR-015(h), asserted live by T064 only if G13 recorded `OVERRULED` as producible; `data-model.md` §9 spells `routeTargets` as the schema does (`importRT`, `exportRT`) and tells it from the `Network`'s `{import, export}`; `AD-46` carries its amendment by `AD-55`; the stream examples name `migr-svc1`; quickstart §23 drops a path nothing creates. No identifier added |
| AD-67 | — | new (analysis 2026-09-21, seventh pass) | Seventh-pass closures on the task list, none needing a decision: T040 takes the fabric read-back as an interface and T041, which creates `internal/verify/fabric.go`, wires the reconciler to it — the one used-before-created reference that had no forward note, the task lines left where they are; T040 makes T028's **envtest file** pass, T028's two `cmd/srl-provider` start-up tests passing with T042 (`AD-59`); T087 names the manifest half of T168's `test_llm_endpoint.py` as what its read-only `llm-provider` mounts make pass, and §Phase Dependencies names both halves; T072's script and in-cluster Job implement the FR-079 redaction pattern set themselves — `redaction.py` is T074's and no tier image exists until T086 — with T168's one embedded-userinfo fixture on both halves keeping the two implementations equal; T025's credential-literal check (FR-019, CR-008) gains its own planted fixture, a `stringData` password under a fixture `deploy/` tree failing the check naming the file (plan's `make`-target table says the same); T175's stray comma. No identifier added, `[P]` count unchanged at 84 |
| AD-68 | — | new (analysis 2026-09-21, eighth pass; **operator decision**) | A leaf two services would share belongs to the fabric's priority-10 `Config`: an access port's `admin-state` and `vlan-tagging` and `irb0`'s `admin-state` are rendered by the fabric `Config`; the port's tagging mode is declared in `Fabric.spec.inventory[].untaggedAccessPorts` and an attachment must ask for it, the refusal listing the ports declared in the mode asked for; a subinterface's `/acl/interface[…]/interface-ref` is rendered by the `Config` that renders the subinterface, a standalone `acl` writing only its filter entry; a leaf in FR-015's rule is a non-key leaf and the provider's overlap check is the backstop. FR-015, FR-034; data-model §3a, §10, §13, §20; `contracts/crd-api.md`, `contracts/reconciliation.md` Rule 4, `contracts/acl-render-contract.md`; G9, Open item 19; tasks T013, T014, T027, T028, T039, T040, T043, T053, T054, T056, T057, T059, T061, T098, T107, T112 |
| AD-69 | — | new (analysis 2026-09-21, eighth pass) | Every generated `Config` lives in `agentic-netops-system`; a fabric `Config` carries an owner reference to its `Fabric`, a service `Config` carries none — a cross-namespace owner is read as absent and the dependent collected — and is tied to its source by annotation and label and removed by the finalizer; a `Config` of the derived name that is another source's is never overwritten (`Applied=False/OwnershipConflict`). FR-016, FR-103; `contracts/crd-api.md`; tasks T028, T040, T054, T059 |
| AD-70 | — | new (analysis 2026-09-21, eighth pass) | T047 — freezing the fabric golden files against G12's observed serialization — moves after T052, the first gate run, and depends on it rather than on T043's implementation of the gate; it keeps its id. FR-020, R-36; tasks T047 and §Phase Dependencies |
| AD-71 | — | new (analysis 2026-09-21, eighth pass) | Eighth-pass closures of the medium findings, one a recorded choice: a `firstPartyImages` entry whose Dockerfile is absent is *pending* — digests still resolved, fails if anything references the image, none admitted at acceptance; `make verify-evidence` (T012) owns the SC-004 recording rule and T151 ends by running it; `make verify-render-schema` runs `sdc-lite config validate`, pinned by tooling; the tier purge scales down the workloads that exist; T064 builds both modes of `delete_unreachable.sh`; **a force-release finding whose node has left `spec.nodes` stays in `status.findings[]` and does not count toward `Degraded` until the node returns** (choice); `target_failure.sh` records the layer's target-loss latency and a miss fails SC-008 naming it. NFR-003, SC-004, FR-020, NFR-006, SC-043, FR-103, SC-008; data-model §3a, §26; Open item 20; tasks T008, T009, T010, T012, T028, T040, T047, T064, T088, T151, T174 |
| AD-72 | — | new (analysis 2026-09-21, eighth pass) | Eighth-pass closures of the low findings, none needing a decision: FR-038, FR-051, FR-052, FR-071, FR-073 and FR-081 cited by id on the tasks that build them, and the four range citations written out; SC-012 measured on a Ready fabric; User Story 7 scenario 4b in NFR-006's order; a purge stopped by a held deletion names the target or the `HolderPresent` holder. Tasks T078, T083, T084, T085, T088, T101, T105, T110, T124, T125 |
| AD-73 | — | new (2026-09-21; **operator decision**) | The operator ratifies, as written and with no amendment, the five choices the analysis passes made on their own recommendation: AD-44, AD-45, AD-63, the `untaggedAccessPorts` declaration inside AD-68, and point 6 of AD-71. No artifact changes meaning; no unratified choice remains |
| AD-74 | — | new (first implementation run, 2026-09-21) | G11 failed on kuid `v0.0.13`; the first-party allocation authority of CD-03 adopted by recorded decision, made under the operator's delegation; T176–T183 build, install and qualify it; FR-098 and FR-104 are why a patched kuid was not an option |
| AD-75 | — | new (first live gate, 2026-09-21) | The schema-deviation repository is served to the device-configuration layer from an in-cluster mirror, under a tag; decided under the operator's delegation |
| AD-76 | — | new (first live gate, 2026-09-21) | Configuration-integrity leaves are read from the configuration datastore; decided under the operator's delegation |
| AD-77 | — | new (first live gate, 2026-09-21) | SC-004's negative control is the fault the gate observes to stop reflection; the `Fabric` declares it; decided under the operator's delegation |
| AD-78 | — | new (first live gate, 2026-09-21) | G6's "refused one byte above" applies to the platform's port maximum; the tenant boundary is proven on the data plane; decided under the operator's delegation |
| AD-79 | — | new (first live gate, 2026-09-21) | The applied-side binding check reads the keyed binding; a shared filter's per-subinterface entry list is an observation; decided under the operator's delegation |
| AD-80 | — | new (first live gate, 2026-09-21) | The data server is re-pinned to a release that reverts drift, qualified against the pinned config server; decided under the operator's delegation |
| AD-81 | — | new (first live gate, 2026-09-21) | Golden files freeze the identityref form G12 observed; the offline validator's defect is handled on its input only; decided under the operator's delegation |
| AD-82 | — | new (first live gate, 2026-09-21) | A standing delegation: a live finding that contradicts an assumption is decided by the build, recorded, and never by waiving a gate; decided under the operator's delegation |

### Risks

| Composite | Source | Verbatim? | Note |
| --- | --- | --- | --- |
| R-01 | `001:plan risk 1` | rewritten | Upstream examples and current APIs differ. **Rewritten (RD-03)**: confirmed real — the published artefacts and the main branch disagree on field names — and de-fanged, because the upstream fabric API is now reference design only |
| R-02 | `001:plan risk 2` | rewritten | **Rewritten, not retired (RD-03)**: "no upstream provider for the required device path" becomes "the first-party provider is the only renderer of every device path", which is a design property to hold rather than a gap to close |
| R-03 | `001:plan risk 3` | rewritten | **Rewritten, not retired (RD-01)**: "the fast profile lacks full management/EVPN behaviour" — there is no fast/conformance split, and with it no "use the other profile" escape — becomes "the licence-free emulated types do not model a property a construct depends on", mitigated by the per-construct qualification record and the refusal by name (FR-097). The plan has carried it as a live row since the retarget; this row said *retired* until the sixth analysis pass of 2026-09-21 corrected it (`AD-59`). `001:plan risk 3` still resolves here |
| R-04 | `001:plan risk 4` | retired | **Retired by RD-04.** The risk was realised, not avoided: no licence-free container type has an SRv6 data plane or counters, which is why the scope is deferred. `001:plan risk 4` still resolves here |
| R-05 | `001:plan risk 5` | rewritten | OpenConfig coverage is incomplete. **Rewritten (RD-08)**: the gap is known and specific — EVPN and VXLAN are marked not-supported by the vendor's own deviation files — so native-first is the default and the register records every exception |
| R-06 | `001:plan risk 6` | yes | Duplicate controller ownership |
| R-07 | `001:plan risk 7` | yes | Source MPLS semantics lack equivalents |
| R-08 | `001:plan risk 8` | rewritten | Privileged and KVM lab requirements. **Rewritten (RD-01)**: the KVM and nested-virtualization half is deleted because no hypervisor is required; the privileged-container and host-runtime trust boundary survives unchanged |
| R-09 | `001:plan risk 9` | yes | Duplicate telemetry and cardinality |
| R-10 | `001:plan risk 10` | yes | Topology and metric labels do not join |
| R-11 | `001:plan risk 11` | rewritten | VXLAN overhead breaks traffic. **Rewritten (RD-10)**: the numbers are concrete (9412 / 9398 / 9348) and the sharpest edge is new — the device performs no VXLAN MTU check and the endpoint side defaults to a value that blackholes TCP |
| R-12 | `001:plan risk 12` | rewritten | The shared Docker network is over-broad or collides. **Rewritten (RD-01)**: realised on the reference host, where the inherited default collides with an existing network. The mitigation is now a requirement: a configurable CIDR and an overlap preflight (FR-008) |
| R-13 | `001:plan risk 13` | yes | The cluster exhausts host resources |
| R-14 | `002:plan R-01` | yes | Transport gateway may not expose client-CA verification |
| R-15 | `002:plan R-02` | yes | Fabric controllers may reconcile only their own namespace |
| R-16 | `002:plan R-03` | yes | The tier identity extends into the allocation namespace |
| R-17 | `002:plan R-04` | yes | A single-writer checkpointer pins the supervisor to one replica |
| R-18 | `002:plan R-05` | yes | Model quality drifts across a provider switch |
| R-19 | `002:plan R-06` | yes | The tier dashboard needs a mount on a control-plane file |
| R-20 | `002:plan R-07` | yes | Prompt injection succeeds despite the stacked mitigations |
| R-21 | `002:plan R-08` | yes | Kubernetes has no multi-object transaction |
| R-22 | `002:plan R-09` | yes | The polyglot tree doubles the build and CI surface |
| R-23 | `002:plan R-10` | yes | Tier workloads displace fabric workloads |
| R-24 | `002:plan R-11` | yes | Two collectors could drift into two instrumentations |
| R-25 | `003:plan R-01` | retired | **Retired by RD-02.** A YANG-invalid whole-config access-list row poisons every later whole-config write — a failure mode of a configuration store that does not exist here. `003:plan R-01` still resolves here |
| R-26 | `003:plan R-02` | closed | A rule the switch never accepted. **Closed by construction (RD-05)**: every applied-side path is keyed by filter name, type, entry and direction, so a switch-wide check is not expressible. The row is kept, not deleted, because its lesson is now carried by NFR-013 and because the platform has a *new* stock-object hazard — the device's own `cpm` filter entries — that would recreate it if an unkeyed check were ever written |
| R-27 | `003:plan R-03` | yes | Regenerating goldens hides a real change |
| R-28 | `003:plan R-04` | rewritten | A local `vlan` collides with the derived routed-instance band. **Rewritten (RD-09)**: no band is derived, so the collision cannot occur. **Rewritten again (AD-33)**: the platform's VLAN space is split into a chosen naming band `100–999` and the index's allocation band `1000–4000`; a named VLAN outside the naming band, and any VLAN outside `100–4000`, is refused with both bands stated. Chosen, not derived — nothing reinstates PC-15 |
| R-29 | `003:plan R-05` | rewritten | Two services binding a filter to one port at one stage. **Rewritten (RD-05)**: the unit is the subinterface, direction and address family, so the risk narrows and the refusal gains a platform reason |
| R-30 | `003:plan R-06` | yes | Suggested prompts drift from the site's real port map. Unchanged; only the port names moved |
| R-31 | — | new (retarget) | The allocation authority is dormant upstream (last release 2024-12-27). Pinned and qualified at P0 by gate item G11, with a named first-party fallback behind the same claim contract, decided at P0 and never silently |
| R-32 | — | new (retarget) | The device-configuration layer's deviation patch weakens schema validation. Gate item G10 re-proves that the deviated schema still rejects the configurations the platform relies on being rejected |
| R-33 | — | new (retarget) | One device gRPC server, two clients: the session limit is shared by the device-configuration layer and the telemetry collector, and exhaustion presents as an intermittent fault with no single culprit (FR-086) |
| R-34 | — | new (retarget) | The lab image exposes a plaintext management port beside the encrypted one; a boundary that denies only the encrypted port has a bypass (FR-075) |
| R-35 | — | new (retarget) | The containerized dataplane's packet-rate ceiling makes any test that asserts a rate flaky, and the flake reads as a network fault (FR-020, NFR-004) |
| R-36 | — | new (retarget) | Identityref JSON serialization drift breaks idempotence permanently and presents as drift. Gate item G12 observes the form from a real read before the golden files are frozen |
| R-37 | — | new (retarget) | Omitting the route-reflector's inter-AS VPN setting yields "sessions up, zero EVPN routes" — a silent failure with nothing in the session state to point at. Gate item G8 |
| R-38 | — | new (plan refresh 2026-09-20) | Operator credentials are HTTP Basic over loopback plaintext: lab-only, the password always generated and never defaulted, production delta named (CD-01, FR-102, FR-019) |
| R-39 | — | new (plan refresh 2026-09-20) | A force-release frees identifiers a device may still carry: durable finding, colliding render refused while it is open, tier denied at admission (CD-02, FR-103) |
| R-40 | — | new (plan refresh 2026-09-20) | A false out-of-band report from hashing before defaulting or from a later schema default: hash taken from the dry-run result; defaults within `v1alpha1` treated as breaking (CD-04, FR-105) |
| R-41 | — | new (plan refresh 2026-09-20) | The recording shows a success the cluster did not have: acceptance from `kubectl` JSON, never from a frame (CD-06) |
| R-42 | — | new (plan refresh 2026-09-20) | The walkthrough drifts from the predecessor's, or a predecessor fact leaks into the README: prompts tabulated word for word, section order fixed, deny-list and lock-file checks in `make verify-readme` (CD-06) |
| R-43 | — | new (analysis 2026-09-20) | A first-party workload runs an image the current tree did not build: content-hash tags, a never-pull policy and the per-run image-ID check of `make verify-compat` (AD-05, NFR-003) |
| R-44 | — | new (analysis 2026-09-20, second pass) | The pinned allocation authority may not bind a claim for a stated value, or may bind two: observed by the widened gate item G11 before FR-109's path is relied on; a failure takes FR-104's path. **Widened again (AD-32, AD-33)** to four more properties the claim design rests on: that a refusal names the holder, that a claim's `metadata.labels` are selectable, which value a dynamic claim returns, and that none is ever below the index's `minID`. **Widened once more (AD-47)**: that deleting a claim frees its value synchronously, which the finalizer's release step rests on. **One list and one count (AD-56)**: the six observations (a)–(f) of `contracts/kuid-claim-profiles.md` §6, which the plan's gate table, R-44, research Open item 15, quickstart and T044 cite and do not re-count. AD-09 |
| R-45 | — | new (analysis 2026-09-20, third pass) | The provider's identity reaches VLAN claims and adopts by label: adoption is by label **and** value, the identity holds no create, update or patch there, and `status.claimRefs` enumerates the footprint (AD-16). **Strengthened by AD-32**: adoption takes label, the claim's deterministic name **and** a value the object carries, so a copied correlation label adopts nothing — which also closes CHK033 |
| R-46 | — | new (analysis 2026-09-20, fourth pass); amended (operator decision 2026-09-20) | The `Fabric` no longer asserts route exchange: mitigated by reading `inter-as-vpn` **and** `route-reflector client` back from every reflecting spine — a configuration-integrity check, stated as one, because both are configuration leaves the state datastore mirrors — by G8 and its negative control, by **T051's post-render probe on the rendered fabric** (reported under FR-108, never an input to readiness), by the first spanning service's `RoutesMissing`, by P3's negative control — declarative since AD-43: `Fabric.spec.overlay.interASVPN` set `false` and restored — and by the `EvpnRoutesLost` alert once guarded so that it cannot fire until one EVI is present on at least two leaves. AD-23, AD-31, AD-43, AD-48 |
| R-47 | — | new (analysis 2026-09-20, fourth pass; mitigation reworded by the operator review, AD-35, and the fifth pass, AD-46) | Removing the tier could delete the services it submitted, which an operator may not expect of a "tier" flag, and a finalizer blocked on an unreachable target could hang the removal: mitigated by a removal that **lists** the `Network`s and **refuses, non-zero and having deleted nothing, while any exist** — deleting them takes `--remove-services`, a word of its own — and, with the flag, scales the tier's request-accepting workloads down first, takes the list of what it deletes after that, exports the audit record, waits a bounded time that names the blocker, never force-releases, deletes the namespace only once a re-list is empty, and leaves the control-plane namespace `agentic-netops-services` untouched either way. AD-24, AD-26, AD-35, AD-46 |
| R-48 | — | new (operator review 2026-09-20) | Revertive mode may repair drift before a `Deviation` can be observed: gate item G13 records what is observable, the drift suite asserts only that, and an unobservable repair leaves SC-007 reported as not demonstrated, never waived. It is SC-007's risk alone since SC-004's negative control became declarative. AD-34, AD-43 |

## Reverse — source id → composite

Grouped by source specification. Every source requirement resolves to exactly one composite
requirement. Two source *decisions* (`003:D-01`, `003:D-08`) appear twice, because each is
carried both as a decision in its own right and as a clause merged into a requirement.

The retarget did not change this table's shape, only thirteen of its rows: where the composite
identifier a source resolves to was tombstoned by the retarget, the **Composite** cell says so
(`FR-003 — retired by RD-04`) and the disposition is `retired-by-retarget`. The source identifier
still resolves; what it resolves to is a number with a tombstone and a stated destination, which is
a different thing from a source requirement that was dropped. All thirteen are listed by name in
§Nothing dropped, and nothing quietly retired.

### 001 — Agentic NetOps SONiC EVPN/VXLAN Fabric (M1)

| Source | Composite | Disposition | Note |
| --- | --- | --- | --- |
| `001:FR-001` | FR-001 | carried | — |
| `001:FR-002` | FR-002 | carried | — |
| `001:FR-003` | FR-004 | carried | — |
| `001:FR-004` | FR-011 | carried | — |
| `001:FR-005` | FR-012 | carried | — |
| `001:FR-006` | FR-013 | carried | — |
| `001:FR-007` | FR-014 | carried | — |
| `001:FR-008` | FR-015 | carried | — |
| `001:FR-009` | FR-016 | carried | — |
| `001:FR-010` | FR-044 | merged | Merged with `003:FR-019` into the migration alias catalogue |
| `001:FR-011` | FR-045 | carried | — |
| `001:FR-012` | FR-048 | carried | — |
| `001:FR-013` | FR-017 | merged | The path-register clause `003:D-08` adds is stated inside it |
| `001:FR-014` | FR-018 | carried | — |
| `001:FR-015` | FR-019 | carried | — |
| `001:FR-016` | FR-086 | carried | — |
| `001:FR-017` | FR-087 | carried | — |
| `001:FR-018` | FR-088 | carried | — |
| `001:FR-019` | FR-020 | carried | — |
| `001:FR-020` | FR-049 | carried | Vendor names moved from the requirement text into SC-017(a) and platform-coupling.md |
| `001:FR-021` | FR-006 | carried | — |
| `001:FR-022` | FR-010 | carried | — |
| `001:FR-023` | FR-007 | carried | — |
| `001:FR-024` | FR-008 | carried | — |
| `001:FR-025` | FR-009 | carried | — |
| `001:FR-026` | FR-021 — retired by RD-04 | retired-by-retarget | The id resolves and keeps its tombstone; the obligation is carried to a future feature |
| `001:FR-027` | FR-003 — retired by RD-04 | retired-by-retarget | The id resolves and keeps its tombstone. Its dual-stack underlay half is **not** lost: it is salvaged into FR-011 |
| `001:FR-028` | FR-005 — retired by RD-04 | retired-by-retarget | The id resolves and keeps its tombstone; the obligation is carried to a future feature |
| `001:FR-029` | FR-022 — retired by RD-04 | retired-by-retarget | The id resolves and keeps its tombstone; the obligation is carried to a future feature |
| `001:FR-030` | FR-023 — retired by RD-04 | retired-by-retarget | The id resolves and keeps its tombstone; the obligation is carried to a future feature |
| `001:FR-031` | FR-089 | carried | — |
| `001:FR-032` | FR-094 | carried | The visualization boundary inverted under the retarget and was re-scoped to a reference-artifact boundary — spec.md §Retarget decisions 6 (RD-07) |
| `001:FR-033` | FR-096 | carried | — |
| `001:NFR-001` | NFR-001 | carried | — |
| `001:NFR-002` | NFR-002 | carried | — |
| `001:NFR-003` | NFR-003 | carried | — |
| `001:NFR-004` | NFR-004 | carried | — |
| `001:NFR-005` | NFR-005 | carried | — |
| `001:SC-001` | SC-001 | carried | — |
| `001:SC-002` | SC-004 | carried | — |
| `001:SC-003` | SC-005 | carried | — |
| `001:SC-004` | SC-016 | carried | — |
| `001:SC-005` | SC-006 | carried | — |
| `001:SC-006` | SC-007 | carried | — |
| `001:SC-007` | SC-008 | carried | — |
| `001:SC-008` | SC-034 | carried | — |
| `001:SC-009` | SC-035 | carried | — |
| `001:SC-010` | SC-017 | carried | — |
| `001:SC-011` | SC-002 | carried | — |
| `001:SC-012` | SC-003 | carried | — |
| `001:SC-013` | SC-009 — retired by RD-04 | retired-by-retarget | The id resolves and keeps its tombstone; the criterion is carried to a future feature |
| `001:SC-014` | SC-010 — retired by RD-04 | retired-by-retarget | The id resolves and keeps its tombstone; the criterion is carried to a future feature |
| `001:SC-015` | SC-036 | carried | — |
| `001:SC-016` | SC-037 | carried | — |
| `001:US1` | US9 | merged | Becomes the brownfield story once the vocabulary closes; merged into US9 with its unsupported-feature scenario kept |
| `001:US2` | US2 | carried | — |
| `001:US3` | US1 | carried | — |
| `001:US4` | US11 | carried | — |
| `001:US5` | US3 — retired by RD-04 | retired-by-retarget | The story keeps its number and a tombstone in [spec.md](./spec.md); it is carried to a future feature |
| `001:D-01` | D-04 | carried | — |
| `001:D-02` | D-05 | carried | Its rejection of an agent device session is the origin of the safety boundary (FR-075) |
| `001:D-03` | D-06 | carried | Its stated material integration gap inverted under the retarget, and the upstream provider proved unusable — spec.md §Retarget decisions 1 and 2 (RD-02, RD-03) |
| `001:D-04` | D-18 | carried | — |
| `001:D-05` | D-17 | carried | Catalogue re-expressed in construct terms; retired names labelled as migration aliases |
| `001:D-06` | D-01 | carried | — |
| `001:D-07` | D-08 — retired by RD-04 | retired-by-retarget | The decision keeps its heading and a tombstone in [research.md](./research.md) |
| `001:D-08` | D-36 | carried | — |
| `001:D-09` | D-02 | carried | — |
| `001:D-10` | D-07 | carried | — |
| `001:plan risk 1` | R-01 | carried | — |
| `001:plan risk 2` | R-02 | carried | — |
| `001:plan risk 3` | R-03 | carried | Rewritten by RD-01: there is no fast/conformance profile split on this platform, so the risk is a property the one emulated type does not model (`AD-59`) |
| `001:plan risk 4` | R-04 — retired by RD-04 | retired-by-retarget | Retired with the scope it guarded; the risk was realised, not avoided |
| `001:plan risk 5` | R-05 | carried | — |
| `001:plan risk 6` | R-06 | carried | — |
| `001:plan risk 7` | R-07 | carried | — |
| `001:plan risk 8` | R-08 | carried | — |
| `001:plan risk 9` | R-09 | carried | — |
| `001:plan risk 10` | R-10 | carried | — |
| `001:plan risk 11` | R-11 | carried | — |
| `001:plan risk 12` | R-12 | carried | — |
| `001:plan risk 13` | R-13 | carried | — |

### 002 — AGNTCY Intent Tier (M2)

| Source | Composite | Disposition | Note |
| --- | --- | --- | --- |
| `002:FR-001` | FR-050 | carried | — |
| `002:FR-002` | FR-051 | carried | — |
| `002:FR-003` | FR-052 | carried | — |
| `002:FR-004` | FR-053 | carried | — |
| `002:FR-005` | FR-054 | carried | — |
| `002:FR-006` | FR-055 | carried | — |
| `002:FR-007` | FR-056 | carried | — |
| `002:FR-008` | FR-057 | carried | — |
| `002:FR-009` | FR-058 | carried | — |
| `002:FR-010` | FR-059 | carried | — |
| `002:FR-011` | FR-060 | merged | Merged with `003:D-01` / gate C1 — the one-translator rule, stated once |
| `002:FR-012` | FR-061 | carried | — |
| `002:FR-013` | FR-062 | merged | Merged with 003's claim profiles — one allocation-authority requirement |
| `002:FR-014` | FR-063 | carried | — |
| `002:FR-015` | FR-064 | carried | — |
| `002:FR-016` | FR-075 | merged | Merged with `002:FR-029` — the absolute constraint and the identity that enforces it, stated once |
| `002:FR-017` | FR-065 | carried | — |
| `002:FR-018` | FR-066 | carried | — |
| `002:FR-019` | FR-067 | carried | — |
| `002:FR-020` | FR-068 | carried | — |
| `002:FR-021` | FR-069 | carried | — |
| `002:FR-022` | FR-070 | carried | — |
| `002:FR-023` | FR-071 | carried | — |
| `002:FR-024` | FR-072 | carried | — |
| `002:FR-025` | FR-073 | carried | — |
| `002:FR-026` | FR-074 | carried | — |
| `002:FR-027` | FR-076 | carried | — |
| `002:FR-028` | FR-077 | carried | — |
| `002:FR-029` | FR-075 | merged | **Merged into FR-075**, not dropped. A reader holding this id finds the structural half of the no-device-session rule there |
| `002:FR-030` | FR-078 | carried | — |
| `002:FR-031` | FR-079 | carried | — |
| `002:FR-032` | FR-080 | carried | — |
| `002:FR-033` | FR-081 | carried | — |
| `002:FR-034` | FR-082 | carried | — |
| `002:FR-035` | FR-090 | carried | — |
| `002:FR-036` | FR-091 | carried | — |
| `002:FR-037` | FR-092 | carried | — |
| `002:FR-038` | FR-093 | carried | — |
| `002:FR-039` | FR-095 | carried | — |
| `002:NFR-001` | NFR-006 | carried | Removability survives the merge as a system property, not a document artefact |
| `002:NFR-002` | NFR-007 | carried | — |
| `002:NFR-003` | NFR-008 | carried | — |
| `002:NFR-004` | NFR-009 | carried | — |
| `002:NFR-005` | NFR-010 | carried | — |
| `002:NFR-006` | NFR-011 | carried | — |
| `002:NFR-007` | NFR-012 | carried | — |
| `002:SC-001` | SC-019 | carried | — |
| `002:SC-002` | SC-020 | carried | — |
| `002:SC-003` | SC-027 | carried | Its acceptance record is disputed — see spec.md §Inherited acceptance record |
| `002:SC-004` | SC-028 | carried | Its acceptance record is disputed — see spec.md §Inherited acceptance record |
| `002:SC-005` | SC-029 | carried | — |
| `002:SC-006` | SC-030 | carried | — |
| `002:SC-007` | SC-021 | carried | — |
| `002:SC-008` | SC-023 | carried | — |
| `002:SC-009` | SC-038 | carried | — |
| `002:SC-010` | SC-039 | carried | — |
| `002:SC-011` | SC-032 | carried | — |
| `002:SC-012` | SC-024 | carried | — |
| `002:SC-013` | SC-025 | carried | Its acceptance record is disputed — see spec.md §Inherited acceptance record |
| `002:SC-014` | SC-026 | carried | — |
| `002:SC-015` | SC-022 | carried | — |
| `002:SC-016` | SC-031 | carried | — |
| `002:US1` | US4 | merged | — |
| `002:US2` | US6 | carried | — |
| `002:US3` | US7 | carried | — |
| `002:US4` | US10 | carried | — |
| `002:US5` | US12 | carried | — |
| `002:D-01` | D-20 | carried | — |
| `002:D-02` | D-27 | carried | — |
| `002:D-03` | D-34 | carried | — |
| `002:D-04` | D-30 | carried | — |
| `002:D-05` | D-21 | carried | — |
| `002:D-06` | D-28 | carried | — |
| `002:D-07` | D-29 | carried | — |
| `002:D-08` | D-37 | carried | — |
| `002:D-09` | D-31 | carried | — |
| `002:D-10` | D-32 | carried | — |
| `002:D-11` | D-22 | carried | **Superseded in part**: the `id.kuid.dev` claim target is replaced by the served `*.be.kuid.dev` groups |
| `002:D-12` | D-33 | carried | — |
| `002:D-13` | D-35 | carried | — |
| `002:D-14` | D-23 | carried | — |
| `002:D-15` | D-03 | carried | — |
| `002:D-16` | D-24 | carried | — |
| `002:plan R-01` | R-14 | carried | — |
| `002:plan R-02` | R-15 | carried | — |
| `002:plan R-03` | R-16 | carried | — |
| `002:plan R-04` | R-17 | carried | — |
| `002:plan R-05` | R-18 | carried | — |
| `002:plan R-06` | R-19 | carried | — |
| `002:plan R-07` | R-20 | carried | — |
| `002:plan R-08` | R-21 | carried | — |
| `002:plan R-09` | R-22 | carried | — |
| `002:plan R-10` | R-23 | carried | — |
| `002:plan R-11` | R-24 | carried | — |

### 003 — Datacenter Service Constructs (M3)

| Source | Composite | Disposition | Note |
| --- | --- | --- | --- |
| `003:FR-001` | FR-024 | carried | — |
| `003:FR-002` | FR-025 | carried | — |
| `003:FR-003` | FR-026 | carried | — |
| `003:FR-003a` | FR-027 | carried | Lettered id folded into the flat sequence |
| `003:FR-004` | FR-028 | carried | — |
| `003:FR-005` | FR-029 | carried | — |
| `003:FR-006` | FR-030 | carried | — |
| `003:FR-007` | FR-031 | carried | — |
| `003:FR-008` | FR-032 | carried | — |
| `003:FR-009` | FR-033 | carried | — |
| `003:FR-010` | FR-034 | carried | — |
| `003:FR-011` | FR-035 | carried | — |
| `003:FR-012` | FR-036 | carried | — |
| `003:FR-012a` | FR-037 | carried | Lettered id folded into the flat sequence |
| `003:FR-013` | FR-038 | carried | — |
| `003:FR-014` | FR-039 | carried | — |
| `003:FR-015` | FR-040 | carried | — |
| `003:FR-016` | FR-041 | carried | — |
| `003:FR-017` | FR-042 | carried | Its acceptance record is disputed and its implemented check is open — see spec.md §Inherited acceptance record and research.md D-16 |
| `003:FR-018` | FR-043 | carried | — |
| `003:FR-019` | FR-044 | merged | Merged with `001:FR-010` into the migration alias catalogue |
| `003:FR-020` | FR-046 | carried | — |
| `003:FR-021` | FR-047 | carried | — |
| `003:FR-022` | FR-083 | carried | — |
| `003:FR-023` | FR-084 | carried | Supersedes `002:contracts/supervisor-http.md` §`GET /suggested-prompts`; only the construct form is carried |
| `003:FR-024` | FR-085 | carried | — |
| `003:SC-001` | SC-011 | carried | — |
| `003:SC-002` | SC-012 | carried | — |
| `003:SC-003` | SC-014 | carried | — |
| `003:SC-004` | SC-015 | carried | — |
| `003:SC-005` | SC-033 | carried | — |
| `003:SC-006` | SC-018 | carried | — |
| `003:SC-007` | SC-013 | carried | — |
| `003:US1` | US4 | merged | — |
| `003:US2` | US5 | carried | — |
| `003:US3` | US8 | carried | — |
| `003:US4` | US9 | merged | — |
| `003:US5` | US13 | carried | — |
| `003:D-01` | FR-060 | merged | Resolves twice: as the decision D-10, and as the one-translator clause merged into FR-060 |
| `003:D-01` | D-10 | carried | Resolves twice: as the decision D-10, and as the one-translator clause merged into FR-060 |
| `003:D-02` | D-12 — retired by RD-02 | retired-by-retarget | The decision keeps its heading and a tombstone in [research.md](./research.md) |
| `003:D-03` | D-11 | carried | — |
| `003:D-04` | D-16 | carried | Carried; the reconciliation's finding against its implemented check is added, not absorbed |
| `003:D-05` | D-13 | carried | — |
| `003:D-06` | D-14 | carried | — |
| `003:D-07` | D-25 | carried | — |
| `003:D-08` | FR-017 | merged | Resolves twice: as the decision D-09, and as the register clause merged into FR-017 |
| `003:D-08` | D-09 | carried | Resolves twice: as the decision D-09, and as the register clause merged into FR-017 |
| `003:D-09` | D-19 | carried | — |
| `003:D-10` | D-15 | carried | — |
| `003:D-11` | D-26 | carried | Supersedes `002:contracts/normalized-service-intent.schema.json:36` `endpoints.minItems: 2` |
| `003:plan R-01` | R-25 — retired by RD-02 | retired-by-retarget | The failure mode does not exist on this platform |
| `003:plan gate C1` | FR-060 | merged | — |
| `003:plan R-02` | R-26 | carried | — |
| `003:plan gate C2` | FR-075 | merged | — |
| `003:plan R-03` | R-27 | carried | — |
| `003:plan R-04` | R-28 | carried | — |
| `003:plan R-05` | R-29 | carried | — |
| `003:plan R-06` | R-30 | carried | — |
| `003:contracts/kuid-claim-profiles.md` | FR-062 | merged | — |

## Supersessions applied

`specs/README.md` §Supersedes records five claims of 002 that 003 replaced. The composite carries
**only the superseding form** in every case. The retarget added no supersession of its own — a
supersession is one source replacing another's claim, and the retarget has no source to replace; it
changes composite text, which the forward table records as `retargeted`. Two of the five rows below
moved content in the retarget without changing which form is carried, and those moves are noted in
the table.

| Superseded claim | Superseded by | Where the superseding form lives in this composite | Evidence cited by the registry |
| --- | --- | --- | --- |
| `002:contracts/supervisor-http.md:88-91` — `GET /suggested-prompts` serving the four service-provider service names | `003:FR-023`, `003:FR-001` | FR-084; `contracts/supervisor-http.md` §`GET /suggested-prompts` | Served prompts moved to the constructs in `d14f3e1b`, `12144252` (2026-09-06); `003/spec.md:249` forbids advertising the retired names |
| `002:contracts/normalized-service-intent.schema.json:11` — a `type` enum of four service-provider names, described as "not extensible" | `003:D-01` | `contracts/normalized-service-intent.schema.json` `type` enum is the four constructs; the retired names are input aliases folded before the schema is reached. **Retarget (RD-06)**: the enum is unchanged, and two of its four values are now asserted in CI to match the device's own instance-type names (FR-099) | `agents/common/schemas/interpretation.py:25-35` is the construct set with the legacy names folded; `003/contracts/construct-vocabulary.md` |
| `002:contracts/normalized-service-intent.schema.json:36` — `endpoints.minItems: 2` | `003:D-11` | `contracts/normalized-service-intent.schema.json` `minItems: 1`, with the per-construct minimum in validation; D-26 | `003/research.md` Decision 11 sets `vlan`, `ip-vrf` and `acl` at one endpoint |
| `002:research.md:231-235` — claims against `id.kuid.dev` | `003:contracts/kuid-claim-profiles.md` | D-22; `contracts/kuid-claim-profiles.md`; the RBAC rule in `contracts/kubernetes-objects.md` targets the served `*.be.kuid.dev` claim groups. **Retarget (RD-09)**: the served groups are unchanged; the claim *set* narrows to the VLAN and VNI indices and the route-target index is removed | `003/contracts/kuid-claim-profiles.md`; the code targets the served `*.be.kuid.dev` groups |
| `002` runbook vocabulary (`docs/INTENT_TIER_RUNBOOK.md:3`) | `003` | NFR-011 and `quickstart.md` §Diagnosing a failure use construct vocabulary throughout | Runbook rewritten to the constructs |

001 has no superseded claims recorded. Its intent-tier exclusion was not superseded; it was
**answered** by 002, which took the excluded scope as M2, and it is dissolved by this composite —
see [spec.md](./spec.md) §Provenance.

## Retarget dispositions

The merge's arithmetic answered one question: did anything vanish between the sources and the
composite? The retarget raises a second: what did the platform change do to each identifier that
survived? Both answers belong here, and the second is not allowed to hide inside the first.

Every composite identifier has exactly one retarget disposition.

| Disposition | FR | NFR | SC | CR | US | D | R |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **Carried unchanged** — the retarget did not touch the text | 55 | 10 | 28 | 3 | 12 | 19 | 18 |
| **Retargeted / revised / rewritten** — the identifier stands, its text is new | 36 | 2 | 9 | 3 | 0 | 16 | 9 |
| **Retired** — number and source mapping kept, tombstoned, carried to a future feature | 5 | 0 | 2 | 0 | 1 | 2 | 3 |
| *Subtotal — identifiers that existed before the retarget* | **96** | **12** | **39** | **6** | **13** | **37** | **30** |
| **New (retarget)** — no source line; from an RD decision or a recorded gap | 5 | 1 | 2 | 1 | 0 | 15 | 7 |
| **Total after the retarget** | **101** | **13** | **41** | **7** | **13** | **52** | **37** |

Notes on the columns that are easy to misread:

- **FR totals are of identifiers, not of live requirements.** 101 numbers exist; 5 of them
  (FR-003, FR-005, FR-021, FR-022, FR-023) are tombstones, so **96 functional requirements are
  live**. The same distinction applies to SC: 41 numbers, 2 tombstones, **39 live criteria**.
- **The nine "rewritten" risks** are R-01, R-02, R-05, R-08, R-11, R-12, R-28, R-29 and R-26.
  R-26 is a special case and is counted here: it is **closed by construction** rather than merely
  reworded, and its row is kept so the lesson and the platform's new stock-object hazard are not
  lost with it.
- **The 12 carried user stories** keep their statements and their priorities. Several had
  acceptance scenarios restated where a scenario named a device object, a node count or an
  interface name; that is a change of example, not of journey, and it is recorded in
  [spec.md](./spec.md) rather than counted as a retarget of the story.
- **D counts 15 new records**, which are RD-01 to RD-15 — the retarget decisions themselves. They
  are decisions in the same register as D-01 to D-37, numbered separately so that a reader can tell
  at a glance which pass made a call.

## Nothing dropped, and nothing quietly retired

Two claims are made here, and they are different claims.

**The merge dropped nothing.** No source functional requirement, non-functional requirement,
success criterion, user story, research decision or risk was dropped by the consolidation. The
`dropped-with-reason` disposition is defined above and is used nowhere: every row of the reverse
table resolves to `carried`, `merged` or `retired-by-retarget`.

**The retarget retired eight identifiers, and retiring is not dropping — but it is not nothing
either, so they are listed rather than summarised.** Each keeps its number, keeps its source
mapping, carries a one-line tombstone in [spec.md](./spec.md), and is carried to a future feature
(working title *SRv6 services*, not created by this specification). A reader holding any source id
below still lands somewhere that tells them what happened.

| Retired composite id | Source it still resolves | Retired by | Where the obligation went |
| --- | --- | --- | --- |
| US3 | `001:US5` | RD-04 | Future feature. The story is unsatisfiable on any pinnable SR Linux profile |
| FR-003 | `001:FR-027` | RD-04 | Future feature — **except** its dual-stack underlay half, which is salvaged into FR-011 and is live |
| FR-005 | `001:FR-028` | RD-04 | Future feature. The general capability-gate obligation is unaffected and lives in FR-004 |
| FR-021 | `001:FR-026` | RD-04 | Future feature |
| FR-022 | `001:FR-029` | RD-04 | Future feature |
| FR-023 | `001:FR-030` | RD-04 | Future feature |
| SC-009 | `001:SC-013` | RD-04 | Future feature |
| SC-010 | `001:SC-014` | RD-04 | Future feature |

Four further records are retired without a tombstone in the requirement text, because they are
not requirements: decisions **D-08** (RD-04) and **D-12** (RD-02), which keep a tombstone heading in
[research.md](./research.md); and risks **R-04** (RD-04) and **R-25** (RD-02) — not R-03, which RD-01 rewrote and the plan carries live (`AD-59`) —
which keep their rows in this file and in the plan. R-04 deserves its reason stated plainly: it is
retired because the risk it named was **realised**, not because it went away — no licence-free
container type has an SRv6 data plane, which is precisely why the scope is deferred.

Two classes of source **prose** are deliberately not carried forward as live constraints, and
neither is a requirement:

| Source prose | Why it is not carried | Where its existence is recorded |
| --- | --- | --- |
| `001/spec.md:19-24` §"Non-goals — the multi-agent intent tier" | It describes the M1/M2 boundary this composite dissolves. Carrying it forward would contradict the document it sits in | [spec.md](./spec.md) §Provenance |
| `002/spec.md` §"Relationship to feature 001" and §"What this feature is not" | Same boundary, stated from the other side. Its substantive content — the dependency direction and the removability property — is carried as NFR-006 and NFR-007 and measured by SC-025 | [spec.md](./spec.md) §Provenance |

A third class is added by the retarget: **the SONiC-specific design of all three sources.** None of
it is carried as a live constraint, and none of it is dropped without a record either — every
binding is inventoried, given a disposition and resolved row by row in
[platform-coupling.md](./platform-coupling.md), which is the resolution record for exactly that
question.

## Counts

**Sources to composite** (the merge's arithmetic, unchanged by the retarget):

| | 001 | 002 | 003 | Source total | Composite after the merge |
| --- | ---: | ---: | ---: | ---: | ---: |
| Functional requirements | 33 | 39 | 26 (24 numbers, 2 lettered) | 98 | **96** |
| Non-functional requirements | 5 | 7 | 0 | 12 | **12** |
| Success criteria | 16 | 16 | 7 | 39 | **39** |
| User stories | 5 | 5 | 5 | 15 | **13** |
| Research decisions | 10 | 16 | 11 | 37 | **37** |
| Risks | 13 | 11 | 6 | 30 | **30** |

The functional-requirement count falls by two and the user-story count by two, for four merges in
total: `001:FR-010`+`003:FR-019` → FR-044; `002:FR-016`+`002:FR-029` → FR-075;
`002:US1`+`003:US1` → US4; `001:US1`+`003:US4` → US9. Every other merge marked in the forward
table folds a *decision* or a *contract clause* into a requirement, which changes no count. The
constitution-mandated requirements (CR-001 to CR-006 at the merge) are not in this table because
they have no source specification; they are derived from the constitution.

**Composite before and after the retarget:**

| | After the merge | Retired | Added | Identifiers now | **Live now** |
| --- | ---: | ---: | ---: | ---: | ---: |
| Functional requirements | 96 | 5 | 5 | 101 | **96** |
| Non-functional requirements | 12 | 0 | 1 | 13 | **13** |
| Success criteria | 39 | 2 | 2 | 41 | **39** |
| Constitution-mandated requirements | 6 | 0 | 1 | 7 | **7** |
| User stories | 13 | 1 | 0 | 13 | **12** |
| Research decisions | 37 | 2 | 15 (RD-01…RD-15) | 52 | **50** |
| Risks | 30 | 3 | 7 (R-31…R-37) | 37 | **34** |

The two columns say different things and both are needed. **Identifiers now** is what the numbering
reaches, and it never goes down, because nothing is renumbered and a retired number is never reused.
**Live now** is what a reader must satisfy. The functional-requirement count returning to 96 is an
arithmetic coincidence — five retired, five added, different five — not a sign that nothing changed;
36 of the 91 surviving requirements were rewritten.

**Plan refresh, 2026-09-20.** The tables above record the merge and the retarget and are not
restated. The refresh added six decisions (`CD-01`…`CD-06`, research §12) and five risks (`R-38`…
`R-42`), retired none and renumbered none: research decisions reach 58 identifiers with 56 live, and
risks reach 42 identifiers with 39 live. It also added one component (`C-22`) and one delivery phase
(`P12`), both for the closing README and walkthrough.

**Analysis remediation, 2026-09-20.** The cross-artifact analysis added three functional
requirements (FR-106 to FR-108), one success criterion (SC-044), one constitution-mandated
requirement (CR-008), eight decisions (`AD-01`…`AD-08`, research §13) and one risk (`R-43`); it
retired none and renumbered none. Functional requirements reach 108 identifiers with 103 live,
success criteria 44 with 42 live, constitution-mandated requirements 8, research decisions 66 with
64 live, and risks 43 with 40 live. FR-007, FR-075, NFR-003 and CR-002 were reworded in place; what
changed in each is in [spec.md](./spec.md) §Analysis remediation.

**Analysis remediation, second pass, 2026-09-20.** A re-run of the analysis added one functional
requirement (FR-109), one non-functional requirement (NFR-014), one success criterion (SC-045),
seven decisions (`AD-09`…`AD-15`, research §13 — two of them operator decisions) and one risk
(`R-44`); it retired none and renumbered none. Functional requirements reach 109 identifiers with
104 live, non-functional requirements 14, success criteria 45 with 43 live, constitution-mandated
requirements 8, research decisions 73 with 71 live, and risks 44 with 41 live. FR-013, FR-015,
FR-104, NFR-003, SC-008, CR-005 and CR-006 were reworded in place; what changed in each is in
[spec.md](./spec.md) §Analysis remediation, second pass.

**Analysis remediation, third pass, 2026-09-20.** A third run added one success criterion (SC-046),
seven decisions (`AD-16`…`AD-22`, research §13 — two of them design choices recorded with their
alternatives) and one risk (`R-45`); it added no requirement, retired none and renumbered none.
Functional requirements stay at 109 identifiers with 104 live, non-functional requirements 14,
success criteria reach 46 with 44 live, constitution-mandated requirements 8, research decisions 80
with 78 live, and risks 45 with 42 live. FR-015, FR-030, FR-034, FR-062, FR-078, FR-109, NFR-003,
SC-028 and SC-029 were reworded in place, and the *Fabric service resource* entity was merged into
*Network*; what changed in each is in [spec.md](./spec.md) §Analysis remediation, third pass.

**Analysis remediation, fourth pass, 2026-09-20.** A fourth run added eight decisions
(`AD-23`…`AD-30`, research §13 — three of them design choices recorded with their alternatives), two
risks (`R-46`, `R-47`) and one task (T174); it added no requirement and no success criterion, retired
none and renumbered none. Functional requirements stay at 109 identifiers with 104 live,
non-functional requirements 14, success criteria 46 with 44 live, constitution-mandated requirements
8; research decisions reach 88 with 86 live, and risks 47 with 44 live. User Story 1, User Story 7,
FR-020, FR-048, FR-062, FR-078, FR-096, FR-100, FR-102, FR-107, FR-109, NFR-004, NFR-006 and SC-004
were reworded in place, and the *Audit event* entity with FR-078; what changed in each is in
[spec.md](./spec.md) §Analysis remediation, fourth pass.

**Operator review, 2026-09-20 — clarify-delta closures (`AD-39`).** The review of
`checklists/clarify-delta.md` closed the items that needed no design decision and added **four**
success criteria, `SC-047` to `SC-050`, for the four delta requirements that had none — FR-104,
FR-106, FR-108 and NFR-014. No requirement, task, risk or research decision other than `AD-39` was
added, none was retired and none renumbered. Success criteria reach 50 with 48 live. FR-102 to
FR-109, NFR-014, SC-030, SC-042, SC-043, FR-086 and §Scope and interpretation were extended in
place; what changed in each is in [research.md](./research.md) §13 `AD-39`.

**Operator review, 2026-09-20 — the decisions (`AD-31`…`AD-38`), and the totals after it.** The five
design choices the analysis passes had made without the operator were researched
([review/2026-09-20/](./review/2026-09-20/)) and decided by the operator: `AD-23` and `AD-16` ratified
with amendments (`AD-31`, `AD-32`); `AD-27`'s refusal replaced by disjoint VLAN bands (`AD-33`);
`AD-17` kept with its rationale corrected and gate item G13 added (`AD-34`); `AD-26`'s default
reversed — the tier's removal refuses unless `--remove-services` (`AD-35`); `AD-24`'s export
specified (`AD-36`); and the two halves of the requirements-checklist triage closed (`AD-37`,
`AD-38`). With `AD-39` above, the review added nine decisions, four success criteria, one gate item
(G13, thirteen in all), one risk (`R-48`) and one task (T175); it retired none and renumbered none.
Functional requirements stay at 109 identifiers with 104 live, non-functional requirements 14,
success criteria reach 50 with 48 live, constitution-mandated requirements 8; research decisions
reach 97 with 95 live, risks 48 with 45 live, and tasks 175.

**Fifth analysis pass, 2026-09-21 (`AD-40`…`AD-50`).** One constitution conflict and twelve high
findings were closed: four by operator decision (`AD-40`…`AD-43`), two by a recorded, reversible
choice (`AD-44`, `AD-45`) and the rest as closures (`AD-46`…`AD-50`). The pass added eleven
decisions, two constitution-mandated requirements (`CR-009`, `CR-010`) and one open item (18, the
G13 observation); it added no functional or non-functional requirement, success criterion, risk,
gate item or task, retired none and renumbered none. Functional requirements stay at 109 identifiers
with 104 live, non-functional requirements 14, success criteria 50 with 48 live;
constitution-mandated requirements reach 10; research decisions reach 108 with 106 live; risks stay
at 48 with **46** live, gate items at thirteen and tasks at 175. *(Corrected by the sixth analysis pass
of 2026-09-21, `AD-59`: every dated paragraph above counts R-03 as retired and is one low from the
retarget onward — 35, 40, 41, 42, 43, 45 and 46 live where they say 34, 39, 40, 41, 42, 44 and 45.
The plan's risk table tombstones two rows, R-04 and R-25; R-03 was rewritten by RD-01 and has been
a live row there throughout. The older paragraphs are left as they were written.)*

**Sixth analysis pass, 2026-09-21 (`AD-51`…`AD-60`).** No constitution conflict; six high findings,
second-order effects of the fifth pass, were closed: three by operator decision (`AD-51`…`AD-53`) and
the rest as closures (`AD-54`…`AD-60`). The pass added ten decisions and one reason code (`Deleting`,
on `Ready`); it added no requirement, success criterion, risk, gate item, open item or task, retired
none and renumbered none. Functional requirements stay at 109 identifiers with 104 live,
non-functional requirements 14, success criteria 50 with 48 live, constitution-mandated requirements
10; research decisions reach 118 with 116 live; risks stay at 48 with 46 live, gate items at thirteen,
open items at 18 and tasks at 175.

**Seventh analysis pass, 2026-09-21 (`AD-61`…`AD-67`).** No constitution conflict and one high
finding, closed by `AD-61`; `AD-63` is a recorded, reversible choice and the rest are closures. The
pass added seven decisions and no requirement, success criterion, risk, gate item, open item or task;
it retired none and renumbered none. Functional requirements stay at 109 identifiers with 104 live,
non-functional requirements 14, success criteria 50 with 48 live, constitution-mandated requirements
10; research decisions reach 125 with 123 live; risks stay at 48 with 46 live, gate items at thirteen,
open items at 18 and tasks at 175.

**Eighth analysis pass, 2026-09-21 (`AD-68`…`AD-73`), bounded.** The gate was green and no
constitution conflict was found; three high findings were closed — `AD-68` by operator decision,
`AD-69` and `AD-70` as closures — and then the pass's seven medium findings, in `AD-71`, one point of
which is a recorded choice, and its low findings in `AD-72`; `AD-73` records the operator's ratification of the five choices the passes had made themselves, so none remains unratified. The pass added six decisions and two open items, and no
requirement, success criterion, risk, gate item or task; it retired none and renumbered none (T047
moved after T052 and kept its id). Functional requirements stay at 109 identifiers with 104 live,
non-functional requirements 14, success criteria 50 with 48 live, constitution-mandated requirements
10; research decisions reach 131 with 129 live; risks stay at 48 with 46 live, gate items at thirteen,
open items reach 20 and tasks at 175.

**After the eighth analysis pass, 2026-09-21 — the first implementation run and `AD-74`.** The run
approved task phases 1 and 2 and stopped in phase 3 on gate item G11, as FR-104 requires; the
first-party allocation authority was adopted by recorded decision (`AD-74`,
`docs/decisions/allocator-substitution.md`). That added one decision and eight tasks (T176–T183, in
User Story 1 before T048) and closed open item 10 by observation; it added no requirement, success
criterion, risk or gate item, retired none and renumbered none. Functional requirements stay at 109
identifiers with 104 live, non-functional requirements 14, success criteria 50 with 48 live,
constitution-mandated requirements 10; research decisions reach 132 with 130 live; risks stay at 48
with 46 live, gate items at thirteen, open items stay at 20 and tasks at 183.

**After the eighth analysis pass, 2026-09-21 — the first live gate and `AD-75`…`AD-82`.** The second
implementation run passed G11 on the first-party authority, brought the lab up and ran the gate, which
contradicted seven assumptions of these artefacts; each was decided under the operator's delegation in
favour of the requirement's intent, no gate waived (`AD-75`…`AD-81`), and `AD-82` records the standing
delegation for later findings. That added eight decisions, five tasks (T184–T187 in User Story 1, T188
before T155) and two open items; it added no requirement, success criterion, risk or gate item, retired
none and renumbered none. Functional requirements stay at 109 identifiers with 104 live, non-functional
requirements 14, success criteria 50 with 48 live, constitution-mandated requirements 10; research
decisions reach 140 with 138 live; risks stay at 48 with 46 live, gate items at thirteen, open items
reach 22 and tasks at 188.

### Self-check

The forward table's completeness claim is mechanical, not asserted. Every `FR-`, `NFR-` and `SC-`
identifier defined in [spec.md](./spec.md) appears exactly once in the forward table, and every
`FR-`, `NFR-` and `SC-` identifier in the forward table is defined in [spec.md](./spec.md) — 109 +
14 + 50 = 173 identifiers, in both directions, with no orphan in either (the retarget's 101 + 13 +
41 = 155, plus FR-102 to FR-105, SC-042 and SC-043 added by the clarification session of
2026-09-20, plus FR-106 to FR-108 and SC-044 added by the analysis remediation of the same day, plus FR-109,
NFR-014 and SC-045 added by its second pass, plus SC-046 added by its third, plus SC-047 to SC-050
added by the operator review of 2026-09-20 (`AD-39`); the
totals tables above record the merge and the retarget and are not restated). The same holds for the
ten CR identifiers (CR-009 and CR-010 added by the fifth analysis pass of 2026-09-21, `AD-50`). Re-run it by extracting the `- **ID**:` bullets from `spec.md` and the
leading cell of each forward-table row and comparing the two sets.

## Obligations index

**Date: 2026-09-21.** This section reflects the text of FR-015, FR-078, FR-107, FR-108, FR-109 and
NFR-003 **as of the seventh analysis pass of 2026-09-21**, which re-read every row against its
requirement in both directions (`AD-65`); a later edit to any of them is not carried here
automatically, and the requirement text always wins over this index. Its history: written at the
operator review of 2026-09-20 for FR-015, FR-078, FR-109 and NFR-003; FR-107 added by the fifth
analysis pass of 2026-09-21 (`AD-40`, `AD-49`), which also reworded FR-078's rows (e) and (g) and
added (h) (`AD-46`); FR-109's rows (l) to (n) and the `AD-53`/`AD-54` wording of FR-107's rows (c)
and (g) added by the sixth; FR-108 added, and FR-015(h) and the two missing clauses of FR-109(i)
written in, by the seventh (`AD-65`).

Four requirements — and, since the fifth pass, FR-107, and since the seventh, FR-108 — carry several separable obligations under one number. Each is testable, but none
is testable as a single assertion, so a task list can look complete while a clause inside one of
them has no carrier. This index enumerates those clauses and names, per clause, the task that
builds it and the check that asserts it.

**The `(a)`, `(b)` labels are index labels inside this file, not identifiers.** They are not
requirements, nothing cites them, no task is written against one, and they create no new numbering
to keep stable. The requirement is always the whole of FR-015, FR-078, FR-107, FR-108, FR-109 or NFR-003; splitting
any of them into real sub-identifiers would renumber the specification, which neither pass has done
and this index does not do either.

### FR-015 — the device-configuration layer, drift policy and priority

| Label | Obligation, as the requirement states it | Built by | Asserted by |
|---|---|---|---|
| FR-015(a) | Validate rendered configuration against the pinned device schema **before any device write** | T036 (the `Schema` CR as compatibility-set part 4, commit-pinned) | `make verify-render-schema` over every frozen golden (T063, T113); the CI job of T007 |
| FR-015(b) | Apply over gNMI **as a transaction that rolls back on rejection** | T036, T042 | Gate item **G5** — commit-confirmed rollback confined to its own transaction (T043) |
| FR-015(c) | Expose intended, running, applied and deviation state | T036, T058 | The keyed two-sided read-back of T058; the live drift suite of T064 (`test-managed-drift`) |
| FR-015(d) | Be **the only component that writes device configuration** | T042 | `make verify-boundaries` — no device client invoked outside the gate, the suites and the walkthrough tooling (FR-108); plan §Verification "Verification-tooling boundary" |
| FR-015(e) | Lab mode states an **explicit** revertive drift policy on every generated configuration resource — never left absent for the layer's own default | T042 (`DRIFT_POLICY` is the one place the policy is stated, and it lands on the resource's `revertive` field); T040 and T059 generate the resources that carry it | The generated-`Config` assertions of T028 (`Fabric`, priority 10) and T054 (`Network`, priority 20): `spec.revertive` present and `true` on every one. T036 appears only as the **negative** assertion — `make sdc-onboard` fails, naming the file, on an onboarding manifest that appears to state a drift policy, because none of the onboarding APIs has such a field (AD-34, AD-48) |
| FR-015(f) | The policy is a provider setting with **no default**, its value set closed at the exact string `revertive`, and a provider started without one — or with any other value in any spelling — refuses to start | T042 (`DRIFT_POLICY`, no default, closed set of one) | `cmd/srl-provider/driftpolicy_test.go` — **written test-first in T028**, made to pass by T042 (`AD-59`) — asserting unset, empty, `non-revertive`, `Revertive` and `true` each refused naming the variable; plan §Verification "Drift policy" |
| FR-015(g) | Configuration resources that could touch the same device leaf **MUST NOT share a priority**; the overlap is refused at validation, never ordered | T059 (priority-collision refusal at priority 20) | T054 — two `Config`s that could touch one leaf refused `OwnershipConflict`, never ordered |
| FR-015(h) | An **overruled platform-owned path is a terminal error** — never reapplied, the condition naming the path and the overruling intent ([contracts/reconciliation.md](./contracts/reconciliation.md) Rules 4 and 6) | T059 (a `Deviation` with reason `OVERRULED` on a path one of the object's `Config`s owns sets `Applied=False/OwnershipConflict` naming the path and the overruling intent, classed terminal, never answered with a reapply — `AD-66`) | T054 — a fake `Deviation{reason: OVERRULED}` on an owned path: the condition set, `Ready` not `True`, no `Config` write on that or any later reconcile; T064's `managed_drift.sh` asserts it live **only if** G13 recorded `OVERRULED` as producible on the pinned layer, and otherwise reports it "not demonstrated live; envtest-covered" (`AD-34`, `AD-66`). Row added by the seventh pass (`AD-65`) |

### FR-078 — the audit record

| Label | Obligation, as the requirement states it | Built by | Asserted by |
|---|---|---|---|
| FR-078(a) | Record **every** confirmation, decline, submission, removal, refusal and detected out-of-band change as an auditable event carrying principal, correlation identifier and resulting resource | T101 (the supervisor's audit wiring), T100 (the three the deployer decides) | T103's audit reconciliation — the stream read from the analytics store and compared with the created resources and their submitted-spec hashes (SC-030); plan §Verification "Audit record" |
| FR-078(b) | A refusal for want of a valid credential has **no principal**, never reaches the pipeline, and is counted in a metric and logged instead | T085 (`auth.py` — the decision is taken before a thread identifier is minted) and T080 (`agentic_netops_agent_auth_refusals_total` in `agents/common/metrics.py`) | T077 (`test_supervisor_http.py`, test-first: `401` with no thread, model call, claim or `AuditEvent`, the counter incremented), T089 (`test_operator_auth.py`, live) and the handler-level tests of plan §Verification "Authentication" — a refused request mints no thread identifier |
| FR-078(c) | The record is the trace-borne event **in the agent-analytics store**, kept with no expiry for as long as the store exists; a Kubernetes Event may mirror it and is never the record | T087 (the store and the agent collector, installed by T088 before any agent workload — AD-45), T136 (the second exporter), T100 (mirrors three as Events) | Plan §Verification "Audit record" — every event present in the store as a span event, and the supervisor publishing no Event and holding no permission to |
| FR-078(d) | Exported **before anything removes the store**, on both down paths, unconditionally and not only when evidence capture was asked for | T088 (`scripts/lib/audit_export.sh`), T049 (`off.sh`) | T174 against a fake store — export before delete on `off.sh` and on `off.sh --purge-intent-tier`, requested or not; T152's removability run proves the artefact exists and predates the deletion |
| FR-078(e) | The export carries the NFR-013 run-captured fields, is newline-delimited JSON one object per row, compressed, and is captured under an identifier unique to the attempt | T088, T011 (`evidence_run`) | T174 (per-attempt identifier; a re-run never rewrites an artefact — it **skips** where a *verified* export is found under the lab's evidence root and captures the skip, and **adds** one otherwise, by the one rule of `data-model.md` §16, AD-46), and the evidence audit of SC-040 |
| FR-078(f) | A failed export **stops the removal with the store intact**; the only way past is the named discard flag, whose use is printed and recorded. An export *fails* when the store is present but unqueryable within the bound, the query errors, the artefact cannot be written or fewer rows are written than the store reported; a store never installed is skipped, and one that returns no rows is a successful empty export | T088, T049 | T174 — each of the four failure cases stops the run non-zero with the store intact, an absent store is skipped and an empty one is a successful empty export, and `--discard-audit-record` goes past it with its use printed and written to evidence |
| FR-078(g) | After the export the evidence file is the record — the stream half of SC-030 and SC-042 **is reconciled from the file alone** once the store is gone — and the half of SC-030 that compares the stream against live objects runs **before** the store and those objects are removed | T103 (the reconciliation while the lab is up, and its **file-source mode**), T152 | T103 (SC-030) ordered ahead of T152's purge in the phase order; T152's closing read-back — `test_audit_reconcile.py` in file-source mode over the exported artefact and the usernames record alone, the live-object half reported as not run (AD-46) |
| FR-078(h) | The operator usernames the run used are captured with the run's evidence — username only, never the password — **before anything removes the operator credential**, so SC-042 reconciles without the store and without the Secret | T088 (the capture at the tier phase; the usernames record written by `scripts/lib/audit_export.sh`), T049 (the same function on the full teardown) | T174 — the record written before the fake Secret is deleted on both down paths, no password in it, `username_unchanged: false` when captures differ; T152's file-source run reconciles against the record and reads `username_unchanged` there, while T148 — run with the tier up, before any record exists — derives the set and its cardinality from the tier-phase captures (AD-46, AD-55) |

### FR-109 — claims, adoption and release ownership

| Label | Obligation, as the requirement states it | Built by | Asserted by |
|---|---|---|---|
| FR-109(a) | Every VNI a service intent object carries is backed by a **bound claim before any device configuration is rendered for it**, whichever way the object arrived | T171 (the claim gate in the reconciler's dependency waits, T059) | T170 (envtest, claim before any `Config`); T172 (live, with no tier installed — SC-045) |
| FR-109(b) | A bound claim carrying the object's correlation label, **bearing the deterministic name for that field and reporting that value** is adopted and nothing is created; a label match with a different value is not adopted, and neither is a label-and-value match under any other name — one three-part rule for VNI and VLAN claims (AD-42) | T171 (adopt on label, deterministic name **and** value, VNI **and** VLAN); T099 (the allocator names every claim by the provider's scheme) | T170; T173 end to end for a tier-provisioned service (SC-046) |
| FR-109(c) | Where none exists, claim **exactly that value**, under a deterministic name derived from the object and labelled with it | T171 | T170 — one claim per `l2vni`/`l3vni` for exactly the stated value, deterministically named; T172 live |
| FR-109(d) | A value held by another owner or outside the band sets `Accepted=False` naming the value and the holder or the band, with **nothing rendered** and **no other value chosen** | T171 (`AllocationConflict`) | T170; T172 — a second object naming a held L2VNI refused with zero `Config`s |
| FR-109(e) | Adopted and created claims alike are released **only by finalization**, after the removal has been read back | T060 (the finalizer releases every `status.claimRefs` entry), T171 | T055 (deletion order, claims held while a target is unreachable, no timer); T173 (claim-selector diff empty after removal by either path) |
| FR-109(f) | The identifiers a claim backs are **immutable once the object is accepted** — its VNIs and the VLAN of its `vlan` or `mac-vrf` entry — the API refusing the edit naming the field; attachments may change, but one added to an accepted object may not carry an allocation-band VLAN **the object does not already carry** (AD-47) | T014 (CEL markers), T056 (webhook rules) | Plan §Verification "Immutable identifiers" — envtest updates of an accepted `Network` (T017): a changed `l2vni`, `l3vni` or service VLAN refused naming the field, a removed attachment accepted, an added one accepted with a naming-band VLAN, none, or the allocated VLAN the object already carries, and refused with a new allocation-band VLAN, while an `accessLists`-only object — outside the rule, its VLAN a reference — gains an attachment on `1500` (AD-56); no second claim ever made for one role |
| FR-109(g) | **Adoption is decided once per value**: a claim recorded as adopted stays adopted, held and listed until finalization, whatever attachments are removed meanwhile, and is never re-evaluated or released early | T171, T060 | T170 — a `mac-vrf` whose VLAN was allocated keeps its claim `adopted` after an attachment carrying it is removed (AD-51); T055 — every entry of `status.claimRefs` is released by the finalizer, never earlier; T173 live |
| FR-109(h) | The **band decides**: a named VLAN (`100–999`) is claimed by nobody and is exclusive by FR-034; an allocation-band VLAN (`1000–4000`) must be backed by an adopted claim or the object is refused naming the VLAN and both bands; the attachment VLAN of an `accessLists`-only object is a reference and is outside the rule (AD-47). On the tier path the naming band is the **mapper's**, at interpretation (AD-41) | T171 (VLAN adoption), T014/T056 (the band rules), T098 (the mapper's naming-band refusal) | T170; T173 for the tier path; T093 for the per-construct claim profiles; T091 (the mapper half) and T106 (the `acl` reference) |
| FR-109(i) | A tier-submitted object carries the provider's finalizer **from the moment it is applied**; one applied with cluster tooling takes it at the provider's first reconcile. **Finalization resolves adoption before it releases**, so an object deleted before its first reconcile orphans nothing (AD-44) — and it **creates no claim on a deleting object**. Because admission fails closed (FR-034), **neither kind of object can be applied while the provider is down**: the one finalizer-less window is an object applied with cluster tooling and deleted before the provider's first reconcile, a deletion never being intercepted (AD-52) | T060 (adopt, then release, claiming nothing), T171 (the resolution it runs), T100 (the deployer applies it with the finalizer set), T061 (the webhook's `failurePolicy: Fail` on `CREATE` and `UPDATE`, `DELETE` not listed) | T055 and T170 (the never-reconciled object — its claims adopted and released, **none created on the deleting object**); T056 (with the webhook unreachable a create and an update are refused and a delete is accepted and blocks on its finalizer); T173 (the live variant, recorded — the provider killed *after* the apply, never before it); T092 (the deployer's submission contract) *(the two clauses written in by the seventh pass, `AD-65`)* |
| FR-109(j) | Which correlation identifiers are still provisional is determined by **the deployer**; the allocator agent deletes only the claims it is told to delete and reads no service intent object, so the verb sets of FR-075 are unchanged | T100, T101 | T092/T093; the RBAC assertions of T042 and the denial probes of the safety-boundary phase |
| FR-109(k) | That the authority binds a stated value, refuses a second, reports the value in status, allows its labels to be selected on, never allocates below its index's lower bound and frees a deleted claim's value synchronously is a **gate item**, never assumed | T044 (G11, with its early hook) | Gate item **G11** — the six observations (a)–(f) of `contracts/kuid-claim-profiles.md` §6, the one list (AD-56), including the negative control that the stated-value check fails against an index that does not contain the value |
| FR-109(l) | **An `ip-vrf` attachment's VLAN is named or absent and is never allocated** (AD-51): the tier claims no VLAN for an `ip-vrf`, and one carrying an attachment VLAN in the allocation band has no adoptable claim by construction and is refused | T099 (the allocator's profile), T098 (an endpoint naming no VLAN is untagged, not a missing field), T171 (the claim gate matches a VLAN claim against the `vlans[]` or `bridgeDomains[]` entry only) | T093 (zero `vlanclaims` for an `ip-vrf`); T091 (`accept_ipvrf_untagged_no_vlan`); T170 (`AllocationConflict` even with a label-and-value-matching claim present); T017 (an `ip-vrf` gaining an attachment on `1500` refused); T173 (zero VLAN claims, live) |
| FR-109(m) | **An allocation-authority error is not an answer** (AD-56): never read as "nothing adoptable", never reported as an allocation conflict; a dependency wait before a render, and in finalization the finalizer kept and nothing released, both retried with bounded backoff and no deadline | T171 (the error returned as a retryable wait), T060 (the finalizer's steps 1 and 6) | T170 and T055 — the `pkg/kuid` fake made to error on the lookup, the create and the DELETE |
| FR-109(n) | The service intent object's name and its `vlan`, `mac-vrf` and routed-instance entry names are bounded to 63-character labels, and the tier's service identifier to a 15-character one, **so that every claim name is a valid object name** (AD-56) | T014 (`maxLength`/`pattern` and the name rule); the `pattern` on `service_id`/`serviceId` in both JSON schemas, T098 | T017 (a 64-character `metadata.name` and entry name refused); T091 (a `service_id` outside the pattern fails the schema) |

### NFR-003 — pinning

| Label | Obligation, as the requirement states it | Built by | Asserted by |
|---|---|---|---|
| NFR-003(a) | Everything — images, charts, CRDs, API services, YANG models, schema patches, dashboard plugins, generator tools, upstream repositories — pinned to a digest-backed release tag or to a commit | T010 (`make verify-pins`) | T009's fixture lock files, each case failing the check; the CI job of T007 |
| NFR-003(b) | `latest`, a floating minor tag and a branch reference forbidden **wherever a reference can appear**, including inside the device-configuration layer's schema definition | T010, T036 (commit-pinned `Schema` refs, never a branch) | T009 — a `latest` tag, a floating minor tag and a branch ref inside the `Schema` CR's repository refs each rejected |
| NFR-003(c) | A placeholder or synthetic digest forbidden, and **every digest resolved against its registry** — no digest-shaped-string check | T010 (`resolve_pins.sh` fills unresolved fields from the registry only, never from input text) | T009 — a placeholder digest and a digest that does not resolve each rejected |
| NFR-003(d) | Intent-tier images have a **local build step** and are pinned in the same lock file as everything else | T086 (the tier image builds), T169 (the shared build) | T169's `image_build_test.sh`; `make verify-compat` (T050) checking the running workloads |
| NFR-003(e) | Exactly **one** exception is admitted — the recorded allocator substitution — warned by name at provisioning; anything else the pin check cannot hold is a failure, never a warning, and the lock file has no field in which another could be declared | T010, T048 (warns by name on every run) | T009 — `first-party` without a resolvable decision record and failed-gate evidence, and **any** other declared exception, each failing; plan §Verification "Pin exceptions" |
| NFR-003(f) | Host-side test and recording tooling is pinned like everything else and is not an exception — the package by exact version and hash, the browser by the build that version fixes, each host tool by the recorded version, compared with the host **before the suite that uses it runs** | T003 (the exact package pins), T157 (the recording tooling) | Plan §Verification "Host tooling" — a ranged package version, a differing browser revision and a missing or different capture tool each failing `make verify-pins` naming the entry; T127 runs the host-tooling check first and puts the versions in evidence |
| NFR-003(g) | A first-party image is pinned by its **build inputs** — every `FROM` by a registry-resolved locked digest, every dependency set by its lock-file hash — tagged with the content hash of its build context, never-pull, and the image each build produced recorded in that run's evidence and checked against the running workloads | T169, T042/T086 (its consumers) | T169's unit test (same tree → same tag; one changed byte → a different tag; a tag-only `FROM` refused) and T050 (`verify-compat`: a workload running anything but this run's built image fails naming it) |
| NFR-003(h) | The pin check **fails** a first-party image whose `FROM` is not a locked digest, whose dependency lock does not match its locked hash, or which any manifest references by a mutable tag | T010 | Plan §Verification "First-party images" — the four fixture Dockerfiles and the mutable-tag manifest, each failing `make verify-pins` |

### FR-107 — scheduled re-verification

*Added by the fifth analysis pass of 2026-09-21 (`AD-49`), which found three of these clauses with no
task; it reflects FR-107 as of the operator decision `AD-40`.*

| Label | Obligation, as the requirement states it | Built by | Asserted by |
|---|---|---|---|
| FR-107(a) | Re-run the two-sided read-back of FR-100 (and FR-042) for the fabric design and every service that has reported Ready, at an interval that defaults to five minutes and is configuration, not code | T040, T059 (the requeue at `REVERIFY_INTERVAL`, re-running T041 and T058 unchanged) | T028, T054 (fake clock — default asserted, override honoured, zero `Config` writes on a clean pass; and a `Fabric` reporting `Ready=False` suspends no `Network`'s re-verification — AD-55); T167 live |
| FR-107(b) | A value below the stated minimum, or one that cannot be parsed, **refuses the provider's start** rather than falling back to the default | T042 (`REVERIFY_INTERVAL` parsed at start-up; the 30 s floor of data-model.md §25) | `cmd/srl-provider/reverifyinterval_test.go` — **written test-first in T028**, made to pass by T042 (`AD-59`) — `10s`, `0`, `-5m`, `five minutes` and an empty string refused naming the variable; `30s` and unset accepted |
| FR-107(c) | An object that has never reported Ready is outside the schedule — "has reported Ready" read **at the object's current generation**, whose carriers `AD-62` names; one held in deletion stays inside it — only as the finalizer's requeue, reporting `Ready=False/Deleting` and never `Ready=Unknown` (`AD-53`) | T040, T059; T060 (the deletion requeue; `Ready=False/Deleting` as finalization's first act), T023 (the setter) | T054 (a never-Ready `Network` is not requeued by the schedule, a deleting one is; a Ready one updated to a new generation while a target is away is `Ready=False/NotConverged`, not `Unknown` — `AD-62`); T055 (`Ready=False/Deleting` at every observation of a held object, never `Unknown`); T055 (a finding clears only from a scheduled read-back) |
| FR-107(d) | A pass that finds an invariant missing sets `Ready=False` naming it, within one re-verification interval plus one reconciliation interval | T040, T059 | T028, T054 (`Ready=False/RoutesMissing` and back); T167 (SC-044's bound, live) |
| FR-107(e) | Drift the pass finds on an owned path is repaired under the selected drift policy | T040, T059 (Rule 6 on the same pass) | T064's `managed_drift.sh`, asserting what gate item G13 observed to be witnessable |
| FR-107(f) | A pass that **could not run** sets `Ready=Unknown/VerificationFailed` and `Degraded=True/VerificationFailed` naming the target, at that pass; never `Ready=False`, never a standing `Ready=True`; the last-verified time does not advance; the next pass that runs settles it. The same outcome when the reconciler sees, **between two scheduled passes**, that a required target of a Ready object is unreachable — which keeps SC-008's bound (`AD-54`); and `Ready=Unknown` is never a success to anything that reads it (FR-054, FR-067) | T023 (`Unknown` admitted on `Ready` only, with that one reason), T040, T059 | T028, T054 (unreachable fake target: neither True nor False, `lastVerifiedTime` frozen, `Ready=True` on return; and the between-passes case, within two reconciliation intervals without waiting for the schedule); T064's `target_failure.sh` (SC-008) and T167's management-network cut (SC-044), live; T092 (the tier's watch stays open on `Ready=Unknown` and a status answer says readiness is unknown) |
| FR-107(g) | The time of the last successful re-verification — *successful* meaning the pass **ran**, whatever it found (`AD-54`) — is visible in status and as a metric | T013 (`status.lastVerifiedTime`), T023 (its setter), T133 (`reverify_last_success_timestamp_seconds`, data-model.md §21) | T028, T054 (the field advances on every pass that ran — the one that found an invariant missing included — and is frozen only on a pass that could not run); T167 (advancing through the `Ready=False` window, live); T133's unit test (the series removed when finalization starts); T134 (the series is scraped) |
| FR-107(h) | A `Ready=True` older than the bound **raises an alert**, rather than only being visible | T130 (`ReverificationStalled`) | T134's `alerts_fire.sh` — fired by a management-network cut, cleared on reconnection |
| FR-107(i) | Re-verification adds **no client** of the device management server: it reads the state the device-configuration layer already exposes | T041, T058 (the read-back reads through the layer); T031 (the session limit sized for two clients, FR-086) | Structural rather than counted: the provider holds no device credential — T037 generates them into the device-configuration layer's and the collector's namespaces only — so it cannot open a session. **No test counts sessions per client**; the fifth pass records that as the index's one open carrier rather than inventing one |

### FR-108 — the boundary around verification tooling

*Added by the seventh analysis pass of 2026-09-21 (`AD-65`): the requirement had grown across three
passes (`AD-03`, `AD-48`, `AD-55`/`AD-60`) to a dozen separable obligations and had no rows. Where a
clause is stated by its builder and asserted by nothing that would fail without it, the row says so.*

| Label | Obligation, as the requirement states it | Built by | Asserted by |
|---|---|---|---|
| FR-108(a) | Verification tooling is **never a change path**, and no service, fabric or lifecycle outcome depends on it — provisioning, convergence and readiness use only the path of FR-014 and FR-015 | T034 (the `LabReady` wait is a credential-less port accept, never a device client); T051 (the post-render probe is reported and evidence-captured, never an input to `Fabric.status`) | T025's fixture — a `gnmic` line planted under `scripts/lib/` fails `make verify-boundaries` naming the file (`AD-57`). For readiness the carrier is structural, as in FR-107(i): the provider holds no device credential, so no tool's result can reach a condition. **No test asserts that `Fabric.status` is unchanged by the probe's outcome** |
| FR-108(b) | Every such invocation is **run-captured evidence** (NFR-013) | T011 (`evidence_run`); T043, T051, T064, T134, T166 and T167 each state that every call goes through it | T154 (`make verify-evidence`, SC-040) — every artefact of the run carries its NFR-013 fields |
| FR-108(c) | What a tool writes is scratch configuration or a declared injected fault, **removed by the tool that wrote it, the removal read back before the run continues** | T043 (`run_gate.sh` reads the removal back on every node before it reports), T051 (the probe's scratch EVPN instances), T134 (`alerts_fire.sh`: link restored, leaf reattached), T064 and T167 (their faults) | The read-back is each script's own closing step, captured by `evidence_run`, and is the second half of SC-049; T151 and every suite's opening `leftovers::scan` catch a removal that did not happen. **No offline fixture fails a gate that skips its read-back** |
| FR-108(d) | The exception by class: a fault injected on a managed path is **drift**, which the platform restores under FR-015 — the injecting tool removes nothing and **reads the restoration back**; SC-004's negative control is declarative and is not a case of it | T064 (`managed_drift.sh`; `verify_services.sh` patches `Fabric.spec.overlay.interASVPN` and opens no device session), T043 (G13 records what is witnessable) | T064 live — restoration read back from device state, the deviation asserted only where `tests/gate/observed/deviation.json` says it is durably visible (SC-007) |
| FR-108(e) | It uses **the lab operator's device credentials, never a platform workload's identity**, and is never installed as a long-running process | T043 (every device call with the lab operator's credentials; G7's Pod pair given them for its lifetime only, "never the `monitoring` copy", never left running), T166 | The removal of G7's pair and namespace is read back before the gate reports (T043, `AD-55`). **No test asserts which credential a tool presented** — the clause is carried by the tasks' wording and by the boundary check of (g), which keeps device clients out of every platform path |
| FR-108(f) | It is **not reachable from, or invocable by, the intent tier** (FR-075) | The tier's identities and network policy, applied by T073 (T068–T072) before any agent workload exists | T066 (`boundary_probes.sh` — `pods/exec` and every documented management port denied to both identities) and T073's per-source packet counter (SC-028, SC-029) |
| FR-108(g) | A device client invoked from anywhere but the gate, the test suites and the walkthrough tooling **fails the boundary check in CI**; a *device client* is any invocation that opens a management session, which is what the check matches | T025 (`scripts/ci/verify_boundaries.sh` — `gnmic`, `gnmi_cli`, `sr_cli`, `ssh`/`sshpass` to a management address, `docker exec clab-…` outside `tests/`, `testautomation/` and quoted command blocks under `docs/` and `specs/`); T157 (the walkthrough's read-only `sr_cli` `info from state` proofs live under `testautomation/`) | T025's fixture in `tests/unit/verifyboundaries/` — the planted line fails under `scripts/lib/` and passes under `tests/` — run by T007's CI job; it is what **SC-049** measures |
| FR-108(h) | The **gate-owned scratch configuration resource**: labelled as gate-owned, at a priority no platform resource uses, on a path no fabric or service renders, removed by the gate with the removal read back **both** as the cluster object gone and as its content gone from the running datastore — FR-013's one named exception (`AD-48`) | T043 (G13 — neither priority 10 nor 20, a path no render emits, `spec.revertive: true` stated, both read-backs before the gate reports) | T043's `tests/unit/gate/leftover_scan_test.sh` — a cluster carrying one gate-labelled `Config` refuses the start naming it — and G13's own double read-back, in evidence. **The priority and the unrendered path are stated by T043 and asserted by no test of their own** |
| FR-108(i) | **A declared injected fault** is named in the run's evidence **before** it is made | T043 (convention *(iii)*: `<EVIDENCE_DIR>/declared-faults.json`, with the node, the change and the probe that finds it); T064, T134 and T167 follow it | `leftover_scan_test.sh` — a node missing from the management network refuses the start naming it, which exercises the fault-class probe. **That the record precedes the fault is asserted by no test** |
| FR-108(j) | Everything of the first two kinds is **named or labelled so that a later run can find it**, and a gate or acceptance run **refuses to start** while a leftover is present on any node — or, for the gate-owned `Config` and the gate's labelled scratch namespace, in the cluster | T043 (`tests/lib/leftovers.sh`: the `vt-scratch-` prefix, the gate-owned label, `leftovers::scan` reading the datastores, the cluster for a gate-labelled `Config` and for a gate-labelled scratch namespace, and every fault-class probe); T051, T064, T134, T167 and T151 start with it | `leftover_scan_test.sh` — a `vt-scratch-` instance, a gate-labelled `Config`, a gate-labelled scratch namespace and a detached node each refuse the start, four kinds of leftover with one plant of each, and a clean lab starts (`AD-49`, `AD-64`); the `vt-scratch-` prefix asserted absent from every golden |
| FR-108(k) | The **throwaway Pod**: only for a gate item that has to observe a pinned telemetry client, in a scratch namespace the gate labels, given the lab operator's device credentials for its lifetime only, and removed | T043 (G7's pinned gNMIc and collector pair), T166 (the three qualifications' Pods; its scripts remove the namespace and the Pods) | T043 (`AD-55`) and T166 (`AD-64`) each read the removal of their Pods and namespace back before the gate reports; each namespace carries the gate-owned label, so the scan of (j) finds one a dead script left — the fixture's scratch-namespace plant |

**How to keep this index honest.** It is a reading aid, not a second source of truth. When one of the
indexed requirements is reworded, re-read it against the rows above: a clause that no longer appears is
deleted here, a clause that appears with no carrier is the finding the index exists to surface.
