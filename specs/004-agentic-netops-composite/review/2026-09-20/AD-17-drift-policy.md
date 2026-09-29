# AD-17 review — the drift-policy set closed at one member

**Decision under review**: `research.md:2259` "AD-17: The drift-policy set is closed, with one member
*(FR-015 — choice)*". Carriers: `spec.md:803-813` (FR-015), `spec.md:1542` (SC-007),
`spec.md:904-912` (FR-107), `data-model.md:1239-1242` (§25 last paragraph),
`contracts/reconciliation.md:127-146` (Rule 6), `contracts/crd-api.md:217-223,262`,
`plan.md:263-270,764-767,1047`, `quickstart.md:478-483,1365`, `tasks.md:168` (T036), `tasks.md:174`
(T042), `tasks.md:182` (T048), `tasks.md:228` (T064), `tasks.md:498` (T141),
`traceability.md:366`. Constitution Principle I: `.specify/memory/constitution.md:89-97`.

Review is advisory. Nothing in the feature directory was modified; no checkbox was ticked.

---

## Verdict

**RATIFY WITH AMENDMENTS** — confidence **high** on the SDC facts (all verified against the pinned
artefacts), **medium-high** on the design judgement.

The *mechanism* AD-17 chose is sound and should stand: `DRIFT_POLICY` required, no default, closed
value set `{revertive}` (exact string), refusing the start on unset/empty/`non-revertive`/
`Revertive`/`true`. It is the only mechanism in the artefacts that actually enforces FR-015's
"MUST NOT be inherited from the lab", and it maps to a real, verified API field.

The *rationale* is factually wrong and must be amended in five places. AD-17, FR-015,
`contracts/reconciliation.md` Rule 6, `contracts/crd-api.md` and `quickstart.md` all assert that
SDC's **only** other behaviour is "accept the device's value as active", and that this is why the
set is closed. At the pinned versions SDC also ships an operator-driven **revert** of a recorded
deviation (`DeviationClear` / `kubectl sdc deviation --revert`, full or path-filtered), which *is*
repair and which Principle I would admit. The set should stay closed at one member **by scope**, not
by a claim that no repairing alternative exists — because that claim is false and an operator who
reads the SDC docs will find it false.

Two further defects, one of them high, are reported below: **T036 asks four CRs to state a field
none of them has**, and **the drift test may be asserting an artefact that revertive mode races away
before it can be observed**.

---

## Q1 — How sdcio actually expresses revertive vs non-revertive

### It is a field on `Config` (and `ConfigSet`), plus a server-side global

| Surface | Exact name | Type | Default | Verified at |
|---|---|---|---|---|
| Per-intent | `Config.spec.revertive` | `*bool` (`json:"revertive,omitempty"`) | **none in the CRD** — no `default:` key in the OpenAPI schema | `config-server@v0.0.58 apis/config/v1alpha1/config_types.go` (fetched); `crds/config.sdcio.dev_configs.yaml:77-80,123-126,275-278,326-329` (fetched — the only `default:` keys in that file are `lifecycle.deletionPolicy: delete` at :261,:312) |
| Per-intent-set | `ConfigSet.spec.revertive` | same | same | `crds/config.sdcio.dev_configsets.yaml` (fetched, 4 occurrences) |
| Global | `REVERTIVE` env var on the `data-server-controller` StatefulSet | string | deployed as `"true"` | `evidence/05-kubenet-sdc-kuid.md:318,523-524` |

Go doc comment, verbatim: *"Revertive defines if this CR is enabled for revertive or non revertve
operation"* (`config_types.go`; same string in the CRD description). `ConfigSpec` at v0.0.58 is
exactly `{Lifecycle, Priority int32, Revertive *bool, Config []ConfigBlob}` — there is no separate
drift, policy or hold field.

Precedence, verbatim from `https://docs.sdcio.dev/user-guide/configuration/config/config/`
(fetched): *"defines the revertive or non revertive behavior. If not defined the global
configuration, by default to `true`, applies"* — i.e. omitting the field inherits `REVERTIVE`. This
corroborates `evidence/05-kubenet-sdc-kuid.md:483` exactly.

### It is NOT on Target / TargetSyncProfile / TargetConnectionProfile / DiscoveryRule / Schema

Verified by fetching the v0.0.58 CRDs and grepping case-insensitively for `revertive` and `drift`:

| CRD (v0.0.58) | matches |
|---|---|
| `inv.sdcio.dev_targets.yaml` (211 lines) | 0 |
| `inv.sdcio.dev_targetsyncprofiles.yaml` (148 lines) | 0 |
| `inv.sdcio.dev_targetconnectionprofiles.yaml` (164 lines) | 0 |
| `inv.sdcio.dev_discoveryrules.yaml` (353 lines) | 0 |
| `inv.sdcio.dev_schemas.yaml` (265 lines) | 0 |
| `config.sdcio.dev_configs.yaml` | **4** (`spec` + `status.appliedConfig`, v1alpha1 + config) |

`TargetSyncProfileSpec` at v0.0.58 is `{Validate bool, Buffer int64, Workers int64, Sync
[]TargetSyncProfileSync}` — fetched from `apis/inv/v1alpha1/targetsyncprofile_types.go`. No
revertive, drift, deviation or policy field.

### What each mode does on a deviation

Deviation reasons, verbatim from `https://docs.sdcio.dev/user-guide/deviation/` (fetched) and
matching `evidence/05-kubenet-sdc-kuid.md:511-515`:

| Reason | Condition | SDC action |
|---|---|---|
| `UNHANDLED` | no matching `Config` CR (brownfield) | report only, target-scoped `Deviation` |
| `NOT_APPLIED` | matching `Config` exists, device differs | **revertive**: *"SDC will automatically reapply the Config CR when a NOT-APPLIED deviation is detected, restoring the intended configuration."* **non-revertive**: *"SDC will treat the deviation as part of the active configuration."* |
| `OVERRULED` | a higher-precedence (lower-number) intent won | report only, never fight |

`Deviation.spec` is `{deviationType, deviations[]: {path, desiredValue, actualValue, reason}}`;
`reason` is a free `string` in the CRD (`config.sdcio.dev_deviations.yaml:63-65,180-182` — *"Reason
defines the reason of the deviation"*), not a Go enum, so the reason strings are convention, not a
typed API. `deviation_types.go` at v0.0.58 defines no `NOT_APPLIED`/`OVERRULED` constants; the
string is asserted in helpers (`evidence/05-kubenet-sdc-kuid.md:520` cites
`deviation_helpers.go:38` testing `dev.Reason == "NOT_APPLIED"`).

### Does FR-015's "stated on every device configuration resource the provider generates" map to a real field?

**Yes.** It maps to `Config.spec.revertive: true` on every `Config` the provider writes, which is
exactly what `contracts/crd-api.md:217` and the exemplar at `contracts/crd-api.md:262` do. The field
is optional with no CRD default, so "always stated and never left to the layer's own default"
(`contracts/crd-api.md:217`) is a real, enforceable distinction rather than a rhetorical one. This
part of AD-13/AD-17 is well grounded.

One type mismatch worth a line of wording: `DRIFT_POLICY` is a **closed one-member string enum**
while the field it lands in is a **tri-state boolean** (`true` / `false` / unset). The provider's
mapping is `revertive` → `true`; there is no string in the closed set that could ever produce
`false` or unset. That is internally consistent but means the setting's shape does not mirror the
API's, which is worth stating once rather than leaving a reader to infer it.

---

## Q2 — Is a one-member closed enum sensible, or over-engineering?

### The claim that forces the shape is false

AD-17's rationale (`research.md:2264-2268`) and FR-015 (`spec.md:809-811`) both rest on: *"the only
other behaviour the device-configuration layer offers, accepting the device's value as active, is
not repair."*

Non-revertive mode is **not** a terminal accept. At the pinned versions SDC records the deviation
and offers the operator two outcomes, and its own CI exercises both against SR Linux 25.7.1:

- **Accept** — `kubectl sdc deviation ... --accept`, partial or full. Test cases *"Create
  Deviations, Partially accept and Verify, Fully accept and Verify"*
  (`sdcio/integration-tests tests/03-deviations/22-srl-nonrevertive.robot`, fetched).
- **Reject / revert** — test cases *"Reject Deviations and Verify revertive behavior"* and
  *"Partially Revert Deviations by Filter Path and Verify remaining deviations"* (same file). The
  keyword is `kubectl sdc deviation --deviation <name> --revert -n <ns>`
  (`tests/Keywords/deviation.robot`, fetched), and the API object behind it is **`DeviationClear`**,
  present at v0.0.58 as `crds/config.sdcio.dev_deviationclears.yaml` with
  `spec.items[].{type, configName, paths[]}` — i.e. clear-by-path, not all-or-nothing. A
  target-scoped twin, `TargetClearDeviation`, exists in the same CRD set. `evidence/05-kubenet-sdc-kuid.md:525`
  already names `DeviationClear` / `TargetClearDeviation` as "an explicit operator action".

So the upstream layer already supports **hold-and-report, then operator-approved repair** —
precisely the policy AD-17's own rejected-alternatives bullet (`research.md:2269-2272`) describes as
*"a second value that holds the deviation and repairs on operator approval — it repairs, so the
constitution would allow it, but it needs an approval mechanism, a status shape and tests that
nobody has asked for."* The approval mechanism is not missing. It ships, it is a first-class CR, and
it is in the repo's own evidence file. What is genuinely missing is only the *platform's* status
shape and tests for it.

### The three options against FR-015 and Principle I

**(a) No setting at all; revertive hard-wired, stated in FR-015.**
Violates FR-015's own second sentence as written. "Production drift policy MUST be selected
explicitly and MUST NOT be inherited from the lab" (`spec.md:803-805`) is a statement about *who
decides*, not about *how many values exist*. Hard-wiring removes the act of selection entirely: a
production deployment would inherit the lab's behaviour by construction, which is the exact failure
AD-13 was created to close (`research.md:2201-2202`: *"'MUST NOT be inherited from the lab' had no
mechanism; a default* is *inheritance"*). It is also the most surprising option for an operator who
later needs a second policy: there is no seam to widen, so the change is a code change with no
requirement behind it. **Reject.**

**(c) Admit `non-revertive` for production with a recorded constitution exception.**
Principle I (`constitution.md:96-97`) is unqualified: *"detected drift MUST be repaired."* Plain
`non-revertive` with no follow-up is accept-as-active, which is not repair, so this genuinely needs
an amendment. But nothing in this feature asks for it, no success criterion measures it, and
carrying a constitution exception for an unused value is strictly worse than not having the value.
Principle VI's *"a gate MUST NOT be waived to make a run pass"* (`constitution.md:171`) is the same
instinct: do not pre-weaken a rule for a case nobody has. **Reject.**

**(b) Keep the setting, values `{revertive}` now, documented extension rule — current AD-17.**
Best of the three, and already the one implemented across the artefacts. It satisfies
FR-015 literally (a required setting with no default is an explicit selection), satisfies Principle I
(the one admissible value repairs), and leaves a named, requirement-level seam:
`spec.md:812-813` — *"Admitting a second policy is a change to this requirement that names the value
and states how it repairs drift; a policy that does not repair needs a constitution amendment
first."* That two-tier extension rule is well constructed and is exactly right for the
`DeviationClear` case: hold-and-operator-revert repairs, so it enters by an FR-015 change with no
constitution amendment. **Ratify the mechanism.**

### Is it over-engineering?

No — but the *justification* currently offered for it is. A required env var with one legal value is
roughly six lines of start-up validation (T042 already scopes
`cmd/srl-provider/driftpolicy_test.go`, `tasks.md:174`) and buys three things a hard-wire does not:
an explicit production act, a named seam for the second policy, and a start-up refusal that is
testable and observable. That is cheap. What is expensive is the four-place assertion that no other
repairing behaviour exists, because it is wrong, it will be discovered by anyone who opens the SDC
docs, and it is the kind of confidently-stated falsehood Principle I exists to prevent the system
from emitting about itself.

### Most honest and least surprising to an operator

Option (b) with the rationale rewritten. The honest sentence is *"today the platform implements one
policy, `revertive`; SDC also supports hold-and-operator-revert, which this feature does not build,
and which would enter by an FR-015 change naming it"* — not *"`revertive` is the only thing that
could repair."* The first sentence is checkable and survives contact with the upstream docs; the
second does not.

---

## Q3 — Is there a repair-capable policy other than immediate revert?

**Yes, and SDC supports it today.** Three shapes, with what exists upstream for each:

| Shape | SDC support at the pinned versions | Principle I |
|---|---|---|
| **Immediate revert** | `Config.spec.revertive: true` / `REVERTIVE=true`. CI-covered: `tests/03-deviations/12-srl-revertive.robot` (fetched) — delete and adjust device config for five intents across three SR Linux nodes, assert the intent comes back, 2-minute eventual timeout | Admitted; this is the current choice |
| **Report and block Ready until the operator reverts** (hold-down / revert-after-alert) | `spec.revertive: false` **plus** `DeviationClear` (`kubectl sdc deviation --revert`, `spec.items[].paths[]` for partial revert). CI-covered: `22-srl-nonrevertive.robot` "Reject Deviations and Verify revertive behavior" and "Partially Revert Deviations by Filter Path" | **Admitted** — it repairs, the repair is just operator-gated. Under AD-17's own extension rule this needs an FR-015 change, not a constitution amendment |
| **Timed hold-down then auto-revert** | No upstream timer. Would be first-party: hold `revertive: false`, run a timer, then emit a `DeviationClear` or flip `spec.revertive` | Admitted in principle. But `data-model.md:1234-1238` shows this feature's aversion to timers on repair paths, and FR-103 forbids timers on the release path; a new timer would need its own decision |

The platform would also need to supply what SDC does not: a condition/reason shape so a held
deviation shows as `Ready=False` naming the path (Principle I's *"Status conditions MUST name the
specific missing invariants"*, `constitution.md:98-99`), and the RBAC to create `DeviationClear`.
Neither is in scope here — which is the correct reason to defer it, and the reason AD-17 should
give.

One consequence worth flagging: under the current closed set the platform never creates a
`DeviationClear`, so the provider needs no permission on `deviationclears` /
`targetcleardeviations`. T042's RBAC (`tasks.md:174`) enumerates `genidclaims` and `vlanclaims`
verbs precisely and says nothing about the SDC deviation group. That is consistent with AD-17 but is
currently implicit; a least-privilege review would want it stated.

---

## Q4 — Consistency check across the feature directory

Every statement of the drift policy found by grepping for `DRIFT_POLICY`, `revertive`,
`non-revertive` and `drift` across `*.md` in the feature directory.

### Agreeing with AD-17 (no action)

`spec.md:806-813` · `data-model.md:1239-1242` · `contracts/reconciliation.md:133-146` ·
`contracts/crd-api.md:217-223` · `plan.md:263-270`, `:457`, `:764-767`, `:1047` ·
`quickstart.md:478-483`, `:1365` · `tasks.md:174` (T042), `:182` (T048), `:498` (T141) ·
`traceability.md:366` · `checklists/clarify-delta.md:105-107` (CHK022) and `:159-162` (CHK037) —
both correctly open, both reviewer-owned.

### C-1 — HIGH — T036 asks four CRs to state a field none of them has

`tasks.md:168` (T036) requires the onboarding manifests
`deploy/sdc/onboarding/{schema.yaml,target-connection-profile.yaml,target-sync-profile.yaml,discovery-rule.yaml}`
to carry *"the **lab revertive drift policy stated explicitly** — never implied by an absent field,
and `make sdc-onboard` refuses an onboarding set that does not state it (FR-015, AD-13)"*.

Per Q1, **none of `Schema`, `TargetConnectionProfile`, `TargetSyncProfile` or `DiscoveryRule` has a
revertive field at v0.0.58** (0 matches in all four fetched CRDs). The only places the policy is
expressible are `Config`/`ConfigSet.spec.revertive` — which T036 does not author, T042's provider
writes — and the `REVERTIVE` env var on the `data-server-controller` StatefulSet
(`evidence/05-kubenet-sdc-kuid.md:318`), which is not one of the four named files and is not part of
the onboarding set at all.

As written, T036 is unimplementable and `make sdc-onboard`'s refusal check has nothing to match.

**So: is the policy stated in one place or two, and can they disagree?** Two, and yes. T036 states
it in the onboarding manifests; T042 states it as the provider setting that lands on every `Config`.
If T036 is reinterpreted as "set `REVERTIVE=true` on the SDC data-server deployment" — the only
reading with a real field behind it — then the two become a genuine pair that can disagree: an
onboarding set with `REVERTIVE=false` and a provider with `DRIFT_POLICY=revertive` would *not*
misbehave (the explicit `spec.revertive: true` on each `Config` wins over the global per
`docs.sdcio.dev` config page), but the manifests would assert a lab policy the platform does not
follow, and `make sdc-onboard` would pass. The inverse — onboarding `REVERTIVE=true`, provider
refusing to start — is caught by T042. The asymmetry is the hazard.

The cleanest resolution is that the policy has **one** normative home, `Config.spec.revertive`
written by the provider from `DRIFT_POLICY` (T042), and that T036's clause becomes a defence-in-depth
statement about the SDC deployment's global default, explicitly named as such and pointed at the
right file. Proposed wording below.

### C-2 — HIGH, UNVERIFIED — the drift test may assert an artefact revertive mode races away

`tasks.md:228` (T064): *"drift asserts a `Deviation` with `NOT_APPLIED` then restoration"*.
`quickstart.md:444-446` expects the same: a `Deviation` naming path, desired and actual value with
reason `NOT_APPLIED`, *"and the desired value reapplied"*. `plan.md:785` and `tasks.md:228` also
rely on an injected `inter-as-vpn` removal persisting long enough for the service to report
`RoutesMissing` *"before the revertive policy restores the setting"*.

Upstream's own tests suggest this ordering is not free. `22-srl-nonrevertive.robot` (fetched)
**patches `spec.revertive: false` on every intent in `Setup`** before injecting deviations, and it
is the non-revertive suite — not the revertive one — that carries `Verify Deviation on k8s`
(`tests/Keywords/deviation.robot`, which counts `.spec.deviations | length`). The revertive suite
`12-srl-revertive.robot` asserts only that the device configuration returns; it never asserts a
`Deviation` CR was observable. Whether a `Deviation` with `NOT_APPLIED` is durably visible in
`revertive: true` mode, or is reconciled away between the sync cycle and the deviation manager's
poll, is **UNVERIFIED** — I did not find a stated sync or poll interval in a source I fetched.

If a `Deviation` is not reliably observable under `revertive: true`, then SC-007's *"detected and
restored"* has only its second half testable, and T064 and the `quickstart.md` §8 walkthrough both
fail or flake for a reason that is not a platform defect. This needs to be observed, not assumed —
the same discipline `tasks.md:228` already applies to the delete-while-unreachable case (*"**observes**
what SDC does"*).

### C-3 — MEDIUM — `research.md` contradicts itself

`research.md:180-181`: *"the lab sets `revertive: true` so drift on a platform-owned path is
restored; **production drift policy is an operator decision** and must not be inherited from the
lab."*
`research.md:1128`: *"lab `revertive: true` and **production policy explicit**"*.

Both predate AD-17 (`research.md:2259`) and both survive in the same file, reading as though a
production deployment may choose something other than `revertive`. Under AD-17 the only decision
left is *to state* `revertive`. Same file, opposite implication.

### C-4 — MEDIUM — "lab" scoping in the carriers is now vestigial and misleading

`spec.md:219-221` (US2 Independent Test): *"restores drift **in lab revertive mode**"*.
`spec.md:233-234` (US2 scenario 4): *"recorded and the desired value restored **in lab revertive
mode**"*.
`spec.md:1542` (SC-007): *"Drift on a **managed lab path** is detected and restored"*.
Also `plan.md:770`, `:785`, `:972`; `quickstart.md:416`, `:446`; `contracts/reconciliation.md:290`.

Every one of these conditions drift repair on the *lab*. With the set closed at one member, "lab
revertive mode" is a tautology — there is no other mode any deployment may run — and the phrasing
implies a production mode that behaves differently, which AD-17 exists to deny. It also sits awkwardly
against Principle I (`constitution.md:96-97`) and FR-107 (`spec.md:910-911`), both of which require
repair unconditionally, not "in lab mode". SC-007 is the sharpest case: as the measure of FR-015 it
should measure the policy the platform always runs, not a lab-conditioned one.

This is wording, not substance — but it is the wording an operator reads first.

### C-5 — LOW — `contracts/crd-api.md:262` inline comment

`revertive: true                         # lab; production policy is explicit`

"Production policy is explicit" reads as "production may differ". Under AD-17, production states the
same single value. The prose eleven lines above (`:217-223`) is correct; the exemplar comment
contradicts it at the exact point a reader copies the YAML.

### C-6 — LOW — `evidence/05-kubenet-sdc-kuid.md:676` and `:833`

*"lab revertive = `REVERTIVE=true` globally plus `spec.revertive` per Config; production policy
explicit"* and *"**`revertive: true`** in lab; production policy explicit (FR-015)."*

Same pre-AD-17 framing. **Do not edit** — `evidence/` is dated, captured research and its value is
that it says what was known when it was captured. Noted only so that a later reader does not treat
it as a live contradiction. The same applies to `research.md:180-181` if the operator's convention
is that research.md §sections above §13 are historical; if they are not, C-3 stands as a live
inconsistency.

### C-7 — INFORMATIONAL — `spec.md` records no operator ratification

`spec.md:1748-1759` describes AD-16 and AD-17 as *"design choices the operator may reverse"*, closed
*"at the operator's instruction"* to fix everything found — which is an instruction to remediate, not
a ratification of the specific choice. `checklists/clarify-delta.md:159-162` (CHK037) asks exactly
this and is unticked. This review is input to CHK037 and CHK022; neither was ticked here.

---

## Proposed wording changes (proposals only — nothing was applied)

**P-1 — `spec.md:809-813`, FR-015.** Replace the "only other behaviour" clause. Suggested:

> The set of drift policies is **closed and has exactly one member, `revertive`** — a not-applied
> deviation on an owned path is reapplied and the restoration is verified — because constitution
> Principle I requires detected drift to be repaired and this is the only repairing policy this
> platform implements. The device-configuration layer also supports holding a deviation for an
> operator to accept or revert; that is repair, but the platform builds neither the status shape nor
> the approval path for it, so it is not an admissible value here. Any other value, in any spelling
> or casing, is unknown and refuses the start exactly as an absent one does. Admitting a second
> policy is a change to this requirement that names the value and states how it repairs drift; a
> policy that does not repair — such as accepting the device's value as active — needs a
> constitution amendment first.

**P-2 — `research.md:2264-2272`, AD-17 Rationale and Alternatives.** Correct the factual claim: name
`DeviationClear` / `TargetClearDeviation` and `kubectl sdc deviation --revert` as the existing
upstream approval mechanism (already cited at `evidence/05-kubenet-sdc-kuid.md:525`), and restate the
rejection as *out of scope for this feature* rather than *mechanism does not exist*. Keep the
decision and the two-tier extension rule unchanged.

**P-3 — `contracts/reconciliation.md:135-139`, Rule 6.** Replace *"The device-configuration layer
also has a non-revertive mode, which accepts the device's value as active rather than fighting it.
That is not repair"* with the accurate two-outcome description: non-revertive records the deviation
and leaves the operator to accept it (not repair) or revert it (repair, operator-gated); neither
outcome is implemented here, so neither is an admissible `DRIFT_POLICY` value today.

**P-4 — `tasks.md:168`, T036.** Either drop the drift-policy clause from T036 entirely — leaving
`Config.spec.revertive`, written by the provider from `DRIFT_POLICY`, as the single normative
statement (T042) — or rewrite it to name the field that exists: *"the SDC data-server deployment's
global `REVERTIVE` env var set to `true` as defence in depth, stated explicitly in the SDC install
manifest rather than in the four onboarding CRs, none of which has a revertive field at the pinned
versions; `make sdc-onboard` refuses an install set that does not state it."* Whichever is chosen,
state in one line that the provider's explicit `spec.revertive` on each `Config` overrides the
global, so the two can never disagree in effect.

**P-5 — `contracts/crd-api.md:262`.** `# lab and production alike; the value is always stated, never
inherited (AD-17)`.

**P-6 — C-4 wording sweep.** In `spec.md:221`, `:234`, `:1542`, `plan.md:770`, `:785`, `:972`,
`quickstart.md:416`, `:446`, `contracts/reconciliation.md:290`: replace "in lab revertive mode" /
"under the lab revertive policy" / "managed **lab** path" with "under the selected drift policy" or
"under the revertive drift policy", so the criterion measures the policy every deployment runs.

**P-7 — `research.md:180-181` and `:1128`.** If those sections are live rather than historical, add
the AD-17 back-reference so "production drift policy is an operator decision" reads as "production
states `revertive` itself".

**P-8 — `spec.md` FR-015 or `data-model.md` §25.** One sentence on the type mapping:
`DRIFT_POLICY=revertive` → `Config.spec.revertive: true`; the setting is a string because it names a
policy, the field is a boolean because that is what the layer offers.

**P-9 — T042 RBAC, `tasks.md:174`.** State that the provider holds **no** verbs on
`deviationclears` / `targetcleardeviations` in the SDC group, and that a future
hold-and-operator-revert policy would be the change that adds them. Makes the closed set visible in
the permission surface.

---

## UNVERIFIED list, and what should observe each

| # | Claim | Why unverified | Who should observe it |
|---|---|---|---|
| U-1 | A `Deviation` with reason `NOT_APPLIED` is **durably observable** under `spec.revertive: true` before SDC reapplies — i.e. the assertion in `tasks.md:228` and `quickstart.md:444-446` is winnable | Upstream's revertive suite asserts only restoration, never a `Deviation` CR; the non-revertive suite is the one that patches `revertive: false` and counts deviations. No sync/poll interval found in a fetched source | **T064** (`tests/integration/managed_drift.sh`) must *observe* whether the `Deviation` appears, exactly as it already observes the delete-while-unreachable case, and record what it saw. If it is not observable, SC-007 needs a second witness (`Config.status.deviationGeneration` advancing, a device-side commit in `/system/configuration/commit`, or a provider-emitted event) rather than a flaky CR poll. Strongly consider a **new gate item G13** — "a `NOT_APPLIED` deviation on an owned path is visible in a `Deviation` CR under the policy the platform runs, with its negative control" — because this is a platform capability the design depends on and `plan.md:630-641` has no item covering deviation observability |
| U-2 | The `inter-as-vpn` negative control (`plan.md:785`, `tasks.md:228`) holds long enough for the service to report `Ready=False/RoutesMissing` before revertive repair closes the window | Same race as U-1; the fault is injected on a path the fabric `Config` at priority 10 owns (`plan.md:457`), so SDC will fight it | **T064**'s `verify_services.sh` negative control. If the window is too short, the declared injected fault (FR-108) may need the `Config` temporarily set non-revertive by the test itself — which would be a **new** FR-108 boundary question, since it means test tooling mutating a platform-owned `Config` field |
| U-3 | The deviation `reason` strings `NOT_APPLIED` / `OVERRULED` / `UNHANDLED` are stable at v0.0.58 | The CRD types `reason` as a bare `string` with no enum and no Go constants; the strings come from docs and helper tests, not from a typed API | **G10** already covers "the deviated schema still rejects what the platform relies on being rejected" — the nearest fit. Cleanest is to fold the exact observed reason strings into **T064**'s captured evidence, and to treat `OVERRULED` string-matching (which `tasks.md:228` makes a *terminal* condition) as depending on an untyped value |
| U-4 | The `REVERTIVE` env var on `data-server-controller` v0.0.66 is read the way `evidence/05-kubenet-sdc-kuid.md:523-524` states, and an explicit `spec.revertive` always overrides it | The override direction is stated in `docs.sdcio.dev` prose (*"If not defined the global configuration … applies"*), not read from v0.0.66 source | If P-4's second option is taken (T036 keeps a global statement), **T036**'s `make sdc-onboard` check and **T064** should together show that an explicit `spec.revertive: true` wins regardless of the global. If P-4's first option is taken, this stops mattering |
| U-5 | `DeviationClear` at v0.0.58 actually performs a revert rather than only clearing the record | CRD schema and the `--revert` keyword name were verified; the server-side behaviour was not read from source | Nothing in this feature depends on it **today**. It becomes a gate obligation only if FR-015 is ever extended to admit hold-and-operator-revert — at which point it is the new policy's own qualification item |

No claim in this report about the pinned SDC surface is unsourced: `config_types.go`,
`targetsyncprofile_types.go`, `deviation_types.go` and the six CRD YAMLs were fetched at
`config-server` tag `v0.0.58`; `docs.sdcio.dev` config and deviation pages and the three
`sdcio/integration-tests` files were fetched at `main` and are therefore **at or near**, not pinned
to, the reviewed versions — the robot tests in particular are `main`, and `evidence/05-kubenet-sdc-kuid.md:528`
independently records them as running against `ghcr.io/nokia/srlinux:25.7.1`.

---

## Summary of what the operator is being asked to decide

1. **Keep the mechanism** — `DRIFT_POLICY`, required, no default, closed set `{revertive}`. Recommended.
2. **Correct the rationale** in five places (P-1, P-2, P-3, P-5, and `research.md` per P-7): SDC *does*
   have a second repairing behaviour; it is out of scope, not nonexistent.
3. **Fix T036** (P-4) — it currently requires a field that does not exist on any of the four CRs it names.
4. **Decide whether T064 can assert what it asserts** (U-1, U-2) before implementation starts, ideally
   as a new capability-gate item.
5. **Decide the "lab" wording sweep** (P-6) — cosmetic, but it is what an operator reads first, and it
   currently implies a production mode AD-17 denies.

Items 2–5 are amendments; none of them reverses AD-17.

---

## Applied 2026-09-20

Operator decision received and applied. AD-17's **mechanism stands**; its **rationale is corrected**
everywhere; T036 loses its drift-policy clause; gate item **G13** is added. Every edit was made with
the locked atomic editor; no checkbox was ticked; no identifier was renumbered and the only new one
is G13. `evidence/` was not touched — it is dated research and its value is that it records what was
known when it was captured.

### research.md — 12 edits
- `### AD-34: [[STUB-AD-34]]` → full entry **"The drift-policy set stays closed at `revertive`, with
  its rationale corrected *(FR-015, AD-17 — operator decision)*"** in AD-17's format: Decision /
  Rationale / What was verified / Alternatives rejected / Consequences, citing this report and the
  five upstream sources read (`config_types.go`, `config.sdcio.dev_configs.yaml`, the five `inv`
  CRDs, `config.sdcio.dev_deviationclears.yaml`, `docs.sdcio.dev`, the two robot suites).
- **AD-17 Rationale** — anchor *"The only other behaviour the device-configuration layer has is its
  non-revertive mode, which accepts the device's value as active"*: false sentence removed from the
  reason, replaced by "`revertive` is the only policy this platform implements that repairs", plus a
  dedicated *"Rationale corrected by AD-34"* bullet that states what the entry originally claimed and
  why it was wrong.
- **AD-17 Alternatives rejected** — anchor *"it needs an approval mechanism, a status shape and tests
  that nobody has asked for"*: now says the approval mechanism already exists upstream as
  `DeviationClear`; what is missing is this platform's status shape, permission and tests. *"A
  report-only value — needs a constitution amendment first"* → *"a value that only reports and never
  repairs — FR-015 may not admit it while Principle I stands"*.
- **AD-17 What stays true** — anchor *"every `Config` still states the policy"*: names the field.
- **AD-13** — anchor *"Amended by AD-17"*: added *"Rationale corrected by AD-34"* one-liner giving
  what a second value actually costs (repair procedure, status shape, tests, runbook — not an
  amendment).
- **Deviation policy bullet** (C-3a) — anchor *"production drift policy is an operator decision"*:
  rewritten to "stated on every `Config` explicitly, never inherited, closed at one member, and what
  production selects is the same `revertive`, selected by it".
- **Rules-that-come-with-it bullet** (C-3b) — anchor *"lab `revertive: true` and production policy
  explicit"* → *"`revertive: true` stated on every `Config` and never inherited, in the lab and in
  production alike"*.
- `G1 to G12 as written in RD-12 and FR-004` → `G1 to G13 …`.
- **RD-12 Decision** — *"gate is twelve items"* → *"thirteen items"*; **G13** added to the item list
  after G12.
- **RD-12 Rationale** — anchor *"G12 exists because a golden file frozen against a guessed
  serialization form…"*: added why G13 exists (upstream's revertive suite never asserts a
  `Deviation`; the non-revertive suite turns revert off before it counts them).
- **RD-12 Alternatives rejected** — added *"Letting the drift test assert a `Deviation` and marking
  the flake as environmental."*

### spec.md — 6 edits
- **FR-015** — anchor *"the only other behaviour the device-configuration layer offers, accepting the
  device's value as active, is not repair"*: replaced. Now states that the policy lands on the
  resource's boolean revertive field and is never left absent; that `revertive` is the only repairing
  policy *this platform implements*; that non-revertive **records and holds** a deviation for the
  operator to accept or revert, so it is out of scope rather than forbidden; and that a second policy
  is an FR-015 change bringing its repair procedure, status shape, tests and runbook entry — the
  "constitution amendment" clause now applies only to a policy that does not repair at all.
- **FR-004** — anchor *"and the exact JSON serialization the device returns for every rendered
  value"*: the enumerated gate gains "what a managed-path deviation leaves observable under the drift
  policy the platform runs — which decides what the drift check of FR-015 and SC-007 may assert".
  (FR-004 still numbers no items, as instructed.)
- **US2 Independent Test** — *"restores drift in lab revertive mode"* → *"under the revertive drift
  policy"*.
- **US2 scenario 4** — *"recorded and the desired value restored in lab revertive mode"* → restored
  under the revertive drift policy, "and the deviation is recorded in whatever form gate item G13
  observed that policy to leave visible".
- **SC-007** — *"Drift on a managed lab path is detected and restored"* → restored under the
  revertive drift policy, "witnessed as gate item G13 observed it to be witnessable, by the recorded
  deviation where one is durably visible and otherwise by the restored value read back from the
  device".
- **Third pass table, FR-015 row** — the "non-repairing one a constitution amendment first" claim
  withdrawn in place, with the AD-34 pointer. *(No fifth-pass section was created — none existed and
  other agents are editing that area.)*

### tasks.md — 8 edits
- Phase preamble: `G1–G12 capability gate` → `G1–G13`.
- **T036** — anchor *"the **lab revertive drift policy stated explicitly**"*: replaced with **"no
  drift-policy statement of any kind"**, stating that none of `Schema`, `TargetConnectionProfile`,
  `TargetSyncProfile` and `DiscoveryRule` has a revertive field at the pinned versions, that the
  policy has exactly one home (T042's setting → the `revertive` field of every `Config`), and that
  `make sdc-onboard` now asserts the **negative** and fails naming the file.
- **T042** — the setting is named "the only place the policy is stated"; it lands on the `revertive`
  field of every generated `Config` and is never left absent (checked by T027/T053 render
  assertions); production states the same value itself; and the provider identity holds **no** verbs
  on `deviationclears`/`targetcleardeviations`.
- **T043** — script range `g01_capabilities.sh … g12_…` → `… g13_deviation_observability.sh`, and
  **G13** added to the item list: drift injected on a gate-owned scratch `Config`'s path, the answer
  plus the reason strings seen and the time to restoration written to
  `tests/gate/observed/deviation.json`; it **records and does not fail on either answer** — only an
  unobservable deviation *and* an unobserved restoration is a G13 failure.
- **T064** — anchor *"drift asserts a `Deviation` with `NOT_APPLIED` then restoration"*: now asserts
  exactly what G13 observed, read from `tests/gate/observed/deviation.json` — deviation **and**
  restoration where G13 found it durably visible, otherwise restoration alone from device state with
  the deviation reported and not asserted — "and never an artefact G13 found the revertive policy
  reapplies away first".
- **T141** — the runbook clause *"it accepts drift rather than repairing it, which constitution
  Principle I forbids"* replaced with the accurate two-outcome description and "not a constitution
  amendment".
- Phase-narrative line *"drift-revertive in lab mode"* → *"under the one drift policy"*.

### plan.md — 10 edits
- `G1–G12` → `G1–G13` at four sites (P0 summary, Principle VI row, component **C-21**, verification
  inventory row).
- **G13 row added** to the gate table after G12 (re-anchored: another agent had already amended the
  G12 row for AD-31).
- Third-pass constraint summary — *"non-revertive mode accepts drift rather than repairing it and is
  not admissible under Principle I"* → holds the deviation for an operator to accept or revert, a
  shape this feature does not build; "rationale corrected by AD-34".
- Provider drift-policy paragraph — names `spec.revertive: true`, "never leaving the field absent for
  the layer's own global default to supply", production selects the same value.
- *"drift under the lab revertive policy"* → *"under the revertive drift policy"*.
- **SC-007 row** — reworded to the G13-witnessed form.
- **Drift policy** row in the verification strategy — adds that every `Config` states the policy *in
  its `revertive` field rather than leaving it absent*, checked by a render assertion, "because an
  absent field inherits the layer's global default".

### quickstart.md — 5 edits
- **G13 row added** to the §1 gate table after G12.
- §8 expected-outcome line — *"restored under the lab revertive policy"* → *"under the revertive
  drift policy, witnessed as G13 observed it to be witnessable"*.
- **Drift (SC-007) probe expectation** — restoration read back from the device is now the primary
  witness; whether the `Deviation` is also visible is "what gate item G13 observed", and an empty
  `kubectl get deviations` is stated to be the expected result, not a failure, where G13 recorded it
  as not observable.
- **`DRIFT_POLICY` paragraph** — the false "accepts drift instead of repairing it, which constitution
  Principle I does not allow" replaced; adds that the setting is the only place the policy is said and
  that an absent field inherits the layer's global default.
- **Failure table row** — "Admitting another value is a change to FR-015 **that brings its repair
  procedure, status shape, tests and runbook entry with it — not a setting, and not a constitution
  amendment**".

### contracts/reconciliation.md — 3 edits
- **Rule 6** drift-policy bullet — adds "stated on every configuration resource as its revertive
  field, never left absent".
- **Rule 6** non-revertive bullet — rewritten: it does **not** simply accept the device's value; it
  records and holds for accept **or revert**; hold-and-operator-revert is a policy Principle I would
  admit and is inadmissible *here* only because the platform builds neither the `Ready=False` shape
  nor the clearing path.
- Contract-tests **Drift** row — reworded to the G13-witnessed form.

### contracts/crd-api.md — 2 edits
- `revertive: true` bullet — explains that the field is an optional boolean with no default in the
  layer's own schema, so an absent field silently inherits the data-server's global setting; the
  `DRIFT_POLICY` → `revertive: true` mapping is named; non-revertive described accurately.
- Exemplar comment `# lab; production policy is explicit` → `# lab and production alike; always
  stated, never inherited (AD-17, AD-34)`.

### data-model.md — 1 edit
- §25 closing paragraph — adds that production states the same value, and the string-vs-boolean
  mapping (`revertive` → `true`; no member of the closed set can produce `false` or an absent field),
  and that the layer's `false` is not "accept the drift".

### traceability.md — 5 edits
- FR-004 row and RD-12 row: `G1–G12` → `G1–G13`, RD-12 noting the deviation-observability item.
- AD-17 row: false fact removed, "**Rationale corrected by AD-34**" appended.
- AD-13 row: names the field; AD-34 pointer.
- **AD-34 row added** after AD-31, in the operator-decision format used by AD-31.

### platform-coupling.md — 3 edits
- PC-02: *"Twelve gate items"* → *"Thirteen"*; G13 appended to the enumerated list.
- PC-A-03: *"**G1 to G12**"* → *"**G1 to G13**"*.

### Deliberately not changed
- **Golden-file freezing still hangs on G12** — `plan.md` "golden files are frozen only after gate
  item G12", R-02, R-36, T047, T053, T063, T113, the "provisional until G12" rule, `quickstart.md`
  §"path register", `contracts/acl-render-contract.md` and PC-A-12 are all untouched, as instructed.
- **`evidence/05-kubenet-sdc-kuid.md`** (`:526`, `:676`, `:833`) and `evidence/01-lab-platform.md`
  — dated research reports, left verbatim. §3.4 already names `DeviationClear` /
  `TargetClearDeviation`, which is the evidence AD-34 rests on, so no note was needed.
- `checklists/` — untouched and unticked. CHK022 and CHK037 remain open; AD-34 is their input.
- Other agents' files under `review/` and the concurrent AD-31/AD-35/AD-36 edits — untouched.
- `.specify/memory/constitution.md` — untouched.

### For the coordinator to add (identifiers I may not create)
1. **A `tests/gate/g13_deviation_observability.sh` task line.** I folded G13's script into **T043**'s
   per-item list as instructed, and T043 already carries the scratch-removal read-back that G13's
   injected drift needs. No new task id was created.
2. **A dependency edge T064 → T043.** T064's drift assertion now reads
   `tests/gate/observed/deviation.json`, exactly as T047 reads `tests/gate/observed/serialization.json`
   and declares `(depends on T043)`. T064 declares no dependency today; it should.
3. **A risk id for the observability race**, if one is wanted: *"SC-007's drift check may have no
   durable artefact to assert — the revertive policy can reapply before the `Deviation` is visible;
   G13 decides the assertion before the test is written, and T064 asserts only what G13 recorded."*
   It is currently carried only by G13 and by U-1 in this report.
