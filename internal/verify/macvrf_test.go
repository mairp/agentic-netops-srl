package verify

import (
	"context"
	"sort"
	"strings"
	"testing"

	"github.com/mairp/agentic-netops-srl/internal/status"
)

// ---------------------------------------------------------------------------
// vlan: never held to overlay evidence.
// ---------------------------------------------------------------------------

var overlayFragments = []string{"vxlan", "tunnel", "bgp-evpn", "bgp-vpn", "route-table", "vtep", "multicast-destinations"}

func TestVLANPassesWithNoOverlayRead(t *testing.T) {
	for _, nodes := range [][]string{{"leaf01"}, {"leaf01", "leaf02", "leaf03"}} {
		s, in, r, _ := serviceFixture(t, vlanModel(t, nodes...), nil)
		res := mustPass(t, s, in)
		for _, p := range r.allRequested() {
			for _, f := range overlayFragments {
				if strings.Contains(p, f) {
					t.Errorf("vlan over %v requested overlay path %s", nodes, p)
				}
			}
		}
		want := []string{
			"/interface[name=ethernet-1/1]/subinterface[index=990]/oper-down-reason",
			"/interface[name=ethernet-1/1]/subinterface[index=990]/oper-state",
			"/network-instance[name=vlan-v1]/interface[name=ethernet-1/1.990]/oper-down-reason",
			"/network-instance[name=vlan-v1]/interface[name=ethernet-1/1.990]/oper-state",
			"/network-instance[name=vlan-v1]/oper-down-reason",
			"/network-instance[name=vlan-v1]/oper-state",
		}
		for _, n := range nodes {
			if got := dedupe(r.requested[n]); strings.Join(sortedCopy(got), "\n") != strings.Join(want, "\n") {
				t.Errorf("%s requested\n%s\nwant\n%s", n, strings.Join(sortedCopy(got), "\n"), strings.Join(want, "\n"))
			}
		}
		if len(res.ConfigPaths) != 2*len(nodes) {
			t.Errorf("config paths %v", res.ConfigPaths)
		}
	}
}

// A vlan spanning two leaves with no remote VTEP, no destination and no route
// in state still passes: nothing overlay-related is ever asserted.
func TestVLANNeverAssertsOverlay(t *testing.T) {
	s, in, _, _ := serviceFixture(t, vlanModel(t, "leaf01", "leaf02"), nil)
	in.Loopbacks = nil // no VTEP known at all
	mustPass(t, s, in)
}

func TestVLANMissingInvariantsNamed(t *testing.T) {
	m := vlanModel(t, "leaf01", "leaf02")

	t.Run("network-instance down with the device's reason", func(t *testing.T) {
		s, in, r, _ := serviceFixture(t, m, nil)
		r.set("leaf01", NetworkInstanceOperStatePath("vlan-v1"), "down")
		r.set("leaf01", NetworkInstanceOperDownReasonPath("vlan-v1"), "admin-down")
		res := mustMiss(t, s, in)
		if !hasMissing(res, "leaf01", CheckNetworkInstanceOperState, "network-instance vlan-v1", "reads down, want up",
			"the device reports oper-down-reason admin-down") {
			t.Errorf("not named: %s", res.Message())
		}
		if res.Reason() != status.ReasonNotConverged {
			t.Errorf("reason %s", res.Reason())
		}
	})
	t.Run("member interface up but reporting a reason", func(t *testing.T) {
		s, in, r, _ := serviceFixture(t, m, nil)
		r.set("leaf02", InstanceInterfaceOperDownReasonPath("vlan-v1", "ethernet-1/1.990"), "mac-dup-detected")
		res := mustMiss(t, s, in)
		if !hasMissing(res, "leaf02", CheckInstanceInterfaceOperState, "interface ethernet-1/1.990", "oper-down-reason reports mac-dup-detected, want absent") {
			t.Errorf("not named: %s", res.Message())
		}
	})
	t.Run("subinterface down", func(t *testing.T) {
		s, in, r, _ := serviceFixture(t, m, nil)
		r.set("leaf02", SubinterfaceOperStatePath("ethernet-1/1", 990), "down")
		r.set("leaf02", SubinterfaceOperDownReasonPath("ethernet-1/1", 990), "port-down")
		res := mustMiss(t, s, in)
		if !hasMissing(res, "leaf02", CheckSubinterfaceOperState, "subinterface ethernet-1/1.990", "reads down", "port-down") {
			t.Errorf("not named: %s", res.Message())
		}
	})
	t.Run("subinterface absent from state", func(t *testing.T) {
		s, in, r, _ := serviceFixture(t, m, nil)
		r.set("leaf01", SubinterfaceOperStatePath("ethernet-1/1", 990))
		res := mustMiss(t, s, in)
		if !hasMissing(res, "leaf01", CheckSubinterfaceOperState, "reads nothing, want up") {
			t.Errorf("not named: %s", res.Message())
		}
	})
	t.Run("an overlay child on the vlan's instance in the running datastore", func(t *testing.T) {
		s, in, r, _ := serviceFixture(t, m, nil)
		r.running["leaf01"] = `{"network-instance":[{"name":"vlan-v1","admin-state":"enable","vxlan-interface":[{"name":"vxlan0.19990"}],` +
			`"protocols":{"bgp-evpn":{"bgp-instance":[{"id":1}]}}}]}`
		res := mustMiss(t, s, in)
		if !hasMissing(res, "leaf01", CheckWritten, "vlan network-instance vlan-v1 carries an overlay child", "vxlan-interface/name reads vxlan0.19990") ||
			!hasMissing(res, "leaf01", CheckWritten, "bgp-evpn/bgp-instance/id reads 1") {
			t.Errorf("not named: %s", res.Message())
		}
	})
}

// ---------------------------------------------------------------------------
// mac-vrf.
// ---------------------------------------------------------------------------

func TestMACVRFPassSingleLeafReadsNoRemote(t *testing.T) {
	s, in, r, _ := serviceFixture(t, macvrfModel(t, false, "leaf01"), nil)
	mustPass(t, s, in)
	for _, p := range r.allRequested() {
		if strings.Contains(p, "multicast-destinations") || strings.Contains(p, "/vtep[") {
			t.Errorf("a one-leaf mac-vrf read remote evidence: %s", p)
		}
	}
}

func TestMACVRFPassSpanning(t *testing.T) {
	s, in, r, _ := serviceFixture(t, macvrfModel(t, false, "leaf01", "leaf02", "leaf03"), nil)
	mustPass(t, s, in)
	got := strings.Join(r.requested["leaf02"], "\n")
	for _, want := range []string{
		"/network-instance[name=macvrf-m1]/oper-state",
		"/network-instance[name=macvrf-m1]/interface[name=ethernet-1/1.990]/oper-state",
		"/interface[name=ethernet-1/1]/subinterface[index=990]/oper-state",
		"/network-instance[name=macvrf-m1]/vxlan-interface[name=vxlan0.19990]/oper-state",
		"/tunnel-interface[name=vxlan0]/vxlan-interface[index=19990]/oper-state",
		"/network-instance[name=macvrf-m1]/protocols/bgp-evpn/bgp-instance[id=1]/oper-state",
		"/network-instance[name=macvrf-m1]/protocols/bgp-vpn/bgp-instance[id=1]/route-distinguisher/route-distinguisher-origin",
		"/network-instance[name=macvrf-m1]/protocols/bgp-vpn/bgp-instance[id=1]/route-target/export-route-target-origin",
		"/network-instance[name=macvrf-m1]/protocols/bgp-vpn/bgp-instance[id=1]/route-target/import-route-target-origin",
		"/tunnel-interface[name=vxlan0]/vxlan-interface[index=19990]/bridge-table/multicast-destinations/destination[vtep=10.0.0.1][vni=19990]/destination-index",
		"/tunnel-interface[name=vxlan0]/vxlan-interface[index=19990]/bridge-table/multicast-destinations/destination[vtep=10.0.0.1][vni=19990]/not-programmed-reason",
		"/tunnel-interface[name=vxlan0]/vxlan-interface[index=19990]/bridge-table/multicast-destinations/destination[vtep=10.0.0.3][vni=19990]/destination-index",
		"/tunnel/vxlan-tunnel/vtep[address=10.0.0.1]/index",
		"/tunnel/vxlan-tunnel/vtep[address=10.0.0.3]/index",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("leaf02 did not read %s", want)
		}
	}
	if strings.Contains(got, "10.0.0.2") {
		t.Error("leaf02 read its own VTEP as a remote")
	}
}

func TestMACVRFMissingInvariantsNamed(t *testing.T) {
	m := macvrfModel(t, false, "leaf01", "leaf02")
	dest := MulticastDestinationIndexPath(19990, "10.0.0.2", 19990)
	for _, tc := range []struct {
		name   string
		node   string
		set    map[string][]string
		check  Check
		reason string
		frags  []string
	}{
		{"vxlan-interface member down", "leaf01", map[string][]string{
			InstanceVXLANInterfaceOperStatePath("macvrf-m1", "vxlan0.19990"):      {"down"},
			InstanceVXLANInterfaceOperDownReasonPath("macvrf-m1", "vxlan0.19990"): {"vxlan-tunnel-down"}},
			CheckVXLANInterfaceOperState, status.ReasonNotConverged, []string{"vxlan-interface vxlan0.19990", "vxlan-tunnel-down"}},
		{"tunnel vxlan-interface absent", "leaf02", map[string][]string{TunnelVXLANInterfaceOperStatePath(19990): nil},
			CheckVXLANInterfaceOperState, status.ReasonNotConverged, []string{"tunnel vxlan0.19990", "reads nothing"}},
		{"EVPN instance down", "leaf02", map[string][]string{
			EVPNInstanceOperStatePath("macvrf-m1", 1):      {"down"},
			EVPNInstanceOperDownReasonPath("macvrf-m1", 1): {"admin-disabled"}},
			CheckEVPNInstanceOperState, status.ReasonNotConverged, []string{"EVPN instance 1 (evi 19990)", "oper-down-reason admin-disabled"}},
		{"RD not device-derived", "leaf01", map[string][]string{RDOriginPath("macvrf-m1", 1): {"none"}},
			CheckBGPVPNOrigin, status.ReasonNotConverged, []string{"route distinguisher", "reads none, want auto-derived-from-evi"}},
		{"export RT dropped by the render", "leaf01", map[string][]string{RTOriginPath("macvrf-m1", 1, "export"): {"auto-derived-from-evi"}},
			CheckBGPVPNOrigin, status.ReasonNotConverged, []string{"export route target target:65000:19990", "want manual"}},
		{"import RT", "leaf02", map[string][]string{RTOriginPath("macvrf-m1", 1, "import"): {"from-import-policy"}},
			CheckBGPVPNOrigin, status.ReasonNotConverged, []string{"import route target", "from-import-policy"}},
		{"multicast destination to the remote VTEP absent", "leaf01", map[string][]string{dest: nil},
			CheckMulticastDestination, status.ReasonRoutesMissing, []string{"macvrf-m1 multicast destination to leaf02 VTEP 10.0.0.2 (vni 19990)", "reads nothing"}},
		{"multicast destination index zero", "leaf01", map[string][]string{dest: {"0"}},
			CheckNotProgrammed, status.ReasonNotProgrammed, []string{"leaf02 VTEP 10.0.0.2", "reads 0"}},
		{"multicast destination not programmed", "leaf01", map[string][]string{
			MulticastDestinationNotProgrammedPath(19990, "10.0.0.2", 19990): {"multicast-limit"}},
			CheckNotProgrammed, status.ReasonNotProgrammed, []string{"not-programmed-reason reports multicast-limit, want absent"}},
		{"remote VTEP absent", "leaf02", map[string][]string{VTEPIndexPath("10.0.0.1"): nil},
			CheckRemoteVTEP, status.ReasonRoutesMissing, []string{"remote VTEP 10.0.0.1 of leaf01", "reads nothing"}},
		{"remote VTEP index zero", "leaf02", map[string][]string{VTEPIndexPath("10.0.0.1"): {"0"}},
			CheckNotProgrammed, status.ReasonNotProgrammed, []string{"remote VTEP 10.0.0.1"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, in, r, _ := serviceFixture(t, m, nil)
			for p, v := range tc.set {
				r.set(tc.node, p, v...)
			}
			res := mustMiss(t, s, in)
			if !hasMissing(res, tc.node, tc.check, tc.frags...) {
				t.Errorf("%s: not named: %s", tc.check, res.Message())
			}
			if len(res.Missing) != 1 {
				t.Errorf("want exactly one invariant, got %s", res.Message())
			}
			if res.Reason() != tc.reason {
				t.Errorf("reason %s, want %s", res.Reason(), tc.reason)
			}
		})
	}
}

func TestMACVRFRemoteWithoutLoopbackIsAnInputError(t *testing.T) {
	s, in, _, _ := serviceFixture(t, macvrfModel(t, false, "leaf01", "leaf02"), nil)
	in.Loopbacks = map[string]string{"leaf01": "10.0.0.1"}
	_, err := s.VerifyService(context.Background(), in)
	if err == nil || IsCouldNotRun(err) || !strings.Contains(err.Error(), "leaf02") {
		t.Fatalf("want an input error naming leaf02, got %v", err)
	}
}

// The mac-vrf with an anycast gateway: both instances read, irb0.<vlan> a
// member of both, the routed half's gateway subnet local on every leaf.
func TestMACVRFGatewayReadsBothHalves(t *testing.T) {
	s, in, r, _ := serviceFixture(t, macvrfModel(t, true, "leaf01", "leaf02"), map[string][]string{"ipvrf-m1": {"10.10.0.0/24"}})
	mustPass(t, s, in)
	got := strings.Join(r.requested["leaf01"], "\n")
	for _, want := range []string{
		InstanceInterfaceOperStatePath("macvrf-m1", "irb0.990"),
		InstanceInterfaceOperStatePath("ipvrf-m1", "irb0.990"),
		InstanceVXLANInterfaceOperStatePath("ipvrf-m1", "vxlan0.19991"),
		TunnelVXLANInterfaceOperStatePath(19991),
		EVPNInstanceOperStatePath("ipvrf-m1", 1),
		InstanceRouteActivePath("ipvrf-m1", "10.10.0.0/24", RouteTypeLocal),
		InstanceRouteActivePath("ipvrf-m1", "2001:db8:10::/64", RouteTypeLocal),
		MulticastDestinationIndexPath(19990, "10.0.0.2", 19990),
	} {
		if !strings.Contains(got, want) {
			t.Errorf("leaf01 did not read %s", want)
		}
	}
	if strings.Contains(got, "route-type=bgp-evpn") {
		t.Error("the gateway subnet, local on every leaf, was read as a remote route")
	}

	r.set("leaf02", InstanceInterfaceOperStatePath("ipvrf-m1", "irb0.990"), "down")
	r.set("leaf02", InstanceInterfaceOperDownReasonPath("ipvrf-m1", "irb0.990"), "associated-mac-vrf-down")
	res := mustMiss(t, s, in)
	if !hasMissing(res, "leaf02", CheckInstanceInterfaceOperState, "network-instance ipvrf-m1 interface irb0.990", "associated-mac-vrf-down") {
		t.Errorf("not named: %s", res.Message())
	}
}

func sortedCopy(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}

// TestMACVRFVTEPTeardownIsRoutesMissing is the pass observed live on 25.7.1
// after a leaf's uplinks were taken down (T167, 2026-09-24): the remote VTEP
// still reads index 0 while the multicast destination to it — the route
// evidence it derives from — is already gone. That zero is the missing
// route's consequence, so the pass is RoutesMissing, never NotProgrammed;
// the negative control is the same zero index with the destination present,
// which stays NotProgrammed (TestMACVRFMissingInvariantsNamed).
func TestMACVRFVTEPTeardownIsRoutesMissing(t *testing.T) {
	m := macvrfModel(t, false, "leaf01", "leaf02")
	s, in, r, _ := serviceFixture(t, m, nil)
	r.set("leaf02", MulticastDestinationIndexPath(19990, "10.0.0.1", 19990))
	r.set("leaf02", VTEPIndexPath("10.0.0.1"), "0")
	res := mustMiss(t, s, in)
	if res.Reason() != status.ReasonRoutesMissing {
		t.Fatalf("reason %s, want RoutesMissing: %s", res.Reason(), res.Message())
	}
	if !hasMissing(res, "leaf02", CheckRemoteVTEP, "remote VTEP 10.0.0.1 of leaf01", "reads 0 and its route evidence") {
		t.Errorf("remote VTEP not named under remote-vtep: %s", res.Message())
	}
	if !hasMissing(res, "leaf02", CheckMulticastDestination, "leaf01 VTEP 10.0.0.1") {
		t.Errorf("multicast destination not named: %s", res.Message())
	}
	for _, mi := range res.Missing {
		if mi.Check == CheckNotProgrammed {
			t.Errorf("a teardown zero was reported NotProgrammed: %s", mi.Detail)
		}
	}
}
