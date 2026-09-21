package model

import (
	"sort"
	"strconv"
	"strings"
)

// WritePaths enumerates, as concrete native gNMI paths with key values, every
// schema node the fabric Config of this node writes. It is built from what the
// model actually populates, so the path register's guard (pkg/register, T022)
// fails on any construct that would write a path the register does not cover
// (FR-017). The renderer (T039) renders exactly these.
func (n *FabricNode) WritePaths() []string {
	w := &pathSet{}
	ni := elem("network-instance", "name", DefaultNetworkInstance)
	for _, p := range n.FabricPorts {
		ifc := elem("interface", "name", p.Name)
		w.add(ifc, "admin-state")
		if p.MTU != 0 {
			w.add(ifc, "mtu")
		}
		sub := ifc + elem("subinterface", "index", "0")
		w.add(sub, "admin-state")
		if p.IPMTU != 0 {
			w.add(sub, "ip-mtu")
		}
		w.add(sub, "ipv4/admin-state")
		w.add(sub, "ipv4"+elem("address", "ip-prefix", p.IPv4))
		w.add(sub, "ipv4/unnumbered/admin-state")
		if p.IPv6 != "" {
			w.add(sub, "ipv6/admin-state")
			w.add(sub, "ipv6"+elem("address", "ip-prefix", p.IPv6))
		}
		w.add(ni, elem("interface", "name", SubinterfaceName(p.Name, 0)))
	}
	// system0 loopback: the VTEP source (IPv4 only) and the router-id.
	sys := elem("interface", "name", SystemInterface)
	w.add(sys, "admin-state")
	ssub := sys + elem("subinterface", "index", "0")
	w.add(ssub, "admin-state")
	w.add(ssub, "ipv4/admin-state")
	w.add(ssub, "ipv4"+elem("address", "ip-prefix", n.SystemIPv4))
	w.add(ssub, "ipv4/unnumbered/admin-state")
	if n.SystemIPv6 != "" {
		w.add(ssub, "ipv6/admin-state")
		w.add(ssub, "ipv6"+elem("address", "ip-prefix", n.SystemIPv6))
	}
	w.add(ni, elem("interface", "name", SubinterfaceName(SystemInterface, 0)))

	// Port-level leaves of every access port, and irb0's own admin-state (AD-68).
	for _, p := range n.AccessPorts {
		ifc := elem("interface", "name", p.Name)
		w.add(ifc, "admin-state")
		w.add(ifc, "vlan-tagging")
	}
	if n.IRBEnabled {
		w.add(elem("interface", "name", IRBInterface), "admin-state")
	}
	// The tunnel-interface itself (leaves only); its vxlan-interfaces are the services'.
	if n.VXLANTunnel {
		w.add(elem("tunnel-interface", "name", TunnelInterface), "")
	}

	w.add(ni, "type")
	w.add(ni, "admin-state")

	// Underlay export/import policy advertising the system loopbacks.
	for _, pfx := range n.LoopbackBlock {
		w.add("/routing-policy"+elem("prefix-set", "name", LoopbackPrefixSet),
			elem("prefix", "ip-prefix", pfx)+"[mask-length-range="+MaskLengthRange(pfx)+"]")
	}
	st := "/routing-policy" + elem("policy", "name", LoopbackPolicy) + elem("statement", "name", "1")
	w.add(st, "match/prefix/prefix-set")
	w.add(st, "action/policy-result")

	bgp := ni + "/protocols/bgp"
	w.add(bgp, "admin-state")
	w.add(bgp, "autonomous-system")
	w.add(bgp, "router-id")
	fams := n.BGP.Families()
	for _, f := range fams {
		w.add(bgp+elem("afi-safi", "afi-safi-name", f), "admin-state")
	}
	if n.BGP.InterASVPN != nil {
		w.add(bgp+elem("afi-safi", "afi-safi-name", AFIEVPN), "evpn/inter-as-vpn")
	}
	for _, g := range n.BGP.Groups() {
		gp := bgp + elem("group", "group-name", g)
		if g == OverlayGroup {
			w.add(gp, "peer-as")
			w.add(gp, "local-as/as-number")
			if n.BGP.RouteReflectorClient != nil {
				w.add(gp, "route-reflector/client")
			}
		} else {
			w.add(gp, "export-policy")
			w.add(gp, "import-policy")
			if n.BGP.AllowOwnAS > 0 {
				w.add(gp, "as-path-options/allow-own-as")
			}
		}
		for _, f := range fams {
			w.add(gp+elem("afi-safi", "afi-safi-name", f), "admin-state")
		}
	}
	for _, nb := range n.BGP.Neighbors {
		p := bgp + elem("neighbor", "peer-address", nb.PeerAddress)
		w.add(p, "peer-group")
		if nb.PeerAS != 0 {
			w.add(p, "peer-as")
		}
		if nb.LocalAddress != "" {
			w.add(p, "transport/local-address")
		}
	}
	return w.sorted()
}

// WritePaths enumerates every schema node the service Config of this node
// writes (data-model.md §13 "Exact native paths"). A service writes nothing
// above its own subinterface[index] (AD-68).
func (n *ServiceNode) WritePaths() []string {
	w := &pathSet{}
	for _, s := range n.Subinterfaces {
		sub := elem("interface", "name", s.Port) + elem("subinterface", "index", u(s.Index))
		w.add(sub, "type")
		w.add(sub, "admin-state")
		if s.VLAN != 0 {
			w.add(sub, "vlan/encap/single-tagged/vlan-id")
		}
		for _, a := range s.IPv4 {
			w.add(sub, "ipv4/admin-state")
			w.add(sub, "ipv4"+elem("address", "ip-prefix", a))
		}
		for _, a := range s.IPv6 {
			w.add(sub, "ipv6/admin-state")
			w.add(sub, "ipv6"+elem("address", "ip-prefix", a))
		}
	}
	for _, irb := range n.IRB {
		sub := elem("interface", "name", IRBInterface) + elem("subinterface", "index", u(irb.Index))
		w.add(sub, "admin-state")
		w.add(sub, "anycast-gw/virtual-router-id")
		w.add(sub, "ip-mtu")
		if len(irb.IPv4) > 0 {
			w.add(sub, "ipv4/admin-state")
			for _, a := range irb.IPv4 {
				addr := sub + "/ipv4" + elem("address", "ip-prefix", a)
				w.add(addr, "anycast-gw")
				w.add(addr, "primary")
			}
			w.add(sub, "ipv4/arp/learn-unsolicited")
			w.add(sub, "ipv4/arp/host-route"+elem("populate", "route-type", "dynamic"))
			w.add(sub, "ipv4/arp/evpn"+elem("advertise", "route-type", "dynamic"))
		}
		if len(irb.IPv6) > 0 {
			w.add(sub, "ipv6/admin-state")
			for _, a := range irb.IPv6 {
				w.add(sub+"/ipv6"+elem("address", "ip-prefix", a), "anycast-gw")
			}
			w.add(sub, "ipv6/neighbor-discovery/learn-unsolicited")
			w.add(sub, "ipv6/neighbor-discovery/host-route"+elem("populate", "route-type", "dynamic"))
			w.add(sub, "ipv6/neighbor-discovery/evpn"+elem("advertise", "route-type", "dynamic"))
		}
	}
	for _, vx := range n.VXLANInterfaces {
		p := elem("tunnel-interface", "name", TunnelInterface) + elem("vxlan-interface", "index", u(vx.Index))
		w.add(p, "type")
		w.add(p, "ingress/vni")
		if vx.EgressSystemIP {
			w.add(p, "egress/source-ip")
		}
	}
	for _, ni := range n.NetworkInstances {
		p := elem("network-instance", "name", ni.Name)
		w.add(p, "type")
		w.add(p, "admin-state")
		if ni.Description != "" {
			w.add(p, "description")
		}
		for _, i := range ni.Interfaces {
			w.add(p, elem("interface", "name", i)[1:])
		}
		if ni.VXLANInterface != "" {
			w.add(p, elem("vxlan-interface", "name", ni.VXLANInterface)[1:])
		}
		if ni.ProtectAnycastGWMAC {
			w.add(p, "bridge-table/protect-anycast-gw-mac")
		}
		if ni.EVPN != nil {
			e := p + "/protocols/bgp-evpn" + elem("bgp-instance", "id", u(ni.EVPN.ID))
			for _, leaf := range []string{"admin-state", "encapsulation-type", "vxlan-interface", "evi", "ecmp"} {
				w.add(e, leaf)
			}
		}
		if ni.BGPVPN != nil {
			v := p + "/protocols/bgp-vpn" + elem("bgp-instance", "id", u(ni.BGPVPN.ID))
			w.add(v, "route-target/export-rt")
			w.add(v, "route-target/import-rt")
		}
	}
	for _, f := range n.ACLFilters {
		fp := "/acl" + elem("acl-filter", "name", f.Name) + "[type=" + string(f.Type) + "]"
		w.add(fp, "description")
		if f.StatisticsPerEntry {
			w.add(fp, "statistics-per-entry")
		}
		if f.SubinterfaceSpecific != "" {
			w.add(fp, "subinterface-specific")
		}
		for _, e := range f.Entries {
			ep := fp + elem("entry", "sequence-id", u(e.SequenceID))
			if e.Description != "" {
				w.add(ep, "description")
			}
			w.add(ep, "action/"+string(e.Action))
			fam := string(e.Family)
			if e.Protocol != "" {
				if e.Family == FamilyIPv4 {
					w.add(ep, "match/ipv4/protocol")
				} else {
					w.add(ep, "match/ipv6/next-header")
				}
			}
			if e.SourcePrefix != "" {
				w.add(ep, "match/"+fam+"/source-ip/prefix")
			}
			if e.DestinationPrefix != "" {
				w.add(ep, "match/"+fam+"/destination-ip/prefix")
			}
			addPort(w, ep, "source-port", e.SourcePort)
			addPort(w, ep, "destination-port", e.DestinationPort)
		}
	}
	for _, ai := range n.ACLInterfaces {
		ip := "/acl" + elem("interface", "interface-id", ai.InterfaceID)
		if ai.Ref != nil {
			w.add(ip, "interface-ref/interface")
			w.add(ip, "interface-ref/subinterface")
		}
		for _, r := range ai.Input {
			w.add(ip, "input"+elem("acl-filter", "name", r.Name)+"[type="+string(r.Type)+"]")
		}
		for _, r := range ai.Output {
			w.add(ip, "output"+elem("acl-filter", "name", r.Name)+"[type="+string(r.Type)+"]")
		}
	}
	return w.sorted()
}

func addPort(w *pathSet, entry, which string, pm *PortMatch) {
	if pm == nil {
		return
	}
	base := entry + "/match/transport/" + which
	if pm.Hi != 0 {
		w.add(base, "range/start")
		w.add(base, "range/end")
		return
	}
	w.add(base, "operator")
	w.add(base, "value")
}

type pathSet struct{ m map[string]bool }

func (p *pathSet) add(prefix, rest string) {
	if p.m == nil {
		p.m = map[string]bool{}
	}
	if rest != "" && !strings.HasPrefix(rest, "/") {
		rest = "/" + rest
	}
	p.m[prefix+rest] = true
}

func (p *pathSet) sorted() []string {
	out := make([]string, 0, len(p.m))
	for k := range p.m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// elem renders one path element with an optional key: `/name[key=value]`.
func elem(name, key, value string) string {
	if key == "" {
		return "/" + name
	}
	return "/" + name + "[" + key + "=" + value + "]"
}

func u(v uint32) string { return strconv.FormatUint(uint64(v), 10) }
