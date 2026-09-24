package verify

// T108 — the keyed access-list read-back (contracts/acl-render-contract.md
// §4.1–§4.5 as reconciled by live finding 2026-09-21-acl-binding-state).
// The applied side is read the way the provider reads it: through MatchState
// over the device metric collector's series (gNMIc names, list keys as
// labels), so a key the read-back leaves unspecified really does match any
// instance and a keyed read really does exclude every other filter.

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"

	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"

	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/render/srl"
	"github.com/mairp/agentic-netops-srl/internal/status"
)

// sampleReader is a StateReader whose state datastore is the collector's
// exposition: per node, a set of series matched by MatchState.
type sampleReader struct {
	mu        sync.Mutex
	running   map[string][]byte
	samples   map[string][]Sample
	requested map[string][]string
}

func (r *sampleReader) Running(_ context.Context, t Target) ([]byte, error) {
	if b, ok := r.running[t.Name]; ok {
		return b, nil
	}
	return []byte(`{}`), nil
}

func (r *sampleReader) State(_ context.Context, t Target, paths []string) (map[string][]string, error) {
	r.mu.Lock()
	r.requested[t.Name] = append(r.requested[t.Name], paths...)
	r.mu.Unlock()
	return MatchState(r.samples[t.Name], paths)
}

const (
	tcamSeries  = "srl_nokia_acl:acl_acl_filter_entry_tcam_entries_forwarding_complex_"
	statsSeries = "srl_nokia_acl:acl_acl_filter_entry_statistics_"
	progSeries  = "srl_nokia_acl:acl_datapath_programming_forwarding_complex_programming_complete"
)

func entrySample(node, series, filter, typ string, seq uint32, extra map[string]string, v string) Sample {
	l := map[string]string{"source": node, "acl_filter_name": filter, "acl_filter_type": typ, "entry_sequence_id": fmt.Sprint(seq)}
	for k, x := range extra {
		l[k] = x
	}
	return Sample{Name: series, Labels: l, Value: v}
}

// tcamSamples: one entry's TCAM on one complex, by direction.
func tcamSamples(node, filter, typ string, seq uint32, complex string, single, in, out string) []Sample {
	cx := map[string]string{"forwarding_complex_complex_identifier": complex}
	return []Sample{
		entrySample(node, tcamSeries+"single_instance", filter, typ, seq, cx, single),
		entrySample(node, tcamSeries+"input_total", filter, typ, seq, cx, in),
		entrySample(node, tcamSeries+"output_total", filter, typ, seq, cx, out),
	}
}

func statsSamples(node, filter, typ string, seq uint32, matched, incomplete string) []Sample {
	return []Sample{
		entrySample(node, statsSeries+"matched_packets", filter, typ, seq, nil, matched),
		entrySample(node, statsSeries+"incomplete", filter, typ, seq, nil, incomplete),
	}
}

func progSample(node, slot, complex, v string) Sample {
	return Sample{Name: progSeries, Value: v, Labels: map[string]string{"source": node,
		"forwarding_complex_slot_id": slot, "forwarding_complex_complex_id": complex}}
}

// stockSamples is what a stock SR Linux node exports: containerlab's and the
// image's control-plane filters (`cpm`, ipv4 and ipv6), dozens of entries, all
// programmed and counting — and the programming gate true.
func stockSamples(node string) []Sample {
	out := []Sample{progSample(node, "1", "0", "1")}
	for _, typ := range []string{"ipv4", "ipv6"} {
		for seq := uint32(10); seq <= 400; seq += 10 {
			out = append(out, tcamSamples(node, "cpm", typ, seq, "(1,0)", "2", "2", "0")...)
			out = append(out, statsSamples(node, "cpm", typ, seq, "1234", "0")...)
		}
	}
	return out
}

// programmedSamples: every entry of every filter of n programmed in the
// direction(s) n binds it, statistics readable and complete (matched 0: a
// quiet link).
func programmedSamples(n *model.ServiceNode) []Sample {
	var out []Sample
	for _, b := range boundFilters(n) {
		in, outd := "0", "0"
		if len(b.dirs["input"]) > 0 {
			in = "2"
		}
		if len(b.dirs["output"]) > 0 {
			outd = "2"
		}
		for _, e := range b.filter.Entries {
			out = append(out, tcamSamples(n.Node, b.filter.Name, string(b.filter.Type), e.SequenceID, "(1,0)", "2", in, outd)...)
			out = append(out, statsSamples(n.Node, b.filter.Name, string(b.filter.Type), e.SequenceID, "0", "0")...)
		}
	}
	return out
}

// aclModel: a standalone `acl` — ingress IPv4 with a default deny, bound on
// leaf01 ethernet-1/1.110 (egress: the same list at stage egress).
func aclModel(t *testing.T, stage model.Stage) *model.ServiceModel {
	t.Helper()
	deny := model.ActionDrop
	return buildService(t, model.ServiceInput{ServiceID: "guard", Tenant: "t1", Construct: model.ConstructACL,
		AccessLists: []model.AccessList{{Stage: stage, Family: model.FamilyIPv4, DefaultAction: &deny,
			Rules: []model.ACLRule{{Name: "permit-https", Priority: 100, Action: model.ActionAccept, Protocol: "tcp",
				SourcePrefix: "10.0.0.0/24", DestinationPort: &model.PortMatch{Lo: 443}}},
			Bindings: []model.ACLBinding{{Node: "leaf01", Port: "ethernet-1/1", VLAN: 110}}}}})
}

// aclFixture: every node's Config Ready, its rendered document in running, the
// stock control-plane filters plus this service's programmed entries in state.
func aclFixture(t *testing.T, m *model.ServiceModel) (*Service, ServiceInput, *sampleReader) {
	t.Helper()
	r := &sampleReader{running: map[string][]byte{}, samples: map[string][]Sample{}, requested: map[string][]string{}}
	cfgs := &fakeConfigs{cfgs: map[string]*configv1alpha1.Config{}, devs: map[string]*configv1alpha1.Deviation{}}
	in := ServiceInput{Model: m, Loopbacks: testLoopbacks, TargetNamespace: "agentic-netops-system"}
	for i := range m.Nodes {
		n := &m.Nodes[i]
		doc, err := srl.RenderServiceNode(n)
		if err != nil {
			t.Fatal(err)
		}
		name := "svc-" + m.ServiceID + "." + n.Node
		in.Nodes = append(in.Nodes, ServiceNodeInput{Node: n.Node, ConfigName: name, Rendered: doc.JSON})
		cfgs.cfgs[name] = readyConfig(name, 1)
		r.running[n.Node] = doc.JSON
		r.samples[n.Node] = append(stockSamples(n.Node), programmedSamples(n)...)
	}
	return &Service{Reader: r, Configs: cfgs}, in, r
}

// setSample replaces (or with v == "" removes) every series of name for this
// filter entry whose extra labels match.
func setSample(r *sampleReader, node, series, filter string, seq uint32, v string) {
	var out []Sample
	for _, s := range r.samples[node] {
		if s.Name == series && s.Labels["acl_filter_name"] == filter && s.Labels["entry_sequence_id"] == fmt.Sprint(seq) {
			if v == "" {
				continue
			}
			s.Value = v
		}
		out = append(out, s)
	}
	r.samples[node] = out
}

// ---------------------------------------------------------------------------

func TestACLReadbackPassesKeyed(t *testing.T) {
	for _, stage := range []model.Stage{model.StageIngress, model.StageEgress} {
		s, in, r := aclFixture(t, aclModel(t, stage))
		res := mustPass(t, s, in)
		// every access-list state path is keyed by this filter's name, type and
		// entry — or is the programming gate; nothing under /acl/interface is
		// read from state (not mirrored on 25.7.1; A4 is recorded, not judged)
		filter := "acl-guard-" + string(stage)
		for _, p := range r.requested["leaf01"] {
			switch {
			case p == ACLProgrammingCompletePath():
			case strings.HasPrefix(p, "/acl/acl-filter[name="+filter+"][type=ipv4]/entry[sequence-id="):
			default:
				t.Errorf("%s: unkeyed or foreign state read %s", stage, p)
			}
		}
		if len(res.Paths) != 1+2*(1+2+2) {
			t.Errorf("%s: %d state paths read, want the gate plus 5 per entry: %v", stage, len(res.Paths), res.Paths)
		}
		for _, p := range res.ConfigPaths {
			if strings.Contains(p, "interface-ref") {
				t.Errorf("%s: a standalone list's read-back reads interface-ref (not its own, AD-68): %s", stage, p)
			}
		}
	}
}

// TestACLNegativeControlStockNode (NFR-013, §4.5): a stock node carries only
// the control-plane filters — dozens of programmed, counting entries — and
// no platform filter. The check set FAILS on it: every keyed read is absent.
func TestACLNegativeControlStockNode(t *testing.T) {
	s, in, r := aclFixture(t, aclModel(t, model.StageIngress))
	r.samples["leaf01"] = stockSamples("leaf01")
	r.running["leaf01"] = []byte(`{"srl_nokia-acl:acl": {"acl-filter": [{"name": "cpm", "type": "ipv4",
	  "entry": [{"sequence-id": 10, "action": {"accept": {}}}, {"sequence-id": 100, "action": {"accept": {}}}]}]}}`)
	res := mustMiss(t, s, in)
	for _, want := range []struct {
		c    Check
		frag []string
	}{
		{CheckACLFilter, []string{"acl-filter acl-guard-ingress type ipv4", "/acl/acl-filter[name=acl-guard-ingress][type=ipv4] absent"}},
		{CheckACLProgrammed, []string{"acl-guard-ingress type ipv4 entry 100", "single-instance reads nothing"}},
		{CheckACLProgrammed, []string{"entry 65535", "input-total reads nothing"}},
		{CheckACLStatistics, []string{"entry 100", "matched-packets reads nothing"}},
	} {
		if !hasMissing(res, "leaf01", want.c, want.frag...) {
			t.Errorf("stock node: %s %v not named in %s", want.c, want.frag, res.Message())
		}
	}
	for _, m := range res.Missing {
		if strings.Contains(m.Detail, "cpm") {
			t.Errorf("the stock filter was read as evidence: %s", m)
		}
	}
}

// TestACLNonexistentFilterFails: written but never programmed (no TCAM, no
// statistics for this filter in state) fails naming filter, type and entry.
func TestACLNonexistentFilterFails(t *testing.T) {
	s, in, r := aclFixture(t, aclModel(t, model.StageIngress))
	r.samples["leaf01"] = stockSamples("leaf01")
	res := mustMiss(t, s, in)
	for _, seq := range []string{"entry 100", "entry 65535"} {
		if !hasMissing(res, "leaf01", CheckACLProgrammed, "acl-filter acl-guard-ingress type ipv4 "+seq, "bound input on ethernet-1/1.110", "reads nothing") {
			t.Errorf("%s not named: %s", seq, res.Message())
		}
	}
	if res.Reason() != status.ReasonNotConverged {
		t.Errorf("reason %s", res.Reason())
	}
}

// TestACLAnotherServicesFilterNeverSatisfies: a fully programmed filter of
// another service (another name, same type, same entries) satisfies nothing.
func TestACLAnotherServicesFilterNeverSatisfies(t *testing.T) {
	s, in, r := aclFixture(t, aclModel(t, model.StageIngress))
	other := stockSamples("leaf01")
	for _, seq := range []uint32{100, 65535} {
		other = append(other, tcamSamples("leaf01", "acl-other-ingress", "ipv4", seq, "(1,0)", "2", "2", "0")...)
		other = append(other, statsSamples("leaf01", "acl-other-ingress", "ipv4", seq, "7", "0")...)
		// and this filter's name under the other type
		other = append(other, tcamSamples("leaf01", "acl-guard-ingress", "ipv6", seq, "(1,0)", "2", "2", "0")...)
	}
	r.samples["leaf01"] = other
	res := mustMiss(t, s, in)
	if !hasMissing(res, "leaf01", CheckACLProgrammed, "acl-guard-ingress type ipv4 entry 100", "reads nothing") {
		t.Errorf("another service's filter satisfied the read-back: %s", res.Message())
	}
}

// TestACLWrongDirectionFails: the filter programmed on output though it is
// declared ingress: A2 (input-total 0) is NotProgrammed and A3 (output-total
// > 0) names the undeclared direction.
func TestACLWrongDirectionFails(t *testing.T) {
	s, in, r := aclFixture(t, aclModel(t, model.StageIngress))
	for _, seq := range []uint32{100, 65535} {
		setSample(r, "leaf01", tcamSeries+"input_total", "acl-guard-ingress", seq, "0")
		setSample(r, "leaf01", tcamSeries+"output_total", "acl-guard-ingress", seq, "2")
	}
	res := mustMiss(t, s, in)
	if !hasMissing(res, "leaf01", CheckACLDirection, "acl-guard-ingress type ipv4 entry 100 not bound output", "output-total reads 2, want 0") {
		t.Errorf("A3 not named: %s", res.Message())
	}
	if !hasMissing(res, "leaf01", CheckNotProgrammed, "entry 65535 bound input on ethernet-1/1.110", "input-total reads 0") {
		t.Errorf("A2 not named: %s", res.Message())
	}
	// A3 alone (input programmed too) still fails
	s, in, r = aclFixture(t, aclModel(t, model.StageIngress))
	setSample(r, "leaf01", tcamSeries+"output_total", "acl-guard-ingress", 100, "2")
	res = mustMiss(t, s, in)
	if len(res.Missing) != 1 || res.Missing[0].Check != CheckACLDirection {
		t.Errorf("want exactly A3: %s", res.Message())
	}
}

// TestACLTCAMOnAnyComplex: A1/A2 need > 0 on at least one complex; a second
// complex reading 0 (the subinterface lives elsewhere) does not fail it.
func TestACLTCAMOnAnyComplex(t *testing.T) {
	s, in, r := aclFixture(t, aclModel(t, model.StageIngress))
	r.samples["leaf01"] = append(r.samples["leaf01"], tcamSamples("leaf01", "acl-guard-ingress", "ipv4", 100, "(1,1)", "2", "0", "0")...)
	mustPass(t, s, in)
	// every complex 0 on input: NotProgrammed
	setSample(r, "leaf01", tcamSeries+"input_total", "acl-guard-ingress", 100, "0")
	res := mustMiss(t, s, in)
	if res.Reason() != status.ReasonNotProgrammed || !hasMissing(res, "leaf01", CheckNotProgrammed, "entry 100 bound input", "reads 0,0") {
		t.Errorf("reason %s: %s", res.Reason(), res.Message())
	}
}

// TestACLStatisticsAndGate: matched-packets' value is never judged (0 on a
// quiet link passes), but it must be readable; incomplete true fails; the
// programming gate false on any complex fails.
func TestACLStatisticsAndGate(t *testing.T) {
	s, in, r := aclFixture(t, aclModel(t, model.StageIngress))
	setSample(r, "leaf01", statsSeries+"matched_packets", "acl-guard-ingress", 100, "0")
	mustPass(t, s, in)

	setSample(r, "leaf01", statsSeries+"matched_packets", "acl-guard-ingress", 100, "")
	res := mustMiss(t, s, in)
	if !hasMissing(res, "leaf01", CheckACLStatistics, "entry 100 statistics", "matched-packets reads nothing") {
		t.Errorf("A5 readable: %s", res.Message())
	}

	s, in, r = aclFixture(t, aclModel(t, model.StageIngress))
	setSample(r, "leaf01", statsSeries+"incomplete", "acl-guard-ingress", 65535, "1")
	res = mustMiss(t, s, in)
	if !hasMissing(res, "leaf01", CheckACLStatistics, "entry 65535 statistics complete", "reads true, want not true") {
		t.Errorf("A5 incomplete: %s", res.Message())
	}

	s, in, r = aclFixture(t, aclModel(t, model.StageIngress))
	r.samples["leaf01"] = append(r.samples["leaf01"], progSample("leaf01", "2", "0", "0"))
	res = mustMiss(t, s, in)
	if !hasMissing(res, "leaf01", CheckACLProgramming, "reads true,false, want true on every instance") {
		t.Errorf("G1: %s", res.Message())
	}
	var kept []Sample
	for _, x := range r.samples["leaf01"] {
		if x.Name != progSeries {
			kept = append(kept, x)
		}
	}
	r.samples["leaf01"] = kept
	res = mustMiss(t, s, in)
	if !hasMissing(res, "leaf01", CheckACLProgramming, "reads nothing") {
		t.Errorf("G1 absent: %s", res.Message())
	}
}

// editRunning applies f to leaf01's running document.
func editRunning(t *testing.T, r *sampleReader, f func(acl map[string]any)) {
	t.Helper()
	var doc map[string]any
	if err := json.Unmarshal(r.running["leaf01"], &doc); err != nil {
		t.Fatal(err)
	}
	f(doc["srl_nokia-acl:acl"].(map[string]any))
	b, _ := json.Marshal(doc)
	r.running["leaf01"] = b
}

func firstFilter(a map[string]any) map[string]any { return a["acl-filter"].([]any)[0].(map[string]any) }

func entryAt(a map[string]any, seq float64) map[string]any {
	for _, e := range firstFilter(a)["entry"].([]any) {
		if m := e.(map[string]any); m["sequence-id"] == seq {
			return m
		}
	}
	return nil
}

// TestACLWrittenSideNamed: C2–C7 each fail naming filter, entry or
// direction when the running datastore disagrees with the render.
func TestACLWrittenSideNamed(t *testing.T) {
	cases := map[string]struct {
		stage model.Stage
		edit  func(a map[string]any)
		c     Check
		frag  []string
	}{
		"C2 action": {model.StageIngress, func(a map[string]any) { entryAt(a, 100)["action"] = map[string]any{"drop": map[string]any{}} },
			CheckACLEntry, []string{"entry 100", "/action/accept absent"}},
		"C3 match value": {model.StageIngress, func(a map[string]any) {
			entryAt(a, 100)["match"].(map[string]any)["transport"].(map[string]any)["destination-port"].(map[string]any)["value"] = 8443
		}, CheckACLEntry, []string{"entry 100", "destination-port/value reads 8443, want 443"}},
		"C4 default": {model.StageIngress, func(a map[string]any) {
			f := firstFilter(a)
			f["entry"] = f["entry"].([]any)[:1]
		}, CheckACLEntry, []string{"entry 65535 (the declared default action)", "absent"}},
		"C6 binding": {model.StageIngress, func(a map[string]any) { delete(a["interface"].([]any)[0].(map[string]any), "input") },
			CheckACLBinding, []string{"not bound input on ethernet-1/1.110"}},
		"C6 other direction": {model.StageIngress, func(a map[string]any) {
			ai := a["interface"].([]any)[0].(map[string]any)
			ai["output"] = ai["input"]
		}, CheckACLBinding, []string{"bound output on ethernet-1/1.110, a direction not declared"}},
		"C7 egress": {model.StageEgress, func(a map[string]any) { delete(firstFilter(a), "subinterface-specific") },
			CheckACLFilter, []string{"acl-guard-egress", "subinterface-specific reads nothing, want output-only"}},
	}
	for name, c := range cases {
		s, in, r := aclFixture(t, aclModel(t, c.stage))
		editRunning(t, r, c.edit)
		res, err := s.VerifyService(context.Background(), in)
		if err != nil {
			t.Fatal(err)
		}
		if !hasMissing(res, "leaf01", c.c, c.frag...) {
			t.Errorf("%s: not named: %s", name, res.Message())
		}
	}
}

// TestACLServicePropertyInReadback: a `vlan` carrying its own list is Ready
// only when the list's checks hold too, and C5 reads the interface-ref it owns.
func TestACLServicePropertyInReadback(t *testing.T) {
	deny := model.ActionDrop
	m := buildService(t, model.ServiceInput{ServiceID: "v1", Construct: model.ConstructVLAN,
		L2: &model.L2Segment{VLAN: 990, Attachments: []model.Attachment{{Node: "leaf01", Port: "ethernet-1/1"}}},
		AccessLists: []model.AccessList{{Stage: model.StageIngress, Family: model.FamilyIPv6, DefaultAction: &deny,
			Rules:    []model.ACLRule{{Name: "permit-icmpv6", Priority: 10, Action: model.ActionAccept, Protocol: "icmpv6"}},
			Bindings: []model.ACLBinding{{Node: "leaf01", Port: "ethernet-1/1", VLAN: 990}}}}})
	s, in, r, _ := serviceFixture(t, m, nil)
	doc, err := srl.RenderServiceNode(m.Node("leaf01"))
	if err != nil {
		t.Fatal(err)
	}
	r.running["leaf01"] = string(doc.JSON)
	in.Nodes[0].Rendered = doc.JSON
	res := mustPass(t, s, in)
	for _, p := range []string{"/acl/interface[interface-id=ethernet-1/1.990]/interface-ref/subinterface",
		"/acl/acl-filter[name=acl-v1-ingress][type=ipv6]/entry[sequence-id=10]/match/ipv6/next-header"} {
		if !containsString(res.ConfigPaths, p) {
			t.Errorf("config path %s not read: %v", p, res.ConfigPaths)
		}
	}
	// the list unprogrammed: the service is not Ready, the filter named
	r.set("leaf01", ACLTCAMPath("acl-v1-ingress", model.FamilyIPv6, 10, "input-total"), "0")
	res = mustMiss(t, s, in)
	if !hasMissing(res, "leaf01", CheckNotProgrammed, "acl-filter acl-v1-ingress type ipv6 entry 10 bound input on ethernet-1/1.990") {
		t.Errorf("not named: %s", res.Message())
	}
	// the interface-ref the vlan owns, absent from running
	s, in, r, _ = serviceFixture(t, m, nil)
	var d map[string]any
	_ = json.Unmarshal(doc.JSON, &d)
	delete(d["srl_nokia-acl:acl"].(map[string]any)["interface"].([]any)[0].(map[string]any), "interface-ref")
	b, _ := json.Marshal(d)
	r.running["leaf01"] = string(b)
	res = mustMiss(t, s, in)
	if !hasMissing(res, "leaf01", CheckACLBinding, "acl interface ethernet-1/1.990", "interface-ref/subinterface reads nothing, want 990") {
		t.Errorf("C5 not named: %s", res.Message())
	}
}
