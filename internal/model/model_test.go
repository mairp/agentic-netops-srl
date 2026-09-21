package model

import (
	"slices"
	"testing"
)

func TestBuildServiceMACVRFGatewayMatchesExemplar(t *testing.T) {
	m, err := BuildService(gatewayService())
	if err != nil {
		t.Fatal(err)
	}
	n := m.Node("leaf01")
	if n == nil || len(m.Nodes) != 2 {
		t.Fatalf("nodes: %+v", m.Nodes)
	}
	if len(n.NetworkInstances) != 2 {
		t.Fatalf("instances: %+v", n.NetworkInstances)
	}
	ip, mac := n.NetworkInstances[0], n.NetworkInstances[1]
	if mac.Name != "macvrf-4b7e19c2a05d3f6" || mac.Type != MACVRF || mac.VXLANInterface != "vxlan0.10021" {
		t.Errorf("mac-vrf: %+v", mac)
	}
	if !slices.Equal(mac.Interfaces, []string{"ethernet-1/1.100", "irb0.100"}) || !mac.ProtectAnycastGWMAC {
		t.Errorf("mac-vrf members: %+v", mac.Interfaces)
	}
	if mac.EVPN.EVI != 10021 || mac.BGPVPN.ExportRT != "target:65000:10021" || mac.BGPVPN.ImportRT != "target:65000:10021" || mac.EVPN.ECMP != 8 {
		t.Errorf("mac-vrf evpn: %+v %+v", mac.EVPN, mac.BGPVPN)
	}
	if ip.Name != "ipvrf-4b7e19c2a05d3f6" || ip.Type != IPVRF || ip.VXLANInterface != "vxlan0.10022" ||
		ip.EVPN.EVI != 10022 || ip.BGPVPN.ExportRT != "target:65000:10022" {
		t.Errorf("ip-vrf: %+v", ip)
	}
	if !slices.Equal(ip.Interfaces, []string{"irb0.100"}) {
		t.Errorf("irb0.<vlan> must be a member of both instances: %+v", ip.Interfaces)
	}
	if len(n.VXLANInterfaces) != 2 || n.VXLANInterfaces[0].Type != Bridged || !n.VXLANInterfaces[0].EgressSystemIP ||
		n.VXLANInterfaces[1].Type != Routed || n.VXLANInterfaces[1].EgressSystemIP {
		t.Errorf("vxlan: %+v", n.VXLANInterfaces)
	}
	if len(n.IRB) != 1 || n.IRB[0].Name() != "irb0.100" || n.IRB[0].VirtualRouterID != 1 || n.IRB[0].IPMTU != 9348 {
		t.Errorf("irb: %+v", n.IRB)
	}
	if len(n.ACLFilters) != 1 {
		t.Fatalf("filters: %+v", n.ACLFilters)
	}
	f := n.ACLFilters[0]
	if f.Name != "acl-4b7e19c2a05d3f6-ingress" || f.Type != FamilyIPv4 || !f.StatisticsPerEntry || f.SubinterfaceSpecific != "" {
		t.Errorf("filter: %+v", f)
	}
	if len(f.Entries) != 2 || f.Entries[0].SequenceID != 100 || f.Entries[1].SequenceID != 65535 || f.Entries[1].Action != ActionDrop {
		t.Errorf("entries: %+v", f.Entries)
	}
	if len(n.ACLInterfaces) != 1 || n.ACLInterfaces[0].InterfaceID != "ethernet-1/1.100" ||
		n.ACLInterfaces[0].Ref == nil || n.ACLInterfaces[0].Ref.Subinterface != 100 || len(n.ACLInterfaces[0].Input) != 1 {
		t.Errorf("acl interface: %+v", n.ACLInterfaces)
	}
	// leaf02 has no filter binding but still renders the interface-ref of its subinterface (AD-68).
	n2 := m.Node("leaf02")
	if len(n2.ACLFilters) != 0 || len(n2.ACLInterfaces) != 1 || n2.ACLInterfaces[0].Ref == nil || len(n2.ACLInterfaces[0].Input) != 0 {
		t.Errorf("leaf02 acl interface: %+v", n2.ACLInterfaces)
	}
}

func TestBuildServiceVLANHasNoOverlay(t *testing.T) {
	m, err := BuildService(ServiceInput{ServiceID: "21", Construct: ConstructVLAN, FabricASN: 65000,
		L2: &L2Segment{VLAN: 100, Attachments: []Attachment{{Node: "leaf01", Port: "ethernet-1/1"}}}})
	if err != nil {
		t.Fatal(err)
	}
	n := m.Nodes[0]
	if len(n.VXLANInterfaces) != 0 || n.NetworkInstances[0].EVPN != nil || n.NetworkInstances[0].Name != "vlan-21" ||
		n.NetworkInstances[0].Description != "Service 21 (vlan)" {
		t.Errorf("vlan: %+v", n)
	}
	if _, err := BuildService(ServiceInput{ServiceID: "21", Construct: ConstructVLAN, FabricASN: 65000,
		L2: &L2Segment{VLAN: 100, L2VNI: 10021, Attachments: []Attachment{{Node: "leaf01", Port: "ethernet-1/1"}}}}); err == nil {
		t.Error("vlan with a vni accepted")
	}
}

func TestBuildServiceIPVRFUntagged(t *testing.T) {
	m, err := BuildService(ServiceInput{ServiceID: "21", Construct: ConstructIPVRF, FabricASN: 65000,
		Routed: &RoutedService{L3VNI: 10022, Attachments: []RoutedAttachment{
			{Node: "leaf01", Port: "ethernet-1/2", IPv4: []string{"10.20.0.1/24"}},
			{Node: "leaf02", Port: "ethernet-1/2", VLAN: 300, IPv4: []string{"10.30.0.1/24"}}}}})
	if err != nil {
		t.Fatal(err)
	}
	if s := m.Node("leaf01").Subinterfaces[0]; s.Index != 0 || s.Type != Routed || s.VLAN != 0 {
		t.Errorf("untagged routed subinterface: %+v", s)
	}
	if s := m.Node("leaf02").Subinterfaces[0]; s.Index != 300 || s.Name() != "ethernet-1/2.300" {
		t.Errorf("tagged routed subinterface: %+v", s)
	}
}

func TestBuildServiceStandaloneACLWritesNoInterfaceRef(t *testing.T) {
	m, err := BuildService(ServiceInput{ServiceID: "a1", Construct: ConstructACL, AccessLists: []AccessList{{
		Stage: StageEgress, Family: FamilyIPv6,
		Rules:    []ACLRule{{Name: "r", Priority: 10, Action: ActionDrop, SourcePort: &PortMatch{Lo: 1000, Hi: 2000}}},
		Bindings: []ACLBinding{{Node: "leaf01", Port: "ethernet-1/1", VLAN: 100}},
	}}})
	if err != nil {
		t.Fatal(err)
	}
	n := m.Nodes[0]
	if len(n.Subinterfaces) != 0 || len(n.ACLInterfaces) != 1 || n.ACLInterfaces[0].Ref != nil || len(n.ACLInterfaces[0].Output) != 1 {
		t.Errorf("standalone acl: %+v", n)
	}
	if n.ACLFilters[0].SubinterfaceSpecific != "output-only" {
		t.Errorf("egress filter must be subinterface-specific: %+v", n.ACLFilters[0])
	}
}

func TestBuildServiceRefusesBindingOnForeignSubinterface(t *testing.T) {
	in := gatewayService()
	in.AccessLists[0].Bindings = []ACLBinding{{Node: "leaf01", Port: "ethernet-1/9", VLAN: 100}}
	if _, err := BuildService(in); err == nil {
		t.Error("binding on a subinterface the service does not create accepted")
	}
}

func testFabric() FabricInput {
	return FabricInput{
		Name: "fabric01", FabricASN: 65000, InterASVPN: true,
		MTU: FabricMTU{PortMTU: 9412, UnderlayIPMTU: 9398, BridgedL2MTU: 9412, TenantIPMTU: 9348},
		Nodes: []FabricNodeInput{
			{Name: "spine01", Role: RoleSpine, SystemIPv4: "10.0.0.11/32", ASN: 65100, RouteReflector: true},
			{Name: "spine02", Role: RoleSpine, SystemIPv4: "10.0.0.12/32", ASN: 65100, RouteReflector: true},
			{Name: "leaf01", Role: RoleLeaf, SystemIPv4: "10.0.0.1/32", ASN: 65101},
			{Name: "leaf02", Role: RoleLeaf, SystemIPv4: "10.0.0.2/32", ASN: 65102},
		},
		Links: []FabricLink{
			{A: LinkEnd{"leaf01", "ethernet-1/49", "192.168.0.1/31"}, B: LinkEnd{"spine01", "ethernet-1/1", "192.168.0.0/31"}},
			{A: LinkEnd{"leaf01", "ethernet-1/50", "192.168.0.3/31"}, B: LinkEnd{"spine02", "ethernet-1/1", "192.168.0.2/31"}},
			{A: LinkEnd{"leaf02", "ethernet-1/49", "192.168.0.5/31"}, B: LinkEnd{"spine01", "ethernet-1/2", "192.168.0.4/31"}},
			{A: LinkEnd{"leaf02", "ethernet-1/50", "192.168.0.7/31"}, B: LinkEnd{"spine02", "ethernet-1/2", "192.168.0.6/31"}},
		},
		Inventory: []InventoryEntry{
			{Node: "leaf01", AccessPorts: []string{"ethernet-1/1", "ethernet-1/2"}, UntaggedAccessPorts: []string{"ethernet-1/2"}},
			{Node: "leaf02", AccessPorts: []string{"ethernet-1/1", "ethernet-1/2"}},
		},
		Maintenance: []MaintenanceEntry{{Node: "leaf02", Interface: "ethernet-1/50", AdminState: "disable"}},
	}
}

func TestBuildFabric(t *testing.T) {
	m, err := BuildFabric(testFabric())
	if err != nil {
		t.Fatal(err)
	}
	s := m.Node("spine01")
	if s.BGP.InterASVPN == nil || !*s.BGP.InterASVPN || !s.BGP.RouteReflectorClient || s.IRBEnabled {
		t.Errorf("spine01: %+v", s.BGP)
	}
	l := m.Node("leaf01")
	if l.BGP.InterASVPN != nil || !l.IRBEnabled || l.BGP.OverlayAS != 65000 || l.BGP.AutonomousSystem != 65101 {
		t.Errorf("leaf01: %+v", l)
	}
	if l.AccessPorts[0].Name != "ethernet-1/1" || !l.AccessPorts[0].VLANTagging || l.AccessPorts[1].VLANTagging {
		t.Errorf("tagging mode: %+v", l.AccessPorts)
	}
	if p := m.Node("leaf02").FabricPorts[1]; p.Name != "ethernet-1/50" || p.Enabled {
		t.Errorf("maintenance: %+v", p)
	}
	// interASVPN=false is rendered as false, never dropped (AD-43).
	in := testFabric()
	in.InterASVPN = false
	m2, _ := BuildFabric(in)
	if v := m2.Node("spine02").BGP.InterASVPN; v == nil || *v {
		t.Errorf("interASVPN false must be stated: %v", v)
	}
	if !slices.Contains(m2.Node("spine02").WritePaths(), "/network-instance[name=default]/protocols/bgp/afi-safi[afi-safi-name=evpn]/evpn/inter-as-vpn") {
		t.Error("inter-as-vpn path missing when false")
	}
}

func TestWritePathsServiceNoPortLevelLeaf(t *testing.T) {
	m, _ := BuildService(gatewayService())
	for _, p := range m.Node("leaf01").WritePaths() {
		switch p {
		case "/interface[name=ethernet-1/1]/admin-state", "/interface[name=ethernet-1/1]/vlan-tagging", "/interface[name=irb0]/admin-state":
			t.Errorf("service writes fabric-owned leaf %s (AD-68)", p)
		}
	}
}
