package register

// The subscription side of the path-register guard (T022, completed by T128;
// FR-017, FR-089, R-09). Offline: it reads the committed YANG index of the
// pinned models (testdata/yang-index-v25.7.1.json, `go run ./hack/yangindex`)
// and the committed live-series observation, never the network.
//
//   - every subscribed path is in the pinned models, and the index is the one
//     of the commit versions.lock.yaml pins;
//   - the recorded metric name is the one derived from the schema (module
//     qualification per RFC 7951), and equals the live name wherever the
//     series was observed;
//   - the label set is closed (exactly the path-derived labels, then the
//     pipeline's) and bounded (every label's bound admits its key's class);
//   - no two subscribed paths overlap; at most three streams; the read-back's
//     paths are all kept, every 5 s;
//   - negative controls: each rule refuses a fixture that breaks it.

import (
	"bufio"
	"encoding/json"
	"os"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"
)

const yangIndexFile = "testdata/yang-index-v25.7.1.json"

func loadIndex(t *testing.T) *YangIndex {
	t.Helper()
	b, err := os.ReadFile(yangIndexFile)
	if err != nil {
		t.Fatal(err)
	}
	var idx YangIndex
	if err := json.Unmarshal(b, &idx); err != nil {
		t.Fatal(err)
	}
	if idx.Schema != YangIndexSchema {
		t.Fatalf("%s: schema %q", yangIndexFile, idx.Schema)
	}
	return &idx
}

// TestYangIndexIsThePinnedCommit: the index was generated from exactly the
// models versions.lock.yaml pins (part 2) — a re-pin fails here until the index
// is regenerated and the register re-validated against it.
func TestYangIndexIsThePinnedCommit(t *testing.T) {
	idx := loadIndex(t)
	f, err := os.Open("../../versions.lock.yaml")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	lock := map[string]string{}
	in := false
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		l := sc.Text()
		switch {
		case strings.HasPrefix(l, "  yangModels:"):
			in = true
		case in && strings.HasPrefix(l, "  ") && !strings.HasPrefix(l, "    "):
			in = false
		case in:
			if k, v, ok := strings.Cut(strings.TrimSpace(l), ":"); ok {
				lock[k] = strings.TrimSpace(v)
			}
		}
	}
	if lock["commit"] == "" || idx.Commit != lock["commit"] || idx.Tag != lock["tag"] || idx.Repository != lock["repository"] {
		t.Errorf("index %s %s@%s, lock pins %s %s@%s — regenerate: go run ./hack/yangindex -models <checkout>",
			idx.Repository, idx.Tag, idx.Commit, lock["repository"], lock["tag"], lock["commit"])
	}
}

// TestSubscribeRegisterMatchesPinnedYANG: every entry resolves in the pinned
// models with its derived metric name and a closed, bounded label set; the
// index carries no path the register dropped.
func TestSubscribeRegisterMatchesPinnedYANG(t *testing.T) {
	idx := loadIndex(t)
	for _, e := range CheckIndex(SubscribeEntries(), idx) {
		t.Error(e)
	}
	reg := map[string]bool{}
	for _, e := range SubscribeEntries() {
		reg[e.Path] = true
	}
	for p := range idx.Paths {
		if !reg[p] {
			t.Errorf("index path %s is not registered — regenerate the index", p)
		}
	}
}

// TestSubscribeNamesAreTheLiveNames: every series observed live (2026-09-24)
// is a registered metric — a leaf's name or a container's leaf beneath — with
// exactly the registered label set (plus the collector's scope labels), so the
// derivation rule is the one the pipeline applies, not an assumption.
func TestSubscribeNamesAreTheLiveNames(t *testing.T) {
	idx := loadIndex(t)
	byMetric := map[string]SubscribeEntry{}
	for _, e := range SubscribeEntries() {
		p := idx.Paths[e.Path]
		for vp := range p.LeafValuePaths() {
			byMetric[MetricFromValuePath(vp)] = e
		}
	}
	f, err := os.Open("testdata/live-series-2026-09-24.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	n := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		name, labels, _ := strings.Cut(line, " ")
		n++
		e, ok := byMetric[name]
		if !ok {
			t.Errorf("live series %s is no registered metric", name)
			continue
		}
		want := append(e.LabelNames(), ScopeLabels...)
		sort.Strings(want)
		if got := strings.Split(labels, ","); !slices.Equal(got, want) {
			t.Errorf("live series %s labels %v, registered %v", name, got, want)
		}
	}
	if n < 25 {
		t.Fatalf("only %d live series read", n)
	}
}

// readBackPaths are the paths the provider's read-back reads from the
// collector (the former scripts/lib/device_metrics.sh DEVICE_METRICS_PATHS,
// T039/T058/T108/T116): each stays subscribed, every 5 s.
var readBackPaths = []string{
	"/interface[name=*]/oper-state",
	"/interface[name=*]/subinterface[index=*]/oper-state",
	"/interface[name=*]/subinterface[index=*]/oper-down-reason",
	"/tunnel-interface[name=*]/vxlan-interface[index=*]/oper-state",
	"/tunnel-interface[name=*]/vxlan-interface[index=*]/oper-down-reason",
	"/tunnel-interface[name=*]/vxlan-interface[index=*]/bridge-table/multicast-destinations/destination[vtep=*][vni=*]/destination-index",
	"/tunnel-interface[name=*]/vxlan-interface[index=*]/bridge-table/multicast-destinations/destination[vtep=*][vni=*]/not-programmed-reason",
	"/tunnel/vxlan-tunnel/vtep[address=*]/index",
	"/network-instance[name=*]/oper-state",
	"/network-instance[name=*]/oper-down-reason",
	"/network-instance[name=*]/interface[name=*]/oper-state",
	"/network-instance[name=*]/interface[name=*]/oper-down-reason",
	"/network-instance[name=*]/vxlan-interface[name=*]/oper-state",
	"/network-instance[name=*]/vxlan-interface[name=*]/oper-down-reason",
	"/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/session-state",
	"/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=*]/oper-state",
	"/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=*]/received-routes",
	"/network-instance[name=*]/route-table/ipv4-unicast/route/active",
	"/network-instance[name=*]/route-table/ipv6-unicast/route/active",
	"/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/evi",
	"/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/oper-state",
	"/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/oper-down-reason",
	"/network-instance[name=*]/protocols/bgp-vpn/bgp-instance[id=*]/route-distinguisher/route-distinguisher-origin",
	"/network-instance[name=*]/protocols/bgp-vpn/bgp-instance[id=*]/route-target/export-route-target-origin",
	"/network-instance[name=*]/protocols/bgp-vpn/bgp-instance[id=*]/route-target/import-route-target-origin",
	"/acl/datapath-programming/forwarding-complex[slot-id=*][complex-id=*]/programming-complete",
	"/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/tcam-entries/forwarding-complex[complex-identifier=*]/single-instance",
	"/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/tcam-entries/forwarding-complex[complex-identifier=*]/input-total",
	"/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/tcam-entries/forwarding-complex[complex-identifier=*]/output-total",
	"/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/statistics/matched-packets",
	"/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/statistics/incomplete",
	"/interface[name=*]/subinterface[index=*]/anycast-gw/anycast-gw-mac-origin",
	"/interface[name=*]/subinterface[index=*]/ipv4/address[ip-prefix=*]/status",
	"/interface[name=*]/subinterface[index=*]/ipv6/address[ip-prefix=*]/status",
	"/network-instance[name=default]/bgp-rib/afi-safi[afi-safi-name=evpn]/evpn/rib-in-out/rib-in-post/ip-prefix-route[route-distinguisher=*][ethernet-tag-id=*][ip-prefix-length=*][ip-prefix=*][neighbor=*][path-id=*]/used-route",
}

func TestSubscribeReadBackPathsKept(t *testing.T) {
	reg := map[string]SubscribeEntry{}
	for _, e := range SubscribeEntries() {
		reg[e.Path] = e
	}
	for _, p := range readBackPaths {
		e, ok := reg[p]
		switch {
		case !ok:
			t.Errorf("read-back path %s is no longer subscribed", p)
		case !e.ReadBack || e.Subscription != SubState || e.SampleInterval != 5*time.Second || e.Mode != Sample:
			t.Errorf("read-back path %s: %s %s/%s readBack=%v, want %s sample/5s", p, e.Subscription, e.Mode, e.SampleInterval, e.ReadBack, SubState)
		}
	}
	for _, e := range SubscribeEntries() {
		if e.ReadBack && !slices.Contains(readBackPaths, e.Path) {
			t.Errorf("%s is marked read-back but is not a read-back path", e.Path)
		}
	}
}

// TestSubscribeStreams: at most three streams, on-change nowhere (G7 observed
// sampled streams only).
func TestSubscribeStreams(t *testing.T) {
	subs := Subscriptions()
	if len(subs) > MaxSubscriptions {
		t.Errorf("%d subscriptions", len(subs))
	}
	for _, s := range subs {
		if s.Mode != Sample {
			t.Errorf("%s: %s — on-change only where G7 covers it, none does", s.Name, s.Mode)
		}
	}
}

// --- negative controls: the subscription guard refuses what it must ---

func entryFor(t *testing.T, path string) SubscribeEntry {
	t.Helper()
	for _, e := range SubscribeEntries() {
		if e.Path == path {
			e.Labels = append([]Label(nil), e.Labels...)
			return e
		}
	}
	t.Fatalf("no entry %s", path)
	return SubscribeEntry{}
}

func wantErr(t *testing.T, what string, errs []string, sub string) {
	t.Helper()
	for _, e := range errs {
		if strings.Contains(e, sub) {
			return
		}
	}
	t.Errorf("%s passed the guard (want an error containing %q; got %v)", what, sub, errs)
}

func TestGuardRefusesUnlistedLabel(t *testing.T) {
	idx := loadIndex(t)
	// a path-derived label the entry does not name (subinterface_index dropped)
	e := entryFor(t, "/interface[name=*]/subinterface[index=*]/oper-state")
	e.Labels = slices.DeleteFunc(e.Labels, func(l Label) bool { return l.Name == "subinterface_index" })
	wantErr(t, "an entry with an unlisted label", CheckIndex([]SubscribeEntry{e}, idx), "not the closed derived set")
	// a label the path does not derive
	e = entryFor(t, "/interface[name=*]/oper-state")
	e.Labels = append([]Label{{"interface_description", BoundInventory}}, e.Labels...)
	wantErr(t, "an entry with an extra label", CheckIndex([]SubscribeEntry{e}, idx), "not the closed derived set")
	// a list the path names without keys still yields its key labels (route)
	e = entryFor(t, "/network-instance[name=*]/route-table/ipv4-unicast/route/active")
	e.Labels = append(e.Labels[:1:1], PipelineLabels...)
	wantErr(t, "a keyless list with its key labels unlisted", CheckIndex([]SubscribeEntry{e}, idx), "not the closed derived set")
}

func TestGuardRefusesUnboundedLabel(t *testing.T) {
	idx := loadIndex(t)
	// an address prefix claimed as lab inventory: inventory never admits a prefix
	e := entryFor(t, "/interface[name=*]/subinterface[index=*]/ipv4/address[ip-prefix=*]/status")
	for i := range e.Labels {
		if e.Labels[i].Name == "address_ip_prefix" {
			e.Labels[i].Bound = BoundInventory
		}
	}
	wantErr(t, "a prefix label without a route/intent bound", CheckIndex([]SubscribeEntry{e}, idx), "is unbounded")
	// a free-form route prefix claimed closed by the schema
	e = entryFor(t, "/network-instance[name=*]/route-table/ipv4-unicast/route/active")
	for i := range e.Labels {
		if e.Labels[i].Name == "route_ipv4_prefix" {
			e.Labels[i].Bound = BoundSchema
		}
	}
	wantErr(t, "a route prefix claimed schema-bounded", CheckIndex([]SubscribeEntry{e}, idx), "is unbounded")
	// a label with no bound at all, and one outside the closed set
	e = entryFor(t, "/interface[name=*]/oper-state")
	e.Labels[0].Bound = ""
	wantErr(t, "a label without a bound", validateSubscribe([]SubscribeEntry{e}), "is not one of")
	wantErr(t, "a label without a bound (index)", CheckIndex([]SubscribeEntry{e}, idx), "is unbounded")
	e.Labels[0].Bound = "trust-me"
	wantErr(t, "a label with an unknown bound", validateSubscribe([]SubscribeEntry{e}), "is not one of")
	// a path label claiming the pipeline bound
	e.Labels[0].Bound = BoundPipeline
	wantErr(t, "a path label with the pipeline bound", validateSubscribe([]SubscribeEntry{e}), "claims the pipeline bound")
}

func TestGuardRefusesOverlap(t *testing.T) {
	// the FR-089 container over the read-back's leaves: every matched-packets
	// series would be exported twice (DuplicateDeviceSeries)
	container := entryFor(t, "/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/statistics/matched-packets")
	container.Path = "/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/statistics"
	container.Subscription = SubCounters
	container.SampleInterval = 10 * time.Second
	container.ReadBack = false
	wantErr(t, "a container over a registered leaf", validateSubscribe(append(SubscribeEntries(), container)), "overlap")
	// a wildcard and a fixed key select the same default instance
	if !Overlaps("/network-instance[name=*]/protocols/bgp/neighbor[peer-address=*]/session-state",
		"/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/session-state") {
		t.Error("[name=*] and [name=default] do not overlap")
	}
	// the same path twice
	wantErr(t, "a duplicate path", validateSubscribe(append(SubscribeEntries(), entryFor(t, "/interface[name=*]/oper-state"))), "duplicate")
	// disjoint: two fixed values, and siblings
	if Overlaps("/network-instance[name=default]/oper-state", "/network-instance[name=mgmt]/oper-state") ||
		Overlaps("/interface[name=*]/oper-state", "/interface[name=*]/admin-state") {
		t.Error("disjoint paths reported as overlapping")
	}
}

func TestGuardRefusesStreamShape(t *testing.T) {
	es := SubscribeEntries()
	extra := entryFor(t, "/interface[name=*]/admin-state")
	extra.Path = "/interface[name=*]/description"
	extra.Subscription = "device-fourth"
	wantErr(t, "a fourth subscription", validateSubscribe(append(es, extra)), "at most 3")
	slowRB := entryFor(t, "/interface[name=*]/oper-state")
	slowRB.SampleInterval = 10 * time.Second
	wantErr(t, "a read-back path at 10 s", validateSubscribe([]SubscribeEntry{slowRB}), "metric_expiration")
	mixed := entryFor(t, "/interface[name=*]/admin-state")
	mixed.Path = "/interface[name=*]/description"
	mixed.SampleInterval = 10 * time.Second
	wantErr(t, "a subscription with two intervals", validateSubscribe(append(es, mixed)), "mixes")
}

func TestGuardRefusesPathNotInPinnedModels(t *testing.T) {
	idx := loadIndex(t)
	e := entryFor(t, "/interface[name=*]/oper-state")
	e.Path = "/interface[name=*]/advertised-routes"
	wantErr(t, "a path the pinned models lack", CheckIndex([]SubscribeEntry{e}, idx), "not in the YANG index")
	// a wrong metric name
	e = entryFor(t, "/interface[name=*]/oper-state")
	e.Metric = "interface_oper_state" // unqualified: what the pre-T128 register assumed
	wantErr(t, "an unqualified metric name", CheckIndex([]SubscribeEntry{e}, idx), "is not the derived")
	// a container holding a list
	p := idx.Paths["/interface[name=*]/statistics"]
	p.Lists = []string{"mac-type"}
	fake := &YangIndex{Tag: idx.Tag, Commit: idx.Commit, Paths: map[string]IndexedPath{"/interface[name=*]/statistics": p}}
	wantErr(t, "a container holding a list", CheckIndex([]SubscribeEntry{entryFor(t, "/interface[name=*]/statistics")}, fake), "holds the list")
}

func TestKeyClass(t *testing.T) {
	for _, c := range []struct {
		t    YangType
		want KeyClass
	}{
		{YangType{Name: "enumeration", Base: "enumeration"}, ClassClosed},
		{YangType{Name: "identityref", Base: "identityref"}, ClassClosed},
		{YangType{Name: "ip-prefix", Base: "union", Members: []YangType{{Name: "ipv4-prefix", Base: "string"}, {Name: "ipv6-prefix", Base: "string"}}}, ClassPrefix},
		{YangType{Name: "ip-address", Base: "union", Members: []YangType{{Name: "ipv4-address", Base: "string"}}}, ClassAddress},
		{YangType{Name: "uint32", Base: "uint32"}, ClassNumber},
		{YangType{Name: "name", Base: "string"}, ClassText},
	} {
		if got := c.t.Class(); got != c.want {
			t.Errorf("%+v: %s, want %s", c.t, got, c.want)
		}
	}
}
