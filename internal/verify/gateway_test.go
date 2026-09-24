package verify

// T116: the anycast-gateway read-back of a `mac-vrf` (gateway.go): the IRB
// subinterface, its anycast-gw state, each declared anycast address, and the
// other leaves' EVPN IP-prefix (Type-5) routes per declared, qualified family
// (FR-032, FR-100, CR-010).

import (
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/status"
)

func ipv4GatewayModel(t *testing.T, nodes ...string) *model.ServiceModel {
	var att []model.Attachment
	for _, n := range nodes {
		att = append(att, model.Attachment{Node: n, Port: "ethernet-1/1"})
	}
	return buildService(t, model.ServiceInput{ServiceID: "m1", Construct: model.ConstructMACVRF,
		L2:      &model.L2Segment{VLAN: 990, L2VNI: 19990, Attachments: att},
		Gateway: &model.Gateway{L3VNI: 19991, IPv4: []string{"10.10.0.1/24"}, IPMTU: 1500}})
}

// gatewayPaths are the paths of node's requests that gateway.go adds: irb0's own and the EVPN RIB's.
func gatewayPaths(r *svcReader, node string) []string {
	var out []string
	for _, p := range dedupe(r.requested[node]) {
		if strings.HasPrefix(p, "/interface[name=irb0]") || strings.HasPrefix(p, EVPNIPPrefixRoutePath) {
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out
}

var (
	v4Type5FromLeaf02 = Type5UsedRoutePath("10.0.0.2:19991", "10.10.0.0/24")
	v6Type5FromLeaf02 = Type5UsedRoutePath("10.0.0.2:19991", "2001:db8:10::/64")
)

// Dual-stack, two leaves, everything present: the pass passes and every gateway leaf of
// each node is read, keyed to irb0.990 and — for the Type-5 — to the OTHER leaf's RD.
func TestGatewayDualStackPass(t *testing.T) {
	s, in, r, _ := serviceFixture(t, macvrfModel(t, true, "leaf01", "leaf02"), nil)
	mustPass(t, s, in)
	want := []string{
		v4Type5FromLeaf02,
		v6Type5FromLeaf02,
		"/interface[name=irb0]/subinterface[index=990]/anycast-gw/anycast-gw-mac-origin",
		"/interface[name=irb0]/subinterface[index=990]/ipv4/address[ip-prefix=10.10.0.1/24]/status",
		"/interface[name=irb0]/subinterface[index=990]/ipv6/address[ip-prefix=2001:db8:10::1/64]/status",
		"/interface[name=irb0]/subinterface[index=990]/oper-down-reason",
		"/interface[name=irb0]/subinterface[index=990]/oper-state",
	}
	sort.Strings(want)
	if got := gatewayPaths(r, "leaf01"); !reflect.DeepEqual(got, want) {
		t.Errorf("leaf01 gateway reads:\n got %v\nwant %v", got, want)
	}
	for _, p := range gatewayPaths(r, "leaf02") {
		if strings.Contains(p, "10.0.0.2:") {
			t.Errorf("leaf02 read its own Type-5 as a remote route: %s", p)
		}
	}
	if !strings.Contains(strings.Join(gatewayPaths(r, "leaf02"), "\n"), Type5UsedRoutePath("10.0.0.1:19991", "2001:db8:10::/64")) {
		t.Error("leaf02 did not read leaf01's IPv6 Type-5")
	}
}

// The CR-010 case: the IPv4 Type-5 present, the IPv6 one absent → RoutesMissing naming the
// IPv6 route, the remote leaf and its RD; never a pass on the IPv4 half alone. A path that
// is present but not used is missing too.
func TestGatewayIPv6Type5MissingIsRoutesMissing(t *testing.T) {
	for name, vals := range map[string][]string{"absent": nil, "not used on any path": {"false", "false"}} {
		t.Run(name, func(t *testing.T) {
			s, in, r, _ := serviceFixture(t, macvrfModel(t, true, "leaf01", "leaf02"), nil)
			r.set("leaf01", v6Type5FromLeaf02, vals...)
			res := mustMiss(t, s, in)
			if !hasMissing(res, "leaf01", CheckType5Route,
				"EVPN IP-prefix (Type-5) route 2001:db8:10::/64 from leaf02 (RD 10.0.0.2:19991)") {
				t.Errorf("the IPv6 Type-5 is not named: %s", res.Message())
			}
			if len(res.Missing) != 1 || res.Reason() != status.ReasonRoutesMissing {
				t.Errorf("want exactly the IPv6 Type-5, RoutesMissing; got %s: %s", res.Reason(), res.Message())
			}
			if ReasonOf(CheckType5Route) != status.ReasonRoutesMissing {
				t.Error("a missing Type-5 is not RoutesMissing")
			}
		})
	}
	// one used path of several is enough
	s, in, r, _ := serviceFixture(t, macvrfModel(t, true, "leaf01", "leaf02"), nil)
	r.set("leaf01", v6Type5FromLeaf02, "false", "true")
	mustPass(t, s, in)
}

// An IPv4-only gateway: no IPv6 path is ever requested, on any node (FR-032).
func TestGatewayIPv4OnlyReadsNoIPv6(t *testing.T) {
	s, in, r, _ := serviceFixture(t, ipv4GatewayModel(t, "leaf01", "leaf02"), nil)
	mustPass(t, s, in)
	want := []string{
		v4Type5FromLeaf02,
		"/interface[name=irb0]/subinterface[index=990]/anycast-gw/anycast-gw-mac-origin",
		"/interface[name=irb0]/subinterface[index=990]/ipv4/address[ip-prefix=10.10.0.1/24]/status",
		"/interface[name=irb0]/subinterface[index=990]/oper-down-reason",
		"/interface[name=irb0]/subinterface[index=990]/oper-state",
	}
	sort.Strings(want)
	if got := gatewayPaths(r, "leaf01"); !reflect.DeepEqual(got, want) {
		t.Errorf("leaf01 gateway reads:\n got %v\nwant %v", got, want)
	}
	for _, p := range r.allRequested() {
		if strings.Contains(p, "ipv6") || strings.Contains(p, "2001:") || strings.Contains(p, "fe80") {
			t.Errorf("an IPv4-only gateway read an IPv6 path: %s", p)
		}
	}
}

// An anycast address the device does not report preferred fails naming it; so does an IRB
// subinterface down (with the device's reason) and an absent anycast-gw state.
func TestGatewayLocalInvariantsNamed(t *testing.T) {
	m := macvrfModel(t, true, "leaf01", "leaf02")
	for _, tc := range []struct {
		name  string
		node  string
		set   map[string][]string
		check Check
		frags []string
	}{
		{"IPv6 anycast address tentative", "leaf02",
			map[string][]string{AddressStatusPath("irb0", 990, "2001:db8:10::1/64"): {"tentative"}},
			CheckAnycastAddress, []string{"anycast address 2001:db8:10::1/64 of irb0.990", "reads tentative, want preferred"}},
		{"IPv4 anycast address absent", "leaf01",
			map[string][]string{AddressStatusPath("irb0", 990, "10.10.0.1/24"): nil},
			CheckAnycastAddress, []string{"anycast address 10.10.0.1/24 of irb0.990", "reads nothing"}},
		{"IRB subinterface down", "leaf01", map[string][]string{
			SubinterfaceOperStatePath("irb0", 990):      {"down"},
			SubinterfaceOperDownReasonPath("irb0", 990): {"ip-mtu-larger-than-oper-mac-vrf-mtu"}},
			CheckIRBSubinterfaceOperState, []string{"IRB subinterface irb0.990", "reads down", "ip-mtu-larger-than-oper-mac-vrf-mtu"}},
		{"IRB subinterface up with a reason", "leaf01", map[string][]string{
			SubinterfaceOperDownReasonPath("irb0", 990): {"other"}},
			CheckIRBSubinterfaceOperState, []string{"IRB subinterface irb0.990", "reports other, want absent"}},
		{"anycast-gw state absent", "leaf02", map[string][]string{AnycastGWMACOriginPath("irb0", 990): nil},
			CheckAnycastGateway, []string{"anycast gateway of irb0.990", "anycast-gw-mac-origin reads nothing"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, in, r, _ := serviceFixture(t, m, nil)
			for p, v := range tc.set {
				r.set(tc.node, p, v...)
			}
			res := mustMiss(t, s, in)
			if !hasMissing(res, tc.node, tc.check, tc.frags...) {
				t.Errorf("%s not named: %s", tc.check, res.Message())
			}
			if len(res.Missing) != 1 || res.Reason() != status.ReasonNotConverged {
				t.Errorf("want exactly one NotConverged invariant, got %s: %s", res.Reason(), res.Message())
			}
		})
	}
}

// A single-leaf gateway has no remote leaf: no Type-5 is read, and it passes.
func TestGatewaySingleLeafReadsNoType5(t *testing.T) {
	s, in, r, _ := serviceFixture(t, macvrfModel(t, true, "leaf01"), nil)
	mustPass(t, s, in)
	for _, p := range r.allRequested() {
		if strings.Contains(p, "bgp-rib") {
			t.Errorf("a one-leaf gateway read a Type-5 route: %s", p)
		}
	}
	if len(gatewayPaths(r, "leaf01")) != 5 {
		t.Errorf("the local gateway leaves are still read: %v", gatewayPaths(r, "leaf01"))
	}
}

// The record does not qualify ip-vrf.evpn-type5-ipv6: the IPv6 Type-5 is not read (and its
// absence fails nothing); the IPv4 one, qualified, still is. A record qualifying neither
// reads no Type-5.
func TestGatewayUnqualifiedType5NotRead(t *testing.T) {
	s, in, r, _ := serviceFixture(t, macvrfModel(t, true, "leaf01", "leaf02"), nil)
	var asked []string
	in.Qualified = func(key string) bool {
		asked = append(asked, key)
		return key == "ip-vrf.evpn-type5-ipv4"
	}
	r.set("leaf01", v6Type5FromLeaf02)
	mustPass(t, s, in)
	got := strings.Join(r.allRequested(), "\n")
	if strings.Contains(got, "ip-prefix=2001:db8:10::/64]") {
		t.Error("the unqualified IPv6 Type-5 was read")
	}
	if !strings.Contains(got, v4Type5FromLeaf02) {
		t.Error("the qualified IPv4 Type-5 was not read")
	}
	if !contains(asked, "ip-vrf.evpn-type5-ipv6") || !contains(asked, "ip-vrf.evpn-type5-ipv4") {
		t.Errorf("record keys asked: %v", asked)
	}

	s, in, r, _ = serviceFixture(t, macvrfModel(t, true, "leaf01", "leaf02"), nil)
	in.Qualified = func(string) bool { return false }
	mustPass(t, s, in)
	for _, p := range r.allRequested() {
		if strings.Contains(p, "bgp-rib") {
			t.Errorf("an unqualified Type-5 was read: %s", p)
		}
	}
}

// A gateway's Type-5 of a remote leaf with no allocated system0.0 address cannot be keyed:
// an input error, never a pass that could not run.
func TestGatewayType5NeedsTheRemoteLoopback(t *testing.T) {
	in := ServiceInput{Model: ipv4GatewayModel(t, "leaf01", "leaf02"), Loopbacks: map[string]string{"leaf01": "10.0.0.1"}}
	if _, err := ServiceExpectations(in); err == nil || !strings.Contains(err.Error(), "leaf02") {
		t.Fatalf("want an input error naming leaf02, got %v", err)
	}
}
