# Contract: the fabric intent object

**Feature**: `004-agentic-netops-composite` | **Carries**: FR-029 to FR-032, FR-035 to FR-037,
FR-044, FR-046, FR-048, FR-101 | **Decisions**: D-11, D-19, RD-05, RD-06, RD-09

**Producer**: the single translator · **Consumers**: the typed read side (`pkg/fabricapi`), the SR
Linux provider, the golden files.

`Network` is a **first-party Kind with a real structural OpenAPI schema**. `spec` carries no
`x-kubernetes-preserve-unknown-fields`; unknown fields are rejected; every enum, range, format and
required field is expressed in the schema, and the cross-field and cross-object rules are CEL rules
and admission rules listed in [crd-api.md](./crd-api.md) §Required `Fabric` and `Network` API. A
field this contract does not name cannot be set. Adding a field is a schema change, reviewed as one.

## 1. Shape

```yaml
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
metadata:
  name: migr-<serviceId>                                   # a DNS-1123 label, <=63, no dot: the Config name parses on it
  namespace: <the intent namespace the deployer stamps>
  labels:
    agentic-netops.io/correlation-id: <32 hex trace id>     # stamped by the intent tier
    agentic-netops.io/tier: intent
  annotations:
    agentic-netops.io/translator: agentic-netops-migration-translator
    agentic-netops.io/translator-version: v0.1.0
    agentic-netops.io/mapping-version: v0.1.0
    agentic-netops.io/migration-input-hash: <sha256 of the canonical input>
    agentic-netops.io/tenant: <tenant>
    agentic-netops.io/service-type: vlan | mac-vrf | ip-vrf | acl
    agentic-netops.io/source-service-type: <the migration alias>   # only when it arrived as one
    agentic-netops.io/limited-equivalence: <marker>                # only for a point-to-point source
    agentic-netops.io/intent-thread-id: <uuid>                     # stamped by the intent tier
    agentic-netops.io/intent-principal: <authenticated operator username>   # FR-102
    agentic-netops.io/intent-submitted-at: <RFC3339>
    agentic-netops.io/intent-submitted-spec-sha256: <64 hex>       # FR-105; tier-owned, written once, last
spec:
  description: Service <serviceId> (<construct>)
  vlans:
  - {name: vlan-<serviceId>, vlan: 100}
  bridgeDomains:
  - name: bd-<serviceId>
    vlan: 100
    l2vni: 10021
    evpn: {routeTargets: {import: ["target:65000:10021"], export: ["target:65000:10021"]}}
    irb:                        # present iff the mac-vrf declares an anycast gateway
      vrf: vrf-<serviceId>
      gatewayIPv4: 10.10.0.1/24
      gatewayIPv6: 2001:db8:10::1/64
  routers:
  - name: vrf-<serviceId>
    routeTargets: {import: ["target:65000:10022"], export: ["target:65000:10022"]}
    l3vni: 10022
    prefixes: ["10.10.0.0/24"]
  accessLists:
  - name: acl-<serviceId>-ingress
    stage: ingress
    type: ipv4
    defaultAction: deny
    rules:
    - {name: allow-https, priority: 100, action: permit, protocol: tcp,
       sourcePrefix: 10.0.0.0/24, destinationPort: "443", description: "operator text"}
  attachments:
  - {node: leaf01, vlan: 100, attachment: ethernet-1/1}    # L2 constructs
  - {node: leaf01, vlan: 200, vrf: vrf-<serviceId>, attachment: ethernet-1/1}  # ip-vrf, tagged
  - {node: leaf01, attachment: ethernet-1/1}               # acl-only, untagged subinterface — legal only where the inventory declares the port untagged (AD-68)
  - {node: leaf02, attachment: ethernet-1/1, vlan: 100}    # acl-only on an existing tagged subinterface
```

**Provider keys never appear on this object.** The provider's source identity, generation, render
hash, compatibility set and mapping version belong on the configuration resources it generates, so
exactly two actors — the translator and the intent tier — stamp this object, with disjoint key sets
(FR-101).

**There is no route distinguisher.** `routers[]` carries none and none may be set: the device
derives it per leaf from its own system loopback address and the EVPN instance identifier. The
`routeTargets` on both `bridgeDomains[].evpn` and `routers[]` are **derived and rendered explicitly**
as `target:<fabricASN>:<vni>`; they appear in the object because the operator confirmed them and the
golden files assert them, not because anyone chose them.

## 2. Which lists each construct emits

| Construct | `vlans` | `bridgeDomains` | `routers` | `accessLists` | attachments carry |
|---|---|---|---|---|---|
| `vlan` | 1 | — | — | 0 or 1 | `vlan` |
| `mac-vrf` | — | 1 | — | 0 or 1 | `vlan` |
| `mac-vrf` + gateway | — | 1 (with `irb`) | 1 | 0 or 1 | `vlan` |
| `ip-vrf` | — | — | 1 | 0 or 1 | `vrf`, and `vlan` when the attachment is tagged — always a VLAN the operator **named**, from `100–999`; none is ever allocated for an `ip-vrf` (AD-51) |
| `acl` | — | — | — | 1 | neither, or `vlan` alone |

**Why a local VLAN is its own list** and not a bridge domain with a zero L2VNI: encoding "this is a
different service" as "this field is missing" is the exact defect that once made an integrated
L2/L3 service silently render as a bridged one, with the routed half disappearing and no error
(D-11). On this platform the reason is stronger, not weaker: a `vlan` and a `mac-vrf` render to the
**same network-instance type**, differing only by which optional children are absent, so the
device-side difference between "the operator asked for a local bridge domain" and "the operator
asked for a fabric-wide one whose overlay half failed to render" is invisible. The intent-side
distinction is the only place that difference survives, and the schema keeps it.

## 3. Deterministic emission order

The emitter writes keys in a fixed order so the golden files are a real contract:

1. `apiVersion`, `kind`
2. `metadata`: `name`, `namespace`, `labels`, `annotations` — annotations in exactly this key
   order: translator, translator-version, mapping-version, migration-input-hash, tenant,
   **service-type**, **source-service-type**, limited-equivalence, then the intent-tier audit keys
   — thread id, principal, submitted-at — and **last of all the submitted-spec hash**, which is
   computed from the server-side dry-run result — which is the representation FR-105 requires be
   hashed — and is therefore the one key added between the
   dry-run and the apply (FR-105). It is last so that "computed late" can never again mean
   "silently dropped"
3. `spec`: `description`, **`vlans`**, `bridgeDomains`, `routers`, **`accessLists`**, `attachments`

Within a bridge domain: `name`, `vlan`, `l2vni`, `evpn`, `irb`. Within a router: `name`,
`routeTargets`, `l3vni`, `prefixes`. Within an access list: `name`, `stage`, `type`,
`defaultAction`, `rules`. Within a rule: `name`, `priority`, `action`, `protocol`, `sourcePrefix`,
`destinationPrefix`, `sourcePort`, `destinationPort`, `description`. Within an attachment: `node`,
`attachment`, `vlan`, `vrf`. Empty and zero-valued fields are omitted.

**The source-service-type and limited-equivalence keys were missing from this order**, so the
provenance the requirement asks for was computed and then silently dropped before it reached the
object (D-19). They are in it now, and these annotations are the **single** provenance record for
both construct provenance and migration provenance (FR-046); a `MigrationPlan`, when used,
references them rather than restating them (FR-048).

## 4. Read side

Package `pkg/fabricapi` — the typed read side of the first-party API.

```go
func (n *Network) VLANs() []NetworkVLAN        // spec.vlans
func (n *Network) BridgeDomains() []BridgeDomain
func (n *Network) Routers() []NetworkRouter
func (n *Network) AccessLists() []AccessList   // spec.accessLists
func (n *Network) Attachments() []NetworkAttachment
```

`NetworkVLAN{Name string; VLAN int64}`;
`BridgeDomain{Name string; VLAN, L2VNI int64; EVPN EVPNSpec; IRB *IRBSpec}`;
`NetworkRouter{Name string; L3VNI int64; RouteTargets RouteTargets; Prefixes []string}`;
`AccessList{Name, Stage, Type, DefaultAction string; Rules []ACLRule}`;
`ACLRule{Name string; Priority int64; Action, Protocol, SourcePrefix, DestinationPrefix,
SourcePort, DestinationPort, Description string}`;
`NetworkAttachment{Node, Attachment, VRF string; VLAN *int64}`.

`NetworkRouter` has **no route-distinguisher field**. All five accessors keep the existing tolerance
discipline: an unknown shape yields nil and a mistyped field is omitted rather than failing the
decode, because the CRD is the source of truth and the client must not drift from it.

## 5. Rendering rules the provider must honour

1. An attachment with a VLAN resolves against the bridge domains **then** the local VLANs; matching
   neither is an error naming both sets. A local `vlan` and a `mac-vrf` bridge domain are resolved
   from **different lists**, never inferred from whether an overlay field is present.
2. An attachment with neither a VLAN nor a routed instance is an error **only when** the object
   declares no access lists; otherwise it is an access-list-only attachment, and an access-list-only
   attachment MAY carry a VLAN purely to name which existing subinterface to bind to.
3. Every attachment resolves through the `Fabric` site inventory to exactly one subinterface:
   `<port>.<vlan>` when a VLAN is named, `<port>.0` when none is. **One owner per
   `(node, port, vlan)`**: two objects deriving the same subinterface name are refused before
   anything is created, naming the holder — a string comparison, not a device query.
4. A `mac-vrf` bridge domain **must** carry a non-zero L2VNI; a bridge domain with no L2VNI is a
   malformed object, not a local VLAN. A `vlan` entry **never** gets a VXLAN interface, an EVPN
   instance or a route target.
5. Route targets are rendered explicitly from the fabric-wide overlay AS and the VNI; the device's
   own derivation is never relied on, because it uses the per-leaf underlay AS and would differ on
   every leaf. The route distinguisher is left to the device and is not rendered.
6. A declared prefix on a `routers` entry must be reachable through one of that object's attachment
   subnets, or be rendered as an explicit route; a prefix that is neither is **refused at
   validation**, naming the prefix, rather than applied and hoped for.
7. An access list renders on **every** node that has an attachment in this object, bound to that
   node's own subinterfaces and no others.
8. A standalone access list — an object whose only list is `accessLists` — requires each target
   subinterface **to already exist**, checked against the attachments of other `Network` objects on
   that node, port and VLAN. When none exists it is refused before anything is created, naming the
   missing subinterface. An access list never creates an interface or a subinterface.
9. The binding unit is `(node, port, subinterface index, direction, address family)`. A second list
   of the same family in the same unit is **refused, naming the holder** — never displaced, never
   merged into, never joined. An object with a deletion timestamp still holds its bindings until it
   is gone, and the refusal says so.
10. **Equal ownership is refused, not resolved.** Wherever two objects would contend for one
    subinterface or one binding unit, the render stops at validation. The same doctrine governs
    configuration-resource priority: two resources that could touch one device leaf never share a
    priority — and no two service resources do, the leaves they would share being the fabric's
    (AD-68).
11. An object that produces no node plans is still an error — an access-list-only service must
    produce node plans, or nothing was bound and reporting success would be a lie.

## 6. Exemplar — a `mac-vrf` with an anycast gateway and an ingress access list

Operator request: *"extend vlan 100 as a mac-vrf across leaf01 and leaf02 for tenant acme, with a
gateway at 10.10.0.1/24 and 2001:db8:10::1/64, and permit tcp 443 from 10.0.0.0/24 on ingress, deny
everything else."* Service identifier `4b7e19c2a05d3f6` — generated by the mapper, 15 lower-case hexadecimal characters
([../data-model.md](../data-model.md) §8, AD-61); L2VNI 10021 and L3VNI 10022 from the allocation authority; VLAN 100
carried **as named** — it lies in the naming band `100–999` and claims nothing (AD-33);
`fabricASN` 65000 from the `Fabric`.

```yaml
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
metadata:
  name: migr-4b7e19c2a05d3f6
  namespace: agentic-netops-intent
  labels:
    agentic-netops.io/correlation-id: 4f2c1a9e7b6d40518c3e9a2f1d0b7c85
    agentic-netops.io/tier: intent
  annotations:
    agentic-netops.io/translator: agentic-netops-migration-translator
    agentic-netops.io/translator-version: v0.1.0
    agentic-netops.io/mapping-version: v0.1.0
    agentic-netops.io/migration-input-hash: sha256:9b1c…
    agentic-netops.io/tenant: acme
    agentic-netops.io/service-type: mac-vrf
    agentic-netops.io/intent-thread-id: 0b0f6f2e-6a52-4b1a-9a2f-2f5f7d8c1e44
    agentic-netops.io/intent-principal: operator
    agentic-netops.io/intent-submitted-at: "2026-09-20T14:31:07Z"
    agentic-netops.io/intent-submitted-spec-sha256: <64 hex of the canonical dry-run spec>
spec:
  description: Service 4b7e19c2a05d3f6 (mac-vrf)
  bridgeDomains:
  - name: bd-4b7e19c2a05d3f6
    vlan: 100
    l2vni: 10021
    evpn:
      routeTargets:
        import: ["target:65000:10021"]
        export: ["target:65000:10021"]
    irb:
      vrf: vrf-4b7e19c2a05d3f6
      gatewayIPv4: 10.10.0.1/24
      gatewayIPv6: 2001:db8:10::1/64
  routers:
  - name: vrf-4b7e19c2a05d3f6
    routeTargets:
      import: ["target:65000:10022"]
      export: ["target:65000:10022"]
    l3vni: 10022
    prefixes: ["10.10.0.0/24", "2001:db8:10::/64"]
  accessLists:
  - name: acl-4b7e19c2a05d3f6-ingress
    stage: ingress
    type: ipv4
    defaultAction: deny
    rules:
    - name: allow-https
      priority: 100
      action: permit
      protocol: tcp
      sourcePrefix: 10.0.0.0/24
      destinationPort: "443"
      description: operator https allowance
  attachments:
  - {node: leaf01, attachment: ethernet-1/1, vlan: 100}
  - {node: leaf02, attachment: ethernet-1/1, vlan: 100}
```

What this object commits the provider to, on each of the two leaves: a bridge-domain
network-instance `macvrf-4b7e19c2a05d3f6` carrying the bridged subinterface `ethernet-1/1.100` and the
VXLAN interface `vxlan0.10021` with EVPN instance identifier 10021 and both route targets rendered;
a routed network-instance `ipvrf-4b7e19c2a05d3f6` carrying `vxlan0.10022` with EVPN instance identifier
10022; the subinterface `irb0.100` attached to **both**, carrying both declared gateway addresses as
anycast addresses; and the filter `acl-4b7e19c2a05d3f6-ingress` of type `ipv4` with entry 100 permitting and
the reserved entry 65535 dropping, bound on input to `ethernet-1/1.100` with an explicit interface
reference. Priority ordering is ascending and the first match wins, so entry 100 is evaluated before
entry 65535 — the interpretation stated that in words before the operator confirmed, and stated that
without `defaultAction: deny` the platform would have accepted unmatched traffic.

The resulting configuration resource for `leaf01`, with its trimmed native value, is in
[crd-api.md](./crd-api.md) §Generated device configuration contract. The two leaves' resources are
identical apart from the node name in `metadata.name` and in the target labels, because every
derived value in the render is a function of the service, not of the leaf — which is exactly why the
route targets are rendered and the route distinguisher is not.
