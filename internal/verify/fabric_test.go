package verify

import (
	"context"
	"encoding/json"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	condv1alpha1 "github.com/sdcio/config-server/apis/condition/v1alpha1"
	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	"github.com/mairp/agentic-netops-srl/internal/model"
)

// ---------------------------------------------------------------------------
// Fakes: a StateReader standing in for the device-configuration layer, and a
// ConfigReader standing in for its Config/Deviation objects.
// ---------------------------------------------------------------------------

type fakeReader struct {
	mu          sync.Mutex
	running     map[string]string   // node -> running JSON (default: the node's rendered doc)
	override    map[string][]string // path -> values (nil slice = absent), all nodes
	nodeOver    map[string]map[string][]string
	unreachable map[string]error
	block       bool
	paths       []string
	nodePaths   map[string][]string
	rendered    map[string]string
}

func newFakeReader() *fakeReader {
	return &fakeReader{running: map[string]string{}, override: map[string][]string{},
		nodeOver: map[string]map[string][]string{}, unreachable: map[string]error{}, rendered: map[string]string{},
		nodePaths: map[string][]string{}}
}

func (f *fakeReader) Running(ctx context.Context, t Target) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.unreachable[t.Name]; err != nil {
		return nil, err
	}
	if r, ok := f.running[t.Name]; ok {
		return []byte(r), nil
	}
	if r, ok := f.rendered[t.Name]; ok {
		return []byte(r), nil
	}
	return []byte(`{}`), nil
}

func (f *fakeReader) State(ctx context.Context, t Target, paths []string) (map[string][]string, error) {
	f.mu.Lock()
	block := f.block
	err := f.unreachable[t.Name]
	f.mu.Unlock()
	if block {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	if err != nil {
		return nil, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.paths = append(f.paths, paths...)
	f.nodePaths[t.Name] = append(f.nodePaths[t.Name], paths...)
	out := map[string][]string{}
	for _, p := range paths {
		if v, ok := f.nodeOver[t.Name][p]; ok {
			if v != nil {
				out[p] = v
			}
			continue
		}
		if v, ok := f.override[p]; ok {
			if v != nil {
				out[p] = v
			}
			continue
		}
		switch {
		case strings.HasSuffix(p, "/oper-state"):
			out[p] = []string{"up"}
		case strings.HasSuffix(p, "/session-state"):
			out[p] = []string{"established"}
		case strings.HasSuffix(p, "/active"), strings.HasSuffix(p, "/inter-as-vpn"), strings.HasSuffix(p, "/client"):
			out[p] = []string{"true"}
		}
		// device-object presence paths (/index, /name) are absent by default
	}
	return out, nil
}

func (f *fakeReader) setNode(node, path string, vals []string) {
	if f.nodeOver[node] == nil {
		f.nodeOver[node] = map[string][]string{}
	}
	f.nodeOver[node][path] = vals
}

type fakeConfigs struct {
	cfgs map[string]*configv1alpha1.Config
	devs map[string]*configv1alpha1.Deviation
	err  error
}

func (f *fakeConfigs) GetConfig(_ context.Context, name string) (*configv1alpha1.Config, error) {
	if f.err != nil {
		return nil, f.err
	}
	c, ok := f.cfgs[name]
	if !ok {
		return nil, apierrors.NewNotFound(schema.GroupResource{Group: "config.sdcio.dev", Resource: "configs"}, name)
	}
	return c, nil
}

func (f *fakeConfigs) GetConfigDeviation(_ context.Context, name string) (*configv1alpha1.Deviation, error) {
	return f.devs[name], nil
}

func readyConfig(name string, gen int64) *configv1alpha1.Config {
	c := &configv1alpha1.Config{ObjectMeta: metav1.ObjectMeta{Name: name, Generation: gen}}
	c.SetConditions(condv1alpha1.Condition{Condition: metav1.Condition{
		Type: string(condv1alpha1.ConditionTypeReady), Status: metav1.ConditionTrue,
		Reason: "Ready", ObservedGeneration: gen}})
	return c
}

// ---------------------------------------------------------------------------
// Fixture: the default fabric (data-model.md §3a), both families.
// ---------------------------------------------------------------------------

func fixture(t *testing.T, interASVPN bool) (*Fabric, *fakeReader, *fakeConfigs, FabricInput) {
	t.Helper()
	return fixtureRC(t, interASVPN, true)
}

// spineRunning is a reflecting spine's running configuration as the layer
// holds it: the configuration-integrity leaves under the default instance's
// BGP. An empty value leaves that leaf out.
func spineRunning(interASVPN, client string) string {
	evpn, rr := "{}", "{}"
	if interASVPN != "" {
		evpn = `{"inter-as-vpn":` + interASVPN + `}`
	}
	if client != "" {
		rr = `{"client":` + client + `}`
	}
	return `{"srl_nokia-interfaces:interface":[{"name":"system0","admin-state":"enable"}],` +
		`"srl_nokia-network-instance:network-instance":[{"name":"default","type":"srl_nokia-network-instance:default",` +
		`"protocols":{"srl_nokia-bgp:bgp":{"afi-safi":[{"afi-safi-name":"srl_nokia-common:ipv4-unicast"},` +
		`{"afi-safi-name":"srl_nokia-common:evpn","evpn":` + evpn + `}],` +
		`"group":[{"group-name":"underlay"},{"group-name":"overlay","route-reflector":` + rr + `}]}}}]}`
}

func fixtureRC(t *testing.T, interASVPN, reflectorClients bool) (*Fabric, *fakeReader, *fakeConfigs, FabricInput) {
	t.Helper()
	in := model.FabricInput{
		Name: "fabric01", FabricASN: 65000, InterASVPN: interASVPN, ReflectorClients: reflectorClients,
		AddressFamilies: []model.AddressFamily{model.FamilyUnderlayIPv4, model.FamilyUnderlayIPv6},
		MTU:             model.FabricMTU{PortMTU: 9412, UnderlayIPMTU: 9398, BridgedL2MTU: 9412, TenantIPMTU: 9348},
		Nodes: []model.FabricNodeInput{
			{Name: "spine01", Role: model.RoleSpine, SystemIPv4: "10.0.0.11/32", ASN: 65100, RouteReflector: true},
			{Name: "spine02", Role: model.RoleSpine, SystemIPv4: "10.0.0.12/32", ASN: 65100, RouteReflector: true},
			{Name: "leaf01", Role: model.RoleLeaf, SystemIPv4: "10.0.0.1/32", ASN: 65101},
			{Name: "leaf02", Role: model.RoleLeaf, SystemIPv4: "10.0.0.2/32", ASN: 65102},
		},
		Links: []model.FabricLink{
			{A: model.LinkEnd{Node: "leaf01", Port: "ethernet-1/49", IPv4: "10.1.0.1/31"}, B: model.LinkEnd{Node: "spine01", Port: "ethernet-1/1", IPv4: "10.1.0.0/31"}},
			{A: model.LinkEnd{Node: "leaf01", Port: "ethernet-1/50", IPv4: "10.1.0.3/31"}, B: model.LinkEnd{Node: "spine02", Port: "ethernet-1/1", IPv4: "10.1.0.2/31"}},
			{A: model.LinkEnd{Node: "leaf02", Port: "ethernet-1/49", IPv4: "10.1.0.5/31"}, B: model.LinkEnd{Node: "spine01", Port: "ethernet-1/2", IPv4: "10.1.0.4/31"}},
			{A: model.LinkEnd{Node: "leaf02", Port: "ethernet-1/50", IPv4: "10.1.0.7/31"}, B: model.LinkEnd{Node: "spine02", Port: "ethernet-1/2", IPv4: "10.1.0.6/31"}},
		},
		Inventory: []model.InventoryEntry{
			{Node: "leaf01", AccessPorts: []string{"ethernet-1/1"}, FabricPorts: []string{"ethernet-1/49", "ethernet-1/50"}},
			{Node: "leaf02", AccessPorts: []string{"ethernet-1/1"}, FabricPorts: []string{"ethernet-1/49", "ethernet-1/50"}},
		},
	}
	m, err := model.BuildFabric(in)
	if err != nil {
		t.Fatal(err)
	}
	r := newFakeReader()
	cs := &fakeConfigs{cfgs: map[string]*configv1alpha1.Config{}, devs: map[string]*configv1alpha1.Deviation{}}
	fi := FabricInput{Model: m, InterASVPN: interASVPN, ReflectorClients: reflectorClients, TargetNamespace: "agentic-netops-system"}
	for _, n := range m.Nodes {
		doc := `{"srl_nokia-interfaces:interface":[{"name":"system0","admin-state":"enable"}],` +
			`"srl_nokia-network-instance:network-instance":[{"name":"default","type":"srl_nokia-network-instance:default"}]}`
		name := "fabric01." + n.Name
		r.rendered[n.Name] = doc
		if n.BGP.RouteReflectorClient != nil {
			// the device holds the configuration-integrity leaves as declared
			r.running[n.Name] = spineRunning(strconv.FormatBool(interASVPN), strconv.FormatBool(reflectorClients))
		}
		cs.cfgs[name] = readyConfig(name, 1)
		fi.Nodes = append(fi.Nodes, FabricNodeInput{Node: n.Name, ConfigName: name, Rendered: []byte(doc)})
	}
	return &Fabric{Reader: r, Configs: cs, Timeout: 2 * time.Second}, r, cs, fi
}

func mustRun(t *testing.T, f *Fabric, in FabricInput) FabricResult {
	t.Helper()
	res, err := f.VerifyFabric(context.Background(), in)
	if err != nil {
		t.Fatalf("pass could not run: %v", err)
	}
	return res
}

func wantMissing(t *testing.T, res FabricResult, node string, check Check, substr ...string) {
	t.Helper()
	if res.Passed() {
		t.Fatalf("pass passed; want %s %s missing", node, check)
	}
	if res.Reason() != "NotConverged" {
		t.Errorf("reason %q, want NotConverged", res.Reason())
	}
	for _, m := range res.Missing {
		if m.Node != node || m.Check != check {
			continue
		}
		ok := true
		for _, s := range substr {
			if !strings.Contains(m.Detail, s) {
				ok = false
			}
		}
		if ok {
			if !strings.Contains(res.Message(), node) {
				t.Errorf("message does not name the node %s: %s", node, res.Message())
			}
			return
		}
	}
	t.Fatalf("no %s %s invariant containing %q in %v", node, check, substr, res.Missing)
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

func TestFabricPassesWhenEveryInvariantHolds(t *testing.T) {
	f, r, _, in := fixture(t, true)
	res := mustRun(t, f, in)
	if !res.Passed() {
		t.Fatalf("missing: %v", res.Missing)
	}
	for _, want := range []string{
		"/interface[name=ethernet-1/49]/oper-state",
		"/interface[name=ethernet-1/49]/subinterface[index=0]/oper-state",
		"/interface[name=system0]/subinterface[index=0]/oper-state",
		"/network-instance[name=default]/protocols/bgp/neighbor[peer-address=10.0.0.11]/afi-safi[afi-safi-name=srl_nokia-common:evpn]/oper-state",
		"/network-instance[name=default]/route-table/ipv4-unicast/route[ipv4-prefix=10.0.0.2/32][route-type=bgp]/active",
	} {
		if !containsStr(res.Paths, want) {
			t.Errorf("path not read: %s", want)
		}
	}
	// the configuration-integrity leaves are read from the configuration
	// datastore, never from state (AD-76)
	for _, want := range []string{
		"/network-instance[name=default]/protocols/bgp/afi-safi[afi-safi-name=srl_nokia-common:evpn]/evpn/inter-as-vpn",
		"/network-instance[name=default]/protocols/bgp/group[group-name=overlay]/route-reflector/client",
	} {
		if !containsStr(res.ConfigPaths, want) {
			t.Errorf("configuration-integrity path not read from the configuration datastore: %s", want)
		}
		if containsStr(res.Paths, want) || containsStr(r.paths, want) {
			t.Errorf("configuration-integrity path read from the state datastore: %s", want)
		}
	}
	// the IPv6 loopback of every other node, where the family is enabled
	v6 := 0
	for _, p := range res.Paths {
		if strings.Contains(p, "/route-table/ipv6-unicast/route[ipv6-prefix=") {
			v6++
		}
	}
	if v6 == 0 {
		t.Error("no ipv6-unicast loopback route read although the family is enabled")
	}
	// an access port's oper-state is not a Fabric invariant (AD-68)
	for _, leaf := range []string{"leaf01", "leaf02"} {
		for _, p := range r.nodePaths[leaf] {
			if strings.HasPrefix(p, "/interface[name=ethernet-1/1]") {
				t.Errorf("%s: access port state read: %s", leaf, p)
			}
		}
	}
}

func TestEachAppliedSideInvariantFails(t *testing.T) {
	for _, tc := range []struct {
		name  string
		node  string
		path  string
		vals  []string
		check Check
		sub   []string
	}{
		{"interface down", "leaf01", InterfaceOperStatePath("ethernet-1/49"), []string{"down"}, CheckInterfaceOperState, []string{"ethernet-1/49", "down"}},
		{"subinterface down", "spine01", SubinterfaceOperStatePath("ethernet-1/2", 0), []string{"down"}, CheckInterfaceOperState, []string{"ethernet-1/2.0"}},
		{"system0.0 absent", "leaf02", SubinterfaceOperStatePath("system0", 0), nil, CheckInterfaceOperState, []string{"system0.0", "nothing"}},
		{"underlay session", "leaf01", SessionStatePath("10.1.0.0"), []string{"active"}, CheckSessionState, []string{"10.1.0.0", "active"}},
		{"overlay session", "leaf02", SessionStatePath("10.0.0.12"), []string{"idle"}, CheckSessionState, []string{"overlay", "10.0.0.12"}},
		{"evpn family not negotiated", "spine02", EVPNFamilyOperStatePath("10.0.0.1"), []string{"down"}, CheckEVPNFamily, []string{"EVPN family on 10.0.0.1"}},
		{"loopback route inactive", "leaf01", RouteActivePath("ipv4-unicast", "ipv4-prefix", "10.0.0.2/32"), []string{"false"}, CheckLoopbackRoute, []string{"leaf02", "10.0.0.2/32"}},
		{"loopback route absent", "spine01", RouteActivePath("ipv4-unicast", "ipv4-prefix", "10.0.0.12/32"), nil, CheckLoopbackRoute, []string{"spine02"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f, r, _, in := fixture(t, true)
			r.setNode(tc.node, tc.path, tc.vals)
			res := mustRun(t, f, in)
			wantMissing(t, res, tc.node, tc.check, tc.sub...)
			if len(res.Missing) != 1 {
				t.Errorf("want exactly one missing invariant, got %v", res.Missing)
			}
		})
	}
}

func TestIPv6LoopbackRouteFailsWhereTheFamilyIsEnabled(t *testing.T) {
	f, r, _, in := fixture(t, true)
	var other string
	for _, n := range in.Model.Nodes {
		if n.Name == "leaf02" {
			other = n.SystemIPv6
		}
	}
	if other == "" {
		t.Skip("the model derives no IPv6 system address")
	}
	p := RouteActivePath("ipv6-unicast", "ipv6-prefix", hostPrefix(other, 128))
	r.setNode("leaf01", p, nil)
	wantMissing(t, mustRun(t, f, in), "leaf01", CheckLoopbackRoute, "leaf02")
}

func TestWrittenSideFails(t *testing.T) {
	t.Run("config not applied", func(t *testing.T) {
		f, _, cs, in := fixture(t, true)
		c := cs.cfgs["fabric01.leaf01"]
		c.SetConditions(condv1alpha1.Failed("transaction failed"))
		wantMissing(t, mustRun(t, f, in), "leaf01", CheckWritten, "not applied", "Failed")
	})
	t.Run("config applied at an older generation", func(t *testing.T) {
		f, _, cs, in := fixture(t, true)
		cs.cfgs["fabric01.spine01"].Generation = 2
		wantMissing(t, mustRun(t, f, in), "spine01", CheckWritten, "generation 1")
	})
	t.Run("config absent", func(t *testing.T) {
		f, _, cs, in := fixture(t, true)
		delete(cs.cfgs, "fabric01.leaf02")
		wantMissing(t, mustRun(t, f, in), "leaf02", CheckWritten, "absent")
	})
	t.Run("deviation reported", func(t *testing.T) {
		f, _, cs, in := fixture(t, true)
		cs.devs["fabric01.leaf01"] = &configv1alpha1.Deviation{Spec: configv1alpha1.DeviationSpec{
			Deviations: []configv1alpha1.ConfigDeviation{{Path: "/interface[name=system0]/admin-state", Reason: "NOT_APPLIED"}}}}
		wantMissing(t, mustRun(t, f, in), "leaf01", CheckWritten, "deviation", "NOT_APPLIED")
	})
	t.Run("rendered content absent from running", func(t *testing.T) {
		f, r, _, in := fixture(t, true)
		r.running["spine02"] = `{"interface":[{"name":"system0","admin-state":"disable"}],"network-instance":[{"name":"default","type":"default"}]}`
		wantMissing(t, mustRun(t, f, in), "spine02", CheckWritten, "running datastore", "/interface[name=system0]")
	})
	t.Run("running may omit module qualification and stringify numbers", func(t *testing.T) {
		if got := missingLeaves(
			map[string]any{"srl_nokia-interfaces:interface": []any{map[string]any{"name": "e1", "mtu": float64(9412), "t": "srl_nokia-interfaces:routed"}}},
			map[string]any{"interface": []any{map[string]any{"name": "e0"}, map[string]any{"name": "e1", "mtu": "9412", "t": "routed", "x": 1}}},
			""); len(got) != 0 {
			t.Errorf("subset not recognised: %v", got)
		}
	})
}

// The configuration-integrity leaves are read from the configuration datastore
// (AD-76): a spine whose running configuration lost one is NotConverged naming
// the spine and the setting, whatever the state datastore reports, and the
// message says it is a configuration-integrity check read from there.
func TestConfigurationIntegrityIsReadFromTheConfigurationDatastore(t *testing.T) {
	for _, tc := range []struct {
		name, node, running string
		sub                 []string
	}{
		{"inter-as-vpn lost", "spine01", spineRunning("false", "true"), []string{"spine01", "inter-as-vpn", "reads false in the configuration datastore, want true"}},
		{"inter-as-vpn absent", "spine02", spineRunning("", "true"), []string{"spine02", "inter-as-vpn", "reads nothing"}},
		{"rr client lost", "spine02", spineRunning("true", "false"), []string{"spine02", "route-reflector client", "reads false in the configuration datastore, want true"}},
		{"rr client absent", "spine01", spineRunning("true", ""), []string{"spine01", "route-reflector client", "reads nothing"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f, r, _, in := fixture(t, true)
			r.running[tc.node] = tc.running
			res := mustRun(t, f, in)
			wantMissing(t, res, tc.node, CheckConfigurationIntegrity,
				append([]string{"configuration-integrity check (read from the configuration datastore)"}, tc.sub...)...)
			if len(res.Missing) != 1 {
				t.Errorf("want exactly one missing invariant, got %v", res.Missing)
			}
		})
	}
	t.Run("state not mirroring the leaves is not a failure", func(t *testing.T) {
		f, r, _, in := fixture(t, true)
		r.override[InterASVPNPath()] = nil
		r.override[RouteReflectorClientPath(model.OverlayGroup)] = nil
		if res := mustRun(t, f, in); !res.Passed() {
			t.Fatalf("SR Linux 25.7.1 state does not mirror these leaves; missing: %v", res.Missing)
		}
	})
	t.Run("state reading true does not mask a lost setting", func(t *testing.T) {
		f, r, _, in := fixture(t, true)
		r.override[RouteReflectorClientPath(model.OverlayGroup)] = []string{"true"}
		r.running["spine01"] = spineRunning("true", "false")
		wantMissing(t, mustRun(t, f, in), "spine01", CheckConfigurationIntegrity, "route-reflector client", "configuration datastore")
	})
}

func TestConfigValues(t *testing.T) {
	var doc any
	if err := json.Unmarshal([]byte(spineRunning("true", "false")), &doc); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		path string
		want []string
	}{
		{InterASVPNPath(), []string{"true"}},
		{RouteReflectorClientPath(model.OverlayGroup), []string{"false"}},
		// the identityref key matches by local name
		{"/network-instance[name=default]/protocols/bgp/afi-safi[afi-safi-name=evpn]/evpn/inter-as-vpn", []string{"true"}},
		{RouteReflectorClientPath("underlay"), nil},
		{"/network-instance[name=other]/protocols/bgp/group[group-name=overlay]/route-reflector/client", nil},
		{"/interface[name=system0]/admin-state", []string{"enable"}},
		{"/interface/name", []string{"system0"}},
	} {
		if got := ConfigValues(doc, tc.path); strings.Join(got, ",") != strings.Join(tc.want, ",") {
			t.Errorf("%s: got %v, want %v", tc.path, got, tc.want)
		}
	}
}

// overlay.interASVPN is a configuration-integrity setting only (AD-77): a
// Fabric declaring it false converges when the device holds false, and is
// NotConverged only when the read-back differs from the declaration.
func TestInterASVPNFalseIsAConfigurationIntegrityCaseOnly(t *testing.T) {
	f, r, _, in := fixture(t, false)
	if res := mustRun(t, f, in); !res.Passed() {
		t.Fatalf("interASVPN false read back false is no convergence rule of its own (AD-77); missing: %v", res.Missing)
	}
	r.running["spine02"] = spineRunning("true", "true")
	res := mustRun(t, f, in)
	wantMissing(t, res, "spine02", CheckConfigurationIntegrity,
		"configuration-integrity check (read from the configuration datastore)", "inter-as-vpn", "reads true", "want false")
	if len(res.Missing) != 1 {
		t.Errorf("want exactly one missing invariant, got %v", res.Missing)
	}
}

// A Fabric that declares overlay.reflectorClients false — SC-004's declarative
// negative control — is NotConverged naming each reflecting spine and the
// setting route-reflector client, whether the device reads false (as rendered)
// or still true (AD-77); the message records it as a configuration-integrity
// check read from the configuration datastore.
func TestReflectorClientsFalseDeclaredIsNotConverged(t *testing.T) {
	f, r, _, in := fixtureRC(t, true, false)
	res := mustRun(t, f, in)
	for _, spine := range []string{"spine01", "spine02"} {
		wantMissing(t, res, spine, CheckConfigurationIntegrity, "route-reflector client", "declared false", "spec.overlay.reflectorClients")
	}
	if !strings.Contains(res.Message(), "configuration-integrity check (read from the configuration datastore)") {
		t.Errorf("message does not say configuration-integrity read from the configuration datastore: %s", res.Message())
	}
	for _, m := range res.Missing {
		if m.Node == "leaf01" || m.Node == "leaf02" {
			t.Errorf("a leaf is not a reflecting spine: %v", m)
		}
		if strings.Contains(m.Detail, "inter-as-vpn") {
			t.Errorf("only route-reflector client is named: %v", m)
		}
	}
	if len(res.Missing) != 2 {
		t.Errorf("want one invariant per reflecting spine, got %v", res.Missing)
	}
	// and a device still reading true names the read-back too
	r.running["spine01"] = spineRunning("true", "true")
	res = mustRun(t, f, in)
	wantMissing(t, res, "spine01", CheckConfigurationIntegrity, "route-reflector client", "reads true", "want false")
	wantMissing(t, res, "spine01", CheckConfigurationIntegrity, "route-reflector client", "declared false")
	wantMissing(t, res, "spine02", CheckConfigurationIntegrity, "route-reflector client", "declared false")
	// true restores convergence
	f, _, _, in = fixtureRC(t, true, true)
	if res := mustRun(t, f, in); !res.Passed() {
		t.Fatalf("reflectorClients true: missing %v", res.Missing)
	}
}

func TestCouldNotRunIsAnErrorNotAResult(t *testing.T) {
	t.Run("target unreachable", func(t *testing.T) {
		f, r, _, in := fixture(t, true)
		r.unreachable["leaf02"] = errors.New("connection refused")
		_, err := f.VerifyFabric(context.Background(), in)
		e := AsCouldNotRun(err)
		if e == nil {
			t.Fatalf("want CouldNotRunError, got %v", err)
		}
		if got := e.Targets(); len(got) != 1 || got[0] != "leaf02" {
			t.Errorf("targets %v, want [leaf02]", got)
		}
		if !strings.Contains(err.Error(), "leaf02") {
			t.Errorf("error does not name the target: %v", err)
		}
	})
	t.Run("read timed out", func(t *testing.T) {
		f, r, _, in := fixture(t, true)
		r.block = true
		f.Timeout = 50 * time.Millisecond
		_, err := f.VerifyFabric(context.Background(), in)
		if !IsCouldNotRun(err) || !strings.Contains(err.Error(), "timed out") {
			t.Fatalf("want a timed-out CouldNotRunError, got %v", err)
		}
	})
	t.Run("state not served by the pinned layer", func(t *testing.T) {
		_, _, cs, in := fixture(t, true)
		rc := &configv1alpha1.RunningConfig{}
		s := newTestScheme(t)
		var objs []runtimeObject
		for _, n := range in.Nodes {
			o := rc.DeepCopy()
			o.Name, o.Namespace = n.Node, "agentic-netops-system"
			o.Status.Value.Raw = n.Rendered
			objs = append(objs, o)
		}
		c := fake.NewClientBuilder().WithScheme(s).WithObjects(toClientObjects(objs)...).Build()
		f := &Fabric{Reader: &LayerReader{Client: c}, Configs: cs}
		_, err := f.VerifyFabric(context.Background(), in)
		if !IsCouldNotRun(err) || !errors.Is(err, ErrStateNotServed) {
			t.Fatalf("want CouldNotRunError wrapping ErrStateNotServed, got %v", err)
		}
	})
	t.Run("running configuration not served", func(t *testing.T) {
		_, _, cs, in := fixture(t, true)
		c := fake.NewClientBuilder().WithScheme(newTestScheme(t)).Build()
		f := &Fabric{Reader: &LayerReader{Client: c}, Configs: cs}
		_, err := f.VerifyFabric(context.Background(), in)
		e := AsCouldNotRun(err)
		if e == nil || len(e.Targets()) != 4 {
			t.Fatalf("want all four targets unable to run, got %v", err)
		}
	})
}

// The read-back never counts EVPN routes (FR-100, AD-23): no received-routes,
// active-routes, sent-routes or RIB path is ever read, at run time or in the
// source's string literals.
func TestNoEVPNRouteCountIsEverRead(t *testing.T) {
	forbidden := []string{"received-routes", "active-routes", "sent-routes", "bgp-rib", "/rib", "evpn/routes", "route-count"}
	f, r, _, in := fixture(t, true)
	in.Findings = []FindingInput{{Index: 0, Node: "leaf01", DeviceObjects: []string{"macvrf-x", "ethernet-1/1.100", "vxlan0.10021", "acl-x-ingress"}}}
	mustRun(t, f, in)
	f2, r2, _, in2 := fixture(t, false)
	mustRun(t, f2, in2)
	all := append(append([]string{}, r.paths...), r2.paths...)
	if len(all) == 0 {
		t.Fatal("no path read")
	}
	for _, p := range all {
		for _, bad := range forbidden {
			if strings.Contains(p, bad) {
				t.Errorf("read-back reads a route-count path: %s", p)
			}
		}
	}
	fs := token.NewFileSet()
	file, err := parser.ParseFile(fs, "fabric.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	ast.Inspect(file, func(n ast.Node) bool {
		if lit, ok := n.(*ast.BasicLit); ok && lit.Kind == token.STRING {
			v, _ := strconv.Unquote(lit.Value)
			for _, bad := range forbidden {
				if strings.Contains(v, bad) {
					t.Errorf("fabric.go:%d string literal names %q: %s", fs.Position(lit.Pos()).Line, bad, v)
				}
			}
		}
		return true
	})
}

func TestFindingsClearOnlyWhenAbsentFromBothDatastores(t *testing.T) {
	objs := []string{"macvrf-4b7e", "ethernet-1/1.100", "vxlan0.10021", "acl-4b7e-ingress"}
	f, r, _, in := fixture(t, true)
	in.Findings = []FindingInput{{Index: 3, Node: "leaf01", DeviceObjects: objs}}
	if res := mustRun(t, f, in); len(res.ClearedFindings) != 1 || res.ClearedFindings[0] != 3 {
		t.Fatalf("absent everywhere: cleared %v, want [3]", res.ClearedFindings)
	}
	// still in the running datastore
	r.running["leaf01"] = `{"srl_nokia-interfaces:interface":[{"name":"system0","admin-state":"enable"},{"name":"ethernet-1/1","subinterface":[{"index":100}]}],` +
		`"srl_nokia-network-instance:network-instance":[{"name":"default","type":"srl_nokia-network-instance:default"}]}`
	if res := mustRun(t, f, in); len(res.ClearedFindings) != 0 {
		t.Errorf("subinterface in running: cleared %v", res.ClearedFindings)
	}
	delete(r.running, "leaf01")
	// still in the state datastore
	r.setNode("leaf01", DeviceObjectStatePath("vxlan0.10021"), []string{"10021"})
	if res := mustRun(t, f, in); len(res.ClearedFindings) != 0 {
		t.Errorf("tunnel in state: cleared %v", res.ClearedFindings)
	}
	if got := DeviceObjectStatePath("vxlan0.10021"); got != "/tunnel-interface[name=vxlan0]/vxlan-interface[index=10021]/index" {
		t.Errorf("tunnel path %s", got)
	}
	if got := DeviceObjectStatePath("macvrf-4b7e"); got != "/network-instance[name=macvrf-4b7e]/name" {
		t.Errorf("instance path %s", got)
	}
}

func TestConfigReaderErrorIsCouldNotRun(t *testing.T) {
	f, _, cs, in := fixture(t, true)
	cs.err = errors.New("the layer's API did not answer")
	if _, err := f.VerifyFabric(context.Background(), in); !IsCouldNotRun(err) {
		t.Fatalf("want CouldNotRunError, got %v", err)
	}
}

func containsStr(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}
