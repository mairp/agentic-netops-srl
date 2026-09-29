# Triage of `checklists/requirements.md` — Part B (second half)

**Date**: 2026-09-20 · **Prepared for**: the human reviewer · **Prepared by**: research assistant (agent)

**Scope**: every `- [ ]` item from `## Lab, lifecycle and placement` (requirements.md:229) to the end
of the file — **CHK091 … CHK135, 45 items** — plus the non-checkbox `## Readiness result` section
(requirements.md:347-355), noted at the end of the table.

**Nothing was ticked, edited, reordered or annotated.** `checklists/requirements.md` and
`checklists/clarify-delta.md` are untouched, as is every other file in the feature. This report is
the only file written. Every verdict below is a *preparation* for the reviewer's decision, not the
decision.

**Method**: the checklist header (requirements.md:1-17) defines these as unit tests on the *quality*
of what is written. Each row therefore asks whether the document says the thing, clearly and
consistently — not whether an implementation works. Where a claim is made it carries `file:line`
citations that were actually read. Where support was not found, the row says what was searched for.

**Pin realism**: per the reviewer's instruction, no network verification was done. Version and digest
pins were checked only for internal consistency across `plan.md` §Technical Context,
`contracts/crd-api.md` §Version contract, `tasks.md` T008 and `evidence/`; their *reality* is
**resolved by `make verify-pins` at P0** (plan.md:583, 615).

**Context applied**: the checklist predates FR-102…FR-109, NFR-014, SC-042…SC-046 and CR-008, and
predates four analysis/remediation passes (spec.md:1710-1788; research.md §13 AD-01…AD-30). Items were
read against the *current* text, so several are satisfied, and two are broken, by wording that did not
exist when the item was written.

---

## Verdicts

| Item | Line | What it asks (abbrev.) | Verdict | Note |
|---|---|---|---|---|
| CHK091 | 231 | One pinned cluster, declaratively configured, is the sole application runtime | **SUPPORTED** | FR-006 `spec.md:743-745` (pinned Kind release + node image, stable name, declarative cluster config); FR-007 `spec.md:746-753` (every listed component "MUST run inside the Kind cluster"); FR-009 `spec.md:760-762` |
| CHK092 | 232 | One provisioning path and one shutdown path cover the whole platform, tier included | **SUPPORTED** | FR-010 `spec.md:763-770` — "the primary lifecycle interface for the whole platform, **including the intent tier**", tier selection by flag; two scripts only, `plan.md:341` (`provision.sh [--with-intent-tier]` / `off.sh [--purge-intent-tier]`) |
| CHK093 | 233 | Both idempotent, partial-state tolerant, ownership-checked | **SUPPORTED** | FR-010 `spec.md:763-770` ("idempotent … refuse to delete resources they do not own"); SC-003 `spec.md:1524-1526` (succeeds from fully provisioned *and partially failed* states; second run a no-op) |
| CHK094 | 234 | Containerlab limited to network and endpoint nodes | **SUPPORTED** | FR-008 `spec.md:754-759` ("MUST remain responsible only for SR Linux nodes and Linux traffic endpoints"); FR-001 `spec.md:716-719` |
| CHK095 | 235 | Dedicated mgmt network; configurable space; checked against every Docker network, pod and service network | **SUPPORTED** | FR-008 `spec.md:754-759` — all four clauses present, including "an overlap MUST fail preflight with the colliding network named" |
| CHK096 | 238 | Configuration, Secrets, RBAC, state, dashboards and alerts are Kubernetes resources | **SUPPORTED** | FR-009 `spec.md:760-762` ("Application state, Secrets, RBAC, dashboards, **rules** and datasources"); FR-019 `spec.md:835-837`; FR-096 `spec.md:1326-1331`. Minor: the item's word "alerts" appears as "rules"; FR-087 `spec.md:1277-1279` requires "actionable alerts" |
| CHK097 | 240 | Standalone/Compose/host-side forbidden **without exception**; no component outside the cluster may read or write device configuration; predecessor executor recorded as the defect | **STALE** | The premise was narrowed by the first analysis pass (AD-03, `research.md:2048`). FR-007 `spec.md:746-753` now scopes the absolute to "no **platform** component outside the cluster", and FR-108 `spec.md:914-926` explicitly allows the capability gate, fault/drift injection and the walkthrough proofs to **open a management session from the operator's host and write scratch configuration**. The item's literal "no component" no longer holds. The second half *is* supported: the predecessor's host-side executor is recorded as the defect, not a carried exception, at `platform-coupling.md:127-134, 149-154` and `spec.md:111` |
| CHK098 | 247 | Telemetry pipeline, metrics store and dashboards all required | **SUPPORTED** | FR-087 `spec.md:1277-1279`; CR-005 `spec.md:1438-1440` |
| CHK099 | 248 | Metrics store identified as storage; collector is a pipeline | **SUPPORTED** | FR-088 `spec.md:1280-1282` — "Prometheus MUST be the metrics store. This specification MUST NOT claim the OpenTelemetry Collector stores telemetry" |
| CHK100 | 249 | Durable logs and traces require an explicit later addition | **SUPPORTED** | FR-088 `spec.md:1282` — "out of scope unless a log store and a trace store are added explicitly" |
| CHK101 | 250 | One device collector; overlapping subscription ingestion disabled for the same series; session limit sized for both | **SUPPORTED** | FR-086 `spec.md:1273-1276` (all three clauses, incl. "whose session limit MUST be sized explicitly for the two together"); FR-089 `spec.md:1283-1295`; PC-S-04 `platform-coupling.md:195` |
| CHK102 | 252 | One emission per activity, fanned out to two sinks, never two instrumentations | **SUPPORTED** | FR-091 `spec.md:1298-1302` — "two independent instrumentations of the same activity are non-conforming" |
| CHK103 | 253 | Versioned topology asset generated from lab inventory in the same step as the collector target list; identifiers verified against live metric queries | **SUPPORTED** | FR-096 `spec.md:1326-1331` ("**and the device metric collector's target list** from the same containerlab inventory in the same step, before readiness"; assets pinned); SC-036 `spec.md:1688-1690` (node/link set matches metadata, values match direct metric queries) |
| CHK104 | 255 | Physical view and EVPN service-path view; join is a named label set; visualization reference adds no runtime dependency | **SUPPORTED** | FR-094 `spec.md:1309-1323` — both views, the join is "**exactly two registered labels** … `source` and `interface_name`", and the reference lab is "visualization and generator reference only" with everything vendored and pinned; SC-017(b) `spec.md:1602-1614` |
| CHK105 | 258 | Telemetry outage is observable but cannot control or block network configuration | **PARTIAL** | *Observable* is supported: `spec.md:696-702` (Observability edge cases — stale series shown absent, duplicate series a failure, backpressure). *Cannot block* is stated **only in the data model**: `data-model.md:945-946` — "`Degraded=True` may coexist with network readiness only for a non-blocking telemetry failure, with the distinction in the reason." Searched `spec.md` for "telemetry outage", "must not block", "cannot block" and read FR-086 to FR-096 and NFR-002: **no requirement says the telemetry path is never in the configuration or readiness path.** The property is true by construction (readiness reads device state via FR-100/FR-015, not via telemetry) but is not written as an obligation |
| CHK106 | 259 | Correlation identifier joins agent activity, reconciliation and device telemetry both ways, no timestamp correlation | **SUPPORTED** | FR-093 `spec.md:1306-1308` ("join without timestamp correlation"); FR-090 `spec.md:1296-1297`; SC-039 `spec.md:1696-1698`; PC-N-09 `platform-coupling.md:89` |
| CHK107 | 264 | TLS, Secrets, least-privilege RBAC, redaction, lab-credential limitations covered | **SUPPORTED** | FR-019 `spec.md:835-837` (Secrets + per-controller RBAC + "lab defaults MUST never be presented as production-safe"); FR-079 `spec.md:1240-1241` (redaction); FR-102 `spec.md:1259-1272`; TLS on the southbound `plan.md:177-181` |
| CHK108 | 266 | Privileged containers and host runtime access are documented trust boundaries; no hypervisor / nested virtualization implied | **PARTIAL** | The *no-hypervisor* half is well supported: `spec.md:169-170` (User Story 1), NFR-004 `spec.md:1372-1377` ("on a documented Linux host with a container runtime **and no hypervisor**"), `plan.md:138`, `quickstart.md:34`. The *privileged-runtime trust boundary* half appears **only in plan.md**: `plan.md:232` ("a privileged lab runtime as a documented trust boundary") and risk R-08 `plan.md:1072`. Searched `spec.md` for "privileged", "host runtime", "trust boundary": no FR, NFR or assumption names it |
| CHK109 | 268 | Break-glass finalizer behaviour and orphan risk, including the deletion ordering a bound filter imposes | **SUPPORTED** | FR-103 `spec.md:877-888` — finalization blocks, allocations stay claimed, the only exit is an annotated force-release that publishes an Event and leaves a durable finding "stating that the device may still carry stale configuration"; FR-043 `spec.md:1050-1061` — "Withdrawal MUST remove the binding before the filter, and a service whose attachment still carries another service's access list MUST NOT finalize until that list is withdrawn, surfacing the holder by name"; conditions at `data-model.md:930-940` |
| CHK110 | 270 | No credential literal appears in any manifest, **and CI enforces it** | **PARTIAL** | The rule is asserted in four places — FR-019 `spec.md:835-837`, CR-008 `spec.md:1447-1450`, `plan.md:231`, `plan.md:304`, `plan.md:679`, `quickstart.md:275`. The **CI carrier is missing**: the make-target table at `plan.md:580-590` lists `verify-pins`, `verify-upstream-artefacts`, `verify-render-schema`, `verify-compat`, `verify-boundaries`, `verify-provenance-headers`, `verify-evidence`, `verify-readme` — none is a credential-literal or secret scan — and searching `tasks.md` for `gitleaks`, "secret scan", "credential … manifest" returns no implementing task. Contrast SC-017 `spec.md:1602-1614`, where the analogous boundary *does* name its CI deny-list |
| CHK111 | 274 | User stories independently testable and prioritized | **SUPPORTED** | All twelve live stories carry `(Priority: Pn)` and an `**Independent Test**` paragraph — e.g. US1 `spec.md:164, 174`; US2 `209, 219`; US13 `559, 569`. US3 is the retired tombstone `spec.md:240-250`. US1's independent test was made self-standing by the first pass (`spec.md:1720`) and rewritten again by AD-23 (`spec.md:1770`) |
| CHK112 | 275 | Functional and non-functional requirements are unambiguous | **JUDGEMENT** | Only a human can rule on ambiguity across 109 FRs and 14 NFRs. Relevant input for the reviewer: `checklists/clarify-delta.md` §Requirement Clarity (its CHK014-CHK020, lines 73-98) already raises specific ambiguity questions against FR-102, FR-105, FR-108, FR-109 and NFR-014 — the two checklists should be ruled on together |
| CHK113 | 276 | Success criteria map to quickstart evidence | **SUPPORTED** | Two directions exist. `plan.md:962-1010` §Verification strategy maps **every** SC to a runnable check; `quickstart.md` carries `**Proves**: SC-…` lines per section — `178, 212, 253, 309, 332, 380, 400, 485, 526, 576, 1015, 1339` — including the retired SC-009/SC-010 marked as such at `plan.md:975-976` |
| CHK114 | 277 | Spec, plan, data model, contracts and quickstart use one set of component names and one ownership model | **PARTIAL** | *Ownership model*: single and explicit — FR-101 `spec.md:1332-1339` (one owner per key; the provider stamps `Config`, never the service intent object), mirrored at `contracts/crd-api.md:379` and `contracts/kubernetes-objects.md`. *Component names*: two registers. `spec.md` uses role names throughout ("the device-configuration layer", "the allocation authority", "the metrics store", "the device metric collector"); `plan.md`, `tasks.md` and the contracts use product names (SDC/sdcio, KUID, Prometheus, gNMIc). `plan.md:143-161` supplies the mapping, but `spec.md` §Scope and interpretation (`123-148`) contains no glossary and does not cite it, so a reader of the spec alone cannot join the two. This is deliberate (it is what CHK001 asks for) but it means "one set of names" is literally false |
| CHK115 | 279 | Research distinguishes verified upstream capability from proposed platform work; every rejected alternative preserved | **PARTIAL** | The *distinction* is strongly supported: `research.md:2495-2583` §Open items carried to P0 (17 named unknowns, each tied to a gate item and a risk), the "**Not assumed**" markers at `research.md:1855, 2162`, and the closing paragraph `research.md:2580-2583` ("Every lab measurement this record cites was taken in research on a throwaway lab … Each is **re-observed at P0**"). The *preservation* half cannot be verified from inside this folder: only 9 of the 37 inherited `D-xx` entries (`research.md:29-1025`) carry an "Alternatives rejected" block, and 7 of the 30 `AD-xx` entries do. Whether anything was lost in the merge needs the three source research files, which are not here |
| CHK116 | 281 | Constitution gate evaluates all six principles by name, with a verdict and a reason each | **SUPPORTED** | `plan.md:295-301` — Principles I to VI each named, each with a verdict and a multi-sentence reason. Two verdicts are honestly qualified ("**PASS — by obligation, nothing observed yet**", V and VI), and `plan.md:289-293` states why. Source cited as v1.1.0 at `plan.md:285` |
| CHK117 | 289 | Every `platform-coupling.md` row carries a disposition and, where not `unchanged`, a resolution naming RD decision, requirements and evidence | **SUPPORTED** | Disposition vocabulary defined `platform-coupling.md:27-35`; rows PC-01…PC-21 `48-68`, PC-N-01…PC-N-17 `81-97`, PC-A-01…PC-A-13 `105-117`. Every non-`unchanged` row names an RD, a "Carried by" requirement list and an `evidence/…` section (e.g. PC-01 `:48`, PC-09 `:56`, PC-A-06 `:110`) |
| CHK118 | 292 | No predecessor-platform term in live requirement text; every remaining grep hit is provenance/history | **SUPPORTED** | The item's grep was run verbatim. Every hit outside the three expected files is a labelled provenance column or a *negation*: `spec.md:10, 18, 22, 39, 57, 59, 79, 98-101, 129` (§Provenance and §Inherited acceptance record), `spec.md:169` / `plan.md:138` / `quickstart.md:34` (negations of KVM and nested virtualization), `plan.md:112`, `plan.md:922` (predecessor tooling being ported), `data-model.md:93, 279`, `research.md:1957-1966`, `contracts/readme-and-walkthrough.md:30, 35, 48-49, 68-70, 87` (all "Predecessor \| This platform" table columns). **Note for the reviewer**: the item's parenthetical — that those three files are "the only files where such terms are expected" — does not hold literally; six live files carry labelled predecessor columns by design |
| CHK119 | 297 | Every retired identifier resolves: number kept, tombstone, source mapping, listed in §Nothing dropped, obligation located | **SUPPORTED** | `traceability.md:752-777` — §Nothing dropped lists all eight retired ids with the source they still resolve, the retiring decision (RD-04) and where the obligation went, including FR-003's salvaged dual-stack half. Tombstones in place at `spec.md:240` (US3), `727` (FR-003), `741` (FR-005), `847`, `849`, `851` (FR-021…023), `1571`, `1573` (SC-009/010); §Deferred scope `spec.md:1827-1842`. Reverse-table rows at `traceability.md:475-479` carry `retired-by-retarget` |
| CHK120 | 300 | The six open merge decisions are decided; each names its carrying requirements; none answered by prose no requirement enforces | **SUPPORTED** (one caveat) | `spec.md:1789-1811` — table of six with a "Carried by" column: FR-007/014/015; FR-012/013/014/098; tombstones; FR-035…043; FR-029/099; FR-094/SC-017(b). Full records RD-01…RD-15 at `research.md:1026-1775`. **Caveat**: row 3 (SRv6) is carried by "tombstones" plus §Deferred scope, not by a live requirement — the right shape for a deferral, but the one row that cannot satisfy the item's own test on its own terms |
| CHK121 | 302 | Each of the six gaps closed by **exactly one** carrying requirement or a named deferral; mapping in one place | **PARTIAL** | The mapping is in one place — `spec.md:1812-1826`. GAP-1→FR-097, GAP-3→FR-101, GAP-4→FR-043, GAP-6→FR-100 are each exactly one; GAP-5 is a named deferral. **GAP-2 names two** — `spec.md:1821`: "FR-046, FR-048". Reading FR-046 `spec.md:1074-1077` and FR-048 `spec.md:1081-1088`, FR-046 is the single provenance record and FR-048 only *references* it, so the intent is one carrier — but the table as written fails the literal "exactly one" |
| CHK122 | 304 | Every RD records decision, rationale, **evidence citation** and alternatives rejected; disagreement with evidence stated, not smoothed | **SUPPORTED** | `research.md:1026-1775` §11 — all fifteen RD entries carry Decision / Rationale / Evidence / Alternatives rejected / Consequences (RD-01 `1035-1097`; RD-15 `1739-1771`). Disagreement is stated rather than smoothed: `platform-coupling.md:56` (PC-09 — "The research recommendation of `rank×10` was **rejected**"), `platform-coupling.md:85` (PC-N-05 — "**This row was wrong, and saying so is the point of keeping it**"). Note: RD-14 `research.md:1705` and RD-15 `research.md:1739` cite `spec.md` sections rather than an `evidence/` report, being decisions about this document |
| CHK123 | 307 | No invented digest/version/YANG path; every digest also in `evidence/` or the RD record; unknown digests stated as pinned at the first phase, never a placeholder | **SUPPORTED** | Every `sha256:` string in `spec.md`, `plan.md`, `research.md`, `tasks.md`, `contracts/` and `platform-coupling.md` also occurs in `evidence/01-lab-platform.md` or `evidence/05-kubenet-sdc-kuid.md` (checked exhaustively). No placeholder or synthetic digest exists anywhere; NFR-003 `spec.md:1344-1371` forbids one outright, and the only "placeholder" occurrences are the prohibitions themselves (`contracts/crd-api.md:111, 467`, `quickstart.md:95`) or the predecessor defect record (`spec.md:107`, `platform-coupling.md:178`). Un-quoted pins are explicitly deferred: `plan.md:160-161`, `contracts/crd-api.md:88-89`. **Pin realism is resolved by `make verify-pins` at P0** (`plan.md:583, 615`), not here |
| CHK124 | 311 | Gate covers every construct **and every gated property**; result published per construct and property where the tier reads it; unqualified refused at interpretation by name | **SUPPORTED** (one caveat) | FR-004 `spec.md:730-740` (twelve-item gate incl. "its result is recorded per construct"); FR-097 `spec.md:853-857` ("per construct and per gated property … published where the intent tier can read it … refused at interpretation, naming what is unqualified, before any identifier is claimed"); the record is a mounted ConfigMap — `contracts/kubernetes-objects.md:40, 65`; refusal path — `contracts/reconciliation.md:16, 44, 278`, `contracts/construct-vocabulary.md:144`, `contracts/crd-api.md:159`; gate items G1-G12 `plan.md:627-640`. **Caveat**: the *set* of "gated properties" is never enumerated closed — `egress` is the only one named (`data-model.md:323, 539`, PC-S-14 `platform-coupling.md:205`), so "every gated property" is asserted rather than listed |
| CHK125 | 315 | Every applied-side read-back **keyed** to this service's objects; no fabric-wide or device-wide counts; each check has a recorded negative control | **SUPPORTED** | FR-100 `spec.md:863-876` ("Every applied-side read MUST be keyed to this service's own objects; a fabric-wide or device-wide count is never evidence"); FR-042 `spec.md:1040-1049`; NFR-013 `spec.md:1402-1408` (a check counts only after it has been shown to **fail** on a stock fabric); SC-040 `spec.md:1701-1704`; negative-control procedure `quickstart.md:653`; the predecessor defect this closes `platform-coupling.md:179`. **AD-23 strengthened this item**: `spec.md:1770` and `research.md:2351` removed the last unkeyed count (fabric-wide EVPN routes) from fabric-design readiness |
| CHK126 | 319 | Evaluation order, usable priority range and unmatched-traffic behaviour stated in requirement, contract, data model and quickstart alike | **SUPPORTED** | Requirement: FR-039 `spec.md:1017-1026`, FR-041 `spec.md:1033-1039`, FR-083 `spec.md:1251-1253`, entity `spec.md:1496`, scenario `spec.md:330-332, 341`. Contract: `contracts/acl-render-contract.md:72, 91-102, 242`; `contracts/construct-vocabulary.md:105, 110, 141`. Data model: `data-model.md:405-408, 561, 1037-1038`. Quickstart: `quickstart.md:357, 559-560`. Note: `spec.md` states the *order* and *requires* the usable range be stated to the operator without naming 1–65534/65535 — deliberate, per the PC-N-05 lesson `platform-coupling.md:85`, and consistent with CHK001 |
| CHK127 | 322 | The MTU numbers are identical in `spec.md`, `plan.md`, `data-model.md`, `quickstart.md` and the constitution | **PARTIAL** | Wherever the numbers appear they agree exactly — port max **9412**, fabric link **9412**, underlay IP **9398**, tenant over VXLAN **9348**, probes **9320 (IPv4)** / **9300 (IPv6)**, endpoint interface **9348**: `constitution.md:19-20, 186-190`; `plan.md:215-221, 635`; `data-model.md:165-168, 1060-1067`; `quickstart.md:143, 694-702`; `contracts/readme-and-walkthrough.md:165-166`; `contracts/crd-api.md:283`. **But `spec.md` contains none of them** (grep for 9412/9398/9348/9320/9300 in spec.md → 0 hits). It speaks only of "the tenant MTU the fabric actually carries" (FR-002 `spec.md:720-726`), "the MTU envelope" (FR-004 `spec.md:730`) and "the tenant MTU boundary" (SC-005 `spec.md:1536-1539`). The item's "identical in spec.md" is therefore not evaluable — a direct tension with CHK001, which forbids exactly this kind of detail in FR/NFR/SC text |
| CHK128 | 325 | Mgmt CIDR default, device and endpoint addresses and device port list identical in `spec.md`, `plan.md`, `quickstart.md` and the Kubernetes-objects contract; denial enumeration names the same ports the lab image is documented to open | **PARTIAL** | **(a) Addresses agree** across `plan.md:343`, `data-model.md:47`, `quickstart.md:44, 110`, `contracts/kubernetes-objects.md:150`, `platform-coupling.md:110` — `172.25.25.0/24` (`MGMT_CIDR`), devices `.11 .12 .21 .22`, clients `.101 .102`. As with CHK127, **`spec.md` states none of them**: FR-008 `spec.md:754-759` says "configurable" with no default, FR-075 `spec.md:1208-1220` names ports descriptively ("the encrypted management port, the plaintext management port the lab image also exposes"). **(b) The port enumerations do NOT match, twice.** (i) `quickstart.md:792` dials `57400 57401 22 443 830` — **port 80 is missing**, while `plan.md:400` and `contracts/kubernetes-objects.md:135` both list 80/443. (ii) PC-S-03 `platform-coupling.md:194` documents the image as also exposing **SNMP 161** and the vendor automation ports **50052 / 57410 / 57411**; none of these appears in any denial enumeration — `contracts/kubernetes-objects.md:132-141` says the image "also listens on `57401`, `22`, `80`, `443` and `830`" (contradicting PC-S-03) and then calls a port-only denial "four open doors" while listing five. The NetworkPolicy denies the whole CIDR, so the *security* property is not at risk; what fails is the *enumerated, attemptable* denial that FR-075 / SC-028 / CHK086 rest on |
| CHK129 | 328 | Compatibility set identical part for part in `plan.md`, `research.md` and `contracts/crd-api.md` | **PARTIAL** | `plan.md:143-161` and `contracts/crd-api.md:71-86` agree on all nine parts, value for value. `research.md` states parts 1-6 and 8 (RD-01 `research.md:1035-1044`; RD-03 `research.md:1110-1123, 1174`; RD-11 `research.md:1571`) but **carries no pin for part 7 (containerlab `0.79.0`) or part 9 (`srl-mapping v0.1.0`)** — neither string occurs in `research.md` at all. So two of nine parts are present in two files and absent from the third, which is exactly what the item tests. (Pin *realism*: `make verify-pins` at P0.) |
| CHK130 | 330 | Constitution version cited is **v1.1.0** everywhere; no file cites the pre-amendment version or its removed known-limitation clause | **SUPPORTED** | `plan.md:285`, `spec.md:1419`, `tasks.md:38`, `traceability.md:255`, `research.md:1566` — all v1.1.0; the constitution itself is `**Version**: 1.1.0` (`constitution.md:254`). No `v1.0.0` citation anywhere in the feature folder. The removed FRR IPv6-IRB known limitation survives only as the `deleted` row PC-17 `platform-coupling.md:64`; its replacement is `constitution.md:195` and gate item G8 |
| CHK131 | 332 | Node names, count, hardware types, containerlab kind and interface naming identical everywhere | **SUPPORTED** | Six nodes `spine01/spine02/leaf01/leaf02/client01/client02`, kind `nokia_srlinux`, `ixr-d3l` spines / `ixr-d2l` leaves, native `ethernet-1/N` with `e1-N` Linux-side — consistent across `spec.md:716-726`, `plan.md:195-201`, `research.md:1040-1050`, `data-model.md`, `quickstart.md`, `tasks.md`, all contracts and `platform-coupling.md:105`. Metric-label join `source` / `interface_name` (`ethernet-1/49 → e1-49`) agrees at FR-094 `spec.md:1318-1320` and PC-A-09 `platform-coupling.md:113`. The only `Ethernet8`, `ethernet1` and `srv6-client0N` occurrences are provenance columns (`platform-coupling.md:105`, `research.md:1959-1961`, `contracts/readme-and-walkthrough.md:68-70`); `ixr-h*` appears only as the excluded types |
| CHK132 | 335 | The couplings the new platform introduces are inventoried too | **SUPPORTED** | `platform-coupling.md:183-205` §New couplings the SR Linux platform introduces — PC-S-01…PC-S-15, each with a class, a "Carried by" requirement list, an evidence section and a "why it bites" note; the §-intro at `183-189` states the purpose the item names ("so that the next platform move … starts from a complete inventory") |
| CHK133 | 337 | Nothing claims observation; research numbers attributed and marked for re-observation; no gate, probe or counter reported as passed | **SUPPORTED** | `research.md:2495-2583` §Open items carried to P0 — seventeen unknowns, each tied to a gate item and a risk — closing with "Every lab measurement this record cites was taken in research on a throwaway lab … Each is **re-observed at P0**" (`2580-2583`); `plan.md:289-293` ("There is nothing here to have passed or failed") and the two qualified verdicts `plan.md:300-301`; NFR-004 `spec.md:1372-1377` ("observed by a clean-host run and taken from its evidence, **never quoted from research**"); `research.md:1080, 1557` ("re-observed at P0"); the checklist's own §Readiness result `requirements.md:347-355` |
| CHK134 | 340 | Every dormant upstream dependency qualified at the first phase, with a named first-party fallback behind the same contract, chosen explicitly | **SUPPORTED** | One dormant dependency exists: the allocation authority. FR-104 `spec.md:889-903` (gate failure stops provisioning; the one permitted substitution is first-party, adopted by a recorded operator decision, same claim semantics, never coexisting, recorded in the compatibility set and warned at provisioning); PC-S-15 `platform-coupling.md:205`; gate item G11 `plan.md:638`; Open item 10 `research.md:2540-2547`; CD-03 `research.md:1874`. The other dormant upstream project (the fabric control plane) is **not a dependency** — RD-03, `platform-coupling.md:155-159` ("a **reference design only**") |
| CHK135 | 343 | The two device-matching construct names **required** to match, asserted in CI against the pinned device model; the other two documented as operator vocabulary | **PARTIAL** | The requirement says exactly this: FR-099 `spec.md:991-998` — "MUST remain identical … **asserted in CI against the pinned device model** … `vlan` and `acl` are operator vocabulary and are documented with the device objects they render", backed by `contracts/construct-vocabulary.md:27, 115-128` and task T140 `tasks.md:496`. **But no CI carrier exists.** The make-target table `plan.md:580-590` contains no such check, and the only vocabulary scan — T142 `tasks.md:498`, `scripts/ci/verify_vocabulary.sh` — is the **SC-033 retired-name scan** over prompts, refusal strings, the UI bundle, docs and dashboards, not an assertion against the pinned device YANG. Contrast FR-017's path register, which *does* name its CI guard (`spec.md:820-829`) |
| *(§Readiness result)* | 347-355 | Not a checkbox item — the status paragraph | **STALE** (informational) | Its content still matches the document's honesty posture (`spec.md:7` Status `Draft`; `spec.md:85`; inherited acceptance record `spec.md:72-122`). But it was written at the second pass and never updated: it does not mention the 2026-09-20 clarify session (`spec.md:152-161`) or the four analysis/remediation passes (`spec.md:1710-1788`), and it predates FR-102…FR-109, NFR-014, SC-042…SC-046 and CR-008. Since the checklist is reviewer-owned, this is reported, not changed |

### Counts

| Verdict | Count |
|---|---|
| SUPPORTED | 33 |
| PARTIAL | 10 |
| NOT SUPPORTED | 0 |
| STALE | 1 (CHK097) |
| JUDGEMENT | 1 (CHK112) |
| **Total checkbox items triaged** | **45** (CHK091–CHK135) |

Plus one informational STALE note on the non-checkbox `## Readiness result` section.

---

## Coverage of the identifiers added after this checklist was written

`requirements.md` names only six identifiers anywhere in its text — FR-042, FR-097, FR-100, NFR-003,
NFR-013, SC-040 — all of them retarget-era ids that existed when it was written. **None of the fifteen
later identifiers has any item in `requirements.md`**, which `clarify-delta.md:6` states outright
("`requirements.md` carries no item for any of these ids").

| Identifier | Item in `requirements.md`? | Covered by `clarify-delta.md`? (item ids) |
|---|---|---|
| FR-102 | **No** | Yes — CHK004, CHK014, CHK025, CHK034, CHK039 (+ CHK028 via SC-042) |
| FR-103 | **No** | Yes — CHK001, CHK002, CHK003, CHK029, CHK034, CHK039 |
| FR-104 | **No** | Yes — CHK012, CHK013, CHK027, CHK034, CHK039 |
| FR-105 | **No** | Yes — CHK010, CHK015, CHK016, CHK017, CHK032, CHK034 |
| FR-106 | **No** | Yes — CHK005, CHK027, CHK034, CHK035 |
| FR-107 | **No** | Yes — CHK006, CHK007, CHK021, CHK026, CHK030, CHK034 |
| FR-108 | **No** | Yes — CHK008, CHK018, CHK027, CHK034 |
| FR-109 | **No** | Yes — CHK009, CHK010, CHK011, CHK013, CHK019, CHK023, CHK024, CHK033, CHK034, CHK036 |
| NFR-014 | **No** | Yes — CHK020, CHK027 |
| SC-042 | **No** | Yes — CHK028, CHK031 (+ CHK025 on export/removal ordering) |
| SC-043 | **No** | Yes — CHK029, CHK031 |
| SC-044 | **No** | Yes — CHK021, CHK030, CHK031 |
| SC-045 | **No** | **Weakly** — named by no item; reached only through CHK031's range "SC-042…SC-046" (`clarify-delta.md:136`) and indirectly through the FR-109 items |
| SC-046 | **No** | **Weakly** — same: only through CHK031's range (`clarify-delta.md:136`) |
| CR-008 | **No** | **No** — `CR-008` occurs in `clarify-delta.md` only in the header's purpose statement (`clarify-delta.md:4`). **No item in either checklist reviews CR-008** |

**What this tells the reviewer**: the two checklists together cover the whole spec with three
exceptions. **CR-008 is reviewed by neither.** SC-045 and SC-046 are reviewed only by the generic
negative-control question CHK031, which asks one thing of five criteria at once. `clarify-delta.md`
anticipates precisely this — its own CHK040 (`clarify-delta.md:172-174`) asks whether `requirements.md`
needs counterpart items "so that no id is reviewed by neither". The answer this triage supports is:
for CR-008, yes.

Note also that four of the ten PARTIAL findings below concern *older* identifiers, so the delta
checklist would not have caught them; and CHK097 is broken by FR-108, which the delta checklist covers
for FR-108's own quality (CHK008, CHK018) but not for its effect on CHK097's premise.

---

## Reviewer's shortlist

Ranked by how much each matters **before implementation starts**. Every "proposed fix" below is a
**proposal only** — nothing has been applied, and the checklist has not been marked.

**1. CHK128(b) — the denial port enumeration disagrees with itself and with PC-S-03.** *(highest)*
The safety boundary's whole claim is that denial is *attemptable and enumerated* (CHK086, FR-075
`spec.md:1208-1220`, SC-028 `spec.md:1648-1654`). Three surfaces give three different port lists:
`quickstart.md:792` omits 80; `contracts/kubernetes-objects.md:140-141` lists five ports and says
"four open doors"; PC-S-03 `platform-coupling.md:194` documents SNMP 161 and 50052/57410/57411 as
also open, and no probe dials them. A boundary test written from the quickstart would silently prove
less than the spec claims.
*Proposed fix (proposal only)*: pick one canonical port list, derive it from PC-S-03, and state it in
exactly one place that the other two cite — then correct `quickstart.md:792` (add 80) and the "four
open doors" sentence. If 161 and the vendor ports are deliberately out of the probe, say why there.

**2. CHK097 — the item's absolute no longer matches FR-007 + FR-108.** *(high)*
This is a genuine STALE, not a defect in the spec: AD-03 (`research.md:2048`) narrowed FR-007 to
"platform component" and created FR-108 to bound the tools that check it. But a reviewer ticking
CHK097 as written would be asserting something the spec now contradicts.
*Proposed fix (proposal only)*: the reviewer restates CHK097 in two parts — "no *platform* component
outside the cluster reads or writes device configuration (FR-007), and every non-platform exception
is bounded by name (FR-108)" — and records that the predecessor-executor half is satisfied at
`platform-coupling.md:127-154`.

**3. CHK110 — "and CI enforces it" has no carrier.** *(high)*
Every other absolute in this document names its CI check. A credential-literal rule with no scan is
exactly the shape of the predecessor defect the retarget was supposed to prevent by rule rather than
by care.
*Proposed fix (proposal only)*: add a `verify-secrets` (or fold into `verify-boundaries`) make target
to `plan.md:580-590` and a task to `tasks.md`, carried by FR-019/CR-008.

**4. CHK135 — FR-099's "asserted in CI" has no carrier either.** *(high)*
FR-099 is the requirement that makes RD-06 real rather than a coincidence. Without a check against
the pinned YANG, a device release that renames its instance types would break the promise silently.
*Proposed fix (proposal only)*: name the assertion — a check that reads the pinned
`srlinux-yang-models` network-instance type identities and fails if `mac-vrf` / `ip-vrf` no longer
match — and add it to the make-target table and to `tasks.md` alongside T142.

**5. CHK129 — two of nine compatibility-set parts are missing from `research.md`.** *(medium-high)*
The set is the thing a release bump must move as one unit (PC-S-01 `platform-coupling.md:192`). A
part that lives in two of three files is a part that can drift.
*Proposed fix (proposal only)*: add containerlab `0.79.0` and `srl-mapping v0.1.0` to RD-01's decision
paragraph (`research.md:1035-1058`), or have RD-01 cite `contracts/crd-api.md:75-86` as the single
authoritative table.

**6. CHK127 / CHK128(a) — the spec deliberately carries none of the concrete values.** *(medium; needs a ruling, not a fix)*
Both items name `spec.md` as a file the numbers must be identical in; `spec.md` states none of them,
because CHK001 forbids that detail in requirement text. The values are otherwise perfectly consistent.
*Proposed resolution (proposal only)*: the reviewer rules once that CHK127 and CHK128 mean "identical
wherever they appear, and `spec.md` is required to name the *property* rather than the *number*", and
records the ruling next to CHK001. No document change needed.

**7. CHK105 — the non-blocking rule lives only in the data model.** *(medium)*
"A telemetry outage cannot block network configuration" is an operator-visible safety property with no
requirement behind it; only `data-model.md:945-946` states it.
*Proposed fix (proposal only)*: one clause in FR-086 or NFR-002 — telemetry is never in the
configuration, reconciliation or readiness path, and a telemetry failure sets `Degraded` without
affecting network readiness.

**8. CHK108 — the privileged-runtime trust boundary is only in `plan.md`.** *(medium)*
`plan.md:232` and R-08 `plan.md:1072` document it; no FR, NFR or assumption in `spec.md` does.
*Proposed fix (proposal only)*: add it to `spec.md` §Assumptions beside the existing dataplane and
disposable-cluster assumptions, or to NFR-004 which already states the host requirements.

**9. CHK121 — GAP-2 names two carriers where the item asks for exactly one.** *(low)*
Substantively fine (FR-046 is the record; FR-048 references it) but the table reads as two.
*Proposed fix (proposal only)*: reword `spec.md:1821` to "FR-046 (FR-048 references it)".

**10. CHK114 / CHK115 — two items the document cannot answer on its own.** *(low, but decide before implement)*
CHK114: no glossary joins the spec's role names to the plan's product names — a reader of `spec.md`
alone cannot resolve "the allocation authority" to KUID. *Proposed fix*: a five-row naming key in
`spec.md` §Scope and interpretation, or an explicit pointer to `plan.md:143-161`.
CHK115: "every rejected alternative preserved" needs the three source research files, which are not in
this folder. *Proposed resolution*: the reviewer records CHK115 as answerable only against 001/002/003,
or narrows it to the retarget-era decisions, where all fifteen RDs do carry the block.

**Also for the reviewer, from the coverage table**: **CR-008 has no item in either checklist.** Before
implement, either add one item to `clarify-delta.md` (reviewer-owned, so the reviewer adds it) or
record that CR-008 is reviewed through its carriers FR-019 / FR-079 / FR-102 / FR-106. The same call is
worth making for SC-045 and SC-046, which only CHK031's range reaches.

---

*Prepared without modifying any existing file. No checklist marker was changed. Every verdict is
evidence the reviewer can re-read at the cited lines; the decision is the reviewer's.*

---

## Applied 2026-09-20

The operator approved applying the shortlist. Every edit below was made with the locked atomic
editor. **`checklists/` was not touched and no marker was ticked** (`requirements.md` md5
`a85b0f85…`, `clarify-delta.md` md5 `a0f1554a…`, both unchanged). No identifier was added or
renumbered. `evidence/`, the constitution and other agents' reports were not modified. The decision
record is **research.md §13 AD-38**.

### CHK128 — one denied-management-port list, stated once and cited everywhere *(led)*

The authoritative list now lives in **`contracts/kubernetes-objects.md` §Identity contract**, taken
from `evidence/01-lab-platform.md` §4.2: **TCP 22, 80, 443, 830, 50052, 57400, 57401, 57410, 57411
and UDP 161**.

| File | Change |
|---|---|
| `contracts/kubernetes-objects.md` | Denial table gains a row for 50052/57410/57411 and a UDP 161 row; the prose becomes the single authoritative list, names the four surfaces that cite it, and adds two honesty notes (UDP has no timeout signal; the list is documentation, not an observation of the pin). "four open doors" → "nine open doors"; "the port set is the five above" → "the ten above" |
| `platform-coupling.md` | PC-S-03 becomes the *inventory* and points at the contract for the probe set; records that §4.2 was probed on a later release and that the same report's CPM-ACL baseline allows Telnet/23 with no listener, so G2 reconciles. PC-A-06 cites the contract instead of restating five ports |
| `quickstart.md` §15 | Probe loop corrected to all nine TCP ports (80 was missing); a separate recorded UDP 161 attempt with an in-line comment saying why it is recorded and not asserted; expectations reworded; fails if G2's listening set carries an undialled port |
| `quickstart.md` §1 / `plan.md` gate table | **G2** extended to record the ports the pinned image actually listens on (no new gate identifier) |
| `plan.md` | Architecture-diagram note, the P1 paragraph and the **SC-029** verification row all cite the single list instead of restating partial ones |
| `tasks.md` | **T066** dials the documented set read from the contract, marks the UDP row recorded-not-asserted, and reconciles against G2; **T070** keeps the NetworkPolicy CIDR-wide *and protocol-wide* so it never acquires a port list; **T073**'s counter is named as the assertion behind the UDP row; **T043** G2 writes `tests/gate/observed/mgmt-ports.json`; the US6 phase Independent Test reworded; a hard-rule bullet added: the port set is stated once and never retyped |
| `spec.md` | **FR-075** widens the number-free denial surface (monitoring port, vendor automation ports, any protocol) and requires the probe set to be every documented port, stated once and reconciled against observation. **SC-029** states that a connection-oriented attempt counts when observed to time out, a connectionless one is recorded with SC-028's counter asserting it, and an unobserved listening port fails the criterion |

### The other PARTIAL items

| CHK | Applied where |
|---|---|
| **CHK110** | `spec.md` FR-019 gains the no-credential-literal-in-any-manifest rule *and* the obligation that a repository-wide check carry it; `tasks.md` **T025** adds that scan to `scripts/ci/verify_boundaries.sh` over `deploy/` with a fixture test; `plan.md` make-target table names FR-019/CR-008 on the `verify-boundaries` row. Runs on every PR through T007. No new task |
| **CHK135** | Carrier already existed and was invisible: `pkg/migration/device_names_test.go` in **T096**, run by `make test-static`. `plan.md`'s `test-static` row now names FR-099 and that file. `spec.md` unchanged — naming a test file in requirement text is what CHK001 forbids |
| **CHK129** | `research.md` RD-01 now carries both missing parts: containerlab **`0.79.0`** cited to `evidence/01-lab-platform.md` §0 (the version this research ran, commit `5ae50094a`) and §4.3 (the window that covers the image pin) — it **has** evidence, so it is cited, not flagged; `srl-mapping v0.1.0` stated as **first-party**, resolvable against no registry, asserted by `make verify-compat` against parts 1–4 rather than resolved by `make verify-pins` |
| **CHK105** | `spec.md` **NFR-002** gains the telemetry-isolation clause: the telemetry path is never in the configuration path, a failure in it is observable as its own failure and blocks nothing, and may set `Degraded` while network readiness stands |
| **CHK108** | `spec.md` §Assumptions gains a bullet: the privileged lab runtime is a documented trust boundary, not an oversight, and it is the one host privilege taken — still no hypervisor, nested virtualization or acceleration device |
| **CHK114** | `spec.md` §Scope and interpretation gains a paragraph naming the five roles, pointing at `plan.md` §Technical Context for which project fills each, forbidding a third name for the same role, and saying why the registers stay separate |
| **CHK121** | `spec.md` GAP-2 row: "FR-046, FR-048" → "FR-046 (FR-048 references it, and adds no second record)" |
| **CHK115** | **No document change.** Recorded in AD-38 as answerable only against the 001/002/003 research files, which are not in this folder, or to be narrowed to the retarget-era decisions where all fifteen RDs carry the block |
| **CHK127 / CHK128(a)** | **No document change — the reviewer's ruling.** Both ask the MTU numbers and the management addresses be identical *in `spec.md`*; they agree everywhere they appear, and `spec.md` carries none of them because CHK001 forbids that detail in requirement text. Recorded as an item-versus-item conflict in AD-38 |

### Not touched, deliberately

`checklists/` (reviewer-owned, unticked); **CHK097** and the **`## Readiness result`** block (STALE —
the reviewer's to reword); `evidence/`; the constitution; and every passage named in the concurrency
warning (AD-23 fabric readiness, claims/VLAN band, drift policy and G13, tier purge, audit export,
clarify-delta closures, part-A SC "verified by" clauses).
