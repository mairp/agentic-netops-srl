package verify

// The ip-vrf applied-side read-back (T058; data-model.md §13 "Read-back per
// construct", ip-vrf row; FR-100, CR-001). It also reads the routed half of a
// mac-vrf with an anycast gateway (its ipvrf-<id> instance); the gateway's own
// IRB and anycast state are T116's (internal/verify/gateway.go).
//
// On every node: the routed network-instance and every member interface up
// with no oper-down-reason, each of its routed access-port subinterfaces up,
// the routed vxlan-interface as a member and on the tunnel, the EVPN instance
// oper-state, the device's own RD / RT origins, and the instance's prefixes in
// ITS OWN route table, one route per prefix:
//
//   - the prefixes checked are the instance's declared prefixes
//     (spec.routers[].prefixes, ServiceInput.Prefixes) together with the
//     subnets the service attaches to it — each routed subinterface's and IRB
//     subinterface's addresses, masked to their prefix;
//   - a prefix attached on THIS leaf is local: route[<prefix>][route-type=local]/active == true;
//   - a prefix attached only on OTHER leaves of the service is remote — it can
//     only reach this leaf as an EVPN Type-5 route for this service's L3VNI:
//     route[<prefix>][route-type=bgp-evpn]/active == true (RoutesMissing when not);
//   - a declared prefix attached on no leaf is present and active under any
//     route type (RoutesMissing when not).
//
// Every read is keyed by the instance name and the prefix; no route count,
// route-summary or received-routes leaf is read.

import (
	"fmt"
	"net/netip"
	"sort"

	"github.com/mairp/agentic-netops-srl/internal/model"
)

// ipvrfExpectations are the ip-vrf leaves of instance ni on node n.
func ipvrfExpectations(m *model.ServiceModel, n *model.ServiceNode, ni *model.NetworkInstance, declared []string) []StateExpectation {
	out := instanceExpectations(ni)
	out = append(out, subinterfaceExpectations(n, ni)...)
	out = append(out, overlayExpectations(ni, vxlanOf(n, ni))...)

	local := map[string]bool{}
	for _, p := range attachedPrefixes(n, ni) {
		local[p] = true
	}
	remote := map[string]bool{}
	for i := range m.Nodes {
		o := &m.Nodes[i]
		if o.Node == n.Node {
			continue
		}
		for j := range o.NetworkInstances {
			if o.NetworkInstances[j].Name == ni.Name {
				for _, p := range attachedPrefixes(o, &o.NetworkInstances[j]) {
					remote[p] = true
				}
			}
		}
	}
	all := map[string]bool{}
	for p := range local {
		all[p] = true
	}
	for p := range remote {
		all[p] = true
	}
	for _, d := range declared {
		all[canonicalPrefix(d)] = true
	}
	prefixes := make([]string, 0, len(all))
	for p := range all {
		prefixes = append(prefixes, p)
	}
	sort.Strings(prefixes)

	for _, p := range prefixes {
		switch {
		case local[p]:
			out = append(out, StateExpectation{Check: CheckLocalPrefixRoute,
				What: fmt.Sprintf("%s local prefix %s", ni.Name, p),
				Path: InstanceRouteActivePath(ni.Name, p, RouteTypeLocal), Want: LeafTrue})
		case remote[p]:
			out = append(out, StateExpectation{Check: CheckRemotePrefixRoute,
				What: fmt.Sprintf("%s remote prefix %s (attached on %s)", ni.Name, p, attachedOn(m, n.Node, ni.Name, p)),
				Path: InstanceRouteActivePath(ni.Name, p, RouteTypeBGPEVPN), Want: LeafTrue})
		default:
			out = append(out, StateExpectation{Check: CheckRemotePrefixRoute,
				What: fmt.Sprintf("%s declared prefix %s (attached on no leaf of the service)", ni.Name, p),
				Path: InstanceRouteActivePath(ni.Name, p, ""), Want: LeafTrue})
		}
	}
	return out
}

// attachedPrefixes are the subnets of every routed and IRB subinterface of
// node n that is a member of ni, masked, in canonical form.
func attachedPrefixes(n *model.ServiceNode, ni *model.NetworkInstance) []string {
	var out []string
	add := func(addrs []string) {
		for _, a := range addrs {
			out = append(out, canonicalPrefix(a))
		}
	}
	for _, s := range n.Subinterfaces {
		if s.Type == model.Routed && containsString(ni.Interfaces, s.Name()) {
			add(s.IPv4)
			add(s.IPv6)
		}
	}
	for _, irb := range n.IRB {
		if containsString(ni.Interfaces, irb.Name()) {
			add(irb.IPv4)
			add(irb.IPv6)
		}
	}
	return out
}

// attachedOn names the other nodes of the service that attach prefix p to ni.
func attachedOn(m *model.ServiceModel, self, ni, p string) string {
	var on []string
	for i := range m.Nodes {
		o := &m.Nodes[i]
		if o.Node == self {
			continue
		}
		for j := range o.NetworkInstances {
			if o.NetworkInstances[j].Name != ni {
				continue
			}
			for _, q := range attachedPrefixes(o, &o.NetworkInstances[j]) {
				if q == p {
					on = append(on, o.Node)
					break
				}
			}
		}
	}
	sort.Strings(on)
	return fmt.Sprint(on)
}

// canonicalPrefix is an address-with-length masked to its prefix in the
// device's own textual form (10.10.0.1/24 → 10.10.0.0/24,
// 2001:db8:10::1/64 → 2001:db8:10::/64); anything unparseable is kept as is.
func canonicalPrefix(s string) string {
	p, err := netip.ParsePrefix(s)
	if err != nil {
		return s
	}
	return p.Masked().String()
}

// InstanceRouteActivePath is
// /network-instance[name=<ni>]/route-table/<ipv4|ipv6>-unicast/route[<ipv4|ipv6>-prefix=<p>][route-type=<t>]/active;
// an empty route type leaves that key unspecified (any route type), and the
// route's other keys (route-owner, id, origin-network-instance) match any instance.
func InstanceRouteActivePath(ni, prefix, routeType string) string {
	fam, key := "ipv4-unicast", "ipv4-prefix"
	if p, err := netip.ParsePrefix(prefix); err == nil && p.Addr().Is6() {
		fam, key = "ipv6-unicast", "ipv6-prefix"
	}
	path := niPath(ni) + "/route-table/" + fam + "/route[" + key + "=" + prefix + "]"
	if routeType != "" {
		path += "[route-type=" + routeType + "]"
	}
	return path + "/active"
}
