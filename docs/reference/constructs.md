# Construct reference

**Carries**: FR-083 (the four constructs, their variables, what each renders in the device's own
object names, access-list ordering, unmatched traffic, what remains unsupported), FR-085 (retired
names only as migration aliases or provenance), SC-013 (the four cited device references suffice).
**Source of truth**: `specs/004-agentic-netops-composite/contracts/construct-vocabulary.md` §1–§8,
with `contracts/acl-render-contract.md` and `contracts/network-spec.md`. If this page and the
contract disagree, the contract wins and this page is wrong.

Object names below are the ones the renderer writes: `internal/model/names.go`,
`internal/render/srl/*.go`, `internal/render/srl/acl/*.go`. The device is Nokia SR Linux `25.7.1`
as pinned in the lock file. `<id>` is the service identifier (a DNS-1123 label, at most 63
characters); examples use `svc-0042`, tenant `tenant1`, fabric ASN `65000`.

## The four constructs

Reported to an operator in this order; nothing else is offered as a type (FR-024).

| Construct | Meaning |
|---|---|
| `vlan` | a local broadcast domain: a VLAN and the ports in it |
| `mac-vrf` | a VLAN extended over the fabric by an L2VNI with EVPN route targets |
| `ip-vrf` | a routed instance: a VRF with an L3VNI and route targets |
| `acl` | a filter bound to the attachment subinterfaces a service occupies |

`mac-vrf` and `ip-vrf` are **the device's own names** for its bridged and routed
`network-instance` types, not platform coinages (FR-099). CI asserts it against the pinned device
model: `TestConstructNamesMatchDeviceModel` in `pkg/migration/device_names_test.go`. If a future
device release renamed either type, that test fails and this vocabulary changes with it. `vlan`
and `acl` are operator vocabulary; the device objects they render are listed below.

An anycast gateway is a property of a `mac-vrf`, never a fifth construct.

## Name resolution

Implemented in `pkg/migration/constructs.go` (`Key`, `Canonicalize`). The key function lowercases
the input, then deletes every `-`, `_`, space, `.` and `+`. So `IP-VRF`, `ip_vrf`, `MAC VRF`,
`macvrf` and `Mac-Vrf` all resolve to the same construct.

| Key | Construct | Kind |
|---|---|---|
| `vlan` | `vlan` | construct |
| `macvrf` | `mac-vrf` | construct |
| `ipvrf` | `ip-vrf` | construct |
| `acl` | `acl` | construct |
| `l2vni` | `mac-vrf` | synonym |
| `l3vni` | `ip-vrf` | synonym |
| `accesslist` | `acl` | synonym |

The migration aliases also resolve, on input only (see
[Migration aliases (accepted on input only)](#migration-aliases-accepted-on-input-only)). A key in
neither table is refused, and the refusal lists the four construct names (FR-028).

## Required and accepted variables

`R` required · `O` optional · `D` **derived**: computed by the platform, shown in the assignment
exactly as it will be rendered, and **refused if the operator supplies it** · `X` refused, naming
the construct that carries it (FR-033) · `—` not applicable.

| Variable | `vlan` | `mac-vrf` | `ip-vrf` | `acl` |
|---|---|---|---|---|
| `tenant` | R | R | R | R |
| `endpoints[].node`, `.attachment` | R | R | R | R |
| `endpoints[].vlan` | R (shared) | R (shared) | O (per attachment) | O (names the subinterface) |
| `endpoints[].vrf` | — | — | R | — |
| `l2vni` | X | R | X | X |
| `l3vni` | X | O (R with a gateway) | R | X |
| `routeTargets` | X | D | D | X |
| `addressFamilies` | — | — | R (at least one prefix) | — |
| `anycastGateway` | X | O | X | X |
| `acl` | O | O | O | R |
| **minimum endpoints** | 1 | 2 (1 with a gateway) | 1 | 1 |

The endpoint minimum is enforced by the validator, not by a schema floor: three of the four
constructs are legitimately single-attachment (D-26).

**VLANs, two bands.** A VLAN an operator names comes from the naming band **`100–999`**. The
allocation authority allocates only from **`1000–4000`**, and only the shared VLAN of a `vlan` or
`mac-vrf` whose operator named none. The bands are disjoint, so an allocated VLAN can never collide
with a named one. A named VLAN below `100`, in `1000–4000`, or above `4000` is refused at
interpretation with **both bands stated** (FR-062). An `ip-vrf` endpoint's VLAN is named or absent,
never allocated; absent means the untagged subinterface `<port>.0`. The VLAN on a standalone `acl`
endpoint is a reference to a subinterface another service created, so neither band applies to it.

**VNIs.** L2VNIs and L3VNIs are allocated from **`10000–20000`**, a subset of the range the device's
EVPN instance identifier (`1–65535`) can carry, because `evi := vni`. A VNI outside the band is
refused naming the VNI and the band.

**Route targets are derived, shown and never supplied.** Import and export are both
`target:<fabricASN>:<vni>`, with `fabricASN` a fabric-wide constant, and they are shown before the
second confirmation. They are written explicitly because the device's own auto-derivation would use
each leaf's own AS and produce route targets that never match.

**There is no route-distinguisher variable.** The device derives it per leaf from its system
address and the EVPN instance identifier. It is not claimed, rendered or shown.

### Access-list variables

| Variable | Values | Notes |
|---|---|---|
| `stage` | `ingress` \| `egress` | `ingress` → device `input`, `egress` → `output`. `egress` is refused unless the qualification record shows it qualified (FR-097); `docs/reference/qualification-record.md` currently lists `acl.egress: unqualified` |
| `type` | `ipv4` \| `ipv6` | Input spellings `l3`, `l3v6`, `ip`, `ipv6` fold to these two. A MAC list is refused (FR-038) |
| `rules[].name` | 1–255 characters | Carried into the entry's `description`. A rule's identity is its priority |
| `rules[].priority` | `1–65534`, distinct | Rendered as `sequence-id`, unchanged. `65535` is reserved |
| `rules[].action` | `permit` \| `deny` | `permit` → `accept {}`, `deny` → `drop {}` |
| `rules[].protocol` | a known name or `0–255` | `icmpv6` is accepted (device `icmp6`, 58). L4 ports need TCP or UDP |
| `rules[].sourcePrefix`, `.destinationPrefix` | a prefix of the list's family | A wrong-family prefix is refused |
| `rules[].sourcePort`, `.destinationPort` | a number or `lo-hi` | Rendered as numbers, never as the device's port-name enumeration |
| `defaultAction` | `permit` \| `deny`, optional | See [What happens to unmatched traffic](#what-happens-to-unmatched-traffic) |

## What each construct renders — in the device's own object names

Rendered as native `srl_nokia` YANG configuration, one SDC `Config` per (service, node), applied
over gNMI. Derived names, from `internal/model/names.go`:

| Object | Name |
|---|---|
| `vlan` network-instance | `vlan-<id>` |
| `mac-vrf` network-instance | `macvrf-<id>` |
| `ip-vrf` network-instance (also the gateway's routed half) | `ipvrf-<id>` |
| attachment subinterface | `<port>.<vlan>`, e.g. `ethernet-1/1.100`; untagged: `<port>.0` |
| VXLAN interface | `vxlan0.<index>`, index `:= vni` |
| gateway subinterface | `irb0.<vlan>` |
| EVPN / VPN instance | `bgp-evpn bgp-instance 1`, `bgp-vpn bgp-instance 1`; `evi := vni`; `ecmp 8` |
| route targets | `target:<fabricASN>:<vni>` (export and import) |
| access-list filter | `acl-<id>-ingress` / `acl-<id>-egress`, keyed with its `type` |
| network-instance description | `Service <id> (<construct>)` |

The examples below are the flat `set /` form of the rendered tree. Port-level leaves
(`admin-state`, `vlan-tagging true`, `mtu`), `irb0`'s own admin-state and `tunnel-interface vxlan0`
itself belong to the fabric configuration; a service writes nothing above its own subinterfaces.

### `vlan`

A `network-instance` of type `mac-vrf` with **no** `vxlan-interface`, **no** `bgp-evpn` and **no**
`bgp-vpn`: a purely local bridge domain, plus its bridged subinterfaces (`single-tagged vlan-id`).
It stays a construct of its own because the device realises it with the same instance type as a
`mac-vrf`; "local" is never encoded as "the overlay fields happen to be missing" (FR-029).

```text
set / interface ethernet-1/1 subinterface 100 type bridged
set / interface ethernet-1/1 subinterface 100 admin-state enable
set / interface ethernet-1/1 subinterface 100 vlan encap single-tagged vlan-id 100
set / network-instance vlan-svc-0042 type mac-vrf
set / network-instance vlan-svc-0042 admin-state enable
set / network-instance vlan-svc-0042 description "Service svc-0042 (vlan)"
set / network-instance vlan-svc-0042 interface ethernet-1/1.100
```

### `mac-vrf`

A `network-instance` of type `mac-vrf`; bridged subinterfaces `ethernet-1/N.<vlan>`;
`vxlan0.<l2vni>` of `type bridged` with `ingress vni <l2vni>` and
`egress source-ip use-system-ipv4-address`; `bgp-evpn bgp-instance 1` carrying the VXLAN interface,
`evi := l2vni`, `encapsulation-type vxlan` and `ecmp 8`; `bgp-vpn bgp-instance 1` carrying the
explicit export and import route targets.

```text
set / interface ethernet-1/1 subinterface 100 type bridged
set / interface ethernet-1/1 subinterface 100 vlan encap single-tagged vlan-id 100
set / tunnel-interface vxlan0 vxlan-interface 10021 type bridged
set / tunnel-interface vxlan0 vxlan-interface 10021 ingress vni 10021
set / tunnel-interface vxlan0 vxlan-interface 10021 egress source-ip use-system-ipv4-address
set / network-instance macvrf-svc-0042 type mac-vrf
set / network-instance macvrf-svc-0042 interface ethernet-1/1.100
set / network-instance macvrf-svc-0042 vxlan-interface vxlan0.10021
set / network-instance macvrf-svc-0042 protocols bgp-evpn bgp-instance 1 encapsulation-type vxlan
set / network-instance macvrf-svc-0042 protocols bgp-evpn bgp-instance 1 vxlan-interface vxlan0.10021
set / network-instance macvrf-svc-0042 protocols bgp-evpn bgp-instance 1 evi 10021
set / network-instance macvrf-svc-0042 protocols bgp-evpn bgp-instance 1 ecmp 8
set / network-instance macvrf-svc-0042 protocols bgp-vpn bgp-instance 1 route-target export-rt target:65000:10021
set / network-instance macvrf-svc-0042 protocols bgp-vpn bgp-instance 1 route-target import-rt target:65000:10021
```

### `ip-vrf`

A `network-instance` of type `ip-vrf`; routed subinterfaces carrying the attachment addresses
(index `:=` the named VLAN, or `0` when none is named) with an explicit `ip-mtu`; `vxlan0.<l3vni>`
of `type routed`; `bgp-evpn bgp-instance 1` with `evi := l3vni` in the interface-less model, so the
declared prefixes are advertised as EVPN IP-prefix (Type-5) routes because they are in the
instance's route table; `bgp-vpn bgp-instance 1` with explicit route targets.

```text
set / interface ethernet-1/1 subinterface 200 type routed
set / interface ethernet-1/1 subinterface 200 vlan encap single-tagged vlan-id 200
set / interface ethernet-1/1 subinterface 200 ipv4 address 10.20.0.1/24
set / tunnel-interface vxlan0 vxlan-interface 10022 type routed
set / tunnel-interface vxlan0 vxlan-interface 10022 ingress vni 10022
set / network-instance ipvrf-svc-0042 type ip-vrf
set / network-instance ipvrf-svc-0042 interface ethernet-1/1.200
set / network-instance ipvrf-svc-0042 vxlan-interface vxlan0.10022
set / network-instance ipvrf-svc-0042 protocols bgp-evpn bgp-instance 1 evi 10022
set / network-instance ipvrf-svc-0042 protocols bgp-vpn bgp-instance 1 route-target export-rt target:65000:10022
set / network-instance ipvrf-svc-0042 protocols bgp-vpn bgp-instance 1 route-target import-rt target:65000:10022
```

### `mac-vrf` with an anycast gateway

The `mac-vrf` above plus `irb0.<vlan>`, a member of **both** `macvrf-<id>` and `ipvrf-<id>`; the
routed half is an `ip-vrf` with `vxlan0.<l3vni>` (`type routed`, `evi := l3vni`,
`target:<fabricASN>:<l3vni>`). `irb0.<vlan>` carries `anycast-gw virtual-router-id 1`, an explicit
`ip-mtu`, addresses with `anycast-gw true`, and ARP/ND `learn-unsolicited`, `host-route populate
dynamic` and `evpn advertise dynamic`, **only for the address families the operator declared**
(FR-032). The `mac-vrf` also gets `bridge-table protect-anycast-gw-mac true`.

```text
set / interface irb0 subinterface 100 anycast-gw virtual-router-id 1
set / interface irb0 subinterface 100 ipv4 address 10.10.0.1/24 anycast-gw true
set / interface irb0 subinterface 100 ipv4 arp learn-unsolicited true
set / interface irb0 subinterface 100 ipv4 arp host-route populate dynamic
set / interface irb0 subinterface 100 ipv4 arp evpn advertise dynamic
set / network-instance macvrf-svc-0042 interface irb0.100
set / network-instance macvrf-svc-0042 bridge-table protect-anycast-gw-mac true
set / network-instance ipvrf-svc-0042 type ip-vrf
set / network-instance ipvrf-svc-0042 interface irb0.100
set / network-instance ipvrf-svc-0042 vxlan-interface vxlan0.10022
```

### `acl`

`/acl/acl-filter[name=<F>][type=<T>]`, keyed by **name and type**, with `description`
`<tenant>/<id> <stage>` and `statistics-per-entry true`; one `entry[sequence-id=<S>]` per rule, plus
the default-action entry when declared; bound through `/acl/interface[interface-id=<port>.<idx>]`
with an explicit `interface-ref` (`interface`, `subinterface`) and an `input` (ingress) or `output`
(egress) `acl-filter[name][type]` reference. An egress filter also carries `subinterface-specific
output-only` (or `input-and-output`). The `interface-ref` is written by the configuration that owns
the subinterface; a standalone `acl` writes only the filter and its `input`/`output` reference, and
never creates a subinterface (FR-035, FR-037).

```text
set / acl acl-filter acl-svc-0042-ingress type ipv4 description "tenant1/svc-0042 ingress"
set / acl acl-filter acl-svc-0042-ingress type ipv4 statistics-per-entry true
set / acl acl-filter acl-svc-0042-ingress type ipv4 entry 100 description "permit-https"
set / acl acl-filter acl-svc-0042-ingress type ipv4 entry 100 match ipv4 protocol tcp
set / acl acl-filter acl-svc-0042-ingress type ipv4 entry 100 match ipv4 source-ip prefix 10.0.0.0/24
set / acl acl-filter acl-svc-0042-ingress type ipv4 entry 100 match transport destination-port operator eq
set / acl acl-filter acl-svc-0042-ingress type ipv4 entry 100 match transport destination-port value 443
set / acl acl-filter acl-svc-0042-ingress type ipv4 entry 100 action accept
set / acl acl-filter acl-svc-0042-ingress type ipv4 entry 65535 description "default-deny"
set / acl acl-filter acl-svc-0042-ingress type ipv4 entry 65535 action drop
set / acl interface ethernet-1/1.100 interface-ref interface ethernet-1/1
set / acl interface ethernet-1/1.100 interface-ref subinterface 100
set / acl interface ethernet-1/1.100 input acl-filter acl-svc-0042-ingress type ipv4
```

The full render and verification contract, including the per-filter, per-entry read-back, is
`contracts/acl-render-contract.md`.

## How access-list rules are ordered

- A rule's `priority` is rendered as the entry's `sequence-id` **unchanged**: what the operator
  wrote is what the device shows.
- Entries are evaluated in **ascending** `sequence-id` order and **the first match wins**: priority
  100 is evaluated before priority 200.
- The usable range is **`1–65534`**. Priorities must be distinct within a list, and so must rule
  names.
- **`65535` is reserved** for the terminal match-all entry, rendered **only when a default action
  is declared**. A rule at 65535 is refused, and the refusal states that `1–65534` is usable
  (FR-039, FR-040).

The evaluation order and the usable range are stated to the operator at the first confirmation.

## What happens to unmatched traffic

- **With no default action declared, unmatched traffic is ACCEPTED.** That is the device's own
  implicit behaviour. Nothing is rendered at 65535, the first confirmation says that unmatched
  traffic is accepted by the device's default, and the platform never describes the list as
  restrictive beyond its explicit rules (FR-041).
- **`defaultAction: deny`** renders `entry 65535` with `action drop {}` (description
  `default-deny`). This is the only way "deny everything else" is true.
- **`defaultAction: permit`** renders `entry 65535` with `action accept {}` (description
  `default-permit`). This behaves like the implicit default, but it is rendered anyway so the
  read-back has an entry to assert.

## Constraints that survive

Enforced per construct, with the cause stated in construct terms (FR-034):

- **One service VLAN across every endpoint** of a `vlan` or `mac-vrf`: one bridge domain is one
  broadcast domain.
- **The VNI band** `10000–20000`, inside the device's EVPN instance range, because `evi := vni`.
- **The VLAN naming band** `100–999` (see above), refused with both bands stated.
- **One tagging mode per port** (FR-034, amended by AD-68): an untagged attachment (subinterface
  `0`) and a tagged one never share a port. The mode is the one the site inventory declares for the
  port (tagged unless declared untagged). An attachment asking for the other mode is refused, and
  the refusal lists the ports declared in the mode it asked for.
- **One owner per (node, port, VLAN)**: two services deriving the same attachment subinterface are
  refused before any device write, naming the holding service.
- **Access-list binding exclusivity**: the key is
  `(node, subinterface, direction, address family)`, for example
  `leaf01 / ethernet-1/1 / 100 / input / ipv4`. One filter per address family per subinterface per
  direction. A second binding is refused naming the holder, and a holder that is being removed
  still holds the key until it is gone (FR-043). `ethernet-1/1.0` and `ethernet-1/1.100` do not
  conflict.
- An access list is owned by exactly one service. Naming an existing list instead of stating rules
  is refused.
- A spine is never an attachment. The node and the port must exist in the site inventory, and a
  refusal lists the valid names.
- **A VNI and a service VLAN cannot be edited.** Once accepted, `l2vni`, `l3vni` and the service
  VLAN are immutable. To change one, remove the service and create it again (AD-25). Attachments,
  access lists, prefixes and gateway addresses stay mutable.
- A construct or property the qualification record does not show as qualified is refused at
  interpretation, before any identifier is claimed (FR-097).

## What remains unsupported

Refused by name. Listed in the contracts and the specification:

- **Traffic engineering, pseudowire OAM, control word, multicast VPN, complex or unmapped QoS,
  service chaining, and raw device CLI** as input (construct-vocabulary §5, FR-045).
- **A route-distinguisher field**: none exists, and none may be set.
- EVPN multihoming, IPv6 VXLAN tunnel endpoints, SRv6 in any form, and feature-exact QoS or OAM
  translation (spec Assumptions).
- **Access lists**:
  - Layer 2 (`type mac`) lists are out of scope (FR-038).
  - `egress` is accepted only when the qualification record shows it qualified (FR-097).
  - Not in the match set: `tcp-flags`, `dscp`, `ttl`, `hop-limit`, fragment matching,
    `ip-option-present`, ICMP/ICMPv6 type and code, and `prefix-list` references.
  - Also out of scope: `log`, mirroring, policers and rate limiting, `copy`, `forward next-hop`,
    forwarding-class actions, and policy-based forwarding.
  - The platform does not write control-plane (`cpm`), `system` or `capture` filters. The names
    `system` and `capture` are reserved.
  - A list cannot bind to a network instance, a VLAN as such, an IRB subinterface, or fabric-wide.
  - L4 ports work only with TCP or UDP.
- A second access list of the same address family and direction on one subinterface (FR-043).

## Refusals

Every refusal is all-or-nothing: nothing is created. Every cause names its property path
(construct-vocabulary §7):

```json
{
  "error": "validation",
  "causes": [
    "l2vni: a vlan is local to the node; ask for a mac-vrf to extend it over the fabric",
    "acl.rules[2].priority: 100 is already used by another rule; priorities must be distinct",
    "endpoints[0].attachment: leaf01 has no port 'ethernet-9/9'; this site's ports are ethernet-1/1, ethernet-1/49, ethernet-1/50"
  ]
}
```

- **An unknown construct**: the refusal lists the four, `vlan, mac-vrf, ip-vrf, acl` (FR-028).
- **A capability the fabric cannot render**: the refusal offers the nearest construct **by its
  construct name** (FR-084).
- **A variable that belongs to another construct**: the refusal names both the property and the
  construct that carries it (FR-033).
- **An unqualified construct or property**: the refusal names it and says what the qualification
  record shows for it (FR-097).

## Migration aliases (accepted on input only)

The six keys below are the brownfield vocabulary the migration path reads. Each is a **migration
alias**. It is folded into its construct on input, before any validator or translator sees it. The
arrival spelling is recorded only as **provenance**: the `agentic-netops.io/source-service-type`
annotation, excluded from the canonical hash. **No output anywhere emits an alias as a type**
(FR-026, FR-044, FR-085).

| Key | Construct | Recorded as |
|---|---|---|
| `vpls` | `mac-vrf` | migration alias; provenance `VPLS` |
| `vpws` | `mac-vrf` | migration alias; provenance `VPWS` |
| `eline` | `mac-vrf` | migration alias; provenance `VPWS` |
| `l3vpn` | `ip-vrf` | migration alias; provenance `L3VPN` |
| `l2l3irb` | `mac-vrf` | migration alias; provenance `L2L3-IRB` |
| `irb` | `mac-vrf` | migration alias; provenance `L2L3-IRB` |

A request arriving through the point-to-point L2 migration alias (provenance `VPWS`) is also held
to exactly two endpoints and needs the limited-equivalence opt-in set explicitly true. A request
that names `mac-vrf` directly is subject to neither constraint (FR-047).

## The four cited SR Linux 25.7 references

For release 25.7 at the vendor documentation site, <https://documentation.nokia.com/srlinux/25-7/>.
A newcomer who has read only these can provision each construct without a translation table
(SC-013). For `mac-vrf` and `ip-vrf`, the construct name **is** the word these references use.

1. **Bridging: `mac-vrf` network-instances and VLAN subinterfaces.** SR Linux 25.7 *Interfaces
   Guide* (subinterfaces, `single-tagged` VLAN encapsulation, bridged type), read with the
   `mac-vrf` network-instance. Covers `vlan`.
2. **EVPN-VXLAN Layer 2.** SR Linux 25.7 *EVPN-VXLAN Guide*, Layer 2 services: `vxlan-interface`
   of type bridged, `bgp-evpn`, `bgp-vpn` route targets. Covers `mac-vrf`.
3. **EVPN-VXLAN Layer 3: `ip-vrf` and IRB with an anycast gateway.** SR Linux 25.7 *EVPN-VXLAN
   Guide*, Layer 3 services: routed `vxlan-interface`, EVPN IP-prefix routes, `irb0` subinterfaces
   with `anycast-gw`. Covers `ip-vrf` and the `mac-vrf` gateway.
4. **Access control lists.** SR Linux 25.7 *ACL and Policy-Based Routing Guide*:
   `acl-filter [name][type]`, `entry sequence-id`, `/acl interface` bindings, input and output.
   Covers `acl`.

The vendor's public learning tutorials, at <https://learn.srlinux.dev/tutorials/>:

- the **L2 EVPN** tutorial (`mac-vrf` over EVPN-VXLAN), <https://learn.srlinux.dev/tutorials/l2evpn/intro/>;
- the **L3 EVPN** tutorial (`ip-vrf`, EVPN IP-prefix routes).
