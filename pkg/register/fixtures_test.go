package register

import "github.com/mairp/agentic-netops-srl/internal/model"

// fabricFixtures are representative Fabric designs: every fabric construct —
// fabric links with MTUs, system0, access ports tagged and untagged, irb0 on
// leaves, route-reflecting spines with inter-as-vpn true and false and with
// route-reflector client true and false, a maintenance entry.
func fabricFixtures() map[string]model.FabricInput {
	base := func(interAS, clients bool) model.FabricInput {
		return model.FabricInput{
			Name: "default", FabricASN: 65000, InterASVPN: interAS, ReflectorClients: clients,
			MTU: model.FabricMTU{PortMTU: 9412, UnderlayIPMTU: 9398, BridgedL2MTU: 9412, TenantIPMTU: 9348},
			Nodes: []model.FabricNodeInput{
				{Name: "spine01", Role: model.RoleSpine, SystemIPv4: "10.0.0.11/32", ASN: 65100, RouteReflector: true},
				{Name: "spine02", Role: model.RoleSpine, SystemIPv4: "10.0.0.12/32", ASN: 65100, RouteReflector: true},
				{Name: "leaf01", Role: model.RoleLeaf, SystemIPv4: "10.0.0.1/32", ASN: 65101},
				{Name: "leaf02", Role: model.RoleLeaf, SystemIPv4: "10.0.0.2/32", ASN: 65102},
			},
			Links: []model.FabricLink{
				{A: model.LinkEnd{Node: "leaf01", Port: "ethernet-1/49", IPv4: "192.168.0.1/31"}, B: model.LinkEnd{Node: "spine01", Port: "ethernet-1/1", IPv4: "192.168.0.0/31"}},
				{A: model.LinkEnd{Node: "leaf01", Port: "ethernet-1/50", IPv4: "192.168.0.3/31"}, B: model.LinkEnd{Node: "spine02", Port: "ethernet-1/1", IPv4: "192.168.0.2/31"}},
				{A: model.LinkEnd{Node: "leaf02", Port: "ethernet-1/49", IPv4: "192.168.0.5/31"}, B: model.LinkEnd{Node: "spine01", Port: "ethernet-1/2", IPv4: "192.168.0.4/31"}},
				{A: model.LinkEnd{Node: "leaf02", Port: "ethernet-1/50", IPv4: "192.168.0.7/31"}, B: model.LinkEnd{Node: "spine02", Port: "ethernet-1/2", IPv4: "192.168.0.6/31"}},
			},
			Inventory: []model.InventoryEntry{
				{Node: "leaf01", AccessPorts: []string{"ethernet-1/1", "ethernet-1/2"}, UntaggedAccessPorts: []string{"ethernet-1/2"}},
				{Node: "leaf02", AccessPorts: []string{"ethernet-1/1", "ethernet-1/2"}},
			},
			Maintenance: []model.MaintenanceEntry{{Node: "leaf02", Interface: "ethernet-1/50", AdminState: "disable"}},
		}
	}
	return map[string]model.FabricInput{"interASVPN-true": base(true, true), "interASVPN-false": base(false, true),
		"reflectorClients-false": base(true, false)}
}

// serviceFixtures are representative services covering every construct and
// every access-list shape: vlan; mac-vrf bridged only; mac-vrf with an anycast
// gateway (IPv4 and IPv6) and an ingress IPv4 filter; ip-vrf tagged and
// untagged, dual-stack, with an egress IPv6 filter using port ranges and a
// protocol; standalone acl, ingress IPv4 and egress IPv6.
func serviceFixtures() map[string]model.ServiceInput {
	drop, accept := model.ActionDrop, model.ActionAccept
	two := []model.Attachment{{Node: "leaf01", Port: "ethernet-1/1"}, {Node: "leaf02", Port: "ethernet-1/1"}}
	return map[string]model.ServiceInput{
		"vlan": {ServiceID: "vlan-100", Tenant: "t1", Construct: model.ConstructVLAN, FabricASN: 65000,
			L2: &model.L2Segment{VLAN: 100, Attachments: two},
			AccessLists: []model.AccessList{{Stage: model.StageIngress, Family: model.FamilyIPv4, DefaultAction: &accept,
				Rules:    []model.ACLRule{{Name: "deny-telnet", Priority: 10, Action: model.ActionDrop, Protocol: "tcp", DestinationPort: &model.PortMatch{Lo: 23}}},
				Bindings: []model.ACLBinding{{Node: "leaf01", Port: "ethernet-1/1", VLAN: 100}}}}},
		"mac-vrf": {ServiceID: "l2-200", Construct: model.ConstructMACVRF, FabricASN: 65000,
			L2: &model.L2Segment{VLAN: 200, L2VNI: 10200, Attachments: two}},
		"mac-vrf-gateway": {ServiceID: "4b7e19c2a05d3f6", Tenant: "tenant1", Construct: model.ConstructMACVRF, FabricASN: 65000,
			L2:      &model.L2Segment{VLAN: 300, L2VNI: 10021, Attachments: two},
			Gateway: &model.Gateway{L3VNI: 10022, IPv4: []string{"10.10.0.1/24"}, IPv6: []string{"2001:db8::1/64"}, IPMTU: 9348},
			AccessLists: []model.AccessList{{Stage: model.StageIngress, Family: model.FamilyIPv4, DefaultAction: &drop,
				Rules: []model.ACLRule{{Name: "allow-https", Priority: 100, Action: model.ActionAccept, Protocol: "tcp",
					SourcePrefix: "10.0.0.0/24", DestinationPrefix: "10.10.0.0/24", DestinationPort: &model.PortMatch{Lo: 443}}},
				Bindings: []model.ACLBinding{{Node: "leaf01", Port: "ethernet-1/1", VLAN: 300}}}}},
		"ip-vrf": {ServiceID: "l3-400", Construct: model.ConstructIPVRF, FabricASN: 65000,
			Routed: &model.RoutedService{L3VNI: 10400, Attachments: []model.RoutedAttachment{
				{Node: "leaf01", Port: "ethernet-1/2", IPv4: []string{"10.40.0.1/24"}, IPv6: []string{"2001:db8:40::1/64"}},
				{Node: "leaf02", Port: "ethernet-1/2", VLAN: 400, IPv4: []string{"10.41.0.1/24"}, IPv6: []string{"2001:db8:41::1/64"}}}},
			AccessLists: []model.AccessList{{Stage: model.StageEgress, Family: model.FamilyIPv6, DefaultAction: &accept,
				Rules: []model.ACLRule{{Name: "drop-range", Priority: 20, Action: model.ActionDrop, Protocol: "udp",
					SourcePrefix: "2001:db8:1::/48", DestinationPrefix: "2001:db8:40::/64",
					SourcePort: &model.PortMatch{Lo: 1000, Hi: 2000}, DestinationPort: &model.PortMatch{Lo: 3000, Hi: 4000}}},
				Bindings: []model.ACLBinding{{Node: "leaf01", Port: "ethernet-1/2"}, {Node: "leaf02", Port: "ethernet-1/2", VLAN: 400}}}}},
		"acl-standalone": {ServiceID: "acl-500", Tenant: "t2", Construct: model.ConstructACL,
			AccessLists: []model.AccessList{
				{Stage: model.StageIngress, Family: model.FamilyIPv4, DefaultAction: &drop,
					Rules:    []model.ACLRule{{Name: "allow-dns", Priority: 5, Action: model.ActionAccept, Protocol: "udp", SourcePort: &model.PortMatch{Lo: 53}}},
					Bindings: []model.ACLBinding{{Node: "leaf01", Port: "ethernet-1/1", VLAN: 200}}},
				{Stage: model.StageEgress, Family: model.FamilyIPv6,
					Rules:    []model.ACLRule{{Name: "drop-all", Priority: 1, Action: model.ActionDrop}},
					Bindings: []model.ACLBinding{{Node: "leaf02", Port: "ethernet-1/1", VLAN: 200}}},
			}},
	}
}
