# Review: AD-26 (tier removal deletes tier-submitted services) and AD-24 (audit-record export)

**Feature**: `004-agentic-netops-composite` · **Date**: 2026-09-20 · **Reviewer**: research agent
(recommendation only — every decision below belongs to the human operator)
**Scope**: `research.md:2378–2393` (AD-24), `research.md:2410–2431` (AD-26) and their carriers.
**Constraints honoured**: no existing file was modified, no checkbox ticked; this file is the only
write. Every claim below cites `file:line` or is listed as UNVERIFIED.

Paths are relative to `/root/agentic-netops-srl/specs/004-agentic-netops-composite/` unless they
begin with `/root/`.

---

## 0. Verdicts

| Decision | Verdict | Confidence |
|---|---|---|
| **AD-26** — the intent namespace is tier-owned; removing the tier deletes the `Network`s in it | **RATIFY WITH AMENDMENTS** — ratify the *machinery* (list-first, export-first, bounded script wait, non-zero stop, never force-release, separate `agentic-netops-services`); **reverse the default**: the purge should refuse while tier-submitted services exist unless an explicit `--remove-services` is given (alternative **(c)**) | Moderate-high on the default (~0.75); high on the machinery (~0.9) |
| **AD-24** — the audit record is exported unconditionally before anything removes its store | **RATIFY WITH AMENDMENTS** on the principle; the *design* is **incomplete** — format, failure definition, bound, idempotence on re-run and post-export consumability are all unspecified | High on the principle (~0.9); high that the design is incomplete (~0.9) |

Both decisions are marked `— choice` / analysis-pass decisions (`traceability.md:373`, `:375`) and
neither appears in `checklists/clarify-delta.md`; the nearest items, CHK023 (`checklists/clarify-delta.md:108–111`,
claim release "in every removal path — … tier removal …") and CHK025 (`:116–119`, export vs
credential-removal ordering), are both still unticked. **These two decisions should be added to the
reviewer-owned checklist rather than treated as closed.**

---

## 1. AD-26

### Q1 — Is deleting live operator services the right default?

**Finding 1.1 — No requirement asked for it; AD-26 wrote the requirement that now justifies it.**
AD-26's own rationale concedes the point: *"the task list and the quickstart already deleted the
intent namespace, **which no requirement said**"* (`research.md:2421–2422`). The pre-existing
obligation was only NFR-006's first two sentences — deployable/removable independently, every
control-plane gate still passing — which are carried verbatim from the predecessor's NFR-001
(`/root/agentic-netops/specs/002-agntcy-intent-tier/spec.md:341–342`). The service-deleting clause
now in `spec.md:1383–1388` was **added by AD-26**, and US7 scenario 4's qualifier *"every service
applied with cluster tooling"* (`spec.md:405–406`) narrows what "unaffected" means so that
tier-submitted services fall outside it. The predecessor's same scenario read *"and the fabric from
feature 001 is unaffected"* with no qualifier
(`/root/agentic-netops/specs/002-agntcy-intent-tier/spec.md:145–147`). So the carriers are not
independent evidence for AD-26: they were amended to fit it. This is the structural reason to treat
the default as still open.

**Finding 1.2 — The predecessor did the opposite, deliberately.**
`off.sh --purge-intent-tier` in the predecessor called `intent::uninstall`
(`/root/agentic-netops/scripts/off.sh:37–44`), whose contract is stated in its own header: *"delete
every tier workload, Service, ConfigMap, Secret, Job, and PVC in agentic-netops-agents that the
install created … **the namespace and its RBAC/NetworkPolicies … are left alone** unless
`PURGE_INTENT_TIER_RBAC=true`"* (`/root/agentic-netops/scripts/lib/intent_tier.sh:12–18`, body at
`:380–425`). It touched **no** service-intent object at all: the tier's submitted objects lived in
`agentic-netops-intent` (`/root/agentic-netops/agents/common/audit.py:66`,
`/root/agentic-netops/agents/provisioning/deployer/submit.py:393`) and the uninstall's entire
namespace-scoped action list is `agentic-netops-agents`
(`/root/agentic-netops/scripts/lib/intent_tier.sh:37`). The predecessor runbook states the same to
operators: *"To remove only the intent tier (leaving the fabric/control plane intact) … deletes
supervisor/mapper/allocator/deployer/slim/ui deployments and services, the secret generator job,
config/secrets, and the supervisor checkpoint PVC"*
(`/root/agentic-netops/docs/INTENT_TIER_RUNBOOK.md:32–35`). **Under the predecessor, the services
survived the purge and the fabric was literally unaffected.** AD-26 is therefore a behaviour
reversal from the shipped system, presented as a closure of a defect.

**Finding 1.3 — Operator surprise is not hypothetical on this codebase.**
The predecessor recorded an incident in which a test run invoked `off.sh --purge-intent-tier` and
*"tore down the intent tier **and** the containerlab fabric on the running lab"*, with an
unrecoverable loss (`/root/agentic-netops/docs/SUGGESTED_PROMPTS_POSTMORTEM.md:220–233`). The root
cause recorded there is precisely the class AD-26 re-introduces: *"one marker means two different
things … and nothing distinguished them"*. The fix applied there was **an explicit opt-in gate**
(`AGENTIC_NETOPS_ALLOW_DESTRUCTIVE_E2E=1`), i.e. the shape of alternative (c). Under AD-26 the
surprise is larger, not smaller: one flag now removes device configuration from the leaves.

**Finding 1.4 — The confirmation asymmetry is a Principle II problem.**
Constitution Principle II requires *"two explicit human confirmations"* for provisioning
(`/root/agentic-netops-srl/.specify/memory/constitution.md:110`) with the rationale that *"an agent
that can change a fabric must be harder to trigger by accident than by intent"* (`:118–119`). Under
AD-26, N services that each cost two confirmations are removed by one word on a command line whose
name (`--purge-intent-tier`) names the tier, not the services. The identity that may remove them
through confirmations is the deployer; the purge removes them as cluster admin. The list-first
mitigation (`plan.md:1111`, R-47) prints what is about to go, but the script is non-interactive by
default (`spec.md:764–765`), so nobody reads the list before the deletes happen.
FR-010 also says both scripts *"MUST … refuse to delete resources they do not own"*
(`spec.md:766–767`) — whether a twice-confirmed operator service is "owned" by the tier is exactly
the question AD-26 answered for the operator without asking.

**Finding 1.5 — SC-025 does not require the cluster to be trace-free, so AD-26's rejection of the
alternative overstates it.** AD-26 rejects "keep the services" partly because *"the removability run
could not show a cluster with no tier trace in it"* (`research.md:2428–2429`). SC-025 says only
*"Removing the intent tier entirely leaves 100% of control-plane acceptance gates passing,
demonstrated by a full gate run with the tier absent"* (`spec.md:1639–1641`). A namespace holding
live, control-plane-reconciled `Network`s is not a gate. (Separately: the purge as specified already
leaves a cluster-scoped tier trace behind — see Finding 2.4.)

**Evaluation of the three options**

| | (a) AD-26 as written | (b) Keep services; control plane takes the namespace | (c) Refuse unless `--remove-services` |
|---|---|---|---|
| NFR-006 "removable independently, gates passing" (`spec.md:1380–1382`) | satisfied | satisfied (gates do not depend on the tier either way) | satisfied |
| US7-4 "control plane unaffected" (`spec.md:405–406`) | satisfied only because the clause was narrowed | satisfied on the original reading | satisfied on either reading |
| Constitution II "harder by accident than by intent" (`constitution.md:118–119`) | **weakest** — one flag, no confirmation | strong (nothing destructive happens) | **strongest** — destructive action needs its own word |
| Constitution III "Teardown MUST be idempotent and safe to re-run" (`constitution.md:130`) | satisfied | satisfied | satisfied |
| FR-010 non-interactive, flag-driven (`spec.md:763–767`) | satisfied | satisfied | satisfied — a flag, not a prompt |
| Cost to the documented sequence | none | the removability grep at `quickstart.md:1081–1082` must change (namespace survives; adopted claims keep `tier=intent`) | one flag added to `quickstart.md:1079` and `tasks.md:517` (T152) |
| Ownership of `agentic-netops-intent` after removal | resolved by deletion | must be re-declared control-plane-owned (`data-model.md:45`, `contracts/kubernetes-objects.md:73`, `tasks.md:259` T068) | unchanged; resolved only in the `--remove-services` path |
| Re-install behaviour | clean | tier re-install meets pre-existing objects it once submitted (covered by FR-105 / `spec.md:161–162`, but untested) | clean |

**Recommendation.** Keep everything AD-26 built and move the default one notch: the purge **lists**
the tier-submitted `Network`s and, if the list is non-empty, **stops zero-or-non-zero with an
actionable diagnostic** naming them and the two ways forward — `--remove-services` (delete them
through ordinary finalization, exactly the AD-26 sequence) or `--keep-services` (leave them running;
the namespace's ownership label flips to control-plane and the tier's Role/RoleBinding in it are
removed). This costs one flag in `quickstart.md §24` and T152, preserves every safety property AD-26
added, and is the only one of the three that satisfies Principle II's rationale on its own terms.
Option (b) as a standing default is defensible and matches the predecessor, but it leaves the
namespace-ownership question to be re-specified in four places; option (c) leaves the AD-26 text
almost entirely intact.

### Q2 — Kubernetes mechanics

**2.1 Finalizers and the namespace — the ordering is right, and should be made explicit.**
Deleting the `Network`s first and deleting the namespace only afterwards
(`tasks.md:306` T088: *"only then remove the rest"*; `quickstart.md:1105–1108`) is the correct order:
issuing `delete namespace` while a `Network` finalizer is blocked would leave the namespace
`Terminating` for ever, which is exactly the outcome AD-26 says it is closing
(`research.md:2423–2424`). **Gap**: nothing states that the namespace delete is guarded by a
**re-list returning empty**, only that the Networks were deleted and waited on. Recommend stating it.

**2.2 A real race: the tier is still live during the wait.** T088's order is list → export → delete →
wait ≤300 s → remove workloads (`tasks.md:306`). Throughout the wait the supervisor, UI and deployer
are running and the `intent-writer` Role still exists (`tasks.md:260` T069), so a new request can be
confirmed and a **new `Network` created in a namespace that is being torn down**. Two consequences:
(i) that object is not in the snapshot list, so it is never waited on and is swept by the namespace
delete without FR-103's read-back; (ii) — worse — its **audit events are written to a store that has
already been exported** (`research.md:2381–2383`), so FR-078's *"after the export the evidence file
is the record"* (`spec.md:1236–1237`) is false for them. **Recommendation: yes, the purge should
quiesce the tier's write path first** — scale `supervisor`, `ui` and `deployer` to zero (or delete
those Deployments) **before** the list and the export. This is safe: the provider's finalizer, not
the deployer, removes device configuration and releases claims
(`tasks.md:306`; `spec.md:936–937`). The stop message should then say the tier is *quiesced and
resumable by re-provisioning*, because `spec.md:1385–1387` currently promises *"the rest of the tier
still in place"*, which an operator may read as "still serving".

**2.3 Events mirrored in the intent namespace — no problem.** The deployer mirrors three event kinds
as Kubernetes Events there (`contracts/kubernetes-objects.md:104–108`, `data-model.md:876–880`), and
the spec is explicit that an Event *"expires, and is never the record"* and that no reconciliation
reads one (`spec.md:1237–1239`, `data-model.md:879–880`). Deleting the namespace destroys the
mirrors only. Coherent.

**2.4 The ValidatingAdmissionPolicy — no interaction, but a leftover.** `deny-tier-force-release`
matches `networks…` on **CREATE and UPDATE** by the two tier ServiceAccounts
(`contracts/kubernetes-objects.md:60`, `tasks.md:262` T071). The purge runs as the operator's
kubeconfig and issues **DELETE**, so it is neither matched nor denied; and the purge never writes the
annotation (`tasks.md:294` T174 asserts *"no force-release annotation ever written"*). **But** the
VAP and its Binding are **cluster-scoped tier artefacts** and appear nowhere in the purge's removal
list (`quickstart.md:1105–1109` removes namespaces, the kuid RoleBinding, the qualification copy, the
dashboard ConfigMap and its patch, the images). Either it is removed with the tier or it is declared
boundary-owned and kept — and the removability check at `quickstart.md:1081` only greps
**namespaces**, so it would not notice either way.

**2.5 The webhook is in the provider — correct by construction, with one caveat.** The cross-object
rules are an admission webhook served by the provider (`plan.md:533`,
`contracts/crd-api.md:154–159`) and all of them are CREATE/UPDATE semantics; the provider is
untouched by the purge (`tasks.md:306`), so deletions and finalizers proceed normally. The caveat is
the *full* `off.sh` path, not the purge: it deletes the Kind cluster wholesale
(`quickstart.md:1093`, `tasks.md:183` T049), so no `Network` finalizer ever runs and FR-103's
read-back never happens. That is acceptable only because the containerlab nodes go in the same run —
worth one sentence somewhere, since it is the one path where device state is left behind by design.

**2.6 Coherence and re-runnability of the mid-way stop.** After the non-zero stop the cluster state is
coherent (`Network` deleted-but-finalizing, claims still bound per FR-103 `spec.md:877–884`, tier
objects present, control plane untouched) and a re-run completes (`research.md:2416–2418`). Two
implementation hazards, both currently unstated:
- **Export idempotence.** The re-run must export again (the store still exists). `evidence_run` writes
  `<EVIDENCE_DIR>/<id>.json` (`tasks.md:115` T011) and `verify_evidence` fails on *"a content hash that
  changed after capture (post-edit)"* (`tasks.md:116` T012). A second export under the same id in the
  same `EVIDENCE_DIR` is therefore either an overwrite that trips SC-040 or a silent duplicate.
  The export id must be unique per attempt, or a verified prior export must satisfy the gate.
- **Re-run after an export failure.** If attempt 1 exported successfully and attempt 2's export fails
  (store now unhealthy), the removal stops although a valid record already exists. The rule should be
  "export unless a verified export of this store exists in this run's evidence".

### Q3 — Is 300 s reasonable, and does it violate FR-103?

**Against the other bounds** (`data-model.md:1221–1233`): reconcile 15 s, convergence 150 s, deployer
call 210 s, request deadline 300 s, re-verification 300 s, SC-043's ten intervals = 150 s
(`data-model.md:1238`). A normal finalization is a removal plus a read-back from each device —
single-digit reconcile intervals. **300 s = 20 reconcile intervals = 2× convergence timeout**, and it
matches two existing 300 s values in the same table. The value is reasonable and consistent.

**FR-103 in letter**: not violated. FR-103 forbids a timeout that *"release[s] an identifier or
remove[s] the object"* (`spec.md:881–882`). This timer does neither; `data-model.md:1233` states it
*"bounds the script, never the finalizer"*, and T174 asserts no force-release is ever written
(`tasks.md:294`). **In spirit**: acceptable, with one caveat — FR-103 names exactly two exits (the
target returns; a documented operator force-release). The script's stop is a *third observation
outcome*, not a third exit, and the documents do say so; keep that phrasing and never let the bound
become an input to any cluster action. Two concrete improvements:
- **Fail fast on a known-unreachable target.** The blocked state is already self-describing —
  `Deleting=True` / reason `TargetUnreachable` naming the leaf (`quickstart.md:1236–1238`). If that
  condition is already present when the wait begins, the purge should stop immediately rather than
  burn 300 s; the 300 s is for *slow*, not for *known-blocked*.
- **Distinct exit code** for "blocked on an unreachable target" versus a genuine script error, so
  automation and the re-run path can tell them apart. Neither `tasks.md:294` nor `:306` says more than
  "non-zero".
- One textual tension to resolve: `data-model.md:1234–1236` says *"the delete-while-unreachable state
  has **no** bound at all … and none of these applies to it"* in the same table that now carries the
  tier-removal row. The row's own disclaimer covers it, but the invariant sentence should name the
  exception explicitly.

### Q4 — Is `agentic-netops-services` introduced consistently?

All 35 `agentic-netops-intent` hits in the feature directory, classified:

**Correct (tier-submitted or tier-RBAC):** `data-model.md:45`; `tasks.md:253` (T066 allow-list),
`:259` (T068), `:260` (T069), `:306` (T088); `contracts/crd-api.md:34`;
`contracts/kubernetes-objects.md:15, 22, 69, 73`; `contracts/network-spec.md:202` (the exemplar
carries `intent-thread-id`/`intent-principal`, so it is tier-submitted); `research.md:884, 898`
(D-33); `quickstart.md:194, 567, 569, 725, 736, 783, 842, 1081, 1098, 1165, 1167, 1169, 1181, 1202,
1265, 1289*` — see below for 1289.

**Incoherent or under-specified:**

| Hit | Problem |
|---|---|
| `quickstart.md:1228, 1239, 1252` (§27, `make test-delete-unreachable`) | T042 states this suite uses `agentic-netops-services` (`tasks.md:174`: *"the suites of T064/T167/T172 use it"*), and `delete_unreachable.sh` is T064 (`tasks.md:228`). The quickstart still drives it in the **intent** namespace. SC-043 is a control-plane criterion (`spec.md:1547–1551`, `plan.md:1008`); as written §27 cannot run with the tier absent, which is what SC-025's gate run requires (`spec.md:1639–1641`, `quickstart.md:1087`). |
| `quickstart.md:1289` (§27a, `make test-reverify`) | Same: T167 (`tasks.md:229`) is named by T042 as a `agentic-netops-services` suite; SC-044 is a provider behaviour (`plan.md:1009`). The read-back command uses the intent namespace. |
| `quickstart.md:1265` | The VAP-denial probe **must** run in the intent namespace (the tier holds Network verbs only there — `tasks.md:260`, and `tasks.md:253` asserts `Network` outside the intent namespace is denied), so this line is right, but it makes §27 tier-dependent. It belongs with the boundary probes (T066/T073, `tasks.md:253, 264`), not inside an SC-043 section. |
| `data-model.md:795` (§15 table: `Network` → `agentic-netops-intent`) | Reads as *the* home of `Network`. Scoped to "what the tier submits" by its heading (`:788`), but it is the table a reader will quote. One clause naming `agentic-netops-services` for hand-applied objects would close it. |
| `plan.md:367` (architecture diagram) | The diagram shows `ns agentic-netops-intent` only; `agentic-netops-services` — introduced at `plan.md:70` — is absent from the picture. |

**US2 suites — the intent is stated once and not carried through.** `tasks.md:174` (T042) is the only
place that binds T064/T167/T172 to `agentic-netops-services`. T062 (`tasks.md:226`) says it correctly
for the examples (*"namespace `agentic-netops-services`, never the tier's intent namespace"*), and
T172 (`tasks.md:230`) runs *"with no intent tier installed"* against those examples, so it is coherent
by inheritance. T064 (`tasks.md:228`) and T167 (`tasks.md:229`) name **no namespace at all** and their
quickstart sections name the wrong one. `quickstart.md §8` (`:405, 457–458, 471`) and `§27a` are
otherwise consistent with `agentic-netops-services`.

**Deployer pre-flight vs the cluster-wide webhook — not coherent, and structurally unfixable inside
the current boundary.** T112 scans **only** `agentic-netops-intent` (`tasks.md:384`), while the
cross-object rules are evaluated cluster-wide — `contracts/kubernetes-objects.md:73` says explicitly
*"the cross-object admission rules see both namespaces alike"*, and the provider watches cluster-wide
(`plan.md:1079` R-15). So a hand-applied `Network` in `agentic-netops-services` that holds
`(node, port, vlan)` or a tagging mode is **invisible to the pre-flight**, and the tier discovers the
conflict only when admission rejects the apply. The tier cannot fix this by widening the scan: its
Role grants `networks` in the intent namespace only (`tasks.md:260`) and T066 asserts that `Network`
**outside** the intent namespace is denied (`tasks.md:253`). Consequences worth the operator's
attention: FR-043's *"refused before anything is created"* (`spec.md:1050–1052`) still holds
technically (admission refuses before creation), but the friendly refusal naming the incumbent
(`quickstart.md:724`) degrades to a webhook rejection; and AD-27's allocated-VLAN collision path
(`research.md:2432–2440`, `tasks.md:384`) can now claim a VLAN and then be rejected at admission, so
the deployer must release the provisional claims on an admission denial — which no task states.
Three ways out, all operator choices: (i) grant the deployer `get,list,watch` (no write) on `networks`
cluster-wide and widen the scan; (ii) mount a read-only projection of the services namespace's
occupancy; (iii) declare the webhook authoritative, state that the pre-flight is a best-effort
message improver, and require provisional-claim release on admission denial.

---

## 2. AD-24

### Q5 — Is the export design complete?

**The principle is right.** FR-078's *"exported with the run's evidence before anything removes the
store … unconditionally and not only when evidence capture was asked for"* (`spec.md:1231–1236`) is
the only reading under which Principle II's *"All actions MUST be auditable"*
(`constitution.md:116`) survives a routine teardown; the assumptions section already says the audit
record *"is the one export that is never optional"* (`spec.md:1875–1876`). Ratify that.

**The design is incomplete on six points.**

1. **Format — unspecified anywhere.** T088 says only *"the analytics store's trace tables written
   through the evidence capture"* (`tasks.md:306`). No table names, no schema, no serialization
   (TSV/JSONEachRow/native/Parquet), no compression, no manifest. `data-model.md §21` (`:1076–1090`)
   describes the emission path, not the store's tables; the `AuditEvent` field list at
   `data-model.md:854–860` is the *event* shape, not the export. Without a stated format, "export
   fails" cannot be tested and the file cannot be read back.
2. **Where it lands.** By inheritance from `evidence_run`, `<EVIDENCE_DIR>/<id>.json` plus raw output,
   `EVIDENCE_DIR` defaulting to `.evidence/<cluster>_<lab>/<UTC run id>/` (`tasks.md:115` T011). That
   is coherent but never stated in AD-24, FR-078 or `quickstart.md §24`. Note the side effect: a
   teardown run with evidence capture *off* now always creates an evidence directory, and an
   unwritable `EVIDENCE_DIR` becomes a teardown blocker.
3. **NFR-013 fields.** Satisfied only via `evidence_run` (`spec.md:1402–1409`, `tasks.md:115`), and
   `verify_evidence` *"fail[s] on any artefact missing an NFR-013 field"* (`tasks.md:116`). Two
   snags: the export has **no negative control** and is not a readiness check, so it should be
   explicitly exempted from T012's negative-control rule; and the re-run/duplicate-id hazard in
   Finding 2.6 above applies directly here.
4. **Size.** Unaddressed. The store holds *"every model call's prompt, model identity and response"*
   (`plan.md:469` C-17; NFR-009 `spec.md:1396–1397`), and the export is *the trace tables*, not the
   audit events. After a full acceptance run — three clean deploy/test/destroy cycles
   (`tasks.md:516` T151) plus the adversarial corpus of ≥30 cases (`tasks.md:266` T075) — this is
   plausibly the largest single artefact in `EVIDENCE_DIR`. Recommend: compressed, and either scoped
   to the audit span events plus their parent spans, or explicitly stated as a full dump with a size
   expectation. **UNVERIFIED**: actual magnitude — no measurement exists.
5. **"Export fails" is undefined, and there is no bound on it.** The distinguishable cases are at
   least: store never installed (skip — `tasks.md:183` "whenever the analytics store exists"); the
   StatefulSet/PVC exists but the Pod is not Ready; the query errors; zero rows returned (success or
   failure?); a partial/truncated write; `EVIDENCE_DIR` unwritable. `data-model.md §25` gives the
   export **no timeout**, so an unresponsive ClickHouse can hang the teardown — against FR-010's
   *"fail fast with actionable diagnostics"* (`spec.md:765`) and against `quickstart.md:1122`'s *"The
   shutdown script tolerates partial provisioning"*. A wedged store currently makes
   `--discard-audit-record` the only route to a teardown, which is a defensible but undocumented
   operator trap. Recommend: define "exists", add an `AUDIT_EXPORT_TIMEOUT_SECONDS` row to
   `data-model.md §25`, and state that an empty store is a successful export of an empty record.
6. **Redaction (FR-079).** The export is a copy of a store whose contents are already required to be
   redacted at emission (`spec.md:1240–1241`; guards at `tasks.md:265` T074), so no second pass is
   needed — but that reasoning is nowhere written, and SC-031's scan is scoped to *"the corpora of
   SC-020 and SC-028"* (`spec.md:1663–1665`), not to the exported artefact. Since the export moves
   prompts and responses out of the cluster onto the host filesystem, the exported file should be
   named as in scope for SC-031's credential scan.

**SC-030 / SC-042 after the store is gone — the claim is currently false.** FR-078 says *"After the
export the evidence file is the record. It is the stream SC-030 and SC-042 reconcile"*
(`spec.md:1236–1237`), repeated at `data-model.md:874–875`. But the only reconciliation tool reads
the **live store** (`quickstart.md:872–875`: *"The stream it reconciles is read from the
agent-analytics store"*; `agents/tests/e2e/test_audit_reconcile.py`, `quickstart.md:882`), and no task
gives it a file input. Worse, SC-030 compares the stream *"against the set of resources the tier
created and their submitted-spec hashes"* (`spec.md:1658–1662`) — after the purge under AD-26 those
resources no longer exist, so the reconciliation is unrunnable post-purge in principle, not just in
tooling. Resolution options: (i) give the reconciliation an `--audit-export <file>` source and require
the export to carry the resource refs and hashes it needs (it already carries `resources` and both
hashes per `data-model.md:858, 866–867`); or (ii) soften FR-078 to *"the evidence file is the durable
record; the reconciliations of SC-030 and SC-042 run against the live store before it is removed"* —
which is what the documented sequence already does (§19 at `quickstart.md:867` precedes §24 at
`:1070`). Either is fine; the current text asserts (i) while the tasks implement (ii).

**One ordering gap AD-26 creates for AD-24.** See Finding 2.2: with the tier live during the ≤300 s
wait, audit events can be written **after** the export. Quiescing first fixes AD-24 as well as AD-26.

**One recording gap.** The purge's own deletions are performed with cluster tooling, not through the
tier, so they generate no audit event (and would in any case land after the export). FR-078 requires
every *"removal"* to be recorded (`spec.md:1226–1228`). The purge's printed list is the only record
of them; that should be said explicitly, and the list should be captured through `evidence_run` so it
carries the NFR-013 fields.

---

## 3. Residual inconsistencies (file:line)

| # | Location | Inconsistency |
|---|---|---|
| RI-1 | `quickstart.md:1228, 1239, 1252` vs `tasks.md:174` | §27 (`make test-delete-unreachable`, T064) drives `agentic-netops-intent`; T042 assigns that suite to `agentic-netops-services`. Blocks SC-043 in a tier-absent gate run (`spec.md:1639`). |
| RI-2 | `quickstart.md:1289` vs `tasks.md:174, 229` | §27a (`make test-reverify`, T167) reads `status.lastVerifiedTime` from the intent namespace; same mismatch. |
| RI-3 | `tasks.md:228, 229` | T064 and T167 name no namespace at all; the binding exists only in T042's prose. |
| RI-4 | `tasks.md:384` (T112) vs `contracts/kubernetes-objects.md:73` and `tasks.md:253` | Pre-flight scans one namespace; the admission rules span both; the tier's RBAC forbids widening the scan. |
| RI-5 | `quickstart.md:1105–1109` vs `contracts/kubernetes-objects.md:60`, `tasks.md:262` | The cluster-scoped `deny-tier-force-release` VAP + Binding is a tier artefact but is not in the purge's removal list, and `quickstart.md:1081` checks namespaces only. |
| RI-6 | `tasks.md:306` (T088) vs `spec.md:1231–1236` | Export precedes a ≤300 s window in which the live tier can write new audit events into the already-exported store, and can create unlisted `Network`s in the namespace being removed. |
| RI-7 | `tasks.md:115, 116` vs `tasks.md:294, 306` | Re-running the purge re-exports under the same evidence id; T012 fails on a changed content hash. No per-attempt id rule. |
| RI-8 | `spec.md:1236–1237`, `data-model.md:874–875` vs `quickstart.md:872–875`, `tasks.md` (no task) | "the stream SC-030 and SC-042 reconcile" is the exported file, but no tool can read it and the tier-created resources are gone by then. |
| RI-9 | `data-model.md:1234–1236` vs `:1233` | "the delete-while-unreachable state has **no** bound at all … none of these applies" sits in the same table as a 300 s row about that state. |
| RI-10 | `data-model.md:795` | §15's `Network` namespace table names only `agentic-netops-intent`. |
| RI-11 | `plan.md:367` vs `plan.md:70`, `data-model.md:45` | `agentic-netops-services` missing from the architecture diagram. |
| RI-12 | `quickstart.md:1087` | `CONTROL_PLANE_ONLY=1` appears exactly once and is defined nowhere; no artefact partitions the success criteria into control-plane and tier sets, yet SC-025 is stated as "100% of control-plane acceptance gates". |
| RI-13 | `quickstart.md:1093` | `--preserve-evidence` appears exactly once; it is not in FR-010's documented-flag set (`spec.md:763–767`) nor in T049's flag list (`tasks.md:183`). |
| RI-14 | `quickstart.md:1081–1082` | The removability proof greps namespaces and `tier=intent` claims only; it would not detect a surviving cluster-scoped tier object, and under options (b)/(c) it needs restating (an *adopted* claim of a surviving service legitimately keeps its provenance label — AD-16, `research.md:2235`). |
| RI-15 | `spec.md:1385–1387` | "with the rest of the tier still in place" will be false in spirit if the purge quiesces the supervisor first (recommended); and is ambiguous today about whether the tier is expected to still serve requests. |

---

## 4. Proposed wording changes (proposals only — not applied)

**P-1 — `spec.md:1383–1388` (NFR-006), the default.** Replace *"Removing the tier removes the
services it submitted … "* with: *"Removing the tier does not remove the services it submitted unless
the operator asks for that in the same command. The removal lists them first; where the list is
non-empty it stops with an actionable diagnostic naming each service and the two documented
continuations — remove them through ordinary finalization, or leave them running and hand their
namespace to the control plane. Where removal is asked for, the removal exports the audit record
(FR-078), waits a bounded time for finalization, and where one is blocked (FR-103) stops non-zero
naming the service and the target with the rest of the tier still in place. It MUST NOT
force-release."*

**P-2 — `spec.md:405–406` (US7-4).** Restore the unqualified promise and add the flag: *"…, the
services the tier submitted are listed and are removed only when the documented removal flag is
given, and the control plane — its controllers, the fabric design and every service it still holds —
is unaffected (NFR-006)."*

**P-3 — `tasks.md:306` (T088), ordering.** Insert before "list": *"quiesce the tier's write path
first — scale `supervisor`, `ui` and `deployer` to zero and confirm no `Network` is created after the
list — so that no audit event is written after the export and no request enters a namespace being
removed;"*. Add at the end: *"delete the namespace only after a re-list returns empty; exit 3
(distinct from a script error) when a `Network` is still `Deleting`; stop immediately, without
waiting, where a listed `Network` already reports `Deleting=True/TargetUnreachable`."*

**P-4 — `data-model.md:1233–1236` (§25).** Add a row *"Audit export | a bound to be chosen, after
which the export is a failure | `off.sh` · `AUDIT_EXPORT_TIMEOUT_SECONDS` | FR-078, AD-24"*, and
amend the invariant sentence to *"…has **no** bound at all (§18, FR-103) and none of these applies to
it, except the tier-removal row, which bounds only the removal script's observation of that state and
never the finalizer."*

**P-5 — `spec.md:1236–1237` (FR-078).** Either add *"…and the exported file MUST carry, for each
event, the fields the SC-030 and SC-042 reconciliations need — principal, correlation identifier,
resource reference and submitted-spec hash — so that both can run from the file alone"*, or replace
the sentence with *"the reconciliations of SC-030 and SC-042 run against the live store before it is
removed; after the export the file is the durable record."* Choose one; the documents currently
assert the first and implement the second.

**P-6 — `research.md:2378–2393` (AD-24), completeness.** Add a *Format* clause naming the tables
exported, the serialization, the compression, the file name under `EVIDENCE_DIR`, and a definition of
failure enumerating: store absent (skip), store present but unqueryable within the bound (failure),
query error (failure), empty result (success), partial write (failure), evidence directory unwritable
(failure).

**P-7 — `quickstart.md:1228, 1239, 1252` and `:1289`.** Re-point §27's and §27a's commands at
`-n agentic-netops-services`, and move the VAP-denial probe now at `:1265` into §23 (the boundary
deny-list, `quickstart.md:1017`) where the tier is a stated precondition.

**P-8 — `tasks.md:228, 229` (T064, T167).** Add *"in `agentic-netops-services` (T042), so the suite
runs with no intent tier installed"* to both.

**P-9 — `quickstart.md:1105–1109` and `contracts/kubernetes-objects.md:60`.** State whether the
cluster-scoped `deny-tier-force-release` policy and its binding are removed by the purge or are
boundary-owned and retained, and extend the removability check at `quickstart.md:1081` to cover
cluster-scoped tier objects.

**P-10 — `tasks.md:384` (T112).** Add the chosen resolution of RI-4 and, regardless of which is
chosen: *"on an admission denial the deployer MUST release every provisional claim it made for the
request before reporting the refusal (FR-109, AD-27)."*

**P-11 — `data-model.md:795`.** Append to the table caption: *"Objects applied with cluster tooling
live in `agentic-netops-services` (§2); this table is the tier's submission target only."*

**P-12 — `checklists/clarify-delta.md`.** Add two reviewer items: *"Is deleting twice-confirmed
operator services the right default for a flag named `--purge-intent-tier`, given constitution
Principle II and the predecessor's behaviour? [Conflict, Spec §NFR-006, §US7-4, research §AD-26]"*
and *"Does AD-24 state the export's format, failure definition, bound and post-export consumability
well enough to be implemented and tested? [Gap, Spec §FR-078, research §AD-24]"*.

---

## 5. UNVERIFIED

- **U-1** — The pre-AD-26 text of `spec.md` NFR-006 and US7 scenario 4 in *this* repository. The
  repository is not a git repo, so the amendment is inferred from AD-26's own consequence list
  (`research.md:2430–2431`), the change log row (`spec.md:1780`) and the predecessor's wording
  (`/root/agentic-netops/specs/002-agntcy-intent-tier/spec.md:341–342, 145–147`).
- **U-2** — Whether ClickHouse trace-table volume after a full acceptance run is a size problem. No
  measurement exists in either repository.
- **U-3** — Whether an adopted claim retains the `agentic-netops.io/tier=intent` label after the
  provider adopts it (AD-16). The label selector at `quickstart.md:1082` assumes something about this;
  nothing states it. Relevant to options (b)/(c) and to RI-14.
- **U-4** — Whether `ValidatingAdmissionPolicy` is served at the pinned Kubernetes minor; T166
  qualifies it and T071 has a provider-webhook fallback (`tasks.md:177, 262`). If the fallback ships,
  Finding 2.4's "leftover" becomes a provider-owned webhook instead and RI-5 changes shape.
- **U-5** — What `CONTROL_PLANE_ONLY=1` excludes (RI-12). Nothing defines it, so "which gates are
  control-plane gates" could not be checked against SC-025.
- **U-6** — Whether `agents/tests/e2e/test_audit_reconcile.py` in the successor is intended to accept a
  file source. Only the predecessor's implementation was read
  (`/root/agentic-netops/agents/tests/e2e/test_audit_reconcile.py:46`), which reads the live cluster.
- **U-7** — No external URL was fetched for this review; all citations are repository files.

---

## Applied 2026-09-20

Operator decisions AD-35 (purge default reversed; amends AD-26) and AD-36 (audit-export design;
amends AD-24) applied. Every edit below was made with the locked atomic editor; no checkbox was
ticked, no identifier renumbered, and no new FR/NFR/SC/R/T/G was created. One new **default bound**
was introduced as a design value with its owner setting, in the table that owns such values.

**`spec.md`** — NFR-006 (*"The services the tier submitted live in the tier's intent namespace, and
removing the tier does **not** remove them unless…"*); User Story 7 scenario 4 (*"…only where the
operator asked for that in the same command"*, and *"every service it still holds"* replacing *"every
service applied with cluster tooling"*); the intent-tier edge cases (the old one split into three:
refusal, quiesced removal with a blocked finalizer, and the post-list creation case); FR-010 (flag
set enumerated; *"A flag whose effect is destructive beyond the thing the command is named for MUST
be its own flag"*); FR-078 (export format, per-attempt identifier, failure set, and the split of
SC-030/SC-042 into a stream half and a live-object half); FR-079 (*"…is a copy of already-redacted
material and MUST NOT depend on a second pass at export time"*); the fourth-pass change-log row for
NFR-006 (*"Superseded in part by the operator decision of 2026-09-20 (AD-35)"*). SC-025 untouched.

**`data-model.md`** — §2 namespaces row (`agentic-netops-intent` *"…deletes only when it is asked to
and otherwise stops naming"*); §15 `Network` table (*"…it is the tier's submission target only"*);
§16 "Where it lives" (export format, failure set, reconciliation from the file); §25 tier-removal
wait row (flag in the owner column; no wait spent on an already-unreachable target) and a **new
`Audit-record export` row** (120 s, `off.sh` · `AUDIT_EXPORT_TIMEOUT_SECONDS`, stated as a design
value); §25 invariant sentence (the tier-removal row is not an exception to FR-103's "no bound").

**`contracts/kubernetes-objects.md`** — the `agentic-netops-intent` namespace row (*"**not together
with the `Network`s in it** unless the removal was given `--remove-services`"*); the `clickhouse`
row (export format, failure set, bound); the `deny-tier-force-release` row (*"It is a tier artefact
although it is cluster-scoped… the removability check looks for it by name"*).

**`quickstart.md`** — §19 (*"**Run this before §24.**"* and reconciliation from the exported file);
§24 removability proof (now two steps: refusal first, then `--remove-services`; adds the
`validatingadmissionpolicy` check) and its narrative (quiesce, export, re-list-before-namespace,
why the flag is given here and that SC-025 does not require it, and that the full teardown needs no
flag); §27 (`make test-delete-unreachable` re-pointed to `agentic-netops-services`, three commands
plus the framing sentence) with the VAP-denial probe kept in the intent namespace and labelled as
the tier's own probe; §27a (`lastVerifiedTime` read re-pointed, plus one sentence of rationale).

**`plan.md`** — C-18 (refusal, flag, quiesce, full-teardown exemption, export design); P11
(two-step removability run and why the flag is given); R-47 (rewritten around the refusal and the
predecessor's behaviour); the "Audit export and tier removal" verification-strategy row; the
summary sentence near the top of the plan that listed the old default.

**`tasks.md`** — T049 (full teardown needs no `--remove-services`; `--preserve-evidence` named as a
documented flag); T064 (`delete_unreachable.sh` applies in `agentic-netops-services`); T088 (whole
removal sequence rewritten: evidence-captured list, refusal, quiesce, export design and bound,
no-wait-on-known-unreachable, re-list before namespace, and the VAP among the removed objects);
T112 (namespace scope only — the pre-flight is *"a better message and never the authority"*, and the
deployer must release provisional claims on an admission refusal; the allocated-VLAN sentence was
left untouched for the claims agent); T136 (export format and bound); T141 (runbook now teaches the
refusal, the flag, the quiesce and the full-teardown exemption); T152 (two-step proof with the
refusal asserted first); T167 (`reverify.sh` applies in `agentic-netops-services`); T174 (refusal
case, quiesce ordering, the four export failure cases, the per-attempt identifier, the re-list, and
the no-re-export-over-a-hashed-artefact case); the US7 "Independent Test" line.

**`research.md`** — `[[STUB-AD-35]]` and `[[STUB-AD-36]]` replaced with full entries in AD-26's
format (Decision / Rationale / Alternatives rejected / Consequences), both marked **operator
decision** and citing this report and the predecessor evidence; one-line *"Amended by AD-35"* /
*"Amended by AD-36"* pointers added inside AD-26 and AD-24 rather than rewriting them.

**`traceability.md`** — AD-35 and AD-36 rows added after AD-34.

### Not applied, and why

- **RI-4 (pre-flight vs cluster-wide webhook)** is closed *without* widening the boundary: reading
  `Network`s in `agentic-netops-services` would need a cluster-wide read grant for `intent-deployer`,
  which is an FR-075 allow-list change and an operator decision, not mine. T112 now states that
  admission is the authority and that provisional claims are released on its refusal.
- **RI-11** (`agentic-netops-services` missing from the `plan.md` architecture diagram) — ASCII art
  being edited concurrently; left for the coordinator.
- **RI-12** (`CONTROL_PLANE_ONLY` undefined; no control-plane/tier partition of the success criteria)
  — needs a new artefact or task; out of scope under the no-new-identifier rule.
- `checklists/` untouched, as instructed.
