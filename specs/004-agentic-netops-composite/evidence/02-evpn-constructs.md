# 02 — The SR Linux EVPN/VXLAN configuration and state model, and how the four constructs render onto it

**Research agent report** | **Date**: 2026-09-20 | **Feature**: `004-agentic-netops-composite` (SR Linux retarget)
**Replaces couplings**: PC-11, PC-15, PC-16, PC-17, PC-A-07, PC-A-12 · **Answers**: [spec.md](../../../../root/agentic-netops-srl/specs/004-agentic-netops-composite/spec.md) §Open decisions 5

Every factual claim below is tagged `[VERIFIED: <source>]` or `[UNVERIFIED: from memory]` per the
constitution's Principle I. "VERIFIED" means I read it in that source during this session.

---

## 0. Release pin and the provenance of every YANG citation in this report

**Pin `ghcr.io/nokia/srlinux:25.7.1`**, digest
`sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402`
[VERIFIED: ghcr.io registry API `https://ghcr.io/v2/nokia/srlinux/manifests/25.7.1`, via the
toolchain research pass this session].

The binding constraint is **sdcio**, not containerlab and not Nokia: 25.7.1 is the newest release
for which sdcio has a first-party, CI-exercised `Schema` definition, and `sdcio/srlinux-yang-patch`
has branches only up to `v25.7` — no `v25.10`, `v26.3` or `v26.7`
[VERIFIED: `git ls-remote --heads https://github.com/sdcio/srlinux-yang-patch.git`;
`sdcio/integration-tests` @ `7666a7f` (2026-09-07) pins `ghcr.io/nokia/srlinux:25.7.1` and
`schema-nokia-srl-25.7.1.yaml`]. containerlab 0.79.0 supports up to and past v26.3
[VERIFIED: `nodes/srl/version.go` @ tag `v0.79.0`], so it is not the gate.

**Every YANG path, range, pattern, enum and `must` quoted below was re-checked at tag `v25.7.1`**
of `github.com/nokia/srlinux-yang-models`, cloned this session to
`/tmp/claude-0/-root-agentic-netops-srl/77a4cc1d-228f-434a-a329-d82df9d3fa56/scratchpad/research/src/srlinux-yang-models`.
Where a fact also holds at v25.10.3 / v26.7.2 I say so.

Local path convention used below:
`$Y = <clone>/srlinux-yang-models/srl_nokia/models`.

Modules that matter, with their YANG module name and prefix
[VERIFIED: module headers at v25.7.1]:

| Module name (use this in JSON_IETF) | Prefix (use this in XPath/`must`) | Namespace |
|---|---|---|
| `srl_nokia-network-instance` | `srl_nokia-netinst` | `urn:nokia.com:srlinux:net-inst:network-instance` |
| `srl_nokia-interfaces` | `srl_nokia-if` | — |
| `srl_nokia-interfaces-vlans` | `srl_nokia-if-vlan` | `urn:nokia.com:srlinux:chassis:interfaces-vlans` |
| `srl_nokia-if-ip` | `srl_nokia-if-ip` | — (grouping-only; its nodes land in `srl_nokia-interfaces`' namespace) |
| `srl_nokia-interfaces-nbr` | `srl_nokia-if-ip-nbr` | — |
| `srl_nokia-interfaces-nbr-evpn` | — | — |
| `srl_nokia-tunnel-interfaces` | `srl_nokia-tunnel-if` | `urn:nokia.com:srlinux:vxlan:tunnel-interfaces` |
| `srl_nokia-tunnel` | `srl_nokia-tunnel` | — |
| `srl_nokia-vxlan-tunnel-vtep` | — | — |
| `srl_nokia-bgp` | `srl_nokia-bgp` | — |
| `srl_nokia-bgp-evpn` | `srl_nokia-bgp-evpn` | — |
| `srl_nokia-bgp-vpn` | `srl_nokia-bgp-vpn` | `urn:nokia.com:srlinux:bgp:bgp-vpn` |
| `srl_nokia-ip-route-tables` | `srl_nokia-ip-route-tables` | — |
| `srl_nokia-rib-bgp` | — | — |
| `srl_nokia-bridge-table-mac-table` | — | — |

**Which nodes need a module prefix in JSON_IETF** is decided by `augment` vs `uses`
[VERIFIED: augment statements grepped at v25.7.1]:

- `srl_nokia-interfaces-vlans` augments `/interface` and `/interface/subinterface` →
  `vlan-tagging` and `vlan` are **prefixed**.
- `srl_nokia-if-ip` is consumed by `uses` inside `srl_nokia-interfaces` → `ipv4`, `ipv6`,
  `anycast-gw` are **not** prefixed.
- `srl_nokia-interfaces-nbr` augments `.../ipv4` and `.../ipv6` → `arp` and
  `neighbor-discovery` are **prefixed**.
- `srl_nokia-interfaces-nbr-evpn` augments `.../ipv4/arp` and `.../ipv6/neighbor-discovery` →
  `evpn` is **prefixed**.
- `srl_nokia-bgp-evpn` augments `/network-instance/protocols/bgp-evpn` → the `bgp-evpn` container
  itself is **not** prefixed (it is declared in `srl_nokia-network-instance`), but the
  `bgp-instance` list inside it **is**.
- `srl_nokia-bgp-vpn` augments `/network-instance/protocols` → `bgp-vpn` **is** prefixed.
- `srl_nokia-vxlan-tunnel-vtep` augments `/tunnel` → `vxlan-tunnel` **is** prefixed.
- `srl_nokia-ip-route-tables` augments `/network-instance/route-table` → `route-table` is not
  prefixed, `ipv4-unicast`/`ipv6-unicast` **are**.
- `srl_nokia-rib-bgp` augments `/network-instance` → `bgp-rib` **is** prefixed.

gNMI default model set: `/system/grpc-server[name=*]/yang-models` has
`type enumeration { enum native; enum openconfig; }` with `default "native"`
[VERIFIED: `$Y/grpc/srl_nokia-grpc.yang:466-476` @ v25.7.1]. So no `origin` is needed on paths as
long as the server keeps the default; with `openconfig` selected you must prefix paths with
`native:` [VERIFIED: `/root/learn-srlinux/docs/tutorials/infrastructure/kne/srl-with-oc-services/index.md:218`].

**A decisive finding for FR-017 / PC-14**: SR Linux's own OpenConfig deviation file marks the whole
EVPN surface `not-supported`:

```
deviation ".../network-instance/openconfig-network-instance:evpn"                         { deviate not-supported; }
deviation ".../bgp/openconfig-network-instance:global/.../afi-safi/...:l2vpn-evpn"        { deviate not-supported; }
deviation ".../bgp/openconfig-network-instance:neighbors/.../afi-safi/...:l2vpn-evpn"     { deviate not-supported; }
deviation ".../bgp/openconfig-network-instance:peer-groups/.../afi-safi/...:l2vpn-evpn"   { deviate not-supported; }
deviation ".../bgp/openconfig-network-instance:rib/.../afi-safi/...:l2vpn-evpn"           { deviate not-supported; }
deviation ".../network-instance/openconfig-network-instance:encapsulation"                { deviate not-supported; }
deviation ".../network-instance/openconfig-network-instance:fdb"                          { deviate not-supported; }
```
[VERIFIED: `<clone>/srlinux-yang-models/openconfig/openconfig-srl-deviations.yang` lines 3620, 3908,
4080, 4260, 4468 @ v25.7.1; the file contains 900 `deviate not-supported` statements in total].

**Consequence**: every construct in this report renders on **native `srl_nokia-*` YANG, by
necessity, not by preference.** The OpenConfig-versus-native path register (FR-017, PC-N-12) does
*not* collapse under this retarget — it gets a single, sharp, machine-checkable justification per
EVPN path: *"`openconfig-srl-deviations.yang` @ v25.7.1 marks the OpenConfig equivalent
`not-supported`."* That is a much stronger justification than the SONiC register had.

---

## 1. Underlay

### 1.1 Recommendation

**Recommended**: numbered eBGP IPv4 `/31` (or `/30`) point-to-point in `network-instance default`,
loopback on `system0.0`, and an **iBGP EVPN overlay** in one AS with the **two spines as route
reflectors** (`route-reflector client true` on the spine's overlay group). Spines carry **no**
`mac-vrf`, no `ip-vrf`, no `tunnel-interface` — they are IP transit plus RR, exactly as FR-011
requires.

**Why numbered rather than unnumbered**: FR-012 makes the allocation authority the owner of
"IP addresses, ASNs, VLANs, VNIs", and kubenet/KUID already model links and link IPAM. Numbered
keeps that path intact and keeps the underlay reconstructable from the allocation records alone.
Unnumbered is a *documented alternative* (§1.4) that trades those claims for RA-based discovery.

**Why iBGP-with-RR rather than eBGP overlay**: with two spines as RRs, a leaf holds exactly two
overlay sessions regardless of leaf count, the next-hop is unchanged end-to-end (so
`use-system-ipv4-address` next-hops resolve directly to the underlay `/32`), and the overlay AS is
a single fabric-wide constant instead of a per-node claim. eBGP overlay (spines as route *servers*,
i.e. `ebgp` with next-hop unchanged) works on SR Linux too but needs `next-hop-unchanged`-style
policy the RR design gets for free.

**Mandatory on the spines: `inter-as-vpn true`.** A spine that is not a VTEP has no `mac-vrf` or
`ip-vrf`, therefore no locally-imported route target, and SR Linux **rejects and does not
re-advertise** EVPN routes whose RTs match nothing locally. The override is:

```srl
set / network-instance default protocols bgp afi-safi evpn admin-state enable
set / network-instance default protocols bgp afi-safi evpn evpn inter-as-vpn true
```

Exact path and semantics, from the model itself:

```
/network-instance[name=default]/protocols/bgp/afi-safi[afi-safi-name=srl_nokia-common:evpn]/evpn/inter-as-vpn
  type boolean; default "false";
  must ". = false() or (… type = 'srl_nokia-netinst:default')"   // EVPN only in the default instance
  description "When set to true, received EVPN routes that are not imported by any network-instance
               are retained in the BGP RIB and considered 'used' so that they can be propagated to
               any EBGP or IBGP peer. This command supersedes the effect of keep-all-routes."
```
[VERIFIED: `$Y/network-instance/srl_nokia-bgp.yang:4467-4478` (the `container evpn` under the
`afi-safi` list begins at `:4427`) @ v25.7.1. There is **no** `if-feature` on this leaf, so it is
unconditionally available.]

Note the sibling `keep-all-routes` is *not* a substitute: it retains the routes but marks them
`rejected`, and *"these routes … cannot be propagated to other peers"*
[VERIFIED: same file, `:4441-4451`]. Only `inter-as-vpn` makes them propagate.

The operational framing:

> *"On the spines, the configuration option `inter-as-vpn` must be set to `true` … Since the spines
> are not configured as VTEPs and act as pure IP forwarders in this design, there are no Layer 2 or
> Layer 3 VXLAN constructs created on the spines, associated to any route targets for EVPN route
> import. By default, such routes (which have no local route target for import) will be rejected and
> not advertised to other leafs."*
[VERIFIED: `/root/learn-srlinux/docs/blog/posts/2024/srlinux-asymmetric-routing.md:700-704`, config
shape at `:596-602`]

**This is the single most likely cause of a fabric that comes up with every session `established`,
every `oper-state up`, and zero EVPN routes anywhere.** It must be part of the spine render and part
of the capability gate, not discovered during the first service apply.

**The AS-plan trap that decides route-target strategy.** SR Linux auto-derives the route target as
`target:<asn>:<evi>` where `<asn>` is `/network-instance[name=default]/protocols/bgp/autonomous-system`.
In a classic eBGP-underlay Clos that leaf is **different on every leaf**, so auto-derived RTs never
match and a service silently never forms. The learn.srlinux.dev L3 tutorial hits this and configures
RTs manually for exactly this reason: *"otherwise auto-derivation process will use the AS number
specified under the global BGP process, and we have different AS numbers per leaf"*
[VERIFIED: `/root/learn-srlinux/docs/tutorials/l3evpn/rt5-only/l3evpn.md:86`]. Two ways out, and the
choice belongs here rather than in §8:

| Option | Underlay AS plan | RT strategy | Read-back origin |
|---|---|---|---|
| **(a) — recommended** | global `autonomous-system` = per-leaf eBGP ASN; overlay group carries `local-as as-number <fabric-asn>` | **Render RT explicitly** as `target:<fabricASN>:<evi>` | `manual` |
| (b) | global `autonomous-system` = the fabric overlay ASN on every leaf; underlay group carries `local-as as-number <per-leaf-asn>` | let SR Linux auto-derive | `auto-derived-from-evi` |

**Recommend (a).** It matches both learn.srlinux.dev tutorials' AS plan, keeps the underlay AS the
"real" one for troubleshooting, and the RT stays claim-free anyway because it is *derived by the
platform* from an allocated VNI plus a fabric-wide constant (§8.2). Option (b) buys a prettier
read-back leaf at the cost of a surprising AS plan.

The **route distinguisher is safe either way**: it auto-derives from the `system0.0` IPv4 address,
not the ASN, so it is per-leaf unique by construction. Leave it auto-derived.

### 1.2 Exact config paths (all in `network-instance default`)

```
/interface[name=ethernet-1/N]/subinterface[index=0]/type                      = srl_nokia-if:routed
/interface[name=ethernet-1/N]/subinterface[index=0]/ipv4/admin-state
/interface[name=ethernet-1/N]/subinterface[index=0]/ipv4/address[ip-prefix=…]
/interface[name=system0]/subinterface[index=0]/ipv4/address[ip-prefix=10.0.0.1/32]
/network-instance[name=default]/interface[name=ethernet-1/N.0]
/network-instance[name=default]/interface[name=system0.0]
/network-instance[name=default]/protocols/bgp/autonomous-system
/network-instance[name=default]/protocols/bgp/router-id
/network-instance[name=default]/protocols/bgp/afi-safi[afi-safi-name=ipv4-unicast]/admin-state
/network-instance[name=default]/protocols/bgp/group[group-name=underlay]/…
/network-instance[name=default]/protocols/bgp/neighbor[peer-address=…]/peer-group
/network-instance[name=default]/protocols/bgp/group[group-name=overlay]/afi-safi[afi-safi-name=evpn]/admin-state
/network-instance[name=default]/protocols/bgp/group[group-name=overlay]/local-as/as-number
/network-instance[name=default]/protocols/bgp/group[group-name=overlay]/route-reflector/client
/network-instance[name=default]/protocols/bgp/neighbor[peer-address=…]/transport/local-address
/network-instance[name=default]/protocols/bgp/ebgp-default-policy/import-reject-all
/network-instance[name=default]/protocols/bgp/ebgp-default-policy/export-reject-all
```
[VERIFIED: `$Y/network-instance/srl_nokia-bgp.yang` @ v25.7.1 — `route-reflector/client` at line 1196
(group) and 2629 (neighbor); `local-as/as-number` at 1158/2590; `transport/local-address` at
1353/2801; `ebgp-default-policy/import-reject-all` default `true` at 3950; `export-reject-all`
default `true` at 3956]

**Gotcha that will bite the first apply**: `ebgp-default-policy/import-reject-all` and
`export-reject-all` both **default to `true`**, so an eBGP underlay with no explicit import/export
policy advertises and accepts nothing. The learn.srlinux.dev tutorials work around this with an
`accept`-everything policy in the L2 tutorial and a loopback prefix-set policy in the L3 one
[VERIFIED: `https://learn.srlinux.dev/tutorials/l2evpn/fabric/` —
`set / routing-policy policy all default-action policy-result accept` plus
`group eBGP-underlay export-policy [ all ]` / `import-policy [ all ]`;
`/root/learn-srlinux/docs/tutorials/l3evpn/rt5-only/underlay.md:354-370` —
`prefix-set system-loopbacks prefix 10.0.0.0/8 mask-length-range 32..32` +
`policy system-loopbacks-policy`]. **Recommend the prefix-set form**: an `accept`-all policy on an
eBGP underlay is a lab shortcut that silently leaks tenant prefixes if an `ip-vrf` ever leaks.

`session-state` is an enumeration `idle | connect | active | opensent | openconfirm | established`
[VERIFIED: `$Y/network-instance/srl_nokia-bgp.yang:1517-1541` @ v25.7.1].

### 1.3 Dual-stack, and the IPv6-underlay question — **the hard answer**

**A VXLAN IPv6 underlay (VTEP over IPv6) is NOT supported on SR Linux 25.7.1**, nor on 25.10.3,
nor on 26.7.2.

```yang
container egress {
  leaf source-ip {
    type union {
      type enumeration {
        enum use-system-ipv4-address { value 0; }
      }
      /*
      only loopback v4 supported now
      type srl_nokia-comm:ip-address;
       */
    }
    default "use-system-ipv4-address";
```
[VERIFIED: `$Y/tunnel/srl_nokia-tunnel-interfaces.yang:161-171` @ v25.7.1 — the commented-out
`ip-address` union member and the literal comment *"only loopback v4 supported now"*. The same
IPv4-only enumeration, minus the comment, is present at v24.10.7, v25.10.3 and v26.7.2 —
[VERIFIED: same file at those three tags]. Nokia's guide confirms operationally: the VXLAN egress
source and the default EVPN next-hop are *"the IPv4 address of the default network instance
subinterface system0.0"* [VERIFIED:
`https://documentation.nokia.com/srlinux/25-10/books/vpn-services/evpn-vxlan-tunnels-layer-2.html`].]

Therefore:

- **`system0.0` MUST carry an IPv4 `/32`.** Without it the bgp-evpn instance goes oper-down with
  `oper-down-reason = vxlan_interface_no_source_ip_address`, and the network-instance's
  `vxlan-interface` goes down with
  `oper-down-reason = vxlan-if-default-net-inst-source-address-missing`
  [VERIFIED: `$Y/network-instance/srl_nokia-bgp-evpn.yang:640-658` and
  `$Y/network-instance/srl_nokia-network-instance.yang:566-574` @ v25.7.1].
- **Dual-stack is fine everywhere else**: routed subinterfaces can carry IPv4 and IPv6; BGP can run
  `ipv4-unicast` and `ipv6-unicast`; `ip-vrf` tenants can be dual-stack; IRBs can be dual-stack.
  What cannot be IPv6 is the *tunnel endpoint*.
- `bgp-evpn/.../routes/bridge-table/next-hop` does accept `use-system-ipv6-address`
  (`srl_nokia-comm:next-hop-type` is a union of `use-system-ipv4-address | use-system-ipv6-address
  | ip-address`) [VERIFIED: `$Y/common/srl_nokia-common.yang:1414-1426` @ v25.7.1], **but setting it
  with `encapsulation-type vxlan` produces an unreachable next-hop**, because the egress source
  cannot be IPv6. That leaf is for `mpls` / `srv6` encapsulation. Treat "IPv6 EVPN next-hop" as a
  refusal for this fabric.

**Requirement wording consequence**: the composite must state the VXLAN underlay address family as
**IPv4-only**, and the MTU arithmetic in [data-model.md §20](../../../../root/agentic-netops-srl/specs/004-agentic-netops-composite/data-model.md)
loses its "54 over IPv6" branch for the *underlay* (it keeps it for an IPv6 *tenant* payload inside
an IPv4 VXLAN tunnel, which is a different sum).

### 1.4 Alternative: eBGP IPv6-unnumbered underlay (documented, working, not recommended as default)

SR Linux supports RFC 8950 IPv4-over-IPv6-next-hop with IPv6 link-local peering, discovered via
Router Advertisements:

```
set / interface ethernet-1/49 subinterface 1 ipv6 admin-state enable
set / interface ethernet-1/49 subinterface 1 ipv6 router-advertisement router-role admin-state enable
set / interface ethernet-1/49 subinterface 1 ipv6 router-advertisement router-role max-advertisement-interval 10
set / interface ethernet-1/49 subinterface 1 ipv6 router-advertisement router-role min-advertisement-interval 4
set / network-instance default interface ethernet-1/49.1
set / network-instance default protocols bgp dynamic-neighbors interface ethernet-1/49.1 peer-group underlay
set / network-instance default protocols bgp dynamic-neighbors interface ethernet-1/49.1 allowed-peer-as [ 4200000001..4200000010 ]
set / network-instance default protocols bgp dynamic-neighbors accept match fe80::/10 peer-group underlay
set / network-instance default ip-forwarding receive-ipv4-check false
```
[VERIFIED: `/root/learn-srlinux/docs/tutorials/l3evpn/rt5-only/underlay.md:84-110, 384-409`]

The config leaf is gated `if-feature "srl_nokia-feat:bgp-unnumbered-peers"`
[VERIFIED: `$Y/network-instance/srl_nokia-bgp.yang:3905` and `$Y/common/srl_nokia-features.yang:412`
@ v25.7.1]. Note this is still an **IPv4 VXLAN underlay** — only the *transport* of the BGP session
and the next-hop of the IPv4 loopback prefixes is IPv6; `system0.0` still carries the IPv4 `/32`.

**Consequence if adopted**: KUID stops claiming p2p link addresses (one whole index family drops out
of the critical path), but the reconciliation loses the ability to state the underlay's addressing
from its own records, and SC-008's 30 s budget must absorb the RA discovery interval (4–10 s with
the tuned timers above).

### 1.5 Copy-pastable underlay + overlay exemplar (2-spine / 2-leaf)

Addressing: `leaf01 10.0.0.1/32` AS `4200000001`, `leaf02 10.0.0.2/32` AS `4200000002`,
`spine01 10.0.1.1/32` AS `4200000011`, `spine02 10.0.1.2/32` AS `4200000012`,
fabric overlay AS `65535`, p2p `/31`s from `192.168.0.0/24`.

**leaf01**

```srl
enter candidate
# --- p2p underlay links ------------------------------------------------------
set / interface ethernet-1/49 admin-state enable
set / interface ethernet-1/49 subinterface 0 ipv4 admin-state enable
set / interface ethernet-1/49 subinterface 0 ipv4 address 192.168.0.1/31
set / interface ethernet-1/50 admin-state enable
set / interface ethernet-1/50 subinterface 0 ipv4 admin-state enable
set / interface ethernet-1/50 subinterface 0 ipv4 address 192.168.0.3/31

# --- VTEP loopback -----------------------------------------------------------
set / interface system0 admin-state enable
set / interface system0 subinterface 0 ipv4 admin-state enable
set / interface system0 subinterface 0 ipv4 address 10.0.0.1/32

set / network-instance default interface ethernet-1/49.0
set / network-instance default interface ethernet-1/50.0
set / network-instance default interface system0.0

# --- underlay policy (loopbacks only; eBGP rejects everything by default) -----
set / routing-policy prefix-set system-loopbacks prefix 10.0.0.0/8 mask-length-range 32..32
set / routing-policy policy system-loopbacks-policy statement 1 match prefix prefix-set system-loopbacks
set / routing-policy policy system-loopbacks-policy statement 1 action policy-result accept

# --- underlay eBGP -----------------------------------------------------------
set / network-instance default protocols bgp autonomous-system 4200000001
set / network-instance default protocols bgp router-id 10.0.0.1
set / network-instance default protocols bgp afi-safi ipv4-unicast admin-state enable
set / network-instance default protocols bgp group underlay export-policy [ system-loopbacks-policy ]
set / network-instance default protocols bgp group underlay import-policy [ system-loopbacks-policy ]
set / network-instance default protocols bgp neighbor 192.168.0.0 peer-group underlay
set / network-instance default protocols bgp neighbor 192.168.0.0 peer-as 4200000011
set / network-instance default protocols bgp neighbor 192.168.0.2 peer-group underlay
set / network-instance default protocols bgp neighbor 192.168.0.2 peer-as 4200000012

# --- overlay iBGP EVPN to both spines ---------------------------------------
set / network-instance default protocols bgp afi-safi evpn admin-state enable
set / network-instance default protocols bgp group overlay peer-as 65535
set / network-instance default protocols bgp group overlay local-as as-number 65535
set / network-instance default protocols bgp group overlay afi-safi evpn admin-state enable
set / network-instance default protocols bgp group overlay afi-safi ipv4-unicast admin-state disable
set / network-instance default protocols bgp group overlay timers minimum-advertisement-interval 1
set / network-instance default protocols bgp neighbor 10.0.1.1 peer-group overlay
set / network-instance default protocols bgp neighbor 10.0.1.1 transport local-address 10.0.0.1
set / network-instance default protocols bgp neighbor 10.0.1.2 peer-group overlay
set / network-instance default protocols bgp neighbor 10.0.1.2 transport local-address 10.0.0.1
commit now
```

**spine01** (IP transit + EVPN route reflector; **no** `tunnel-interface`, **no** `mac-vrf`, **no**
`ip-vrf`)

```srl
enter candidate
set / interface ethernet-1/1 admin-state enable
set / interface ethernet-1/1 subinterface 0 ipv4 admin-state enable
set / interface ethernet-1/1 subinterface 0 ipv4 address 192.168.0.0/31
set / interface ethernet-1/2 admin-state enable
set / interface ethernet-1/2 subinterface 0 ipv4 admin-state enable
set / interface ethernet-1/2 subinterface 0 ipv4 address 192.168.0.4/31
set / interface system0 admin-state enable
set / interface system0 subinterface 0 ipv4 admin-state enable
set / interface system0 subinterface 0 ipv4 address 10.0.1.1/32
set / network-instance default interface ethernet-1/1.0
set / network-instance default interface ethernet-1/2.0
set / network-instance default interface system0.0

set / routing-policy prefix-set system-loopbacks prefix 10.0.0.0/8 mask-length-range 32..32
set / routing-policy policy system-loopbacks-policy statement 1 match prefix prefix-set system-loopbacks
set / routing-policy policy system-loopbacks-policy statement 1 action policy-result accept

set / network-instance default protocols bgp autonomous-system 4200000011
set / network-instance default protocols bgp router-id 10.0.1.1
set / network-instance default protocols bgp afi-safi ipv4-unicast admin-state enable
set / network-instance default protocols bgp group underlay export-policy [ system-loopbacks-policy ]
set / network-instance default protocols bgp group underlay import-policy [ system-loopbacks-policy ]
set / network-instance default protocols bgp neighbor 192.168.0.1 peer-group underlay
set / network-instance default protocols bgp neighbor 192.168.0.1 peer-as 4200000001
set / network-instance default protocols bgp neighbor 192.168.0.5 peer-group underlay
set / network-instance default protocols bgp neighbor 192.168.0.5 peer-as 4200000002

# --- EVPN route reflector ----------------------------------------------------
set / network-instance default protocols bgp afi-safi evpn admin-state enable
# MANDATORY on a non-VTEP spine, or every EVPN route is rejected and never reflected:
set / network-instance default protocols bgp afi-safi evpn evpn inter-as-vpn true
set / network-instance default protocols bgp group overlay peer-as 65535
set / network-instance default protocols bgp group overlay local-as as-number 65535
set / network-instance default protocols bgp group overlay afi-safi evpn admin-state enable
set / network-instance default protocols bgp group overlay afi-safi ipv4-unicast admin-state disable
set / network-instance default protocols bgp group overlay route-reflector client true
set / network-instance default protocols bgp dynamic-neighbors accept match 0.0.0.0/0 peer-group overlay
commit now
```

[Structure VERIFIED against `https://learn.srlinux.dev/tutorials/l2evpn/fabric/` and
`.../l2evpn/evpn/`, `/root/learn-srlinux/docs/tutorials/l3evpn/rt5-only/underlay.md` and
`.../overlay.md`, and `/root/learn-srlinux/docs/blog/posts/2024/srlinux-asymmetric-routing.md:596-704`.
The 2-spine fan-out, the `/31` plan and the per-node names are this report's composition, not a
quotation.]

---

## 2. The `mac-vrf` construct

### 2.1 Exact config tree

```
/interface[name=ethernet-1/1]/srl_nokia-interfaces-vlans:vlan-tagging                       = true
/interface[name=ethernet-1/1]/subinterface[index=200]/type                                  = srl_nokia-if:bridged
/interface[name=ethernet-1/1]/subinterface[index=200]/admin-state                           = enable
/interface[name=ethernet-1/1]/subinterface[index=200]/srl_nokia-interfaces-vlans:vlan/encap/single-tagged/vlan-id = 200

/tunnel-interface[name=vxlan0]/vxlan-interface[index=10021]/type                            = srl_nokia-if:bridged
/tunnel-interface[name=vxlan0]/vxlan-interface[index=10021]/ingress/vni                      = 10021
/tunnel-interface[name=vxlan0]/vxlan-interface[index=10021]/egress/source-ip                 = use-system-ipv4-address

/network-instance[name=macvrf-21]/type                                                       = srl_nokia-netinst:mac-vrf
/network-instance[name=macvrf-21]/admin-state                                                = enable
/network-instance[name=macvrf-21]/interface[name=ethernet-1/1.200]
/network-instance[name=macvrf-21]/vxlan-interface[name=vxlan0.10021]
/network-instance[name=macvrf-21]/protocols/bgp-evpn/srl_nokia-bgp-evpn:bgp-instance[id=1]/admin-state      = enable
/network-instance[name=macvrf-21]/protocols/bgp-evpn/srl_nokia-bgp-evpn:bgp-instance[id=1]/encapsulation-type = vxlan
/network-instance[name=macvrf-21]/protocols/bgp-evpn/srl_nokia-bgp-evpn:bgp-instance[id=1]/vxlan-interface  = vxlan0.10021
/network-instance[name=macvrf-21]/protocols/bgp-evpn/srl_nokia-bgp-evpn:bgp-instance[id=1]/evi              = 10021
/network-instance[name=macvrf-21]/protocols/bgp-evpn/srl_nokia-bgp-evpn:bgp-instance[id=1]/ecmp             = 8
/network-instance[name=macvrf-21]/protocols/srl_nokia-bgp-vpn:bgp-vpn/bgp-instance[id=1]/route-distinguisher/rd   (optional)
/network-instance[name=macvrf-21]/protocols/srl_nokia-bgp-vpn:bgp-vpn/bgp-instance[id=1]/route-target/export-rt   (optional)
/network-instance[name=macvrf-21]/protocols/srl_nokia-bgp-vpn:bgp-vpn/bgp-instance[id=1]/route-target/import-rt   (optional)
```
[VERIFIED: all nodes and their placement at v25.7.1 in `$Y/interfaces/srl_nokia-interfaces.yang`,
`$Y/interfaces/srl_nokia-interfaces-vlans.yang`, `$Y/tunnel/srl_nokia-tunnel-interfaces.yang`,
`$Y/network-instance/srl_nokia-network-instance.yang`, `$Y/network-instance/srl_nokia-bgp-evpn.yang`,
`$Y/network-instance/srl_nokia-bgp-vpn.yang`. Structurally matched against Nokia's own example at
`https://documentation.nokia.com/srlinux/25-10/books/vpn-services/evpn-vxlan-tunnels-layer-2.html`
and the learn.srlinux.dev L2 tutorial at `https://learn.srlinux.dev/tutorials/l2evpn/evpn/`]

`bgp-evpn` is a **presence** container with
`must '… type != "srl_nokia-netinst:default"'` — *"The bgp-evpn configuration is not possible on
network-instance of type default."* [VERIFIED: `$Y/network-instance/srl_nokia-network-instance.yang`
`container bgp-evpn` block @ v25.7.1]. The `bgp-evpn/bgp-instance/id` leaf is a **leafref to**
`…/protocols/bgp-vpn/bgp-instance/id`, so **`bgp-vpn/bgp-instance[id=1]` must exist even when RD and
RT are auto-derived** — an empty `bgp-instance` entry is required, not optional
[VERIFIED: `$Y/network-instance/srl_nokia-bgp-evpn.yang:646-650` @ v25.7.1; Nokia's own `ip-vrf`
example shows exactly `bgp-vpn { bgp-instance 1 { } }` with no children].

### 2.2 Route-distinguisher and route-target: auto-derived vs explicit

Both `rd`, `export-rt` and `import-rt` are **optional**. When omitted:

> *"the RD is auto-derived as `<ip-address>:<evi>` where 'ip-address' is the ipv4 address associated
> to the subinterface lo0.1."* — and for RT: *"the RT is auto-derived with the format
> `<asn>:<evi>` where 'asn' is the autonomous-system configured in the network-instance default."*
[VERIFIED: `$Y/network-instance/srl_nokia-bgp-vpn.yang:168-171, 209-213, 238-242` @ v25.7.1]

**The YANG description says `lo0.1`; the Release 25.10 EVPN guide says `system0.0`**
[VERIFIED: `https://documentation.nokia.com/srlinux/25-10/books/vpn-services/evpn-vxlan-tunnels-layer-2.html`
— *"The route-distinguisher is derived as `<ip-address:evi>`, where the `ip-address` is the IPv4
address of the default network instance subinterface system0.0."*]. The `lo0.1` text is stale YANG
prose carried since early releases. **Treat `system0.0` as authoritative** and record the
discrepancy — a reader who trusts the YANG description will provision the wrong loopback. This is
also consistent with `oper-down-reason = no-loopback-address-or-rd` on the bgp-vpn instance
[VERIFIED: `$Y/network-instance/srl_nokia-bgp-vpn.yang:239-248` @ v25.7.1].

**Auto-derived RT is unusable with a per-leaf underlay ASN** — see §1.1's AS-plan trap. Under the
recommended option (a), **render `export-rt` and `import-rt` explicitly** as
`target:<fabricASN>:<evi>` and leave `rd` auto-derived. Real proof that the two behave
independently, from a live device:

```
A:leaf1# show network-instance vrf-1 protocols bgp-vpn bgp-instance 1
        route-distinguisher: 10.0.0.1:111, auto-derived-from-evi
        export-route-target: target:100:111, manual
        import-route-target: target:100:111, manual
```
[VERIFIED: `/root/learn-srlinux/docs/tutorials/l2evpn/evpn.md:344-352`]

The device *reports its own derivation* in three state leaves, which is the read-back gold:

| State leaf | Enum |
|---|---|
| `…/bgp-vpn/bgp-instance[id=1]/route-distinguisher/route-distinguisher-origin` | `auto-derived-from-evi`, `auto-derived-from-system-ip:0`, `manual`, `none` |
| `…/bgp-vpn/bgp-instance[id=1]/route-target/export-route-target-origin` | `auto-derived-from-evi`, `auto-derived-from-esi-bytes-1-6`, `from-export-policy`, `manual`, `none` |
| `…/bgp-vpn/bgp-instance[id=1]/route-target/import-route-target-origin` | same as export |
[VERIFIED: `$Y/network-instance/srl_nokia-bgp-vpn.yang:156-235` @ v25.7.1]

### 2.3 Value ranges — the authoritative table

| Value | Path | Range / pattern | Source @ v25.7.1 |
|---|---|---|---|
| **EVI** | `…/bgp-evpn/bgp-instance[id]/evi` | `uint32 { range "1..65535" }`, **`mandatory true`** | `typedef evi` `$Y/common/srl_nokia-common.yang:2055-2061`; `mandatory` at `$Y/…/srl_nokia-bgp-evpn.yang:618` |
| **VNI** | `/tunnel-interface[name]/vxlan-interface[index]/ingress/vni` | `uint32 { range "1..16777215" }`, **`mandatory true`** | `$Y/tunnel/srl_nokia-tunnel-interfaces.yang:148-153` |
| **vxlan-interface index** | `/tunnel-interface[name]/vxlan-interface[index]` | `uint32 { range "0..99999999" }`, `max-elements 16384` per tunnel-interface — **note the L2 tutorial's prose says "0-4294967295", which is wrong; trust the YANG** | `$Y/tunnel/srl_nokia-tunnel-interfaces.yang:93, 98-104` @ v25.7.1; contradicting prose at `/root/learn-srlinux/docs/tutorials/l2evpn/evpn.md:167-179` |
| **tunnel-interface name** | `/tunnel-interface[name]` | `vxlan<N>`, `N = 0..255` | `$Y/tunnel/srl_nokia-tunnel-interfaces.yang` `leaf name` description |
| **vxlan-interface reference** | `/network-instance[name]/vxlan-interface[name]` | `length "8..17"`, pattern `(vxlan(0\|1[0-9][0-9]\|2([0-4][0-9]\|5[0-5])\|[1-9][0-9]\|[1-9])\.(0\|[1-9](\d){0,8}))`, **`max-elements 1`** | `typedef network-instance-vxlan-if-ref` `$Y/…/srl_nokia-network-instance.yang:76-83`; `max-elements 1` at line ~558 |
| **network-instance name** | `/network-instance[name]` | `restricted-name`: `length "1..247"`, pattern `` [A-Za-z0-9!@#$%^&()|+=`~.,_:;?-][A-Za-z0-9 !@#$%^&()|+=`~.,_:;?-]* `` — **no `/`, no `*`, no quotes, no leading space** | `$Y/common/srl_nokia-common.yang:1189-1196` |
| **subinterface index** | `/interface[name]/subinterface[index]` | `uint32 { range "0..9999" }`, `max-elements 4095` | `$Y/interfaces/srl_nokia-interfaces.yang:1003-1011` |
| **subinterface reference** | `/network-instance[name]/interface[name]` | `<interface-name>.<index>`, `length 1..255`; canonical form constrained by `subinterface-all`: index `(0\|[1-9]\d{0,3})` | `$Y/…/srl_nokia-network-instance.yang:70-75`; `$Y/common/srl_nokia-common.yang:758-771` |
| **vlan-id** | `…/vlan/encap/single-tagged/vlan-id` | `uint16 { range "1..4094" }`, or enums `optional` / `any` (bridged only, feature-gated) | `$Y/interfaces/srl_nokia-interfaces-vlans.yang:80-86, 170-200` |
| **ecmp** | `…/bgp-evpn/bgp-instance[id]/ecmp` | `uint32 { range "1..128" }`, default `1`, **but `must` caps it at 8 unless the network-instance is `ip-vrf`** | `$Y/…/srl_nokia-bgp-evpn.yang:625-637` |
| **bgp-vpn bgp-instance id** | `…/bgp-vpn/bgp-instance[id]` | `uint8 { range "1..2" }`, `max-elements 2` ("only one instance allowed in the current release") | `$Y/…/srl_nokia-bgp-vpn.yang:153-163` |
| **RD** | `…/route-distinguisher/rd` | union of type-0 `<2byte-asn>:<4byte>`, type-1 `<ipv4>:<2byte>`, type-2 `<4byte-asn>:<2byte>`, type-2b `<asn.asn>:<2byte>`; `must` rejects `0:*`, `0.0:*`, and `0.0.0.0:<513` | `$Y/common/srl_nokia-common.yang:1361-1412`; `must`s at `$Y/…/srl_nokia-bgp-vpn.yang:172-183` |
| **RT** | `…/route-target/export-rt`, `import-rt` | `bgp-ext-community-type` with `must "starts-with(.,'target')"` — i.e. literally `target:A:B` | `$Y/routing-policy/srl_nokia-policy-types.yang:324+`; `must` at `$Y/…/srl_nokia-bgp-vpn.yang:209, 238` |
| **mac-limit** | `/network-instance[name]/bridge-table/mac-limit/maximum-entries` | `int32 { range "1..250000" }`, **default `250`** | `$Y/…/srl_nokia-bridge-table-mac-limit.yang:27-34` |

### 2.4 Copy-pastable exemplar — `mac-vrf` on `leaf01` (SR Linux CLI flat `set /`)

Golden-file parameters: serviceId `21`, tenant `blue`, VLAN `200`, L2VNI `10021`,
fabric overlay AS `65535`, `system0.0 = 10.0.0.1/32`.

```srl
# --- attachment point -------------------------------------------------------
set / interface ethernet-1/1 admin-state enable
set / interface ethernet-1/1 vlan-tagging true
set / interface ethernet-1/1 subinterface 200 type bridged
set / interface ethernet-1/1 subinterface 200 admin-state enable
set / interface ethernet-1/1 subinterface 200 vlan encap single-tagged vlan-id 200

# --- VXLAN interface (L2VNI) ------------------------------------------------
set / tunnel-interface vxlan0 vxlan-interface 10021 type bridged
set / tunnel-interface vxlan0 vxlan-interface 10021 ingress vni 10021
set / tunnel-interface vxlan0 vxlan-interface 10021 egress source-ip use-system-ipv4-address

# --- the bridge domain ------------------------------------------------------
set / network-instance macvrf-21 type mac-vrf
set / network-instance macvrf-21 admin-state enable
set / network-instance macvrf-21 description "Service 21 (mac-vrf)"
set / network-instance macvrf-21 interface ethernet-1/1.200
set / network-instance macvrf-21 vxlan-interface vxlan0.10021

# --- EVPN control plane -----------------------------------------------------
set / network-instance macvrf-21 protocols bgp-evpn bgp-instance 1 admin-state enable
set / network-instance macvrf-21 protocols bgp-evpn bgp-instance 1 encapsulation-type vxlan
set / network-instance macvrf-21 protocols bgp-evpn bgp-instance 1 vxlan-interface vxlan0.10021
set / network-instance macvrf-21 protocols bgp-evpn bgp-instance 1 evi 10021
set / network-instance macvrf-21 protocols bgp-evpn bgp-instance 1 ecmp 8
set / network-instance macvrf-21 protocols bgp-vpn bgp-instance 1
# RD is left auto-derived -> 10.0.0.1:10021 (system0.0 IPv4 : evi). Do NOT leave the RT
# auto-derived: it would become target:<this leaf's underlay ASN>:10021 and differ per leaf (see
# section 1.1). Render it from the fabric ASN instead:
set / network-instance macvrf-21 protocols bgp-vpn bgp-instance 1 route-target export-rt target:65535:10021
set / network-instance macvrf-21 protocols bgp-vpn bgp-instance 1 route-target import-rt target:65535:10021
commit now
```

### 2.5 The same thing as a gNMI `Set` with `JSON_IETF` (this is the golden-file form)

`gnmic -a clab-agentic-leaf01:57400 -u admin -p NokiaSrl1! --skip-verify -e json_ietf \
  set --update-path / --update-file macvrf-21.leaf01.json`

```json
{
  "srl_nokia-interfaces:interface": [
    {
      "name": "ethernet-1/1",
      "admin-state": "enable",
      "srl_nokia-interfaces-vlans:vlan-tagging": true,
      "subinterface": [
        {
          "index": 200,
          "type": "srl_nokia-interfaces:bridged",
          "admin-state": "enable",
          "srl_nokia-interfaces-vlans:vlan": {
            "encap": { "single-tagged": { "vlan-id": 200 } }
          }
        }
      ]
    }
  ],
  "srl_nokia-tunnel-interfaces:tunnel-interface": [
    {
      "name": "vxlan0",
      "vxlan-interface": [
        {
          "index": 10021,
          "type": "srl_nokia-interfaces:bridged",
          "ingress": { "vni": 10021 },
          "egress": { "source-ip": "use-system-ipv4-address" }
        }
      ]
    }
  ],
  "srl_nokia-network-instance:network-instance": [
    {
      "name": "macvrf-21",
      "type": "srl_nokia-network-instance:mac-vrf",
      "admin-state": "enable",
      "description": "Service 21 (mac-vrf)",
      "interface": [ { "name": "ethernet-1/1.200" } ],
      "vxlan-interface": [ { "name": "vxlan0.10021" } ],
      "protocols": {
        "bgp-evpn": {
          "srl_nokia-bgp-evpn:bgp-instance": [
            {
              "id": 1,
              "admin-state": "enable",
              "encapsulation-type": "vxlan",
              "vxlan-interface": "vxlan0.10021",
              "evi": 10021,
              "ecmp": 8
            }
          ]
        },
        "srl_nokia-bgp-vpn:bgp-vpn": {
          "bgp-instance": [
            {
              "id": 1,
              "route-target": {
                "export-rt": "target:65535:10021",
                "import-rt": "target:65535:10021"
              }
            }
          ]
        }
      }
    }
  ]
}
```

Notes on this payload:

- The module-qualification of every key follows the augment/uses analysis in §0
  [VERIFIED: augment statements at v25.7.1].
- Identityref values are written RFC 7951-style as `<module-name>:<identity>`
  (`srl_nokia-network-instance:mac-vrf`, `srl_nokia-interfaces:bridged`).
  **[UNVERIFIED: from memory]** that SR Linux *also* accepts the bare `"mac-vrf"` / `"bridged"`
  form and that it *emits* the qualified form on a `Get`. **Action for the first lab bring-up:
  `gnmic get --path /network-instance[name=macvrf-21]/type -e json_ietf` and freeze whichever form
  the device emits into the golden file** — the golden must match what read-back returns, or SC-006
  ("zero gNMI mutations on the second reconciliation") will fail on a serialization difference.
- `Update` is a merge on SR Linux; `Replace` on a per-service subtree
  (`/network-instance[name=macvrf-21]`) is the idempotent form and the one that makes
  label-selector rollback (FR-067) meaningful. Recommend Replace per owned subtree, Update never.

---

## 3. The `vlan` construct, and **Open decision 5**

### 3.1 What `vlan` is on SR Linux

**There is no VLAN table on SR Linux.** A VLAN is not an object; it is an *encapsulation match* on
a subinterface (`…/vlan/encap/single-tagged/vlan-id`) and a *bridge domain* is a
`network-instance type mac-vrf`. There is no `VLAN|Vlan<id>` row and no `VLAN_MEMBER` equivalent —
PC-11's whole vocabulary evaporates.

So yes: **a `vlan` is a `mac-vrf` network-instance with no `vxlan-interface`, no `bgp-evpn` and no
`bgp-vpn`.** Nothing else changes: same type identity, same bridge-table, same bridged
subinterfaces. Because `vxlan-interface` and `protocols/bgp-evpn` are both *optional* on a
`mac-vrf` (`bgp-evpn` is a presence container; `vxlan-interface` is a list with `max-elements 1` and
no `min-elements`), a bare local bridge domain is a first-class, fully-supported configuration
[VERIFIED: `$Y/network-instance/srl_nokia-network-instance.yang` @ v25.7.1].

```srl
set / interface ethernet-1/1 admin-state enable
set / interface ethernet-1/1 vlan-tagging true
set / interface ethernet-1/1 subinterface 100 type bridged
set / interface ethernet-1/1 subinterface 100 admin-state enable
set / interface ethernet-1/1 subinterface 100 vlan encap single-tagged vlan-id 100
set / network-instance vlan-21 type mac-vrf
set / network-instance vlan-21 admin-state enable
set / network-instance vlan-21 description "Service 21 (vlan)"
set / network-instance vlan-21 interface ethernet-1/1.100
commit now
```

That is the *entire* render. No VNI, no EVI, no RD, no RT — FR-029 satisfied literally.

### 3.2 Recommendation on Open decision 5

**Decision 5a — does `vlan` remain its own construct? YES. Keep it.**

Reasons, in order of weight:

1. **D-11's defect returns if it is dropped.** network-spec.md §2 already records *why* a local VLAN
   is its own `spec.vlans[]` list and not "a bridge domain with a zero L2VNI": *"encoding 'this is a
   different service' as 'this field is missing' is the exact defect that once made an integrated
   L2/L3 service silently render as a bridged one."* On SR Linux the two constructs now render to
   **the same YANG list with the same type identity**, differing only by which optional children are
   absent. That makes the defect *more* likely, not less: the difference between "operator asked for
   a local bridge domain" and "operator asked for a fabric-wide one whose overlay half failed to
   render" becomes invisible in the device config. The intent-side distinction is the only place the
   difference survives. **Keep `spec.vlans[]` and `spec.bridgeDomains[]` separate, and keep the
   construct separate.**
2. **The claim profile differs materially.** A `vlan` claims a VLAN ID and nothing else; a `mac-vrf`
   claims a VLAN *and* an L2VNI *and* (see §8) an EVI. "Claiming nothing is a success" (PC-N-06)
   only stays checkable if the construct declares its profile up front.
3. **The refusal table in construct-vocabulary.md §3 stays coherent**: `vlan` + `l2vni` → "ask for a
   mac-vrf to extend it over the fabric" is a real, useful refusal, and it has a real device
   meaning: you would be adding a `vxlan-interface` and a `bgp-evpn` instance.

**But FR-029's wording must change.** It currently says *"`vlan` MUST provision a local broadcast
domain — a VLAN and its port membership"*. On SR Linux there is no VLAN object and no port
membership. Proposed replacement:

> **FR-029 (retargeted)**: `vlan` MUST provision a **local bridge domain** — a bridge-domain
> instance plus the tagged or untagged subinterfaces attached to it — and MUST NOT allocate a VNI,
> an EVPN instance identifier, or route targets.

and the corresponding row in [data-model.md §6] changes "Renders" from
*"A VLAN row plus bridge membership"* to
*"A bridge-domain network-instance with bridged subinterfaces; no tunnel interface, no EVPN
control plane"*.

**Decision 5b — is the vocabulary alignment a requirement or an implementation convenience?
Make it a REQUIREMENT.**

Proposed addition to FR-024:

> Two of the four construct names — `mac-vrf` and `ip-vrf` — MUST be the network operating system's
> own model identities rather than a platform translation, and CI MUST assert that the pinned device
> YANG declares `identity mac-vrf` and `identity ip-vrf` under the network-instance type base. If a
> future retarget moves to a platform that does not name them so, the divergence MUST be recorded in
> the platform-coupling inventory rather than absorbed silently.

Why a requirement rather than a convenience:

- It is **cheap and machine-checkable**: a CI step greps the pinned `srlinux-yang-models` tag for
  `identity mac-vrf {` and `identity ip-vrf {`. That is the same shape of assertion the path
  register already uses (PC-N-12).
- **SC-013 becomes measurable for the first time.** SC-013 asks that a newcomer who read only the
  cited device references can provision each construct *"without consulting a translation table."*
  For `mac-vrf` and `ip-vrf` that is now literally true: the operator types the identity name the
  device's own YANG declares. For `vlan` and `acl` it remains a platform word, and the spec should
  say so rather than claim four-for-four.
- It **converts PC-N-03's note into a settled fact.** PC-N-03 already anticipated this
  (*"on a platform whose own model uses these names, the vocabulary stops being a translation
  layer. That changes its *status*, not its content"*). Making it a requirement is the smallest
  change that discharges that note.

**Alternative considered and rejected**: leave it an implementation convenience. Rejected because
the *next* retarget then has no record that two of the four names were chosen to match a device
model, and would be free to "improve" them — losing the property for free.

---

## 4. The `ip-vrf` construct

### 4.1 Model choice: interface-less symmetric IRB (EVPN-IFL, RT5-only) — **recommended**

SR Linux offers three L3 EVPN models [VERIFIED:
`https://documentation.nokia.com/srlinux/25-10/books/vpn-services/evpn-vxlan-tunnels-layer-3.html`]:

| Model | Shape | Config marker |
|---|---|---|
| **IFL (interface-less)** | EVPN tunnels terminate directly on the `ip-vrf`; only RT5 IP-prefix routes | `ip-vrf` + `vxlan-interface type routed` + `bgp-evpn` |
| **IFF (interface-ful)** | tunnels terminate on a *supplementary broadcast domain* — a `mac-vrf` with no bridged subinterfaces | `bgp-evpn/bgp-instance/supplementary-broadcast-domain` + `routes/route-table/ip-prefix/advertise-interface-ful` |
| **IFL-host** | RT2 MAC/IP routes carrying an L3 label and the ip-vrf's RT | `…/arp/evpn/advertise[route-type]/interface-less-routing` |

**Recommend IFL.** It is the model both Nokia examples and the learn.srlinux.dev `l3evpn/rt5-only`
tutorial use; it needs no supplementary broadcast domain; and it is the one that matches FR-031's
"a VRF with an L3VNI and route targets, advertising the prefixes the operator declared".

The YANG proves IFF is gated and narrow: `advertise-interface-ful` is `if-feature
"srl_nokia-feat:evpn-iff"` and carries two `must`s — it *"can only be enabled on network-instances
of type mac-vrf"* and *"only … on a mac-vrf configured as supplementary-broadcast-domain"*
[VERIFIED: `$Y/network-instance/srl_nokia-bgp-evpn.yang:353-374` @ v25.7.1]. Nokia states plainly:
*"IFL and numbered IFF models are not interoperable (different IP prefix route formats)"*
[VERIFIED: same 25-10 L3 page]. **Recommend: IFL fabric-wide; refuse any request that would mix.**

### 4.2 How declared prefixes get advertised — **no redistribution, no policy**

> *"In the EVPN IFL model, all interface and local routes (static, ARP-ND, BGP, and so on) are
> automatically advertised in RT5s without the need for any export policy."*
[VERIFIED: `https://documentation.nokia.com/srlinux/25-10/books/vpn-services/evpn-vxlan-tunnels-layer-3.html`]

So an `ip-vrf`'s RT5 origination set is *exactly* its `route-table`. There is nothing to
redistribute, nothing to `advertise` toggle on, and no `network` statement.

**This changes what FR-031 has to check.** "Advertising the prefixes the operator declared" becomes:
*every declared prefix must be present in that ip-vrf's route-table on the attaching node*. A prefix
that corresponds to nothing is simply never advertised, silently. Recommended rendering rules:

1. A declared prefix that matches a routed subinterface's address → it appears as a `local` route,
   advertised automatically. This is the normal case.
2. A declared prefix with no attachment carrying it → render an explicit
   `/network-instance[name]/srl_nokia-aggregate-routes:aggregate-routes/route[prefix=…]` or
   `/network-instance[name]/srl_nokia-static-routes:static-routes/route[prefix=…]`
   [VERIFIED: `$Y/network-instance/srl_nokia-aggregate-routes.yang:37-48, 103` and
   `$Y/network-instance/srl_nokia-static-routes.yang:42-80, 118` @ v25.7.1 — both `augment
   "/srl_nokia-netinst:network-instance"`].
3. A declared prefix that is neither → **refuse at validation**, naming the prefix and that the
   fabric advertises what is in the routed instance's route table. Do **not** apply and hope.

### 4.3 PC-15 is deleted, and what replaces it

PC-15 carried *"the derived routed-instance VLAN band 4001–4094, the L3VNI renderable sub-band
10000–14094, and the derivation from VNI to routed VLAN"*, and the coupling file already flagged it
as *"a consequence of how this render path creates a routed instance, not of EVPN"*.

**Confirmed: SR Linux needs no VLAN-per-VRF derivation at all.** There is no routed VLAN, no SVI
inside a VLAN, and no VLAN object. The L3VNI is bound to the `ip-vrf` directly by a
`vxlan-interface type routed` whose `ingress/vni` is the L3VNI
[VERIFIED: `$Y/tunnel/srl_nokia-tunnel-interfaces.yang` `leaf type` `must ".='srl_nokia-if:bridged'
or .='srl_nokia-if:routed'"` @ v25.7.1; and Nokia's worked example `vxlan-interface 3 { type routed;
ingress { vni 3 } }` at the 25-7 L3 page]. **Delete the 4001–4094 band and the 10000–14094
sub-band.** Delete the "reserved derived-VLAN band" row from construct-vocabulary.md §4.

**What replaces the constraint** — three new, *real* platform constraints:

| New constraint | Value | Source |
|---|---|---|
| **EVI is mandatory and is `1..65535`** | Every `bgp-evpn/bgp-instance` on *both* a `mac-vrf` and an `ip-vrf` requires an `evi`, and the range is 16-bit | `$Y/common/srl_nokia-common.yang:2055-2061`; `mandatory true` at `$Y/…/srl_nokia-bgp-evpn.yang:618` |
| **One `vxlan-interface` per network-instance** | `max-elements 1` | `$Y/…/srl_nokia-network-instance.yang` `list vxlan-interface` |
| **L2VNI and L3VNI are distinct VNIs and need distinct `vxlan-interface` indices** | index `0..99999999`, 16384 per `vxlan<N>` | `$Y/tunnel/srl_nokia-tunnel-interfaces.yang:93, 98-104` |

The **EVI ceiling of 65535 is the new binding constraint** and it is *tighter* than anything SONiC
imposed. KUID's VNI index band is 10000–20000 [VERIFIED:
`/root/agentic-netops-srl/specs/004-agentic-netops-composite/contracts/kuid-claim-profiles.md` §1],
which fits entirely inside `1..65535` — see §8 for how to exploit that.

### 4.4 Copy-pastable exemplar — `ip-vrf` on `leaf01`

Parameters: serviceId `21`, L3VNI `10022`, routed attachment `ethernet-1/2` VLAN `300`,
prefix `10.20.0.0/24`.

```srl
# --- routed attachment ------------------------------------------------------
set / interface ethernet-1/2 admin-state enable
set / interface ethernet-1/2 vlan-tagging true
set / interface ethernet-1/2 subinterface 300 type routed
set / interface ethernet-1/2 subinterface 300 admin-state enable
set / interface ethernet-1/2 subinterface 300 vlan encap single-tagged vlan-id 300
set / interface ethernet-1/2 subinterface 300 ipv4 admin-state enable
set / interface ethernet-1/2 subinterface 300 ipv4 address 10.20.0.1/24

# --- VXLAN interface (L3VNI) ------------------------------------------------
set / tunnel-interface vxlan0 vxlan-interface 10022 type routed
set / tunnel-interface vxlan0 vxlan-interface 10022 ingress vni 10022

# --- the routed instance ----------------------------------------------------
set / network-instance ipvrf-21 type ip-vrf
set / network-instance ipvrf-21 admin-state enable
set / network-instance ipvrf-21 description "Service 21 (ip-vrf)"
set / network-instance ipvrf-21 interface ethernet-1/2.300
set / network-instance ipvrf-21 vxlan-interface vxlan0.10022

# --- EVPN IFL control plane -------------------------------------------------
set / network-instance ipvrf-21 protocols bgp-evpn bgp-instance 1 admin-state enable
set / network-instance ipvrf-21 protocols bgp-evpn bgp-instance 1 encapsulation-type vxlan
set / network-instance ipvrf-21 protocols bgp-evpn bgp-instance 1 vxlan-interface vxlan0.10022
set / network-instance ipvrf-21 protocols bgp-evpn bgp-instance 1 evi 10022
set / network-instance ipvrf-21 protocols bgp-evpn bgp-instance 1 ecmp 8
set / network-instance ipvrf-21 protocols bgp-vpn bgp-instance 1
set / network-instance ipvrf-21 protocols bgp-vpn bgp-instance 1 route-target export-rt target:65535:10022
set / network-instance ipvrf-21 protocols bgp-vpn bgp-instance 1 route-target import-rt target:65535:10022
# Optional, only for interop with third-party EVPN-IFF-unnumbered peers — NOT for a homogeneous
# SR Linux fabric, where it just adds a MAC/IP route nobody consumes:
#   set / network-instance ipvrf-21 protocols bgp-evpn bgp-instance 1 routes route-table mac-ip advertise-gateway-mac true
commit now
```

`advertise-gateway-mac` is `default "false"` and its own description limits it to
*"interoperate with a remote system working in EVPN IFF (Interface-ful) Unnumbered mode"*
[VERIFIED: `$Y/network-instance/srl_nokia-bgp-evpn.yang:285-296` @ v25.7.1; Nokia's 25-10 L3 page
confirms it *"supports third-party EVPN IFF unnumbered implementations for VXLAN only"*].
**Recommend leaving it at its default in this fabric and refusing to expose it as a construct
variable.**

---

## 5. Anycast gateway on a `mac-vrf` (symmetric IRB)

### 5.1 Shape

Symmetric IRB on SR Linux = one `irb0.<N>` subinterface attached to **both** the `mac-vrf` and the
`ip-vrf`.

> **"Yes, the same `irb0.1` subinterface appears in BOTH the mac-vrf and ip-vrf network instances."**
[VERIFIED: `https://documentation.nokia.com/srlinux/25-7/books/vpn-services/evpn-vxlan-tunnels-layer-3.html`]

The YANG proves it independently: the per-interface `oper-down-reason` enumeration inside a
network-instance includes `mac-vrf-association-missing`, `ip-vrf-association-missing`,
`associated-mac-vrf-down` and `associated-ip-vrf-down`
[VERIFIED: `$Y/network-instance/srl_nokia-network-instance.yang:463-480` @ v25.7.1]. Those reasons
only make sense for a subinterface that is required to have both associations.

### 5.2 Exact paths

```
/interface[name=irb0]/subinterface[index=200]/anycast-gw                                  (presence container)
/interface[name=irb0]/subinterface[index=200]/anycast-gw/virtual-router-id                 uint8 1..255, default 1
/interface[name=irb0]/subinterface[index=200]/anycast-gw/anycast-gw-mac                    mac-address (optional)
/interface[name=irb0]/subinterface[index=200]/anycast-gw/anycast-gw-mac-origin             (state)
/interface[name=irb0]/subinterface[index=200]/ipv4/address[ip-prefix=10.10.0.1/24]/anycast-gw   boolean
/interface[name=irb0]/subinterface[index=200]/ipv4/address[ip-prefix=10.10.0.1/24]/primary      empty
/interface[name=irb0]/subinterface[index=200]/ipv6/address[ip-prefix=2001:db8:10::1/64]/anycast-gw
/interface[name=irb0]/subinterface[index=200]/ipv6/address[ip-prefix=2001:db8:10::1/64]/primary
/interface[name=irb0]/subinterface[index=200]/ipv4/srl_nokia-interfaces-nbr:arp/learn-unsolicited                 boolean, default false
/interface[name=irb0]/subinterface[index=200]/ipv4/srl_nokia-interfaces-nbr:arp/host-route/populate[route-type=dynamic|static|evpn]
/interface[name=irb0]/subinterface[index=200]/ipv4/srl_nokia-interfaces-nbr:arp/srl_nokia-interfaces-nbr-evpn:evpn/advertise[route-type=dynamic|static]
/interface[name=irb0]/subinterface[index=200]/ipv6/srl_nokia-interfaces-nbr:neighbor-discovery/learn-unsolicited  enum none|global|link-local|both, default none
/interface[name=irb0]/subinterface[index=200]/ipv6/srl_nokia-interfaces-nbr:neighbor-discovery/host-route/populate[route-type=…]
/interface[name=irb0]/subinterface[index=200]/ipv6/srl_nokia-interfaces-nbr:neighbor-discovery/srl_nokia-interfaces-nbr-evpn:evpn/advertise[route-type=…]
/network-instance[name=macvrf-21]/interface[name=irb0.200]
/network-instance[name=ipvrf-21]/interface[name=irb0.200]
/network-instance[name=macvrf-21]/bridge-table/protect-anycast-gw-mac                      boolean, default false
```
[VERIFIED @ v25.7.1: `anycast-gw-top` grouping `$Y/interfaces/srl_nokia-if-ip.yang:411-448` —
`must "starts-with(../../name,'irb')"` / *"Only supported on IRB subinterfaces"*, `virtual-router-id`
`uint8 { range "1..255" }` default `1`, MAC auto-derived `00:00:5E:00:01:VRID`;
per-address `anycast-gw` leaves for IPv4 at `srl_nokia-if-ip.yang:200-218` and for IPv6 at
`:379-399`; `primary` is `type empty` at `:225` / `:406`;
`learn-unsolicited` (v4 boolean / v6 enum) at `$Y/interfaces/srl_nokia-interfaces-nbr.yang:243, 362-379`;
`host-route/populate` keyed by `route-type { static | dynamic | evpn }` at `:147-184`;
`evpn/advertise` keyed by `route-type { static | dynamic }` at
`$Y/interfaces/srl_nokia-interfaces-nbr-evpn.yang:100-124`;
`protect-anycast-gw-mac` at `$Y/network-instance/srl_nokia-bridge-table.yang:68-73`]

Two `must` constraints that will reject a naive render:

- `anycast-gw true` on an address requires the **`anycast-gw` presence container** to exist on the
  same subinterface: `must ". = false() or (. = true() and ../../../anycast-gw) or
  not(starts-with(../../../../name,'irb'))"` → *"Only supported if anycast-gw container is
  configured"*.
- An IPv6 anycast-gw address may not be link-local:
  `must "not(starts-with(../ip-prefix,'fe80'))"` → *"not supported on link local address"*.
[VERIFIED: `$Y/interfaces/srl_nokia-if-ip.yang:206-208, 384-389` @ v25.7.1]

**Why the three ARP/ND knobs are non-optional, not tuning.** With the same anycast IP and MAC on
every leaf, an ARP *reply* travelling back across the fabric is consumed by whichever leaf's IRB
sees it first, so the originating leaf's ARP process never completes:

> *"Since this IRB interface exists on leaf4 as well, the ARP reply will be consumed by it, never
> reaching leaf1, and thus, creating a failure in the ARP process. To circumvent this problem
> associated with an anycast, distributed IRB model, the EVPN Type-2 MAC+IP routes are used to
> populate the ARP cache."*
[VERIFIED: `/root/learn-srlinux/docs/blog/posts/2024/srlinux-asymmetric-routing.md:1657`]

So `learn-unsolicited` + `host-route populate dynamic` + `evpn advertise dynamic` are what make a
distributed gateway work at all. **Render all three unconditionally whenever an anycast gateway is
declared.** `proxy-arp` is an additional, optional knob (`…/ipv4/arp/proxy-arp`) shown on one
subinterface of the reference design and omitted on another
[VERIFIED: same file, `:1113-1166`] — recommend leaving it off and not exposing it as a construct
variable.

**`anycast-gw-mac` explicit vs derived.** The reference design pins it
(`anycast-gw { anycast-gw-mac 00:00:5E:00:53:00 }`, identical on all four leaves)
[VERIFIED: same file, `:1113-1298`]; the YANG derives it from `virtual-router-id` as
`00:00:5E:00:01:VRID` when omitted [VERIFIED: `$Y/interfaces/srl_nokia-if-ip.yang:439-456`
@ v25.7.1]. **Recommend deriving from `virtual-router-id 1`** — one fewer value to render, one
fewer value to keep identical across leaves, and `anycast-gw-mac-origin` reports which path was
taken. Note the derived MAC `00:00:5E:00:01:01` is what shows in the bridge table with
`type = irb-interface-anycast`
[VERIFIED: `/root/learn-srlinux/docs/cli/show-commands/evpn.md:110-127` shows
`00:00:5E:00:01:01 | irb | 0 | irb-interface-anycast` alongside the per-leaf
`irb-interface` MAC].

**Alternative model not recommended: asymmetric IRB.** SR Linux also supports putting `irb0.N` in
the `mac-vrf` and doing the L3 lookup in `network-instance default` with **no `ip-vrf`, no L3VNI and
`type bridged` vxlan-interfaces only** [VERIFIED: same file, `:1030-1047, 1337-1397`]. Reject it for
this composite: FR-032 says the `mac-vrf`+gateway composition "MUST be the only way symmetric IRB is
expressed", and the asymmetric model's documented cost is that *"VLANs/VNIs cannot be scoped to
specific leafs only — they must exist across all leafs that want to participate in inter-VNI
routing"* [VERIFIED: same file, `:115-120`], which is the opposite of what a per-service fabric
wants.

### 5.3 Copy-pastable exemplar — `mac-vrf` + anycast gateway on `leaf01`

Adds to the `mac-vrf` block in §2.4. IPv4 gateway `10.10.0.1/24`, IPv6 gateway `2001:db8:10::1/64`,
L3VNI `10022` in `ipvrf-21`.

```srl
# --- the IRB ----------------------------------------------------------------
set / interface irb0 admin-state enable
set / interface irb0 subinterface 200 admin-state enable
set / interface irb0 subinterface 200 anycast-gw virtual-router-id 1
set / interface irb0 subinterface 200 ipv4 admin-state enable
set / interface irb0 subinterface 200 ipv4 address 10.10.0.1/24 anycast-gw true
set / interface irb0 subinterface 200 ipv4 address 10.10.0.1/24 primary
set / interface irb0 subinterface 200 ipv4 arp learn-unsolicited true
set / interface irb0 subinterface 200 ipv4 arp host-route populate dynamic
set / interface irb0 subinterface 200 ipv4 arp evpn advertise dynamic
set / interface irb0 subinterface 200 ipv6 admin-state enable
set / interface irb0 subinterface 200 ipv6 address 2001:db8:10::1/64 anycast-gw true
set / interface irb0 subinterface 200 ipv6 address 2001:db8:10::1/64 primary
set / interface irb0 subinterface 200 ipv6 neighbor-discovery learn-unsolicited global
set / interface irb0 subinterface 200 ipv6 neighbor-discovery host-route populate dynamic
set / interface irb0 subinterface 200 ipv6 neighbor-discovery evpn advertise dynamic

# --- attach it to BOTH halves ----------------------------------------------
set / network-instance macvrf-21 interface irb0.200
set / network-instance macvrf-21 bridge-table protect-anycast-gw-mac true
set / network-instance ipvrf-21  interface irb0.200
commit now
```

(The `ip-vrf` half is exactly §4.4, with `ethernet-1/2.300` omitted if the routed instance exists
only to carry the gateway.)

### 5.4 Does the FRR IPv6 IRB Type-5 limitation (PC-17) disappear? **Yes — and completely.**

PC-17 was: *"FRR 10.3's known IPv6 IRB Type-5 limitation — a global address registered as a kernel
rather than a connected route, so `redistribute connected` never originates it."*

Every mechanism that bug depended on is absent on SR Linux:

1. **There is no FRR.** EVPN is implemented by SR Linux's own `bgp_evpn_mgr` application
   [VERIFIED: `route-owner` values shown in
   `/root/learn-srlinux/docs/tutorials/l3evpn/rt5-only/l3evpn.md:264, 290` are literally
   `bgp_evpn_mgr`].
2. **There is no `redistribute connected`.** In IFL, *"all interface and local routes … are
   automatically advertised in RT5s without the need for any export policy"* [VERIFIED: Nokia 25-10
   L3 page]. The kernel-route-vs-connected-route distinction simply has no analogue: the ip-vrf's
   route table *is* the advertisement set.
3. **IPv6 anycast gateway is a first-class, symmetric config leaf** with the same shape as IPv4
   [VERIFIED: `$Y/interfaces/srl_nokia-if-ip.yang:379-399` @ v25.7.1].
4. Nokia explicitly documents IPv6 parity, including LLA advertisement:
   *"For IPv6, Local Link Addresses (LLAs) are also advertised in addition to global addresses."*
   [VERIFIED: `https://documentation.nokia.com/srlinux/25-10/books/advanced-solutions/evpn-vxlan-layer-3.html`]

**Honest statement of evidence strength**: the IPv6 half of this rests on the YANG (which is
unambiguous: `anycast-gw` exists identically under `ipv6/address`, and `neighbor-discovery` carries
`learn-unsolicited`, `host-route/populate` and `evpn/advertise` exactly as `arp` does) plus Nokia's
guide. It does **not** rest on a worked example: a repo-wide grep of `/root/learn-srlinux` finds
**zero** occurrences of `neighbor-discovery`, zero IPv6 `anycast-gw`, and zero IPv6 Type-5 examples
— every anycast-gateway and every RT5 example in the entire doc site is IPv4-only
[VERIFIED: exhaustive grep of `/root/learn-srlinux` this session]. **Therefore: the very first
capability-gate item for this retarget must be an IPv6 anycast gateway plus an IPv6 Type-5 route,
observed end to end on the pinned image.** That is precisely the check PC-17 existed to force, and
it should survive the deletion of PC-17 as a gate rather than as a workaround.

**Delete PC-17. Delete CR-001's "affected services report `Ready=False` naming the missing route"
clause as a *platform-specific defect workaround*** — but **keep the general readiness rule**
(Principle I / PC-N-13) that a prefix the service declared and the device has not advertised is not
Ready. The check survives; the reason it existed does not.

### 5.5 SR Linux-specific equivalents to watch instead

These are **not** the same bug, but they are the SR Linux readiness traps that must replace it in
the test matrix. All four are verified:

| Trap | Evidence | Read-back that catches it |
|---|---|---|
| **IRB oper-down on MTU** — *"When the mac-vrf has an associated irb subinterface, if the configured irb ip-mtu exceeds the oper-mac-vrf-mtu minus 14 bytes (Ethernet header), then the irb subinterface will remain operationally down."* | `$Y/…/srl_nokia-network-instance.yang` `leaf oper-mac-vrf-mtu` description @ v25.7.1 | `/network-instance[name]/oper-mac-vrf-mtu` vs `/interface[name=irb0]/subinterface[index]/oper-state` + `oper-down-reason` |
| **IRB needs both associations** | `oper-down-reason` enums `mac-vrf-association-missing`, `ip-vrf-association-missing` | `/network-instance[name]/interface[name=irb0.N]/oper-down-reason` |
| **No MTU check for VXLAN in EVPN-IFL** — *"If the routed packet plus the VXLAN overhead exceeds the underlay interface MTU … the packet is still encapsulated and sent to the remote leaf."* | Nokia 25-10 advanced-solutions L3 page | Nothing on-device catches it — **the MTU arithmetic (PC-19) must be enforced by validation, not by the device.** Keep it as a validation invariant, not a read-back |
| **`anycast-gw` container must exist before `anycast-gw true`** | `must` at `$Y/interfaces/srl_nokia-if-ip.yang:206` | Config-side; caught at SDC dry-run |

Also record: *"BGP PE-CE sessions can only be established with primary IP addresses"* and
*"When IRB subinterfaces are admin-disabled, IRB MAC addresses are removed from the mac-table"*
[VERIFIED: same Nokia page]. The first is why the exemplar sets `primary` on the anycast address.

---

## 6. Multi-vendor naming — does SR Linux literally call them `mac-vrf` and `ip-vrf`?

**Yes, literally.** Both are YANG identities in `srl_nokia-network-instance`, module prefix
`srl_nokia-netinst`, namespace `urn:nokia.com:srlinux:net-inst:network-instance`:

```yang
identity ni-type { description "Base type for network instance types."; }

identity ip-vrf {
  base ni-type;
  description "A private Layer 3 only routing instance.";
}

identity mac-vrf {
  if-feature "srl-feat:bridged";
  base ni-type;
  description "A private Layer 2 only switching instance.";
}
```
[VERIFIED: `$Y/network-instance/srl_nokia-network-instance.yang:103-115` @ v25.7.1; identical at
v24.10.7, v25.10.3 and v26.7.2 — [VERIFIED: same file at those tags]]

They appear as literal string values throughout the model's own `must` expressions, e.g.
`must "../type = 'srl_nokia-netinst:mac-vrf'"` (*"Bridge-table configuration is only possible on
network-instance of type mac-vrf"*) and
`must "current()/../../../srl_nokia-netinst:type = 'srl_nokia-netinst:ip-vrf'"`
[VERIFIED: `$Y/…/srl_nokia-network-instance.yang` `container bridge-table`;
`$Y/…/srl_nokia-bgp-vpn.yang:149-151` @ v25.7.1].

Forms you will see on the wire:

| Context | Form |
|---|---|
| YANG `must` / XPath | `srl_nokia-netinst:mac-vrf` (module **prefix**) |
| RFC 7951 JSON_IETF (gNMI) | `srl_nokia-network-instance:mac-vrf` (module **name**) |
| SR Linux CLI `set` / `info` | `mac-vrf` (bare) |

**Only the first and third are verified this session**; the JSON form follows RFC 7951's rule for
identityref but has not been observed from a running device — see the action note in §2.5.

The other two constructs are **not** device words: there is no `vlan` object type on SR Linux (§3.1),
and access lists are `acl` in SR Linux's own model too (`$Y/acl/`), but that is outside this topic.

**Consequence for FR-024 (Open decision 5b)**: see §3.2. In short — the vocabulary's *status*
changes from translation layer to device terminology for two of four; the *content* does not change
at all; and the composite should say which two, so SC-013 is honest about the other two.

---

## 7. STATE read-back — what "Ready" is allowed to mean (replaces PC-11)

### 7.1 What "the configuration it wrote" and "the device's own applied view" mean on SR Linux

SR Linux exposes **four datastores**: `candidate`, `running`, `state`, `tools`. *"Running: used to
retrieve the active configuration. State: used to retrieve the running (active) configuration along
with the operational state."* [VERIFIED:
`/root/learn-srlinux/docs/tutorials/programmability/json-rpc/basics.md` §Datastore]

There is **no ASIC_DB equivalent** and no second store that a write lands in. The SONiC
"CONFIG_DB vs APPL_DB vs ASIC_DB" three-way split has no analogue. Proposed replacement for
PC-11 and for PC-N-13's "two-sided where an applied view exists":

| SONiC concept | SR Linux replacement |
|---|---|
| "the configuration it wrote" | **The SDC `Config` CR's intended config**, compared against the **`running` datastore** read back over gNMI (`Get` with `type=CONFIG`; `gnmic get --type config`) |
| "the device's own applied view" | **The `state` datastore** (`type=STATE`) — specifically the `config false` leaves the device *derives* from the config: `oper-state`, `oper-down-reason`, the `*-origin` leaves, the bridge/tunnel/RIB tables |
| ASIC_DB programming proof | **`not-programmed-reason` being absent** and **`destination-index` being non-zero** on the bridge-table and VXLAN-destination entries; plus `/platform/**/fib-table` |

`route-distinguisher-origin`, `export-route-target-origin`, `import-route-target-origin` and
`anycast-gw-mac-origin` are the genuinely two-sided leaves: **we write `evi`, the device reports
`route-distinguisher-origin = auto-derived-from-evi` plus the RD value it derived.** That is a real
applied-side assertion, not a re-read of our own write. Use them. (Under the recommended AS plan the
two RT origins read `manual`, which is *also* meaningful: an unexpected `auto-derived-from-evi`
there means the render dropped the RT and the service is about to fail to form silently — §1.1.)

**The SONiC applied-side scoping defect (R-26) must not be re-created.** Every check below is scoped
by the service's own network-instance name, VNI, EVI or RD — none of them is switch-wide, and none
of them passes on a stock leaf.

### 7.2 Per-construct convergence evidence

Paths are gNMI paths; add `origin: native` only if the grpc-server's `yang-models` has been changed
from its default.

#### Common to all three L2/L3 constructs

```
/network-instance[name=<ni>]/oper-state                                 == up
/network-instance[name=<ni>]/oper-down-reason                           absent   (enum: admin-down | no-mcid)
/network-instance[name=<ni>]/interface[name=<subif>]/oper-state         == up
/network-instance[name=<ni>]/interface[name=<subif>]/oper-down-reason   absent
/interface[name=<port>]/subinterface[index=<idx>]/oper-state            == up
/interface[name=<port>]/subinterface[index=<idx>]/oper-down-reason      absent
```
`network-instance/interface/oper-down-reason` enum, verbatim:
`ip-addr-missing | ip-addr-overlap | subif-down | net-inst-down | vrf-type-mismatch |
mac-dup-detected | associated-mac-vrf-down | mac-vrf-association-missing |
ip-vrf-association-missing | associated-ip-vrf-down | evpn-mh-standby | interface-ref-missing |
stp-not-forwarding`
[VERIFIED: `$Y/network-instance/srl_nokia-network-instance.yang:463-482` @ v25.7.1]

#### `vlan`

That is the whole check. **A `vlan` has no overlay evidence and MUST NOT be held to any.** Adding a
VTEP or route check to a `vlan` would be exactly the "unobserved property reported as converged"
inversion — a check that can never pass. A converged `vlan` is: network-instance up, every bridged
subinterface up, and `type == srl_nokia-netinst:mac-vrf` with **no** `vxlan-interface` child and
**no** `protocols/bgp-evpn` child in running.

#### `mac-vrf`

```
# tunnel side
/network-instance[name=<ni>]/vxlan-interface[name=vxlan0.<vni>]/oper-state        == up
/network-instance[name=<ni>]/vxlan-interface[name=vxlan0.<vni>]/oper-down-reason  absent
/tunnel-interface[name=vxlan0]/vxlan-interface[index=<vni>]/oper-state            == up
/tunnel-interface[name=vxlan0]/vxlan-interface[index=<vni>]/oper-down-reason      absent

# EVPN control plane
/network-instance[name=<ni>]/protocols/bgp-evpn/bgp-instance[id=1]/oper-state             == up
/network-instance[name=<ni>]/protocols/bgp-evpn/bgp-instance[id=1]/oper-down-reason        absent
/network-instance[name=<ni>]/protocols/bgp-vpn/bgp-instance[id=1]/oper-down-reason         == none
/network-instance[name=<ni>]/protocols/bgp-vpn/bgp-instance[id=1]/route-distinguisher/rd
/network-instance[name=<ni>]/protocols/bgp-vpn/bgp-instance[id=1]/route-distinguisher/route-distinguisher-origin  == auto-derived-from-evi
/network-instance[name=<ni>]/protocols/bgp-vpn/bgp-instance[id=1]/route-target/export-rt                           == target:<fabricASN>:<evi>
/network-instance[name=<ni>]/protocols/bgp-vpn/bgp-instance[id=1]/route-target/export-route-target-origin           == manual
/network-instance[name=<ni>]/protocols/bgp-vpn/bgp-instance[id=1]/route-target/import-route-target-origin           == manual

# Type-3 / IMET: the remote VTEPs in this EVI's flooding list  (>= peers-1 entries)
/tunnel-interface[name=vxlan0]/vxlan-interface[index=<vni>]/bridge-table/multicast-destinations/destination[vtep=<remote>][vni=<vni>]/destination-index   != 0
/tunnel-interface[name=vxlan0]/vxlan-interface[index=<vni>]/bridge-table/multicast-destinations/destination[vtep=<remote>][vni=<vni>]/multicast-forwarding
/tunnel-interface[name=vxlan0]/vxlan-interface[index=<vni>]/bridge-table/multicast-destinations/destination[…]/not-programmed-reason  absent

# Type-2 / MAC-IP: remote MACs in this bridge domain
/network-instance[name=<ni>]/bridge-table/mac-table/mac[address=<mac>]/type                   == evpn
/network-instance[name=<ni>]/bridge-table/mac-table/mac[address=<mac>]/destination
/network-instance[name=<ni>]/bridge-table/mac-table/mac[address=<mac>]/not-programmed-reason   absent
/tunnel-interface[name=vxlan0]/vxlan-interface[index=<vni>]/bridge-table/unicast-destinations/destination[vtep=<remote>][vni=<vni>]/destination-index != 0

# VTEP / tunnel table
/tunnel/srl_nokia-vxlan-tunnel-vtep:vxlan-tunnel/vtep[address=<remote-system-ip>]/index         != 0
/tunnel/srl_nokia-vxlan-tunnel-vtep:vxlan-tunnel/vtep[address=<remote-system-ip>]/last-change
/network-instance[name=default]/tunnel-table/…                                                 (owner vxlan_mgr, type vxlan)
```
[VERIFIED @ v25.7.1: `vxlan-interface` oper leaves `$Y/tunnel/srl_nokia-tunnel-interfaces.yang:136-157`
with `oper-down-reason` enum `mac-failed | ingress-hash-failed | egress-hash-failed | other`;
network-instance `vxlan-interface` oper-down-reason enum
`vxlan-tunnel-down | net-inst-down | vxlan-if-default-net-inst-source-address-missing |
vxlan-if-default-net-inst-source-if-down | vrf-type-mismatch | no-mcid`
at `$Y/…/srl_nokia-network-instance.yang:566-574`;
bgp-evpn `oper-down-reason` enum at `$Y/…/srl_nokia-bgp-evpn.yang:640-658`;
bgp-vpn `oper-down-reason` enum at `$Y/…/srl_nokia-bgp-vpn.yang:239-248`;
multicast destination `list destination { key "vtep vni"; }` with `multicast-forwarding`,
`destination-index`, `not-programmed-reason` at
`$Y/tunnel/srl_nokia-tunnel-interfaces-vxlan-interface-bridge-table-multicast-destinations.yang:37-70`;
unicast destinations + `es-destination` keyed by `esi` at
`…-unicast-destinations.yang:134-185`;
mac-table `list mac { key "address" }` with `type`, `destination-type`, `destination-index`,
`destination`, `last-update`, `not-programmed-reason { mac-limit | failed-on-slots |
no-destination-index | reserved }`, `failed-slots` at
`$Y/network-instance/srl_nokia-bridge-table-mac-table.yang:48-122`;
`mac-type` enum `static | duplicate | learnt | irb-interface | evpn | evpn-static |
irb-interface-anycast | proxy-anti-spoof | reserved | eth-cfm | irb-interface-vrrp` at
`$Y/common/srl_nokia-common.yang:1867-1905`;
`/tunnel/vxlan-tunnel/vtep[address]` with `index` and `last-change` at
`$Y/tunnel/srl_nokia-vxlan-tunnel-vtep.yang:173-196`.
Operational shape cross-checked against the tutorial's real CLI output at
`/root/learn-srlinux/docs/tutorials/l2evpn/evpn.md:794-856` — including the `vxlan_mgr` /
`vxlan` owner/type of the default-instance tunnel-table row.]

#### `ip-vrf`

```
/network-instance[name=<ni>]/oper-state                                                        == up
/network-instance[name=<ni>]/vxlan-interface[name=vxlan0.<l3vni>]/oper-state                    == up
/network-instance[name=<ni>]/protocols/bgp-evpn/bgp-instance[id=1]/oper-state                   == up
/network-instance[name=<ni>]/protocols/bgp-vpn/bgp-instance[id=1]/route-distinguisher/rd

# Type-5 received and installed — THIS is the ip-vrf's convergence proof
/network-instance[name=<ni>]/route-table/srl_nokia-ip-route-tables:ipv4-unicast/route[ipv4-prefix=<remote-prefix>][route-type=srl_nokia-common:bgp-evpn][route-owner=bgp_evpn_mgr][id=0][origin-network-instance=<ni>]/active  == true
/network-instance[name=<ni>]/route-table/srl_nokia-ip-route-tables:ipv6-unicast/route[…]/active                                         == true

# with an anycast gateway: the IRB's own subnet and the host routes it populates
#   route-type=srl_nokia-common:local   route-owner=net_inst_mgr   (the IRB subnet)
#   route-type=srl_nokia-common:arp-nd  route-owner=arp_nd_mgr     (/32 or /128 host routes from
#                                                                   `arp host-route populate dynamic`)
```
Real device output confirming those two owner strings in an `ip-vrf` carrying an IRB:
`192.168.1.0/24 | local | net_inst_mgr | … | irb1.1` and
`192.168.1.11/32 | arp-nd | arp_nd_mgr | … | irb1.1`
[VERIFIED: `/root/learn-srlinux/docs/blog/posts/2023/sr-linux-kubernetes-anycast-lab.md:381-414`]
The `route` list key is **five parts**:
`key "ipv4-prefix route-type route-owner id origin-network-instance"`
[VERIFIED: `$Y/network-instance/srl_nokia-ip-route-tables.yang:565-575` (v4) and `:605-615` (v6)
@ v25.7.1]. `route-type` is an identityref with base `srl_nokia-comm:ip-route-type`; the EVPN
members are `bgp-evpn` (*"BGP Ethernet VPN (EVPN) Interface-less"*), `bgp-evpn-iff`
(*"…Interface-ful"*) and `bgp-evpn-ifl-host` (*"…Interface-less Host"*)
[VERIFIED: `$Y/common/srl_nokia-common.yang:1443-1463` @ v25.7.1]. `route-owner` is a free-form
`string` — *"The application name of the owner of the IP route"*
[VERIFIED: `$Y/…/srl_nokia-ip-route-tables.yang:325-330`] — whose observed value for EVPN routes is
**`bgp_evpn_mgr`** [VERIFIED: real tutorial output at
`/root/learn-srlinux/docs/tutorials/l3evpn/rt5-only/l3evpn.md:264, 290`, which shows
`route-type = bgp-evpn`, `route-owner = bgp_evpn_mgr`, `active = True`, `preference 170`,
next-hop `10.0.0.2/32`].

**Assert on `route-type == bgp-evpn`, not on `route-owner`** — `route-type` is a typed identityref
with a stable name; `route-owner` is an internal application name that Nokia may rename.

#### BGP session and per-AFI counters (all constructs, on `network-instance default`)

```
/network-instance[name=default]/protocols/bgp/neighbor[peer-address=<spine-ip>]/session-state                                        == established
/network-instance[name=default]/protocols/bgp/neighbor[peer-address=<spine-ip>]/afi-safi[afi-safi-name=srl_nokia-common:evpn]/received-routes
/network-instance[name=default]/protocols/bgp/neighbor[peer-address=<spine-ip>]/afi-safi[afi-safi-name=srl_nokia-common:evpn]/active-routes
/network-instance[name=default]/protocols/bgp/neighbor[peer-address=<spine-ip>]/afi-safi[afi-safi-name=srl_nokia-common:evpn]/sent-routes
/network-instance[name=default]/protocols/bgp/neighbor[peer-address=<spine-ip>]/afi-safi[afi-safi-name=srl_nokia-common:evpn]/rejected-routes
```
[VERIFIED: `session-state` enum at `$Y/network-instance/srl_nokia-bgp.yang:1517-1541`;
`received-routes`, `sent-routes`, `active-routes`, `rejected-routes`,
`received-routes-withdrawn-due-to-error` at `:2467-2500`; `afi-safi-name` identityref base
`srl_nokia-comm:bgp-address-family` with member `identity evpn` at
`$Y/common/srl_nokia-common.yang:1793` @ v25.7.1. Note the `must` on the neighbor's `afi-safi-name`:
*"EVPN is not supported in network instances other than default"*.]

#### EVPN RIB, by route type (SC-004's "required Type 2, 3 and 5 routes")

`/network-instance[name=default]/srl_nokia-rib-bgp:bgp-rib/afi-safi[afi-safi-name=srl_nokia-common:evpn]/evpn/`
then one of:

| EVPN route type | List | List key |
|---|---|---|
| Type 1 (Ethernet A-D) | `ethernet-ad-route` | `route-distinguisher esi ethernet-tag-id neighbor path-id` |
| **Type 2 (MAC/IP)** | `mac-ip-route` | `route-distinguisher mac-length mac-address ip-address ethernet-tag-id neighbor path-id` |
| **Type 3 (IMET)** | `imet-route` | `route-distinguisher originating-router ethernet-tag-id neighbor path-id` |
| Type 4 (ES) | `ethernet-segment-route` | `route-distinguisher esi originating-router neighbor path-id` |
| **Type 5 (IP prefix)** | `ip-prefix-route` | `route-distinguisher ethernet-tag-id ip-prefix-length ip-prefix neighbor path-id` |
| Type 6/7/8 (SMET, sync) | `smet-route`, `multicast-membership-report-synch-route`, `multicast-leave-synch-route` | … |

under the containers `local-rib`, `rib-in-out/rib-in-pre`, `rib-in-out/rib-in-post`,
`rib-in-out/rib-out-post`
[VERIFIED: `$Y/network-instance/srl_nokia-rib-bgp.yang:2658-2830` and the `augment
"/srl_nokia-netinst:network-instance"` at `:3805` @ v25.7.1].

**Scoping recommendation**: filter by `route-distinguisher = <this service's RD>` in `local-rib`.
That is per-service and cannot pass on a stock leaf. Counting routes fabric-wide is the R-26 defect.
Note the RD is **per-leaf** (`<system-ip>:<evi>`), so the local RD identifies *our* advertisements
and the remote leaves' RDs (`<their-system-ip>:<same evi>`) identify what we received — match on the
`:<evi>` suffix when checking the receive side.

### 7.3 Datapath-programming evidence (the ASIC_DB replacement)

SR Linux surfaces programming failure as *negative* leaves rather than a positive mirror store:

- `bridge-table/mac-table/mac[…]/not-programmed-reason` —
  `mac-limit | failed-on-slots | no-destination-index | reserved`, plus `failed-slots` (a
  `leaf-list uint8 { range "1..16" }` of linecard slot IDs)
  [VERIFIED: `$Y/…/srl_nokia-bridge-table-mac-table.yang:82-98` @ v25.7.1].
- `…/bridge-table/multicast-destinations/destination[…]/not-programmed-reason` and
  `…/unicast-destinations/destination[…]/destination-index`
  [VERIFIED: the two destination modules cited above].
- `srl_nokia-ip-route-tables` also augments
  `/platform/linecard/forwarding-complex/fib-table` **and**
  `/platform/control/forwarding-plane/fib-table`
  [VERIFIED: `$Y/network-instance/srl_nokia-ip-route-tables.yang:920, 926` @ v25.7.1].
  **[UNVERIFIED: from memory]** which of those two is populated on a containerised SR Linux with no
  physical linecard — confirm at first bring-up and pick one.

**Recommended two-sided rule**: *applied* means
`oper-state == up` **and** `not-programmed-reason` absent **and** `destination-index != 0`
on every object the service owns. That is observed device state, scoped to the service, and it
cannot pass on an unprovisioned leaf — which is precisely the property R-26 found missing.

### 7.4 Subscription shape for the telemetry pipeline (PC-A-08 input)

All of the above are `config false` leaves in the `state` datastore, so they are `SAMPLE`- or
`ON_CHANGE`-subscribable over gNMI. Recommended `ON_CHANGE` set (small, high-signal):
`…/oper-state`, `…/oper-down-reason`, `…/session-state`, `…/*-origin`,
`/tunnel/vxlan-tunnel/vtep[address=*]/index`. Recommended `SAMPLE` set: the per-AFI route counters
and the mac-table statistics (`active-entries`, `total-entries`, `failed-entries`, and the
per-`mac-type` breakdown at `$Y/…/srl_nokia-bridge-table-mac-table.yang:124-175`).

---

## 8. Identifier allocation — recommended KUID claim profiles

### 8.1 What actually needs allocating

| Value | Needs a claim? | Why |
|---|---|---|
| **VLAN ID** | **Yes**, unless the operator named one | Fabric-scoped; 1–4094; already in `vlan.be.kuid.dev/VLANIndex` 100–4000 |
| **L2VNI** | **Yes** | Fabric-scoped; `genid.be.kuid.dev/GENIDIndex` 10000–20000 |
| **L3VNI** | **Yes** | Same index, same band |
| **EVI** | **No — derive `evi := vni`** | See §8.2 |
| **Route target** | **No — but render it explicitly** as `target:<fabricASN>:<evi>`; `fabricASN` is a configuration constant, not a claim | See §8.2 and the AS-plan trap in §1.1 |
| **Route distinguisher** | **No — let SR Linux auto-derive `<system0.0 ipv4>:<evi>`** | Per-leaf unique by construction; requires no fabric-wide index |
| **Subinterface index** | **No — derive `index := vlan-id`, untagged `:= 0`** | See §9 |
| **vxlan-interface index** | **No — derive `index := vni`** | Node-scoped; VNI is already unique fabric-wide, so it is trivially unique per node |
| **tunnel-interface name** | **No — fabric constant `vxlan0`** | 1 of 256 slots; a constant makes goldens stable |
| **irb subinterface index** | **No — derive `index := vlan-id`** | Keeps `ethernet-1/N.<vlan>` and `irb0.<vlan>` in lockstep |
| **network-instance name** | **No — derive from serviceId** | See §9.3 |
| **ESI** | **No — out of scope** | EVPN multihoming stays out (§10) |

### 8.2 The central recommendation: `evi := vni`, and drop the RT index

EVI is `1..65535` [VERIFIED: `typedef evi`, `$Y/common/srl_nokia-common.yang:2055-2061` @ v25.7.1].
KUID's VNI band is `10000–20000` [VERIFIED: `contracts/kuid-claim-profiles.md` §1]. The band fits
**entirely** inside the EVI range. Therefore:

- **`evi := vni`** is a legal, collision-free, deterministic derivation on both the L2 and L3 halves
  (`evi_l2 := l2vni`, `evi_l3 := l3vni`, and the two VNIs already differ).
- With `evi` set and `rd` omitted, SR Linux derives RD `= <system0.0 ipv4>:<evi>`, per-leaf unique
  and independent of any ASN [VERIFIED: `$Y/network-instance/srl_nokia-bgp-vpn.yang:168-171`
  @ v25.7.1, corroborated by Nokia's 25-10 L2 guide and by live output at
  `/root/learn-srlinux/docs/tutorials/l2evpn/evpn.md:344-352`]. **No RD claim.**
- **RT is rendered explicitly as `target:<fabricASN>:<evi>`**, where `fabricASN` is a single
  fabric-wide configuration constant. It is *not* claimed: it is a pure function of an
  already-claimed VNI and a constant. Auto-derivation is rejected because it would use the *per-leaf*
  underlay ASN and produce a different RT on every leaf (§1.1)
  [VERIFIED: `/root/learn-srlinux/docs/tutorials/l3evpn/rt5-only/l3evpn.md:86` states this failure
  mode explicitly as the reason its own tutorial sets RTs by hand].
- **The `extcomm.be.kuid.dev/EXTCOMMIndex` route-target index therefore still claims nothing.** That
  deletes one whole index family from the critical path, removes a class of leakable claims (D-25's
  concern), and makes RD and RT reconstructable from the VNI plus one constant.

**The new constraint this creates, and it must be stated as a requirement**: the VNI index band
**MUST remain within `1..65535`** while `evi := vni` holds. If anyone widens the VNI band above
65535, the derivation silently breaks at `evi` validation. This is the *replacement* for the
"renderable L3VNI band" constraint in construct-vocabulary.md §4 — same shape of rule, different and
now *device-grounded* reason:

> **FR-034 (retargeted band clause)**: The VNI index band MUST be a subset of the device's EVPN
> instance identifier range, because the EVPN instance identifier is derived from the VNI. A request
> for a VNI outside that band is refused naming the VNI and the band. (Device range at the pinned
> release: `1..65535`.)

**When the EXTCOMM index would come back**: asymmetric import/export (hub-and-spoke), route-target
based leaking between tenants, or interop with a non-SR-Linux PE that derives differently. None of
those is in the four constructs today — so **keep the index configured and the claim code path
alive, but claim zero**, and make "the profile claimed zero route targets" an explicit, asserted
outcome rather than an accident (the same discipline `acl`'s zero-claim release already needs).

### 8.3 Recommended claim profiles (replacement for `contracts/kuid-claim-profiles.md` §2)

| Construct | VLAN index | VNI index (L2VNI) | VNI index (L3VNI) | RT index | Derived, not claimed |
|---|---|---|---|---|---|
| `vlan` | claim **unless the operator named a VLAN** | — | — | — | subif index := vlan; NI name := `vlan-<serviceId>` |
| `mac-vrf` | claim unless named | claim | — | **0** | `evi := l2vni`; vxlan-if index := l2vni; RD auto-derived; RT = `target:<fabricASN>:<l2vni>`; subif index := vlan |
| `mac-vrf` + gateway | claim unless named | claim | claim | **0** | as above, plus `evi_l3 := l3vni`, RT = `target:<fabricASN>:<l3vni>`, `irb0.<vlan>`, second vxlan-if index := l3vni |
| `ip-vrf` | — | — | claim | **0** | `evi := l3vni`; vxlan-if index := l3vni; RD auto-derived; RT = `target:<fabricASN>:<l3vni>`; routed subif index := vlan of the attachment |
| `acl` | — | — | — | — | claims nothing (unchanged) |

Two rules carried forward unchanged: a VLAN the operator named is not claimed, and two different
requested VLANs on one service is a contradiction, refused, never resolved.

One rule **deleted**: *"An L3VNI is claimed from the sub-band that has a derivable routed-instance
VLAN"* — there is no derivable routed-instance VLAN on SR Linux (§4.3).

One rule **added**: the release path must assert that the RT index claim count is **zero** for every
construct, mirroring how `acl`'s zero-claim release is already asserted. Otherwise the EXTCOMM index
becomes dead code nobody notices has started claiming again.

---

## 9. Attachment model

### 9.1 What an attachment point is on SR Linux

`attachment point = node + port + vlan` maps to:

```
/interface[name=ethernet-1/N]/srl_nokia-interfaces-vlans:vlan-tagging = true
/interface[name=ethernet-1/N]/subinterface[index=<idx>]/type          = bridged | routed
/interface[name=ethernet-1/N]/subinterface[index=<idx>]/srl_nokia-interfaces-vlans:vlan/encap/single-tagged/vlan-id = <vlan>
/network-instance[name=<ni>]/interface[name=ethernet-1/N.<idx>]
```

Interface names are `ethernet-<slot>/<port>` per
`typedef interface-all`, `length "3..21"`, pattern including
`ethernet-([1-9](\d){0,1}(/m[1-6])?(/[1-9](\d){0,1})?/(([1-9](\d){0,1})|(1[0-1]\d)|(12[0-8])))`,
plus `system0`, `lo0..lo255`, `irb0..irb255`, `lag1..lag1000`, `mgmt0`
[VERIFIED: `$Y/common/srl_nokia-common.yang:723-741` @ v25.7.1].
Containerlab maps `ethernet-1/Y` to the Linux device `e1-Y`
[VERIFIED: `https://containerlab.dev/manual/kinds/srl/`]. **PC-A-01's `Ethernet8`-style naming is
replaced by `ethernet-1/N`, and the site port map (PC-A-07) is re-keyed accordingly.**

### 9.2 Recommended deterministic subinterface-index derivation

> **`subinterface index := vlan-id` for a tagged attachment; `index := 0` for an untagged one.**

Why this and not a counter:

1. **It is legal.** `vlan-id` is `1..4094`; subinterface `index` is `0..9999` with
   `max-elements 4095` per interface; the `subinterface-all` reference pattern accepts
   `(0|[1-9]\d{0,3})`, i.e. exactly 0–9999
   [VERIFIED: `$Y/interfaces/srl_nokia-interfaces.yang:1003-1011`;
   `$Y/interfaces/srl_nokia-interfaces-vlans.yang:80-86`;
   `$Y/common/srl_nokia-common.yang:758-771` @ v25.7.1]. 4094 tagged subinterfaces + index 0 fits
   the `max-elements 4095` ceiling **exactly**.
2. **It makes the golden files readable and stable.** `ethernet-1/1.200` self-evidently carries
   VLAN 200. A counter would make golden files order-dependent and would break SC-006.
3. **It turns the conflict rule into a name collision.** Two services wanting (leaf01,
   ethernet-1/1, vlan 200) both derive `ethernet-1/1.200` — detectable at *validation*, before any
   device write, by pure string comparison. No device query needed.
4. **It is idempotent under re-render**, which SC-006 requires.

**Untagged caveat**: SR Linux's `encap/untagged` container carries
`must '(../../../../vlan-tagging = true())'` — *"untagged only configurable if vlan-tagging enabled
on parent interface"* — and `must "(../../../srl_nokia-if:type = 'srl_nokia-if:bridged')"` —
*"untagged only allowed with type bridged"*
[VERIFIED: `$Y/interfaces/srl_nokia-interfaces-vlans.yang` `container untagged` @ v25.7.1]. So an
"untagged port" still has `vlan-tagging true` and subinterface `0` with an explicit `untagged`
encap. A port with `vlan-tagging false` has a single subinterface `0` with **no** `vlan` container
at all — that is a *third* mode, and the render must pick one per port and refuse mixing.

**IRB index**: `irb0.<vlan-id>`, same number. Then for any service, the triple
(bridged subif index, irb subif index, VLAN) are all the same integer, and `irb0` holds up to 4095
subinterfaces before `irb1` is needed [VERIFIED: same `max-elements 4095`; `irb0..irb255` from
`interface-all`].

**vxlan-interface index**: `:= vni` (§8.1). `vxlan0.10021` then reads as "the VXLAN interface for
VNI 10021".

### 9.3 Network-instance name derivation

`restricted-name` allows `length 1..247` and a broad character set that notably **excludes `/`**
and allows a space anywhere but the first character
[VERIFIED: `$Y/common/srl_nokia-common.yang:1189-1196` @ v25.7.1].

**Recommendation: keep the existing SONiC-derived name function unchanged.** PC-06's rule —
`[a-zA-Z0-9]{1}([-a-zA-Z0-9_]{1,63})`, 2–64 chars, first char alphanumeric, no dot, no space — is a
**strict subset** of `restricted-name`. Every name it produces is valid on SR Linux. Keeping it:

- costs nothing,
- preserves the derivation function and its tests (the function that exists "because a device once
  rejected a 19-character generated name"),
- and keeps names Linux-safe and shell-safe, which matters because SR Linux network-instance names
  become Linux network namespace names.

So PC-06 **survives the retarget as a deliberately narrower self-imposed rule**, not as a device
constraint. Record it that way in platform-coupling.md — reclassify PC-06 from `platform-specific`
to `platform-adjacent`, with the note that the device's own rule is looser.

Recommended derivations:

| Construct | Network-instance name |
|---|---|
| `vlan` | `vlan-<serviceId>` |
| `mac-vrf` | `macvrf-<serviceId>` |
| `ip-vrf` (standalone or the routed half of a gateway-bearing `mac-vrf`) | `ipvrf-<serviceId>` |

### 9.4 Conflict cases and what each must do

| # | Conflict | Device behaviour | Recommended platform behaviour |
|---|---|---|---|
| 1 | Two services claim the same (node, port, vlan) | The derived subinterface `ethernet-1/N.<vlan>` can belong to **only one** network-instance | **Refuse at validation**, naming the holding service and the port+VLAN. Pure string comparison — no device query |
| 2 | Same (node, port), one service wants a bridged attachment and another a routed one at different VLANs | Legal on SR Linux — `type` is per-subinterface | **Allow.** This is the normal mixed-service port |
| 3 | Same (node, port), one service needs `vlan-tagging false` and another needs a tagged subinterface | `vlan-tagging` is a **per-interface** leaf; the `must`s make the combination unsatisfiable | **Refuse**, naming the port and the two services — this is an interface-level, not subinterface-level, exclusivity |
| 4 | Same VLAN ID used by two different services on two different ports of one node | **Legal on SR Linux** — VLAN is only an encap match, not a node-global object | **Refuse anyway.** The VLAN index is fabric-allocated and one VLAN means one broadcast domain across the fabric (construct-vocabulary.md §4). Allowing it would make the allocated VLAN meaningless |
| 5 | `irb0.<vlan>` attached to two `ip-vrf`s | SR Linux rejects/downs it; `oper-down-reason` reports the missing or wrong association | **Refuse at validation**; the read-back check is the backstop, not the gate |
| 6 | A construct tries to attach a subinterface to a **spine** | Legal on SR Linux | **Refuse** — FR-011 and data-model.md §20 ("Spines cannot be service attachment points or VTEPs"). Observable backstop: spine `/tunnel-interface` list is empty |
| 7 | An `acl` and a service both bind the same port at the same stage | Out of this topic — see Open decision 4 | — |

Note for Open decision 4, since it touches this model: SR Linux binds filters to **subinterfaces**,
not ports (`/interface/subinterface/acl/…`). That confirms the coupling file's prediction in PC-A-02
that "a platform that binds filters to subinterfaces rewrites both requirements". With `subinterface
index := vlan-id`, the unit of exclusivity naturally becomes "(port, vlan, stage)", which is
*finer* than "(port, stage)" and therefore strictly less restrictive — a good outcome, but a
requirement-level change. **[UNVERIFIED: from memory]** that SR Linux has no port-level ACL binding
at all; that belongs to the ACL research topic, not this one.

---

## 10. Scale, limits and multihoming scope

### 10.1 Container-specific limits the tests must respect

| Limit | Value | Source |
|---|---|---|
| **Datapath throughput, license-less** | **1000 PPS** | [VERIFIED: `https://containerlab.dev/manual/kinds/srl/` — *"the datapath is limited to 1000 PPS"*] |
| **Process lifetime, license-less** | *"the `sr_linux` process will restart once a week"* | [VERIFIED: same page] |
| **Default node type** | `ixr-d2l` if `type` is unset | [VERIFIED: same page] |
| **Type used by the reference EVPN lab** | `ixr-d2` for leaves, `ixr-d3` for the spine, image `ghcr.io/nokia/srlinux:25.10` | [VERIFIED: `/root/learn-srlinux/labs/evpn01.clab.yml`] |
| **EVPN-VXLAN platform support** | *"supported on specific platforms (7220 IXR-D2/D3, 7250 IXR Gen 2, 7730 SXR)"* | [VERIFIED: `https://documentation.nokia.com/srlinux/25-10/books/vpn-services/evpn-vxlan-tunnels-layer-3.html`] |

| **Per-node resources** | *"Each node requires 2vCPU and 2GB of RAM"* | [VERIFIED: `/root/learn-srlinux/docs/get-started/lab.md:174` footnote] |
| **Reference EVPN lab envelope** | 2 vCPU / 6 GB for 3 SR Linux nodes + 2 Linux clients | [VERIFIED: `/root/learn-srlinux/docs/tutorials/l2evpn/intro.md:13`] |
| **Reference L3 EVPN lab envelope** | 2 vCPU / 8 GB | [VERIFIED: `/root/learn-srlinux/docs/tutorials/l3evpn/rt5-only/index.md:12`] |
| **Bare container's emulated variant** | D3L by default | [VERIFIED: `/root/learn-srlinux/docs/get-started/lab.md:80`] |

**The host budget is a real constraint for this composite**: 2 spines + 2 leaves at 2 GB each is
8 GB for the fabric alone, before four Linux endpoint containers and before the Kind cluster that
runs everything else. NFR-012 ("the intent tier MUST run within the resource envelope of the
existing single-host lab") should be re-derived against that number rather than inherited from the
SONiC figure.

**Recommendation on node type**: pin `type: ixr-d2` for `leaf01`/`leaf02` and `type: ixr-d3` for
`spine01`/`spine02` — the exact pair the reference EVPN lab uses, and inside the documented
EVPN-VXLAN-supported family. Do **not** rely on the `ixr-d2l` default; state it explicitly so the
topology is reproducible across containerlab versions.

**The 1000 PPS ceiling is a requirement-level fact**, not a footnote. SC-005's "cross-leaf L2
reachability, intra-routed-instance L3 routing and inter-instance isolation tests" must be written
as *reachability and isolation* tests (ping, ARP/ND resolution, MAC learning, route presence), never
as throughput tests, and any acceptance packet-rate must sit well under 1000 PPS. The MTU
acceptance packets (PC-19) are fine — they are single large packets, not a rate.

### 10.2 Model limits

| Limit | Value | Source @ v25.7.1 |
|---|---|---|
| `vxlan-interface` per `tunnel-interface` | `max-elements 16384` | `$Y/tunnel/srl_nokia-tunnel-interfaces.yang:93` |
| `vxlan-interface` per network-instance | `max-elements 1` | `$Y/…/srl_nokia-network-instance.yang` `list vxlan-interface` |
| `tunnel-interface` names | `vxlan0`..`vxlan255` | `$Y/tunnel/srl_nokia-tunnel-interfaces.yang` `leaf name` description |
| Subinterfaces per interface | `max-elements 4095` | `$Y/interfaces/srl_nokia-interfaces.yang:1004` |
| `bgp-evpn/bgp-instance` per network-instance | `max-elements 1` | `$Y/…/srl_nokia-bgp-evpn.yang` `list bgp-instance` |
| `bgp-vpn/bgp-instance` per network-instance | `max-elements 2`, *"Only one instance allowed in the current release"* | `$Y/…/srl_nokia-bgp-vpn.yang:153-157` |
| `ecmp` | 1..8 for `mac-vrf`/`vpws`, 1..128 for `ip-vrf` | `$Y/…/srl_nokia-bgp-evpn.yang:625-637` |
| Bridge-table MAC limit | **default 250**, range 1..250000 | `$Y/…/srl_nokia-bridge-table-mac-limit.yang:27-34` |
| `oper-mac-vrf-mtu` | 1492..9500 | `$Y/…/srl_nokia-network-instance.yang` `leaf oper-mac-vrf-mtu` |

**The default MAC limit of 250 is the one that will surprise a scale test.** It is a *configuration*
default, so a test that learns more than 250 MACs in one `mac-vrf` will see
`not-programmed-reason = mac-limit` rather than a failure — and a read-back that only checks
`oper-state` would call that Ready. Either raise
`/network-instance[name]/bridge-table/mac-limit/maximum-entries` explicitly in the render, or cap
the test. **Recommend: set it explicitly in the render so the value is owned and visible, not
inherited.**

### 10.3 EVPN multihoming — **confirmed out of scope, and cleanly separable**

Multihoming configuration lives in an entirely different subtree:

```
/system/network-instance/protocols/evpn/ethernet-segments/bgp-instance[id=1]/ethernet-segment[name=…]/esi
                                                                                             …/multi-homing-mode
                                                                                             …/interface
                                                                                             …/esi-label
```
[VERIFIED: `$Y/system/srl_nokia-system-network-instance-bgp-evpn-ethernet-segments.yang:426-660`
with `augment "/srl_nokia-system:system/…/protocols/…:evpn"` @ v25.7.1. `esi` is
`srl_nokia-comm:esi`, 10 bytes, with `must` rejecting ESI-0, MAX-ESI and any value whose bytes 1–6
are all zero *"since they would produce a null ESI-import route-target"*.]

Confirmations that it stays out:

- It is a **system-level** subtree, not a per-service one. Nothing in any of the four constructs
  reaches it.
- It needs a LAG or a virtual ES per attachment — the four constructs' attachment model is a single
  port + VLAN (§9), which is single-homed by construction.
- Its traces in the service-level model are inert when it is unconfigured: the `es-destination` list
  in `unicast-destinations` stays empty; the `evpn-mh-standby` `oper-down-reason` never fires; the
  `ethernet-segment-route` (Type 4) and `ethernet-ad-route` (Type 1) RIB lists stay empty
  [VERIFIED: the corresponding lists in
  `$Y/tunnel/…-unicast-destinations.yang:134-155`,
  `$Y/…/srl_nokia-network-instance.yang:463-480`,
  `$Y/…/srl_nokia-rib-bgp.yang:2658-2700` @ v25.7.1].
- Feature flags exist for it (`evpn-mh`, `evpn-mh-virtual-es`, `evpn-mh-ip-aliasing`,
  `evpn-mh-no-esi-label`, …) so a future capability gate has something concrete to test
  [VERIFIED: `$Y/common/srl_nokia-features.yang` — `feature evpn-mh` and siblings].
- Its own documented limits would need new requirements if it ever came in scope: **an Ethernet
  Segment spans at most four PEs**; a LAG is **mandatory** for all-active mode; `esi`,
  `multi-homing-mode` and the LACP parameters must match on every ES peer; and `ecmp` must be sized
  by hand to the number of PEs serving the CE
  [VERIFIED: `/root/learn-srlinux/docs/tutorials/evpn-mh/basics/index.md:150, 168`,
  `.../conf.md:62, 115, 132-133, 187`].

**Recommendation: EVPN multihoming stays out of scope. No ESI is ever claimed. Say so explicitly in
the claim-profile contract (an ESI row that reads "never claimed") rather than leaving it
unmentioned**, so a later reader does not have to rediscover the decision.

---

## 11. Summary of coupling-row dispositions

| Row | Was | Disposition under SR Linux |
|---|---|---|
| **PC-11** | CONFIG_DB/APPL_DB/ASIC_DB table names, db numbers, `redis-hget` check types | **Deleted and replaced.** SR Linux has four datastores (`candidate`/`running`/`state`/`tools`); "what we wrote" = SDC intended vs the `running` datastore; "the applied view" = the `state` datastore's derived `config false` leaves. The ASIC_DB analogue is `not-programmed-reason` absent + `destination-index != 0` + `/platform/**/fib-table`. §7 |
| **PC-15** | Routed-instance VLAN band 4001–4094 and L3VNI sub-band 10000–14094 | **Deleted outright.** No VLAN-per-VRF derivation exists. Replaced by the EVI ceiling `1..65535` and the rule that the VNI band must be a subset of it. §4.3, §8.2 |
| **PC-16** | Device routed-instance name derivation; port map to kernel devices | **Halved.** The name derivation survives as a *narrower-than-necessary* rule (PC-06 is a strict subset of `restricted-name`) — keep it. The "kernel devices that are not port-table rows" half is deleted: every attachment on SR Linux is a first-class `interface`/`subinterface`, there is no bypass path. §9.3 |
| **PC-17** | FRR 10.3 IPv6 IRB Type-5 kernel-vs-connected-route bug | **Deleted.** No FRR, no `redistribute connected`, IFL advertises the whole ip-vrf route table automatically, IPv6 anycast-gw is first-class. Replaced by four SR Linux-specific readiness traps (IRB MTU, dual association, no VXLAN MTU check, anycast-gw container ordering). §5.4, §5.5 |
| **PC-A-07** | Site inventory node and port maps | **Content replaced**: node kind `nokia_srlinux`, types `ixr-d2`/`ixr-d3`, port names `ethernet-1/N` (Linux `e1-N`). The map's *shape* stands. §9.1, §10.1 |
| **PC-A-12** | Golden files and deterministic emission order | **Contents replaced, contract intact.** §2.4/§2.5, §3.1, §4.4, §5.3 are the exemplars. One open item: freeze the identityref serialization form (`"srl_nokia-network-instance:mac-vrf"` vs `"mac-vrf"`) from a real `Get` at first bring-up before the goldens are locked. §2.5 |
| **Open decision 5** | Vocabulary status; does `vlan` survive? | **Keep `vlan` as its own construct** (D-11's defect otherwise returns, now more strongly). **Make the `mac-vrf`/`ip-vrf` alignment a requirement** with a CI assertion against the pinned YANG, and state that two of four — not four of four — are device terminology. Reword FR-029 away from "a VLAN and its port membership" to "a local bridge domain and its subinterfaces". §3.2 |

## 12. Open items a later pass must close

1. **Identityref JSON serialization form** — observe it from a real device before freezing goldens
   (§2.5). This is the only item in the exemplars that is not verified.
2. **Which `fib-table` augment is populated** on a containerised SR Linux with no linecard
   (`/platform/linecard/forwarding-complex/fib-table` vs
   `/platform/control/forwarding-plane/fib-table`) (§7.3).
3. **Whether SR Linux offers any port-level ACL bind point**, or subinterface only — belongs to the
   ACL topic but changes Open decision 4's conflict unit (§9.4 note).
4. **`inter-as-vpn true` on the spines** — the leaf and its semantics are verified at v25.7.1
   (§1.1), but that it is *required* for a non-VTEP RR spine comes from a Nokia engineer's blog post
   at 24.7.1 rather than from the release documentation. Confirm empirically at first bring-up that
   omitting it reproduces the "every session established, zero EVPN routes" failure, then add it to
   the capability gate.
5. **IPv6 anycast gateway + IPv6 Type-5, observed end to end.** Nothing in the entire
   learn.srlinux.dev corpus demonstrates either (§5.4). This is the first capability-gate item.
6. **sdcio deviations** — the pinned `srlinux-yang-patch@v25.7` deletes `must` constraints on
   subinterface `type`, `ipv4`/`ipv6` `admin-state`, `vxlan-interface` and
   `bgp-evpn/bgp-instance/id`. Those are *exactly* the nodes this report's renders touch. Verify at
   bring-up that the deviated schema still rejects the invalid configurations this report relies on
   being rejected (e.g. `anycast-gw true` without the `anycast-gw` container), or the SDC dry-run
   gate is weaker than the device.
