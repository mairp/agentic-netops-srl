# Contract: translation, reconciliation and safety

**Feature**: `004-agentic-netops-composite` | **Carries**: FR-010, FR-014 to FR-018, FR-042,
FR-043, FR-044, FR-045, FR-097, FR-100; NFR-001, NFR-002, NFR-005, NFR-013

**Applies to**: construct translation, the SR Linux provider, the device-configuration layer
integration, device application, drift, failure and deletion.

## Rule 1: No silent semantic loss

- A mapping is allowed only when every required source property has a qualified target equivalent.
- Limited equivalence — a point-to-point service represented by a dedicated L2VNI — requires
  explicit opt-in and a durable status finding.
- Unsupported fields reject the **entire** translation before any allocation, generated `Network` or
  device configuration is created.
- A construct or gated property the qualification record does not show as qualified is refused at
  interpretation, naming it, before any identifier is claimed (FR-097).
- Raw device CLI is never an accepted source format.
- Validation is all-or-nothing: every cause is collected and returned together, and nothing
  partial is ever emitted.

## Rule 2: Deterministic, idempotent rendering

- Equivalent normalized input, fabric design, allocations, schema and mapping version produce
  byte-equivalent canonical device intent.
- Resource names, ordering and hashes are stable, and the emission order is fixed so the golden
  files are a real contract.
- Every derived value — the EVPN instance identifier, the route targets, the subinterface,
  tunnel-interface and integrated-routing indices, and the network-instance names — is a pure
  function of an allocated value, the service identifier or a fabric constant. Nothing is
  separately allocated at render time.
- Identityref and foreign-module enum values are serialized in the exact form the device returns on
  a read. That form is observed at the capability gate before any golden file is frozen, because a
  serialization difference alone would produce a mutation on every reconcile.
- An unchanged render results in no Kubernetes spec write and no gNMI mutation.
- Rendering has no hidden external allocation or mutable local state.
- The same service expressed in the construct vocabulary and in a migration alias produces a
  byte-identical `spec:` block.

## Rule 3: Dependency gates precede mutation

The provider does not emit changed device intent until:

1. the **qualification record** shows every construct and gated property in the object qualified;
2. source intent and references are valid, and the `Fabric` **exists and is Accepted** — its
   inventory is what attachments resolve through. The `Fabric`'s own `Ready` is **not** a gate: a
   `Fabric` reporting `Ready=False` neither holds a `Network` waiting nor suspends its scheduled
   re-verification, which is what lets a service report `RoutesMissing` while the `Fabric` reports
   `NotConverged` ([../data-model.md](../data-model.md) §19, AD-55);
3. every required allocation claim is **bound** and reports its allocated value in status — and the
   provider is what makes that true for a `Network` that arrived without the tier (FR-109): for each
   `l2vni` and `l3vni` it **adopts** the bound claim that carries the object's correlation label,
   bears the deterministic name `<namespace>.<name>.<role>` for that field *and* reports that
   value — three things together, for a VNI claim exactly as for a VLAN claim (AD-42), so that a
   copied correlation label alone adopts nothing — or else **claims exactly that value** from the VNI index through
   `pkg/kuid`, under a name derived from the object's namespace, name and the field's role, labelled
   with the object. The authority arbitrates: a value held by another owner, or outside the
   allocation band, is `Accepted=False/AllocationConflict` naming the value and the holder or the
   band — nothing is rendered, no other value is tried, and no webhook duplicates the arbitration.
   The VLAN half is decided **by band** (AD-33), because a `Network` cannot say whether its VLAN
   was named or allocated: a VLAN in the naming band `100–999` is claimed on neither path and its
   exclusivity is the one-owner rule of FR-034; a VLAN in the allocation band `1000–4000` **MUST**
   be backed by an adoptable bound claim — the tier's — which the provider **adopts** by the same
   three-part rule of label, deterministic name and value, matching the value against the entry
   the claim's name names — `spec.vlans[].vlan` or `spec.bridgeDomains[].vlan`, those two and no
   other — so that the finalizer — and not the tier — releases it. An attachment's VLAN is never
   matched on its own (AD-51): on a `vlan` or `mac-vrf` it is that entry's VLAN, and on an `ip-vrf`
   it is named or absent and never allocated, so an `ip-vrf` attachment carrying a VLAN in
   `1000–4000` has no adoptable claim **by construction**. A VLAN in the allocation band that no such claim backs is
   `Accepted=False/AllocationConflict` naming the VLAN and both bands, with nothing rendered. The
   provider never creates a VLAN claim on either path. **An `accessLists`-only object is outside
   the band rule**: the VLAN on a standalone `acl`'s attachment is a reference to the subinterface
   another service created, so no claim is looked for behind it, whichever band it lies in
   (AD-47). **Adoption is evaluated once per value**: a
   claim already recorded `adopted` in `status.claimRefs` stays adopted for the life of the object
   and is never re-evaluated, dropped or released early — a `vlan` or `mac-vrf` whose VLAN was
   allocated keeps its claim held and listed until finalization when an attachment carrying it is
   removed (AD-25, AD-32). **An authority error is not an answer** (AD-56): a lookup or a create
   that errors — the authority unreachable, the aggregated API unhealthy, a timeout — is never
   read as "no adoptable claim" and never reported as `AllocationConflict`. It is a dependency
   wait, as an unbound claim is: nothing is rendered, no refusal is recorded, and the pass is
   retried with bounded exponential backoff and jitter ([../data-model.md](../data-model.md) §19).
   Only the authority's own answer that no such claim exists lets the claim step, or the band
   refusal above, run. Because the two bands are disjoint,
   an allocated VLAN can never equal a VLAN another service named, so no reconcile has to detect
   that case (AD-33 supersedes AD-27's refusal path)
   (AD-16, AD-32, AD-33, AD-42, AD-47, AD-51, AD-56;
   [kuid-claim-profiles.md](./kuid-claim-profiles.md) §1, §2, §3, §4, §5, §8);
4. the target's `Schema` is loaded and Ready and the `Target` and its credentials are Ready;
5. image, schema and mapping compatibility match across all nine parts of the compatibility set;
6. every rendered path passes offline schema validation against the pinned device schema;
7. every rendered path is covered by the path register.

Failure sets a current-generation condition with a reason code from the closed set and an Event.
Partial render output is not applied.

## Rule 4: One owner per managed path

- The `Fabric` and the allocation authority own design and allocations; the provider owns generated
  configuration specs; the device-configuration layer owns device transactions; the intent tier owns
  none of them and submits only into its own namespace.
- The provider uses scoped paths and server-side-apply field ownership under one field manager.
- **Two configuration resources that can touch the same device leaf MUST have distinct priorities.**
  The layer leaves an equal-priority winner undefined, so an equal-priority overlap is a conflict
  refused at validation, never an ordering left to the layer to resolve. The reserved bands are
  `10` for fabric configuration and `20` for service configuration. **A leaf is a non-key leaf, and
  no two service `Config`s share one by construction** (AD-68): the port-level leaves of an access
  port and `irb0`'s own `admin-state` are the fabric `Config`'s; a service `Config` writes nothing
  above its own `subinterface[index]`; a subinterface's `/acl/interface[…]/interface-ref` is rendered
  by the `Config` that renders the subinterface, and a standalone `acl` writes only its filter entry
  beneath it. The provider compares non-key leaf paths against the node's other `Config`s of the
  same priority before writing, and an overlap is `Applied=False/OwnershipConflict` naming the path
  and the other `Config` — a backstop that fires on a defect, never on two well-formed services.
- **An `OVERRULED` deviation on a platform-owned path is a terminal error**, not a warning: it means
  a higher-precedence intent has taken a path this platform believes it owns, and the layer will
  never fight it back. The condition names the path and the overruling intent.
- The ownership assertion is machine-checked rather than aspirational: for every managed path, the
  layer's own per-leaf blame record must name this service's intent and no other.
- The platform does not overwrite unmanaged device paths, and a brownfield path with no matching
  configuration resource is reported as an unhandled deviation rather than claimed.
- An access-list renderer writes only its own filter and its own binding, and never
  read-modify-writes another filter or another service's binding list.

## Rule 5: Safe transaction and readiness semantics

- Validation and transaction confirmation are mandatory; direct device mutation is forbidden, and
  there is no path by which anything outside the cluster writes device configuration. The tools that
  check the platform — the capability gate, fault and drift injection, the walkthrough's read-only
  device proofs — are bounded by FR-108 and are never such a path: what they write is scratch or a
  declared fault, they remove it themselves, and no platform outcome depends on them.
- **"Dry-run" means two real things, and neither is the Kubernetes API server validating a device
  payload.** (1) A server-side dry-run of the `Network` against its structural schema and its CEL
  and webhook rules, which is meaningful because the CRD has a real schema. (2) Schema validation of
  the rendered device configuration — offline in CI, and again by the device-configuration layer
  before any device write. The API server cannot validate the rendered native value, and that MUST
  NOT be presented as a gate.
- A device transaction is atomic: either every modification in it applies or the whole request rolls
  back. **A failed transaction fails its own transaction only**; nothing it wrote persists and
  nothing it did poisons a later commit.
- **Read-back is two-sided for every construct** (FR-100): the written side — the configuration
  resource applied with no deviation and its content present in the device's **running** datastore
  — and the applied side — the device's own **state** for the objects this service created. Every
  applied-side read is keyed to this service's own objects; a fabric-wide or device-wide count is
  never evidence.
- **The `Fabric`'s applied side is its own objects, and never a route count** (AD-23, AD-31):
  interfaces and subinterfaces up, every underlay and overlay session established with the EVPN
  family negotiated — read from the family's own `oper-state` per neighbour, not inferred from the
  session — and every other node's allocated `system0.0` loopback present and active in this node's
  route table. Beside them, and **stated as a configuration-integrity check rather than applied-side
  behavioural evidence**, `inter-as-vpn` and `route-reflector client` read back `true` from every
  reflecting spine: both are configuration leaves, and SR Linux 25.7.1 does not mirror them into
  state, so both are read from the configuration datastore (the running datastore through the
  device-configuration layer), as decided (AD-76); the read shows they are applied, not that
  reflection works. A `Fabric` that declares either setting other than it reads back fails the same
  read. A `Fabric` that itself declares `overlay.reflectorClients: false` reports
  `Ready=False/NotConverged` naming the spines and the setting — which is how SC-004's declarative
  negative control shows on the `Fabric` while each spanning `Network` reports `RoutesMissing`
  (AD-43's mechanism, its field as decided in AD-77: with `inter-as-vpn` removed the spines still
  reflected, so `overlay.interASVPN: false` is no control). The `Fabric` converges
  before any service exists, so zero EVPN routes is then correct; route exchange through the
  rendered fabric is an invariant of each `Network` spanning two leaves (`RoutesMissing`), keyed to
  that service's own EVPN instance, and reflection on the rendered fabric is proved by G8 and by
  T051's post-render probe, neither of which is an input to readiness (FR-108).
- Aggregate `Ready=True` requires all mandatory per-device operations to be confirmed **and** both
  sides of the read-back to pass on the current generation.
- **`Ready=True` is re-verified on a schedule, never remembered** (FR-107). For the `Fabric` and for
  every `Network` that has reported Ready, the same two-sided read-back is repeated at the
  re-verification interval — five minutes by default ([../data-model.md](../data-model.md) §25) —
  whether or not anything changed. A pass that **ran** — that completed its read-back on both sides, whatever it found — advances
  `status.lastVerifiedTime` and the `reverify_last_success_timestamp_seconds` metric
  ([../data-model.md](../data-model.md) §21); a pass that finds an invariant missing has run, so it
  advances both **and** sets
  `Ready=False` naming it, with the same reason codes as a first convergence (AD-54); drift it finds on an
  owned path is handled by Rule 6. A pass that **could not run** — a required target unreachable, or
  the read timed out — sets `Ready=Unknown/VerificationFailed` and
  `Degraded=True/VerificationFailed`, both naming the target, at that pass and not after a further
  wait, and advances neither the field nor the metric. It never sets `Ready=False`, because an
  outage is not evidence that an invariant is gone, and never leaves `Ready=True` standing, because
  that would be a remembered result; the next pass that runs settles it either way. The reconciler
  that observes a required target of a Ready object not Ready between two passes does the same,
  which is what keeps SC-008's two-interval bound for a target failure (FR-107, AD-40). An
  object that has never reported Ready is outside the schedule; one held in deletion stays inside
  it **only as the finalizer's requeue** (Rule 8): no read-back decides its readiness, it is
  `Ready=False/Deleting` from step 1 and never `Ready=Unknown`, and its
  `reverify_last_success_timestamp_seconds` series is removed when finalization starts (AD-53,
  AD-54). `REVERIFY_INTERVAL` below its 30 s floor, or unparseable, refuses the provider's
  start ([../data-model.md](../data-model.md) §25). The schedule is a requeue, not a second controller, and it writes
  no `Config` when nothing differs (Rule 2).
- A mixed success/failure result is `Degraded`, records every target, and never claims full
  success.
- The last valid configuration remains desired when a new generation fails validation.
- No automated rollback may erase unrelated, shared or manually owned configuration.

## Rule 6: Drift is explicit

- The configuration layer compares intended and running configuration for owned paths and types each
  difference: **unhandled** (no matching configuration resource — brownfield, reported only),
  **not-applied** (a matching resource exists and the device differs), or **overruled** (a
  higher-precedence intent won).
- The drift policy is `revertive`: a not-applied deviation is reapplied and restoration is
  verified. It is the **only member of a closed set** (FR-015, AD-17, AD-34). The policy is stated
  on every configuration resource as its revertive field, never left absent for the layer's own
  default to supply.
- The device-configuration layer also has a non-revertive mode. It does **not** simply accept the
  device's value: it records the deviation and holds it for the operator, who may accept it as
  active — which is not repair — or revert it, which is. Hold-and-operator-revert is therefore a
  policy constitution Principle I would admit; it is **not admissible here** because this platform
  builds neither the `Ready=False` shape a held deviation needs nor the path that clears one. So
  `DRIFT_POLICY` set to anything but the exact string `revertive` refuses the provider's start as
  an unset one does. Admitting another value is a change to FR-015 that brings that value's repair
  procedure, status shape, tests and runbook entry with it.
- An overruled deviation on a platform-owned path is never reapplied — it is the terminal error of
  Rule 4.
- Clearing a deviation is an explicit operator action, never an automatic side effect.
- Unmanaged-path changes are observed only if subscribed; they are neither reverted nor claimed.
- Production drift policy must be explicitly selected and cannot inherit the lab default silently —
  there is no default to inherit, and today there is one value to select, the same one the lab
  selects.

## Rule 7: Bounded retry and classified errors

- Transient transport and unavailability failures retry with bounded exponential backoff and
  jitter.
- Terminal schema, unsupported-feature, unqualified-construct, ownership, collision and
  compatibility errors do not hot-loop; they retry on a relevant generation or dependency change.
- Every failure emits a stable reason code, a rate-bounded Event, a metric and a concise status.

Default timings: controller resync and requeue 15s; transient backoff base 250ms with full jitter,
capped at 10s, maximum 6 attempts; terminal errors do not retry until a relevant generation or
dependency change; scheduled re-verification every 5 minutes (Rule 5, FR-107). Every one of them is
configuration, tabulated with the intent tier's bounds in [../data-model.md](../data-model.md) §25.

## Rule 8: Ordered deletion and recoverable finalization

0. **The finalizer is on the object before any of this can help.** A tier-submitted `Network` is
   applied by the deployer with the finalizer already set, so it is never finalizer-less and a
   deletion in the window before the provider's first reconcile still blocks here (AD-32,
   [kubernetes-objects.md](./kubernetes-objects.md) §"Submission contract"). A `Network` applied
   with cluster tooling takes the finalizer from the provider's first reconcile. Neither can be
   *applied* while the provider is down: the admission webhook it serves fails closed, so the API
   server refuses the create ([crd-api.md](./crd-api.md), AD-52). The one finalizer-less window is
   therefore an object applied with cluster tooling and then deleted before that first reconcile —
   the provider slow, or gone down after the apply was admitted. A delete is never intercepted: one
   that arrives while the provider is down removes such an object outright, and waits here on every
   object that carries the finalizer.
1. Mark deletion in progress — **`Ready=False` with the reason `Deleting`, set at once**, beside
   `Deleting=True/<what is outstanding>`, before anything is removed, whatever the reachability of
   the object's targets, and kept until the object is gone: a service being removed is no longer
   offered, so nothing is read back to decide it, and it is never `Ready=True` and never
   `Ready=Unknown` from here on (FR-103, AD-53) — and stop new render changes — and **resolve adoption before anything
   is released** (AD-44): for every value the object carries that is not yet in
   `status.claimRefs`, run the adoption predicate of Rule 3 — the same three-part rule, nothing
   looser — and record what it adopts. A tier-submitted `Network` deleted before the provider's
   first reconcile has an empty `status.claimRefs` and claims that are nonetheless its own; the
   finalizer of step 0 holds the object, and this is what gives step 6 something to release.
   Nothing is *claimed* on a deleting object: a VNI nobody claimed is not claimed in order to be
   released. **An authority that errors has not answered** (AD-56): a lookup that fails — as
   opposed to one that returns no such claim — adopts nothing *and settles nothing*. The finalizer
   stays, `Deleting=True/RemovingConfiguration` stays with the authority named in its message, and
   the pass is requeued with bounded exponential backoff. Steps 2 to 5 do not wait on it —
   removing configuration needs no claim — but **steps 6 and 7 never run on a list this step
   could not complete**, or a tier claim the lookup failed to see would be orphaned by the very
   path AD-44 closed.
2. Remove only device intent owned by the source, **in dependency order**: the access-list binding
   first, then the filter, and only then anything that owns the subinterface. The binding is a
   separate object from the interface, so removing the subinterface first leaves a dangling
   reference.
3. **A service whose attachment subinterface still carries another service's standalone access list
   MUST NOT finalize** until that list is withdrawn; the finalizer surfaces the holder by name
   rather than leaving a dangling binding or silently deleting someone else's filter (FR-043).
4. Conversely, an object that has a deletion timestamp **still holds its own bindings until it is
   gone**: a request that would take one of them is refused, and the refusal says the holder is
   being removed.
5. **Confirm cleanup by reading the removal back from every affected device.** *There is no
   timeout on this step* (FR-103; the earlier "record a target-unreachable timeout" is withdrawn).
   With a target unreachable the object remains, `Deleting=True/TargetUnreachable` names each such
   target, configuration already removable from reachable devices is removed, **every allocation
   stays claimed**, and the reconciler requeues at the re-verification interval. When the target
   returns, removal completes with no operator action.
6. Release only owned identifier claims — the ones the provider adopted (the tier's VNI **and VLAN**
   claims, AD-16) and the ones it created (FR-109), both recorded in `status.claimRefs` — and only
   after step 5. `status.claimRefs` — completed by step 1 on an object that was never reconciled
   while it lived — is the whole list and the only list: a claim that was adopted
   is released here and nowhere earlier, whatever attachments were removed meanwhile — a `mac-vrf`
   whose VLAN was allocated and from which an attachment carrying that VLAN was removed while it
   lived still lists its VLAN claim, and releases it here. Every claimed value sits on an immutable
   named entry, so no object can stop carrying one (AD-25, AD-32, AD-51, AD-61).
   Deleting a claim at the pinned authority frees its value **synchronously**, as the DELETE
   returns, so there is no grace period to lean on and this step is the only place it may happen
   (read at `v0.0.13`, and observed by G11 — a stated-value claim is deleted and an immediate
   second claim for the same value binds — before this step relies on it, R-44). **A construct whose profile claimed
   nothing releases nothing, and that is a success, not a missing-claims error.** A DELETE that
   **errors** is neither: the claim stays in `status.claimRefs`, the finalizer stays, the reason
   stays `RemovingConfiguration` naming the authority, and the step is retried with backoff until
   every entry is gone — a claim already gone counting as released. No timer is on this path
   either, and the force-release is not an exit from it: that is honoured only on
   `TargetUnreachable` (FR-103), and the authority is an in-cluster dependency whose return
   completes the step unaided (AD-56).
7. Remove the finalizer. That is an `UPDATE` of the `Network`, and the admission webhook admits it
   without evaluating a rule — as it does every `UPDATE` of an object carrying a deletion timestamp
   and every `UPDATE` that leaves `spec` unchanged — so an object whose attachment no longer
   resolves, or whose node has left the `Fabric` inventory, still finalizes
   ([crd-api.md](./crd-api.md), AD-61).

**Force-release is the only other exit** (FR-103, CD-02). Every row of the table below is
**required by FR-103**, which states the guard rules and the open-finding consequence; this contract
states their shape. It is the annotation
`fabric.agentic-netops.io/force-release: "<reason>"` on the `Network`, set by an operator with
cluster tooling. Setting it is a metadata-only `UPDATE`, which the admission webhook admits without
evaluating a rule (AD-61), so it can be set on a service whose unreachable device has already been
removed from the `Fabric` — the never-returning target, where it is the only exit; the rules that
guard it are the ones below, unchanged:

| Rule | |
|---|---|
| The reason is required | an empty value is refused with a `Warning` Event `ForceReleaseRefused`; nothing is released |
| It is honoured only on an object that is being deleted **and** is blocked on `TargetUnreachable` | set on a live service it is ignored with an Event; it is never a way to delete |
| The intent tier cannot set it | both tier identities are denied at admission ([kubernetes-objects.md](./kubernetes-objects.md)) |
| Before anything is released | a `Warning` Event `ForceReleased` is published, and a finding is appended to `Fabric.status.findings[]` naming the service, the device, every identifier released and the device object names the service had rendered there, stating that **the device may still carry stale configuration** |
| The finding outlives the `Network` | it is removed only after the `Fabric` reconciler's scheduled re-verification has read that device and found every named object absent from the running and the state datastore |
| While the finding is open | a render that would produce one of the named objects on that device is refused `OwnershipConflict`, so a re-claimed identifier cannot collide with the stale one |

Removing the finalizer by hand with cluster-admin rights remains physically possible and records
nothing; the runbook (NFR-011) names it as what **not** to do and lists what it orphans. What the
device-configuration layer does with a `Config` deleted while its target was away is **observed**
by `make test-delete-unreachable`, not assumed.

## Rule 9: Telemetry does not control configuration

- A monitoring outage degrades observability but neither blocks nor mutates desired network state.
- The device metric collector is the only device collector and exports over OTLP to the telemetry
  collector; overlapping subscription-based ingestion in the configuration layer is disabled for
  those same series. Both are clients of the same device management server, whose session limit is
  sized explicitly for the two together.
- The collector's own health endpoint is scraped, so every pipeline stage has evidence.
- Metrics never contain secrets or unbounded raw path or error values as labels.
- Prometheus is the metric store; the telemetry collector is a receiver-processor-exporter.
- Topology identifiers and metric labels use one versioned join contract of exactly two labels; the
  topology and service-path views must not infer or invent nodes, links, paths or health.

## Rule 10: Environment lifecycle is centralized and idempotent

- The cluster is the sole runtime for every platform and intent-tier application.
- There is **one lab profile**. No flag selects a device profile and no phase branches on one.
- Provisioning progresses through the owned network, cluster, containerlab, application, target,
  capability-gate, fabric, safety-boundary, observability and tier phases using **readiness, not
  fixed sleeps**, as its gates.
- The management address space is checked against every existing Docker network, the pod CIDR and
  the service CIDR **before anything is created**; an overlap fails preflight naming the colliding
  network.
- Re-running provisioning reconciles current state and never deletes a healthy cluster merely to
  obtain a clean install.
- Shutdown works backward from any partial state, optionally captures evidence first, and deletes
  only explicitly named or labelled platform resources — never anything under the lab's evidence
  root, whether or not that capture was asked for (FR-010, AD-64).
- Both scripts use bounded waits and actionable phase-specific failures. An absent owned resource
  is successful cleanup, not an error.

## Rule 11: Construct rendering is explicit per construct

- An attachment with a VLAN resolves against the bridge domains **then** the local VLAN list;
  matching neither is an error naming both sets.
- An attachment with neither a VLAN nor a routed instance is an error **only when** the object
  declares no access lists; otherwise it is an access-list-only attachment, and it may carry a VLAN
  purely to name which existing subinterface to bind to.
- A `vlan` renders a bridge-domain network-instance with bridged subinterfaces and **never** a
  VXLAN interface, an EVPN instance or a route target. A `vlan` is held to no overlay evidence,
  because it has none to give.
- A `mac-vrf` renders a bridge-domain network-instance that **must** carry a non-zero L2VNI, a
  bridged VXLAN interface at index `= vni`, an EVPN instance whose identifier is `= vni`, and both
  route targets rendered explicitly as `target:<fabricASN>:<vni>`. A device-derived route target is
  never relied on: it would use the per-leaf underlay AS and differ on every leaf.
- An `ip-vrf` renders a routed network-instance with a routed VXLAN interface, an interface-less
  EVPN instance, and routed subinterfaces carrying the attachment addresses. Declared prefixes are
  advertised because they are in the routed instance's route table; a declared prefix that no
  attachment and no rendered route puts there is **refused at validation**, naming the prefix,
  rather than applied in the hope that it appears.
- A `mac-vrf` with a gateway renders `irb0.<vlan>` attached to **both** the bridge domain and the
  routed instance, with the anycast container present before any address is marked anycast, only the
  declared address families, the fabric-constant virtual-router-id, unsolicited neighbour learning,
  host-route population and EVPN advertisement all enabled, and an explicit IP MTU.
- An access list renders on **every** node that has an attachment in this object, bound to that
  node's own subinterfaces and no others, with both the binding key and an explicit interface
  reference always written.
- A standalone access list requires the subinterface to already exist, checked against the
  attachments of other `Network` objects; it never creates an interface or a subinterface.
- **Equal ownership is refused, never resolved**: two objects deriving the same
  `(node, port, vlan)` subinterface, or the same binding unit
  `(node, port, subinterface, direction, address family)`, are refused before anything is created,
  naming the holder.
- An object that produces no node plans is an error — an access-list-only service must produce
  node plans, or nothing was bound and reporting success would be a lie.

## Rule 12: *Retired*

*Retired by the SR Linux retarget (RD-04) — the atomic, capture-verified SRv6 service generation is
deferred with the SRv6 service itself. See [spec.md](../spec.md) §Deferred scope.*

## Contract tests

| Property | Required proof |
|---|---|
| No semantic loss | Unsupported and limited-equivalence fixtures reject or require opt-in before mutation |
| Qualification gate | A construct or gated property absent from the qualification record is refused at interpretation; zero objects, zero claims |
| Determinism | Golden render and hash identical across repeated runs |
| Identityref serialization | A render, a device read-back and a re-render of the same generation agree byte for byte on every identityref and foreign-module enum value; a change in that form fails the test rather than producing a silent mutation |
| Vocabulary equivalence | The same service in a migration alias and in construct form emits a byte-identical `spec:` |
| Idempotence | A second reconcile causes zero spec and zero gNMI change |
| Dependency gating | A missing schema, target, qualification record or unbound claim produces Waiting or Degraded and no changed configuration |
| Provider-side claims | A `Network` with no adoptable claim has one bound claim per VNI, for exactly the stated value, before its first `Config`; a tier claim matching label, deterministic name **and** value is adopted, never duplicated — VNI and VLAN alike, a VLAN claim never being created by the provider; a held or out-of-band value is `AllocationConflict` with zero `Config`s; a VLAN in `1000–4000` that no adoptable claim backs is `AllocationConflict` naming the VLAN and both bands, while one in `100–999` needs no claim; an `accessLists`-only object carrying a `1000–4000` attachment VLAN is accepted with no claim looked for, because that VLAN is a reference; a label-and-value match under any other claim name is **not** adopted, VNI or VLAN; a claim once `adopted` stays in `status.claimRefs` and is never re-evaluated — a `mac-vrf` whose VLAN was allocated keeps it after an attachment carrying it is removed; an **`ip-vrf` attachment carrying a VLAN in `1000–4000` is `AllocationConflict`**, no claim being adoptable behind it by construction (AD-51); **an authority that errors is neither "nothing adoptable" nor `AllocationConflict`** — with the `pkg/kuid` fake failing, nothing is rendered, no refusal is recorded and the pass retries, and in finalization the finalizer stays, nothing is released and removal completes once the fake answers again (AD-56); a tier-submitted object deleted **before its first reconcile** has its claims adopted at finalization and then released, none left behind; every adopted claim is released by finalization and none by the tier (FR-109, SC-045, SC-046, AD-32, AD-33, AD-42, AD-44, AD-47, AD-51, AD-56) |
| Register coverage | Every rendered path is registered; a new construct cannot pass uncovered |
| Partial failure | One failed target prevents aggregate Ready and identifies per-target results |
| Ownership | A manual unmanaged path survives update and deletion; the layer's blame record names this platform's intent and no other on every managed path |
| Equal-priority refusal | Two configuration resources that could touch one leaf at the same priority are **refused at validation**, with the conflict named — never applied and left to the layer to order |
| Overruled deviation | An overruled platform-owned path sets a terminal condition naming the path and the overruling intent, and is never reapplied |
| Drift | A not-applied deviation on a managed path is reverted under the revertive policy, witnessed as gate item G13 observed it to be witnessable; an unhandled deviation is reported and not claimed |
| Recovery | A controller restart between render and confirmation converges safely; a target reconnect replays only recorded applied state |
| Deletion | `Ready=False/Deleting` from the first reconcile that sees the deletion timestamp, before anything is removed, and until the object is gone (AD-53); owned paths and claims removed in binding → filter → subinterface order; shared paths and claims preserved; a foreign standalone list blocks finalization and is named |
| Deletion, target unreachable | With one affected device unreachable the object remains, `Deleting=True/TargetUnreachable` names it, `Ready` is `False/Deleting` at every observation — never `True`, never `Unknown/VerificationFailed` (AD-53) — and a claim-selector diff shows **every** allocation still bound across at least ten reconciliation intervals; on the device's return removal completes with zero operator action. No code path on this route carries a deadline (SC-043) |
| Force-release | An empty reason is refused and releases zero identifiers; set on an object that is not both deleting and blocked on `TargetUnreachable` it is ignored with an Event and nothing released; removing the unreachable device from the `Fabric` completes nothing and releases nothing; a tier identity is denied at admission; an honoured release publishes the Event and leaves a `Fabric` finding naming the device, the identifiers and the object names — visible in `status.findings[]` at once, the `Fabric`'s `Degraded` reason staying `VerificationFailed` while that device cannot be read and becoming `StaleConfigurationPossible` at the first pass after it returns with the finding still open (AD-54); the finding clears only after a clean read-back — one whose node has left `spec.nodes` therefore stays on record, and does not count toward `Degraded` until the node returns (AD-71); a colliding render is refused while it is open |
| Two-sided read-back | For every construct, both sides are read; either absent is unconverged |
| Scheduled re-verification | With no change to intent, a Ready object whose applied-side invariant is withdrawn goes `Ready=False` naming it within one re-verification interval plus one reconciliation interval, and returns on recovery; `status.lastVerifiedTime` advances on every interval; a pass that finds nothing writes no `Config`. **A pass that cannot run** — the target unreachable — sets `Ready=Unknown/VerificationFailed` and `Degraded=True/VerificationFailed` naming the target at that pass, never `Ready=False` and never a standing `Ready=True`, with `lastVerifiedTime` frozen, and `Ready=True` returns at the first pass after the target does. `REVERIFY_INTERVAL` below 30 s or unparseable refuses the start (FR-107, SC-044, AD-40) |
| Verification-tooling boundary | No device client is invoked from anywhere but the gate, the test suites and the walkthrough tooling; every such invocation is run-captured; scratch configuration is removed and its removal read back before the run continues (FR-108) |
| Keyed read-back, negative control | Every applied-side check is shown to **fail on a stock fabric** that does not carry the thing it checks for, before its pass is allowed to count; an unkeyed check that passes on an empty fabric is a defect, not a result (NFR-013) |
| Access-list convergence | The filter, its entries, the reserved terminal entry and the binding are read back on both sides, each keyed by filter name, type and entry, and in the declared direction only |
| Telemetry isolation | A collector outage leaves reconciliation functional and surfaces telemetry degradation |
| Device pipeline | Runtime inspection proves one collector path for device series |
| Topology exposition | Topology identifiers and direct metric results match both views |
| Central placement | Runtime inventory finds all platform applications in the cluster and none in a Compose or standalone container |
| Provision lifecycle | Clean and repeated runs converge without destructive recreation |
| Shutdown lifecycle | Ready, partial and already-absent states clean up safely and idempotently |
