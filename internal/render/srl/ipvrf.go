package srl

import (
	"fmt"

	"github.com/mairp/agentic-netops-srl/internal/model"
)

// renderIPVRF builds the network-instance ipvrf-<serviceId> of an `ip-vrf` or
// of a mac-vrf's gateway: type ip-vrf, its routed members (routed
// subinterfaces carrying the attachment addresses, or irb0.<vlan>), the routed
// vxlan0.<l3vni> member and the interface-less EVPN instance (bgp-evpn
// bgp-instance 1, evi := l3vni, with no interface-ful construct) and bgp-vpn
// bgp-instance 1 with explicit route targets. Declared prefixes are advertised
// in Type-5 routes because they are in the routed instance's route table — no
// redistribution, no policy, no network statement (Rule 11,
// evidence/02-evpn-constructs.md §4.2).
func renderIPVRF(ni *model.NetworkInstance) (container, error) {
	if ni.VXLANInterface == "" || ni.EVPN == nil || ni.BGPVPN == nil {
		return nil, fmt.Errorf("ip-vrf %s: needs its routed vxlan-interface, EVPN and BGP-VPN instances", ni.Name)
	}
	if ni.ProtectAnycastGWMAC {
		return nil, fmt.Errorf("ip-vrf %s: protect-anycast-gw-mac is a mac-vrf bridge-table setting", ni.Name)
	}
	e := renderInstanceBase(ni)
	renderOverlay(e, ni)
	return e, nil
}
