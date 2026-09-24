package srl

// The anycast gateway of a `mac-vrf` (T116; FR-032, FR-100, CR-010;
// contracts/reconciliation.md Rule 11; data-model.md §13, the `mac-vrf` +
// gateway row). The gateway is a property of the mac-vrf, never a fifth
// construct: the model (internal/model/service.go gateway()) makes irb0.<vlan>
// a member of both the bridged instance macvrf-<id> and the routed one
// ipvrf-<id>; subinterface.go places the entry rendered here under irb0.
//
// Only the address families the gateway declares are rendered: a gateway
// naming only IPv4 renders no ipv6 container at all, and the reverse — an
// unrequested family is never added (FR-032). The read-back reads the same
// families and no other (internal/verify/gateway.go).
//
// `primary` is not rendered. The pinned device-configuration layer cannot carry
// the empty leaf: `"primary": [null]` (the G12-observed JSON_IETF form) and
// `{}` are refused by the device's parser through the layer, and `null`, which
// the layer accepts, states no value — observed live 2026-09-24, docs/decisions/live-findings.md
// `2026-09-24-irb-primary`. A gateway declares one address per family, and the
// device selects the numerically lowest (here the only) IPv4 address of a
// subinterface as its primary address by default, so leaving the leaf out
// renders the same device behaviour.

import "github.com/mairp/agentic-netops-srl/internal/model"

// renderIRBSubinterface builds irb0.<vlan>, the anycast gateway of a mac-vrf
// with integrated routing (Rule 11, evidence/02-evpn-constructs.md §5): its
// admin-state, the anycast-gw presence container with the fabric-constant
// virtual-router-id (present before any address is marked anycast), the
// explicit ip-mtu, and per declared family only: each address with
// `anycast-gw true`, unsolicited neighbour learning, host-route population and
// EVPN advertisement of dynamic entries — what makes a distributed gateway
// work at all. arp / neighbor-discovery are augmented in by
// srl_nokia-interfaces-nbr and their evpn container by
// srl_nokia-interfaces-nbr-evpn, so they are module-qualified. irb0's own
// admin-state is the fabric Config's (AD-68).
func renderIRBSubinterface(s model.IRBSubinterface) container {
	e := container{
		"index":       s.Index,
		"admin-state": adminState(true),
		"anycast-gw":  container{"virtual-router-id": s.VirtualRouterID},
		"ip-mtu":      s.IPMTU,
	}
	dynamic := func() *list { return newList("route-type").add(container{"route-type": "dynamic"}) }
	if len(s.IPv4) > 0 {
		addrs := newList("ip-prefix")
		for _, a := range s.IPv4 {
			addrs.add(container{"ip-prefix": a, "anycast-gw": true})
		}
		e["ipv4"] = container{
			"admin-state": adminState(true),
			"address":     addrs,
			// stated for the validator, as on every IPv4 subinterface
			// (subinterface.go renderSubinterface); it also satisfies the
			// host-route populate must on an IPv4 irb subinterface.
			"unnumbered": container{"admin-state": adminState(false)},
			modInterfacesNbr + ":arp": container{
				"learn-unsolicited":            true,
				"host-route":                   container{"populate": dynamic()},
				modInterfacesNbrEVPN + ":evpn": container{"advertise": dynamic()},
			},
		}
	}
	if len(s.IPv6) > 0 {
		addrs := newList("ip-prefix")
		for _, a := range s.IPv6 {
			addrs.add(container{"ip-prefix": a, "anycast-gw": true})
		}
		e["ipv6"] = container{
			"admin-state": adminState(true),
			"address":     addrs,
			modInterfacesNbr + ":neighbor-discovery": container{
				// global: the anycast addresses are global unicast (an
				// anycast-gw address may not be link-local).
				"learn-unsolicited":            "global",
				"host-route":                   container{"populate": dynamic()},
				modInterfacesNbrEVPN + ":evpn": container{"advertise": dynamic()},
			},
		}
	}
	return e
}
