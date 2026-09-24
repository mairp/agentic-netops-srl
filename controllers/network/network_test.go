package network

import (
	"strings"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/model"
)

func vlanPtr(v int64) *fabricv1.AttachmentVLAN { a := fabricv1.AttachmentVLAN(v); return &a }

// A service document: one tagged bridged subinterface, its interface-ref and one mac-vrf.
func svcDoc(vlan, ni string) string {
	return `{
 "srl_nokia-interfaces:interface": [{"name": "ethernet-1/1", "subinterface": [{"index": ` + vlan + `, "type": "srl_nokia-interfaces:bridged", "admin-state": "enable",
   "srl_nokia-interfaces-vlans:vlan": {"encap": {"single-tagged": {"vlan-id": ` + vlan + `}}}}]}],
 "srl_nokia-network-instance:network-instance": [{"name": "` + ni + `", "type": "srl_nokia-network-instance:mac-vrf", "admin-state": "enable",
   "interface": [{"name": "ethernet-1/1.` + vlan + `"}]}],
 "srl_nokia-acl:acl": {"interface": [{"interface-id": "ethernet-1/1.` + vlan + `", "interface-ref": {"interface": "ethernet-1/1", "subinterface": ` + vlan + `}}]}
}`
}

// Non-key leaf paths (AD-68): two tagged services on one access port share no leaf; a
// key-only list entry contributes none; the same subinterface written twice does.
func TestNonKeyLeafPaths(t *testing.T) {
	a, err := NonKeyLeafPaths([]byte(svcDoc("100", "vlan-a")))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := NonKeyLeafPaths([]byte(svcDoc("200", "vlan-b")))
	want := "/interface[name=ethernet-1/1]/subinterface[index=100]/admin-state"
	if !containsPath(a, want) {
		t.Fatalf("%s missing from %v", want, a)
	}
	for _, p := range a {
		if strings.HasSuffix(p, "]") {
			t.Errorf("key-only path %s counted as a leaf", p)
		}
		if containsPath(b, p) {
			t.Errorf("two tagged services on one port share %s", p)
		}
	}
	if !containsPath(a, "/acl/interface[interface-id=ethernet-1/1.100]/interface-ref/subinterface") {
		t.Errorf("interface-ref leaf missing: %v", a)
	}
	same, _ := NonKeyLeafPaths([]byte(svcDoc("100", "vlan-c")))
	if !containsPath(same, want) {
		t.Error("the same subinterface's admin-state must be a shared leaf")
	}
}

func TestNormalizePath(t *testing.T) {
	for in, want := range map[string]string{
		"interface[name=ethernet-1/1]/subinterface[index=100]/admin-state":                                        "/interface[name=ethernet-1/1]/subinterface[index=100]/admin-state",
		"/srl_nokia-interfaces:interface[name=ethernet-1/1]/srl_nokia-interfaces-vlans:vlan/encap":                "/interface[name=ethernet-1/1]/vlan/encap",
		"/network-instance[name=default]/protocols/bgp/afi-safi[afi-safi-name=srl_nokia-common:evpn]/admin-state": "/network-instance[name=default]/protocols/bgp/afi-safi[afi-safi-name=srl_nokia-common:evpn]/admin-state",
	} {
		if got := NormalizePath(in); got != want {
			t.Errorf("NormalizePath(%q) = %q, want %q", in, got, want)
		}
	}
}

// The construct is decided by which lists are present (contracts/network-spec.md §2).
func TestAnalyseConstruct(t *testing.T) {
	att := []fabricv1.NetworkAttachment{{Node: "leaf01", Attachment: "ethernet-1/1", VLAN: vlanPtr(100)}}
	for name, tc := range map[string]struct {
		spec fabricv1.NetworkSpec
		want model.Construct
	}{
		"vlan":    {fabricv1.NetworkSpec{VLANs: []fabricv1.NetworkVLAN{{Name: "v", VLAN: 100}}, Attachments: att}, model.ConstructVLAN},
		"mac-vrf": {fabricv1.NetworkSpec{BridgeDomains: []fabricv1.BridgeDomain{{Name: "b", VLAN: 100, L2VNI: 10001}}, Attachments: att}, model.ConstructMACVRF},
		"ip-vrf":  {fabricv1.NetworkSpec{Routers: []fabricv1.NetworkRouter{{Name: "r", L3VNI: 10002}}, Attachments: att}, model.ConstructIPVRF},
		"acl":     {fabricv1.NetworkSpec{AccessLists: []fabricv1.AccessList{{Name: "a", Stage: "ingress", Type: "ipv4"}}, Attachments: att}, model.ConstructACL},
	} {
		in, err := analyse(&fabricv1.Network{Spec: tc.spec})
		if err != nil || in.construct != tc.want {
			t.Errorf("%s: construct %v err %v", name, in, err)
		}
	}
}

// The claim profile: VNIs always, VLANs only in the allocation band and only from vlans[] /
// bridgeDomains[] (AD-33, AD-51); an ip-vrf attachment's allocation-band VLAN is a conflict by
// construction; an accessLists-only object is outside the band rule (AD-47).
func TestCarriedValuesAndBandGate(t *testing.T) {
	n := &fabricv1.Network{ObjectMeta: metav1.ObjectMeta{Namespace: "ns", Name: "svc"}, Spec: fabricv1.NetworkSpec{
		BridgeDomains: []fabricv1.BridgeDomain{{Name: "bd", VLAN: 1500, L2VNI: 10001, IRB: &fabricv1.IRBSpec{VRF: "vrf", GatewayIPv4: "10.0.0.1/24"}}},
		Routers:       []fabricv1.NetworkRouter{{Name: "vrf", L3VNI: 10002}},
	}}
	var got []string
	for _, c := range carriedValues(n) {
		got = append(got, ClaimName(n.Namespace, n.Name, c.role))
	}
	want := "ns.svc.vlan-bd ns.svc.l2vni-bd ns.svc.l3vni-vrf"
	if strings.Join(got, " ") != want {
		t.Errorf("carried %v, want %s", got, want)
	}
	n.Spec.BridgeDomains[0].VLAN = 200
	if len(carriedValues(n)) != 2 {
		t.Error("a naming-band VLAN needs no claim")
	}
	ip := &fabricv1.Network{Spec: fabricv1.NetworkSpec{Routers: []fabricv1.NetworkRouter{{Name: "r", L3VNI: 10002}},
		Attachments: []fabricv1.NetworkAttachment{{Node: "leaf01", Attachment: "ethernet-1/1", VLAN: vlanPtr(1500), VRF: "r"}}}}
	if c := ipvrfBandConflicts(ip); len(c) != 1 || !strings.Contains(c[0], "1500") || !strings.Contains(c[0], "100–999") || !strings.Contains(c[0], "1000–4000") {
		t.Errorf("ip-vrf 1500: %v", c)
	}
	ip.Spec.Attachments[0].VLAN = vlanPtr(200)
	if c := ipvrfBandConflicts(ip); len(c) != 0 {
		t.Errorf("ip-vrf 200: %v", c)
	}
	acl := &fabricv1.Network{Spec: fabricv1.NetworkSpec{AccessLists: []fabricv1.AccessList{{Name: "a"}},
		Attachments: []fabricv1.NetworkAttachment{{Node: "leaf01", Attachment: "ethernet-1/1", VLAN: vlanPtr(1500)}}}}
	if !isACLOnly(acl) || len(carriedValues(acl)) != 0 {
		t.Error("an accessLists-only object carries no claimed value")
	}
}

func TestServiceID(t *testing.T) {
	for in, want := range map[string]string{"migr-4b7e19c2a05d3f6": "4b7e19c2a05d3f6", "svc-a": "svc-a"} {
		if got := ServiceID(&fabricv1.Network{ObjectMeta: metav1.ObjectMeta{Name: in}}); got != want {
			t.Errorf("ServiceID(%s) = %s, want %s", in, got, want)
		}
	}
}
