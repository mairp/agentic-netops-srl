package webhook

import (
	"strings"
	"testing"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
)

func vlan(v int64) *fabricv1.AttachmentVLAN { a := fabricv1.AttachmentVLAN(v); return &a }

func att(node, port string, v *fabricv1.AttachmentVLAN) fabricv1.NetworkAttachment {
	return fabricv1.NetworkAttachment{Node: fabricv1.DNSLabel(node), Attachment: fabricv1.PortName(port), VLAN: v}
}

func vlanNet(name string, id int64, atts ...fabricv1.NetworkAttachment) fabricv1.Network {
	return fabricv1.Network{
		ObjectMeta: metav1.ObjectMeta{Namespace: "ns", Name: name},
		Spec: fabricv1.NetworkSpec{
			VLANs:       []fabricv1.NetworkVLAN{{Name: "v", VLAN: fabricv1.VLANID(id)}},
			Attachments: atts,
		},
	}
}

func aclNet(name, stage, typ string, atts ...fabricv1.NetworkAttachment) fabricv1.Network {
	return fabricv1.Network{
		ObjectMeta: metav1.ObjectMeta{Namespace: "ns", Name: name},
		Spec: fabricv1.NetworkSpec{
			AccessLists: []fabricv1.AccessList{{Name: "f", Stage: stage, Type: typ,
				Rules: []fabricv1.ACLRule{{Name: "r", Priority: 10, Action: "permit"}}}},
			Attachments: atts,
		},
	}
}

func testInventory() Inventory {
	return NewInventory([]fabricv1.Fabric{{Spec: fabricv1.FabricSpec{
		Nodes: []fabricv1.FabricNode{{Name: "leaf01", Role: fabricv1.NodeRoleLeaf}, {Name: "leaf02", Role: fabricv1.NodeRoleLeaf}, {Name: "spine01", Role: fabricv1.NodeRoleSpine}},
		Inventory: []fabricv1.InventoryEntry{
			{Node: "leaf01", AccessPorts: []fabricv1.PortName{"ethernet-1/1", "ethernet-1/2"}, UntaggedAccessPorts: []fabricv1.PortName{"ethernet-1/2"}},
			{Node: "leaf02", AccessPorts: []fabricv1.PortName{"ethernet-1/1"}},
			{Node: "spine01", FabricPorts: []fabricv1.PortName{"ethernet-1/1"}},
		},
	}}})
}

func one(t *testing.T, vs []Violation, rule Rule, wants ...string) {
	t.Helper()
	if len(vs) != 1 {
		t.Fatalf("want exactly one %s violation, got %v", rule, vs)
	}
	if vs[0].Rule != rule {
		t.Fatalf("want rule %s, got %v", rule, vs[0])
	}
	for _, w := range wants {
		if !strings.Contains(vs[0].Message, w) {
			t.Errorf("message %q does not contain %q", vs[0].Message, w)
		}
	}
}

func TestResolvable(t *testing.T) {
	inv := testInventory()
	ok := vlanNet("a", 100, att("leaf01", "ethernet-1/1", vlan(100)), att("leaf02", "ethernet-1/1", vlan(100)))
	if vs := CheckResolvable(&ok, inv, "sys"); len(vs) != 0 {
		t.Fatalf("resolvable attachments refused: %v", vs)
	}
	tagged := "leaf01 [ethernet-1/1], leaf02 [ethernet-1/1]"
	untagged := "leaf01 [ethernet-1/2], leaf02 [none]"
	cases := map[string]struct {
		a     fabricv1.NetworkAttachment
		wants []string
	}{
		"spine":            {att("spine01", "ethernet-1/1", vlan(100)), []string{"spine01", "never on a spine", tagged}},
		"unknown node":     {att("leaf09", "ethernet-1/1", vlan(100)), []string{"leaf09", tagged}},
		"fabric port":      {att("leaf01", "ethernet-1/49", vlan(100)), []string{"ethernet-1/49", "not an access port", tagged}},
		"untagged on tag":  {att("leaf01", "ethernet-1/1", nil), []string{"untaggedAccessPorts", "declares untagged", untagged}},
		"tagged on untag":  {att("leaf01", "ethernet-1/2", vlan(100)), []string{"untaggedAccessPorts", "declares tagged", tagged}},
		"unknown untagged": {att("leaf09", "ethernet-1/1", nil), []string{untagged}},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			n := vlanNet("a", 100, c.a)
			one(t, CheckResolvable(&n, inv, "sys"), RuleResolvability, c.wants...)
		})
	}
	t.Run("no fabric", func(t *testing.T) {
		one(t, CheckResolvable(&ok, NewInventory(nil), "sys")[:1], RuleResolvability, "no Fabric exists in sys")
	})
}

func TestOwnerAndMode(t *testing.T) {
	holder := vlanNet("holder", 100, att("leaf01", "ethernet-1/1", vlan(100)))
	cand := vlanNet("cand", 100, att("leaf01", "ethernet-1/1", vlan(100)))
	one(t, CheckOwner(&cand, []fabricv1.Network{holder}), RuleOwner, "leaf01 ethernet-1/1.100", "ns/holder")

	other := vlanNet("cand", 200, att("leaf01", "ethernet-1/1", vlan(200)))
	if vs := CheckOwner(&other, []fabricv1.Network{holder}); len(vs) != 0 {
		t.Fatalf("different vlan refused: %v", vs)
	}
	if vs := CheckTaggingMode(&other, []fabricv1.Network{holder}); len(vs) != 0 {
		t.Fatalf("same mode refused: %v", vs)
	}

	untagged := fabricv1.Network{ObjectMeta: metav1.ObjectMeta{Namespace: "ns", Name: "untagged"},
		Spec: fabricv1.NetworkSpec{Routers: []fabricv1.NetworkRouter{{Name: "r", L3VNI: 5000}},
			Attachments: []fabricv1.NetworkAttachment{{Node: "leaf01", Attachment: "ethernet-1/1", VRF: "r"}}}}
	one(t, CheckTaggingMode(&untagged, []fabricv1.Network{holder}), RuleTaggingMode, "port leaf01 ethernet-1/1", "ns/untagged", "ns/holder", "untagged", "tagged")
	one(t, CheckTaggingMode(&holder, []fabricv1.Network{untagged}), RuleTaggingMode, "ns/holder", "ns/untagged")

	now := metav1.Now()
	deleting := untagged.DeepCopy()
	deleting.DeletionTimestamp = &now
	one(t, CheckTaggingMode(&cand, []fabricv1.Network{*deleting}), RuleTaggingMode, "being deleted and still holds")

	// A standalone access list on the holder's attachment is neither an owner nor a mode.
	acl := aclNet("acl", "ingress", "ipv4", att("leaf01", "ethernet-1/1", vlan(100)))
	if vs := append(CheckOwner(&untagged, []fabricv1.Network{acl}), CheckTaggingMode(&untagged, []fabricv1.Network{acl})...); len(vs) != 0 {
		t.Fatalf("standalone acl counted: %v", vs)
	}
	if vs := append(CheckOwner(&acl, []fabricv1.Network{holder}), CheckTaggingMode(&acl, []fabricv1.Network{holder})...); len(vs) != 0 {
		t.Fatalf("standalone acl refused as owner: %v", vs)
	}
}

func TestAccessLists(t *testing.T) {
	holder := vlanNet("holder", 100, att("leaf01", "ethernet-1/1", vlan(100)))
	acl := aclNet("acl", "ingress", "ipv4", att("leaf01", "ethernet-1/1", vlan(100)))
	if vs := CheckStandaloneSubinterface(&acl, []fabricv1.Network{holder}); len(vs) != 0 {
		t.Fatalf("existing subinterface refused: %v", vs)
	}
	missing := aclNet("acl", "ingress", "ipv4", att("leaf01", "ethernet-1/1", vlan(300)))
	one(t, CheckStandaloneSubinterface(&missing, []fabricv1.Network{holder}), RuleStandaloneNeedsSubi, "leaf01 ethernet-1/1.300")

	second := aclNet("second", "ingress", "ipv4", att("leaf01", "ethernet-1/1", vlan(100)))
	one(t, CheckBindings(&second, []fabricv1.Network{holder, acl}), RuleBindingExclusivity, "ns/acl", "ingress ipv4")
	v6 := aclNet("v6", "ingress", "ipv6", att("leaf01", "ethernet-1/1", vlan(100)))
	if vs := CheckBindings(&v6, []fabricv1.Network{holder, acl}); len(vs) != 0 {
		t.Fatalf("other family refused: %v", vs)
	}
	now := metav1.Now()
	acl.DeletionTimestamp = &now
	one(t, CheckBindings(&second, []fabricv1.Network{acl}), RuleBindingExclusivity, "being deleted and still holds its bindings", "being removed")
}

func TestQualification(t *testing.T) {
	gw := fabricv1.Network{Spec: fabricv1.NetworkSpec{
		BridgeDomains: []fabricv1.BridgeDomain{{Name: "bd", VLAN: 100, L2VNI: 10, IRB: &fabricv1.IRBSpec{VRF: "r", GatewayIPv4: "10.0.0.1/24", GatewayIPv6: "2001:db8::1/64"}}},
		Routers:       []fabricv1.NetworkRouter{{Name: "r", L3VNI: 20}},
		AccessLists:   []fabricv1.AccessList{{Name: "f", Stage: "egress", Type: "ipv6"}},
	}}
	want := "acl,acl.binding-without-filter,acl.egress,mac-vrf,mac-vrf.anycast-gateway-ipv4,mac-vrf.anycast-gateway-ipv6"
	if got := strings.Join(Requirements(&gw.Spec), ","); got != want {
		t.Fatalf("requirements %s, want %s", got, want)
	}
	all := map[string]string{}
	for _, k := range strings.Split(want, ",") {
		all[k] = "qualified"
	}
	q := QualificationFromConfigMap(&corev1.ConfigMap{Data: all})
	if vs := CheckQualified(&gw.Spec, q); len(vs) != 0 {
		t.Fatalf("qualified refused: %v", vs)
	}
	all["acl.egress"] = "unqualified"
	delete(all, "mac-vrf.anycast-gateway-ipv6")
	one(t, CheckQualified(&gw.Spec, q), RuleQualification, "acl.egress, mac-vrf.anycast-gateway-ipv6")
	one(t, CheckQualified(&gw.Spec, QualificationFromConfigMap(nil)), RuleQualification, "does not exist")

	ipvrf := fabricv1.NetworkSpec{Routers: []fabricv1.NetworkRouter{{Name: "r", L3VNI: 20, Prefixes: []fabricv1.IPPrefix{"10.1.0.0/24", "2001:db8:1::/64"}}}}
	if got := strings.Join(Requirements(&ipvrf), ","); got != "acl.binding-without-filter,ip-vrf,ip-vrf.evpn-type5-ipv4,ip-vrf.evpn-type5-ipv6" {
		t.Fatalf("ip-vrf requirements %s", got)
	}
}

func TestEvaluates(t *testing.T) {
	base := vlanNet("a", 100, att("leaf01", "ethernet-1/1", vlan(100)))
	if ok, _ := Evaluates(admissionv1.Create, &base, nil); !ok {
		t.Fatal("CREATE not evaluated")
	}
	meta := base.DeepCopy()
	meta.Labels = map[string]string{"x": "y"}
	meta.Annotations = map[string]string{"fabric.agentic-netops.io/force-release": "gone"}
	meta.Finalizers = []string{"f"}
	if ok, _ := Evaluates(admissionv1.Update, meta, &base); ok {
		t.Fatal("metadata-only UPDATE evaluated")
	}
	// nil and empty lists are the same spec (semantic comparison).
	empty := base.DeepCopy()
	empty.Spec.AccessLists = []fabricv1.AccessList{}
	if ok, _ := Evaluates(admissionv1.Update, empty, &base); ok {
		t.Fatal("semantically equal spec evaluated")
	}
	moved := base.DeepCopy()
	moved.Spec.Attachments[0].Attachment = "ethernet-1/2"
	if ok, _ := Evaluates(admissionv1.Update, moved, &base); !ok {
		t.Fatal("spec-changing UPDATE not evaluated")
	}
	now := metav1.Now()
	deleting := moved.DeepCopy()
	deleting.DeletionTimestamp = &now
	old := base.DeepCopy()
	old.DeletionTimestamp = &now
	if ok, _ := Evaluates(admissionv1.Update, deleting, old); ok {
		t.Fatal("UPDATE of a deleting object evaluated")
	}
}

// An owner's UPDATE may not remove a subinterface another Network's standalone list is bound to:
// the binding is withdrawn first (contracts/acl-render-contract.md §5).
func TestHeldSubinterfaces(t *testing.T) {
	old := vlanNet("holder", 100, att("leaf01", "ethernet-1/1", vlan(100)), att("leaf02", "ethernet-1/1", vlan(100)))
	acl := aclNet("acl", "ingress", "ipv4", att("leaf01", "ethernet-1/1", vlan(100)))
	dropBound := vlanNet("holder", 100, att("leaf02", "ethernet-1/1", vlan(100)))
	one(t, CheckHeldSubinterfaces(&dropBound, &old, []fabricv1.Network{acl}), RuleStandaloneNeedsSubi,
		"leaf01 ethernet-1/1.100", "ns/acl", "withdraw that list first")
	dropOther := vlanNet("holder", 100, att("leaf01", "ethernet-1/1", vlan(100)))
	if vs := CheckHeldSubinterfaces(&dropOther, &old, []fabricv1.Network{acl}); len(vs) != 0 {
		t.Fatalf("dropping an unbound attachment refused: %v", vs)
	}
	if vs := CheckHeldSubinterfaces(&dropBound, nil, []fabricv1.Network{acl}); len(vs) != 0 {
		t.Fatalf("a CREATE checked against an old object: %v", vs)
	}
	now := metav1.Now()
	acl.DeletionTimestamp = &now
	one(t, CheckHeldSubinterfaces(&dropBound, &old, []fabricv1.Network{acl}), RuleStandaloneNeedsSubi, "being removed")
}
