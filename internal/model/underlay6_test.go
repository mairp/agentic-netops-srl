package model

import "testing"

func TestDerivedUnderlayIPv6(t *testing.T) {
	for in, want := range map[string]string{"10.0.0.1/32": "fd00::a00:1/128", "10.0.0.12/32": "fd00::a00:c/128"} {
		if got, err := DeriveSystemIPv6(in); err != nil || got != want {
			t.Errorf("DeriveSystemIPv6(%s) = %s, %v; want %s", in, got, err, want)
		}
	}
	for in, want := range map[string]string{"10.1.0.0/31": "fd00:1::a01:0/127", "10.1.0.1/31": "fd00:1::a01:1/127"} {
		if got, err := DeriveLinkIPv6(in); err != nil || got != want {
			t.Errorf("DeriveLinkIPv6(%s) = %s, %v; want %s", in, got, err, want)
		}
	}
	if _, err := DeriveSystemIPv6("10.0.0.1/31"); err == nil {
		t.Error("system IPv6 derived from a non-/32")
	}
	if MaskLengthRange("fd00::a00:1/128") != "128..128" || MaskLengthRange("10.0.0.1/32") != "32..32" {
		t.Error("mask-length-range")
	}
	in := testFabric()
	in.AddressFamilies = []AddressFamily{FamilyUnderlayIPv6}
	if _, err := BuildFabric(in); err == nil {
		t.Error("an IPv6-only underlay accepted: the VXLAN tunnel endpoint is IPv4-only")
	}
	in.AddressFamilies = []AddressFamily{FamilyUnderlayIPv4}
	m, err := BuildFabric(in)
	if err != nil {
		t.Fatal(err)
	}
	if n := m.Node("leaf01"); n.SystemIPv6 != "" || n.FabricPorts[0].IPv6 != "" || n.BGP.IPv6Unicast {
		t.Errorf("IPv6 on an IPv4-only underlay: %+v", n)
	}
	m, _ = BuildFabric(testFabric()) // empty families: both, the default
	if n := m.Node("spine01"); n.SystemIPv6 != "fd00::a00:b/128" || !n.BGP.IPv6Unicast || n.VXLANTunnel {
		t.Errorf("spine01: %+v", n)
	}
	if !m.Node("leaf01").VXLANTunnel {
		t.Error("leaf01 has no tunnel-interface")
	}
}
