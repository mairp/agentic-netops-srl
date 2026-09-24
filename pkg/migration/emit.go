package migration

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// The emitted object. Field names and JSON tags are exactly those of api/fabric/v1alpha1
// (network_types.go) — a test decodes every emitted object strictly into fabricv1.Network — and the
// struct field order is the emission order of contracts/network-spec.md §3, so the JSON form (the
// sidecar's "manifests") and the YAML form (written by hand below) carry keys in one order.
// Empty and zero-valued fields are omitted. There is no route-distinguisher field anywhere (RD-09).
// No namespace and no labels: the deployer stamps those (FR-101).

// Network is the emitted fabric intent object.
type Network struct {
	APIVersion string      `json:"apiVersion"`
	Kind       string      `json:"kind"`
	Metadata   Metadata    `json:"metadata"`
	Spec       NetworkSpec `json:"spec"`
}

// Metadata carries the name and the translator's annotations.
type Metadata struct {
	Name        string            `json:"name"`
	Annotations map[string]string `json:"annotations"`
}

// NetworkSpec: description, vlans, bridgeDomains, routers, accessLists (arrives with T110), attachments.
type NetworkSpec struct {
	Description   string         `json:"description,omitempty"`
	VLANs         []NetworkVLAN  `json:"vlans,omitempty"`
	BridgeDomains []BridgeDomain `json:"bridgeDomains,omitempty"`
	Routers       []Router       `json:"routers,omitempty"`
	Attachments   []Attachment   `json:"attachments"`
}

// NetworkVLAN is a local broadcast domain (spec.vlans[]).
type NetworkVLAN struct {
	Name string `json:"name"`
	VLAN int64  `json:"vlan"`
}

// BridgeDomain is a mac-vrf (spec.bridgeDomains[]): name, vlan, l2vni, evpn, irb.
type BridgeDomain struct {
	Name  string `json:"name"`
	VLAN  int64  `json:"vlan"`
	L2VNI int64  `json:"l2vni"`
	EVPN  *EVPN  `json:"evpn,omitempty"`
	IRB   *IRB   `json:"irb,omitempty"`
}

// EVPN carries the bridge domain's derived route targets.
type EVPN struct {
	RouteTargets *RouteTargets `json:"routeTargets,omitempty"`
}

// RouteTargets are derived: target:<fabricASN>:<vni>.
type RouteTargets struct {
	Import []string `json:"import,omitempty"`
	Export []string `json:"export,omitempty"`
}

// IRB is a mac-vrf's anycast gateway into its own router.
type IRB struct {
	VRF         string `json:"vrf"`
	GatewayIPv4 string `json:"gatewayIPv4,omitempty"`
	GatewayIPv6 string `json:"gatewayIPv6,omitempty"`
}

// Router is an ip-vrf (spec.routers[]): name, routeTargets, l3vni, prefixes. No rd.
type Router struct {
	Name         string        `json:"name"`
	RouteTargets *RouteTargets `json:"routeTargets,omitempty"`
	L3VNI        int64         `json:"l3vni"`
	Prefixes     []string      `json:"prefixes,omitempty"`
}

// Attachment: node, attachment, vlan, vrf.
type Attachment struct {
	Node       string `json:"node"`
	Attachment string `json:"attachment"`
	VLAN       *int64 `json:"vlan,omitempty"`
	VRF        string `json:"vrf,omitempty"`
}

// JSON is the object as JSON, keys in emission order (annotation keys sorted, as JSON maps are).
func (n Network) JSON() json.RawMessage {
	b, err := json.Marshal(n)
	if err != nil {
		panic(fmt.Sprintf("migration: marshalling an emitted Network failed: %v", err))
	}
	return b
}

// YAML is the object as one YAML document in the fixed key order of network-spec.md §3.
func (n Network) YAML() string {
	w := &yamlWriter{}
	w.kv(0, "apiVersion", n.APIVersion)
	w.kv(0, "kind", n.Kind)
	w.line(0, "metadata:")
	w.kv(1, "name", n.Metadata.Name)
	w.line(1, "annotations:")
	for _, k := range annotationOrder {
		if v, ok := n.Metadata.Annotations[k]; ok {
			w.kv(2, k, v)
		}
	}
	w.b.WriteString(n.Spec.YAML())
	return w.b.String()
}

// YAML is the `spec:` block alone — what the golden files hold, byte for byte.
func (s NetworkSpec) YAML() string {
	w := &yamlWriter{}
	w.line(0, "spec:")
	if s.Description != "" {
		w.kv(1, "description", s.Description)
	}
	if len(s.VLANs) > 0 {
		w.line(1, "vlans:")
		for _, v := range s.VLANs {
			w.item(1, "name", v.Name)
			w.num(2, "vlan", v.VLAN)
		}
	}
	if len(s.BridgeDomains) > 0 {
		w.line(1, "bridgeDomains:")
		for _, bd := range s.BridgeDomains {
			w.item(1, "name", bd.Name)
			w.num(2, "vlan", bd.VLAN)
			w.num(2, "l2vni", bd.L2VNI)
			if bd.EVPN != nil && bd.EVPN.RouteTargets != nil {
				w.line(2, "evpn:")
				w.routeTargets(3, bd.EVPN.RouteTargets)
			}
			if bd.IRB != nil {
				w.line(2, "irb:")
				w.kv(3, "vrf", bd.IRB.VRF)
				if bd.IRB.GatewayIPv4 != "" {
					w.kv(3, "gatewayIPv4", bd.IRB.GatewayIPv4)
				}
				if bd.IRB.GatewayIPv6 != "" {
					w.kv(3, "gatewayIPv6", bd.IRB.GatewayIPv6)
				}
			}
		}
	}
	if len(s.Routers) > 0 {
		w.line(1, "routers:")
		for _, r := range s.Routers {
			w.item(1, "name", r.Name)
			if r.RouteTargets != nil {
				w.routeTargets(2, r.RouteTargets)
			}
			w.num(2, "l3vni", r.L3VNI)
			if len(r.Prefixes) > 0 {
				w.line(2, "prefixes:")
				for _, p := range r.Prefixes {
					w.line(2, "- "+scalar(p))
				}
			}
		}
	}
	w.line(1, "attachments:")
	for _, a := range s.Attachments {
		w.item(1, "node", a.Node)
		w.kv(2, "attachment", a.Attachment)
		if a.VLAN != nil {
			w.num(2, "vlan", *a.VLAN)
		}
		if a.VRF != "" {
			w.kv(2, "vrf", a.VRF)
		}
	}
	return w.b.String()
}

type yamlWriter struct{ b strings.Builder }

func (w *yamlWriter) line(depth int, s string) {
	w.b.WriteString(strings.Repeat("  ", depth))
	w.b.WriteString(s)
	w.b.WriteByte('\n')
}

func (w *yamlWriter) kv(depth int, k, v string) { w.line(depth, k+": "+scalar(v)) }

func (w *yamlWriter) num(depth int, k string, v int64) {
	w.line(depth, k+": "+strconv.FormatInt(v, 10))
}

// item opens a list entry at depth (the dash at depth's indentation, as kubectl writes lists).
func (w *yamlWriter) item(depth int, k, v string) { w.line(depth, "- "+k+": "+scalar(v)) }

func (w *yamlWriter) routeTargets(depth int, rt *RouteTargets) {
	w.line(depth, "routeTargets:")
	for _, l := range []struct {
		k string
		v []string
	}{{"import", rt.Import}, {"export", rt.Export}} {
		if len(l.v) == 0 {
			continue
		}
		w.line(depth+1, l.k+":")
		for _, t := range l.v {
			w.line(depth+1, "- "+quoted(t))
		}
	}
}

// plainSafe is the conservative set of strings written unquoted: they start with a letter or digit,
// hold no character YAML gives meaning to (no ": ", no " #", no flow indicators), and do not end in a
// colon. Everything else — and anything YAML 1.1 or 1.2 would read as a number, boolean or null —
// is double-quoted, JSON-escaped (a JSON string is a valid YAML double-quoted scalar).
var (
	plainSafe   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9 ._/:()+@-]*$`)
	numberLike  = regexp.MustCompile(`^[-+]?(\.[0-9]+|[0-9][0-9_]*(\.[0-9_]*)?)([eE][-+]?[0-9]+)?$|^0[xob][0-9a-fA-F_]+$|^[0-9][0-9_]*(:[0-5]?[0-9])+(\.[0-9_]*)?$`)
	yamlLiteral = map[string]bool{"y": true, "n": true, "yes": true, "no": true, "true": true, "false": true,
		"on": true, "off": true, "null": true, "~": true}
)

func scalar(s string) string {
	if s == "" || !plainSafe.MatchString(s) || strings.Contains(s, ": ") || strings.HasSuffix(s, ":") ||
		strings.HasSuffix(s, " ") || numberLike.MatchString(s) || yamlLiteral[strings.ToLower(s)] {
		return quoted(s)
	}
	return s
}

func quoted(s string) string {
	var b strings.Builder
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(s)
	return strings.TrimSuffix(b.String(), "\n")
}
