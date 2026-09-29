# Contract: Kubernetes APIs and generated resources

**Feature**: `004-agentic-netops-composite` | **Carries**: FR-006 to FR-010, FR-013, FR-014,
FR-016, FR-017, FR-048, FR-098, FR-100, FR-101; NFR-003, NFR-013

**Applies to**: the first-party fabric API, the upstream allocation and device-configuration
resources, the optional `MigrationPlan`, provider-generated device configuration, status, ownership
and version compatibility.

## API boundary

1. Operators express fabric design through the first-party `Fabric` Kind, and ongoing service
   intent through the first-party `Network` Kind, both in
   `fabric.agentic-netops.io/v1alpha1` with structural schemas.
2. The allocation authority owns identifier and address allocation through its `ipam`, `as`, `vlan`
   and `genid` index, claim and entry APIs, and holds the node, link and endpoint inventory. The
   `Fabric` reconciler claims addresses and AS numbers; the intent tier's allocator claims VLANs and
   VNIs. Nothing else allocates.
3. The SR Linux provider is the **only** renderer of any device path — underlay, overlay, bridged
   and routed instances, integrated routing, anycast gateway and access lists alike. It derives one
   configuration resource per affected device per source object.
4. **There is no per-device intermediate Kind.** The per-(source object, node) object is the
   device-configuration layer's own `Config`.
5. The device-configuration layer is the only component authorized to mutate device configuration.
   No component outside the cluster reads or writes device configuration, and there is no executor,
   host-side agent or second write path (FR-007, RD-02).
6. *Retired by the SR Linux retarget (RD-04): the platform `SRv6Service` API. The Kind is not
   defined, not installed, not served and not granted to any identity; see
   [spec.md](../spec.md) §Deferred scope.*
7. The optional `MigrationPlan` records source translation and cutover evidence; it does not
   replace the `Network`, and it references the `Network`'s provenance annotations rather than
   restating them (FR-046, FR-048).
8. **The intent tier is a client of this boundary, not a participant in it.** It submits `Network`
   objects into `agentic-netops-intent` and nothing else — no `Fabric`, no claim update, no
   configuration resource, no ConfigMap. See [kubernetes-objects.md](./kubernetes-objects.md).

All APIs and their controllers run in the named cluster. Containerlab is not an application
runtime and hosts only network and endpoint nodes.

## Deployment contract

- The declarative cluster configuration is version controlled: its config API, cluster name, node
  roles, node image digest, pod and service CIDRs, mounts, labels and port mappings.
- **cert-manager is a pinned prerequisite** and is installed and waited on before the
  device-configuration layer, whose aggregated API server needs its CA bundle. A missing or
  unhealthy cert-manager is a preflight failure, never a retry loop.
- Every upstream API is installed **from that project's own pinned artefact**. No CRD or API
  service may be created in an upstream project's API group by this repository, and the
  provisioning script MUST **fail, naming the artefact it could not fetch, rather than fall back**
  to a hand-written look-alike Kind in a look-alike group (FR-098). A first-party API lives in a
  first-party group and says so.
- The provisioning script is the **sole** implementation of complete environment creation and
  convergence, including the capability-gate phase and the intent-tier phase. Make and CI commands
  may invoke it but may not reimplement its phases.
- The shutdown script is the sole implementation of environment shutdown and cleanup, including
  the tier purge.
- Every platform application is installed into the cluster with pinned manifests or chart
  releases. Standalone application containers and Compose files are contract violations.
- Namespaces, Services, volumes, Secrets, RBAC, monitoring discovery, dashboards, datasources and
  alert rules are Kubernetes resources.
- Cluster nodes and containerlab management interfaces share a dedicated labelled Docker network.
  The management address space is configurable and is **checked against every existing Docker
  network, the pod CIDR and the service CIDR before anything is created**; an overlap fails
  preflight with the colliding network named (FR-008).
- There is one lab profile. No flag selects a device profile, and no manifest branches on one.
- Lifecycle scripts resolve the exact cluster, topology and network targets and refuse broad or
  unowned deletion.

## Version contract

The compatibility set has **nine parts**, because the device schema is assembled from two
repositories and the control plane is three independently released projects. All nine are pinned
together, published in deployment metadata and in provider status, and asserted by the provider
before it renders.

| # | Part | Pin |
|---|---|---|
| 1 | Device image | `ghcr.io/nokia/srlinux:25.7.1` @ `sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402` |
| 2 | Device YANG models | `nokia/srlinux-yang-models` tag `v25.7.1` = commit `badcf9977fe672437907cdae7daebb27a1361c36` |
| 3 | Schema deviation patch | `sdcio/srlinux-yang-patch` **by commit** `7410316d34f1d393b82889c0caa1b5acef80fb60` — the repository has no tags and `config-server v0.0.58` treats a `hash` reference as a tag, so the locked commit is served from the in-cluster git mirror (`schema-mirror`, `sdc-system`), asserted equal to the lock, under a tag named after the commit, and the `Schema` references the mirror by that tag; the lock records the upstream repository and commit unchanged (AD-75). The same mirror serves the first-party deviation module `deploy/sdc/schema-deviations` at a content-pinned tag (AD-82 `2026-09-21-feature-guarded-must`) |
| 4 | `Schema` CR definition | `provider: srl.nokia.sdcio.dev`, `version: 25.7.1`, `models: [srl_nokia/models]`, `includes: [ietf, openconfig]`, `excludes: ['.*tools.*']` |
| 5 | Device-configuration release | config-server `v0.0.58` — `ghcr.io/sdcio/config-server-api-server:v0.0.58` @ `sha256:bd5d312512ad7484eadb6b8e43ef550f647034abdead80429b8ba17d74041f9e`, `ghcr.io/sdcio/config-server-controller:v0.0.58` @ `sha256:01c69c589137579db784c769019bc92591899666714f153b5b4b97a761ffea13`, `ghcr.io/sdcio/data-server:v0.0.72` @ `sha256:f294c2b3810da2d92c4cba0affede839743e75d9343e4ccc80b38e39bd95dca0` (re-pinned from `v0.0.66`, which never reverted drift; `TargetsReady`, G10 and G13 passed on it — AD-80); plus the pinned cert-manager release it requires |
| 6 | Allocation authority | the authority the lock selects (`allocationAuthority.kind`) — on this lab the **first-party substitute** (`IdentifierPool`/`IdentifierClaim`, `agentic-netops-allocation`, run by the provider image with `SRL_PROVIDER_ROLE=allocation-authority`), adopted when G11 failed on kuid (AD-74); the lock-selectable alternative is `kuid-server v0.0.13` @ `sha256:d6fdae78cc5ba4d14655ef2e77bc3c38eb8201679b52aef56bf550e332800608`, never installed beside it |
| 7 | Containerlab | `0.79.0` |
| 8 | Device metric collector | gNMIc `0.47.0` |
| 9 | Provider mapping version | `srl-mapping v0.1.0`, first-party, asserted against parts 1–4 |

The Kubernetes distribution is pinned alongside: `kind v0.27.0` with its node image pinned by digest
in `versions.lock.yaml` at P0; the Kubernetes minor is whatever that pinned node image carries.

**Observability compatibility set**, pinned as one unit beside the nine: the OpenTelemetry
Collector, Prometheus, Grafana, the topology panel plugin `andrewbmchugh-flow-panel 1.20.1`, the
topology-drawing generator image (pinned by tag **and** digest, never `latest` and never an omitted
version flag), and the generated topology-asset schema together with the two-label join contract.

- **No branch reference may appear in the `Schema` CR.** Its repository entries are pinned by tag or
  by commit hash; a branch reference is mutable and is forbidden wherever it can appear. Where the
  pinned layer cannot fetch a commit by hash, the commit is served under a tag from the in-cluster
  mirror (part 3, AD-75) — never by a branch.
- Pin every first-party image — the provider's and the intent tier's — in the same lock file, with
  a local build step. A locally built image has no registry digest, so what is pinned is what *can*
  be resolved: every `FROM` by registry-resolved digest and every dependency lock file by hash; the
  image is tagged with the content hash of its build context, run with a never-pull policy, and its
  built identity is recorded in the run's evidence ([../data-model.md](../data-model.md) §26).
- A mismatch between a resource's recorded compatibility set and the target's loaded schema MUST set
  `SchemaMismatch`, emit no changed configuration spec, and leave the last known valid applied
  intent intact.
- `latest`, floating minor tags, branch references and a mixture of tutorial and main-branch API
  shapes are forbidden.

**The pin check is executable, and it is what NFR-003 means.** `make verify-pins` MUST resolve every
digest against its registry and every commit against its repository, so that an unpullable or
non-existent pin fails **before** provisioning rather than during it. A placeholder or synthetic
digest is a hard failure of the check, not a warning: any digest that does not resolve is treated as
absent, and the run stops naming the file, the key and the reference. Where a digest is genuinely
not yet known it is recorded as pinned by digest in the lock file at P0 and the check fails until it
is — a reference is never invented to make the check pass.

## Required `Fabric` and `Network` API

**Group/version**: `fabric.agentic-netops.io/v1alpha1` · **Kinds**: `Fabric` (plural `fabrics`),
`Network` (plural `networks`) · **Scope**: Namespaced · **Status subresource**: required on both

Both Kinds carry **real structural OpenAPI schemas**. `spec` MUST NOT carry
`x-kubernetes-preserve-unknown-fields`, unknown fields are rejected, and every enum, format, range
and required field is expressed in the schema so that a server-side dry-run is a meaningful gate.
This is what makes "dry-run" mean something for the intent object; it says nothing about the device
payload, which is validated by the device-configuration layer instead.

**`Fabric`** requires: at least one `leaf` and one `spine` node, unique node names, a system loopback
that is a `/32` or a reference to an address pool, an AS number that is unique per leaf and shared
across spines, an immutable `overlay.fabricASN`, a route-reflector flag only on a spine, a non-empty
underlay address-family list, the MTU block, and an inventory whose access and fabric port lists are
disjoint and whose spine entries have no access ports. It **accepts** an optional
`inventory[].untaggedAccessPorts` — a subset of that entry's `accessPorts`, empty by default — which
declares the ports rendered `vlan-tagging false`; every other access port is rendered
`vlan-tagging true`, and the fabric `Config` owns that leaf and the port's `admin-state` (AD-68). A
declaration that would change the mode of a port a `Network` still attaches to is
`Accepted=False/InvalidIntent` naming the port and the services. It **accepts** an optional `maintenance[]` —
`{node, interface, adminState: disable}`, each naming a port in the inventory, at most one entry per
port — which is the one declarative administrative-state knob: the fabric reconciler renders it as
the interface's `admin-state` in that node's priority-10 `Config`, and removing the entry restores
it. It also **accepts `overlay.interASVPN: false`** — no rule refuses or warns on it, on a reflecting
spine or anywhere else; it is rendered as stated and checked as declared equals read back, and is
**not** SC-004's control nor a convergence rule of its own (AD-77: with `inter-as-vpn` removed the
spines still reflected). It **accepts `overlay.reflectorClients`** (boolean, default `true`),
rendered as `route-reflector client` on every reflecting spine's overlay group, and accepts
`overlay.reflectorClients: false` the same way — no rule refuses or warns on it — because **that** is
the declarative way to withdraw reflection that SC-004's negative control uses (AD-43's mechanism,
its field as decided in AD-77); the `Fabric` then reports `Ready=False/NotConverged` naming the
reflecting spines and the setting rather than refusing the object. Full shape in [../data-model.md](../data-model.md) §3a.

**`Network`** requires the shape in [network-spec.md](./network-spec.md) §1. Validation is expressed
as CEL rules on the structural schema wherever it is same-object, and in an admission webhook only
where a rule is genuinely cross-object:

| Rule | Where | Statement |
|---|---|---|
| Construct-list exclusivity | CEL | Exactly one of the five shapes in [network-spec.md](./network-spec.md) §2 may be present: `vlans` alone, `bridgeDomains` alone, `bridgeDomains`+`routers` with an `irb`, `routers` alone, or `accessLists` alone. Any other combination is rejected naming both lists |
| One VLAN per bridge domain | CEL | Every attachment of a `vlan` or `bridgeDomains` service carries the same VLAN as that list entry |
| VLAN range | CEL | `1..4094` structurally; **`100..4000`** — the platform's whole VLAN space — enforced with both bands stated in the message: `100–999` to name from, `1000–4000` the allocation authority's (AD-33). **The CEL rule stops there on purpose.** Which band a value falls in decides whether a claim must back it, and CEL cannot see a claim, so telling a named VLAN from an allocated one is not a CEL rule: the **mapper** enforces the naming band on the tier path, at interpretation and before any claim exists — the translator, like this rule, checks only the structural `100..4000`, because its input cannot say which kind a VLAN is (AD-41) — and the provider's claim gate enforces the allocation band on the cluster-tooling path. The attachment VLAN of an `accessLists`-only object is a reference to another service's subinterface and is held to the structural range alone (AD-47) ([kuid-claim-profiles.md](./kuid-claim-profiles.md) §2, [reconciliation.md](./reconciliation.md) Rule 3) |
| VNI device range | CEL | `l2vni` and `l3vni` are within the **device range** `1..65535` — not to be confused with the *allocation band*, the VNI index's own range, which the translator and the allocation authority enforce (AD-10) — because the EVPN instance identifier is derived from the VNI; a service's L2VNI and L3VNI differ |
| Route targets are derived | CEL | `routeTargets` entries match `target:<fabricASN>:<vni>` for this object's own VNIs. A route distinguisher field does not exist and is rejected as an unknown field |
| Gateway placement | CEL | `irb` appears only on a `bridgeDomains` entry, declares at least one address family, and requires a `routers` entry to point at; an IPv6 gateway address is not link-local |
| Access-list rules | CEL | `type` ∈ `ipv4`\|`ipv6`; ≥1 rule; priorities distinct and in `1..65534`; rule names distinct; every prefix in the list's family; an L4 port only with TCP or UDP; a reserved filter name rejected by name |
| Attachment uniqueness in-object | CEL | No two attachments in one object resolve to the same `(node, port, vlan)` |
| One tagging mode per port, in-object | CEL | No two attachments in one object name the same `(node, port)` with one carrying a VLAN and the other none; the message names the port (FR-034, AD-20) |
| Allocated identifiers are immutable | CEL (transition) | Once the object is accepted, `bridgeDomains[].l2vni`, `routers[].l3vni`, `vlans[].vlan` and `bridgeDomains[].vlan` cannot change, and the entries of those three lists — maps keyed by `name` — cannot be added, removed or renamed. The message names the field and says that changing it is a removal and a new service, so no claim is ever superseded while its service lives (FR-109, AD-25). `attachments[]`, `accessLists[]`, `prefixes` and gateway addresses stay mutable |
| An added attachment may not bring a *new* allocation-band VLAN | CEL (transition) | An attachment **added** to an accepted object must carry a VLAN in `100–999`, or none, **or the allocation-band VLAN the object already carries** — the VLAN of its own `vlans[]` or `bridgeDomains[]` entry, which is the only place an allocated VLAN can live (AD-51), so the rule reads `spec` alone and never `status` — so that a `vlan` or `mac-vrf` whose VLAN was allocated can still gain an attachment, which the one-VLAN-per-bridge-domain rule obliges to carry that same VLAN and whose claim is already adopted (AD-47). `spec.attachments[]` stays mutable (AD-25); what is refused is a VLAN in `1000–4000` that the object does **not** already carry, because that would be an allocation nobody claimed, on an object whose claims are already fixed. The message names the VLAN and both bands and says the attachment is a new service (FR-109, AD-32, AD-33). On an **`ip-vrf`** the object carries no such VLAN, so an added attachment carries a naming-band VLAN or none: an `ip-vrf` attachment's VLAN is named or absent and never allocated (AD-51). An **`accessLists`-only object is outside the rule**, its attachment VLAN being a reference (AD-47): it may gain an attachment naming a VLAN in either band, and T014 and T017 carry that exemption (AD-56). An attachment already present keeps its VLAN, and an attachment **removed** takes nothing with it — its claim stays adopted and held until finalization |
| Attachment resolvability | webhook | Every attachment names a node and an access port the `Fabric` inventory lists, and never a spine — **in the tagging mode the inventory declares for that port**: an untagged attachment only on a port listed in `untaggedAccessPorts`, a tagged one only on a port that is not. The refusal lists the ports declared in the mode that was asked for (CR-003, AD-68) |
| One owner per (node, port, vlan) | webhook | No other `Network` already owns the derived subinterface; the refusal names the holding service. This is the rule that makes a **named** VLAN exclusive, since nobody claims one (FR-034, FR-109). It sees `agentic-netops-intent` and `agentic-netops-services` alike, so it catches a holder the deployer's pre-flight — which scans the intent namespace only — cannot see. With the bands disjoint (AD-33) the two services in such a conflict have both **named** the VLAN; an allocated VLAN cannot be one of them. **An `accessLists`-only object is never an owner under this rule**: its attachment *references* the subinterface another `Network` owns and creates none (row *Standalone list needs its subinterface*, below), so it is neither refused by this rule nor counted as the holder when the owning service's attachment is checked |
| One tagging mode per port | webhook | No other `Network` holds an attachment on the same `(node, port)` in the other tagging mode — an untagged attachment (subinterface `0`) and a tagged one never share a port, because tagging is a property of the interface. The refusal names the port and both services. A service with a deletion timestamp still holds its mode. A standalone access list inherits the mode of the attachment it binds to and is not a second mode (FR-034, AD-20). With the mode declared on the port (AD-68) two admitted attachments each match one declaration, so this rule is the backstop across a change of that declaration |
| Access-list binding exclusivity | webhook | No other `Network` holds a binding on the same `(node, port, subinterface, direction, address family)`; a service with a deletion timestamp still holds its bindings, and the refusal says so |
| Standalone list needs its subinterface | webhook | An `accessLists`-only object binds only where another `Network`'s attachment already created the subinterface; otherwise refused naming the missing subinterface. The VLAN on its attachment is a **reference** to that subinterface — in either band, claimed by nobody on this object's account, and outside both band rules (AD-47) |
| Qualification | webhook | Every construct and gated property in the object appears as qualified in the qualification record; otherwise rejected with `Unqualified` |
| Name shape | CEL, schema | `metadata.name` is a DNS-1123 **label** — lower-case alphanumerics and `-`, **no dot**, **at most 63 characters** — so the generated configuration-resource name parses to the right node. The names of `vlans[]`, `bridgeDomains[]` and `routers[]` entries are DNS-1123 labels of at most 63 characters too (`maxLength` and `pattern` on the schema). The bound is what keeps every claim name `<namespace>.<name>.<role>` a valid object name: `63 + 1 + 63 + 1 + 6 + 63 = 197 ≤ 253`, the six being the longest role prefix, `l2vni-` or `l3vni-` ([kuid-claim-profiles.md](./kuid-claim-profiles.md) §5, AD-56) |

`Fabric` is immutable in `overlay.fabricASN` and in each node's `role` after acceptance. An
admission webhook MAY provide further semantic validation that cannot be expressed structurally, but
the controllers remain authoritative for dependency and capability validation.

**The webhook fails closed** *(AD-52, operator decision)*. Its `ValidatingWebhookConfiguration` is
registered for `CREATE` and `UPDATE` of every resource it has a rule for — `networks` today; the
`Fabric`'s validation is CEL alone and needs no webhook — with:

| Field | Value | Why |
|---|---|---|
| `failurePolicy` | **`Fail`** | The provider serves the webhook, so while the provider is down no `Network` create or update is admitted — the tier's, an operator's or anyone else's. Every row marked *webhook* above therefore holds at admission **at all times**, which is what CR-003's "at admission alike" and FR-034's one-owner and one-tagging-mode rules need; nothing is admitted unchecked and reported `Accepted=False` afterwards |
| Operations | `CREATE`, `UPDATE` — **never `DELETE`** | A removal through the tier, the deployer's rollback and a `kubectl delete` go through whether or not the provider is up; the finalizer holds the object until the provider is back (Rule 8), so removal never depends on the webhook |
| `timeoutSeconds` | not stated — the API server's default | No artifact gives a figure and none is invented here |
| Rules evaluated on | a `CREATE`, and an `UPDATE` **that changes `spec`** on an object with no deletion timestamp — **nothing else** (AD-61) | An `UPDATE` that leaves `spec` as it was — a finalizer added or removed, a label, an annotation, the force-release annotation included — and **any** `UPDATE` of an object that carries a deletion timestamp are **admitted without evaluating a single rule**. The registration above is unchanged: the exemption is the handler's own first step, not a narrower `rules` entry and not a `matchConditions` expression, so every `UPDATE` still reaches the webhook and is still refused while it cannot be reached |

A request refused because the webhook could not be reached is a **failure of the cluster API
dependency, not a validation refusal**: it names no rule, no holder and no valid alternative, and
the deployer reports it as such ([kubernetes-objects.md](./kubernetes-objects.md) §"Submission
contract", step 4; NFR-010). `failurePolicy: Ignore` was rejected: it would admit an object none of
the cross-object rules had seen for as long as the provider was restarting, and leave the refusal to
an after-the-fact `Accepted=False` on an object that already exists.

**What the webhook evaluates, and what it lets through unread** *(AD-61)*. Every row marked *webhook*
in the table above is a rule about what a `spec` may **say**, so it is evaluated when a `spec` is
first stated — a `CREATE` — and when it is restated — an `UPDATE` whose `object.spec` differs from
its `oldObject.spec`, compared semantically — and at no other time. The handler's first step admits,
with no rule evaluated, an `UPDATE` whose `spec` is unchanged and any `UPDATE` of an object carrying a
deletion timestamp. In the Kubernetes API a finalizer added or removed, a label and an annotation are
each an `UPDATE` of `networks`, and three things the platform itself requires are exactly that, on an
object whose `spec` may no longer pass a rule it passed when it was admitted: **Rule 8 step 7**, the
provider removing its finalizer ([reconciliation.md](./reconciliation.md)); **the force-release of
FR-103** on a device that never returns, whose node the operator may already have taken out of the
`Fabric` inventory, so that *Attachment resolvability* would refuse the annotation that is the only
exit left; and the deletion of a service whose attachment stopped resolving after a topology change,
or whose construct the qualification record no longer shows. None of them is ever refused by the
platform's own webhook. The provider's status writes never reach it at all: its rule names the
resource `networks` and not the `status` subresource.

This widens nothing. **The guard on the force-release annotation stays where it was**: the admission
*policy* `deny-tier-force-release` ([kubernetes-objects.md](./kubernetes-objects.md)) — a separate
admission step this exemption does not touch — still denies it to both tier identities on `CREATE`
and `UPDATE` alike, and the provider still honours it only with a reason and only on an object both
deleting and blocked on `TargetUnreachable` (Rule 8). A metadata-only `UPDATE` cannot take a
subinterface, a tagging mode or a binding, because those are read from `spec`; and an object with a
deletion timestamp **still holds** its mode and its bindings against every *other* object's
admission, read from its stored `spec`, exactly as the rows above say. The CEL rules are the API
server's own and run on every write as before. While the webhook cannot be reached a metadata-only
`UPDATE` is refused like any other — the exemption lives behind the call — which costs nothing:
only the provider removes its finalizer or acts on the force-release annotation, and it is the
provider that is down.

**Status** on both Kinds exposes `observedGeneration`, the standard conditions
([../data-model.md](../data-model.md) §18), the claim references backing every allocated value — each marked `adopted` (the tier made it) or `created` (the provider did, FR-109) — the
generated configuration references with their render hashes, and per-target phase and reason.
`Ready=True` requires current-generation apply **and** the two-sided read-back of FR-100.

**`status.claimRefs[]` — the one field list** (FR-109, AD-56). Every other artifact cites this
table; none restates it.

| Field | Meaning |
|---|---|
| `name` | the claim object's name — deterministic, `<namespace>.<name>.<role>` ([kuid-claim-profiles.md](./kuid-claim-profiles.md) §5) |
| `namespace` | the allocation namespace the claim lives in |
| `indexKind` | which index it draws from: the VLAN index or the generic-identifier (VNI) index |
| `value` | the identifier the claim reports, so the list is readable without a second query |
| `origin` | `adopted` — the tier made it — or `created` — the provider did. Written once and never changed: adoption is decided once per value |

**Printer columns**

| Kind | Columns |
|---|---|
| `Fabric` | Leaves, Spines, FabricASN, Allocated, Ready, Degraded, Age |
| `Network` | Construct, Tenant, VLAN, L2VNI, L3VNI, Ready, Degraded, Age |

## Optional `MigrationPlan` API

**Group/version**: `agentic-netops.io/v1alpha1` · **Kind**: `MigrationPlan` · **Scope**: Namespaced ·
**Status subresource**: required

The structural schema MUST reject unknown fields; enforce the migration-alias and cutover enums;
require a stable source identifier and a target `Network` reference; reject raw CLI or
configuration blobs; validate prefix, endpoint and attachment formats where expressible — it has
**no** route-target, VLAN or VNI policy field of its own, those being derived or allocated for a
migrated service exactly as for any other (FR-012, AD-29); use admission rules for cross-field constraints; keep source identity immutable after
acceptance; default limited equivalence to false and automatic cutover to disabled; and expose
printer columns for the construct, the target `Network`, Ready, Degraded and Age.

A `MigrationPlan` records **the construct the service became alongside the source vocabulary it
arrived in**, and references the `Network`'s provenance annotations rather than restating them —
the annotations are the single provenance record (FR-046, FR-048).

**Not installed by default** (AD-29). The CRD is generated under `config/crd/optional/`, outside the
default kustomization, and lab provisioning never applies it. Its controller is part of the provider
binary and registers only when the CRD is served, under its own Role — `get, list, watch` and
`status` updates on `migrationplans`, `get, list, watch` on `networks`. It records; it never creates
or modifies a `Network`, so translation still happens in exactly one place (FR-060).

## Generated device configuration contract

For every source object and every affected device, the provider generates exactly one
`config.sdcio.dev` `Config`, which MUST have:

- **a deterministic name `<source>.<node>`** — the source object's name, a single dot, the node
  name. The layer parses the node as the text after the last dot, so **the source name must contain
  no dot**; a dot silently mis-targets the configuration and is refused at validation;
- **target binding by label**, `config.sdcio.dev/targetName: <node>` and
  `config.sdcio.dev/targetNamespace: <the target's namespace>`, resolving to a Ready target;
- **an explicit priority from a reserved band**: `10` for the `Fabric`-derived per-node
  configuration, `20` for per-service configuration. **Two `Config` objects that can touch the same
  device leaf MUST NOT share a priority** — the layer leaves an equal-priority winner undefined, so
  such an overlap is a conflict refused at validation, not an ordering to resolve. *A leaf here is a
  non-key leaf* — a list key is part of a path — and the render is built so that no two service
  `Config`s share one (AD-68): **the port-level leaves of an access port (`admin-state`,
  `vlan-tagging`) and `irb0`'s own `admin-state` are rendered by the fabric `Config` at priority
  `10`**, from the inventory's declared tagging mode; a service `Config` writes nothing above its own
  `subinterface[index]`, and the `/acl/interface[…]/interface-ref` of a subinterface is rendered by
  the `Config` that renders that subinterface, a standalone `acl` writing only its filter entry
  beneath it. The provider compares non-key leaf paths with the node's other `Config`s of the same
  priority before it writes; an overlap is `Applied=False/OwnershipConflict` naming the path and the
  other `Config`;
- **`lifecycle.deletionPolicy: delete`** on everything the platform owns, so finalization removes
  device state; `orphan` is a documented break-glass only;
- **`revertive: true`**, always stated and never left to the layer's own default — the field is an
  optional boolean with no default in the layer's own schema, so an absent field silently inherits
  the data-server's global setting, which is exactly what FR-015 forbids. The provider reads the
  policy from `DRIFT_POLICY`, which has **no default** and a **closed value set of one,
  `revertive`** (exact string), mapping to `revertive: true` here; unset, empty or anything else —
  `non-revertive`, `Revertive`, `true` — refuses the start naming the variable and the admissible
  value. The production drift policy is selected explicitly and never inherited from the lab; today
  there is one value to select, and it is the same one the lab selects. The layer's non-revertive
  mode holds the deviation for an operator to accept or revert rather than accepting it outright,
  so it is a shape the constitution would admit and this feature does not build (FR-015, AD-13,
  AD-17, AD-34);
- **one `config[]` entry at path `/`** whose `value` is the native JSON_IETF document for that node's
  share of the source object, module-qualified, with identityref values in the exact serialization
  the device returns on a read;
- **namespace `agentic-netops-system`, always** — the provider's own. A `Fabric` lives there, so a
  fabric `Config` carries a controller owner reference to it. A `Network` never does, so **a service
  `Config` carries no `ownerReferences`**: a cross-namespace owner is read by Kubernetes as an absent
  one and the dependent is collected, which with `deletionPolicy: delete` would withdraw the service
  from the device. It is tied to its source by the `agentic-netops.io/source-uid` annotation and the
  labels `agentic-netops.io/network-namespace` and `agentic-netops.io/network-name`, and removed by
  the `Network`'s finalizer (FR-103). A `Config` of the derived name whose `source-uid` is another
  object's is never overwritten: `Applied=False/OwnershipConflict` naming the holder (FR-016, AD-69);
- annotations for source UID and generation, the render hash, **the nine-part compatibility set** and
  the mapping version;
- the dedicated server-side-apply field manager `agentic-netops-srl-provider`;
- the smallest practical set of scoped paths;
- no plaintext credentials or secret values;
- no field claimed by another controller unless priority and ownership are explicitly designed.

Provider reconciliation MUST compare the canonical render hash before updating. An unchanged hash
causes no spec update and therefore no device transaction.

**Exemplar — the `Config` the provider generates on `leaf01`** for the `mac-vrf` with an anycast
gateway and an ingress access list shown in [network-spec.md](./network-spec.md) §6. The native
value is trimmed to one object of each kind; the full document carries every path listed in
[../data-model.md](../data-model.md) §13.

```yaml
apiVersion: config.sdcio.dev/v1alpha1     # storage version is `config`; do not assume v1alpha1
kind: Config
metadata:
  name: migr-4b7e19c2a05d3f6.leaf01               # <source>.<node>; the source name carries no dot
  namespace: agentic-netops-system
  labels:
    config.sdcio.dev/targetName: leaf01
    config.sdcio.dev/targetNamespace: agentic-netops-system   # the Targets' namespace (AD-82 2026-09-21-target-namespace)
    agentic-netops.io/network-namespace: agentic-netops-intent
    agentic-netops.io/network-name: migr-4b7e19c2a05d3f6
  annotations:
    agentic-netops.io/source-uid: "<uid of the Network>"
    agentic-netops.io/source-generation: "3"
    agentic-netops.io/render-hash: "sha256:<canonical render hash>"
    agentic-netops.io/mapping-version: srl-mapping v0.1.0
    agentic-netops.io/compatibility-set: "<the nine-part set identifier>"
  # no ownerReferences: the Network lives in another namespace (AD-69); the finalizer removes this object
spec:
  priority: 20                            # 10 is the fabric Config; never equal on one leaf
  revertive: true                         # lab and production alike; always stated, never inherited (AD-17, AD-34)
  lifecycle: {deletionPolicy: delete}
  config:
  - path: /
    value:
      srl_nokia-interfaces:interface:
      - name: ethernet-1/1                # the port's own admin-state and vlan-tagging are the fabric Config's (AD-68)
        subinterface:
        - index: 100
          type: srl_nokia-interfaces:bridged
          admin-state: enable
          srl_nokia-interfaces-vlans:vlan:
            encap: {single-tagged: {vlan-id: 100}}
      - name: irb0                        # irb0's own admin-state is the fabric Config's (AD-68)
        subinterface:
        - index: 100
          admin-state: enable
          anycast-gw: {virtual-router-id: 1}
          ip-mtu: 9348
          srl_nokia-if-ip:ipv4:
            admin-state: enable
            address:
            - {ip-prefix: 10.10.0.1/24, anycast-gw: true, primary: [null]}
            srl_nokia-interfaces-nbr:arp:
              learn-unsolicited: true
              host-route: {populate: [{route-type: dynamic}]}
              srl_nokia-interfaces-nbr-evpn:evpn: {advertise: [{route-type: dynamic}]}
      srl_nokia-tunnel-interfaces:tunnel-interface:
      - name: vxlan0
        vxlan-interface:
        - index: 10021
          type: srl_nokia-interfaces:bridged
          ingress: {vni: 10021}
          egress: {source-ip: use-system-ipv4-address}
        - index: 10022
          type: srl_nokia-interfaces:routed
          ingress: {vni: 10022}
      srl_nokia-network-instance:network-instance:
      - name: macvrf-4b7e19c2a05d3f6
        type: srl_nokia-network-instance:mac-vrf
        admin-state: enable
        description: Service 4b7e19c2a05d3f6 (mac-vrf)
        interface: [{name: ethernet-1/1.100}, {name: irb0.100}]
        vxlan-interface: [{name: vxlan0.10021}]
        bridge-table: {protect-anycast-gw-mac: true}
        protocols:
          bgp-evpn:
            srl_nokia-bgp-evpn:bgp-instance:
            - {id: 1, admin-state: enable, encapsulation-type: vxlan,
               vxlan-interface: vxlan0.10021, evi: 10021, ecmp: 8}
          srl_nokia-bgp-vpn:bgp-vpn:
            bgp-instance:
            - id: 1
              route-target: {export-rt: "target:65000:10021", import-rt: "target:65000:10021"}
      - name: ipvrf-4b7e19c2a05d3f6
        type: srl_nokia-network-instance:ip-vrf
        admin-state: enable
        interface: [{name: irb0.100}]
        vxlan-interface: [{name: vxlan0.10022}]
        protocols:
          bgp-evpn:
            srl_nokia-bgp-evpn:bgp-instance:
            - {id: 1, admin-state: enable, encapsulation-type: vxlan,
               vxlan-interface: vxlan0.10022, evi: 10022, ecmp: 8}
          srl_nokia-bgp-vpn:bgp-vpn:
            bgp-instance:
            - id: 1
              route-target: {export-rt: "target:65000:10022", import-rt: "target:65000:10022"}
      srl_nokia-acl:acl:
        acl-filter:
        - name: acl-4b7e19c2a05d3f6-ingress
          type: srl_nokia-acl:ipv4
          statistics-per-entry: true
          entry:
          - sequence-id: 100
            description: allow-https
            match:
              ipv4: {protocol: tcp, source-ip: {prefix: 10.0.0.0/24}}
              transport: {destination-port: {operator: eq, value: 443}}
            action: {accept: {}}
          - sequence-id: 65535
            description: default-deny
            action: {drop: {}}
        interface:
        - interface-id: ethernet-1/1.100
          interface-ref: {interface: ethernet-1/1, subinterface: 100}   # rendered with the subinterface by its owner, filter or none (AD-68)
          input:
            acl-filter: [{name: acl-4b7e19c2a05d3f6-ingress, type: srl_nokia-acl:ipv4}]
```

Notes that are part of the contract, not commentary:

- Identityref and foreign-module enum values are written module-qualified. The exact form the device
  returns on a read is observed at the capability gate **before any golden file is frozen**, and the
  golden files carry that form, because a serialization difference alone would produce a spurious
  mutation on every reconcile. G12 observed the module-prefixed RFC 7951 form, and the goldens freeze
  it, as decided (AD-81).
- An action is a presence container: it serializes as an empty object, never as `true` and never as
  `null`.
- The route distinguisher is absent by design: the device derives it. The route targets are present
  by design: a device-derived route target would use the per-leaf underlay AS and would never match.
- The filter key is the **pair** `(name, type)`; every render, read-back and withdrawal path carries
  both.
- The whole per-(service, node) document is one transaction. A failed transaction fails only itself
  and rolls back; nothing poisons a later commit.

## Metadata contract

**Two actors stamp metadata on the `Network`, with disjoint key sets and a fixed emission order.
The provider stamps none of it** (FR-101).

| Actor | Keys | Object |
|---|---|---|
| Translator | translator, translator-version, mapping-version, input hash, tenant, **service-type (the construct)**, **source-service-type (the migration alias, when there was one)**, limited-equivalence | `Network` |
| Intent tier | `agentic-netops.io/correlation-id` (label, selectable), `agentic-netops.io/tier` (label), thread id, principal — **the authenticated username (FR-102)** — submitted-at and the **submitted-spec SHA-256 (FR-105)** (annotations) | `Network` |
| Provider | source UID, source generation, render hash, compatibility set, mapping version | **`Config`, never the `Network`** |

Neither actor writes the other's keys. The emission order of all keys is fixed and is stated in
[network-spec.md](./network-spec.md) §3, so that a key computed late is not silently dropped. All of
these are metadata: stamping them changes no schema, controller or reconciliation contract.

One annotation is **read by the provider and written by neither stamping actor**:
`fabric.agentic-netops.io/force-release: "<reason>"`, the operator break-glass of FR-103. It is
honoured only on a `Network` that is being deleted and is blocked on an unreachable target, requires
a non-empty reason, and is denied to both intent-tier identities at admission
([reconciliation.md](./reconciliation.md) Rule 8, [kubernetes-objects.md](./kubernetes-objects.md)).
The group adds no mutating webhook and the provider never writes `spec`, which is what makes the
submitted-spec hash comparable with a later read.

## Status contract

- Status always includes `observedGeneration` and the standard conditions.
- `Fabric` and `Network` status carry `lastVerifiedTime`, the last scheduled re-verification that
  **ran** — that completed its read-back, whatever it found; only a pass that could not run leaves
  it where it was (FR-107, AD-54). A last pass that ran **older** than one re-verification interval
  plus one reconciliation interval is a stalled schedule, and raises the alert
  `ReverificationStalled` — on the **age** of that pass, whatever `Ready` says, for every object
  that has a series ([../data-model.md](../data-model.md) §21, AD-62): it is the only signal for a
  `Ready=True` nobody re-read, which is the case FR-107 requires it for. A re-verification that could
  not run against a required target sets **`Ready=Unknown/VerificationFailed`** and
  `Degraded=True/VerificationFailed`, both naming it, at that pass; `lastVerifiedTime` does not
  advance. It never sets `Ready=False` and never leaves `Ready=True` standing; the next pass that
  runs returns `Ready=True` or sets `Ready=False` naming the invariant (AD-40). `Ready` is the only
  condition of this API that takes the `Unknown` status, and `VerificationFailed` is the only
  reason it takes it with; a client MUST NOT read `Unknown` as Ready.
- `Ready=True` requires current-generation `Rendered`, `Validated` and `Applied` success for every
  required target **plus a two-sided read-back** (FR-100): the written side — the configuration
  resource applied with no deviation and its content present in the device's running datastore — and
  the applied side — the device's own state for the objects this service created, every read keyed
  to this service's own filter, instance, subinterface, tunnel or route. A fabric-wide or
  device-wide count is never evidence. **"Current-generation" decides the unreachable-target case
  too**: an object updated to a generation whose `Applied` is not yet True is converging —
  `Ready=False/NotConverged` with `Applied=False/TargetNotReady` while the target is away — and not
  `Ready=Unknown`, although it was Ready at the generation before
  ([../data-model.md](../data-model.md) §18, AD-62).
- A status condition MUST name the missing invariant and surface the device's own reason when it
  gives one; the reason codes are the closed set in [../data-model.md](../data-model.md) §18.
- `Degraded=True` says by its reason what it means for readiness. It coexists with `Ready=True` in
  exactly two cases — a non-blocking telemetry failure (`TelemetryUnavailable`) and, on the `Fabric`
  only, an open force-release finding (`StaleConfigurationPossible`, FR-103). `PartialFailure` comes
  with `Ready=False`, and `VerificationFailed` always comes with `Ready=Unknown`, never with
  `Ready=True`. One condition carries one reason, and the order is total: the two that follow
  `Ready`, then `StaleConfigurationPossible`, then `TelemetryUnavailable`, which is the reason only
  when the telemetry dependency is the only thing impaired
  ([../data-model.md](../data-model.md) §18, AD-62).
- Per-device status contains the target, the current phase, the configuration reference, the last
  transaction reference when available, a stable reason code and a concise message.
- Messages may aid humans; automation keys on stable reason codes.
- Controller logs are never the sole source of failure state.
- **During deletion** a `Network` carries `Deleting=True` whose reason says what is outstanding —
  `RemovingConfiguration`, `TargetUnreachable` (the message names each target), `HolderPresent`
  (the message names the holding service) or, transiently, `ForceReleased`. No deadline is attached
  to any of them (FR-103). Beside it, from the moment finalization starts and until the object is
  gone, **`Ready=False` with the reason `Deleting`** — in every deletion, whatever the reachability
  of its targets; an object being deleted is never `Ready=True` and never `Ready=Unknown`, because
  it is no longer offered and nothing is read back to decide that (AD-53). A client that reads
  `Ready=False` keys on the reason: `Deleting` is a removal in progress, not a failure.
- **`Fabric.status.findings[]`** is the durable record of a force-release and outlives the service
  it names; its fields and its clearance rule are in [../data-model.md](../data-model.md) §3a. An
  open finding sets `Degraded=True/StaleConfigurationPossible` on the `Fabric` and nothing else —
  **once a pass can read the fabric's targets**: one condition carries one reason, and while a
  required target cannot be read the reason is `VerificationFailed` (with `Ready=Unknown`), the
  finding being visible in `status.findings[]` throughout; `StaleConfigurationPossible` is the
  reason from the first pass that runs while a finding is still open (AD-54).

## Conditional kinds — the recorded allocator substitution (FR-104)

`IdentifierPool` and `IdentifierClaim` are **defined in this group and installed only when the lock
file selects `allocationAuthority.kind: first-party`** under a recorded operator decision
([kuid-claim-profiles.md](./kuid-claim-profiles.md) §7, [../data-model.md](../data-model.md) §23).
Both have structural schemas with no `x-kubernetes-preserve-unknown-fields`; an `IdentifierClaim`'s
`spec` is immutable by CEL and its allocation is reported in `status.value`. They are the single
exception FR-013 names, they replace the upstream allocation APIs rather than standing beside them,
and they are never served in an upstream group. With `kind: kuid` — the default — neither CRD exists
in the cluster, and a test asserts that.

## API contract tests

- Server-side dry-run accepts every shipped manifest against the pinned CRDs, and **rejects** each
  negative fixture: an unknown field, a route-distinguisher field, a VNI outside the device range `1..65535`, a VLAN
  outside the managed range, duplicate rule priorities, a priority of 65535, a mismatched prefix
  family, an L4 port on a non-TCP/UDP protocol, a reserved filter name, two attachments resolving to
  one subinterface, an untagged and a tagged attachment on one port (in one object by CEL, across
  two objects by the webhook, naming the port and both services), an attachment in a mode other than
  the one the inventory declares for its port (AD-68), a spine attachment, a name
  containing a dot, a `metadata.name` of 64 characters and a `bridgeDomains[]` entry name of 64
  (the bound that keeps a claim name inside 253, AD-56), and — as **updates** to an accepted object — a changed `l2vni`, a changed
  `l3vni` and a changed service VLAN, each refused naming the field, beside an added attachment
  that is accepted (AD-25) — one carrying a naming-band VLAN or none, **and** one on a `mac-vrf`
  whose VLAN was allocated, carrying that same VLAN — and an added attachment carrying an
  allocation-band VLAN the object does not already carry, refused naming the VLAN and both bands
  (AD-47) — an `ip-vrf` gaining an attachment on VLAN `1500` being one such (AD-51) — while an
  **`accessLists`-only** object gaining an attachment on VLAN `1500` is accepted, that VLAN being
  a reference and the object outside the rule (AD-47, AD-56).
- Every golden render is **schema-validated against the pinned device schema offline**, through the
  device-configuration layer's own schema tooling, before any test touches a device.
- An **FR-098 test** asserts that no CRD or API service this repository installs declares an
  upstream project's API group, and that the provisioning script fails — rather than creating a
  stand-in — when an upstream artefact cannot be fetched.
- A **qualification-record test** asserts that a construct or gated property absent from the record
  is refused at interpretation with `Unqualified`, that nothing is created, and that the record is
  readable by the tier without granting it any new permission.
- An **FR-104 test** asserts exactly one allocation authority: under `kuid` no `IdentifierPool` or
  `IdentifierClaim` CRD is installed; under `first-party` no `*.be.kuid.dev` APIService exists; and
  the pin check refuses `first-party` without a decision record and failed-gate evidence that
  resolve.
- A **submitted-hash test** asserts that the applied `Network` differs from its dry-run result in
  exactly one annotation, that re-reading an untouched object reproduces the hash, and that a
  `kubectl`-made edit to any `spec` field does not.
- A **force-release test** asserts the empty-reason refusal, the admission denial for both tier
  identities, the Event, the finding's content and its clearance only after a clean read-back.
- A **fail-closed test** asserts that the shipped `ValidatingWebhookConfiguration` states
  `failurePolicy: Fail` on `CREATE` and `UPDATE` of `networks` and does not list `DELETE`, and — in
  envtest, with the webhook's endpoint made unreachable — that a `Network` create and an update are
  refused by the API server while a delete of an existing `Network` is accepted (AD-52).
- An **evaluation-scope test** asserts what the webhook does *not* evaluate (AD-61): on a `Network`
  carrying a deletion timestamp and the provider's finalizer, **whose node has been removed from the
  `Fabric` inventory**, setting the force-release annotation and removing the finalizer are both
  admitted; a label or annotation change on a live `Network` whose attachment no longer resolves is
  admitted; a `spec`-changing `UPDATE` on a live object is **still evaluated** — an attachment moved
  onto a port another service owns is refused naming the holder; and with the endpoint unreachable
  every one of those `UPDATE`s is refused by the API server, the exemption being the handler's.
- Conversion and webhook tests preserve supported objects across any introduced API version.
- Golden renders use stable names, hashes, owner references and scoped paths.
- Reapplying the same source generation produces no spec update and no device mutation.
- Deleting a source removes only its owned configuration resources after finalization.
- Topology assets contain exactly the deployed node and link identifiers and join to the declared
  two-label metric contract.
- Pin-check tests: every digest resolves against its registry, every commit against its repository;
  a placeholder digest, a branch reference in the `Schema` CR, a `latest` tag and an omitted
  generator version each fail the check.
- A clean provisioning run and a repeated run both reach every readiness gate, including the
  capability gate.
- Shutdown from Ready, partial and already-absent states removes only owned resources and returns
  success.
- Runtime inventory proves every non-network application is a Pod in the cluster and no standalone
  or Compose application container exists.
