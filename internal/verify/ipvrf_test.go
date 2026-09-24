package verify

import (
	"strings"
	"testing"

	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/status"
)

var ipvrfPrefixes = map[string][]string{"ipvrf-r1": {"10.199.1.0/24", "10.199.2.0/24"}}

// leaf01 attaches 10.199.1.0/24 and 2001:db8:199:1::/64, leaf02 10.199.2.0/24:
// each is local where attached and a bgp-evpn route on the other leaf.
func TestIPVRFPassLocalAndRemotePrefixes(t *testing.T) {
	s, in, r, _ := serviceFixture(t, ipvrfModel(t), ipvrfPrefixes)
	mustPass(t, s, in)
	for node, want := range map[string][]string{
		"leaf01": {
			"/network-instance[name=ipvrf-r1]/route-table/ipv4-unicast/route[ipv4-prefix=10.199.1.0/24][route-type=local]/active",
			"/network-instance[name=ipvrf-r1]/route-table/ipv6-unicast/route[ipv6-prefix=2001:db8:199:1::/64][route-type=local]/active",
			"/network-instance[name=ipvrf-r1]/route-table/ipv4-unicast/route[ipv4-prefix=10.199.2.0/24][route-type=bgp-evpn]/active",
			"/network-instance[name=ipvrf-r1]/oper-state",
			"/network-instance[name=ipvrf-r1]/interface[name=ethernet-1/1.991]/oper-state",
			"/interface[name=ethernet-1/1]/subinterface[index=991]/oper-state",
			"/network-instance[name=ipvrf-r1]/vxlan-interface[name=vxlan0.19991]/oper-state",
			"/tunnel-interface[name=vxlan0]/vxlan-interface[index=19991]/oper-state",
			"/network-instance[name=ipvrf-r1]/protocols/bgp-evpn/bgp-instance[id=1]/oper-state",
			"/network-instance[name=ipvrf-r1]/protocols/bgp-vpn/bgp-instance[id=1]/route-distinguisher/route-distinguisher-origin",
		},
		"leaf02": {
			"/network-instance[name=ipvrf-r1]/route-table/ipv4-unicast/route[ipv4-prefix=10.199.2.0/24][route-type=local]/active",
			"/network-instance[name=ipvrf-r1]/route-table/ipv4-unicast/route[ipv4-prefix=10.199.1.0/24][route-type=bgp-evpn]/active",
			"/network-instance[name=ipvrf-r1]/route-table/ipv6-unicast/route[ipv6-prefix=2001:db8:199:1::/64][route-type=bgp-evpn]/active",
		},
	} {
		got := strings.Join(r.requested[node], "\n")
		for _, w := range want {
			if !strings.Contains(got, w) {
				t.Errorf("%s did not read %s", node, w)
			}
		}
	}
	// an ip-vrf has no multicast destinations; its remote evidence is its routes
	for _, p := range r.allRequested() {
		if strings.Contains(p, "multicast-destinations") || strings.Contains(p, "/vtep[") {
			t.Errorf("ip-vrf read %s", p)
		}
	}
}

func TestIPVRFSingleLeafReadsNoRemote(t *testing.T) {
	m := buildService(t, model.ServiceInput{ServiceID: "r2", Construct: model.ConstructIPVRF,
		Routed: &model.RoutedService{L3VNI: 19992, Attachments: []model.RoutedAttachment{
			{Node: "leaf01", Port: "ethernet-1/2", IPv4: []string{"10.20.0.1/24"}}}, IPMTU: 9348}})
	s, in, r, _ := serviceFixture(t, m, map[string][]string{"ipvrf-r2": {"10.20.0.0/24"}})
	mustPass(t, s, in)
	for _, p := range r.allRequested() {
		if strings.Contains(p, "bgp-evpn]") {
			t.Errorf("a one-leaf ip-vrf read a remote route: %s", p)
		}
	}
	if !strings.Contains(strings.Join(r.requested["leaf01"], "\n"), "/interface[name=ethernet-1/2]/subinterface[index=0]/oper-state") {
		t.Error("untagged routed subinterface 0 not read")
	}
}

func TestIPVRFMissingInvariantsNamed(t *testing.T) {
	m := ipvrfModel(t)
	remote4 := InstanceRouteActivePath("ipvrf-r1", "10.199.2.0/24", RouteTypeBGPEVPN)
	for _, tc := range []struct {
		name   string
		node   string
		set    map[string][]string
		check  Check
		reason string
		frags  []string
	}{
		{"network-instance down", "leaf02", map[string][]string{
			NetworkInstanceOperStatePath("ipvrf-r1"):      {"down"},
			NetworkInstanceOperDownReasonPath("ipvrf-r1"): {"admin-down"}},
			CheckNetworkInstanceOperState, status.ReasonNotConverged, []string{"network-instance ipvrf-r1", "admin-down"}},
		{"routed subinterface down", "leaf01", map[string][]string{
			SubinterfaceOperStatePath("ethernet-1/1", 991):      {"down"},
			SubinterfaceOperDownReasonPath("ethernet-1/1", 991): {"no-ip-config"}},
			CheckSubinterfaceOperState, status.ReasonNotConverged, []string{"subinterface ethernet-1/1.991", "no-ip-config"}},
		{"vxlan-interface member reporting a reason", "leaf01", map[string][]string{
			InstanceVXLANInterfaceOperDownReasonPath("ipvrf-r1", "vxlan0.19991"): {"vrf-type-mismatch"}},
			CheckVXLANInterfaceOperState, status.ReasonNotConverged, []string{"vxlan0.19991", "vrf-type-mismatch, want absent"}},
		{"EVPN instance down", "leaf01", map[string][]string{
			EVPNInstanceOperStatePath("ipvrf-r1", 1):      {"down"},
			EVPNInstanceOperDownReasonPath("ipvrf-r1", 1): {"bgp-vpn-instance-oper-down"}},
			CheckEVPNInstanceOperState, status.ReasonNotConverged, []string{"evi 19991", "bgp-vpn-instance-oper-down"}},
		{"local prefix absent", "leaf01", map[string][]string{InstanceRouteActivePath("ipvrf-r1", "10.199.1.0/24", RouteTypeLocal): nil},
			CheckLocalPrefixRoute, status.ReasonNotConverged, []string{"local prefix 10.199.1.0/24", "reads nothing, want true"}},
		{"remote prefix absent", "leaf01", map[string][]string{remote4: nil},
			CheckRemotePrefixRoute, status.ReasonRoutesMissing, []string{"remote prefix 10.199.2.0/24 (attached on [leaf02])", "route-type=bgp-evpn"}},
		{"remote prefix present, not active", "leaf01", map[string][]string{remote4: {"false"}},
			CheckRemotePrefixRoute, status.ReasonRoutesMissing, []string{"10.199.2.0/24", "reads false, want true"}},
		{"remote IPv6 prefix absent", "leaf02", map[string][]string{
			InstanceRouteActivePath("ipvrf-r1", "2001:db8:199:1::/64", RouteTypeBGPEVPN): nil},
			CheckRemotePrefixRoute, status.ReasonRoutesMissing, []string{"remote prefix 2001:db8:199:1::/64 (attached on [leaf01])", "ipv6-unicast"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, in, r, _ := serviceFixture(t, m, ipvrfPrefixes)
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

// A remote prefix installed on this leaf under another route type is not the
// EVPN route the service needs.
func TestIPVRFRemotePrefixOfAnotherRouteTypeIsMissing(t *testing.T) {
	s, in, r, _ := serviceFixture(t, ipvrfModel(t), ipvrfPrefixes)
	r.set("leaf01", InstanceRouteActivePath("ipvrf-r1", "10.199.2.0/24", RouteTypeBGPEVPN))
	r.set("leaf01", InstanceRouteActivePath("ipvrf-r1", "10.199.2.0/24", "static"), "true")
	res := mustMiss(t, s, in)
	if !hasMissing(res, "leaf01", CheckRemotePrefixRoute, "10.199.2.0/24") || res.Reason() != status.ReasonRoutesMissing {
		t.Errorf("not named: %s / %s", res.Reason(), res.Message())
	}
}

// A declared prefix no leaf of the service attaches must still be present and
// active in every leaf's route table, under any route type.
func TestIPVRFDeclaredUnattachedPrefix(t *testing.T) {
	prefixes := map[string][]string{"ipvrf-r1": {"10.199.1.0/24", "10.199.2.0/24", "10.77.0.0/16"}}
	s, in, r, _ := serviceFixture(t, ipvrfModel(t), prefixes)
	anyType := InstanceRouteActivePath("ipvrf-r1", "10.77.0.0/16", "")
	if anyType != "/network-instance[name=ipvrf-r1]/route-table/ipv4-unicast/route[ipv4-prefix=10.77.0.0/16]/active" {
		t.Fatalf("path %s", anyType)
	}
	mustPass(t, s, in)
	r.set("leaf02", anyType)
	res := mustMiss(t, s, in)
	if !hasMissing(res, "leaf02", CheckRemotePrefixRoute, "declared prefix 10.77.0.0/16 (attached on no leaf of the service)") ||
		res.Reason() != status.ReasonRoutesMissing {
		t.Errorf("not named: %s / %s", res.Reason(), res.Message())
	}
}

func TestCanonicalPrefix(t *testing.T) {
	for in, want := range map[string]string{
		"10.199.1.1/24":        "10.199.1.0/24",
		"10.199.1.0/24":        "10.199.1.0/24",
		"2001:db8:199:1::1/64": "2001:db8:199:1::/64",
		"2001:DB8:10::1/64":    "2001:db8:10::/64",
		"not-a-prefix":         "not-a-prefix",
	} {
		if got := canonicalPrefix(in); got != want {
			t.Errorf("canonicalPrefix(%s) = %s, want %s", in, got, want)
		}
	}
}
