package verify

import (
	"context"
	"errors"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/status"
)

// ---------------------------------------------------------------------------
// Fakes: a StateReader whose state datastore is a per-node map (what the
// collector would answer), recording every path requested; and the
// ConfigReader of fabric_test.go.
// ---------------------------------------------------------------------------

type svcReader struct {
	mu          sync.Mutex
	running     map[string]string
	state       map[string]map[string][]string // node -> path -> values
	unreachable map[string]error
	block       bool
	requested   map[string][]string // node -> paths requested
}

func newSvcReader() *svcReader {
	return &svcReader{running: map[string]string{}, state: map[string]map[string][]string{},
		unreachable: map[string]error{}, requested: map[string][]string{}}
}

func (f *svcReader) Running(_ context.Context, t Target) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.unreachable[t.Name]; err != nil {
		return nil, err
	}
	if r, ok := f.running[t.Name]; ok {
		return []byte(r), nil
	}
	return []byte(`{}`), nil
}

func (f *svcReader) State(ctx context.Context, t Target, paths []string) (map[string][]string, error) {
	f.mu.Lock()
	block, err := f.block, f.unreachable[t.Name]
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
	f.requested[t.Name] = append(f.requested[t.Name], paths...)
	out := map[string][]string{}
	for _, p := range paths {
		if v := f.state[t.Name][p]; len(v) > 0 {
			out[p] = v
		}
	}
	return out, nil
}

func (f *svcReader) set(node, path string, vals ...string) {
	if f.state[node] == nil {
		f.state[node] = map[string][]string{}
	}
	if len(vals) == 0 {
		delete(f.state[node], path)
		return
	}
	f.state[node][path] = vals
}

func (f *svcReader) allRequested() []string {
	var out []string
	for _, ps := range f.requested {
		out = append(out, ps...)
	}
	sort.Strings(out)
	return out
}

// healthy fills the state datastore so every expectation of in holds: the
// wanted value, a non-zero index, and no reason leaf.
func healthy(t *testing.T, r *svcReader, in ServiceInput) {
	t.Helper()
	exps, err := ServiceExpectations(in)
	if err != nil {
		t.Fatal(err)
	}
	for node, es := range exps {
		for _, e := range es {
			if e.Expect == ExpectNonZero {
				r.set(node, e.Path, "103476342702")
			} else {
				r.set(node, e.Path, e.Want)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Inputs.
// ---------------------------------------------------------------------------

var testLoopbacks = map[string]string{"leaf01": "10.0.0.1/32", "leaf02": "10.0.0.2", "leaf03": "10.0.0.3"}

func buildService(t *testing.T, in model.ServiceInput) *model.ServiceModel {
	t.Helper()
	in.FabricASN = 65000
	m, err := model.BuildService(in)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func vlanModel(t *testing.T, nodes ...string) *model.ServiceModel {
	var att []model.Attachment
	for _, n := range nodes {
		att = append(att, model.Attachment{Node: n, Port: "ethernet-1/1"})
	}
	return buildService(t, model.ServiceInput{ServiceID: "v1", Construct: model.ConstructVLAN,
		L2: &model.L2Segment{VLAN: 990, Attachments: att}})
}

func macvrfModel(t *testing.T, gateway bool, nodes ...string) *model.ServiceModel {
	var att []model.Attachment
	for _, n := range nodes {
		att = append(att, model.Attachment{Node: n, Port: "ethernet-1/1"})
	}
	in := model.ServiceInput{ServiceID: "m1", Construct: model.ConstructMACVRF,
		L2: &model.L2Segment{VLAN: 990, L2VNI: 19990, Attachments: att}}
	if gateway {
		in.Gateway = &model.Gateway{L3VNI: 19991, IPv4: []string{"10.10.0.1/24"}, IPv6: []string{"2001:db8:10::1/64"}, IPMTU: 1500}
	}
	return buildService(t, in)
}

func ipvrfModel(t *testing.T) *model.ServiceModel {
	return buildService(t, model.ServiceInput{ServiceID: "r1", Construct: model.ConstructIPVRF,
		Routed: &model.RoutedService{L3VNI: 19991, Attachments: []model.RoutedAttachment{
			{Node: "leaf01", Port: "ethernet-1/1", VLAN: 991, IPv4: []string{"10.199.1.1/24"}, IPv6: []string{"2001:db8:199:1::1/64"}},
			{Node: "leaf02", Port: "ethernet-1/1", VLAN: 991, IPv4: []string{"10.199.2.1/24"}},
		}, IPMTU: 9348}})
}

// serviceFixture is a ready pass: every node's Config Ready, its rendered
// document in the running datastore, and a healthy state datastore.
func serviceFixture(t *testing.T, m *model.ServiceModel, prefixes map[string][]string) (*Service, ServiceInput, *svcReader, *fakeConfigs) {
	t.Helper()
	r := newSvcReader()
	cfgs := &fakeConfigs{cfgs: map[string]*configv1alpha1.Config{}, devs: map[string]*configv1alpha1.Deviation{}}
	in := ServiceInput{Model: m, Prefixes: prefixes, Loopbacks: testLoopbacks, TargetNamespace: "agentic-netops-system"}
	for _, n := range m.Nodes {
		name := "svc-" + m.ServiceID + "-" + n.Node
		doc := `{"network-instance":[{"name":"` + n.NetworkInstances[0].Name + `","admin-state":"enable"}]}`
		in.Nodes = append(in.Nodes, ServiceNodeInput{Node: n.Node, ConfigName: name, Rendered: []byte(doc)})
		cfgs.cfgs[name] = readyConfig(name, 1)
		r.running[n.Node] = doc
	}
	healthy(t, r, in)
	return &Service{Reader: r, Configs: cfgs}, in, r, cfgs
}

func mustPass(t *testing.T, s *Service, in ServiceInput) ServiceResult {
	t.Helper()
	res, err := s.VerifyService(context.Background(), in)
	if err != nil {
		t.Fatalf("pass could not run: %v", err)
	}
	if !res.Passed() {
		t.Fatalf("expected a passing read-back, got %s", res.Message())
	}
	return res
}

func mustMiss(t *testing.T, s *Service, in ServiceInput) ServiceResult {
	t.Helper()
	res, err := s.VerifyService(context.Background(), in)
	if err != nil {
		t.Fatalf("pass could not run: %v", err)
	}
	if res.Passed() {
		t.Fatal("expected missing invariants, the read-back passed")
	}
	return res
}

// hasMissing finds the invariant of node and check whose detail carries every fragment.
func hasMissing(res ServiceResult, node string, c Check, fragments ...string) bool {
	for _, m := range res.Missing {
		if m.Node != node || m.Check != c {
			continue
		}
		ok := true
		for _, f := range fragments {
			if !strings.Contains(m.Detail, f) {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Tests common to every construct.
// ---------------------------------------------------------------------------

func TestServiceWrittenSide(t *testing.T) {
	m := macvrfModel(t, false, "leaf01", "leaf02")

	t.Run("config not applied", func(t *testing.T) {
		s, in, _, cfgs := serviceFixture(t, m, nil)
		cfgs.cfgs["svc-m1-leaf02"] = readyConfig("svc-m1-leaf02", 3)
		cfgs.cfgs["svc-m1-leaf02"].Generation = 4
		res := mustMiss(t, s, in)
		if !hasMissing(res, "leaf02", CheckWritten, "svc-m1-leaf02 not applied", "generation 3", "at 4") {
			t.Errorf("stale generation not named: %s", res.Message())
		}
		if res.Reason() != status.ReasonNotConverged {
			t.Errorf("reason %s", res.Reason())
		}
	})
	t.Run("config absent", func(t *testing.T) {
		s, in, _, cfgs := serviceFixture(t, m, nil)
		delete(cfgs.cfgs, "svc-m1-leaf01")
		res := mustMiss(t, s, in)
		if !hasMissing(res, "leaf01", CheckWritten, "Config svc-m1-leaf01 absent") {
			t.Errorf("absent Config not named: %s", res.Message())
		}
	})
	t.Run("deviation", func(t *testing.T) {
		s, in, _, cfgs := serviceFixture(t, m, nil)
		dev := &configv1alpha1.Deviation{ObjectMeta: metav1.ObjectMeta{Name: "svc-m1-leaf01"}}
		dev.Spec.Deviations = []configv1alpha1.ConfigDeviation{{Path: "/network-instance[name=macvrf-m1]/admin-state", Reason: "NOT_APPLIED"}}
		cfgs.devs["svc-m1-leaf01"] = dev
		res := mustMiss(t, s, in)
		if !hasMissing(res, "leaf01", CheckWritten, "deviation", "macvrf-m1", "NOT_APPLIED") {
			t.Errorf("deviation not named: %s", res.Message())
		}
	})
	t.Run("rendered content absent from running", func(t *testing.T) {
		s, in, r, _ := serviceFixture(t, m, nil)
		r.running["leaf02"] = `{"network-instance":[{"name":"macvrf-m1","admin-state":"disable"}]}`
		res := mustMiss(t, s, in)
		if !hasMissing(res, "leaf02", CheckWritten, "absent from the running datastore", "network-instance[name=macvrf-m1]") {
			t.Errorf("running difference not named: %s", res.Message())
		}
	})
	t.Run("config read error cannot run", func(t *testing.T) {
		s, in, _, cfgs := serviceFixture(t, m, nil)
		cfgs.err = errors.New("apiserver down")
		_, err := s.VerifyService(context.Background(), in)
		if !IsCouldNotRun(err) {
			t.Fatalf("want CouldNotRunError, got %v", err)
		}
	})
}

func TestServiceCouldNotRun(t *testing.T) {
	m := macvrfModel(t, false, "leaf01", "leaf02")

	t.Run("node with no sample in the collector", func(t *testing.T) {
		s, in, r, _ := serviceFixture(t, m, nil)
		r.unreachable["leaf02"] = errors.New("the device metric collector holds no sample from leaf02 within its expiration window")
		res, err := s.VerifyService(context.Background(), in)
		cnr := AsCouldNotRun(err)
		if cnr == nil {
			t.Fatalf("want CouldNotRunError, got %v (result %+v)", err, res)
		}
		if got := cnr.Targets(); len(got) != 1 || got[0] != "leaf02" {
			t.Errorf("targets %v, want [leaf02]", got)
		}
		if !strings.Contains(err.Error(), "leaf02") || !strings.Contains(err.Error(), "no sample") {
			t.Errorf("error does not name the node and cause: %v", err)
		}
		if res.Passed() && len(res.Paths) > 0 {
			t.Error("a pass that could not run returned a result")
		}
	})
	t.Run("collector error through the real CollectorReader", func(t *testing.T) {
		s, in, _, _ := serviceFixture(t, m, nil)
		s.Reader = &CollectorReader{Layer: s.Reader, URL: "http://127.0.0.1:1/metrics", HTTP: nil}
		_, err := s.VerifyService(context.Background(), in)
		if cnr := AsCouldNotRun(err); cnr == nil || len(cnr.Targets()) != 2 {
			t.Fatalf("want CouldNotRunError naming both leaves, got %v", err)
		}
	})
	t.Run("timeout", func(t *testing.T) {
		s, in, r, _ := serviceFixture(t, m, nil)
		r.block = true
		s.Timeout = 50 * time.Millisecond
		_, err := s.VerifyService(context.Background(), in)
		if !IsCouldNotRun(err) || !strings.Contains(err.Error(), "timed out") {
			t.Fatalf("want a timed-out CouldNotRunError, got %v", err)
		}
	})
	t.Run("the state datastore not served", func(t *testing.T) {
		s, in, _, _ := serviceFixture(t, m, nil)
		// the layer's own answer to a state read (LayerReader.State), with a
		// running datastore that is served
		s.Reader = stateNotServed{s: newSvcReader()}
		_, err := s.VerifyService(context.Background(), in)
		if !IsCouldNotRun(err) || !errors.Is(err, ErrStateNotServed) {
			t.Fatalf("want CouldNotRunError wrapping ErrStateNotServed, got %v", err)
		}
	})
}

type stateNotServed struct{ s *svcReader }

func (r stateNotServed) Running(ctx context.Context, t Target) ([]byte, error) {
	return r.s.Running(ctx, t)
}
func (r stateNotServed) State(ctx context.Context, t Target, p []string) (map[string][]string, error) {
	return (&LayerReader{}).State(ctx, t, p)
}

func TestServiceNilModel(t *testing.T) {
	if _, err := (&Service{}).VerifyService(context.Background(), ServiceInput{}); err == nil || IsCouldNotRun(err) {
		t.Fatalf("nil model: %v", err)
	}
}

// TestServiceReasonPrecedence: NotConverged, then NotProgrammed, then RoutesMissing.
func TestServiceReasonPrecedence(t *testing.T) {
	inv := func(c Check) Invariant { return Invariant{Node: "leaf01", Check: c, Detail: "x"} }
	for _, tc := range []struct {
		checks []Check
		want   string
	}{
		{[]Check{CheckRemotePrefixRoute}, status.ReasonRoutesMissing},
		{[]Check{CheckMulticastDestination, CheckRemoteVTEP}, status.ReasonRoutesMissing},
		{[]Check{CheckRemoteVTEP, CheckNotProgrammed}, status.ReasonNotProgrammed},
		{[]Check{CheckNotProgrammed, CheckEVPNInstanceOperState, CheckRemotePrefixRoute}, status.ReasonNotConverged},
		{[]Check{CheckWritten}, status.ReasonNotConverged},
		{[]Check{CheckBGPVPNOrigin}, status.ReasonNotConverged},
		{[]Check{CheckLocalPrefixRoute}, status.ReasonNotConverged},
	} {
		var res ServiceResult
		for _, c := range tc.checks {
			res.Missing = append(res.Missing, inv(c))
		}
		if got := res.Reason(); got != tc.want {
			t.Errorf("%v: reason %s, want %s", tc.checks, got, tc.want)
		}
		if !strings.HasPrefix(res.Message(), "missing: leaf01 ") {
			t.Errorf("message %q", res.Message())
		}
	}
	if (ServiceResult{}).Message() != "read-back passed on both sides" {
		t.Error("passing message")
	}
}

// ---------------------------------------------------------------------------
// FR-100 / CR-001: every path requested is keyed to the service's own objects;
// no aggregate is ever read.
// ---------------------------------------------------------------------------

var aggregateFragments = []string{"received-routes", "active-routes", "route-summary", "statistics", "total-", "-count", "multicast-limit", "current-usage"}

// ownKeys are the key fragments that name this service's own objects on node
// n (or, for a spanning mac-vrf, the remote VTEPs of this service).
func ownKeys(in ServiceInput, node string) []string {
	var keys []string
	n := in.Model.Node(node)
	for _, ni := range n.NetworkInstances {
		keys = append(keys, "/network-instance[name="+ni.Name+"]/")
	}
	for _, s := range n.Subinterfaces {
		keys = append(keys, "/interface[name="+s.Port+"]/subinterface[index="+itoa(s.Index)+"]/")
	}
	for _, vx := range n.VXLANInterfaces {
		keys = append(keys, "/tunnel-interface[name=vxlan0]/vxlan-interface[index="+itoa(vx.Index)+"]/")
	}
	for other, lb := range in.Loopbacks {
		if other != node && in.Model.Node(other) != nil {
			keys = append(keys, "/tunnel/vxlan-tunnel/vtep[address="+vtepAddress(lb)+"]/")
		}
	}
	return keys
}

func itoa(u uint32) string { return strconv.FormatUint(uint64(u), 10) }

var unkeyedList = regexp.MustCompile(`/(network-instance|interface|subinterface|tunnel-interface|vxlan-interface|bgp-instance|route|destination|vtep)/`)

func assertKeyed(t *testing.T, in ServiceInput, r *svcReader) {
	t.Helper()
	if len(r.requested) == 0 {
		t.Fatal("no state path requested")
	}
	for node, paths := range r.requested {
		keys := ownKeys(in, node)
		for _, p := range paths {
			if strings.Contains(p, "*") {
				t.Errorf("%s: wildcard path %s", node, p)
			}
			if unkeyedList.MatchString(p + "/") {
				t.Errorf("%s: a list is read unkeyed in %s", node, p)
			}
			for _, a := range aggregateFragments {
				if strings.Contains(p, a) {
					t.Errorf("%s: aggregate path %s (%s)", node, p, a)
				}
			}
			own := false
			for _, k := range keys {
				if strings.HasPrefix(p, k) {
					own = true
					break
				}
			}
			if !own {
				t.Errorf("%s: path %s is not keyed to this service's own objects (%v)", node, p, keys)
			}
			if strings.Contains(p, "network-instance[name=default]") {
				t.Errorf("%s: the default instance is read: %s", node, p)
			}
		}
	}
}

func TestServicePathsKeyedNoAggregate(t *testing.T) {
	for name, tc := range map[string]struct {
		m        *model.ServiceModel
		prefixes map[string][]string
	}{
		"vlan":            {vlanModel(t, "leaf01", "leaf02"), nil},
		"mac-vrf":         {macvrfModel(t, false, "leaf01", "leaf02", "leaf03"), nil},
		"mac-vrf+gateway": {macvrfModel(t, true, "leaf01", "leaf02"), map[string][]string{"ipvrf-m1": {"10.10.0.0/24"}}},
		"ip-vrf":          {ipvrfModel(t), map[string][]string{"ipvrf-r1": {"10.199.1.0/24", "10.199.2.0/24", "10.77.0.0/16"}}},
	} {
		t.Run(name, func(t *testing.T) {
			s, in, r, _ := serviceFixture(t, tc.m, tc.prefixes)
			res := mustPass(t, s, in)
			assertKeyed(t, in, r)
			if got, want := res.Paths, r.allRequested(); strings.Join(got, "\n") != strings.Join(want, "\n") {
				t.Errorf("result paths differ from the paths requested:\n%v\n%v", got, want)
			}
		})
	}
}
