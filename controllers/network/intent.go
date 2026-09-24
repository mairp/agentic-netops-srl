package network

// The Network spec → canonical service input translation (T059; contracts/network-spec.md §2,
// §5; data-model.md §13): the construct is decided by which lists are present, never inferred
// from whether an overlay field is set (D-11); every attachment resolves through the Fabric's
// site inventory to exactly one (node, port, vlan); the route-target constant is the Fabric's
// spec.overlay.fabricASN; VLANs and VNIs are the object's own, their claims having been bound
// by the claim gate (claims.go) before this runs.

import (
	"fmt"
	"net/netip"
	"sort"
	"strconv"
	"strings"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/model"
)

// Metadata keys the provider READS on a Network (it writes none of them, FR-101).
const (
	// AnnotationTenant is the translator's tenant annotation, carried into the access-list
	// description only.
	AnnotationTenant = "agentic-netops.io/tenant"
	// tierNamePrefix is the prefix of a tier-submitted Network's name, migr-<serviceId>
	// (kuid-claim-profiles.md §5): the service identifier every device name derives from is
	// the name without it.
	tierNamePrefix = "migr-"
)

// attachment is one resolved attachment: a node, a port and a VLAN (0 = untagged).
type attachment struct {
	Node string
	Port string
	VLAN uint32
	// VLANSet says the attachment names a VLAN (a tagged subinterface).
	VLANSet bool
	VRF     string
}

func (a attachment) String() string {
	if a.VLANSet {
		return fmt.Sprintf("%s %s vlan %d", a.Node, a.Port, a.VLAN)
	}
	return fmt.Sprintf("%s %s (untagged)", a.Node, a.Port)
}

// intent is what analyse found on a Network: its construct and resolved attachments.
type intent struct {
	construct   model.Construct
	gateway     bool
	aclOnly     bool
	attachments []attachment
	nodes       []string // attachment nodes, sorted, distinct
}

// ServiceID is the service identifier every device-side name derives from: the Network's
// name, without the tier's migr- prefix (data-model.md §13 "Derivations").
func ServiceID(n *fabricv1.Network) string {
	if id := strings.TrimPrefix(n.Name, tierNamePrefix); id != "" {
		return id
	}
	return n.Name
}

// analyse decides the construct from which lists are present (contracts/network-spec.md §2)
// and collects the attachments. An error is an InvalidIntent refusal.
func analyse(n *fabricv1.Network) (*intent, error) {
	s := &n.Spec
	in := &intent{}
	switch {
	case len(s.VLANs) > 0 && (len(s.BridgeDomains) > 0 || len(s.Routers) > 0):
		return nil, fmt.Errorf("vlans cannot stand beside bridgeDomains or routers: a vlan is a local bridge domain with no overlay")
	case len(s.VLANs) > 0:
		in.construct = model.ConstructVLAN
	case len(s.BridgeDomains) > 0:
		in.construct = model.ConstructMACVRF
		for _, bd := range s.BridgeDomains {
			if bd.IRB != nil {
				in.gateway = true
			}
		}
		if len(s.Routers) > 0 && !in.gateway {
			return nil, fmt.Errorf("bridgeDomains and routers stand together only when the bridge domain carries an irb pointing at the router")
		}
	case len(s.Routers) > 0:
		in.construct = model.ConstructIPVRF
	case len(s.AccessLists) > 0:
		in.construct = model.ConstructACL
		in.aclOnly = true
	default:
		return nil, fmt.Errorf("one of vlans, bridgeDomains, routers or accessLists must be present")
	}
	if len(s.Attachments) == 0 {
		return nil, fmt.Errorf("a Network needs at least one attachment")
	}
	seen := map[string]bool{}
	nodes := map[string]bool{}
	for _, a := range s.Attachments {
		at := attachment{Node: string(a.Node), Port: string(a.Attachment), VRF: string(a.VRF)}
		if a.VLAN != nil {
			at.VLAN, at.VLANSet = uint32(*a.VLAN), true
		}
		key := at.String()
		if seen[key] {
			return nil, fmt.Errorf("two attachments resolve to one subinterface: %s", key)
		}
		seen[key] = true
		nodes[at.Node] = true
		in.attachments = append(in.attachments, at)
	}
	for n := range nodes {
		in.nodes = append(in.nodes, n)
	}
	sort.Strings(in.nodes)
	return in, nil
}

// inventoryProblems resolves every attachment through the Fabric's site inventory: the node
// must have an inventory entry and the port must be one of its access ports. Each problem
// names the attachment (a Fabric changed under an allocated Network, FR-101, is one of them).
func inventoryProblems(in *intent, f *fabricv1.Fabric) []string {
	ports := map[string]map[string]bool{}
	for _, e := range f.Spec.Inventory {
		m := map[string]bool{}
		for _, p := range e.AccessPorts {
			m[string(p)] = true
		}
		ports[string(e.Node)] = m
	}
	var out []string
	for _, a := range in.attachments {
		m, ok := ports[a.Node]
		switch {
		case !ok:
			out = append(out, fmt.Sprintf("attachment %s: node %s is not in the inventory of Fabric %s/%s", a, a.Node, f.Namespace, f.Name))
		case !m[a.Port]:
			out = append(out, fmt.Sprintf("attachment %s: port %s is not an access port of %s in the inventory of Fabric %s/%s", a, a.Port, a.Node, f.Namespace, f.Name))
		}
	}
	return out
}

// serviceInput is the canonical service input of a Network whose every claim is bound.
func serviceInput(n *fabricv1.Network, f *fabricv1.Fabric, in *intent) (model.ServiceInput, error) {
	s := &n.Spec
	si := model.ServiceInput{
		ServiceID: ServiceID(n),
		Tenant:    n.Annotations[AnnotationTenant],
		Construct: in.construct,
		FabricASN: uint32(f.Spec.Overlay.FabricASN),
	}
	switch in.construct {
	case model.ConstructVLAN:
		v := s.VLANs[0]
		si.L2 = &model.L2Segment{VLAN: uint32(v.VLAN), L2MTU: uint32(f.Spec.MTU.BridgedL2MTU)}
		for _, a := range in.attachments {
			if !a.VLANSet || a.VLAN != uint32(v.VLAN) {
				return si, fmt.Errorf("attachment %s does not carry the VLAN %d of spec.vlans[%s]", a, v.VLAN, v.Name)
			}
			si.L2.Attachments = append(si.L2.Attachments, model.Attachment{Node: a.Node, Port: a.Port})
		}
	case model.ConstructMACVRF:
		bd := s.BridgeDomains[0]
		si.L2 = &model.L2Segment{VLAN: uint32(bd.VLAN), L2VNI: uint32(bd.L2VNI), L2MTU: uint32(f.Spec.MTU.BridgedL2MTU)}
		for _, a := range in.attachments {
			if !a.VLANSet || a.VLAN != uint32(bd.VLAN) {
				return si, fmt.Errorf("attachment %s does not carry the VLAN %d of spec.bridgeDomains[%s]", a, bd.VLAN, bd.Name)
			}
			si.L2.Attachments = append(si.L2.Attachments, model.Attachment{Node: a.Node, Port: a.Port})
		}
		if bd.IRB != nil {
			var router *fabricv1.NetworkRouter
			for i := range s.Routers {
				if s.Routers[i].Name == bd.IRB.VRF {
					router = &s.Routers[i]
				}
			}
			if router == nil {
				return si, fmt.Errorf("spec.bridgeDomains[%s].irb.vrf %s names no routers entry", bd.Name, bd.IRB.VRF)
			}
			gw := &model.Gateway{L3VNI: uint32(router.L3VNI), IPMTU: uint32(f.Spec.MTU.TenantIPMTU)}
			if bd.IRB.GatewayIPv4 != "" {
				gw.IPv4 = []string{bd.IRB.GatewayIPv4}
			}
			if bd.IRB.GatewayIPv6 != "" {
				gw.IPv6 = []string{bd.IRB.GatewayIPv6}
			}
			si.Gateway = gw
		}
	case model.ConstructIPVRF:
		r := s.Routers[0]
		si.Routed = &model.RoutedService{L3VNI: uint32(r.L3VNI), IPMTU: uint32(f.Spec.MTU.TenantIPMTU)}
		for _, a := range in.attachments {
			if a.VRF != string(r.Name) {
				return si, fmt.Errorf("attachment %s names vrf %q, not the routers entry %s", a, a.VRF, r.Name)
			}
		}
		addrs, err := routedAddresses(r, in.attachments)
		if err != nil {
			return si, err
		}
		for _, a := range in.attachments {
			ad := addrs[a.String()]
			si.Routed.Attachments = append(si.Routed.Attachments, model.RoutedAttachment{
				Node: a.Node, Port: a.Port, VLAN: a.VLAN, IPv4: ad.v4, IPv6: ad.v6})
		}
	}
	for _, al := range s.AccessLists {
		m, err := accessList(al, in)
		if err != nil {
			return si, err
		}
		si.AccessLists = append(si.AccessLists, m)
	}
	return si, nil
}

// accessList maps one spec.accessLists entry; it binds on every attachment of the object
// (contracts/network-spec.md §5 rule 7).
func accessList(al fabricv1.AccessList, in *intent) (model.AccessList, error) {
	out := model.AccessList{Stage: model.Stage(al.Stage), Family: model.Family(al.Type)}
	if al.DefaultAction != "" {
		a := aclAction(al.DefaultAction)
		out.DefaultAction = &a
	}
	for _, r := range al.Rules {
		mr := model.ACLRule{
			Name: r.Name, Priority: uint32(r.Priority), Action: aclAction(r.Action),
			SourcePrefix: string(r.SourcePrefix), DestinationPrefix: string(r.DestinationPrefix),
		}
		if p := string(r.Protocol); p != "" && p != "any" {
			mr.Protocol = p
		}
		var err error
		if mr.SourcePort, err = portMatch(string(r.SourcePort)); err != nil {
			return out, fmt.Errorf("access list %s rule %s: sourcePort: %w", al.Name, r.Name, err)
		}
		if mr.DestinationPort, err = portMatch(string(r.DestinationPort)); err != nil {
			return out, fmt.Errorf("access list %s rule %s: destinationPort: %w", al.Name, r.Name, err)
		}
		out.Rules = append(out.Rules, mr)
	}
	for _, a := range in.attachments {
		out.Bindings = append(out.Bindings, model.ACLBinding{Node: a.Node, Port: a.Port, VLAN: a.VLAN})
	}
	return out, nil
}

func aclAction(a string) model.Action {
	if a == "permit" {
		return model.ActionAccept
	}
	return model.ActionDrop
}

func portMatch(s string) (*model.PortMatch, error) {
	if s == "" {
		return nil, nil
	}
	lo, hi, rng := strings.Cut(s, "-")
	l, err := strconv.ParseUint(lo, 10, 16)
	if err != nil {
		return nil, fmt.Errorf("port %q", s)
	}
	pm := &model.PortMatch{Lo: uint16(l)}
	if rng {
		h, err := strconv.ParseUint(hi, 10, 16)
		if err != nil || h < l {
			return nil, fmt.Errorf("port range %q", s)
		}
		pm.Hi = uint16(h)
	}
	return pm, nil
}

// routedPrefixes are the declared prefixes of every routed instance, keyed by the
// network-instance name the read-back keys its route-table reads to.
func routedPrefixes(n *fabricv1.Network) (map[string][]string, error) {
	if len(n.Spec.Routers) == 0 {
		return nil, nil
	}
	name, err := model.IPVRFName(ServiceID(n))
	if err != nil {
		return nil, err
	}
	out := map[string][]string{}
	for _, r := range n.Spec.Routers {
		for _, p := range r.Prefixes {
			out[name] = append(out[name], string(p))
		}
	}
	return out, nil
}

// leafLoopbacks is every leaf's allocated system0.0 IPv4 address, from the Fabric's own
// allocations (the VTEPs a spanning service must see).
func leafLoopbacks(f *fabricv1.Fabric) map[string]string {
	leaves := map[string]bool{}
	for _, n := range f.Spec.Nodes {
		if n.Role == fabricv1.NodeRoleLeaf {
			leaves[string(n.Name)] = true
		}
	}
	out := map[string]string{}
	for _, a := range f.Status.Allocations {
		if a.Purpose == "loopback" && leaves[a.Node] && a.Value != "" {
			addr, _, _ := strings.Cut(a.Value, "/")
			out[a.Node] = addr
		}
	}
	return out
}

// routedAddress is the address a routed subinterface carries, per family.
type routedAddress struct{ v4, v6 []string }

// routedAddresses derives the address every routed attachment of an ip-vrf carries from the
// router's declared prefixes (contracts/reconciliation.md Rule 11: "routed subinterfaces
// carrying the attachment addresses"; data-model.md §19: every declared prefix reachable through
// an attachment subnet, subnets non-overlapping within the instance). The Network API carries no
// per-attachment address field, so the address is derived — never chosen — per address family:
//
//   - the declared prefixes of the family are taken in address order, the attachments in
//     (node, port, vlan) order;
//   - ONE declared prefix: every attachment is a gateway of it and carries its first host
//     address (the subnet is present on every attached leaf);
//   - as many prefixes as attachments: the i-th attachment carries the first host address of
//     the i-th prefix — one subnet per attachment, each advertised as a Type-5 route to the
//     other leaves;
//   - any other count is refused naming the counts; a prefix with host bits set, one too long
//     to hold a host, and two overlapping prefixes are refused naming them; a router declaring
//     no prefix at all is refused, because its routed subinterfaces would carry no address.
//
// Decision recorded in docs/decisions/live-findings.md (AD-82, 2026-09-21-routed-attachment-address).
func routedAddresses(r fabricv1.NetworkRouter, atts []attachment) (map[string]routedAddress, error) {
	byFam := map[bool][]netip.Prefix{}
	for _, raw := range r.Prefixes {
		p, err := netip.ParsePrefix(string(raw))
		if err != nil {
			return nil, fmt.Errorf("spec.routers[%s].prefixes: %q is not a prefix: %w", r.Name, raw, err)
		}
		if p != p.Masked() {
			return nil, fmt.Errorf("spec.routers[%s].prefixes: %s has host bits set; declare the network %s", r.Name, p, p.Masked())
		}
		if p.Bits() >= p.Addr().BitLen() {
			return nil, fmt.Errorf("spec.routers[%s].prefixes: %s holds no host address for a routed subinterface", r.Name, p)
		}
		byFam[p.Addr().Is4()] = append(byFam[p.Addr().Is4()], p)
	}
	if len(byFam[true])+len(byFam[false]) == 0 {
		return nil, fmt.Errorf("spec.routers[%s] declares no prefix: an ip-vrf's routed subinterfaces carry the first host address of its declared prefixes, so at least one is needed", r.Name)
	}
	ordered := append([]attachment(nil), atts...)
	sort.Slice(ordered, func(i, j int) bool {
		a, b := ordered[i], ordered[j]
		if a.Node != b.Node {
			return a.Node < b.Node
		}
		if a.Port != b.Port {
			return a.Port < b.Port
		}
		return a.VLAN < b.VLAN
	})
	out := map[string]routedAddress{}
	for _, is4 := range []bool{true, false} {
		ps := byFam[is4]
		if len(ps) == 0 {
			continue
		}
		fam := "ipv6"
		if is4 {
			fam = "ipv4"
		}
		sort.Slice(ps, func(i, j int) bool { return ps[i].Addr().Less(ps[j].Addr()) })
		for i := 1; i < len(ps); i++ {
			if ps[i-1].Overlaps(ps[i]) {
				return nil, fmt.Errorf("spec.routers[%s].prefixes: %s and %s overlap; subnets within one routed instance do not", r.Name, ps[i-1], ps[i])
			}
		}
		if len(ps) != 1 && len(ps) != len(ordered) {
			return nil, fmt.Errorf("spec.routers[%s].prefixes declares %d %s prefixes for %d attachments: declare one (every attachment carries its first host address) or one per attachment (assigned in (node, port, vlan) order)",
				r.Name, len(ps), fam, len(ordered))
		}
		for i, a := range ordered {
			p := ps[0]
			if len(ps) > 1 {
				p = ps[i]
			}
			addr := netip.PrefixFrom(p.Addr().Next(), p.Bits()).String()
			ra := out[a.String()]
			if is4 {
				ra.v4 = append(ra.v4, addr)
			} else {
				ra.v6 = append(ra.v6, addr)
			}
			out[a.String()] = ra
		}
	}
	return out, nil
}
