# Review: AD-16 (provider adopts and releases the tier's VLAN claims) and AD-27 (an allocated VLAN colliding with a named one is refused by name)

**Reviewer**: research agent · **Date**: 2026-09-20 · **Feature**: `004-agentic-netops-composite`
**Status**: recommendation only. Both decisions are the human operator's. Nothing in the feature
directory was modified by this review and no checkbox was ticked.

**Read**: `research.md` §13 AD-09, AD-16, AD-25, AD-26, AD-27; `spec.md` FR-062, FR-075, FR-103,
FR-104, FR-109, SC-045, SC-046, CR-002, CR-003; `contracts/kuid-claim-profiles.md` (all);
`contracts/reconciliation.md` Rule 3, Rule 8; `contracts/kubernetes-objects.md`;
`contracts/crd-api.md`; `contracts/network-spec.md`; `contracts/readme-and-walkthrough.md`;
`data-model.md`; `plan.md` (C-14, P7, P12, P0/G11, R-16, R-28, R-31, R-44, R-45, R-47);
`quickstart.md`; `tasks.md`; `evidence/05-kubenet-sdc-kuid.md`;
`/root/agentic-netops-srl/.specify/memory/constitution.md` Principle II.

**KUID sources**: a local clone at `/root/agentic-netops-srl/kuid`, verified to be the pinned tag —
`git log -1 v0.0.13` = `7528e81528c2e9f586b6fe657907424ad93c7ead`, and `git diff v0.0.13 HEAD --
apis pkg` is **empty** (the only difference to the checked-out `be8e5686` is two files under
`docs/`). Every Go citation below is therefore a v0.0.13 citation. Spot-checked against
`https://raw.githubusercontent.com/kuidio/kuid/v0.0.13/apis/backend/vlan/v1alpha1/vlanclaim_types.go`
(HTTP 200, byte-identical). Kubernetes owner-reference semantics fetched from
`https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/`.

---

## Verdicts

| Decision | Verdict | Confidence |
|---|---|---|
| **AD-16** — the provider adopts the tier's VLAN claims, never creates one, and is the one release owner of every claim of a submitted service | **RATIFY WITH AMENDMENTS** | **High** on the principle and on KUID compatibility; **medium** on the edge cases, because three of the amendments below close leaks the current wording permits |
| **AD-27** — an allocated VLAN colliding with a named one on the requested port is refused by name, with no retry | **RATIFY WITH AMENDMENTS** | **Medium-high**. The refusal must exist whatever else is decided — it is the only outcome available for a holder the tier cannot see. But it is not the only option available, and one structural alternative the analysis agent did not consider removes the edge case instead of reporting it. That one is the operator's to take or leave |

Neither decision needs reversing. Both need their wording tightened, and AD-27 deserves one
explicitly-offered alternative before it is frozen.

---

## Question 1 — KUID facts at v0.0.13

All VERIFIED unless marked. Line numbers are from the local v0.0.13-identical clone; the equivalent
raw URL is `https://raw.githubusercontent.com/kuidio/kuid/v0.0.13/<path>`.

### 1a. Dynamic allocation — YES

A claim with neither `spec.id` nor `spec.range` is `ClaimType_DynamicID`
(`/root/agentic-netops-srl/kuid/apis/backend/vlan/vlanclaim_object.go:225-245`), dispatched to
`dynamicApplicator` (`/root/agentic-netops-srl/kuid/pkg/backend/generic/backend.go:210-225`), which
calls `tree.ClaimFree(...)` on the index tree
(`/root/agentic-netops-srl/kuid/pkg/backend/generic/applicator_dynamic_id.go:135-140`).

### 1b. Claim for a stated/static value — YES. The field is `spec.id`

```go
// VLANClaimSpec defines the desired state of VLANClaim
type VLANClaimSpec struct {
	Index string   `json:"index" ...`
	ID    *uint32  `json:"id,omitempty" ...`
	Range *string  `json:"range,omitempty" ...`
	commonv1alpha1.ClaimLabels `json:",inline" ...`
}
```
`/root/agentic-netops-srl/kuid/apis/backend/vlan/v1alpha1/vlanclaim_types.go:27-40`. `GENIDClaimSpec`
is the same shape with `ID *uint64`
(`/root/agentic-netops-srl/kuid/apis/backend/genid/v1alpha1/genidclaim_types.go:27-40`).

There is **no** field called `vlanID` or `VLANID` — the doc comment says "VLANID defines…" above a
field literally named `ID`. `spec.index` is the **name of a `VLANIndex` object in the same
namespace**; the claim's cache key is `{claim.Namespace, claim.Spec.Index}`
(`apis/backend/vlan/vlanclaim_object.go:52-54`). The claim-type set is
`invalid | staticID | dynamicID | range` (`apis/backend/claim_types.go:19-41`) — there is no
`staticRange`. Setting both `id` and `range` is refused with
`"a claim can only have 1 addressing, got %s"` (`apis/backend/vlan/vlanclaim_object.go:157`).

**Action for the contracts**: `contracts/kuid-claim-profiles.md` and
`contracts/reconciliation.md` Rule 3 both say "a claim for the stated value" without ever naming the
field. They can now say `spec.id`, and `status.id`, by name.

### 1c. Labels and label-selector listing — YES, but the placement matters and the contracts have not said which

KUID claims carry user labels in **`spec.labels`** (a map) and a **`spec.selector`**
(`metav1.LabelSelector`), inlined as `ClaimLabels`
(`/root/agentic-netops-srl/kuid/apis/common/v1alpha1/labels.go:26-49`). `spec.selector` is what
drives a dynamic claim *from inside a named range*
(`pkg/backend/generic/applicator_dynamic_id.go:70-94`).

The aggregated apiserver's `List` filters on **`metadata.labels` only**:

```go
if options.LabelSelector != nil {
	if options.LabelSelector.Matches(labels.Set(accessor.GetLabels())) {
		f = false
	}
}
```
`/root/agentic-netops-srl/kuid/pkg/registry/generic/strategy_resource.go:244-253`.

So `kubectl -n kuid-system get vlanclaims -l agentic-netops.io/correlation-id=$CID`
(`quickstart.md:1201`) works **only if the allocator writes the correlation label into
`metadata.labels`**. Labels written into `spec.labels` are invisible to `-l`. Every claim-selector
diff in this specification — SC-026, SC-045, SC-046, `quickstart.md:1082-1083`,
`quickstart.md:1201-1206`, the adoption query behind AD-09 and AD-16 — depends on this and none of
the artefacts says where the label goes.

Claims, entries and indices are genuine namespaced API objects served by the aggregated apiserver
(`/root/agentic-netops-srl/kuid/main.go:86-93`; default storage `badgerdb`,
`pkg/config/config.go:37-42,75`), so `get/list/watch` by label selector is ordinary Kubernetes
behaviour.

### 1d. Status reporting the allocated value — YES: `status.id` (and `status.range`)

```go
type VLANClaimStatus struct {
	condv1alpha1.ConditionedStatus `json:",inline" ...`
	ID        *uint32 `json:"id,omitempty" ...`
	Range     *string `json:"range,omitempty" ...`
	ExpiryTime *string `json:"expiryTime,omitempty" ...`
}
```
`/root/agentic-netops-srl/kuid/apis/backend/vlan/v1alpha1/vlanclaim_types.go:42-57`.

`Ready` is set on success (`pkg/backend/generic/applicator_static_id.go:109`;
`pkg/reconcilers/vlanclaim/reconciler.go:149`), `Failed(msg)` on error (`reconciler.go:170`). So
"bound and reporting its allocated value in status" — the phrase `contracts/reconciliation.md:47`
and `contracts/kuid-claim-profiles.md:120` use — maps exactly onto `Ready=True` plus `status.id`.

**Note a hazard nobody has carried**: `status.expiryTime` exists. A claim that expires would free a
value FR-103 (`spec.md:877-888`) says must stay held. I found **no writer** for that field anywhere
in `apis/` or `pkg/` at v0.0.13, but I did not prove there is none. See U4 below.

### 1e. Refusing a second claim for the same value — YES, at CREATE, and the refusal names the holder

`staticApplicator.Apply` → `getParentContext` finds the existing tree entry and calls
`claim.ValidateOwner(labels)` (`pkg/backend/generic/applicator_static_id.go:134-153`):

```go
func (r *VLANClaim) ValidateOwner(labels labels.Set) error {
	routeClaimName := labels[backend.KuidClaimNameKey]
	routeClaimUID  := labels[backend.KuidClaimUIDKey]
	if string(r.UID) != routeClaimUID && r.Name != routeClaimName {
		return fmt.Errorf("route owned by different claim got name %s/%s uid %s/%s", ...)
	}
	return nil
}
```
`/root/agentic-netops-srl/kuid/apis/backend/vlan/vlanclaim_object.go:210-223`.

That error is returned from the **CREATE path** — `strategy.InvokeCreate`
(`pkg/registry/generic/strategy_resource.go:102-107`) → `claimInvoker.InvokeCreate` →
`be.Claim` (`pkg/backend/invoker.go:36-41`) — so the second claim fails as an API error rather than
being accepted with `Ready=False`. This is good news for FR-109: the holder's claim name is *in the
error string*, which is exactly what `Accepted=False/AllocationConflict` "naming the value and the
holder" (`spec.md:934-936`) needs, and the provider does not have to go looking for it.

Two caveats worth recording:

- The ownership guard is `&&`, not `||`: a claim is only rejected when **both** the UID and the name
  differ. Within one namespace + one index a name collision cannot happen, and cross-namespace
  claims land in different cache instances, so the *effective* guarantee holds — but it holds for a
  reason the code does not state. If the platform ever puts two indices of the same name in one
  namespace, or reuses claim names, this matters.
- `InvokeUpdate` also calls `be.Claim` (`pkg/backend/invoker.go:43-48`). The design's deliberate
  withholding of `update`/`patch` from both the tier and the provider
  (`contracts/kuid-claim-profiles.md:126,131-136`) is therefore load-bearing in a way the rationale
  did not know: an `update` that changed `spec.id` would *move* the allocation, silently releasing
  the old entry (`applicator.go:111-130` `deleteNonClaimedEntries`). **The no-update rule is better
  justified than the specification claims. Keep it.**

### 1f. Are claims namespaced? — YES, all of them

```go
func (VLANClaim) NamespaceScoped() bool { return true }
```
`/root/agentic-netops-srl/kuid/apis/backend/vlan/v1alpha1/vlanclaim_resource.go:46-50`; identically
for `GENIDClaim` (`apis/backend/genid/v1alpha1/genidclaim_resource.go:48-50`), `VLANIndex`
(`vlanindex_resource.go:48-50`) and `VLANEntry` (`vlanentry_resource.go:48-50`). Corroborated by the
shipped CRDs, `scope: Namespaced` (`/root/agentic-netops-srl/kuid/crds/vlan.be.kuid.dev_vlanclaims.yaml:17`).
Plural `vlanclaims` (`apis/backend/vlan/vlanclaim_resource.go:39`); index plural is **`vlanindices`**
(`apis/backend/vlan/vlanindex_resource.go:39`) — worth noting because nothing in the feature
directory names it.

A claim and its index must be in the **same namespace** (the cache key,
`vlanclaim_object.go:52-54`). `kuid-system` for everything, as designed. No change needed.

### 1g. VLAN index scope, and could there be per-port or per-node indices?

```go
type VLANIndexSpec struct {
	MinID *uint32 `json:"minID,omitempty" ...`
	MaxID *uint32 `json:"maxID,omitempty" ...`
	commonv1alpha1.UserDefinedLabels `json:",inline" ...`
	Claims []VLANIndexClaim `json:"claims,omitempty" ...`
}
```
`/root/agentic-netops-srl/kuid/apis/backend/vlan/v1alpha1/vlanindex_types.go:27-40`.

- `minID`/`maxID` exist and are what `contracts/kuid-claim-profiles.md:20`'s 100–4000 band rests on.
  Hard bounds `VLANID_Min = 0`, `VLANID_Max = 4095` (`apis/backend/vlan/helper.go:23-24`); the tree
  is always the full 12 bits (`vlanindex_object.go:48-55`).
- **`minID`/`maxID` do not shrink the tree — they materialise *reserved range claims***
  `<index>.rangereservedmin` (`0-<min-1>`) and `<index>.rangereservedmax` (`<max+1>-4095`)
  (`apis/backend/vlan/vlanindex_object.go:79-97`; names from `apis/backend/claim_types.go:44-45`),
  and a claim cannot draw from a reserved range:
  `return fmt.Errorf("cannot claim from a reserved range")`
  (`pkg/backend/generic/applicator_dynamic_id.go:111-113`). **This is the mechanism behind
  Alternative 4 in §3 below, and the platform is already using it.**
- `spec.claims[]` (new at v0.0.13) lets an index carry embedded named sub-claims with `id` or
  `range` and labels, materialised as real claims named `<index>.<claim.Name>` owned by the index
  (`vlanindex_types.go:42-54`; `vlanindex_object.go:159-187`). This is a second, finer reservation
  mechanism, written by whoever writes the index — the provisioning script, never the tier.
- **Multiple VLAN indices: yes, nothing prevents it.** `CreateIndex` keys a separate cache instance
  per `{namespace, name}` (`pkg/backend/generic/backend.go:72-109`), each with its own tree; there
  is no singleton check and no validation coupling indices. One index per node, per port, per
  fabric is fully supported.

> **But it does not dissolve AD-27's collision — see §3, Alternative 2.** Per-port indices make
> *allocated* VLANs unique per port; the collision AD-27 addresses is between an allocated VLAN and
> a **named** one, and named VLANs are claimed by nobody (AD-09, an operator decision,
> `contracts/kuid-claim-profiles.md:77-80`). A per-port index is exactly as ignorant of a named VLAN
> as a global one. The premise in the review brief is, on the evidence, false.

### 1h. Owner-reference / "claim owner" semantics relevant to adoption

- **KUID sets no ownerReferences on user-created claims.** Owner refs appear only on `*Entry`
  objects (pointing back at the claim, built *from the labels* —
  `apis/backend/vlan/vlanentry_object.go:112-128`, whose own comment calls it "a bit of a hack") and
  on index-embedded claims (pointing at the index, `vlanindex_object.go:120-127,142-149,175-182`).
- Ownership of an allocated value is asserted purely by two labels stamped on the tree entry:
  ```go
  KuidOwnerKindKey = "be.kuid.dev/owner-kind"
  KuidClaimNameKey = "be.kuid.dev/claim-name"
  KuidClaimUIDKey  = "be.kuid.dev/claim-uid"
  KuidClaimTypeKey = "be.kuid.dev/claim-type"
  KuidIndexEntryKey = "be.kuid.dev/index-entry"
  ```
  `/root/agentic-netops-srl/kuid/apis/backend/LabelKeys.go:21-31`. The owner-**namespace** and
  owner-**name** keys are present but **commented out** at v0.0.13.
- A claim is idempotently re-appliable: `validateExists` → `reclaimIDFromExisitingEntries` reclaims
  an entry already labelled with the claim's own name+UID and calls `tree.Update` rather than
  `ClaimID` (`applicator_static_id.go:43-68,119-132`). So the provider re-reconciling an adopted
  claim is safe — it need do nothing at all, since it holds no `create`/`update` there.
- **Consequence for AD-16**: there is no KUID-native "owner" the provider could set or read to make
  adoption stronger than label+value. Labels are the only handle. AD-16 chose the only available
  mechanism.

### 1i. Does deleting a claim free the value immediately? — YES, synchronously

`strategy.InvokeDelete` (`pkg/registry/generic/strategy_resource.go:187-192`) →
`claimInvoker.InvokeDelete` → `be.Release` (`pkg/backend/invoker.go:50-55`) →
`backend.Release` takes the write lock, calls `applicator.Delete`, then `saveAll`
(`pkg/backend/generic/backend.go:177-208`) → `applicator.delete` calls
`tree.ReleaseID(...)` / `table.Release(...)` on the owner's entries
(`pkg/backend/generic/applicator.go:58-79`). In the controller (etcd) mode the release runs *before*
the finalizer is removed (`pkg/reconcilers/vlanclaim/reconciler.go:96-118`).

**This is the fact AD-16 and FR-103 stand on**: when the provider's finalizer deletes an adopted
claim after the device read-back, the identifier is free at that instant and not before. It also
means there is no grace period to lean on — a claim deleted early is *gone* early, which is why the
rollback race in §2 matters.

### 1j. Cross-namespace ownerReferences — disallowed, VERIFIED

From `https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/`:

> "Cross-namespace owner references are disallowed by design. Namespaced dependents can specify
> cluster-scoped or namespaced owners. A namespaced owner **must** exist in the same namespace as
> the dependent. If it does not, the owner reference is treated as absent, and the dependent is
> subject to deletion once all owners are verified absent."

> "In v1.20+, if the garbage collector detects an invalid cross-namespace `ownerReference` … a
> warning Event with a reason of `OwnerRefInvalidNamespace` … is reported."

Claims live in `kuid-system`; `Network`s live in `agentic-netops-intent` or
`agentic-netops-services` (`contracts/kubernetes-objects.md:73`). An ownerReference from claim to
`Network` is therefore **impossible**, and worse than impossible: it would be treated as an absent
owner and could make the claim **eligible for garbage collection**. See §2 finding 6.

---

## Question 2 — AD-16 soundness

The principle is right and I recommend keeping it. Six residual issues, ordered by severity.

### Finding 1 (HIGH) — the `ip-vrf` attachment VLAN escapes both AD-16 and AD-25

`contracts/kuid-claim-profiles.md:62` gives `ip-vrf` "claim per tagged attachment **unless the
operator named a VLAN**", and `contracts/network-spec.md:90` confirms an `ip-vrf`'s attachments
carry "`vrf`, and `vlan` when the attachment is tagged". So for an `ip-vrf`, **the allocated VLAN
lives only in `spec.attachments[].vlan`**.

AD-25 (`research.md:2395-2402`; `data-model.md:611-617`) freezes `vlans[].vlan`,
`bridgeDomains[].vlan`, `bridgeDomains[].l2vni` and `routers[].l3vni` by CEL and explicitly leaves
**`attachments[]` mutable**. Two consequences the artefacts do not cover:

- **Leak.** AD-16's adoption predicate is "reporting a VLAN the object carries"
  (`contracts/kuid-claim-profiles.md:181`; `spec.md:944-946`). Remove the tagged attachment and the
  object stops carrying that VLAN. If the provider recomputes adoption every reconcile — which a
  controller written from Rule 3 (`contracts/reconciliation.md:47-56`) naturally would — the claim
  falls out of the adoption set and out of `status.claimRefs`, and nobody releases it. FR-109
  *intends* otherwise ("a claim whose value the object no longer carries stays held, and listed,
  until finalization", `spec.md:940-942`), but that is stated as an outcome, not as a rule the
  adoption predicate must obey. T170 (`tasks.md:216`) does not test it.
- **Unclaimed value inside the band.** Adding a new tagged attachment to an accepted `ip-vrf` is a
  legal edit. Its VLAN is inside the 100–4000 allocation index, nothing claimed it, the provider
  never creates VLAN claims, and the tier is not in the loop for a `kubectl edit`. The authority can
  then hand that same VLAN to another service. This is precisely the hazard AD-09 was written to
  close for VNIs, reopened on the VLAN side by AD-25's choice to leave attachments mutable.

### Finding 2 (HIGH) — provider down between apply and first reconcile: claims with no release owner

The finalizer is the provider's and is placed on first reconcile (`tasks.md:224` T060,
`controllers/network/finalizer.go`). Nothing places it at admission — the
`deny-tier-force-release` `ValidatingAdmissionPolicy` is the only admission object in the inventory
(`contracts/kubernetes-objects.md:60`). So between the deployer's apply and the provider's first
reconcile there is a window in which the `Network` carries **no finalizer**:

- a `kubectl delete` in that window succeeds immediately; the tier's VLAN and VNI claims are
  orphaned. The tier will not release them — the service *was* submitted (`spec.md:948-951`). The
  provider never adopted them, so its finalizer never runs.
- the same window is entered whenever the provider is being upgraded, is crash-looping, or has not
  yet leader-elected (`tasks.md:174` T042).

AD-16's central claim — "**one release owner, the provider**, whichever way the service is later
removed" (`spec.md:948-949`) — is false for the duration of that window.

### Finding 3 (HIGH) — the rollback race, and the guard that needs a read the allocator does not have

FR-066 rollback deletes everything matching the correlation label
(`contracts/kubernetes-objects.md:204-207`) and the tier releases "every provisional claim"
(`spec.md:949-951`). In a multi-object bundle — which the design contemplates, "a rejection injected
on the second object deletes the first" (`tasks.md:334` T092) — object A can already be accepted and
its claims adopted when object B fails. Rollback then races the provider: if the tier deletes the
claims, the release is **immediate and synchronous** (§1i) and the VLAN is free while a device may
still carry it. That is the exact hazard FR-103 exists to prevent.

The design knows this and puts a guard on it — but the guard as tasked is illegal:

> `tasks.md:335` (T093): "…**and no release of any claim once the service has been submitted**: the
> release path refuses a correlation id whose `Network` exists"

Reading whether a `Network` exists is a read the **allocator** does not have. FR-075
(`spec.md:1208-1220`) and `contracts/kubernetes-objects.md:101-108` grant it claims in `kuid-system`
and nothing else, and AD-27's own rationale (`research.md:2443-2445`) rejects its alternative
*because* "the allocator agent cannot read `Network`s". AD-16's safety guard therefore depends on
the same widening AD-27 refused. One of the two has to move. See the proposed wording.

### Finding 4 (MEDIUM) — label spoofing (R-45): "label AND value" is *necessary but not sufficient*

R-45 (`plan.md:1109`) mitigates with label-and-value, no create/update/patch on `vlanclaims`, and an
enumerable `status.claimRefs`. That is sound as far as it goes, and §1h confirms there is no
stronger KUID-native handle. Two gaps remain:

- **Who can spoof.** The allocator identity may create `vlanclaims` in `kuid-system` with any
  `metadata.labels` it likes (`contracts/kubernetes-objects.md:81,103-104`). A compromised or
  buggy allocator can therefore mint a claim carrying another service's correlation label and a
  VLAN that service carries, and the provider will adopt it and, at finalization, delete it. The
  damage is bounded (a stray claim released early, and a value handed back to the index) but it is
  not zero — that value can then be re-allocated while the device still carries it.
- **A cheap hardening the design already uses for VNIs.** Provider-created VNI claims are named
  deterministically `<namespace>.<name>.<role>` (`contracts/kuid-claim-profiles.md:182`). Nothing
  constrains the *name* of an adoptable VLAN claim. Requiring the same deterministic name for an
  adoptable VLAN claim makes the name itself carry the `Network` identity, so a spoof needs the
  right name as well as the right label and value. Cost: the allocator must know the final
  `Network` name at claim time — it is derived from the service id, which the allocator stage
  already has (`contracts/kuid-claim-profiles.md:59-62` names instances `vlan-<serviceId>` etc.), so
  this looks free; confirm before adopting.

### Finding 5 (LOW–MEDIUM) — purge of the tier (AD-26) while `Network`s finalize

The ordering in T088 (`tasks.md:306`) is correct and AD-16-consistent: list, export audit, delete
`Network`s, bounded wait, **then** remove workloads, Secrets and "the **provisional** claims of
requests never submitted". A purge that stops non-zero on a blocked finalizer never reaches the
claim step, so nothing is force-released. Good.

The residual issue is an over-strong assertion elsewhere: `tasks.md:310` (T089) requires "purge
leaves no workload and **no claim**", and `quickstart.md:1082-1083` asserts the
`agentic-netops.io/tier=intent` selector is empty after the purge. Both are true only on the happy
path; AD-26 explicitly permits the unhappy one. The test needs the same conditional the decision
has.

A second, smaller point: the purge distinguishes "provisional" from "adopted" by *the `Network`
being gone*. That is the same read as Finding 3 — but here it is the provisioning **script**
running with the operator's own cluster authority, not a tier identity, so no boundary is crossed.
Saying so explicitly in AD-16 would make the asymmetry deliberate rather than accidental.

### Finding 6 — would an ownerReference from claim to `Network` be better, or is it impossible?

**Impossible, and it would be actively harmful if attempted.** Cross-namespace owner references are
disallowed by design; an invalid one is "treated as absent, and the dependent is subject to deletion
once all owners are verified absent"
(`https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/`, quoted in
full at §1j). A claim in `kuid-system` pointing at a `Network` in `agentic-netops-intent` would
therefore be a candidate for garbage collection at an unpredictable moment — releasing a VLAN while
a device carries it, with no read-back, which is exactly what FR-103 forbids. AD-16's label-and-value
adoption is not a second-best; it is the only correct mechanism available. **This should be recorded
in AD-16 as a closed alternative with its citation, so a later pass does not propose it again.**

(For completeness: moving the claims into the same namespace as the `Network`s to enable owner refs
is not open either — a KUID claim must sit in the same namespace as its index
(`apis/backend/vlan/vlanclaim_object.go:52-54`), so it would mean an index per intent namespace, and
would hand the tier's namespace an allocation index. Not recommended.)

### Findings that came back clean

- **Service submitted but provider down, then removed *through the tier*** — the deployer deletes
  the `Network`, which stays until the provider returns and finalizes; claims stay held. Correct.
- **`kubectl delete` of a `Network` the provider has adopted** — finalizer blocks, read-back, claims
  released. This is SC-046's second half (`spec.md:1565-1570`) and T173 (`tasks.md:352`) tests it,
  negative control first. Correct.
- **Provider RBAC** — `get, list, watch, delete` on `vlanclaims`, no `create`/`update`/`patch`
  (`contracts/kuid-claim-profiles.md:131-136`; `tasks.md:174`). Given §1e's discovery that
  `InvokeUpdate` re-runs the claim (and can silently move an allocation), withholding `update` is
  *more* important than the rationale realised. Keep it, and say why.
- **KUID compatibility of the whole adoption scheme** — claims are namespaced, labelled, listable by
  metadata label selector, report `status.id`, refuse a duplicate static claim at CREATE naming the
  holder, and release synchronously on delete. Every mechanical assumption AD-16 makes is available
  at v0.0.13.

---

## Question 3 — AD-27 evaluation

### 3a. Reachability in the frozen walkthrough: **zero**

All three frozen prompts **name** their VLAN:

| # | Construct | Frozen prompt | VLAN |
|---|---|---|---|
| A | `vlan` | "Provision a vlan **170** on leaf01 ethernet-1/1 for tenant acme" | named |
| B | `ip-vrf` | "…leaf01 ethernet-1/1 **vlan 253** and leaf02 ethernet-1/1 **vlan 253**…" | named |
| C | `mac-vrf` | "Extend **vlan152** as a mac-vrf across leaf01 ethernet-1/1 and leaf02 ethernet-1/1…" | named |

`contracts/readme-and-walkthrough.md:68-70`; identifiers declared single-use at
`contracts/readme-and-walkthrough.md:77-78` and `tasks.md:532` (T158).

**No VLAN is allocated anywhere in P12.** AD-27's collision cannot occur in the recorded walkthrough,
and the take is not at risk from this decision either way. (It also means SC-046 — "a service
provisioned through the intent tier with **no VLAN named**", `spec.md:1565` — is exercised only by
T173 (`tasks.md:352`) and `quickstart.md` §26a, never by the demo. That is a separate observation,
not a defect.)

### 3b. Likelihood and severity in the 6-node lab

The collision needs all of: a service requested with **no VLAN named**, on a `(node, port)` that
**already carries a named VLAN** from another service, and the authority handing out **exactly** that
value. In this lab the access ports that carry services are `leaf01 ethernet-1/1` and
`leaf02 ethernet-1/1` (`contracts/readme-and-walkthrough.md:69-70`), so the exposure is two
`(node, port)` pairs and a handful of named VLANs against a 3901-value index
(`contracts/kuid-claim-profiles.md:20`).

**Frequency depends on one unverified fact.** If `tree.ClaimFree`
(`pkg/backend/generic/applicator_dynamic_id.go:135`) returns an arbitrary free id, the collision is
roughly 3-in-3901 per allocation — genuinely rare, and AD-27's "a corner a single-operator lab meets
rarely" (`research.md:2444-2445`) is fair. If it returns the **lowest** free id — the common
implementation — allocated VLANs march 100, 101, 102 … and the 53rd allocation in the lab's lifetime
lands on **152**, the walkthrough's named `mac-vrf` VLAN, deterministically. `tree.ClaimFree` lives
in `github.com/henderiw/idxtable`, which is neither vendored nor in the module cache, so **I could
not verify which it is** (U1). *The rationale's severity assessment is resting on an assumption that
one extra line in the G11 script would settle.*

Severity when it does occur is low: nothing is created, provisional claims are released, the
operator is told, and naming a VLAN gets them through. No device is touched and no identifier leaks.

### 3c. Is refusal-by-name acceptable under Principle II?

**Yes on the letter; partly on the spirit.** Constitution Principle II
(`/root/agentic-netops-srl/.specify/memory/constitution.md:105-119`) requires two confirmations, no
one-shot provisioning, rejection **up front** of "inputs referencing non-existent nodes or ports"
with "concrete valid alternatives" enumerated, and closes "must fail loudly on bad input rather than
guessing". CR-003 (`spec.md:1432-1433`) carries exactly that scope. An allocated-VLAN collision is
**not** an input naming a non-existent node or port — the operator's input is entirely valid — so
CR-003 does not literally bind, and refusing rather than silently retrying is squarely in the spirit
of "fail loudly rather than guessing". AD-27 is admissible.

Two places where it falls short of the standard the constitution sets elsewhere:

1. **It enumerates no concrete alternative.** The refusal says "naming a free VLAN avoids it"
   (`spec.md:1143-1145`; `contracts/kuid-claim-profiles.md:119`) — advice, not an alternative. The
   pre-flight that raises the refusal has just scanned the port and therefore *knows* which VLANs
   are free on it. Naming two or three costs nothing and matches how every other refusal in this
   specification behaves (FR-034, FR-059, FR-061, FR-097 per CR-003).
2. **It arrives after both confirmations.** The pre-flight is step 1 of the *submission* contract
   (`contracts/kubernetes-objects.md:199-201`), and the pipeline is mapper → confirmation 1 →
   allocator → confirmation 2 → deployer (`tasks.md:346` T101). So the operator confirms twice and
   *then* learns the request cannot proceed. Principle II's "rejected up front" is about bad input
   and does not forbid this, but it is the weakest part of the design, and Alternative 1 below fixes
   it for free.

### 3d. A scope hole in the refusal as written

`contracts/kuid-claim-profiles.md:119`, `spec.md:1142-1145` and `plan.md:845-847` all present the
deployer's pre-flight as *the* thing that refuses the collision. But the pre-flight scans **the
intent namespace only** (`contracts/kubernetes-objects.md:199-201`; `tasks.md:384` T112 —
"scan `agentic-netops-intent`"), and the deployer's identity is namespaced to it
(`spec.md:1213-1215`). A named VLAN held by a hand-applied `Network` in the control-plane-owned
`agentic-netops-services` (AD-26, `contracts/kubernetes-objects.md:73`) is **invisible** to the
pre-flight.

That case is not lost — the cross-object **webhook** rule "One owner per (node, port, vlan)"
(`contracts/crd-api.md:155`) sees both namespaces alike (`contracts/kubernetes-objects.md:73`) and
refuses at the server-side dry-run, which "aborts the whole bundle"
(`contracts/kubernetes-objects.md:204-206`), after which rollback releases the provisional claims.
So the outcome is right and the safety property holds. But the artefacts describe a belt as though
it were the only garment. **The webhook is the arbiter; the pre-flight is an early, better-worded
copy of it.** Saying that plainly costs one sentence and prevents an implementer from believing the
pre-flight is complete.

### 3e. Alternatives — honest cost/benefit

#### Alternative 1 — ask the deployer for the occupied VLANs *before* the allocator claims (RECOMMENDED as an addition)

The deployer already holds `get, list, watch` on `networks` in the intent namespace
(`contracts/kubernetes-objects.md:96-98`) and already computes the occupied `(node, port, vlan)` set
in its pre-flight (`tasks.md:384`). Expose that set as a read-only deployer tool the supervisor calls
**at the allocator stage**, before confirmation 1, and have the allocator exclude those VLANs from
its claim (via `spec.selector`-free dynamic claim plus a retry, or by claiming a stated free value).

- **Does it widen FR-075?** **No.** No new resource, no new verb, no new identity. The allocator
  never reads a `Network`; the deployer reads only what it already reads.
- **Benefit**: the assignment the operator confirms is already collision-free, so the post-
  confirmation refusal of §3c(2) mostly disappears, and the refusal that remains is the genuinely
  unavoidable one (a cross-namespace holder, §3d).
- **Cost**: one new deployer endpoint, one supervisor-graph edge, one more contract in
  `contracts/supervisor-http.md`. Touches P7 (`plan.md:825-847`), C-14 (`plan.md:466`), T092, T100,
  T101, T112.
- **What it does *not* do**: it is still blind to `agentic-netops-services`, so AD-27's refusal must
  remain as the floor.
- **Important**: do this **before** the confirmations, never after. The variant in the review brief —
  "reporting the occupied VLANs back so the allocator re-claims while holding the colliding claim" at
  pre-flight time — changes the identifier **after** the operator confirmed it, which breaks CR-002
  (`spec.md:1428-1431`) and FR-063's byte-identical assignment (`spec.md:1147-1149`). **Reject the
  post-confirmation form; adopt the pre-confirmation form.**

#### Alternative 2 — per-(node, port) or per-node VLAN indices (NOT RECOMMENDED)

- **Feasible?** Yes, unreservedly (§1g). KUID supports any number of `VLANIndex` objects.
- **Does it dissolve the collision?** **No — and the brief's premise here is wrong.** Named VLANs are
  claimed by nobody (AD-09, operator decision, `contracts/kuid-claim-profiles.md:77-80`), so an
  index scoped to a port is exactly as blind to a named VLAN on that port as a global one. Two
  *allocated* VLANs already never collide — a single index never hands the same value out twice —
  so per-port indices solve a problem that does not exist.
- **It makes the target problem slightly worse.** A global index never re-uses a value fabric-wide;
  per-port indices re-use the low end of the range on *every* port, so each port accumulates
  allocated VLANs in the same region where named VLANs live. The named-collision rate goes up, not
  down.
- **Cost**: an index object per `(node, port)` (4 device targets × N access ports), an index-name
  resolution step in the allocator's adapter and in the provisioning script, an
  `AllocationConflict` message that must now name which index, and a larger `kuid-system` footprint
  against NFR-004/NFR-012.
- **Verdict**: cost high, benefit negative. It would only become interesting if the 3901-value index
  approached exhaustion, which a 6-node lab will not.

#### Alternative 3 — an exclusion list in the `site-inventory` ConfigMap (NOT RECOMMENDED)

- `site-inventory` is written **once** by the provisioning script from the `Fabric` inventory and
  mounted read-only into mapper, allocator and deployer
  (`contracts/kubernetes-objects.md:35`), and **no RBAC rule grants the tier any verb on ConfigMaps
  anywhere** (`contracts/kubernetes-objects.md:104-108`).
- So the list could never be updated as services are created and removed. It would be stale from the
  first provisioning run onward, and would give the allocator *false confidence* — worse than the
  honest ignorance it has now. Widening it to a live list means giving a tier identity ConfigMap
  write, which is a larger widening than the `Network` read AD-27 refused.
- **Verdict**: reject.

#### Alternative 4 — split the band: named VLANs and allocated VLANs never overlap (RECOMMENDED to the operator as the structural fix)

Narrow the allocation index to, say, `minID: 1000, maxID: 4000`, and refuse a **named** VLAN inside
that band at validation, naming the band an operator may name from (100–999).

- **Feasible at v0.0.13?** Yes, and the platform is already using the mechanism: `spec.minID`/
  `spec.maxID` (`apis/backend/vlan/v1alpha1/vlanindex_types.go:29-34`) materialise reserved range
  claims (`apis/backend/vlan/vlanindex_object.go:79-97`) and a claim cannot draw from a reserved
  range — `"cannot claim from a reserved range"`
  (`pkg/backend/generic/applicator_dynamic_id.go:111-113`). Today's 100–4000 band *is* this
  mechanism. Changing `minID` is a manifest edit.
- **Benefit**: the collision becomes **structurally impossible** rather than detected. No pre-flight,
  no refusal, no rollback, no retry, no race. AD-27 reduces to a validation rule that is already
  half-written (`contracts/kuid-claim-profiles.md:77-80` already refuses a named VLAN outside the
  index range).
- **Does it widen FR-075?** No. No RBAC change, no `Network` read, no tier change at all.
- **Does it reopen "named VLANs are never claimed"?** **No.** Nothing is claimed. The two spaces are
  simply disjoint. The operator decision stands untouched.
- **Does the frozen walkthrough survive?** **Yes** — 152, 170 and 253 are all below 1000
  (`contracts/readme-and-walkthrough.md:68-70`). P12 needs no change.
- **Costs, stated honestly**:
  - The operator loses the freedom to name a VLAN ≥ 1000. In a lab with 900 nameable VLANs and two
    active access ports this is not a real constraint, but it *is* a reduction in expressiveness and
    it is the operator's call, not mine.
  - It contradicts one existing sentence: "there is **no derived or reserved VLAN band** on this
    platform to carve out of it (R-28)" (`contracts/kuid-claim-profiles.md:80`). R-28 as rewritten
    (`plan.md:1092`; `platform-coupling.md:62`) removed a *derived* band because SR Linux derives
    none — a reserved *naming* band is a different animal, chosen rather than derived, so the
    evidence behind R-28 is not contradicted. But the sentence is, and it would have to be rewritten
    rather than quietly reinterpreted.
  - It adds a second range to explain, exactly the "two ranges, two names" bookkeeping AD-10
    (`research.md:2169-2177`) had to introduce for VNIs. That cost is real and was paid once already.
- **Verdict**: this is the only option on the table that removes the edge case instead of reporting
  it, and it is the cheapest to build. It is a genuine design choice with a genuine price, which is
  why it belongs in front of the operator rather than in a recommendation. **Put it to them.**

### 3f. AD-27 verdict

**RATIFY WITH AMENDMENTS.** Keep the refusal — it is the only available outcome for a holder in
`agentic-netops-services`, and "no other value tried silently" is correct under FR-062 and
Principle II. Amend it to name free alternatives, to state that the webhook is the arbiter and the
pre-flight the early copy, and to record Alternatives 2 and 3 as evaluated-and-rejected with the
reasons above (so they are not re-proposed). Put Alternative 4 to the operator as a separate,
explicit choice, and adopt Alternative 1 if the post-confirmation refusal is judged to cost too
much operator time.

---

## Question 4 — residual inconsistencies in the feature directory

| # | Where | What contradicts what |
|---|---|---|
| **I1** | `tasks.md:335` (T093) vs `spec.md:1208-1220` (FR-075), `contracts/kubernetes-objects.md:101-108`, `research.md:2443-2445` (AD-27) | T093 requires the allocator's "release path [to refuse] a correlation id whose `Network` exists". The allocator has no verb on `networks` anywhere, and AD-27 rejects its own alternative *because* "the allocator agent cannot read `Network`s, and giving it that read widens FR-075". **AD-16's safety guard, as tasked, needs the widening AD-27 refused.** Highest-priority contradiction of the four |
| **I2** | `contracts/kuid-claim-profiles.md:119`, `spec.md:1142-1145`, `plan.md:845-847` vs `contracts/kubernetes-objects.md:199-201`, `tasks.md:384` (T112) | The first three say the deployer's pre-flight refuses the allocated-VLAN collision, unqualified. The last two scope that scan to `agentic-netops-intent`. A named VLAN held in `agentic-netops-services` is invisible to it and is caught only by the webhook (`contracts/crd-api.md:155`, `contracts/kubernetes-objects.md:73`) |
| **I3** | `contracts/kuid-claim-profiles.md:62` + `contracts/network-spec.md:90` vs `research.md:2395-2402` (AD-25) + `data-model.md:611-617` | An `ip-vrf`'s allocated VLAN lives only in `spec.attachments[].vlan`, which AD-25's CEL leaves mutable. So an adopted VLAN claim can lose the adoption predicate of `contracts/kuid-claim-profiles.md:181`, and a newly added tagged attachment carries an unclaimed VLAN inside the allocation band. See §2 Finding 1 |
| **I4** | `quickstart.md:1201` vs `quickstart.md:1204-1206` + `contracts/kuid-claim-profiles.md:182` vs `quickstart.md:1082-1083` | Three different selectors are used for "the claims of this service": `agentic-netops.io/correlation-id`, `agentic-netops.io/network-namespace` + `…/network-name`, and `agentic-netops.io/tier=intent`. SC-045 (`spec.md:1558-1564`) and SC-046 (`spec.md:1565-1570`) are both "claim-selector diffs" over different selectors, and **no artefact states which labels a claim must carry, nor that they must be `metadata.labels`** — which §1c shows is the only kind the aggregated apiserver will filter on |
| **I5** | `tasks.md:310` (T089) and `quickstart.md:1082-1083` vs `research.md:2410-2430` (AD-26) + `tasks.md:306` (T088) | "purge leaves no workload and no claim" is unconditional; AD-26 explicitly allows the purge to stop non-zero with `Network`s still finalizing and their adopted claims still held |
| **I6** *(checked, not a defect)* | `contracts/kuid-claim-profiles.md:131-136`, `tasks.md:174`, `contracts/kubernetes-objects.md:81` | Provider and allocator verb sets are internally consistent with AD-16 everywhere I looked: provider gets `create` on `genidclaims` and **no `create`** on `vlanclaims`; the allocator gets `create`/`delete` on both and no `update`/`patch`. No artefact anywhere says the provider creates a VLAN claim. `data-model.md:105`, `data-model.md:580`, `data-model.md:1056-1058`, `contracts/reconciliation.md:56,180-182,284`, `plan.md:838-847`, `tasks.md:216,223,306,345` all agree with AD-16 on who releases what |
| **I7** *(out of scope, noted)* | `evidence/05-kubenet-sdc-kuid.md:600-604` vs `contracts/kuid-claim-profiles.md:19` | The evidence recommends `vxlan.be.kuid.dev/VXLANIndex` for VNIs with GENID as the fallback; the contract took GENID. That may well be right (the evidence itself records the `vxlan` backend as **gone at HEAD**, `evidence/05-kubenet-sdc-kuid.md:594`), but the contract does not say the fork was decided or why. Not an AD-16/AD-27 matter |

---

## Proposed wording changes — PROPOSALS ONLY, NOT APPLIED

No file was edited. Each item below names the file and line it would touch.

### For AD-16

**P1 — adoption is sticky.** `contracts/kuid-claim-profiles.md:181` (the "Adopt (VLAN)" row) and
`contracts/reconciliation.md:53-56`: add — *"Adoption is evaluated once. A claim recorded in
`status.claimRefs` as `adopted` stays adopted for the life of the object, whether or not the object
still carries that value on a later reconcile (FR-109, AD-25). The predicate is re-evaluated only
for a value not already in `status.claimRefs`."* Add the corresponding assertion to `tasks.md:216`
(T170): an `ip-vrf` whose tagged attachment is removed keeps its VLAN claim in `status.claimRefs`
and releases it at finalization.

**P2 — name the fields the predicate reads, and close the `ip-vrf` attachment gap.**
`contracts/kuid-claim-profiles.md:181`: replace "reporting a VLAN the object carries" with
*"reporting a VLAN in `spec.vlans[].vlan`, `spec.bridgeDomains[].vlan` or `spec.attachments[].vlan`"*.
Then extend AD-25 (`research.md:2395-2402`; `data-model.md:611-617`; `contracts/crd-api.md` rule
table) with one of: *(a)* `spec.attachments[].vlan` is immutable on an accepted object when it is
backed by a claim, or *(b)* an attachment **added** to an accepted object carrying a VLAN inside the
allocation index's range is refused naming the range and the reason (nothing would claim it). (b) is
the lighter change and keeps attachments otherwise mutable, which AD-25 wanted.

**P3 — close the no-finalizer window.** `spec.md:927-954` (FR-109) and
`contracts/reconciliation.md:160-183` (Rule 8): state where the finalizer is placed and what holds
if it is not placed yet. Cheapest option: the deployer applies the `Network` **with the finalizer
already set** (it holds `create`/`update`/`patch` on `networks` in its namespace,
`contracts/kubernetes-objects.md:96-98`), so the object is never finalizer-less, and a hand-applied
`Network` gets it from the provider as today with the window acknowledged. Alternative: a mutating
admission policy. Either way the sentence *"one release owner, the provider, whichever way the
service is later removed"* (`spec.md:948-949`) needs the qualifier or the mechanism. Task carrier:
`tasks.md:224` (T060), `tasks.md:345` (T100).

**P4 — move Finding 3's guard off the allocator.** `tasks.md:335` (T093) and `tasks.md:344` (T099):
the "has this been submitted?" check belongs to the **deployer**, which already reads `networks` in
the intent namespace, not to the allocator. Reword T093 to: *"the tier's release path is driven by
the deployer, which refuses a correlation id whose `Network` exists in the intent namespace; the
allocator deletes only claims the deployer names."* Then `research.md:2443-2445` (AD-27's rationale)
stays true and FR-075 is untouched. Add a denial probe to `tasks.md` US6 asserting the allocator
identity **cannot** read `networks`, so the boundary is proven rather than assumed.

**P5 — say where the correlation label lives.** `contracts/kuid-claim-profiles.md:128-129`,
`spec.md:1558-1570` (SC-045, SC-046), `quickstart.md:1201-1206`: state that every claim the tier or
the provider creates carries its correlation and object labels in **`metadata.labels`**, because the
allocation authority's `List` filters on metadata labels only
(`pkg/registry/generic/strategy_resource.go:244-253`), and that KUID's own `spec.labels`/
`spec.selector` are **not** used by this platform. Settle on **one** selector for "the claims of this
service" across SC-045, SC-046, the purge check and the adoption query (I4).

**P6 — record the impossible alternative.** `research.md` AD-16 "Alternatives rejected"
(`research.md:2250-2254`): add — *"an ownerReference from the claim to the `Network` — impossible:
claims live in `kuid-system` and `Network`s do not, and Kubernetes treats a cross-namespace owner
reference as an absent owner, making the dependent eligible for garbage collection
(kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/) — which would release
an identifier with no read-back, the hazard FR-103 exists to prevent."*

**P7 — strengthen R-45 (optional).** `plan.md:1109`: add the deterministic-name requirement for an
adoptable VLAN claim (§2 Finding 4), if the allocator can know the `Network` name at claim time.

**P8 — fix the purge assertion.** `tasks.md:310` (T089) and `quickstart.md:1082-1083`: qualify
"purge leaves … no claim" with "on a purge that completed; a purge stopped on a blocked finalizer
leaves the adopted claims of the still-`Deleting` services held, by AD-26 and FR-103."

**P9 — say why `update` is withheld.** `contracts/kuid-claim-profiles.md:126,131-136`: add the
observed reason — at the pinned authority an update re-runs the claim and a changed `spec.id`
*moves* the allocation, silently releasing the previous entry
(`pkg/backend/invoker.go:43-48`; `pkg/backend/generic/applicator.go:111-130`). This turns a prudent
choice into an evidenced one.

### For AD-27

**P10 — enumerate alternatives in the refusal.** `spec.md:1142-1145` (FR-062),
`contracts/kuid-claim-profiles.md:119`, `tasks.md:384` (T112), `tasks.md:334` (T092): the refusal
must name **at least two free VLANs on that `(node, port)`**, which the pre-flight already knows, in
addition to the VLAN, the port and the holder. Brings it into line with CR-003's style
(`spec.md:1432-1433`).

**P11 — name the arbiter.** `contracts/kuid-claim-profiles.md:119` and `spec.md:1142-1145`: add —
*"The pre-flight scans the intent namespace only. A named VLAN held by a `Network` in
`agentic-netops-services` is refused by the cross-object one-owner rule at the server-side dry-run
(`contracts/crd-api.md:155`), which aborts the bundle and rolls back every provisional claim; the
pre-flight is the earlier and better-worded copy of the same rule, not the only one."* Add that case
to `tasks.md:334` (T092) as a second fixture.

**P12 — record the evaluated alternatives.** `research.md:2443-2446` (AD-27 "Alternative rejected"):
add per-`(node, port)` indices (rejected — named VLANs are unclaimed, so a scoped index is equally
blind; it re-uses low VLANs on every port and raises the collision rate; costs an index per port) and
the `site-inventory` exclusion list (rejected — the ConfigMap is written once by the provisioning
script and mounted read-only, and no tier identity holds any ConfigMap verb, so the list would be
stale by construction).

**P13 — offer the split band as an operator decision.** A new entry under `research.md` "Open items
carried to P0" (`research.md:2495+`): *"Whether the allocation VLAN index is narrowed (e.g.
`minID: 1000`) so that named and allocated VLANs occupy disjoint bands, making the AD-27 collision
structurally impossible at the cost of refusing a named VLAN ≥ 1000. Feasible at the pinned
authority (`VLANIndexSpec.MinID/MaxID`, reserved range claims, `'cannot claim from a reserved
range'`). Contradicts `contracts/kuid-claim-profiles.md:80` as written (R-28), which would be
rewritten. The frozen walkthrough's 152, 170 and 253 are unaffected."* Operator's call.

**P14 — record what the walkthrough does and does not exercise.** `plan.md:914-940` (P12) or
`contracts/readme-and-walkthrough.md:68-78`: note that all three frozen prompts name their VLAN, so
the recording exercises no allocated VLAN and cannot meet the AD-27 collision, and that SC-046 is
proven by T173 and `quickstart.md` §26a instead. Prevents a later pass from assuming the demo covers
the adoption path.

---

## UNVERIFIED items, mapped to a gate check

Nothing below is assumed in either decision's favour. G11 is the allocation claim round-trip gate
(`plan.md:640,654-659`; `quickstart.md:148`; `tasks.md:176` T044), evaluated as soon as the authority
is installed; a failure takes FR-104's path.

| # | Unverified | Why it could not be settled statically | Proposed check |
|---|---|---|---|
| **U1** | Whether a **dynamic** VLAN/GENID claim returns the *lowest* free id or an arbitrary one | `tree.ClaimFree` (`pkg/backend/generic/applicator_dynamic_id.go:135`) is in `github.com/henderiw/idxtable v0.0.0-20241126090137-4f6e57a5aec4`, which is not vendored in the clone and not in the module cache | **G11 addition**: record the ids returned by three consecutive dynamic claims against a fresh index. **This decides AD-27's severity**: lowest-first makes the collision deterministic after ~50 allocations in this lab; arbitrary makes it ~3-in-3901. AD-27's "met rarely" rationale is unsupported until this is observed |
| **U2** | Whether a dynamic claim can be handed a value inside a reserved `minID`/`maxID` range | The guard `"cannot claim from a reserved range"` (`applicator_dynamic_id.go:111-113`) is on the *parent-range* path; the root-tree path goes to `ClaimFree` in the same unvendored module. `isReserved` itself is visibly odd — its intended body is commented out (`pkg/backend/generic/applicator.go:132-141`) | **G11 addition, required only if P13/Alternative 4 is adopted**: create an index with `minID: 1000`, make five dynamic claims, assert every `status.id` ≥ 1000. Also worth running as-is, because today's 100–4000 band already relies on it |
| **U3** | That a second claim for a held static value is refused **at CREATE** and that the error **names the holder** | Read from source, not run: `strategy_resource.go:102-107` → `invoker.go:36-41` → `applicator_static_id.go:134-153` → `vlanclaim_object.go:210-223` | **G11 wording**: `plan.md:640` already requires "a second claim for it is refused". Extend to *"…refused, and the refusal identifies the holding claim"*, so FR-109's `AllocationConflict` message (`spec.md:934-936`) has an observed source rather than an inferred one. Carrier: `tasks.md:176` (T044) |
| **U4** | Whether `status.expiryTime` (`vlanclaim_types.go:53-56`) is ever populated | The field exists; I found no writer in `apis/` or `pkg/` at v0.0.13, but did not prove exhaustively that none exists | **G11 addition**: hold a claim across at least one re-verification interval and assert `status.expiryTime` stays empty and the entry stays claimed. **A claim that expired on its own would release an identifier on a timer, which FR-103 (`spec.md:877-880`) forbids outright** — this is the one unverified item that could invalidate FR-103 rather than merely AD-16 |
| **U5** | Ordering of release versus storage delete in `github.com/henderiw/apiserver-store` | Read via a fetched summary of `pkg/generic/registry/delete.go`, not verbatim | **G11 addition**: delete a claim and immediately re-claim the same static id; it must succeed. Confirms the release is complete when the DELETE returns, which the provider's finalizer (Rule 8 step 6, `contracts/reconciliation.md:179-182`) assumes |
| **U6** | Whether the allocator can know the final `Network` name at claim time (needed only for P7) | A design question about unwritten code, not a KUID fact | Check when P7 is considered; not a gate item |

---

## Summary of what the operator is being asked to decide

1. **AD-16**: ratify, with P1–P5 as required amendments (sticky adoption, the `ip-vrf` attachment
   VLAN, the no-finalizer window, moving the submitted-check off the allocator, and where the
   correlation label lives). P6–P9 are tidying.
2. **AD-27**: ratify the refusal, with P10–P12 as required amendments (name alternatives, name the
   arbiter, record the rejected options).
3. **One genuine open choice, P13**: narrow the allocation index so named and allocated VLANs cannot
   overlap. It removes the edge case for the price of a naming restriction and one rewritten
   sentence. It is cheap, it is verified feasible at the pinned authority, and the frozen walkthrough
   survives it. It is not mine to take.
4. **One thing to measure before believing either rationale**: U1. Whether dynamic allocation is
   lowest-first decides whether AD-27 guards a rare corner or a scheduled appointment.

---

## Applied 2026-09-20

The operator ratified **AD-16** with amendments P1–P9 (recorded as **AD-32**) and chose **P13 — split
the bands** over AD-27's refusal (recorded as **AD-33**). Both are operator decisions. Every edit
below was made with the shared locked editor; no checkbox was ticked, no identifier renumbered, no
new FR/NFR/SC/R/T/G identifier added, and the KUID clone was not touched. Anchors are quoted text,
not line numbers.

**Canonical wording applied everywhere**: naming band `100–999` (operator-named, claimed by nobody,
exclusive by the one-owner rule of FR-034); allocation band `1000–4000` (the VLAN index's own
`minID`/`maxID`, every value claimed); structural CEL stays `100..4000` and is never asked to tell
the two apart; the rule is stated **by value** because a `Network` cannot say which kind its VLAN is.

### `contracts/kuid-claim-profiles.md` — 10 edits
| Anchor | Change |
|---|---|
| `**Decisions**: D-22, D-25, RD-09, …` | adds AD-16, AD-27, AD-32, AD-33 |
| `\| VLAN index \| …VLANIndex\| 100–4000` | range → **1000–4000**; new "Two VLAN bands, and they do not overlap (AD-33)" block with the band table, the "chosen not derived" statement and where each half is enforced |
| §2 rule 1 `A VLAN the operator named is not claimed.` | rewritten: naming band, both bands in every refusal, the R-28 sentence rewritten honestly, and the split enforcement (translator on the tier path, provider claim gate on the cluster-tooling path, CEL never) |
| §3 `…would hand out an identifier a device may still carry.` | adds **"What decides that a claim is still provisional, and who asks (AD-32)"** — the deployer decides, the allocator deletes what it is told, no verb added — and **"Where the labels live (AD-32)"** — `metadata.labels` only, one canonical selector, a G11 observation |
| §4 `\| A named VLAN outside the VLAN index range…` | refusal states both bands |
| §4 `\| An **allocated** VLAN that another service already attached…` | replaced by three rows: the collision **cannot occur**; the genuine (node, port, VLAN) conflict with the webhook named as arbiter; and the new allocation-band-VLAN-with-no-claim refusal |
| §5 `…cannot retarget an existing claim.` | adds the observed reason `update` is withheld (an update re-runs the claim and moves the allocation) |
| §5 `…so its footprint is enumerable (R-16).` | adds "no verb on `networks` anywhere" and the **deterministic claim name** `<intent-namespace>.migr-<serviceId>.vlan-<entry>`, with why the allocator can form it |
| §6 `…and that the aggregated API is healthy.` | widens G11 by four observations (stated-value refusal naming the holder; label selectability; which value a dynamic claim returns; never below `minID`) |
| §8 `\| Adopt (VLAN) \|` | names the three fields, requires the deterministic name, states the band rule; new **"Adopt (once)"** row making adoption sticky |
| §8 `The provider *creates* nothing…` / `**Not assumed**` | adds the finalizer-at-apply rule, the authority's own field names (`spec.id`/`status.id`/dynamic form), and the two further non-assumptions |

### `contracts/reconciliation.md` — 4 edits
Rule 3 clause 3 (`A VLAN an operator names is claimed on neither path…`) → band-decided VLAN half,
named fields, sticky adoption, collision impossible. Rule 8 gains **step 0** (finalizer present
before deletion ordering matters). Rule 8 step 6 gains "`status.claimRefs` is the whole list" and
the synchronous-release observation. The `Provider-side claims` contract-test row gains the band
refusal, the deterministic name and stickiness.

### `contracts/crd-api.md` — 3 edits
`VLAN range` rule → both bands in the message plus the explicit statement that CEL stops there.
`One owner per (node, port, vlan)` → names it as what makes a *named* VLAN exclusive, notes it sees
both service namespaces, notes both VLANs in such a conflict are named. New transition rule row:
**an added attachment may not name an allocation-band VLAN**.

### `contracts/kubernetes-objects.md` — 4 edits
Submission step 1 → the pre-flight is the intent namespace only and never the arbiter. Step 5 →
**apply with the finalizer already set**; step 6 → rollback never deletes a claim of an applied
object. Allocator identity → "and nothing decides *when* it may delete one", the deployer's role, no
new verb. Denial-probe table → two new probes (allocator reading a `Network`; deployer reading
`agentic-netops-services`).

### `spec.md` — 8 edits
FR-062 rewritten (two disjoint bands, both bands in refusals, collision gone, deployer decides what
is provisional). FR-109 rewritten in two places (band rule with named fields and the
`AllocationConflict` refusal; sticky adoption; added-attachment restriction; finalizer from apply;
deployer-owned release gate; five gate observations). FR-075 allocator clause → no verb on service
intent objects, deployer decides. SC-045 and SC-046 extended. Edge cases: the "`vlan` outside the
range" case → both bands plus three new cases (unbacked allocation-band VLAN, added attachment,
removed attachment); the AD-27 collision case → **cannot occur**; a new case for deletion before the
finalizer. Two change-log rows annotated with AD-32 / AD-33.

### `data-model.md` — 6 edits
The `VLANIndex` row (bands). "Every VLAN is within the range the VLAN index manages" → the by-value
rule and the chosen-not-derived statement. `ClaimRef.released_at` → deployer decides; new
`ClaimRef.labels` row (`metadata.labels`, with the reason). `allocated_value` → `status.id`.
Immutability paragraph → added-attachment restriction and once-per-value adoption. The invariant
list → one-release-owner qualified by the deployer's role and the finalizer, plus a new
adoption-decided-once invariant.

### `plan.md` — 7 edits
R-28, R-44 and R-45 rewritten. G11 gate row widened (four observations, with why each is unknown
from source). C-14 rewritten (band, pre-flight scope, finalizer at apply, release gate). C-21's G11
sentence widened. The third-pass constraint paragraph and the P4 claim paragraph rewritten. The P7
AD-27 paragraph replaced by the band statement plus the deployer's two new responsibilities.

### `tasks.md` — 20 edits across 15 existing tasks
T014 (CEL both bands + added-attachment rule), T017 (band fixtures + added/removed attachment),
T019 (`metadata.labels` selection, `spec.id`/`status.id`), T038 (**index seed `minID: 1000`,
`maxID: 4000`**), T044 (G11 script: four new observations, two negative controls), T055 (a claim
adopted for a value the object no longer carries), T060 (finalizer placement, release every
`claimRefs` entry), T062 (examples use naming-band VLANs; new `vlan-unclaimed-band.yaml` fixture),
T069 (no `update`/`patch` with the observed reason; **no `networks` verb for the allocator**),
T089 (purge assertion qualified — "after a purge run with `--remove-services` that completed"),
T091 (new `vlan_named_in_allocation_band` fixture; both bands in messages), T092 (finalizer at
apply, release gate, cross-namespace conflict fixture, **no collision fixture — case impossible**),
T093 (**the `Network` read moves off the allocator**; asserts it issues none), T100 (finalizer at
apply; deployer owns the release gate), T112 (**no allocated-VLAN case to catch**), T141 (runbook:
two bands; who releases a claim, extended), T170 (band rule, three fields, deterministic name,
CHK033 and R-45 negatives, sticky adoption, `metadata.labels`), T171 (adopt on three things, once
per value; band refusal), T173 (`ip-vrf` attachment case, band observation, **second negative
control for CHK033**).

### `quickstart.md` — 6 edits
G11 gate row widened. §26 gains the band paragraph and the unbacked-band-VLAN check. §26a gains the
band observation, the `metadata.labels` note, the deployer's role, the `ip-vrf` case and the CHK033
negative. Diagnosis table gains two rows (named VLAN outside the naming band; `AllocationConflict`
on a `kubectl`-applied VLAN).

### `research.md` — 5 edits
`[[STUB-AD-32]]` → **AD-32: Adoption is decided once, on three things, and the deployer decides what
is provisional** (Decision / Rationale / Alternatives rejected / Not assumed / Consequences, with
the cross-namespace owner-reference alternative recorded as impossible-and-harmful).
`[[STUB-AD-33]]` → **AD-33: Named and allocated VLANs get disjoint bands, so they cannot collide**
(including "What it costs, stated plainly", the R-28 reconciliation, and per-port indices and the
ConfigMap exclusion list recorded as rejected so they are not re-proposed). One-line **Amended by**
pointers added inside AD-16 and AD-27, which are otherwise untouched. Open item 15 widened from two
unknowns to five, with the `status.expiryTime` hazard recorded beside them. RD-09's stale
"usable range 100–4000" corrected.

### `traceability.md` — 7 edits
New **AD-32** and **AD-33** rows after AD-31. AD-16 row → "Amended by AD-32"; AD-27 row →
"Superseded by AD-33". R-28, R-44, R-45 and SC-046 rows extended.

### `platform-coupling.md` — 1 edit
PC-15's "usable VLAN range is simply the VLAN index's (100–4000)" → the split, with the explicit
statement that it is chosen rather than derived and reinstates nothing.

### `contracts/readme-and-walkthrough.md` — 1 edit
After the frozen-identifier sentence: **all three walkthrough VLANs (152, 170, 253) lie in the
naming band and all three prompts name their VLAN**, so the take allocates nothing and P12 is
unaffected; a second take picks from `100–999`; SC-046 is proven by T173 and quickstart §26a rather
than by the recording.

### CHK033 — closed in prose, no verb added
Closed without giving any identity a new permission, by requiring adoption to agree on **three**
things: the correlation label, the claim's deterministic name derived from the object, and a
reported value the object actually carries. A cluster-tooling object that copies another service's
correlation label satisfies only the first, so it adopts nothing. Recorded in
`kuid-claim-profiles.md` §5 and §8, `plan.md` R-45, `traceability.md` R-45, and tested by T170 and
T173's second negative control. The checklist item itself was **not ticked** — it is reviewer-owned.
