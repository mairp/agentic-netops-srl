# Hand-written construct examples (T062)

`kubectl apply -f examples/constructs/` applies the six `Network` objects in this directory —
it reads only `.yaml`, `.yml` and `.json` files, so this README is ignored, and it does not
descend into `negative/` (no `-R`), so the fixture built never to be accepted is never applied
by a documented bring-up (AD-50). Every object lives in **`agentic-netops-services`**, the
control-plane-owned namespace for `Network`s applied with cluster tooling; none is ever written
into the intent tier's namespace (AD-26). No claim manifest is shipped: the provider claims each
stated VNI itself, before it writes any `Config` (FR-109). Every VLAN is **named** from the
naming band `100–999`, which is never claimed (AD-33).

What each becomes on the devices (data-model.md §13), one priority-20 `Config` per (service,
node) in `agentic-netops-system`, named `<network>.<node>`:

| File | `Network` | leaf01 | leaf02 |
|---|---|---|---|
| `vlan.yaml` | `lab-vlan` | network-instance `vlan-lab-vlan` (type `mac-vrf`, no vxlan-interface, no `bgp-evpn`, no `bgp-vpn`); subinterface `ethernet-1/1.110` type `bridged`, single-tagged vlan-id 110; `/acl/interface[interface-id=ethernet-1/1.110]/interface-ref` | — |
| `macvrf.yaml` | `lab-macvrf` | network-instance `macvrf-lab-macvrf` (type `mac-vrf`); subinterface `ethernet-1/1.120` type `bridged`, vlan-id 120; `vxlan0.10120` type `bridged`, ingress vni 10120, egress source-ip `use-system-ipv4-address`; `bgp-evpn bgp-instance 1` evi 10120, ecmp 8; `bgp-vpn bgp-instance 1` import/export `target:65000:10120`; its interface-ref | the same |
| `ipvrf.yaml` | `lab-ipvrf-a` | network-instance `ipvrf-lab-ipvrf-a` (type `ip-vrf`); subinterface `ethernet-1/1.130` type `routed`, vlan-id 130, `10.130.1.1/24`, `2001:db8:130:1::1/64`; `vxlan0.10130` type `routed`, ingress vni 10130; `bgp-evpn bgp-instance 1` evi 10130 (interface-less Type-5); `bgp-vpn` `target:65000:10130`; its interface-ref | the same on `ethernet-1/1.130` with `10.130.2.1/24`, `2001:db8:130:2::1/64` |
| `ipvrf-isolated.yaml` | `lab-ipvrf-b` | network-instance `ipvrf-lab-ipvrf-b`; `ethernet-1/1.140` routed, `10.140.1.1/24`, `2001:db8:140:1::1/64`; `vxlan0.10140`; evi 10140; `target:65000:10140` | `ethernet-1/1.140` with `10.140.2.1/24`, `2001:db8:140:2::1/64` |
| `macvrf-with-acl.yaml` | `lab-macvrf-acl` | network-instance `macvrf-lab-macvrf-acl` (type `mac-vrf`); subinterface `ethernet-1/1.150` type `bridged`, vlan-id 150; `vxlan0.10150`; evi 10150; `target:65000:10150`; its interface-ref — and, in the **same** `Config`, filter `acl-lab-macvrf-acl-ingress` type `ipv4` (statistics-per-entry, entries 100 / 200 / 300 at the operator's priorities, default `accept` at 65535) bound `input` on `ethernet-1/1.150` | the same |
| `acl-standalone.yaml` | `lab-acl` | only filter `acl-lab-acl-ingress` type `ipv6` (entries 10, 20, default `accept` at 65535) and its `input` binding on `ethernet-1/1.110` — the subinterface `lab-vlan` creates, whose interface-ref `lab-vlan`'s `Config` writes; no subinterface, network-instance or interface-ref of its own (AD-68) | — |

An `ip-vrf`'s routed subinterfaces carry the first host address of its declared prefixes: one
prefix per attachment and family, assigned in (node, port, vlan) order — or a single prefix that
every attachment is a gateway of (docs/decisions/live-findings.md,
`2026-09-21-routed-attachment-address`). The two `ip-vrf`s are isolated: distinct L3VNIs and
route targets, so neither learns the other's prefixes.

Access lists (US5): the filter name is `acl-<network>-<stage>`, each rule's priority is its entry
sequence-id unchanged (ascending, first match wins), and a declared `defaultAction` renders the
terminal match-all entry at 65535 — without one, unmatched traffic is accepted by the device's own
default. `lab-acl` binds a subinterface another `Network` owns, so it is applied after `lab-vlan`
and removed before it.

The port-level leaves (`/interface[name=ethernet-1/1]/admin-state`, `vlan-tagging`, `mtu`) and
`irb0`'s `admin-state` are never a service's: the fabric `Config` renders them at priority 10
(AD-68).

`negative/vlan-unclaimed-band.yaml` — `lab-vlan-unclaimed`, VLAN 1500 in the allocation band
`1000–4000` with no claim: refused by the provider's claim gate with
`Accepted=False/AllocationConflict` naming VLAN 1500 and both bands, zero `Config`s and zero
claims. Applied only by its own path, by `make test-provider-claims` (T172).
