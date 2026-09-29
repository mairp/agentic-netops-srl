# Data Model: Agentic NetOps — Composite Platform

**Feature**: `004-agentic-netops-composite` | **Date**: 2026-09-20
**Source**: [spec.md](./spec.md) §Key Entities | **Decisions**: [research.md](./research.md)

The merged entity model, read top-down: who owns what, what an operator can ask for, what the
intent tier produces, what reaches the cluster, and what each construct becomes on a device.

Entities in §6–§12 exist twice by design — once as a Python model in the agent tier and once as a
Go struct in the translator — and the two must stay byte-compatible, because the Python model
serializes straight into a strict parser that rejects unknown fields.

---

## 1. Ownership model

| Layer | Source of truth | Owns | Must not own |
|---|---|---|---|
| Intent tier | Conversation thread state | Natural-language interpretation, operator confirmations, the correlation identifier, the audit record | Allocation, translation semantics, device configuration, or any device session |
| Migration boundary | Git and the optional `MigrationPlan` | Source provenance, mapping findings, cutover decision | Allocations or device configuration |
| Translator (`pkg/migration`) | The construct vocabulary | Canonicalization, all-or-nothing validation, the rendered `Network` object | Allocation, cluster interaction, device state |
| Fabric design and allocation authority | The first-party `Fabric` object and the allocation authority's indices and claims | Node roles, underlay addressing and ASN plan, the fabric-wide overlay AS, MTU policy, route-reflecting spines, the site inventory, and the allocation of IP addresses, ASNs, VLANs and VNIs | Per-service semantics or any device YANG path |
| SR Linux provider (`controllers/fabric`, `controllers/network`) | Controller reconciliation | Deterministic per-device rendering of every SR Linux path, and readiness propagation from two-sided read-back | Independent allocation or device transaction |
| Device-configuration layer | Upstream `inv.sdcio.dev` and `config.sdcio.dev` resources and target state | Schemas, device transactions, running-versus-intended comparison, deviations, per-leaf intent ownership | Service semantics |
| Device | Running network state | Applied forwarding and control-plane state | Desired-state authority |
| Observability | The metrics store | Time-series metrics and alert state | Configuration source of truth |

The same field or path MUST have one owner. The platform uses server-side apply with the dedicated
field manager `agentic-netops-srl-provider` for generated configuration resources. Unmanaged device
paths remain untouched, and per-leaf ownership is machine-checked against the device-configuration
layer's own blame records (see [contracts/reconciliation.md](./contracts/reconciliation.md) Rule 4).

**Two actors stamp metadata on the `Network`** — the translator and the intent tier — with disjoint
key sets, no actor writing another's keys, and a fixed emission order. The provider stamps nothing
on the `Network`: its source identity, generation, render hash, compatibility set and mapping
version belong on the `Config` objects it generates (FR-101).

---

## 2. Runtime and lifecycle model

| Runtime resource | Owner | Contents and behaviour |
|---|---|---|
| Kind cluster `agentic-netops` | Lifecycle scripts | Sole application runtime; pinned node image and declarative cluster configuration |
| Namespaces | Manifests and chart releases | `agentic-netops-system` (provider, gate record source), `agentic-netops-services` (control-plane-owned; `Network`s applied with cluster tooling — the shipped examples and the control-plane suites; untouched by the tier's removal), `agentic-netops-intent` (tier-owned; tier-submitted `Network`s, which the tier's removal deletes only when it is asked to and otherwise stops naming — AD-26, AD-35), `agentic-netops-agents` (tier workloads), the allocation authority's namespace — `agentic-netops-allocation` on this lab, where the lock selects the first-party substitute (AD-74), `kuid-system` under the lock-selectable alternative kuid — `sdc-system` (the device-configuration layer's own workloads and the schema mirror, AD-75; the onboarding set and the `Target`s are in `agentic-netops-system`, AD-82 `2026-09-21-target-namespace`), `cert-manager`, `monitoring` |
| In-cluster applications | Kubernetes controllers | cert-manager, the allocation authority the lock selects (on this lab the first-party substitute, run by the provider binary with `SRL_PROVIDER_ROLE=allocation-authority`, AD-74; `kuid-server` is the lock-selectable alternative, never coexisting), the device-configuration layer (config-server api-server, controller, data-server) and its in-cluster schema mirror (AD-75), the SR Linux provider, the migration translator sidecar, gNMIc, the OpenTelemetry Collector, Prometheus, Grafana, and every intent-tier workload |
| Management network | Lifecycle scripts | Labelled Docker network `agentic-netops-mgmt`, default CIDR `172.25.25.0/24`, shared by cluster nodes and containerlab management interfaces |
| Containerlab topology | Lifecycle scripts plus `lab/topology.clab.yml` | Six nodes — `spine01`, `spine02`, `leaf01`, `leaf02`, `client01` (on leaf01), `client02` (on leaf02) — and nothing else |
| Application state | Kubernetes APIs, volumes and Secrets | Desired state, metric retention, thread checkpoints, analytics, credentials, dashboards, alerts, schema data |

Every owned non-Kubernetes runtime resource carries stable labels or a deterministic name so
teardown can resolve its exact target without broad globs. The shutdown path never deletes a
cluster or network whose ownership or name does not match its selected cluster.

Lifecycle phases are durable and repeat-safe:

```text
Absent → NetworkReady → ClusterReady → LabReady → AppsReady → TargetsReady → GateReady
   ▲                                                                  │
   │                              FabricReady → ObservabilityReady → IntentTierReady
   │                                                                  │
   └───────── teardown: evidence → tier purge → lab removal → cluster deletion → cleanup ─────┘
```

`GateReady` is the capability gate (FR-004) and the publication of the per-construct qualification
record (FR-097); no service intent is accepted before it. The device metric collector (gNMIc and the
OpenTelemetry Collector) is installed at `TargetsReady`, before `FabricReady`, because it is the
read-back's state source; Prometheus, Grafana and the rules stay at `ObservabilityReady` (AD-82
`2026-09-21-state-source`). Provisioning resumes from the first unmet
phase. Shutdown tolerates any phase and treats an already-absent owned resource as success. The tier
phase runs **after** every fabric readiness wait, and the tier purge runs **before** lab removal, so
the removability run is a script invocation rather than a manual excavation. The teardown's first
step, *evidence*, is the **optional** capture `--preserve-evidence` asks for — through
`evidence_run`, of the state the teardown is about to remove; the audit export is not optional and
is not part of it (§16). The flag adds that capture and nothing else: **no step of the teardown or
of the tier purge deletes anything under the lab's evidence root**, `.evidence/<cluster>_<lab>/`,
with the flag or without it (FR-010, AD-64).

There is **one** lab profile. No flag selects a device profile, and no phase branches on one.

---

## 3. Existing upstream resources reused and the first-party fabric API

Exact API versions and fields come from one pinned release of each project. Upstream Kinds below are
the logical contract; the implementation must verify them from the project's **own** pinned
artefacts. No CRD or API service may be installed into an upstream project's API group unless it is
that project's own pinned, unmodified artefact, and the provisioning script MUST fail rather than
fall back to a first-party look-alike (FR-098).

### First-party fabric API

**Group/version** `fabric.agentic-netops.io/v1alpha1`. Structural OpenAPI schemas; no
`x-kubernetes-preserve-unknown-fields` on `spec`.

| Resource | Purpose | Required state |
|---|---|---|
| `Fabric` | The fabric design: node roles and platforms, underlay addressing and ASN plan (as references to allocation indices), the fabric-wide overlay AS, route-reflecting spines, MTU policy, and the site inventory of attachable access ports | Exactly one per fabric; `Accepted` and allocations bound. What a `Network` waits on is that the `Fabric` **exists and is Accepted** — never its `Ready`, which is the fabric's own report and gates no service (§19, AD-55) |
| `Network` | The service intent object: `vlans`, `bridgeDomains`, `routers`, `accessLists`, `attachments`. One per service; the only object the intent tier writes | Accepted and every derived per-device `Config` Ready, with two-sided read-back passing (FR-100) |

There is **no `NetworkDevice` Kind**: the per-(service, node) object is the device-configuration
layer's own `Config`. There is no second fabric-intent API (FR-013).

**Admission fails closed (FR-034, AD-52).** The cross-object rules on a `Network` — attachment
resolvability, one owner, one tagging mode, binding exclusivity, the standalone list's subinterface
and qualification — live in a validating webhook the provider serves, registered
`failurePolicy: Fail` on `CREATE` and `UPDATE` and never on `DELETE`
([contracts/crd-api.md](./contracts/crd-api.md)). While the provider is down no `Network` is
created or updated, so no object exists that those rules have not seen; a delete is not intercepted
and waits on the finalizer (§19). A create refused for that reason is a failure of the cluster API
dependency, not a validation refusal, and carries no reason code from §18 — no object exists to
carry one.

**What it evaluates (AD-61).** The rules are about what a `spec` says, so the webhook evaluates them
on a `CREATE` and on an `UPDATE` that **changes `spec`** — and admits, with no rule evaluated, an
`UPDATE` that leaves `spec` unchanged (a finalizer added or removed, a label, an annotation, the
force-release annotation included) and any `UPDATE` of an object carrying a deletion timestamp.
Finalization's last step, the force-release of FR-103 on a device that has left the `Fabric`
inventory, and the deletion of a service whose attachment no longer resolves are therefore never
refused by the platform's own webhook. The exemption is the handler's first step, the registration
is unchanged, and the guard on the force-release annotation — the admission policy
`deny-tier-force-release` and the provider's honouring rules (§19) — is untouched
([contracts/crd-api.md](./contracts/crd-api.md)).

### Allocation authority (KUID)

**As decided (AD-74)**: G11 failed on the pinned `kuid-server v0.0.13` (2026-09-21) and the lock
selects the first-party substitute (`allocationAuthority.kind: first-party`, §23), which is what runs
on this lab and on which G11 passed. The kuid resources below are the documented alternative the lock
can select (CD-03), never installed beside the substitute; the claim semantics are the same on both
sides of the `pkg/kuid` seam.

Aggregated APIServices served by `kuid-server`, not CRDs. Pinned at `v0.0.13`.

| Resource | Purpose | Claimed by | Required state |
|---|---|---|---|
| `infra.kuid.dev/v1alpha1` `Node`, `Link`, `Endpoint` | Node, link and endpoint inventory, aligned with the containerlab topology | — (inventory) | All expected nodes and links resolved |
| `ipam.be.kuid.dev/v1alpha1` `IPIndex` / `IPClaim` / `IPEntry` | System loopback and point-to-point link address pools | The `Fabric` reconciler | Unique and bound |
| `as.be.kuid.dev/v1alpha1` `ASIndex` / `ASClaim` / `ASEntry` | Per-leaf underlay AS numbers and the shared spine AS | The `Fabric` reconciler | Unique and bound |
| `vlan.be.kuid.dev/v1alpha1` `VLANIndex` / `VLANClaim` / `VLANEntry` | Service VLAN identifiers, **allocation band `1000–4000`** (`minID`/`maxID` on the index); the **naming band `100–999`** is outside the index and holds no claim (AD-33) | The tier's allocator agent, when the operator names no VLAN; once the service is submitted the **`Network` reconciler adopts the claim and is what releases it** (FR-109, AD-16, AD-32). A VLAN an operator names is claimed by nobody | Unique and bound |
| `genid.be.kuid.dev/v1alpha1` `GENIDIndex` / `GENIDClaim` / `GENIDEntry` | L2VNI and L3VNI identifiers, 32-bit index, allocation band 10000–20000 | The tier's allocator agent on the tier path; the **`Network` reconciler** for a `Network` applied with cluster tooling, for exactly the value it states (FR-109) | Unique and bound |

The route-target index is **removed** from the claim profiles: route targets are rendered from the
fabric-wide overlay AS and the VNI and are never claimed (§11, RD-09). The allocation authority is
dormant upstream; it is reused unchanged behind a qualification item and a named first-party
fallback decided at P0 (R-31), never silently — and that fallback was adopted, recorded, when G11
failed on it (AD-74).

### Device-configuration layer

| Resource | Group/version | Purpose | Required state |
|---|---|---|---|
| `Schema` | `inv.sdcio.dev/v1alpha1` | The pinned YANG bundle: the device vendor's native models plus the layer's own deviation patch, each pinned by tag or commit and never by branch; the patch repository's locked commit is served from an in-cluster git mirror in `sdc-system`, asserted equal to the lock, under a tag named after the commit (AD-75), and the same mirror serves the first-party deviation module at a content-pinned tag (AD-82 `2026-09-21-feature-guarded-must`). With the rest of the onboarding set it lives in `agentic-netops-system` (AD-82 `2026-09-21-target-namespace`) | Loaded and Ready; version matches the image |
| `TargetConnectionProfile` | `inv.sdcio.dev/v1alpha1` | gNMI transport, port, encoding, TLS and credential policy | Ready; Secret references resolve |
| `TargetSyncProfile` | `inv.sdcio.dev/v1alpha1` | Running-state synchronization policy | Ready |
| `DiscoveryVendorProfile` | `inv.sdcio.dev/v1alpha1` | How version, platform, hostname and serial are learned from the device | Ready |
| `DiscoveryRule` | `inv.sdcio.dev/v1alpha1` | Resolves the four lab targets from fixed management addresses and host names | Ready; produces the expected targets |
| `Target` | `inv.sdcio.dev/v1alpha1` | Management endpoint and schema selection | Ready before rendering applies |
| `Config` | `config.sdcio.dev` (storage version `config`; `v1alpha1` served) | Scoped per-(source object, device) generated intent | Validated, Applied, Ready |
| `ConfigSet` | `config.sdcio.dev` | Identical label-selected shared snippet | Used only when genuinely identical |
| `RunningConfig` / `TargetRunning` | `config.sdcio.dev` | The device's observed running configuration | Synchronized |
| `Deviation` | `config.sdcio.dev` | Intended-versus-running difference, typed `UNHANDLED`, `NOT_APPLIED` or `OVERRULED` | Empty for platform-owned paths when converged; actionable when present |
| `ConfigBlame` / `TargetBlame` | `config.sdcio.dev` | Per-leaf intent ownership and provenance of configured paths | Resolves to this platform's generated intent and no other |
| `Subscription` | `inv.sdcio.dev/v1alpha1` | Optional telemetry selection and export | **Not** instantiated for device metrics the dedicated collector owns |

Clients MUST NOT assume `v1alpha1` is the `Config` storage version. The Kubernetes API server
performs no validation of `Config.spec.config[].value`; the meaningful dry-run of a rendered device
payload is the layer's own transaction dry-run or its offline schema validator (`sdc-lite config validate`, pinned in the lock file — AD-71), never a server-side
apply dry-run. `sdc-lite v0.4.0` refuses the observed module-prefixed identityref form inside a `must`, so it validates a prefix-normalised copy of a golden (the golden untouched, the defect named, a wrong-identity negative control); the layer's own validation always sees the true form (AD-81).

---

## 3a. The `Fabric` object

One per fabric, in `agentic-netops-system`. It is the fabric design and the allocation authority's
consumer; it is not a service and carries no tenant intent.

```yaml
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Fabric
metadata:
  name: fabric01
  namespace: agentic-netops-system
spec:
  nodes:
  - {name: spine01, role: spine, platform: ixr-d3l, systemIPv4: 10.0.0.11/32, asn: 65100, routeReflector: true}
  - {name: spine02, role: spine, platform: ixr-d3l, systemIPv4: 10.0.0.12/32, asn: 65100, routeReflector: true}
  - {name: leaf01,  role: leaf,  platform: ixr-d2l, systemIPv4: 10.0.0.1/32,  asn: 65101}
  - {name: leaf02,  role: leaf,  platform: ixr-d2l, systemIPv4: 10.0.0.2/32,  asn: 65102}
  underlay:
    addressFamilies: [ipv4, ipv6]
    # kuid-form references; provisioning rewrites group, kind and namespace to the authority the lock selects —
    # on this lab fabric.agentic-netops.io IdentifierPool in agentic-netops-allocation (AD-74), names unchanged
    loopbackPoolRef: {group: ipam.be.kuid.dev, kind: IPIndex, name: fabric01-loopback, namespace: kuid-system}
    linkPoolRef:     {group: ipam.be.kuid.dev, kind: IPIndex, name: fabric01-p2p,      namespace: kuid-system}
    asnPoolRef:      {group: as.be.kuid.dev,   kind: ASIndex, name: fabric01-underlay, namespace: kuid-system}
  overlay:
    fabricASN: 65000                      # the RT constant; never a per-leaf ASN
    routeReflectors: [spine01, spine02]
    interASVPN: true                      # rendered as inter-as-vpn on every reflecting spine; checked declared = read back (AD-77)
    reflectorClients: true                # the default; false is SC-004's declarative negative control (AD-77)
    tunnelInterface: vxlan0               # fabric constant
  mtu:
    portMTU: 9412                         # /interface[name]/mtu on every port the fabric owns: fabric links and access ports (AD-82 2026-09-21-access-port-mtu)
    underlayIPMTU: 9398                   # routed subinterface ip-mtu
    bridgedL2MTU: 9412                    # bridged subinterface l2-mtu, on every bridged service subinterface
    tenantIPMTU: 9348                     # portMTU − 64; ip-mtu on every routed ip-vrf subinterface and irb0.<vlan>; also the endpoint interface MTU
  inventory:
  - {node: leaf01, accessPorts: [ethernet-1/1], fabricPorts: [ethernet-1/49, ethernet-1/50]}
  - {node: leaf02, accessPorts: [ethernet-1/1, ethernet-1/2], untaggedAccessPorts: [ethernet-1/2], fabricPorts: [ethernet-1/49, ethernet-1/50]}
  - {node: spine01, accessPorts: [], fabricPorts: [ethernet-1/1, ethernet-1/2]}
  - {node: spine02, accessPorts: [], fabricPorts: [ethernet-1/1, ethernet-1/2]}
  # `untaggedAccessPorts` is a subset of the entry's accessPorts (AD-68); leaf02 ethernet-1/2 — client02's
  # second link — is the lab's one untagged access port, where an ip-vrf naming no VLAN lands (AD-51;
  # live-findings 2026-09-26-t151r7, decided under AD-82)
  maintenance: []          # optional; e.g. [{node: leaf01, interface: ethernet-1/49, adminState: disable}]
status:
  observedGeneration: 1
  lastVerifiedTime: null   # the last scheduled re-verification that ran — completed its read-back, whatever it found (FR-107)
  allocations: []          # claim references for every loopback, link prefix and ASN
  renderedConfigs: []      # one per node, priority 10
  findings: []             # durable force-release records (FR-103); see below
  conditions: []
```

| Field | Validation | Meaning |
|---|---|---|
| `spec.nodes[].role` | enum `leaf` \| `spine`; at least one of each | Decides what the fabric reconciler renders and what may carry an attachment |
| `spec.nodes[].platform` | enum of licence-free emulated types carrying the full EVPN-VXLAN feature set | A type without VXLAN is refused for any role |
| `spec.nodes[].systemIPv4` | `/32`, unique; may be omitted and claimed from `loopbackPoolRef` | The VTEP source and BGP router-id; the only tunnel source the platform supports |
| `spec.nodes[].asn` | unique per leaf; identical across spines; may be claimed from `asnPoolRef` | The underlay AS. It is **never** the route-target AS |
| `spec.nodes[].routeReflector` | boolean; only on a `spine` | A reflecting spine that is not a tunnel endpoint reflects EVPN routes to its `route-reflector client`s; it carries `overlay.interASVPN` and `overlay.reflectorClients` as declared. That it needs `inter-as-vpn` to reflect was not reproduced on SR Linux 25.7.1 — reflection continued without it (G8, AD-77) |
| `spec.underlay.addressFamilies` | non-empty subset of `ipv4`, `ipv6`; both by default | Dual-stack underlay and tenant families. The VXLAN tunnel endpoint stays IPv4 |
| `spec.overlay.interASVPN` | boolean; `true` on the default `Fabric`. **`false` is accepted** — no CEL or webhook rule refuses it on a reflecting spine, and none warns | Rendered as `inter-as-vpn` on every reflecting spine, as stated, and checked by the configuration-integrity invariant below as declared equals read back (`false` declared and read back `false` is consistent). As decided (AD-77) it is **not** SC-004's negative control and not a convergence rule of its own: with `inter-as-vpn` removed the spines still reflected on SR Linux 25.7.1 (G8 observation `interASVPNRemovedReflectionContinues: true`), so that control is `spec.overlay.reflectorClients` |
| `spec.overlay.reflectorClients` | boolean; default `true`. **`false` is accepted** — no CEL or webhook rule refuses it on a reflecting spine, and none warns | Rendered as `route-reflector client` on every reflecting spine's overlay group, as stated (`false` is rendered as `false`, never dropped). `false` is the **declarative** way to withdraw reflection, which is what the route half of SC-004 uses as its negative control (AD-43's mechanism, its field replaced as decided in AD-77; G8 observed it stop reflection, `reflectorClientsFalseStopsReflection: true`): every session stays established, the spines reflect nothing, and each spanning `Network` reports `Ready=False/RoutesMissing` at its next re-verification. The `Fabric` stays truthful while it is `false`: `Ready=False/NotConverged` naming each reflecting spine and the setting, because a fabric whose reflectors are declared not to reflect is not converged; setting it back to `true` restores both |
| `spec.overlay.fabricASN` | required, immutable after apply | The one constant every route target is rendered from |
| `spec.overlay.tunnelInterface` | fixed `vxlan0` | Fabric constant; keeps golden files stable |
| `spec.mtu.*` | within the platform envelope; `tenantIPMTU == portMTU − 64` | §20 |
| `spec.inventory[].accessPorts` | port names in the device's own naming; disjoint from `fabricPorts` | The only ports an attachment may name. A spine has none. **The fabric's priority-10 `Config` owns each one's port-level leaves** — `admin-state` (`enable`, or `disable` from `maintenance[]`) and `vlan-tagging` — and, once per leaf, `irb0`'s own `admin-state`, so that no two service `Config`s ever share a leaf (FR-015, AD-68). An access port's **oper-state is not a `Fabric` Ready invariant** — a host being attached is no part of the fabric design; it stays the attaching service's, through its subinterface |
| `spec.inventory[].untaggedAccessPorts` | optional; a subset of the same entry's `accessPorts`; empty by default | The **declared tagging mode**. A port listed here renders `vlan-tagging false` and carries one untagged attachment (subinterface `0`, no `vlan` container); every other access port renders `vlan-tagging true` and carries tagged attachments only. An attachment must ask for the mode its port declares (§20). A change that would flip the mode of a port any `Network` still attaches to is `Accepted=False/InvalidIntent` naming the port and the services, the last rendered `Config` left as it was (AD-68) |
| `spec.maintenance[]` | optional; `node` and `interface` must name a port in `spec.inventory` (access or fabric); `adminState` enum, today only `disable`; at most one entry per (node, interface) | The **declarative** way to take a port out of service — for maintenance, and for the link-failure step of the acceptance suites. The fabric reconciler renders `/interface[name]/admin-state disable` into that node's priority-10 `Config`; removing the entry restores `enable`. It is the only administrative-state knob the platform has, it is rendered through the one southbound like everything else, and the `Fabric` stays truthful while it is set: `Ready=False/NotConverged` naming the sessions the disabled port took down |

Conditions: `Accepted`, `Rendered`, `Validated`, `Applied`, `Ready`, `Degraded` (§18 — the one
closed set; there is no `Allocated` condition: an underlay claim that is not yet bound is a
dependency wait under `Accepted`, and one the authority refuses is `Accepted=False/AllocationConflict`).
`Ready=True` requires every node's fabric `Config` applied at priority 10 **and**, read back from
device state (sampled by the device metric collector, as decided in AD-82 `2026-09-21-state-source`): interfaces and subinterfaces up; every underlay and overlay session `established`
(`…/protocols/bgp/neighbor[peer-address=<ip>]/session-state`) with the EVPN family negotiated on
each overlay session
(`…/neighbor[peer-address=<ip>]/afi-safi[afi-safi-name=srl_nokia-common:evpn]/oper-state == up`, a
`config false` leaf whose model description is "Negotiated operational state of the address family
is up"); and, keyed to the loopbacks the `Fabric` itself allocated, every **other** node's
`system0.0` address present and `active` in this node's route table
(`/network-instance[name=default]/route-table/ipv4-unicast/route[ipv4-prefix=<remote /32>][route-type=bgp][…]/active`,
and the `ipv6-unicast` equivalent where the family is enabled) — which is what User Story 1 scenario
2 promises and what would otherwise leave a policy-less eBGP underlay invisible. `inter-as-vpn`
**and** `route-reflector client` are read back from every reflecting spine and must equal what the `Fabric` declares (`overlay.interASVPN`, `overlay.reflectorClients`); a spine whose read-back differs is
`Ready=False/NotConverged` naming that spine and the setting, and a `Fabric` that itself declares
`overlay.reflectorClients: false` is `Ready=False/NotConverged` naming each reflecting spine and the setting whatever the device reads (AD-43's mechanism, its field as decided in AD-77; `overlay.interASVPN: false` is no convergence rule of its own). Both are **configuration**
leaves that SR Linux 25.7.1 does not mirror into state, so they are read from the **configuration datastore** — the node's
running configuration through the device-configuration layer, as decided (AD-76) — which shows the setting is applied on the device, not that reflection works: they are
a **configuration-integrity** invariant, never applied-side behavioural evidence (AD-31).
**It never counts EVPN routes** (FR-100, AD-23): the `Fabric` converges before any
service exists and after the gate's scratch instances are gone, so zero EVPN routes is then the
correct state, and a fabric-wide received-route count is not keyed evidence in any case. Route
exchange through the rendered fabric is an invariant of every `Network` that spans two leaves —
`Ready=False/RoutesMissing` names it there — and the behavioural proof that reflection works on this
image is the gate's G8, T051's post-render probe on the rendered fabric, and that first spanning
service. That read-back is
repeated at the re-verification interval (§25, FR-107): `status.lastVerifiedTime` advances on every
pass that ran — that completed its read-back, whatever it found (AD-54) — and a pass that finds an
invariant missing sets `Ready=False` naming it and advances the field all the same. A pass that
**could not run** — a required target unreachable, a read timed out — sets
`Ready=Unknown/VerificationFailed` and `Degraded=True/VerificationFailed` naming the target and
leaves `status.lastVerifiedTime` where it was (§18, FR-107, AD-40). `Network` status
carries the same field under the same rules.

### `status.findings[]` — the record that outlives a force-released service (FR-103)

Written by the provider when it honours a force-release (§19), because the `Network` it concerns is
about to stop existing and an Event expires.

| Field | Type | Meaning |
|---|---|---|
| `type` | enum, today only `StaleConfigurationPossible` | The device may still carry what the service rendered |
| `service` | `{namespace, name, uid}` | The force-released `Network` |
| `node` | `str` | The device that was unreachable |
| `identifiers` | `list[{kind, index, value}]` | Every allocation released without a read-back |
| `deviceObjects` | `list[str]` | The object names the service had rendered on that node — network instances, subinterfaces, tunnel interfaces, filters |
| `reason` | `str` | The operator's stated reason, copied from the annotation |
| `recordedAt` | `datetime` | |

Rules: a finding is appended once per (service UID, node); it is **removed only** after the `Fabric`
reconciler's scheduled re-verification has read that node and found every `deviceObjects` entry
absent from both the running and the state datastore (the device's state as the device metric collector samples it — AD-82 `2026-09-21-state-source`), and the removal publishes an Event. While a
finding is open, a `Network` whose render would produce one of its `deviceObjects` on that node is
`Applied=False/OwnershipConflict`. An open finding does not make the `Fabric` not-Ready; it sets
`Degraded=True/StaleConfigurationPossible` so that it is visible on the dashboards — from the first
pass that can read the fabric's targets again: while the target that occasioned the release is
still away the one `Degraded` condition carries `VerificationFailed`, and the finding is visible
in this list (§18's order, AD-54). Both of those
consequences — the refused render and degraded rather than not-Ready — are requirements, stated in
FR-103; this section states their shape.

**A finding whose node has left `spec.nodes`** — a force-release is honoured after the device has
been removed from the `Fabric` — can never be read clean, so it is never removed; it **stays in this
list as the record** and **does not count toward `Degraded`** while the node is absent, the device
being no part of the fabric that `Degraded` describes and no `Network` being able to attach to it.
If the node returns to the inventory the finding counts again from the first pass that runs, and
clears as any other does (AD-71).

---

## 4. *Retired: SRv6Service*

*Retired by the SR Linux retarget (RD-04) — no licence-free emulated type originates or terminates
an SRv6 service, and no release models explicit segment lists, steering policy or per-SID counters.*
*The Kind is not defined, not installed and not granted to any identity; FR-021 to FR-023 carry the
tombstones and [spec.md](./spec.md) §Deferred scope carries what would reopen it.*
*Evidence: [evidence/04-srv6.md](./evidence/04-srv6.md).*

---

## 5. Optional platform CRD: MigrationPlan

Disabled by default, and the mechanism is structural (AD-29): its CRD is generated under
`config/crd/optional/`, which the default kustomization does not include, and lab provisioning never
installs it; an operator who wants it applies that directory. Its controller lives in the provider
binary and registers **only when the CRD is served**, under a Role of its own — `get, list, watch`
and `status` updates on `migrationplans`, `get, list, watch` on `networks` — so it records and can
never create or modify a `Network`. It exists only for durable migration review, never for ongoing
device orchestration. Group/version `agentic-netops.io/v1alpha1`.

| Field | Type / validation | Meaning |
|---|---|---|
| `spec.source.platform` | enum `legacy-router` | Normalized legacy origin with no vendor coupling |
| `spec.source.serviceType` | The migration alias set | Selects an explicit mapping onto a construct |
| `spec.source.serviceID` | Non-empty, immutable | External correlation key |
| `spec.source.normalizedIntent` | Structural schema; raw CLI forbidden | Only fields the translator understands |
| `spec.targetNetworkRef.name` | DNS-compatible reference | The stable generated `Network` |
| `spec.mappingPolicy.allowLimitedEquivalence` | boolean, default false | Explicit opt-in for the point-to-point limited equivalence |
| `spec.mappingPolicy.cutover` | enum `manual`, `disabled` | No automatic live cutover |
| `status.construct` | One of the four constructs | The construct the service became |
| `status.sourceVocabulary` | The alias it arrived as | Recorded beside the construct, never instead of it |
| `status.unsupportedFeatures[]` | Structured code, field path, message | Exact non-mappable semantics |
| `status.generatedNetworkRef` | Object reference | The `Network` the translator's output was applied as — **recorded** once that object exists and validates; the controller never creates it |
| `status.perDevice[]` | Target, phase, reason, `Config` reference | Aggregated rollout evidence |

A `MigrationPlan` **references** the `Network`'s provenance annotations rather than restating them:
the annotations on the `Network` are the single provenance record for both construct provenance and
migration provenance (FR-046). What a plan adds is the pair `status.construct` plus
`status.sourceVocabulary` — the construct the service became alongside the source vocabulary it
arrived in — and the cutover evidence (FR-048). It has **no route-target, VLAN or VNI policy**: a
source route target is a source property the translator either maps onto the derived form of FR-012
or rejects as unmapped (FR-045); the field `preserveRouteTargets` the SONiC-era model carried is
removed, because a preserved route target cannot be expressed in a `Network` whose route targets
are `target:<fabricASN>:<vni>` by CEL rule (AD-29).

---

## 6. Construct

The closed set of things an operator can ask for. Not a runtime object: a vocabulary.

| Construct | Required variables | Optional | Renders |
|---|---|---|---|
| `vlan` | tenant, ≥1 endpoint each with a `vlan` | `acl` | A bridge-domain network-instance with bridged subinterfaces; no tunnel interface, no EVPN control plane, no route targets |
| `mac-vrf` | tenant, `l2vni`, ≥2 endpoints on one shared `vlan` (or 1 with a gateway) | `anycastGateway` (+ `l3vni`), `acl` | A bridge-domain network-instance, its bridged subinterfaces, a bridged VXLAN interface carrying the L2VNI, and an EVPN instance with explicitly rendered route targets; with a gateway, additionally the routed instance and the integrated-routing subinterface |
| `ip-vrf` | tenant, `l3vni`, `addressFamilies` with ≥1 prefix, ≥1 endpoint each with a `vrf` | `acl` | A routed network-instance, its routed subinterfaces, a routed VXLAN interface carrying the L3VNI, and an interface-less EVPN instance advertising the routed instance's route table |
| `acl` | tenant, `acl`, ≥1 endpoint | endpoint `vlan` | Filter objects and their subinterface bindings on the named nodes. **No overlay identifier is claimed** |

`routeTargets` are **derived and displayed, never asked for**: `target:<fabricASN>:<vni>` for both
halves. No route distinguisher is carried anywhere in the vocabulary — the device derives it from
the system loopback address and the EVPN instance identifier.

**Name resolution**: the key function lowercases and strips `-`, `_`, space, `.` and `+`, so
`IP-VRF`, `ip_vrf`, `MAC VRF` and `macvrf` are one key. An unknown key is refused with the four
construct names listed, in order.

**Aliases (input only, never emitted)**: the multipoint L2 alias, the point-to-point L2 alias and
the integrated L2/L3 alias fold to `mac-vrf`; the routed VPN alias folds to `ip-vrf`; plus the
convenience synonyms `l2vni`→`mac-vrf`, `l3vni`→`ip-vrf`, `accesslist`→`acl`. The fold records the
arrival vocabulary as provenance (§12).

**Wrong-construct variables**: every rejected combination names both the property and the construct
that carries it.

| On construct | Offending property | Refusal points at |
|---|---|---|
| `vlan` | `l2vni` | ask for a `mac-vrf` to extend it over the fabric |
| `vlan` | `l3vni` | ask for an `ip-vrf`, or a `mac-vrf` with an `anycastGateway` |
| `vlan` | `routeTargets` | a `vlan` is not advertised by EVPN |
| `vlan` | `anycastGateway` | only a `mac-vrf` carries one |
| `mac-vrf` | `l3vni` without `anycastGateway` | a `mac-vrf` carries an L3VNI only when it declares a gateway |
| `ip-vrf` | `l2vni` | ask for a `mac-vrf` with an `anycastGateway` to get both |
| `ip-vrf` | `anycastGateway` | belongs to the `mac-vrf` whose integrated-routing interface carries it |
| `acl` | `l2vni`, `l3vni`, `routeTargets`, `anycastGateway` | an `acl` binds to attachment subinterfaces; attach it to another construct to filter that service |

A construct or a gated property the qualification record does not show as qualified — egress
filtering is the named example — is refused at interpretation before any identifier is claimed
(FR-097).

---

## 7. ServiceRequest (conversation thread)

The durable operator-initiated conversation, persisted by the checkpointer and keyed by thread.

| Field | Type | Rules |
|---|---|---|
| `thread_id` | `str` | UUIDv4; the checkpointer key; scopes every stage's work |
| `correlation_id` | `str` | 32 lowercase hex — the trace identifier of the root span. Immutable once set. The join key |
| `principal` | `str` | The **authenticated** operator username (FR-102, §22) — set by the supervisor from the verified credential, never read from the request. Recorded on every audit event |
| `original_text` | `str` | The operator's request, verbatim. Treated as **data** at every use site |
| `workflow_status` | status enum | The closed set (§17) |
| `iteration_count` | `int` | Bounded by the iteration cap |
| `deadline` | `datetime` | Wall-clock bound; expiry is an explicit outcome, never a hang |
| `confirmation_1` | `Decision \| None` | Post-interpretation |
| `confirmation_2` | `Decision \| None` | Post-assignment; **without it nothing is submitted** |
| `claimed_ids` | `list[ClaimRef]` | Released on decline; may legitimately be empty (§11) |
| `interpretation` | `Interpretation \| None` | §8 |
| `assignment` | `NormalizedServiceIntent \| None` | §9 |
| `submitted_resources` | `list[ResourceRef]` | §15 |

`Decision` = `{decided: "confirm" | "decline", at: datetime, principal: str}`, where `principal` is
the username authenticated on the request that carried the decision — a thread continued under a
different credential records the different name, it does not inherit the first one.

A `ServiceRequest` exists only for an authenticated request: an unauthenticated one is refused
before a `thread_id` is minted, so there is no record of it here at all (FR-102, SC-042).

**State transitions**:

```text
RECEIVED_REQUEST ─► VALIDATED ─► MAPPED ──┬─(decline)─► FAILED*
                                          └─(confirm)─► ALLOCATED ──┬─(decline)─► FAILED*
                                                                    └─(confirm)─► APPROVED
APPROVED ─► PROVISIONING ─► CONFIGURED ─► VERIFIED ─► COMPLETED
  any ──(unsupported | unqualified | schema reject | worker failure | deadline | iteration cap)──► FAILED
  any ──(transport or state loss)──► STATUS_UNKNOWN
```

`FAILED*` on decline is a clean terminal state, not an error: the thread stays resumable so the
operator can amend and continue, and every claimed identifier is released first.

**Invariant**, enforced in the submission stage and not merely in routing: submission is refused
unless the status is approved **and** the second confirmation is a confirm. This is what makes the
"zero fabric changes without a recorded confirmation" criterion hold even if the text-driven
routing misclassifies a reply.

---

## 8. Interpretation

The mapper's output — the artifact the operator confirms first, and the published schema. Full
JSON Schema in [contracts/interpretation.schema.json](./contracts/interpretation.schema.json).

| Field | Type | Rules |
|---|---|---|
| `service_id` | `str` | A DNS-1123 label of ≤15 characters — lower-case alphanumerics and `-`, **no dot** (§20); unique per thread. The pattern is in the schema, because the identifier becomes the `Network` name and part of every claim name (AD-56). **How it is generated — the one statement of the rule (AD-61)**: by the mapper's own code, never by the model and never from the tenant or any other field of the request — the first **15 characters of the lower-case hexadecimal form of a random (version 4) UUID**, so 15 characters of `[0-9a-f]`, a DNS-1123 label of exactly the schema's `maxLength` whatever the tenant is called. It is opaque: the tenant and the construct are read from the object's annotations, never from its name. Every example identifier in these artifacts that stands for a tier-generated one has this shape; the hand-authored translator inputs of §9's schema examples (`svc-vlan-01` …) are the CLI path's and need only satisfy the pattern |
| `service_type` | construct enum | `vlan` \| `mac-vrf` \| `ip-vrf` \| `acl`, **after** alias folding. A retired name never appears here |
| `source_service_type` | `str \| None` | The alias the request arrived as; `None` when the operator named a construct |
| `tenant` | `str` | RFC 1123 label; required, never defaulted |
| `endpoints` | `list[EndpointIntent]` | `len >= 1`; the per-construct minimum lives in validation, not in the schema floor |
| `anycast_gateway` | object \| `None` | Present only on `mac-vrf`; at least one address family; an unrequested family is never added |
| `acl` | object \| `None` | Required when the construct is `acl`; optional on any other construct |
| `ipv4_prefixes` / `ipv6_prefixes` | `list[str]` | For the routed construct |
| `bandwidth` / `sla` | `str \| None` | Optional; absence is not a blocker |
| `missing_fields` | `list[str]` | Non-empty ⇒ a clarification request, not an interpretation |
| `unsupported_properties` | `list[str]` | Non-empty ⇒ a rejection with the properties named; **no partial assignment may follow**. A construct or a gated property the qualification record does not show as qualified is named **here** (FR-097) — the schema is closed (`additionalProperties: false`) and has no separate list for it (AD-59) |

**Validation rules**: `missing_fields` and `unsupported_properties` are
each terminal and mutually exclusive — routing onward while either is non-empty is forbidden. An
unqualified construct or property is an `unsupported_properties` entry naming it, refused before
anything is claimed; what tells the operator *why* is the refusal's wording and the audit event's
`reason` (§16), never a third list. A
construct outside the enum is a rejection, never a coercion. The model is filled by structured
extraction; the model never emits free-form instructions the platform acts on.

**What an interpretation must state to the operator before the first confirmation**, because the
platform will not let either fact be learned from the fabric instead:

- **Evaluation order.** Access-list rules are evaluated in **ascending priority number, first match
  wins**; the priority the operator wrote is the number the device shows; the usable range is
  1–65534 and the last position is reserved for the default action (FR-039).
- **The implicit default.** When no default action is declared, unmatched traffic on the bound
  attachments **is accepted by the platform's own default**; the list is never described as
  restrictive beyond its explicit rules (FR-041).

**Carriage**: summary text plus the compatibility marker **and** a structured data part holding the
same object. The data part is authoritative; the marker is compatibility.

---

## 9. NormalizedServiceIntent (resource assignment)

The allocator's output — the artifact the operator confirms second, and **the one contract the
single translator consumes**. Go: the translator's service-input struct. Full JSON Schema in
[contracts/normalized-service-intent.schema.json](./contracts/normalized-service-intent.schema.json).

| Field (wire) | Type | Rules |
|---|---|---|
| `serviceId` | `str` | Carried from the interpretation; a DNS-1123 label of ≤15 characters, **no dot**; unique within a batch |
| `type` | construct enum | One of the four constructs **after** folding; the wire value is always canonical |
| `tenant` | `str` | Carried from the interpretation |
| `routeTargets` | object \| `None` | `{importRT[], exportRT[]}` — the wire names of this contract's schema, both required and each non-empty; the `Network` the translator emits from it carries the same values as `routeTargets: {import[], export[]}` ([contracts/network-spec.md](./contracts/network-spec.md) §1), and the two records' field names are not interchangeable (AD-66) — **derived** `target:<fabricASN>:<vni>`; required for `mac-vrf` and `ip-vrf`, forbidden on `vlan` and `acl`. **No route distinguisher is carried**: the device derives it as `<system loopback IPv4>:<EVPN instance id>` |
| `l2vni` | `int \| None` | Required for `mac-vrf`; forbidden elsewhere; from the allocation authority |
| `l3vni` | `int \| None` | Required for `ip-vrf` and for a gateway-bearing `mac-vrf`; from the allocation authority |
| `addressFamilies` | object \| `None` | Required for `ip-vrf`, ≥1 prefix across both families |
| `anycastGateway` | object \| `None` | Only on `mac-vrf` (§10 below) |
| `acl` | object \| `None` | On any construct; **required** when the construct is `acl` |
| `endpoints` | `list[Endpoint]` | Per-construct minimum in §10 |
| `policies` | object | The limited-equivalence opt-in — only meaningful for a point-to-point-sourced input |
| `unsupported` | object | Any present field is terminal and named |
| source type | Go-only, not serialized | Provenance (§12). Excluded from the canonical hash so the same service hashes identically in either vocabulary |

**Validation rules**

- **Strictness must match the Go side.** The Python model forbids extra fields because the Go
  parser rejects unknown fields; a laxer Python model would let a malformed object reach the
  translator and fail there instead of at the agent boundary — the opposite of what the
  local-rejection requirement asks for.
- No identifier may be locally generated. Every **allocated** VLAN — one in the allocation band
  `1000–4000` — and every VNI traces to a claim reference in the thread's claimed identifiers, and
  such a value without a backing claim is a validation failure. **Two kinds of VLAN are exempt,
  because nobody claims them**: a VLAN the operator named, which lies in the naming band `100–999`
  (§11, AD-33) — every `ip-vrf` attachment VLAN is one, none ever being allocated (AD-51) — and the
  VLAN a standalone `acl` names, which is a reference to another service's subinterface in either
  band (AD-47). A construct whose profile claims nothing legitimately has an empty list (AD-56).
- **Derived values are shown, not claimed.** Route targets, the EVPN instance identifier, the
  subinterface, tunnel-interface and integrated-routing indices and the network-instance names are
  reconstructable functions of an allocated value, the service identifier or a fabric constant, and
  MUST be shown in the assignment exactly as they will be rendered, so the second confirmation
  covers them too (FR-012, FR-062).
- The construct must equal the interpretation's construct; a mismatch is a contract violation
  between stages, reported as failed at the allocator.
- **Determinism**: the assignment is memoized on the thread state keyed by the hash of the
  interpretation. A repeat within the thread returns the stored object byte for byte, or reports
  that the service already exists.
- **Validation is all-or-nothing**: every cause is collected and returned together; nothing partial
  is ever emitted.

---

## 10. Endpoint, attachment point and anycast gateway

### Endpoint

An attachment point is **a node, a port and optionally a VLAN**. It resolves through the `Fabric`
site inventory to exactly one subinterface: `ethernet-1/N.<vlan>` when a VLAN is named, and
`ethernet-1/N.0` when none is.

| Field | Type | Rules |
|---|---|---|
| `node` | `str` | Required; must be a node the `Fabric` inventory has, and must not be a spine |
| `attachment` | `str` | Required; a port in the device's own naming (`ethernet-1/N`); must appear in that node's `accessPorts`; case and separators folded. It must be written in the operator's own text (`ethernet-1/1`, `eth1/1`, `e1-1`, `1/1`, matched by slot and port); one the text does not write is asked for and never supplied, even where the node has one access port (FR-059; AD-82 `2026-09-25-port-grounding`) |
| `vlan` | `int \| None` | Required for `vlan` and `mac-vrf`, **identical across every endpoint** — one bridge domain is one broadcast domain — named by the operator or, when none was named, allocated. Optional on an `ip-vrf` endpoint, where it is **named or absent and never allocated** (AD-51). Optional on an `acl` endpoint, where it names which existing subinterface to bind to |
| `vrf` | `str \| None` | Required for `ip-vrf` |

| Construct | Minimum endpoints | VLAN rule | Routed-instance rule |
|---|---|---|---|
| `vlan` | 1 | Required, shared | — |
| `mac-vrf` | 2, or 1 with an anycast gateway | Required, shared | — |
| `ip-vrf` | 1 | Optional per endpoint; a VLAN the operator **names**, from `100–999`, is the tagged subinterface, and absent means the untagged one — the allocator never allocates one (AD-51) | Required per endpoint |
| `acl` | 1 | Optional; absent means the untagged subinterface | — |

**Derivations**, fixed and reconstructable:

| Derived value | Rule |
|---|---|
| Subinterface index | `:= vlan` for a tagged attachment; `:= 0` for an untagged one |
| Subinterface name | `<port>.<index>`, e.g. `ethernet-1/1.100`, `ethernet-1/1.0` |
| Subinterface type | `bridged` for `vlan` and `mac-vrf` attachments; `routed` for `ip-vrf` attachments |
| Integrated-routing subinterface | `irb0.<vlan>` — the same number as the bridged subinterface index |

**Ownership rule: one owner per (node, port, vlan).** Two services asking for the same triple both
derive the same subinterface name, and a subinterface belongs to exactly one network instance.
That is a name collision detectable by string comparison at validation, before any device write, and
it is refused naming the service that holds the attachment. A second service may legitimately use
the **same physical port** at a different VLAN, including one bridged and one routed subinterface.

A port whose attachments require conflicting tagging modes — one service needing an untagged-only
port and another a tagged subinterface — is refused at the **interface** level, naming the port and
both services, because tagging is a per-interface property. This is FR-034's *one tagging mode per
port*: a CEL rule inside one object and a webhook rule across objects
([contracts/crd-api.md](./contracts/crd-api.md)), with the deployer's pre-flight refusing it before
anything is created (AD-20). Whether the pinned release accepts an untagged subinterface beside
tagged ones on one port was not observed in research, so the mix is refused rather than assumed.
**The mode itself is the `Fabric`'s declaration, not the first service's choice** (§3a
`untaggedAccessPorts`, AD-68): `vlan-tagging` is rendered by the fabric `Config`, an attachment must
ask for the mode its port declares, and the refusal lists the ports declared in the mode it asked
for — so the cross-object rule above is the backstop across a change of the declaration.

### AnycastGateway

The routed half of a `mac-vrf`. Its presence is what makes the service symmetric IRB; its absence
means no routed instance and no L3 identifier claimed at all.

| Field | Type | Rules |
|---|---|---|
| `ipVrf` | `str \| None` | The routed instance the operator meant; the translator emits one routed instance per service and points the gateway at it |
| `gatewayIPv4` | `str \| None` | An address with a prefix length; rendered as an anycast address on `irb0.<vlan>` |
| `gatewayIPv6` | `str \| None` | As above; must not be a link-local address |

At least one of the two is required; **both are never required**. An unrequested address family is
never added — a gateway naming only IPv4 configures only IPv4, and the service is not held to a
routed EVPN prefix route it never asked for. The legacy gateway spelling parses and is folded into
this shape, which then clears it; its own routed-instance field was a tenant-scoped label that never
named the router the translator emits, so only the addresses carry over.

**Fabric constants, not operator variables**: the anycast virtual-router-id is **1** on every leaf,
and the gateway MAC is derived from it rather than rendered. The integrated-routing subinterface is
always `irb0.<vlan>` and is attached to **both** the bridge domain and the routed instance.

---

## 11. ACL and ACLRule

A named, staged, address-family-scoped, ordered set of rules bound to the subinterfaces of its
service's endpoints.

| Field | Type | Rules |
|---|---|---|
| `name` | `str \| None` | A **label**, not an identity: defaulted from the service identifier, unique only within its own service, sanitised for the device's own name rule. An access list belongs to exactly one service and is withdrawn with it; a request naming an existing list instead of stating its rules is refused. The names the device reserves for its own filters are refused by name |
| `stage` | `str` | Required; `ingress` \| `egress` (folded from in/inbound and out/outbound). `egress` is refused at interpretation unless the qualification record shows egress filtering qualified on the pinned profile (FR-097) — on this fabric the record publishes `acl.egress` **unqualified** (the pinned data-server refuses the egress binding's `must` though the render satisfies it; G9 passed egress device-direct only), so `egress` is refused by name |
| `type` | `str` | Required; `ipv4` \| `ipv6`. Input spellings `l3`, `l3v6` and `ip` fold onto these. A Layer 2 (MAC) list is **refused as out of scope** — the construct is defined over address families, and admitting MAC would make the unit of binding exclusivity coarser for every service; a MAC or ethertype field, or a Layer 2 protocol, in a rule is refused with the same wording (AD-82 `2026-09-25-acl-layer2-refusal`). An unstated family is the one family the operator's own prefixes state or, with none, the ICMP version named; stating neither or both, it is asked for, never chosen (FR-059; AD-82 `2026-09-25-acl-family-inference`) |
| `rules` | `list[ACLRule]` | ≥1 required |
| `defaultAction` | `str \| None` | `permit` \| `deny`; when declared, rendered explicitly as a terminal match-all entry at the reserved last position, evaluated after every rule the operator wrote. When not declared, the confirmation states that unmatched traffic is accepted by the platform's own default. A default action is kept only when the operator's words state one ("the rest", "everything else", "all other traffic", default, unmatched, otherwise); otherwise it is dropped (FR-041, FR-059; AD-82 `2026-09-25-acl-default-grounding`) |

**Binding**: attachment subinterfaces only, resolved from node + port + optional VLAN. A request
asking to bind to a network instance, to a VLAN as such, to an integrated-routing interface or
fabric-wide is refused stating that the list binds to named attachments. A **standalone** list binds
only to a subinterface another service has already created; when none exists it is refused before
anything is created, naming the missing subinterface, and it never creates one itself.

**Unit of exclusivity**: `(node, port, subinterface index, direction, address family)`. An IPv4 and
an IPv6 list on one subinterface do not conflict; two services on different subinterfaces of one
port at the same stage do not conflict. A second list of the same family in the same direction on
one subinterface is refused naming the holder — the platform accepts one filter of a type per
subinterface per direction, so it is unsupported, not merely ambiguous.

### ACLRule

| Field | Type | Rules |
|---|---|---|
| `name` | `str` | Required; unique within the list. Carried into the rendered entry's description; the entry's identity is its priority. A rule the operator did not name gets a label derived from what it states (`permit-tcp-443`, made distinct by a suffix) — a label, not a service-defining value (AD-82 `2026-09-25-acl-rule-labels`) |
| `priority` | `int` | Required; **1–65534**; distinct within the list. Rendered **unchanged** as the device's entry sequence number. Rules are evaluated in **ascending** priority number and the first match wins. **65535 is reserved** for the default action; a rule claiming it is refused, stating the usable range. When **no** rule states a priority, the rules are numbered 10, 20, … in the order the operator stated them, and the first confirmation shows it (AD-82 `2026-09-25-acl-rule-labels`) |
| `action` | `str` | Required; `permit` \| `deny` (folded from allow/forward/accept and drop/block/discard). `permit` renders as the device's accept action, `deny` as its drop action |
| `protocol` | `str \| None` | `any`, an IP protocol number 0–255, or a known protocol name. **ICMPv6 (58) is accepted** |
| `sourcePrefix` / `destinationPrefix` | `str \| None` | CIDR; must match the list's family — a mismatched prefix is refused, not rendered as a rule that can never match |
| `sourcePort` / `destinationPort` | `str \| None` | A port or an inclusive `lo-hi` range, 0–65535, `hi >= lo`; **TCP and UDP only**, and only when the rule declares that protocol. A port of `0`, `0-0`, `0-65535` or `1-65535`, and a prefix of `0.0.0.0/0` or `::/0`, is how "any" is written and is treated as absent (AD-82 `2026-09-25-acl-any-placeholders`) |
| `description` | `str \| None` | Carried into the entry description |

Out of scope and refused by name: TCP flags, DSCP, TTL and hop limit, fragment matching, ICMP type
and code, logging, mirroring and rate limiting. Every refusal names the offending rule by index and
field.

### ClaimRef

| Field | Type | Note |
|---|---|---|
| `name` | `str` | The claim object name — **deterministic**, `<intent-namespace>.migr-<serviceId>.<role>` with role `vlan-<entry>` — entry being the name of the `vlans[]` or `bridgeDomains[]` entry, the only two places an allocated VLAN lives (AD-51) — `l2vni-<bridgeDomain>` or `l3vni-<router>`: the one scheme the provider names its own claims by, and one of the three things it adopts a claim on, VLAN and VNI alike (AD-32, AD-42; [contracts/kuid-claim-profiles.md](./contracts/kuid-claim-profiles.md) §5) |
| `namespace` | `str` | The allocation namespace — a claim must share a namespace with its index |
| `index_kind` / `index_name` | `str` | The index the claim draws from: a VLAN index or a generic-identifier index |
| `allocated_value` | `str \| int \| None` | Read from claim status — `status.id` at the pinned authority, with the claim `Ready`; `None` until allocated, and a claim that reports none is terminal for the request (G11) |
| `labels` | `dict[str, str]` | Written into the claim's **`metadata.labels`**, never the authority's own `spec.labels`: the aggregated API filters a label selector on object metadata, so a label written anywhere else is invisible to every claim-selector diff this design relies on (SC-026, SC-045, SC-046, AD-32). Carries the correlation identifier for a tier claim, the object namespace and name for one the provider created |
| `released_at` | `datetime \| None` | Set when the **tier** deletes it — on decline, on rollback, or for a request never submitted. Which correlation identifiers are still provisional is decided by the **deployer**, the only tier identity that may read a `Network`; the allocator deletes what it is told to and reads no `Network` (FR-075, AD-32). The claims of a submitted service are not the tier's to release: the provider adopts them and its finalizer releases them (FR-109, AD-16) |

Claim profiles per construct — `vlan` claims a VLAN only; `mac-vrf` a VLAN and an L2VNI;
`mac-vrf` with a gateway a VLAN, an L2VNI and an L3VNI, the VLAN in each case only when the
operator named none; `ip-vrf` an L3VNI **and never a VLAN** — its attachment VLANs are named or
absent (AD-51); `acl` nothing — are stated in full in
[contracts/kuid-claim-profiles.md](./contracts/kuid-claim-profiles.md).

Every claim carries the correlation label, which is what makes the decline check a single
label-selector query. **A construct whose profile claims nothing produces an empty list, and the
release path must treat that as success rather than a missing-claims error.** A VLAN the operator
named is not claimed and comes from the naming band `100–999`; one named outside it is refused
with both bands stated, **by the mapper at interpretation and before the allocator runs** — this
record never exists for it (AD-33, AD-41). The VLAN a standalone `acl` names is a reference to
another service's subinterface: it claims nothing and is held to neither band (AD-47).

---

## 12. Rendered `Network` and the provenance record

What the translator emits. Full shape and emission order in
[contracts/network-spec.md](./contracts/network-spec.md).

```yaml
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
spec:
  description: Service <id> (<construct>)
  vlans:          [ { name, vlan } ]
  bridgeDomains:  [ { name, vlan, l2vni, evpn.routeTargets, irb? } ]
  routers:        [ { name, routeTargets, l3vni, prefixes } ]
  accessLists:    [ { name, stage, type, defaultAction?, rules[] } ]
  attachments:    [ { node, attachment, vlan? , vrf? } ]
```

**Allocated identifiers are immutable once the object is accepted** (FR-109, AD-25):
`bridgeDomains[].l2vni`, `routers[].l3vni`, `vlans[].vlan` and `bridgeDomains[].vlan` carry CEL
transition rules (`self == oldSelf`, the lists being maps keyed by `name`, whose entries cannot be
renamed, added or removed after acceptance either). The refusal names the field and says that
changing it is a removal and a new service. `attachments[]`, `accessLists[]`, `prefixes` and the
gateway addresses stay mutable, **except that an attachment added to an accepted object may not
carry a VLAN in the allocation band `1000–4000` that the object does not already carry** — nothing
would claim it, and the object's claims are already fixed (AD-32, AD-33); an attachment carrying a
naming-band VLAN, or none, may still be added, and so may one carrying an allocation-band VLAN the
object already has in `vlans[]` or `bridgeDomains[]` — the only places an allocated VLAN lives, so the rule reads `spec` alone (AD-51) — the one-VLAN-per-bridge-
domain rule obliges a new attachment of a `vlan` or `mac-vrf` to carry the service VLAN, and where
that VLAN was allocated its claim is already adopted (AD-47). An `accessLists`-only object is outside the added-attachment rule, its attachment VLAN being a reference (AD-47, AD-56), and an `ip-vrf` — which carries no allocated VLAN at all — may gain only an attachment with a naming-band VLAN or none (AD-51). Adoption is decided **once per value**: an adopted claim stays in `status.claimRefs`, adopted and held, until finalization, whatever attachments are removed meanwhile, and is never re-evaluated. The fields of a `status.claimRefs[]` entry are listed once, in [contracts/crd-api.md](./contracts/crd-api.md) §Status.

| Construct | `vlans` | `bridgeDomains` | `routers` | `accessLists` | attachments carry |
|---|---|---|---|---|---|
| `vlan` | 1 | — | — | 0 or 1 | `vlan` |
| `mac-vrf` | — | 1 | — | 0 or 1 | `vlan` |
| `mac-vrf` + gateway | — | 1 (with `irb`) | 1 | 0 or 1 | `vlan` |
| `ip-vrf` | — | — | 1 | 0 or 1 | `vrf`, and `vlan` when the attachment is tagged — always a named VLAN (AD-51) |
| `acl` | — | — | — | 1 | neither, or `vlan` alone |

`routers[]` carries **no route distinguisher**: the device derives it. `routeTargets` on both
`bridgeDomains[].evpn` and `routers[]` are the derived, rendered values.

An access-list-only service emits access lists and attachments and nothing else — its attachments
carry no routed instance, and may carry a VLAN only to name which existing subinterface to bind to,
which is why the render-time "neither routed instance nor VLAN" error is conditional on the object
declaring no access lists.

The typed read side lives in `pkg/fabricapi` and keeps its tolerance discipline: an unknown shape
yields nil and a mistyped field is omitted rather than failing the decode, because the CRD is the
source of truth and the client must not drift from it.

### Provenance record

The **single** provenance record for both construct provenance and migration provenance is the set
of annotations on the `Network` (FR-046). No second record of the same fact exists; a
`MigrationPlan`, when used, references it.

| Annotation | Set when | Value |
|---|---|---|
| service type | always | The construct |
| source service type | The request arrived in a retired vocabulary | The alias it arrived as |
| limited equivalence | The point-to-point alias | The limited-equivalence marker |

**Services that converged before the vocabulary changed** carry a retired name in the service-type
annotation and have no source-service-type. Their stored record is **never rewritten** — no
converged service is written to for a naming change. Every read surface derives the construct from
the retired name using the same alias table and reports that, showing the stored value as
provenance.

All provenance keys must appear in the fixed emission order, or they are computed and then silently
dropped.

---

## 13. Device-side entities

What each construct becomes on an SR Linux node. Rendered by the provider into one `Config` per
(source object, node); validated and applied by the device-configuration layer. Every path below is
native.

| Construct | network-instance | interface / subinterface | tunnel-interface / vxlan-interface | bgp-evpn / bgp-vpn | integrated routing | access list |
|---|---|---|---|---|---|---|
| `vlan` | `vlan-<id>`, `type mac-vrf` | on an `ethernet-1/N` the fabric `Config` already renders `vlan-tagging true` and `mtu` = `portMTU` (AD-68, AD-82 `2026-09-21-access-port-mtu`): `subinterface <vlan>` `type bridged`, `single-tagged vlan-id <vlan>`, `l2-mtu` = `bridgedL2MTU` | — | — | — | optional, on this service's own subinterfaces |
| `mac-vrf` | `macvrf-<id>`, `type mac-vrf`, member `vxlan0.<l2vni>` | as above | `vxlan0` / `vxlan-interface <l2vni>` `type bridged`, `ingress vni <l2vni>`, `egress source-ip use-system-ipv4-address` | `bgp-evpn bgp-instance 1`: `encapsulation-type vxlan`, `vxlan-interface vxlan0.<l2vni>`, `evi <l2vni>`, `ecmp 8`; `bgp-vpn bgp-instance 1` with `route-target export-rt`/`import-rt` | — | optional |
| `ip-vrf` | `ipvrf-<id>`, `type ip-vrf`, member `vxlan0.<l3vni>` | `subinterface <vlan>` `type routed` with the attachment address and `ip-mtu` = `tenantIPMTU` (AD-82 `2026-09-21-access-port-mtu`), or untagged `subinterface 0` | `vxlan-interface <l3vni>` `type routed`, `ingress vni <l3vni>` | `bgp-evpn bgp-instance 1` with `evi <l3vni>`; `bgp-vpn bgp-instance 1` with both route targets | — | optional |
| `mac-vrf` + gateway | both `macvrf-<id>` and `ipvrf-<id>`; `irb0.<vlan>` is a member of **both** | as for `mac-vrf`, plus the IRB subinterface | both vxlan-interfaces, one bridged and one routed | both EVPN instances | `irb0.<vlan>`: `anycast-gw` container with `virtual-router-id 1`; each declared family's address with `anycast-gw true` (no `primary` leaf is rendered — the pinned layer refuses the empty-leaf encoding and the device makes the only IPv4 address primary, AD-82 `2026-09-24-irb-primary`); unsolicited neighbour learning, host-route population and EVPN advertisement enabled; explicit `ip-mtu` | optional |
| `acl` | — (never creates one) | — (never creates one; requires the subinterface to exist) | — | — | — | `acl-filter[name=acl-<id>-<stage>][type=<ipv4\|ipv6>]` with one entry per rule plus the reserved terminal entry, and `acl/interface[interface-id=<port>.<index>]` with an explicit `interface-ref` and the filter listed under `input` or `output` |

**Exact native paths** the provider renders, by object. The first four are rendered **by the
fabric `Config` at priority 10**, for every access port and once per leaf for `irb0`, because two
services would otherwise share them; everything after them is a service `Config`'s, at priority 20,
and lies beneath a list entry that service alone keys (FR-015, AD-68). Every generated `Config`
lives in `agentic-netops-system`; a service's carries no owner reference (AD-69).

```text
/interface[name=ethernet-1/N]/admin-state                                          (fabric Config; access ports)
/interface[name=ethernet-1/N]/vlan-tagging                                         (fabric Config; from the declared mode)
/interface[name=ethernet-1/N]/mtu                                                  (fabric Config; = portMTU on access ports too — AD-82 2026-09-21-access-port-mtu)
/interface[name=irb0]/admin-state                                                  (fabric Config; every leaf)

/interface[name=ethernet-1/N]/subinterface[index=<idx>]/type                      = bridged | routed
/interface[name=ethernet-1/N]/subinterface[index=<idx>]/admin-state
/interface[name=ethernet-1/N]/subinterface[index=<idx>]/vlan/encap/single-tagged/vlan-id
/interface[name=ethernet-1/N]/subinterface[index=<idx>]/ip-mtu                   = tenantIPMTU  (routed — AD-82 2026-09-21-access-port-mtu)
/interface[name=ethernet-1/N]/subinterface[index=<idx>]/l2-mtu                   = bridgedL2MTU (bridged — the same row)
/interface[name=ethernet-1/N]/subinterface[index=<idx>]/ipv4|ipv6/address[ip-prefix=…]
/interface[name=ethernet-1/N]/subinterface[index=<idx>]/ipv4/unnumbered/admin-state = disable  (stated beside an IPv4 address)
/interface[name=irb0]/subinterface[index=<vlan>]/anycast-gw/virtual-router-id
/interface[name=irb0]/subinterface[index=<vlan>]/ipv4/address[ip-prefix=…]/anycast-gw
/interface[name=irb0]/subinterface[index=<vlan>]/ipv4/address[ip-prefix=…]/primary   (NOT rendered — AD-82 2026-09-24-irb-primary)
/interface[name=irb0]/subinterface[index=<vlan>]/ipv4/arp/learn-unsolicited
/interface[name=irb0]/subinterface[index=<vlan>]/ipv4/arp/host-route/populate[route-type=dynamic]
/interface[name=irb0]/subinterface[index=<vlan>]/ipv4/arp/evpn/advertise[route-type=dynamic]
/interface[name=irb0]/subinterface[index=<vlan>]/ipv6/address[ip-prefix=…]/anycast-gw
/interface[name=irb0]/subinterface[index=<vlan>]/ipv6/neighbor-discovery/learn-unsolicited
/interface[name=irb0]/subinterface[index=<vlan>]/ipv6/neighbor-discovery/host-route/populate[route-type=dynamic]
/interface[name=irb0]/subinterface[index=<vlan>]/ipv6/neighbor-discovery/evpn/advertise[route-type=dynamic]
/interface[name=irb0]/subinterface[index=<vlan>]/ip-mtu

/tunnel-interface[name=vxlan0]/vxlan-interface[index=<vni>]/type                  = bridged | routed
/tunnel-interface[name=vxlan0]/vxlan-interface[index=<vni>]/ingress/vni
/tunnel-interface[name=vxlan0]/vxlan-interface[index=<vni>]/egress/source-ip      = use-system-ipv4-address

/network-instance[name=<ni>]/type                                                 = mac-vrf | ip-vrf
/network-instance[name=<ni>]/admin-state
/network-instance[name=<ni>]/description
/network-instance[name=<ni>]/interface[name=<port>.<idx>]
/network-instance[name=<ni>]/interface[name=irb0.<vlan>]
/network-instance[name=<ni>]/vxlan-interface[name=vxlan0.<vni>]
/network-instance[name=<ni>]/bridge-table/protect-anycast-gw-mac
/network-instance[name=<ni>]/protocols/bgp-evpn/bgp-instance[id=1]/admin-state
/network-instance[name=<ni>]/protocols/bgp-evpn/bgp-instance[id=1]/encapsulation-type
/network-instance[name=<ni>]/protocols/bgp-evpn/bgp-instance[id=1]/vxlan-interface
/network-instance[name=<ni>]/protocols/bgp-evpn/bgp-instance[id=1]/evi
/network-instance[name=<ni>]/protocols/bgp-evpn/bgp-instance[id=1]/ecmp
/network-instance[name=<ni>]/protocols/bgp-vpn/bgp-instance[id=1]
/network-instance[name=<ni>]/protocols/bgp-vpn/bgp-instance[id=1]/route-target/export-rt
/network-instance[name=<ni>]/protocols/bgp-vpn/bgp-instance[id=1]/route-target/import-rt

/acl/acl-filter[name=<F>][type=<T>]/description
/acl/acl-filter[name=<F>][type=<T>]/statistics-per-entry
/acl/acl-filter[name=<F>][type=<T>]/subinterface-specific                          (egress only)
/acl/acl-filter[name=<F>][type=<T>]/entry[sequence-id=<priority>]/description
/acl/acl-filter[name=<F>][type=<T>]/entry[sequence-id=<priority>]/match/…
/acl/acl-filter[name=<F>][type=<T>]/entry[sequence-id=<priority>]/action/accept|drop
/acl/acl-filter[name=<F>][type=<T>]/entry[sequence-id=65535]/action/accept|drop     (default action)
/acl/interface[interface-id=<port>.<idx>]/interface-ref/interface                  (the Config that renders the subinterface — always)
/acl/interface[interface-id=<port>.<idx>]/interface-ref/subinterface               (the same)
/acl/interface[interface-id=<port>.<idx>]/input|output/acl-filter[name=<F>][type=<T>]   (the Config of the service whose list it is)
```

**Derivations** (reconstructable, never separately allocated):

| Derived | Rule |
|---|---|
| EVPN instance identifier | `evi := vni` — the L2 instance from the L2VNI, the L3 instance from the L3VNI |
| Route targets | `target:<fabricASN>:<vni>` for both import and export, rendered explicitly. A device-derived route target uses the **per-leaf** underlay AS and would differ on every leaf, so it is never relied on |
| Route distinguisher | Left to the device: `<system loopback IPv4>:<evi>`, per-leaf unique. Never rendered |
| vxlan-interface index | `:= vni` |
| Tunnel interface name | Fabric constant `vxlan0` |
| Subinterface index | `:= vlan`, untagged `:= 0` |
| Integrated-routing subinterface | `irb0.<vlan>` |
| Network-instance names | `vlan-<serviceId>`, `macvrf-<serviceId>`, `ipvrf-<serviceId>`, sanitised |
| Filter name | `acl-<serviceId>-<ingress\|egress>`, sanitised |
| Entry sequence number | `:= priority`, unchanged |

### Read-back per construct

Readiness is two-sided for **every** construct (FR-100), and every applied-side read is keyed to
this service's own objects. A fabric-wide or device-wide count is never evidence: a stock node
already carries its own control-plane filters and its own state.

| Construct | Written side (`Config` Ready, no deviation, present in the **running** datastore) | Applied side (the **state** datastore, keyed — sampled by the device metric collector, AD-82 `2026-09-21-state-source`) |
|---|---|---|
| `vlan` | The network-instance, its bridged subinterfaces and their encapsulation, with **no** vxlan-interface and **no** bgp-evpn child | `/network-instance[name=<ni>]/oper-state == up`; `…/oper-down-reason` absent; `…/interface[name=<subif>]/oper-state == up` and its `oper-down-reason` absent; `/interface[name=<port>]/subinterface[index=<idx>]/oper-state == up`. **Nothing overlay-related is asserted** — a `vlan` has no overlay evidence and must not be held to any |
| `mac-vrf` | All of the above plus the bridged vxlan-interface, the EVPN instance with its `evi`, and both route targets | The `vlan` set, plus `…/vxlan-interface[name=vxlan0.<l2vni>]/oper-state == up`; `/tunnel-interface[name=vxlan0]/vxlan-interface[index=<l2vni>]/oper-state == up`; `…/protocols/bgp-evpn/bgp-instance[id=1]/oper-state == up`; `…/bgp-vpn/bgp-instance[id=1]/route-distinguisher/route-distinguisher-origin == auto-derived-from-evi` and both route-target origins `== manual`; once the service spans two leaves, `/tunnel-interface[name=vxlan0]/vxlan-interface[index=<l2vni>]/bridge-table/multicast-destinations/destination[vtep=<remote>][vni=<l2vni>]/destination-index != 0` with `not-programmed-reason` absent, and `/tunnel/vxlan-tunnel/vtep[address=<remote>]/index != 0` |
| `ip-vrf` | All of the routed-instance objects plus the routed vxlan-interface and the EVPN instance | `/network-instance[name=<ni>]/oper-state == up`; `…/vxlan-interface[name=vxlan0.<l3vni>]/oper-state == up`; `…/protocols/bgp-evpn/bgp-instance[id=1]/oper-state == up`; every declared prefix present in `…/route-table/ipv4-unicast\|ipv6-unicast` and, for a remote prefix, `route[…][route-type=bgp-evpn]/active == true` |
| `mac-vrf` + gateway | Both halves plus the IRB subinterface, its anycast addresses and its neighbour knobs | Both sets above, plus `/network-instance[name=macvrf-<id>]/interface[name=irb0.<vlan>]/oper-state == up` and `/network-instance[name=ipvrf-<id>]/interface[name=irb0.<vlan>]/oper-state == up`, each `oper-down-reason` absent, and `/interface[name=irb0]/subinterface[index=<vlan>]/ipv4\|ipv6/address[…]/anycast-gw` reflected in state with the gateway's own subnet present in the routed instance's route table |
| `acl` | The filter with every rendered entry and its action, the reserved terminal entry, the binding's `interface-ref` resolving to the intended base interface and subinterface index, and the filter listed under the declared direction | Per entry, keyed by `[name=F][type=T][sequence-id=S]`: the entry's TCAM cost non-zero in the **declared** direction on at least one forwarding complex, zero in the other, and non-zero as a single instance; the device's own per-subinterface view of this filter is **recorded, never judged** — SR Linux 25.7.1 mirrors no part of `/acl/interface` into state, so the binding is judged in running (written side) and shown applied by traffic at G9 (A4, AD-79, AD-82 `2026-09-21-acl-binding-state`); per-entry statistics readable and not incomplete. Gate once per node: ACL datapath programming complete |

The device reports its own derivations in the `*-origin` leaves, which is what makes the
route-distinguisher and route-target checks genuine applied-side assertions rather than a re-read of
the platform's own write. An unexpected auto-derived route-target origin means the render dropped
the route target and the service is about to fail to form silently.

Programming failure surfaces as **negative** leaves — a non-programmed reason present, or a
destination index of zero — rather than a mirror store. "Applied" therefore means: operational state
up, no non-programmed reason, and a non-zero destination or TCAM index, on every object the service
owns. Readiness never depends on passing traffic; dataplane enforcement is demonstrated separately
in acceptance (SC-041). Full access-list contract in
[contracts/acl-render-contract.md](./contracts/acl-render-contract.md).

---

## 14. Worker capability descriptor

A runtime-discoverable agent card. Discovery, not a hardcoded worker list.

| Field | Value | Note |
|---|---|---|
| `id` | `org/namespace/local_name` | Routable: the topic used by the server to register and by the client to address is derived from it |
| `name`, `description`, `version` | strings | |
| `skills` | list | One skill per worker: map a request, allocate a service, deploy a service |
| `capabilities` | object | Non-streaming, as the workers set |

The supervisor resolves a capability to a topic through the card at call time. Adding or replacing
a worker changes no supervisor code.

---

## 15. Fabric service resource (what the tier submits)

The only artifact the intent tier creates outside itself. **Owned and reconciled by the control
plane**; the tier creates it, stamps it, watches it, and may delete what it created.

| Kind | Group/version | Namespace |
|---|---|---|
| `Network` | `fabric.agentic-netops.io/v1alpha1` | `agentic-netops-intent` |

That is the whole list, and it is the tier's submission target only: a `Network` applied with
cluster tooling lives in the control-plane-owned `agentic-netops-services` (§2), which no tier
identity can write to. The tier's writer Role grants `networks` in its own namespace and nothing
else; there is no second Kind it can write, which is how the vocabulary and the tier's permissions
are kept in step.

Metadata stamped by the tier — metadata only, no schema change:

```yaml
metadata:
  labels:
    agentic-netops.io/correlation-id: "<32 hex trace id>"   # selectable join key
    agentic-netops.io/tier: intent
  annotations:
    agentic-netops.io/intent-thread-id: "…"
    agentic-netops.io/intent-principal: "…"              # the authenticated username (FR-102)
    agentic-netops.io/intent-submitted-at: "<RFC3339>"
    agentic-netops.io/intent-submitted-spec-sha256: "<64 hex>"   # FR-105; stamped once, last
```

**The submitted-spec hash** is the SHA-256 of the canonical JSON — keys sorted, no insignificant
whitespace, numbers in shortest round-trip form — of `spec` **as the server-side dry-run returned
it**, so it is the form a later read returns. The dry-run carries every other key; the apply is the
dry-run object plus this one annotation. The tier never updates a service, so the hash is written
exactly once. On every status or removal request the object is re-read:

| Live object | Tier's statement | Tier's writes |
|---|---|---|
| present, hash matches | the live state | none |
| present, hash differs | **modified outside the tier**, then the live state — never the remembered one | none |
| absent, and no tier removal is recorded for it | **deleted outside the tier** | none — never re-created |

Each of the last two emits an `out_of_band` audit event (§16) and increments the tier metric (§21).
A removal asked of a modified service is not executed by the turn that detects it: the modification
is stated at that request's first confirmation and removal proceeds only through both.

The label is what makes the reverse join a query and the rollback set exact and enumerable.
Annotations carry the audit fields, which are not query keys and may contain characters a label
value forbids. The tier never writes a translator key and never writes a provider key; the provider
writes nothing here at all (FR-101).

`ResourceRef` = `{apiVersion, kind, namespace, name, uid, ready: "True"|"False"|"Unknown"|None, reason: str|None}`.
`ready` is the `Ready` condition's **status string as the cluster reports it**, never a boolean — a
boolean cannot carry `Unknown` (§18, AD-40) and cannot tell `False/Deleting` (AD-53) from
`False/NotConverged` — and `reason` is that condition's reason code beside it, always present when
`ready` is `"False"` or `"Unknown"`. `ready` is `None` only before the watch has read a `Ready`
condition at all. The pair is what the deployer puts on every `progress` chunk
([contracts/supervisor-http.md](./contracts/supervisor-http.md)), unaltered by the supervisor
(AD-62). The watch itself resolves to a Ready object, a terminal failure, or a timeout — the
requirement is to report which of the three (FR-067); a removal's watch resolves as §17 states
(AD-63).

---

## 16. RequestTrace and AuditEvent

**RequestTrace** is not a stored model — it is the trace itself, rooted at the span whose trace
identifier *is* the correlation identifier. One trace per request spans every stage, worker call,
model call and the convergence watch. Reproducibility requires the prompt, the model identity and
the response to be recoverable from it, so each model-call span carries the model identity, the
prompt and the response as attributes — redacted through the same filter the credential-scan
criterion enforces.

**AuditEvent** is immutable and emitted for every confirmation, decline, submission, removal,
refusal and detected out-of-band change (FR-078):

| Field | Type |
|---|---|
| `event_type` | `"confirm" \| "decline" \| "submit" \| "refuse" \| "remove" \| "out_of_band"` |
| `correlation_id` / `thread_id` / `principal` | `str` |
| `at` | `datetime` |
| `resources` | `list[ResourceRef]` — empty for refuse and decline |
| `reason` | `str \| None` — the named unsupported or unqualified properties, or the refusal explanation |

`principal` is always the authenticated username (FR-102). **A request refused for want of a valid
credential emits no `AuditEvent`** — there is no principal to record, and an event without one would
falsify SC-042's reconciliation; it produces a structured log line and increments
`agentic_netops_agent_auth_refusals_total` (§21) instead. An `out_of_band` event (FR-105) carries the principal who
asked, the resource, `reason` = `modified` or `deleted`, and both hashes when the object still
exists.

**Where it lives** (FR-078, AD-18). The audit event is a **span event on the request trace**,
emitted by the process that decided it — the supervisor for a confirmation, a decline and a refusal,
the deployer for a submission, a removal and an out-of-band detection — through that process's one
exporter, and kept in the agent-analytics store (ClickHouse, §21). **That stored event is the
record**: it is kept there with no expiry for as long as the store exists, and exported by the
evidence capture **before anything removes the store** — `off.sh` and the tier's removal alike,
unconditionally; a failed export stops the removal, and only `--discard-audit-record`, printed and
recorded, goes past it (AD-24). The export is newline-delimited JSON, one object per stored row,
compressed, written through `evidence_run` under an identifier unique to the attempt so that a
re-run after a stopped removal adds an artefact instead of rewriting a hashed one (NFR-013, SC-040);
it fails when the store is present but unqueryable within `AUDIT_EXPORT_TIMEOUT_SECONDS` (§25), when
the query errors, when the artefact cannot be written or when it holds fewer rows than the store
reported; an absent store is skipped and an empty one exports an empty record (AD-36). After the
export the evidence file is the record. Because each event carries its principal, correlation
identifier, resource reference and submitted-spec hash, the stream half of SC-030 and SC-042
reconciles from that file once the store is gone — and it **is** reconciled from it: the audit
reconciliation has a file-source mode that reads the exported artefact and the usernames record
below and nothing else, and the removability run ends with it (AD-46); the half that compares the
stream against live objects runs before either is removed, and in the file-source mode is reported
as not run, never as passed. A removal's one `remove` event is emitted when the delete is
issued, whichever way the removal turn then ends (AD-63), so the stream's counts reconcile (SC-030)
whether the object was gone within the bound or is still held in deletion.

**A re-run: when it skips, when it adds** (FR-078, AD-36, AD-46 — stated here and nowhere else). A
removal that stopped — on a blocked finalizer, on the fallback to the refusal — is re-run, and the
export step then does one of two things. It **skips** the export where the lab's evidence already
holds a **verified** one, and captures the skip through `evidence_run` as a record of its own,
naming the artefact it relied on. Otherwise it **adds** an artefact under a new attempt identifier.
It never rewrites one. An earlier export is *verified* when all three hold: its evidence record
carries exit status zero and a written-row count equal to the row count the store reported at the
time, beside **the newest stored row's timestamp as the store reported it then** (recorded as
absent for an empty store); the artefact's content hash still equals the hash that record carries (the SC-040 post-edit
check, applied to one file); and the store, asked again now, reports that same row count **and
that same newest-row timestamp** — so an
export taken before the tier was re-provisioned and wrote again is not verified, and a new one is
added beside it. The timestamp is what tells one store from another: the lab's evidence root
outlives a teardown — `off.sh` deletes nothing under it, with `--preserve-evidence` or without
(§2, FR-010, AD-64) —, a lab re-created under the same cluster and lab names looks there too, and a
fresh store that happens to hold as many rows as an earlier lab's export would otherwise be
skipped and then destroyed unexported. A count alone is not the store's identity; the count and
the newest row's time together are, with no number invented for it (AD-55). A store that cannot be asked within `AUDIT_EXPORT_TIMEOUT_SECONDS` is the failed
export above, not a skip. **Where the re-run looks**: `evidence_run`'s default directory is per
invocation (`.evidence/<cluster>_<lab>/<UTC run id>/`), so a re-run never finds the earlier
attempt in its own directory. It looks under the **lab's evidence root** — the parent,
`.evidence/<cluster>_<lab>/`, and an operator-set `EVIDENCE_DIR` besides — for export records whose
NFR-013 cluster and lab identity equal the live lab's; "this run's evidence" in AD-36 is the lab
run's, not the invocation's. The evidence identifiers are `audit-export-<attempt>` for the export
and `operator-usernames-<attempt>` for the record below, `<attempt>` being unique to the attempt.
**The artefact has one file name, stated here and nowhere else**: the export is
`<EVIDENCE_DIR>/audit-export-<attempt>.ndjson.gz`, beside the evidence record
`audit-export-<attempt>.json` that `evidence_run` writes for it and that carries its hash and row
count — which is the file quickstart §24 finds with `ls` and hands to the audit reconciliation's
file-source mode (AD-59).

**The usernames the run used** (SC-042, FR-078, AD-46). The `operator-credentials` Secret (§22) is a
tier artefact and goes with the tier, so SC-042 is never reconciled against the Secret alone. The
tier phase captures the Secret's `username` key — **never** `password` — through `evidence_run` on
every provisioning run, and the export step captures it again **before anything removes the
Secret**, on both down paths, and writes the usernames record beside the export: the distinct set
of usernames over this lab's captures, found the same way as above, and `username_unchanged`, true
exactly when that set has one member. **Who reads what**: while the tier is up the usernames record
of the removal that will end it does not exist yet — a record an earlier export left under the
lab's evidence root, by an earlier tier instance's removal or by the stand-alone export the
file-source mode is proven against, is a snapshot of the captures up to that export and is never
read for the running tier (AD-64) —, so the authentication audit derives the distinct set and its cardinality from the
tier-phase captures themselves; `username_unchanged` is a field of the record alone and is read
only by the file-source run that follows the export (AD-55). A set of more than one invalidates SC-042's measure for the
run and the record says so; it is never reconciled away. The **deployer** additionally
mirrors the three events it decides itself as Kubernetes Events in the intent namespace, because it
is the only tier identity that may publish Events (FR-075); the supervisor holds no cluster
permission and mirrors nothing. A Kubernetes Event expires and is never the record, and no
reconciliation reads one. The audit
reconciliation (SC-030) compares the stream against the resources the tier created **and their
submitted-spec hashes**: counts must be equal and any tier-originated resource without a matching
confirmation is a failure. An `out_of_band` event is **not** a violation — it is counted
separately, and the reconciliation additionally asserts that the tier wrote nothing after it.

---

## 17. Workflow status (closed set)

`RECEIVED_REQUEST`, `VALIDATED`, `MAPPED`, `ALLOCATED`, `APPROVED`, `PROVISIONING`, `CONFIGURED`,
`VERIFIED`, `COMPLETED`, `FAILED`, `STATUS_UNKNOWN`. The mapping onto the required minimum set is
in [research.md](./research.md) D-24. **No status outside this enum may appear anywhere**,
including in the operator stream and the chat surface.

**`STATUS_UNKNOWN` is never a success** (FR-054). It is the value for a request whose outcome the
platform cannot observe — the transport or the state store was lost mid-request — and it is
terminal only in the sense that the pipeline stops: it never satisfies a convergence watch
(FR-067), it is never counted as a converged request in the per-stage success rate (FR-092), and it
is never reported to the operator as a completed one. What the operator is told is that the outcome
is unknown, which dependency was lost (NFR-010), and that the live object is the record (FR-105) —
a status request re-reads it rather than repeating the remembered status.

The provider has the same third value one layer down, and the tier treats it the same way: a
`Network` reporting **`Ready=Unknown`** (§18 — its read-back could not run, FR-107) is **not** a
converged service. A convergence watch that sees it keeps watching (FR-067); a status answer built
from it says the service's readiness is unknown and names the target from the condition, never
"converged" and never "failed"; and it moves no request to `VERIFIED` or `COMPLETED`. It is a
condition on the object, not a workflow status, so it adds nothing to the enum above.

A `Network` that is being removed reports **`Ready=False/Deleting`** from the moment its
finalization starts (§18, AD-53), and the tier reads that reason rather than the bare `False`: a
status answer built from such an object says the service **is being removed** and repeats what its
`Deleting` condition says is outstanding — the unreachable target or the holding service, by name —
never "failed" and never "converged". It too is a condition on the object and adds nothing to the
enum.

**A removal asked of the tier has a watch of its own, and two endings** (FR-069, AD-63). After both
confirmations the deployer deletes the `Network` and watches until the object is **gone**, under the
same convergence timeout as a creation (§25). The request moves `APPROVED` → `PROVISIONING` and never
through `CONFIGURED` or `VERIFIED`, whose meanings — accepted by the API server, reported Ready — no
removal can have; its `progress` chunks carry `ready: "False"` with `reason: "Deleting"`. **Gone
within the bound is `COMPLETED`**: the removal was observed, not assumed from an accepted delete.
**Still present at the bound, the turn ends at `PROVISIONING`** — the one status of the set that says
a change was submitted and is not yet observed complete — and its final message says that the
removal is **in progress**, repeats what the object's `Deleting` condition says is outstanding (the
unreachable target or the holding service, by name), and says that it completes without operator
action when that ends — or by the force-release, which is never the tier's to set (FR-103) — and that
a status request reports it from the live object. That ending is never `COMPLETED`, never `FAILED`
and never `STATUS_UNKNOWN`: nothing failed and nothing was lost from view; and it is never counted
as a converged request (FR-092). No status is added for it. A **creation** watch that sees
`Ready=False/Deleting` — the object deleted under it — ends `FAILED` naming the deletion; no tier
removal being recorded for that object, it is reported as **deleted outside the tier**, with the
audit event and the counter of §15 (FR-067, FR-105).

---

## 18. Standard conditions

All platform-owned status uses Kubernetes conditions with `type`, `status`, `reason`, `message`,
`observedGeneration` and `lastTransitionTime`. Messages may aid humans; automation keys on the
reason codes.

| Condition | True when | False reason codes |
|---|---|---|
| `Accepted` | Schema and references are valid and every requested construct and property is qualified | `InvalidIntent`, `ReferenceNotFound`, `Unqualified`, `AllocationConflict` |
| `Translated` | A complete, non-lossy mapping exists. **`MigrationPlan` only** — the provider never sets it on a `Fabric` or a `Network` | `UnsupportedFeature`, `Collision` |
| `Rendered` | The provider emitted deterministic configuration for every affected node | `SchemaMismatch`, `MappingFailed`, `RegisterUncovered` |
| `Validated` | Every rendered path passed the pinned device schema | `YangValidationFailed`, `SchemaMismatch` |
| `Applied` | Every required device transaction was confirmed | `TargetNotReady`, `TransactionFailed`, `OwnershipConflict` |
| `Ready` | Applied state **and** both sides of the read-back pass (FR-100). **The one condition with three states**: it is `Unknown` — neither True nor False — when the read-back of an object that had reported Ready could not run (FR-107, AD-40) | `NotConverged`, `NotProgrammed`, `RoutesMissing`, `Deleting` (the object is being removed — AD-53); *(Unknown reason — the only one)* `VerificationFailed` |
| `Degraded` | Any required target or telemetry dependency is impaired | `PartialFailure`, `TelemetryUnavailable`, `VerificationFailed`, `StaleConfigurationPossible` (`Fabric` only) |
| `Deleting` | The object carries a deletion timestamp and finalization has not finished. **Polarity is deliberate: it is True while work remains**, and its reason says what is outstanding | *(True reasons)* `RemovingConfiguration`, `TargetUnreachable`, `HolderPresent`, `ForceReleased` |

Reason-code meanings that are not self-evident:

- **`Unqualified`** — the qualification record does not show this construct or this gated property
  (egress filtering is the named example) as qualified on the pinned image and emulated types.
  Nothing is created (FR-097).
- **`AllocationConflict`** — one of two things. A VNI the object names has no adoptable claim and
  the allocation authority refused a claim for it: the value is held by another owner, or lies
  outside the allocation band; the message names the value and the holder or the band. Or the
  object carries a **VLAN in the allocation band `1000–4000` that no adoptable claim backs** —
  which an `ip-vrf` attachment VLAN in that band always is, none ever being allocated (AD-51) —
  and the message names the VLAN and both bands (AD-33). Nothing is rendered and no other value is
  tried (FR-109). **It is an answer, never an error**: an allocation authority that errors or
  cannot be reached is a dependency wait, retried with backoff, and is not reported under this
  reason (AD-56).
- **`OwnershipConflict`** — a platform-owned path is reported overruled by a higher-precedence
  intent, or two configuration resources that can touch the same device leaf were given the same
  priority. Terminal until explicitly resolved; never a value to re-apply harder. It has one further
  use, which is **not** terminal: while a force-release finding is open on the `Fabric` (§3a,
  FR-103), a `Network` whose render would reproduce one of the device objects that finding names on
  that node is `Applied=False/OwnershipConflict`, the message naming the finding; it ends when the
  finding is cleared by a clean read-back, with no operator action on the `Network`.
- **`SchemaMismatch`** — the compatibility set on the resource does not match the one the target's
  schema was loaded from. No changed configuration is emitted and the last known valid applied
  intent stays intact.
- **`TargetNotReady`** — the device target, its credentials or its schema are not Ready.
- **`NotProgrammed`** — the configuration is in the running datastore but the device's own state
  reports it as not programmed, or with a zero destination or TCAM index. A remote VTEP's zero index
  is `NotProgrammed` only while the route it derives from is present; read with its IMET route evidence
  (the multicast destination to that VTEP) absent in the same pass, it is `RoutesMissing` (AD-82
  `2026-09-24-vtep-teardown`).
- **`TargetUnreachable`** (on `Deleting`) — configuration has been removed from every reachable
  target and the message names each target that is not — including a node whose `Target` is Ready
  but that the collector-based data-path probe finds with no sample within 30 s (AD-82
  `2026-09-24-delete-unreachable`). Every allocation is still claimed. There is
  no deadline on this state; it ends when the target returns and the removal is read back, or by a
  force-release (FR-103).
- **`HolderPresent`** (on `Deleting`) — another service's standalone access list is still bound to a
  subinterface this service owns; the message names the holder (FR-043).
- **`ForceReleased`** (on `Deleting`) — transient, set immediately before the finalizer is removed;
  the durable record is the `Fabric` finding (§3a).
- **`Deleting`** (the *reason*, on `Ready` — not to be confused with the condition of the same
  name, which it always accompanies) — the object carries a deletion timestamp. `Ready=False` with
  this reason is set **at once, when finalization starts** (§19; contracts/reconciliation.md Rule 8
  step 1), in every deletion and whatever the reachability of its targets: a service being removed
  is no longer offered, so nothing is read back to decide it. It stays until the object is gone.
  An object being deleted is never `Ready=True` and never `Ready=Unknown`, and
  `VerificationFailed` is never set on it — the re-verification schedule keeps it only to requeue
  the finalizer, and the `Deleting` *condition*'s reason (`TargetUnreachable`, naming each target)
  is what says a device could not be reached (FR-103, FR-107, AD-53).
- **`RoutesMissing`** — the required EVPN routes, remote tunnel endpoints or route-table entries for
  this service are absent although the sessions are established. The condition names the missing
  invariant and surfaces the device's own reason when it gives one.
- **`VerificationFailed`** — the read-back of an object that had reported Ready could not run
  against a required target: the target was unreachable or the read timed out, whether the
  scheduled re-verification found it so or the reconciler observed the target not Ready between two
  passes — or, on a `Network` Ready at its current generation with nothing written this reconcile,
  the layer no longer confirms its `Config` (AD-82 `2026-09-24-layer-before-target`), or the device
  metric collector holds no sample for the node (AD-82 `2026-09-21-state-source`). It sets **two** conditions at that pass, with no further wait: **`Ready=Unknown`** and
  `Degraded=True`, both with this reason and both naming the target; `lastVerifiedTime` does not
  advance. It never sets `Ready=False` — an outage is not evidence that an invariant is gone — and
  it never leaves `Ready=True` standing, because a `Ready=True` nobody could re-read is a prior
  reconciliation result, which constitution Principle I forbids reporting as current. The next pass
  that runs settles it: `Ready=True` if both sides pass, `Ready=False` naming the invariant if one
  is missing. It is the only reason `Ready=Unknown` ever carries, and `Ready=Unknown` is the only
  state it sets on `Ready` (FR-107, AD-40; it replaces the operator review's "`Ready` keeps its
  last observed value").

`Ready=True` is forbidden when any required target is not Ready: an object still converging stays
`Ready=False`, and one that had reported Ready becomes `Ready=Unknown/VerificationFailed` as above —
unless it is being deleted, which is `Ready=False/Deleting` from the moment finalization starts and
nothing else (AD-53). **"Had reported Ready" means at the current generation** (AD-62): an object
updated to a new generation whose `Applied` is not yet True is converging again — `Ready=False/NotConverged`,
because `Ready=True` requires current-generation `Applied` ([contracts/crd-api.md](./contracts/crd-api.md)
§Status contract) — and a target that cannot be reached leaves it there, with
`Applied=False/TargetNotReady` naming the target, **not** at `Unknown`, although it was Ready at the
generation before. `Unknown` says a read-back could not be repeated; for the new generation none
was ever made.
`Degraded=True` may coexist with `Ready=True` in exactly two cases, and the reason says which: a
**non-blocking telemetry failure** (`TelemetryUnavailable` — NFR-002; the telemetry path is never in
the configuration path), and, on the `Fabric` only, an **open force-release finding**
(`StaleConfigurationPossible` — FR-103 requires degraded, not not-Ready). The list is closed.
**`VerificationFailed` is never one of them**: it always arrives with `Ready=Unknown`. `PartialFailure`
is never one of them either, because partial success is never aggregate Ready (FR-018).

**One `Degraded` condition carries one reason, so the reasons have a total order** (AD-54, AD-62).
The first two follow `Ready` and so never compete: `PartialFailure` comes with the `Ready=False` of a
partial failure and `VerificationFailed` with `Ready=Unknown`. After them, on the `Fabric`,
`StaleConfigurationPossible`; and last, on either kind, `TelemetryUnavailable` — it is the reason
only when the telemetry dependency of NFR-002 is the **only** thing impaired, which is why it may
stand beside `Ready=True`. So on the `Fabric`: `VerificationFailed` > `StaleConfigurationPossible` >
`TelemetryUnavailable`. Both reconcilers set these reasons through T023's setter — `PartialFailure`
from the per-target aggregation, `TelemetryUnavailable` from the telemetry-health input they are
given and never from a device read (T040, T059; asserted by T028 and T054) — and a telemetry failure
changes no other condition (NFR-002). The order of the two that meet in a force-release is this: A force-release is honoured only while a target is unreachable, which is exactly
when the `Fabric` — that target being one of its own — is `Ready=Unknown` with
`Degraded=True/VerificationFailed`. While a required target cannot be read, **`VerificationFailed` is
the reason**, and the open finding is visible where it is recorded, in `status.findings[]` (§3a);
`StaleConfigurationPossible` becomes the reason at the first pass that runs while a finding is
still open, beside the `Ready=True` that pass returns, and the condition clears when the last
finding does.

---

## 19. Reconciliation state machine

```text
Pending
  ├─ dependency absent ──────────► Waiting
  ├─ terminal validation error ──► Rejected
  └─ dependencies met ───────────► Rendering
                                        │  deterministic configuration created
                                        ▼
                                    Validating
                            ┌───────────┴───────────┐
                     validation error            accepted
                            ▼                       ▼
                         Degraded                Applying
                                                    │  transaction confirmed
                                                    ▼
                                                Verifying   ← read-back, both sides
                                         ┌──────────┴──────────┐
                                      failed                 passed
                                         ▼                     ▼
                                      Degraded               Ready
                                                               │
                                   drift / update ─────────────┘
```

- `Ready` is left three ways, never by forgetting: an update or a drift re-enters the machine; a
  scheduled read-back that **finds an invariant missing** goes to `Ready=False` naming it; and a
  read-back that **could not run** — a required target unreachable or the read timed out — goes to
  `Ready=Unknown/VerificationFailed` with `Degraded=True/VerificationFailed` naming the target, at
  that pass. `Unknown` is not a fourth resting state: the next pass that runs returns the object to
  `Ready=True` or sends it to `Ready=False` (§18, FR-107, AD-40); a `Network` held at `Ready=Unknown`
  retries its read-back at the reconciliation interval (15 s), not the re-verification interval (AD-82
  `2026-09-24-unknown-retry`). Those are the ways a living object
  leaves it; a **deletion** is the other, and the only one that reads nothing: `Ready=False/Deleting`
  at once, when finalization starts (below, AD-53).
- Dependencies are: the qualification record, the `Fabric`, every claim bound — adopted or, for a
  `Network` that arrived without the tier, created by the reconciler itself (FR-109) — and the
  target's schema and connectivity Ready. The `Fabric` dependency is that it **exists and is
  Accepted** — its inventory is what attachments resolve through — and **never that it is Ready**:
  "dependencies met" in the diagram above never includes it (AD-55). A `Fabric` reporting
  `Ready=False` does not hold a `Network` in `Waiting`, and it never suspends
  the scheduled re-verification of a service that has reported Ready (FR-107). That is what lets a
  service report `RoutesMissing` while the `Fabric` itself reports `NotConverged` — the state both
  `make test-reverify` (SC-044) and SC-004's declarative negative control (AD-43) depend on.
- Transient errors retry with bounded exponential backoff and jitter. **An allocation authority
  that errors or cannot be reached is one of them** (AD-56): while it lasts a `Network` stays in
  `Waiting` as it does for an unbound claim, never `Rejected` — `AllocationConflict` is the
  authority's *answer*, not its absence — and a deleting object keeps its finalizer and
  `Deleting=True/RemovingConfiguration`, its message naming the authority, with no claim adopted
  and none released until the authority answers
  ([contracts/reconciliation.md](./contracts/reconciliation.md) Rule 3, Rule 8 steps 1 and 6).
- Terminal schema, mapping, qualification and ownership errors wait for a new generation or
  dependency version; they do not hot-loop.
- Updates preserve allocations unless the requested semantic change requires new ones.
- Deletion removes the access-list binding, then the filter, then anything that owns the
  subinterface, **reads the removal back from every affected device**, and only then releases owned
  claims and removes the finalizer. **The object is `Ready=False/Deleting` from the moment this
  starts** — before anything is removed, whatever the reachability of its targets, and until it is
  gone; no read-back decides it and it is never `Ready=Unknown` (§18, AD-53). **No timeout exists on
  this path** (FR-103): with a target
  unreachable the object stays, `Deleting=True/TargetUnreachable` names it, every claim stays bound,
  the reconciler requeues at the re-verification interval, and removal completes unaided when the
  target returns.

```text
deletionTimestamp set ─► Ready=False/Deleting at once, and until the object is gone (AD-53)
  └─► RemovingConfiguration ── every target reachable, removal read back ──► release claims ─► gone
            │
            └─ a target unreachable ─► TargetUnreachable  (claims held; no timer)
                                         ├─ target returns, removal read back ─► release claims ─► gone
                                         └─ annotation force-release: "<reason>", by a non-tier identity
                                              ─► Event ForceReleased + Fabric.status.findings[] entry
                                              ─► release claims ─► gone   (finding remains; §3a)
```
- Provider restart is safe because desired resources, hashes and transaction state are durable in
  Kubernetes, and the device-configuration layer replays every configuration that has a recorded
  applied state when a target reconnects.

---

## 20. Validation invariants

- Every VLAN is within `100–4000`, and which half it falls in decides who owns it (AD-33): a VLAN
  in the **naming band `100–999`** was named by the operator, is claimed by nobody, and is made
  exclusive by the one-owner rule; a VLAN in the **allocation band `1000–4000`** came from the VLAN
  index and MUST be backed by an adoptable bound claim, or the object is refused naming the VLAN and
  both bands. A named VLAN outside `100–999`, and any VLAN outside `100–4000`, is refused with both
  bands stated — the first by the **mapper** at interpretation, before any claim, the second by the
  translator's and the CRD's structural check, neither of which can tell a named VLAN from an
  allocated one (AD-41). The attachment VLAN of an `accessLists`-only object is a **reference** to
  another service's subinterface and is outside both band rules (AD-47). Nothing is *derived*: the platform derives no routed VLAN and reserves nothing on a
  device — the naming band is a chosen partition of the platform's own VLAN space, which is what
  makes an allocated VLAN and a named one incapable of colliding.
- Every VNI is unique in its allocation scope and drawn from the VNI band — the *allocation band*,
  the VNI index's own range — and **the VNI band MUST be a subset of 1–65535**, the *device range*
  of the EVPN instance identifier, because `evi := vni`. The two are enforced in different places
  (AD-10): the device range by the CRD's CEL rule; the allocation band by the translator for a
  request, and by the allocation authority for a `Network` applied with cluster tooling, whose
  claim for a value outside the band is refused (`AllocationConflict`). Either refusal names the
  VNI and the range.
- Every VNI on a `Network` is backed by a bound claim before anything is rendered for it — adopted
  from the tier or created by the provider for the stated value (FR-109).
- An L2VNI and an L3VNI on one service are distinct values and therefore distinct
  tunnel-interface indices.
- Every route target is syntactically valid, rendered explicitly from the fabric-wide overlay AS and
  the VNI, and never left for the device to derive.
- An attachment references an existing node and an access port that node's inventory lists, and
  **exactly one service owns a given (node, port, vlan)**. A collision is refused at validation by
  string comparison on the derived subinterface name, naming the holder.
- Conflicting tagging modes on one port are refused at the interface level, naming the port and both
  services.
- An attachment asks for the tagging mode its port **declares** in the `Fabric` inventory (§3a); any
  other is refused listing the ports declared in the mode it asked for (CR-003, AD-68).
- Spines cannot be service attachment points or tunnel endpoints.
- Routed services require non-overlapping subnets within one routed instance, and every declared
  prefix must be reachable through an attachment subnet or an explicitly rendered route — a prefix
  that corresponds to nothing is refused rather than applied and hoped for.
- A service identifier used in a generated configuration-resource name **MUST NOT contain a dot**:
  the device-configuration layer parses the node name as the text after the last dot, so a dot
  silently mis-targets the configuration.
- Two configuration resources that can touch the same device leaf MUST NOT share a priority. A leaf
  is a non-key leaf; the leaves two services would share — an access port's `admin-state` and
  `vlan-tagging`, `irb0`'s `admin-state` — are rendered by the fabric `Config`, and a subinterface's
  `/acl/interface[…]/interface-ref` by the `Config` that renders the subinterface (§13, AD-68).
- Every generated `Config` is created in `agentic-netops-system`. A fabric `Config` carries an owner
  reference to its `Fabric`; a service `Config` carries none, a `Network` never sharing that
  namespace, and is removed by the finalizer (AD-69).
- Unsupported source fields cause full rejection; warning-only semantic loss is prohibited.
- Access lists: rule priorities are distinct within a list and lie in **1–65534**; **65535 is
  reserved** for the default action and a rule claiming it is refused with the usable range stated;
  rule names are distinct within a list; a prefix must match its list's address family; an L4 port
  requires TCP or UDP; the filter type is `ipv4` or `ipv6`; a name the device reserves for its own
  filters is refused by name; the unit of exclusivity is (node, port, subinterface index, direction,
  address family) and a second list of the same family in that unit is refused naming the holder; a
  standalone list requires the subinterface to already exist and never creates one.
- Every construct and every gated property must appear as qualified in the qualification record
  before any identifier is claimed.
- **No principal is caller-asserted**: the operator entrypoint's request schema is strict and has no
  `principal` field; a request carrying one is refused naming it (FR-102).
- **No timer releases an identifier or removes a service object** (FR-103). The force-release
  annotation requires a non-empty reason, is honoured only on an object that is both deleting and
  blocked on an unreachable target, and is denied to both tier identities at admission — all three
  required by FR-103.
- **Exactly one allocation authority** is installed, and it is the one the lock file names (FR-104,
  §23).
- **The submitted-spec hash is written once**, by the tier, from the dry-run result; nothing else
  writes that key and nothing ever rewrites it (FR-105, FR-101).
- **One tagging mode per port** (FR-034): an untagged attachment and a tagged one never share a
  (node, port), within one object or across two.
- **Every claim of a submitted service has one release owner, the provider** (FR-109): the tier
  releases only provisional claims — which the **deployer** identifies, never the allocator, so no
  verb set widens (AD-32) — and the finalizer releases adopted and created claims, VNI and VLAN,
  after the read-back. A tier-submitted object carries that finalizer from the moment it is applied,
  so the ownership holds from the first instant and not only from the provider's first reconcile —
  and **finalization resolves adoption before it releases** (AD-44): every value a deleting object
  carries that is not yet in `status.claimRefs` is put through the adoption rule first, so an object
  deleted before its first reconcile leaves no claim behind. Nothing is claimed on a deleting object.
- **One adoption rule, three parts, for VNI and VLAN claims alike** (FR-109, AD-42): the correlation
  label, the deterministic claim name `<namespace>.<name>.<role>` and a value the object carries
  must all agree. A match on label and value under any other name adopts nothing.
- **Adoption is decided once per value** (FR-109, AD-32): a claim recorded `adopted` in
  `status.claimRefs` stays adopted until finalization and is never re-evaluated, which is what
  keeps the allocated VLAN of a `vlan` or `mac-vrf` from being released early when an attachment
  carrying it is removed.
- **An `ip-vrf` attachment's VLAN is named or absent, never allocated** (AD-51): the allocator
  claims no VLAN for an `ip-vrf`, a VLAN claim is named after a `vlans[]` or `bridgeDomains[]`
  entry and nothing else, and an `ip-vrf` attachment carrying a VLAN in `1000–4000` is
  `Accepted=False/AllocationConflict` by construction.
- **An allocation-authority error is not an answer** (AD-56): it is never "nothing adoptable" and
  never `AllocationConflict` — a dependency wait before a render, and in finalization the finalizer
  kept with nothing released, both retried with bounded backoff.
- **Every claim name fits**: `metadata.name` and the `vlans[]`, `bridgeDomains[]` and `routers[]`
  entry names are DNS-1123 labels of at most 63 characters, so `<namespace>.<name>.<role>` is at
  most `63 + 1 + 63 + 1 + 6 + 63 = 197` of the 253 an object name allows (AD-56).

**MTU and overhead (lab defaults)**: underlay port MTU **9412** — the platform maximum, enforced at
commit — with routed-subinterface IP MTU **9398** and bridged-subinterface L2 MTU **9412**. As decided (AD-82 `2026-09-21-access-port-mtu`) the port MTU is rendered by the fabric on **every port it owns**, fabric links and access ports alike, and the service renders `ip-mtu` = the tenant IP MTU on every routed `ip-vrf` subinterface and `l2-mtu` = the bridged L2 MTU on every bridged subinterface — each device default is below the tenant MTU. VXLAN
encapsulation adds **50 bytes** over the IPv4 underlay (outer Ethernet 14 + IPv4 20 + UDP 8 + VXLAN
8), and the inner Ethernet header costs a further 14, so the effective tenant IP MTU is
**9348 = port MTU − 64** for both address families; the VXLAN tunnel endpoint is IPv4-only, so there
is no separate IPv6-underlay figure. Acceptance packets are sized at ICMP payload **9320** (IPv4)
and **9300** (IPv6), each one byte below the observed drop threshold, with one byte more expected to
fail. **Linux endpoint interfaces MUST be set to 9348**: left at the container runtime's veth
default they black-hole TCP while ping still succeeds. An integrated-routing subinterface's IP MTU
must be set explicitly and must stay at least 14 bytes below the bridge domain's operational MTU, or
the subinterface stays operationally down. The platform performs **no** VXLAN MTU check of its own,
so this arithmetic is a validation invariant, not a read-back. The commit-time refusal one byte above is asserted for the port MTU (9413) and the routed `ip-mtu` (9399) only; the device **accepts** an IRB `ip-mtu` of 9349, so the tenant boundary is the data-plane probe above (AD-78). These numbers were measured in
research and are re-observed at P0 on the pinned image as a capability-gate item (RD-10).

---

## 21. Observability model

Every metric carries bounded identity labels: cluster, namespace, target, device role, resource
kind and name, reconcile result, signal source, and for the tier the stage and the correlation
identifier. Service identifiers are allowed only where cardinality is bounded by the reference lab.
Raw path values, error messages and trace identifiers are never metric labels.

The device path is fixed: the in-cluster gNMIc subscribes to the registered native paths and exports
OTLP to the OpenTelemetry Collector, which exposes normalized metrics to Prometheus.
Subscription-based ingestion in the device-configuration layer is disabled for those same series,
and **gNMIc's own `/metrics` endpoint is scraped** as `gnmic-self` so that every pipeline stage has
evidence rather than only its endpoints. Controllers send their own OTLP directly to the collector.
The same device pipeline is the **state source of every applied-side read-back** (the pinned
data-server serves no state datastore): gNMIc samples every **5 s**, the exporter drops a series not
refreshed within **20 s**, and a node with no sample or a collector that does not answer is a pass that
could not run (`Ready=Unknown/VerificationFailed`), never an absent value — FR-086's second device
client, no third (AD-82 `2026-09-21-state-source`, `2026-09-21-collector-freshness`).
Tier agents emit **once** to the tier collector, which fans out to the analytics store and forwards
to the fabric collector; every tier metric carries the prefix that passes the fabric collector's
filter unmodified.

The metrics store holds: interface administrative and operational state, traffic rate and
statistics; subinterface statistics; BGP neighbour session state (enumeration transformed to a
number) and per-address-family route counts including the EVPN family; network-instance operational
state; EVPN instance state; VXLAN tunnel endpoint state and counters — the tunnel endpoint carries
the packet counters, the tunnel interface itself does not; bridge-table MAC counts; route-table and
tunnel-table summaries; per-entry access-list counters; platform CPU, memory and application health;
configuration, deviation and transaction metrics; reconcile duration, count, error, retry and queue
metrics; collector receiver, exporter, queue and drop metrics; and the tier's per-stage counts,
success rate, latency, confirmation, decline, refusal and model-call metrics, plus
`agentic_netops_agent_auth_refusals_total` (FR-102) and
`agentic_netops_agent_out_of_band_changes_total{change}` with `change` ∈ `modified`, `deleted`
(FR-105) — both bounded-label counters. **The tier metric prefix is the literal
`agentic_netops_agent_`, stated here once**: it is the predecessor tier's, carried unchanged like the
rest of that tier (D-20, D-37, AD-66); every tier metric name starts with it,
`agents/common/metrics.py` refuses to register one that does not, and the fabric collector's filter
admits exactly that prefix beside the device metric names. **FR-092's per-stage outcome counter has
one name, `agentic_netops_agent_stage_requests_total{stage,outcome}`** — `stage` the pipeline stage,
`outcome` a closed set in which `STATUS_UNKNOWN` is never a converged outcome (§17, AD-54) — from
which the per-stage success rate is computed; every other artifact cites this section for the prefix
and for that name. The provider
additionally exports **`reverify_last_success_timestamp_seconds{kind,namespace,name}`** — the Unix
time of `status.lastVerifiedTime`, a timestamp and not an age, so that it stays correct while the
provider is not being scraped — and a re-verification result counter. **This is the one name for
it**; every other artifact cites this section. **"Success" in that name means the pass completed —
it ran its read-back on both sides, whatever it found — not that the read-back passed**: a pass that
finds an invariant missing advances the series and the field, and only a pass that could not run
leaves them where they were; the name is kept because it is the one already built (AD-54). **The
series lives exactly as long as the object is inside the read-back schedule**: the provider removes
the object's series when its finalization starts — from then on nothing is re-verified and the
object says `Ready=False/Deleting` (§18, AD-53) — and it is therefore absent once the object is
gone, so a removed or a held-in-deletion service never ages into `ReverificationStalled` (AD-54). The alert **`ReverificationStalled`** computes the
age (`time() - reverify_last_success_timestamp_seconds`) and fires once it exceeds one
re-verification interval plus one reconciliation interval — the measurable form of FR-107's
"a stalled schedule is itself detectable". It fires whatever `Ready` says, for every object that
has a series: for a `Ready=True` nobody
re-read it is the only signal, and during an outage it follows the `Ready=Unknown/VerificationFailed`
the operator already sees (§18, AD-40). For every registered
path the derived metric name, label names and stream mode are recorded in the path register
(FR-017); sampled streaming is the default and on-change is used only where an acceptance check
covers it.

**The required alert set** *(FR-087; stated here once, and every other artifact cites it by these
names)*. Each rule carries a severity, the identity labels above and an annotation saying what the
operator looks at next — which is what "actionable" means in FR-087 — and **each of the ten is shown to fire
and to clear**, in one of two ways. *Live*, by the acceptance run
(`alerts_fire.sh`, SC-035, SC-037), where the platform has a declared way to make the fault: a
link taken down, a failed reconciliation, a leaf cut from the management network, a stopped pipeline
stage, and — for `EvpnRoutesLost` — the declarative fault of AD-43, its field as decided in AD-77,
`Fabric.spec.overlay.reflectorClients: false`, on a lab that carries a service spanning both leaves. *By
the rule unit test* — `promtool test rules` from the pinned Prometheus image over synthetic series
(`tests/unit/alerts/`, T130), which covers **every** rule, fire, clear and no-fire — and is the
**only** proof where no live provocation is available on this platform: `OtlpDataPointsRejected`
would need a stage made to refuse data and `DuplicateDeviceSeries` a second ingestion path, and
neither has a declared way to be produced; the guard on `EvpnRoutesLost` — silent with no EVPN
instance, and with one EVI on one leaf — is asserted there too (AD-48, AD-59). A rule unit test
proves the expression, not the pipeline, and is never reported as a live firing. Expressions are written against the metric names
the path register records (FR-017), never against names assumed before G7 has qualified them.

| Alert | Fires when | Measures |
|---|---|---|
| `FabricLinkDown` | a fabric link's operational state is down | FR-087, SC-035 |
| `BGPSessionDown` | an underlay or overlay BGP session is not established | FR-087, SC-035 |
| `EvpnRoutesLost` | sessions established and zero EVPN routes received — guarded so that it cannot fire until an EVPN instance is present on at least two leaves (AD-23, AD-31) | FR-100, SC-035 |
| `ReconciliationFailed` | a `Fabric` or `Network` reconcile ends in an error or a terminal condition | FR-087, NFR-005, SC-035 |
| `ReverificationStalled` | the age computed from `reverify_last_success_timestamp_seconds` exceeds one re-verification interval plus one reconciliation interval | FR-107 |
| `DeviceTelemetryTargetDown` | the device metric collector reports a target down | SC-037 |
| `DeviceSubscriptionStalled` | a subscription has stopped delivering updates | SC-037 |
| `OtlpExportFailing` | a pipeline stage has stopped exporting | SC-037 |
| `OtlpDataPointsRejected` | telemetry is refused or dropped at any stage — the collector's refused, send-failed and queue series and the device metric collector's own error counters | NFR-002, User Story 11 scenario 4 |
| `DuplicateDeviceSeries` | one device series arrives by more than one path | FR-086, SC-037 |

A rule outside this table may be added; one inside it may not be dropped or renamed without this
table changing in the same change (constitution Principle IV).

The provisioning script derives a versioned topology asset from the containerlab inventory in the
same step that generates the collector's target list, and installs it as a ConfigMap consumed by
pinned panels. **The join between topology assets and metrics is exactly two registered labels**:
the node name as the containerlab inventory spells it, and the normalized interface name
(`ethernet-1/49` → `e1-49`). The physical view overlays link state, rate, utilization, direction and
alarms; the **EVPN service-path view** overlays, per `mac-vrf` or `ip-vrf`, the leaf-to-leaf tunnel
path, per-tunnel-endpoint statistics, per-VNI MAC counts, the routed instance's route counts, and
the hit counters of any access list bound to the service. CI compares every displayed identifier
against both the containerlab inventory and live metric queries.

Telemetry health is reported separately from configuration readiness, so a monitoring outage
neither mutates nor blocks network desired state.

---

## 22. OperatorCredential *(FR-102, CD-01)*

Not an API type — a generated Secret and the rule for what may be derived from it.

| Item | Value |
|---|---|
| Object | Secret `operator-credentials`, namespace `agentic-netops-agents` |
| Keys | `username` (default `operator`; overridable at provisioning by `OPERATOR_USERNAME`), `password` (**always generated**; never accepted from the environment, a flag or a file) |
| Written by | the provisioning script's secret-generation step; an existing Secret is preserved on re-provisioning |
| Removed by | `off.sh`, with the other generated Secrets, and the tier's removal with the tier's namespace — in both, only **after** the `username` has been captured into the run's evidence (§16; never the `password`), because SC-042 is reconciled against the usernames the run used and must still be reconcilable once this Secret is gone (AD-46) |
| Read by | the supervisor only, as a **read-only volume** — it holds no service-account token, and no RBAC rule grants any tier identity a verb on Secrets |
| Verified on | `POST /agent/prompt/stream`, `GET /suggested-prompts`, `GET /transport/config` |
| Not verified on | `GET /health`, `GET /v1/health` — probe routes; they create no thread, call no model and claim nothing |
| Yields | `principal` := the authenticated `username`, the only source of §7's `principal`, §16's `principal` and the `intent-principal` annotation |

Refusal is `401` with a `WWW-Authenticate: Basic` challenge, decided **before a `thread_id` is
minted**. Comparison is constant-time; a failed attempt costs a fixed delay. Rotation is a Secret
update: the mounted file is re-read, no restart is required, and events recorded under the old
credential remain valid for SC-042 because they matched a credential that existed when they were
recorded. **Lab credentials — not production-safe** (FR-019); one operator is the reference scale,
and multi-operator use is the recorded trigger for replacing Basic with an identity provider.

---

## 23. Allocation-authority selection *(FR-104, CD-03)*

Part 6 of the compatibility set. It is data in the lock file, not a flag and not a runtime choice.

```yaml
# versions.lock.yaml (shape only — digests are resolved at P0, never written by hand)
allocationAuthority:
  kind: kuid                      # kuid | first-party — this lab: first-party (AD-74)
  # required when, and only when, kind is first-party:
  # decisionRecord: docs/decisions/allocator-substitution.md
  # failedGateEvidence: {path: <run-scoped G11 evidence file>, sha256: <of that file>}
```

| Rule | Enforced by |
|---|---|
| `first-party` without both references, or with references that do not resolve, is refused | `make verify-pins` |
| Exactly one authority is installed and it is the lock file's: with `kuid`, no `IdentifierPool`/`IdentifierClaim` CRD exists; with `first-party`, no `*.be.kuid.dev` APIService exists | `make verify-compat`, and provisioning before it installs anything above the authority |
| A failing G11 stops provisioning, non-zero, naming G11; no allocator is selected by the script | `provision.sh`; run with the authority made to fail by `tests/unit/lifecycle/g11_stop_test.sh` (T044, SC-047) |
| A change of authority, in either direction, is made on a lab holding **no bound claim**; where one is held provisioning stops before touching either authority, naming the services that rest on it — they are removed first and re-created after, and no claim is migrated (FR-104) | `provision.sh` (T048); the same test file |
| Returning to the upstream authority is recorded like adopting the substitute: `kind: kuid` while the decision record shows an adoption and no later dated return entry is refused (FR-104) | `make verify-pins` (T009's fixtures) |
| The substitute is warned by name on every provisioning run | `provision.sh` |

**The substitute's kinds** — defined now so that nothing above the seam changes, **installed and
implemented only under a recorded decision** — which exists (AD-74, `docs/decisions/allocator-substitution.md`):
they are what runs on this lab:

| Kind | Group/version | Namespace | Shape |
|---|---|---|---|
| `IdentifierPool` | `fabric.agentic-netops.io/v1alpha1` | `agentic-netops-allocation` | `spec.type` ∈ `ip`, `asn`, `vlan`, `vni`, `genid`; `spec.range` or `spec.prefix`; structural schema |
| `IdentifierClaim` | `fabric.agentic-netops.io/v1alpha1` | `agentic-netops-allocation` | `spec.poolRef`, optional `spec.requested`; **`spec` immutable by CEL**; `status.value` reports the allocation; carries the tier's correlation label |

The claim semantics the platform relies on are identical on both sides of the seam: IP, ASN, VLAN
and VNI pools; the allocated value reported in status; the tier may **create and delete but never
update** a claim. Under substitution the tier's narrow Role moves from the two upstream claim groups
in `kuid-system` to `identifierclaims` in `agentic-netops-allocation`, with the same verbs and the
same deliberate absence of `update` and `patch`; the `Fabric`'s pool references change group and
kind and nothing else. Neither kind is ever served in, or shaped to imitate, an upstream API group
(FR-098).

---

## 24. WalkthroughEvidence *(C-22, CD-06)*

The machine record that the README's recording is accepted against —
`docs/media/agentic-netops-srl-intent-tier-demo-evidence.json`, written by `accept.py` and never by
hand. It keeps the predecessor's shape so the two are comparable, and adds the NFR-013 identity
fields.

| Field | Meaning |
|---|---|
| `generated_utc`, `take` | When acceptance ran, and which take it accepted |
| `run` | `{command, exit_status, device_image_digest, cluster, lab}` — the NFR-013 fields |
| `video` | `{width, height, duration}` of the **uncut** take; the 6× cut's duration is derived |
| `prompts[]` | One per service, in recording order |
| `prompts[].id`, `.prompt`, `.construct` | The frozen wording of `docs/DEMO_VIDEO.md` and the construct it must map to |
| `prompts[].correlation_id`, `.network` | The join to the cluster |
| `prompts[].t_enter_utc`, `.seconds_enter_to_deployed` | Measured, and the only source of any timing the README states |
| `prompts[].dom_outcome_text` | What the console said |
| `prompts[].ready_condition`, `.event_reasons`, `.service_type` | From `kubectl` JSON — **what acceptance is decided on** |
| `prompts[].leaf_pass`, `.commands` | The read-only leaf reads and whether each showed the fact it was run for, per leaf |
| `closing_listing` | The `Network` listing at the end of the take |
| `failures[]`, `accept_pass` | `accept_pass` is true only with `failures` empty |

Invariants: the principal on all three `Network`s is the generated operator username; no credential
appears in the evidence, the logs or any frame, because login precedes recording; a take with
`accept_pass: false` is deleted rather than embedded; the README states no timing, version or
outcome that is not in this file, the lock file or P11's evidence.

---

## 25. Default bounds and intervals *(FR-018, FR-053, FR-067, FR-073, FR-107)*

Every bound a requirement names has one default, stated here and nowhere else. Each is configuration
— an environment variable on the workload that owns it — never a constant a change of value would
need a rebuild for. The intent-tier values are the predecessor tier's, carried unchanged like the
rest of that tier (D-20); the control-plane retry values are the ones [contracts/reconciliation.md](./contracts/reconciliation.md) Rule 7 already states, repeated here so that there is one table; the re-verification interval is the constitution's. A test asserts the default
and asserts that the override is honoured.

| Bound | Default | Owner · setting | Requirement |
|---|---|---|---|
| Reconciliation interval (controller resync and requeue) | 15 s — SC-008's "two reconciliation intervals" is therefore its stated 30 s | provider · `RECONCILE_INTERVAL` | FR-018, SC-008; [contracts/reconciliation.md](./contracts/reconciliation.md) Rule 7 |
| Transient-error backoff | exponential from 250 ms with full jitter, capped at 10 s, at most 6 attempts; terminal errors do not retry until a relevant generation or dependency change | provider · `RETRY_BACKOFF_BASE`, `RETRY_BACKOFF_CAP`, `RETRY_MAX_ATTEMPTS` | FR-018; Rule 7 |
| **Re-verification interval** | **5 min**, with a floor of **30 s** — a shorter value, or one that cannot be parsed, refuses the provider's start naming the variable rather than reverting to the default (FR-107); unset means the default | provider · `REVERIFY_INTERVAL` | FR-107, SC-044, constitution Principle I |
| Orchestration iteration limit | 3 supervisor iterations per request turn; a turn awaiting a confirmation does not count | supervisor · `SUPERVISOR_MAX_ITERATIONS` | FR-053 |
| Request wall-clock deadline | 300 s, operator confirmation time excluded | supervisor · `SUPERVISOR_REQUEST_DEADLINE_SECONDS` | FR-053 |
| Worker call timeout | 60 s (mapper, allocator agent) | supervisor · `WORKER_CALL_TIMEOUT_SECONDS` | FR-073 |
| Model call timeout | 45 s per model call, the model library's own retries off — asserted at start-up to be below the worker call timeout, so a provider that holds a call is reported by the worker that made it naming the model provider, before the supervisor's call to that worker times out. Added by P11's degradation run (T146), which observed a held call reported as "worker unreachable" | supervisor, mapper · `MODEL_CALL_TIMEOUT_SECONDS` | NFR-010 |
| Model reasoning effort | `low` — asked of a reasoning model on every call and dropped for a model that takes no such parameter, so a change of provider is still a change of the `llm-provider` Secret alone; one of `minimal`, `low`, `medium`, `high`, or empty for the provider's own default. Added by P11's phrasing run (T144), where the provider's default effort held access-list interpretations past the model call timeout (AD-82, `docs/decisions/live-findings.md` `2026-09-25-model-reasoning-effort`) | supervisor, mapper · `MODEL_REASONING_EFFORT` | NFR-008, NFR-010 |
| Deployer call timeout | 210 s — deliberately longer than the convergence timeout it contains | supervisor · `DEPLOYER_CALL_TIMEOUT_SECONDS` | FR-073 |
| Worker call retries | 2 retries after the first attempt, exponential backoff from 1 s (1 s, then 2 s); only "unreachable" is retried, a returned failure never is | supervisor · `WORKER_CALL_RETRIES` | FR-073 |
| Convergence timeout | 150 s, polled | deployer · `DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS` | FR-067, SC-023 |
| Allocation-authority retry | the worker-call retry rule, then a named terminal failure — there is no local lease | allocator agent | FR-062, CD-03 |
| Tier-removal wait | 300 s for the tier-submitted `Network`s to finalize, then a non-zero stop naming each `Network` still `Deleting` and its unreachable target; it bounds the *script*, never the finalizer, and nothing is force-released. It is not spent on a `Network` that already reports `Deleting=True` with an unreachable target when the wait begins: that stops the removal at once | `off.sh --purge-intent-tier --remove-services` · `TIER_PURGE_WAIT_SECONDS` | NFR-006, FR-103, AD-26, AD-35 |
| Audit-record export | 120 s to read the store's trace tables and write the export; past it the export has failed and the removal stops with the store intact (FR-078). A **design value**, not a measurement: short enough that an unresponsive store cannot hold a teardown open, long enough for a lab run's trace tables — the first run that measures a real export records what it took, and this default is revisited against it | `off.sh` · `AUDIT_EXPORT_TIMEOUT_SECONDS` | FR-078, AD-24, AD-36 |
| Tier metric export interval | 10 s — below the fabric exporter's 20 s series expiration, so a tier series never reads absent between exports (AD-82 `2026-09-25-tier-metric-export-interval`) | every tier workload · `OTEL_METRIC_EXPORT_INTERVAL` (code default `METRIC_EXPORT_INTERVAL_MS`) | FR-092, FR-093 |

Invariants: `convergence timeout < deployer call timeout < request deadline ≤ SC-023's five minutes`,
asserted at start-up so that an override cannot silently make a bound unreachable; the
delete-while-unreachable state has **no** bound at all (§18, FR-103) and none of these applies to
it — the tier-removal row is not an exception to that, because it bounds only how long the removal
*script* watches that state and never the finalizer, the object or an identifier; the "ten
reconciliation intervals" of SC-043 is 150 s at the default. The provider's
`DRIFT_POLICY` is deliberately **not** in this table: it has no default — the provider refuses to
start without one, and `revertive` is what lab provisioning chooses and what a production
deployment states for itself (FR-015, AD-13). Its value set is closed and has one member, the exact
string `revertive`; unset, empty and every other value refuse the start alike, naming the variable
and the admissible value (AD-17). The setting is a string because it names a policy; the field it
lands in, the configuration resource's `revertive`, is a boolean, because `true` and `false` are
what the layer offers — `revertive` maps to `true`, and no member of the closed set can produce
`false` or an absent field. The layer's `false` is not "accept the drift": it holds the deviation
for an operator to accept or revert, a shape this feature does not build (AD-34).

---

## 26. First-party image pins *(NFR-003)*

A first-party image — `srl-provider`, and the intent tier's `supervisor`, `mapper`, `allocator`,
`deployer`, `intent-translator` and `ui` — is built locally and exists in no registry, so there is
no registry digest to resolve. What *is* resolvable is everything it is built from, and that is what
the lock file pins.

```yaml
# versions.lock.yaml (shape only — digests and hashes are written by tooling, never by hand)
firstPartyImages:
- name: srl-provider
  dockerfile: docker/Dockerfile.srl-provider
  context: .
  from:                                   # every FROM line, in order, by registry-resolved digest
  - {ref: golang, tag: <locked toolchain>-alpine, digest: <resolved>}
  - {ref: <the runtime base the Dockerfile names>, tag: <locked>, digest: <resolved>}
  dependencyLocks:                        # SHA-256 of each dependency lock file the build consumes
  - {path: go.sum, sha256: <computed>}
- name: supervisor
  dockerfile: docker/Dockerfile.supervisor
  context: agents
  from: [{ref: python, tag: 3.13.0-slim, digest: <resolved>}]
  dependencyLocks: [{path: agents/uv.lock, sha256: <computed>}]
# … mapper, allocator, deployer (as supervisor); intent-translator (as srl-provider);
#   ui (node:20-alpine, ui/package-lock.json)
```

| Rule | Enforced by |
|---|---|
| Every `FROM` in every first-party Dockerfile is `<ref>@sha256:<digest>`, equals the lock file's entry, and that digest resolves in its registry | `make verify-pins` |
| Every `dependencyLocks[].sha256` equals the file in the tree | `make verify-pins` |
| The image is tagged `<name>:<contentHash>`, where `contentHash` is the SHA-256 of the build context's tracked files plus the Dockerfile — never `latest`, never a reusable tag; every manifest references it by that tag with `imagePullPolicy: Never` | the build step (`scripts/lib/image_build.sh`); `make verify-pins` fails any first-party image referenced by a mutable tag |
| The image ID each build produced is written to the run's evidence, never to the lock file — a lock file rewritten by every build is a pin nobody reads | the build step, through `evidence_run` |
| Every running first-party workload carries the tag of the current tree and the image ID this run's build recorded | `make verify-compat` |

The base-image digests above are left `<resolved>` deliberately: they are filled by
`scripts/lib/resolve_pins.sh` from the registry, under the rule that no digest is ever typed.

**An entry whose Dockerfile is not in the tree yet is *pending*** (AD-71). The lock file lists all
seven images from the start, and six Dockerfiles arrive with later stories. For such an entry
`make verify-pins` still resolves every `from[]` digest and checks each dependency lock that exists,
prints `pending: <name> — Dockerfile absent`, and **fails if any manifest, script or Makefile target
references that image**; a Dockerfile under `docker/` with no entry fails; the acceptance run
(`verify_pins.sh --no-pending`) admits no pending entry. Pending is therefore never a pass for
anything that is built or deployed, and it is not an exception field.

**No exception field exists in `versions.lock.yaml`** (NFR-003, AD-12). The one pin exception the specification
admits is the recorded allocator substitution of §23; a lock file that declares any other —
an `exceptions`, `allowUnpinned` or skip-style field anywhere — fails `make verify-pins`.

---

## 27. Log record *(NFR-014)*

Every first-party workload writes one JSON object per line **to standard output**, which is the
stream a consumer reads; nothing else defines these fields (NFR-014).

| Field | Rule |
|---|---|
| `ts` | UTC, RFC 3339 |
| `level` | `debug`, `info`, `warn`, `error` |
| `component` | the workload: `srl-provider`, `intent-translator`, `supervisor`, `mapper`, `allocator`, `deployer` |
| `msg` | one sentence, written for an operator |
| `kind`, `namespace`, `name` | the resource the line is about, when there is one |
| `correlation_id` | on every line of a request, and on every provider line about an object that carries the correlation label |
| `thread_id` | intent tier only, when there is one |

Every value passes the redaction of FR-079 before it is written. A log line is never the only
record of an outcome: conditions, Events and metrics carry that (NFR-005). The lifecycle scripts use
a level and phase prefix and are not JSON.

---

## 28. Host-side tooling pins *(NFR-003, AD-21)*

Tooling that ships in no image and runs on the operator's host — never in the cluster, never as a
platform component — is pinned in the same lock file:

```yaml
# versions.lock.yaml (shape only — versions are recorded by tooling from what is observed, never typed)
hostTooling:
  browserAutomation:              # drives the chat-surface session (SC-019) and the walkthrough
    package: playwright           # exact version in agents/pyproject.toml's dev group,
    lockFile: agents/uv.lock      #   hash-locked here like every other tier dependency
    browser: chromium             # the build that package version fixes; its revision is recorded
  capture:                        # the recorded walkthrough only (C-22)
    - {tool: ffmpeg, version: <recorded>}
    - {tool: <X display server the driver records from>, version: <recorded>}
```

| Rule | Enforced by |
|---|---|
| The browser-automation package is an exact version, hash-locked; a range is refused | `make verify-pins` |
| The installed browser revision equals the one the locked package version fixes | `make verify-pins`, before the suite that uses it |
| Each capture tool's host version equals the recorded one; a missing or different tool fails naming it | `make verify-pins`, before `record.py --smoke` |
| The versions a run actually used are in that run's evidence | `evidence_run` (NFR-013) |

`resolve_pins.sh` records a version from the host that runs the first smoke, the same way it fills a
digest from a registry: from what it observes, never from input text. This block is not a pin
exception — NFR-003 still admits exactly one, and it is not this.
