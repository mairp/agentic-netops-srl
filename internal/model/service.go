package model

import (
	"fmt"
	"net/netip"
	"sort"
)

// Construct is one of the four service constructs plus the standalone access
// list (contracts/construct-vocabulary.md).
type Construct string

const (
	ConstructVLAN   Construct = "vlan"
	ConstructMACVRF Construct = "mac-vrf"
	ConstructIPVRF  Construct = "ip-vrf"
	ConstructACL    Construct = "acl"
)

// Family is an address family.
type Family string

const (
	FamilyIPv4 Family = "ipv4"
	FamilyIPv6 Family = "ipv6"
)

// Action is an access-list action.
type Action string

const (
	ActionAccept Action = "accept"
	ActionDrop   Action = "drop"
)

// SubinterfaceType is bridged or routed.
type SubinterfaceType string

const (
	Bridged SubinterfaceType = "bridged"
	Routed  SubinterfaceType = "routed"
)

// NetworkInstanceType is the device's own network-instance type.
type NetworkInstanceType string

const (
	MACVRF NetworkInstanceType = "mac-vrf"
	IPVRF  NetworkInstanceType = "ip-vrf"
)

// ---------------------------------------------------------------------------
// Inputs — what a Network carries once every claim is bound.
// ---------------------------------------------------------------------------

// ServiceInput is the resolved intent of one service: every allocated value
// (VLAN, VNIs) already bound, every attachment resolved to (node, port).
type ServiceInput struct {
	// ServiceID is the service identifier every name derives from.
	ServiceID string
	// Tenant is used only in the access-list description.
	Tenant string
	// Construct is the service construct.
	Construct Construct
	// FabricASN is the one fabric-wide route-target constant.
	FabricASN uint32
	// L2 is the bridged segment of a `vlan` or `mac-vrf`.
	L2 *L2Segment
	// Gateway adds the anycast gateway (and its ip-vrf) to a `mac-vrf`.
	Gateway *Gateway
	// Routed is the routed service of an `ip-vrf`.
	Routed *RoutedService
	// AccessLists are the filters this service renders — as a property of the
	// service, or (Construct == acl) standalone.
	AccessLists []AccessList
}

// Attachment is a (node, port) an L2 segment is attached on.
type Attachment struct {
	Node string
	Port string
}

// L2Segment is a bridged segment: one VLAN, and for a mac-vrf one L2VNI.
type L2Segment struct {
	VLAN        uint32
	L2VNI       uint32 // zero for a `vlan` construct
	Attachments []Attachment
	// L2MTU is bridgedL2MTU (data-model.md §20: 9412), stated on every bridged
	// subinterface; left unset the device default (9232) drops a tenant-MTU
	// frame (live finding 2026-09-21-access-port-mtu). 0 = not rendered.
	L2MTU uint32
}

// Gateway is the anycast gateway of a mac-vrf with integrated routing.
type Gateway struct {
	L3VNI uint32
	// IPv4 / IPv6 are the gateway addresses with prefix length, e.g. 10.10.0.1/24.
	IPv4  []string
	IPv6  []string
	IPMTU uint32
}

// RoutedAttachment is one routed subinterface of an ip-vrf.
type RoutedAttachment struct {
	Node string
	Port string
	VLAN uint32 // 0 = untagged subinterface 0
	IPv4 []string
	IPv6 []string
}

// RoutedService is an ip-vrf.
type RoutedService struct {
	L3VNI       uint32
	Attachments []RoutedAttachment
	// IPMTU is the tenant IP MTU stated on every routed subinterface
	// (data-model.md §20: 9348 = port MTU − 64). Left unset the device applies
	// its own subinterface default, far below the tenant MTU.
	IPMTU uint32
}

// PortMatch is a transport port match: a single port (Lo only) or a range.
type PortMatch struct {
	Lo uint16
	Hi uint16 // zero for a single port
}

// ACLRule is one operator rule.
type ACLRule struct {
	Name              string
	Priority          uint32
	Action            Action
	Protocol          string // name or number; empty = any
	SourcePrefix      string
	DestinationPrefix string
	SourcePort        *PortMatch
	DestinationPort   *PortMatch
}

// ACLBinding is where a filter is bound: node + port (+ VLAN; 0 = subinterface 0).
type ACLBinding struct {
	Node string
	Port string
	VLAN uint32
}

// AccessList is one filter of one service.
type AccessList struct {
	Stage         Stage
	Family        Family
	Rules         []ACLRule
	DefaultAction *Action
	Bindings      []ACLBinding
}

// ---------------------------------------------------------------------------
// Per-node objects — what one service Config carries for one node.
// ---------------------------------------------------------------------------

// Subinterface is a service-owned subinterface of an access port. The port's
// own admin-state and vlan-tagging are the fabric Config's (AD-68).
type Subinterface struct {
	Port  string
	Index uint32
	Type  SubinterfaceType
	VLAN  uint32 // 0 = untagged, no vlan container
	IPv4  []string
	IPv6  []string
	IPMTU uint32 // routed subinterfaces only; 0 = not rendered
	L2MTU uint32 // bridged subinterfaces only; 0 = not rendered
}

// Name is `<port>.<index>`.
func (s Subinterface) Name() string { return SubinterfaceName(s.Port, s.Index) }

// IRBSubinterface is `irb0.<vlan>` with its anycast gateway.
type IRBSubinterface struct {
	Index           uint32
	VirtualRouterID uint32
	IPv4            []string
	IPv6            []string
	IPMTU           uint32
}

// Name is `irb0.<index>`.
func (s IRBSubinterface) Name() string { return SubinterfaceName(IRBInterface, s.Index) }

// VXLANInterface is `/tunnel-interface[name=vxlan0]/vxlan-interface[index]`.
type VXLANInterface struct {
	Index uint32
	Type  SubinterfaceType
	VNI   uint32
	// EgressSystemIP renders `egress source-ip use-system-ipv4-address`
	// (bridged interfaces, data-model.md §13).
	EgressSystemIP bool
}

// Name is `vxlan0.<index>`.
func (v VXLANInterface) Name() string { return VXLANInterfaceName(v.Index) }

// EVPNInstance is `protocols/bgp-evpn/bgp-instance[id=1]`.
type EVPNInstance struct {
	ID             uint32
	EVI            uint32
	VXLANInterface string
	ECMP           uint32
}

// BGPVPNInstance is `protocols/bgp-vpn/bgp-instance[id=1]` with explicit targets.
type BGPVPNInstance struct {
	ID       uint32
	ExportRT string
	ImportRT string
}

// NetworkInstance is a mac-vrf or ip-vrf of one service on one node.
type NetworkInstance struct {
	Name                string
	Type                NetworkInstanceType
	Description         string
	Interfaces          []string // subinterface references, sorted
	VXLANInterface      string   // at most one (max-elements 1); empty for `vlan`
	ProtectAnycastGWMAC bool
	EVPN                *EVPNInstance
	BGPVPN              *BGPVPNInstance
}

// ACLEntry is `entry[sequence-id]`.
type ACLEntry struct {
	SequenceID        uint32
	Description       string
	Action            Action
	Family            Family
	Protocol          string
	SourcePrefix      string
	DestinationPrefix string
	SourcePort        *PortMatch
	DestinationPort   *PortMatch
}

// ACLFilter is `/acl/acl-filter[name][type]`.
type ACLFilter struct {
	Name                 string
	Type                 Family
	Description          string
	StatisticsPerEntry   bool
	SubinterfaceSpecific string // "output-only" on egress, empty otherwise
	Entries              []ACLEntry
}

// FilterRef is a (name, type) pair — the filter key is always the pair.
type FilterRef struct {
	Name string
	Type Family
}

// ACLInterface is `/acl/interface[interface-id]`.
type ACLInterface struct {
	InterfaceID string
	// Ref is written by the Config that renders the subinterface, always, and
	// never by a standalone acl (AD-68).
	Ref    *InterfaceRef
	Input  []FilterRef
	Output []FilterRef
}

// InterfaceRef is `interface-ref {interface, subinterface}`.
type InterfaceRef struct {
	Interface    string
	Subinterface uint32
}

// ServiceNode is everything one service renders on one node (one Config).
type ServiceNode struct {
	Node             string
	Subinterfaces    []Subinterface
	IRB              []IRBSubinterface
	VXLANInterfaces  []VXLANInterface
	NetworkInstances []NetworkInstance
	ACLFilters       []ACLFilter
	ACLInterfaces    []ACLInterface
}

// ServiceModel is the canonical model of one service: one ServiceNode per
// affected node, sorted by node name.
type ServiceModel struct {
	ServiceID string
	Construct Construct
	Nodes     []ServiceNode
}

// Node returns the per-node object for name, or nil.
func (m *ServiceModel) Node(name string) *ServiceNode {
	for i := range m.Nodes {
		if m.Nodes[i].Node == name {
			return &m.Nodes[i]
		}
	}
	return nil
}

// BuildService derives the per-node model of one service. It is a pure
// function: equal inputs give equal outputs, independent of input ordering.
func BuildService(in ServiceInput) (*ServiceModel, error) {
	if err := ValidateServiceID(in.ServiceID); err != nil {
		return nil, err
	}
	b := &serviceBuilder{in: in, nodes: map[string]*ServiceNode{}}
	var err error
	switch in.Construct {
	case ConstructVLAN:
		err = b.vlan()
	case ConstructMACVRF:
		err = b.macvrf()
	case ConstructIPVRF:
		err = b.ipvrf()
	case ConstructACL:
		if in.L2 != nil || in.Gateway != nil || in.Routed != nil {
			err = fmt.Errorf("a standalone acl creates no subinterface, instance or tunnel")
		}
	default:
		err = fmt.Errorf("unknown construct %q", in.Construct)
	}
	if err != nil {
		return nil, err
	}
	if err := b.accessLists(); err != nil {
		return nil, err
	}
	return b.finish(), nil
}

type serviceBuilder struct {
	in    ServiceInput
	nodes map[string]*ServiceNode
}

func (b *serviceBuilder) node(name string) *ServiceNode {
	n, ok := b.nodes[name]
	if !ok {
		n = &ServiceNode{Node: name}
		b.nodes[name] = n
	}
	return n
}

func (b *serviceBuilder) vlan() error {
	l2 := b.in.L2
	if l2 == nil {
		return fmt.Errorf("vlan construct needs an L2 segment")
	}
	if l2.L2VNI != 0 || b.in.Gateway != nil || b.in.Routed != nil {
		return fmt.Errorf("a vlan construct has no overlay: no vni, gateway or routed half")
	}
	ni, err := VLANInstanceName(b.in.ServiceID)
	if err != nil {
		return err
	}
	return b.bridged(ni, nil, nil)
}

func (b *serviceBuilder) macvrf() error {
	l2 := b.in.L2
	if l2 == nil {
		return fmt.Errorf("mac-vrf construct needs an L2 segment")
	}
	if b.in.Routed != nil {
		return fmt.Errorf("mac-vrf construct carries no routed attachments")
	}
	ni, err := MACVRFName(b.in.ServiceID)
	if err != nil {
		return err
	}
	vx, evpn, vpn, err := b.overlay(l2.L2VNI, Bridged)
	if err != nil {
		return err
	}
	if err := b.bridged(ni, &vx, &overlayParts{evpn: evpn, vpn: vpn}); err != nil {
		return err
	}
	if b.in.Gateway != nil {
		return b.gateway()
	}
	return nil
}

type overlayParts struct {
	evpn *EVPNInstance
	vpn  *BGPVPNInstance
}

// overlay derives the vxlan-interface, EVPN and BGP-VPN instances from one VNI.
func (b *serviceBuilder) overlay(vni uint32, typ SubinterfaceType) (VXLANInterface, *EVPNInstance, *BGPVPNInstance, error) {
	idx, err := VXLANInterfaceIndex(vni)
	if err != nil {
		return VXLANInterface{}, nil, nil, err
	}
	evi, err := EVI(vni)
	if err != nil {
		return VXLANInterface{}, nil, nil, err
	}
	rt, err := RouteTarget(b.in.FabricASN, vni)
	if err != nil {
		return VXLANInterface{}, nil, nil, err
	}
	vx := VXLANInterface{Index: idx, Type: typ, VNI: vni, EgressSystemIP: typ == Bridged}
	return vx,
		&EVPNInstance{ID: BGPInstanceID, EVI: evi, VXLANInterface: vx.Name(), ECMP: EVPNECMP},
		&BGPVPNInstance{ID: BGPInstanceID, ExportRT: rt, ImportRT: rt},
		nil
}

func (b *serviceBuilder) bridged(niName string, vx *VXLANInterface, ov *overlayParts) error {
	l2 := b.in.L2
	idx, err := SubinterfaceIndex(l2.VLAN)
	if err != nil {
		return err
	}
	if l2.VLAN == 0 {
		return fmt.Errorf("a bridged segment needs a vlan")
	}
	if len(l2.Attachments) == 0 {
		return fmt.Errorf("a bridged segment needs at least one attachment")
	}
	for _, a := range l2.Attachments {
		if a.Node == "" || a.Port == "" {
			return fmt.Errorf("attachment needs node and port")
		}
		n := b.node(a.Node)
		s := Subinterface{Port: a.Port, Index: idx, Type: Bridged, VLAN: l2.VLAN, L2MTU: l2.L2MTU}
		n.Subinterfaces = append(n.Subinterfaces, s)
		ni := b.instance(n, niName, MACVRF)
		ni.Interfaces = append(ni.Interfaces, s.Name())
		if vx != nil {
			ni.VXLANInterface = vx.Name()
			ni.EVPN, ni.BGPVPN = ov.evpn, ov.vpn
			addVXLAN(n, *vx)
		}
	}
	return nil
}

func (b *serviceBuilder) gateway() error {
	gw := b.in.Gateway
	l2 := b.in.L2
	if len(gw.IPv4)+len(gw.IPv6) == 0 {
		return fmt.Errorf("anycast gateway needs at least one address")
	}
	if err := validatePrefixes(gw.IPv4, FamilyIPv4); err != nil {
		return err
	}
	if err := validatePrefixes(gw.IPv6, FamilyIPv6); err != nil {
		return err
	}
	if gw.IPMTU == 0 {
		return fmt.Errorf("anycast gateway needs an explicit ip-mtu")
	}
	irbName, err := IRBSubinterfaceName(l2.VLAN)
	if err != nil {
		return err
	}
	ipvrf, err := IPVRFName(b.in.ServiceID)
	if err != nil {
		return err
	}
	macvrf, _ := MACVRFName(b.in.ServiceID)
	vx, evpn, vpn, err := b.overlay(gw.L3VNI, Routed)
	if err != nil {
		return err
	}
	for _, n := range b.nodes {
		n.IRB = append(n.IRB, IRBSubinterface{
			Index: l2.VLAN, VirtualRouterID: AnycastVirtualRouterID,
			IPv4: sortedCopy(gw.IPv4), IPv6: sortedCopy(gw.IPv6), IPMTU: gw.IPMTU,
		})
		// irb0.<vlan> is a member of both instances.
		mac := b.instance(n, macvrf, MACVRF)
		mac.Interfaces = append(mac.Interfaces, irbName)
		mac.ProtectAnycastGWMAC = true
		ip := b.instance(n, ipvrf, IPVRF)
		ip.Interfaces = append(ip.Interfaces, irbName)
		ip.VXLANInterface = vx.Name()
		ip.EVPN, ip.BGPVPN = evpn, vpn
		addVXLAN(n, vx)
	}
	return nil
}

func (b *serviceBuilder) ipvrf() error {
	r := b.in.Routed
	if r == nil {
		return fmt.Errorf("ip-vrf construct needs a routed service")
	}
	if b.in.L2 != nil || b.in.Gateway != nil {
		return fmt.Errorf("ip-vrf construct carries no bridged segment or gateway")
	}
	if len(r.Attachments) == 0 {
		return fmt.Errorf("ip-vrf needs at least one attachment")
	}
	if r.IPMTU == 0 {
		return fmt.Errorf("ip-vrf needs an explicit ip-mtu on its routed subinterfaces")
	}
	ni, err := IPVRFName(b.in.ServiceID)
	if err != nil {
		return err
	}
	vx, evpn, vpn, err := b.overlay(r.L3VNI, Routed)
	if err != nil {
		return err
	}
	for _, a := range r.Attachments {
		if a.Node == "" || a.Port == "" {
			return fmt.Errorf("attachment needs node and port")
		}
		idx, err := SubinterfaceIndex(a.VLAN)
		if err != nil {
			return err
		}
		if err := validatePrefixes(a.IPv4, FamilyIPv4); err != nil {
			return err
		}
		if err := validatePrefixes(a.IPv6, FamilyIPv6); err != nil {
			return err
		}
		n := b.node(a.Node)
		s := Subinterface{Port: a.Port, Index: idx, Type: Routed, VLAN: a.VLAN,
			IPv4: sortedCopy(a.IPv4), IPv6: sortedCopy(a.IPv6), IPMTU: r.IPMTU}
		n.Subinterfaces = append(n.Subinterfaces, s)
		inst := b.instance(n, ni, IPVRF)
		inst.Interfaces = append(inst.Interfaces, s.Name())
		inst.VXLANInterface = vx.Name()
		inst.EVPN, inst.BGPVPN = evpn, vpn
		addVXLAN(n, vx)
	}
	return nil
}

func (b *serviceBuilder) instance(n *ServiceNode, name string, typ NetworkInstanceType) *NetworkInstance {
	for i := range n.NetworkInstances {
		if n.NetworkInstances[i].Name == name {
			return &n.NetworkInstances[i]
		}
	}
	n.NetworkInstances = append(n.NetworkInstances, NetworkInstance{
		Name: name, Type: typ, Description: ServiceDescription(b.in.ServiceID, b.in.Construct),
	})
	return &n.NetworkInstances[len(n.NetworkInstances)-1]
}

func addVXLAN(n *ServiceNode, vx VXLANInterface) {
	for _, e := range n.VXLANInterfaces {
		if e.Index == vx.Index {
			return
		}
	}
	n.VXLANInterfaces = append(n.VXLANInterfaces, vx)
}

func (b *serviceBuilder) accessLists() error {
	seen := map[string]bool{}
	for _, al := range b.in.AccessLists {
		name, err := FilterName(b.in.ServiceID, al.Stage)
		if err != nil {
			return err
		}
		if al.Family != FamilyIPv4 && al.Family != FamilyIPv6 {
			return fmt.Errorf("acl family %q is neither ipv4 nor ipv6", al.Family)
		}
		key := name + "/" + string(al.Family)
		if seen[key] {
			return fmt.Errorf("two access lists render filter %s type %s", name, al.Family)
		}
		seen[key] = true
		if len(al.Bindings) == 0 {
			return fmt.Errorf("access list %s has no binding", name)
		}
		filter, err := buildFilter(b.in, name, al)
		if err != nil {
			return err
		}
		ref := FilterRef{Name: name, Type: al.Family}
		for _, bd := range al.Bindings {
			idx, err := SubinterfaceIndex(bd.VLAN)
			if err != nil {
				return err
			}
			var n *ServiceNode
			if b.in.Construct == ConstructACL {
				n = b.node(bd.Node)
			} else {
				var ok bool
				if n, ok = b.nodes[bd.Node]; !ok || !ownsSubinterface(n, bd.Port, idx) {
					return fmt.Errorf("access list %s binds %s %s.%d, which this service does not create", name, bd.Node, bd.Port, idx)
				}
			}
			addFilter(n, filter)
			ai := aclInterface(n, SubinterfaceName(bd.Port, idx))
			if al.Stage == StageIngress {
				ai.Input = appendRef(ai.Input, ref)
			} else {
				ai.Output = appendRef(ai.Output, ref)
			}
		}
	}
	return nil
}

func ownsSubinterface(n *ServiceNode, port string, idx uint32) bool {
	for _, s := range n.Subinterfaces {
		if s.Port == port && s.Index == idx {
			return true
		}
	}
	return false
}

func buildFilter(in ServiceInput, name string, al AccessList) (ACLFilter, error) {
	f := ACLFilter{
		Name:               name,
		Type:               al.Family,
		Description:        FilterDescription(in.Tenant, in.ServiceID, al.Stage),
		StatisticsPerEntry: true,
	}
	if al.Stage == StageEgress {
		f.SubinterfaceSpecific = "output-only"
	}
	seq := map[uint32]bool{}
	for _, r := range al.Rules {
		s, err := SequenceID(r.Priority)
		if err != nil {
			return f, err
		}
		if seq[s] {
			return f, fmt.Errorf("filter %s: two rules share priority %d", name, s)
		}
		seq[s] = true
		if r.Action != ActionAccept && r.Action != ActionDrop {
			return f, fmt.Errorf("filter %s rule %q: action %q", name, r.Name, r.Action)
		}
		for _, p := range []string{r.SourcePrefix, r.DestinationPrefix} {
			if p != "" {
				if err := validatePrefixes([]string{p}, al.Family); err != nil {
					return f, fmt.Errorf("filter %s rule %q: %w", name, r.Name, err)
				}
			}
		}
		for _, pm := range []*PortMatch{r.SourcePort, r.DestinationPort} {
			if pm != nil && pm.Hi != 0 && pm.Hi < pm.Lo {
				return f, fmt.Errorf("filter %s rule %q: port range %d-%d", name, r.Name, pm.Lo, pm.Hi)
			}
		}
		f.Entries = append(f.Entries, ACLEntry{
			SequenceID: s, Description: r.Name, Action: r.Action, Family: al.Family,
			Protocol: r.Protocol, SourcePrefix: r.SourcePrefix, DestinationPrefix: r.DestinationPrefix,
			SourcePort: r.SourcePort, DestinationPort: r.DestinationPort,
		})
	}
	if al.DefaultAction != nil {
		desc := "default-deny"
		if *al.DefaultAction == ActionAccept {
			desc = "default-permit"
		}
		f.Entries = append(f.Entries, ACLEntry{SequenceID: DefaultActionSequenceID, Description: desc,
			Action: *al.DefaultAction, Family: al.Family})
	}
	sort.Slice(f.Entries, func(i, j int) bool { return f.Entries[i].SequenceID < f.Entries[j].SequenceID })
	return f, nil
}

func addFilter(n *ServiceNode, f ACLFilter) {
	for _, e := range n.ACLFilters {
		if e.Name == f.Name && e.Type == f.Type {
			return
		}
	}
	n.ACLFilters = append(n.ACLFilters, f)
}

func aclInterface(n *ServiceNode, id string) *ACLInterface {
	for i := range n.ACLInterfaces {
		if n.ACLInterfaces[i].InterfaceID == id {
			return &n.ACLInterfaces[i]
		}
	}
	n.ACLInterfaces = append(n.ACLInterfaces, ACLInterface{InterfaceID: id})
	return &n.ACLInterfaces[len(n.ACLInterfaces)-1]
}

func appendRef(refs []FilterRef, r FilterRef) []FilterRef {
	for _, e := range refs {
		if e == r {
			return refs
		}
	}
	return append(refs, r)
}

// finish writes the interface-ref of every owned subinterface (AD-68) and
// sorts every list so that the model is independent of input order.
func (b *serviceBuilder) finish() *ServiceModel {
	m := &ServiceModel{ServiceID: b.in.ServiceID, Construct: b.in.Construct}
	for _, n := range b.nodes {
		// The Config that renders a subinterface renders its interface-ref, always.
		for _, s := range n.Subinterfaces {
			ai := aclInterface(n, s.Name())
			ai.Ref = &InterfaceRef{Interface: s.Port, Subinterface: s.Index}
		}
		sort.Slice(n.Subinterfaces, func(i, j int) bool { return n.Subinterfaces[i].Name() < n.Subinterfaces[j].Name() })
		sort.Slice(n.IRB, func(i, j int) bool { return n.IRB[i].Index < n.IRB[j].Index })
		sort.Slice(n.VXLANInterfaces, func(i, j int) bool { return n.VXLANInterfaces[i].Index < n.VXLANInterfaces[j].Index })
		for i := range n.NetworkInstances {
			sort.Strings(n.NetworkInstances[i].Interfaces)
		}
		sort.Slice(n.NetworkInstances, func(i, j int) bool { return n.NetworkInstances[i].Name < n.NetworkInstances[j].Name })
		sort.Slice(n.ACLFilters, func(i, j int) bool {
			if n.ACLFilters[i].Name != n.ACLFilters[j].Name {
				return n.ACLFilters[i].Name < n.ACLFilters[j].Name
			}
			return n.ACLFilters[i].Type < n.ACLFilters[j].Type
		})
		for i := range n.ACLInterfaces {
			sortRefs(n.ACLInterfaces[i].Input)
			sortRefs(n.ACLInterfaces[i].Output)
		}
		sort.Slice(n.ACLInterfaces, func(i, j int) bool { return n.ACLInterfaces[i].InterfaceID < n.ACLInterfaces[j].InterfaceID })
		m.Nodes = append(m.Nodes, *n)
	}
	sort.Slice(m.Nodes, func(i, j int) bool { return m.Nodes[i].Node < m.Nodes[j].Node })
	return m
}

func sortRefs(r []FilterRef) {
	sort.Slice(r, func(i, j int) bool {
		if r[i].Name != r[j].Name {
			return r[i].Name < r[j].Name
		}
		return r[i].Type < r[j].Type
	})
}

func sortedCopy(in []string) []string {
	if len(in) == 0 {
		return nil
	}
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}

func validatePrefixes(ps []string, fam Family) error {
	for _, p := range ps {
		pf, err := netip.ParsePrefix(p)
		if err != nil {
			return fmt.Errorf("%q is not a prefix: %w", p, err)
		}
		if (fam == FamilyIPv4) != pf.Addr().Is4() {
			return fmt.Errorf("%q is not an %s prefix", p, fam)
		}
	}
	return nil
}
