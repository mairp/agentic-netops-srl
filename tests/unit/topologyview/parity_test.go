// Package topologyview_test holds the topology view to the containerlab inventory (T131; FR-094,
// FR-096, R-10, SC-036). Offline: the generator runs over the real lab/topology.clab.yml and the
// committed output of the pinned clab-io-draw over that same file
// (internal/topologyview/testdata/clab-io-draw-0.7.1, see its PROVENANCE), no docker, no cluster.
//
// Proves:
//   - NormalizeInterface maps ethernet-<s>/<p> → e<s>-<p> and nothing else, and the Prometheus
//     relabel of job `devices` (deploy/observability/prometheus/prometheus.yml) agrees with it;
//   - the fixture is clab-io-draw's output for today's inventory, by the lock file's pinned image;
//   - parity: gNMIc target list nodes == inventory devices == SVG device nodes == panel sources;
//     every inventory link is in the SVG and every device-side port in the panel, both directions,
//     normalized; every dataRef is one of the three legends over exactly `source` and
//     `interface_name`; every fabric_link_info rule is an inventory device↔device link direction;
//     the target addresses are onboarding::hosts' (one address plan);
//   - negative controls: an SVG missing a link, a target list missing a node, a target at another
//     address, a panel dataRef with the unnormalized name, a rule for a link the inventory does not
//     have, and clab-io-draw output of another inventory each fail.
package topologyview_test

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"

	tv "github.com/mairp/agentic-netops-srl/internal/topologyview"
)

const mgmtCIDR = "172.25.25.0/24"

func repoRoot(t *testing.T) string {
	t.Helper()
	_, file, _, _ := runtime.Caller(0)
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
}

func fixtureDir(t *testing.T) string {
	return filepath.Join(repoRoot(t), "internal", "topologyview", "testdata", "clab-io-draw-0.7.1")
}

func inventoryPath(t *testing.T) string {
	return filepath.Join(repoRoot(t), "lab", "topology.clab.yml")
}

// generated runs the generator over the real inventory and the fixture and returns its assets.
func generated(t *testing.T) (*tv.Inventory, tv.Assets) {
	t.Helper()
	out := t.TempDir()
	if err := tv.Generate(tv.Options{Topology: inventoryPath(t), MgmtCIDR: mgmtCIDR, DrawioDir: fixtureDir(t), OutDir: out, GeneratorRef: "fixture"}); err != nil {
		t.Fatalf("generate: %v", err)
	}
	inv, err := tv.LoadInventory(inventoryPath(t))
	if err != nil {
		t.Fatal(err)
	}
	read := func(n string) []byte {
		b, err := os.ReadFile(filepath.Join(out, n))
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	return inv, tv.Assets{Targets: read(tv.FileTargets), SVG: read(tv.FileSVG), Panel: read(tv.FilePanel), Rules: read(tv.FileRules), MgmtCIDR: mgmtCIDR}
}

func sorted(m map[string]bool) []string {
	var s []string
	for k := range m {
		s = append(s, k)
	}
	sort.Strings(s)
	return s
}

func sameSet(t *testing.T, what string, got, want map[string]bool) {
	t.Helper()
	if strings.Join(sorted(got), ",") != strings.Join(sorted(want), ",") {
		t.Errorf("%s: got %v, want %v", what, sorted(got), sorted(want))
	}
}

var normalizeCases = []struct{ in, want string }{
	{"ethernet-1/49", "e1-49"},
	{"ethernet-1/50", "e1-50"},
	{"ethernet-1/1", "e1-1"},
	{"ethernet-2/10", "e2-10"},
	{"e1-49", "e1-49"},
	{"mgmt0", "mgmt0"},
	{"system0", "system0"},
	{"irb0", "irb0"},
	{"lo0", "lo0"},
	{"eth1", "eth1"},
	{"ethernet-1/1.0", "ethernet-1/1.0"}, // a subinterface name is not an interface name
	{"", ""},
}

func TestNormalizeInterface(t *testing.T) {
	for _, c := range normalizeCases {
		if got := tv.NormalizeInterface(c.in); got != c.want {
			t.Errorf("NormalizeInterface(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// The Prometheus relabel of job `devices` is the scrape-side half of the same normalization:
// Prometheus anchors the regex (^(?:…)$) and expands ${n} in the replacement.
func TestPrometheusRelabelAgrees(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(repoRoot(t), "deploy", "observability", "prometheus", "prometheus.yml"))
	if err != nil {
		t.Fatalf("prometheus.yml: %v", err)
	}
	var cfg struct {
		ScrapeConfigs []struct {
			JobName        string `json:"job_name"`
			MetricRelabels []struct {
				SourceLabels []string `json:"source_labels"`
				Regex        string   `json:"regex"`
				TargetLabel  string   `json:"target_label"`
				Replacement  string   `json:"replacement"`
				Action       string   `json:"action"`
			} `json:"metric_relabel_configs"`
		} `json:"scrape_configs"`
	}
	if err := yaml.Unmarshal(b, &cfg); err != nil {
		t.Fatal(err)
	}
	found := 0
	for _, sc := range cfg.ScrapeConfigs {
		for _, r := range sc.MetricRelabels {
			if r.TargetLabel != "interface_name" {
				continue
			}
			if sc.JobName != "devices" {
				t.Errorf("job %s rewrites interface_name; only job devices may", sc.JobName)
			}
			found++
			if r.Regex != tv.InterfaceRelabelRegex || r.Replacement != tv.InterfaceRelabelReplacement {
				t.Errorf("relabel regex/replacement %q/%q, topologyview uses %q/%q", r.Regex, r.Replacement, tv.InterfaceRelabelRegex, tv.InterfaceRelabelReplacement)
			}
			re := regexp.MustCompile("^(?:" + r.Regex + ")$")
			for _, c := range normalizeCases {
				got := c.in
				if m := re.FindStringSubmatchIndex(c.in); m != nil {
					got = string(re.ExpandString(nil, r.Replacement, c.in, m))
				}
				if got != c.want {
					t.Errorf("relabel(%q) = %q, NormalizeInterface gives %q", c.in, got, c.want)
				}
			}
		}
	}
	if found != 1 {
		t.Errorf("want exactly one interface_name relabel (job devices), found %d", found)
	}
}

func TestFixtureProvenance(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(fixtureDir(t), "PROVENANCE"))
	if err != nil {
		t.Fatal(err)
	}
	inv, err := tv.LoadInventory(inventoryPath(t))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "inventory: lab/topology.clab.yml sha256:"+inv.Digest) {
		t.Errorf("fixture was generated from another lab/topology.clab.yml than today's (sha256:%s) — regenerate it as its PROVENANCE says", inv.Digest)
	}
	lock, err := os.ReadFile(filepath.Join(repoRoot(t), "versions.lock.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var l struct {
		Observability struct {
			TopologyGenerator struct {
				Tag    string `json:"tag"`
				Pinned string `json:"pinned"`
			} `json:"topologyGenerator"`
		} `json:"observability"`
	}
	if err := yaml.Unmarshal(lock, &l); err != nil {
		t.Fatal(err)
	}
	ref := l.Observability.TopologyGenerator.Pinned
	if ref == "" || !strings.Contains(ref, "@sha256:") || l.Observability.TopologyGenerator.Tag == "latest" {
		t.Fatalf("lock pins the topology generator as %q", ref)
	}
	if !strings.Contains(string(b), "generator: "+ref+"\n") {
		t.Errorf("fixture PROVENANCE does not name the lock's pinned generator %s", ref)
	}
	// the dashboard clab-io-draw emitted builds dataRefs from exactly the two join labels
	var dash struct {
		Panels []struct {
			Targets []struct {
				LegendFormat string `json:"legendFormat"`
			} `json:"targets"`
		} `json:"panels"`
	}
	db, err := os.ReadFile(filepath.Join(fixtureDir(t), "topology.clab.grafana.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(db, &dash); err != nil {
		t.Fatal(err)
	}
	legends := map[string]bool{}
	for _, p := range dash.Panels {
		for _, tg := range p.Targets {
			legends[tg.LegendFormat] = true
		}
	}
	sameSet(t, "clab-io-draw legend formats", legends, map[string]bool{tv.LegendOperState: true, tv.LegendOut: true, tv.LegendIn: true})
	for l := range legends {
		labels := regexp.MustCompile(`\{\{(\w+)\}\}`).FindAllStringSubmatch(l, -1)
		if len(labels) != 2 || labels[0][1] != "source" || labels[1][1] != "interface_name" {
			t.Errorf("legend %q is not built from exactly source and interface_name", l)
		}
	}
}

func TestParity(t *testing.T) {
	inv, a := generated(t)
	if err := tv.Parity(inv, a); err != nil {
		t.Fatalf("parity: %v", err)
	}

	devices := map[string]bool{}
	nodes := map[string]bool{}
	for _, n := range inv.Nodes {
		nodes[n.Name] = true
		if n.Device() {
			devices[n.Name] = true
		}
	}
	sameSet(t, "inventory devices", devices, map[string]bool{"spine01": true, "spine02": true, "leaf01": true, "leaf02": true})

	// target list
	ts, err := tv.ParseTargets(a.Targets)
	if err != nil {
		t.Fatal(err)
	}
	targetNodes := map[string]bool{}
	for _, tg := range ts {
		targetNodes[tg.Name] = true
	}
	sameSet(t, "gNMIc targets vs devices", targetNodes, devices)

	// SVG
	ids := map[string]bool{}
	for _, m := range regexp.MustCompile(`id="cell-([^"]+)"`).FindAllStringSubmatch(string(a.SVG), -1) {
		ids[m[1]] = true
	}
	svgDevices, svgNodes := map[string]bool{}, map[string]bool{}
	for id := range ids {
		if !strings.Contains(id, ":") {
			svgNodes[id] = true
			if devices[id] {
				svgDevices[id] = true
			}
		}
		if strings.Contains(id, "ethernet-") || strings.Contains(id, "clab-") {
			t.Errorf("svg cell %q is not on the join (raw interface or container name)", id)
		}
	}
	sameSet(t, "svg device nodes vs devices", svgDevices, devices)
	sameSet(t, "svg nodes vs inventory nodes", svgNodes, nodes)

	// panel
	_, cells, err := tv.ParsePanel(a.Panel)
	if err != nil {
		t.Fatal(err)
	}
	panelKeys, panelSources := map[string]bool{}, map[string]bool{}
	dataRef := regexp.MustCompile(`^(?:oper-state:([a-z0-9]+):(e\d+-\d+)|([a-z0-9]+):(e\d+-\d+):(?:out|in))$`)
	for _, c := range cells {
		panelKeys[c.Key] = true
		m := dataRef.FindStringSubmatch(c.DataRef)
		if m == nil {
			t.Errorf("panel cell %q dataRef %q is not <source>:<e1-N> from the legends", c.Key, c.DataRef)
			continue
		}
		panelSources[m[1]+m[3]] = true
	}
	sameSet(t, "panel sources vs devices", panelSources, devices)

	// every device↔device link, both directions, normalized
	fabric := inv.FabricLinks()
	if len(fabric) != 8 {
		t.Fatalf("want 8 fabric link directions (4 links), got %d", len(fabric))
	}
	for _, l := range fabric {
		for _, key := range []string{l.CellKey(), "link_id:" + l.CellKey()} {
			if !ids[key] {
				t.Errorf("svg lacks %q", key)
			}
			if !panelKeys[key] {
				t.Errorf("panel lacks %q", key)
			}
		}
	}
	for _, want := range []string{"leaf01:e1-49:spine01:e1-1", "spine01:e1-1:leaf01:e1-49", "link_id:leaf02:e1-50:spine02:e1-2", "link_id:spine02:e1-2:leaf02:e1-50"} {
		if !panelKeys[want] || !ids[want] {
			t.Errorf("cell %q missing (panel %v, svg %v)", want, panelKeys[want], ids[want])
		}
	}

	// rules: every fabric_link_info is an inventory link direction, one per direction
	rules, err := tv.ParseRules(a.Rules)
	if err != nil {
		t.Fatal(err)
	}
	invLinks := map[string]bool{}
	for _, l := range fabric {
		invLinks[l.CellKey()] = true
	}
	ruleLinks := map[string]bool{}
	nodeInfo := map[string]bool{}
	for _, r := range rules {
		switch r.Record {
		case tv.FabricLinkSeries:
			k := r.Labels["source"] + ":" + r.Labels["interface_name"] + ":" + r.Labels["peer_source"] + ":" + r.Labels["peer_interface"]
			if !invLinks[k] {
				t.Errorf("fabric_link_info %v is not an inventory fabric link", r.Labels)
			}
			ruleLinks[k] = true
		case tv.NodeInfoSeries:
			nodeInfo[r.Labels["source"]+"="+r.Labels["role"]] = true
		}
		if r.Group != "agentic-netops-topology" {
			t.Errorf("rule group %q", r.Group)
		}
	}
	sameSet(t, "fabric_link_info vs inventory fabric links", ruleLinks, invLinks)
	sameSet(t, "node_info", nodeInfo, map[string]bool{"spine01=spine": true, "spine02=spine": true, "leaf01=leaf": true, "leaf02=leaf": true, "client01=client": true, "client02=client": true})
}

// The target list and the onboarding (DiscoveryRule, device_metrics) use one address plan.
func TestTargetsMatchOnboarding(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 (onboarding::hosts) not available")
	}
	_, a := generated(t)
	for _, cidr := range []string{mgmtCIDR, "10.99.0.0/24"} {
		cmd := exec.Command("bash", "-c", `source scripts/lib/onboarding.sh && onboarding::hosts "$1"`, "_", cidr)
		cmd.Dir = repoRoot(t)
		want, err := cmd.Output()
		if err != nil {
			t.Fatalf("onboarding::hosts %s: %v", cidr, err)
		}
		got := a.Targets
		if cidr != mgmtCIDR {
			inv, _ := tv.LoadInventory(inventoryPath(t))
			ts, err := tv.Targets(inv, cidr)
			if err != nil {
				t.Fatal(err)
			}
			got = tv.FormatTargets(ts)
		}
		if string(got) != string(want) {
			t.Errorf("MGMT_CIDR %s: targets\n%s\nonboarding::hosts\n%s", cidr, got, want)
		}
	}
}

func TestCanonicalID(t *testing.T) {
	inv, err := tv.LoadInventory(inventoryPath(t))
	if err != nil {
		t.Fatal(err)
	}
	for in, want := range map[string]string{
		"clab-agentic-netops-fabric-leaf01":        "leaf01",
		"group-clab-agentic-netops-fabric-spine02": "group-spine02",
		"link_id:clab-agentic-netops-fabric-leaf01:ethernet-1/49:clab-agentic-netops-fabric-spine01:ethernet-1/1": "link_id:leaf01:e1-49:spine01:e1-1",
		"mid:clab-agentic-netops-fabric-client01:eth1:clab-agentic-netops-fabric-leaf01:e1-1":                     "mid:client01:eth1:leaf01:e1-1",
		"oper-state:clab-agentic-netops-fabric-spine01:e1-2":                                                      "oper-state:spine01:e1-2",
	} {
		if got := inv.CanonicalID(in); got != want {
			t.Errorf("CanonicalID(%q) = %q, want %q", in, got, want)
		}
	}
}

// Negative controls: each mutation must make Parity fail, naming what is wrong.
func TestParityNegativeControls(t *testing.T) {
	inv, good := generated(t)
	cases := []struct {
		name   string
		mutate func(a *tv.Assets)
		want   string
	}{
		{"svg missing a link direction", func(a *tv.Assets) {
			a.SVG = regexp.MustCompile(`(?s)<g id="cell-link_id:leaf01:e1-49:spine01:e1-1">.*?</g>\n`).ReplaceAll(a.SVG, nil)
		}, `missing cell "cell-link_id:leaf01:e1-49:spine01:e1-1"`},
		{"svg missing a node", func(a *tv.Assets) {
			a.SVG = []byte(strings.Replace(string(a.SVG), `id="cell-spine02"`, `id="spine02"`, 1))
		}, "svg nodes vs inventory nodes: missing [spine02]"},
		{"target list missing a node", func(a *tv.Assets) {
			a.Targets = []byte(strings.Replace(string(a.Targets), "leaf02 172.25.25.22\n", "", 1))
		}, "targets vs inventory devices: missing [leaf02]"},
		{"target list with a client", func(a *tv.Assets) {
			a.Targets = append(a.Targets, []byte("client01 172.25.25.31\n")...)
		}, "targets vs inventory devices: extra [client01]"},
		{"target at another address", func(a *tv.Assets) {
			a.Targets = []byte(strings.Replace(string(a.Targets), "172.25.25.21", "172.25.25.99", 1))
		}, "leaf01 at 172.25.25.99"},
		{"panel dataRef not normalized", func(a *tv.Assets) {
			a.Panel = []byte(strings.Replace(string(a.Panel), "dataRef: oper-state:spine01:e1-1\n", "dataRef: oper-state:spine01:ethernet-1/1\n", 1))
		}, "is not normalized"},
		{"panel dataRef with a third label", func(a *tv.Assets) {
			a.Panel = []byte(strings.Replace(string(a.Panel), "dataRef: spine01:e1-1:out\n", "dataRef: spine01:e1-1:default:out\n", 1))
		}, "is not one of"},
		{"panel missing a link direction", func(a *tv.Assets) {
			a.Panel = regexp.MustCompile(`(?m)^  link_id:spine02:e1-2:leaf02:e1-50:\n(?:    .*\n|      .*\n)*`).ReplaceAll(a.Panel, nil)
		}, `missing cell "link_id:spine02:e1-2:leaf02:e1-50"`},
		{"rule for a link the inventory lacks", func(a *tv.Assets) {
			a.Rules = append(a.Rules, []byte("      - record: agentic_netops_fabric_link_info\n        expr: vector(1)\n        labels: {source: \"leaf01\", interface_name: \"e1-51\", peer_source: \"spine01\", peer_interface: \"e1-9\"}\n")...)
		}, "fabric_link_info vs inventory fabric links: extra"},
		{"rule missing a direction", func(a *tv.Assets) {
			a.Rules = []byte(strings.Replace(string(a.Rules), "      - record: agentic_netops_fabric_link_info\n        expr: vector(1)\n        labels: {source: \"spine01\", interface_name: \"e1-1\", peer_source: \"leaf01\", peer_interface: \"e1-49\"}\n", "", 1))
		}, "fabric_link_info vs inventory fabric links: missing [spine01:e1-1:leaf01:e1-49]"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a := good
			a.Targets, a.SVG, a.Panel, a.Rules = append([]byte(nil), good.Targets...), append([]byte(nil), good.SVG...), append([]byte(nil), good.Panel...), append([]byte(nil), good.Rules...)
			c.mutate(&a)
			if string(a.Targets) == string(good.Targets) && string(a.SVG) == string(good.SVG) && string(a.Panel) == string(good.Panel) && string(a.Rules) == string(good.Rules) {
				t.Fatal("mutation did not apply")
			}
			err := tv.Parity(inv, a)
			if err == nil {
				t.Fatal("parity passed on a mutated asset")
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Errorf("parity error does not name %q:\n%v", c.want, err)
			}
		})
	}
}

// clab-io-draw output of one inventory never passes for another: a link moved in the inventory
// makes Generate refuse and write nothing.
func TestGenerateRefusesAnotherInventory(t *testing.T) {
	b, err := os.ReadFile(inventoryPath(t))
	if err != nil {
		t.Fatal(err)
	}
	moved := strings.Replace(string(b), `["leaf02:ethernet-1/50", "spine02:ethernet-1/2"]`, `["leaf02:ethernet-1/51", "spine02:ethernet-1/2"]`, 1)
	if moved == string(b) {
		t.Fatal("inventory mutation did not apply")
	}
	dir := t.TempDir()
	topo := filepath.Join(dir, "topology.clab.yml")
	if err := os.WriteFile(topo, []byte(moved), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "out")
	err = tv.Generate(tv.Options{Topology: topo, MgmtCIDR: mgmtCIDR, DrawioDir: fixtureDir(t), OutDir: out})
	if err == nil || !strings.Contains(err.Error(), "leaf02:e1-51") {
		t.Fatalf("generate over a changed inventory: %v", err)
	}
	if _, serr := os.Stat(out); !os.IsNotExist(serr) {
		t.Errorf("generate wrote %s despite the mismatch", out)
	}
}
