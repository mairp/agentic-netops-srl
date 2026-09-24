package verify

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"

	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/status"
)

// exposition in the collector's observed naming (G7, tests/gate/observed/
// telemetry-series.json; deploy/observability/device-metrics live output).
const collectorFixture = `# HELP srl_nokia_network_instance:network_instance_protocols_srl_nokia_bgp:bgp_neighbor_session_state
# TYPE srl_nokia_network_instance:network_instance_protocols_srl_nokia_bgp:bgp_neighbor_session_state gauge
srl_nokia_network_instance:network_instance_protocols_srl_nokia_bgp:bgp_neighbor_session_state{neighbor_peer_address="10.0.0.1",network_instance_name="default",source="leaf01",subscription_name="device-state"} 5
srl_nokia_network_instance:network_instance_protocols_srl_nokia_bgp:bgp_neighbor_session_state{neighbor_peer_address="10.0.0.3",network_instance_name="default",source="leaf01",subscription_name="device-state"} 2
srl_nokia_network_instance:network_instance_protocols_srl_nokia_bgp:bgp_neighbor_session_state{neighbor_peer_address="10.0.0.1",network_instance_name="default",source="leaf02",subscription_name="device-state"} 5
srl_nokia_network_instance:network_instance_protocols_srl_nokia_bgp:bgp_neighbor_afi_safi_oper_state{afi_safi_afi_safi_name="evpn",neighbor_peer_address="fd00::1",network_instance_name="default",source="leaf01"} 1
srl_nokia_network_instance:network_instance_protocols_srl_nokia_bgp:bgp_neighbor_afi_safi_oper_state{afi_safi_afi_safi_name="ipv4-unicast",neighbor_peer_address="fd00::1",network_instance_name="default",source="leaf01"} 0
srl_nokia_network_instance:network_instance_protocols_bgp_evpn_srl_nokia_bgp_evpn:bgp_instance_evi{bgp_instance_id="1",network_instance_name="vt-scratch-mv",source="leaf01"} 101
srl_nokia_interfaces:interface_oper_state{interface_name="ethernet-1/49",source="leaf01"} 1
srl_nokia_interfaces:interface_subinterface_oper_state{interface_name="ethernet-1/49",subinterface_index="0",source="leaf01"} 0
srl_nokia_network_instance:network_instance_route_table_srl_nokia_ip_route_tables:ipv4_unicast_route_active{network_instance_name="default",route_id="0",route_ipv4_prefix="10.255.0.2/32",route_origin_network_instance="default",route_route_owner="bgp_mgr",route_route_type="srl_nokia-common:bgp",source="leaf01"} 1
srl_nokia_network_instance:network_instance_oper_state{network_instance_name="default",source="leaf01"} 1
`

func TestSeriesKeyDropsModuleQualifiers(t *testing.T) {
	for name, want := range map[string]string{
		"srl_nokia_network_instance:network_instance_protocols_srl_nokia_bgp:bgp_neighbor_session_state":     "network_instance_protocols_bgp_neighbor_session_state",
		"srl_nokia_network_instance:network_instance_protocols_bgp_evpn_srl_nokia_bgp_evpn:bgp_instance_evi": "network_instance_protocols_bgp_evpn_bgp_instance_evi",
		"srl_nokia_interfaces:interface_oper_state":                                                          "interface_oper_state",
	} {
		if got := SeriesKey(name); got != want {
			t.Errorf("SeriesKey(%s) = %s, want %s", name, got, want)
		}
	}
}

func fixtureSamples(t *testing.T, node string) []Sample {
	t.Helper()
	all, err := ParseExposition(strings.NewReader(collectorFixture))
	if err != nil {
		t.Fatal(err)
	}
	var out []Sample
	for _, s := range all {
		if s.Labels["source"] == node {
			out = append(out, s)
		}
	}
	return out
}

// TestMatchStateKeyedAndDecoded: every Fabric read-back path resolves to the
// one keyed instance and its value decoded back to the device's string; a
// neighbour, family or prefix the node does not report is absent.
func TestMatchStateKeyedAndDecoded(t *testing.T) {
	paths := []string{
		SessionStatePath("10.0.0.1"),
		SessionStatePath("10.0.0.3"),
		SessionStatePath("10.0.0.9"), // not reported → absent
		EVPNFamilyOperStatePath("fd00::1"),
		InterfaceOperStatePath("ethernet-1/49"),
		SubinterfaceOperStatePath("ethernet-1/49", 0),
		RouteActivePath("ipv4-unicast", "ipv4-prefix", "10.255.0.2/32"),
		RouteActivePath("ipv4-unicast", "ipv4-prefix", "10.255.0.3/32"), // not reported → absent
		DeviceObjectStatePath("vt-scratch-mv"),                          // no oper-state series → absent
		DeviceObjectStatePath("default"),                                // presence
	}
	got, err := MatchState(fixtureSamples(t, "leaf01"), paths)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string][]string{
		SessionStatePath("10.0.0.1"):                                    {"established"},
		SessionStatePath("10.0.0.3"):                                    {"active"},
		EVPNFamilyOperStatePath("fd00::1"):                              {"up"},
		InterfaceOperStatePath("ethernet-1/49"):                         {"up"},
		SubinterfaceOperStatePath("ethernet-1/49", 0):                   {"down"},
		RouteActivePath("ipv4-unicast", "ipv4-prefix", "10.255.0.2/32"): {"true"},
		DeviceObjectStatePath("default"):                                {"present"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("MatchState:\n got %v\nwant %v", got, want)
	}
}

// TestCollectorReaderCouldNotRun: a collector that does not answer, and a node
// with no sample in it, are reads that could not be made — errors — never
// absent values; another node's samples are never read for this one.
func TestCollectorReaderCouldNotRun(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(collectorFixture))
	}))
	defer srv.Close()
	r := &CollectorReader{URL: srv.URL}
	got, err := r.State(context.Background(), Target{Namespace: "sdc-system", Name: "leaf02"}, []string{SessionStatePath("10.0.0.1"), SessionStatePath("10.0.0.3")})
	if err != nil {
		t.Fatal(err)
	}
	if want := map[string][]string{SessionStatePath("10.0.0.1"): {"established"}}; !reflect.DeepEqual(got, want) {
		t.Errorf("leaf02 read %v, want only its own sample %v", got, want)
	}
	if _, err := r.State(context.Background(), Target{Namespace: "sdc-system", Name: "spine01"}, []string{SessionStatePath("10.0.0.1")}); err == nil ||
		!strings.Contains(err.Error(), "no sample from spine01") {
		t.Errorf("a node with no sample must be a read that could not be made, got %v", err)
	}
	dead := &CollectorReader{URL: "http://127.0.0.1:1/metrics"}
	if _, err := dead.State(context.Background(), Target{Name: "leaf01"}, []string{SessionStatePath("10.0.0.1")}); err == nil ||
		!strings.Contains(err.Error(), "could not be read") {
		t.Errorf("an unreachable collector must be a read that could not be made, got %v", err)
	}
}

// TestCollectorReaderRunningIsTheLayers: the running datastore is read
// through the layer, never from the collector.
func TestCollectorReaderRunningIsTheLayers(t *testing.T) {
	layer := &fakeRunning{doc: []byte(`{"interface":[]}`)}
	r := &CollectorReader{Layer: layer, URL: "http://127.0.0.1:1/metrics"}
	got, err := r.Running(context.Background(), Target{Namespace: "agentic-netops-system", Name: "leaf01"})
	if err != nil || string(got) != `{"interface":[]}` || layer.calls != 1 {
		t.Fatalf("Running = %q, %v (layer calls %d); want the layer's document", got, err, layer.calls)
	}
}

type fakeRunning struct {
	doc   []byte
	calls int
}

func (f *fakeRunning) Running(context.Context, Target) ([]byte, error) { f.calls++; return f.doc, nil }
func (f *fakeRunning) State(context.Context, Target, []string) (map[string][]string, error) {
	return nil, errors.New("not used")
}

// TestCollectorStockCapture parses the live capture of a stock lab (no fabric
// rendered): interfaces are reported, no BGP neighbour is — so a Fabric
// read-back against it finds its sessions absent (invariant missing), not
// "could not run".
func TestCollectorStockCapture(t *testing.T) {
	raw, err := os.ReadFile("testdata/collector-stock.prom")
	if err != nil {
		t.Fatal(err)
	}
	all, err := ParseExposition(strings.NewReader(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	var leaf []Sample
	for _, s := range all {
		if s.Labels["source"] == "leaf01" {
			leaf = append(leaf, s)
		}
	}
	got, err := MatchState(leaf, []string{InterfaceOperStatePath("ethernet-1/1"), SessionStatePath("10.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}
	if v := got[InterfaceOperStatePath("ethernet-1/1")]; len(v) != 1 || (v[0] != "up" && v[0] != "down") {
		t.Errorf("ethernet-1/1 oper-state = %v", v)
	}
	if _, ok := got[SessionStatePath("10.0.0.1")]; ok {
		t.Error("a stock node reports no BGP neighbour")
	}
}

// TestCollectorConvergedCapture: against the live capture of the converged
// default Fabric (fabric01, 2026-09-21), the read-back's own paths resolve to
// the device's values: overlay sessions established with the EVPN family up,
// underlay sessions established, and the other nodes' loopbacks active as BGP
// routes — including spine↔spine (allow-own-as on the spines' underlay).
func TestCollectorConvergedCapture(t *testing.T) {
	raw, err := os.ReadFile("testdata/collector-fabric01.prom")
	if err != nil {
		t.Fatal(err)
	}
	all, err := ParseExposition(strings.NewReader(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	node := func(n string) []Sample {
		var out []Sample
		for _, s := range all {
			if s.Labels["source"] == n {
				out = append(out, s)
			}
		}
		return out
	}
	for n, want := range map[string]map[string]string{
		"leaf01": {
			SessionStatePath("10.0.0.11"):                                     "established",
			SessionStatePath("10.0.0.12"):                                     "established",
			EVPNFamilyOperStatePath("10.0.0.11"):                              "up",
			RouteActivePath("ipv4-unicast", "ipv4-prefix", "10.0.0.2/32"):     "true",
			RouteActivePath("ipv4-unicast", "ipv4-prefix", "10.0.0.12/32"):    "true",
			RouteActivePath("ipv6-unicast", "ipv6-prefix", "fd00::a00:2/128"): "true",
			SubinterfaceOperStatePath("system0", 0):                           "up",
			InterfaceOperStatePath("ethernet-1/49"):                           "up",
		},
		"spine01": {
			SessionStatePath("10.0.0.1"):                                   "established",
			EVPNFamilyOperStatePath("10.0.0.2"):                            "up",
			RouteActivePath("ipv4-unicast", "ipv4-prefix", "10.0.0.12/32"): "true",
		},
	} {
		var paths []string
		for p := range want {
			paths = append(paths, p)
		}
		got, err := MatchState(node(n), paths)
		if err != nil {
			t.Fatal(err)
		}
		for p, w := range want {
			if v := got[p]; len(v) != 1 || v[0] != w {
				t.Errorf("%s %s = %v, want [%s]", n, p, v, w)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// The service read-back (T058) against the collector.
// ---------------------------------------------------------------------------

// scratchServiceModel is the model of T058's live probe (vt-scratch- names,
// which BuildService does not derive): a mac-vrf, an ip-vrf and a vlan on
// ethernet-1/1 of leaf01 and leaf02.
func scratchServiceModel() *model.ServiceModel {
	m := &model.ServiceModel{ServiceID: "vt-scratch", Construct: model.ConstructMACVRF}
	for i, node := range []string{"leaf01", "leaf02"} {
		m.Nodes = append(m.Nodes, model.ServiceNode{Node: node,
			Subinterfaces: []model.Subinterface{
				{Port: "ethernet-1/1", Index: 990, Type: model.Bridged, VLAN: 990},
				{Port: "ethernet-1/1", Index: 991, Type: model.Routed, VLAN: 991,
					IPv4: []string{fmt.Sprintf("10.199.%d.1/24", i+1)}, IPv6: []string{fmt.Sprintf("2001:db8:199:%d::1/64", i+1)}},
				{Port: "ethernet-1/1", Index: 992, Type: model.Bridged, VLAN: 992},
			},
			VXLANInterfaces: []model.VXLANInterface{{Index: 19990, Type: model.Bridged, VNI: 19990}, {Index: 19991, Type: model.Routed, VNI: 19991}},
			NetworkInstances: []model.NetworkInstance{
				{Name: "vt-scratch-macvrf", Type: model.MACVRF, Interfaces: []string{"ethernet-1/1.990"}, VXLANInterface: "vxlan0.19990",
					EVPN:   &model.EVPNInstance{ID: 1, EVI: 19990, VXLANInterface: "vxlan0.19990", ECMP: 8},
					BGPVPN: &model.BGPVPNInstance{ID: 1, ExportRT: "target:65000:19990", ImportRT: "target:65000:19990"}},
				{Name: "vt-scratch-ipvrf", Type: model.IPVRF, Interfaces: []string{"ethernet-1/1.991"}, VXLANInterface: "vxlan0.19991",
					EVPN:   &model.EVPNInstance{ID: 1, EVI: 19991, VXLANInterface: "vxlan0.19991", ECMP: 8},
					BGPVPN: &model.BGPVPNInstance{ID: 1, ExportRT: "target:65000:19991", ImportRT: "target:65000:19991"}},
				{Name: "vt-scratch-vlan", Type: model.MACVRF, Interfaces: []string{"ethernet-1/1.992"}},
			}})
	}
	return m
}

func scratchServiceRun(t *testing.T, exposition string) (ServiceResult, error) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(exposition)) }))
	defer srv.Close()
	cfgs := &fakeConfigs{cfgs: map[string]*configv1alpha1.Config{
		"svc-leaf01": readyConfig("svc-leaf01", 1), "svc-leaf02": readyConfig("svc-leaf02", 1)}}
	s := &Service{Reader: &CollectorReader{Layer: &fakeRunning{doc: []byte(`{}`)}, URL: srv.URL}, Configs: cfgs}
	return s.VerifyService(context.Background(), ServiceInput{Model: scratchServiceModel(), TargetNamespace: "agentic-netops-system",
		Loopbacks: map[string]string{"leaf01": "10.0.0.1", "leaf02": "10.0.0.2"},
		Prefixes:  map[string][]string{"vt-scratch-ipvrf": {"10.199.1.0/24", "10.199.2.0/24"}},
		Nodes:     []ServiceNodeInput{{Node: "leaf01", ConfigName: "svc-leaf01"}, {Node: "leaf02", ConfigName: "svc-leaf02"}}})
}

// TestCollectorServicesCapture: against the live capture of the converged
// scratch services, every path of the service read-back — oper-states, the
// device's RD/RT origins, the multicast destination and VTEP indexes (uint64,
// converted by the collector), the local and bgp-evpn routes of both families
// — resolves to the device's value and the pass passes on both leaves.
func TestCollectorServicesCapture(t *testing.T) {
	raw, err := os.ReadFile("testdata/collector-services.prom")
	if err != nil {
		t.Fatal(err)
	}
	res, err := scratchServiceRun(t, string(raw))
	if err != nil {
		t.Fatal(err)
	}
	if !res.Passed() {
		t.Fatalf("the converged capture must pass: %s", res.Message())
	}
	samples, err := ParseExposition(strings.NewReader(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	var leaf01 []Sample
	for _, s := range samples {
		if s.Labels["source"] == "leaf01" {
			leaf01 = append(leaf01, s)
		}
	}
	got, err := MatchState(leaf01, []string{
		MulticastDestinationIndexPath(19990, "10.0.0.2", 19990),
		VTEPIndexPath("10.0.0.2"),
		RDOriginPath("vt-scratch-macvrf", 1),
		RTOriginPath("vt-scratch-ipvrf", 1, "export"),
		InstanceRouteActivePath("vt-scratch-ipvrf", "2001:db8:199:2::/64", RouteTypeBGPEVPN),
		InstanceRouteActivePath("vt-scratch-ipvrf", "10.199.2.0/24", RouteTypeLocal), // remote: not local here
	})
	if err != nil {
		t.Fatal(err)
	}
	want := map[string][]string{
		MulticastDestinationIndexPath(19990, "10.0.0.2", 19990):                              {"103476342706"},
		VTEPIndexPath("10.0.0.2"):                                                            {"103476342685"},
		RDOriginPath("vt-scratch-macvrf", 1):                                                 {"auto-derived-from-evi"},
		RTOriginPath("vt-scratch-ipvrf", 1, "export"):                                        {"manual"},
		InstanceRouteActivePath("vt-scratch-ipvrf", "2001:db8:199:2::/64", RouteTypeBGPEVPN): {"true"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("MatchState:\n got %v\nwant %v", got, want)
	}
}

// TestCollectorServicesDownCapture: with leaf01's vlan instance and
// subinterface disabled (live capture), the pass names each object with the
// device's own reason, decoded from the collector's integers.
func TestCollectorServicesDownCapture(t *testing.T) {
	up, err := os.ReadFile("testdata/collector-services.prom")
	if err != nil {
		t.Fatal(err)
	}
	down, err := os.ReadFile("testdata/collector-services-down.prom")
	if err != nil {
		t.Fatal(err)
	}
	var lines []string
	for _, l := range strings.Split(string(up), "\n") {
		if strings.Contains(l, `source="leaf01"`) && (strings.Contains(l, "vt-scratch-vlan") || strings.Contains(l, `subinterface_index="992"`)) {
			continue // replaced by the down capture
		}
		lines = append(lines, l)
	}
	res, err := scratchServiceRun(t, strings.Join(lines, "\n")+"\n"+string(down))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []struct {
		check Check
		frags []string
	}{
		{CheckNetworkInstanceOperState, []string{"network-instance vt-scratch-vlan", "reads down", "oper-down-reason admin-down"}},
		{CheckInstanceInterfaceOperState, []string{"interface ethernet-1/1.992", "reads down", "oper-down-reason net-inst-down"}},
		{CheckSubinterfaceOperState, []string{"subinterface ethernet-1/1.992", "reads down", "oper-down-reason admin-disabled"}},
	} {
		if !hasMissing(res, "leaf01", want.check, want.frags...) {
			t.Errorf("%s not named: %s", want.check, res.Message())
		}
	}
	if len(res.Missing) != 3 || res.Reason() != status.ReasonNotConverged {
		t.Errorf("want the three vlan invariants, NotConverged; got %s: %s", res.Reason(), res.Message())
	}
}

// TestDecodeTablesMatchCollectorConfig holds decodeValue to the event
// processors scripts/lib/device_metrics.sh renders: every string → integer
// replacement decodes back to its string, the catch-all to UnrecognisedValue.
func TestDecodeTablesMatchCollectorConfig(t *testing.T) {
	cfg := renderCollectorConfig(t)
	leaves := map[string][]string{
		"session-state-to-int":  {"session-state"},
		"oper-state-to-int":     {"oper-state"},
		"active-to-int":         {"active"},
		"acl-bool-to-int":       {"programming-complete", "incomplete"},
		"rib-bool-to-int":       {"used-route"},
		"address-status-to-int": {"status"},
		"anycast-origin-to-int": {"anycast-gw-mac-origin"},
		"reason-to-int":         {"oper-down-reason", "not-programmed-reason"},
		"origin-to-int":         {"route-distinguisher-origin", "export-route-target-origin", "import-route-target-origin"},
	}
	proc := regexp.MustCompile(`^      ([a-z-]+):$`)
	repl := regexp.MustCompile(`replace: \{apply-on: value, old: "\^(.*)\$", new: "(\d+)"\}`)
	seen := map[string]int{}
	cur := ""
	for _, l := range strings.Split(cfg, "\n") {
		if m := proc.FindStringSubmatch(l); m != nil {
			cur = m[1]
			continue
		}
		m := repl.FindStringSubmatch(l)
		if m == nil {
			continue
		}
		ls, ok := leaves[cur]
		if !ok {
			t.Fatalf("processor %s maps values but the reader has no table for it", cur)
		}
		want := m[1]
		if want == "[^0-9].*" {
			want = UnrecognisedValue
		}
		for _, leaf := range ls {
			if got := decodeValue(leaf, m[2]); got != want {
				t.Errorf("%s: %s encoded %s decodes to %q, want %q", cur, leaf, m[2], got, want)
			}
		}
		seen[cur]++
	}
	for p := range leaves {
		if seen[p] == 0 {
			t.Errorf("processor %s not rendered", p)
		}
	}
	if seen["reason-to-int"] != len(reasons) || seen["origin-to-int"] != len(origins) {
		t.Errorf("table sizes differ: reasons %d rendered / %d decoded, origins %d / %d",
			seen["reason-to-int"], len(reasons), seen["origin-to-int"], len(origins))
	}
	if seen["address-status-to-int"] != len(addressStatuses) || seen["anycast-origin-to-int"] != len(anycastOrigins) {
		t.Errorf("table sizes differ: address statuses %d rendered / %d decoded, anycast origins %d / %d",
			seen["address-status-to-int"], len(addressStatuses), seen["anycast-origin-to-int"], len(anycastOrigins))
	}
	// the uint64 indexes are converted to integers or never exported
	for _, v := range []string{`".*destination-index$"`, `".*vtep/index$"`, `".*oper-down-reason$"`, `".*not-programmed-reason$"`,
		`".*route-distinguisher-origin$"`, `".*route-target-origin$"`, `".*/programming-complete$"`, `".*/statistics/incomplete$"`,
		`".*/statistics/matched-packets$"`, `".*/used-route$"`, `".*address/status$"`, `".*anycast-gw-mac-origin$"`} {
		if !strings.Contains(cfg[strings.Index(cfg, "state-as-int:"):], v) {
			t.Errorf("state-as-int does not convert %s", v)
		}
	}
}

// TestServicePathsAreSubscribed: every state path the service read-back
// requests, for every construct, is an instance of a path the collector
// subscribes to (same elements, keys aside) — a path not subscribed would read
// as absent forever.
func TestServicePathsAreSubscribed(t *testing.T) {
	cfg := renderCollectorConfig(t)
	sub := regexp.MustCompile(`^          - "(/.*)"$`)
	subscribed := map[string]bool{}
	for _, l := range strings.Split(cfg, "\n") {
		if m := sub.FindStringSubmatch(l); m != nil {
			subscribed[elementNames(t, m[1])] = true
		}
	}
	if len(subscribed) == 0 {
		t.Fatal("no subscription rendered")
	}
	gw, err := model.BuildService(model.ServiceInput{ServiceID: "g1", Construct: model.ConstructMACVRF, FabricASN: 65000,
		L2:      &model.L2Segment{VLAN: 990, L2VNI: 19990, Attachments: []model.Attachment{{Node: "leaf01", Port: "ethernet-1/1"}, {Node: "leaf02", Port: "ethernet-1/1"}}},
		Gateway: &model.Gateway{L3VNI: 19991, IPv4: []string{"10.10.0.1/24"}, IPv6: []string{"2001:db8:10::1/64"}, IPMTU: 1500}})
	if err != nil {
		t.Fatal(err)
	}
	exps, err := ServiceExpectations(ServiceInput{Model: scratchServiceModel(), Loopbacks: map[string]string{"leaf01": "10.0.0.1", "leaf02": "10.0.0.2"},
		Prefixes: map[string][]string{"vt-scratch-ipvrf": {"10.77.0.0/16"}}})
	if err != nil {
		t.Fatal(err)
	}
	gexps, err := ServiceExpectations(ServiceInput{Model: gw, Loopbacks: map[string]string{"leaf01": "10.0.0.1", "leaf02": "10.0.0.2"}})
	if err != nil {
		t.Fatal(err)
	}
	// an access list in each direction (T108)
	deny := model.ActionDrop
	am, err := model.BuildService(model.ServiceInput{ServiceID: "a1", Construct: model.ConstructACL,
		AccessLists: []model.AccessList{
			{Stage: model.StageIngress, Family: model.FamilyIPv4, DefaultAction: &deny,
				Rules:    []model.ACLRule{{Name: "r", Priority: 10, Action: model.ActionAccept, Protocol: "icmp"}},
				Bindings: []model.ACLBinding{{Node: "leaf01", Port: "ethernet-1/1", VLAN: 990}}},
			{Stage: model.StageEgress, Family: model.FamilyIPv6,
				Rules:    []model.ACLRule{{Name: "r", Priority: 10, Action: model.ActionAccept, Protocol: "icmpv6"}},
				Bindings: []model.ACLBinding{{Node: "leaf01", Port: "ethernet-1/1", VLAN: 990}}}}})
	if err != nil {
		t.Fatal(err)
	}
	aexps, err := ServiceExpectations(ServiceInput{Model: am})
	if err != nil {
		t.Fatal(err)
	}
	if len(aexps["leaf01"]) < 10 {
		t.Fatalf("access-list expectations %v", aexps["leaf01"])
	}
	n := 0
	for _, es := range [][]StateExpectation{exps["leaf01"], gexps["leaf02"], aexps["leaf01"]} {
		for _, e := range es {
			for _, p := range []string{e.Path, e.ReasonPath} {
				if p == "" {
					continue
				}
				n++
				if !subscribed[elementNames(t, p)] {
					t.Errorf("%s is not subscribed by scripts/lib/device_metrics.sh", p)
				}
			}
		}
	}
	if n < 40 {
		t.Errorf("only %d paths checked", n)
	}
}

func elementNames(t *testing.T, p string) string {
	t.Helper()
	elems, err := parsePath(p)
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(elems))
	for _, e := range elems {
		names = append(names, e.name)
	}
	return strings.Join(names, "/")
}

func renderCollectorConfig(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not available")
	}
	out, err := exec.Command("bash", "../../scripts/lib/device_metrics.sh", "render", "172.25.25.0/24").Output()
	if err != nil {
		t.Fatalf("device_metrics.sh render: %v", err)
	}
	return string(out)
}

// TestCollectorUnreachableByFreshness: the data-path half of "can this node be read" (SC-008,
// live-findings 2026-09-21-target-unreachable). A node whose newest timestamped sample is older
// than the limit, or that has no sample, cannot be read; a fresh one can; the timestamp the
// exporter appends (send_timestamps) is parsed; an unreadable collector is an error.
func TestCollectorUnreachableByFreshness(t *testing.T) {
	now := time.UnixMilli(1790007907540)
	fixture := strings.Join([]string{
		`srl_nokia_interfaces:interface_oper_state{interface_name="ethernet-1/1",source="leaf01"} 1 1790007905564`, // 2 s old
		`srl_nokia_interfaces:interface_oper_state{interface_name="ethernet-1/1",source="leaf02"} 1 1790007880000`, // 27.5 s old
		`srl_nokia_interfaces:interface_oper_state{interface_name="ethernet-1/2",source="leaf02"} 1 1790007890000`, // newest of leaf02: 17.5 s
		`srl_nokia_interfaces:interface_oper_state{interface_name="ethernet-1/1",source="spine02"} 1`,              // no timestamp
	}, "\n") + "\n"
	samples, err := ParseExposition(strings.NewReader(fixture))
	if err != nil {
		t.Fatal(err)
	}
	if samples[0].TimestampMs != 1790007905564 || samples[3].TimestampMs != 0 {
		t.Fatalf("timestamps parsed %d / %d", samples[0].TimestampMs, samples[3].TimestampMs)
	}
	got := StaleNodes(samples, []string{"leaf01", "leaf02", "spine01", "spine02"}, 12*time.Second, now)
	if _, ok := got["leaf01"]; ok {
		t.Errorf("leaf01's newest sample is 2 s old: reachable, got %q", got["leaf01"])
	}
	if !strings.Contains(got["leaf02"], "leaf02") || !strings.Contains(got["leaf02"], "18s old") {
		t.Errorf("leaf02's newest sample is 17.5 s old: unreachable, named with its age, got %q", got["leaf02"])
	}
	if !strings.Contains(got["spine01"], "no sample from spine01") {
		t.Errorf("spine01 has no sample: unreachable, got %q", got["spine01"])
	}
	if _, ok := got["spine02"]; ok {
		t.Errorf("an untimestamped sample counts as fresh (the exporter's expiration bounds it), got %q", got["spine02"])
	}
	// negative control: the same samples judged at the time leaf02's newest was taken are fresh
	if g := StaleNodes(samples, []string{"leaf02"}, 12*time.Second, time.UnixMilli(1790007890000)); len(g) != 0 {
		t.Errorf("leaf02 at its own sample time must be fresh, got %v", g)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(fixture)) }))
	defer srv.Close()
	r := &CollectorReader{URL: srv.URL}
	if g, err := r.Unreachable(context.Background(), []string{"leaf01", "leaf02"}, 12*time.Second, now); err != nil || len(g) != 1 || g["leaf02"] == "" {
		t.Errorf("Unreachable over HTTP: %v %v", g, err)
	}
	dead := &CollectorReader{URL: "http://127.0.0.1:1/metrics"}
	if _, err := dead.Unreachable(context.Background(), []string{"leaf01"}, 12*time.Second, now); err == nil || !strings.Contains(err.Error(), "could not be read") {
		t.Errorf("an unreadable collector is an error, got %v", err)
	}
}

// gatewayExposition is the anycast-gateway series in the collector's naming (T116): leaf01's
// view of lab-macvrf-gateway (VLAN 130, L3VNI 10131) as observed live 2026-09-24 on SR Linux
// 25.7.1 — irb0.130 up, its anycast-gw MAC origin vrid-auto-derived, both anycast addresses
// preferred (a link-local address beside them), and leaf02's Type-5 routes in the EVPN RIB,
// one path per spine, the one via 10.0.0.11 used.
const gatewayExposition = `srl_nokia_interfaces:interface_subinterface_oper_state{interface_name="irb0",subinterface_index="130",source="leaf01",subscription_name="device-state"} 1
srl_nokia_interfaces:interface_subinterface_anycast_gw_anycast_gw_mac_origin{interface_name="irb0",subinterface_index="130",source="leaf01",subscription_name="device-state"} 2
srl_nokia_interfaces:interface_subinterface_ipv4_address_status{address_ip_prefix="10.30.0.1/24",interface_name="irb0",subinterface_index="130",source="leaf01",subscription_name="device-state"} 1
srl_nokia_interfaces:interface_subinterface_ipv6_address_status{address_ip_prefix="2001:db8:30::1/64",interface_name="irb0",subinterface_index="130",source="leaf01",subscription_name="device-state"} 1
srl_nokia_interfaces:interface_subinterface_ipv6_address_status{address_ip_prefix="fe80::1:1ff:feff:41/64",interface_name="irb0",subinterface_index="130",source="leaf01",subscription_name="device-state"} 1
srl_nokia_network_instance:network_instance_srl_nokia_rib_bgp:bgp_rib_afi_safi_srl_nokia_rib_bgp_evpn:evpn_rib_in_out_rib_in_post_ip_prefix_route_used_route{afi_safi_afi_safi_name="srl_nokia-common:evpn",ip_prefix_route_ethernet_tag_id="0",ip_prefix_route_ip_prefix="10.30.0.0/24",ip_prefix_route_ip_prefix_length="24",ip_prefix_route_neighbor="10.0.0.11",ip_prefix_route_path_id="0",ip_prefix_route_route_distinguisher="10.0.0.2:10131",network_instance_name="default",source="leaf01",subscription_name="device-state"} 1
srl_nokia_network_instance:network_instance_srl_nokia_rib_bgp:bgp_rib_afi_safi_srl_nokia_rib_bgp_evpn:evpn_rib_in_out_rib_in_post_ip_prefix_route_used_route{afi_safi_afi_safi_name="srl_nokia-common:evpn",ip_prefix_route_ethernet_tag_id="0",ip_prefix_route_ip_prefix="10.30.0.0/24",ip_prefix_route_ip_prefix_length="24",ip_prefix_route_neighbor="10.0.0.12",ip_prefix_route_path_id="0",ip_prefix_route_route_distinguisher="10.0.0.2:10131",network_instance_name="default",source="leaf01",subscription_name="device-state"} 0
srl_nokia_network_instance:network_instance_srl_nokia_rib_bgp:bgp_rib_afi_safi_srl_nokia_rib_bgp_evpn:evpn_rib_in_out_rib_in_post_ip_prefix_route_used_route{afi_safi_afi_safi_name="srl_nokia-common:evpn",ip_prefix_route_ethernet_tag_id="0",ip_prefix_route_ip_prefix="2001:db8:30::/64",ip_prefix_route_ip_prefix_length="64",ip_prefix_route_neighbor="10.0.0.11",ip_prefix_route_path_id="0",ip_prefix_route_route_distinguisher="10.0.0.2:10131",network_instance_name="default",source="leaf01",subscription_name="device-state"} 1
`

// TestCollectorGatewaySeries: every gateway read-back path resolves to its keyed instance
// through the collector's labels — an ip-prefix key carrying a '/', an IPv6 prefix, the
// identityref afi-safi key — decoded back to the device's strings; the used-route of every
// path of a route is read (one true is enough), and a route distinguisher or prefix the RIB
// does not hold is absent.
func TestCollectorGatewaySeries(t *testing.T) {
	samples, err := ParseExposition(strings.NewReader(gatewayExposition))
	if err != nil {
		t.Fatal(err)
	}
	got, err := MatchState(samples, []string{
		SubinterfaceOperStatePath("irb0", 130),
		AnycastGWMACOriginPath("irb0", 130),
		AddressStatusPath("irb0", 130, "10.30.0.1/24"),
		AddressStatusPath("irb0", 130, "2001:db8:30::1/64"),
		Type5UsedRoutePath("10.0.0.2:10131", "10.30.0.0/24"),
		Type5UsedRoutePath("10.0.0.2:10131", "2001:db8:30::/64"),
		Type5UsedRoutePath("10.0.0.1:10131", "10.30.0.0/24"), // leaf01's own RD: absent
		Type5UsedRoutePath("10.0.0.2:10131", "10.31.0.0/24"), // another prefix: absent
		AddressStatusPath("irb0", 130, "2001:db8:31::1/64"),  // not configured: absent
	})
	if err != nil {
		t.Fatal(err)
	}
	want := map[string][]string{
		SubinterfaceOperStatePath("irb0", 130):                   {"up"},
		AnycastGWMACOriginPath("irb0", 130):                      {AnycastOriginVRIDAutoDerived},
		AddressStatusPath("irb0", 130, "10.30.0.1/24"):           {AddressStatusPreferred},
		AddressStatusPath("irb0", 130, "2001:db8:30::1/64"):      {AddressStatusPreferred},
		Type5UsedRoutePath("10.0.0.2:10131", "10.30.0.0/24"):     {"true", "false"},
		Type5UsedRoutePath("10.0.0.2:10131", "2001:db8:30::/64"): {"true"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("MatchState:\n got %v\nwant %v", got, want)
	}
}
