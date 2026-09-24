package srl

// This file holds the service entry points (T057): the priority-20 service
// Config document of one (service, node), rendered from the canonical service
// model (internal/model BuildService) — data-model.md §13, contracts/
// reconciliation.md Rule 11, FR-029, FR-030, FR-031, FR-017.
//
// subinterface.go builds the service-owned subinterfaces of access ports and
// their /acl/interface interface-ref, vlan.go the bridge domain every `vlan`
// and `mac-vrf` shares, macvrf.go the EVPN mac-vrf and its anycast gateway
// (irb0.<vlan>), ipvrf.go the routed instance with its interface-less Type-5
// EVPN instance, and vxlan_service.go the vxlan-interfaces under the fabric's
// tunnel-interface vxlan0 and the bgp-evpn / bgp-vpn instances.
//
// A service render writes no port-level leaf — no /interface[name=<port>]/
// admin-state, vlan-tagging or mtu — and none of irb0's own: those are the
// fabric Config's (T039). Every interface entry it emits carries only its key
// and the subinterface[index] it owns, and every subinterface it creates
// brings /acl/interface[interface-id=<port>.<idx>]/interface-ref, filter or
// none, so a standalone `acl` binding beneath it shares no leaf with it
// (FR-015, AD-68).

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"

	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/pkg/register"
)

// Module names of the service subtrees that come from another module than
// their parent (RFC 7951 member names use the module name; evidence/
// 02-evpn-constructs.md §0).
const (
	modInterfacesNbr     = "srl_nokia-interfaces-nbr"
	modInterfacesNbrEVPN = "srl_nokia-interfaces-nbr-evpn"
	modBGPEVPN           = "srl_nokia-bgp-evpn"
	modBGPVPN            = "srl_nokia-bgp-vpn"
	modACL               = "srl_nokia-acl"
)

// UnsupportedError is returned when a service node carries a construct this
// renderer does not render yet: access-list filters and their input/output
// bindings are User Story 5's renderer (internal/render/srl/acl). The
// reconciler maps it to Rendered=False/UnsupportedFeature.
type UnsupportedError struct {
	Node string
	// Filters names every filter the node carries, as `<name>[type=<type>]`.
	Filters []string
}

func (e *UnsupportedError) Error() string {
	return fmt.Sprintf("render service node %s: access list(s) %s cannot be rendered yet: access-list rendering (filters and their input/output bindings) arrives with User Story 5",
		e.Node, strings.Join(e.Filters, ", "))
}

// RenderService renders the priority-20 service Config document of every node
// of m, keyed by node name.
func RenderService(m *model.ServiceModel) (map[string]*Rendered, error) {
	if m == nil {
		return nil, fmt.Errorf("render service: nil model")
	}
	out := make(map[string]*Rendered, len(m.Nodes))
	for i := range m.Nodes {
		r, err := RenderServiceNode(&m.Nodes[i])
		if err != nil {
			return nil, err
		}
		if _, dup := out[r.Node]; dup {
			return nil, fmt.Errorf("render service %s: node %s appears twice", m.ServiceID, r.Node)
		}
		out[r.Node] = r
	}
	return out, nil
}

// RenderServiceNode renders the service Config document of one node: the
// service's subinterfaces (bridged or routed, with their VLAN and addresses),
// irb0.<vlan> with its anycast gateway, the vxlan-interfaces under vxlan0, the
// mac-vrf / ip-vrf network-instances with their EVPN and BGP-VPN instances and
// explicit route targets, and the interface-ref of every owned subinterface.
//
// A node carrying an access-list filter or a filter binding is refused with an
// *UnsupportedError. Before returning, every leaf path of the document is
// checked against the entries the service Config may write (FR-017); an
// uncovered path is a *register.UncoveredError (Rendered=False/RegisterUncovered).
func RenderServiceNode(n *model.ServiceNode) (*Rendered, error) {
	if n == nil || n.Node == "" {
		return nil, fmt.Errorf("render service node: node without a name")
	}
	doc, err := serviceTree(n)
	if err != nil {
		return nil, err
	}
	paths, err := leafPaths(doc)
	if err != nil {
		return nil, fmt.Errorf("render service node %s: %w", n.Node, err)
	}
	if err := register.CheckServicePaths(n.Node, paths); err != nil {
		return nil, err
	}
	js, err := canonicalJSON(doc)
	if err != nil {
		return nil, fmt.Errorf("render service node %s: %w", n.Node, err)
	}
	sum := sha256.Sum256(js)
	return &Rendered{Node: n.Node, JSON: js, Hash: hex.EncodeToString(sum[:])}, nil
}

// ServiceLeafPaths returns, sorted, the concrete leaf paths of the document
// RenderServiceNode emits for n, with the module qualification of node names
// removed (identityref key values are kept as rendered). Paths of list entries
// that carry only their keys are included.
func ServiceLeafPaths(n *model.ServiceNode) ([]string, error) {
	if n == nil || n.Node == "" {
		return nil, fmt.Errorf("service leaf paths: node without a name")
	}
	doc, err := serviceTree(n)
	if err != nil {
		return nil, err
	}
	return leafPaths(doc)
}

func serviceTree(n *model.ServiceNode) (container, error) {
	if err := unsupported(n); err != nil {
		return nil, err
	}
	doc := container{}
	if ifs := renderServiceInterfaces(n); ifs != nil {
		doc[modInterfaces+":interface"] = ifs
	}
	if t := renderVXLANInterfaces(n); t != nil {
		doc[modTunnelInterfaces+":tunnel-interface"] = t
	}
	nis := newList("name")
	for i := range n.NetworkInstances {
		e, err := renderServiceNI(&n.NetworkInstances[i])
		if err != nil {
			return nil, fmt.Errorf("render service node %s: %w", n.Node, err)
		}
		nis.add(e)
	}
	if len(nis.entries) > 0 {
		doc[modNetworkInstance+":network-instance"] = nis
	}
	if acl := renderInterfaceRefs(n); acl != nil {
		doc[modACL+":acl"] = acl
	}
	if len(doc) == 0 {
		return nil, fmt.Errorf("render service node %s: nothing to render", n.Node)
	}
	return doc, nil
}

// unsupported refuses a node carrying access-list filters or bindings (US5).
func unsupported(n *model.ServiceNode) error {
	set := map[string]bool{}
	for _, f := range n.ACLFilters {
		set[fmt.Sprintf("%s[type=%s]", f.Name, f.Type)] = true
	}
	for _, ai := range n.ACLInterfaces {
		for _, r := range append(append([]model.FilterRef(nil), ai.Input...), ai.Output...) {
			set[fmt.Sprintf("%s[type=%s]", r.Name, r.Type)] = true
		}
	}
	if len(set) == 0 {
		return nil
	}
	names := make([]string, 0, len(set))
	for k := range set {
		names = append(names, k)
	}
	sort.Strings(names)
	return &UnsupportedError{Node: n.Node, Filters: names}
}

// renderServiceNI dispatches on the device's network-instance type.
func renderServiceNI(ni *model.NetworkInstance) (container, error) {
	switch ni.Type {
	case model.MACVRF:
		if ni.VXLANInterface == "" {
			if ni.EVPN != nil || ni.BGPVPN != nil {
				return nil, fmt.Errorf("network-instance %s: an EVPN instance without a vxlan-interface", ni.Name)
			}
			return renderVLANInstance(ni), nil
		}
		return renderMACVRF(ni)
	case model.IPVRF:
		return renderIPVRF(ni)
	}
	return nil, fmt.Errorf("network-instance %s: type %q is not rendered by a service", ni.Name, ni.Type)
}
