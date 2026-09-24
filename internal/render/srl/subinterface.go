package srl

import "github.com/mairp/agentic-netops-srl/internal/model"

// renderServiceInterfaces builds /interface for a service Config (data-model.md
// §13, AD-68): one entry per access port carrying only its name and the
// subinterface[index] entries this service owns, and irb0 carrying only its
// name and this service's irb0.<vlan>. The port-level leaves (admin-state,
// vlan-tagging, mtu) and irb0's own admin-state are the fabric Config's and
// are never rendered here: the first leaf a service writes on an interface is
// under subinterface[index]. It returns nil when the node owns no
// subinterface.
func renderServiceInterfaces(n *model.ServiceNode) *list {
	ports := map[string]*list{}
	var order []string
	for _, s := range n.Subinterfaces {
		l, ok := ports[s.Port]
		if !ok {
			l = newList("index")
			ports[s.Port] = l
			order = append(order, s.Port)
		}
		l.add(renderSubinterface(s))
	}
	ifs := newList("name")
	for _, p := range order {
		ifs.add(container{"name": p, "subinterface": ports[p]})
	}
	if len(n.IRB) > 0 {
		irb := newList("index")
		for _, s := range n.IRB {
			irb.add(renderIRBSubinterface(s))
		}
		ifs.add(container{"name": model.IRBInterface, "subinterface": irb})
	}
	if len(ifs.entries) == 0 {
		return nil
	}
	return ifs
}

// renderSubinterface builds one service-owned subinterface of an access port:
// its type (bridged for a `vlan` / `mac-vrf`, routed for an `ip-vrf`; the
// identities are srl_nokia-interfaces', G12-observed module-qualified), its
// admin-state, the single-tagged vlan-id (index := vlan; an untagged
// subinterface 0 carries no vlan container) and, on a routed subinterface,
// the tenant ip-mtu, on a bridged one the bridged l2-mtu (data-model.md §20;
// each device default is below the tenant MTU), and
// the attachment addresses of each declared family — the prefixes an ip-vrf
// advertises in its interface-less Type-5 routes because they are in its route
// table (Rule 11). vlan comes from srl_nokia-interfaces-vlans by augment and is
// module-qualified; ipv4/ipv6 come from srl_nokia-if-ip by `uses` and are not.
// ipv4/unnumbered/admin-state is stated `disable` beside an IPv4 address for
// the reason the fabric's routed subinterfaces state it (interfaces.go
// addressFamilies): the validator evaluates the address's must against the
// absent node rather than the default.
func renderSubinterface(s model.Subinterface) container {
	e := container{
		"index":       s.Index,
		"type":        identityref(modInterfaces, string(s.Type)),
		"admin-state": adminState(true),
	}
	if s.VLAN != 0 {
		e[modInterfacesVLANs+":vlan"] = container{
			"encap": container{"single-tagged": container{"vlan-id": s.VLAN}},
		}
	}
	if s.IPMTU != 0 {
		e["ip-mtu"] = s.IPMTU
	}
	if s.L2MTU != 0 {
		e["l2-mtu"] = s.L2MTU
	}
	if len(s.IPv4) > 0 {
		e["ipv4"] = container{
			"admin-state": adminState(true),
			"address":     prefixes(s.IPv4),
			"unnumbered":  container{"admin-state": adminState(false)},
		}
	}
	if len(s.IPv6) > 0 {
		e["ipv6"] = container{"admin-state": adminState(true), "address": prefixes(s.IPv6)}
	}
	return e
}

func prefixes(ps []string) *list {
	l := newList("ip-prefix")
	for _, p := range ps {
		l.add(container{"ip-prefix": p})
	}
	return l
}
