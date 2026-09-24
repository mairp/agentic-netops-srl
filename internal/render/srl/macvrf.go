package srl

import (
	"fmt"

	"github.com/mairp/agentic-netops-srl/internal/model"
)

// renderMACVRF builds the network-instance macvrf-<serviceId> of a `mac-vrf`:
// the bridge domain of vlan.go plus its overlay — the bridged vxlan0.<l2vni>
// member, bgp-evpn bgp-instance 1 with evi := l2vni and bgp-vpn bgp-instance 1
// with explicit route targets (vxlan_service.go) — and, with an anycast
// gateway, `bridge-table protect-anycast-gw-mac true` (Rule 11).
func renderMACVRF(ni *model.NetworkInstance) (container, error) {
	if ni.EVPN == nil || ni.BGPVPN == nil {
		return nil, fmt.Errorf("mac-vrf %s: a vxlan-interface without its EVPN and BGP-VPN instances", ni.Name)
	}
	e := renderInstanceBase(ni)
	renderOverlay(e, ni)
	if ni.ProtectAnycastGWMAC {
		e["bridge-table"] = container{"protect-anycast-gw-mac": true}
	}
	return e, nil
}

// renderIRBSubinterface builds irb0.<vlan>, the anycast gateway of a mac-vrf
// with integrated routing (Rule 11, evidence/02-evpn-constructs.md §5): its
// admin-state, the anycast-gw presence container with the fabric-constant
// virtual-router-id (present before any address is marked anycast), the
// explicit ip-mtu, and per declared family only: each address with
// `anycast-gw true` (IPv4 also `primary`, an empty leaf, [null] in JSON_IETF as
// G12 observed), unsolicited neighbour learning, host-route population and
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
			addrs.add(container{"ip-prefix": a, "anycast-gw": true, "primary": leafList{nil}})
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
