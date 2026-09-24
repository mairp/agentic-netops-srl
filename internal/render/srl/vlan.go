package srl

import "github.com/mairp/agentic-netops-srl/internal/model"

// renderInstanceBase builds what every service network-instance carries: its
// name (vlan-/macvrf-/ipvrf-<serviceId>), the device's own type identity
// (srl_nokia-network-instance:mac-vrf | ip-vrf, G12-observed
// module-qualified), admin-state enable, the description and its member
// subinterfaces (`<port>.<idx>`, `irb0.<vlan>`).
func renderInstanceBase(ni *model.NetworkInstance) container {
	e := container{
		"name":        ni.Name,
		"type":        identityref(modNetworkInstance, string(ni.Type)),
		"admin-state": adminState(true),
	}
	if ni.Description != "" {
		e["description"] = ni.Description
	}
	if len(ni.Interfaces) > 0 {
		ifs := newList("name")
		for _, i := range ni.Interfaces {
			ifs.add(container{"name": i})
		}
		e["interface"] = ifs
	}
	return e
}

// renderVLANInstance builds the bridge domain of a `vlan`: a network-instance
// vlan-<serviceId> of type mac-vrf with its bridged subinterfaces and never a
// vxlan-interface, an EVPN instance or a route target — a `vlan` has no
// overlay and is held to no overlay evidence (Rule 11, data-model.md §13).
func renderVLANInstance(ni *model.NetworkInstance) container {
	return renderInstanceBase(ni)
}
