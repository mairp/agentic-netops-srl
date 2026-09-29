# Checklist triage — `checklists/requirements.md`, part A (CHK001–CHK090)

**Date**: 2026-09-20 · **Prepared for**: the human reviewer who owns
[`../../checklists/requirements.md`](../../checklists/requirements.md)

**Scope**: every `- [ ]` item from `## Content quality` through the end of `## Safety boundary`
(checklist lines 19–228, CHK001–CHK090). `## Lab, lifecycle and placement` (CHK091 onward) is **not**
covered here.

**Nothing was ticked, edited, reordered or annotated.** The checklist file was read only. No other
file in the feature was modified. This report is the only file written.

**What a verdict means here**

| Verdict | Meaning |
|---|---|
| `SUPPORTED` | The spec (or the cited companion artefact) satisfies the item, with evidence read, not inferred |
| `PARTIAL` | Partly satisfied; the row says exactly what is missing |
| `NOT SUPPORTED` | Searched for and not found; the row says what was searched for |
| `STALE` | The item's premise no longer matches the document |
| `JUDGEMENT` | Only the reviewer can decide; the row says what the judgement is about |

**Evidence base**: `spec.md` read in full (1925 lines); `traceability.md`, `platform-coupling.md`,
`plan.md` §Constitution Check and §Delivery phases, `research.md` §11/§13 excerpts,
`evidence/05-kubenet-sdc-kuid.md`, `contracts/crd-api.md`, `contracts/reconciliation.md`,
`contracts/kuid-claim-profiles.md`, `data-model.md` §17, `tasks.md` (checkbox count), and the
archived sources `specs/.archive/001-003-sources-2026-09-20.tar.gz` (used for the two mechanical
completeness checks and for the `Status: Draft` check). Three checks were run mechanically rather
than asserted; they are marked *(mechanical)* in the note.

**Caveat the reviewer should hold throughout**: the checklist predates FR-102…FR-109, NFR-014,
SC-042…SC-046 and CR-008. Where later text satisfies an item, the row says so; where later text
broke an item's premise, the verdict is `STALE`.

---

## Content quality

| Item | Abbreviated | Verdict | Note |
|---|---|---|---|
| CHK001 | No implementation detail leaks into FR/NFR/SC — product names live in plan and contracts | **PARTIAL** | Product names are extensively present in requirement and criterion text: `containerlab` ×12, `SR Linux` ×12, `Kubernetes` ×11, `gNMI` ×6, `Prometheus` ×4, `Grafana` ×4, `OpenTelemetry Collector` ×3, `gNMIc` ×2, `Kind cluster` ×2, `Docker` ×2, `nokia_srlinux`, `OTLP`, `JSON_IETF` (counted over `spec.md:704-1712`). Strongest instances: `spec.md:744` (FR-006 "a pinned Kind release and node image"), `spec.md:1280` (FR-088 "Prometheus MUST be the metrics store"), `spec.md:1283` (FR-089 "An in-cluster gNMIc subscribes over gNMI"). The item is violated in letter; whether it is a *defect* is the reviewer's call, because the retarget makes the named stack the subject of the feature (`spec.md:125-130`) and pins it as one compatibility set (FR-017, `spec.md:826-829`) |
| CHK002 | Focused on operator value and system behaviour rather than mechanism | **JUDGEMENT** | Both readings are supportable and only the reviewer can settle it. For: the thirteen user stories are written as operator journeys (`spec.md:164-579`) and every SC is an outcome. Against: several requirements prescribe mechanism — FR-016 names owner references, generation hashes and server-side apply (`spec.md:817-819`); FR-101 specifies annotation-key ownership and emission order (`spec.md:1332-1338`); NFR-014 specifies "one JSON object per line" (`spec.md:1409-1415`) |
| CHK003 | All mandatory template sections present and filled | **SUPPORTED** | Template mandatory sections are `User Scenarios & Testing`, `Requirements`, `Success Criteria` (`.specify/templates/spec-template.md:11,81,128`), plus `Assumptions` (`:142`), `Edge Cases` (`:71`), `Constitution-Mandated Requirements` (`:101`) and `Key Entities` (`:123`) where applicable. All present and filled: `spec.md:162`, `:582`, `:704`, `:1417`, `:1452`, `:1513`, `:1868` |
| CHK004 | Readable by someone who has not opened 001, 002 or 003 | **SUPPORTED** | The document carries its own context: §Provenance with the source table and milestone scopes (`spec.md:27-70`), §Inherited acceptance record with each disputed approval restated in full (`spec.md:72-121`). Source-qualified identifiers appear in live text exactly once, and there only as an explanation of the citation format (`spec.md:34`) — so no requirement requires a source document to be read to be understood |

## Identity and scope

| Item | Abbreviated | Verdict | Note |
|---|---|---|---|
| CHK005 | Scope distinguishes replacing a logical role from installing the NOS on arbitrary hardware | **SUPPORTED** | `spec.md:132-136`: "means replace its **logical role and supported service intent** … It does not mean SR Linux runs on arbitrary router hardware, nor that every WAN/MPLS feature has an EVPN equivalent" |
| CHK006 | All network nodes are SR Linux in containerlab; Linux limited to endpoints and tooling | **SUPPORTED** | FR-001 `spec.md:716-719` ("All emulated network devices MUST be Nokia SR Linux nodes … endpoint hosts MAY be Linux containers"); FR-008 `spec.md:754-755` ("Containerlab MUST remain responsible only for SR Linux nodes and Linux traffic endpoints") |
| CHK007 | Proprietary controller / fabric-automation / device-package dependencies excluded, CI-enforced | **SUPPORTED** | FR-049 `spec.md:1089-1093`; enforcement is SC-017(a) `spec.md:1602-1614` ("A repository-wide CI deny-list enforces three boundaries"). Scope extended to the NOS vendor's own automation product in `platform-coupling.md` PC-21 |
| CHK008 | ASIC equivalence and live cutover not implied; packet-rate ceiling stated as a limit tests must respect | **SUPPORTED** | Assumptions `spec.md:1870-1872` and `:1886-1887` (no production-ASIC claim; automated cutover out of scope); NFR-004 `spec.md:1375-1377` ("the limits of the containerized dataplane — in particular its packet-rate ceiling — that acceptance tests must respect"); FR-020 `spec.md:1841-1843` ("MUST NOT assert throughput") |
| CHK009 | Describes SR Linux only; every inherited coupling inventoried **with disposition and resolution**; new SR Linux couplings inventoried too | **SUPPORTED** | `platform-coupling.md:10-13` states the file is now the resolution record; the disposition vocabulary is `:28-35`; all 21 inherited rows (PC-01…PC-21) carry both a `Disposition` and a `Resolution on SR Linux` column with an evidence citation; the SR Linux-introduced couplings are §New couplings PC-S-01…PC-S-15 (`platform-coupling.md:183-206`). In `spec.md`, "SONiC" appears only in provenance/history sentences (lines 10, 18, 22, 39, 57, 59, 79, 129) and in no requirement |

## Consolidation integrity

| Item | Abbreviated | Verdict | Note |
|---|---|---|---|
| CHK010 | Every composite FR/NFR/SC/CR/US/decision/risk in the forward table, incl. added and retired | **SUPPORTED** | *(mechanical)* Extracted every `- **ID**:` bullet from `spec.md` (177: 109 FR + 14 NFR + 46 SC + 8 CR) and every leading cell of the forward tables (`traceability.md:66-432`): 177 = 177, no orphan either way, no duplicate row. Retarget/clarification/analysis additions are all present (FR-102…FR-109, NFR-014, SC-042…SC-046, CR-008). User stories `:270-285` (13 incl. retired US3), decisions `:288-380`, risks `:381-432`. The file's own self-check is `:879-890` |
| CHK011 | Every source FR/NFR/SC/US/decision/risk in the reverse table, incl. merged, superseded, retired | **SUPPORTED** | *(mechanical, against the archive)* Unpacked `specs/.archive/001-003-sources-2026-09-20.tar.gz`; counted 001 = 33 FR/5 NFR/16 SC/5 US, 002 = 39/7/16/5, 003 = 26/0/7/5 — matching `traceability.md:805-810` exactly. Compared the 149 source FR/NFR/SC identifiers with the 149 source cells of the reverse tables (`traceability.md:433-696`): identical sets, nothing missing either way. Decision, user-story and plan-risk rows are present in the same tables (86 further rows) |
| CHK012 | No source requirement vanished: every reverse row `carried`/`merged`/`retired-by-retarget`; `dropped-with-reason` used nowhere | **SUPPORTED** | *(mechanical)* Disposition tally over `traceability.md:433-696`: 207 `carried`, 16 `merged`, 13 `retired-by-retarget`, zero anything else. `dropped-with-reason` occurs only in the vocabulary definition (`:48`, "Used nowhere") and the claim at `:758`. Each retired row names its retiring decision and destination — §"Nothing dropped" table `traceability.md:768-780` (eight identifiers, each with source, RD-04/RD-02 and "where the obligation went") |
| CHK013 | Every superseded claim appears only in its superseding form, each supersession recorded with citation | **SUPPORTED** | `traceability.md:697-715`: five supersessions of 002 by 003, each with "where the superseding form lives" and an evidence citation (commit ids, file:line); `:700-703` states the retarget added no supersession, with the reason |
| CHK014 | No source-qualified identifier form in live requirement text | **SUPPORTED** | Grep for `00[123]:(FR\|NFR\|SC\|US\|D)-` over `spec.md` returns exactly one hit, `spec.md:34`, which is the §Provenance sentence explaining the citation format — not live requirement text |
| CHK015 | Identifiers flat and continuous, grouped by concern, lettered sub-ids folded and the fold recorded; nothing renumbered; no retired number reused | **SUPPORTED** | Numbering is flat and continuous (FR-001…FR-109 all present, verified in CHK010) and grouped by concern under the ten `####` headings (`spec.md:706-710` states the grouping intent). The two lettered source ids are folded and the fold is recorded: `003:FR-003a → FR-027` and `003:FR-012a → FR-037` (`traceability.md:98, 108, 639, 649, 805`). "Nothing was renumbered" is restated by each pass (`spec.md:1715, 1735, 1753, 1771`) and retired numbers keep tombstones rather than being reused (`spec.md:727-729, 741-742, 847-852, 1571-1574`). *Note for the reviewer*: the **merge** did renumber source ids into the flat sequence by design (`spec.md:67-70`); the item's "no identifier was renumbered" is true of **composite** identifiers |
| CHK016 | Safety-boundary requirements contiguous and unbroken | **SUPPORTED** | §8 Safety boundary holds FR-075…FR-079 with nothing interleaved (`spec.md:1202-1241`), and `:1204-1206` states the contiguity is deliberate |
| CHK017 | Scope-boundary prose recorded as history in §Provenance, not carried as a live constraint | **SUPPORTED** | `spec.md:49-55` ("They are recorded here as history and are **not** carried forward as live constraints"); the two source passages are itemised with where their existence is recorded in `traceability.md:786-793` |
| CHK018 | Removability survives merge and retarget as a requirement | **SUPPORTED** | NFR-006 `spec.md:1380-1388` ("This is a property of the system, not of the documents"), NFR-007 `:1389-1390`, measured by SC-025 `:1639-1640` |

## Honesty

| Item | Abbreviated | Verdict | Note |
|---|---|---|---|
| CHK019 | Status is `Draft`, matching all three sources | **SUPPORTED** | `spec.md:7` and `:85`. Verified against the archive: `001/spec.md:5`, `002/spec.md:5`, `003/spec.md:7` all read `**Status**: Draft` |
| CHK020 | No task is marked complete; no `tasks.md` is produced | **STALE** (first half SUPPORTED) | The premise changed: a `tasks.md` **is** now produced (2026-09-20, `spec.md:87-91`). The surviving half holds and is verified mechanically: `tasks.md` carries 174 `- [ ]` and zero `- [x]`, and `spec.md:89-91` binds ticking to NFR-013 evidence. Recommend the reviewer re-read the item as "no task is marked complete" and record the `tasks.md` clause as overtaken |
| CHK021 | Each disputed approval carried **with** its contradiction | **SUPPORTED** | `spec.md:96-101`: a four-row table whose columns are "What it asserts" and "Contradiction recorded against it", each contradiction cited to a reconciliation-sheet row or an evidence section |
| CHK022 | Absent-runtime caveat stated once, plainly; research numbers phrased as measured-in-research and re-observed | **PARTIAL** | First half SUPPORTED: `spec.md:113-121` states the caveat once and closes "No claim in this document should be read as a report of observed success"; NFR-004 goes further, requiring the per-node footprint be "observed by a clean-host run and taken from its evidence, never quoted from research" (`spec.md:1374-1375`). **Missing**: the one bare research number left in `spec.md` — Assumptions `:1871-1872`, "The containerized dataplane forwards at a few thousand packets per second at most", stated as fact, where the underlying record is "1000 PPS documented unlicensed, ~5 kpps measured" (`platform-coupling.md` PC-S-10) and the pattern used elsewhere is "measured in research … re-observed at P0" (PC-03, PC-19) |
| CHK023 | Constitution gate re-evaluated for a **greenfield** repo; pass-by-obligation; predecessor defects named as the reason NFR-003 and NFR-013 exist | **SUPPORTED** | `plan.md:289-291` ("**This is a greenfield repository** … There is nothing here to have passed or failed"); Principle V `plan.md:300` ("**PASS — by obligation, nothing observed yet** … The predecessor's placeholder digests and unpinned `:latest` tier images are the reason those clauses are worded that way"); Principle VI `plan.md:301` ("The predecessor's three disputed approval records … are exactly why NFR-013 and SC-040 exist"); `plan.md:330-332` ("No principle failure is carried and no exception is requested"). *Note*: only Principles V and VI carry the "by obligation" qualifier; I–IV are plain `PASS` with a specification-level reason |
| CHK024 | Where a source specified a design the sources say was **not** built, divergence recorded as history **and** answered by a named requirement | **SUPPORTED** | `spec.md:105-111`: a "Failure recorded → Answered by" table mapping each to NFR-003, NFR-013/SC-040, FR-042/FR-100, FR-013/FR-098, FR-014/FR-015/FR-007. The southbound case is additionally carried in `platform-coupling.md` §History (`:121-168`) |

## Requirement completeness

| Item | Abbreviated | Verdict | Note |
|---|---|---|---|
| CHK025 | No `[NEEDS CLARIFICATION]` marker remains | **SUPPORTED** | Grep over the whole feature directory returns one hit, and it is the checklist item itself (`checklists/requirements.md:82`). Open questions are instead carried as §Clarification candidates with two marked *Resolved* (`spec.md:1843-1866`) |
| CHK026 | Requirements testable and unambiguous; **each states a single obligation** | **PARTIAL** | Testability holds (each requirement names an observable outcome, and 177/177 identifiers are traced). The "single obligation" half does not: several requirements bundle many separable obligations — FR-109 runs 28 lines and carries adoption, tier-less claiming, collision refusal, immutability, attachment mutability and release ownership (`spec.md:927-954`); NFR-003 runs 28 lines covering pins, the single admitted exception, host-side tooling and first-party build-input pinning (`spec.md:1344-1371`); FR-078 covers six event kinds, retention, export, failure-stop and the discard flag (`spec.md:1226-1239`); FR-015 covers validation, transactionality, drift policy closure and priority overlap (`spec.md:800-816`). These are testable but not unit-testable as written |
| CHK027 | Absolute constraints marked as such rather than reading as defaults | **SUPPORTED** | FR-075 `spec.md:1209` ("**This is an absolute constraint, not a default.**"); FR-007 `:749-751` ("**without exception**"); FR-015 `:804-806` ("a provider setting with **no default** … a provider started without one refuses to start"); NFR-003 `:1346-1348` ("forbidden wherever a reference can appear") |
| CHK028 | Success criteria measurable, **and each names a verification method** | **PARTIAL** | Measurability holds throughout (percentages, counts, time bounds, byte-identity). The "names a verification method" half is uneven. Named, exemplary: SC-026 `spec.md:1641-1642` ("verified by comparing allocation state before and after"), SC-028 `:1648-1654` (per-source counter, positive control), SC-045 `:1558-1564` and SC-046 `:1565-1570` ("verified by a claim-selector diff before, during and after"). **Not named**: SC-011 `:1578-1579`, SC-019 `:1621-1623`, SC-027 `:1646-1647`, SC-033 `:1671-1673`, SC-034 `:1682-1685`, SC-035 `:1686-1687` state an outcome with no method attached. Given the inherited acceptance record, this is the gap most worth closing |
| CHK029 | Success criteria are technology-agnostic | **PARTIAL** | Several name the pinned stack: SC-002 `spec.md:1521` ("Ready for the Kind cluster"), SC-006 `:1540-1541` ("zero gNMI mutations"), SC-034 `:1682-1685` (metrics store, dashboards, telemetry collector), SC-037 `:1691-1693` ("the single collector pipeline to the metrics store"). Same root cause and same reviewer call as CHK001 — the feature's subject *is* a pinned stack |
| CHK030 | Acceptance scenarios defined for every live user story | **SUPPORTED** | 13 `### User Story` headings and 12 `**Acceptance Scenarios**` blocks; the one story without is US3, which is tombstoned (`spec.md:240-247`). Every live story also carries a *Why this priority* and an *Independent Test* |
| CHK031 | Edge cases identified across fabric, constructs, intent tier and observability | **SUPPORTED** | Four headed groups at `spec.md:582-702`: "Fabric, allocation and reconciliation" (`:584-612`), "Constructs and access lists" (`:614-654`), "Intent tier" (`:656-692`), "Observability" (`:694-702`). The fourth analysis pass added an outcome to the four that had none (`spec.md:1727`) |
| CHK032 | Scope bounded, out-of-scope stated — incl. deferred scope naming what would reopen it | **SUPPORTED** | §Deferred scope `spec.md:1827-1841` with the tombstone table and "**What would reopen it**: a pinnable, licensable device profile that originates and terminates SRv6 services …"; further out-of-scope in `:147-150`, `:1888-1889`, `:1902-1905` |
| CHK033 | Dependencies and assumptions identified, **each stating its consequence** | **PARTIAL** | The assumptions are present and most do state a consequence (`spec.md:1877-1885`, `:1896-1898`, `:1906-1916`). Bare ones with no consequence: `:1892-1893` (why a local `vlan` is its own construct — a rationale, not a consequence) and `:1911-1912` ("Lab-scale concurrency: a single operator …"). There is also no `Dependencies` block in `spec.md`; upstream dependency state lives in `plan.md` §Technical Context, `research.md` §11 and `platform-coupling.md` PC-S-01/PC-S-15 — adequate, but a reader of `spec.md` alone does not get it |
| CHK034 | Every `[GAP]` resolves to exactly one carrying requirement or a named deferral; no gap closed by prose | **SUPPORTED** | §Gaps closed by the retarget `spec.md:1812-1825`: GAP-1→FR-097, GAP-2→FR-046 (+FR-048 as the referencing Kind), GAP-3→FR-101, GAP-4→FR-043, GAP-5→closed by deferral with the RBAC consequence named, GAP-6→FR-100. Each closing requirement carries a "*(Closes GAP-n.)*" marker in its own text (`:857`, `:1077`, `:1058`, `:876`, `:1338`). Minor: GAP-2 names two identifiers, of which FR-046 is the carrier |

## Architecture quality

| Item | Abbreviated | Verdict | Note |
|---|---|---|---|
| CHK035 | Kubernetes reconciliation is the orchestration workflow; **no second workflow engine** | **PARTIAL** | The positive half is stated: every agent-originated change is a declarative resource submitted to the cluster API (FR-064 `spec.md:1164-1165`), one fabric-intent API group (FR-013 `:785-795`), one translation implementation (FR-060 `:1126-1131`), reconciliation semantics in FR-018 `:830-834`. **The prohibition is nowhere**: grep for "workflow engine", "second orchestrator", "orchestration engine", "Argo", "Temporal", "Airflow" over `spec.md`, `plan.md` and `contracts/` returns nothing. The document forbids a second *translation path* and a second *fabric-intent API* by name, but never a second workflow engine |
| CHK036 | Upstream config layer owns device transactions and drift; allocation authority owns identifiers; first-party API owns only what neither can express | **SUPPORTED** | FR-015 `spec.md:800-816` (validate, apply as a transaction, expose deviation, "the only component that writes device configuration"); FR-012 `:777-784` (fabric design + allocation authority own allocation, everything else derived); FR-013 `:785-795` ("because no maintained upstream fabric API can express the four constructs") |
| CHK037 | One narrow provider, not a second orchestrator; "gap controller" rejected **by name** | **SUPPORTED** | FR-014 `spec.md:796-799` (a single first-party provider, the only renderer of any device path); §Retarget decisions row 2 `:1799` ("a gap controller would be a second translation path by this specification's own definition"); the rejection is argued in `research.md:150-153` and `:1181-1184` |
| CHK038 | First-party API fills only what no upstream API can express; delegates topology, identifier allocation and device transactions | **SUPPORTED** | FR-013 `spec.md:790-795`; delegation in FR-012 `:777-784`, FR-015 `:800-803`, and the *Inventory* entity ("the allocation authority's node, link and endpoint records", `:1459-1460`) |
| CHK039 | One device transaction and drift layer | **SUPPORTED** | FR-015 `spec.md:802-803`: "It MUST be the only component that writes device configuration"; reinforced by FR-007 `:749-753` and FR-108 `:914-926`, which bounds the checking tools without widening the write path |
| CHK040 | Ownership boundaries prevent two reconcilers on one path; two configs touching one leaf may not share a priority | **SUPPORTED** | FR-015 `spec.md:814-816` ("Configuration resources that could touch the same device leaf MUST NOT share a priority: such an overlap is a conflict refused at validation"); FR-016 `:817-819` (owner references, scoped field ownership); FR-101 `:1332-1338` (one owner per metadata key) |
| CHK041 | Direct reconciliation is the first slice; review workflows clearly later | **SUPPORTED** | Delivery order in `plan.md`: P2 fabric foundation `:695` and P3 provider/constructs `:719` precede P6 transport `:809` and P7 submission `:826`. The reviewable/cutover workflow is explicitly optional and conditional — FR-048 `spec.md:1081-1088` ("If an auditable cutover workflow is required … It is not installed unless asked for"). *Reading used*: "review workflows" = the `MigrationPlan` approval/cutover path; if the reviewer meant something else, this row needs re-reading |
| CHK042 | Upstream APIs reused not duplicated; **no first-party Kind in an upstream API group** | **SUPPORTED** | FR-013 `spec.md:785-789` (reuse unchanged, no duplicate CRDs); FR-098 `:858-862` ("No CRD or API service MAY be installed into an upstream project's API group unless it is that project's own pinned, unmodified artefact … the provisioning script MUST fail rather than fall back to one"); the one permitted substitution is held to the same rule by FR-104 `:896-898` |
| CHK043 | Intent tier is a layer **above** the declarative boundary; dependency arrow never points back | **SUPPORTED** | NFR-006 `spec.md:1382-1383` ("the dependency arrow points from the tier to the control plane and never back"); NFR-007 `:1389-1390`; FR-064 `:1164-1165`; §Provenance `:49-55` |

## Upstream capability and version realism

| Item | Abbreviated | Verdict | Note |
|---|---|---|---|
| CHK044 | Dependency state stated as found: config layer active and CI-exercised against this release; allocation authority and upstream fabric control plane **dormant**, with last release dates | **SUPPORTED** | Config layer exercised against the pin: `platform-coupling.md` PC-S-01 ("sdcio CI runs against 25.7.1"). Allocation authority dormant with a date: PC-S-15 ("`kuid-server` last released 2024-12-27") and `research.md:1192-1194`. Upstream fabric control plane dormant: `research.md:1177-1179` ("no release, is dormant for roughly twenty-two months, demonstrates against an SR Linux release from 24.3, no longer compiles against the current device-configuration layer"); exact dates per repository are tabulated in `evidence/05-kubenet-sdc-kuid.md:65-70`. *Minor*: in `research.md` the fabric control plane's dormancy is given as a duration, with the dates only in the evidence file |
| CHK045 | Tutorial-vs-current version drift identified; no requirement rests on a tutorial's field names | **SUPPORTED** | Drift identified concretely: `evidence/05-kubenet-sdc-kuid.md:92-96` ("the field names were renamed between the tutorial artifacts and the kuidapps main branch … it is real"); the rule is `research.md:141-143` ("It must not combine tutorial YAML with an unpinned branch, and it must not assume a Kind's storage version from the version it writes"). Structurally the risk is retired: the upstream fabric API is not adopted at all (RD-03, FR-013 `spec.md:790-793`), so no requirement can rest on its field names |
| CHK046 | One complete pinned upstream release or commit per reused project, from that project's own artefacts | **SUPPORTED** | FR-098 `spec.md:858-862` ("that project's own pinned, unmodified artefact"); Assumptions `:1877-1880` ("One release of the device-configuration layer and one release of the allocation authority are selected … installed from their own pinned artefacts"); NFR-003 `:1344-1348` |
| CHK047 | One qualified compatibility set, and its **weakest member** — the one that caps the device release — is named | **SUPPORTED** | The set is FR-017 `spec.md:826-829` (nine members, "pinned and published as one compatibility set"); its members are enumerated in `platform-coupling.md` PC-01; the weakest member is named in PC-S-01: "**The release pin's ceiling is set by the deviation patch, not by the NOS** … sdcio's `srlinux-yang-patch` deviation branches stop at `v25.7`". *Note*: the cap is named in the companion artefacts, not in FR-017 itself |
| CHK048 | One lab profile and one device image; the capability gate qualifies it; no second profile to fall back to | **SUPPORTED** | FR-010 `spec.md:767` ("There is one lab profile; no flag selects a device profile"); FR-004 `:730-740` is the qualifier; Assumptions `:1881-1885` ("If the pinned image fails the capability gate, the gate's failing item is fixed or the affected construct is reported unqualified; the gate is not relaxed"); `platform-coupling.md` PC-03 deletes the two-profile scheme |
| CHK049 | Acceptance cannot skip, mock or substitute host forwarding for device behaviour; unqualified constructs refused by name | **SUPPORTED** | FR-004 `spec.md:740` ("A failed capability is never skipped and never weakened"); FR-097 `:853-857` (refused at interpretation, naming what is unqualified, before anything is claimed); CR-007 `:1444-1446`; the host-forwarding substitution is closed by FR-007 `:746-753` (no host-side executors, without exception) and bounded by FR-108 `:914-926` (checking tools write only scratch or a declared fault, and no outcome depends on them) |
| CHK050 | Floating versions, mutable tags, branch refs, placeholder digests forbidden; pin check resolves every digest; predecessor failure recorded as the reason | **SUPPORTED** | NFR-003 `spec.md:1344-1371` states all four prohibitions "wherever a reference can appear", requires registry resolution, admits exactly one exception and closes the field in which another could be declared; the predecessor's failure is named as the reason at `spec.md:107` and in `plan.md:300` |

## Construct vocabulary

| Item | Abbreviated | Verdict | Note |
|---|---|---|---|
| CHK051 | Construct set closed at four; nothing else advertised as a type | **SUPPORTED** | FR-024 `spec.md:958-960`; scope statement `:140-145`; SC-033 `:1671-1673` |
| CHK052 | Name resolution case-, hyphen-, underscore- and space-insensitive | **SUPPORTED** | FR-025 `spec.md:961-962`; US4 scenario 6 `:289-290` (`IP-VRF`, `ip_vrf`, `MAC VRF`) |
| CHK053 | Each construct states what it MUST provision **and what it must not** | **SUPPORTED** | `vlan`: FR-029 `spec.md:972-976` ("MUST NOT allocate a VNI or route targets, nor render any tunnel or EVPN configuration … so that 'local' is never encoded as 'the overlay fields are missing'"). `acl`: FR-035 `:999-1004` ("MUST NOT create an interface or subinterface of its own") plus FR-062 `:1137-1138` ("MUST claim only what the requested construct's profile allocates") and the profile table `contracts/kuid-claim-profiles.md:47,63` ("An access list allocates nothing"). `mac-vrf`/`ip-vrf` positives at `:977-981`, with US8 scenario 3 `:430-431` supplying the `mac-vrf` negative |
| CHK054 | Symmetric IRB as composition, not a fifth type name | **SUPPORTED** | FR-032 `spec.md:982-983` ("this composition MUST be the only way symmetric IRB is expressed"); US8 `:410-431` |
| CHK055 | A variable belonging to another construct is refused naming both property and carrier | **SUPPORTED** | FR-033 `spec.md:984-985` ("naming both the property and the construct that carries it — never silently ignored"); US4 scenario 7 `:291-293` |
| CHK056 | Retired service names accepted as **input aliases only**; in output only as provenance | **SUPPORTED** | FR-044 `spec.md:1062-1068` ("folded on entry before any validator or translator sees them … A folded name MUST NOT appear in any output as a type"); FR-026 `:963-965`; FR-046 `:1074-1077`; FR-085 `:1257-1258`; SC-033 `:1671-1673` |
| CHK057 | Every per-service-type fabric constraint enforced per construct, cause stated in construct terms | **SUPPORTED** | FR-034 `spec.md:986-990`, which enumerates the constraints (one service VLAN per bridge domain, VNI band within the EVI range, the managed VLAN range, one owner per node/port/VLAN, one tagging mode per port, site inventory) "with the cause stated in construct terms" |
| CHK058 | A service that converged before the vocabulary changed is reported by its construct, stored record untouched | **SUPPORTED** | FR-027 `spec.md:966-969` ("Its stored record MUST NOT be rewritten — no converged service is written to for a naming change"); US9 scenario 3 `:456-458`; the *Provenance record* entity `:1498-1500` ("Derived on read for pre-existing services; never written back to them") |

## Access lists

| Item | Abbreviated | Verdict | Note |
|---|---|---|---|
| CHK059 | Expressible both as a service and as a property of another service | **SUPPORTED** | FR-035 `spec.md:999-1004` (own right) and FR-036 `:1005-1008` (property of a `vlan`/`mac-vrf`/`ip-vrf`); US5 `:302-342` |
| CHK060 | Binding to attachment subinterfaces only; network-instance/IRB/fabric-wide refused saying so | **SUPPORTED** | FR-037 `spec.md:1009-1013` ("An access list MUST NOT be bindable to a network instance, to a VLAN as such, to an integrated-routing interface or fabric-wide, and a request asking for one MUST be refused stating that the list binds to named attachments"); Assumptions `:1899-1901` |
| CHK061 | A stage, an address family and at least one rule are required | **SUPPORTED** | FR-038 `spec.md:1014-1016`; the "no rules" case is also an edge case at `:652-653` |
| CHK062 | Duplicate priorities/names, reserved position, cross-family prefix, L4 port on non-TCP/UDP, reserved device name, out-of-range each refused naming the rule | **SUPPORTED** | FR-040 `spec.md:1027-1032` carries all seven, "each naming the offending rule, and for the reserved position, stating the range that is usable"; the reserved-name case is traced to `platform-coupling.md` PC-S-12 (`system`, `capture`) |
| CHK063 | Evaluation order and usable range stated at first confirmation; declared default rendered at the reserved last position; undeclared default states accept | **SUPPORTED** | FR-039 `spec.md:1017-1026` (ascending, first match wins, rendered unchanged as the sequence number, last position reserved, "stated to the operator at the first confirmation"); FR-041 `:1033-1039` ("rendered explicitly … as a terminal match-all entry at the reserved last position … the confirmation shown to the operator MUST state that unmatched traffic will be accepted"); US5 scenarios 5 and 8 `:330-342` |
| CHK064 | Convergence requires written config **and** the device's programmed state for **this** filter, keyed; unobserved never converged; readiness never depends on traffic | **SUPPORTED** | FR-042 `spec.md:1040-1049` ("keyed by this filter's name, address family and entry … A count of filters or entries across the device is never evidence … A property the platform has not observed MUST NOT be reported as converged. Readiness MUST NOT depend on passing traffic"); enforcement moved to acceptance by SC-041 `:1705-1708` |
| CHK065 | Second binding on the same subinterface/direction/family refused naming the incumbent; nothing displaced; a service being removed still holds its bindings | **SUPPORTED** | FR-043 `spec.md:1050-1058` (all three clauses verbatim, plus "Withdrawal MUST remove the binding before the filter" and the finalization rule); US5 scenario 6 `:334-336`; edge cases `:639-645` |
| CHK066 | What cannot be expressed is refused **by name**; what is excluded by scope says so | **SUPPORTED** | FR-038 `spec.md:1015-1016` ("MUST be refused as out of scope — the construct is defined over address families — rather than as something the device lacks"); Assumptions `:1902-1905` ("out of scope and refused by name"); FR-061 `:1132-1134`; `platform-coupling.md` PC-07 records the reason change |
| CHK067 | Predecessor's switch-wide applied-side check recorded as a defect, the preventing requirement named, stock filter entries documented as the hazard | **SUPPORTED** | Defect and answer: `spec.md:109` ("An applied-side check that passed on an empty fabric because it was switch-wide → FR-042 and FR-100"); the hazard: FR-042 `:1045-1046` ("because a stock device already carries filters of its own"), made concrete in `platform-coupling.md` PC-13 ("containerlab's stock **`cpm`** filter entries are what is 'already there on an empty fabric' now"); generalised by NFR-013 `:1405-1407` |

## Service translation and migration safety

| Item | Abbreviated | Verdict | Note |
|---|---|---|---|
| CHK068 | Migration alias catalogue explicit and in construct terms | **SUPPORTED** | FR-044 `spec.md:1062-1068` names each fold (multipoint L2VPN and its p2p variant → `mac-vrf` with an L2VNI; the routed VPN name → `ip-vrf`; the integrated L2/L3 name → `mac-vrf` with an anycast gateway) |
| CHK069 | Limited equivalence requires opt-in, not claimed as full parity | **SUPPORTED** | FR-045 `spec.md:1071-1073` ("Limited equivalence — a point-to-point service represented by a dedicated L2VNI — requires explicit opt-in and a durable status finding") |
| CHK070 | TE, pseudowire OAM, multicast, complex QoS, service chaining and unknown properties rejected or deferred | **SUPPORTED** | FR-045 `spec.md:1069-1071` (unmapped or lossy properties rejected before any device mutation, unsupported features enumerated in status); US9 scenario 5 `:462-464` (TE, pseudowire-OAM, multicast, unmapped-QoS by name); Assumptions `:1888-1889` (service chaining, multicast VPN, feature-exact QoS/OAM out of scope) |
| CHK071 | Translation is all-or-nothing before any downstream mutation | **SUPPORTED** | FR-045 `spec.md:1069-1071`; US9 Independent Test `:445-448` ("an unmapped source property rejects the whole translation before any downstream resource is created"); SC-016 `:1600-1601` |
| CHK072 | Identifier, reference and collision validation specified | **SUPPORTED** | Identifier bands and one-owner: FR-034 `spec.md:986-990`; reference resolution through the site inventory: FR-037 `:1009-1011`; allocation collisions: FR-062 `:1135-1147`; tier-less VNI collisions with `Accepted=False` naming value and holder: FR-109 `:927-954`; binding collisions: FR-043 `:1050-1058` |
| CHK073 | Raw device CLI is not an accepted translation input | **SUPPORTED** | FR-045 `spec.md:1071`: "Raw device CLI is never an accepted translation input" |
| CHK074 | Source-scoped constraints stay scoped to their source vocabulary | **SUPPORTED** | FR-047 `spec.md:1078-1080` ("MUST NOT be imposed on requests that name the construct directly"); US9 scenario 4 `:459-461`; edge case `:654` |
| CHK075 | Exactly one translation implementation; the access-list render is a field on the same object | **SUPPORTED** | FR-060 `spec.md:1126-1131`: "**so that no second translation implementation exists**. Intent becomes fabric intent in exactly one place; the access-list render is a field on the same fabric intent object, not a second path" |

## Intent tier

| Item | Abbreviated | Verdict | Note |
|---|---|---|---|
| CHK076 | Pipeline stages each have a single responsibility and a schema-validated output | **SUPPORTED** | FR-051 `spec.md:1100-1102` ("a fixed pipeline of four specialist stages … where each stage has a single responsibility and a schema-validated output contract"); FR-058 `:1119-1122`; FR-065 `:1166-1167` |
| CHK077 | Two explicit human confirmations; a one-shot request cannot provision | **SUPPORTED** | FR-055 `spec.md:1112-1114`; CR-002 `:1428-1431` (scoped to the tier by the first analysis pass, `:1725`); the state-machine invariant in `data-model.md:368-371` refuses submission unless the status is approved and the second confirmation is a confirm |
| CHK078 | Declining releases every provisionally claimed identifier and leaves the fabric unchanged — **including when the construct claimed nothing** | **SUPPORTED** | FR-056 `spec.md:1115-1116`; the claimed-nothing case is FR-062 `:1137-1138` ("MUST treat 'this construct claims nothing' as a success rather than an error") with the `acl` profile at `contracts/kuid-claim-profiles.md:63`; measured by SC-026 `:1641-1642` |
| CHK079 | Under-specified requests ask for exactly the missing detail, never defaulting a service-defining value | **SUPPORTED** | FR-059 `spec.md:1123-1125` ("rather than substituting defaults for service-defining values"); US4 scenario 9 `:297-298` |
| CHK080 | Every allocated identifier from the existing authority per the claim profile; derived identifiers shown exactly as rendered | **SUPPORTED** | FR-062 `spec.md:1135-1141` (both halves: obtain from the authority rather than generating locally; "Identifiers the platform derives rather than allocates (FR-012) MUST be shown in the assignment exactly as they will be rendered, so the second confirmation covers them too") |
| CHK081 | Submission atomic, dry-run-gated, rollback-enumerable; outcome one of three; "dry-run" is a check that can actually fail | **SUPPORTED** | Atomic + rollback enumerated: FR-066 `spec.md:1168-1170`; three outcomes: FR-067 `:1171-1174`; the dry-run gate: CR-004 `:1434-1437`. The "can actually fail" half is carried by the contracts: `contracts/crd-api.md:121-125` (real structural schemas, no `x-kubernetes-preserve-unknown-fields`, "so that a server-side dry-run is a meaningful gate … it says nothing about the device payload"), the cross-object rules at `crd-api.md:154-159` (attachment resolvability, one owner per node/port/vlan, tagging mode, binding exclusivity, qualification — all webhook), and `contracts/reconciliation.md:92-96` ("neither is the Kubernetes API server validating a device payload … that MUST NOT be presented as a gate") |
| CHK082 | Workers independently addressable, runtime-discoverable, timeout- and retry-bounded, unreachable ≠ failed | **SUPPORTED** | FR-070 `spec.md:1179-1181` ("independently addressable processes rather than in-process function calls"); FR-071 `:1182-1183` (runtime-discovered capability descriptor); FR-073 `:1186-1189` (per-call timeout, bounded retry with backoff, "MUST distinguish 'worker unreachable' from 'worker returned a failure'"); FR-074 `:1190-1191` |
| CHK083 | Workflow status vocabulary closed **and the unknown status is never a success** | **PARTIAL** | Closed set: SUPPORTED — FR-054 `spec.md:1109-1111` and the eleven-value enum in `data-model.md:889-894` ("**No status outside this enum may appear anywhere**, including in the operator stream and the chat surface"). **Missing**: nothing says `STATUS_UNKNOWN` is never a success. The state diagram (`data-model.md:358-365`) reaches it from "any" on transport or state loss and keeps it distinct from `COMPLETED`, and FR-067 `:1171-1173` requires one of three outcomes — but no requirement forbids treating `STATUS_UNKNOWN` as converged, and FR-018's "partial success never reported as ready" (`:830-834`) is about the control plane, not the tier |

## Safety boundary

| Item | Abbreviated | Verdict | Note |
|---|---|---|---|
| CHK084 | No-device-session rule is absolute and stated once, at its strongest | **SUPPORTED** | FR-075 `spec.md:1208-1210` ("MUST NOT open a device session, issue a device command, or write device configuration by any path. **This is an absolute constraint, not a default.**"); §8 preamble `:1204-1206` states the block is contiguous by design. No weaker restatement elsewhere: FR-064 and FR-076 are complements, not repetitions |
| CHK085 | Enforced **structurally** — an identity that cannot express the action — not only behaviourally | **SUPPORTED** | FR-075 `spec.md:1210-1220`: "It MUST be enforced structurally and not only behaviourally", then the exact two identities and their verb sets, closing "so that the forbidden action cannot be expressed even by an agent that tried". The verb sets were made exact by the first analysis pass (`:1723`) precisely so the denial probes have an allow-list |
| CHK086 | Every denial attemptable and enumerated, covering **every** management port the lab image exposes, including the plaintext one | **SUPPORTED** | FR-075 `spec.md:1216-1220` ("**on any port** — the encrypted management port, the plaintext management port the lab image also exposes, the shell and every programmatic interface alike"); SC-029 `:1655-1657` ("verified by attempting each, as each identity, and observing denial"); the probe list is `plan.md:676-680` (57400, 57401, 22, 80/443, 830); the port inventory is `platform-coupling.md` PC-S-03 |
| CHK087 | User text and worker text treated as data; injected instruction produces a byte-identical proposal | **SUPPORTED** | FR-077 `spec.md:1223-1225` ("MUST produce an unchanged proposal for a request whose text carries an embedded instruction"); US6 scenario 2 `:365-367`; SC-028 `:1648-1654` measures it over a dedicated adversarial corpus |
| CHK088 | Every confirmation, decline, submission and refusal auditable with principal and correlation id | **SUPPORTED** | FR-078 `spec.md:1226-1239` — six event kinds, "carrying the requesting principal, the request correlation identifier and the resulting resource", with the store, retention, unconditional export and the named discard flag. The principal is the authenticated username, never caller-asserted (FR-102 `:1263-1266`). Measured by SC-030 `:1658-1662` and SC-042 `:1674-1678`. *Note*: the item's "every refusal" was deliberately narrowed by the fourth pass — an unauthenticated refusal has no principal and is counted in a metric instead (`:1228-1230`, `:1786`) |
| CHK089 | Credentials and secrets redacted from every prompt, log, trace and transcript; no device credential as a literal anywhere | **SUPPORTED** | FR-079 `spec.md:1240-1241`; SC-031 `:1663-1665` ("zero credentials or secrets present in any trace, log or transcript, verified by scanning the corpora of SC-020 and SC-028"); the literal half is FR-019 `:835-837` (Secrets only), CR-008 `:1447-1450` ("Credentials MUST never be committed"), FR-102 `:1259-1262` and FR-106 `:1150-1160`; the generator step is `plan.md:678-680` ("so no credential is ever a literal in a manifest") |
| CHK090 | The delivery sequence builds and proves this boundary **before any agent is deployed** | **SUPPORTED** | `plan.md:672` — phase P1 is "Safety boundary, before any agent exists", ahead of P6 transport (`:809`) and P7 submission (`:826`); the phase ends `plan.md:693-694`: "At the end of this phase the guardrail exists and is proven, and **no agent has been deployed.**" The obligation is also asserted in `spec.md:1204-1206` |

---

## Reviewer's shortlist

Only the `PARTIAL`, `STALE` and `JUDGEMENT` rows, ranked by how much they matter before
implementation starts. **Every fix below is a proposal only** — the reviewer decides, and nothing
has been changed.

1. **CHK028 — success criteria that name no verification method.** *Why it ranks first*: this
   feature's entire honesty apparatus (NFR-013, SC-040, the inherited acceptance record) exists
   because criteria were declared passed by proofs nobody could reproduce. Six criteria still state
   an outcome with no method: SC-011 (`spec.md:1578`), SC-019 (`:1621`), SC-027 (`:1646`), SC-033
   (`:1671`), SC-034 (`:1682`), SC-035 (`:1686`). *Proposed fix*: append a method clause to each in
   the form SC-045/SC-046 already use ("verified by …"), without renumbering. SC-034 and SC-035 in
   particular should name the query or the alert-fire capture that counts as evidence.

2. **CHK026 — requirements that bundle many obligations.** *Why it matters*: FR-109
   (`spec.md:927-954`), NFR-003 (`:1344-1371`), FR-078 (`:1226-1239`) and FR-015 (`:800-816`) each
   carry five or more separable obligations, so "FR-109 passes" is not a statement a single test can
   make, and a task list can appear to cover a requirement while missing a clause inside it.
   *Proposed fix*: leave the numbering alone and add an obligations index — one table row per clause
   per requirement, in `data-model.md` or `traceability.md` — so each clause has an addressable
   handle for tasks and tests. Splitting the requirements themselves would violate the
   never-renumber rule the two passes have held to.

3. **CHK083 — `STATUS_UNKNOWN` is not stated to be a non-success.** *Why it matters*: it is reachable
   from any state on transport or state loss (`data-model.md:358-365`) and is the one enum value
   whose mishandling would let the tier report a request as done when it does not know. *Proposed
   fix*: one clause on FR-054 (`spec.md:1109-1111`) — "`STATUS_UNKNOWN` is never a success: a request
   in it is neither converged nor confirmed, and it is reported to the operator as an unknown outcome
   with the dependency that was lost (NFR-010)."

4. **CHK035 — no statement forbidding a second workflow engine.** *Why it matters*: the document
   forbids a second translation path (FR-060) and a second fabric-intent API (FR-013) by name, so the
   absence of the orchestration equivalent is conspicuous, and this is exactly the seam where a
   "temporary" job runner gets added during implementation. *Proposed fix*: one clause on FR-064
   (`spec.md:1164-1165`) — "Kubernetes reconciliation is the only orchestration of fabric change; no
   second workflow or job engine may sequence, retry or gate a device change."

5. **CHK020 — STALE.** The item's second clause ("no `tasks.md` is produced") is overtaken: a
   `tasks.md` exists (`spec.md:87-91`). The substantive half is intact and verified — 174 `- [ ]`
   and zero `- [x]`. *Proposed fix*: the reviewer records the clause as overtaken and evaluates the
   item as "no task is marked complete"; no document change is needed.

6. **CHK001 and CHK029 — product names in FR/NFR/SC text.** One root cause, two rows. The counts and
   citations are in the table; the question is whether naming the pinned stack inside requirements is
   intended here. *Proposed fix if the reviewer wants the item satisfied*: nothing structural — add a
   sentence to §Scope and interpretation (`spec.md:123-138`) saying the named products are the
   subject of the reference lab, are pinned as one compatibility set (FR-017) and are not
   implementation choices left open. *Proposed fix if not*: leave as is and mark both items
   not-applicable to this feature, with the reason recorded.

7. **CHK033 — two assumptions with no consequence, and no dependency block in `spec.md`.**
   `spec.md:1892-1893` and `:1911-1912`. *Proposed fix*: give each a consequence clause (for
   lab-scale concurrency: what happens when concurrency exceeds it — which the FR-062 arbitration
   edge case at `:667-670` already implies), and add a short "Dependencies" list to §Assumptions
   pointing at `platform-coupling.md` PC-S-01/PC-S-15 for upstream state.

8. **CHK022 — one bare research number.** `spec.md:1871-1872` states the packet-rate as fact where
   the record is "1000 PPS documented unlicensed, ~5 kpps measured" (`platform-coupling.md` PC-S-10).
   *Proposed fix*: match the phrasing used everywhere else — "measured in research (~5 kpps; 1000 PPS
   documented for the unlicensed container), re-observed at P0".

9. **CHK002 — JUDGEMENT.** Whether the document is "focused on operator value rather than mechanism"
   is a reviewer call, not a finding. The evidence on both sides is in the row. No fix proposed; the
   reviewer ticks or does not.

---

## Counts

| Verdict | Count |
|---|---:|
| SUPPORTED | 80 |
| PARTIAL | 8 |
| JUDGEMENT | 1 |
| STALE | 1 |
| NOT SUPPORTED | 0 |
| **Total (CHK001–CHK090)** | **90** |

`PARTIAL`: CHK001, CHK022, CHK026, CHK028, CHK029, CHK033, CHK035, CHK083.
`JUDGEMENT`: CHK002. `STALE`: CHK020.

Three rows were verified mechanically rather than by reading a claim: CHK010 (177 spec identifiers
vs 177 forward-table rows), CHK011 (149 source identifiers vs 149 reverse-table rows, against the
archived sources), CHK012 (disposition tally: 207 `carried`, 16 `merged`, 13 `retired-by-retarget`,
zero `dropped-with-reason`). CHK019 and CHK020 were also checked against the archive and `tasks.md`
respectively.

---

## Applied 2026-09-20

The operator approved applying the shortlist. All eight `PARTIAL` items are closed below. The
checklist itself was **not** touched: no box was ticked, no item reworded, nothing reordered. Every
edit was made with the locked atomic editor under an exclusive per-file lock, because five other
agents were editing the same files; each was re-read immediately before the edit and all fourteen
insertions were verified present exactly once afterwards. **Nothing was renumbered and no new FR,
NFR, SC, CR, R, T or G identifier was created.** The decision is recorded as `AD-37` in
[research.md](../../research.md) §13.

| CHK | Verdict before | What was changed, and where |
|---|---|---|
| CHK028 | PARTIAL | `spec.md` — SC-011, SC-019, SC-027, SC-033, SC-034 and SC-035 each gained a `— verified by …` clause in the style of SC-045/SC-046. Each method is taken from `plan.md` §Verification strategy and the owning task, not invented: one prompt per construct end to end (T103); a scripted browser session with nothing but the chat surface (T127); the unsupported-construct corpus with fabric state compared before and after (T143, T144); the repository-wide vocabulary scan carried by the boundary check (T142); named target-health queries plus a view load on a fresh lab, and each fault injected in turn with its alert observed to fire and clear (T134). What the criteria require is unchanged |
| CHK026 | PARTIAL | `traceability.md` — new final section **§Obligations index**, dated, stating that it reflects the requirement text as of the operator review of 2026-09-20 and that the requirement text wins over it. Four tables: FR-015(a)–(g), FR-078(a)–(g), FR-109(a)–(k), NFR-003(a)–(h), each row naming the obligation, the task that builds it and the check that asserts it. The section states in bold that the `(a)`, `(b)` labels are **index labels inside that file, not identifiers**. `spec.md` §Requirements gained one paragraph pointing at it and repeating that caveat. **The body text of FR-015, FR-078, FR-109 and NFR-003 was not edited** — those four were being reworded by other agents, and the index was composed last, after a settle window, against their then-current text |
| CHK083 | PARTIAL | `spec.md` FR-054 and `data-model.md` §17 — an indeterminate status is now stated never to be a success: it never satisfies a convergence watch (FR-067), is never counted as a converged request in the per-stage success rate (FR-092), and the operator is told the outcome is unknown, which dependency was lost (NFR-010) and that the live object is the record (FR-105). FR-054 also points at the §17 enumeration |
| CHK035 | PARTIAL | `spec.md` FR-013 — one sentence added where the second translation path and the second fabric-intent API are already forbidden: controllers reconciling these objects are the only orchestration of fabric change; no second workflow, pipeline or job engine may sequence, retry, schedule or gate a device change; no change reaches a device except by a controller reconciling one of these objects |
| CHK001 | PARTIAL | `spec.md` §Scope and interpretation — new paragraph "Why named products appear in the requirements": the named artefacts are the subject of this one pinned reference lab and members of the single compatibility set (FR-017, NFR-003); a requirement names one only where the obligation is about that artefact; platform-neutral obligations stay stated by role; `platform-coupling.md` classifies every binding. No requirement text changed |
| CHK029 | PARTIAL | Same paragraph — the success criteria that name the pinned stack (SC-002, SC-006, SC-034, SC-037) have the same root cause and are covered by the same scope statement |
| CHK033 | PARTIAL | `spec.md` §Assumptions — the lab-scale-concurrency assumption gained its consequence (concurrency is arbitrated, not engineered for; the loser of a contested identifier or attachment fails with the conflicting value named, FR-062/FR-034; no queue, fair share or throughput target may be assumed); the local-`vlan` assumption gained its consequence (carried as its own construct and its own list, never a `mac-vrf` with its overlay fields missing, FR-029); and a new assumption points at where the upstream dependency state is recorded — research §11, PC-S-01, PC-S-15 and the repository dates in `evidence/05-kubenet-sdc-kuid.md` — with the consequence of a dormant dependency stated as a pin, a gate item and a recorded fallback, never a wait |
| CHK022 | PARTIAL | `spec.md` §Assumptions — the dataplane packet-rate figure now carries both recorded numbers and their source (1000 PPS documented for the unlicensed container, ~5 kpps measured in research, `platform-coupling.md` PC-S-10) and the rule NFR-004 already applies: re-stated from what the clean-host run observes, never quoted from research |

**Deliberately not changed.**

- **CHK020 (STALE)** — rewording a checklist item belongs to the reviewer. The checklist still says
  "no `tasks.md` is produced"; `tasks.md` exists with 174 unticked boxes and none ticked. Recorded
  in `AD-37` as open rather than closed.
- **CHK002 (JUDGEMENT)** — whether the document is focused on operator value rather than mechanism
  is the reviewer's call, not a defect to fix. Untouched.
- **FR-015, FR-078, FR-109, NFR-003 body text** — out of bounds for this pass by instruction, and
  under concurrent edit. The obligations index describes them; it does not change them.

**Files edited**: `spec.md` (11 insertions across §Scope, §Requirements preamble, FR-013, FR-054,
six success criteria and §Assumptions), `data-model.md` (§17), `traceability.md` (§Obligations
index), `research.md` (`AD-37`). Every task identifier cited in the index and in `AD-37` was
verified to exist exactly once in `tasks.md` at the time of writing.
