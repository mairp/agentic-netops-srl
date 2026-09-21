package model

import (
	"reflect"
	"strings"
	"testing"
)

func TestEVIIsVNI(t *testing.T) {
	for _, tc := range []struct {
		vni     uint32
		want    uint32
		wantErr bool
	}{
		{vni: 10021, want: 10021},
		{vni: 1, want: 1},
		{vni: 65535, want: 65535},
		{vni: 0, wantErr: true},
		{vni: 65536, wantErr: true}, // evi is 1..65535 on the device
	} {
		got, err := EVI(tc.vni)
		if (err != nil) != tc.wantErr || got != tc.want {
			t.Errorf("EVI(%d) = %d, %v; want %d, err=%v", tc.vni, got, err, tc.want, tc.wantErr)
		}
	}
}

func TestRouteTarget(t *testing.T) {
	for _, tc := range []struct {
		asn, vni uint32
		want     string
		wantErr  bool
	}{
		{asn: 65000, vni: 10021, want: "target:65000:10021"},
		{asn: 65535, vni: 10022, want: "target:65535:10022"},
		{asn: 4200000000, vni: 10021, want: "target:4200000000:10021"},
		{asn: 4200000000, vni: 70000, wantErr: true},
		{asn: 0, vni: 10021, wantErr: true},
		{asn: 65000, vni: 0, wantErr: true},
		{asn: 65000, vni: 16777216, wantErr: true},
	} {
		got, err := RouteTarget(tc.asn, tc.vni)
		if (err != nil) != tc.wantErr || got != tc.want {
			t.Errorf("RouteTarget(%d,%d) = %q, %v; want %q err=%v", tc.asn, tc.vni, got, err, tc.want, tc.wantErr)
		}
	}
}

func TestSubinterfaceIndexIsVLAN(t *testing.T) {
	for _, tc := range []struct {
		vlan, want uint32
		wantErr    bool
	}{
		{vlan: 100, want: 100},
		{vlan: 0, want: 0}, // untagged
		{vlan: 4000, want: 4000},
		{vlan: 4094, want: 4094},
		{vlan: 4095, wantErr: true},
	} {
		got, err := SubinterfaceIndex(tc.vlan)
		if (err != nil) != tc.wantErr || got != tc.want {
			t.Errorf("SubinterfaceIndex(%d) = %d, %v", tc.vlan, got, err)
		}
	}
}

func TestInterfaceNames(t *testing.T) {
	idx, err := VXLANInterfaceIndex(10021)
	if err != nil || idx != 10021 {
		t.Fatalf("VXLANInterfaceIndex = %d, %v", idx, err)
	}
	if got := VXLANInterfaceName(idx); got != "vxlan0.10021" {
		t.Errorf("VXLANInterfaceName = %q", got)
	}
	if got, err := IRBSubinterfaceName(100); err != nil || got != "irb0.100" {
		t.Errorf("IRBSubinterfaceName = %q, %v", got, err)
	}
	if _, err := IRBSubinterfaceName(0); err == nil {
		t.Error("irb0.0 must be refused: an IRB subinterface is keyed by a VLAN")
	}
	if got := SubinterfaceName("ethernet-1/1", 100); got != "ethernet-1/1.100" {
		t.Errorf("SubinterfaceName = %q", got)
	}
	if _, err := VXLANInterfaceIndex(0); err == nil {
		t.Error("vni 0 must be refused")
	}
}

func TestInstanceAndFilterNames(t *testing.T) {
	const id = "4b7e19c2a05d3f6"
	for _, tc := range []struct {
		fn   func(string) (string, error)
		want string
	}{
		{VLANInstanceName, "vlan-" + id},
		{MACVRFName, "macvrf-" + id},
		{IPVRFName, "ipvrf-" + id},
	} {
		got, err := tc.fn(id)
		if err != nil || got != tc.want {
			t.Errorf("got %q, %v; want %q", got, err, tc.want)
		}
		if err := ValidateNetworkInstanceName(got); err != nil {
			t.Errorf("derived name %q not device-safe: %v", got, err)
		}
	}
	for stage, want := range map[Stage]string{StageIngress: "acl-svc-0042-ingress", StageEgress: "acl-svc-0042-egress"} {
		got, err := FilterName("svc-0042", stage)
		if err != nil || got != want {
			t.Errorf("FilterName(%s) = %q, %v; want %q", stage, got, err, want)
		}
	}
	if _, err := FilterName("svc", "both"); err == nil {
		t.Error("unknown stage must be refused")
	}
}

// Names are refused, never rewritten (D-13, acl-render-contract.md §2).
func TestNamesRefuseNeverRewrite(t *testing.T) {
	for _, bad := range []string{"", "Svc", "svc_1", "svc.1", "svc/1", " svc", "-svc", "svc-", strings.Repeat("a", 64)} {
		if _, err := MACVRFName(bad); err == nil {
			t.Errorf("MACVRFName(%q) accepted", bad)
		}
		if _, err := FilterName(bad, StageIngress); err == nil {
			t.Errorf("FilterName(%q) accepted", bad)
		}
	}
	// The longest admitted id still fits the device bounds.
	long := strings.Repeat("a", 63)
	if n, err := MACVRFName(long); err != nil || len(n) > 247 {
		t.Errorf("63-char id: %q, %v", n, err)
	}
}

func TestDeviceNameRules(t *testing.T) {
	for _, n := range []string{"system", "capture"} {
		if err := ValidateFilterName(n); err == nil {
			t.Errorf("reserved filter name %q accepted", n)
		}
	}
	if err := ValidateNetworkInstanceName("a/b"); err == nil {
		t.Error("'/' is outside restricted-name")
	}
	if err := ValidateFilterName("a/b"); err != nil {
		t.Errorf("'/' is inside srl_nokia-comm:name: %v", err)
	}
	if err := ValidateNetworkInstanceName(" lead"); err == nil {
		t.Error("leading space accepted")
	}
	if err := ValidateNetworkInstanceName(strings.Repeat("a", 248)); err == nil {
		t.Error("248-char network-instance name accepted")
	}
	if err := ValidateFilterName(strings.Repeat("a", 256)); err == nil {
		t.Error("256-char filter name accepted")
	}
}

func TestSequenceIDIsPriority(t *testing.T) {
	if s, err := SequenceID(100); err != nil || s != 100 {
		t.Errorf("SequenceID(100) = %d, %v", s, err)
	}
	for _, bad := range []uint32{0, 65535, 70000} {
		if _, err := SequenceID(bad); err == nil {
			t.Errorf("SequenceID(%d) accepted; 65535 is reserved", bad)
		}
	}
}

func TestNormalizeInterfaceLabel(t *testing.T) {
	if got := NormalizeInterfaceLabel("ethernet-1/49"); got != "e1-49" {
		t.Errorf("got %q", got)
	}
}

// Determinism: every derivation is a pure function — repeated calls agree, and
// the full model does not depend on input order.
func TestDerivationsDeterministic(t *testing.T) {
	for i := 0; i < 50; i++ {
		a, _ := RouteTarget(65000, 10021)
		b, _ := MACVRFName("svc-1")
		c, _ := FilterName("svc-1", StageEgress)
		if a != "target:65000:10021" || b != "macvrf-svc-1" || c != "acl-svc-1-egress" {
			t.Fatalf("non-deterministic derivation: %q %q %q", a, b, c)
		}
	}
	in := gatewayService()
	m1, err := BuildService(in)
	if err != nil {
		t.Fatal(err)
	}
	rev := gatewayService()
	for i, j := 0, len(rev.L2.Attachments)-1; i < j; i, j = i+1, j-1 {
		rev.L2.Attachments[i], rev.L2.Attachments[j] = rev.L2.Attachments[j], rev.L2.Attachments[i]
	}
	rev.Gateway.IPv4 = []string{"10.10.1.1/24", "10.10.0.1/24"}
	m2, err := BuildService(rev)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(m1, m2) {
		t.Fatalf("model depends on input order:\n%+v\n%+v", m1, m2)
	}
}

func gatewayService() ServiceInput {
	deny := ActionDrop
	return ServiceInput{
		ServiceID: "4b7e19c2a05d3f6", Tenant: "tenant1", Construct: ConstructMACVRF, FabricASN: 65000,
		L2: &L2Segment{VLAN: 100, L2VNI: 10021, Attachments: []Attachment{
			{Node: "leaf01", Port: "ethernet-1/1"}, {Node: "leaf02", Port: "ethernet-1/1"}}},
		Gateway: &Gateway{L3VNI: 10022, IPv4: []string{"10.10.0.1/24", "10.10.1.1/24"}, IPv6: []string{"2001:db8::1/64"}, IPMTU: 9348},
		AccessLists: []AccessList{{
			Stage: StageIngress, Family: FamilyIPv4, DefaultAction: &deny,
			Rules: []ACLRule{{Name: "allow-https", Priority: 100, Action: ActionAccept, Protocol: "tcp",
				SourcePrefix: "10.0.0.0/24", DestinationPort: &PortMatch{Lo: 443}}},
			Bindings: []ACLBinding{{Node: "leaf01", Port: "ethernet-1/1", VLAN: 100}},
		}},
	}
}

// Purity: the same input yields the same output, and the input is not mutated.
func TestModelPurity(t *testing.T) {
	in := gatewayService()
	snapshot := gatewayService()
	m1, err1 := BuildService(in)
	m2, err2 := BuildService(in)
	if err1 != nil || err2 != nil || !reflect.DeepEqual(m1, m2) {
		t.Fatalf("BuildService not pure: %v %v", err1, err2)
	}
	if !reflect.DeepEqual(in, snapshot) {
		t.Fatal("BuildService mutated its input")
	}
	fin := testFabric()
	fsnap := testFabric()
	f1, err1 := BuildFabric(fin)
	f2, err2 := BuildFabric(fin)
	if err1 != nil || err2 != nil || !reflect.DeepEqual(f1, f2) {
		t.Fatalf("BuildFabric not pure: %v %v", err1, err2)
	}
	if !reflect.DeepEqual(fin, fsnap) {
		t.Fatal("BuildFabric mutated its input")
	}
	// Derived identifiers of one service agree across nodes: evi := vni and
	// the route target are the same on every leaf.
	for _, name := range []string{"leaf01", "leaf02"} {
		n := m1.Node(name)
		if n == nil {
			t.Fatalf("no node %s", name)
		}
		for _, ni := range n.NetworkInstances {
			if ni.EVPN != nil && ni.BGPVPN != nil {
				want, _ := RouteTarget(65000, ni.EVPN.EVI)
				if ni.BGPVPN.ExportRT != want || ni.BGPVPN.ImportRT != want {
					t.Errorf("%s/%s: rt %q/%q, want %q", name, ni.Name, ni.BGPVPN.ExportRT, ni.BGPVPN.ImportRT, want)
				}
			}
		}
	}
}
