package verify

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
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
