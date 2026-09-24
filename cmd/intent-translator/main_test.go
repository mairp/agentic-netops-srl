package main

// T097: the sidecar is the translator package behind HTTP and nothing else — the same bytes as the
// package (and so as the CLI), 200/422/400 per contracts/translator-api.md, NFR-014 log lines, and no
// cluster client anywhere in the binary's imports.

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/telemetry/jsonlog"
	"github.com/mairp/agentic-netops-srl/pkg/migration"
)

const testdata = "../../tests/unit/testdata/migration"

func labOptions(t *testing.T) migration.Options {
	t.Helper()
	o, err := migration.ParseOptions(`{"leaf01":"leaf","leaf02":"leaf","spine01":"spine","spine02":"spine"}`,
		`{"leaf01":["ethernet-1/1"],"leaf02":["ethernet-1/1"],"spine01":[],"spine02":[]}`, "65000")
	if err != nil {
		t.Fatal(err)
	}
	return o
}

func server(t *testing.T, logs *bytes.Buffer) *httptest.Server {
	t.Helper()
	s := httptest.NewServer(newHandler(labOptions(t), jsonlog.NewLogger(logs, component, false, nil)))
	t.Cleanup(s.Close)
	return s
}

func post(t *testing.T, s *httptest.Server, body []byte) (int, []byte) {
	t.Helper()
	resp, err := http.Post(s.URL+"/v1/translate", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var b bytes.Buffer
	_, _ = b.ReadFrom(resp.Body)
	if ct := resp.Header.Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type %q", ct)
	}
	return resp.StatusCode, b.Bytes()
}

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(testdata, name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestTranslate200IsThePackagesOutput(t *testing.T) {
	var logs bytes.Buffer
	s := server(t, &logs)
	for _, c := range []string{"vlan", "macvrf", "ipvrf", "macvrf_allocated_vlan"} {
		in := fixture(t, "construct_"+c+".json")
		code, body := post(t, s, in)
		if code != http.StatusOK {
			t.Fatalf("%s: status %d: %s", c, code, body)
		}
		var resp struct {
			Manifests []json.RawMessage `json:"manifests"`
			YAML      string            `json:"yaml"`
		}
		dec := json.NewDecoder(bytes.NewReader(body))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&resp); err != nil {
			t.Fatal(err)
		}
		want, err := migration.TranslateJSON(in, labOptions(t))
		if err != nil {
			t.Fatal(err)
		}
		if resp.YAML != want.YAML {
			t.Errorf("%s: the sidecar's yaml differs from the package's", c)
		}
		if len(resp.Manifests) != 1 || !bytes.Equal(resp.Manifests[0], want.Manifests[0].JSON()) {
			t.Errorf("%s: manifests %s", c, resp.Manifests)
		}
		var n fabricv1.Network
		d := json.NewDecoder(bytes.NewReader(resp.Manifests[0]))
		d.DisallowUnknownFields()
		if err := d.Decode(&n); err != nil || n.Kind != "Network" || n.APIVersion != "fabric.agentic-netops.io/v1alpha1" {
			t.Errorf("%s: manifest does not decode strictly into fabricv1.Network: %v", c, err)
		}
		if c != "macvrf_allocated_vlan" {
			golden := fixture(t, "construct_"+c+".spec.golden.yaml")
			if !strings.HasSuffix(resp.YAML, string(golden)) {
				t.Errorf("%s: the yaml's spec block is not the golden", c)
			}
		}
	}
	// a batch: one manifest per service, in order
	code, body := post(t, s, []byte("["+string(fixture(t, "construct_vlan.json"))+","+string(fixture(t, "construct_ipvrf.json"))+"]"))
	var resp struct {
		Manifests []struct {
			Metadata struct{ Name string } `json:"metadata"`
		} `json:"manifests"`
	}
	_ = json.Unmarshal(body, &resp)
	if code != 200 || len(resp.Manifests) != 2 || resp.Manifests[0].Metadata.Name != "migr-1a2b3c4d5e6f701" || resp.Manifests[1].Metadata.Name != "migr-9c3d5e7f1a2b4c6" {
		t.Errorf("batch: %d %s", code, body)
	}
	assertLogLines(t, &logs)
}

func TestTranslate422And400(t *testing.T) {
	var logs bytes.Buffer
	s := server(t, &logs)
	for _, f := range []string{"refuse_unsupported_te.json", "refuse_malformed_unknown_field.json", "refuse_node_port_vlan_taken.json", "refuse_unknown_node.json"} {
		code, body := post(t, s, fixture(t, f))
		var e migration.StructuredError
		if err := json.Unmarshal(body, &e); err != nil || code != http.StatusUnprocessableEntity || e.Error != "validation" || len(e.Causes) == 0 {
			t.Errorf("%s: %d %s; want 422 validation with causes", f, code, body)
		}
		if bytes.Contains(body, []byte("apiVersion")) || bytes.Contains(body, []byte("manifests")) {
			t.Errorf("%s: a refusal carried output", f)
		}
	}
	code, body := post(t, s, fixture(t, "refuse_unsupported_te.json"))
	if code != 422 || !bytes.Contains(body, []byte("unsupported feature: traffic-engineering")) {
		t.Errorf("unsupported_te: %d %s", code, body)
	}
	for _, bad := range []string{"", "not json", "{\"serviceId\":", "42"} {
		code, body := post(t, s, []byte(bad))
		if code != http.StatusBadRequest || !bytes.Contains(body, []byte(`"error":"malformed"`)) {
			t.Errorf("%q: %d %s; want 400 malformed", bad, code, body)
		}
	}
	big := bytes.Repeat([]byte(" "), maxBody+10)
	if code, _ := post(t, s, big); code != http.StatusBadRequest {
		t.Errorf("an oversized body: %d", code)
	}
	resp, err := http.Get(s.URL + "/v1/translate")
	if err != nil || resp.StatusCode != http.StatusMethodNotAllowed || resp.Header.Get("Allow") != "POST" {
		t.Errorf("GET /v1/translate: %v %v", err, resp)
	}
	assertLogLines(t, &logs)
}

func TestHealthz(t *testing.T) {
	s := server(t, &bytes.Buffer{})
	resp, err := http.Get(s.URL + "/healthz")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("healthz: %v %v", err, resp)
	}
}

// assertLogLines: every line one JSON object with ts, level, component, msg first (NFR-014).
func assertLogLines(t *testing.T, logs *bytes.Buffer) {
	t.Helper()
	lines := strings.Split(strings.TrimSpace(logs.String()), "\n")
	if len(lines) == 0 || lines[0] == "" {
		t.Fatal("no log line written")
	}
	for _, l := range lines {
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatalf("not one JSON object per line: %q", l)
		}
		if m["component"] != component || m["msg"] == "" || m["level"] == "" || m["ts"] == "" {
			t.Errorf("log line %q lacks the NFR-014 fields", l)
		}
		if !strings.HasPrefix(l, `{"ts":`) {
			t.Errorf("log line does not start with ts: %q", l)
		}
	}
}

// The process: listens where told, answers, stops on cancellation; an unparsable inventory refuses
// to start.
func TestRunServesAndStops(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	_ = l.Close()
	t.Setenv(EnvListenAddr, addr)
	t.Setenv(migration.EnvNodeMap, "")
	t.Setenv(migration.EnvPortMap, "")
	t.Setenv(migration.EnvFabricASN, "65000")
	ctx, cancel := context.WithCancel(context.Background())
	var out bytes.Buffer
	done := make(chan int, 1)
	go func() { done <- run(ctx, nil, &out) }()
	deadline := time.Now().Add(5 * time.Second)
	for {
		resp, err := http.Get("http://" + addr + "/healthz")
		if err == nil && resp.StatusCode == 200 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the sidecar did not come up on %s: %v", addr, err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	cancel()
	if code := <-done; code != 0 {
		t.Errorf("exit %d", code)
	}
	if !strings.Contains(out.String(), `"msg":"intent-translator listening"`) || !strings.Contains(out.String(), addr) {
		t.Errorf("start-up line: %s", out.String())
	}

	t.Setenv(migration.EnvNodeMap, "not-json")
	if code := run(context.Background(), nil, &bytes.Buffer{}); code != 2 {
		t.Errorf("an unparsable FABRIC_NODE_MAP: exit %d, want 2", code)
	}
}

func TestDefaultListenIsLoopback8090(t *testing.T) {
	if defaultAddr != "127.0.0.1:8090" {
		t.Errorf("default listen address %q", defaultAddr)
	}
}

// No cluster client: the binary's dependency closure holds no client-go, controller-runtime or
// apimachinery package — it reads and writes JSON and YAML only (translator-api.md).
func TestNoClusterClientImported(t *testing.T) {
	goBin, err := exec.LookPath("go")
	if err != nil {
		t.Skip("no go binary on PATH")
	}
	out, err := exec.Command(goBin, "list", "-deps", ".").Output()
	if err != nil {
		t.Fatal(err)
	}
	deps := strings.Fields(string(out))
	if len(deps) < 10 {
		t.Fatalf("go list -deps returned %d packages", len(deps))
	}
	for _, d := range deps {
		for _, banned := range []string{"k8s.io/client-go", "sigs.k8s.io/controller-runtime", "k8s.io/apimachinery", "k8s.io/api/"} {
			if strings.HasPrefix(d, banned) {
				t.Errorf("the intent-translator binary imports %s", d)
			}
		}
	}
}
