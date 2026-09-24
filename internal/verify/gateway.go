package verify

// The anycast-gateway applied-side read-back of a `mac-vrf` (T116; data-model.md
// §10 AnycastGateway, §13 "Read-back per construct", `mac-vrf` + gateway row;
// FR-032, FR-100, CR-001, CR-010; contracts/reconciliation.md Rule 5).
//
// The bridged half is macvrf.go's and the routed half (the ipvrf-<id> instance,
// irb0.<vlan> as its member, the gateway subnet local in its route table) is
// ipvrf.go's; this file adds, on every node carrying irb0.<vlan> — the leaves
// observed live on SR Linux 25.7.1 (2026-09-24, lab-macvrf-gateway, phase9 brief):
//
//	/interface[name=irb0]/subinterface[index=<vlan>]/oper-state                     == up, oper-down-reason absent
//	/interface[name=irb0]/subinterface[index=<vlan>]/anycast-gw/anycast-gw-mac-origin present (vrid-auto-derived)
//	/interface[name=irb0]/subinterface[index=<vlan>]/<ipv4|ipv6>/address[ip-prefix=<gw>]/status == preferred
//
// per anycast address of a DECLARED family only (the link-local fe80 addresses
// the device also lists are never read, nor is an undeclared family: FR-032).
//
// The EVPN IP-prefix (Type-5) invariant. The gateway subnet is local in
// ipvrf-<id> on every leaf, so the routed instance's route table cannot show the
// Type-5 the other leaves advertise; the EVPN RIB does. On node N, for each
// declared family F whose `ip-vrf.evpn-type5-<F>` the qualification record
// qualifies (ServiceInput.Qualified), and for each OTHER leaf R of the service:
//
//	/network-instance[name=default]/bgp-rib/afi-safi[afi-safi-name=evpn]/evpn/rib-in-out/rib-in-post/
//	    ip-prefix-route[route-distinguisher=<R system0>:<evi>][ip-prefix=<masked gateway subnet>]/used-route == true
//
// on at least one path (the route's other keys — ethernet-tag-id, ip-prefix-length,
// neighbor, path-id — match any instance; the second path via the other spine
// reads used-route false). The RD is the one R derives for this instance
// (auto-derived-from-evi, <system0.0 IPv4>:<evi>, the evi being the L3VNI).
// Missing is RoutesMissing naming "EVPN IP-prefix (Type-5) route <subnet> from
// <R> (RD <rd>)": a dual-stack gateway is never Ready on its IPv4 half alone.
// A single-leaf service has no remote leaf and reads no Type-5.

import (
	"fmt"
	"net/netip"

	"github.com/mairp/agentic-netops-srl/internal/model"
)

// Gateway read-back checks.
const (
	// CheckIRBSubinterfaceOperState: irb0.<vlan> up with no oper-down-reason.
	CheckIRBSubinterfaceOperState Check = "irb-subinterface-oper-state"
	// CheckAnycastGateway: the anycast-gw state of irb0.<vlan> reflected by the device.
	CheckAnycastGateway Check = "anycast-gateway"
	// CheckAnycastAddress: a declared anycast address preferred.
	CheckAnycastAddress Check = "anycast-address"
	// CheckType5Route: another leaf's EVPN IP-prefix route for the gateway subnet (RoutesMissing).
	CheckType5Route Check = "evpn-type5-route"
)

// Device vocabulary of the gateway read-back (SR Linux 25.7.1, observed live 2026-09-24).
const (
	// AddressStatusPreferred is an interface address's status once usable.
	AddressStatusPreferred = "preferred"
	// AnycastOriginVRIDAutoDerived is the anycast-gw-mac-origin of a gateway MAC
	// derived from the rendered virtual-router-id (no anycast-gw-mac rendered).
	AnycastOriginVRIDAutoDerived = "vrid-auto-derived"
	// Type5QualificationKey is the qualification record key of a family's
	// Type-5 property, formatted with the family (ipv4 | ipv6).
	Type5QualificationKey = "ip-vrf.evpn-type5-%s"
)

// gatewayExpectations are the anycast-gateway leaves of node n: one set per
// irb0.<vlan> it carries, keyed by the routed instance irb0.<vlan> is a member of.
func gatewayExpectations(m *model.ServiceModel, n *model.ServiceNode, in ServiceInput) ([]StateExpectation, error) {
	var out []StateExpectation
	for _, irb := range n.IRB {
		name := irb.Name()
		out = append(out,
			StateExpectation{Check: CheckIRBSubinterfaceOperState, What: "IRB subinterface " + name,
				Path: SubinterfaceOperStatePath(model.IRBInterface, irb.Index), Want: OperStateUp,
				ReasonPath: SubinterfaceOperDownReasonPath(model.IRBInterface, irb.Index), ReasonAbsent: true},
			StateExpectation{Check: CheckAnycastGateway, What: "anycast gateway of " + name,
				Path: AnycastGWMACOriginPath(model.IRBInterface, irb.Index), Expect: ExpectPresent})
		for _, fam := range []struct {
			name  string
			addrs []string
		}{{"ipv4", irb.IPv4}, {"ipv6", irb.IPv6}} {
			for _, a := range fam.addrs {
				out = append(out, StateExpectation{Check: CheckAnycastAddress,
					What: fmt.Sprintf("anycast address %s of %s", a, name),
					Path: AddressStatusPath(model.IRBInterface, irb.Index, a), Want: AddressStatusPreferred})
			}
		}

		ni := routedInstanceOf(n, name)
		if ni == nil || ni.VXLANInterface == "" {
			continue // no routed half keyed on this node: no Type-5 to expect
		}
		remotes, err := remoteVTEPs(m, n, ni, in.Loopbacks)
		if err != nil {
			return nil, err
		}
		if len(remotes) == 0 {
			continue // a single-leaf service: nothing is advertised to it
		}
		evi := uint32(0)
		if ni.EVPN != nil {
			evi = ni.EVPN.EVI
		} else if vx := vxlanOf(n, ni); vx != nil {
			evi = vx.VNI
		}
		for _, fam := range []struct {
			name  string
			addrs []string
		}{{"ipv4", irb.IPv4}, {"ipv6", irb.IPv6}} {
			if len(fam.addrs) == 0 || !in.qualified(fmt.Sprintf(Type5QualificationKey, fam.name)) {
				continue
			}
			for _, subnet := range uniqueCanonical(fam.addrs) {
				for _, r := range remotes {
					rd := fmt.Sprintf("%s:%d", r.vtep, evi)
					out = append(out, StateExpectation{Check: CheckType5Route,
						What: fmt.Sprintf("EVPN IP-prefix (Type-5) route %s from %s (RD %s)", subnet, r.node, rd),
						Path: Type5UsedRoutePath(rd, subnet), Want: LeafTrue})
				}
			}
		}
	}
	return out, nil
}

// qualified reports whether the record qualifies key; with no record given,
// everything is (admission already refused what the record does not qualify).
func (in ServiceInput) qualified(key string) bool {
	return in.Qualified == nil || in.Qualified(key)
}

// routedInstanceOf is node n's ip-vrf instance that has subinterface name as a member.
func routedInstanceOf(n *model.ServiceNode, name string) *model.NetworkInstance {
	for i := range n.NetworkInstances {
		ni := &n.NetworkInstances[i]
		if ni.Type == model.IPVRF && containsString(ni.Interfaces, name) {
			return ni
		}
	}
	return nil
}

// uniqueCanonical masks each address to its subnet, in order, without repeats.
func uniqueCanonical(addrs []string) []string {
	var out []string
	seen := map[string]bool{}
	for _, a := range addrs {
		p := canonicalPrefix(a)
		if !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	return out
}

// AnycastGWMACOriginPath is /interface[name=<if>]/subinterface[index=<i>]/anycast-gw/anycast-gw-mac-origin.
func AnycastGWMACOriginPath(ifc string, index uint32) string {
	return fmt.Sprintf("/interface[name=%s]/subinterface[index=%d]/anycast-gw/anycast-gw-mac-origin", ifc, index)
}

// AddressStatusPath is /interface[name=<if>]/subinterface[index=<i>]/<ipv4|ipv6>/address[ip-prefix=<addr>]/status;
// the family follows the address.
func AddressStatusPath(ifc string, index uint32, addr string) string {
	fam := "ipv4"
	if isIPv6(addr) {
		fam = "ipv6"
	}
	return fmt.Sprintf("/interface[name=%s]/subinterface[index=%d]/%s/address[ip-prefix=%s]/status", ifc, index, fam, addr)
}

// EVPNIPPrefixRoutePath is the EVPN RIB's post-policy IP-prefix (Type-5) route list of the
// default network-instance: /network-instance[name=default]/bgp-rib/afi-safi[afi-safi-name=evpn]/evpn/rib-in-out/rib-in-post/ip-prefix-route.
const EVPNIPPrefixRoutePath = "/network-instance[name=" + model.DefaultNetworkInstance + "]/bgp-rib/afi-safi[afi-safi-name=evpn]/evpn/rib-in-out/rib-in-post/ip-prefix-route"

// Type5UsedRoutePath is …/ip-prefix-route[route-distinguisher=<rd>][ip-prefix=<subnet>]/used-route;
// the route's other keys (ethernet-tag-id, ip-prefix-length, neighbor, path-id) match any instance.
func Type5UsedRoutePath(rd, subnet string) string {
	return EVPNIPPrefixRoutePath + "[route-distinguisher=" + rd + "][ip-prefix=" + subnet + "]/used-route"
}

// isIPv6 reports whether an address (with or without a prefix length) is IPv6.
func isIPv6(addr string) bool {
	if p, err := netip.ParsePrefix(addr); err == nil {
		return p.Addr().Is6()
	}
	a, err := netip.ParseAddr(addr)
	return err == nil && a.Is6()
}
