package srl

import "github.com/mairp/agentic-netops-srl/internal/model"

// renderInterfaces builds /interface for the fabric Config of one node
// (data-model.md §3a `spec.mtu`, `spec.inventory`, `spec.maintenance[]`, §13):
//
//   - every fabric port: admin-state (disable while spec.maintenance[] names
//     it, AD-06), mtu = portMTU (9412), and routed subinterface 0 with
//     ip-mtu = underlayIPMTU (9398), its claimed IPv4 /31 and derived IPv6 /127;
//   - system0 and system0.0 with the IPv4 /32 — the VTEP source and router-id,
//     the only tunnel source the platform supports — and the derived IPv6 /128;
//   - every access port: admin-state (enable, or disable from maintenance[]),
//     vlan-tagging from the declared mode (untaggedAccessPorts renders false)
//     and mtu = portMTU — the tenant ip-mtu of a service subinterface does not
//     fit under the device default (live finding 2026-09-21-access-port-mtu) —
//     and no subinterface: those are the services' (AD-68);
//   - irb0's own admin-state enable, once, on a leaf only (AD-68).
func renderInterfaces(n *model.FabricNode) *list {
	ifs := newList("name")
	for _, p := range n.FabricPorts {
		e := container{"name": p.Name, "admin-state": adminState(p.Enabled)}
		if p.MTU != 0 {
			e["mtu"] = p.MTU
		}
		sub := container{"index": uint32(0), "admin-state": adminState(true)}
		if p.IPMTU != 0 {
			sub["ip-mtu"] = p.IPMTU
		}
		addressFamilies(sub, p.IPv4, p.IPv6)
		e["subinterface"] = newList("index").add(sub)
		ifs.add(e)
	}

	sys := container{"index": uint32(0), "admin-state": adminState(true)}
	addressFamilies(sys, n.SystemIPv4, n.SystemIPv6)
	ifs.add(container{
		"name":         model.SystemInterface,
		"admin-state":  adminState(true),
		"subinterface": newList("index").add(sys),
	})

	for _, p := range n.AccessPorts {
		e := container{
			"name":                               p.Name,
			"admin-state":                        adminState(p.Enabled),
			modInterfacesVLANs + ":vlan-tagging": p.VLANTagging,
		}
		if p.MTU != 0 {
			e["mtu"] = p.MTU
		}
		ifs.add(e)
	}
	if n.IRBEnabled {
		ifs.add(container{"name": model.IRBInterface, "admin-state": adminState(true)})
	}
	return ifs
}

// addressFamilies adds the ipv4 (always) and ipv6 (when derived) containers of
// a routed subinterface. ipv4/ipv6 come from srl_nokia-if-ip by `uses`, so they
// carry no module qualification (evidence/02-evpn-constructs.md §0).
//
// ipv4/unnumbered/admin-state is stated as `disable` although that is the model
// default: every ipv4 address carries the must `../../unnumbered/admin-state !=
// 'enable'`, and the device-configuration layer's validator (data-server v0.0.66,
// the pin at the time, and sdc-lite offline) evaluates it against the absent node rather than the
// default, refusing the address. Observed live against the Targets, pass 37;
// the if-feature ipv4-unnumbered is advertised by all four nodes (G3).
func addressFamilies(sub container, v4, v6 string) {
	sub["ipv4"] = container{
		"admin-state": adminState(true),
		"address":     newList("ip-prefix").add(container{"ip-prefix": v4}),
		"unnumbered":  container{"admin-state": adminState(false)},
	}
	if v6 != "" {
		sub["ipv6"] = container{
			"admin-state": adminState(true),
			"address":     newList("ip-prefix").add(container{"ip-prefix": v6}),
		}
	}
}
