// Package fabricapi is the typed read side of the first-party fabric API
// (fabric.agentic-netops.io/v1alpha1) — the only consumer-facing view of the API group
// (contracts/network-spec.md §4, data-model.md §12).
//
// A Network wraps the object as the API server returned it (an unstructured map). The five
// accessors keep the tolerance discipline of the contract: an unknown shape yields nil and a
// mistyped field is omitted — left at its zero value — rather than failing the decode, because
// the CRD is the source of truth and this client must not drift from it.
package fabricapi

import (
	"encoding/json"
	"math"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// Network is a read-only view of a fabric.agentic-netops.io/v1alpha1 Network.
type Network struct {
	// Object is the object as decoded from JSON or YAML: apiVersion, kind, metadata, spec, status.
	Object map[string]any
}

// New wraps a decoded object. A nil map yields a Network whose accessors all return nil.
func New(obj map[string]any) *Network { return &Network{Object: obj} }

// FromUnstructured wraps an unstructured object.
func FromUnstructured(u *unstructured.Unstructured) *Network {
	if u == nil {
		return &Network{}
	}
	return &Network{Object: u.Object}
}

// NetworkVLAN is a spec.vlans[] entry — a local VLAN, the vlan construct.
type NetworkVLAN struct {
	Name string
	VLAN int64
}

// RouteTargets are the explicitly rendered, derived route targets target:<fabricASN>:<vni>.
type RouteTargets struct {
	Import []string
	Export []string
}

// EVPNSpec is the EVPN half of a bridge domain.
type EVPNSpec struct {
	RouteTargets RouteTargets
}

// IRBSpec is the anycast gateway of a mac-vrf.
type IRBSpec struct {
	VRF         string
	GatewayIPv4 string
	GatewayIPv6 string
}

// BridgeDomain is a spec.bridgeDomains[] entry — the mac-vrf construct.
type BridgeDomain struct {
	Name  string
	VLAN  int64
	L2VNI int64
	EVPN  EVPNSpec
	IRB   *IRBSpec
}

// NetworkRouter is a spec.routers[] entry. It has no route-distinguisher field: the device
// derives it.
type NetworkRouter struct {
	Name         string
	L3VNI        int64
	RouteTargets RouteTargets
	Prefixes     []string
}

// ACLRule is one ordered rule of an access list.
type ACLRule struct {
	Name              string
	Priority          int64
	Action            string
	Protocol          string
	SourcePrefix      string
	DestinationPrefix string
	SourcePort        string
	DestinationPort   string
	Description       string
}

// AccessList is a spec.accessLists[] entry.
type AccessList struct {
	Name          string
	Stage         string
	Type          string
	DefaultAction string
	Rules         []ACLRule
}

// NetworkAttachment is a spec.attachments[] entry. VLAN is nil for the untagged subinterface.
type NetworkAttachment struct {
	Node       string
	Attachment string
	VRF        string
	VLAN       *int64
}

// VLANs returns spec.vlans.
func (n *Network) VLANs() []NetworkVLAN {
	items := n.list("vlans")
	if items == nil {
		return nil
	}
	out := make([]NetworkVLAN, 0, len(items))
	for _, m := range items {
		v := NetworkVLAN{Name: str(m, "name")}
		v.VLAN, _ = integer(m, "vlan")
		out = append(out, v)
	}
	return out
}

// BridgeDomains returns spec.bridgeDomains.
func (n *Network) BridgeDomains() []BridgeDomain {
	items := n.list("bridgeDomains")
	if items == nil {
		return nil
	}
	out := make([]BridgeDomain, 0, len(items))
	for _, m := range items {
		b := BridgeDomain{Name: str(m, "name")}
		b.VLAN, _ = integer(m, "vlan")
		b.L2VNI, _ = integer(m, "l2vni")
		if evpn, ok := m["evpn"].(map[string]any); ok {
			b.EVPN.RouteTargets = routeTargets(evpn)
		}
		if irb, ok := m["irb"].(map[string]any); ok {
			b.IRB = &IRBSpec{
				VRF:         str(irb, "vrf"),
				GatewayIPv4: str(irb, "gatewayIPv4"),
				GatewayIPv6: str(irb, "gatewayIPv6"),
			}
		}
		out = append(out, b)
	}
	return out
}

// Routers returns spec.routers.
func (n *Network) Routers() []NetworkRouter {
	items := n.list("routers")
	if items == nil {
		return nil
	}
	out := make([]NetworkRouter, 0, len(items))
	for _, m := range items {
		r := NetworkRouter{Name: str(m, "name"), RouteTargets: routeTargets(m), Prefixes: strings(m, "prefixes")}
		r.L3VNI, _ = integer(m, "l3vni")
		out = append(out, r)
	}
	return out
}

// AccessLists returns spec.accessLists.
func (n *Network) AccessLists() []AccessList {
	items := n.list("accessLists")
	if items == nil {
		return nil
	}
	out := make([]AccessList, 0, len(items))
	for _, m := range items {
		a := AccessList{
			Name:          str(m, "name"),
			Stage:         str(m, "stage"),
			Type:          str(m, "type"),
			DefaultAction: str(m, "defaultAction"),
		}
		if rules, ok := m["rules"].([]any); ok {
			a.Rules = make([]ACLRule, 0, len(rules))
			for _, ri := range rules {
				rm, ok := ri.(map[string]any)
				if !ok {
					continue
				}
				r := ACLRule{
					Name:              str(rm, "name"),
					Action:            str(rm, "action"),
					Protocol:          str(rm, "protocol"),
					SourcePrefix:      str(rm, "sourcePrefix"),
					DestinationPrefix: str(rm, "destinationPrefix"),
					SourcePort:        str(rm, "sourcePort"),
					DestinationPort:   str(rm, "destinationPort"),
					Description:       str(rm, "description"),
				}
				r.Priority, _ = integer(rm, "priority")
				a.Rules = append(a.Rules, r)
			}
		}
		out = append(out, a)
	}
	return out
}

// Attachments returns spec.attachments.
func (n *Network) Attachments() []NetworkAttachment {
	items := n.list("attachments")
	if items == nil {
		return nil
	}
	out := make([]NetworkAttachment, 0, len(items))
	for _, m := range items {
		a := NetworkAttachment{Node: str(m, "node"), Attachment: str(m, "attachment"), VRF: str(m, "vrf")}
		if v, ok := integer(m, "vlan"); ok {
			a.VLAN = &v
		}
		out = append(out, a)
	}
	return out
}

// list returns the map entries of spec.<field>; nil when the object, spec or the field is not
// the expected shape. Entries that are not objects are skipped.
func (n *Network) list(field string) []map[string]any {
	if n == nil || n.Object == nil {
		return nil
	}
	spec, ok := n.Object["spec"].(map[string]any)
	if !ok {
		return nil
	}
	raw, ok := spec[field].([]any)
	if !ok {
		return nil
	}
	out := make([]map[string]any, 0, len(raw))
	for _, e := range raw {
		if m, ok := e.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

func routeTargets(m map[string]any) RouteTargets {
	rt, ok := m["routeTargets"].(map[string]any)
	if !ok {
		return RouteTargets{}
	}
	return RouteTargets{Import: strings(rt, "import"), Export: strings(rt, "export")}
}

func str(m map[string]any, key string) string {
	s, _ := m[key].(string)
	return s
}

// strings returns the string entries of a list field, omitting entries of another type.
func strings(m map[string]any, key string) []string {
	raw, ok := m[key].([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(raw))
	for _, e := range raw {
		if s, ok := e.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

// integer reads a whole number in any of the forms a JSON or YAML decoder produces; a
// non-integral or non-numeric value is reported absent.
func integer(m map[string]any, key string) (int64, bool) {
	switch v := m[key].(type) {
	case int64:
		return v, true
	case int:
		return int64(v), true
	case int32:
		return int64(v), true
	case uint32:
		return int64(v), true
	case float64:
		if v == math.Trunc(v) && !math.IsInf(v, 0) && math.Abs(v) < 1<<53 {
			return int64(v), true
		}
	case json.Number:
		if i, err := v.Int64(); err == nil {
			return i, true
		}
	}
	return 0, false
}
