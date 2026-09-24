package telemetry

// The register → collector agreement (T128; FR-017, FR-089):
//   - the committed deploy/observability/gnmic/subscriptions.yaml is exactly
//     GnmicSubscriptionsYAML() (golden; regenerate with -update);
//   - the gNMIc configuration scripts/lib/device_metrics.sh renders embeds that
//     section unchanged, keeps the OTLP output settings G7 recorded
//     (tests/gate/observed/telemetry-series.json), and converts to a number
//     every registered leaf the pinned YANG types as a JSON string — an
//     enumeration by an event-strings table and the conversion, a 64-bit
//     number by the conversion — since gNMIc's OTLP output drops strings
//     (pkg/register/testdata/yang-index-v25.7.1.json supplies the types).

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"os/exec"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"

	"github.com/mairp/agentic-netops-srl/pkg/register"
)

var update = flag.Bool("update", false, "regenerate "+SubscriptionsFile)

const root = "../../"

func TestGnmicSubscriptionsGolden(t *testing.T) {
	got := GnmicSubscriptionsYAML()
	if *update {
		if err := os.WriteFile(root+SubscriptionsFile, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(root + SubscriptionsFile)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Errorf("%s is not the register's rendering — regenerate: go test ./internal/telemetry -run TestGnmicSubscriptionsGolden -update", SubscriptionsFile)
	}
}

func TestParseGnmicSubscriptionsRoundTrip(t *testing.T) {
	subs, err := ParseGnmicSubscriptions(GnmicSubscriptionsYAML())
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(subs, Subscriptions()) {
		t.Errorf("round trip:\n got  %+v\n want %+v", subs, Subscriptions())
	}
	if _, err := ParseGnmicSubscriptions([]byte("subscriptions:\n  x:\n    mode: once\n")); err == nil {
		t.Error("a non-stream subscription parsed")
	}
}

type gnmicConfig struct {
	SkipVerify bool   `json:"skip-verify"`
	TLSCA      string `json:"tls-ca"`
	APIServer  struct {
		Address       string `json:"address"`
		EnableMetrics bool   `json:"enable-metrics"`
	} `json:"api-server"`
	Targets       map[string]struct{ Address string } `json:"targets"`
	Subscriptions json.RawMessage                     `json:"subscriptions"`
	Outputs       map[string]map[string]any           `json:"outputs"`
	Processors    map[string]struct {
		EventStrings *struct {
			ValueNames []string         `json:"value-names"`
			Transforms []map[string]any `json:"transforms"`
		} `json:"event-strings"`
		EventConvert *struct {
			ValueNames []string `json:"value-names"`
			Type       string   `json:"type"`
		} `json:"event-convert"`
	} `json:"processors"`
}

func renderGnmic(t *testing.T, env ...string) (gnmicConfig, string) {
	t.Helper()
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not available")
	}
	cmd := exec.Command("bash", root+"scripts/lib/device_metrics.sh", "render", "172.25.25.0/24")
	cmd.Env = append(os.Environ(), env...)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("device_metrics.sh render: %v", err)
	}
	var cm struct {
		Data map[string]string `json:"data"`
	}
	if err := yaml.Unmarshal(out, &cm); err != nil {
		t.Fatal(err)
	}
	raw := cm.Data["gnmic.yaml"]
	var cfg gnmicConfig
	if err := yaml.Unmarshal([]byte(raw), &cfg); err != nil {
		t.Fatalf("gnmic.yaml: %v", err)
	}
	return cfg, raw
}

// TestRenderedGnmicConfig: the deployed configuration carries the generated
// subscriptions unchanged, the G7 output settings, gnmic-self's api-server and
// the TLS switch.
func TestRenderedGnmicConfig(t *testing.T) {
	cfg, raw := renderGnmic(t)
	subsDoc, _ := yaml.JSONToYAML(cfg.Subscriptions)
	rendered, err := ParseGnmicSubscriptions(append([]byte("subscriptions:\n"), indent(subsDoc)...))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(rendered, Subscriptions()) {
		t.Errorf("rendered subscriptions are not the register's:\n got  %+v\n want %+v", rendered, Subscriptions())
	}
	if len(cfg.Targets) != 4 {
		t.Errorf("targets %v", cfg.Targets)
	}
	if cfg.APIServer.Address != ":7890" || !cfg.APIServer.EnableMetrics {
		t.Errorf("api-server %+v", cfg.APIServer)
	}
	if cfg.SkipVerify || cfg.TLSCA != "/etc/gnmic-tls/ca.crt" {
		t.Errorf("TLS verification is on by default: skip-verify %v tls-ca %q", cfg.SkipVerify, cfg.TLSCA)
	}
	off, _ := renderGnmic(t, "DEVICE_METRICS_TLS_VERIFY=0")
	if !off.SkipVerify || off.TLSCA != "" {
		t.Errorf("DEVICE_METRICS_TLS_VERIFY=0: skip-verify %v tls-ca %q", off.SkipVerify, off.TLSCA)
	}
	// the OTLP output exactly as G7 recorded it
	var g7 struct {
		Settings struct {
			Output map[string]any `json:"gnmic_otlp_output"`
		} `json:"settings"`
	}
	b, err := os.ReadFile(root + "tests/gate/observed/telemetry-series.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &g7); err != nil {
		t.Fatal(err)
	}
	out := cfg.Outputs["device-metrics"]
	for k, want := range g7.Settings.Output {
		if k == "event-processors" {
			continue // G7's were scratch copies of this configuration's
		}
		if !reflect.DeepEqual(out[k], want) {
			t.Errorf("output %s = %v, G7 recorded %v", k, out[k], want)
		}
	}
	// every processor defined is applied, and every applied one defined
	var applied []string
	for _, p := range out["event-processors"].([]any) {
		applied = append(applied, p.(string))
	}
	var defined []string
	for p := range cfg.Processors {
		defined = append(defined, p)
	}
	sort.Strings(defined)
	sortedApplied := append([]string(nil), applied...)
	sort.Strings(sortedApplied)
	if !reflect.DeepEqual(defined, sortedApplied) {
		t.Errorf("processors defined %v, applied %v", defined, applied)
	}
	if !strings.Contains(raw, "\nsubscriptions:\n") {
		t.Error("subscriptions section not at gnmic.yaml's top level")
	}
}

func indent(b []byte) []byte {
	var out bytes.Buffer
	for _, l := range strings.SplitAfter(string(b), "\n") {
		if l != "" {
			out.WriteString("  " + l)
		}
	}
	return out.Bytes()
}

// TestEveryRegisteredLeafIsExported: every leaf a registered path exports
// whose JSON_IETF value is a string (pinned YANG types) is converted to a
// number by the rendered processors, or gNMIc's OTLP output would drop it; an
// enumeration is first mapped by an event-strings table. A registered LEAF of
// a free-form string type is refused outright (it could never be exported); a
// free-form string beneath a registered container (last-clear) is simply not
// exported.
func TestEveryRegisteredLeafIsExported(t *testing.T) {
	cfg, _ := renderGnmic(t)
	var convert, mapped []*regexp.Regexp
	for name, p := range cfg.Processors {
		if p.EventConvert != nil {
			if p.EventConvert.Type != "int" {
				t.Errorf("processor %s converts to %s", name, p.EventConvert.Type)
			}
			for _, v := range p.EventConvert.ValueNames {
				convert = append(convert, regexp.MustCompile(v))
			}
		}
		if p.EventStrings != nil && len(p.EventStrings.Transforms) > 0 {
			for _, v := range p.EventStrings.ValueNames {
				mapped = append(mapped, regexp.MustCompile(v))
			}
		}
	}
	matches := func(res []*regexp.Regexp, v string) bool {
		for _, re := range res {
			if re.MatchString(v) {
				return true
			}
		}
		return false
	}
	b, err := os.ReadFile(root + "pkg/register/testdata/yang-index-v25.7.1.json")
	if err != nil {
		t.Fatal(err)
	}
	var idx register.YangIndex
	if err := json.Unmarshal(b, &idx); err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, e := range register.SubscribeEntries() {
		p, ok := idx.Paths[e.Path]
		if !ok {
			t.Errorf("%s not in the YANG index", e.Path)
			continue
		}
		for vp, typ := range p.LeafValuePaths() {
			if !typ.JSONString() {
				continue
			}
			closed := typ.Base == "enumeration" || typ.Base == "identityref"
			if !closed && typ.Base != "uint64" && typ.Base != "int64" && typ.Base != "decimal64" {
				// a free-form string (date-and-time, name, address)
				if p.Kind == "leaf" {
					t.Errorf("%s: a %s (%s) leaf is a string — it can never be exported", e.Path, typ.Name, typ.Base)
				}
				continue
			}
			checked++
			if closed && !matches(mapped, vp) {
				t.Errorf("%s: enumeration %s (%s) is mapped to integers by no event-strings processor", e.Path, vp, typ.Name)
			}
			if !matches(convert, vp) {
				t.Errorf("%s: %s (%s %s) is converted by no event-convert processor — gNMIc's OTLP output drops it", e.Path, vp, typ.Name, typ.Base)
			}
		}
	}
	if checked < 50 {
		t.Errorf("only %d string-encoded leaves checked", checked)
	}
	// and a conversion never reaches a date-and-time leaf
	for _, e := range register.SubscribeEntries() {
		for vp, typ := range idx.Paths[e.Path].LeafValuePaths() {
			if typ.Base == "string" && matches(convert, vp) {
				t.Errorf("%s: the string leaf %s (%s) is handed to an integer conversion", e.Path, vp, typ.Name)
			}
		}
	}
}
