package migration

// T091, translator half (FR-028, FR-033, FR-034, FR-045, SC-015, AD-20, AD-41): every refusal
// fixture, run through the BUILT CLI exactly as quickstart.md §6 runs it — non-zero exit, the
// structured error {"error":"validation","causes":[…]} on stderr, nothing on stdout, and every cause
// naming its property path; plus the positive half: the allocated-VLAN fixture translates.

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

var (
	cliOnce sync.Once
	cliPath string
	cliErr  string
)

// buildCLI builds cmd/migration-translator once per test binary into a temporary directory.
func buildCLI(t *testing.T) string {
	t.Helper()
	cliOnce.Do(func() {
		dir, err := os.MkdirTemp("", "migration-translator-")
		if err != nil {
			cliErr = err.Error()
			return
		}
		// go test puts $GOROOT/bin first on the PATH of the test process.
		goBin, err := exec.LookPath("go")
		if err != nil {
			cliErr = "no go binary on PATH to build the CLI with: " + err.Error()
			return
		}
		cliPath = filepath.Join(dir, "migration-translator")
		cmd := exec.Command(goBin, "build", "-o", cliPath, "./cmd/migration-translator")
		cmd.Dir = filepath.Join("..", "..")
		if out, err := cmd.CombinedOutput(); err != nil {
			cliErr = "go build ./cmd/migration-translator: " + err.Error() + "\n" + string(out)
		}
	})
	if cliErr != "" {
		t.Fatal(cliErr)
	}
	return cliPath
}

func TestMain(m *testing.M) {
	code := m.Run()
	if cliPath != "" {
		_ = os.RemoveAll(filepath.Dir(cliPath))
	}
	os.Exit(code)
}

type cliRun struct {
	code           int
	stdout, stderr []byte
}

// runCLI runs the built CLI with --file and the lab's site inventory in the environment.
func runCLI(t *testing.T, file string) cliRun {
	t.Helper()
	cmd := exec.Command(buildCLI(t), "--file", filepath.Join(testdata, file))
	cmd.Env = append(os.Environ(), EnvNodeMap+"="+labNodeMap, EnvPortMap+"="+labPortMap, EnvFabricASN+"=65000")
	var so, se bytes.Buffer
	cmd.Stdout, cmd.Stderr = &so, &se
	err := cmd.Run()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	return cliRun{code, so.Bytes(), se.Bytes()}
}

func TestRefusalFixturesThroughTheCLI(t *testing.T) {
	for _, tc := range []struct {
		fixture string
		// path: the property path at least one cause starts with; want: substrings that one cause holds
		path string
		want []string
	}{
		{"wrong_var_l2vni_on_vlan", "l2vni: ", []string{"a vlan", "mac-vrf"}},
		{"wrong_var_gateway_on_ipvrf", "anycastGateway: ", []string{"an ip-vrf", "mac-vrf"}},
		{"unknown_construct", "type: ", []string{`"evpn-magic"`, "vlan, mac-vrf, ip-vrf, acl"}},
		{"vlan_outside_index_range", "endpoints[0].vlan: ", []string{"VLAN 50", "100–4000", "100–999", "1000–4000"}},
		{"vni_outside_band", "l2vni: ", []string{"25000", "10000–20000"}},
		{"vlan_mismatch_endpoints", "endpoints[1].vlan: ", []string{"110", "100", "one bridge domain"}},
		{"tagging_mode_mixed", "endpoints[1]: ", []string{"port ethernet-1/1", "leaf01", "untagged", "tagged", "one tagging mode"}},
		{"node_port_vlan_taken", "input[1].endpoints[0]: ", []string{"leaf01", "ethernet-1/1", "VLAN 100", "held by service 9d1f3b5c7e8a0b2"}},
		{"unknown_node", "endpoints[0].node: ", []string{`"leaf09"`, "leaf01, leaf02"}},
		{"unknown_port", "endpoints[0].attachment: ", []string{`"ethernet-1/9"`, "ethernet-1/1"}},
		{"unsupported_te", "unsupported.traffic-engineering: ", []string{"unsupported feature: traffic-engineering"}},
		{"malformed_unknown_field", "colour: ", []string{`unknown field "colour"`}},
	} {
		t.Run(tc.fixture, func(t *testing.T) {
			r := runCLI(t, "refuse_"+tc.fixture+".json")
			if r.code == 0 {
				t.Fatalf("exit 0; want a refusal (stdout %q)", r.stdout)
			}
			if r.code != 1 {
				t.Errorf("exit %d; want 1 (a refusal, not a usage error)", r.code)
			}
			if len(r.stdout) != 0 {
				t.Errorf("stdout is not empty — nothing may be emitted on a refusal:\n%s", r.stdout)
			}
			var e StructuredError
			dec := json.NewDecoder(bytes.NewReader(r.stderr))
			dec.DisallowUnknownFields()
			if err := dec.Decode(&e); err != nil {
				t.Fatalf("stderr is not the structured error: %v\n%s", err, r.stderr)
			}
			if e.Error != "validation" || len(e.Causes) == 0 {
				t.Fatalf("stderr %s; want error validation with causes", r.stderr)
			}
			found := false
			for _, c := range e.Causes {
				if !strings.Contains(c, ": ") || strings.HasPrefix(c, " ") {
					t.Errorf("cause %q does not start with a property path", c)
				}
				if !strings.HasPrefix(c, tc.path) {
					continue
				}
				all := true
				for _, w := range tc.want {
					all = all && strings.Contains(c, w)
				}
				found = found || all
			}
			if !found {
				t.Errorf("no cause starts with %q and holds %q; causes:\n  %s", tc.path, tc.want, strings.Join(e.Causes, "\n  "))
			}
		})
	}
}

// Every refuse_*.json fixture in the directory is refused by the CLI — covered by the table above
// or by the access-list suite (acl_test.go) — except those decidedByTheWebhook, which need data the
// translator is never given and are proved against the webhook's rules there; none is silently
// skipped.
func TestEveryTranslatorRefusalFixtureRefuses(t *testing.T) {
	files, err := filepath.Glob(filepath.Join(testdata, "refuse_*.json"))
	if err != nil || len(files) < 12 {
		t.Fatalf("refusal fixtures: %v (%d)", err, len(files))
	}
	for _, f := range files {
		if _, elsewhere := decidedByTheWebhook[filepath.Base(f)]; elsewhere {
			r := runCLI(t, filepath.Base(f))
			if r.code != 0 {
				t.Errorf("%s: the translator cannot decide it and must translate it; exit %d, stderr %s", filepath.Base(f), r.code, r.stderr)
			}
			continue
		}
		r := runCLI(t, filepath.Base(f))
		if r.code == 0 || len(r.stdout) != 0 || !bytes.HasPrefix(r.stderr, []byte(`{"error":"validation","causes":[`)) {
			t.Errorf("%s: exit %d, stdout %d bytes, stderr %s", filepath.Base(f), r.code, len(r.stdout), r.stderr)
		}
	}
}

func TestCLITranslatesTheConstructsAndTheAllocatedVLAN(t *testing.T) {
	for _, c := range []string{"vlan", "macvrf", "ipvrf", "macvrf_allocated_vlan"} {
		r := runCLI(t, "construct_"+c+".json")
		if r.code != 0 || len(r.stderr) != 0 {
			t.Errorf("%s: exit %d, stderr %s", c, r.code, r.stderr)
			continue
		}
		if !bytes.HasPrefix(r.stdout, []byte("apiVersion: fabric.agentic-netops.io/v1alpha1\nkind: Network\n")) {
			t.Errorf("%s: stdout %s", c, r.stdout)
		}
		if c != "macvrf_allocated_vlan" {
			golden, _ := os.ReadFile(filepath.Join(testdata, "construct_"+c+".spec.golden.yaml"))
			if !bytes.HasSuffix(r.stdout, golden) {
				t.Errorf("%s: the CLI output does not end with the golden spec block", c)
			}
		} else if !bytes.Contains(r.stdout, []byte("    vlan: 1500\n")) {
			t.Errorf("allocated VLAN 1500 not emitted:\n%s", r.stdout)
		}
	}
}

func TestCLIUsage(t *testing.T) {
	for _, args := range [][]string{{}, {"--file"}, {"--bogus"}, {"--file", "x", "extra"}} {
		cmd := exec.Command(buildCLI(t), args...)
		var so bytes.Buffer
		cmd.Stdout = &so
		err := cmd.Run()
		if ee, ok := err.(*exec.ExitError); !ok || ee.ExitCode() != 2 || so.Len() != 0 {
			t.Errorf("args %q: %v, stdout %q; want exit 2 and no output", args, err, so.String())
		}
	}
	cmd := exec.Command(buildCLI(t), "--file", filepath.Join(testdata, "construct_vlan.json"))
	cmd.Env = append(os.Environ(), EnvNodeMap+"=not-json")
	if err := cmd.Run(); err == nil || err.(*exec.ExitError).ExitCode() != 2 {
		t.Errorf("an unparsable FABRIC_NODE_MAP: %v; want exit 2", err)
	}
}
