package model

import (
	"fmt"
	"net/netip"
	"sort"
)

// Role is a fabric node role.
type Role string

const (
	RoleLeaf  Role = "leaf"
	RoleSpine Role = "spine"
)

// ---------------------------------------------------------------------------
// Inputs — the Fabric design with every underlay claim bound.
// ---------------------------------------------------------------------------

// FabricInput is the resolved fabric design (data-model.md §3a): node
// addresses and ASNs are the bound values of the Fabric reconciler's claims.
type FabricInput struct {
	Name       string
	FabricASN  uint32
	InterASVPN bool
	// ReflectorClients is spec.overlay.reflectorClients as declared (default
	// true): rendered as `route-reflector client` on every reflecting spine's
	// overlay group as stated (AD-77).
	ReflectorClients bool
	// AddressFamilies is spec.underlay.addressFamilies; empty means the
	// default, both. IPv4 is always required: the VXLAN tunnel endpoint is
	// IPv4-only on the pinned image (evidence/02-evpn-constructs.md §1.3).
	AddressFamilies []AddressFamily
	MTU             FabricMTU
	Nodes           []FabricNodeInput
	Links           []FabricLink
	Inventory       []InventoryEntry
	Maintenance     []MaintenanceEntry
}

// AddressFamily is an underlay address family.
type AddressFamily string

const (
	FamilyUnderlayIPv4 AddressFamily = "ipv4"
	FamilyUnderlayIPv6 AddressFamily = "ipv6"
)

// FabricMTU is spec.mtu.
type FabricMTU struct {
	PortMTU       uint32
	UnderlayIPMTU uint32
	BridgedL2MTU  uint32
	TenantIPMTU   uint32
}

// FabricNodeInput is one spec.nodes[] entry with its bound values.
type FabricNodeInput struct {
	Name           string
	Role           Role
	SystemIPv4     string // /32
	ASN            uint32
	RouteReflector bool
}

// LinkEnd is one end of a fabric link with its claimed point-to-point address.
type LinkEnd struct {
	Node string
	Port string
	IPv4 string // e.g. 192.168.0.1/31
}

// FabricLink is a leaf–spine link.
type FabricLink struct {
	A, B LinkEnd
}

// InventoryEntry is spec.inventory[].
type InventoryEntry struct {
	Node                string
	AccessPorts         []string
	UntaggedAccessPorts []string
	FabricPorts         []string
}

// MaintenanceEntry is spec.maintenance[] (AD-06).
type MaintenanceEntry struct {
	Node       string
	Interface  string
	AdminState string // today only "disable"
}

// ---------------------------------------------------------------------------
// Per-node objects — what one priority-10 fabric Config carries.
// ---------------------------------------------------------------------------

// AccessPort is an access port's port-level leaves, owned by the fabric Config
// (AD-68).
type AccessPort struct {
	Name        string
	Enabled     bool
	VLANTagging bool
	// MTU is portMTU (9412): the tenant IP MTU of a service subinterface
	// (9348) does not fit under the device's default port MTU (9232), which
	// holds a routed subinterface down with ip-mtu-too-large (live finding
	// 2026-09-21-access-port-mtu).
	MTU uint32
}

// RoutedPort is a fabric port with its routed subinterface 0.
type RoutedPort struct {
	Name    string
	Enabled bool
	MTU     uint32
	IPMTU   uint32
	IPv4    string
	// IPv6 is derived from IPv4 (DeriveLinkIPv6), empty when the underlay
	// is IPv4-only. It is not a claim.
	IPv6 string
}

// BGPNeighbor is one configured neighbor.
type BGPNeighbor struct {
	PeerAddress  string
	PeerGroup    string
	PeerAS       uint32 // underlay only
	LocalAddress string // overlay only
}

// FabricBGP is the default network-instance's BGP.
type FabricBGP struct {
	AutonomousSystem uint32
	RouterID         string
	// Overlay AS on the overlay group: the fabric constant.
	OverlayAS uint32
	// RouteReflectorClient is rendered as `route-reflector client` on the
	// overlay group of a reflecting spine as stated — true or false, never
	// dropped (AD-77); nil on a node that is not a reflector.
	RouteReflectorClient *bool
	// InterASVPN is rendered on every reflecting spine as stated — true or
	// false, never dropped (AD-43); nil on a node that is not a reflector.
	InterASVPN *bool
	// IPv6Unicast enables the ipv6-unicast family and the per-link IPv6
	// underlay sessions (group UnderlayV6Group).
	IPv6Unicast bool
	// AllowOwnAS is rendered as `as-path-options allow-own-as` on the
	// underlay groups of a node whose underlay AS another node shares (the
	// spines): without it the node drops, by AS-path loop detection, the
	// other's loopback re-advertised through a leaf, and the read-back's
	// loopback-route invariant — every other node's system0.0 active — could
	// never hold. It is what G8's scratch fabric observed the invariant on
	// (tests/gate/lib/scratch_fabric.sh). Zero: not rendered.
	AllowOwnAS uint8
	Neighbors  []BGPNeighbor
}

// FabricNode is everything the fabric renders on one node.
type FabricNode struct {
	Name        string
	Role        Role
	SystemIPv4  string
	SystemIPv6  string // derived from SystemIPv4 (DeriveSystemIPv6); empty when IPv4-only
	FabricPorts []RoutedPort
	AccessPorts []AccessPort
	IRBEnabled  bool // irb0 admin-state, leaves only
	// VXLANTunnel renders the tunnel-interface vxlan0 entry: leaves only —
	// spines terminate no tenant VXLAN. The vxlan-interfaces beneath it are
	// the services' (data-model.md §13).
	VXLANTunnel   bool
	BGP           FabricBGP
	LoopbackBlock []string // prefixes of the system-loopbacks prefix-set (IPv4 /32 and derived IPv6 /128)
}

// FabricModel is the canonical fabric model, nodes sorted by name.
type FabricModel struct {
	Name      string
	FabricASN uint32
	Nodes     []FabricNode
}

// Node returns the per-node object for name, or nil.
func (m *FabricModel) Node(name string) *FabricNode {
	for i := range m.Nodes {
		if m.Nodes[i].Name == name {
			return &m.Nodes[i]
		}
	}
	return nil
}

// BuildFabric derives the per-node fabric model. Pure and order-independent.
func BuildFabric(in FabricInput) (*FabricModel, error) {
	if in.FabricASN == 0 {
		return nil, fmt.Errorf("fabric %s: fabricASN is required", in.Name)
	}
	nodes := map[string]*FabricNodeInput{}
	var leaves, spines, reflectors []string
	for i := range in.Nodes {
		n := &in.Nodes[i]
		if _, dup := nodes[n.Name]; dup {
			return nil, fmt.Errorf("node %s declared twice", n.Name)
		}
		nodes[n.Name] = n
		if _, err := hostPrefix(n.SystemIPv4); err != nil {
			return nil, fmt.Errorf("node %s systemIPv4: %w", n.Name, err)
		}
		switch n.Role {
		case RoleLeaf:
			leaves = append(leaves, n.Name)
			if n.RouteReflector {
				return nil, fmt.Errorf("node %s: routeReflector is only valid on a spine", n.Name)
			}
		case RoleSpine:
			spines = append(spines, n.Name)
			if n.RouteReflector {
				reflectors = append(reflectors, n.Name)
			}
		default:
			return nil, fmt.Errorf("node %s: role %q", n.Name, n.Role)
		}
	}
	if len(leaves) == 0 || len(spines) == 0 {
		return nil, fmt.Errorf("a fabric needs at least one leaf and one spine")
	}
	v6, err := underlayIPv6(in.AddressFamilies)
	if err != nil {
		return nil, fmt.Errorf("fabric %s: %w", in.Name, err)
	}
	sys6 := map[string]string{}
	if v6 {
		for _, n := range in.Nodes {
			a, err := DeriveSystemIPv6(n.SystemIPv4)
			if err != nil {
				return nil, fmt.Errorf("node %s: %w", n.Name, err)
			}
			sys6[n.Name] = a
		}
	}
	sort.Strings(reflectors)
	sort.Strings(leaves)

	asUsers := map[uint32]int{}
	for _, n := range in.Nodes {
		asUsers[n.ASN]++
	}

	out := map[string]*FabricNode{}
	for _, n := range in.Nodes {
		fn := &FabricNode{
			Name: n.Name, Role: n.Role, SystemIPv4: n.SystemIPv4, SystemIPv6: sys6[n.Name],
			IRBEnabled:  n.Role == RoleLeaf,
			VXLANTunnel: n.Role == RoleLeaf,
			BGP: FabricBGP{
				AutonomousSystem: n.ASN,
				RouterID:         mustAddr(n.SystemIPv4),
				OverlayAS:        in.FabricASN,
				IPv6Unicast:      v6,
			},
		}
		if asUsers[n.ASN] > 1 {
			fn.BGP.AllowOwnAS = 1
		}
		if n.RouteReflector {
			v := in.InterASVPN
			fn.BGP.InterASVPN = &v
			rc := in.ReflectorClients
			fn.BGP.RouteReflectorClient = &rc
			// A reflector peers with every leaf loopback.
			for _, l := range leaves {
				fn.BGP.Neighbors = append(fn.BGP.Neighbors, BGPNeighbor{
					PeerAddress: mustAddr(nodes[l].SystemIPv4), PeerGroup: OverlayGroup,
					LocalAddress: mustAddr(n.SystemIPv4)})
			}
		}
		if n.Role == RoleLeaf {
			for _, r := range reflectors {
				fn.BGP.Neighbors = append(fn.BGP.Neighbors, BGPNeighbor{
					PeerAddress: mustAddr(nodes[r].SystemIPv4), PeerGroup: OverlayGroup,
					LocalAddress: mustAddr(n.SystemIPv4)})
			}
		}
		for _, other := range in.Nodes {
			fn.LoopbackBlock = append(fn.LoopbackBlock, other.SystemIPv4)
			if v6 {
				fn.LoopbackBlock = append(fn.LoopbackBlock, sys6[other.Name])
			}
		}
		sort.Strings(fn.LoopbackBlock)
		out[n.Name] = fn
	}

	maint := map[string]bool{}
	for _, m := range in.Maintenance {
		if m.AdminState != "disable" {
			return nil, fmt.Errorf("maintenance %s %s: adminState %q", m.Node, m.Interface, m.AdminState)
		}
		maint[m.Node+"|"+m.Interface] = true
	}

	for _, l := range in.Links {
		for _, pair := range [][2]LinkEnd{{l.A, l.B}, {l.B, l.A}} {
			self, peer := pair[0], pair[1]
			fn, ok := out[self.Node]
			if !ok {
				return nil, fmt.Errorf("link end names unknown node %s", self.Node)
			}
			if _, ok := nodes[peer.Node]; !ok {
				return nil, fmt.Errorf("link end names unknown node %s", peer.Node)
			}
			if _, err := netip.ParsePrefix(self.IPv4); err != nil {
				return nil, fmt.Errorf("link %s %s: %w", self.Node, self.Port, err)
			}
			rp := RoutedPort{
				Name: self.Port, Enabled: !maint[self.Node+"|"+self.Port],
				MTU: in.MTU.PortMTU, IPMTU: in.MTU.UnderlayIPMTU, IPv4: self.IPv4,
			}
			fn.BGP.Neighbors = append(fn.BGP.Neighbors, BGPNeighbor{
				PeerAddress: mustAddr(peer.IPv4), PeerGroup: UnderlayGroup, PeerAS: nodes[peer.Node].ASN,
			})
			if v6 {
				self6, err := DeriveLinkIPv6(self.IPv4)
				if err != nil {
					return nil, fmt.Errorf("link %s %s: %w", self.Node, self.Port, err)
				}
				peer6, err := DeriveLinkIPv6(peer.IPv4)
				if err != nil {
					return nil, fmt.Errorf("link %s %s: %w", peer.Node, peer.Port, err)
				}
				rp.IPv6 = self6
				fn.BGP.Neighbors = append(fn.BGP.Neighbors, BGPNeighbor{
					PeerAddress: mustAddr(peer6), PeerGroup: UnderlayV6Group, PeerAS: nodes[peer.Node].ASN,
				})
			}
			fn.FabricPorts = append(fn.FabricPorts, rp)
		}
	}

	for _, inv := range in.Inventory {
		fn, ok := out[inv.Node]
		if !ok {
			return nil, fmt.Errorf("inventory names unknown node %s", inv.Node)
		}
		untagged := map[string]bool{}
		for _, p := range inv.UntaggedAccessPorts {
			untagged[p] = true
		}
		access := map[string]bool{}
		for _, p := range inv.AccessPorts {
			access[p] = true
			fn.AccessPorts = append(fn.AccessPorts, AccessPort{
				Name: p, Enabled: !maint[inv.Node+"|"+p], VLANTagging: !untagged[p], MTU: in.MTU.PortMTU,
			})
		}
		for p := range untagged {
			if !access[p] {
				return nil, fmt.Errorf("node %s: untagged port %s is not an access port", inv.Node, p)
			}
		}
		if len(inv.AccessPorts) > 0 && fn.Role != RoleLeaf {
			return nil, fmt.Errorf("node %s: a spine has no access ports", inv.Node)
		}
	}

	m := &FabricModel{Name: in.Name, FabricASN: in.FabricASN}
	for _, fn := range out {
		sort.Slice(fn.FabricPorts, func(i, j int) bool { return fn.FabricPorts[i].Name < fn.FabricPorts[j].Name })
		sort.Slice(fn.AccessPorts, func(i, j int) bool { return fn.AccessPorts[i].Name < fn.AccessPorts[j].Name })
		sort.Slice(fn.BGP.Neighbors, func(i, j int) bool {
			a, b := fn.BGP.Neighbors[i], fn.BGP.Neighbors[j]
			if a.PeerGroup != b.PeerGroup {
				return a.PeerGroup > b.PeerGroup // underlay before overlay
			}
			return a.PeerAddress < b.PeerAddress
		})
		m.Nodes = append(m.Nodes, *fn)
	}
	sort.Slice(m.Nodes, func(i, j int) bool { return m.Nodes[i].Name < m.Nodes[j].Name })
	return m, nil
}

func hostPrefix(s string) (netip.Prefix, error) {
	p, err := netip.ParsePrefix(s)
	if err != nil {
		return p, err
	}
	if !p.Addr().Is4() || p.Bits() != 32 {
		return p, fmt.Errorf("%q is not an IPv4 /32", s)
	}
	return p, nil
}

func mustAddr(prefix string) string {
	p, err := netip.ParsePrefix(prefix)
	if err != nil {
		return prefix
	}
	return p.Addr().String()
}

// BGP address-family names as the model (and the path register) keys them.
// The renderer maps them to the device's identityref form in one place
// (internal/render/srl, T047 switches that form after G12).
const (
	AFIIPv4Unicast = "ipv4-unicast"
	AFIIPv6Unicast = "ipv6-unicast"
	AFIEVPN        = "evpn"
)

// Families are the address families enabled on the BGP instance, sorted.
func (b *FabricBGP) Families() []string {
	if b.IPv6Unicast {
		return []string{AFIEVPN, AFIIPv4Unicast, AFIIPv6Unicast}
	}
	return []string{AFIEVPN, AFIIPv4Unicast}
}

// Groups are the peer-groups rendered, sorted.
func (b *FabricBGP) Groups() []string {
	if b.IPv6Unicast {
		return []string{OverlayGroup, UnderlayGroup, UnderlayV6Group}
	}
	return []string{OverlayGroup, UnderlayGroup}
}

// GroupFamilyEnabled says whether family is enabled on group. Every group
// states every enabled family explicitly, so each session carries exactly
// one: the IPv4 underlay sessions ipv4-unicast, the IPv6 underlay sessions
// ipv6-unicast, the overlay sessions evpn.
func (b *FabricBGP) GroupFamilyEnabled(group, family string) bool {
	switch group {
	case UnderlayGroup:
		return family == AFIIPv4Unicast
	case UnderlayV6Group:
		return family == AFIIPv6Unicast
	case OverlayGroup:
		return family == AFIEVPN
	}
	return false
}
