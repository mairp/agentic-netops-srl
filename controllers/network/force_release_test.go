package network

import (
	"reflect"
	"strings"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/model"
)

// The annotation's value is the reason; a blank one is set but empty (refused, FR-103).
func TestForceReleaseReason(t *testing.T) {
	n := &fabricv1.Network{}
	if _, set := ForceReleaseReason(n); set {
		t.Fatal("no annotation reads as set")
	}
	n.Annotations = map[string]string{AnnotationForceRelease: "  \t"}
	if r, set := ForceReleaseReason(n); !set || r != "" {
		t.Fatalf("blank value: %q %v, want set and empty", r, set)
	}
	n.Annotations[AnnotationForceRelease] = " leaf02 gone "
	if r, _ := ForceReleaseReason(n); r != "leaf02 gone" {
		t.Fatalf("reason %q", r)
	}
}

// The device object names are the ones internal/verify.DeviceObjectStatePath reads: network
// instances, <port>.<index> (irb0 included), vxlan0.<index>, filters — sorted and distinct.
func TestDeviceObjects(t *testing.T) {
	sn := &model.ServiceNode{
		Node:             "leaf01",
		NetworkInstances: []model.NetworkInstance{{Name: "macvrf-a"}, {Name: "ipvrf-a"}},
		Subinterfaces:    []model.Subinterface{{Port: "ethernet-1/1", Index: 100}, {Port: "ethernet-1/1", Index: 100}},
		IRB:              []model.IRBSubinterface{{Index: 100}},
		VXLANInterfaces:  []model.VXLANInterface{{Index: 10100}},
		ACLFilters:       []model.ACLFilter{{Name: "acl-a-ingress"}},
	}
	want := []string{"acl-a-ingress", "ethernet-1/1.100", "ipvrf-a", "irb0.100", "macvrf-a", "vxlan0.10100"}
	if got := DeviceObjects(sn); !reflect.DeepEqual(got, want) {
		t.Fatalf("DeviceObjects %v, want %v", got, want)
	}
}

// A finding refuses a render producing one of its objects on its node only while that node is
// in spec.nodes (AD-71); another node, or no shared object, refuses nothing.
func TestStaleFindingConflicts(t *testing.T) {
	f := &fabricv1.Fabric{ObjectMeta: metav1.ObjectMeta{Namespace: "agentic-netops-system", Name: "fabric01"}}
	f.Spec.Nodes = []fabricv1.FabricNode{{Name: "leaf01"}, {Name: "leaf02"}}
	f.Status.Findings = []fabricv1.Finding{{Node: "leaf02", DeviceObjects: []string{"ethernet-1/1.100", "macvrf-old"},
		Service: fabricv1.ServiceRef{Namespace: "ns", Name: "old", UID: "u1"}}}
	m := &model.ServiceModel{Nodes: []model.ServiceNode{
		{Node: "leaf01", Subinterfaces: []model.Subinterface{{Port: "ethernet-1/1", Index: 100}}},
		{Node: "leaf02", Subinterfaces: []model.Subinterface{{Port: "ethernet-1/1", Index: 100}}, NetworkInstances: []model.NetworkInstance{{Name: "vlan-new"}}},
	}}
	got := staleFindingConflicts(f, m)
	if len(got) != 1 || !strings.Contains(got[0], "ns/old") || !strings.Contains(got[0], "leaf02") || !strings.Contains(got[0], "ethernet-1/1.100") {
		t.Fatalf("conflicts %v", got)
	}
	m.Nodes[1].Subinterfaces[0].Index = 200
	if got := staleFindingConflicts(f, m); len(got) != 0 {
		t.Fatalf("no shared object, yet %v", got)
	}
	m.Nodes[1].Subinterfaces[0].Index = 100
	f.Spec.Nodes = f.Spec.Nodes[:1]
	if got := staleFindingConflicts(f, m); len(got) != 0 {
		t.Fatalf("a finding whose node left spec.nodes refused %v", got)
	}
}

// Every claimRef becomes an identifier: kind from the role, index from the Fabric's indices.
func TestReleasedIdentifiers(t *testing.T) {
	r := &Reconciler{}
	f := &fabricv1.Fabric{ObjectMeta: metav1.ObjectMeta{Name: "fabric01"}}
	n := &fabricv1.Network{ObjectMeta: metav1.ObjectMeta{Namespace: "ns", Name: "svc"}}
	n.Status.ClaimRefs = []fabricv1.ClaimRef{
		{Name: "ns.svc.vlan-bd", IndexKind: fabricv1.ClaimIndexVLAN, Value: 1300},
		{Name: "ns.svc.l2vni-bd", IndexKind: fabricv1.ClaimIndexGENID, Value: 11300},
		{Name: "ns.svc.l3vni-vrf", IndexKind: fabricv1.ClaimIndexGENID, Value: 11301},
	}
	want := []fabricv1.ReleasedIdentifier{
		{Kind: "l2vni", Index: "fabric01-vni", Value: "11300"},
		{Kind: "l3vni", Index: "fabric01-vni", Value: "11301"},
		{Kind: "vlan", Index: "fabric01-vlan", Value: "1300"},
	}
	if got := r.releasedIdentifiers(n, f); !reflect.DeepEqual(got, want) {
		t.Fatalf("identifiers %+v, want %+v", got, want)
	}
}
