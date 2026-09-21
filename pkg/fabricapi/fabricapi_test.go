package fabricapi_test

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/yaml"

	"github.com/mairp/agentic-netops-srl/pkg/fabricapi"
)

// exemplar is contracts/network-spec.md §6 — a mac-vrf with an anycast gateway and an ingress
// access list — plus the other shapes of §1.
const exemplar = `
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
metadata: {name: migr-4b7e19c2a05d3f6, namespace: agentic-netops-intent}
spec:
  description: Service 4b7e19c2a05d3f6 (mac-vrf)
  bridgeDomains:
  - name: bd-4b7e19c2a05d3f6
    vlan: 100
    l2vni: 10021
    evpn: {routeTargets: {import: ["target:65000:10021"], export: ["target:65000:10021"]}}
    irb: {vrf: vrf-4b7e19c2a05d3f6, gatewayIPv4: 10.10.0.1/24, gatewayIPv6: "2001:db8:10::1/64"}
  routers:
  - name: vrf-4b7e19c2a05d3f6
    routeTargets: {import: ["target:65000:10022"], export: ["target:65000:10022"]}
    l3vni: 10022
    prefixes: ["10.10.0.0/24", "2001:db8:10::/64"]
  accessLists:
  - name: acl-4b7e19c2a05d3f6-ingress
    stage: ingress
    type: ipv4
    defaultAction: deny
    rules:
    - {name: allow-https, priority: 100, action: permit, protocol: tcp, sourcePrefix: 10.0.0.0/24, destinationPort: "443", description: operator https allowance}
  attachments:
  - {node: leaf01, attachment: ethernet-1/1, vlan: 100}
  - {node: leaf02, attachment: ethernet-1/1}
`

func decode(t *testing.T, doc string) *fabricapi.Network {
	t.Helper()
	obj := map[string]any{}
	if err := yaml.Unmarshal([]byte(doc), &obj); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return fabricapi.New(obj)
}

func i64(v int64) *int64 { return &v }

func TestAccessorsOnExemplar(t *testing.T) {
	n := decode(t, exemplar)
	tests := []struct {
		name string
		got  any
		want any
	}{
		{"VLANs absent is nil", n.VLANs(), []fabricapi.NetworkVLAN(nil)},
		{"BridgeDomains", n.BridgeDomains(), []fabricapi.BridgeDomain{{
			Name: "bd-4b7e19c2a05d3f6", VLAN: 100, L2VNI: 10021,
			EVPN: fabricapi.EVPNSpec{RouteTargets: fabricapi.RouteTargets{Import: []string{"target:65000:10021"}, Export: []string{"target:65000:10021"}}},
			IRB:  &fabricapi.IRBSpec{VRF: "vrf-4b7e19c2a05d3f6", GatewayIPv4: "10.10.0.1/24", GatewayIPv6: "2001:db8:10::1/64"},
		}}},
		{"Routers", n.Routers(), []fabricapi.NetworkRouter{{
			Name: "vrf-4b7e19c2a05d3f6", L3VNI: 10022,
			RouteTargets: fabricapi.RouteTargets{Import: []string{"target:65000:10022"}, Export: []string{"target:65000:10022"}},
			Prefixes:     []string{"10.10.0.0/24", "2001:db8:10::/64"},
		}}},
		{"AccessLists", n.AccessLists(), []fabricapi.AccessList{{
			Name: "acl-4b7e19c2a05d3f6-ingress", Stage: "ingress", Type: "ipv4", DefaultAction: "deny",
			Rules: []fabricapi.ACLRule{{Name: "allow-https", Priority: 100, Action: "permit", Protocol: "tcp",
				SourcePrefix: "10.0.0.0/24", DestinationPort: "443", Description: "operator https allowance"}},
		}}},
		{"Attachments", n.Attachments(), []fabricapi.NetworkAttachment{
			{Node: "leaf01", Attachment: "ethernet-1/1", VLAN: i64(100)},
			{Node: "leaf02", Attachment: "ethernet-1/1"},
		}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if !reflect.DeepEqual(tc.got, tc.want) {
				t.Fatalf("got  %#v\nwant %#v", tc.got, tc.want)
			}
		})
	}
}

func TestVLANsAndIPVRF(t *testing.T) {
	tests := []struct {
		name      string
		doc       string
		wantVLANs []fabricapi.NetworkVLAN
		wantAtt   []fabricapi.NetworkAttachment
		wantRtrs  int
	}{
		{
			name:      "vlan construct",
			doc:       `{spec: {vlans: [{name: vlan-a, vlan: 110}], attachments: [{node: leaf01, attachment: ethernet-1/1, vlan: 110}]}}`,
			wantVLANs: []fabricapi.NetworkVLAN{{Name: "vlan-a", VLAN: 110}},
			wantAtt:   []fabricapi.NetworkAttachment{{Node: "leaf01", Attachment: "ethernet-1/1", VLAN: i64(110)}},
		},
		{
			name:     "ip-vrf, tagged and untagged",
			doc:      `{spec: {routers: [{name: vrf-a, l3vni: 10030}], attachments: [{node: leaf01, attachment: ethernet-1/1, vlan: 200, vrf: vrf-a}, {node: leaf02, attachment: ethernet-1/2, vrf: vrf-a}]}}`,
			wantRtrs: 1,
			wantAtt: []fabricapi.NetworkAttachment{
				{Node: "leaf01", Attachment: "ethernet-1/1", VLAN: i64(200), VRF: "vrf-a"},
				{Node: "leaf02", Attachment: "ethernet-1/2", VRF: "vrf-a"},
			},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			n := decode(t, tc.doc)
			if got := n.VLANs(); !reflect.DeepEqual(got, tc.wantVLANs) {
				t.Errorf("VLANs: got %#v want %#v", got, tc.wantVLANs)
			}
			if got := n.Attachments(); !reflect.DeepEqual(got, tc.wantAtt) {
				t.Errorf("Attachments: got %#v want %#v", got, tc.wantAtt)
			}
			if got := len(n.Routers()); got != tc.wantRtrs {
				t.Errorf("Routers: got %d want %d", got, tc.wantRtrs)
			}
		})
	}
}

// TestTolerance: an unknown shape yields nil and a mistyped field is omitted rather than
// failing the decode (contracts/network-spec.md §4).
func TestTolerance(t *testing.T) {
	tests := []struct {
		name  string
		obj   map[string]any
		check func(t *testing.T, n *fabricapi.Network)
	}{
		{"nil object", nil, func(t *testing.T, n *fabricapi.Network) { allNil(t, n) }},
		{"spec not a map", map[string]any{"spec": "nope"}, func(t *testing.T, n *fabricapi.Network) { allNil(t, n) }},
		{"lists not lists", map[string]any{"spec": map[string]any{
			"vlans": "x", "bridgeDomains": 3, "routers": map[string]any{}, "accessLists": true, "attachments": "y",
		}}, func(t *testing.T, n *fabricapi.Network) { allNil(t, n) }},
		{"non-object entries skipped", map[string]any{"spec": map[string]any{
			"vlans": []any{"junk", map[string]any{"name": "v", "vlan": int64(120)}},
		}}, func(t *testing.T, n *fabricapi.Network) {
			want := []fabricapi.NetworkVLAN{{Name: "v", VLAN: 120}}
			if got := n.VLANs(); !reflect.DeepEqual(got, want) {
				t.Fatalf("got %#v want %#v", got, want)
			}
		}},
		{"mistyped fields omitted", map[string]any{"spec": map[string]any{
			"bridgeDomains": []any{map[string]any{"name": 7, "vlan": "100", "l2vni": 10021.5, "evpn": "x", "irb": "y"}},
			"routers":       []any{map[string]any{"name": "r", "l3vni": json.Number("10022"), "prefixes": []any{"10.0.0.0/24", 5}, "rd": "65000:1"}},
			"accessLists":   []any{map[string]any{"name": "a", "rules": []any{"bad", map[string]any{"name": "r1", "priority": "high"}}}},
			"attachments":   []any{map[string]any{"node": "leaf01", "attachment": "ethernet-1/1", "vlan": "100"}},
		}}, func(t *testing.T, n *fabricapi.Network) {
			if got, want := n.BridgeDomains(), []fabricapi.BridgeDomain{{}}; !reflect.DeepEqual(got, want) {
				t.Errorf("BridgeDomains: got %#v want %#v", got, want)
			}
			if got, want := n.Routers(), []fabricapi.NetworkRouter{{Name: "r", L3VNI: 10022, Prefixes: []string{"10.0.0.0/24"}}}; !reflect.DeepEqual(got, want) {
				t.Errorf("Routers: got %#v want %#v", got, want)
			}
			if got, want := n.AccessLists(), []fabricapi.AccessList{{Name: "a", Rules: []fabricapi.ACLRule{{Name: "r1"}}}}; !reflect.DeepEqual(got, want) {
				t.Errorf("AccessLists: got %#v want %#v", got, want)
			}
			if got, want := n.Attachments(), []fabricapi.NetworkAttachment{{Node: "leaf01", Attachment: "ethernet-1/1"}}; !reflect.DeepEqual(got, want) {
				t.Errorf("Attachments: got %#v want %#v", got, want)
			}
		}},
		{"integer forms", map[string]any{"spec": map[string]any{
			"vlans": []any{
				map[string]any{"name": "a", "vlan": int(101)},
				map[string]any{"name": "b", "vlan": int32(102)},
				map[string]any{"name": "c", "vlan": float64(103)},
				map[string]any{"name": "d", "vlan": json.Number("104")},
			},
		}}, func(t *testing.T, n *fabricapi.Network) {
			want := []fabricapi.NetworkVLAN{{"a", 101}, {"b", 102}, {"c", 103}, {"d", 104}}
			if got := n.VLANs(); !reflect.DeepEqual(got, want) {
				t.Fatalf("got %#v want %#v", got, want)
			}
		}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) { tc.check(t, fabricapi.New(tc.obj)) })
	}
}

func allNil(t *testing.T, n *fabricapi.Network) {
	t.Helper()
	if n.VLANs() != nil || n.BridgeDomains() != nil || n.Routers() != nil || n.AccessLists() != nil || n.Attachments() != nil {
		t.Fatalf("an unknown shape must yield nil from every accessor")
	}
}

func TestFromUnstructured(t *testing.T) {
	u := &unstructured.Unstructured{Object: map[string]any{"spec": map[string]any{
		"vlans": []any{map[string]any{"name": "v", "vlan": int64(130)}},
	}}}
	if got := fabricapi.FromUnstructured(u).VLANs(); len(got) != 1 || got[0].VLAN != 130 {
		t.Fatalf("got %#v", got)
	}
	if fabricapi.FromUnstructured(nil).VLANs() != nil {
		t.Fatal("nil unstructured must yield nil")
	}
	var nilNet *fabricapi.Network
	if nilNet.Attachments() != nil {
		t.Fatal("nil *Network must yield nil")
	}
}

// TestNoRouteDistinguisher: NetworkRouter has no route-distinguisher field (§4).
func TestNoRouteDistinguisher(t *testing.T) {
	rt := reflect.TypeOf(fabricapi.NetworkRouter{})
	for i := 0; i < rt.NumField(); i++ {
		name := strings.ToLower(rt.Field(i).Name)
		if name == "rd" || strings.Contains(name, "distinguisher") {
			t.Fatalf("NetworkRouter carries a route-distinguisher field %q", rt.Field(i).Name)
		}
	}
}
