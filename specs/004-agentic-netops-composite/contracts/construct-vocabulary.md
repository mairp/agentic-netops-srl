# Contract: construct vocabulary

**Feature**: `004-agentic-netops-composite` | **Carries**: FR-024 to FR-034, FR-044, FR-047,
FR-083 to FR-085, FR-097, FR-099 | **Decisions**: D-10, D-15, D-17, D-19, D-26, RD-05, RD-06, RD-09

**Consumers**: the mapper's prompt and catalogue, `Interpretation`, `NormalizedServiceIntent`, the
translator, every refusal message, every operator-facing document.

This is the single authority for what an operator may name and what each name requires. **If a
surface disagrees with this file, the surface is wrong.**

## 1. The four constructs

```text
vlan      a local broadcast domain: a VLAN and the ports in it
mac-vrf   a VLAN extended over the fabric by an L2VNI with EVPN route targets
ip-vrf    a routed instance: a VRF with an L3VNI and route targets
acl       a filter bound to the attachment subinterfaces a service occupies
```

Reported to an operator in that order. **Nothing else is advertised as a type an operator can ask
for** (FR-024).

`mac-vrf` and `ip-vrf` are **the device's own names** for its bridged and routed network-instance
types, not this platform's coinages. That alignment is a requirement, asserted in CI against the
pinned device model, so that an operator who reads the device documentation and an operator who
reads this platform's documentation learn the same two words (FR-099). `vlan` and `acl` are operator
vocabulary and are documented below with the device objects they render.

## 2. Name resolution (FR-025)

The key function lowercases the input, then deletes every `-`, `_`, space, `.` and `+`.

Two spellings naming the same key are the same construct: `IP-VRF`, `ip_vrf`, `MAC VRF`, `macvrf`
and `Mac-Vrf` all resolve. A key not in the table below is refused with the four construct names
listed (FR-028).

| Key | Construct | Kind |
|---|---|---|
| `vlan` | `vlan` | construct |
| `macvrf` | `mac-vrf` | construct |
| `ipvrf` | `ip-vrf` | construct |
| `acl` | `acl` | construct |
| `l2vni` | `mac-vrf` | synonym |
| `l3vni` | `ip-vrf` | synonym |
| `accesslist` | `acl` | synonym |
| `vpls` | `mac-vrf` | **migration alias**, records `VPLS` as the arrival vocabulary |
| `vpws` | `mac-vrf` | **migration alias**, records `VPWS` |
| `eline` | `mac-vrf` | **migration alias**, records `VPWS` |
| `l3vpn` | `ip-vrf` | **migration alias**, records `L3VPN` |
| `l2l3irb` | `mac-vrf` | **migration alias**, records `L2L3-IRB` |
| `irb` | `mac-vrf` | **migration alias**, records `L2L3-IRB` |

The last six rows are the **migration aliases** — the brownfield vocabulary the migration path
exists to read. They are accepted on **input only**, folded before any validator or translator sees
them, and **no output anywhere ever emits one as a type** (FR-026, FR-044, FR-085). The recorded
arrival vocabulary is provenance, not a type.

## 3. Per-construct variables

`R` required · `O` optional · `D` **derived** — computed by the platform, shown in the assignment
exactly as it will be rendered, and refused if the operator supplies it · `X` refused, naming the
construct that carries it.

| Variable | `vlan` | `mac-vrf` | `ip-vrf` | `acl` |
|---|---|---|---|---|
| `tenant` | R | R | R | R |
| `endpoints[].node`, `.attachment` | R | R | R | R |
| `endpoints[].vlan` | R (shared) | R (shared) | O (per attachment) | O (names the subinterface) |
| `endpoints[].vrf` | — | — | R | — |
| `l2vni` | X | R | X | X |
| `l3vni` | X | O (R with a gateway) | R | X |
| `routeTargets` | X | D | D | X |
| `addressFamilies` | — | — | R (≥1 prefix) | — |
| `anycastGateway` | X | O | X | X |
| `acl` | O | O | O | R |
| minimum endpoints | 1 | 2 (1 with a gateway) | 1 | 1 |

The endpoint minimum lives here and in the validator, **not** as a schema floor — three of the four
constructs are legitimately single-attachment, and a floor of two would make a valid request
unrepresentable before any validator could explain why (D-26).

**There is no route-distinguisher variable.** The device derives the distinguisher itself from the
attachment leaf's system address and the EVPN instance identifier; it is per-leaf unique by
construction and needs no fabric-wide identifier. It is neither claimed, nor rendered, nor shown.

**`routeTargets` is derived and shown.** Import and export are `target:<fabricASN>:<vni>`, where
`fabricASN` is a fabric-wide constant, and they appear in the assignment before the second
confirmation so the operator confirms what will actually be written (FR-062). They are rendered
explicitly rather than left to the device's own auto-derivation, which would use each leaf's own
autonomous-system number and produce a route target that silently never matches.

**An `ip-vrf` endpoint's `vlan` is named or absent, never allocated (AD-51 — operator).** `O (per
attachment)` means exactly that: an operator who wants a tagged routed subinterface names its VLAN,
from the naming band `100–999`, and an endpoint that names none is the untagged subinterface
`<port>.0`. The allocator claims no VLAN for an `ip-vrf`; the only VLANs the platform allocates are
the shared VLAN of a `vlan` or a `mac-vrf` whose operator named none
([kuid-claim-profiles.md](./kuid-claim-profiles.md) §2).

**An `acl` endpoint MAY carry `vlan`.** It names *which* subinterface of the port to bind; it never
creates one. With no VLAN the binding is the untagged subinterface. The named node, port and VLAN
must already resolve to an attachment another service created, or the request is refused naming the
missing attachment (FR-035, FR-037).

### 3.1 Access-list variables

| Variable | Values | Notes |
|---|---|---|
| `stage` | `ingress` \| `egress` | Renders as the device's input or output direction. `egress` is refused when the qualification record does not show it qualified on the pinned profile (FR-097) |
| `type` | `ipv4` \| `ipv6` | The address family. Input spellings `l3`, `l3v6`, `ip` and `ipv6` fold to these two. A Layer 2 (MAC) list is refused as out of scope — the construct is defined over address families (FR-038) |
| `rules[].name` | 1–255 characters | A label carried into the device entry's description. The **identity** of a rule is its priority |
| `rules[].priority` | **1–65534**, distinct | **Evaluated in ascending order, first match wins**: priority 100 is evaluated before priority 200. Rendered as the device's entry sequence number **unchanged**, so what the operator wrote is what the device shows. **65535 is reserved** for the default action and is refused to a rule, with the usable range stated (FR-039, FR-040) |
| `rules[].action` | `permit` \| `deny` | |
| `rules[].protocol` | a known name or a number 0–255 | **`icmpv6` is accepted.** L4 ports require TCP or UDP |
| `rules[].sourcePrefix`, `.destinationPrefix` | a prefix in the list's own family | A wrong-family prefix is refused |
| `rules[].sourcePort`, `.destinationPort` | a value or a `lo-hi` range | TCP or UDP only |
| `defaultAction` | `permit` \| `deny`, optional | Rendered explicitly as a terminal match-all entry at the reserved last position. **When it is absent the confirmation MUST state that unmatched traffic is accepted by the device's own default** — it is never left implied (FR-041) |

The evaluation order and the usable priority range MUST be stated to the operator **at the first
confirmation** (FR-039).

## 4. What each construct renders (FR-083, FR-099)

Native device object names, as an operator would find them in the device's own documentation.

| Construct | Renders as |
|---|---|
| `vlan` | a `network-instance` of type **`mac-vrf`** with **no** VXLAN interface, **no** `bgp-evpn` and **no** `bgp-vpn` — a purely local bridge domain — plus its bridged subinterfaces `ethernet-1/N.<vlan>` (`single-tagged vlan-id`, on a port whose `vlan-tagging true` the fabric configuration renders — AD-68). It remains its own construct and its own list precisely because the device realizes it with the same instance type as `mac-vrf`, so that "local" is never encoded as "the overlay fields happen to be missing" (FR-029) |
| `mac-vrf` | a `network-instance` of type **`mac-vrf`**; bridged subinterfaces `ethernet-1/N.<vlan>`; `tunnel-interface vxlan0` with a `vxlan-interface <l2vni>` of `type bridged` and `ingress vni <l2vni>`; `bgp-evpn bgp-instance 1` carrying the VXLAN interface, the EVPN instance identifier and ECMP; `bgp-vpn bgp-instance 1` carrying the explicit export and import route targets |
| `ip-vrf` | a `network-instance` of type **`ip-vrf`**; routed subinterfaces; a `vxlan-interface <l3vni>` of `type routed`; `bgp-evpn` in the interface-less model, so the declared prefixes are advertised as EVPN IP-prefix routes reachable through the attachment subnets |
| `mac-vrf` + anycast gateway | the `mac-vrf` above, plus an `irb0.<vlan>` subinterface carrying `anycast-gw true` addresses and an `anycast-gw virtual-router-id`, attached to **both** the `mac-vrf` and the `ip-vrf`, with ARP/ND `learn-unsolicited`, host-route population and EVPN advertisement — **only** for the address families the operator declared |
| `acl` | an `acl-filter` keyed by **name and type** with one `entry` per rule and per default action, `statistics-per-entry true`, bound through `acl interface <ethernet-1/N>.<idx>` with an explicit `interface-ref` and an `input` or `output` filter reference. See [acl-render-contract.md](./acl-render-contract.md) |

The identity of the two shared names is a CI assertion against the pinned device model, not a
coincidence (FR-099): if a future device release renames its bridged or routed instance type, this
vocabulary changes with it or the assertion fails.

## 5. Constraints that survive the vocabulary change (FR-034)

| Constraint | Applies to | The cause text names |
|---|---|---|
| One service VLAN across every endpoint | `vlan`, `mac-vrf` | the two differing VLANs, and that one bridge domain is one broadcast domain |
| The VNI band is a subset of the range the device's EVPN instance identifier can carry | `mac-vrf`, `ip-vrf`, gateway-bearing `mac-vrf` | the VNI and the band, because the instance identifier is derived from the VNI |
| The naming band: a VLAN an operator names comes from `100–999` (FR-062, AD-33) | `vlan`, `mac-vrf`, `ip-vrf` — never the VLAN a standalone `acl` names, which is a reference to another service's subinterface (AD-47) | the requested VLAN and **both bands** — `100–999` to name from, `1000–4000` the allocation authority's; refused by the mapper at interpretation, before any claim (AD-41), for a value below `100`, in `1000–4000` or anywhere above `4000` alike — the interpretation schema floors a VLAN at `0` and carries no upper bound, so that no integer an operator can type is turned away by schema validation with neither band stated (AD-56, AD-61) |
| One owner per (node, port, VLAN) | all four | the holding service, the port and the VLAN — two services deriving the same attachment subinterface is a name collision caught by comparison, before any device write |
| A service attachment may not be a spine | all four | the node, and that spines are not attachment points |
| Site inventory: the node and the attachment must exist | all four | the offending name and the site's real names |
| Rule priorities are distinct, and the last evaluation position is reserved for the default action | any construct carrying an `acl` | the colliding or reserved priority, and that 1–65534 is usable |
| An access list is owned by exactly one service; naming an existing list instead of stating rules is refused | any construct carrying an `acl` | that a service carries its own rules |
| An attachment subinterface already carrying another service's list in the same direction for the same address family | any construct carrying an `acl` | the service that holds the binding — and, when that service is being removed, that it holds it until it is gone |
| The construct or property is not shown as qualified in the fabric's qualification record | all four | what is unqualified, refused **at interpretation**, before any identifier is claimed or any resource created (FR-097) |
| Unsupported claims — traffic engineering, pseudowire OAM, control word, multicast VPN, complex QoS, service chaining, raw device CLI | all four | the claim by name |

The band values themselves are platform-specific:
[platform-coupling.md](../platform-coupling.md), and the claimed-versus-derived split is in
[kuid-claim-profiles.md](./kuid-claim-profiles.md).

*Retired by the retarget (RD-09): the "reserved derived-VLAN band" and the "renderable L3VNI
sub-band" constraints. This platform derives no routed-instance VLAN, so neither band has a
referent; the VNI-band and VLAN-range rows above replace them.*

## 6. Constraints scoped to a source vocabulary (FR-047)

Applied when and only when the recorded arrival vocabulary says the request came that way. A
request naming `mac-vrf` directly is subject to neither.

| Arrival vocabulary | Extra constraint |
|---|---|
| The point-to-point L2 alias | exactly 2 endpoints |
| The point-to-point L2 alias | the limited-equivalence opt-in must be explicitly true |

The recorded arrival vocabulary is excluded from the canonical hash, so the same service hashes
identically in either vocabulary (D-19).

## 7. Refusal shape

Every refusal is all-or-nothing and every cause names its property path:

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

A refusal for an unknown construct lists the four (FR-028). A refusal for a capability the fabric
cannot render offers the nearest construct **by its construct name** (FR-084). A refusal for a
wrong-construct variable names both the property and the construct that carries it (FR-033). A
refusal for an unqualified construct or property names what is unqualified and what the
qualification record says about it (FR-097).

## 8. The four cited device references (SC-013)

A newcomer who has read only these can provision each construct without a translation table:

1. the device vendor's published documentation for **bridging: `mac-vrf` network-instances and VLAN
   subinterfaces**;
2. the device vendor's published documentation for **EVPN-VXLAN Layer 2**;
3. the device vendor's published documentation for **EVPN-VXLAN Layer 3: `ip-vrf` and IRB with an
   anycast gateway**;
4. the device vendor's published documentation for **access control lists**;

as published for the pinned release at the vendor's documentation site, together with the vendor's
public L2 and L3 EVPN learning tutorials. For `mac-vrf` and `ip-vrf`, the construct name **is** the
word those references use (RD-06).
