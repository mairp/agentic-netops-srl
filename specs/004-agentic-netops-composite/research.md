# Phase 0 Research: Agentic NetOps — Composite Platform

**Feature**: `004-agentic-netops-composite` | **Date**: 2026-09-20 | **Spec**: [spec.md](./spec.md)

The merged decision record: 10 decisions from the declarative control plane, 16 from the intent
tier and 11 from the construct vocabulary, renumbered `D-01`…`D-37` and grouped by the same
concern order the requirements use, **revised in place wherever the move to Nokia SR Linux changed
what was decided**, followed by the retarget's own decisions as `RD-01`…`RD-15` in §11 and the
clarification decisions of the 2026-09-20 plan refresh as `CD-01`…`CD-06` in §12. Each entry
keeps what was chosen, why, and — the reason this record is worth carrying at all — **what was
rejected**.

The retargeting pass has happened. Several alternatives the merge rejected were re-opened by it,
and the record says so at each one rather than deferring the question: the two-profile lab split
(reversed, D-01 / **RD-01**), OpenConfig-preferred path selection (reversed to native-first, D-06
and D-09 / **RD-08**), reuse of an upstream fabric intent API (reversed to a first-party API, D-04
and D-06 / **RD-03**), the refusal to match ICMPv6 (reversed, D-15 / **RD-05**), and traffic
assertions through the client containers (partially adopted — in acceptance only, never in
readiness, D-16 / **RD-05**). Two decisions did not survive the platform change at all and are
tombstoned with their numbers kept: **D-08** (SRv6, retired by **RD-04**) and **D-12** (raw-store
access-list writes, retired by **RD-02**). Row-by-row resolution of every platform coupling is in
[platform-coupling.md](./platform-coupling.md); the research the retarget decisions rest on is in
[evidence/](./evidence/).

Source attribution for every decision is in [traceability.md](./traceability.md).

---

## 1. Lab, topology and lifecycle

### D-01: One containerlab profile, qualified as a whole

- **Decision**: use containerlab for every network node, with the `nokia_srlinux` kind and **one
  lab profile only**. Leaves run the emulated `ixr-d2l` type and spines the `ixr-d3l` type — both
  licence-free and both carrying the full EVPN-VXLAN feature set. No hypervisor, no KVM and no
  nested virtualization is required, and no flag selects a device profile (FR-010).
- **Reference topology**: `spine01`, `spine02`, `leaf01`, `leaf02`, `client01` (on `leaf01`) and
  `client02` (on `leaf02`) — six nodes. Spines provide a dual-stack routed underlay and reflect the
  EVPN overlay without terminating tenant VXLAN; leaves are the VTEPs, sourcing tunnels from
  `system0.0`, which is also the router id. The clients are Linux containers that take part in
  several services at once through **VLAN subinterfaces on their single link**, so L2, L3,
  isolation and access-list tests need no further nodes. IPv4 `/31` plus IPv6 underlay links,
  system loopbacks as router ids and VTEP sources, a BGP EVPN overlay, symmetric IRB where a
  gateway is declared, and an MTU envelope that accounts for VXLAN overhead (RD-10).
- **Qualification**: pin the containerlab version and the image digest, then run the capability
  gate — **G1 to G13 as written in RD-12 and FR-004** — before any orchestration test. The gate is
  the qualification list; there is no separate, weaker per-profile list, because there is no second
  profile.
- **Constraint**: the container uses a software forwarding layer and is not ASIC-equivalence
  testing. Its packet-rate ceiling is roughly 1–5 kpps per node, so acceptance asserts
  reachability, isolation and counter movement and never throughput (FR-020, NFR-004).
- **Why the two-tier split is gone, stated honestly**: the split was not a principle. It existed
  because the previous platform's *container* image lacked management services and EVPN data-plane
  behaviour — one profile approved for that lab shipped no gNMI server at all — so a VM profile was
  the only way to qualify anything, and the fast profile could never be the one under test. The SR
  Linux container carries no such deficit: the licence-free emulated types expose the same gNMI
  management surface, the same EVPN-VXLAN feature set and a forwarding layer that enforces access
  lists. With no capability the container lacks, a second profile would be a slower copy of the
  first, and the honest consequence is that the fast lab is now also the conformance lab.
- **Alternatives rejected**:
  - *The two-tier fast/conformance split.* Reversed, for the reason above; it would now buy a KVM
    dependency and a second matrix for no capability.
  - *An `ixr-h`-series emulated type.* It models no VXLAN, so it cannot carry any overlay
    construct in any role.
  - *Pinning the newest published release.* The pin is the newest release for which every part of
    the compatibility set has a matching artefact, not the newest image that exists (RD-01).
- **Revised by**: RD-01, RD-12.

### D-02: The Kubernetes cluster is the single application runtime

- **Decision**: provision one pinned Kind cluster named `agentic-netops` and run the fabric control
  plane, the allocation authority, every device-configuration component **and its cert-manager
  prerequisite**, the platform controllers, the device metric collector, the telemetry collector,
  the metrics store, the dashboards, their operator resources and every intent-tier workload inside
  it. Containerlab runs only SR Linux nodes and Linux traffic endpoints.
- **Rationale**: centralizing controllers, configuration, Secrets, RBAC, service discovery,
  health, telemetry and lifecycle in one declarative operational surface. It also makes metric
  discovery and Kubernetes enrichment straightforward. cert-manager is in the cluster rather than
  beside it for the same reason: the device-configuration layer's aggregated API server will not
  serve without it, so it is a platform application with a pinned manifest like every other.
- **Connectivity**: the lifecycle script creates a dedicated labelled Docker management network
  `agentic-netops-mgmt`, default CIDR **`172.25.25.0/24`** and configurable through `MGMT_CIDR`,
  connects the cluster node containers to it, and configures containerlab to reuse it. Pod and
  service CIDRs stay separate from device management addressing, and a **preflight refuses to
  create anything when the chosen space overlaps an existing Docker network, the pod CIDR or the
  service CIDR**, naming the collision (FR-008).
- **Alternative rejected**: separate Compose or standalone containers for the device-configuration
  layer or telemetry. They split ownership, duplicate service discovery and secret handling, and
  complicate ordered teardown.
- **Alternative rejected**: a host-side component of any kind with a device write path. FR-007 now
  carries no exception at all (RD-02); nothing outside the cluster reads or writes device
  configuration.
- **Revised by**: RD-02.

### D-03: Polyglot build and CI — additive jobs, no change to the Go path

- **Decision**: the Python tier lives under `agents/`, the browser app under `ui/`, and the Go
  translator wrapper under `cmd/intent-translator/`. CI gains a Python job, a UI job and a
  no-credential-literals job. The existing Go job is not modified.
- **Rationale**: polyglot is an accepted cost; the question is only how to keep the dependency
  arrow one-directional. Additive jobs mean deleting the tier deletes its jobs and leaves the Go
  pipeline byte-identical, which is the CI half of the removability criterion.
- **Package layout**: the tier's internal import paths are preserved by copying the `agents/` tree
  into each image, so its `from config.config import …` style imports resolve unchanged. The
  Python config module lands at `agents/config/` and never at the repository-root `config/`, which
  belongs to the Go API types and cluster assets.
- **Alternative rejected**: a separate repository for the tier. It satisfies removability
  trivially but breaks the single bring-up path the operator story requires.

---

## 2. Declarative control plane, reconciliation and rendering

### D-04: Reuse the upstream allocation/inventory and device-configuration APIs; own the fabric API

- **Decision**: pin and reuse, unchanged, the device-configuration layer's `Schema`,
  `TargetConnectionProfile`, `TargetSyncProfile`, `DiscoveryRule`, `Target`, `Config`, `ConfigSet`,
  `RunningConfig`, `Deviation` and `ConfigBlame` APIs, and the allocation authority's IP, ASN, VLAN
  and generic-identifier index and claim APIs together with its node, link and endpoint inventory.
  **Define the fabric and service intent in exactly one first-party API group**,
  `fabric.agentic-netops.io/v1alpha1`, with structural OpenAPI schemas and no
  `x-kubernetes-preserve-unknown-fields` on `spec`: a `Fabric` Kind for the fabric design and the
  `Network` Kind for service intent. No `NetworkDevice`-style per-device intermediate Kind exists;
  the per-(service, node) object is the device-configuration layer's `Config` itself (FR-013).
- **Rationale**: the two halves of this decision are reused for opposite reasons. The
  device-configuration and allocation projects are current, released and serve exactly the
  contracts the platform needs, so reimplementing them would add risk for nothing. The upstream
  *fabric* control plane is not in that state: it is dormant, it renders for a device release two
  years old, it no longer builds against the current device-configuration layer, and its intent
  object cannot express an access list, an anycast gateway, a local bridge domain or an explicit
  route target — four of the things this specification exists to provision
  ([evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md) §1.3, §2.4).
- **Finding that changed this decision**: the predecessor build never ran the upstream fabric
  control plane at all. Its installer fetched CRD paths that do not exist upstream and **silently
  fell back to hand-written look-alike CRDs in look-alike API groups**, and the `Network` shape the
  whole data model rested on was a first-party invention presented as an upstream API
  ([evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md) §0, §1, §2). The reuse this
  decision once claimed was therefore never tested by the running system. 004 records that and
  forbids the mechanism: no CRD or API service may be installed into an upstream project's API
  group unless it is that project's own pinned artefact (FR-098).
- **Version finding**: the upstream artefacts disagree with each other across releases, so the
  implementation pins one complete commit or release per project and validates every example
  against that release's served APIs. It must not combine tutorial YAML with an unpinned branch,
  and it must not assume a Kind's storage version from the version it writes.
- **Alternatives rejected**:
  - *Adopting the upstream fabric CRDs as they are.* They cannot express the four constructs, and
    the project that serves them is dormant; the platform would inherit a frozen dependency it
    cannot extend ([evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md) §6).
  - *Upstream CRDs plus a first-party "gap" controller for what they cannot express.* Two
    controllers rendering onto one device is a second translation path by this specification's own
    definition (FR-060), and ownership of a given device path would be decided by deployment order.
  - *Carrying access lists as annotations on the upstream object.* An annotation is an unvalidated
    string; the whole point of a structural schema is that the dry-run gate means something.
  - *Forking the upstream fabric project.* A fork of a dormant tree is a first-party codebase
    wearing someone else's API group — exactly what FR-098 forbids, with the maintenance cost of
    both.
  - *A separate `AccessList` CRD.* It breaks the one-object-per-service shape the submission
    transaction's convergence watch depends on, and makes an access list referenceable by services
    that do not own it.
  - *A new `Fabric`, `Tenant`, `VRF` and `Attachment` CRD family.* Still rejected: `Fabric` plus
    `Network` is the smallest pair that covers design and service intent, and more Kinds would
    re-create the ambiguous ownership this decision set out to avoid.
- **Revised by**: RD-03.

### D-05: The device-configuration layer is the only device transaction layer

- **Decision**: reuse the device-configuration layer (SDC) and only it. Concretely: the
  `inv.sdcio.dev/v1alpha1` group supplies `Schema`, `TargetConnectionProfile`,
  `TargetSyncProfile`, `DiscoveryRule` and the discovery-generated `Target`; the
  `config.sdcio.dev/v1alpha1` group supplies `Config`, `ConfigSet`, `RunningConfig`, `Deviation`
  and `ConfigBlame`. Prefer one `Config` per (source object, device); use `ConfigSet` only for
  genuinely identical label-selected snippets. A `Config` binds its target by the
  `config.sdcio.dev/targetName` and `config.sdcio.dev/targetNamespace` labels and is named
  deterministically `<service>.<node>` — with **no dot permitted inside `<service>`**, because the
  layer parses the node name as the text after the last dot.
- **Priority bands**: `10` for the fabric/underlay `Config`, `20` for service `Config`s. **Two
  `Config`s that could touch the same device leaf MUST NOT share a priority**: that overlap is a
  conflict refused at validation, not an ordering left to the layer, because the layer's winner
  between equal priorities is undefined (FR-015).
- **Deviation policy**: `lifecycle.deletionPolicy: delete`; every `Config` the provider generates
  states `revertive: true` explicitly, so drift on a platform-owned path is restored. The policy is
  never inherited — from the lab or from the layer's own `REVERTIVE` default — and the set of
  values is closed at one member, so what a production deployment selects is the same `revertive`,
  selected by it (FR-015, AD-13, AD-17, AD-34). An `OVERRULED` deviation on a platform-owned path
  is a terminal error, not a state to reconcile around.
- **What "dry-run" means here**, stated because the phrase covers two different mechanisms: (1)
  Kubernetes **server-side dry-run** of the first-party `Network` against its structural schema and
  admission policy — which is meaningful precisely because the CRD now has a real schema (D-04);
  and (2) the device-configuration layer's own **schema validation of the rendered device config**,
  offline in CI against the pinned schema and again inside the layer before any gNMI Set. The
  Kubernetes API server cannot validate the opaque configuration payload a `Config` carries, and
  this specification never presents it as though it could.
- **Rationale**: the layer already provides schema management, declarative configuration, target
  discovery, validation, intent priority, transactions, running and intended state, configuration
  blame and drift handling over gNMI. Reimplementing these would add risk.
- **Transaction isolation**: a failed device transaction fails **its own** transaction and rolls
  back; it does not poison later commits, and no requirement may assume otherwise.
- **Alternative rejected**: direct SSH/CLI, or direct gNMI from an agent. It has no durable
  Kubernetes desired state, weaker validation and unclear field ownership. **This rejection is the
  origin of the entire safety boundary** (D-33, FR-075) and is honoured rather than overturned by
  the intent tier: the tier's output is a Kubernetes resource, it is dry-run-validated before
  submission, and it writes only into its own namespace with the control plane retaining ownership
  of everything below.
- **Alternative rejected**: a host-side executor beside the layer as an escape hatch. There is no
  such component and no requirement admits one (RD-02, FR-007).
- **Revised by**: RD-02.

### D-06: One first-party provider renders every device path

- **Decision**: build a single provider — one controller binary with a `Fabric` reconciler and a
  `Network` reconciler — that watches the first-party intent objects and renders deterministic
  device configuration resources: one per node for the fabric (priority 10), one per
  (service, node) for each service (priority 20). It is the **only** renderer of any device path —
  interfaces, `system0`, underlay BGP, the EVPN overlay and routing policy, the VXLAN
  tunnel-interface, bridged and routed network instances, integrated routing, the anycast gateway
  and access lists alike (FR-014).
- **Rationale**: **this was named as the material integration gap, and the retarget made it
  deeper, not shallower.** The merge expected the gap to invert on a platform the upstream project
  already ships a provider for — SR Linux is that platform, and the provider exists. It is
  nonetheless unusable: it is dormant, it targets a device release two years old, it does not
  compile against the current device-configuration layer, and it renders only what its upstream
  intent object can express, which excludes access lists, anycast gateways, local bridge domains
  and explicit route targets ([evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md)
  §2). Its native SR Linux JSON templates remain a useful **reference design** for the render and
  are cited as one; nothing resolves from it at run time.
- **Path policy**: **native-first.** Every rendered path is the device's own `srl_nokia` YANG
  unless the path register records a justified exception, because the device's own deviation files
  mark the standard model's EVPN and VXLAN coverage not-supported and the pinned schema is built
  from native models only (D-09, RD-08). The provider maps interfaces, loopbacks, routed and
  bridged instances, VLANs, L2 and L3 VNIs, the VXLAN overlay, underlay BGP, BGP EVPN and route
  targets into a schema pinned to the exact image.
- **API policy**: the provider adds no CRD of its own. Operators submit the first-party `Network`;
  the device configuration resource remains the transaction object; the provider's own metadata —
  source identity, generation, render hash, compatibility set and mapping version — is stamped on
  the `Config` it generates and never on the `Network` (FR-101).
- **Alternative rejected**: a second orchestration API. It would obscure which controller owns
  identifiers and device state.
- **Alternative rejected**: adopting the upstream provider, or a fork of it, as the renderer. See
  D-04's rejected alternatives; the deciding fact is that it cannot express four of the constructs
  this specification is for.
- **Revised by**: RD-03, RD-08.

### D-07: Direct reconciliation first; review workflows later

- **Decision**: apply intent directly through the first-party provider and the
  device-configuration layer. Add a Git-based rendered-config review flow, or a workspace and
  rollout flow, only after the lab is reliable end to end.
- **Rationale**: a second approval pipeline would complicate the first working slice. The
  device-configuration layer already documents Git-based rendered-config review as an option, so it
  remains the preferred production enhancement rather than a custom approval service.
- **Alternative rejected**: building the review pipeline first. The intent tier's two confirmation
  gates already provide the human checkpoint this lab needs.

### D-08: *Retired — a capability-gated SRv6 VPN service*

*Retired by the SR Linux retarget (RD-04) — no licence-free SR Linux container type can originate
or terminate an SRv6 service, and no release models explicit segment lists, steering policy or
per-SID counters, so the decision's capture-proven acceptance is unsatisfiable on any pinnable
profile.*
*Carried to a future feature (working title "005 — SRv6 services"), which this specification does
not create; the evidence is in [evidence/04-srv6.md](./evidence/04-srv6.md).*

### D-09: The path register is native-first, and it covers the access-list paths like any other

- **Decision**: the path register records **every** path the platform renders and every path the
  collector subscribes to, with the native `srl_nokia` model as the **default** and an entry
  required only where a standard-model exception is justified — today there are none. The
  access-list filter, entry and interface-binding paths are register entries exactly like the
  network-instance, subinterface and tunnel-interface paths, and the render package's access-list
  functions are what the CI guard exercises. For a subscribed path the register also carries the
  derived metric name, its labels and its stream mode (FR-017, FR-089).
- **Rationale**: the register is the CI-checked statement of which device paths this system writes
  and under which model, and leaving a construct out of it would let the guard pass while covering
  nothing. Its default is inverted from the merge's because the evidence inverted: the device's own
  deviation files mark the standard model's EVPN and VXLAN coverage not-supported, and the pinned
  device schema is assembled from native models only, so "prefer the standard model" would describe
  a preference the platform can never exercise
  ([evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md) §8).
- **An access list *is* a device-configuration object now — the merge's "no configuration object is
  created for an access list" is reversed.** That sentence was true only of a southbound that no
  longer exists: the access list was excluded from the transaction layer to keep it off a
  whole-config path that could poison a node (D-12). With one provider, one transaction layer and
  one path register, the access list renders into the same `Config` as the service that owns it,
  and excluding it would be the second render path the one-translator rule forbids — the exact
  inverse of the reason it was once excluded.
- **Alternative rejected**: rendering access lists through a second component "as well". Two
  renders of one construct is the drift the one-translator rule exists to prevent.
- **Alternative rejected**: a standard-model-first default with native as the exception. It
  inverts the evidence, and every EVPN and VXLAN path would immediately be an exception.
- **Revised by**: RD-02, RD-08.

---

## 3. Construct vocabulary and semantics

### D-10: The construct set is closed at four, and the legacy names are input aliases only

- **Decision**: `vlan`, `mac-vrf`, `ip-vrf`, `acl` are the only types an operator can ask for. The
  retired service-provider names remain *accepted spellings on input*, folded to a construct by
  `Canonicalize()` before any validator or translator sees them, and recorded separately as source
  provenance. Symmetric IRB is not a fifth type: it is a `mac-vrf` carrying an anycast gateway.
- **Rationale**: the migration translator's inputs are brownfield service definitions; refusing to
  read their own vocabulary would defeat the feature it was built for. Folding on entry is what
  makes one-vocabulary-everywhere achievable — one vocabulary in the validator, the rendered
  object, the annotations, the status and the audit trail — without keeping a second code path
  alive.
- **Alternatives rejected**:
  - *Reject legacy names outright.* Breaks the brownfield story for no gain: the names never reach
    an operator-visible surface anyway once folded.
  - *Keep both vocabularies live end to end.* Two type switches in the validator, two in the
    translator, two in the renderer — exactly the drift the single-vocabulary rule prevents.
  - *Map the point-to-point legacy name to a distinct construct.* Attachment count is a property,
    not a type; its exactly-two rule survives as a source-scoped constraint (D-19), not a
    construct.
- **Outcome of the retarget**: the anticipated case arrived. SR Linux names its bridged and routed
  network-instance types `mac-vrf` and `ip-vrf`, so for two of the four constructs the vocabulary
  is no longer a translation layer but a direct quotation of the device. That alignment is now a
  requirement asserted in CI against the pinned model (FR-099), not a coincidence to be preserved
  by convention; `vlan` and `acl` remain operator vocabulary and are documented with the device
  objects they render.
- **Revised by**: RD-06.

### D-11: A local `vlan` is its own list, not a bridge domain without an L2VNI

- **Decision**: the service intent object carries `spec.vlans[]` (`{name, vlan}`) as a sibling of
  `bridgeDomains` and `routers`. The provider renders it as a bridged network instance with the
  attachment subinterfaces that belong to it and nothing else — concretely, a `mac-vrf`
  network-instance **with no `vxlan-interface`, no `bgp-evpn` and no `bgp-vpn`** — so no tunnel,
  no overlay identifier and no EVPN block is emitted.
- **Rationale**: the alternative encodes "this is a different service" as "this field is missing",
  which is the exact defect that once made every IRB silently render as a bridged service — the
  routed half disappeared with no error. **On SR Linux that hazard is sharper, not softer**: a
  local `vlan` and a `mac-vrf` render to the *same device instance type*, `mac-vrf`, and differ
  only by the presence of the overlay blocks. If the construct were "a bridge domain whose L2VNI is
  absent", then the construct, the render and the device would all express the difference as an
  absence, and a dropped field at any layer would be indistinguishable from an operator asking for
  a local VLAN. A separate list makes the construct explicit at every layer, and lets the L2 render
  keep its "L2VNI must be non-zero" guard as a hard error rather than a branch.
- **Cost accepted**: the attachment dispatch must consult both maps; an attachment whose VLAN
  matches neither reports *both* the declared bridge domains and the declared local VLANs, so the
  message stays useful.
- **Alternatives rejected**:
  - *A bridge domain with a zero L2VNI.* See above.
  - *A separate local-VLAN CRD.* It breaks the one-object-per-service shape the deployment
    transaction's convergence watch depends on.
- **Revised by**: RD-06.

---

## 4. Access lists

### D-12: *Retired — access-list rows are raw-store writes, never whole-config writes*

*Retired by the SR Linux retarget (RD-02) — the decision was entirely an argument about a
configuration store, a whole-config patch path and a failure mode that poisoned subsequent writes.
None of those exists here: there is one southbound, one transaction layer, and a rejected
transaction rolls back without affecting the next one.*
*The access-list render is now an ordinary part of the same device configuration resource as the
service that owns it (D-09, D-13); see [evidence/03-acl.md](./evidence/03-acl.md) §8.*

### D-13: One filter per service, stage and address family, with a derived device name

- **Decision**: a service's access list renders as exactly one `acl-filter` per **(service, stage,
  address family)**, named deterministically `acl-<serviceId>-<ingress|egress>`. An IPv4 and an
  IPv6 list on the same service and stage are two filters, because the filter's identity on the
  device is the **pair** `(name, type)` — not the name alone — and both may coexist. The operator's
  rule names are carried in each entry's `description`; the identity of an entry is its
  sequence-id (D-15).
- **Rationale**: the device constrains a filter name to its own string type, and generated service
  identifiers do not satisfy that by construction, so the name is produced by a sanitiser rather
  than taken from the operator — this project has already been bitten once by handing a device a
  name its schema rejects. Deriving deterministically means apply, verify and rollback all agree on
  the name without storing it. Keying on the pair rather than the name is what lets one service
  filter both address families on one attachment without a name collision
  ([evidence/03-acl.md](./evidence/03-acl.md) §1, §2).
- **Reserved names**: `system` and `capture` are the device's own filter names and are **refused**,
  by name, before anything is created (FR-040). A derivation that produced one would be a
  platform defect, but an operator-supplied label that sanitises onto one is an ordinary refusal.
- **Consequence**: the filter is per-service, so two services filtering one physical port produce
  two filters — which is how the device expresses two filters on one port, provided they are on
  different subinterfaces or different address families (D-14) — and a rollback deletes only its
  own filter. Nothing another service owns is ever touched.
- **Alternative rejected**: using the operator's label directly as the device object name. It
  produces names the device refuses, discovered at apply time rather than at validation time.
- **Alternative rejected**: one filter per service carrying both address families. The device's
  filter type is part of its key and each filter is single-family; there is no object to put them
  both in.
- **Revised by**: RD-05.

### D-14: The binding conflict is a pre-flight refusal plus a non-destructive renderer

- **Decision**: two mechanisms, deliberately.
  1. **Refuse before submission.** The deployer's pre-flight lists the service intent objects in
     the intent namespace, reads their access lists and attachments, and refuses a request that
     would bind a second filter to an attachment subinterface already carrying one *in the same
     direction and for the same address family*, naming the service that holds it. This runs before
     the first apply.
  2. **Never rewrite another filter's binding.** The renderer writes only its own filter and its
     own binding; it never reads-modifies-writes another service's binding. A rollback deletes its
     own filter and entries and nothing else.
- **The unit of exclusivity is (node, interface, subinterface, direction, address family)** — not
  the physical port. Two services MAY filter the same physical port at the same stage when they own
  different subinterfaces, and an IPv4 and an IPv6 filter on one subinterface and direction do not
  conflict at all.
- **Rationale**: the rationale changes from "the device gives two bindings no defined evaluation
  order" to something stronger. On the emulated 7220 IXR platform the device accepts **one filter
  of a given type per subinterface per direction**, so a second binding is not ambiguous — it is
  unsupported. Refusing and naming the incumbent is therefore a necessity rather than a policy, and
  the refusal message says so ([evidence/03-acl.md](./evidence/03-acl.md) §5, §6). The renderer
  guard is the belt to that pre-flight's braces: the pre-flight sees the cluster, the renderer sees
  one object, and only the transaction layer touches the device.
- **Deletion ordering**: withdrawal removes the **binding first, then the filter**, and only then
  may the subinterface's owner be removed. A service whose attachment subinterface still carries
  another service's standalone access list cannot finalize until that list is withdrawn, and the
  finalizer surfaces the holder by name.
- **Alternatives rejected**:
  - *Merge both services' rules into one filter.* One service's rollback would then have to
    surgically edit another's live filter.
  - *Let the second binding win.* Exactly the silent displacement the requirement forbids — and on
    this platform it would not even be a displacement, it would be a rejected transaction.
  - *Treat the physical port as the unit of exclusivity.* It would refuse two services that the
    device is perfectly able to carry on two subinterfaces, and it would still not describe the
    address-family case correctly.
- **Gap closed**: what the pre-flight sees while a conflicting service is mid-finalization is
  settled by FR-043 — an object with a deletion timestamp **still holds its bindings until it is
  gone**, and the refusal says the holder is being removed rather than reporting the attachment as
  free. See [spec.md](./spec.md) §Gaps closed by the retarget, GAP-4.
- **Revised by**: RD-05, RD-14.

### D-15: The accepted match set is the pinned release's, and what it cannot express is refused by name

- **Decision**: the accepted access-list vocabulary is bounded by what the pinned release's ACL
  model can express, and the validator refuses the rest **by name** rather than rendering something
  the device will not honour. The model is the ≥24.3 form only —
  `/acl/acl-filter[name][type]` with `entry[sequence-id]`, bound through
  `/acl/interface[interface-id]` with an `interface-ref` and an `input` or `output`
  `acl-filter[name][type]` ([evidence/03-acl.md](./evidence/03-acl.md) §0, §3, §4, §5).

  | Operator field | Device field | Accepted values |
  |---|---|---|
  | `stage` | the direction under the interface binding | ingress → `input`, egress → `output` (folded from in/inbound and out/outbound); egress only where the pinned profile qualified it, otherwise refused by name (FR-097) |
  | `type` | the `acl-filter` key `type` | `ipv4` and `ipv6` only; the operator spellings `l3`, `l3v6`, `ip` fold onto them |
  | rule `priority` | entry `sequence-id` | **1–65534**, distinct per filter, rendered **unchanged** — evaluated in ascending order, first match wins; **65535 is reserved** for the default action |
  | rule `action` | entry action | `accept` (permit) and `drop` (deny); logging and mirroring are out of scope |
  | rule `protocol` | IPv4 `protocol` / IPv6 `next-header` | any IP protocol number 0–255 or a known name, **including ICMPv6 (58)** |
  | rule `sourcePrefix` / `destinationPrefix` | source / destination IP prefix | an IPv4 prefix on an `ipv4` filter, an IPv6 prefix on an `ipv6` filter |
  | rule `sourcePort` / `destinationPort` | L4 source / destination port | a port, or an inclusive range; **only when the protocol is TCP or UDP** |
  | `defaultAction` | a terminal match-all entry at the reserved sequence-id | rendered explicitly at `65535`; an operator rule claiming that sequence-id is refused, stating that 1–65534 is usable |

- **The ordering direction is the device's, and it is the reverse of the predecessor's.** Entries
  are evaluated in **ascending** sequence-id with the first match winning, so priority 10 is
  evaluated before priority 20. The mapping is the **identity** — what the operator wrote is the
  number the device shows. Because this inverts a habit, FR-039 requires the evaluation order and
  the usable range to be stated to the operator at the first confirmation rather than left to be
  discovered from a read-back.
- **The platform's own default for unmatched traffic is ACCEPT.** A declared `defaultAction` is
  therefore not decoration: it is the only thing that makes "deny everything else" true, and it is
  rendered as the reserved terminal entry. When none is declared, the confirmation **must** state
  that unmatched traffic is accepted by the platform default, and the platform must not describe
  such a list as restrictive beyond its explicit rules (FR-041).
- **Two corrections to the inherited match set**, both recorded as corrections rather than new
  design:
  1. **A Layer 2 (MAC) list is still refused — for a different reason.** The device does model a
     `mac` filter type; the refusal is no longer "the device has no such type" but "the construct
     is defined over address families", and it is stated that way (FR-038). The supporting fact is
     that a MAC filter and an IP filter are mutually exclusive on one subinterface and direction,
     so admitting `mac` would make D-14's exclusivity rule depend on a type the vocabulary does not
     otherwise use ([evidence/03-acl.md](./evidence/03-acl.md) §2).
  2. **The ICMPv6 refusal is reversed.** The previous platform's protocol set did not contain 58,
     so an ICMPv6 rule could be written and would never match. SR Linux matches on the IPv6
     `next-header` across the full 0–255 range, so 58 is matchable like any other value and
     refusing it would refuse a rule the device can honour. It is accepted, and FR-040 says so
     explicitly ([evidence/03-acl.md](./evidence/03-acl.md) §4).
- **Out of scope and refused by name**: TCP flags, DSCP, TTL and hop-limit, fragment matching, ICMP
  type and code, logging, mirroring, rate limiting, control-plane and system filters, and
  policy-based forwarding. The device models several of these; the refusal says "out of scope", not
  "unsupported", because the two are different claims.
- **Rationale**: the validator already refuses a rule that can never match. A rule the *filter* can
  never carry is the same defect one level up. Anything outside this set would otherwise be written
  into the running datastore, read back successfully by a naive check, and program nothing.
- **Alternative rejected**: accepting a wider vocabulary and letting the device reject it. Where
  the device rejects it, the failure arrives at apply time instead of at validation time; where it
  accepts a row and programs nothing, the outcome is worse still.
- **Revised by**: RD-05.

### D-16: An access list is verified two-sided — running datastore and device state

- **Decision**: the read-back is **two-sided**, and every path on both sides is **keyed to this
  filter**. Written side: the device configuration resource is applied with no deviation, and the
  filter, its entries and its binding are present in the device's **running** datastore with the
  intended type, sequence-ids, actions and match fields. Applied side: the device's **state**
  datastore for *this* filter — the binding present under the intended subinterface and direction,
  every entry's programmed/TCAM state non-zero **for that direction**, and per-entry `statistics`
  readable, which requires `statistics-per-entry` to be set on the filter. A service failing either
  side is **not** Ready ([evidence/03-acl.md](./evidence/03-acl.md) §7).
- **Rationale**: every other construct on this fabric asserts operational evidence, not only the
  rows the platform wrote — the tunnel endpoint's own state, the EVPN routes in the route table,
  the instance's operational state (D-09, RD-13, FR-100). Reading back only the datastore you wrote
  to proves the write landed, not that the device programmed it, and holding the access list to a
  weaker bar than the other constructs would be exactly the overclaim this project has recorded
  against itself before: a successful submission reported for a service the fabric never built.
- **The carried defect is closed by construction, not by vigilance.** The predecessor's
  applied-side checks were **switch-wide**: one matched any filter at the stage with a bind point,
  and the other counted all entries against this service's rule count, so a one-rule list passed on
  an empty fabric. Here there is no switch-wide read to write by accident — the applied-side paths
  are keyed by filter name, filter type and entry sequence-id, and a count across the device is not
  expressible as evidence for a service. FR-042 states the keying as the requirement, and NFR-013
  requires each check to have been shown to fail on a stock fabric before its pass counts.
- **The hazard that replaces it**: a stock SR Linux node is **not** empty of filters — it carries
  its own control-plane (`cpm`) filter entries from first boot. Any check that counts filters or
  entries device-wide passes on an untouched fabric for that reason alone, which is precisely the
  negative control NFR-013 demands and the documented reason the keyed form is mandatory rather
  than preferred.
- **Enforcement is demonstrable on this platform, and is demonstrated — in acceptance only.** The
  containerized dataplane enforces filters, so a permit/deny probe between the client containers is
  possible, and SC-041 requires exactly one such probe per qualified direction, evidenced by the
  per-entry matched-packet counters of the entries the platform wrote. **Readiness never depends on
  traffic** (FR-042): the probe proves enforcement, the keyed read-back proves programming, and the
  two are deliberately not the same check.
- **Alternatives rejected**:
  - *Running-datastore read-back alone.* Weaker than the bar every other construct is held to.
  - *A device-wide filter or entry count as applied-side evidence.* It passes on a stock fabric.
  - *Silently falling back to configuration-only where the device exposes no applied state.* The
    gap is reported, not absorbed — an unverified property must never read as a verified one.
  - *Traffic assertions through the client containers as the readiness check.* **Partially
    adopted, and the scope of the adoption is the point.** The merge rejected them outright as a
    new class of device interaction the previous dataplane could not support anyway. They are now
    in scope for **acceptance** (SC-041) because the dataplane does enforce; they remain rejected
    for **readiness**, because readiness that depends on traffic would make a service's Ready
    condition a function of whether a probe container happened to be running.
- **Revised by**: RD-05, RD-13.

---

## 5. Migration compatibility and provenance

### D-17: Translate services, not device CLI

- **Decision**: import normalized service intent and map only explicit semantic equivalents. Never
  translate raw device commands or imply universal feature parity. The alias catalogue, expressed
  in the construct vocabulary with the retired names shown as the migration aliases they are:

  | Previous logical role or service (migration alias) | Construct or fabric outcome | Status |
  |---|---|---|
  | Core transit router | Spine, IP underlay only | Supported |
  | Provider-edge router | Leaf or border leaf, VTEP | Supported |
  | Customer attachment circuit | Leaf port or subinterface plus a VLAN attachment | Supported |
  | MPLS core / label transport | Routed Clos underlay plus BGP | Architectural replacement |
  | VPNv4/VPNv6 control plane | BGP EVPN | Architectural replacement |
  | Multipoint L2VPN alias | `mac-vrf` — bridge domain, L2VNI, EVPN Type 2/3 | Supported |
  | Routed VPN alias | `ip-vrf` — routed instance, L3VNI, route targets, Type 5 | Supported after the capability gate |
  | Point-to-point L2 alias | `mac-vrf` with exactly two attachments | Limited equivalence, opt-in |
  | Integrated L2/L3 alias | `mac-vrf` with an anycast gateway (symmetric IRB) | Supported after the capability gate |
  | Traffic-engineering and segment-policy constructs | No automatic mapping | Rejected |
  | Pseudowire OAM / control word | No automatic mapping | Rejected |
  | Multicast VPN, complex QoS/OAM, service chaining | No automatic mapping | Rejected or deferred |

- **Rationale**: the device supports L2 and L3 EVPN concepts including the relevant route types,
  but image and platform coverage and scale vary. A rejected, explainable migration is safer than a
  superficially successful lossy translation.
- **Alternative rejected**: best-effort mapping with warnings. Warning-only semantic loss is
  prohibited; the whole request is refused instead.

### D-18: Only an optional migration-audit CRD

- **Decision**: normal operation needs no new operator-facing CRD. Use labels and annotations on
  the generated service intent object for provenance. Add the
  `MigrationPlan.agentic-netops.io/v1alpha1` CRD only if the implementation needs durable
  translation findings, approval, cutover and verification status.
- **Rationale**: service conversion is a one-time boundary workflow not covered by the service
  intent API, but it must not become a competing device orchestration API.
- **Alternative rejected**: a generic service-intent CRD. It would overlap the `Network` Kind,
  obscure validation, and make it unclear which controller owns identifiers and device state.
- **Gap closed**: what a `MigrationPlan` records now that its target type is a construct rather
  than the source name it was written for is settled by FR-046 and FR-048 — the annotations on the
  `Network` are the single provenance record, and a `MigrationPlan` references them and records the
  construct alongside the source vocabulary rather than restating either. See [spec.md](./spec.md)
  §Gaps closed by the retarget, GAP-2.
- **Revised by**: RD-14.

### D-19: Source-scoped constraints stay scoped to the source vocabulary

- **Decision**: the two rules that belong to the point-to-point legacy alias rather than to
  `mac-vrf` — exactly two endpoints, and the limited-equivalence opt-in — apply when and only when
  the recorded source type says the request arrived that way. A request naming `mac-vrf` directly
  claims no pseudowire and is subject to neither. Provenance is carried on the object as
  annotations, and the source type is excluded from the canonical hash so the same service hashes
  identically in either vocabulary.
- **Rationale**: this is what makes brownfield acceptance and construct semantics compatible.
  Imposing the two-endpoint rule on `mac-vrf` would break multipoint; dropping it for legacy inputs
  would silently relax a constraint a brownfield source relies on.
- **Defects to avoid, recorded rather than found again**: in the predecessor the emitted-annotation
  key order omitted the source-type key, so the provenance annotation was computed and then dropped
  before it reached the object; and the strict parser never called `Canonicalize()`, so every legacy
  input failed validation outright. Both are implementation obligations here, not new decisions.
- **Alternative rejected**: applying every source constraint to every request. It would make the
  vocabulary change a functional regression.

---

## 6. Intent tier: conversation, interpretation and assignment

### D-20: Reproduce the tier's stack at its pinned versions

- **Decision**: carry the agent SDK, the agent-to-agent SDK, the model gateway library, the
  observability SDK, the identity SDK, the graph framework and its supervisor package, the data
  validation library, the web framework and the transport gateway image forward unchanged, on
  Python 3.13.
- **Rationale**: the pins are the fidelity contract. The model gateway library is also the
  mechanism that satisfies configurable provider choice — provider selection is by model-name
  prefix alone, so switching providers is a Secret change, not a code change.
- **Incompatibilities found**: none blocking. The base image runs unchanged as a container image;
  nothing in the list requires a host daemon or a Compose-only feature. Every tier pin is recorded
  in the lock file under a tier block **by digest, not by tag**, to match the pinning discipline
  NFR-003 now states without exception.
- **Alternative rejected**: upgrading the agent SDKs to current releases. The supervisor's
  transport helpers hard-require the pinned transport and the pinned client shape; an upgrade would
  change the discovery and client-construction surface for no requirement.

### D-21: A durable checkpointer on a volume, not an in-memory one

- **Decision**: replace the in-memory checkpointer with a file-backed one writing to a persistent
  volume mounted in the supervisor pod. The supervisor runs one replica with a recreate strategy.
- **Rationale**: the edge case "the supervisor restarts mid-request, with an assignment confirmed
  but not yet submitted" requires thread state to outlive the pod, and per-thread refinement across
  messages requires it too. A file-backed store on a volume is the smallest thing that does it, and
  the lab-scale concurrency assumption means the single-writer limit is not a real constraint here.
- **Alternatives rejected**:
  - *A multi-writer database checkpointer.* The right answer for multi-replica supervisors, and
    the recorded revisit trigger if concurrency ever exceeds one writer — but it adds a stateful
    workload, a volume, a credential and a readiness dependency to a lab scoped to one operator.
  - *Keeping the in-memory checkpointer and documenting the loss.* It fails the stated edge case
    outright, and release-on-decline becomes unenforceable across a restart, because the claim
    would outlive the state that knows about it.

### D-22: Identifiers come from claims the tier creates and deletes

- **Decision**: the allocator obtains every identifier the tier is responsible for by creating a
  claim referencing the existing index, waiting for the claim to report its allocated value in its
  status, and using that value. Declining at either confirmation point deletes the claim, releasing
  the identifier.
- **Which groups are actually used**: the tier claims from **`vlan.be.kuid.dev`** (service VLANs)
  and **`genid.be.kuid.dev`** (L2VNI and L3VNI) and from nothing else. The fabric's IP prefixes and
  ASNs come from **`ipam.be.kuid.dev`** and **`as.be.kuid.dev`**, claimed by the provider's
  `Fabric` reconciler rather than by the tier, because they belong to the fabric design and not to
  a service request. These are aggregated APIs served by the allocation authority, not CRDs.
- **Namespace**: claims are namespaced and their index reference carries no namespace field, so a
  claim must live in the same namespace as its index. The tier therefore receives a **narrow Role
  in the allocation namespace limited to claims** — get, list, watch, create and delete, and
  deliberately **no update or patch**, so it can claim and release but cannot retarget an existing
  claim. It receives no access to indices, Secrets, or any other resource there.
- **Rationale**: the allocation authority is the only allocator and local generation is forbidden.
  "Declining leaves zero identifiers claimed" becomes a label-selector diff rather than an
  argument.
- **Alternative rejected**: mirroring the indices into the tier namespace so claims stay local.
  That creates a second allocation authority with its own drift — exactly what the single-authority
  rule forbids.
- **Alternative rejected**: a claim group for route targets. Route targets are derived, not
  allocated (D-25, RD-09).
- **Revised by**: RD-03, RD-09.

### D-23: Correct or drop the defects the fidelity analysis found — do not port them

- **Decision**: four findings are corrected rather than carried.
  1. An orphaned superseded allocator module with zero importers is not carried forward in any
     form.
  2. Every credential — the analytics store, the dashboards, the transport gateway password, the
     device credentials and the model-provider key — comes from a Secret generated in-cluster by
     the existing generator pattern. No credential literal appears in any manifest, and CI enforces
     it.
  3. A misspelled, orphaned exceptions module is carried forward with the spelling corrected and
     **actually wired in**: its authentication error becomes the raised type for transport
     authentication failures, which is the error path the subject declared and never used.
  4. Tests exercising a removed browser interface and a removed approval surface are not carried
     forward; the confirmation flows they meant to cover are re-tested against the live routing.
- **Rationale**: a faithful restoration is a restoration of the working system, not of its bugs.
- **Alternative rejected**: porting the tree verbatim. It would re-introduce known defects and
  known-dead code with no requirement asking for either.

### D-24: The workflow status vocabulary maps onto the existing enum

> **Amended by AD-63** (seventh pass, 2026-09-21): the table's meanings are a creation's.
> `CONFIGURED` ("every object accepted by the API server") and `VERIFIED` ("every object reported
> Ready") cannot apply to a **removal**, which moves `APPROVED` → `PROVISIONING` and ends
> `COMPLETED` once the object is observed gone — or stays at `PROVISIONING`, reported as in
> progress, when it is still present at the convergence timeout. No member is added.

- **Decision**: the required closed set maps onto the existing provisioning-status enum, carried
  forward unchanged:

  | Required status | Enum member | Meaning |
  |---|---|---|
  | received | `RECEIVED_REQUEST` | request accepted, thread opened |
  | — | `VALIDATED` | interpretation passed its schema |
  | interpreted | `MAPPED` | interpretation returned, awaiting first confirmation |
  | assigned | `ALLOCATED` | normalized intent built, awaiting second confirmation |
  | approved | `APPROVED` | second confirmation recorded, nothing submitted yet |
  | submitting | `PROVISIONING` | dry-run passed, bundle applying |
  | — | `CONFIGURED` | every object accepted by the API server |
  | — | `VERIFIED` | every object reported Ready |
  | converged | `COMPLETED` | outcome reported to the operator |
  | failed | `FAILED` | terminal failure, with the responsible stage named |
  | — | `STATUS_UNKNOWN` | transport or state loss; **never a success** |

- **Rationale**: the requirement asks for a closed set covering at least seven states; the existing
  enum is a strict superset adding three useful intermediates. Reusing it keeps the lineage and
  avoids a parallel vocabulary.
- **Alternative rejected**: inventing a new status vocabulary. It would leave two enums to keep in
  agreement across the stream, the surface and the audit record.

### D-25: Claim profiles per construct, not new indices

> **Amended by AD-51** (operator decision, 2026-09-21): the `ip-vrf` row's VLAN cell no longer
> holds — no VLAN is ever allocated for an `ip-vrf` attachment; its VLAN is named or absent.

- **Decision**: the indices are unchanged. What is defined per construct is **which** indices it
  claims from, and that a construct may claim **nothing**:

  | Construct | VLAN index | Generic id index (L2VNI) | Generic id index (L3VNI) |
  |---|---|---|---|
  | `vlan` | claim unless the operator named a VLAN | — | — |
  | `mac-vrf` | claim unless the operator named a VLAN | claim | claim **only if** an anycast gateway is declared |
  | `ip-vrf` | claim per tagged attachment unless the operator named a VLAN | — | claim |
  | `acl` | — | — | — |

- **The route-target index is removed.** Route targets are not allocated at all: they are rendered
  explicitly as `target:<fabricASN>:<vni>`, a deterministic function of a fabric-wide constant and
  an already-claimed value (FR-012). Allocating them would have been allocation state for a value
  that is reconstructable, and it would have hidden the real hazard — that the device's
  *auto-derived* route target uses the per-leaf underlay ASN, so it differs per leaf and silently
  never matches. Route distinguishers are likewise not allocated and not rendered: the device
  derives one per instance, and `Network.spec.routers[].rd` no longer exists.
  *Revisit trigger*: asymmetric import/export, or deliberate inter-tenant leaking.
- **Rationale**: the served indices cover the identifier space all four constructs need. Adding an
  index for access lists would contradict "no overlay identifiers are allocated" and would give the
  `acl` construct a claim it can leak. The real gap was the opposite one: the predecessor's
  allocator claimed a VNI and a route target *unconditionally*, so a `vlan` stranded an L2VNI it
  never renders and an `acl` stranded both. Release-on-decline is correspondingly scoped: nothing
  claimed, nothing to release — and the release path must treat that as success, not as a
  missing-claims error.
- **Two consequences, not options**: a VLAN the operator named is not claimed, and two *different*
  requested VLANs on one service are a contradiction in the request and are refused rather than
  silently resolved.
- **The band constraint that replaces the routed-VLAN sub-band**: because the EVPN instance
  identifier is derived as `evi := vni`, **the VNI band MUST be a subset of the range the device's
  EVI can carry, 1–65535**. The merge's rule that an L3VNI may be claimed only from a sub-band with
  a derivable routed-instance VLAN is deleted: nothing about a routed instance on this platform
  derives a VLAN from the VNI. A VLAN the operator names outside the VLAN index's own usable range
  is refused with the range stated (FR-034).
- **Alternative rejected**: an index per construct. It multiplies allocation state for no
  identifier the constructs actually need.
- **Alternative rejected**: a route-target index. See above — a derived value with an allocator in
  front of it is drift waiting to happen.
- **Revised by**: RD-09.

### D-26: One construct per request, and one endpoint minimum

- **Decision**: the interpretation's endpoint floor drops from two to one, and the per-construct
  minimum moves to validation, where it already lives on the translator side: `vlan` ≥1, `ip-vrf`
  ≥1, `acl` ≥1, `mac-vrf` ≥2 — or ≥1 when it carries an anycast gateway. A request naming two
  constructs goes to the existing clarification path; one construct per exchange is unchanged.
- **Rationale**: three of the four constructs are legitimately single-attachment; a schema floor of
  two would make "give tenant acme an ip-vrf on leaf01 ethernet-1/1" unrepresentable *before* any
  validator could explain why. Keeping the per-construct minimum in one place avoids two
  disagreeing rules.
- **Alternative rejected**: a multi-construct transaction. It is out of scope and would need its
  own convergence and rollback semantics.

---

## 7. Intent tier: submission, convergence and inter-agent transport

### D-27: The transport port and variable name are the code's, not the documentation's

- **Decision**: the transport port is **46357** and the environment variable is the long form
  `TRANSPORT_SERVER_ENDPOINT`, paired with the default-transport selector. These names and this
  number are used in the Service, the NetworkPolicy, the probes, the manifests and the runbook,
  with no exceptions.
- **Rationale**: the gateway publishes that port, its data-plane server listens on it, and the
  configuration default uses the long variable name. The project README gives a different port
  under a short variable name; nothing listens on or dials that port and nothing reads that name.
- **Alternative rejected**: following the README. It would leave every agent unable to join the
  transport mesh — exactly the risk the fidelity analysis names.

### D-28: Mutual TLS on the transport gateway, with a named fallback and a stated production delta

- **Decision**: run the gateway with TLS enabled and client-certificate verification, using a CA
  and per-agent certificates generated in-cluster by a job reusing the existing generator pattern.
  The gateway password comes from a Secret, never a literal. A NetworkPolicy admits the transport
  port only from the tier's agent pods.
- **Rationale**: the requirement is an authenticated transport that refuses unauthenticated worker
  registration. The subject's gateway is the opposite — insecure TLS on both its data and control
  planes — an unencrypted lab gateway that cannot satisfy the requirement as-is.
- **Qualification gate**: the exact TLS key names the pinned image accepts under its server TLS
  block are confirmed against the image before the transport is deployed, because the subject's
  configuration only ever exercised the insecure branch and therefore proves nothing about the
  cert-bearing one.
- **Fallback, if the pinned image does not expose client-CA verification**: keep TLS server-side
  only and carry worker authentication on the gateway password plus the NetworkPolicy pod
  selector. Recorded as an **accepted risk**, not a silent downgrade, with the production delta
  named: a production deployment must terminate the transport behind a mesh providing mutual TLS
  and workload identity, because a shared password is not per-worker authentication and a network
  policy is not an authenticator.
- **Alternative rejected**: keeping insecure TLS because it is a lab. The requirement belongs to
  this platform, not to production.

### D-29: Payloads keep the marker format but are validated as structured data

- **Decision**: preserve the two-stage handoff and its wire markers — a summary plus an HTML
  comment carrying the JSON — **and** carry the same object as a structured data part alongside the
  text part in the agent-to-agent message. The receiver reads the data part when present and falls
  back to parsing the marker; either way the object is validated against its model **before it is
  used**, and a validation failure is a terminal stage failure that submits nothing.
- **Rationale**: rejecting a malformed agent output before it reaches the cluster cannot be done by
  string-splitting an HTML comment out of model prose — a truncated or duplicated marker yields
  either a parse crash or a silently partial object. The pinned agent-to-agent SDK already models a
  part as text, file or data, so the structured channel needs no protocol change. Retaining the
  marker keeps the existing chat rendering path working unchanged.
- **Alternative rejected**: dropping the markers entirely. It would break wire compatibility with
  the chat rendering for no requirement, and the markers cost nothing once the authoritative copy
  is the data part.

### D-30: The Python tier reaches the Go translator through a loopback sidecar

- **Decision**: build a thin Go HTTP server wrapping the existing translator package and exposing a
  translate endpoint. Deploy it as a **sidecar container in the deployer pod**, bound to loopback,
  with no Service and no NetworkPolicy allowance. The allocator emits the normalized service-intent
  contract; the deployer hands that JSON to the sidecar and receives the `Network` manifest it then
  submits.
- **Rationale**: translation semantics stay in exactly one implementation, with no Python
  reimplementation. The translator CLI proves the library is pure and deterministic: it reads JSON,
  validates all-or-nothing, and writes YAML with no cluster interaction. Wrapping the same calls in
  an HTTP handler adds no semantics. Binding to loopback means the translator adds zero
  cluster-visible attack surface and the namespace policy stays deny-all for cross-pod traffic.
- **Alternatives rejected**:
  - *Subprocessing the translator CLI from Python.* Requires the Go binary inside the Python image,
    producing a mixed-provenance image and a second build path per release. Rejected on build
    reproducibility, not on correctness — the semantics would be identical.
  - *A cluster Service in front of the translator.* A new in-cluster network surface reachable by
    anything the policy admits, for a call that is always pod-local. Rejected as unnecessary
    exposure.
  - *A new controller consuming normalized JSON.* That is a control-plane component, and the tier
    is forbidden from adding one. Rejected as out of bounds.
- **Oracle**: the migration golden files are the equivalence oracle — the agent-produced normalized
  JSON is fed through the same sidecar and the emitted `spec:` must match byte for byte.

### D-31: The correlation identifier is the trace identifier, carried as a label

- **Decision**: the correlation identifier is the 32-hex W3C trace identifier of the request's root
  span. It is stamped on every submitted resource as a **label**, with the thread identifier, the
  principal and the submission time as annotations.
- **Rationale**: the same identifier must appear on the telemetry and on the resource, and the join
  must work without timestamp correlation. A label — not an annotation — is required, because only
  labels are selectable; a label selector on the correlation identifier is the reverse direction of
  the join. A 32-hex identifier is a valid label value, so no encoding is needed. The audit fields
  go in annotations because they are not query keys and the principal may contain characters a
  label value forbids.
- **Second use**: the same label is what makes the rollback set exact and enumerable — see D-32.
- **Schema check**: labels and annotations are object metadata. Stamping them changes no
  control-plane schema, controller or reconciliation contract, and the control plane already
  establishes the pattern with its own migration provenance.
- **Alternative rejected**: an annotation-only correlation identifier. It satisfies the stamping
  requirement but not the join, because annotations cannot be selected on.
- **Gap closed**: key ownership is settled by FR-101 — one owner per key, a fixed emission order,
  and the provider stamping its own metadata on the device configuration resources instead of on
  the `Network`, which leaves only two actors writing the object's metadata. See
  [spec.md](./spec.md) §Gaps closed by the retarget, GAP-3.
- **Revised by**: RD-14.

### D-32: Atomic submission is dry-run-then-apply, with label-selector rollback

- **Decision**: two phases. **Phase A**: server-side dry-run of every object in the bundle; if any
  object is rejected, nothing is applied and the request fails with the rejecting object named.
  **Phase B**: apply the bundle in deterministic order, every object carrying the correlation
  label; if any apply fails, delete every object bearing that label value and report the rolled-back
  set.
- **Rationale**: the Kubernetes API has no multi-object transaction, so atomicity has to be built.
  Server-side dry-run catches schema, admission and conflict failures before any mutation, which is
  where nearly all bundle failures live — and it catches more of them now that the `Network` has a
  structural schema with admission policy behind it rather than an open object (D-04, D-05).
  The correlation label makes the rollback set exact and enumerable rather than reconstructed from
  memory — which matters precisely when the supervisor restarted, since the label survives in the
  cluster when in-process state does not.
- **Alternative rejected**: applying optimistically and reconciling later. It leaves partial
  services on the fabric, which the atomicity requirement forbids and the audit reconciliation
  would catch.

---

## 8. Safety boundary

### D-33: The tier submits into its own namespace, not the control plane's

- **Decision**: the tier's submitted service intent objects land in the tier-owned namespace
  `agentic-netops-intent`. The deployer's Role grants write access to exactly one resource there —
  **`networks.fabric.agentic-netops.io`** (create, get, list, watch, update, patch, delete) plus
  Events — and it holds no rule at all in the namespace where the control plane's own resources
  live.
- **Rationale**: the requirement says "within its own namespace", and the denial must be provable
  by attempting it and observing it. With no rule in the control plane's namespace, an
  authorization check as the tier's identity returns `no` for every verb on control-plane-owned
  resources — a one-command proof rather than an argument. It also means an agent that somehow
  constructed a request targeting a control-plane resource is refused by the API server, satisfying
  "cannot express the action even if an agent tried".
- **One kind, not two**: the Role grants the service intent Kind and nothing else. The second
  writable kind the merge granted no longer exists (RD-04), which is how GAP-5 is closed — by
  narrowing the grant rather than by policing it.
- **Watch scope**: the provider watches `Network` cluster-wide so that tier-submitted objects in
  `agentic-netops-intent` converge. This is first-party configuration on a first-party controller,
  so it is set, not qualified — the merge's gate item here existed because the controllers were
  third-party and their watch scope was an assumption.
- **Alternative rejected**: submitting alongside the control plane's own resources. It reads as
  simpler, but it grants the tier write access in the namespace holding the control plane's desired
  state, and it makes the most important denial unprovable.
- **Revised by**: RD-03, RD-04.

---

## 9. Operator surface

### D-34: The browser transport is a newline-delimited JSON stream, not a WebSocket

- **Decision**: the operator surface is a streaming POST emitting newline-delimited JSON chunks. No
  WebSocket route is planned, implemented, probed or documented.
- **Rationale**: the supervisor declares five routes and no WebSocket, and the frontend calls the
  streaming POST. The README's WebSocket route describes a removed interface, and the two tests
  that drive it document that removed interface rather than the live one.
- **Consequence for live progress**: convergence progress reaches the browser on the same stream
  the request opened — the convergence watch emits a chunk per resource state change. No second
  channel is introduced.
- **Alternative rejected**: adding a WebSocket because the README mentions one. It would
  reintroduce a defect the analysis caught, and duplicate the streaming path that already works.

### D-35: The chat surface is the existing browser app, served as a cluster workload

- **Decision**: carry the existing frontend forward, built by the existing pattern and served as a
  Deployment plus Service, reached through a cluster port mapping rather than an ingress
  controller.
- **Rationale**: the operator-surface requirements describe exactly what the existing chat surface
  already renders — labelled per-stage steps with readable payloads, both confirmation points, and
  live progress off the stream. The API base-URL values become ConfigMap entries pointing at
  cluster service DNS names rather than localhost, which is the only substantive change; the build
  script already regenerates the runtime environment before build.
- **Alternative rejected**: a new UI. It discards a working surface that already matches the
  requirements, for no requirement.

---

## 10. Observability

### D-36: Device collector → telemetry pipeline → metrics store, with topology exposition

- **Decision**: instrument the platform controllers with OpenTelemetry metrics and traces and
  scrape the supported upstream metric endpoints. Use gNMIc as the **sole** device collector,
  export its metrics over OTLP to the OpenTelemetry Collector, expose normalized metrics to
  Prometheus, and query them from Grafana. Disable overlapping subscription-based metrics in the
  device-configuration layer for the same series. gNMIc's own `/metrics` endpoint is scraped as
  pipeline-health evidence, so every stage of the pipeline has evidence of its own (FR-089,
  SC-034, SC-037).
- **The pipeline is implementable as specified**: gNMIc carries a native OTLP output, verified
  present at the pinned **0.47.0**, so the single OTLP path needs no `prometheus`-output detour and
  no second exporter ([evidence/06-telemetry-visualization.md](./evidence/06-telemetry-visualization.md)
  §1.1, §1.2). The merge asserted this pipeline without having confirmed the output exists; it now
  rests on a read of the collector's own output set rather than on an assumption.
- **Rationale**: this meets the requested open stack while keeping storage responsibilities
  accurate. The OpenTelemetry Collector is a pipeline, not a durable telemetry database.
- **Path set**: the subscribed set is the device's **native** paths, registered in the path
  register with their derived metric name, labels and stream mode (D-09, FR-017): interface
  administrative and operational state, traffic rate and statistics; subinterface statistics; BGP
  neighbour session state and per-AFI/SAFI route counts including the EVPN family;
  network-instance operational state; EVPN instance state; VXLAN tunnel-endpoint state and
  counters; bridge-table MAC counts; route-table and tunnel-table summaries; per-entry access-list
  counters; and platform CPU, memory and application health. Subscriptions use `json_ietf` in the
  native origin and **`sample` mode by default**, with on-change used only where an acceptance
  check has shown the device supports it for that path.
- **Scope**: metrics and live troubleshooting traces. Durable log and trace storage requires an
  explicit later addition; it is not implied by the dashboards or the metrics store (FR-088).
- **Topology exposition**: topology assets, the topology panel resources and the collector's target
  list are generated from the same containerlab inventory in the same provisioning step (FR-096).
  The panel is the pinned `andrewbmchugh-flow-panel` **1.20.1**; the SVG and its panel YAML are
  produced by a pinned `clab-io-draw` from `containerlab graph --drawio`. The join between a
  drawing cell and a metric series is **exactly two registered labels** — `source`, the containerlab
  node name, and `interface_name`, normalized from the device's own `ethernet-1/49` to `e1-49` —
  so the join is a contract the register states rather than a label that emerges from collector
  normalization.
- **The boundary this decision draws, restated**: the published telemetry lab whose exposition
  pattern this view is drawn from is a **visualization and generator reference only**. The merge
  expressed that as "its network operating system is not introduced as a runtime" — which becomes
  vacuous when its network operating system *is* the target. It is re-scoped to a
  **reference-artifact boundary** (RD-07, FR-094, SC-017(b)): patterns, panel schema, cell-identifier
  convention and generator tooling may be reused; every reused artefact is vendored, pinned by
  version or digest, carries a provenance header and is served from inside the cluster; and nothing
  resolves from that repository's branch, release feed or registry at run time.
- **Alternative rejected**: treating the OpenTelemetry Collector as the metrics store. It is a
  receiver-processor-exporter and stores nothing; claiming otherwise would misdescribe where
  evidence lives.
- **Alternative rejected**: gNMIc's `prometheus` output scraped directly, skipping OTLP. It would
  produce a second, differently-named metric family for the same series and split the pipeline's
  health evidence in two.
- **Revised by**: RD-07, RD-08, RD-11.

### D-37: One emission, fanned out by a tier-owned collector — zero control-plane edits

- **Decision**: agents emit OTLP **once** to a tier-owned collector in the tier namespace. That
  collector is the only fan-out point, with two exporters: one to the tier's agent-analytics store,
  and one forwarding to the fabric's OpenTelemetry Collector.
- **Rationale**: two independent instrumentations of the same activity are forbidden. One SDK, one
  export endpoint, one collector, two exporters is a single emission path by construction. Routing
  through a tier-owned collector rather than editing the fabric collector's configuration means
  removing the tier's namespace removes the whole pipeline, which is what removability requires.
  The fabric collector already accepts OTLP and already exports to the metrics store, so the
  forwarded metrics need no change there.
- **Naming constraint that makes this work with no control-plane edit**: the fabric collector keeps
  only metrics whose names match its filter. That filter is a platform-owned expression and it must
  be written to admit **both** the device metric names derived from the SR Linux native paths and
  the platform-prefixed agent prefix — the tier's metric names are chosen to pass the same
  expression unmodified. This is a deliberate constraint on the tier's metric naming, adopted so
  that no control-plane file changes; it is also a constraint on the filter itself, which must be
  reviewed against the registered native path set (D-09, D-36) rather than inherited from a
  previous platform's metric names.
- **Analytics store**: a tier-owned single-replica stateful workload with a volume and a
  **generated** password Secret — never a default credential pair. It is queried directly and is
  deliberately **not** wired into the fabric dashboards as a datasource: that workload pins its
  image by digest and has third-party plugin installation removed on purpose after a plugin
  reference crash-looped it. The tier dashboard is therefore metrics-store-backed, and the
  analytics store is additive.
- **Alternatives rejected**:
  - *Adding the analytics exporter and a traces pipeline directly to the fabric collector.* It
    works, but it points a dependency arrow from a control-plane component at the tier's sink, and
    the removability run would then require reverting a control-plane file rather than deleting a
    namespace.
  - *Instrumenting the agents twice, once per sink.* Explicitly non-conforming.
- **Revised by**: RD-11.

---

## 11. SR Linux retarget decisions

The fifteen decisions the retarget made, in the numbering the retarget record uses. Two are marked
*operator decision* — they were put to the operator on **2026-09-20** and answered there, because
each removes something the merged specification promised. Every decision cites the research report
that supports it; where a report's own recommendation differs from what was adopted, the difference
is stated rather than smoothed over. The reports are evidence, not specification
([evidence/README.md](./evidence/README.md)).

### RD-01: Platform, release pin and topology

- **Decision**: the device image is **`ghcr.io/nokia/srlinux:25.7.1`**, pinned by the multi-arch
  manifest-list digest
  **`sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402`**. The containerlab
  kind is `nokia_srlinux`; **leaves are `ixr-d2l` and spines `ixr-d3l`**, both licence-free and both
  carrying the full EVPN-VXLAN feature set. There is **one lab profile**, no KVM and no nested
  virtualization; the host needs an x86-64 CPU with SSSE3, kernel ≥ 4.10 and Docker, and roughly
  2 vCPU and 2 GiB per SR Linux node. The topology is **six nodes** — `spine01`, `spine02`,
  `leaf01`, `leaf02`, `client01`, `client02` — with the clients as Linux containers taking part in
  several services over VLAN subinterfaces on one link. Interfaces are named device-natively
  (`ethernet-1/N`; Linux-side `e1-N`): spines use `ethernet-1/1` and `ethernet-1/2` toward the
  leaves, leaves use `ethernet-1/49` and `ethernet-1/50` as uplinks and `ethernet-1/1` for the
  client; `system0.0` is the VTEP source and router id, `mgmt0` is management, `irb0.<vlan>` is the
  gateway subinterface and the tunnel-interface constant is `vxlan0`. Management runs on the
  labelled Docker network `agentic-netops-mgmt`, default CIDR **`172.25.25.0/24`** (`MGMT_CIDR`),
  with devices at `.11 .12 .21 .22` and clients at `.101 .102`; containerlab's `mgmt.mtu` is never
  set. The management plane is **gNMI over TLS on 57400** only — plaintext gNMI on **57401**
  exists and must be covered by the tier's denial, and JSON-RPC, SSH, NETCONF, SNMP and the vendor
  automation ports are never used. The full set the image exposes — TCP 22, 80, 443, 830, 50052,
  57400, 57401, 57410, 57411 and UDP 161
  ([evidence/01-lab-platform.md](./evidence/01-lab-platform.md) §4.2) — is what the tier's denial
  probe must dial, enumerated once in
  [contracts/kubernetes-objects.md](./contracts/kubernetes-objects.md); §4.2 was probed on a release
  later than the pin and the same report's CPM-ACL baseline allows Telnet/23 with no listener
  recorded, so the set is reconciled at P0 against what gate item G2 observes the pinned image
  listening on. **Containerlab is pinned at `0.79.0`** — the version this research ran
  ([evidence/01-lab-platform.md](./evidence/01-lab-platform.md) §0: `containerlab version` →
  `0.79.0`, commit `5ae50094a`), and the version whose window covers the image pin: it handles the
  26.3+ TLS path rename and sits above the 24.3 gRPC-shape gate, so `0.79.0` with `25.7.1` is inside
  a tested window (§4.3). **The provider's mapping version `srl-mapping v0.1.0`** is the ninth part
  of the compatibility set and is **first-party** — a version this repository mints for its own
  render mapping, resolvable against no registry, so `make verify-compat` asserts it against parts
  1–4 rather than `make verify-pins` resolving it.
  A gNMI Set writes the **running** datastore only, so persistence comes from
  `/system/configuration/auto-save` set in the bootstrap config, and the gRPC server's
  `session-limit` (default **20**, shared by the device-configuration layer and the metric
  collector) is sized explicitly there too.
- **Rationale**: 25.7.1 is the newest release for which **every part of the compatibility set has a
  matching artefact** — it is the release the device-configuration layer's own CI runs against, the
  last one its YANG deviation branches cover, and it sits below the containerlab release at which
  the SR Linux TLS configuration path changes. Pinning the newest image instead would mean
  hand-authoring a schema resource and either dropping or forking the deviations that exist
  precisely so the vendor's YANG compiles at all. The type choice follows the feature set, not
  taste: the emulated `ixr-d2l` and `ixr-d3l` carry `vxlan`, `evpn-vxlan-mac-vrf`,
  `evpn-vxlan-ifl`, the ACL features and VXLAN statistics, and they are what the vendor's own
  reference labs use.
- **Evidence**: [evidence/01-lab-platform.md](./evidence/01-lab-platform.md) §1.4 (the digests,
  read from the registry this session), §1.6 (which single release to pin, and why the constraint
  is the toolchain rather than the image), §1.7 (what replaces the five-part compatibility set),
  §2.1 and §2.3 (the type list and what is licence-free), §2.4 (the decisive feature table),
  §2.6 (the type recommendation), §3.1–§3.5 (naming, the special interfaces, the
  subinterface/`vlan-tagging` model, the VXLAN object model and the port map), §4.1–§4.5
  (credentials, the observed ports, containerlab's TLS material, management network reuse),
  §4.6 (the `172.31.0.0/16` collision on the reference host), §5.1–§5.4 (no KVM, the hard host
  requirements, the measured 1.4–1.8 GiB idle footprint, the NFR-004 rewrite), §6.3 and §6.4
  (running-only Sets, `auto-save`, and commit-confirmed over gNMI);
  [evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md) §7 (the nine-part
  compatibility set) and §9.3 (the `session-limit` trap).
- **Measurement status**: the lab measurements were taken in research on **26.7.2** in throwaway
  labs; they are re-observed at P0 on the pinned release through the capability gate (RD-12). No
  number here is reported as observed on the pin.
- **Alternatives rejected**:
  - *Pinning `26.7.2`* (`sha256:0096fe3ebcafabb7253492e2060425fe027a168e0e066766d1e85efbb0b48be8`).
    The research measured most of its lab facts on it and it works, but the device-configuration
    layer publishes no schema resource or YANG deviation branch past 25.7, and containerlab changes
    the SR Linux TLS configuration path at 26.3. Taking it would mean hand-authoring the schema and
    forking the deviations — risk with no requirement behind it.
  - *A floating tag such as `latest`.* Forbidden by NFR-003, and it currently resolves to the same
    manifest as the newest release, so it also carries the objection above.
  - *An `ixr-h` series type.* `ixr-h4` and its siblings have no `vxlan` and neither EVPN feature at
    all, so no overlay construct can be built on them in any role. `ixr-h5` has VXLAN but not the
    rest of what the constructs need, and `ixr-h6` will not boot without a licence.
  - *A release train older than 25.3.* The gate assumes objects that post-date it.
  - *Keeping the inherited `172.31.0.0/16` management default.* It collides with an existing Docker
    network on the reference host, which is why the default moves and the preflight is mandatory.
  - *Setting containerlab's `mgmt.mtu`.* Observed to apply partially and silently.
- **Consequences**: FR-001, FR-002, FR-006, FR-008, FR-010, NFR-003, NFR-004, SC-001, SC-002,
  SC-003; D-01 and D-02 revised; the `--profile` flag deleted from the lifecycle scripts.

### RD-02: The southbound is the provider, the device-configuration layer and gNMI — with no exception

- **Decision**: the **only** southbound is `provider → device-configuration Config → gNMI
  (JSON_IETF, TLS) → SR Linux`. There is no executor, no shell path into a device, no raw-store
  client, no whole-config-versus-raw-store split and no escape hatch, and FR-007 carries no
  exception: every component except the network nodes and the Linux endpoints runs in the cluster.
  Everything that existed for the old path is deleted rather than adapted — the coupling rows that
  described the configuration store and its binding semantics, **D-12**, risk R-25, the host-side
  executor and plan packages, the store check types and the "no access-list operation in a
  whole-config write" assertion. The recorded divergence survives only as history.
- **The pinned layer**: device-configuration `config-server v0.0.58` — images
  `ghcr.io/sdcio/config-server-api-server:v0.0.58` @
  `sha256:bd5d312512ad7484eadb6b8e43ef550f647034abdead80429b8ba17d74041f9e` and
  `ghcr.io/sdcio/config-server-controller:v0.0.58` @
  `sha256:01c69c589137579db784c769019bc92591899666714f153b5b4b97a761ffea13` — with
  `ghcr.io/sdcio/data-server:v0.0.66` @
  `sha256:fe138dcfcfeb5bee2a615bd4e9616bafc9d27b57ae55cee9360d4fd0d2cecbf7`, and **cert-manager as
  a pinned prerequisite** (its aggregated API server does not serve without one; the digest is
  pinned in `versions.lock.yaml` at P0). The schema resource declares provider
  `srl.nokia.sdcio.dev`, version `25.7.1`, the model repository
  `https://github.com/nokia/srlinux-yang-models` at tag `v25.7.1` (commit
  `badcf9977fe672437907cdae7daebb27a1361c36`), `models: [srl_nokia/models]`,
  `includes: [ietf, openconfig]`, `excludes: ['.*tools.*']`, plus the deviation repository
  `sdcio/srlinux-yang-patch` pinned **by hash** `7410316d34f1d393b82889c0caa1b5acef80fb60` —
  never by its `v25.7` branch, because a branch reference is mutable.
- **The rules that come with it**: one `Config` per (service, node), bound by the target-name and
  target-namespace labels, named `<service>.<node>` with no dot inside `<service>`; priority band
  `10` for fabric and `20` for services, with two `Config`s that could touch one leaf never sharing
  a priority; `lifecycle.deletionPolicy: delete`; `revertive: true` stated on every `Config` and
  never inherited, in the lab and in production alike; any `OVERRULED` deviation on a
  platform-owned path a terminal error. "Dry-run" means
  two real mechanisms and neither is the API server validating the device payload (D-05). A failed
  device transaction rolls back and does not poison the next one.
- **Rationale**: the escape hatch existed for one platform-specific hazard — a whole-config write
  that failed validation poisoned every subsequent whole-config write on that node — and that
  hazard does not exist here. The leafref that could not resolve on the old platform, the
  access-list binding's reference to a subinterface, **does** resolve on SR Linux. Validation moves
  left: the layer validates against the pinned schema before a byte reaches the device, and the
  same validation runs offline in CI. Transactions, rollback, recovery, drift and configuration
  blame are features of the layer that its own CI exercises against this exact image.
- **Evidence**: [evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md) §3.1–§3.3
  (release, deployment, the API groups and a complete working SR Linux example), §3.4 (priority,
  ownership, deviation and revertive semantics, including that equal priorities are **not**
  resolved), §3.5 (the known limitations, including that the API server validates none of the
  device payload and that the deviation branches stop at `v25.7`), §5 (the southbound
  recommendation and the artefacts deleted as a consequence), §7 (the pins);
  [evidence/03-acl.md](./evidence/03-acl.md) §8 (the whole-config poisoning hazard is gone, and
  what replaces the raw-store split).
- **Alternatives rejected**:
  - *Keeping a host-side executor as an escape hatch.* Its only justification was the poisoning
    hazard; keeping it would re-derive a set of couplings against a store that does not exist, and
    it would be a second renderer, which FR-060 forbids.
  - *Direct gNMI from a controller, bypassing the layer.* It discards validation, transactions,
    drift handling and field ownership for nothing (D-05).
  - *Treating a Kubernetes server-side dry-run of the `Config` as the validation gate.* The API
    server does not validate the device payload; presenting it as a gate would be an overclaim.
  - *Pinning the deviation repository by its branch.* Mutable, and NFR-003 forbids it.
- **Consequences**: FR-007 (no exception), FR-014, FR-015, FR-017, NFR-003, CR-004; D-02, D-05 and
  D-09 revised; **D-12 tombstoned**; PC-11, PC-12, PC-13 and the second half of PC-16 deleted;
  R-25 retired; new risks R-32 (the deviation patch weakens validation) and R-33 (the shared gRPC
  session limit).

### RD-03: Control-plane ownership — a first-party fabric API and one first-party provider *(operator decision, 2026-09-20)*

- **Decision**: the fabric control plane is **first-party**. The upstream fabric project and its SR
  Linux provider are **not in the dependency graph** — they are cited as a **reference design**
  only, because their native SR Linux JSON templates informed the render. The first-party API group
  is **`fabric.agentic-netops.io/v1alpha1`** with structural schemas: **`Fabric`** (node roles,
  underlay addressing pools, the ASN plan, the fabric-wide overlay AS, MTU policy, the
  route-reflecting spines and the site inventory) and **`Network`** (the service intent object,
  whose Kind name is kept so the tier's contracts stay stable). There is **no `NetworkDevice`
  Kind** — the per-(service, node) object is the device-configuration `Config` itself — and **no
  `SRv6Service`** (RD-04). One controller binary, **`agentic-netops-srl-provider`**, carries a
  `Fabric` reconciler and a `Network` reconciler and is the single renderer of every device path.
  **Reused unchanged**: the device-configuration layer in full, and the allocation authority
  **`kuid-server v0.0.13`** @ `sha256:d6fdae78cc5ba4d14655ef2e77bc3c38eb8201679b52aef56bf550e332800608`
  for its `ipam`, `as`, `vlan` and `genid` index/claim/entry APIs and its node, link and endpoint
  inventory — aggregated APIs, not CRDs.
- **Rationale**: the upstream fabric control plane has had no release, is dormant for roughly
  twenty-two months, demonstrates against an SR Linux release from 24.3, no longer compiles against
  the current device-configuration layer, publishes only mutable image references, and — decisively
  — **cannot express four of the things this specification provisions**: an access list, an anycast
  gateway, a local-only bridge domain and an explicit route target. A gap controller beside it
  would be a second translation path by FR-060's own definition, and the two controllers would
  contend for the same device paths under a priority scheme whose equal-priority behaviour is
  undefined.
- **Recorded honestly**: the predecessor build **never ran** the upstream control plane. Its
  installers fetched CRD paths that do not exist upstream and fell back silently to hand-written
  look-alike CRDs in look-alike API groups; its lock file pinned a device-configuration repository
  that returns 404; and the `Network` shape the entire data model rested on was a first-party
  invention presented as an upstream API. So this decision is not a regression from reuse — it is
  the first time the question has been answered truthfully. **FR-098** forbids the mechanism that
  hid it.
- **The allocation authority is dormant too, and that is recorded rather than hidden**: its last
  release is from 2024-12-27. It is reused because it is the only allocator and it serves exactly
  the claim contract the platform needs, under **risk R-31**, with a P0 qualification (a claim
  round-trip reporting an allocated value in status, and the aggregated API healthy on the pinned
  Kind — gate item G11) and a named fallback: a first-party static-pool allocator behind the same
  claim contract, adopted at P0 by decision and never silently.
- **Evidence**: [evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md) §0 (the three
  findings, including the look-alike CRDs and the 404 pin), §1.1–§1.4 (what the upstream bundle
  is, its API surface, what its `Network` can and cannot express — `accessLists` absent, no anycast
  gateway, no local-only VLAN, no explicit route target — and that it claims only IP and AS),
  §2.1–§2.4 (where the upstream provider lives, how it emits a `Config`, the definitive gap list in
  its templates, and that its demonstrated target is SR Linux 24.3.2), §4 (the allocation
  authority's exact groups and kinds, and its dormancy), §6 (the ownership recommendation, why not
  upstream as-is, why not a gap controller, and how access-list intent is carried), §7 (the pins
  and the mutual-compatibility caveats).
- **Where this goes further than the research**: the report recommended keeping the upstream fabric
  CRDs and replacing only the provider. The operator decision removes them as well, because the
  report's own gap list shows the object cannot carry the access-list, gateway, local-VLAN or
  route-target intent this specification requires, and a first-party object beside a dormant
  upstream one would leave two intent objects for one service.
- **Alternatives rejected**:
  - *Upstream as-is.* Dormant, wrong device release, does not compile against the current
    device-configuration layer, renders none of the four missing constructs, and pins nothing
    immutably.
  - *Upstream plus a first-party gap controller.* Two renderers onto one device: a second
    translation path by FR-060's definition, with ownership decided by priority ordering and an
    undefined outcome when two intents meet on one leaf.
  - *Carrying access-list intent as an annotation on the upstream object.* Unvalidatable by the API
    server, invisible to schema tooling, impossible to dry-run, and it puts payload in metadata —
    which makes the metadata-ownership problem worse rather than better.
  - *Forking the upstream fabric project to add the missing fields.* Technically clean and
    genuinely tempting, but it forks a dormant tree and makes every future rebase a conflict in the
    type the whole data model rests on — and it is a first-party codebase in someone else's API
    group, which FR-098 forbids.
  - *A separate first-party `AccessList` CRD.* The gap controller in CRD clothing: two objects, two
    renders, two readiness stories for one service.
- **Consequences**: FR-012, FR-013, FR-014, FR-062, FR-098; D-04, D-06, D-22 and D-33 revised;
  C-05, C-09, C-20 and C-21; risk R-31; R-02 rewritten rather than retired.

### RD-04: SRv6 is deferred to a future feature *(operator decision, 2026-09-20)*

- **Decision**: **SRv6 is out of scope for 004** and is carried to a future feature (working title
  "005 — SRv6 services"), which this specification does not create. The retired identifiers keep
  their numbers and a one-line tombstone: **US3, FR-003, FR-005, FR-021, FR-022, FR-023, SC-009,
  SC-010, D-08, R-04, C-06, PC-04, PC-05**, reconciliation Rule 12, delivery phase P4,
  `data-model.md` §4 and `quickstart.md` §9. Every SRv6 mention in live requirement text is
  removed, and the "SRv6 service-path view" becomes an **EVPN service-path view**: the
  VTEP-to-VTEP path per bridged or routed instance, per-VTEP tunnel statistics, per-VNI MAC counts
  and access-list entry hit counters.
- **Salvaged, not lost**: the dual-stack underlay obligation that FR-003 also carried moves into
  **FR-011** — the underlay and tenant address families are dual-stack, while **the VXLAN tunnel
  endpoint is IPv4-only**, because the platform's tunnel source admits only the system IPv4
  address. **GAP-5 is closed by narrowing**: the tier's writer Role grants the service intent Kind
  alone and `srv6services` is removed everywhere.
- **Rationale**: no licence-free SR Linux container type can originate or terminate an SRv6
  service. Where SRv6 exists at all the platform is documented as transit-only for micro-SID
  traffic, with service initiation and termination listed as unsupported; the types that could host
  a headend will not boot without a licence. Deeper than the platform gating: **no SR Linux release
  models an explicit segment list, an SRv6 policy, a steering entry or a per-SID counter**, and the
  standard-model fallback is marked not-supported for segment routing. US3's acceptance — ordered
  SIDs proven from a capture, per-SID counters, an operator-directed path change — is therefore
  unsatisfiable in principle, not merely unqualified on this profile. Keeping it as a requirement
  while knowing that would be exactly the overclaim Principle I forbids.
- **Evidence**: [evidence/04-srv6.md](./evidence/04-srv6.md) §0 (the bottom line), §3.2 (the
  decisive "not modelled" list, including the standard-model deviation), §4.1–§4.3 (the container
  types, what was observed on each, and the one licence-free platform's exposed schema), §4.4 (a
  Set accepted into running and absent from state, with no route or tunnel entry — "not even
  programmed"), §4.6 (the vendor's own platform statement), §6 (the alternatives), §8 (the
  consequences and the identifier lists), §10 (what would reopen it);
  [evidence/01-lab-platform.md](./evidence/01-lab-platform.md) §2.4 (no `srv6`, `srv6-dt2` or
  `mpls` feature on any licence-free datacenter type) and §7 "G10 — what the gate must NOT check
  any more".
- **Where this differs from the research**: the report recommended demoting SRv6 behind a
  fail-closed capability gate and rewriting the service contract down to what SR Linux models, with
  deferral as its runner-up. The operator chose deferral. The report's own argument for the runner-up
  is the one that decides it: a gate that can never pass, guarding a requirement that cannot hold in
  principle, is a requirement the specification should not be carrying.
- **Alternatives rejected**:
  - *Best-effort SRv6 L3VPN on SR Linux (BGP-signalled service SIDs, one SID, no explicit path).*
    Needs a licence and a chassis type the lab cannot pin, needs a second IGP added to a BGP-only
    fabric, cannot be folded into the bridged construct at all, and still fails the ordered-SID and
    per-SID-counter half of the acceptance.
  - *Linux endpoints performing the encapsulation with SR Linux as plain IPv6 transit.* Forbidden
    twice already — every emulated network device must be an SR Linux node, and host-only SRv6 is
    named explicitly as something a failed capability check may not be replaced with. Adopting it
    would mean deleting the anti-overclaim rule in order to produce a green result that says
    nothing about the device under test.
  - *A mixed lab with a second network operating system for SRv6.* Violates the single-platform
    rule and doubles the image, licence and schema surface for one user story.
  - *Keeping the service and its requirements behind a gate that fails closed.* The research's own
    recommendation, and the closest call. Rejected because it would leave requirements in the
    specification that no release of this platform can satisfy — and because the gate's value as a
    demonstration does not justify carrying unsatisfiable text.
- **Consequences**: US3, FR-003, FR-005, FR-011, FR-021, FR-022, FR-023, SC-009, SC-010 and
  §Deferred scope; D-08 tombstoned; GAP-5 closed; delivery phase P4 retired; R-04 and C-06 retired;
  the topology drops to six nodes (RD-01).

### RD-05: Access lists — model, binding point, ordering and verification

- **Decision**: the model is the ≥24.3 form only — `/acl/acl-filter[name][type]` (the key is the
  **pair**, `type` ∈ `ipv4`|`ipv6`|`mac`) with `entry[sequence-id]`, bound through
  `/acl/interface[interface-id]` carrying an explicit `interface-ref{interface, subinterface}` and
  an `input` or `output` `acl-filter[name][type]`.
  - **The binding point is the subinterface.** The operator still names a node, a port and
    optionally a VLAN; that resolves through the site inventory to `(interface, index)`, with no
    VLAN meaning index `0`. `interface-id` is written as `"<interface>.<index>"` and
    `interface-ref` is **always** written as well.
  - **The unit of exclusivity is (node, interface, subinterface, direction, address family).** Two
    services may share a physical port at the same stage on different subinterfaces or different
    address families.
  - **A standalone access list requires the subinterface to exist already**, owned by another
    service on that node, port and VLAN; otherwise it is refused before anything is created,
    naming the missing subinterface. An access list never creates a subinterface. A list stated as
    a property of a service binds to that service's own subinterfaces in the same `Config`.
  - **Ordering: `sequence-id := priority`, the identity mapping.** Entries are evaluated in
    **ascending** order, first match wins. Usable range **1–65534**; **65535 is reserved** for the
    default action.
  - **The platform's implicit default is ACCEPT.** A declared `defaultAction` renders as entry
    `65535` with no match fields; when none is declared, the confirmation must state that unmatched
    traffic is accepted by the platform default.
  - **Types accepted: `ipv4` and `ipv6`**; `l3` and `l3v6` spellings fold. **`mac` is refused as
    out of scope.** Protocols: any IP protocol number 0–255 or a known name, **including ICMPv6**;
    L4 ports only with TCP or UDP; actions permit → `accept` and deny → `drop`; no logging.
    TCP flags, DSCP, TTL and hop-limit, fragments and ICMP type/code are refused by name.
  - **Names**: filter name derived `acl-<serviceId>-<stage>`, sanitised to the device's own string
    type; **`system` and `capture` are reserved and refused**. Operator rule names live in the
    entry description.
  - **Egress is a capability-gate item.** Egress filters on the emulated platform carry platform
    restrictions; if the pinned profile does not qualify egress, an egress list is refused by name
    at interpretation (FR-097).
  - **Verification is two-sided and keyed** (D-16, RD-13), and **enforcement is demonstrated in
    acceptance only** (SC-041), never in readiness.
  - **Deletion order**: binding → filter → the subinterface's owner.
- **Rationale**: the binding point decides everything else. Because the binding is a separate
  top-level object whose `interface-ref` is a leafref into the subinterface tree, the device itself
  proves the binding target exists — which is what makes "refuse a standalone list naming an
  attachment nobody created" an enforceable rule rather than a convention. Because the platform
  accepts one filter of a type per subinterface per direction, the conflict refusal is a necessity
  rather than a policy (D-14). And because the device evaluates ascending with an implicit accept,
  both the ordering direction and the default action have to be stated to the operator rather than
  inherited from the previous platform's habits.
- **Evidence**: [evidence/03-acl.md](./evidence/03-acl.md) §0 (the release and the 24.3
  restructure), §1 (filter identity, the sanitiser, the name constraints and the reserved names),
  §2 (filter types, and why the MAC refusal survives with a different reason), §3 (sequence-id,
  the direction inversion stated as a correctness trap, the reserved terminal slot and its effect
  on FR-041), §4 (the match set, and that the ICMPv6 refusal vanishes), §5 (the binding point, the
  answers to the sub-questions, the standalone-ACL options and the deletion ordering), §6 (egress
  restrictions, TCAM, and that the containerized dataplane does enforce filters), §7 (the keyed
  two-sided read-back); [evidence/01-lab-platform.md](./evidence/01-lab-platform.md) §2.5 (the
  binding tree measured on the emulated types, and the platform's own refusal of a second filter:
  one filter per subinterface per direction).
- **Alternatives rejected**:
  - *Mapping operator priority to `sequence-id` by dense rank × 10* — the research's own
    recommendation. It leaves insertion gaps, but it **renumbers every entry when a rule is
    inserted**, which violates minimal-change reconciliation and makes a device read-back
    illegible against the request the operator wrote. The identity mapping keeps what the operator
    wrote as the number the device shows.
  - *Inverting the mapping (`sequence-id` derived so that a higher operator priority still wins).*
    It preserves one habit from the previous platform at the cost of a device view that contradicts
    the request, on a platform where nothing else preserves that habit. The direction flip is
    instead made explicit to the operator at the first confirmation (FR-039).
  - *O2 — letting a standalone access list create the subinterface it binds to.* It turns an access
    list into an interface-provisioning construct, breaks the one-owner rule, and its rollback
    would delete a subinterface another service may have come to depend on.
  - *O3 — binding by `interface-id` alone and omitting `interface-ref`.* The key is a free string
    with no leafref, so a wrong name produces a configuration that reads back successfully and
    binds nothing: precisely the silent no-op the keyed verification exists to prevent.
  - *O4 — writing the filter immediately and retrying the binding until the subinterface appears.*
    It introduces a partially-converged state the status vocabulary has no word for, and turns the
    mid-finalization question into a mid-creation question as well.
  - *Admitting `mac` filters.* The device models them; the refusal is a scope decision, and it is
    also a simplification, because the platform forbids a MAC filter and an IP filter on one
    subinterface and direction — admitting `mac` would make the unit of exclusivity
    (subinterface, direction) for **every** service, including the ones that never asked for it.
    The refusal must say which kind of "no" it is (FR-038).
  - *Binding to a network instance, a VLAN as such, an integrated-routing interface or
    fabric-wide.* Out of scope for the operator vocabulary; an IRB subinterface is bindable only
    when explicitly named, and never by implicit fan-out.
- **Consequences**: FR-035 to FR-043, FR-097, SC-014, SC-015, SC-041; D-13, D-14, D-15 and D-16
  revised; **D-12 tombstoned** (RD-02); PC-06, PC-10 and PC-13 resolved; R-26 closed by
  construction; R-29 rewritten to the subinterface unit; GAP-4 folded into FR-043.

### RD-06: The construct vocabulary is the device's vocabulary where it can be

- **Decision**: `mac-vrf` and `ip-vrf` are kept as construct names **because they are SR Linux's
  literal `network-instance type` identity values**, and that alignment is promoted from a
  convenience to a requirement with a CI assertion against the pinned YANG (FR-099). `vlan` and
  `acl` remain operator vocabulary, documented alongside the device objects they render.
  **`vlan` stays its own construct and its own list** (`spec.vlans[]`): on SR Linux it renders as a
  `mac-vrf` network-instance **with no `vxlan-interface`, no `bgp-evpn` and no `bgp-vpn`** — a
  local bridge domain with bridged subinterfaces. The four renders are: `mac-vrf` (bridged
  network-instance, `vlan-tagging` single-tagged bridged subinterfaces, a `vxlan-interface` of type
  `bridged` on the constant `vxlan0` tunnel-interface, `bgp-evpn` with its EVI and `bgp-vpn` with
  explicit import and export route targets); `ip-vrf` (routed network-instance, routed
  subinterfaces, a `routed` vxlan-interface and the interface-less EVPN Type-5 model); `mac-vrf`
  with an anycast gateway (an `irb0.<vlan>` subinterface carrying `anycast-gw` addresses and a
  fabric-constant virtual router id, attached to **both** the bridged and the routed instance, with
  ARP/ND learning and host-route population, in the declared address families only); and `acl`
  (RD-05).
- **Rationale**: two of the four constructs stop being a translation layer and become a quotation
  of the device, which is what SC-013 measures — a newcomer who has read the vendor's own
  documentation for bridged instances, Layer 2 EVPN-VXLAN, Layer 3 EVPN-VXLAN with IRB and anycast
  gateway, and access lists can provision all four without a translation table. The same fact makes
  `vlan` **more** necessary as a separate list, not less: a local VLAN and a `mac-vrf` render to
  the same device instance type and differ only by the presence of the overlay blocks, so encoding
  the difference as a missing field would reproduce D-11's defect at the device layer, where it is
  invisible.
- **Evidence**: [evidence/02-evpn-constructs.md](./evidence/02-evpn-constructs.md) §6 (the identity
  values the device actually uses), §3.1 and §3.2 (what `vlan` is on SR Linux and why it stays its
  own list), §2.1 (the `mac-vrf` tree), §4.1 (the interface-less `ip-vrf` model), §5.1–§5.3 (the
  anycast-gateway shape and its exact paths).
- **Alternatives rejected**:
  - *Folding `vlan` into `mac-vrf` as "a bridge domain with no L2VNI".* Both render to instance
    type `mac-vrf`; the distinction would exist only as an absence, at every layer including the
    device.
  - *Renaming the constructs to platform-neutral words.* It would discard the one property SC-013
    measures, for a neutrality no operator of this lab benefits from.
  - *Treating the alignment as a coincidence to be preserved by convention.* Conventions drift
    silently; FR-099's CI assertion against the pinned model does not.
- **Consequences**: FR-024, FR-029, FR-030, FR-031, FR-032, FR-099, SC-013; D-10 and D-11 revised.

### RD-07: The visualization boundary becomes a reference-artifact boundary

- **Decision**: boundary (b) of the repository-wide deny-list is re-scoped. It no longer says "no
  runtime artefact of that telemetry lab's network operating system" — that operating system is now
  the target, so the clause as written forbade the deliverable. It says instead: **no runtime
  dependency on a third-party reference lab repository** — no image, chart, plugin, panel
  configuration, topology asset or dashboard resolved from such a repository's branch, release feed
  or registry at run time, and no unpinned installation of one. Patterns may be reused; artefacts
  may be vendored when pinned by version or immutable digest, carrying a provenance header, and
  served from inside the cluster. Boundaries (a) and (c) are unchanged, and boundary (a) explicitly
  covers the device vendor's own fabric controller and automation product as a proprietary vendor
  controller. The replacement text is in [spec.md](./spec.md) FR-094 and SC-017(b).
- **Rationale**: the original clause protected three different things, and only one of them
  survives the retarget. "Do not adopt a second operating system as a runtime because you borrowed
  its dashboards" is obsolete — the operating system is the target. "Do not adopt that lab's
  deployment shape" is already covered by boundary (c), which forbids running platform applications
  outside the cluster. What remains is the real, unduplicated protection: **do not take a runtime
  dependency on a third-party lab repository's artefacts** — and the research found that dependency
  live in the pattern being borrowed, where the panel configuration, the site configuration and the
  topology drawing are each fetched from the reference repository's default branch at run time, and
  the dashboard plugin is installed without a version. That is a pinning violation wearing a
  visualization hat, and it is now more important than before, not less.
- **CI checks the clause buys**: no reference to a raw repository-content host in any provisioned
  dashboard, panel or datasource; every Grafana plugin installation carrying a version; the
  topology generator's version never `latest` and never omitted; every vendored asset carrying a
  provenance header naming its upstream source and pinned revision.
- **Evidence**: [evidence/06-telemetry-visualization.md](./evidence/06-telemetry-visualization.md)
  §4.1 (the reference lab's live, unpinned, branch-served panel and SVG dependencies, and its
  anonymous-admin Grafana configuration), §5.1 (what the clause says today), §5.2 (the three
  protections and which survive), §5.3 (the options), §5.4 (the recommended replacement text,
  adopted in [spec.md](./spec.md) with only editorial change).
- **Alternatives rejected**:
  - *(i) Drop boundary (b) entirely.* It loses the only protection that is still real, renumbers
    the remaining boundary and breaks the traceability rows that point at it, and the deny-list
    loses the one rule that catches a branch-served dashboard asset.
  - *(iii) Re-scope (b) to forbid Compose or host-side telemetry stacks.* Pure duplication of
    boundary (c); two boundaries with the same predicate make the deny-list incoherent in a
    different way.
  - *(iv) Replace it with a "not this operating system" boundary aimed at some other platform.*
    It inverts the same problem again at the next retarget and encodes an arbitrary grudge as a
    requirement.
- **Consequences**: FR-094, SC-017(b), NFR-003; PC-20 resolved by rewrite; D-36 revised.

### RD-08: The path register is native-first

- **Decision**: **native-first.** Every path the provider renders and every path the collector
  subscribes to is the device's own `srl_nokia` model unless the path register records a justified
  standard-model exception — and today there are none. The register is retained, CI-guarded so a
  new construct cannot pass uncovered, and extended: for a subscribed path it also records the
  derived metric name, the label names and the stream mode.
- **Rationale**: the merge's "prefer qualified standard-model paths, use native only for proven
  gaps" describes a preference this platform cannot exercise. The pinned device schema is built
  from native models only, so **every path the device-configuration layer validates and applies is
  native by construction**. The device's standard-model surface is an optional, separately-enabled,
  deviated subset behind a presence container with its own prerequisite; the gRPC server selects
  one model set per request origin and defaults to native, and the layer does not expose a
  per-path origin. And the coverage is not merely thinner but absent exactly where this
  specification lives: the vendor's own mapping files mark
  `/network-instances/network-instance/evpn` and `/network-instances/network-instance/vlans`
  **not supported**, and there is no standard-model equivalent for the device-computed interface
  traffic rate the topology view is built on.
- **Evidence**: [evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md) §8 (the
  native-only schema model set, the presence container and its prerequisite, the `yang-models`
  default, the coverage asymmetry, and the recommended requirement wording);
  [evidence/06-telemetry-visualization.md](./evidence/06-telemetry-visualization.md) §3 (the
  vendor's own mapping files, the explicit not-supported entries for EVPN and VLANs, and the
  missing traffic-rate equivalent); [evidence/01-lab-platform.md](./evidence/01-lab-platform.md)
  §6.5 (the same asymmetry seen from the encoding and origin side).
- **Alternatives rejected**:
  - *Standard-model-first with native as the justified exception* — the merge's policy. It inverts
    the evidence: every EVPN and VXLAN path becomes an exception on day one, and the register
    degenerates into a list of everything.
  - *Mixing model families per path.* It requires a per-request origin the transaction layer does
    not expose on a rendered path, and it forks the register into two schemas.
  - *Deleting the register now that there is only one answer.* The register is what makes the
    answer checkable, and what catches the first construct that quietly renders something
    uncovered.
- **Consequences**: FR-017, FR-089; D-06 and D-09 revised; PC-14 replaced; C-09.

### RD-09: Identifier derivation and claim profiles

> **Amended by AD-51** (operator decision, 2026-09-21): the `ip-vrf` profile below claims an L3VNI
> and **never a VLAN** — an `ip-vrf` attachment's VLAN is named or absent, and none is allocated.

- **Decision**: exactly three things are **claimed** for a service — the service VLAN
  (`vlan.be.kuid.dev`, allocated from the index's `1000–4000` unless the operator named one, in
  which case it comes from the naming band `100–999` and is claimed by nobody — AD-33) and the L2VNI and
  L3VNI (`genid.be.kuid.dev`, 32-bit index, band 10000–20000) — plus the fabric's IP prefixes
  (`ipam.be.kuid.dev`) and ASNs (`as.be.kuid.dev`), which the `Fabric` reconciler claims, not the
  tier. Everything else is **derived**: `evi := vni`; the route distinguisher is left for the
  device to auto-derive as `<system0.0 IPv4>:<evi>` and is not rendered at all; the route target
  **is** rendered explicitly as `target:<fabricASN>:<vni>`; the subinterface index `:= vlan` (`0`
  when untagged); the vxlan-interface index `:= vni`; the IRB subinterface is `irb0.<vlan>`; and
  network-instance names derive from the service id as `macvrf-<id>`, `ipvrf-<id>` and
  `vlan-<id>`, sanitised.
- **The route-target index is removed** from the claim profiles. *Revisit trigger*: asymmetric
  import/export, or deliberate inter-tenant leaking. `Network.spec.routers[].rd` is removed;
  `routeTargets` stays on the object as the rendered, derived value.
- **The band constraint**: while `evi := vni`, **the VNI band MUST be a subset of the device's EVI
  range, 1–65535**. The merge's rule that an L3VNI may be claimed only from a sub-band with a
  derivable routed-instance VLAN is deleted — nothing on this platform derives a VLAN from a VNI.
  A named VLAN outside the VLAN index's usable range is refused with the range stated.
- **Profiles**: `vlan` → VLAN only; `mac-vrf` → VLAN + L2VNI; `mac-vrf` with a gateway → VLAN +
  L2VNI + L3VNI; `ip-vrf` → L3VNI, plus a VLAN per tagged attachment when the operator named none;
  `acl` → nothing at all.
- **Rationale**: every derived value is reconstructable from a claimed value, the service id or a
  fabric-wide constant, so an allocator in front of it would be state that can drift from the thing
  it describes (FR-012). The route target is the load-bearing case: the device's **auto-derived**
  route target is built from the leaf's own underlay ASN, so on a fabric where each leaf has its
  own ASN it differs per leaf and the import and export sets silently never match — sessions up,
  routes exchanged, no service. Rendering it from the fabric-wide overlay AS is the only form that
  works, and it needs no allocation.
- **Evidence**: [evidence/02-evpn-constructs.md](./evidence/02-evpn-constructs.md) §8.1 (what
  actually needs allocating), §8.2 (`evi := vni` and the argument for dropping the route-target
  index), §8.3 (the claim profiles), §2.2 (auto-derived versus explicit RD and RT, and why an
  auto-derived RT must not be relied on), §2.3 (the authoritative value ranges), §4.3 (what
  replaces the routed-VLAN band), §9.2 (subinterface-index derivation), §9.3 (network-instance name
  derivation), §9.4 (the conflict cases).
- **Alternatives rejected**:
  - *Leaving the route target auto-derived.* It uses the per-leaf ASN and never matches across
    leaves; the failure is silent and looks like a healthy control plane.
  - *Claiming the route target, or claiming the EVI separately from the VNI.* Allocation state for
    values that are a function of an already-claimed value; two sources of truth for one number.
  - *A counter-based subinterface index.* It breaks reconstructability — the same intent reapplied
    after a restart could derive a different index — and it makes the device's own object names
    unreadable against the request. `index := vlan` is stable, legible and collision-detecting by
    construction: two services wanting (node, port, vlan) both derive the same
    `ethernet-1/N.<vlan>` and the second is refused at validation naming the holder.
- **Consequences**: FR-012, FR-034, FR-062, D-22 and D-25 revised; PC-15 deleted; R-28 rewritten.

### RD-10: The MTU envelope

- **Decision**: the 7220 IXR port MTU maximum is **9412**. Fabric links are set to `mtu 9412` and
  the underlay subinterfaces to `ip-mtu 9398`; the tenant IP MTU carried over VXLAN is **9348**,
  which is the port MTU less 64 bytes of encapsulation. The acceptance probes are an ICMP payload
  of **9320** for IPv4 and **9300** for IPv6 passing, and one byte more failing (SC-005).
  **Client interfaces MUST be set to 9348**: containerlab's veth default of 9500 black-holes TCP
  while ping still succeeds, which is the edge case the specification names. An IRB subinterface's
  `ip-mtu` must be set explicitly, because SR Linux performs no VXLAN MTU check of its own.
  The VXLAN tunnel endpoint is IPv4-only.
- **Rationale**: the previous platform's numbers were arithmetic on a different port MTU and a
  different encapsulation budget, and carrying them forward would have produced a tenant MTU that
  either wastes headroom or black-holes. These numbers are the measured envelope, and the
  client-side value is included because the failure it prevents is invisible to the obvious test.
- **Evidence**: [evidence/01-lab-platform.md](./evidence/01-lab-platform.md) §8.1 (the SR Linux MTU
  model), §8.2 (the containerlab veth MTU), §8.3 (the measured VXLAN arithmetic), §8.4 (the
  recomputed numbers against the constitution's).
- **Measurement status**: measured in research on release 26.7.2 in a throwaway lab, and
  **re-observed at P0 on the pinned release** as capability-gate item G6. No number here is
  reported as observed on the pin.
- **Alternatives rejected**:
  - *Keeping the inherited 9216 envelope.* It is not this platform's port MTU; the arithmetic
    below it would be wrong in both directions and the acceptance probe would prove nothing.
  - *Leaving client interfaces at the containerlab default.* It is the exact configuration that
    makes ping pass and TCP hang.
  - *Setting containerlab's `mgmt.mtu`.* Observed to half-apply silently; the management network
    is left at the default instead.
- **Consequences**: FR-002, FR-011, SC-005; constitution v1.1.0 MTU policy.

### RD-11: Telemetry pipeline, path set and topology view

- **Decision**: the pipeline is unchanged from the merge and is implementable as written —
  in-cluster **gNMIc 0.47.0** with a native **`otlp`** output over gRPC → in-cluster OpenTelemetry
  Collector → Prometheus → Grafana — and gNMIc's own metrics endpoint is scraped as a
  `gnmic-self` target so every pipeline stage has evidence. Subscriptions use `json_ietf` in the
  native origin, in **`sample` mode by default**, with on-change used only where an acceptance
  check has shown the device supports it for that path. The registered native path set is:
  interface administrative and operational state, traffic rate and statistics; subinterface
  statistics; BGP neighbour session state (an enumeration, transformed to a number at the source)
  and per-AFI/SAFI route counts including the EVPN family; network-instance operational state;
  EVPN instance state; **VXLAN tunnel-endpoint state and statistics** — the tunnel endpoint, not
  the vxlan-interface, which carries no packet counters; bridge-table MAC counts; route-table and
  tunnel-table summaries; per-entry access-list statistics; and platform CPU, memory and
  application health. The topology view uses `andrewbmchugh-flow-panel` **1.20.1** with its SVG and
  panel YAML generated by a pinned `clab-io-draw` from the containerlab topology, and the join
  between a drawing cell and a metric series is **exactly two labels** — `source` (the containerlab
  node name) and `interface_name`, normalized `ethernet-1/49 → e1-49` at the collector. The
  targets file, the topology assets and the path register are generated from the same containerlab
  inventory in the same provisioning step. Logs stay out of scope.
- **Rationale**: the merge asserted this pipeline without having confirmed that the collector has
  an OTLP output at all; it does, and using it means the metric names the published dashboards
  expect are reproduced exactly, so the single-pipeline requirement costs nothing in portability.
  Two facts are load-bearing and easy to get wrong: there is **no `advertised-routes` leaf** in the
  per-AFI/SAFI subtree, so requirement text promising advertised route counts had to be rewritten;
  and the VXLAN interface object has **no counters**, so every per-service traffic statement is
  per-VTEP. The join contract is stated as a requirement rather than left to emerge from collector
  normalization, because collector-side label sanitisation is a moving target and the drawing cell
  ids are generated against the labels, not against the paths.
- **Evidence**: [evidence/06-telemetry-visualization.md](./evidence/06-telemetry-visualization.md)
  §1.1 (the OTLP output, verified present at 0.47.0, with its full option set), §1.2 (the pipeline
  recommendation and the rejected alternatives), §1.3 (the metric-naming trap and the settings that
  reproduce the published names), §1.4 (label derivation, and why the target must be named for the
  containerlab node), §1.5 (deployment shape), §2.1 (the recommended subscription table, and the
  absent `advertised-routes` leaf and absent vxlan-interface counters), §2.2 (enum handling),
  §2.3 (the event processors, including the interface-name normalization), §2.4 (encoding,
  `updates-only`, on-change and the shared server limits), §3 (native over standard-model
  telemetry), §4.1–§4.3 (the reference lab, the identifier scheme and metric join, and the
  generator flow), §4.5 (plugin pinning and access), §8.2 (the EVPN service-path view that replaces
  the SRv6 one), §9.1 (the draft requirement wording).
- **Measurement status**: the paths were generated against YANG `v25.10.3` in research and are
  **re-validated against `v25.7.1` at P0** (gate item G7 and the register's CI guard).
- **Alternatives rejected**:
  - *Scraping gNMIc's `prometheus` output with the collector instead of exporting OTLP.* Two scrape
    hops, with the collector reduced to relaying a scrape, which makes the "device series flow only
    through the single pipeline" criterion hard to prove.
  - *Scraping gNMIc's `prometheus` output with Prometheus directly* — what the reference lab does.
    There is then no collector in the device path at all, which is the exact pattern the
    single-pipeline requirement was written to forbid.
  - *Remote-write into Prometheus.* It loses the OTLP resource semantics and needs a Prometheus
    feature flag for no benefit here.
  - *Standard-model telemetry.* RD-08: the EVPN paths do not exist there and the traffic-rate leaf
    has no equivalent, so the headline signal would have to be reconstructed at query time.
  - *On-change as the default stream mode.* No published per-path support matrix exists, and both
    of the vendor's own reference labs use `sample` for every subscription including operational
    state. `sample` is the default; on-change is admitted per path only behind an acceptance check
    that subscribes, disturbs the fabric and observes the update.
  - *`updates-only` subscriptions.* Whether the device honours the flag is undocumented, and the
    initial synchronization is what the telemetry-health criterion depends on.
  - *A collector operator, or clustering with an external coordination store.* An early-version
    dependency and a second state-holding workload respectively, for a four-node lab; both are
    recorded as scale-out paths rather than adopted.
  - *Copying the reference lab's Grafana configuration.* It enables anonymous admin access, which
    FR-096 forbids.
- **Consequences**: FR-017, FR-086, FR-089, FR-094, FR-096, SC-034, SC-036, SC-037, NFR-003;
  D-36 and D-37 revised; PC-A-08 and PC-A-09 resolved.

### RD-12: The capability gate, rewritten

- **Decision**: FR-004's gate is thirteen items run against the pinned image and emulated types
  before any end-to-end test:
  **G1** gNMI Capabilities — the `srl_nokia-*` model set at the pinned release and JSON_IETF
  encoding; **G2** version and platform identity (`25.7.1`, `7220 IXR-D2L` and `IXR-D3L`);
  **G3** the platform feature set the constructs depend on (vxlan, evpn, anycast-gw, the acl
  features); **G4** gNMI Set with read-back and durable persistence through `auto-save`;
  **G5** commit-confirmed / transaction rollback of a rejected change; **G6** the MTU envelope
  (RD-10); **G7** Subscribe in `sample` mode, with an on-change probe; **G8** EVPN behaviour —
  Type 2, 3 and 5 exchanged through the route-reflecting spines, **including the `inter-as-vpn`
  check**, with "every session established and zero EVPN routes" recorded as the failure signature,
  and **an IPv6 anycast gateway with IPv6 Type-5 observed end to end**; **G9** access-list
  programming with keyed applied-side read-back in each direction plus the egress qualification;
  **G10** that the device-configuration layer's deviated schema still rejects the invalid
  configurations the platform relies on being rejected; **G11** an allocation claim round-trip;
  **G12** the exact JSON serialization the device returns for every rendered value, observed from a
  real Get **before any golden file is frozen**; **G13** what a managed-path deviation actually
  leaves observable under the policy the platform runs — whether a `Deviation` with reason
  `NOT_APPLIED` is visible for long enough to be asserted, or whether the layer reapplies first and
  the only durable witness is the restored device state — recorded as the observation that decides
  what the drift test may assert (SC-007, AD-34). The per-construct result is published as a
  read-only record the intent tier consults (FR-097).
- **Rationale**: a gate is only worth running if each item can fail for a reason the platform
  cannot work around. G8's two additions are the ones the merge could not have known to ask for: a
  route-reflecting spine that is not itself a tunnel endpoint drops the EVPN routes it should
  reflect unless `inter-as-vpn` is set, and the result looks exactly like a healthy fabric; and no
  published example exists of an IPv6 anycast gateway with IPv6 Type-5 on this platform, which
  makes it the first item to run rather than an assumption to build on. G12 exists because a golden
  file frozen against a guessed serialization form produces a permanent, silent idempotence defect.
  G13 exists because SC-007 says drift is "detected and restored" and the platform had assumed the
  detection leaves a `Deviation` an integration test can read: upstream's own revertive suite
  asserts only that the intent returns, and it is the *non*-revertive suite that turns revert off
  before it counts deviations. Whether a revertive `Deviation` is durably visible is an observation
  about the layer, not a property the platform may assume, so it is a gate item and not a test
  assertion.
- **Evidence**: [evidence/01-lab-platform.md](./evidence/01-lab-platform.md) §7 (the gate rewritten
  item by item, with the gnmic invocations for each), §7 "G10 — what the gate must NOT check any
  more"; [evidence/02-evpn-constructs.md](./evidence/02-evpn-constructs.md) §1.1 and §5.4;
  [evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md) §3.5.
- **Alternatives rejected**:
  - *Carrying the previous gate forward with the platform names swapped.* Half its items test a
    store and a forwarding database that do not exist, and none of its items tests the two things
    most likely to fail here.
  - *Deferring G12 until after the golden files exist.* That is the order that creates the defect.
  - *Letting the drift test assert a `Deviation` and marking the flake as environmental.* A check
    that fails for a reason the platform cannot name is worth nothing; G13 decides what the
    assertion is before the test is written.
  - *Treating a failed item as a documented limitation.* CR-007: a gate is never waived; the
    affected construct is reported unqualified and refused by name (FR-097).
- **Consequences**: FR-004, FR-097, SC-040, CR-007; delivery phase P0.

### RD-13: Two-sided read-back for every construct

- **Decision**: readiness for **every** construct — not only access lists — is set from a two-sided
  read-back (FR-100). Written side: the device configuration resource is applied, carries no
  deviation, and its content is present in the device's running datastore. Applied side: the
  device's **state** datastore, keyed to this service's own objects — network-instance
  `oper-state` (with `oper-down-reason` surfaced when it is down), subinterface operational state,
  vxlan-interface operational state, the `bgp-evpn` instance's operational state; for a `mac-vrf`,
  the remote VTEPs and multicast destinations present once at least two attachments exist on
  different leaves; for an `ip-vrf`, the Type-5 routes present in the route table with `bgp-evpn`
  as their owner; and for an anycast gateway, the IRB's operational and anycast-gateway state. A
  status condition names the missing invariant.
- **Rationale**: this closes GAP-6, which existed because the merge stated two-sided verification
  only for access lists and left every other construct asserting whatever its render happened to
  check. On this platform the distinction is sharp and cheap to honour: the running datastore and
  the state datastore are separate, both are readable over the same gNMI session, and the device
  reports its own reason when an instance is down. "Accepted into running but never programmed" is
  a real failure mode here, and it is visible only as the absence of state.
- **Evidence**: [evidence/02-evpn-constructs.md](./evidence/02-evpn-constructs.md) §7.1 (what
  "running" and "state" mean precisely on SR Linux), §7.2 (the per-construct convergence evidence,
  path by path), §7.3 (datapath-programming evidence);
  [evidence/03-acl.md](./evidence/03-acl.md) §7 (the same discipline for access lists, and its
  note that stating it only for access lists was GAP-6).
- **Alternatives rejected**:
  - *Written-side readiness for everything but access lists.* It is the inconsistency GAP-6 names,
    and it would leave the construct with the weakest device feedback as the only one with the
    strongest check.
  - *A single fabric-level health check standing in for per-service readiness.* It cannot say which
    service is not Ready, and it passes while a service is missing.
- **Consequences**: FR-100, FR-042, CR-001, SC-012; D-16 revised.

### RD-14: The six recorded gaps are closed by requirements, not by convention

- **Decision**: each gap the merge recorded is closed by a requirement rather than by a practice.
  **GAP-1** → **FR-097**: qualification is recorded per construct and per gated property, and an
  unqualified one is refused at interpretation, by name, before anything is claimed or created.
  **GAP-2** → **FR-046** and **FR-048**: one provenance record — the annotations on the `Network` —
  with a `MigrationPlan` referencing it and recording the construct alongside the source
  vocabulary. **GAP-3** → **FR-101**: three candidate writers, disjoint key sets, a fixed emission
  order, and the provider stamping its metadata on the device configuration resources so that only
  two actors write the `Network`'s metadata at all. **GAP-4** → **FR-043**: an object with a
  deletion timestamp still holds its bindings until it is gone, the refusal says the holder is
  being removed, and withdrawal is ordered binding-before-filter-before-owner. **GAP-5** → closed
  by RD-04, by narrowing: the kind the tier could have written no longer exists and the writer Role
  grants `networks.fabric.agentic-netops.io` alone. **GAP-6** → **FR-100** (RD-13).
- **Rationale**: a gap recorded in a specification and left as a note is a gap the implementation
  will close by accident, differently in each place. Each of these is a seam between two actors,
  and a seam is exactly where an unwritten rule becomes two incompatible assumptions.
- **Evidence**: the gaps and their closures are listed in [spec.md](./spec.md) §Gaps closed by the
  retarget; the supporting findings are
  [evidence/03-acl.md](./evidence/03-acl.md) §5 and §7 (GAP-4, GAP-6),
  [evidence/04-srv6.md](./evidence/04-srv6.md) §6 (GAP-5) and
  [evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md) §6 (GAP-3, once the provider
  is first-party and stamps the `Config`).
- **Alternatives rejected**:
  - *Leaving the gaps open for the implementation to settle.* That is what produced them.
  - *Closing GAP-5 by policing the tier's requests rather than its Role.* A denial that is provable
    by enumerating permissions is worth more than one that depends on a validator running.
- **Consequences**: FR-043, FR-046, FR-048, FR-097, FR-100, FR-101.
- **Left for `/speckit-clarify`**: five defaults were chosen where the evidence supported more than
  one answer — the access-list priority direction, refusing an unqualified construct at
  interpretation, the enforcement probe living in acceptance, the trigger for the allocation
  fallback, and the default management address space. Each is a live requirement as written and is
  listed in [spec.md](./spec.md) §Clarification candidates.

### RD-15: The inherited acceptance record becomes preventive requirements

- **Decision**: the disputed approvals travel with this specification, and each becomes a
  requirement that makes its failure mechanically harder to repeat. **NFR-013 (evidence
  integrity)**: every gate and acceptance proof is machine-captured by the run that claims it —
  command, UTC timestamp, exit status, image digest and cluster/lab identity recorded together with
  the raw output; a hand-authored or post-edited proof file is non-conforming; and a check counts
  only after it has been shown to **fail** on a stock fabric that does not carry the thing it
  checks for. **NFR-003 strengthened**: placeholder and synthetic digests are forbidden, the pin
  check resolves every digest against its registry, and mutable references — a branch, `latest`, a
  floating minor tag — are forbidden wherever a reference can appear, explicitly including the
  device schema resource's own repository refs, the Grafana plugin and the generator image.
  **The Constitution Check is re-evaluated for a greenfield repository**: no deployment exists
  here, so Principles V and VI are not "FAIL — carried"; they are PASS-by-obligation, with the
  recorded defects named as the reason NFR-003 and NFR-013 exist at all.
- **Rationale**: four specific ways this platform's shape has already reported success it had not
  observed are on the record — synthetic digests; a profile approved against an image with no gNMI
  server; readiness files contradicted by genuine captures in the same folder, including one for an
  object that never existed; and an applied-side check that passed on an empty fabric because it
  was device-wide. Three of the four are answered by a rule about *evidence*, not about *network
  configuration*, which is why they are non-functional requirements rather than notes.
- **Evidence**: the record and its contradictions are in [spec.md](./spec.md) §Inherited acceptance
  record; the fourth contradiction — that the upstream control plane was never actually installed —
  is [evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md) §0.
- **Alternatives rejected**:
  - *Recording the disputes as history and moving on.* The registry that repeats an approval
    without its contradiction is the failure Principle I names.
  - *A review step instead of a captured-evidence rule.* Review is what produced the contradictions
    that are on the record; the negative control is the part a reviewer cannot supply.
  - *Marking Principles V and VI FAIL in a repository with no deployment.* It would be a false
    report in the other direction, and it would make the gate meaningless when a deployment does
    exist.
- **Consequences**: NFR-003, NFR-013, SC-040, CR-006, CR-007; the Constitution Check in
  [plan.md](./plan.md).

---

## 12. Clarification decisions *(plan refresh, 2026-09-20)*

The clarify session of 2026-09-20 ([spec.md](./spec.md) §Clarifications) added FR-102…FR-105,
SC-042 and SC-043 and rescoped SC-030. The answers are the operator's and are not re-opened here;
what follows is **how** each is built, in the same form as every other entry, numbered `CD-01`…
so that the retarget's `RD-` numbering stays closed at fifteen. `CD-06` is not a clarification: it
records the operator's planning instruction of the same day that the last deliverable is a
repository README modelled on the predecessor's, with the predecessor's recorded walkthrough re-shot
on this platform.

Three statements in the pre-clarification design **contradicted** the clarified specification and
are corrected by this pass rather than carried: a target-unreachable *timeout* during deletion
(`contracts/reconciliation.md` Rule 8, `data-model.md` §19 — now CD-02), a caller-asserted
`principal` field on the operator entrypoint (`contracts/supervisor-http.md`, `quickstart.md` §11 —
now CD-01), and a runtime "lease fallback" when the allocation authority is unreachable
(`contracts/kuid-claim-profiles.md` §4 — now CD-03).

### CD-01: Operator authentication is HTTP Basic against one generated Secret, verified by the supervisor *(FR-102, SC-042)*

- **Decision**: the supervisor verifies an `Authorization: Basic` header on every route that can
  reach the pipeline — `POST /agent/prompt/stream`, `GET /suggested-prompts`,
  `GET /transport/config` — against the Secret `operator-credentials` in `agentic-netops-agents`,
  mounted read-only as a volume (the supervisor keeps **no** service-account token). The Secret
  holds `username` (default `operator`, overridable at provisioning by `OPERATOR_USERNAME`) and
  `password`, which is **always generated** by the provisioning script's secret step and is never
  accepted from the environment, a flag or a file — that is what "never defaulted" means in
  practice. `off.sh` removes it with the other generated Secrets. The two health routes stay
  unauthenticated: they are wired to kubelet probes, a probe credential would be a credential
  literal in a manifest, and neither route creates a thread, calls a model or claims anything. The
  request body's `principal` field is **removed**; the schema is strict, so a request that still
  carries it is refused `400` naming the field rather than having it silently ignored. The
  principal on every audit event, on both `Decision` records and in the
  `agentic-netops.io/intent-principal` annotation is the authenticated username. The chat surface
  shows a login form, keeps the credentials in memory only — never `localStorage`, never a cookie —
  and sends the same header; the route count stays at five. The Kind port mappings for the chat
  surface and the supervisor listen on `127.0.0.1` only. A refused request produces a structured log
  line and increments `intent_auth_refusals_total`; it produces **no** `AuditEvent`, because an
  audit event without an authenticated principal would falsify SC-042's reconciliation. Comparison
  is constant-time and a failed attempt costs a fixed delay.
- **Rationale**: FR-078 and SC-030 are only as good as the principal they record, and the
  pre-clarification contract let the caller type it. Basic against a generated Secret is the
  smallest mechanism that makes the principal a fact the platform established: no new route, no
  session store, no token lifecycle, no second identity system, and the verification sits in front
  of the graph so "before it reaches the pipeline" is structural — the handler returns before a
  thread identifier is minted.
- **Alternatives rejected**:
  - *A login route issuing a session token.* A sixth route, a token store and an expiry policy, for
    one operator on a loopback port. Recorded as the revisit trigger for multi-operator use.
  - *An authenticating reverse proxy in front of both surfaces.* A new pinned image and a new
    trust hop, and the supervisor would then trust a forwarded header — a name something else
    asserts, which is what FR-102 forbids one layer down.
  - *Kubernetes TokenReview against operator ServiceAccount tokens.* It would hand the supervisor
    an API credential it is specified not to hold.
  - *Keeping `principal` in the body as a display name.* Two principals per request is how the
    wrong one ends up in the audit stream.
- **Production delta, stated**: these are lab credentials over loopback HTTP and are **not**
  production-safe (FR-019). Production fronts both surfaces with an identity provider and TLS.
- **Consequences**: FR-102, SC-042, FR-078, SC-030; C-11, C-15, C-16, C-18; R-38.
- *Amended by AD-66*: the counter is `agentic_netops_agent_auth_refusals_total` — every tier metric
  carries the one literal prefix of `data-model.md` §21.

### CD-02: Deletion with an unreachable target blocks; the only exit is an annotated, admission-guarded force-release *(FR-103, SC-043)*

- **Decision**: the `Network` finalizer removes configuration from every reachable target, in the
  existing dependency order, and then **waits**. A new condition `Deleting=True` carries reason
  `TargetUnreachable` and a message naming each unreachable target; every claim stays bound. There
  is no deadline, no retry budget that ends in release and no timer of any kind on this path — the
  reconciler requeues at the re-verification interval and completes on its own when the target
  returns and the removal has been **read back** from it. The break-glass is the annotation
  `fabric.agentic-netops.io/force-release: "<reason>"`; an empty reason is refused with an Event. On
  honouring it the provider publishes a `Warning` Event `ForceReleased`, appends a finding to
  `Fabric.status.findings[]` — type `StaleConfigurationPossible`, the service's namespace, name and
  UID, the node, the identifiers released, the device object names the service had rendered there,
  the stated reason and the time — then releases the claims and removes the finalizer. The finding
  outlives the `Network`. The `Fabric` reconciler's scheduled re-verification reads the named objects
  on that node and removes the finding, with an Event, only after a read that shows them absent from
  both the running and the state datastore. While a finding is open, a render onto that node that
  would produce one of the named objects is refused `OwnershipConflict`, so a re-claimed identifier
  cannot be mistaken for the stale one. **The intent tier cannot force-release**: a
  `ValidatingAdmissionPolicy` denies any request by either tier ServiceAccount that sets or changes
  that annotation, which keeps the break-glass out of reach of the identity that reads operator text.
- **Not assumed**: what the device-configuration layer does with a `Config` that was deleted while
  its target was unreachable, once the target returns. The likely outcome — the layer recomputes
  intent without it and removes the configuration — would clear the finding by itself. It is
  **observed** in P3's target-failure test, and the finding is correct either way.
- **Rationale**: an identifier released while a device still carries it is a collision waiting for
  the next service, and it is silent. Blocking forever is honest and cheap; a timer converts an
  outage into a correctness bug. The force-release is for the device that never comes back, and its
  cost — a possible stale object — is written where it cannot be lost with the service object.
- **Alternatives rejected**:
  - *A target-unreachable timeout*, as the pre-clarification Rule 8 had it. The clarification forbids
    it by name.
  - *Force-finalizer removal with `kubectl patch`.* It works on any object and records nothing; it
    remains possible for a cluster admin, and the runbook says what it orphans, but it is not the
    documented procedure.
  - *Recording the finding as an Event only.* Events expire; the finding must outlive the object.
  - *RBAC instead of admission to keep the tier out.* RBAC cannot distinguish one annotation from
    another on a resource the tier may already patch.
- **Consequences**: FR-103, SC-043, FR-010, NFR-011; C-05, C-15, C-20; R-39.

### CD-03: A failed allocation gate stops provisioning; the substitute is a recorded, lock-file-selected, first-party allocator that never coexists *(FR-104)*

- **Decision**: `provision.sh` exits non-zero naming gate item **G11** when the claim round-trip
  fails, having installed nothing above it, and offers no flag that selects another allocator. The
  allocation authority is part 6 of the compatibility set and is selected **only** by the lock
  file: `allocationAuthority.kind: kuid | first-party`. `first-party` is accepted only when the
  same entry carries `decisionRecord` — a committed `docs/decisions/allocator-substitution.md`
  signed off by the operator — and `failedGateEvidence`, the path and SHA-256 of the run-captured
  G11 failure it answers (NFR-013); `make verify-pins` fails if either is missing or does not
  resolve. The substitute's kinds, `IdentifierPool` and `IdentifierClaim`, live in
  `fabric.agentic-netops.io/v1alpha1` with structural schemas, in their own namespace
  `agentic-netops-allocation`; a claim's `spec` is immutable by CEL and its allocated value is
  reported in `status.value`, so the tier's create-and-delete-never-update Role, the claim profiles
  and the assignment contract are unchanged above the seam. `make verify-compat` asserts
  **exactly one**: with `kuid`, no `IdentifierPool`/`IdentifierClaim` CRD is installed; with
  `first-party`, no `*.be.kuid.dev` APIService exists. Provisioning prints a warning naming the
  substitute on every run. The contract is fixed now; the implementation is built **only** on a
  recorded decision. The pre-clarification "lease fallback when the authority is unreachable" is
  **removed**: an unreachable authority is a bounded retry and then a terminal, named failure of
  that request with nothing claimed.
- **Rationale**: the fallback was always named (R-31, RD-03); what was missing was who decides and
  where it may live. A script that picks an allocator on its own makes the choice invisible, and a
  substitute served in the upstream group is a look-alike API, which FR-098 exists to prevent.
- **Alternatives rejected**:
  - *Automatic fallback on gate failure.* Forbidden by FR-104, and it would make two labs built
    from one lock file differ.
  - *Serving the substitute in `*.be.kuid.dev` so nothing above changes.* FR-098.
  - *Building the substitute now, in case.* A second allocator to test and keep honest before any
    evidence says the first fails.
  - *A provisioning flag instead of the lock file.* A flag is not part of the compatibility set and
    is not checked by CI.
- **Consequences**: FR-104, FR-013, FR-017, FR-098; C-01, C-04, C-13, C-21; R-31 revised.

### CD-04: The submitted-spec hash is taken from the server-side dry-run result, stamped once, and only ever read *(FR-105, SC-030)*

- **Decision**: the tier-owned annotation `agentic-netops.io/intent-submitted-spec-sha256` is the
  SHA-256 of the canonical JSON (keys sorted, no insignificant whitespace, numbers in shortest
  round-trip form) of the `spec` **as the server-side dry-run returned it** — after pruning and
  defaulting, so it is the form a later read returns. The dry-run carries every other key; the
  apply is the dry-run object plus exactly this one annotation, and a unit test asserts the two
  differ in that key only. It is stamped once: the tier never updates a service. On every status or
  removal request the deployer re-reads the object. Absent with no tier removal recorded for it:
  *deleted outside the tier*. Present with a different hash: *modified outside the tier*, and the
  report is built from the live object. Either way the tier emits an `AuditEvent` of type
  `out_of_band` and increments `intent_out_of_band_changes_total{change="modified"|"deleted"}`, and
  writes **nothing**. A removal request against a modified service is not executed by the turn that
  detects it: the modification is stated at that request's first confirmation and the removal
  proceeds only through both confirmations.
- **Rationale**: hashing what the tier *sent* would report every defaulted field as an edit. The
  provider never writes `spec` and no mutating webhook exists on the group, so the dry-run form is
  the persisted form. Detect-and-report keeps the tier out of a fight with a human who used
  `kubectl` on purpose, and keeps Principle II intact: no change without two confirmations,
  including a "repair".
- **Alternatives rejected**:
  - *Revert to the remembered spec.* An unconfirmed fabric change; forbidden by the clarification.
  - *Compare against the checkpointer's copy.* The conversation is not the record (FR-105), and the
    copy dies with the thread volume.
  - *`metadata.generation` instead of a hash.* It says something changed, not whether it was the
    tier, and it cannot be compared after a delete and re-create.
  - *A provider-written hash.* The provider stamps nothing on the `Network` (FR-101).
- **Consequences**: FR-105, FR-101, SC-030; C-14; R-40.
- *Amended by AD-66*: the counter is `agentic_netops_agent_out_of_band_changes_total{change}` — every
  tier metric carries the one literal prefix of `data-model.md` §21.

### CD-05: Access-list priority direction — no design change *(FR-039)*

- **Decision**: confirmed as already designed — ascending priority number, first match wins,
  `sequence-id := priority` with no inversion (RD-05). Recorded so the confirmation is traceable.
- **Consequences**: none; FR-039, `contracts/acl-render-contract.md` unchanged.

### CD-06: The last deliverable is the repository README, modelled on the predecessor's, with the same walkthrough re-recorded on SR Linux *(operator instruction, 2026-09-20)*

- **Decision**: delivery ends with phase **P12**, whose last task writes `README.md` at the
  repository root as the SR Linux counterpart of `/root/agentic-netops/README.md` — the same
  sections in the same order (title and tagline, badges, the closed-loop introduction, **Demo**,
  **The lab** with its four figures, *What works and what does not*, **What you get**,
  **Prerequisites**, **Quickstart**, **Known limitations**, **Repository layout**, **Policies
  enforced in CI**) — with every platform fact replaced by this platform's and **none carried over
  unobserved**. The Demo is the same recording re-shot: one silent 1920×1080 take of the operator
  console provisioning **a `vlan`, then an `ip-vrf` with its prefix, then a `mac-vrf` stretched
  across both leaves**, each confirmed twice, each reported deployed, each then proven in the
  terminal with `kubectl` (the `Network` `Ready`, its events, its spec) and **inside the SR Linux
  leaf** — and cut to **6×** by dropping frames, never blending. The predecessor's prompts are kept
  word for word except where the site inventory forces a change:

  | # | Predecessor (SONiC) | This platform (SR Linux) |
  |---|---|---|
  | A | `Provision a vlan 170 on leaf01 ethernet1 for tenant acme` | `Provision a vlan 170 on leaf01 ethernet-1/1 for tenant acme` |
  | B | `Deploy an ip-vrf between leaf01 wan1 and leaf02 wan1 for tenant initech with prefix 10.53.0.0/24` | `Deploy an ip-vrf between leaf01 ethernet-1/1 vlan 253 and leaf02 ethernet-1/1 vlan 253 for tenant initech with prefix 10.53.0.0/24` |
  | C | `Extend vlan152 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue` | `Extend vlan152 as a mac-vrf across leaf01 ethernet-1/1 and leaf02 ethernet-1/1 for tenant blue` |

  B changes shape because this site has no `wan1`: both access ports are `ethernet-1/1` and a
  routed attachment is a VLAN subinterface of it. The wording is validated against the site
  inventory and the offline translator in the smoke step and frozen in `docs/DEMO_VIDEO.md` before
  the take; identifiers are single-use. The leaf proof replaces the predecessor's `redis-cli`,
  `vtysh` and `bridge` reads with read-only `sr_cli` `info from state` reads of the **same facts**:
  the network instance and its oper-state, the bridged or routed subinterface, the vxlan-interface
  and its VNI, the EVPN instance, the Type-5 route in the `ip-vrf` route table, and the remote VTEP
  on both leaves for the stretched `mac-vrf`. The tooling is ported, not re-invented:
  `testautomation/video/record.py` (the driver, with its framing assertions and `--smoke` mode) and
  `accept.py`, `scripts/video-accelerate.sh`, and `docs/DEMO_VIDEO.md` as the take procedure.
  Acceptance is machine evidence, never a screenshot: `accept.py` re-verifies every "deployed"
  claim from `kubectl` JSON and writes
  `docs/media/agentic-netops-srl-intent-tier-demo-evidence.json` with `accept_pass: true`, carrying
  the NFR-013 fields. A take that fails acceptance is deleted, not embedded. One thing is new
  relative to the predecessor's take: the console now requires a login (CD-01), so the driver logs
  in **before** recording starts and the recording never shows a credential (SC-031).
- **Rationale**: the predecessor's README is the project's public face and its recording is the
  shortest proof that the loop closes. Re-shooting the identical scenario makes the two
  repositories comparable frame for frame, and doing it **last** means the README describes a
  platform that has passed P11 rather than one that is expected to.
- **Alternatives rejected**:
  - *Writing the README first, as a statement of intent.* Principle I: it would claim results
    nothing has produced, and the constitution's sync report already defers the README for that
    reason.
  - *Re-using the predecessor's recording or its figures.* They show a different network operating
    system.
  - *A narrated or captioned cut.* The predecessor's is silent, uncaptioned and uncut before
    acceleration; "exactly the same" includes that.
  - *Hosting the video in the repository.* The predecessor embeds a GitHub user-attachment asset so
    the clone stays small; the same is done here, which makes the upload the one manual,
    outward-facing step and leaves it to the operator.
- **Open, and not invented**: the GitHub repository slug — and therefore every badge URL and the
  asset URL — does not exist yet (this tree is not a git repository). P12 resolves badges from the
  real `origin`; a CI or merge-queue badge appears only if that workflow exists.
- **Consequences**: C-22, P12, `contracts/readme-and-walkthrough.md`, `quickstart.md` §28; the
  constitution's pending README sync item (MTU, pinning and IPv6 gateway facts) is discharged
  there; R-41, R-42.

## 13. Analysis decisions *(cross-artifact analysis, 2026-09-20)*

The consistency analysis run after task generation found places where the specification, the plan
and the task list disagreed with each other or with the constitution. None reopens an operator
decision: RD-01…RD-15 and CD-01…CD-06 stand as written. What follows is how each finding is
closed, numbered `AD-01`… so that the earlier series stay closed.

### AD-01: The model-provider Secret is merged, never replaced, and a declared gateway needs a base URL *(FR-106, CR-008)*

- **Decision**: `llm-provider` is generated from four inputs — model, API key, base URL and an
  optional gateway name. Declaring a gateway without a base URL is refused before any tier workload
  is created. Re-provisioning reads the existing Secret and **merges**: an input that is absent
  from the run keeps its stored value; clearing the base URL takes an explicit
  `AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=1`. Provisioning prints, and every agent logs at start-up, the
  endpoint model calls will use. An agent whose Secret declares a gateway without a base URL refuses
  to start.
- **Rationale**: the constitution requires both rules and only the quickstart carried them. The
  predecessor lost its base URL exactly this way on 2026-09-03: the regeneration applied a whole
  replacement Secret from a shell that had set the model and the key but not the URL, every model
  call then went to the library's default endpoint where the gateway's key was rejected, and the
  tier kept answering only through its deterministic fallbacks. A gateway cannot be detected from a
  model name, so it is declared; an undeclared one is still protected by the merge and by the
  printed endpoint.
- **Alternatives rejected**: *inferring a gateway from the model prefix* — the prefix names a
  protocol, not an endpoint; *always requiring a base URL* — a provider's own hosted API has none to
  give, and a made-up one is worse than the default named as such.
- **Consequences**: FR-106, CR-008; `contracts/kubernetes-objects.md` (`llm-provider`);
  `quickstart.md` prerequisites and the provider-switch step, whose whole-object `kubectl apply`
  is replaced by a merge patch.

### AD-02: Scheduled re-verification is a requeue of the same read-back, five minutes by default *(FR-107, SC-044)*

- **Decision**: both reconcilers requeue every Ready object at `REVERIFY_INTERVAL` (default 5 min)
  and re-run the two-sided read-back of RD-13 unchanged. A pass advances `status.lastVerifiedTime`
  and a timestamp metric; a miss sets `Ready=False` with the same reason codes as first convergence.
  It writes no `Config` when nothing differs, so it cannot disturb NFR-001.
- **Rationale**: constitution Principle I names the schedule and its order of magnitude. The design
  already depended on it — the force-release finding of CD-02 clears on "the `Fabric` reconciler's
  scheduled re-verification" — without any requirement saying that it exists, how often it runs or
  how a stalled one would be noticed.
- **Alternatives rejected**: *relying on the 15 s resync* — a resync re-renders and compares
  `Config`s; it does not read device state, and reading every applied-side path of every service
  every 15 s would spend the shared gRPC session budget of R-33; *a separate verifier controller* —
  a second component with its own opinion of readiness is what RD-13 exists to avoid.
- **Consequences**: FR-107, SC-044, CR-001; `contracts/reconciliation.md` Rule 5 and Rule 7;
  `data-model.md` §3a, §25; an alert on a stalled schedule.

### AD-03: FR-007 governs the platform without exception; the tools that check it are bounded by FR-108

- **Decision**: RD-02 is unchanged — one southbound, no executor, no host-side component on any
  change path. What the specification did not say is that the capability gate, fault and drift
  injection and the walkthrough's read-only proofs necessarily touch a device outside that path:
  G4 and G5 *test* raw gNMI Set and rollback, drift injection *is* an out-of-band write, and the
  leaf proof *is* a console read. FR-108 names them and bounds them: run-captured, scratch or
  declared-fault only, self-removing with the removal read back, lab operator credentials, never a
  long-running process, never reachable from the tier, and nothing the platform does depends on
  them. A CI boundary check fails a device client invoked from anywhere else.
- **Rationale**: a gate that must be run and a requirement that forbids running it produce one of
  two outcomes, both bad — a quiet exemption nobody wrote down, or a gate that is never run. The
  predecessor's recorded failure was a host-side component that the platform's *outcomes* depended
  on; FR-108's last condition is precisely the line between that and a test.
- **Alternatives rejected**: *running the gate as an in-cluster Job* — it moves the client, not the
  problem: FR-015 makes the device-configuration layer the only writer, so a gate Pod issuing a raw
  Set needs the same carve-out and additionally a third copy of the device credentials inside the
  cluster; *driving the gate's scratch configuration through `Config` objects* — G4, G5 and G10
  exist to qualify the layer's own substrate and cannot be qualified through it.
- **Consequences**: FR-007 reworded, FR-108 new; `contracts/reconciliation.md` Rule 5;
  `make verify-boundaries` gains the device-client check.

### AD-04: The tier's verb sets are stated exactly *(FR-075)*

- **Decision**: FR-075 and User Story 6 scenario 3 now state what
  `contracts/kubernetes-objects.md` §Identity contract always granted: the deployer identity —
  `get, list, watch, create, update, patch, delete` on `networks` plus Event creation in the intent
  namespace; the allocator-agent identity — `get, list, watch, create, delete` on the two claim
  resources in the allocation namespace, never `update` or `patch`. Every other tier workload holds
  no permission.
- **Rationale**: label-selector rollback (D-32) and removal (FR-069) need `delete`, and server-side
  apply needs `patch`. A requirement that says "create, read and update" makes the denial probe
  either fail the design or be written loosely; an exact allow-list lets the probe assert that
  everything else is denied.
- **Consequences**: FR-075, US6 scenario 3; the role manifest and the probe suite name the verbs.

### AD-05: A first-party image is pinned by its build inputs and identified per run *(NFR-003)*

- **Decision**: `data-model.md` §26. Every `FROM` by registry-resolved digest and every dependency
  lock file by hash, in the lock file; the image tagged with the content hash of its build context,
  never-pull, never `latest`; the built image ID written to the run's evidence and checked against
  the running workloads by `make verify-compat`. The provider image follows the same rule as the
  six tier images.
- **Rationale**: "resolve every digest against its registry" cannot hold for an image that exists
  in no registry, so the pin check could only ever fail or carry an unwritten exemption — and an
  unwritten exemption for the tier images is the predecessor's `:latest` finding. Writing the built
  ID into the lock file instead would rewrite the lock on every build, and a pin that changes every
  day is one nobody reads.
- **Alternatives rejected**: *a local registry on the host* — a standing host container, which the
  placement boundary exists to avoid, and a digest there proves only that the image was pushed;
  *requiring bit-for-bit reproducible builds* — desirable, not yet demonstrable across three
  toolchains, and not needed for the property that matters: the workload runs what this tree built.
- **Consequences**: NFR-003 extended; `contracts/crd-api.md` §Version contract; R-43.

### AD-06: `Fabric.spec.maintenance[]` is the declarative administrative-state knob

- **Decision**: the field the quickstart already used is defined — `{node, interface,
  adminState: disable}`, validated against the inventory, rendered by the fabric reconciler as the
  interface's `admin-state` in the priority-10 `Config`, registered in the path register.
- **Rationale**: the link-failure step of the acceptance suites needs a way to take a link down that
  is not a device session. Without the field the structural schema rejects the quickstart's patch,
  and the only remaining way to fail a link is from the host.
- **Consequences**: `data-model.md` §3a, `contracts/crd-api.md`; the quickstart's object name is
  corrected to `fabric01`.

### AD-07: One table of default bounds

- **Decision**: `data-model.md` §25. The control-plane retry values are Rule 7's, unchanged; the
  intent-tier values are the predecessor tier's defaults, carried with the rest of that tier
  (D-20): 3 iterations, a 300 s deadline, 60 s worker calls, 210 s for the deployer, 2 retries,
  a 150 s convergence timeout. Start-up asserts `convergence < deployer call < deadline`.
- **Rationale**: FR-053, FR-067 and FR-073 each named a bound without a value, so their tests had
  nothing to assert and SC-023's five minutes had nothing to be consistent with.

### AD-08: Delivery order — the boundary is proven inside the tier phase, after the control plane

- **Decision**: the plan's phase *numbers* are stable and P1 keeps its number, but the order in
  which phases are **executed** is the one the quickstart and the task list already use: P0, P2, P3,
  then P1 as the first step of the tier phase, then P6 onward. The invariant the ordering existed
  for — no agent workload before every denial is observed — is unchanged and is enforced by the
  provisioning script, which refuses to create a tier workload until the probes pass. The three
  qualifications P0 names beside the gate (the transport's TLS key names, the OTLP resource shape,
  and that `ValidatingAdmissionPolicy` is served) run in P0 as the plan says.
- **Rationale**: the admission-policy probe needs a `Network` CRD, the NetworkPolicy probe needs the
  real management CIDR, and a control plane that is complete and useful with no tier present is
  NFR-006. Building the boundary first bought nothing those did not already require.

### Second pass *(re-run of the analysis, 2026-09-20)*

The same analysis, re-run after `AD-01`…`AD-08` were applied, found no constitution conflict and
every live requirement covered by a task, and thirteen smaller findings. Two needed a decision and
were put to the operator the same day; they are marked *operator*. RD-01…RD-15 and CD-01…CD-06
still stand as written.

### AD-09: The provider adopts or makes the VNI claims of a `Network` that arrives without the tier *(FR-109, SC-045 — operator)*

> **Amended by AD-42** (operator decision, 2026-09-21): a tier VNI claim is adopted on correlation
> label, deterministic claim name **and** value — the name scheme below, which the allocator now
> uses too — and no longer on label and value alone.

- **Decision**: before anything is rendered, the `Network` reconciler resolves every `l2vni` and
  `l3vni` to a bound claim. It **adopts** the claim that carries the object's correlation label and
  reports exactly that value — the tier's — and otherwise **claims the stated value** from the VNI
  index through the one `pkg/kuid` seam, under the deterministic name `<namespace>.<name>.<role>`,
  labelled with the object. The allocation authority arbitrates: a value held elsewhere, or outside
  the allocation band, is `Accepted=False/AllocationConflict`, nothing is rendered, and no other
  value is tried. Both kinds of claim are recorded in `status.claimRefs` and released by the
  finalizer after the read-back. A named VLAN is claimed on neither path, as before.
- **Rationale**: the reconciliation contract made "every claim bound" a dependency and made the
  finalizer release claims, while the only claim *creator* in the design was the tier's allocator
  agent. User Story 2 runs with no tier, so its tests asserted on claims nothing created, SC-043
  could not be measured there, and a hand-authored VNI inside the band could later be handed out
  again by the authority. FR-012 says the authority owns VNI allocation; this makes that true on
  both paths.
- **Alternatives rejected**: *examples ship their own claim manifests and the webhook refuses an
  unbacked VNI* — pushes allocation bookkeeping onto whoever writes YAML and makes a bare `Network`
  unusable; *a cross-`Network` uniqueness webhook with hand-authored VNIs kept outside the band* — a
  second arbiter beside the authority, and an exception to FR-012.
- **Not assumed**: that `kuid-server v0.0.13` binds a claim for a stated value and refuses a second
  one. Gate item G11 is widened to observe both, with a negative control (R-44, Open item 15). A
  failure is a G11 failure and takes FR-104's path.
- **Consequences**: FR-109, SC-045; `contracts/kuid-claim-profiles.md` §8 and the provider's
  `genidclaims` verbs in §5; `contracts/reconciliation.md` Rule 3 and Rule 8; `data-model.md` §18
  (`AllocationConflict`) and §20; tasks T170–T172; `make test-provider-claims`.

### AD-10: Two ranges, two names — the device range and the allocation band

- **Decision**: "VNI band" means the *allocation band* — the VNI index's own range, 10000–20000 by
  default — everywhere. The `1..65535` limit that follows from `evi := vni` is the *device range*.
  The CRD's CEL rule enforces the device range; the translator enforces the allocation band for a
  request, and the authority enforces it for a `Network` applied with cluster tooling (AD-09).
- **Rationale**: one contract row called the device range "the VNI band", and a negative fixture
  was described as "an out-of-band VNI" — which also collided with FR-105's "out-of-band change".
  Two fixtures could not say which range they tested.

### AD-11: One first-party group for fabric, service intent and allocation kinds; the `MigrationPlan` group is the only other *(operator)*

- **Decision**: nothing moves. `fabric.agentic-netops.io` carries `Fabric`, `Network` and the
  conditional `IdentifierPool`/`IdentifierClaim`; the optional `MigrationPlan` stays in
  `agentic-netops.io/v1alpha1` as `contracts/crd-api.md` fixes it. FR-013 now says that group is the
  only other one there may be, and FR-104 and the plan stop saying "the single first-party group".
- **Alternative rejected**: moving `MigrationPlan` into the fabric group — it is not fabric or
  service intent, it is optional, and the move would touch a contract, the tree and two tasks to
  make a sentence literally true.

### AD-12: Exactly one pin exception is admitted *(NFR-003, CR-006)*

- **Decision**: the recorded allocator substitution of FR-104 — warned by name on every provisioning
  run, its decision record being its remediation plan — is the only exception. The lock file has no
  field in which another could be declared; one that tries fails `make verify-pins`.
- **Rationale**: "any exception MUST be warned" had a mechanism for one exception and silence about
  the rest, which left room for a quiet second one — the predecessor's failure exactly.

### AD-13: The drift policy has no default *(FR-015)*

- **Decision**: the provider reads `DRIFT_POLICY`, refuses to start when it is unset or unknown,
  and states the policy on every `Config`. Lab provisioning sets `revertive`. The runbook states
  what a production deployment must choose instead.
- **Rationale**: "MUST NOT be inherited from the lab" had no mechanism; a default *is* inheritance.
- *Amended by AD-17*: the value set is closed and has one member, `revertive`. What the runbook
  tells a production deployment is therefore that it states `revertive` itself, and what changing
  FR-015 to admit another value would take.
- *Rationale corrected by AD-34*: what that change would take is the second value's repair
  procedure, status shape, tests and runbook entry — not a constitution amendment.

### AD-14: First-party workloads log one JSON object per line *(NFR-014)*

- **Decision**: `data-model.md` §27 — timestamp, level, component, message, resource identity and
  correlation identifier where they exist, redacted under FR-079. Scripts keep a level and phase
  prefix. The credential scan's harness also asserts the shape.
- **Rationale**: constitution Principle IV says logs MUST be structured. The plan attributed that
  to NFR-005, which says something else, and no task carried it — the same class of gap as AD-01
  and AD-02.

### AD-15: Closures that needed no design decision

- The plan's three statements about the **force-release admission probe** (P1, P3's gate, the
  Admission row) predated AD-08 and placed the probe at P3's gate, before the identities it probes
  exist. They now say what T073 and T150 already do: P1's boundary step, executed after P3, and
  again at P11.
- **Telemetry cardinality and stale series** get an outcome (the edge case), a register-guard
  assertion (T128) and a live check (T134), which R-09 had promised.
- The **substitute allocator controller** still has no task, on purpose; the task list now says
  so, and that `/speckit-converge` adds it after a recorded decision.
- `intent-translator` is built through the same image build as every other first-party image (T097).
- SC-008's "(default 30s)" now reads as the bound it is; two tables and two sub-headings were
  re-joined to their rows and lists.

*Third pass, 2026-09-20.* A third run of the same analysis found no constitution conflict, full task
coverage and fifteen findings. `AD-16` and `AD-17` are **design choices made on the analysis's own
recommendation at the operator's instruction to fix everything found**; each records the alternative
so the operator can reverse it.

### AD-16: The provider adopts and releases the tier's VLAN claims *(FR-109 widened, SC-046 — choice)*

> **Amended by AD-32** (operator decision, 2026-09-20): ratified, with adoption decided once per
> value on label, deterministic name and a named set of fields; the finalizer set at apply time; the
> deployer — never the allocator — deciding what is still provisional; and every claim label placed
> in `metadata.labels`.

- **Decision**: the `Network` reconciler adopts a bound `vlanclaim` that carries the object's
  correlation label and reports a VLAN the object carries — the same label-and-value rule it applies
  to the tier's VNI claims (AD-09) — records it in `status.claimRefs` as `adopted`, holds it while
  the service exists and releases it in finalization after the read-back. It never *creates* a VLAN
  claim: a VLAN with no adoptable claim is one the operator named, claimed by nobody, as before. The
  provider's identity gains `get, list, watch, delete` on `vlanclaims` — no `create`, no `update`, no
  `patch`. The tier releases a claim only while it is provisional (decline, rollback, never
  submitted); its removal path deletes the `Network` and nothing else.
- **Rationale**: AD-09 gave VNI claims a release owner and left the tier's VLAN claims with none. The
  provider held nothing on `vlanclaims`; the tier released on decline, rollback and purge only. So a
  service whose VLAN was allocated leaked that claim on every removal — through the tier or with
  `kubectl delete` — until the 100–4000 index ran dry, and FR-103's "every allocation stays claimed
  until the removal is read back" had no mechanism for the one allocation the provider could not see.
- **Alternatives rejected**: *the tier releases the VLAN claim on its own removal path* — it cannot
  know when the removal has been read back, so it would either release early (the hazard FR-103
  exists to prevent) or need to watch finalization, and a `kubectl delete` would still leak; *a
  periodic sweeper of claims whose `Network` is gone* — a timer that releases identifiers, which
  FR-103 forbids.
- **Consequences**: FR-109, FR-062, SC-046; `contracts/kuid-claim-profiles.md` §3, §5, §8;
  `contracts/reconciliation.md` Rule 3 and Rule 8; `data-model.md` §4, §11, §20; tasks T019, T042,
  T055, T170, T171, T093, T100 and the new live check T173.

### AD-17: The drift-policy set is closed, with one member *(FR-015 — choice)*

- **Decision**: `DRIFT_POLICY` admits exactly the string `revertive`. Unset, empty and every other
  value — `non-revertive`, `Revertive`, `true` — refuse the provider's start, naming the variable
  and the admissible value. A second value is a change to FR-015 that states how it repairs drift.
- **Rationale**: AD-13 said "unset or unknown" and named one known value, so the unknown case could
  not be tested. Constitution Principle I says detected drift MUST be repaired, and `revertive` is
  the only policy this platform implements that repairs; leaving the set open left room for a value
  with no repair procedure behind it.
- *Rationale corrected by AD-34.* This entry originally gave as its reason that the only other
  behaviour the device-configuration layer has is its non-revertive mode, "which accepts the
  device's value as active". That is **not** the case at the pinned versions: non-revertive records
  the deviation and the operator may accept it *or revert it* through `DeviationClear` /
  `TargetClearDeviation` ([evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md)
  §3.4), and a revert is repair. The set stays closed at one member because
  hold-and-operator-revert is out of scope for this feature, not because the constitution forbids
  it.
- **Alternatives rejected**: *a second value that holds the deviation and repairs on operator
  approval* — it repairs, so the constitution allows it, and the approval mechanism it needs
  already exists upstream as `DeviationClear` (whole or path-filtered); what this platform does not
  build is the `Ready=False` status shape a held deviation needs, the permission to create that
  object, or the tests for either, and nobody has asked for them. It can be added later by exactly
  the change FR-015 now describes (AD-34). *A value that only reports and never repairs* — it is
  not repair, so FR-015 may not admit it while Principle I stands.
- **What stays true**: there is still no default, production still selects explicitly, and every
  `Config` still states the policy as `spec.revertive: true`. `contracts/reconciliation.md` Rule 6
  no longer offers the non-revertive mode as "the shape a production policy takes".

### AD-18: The audit record is the trace-borne event in the analytics store *(FR-078)*

- **Decision**: an audit event is a span event on the request trace, emitted by the process that
  decided it through its one exporter, stored in the agent-analytics store, retained for the life of
  the lab environment and exported with the evidence. That stored event is the record and is what
  SC-030 and SC-042 reconcile. The deployer mirrors the three events it decides itself (submission,
  removal, out-of-band) as Kubernetes Events; the supervisor mirrors nothing.
- **Rationale**: the data model had every audit event "emitted as a Kubernetes Event in the intent
  namespace", while confirmations, declines and refusals are decided by the supervisor, which holds
  no cluster permission by FR-075 — and a refusal at the classifier never reaches the deployer. It
  also called the event immutable while an Event expires within about an hour by the API server's
  default. FR-088 puts durable traces out of scope "unless a trace store is added explicitly";
  FR-091's analytics store is that store, and now says so.
- **Alternative rejected**: *give the supervisor Event-create permission* — a third tier identity
  with cluster permission, against FR-075's "exactly two".

### AD-19: "Zero device sessions" is counted per source, inside the cluster nodes *(SC-028)*

- **Decision**: the count is of packets from intent-tier pod addresses toward the management address
  space, taken inside each cluster node ahead of the NetworkPolicy drop and of any source address
  translation, by a counter the harness installs and removes. Its **positive control** is the
  boundary probe's own dial from a tier-labelled pod (T066), which must move it; the adversarial
  corpus must then leave its delta at zero.
- **Rationale**: a counter on the management network also counts the device-configuration layer and
  the metric collector, which dial devices by design, and a cluster CNI commonly translates pod
  sources to the node address on the way out — so the check as written would either never read zero
  or could not tell who dialled. Which packet-filter front end the pinned node image carries is
  observed by the harness, not assumed (Open item 16).
- This is a node-side counter, not a device client, so FR-108 does not govern it; it is run-captured
  like every other check (NFR-013).

### AD-20: One tagging mode per port gets a carrier *(FR-034)*

- **Decision**: the rule the data model already stated — an untagged attachment and a tagged one
  never share a port — is carried by FR-034, by a CEL rule inside one object, a webhook rule across
  objects, the deployer's pre-flight, and fixtures for each.
- **Rationale**: it had no requirement, no contract rule and no test. It is kept rather than deleted
  because research never observed an untagged subinterface beside tagged ones on the pinned release
  (Open item 17); refusing the mix is the conservative reading, and the rule can be relaxed by a
  gate observation later.

### AD-21: Host-side test and recording tooling is pinned *(NFR-003)*

- **Decision**: `data-model.md` §28 — the browser-automation package by exact version and hash in
  the tier's dependency lock, the browser by the build that version fixes, the walkthrough's capture
  tools by a version the lock file records from what is observed on the host, all checked by
  `make verify-pins` before the suite that uses them, and the versions used written to the run's
  evidence. It is not a pin exception.
- **Rationale**: the chat-surface session (T127) and the ported walkthrough driver (T157) use a
  browser-automation package, a browser and a screen-capture tool that were in no lock file.
  Constitution Principle V says all binaries.

### AD-22: Third-pass closures that needed no design decision

- **One closed condition set**: `Allocated` was named on the `Fabric` and defined nowhere; it is
  gone. `Translated` is `MigrationPlan`-only and says so. The shared status helper (T023) sets
  `Accepted`, which FR-109 and the qualification refusal rely on.
- **The untagged binding** of FR-037 (`ethernet-1/1.0`) gets a render case (T104) and refusal and
  lifecycle cases (T105, T106).
- *Network* and *Fabric service resource* were two Key Entities for one object, each calling it the
  only thing the tier creates, which the allocator agent's claims contradict; merged.
- SC-029 and User Story 6 say "both identities"; FR-030 and User Story 5 say what they meant.
- `ClaimValue` is delivered by T019 and consumed by T171; `internal/telemetry/logging.go` is T042's
  file and T133 no longer claims it.
- Ten live identifiers the plan never cited — FR-011, FR-049, FR-071, FR-073, NFR-002, NFR-007 to
  NFR-010 and NFR-012 — are now in its component inventory.

*Fourth pass, 2026-09-20.* A fourth run of the same analysis found no constitution conflict, full
task coverage and fifteen findings, two of them high. All were closed the same day at the operator's
instruction ("fix all listed issues"). `AD-23`, `AD-26` and `AD-27` are **design choices** made on
the analysis's recommendation rather than put to the operator; each records its alternative and is
reversible. Two further seams surfaced while closing them and are closed under `AD-26` and `AD-28`.

### AD-23: `Fabric` readiness reads its own sessions and the reflection setting, never a route count *(FR-100, SC-004 — choice)*

- **Decision**: the `Fabric` is `Ready` when every node's fabric `Config` is applied and the device
  state shows interfaces up, every underlay and overlay session established with the EVPN family
  negotiated, and `inter-as-vpn` reported `true` by every reflecting spine. It never counts EVPN
  routes. `inter-as-vpn` and `route-reflector client` are **configuration** leaves, and SR Linux's
  state datastore is the running configuration plus operational data, so reading them back with
  `--type state` shows the setting is applied on the device, not that reflection works: they are
  read as a **configuration-integrity** invariant and are stated as such wherever they appear, never
  as applied-side behavioural evidence. The behavioural proof of reflection is G8 on this image,
  T051's post-render probe, and the first `Network` that spans two leaves. Route exchange through
  the rendered fabric is an invariant of each `Network` that spans
  two leaves — `Ready=False/RoutesMissing`, keyed to that service's own EVPN instance — and SC-004
  is met by two observations: the session half on the default `Fabric` (US1), the route half with
  the first spanning services (US2), the latter with a negative control in which the setting is
  removed from one spine as a declared injected fault.
- **Rationale**: User Story 1, `data-model.md` §3a and T041 made "EVPN routes actually exchanged" a
  condition of `Fabric` readiness, and `FabricReady` precedes every service while the gate removes
  its scratch instances before it. A device originates an EVPN route only for an EVPN instance —
  with one scope-dependent exception: Ethernet Segment (Type 4) and Ethernet A-D per ES (Type 1)
  routes come from `/system/network-instance/protocols/evpn/ethernet-segments`, which is not inside
  a `mac-vrf`; EVPN multihoming is out of scope and no ESI is ever claimed, so that subtree is empty
  here, and **if multihoming is ever added this rationale must be re-derived** — so
  at that moment zero routes is the *correct* state; the quickstart already said "once services
  exist" two lines above calling zero routes a failed run. As written, provisioning could not pass
  `FabricReady` — or the check would be loosened at build time to let it, which is the failure
  Principle VI names. A received-route count on the default instance is also fabric-wide, the kind
  of evidence FR-100 forbids.
- **Alternative rejected**: *a fabric-owned canary EVPN instance on every leaf, so that the `Fabric`
  can show its own routes* — it proves reflection on the rendered fabric before any service, but it
  puts a permanent tenant-shaped object and a reserved VNI on every leaf, makes the `Fabric`
  reconciler a second renderer of bridged instances, and spends an identifier the allocation
  authority must then know about. The operator may prefer it; R-46 records what is given up.
- **Also rejected**: *a transient probe owned by verification tooling that gates `Fabric`
  readiness* — FR-108 forbids it in terms: no fabric outcome may depend on verification tooling.
  A probe may report and be captured as evidence; it may never be an input to `Fabric.status`.
  What is adopted instead is T051's post-render probe, which reports and does not gate.
- **Consequences**: spec User Story 1, FR-100, SC-004, an edge case; `data-model.md` §3a;
  `contracts/reconciliation.md`; quickstart §4, §8, the diagnosis table; plan P2, P3, the SC-004
  row, R-46; tasks T041, T051, T052, T064.
- **Ratified with amendments** by the operator on 2026-09-20; the amendments are `AD-31`.
- *Amended by AD-43*: the route half's negative control is no longer "the setting removed from one
  spine as a declared injected fault". It is declarative — `Fabric.spec.overlay.interASVPN` set
  `false` and restored — so nothing reverts it, and it withdraws reflection on both spines, which a
  one-spine fault never did.

### AD-24: The audit record is exported before anything removes its store *(FR-078)*

- **Decision**: `off.sh` and `off.sh --purge-intent-tier` export the analytics store's trace tables
  through the evidence capture whenever the store exists, whether or not evidence capture was asked
  for, before deleting it. A failed export stops the run with the store intact. The only way past
  is `--discard-audit-record`, whose use is printed and recorded in the run's evidence. After the
  export, the evidence file is the record. The store carries no TTL.
- **Rationale**: FR-078 kept the record "for the life of the lab environment" in a store inside the
  namespace the tier's removal deletes while the lab runs on — the documented acceptance sequence
  does exactly that before its tier-absent gate run — and evidence capture in `off.sh` was optional.
  Principle II's "all actions MUST be auditable" did not survive a routine step.
- **Alternative rejected**: *move the store out of the tier's namespace so the purge leaves it* — the
  analytics store is a tier workload (R-23) and keeping it would make the tier not removable
  (NFR-006).
- **Consequences**: FR-078, User Story 7 scenario 4, an assumption; `contracts/kubernetes-objects.md`;
  quickstart §24; tasks T049, T088, T136, T152 and the new test T174.
- **Amended by AD-36** (operator decision, 2026-09-20): the principle stands; the export's format,
  location, failure set, bound, per-attempt identifier, redaction and post-export reconciliation are
  stated there.

### AD-25: Allocated identifiers are immutable once a `Network` is accepted *(FR-109)*

- **Decision**: CEL transition rules fix `bridgeDomains[].l2vni`, `routers[].l3vni`, `vlans[].vlan`
  and `bridgeDomains[].vlan`, and the membership of those three lists. The refusal names the field
  and says that changing it is a removal and a new service. Attachments, access lists, prefixes and
  gateway addresses stay mutable; an adopted claim whose value no attachment carries any longer is
  held, and listed, until finalization.
- **Rationale**: FR-109 releases claims only at finalization and said nothing of an edit, so a
  changed VNI either made a second claim beside the first — leaking one per edit until deletion — or
  had no defined behaviour. User Story 2's own test updates a service.
- **Alternative rejected**: *release the superseded claim after the new render is read back* — a
  second release path with its own unreachable-target case, for an edit nobody has asked to make.
- **Consequences**: FR-109, an edge case; `contracts/crd-api.md` rule table and contract tests;
  `data-model.md` §12; quickstart §8; tasks T014, T017.

### AD-26: Removing the tier removes the services it submitted — listed, bounded, never forced *(NFR-006 — choice)*

- **Decision**: the intent namespace is the tier's, so its removal deletes the tier-submitted
  `Network`s. It lists them first, exports the audit record (AD-24), deletes them, and waits up to
  `TIER_PURGE_WAIT_SECONDS` (300 s, `data-model.md` §25) for their finalizers; one still `Deleting`
  stops the removal non-zero naming the `Network` and its unreachable target, with the rest of the
  tier in place. It never force-releases; a re-run completes when the target returns. `Network`s
  applied with cluster tooling live in the control-plane-owned namespace `agentic-netops-services`,
  created with the provider, and are untouched.
- **Rationale**: the task list and the quickstart already deleted the intent namespace, which no
  requirement said and which "the control plane is unaffected" half-denied; and FR-103's blocking
  finalizer would have left that namespace terminating for ever with no stated outcome. Closing it
  surfaced a second seam: the hand-applied examples of User Story 2 were addressed to the tier's
  namespace, which does not exist until the tier phase and is deleted with it.
- **Alternative rejected**: *keep the intent namespace and its services when the tier goes* — the
  services would outlive the only identity that may remove them through a confirmation, the
  namespace would be a tier artefact the control plane must then own, and the removability run
  could not show a cluster with no tier trace in it. The bound limits the script, never the
  finalizer, so FR-103's "no timer releases an identifier" is untouched.
- **Consequences**: NFR-006, User Story 7 scenario 4, an edge case; `data-model.md` §2, §25;
  quickstart §2, §8, §24; plan C-18, P11, R-47; tasks T042, T062, T088, T141, T152, T174.
- **Amended by AD-35** (operator decision, 2026-09-20): the machinery is ratified and the **default is
  reversed** — the removal deletes no service until it is asked to, and quiesces the tier first.

### AD-27: An allocated VLAN that collides with a named one is refused by name *(FR-062 — choice)*

> **Amended by AD-33** (operator decision, 2026-09-20): the two kinds of VLAN are given disjoint
> bands — named `100–999`, allocated `1000–4000` — so the collision below is structurally
> impossible and the refusal path it defines is withdrawn. The one-owner rule stays for two services
> naming the same (node, port, VLAN).

- **Decision**: where the VLAN the authority allocated is already attached, by name, on the
  requested port by another service, the deployer's pre-flight refuses under the one-owner rule of
  FR-034 before anything is created — naming the VLAN, the port and the holder and saying that
  naming a free VLAN avoids it — releases every provisional claim, and tries no other value.
- **Rationale**: named VLANs are claimed by nobody (AD-09, an operator decision) and allocated ones
  come from the same 100–4000 index, so the authority cannot know a named VLAN is in use. The
  collision was reachable and had no stated outcome.
- **Alternative rejected**: *hold the colliding claim, claim again, release the held ones* — it needs
  the allocator agent to read `Network`s, which widens FR-075's exact verb set for a corner a
  single-operator lab meets rarely and can step round by naming a VLAN. *Claim named VLANs too* was
  decided against in the second pass and is not reopened.
- **Consequences**: FR-062, an edge case; `contracts/kuid-claim-profiles.md` §4; plan C-14, P7;
  tasks T092, T112, T141.

### AD-28: Every offline suite has a make target and a CI job *(FR-020)*

- **Decision**: `make test-envtest`, `make test-agents` and `make test-ui` join `make test-static`;
  the CI workflow runs all four on every pull request, and a test asserts that every directory under
  `tests/envtest/` is reached. The four targets quickstart §21 names — `verify-metrics`,
  `verify-topology-view`, `verify-evpn-service-view`, `test-alerts` — are added to the Makefile
  and wired by the task that owns their scripts.
- **Rationale**: eight envtest suites and the chat surface's unit test were written by tasks and
  run by nothing — no target, no CI job — while the constitution requires every PR to pass tests
  and the predecessor's acceptance record was disputed over a CI job narrower than claimed. The
  four observability targets were named in the quickstart and absent from the Makefile task: an
  earlier check had read only the first target of a multi-target `make` line.
- **Consequences**: FR-020; quickstart Gate 0; plan make-target table and verification layers; tasks
  T006, T007, T025, T123, T134.

### AD-29: The optional `MigrationPlan` is brought into line with the platform *(FR-048)*

- **Decision**: `spec.mappingPolicy.preserveRouteTargets` is removed. The CRD is generated under
  `config/crd/optional/`, outside the default kustomization, and lab provisioning never applies it.
  Its controller is part of the provider binary, registers only when the CRD is served, holds
  `get, list, watch` and `status` on `migrationplans` and read-only verbs on `networks`, and never
  creates or modifies a `Network`; `status.generatedNetworkRef` is a recorded reference.
- **Rationale**: a preserved source route target cannot be expressed in a `Network` whose route
  targets are `target:<fabricASN>:<vni>` by CEL rule (FR-012, RD-09) — the field was a SONiC-era
  survivor. "Disabled by default" had nothing that disabled it, no task named the controller's
  host or permissions, and a controller that "generated" a `Network` would have been a second
  place where intent becomes fabric intent (FR-060).
- **Consequences**: FR-048; `data-model.md` §5; `contracts/crd-api.md`; plan C-20; tasks T016, T122.

### AD-30: Fourth-pass closures that needed no design decision

- **FR-102**: "never defaulted" sat beside a default username. The password is always generated and
  never accepted from outside; the username may take a documented default, because it identifies
  and does not authenticate.
- **FR-107** states the bound SC-044 measures — one re-verification interval plus one
  reconciliation interval — instead of "within that interval".
- **FR-078** and the *Audit event* entity list the six event kinds the data model already had, and
  "every refusal" excludes the unauthenticated one, which has no principal and is counted and
  logged instead.
- **FR-096**: the dashboards' administrator credential is the generated Secret `grafana-admin`
  (T037, T130).
- **NFR-004**: the measured per-node footprint is captured by the clean-host run (T052) and quoted
  only from that evidence.
- Plan P0 says why the gate runs after the installs G10 and G11 need; the plan's tree, the task
  list's hard rules and `specs/README.md` name `checklists/clarify-delta.md`; the plan's SC-044 row
  says "uplinks administratively disabled", as T167 and AD-06 do.

*Operator review, 2026-09-20 (after the fourth pass).* The five design choices the analysis passes
had made without the operator — `AD-16`, `AD-17`, `AD-23`, `AD-26`, `AD-27` — were researched by
independent agents against the pinned upstream sources and put to the operator with the reports in
[review/2026-09-20/](./review/2026-09-20/) (`DECISION-SHEET.md`). **The operator decided**: the tier's
removal refuses while tier-submitted services exist unless `--remove-services` is given; named and
allocated VLANs get disjoint bands; the drift-policy set stays closed at `revertive` with its
rationale corrected; `AD-23` and `AD-16` are ratified with the amendments the research found
necessary. `AD-31`…`AD-39` record what changed. These are operator decisions, not choices.

### AD-31: `Fabric` readiness says what its reflection read is, and gains three keyed checks and a post-render probe *(FR-100, SC-004, R-46 — operator decision)*

- **Decision**: `AD-23` is **ratified — no canary** — with seven amendments, on the research in
  [review/2026-09-20/AD-23-fabric-readiness.md](./review/2026-09-20/AD-23-fabric-readiness.md).
  (1) Everywhere the `Fabric`'s reflection read appears it is stated as a **configuration-integrity**
  check, not applied-side behavioural evidence: `inter-as-vpn` carries no `config false` in the
  pinned model and SR Linux's state datastore is the running configuration plus operational data, so
  `--type state` returns the configured value. (2) The applied side gains two reads that cost one
  path each: the EVPN family's own operational state per neighbour
  (`…/neighbor[peer-address=<ip>]/afi-safi[afi-safi-name=srl_nokia-common:evpn]/oper-state`, a
  `config false` leaf whose model description is "Negotiated operational state of the address family
  is up"), and `route-reflector client` read back from every reflecting spine — the nearest failure
  to the one the reflection read defends against, rendered but never read. (3) The `Fabric` also
  reads, keyed to the loopbacks it allocated, every other node's `system0.0` address present and
  `active` in this node's route table — which User Story 1 already promises and no read-back
  delivered, and which is the one applied-side check that would catch a policy-less eBGP underlay.
  (4) The quickstart's §4 block (a) reads the EVPN family, not `session-state` alone, and block (c)
  reads `route-reflector client` beside `inter-as-vpn`. (5) `AD-23`'s premise records its scope
  boundary (ethernet-segment routes are not instance-bound; multihoming is out of scope) and Open
  item 4 records the model text and release documentation that now support the mechanism. (6) T051
  runs a **post-render reflection probe** under FR-108 — scratch EVPN instances on the rendered
  fabric, the Type-3 route observed through the spines, removed and read back — reported and
  captured, never an input to `Fabric.status`; and no run may record SC-004 until both observations
  and the route half's negative control are in the evidence directory. (7) The `EvpnRoutesLost`
  alert is guarded so it cannot fire on a fabric that carries no EVPN instance.
- **Rationale**: `AD-23`'s premise is correct — the pinned model binds EVPN route origination to a
  `bgp-evpn bgp-instance` inside a network-instance, so zero routes before any service is the
  correct state — and the canary buys reflection proof at the price of a permanent tenant-shaped
  object, a reserved VNI the allocation authority must carve out of the VNI band, and a second
  renderer of bridged instances. What `AD-23` did not say is that the invariant standing in for the
  route count is a re-read of the platform's own write, which `data-model.md` §13 already names as
  the thing that does *not* make an applied-side assertion genuine. The amendments keep the decision
  and close that gap without a canary: two of the three added reads are genuine operational state,
  the third is the reachability User Story 1 already claims, and the post-render probe proves
  reflection on the fabric the provider rendered rather than on the gate's own scratch configuration
  — which is exactly the residue R-46 was left carrying. The alert as written fired throughout the
  window `AD-23` declares healthy, which trains an operator to ignore the one signature it exists
  to catch.
- **Alternatives rejected**: *the canary EVPN instance* — rejected again, for `AD-23`'s reasons plus
  the allocation-band and read-back-table costs the review priced. *A transient probe that gates
  `Fabric` readiness* — forbidden by FR-108, which lets no fabric outcome depend on verification
  tooling; the probe reports and is captured instead. *Rewriting the alert in
  `evidence/06-telemetry-visualization.md`* — that file is a research report, so the rule there is
  marked superseded in place and the guarded requirement lives in the design artefacts.
- **Consequences**: research `AD-23` and Open item 4; `data-model.md` §3a;
  `contracts/reconciliation.md`; quickstart §4, §8, §21, the gate table; plan P0 gate items G4, G7,
  G8 and G12, P2, the Principle I row, the SC-004 row, R-46; tasks T041, T043, T051, T052, T064,
  T130; a dated superseding note beside the alert in `evidence/06-telemetry-visualization.md`.
  No new requirement, task, risk or gate item: every amendment lands in text that already exists.
- *Amended by AD-43*: the route half's negative control named in amendment (6) is a declarative
  fault on the `Fabric`, not a device-side edit, and the `Fabric` reports `Ready=False/NotConverged`
  naming the spines and the setting while it lasts. *Amended by AD-48*: amendment (7)'s guard is
  "one EVI present on at least two leaves", not "an EVPN instance on that source", and the series
  names it depends on are recorded by G7 to a file T130 reads.

### AD-32: Adoption is decided once, on three things, and the deployer decides what is provisional *(FR-109, FR-062, FR-075, SC-045, SC-046, R-44, R-45 — operator decision)*

> **Amended by AD-51** (operator decision, 2026-09-21): no VLAN is ever allocated for an `ip-vrf`
> attachment, so the case amendments (1) and (2) were written for — an allocated VLAN that lives
> only on an attachment — no longer exists. The predicate of amendment (2) reads **two** fields,
> `spec.vlans[].vlan` and `spec.bridgeDomains[].vlan`; once-per-value adoption stands as the rule
> that an adopted claim is never re-evaluated; and the added-attachment rule reads `spec` alone.
>
> **Amended by AD-42** (operator decision, 2026-09-21): the deterministic claim name is part of the
> adoption rule for **VNI claims as for VLAN claims**, under the one scheme
> `<namespace>.<name>.<role>` — amendment (5) below names VLAN claims only. **And by AD-44**: the
> finalizer of amendment (3) holds the object but releases nothing by itself, so finalization
> resolves adoption before it releases. **Amended by AD-52** (operator decision, 2026-09-21): the
> admission webhook fails closed, so no object is *applied* while the provider is down; the window
> amendment (3) closes is a **deletion** that arrives before the provider's first reconcile —
> whether the provider is slow or down — and for an object applied with cluster tooling that window
> is "applied, then deleted before the first reconcile".

- **Decision**: `AD-16` is **ratified** — the provider adopts the tier's VLAN claims, never creates
  one, and is the one release owner of every claim of a submitted service — with five amendments,
  on the research in
  [review/2026-09-20/AD-16-AD-27-claims.md](./review/2026-09-20/AD-16-AD-27-claims.md).
  (1) **Adoption is decided once per value.** A claim recorded `adopted` in `status.claimRefs` stays
  adopted for the life of the object, whether or not the object still carries that value on a later
  reconcile; the adoption predicate is re-evaluated only for a value not already recorded.
  (2) **The fields the predicate reads are named** — `spec.vlans[].vlan`,
  `spec.bridgeDomains[].vlan` and `spec.attachments[].vlan`, those three and no other — and an
  attachment **added** to an accepted object may not carry a VLAN in the allocation band, by CEL
  transition rule, because nothing would claim it. (3) **A tier-submitted `Network` carries the
  provider's finalizer from the moment it is applied**: the deployer sets it at apply, needing no
  new verb, so no window exists in which the object can be deleted outright and leave its claims
  with no release owner. (4) **The deployer, never the allocator, decides which correlation
  identifiers are still provisional** — it is the one tier identity that may read a `Network`, it
  names the releasable identifiers and the allocator deletes only those; the allocator holds no verb
  on `networks` in any namespace and a denial probe asserts it. (5) **Every label the platform
  relies on lives in `metadata.labels`**, and an adoptable VLAN claim must also bear the
  deterministic name derived from the object, so that a copied correlation label alone adopts
  nothing.
- **Rationale**: the third pass gave VLAN claims a release owner and left four ways for the
  ownership to fail, each found by reading the pinned authority's own source rather than the design.
  An `ip-vrf`'s allocated VLAN lives only on an attachment, which `AD-25` left mutable, so the
  adoption predicate could lapse on a later reconcile and the claim would be dropped from
  `status.claimRefs` with nobody to release it. The finalizer was placed on the provider's first
  reconcile, so a `kubectl delete` while the provider was down removed the object and orphaned the
  tier's claims — "one release owner, whichever way the service is removed" was false for the
  duration. The guard that stopped a rollback releasing a submitted service's claim was tasked to
  the allocator, which may not read a `Network` at all: `AD-16`'s own safety property needed the
  widening `AD-27` had refused. And the authority filters a label selector on `metadata.labels`
  only — `options.LabelSelector.Matches(labels.Set(accessor.GetLabels()))`,
  `pkg/registry/generic/strategy_resource.go` at `v0.0.13` — while its `spec.labels` field is
  invisible to `kubectl get -l`, so every claim-selector diff in the design rested on a placement
  nothing had stated. Three label conventions were in use across the artefacts and none was
  canonical. The same reading closed **CHK033**: adoption on label and value alone would let an
  object applied with cluster tooling that copies another service's correlation label adopt that
  service's claim, and the deterministic name is what makes the copy insufficient — at no cost in
  permissions.
- **Alternatives rejected**: *an `ownerReference` from the claim to the `Network`* — **impossible,
  and harmful if attempted**: claims live in `kuid-system` and `Network`s do not, and Kubernetes
  treats a cross-namespace owner reference as an **absent** owner, leaving the dependent "subject to
  deletion once all owners are verified absent"
  ([owners-dependents](https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/)),
  which would release an identifier with no read-back — the hazard FR-103 exists to prevent. Moving
  the claims into the `Network`'s namespace to make owner references legal is not open either: a
  claim must share a namespace with its index, so it would put an allocation index inside the tier's
  namespace. *Giving the allocator a `Network` read* — the widening `AD-27` refused and this
  decision does not take; the deployer already has the read. *A sweeper reconciling claims against
  objects* — a timer that releases identifiers, which FR-103 forbids.
- **Not assumed**: that the pinned authority binds a stated value and refuses a second one **naming
  the holder**, that a claim's `metadata.labels` are selectable through the aggregated API, that a
  claim reports its value in `status.id`, and that a claim deleted is released synchronously. All
  are read from `v0.0.13` source and all are **observed by gate item G11** before the provider
  relies on them (R-44).
- **Consequences**: FR-109, FR-062, FR-075, SC-045, SC-046; `contracts/kuid-claim-profiles.md` §3,
  §5, §6, §8; `contracts/reconciliation.md` Rule 3 and Rule 8; `contracts/kubernetes-objects.md`
  (submission contract, identity contract, denial probes); `contracts/crd-api.md` rule table;
  `data-model.md` §11, §12, §20; `plan.md` C-14, C-21, P0/G11, P7, R-44, R-45; quickstart §26, §26a
  and the gate table; tasks T017, T019, T044, T055, T060, T069, T089, T092, T093, T100, T112, T141,
  T170, T171, T173. Closes checklist item CHK033.

### AD-33: Named and allocated VLANs get disjoint bands, so they cannot collide *(FR-062, FR-109, R-28, AD-27 — operator decision)*

> **Amended by AD-41** (operator decision, 2026-09-21): on the tier path the naming band is enforced
> by the **mapper**, at interpretation and before any claim exists — not by the translator, as the
> decision below says, which runs after the allocator on an input that cannot tell a named VLAN from
> an allocated one and keeps only the structural `100–4000` check. **And by AD-47**: the VLAN a
> standalone `acl` names is a reference, exempt from both band rules, and the added-attachment rule
> refuses only an allocation-band VLAN the object does not already carry.

- **Decision**: the platform's VLAN space `100–4000` is **split once and for all**. `100–999` is the
  **naming band** — the only band an operator may name a VLAN from, claimed by nobody, its
  exclusivity the one-owner rule of FR-034. `1000–4000` is the **allocation band** — the VLAN
  index's own `minID`/`maxID`, from which every allocated VLAN comes and in which every value is
  claimed. A named VLAN outside `100–999`, and any VLAN outside `100–4000`, is refused **with both
  bands stated**. Because a service intent object cannot say whether its VLAN was named or
  allocated, **the rule is stated in terms of the value**: a VLAN in `100–999` is a named VLAN and
  is backed by no claim; a VLAN in `1000–4000` MUST be backed by an adoptable bound claim under the
  label-and-value rule of `AD-32`, and an object carrying one that is not is
  `Accepted=False/AllocationConflict` naming the VLAN and both bands, with nothing rendered. The
  structural CEL rule stays `100..4000` and is **never asked to tell a named VLAN from an allocated
  one**, because CEL cannot see a claim: the translator enforces the naming band on the tier path,
  and the provider's claim gate enforces the allocation band on the cluster-tooling path. With the
  bands disjoint the collision `AD-27` guarded is **structurally impossible**, so its refusal path
  is withdrawn with it; the one-owner rule and the deployer's pre-flight stay, for two services
  asking for the same (node, port, VLAN) — necessarily two **named** VLANs.
- **Rationale**: `AD-27` was a correct response to a real gap but it reported an edge case instead
  of removing one, and it did so *after* both confirmations, naming no concrete alternative. The
  research found the collision unreachable in the frozen walkthrough — all three prompts name their
  VLAN (170, 253, 152), so the recording allocates none — but could not say how often it would
  occur in a running lab, because whether the pinned authority allocates the lowest free value or an
  arbitrary one is not readable from its source: lowest-first would make the collision deterministic
  after roughly fifty allocations rather than a 3-in-3901 rarity. A decision resting on an unmeasured
  frequency is a decision worth removing. The mechanism costs nothing: `VLANIndexSpec.MinID/MaxID`
  already exist and the platform already uses them for `100–4000`, they materialise reserved range
  claims, and a claim cannot draw from a reserved range (`"cannot claim from a reserved range"`,
  `pkg/backend/generic/applicator_dynamic_id.go` at `v0.0.13`). No RBAC changes, no `Network` read
  is added, and "named VLANs are never claimed" stands untouched — nothing is claimed, the two
  spaces are simply disjoint.
- **What it costs, stated plainly**: an operator may no longer name a VLAN of `1000` or above. In a
  lab with 900 nameable VLANs and two active access ports that is not a practical constraint, but it
  is a real reduction in expressiveness and it was the operator's to accept. The frozen walkthrough
  identifiers 152, 170 and 253 all lie in the naming band, so P12 is unaffected and a second take
  must pick its replacements from `100–999`.
- **R-28 is not contradicted.** RD-09 deleted a **derived** routed-instance VLAN band because SR
  Linux derives no routed VLAN — that evidence stands and nothing here reinstates PC-15. What this
  decision adds is a **chosen** partition of the platform's own VLAN space. The sentence "there is
  no derived or reserved VLAN band on this platform to carve out of it" is rewritten accordingly
  rather than quietly reinterpreted.
- **Alternatives rejected**: *`AD-27` as written* — see above. *Per-`(node, port)` or per-node VLAN
  indices* — feasible (the authority supports any number of indices, keyed per
  `{namespace, name}`) but **they do not dissolve the collision**: named VLANs are claimed by nobody
  either way, so an index scoped to a port is exactly as blind to a named VLAN on that port as a
  global one, and because per-port indices re-use the low end of the range on every port they would
  make the collision *more* likely while costing an index object per port and an index-resolution
  step in the allocator. *An exclusion list of occupied VLANs in the `site-inventory` ConfigMap* —
  that ConfigMap is written once by the provisioning script and mounted read-only, and no tier
  identity holds any ConfigMap verb anywhere, so the list would be stale from the first run and
  would give the allocator false confidence; making it live means granting ConfigMap writes, a
  larger widening than the `Network` read `AD-27` refused. *A pre-confirmation occupied-VLAN query
  through the deployer* — sound and it widens nothing, but with disjoint bands it has nothing left
  to exclude; it is recorded here so it is not re-proposed as a fix for a problem that no longer
  exists.
- **Not assumed**: that the authority never hands out a value below its index's `minID`. The guard
  is visible in source but the tree implementation it calls is in an unvendored dependency, so it is
  **observed by gate item G11**, with the value three consecutive dynamic claims return recorded
  beside it (R-44).
- **Consequences**: FR-062, FR-109, an edge case; `contracts/kuid-claim-profiles.md` §1, §2, §4, §5,
  §6, §8; `contracts/crd-api.md` rule table; `contracts/reconciliation.md` Rule 3;
  `contracts/kubernetes-objects.md` submission contract; `contracts/readme-and-walkthrough.md` §3.1;
  `data-model.md` §11, §12, §20; `platform-coupling.md` PC-15; `plan.md` C-14, C-21, P0/G11, P7,
  R-28, R-44; quickstart §26, §26a, the gate table and the diagnosis table; tasks T014, T017, T038,
  T044, T062, T091, T092, T093, T112, T141, T170, T171, T173. Supersedes `AD-27`'s refusal path.

### AD-34: The drift-policy set stays closed at `revertive`, with its rationale corrected *(FR-015, AD-17 — operator decision)*

- **Decision**: AD-17's mechanism stands unchanged — `DRIFT_POLICY` is required, has no default and
  a closed value set of one, the exact string `revertive`, which the provider states on every
  `Config` it generates as `spec.revertive: true`. What is corrected is the reason given for the
  closure. The device-configuration layer's non-revertive mode does **not** merely accept the
  device's value: it records the deviation and leaves the operator to accept it *or to revert it*,
  and the revert is repair. Hold-and-operator-revert is therefore a policy constitution Principle I
  admits; it is **out of scope for this feature**, not forbidden by the constitution. Every "needs a
  constitution amendment" claim attached to the drift policy is withdrawn: admitting a second value
  is a change to FR-015 that brings that value's repair procedure, its status shape, its tests and
  its runbook entry with it.
- **Rationale**: FR-015, AD-17, `contracts/reconciliation.md` Rule 6, `contracts/crd-api.md` and
  `quickstart.md` all asserted that accepting the device's value is the only other behaviour the
  layer offers. At the pinned versions that is false, and the artefact that disproves it was already
  in this repository: `DeviationClear` and `TargetClearDeviation` are named in
  [evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md) §3.4 as the explicit operator
  action that clears a deviation. Stating a checkable falsehood as the reason for a rule is exactly
  what constitution Principle I exists to stop this system doing about itself, and it would have
  been found by the first operator who opened the upstream documentation.
- **What was verified** (recorded in
  [review/2026-09-20/AD-17-drift-policy.md](./review/2026-09-20/AD-17-drift-policy.md)):
  `Config.spec.revertive` is `*bool`, optional, with **no** default in the CRD schema — so "always
  stated, never inherited" is a real distinction, not a rhetorical one (config-server v0.0.58
  `apis/config/v1alpha1/config_types.go`, `crds/config.sdcio.dev_configs.yaml`, whose only
  `default:` keys are `lifecycle.deletionPolicy`); omitting the field inherits the data-server's
  `REVERTIVE` environment variable (`docs.sdcio.dev` config page: *"If not defined the global
  configuration, by default to `true`, applies"*); **none** of `Schema`, `Target`,
  `TargetSyncProfile`, `TargetConnectionProfile` or `DiscoveryRule` has a revertive field at
  v0.0.58 — all five CRDs read, zero matches, which is what fixes T036; `DeviationClear` exists at
  v0.0.58 with `spec.items[].{type, configName, paths[]}`, so an operator revert may be whole or
  path-filtered; and the upstream suite `tests/03-deviations/22-srl-nonrevertive.robot` exercises
  accept, reject-and-revert and partial revert against SR Linux 25.7.1, while
  `12-srl-revertive.robot` asserts only that the intent returns and never that a `Deviation` was
  visible — which is why **G13** exists.
- **Alternatives rejected**: *hard-wiring `revertive` with no setting at all* — a production
  deployment would then inherit the lab's behaviour by construction, the exact failure AD-13 exists
  to close, and there would be no seam for a second policy to enter through. *Admitting
  `non-revertive` now* — nothing in this feature asks for it, no success criterion measures it, and
  the platform builds neither the `Ready=False` shape a held deviation needs nor the permission to
  create a `DeviationClear`; a value with no repair procedure behind it is a setting that lies.
  *Leaving the rationale as it stood* — the mechanism would survive on a reason that does not.
- **Consequences**: FR-015, FR-004; SC-007 and User Story 2 lose their "lab mode" conditioning,
  because with one member the policy is the same everywhere and Principle I and FR-107 require
  repair unconditionally; `contracts/reconciliation.md` Rule 6; `contracts/crd-api.md`;
  `quickstart.md` §8 and its failure table; `data-model.md` §25; T036, T042, T043, T048, T064,
  T141; and gate item **G13**, which observes what a revertive-mode deviation actually leaves
  visible so that the drift test asserts an outcome rather than an artefact that may be raced
  away.

### AD-35: The tier's removal deletes no service until it is asked to *(NFR-006 — operator decision)*

- **Decision**: **operator decision, 2026-09-20**, on the review at
  `review/2026-09-20/AD-26-AD-24-tier-removal.md`. AD-26's machinery is **ratified** — the list
  first, the audit export first, the bounded `TIER_PURGE_WAIT_SECONDS` script wait, the non-zero stop
  naming the blocked `Network` and its unreachable target, never a force-release, and the
  control-plane-owned `agentic-netops-services` for `Network`s applied with cluster tooling. Its
  **default is reversed**: `off.sh --purge-intent-tier` lists the tier-submitted `Network`s and,
  while any exist, stops non-zero having deleted nothing, naming each service and the two
  continuations. `--remove-services` is what deletes them, and then the removal **scales
  `supervisor`, `ui` and `deployer` to zero first**, so that nothing new lands in a namespace being
  removed and no audit event is written after the export; the namespace goes only once a re-list
  returns empty; the cluster-scoped `deny-tier-force-release` policy goes with the identities it
  names. A full `off.sh` destroys the cluster and the lab, so it needs no such flag and never asks
  for one — it still exports the audit record first.
- **Rationale**: no requirement asked for the deletion — AD-26 says so itself — and the carriers that
  justified it (NFR-006, User Story 7 scenario 4) were amended by AD-26 to fit it, narrowing
  "unaffected" until tier-submitted services fell outside it. The predecessor's purge deleted no
  service intent object at all and its runbook promised the fabric would be left intact
  (`/root/agentic-netops/scripts/lib/intent_tier.sh:12–18`,
  `/root/agentic-netops/docs/INTENT_TIER_RUNBOOK.md:32–35`), and its own postmortem records a run in
  which a purge removed more than the operator expected, fixed by an explicit opt-in gate
  (`/root/agentic-netops/docs/SUGGESTED_PROMPTS_POSTMORTEM.md`). Each of those services was created
  under two operator confirmations; constitution Principle II asks that such a change be harder to
  trigger by accident than by intent, and a flag named for the tier is not that. SC-025 asks for
  passing gates, not a cluster with no trace of the tier in it: the control-plane gates run against
  `agentic-netops-services` and pass either way.
- **Alternatives rejected**: *keep AD-26's default* — one flag undoing N double-confirmed services,
  with the list printed to a non-interactive script nobody is reading. *Keep the services always and
  hand the intent namespace to the control plane* — defensible, and what the predecessor did, but it
  re-opens namespace ownership in four documents and leaves no way to reach a clean tier-absent lab
  from the documented acceptance run.
- **Consequences**: NFR-006, User Story 7 scenario 4, FR-010, two edge cases (one new, one reworded)
  and the fourth-pass change-log row; `data-model.md` §2, §25; `contracts/kubernetes-objects.md`
  (namespace row, the admission-policy row); quickstart §24 (the proof now runs the refusal first),
  §19; plan C-18, P11, R-47, the verification-strategy row; tasks T088, T141, T152, T174. No new
  requirement, task, risk or gate item.

### AD-36: The audit export has a format, a bound and a defined failure *(FR-078 — operator decision)*

- **Decision**: **operator decision, 2026-09-20**, on the same review. AD-24 is **ratified** and
  completed. The export is **compressed newline-delimited JSON**, one object per stored row with the
  store's own field names, written through the run-captured evidence path so that it carries the
  NFR-013 fields beside the data, under `EVIDENCE_DIR`, with an identifier **unique to the attempt**
  so that a re-run after a stopped removal adds an artefact instead of rewriting one the evidence
  audit has already hashed (SC-040) — and a re-run skips the export where this run's evidence already
  holds a verified one. It **fails** when the store is present but cannot be queried within
  `AUDIT_EXPORT_TIMEOUT_SECONDS` (a new row in `data-model.md` §25; default **120 s**, a design value
  and not a measurement, owned by `off.sh`), when the query errors, when the artefact cannot be
  written, or when fewer rows are written than the store reported; a store that was never installed
  is skipped, and one that returns no rows is a successful export of an empty record. Redaction stays
  where the text is produced (FR-079), so the export is a copy of already-redacted material and
  depends on no second pass — and the artefact is covered by the credential scan that covers traces,
  because it is where those traces leave the cluster. Because each event carries its principal,
  correlation identifier, resource reference and submitted-spec hash, the **stream** half of SC-030
  and SC-042 reconciles from the exported file once the store is gone; the half that compares the
  stream against live objects runs before either is removed, which is the order quickstart §19 and
  §24 already have.
- **Rationale**: AD-24 made the export unconditional and blocking without saying what it produces,
  when it has failed or how long it may take, so "a failed export stops the removal" was untestable
  and an unresponsive store could hold a teardown open against FR-010's fail-fast rule. The
  per-attempt identifier closes a collision between AD-26's re-runnable removal and SC-040's
  post-edit check, which fails an artefact whose content hash changed after capture.
- **Alternatives rejected**: *leave the format to implementation* — the file is the record once the
  store is gone, and a record nothing can read back is not one. *Re-redact at export* — a second pass
  over already-redacted text buys nothing and would hide a failure of FR-079 at the point where it
  matters.
- **Consequences**: FR-078, FR-079; `data-model.md` §16 and a new bound row in §25;
  `contracts/kubernetes-objects.md` (the analytics-store row); quickstart §19, §24; plan C-18, the
  verification-strategy row; tasks T049, T088, T136, T141, T152, T174. One new default bound, stated
  as a design value with its owner setting; no new requirement, task, risk or gate item.

### AD-37: The requirements-checklist triage closures — verification methods, an obligations index, and the two absolutes that were never written down

The first half of `checklists/requirements.md` (CHK001…CHK090) was triaged before implement: 80 items
came back supported, one stale (CHK020 — the item still says no `tasks.md` is produced, which is the
reviewer's to reword), one a reviewer judgement (CHK002), and eight partial. The eight are closed
below. All of it is wording and carrier work: nothing was renumbered, no requirement, criterion,
task, risk or gate item was added, and no design decision was taken. The triage report is
[review/2026-09-20/checklist-requirements-part-A.md](./review/2026-09-20/checklist-requirements-part-A.md).

- **CHK028 — six success criteria now name how they are verified.** SC-011, SC-019, SC-027, SC-033,
  SC-034 and SC-035 stated an outcome and no method, in a specification whose whole evidence
  discipline exists because the predecessor declared criteria passed by proofs nobody could
  reproduce. Each now carries a `— verified by …` clause in the style of SC-045 and SC-046, taken
  from the method [plan.md](./plan.md) §Verification strategy and the owning task already state and
  inventing nothing: one prompt per construct end to end (T103); a scripted browser session with no
  schema consulted (T127); the unsupported-construct corpus with fabric state compared before and
  after (T143, T144); the repository-wide vocabulary scan carried by the boundary check (T142); named
  target-health queries and a view load on a fresh lab, and each fault injected in turn with its
  alert observed to fire and clear (T134). The criteria are unchanged in what they require.
- **CHK026 — the four bundled requirements get an obligations index.** FR-015, FR-078, FR-109 and
  NFR-003 each carry five to eleven separable MUSTs under one number, so "FR-109 passes" is not a
  statement one check can make and a clause can lose its carrier without the identifier noticing.
  Splitting them would renumber the specification, which no pass has done. Instead
  [traceability.md](./traceability.md) §Obligations index enumerates every clause of the four —
  FR-015(a)…(g), FR-078(a)…(g), FR-109(a)…(k), NFR-003(a)…(h) — with the task that builds it and the
  check that asserts it, and §Requirements points at it. The section states its own date and that it
  reflects the requirement text as of the operator review, because the requirements themselves were
  being edited the same day. **The `(a)`, `(b)` labels are index labels inside that file, not
  identifiers**: nothing cites them, no task is written against one, and they add no numbering to
  keep stable.
- **CHK083 — an indeterminate workflow status is never a success.** The closed set (FR-054,
  [data-model.md](./data-model.md) §17) has carried `STATUS_UNKNOWN` since D-24, reachable from any
  state on transport or state loss, and nothing said what it means. FR-054 and §17 now say: it never
  satisfies a convergence watch (FR-067), it is never counted as a converged request in the
  per-stage success rate (FR-092), and what the operator is told instead is that the outcome is
  unknown, which dependency was lost (NFR-010) and that the live object is the record (FR-105).
- **CHK035 — a second workflow engine is now forbidden by name.** The document forbade a second
  translation path (FR-060) and a second fabric-intent API (FR-013) explicitly, and left the
  orchestration equivalent to inference. FR-013 now states it where the other two prohibitions live:
  controllers reconciling these objects are the only orchestration of fabric change, no second
  workflow, pipeline or job engine may sequence, retry, schedule or gate a device change, and no
  change reaches a device except by a controller reconciling one of these objects.
- **CHK001 and CHK029 — why named products appear in the requirements.** Product names are in the
  FR, NFR and SC text by the dozen, which the template rule reads as an implementation leak. They are
  not: this feature *is* one pinned reference lab and those artefacts are its subject. §Scope and
  interpretation now says so, bounds it — a requirement names an artefact only where the obligation
  is about that artefact, and a platform-neutral obligation stays stated by role — and points at
  `platform-coupling.md`, which classifies every binding. Nothing in the requirements changed.
- **CHK033 — two assumptions gain their consequence, and the dependency state gains a pointer.**
  Lab-scale concurrency now says what follows from it: concurrency is arbitrated, not engineered for,
  and the loser of a contested identifier or attachment fails with the conflicting value named
  (FR-062, FR-034) — no queue, no fair share, no throughput target. The local-`vlan` assumption now
  states its consequence, that `vlan` is carried as its own construct and its own list and never as a
  `mac-vrf` with its overlay fields missing (FR-029). A new assumption points at where the upstream
  dependency state is recorded — research §11, PC-S-01 and PC-S-15, and the repository dates in
  `evidence/05-kubenet-sdc-kuid.md` — and states the consequence of a dormant dependency: a pin, a
  gate item and a recorded fallback, never a wait.
- **CHK022 — the one bare research number is phrased like every other.** The dataplane assumption
  said the lab "forwards at a few thousand packets per second at most" as fact, where PC-S-10 records
  1000 PPS documented for the unlicensed container and ~5 kpps measured. It now carries both figures,
  their source, and the rule NFR-004 already applies to the per-node footprint: the number is
  re-stated from what the clean-host run observes, never quoted from research.
- **CHK020 — left open for the reviewer.** The item's second clause ("no `tasks.md` is produced") is
  overtaken: `tasks.md` exists, with 174 unticked boxes and none ticked. The substantive half holds.
  Rewording a checklist item is the reviewer's, so the checklist is untouched and this is recorded
  here rather than closed.

### AD-38: The requirements-checklist triage closures — one port list, named CI carriers, two compatibility-set parts

The second half of `checklists/requirements.md` (CHK091…CHK135) was triaged before implement. Ten
items came back PARTIAL. The closures below are wording and carrier work, not design: nothing was
renumbered, no identifier was added, and each names where the obligation now lives. Two items are
left for the reviewer, and are recorded here as open rather than closed.

- **CHK128 — the denied management port set is now one list, stated once.** Three surfaces carried
  three different lists: the quickstart probe omitted 80, the identity contract said "four open
  doors" while listing five ports, and PC-S-03 documented SNMP 161 and the vendor automation ports
  50052/57410/57411 that no probe dialled. The list lives in
  [contracts/kubernetes-objects.md](./contracts/kubernetes-objects.md) §Identity contract — TCP 22,
  80, 443, 830, 50052, 57400, 57401, 57410, 57411 and UDP 161, taken from
  [evidence/01-lab-platform.md](./evidence/01-lab-platform.md) §4.2 — and quickstart §15, plan P1 and
  the SC-029 row, `tasks.md` T066 and PC-S-03 now cite it instead of restating it. FR-075 states the
  obligation without numbers: the probe set is every port the image is *documented to expose*, never
  the set the platform uses. **Two honesty consequences.** *(a)* A UDP denial cannot be observed by a
  dial — no reply is indistinguishable from a silent server — so `161` is **recorded** by the probe
  and **asserted** by SC-028's per-source packet counter, which counts every protocol; SC-029 says
  so, and T070 keeps the NetworkPolicy CIDR-wide and protocol-wide so it never needs a port list of
  its own. *(b)* The documented list is **not an observation of the pin**: §4.2 was probed on a later
  release, and the same report's CPM-ACL baseline allows Telnet/23 with no listener recorded — the
  two halves of the evidence do not agree on what is open. Gate item **G2** therefore also records
  the ports the pinned image actually listens on (T043, to `tests/gate/observed/mgmt-ports.json`),
  and a listening port the probe set does not carry fails the P1 boundary step. No new gate item was
  added for it; G2 already owned platform identity.
- **CHK110 — "no credential literal in any manifest" gets a real carrier.** The rule was asserted in
  three places in `plan.md` and enforced by nothing: no make target and no task scanned manifests
  (T147's `credential_scan.sh` scans traces, logs and transcripts, which is SC-031, a different
  thing). FR-019 now states the rule and that a repository-wide check must carry it, T025 adds the
  scan to `scripts/ci/verify_boundaries.sh` over every manifest under `deploy/` with a fixture test,
  and the plan's make-target table names it. It runs on every pull request through T007.
- **CHK135 — FR-099's "asserted in CI" gets its carrier named.** The carrier already existed and was
  invisible: `pkg/migration/device_names_test.go` in **T096**, run by `make test-static`. The plan's
  make-target table now says so. Nothing was added; the only vocabulary scan that *was* visible
  (T142, `verify_vocabulary.sh`) is the SC-033 retired-name scan and never asserted anything against
  the device model.
- **CHK129 — the two compatibility-set parts `research.md` did not carry.** Containerlab `0.79.0` and
  the provider mapping `srl-mapping v0.1.0` were in `plan.md` and `contracts/crd-api.md` and in no
  research decision. RD-01 now carries both: containerlab `0.79.0` **has evidence** — it is the
  version this research ran (`evidence/01-lab-platform.md` §0, commit `5ae50094a`) and the one whose
  window covers the image pin (§4.3) — so it is cited, not merely asserted; `srl-mapping v0.1.0` is
  **first-party**, a version this repository mints, resolvable against no registry and therefore
  asserted by `make verify-compat` against parts 1–4 rather than resolved by `make verify-pins`.
- **CHK105 — a telemetry failure cannot block configuration.** The rule existed only in
  `data-model.md` §18. NFR-002 now carries it: the telemetry path is never in the configuration path,
  a failure in it is observable as its own failure and blocks nothing, and it may set `Degraded`
  while network readiness stands.
- **CHK108 — the privileged lab runtime is now a stated trust boundary.** It was documented only in
  `plan.md` (§Constraints and risk R-08). §Assumptions now states it: the emulated nodes need
  privileged containers and host network namespace access, it is documented rather than defended
  against, and it is the one host privilege taken — still no hypervisor and no nested virtualization.
- **CHK114 — the two naming registers are reconciled.** `spec.md` names components by role and
  `plan.md` by product, with no glossary joining them. §Scope and interpretation now says so
  explicitly, names the five roles, points at `plan.md` §Technical Context for which project fills
  each, and forbids a third name for the same role. The registers stay separate on purpose: a
  requirement that names a product cannot outlive it.
- **CHK121 — GAP-2 names one carrier.** The gap table said "FR-046, FR-048" where the item asks for
  exactly one; FR-046 is the single provenance record and FR-048 only references it. The row now
  reads "FR-046 (FR-048 references it, and adds no second record)".
- **CHK115 — left open, and scoped.** "Every rejected alternative is preserved" cannot be answered
  inside this folder: only 9 of the 37 inherited `D-xx` entries carry an *Alternatives rejected*
  block, and whether the merge lost any needs the 001/002/003 research files, which are not here.
  Recorded as answerable only against the sources, or to be narrowed to the retarget-era decisions,
  where all fifteen `RD-xx` entries do carry the block. No document changed.
- **CHK127 and CHK128(a) — left for the reviewer.** Both ask that the MTU numbers, the management
  CIDR default and the device addresses be identical **in `spec.md`** as well as everywhere else.
  They agree everywhere they appear, and `spec.md` deliberately carries none of them, because CHK001
  forbids that detail in requirement text. This is a conflict between two checklist items, not a
  defect in the document, and it is the reviewer's to rule on. **No change was made to `spec.md` for
  either.**

### AD-39: The clarify-delta triage closures — four success criteria, and the rules that lived only in contracts

`checklists/clarify-delta.md` (40 items, the post-clarify delta) was triaged before implement:
5 ANSWERED, 23 PARTIAL, 7 OPEN, 5 JUDGEMENT
([review/2026-09-20/checklist-clarify-delta.md](./review/2026-09-20/checklist-clarify-delta.md)).
The five JUDGEMENT items were the design choices the operator settled in `AD-31`…`AD-36`. The
closures below are the rest: wording, promotion of a rule from a contract into the requirement it
serves, and the four success criteria the operator authorized. Nothing was renumbered, no `FR`,
`NFR`, `R`, `T` or `G` identifier was added, and each closure names where the obligation now lives.

- **CHK001, CHK002, CHK003 — the force-release rules are requirements now.** The empty-reason
  refusal, "honoured only on an object that is both deleting and blocked on an unreachable target"
  and the denial to both tier identities lived only in `contracts/reconciliation.md` Rule 8 and
  `contracts/kubernetes-objects.md`, while FR-075 grants the deployer `update` on a `Network` — so
  the spec alone did not forbid the tier setting the annotation. FR-103 states all three, and with
  them the open-finding consequence (a render that would reproduce a named object on that device is
  refused; the `Fabric` reports **degraded, not not-Ready**), which was operator-visible acceptance
  behaviour stated nowhere in the spec. It also answers the target that never returns: removing the
  device from the `Fabric` completes nothing and releases nothing, so the force-release stays the
  only exit, and each unreachable target is named individually with one finding per service and
  device. Rule 8 and `data-model.md` §3a, §19 keep their statements and now cite FR-103 as their
  source.
- **CHK006 — `VerificationFailed` is defined, and a re-verification that cannot run has an
  outcome.** The reason code was listed on `Ready` in `data-model.md` §18 and explained nowhere, and
  FR-107 covered only a pass that *found* an invariant missing. A pass that could not run — target
  unreachable, read timed out — now reports `Degraded=True/VerificationFailed` naming the target and
  **leaves `Ready` where it stands**, because an outage is not evidence that an invariant is gone;
  `lastVerifiedTime` does not advance, which is what makes the stall visible. The code moved from
  `Ready`'s reason set to `Degraded`'s. *Amended by `AD-40` (operator decision, 2026-09-21): the
  pass that cannot run sets `Ready=Unknown/VerificationFailed` beside the `Degraded` condition and
  never leaves `Ready=True` standing; the reason is carried on both.*
- **CHK007 — the schedule's scope and the interval's floor.** FR-107 says an object that has never
  reported Ready is outside the schedule and one held in deletion stays inside it (the requeue
  `contracts/reconciliation.md` Rule 8 already made), and `REVERIFY_INTERVAL` gains a 30 s floor:
  a shorter or unparseable value refuses the provider's start rather than silently reverting to the
  default (`data-model.md` §25).
- **CHK030 — the stalled schedule has a metric and an alert.** "A stalled schedule is itself
  detectable" was not measurable: `provider` exports
  `reconcile_last_verification_age_seconds{kind,namespace,name}` and the alert
  **`ReverificationStalled`** fires once it exceeds one re-verification interval plus one
  reconciliation interval (`data-model.md` §21, `contracts/crd-api.md` §Status contract,
  quickstart §21). *Amended by `AD-49` (2026-09-21): the metric has one name,
  `reverify_last_success_timestamp_seconds{kind,namespace,name}` — a timestamp, from which the alert
  computes the age — which is the name `tasks.md` and `contracts/reconciliation.md` already built;
  the age-named series above was never built and is withdrawn.*
- **CHK026 — FR-107 adds no third client to the device management session limit.** FR-086 sizes the
  limit "for the two together" and the re-verification read load was unaccounted: re-verification
  reads the state the device-configuration layer already exposes and opens no session, stated in
  both requirements.
- **CHK004 — the probe-route exception is named in FR-102.** "Both surfaces MUST require an
  authenticated operator" stood against two unauthenticated probe routes in
  `contracts/supervisor-http.md`. FR-102 now names the exception by its property — a route that
  creates no thread, calls no model and claims no identifier — and carries rotation without restart
  and the thread continued under a different credential, deferring the credential's shape and the
  fixed failed-attempt delay to `data-model.md` §22.
- **CHK005, CHK035 — FR-106 is merge-safe and redaction-safe.** The Secret is written key by key
  (an omitted key keeps its value and is never deleted), clearing the base URL takes a named input
  of its own, an agent whose Secret loses its base URL while running stops calling the model rather
  than falling back to the library default, and the endpoint every provisioning and start-up line
  prints is **redacted of any credential the base URL embeds** (FR-079) — the conflict between
  "MUST name the endpoint" and "MUST redact credentials from every log" that CHK035 found.
- **CHK008, CHK018 — FR-108's three terms, and the tool that dies mid-write.** *Scratch
  configuration*, *a declared injected fault* and *a device client* are defined in the requirement
  so that two implementers flag the same invocations; and because a tool can die between writing and
  removing, everything of the first two kinds is named or labelled and a gate or acceptance run
  refuses to start while such a leftover is on any node.
- **CHK015, CHK016, CHK032 — FR-105's scope.** The hash is stated to be computed from the
  server-side dry-run result (`contracts/network-spec.md` §3, which now cites FR-105); the
  comparison is over `spec` alone, so a label or annotation edit is not an out-of-band change; a
  removal asked of a service already found modified is not executed by the turn that detects it; and
  detection is deliberately on demand, working from any thread because the hash is on the object.
  SC-030 names its injected set as `spec` edits and deletions made with cluster tooling.
- **CHK017 — "drift" and "out-of-band change" are reserved words.** §Scope and interpretation fixes
  each to one meaning: drift is a deviation on an owned device path, repaired under FR-015; an
  out-of-band change is an edit or deletion of a service intent object outside the tier, detected
  and never reverted (FR-105).
- **CHK012 — FR-104's substitution has preconditions.** A substitution is adopted on a lab holding
  no bound claim; where one is held the services resting on it are enumerated and re-created,
  because no claim survives a change of authority. Returning to the upstream authority is the same
  recorded decision in reverse.
- **CHK020 — NFR-014 says where its contract lives.** The field names, the level set, the timestamp
  format and the stream are fixed in `data-model.md` §27 and nowhere else (standard output), and the
  lifecycle-script exclusion is reasoned rather than asserted: those lines are read by the operator
  watching a run, not by a log consumer, and every outcome they report is also a condition, an Event
  or a metric — so constitution Principle IV is carried where a consumer exists to read it.
- **CHK028, CHK029 — two success criteria measure what they claim.** SC-042 reconciles against the
  set of operator *usernames* a run used, since the principal is the username and a password
  rotation therefore cannot invalidate an earlier event, while a username change mid-run invalidates
  the measure and is recorded. SC-043 gains the two halves of FR-103 it did not measure: an
  empty-reason force-release releases zero identifiers, and the finding clears only after a clean
  read-back.
- **CHK031 — the negative control is stated once.** NFR-013's control was named per readiness check
  and not by SC-042…SC-046. The §Measurable Outcomes preamble states it for every criterion, audited
  by SC-040, instead of repeating it in each.
- **CHK027 — the four delta requirements without a measure get one.** FR-104, FR-106, FR-108 and
  NFR-014 had no success criterion and no record that the absence was intended. **`SC-047`**
  (FR-104: exactly one allocation authority; a failed gate item stops provisioning naming it),
  **`SC-048`** (FR-106: the Secret survives re-provisioning byte-identically, only the named input
  clears the base URL, and no endpoint line carries a credential), **`SC-049`** (FR-108: no device
  client outside the gate, the suites and the walkthrough, with the gate's scratch removal read
  back) and **`SC-050`** (NFR-014: every first-party line parses with its fields, carries its
  correlation identifier and carries no credential) are added. Each is measured by tasks that
  already exist — T044 and T050, T168, T025 and T043, T147 — so no task was added and coverage
  stays complete.
- **CHK034 — the four new requirements get edge cases.** A re-verification that cannot run, a
  schedule that stops advancing, an allocation gate item that fails, verification tooling
  interrupted mid-write, and a gateway declared or left without a base URL.
- **CHK040 — the delta's review vehicle is recorded.** `checklists/requirements.md` carries no item
  for FR-102…FR-109, NFR-014, SC-042…SC-050 or CR-008; `plan.md` now records
  `checklists/clarify-delta.md` as their review vehicle, so no identifier is reviewed by neither.
- **Left open, and why.** CHK010, CHK011, CHK019, CHK033 and CHK036 are claim-adoption questions
  settled with the claims work of `AD-32`; CHK025's ordering of the audit export against operator-
  credential removal belongs with `AD-36`; CHK038 needs no wording change — the five clarification
  answers are all carried, and candidates 2, 3 and 5 are correctly still live defaults.

- **Consequences**: FR-086, FR-102, FR-103, FR-104, FR-105, FR-106, FR-107, FR-108, NFR-014,
  SC-030, SC-042, SC-043, **SC-047**, **SC-048**, **SC-049**, **SC-050**, §Scope and interpretation
  and five edge cases; `data-model.md` §3a, §18, §19, §21, §25, §27;
  `contracts/reconciliation.md` Rule 8, `contracts/crd-api.md`, `contracts/supervisor-http.md`,
  `contracts/network-spec.md`; plan.md's verification-strategy table and its checklist tree;
  quickstart §4, §20, §21, §23, §24, §27; tasks T025, T043, T044, T050, T147, T168 — cited, never
  added.

### Fifth pass — 2026-09-21

The fifth cross-artifact analysis (2026-09-21) found one constitution conflict and twelve high findings,
most of them in the operator review's own propagation. `AD-40`…`AD-43` are **operator decisions**, put
to the operator before any edit; `AD-44` and `AD-45` are choices made on the analysis's recommendation,
reversible, with the alternative recorded; `AD-46`…`AD-50` are closures that needed no decision.

### AD-40: A re-verification that could not run sets `Ready=Unknown` *(FR-107, FR-100, SC-008, constitution Principle I — operator decision)*

- **Decision**: **operator decision, 2026-09-21.** A scheduled re-verification that **could not
  run** — a required target unreachable, or the read timed out — on an object that had reported
  Ready sets **`Ready=Unknown` with the reason `VerificationFailed`, at that pass**, together with
  `Degraded=True/VerificationFailed` naming the target. `status.lastVerifiedTime` does not advance.
  It never sets `Ready=False`, and it never leaves `Ready=True` standing. The next pass that runs
  settles it: `Ready=True` if both sides of the read-back pass, `Ready=False` naming the invariant
  if one is missing. `Ready` is the only condition of this API that takes the `Unknown` status and
  `VerificationFailed` is the only reason it takes it with. The same outcome applies when the
  reconciler, between two scheduled passes, observes a required target of a Ready object not Ready
  — that is a read-back that cannot run, and treating it as one is what lets SC-008's
  two-reconciliation-interval bound and this rule be the same rule rather than two. Nothing that
  reads `Ready` may read `Unknown` as success: not the tier's convergence watch (FR-067), not a
  status answer (FR-054), not an acceptance check.
- **Rationale**: the fifth pass's one constitution finding. The operator review's closure (`AD-39`,
  CHK006) had the pass that cannot run report `Degraded` and **leave `Ready` where it stands**, on
  the sound ground that an outage is not evidence that an invariant is gone. But with the target
  away, "where it stands" is `Ready=True`, for as long as the outage lasts, resting on a read
  nobody can repeat — and constitution Principle I says `Ready=True` "MUST reflect current live
  fabric state verified on devices, never historical success or a prior reconciliation result".
  FR-107 said both things in one paragraph: "`Ready=True` is never a memory of an earlier pass" and,
  two lines on, "MUST leave `Ready` where it stands". `data-model.md` §18 still closed with
  "`Ready=True` is forbidden when any required target is not Ready" and allowed `Degraded=True`
  beside readiness "only for a non-blocking telemetry failure", which the same section's
  `VerificationFailed` and FR-103's `StaleConfigurationPossible` both broke; SC-008 demanded "no
  false aggregate Ready state" on a device failure; and the plan's Principle I row passed without
  mentioning the case. Both halves of the old closure were right about what they refused — False
  would assert a loss nobody observed, True asserts a presence nobody observed — and Kubernetes
  conditions already have the value for "not observed". `Unknown` is the truthful report, and it is
  the only one of the three that is.
- **Alternatives rejected**: *`Ready=False/TargetUnreachable`* — it keeps Principle I by
  overstating: it tells the operator, the tier and every alert keyed on `Ready=False` that a service
  is down when the dataplane may be forwarding untouched, it makes a management-network outage
  indistinguishable from a fabric failure in exactly the moment the two must be told apart, and it
  would count every outage as a lost invariant in SC-044's measure. *Leaving `Ready=True` to stand
  and turning it `Unknown` only after FR-107's bound (one re-verification interval plus one
  reconciliation interval)* — it is the smaller change, and it still reports a prior reconciliation
  result as current for up to that bound after the platform already **knows** it could not verify;
  the principle has no grace period, and a rule with one needs a second timer, a second test and
  an explanation of why five minutes of remembered readiness is acceptable when six is not. *Leaving
  the operator review's text and recording a justification in the Constitution Check* — a recorded
  exception to the first principle, for a case a third condition value removes, is the kind of
  exception the predecessor's record is made of.
- **Consequences**: FR-107 (the cannot-run sentence replaced; "never a memory of an earlier pass"
  kept), FR-054 and FR-067 (`Ready=Unknown` is never a success), SC-008 and SC-044 (the latter gains
  the cannot-run half) and the cannot-run edge case; `data-model.md` §3a, §17, §18 — the `Ready` row
  gains the `Unknown` state, `VerificationFailed` is redefined, and the closing sentence becomes the
  **closed list** of `Degraded=True` cases that may coexist with `Ready=True`: a non-blocking
  telemetry failure, and the `Fabric`'s open force-release finding (FR-103);
  `VerificationFailed` is never one of them — §19, §21; `contracts/crd-api.md` §Status contract;
  `contracts/reconciliation.md` Rule 5 and its required-tests row; plan.md's Principle I row, its
  SC-008 and SC-044 rows and its scheduled-re-verification row; quickstart §21, §27a and the
  failure table; T023, T028, T054, T167, T134. `AD-39`'s CHK006 bullet is amended in place by a
  note and is otherwise left as the record of what the operator review decided. No risk row
  described the old behaviour, so the register is unchanged. No identifier was added.

### AD-41: The naming band is enforced at the mapper, before any claim exists *(FR-062, FR-034, AD-33 — operator decision)*

- **Decision**: on the intent-tier path the naming band of `AD-33` — an operator names a VLAN only
  from `100–999` — is enforced **by the mapper, at interpretation, before any claim exists**, and the
  refusal states both bands. A VLAN present in an interpretation is by construction one the operator
  *named*, because the allocator has not run; that is the only stage of the pipeline of which this is
  true. The translator keeps **only** the structural `100–4000` check, which is also the CRD's: it
  cannot tell a named VLAN from an allocated one and is never asked to. **No provenance field is
  added** to the normalized service intent. The cluster-tooling path is untouched — `AD-33`'s
  by-value claim gate in the provider decides there.
- **Rationale**: `AD-33` gave the tier-path half of its rule to the translator — "the translator
  enforces the naming band on the tier path" — and the sentence went into five artifacts with
  "before anything is claimed" attached. It cannot hold. The translator's only input is the
  allocator's output (`contracts/normalized-service-intent.schema.json`: "the allocator's output and
  the ONLY contract by which agent-assigned resources reach the fabric"), so it runs after the
  claims are made, and in that input a VLAN is a bare integer. T091's fixture
  `vlan_named_in_allocation_band` required it to refuse VLAN 1500 while T173's allocated VLAN 1500
  had to pass it, on a byte-identical input shape: the requirement was untestable as written, and
  the stage that *can* make the distinction — the mapper (T098, plan C-12) — carried no band check
  at all.
- **Alternatives rejected**: *a provenance field on the normalized service intent* (`vlanSource:
  named | allocated`) so the translator can enforce the band — it widens the one contract FR-060
  exists to keep narrow, it makes the translator trust a claim about provenance it cannot verify,
  and it would still refuse *after* the claims were made, so a named VLAN of 1500 would cost a claim
  round-trip and a release before the operator heard of it. *Both — the mapper check and the
  provenance field* — two enforcement points for one rule, with the goldens and the equivalence
  oracle (SC-021) paying for the second. *The allocator enforces it* — it is after the first
  confirmation, so the operator would confirm an interpretation the platform already knows it will
  refuse.
- **Consequences**: FR-062, FR-034, an edge case; `contracts/interpretation.schema.json` (the
  `vlan` property), `contracts/normalized-service-intent.schema.json` (the same, stating that no
  provenance is carried), `contracts/translator-api.md` §Rules, `contracts/kuid-claim-profiles.md`
  §2 rule 1 and §4, `contracts/crd-api.md` rule table, `contracts/construct-vocabulary.md` §5;
  `data-model.md` §11, §20; `plan.md` C-12, P7, R-28, the SC-015 verification row; quickstart §6
  and the diagnosis table; tasks T091 (the fixture moves to its new mapper half,
  `agents/tests/unit/test_mapper_refusals.py`, and a positive translator fixture with VLAN 1500 is
  added), T095, T098, T017, T173. `AD-33`'s sentence is amended in place by a note. No dedicated
  mapper unit-test task existed; T091 was extended rather than an id minted.

### AD-42: VNI and VLAN claims are adopted on the same three things *(FR-109, R-45, AD-32 — operator decision)*

> **Amended by AD-51** (operator decision, 2026-09-21): the `<entry>` of a VLAN claim's role
> `vlan-<entry>` is the name of a `vlans[]` or `bridgeDomains[]` entry and nothing else. An
> `attachments[]` entry has no name, and none is needed: no VLAN is ever allocated for an `ip-vrf`
> attachment, so no claim exists that would have to be named after one.

- **Decision**: a claim is adopted on **three things together — the correlation label, the
  deterministic claim name and a value the object carries — and the rule is the same for a VNI claim
  as for a VLAN claim.** There is one naming scheme, `<namespace>.<name>.<role>`, the one `AD-09`
  gave the provider for the claims it creates: the allocator names a VLAN claim
  `<intent-namespace>.migr-<serviceId>.vlan-<entry>` (as `AD-32` had it) and a VNI claim
  `<intent-namespace>.migr-<serviceId>.l2vni-<bridgeDomain>` or `.l3vni-<router>` — the provider's
  own role strings. A match on label and value under any other name adopts nothing.
- **Rationale**: `AD-32` closed adoption-by-copied-label (CHK033, R-45) for VLAN claims and its
  headline said so for claims in general, but its fifth amendment read "an adoptable **VLAN** claim
  must also bear the deterministic name", and the artifacts split on it: FR-109,
  `contracts/kuid-claim-profiles.md` §8 and T170 adopted a VNI claim on label and value; T171 and
  the reconciliation contract's test row adopted "VNI and VLAN alike" on all three; §5 defined a
  name for VLAN claims only, so the three-part reading had nothing to check a VNI claim's name
  against. Under the two-part reading a `Network` applied with cluster tooling that copies another
  service's correlation label **and its VNI** adopts that service's VNI claim and releases it on
  deletion, with a device still carrying the identifier — the hazard FR-103 exists to prevent, left
  open for the identifier that matters most. The allocator can form every name: the intent
  namespace is fixed, `serviceId` comes from the interpretation, and the entry names the translator
  emits are functions of it (`contracts/network-spec.md` §2).
- **Alternatives rejected**: *two-part for VNI, three-part for VLAN* — it keeps the hole above, and
  it makes one predicate two. *A second naming scheme for the tier's VNI claims* — two schemes for
  the claim behind one field of one object, and the provider's claim path and its adopt path would
  no longer agree on what that claim is called.
- **Not assumed**: nothing new about the pinned authority. A claim's name is ordinary object
  metadata; that its `metadata.labels` are selectable stays a G11 observation (R-44).
- **Consequences**: FR-109, SC-046; `contracts/kuid-claim-profiles.md` §2 rule 1, §5, §8;
  `contracts/reconciliation.md` Rule 3 and the contract-test row; `data-model.md` §11 (`ClaimRef.name`),
  §20; `plan.md` Technical Context, C-05, C-13, R-44, R-45, the "Provider-side claims" row;
  quickstart §26a; `traceability.md` FR-109(b); tasks T093, T099, T170, T171, T173. The phrase
  "label-and-value rule" is retired from every current statement of the predicate. `AD-09`, `AD-16`
  and `AD-32` describe the rule as it stood when they were written.

### AD-43: SC-004's route-half negative control is a declarative fault *(SC-004, FR-108, FR-013, R-46, R-48 — operator decision)*

- **Decision**: **operator decision, 2026-09-21.** The negative control of SC-004's route half is a
  **declarative fault, injected through the platform the way T167 injects SC-044's**, and never a
  device-side edit. `verify_services.sh` patches `Fabric.spec.overlay.interASVPN` to `false`; the
  fabric reconciler renders `inter-as-vpn false` on every reflecting spine through the one
  southbound; every session stays established and nothing is reflected, which is `RoutesMissing`'s
  own definition; the suite waits for the spanning service to report `Ready=False/RoutesMissing`
  naming the routes it lacks within SC-044's bound — one re-verification interval plus one
  reconciliation interval, with `REVERIFY_INTERVAL` overridden to a test value as T167 does — sets
  the field back to `true`, and reads the restoration back (the spines report `true`, the `Fabric`
  and the service are `Ready=True` again within the same bound) before the positive assertion is
  admitted, all through `evidence_run`. While the field is `false` the `Fabric` reports
  `Ready=False/NotConverged` naming each reflecting spine and the setting: its read-back of the
  reflection settings is unchanged — it reads `true` or the `Fabric` is not Ready — so a fabric whose
  reflectors are *declared* unable to reflect says so, exactly as it does under
  `spec.maintenance[]`. No reason code is added. No CEL or webhook rule refuses or warns on
  `interASVPN: false`; none existed, and the contract now says that none may.
- **Rationale**: the control as `AD-23` and `AD-31` left it removed `inter-as-vpn` from one spine
  with a host gNMI Set and required `RoutesMissing` "before the revertive policy restores the
  setting". That path is owned by the fabric `Config` at priority 10, so the revertive policy
  reapplies it — `R-48` records that it may do so before even a `Deviation` is observable — while
  the service re-reads its routes only on FR-107's schedule, five minutes by default. Nothing held
  the fault open, so the control could be raced away on every run, and `AD-31` forbids recording
  SC-004 without it: the criterion was unrecordable by construction. The operator review had named
  the race (U-2 in [review/2026-09-20/AD-17-drift-policy.md](./review/2026-09-20/AD-17-drift-policy.md))
  and only its sibling U-1 was carried forward, as G13. The old control had a second defect the race
  hid: with the setting removed from **one** spine the other still reflects, every leaf keeps a
  full set of routes through it, and the service has nothing to miss — the control could not have
  failed the check even with the window held open. A fabric-wide declarative field withdraws
  reflection on both spines at once. It is intent, so nothing reverts it; it reaches the device by
  the fabric reconciler, so it stays inside FR-013 and FR-015 and FR-108's device-session carve-out
  is not used for it; and the field already existed (`data-model.md` §3a), so nothing is added to
  the API.
- **Alternatives rejected**: *a test-only annotation that triggers an immediate re-verification* —
  it shortens the wait and leaves the race in place, since the layer may still reapply first; it is
  a change path into readiness that exists for the test alone, the kind of seam FR-108 exists to
  keep out of the platform; and it would do nothing about the second spine. *Accepting "not
  demonstrated" for SC-004, as R-48 does for SC-007* — SC-007's unknown is an upstream behaviour the
  platform cannot choose, whereas this one was the design's own choice of injection, and SC-004 is
  the criterion that stands against the predecessor's "sessions up, zero routes" failure. *Setting
  the fabric `Config` non-revertive for the duration of the test* — test tooling mutating a
  platform-owned `Config` field, and a second drift policy in all but name (AD-34). *Removing the
  setting from both spines by hand* — still raced, and two device-side edits where none is needed.
- **Consequences**: spec SC-004; `data-model.md` §3a (the `spec.overlay.interASVPN` row and the
  readiness paragraph); `contracts/crd-api.md` (`Fabric` accepts `false`);
  `contracts/reconciliation.md` (the `Fabric`'s applied side); quickstart §8; plan P3's gate, the
  SC-004 row, R-37, R-46 and R-48 — R-48 is now SC-007's risk alone; traceability R-46 and R-48;
  tasks T027, T039, T041 and T064; research `AD-23` and `AD-31`. No new requirement, criterion,
  task, risk, gate item or reason code.

### AD-44: Finalization resolves adoption before it releases *(FR-109, AD-32)*

> **Ratified by the operator, 2026-09-21 (`AD-73`)**, as written. It is an operator decision from here on; the alternative recorded below stays recorded and is no longer open.


- **Decision**: **finalization resolves adoption before it releases.** On an object that carries a
  deletion timestamp the provider first runs the adoption predicate — the same three-part rule of
  `AD-42`, nothing looser — for every value the object carries that is not yet in
  `status.claimRefs`, records what it adopts, and only then walks the ordered deletion and releases.
  It never *creates* a claim on a deleting object. A tier-submitted `Network` deleted before the
  provider's first reconcile therefore leaves no claim behind.
- **Rationale**: `AD-32` put the finalizer on a tier-submitted object at apply so that "no window
  exists in which it can be deleted outright and leave its claims with no release owner". A
  finalizer holds an object; it releases nothing. Adoption was a Rule 3 gate — it runs before a
  render — and Rule 8 released "`status.claimRefs`, the whole list and the only list", having first
  stopped new render changes. An object deleted in exactly the window `AD-32` was written for
  reached the release step with an empty list: the finalizer was removed, the object went, and the
  tier's claims stayed bound with nobody to release them — the tier may not (the service was
  submitted), and no timer may (FR-103). No test covered the case.
- **Alternative rejected**: *the deployer writes `status.claimRefs` when it applies the object* — the
  tier's writer identity holds no verb on the `networks/status` subresource and FR-075's verb sets
  are exact; granting it would let the tier assert which claims the provider must release, which is
  the provider's judgement to make and the thing the three-part rule exists to check. *The deployer
  releases the claims of an object it finds gone* — it cannot know the removal was read back, the
  early-release hazard `AD-16` rejected. This is a **choice made on the analysis's recommendation**
  and is reversible: the alternative needs only a status verb and a changed release step.
- **Consequences**: FR-109, SC-046, an edge case; `contracts/reconciliation.md` Rule 8 steps 1 and
  6 and the contract-test row; `contracts/kuid-claim-profiles.md` §8 ("Adopt (at finalization)");
  `data-model.md` §20; `plan.md` Technical Context, C-05, the "Provider-side claims" and SC-046
  rows; quickstart §26a; `traceability.md` FR-109(i); tasks T055 and T170 (the never-reconciled
  object, in envtest, where the reconciler can simply not have run), T060, T171, and T173 — whose
  live variant kills the provider's pod as the apply is reported and asserts the end state only,
  because the admission webhook is served by the same binary and the race cannot be staged
  deterministically on a live cluster.
- *Amended by AD-52* (operator decision, 2026-09-21): that webhook **fails closed**. The pod is
  killed after the apply is reported and never before it — an apply while the provider is down is
  refused by the API server — and the variant rests only on the delete, which is not intercepted.

### AD-45: The analytics store is deployed before the first test that reads it *(FR-078, SC-030)*

> **Ratified by the operator, 2026-09-21 (`AD-73`)**, as written. It is an operator decision from here on; the alternative recorded below stays recorded and is no longer open.


- **Decision**: the agent-analytics store and the tier collector are **built and installed with the
  tier's first workloads, not with the dashboards**. `deploy/agents/clickhouse.yaml` and
  `deploy/agents/agent-otel-collector.yaml` move from T136 (US12, plan P9) into T087 (US7, plan P6),
  and T088's tier phase installs them first — after the denial probes, before any agent workload,
  waited Ready. The collector leaves US7 with **one** exporter, the store; T136 keeps what is US12's —
  the second exporter, the forward to the fabric collector, which does not exist in build order until
  US11 has built it — and is reworded as an extension of T087's file. The credentials are unchanged:
  `clickhouse-auth` was already generated by T072, a phase earlier. No task id is added. A choice made
  on the analysis's recommendation and **reversible**: undoing it is moving two manifests back.
- **Rationale**: the store "is also the audit record" (FR-078, AD-18), and three things read or
  write it long before US12: T101's audit span events (US4), T103's SC-030 reconciliation (US4, "read
  from the analytics store, never from Kubernetes Events") and the unconditional export of T088 and
  T174 (US7). The task list built it in Phase 13 while stating that US12 depends on US4, so US4 could
  not close without US12 and US12 could not start without US4; and no task added the two manifests to
  the provisioning path at all, where T126 does say so for the chat surface. plan.md carried the same
  order, P7 reading a store that P9 deployed.
- **Alternatives rejected**: *move `test_audit_reconcile.py` out of T103 into Phase 15* — it leaves
  SC-030 unmeasured until hardening, and it does not remove the problem, because the purge test and
  the export of US7 already need a store to exist. *Mint a task for the two manifests* — T087 is the
  task that authors the tier's manifests and T088 the one that installs them; the work belongs in
  both and needs no third id. *Ship the collector with both exporters at US7* — the forward would
  point at a collector no task has built yet, and a stage that fails every send is the signature the
  pipeline alerts exist to catch.
- **Consequences**: tasks T087, T088, T136, T166 (its consumer list), the US7 header and checkpoint
  and the US12 dependency sentence; plan P6, P7, P9; quickstart §1 (`IntentTierReady`);
  `contracts/kubernetes-objects.md` (the collector row); `traceability.md` FR-078(c). No requirement,
  criterion, task, risk or gate item added.

### AD-46: Fifth-pass closures — tier removal and the audit export

The fifth analysis pass read `AD-35` and `AD-36` against every artifact that states them. Both
decisions had been propagated — no current text still deleted services by default, the two bounds
and the three flags were spelled alike everywhere — and what remained was seams between them: an
export nothing read back, a reconciliation aimed at a Secret the removal deletes, one task whose
order disagreed with its own test, a path the quiesce did not cover, a re-run rule stated two ways,
and one acceptance scenario carrying two outcomes. None needed the operator: where a choice had to
be made, the reading closest to `AD-35` and `AD-36` as written was taken and the alternative is
recorded here. No `FR`, `NFR`, `SC`, `R`, `G` or `T` identifier was added or renumbered.

- **The export is read back** *(FR-078, SC-030, SC-042)*. `AD-36` rejected leaving the format to
  implementation because "a record nothing can read back is not one", and then nothing read it
  back: the quickstart said the reconciliation test "reads it instead of the store", while the only
  task that writes that test fixed its source as the analytics store, and the removability run
  asserted that the artefact exists and carries its fields. `test_audit_reconcile.py` gains a
  **file-source mode** (`--audit-export <artefact>`) that runs the stream half of SC-030 and SC-042
  from the exported newline-delimited JSON and the usernames record alone, touching neither store
  nor cluster, and reports the live-object half as not run — never as passed. T103 proves the mode
  against an export of the live store; T152 ends with it, once the store and the Secret are gone.
  FR-078 now requires the read-back.
- **SC-042 survives the Secret** *(SC-042, FR-078, FR-102)*. SC-042 reconciles against "the set of
  operator usernames the run used" (`AD-39`), but the plan, T148 and the quickstart still said "the
  generated operator Secret" — a tier artefact that goes with the tier's namespace, so the
  reconciliation `AD-36` promises from the file had nothing to be reconciled against. The tier
  phase captures the Secret's `username` — never the password — through `evidence_run` on every
  provisioning run, and the export step captures it again and writes the usernames record beside
  the export, **before anything removes the Secret**, on both down paths: the distinct set over the
  lab's captures, and `username_unchanged`. T088 carries both halves, because it is the one task
  that owns the tier phase and the removal, and the export function it shares with T049 is the
  step `AD-36` already orders ahead of every deletion. *Rejected*: writing the record in T148 — it
  runs while the tier is up and would not bind the capture to the moment before the credential
  goes; and deriving "unchanged" from the stream's own principals, which is the measure judging
  itself.
- **Two lists, told apart** *(NFR-006)*. `AD-35` has the removal list first and refuse, and with
  the flag scale down "first"; the spec, the plan, T152 and T174 put the scale-down before "the
  list", while T088 listed, then scaled down, then "confirmed no `Network` appeared after the
  list" — an order its own call-order test would fail. Both are right about different lists, and
  they are now named: **(a) the refusal-decision list**, a read that changes nothing and decides
  only whether to go on; **(b) the quiesce**; **(c) the authoritative list**, taken after the
  scale-down, which is the list of what is deleted. T174 asserts that the only call before the
  scale-down is (a) and that the scale-down precedes (c) and the export.
- **The quiesce covers every path past the refusal** *(NFR-006, FR-078)*. `AD-35` tied the
  scale-down to `--remove-services`, which left the run without the flag over an empty list going
  on to the export with the request-accepting workloads still up — so the reason `AD-35` gives for
  the quiesce, "no audit event is written after the export", did not hold there, and neither did
  the edge case's "the surface that would accept it is already gone". The scale-down now precedes
  the export on every path that goes past (a). Without the flag, a non-empty (c) — a service that
  landed between the two lists — **falls back to the refusal**: non-zero, the service and both
  continuations named, nothing deleted and nothing exported. The workloads stay scaled down and the
  message names re-provisioning as what restores them, which is what the blocked-finalizer stop
  already does. *Rejected*: scaling the workloads back up on the fallback — the script would have
  to remember replica counts and become a second writer of the tier's desired state, where
  re-provisioning already is the first. The full `off.sh` is untouched by this closure: `AD-35`
  exempts it by name, and whether it should quiesce before its own export is the operator's to say.
- **A re-run: one rule, stated once** *(FR-078, SC-040)*. `AD-36` says a re-run "adds an artefact
  instead of rewriting one" and, in the same sentence, "skips the export where this run's evidence
  already holds a verified one"; FR-078, the data model and the obligations index carried the first
  half, T088 alone the second, *verified* was defined nowhere, and T011's `EVIDENCE_DIR` defaults
  to a per-invocation directory in which a re-run can never find the earlier attempt. The rule is
  now in `data-model.md` §16 and nowhere else, cited from FR-078, T088, T174 and the quickstart: a
  re-run **skips** — capturing the skip, naming the artefact it relied on — where a *verified*
  export exists, and **adds** one under a new attempt identifier otherwise; it never rewrites. An
  export is *verified* when its evidence record carries exit status zero and a written-row count
  equal to the store's count at the time, the artefact's content hash still equals the recorded
  one, and the store asked again now reports that same count. *Amended by `AD-55`: the record
  also carries the newest stored row's timestamp, and the third condition requires that same count
  **and** that same timestamp — a count alone is not the store's identity.* The re-run looks under the **lab's
  evidence root**, by the NFR-013 cluster and lab identity, not under its own run id: "this run's
  evidence" in `AD-36` is read as the lab run's. *Rejected*: skipping on any earlier export that
  passed the first two checks — a tier re-provisioned after a stopped removal writes again, and the
  skip would discard those events without `--discard-audit-record` ever being given; and always
  adding — it contradicts `AD-36`'s skip and re-reads a store the removal is waiting to delete.
- **User Story 7 scenario 4 is 4a and 4b** *(NFR-006)*. One *Then* carried the refusal and the
  removal together — "otherwise the removal stops with them named and still running — all tier
  workloads stop" — so neither outcome could be asserted. 4a is the refusal: non-zero, each service
  and both continuations named, nothing changed, no export. 4b is the removal asked for: quiesce,
  export, finalization, no workload and no claim left. The number is kept. The spec's Independent
  Test says what the task list's already said.
- **Stale text.** The traceability row for R-47 still described a removal that deletes services and did
  not cite `AD-35`; the plan's "Audit record" verification row said "no TTL shorter than the
  lab's life" where FR-078 and `AD-24` say no expiry, and named the store as the reconciliations'
  only source; the plan's architecture banner showed `off.sh` with one of its three flags.
- **Consequences**: NFR-006, FR-078, SC-042, User Story 7 (Independent Test, scenario 4 → 4a/4b),
  three edge cases reworded and one added; `data-model.md` §16 (the re-run rule, the usernames
  record, the file-source mode), §22; `contracts/kubernetes-objects.md` (the `clickhouse`,
  `operator-credentials` and `agentic-netops-intent` rows); quickstart §19, §24 (the 4a check, the
  read-back step), §25; plan C-18, P11, the SC-042 row, the "Audit record" and "Audit export and
  tier removal" rows, R-47, the architecture banner; tasks T049, T088, T103, T141, T148, T152,
  T174; `traceability.md` R-47 and the FR-078 obligations index (rows (e), (g), a new label (h)).
  No new requirement, criterion, risk, gate item or task.

### AD-47: Fifth-pass closures — claims and the VLAN bands

> **Amended by AD-51** (operator decision, 2026-09-21): closure (3)'s "already carries" is the VLAN
> of the object's own `vlans[]` or `bridgeDomains[]` entry — `status.claimRefs` is dropped from it,
> the `ip-vrf` case it covered no longer existing. **And by AD-56**: closure (6)'s "seven" is
> superseded by one list and one count — the **six** observations (a)–(f) of
> `contracts/kuid-claim-profiles.md` §6 — and closure (5)'s exemption of the standalone `acl` is
> carried into the added-attachment rule's own task and test.

- **Decision**: seven closures in the claims and VLAN-band slice, none needing a design decision.
  (1) **FR-075 names `patch`.** The deployer's verbs are `create, read, update, patch, delete` in
  FR-075 and User Story 6 scenario 3, as `AD-04`, the identity contract, plan C-15, T066 and T069
  already had them; server-side apply needs it, and neither `update` nor `patch` reaches the
  force-release annotation, which admission denies to both tier identities (FR-103). Scenario 3's
  allocator wording becomes "never update or patch". (2) **VLAN 100 is a named VLAN.** User Story 4
  scenario 4, quickstart §11 and the exemplar of `contracts/network-spec.md` §6 said it was
  allocated; it lies in the naming band, is carried as named and claims nothing — one L2VNI is what
  that request allocates. (3) **The added-attachment rule is scoped.** It refuses an allocation-band
  VLAN the object does **not already carry** — in `vlans[]`, `bridgeDomains[]` or
  `status.claimRefs`. Unscoped, it contradicted the one-VLAN-per-bridge-domain rule: every
  attachment of a `vlan` or `mac-vrf` must carry the service VLAN, so a service whose VLAN was
  allocated could never gain an attachment, for the stated reason "nothing would claim it" when its
  claim was already adopted. (4) **Pre-`AD-33` wording is removed** from FR-034, the constraint
  table of `contracts/construct-vocabulary.md`, the interpretation schema, `data-model.md` §11 and
  plan's SC-015, "Provider-side claims" and "Immutable identifiers" rows: the constraint is the
  naming band `100–999`, refused with both bands stated, not "the range the allocation authority
  manages", which a named VLAN must now lie *outside*. T017's clause expecting the schema to refuse
  a VLAN of `1000–4000` is corrected — CEL accepts it, by `AD-33`'s own design. (5) **The VLAN a
  standalone `acl` names is a reference** to a subinterface another service created, not a VLAN of
  its own, and is exempt from both band rules: the mapper does not hold it to the naming band, and
  the provider's claim gate looks for no claim behind the attachment VLAN of an `accessLists`-only
  object. Without it an access list could not be bound to any service whose VLAN was allocated, on
  either path. (6) **G11 observes synchronous release** — a stated-value claim is deleted and an
  immediate second claim for the same value binds — which `AD-32` and Rule 8 step 6 said G11
  observed and no definition of G11 included. It extends G11's observation list to seven; it mints
  no gate item. (7) **The provisional-determination MUST is stated once**, in FR-075; FR-062 and
  FR-109 cite it. The band literals stay wherever a message must state them.
- **Rationale**: each is a place where an operator decision of 2026-09-20 was propagated to most
  artifacts and not all, or where two rules written by different passes met for the first time.
  None changes a decision; (3) and (5) state what `AD-33` plainly intended and did not write down.
- **Not assumed**: that deleting a claim frees its value as the DELETE returns is read from
  `v0.0.13` source and is now actually **observed by G11**, with its negative control the refusal of
  the same second claim while the first still exists (R-44).
- **Consequences**: FR-034, FR-062, FR-075, FR-109, User Story 4 scenario 4, User Story 6 scenario
  3, three edge cases; `contracts/crd-api.md` rule table and contract tests,
  `contracts/kuid-claim-profiles.md` §2, §4, §6, §8, `contracts/reconciliation.md` Rule 3 and Rule 8
  step 6, `contracts/translator-api.md`, `contracts/interpretation.schema.json`,
  `contracts/construct-vocabulary.md` §5, `contracts/network-spec.md` §6; `data-model.md` §11, §12,
  §20; `plan.md` C-12, G11, R-44 and three verification rows; quickstart §6, §8, §11, the gate
  table and the diagnosis table; `traceability.md` FR-109(f), (h), (k), R-44; tasks T014, T017,
  T044, T091, T105, T106, T170, T171.

### AD-48: Fifth-pass closures — fabric readiness, drift policy and the gate

The fifth pass found six places where `AD-31` and `AD-34` had been applied unevenly. The closures
below are wording and carrier work, not design: nothing was renumbered, the only identifier added is
Open item 18, and each closure names where the obligation now lives.

- **The stated `spec.revertive: true` had no test that carried it.** T042 named T027's and T053's
  render assertions, traceability named T054, the plan said "a render assertion" — and none of
  those tasks mentioned the field. It is a `Config.spec` field, not part of the rendered device
  payload, so no render golden can hold it. The assertion now lives in **T028** (`Fabric`,
  priority 10) and **T054** (`Network`, priority 20): present and `true` on every generated
  `Config`, never absent. T040 and T059 say they state it, T042, the plan's "Drift policy"
  verification row and traceability's FR-015(e) row name those two tasks, and that row no longer
  says `make sdc-onboard` "refuses an onboarding set that does not state it" — the pre-`AD-34`
  check, inverted. T036 appears there only as the **negative** assertion it now is.
- **FR-108 said every injected fault is "removed by the tool that wrote it", and the drift check
  cannot be.** A fault on a path the platform manages is drift, and the platform restores it under
  FR-015 — that restoration is the thing SC-007 measures. FR-108 gains the exception by class: for
  such a fault the injecting tool removes nothing and reads the restoration back before the run
  continues. Quickstart §21 says the same. After `AD-43` SC-004's control is not such a fault;
  SC-007's drift probe still is.
- **G13's gate-owned scratch `Config` fitted neither FR-108 nor FR-013.** FR-108 described a host
  management session under the lab operator's device credentials; a `Config` reaches the device
  through the device-configuration layer under that layer's own, and FR-013 lets no change reach a
  device except by a controller reconciling a first-party object. FR-108's definition of scratch
  configuration now includes the gate-owned scratch configuration resource — labelled, at a
  priority no platform resource uses, on a path no fabric or service renders, removed by the gate
  with the removal read back **both** as the cluster object gone and as its content gone from the
  running datastore — and names it as the one exception to FR-013, for gate tooling only; FR-013
  points at it; the leftover rule covers the cluster as well as the nodes. The plan's G13 row, the
  quickstart's and T043 use one phrase for it: "a path a gate-owned scratch `Config` owns". Plan
  P0's "installs two items need" is three, G13 among them.
- **The `EvpnRoutesLost` guard still fired in a state FR-100 calls healthy.** `AD-31` guarded it on
  "at least one `bgp-evpn bgp-instance` on that source"; an EVPN instance that sits on a single leaf
  has no remote route to receive, so zero is correct there too and the alert fired. The guard is
  now **one EVI present on at least two leaves** — quickstart §21, T130, R-46 in the plan and in
  traceability. Whether received-route counters also count routes of an EVI the leaf does not
  carry is not assumed either way; the same-EVI condition holds whichever it is.
- **The series names the guard depends on had no recorded carrier.** Plan G7 said the gate
  qualifies "the generated metric names the guard depends on" and T043's G7 recorded nothing.
  T043's G7 now writes the observed series names to `tests/gate/observed/telemetry-series.json`,
  and T130 reads them from that file, never from a guess; the plan's and the quickstart's G7 rows
  cite it. *Amended by AD-55*: how G7 observes them is now stated — the pipeline is not installed
  when the gate runs, so a throwaway pair of the pinned gNMIc and collector images is, the
  naming-relevant settings are recorded beside the names, T129 ships them and T134 re-checks.
- **Stale text.** Open item 4 attributed the config-only-leaf read-back to G8; it is **G4**'s, as
  the plan, the quickstart and T043 say. Quickstart §4 said the `Fabric` is Ready "on (a) and (c)";
  it is (a), (a2) and (c) — the loopback reads are a readiness input since `AD-31`. G13's unknown
  had no entry under "Open items carried to P0", where every other gate-decided unknown has one: it
  is **Open item 18**, carrying R-48, and T043 cites Open items 1–9 and 18.

- **Consequences**: spec FR-013, FR-108; plan P0 (the gate's ordering paragraph, G7, G13), the
  "Drift policy" verification row, R-46; tasks T028, T040, T042, T043, T054, T059, T130;
  traceability FR-015(e), R-46; quickstart §1 (the gate table and its FR-108 paragraph), §4, §21;
  research Open items 4 and 18, `AD-31`. No new requirement, criterion, task, risk or gate item.

### AD-49: Fifth-pass closures — the clarify-delta requirements' uncovered clauses

The operator review (`AD-37`…`AD-39`) promoted rules from contracts into FR-102…FR-108 and FR-054,
FR-013, and added SC-047…SC-050 on the statement that each was "measured by tasks that already
exist". The fifth pass checked that statement clause by clause and found it true of the criteria's
headline and false of nine clauses beneath them: a MUST written into a requirement on 2026-09-20
with no task that builds it or no test that asserts it. None needed a design decision — the one
that did is `AD-40`. Nothing was renumbered and **no `FR`, `NFR`, `SC`, `R`, `G` or `T` identifier
was added**: every closure extends an existing task.

- **Decision**: each uncovered clause gets a builder and an asserter, named, in the task that
  already owned its neighbour.
  - **FR-107 — the pass that cannot run, the floor, the unparseable interval.** The cannot-run
    outcome (now `Ready=Unknown`, `AD-40`) is asserted with a fake clock and an unreachable fake
    target in T028 and T054, built in T040 and T059, admitted by T023's condition helper, and run
    live by T167 as a management-network cut. The 30 s floor and the unparseable value refuse the
    start in T042, asserted by `cmd/srl-provider/reverifyinterval_test.go`. The schedule's scope —
    never-Ready out, deleting in — is asserted in T054. FR-107 joins
    [traceability.md](./traceability.md) §Obligations index, clauses (a)…(i); the index's one open
    carrier is stated there rather than invented: no test counts management sessions per client,
    and "no third client" rests on the provider holding no device credential.
  - **One name for the stalled-schedule metric.** `AD-39` and `data-model.md` §21 named
    `reconcile_last_verification_age_seconds`; T130, T133 and `contracts/reconciliation.md` had
    already built `reverify_last_success_timestamp_seconds{kind,namespace,name}`. The timestamp is
    kept — an age series goes stale the moment the provider stops being scraped, which is when it
    matters, while `time() - <timestamp>` does not — and it is stated once, in §21. The alert keeps
    its name, `ReverificationStalled`, now carried by T130 and fired and cleared by T134's
    `alerts_fire.sh`.
  - **FR-108 — the tool that dies mid-write.** "Named or labelled so that a later run can find it"
    and "MUST refuse to start" had no carrier anywhere outside `spec.md`. T043 owns the convention
    and the scan, `tests/lib/leftovers.sh`: the reserved `vt-scratch-` name prefix for scratch
    device objects (which no golden may contain), the gate-owned label for the scratch `Config`
    (`AD-48` owns that resource's definition), `declared-faults.json` written before a fault is
    made, `leftovers::scan` refusing the start naming node and leftover, and an explicit
    `leftovers::remove` that is never run implicitly. T051, T064, T167 and T151 call it;
    `tests/unit/gate/leftover_scan_test.sh` plants one leftover of each kind.
    *Amended by AD-57*: T134's `alerts_fire.sh` makes the same two fault classes and was missing
    from that list of callers; it follows the convention as T167 does.
  - **FR-106 — the running agent, and SC-048's provisioning half.** The endpoint is resolved from
    the read-only mounted Secret on every model call (T080), so an agent whose Secret loses its
    base URL stops calling the model and never reaches the library default; T168 asserts it with a
    fake transport. T072 redacts the endpoint on every provisioning line and T168's shell half
    gains the embedded-userinfo fixture, so SC-048's "every provisioning line and start-up line"
    is measured on both.
  - **SC-047 and FR-104.** The failing-G11 run had a builder and no runner:
    `tests/unit/lifecycle/g11_stop_test.sh` (T044) makes the fake authority fail in both forms and
    asserts the stop, the name and zero installs above it. FR-104's no-bound-claim precondition
    and its return path are in `contracts/kuid-claim-profiles.md` §7 and `data-model.md` §23, built
    in T048 (the stop before either authority is touched) and checked by T009's return-entry
    fixture. A return entry records a date and a reason and **not** passing-gate evidence: the
    upstream authority cannot pass G11 before it is installed, so the returned authority simply
    faces G11 like any other.
  - **FR-054 and FR-013.** T079 asserts that `STATUS_UNKNOWN` is never a success — not to the
    watch, not to the success rate, not to the operator — and FR-054 gains the FR-092 clause `AD-37`
    said it had and only `data-model.md` §17 carried. FR-013's ban on a second workflow, pipeline
    or job engine gets a carrier in two halves: static in `make verify-boundaries` (T025 — no
    `CronJob`, no engine kind, chart or image, and the provider's ServiceAccount the only
    first-party identity with a mutating verb on `config.sdcio.dev`), runtime in T152's inventory.
  - **FR-103, FR-102, SC-043, `OwnershipConflict`.** T055 and T060 gain the two FR-103 clauses no
    test enumerated — the annotation ignored on an object not both deleting and blocked, and the
    device's removal from the `Fabric` releasing nothing; T077 and T085 the thread continued under
    a different credential. SC-043's empty-reason half reaches plan.md's row, T149 and
    traceability. `data-model.md` §18's definition of `OwnershipConflict` gains its third, and only
    non-terminal, use: the render refused while a force-release finding is open.
  - **Stale ranges and the port list.** `SC-001…SC-046` becomes `SC-001…SC-050` in the task list's
    Tests paragraph and in T151, whose acceptance run would otherwise have excluded the four
    criteria quickstart §24 says it proves. T066 no longer retypes the denied-port list it says is
    never retyped; quickstart §15 keeps its runnable loop, and
    `tests/unit/boundary/port_list_test.sh` (T066) fails when that copy or the probe suite's set
    differs from the contract — the smaller honest change than making an operator's shell loop
    parse a contract.
  - **T175 is recorded.** The operator review added task T175 — the control-plane / tier partition
    of the success criteria, `tests/e2e/sc_partition.yaml`, without which SC-025's "100% of
    control-plane acceptance gates" has no denominator — and no decision recorded it. It is
    recorded here, and plan.md's SC-025 row now states the partition.
- **Rationale**: every one of these was found the same way — by reading the requirement's sentence
  and searching `tasks.md` for the words. A specification whose evidence discipline exists because
  the predecessor declared criteria passed by proofs nobody could reproduce cannot add four
  criteria and say "measured by tasks that already exist" without the tasks saying so.
- **Alternatives rejected**: *new tasks for the uncovered clauses* — each clause sits inside
  behaviour an existing task already builds or tests, and a separate task would have split one
  test file across two owners. *A machine-readable port list both the suite and the quickstart
  read* — a new artifact and a new single source, where the contract is already the declared one;
  a diffing test gives the same guarantee. *Counting management sessions per client to assert
  FR-107's "no third client"* — nothing in the pinned image is known to attribute a session to a
  client, and an assertion that cannot be observed is worse than a stated structural argument.
- **Consequences**: FR-054 and the §Requirements pointer to the obligations index in `spec.md`
  (FR-107's own text is `AD-40`'s); `data-model.md` §18, §21, §23; `contracts/reconciliation.md`
  Rule 5 and its test row, `contracts/kubernetes-objects.md` (the `llm-provider` row and the
  port-list paragraph), `contracts/kuid-claim-profiles.md` §7; plan.md's make-target table, its
  SC-025, SC-043, SC-047 rows and its verification-strategy rows for re-verification, the
  verification-tooling boundary and the model-provider Secret; quickstart §4, §15, §21, §27a;
  traceability's FR-013, FR-104, FR-106, FR-107, FR-108, SC-043, SC-044 rows and §Obligations
  index; tasks T009, T023, T025, T028, T040, T042, T043, T044, T048, T051, T054, T055, T059, T060,
  T064, T066, T072, T077, T079, T080, T085, T092, T130, T133, T134, T149, T151, T152, T167, T168 —
  amended in place, none added. `AD-39`'s CHK030 bullet carries an amendment note for the metric
  name.

### AD-50: Fifth-pass closures — the task list's structure, and the constitution's carriers in the specification

**Task-list structure.** The fifth pass read `tasks.md` against its own rules and against plan.md.
Nothing below is a design decision: no `FR`, `NFR`, `SC`, `R`, `G` or `T` identifier was added, none
was renumbered, and T164 is still the last task. Four tasks lost their `[P]` marker, so the list now
carries 84.

- **The refused fixture left the directory that is applied whole.** `vlan-unclaimed-band.yaml` is
  built never to be accepted, and it sat in `examples/constructs/`, which the US2 Independent Test and
  quickstart §8 apply as a directory before `make wait-services`. It is now
  `examples/constructs/negative/vlan-unclaimed-band.yaml`: `kubectl apply -f` on the parent does not
  descend without `-R`, which no documented command passes, so neither the wholesale apply nor
  `make verify-services` ever sees it. T062 said T172 used it and T172 did not; T172 and plan's
  SC-045 row now run it, because SC-045 measures that refusal and nothing else did. T017's "every
  shipped example accepted" excludes `negative/` and asserts the fixture separately — structurally
  valid, admitted by the API server, refused at the provider's claim gate. T062's citation of
  quickstart §26 for it was wrong; the block is in §8. The README that describes the examples moved
  beside them, `examples/constructs/README.md`, and `examples/services/` — which held nothing else —
  left the tree.
- **`[P]` means what line 30 says it means.** T015 and T016 both wrote
  `tests/unit/api/conditional_kinds_test.go`; T003 and T005 both wrote `agents/pyproject.toml`, and
  T005's ESLint file sits in the tree T004 creates; T035 and T036, and T010 and T012, each wired a
  target into the one root `Makefile` T006 creates. T016, T005, T036 and T012 are no longer `[P]` and
  each says what it follows. The Parallel Opportunities lists and the US1 example were corrected to
  match; `Makefile` and `scripts/lib/intent_tier.sh` joined the serial-files list, and the sentence
  that staffs US10 and US12 in parallel now excepts T126 and T137, which share that script. Phase 15
  listed T146 and T147 both as parallel with T143 and inside the serial run set, and T147 reads what
  T144 and T145 produce: `[P]` there covers writing the file, and every run is serial.
- **A file is created by the first task whose test needs it.** T077 (US7) and T094 (US4) assert
  `intent_auth_refusals_total` and `intent_out_of_band_changes_total{change}` test-first, while
  `agents/common/metrics.py` was T135's, in US12. T080 now creates the file with those two counters
  and T135 extends it — the wording T042 and T133 already used for `logging.go`. *Amended by
  `AD-66`: the two counters carry the tier's literal prefix —
  `agentic_netops_agent_auth_refusals_total` and
  `agentic_netops_agent_out_of_band_changes_total{change}`.* The same on the Go
  side: T059 creates `internal/telemetry/metrics.go` with the reconcile series it increments, and
  T133 extends it and adds tracing. T168's Python half tests `agents/common/llm.py`, which T080
  creates a phase later: US6 closes on the shell half, and the Python half passes with T080.
- **The Go toolchain is chosen once.** T002 read it from a lock file that T008 had not yet written,
  and T008 listed it as a pin to record. T002 selects it from the pinned Kubernetes and
  controller-runtime matrix and writes it in `go.mod`; T008 records what `go.mod` states;
  `make verify-pins` (T010, with a T009 fixture) fails when the two differ.
- **`monitoring` is created by the first thing that writes into it.** T037 writes `grafana-admin`
  and the collector's copy of the device credentials into `monitoring` at `TargetsReady`, in US1; no
  task created the namespace, and the stack that lives there is built in US11. T037 creates it,
  idempotently, with the ownership label. Quickstart §1 listed observability inside `AppsReady`
  while T048 did not and T134 adds `ObservabilityReady`; the order is stated once, in quickstart §1's
  table — `AppsReady` ends at the provider, `ObservabilityReady` installs the stack after the fabric
  has converged — and T048, T134 and `contracts/kubernetes-objects.md` cite it.
- **Every offline shell suite is run by something.** `AD-28` gave every offline suite a target and a
  CI job, and T025 then defined `test-static` as Go tests and the register guard, so the eleven shell
  suites under `tests/unit/` — SC-048's only measurement among them — were run by nothing. No new
  target: `make test-static` runs `tests/unit/**/*_test.sh` through `scripts/ci/test_shell.sh`, and
  `tests/unit/ci/shell_reach_test.sh` fails naming a `*_test.sh` outside the live directories that
  the run did not execute, as the envtest reach test does. `AD-28`'s claim that the four targets are
  every suite that needs no lab is now true as written, so it carries no amendment.
- **Smaller corrections.** `config/manager` left plan.md's tree and T001 — the provider's Deployment
  is `deploy/agentic-netops/` (T042) and nothing populated it. T004 generates `ui/package-lock.json`,
  which T007's `npm ci` needs and T008 pins by hash. Phases 8 and 9 gained the plan-phase line the
  header promises for every phase. The US6 dependency sentence said the admission probe waits on
  "US2's `Network` CRD"; T013/T014 define it and T042 installs it, in US1. Plan P6 claimed "a request
  runs through to a confirmed resource assignment" while T084 ships worker shells and US7's checkpoint
  says the tier cannot yet provision; the claim moved to P7, where the stage logic lands.
- **Consequences**: tasks T001, T002, T004, T005, T008, T009, T010, T012, T016, T017, T025, T036,
  T037, T048, T059, T062, T072, T080, T133, T134, T135, T146, T147, T168, T172, the Phase 8 and
  Phase 9 headers, §Dependencies & Execution Order, §Parallel Opportunities and the US1 example;
  plan §Technical Context, §Project structure, the make-target table, P6, P7, the SC-045 and
  "Offline suites" rows; quickstart Gate 0, §1, §8; `contracts/kubernetes-objects.md` (the namespace
  table). The store's move is `AD-45`.

**The constitution's carriers in the specification.** The fifth pass walked the constitution MUST
by MUST against `spec.md` and found the plan and the tasks carrying obligations the specification
itself did not state. Nothing below changes a design; each closure moves a rule to the document
that is supposed to own it, and names where it was living.

- **Decision**:
  - **C2 — "never a service type the operator did not ask for" gets a carrier.** Principle II's
    clause had no `CR` row and no requirement; the plan cited FR-026 and FR-033, which state other
    things (naming, and a variable on the wrong construct). **CR-002** now states the clause with its
    carriers — FR-024, FR-029, FR-032, FR-059, FR-062 — and **FR-032** gains the two MUST NOTs that
    User Story 8's scenarios 2 and 3 asserted and only `data-model.md` §8 and §10 carried: no
    unrequested address family, and no routed instance and no L3 identifier for a gateway-less
    `mac-vrf`. T115–T118 cite FR-032; the plan's Principle II row cites the real carriers.
  - **C3 — the server-side dry-run is a MUST.** The constitution's transaction names a *server-side*
    dry-run. FR-065 said "locally", CR-004 said "dry-run", and the step was normative only in
    `contracts/kubernetes-objects.md` §Submission contract and in T092. **FR-066** now requires every
    object of a submission to pass a server-side dry-run before anything is applied, any rejection
    aborting the bundle; CR-004 uses the constitution's words. The contract and T092/T100 already
    said it and are cited, not restated.
  - **C4 — the Network-policy and Known-limitation constraints get rows: `CR-009`, `CR-010`.** None
    of 9412, 9398, 9348, 9320 or 9300 appeared anywhere in `spec.md`, and no row carried the IPv6
    Type-5 obligation; the plan said the constraints were carried "by the MTU envelope above".
    **CR-009** states the envelope, the probe sizes with one byte more failing, the ban on
    throughput assertions and G6's re-observation (carriers FR-002, FR-004, FR-020, SC-005; T032,
    T043, T065). **CR-010** states that an IPv6 anycast gateway and IPv6 Type-5 origination are a
    gate item and that a missing IPv6 Type-5 route is `Ready=False` naming it (carriers FR-004,
    FR-097, FR-100; T046, T116, T117). Every number was checked against the constitution and
    `plan.md` §Technical Context before it was written; none differs anywhere. These are the two
    identifiers this pass minted, by the coordinator's exception: a constitution constraint with no
    row is what the `CR` block exists to prevent.
  - **CR-003's enumeration has a carrier.** The row required the refusal to list valid names and
    none of its carriers said so. **FR-034** now states that site-inventory validation refuses an
    unknown node or port *listing the valid names*, on the tier path and at admission alike; the row
    names T056, T091 and T098, which already assert it.
  - **A1 — a status query takes no confirmation.** FR-069's "each subject to the same confirmation
    requirement as creation" put two confirmations in front of a read, T100 built that, and
    quickstart §26 and `contracts/supervisor-http.md` showed a status answered directly. The
    requirement now scopes the confirmations to **removal**, which is a change; a status query is
    informational (FR-057, which now says so), answered from the live object (FR-105), still
    authenticated (FR-102) and traced (FR-090). It is **not** made a seventh audit-event kind:
    FR-078's set of six is closed (AD-30), and what a status query can *find* — an out-of-band
    change — is already one of the six.
  - **A4 — three adjectives get a measure.** *NFR-012*: the "resource envelope" is the host-resource
    preflight's threshold extended by the sum of the requests the tier's workloads declare, and
    "without displacing" is every fabric workload, all four targets and the `Fabric` still Ready
    after the tier is, with no fabric pod evicted, restarted or killed for memory — computed by
    T088's extended preflight and asserted by T089 beside T052's measured footprint. **No figure was
    added**: the per-node threshold is the one quickstart §Prerequisites already states, and the
    tier's sum is read from its manifests. *FR-087 / SC-035*: the required alert set is enumerated
    **once**, as a table in `data-model.md` §21, and cited by name — `FabricLinkDown`,
    `BGPSessionDown`, `EvpnRoutesLost`, `ReconciliationFailed`, `ReverificationStalled`,
    `DeviceTelemetryTargetDown`, `DeviceSubscriptionStalled`, `OtlpExportFailing`,
    `OtlpDataPointsRejected`, `DuplicateDeviceSeries`. Nine of the ten names already existed —
    eight in quickstart §21, and `OtlpDataPointsRejected` in the drafted rules of
    `evidence/06-telemetry-visualization.md`, where it is the name for what T130 calls "telemetry
    refused or dropped". `ReconciliationFailed` is the one name this closure chose, for the alert
    quickstart called "its own alert".
    *The two-constructs edge case* allowed two outcomes; it now states the one T101 builds — the
    tier says plainly that it handles one construct per request and provisions neither.
  - **U6 — six entities the requirements lean on are Key Entities.** The force-release finding
    (FR-103, §3a), the operator credential (FR-102, §22), the path register and the compatibility
    set (FR-017; §21, §23, §26), the evidence record (NFR-013) and the log record (NFR-014, §27).
    The path register and the run-captured evidence record have **no section of their own** in
    `data-model.md`; the entities point at where each is stated today rather than at a section
    invented for the purpose.
  - **D2 — two rules stated twice are stated once.** "A device-wide count is never evidence" is
    FR-100's; FR-042 cites it and keeps only what is specific to filters — that a stock device
    already carries some. "Re-verification adds no third client of the device management server" is
    FR-107's; FR-086 cites it.
- **Rationale**: the constitution is checked against `spec.md` first, and a MUST that lives only in
  a plan row or a task clause is one edit away from being lost — the same failure AD-01 and AD-02
  closed for the base URL and the re-verification schedule. A `CR` row whose carriers do not state
  the obligation is a row that certifies nothing.
- **Alternatives rejected**: *leave the MTU numbers out of the specification because G6 re-observes
  them* — the constitution states them as policy, and a gate item that fails to reproduce one is a
  failed gate (CR-007), not a licence for the number to float; *a new FR for the asked-for type* —
  the clause is a constraint on requirements that exist, which is what a `CR` row is for; *an audit
  event for every status query* — it widens a closed set for a read that changes nothing; *a figure
  for NFR-012* — none has been measured, and Principle I forbids writing one that was not.
- **Consequences**: `spec.md` — CR-002, CR-003, CR-004, **CR-009**, **CR-010**, FR-032, FR-034,
  FR-042, FR-057, FR-066, FR-069, FR-086, FR-087, NFR-012, SC-035, one edge case and six Key
  Entities; `plan.md` — the Principle II, III and VI rows, §Additional constraints, C-14 and the
  SC-035 check; `tasks.md` — T065, T088, T089, T100, T101, T115–T118, T130, T134 and the `[Txn]`
  legend, extended and cited, none added; `data-model.md` §21 (the alert table);
  `contracts/supervisor-http.md`; quickstart §Prerequisites and §21; `traceability.md` — rows for
  CR-009 and CR-010 and notes on CR-002, CR-003, CR-004, FR-032, FR-069, FR-087 and NFR-012. Live
  `CR` rows: ten.

### Sixth pass — 2026-09-21

The sixth cross-artifact analysis (2026-09-21) found no constitution conflict and six high findings, most of
them second-order effects of the fifth pass's decisions. `AD-51`…`AD-53` are **operator decisions**, put
to the operator before any edit; `AD-54`…`AD-59` are closures that needed no decision.

### AD-51: An `ip-vrf` attachment's VLAN is named or absent — the allocator never allocates one *(FR-062, FR-109, SC-046, AD-42 — operator decision)*

- **Decision**: on an `ip-vrf`, an attachment's VLAN is either **named by the operator** — from the
  naming band `100–999`, claiming nothing, like every other named VLAN — or **absent**, which is the
  untagged subinterface `<port>.0`. **The allocator never allocates a VLAN for an `ip-vrf`
  attachment**, on any path. The only VLANs the platform allocates are the shared VLAN of a `vlan`
  or of a `mac-vrf` whose operator named none, so a VLAN claim's role `vlan-<entry>` names a
  `vlans[]` or a `bridgeDomains[]` entry and nothing else. Three things follow and are stated where
  they apply: the adoption predicate matches a VLAN claim against `spec.vlans[].vlan` or
  `spec.bridgeDomains[].vlan`, two fields and not three; an `ip-vrf` attachment carrying a VLAN in
  `1000–4000` has no adoptable claim **by construction** and is
  `Accepted=False/AllocationConflict` naming the VLAN and both bands; and the added-attachment rule
  reads `spec` alone, `status.claimRefs` dropping out of it.
- **Rationale**: the claim profile said an `ip-vrf` claims a VLAN "per tagged attachment unless the
  operator named a VLAN", and SC-046, T173 and quickstart §26a each measured "an `ip-vrf` whose
  allocated attachment VLAN" stayed adopted. Neither half could be built. No request shape says
  *tagged but unnamed*: the interpretation's endpoint carries a node, a port and an optional VLAN,
  and `data-model.md` §10 already read an absent VLAN as the untagged subinterface, so the
  allocator had no way to tell "untagged" from "tagged, allocate one". And `AD-42` made the
  deterministic claim name one of the three things adoption takes, with the role `vlan-<entry>` —
  but an `attachments[]` entry has **no name** (`contracts/network-spec.md` §1: node, port, VLAN,
  routed instance), two tagged attachments of one `ip-vrf` share their only candidate, the `vrf`,
  and T093 asserted claim names "against the entry names the translator emits", of which an
  attachment has none. The Python allocator (T099) and the Go provider (T171) would each have had
  to invent the string, and any difference is a claim that is never adopted and an
  `AllocationConflict` on a service the tier itself submitted. The lab gives the feature nothing
  to do: all three frozen walkthrough prompts name their VLAN, and an operator who wants a tagged
  routed subinterface knows which tag the attached host uses — it is the one VLAN in the platform
  that is dictated from outside the fabric.
- **Alternatives rejected**: *a `tagged: true` request shape with a claim role
  `vlan-<node>-<port>`* — buildable, but it adds a field to the interpretation, to the normalized
  service intent and to the mapper's prompt, a sanitisation rule for a port name inside an object
  name (`ethernet-1/1` carries a `/`), and a second kind of VLAN claim keyed differently from the
  first, all for a VLAN whose value the far end must be configured with anyway: an allocated tag
  the operator learns only at the second confirmation is a tag they then have to go and set on
  the host. *Naming the claim after the `vrf`* — not unique across two attachments of one
  service. *Leaving the profile and deleting only the test clause* — the profile cell would
  promise an allocation nothing can request or adopt.
- **What it costs, stated plainly**: an operator cannot ask the platform to pick a tag for a routed
  attachment. They name one from `100–999` or they take the untagged subinterface.
- **Once-per-value adoption stands** (`AD-32` amendment (1)), as the rule that an adopted claim is
  never re-evaluated, dropped or released early. The case it was written for — an allocated VLAN
  living only on an attachment that may be removed — is gone; what remains measurable, and is
  measured, is a `mac-vrf` whose VLAN was allocated keeping its claim `adopted` after an
  attachment carrying it is removed.
- **Not assumed**: nothing about the pinned authority or the device. The untagged routed
  subinterface `<port>.0` is already in the render table (`data-model.md` §13) and under the
  one-tagging-mode-per-port rule (`AD-20`); this decision adds nothing to either.
- **Consequences**: FR-062, FR-109, SC-046, two edge cases; `contracts/kuid-claim-profiles.md` §2
  (the profile row and rule 1), §4, §5, §8; `contracts/reconciliation.md` Rule 3 and the
  contract-test row; `contracts/crd-api.md` rule table (the added-attachment row) and contract
  tests; `contracts/construct-vocabulary.md` §3; `contracts/network-spec.md` §2; both JSON schemas
  (the `vlan` description); `data-model.md` §9, §10, §11, §12, §18, §20; `plan.md` C-13, P7, R-45,
  the SC-046, "Provider-side claims" and "Immutable identifiers" rows; quickstart §26a and the
  diagnosis table; `traceability.md` SC-046, FR-109(g), FR-109(l); tasks T014, T017, T091, T093,
  T098, T099, T170, T171, T173. Amends `AD-32`, `AD-42` and `AD-47`, each by a note.

### AD-52: The validating webhook fails closed *(FR-034, FR-109, CR-003, NFR-010 — operator decision)*

> **Amended by AD-61** (seventh pass, 2026-09-21): the registration below stands, and what the
> webhook *evaluates* is narrower than what it is registered for — a `CREATE`, and an `UPDATE` that
> changes `spec` on an object with no deletion timestamp. An `UPDATE` that leaves `spec` unchanged
> and any `UPDATE` of a deleting object are admitted unread. "Nothing the webhook checks bears on a
> deletion" was true of the `DELETE` and overlooked that finalization ends in an `UPDATE`.

- **Decision**: **operator decision, 2026-09-21**, put to the operator before any edit. The
  provider's validating admission webhook **fails closed**: its `ValidatingWebhookConfiguration` is
  registered with `failurePolicy: Fail` on `CREATE` and `UPDATE` of `networks` — the one resource it
  has rules for; the `Fabric`'s validation is CEL alone — and **never on `DELETE`**. No
  `timeoutSeconds` is stated, so the API server's default applies; no artifact gave a figure and
  none is invented. While the provider, which serves the webhook, is down, no `Network` create or
  update is admitted by anyone; a removal through the tier, the deployer's rollback and a
  `kubectl delete` still go through and wait on the finalizer. Every admission rule therefore holds
  **at all times**. A dry-run the API server fails because the webhook could not be reached is
  **not a validation refusal**: the deployer retries it under the existing worker-call retry rule
  (`data-model.md` §25) and then reports NFR-010's cluster-API dependency as the cause, naming the
  admission webhook, with nothing applied, nothing to roll back, the thread resumable and the
  request's claims still provisional. No failure class, reason code, bound or identifier is minted.
- **Rationale**: the policy was stated nowhere, and the two readings build different platforms. The
  webhook is served by the provider's own binary (T061), and the submission contract makes it the
  **arbiter** of the cross-object rules — the deployer's pre-flight "scans the intent namespace only"
  and a holder in `agentic-netops-services` "is refused by the one-owner webhook at step 4". Under
  `Ignore`, every restart of the provider would admit objects that none of attachment
  resolvability, one owner, one tagging mode, binding exclusivity or qualification had seen — which
  is CR-003's "at admission alike" and constitution Principle II's up-front refusal lapsing exactly
  when nobody is watching. Meanwhile three passages presupposed the other reading: an edge case, the
  claim-profiles contract and the rationale of `AD-32` each spoke of an object "applied … while the
  provider is down", which `Fail` makes impossible. With `Fail` the finalizer-less window of
  `AD-32` narrows to what can actually happen — an object applied with cluster tooling and then
  deleted before the provider's first reconcile, the provider slow or gone down *after* the apply
  was admitted — and T173's live variant is sound as written, because it kills the provider's pod
  as the apply is *reported* and relies only on the delete, which is never intercepted.
- **Alternatives rejected**: *`failurePolicy: Ignore`, with the provider re-validating on reconcile
  and reporting `Accepted=False` after the fact* — it turns an up-front refusal into a condition on
  an object that already exists, which for the one-owner and tagging-mode rules means two services
  holding one subinterface until a controller notices, and it would need the reconciler to
  re-implement every webhook rule as a second copy. *Intercepting `DELETE` as well* — nothing the
  webhook checks bears on a deletion, and it would make removal, rollback and the tier's own purge
  depend on the provider being up. *A separate webhook Deployment that outlives the provider* — a
  second first-party workload and a second failure mode, for a lab in which a provider outage
  already stops every reconcile; availability of admission without the reconciler buys nothing.
- **Consequences**: FR-034 (admission fails closed; the refusal is a dependency failure), FR-109 and
  one edge case (the window reworded); `contracts/crd-api.md` §"Required `Fabric` and `Network`
  API" (the policy table) and §"API contract tests" (the fail-closed test);
  `contracts/kubernetes-objects.md` §"Submission contract" step 4; `contracts/reconciliation.md`
  Rule 8 step 0; `contracts/kuid-claim-profiles.md` §3; `data-model.md` §3; `plan.md` C-05, P7, the
  API layer row and the SC-046 row; quickstart §26a and a row in §"Diagnosing a failure";
  `traceability.md` — rows FR-034, FR-109 and CR-003; tasks T061 (states it), T056 (asserts it,
  envtest with the endpoint unreachable), T092 and T100 (the deployer's failure class), T146 (the
  live degradation form) and T173 (its wording). `AD-32` and `AD-44` carry an amendment note. No
  requirement, task, risk or gate item added.

### AD-53: An object being deleted reports `Ready=False/Deleting` at once *(FR-103, FR-107, AD-40 — operator decision)*

- **Decision**: **operator decision, 2026-09-21.** An object that is being deleted reports
  **`Ready=False` with the reason `Deleting`, at once** — from the moment finalization starts
  (`contracts/reconciliation.md` Rule 8 step 1), in every deletion, whatever the reachability of its
  targets, and until the object is gone — beside the existing `Deleting=True/<reason>` condition,
  which keeps saying what is outstanding. The service is no longer offered, so **nothing is read
  back to decide it**. The re-verification schedule keeps a deleting object only to drive the
  finalizer's requeue — FR-107's "stays inside it" — and never sets `Ready=Unknown` on it;
  `VerificationFailed` is never set on a deleting object, and the unreachable target is named by
  `Deleting=True/TargetUnreachable` as before. `Deleting` joins `Ready`'s False-reason set in
  `data-model.md` §18: it is the one vocabulary addition of the sixth pass, and it is a reason on
  `Ready`, not a second condition. The tier reads the reason and not the bare `False`: a status
  answer built from such an object says the service is being removed, never that it failed.
- **Rationale**: the sixth pass asked what `AD-40` means for an object held in deletion with a
  target away, and found that no artifact said what `Ready` is on a deleting object at all. FR-107
  put it "inside" the schedule, Rule 8 step 5 requeued it at the re-verification interval, and
  `data-model.md` §18, §19, quickstart §27, T055, T060 and T149 agreed with each other only by
  saying nothing. The implementation that silence invites is a finalizer path that returns early
  on a deletion timestamp and never touches `Ready` — leaving `Ready=True` standing, for a time
  FR-103 deliberately leaves unbounded, on a service whose configuration has already been removed
  from every reachable leaf. That is the standing `Ready=True` `AD-40` was made to end, and
  constitution Principle I forbids it for the same reason. The deletion itself is the evidence: the
  platform does not need to read a device to know that a service it is removing is not being
  offered, so the truthful value is known at step 1 and needs neither a read nor a wait.
- **Alternatives rejected**: *follow `AD-40`* — `Ready=False` when the removal is read back,
  `Ready=Unknown/VerificationFailed` while a target cannot be read. It makes the readiness of a
  service that is being removed depend on the reachability of a device, reports "unknown" about a
  thing the platform itself decided, puts `VerificationFailed` and `TargetUnreachable` on one object
  to say the same outage twice, and would have the schedule run a read-back whose expected result —
  the service's objects present — is the opposite of what finalization is working towards.
  *`Ready=False` with an existing reason* (`NotConverged`) — no vocabulary change, and it tells the
  operator, the tier and any automation keyed on reason codes that a removal in progress is a
  convergence failure; `data-model.md` §18 says automation keys on the reason, so the reason has to
  be true. *Removing the `Ready` condition from a deleting object* — an absent condition is read as
  "not yet reconciled" by every client that waits for one, and it would make `Ready` disappear at
  exactly the moment an operator looks at the object to see why it is still there.
- **Consequences**: FR-103 (the rule, for every deletion) and FR-107 (the deleting object's place
  in the schedule is a requeue, never a read-back) and the deletion edge case; `data-model.md` §17
  (the tier's status answer), §18 (the `Ready` row, the definition of the reason, the closing
  paragraph), §19 (the bullet and the deletion diagram), §21 (the object's re-verification series
  ends when finalization starts — `AD-54`); `contracts/crd-api.md` §Status contract;
  `contracts/reconciliation.md` Rule 5, Rule 8 step 1 and the two deletion test rows; plan.md's
  Principle I row and SC-043 row; quickstart §27 and the failure table; traceability's FR-103 row
  and FR-107(c); T023 (the setter and its refusal test), T055, T060, T064 (`delete_unreachable.sh`,
  which T149 runs), T092. No identifier was added; the one new name is the reason code.

### AD-54: Sixth-pass closures — re-verification and readiness

The sixth pass re-read the fifth pass's re-verification and readiness work (`AD-40`, `AD-49`) against
every artifact that states it. One finding needed a decision and is `AD-53`. The six below needed
none: each is a place where two current statements could not both hold, or where a MUST had a
builder and no asserter, or the reverse. **No `FR`, `NFR`, `SC`, `R`, `G` or `T` identifier was
added**; every closure extends an existing requirement or task.

- **Decision**: each is closed where the rule is stated, and in every artifact that repeats it.
  - **`lastVerifiedTime` advances on every pass that ran.** `contracts/reconciliation.md` Rule 5,
    traceability's FR-107(g) and T023 said the field and the metric advance only on a pass that
    "ran and passed" / "succeeded"; SC-044, plan.md's SC-044 row, `data-model.md` §3a, quickstart
    §27a and T167 said they advance on every interval, through the `Ready=False` window included.
    The second reading is the rule: a pass that **ran** — completed its read-back on both sides,
    whatever it found — advances both, and only a pass that could not run freezes them. A helper
    built to the first reading fails T167, and would make `ReverificationStalled` — which fires
    whatever `Ready` says — fire on a healthy schedule that is truthfully reporting
    `RoutesMissing`. The metric keeps its name, `reverify_last_success_timestamp_seconds`, because
    it is the one `AD-49` settled and the tasks build; `data-model.md` §21 states once that
    "success" there means the pass completed, not that it passed, and FR-107 says the same of
    "successful".
  - **The per-object series ends with the object's place in the read-back schedule.** Nothing said
    the `{kind,namespace,name}` series is ever removed, and a gauge that is never deleted ages
    into `ReverificationStalled` one bound after every service deletion and never clears. The
    provider removes the series when finalization starts — from then on nothing is re-verified
    (`AD-53`) — so it is absent for a deleting and for a deleted object (`data-model.md` §21, T133
    with a unit test).
  - **One `Degraded` condition, one reason: an order on the `Fabric`.** A force-release is honoured
    only while a target is unreachable, which is exactly when `AD-40` has the `Fabric` at
    `Ready=Unknown` with `Degraded=True/VerificationFailed`; FR-103's open finding asks the same
    condition for `StaleConfigurationPossible`, and T055 and T028 each asserted one of them. While a
    required target cannot be read the reason is `VerificationFailed` and the finding is visible
    in `status.findings[]`; `StaleConfigurationPossible` is the reason from the first pass that runs
    with a finding still open, beside the `Ready=True` that pass returns. FR-103's "degraded, not
    not-Ready" holds throughout — `Degraded` is True on both sides of the change and `Ready` is
    never False for it. T055 asserts the finding during the outage and the reason after the return;
    T040 builds the order.
  - **The between-passes rule on the `Network` side.** `AD-40`'s extension — a reconcile that sees a
    required target of a Ready object not Ready is a read-back that cannot run, which is what
    keeps SC-008's two-interval bound — was carried by T040 and T028 for the `Fabric` and by
    neither T059 nor T054 for the `Network`, although T054 is the task tagged SC-008; and T064
    named `target_failure.sh` without saying what it asserts. T059 and T054 gain the clauses, and
    `target_failure.sh` asserts `Ready=Unknown/VerificationFailed` naming the target within SC-008's
    30 s — not True, not False — with a never-Ready service staying `Ready=False`.
  - **FR-092's per-stage counter exists before the test that asserts it.** `AD-49` gave T079 (US7)
    the assertion that `STATUS_UNKNOWN` is never counted as converged in FR-092's per-stage success
    rate, and T085 must make T079 pass; but `AD-50` had T080 create only the two counters asserted
    before US12 and left the rest to T135. T080 now creates a third series — the per-stage
    request-outcome counter, its labels the stage and a closed outcome set — T085 increments it,
    and T135 extends the file and redefines none of the three. The counter's name is T080's to
    fix; no name is invented here.
  - **`llm-provider` is mounted, in the task that authors the Deployments.** FR-106's running-agent
    rule rests on the endpoint being read from the mounted Secret on every model call (T080,
    `contracts/kubernetes-objects.md`), and T087 — the only task that writes the agents' manifests
    — listed its read-only mounts exhaustively without it, while T025's credential check admits
    `secretKeyRef`. An environment variable is fixed at start-up, so that manifest would have made
    the rule unobservable while T168's fake-mount test still passed. T087 mounts it read-only in
    all four agent Deployments and never references it through `secretKeyRef` or `envFrom`;
    T168's Python half gains a manifest assertion that passes with T087.
- **Rationale**: the fifth pass wrote a new state (`Ready=Unknown`), a new metric name and nine
  coverage closures into some thirty tasks in one concurrent edit. Each of these is what that kind
  of edit leaves behind: the rule stated correctly in the requirement and one reading behind in a
  contract row, a test added in one story against a thing built in a later one, a second reason
  for a condition that holds one.
- **Alternatives rejected**: *renaming the metric to drop "success"* — it would be the third name
  in three passes for a series no run has yet produced, and every artifact `AD-49` aligned would
  move again; a stated meaning costs one sentence. *Advancing only on a pass that passed, and
  amending SC-044* — the alert would then need `Ready` in its expression to stay quiet during a
  truthfully reported fault, which couples the stalled-schedule guard to the state it guards.
  *A second condition type for the open finding* — a vocabulary change to avoid an ordering that
  one sentence states, and FR-103 says `Degraded`. *Moving T079's FR-092 assertion to a US12 test*
  — it would leave FR-054's success-rate clause unasserted until the last story, and `AD-50`'s own
  pattern for a counter asserted early is to create it in T080. *Keeping the series for a deleting
  object* — it has no read-back to time, so its age would measure the outage and not the schedule.
- **Consequences**: FR-107 (the meaning of "successful", and its provenance note);
  `data-model.md` §3a (the field's comment, the read-back paragraph, the findings rules), §18 (the
  order of the two reasons), §21 (the metric's meaning and the series' lifetime);
  `contracts/crd-api.md` §Status contract (`lastVerifiedTime`; the open-finding bullet);
  `contracts/reconciliation.md` Rule 5 and the Force-release test row; plan.md's
  scheduled-re-verification paragraph and row, its SC-043 row and its model-provider-Secret row;
  quickstart §8, §27, §27a and the failure table; traceability's FR-107(g); tasks T023, T028, T040,
  T054, T055, T059, T064, T080, T085, T087, T133, T135, T168 — amended in place, none added.

### AD-55: Sixth-pass closures — the fabric dependency, the gate's series names and the tier's removal

- **Decision**: six closures in the slice of `AD-43`, `AD-45`, `AD-46` and `AD-48`, none needing the
  operator and none changing a decision. No `FR`, `NFR`, `SC`, `R`, `G` or `T` identifier is added
  or renumbered. (1) **A `Network` waits on a `Fabric` that exists and is Accepted — never on one
  that is Ready.** `data-model.md` §19 said so from `AD-43` on; Rule 3 item 2 of
  `contracts/reconciliation.md` still read "the `Fabric` is Accepted and Ready", the resource table
  of `data-model.md` §3 still read "`Ready` before any `Network` renders", and the §19 diagram still
  labelled its edge "dependencies Ready". All three now say what §19 says — the diagram's edge is
  "dependencies met" — T059 states the rule in its dependency waits, plan C-05 carries it, and T054
  gains the envtest case: under a `Fabric` that is Accepted and `Ready=False/NotConverged` a new
  `Network` still renders and a Ready one is still re-verified and still reports `RoutesMissing`,
  with an absent or un-Accepted `Fabric` as the negative control. (2) **G7 observes the series names
  through a throwaway pair, as T166 observes the OTLP shape.** `AD-48` gave the names a carrier and
  left unsaid how a gate that runs before `FabricReady` reads the output of a pipeline that
  `ObservabilityReady` installs after it (`AD-50`) and whose manifests are US11's. `g07` starts a
  throwaway Pod pair of the **pinned** gNMIc and collector images in a scratch namespace, under the
  lab operator's device credentials as every other device client of the gate is (FR-108), while
  G8's scratch EVPN instances exist; the file records the series names **and the naming-relevant
  settings they were observed under**; T129 ships exactly those settings; T134 re-checks the live
  names and the shipped settings against the file before it loads T130's rules; the pair and its
  namespace are removed and the removal read back. (3) **`username_unchanged` is read where it
  exists.** It is a field of the usernames record, which the export step writes on a down path;
  T148, quickstart §25 and the plan's SC-042 row read it while the tier was up, when no such record
  exists. With the tier up the authentication audit derives the distinct username set and its
  cardinality from the tier-phase captures; the field is read by T152's file-source run, the first
  point at which the record exists. `AD-46`'s rejection of writing the record in T148 stands.
  (4) **The collector's contract row says when each exporter arrives** — one, the store, from User
  Story 7; the second with User Story 12 — where it said "two exporters out" unqualified and T087,
  built "per" that contract, said one. (5) **T155 closes Open items 1–18**, item 18 being the one
  `AD-48` added. (6) **A verified export is identified by more than a count.** The third condition
  of `data-model.md` §16 compared the store's row count now with the count recorded at export, and
  the lookup is by cluster and lab identity under an evidence root that outlives a teardown, so a
  lab re-created under the same names — the acceptance run's three cycles are that — whose fresh
  store happened to hold as many rows would have had its export skipped and its store destroyed.
  The export's record now also carries the newest stored row's timestamp, and the third condition
  requires the store to report that same count **and** that same timestamp now; T088 records it and
  T174 asserts the same-count, different-timestamp case adds an artefact.
- **Rationale**: (1) is the one that could have cost a criterion. The usual shape of a dependency
  gate is a check at the top of the reconcile that returns a wait, and built from Rule 3 as it read
  it would have suspended re-verification for exactly as long as `interASVPN: false` or a
  `maintenance[]` entry held the `Fabric` at `NotConverged` — so `RoutesMissing` would never have
  appeared, and SC-004's negative control and SC-044 would both have been unrecordable, the defect
  `AD-43` was written to remove. (2) is an ordering an implementer of T043 could not have met: no
  pipeline exists in US1, and a name derived by reading the collector's documentation is the guess
  `AD-48` forbids. Recording the settings beside the names is what makes the observation
  transferable — collector-side naming depends on exporter options, so names observed under one
  configuration say nothing about another — and T134's re-check is what catches a drift between
  the two. (3), (4) and (5) are propagation. (6) needs no invented number: both values are read
  from the store itself.
- **Alternatives rejected**: *keep Rule 3's "Accepted and Ready" and scope it to "changed device
  intent" only* — it leaves a new `Network` held under a `Fabric` that a maintenance entry has made
  not-Ready, which §19 already refuses, and leaves the implementer to infer that re-verification is
  outside the gate. *Move the series-name capture into T134 or T130's first run* — it removes the
  gate's observation from the gate record, lets the rules be authored before anything was
  observed, and `AD-48` put the carrier in G7. *Run the throwaway pair as containers on the
  operator's host instead of Pods* — the collector's pinned image and its configuration are
  exercised in-cluster everywhere else, and T166 already set the pattern; the pair is started by
  `run_gate.sh`, holds the lab operator's credentials for its lifetime only and is never left
  running. *Have the tier phase write the usernames record too, so T148 can read the field* —
  `AD-46` binds the record to the moment before the credential goes, and a second writer of it
  would have to be reconciled with the first. *A store-instance UID for (6)* — the store has none
  that the platform did not have to invent and persist.
- **Not assumed**: which options of the pinned gNMIc `otlp` output and of the pinned collector's
  Prometheus exporter bear on a series name is not asserted here; G7 records the options it ran
  with and the names it saw, and T134 compares.
- **Consequences**: `contracts/reconciliation.md` Rule 3 item 2; `data-model.md` §3 (the `Fabric`
  row), §16 (the *verified* test, "who reads what"), §19 (the diagram's edge and the dependency
  bullet); `contracts/kubernetes-objects.md` (the `agent-otel-collector` row); plan C-05, the G7
  row, the SC-042 row; quickstart §1 (the G7 row), §25; tasks T043, T054, T059, T088, T103, T129,
  T130, T134, T148, T152, T155, T174; `traceability.md` FR-078(h), FR-107(a); research `AD-48`.
  FR-108's words "from the operator's host" are read as covering a Pod the gate starts from that
  host and removes; whether the requirement should say so is left to the coordinator.

### AD-56: Sixth-pass closures — claims and the VLAN bands

- **Decision**: eight closures in the claims and VLAN-band slice, none needing a design decision.
  (1) **An allocation-authority error is not an answer.** A lookup, a create or a delete that
  *errors* — the authority unreachable, the aggregated API unhealthy, a timeout — is never read as
  "nothing adoptable" and never reported as `AllocationConflict`. Before a render it is the
  dependency wait an unbound claim already is (`data-model.md` §19 `Waiting`), retried with
  bounded exponential backoff. In finalization the finalizer stays, `Deleting=True` keeps the
  **existing** reason `RemovingConfiguration` with the authority named in its message, steps 2 to
  5 of Rule 8 still run, and steps 6 and 7 never run on a list step 1 could not complete. No
  reason code is minted, no deadline is attached, and the force-release is not an exit from it —
  FR-103 honours that only on `TargetUnreachable`. (2) **The JSON schemas bound a VLAN
  structurally, `1–4094`**, as the CRD does, and say that the band rules are the mapper's and the
  translator's: with `maximum: 4000` a named VLAN of `4001–4094` failed schema validation before
  the mapper's band check could state both bands, while one of `1–99` reached it. The mapper gains
  the fixture `refuse_vlan_named_above_platform_range`. (3) **`data-model.md` §9 requires a claim
  behind every *allocated* VLAN and every VNI**, not behind every VLAN: a named VLAN and the VLAN a
  standalone `acl` references are claimed by nobody, and the old sentence would have had the
  allocator's own validator refuse all three walkthrough prompts. (4) **The standalone `acl`'s
  exemption from the added-attachment rule** — stated by `AD-47` in the contract's rule table and
  in no task — is written into FR-109, T014 and a positive T017 fixture. (5) **`status.claimRefs[]`
  has one field list**, in `contracts/crd-api.md` §Status — `name`, `namespace`, `indexKind`,
  `value`, `origin` — which T013 builds and `data-model.md` cites; the tier's own `ClaimRef`
  (`data-model.md` §11) is a different record and stays where it is. (6) **`AllocationConflict`
  means two things and §18 says both**: a VNI the authority refused, and an allocation-band VLAN
  no adoptable claim backs. (7) **G11's observations have one list and one count**: the six,
  (a)–(f), of `contracts/kuid-claim-profiles.md` §6. "Five further", "six points" and "seven" were
  three partitions of the same observations; the plan's gate table, R-44, Open item 15, quickstart
  and T044 now cite the list and do not re-count, and "a claim reporting no value is terminal"
  is part of the round trip, outside the six. The translator contract no longer says the
  *allocator* reaches the sidecar — only the deployer does, on loopback. (8) **Every claim name
  fits.** `metadata.name` and the `vlans[]`, `bridgeDomains[]` and `routers[]` entry names are
  DNS-1123 labels of at most 63 characters, so `<namespace>.<name>.<role>` is at most
  `63 + 1 + 63 + 1 + 6 + 63 = 197` of the 253 an object name allows — the six being the longest
  role prefix — and `service_id`/`serviceId` carry a DNS-1123 label `pattern` in both schemas,
  since the identifier becomes the `Network` name and part of every claim name.
- **Rationale**: (1) is the one with a wrong implementation waiting in it: a failed `ListByLabel`
  read as an empty list removes the finalizer of a never-reconciled object and orphans exactly the
  claims `AD-44` exists to release, and the same failure in Rule 3's band gate reports a healthy
  tier-submitted service as `AllocationConflict`. The rest are places where a fifth-pass decision
  reached the contract and not the task, or where two artifacts counted the same thing
  differently. None changes a decision.
- **Alternative considered for (1)**: *a dedicated `Deleting` reason for a release blocked on the
  authority.* `RemovingConfiguration` describes step 1 well and step 6 loosely — by then the
  configuration is gone and what is outstanding is the release. The reason set of `data-model.md`
  §18 is closed and this pass mints no member of it; the message names the authority, which is
  what an operator needs, and the question is left with the coordinator rather than decided here.
- **Not assumed**: nothing new about the pinned authority — how it fails is not modelled, only
  that a failure is distinguishable from its answer at the `pkg/kuid` seam, which T170 and T055
  exercise by driving the fake adapter both ways. That `metadata.name` is reachable from a CEL rule at the object
  root is the API server's documented behaviour and is exercised by T017's fixture.
- **Consequences**: FR-062, FR-109, two edge cases; `contracts/kuid-claim-profiles.md` §4, §5, §6,
  §8; `contracts/reconciliation.md` Rule 3, Rule 8 steps 1 and 6 and the contract-test row;
  `contracts/crd-api.md` rule table ("Name shape", the added-attachment row), §Status and contract
  tests; `contracts/interpretation.schema.json` and
  `contracts/normalized-service-intent.schema.json` (`vlan`, `service_id`/`serviceId`);
  `contracts/translator-api.md`; `contracts/construct-vocabulary.md` §5;
  `contracts/network-spec.md` §1; `data-model.md` §8, §9, §12, §18, §19, §20; `plan.md` C-05,
  C-12, G11, R-44, the SC-015, "Provider-side claims" and "Immutable identifiers" rows; quickstart
  §6, the gate table and the diagnosis table; `traceability.md` R-44, FR-109(f), (k), (m), (n);
  Open item 15; tasks T013, T014, T017, T044, T055, T060, T091, T098, T170, T171. Amends `AD-47`
  by a note.

### AD-57: Sixth-pass closures — the task list's ordering

The sixth pass re-read `tasks.md` after the six concurrent editors of the fifth: 175 unique ids,
none ticked, 84 `[P]` markers as `AD-50` states, no two `[P]` tasks of one phase on one file, every
`make` target declared in T006 and wired by exactly one task, no task line mangled. What it found
is ordering — four places where a task stands on something no earlier task builds or re-establishes
— and five stale sentences. Nothing below is a design decision: **no `FR`, `NFR`, `SC`, `R`, `G` or
`T` identifier was added or renumbered**, no `[P]` marker moved, and T164 is still the last task.

- **Decision**:
  - **The request span is created by the first task whose work rides on it.** `data-model.md` §7
    defines the correlation identifier as "the trace identifier of the root span" and §16 makes an
    audit event a span event on the request trace. T085 (US7) puts that identifier on every chunk,
    T099 and T100 (US4) label claims and `Network`s with it, T101 emits the audit events — and
    `agents/common/tracing.py`, "one trace per request", was T135's, in US12, while T080 gave
    `telemetry.py` only the process's one exporter. T080 now creates `tracing.py` with the root
    request span (trace id = correlation id) and the span-event helper `audit.py` and the
    deployer's events go through; T135 **extends** it with the stage, worker-call, model-call and
    convergence spans. It is the rule `AD-50` applied to `metrics.py`, applied to the file it missed.
  - **A live task says where its lab comes from.** T151 runs three deploy → test → destroy cycles
    and ends with nothing standing; T152 then asserts that tier-submitted `Network`s are "still
    present and Ready"; T152 removes the tier, T153's clean-host quickstart ends in §24's full
    teardown, and Phase 16 — "entered only from a lab that has passed Phase 15" — drives the
    operator console. T152 now runs on a lab re-provisioned `--with-intent-tier` after T151's last
    destroy, and T159 begins by re-provisioning the tier on the same pinned artefacts; the
    `operator-credentials` `username` that run captures (T088) is the one the take's three
    `Network`s are checked against, the earlier Secret having gone with T152's removal. Quickstart
    §24 and §28 and plan P11 and P12 say the same.
  - **`LabReady` is a port accept, not a gNMI call.** T034's `scripts/lib/containerlab.sh` waited
    "until every device answers gNMI on `57400`", and T025 fails any device client invoked outside
    `tests/` and `testautomation/`, FR-108 adding that no lifecycle outcome may depend on
    verification tooling. The wait is a credential-less TCP/TLS accept on `57400` from the host —
    no gNMI RPC, no credential, no device client; that the devices *answer* gNMI is what
    `TargetsReady` shows, through the device-configuration layer's own session. T025's fixtures
    gain the case this would have been: a `gnmic` line planted under `scripts/lib/` fails the check
    naming the file, the same line under `tests/` passes. FR-108 and SC-049 needed no change — "a
    device client is any invocation that opens a management session", and a port accept opens none.
  - **`alerts_fire.sh` is a fault-making suite.** `AD-49` gave FR-108's leftover rule to T043 and
    listed its callers as T051, T064, T167 and T151; T134's `alerts_fire.sh` cuts a leaf from the
    management network — T167's own fault — and impairs a host-side link, and carried neither the
    declaration nor the scan. It now starts with `leftovers::scan`, writes each fault to
    `declared-faults.json` before making it, removes it and reads the removal back. A link
    disabled through `Fabric.spec.maintenance[]` is intent, not a fault, and is patched back.
  - **Stale sentences.** plan P3 still adopted a VNI claim on "correlation label and … value";
    it states the three things of `AD-42`. T042 said T133 adds metrics, which `AD-50` had given to
    T059. `tests/lib/`, which `AD-49` introduced, joined plan's tree and T001's skeleton. The
    prose said US7 depends on US6 while the graph beside it joins US2 into US7; the prose now
    names US2 — the finalizer the tier's removal waits on. T025 enumerated the shell suites
    `test-static` runs and the enumeration was already three suites short of the fifth pass's own
    additions; it describes the glob and leaves the proof to the reach test. T088 lost an
    unmatched `)`.
- **Rationale**: each of the four is a point at which an implementer following the list in order
  either invents something a later task then claims to create (the span), finds no lab (T152,
  T159), writes the natural implementation and fails the project's own CI check (T034), or leaves
  a fault class outside the one convention that finds a tool that died (T134).
- **Alternatives rejected**: *move `tracing.py` whole into T080* — the child spans instrument
  stages that US4 builds, so they stay T135's. *Reorder T152 before T151, or drop the destroy of
  T151's third cycle* — SC-005's reproducibility clause is three **clean** cycles, and the
  removability proof needs services T151's cycles do not leave behind either way. *Keep the tier
  through T152 and record the walkthrough first* — P12 is last by instruction (CD-06), and the
  README describes a platform that has passed P11. *Exempt `scripts/lib/containerlab.sh` from the
  boundary check* — it would make a lifecycle outcome depend on a device client, which FR-108
  forbids; `TargetsReady` already proves what the gNMI call would have. *A new task for the
  re-provisioning* — it is one idempotent command, and it belongs to the task that needs the lab.
- **Not assumed**: which tool makes the port accept on the host is the implementer's; nothing is
  claimed about what the pinned image answers on `57400` before authentication beyond accepting
  the connection, which G1 and `TargetsReady` go on to qualify.
- **Consequences**: tasks T001, T025, T034, T042, T080, T088, T134, T135, T152, T159, the Phase 16
  purpose line, §Path Conventions and §Phase Dependencies; plan §Project structure, P3, P11, P12,
  the SC-049 row and the "Verification-tooling boundary" row; quickstart §1 (`LabReady`), §21, §24,
  §28; `traceability.md` FR-108. `AD-49` carries an amendment note. The `[P]` count stays 84 and
  the per-phase task counts are unchanged.

### AD-58: Sixth-pass closures — the specification and the constitution's carriers

- **Decision**: five closures in the specification and its carriers, none needing a decision.
  (1) **CR-010 has testers.** T115 gains two cases and stays one task: an envtest fake-state
  read-back case in the pattern of T054 — a `mac-vrf` whose gateway declares IPv6, qualified, the
  applied side showing the IRB and the anycast gateway up and the IPv4 Type-5 present but no IPv6
  Type-5 route → `Ready=False/RoutesMissing` naming that route — and the interpretation fixture
  `refuse_gateway_ipv6_unqualified`, in T091's fixture directory and test file and in the pattern
  of T105's `egress_unqualified`. T116 and T117 make them pass; CR-010's carrier list and its
  traceability row name builders and testers apart. (2) **FR-105's removal of a modified service
  reads as the data model does**: the modification is stated at that request's first confirmation
  and the removal proceeds only through both; T094 asserts it. (3) Key Entities cites
  `plan.md` §Component inventory, the heading that exists. (4) The quickstart's G6 row states the
  9320/9300 payload boundary with one byte more failing, as plan G6, T043 and CR-009 already do.
  (5) The forward table's eight `yes` rows that later passes reworded — FR-054, FR-057, FR-066,
  FR-067, FR-078, SC-007, SC-008, SC-035 — carry the AD note their neighbours carry; no flag is
  changed.
- **Rationale**: CR-010 was added by `AD-50` with three carriers that were all implement tasks, so
  the constitution's *Known limitation* — "the affected service MUST report `Ready=False` … naming
  the missing route" — had nothing that would fail if `internal/verify/gateway.go` ignored the IPv6
  route, and the unqualified-IPv6-gateway refusal had no fixture although the egress case beside it
  did. FR-105's "the operator is told first and asks again", read literally, is a new request that
  detects the same mismatch again and can never delete; `data-model.md` §15 and `CD-04` had the
  workable rule and the requirement did not. The remaining three are a heading that was renamed, a
  gate row one clause short of its siblings, and notes applied to four reworded rows and not to
  eight others. `yes` is defined over "both passes" — the merge and the retarget — so the flags are
  not wrong and are left alone.
- **A wording decision recorded**: the unqualified-gateway fixture is written by **T115 (US8)**, not
  by T091 (US4), although it lands in T091's directory and test file. The mapper's catalogue gains
  the gateway only in T117; a US4 fixture that T098 had to make pass would have asked US4 to build
  a US8 property, the ordering defect `AD-45` and `AD-50` removed elsewhere.
- **Alternatives rejected**: *a new task for the gateway read-back test* — the rules of this pass
  mint no task, and T115 is already US8's test task with T116 following it. *Putting the read-back
  case in T054* — T054 is US2's and precedes `internal/verify/gateway.go` by six stories. *Flipping
  the eight `yes` flags to `adapted`* — the vocabulary defines `adapted` as the merge moving the
  wording; an analysis pass is neither pass the flag speaks of.
- **Consequences**: spec CR-010, FR-105 and Key Entities (*Path register*); quickstart §1 (the G6
  row); `traceability.md` — rows CR-010 and FR-105 and the eight forward-table notes; tasks T094,
  T115, T116, T117, extended and none added. No requirement, success criterion, risk, gate item or
  task added.

### AD-59: Sixth-pass closures — vocabulary, alerts and the traceability tables

The sixth pass swept the supporting artifacts mechanically against `spec.md`, `plan.md` and
`tasks.md`: the closed vocabularies (conditions and reason codes, the workflow statuses, the audit
event kinds, the stream's chunk types, the alert names, the metric names, the default bounds, the
flags, namespaces, identities and ports), every `§` and `Rule` citation, the forward table against
the identifiers the specification defines, both JSON schemas, and every path, target and object
name the quickstart uses. Almost all of it agreed. What did not is below. Nothing here is a design
decision: **no `FR`, `NFR`, `SC`, `R`, `G` or `T` identifier was added or renumbered.**

- **Decision**:
  - **An unqualified property is an `unsupported_properties` entry; there is no third list.**
    `data-model.md` §8 gave the interpretation a field `unqualified_properties`, which
    `contracts/interpretation.schema.json` does not have and — being closed
    (`additionalProperties: false`) — cannot carry; the schema's own text already routes an
    unqualified construct or property through `unsupported_properties`, naming it (FR-097), and
    the tier's models are generated against the schema. The schema is the contract: §8 loses the
    row and says where the case goes. The mapper's refusal (T098) and the refusal fixtures never
    used the field and are unchanged.
  - **Each audit event is emitted by exactly one process.** `data-model.md` §16, the plan's
    component rows and `AD-18` split the six kinds three and three — confirmation, decline and
    refusal are the supervisor's; submission, removal and out-of-band are the deployer's — while
    T101 listed *submission* among the events the supervisor's `audit.py` emits and T100 emitted it
    too. Built as written, every submission would be recorded twice and SC-030's equal-count
    reconciliation would fail on a correct run. T101 now states the supervisor's three and names
    the deployer's.
  - **Every alert of the required set of ten is shown to fire and to clear, and the artifacts say
    how.** `data-model.md` §21 claimed that of all ten by the acceptance run, while T134, the
    plan's SC-035 check and SC-035 fired four. Two proofs now exist. *Live* (`alerts_fire.sh`,
    T134), where the platform has a declared way to make the fault: the link, the failed
    reconciliation, the management-network cut, a stopped stage and — new — `EvpnRoutesLost`,
    fired by `AD-43`'s declarative fault (`Fabric.spec.overlay.interASVPN: false`) on a lab that
    carries a spanning service and cleared by patching it back, reported as *not run* where no
    spanning service exists. *By a rule unit test* (`tests/unit/alerts/`, written in T130 before
    the rules): `promtool test rules` over synthetic series, every rule fired, cleared and held
    silent — which is the **only** proof for `OtlpDataPointsRejected` and `DuplicateDeviceSeries`,
    because provoking them live would need a stage made to refuse data and a second ingestion path
    and no artifact records a way to produce either on the pins, and for the `EvpnRoutesLost`
    guard's no-fire half (no EVPN instance; one EVI on one leaf — `AD-48`). `promtool` is run from
    the pinned Prometheus image itself, so no host tool is added to pin (NFR-003). A rule test
    proves the expression, not the pipeline, and is recorded as a rule test, never as a live
    firing.
  - **R-03 is live.** The retarget rewrote R-03 in the plan — "the licence-free emulated types do
    not model a property a construct depends on", mitigated by the qualification record and the
    refusal by name (FR-097) — exactly as it rewrote R-02, and in the same change
    `traceability.md` recorded it as *retired by RD-01*. The plan row has been live in every
    snapshot since the retarget, carries a mitigation the platform depends on, and tombstones only
    R-04 and R-25; nothing else carries that risk. The plan is right: the forward row is
    *rewritten*, the reverse row *carried*, the retired-records paragraph names two risks, and
    **live risks are 46 of 48**, not 45. Every dated totals paragraph from the retarget onward is
    one low; they are history and are left as written, with one correcting sentence on the most
    recent.
  - **The Obligations index names the task that builds and the task that tests first.** FR-078(b)
    named T089 — a test task — as its builder; the builder is T085's `auth.py` with T080's counter,
    tested first by T077. FR-015(f) and FR-107(b) named T042 as both builder and asserter, because
    `driftpolicy_test.go` and `reverifyinterval_test.go` were written inside the task they test,
    against the task list's own test-first rule. Both files move to **T028**, US1's existing
    controller `[Test]` task, which already asserts the policy on every generated `Config` and the
    re-verification default; T042 makes them pass.
  - **The audit export has one file name.** Quickstart §24 found the export with
    `ls … audit-export-*.ndjson.gz`, a name no task fixed — `evidence_run` names only its own
    record. `data-model.md` §16 now states it once, `audit-export-<attempt>.ndjson.gz` beside the
    evidence record `audit-export-<attempt>.json`, and T088 cites it.
  - **Two stale pointers.** Quickstart §27 cited §23 for the tier writer identity's namespace
    limit; the identity probes are §15. `contracts/kubernetes-objects.md`'s namespace table
    omitted `agentic-netops-services`, which two rows of the same file rely on; it is listed as
    control-plane-owned, created with the provider (T042) and never touched by the tier's removal
    (`AD-26`, `AD-35`).
- **Rationale**: a closed vocabulary is only closed if every artifact that states it states the
  same one, and the three defects that mattered here were each a second statement nobody
  reconciled — a field the contract cannot carry, an event two processes emit, a proof claimed for
  ten alerts and built for four. The alert closure prefers an honest split to a uniform claim: a
  live firing that cannot be provoked without inventing how a collector misbehaves is not
  evidence, and a rule test reported as a live firing would be exactly the hand-authored pass
  NFR-013 forbids.
- **Alternatives rejected**: *add `unqualified_properties` to the schema* — it widens a published
  contract to carry a distinction the refusal's wording and the audit event's `reason` already
  carry, and the tier's strict models would have to follow; *let both processes emit the
  submission and deduplicate at reconciliation* — it puts the rule in the reader, and a record
  that needs deduplicating is not the record FR-078 asks for; *provoke `DuplicateDeviceSeries`
  live by re-enabling the device-configuration layer's subscription ingestion* — whether that
  layer exports those series to Prometheus at all on the pin is not recorded anywhere, so the
  step could pass by firing nothing; *narrow §21's claim to the alerts SC-035 names* — FR-087
  makes all ten required, and a required alert nobody has seen fire is the state the inherited
  acceptance record describes; *a new `[Test]` task for the two start-up tests* — an existing
  one fits and no identifier is needed; *tombstone R-03 in the plan to match the count* — it
  deletes a live mitigation to save an arithmetic correction.
- **Consequences**: `data-model.md` §8, §16 and §21; `tasks.md` — T028, T042, T088, T101, T130
  and T134, extended and cited, none added; `plan.md` — the SC-035 check and the scheduled
  re-verification row; `spec.md` — SC-035; quickstart §21 and §27;
  `contracts/kubernetes-objects.md` (the namespace table); `traceability.md` — the R-03 rows, the
  retired-records paragraph, the fifth-pass totals sentence, and the FR-015(f), FR-078(b) and
  FR-107(b) index rows. Live risks: 46. One consequence for CI: the alert-rule suite is an offline
  shell suite under `tests/unit/`, so `make test-static` discovers it (T025) and the offline job
  needs a container runtime and the pinned Prometheus image.

### AD-60: Sixth-pass closures — what the six editors left at their edges

> **Amended by AD-62** (seventh pass, 2026-09-21): the three-valued `ready` of the `progress` chunk
> reached the contract and the UI client (T124) only. `AD-62` gives it its model
> (`data-model.md` §15 `ResourceRef`), its emitter (T100), its carrier (T085), its asserter (T092)
> and its rendering (T125).

Each editor of the sixth pass reported defects it saw outside its own slice. They are closed here so
that the next pass does not rediscover them; none needed a decision.

- **Decision**:
  - **FR-108 names the gate's throwaway Pod.** `AD-55` has gate item G7 observe the pinned telemetry
    client from a throwaway Pod pair; FR-108 allowed a device session only "from the operator's
    host". It now also allows a throwaway Pod the gate starts in a scratch namespace it labels, passes
    the lab operator's device credentials to for its lifetime only, and removes.
  - **The leftover scan reads the cluster for gate-labelled scratch namespaces** as well as for a
    gate-labelled `Config` (T043) — a gate that died mid-G7 would otherwise leave a telemetry client
    holding device sessions against FR-086's limit.
  - **A declarative fault is restored from an exit trap** (T064's `interASVPN: false`, T167's
    `maintenance[]` entry): a wait that times out fails the run *after* restoring, never before.
    *Amended by AD-64*: there is a third maker — T134's `alerts_fire.sh`, which makes the same
    `interASVPN: false` fault and disables a link through `maintenance[]` — and it restores both
    from an exit trap too.
  - **The control-plane-only acceptance run is one pass on the standing lab**, with none of T151's
    deploy → test → destroy cycles (T175, quickstart §24); the full teardown follows quickstart §28,
    which re-provisions the tier on that lab; T089's purge check ends with the tier provisioned again.
  - **`ready` on a `progress` chunk is the three-valued status string** `"True"|"False"|"Unknown"`
    with its reason, never a boolean (`contracts/supervisor-http.md`, T124) — `AD-40` and `AD-53`
    gave `Ready` values a boolean cannot carry — and a cluster-API failure, the admission webhook
    included (`AD-52`), is an `error` chunk of NFR-010's dependency-failure class.
  - **An `accessLists`-only object is never an owner** under the one-owner webhook rule
    (`contracts/crd-api.md`); data-model §12's `ip-vrf` row says `vrf`, and `vlan` when tagged, as
    `contracts/network-spec.md` §2 does; quickstart §6's refusal loop lists every fixture T091 and
    T105 create.
- **Rationale**: every one is a place where two editors' changes met. None changes what the platform
  does; each states what an implementer would otherwise have had to guess.
- **Alternatives rejected**: leaving them as leads for the seventh pass — a known defect costs less
  to fix than to rediscover.
- **Consequences**: FR-108; `contracts/supervisor-http.md`, `contracts/crd-api.md`; data-model §12;
  quickstart §6, §24; tasks T043, T064, T089, T124, T167, T175. No identifier added.

### Seventh pass — 2026-09-21

The seventh cross-artifact analysis (2026-09-21) found no constitution conflict and one high finding — a
consequence of `AD-52` — with four of its six slices carrying nothing above medium. `AD-61` closes the
high finding; `AD-63` is a choice made on the analysis's recommendation, reversible, with the alternative
recorded; the rest are closures. No operator decision was needed.

### AD-61: The fail-closed webhook evaluates its rules on a create and on an update that changes `spec` — never on a metadata-only update or on a deleting object *(FR-034, FR-103, AD-52)*

- **Decision**: the validating webhook of `AD-52` **evaluates its cross-object rules on a `CREATE`,
  and on an `UPDATE` that changes `spec` on an object with no deletion timestamp — and on nothing
  else.** An `UPDATE` whose `object.spec` equals its `oldObject.spec`, compared semantically — a
  finalizer added or removed, a label, an annotation, the force-release annotation included — and
  **any** `UPDATE` of an object that carries a deletion timestamp are **admitted without evaluating
  a rule**. The registration `AD-52` fixed does not move: `failurePolicy: Fail`, `CREATE` and
  `UPDATE` of `networks`, never `DELETE`, no `timeoutSeconds`. The exemption is the **first step of
  the handler**, not a narrower `rules` entry and not a `matchConditions` expression, so every
  `UPDATE` still reaches the webhook and, while it cannot be reached, is still refused. The
  provider's status writes were never in question — the rule names `networks`, not its `status`
  subresource. **Nothing is widened**: the force-release annotation is guarded where it always was —
  the admission *policy* `deny-tier-force-release`, a separate admission step, denies it to both
  tier identities on `CREATE` and `UPDATE` alike, and the provider honours it only with a reason and
  only on an object both deleting and blocked on `TargetUnreachable` (FR-103) — a metadata-only
  `UPDATE` can take no subinterface, tagging mode or binding, those being read from `spec`; a
  deleting object still **holds** its mode and its bindings against every other object's admission,
  from its stored `spec`; and the CEL rules are the API server's and run on every write as before.
- **Rationale**: the rules of `contracts/crd-api.md` are stated as invariants of an object — "every
  attachment names a node and an access port the `Fabric` inventory lists" — and `AD-52` registered
  them for every `UPDATE` with no scope, reasoning that "nothing the webhook checks bears on a
  deletion". That is true of the `DELETE` and overlooks that, in the Kubernetes API, removing a
  finalizer and setting an annotation are `UPDATE`s of `networks`. Three things the platform itself
  requires are exactly such an `UPDATE`, on an object whose `spec` may no longer pass a rule it
  passed when it was admitted: Rule 8 step 7, the provider removing its finalizer; **the
  force-release of FR-103 on a device that never returns** — FR-103 says that "removing the device
  from the fabric design completes nothing and releases nothing, so a device that never returns
  leaves the force-release as the only exit", and with the node gone from the inventory *Attachment
  resolvability* refuses the annotation that is that exit; and the deletion of a service whose
  attachment stopped resolving after a topology change (an edge case the specification names), or
  whose construct the qualification record no longer shows. Read literally, the two contracts could
  not both hold, and an implementer who ran every rule on every `UPDATE` — what the webhook
  scaffolding does by default — would have built a deletion with no exit at all, the fail-closed
  policy removing even the option of working around it. No test passed a metadata-only `UPDATE`
  through admission.
- **Alternatives rejected**: *narrowing the registration with `matchConditions`* — it would put half
  of "what is evaluated" in the configuration and half in the handler, it would make what is
  admitted while the provider is down differ by kind of update, which `AD-52` decided it should
  not, and nothing needs it: only the provider removes its finalizer or acts on the force-release
  annotation, and it is the provider that is down. *Exempting only the provider's own identity* —
  the force-release is set by an operator, not by the provider, and an identity check would leave a
  live object with a stale attachment unable to take even a label. *Evaluating the rules on a
  deleting object whose `spec` changes* — a deleting object renders nothing new (Rule 8 step 1
  stops render changes), so a refusal there protects nothing and can only stand between an operator
  and a removal. *Refusing a `Fabric` edit that would strand a service's attachment* — a second
  cross-object rule in the other direction, on a Kind whose validation is CEL alone by `AD-52`, and
  FR-103 already says what removing the device does: nothing.
- **Also closed by this entry** — four closures in the same slice, none a design decision except
  the last, which is a **choice**:
  (1) **The interpretation schema no longer bounds a named VLAN from above.** `AD-56` raised its
  `maximum` to `4094` so that `4001–4094` would reach the mapper; `4095`, `5000` and `0` still
  failed schema validation with neither band stated, and would have been reported as schema-invalid
  *model output* — NFR-010's model-dependency failure — for a number the operator typed. The
  property is now `minimum: 0` with no `maximum`, on `contracts/interpretation.schema.json` only —
  the normalized service intent keeps the structural `1–4094` — and the mapper gains the fixture
  `refuse_vlan_named_not_a_vlan` (`5000`). FR-062's and T098's "every … reaches the mapper" is true
  afterwards. (2) **"A value the object stopped carrying while it lived" cannot occur** after
  `AD-51`: every claimed value sits on an immutable named entry that can be neither removed nor
  renamed, so T055 asked for a fixture the API refuses to produce. T055, T060 and Rule 8 step 6 now
  carry the case that does occur and that T170 and SC-046 already use — a `mac-vrf` whose VLAN was
  allocated, an attachment carrying it removed while it lived, the claim still adopted and released
  only at finalization. (3) **`traceability.md`'s `AD-32` row** stated the three-field predicate
  with amendment notes for `AD-42` and `AD-44` only; it now notes `AD-51`. (4) **The service
  identifier's generation rule is stated, once** (`data-model.md` §8): the mapper's own code, never
  the model and never the tenant — the first 15 lower-case hexadecimal characters of a random
  version-4 UUID. It is the predecessor tier's rule, carried unchanged like that tier's bounds
  (`data-model.md` §25), and it satisfies the schema's `maxLength: 15` and DNS-1123 `pattern` for
  every tenant. The quickstart's examples had implied `<tenant>-<nnnn>`, which breaks the bound at a
  tenant of eleven characters and would again have surfaced as schema-invalid output; a counter
  (`svc` + digits) was **not chosen** because a stateless mapper has nowhere to keep one and holds
  no cluster permission to derive one. Quickstart §11 and §12, the exemplar of
  `contracts/network-spec.md` §6 and its configuration resource in `contracts/crd-api.md` now carry
  identifiers of that shape, and quickstart says they are illustrative; the hand-authored
  translator inputs in the normalized schema's examples are the CLI path's and are untouched.
- **Not assumed**: nothing about the pinned cluster beyond the Kubernetes API's documented
  behaviour — that a finalizer or annotation change is an `UPDATE` of the main resource, that an
  admission request carries `oldObject`, and that a webhook rule naming `networks` does not match
  `networks/status` — each of which T056 exercises in envtest rather than trusts.
- **Consequences**: FR-034 (one sentence and its provenance note), FR-062 (the schema clause and
  its note); `contracts/crd-api.md` §"Required `Fabric` and `Network` API" (a policy-table row and
  the paragraph "What the webhook evaluates…"), §"API contract tests" (the evaluation-scope test)
  and the exemplar identifiers of its configuration resource; `contracts/reconciliation.md` Rule 8
  steps 6 and 7 and the force-release lead-in; `contracts/interpretation.schema.json` (`vlan`);
  `contracts/construct-vocabulary.md` §5; `contracts/network-spec.md` §6; `data-model.md` §3
  ("Admission fails closed") and §8 (`service_id`); `plan.md` C-05, C-12 and the SC-015 and API
  verification rows; quickstart §6, §11 and §12; `traceability.md` — rows FR-034, `AD-32` and this
  one; tasks T061 (builds the handler's first step), T056 (asserts it: the force-release annotation
  and the finalizer's removal admitted on a deleting `Network` whose node left the inventory, a
  `spec`-changing `UPDATE` still evaluated, the unreachable endpoint still refusing), T055, T060,
  T091 and T098. `AD-52` carries an amendment note. No requirement, criterion, task, risk, gate
  item or reason code added.

### AD-62: Seventh-pass closures — readiness and the stream

The seventh pass re-read the readiness vocabulary after two rounds of edits (`AD-40`, `AD-53`,
`AD-54`, `AD-60`) against every artifact that states it. One finding needed a choice and is `AD-63`.
The six below needed none. **No `FR`, `NFR`, `SC`, `R`, `G` or `T` identifier was added**, and no
condition or reason code: every closure extends an existing requirement, section or task.

- **Decision**: each is closed where the rule is stated, and in every artifact that repeats it.
  - **The stream's `ready` has an emitter, a carrier and an asserter, and its model has its type.**
    `AD-60` made `ready` on a `progress` chunk the three-valued status string with its `reason`,
    in `contracts/supervisor-http.md` and in the UI client (T124) — and nowhere on the side that
    produces it: `data-model.md` §15 still typed `ResourceRef.ready` as `bool|None`, which cannot
    carry `Unknown` and cannot tell `False/Deleting` from `False/NotConverged`, and no tier task
    emitted or asserted the shape. `ResourceRef.ready` is now `"True"|"False"|"Unknown"|None` —
    `None` only before the watch has read a `Ready` condition — with `reason` beside it; T100's
    `watch.py` emits both on every `progress` chunk, T085 streams them unaltered, T092 fails on a
    boolean and on a `"False"` or `"Unknown"` without a reason, and T125 renders `Unknown` and
    `False/Deleting` as neither success nor failure. §7's pointer for `ResourceRef` said §10 and
    says §15.
  - **"Had reported Ready" is read at the current generation.** A Ready object updated to a new
    generation while a target is unreachable was two things at once in `data-model.md` §18 — "an
    object still converging stays `Ready=False`" and "one that had reported Ready becomes
    `Ready=Unknown`" — while `contracts/crd-api.md` already required current-generation `Applied`
    for `Ready=True`. For the new generation the answer is known and is False: nothing of it has
    been applied, so `Ready=False/NotConverged` with `Applied=False/TargetNotReady` naming the
    target. `Unknown` says that a read-back could not be *repeated*, and for this generation none
    was ever made.
  - **SC-044's "never True, never False" polls start at the first `Unknown`.** `AD-40`'s
    between-passes rule gives the platform up to SC-008's two reconciliation intervals to learn of
    a cut, and `Ready=True` necessarily stands for those seconds; SC-044, T064 and T167 said "at no
    point" and "at any poll during the outage", which no build can satisfy and which invites a
    test that sleeps until it passes. The polls run from the first `Unknown` — which must itself
    arrive inside SC-008's bound — until reconnection. The `Ready=True` of the seconds before the
    platform can know is not a remembered result: nothing had yet failed to be re-read.
  - **A `Fabric` has no held deletion.** T040 said the schedule requeues a `Fabric` "held in
    deletion"; Rule 8, `contracts/crd-api.md`'s deletion bullet and `AD-53`'s carriers are all a
    `Network`'s, and no artifact gives the `Fabric` a finalizer. The clause is dropped from T040
    and nothing is added: a `Fabric` deletion rule is not a gap this pass was asked to fill.
  - **`ReverificationStalled` fires on an age, whatever `Ready` says.** `data-model.md` §21 —
    the one statement — says so; quickstart §21 and `contracts/crd-api.md` still described it as
    firing on "a `Ready=True`" that was not re-verified. Both now say the age of the last pass
    that ran, for every object with a series. FR-107's own clause names the case it exists for and
    is left as it is.
  - **The `Degraded` reasons have a total order, and each has a builder.** §18 ordered "the two
    that can meet on the `Fabric`"; `TelemetryUnavailable` can meet either — a leaf cut from the
    management network takes the telemetry target with it — and neither it nor `PartialFailure`
    was named by any task. The first two follow `Ready` and never compete (`PartialFailure` with
    the `Ready=False` of a partial failure, `VerificationFailed` with `Ready=Unknown`); then, on the
    `Fabric`, `StaleConfigurationPossible`; and last `TelemetryUnavailable`, the reason only when
    NFR-002's telemetry dependency is the one thing impaired — so on the `Fabric`
    `VerificationFailed` > `StaleConfigurationPossible` > `TelemetryUnavailable`. T040 and T059 set
    them through T023's setter, `TelemetryUnavailable` from a telemetry-health input they are
    given — a fake in envtest, the provider's own telemetry health once T133 wires it — and never
    from a device read; T028 and T054 assert each.
- **Rationale**: every one is an edge between two earlier closures — a contract amended and its
  model not, a rule stated for the object and not for its generations, a criterion written before
  the rule that bounds it, a precedence stated for the pair that prompted it. None changes what
  the platform decides; each removes a place where two implementers would have built two things.
- **Alternatives rejected**: *`Ready=Unknown` for the updated object* — it would report "not
  observed" about a generation the platform knows it has not applied, and hold the tier's watch
  open on a change that has visibly not been made. *Keeping "at no point `Ready=True`" and
  shortening the detection bound to zero* — detection is the device-configuration layer's, and no
  requirement of this feature can make it instantaneous. *Giving the `Fabric` a finalizer to make
  T040's clause true* — new behaviour, with its own allocation-release questions, to repair a
  stray clause. *A second `Degraded`-like condition for telemetry* — a vocabulary change where an
  order suffices, and NFR-002 says `Degraded`. *Leaving `TelemetryUnavailable` defined and
  unbuilt* — §18's closed set is asserted as a set by T023, so a reason nothing sets is a reason
  nothing tests.
- **Consequences**: FR-107 (the scope sentence and its provenance note) and SC-044; `data-model.md`
  §7 (the pointer), §15 (`ResourceRef`), §18 (the closing paragraph; the order of reasons);
  `contracts/crd-api.md` §Status contract (three bullets); `contracts/kubernetes-objects.md`
  §Submission contract step 7; plan.md's SC-044 row and its cluster-is-the-record paragraph;
  quickstart §21 and §27a; traceability's FR-107(c) and SC-044 rows; tasks T028, T040, T054, T059,
  T064, T085, T092, T100, T125, T133, T167 — amended in place, none added. `AD-60` carries an
  amendment note.

### AD-63: A removal asked of the tier ends when the object is gone, or says what it is still waiting for *(FR-069, FR-067, AD-53)*

> **Ratified by the operator, 2026-09-21 (`AD-73`)**, as written. It is an operator decision from here on; the alternative recorded below stays recorded and is no longer open.


- **Decision**: **the coordinator's choice on the reviewer's recommendation, 2026-09-21 — reversible;
  not an operator decision.** A removal asked of the tier, after both confirmations, **deletes the
  `Network` and watches until the object is gone**, bounded by the same convergence timeout as a
  creation (`data-model.md` §25, 150 s by default). (a) **Gone within the bound**: the removal is
  reported complete — `COMPLETED`. (b) **Still present at the bound**: the turn ends reporting the
  removal as **in progress** — never as a success and never as a failure — naming what the object's
  `Deleting` condition says is outstanding (`TargetUnreachable` names the target, `HolderPresent`
  the holding service), saying that it completes without operator action when that ends, or by the
  force-release that is never the tier's to set (FR-103); a later status query (FR-069) answers
  from the live object. **No status is minted.** The removal moves `APPROVED` → `PROVISIONING` and
  never through `CONFIGURED` or `VERIFIED`; ending (b) is a `final` chunk **at `PROVISIONING`** — the
  member of the closed set that D-24 maps to "submitting", a change made and not yet observed
  complete — and never `COMPLETED`, `FAILED` or `STATUS_UNKNOWN`; it is not counted as a converged
  request (FR-092). A **creation** watch that sees `Ready=False/Deleting` — the object deleted under
  it — ends as a failure naming the deletion, and is an out-of-band deletion (FR-105) when the
  tier recorded no removal of that object.
- **Rationale**: the seventh pass asked what "converged" is for a removal and found that nothing
  said. FR-067's three outcomes are defined for a watch "until it reports Ready"; FR-069 said a
  removal is a change and stopped; T100 deleted the `Network` and said no more; quickstart §26a had
  the *operator* wait for the object to be gone; and `AD-60`'s contract already showed
  `"reason":"Deleting"` on a `progress` chunk, which only a watched removal would ever produce.
  `AD-53` made the question sharper, not easier: a deleting object is `Ready=False`, which a reused
  creation watch would read as a failure. The build that silence invites — answer "removed" when
  the API server accepts the delete — reports as done a thing that FR-103 deliberately leaves
  unbounded, on an object that still exists and still holds every identifier.
- **Alternatives rejected**: ***the turn ends when the delete is accepted*** — the smaller build,
  and it reports a removal the platform has not observed: with a leaf away the object, its
  configuration on that leaf and all its claims are still there when the operator is told they are
  gone, which is what constitution Principle I forbids of `Ready=True` and no less of "removed".
  *Watching without a bound* — FR-103's hold has no deadline, so the turn would be a hang, which
  FR-053 forbids. *`FAILED` at the bound* — nothing failed; the finalizer is doing what FR-103
  requires, and a failure invites the operator to retry or to force. *`STATUS_UNKNOWN` at the
  bound* — that status is for an outcome the platform cannot observe, and here it observes it
  exactly. *A new `REMOVING` status* — a vocabulary change across the stream, the surface, the
  audit record and D-24 for a state an existing member already names.
- **Consequences**: FR-069 (the rule), FR-067 (the `Deleting` sentence and the pointer) and FR-105
  (a deletion seen by an open watch is a detection), with their provenance notes, and one edge
  case; `data-model.md` §17 (the removal's paragraph) and §15; `contracts/supervisor-http.md`
  (the rule and both example endings — the in-progress ending's text rides the operator-facing
  message the `final` chunk already may carry); `contracts/kubernetes-objects.md` §Submission
  contract (step 7 and the removal's steps); plan.md's Principle I row and its
  cluster-is-the-record paragraph; quickstart §26a and the failure table; traceability's FR-067,
  FR-069 and FR-105 rows; T100 (builds), T092 (asserts both endings and the deleted-under-watch
  case, with a fake clock and the fake API server), T079 and T085 (not counted as converged), T125
  (rendered as in progress). D-24 carries an amendment note: `CONFIGURED` and `VERIFIED` do not
  apply to a removal. No identifier was added and no status.

### AD-64: Seventh-pass closures — the lab's lifecycle and the verification tooling

The seventh pass walked the timeline an implementer walks — every provision, purge, teardown and
re-provision the task list and the quickstart imply, from Phase 3 to T164 — and read the
verification tooling against FR-108 as the fifth and sixth passes left it. It found no two
statements that cannot both hold and no criterion that cannot be recorded. What it found is nine
places where a step needs something the step before it removed, where a rule stated for two makers
has a third, or where an obligation has a builder and nothing that asserts it. None needed the
operator. **No `FR`, `NFR`, `SC`, `R`, `G` or `T` identifier was added or renumbered**, and no
`[P]` marker moved.

- **Decision**:
  - **`off.sh` never deletes anything under the lab's evidence root.** `data-model.md` §16 rests
    `AD-55`'s *verified* test on "the lab's evidence root outlives a teardown", and FR-078 says
    that after the export "the evidence file is the record" — while FR-010 and T049 made "the
    preservation of captured evidence" a flag and no artifact said what the script does without
    it. The natural reading of a flag named `--preserve-evidence` is that evidence is not
    preserved otherwise, and built that way a teardown would delete the audit record it had just
    exported, the usernames record beside it, the first two cycles of T151 that T154 audits and
    the tier-phase captures T148 reads. The rule is now stated: neither script deletes anything
    under `.evidence/<cluster>_<lab>/`, on the full teardown or on the tier's purge, with the flag
    or without it; the flag only **adds** the optional capture T049 opens with — through
    `evidence_run`, of the state the teardown is about to remove — which is the *evidence* step
    of `data-model.md` §2's teardown line. T029 asserts it for the full teardown, with and
    without the flag, and T174 for the purge, completed and refused.
  - **T052 ends with the lab provisioned again.** It runs the shutdown from Ready, partial and
    absent states, so it ends with nothing standing, under a checkpoint that reads "a
    reproducible lab with a converged default `Fabric`", and every live task of US2 and US6 that
    follows needs one. It is the defect `AD-57` closed for T152 and T159 and `AD-60` for T089, at
    its first occurrence on the timeline.
  - **Quickstart §25 to §27a run after §11 and before §24's block, or after §28's step 0.** §24's
    note said "any time after §11" and §25 "before §24's teardown", while §24's own block destroys
    the lab three times and then purges the tier: between that purge and §28's re-provisioning
    there is no tier for §25, §26 or §26a to drive, and that is exactly where a reader following
    the document in order runs them. §19 already said "Run this before §24". §26, §26a, §27 and
    §27a say nothing about when they run and needed no change.
  - **T134's two declarative changes are restored from an exit trap.** `AD-60` stated the rule for
    "a declarative fault" and named two makers; `AD-59`, in the same pass, had given
    `alerts_fire.sh` the same `interASVPN: false` fault and it already disabled a link through
    `maintenance[]`. Because both are intent, `leftovers::scan` cannot find them after a run that
    died — which is the reason for the trap, now written into T134, the plan's SC-035 row and
    quickstart §21. `AD-60` carries an amendment note naming T134 as the third maker.
  - **Four obligations get the test that asserts them, inside existing tasks.** *(a)* `AD-60`
    made a gate-labelled scratch namespace a kind of leftover and T043's fixture still planted
    three kinds; it plants a **fourth**, and the plan's "one of each kind" names the four.
    *(b)* T043 said T166's throwaway Pods carry the gate-owned label and T166 did not; T166 now
    labels each scratch namespace and reads its removal back. *(c)* `AD-55` has
    `ObservabilityReady` stop non-zero on an absent series name or a differing setting, with
    nothing offline showing that it does; `tests/unit/lifecycle/observability_recheck_test.sh`,
    written in T134 before the phase as T044 writes `g11_stop_test.sh`, drives the phase against
    a fake `kubectl` and a fake Prometheus and asserts both stops, the not-yet-observable case
    and the negative control. *(d)* `AD-45`'s install order — the store and the tier collector
    applied and waited Ready after the denial probes and before any agent workload — was asserted
    by no call-order test, T174 covering only the down path; T174 gains a second file,
    `tests/unit/lifecycle/tier_phase_order_test.sh`, against the same fake `kubectl`, and T088
    names it as the order it makes pass.
  - **T153 stops before §28.** T159 said T153's clean-host run "ends in the full teardown of
    quickstart.md §24", and `AD-60` had moved that teardown after §28 — whose recording tooling
    is T157's, in Phase 16, and does not exist when T153 runs. T153 now says what it runs: the
    quickstart up to and including §27a, then the teardown; T159's sentence and the plan's SC-032
    row follow.
  - **T103's live-store export is `audit_export.sh` invoked stand-alone, and a usernames record
    an earlier export left is never read for the running tier.** T103 proves the file-source
    mode "against an export taken from the live store" with "the usernames record beside it", and
    `data-model.md` §16 said that while the tier is up there is no usernames record. Both are
    true once it is said how: the export function writes the record beside the export whenever
    it runs and removes nothing, so invoking it stand-alone is the one way T103 has; and by
    Phase 15 the lab's evidence root holds records from T089's removal and from T103. §16, T148
    and quickstart §25 now say that the record of the removal that will end the running tier does
    not exist yet, and that an earlier one — a snapshot of the captures up to its export — is
    never read for it. *Decided here*: the narrower wording "no record of the current tier
    instance exists" was not used, because T103's stand-alone export is of the current instance;
    what makes an earlier record unreadable for T148 is that captures may follow it, not whose
    it is.
  - **The traceability row for FR-108 and the quickstart's gate paragraphs name the throwaway
    Pod and the fourth leftover kind**, as FR-108 has since `AD-60`.
  - **The offline job's one non-lab need is stated where the job is defined, and the gate's
    observed files are committed.** `AD-59` recorded that T130's `promtool` rule test needs a
    container runtime and the pinned Prometheus image, and recorded it only here; T007, T025, the
    plan's `test-static` row and quickstart's Gate 0 now say so — "none of which needs a lab"
    stays true and is completed by "one needs a container runtime". The same test reads its
    series names from `tests/gate/observed/telemetry-series.json`, which a **live** gate writes,
    and no artifact said how an offline job comes to have it; the plan even says run-captured
    evidence is "never checked in as a substitute for a run". The observed files are not that
    evidence but build inputs derived from it, as the goldens frozen against G12's
    `serialization.json` always were: they are tracked, committed after the gate run that wrote
    them, carry no run-specific field so that an unchanged observation is an unchanged file, and
    the run-captured evidence of the same observation stays under the evidence root. Until the
    file exists the rule test reports "not run: series names not yet observed" — named in the
    runner's summary, never counted as a pass — and `alerts_fire.sh`, which runs on a lab whose
    gate has written it, treats a "not run" there as a failure.
- **Rationale**: every one of these is the class the two passes before this one closed elsewhere —
  a live task that does not say where its lab comes from, a rule with one maker more than its
  list, a MUST with a builder and no tester — found by walking the order instead of reading each
  artifact against the others. The evidence-root rule is the only one that could have cost data:
  the other eight cost an implementer an hour, that one costs the audit record FR-078 exists to
  keep.
- **Alternatives rejected**: *make `--preserve-evidence` the switch that keeps the evidence root*
  — it turns FR-078's unconditional export into one that survives only when a flag is remembered,
  and `AD-55`'s lookup under the root into something that usually finds nothing. *Assert the
  purge's half of the evidence-root rule in T029* — T029 is US1's and `--purge-intent-tier` is
  reserved until US7, so the case could not pass at US1's close; it sits in T174, which owns the
  purge. *Drop T052's shutdown runs, or move them to the end of US2* — SC-003 is US1's criterion
  and the MVP stops there. *Renumber §25 to §27a ahead of §24* — the section numbers are cited
  across the task list and the plan; the note is what was wrong. *A new `[Test]` task for the
  two fixture files* — T134 and T174 each own the behaviour and T044 already set the pattern of a
  task writing the fixture it then makes pass. *Have T148 read the usernames record T103's
  export left* — a capture made after that export would be missing from it. *Keep the gate's
  observed files out of the tree and have the rule test derive its names from the path register*
  — the register's names are derived, not observed, which is the guess `AD-48` forbids; *or
  exit non-zero while the file is missing* — every pull request before the first gate run would
  fail on something no pull request can fix, where a named "not run" is honest and
  `alerts_fire.sh` still refuses it on a live lab.
- **Not assumed**: what the optional teardown-time capture contains beyond "the state the
  teardown is about to remove" is the implementer's, as it was; nothing is claimed about which
  options of the pinned images bear on a series name (`AD-55`), nor about whether a hosted CI
  runner offers a container runtime — T007 requires one and says why.
- **Consequences**: spec FR-010; `data-model.md` §2, §16; `contracts/reconciliation.md` Rule 10;
  quickstart Gate 0, §1 (the gate's FR-108 paragraph and the leftover paragraph), §21, §24 (the
  note, the teardown comment, the shutdown paragraph), §25; plan §Project structure (the observed
  files), the `test-static` row, C-18, the SC-032 and SC-035 rows, the "Verification-tooling
  boundary" and "Audit export and tier removal" rows; tasks T007, T025, T029, T043, T049, T052,
  T088, T103, T130, T134, T148, T153, T159, T166, T174; `traceability.md` FR-010, FR-108 and this
  entry's row; research `AD-60`. Two test files are named inside existing tasks —
  `observability_recheck_test.sh` (T134) and `tier_phase_order_test.sh` (T174) — and no task id
  is added.

### AD-65: Seventh-pass closures — the specification's indexes and carriers

- **Decision**: four closures in the specification's indexes and the constitution's carriers, none
  needing a decision.
  (1) **The Obligations index says which text it reflects.** Its preamble still dated it to the
  operator review of 2026-09-20 while FR-109's rows (l) to (n) and FR-107's rows (c) and (g) cite
  sixth-pass decisions. It is redated to the seventh pass, which re-read every row of FR-015,
  FR-078, FR-107, FR-109 and NFR-003 against its requirement in both directions, and it keeps one
  sentence per pass saying what that pass added. The re-read found: two clauses of FR-109 with no
  row — *no claim is created on a deleting object* (T060 builds, T170 asserts) and `AD-52`'s
  *neither kind of object can be applied while the provider is down* (T061 builds, T056 and T173
  assert) — both written into row (i); FR-015's *overruled platform-owned path is a terminal
  error*, now row **(h)**, carried by T059 and T054 as `AD-66` left them; FR-078(f) one definition
  short — what a *failed* export is, and the skipped and the empty store — which T174 already
  asserts case by case; FR-107(f) without the between-passes case of `AD-54` and FR-107(c) without
  the current-generation reading of `AD-62`. NFR-003 needed nothing.
  (2) **FR-108 is indexed.** It was written by `AD-03`, given three definitions and the leftover
  rule by the operator review, the drift-class exception and the gate-owned `Config` by `AD-48`
  and the throwaway Pod by `AD-55`/`AD-60`, and no pass had enumerated it. Eleven rows, built-by
  and asserted-by taken from T011, T025, T034, T043, T051, T064, T066, T073, T134, T151, T154,
  T157, T166 and T167 as they stand. Five rows say, rather than hide, that the clause is stated by
  its builder and that no test would fail without it: that `Fabric.status` is unchanged by the
  post-render probe's outcome (a); that a gate which skipped its removal read-back would be caught
  offline (c); which credential a tool presented (e); the scratch `Config`'s unused priority and
  unrendered path, and that a declared fault's record precedes the fault (h, i).
  (3) **FR-108's leftover rule names the gate's labelled scratch namespace.** T043's
  `leftovers::scan` already looked for it — a gate that died mid-item would leave a Pod holding the
  lab operator's device credentials and a management session against FR-086's limit — and the
  requirement named only the node-side leftovers and the gate-owned `Config`. The MUST lived in a
  task; it is now in the requirement, and `AD-64` gives T043's fixture the fourth plant.
  (4) **CR-004's carriers gain FR-015 and FR-045.** "Rollback on failure" at the device is FR-015's
  transaction, and "unrenderable objects MUST NOT be stranded" on the migration path is FR-045's
  rejection before any device mutation; the plan's Principle III row cited both and CR-004's
  list, which the gate check points at, cited neither.
- **Rationale**: an index that misdates itself is read as stale and then not read; the two FR-109
  clauses and FR-015(h) are exactly what the index exists to surface — a clause inside a long
  requirement that a task list can look complete without. None of the four changes what the
  platform does.
- **A wording decision recorded**: the index rows for the five unasserted FR-108 clauses name the
  gap and **mint no test**. The rules of this pass add no task, none of the five is a behaviour an
  operator relies on unobserved — each is either structural (the provider holds no device
  credential) or backstopped by the start-up scan — and FR-107(i) set the precedent of recording an
  open carrier rather than inventing one. They are reported to the coordinator as candidates.
- **Alternatives rejected**: *splitting FR-108 into sub-identifiers* — it would renumber the
  specification, which no pass has done. *Deleting the index's history sentence and only redating
  it* — the rows cite decisions from three passes, and a reader checking one needs to know which
  pass wrote it. *Leaving the scratch namespace to T043* — a requirement that lists the leftovers a
  run must refuse on, and omits the one that holds a credential, is the wrong place to be short.
- **Consequences**: spec FR-108 (leftover sentence and note), CR-004 (carriers and note) and the
  Requirements preamble; `traceability.md` — §Obligations index (preamble; rows FR-015(h),
  FR-078(f), FR-107(c), FR-107(f), FR-109(i); the new FR-108 subsection), forward rows CR-004 and
  FR-108, and this entry's row. No requirement, success criterion, risk, gate item or task added,
  and no task edited.

### AD-66: Seventh-pass closures — names, commands and an uncovered clause

- **Decision**: seven closures from the seventh pass's mechanical sweep of the supporting artifacts,
  none needing the operator.
  - **The tier metric prefix is the literal `agentic_netops_agent_`, and FR-092's per-stage outcome
    counter is `agentic_netops_agent_stage_requests_total{stage,outcome}`** — both stated once, in
    `data-model.md` §21. No artifact had stated the prefix as a string: D-37 and §21 said only that
    "every tier metric carries the prefix that passes the fabric collector's filter", T129 had to
    write a filter for it, the two counters CD-01 and CD-04 named were `intent_…` — "carrying the
    tier prefix", which they did not — and quickstart §21 alone queried
    `agentic_netops_agent_stage_requests_total`, a name no task built. **The choice follows the
    predecessor, read and not run**: `/root/agentic-netops/agents/common/metrics.py` fixes
    `_PREFIX = "agentic_netops_agent_"`, refuses to register an instrument whose name does not
    start with it, and names its per-stage counters `agentic_netops_agent_stage_requests_total`,
    `…_stage_success_total` and `…_stage_failures_total`, each labelled `{stage}`; its alert rules
    and its dashboard query those names. The tier is carried unchanged (D-20), so the prefix and
    the counter's name are kept; the `outcome` label is `AD-54`'s, which made the success rate a
    computation over one counter with a closed outcome set, so no second series counts the same
    outcomes. `intent_auth_refusals_total` and `intent_out_of_band_changes_total{change}` have no
    predecessor — FR-102 and FR-105 are this feature's — and become
    `agentic_netops_agent_auth_refusals_total` and
    `agentic_netops_agent_out_of_band_changes_total{change}`. The same reading found the
    predecessor's collector filter to be the regular expression `.*agentic-netops.*`, hyphenated,
    which does not match an underscored metric name; T129 therefore matches the literal prefix
    and inherits no pattern, which is what D-37 already asked of the filter.
  - **The quickstart's `go test` commands name the packages that hold the tests.** §7 and §22 ran
    `go test ./tests/unit -run <name>` for tests T119 and T096 put in `pkg/migration`, under
    function names no task gave; §24 ran `go test ./tests/unit`, a directory whose Go tests are all
    in sub-packages. They are now `./pkg/migration` and `./tests/unit/...`; T119 names
    `TestConstructLegacyEquivalence` and T096 `TestConstructNamesMatchDeviceModel`; and each step
    says that `no tests to run` is a **failure** — `go test -run` exits zero when its pattern
    matches nothing, which under constitution Principle I is a pass nobody observed.
  - **FR-015's last clause has a builder and a tester.** "An overruled platform-owned path is a
    terminal error" was carried by `contracts/reconciliation.md` Rule 4, Rule 6 and its
    contract-test row, by the plan's "Device transactions" row and by T059's two words "terminal
    classification"; no test produced an `OVERRULED` deviation and the Obligations index stopped at
    FR-015(g). T054 gains a fake `Deviation{reason: OVERRULED}` on an owned path —
    `Applied=False/OwnershipConflict` naming the path and the overruling intent, no `Config` write
    on any later reconcile, and no such condition for `NOT_APPLIED`; T059 builds it by name; the
    index gains FR-015(h). **Live, it is asserted only if gate item G13 recorded `OVERRULED` among
    the reason strings it saw** (`tests/gate/observed/deviation.json`); otherwise T064 reports
    "not demonstrated live; envtest-covered". Whether the pinned layer can be made to report one
    from the lab is not known, and no way of making one is invented here.
  - **`routeTargets` has two spellings because it is two records.** `data-model.md` §9 showed the
    normalized service intent's object as `{import[], export[]}`; its schema, which forbids
    additional properties, requires `importRT` and `exportRT`. §9 now uses the schema's names and
    says that the `Network` the translator emits carries `routeTargets: {import[], export[]}`
    (`contracts/network-spec.md` §1) — the CRD's names, unchanged.
  - **`AD-46` carries its amendment.** Its definition of a *verified* export — count alone — was
    changed by `AD-55` to count and newest-row timestamp, and said so nowhere.
  - **The stream examples name the object as the tier names it**: `migr-svc1`, the
    `migr-<service_id>` of the interpretation schema, in every example of
    `contracts/supervisor-http.md` — `AD-63`'s two removal endings included.
  - **Quickstart §23's first grep reads `deploy/observability/` alone.** `config/observability/` is
    in no task and not in the plan's tree.
- **Rationale**: the first three are places where following the artifacts produced the wrong thing
  or a false pass — a filter built on a guessed prefix drops the tier's series or the quickstart's
  query returns nothing, a `go test` that matches nothing exits zero, and a MUST with a contract-test
  row had no test. The rest are one name per thing.
- **Alternatives rejected**: *keeping `intent_…` for the two counters and admitting two prefixes in
  the filter* — D-37 constrains the tier to one prefix so that the filter is one expression, and the
  predecessor's module refuses any other name. *A new name for the per-stage counter, such as
  `…_stage_outcomes_total`* — the predecessor's name and the quickstart's query already agreed, and
  a label is a smaller change than a name. *Carrying the predecessor's separate success and failure
  counters beside it* — `AD-54` computes the rate from one series so that `STATUS_UNKNOWN` cannot be
  counted twice or as converged. *Having G13 set out to produce an `OVERRULED` deviation* — it
  would need a second, higher-precedence intent written against a platform-owned path on a live
  node, which FR-108's scratch rules do not cover; the envtest case is the proof, and the live
  suite reports what the gate happened to see.
- **Consequences**: `data-model.md` §9, §16, §21; `contracts/supervisor-http.md`; plan.md P7 (the
  out-of-band paragraph) and the "Drift policy" verification row; quickstart §7, §21, §22, §23, §24,
  §25, §26; `traceability.md` FR-078(b), and the index row FR-015(h), which `AD-65` writes; tasks
  T054, T059, T064, T077, T080, T092, T094, T096, T119, T129, T135; amendment notes on CD-01, CD-04, `AD-46` and `AD-50`.
  No requirement text changed; no identifier added.

### AD-67: Seventh-pass closures — the task list

The seventh pass re-read `tasks.md` after the two rounds in which six editors worked on it at once:
175 unique ids, none ticked, 84 `[P]` markers, no two `[P]` tasks of one phase on one file, every
`make` target declared in T006 and wired by exactly one task, every backticked path of plan,
quickstart and data-model matching the list, no task line mangled. What it found is four places
where one task's sentence about another is no longer the whole truth. Nothing below is a design
decision: **no `FR`, `NFR`, `SC`, `R`, `G` or `T` identifier was added or renumbered**, no `[P]`
marker moved, no task line moved, and T164 is still the last task.

- **Decision**:
  - **T040 says how it stands on a file T041 creates.** T040's reconciler "re-runs T041's
    read-back" and T041, the next task, creates `internal/verify/fabric.go` — the one
    used-before-created reference in the list that carried no forward note, where T049→T088,
    T044→T048, T059→T171 and T168→T080 each carry one, and the opposite of US2's order (T058, then
    T059). T040 now takes the read-back as an interface, which is what T028's fake-state envtest
    drives, and T041 creates the implementation and wires the reconciler to it. The two lines stay
    where they are: ids are not a schedule, but five other editors were anchoring on them.
  - **"Make T028 pass" means its envtest file.** `AD-59` put the provider's two start-up tests —
    `cmd/srl-provider/{driftpolicy,reverifyinterval}_test.go` — into T028, "failing until T042
    builds the binary", and T040 still said "make T028 pass". T040 makes
    `tests/envtest/fabric/fabric_controller_test.go` pass and says that the other two pass with
    T042. A test-only `package main` under `cmd/srl-provider/` compiles nothing until then, which
    is the same tests-first state as every other Go test of the list written before its code.
  - **T168's manifest half is named where it passes.** T168 said its manifest half passes "with
    T087"; T087 did not name it and §Phase Dependencies recorded only the Python half's T080. T087
    now says its read-only `llm-provider` mounts are what make that half of
    `agents/tests/unit/test_llm_endpoint.py` pass, and the prose names both halves.
  - **T072 redacts with its own implementation of the FR-079 pattern set.** T072 printed the
    endpoint "through the same redaction the agents use", which is
    `agents/common/guards/redaction.py` — T074's, two tasks later — and the in-cluster Job has no
    tier image to run it from until T086. The script and the Job implement the pattern set
    themselves; T074's is the tier's implementation; and what keeps the two equal is T168's one
    fixture, the same base URL with embedded userinfo on its shell half and on its Python half.
  - **The credential-literal check has a fixture of its own.** T025's "fixture tests for all three"
    had lost its referent as the task grew: the list that followed planted a `CronJob` and a Role
    (FR-013) and a `gnmic` line (FR-108), and nothing for the FR-019 / CR-008 check, so the one
    check whose purpose is to be "a check that runs … rather than a claim" could have passed by
    matching nothing. A `stringData` password in a manifest under a fixture `deploy/` tree fails
    it naming the file, and the same value behind a `secretKeyRef` passes. Plan's `make`-target
    table says the same.
  - **T175** lost a stray comma after a dash.
- **Rationale**: each is a sentence an implementer working one task at a time would follow
  literally — calling a package that does not exist yet, holding T040 open on tests only T042 can
  satisfy, importing a Python module into a shell script and a Job that has no image, or shipping a
  deny-check with no case that shows it can fail (CR-007: an unbuilt gate never passes silently).
- **Alternatives rejected**: *list T041 before T040* — correct, and free, since ids are not a
  schedule; not done in a pass where other editors anchor on those lines, and the interface is how
  the envtest drives the reconciler with a fake either way. *One pattern-list file shared by the
  script, the Job and `redaction.py`* — it would need a path the Job can mount before any tier
  image exists and a loader on each side; a shared fixture proves the same equality with nothing
  new to ship. *Move T074 ahead of T072* — the Job still could not run the tier's Python. *A new
  task for the credential-literal fixture* — it is one planted file in the fixture tree T025
  already owns.
- **Not assumed**: nothing is claimed about what the FR-079 pattern set matches beyond what FR-079
  and T168's fixture state; a credential carried in a query string is T072's to redact and is not
  asserted equal across the two implementations by any fixture today.
- **Consequences**: tasks T025, T040, T041, T072, T074, T087, T175 and §Phase Dependencies; plan's
  `make`-target table (`verify-boundaries` row). The `[P]` count stays 84 and the per-phase task
  counts are unchanged. Finding 1 of the same review — the leftover scan's fourth fixture and
  T166's label — is not closed here: it belongs to the closures on the lab's lifecycle and the
  verification tooling (`AD-64`).

### Eighth pass — 2026-09-21

The eighth analysis (2026-09-21) was run **bounded**, under the exit rule the seventh pass set: the
deterministic gate, plus four read-only slices briefed for critical and high findings only, each claim
re-read against the text before it counted. The gate was green; the constitution slice and the
specification's own slice found nothing above medium. Three high findings stood — two in the design of
the generated `Config`, one in the task order — and are closed by `AD-68`…`AD-70`. `AD-68` is an
**operator decision** (option (a) of three put to the operator); `AD-69` and `AD-70` are closures.
At the operator's request the pass's medium findings were then closed as well, in `AD-71`; one of
its points is a recorded, reversible choice. Its low findings are closed in `AD-72`. `AD-73` records the operator's ratification of the five choices the
passes had made on their own recommendation.

### AD-68: A leaf two services would share belongs to the fabric's priority-10 `Config`; a service `Config` writes only beneath list entries its own service keys *(FR-015, FR-034, FR-035; operator decision)*

- **Context**: FR-015, Rule 4 of `contracts/reconciliation.md` and `contracts/crd-api.md` refuse at
  validation two `Config`s that "could touch the same device leaf" at one priority, and every service
  `Config` is priority `20`. But the render had every tagged service write its port's
  `/interface[name]/admin-state` and `/interface[name]/vlan-tagging` (`contracts/crd-api.md` exemplar;
  data-model §13), every gateway service write `/interface[name=irb0]/admin-state`, and both a service
  and a standalone `acl` write `/acl/interface[interface-id]/interface-ref/*`. The lab has one access
  port per leaf and the walkthrough puts two services on it: built as written, T054's refusal refuses
  the platform's own examples, or "could touch the same leaf" has no definition to build against.
- **Decision** (operator, option (a)):
  1. **Port-level leaves of an access port are the `Fabric`'s.** The priority-10 `Config` of each leaf
     renders, for every port in `spec.inventory[].accessPorts`: `/interface[name=<port>]/admin-state`
     (`enable`, or `disable` while `spec.maintenance[]` names the port) and
     `/interface[name=<port>]/vlan-tagging` from the port's **declared** tagging mode; and, once per
     leaf, `/interface[name=irb0]/admin-state enable`. They exist before any service does. **An
     access port's oper-state is not a `Fabric` invariant**: whether a host is attached is no part of
     the fabric design, so the `Fabric`'s read-back covers these leaves on the written side only,
     and the applied side stays where it was — the subinterface oper-state of the attaching service.
  2. **The tagging mode is declared, not derived** *(the shape of the declaration — `untaggedAccessPorts` — ratified by the operator, `AD-73`)*. `spec.inventory[].untaggedAccessPorts` is an
     optional subset of that node's `accessPorts`, empty by default: a port listed there renders
     `vlan-tagging false` and carries exactly one untagged attachment (subinterface `0`, no `vlan`
     container — the mode research used, `evidence/01-lab-platform.md` §3.3; a routed untagged
     subinterface has no other legal shape, `evidence/02-evpn-constructs.md` §9); every other access
     port renders `vlan-tagging true` and carries tagged attachments only. **Attachment resolvability
     is extended to the mode**: an attachment must name an access port *in the mode the inventory
     declares for it*, and the refusal lists the ports declared in the mode that was asked for
     (CR-003) — at admission, at the mapper and at the deployer's pre-flight alike. FR-034's
     cross-object rule (`AD-20`) stands as the backstop it was: two admitted attachments can no longer
     differ in mode on one port, since each matches one declaration, except across a change of the
     declaration — and **a `Fabric` whose declaration changes the mode of a port any `Network` still
     attaches to is `Accepted=False/InvalidIntent`** naming the port and the services holding it, its
     last rendered `Config` left as it was.
  3. **A service `Config` writes no leaf above its own list entries.** On an interface its first
     written leaf is under `subinterface[index=<idx>]`; it never writes `admin-state`, `vlan-tagging`
     or `mtu` of a port, nor `irb0`'s own `admin-state`.
  4. **The binding entry's `interface-ref` belongs to the `Config` that renders the subinterface.**
     That `Config` always renders `/acl/interface[interface-id=<port>.<idx>]/interface-ref/{interface,subinterface}`
     with the subinterface, whether or not the service binds a filter of its own; a standalone `acl`'s
     `Config` writes only its `input|output/acl-filter[name][type]` entry beneath it. The leafref proof
     `contracts/acl-render-contract.md` §2 asks for is unchanged — it is made once, by the owner.
  5. **The rule is defined, and stays as a backstop.** A *leaf* in FR-015's rule is a **non-key** leaf:
     a list key is part of a path, and two `Config`s writing beneath one list entry share a path, not
     a leaf. At validation the provider compares the non-key leaf paths of the `Config` it rendered
     with those of every other `Config` of the same priority on that node; an overlap is
     `Applied=False/OwnershipConflict` naming the path and the other `Config`, and nothing is written.
     By points 1–4 no two well-formed services overlap, and the `Fabric` is the only priority-10
     source on a node — so the check fires only on a defect, which is what a backstop is for.
- **Rationale**: it keeps the rule exactly as FR-015 states it and adds no dependency on how the
  device-configuration layer treats two equal-priority intents that agree on a value, which nothing
  in research observed. It also removes the one cross-priority contention the design had: with
  `maintenance[]` able to name an access port, a priority-10 `disable` and a priority-20 `enable` met
  on one leaf, and an `OVERRULED` report there would have been terminal for every service on the port
  (`AD-66`). Only the `Fabric` writes that leaf now.
- **Alternatives rejected**: *(b) exempt leaves on which both `Config`s agree* — it rests on
  unobserved layer behaviour at equal priority and would need a gate item before anything could rely
  on it. *(c) a distinct priority per service* — an unbounded band with an ordering nobody chose.
  *Deriving a port's mode from the services on it* — the fabric render would depend on `Network`s,
  the `Fabric` would no longer converge before any service exists (`AD-23`), and the first tagged
  service on a port would need the fabric transaction to land before its own.
- **Not assumed**: that the pinned release accepts a `/acl/interface[…]` entry carrying an
  `interface-ref` and no filter. Observed by gate item **G9** before anything relies on it (Open item
  19); if it is refused, the stop is the gate's and the fallback is a recorded change, never a silent
  return to a shared leaf.
- **Consequences**: FR-015, FR-034 and the tagging-mode edge case (amendment notes); data-model §3a
  (`untaggedAccessPorts`), §10, §13 (path ownership), §20; `contracts/crd-api.md` (priority rule,
  resolvability row, tagging-mode row, exemplar), `contracts/reconciliation.md` Rule 4,
  `contracts/acl-render-contract.md` §1–§2, `contracts/network-spec.md`; plan's constraint paragraph
  and G9; tasks T013, T014, T027, T028, T039, T040, T043, T053, T054, T056, T057, T059, T061, T098,
  T107, T112. Open item 19 added.
  No `FR`, `NFR`, `SC`, `R`, `G` or `T` identifier added or renumbered.

### AD-69: Every generated `Config` lives in `agentic-netops-system`; a `Network`'s `Config` carries no owner reference *(FR-016, FR-103)*

- **Context**: `contracts/crd-api.md` asked for "an owner reference to the source object when
  namespaces permit" and then showed the opposite: a service `Config` in `agentic-netops-system` with
  an `ownerReferences` entry naming a `Network` in `agentic-netops-intent`. Kubernetes reads a
  cross-namespace owner as an **absent** one and collects the dependent — `AD-32` records exactly this
  hazard for claims — and with `deletionPolicy: delete` a collected `Config` withdraws the service
  from the device. No other artifact said which namespace a `Config` lives in, and FR-016 required
  owner references without qualification.
- **Decision**: every `Config` the provider generates is created in **`agentic-netops-system`**, the
  provider's own namespace. A `Fabric` lives there too, so **a fabric `Config` carries a controller
  owner reference to its `Fabric`**. A `Network` lives in `agentic-netops-intent` or
  `agentic-netops-services`, never there, so **a service `Config` carries no `ownerReferences` at
  all**: it is tied to its source by the `agentic-netops.io/source-uid` annotation and the labels
  `agentic-netops.io/network-namespace` and `agentic-netops.io/network-name` — the pair the claims
  already carry (`AD-09`) — and it is removed by the `Network`'s finalizer, which is how FR-103
  already removes it and read its removal back. Because the two service namespaces share one `Config`
  namespace, two `Network`s of one name would derive one `Config` name: before writing, the provider
  reads a `Config` of that name and, where its `source-uid` is another object's, writes nothing and
  reports `Applied=False/OwnershipConflict` naming the holder. FR-016 reads "owner references where
  owner and dependent share a namespace".
- **Rationale**: finalizer-driven removal is the only removal that can block on an unreachable target
  and hold the allocations (FR-103); garbage collection can do neither, so the owner reference was
  never what removed a service `Config` — it could only ever remove one wrongly.
- **Alternatives rejected**: *`Config`s in the `Network`'s namespace* — it puts device configuration
  inside the tier's namespace, where the tier's identities hold rights, and would widen FR-075's
  denial surface. *A cluster-scoped owner* — none exists for a service.
- **Consequences**: FR-016 (amendment note); `contracts/crd-api.md` (the rule and the exemplar);
  data-model §13; tasks T028, T040, T054, T059. No identifier added.

### AD-70: The fabric golden files are frozen after the first gate **run**, not after the gate is written *(FR-020, R-36, AD-31)*

- **Context**: T047 freezes `tests/golden/fabric/*.json` against `tests/gate/observed/serialization.json`,
  which only a live gate run writes. It sat before T048 (`scripts/provision.sh`, the first thing that
  can run the gate) and T052 (the first live run), and its note "(depends on T043)" named the gate's
  implementation. In order, the task could not be done without inventing the file it reads — which
  plan.md P0, R-36 and the task list's own hard rules forbid.
- **Decision**: T047 moves to directly after T052, keeps its id, and depends on **T052's gate run**.
  Between T027 and T047 the fabric goldens stay marked provisional, as T027 already says, and
  `make verify-render-schema` — declared in T006 — is wired by T047 where it now stands. The later
  freezes (T063, T113, T118) already follow a standing gated lab and do not move.
- **Consequences**: tasks T047 and §Phase Dependencies. The `[P]` count and the per-phase counts are
  unchanged.

### AD-71: Eighth-pass closures — the medium findings *(NFR-003, SC-004, FR-020, NFR-006, SC-043, FR-103, SC-008)*

The eighth pass left seven findings at medium, each a place where a task or a rule stopped one
sentence short of what an implementer needs. They are closed here rather than carried. One needed a
choice — point 6 — made on the analysis's recommendation, reversible, with the alternative recorded.
**No `FR`, `NFR`, `SC`, `R`, `G` or `T` identifier was added or renumbered**; Open item 20 was added.

- **Decision**:
  1. **A locked first-party image whose Dockerfile is not in the tree yet is *pending*, and pending is
     not a pass for anything that uses it.** T008 authors all seven `firstPartyImages` entries while
     six Dockerfiles arrive with T086 and T097, and CI runs `make verify-pins` from the first story.
     For an entry whose `dockerfile` path is absent, `verify-pins` still resolves every `from[]`
     digest and checks every dependency lock that exists, prints the entry as
     `pending: <name> — Dockerfile absent`, and **fails if any manifest, script or Makefile target in
     the tree references that image**. The moment the Dockerfile exists the full check applies. A
     Dockerfile under `docker/` with no lock entry fails. The acceptance run admits no pending entry.
     Nothing unpinned can therefore be built or deployed, which is what NFR-003 protects; no
     exception field is added (`AD-12`).
  2. **`make verify-evidence` owns the SC-004 recording rule.** T052 attributed it to
     `make verify-evidence` and plan.md to "the acceptance script", and neither T012 nor T151 built
     it. It is `scripts/lib/verify_evidence.sh`'s (T012): an `EVIDENCE_DIR` that records SC-004 fails
     unless it holds the session half, the route half and the route half's negative control, each
     with its NFR-013 fields. The acceptance script (T151) ends by running `make verify-evidence`
     over its own run, so both sentences are true of one implementation.
  3. **The offline validator has a name and a pin.** `make verify-render-schema` runs
     **`sdc-lite config validate`** (`sdcio/sdc-lite`; `evidence/05-kubenet-sdc-kuid.md` §3.4) against
     the `Schema` of compatibility-set part 4. The lock file pins it like every other binary — release
     and digest or commit **resolved by T010's tooling, never typed**; research recorded no release of
     it, so none is stated here. It is not host tooling (§28): it runs in CI.
  4. **The purge scales down what exists.** Until T126 adds `deploy/agents/ui.yaml` the `ui`
     Deployment does not exist, while T088's quiesce and T174's test name it. The quiesce scales each
     of `supervisor`, `ui` and `deployer` **that is present**; an absent one is already at zero and is
     reported by name, never an error and never created.
  5. **`delete_unreachable.sh` is built with both of its modes.** SC-043's force-release procedure —
     first an empty reason, asserting by claim-selector diff that nothing is released and the object
     is still held, then a stated one, asserting the Event and the durable finding — was described
     only in the run task T149. T064 builds it, behind the mode switch T149 uses.
  6. **A finding whose node has left the inventory stays on record and stops counting** *(choice; ratified by the operator, `AD-73`)*.
     A finding clears only when the `Fabric`'s re-verification reads its node clean, and a
     force-release is honoured after the node has left `spec.nodes` — so that finding could never
     clear and `Degraded=True/StaleConfigurationPossible` would stand for ever on a device that is no
     longer part of the fabric. Such a finding **stays in `status.findings[]`**, is never removed
     without a clean read-back, and **does not count toward `Degraded`** while its node is absent
     from `spec.nodes`; no `Network` can attach to that node, so the refused-render consequence has
     nothing to refuse. If the node returns to the inventory the finding counts again from the first
     pass that runs, and clears as any other does.
  7. **How fast the layer notices a lost target is observed, not assumed.** SC-008's 30 s bound on
     the first `Ready=Unknown` rests on how soon the pinned device-configuration layer marks a
     `Target` not Ready after a management cut; `AD-62` records that detection is the layer's, and
     nothing observed its latency. `target_failure.sh` (T064) records the measured time from the cut
     to the `Target`'s transition and to the first `Unknown` in its evidence. A latency beyond the
     bound **fails SC-008 naming the layer's measured latency** — never waived, and the bound is
     never widened silently: widening it is a recorded change to SC-008 (Open item 20).
- **Rationale**: points 1–5 state what was already meant; each removes a place where two implementers
  would have built two things, or where a task in order could not be finished. Point 6 keeps FR-103's
  rule — a finding is cleared by a clean read-back and by nothing else — while keeping `Degraded`
  truthful about the fabric that exists. Point 7 keeps Principle VI: the gate is not waived, the
  dependency is named.
- **Alternatives rejected**: *T008 authoring only the entries whose Dockerfile exists* — T086 is a
  `[P]` task and would then have to edit the lock file, a shared file, beside its siblings. *An
  acknowledgement annotation that clears a finding* — a second way to clear what FR-103 says only a
  read-back clears. *Leaving the finding counted* — a permanent `Degraded` teaches operators to
  ignore it. *A provider-side probe of the target to beat the layer's detection* — a second device
  client in the provider, beside the one southbound FR-014 specifies.
- **Consequences**: data-model §3a (`status.findings[]` rules), §26; plan's SC-004 row; tasks T008,
  T009, T010, T012, T028, T040, T047, T064, T088, T151, T174. Open item 20 added.

### AD-72: Eighth-pass closures — the low findings *(SC-012, NFR-006, FR-043)*

- **Decision**: nothing here decides anything; each is a sentence made to say what the design
  already meant. **No identifier was added or renumbered.**
  1. **Six requirements were cited only through a range** — FR-038, FR-051, FR-052, FR-071, FR-073,
     FR-081 — while the tasks that build them cited nothing. The four ranges are written out as ids
     (T078, T085, T105, T125), and the builders cite what they build: T083 (FR-071, FR-073), T084
     (FR-071, FR-074), T101 (FR-051), T110 (FR-038), T124 (FR-052, FR-081).
  2. **SC-012 is measured on a Ready fabric.** Its "none reach a state where objects exist but
     nothing converges" read as forbidding the outcome the degraded-fabric edge case prescribes. On
     a degraded fabric a confirmed request ends as that edge case says, truthfully, and that is not
     a breach of the criterion.
  3. **User Story 7 scenario 4b is written in NFR-006's order**: scale-down, list, export, delete,
     bounded wait. The clauses had the export before the list.
  4. **A purge stopped by a held deletion names what holds it.** NFR-006 and its edge case said "the
     service and the target"; a deletion held by `HolderPresent` has a holder, not a target. Both
     now say what `FR-069` and `AD-63` already say of a removal asked of the tier; T088 names both.
- **Consequences**: SC-012, User Story 7 scenario 4b, NFR-006 and one edge case; tasks T078, T083,
  T084, T085, T088, T101, T105, T110, T124, T125.

### AD-73: The operator ratifies the five choices the analysis passes made on their own recommendation *(operator decision)*

- **Context**: five things in this record were decided by the analysis and not by the operator, each
  marked reversible with its alternative recorded: `AD-44` (finalization resolves adoption before it
  releases), `AD-45` (the analytics store and the tier collector are authored and installed in User
  Story 7, before the first test that reads them), `AD-63` (a removal asked of the tier ends when
  the object is gone, or reports it in progress naming what the deletion awaits), the declaration
  `Fabric.spec.inventory[].untaggedAccessPorts` inside `AD-68` (a port's tagging mode is declared in
  the fabric design, not derived from the services on it), and point 6 of `AD-71` (a force-release
  finding whose node has left the fabric design stays on record and does not count toward
  `Degraded` until the node returns).
- **Decision** (operator, 2026-09-21): **all five are ratified as written, with no amendment.** They
  are operator decisions from here on and are not reopened by a later pass; the alternatives stay in
  the record as what was rejected. No artifact changes meaning: the text each decision produced
  stands.
- **Consequences**: the five entries carry a ratification note; plan.md's list of operator decisions
  and the traceability rows name them. With this, **no unratified choice remains in this record.** No
  identifier added or renumbered.

### AD-74: G11 failed on the pinned allocation authority; the first-party substitute is adopted *(operator decision, made by delegation)*

- **Context**: the first implementation run (2026-09-21) reached `AppsReady`, installed cert-manager
  and kuid-server `v0.0.13`, and failed gate item G11 — the scratch indices of the claim round-trip
  could not be created — so provisioning stopped non-zero naming G11 with nothing above the authority
  installed, which is FR-104 and SC-047 working as written. The run's evidence is
  `.evidence/agentic-netops_agentic-netops-fabric/20260921T042659Z/g11-observations.json`. The
  implementing run attributed the failure to three defects of kuid `v0.0.13` itself (index admission
  validating the zero receiver, a `VLANIndex` failing on its own reserved-range entries, server-side
  apply answering 503); that analysis is the run's and was not re-verified for this entry. Open
  item 10 and R-31 named exactly this branch.
- **Decision** (2026-09-21): **the first-party allocation authority of CD-03 is adopted**, recorded
  in `docs/decisions/allocator-substitution.md` with the failed evidence cited by path and SHA-256,
  and selected in `versions.lock.yaml` (`allocationAuthority.kind: first-party`). The operator,
  shown both ways forward, delegated the choice — "do whatever do you recommend in my behalf" — and
  it was made under that delegation; it is recorded as made that way and not as a choice the operator
  typed.
- **Rationale**: FR-098 admits into an upstream API group only that project's own pinned,
  **unmodified** artefact, and FR-104 names the first-party authority as the one permitted
  substitution; a re-pinned, patched kuid is neither, and would need both requirements amended.
  Upstream is dormant, and no requirement here assumes an upstream fix will arrive. The contract was
  fixed before the failure (data-model.md §23, contracts/kuid-claim-profiles.md §7), the kinds exist
  (T015) and everything above `pkg/kuid` is unchanged by construction (T019).
- **Alternatives rejected**: *a patched fork of kuid re-pinned by commit* — a modified artefact in
  `*.be.kuid.dev` (FR-098), a fork of a dormant project to carry, and a second pin exception NFR-003
  does not admit; *waiting for upstream* — no release since 2024-12-27; *a local lease or pool in the
  tier* — forbidden by FR-062.
- **Consequences**: tasks T176–T183 (User Story 1, before T048) build, test, install and qualify the
  substitute; G11 is run against it with the same six observations and negative controls, and a
  failure there stops provisioning the same way — there is no third authority; kuid is not installed,
  the two never coexist (`make verify-compat`); the substitute is warned by name on every
  provisioning run. Open item 10 is closed by observation: kuid `v0.0.13` does not hold G11 on the
  pinned Kind. No requirement, success criterion, risk or gate item is added or renumbered. The return
  to kuid stays open, recorded like the adoption, on a lab holding no bound claim.

### AD-75: The schema-deviation repository is served to the device-configuration layer from an in-cluster mirror, under a tag *(operator decision, made by delegation)*

- **Context**: `TargetsReady` failed live: `config-server v0.0.58` treats every non-`branch` reference kind, `hash` included, as a tag, and `sdcio/srlinux-yang-patch` carries no tag — the pinned commit `7410316d…` is reachable only as a branch head. Research (`evidence/05`) had read `kind: hash` off the CRD enum; the run falsified it. Branch references are forbidden wherever a reference can appear (NFR-003) and the provider refuses one (`Rendered=False/SchemaMismatch`, observed).
- **Decision** (2026-09-21): the pinned commit is served from an **in-cluster git mirror** — a platform workload in `sdc-system`, built at provisioning from the upstream repository **at exactly the locked commit, asserted before it is served**, exposing that commit under a tag named after it; the `Schema` CR references the mirror by that tag. The lock file still records the upstream repository and commit; the mirror is a transport for it and changes no pin. As with `AD-74`, the operator delegated the choice ("do whatever do you recommend in my behalf you are in Yolo mode", 2026-09-21); it was made under that delegation and is recorded as made that way.
- **Alternatives rejected**: *`kind: branch` with a provisioning-time head assertion* — an exception to the branch rule that breaks the lab the day upstream moves the branch; *a patched config-server* — a modified upstream artefact (FR-098).
- **Consequences**: T184. The mirror's image is a first-party image pinned like every other (data-model.md §26). No pin exception is added.

### AD-76: Configuration-integrity leaves are read from the configuration datastore *(operator decision, made by delegation)*

- **Context**: on SR Linux 25.7.1 a state read of the default network-instance's BGP returns operational leaves only; `inter-as-vpn` and `route-reflector client` are **not** mirrored into state, so the read AD-31 described cannot pass as written (G4 part B, T041, T051 (c)).
- **Decision** (2026-09-21): both leaves are read with the configuration datastore (`--type config` in the gate; the running datastore through the device-configuration layer in T041) and the check **keeps its name and its class**: a configuration-integrity check, never applied-side behavioural evidence (AD-31 unchanged in meaning). G4 part B **records** "config-only leaf not mirrored in state" as an observation and no longer treats the mirror as a pass criterion. As with `AD-74`, the operator delegated the choice ("do whatever do you recommend in my behalf you are in Yolo mode", 2026-09-21); it was made under that delegation and is recorded as made that way.
- **Alternatives rejected**: *dropping the check* — it is what catches a lost reflector setting.
- **Consequences**: T187; AD-31's wording about the state datastore mirroring these leaves is superseded.

### AD-77: SC-004's negative control is the fault the gate observes to stop reflection; the `Fabric` declares it *(operator decision, made by delegation)*

- **Context**: with `inter-as-vpn` removed from both spines the G8 negative controls still **passed** on this topology: routes were still reflected, so that removal is not a control, and AD-43's declarative fault (`overlay.interASVPN: false ⇒ RoutesMissing`) would never fire.
- **Decision** (2026-09-21): the control is whichever declared change G8 **observes** to stop reflection between the leaves with every session still established — the candidate is removing `route-reflector client` from the spines' overlay group — and a candidate that does not stop it is not admitted. The `Fabric` gains `spec.overlay.reflectorClients` (boolean, default `true`), rendered on every reflecting spine as stated; `false` is the declarative fault T064, T134 and T167's consumers use, the fabric then reporting `Ready=False/NotConverged` naming each spine and the setting, restored from an exit trap exactly as AD-43 required. `overlay.interASVPN` stays a rendered setting under the configuration-integrity check (declared equals read back) and **stops being** the negative control or a convergence rule of its own. AD-43's mechanism — declarative, one southbound, no device-side edit — is unchanged; its field is replaced. If no declarable change is observed to stop reflection, that is a stop: SC-004 has no negative control and nothing is admitted without one (NFR-013). As with `AD-74`, the operator delegated the choice ("do whatever do you recommend in my behalf you are in Yolo mode", 2026-09-21); it was made under that delegation and is recorded as made that way.
- **Alternatives rejected**: *keeping `interASVPN` as the control* — a control shown not to fail is a defect (NFR-013); *a device-side edit* — forbidden by AD-43.
- **Consequences**: T186, T187; R-37's assumption that a non-VTEP reflecting spine needs `inter-as-vpn` is recorded as not reproduced on 25.7.1.

### AD-78: G6's "refused one byte above" applies to the platform's port maximum; the tenant boundary is proven on the data plane *(operator decision, made by delegation)*

- **Context**: G6 reproduced all five numbers of CR-009 live — 9412, 9398, 9348, and the 9320 / 9300 probes passing with one byte more failing — but the device **accepts** an IRB `ip-mtu` of 9349 and keeps the IRB up: the tenant value is arithmetic, not a commit-time limit.
- **Decision** (2026-09-21): the commit-time refusal is asserted for the **port MTU** (the platform maximum) only. For the tenant MTU the assertion is the data-plane boundary, which passed, and G6 **records** that 9349 is accepted at commit. No number of CR-009 changes and none failed to reproduce, so this is a corrected criterion, not a waived item (CR-007). As with `AD-74`, the operator delegated the choice ("do whatever do you recommend in my behalf you are in Yolo mode", 2026-09-21); it was made under that delegation and is recorded as made that way.
- **Alternatives rejected**: *failing G6* — no number it re-observes failed; *dropping the tenant check* — the probe is kept.
- **Consequences**: T187.

### AD-79: The applied-side binding check reads the keyed binding; a shared filter's per-subinterface entry list is an observation *(operator decision, made by delegation)*

- **Context**: for an ingress filter that is not subinterface-specific the device does not populate the per-subinterface entry list research item A4 read; the filter is programmed (TCAM entries present) and its binding is present in state.
- **Decision** (2026-09-21): A4 is the **keyed binding** — this filter's name and type under this subinterface's `input` or `output` in state (contracts/acl-render-contract.md §4.4) — and entries stay verified per filter by A1–A3, keyed by filter name, type and sequence-id. The empty per-subinterface list is recorded by G9. No render changes; nothing becomes a device-wide count (FR-042, FR-100). As with `AD-74`, the operator delegated the choice ("do whatever do you recommend in my behalf you are in Yolo mode", 2026-09-21); it was made under that delegation and is recorded as made that way.
- **Alternatives rejected**: *rendering every ingress filter subinterface-specific* — a TCAM cost per subinterface bought only to satisfy a read.
- **Consequences**: T187.

### AD-80: The data server is re-pinned to a release that reverts drift, qualified against the pinned config server *(operator decision, made by delegation)*

- **Context**: `data-server v0.0.66` was observed live to stop reporting deviations for a target until restarted, and to have **no revert-after-sync**: with `revertive: true` a managed-path deviation was visible and not restored in 180 s. FR-015 and Principle I ("detected drift MUST be repaired") cannot hold on it. Releases `v0.0.69`–`v0.0.72` carry both fixes; their interoperation with `config-server v0.0.58` is unverified.
- **Decision** (2026-09-21): part 5 of the compatibility set is re-pinned to the **newest data-server release that fixes both and qualifies live** with `config-server v0.0.58` — `TargetsReady`, G10 and G13 passing on it, tried from `v0.0.72` downwards — its digest resolved by the pin tooling, never typed. If none qualifies, that is a stop: the revertive policy is unqualified and no drift-dependent result is admitted. As with `AD-74`, the operator delegated the choice ("do whatever do you recommend in my behalf you are in Yolo mode", 2026-09-21); it was made under that delegation and is recorded as made that way.
- **Alternatives rejected**: *keeping `v0.0.66` and reporting SC-007 as not demonstrated* — that accepts a platform that does not repair drift.
- **Consequences**: T185; every artefact that types `v0.0.66` is reconciled by T188. Open item 22.

### AD-81: Golden files freeze the identityref form G12 observed; the offline validator's defect is handled on its input only *(operator decision, made by delegation)*

- **Context**: G12 observed module-prefixed identityrefs (RFC 7951), which the live device-configuration layer accepts; the pinned offline validator `sdc-lite v0.4.0` refuses them inside a `must` that compares the bare name, and accepts the bare form, which is not what G12 observed.
- **Decision** (2026-09-21): T047 and T063 freeze the **observed, prefixed form**, as the specification has always tied them to G12 (R-36). `make verify-render-schema` first tries the newest `sdc-lite` release, pinned by tooling; if it still refuses the form, the script validates a **copy** whose identityref prefixes are normalised, the golden itself untouched, with the upstream defect named in the qualification record and a negative control — a golden carrying a wrong identity still fails. The second schema gate, the layer's own validation before any `Set`, always sees the true form. As with `AD-74`, the operator delegated the choice ("do whatever do you recommend in my behalf you are in Yolo mode", 2026-09-21); it was made under that delegation and is recorded as made that way.
- **Alternatives rejected**: *freezing the bare form* — relies on a leniency the RFC does not grant and differs from what the device returns.
- **Consequences**: T047, T187. Open item 21.

### AD-82: A standing delegation: a live finding that contradicts an assumption is decided by the build, recorded, and never by waiving a gate *(operator decision, made by delegation)*

- **Context**: two runs each spent the rest of their pass budget repeating a stop-and-ask nobody was present to answer.
- **Decision** (2026-09-21): when a live observation contradicts an assumption of these artefacts, the build chooses the option that **keeps the requirement's intent**, records it in `docs/decisions/live-findings.md` with the run's evidence cited by path and SHA-256, and continues. It still **stops** — once, without repeating the pass — where the only ways forward would waive or weaken a gate (CR-007), relax a requirement, add a pin exception NFR-003 does not admit, touch a resource the platform does not own, handle a credential it was not given, or act outward-facing. Every decision made this way is listed for the operator's review in T155's closing record and in `README.md`'s *Known limitations* where it limits anything. As with `AD-74`, the operator delegated the choice ("do whatever do you recommend in my behalf you are in Yolo mode", 2026-09-21); it was made under that delegation and is recorded as made that way.
- **Alternatives rejected**: *stopping on every finding* — the last two runs; *an unbounded delegation* — a gate would then be waivable.
- **Consequences**: tasks.md §Stop-and-ask; T188.

## Open items carried to P0

The research reports flagged these as unknowns and said so. None of them is settled by this
document, none is assumed in any requirement's favour, and each is either a capability-gate item
(RD-12) or a decision the first delivery phase records rather than inherits. They are listed here
so that a later pass can close them against evidence instead of against memory.

**Closing record (T155, CR-007, 2026-09-25).** Each item below carries a T155 line naming the P0, P1
or P3 observation that closes it, with the run-captured record by path and SHA-256. An item that the
evidence cannot close is marked **Still open** and says what is missing. It is never closed from
memory.

- **Closed:** 1–18 — 3, 8 and 17 on 2026-09-28 by the scratch probe `tests/gate/open_items_probe.sh` (FR-108; `vt-scratch-` names, removal read back, `make verify-evidence` PASS over its 59 records) — and 18 among them (G13's, AD-48, AD-55); also 19, 20, 22.
- **Still open:** 21 (outside 1–18; closes with an `sdc-lite` release, not with a lab observation).
- Items 4, 10 and 13 closed **against** the research premise. Their decisions are AD-76/AD-77, AD-74 and R-14's fallback.

The base gate record for the P0 lines is `.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate-record.json`
(`42a8fc89385ce008d9749ce63f176376536246eda9bd2634ef877e4a4d8f301c`), which is the record the live
`fabric-qualification` names. What is left unqualified is recorded in
[`docs/reference/qualification-record.md`](../../docs/reference/qualification-record.md) §What is left unqualified.
Every decision made under AD-82 is listed for review in
[`docs/decisions/ad-82-review.md`](../../docs/decisions/ad-82-review.md).

1. **Identityref JSON serialization.** Whether the device returns a module-qualified or a bare
   value for an identityref such as the network-instance type is not observed. Golden files are
   frozen only **after** a real Get has shown the form (gate item G12).
   [evidence/02-evpn-constructs.md](./evidence/02-evpn-constructs.md) §2.5, §12 item 1;
   [evidence/03-acl.md](./evidence/03-acl.md) §11 item 4. Risk R-36.
   **T155 (2026-09-25).** **Closed by** (P0, G12): a real Get returned **module-qualified** RFC 7951 identityrefs (`srl_nokia-network-instance:mac-vrf`, `srl_nokia-common:evpn`, `srl_nokia-interfaces:bridged`; `identityref_values_module_qualified: true`), and the goldens were frozen in that form (T047, T063, AD-81) — `.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/items/G12.json` (`b2a43fc68cd6abfbeba64d46008d77390f61579226ab7122178fc63c3b6a2d72`), tracked `tests/gate/observed/serialization.json` (`90130e937279788e5d6c976d450fe20c17b7cac283cffbc2d4234c95eff90b25`), in the published gate record `.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate-record.json` (`42a8fc89385ce008d9749ce63f176376536246eda9bd2634ef877e4a4d8f301c`, equal to the live `fabric-qualification` annotation `gate-record-sha256`). The offline validator's refusal of that form is item 21.
2. **Which `if-feature`s the emulated leaf type advertises for egress access lists.** The feature
   names and the model constraints are read from the pinned YANG; the per-platform feature file
   lives inside the image and was not read, so whether the egress restriction bites on this type is
   unknown. It is a gate line item (G9), and until it passes, egress is refused by name (FR-097).
   [evidence/03-acl.md](./evidence/03-acl.md) §6, §11 item 2.
   **T155 (2026-09-25).** **Closed by** (P0, G3 + G9; P3, T114): every leaf and spine advertises `acl-if-output-shared-tcam-entries` and `acl-subinterface-entry-statistics` (`.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/items/G3.json`, `e69a96587aca6c49e7a738fd6cd6b314672058db7f00d84319db9781a576627a`), and G9's `property:egress-acl` passed **device-direct** — an output-only binding programmed in TCAM on output only (`.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/items/G9.json`, `325093e3ddae20d4032ff9b3288916a01041c1793b8d170f872520697a7a04b1`). The egress restriction does not bite on the device. It bites in the pinned layer: `data-server v0.0.72` refuses the egress binding's `must` although the render satisfies it (`.evidence/agentic-netops_agentic-netops-fabric/20260924T150500Z-p8/AP.ready.acl-probe-egress.stdout`, `887bd93d9c31de27aca263a05c21be0b49340a5f6dd61ea95c95bf60a91bf622`), so `acl.egress` is published **unqualified** and egress is refused by name (FR-097; `docs/decisions/live-findings.md` `2026-09-24-acl-egress-unqualified`; `docs/reference/qualification-record.md` §What is left unqualified).
3. **Whether `interface-ref` is auto-derived from the `interface-id` key.** The vendor's own lab
   omits it; the vendor's guide sets it. The decision to always write it is safe either way, but
   the underlying behaviour is untested. [evidence/03-acl.md](./evidence/03-acl.md) §5, §11 item 1.
   **T155 (2026-09-25; superseded by the 2026-09-28 line below).** **Still open** — no observation. No run wrote an `/acl/interface` entry **without** `interface-ref`: every render and every gate write sets it (AD-68), and G9 observed only the opposite case (item 19). Whether the device derives it from the `interface-id` key therefore remains untested. Nothing depends on it, because the platform always writes it. What would close it is a G9 scratch binding written without `interface-ref`, whose read-back from running is recorded.
   **T155 (2026-09-28).** **Closed by** (P3 scratch probe, leaf01, 25.7.1): a binding `/acl/interface[interface-id=ethernet-1/10.3994]` carrying only `input acl-filter vt-scratch-oi3` and **no** `interface-ref` was **accepted at commit** (`.evidence/agentic-netops_agentic-netops-fabric/20260929T140000Z-p15-t155-probe/OI.i3.commit.json` `3cd192d1cdc550b8608f074ff997a04c86fa7c0266a5efd4ae246e3014ed6463`); read back from running it carries **no** `interface-ref` (`OI.i3.cfg.json` `d8062d82456caadb6806bc118ad97650602a0c3a68fbc737278e52d0f47a2c40`), and the state datastore holds **nothing** for that binding (`OI.i3.state.json` `cf16edc3736417735ebbe5e44c558365211fd258dfad58511ee01f813a5db7a1`, an answer with no update). **Answer: not derived** — the device does not fill `interface-ref` from the key, and without it the binding has no operational presence. The platform's rule to always write it (FR-037, AD-68) is therefore **required**, not merely safe; nothing changes. Summary: `.evidence/agentic-netops_agentic-netops-fabric/20260929T140000Z-p15-t155-probe/open-items/observations.json` (`488ed42f6a798f410af3f179838d1805e83c3f27a8d50d65da41fa32aebe6b43`).
4. **Whether `inter-as-vpn` is genuinely required on a route-reflecting spine that is not a tunnel
   endpoint.** The leaf and its semantics are verified against the pinned model; that omitting it
   produces "every session established, zero EVPN routes" comes from a vendor engineer's writing
   rather than from release documentation. The **mechanism** is documented: Nokia's VPN Services
   guide states that `inter-as-vpn true` *"allows received EVPN/IP-VPN routes to be retained in the
   BGP RIB and propagated to any eBGP or iBGP peer"*, and the pinned model scopes that to routes
   *"not imported by any network-instance"*, which on a non-VTEP spine is every EVPN route it
   receives; the sibling `keep-all-routes` retains them but cannot propagate them, so it is not a
   substitute. What stays undocumented is the explicit statement that a route-reflecting spine
   requires the setting. It is confirmed empirically at first bring-up —
   including the negative control — and it is part of gate item G8, which also observes that the
   per-neighbour EVPN family `oper-state` is populated on the emulated node type and that the
   per-neighbour EVPN received-route counters read zero before the first spanning service and
   non-zero after it; that a config-only leaf reads back through `--type state` at all is observed
   by **G4**, with its Set and read-back (AD-31, AD-48).
   [evidence/02-evpn-constructs.md](./evidence/02-evpn-constructs.md) §1.1, §12 item 4. Risk R-37.
   **T155 (2026-09-25).** **Closed by** (P0, G4 + G8), **against the premise**: on 25.7.1, with `route-reflector client true`, removing `inter-as-vpn` from every reflecting spine does **not** stop reflection (`interASVPNRemovedReflectionContinues: true`), whereas `route-reflector client false` does, with every session still established (`reflectorClientsFalseStopsReflection: true`) — `.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/items/G8.json` (`1cd5592c24942ddf52d334f664d38ad2b8689b1a5018f0d6b477744d0ee0fc89`), tracked `tests/gate/observed/reflection-control.json` (`8c75ff274c633299f65796090220983d2362d0ba7578fc0fced5cbba2cc639f5`). The per-neighbour EVPN `oper-state` is populated, and the received-route counters read 0 before the first spanning service and non-zero after it (same record). G4 observed that the config-only leaves are **not** mirrored in state (`config_only_leaves_mirrored_in_state: false` for both leaves on both spines, `.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/items/G4.json`, `55d4a2f8c09990dd6fdeecd430bc1069874ccf70f5735c1293fe08521235d51b`). Decided: AD-76 (read from the configuration datastore) and AD-77 (SC-004's control is `Fabric.spec.overlay.reflectorClients: false`; `inter-as-vpn` stays a rendered, configuration-integrity setting).
5. **An IPv6 anycast gateway and an IPv6 Type-5 route, observed end to end.** The model is
   unambiguous and the vendor documents parity, but **no worked example exists anywhere in the
   vendor's published corpus** — every anycast-gateway and every Type-5 example is IPv4-only. This
   is the **first** capability-gate item to run (G8), not the last.
   [evidence/02-evpn-constructs.md](./evidence/02-evpn-constructs.md) §5.4, §12 item 5.
   **T155 (2026-09-25).** **Closed by** (P0, G8): `property:anycast-gateway-ipv6` (client01 reaches `2001:db8:3990::1`), `property:ipv6-type5-received` both ways, `property:ipv6-type5-installed` on both leaves and `property:ipv6-type5-end-to-end` (client01 reaches `2001:db8:ffff::2`) all passed on the pinned image — `.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/items/G8.json` (`1cd5592c24942ddf52d334f664d38ad2b8689b1a5018f0d6b477744d0ee0fc89`). `mac-vrf.anycast-gateway-ipv6` and `ip-vrf.evpn-type5-ipv6` are published `qualified`.
6. **Whether the pinned schema deviation patch weakens validation.** The patch removes `must`
   constraints on exactly the nodes this platform renders — subinterface type, address-family
   administrative state, the vxlan-interface and the EVPN instance id. If the deviated schema no
   longer rejects what the device rejects, the pre-write validation gate is weaker than the device
   and a configuration can pass validation and fail at the device. Gate item G10.
   [evidence/02-evpn-constructs.md](./evidence/02-evpn-constructs.md) §12 item 6;
   [evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md) §3.5. Risk R-32.
   **T155 (2026-09-25).** **Closed by** (P0, G10): the deviated schema refuses r1–r8 and the liveness case, and nothing persists. This held on `data-server v0.0.72` (`.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/items/G10.json`, `788c3c19b7f49e3d1a50d0cbfcfed37d723d8a573a72ad756c2ab950365b277c`) and again after the first-party deviation module was loaded (`.evidence/agentic-netops_agentic-netops-fabric/20260921T142219Z/gate-record.json`, `59e945550f7e57f59ad02649af167970c726e1032d92307d93dbf1c046806bb4`; `docs/decisions/live-findings.md` `2026-09-21-feature-guarded-must`). **Residual, recorded:** on `v0.0.66` the layer's dry-run did not check an enumeration or the union-typed `vlan-id` (`2026-09-21-g10-liveness`). This was not re-observed on `v0.0.72`, and for such a value the device's refusal at commit is the check (R-32).
7. **Per-path on-change support.** No published support matrix exists, and both of the vendor's
   reference labs sample everything. `sample` is the default; a path moves to on-change only after
   an acceptance check subscribes, disturbs the fabric and observes the update (gate item G7).
   [evidence/06-telemetry-visualization.md](./evidence/06-telemetry-visualization.md) §2.4,
   §10 item 1. The same section leaves `updates-only` unverified and therefore unused.
   **T155 (2026-09-25).** **Closed by** (P0, G7): an on-change Subscribe delivered an update after the probed leaf was disturbed, and a sample Subscribe delivered repeated updates of one leaf (`.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/G07.on-change.json`, `cc53f931aabdbf8677585c454c59cfb23254d6af5ec7364f1ed4bb05d07a8e49`; `.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/items/G7.json`, `df9c64b45096eab9e80f50df918fa4e266b31b79ef1ed4e70d7f1dcbb0852c21`). G7 covered on-change on its probe leaf only, so **no** register path was moved to on-change: every subscription in `pkg/register/paths_subscribe.go` stays `sample`. `updates-only` is still unverified and unused.
8. **Which forwarding-table augment a containerized node populates** — the linecard path or the
   control-plane path — which decides where datapath-programming evidence is read from.
   [evidence/02-evpn-constructs.md](./evidence/02-evpn-constructs.md) §7.3, §12 item 2.
   **T155 (2026-09-25; superseded by the 2026-09-28 line below).** **Still open** for the `fib-table` question. Neither `/platform/linecard/forwarding-complex/fib-table` nor `/platform/control/forwarding-plane/fib-table` was read by any gate item or suite, and no read-back depends on either: service programming is read from `not-programmed-reason`, `destination-index` and the route table's `active` (T041, T061). **Partly observed** for access lists: on this containerised node type the linecard forwarding-complex augments **are** populated. G9's A1–A3 read `…/tcam-entries/forwarding-complex[…]` and `/acl/datapath-programming/forwarding-complex[…]/programming-complete` and passed (`.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/items/G9.json`, `325093e3ddae20d4032ff9b3288916a01041c1793b8d170f872520697a7a04b1`). What would close it is one Get of each `fib-table` augment on a node carrying a service, recorded.
   **T155 (2026-09-28).** **Closed by** (P3 scratch probe, leaf01 carrying seven services): **both** augments are populated on this containerised node type — `/platform/linecard/forwarding-complex/fib-table` (next-hop groups with per-next-hop `oper-state`; `.evidence/agentic-netops_agentic-netops-fabric/20260929T140000Z-p15-t155-probe/OI.i8.linecard.json` `c5196eb51000644b7571f5e3ba08554f06403bd4a8c3c260f04452348daa1ad1`) and `/platform/control/forwarding-plane/fib-table` (`programming-progress`; `OI.i8.control.json` `786978638dbab119ded7d06fbebafd4630d8345f0624670faacea2f05e1dd59d`). Datapath-programming evidence may be read from either; the platform's read-backs keep reading `not-programmed-reason`, `destination-index` and the route table's `active`, so no path changes. Summary: `.evidence/agentic-netops_agentic-netops-fabric/20260929T140000Z-p15-t155-probe/open-items/observations.json` (`488ed42f6a798f410af3f179838d1805e83c3f27a8d50d65da41fa32aebe6b43`).
9. **The telemetry path set is re-validated against the pinned YANG release.** The paths were
   generated against a later model tag than the pin; every registered path, its derived metric name
   and its labels are re-checked at P0 before the register is treated as authoritative (FR-017,
   FR-089). [evidence/06-telemetry-visualization.md](./evidence/06-telemetry-visualization.md) §2.1
   and §10; [evidence/README.md](./evidence/README.md).
   **T155 (2026-09-25).** **Closed by** (P3, T128/T134): the subscription register was re-validated offline against an index of the **pinned** `v25.7.1` models, generated by `go run ./hack/yangindex` (`pkg/register/testdata/yang-index-v25.7.1.json`, `b0a4144632658432e9752fe840c42c13d491ab7344d4b32f27e16cdfbfd06bdb`; `CheckIndex` in the register guard). The metric names and label sets came from that index (proof `.specstride/features/004-agentic-netops-composite/gates/proofs/phase12/T128-yangindex.txt`, `7c2c5fd78c2d696b4941f7cb3b0f736ef3fdf135205f5922ce1d22b5a34cd569`). They were then checked live by `make verify-metrics` (T134; `…/proofs/phase12/live-verify-metrics.txt`, `0b4322a55f12a3116c14f81967aa687d8ce14adb979795854996ed2200f7503a`, run dir `.evidence/agentic-netops_agentic-netops-fabric/20260925T002500Z-p12`). G7 recorded the series names that the pinned gNMIc and collector generate (`tests/gate/observed/telemetry-series.json`, `00419204979c76a92af7f9e9d1c4b93ea114cf25cc4df94daac0caa8658a9f33`).
10. **The allocation authority's health on the pinned cluster.** It is dormant upstream, and it
    serves its APIs through an aggregated API server rather than CRDs, so "installed" and "serving"
    are different claims. A claim round-trip reporting an allocated value in status, against a
    healthy aggregated API on the pinned Kind, is gate item G11; the named fallback is decided at
    P0 and never silently. [evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md)
    §4, §7. Risk R-31. If G11 fails, provisioning stops and the branch is CD-03 — never a silent
    substitution.
    **T155 (2026-09-25).** **Closed by** (P0, G11), **as a failure, then a recorded substitution**: G11 **failed** on `kuid-server v0.0.13` on 2026-09-21. The scratch indices could not be created, so no claim bound, and provisioning stopped naming G11 (`.evidence/agentic-netops_agentic-netops-fabric/20260921T042659Z/g11-observations.json`; the copy the lock cites, `docs/decisions/allocator-substitution/g11-observations.json`, `42050ed2b8638f6ccae418cbb24e6bd2d1660e71b881c389291df2729f5dbc45`). The first-party substitute was adopted by operator decision (AD-74, `docs/decisions/allocator-substitution.md`; CD-03, never silently), and G11 **passed** on it (`.evidence/agentic-netops_agentic-netops-fabric/20260921T104117Z/g11-observations.json`, `7eb13f103aa45df02b96aa2cb5ff3c2668553174d989f2a3076d782781808d67`). Every later bring-up repeated the pass, the latest being `.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/items/G11.json` (`175582567511abb4d64b92f1c3688382c71686089334ea6bcc790c34e9f4328f`). See `docs/reference/qualification-record.md` §G11 per allocation authority.
11. **What the device-configuration layer does with a `Config` deleted while its target was
    unreachable, once the target returns.** Not documented upstream and not assumed (CD-02). It is
    observed in P3's delete-while-unreachable test; the force-release finding is correct whichever
    way it turns out. Risk R-39.
    **T155 (2026-09-25).** **Closed by** (P3, `delete_unreachable.sh`). While the target was unreachable, the pinned layer kept the deleting `Config` at `ConfigReady=True` and `Ready=True`, with its `deletionTimestamp` set, and it never reported the device unreachable. Its `Target` also stayed Ready (`.evidence/agentic-netops_agentic-netops-fabric/20260924T063630Z/DU.observe-config.stdout`, `79f7e87fb8e825d4dd8d8dafca8df85fc10e2595dfdae0a809c1d543e5338804`). Once the target returned, the layer **removed its own deleted `Config`** and the content was gone from the device 13 s later (`.evidence/agentic-netops_agentic-netops-fabric/20260924T064106Z/DU.layer-config-gone.stdout`, `a91239997073d97a1b0494a15a7f96db0ae9b45eef99ed2a2f0f83143dbfbb28`). An earlier run edited the device directly while the layer still held the deleting `Config`. That left the layer's tree and the device diverged, and the layer's recovery replay failed. So suites never edit a device under a held `Config`, and the finalizer judges reachability from the data path (`docs/decisions/live-findings.md` `2026-09-24-delete-unreachable`).
12. **`ValidatingAdmissionPolicy` is served at the pinned Kubernetes minor.** It is generally
    available upstream from 1.30; the node image pin is resolved at P0 and the policy that keeps the
    tier from force-releasing (CD-02) is probed there with the other denials. If it were not served,
    the fallback is a validating webhook in the provider — not a relaxed requirement.
    **T155 (2026-09-25).** **Closed by** (P0, T166 `vap_served`): `ValidatingAdmissionPolicy` and its binding are served at `v1` on Kubernetes `v1.32.2`, and a dry-run create is accepted, so the force-release denial uses it (`.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/qualifications/vap_served.json`, `0d1f1a331bba7f2da132803b1bb8f60c66823dfa4ba8a48917b176ba36cf7a47`). The fallback webhook was not needed.
13. **The TLS key names the pinned transport gateway accepts** for a cert-bearing server with
    client-certificate verification. The gateway's configuration schema at the pinned release was
    not read; the manifest is written against what P0 observes, and R-14's fallback applies if
    client-CA verification is not exposed. D-28.
    **T155 (2026-09-25).** **Closed by** (P0, T166 `slim_tls_keys`): the pinned `slim:0.6.1` accepts `cert_file`/`key_file` for the server certificate. Client-certificate verification is **not exposed**: a client without a certificate was accepted and one with a CA-signed certificate was refused. So R-14's fallback applies: server-side TLS, the gateway password and NetworkPolicy (`.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/qualifications/slim_tls_keys.json`, `65ec54c2032d05498667488b37b0aeaed6eb6856355985db6d7c27fd88e69bd9`). Mutual TLS on the transport is therefore not in place, and `docs/reference/qualification-record.md` records that.
14. **The OTLP resource and attribute shape the tier's instrumentation emits** at the pinned SDK
    version. The collector's filter and the tier metric names are built against the observed
    shape, not a guessed one. D-37.
    **T155 (2026-09-25).** **Closed by** (P0, T166 `otlp_shape`): the resource attribute keys, service names, span names and attribute keys that `ioa-observe-sdk 1.0.24` emits were observed through the pinned collector (`.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/qualifications/otlp_shape.json`, `e1df7e4d02387683d707073983f2bc6618179bbd21fc9878b7135d84de248899`). The collector filter and the tier metric names are built against that shape (T135, T136).
15. **How the pinned allocation authority behaves on the six points the claim design rests on.**
    They are the six observations (a)–(f) of `contracts/kuid-claim-profiles.md` §6, which is the
    one list and the one count every other artifact cites (AD-56).
    FR-109 relies on all of them and none is observed; all are part of gate item G11, each with a
    negative control, before the provider's claim path is relied on. Risk R-44; AD-09, AD-32, AD-33,
    AD-47.
    (a) That a claim for a **stated value** binds exactly that value, and (b) that a second claim
    for the same value is refused **naming the holder** — the source returns
    `"route owned by different claim got name …"` from the create path, which is where
    `AllocationConflict` would take its holder from, but it is read and not run. (c) **Which value a
    dynamic claim returns** — whether the authority allocates the lowest free value or an arbitrary
    one cannot be read from source, because the tree it calls lives in an unvendored dependency.
    It decides nothing now that the bands are disjoint (AD-33), and it is recorded rather than
    guessed because it was the unmeasured frequency AD-27 rested on. (d) That **no dynamic claim is
    ever handed a value below the index's `minID`** — the guard is visible
    (`"cannot claim from a reserved range"`) but its tree call is in the same unvendored dependency;
    this is what keeps the allocation band out of the naming band. (e) That a claim's
    **`metadata.labels` are selectable** through the aggregated API — the source filters
    `accessor.GetLabels()` and ignores the authority's own `spec.labels`, so every claim-selector
    diff in this specification depends on where the platform writes its labels (AD-32). (f) That
    **deleting a claim frees its value synchronously**, as the DELETE returns — read from source and
    relied on by the finalizer's release step, which has no grace period to lean on; G11 deletes a
    stated-value claim and requires an immediate second claim for the same value to bind (AD-47).
    One further unknown is recorded without a gate line of its own: `VLANClaimStatus` carries an
    `expiryTime` field and no writer for it was found at `v0.0.13`. If a claim could expire on its
    own it would release an identifier on a timer, which FR-103 forbids outright, so G11 holds a
    claim across a re-verification interval and asserts the field stays empty and the entry stays
    claimed.
    **T155 (2026-09-25).** **Closed by** (P0, G11, on the authority that runs, AD-74): on the first-party substitute (a) a stated-value claim bound exactly 15000, and (b) a second claim was refused with `Conflict`, **naming the holder**. (c) Three dynamic claims on a fresh index returned `1000, 1001, 1002` (lowest free). (d) No dynamic claim went below `minID` (VLAN 1000, VNI 10000). (e) `metadata.labels` were selectable with `-l`, with a negative control on a label held in annotations, and `spec.labels` were not selectable. (f) Deleting a claim freed its value at once: an immediate second claim rebound 15000 with no wait. `expiry` is `null`, because the substitute's claim has no expiry field. Evidence: `.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/items/G11.json` (`175582567511abb4d64b92f1c3688382c71686089334ea6bcc790c34e9f4328f`), first at `…/20260921T104117Z/g11-observations.json` (`7eb13f103aa45df02b96aa2cb5ff3c2668553174d989f2a3076d782781808d67`). On `kuid-server v0.0.13` none of (a)–(f) could be observed (item 10). Its `expiryTime` question therefore stays unanswered, and it no longer applies to the authority that runs.
16. **Which packet-filter front end the pinned cluster node image carries, and where in its packet
    path a pod-sourced packet can be counted before the policy drop and before source translation.**
    SC-028's per-source counter depends on it. Observed by the harness at P1's boundary step, with
    the positive control of AD-19; if no such point exists the fallback is the policy engine's own
    per-pod drop counters, never a count on the management network.
    **T155 (2026-09-25).** **Closed by** (P1, T066/T073 boundary step). The pinned Kind node runs iptables `1.8.9 (legacy)` with 0 iptables-nft rules, plus nftables with kindnet's `inet kindnet-network-policies` chains (prerouting prio −95, postrouting prio 95). The per-source counter is an nftables counter on the **prerouting** hook, ahead of the policy drop and of source translation (`.evidence/agentic-netops_agentic-netops-fabric/20260924T080142Z/boundary/packet-filter-frontend.json`, `fdb3d3c73782702bd368b38fc021704f88bfb3c34cc3928b070e5ca297078e0d`; `…/boundary/counter-install.json`, `5f18b3980f84f7816eb71d4e6dc8eca5649988e2bb44205af6a962041ea667c4`). Its positive control moved (`…/BP.counter.moved.stdout`: `COUNTER all=220 >= 1: moved`, `b909469227de90c05e67853d91f1eb5755559ff7ba8746313f543609598aa930`) after the zero-before-dial negative control. The policy engine's per-pod counters were not needed.
17. **Whether the pinned release accepts an untagged subinterface beside tagged ones on one port.**
    Not observed in research. Until a gate observation says otherwise the mix is refused (FR-034,
    AD-20); an observation that it works relaxes the rule by a recorded change, never silently.
    **T155 (2026-09-25; superseded by the 2026-09-28 line below).** **Still open** — no observation. No gate item, suite or scratch write committed an untagged subinterface beside tagged ones on one port. The mix therefore **stays refused** (FR-034, AD-20), and the `ip-vrf`-without-VLAN case ran on a port declared wholly untagged (T173, `t173-claim-lifecycle-ipvrf-r2`). What would close it is a scratch commit of the mix on a stock port, read back and removed.
    **T155 (2026-09-28).** **Closed by** (P3 scratch probe, leaf01, stock port `ethernet-1/10`): the **device accepts the mix** — `ethernet-1/10.0` untagged beside `ethernet-1/10.3994` single-tagged `3994`, `vlan-tagging true` on the port, committed in one transaction (`.evidence/agentic-netops_agentic-netops-fabric/20260929T140000Z-p15-t155-probe/OI.i17.commit.json` `a41eac91e457027eb27f100f77a60b2e74a257e330ea24b0fb05c9e41cbed53d`) and both read back from running (`OI.i17.cfg.untagged.json` `295988bd424e36b2dcf6b9e0cb961088a465e2a5ed92adf847c6c79bdb420225`, `OI.i17.cfg.tagged.json` `144084fa52ad1f26d5dc836757ed9755d6f6c7d491b43f1e7cc1618f5489a7c3`); both oper-state `down` on the unconnected port (`OI.i17.state.tagged.json` `578e4d68a484293eff0368eac9e9e3bf7d6a9e567c55c50f6b4b4cd6c7f8aeeb`); the scratch removed and read back absent (`OI.gone.port.json` `a5b3237568993342494be5e27c175a8f20b1f2725339d825ae453275d23652e0`). **The refusal of FR-034 / AD-20 is therefore a platform rule, not a device limit**, and it **stays**: this item said an observation that the mix works relaxes the rule only by a recorded change, and no such change is made here — relaxing a requirement is not T155's to do (CR-007). The observation is recorded for the operator in `docs/decisions/ad-82-review.md` as the input such a change would need. Summary: `.evidence/agentic-netops_agentic-netops-fabric/20260929T140000Z-p15-t155-probe/open-items/observations.json` (`488ed42f6a798f410af3f179838d1805e83c3f27a8d50d65da41fa32aebe6b43`).
18. **What a managed-path deviation leaves observable under the revertive policy.** Whether a
    `Deviation` with reason `NOT_APPLIED` is durably visible under `spec.revertive: true` before the
    layer reapplies, which reason strings it carries — the CRD types `reason` as a bare string — and
    how long restoration takes: none is documented upstream, and upstream's own revertive suite
    asserts only that the intent returns. Observed by gate item **G13** on a gate-owned scratch
    `Config` and recorded, not demanded; the drift check of SC-007 asserts what it recorded and
    nothing else, and if neither the deviation nor the restoration is observable SC-007 is reported
    as not demonstrated, never waived.
    [evidence/05-kubenet-sdc-kuid.md](./evidence/05-kubenet-sdc-kuid.md) §3.4;
    [review/2026-09-20/AD-17-drift-policy.md](./review/2026-09-20/AD-17-drift-policy.md). Risk R-48;
    AD-34, AD-48.
    **T155 (2026-09-25).** **Closed by** (P0, G13; P3, T064 `managed_drift.sh`; AD-48, AD-55). On `data-server v0.0.72` under `spec.revertive: true`, drift on a gate-owned path was **restored after 3 s**, and **no** `Deviation` was visible before the restore (the first qualifying run took 5 s). No reason strings were seen, and no `OVERRULED` could be produced: `answer: restored-without-visible-deviation`, `assertable_by_managed_drift: {deviation_not_applied: false, overruled_producible: false, restoration: true}`. Evidence: `.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/items/G13.json` (`f802f9df10f43b8372823430128b1317484f88af0a3c3130b40372562b905bd6`), tracked `tests/gate/observed/deviation.json` (`c3ae0a95d0579061df1a3bf57f1c59c242f5adc515f648773ca4a42172e28ca4`), the first pass on `v0.0.72` `…/20260921T100127Z/gate/items/G13.json` (`200d82e7d6daa979d1dbff33e7541b0ae23e035e0cfa79f48a058befe9022ea2`). On `v0.0.66` a deviation was visible and never restored (AD-80). SC-007's drift check asserts the restoration only, read back from device state (`make test-managed-drift`, run `20260921T160036Z`). The deviation and `OVERRULED` are reported as not demonstrated live, and `OVERRULED` is covered by envtest (`TestNetworkOverruledPathIsTerminal`). They are never waived.
19. **Whether the pinned release accepts an access-list binding entry that carries an
    `interface-ref` and no filter.** `AD-68` has the `Config` that renders a subinterface always
    render `/acl/interface[interface-id=<port>.<idx>]/interface-ref`, so that a standalone `acl`
    binding beneath it shares no leaf with the owner. The model shows no `must` requiring a filter,
    but the entry was never committed bare in research. Observed by gate item **G9**; refused, the
    gate stops and the fallback is a recorded change. AD-68.
    **T155 (2026-09-25).** **Closed by** (P0, G9): a binding entry for `ethernet-1/1.3990` carrying `interface-ref` and no filter was **accepted**, and its `interface-ref` read back from running (`binding-without-filter-accepted`, `binding-without-filter-readback`, observation `binding_without_filter_accepted: true`). Evidence: `.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/items/G9.json` (`325093e3ddae20d4032ff9b3288916a01041c1793b8d170f872520697a7a04b1`). AD-68's render stands.
20. **How soon the pinned device-configuration layer marks a `Target` not Ready after its
    management path is cut.** SC-008's bound on the first `Ready=Unknown` depends on it and nothing
    in research measured it. Measured and recorded by `target_failure.sh` on every run; beyond the
    bound, SC-008 fails naming the measured latency, and widening the bound is a recorded change to
    SC-008, never a relaxed test. AD-62, AD-71.
    **T155 (2026-09-25).** **Closed by** (P3, `target_failure.sh`): the pinned layer did **not** mark `Target leaf02` not Ready at any point during a 315 s link-level cut (`cut_to_target_not_ready_seconds: null`). The provider reported `Ready=Unknown/VerificationFailed` naming leaf02 at **t+25 s**, within SC-008's 30 s bound, from the layer's `Config` status and the collector's data path, not from the `Target` (`.evidence/agentic-netops_agentic-netops-fabric/20260924T044126Z/TF.latencies.stdout`, `24bfc75160af808b1851cf5479375f4540ed49a0b92ca0aeed48d60262ac496e`; `docs/decisions/live-findings.md` `2026-09-24-layer-before-target`, `2026-09-21-mgmt-cut`). SC-008's bound was not widened.

Every lab measurement this record cites was taken in research on a throwaway lab, in several cases
on a later release than the pin. Each is **re-observed at P0** on the pinned image, under the
evidence rules NFR-013 states: captured by the run that claims it, with a negative control showing
the check fails on a stock fabric.
21. **`sdc-lite` refuses RFC 7951 identityrefs inside a `must`** (`AD-81`). Observed on `v0.4.0`; closed when a release validates the goldens unmodified, at which point the input normalisation of `make verify-render-schema` is removed.
    **T155 (2026-09-25).** **Still open.** `versions.lock.yaml` still pins `sdc-lite v0.4.0`, and `make verify-render-schema` still validates a prefix-normalised copy, with the defect named and a wrong-identity negative control (AD-81). No later `sdc-lite` release has been qualified as validating the goldens unmodified. The item closes when one has, and the normalisation is then removed.
22. **`data-server` ≥ `v0.0.69` beside `config-server v0.0.58`** (`AD-80`). Unverified until T185 qualifies it live; decides part 5 of the compatibility set.
    **T155 (2026-09-25).** **Closed by** (P0, T185): `data-server v0.0.72` (`sha256:f294c2b3810da2d92c4cba0affede839743e75d9343e4ccc80b38e39bd95dca0`) beside `config-server v0.0.58` reached `TargetsReady`, and G10 and G13 passed on it (`.evidence/agentic-netops_agentic-netops-fabric/20260921T100102Z/gate/items/G10.json`, `a7c7bd20ffbccf209490aeedd06ac115c51fb962f42b64f3d18ec4a912318a83`; `…/20260921T100127Z/gate/items/G13.json`, `200d82e7d6daa979d1dbff33e7541b0ae23e035e0cfa79f48a058befe9022ea2`). Part 5 is pinned to it (`docs/reference/qualification-record.md` §Data-server re-pin). It also brought a limitation, recorded separately: it refuses the egress binding (`2026-09-24-acl-egress-unqualified`).
