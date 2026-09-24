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
