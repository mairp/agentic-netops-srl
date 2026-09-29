# Contract: allocation claim profiles per construct

**Feature**: `004-agentic-netops-composite` | **Carries**: FR-062, FR-056, **FR-104**, **FR-109** |
**Decisions**: D-22, D-25, RD-09, **CD-03**, **AD-09**, **AD-10**, **AD-16**, **AD-27**,
**AD-32**, **AD-33**, **AD-41**, **AD-42**, **AD-44**, **AD-47**, **AD-51**, **AD-56**, **AD-74**

**Consumers**: the allocator, its claim client, the tier configuration, the index manifests, and the
provider's `Network` reconciler (§8).

No identifier the platform *allocates* is ever generated locally (FR-062). Every claimed value below
comes from a claim against the existing allocation authority and is released when intent is
withdrawn or declined (FR-056). Values the platform **derives** are not claims and are not released;
they are shown in the assignment exactly as they will be rendered, so the second confirmation covers
them too (FR-062).

## 1. Indices

| Index | Group / kind | Range | Configuration variable |
|---|---|---|---|
| VNI index | `genid.be.kuid.dev/GENIDIndex`, 32-bit | 10000–20000 | L2VNI and L3VNI index names |
| VLAN index | `vlan.be.kuid.dev/VLANIndex` | **1000–4000** | VLAN index name |

**Two VLAN bands, and they do not overlap (AD-33 — operator).** The VLAN space this platform uses is
`100–4000`, split once and for all:

| Band | Who chooses it | Is it claimed? |
|---|---|---|
| **100–999** — the *naming band* | the operator, by naming a VLAN in a request or writing one into a `Network` | **never**; its exclusivity is the one-owner rule of FR-034 |
| **1000–4000** — the *allocation band* | the allocation authority, when no VLAN was named | **always**; it is the VLAN index's own `minID`/`maxID` |

A VLAN outside `100–4000` is refused as before, **with both bands stated**. The split is a chosen
naming band, not a derived one — nothing is reserved on the device and no VLAN is derived from
another identifier (R-28's evidence is untouched; see §2 rule 1). Because the bands are disjoint, an
allocated VLAN can never equal a VLAN an operator named, so the collision AD-27 guarded is
structurally impossible rather than detected. The naming band is enforced by `minID: 1000` on the
VLAN index — the authority cannot hand out a value below it — and by a range rule on the named path
(§2 rule 1).

**Two ranges, two names (AD-10).** The *allocation band* is the VNI index's own range, `10000–20000`
by default; the *device range* is `1–65535`. The CRD's CEL rule enforces the device range; the
translator and the allocation authority enforce the allocation band. "The VNI band" below always
means the allocation band.

**The VNI band MUST be a subset of `1–65535`.** The device's EVPN instance identifier (`evi`) is
`1..65535`, and this platform derives `evi := vni` (§2). Widening the VNI index above 65535 would
break that derivation silently, at the device's own `evi` validation rather than at request time. A
VNI outside the band is refused naming the VNI and the band (FR-034). The band `10000–20000` sits
entirely inside the device range, which is what makes the derivation legal
(`evidence/02-evpn-constructs.md` §8.2).

**The route-target index is REMOVED.** An earlier design claimed a 2-byte-AS target from
`extcomm.be.kuid.dev/EXTCOMMIndex`. Route targets are no longer claimed: they are rendered
explicitly as `target:<fabricASN>:<vni>`, a pure function of an already-claimed VNI and one
fabric-wide constant. Removing the index deletes a whole index family from the critical path and
removes a class of leakable claims (D-25's concern). **Revisit trigger** — the index returns only
when one of these enters scope: asymmetric import/export (hub-and-spoke), route-target based leaking
between tenants, or interoperation with a device that derives route targets differently. None is in
the four constructs today.

**Supersession applied.** An earlier decision targeted the `id.kuid.dev` group; the served groups are
the `*.be.kuid.dev` ones above, and those are what this contract and the RBAC rule in
[kubernetes-objects.md](./kubernetes-objects.md) name (D-22).

**No index is added.** An access list allocates nothing, so giving it an index would create a claim
it can leak (D-25).

**The underlay's addresses and autonomous-system numbers are not the tier's.** They are claimed from
`ipam.be.kuid.dev` and `as.be.kuid.dev` by the **`Fabric` reconciler**, at fabric design time, and
the intent tier neither claims nor releases them. The tier's allocator holds no role in those groups
(§5).

## 2. Profiles

| Construct | VLAN index | VNI index (L2VNI) | VNI index (L3VNI) | Derived, not claimed |
|---|---|---|---|---|
| `vlan` | claim **unless the operator named a VLAN** | — | — | subinterface index := VLAN; instance name `vlan-<serviceId>` |
| `mac-vrf` | claim unless named | claim | — | `evi := l2vni`; VXLAN-interface index := L2VNI; route distinguisher auto-derived by the device; route targets `target:<fabricASN>:<l2vni>`; subinterface index := VLAN; instance name `macvrf-<serviceId>` |
| `mac-vrf` + anycast gateway | claim unless named | claim | claim | as above, plus `evi := l3vni` for the routed half, route targets `target:<fabricASN>:<l3vni>`, second VXLAN-interface index := L3VNI, `irb0.<vlan>`, instance name `ipvrf-<serviceId>` |
| `ip-vrf` | — (**named or absent; never claimed**, AD-51) | — | claim | `evi := l3vni`; VXLAN-interface index := L3VNI; route distinguisher auto-derived; route targets `target:<fabricASN>:<l3vni>`; routed subinterface index := the attachment's VLAN, or `0` when it names none; instance name `ipvrf-<serviceId>` |
| `acl` | — | — | — | claims nothing; binds to a subinterface another service already created |

**Why the route distinguisher is not in this table at all.** With `evi` set and the distinguisher
omitted, the device derives it as `<system0.0 IPv4 address>:<evi>` — per-leaf unique by construction
and independent of any autonomous-system number. It needs no fabric-wide index, so
`Network.spec.routers[].rd` is removed from the service intent object entirely (RD-09).

**Why route targets are rendered rather than auto-derived.** The device's own auto-derivation uses
the *per-leaf* underlay autonomous-system number, which produces a different route target on every
leaf — the sessions come up and the routes silently never match. `fabricASN` is a single fabric-wide
constant, so `target:<fabricASN>:<vni>` is the same on every leaf by construction.

Two rules that are consequences, not options:

1. **A VLAN the operator named is not claimed, and it comes from the naming band.** The requested
   VLAN wins; two *different* requested VLANs on one service are a contradiction in the request and
   are refused, never silently resolved. A named VLAN **outside `100–999`** is refused **with both
   bands stated**: one in `1000–4000` because that band is the authority's and naming from it would
   collide with a value the authority may hand out; one outside `100–4000` because the platform
   does not use it at all. Nothing is *derived* here and nothing is reserved on a device — SR Linux
   derives no VLAN (R-28, RD-09) — the naming band is a chosen partition of the platform's own VLAN
   space, and it is what makes an allocated VLAN and a named one incapable of colliding (§1, AD-33).

   **Where each half is enforced.** On the tier path the **mapper** refuses a named VLAN outside
   `100–999` at interpretation, before anything is claimed, stating both bands (AD-41): the
   interpretation is the one place where a VLAN is known to have been *named*, because it exists
   before the allocator has run. The translator cannot make that distinction and is not asked to —
   its input is the allocator's output, in which a named VLAN and an allocated one are the same
   bare integer, and no provenance field is added to tell them apart — so it keeps only the
   structural `100–4000` check, as the CRD's CEL rule does. On the cluster-tooling path a `Network` cannot say whether
   its VLAN was named or allocated, so **the rule is stated in terms of the value**: a VLAN in
   `100–999` is a named VLAN and is backed by no claim; a VLAN in `1000–4000` **MUST** be backed by
   an adoptable bound claim under the three-part adoption rule of §8 — correlation label,
   deterministic claim name and carried value (AD-42) — and an object carrying one that is
   not is `Accepted=False/AllocationConflict` naming the VLAN and both bands, with nothing rendered.
   The CRD's CEL rule stays the structural `100..4000` (`contracts/crd-api.md`): CEL cannot see a
   claim, so it is never asked to tell a named VLAN from an allocated one.

   **The VLAN on a standalone `acl`'s attachment is a reference, and neither band rule applies to
   it (AD-47).** It names the subinterface another service already created and creates nothing, so
   it is not a VLAN of the `acl`'s own: the mapper does not hold it to the naming band — the
   subinterface it names may well carry an allocated VLAN — and the provider's claim gate asks for
   no claim behind it on an `accessLists`-only object, because the claim, where there is one,
   belongs to the service that owns the subinterface. It stays inside the structural `100–4000`
   and it must resolve to a subinterface that exists (`contracts/crd-api.md`, "Standalone list
   needs its subinterface").

   **An `ip-vrf` attachment's VLAN is named or absent — it is never allocated (AD-51 —
   operator).** An operator who wants a tagged routed subinterface names its VLAN, from the naming
   band like any other named VLAN, and it claims nothing; an attachment that names none is the
   untagged subinterface `<port>.0`. The allocator claims no VLAN for an `ip-vrf` on any path, so
   the only VLAN claims that exist are the one behind a `vlan`'s `vlans[]` entry and the one behind
   a `mac-vrf`'s `bridgeDomains[]` entry — both named entries, which is what lets §5 name their
   claims. It follows that **no adoptable claim can exist behind an `ip-vrf` attachment's VLAN**:
   on an object applied with cluster tooling one in `1000–4000` is the `AllocationConflict` refusal
   of §4, by construction and not by lookup.
2. **The release path MUST assert that the route-target claim count is zero** for every construct,
   the same discipline `acl`'s zero-claim release already needs. Without the assertion the removed
   index becomes dead code nobody notices has started claiming again.

*Deleted by the retarget (RD-09): the rule "an L3VNI is claimed from the sub-band that has a
derivable routed-instance VLAN". This platform derives no routed-instance VLAN, so the sub-band has
no referent; PC-15 is deleted with it.*

**Why profiles exist at all**: the allocator previously claimed a VNI and a route target
*unconditionally*, so a `vlan` would strand an L2VNI it never renders and an `acl` would strand both
(D-25).

## 3. Release

Release by correlation identifier releases exactly what the profile claimed. **For `acl` that is
zero claims — the release path must handle "nothing was claimed" as a success, not as a
missing-claims error**, or a declined access-list request reports a spurious failure.

The decline check is therefore a label-selector diff: claims carrying the request's correlation
label must be empty after a decline (SC-026).

**Who releases what** (FR-109, AD-16). The tier releases a claim only while it is *provisional*: on
decline, on rollback of a failed submission, and for a request that was never submitted. Once the
`Network` it backs has been submitted the claim is the **provider's** to hold and release — VNI and
VLAN alike (§8) — so removal through the tier and `kubectl delete` end the same way: the finalizer
releases every adopted claim after the removal is read back, and a held deletion holds them
(FR-103). The tier's removal path deletes the `Network` and nothing else; it never releases a claim
of a submitted service, because doing so before the read-back would hand out an identifier a device
may still carry.

**What decides that a claim is still provisional, and who asks (AD-32 — operator).** "Submitted"
means the `Network` exists. The **deployer** is what determines that — it already reads `networks`
in the intent namespace and nothing else — and the tier's release path acts only on the correlation
identifiers the deployer names as releasable. **The allocator never reads a `Network`**; it deletes
the claims it is told to delete. No tier identity gains a verb for this, so the exact verb sets of
FR-075 are unchanged. A release requested for a correlation identifier whose `Network` exists is
refused by the deployer, named, and audited.

**Where the labels live (AD-32).** Every claim the tier or the provider creates carries its
correlation identifier and its object identity in **`metadata.labels`**, because that is the only
label set the allocation authority's `List` filters on — the aggregated apiserver matches
`options.LabelSelector` against `accessor.GetLabels()`
(`pkg/registry/generic/strategy_resource.go`, observed at the pinned `v0.0.13`). The authority's own
`spec.labels` / `spec.selector` fields are **not used by this platform**: a label written there is
invisible to `kubectl get … -l` and to every claim-selector diff this specification relies on
(SC-026, SC-045, SC-046). One selector is canonical for "the claims of this service" — the
correlation label `agentic-netops.io/correlation-id` for a tier-submitted service, and the object
labels `agentic-netops.io/network-namespace` + `agentic-netops.io/network-name` for a claim the
provider created; both are `metadata.labels` and a claim carries whichever its maker sets. That
labels are selectable on this authority is a **gate observation**, item G11, not an assumption.

## 4. Failure modes the profile must state

| Condition | Outcome |
|---|---|
| Index exhausted | A named exhaustion failure stating the index and its range; nothing submitted |
| Allocation authority unreachable | A bounded retry with backoff, then a **terminal failure of that request naming the authority**; nothing is claimed and nothing is submitted. *There is no local lease, pool or fallback at run time* — the earlier "lease fallback" row is withdrawn, because a second source of identifiers is a second allocation authority, and exactly one may exist (FR-104) |
| A construct asks for an identifier its profile does not claim | a validator cause naming the property and the construct that carries it, not a silent claim (FR-033) |
| A named VLAN outside the **naming band** `100–999`, or a VNI outside the VNI band | refused naming the value and **both VLAN bands** — `100–999` to name from, `1000–4000` the authority's — or, for a VNI, the value and the band (FR-034, AD-33). The named-VLAN refusal is the **mapper's**, at interpretation and before any claim; the translator checks only the structural `100–4000` (§2 rule 1, AD-41). The VLAN a standalone `acl` names is a reference and is not held to the naming band (AD-47) |
| An **allocated** VLAN equal to a VLAN another service **named** | **Cannot occur** (AD-33). The allocation band `1000–4000` and the naming band `100–999` are disjoint, so a value the authority hands out is never a value an operator was allowed to name. The refusal path AD-27 defined for this case is withdrawn with the case; no retry, no second claim and no `Network` read is needed, and the allocator still never reads a `Network` (FR-075). What remains is the genuine conflict below |
| Two services asking for the same **(node, port, vlan)** — both named, or one named and one an attachment of an object applied with cluster tooling | The one-owner rule of FR-034 refuses it: the deployer's pre-flight refuses before anything is created, naming the VLAN, the port and the holder; the cross-object webhook refuses the same case at the server-side dry-run and sees both service namespaces alike, so a holder in `agentic-netops-services` is caught even though the pre-flight cannot see it. Every provisional claim of the request is released; **no other value is tried silently** (FR-062, FR-034) |
| A `Network` applied with cluster tooling carrying a VLAN in the **allocation band** `1000–4000` that no adoptable claim backs | `Accepted=False/AllocationConflict` naming the VLAN and both bands, with nothing rendered — the object either arrived from the tier with its claim or it names a VLAN from `100–999` (§2 rule 1, §8, AD-33). An `accessLists`-only object is the one exception: its attachment VLAN is a reference to another service's subinterface and needs no claim (AD-47). An **`ip-vrf` attachment** carrying a VLAN in `1000–4000` is always this refusal: the allocator never allocates one, so no claim it could be adopted on exists or has a name (§2 rule 1, AD-51) |
| The allocation authority **errors or cannot be reached** while the *provider* looks a claim up, creates one or deletes one — as opposed to answering that no such claim exists | **Never read as "nothing adoptable", and never reported as `AllocationConflict`** (AD-56). Before a render it is a dependency wait — the object stays where an unbound claim leaves it, nothing is rendered, and the pass is retried with bounded exponential backoff ([reconciliation.md](./reconciliation.md) Rule 3). In finalization the finalizer stays, `Deleting=True/RemovingConfiguration` stays with the authority named in its message, nothing is released and the pass is requeued the same way (Rule 8 steps 1 and 6). "No such claim" is an answer; an error is not one |
| A claim that reports no allocated value in status | terminal for the request — the platform never proceeds on an unknown identifier (R-31, gate item G11) |

## 5. Identity

The allocator's cluster identity holds a narrow Role in `kuid-system` limited to claim objects in
**exactly two groups** — `vlan.be.kuid.dev` (`vlanclaims`) and `genid.be.kuid.dev` (`genidclaims`) —
with `get`, `list`, `watch`, `create`, `delete` and deliberately **no `update` and no `patch`**, so
the tier can claim and release but cannot retarget an existing claim. That withholding is better
founded than "cannot retarget" suggests: at the pinned authority an update re-runs the claim through
the same applicator as a create, so a changed `spec.id` **moves** the allocation and silently
releases the previous entry (`pkg/backend/invoker.go`, `pkg/backend/generic/applicator.go`, read at
`v0.0.13`). An identity with `update` could free an identifier a device still carries without any
read-back. The same reasoning is why the provider holds no `update` or `patch` either. It receives no access to
indices, to the `ipam` or `as` groups, to Secrets, or to any other resource in that namespace. It
holds **no verb on `networks` anywhere**, and AD-32's release gate does not give it one: the
deployer decides what is releasable (§3). Every claim the tier creates carries the correlation label
in `metadata.labels`, so its footprint is enumerable (R-16).

**A claim the provider will adopt is named deterministically — VLAN and VNI alike (AD-32, AD-42,
R-45).** There is **one** naming scheme, `<namespace>.<name>.<role>`, and the allocator and the
provider both use it. A VLAN claim the allocator creates for a service is named
`<intent-namespace>.migr-<serviceId>.vlan-<entry>` (entry = the **name** of the `vlans[]` or
`bridgeDomains[]` entry the VLAN belongs to — those two lists and no other: an `attachments[]`
entry has no name, and none is needed, because an attachment's VLAN is the entry's own on a `vlan`
or `mac-vrf` and is never claimed on an `ip-vrf`, AD-51); a VNI claim it creates is named
`<intent-namespace>.migr-<serviceId>.l2vni-<bridgeDomain>` or
`<intent-namespace>.migr-<serviceId>.l3vni-<router>` — the role strings the provider uses for the
VNI claims it creates itself (§8), so there is one name for the claim behind one field of one
object, whoever made it. The allocator can form every one of them: the intent namespace is fixed and `serviceId` is carried from the
interpretation ([../data-model.md](../data-model.md) §20), so the `Network` name `migr-<serviceId>`
is known before the claim is made, and the entry names are functions of it (`vlan-<serviceId>`,
`bd-<serviceId>`, `vrf-<serviceId>`, [network-spec.md](./network-spec.md) §2). The claim's *name*
therefore carries the identity of the `Network` that will adopt it, not only its labels. The
provider adopts a claim — a VLAN claim or a VNI claim, by one rule — only when the name, the
correlation label **and** the reported value all agree with the object (AD-42). A claim mislabelled with another service's correlation identifier therefore cannot be
adopted for it, which is what R-45 needs; and because the provider holds no `create`, `update` or
`patch` on `vlanclaims`, it can release what it adopted and nothing more.

**The name always fits (AD-56).** A claim is a Kubernetes object and its name a DNS-1123 subdomain
of at most 253 characters, so the three parts are bounded where they are declared: a namespace is
at most 63 characters, `Network` `metadata.name` is a DNS-1123 **label** of at most 63, and the
names of `vlans[]`, `bridgeDomains[]` and `routers[]` entries are DNS-1123 labels of at most 63
([crd-api.md](./crd-api.md) rule table, "Name shape"). The longest role prefix is six characters
(`l2vni-`, `l3vni-`), so the longest name is `63 + 1 + 63 + 1 + 6 + 63 = 197`, inside the limit
with room to spare, and every character of it is one a subdomain admits. On the tier path
`serviceId` is itself a DNS-1123 label of at most 15 characters (both JSON schemas), so
`migr-<serviceId>` is at most 20.

The **provider's** identity holds `get`, `list`, `watch`, `create`, `delete` — and likewise no
`update` and no `patch` — on `genidclaims` in the same namespace, for §8, beside the `ipam` and `as`
claims its `Fabric` reconciler already makes. On `vlanclaims` it holds `get`, `list`, `watch` and
`delete` only — **no `create`**, because a named VLAN is never claimed and the provider never claims
one; it needs to read the tier's VLAN claim to adopt it and to delete it at finalization (§8,
AD-16).

## 6. Pin and its risk

As decided (AD-74, 2026-09-21), G11 failed on `kuid-server v0.0.13` and this lab runs the first-party
substitute of §7 (`docs/decisions/allocator-substitution.md`): the lock selects
`allocationAuthority.kind: first-party`, and the claims below are `IdentifierClaim`s against
`IdentifierPool`s in `agentic-netops-allocation`, with the semantics of §1–§5 unchanged. The rest of
this section describes the upstream authority the lock can select instead.

The upstream allocation authority is `kuid-server` **`v0.0.13`**, pinned by digest in the lock file. Its
allocation APIs are aggregated APIServices in the `*.be.kuid.dev` groups, not CRDs, so their
availability is a cluster-level dependency rather than a set of installed schemas.

**The project is dormant upstream** — its last release predates this specification by well over a
year — and that is recorded as **R-31** rather than assumed away. The dormancy is qualified at P0,
not silently: **gate item G11** claims a VLAN and a VNI against the pinned server on the pinned
cluster and requires that each claim reports its allocated value in status (`status.id`, the claim
`Ready`) and that the aggregated API is healthy; a claim that reports no value is terminal (§4).
**Six observations** ride on the same item, each of them something this contract reads from source
and refuses to assume. **This is the one list and the one count** — the plan's gate table, R-44,
research Open item 15, quickstart's gate table and T044 cite it and do not re-count (AD-56):

| | G11 observes that | Because |
|---|---|---|
| (a) | a claim for a **stated** value binds exactly that value | FR-109's claim path states a value (§8) |
| (b) | a second claim for the same value is refused **naming the holder** | it is where `AllocationConflict` takes its holder from |
| (c) | **which value** a dynamic claim returns — three consecutive ones recorded | whether the authority allocates the lowest free value or an arbitrary one is unknown from source; it decides nothing now that the bands are disjoint, and is recorded rather than guessed (AD-33) |
| (d) | no dynamic claim is ever handed a value **below the index's `minID`** | it is what makes the naming band of §1 safe |
| (e) | a claim's **`metadata.labels` are selectable** through the aggregated API | every claim-selector diff here depends on it (§3) |
| (f) | deleting a claim frees its value **synchronously** — a stated-value claim is deleted and an immediate second claim for the same value binds | Rule 8's release step rests on it (AD-47) |

Each has a negative control (T044). A failure of any of them is a G11 failure and takes FR-104's
path.

## 7. If G11 does not hold (FR-104, CD-03)

**Provisioning stops, non-zero, naming G11, and installs nothing above the authority.** The script
never selects another allocator, and offers no flag that does.

The one permitted substitution is a first-party allocator adopted by an **operator decision recorded
before anything is installed** — `docs/decisions/allocator-substitution.md`, citing the run-captured
G11 failure by path and SHA-256 — and selected through the lock file
(`allocationAuthority.kind: first-party`), which `make verify-pins` refuses without both references.

**The switch has a precondition and a way back, both required by FR-104.** A substitution is adopted
on a lab that holds **no bound claim**: when the lock file selects an authority other than the one
installed, provisioning lists the claims the installed one holds and, if any is bound, stops
non-zero before touching either authority, naming each service that rests on one. Those services are
removed first and re-created after the switch — no claim survives a change of authority, and none is
migrated or copied across. **Returning to the upstream authority is the same decision in reverse**:
it is recorded in the same file, as a dated return entry stating its reason, it has the same
no-bound-claim precondition, and `make verify-pins` refuses `kind: kuid` while that file records an
adoption with no later return. The returned authority then faces G11 like any other — a return is
not evidence that it passes, and provisioning stops on it exactly as before if it does not.

| What changes under substitution | What does not |
|---|---|
| The claim kinds: `IdentifierPool` and `IdentifierClaim` in **`fabric.agentic-netops.io/v1alpha1`** — never in, and never imitating, a `*.be.kuid.dev` group (FR-098) | The profiles of §2: which construct claims what, from which band |
| The namespace: `agentic-netops-allocation` instead of `kuid-system` | The release semantics of §3, including "nothing claimed" being a success |
| The allocator's Role: `identifierclaims` in that namespace | Its verbs — `get`, `list`, `watch`, `create`, `delete`, and deliberately **no `update` and no `patch`**; `spec` is additionally immutable by CEL |
| The `Fabric`'s pool references: group and kind | The failure modes of §4; a claim still reports its allocated value in status, and a claim that does not is terminal |
| The upstream authority is **not installed at all** — the two never coexist, asserted by `make verify-compat` | The assignment contract and everything above the allocator's claim adapter |

Which authority a lab runs is recorded in the compatibility set (FR-017) and warned by name on every
provisioning run. The substitute's contract is fixed here; it is **built only on a recorded
decision**, not in advance.

## 8. The provider's side of the claims: adoption, and a `Network` that arrives without the tier (FR-109, AD-09, AD-16)

A `Network` applied with cluster tooling names its VNIs; nobody has claimed them. The provider does,
before it renders anything, through the same `pkg/kuid` adapter seam. A `Network` the tier submitted
already has its claims; the provider adopts them, so that it — and only it — releases them:

| Step | Rule |
|---|---|
| Adopt | A **bound** claim carrying the object's correlation label, bearing the deterministic name of §5 for that field (`<namespace>.<name>.l2vni-<bridgeDomain>` or `.l3vni-<router>`) **and** reporting exactly that value is adopted — this is the tier's claim. All three must agree (AD-42): a label match with a different value is not adopted, and neither is a label-and-value match under any other name, so an object that copies another service's correlation label adopts none of its claims |
| Adopt (VLAN) | The same three-part rule over `vlanclaims`, and the VLAN it reports must be the one the named entry carries — `spec.vlans[].vlan` or `spec.bridgeDomains[].vlan`, those two fields and no other. The claim's name must also match the deterministic shape of §5, which names that entry. **An attachment's VLAN is never matched on its own** (AD-51): on a `vlan` or `mac-vrf` it is the entry's VLAN, by the one-VLAN-per-bridge-domain rule, and on an `ip-vrf` it is named or absent and never claimed — so an `ip-vrf` attachment carrying a VLAN in `1000–4000` has no adoptable claim by construction and is the refusal of §4. **An `accessLists`-only object is outside this row altogether**: the VLAN on a standalone `acl`'s attachment is a reference to a subinterface another service owns, so no claim is looked for behind it and neither band rule applies to it (§2 rule 1, AD-47). There is no *Claim* step for a VLAN: a VLAN in `100–999` with no adoptable claim is a VLAN the operator named and is claimed by nobody (§2 rule 1), while a VLAN in `1000–4000` with no adoptable claim is the refusal of §4, not a VLAN to claim (AD-33) |
| Adopt (once) | **Adoption is evaluated once per value.** A claim recorded in `status.claimRefs[]` as `adopted` stays adopted for the life of the object, whatever a later reconcile finds — a `vlan` or `mac-vrf` whose VLAN was allocated keeps its VLAN claim held and listed until finalization when an attachment carrying it is removed, and an adopted claim is never re-evaluated, dropped or released early (FR-109, AD-25, AD-32; the `ip-vrf` case this row once named no longer exists, AD-51). The predicate above is re-evaluated only for a value that is not already in `status.claimRefs[]` |
| Adopt (at finalization) | **Finalization resolves adoption before it releases (AD-44).** On an object that carries a deletion timestamp the provider first runs the Adopt rows above — the same three-part rule, nothing looser — for every value the object carries that is not yet in `status.claimRefs[]`, records what it adopts, and only then walks Rule 8. A tier-submitted `Network` deleted before the provider's first reconcile therefore reaches the release step with its claims listed, and orphans nothing. No *Claim* row runs on a deleting object: a VNI nobody claimed is not claimed in order to be released |
| Claim | Otherwise a claim **for the stated value** is created in the VNI index, named `<namespace>.<name>.<role>` (role = `l2vni-<bridgeDomain>` or `l3vni-<router>`), labelled `agentic-netops.io/network-namespace` and `agentic-netops.io/network-name` |
| Refuse | The authority reports the value held by another owner, or outside the index's range → `Accepted=False/AllocationConflict` naming the value and the holder or the band; nothing rendered; no other value tried |
| Authority error | A lookup, a create or a delete that **errors** — the authority unreachable, the aggregated API unhealthy, a timeout — is not an answer. It adopts nothing, refuses nothing and releases nothing: the pass is retried with bounded exponential backoff, before a render as a dependency wait and in finalization with the finalizer kept (§4, AD-56). Only "no such claim" lets the *Claim* row, or the refusal of §4, run |
| Record | `status.claimRefs[]`, each marked `adopted` or `created` — the entry's fields are listed once, in [crd-api.md](./crd-api.md) §Status |
| Release | Both kinds, by finalization only, after the removal is read back (Rule 8 step 6); a held deletion holds them (FR-103) |

The provider *creates* nothing for a `vlan` or an `acl`, and that is a success. A named VLAN is not
claimed (§2 rule 1); its exclusivity is the webhook's one-owner rule on (node, port, vlan). An
adopted VLAN claim is recorded in `status.claimRefs[]` as `adopted` and released with the rest.

**The finalizer must be on the object before it is adoptable (AD-32).** The provider's finalizer is
what releases an adopted claim, so a `Network` that carries none has claims with no release owner:
deleted in that window, it takes nothing with it and leaves the tier's claims behind. The deployer
therefore **applies a tier-submitted `Network` with the finalizer already set** — it holds
`create`, `update` and `patch` on `networks` in the intent namespace and needs no new verb for it —
so the object is never finalizer-less. A `Network` applied with cluster tooling receives the
finalizer from the provider on its first reconcile, and the window between the two is the operator's
own: an object applied and then deleted before the provider's first reconcile — the provider slow,
or gone down after the apply was admitted — is deleted outright, and the identifiers it named are
the operator's to account for. The window cannot be widened by applying while the provider is down:
the admission webhook is served by the provider and **fails closed**, so that apply is refused, and
only the delete — which is not intercepted — goes through ([crd-api.md](./crd-api.md), AD-52). The
window is named in the runbook.

**The claim fields this contract names** are the pinned authority's own: a claim states a value in
`spec.id` and reports the allocated one in `status.id`, with `Ready` on the claim; a claim with
neither `spec.id` nor `spec.range` is a dynamic claim. Observed at `v0.0.13`
(`apis/backend/vlan/v1alpha1/vlanclaim_types.go`), re-observed by **G11**, never assumed. Under the
substitution of §7 the same three roles are played by `IdentifierClaim`'s own fields.

**Not assumed**: that the pinned authority binds a claim for a stated value and refuses a second one
is observed by gate item **G11** before the provider relies on it (R-44). Nor is it assumed that the
authority's dynamic allocation returns the lowest free value rather than an arbitrary one, that a
value below the index's `minID` can never be handed out, or that a deleted claim's value is free
as the DELETE returns: G11 observes all of them — the six of §6 (R-44). Under the substitution of
§7 the same steps address `IdentifierClaim`, whose `spec` carries the stated value.
