//go:build envtest

// API contract tests (T017; contracts/crd-api.md §"API contract tests"): the generated CRDs are
// installed into a real API server (controller-runtime envtest) and every case is decided by
// that server's admission — structural schema and CEL — through server-side dry-run creates
// and, for the transition rules, dry-run updates of an object that was really created.
//
// Run: scripts/ci/test_envtest.sh, which sets KUBEBUILDER_ASSETS from setup-envtest and runs
// `go test -tags envtest ./tests/envtest/...`. Without the envtest tag this package is empty,
// so `go test ./...` (make test-static) skips it without a runtime skip.
//
// Every write uses fieldValidation=Strict — what kubectl sends by default — so that an unknown
// field is refused rather than pruned.
package api_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	utilyaml "k8s.io/apimachinery/pkg/util/yaml"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	"sigs.k8s.io/yaml"
)

var (
	k8s      client.Client
	restCfg  *rest.Config
	repoRoot string
	strict   = client.FieldValidation("Strict")
)

const (
	nsIntent  = "agentic-netops-intent"
	nsSystem  = "agentic-netops-system"
	nsUpdates = "envtest-updates"
)

func TestMain(m *testing.M) {
	_, file, _, _ := runtime.Caller(0)
	repoRoot = filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))

	// All three CRD directories are installed here — the default set, the conditional kinds
	// and the optional MigrationPlan — so that each CRD is proven installable (structural, CEL
	// within the cost budget). What provisioning installs is asserted by
	// tests/unit/api/conditional_kinds_test.go, not here.
	env := &envtest.Environment{
		CRDDirectoryPaths: []string{
			filepath.Join(repoRoot, "config", "crd"),
			filepath.Join(repoRoot, "config", "crd", "conditional"),
			filepath.Join(repoRoot, "config", "crd", "optional"),
		},
		ErrorIfCRDPathMissing: true,
	}
	cfg, err := env.Start()
	if err != nil {
		fmt.Fprintf(os.Stderr, "envtest: starting the control plane (is KUBEBUILDER_ASSETS set?): %v\n", err)
		os.Exit(1)
	}
	restCfg = cfg
	code := func() int {
		k8s, err = client.New(cfg, client.Options{})
		if err != nil {
			fmt.Fprintf(os.Stderr, "envtest: client: %v\n", err)
			return 1
		}
		for _, ns := range []string{nsIntent, nsSystem, nsUpdates} {
			if err := k8s.Create(context.Background(), namespace(ns)); err != nil {
				fmt.Fprintf(os.Stderr, "envtest: namespace %s: %v\n", ns, err)
				return 1
			}
		}
		return m.Run()
	}()
	if err := env.Stop(); err != nil {
		fmt.Fprintf(os.Stderr, "envtest: stop: %v\n", err)
	}
	os.Exit(code)
}

// ---------------------------------------------------------------------------------------------
// Fixtures

const fabricYAML = `
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Fabric
metadata: {name: fabric01, namespace: agentic-netops-system}
spec:
  nodes:
  - {name: spine01, role: spine, platform: ixr-d3l, systemIPv4: 10.0.0.11/32, asn: 65100, routeReflector: true}
  - {name: spine02, role: spine, platform: ixr-d3l, systemIPv4: 10.0.0.12/32, asn: 65100, routeReflector: true}
  - {name: leaf01, role: leaf, platform: ixr-d2l, systemIPv4: 10.0.0.1/32, asn: 65101}
  - {name: leaf02, role: leaf, platform: ixr-d2l, systemIPv4: 10.0.0.2/32, asn: 65102}
  underlay:
    addressFamilies: [ipv4, ipv6]
  overlay: {fabricASN: 65000, routeReflectors: [spine01, spine02], interASVPN: true}
  mtu: {portMTU: 9412, underlayIPMTU: 9398, bridgedL2MTU: 9412, tenantIPMTU: 9348}
  inventory:
  - {node: leaf01, accessPorts: [ethernet-1/1, ethernet-1/2], fabricPorts: [ethernet-1/49, ethernet-1/50]}
  - {node: leaf02, accessPorts: [ethernet-1/1], fabricPorts: [ethernet-1/49, ethernet-1/50]}
  - {node: spine01, fabricPorts: [ethernet-1/1, ethernet-1/2]}
  - {node: spine02, fabricPorts: [ethernet-1/1, ethernet-1/2]}
  maintenance:
  - {node: leaf01, interface: ethernet-1/49, adminState: disable}
`

// macvrfYAML is a mac-vrf with no gateway: VLAN 100, L2VNI 10021.
const macvrfYAML = `
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
metadata: {name: macvrf, namespace: agentic-netops-intent}
spec:
  description: mac-vrf
  bridgeDomains:
  - name: bd-a
    vlan: 100
    l2vni: 10021
    evpn: {routeTargets: {import: ["target:65000:10021"], export: ["target:65000:10021"]}}
  attachments:
  - {node: leaf01, attachment: ethernet-1/1, vlan: 100}
  - {node: leaf02, attachment: ethernet-1/1, vlan: 100}
`

// gatewayYAML is a mac-vrf with an anycast gateway and an access list.
const gatewayYAML = `
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
metadata: {name: gateway, namespace: agentic-netops-intent}
spec:
  bridgeDomains:
  - name: bd-a
    vlan: 100
    l2vni: 10021
    evpn: {routeTargets: {import: ["target:65000:10021"], export: ["target:65000:10021"]}}
    irb: {vrf: vrf-a, gatewayIPv4: 10.10.0.1/24, gatewayIPv6: "2001:db8:10::1/64"}
  routers:
  - name: vrf-a
    routeTargets: {import: ["target:65000:10022"], export: ["target:65000:10022"]}
    l3vni: 10022
    prefixes: ["10.10.0.0/24"]
  accessLists:
  - name: acl-a
    stage: ingress
    type: ipv4
    defaultAction: deny
    rules:
    - {name: allow-https, priority: 100, action: permit, protocol: tcp, sourcePrefix: 10.0.0.0/24, destinationPort: "443"}
  attachments:
  - {node: leaf01, attachment: ethernet-1/1, vlan: 100}
`

const vlanYAML = `
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
metadata: {name: vlan, namespace: agentic-netops-intent}
spec:
  vlans: [{name: vlan-a, vlan: 110}]
  attachments:
  - {node: leaf01, attachment: ethernet-1/1, vlan: 110}
`

const ipvrfYAML = `
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
metadata: {name: ipvrf, namespace: agentic-netops-intent}
spec:
  routers:
  - name: vrf-b
    routeTargets: {import: ["target:65000:10032"], export: ["target:65000:10032"]}
    l3vni: 10032
    prefixes: ["10.20.0.0/24"]
  attachments:
  - {node: leaf01, attachment: ethernet-1/1, vlan: 200, vrf: vrf-b}
`

const aclYAML = `
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
metadata: {name: acl, namespace: agentic-netops-intent}
spec:
  accessLists:
  - name: acl-b
    stage: ingress
    type: ipv4
    rules:
    - {name: r1, priority: 10, action: deny, protocol: tcp, destinationPort: "23"}
    - {name: r2, priority: 20, action: permit, protocol: udp, sourcePort: "1000-2000"}
  attachments:
  - {node: leaf01, attachment: ethernet-1/1, vlan: 100}
`

// ---------------------------------------------------------------------------------------------
// Helpers

func parse(t *testing.T, doc string) *unstructured.Unstructured {
	t.Helper()
	obj := map[string]any{}
	if err := yaml.Unmarshal([]byte(doc), &obj); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	return &unstructured.Unstructured{Object: obj}
}

// yv decodes a YAML fragment into a JSON-compatible value (numbers as int64 or float64).
func yv(t *testing.T, frag string) any {
	t.Helper()
	var v any
	if err := yaml.Unmarshal([]byte(frag), &v); err != nil {
		t.Fatalf("value %q: %v", frag, err)
	}
	return v
}

type seg struct {
	key string
	idx int // -1 when the segment is not indexed
}

func parsePath(t *testing.T, path string) []seg {
	t.Helper()
	var out []seg
	for _, p := range strings.Split(path, ".") {
		s := seg{key: p, idx: -1}
		if i := strings.IndexByte(p, '['); i >= 0 {
			n, err := strconv.Atoi(strings.TrimSuffix(p[i+1:], "]"))
			if err != nil {
				t.Fatalf("path %q: %v", path, err)
			}
			s = seg{key: p[:i], idx: n}
		}
		out = append(out, s)
	}
	return out
}

// set assigns a YAML value at a path like spec.bridgeDomains[0].l2vni.
func set(t *testing.T, u *unstructured.Unstructured, path, frag string) {
	t.Helper()
	setValue(t, u, path, yv(t, frag))
}

func setValue(t *testing.T, u *unstructured.Unstructured, path string, v any) {
	t.Helper()
	segs := parsePath(t, path)
	cur := any(u.Object)
	for i, s := range segs {
		m, ok := cur.(map[string]any)
		if !ok {
			t.Fatalf("path %q: %q is not an object", path, s.key)
		}
		last := i == len(segs)-1
		if s.idx < 0 {
			if last {
				m[s.key] = v
				return
			}
			if _, ok := m[s.key]; !ok {
				m[s.key] = map[string]any{}
			}
			cur = m[s.key]
			continue
		}
		l, ok := m[s.key].([]any)
		if !ok || s.idx >= len(l) {
			t.Fatalf("path %q: no element %d of %q", path, s.idx, s.key)
		}
		if last {
			l[s.idx] = v
			return
		}
		cur = l[s.idx]
	}
}

// del removes the field (or list element) at path.
func del(t *testing.T, u *unstructured.Unstructured, path string) {
	t.Helper()
	segs := parsePath(t, path)
	parent := parsePathParent(t, u, segs)
	s := segs[len(segs)-1]
	if s.idx < 0 {
		delete(parent, s.key)
		return
	}
	l := parent[s.key].([]any)
	parent[s.key] = append(l[:s.idx:s.idx], l[s.idx+1:]...)
}

func parsePathParent(t *testing.T, u *unstructured.Unstructured, segs []seg) map[string]any {
	t.Helper()
	cur := any(u.Object)
	for _, s := range segs[:len(segs)-1] {
		m := cur.(map[string]any)
		if s.idx < 0 {
			cur = m[s.key]
		} else {
			cur = m[s.key].([]any)[s.idx]
		}
	}
	m, ok := cur.(map[string]any)
	if !ok {
		t.Fatalf("parent of %v is not an object", segs)
	}
	return m
}

// appendTo appends a YAML value to the list at path.
func appendTo(t *testing.T, u *unstructured.Unstructured, path, frag string) {
	t.Helper()
	segs := parsePath(t, path)
	parent := parsePathParent(t, u, segs)
	key := segs[len(segs)-1].key
	l, _ := parent[key].([]any)
	parent[key] = append(l, yv(t, frag))
}

func dryRunCreate(u *unstructured.Unstructured) error {
	return k8s.Create(context.Background(), u.DeepCopy(), client.DryRunAll, strict)
}

func dryRunUpdate(u *unstructured.Unstructured) error {
	return k8s.Update(context.Background(), u.DeepCopy(), client.DryRunAll, strict)
}

func expectAccepted(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("expected the API server to accept, got: %v", err)
	}
}

// expectRejected asserts an admission refusal (Invalid, or BadRequest for a strict-decoding
// unknown field) whose message contains every wanted substring.
func expectRejected(t *testing.T, err error, want ...string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected the API server to refuse; it accepted")
	}
	if !apierrors.IsInvalid(err) && !apierrors.IsBadRequest(err) {
		t.Fatalf("expected an Invalid or BadRequest refusal, got %v (%T)", err, err)
	}
	msg := err.Error()
	for _, w := range want {
		if !strings.Contains(msg, w) {
			t.Errorf("refusal does not contain %q:\n%s", w, msg)
		}
	}
	t.Logf("refused: %s", msg)
}

// ---------------------------------------------------------------------------------------------
// Every shipped example accepted; examples/constructs/negative/ asserted separately.

type manifest struct {
	path string
	obj  *unstructured.Unstructured
}

func readManifests(t *testing.T, root string, skip func(string) bool) []manifest {
	t.Helper()
	var out []manifest
	err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if skip != nil && skip(p) {
				return filepath.SkipDir
			}
			return nil
		}
		if ext := filepath.Ext(p); ext != ".yaml" && ext != ".yml" {
			return nil
		}
		raw, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		dec := utilyaml.NewYAMLOrJSONDecoder(bytes.NewReader(raw), 4096)
		for i := 0; ; i++ {
			obj := map[string]any{}
			if err := dec.Decode(&obj); err != nil {
				if errors.Is(err, io.EOF) {
					break
				}
				return fmt.Errorf("%s document %d: %w", p, i, err)
			}
			if len(obj) == 0 {
				continue
			}
			rel, _ := filepath.Rel(repoRoot, p)
			out = append(out, manifest{path: fmt.Sprintf("%s#%d", rel, i), obj: &unstructured.Unstructured{Object: obj}})
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walking %s: %v", root, err)
	}
	return out
}

func namespace(name string) *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1", "kind": "Namespace", "metadata": map[string]any{"name": name},
	}}
}

func ensureNamespace(t *testing.T, ns string) {
	t.Helper()
	if ns == "" {
		return
	}
	err := k8s.Create(context.Background(), namespace(ns))
	if err != nil && !apierrors.IsAlreadyExists(err) {
		t.Fatalf("namespace %s: %v", ns, err)
	}
}

func TestEveryShippedExampleAccepted(t *testing.T) {
	negative := filepath.Join(repoRoot, "examples", "constructs", "negative")
	ms := readManifests(t, filepath.Join(repoRoot, "examples"), func(p string) bool { return p == negative })
	kinds := map[string]int{}
	for _, m := range ms {
		kinds[m.obj.GetKind()]++
		t.Run(m.path, func(t *testing.T) {
			ensureNamespace(t, m.obj.GetNamespace())
			expectAccepted(t, dryRunCreate(m.obj))
		})
	}
	// The examples must make this test meaningful: a Fabric and a Network of each construct.
	if kinds["Fabric"] < 1 || kinds["Network"] < 4 {
		t.Fatalf("examples/ must ship at least one Fabric and four Networks (vlan, mac-vrf, ip-vrf, acl); found %v", kinds)
	}
}

// TestNegativeConstructFixturesPassAdmission: examples/constructs/negative/ is refused by the
// provider's claim gate (T170, T172), not by the schema — so the API server must ACCEPT it; a
// test expecting admission to reject it would be asserting the wrong layer (AD-50).
func TestNegativeConstructFixturesPassAdmission(t *testing.T) {
	negative := filepath.Join(repoRoot, "examples", "constructs", "negative")
	if _, err := os.Stat(negative); errors.Is(err, os.ErrNotExist) {
		t.Logf("%s does not exist yet (a later task ships it); nothing to assert", negative)
		return
	}
	for _, m := range readManifests(t, negative, nil) {
		t.Run(m.path, func(t *testing.T) {
			ensureNamespace(t, m.obj.GetNamespace())
			expectAccepted(t, dryRunCreate(m.obj))
		})
	}
}

// ---------------------------------------------------------------------------------------------
// Negative fixtures of contracts/crd-api.md §"API contract tests", by server-side dry-run create.

type createCase struct {
	name   string
	base   string
	mutate func(t *testing.T, u *unstructured.Unstructured)
	want   []string // nil: accepted
}

func runCreateCases(t *testing.T, cases []createCase) {
	t.Helper()
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			u := parse(t, tc.base)
			if tc.mutate != nil {
				tc.mutate(t, u)
			}
			err := dryRunCreate(u)
			if tc.want == nil {
				expectAccepted(t, err)
				return
			}
			expectRejected(t, err, tc.want...)
		})
	}
}

const (
	namingBand     = "naming band 100–999"
	allocationBand = "1000–4000 belongs to the allocation authority"
)

func TestNetworkCreateRejected(t *testing.T) {
	name64 := strings.Repeat("a", 64)
	runCreateCases(t, []createCase{
		{"fixtures are valid as written: mac-vrf", macvrfYAML, nil, nil},
		{"fixtures are valid as written: mac-vrf with gateway", gatewayYAML, nil, nil},
		{"fixtures are valid as written: vlan", vlanYAML, nil, nil},
		{"fixtures are valid as written: ip-vrf", ipvrfYAML, nil, nil},
		{"fixtures are valid as written: acl", aclYAML, nil, nil},

		{"unknown field", macvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.encapsulation", "vxlan")
		}, []string{`unknown field "spec.encapsulation"`}},
		{"route-distinguisher field", ipvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.routers[0].rd", `"65000:10032"`)
		}, []string{`unknown field "spec.routers[0].rd"`}},
		{"route-distinguisher field (long name)", ipvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.routers[0].routeDistinguisher", `"65000:10032"`)
		}, []string{`unknown field "spec.routers[0].routeDistinguisher"`}},
		{"VNI above the device range", macvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.bridgeDomains[0].l2vni", "70000")
			set(t, u, "spec.bridgeDomains[0].evpn.routeTargets", `{import: ["target:65000:70000"], export: ["target:65000:70000"]}`)
		}, []string{"VNI 70000 is outside the device range 1..65535"}},
		{"VNI zero, below the device range", ipvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.routers[0].l3vni", "0")
			del(t, u, "spec.routers[0].routeTargets")
		}, []string{"VNI 0 is outside the device range 1..65535"}},
		{"L2VNI equals L3VNI", gatewayYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.routers[0].l3vni", "10021")
			set(t, u, "spec.routers[0].routeTargets", `{import: ["target:65000:10021"]}`)
		}, []string{"L2VNI and L3VNI differ"}},
		{"VLAN below the managed range states both bands", macvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.bridgeDomains[0].vlan", "50")
			set(t, u, "spec.attachments[0].vlan", "50")
			set(t, u, "spec.attachments[1].vlan", "50")
		}, []string{"VLAN 50 is outside the platform VLAN space 100–4000", namingBand, allocationBand}},
		{"VLAN above the managed range states both bands", vlanYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.vlans[0].vlan", "4001")
			set(t, u, "spec.attachments[0].vlan", "4001")
		}, []string{"VLAN 4001 is outside the platform VLAN space 100–4000", namingBand, allocationBand}},
		{"ip-vrf attachment VLAN outside the managed range states both bands", ipvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.attachments[0].vlan", "4050")
		}, []string{"attachment VLAN 4050 is outside the platform VLAN space 100–4000", namingBand, allocationBand}},
		{"duplicate rule priorities", aclYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.accessLists[0].rules[1].priority", "10")
		}, []string{"rule priorities must be distinct", "priority 10 is used more than once"}},
		{"priority 65535", aclYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.accessLists[0].rules[1].priority", "65535")
		}, []string{"priority 65535 is outside the usable range 1–65534", "65535 is reserved for the default action"}},
		{"priority 0", aclYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.accessLists[0].rules[1].priority", "0")
		}, []string{"priority 0 is outside the usable range 1–65534"}},
		{"duplicate rule names", aclYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.accessLists[0].rules[1].name", "r1")
		}, []string{"Duplicate value"}},
		{"mismatched prefix family", aclYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.accessLists[0].rules[0].sourcePrefix", `"2001:db8::/32"`)
		}, []string{"access list acl-b is of type ipv4: every prefix must be in that address family"}},
		{"L4 port on a non-TCP/UDP protocol", aclYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.accessLists[0].rules[0].protocol", "icmp")
		}, []string{"rule r1: an L4 port is allowed only with protocol tcp or udp"}},
		{"L4 port with no protocol", aclYAML, func(t *testing.T, u *unstructured.Unstructured) {
			del(t, u, "spec.accessLists[0].rules[0].protocol")
		}, []string{"an L4 port is allowed only with protocol tcp or udp"}},
		{"reserved filter name system", aclYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.accessLists[0].name", "system")
		}, []string{"access-list name system is reserved by the device"}},
		{"reserved filter name capture", aclYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.accessLists[0].name", "capture")
		}, []string{"access-list name capture is reserved by the device"}},
		{"two attachments resolving to one subinterface", macvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			appendTo(t, u, "spec.attachments", `{node: leaf01, attachment: ethernet-1/1, vlan: 100}`)
		}, []string{"two attachments resolve to one subinterface: leaf01 ethernet-1/1.100"}},
		{"untagged and tagged attachment on one port of one object", aclYAML, func(t *testing.T, u *unstructured.Unstructured) {
			appendTo(t, u, "spec.attachments", `{node: leaf01, attachment: ethernet-1/1}`)
		}, []string{"port leaf01 ethernet-1/1 carries an untagged and a tagged attachment", "one tagging mode per port"}},
		{"metadata.name containing a dot", macvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			u.SetName("migr.4b7e19c2a05d3f6")
		}, []string{"metadata.name must not contain a dot"}},
		{"entry name containing a dot", macvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.bridgeDomains[0].name", "bd.a")
		}, []string{"spec.bridgeDomains[0].name", "should match"}},
		{"metadata.name of 64 characters", macvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			u.SetName(name64)
		}, []string{"metadata.name must be a DNS-1123 label of at most 63 characters"}},
		{"metadata.name of 63 characters accepted", macvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			u.SetName(name64[:63])
		}, nil},
		{"metadata.name not a DNS-1123 label", macvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			u.SetName("migr-")
		}, []string{"metadata.name must be a DNS-1123 label"}},
		{"bridgeDomains[] entry name of 64 characters", macvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.bridgeDomains[0].name", name64)
		}, []string{"spec.bridgeDomains[0].name", "Too long", "63"}},
		{"vlans[] entry name of 64 characters", vlanYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.vlans[0].name", name64)
		}, []string{"spec.vlans[0].name", "Too long"}},
		{"routers[] entry name of 64 characters", ipvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.routers[0].name", name64)
			set(t, u, "spec.attachments[0].vrf", name64)
		}, []string{"spec.routers[0].name", "Too long"}},

		// Construct-list exclusivity, one VLAN per bridge domain, derived route targets, gateway.
		{"vlans and bridgeDomains together", macvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.vlans", `[{name: vlan-a, vlan: 100}]`)
		}, []string{"vlans and bridgeDomains cannot both be present"}},
		{"vlans and routers together", vlanYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.routers", `[{name: vrf-a, l3vni: 10022}]`)
		}, []string{"vlans and routers cannot both be present"}},
		{"bridgeDomains and routers without an irb", macvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.routers", `[{name: vrf-a, l3vni: 10022}]`)
		}, []string{"bridgeDomains and routers can both be present only when the bridge domain carries an irb"}},
		{"no construct list", macvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			del(t, u, "spec.bridgeDomains")
		}, []string{"one of vlans, bridgeDomains, routers or accessLists must be present"}},
		{"attachment VLAN other than the bridge domain's", macvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.attachments[1].vlan", "101")
		}, []string{"one VLAN per bridge domain"}},
		{"route target not derived from the VNI", macvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.bridgeDomains[0].evpn.routeTargets.export", `["target:65000:99"]`)
		}, []string{"must be target:<fabricASN>:<l2vni>"}},
		{"route target not of the target:<asn>:<vni> form", ipvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.routers[0].routeTargets.import", `["65000:10032"]`)
		}, []string{"spec.routers[0].routeTargets.import[0]", "should match"}},
		{"irb with no router to point at", macvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.bridgeDomains[0].irb", `{vrf: vrf-a, gatewayIPv4: 10.10.0.1/24}`)
		}, []string{"irb requires a routers entry"}},
		{"irb with no address family", gatewayYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.bridgeDomains[0].irb", `{vrf: vrf-a}`)
		}, []string{"irb declares at least one address family"}},
		{"link-local IPv6 gateway", gatewayYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.bridgeDomains[0].irb.gatewayIPv6", `"fe80::1/64"`)
		}, []string{"gatewayIPv6 must not be a link-local address"}},

		// Positive schema cases: which band a value falls in is not a CEL question (AD-33, AD-41).
		{"VLAN 1000 accepted by the schema", macvrfYAML, withVLAN(1000), nil},
		{"VLAN 1500 accepted by the schema", macvrfYAML, withVLAN(1500), nil},
		{"VLAN 4000 accepted by the schema", macvrfYAML, withVLAN(4000), nil},
		{"VLAN 100 accepted by the schema", vlanYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.vlans[0].vlan", "100")
			set(t, u, "spec.attachments[0].vlan", "100")
		}, nil},
		{"ip-vrf attachment VLAN 1500 accepted by the schema on create", ipvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.attachments[0].vlan", "1500")
		}, nil},
		{"ip-vrf untagged attachment accepted", ipvrfYAML, func(t *testing.T, u *unstructured.Unstructured) {
			del(t, u, "spec.attachments[0].vlan")
		}, nil},
		{"accessLists-only attachment VLAN held to the structural range alone", aclYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.attachments[0].vlan", "4050")
		}, nil},
		{"accessLists-only attachment VLAN beyond the structural range", aclYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.attachments[0].vlan", "4095")
		}, []string{"spec.attachments[0].vlan", "4094"}},
	})
}

func withVLAN(v int) func(t *testing.T, u *unstructured.Unstructured) {
	return func(t *testing.T, u *unstructured.Unstructured) {
		s := strconv.Itoa(v)
		set(t, u, "spec.bridgeDomains[0].vlan", s)
		set(t, u, "spec.attachments[0].vlan", s)
		set(t, u, "spec.attachments[1].vlan", s)
	}
}

func TestFabricCreateRejected(t *testing.T) {
	runCreateCases(t, []createCase{
		{"fixture is valid as written", fabricYAML, nil, nil},
		{"maintenance[] naming a port outside the inventory", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			appendTo(t, u, "spec.maintenance", `{node: leaf02, interface: ethernet-1/7, adminState: disable}`)
		}, []string{"maintenance names leaf02 ethernet-1/7, which is not a port of spec.inventory"}},
		{"maintenance[] naming a node outside the inventory", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			appendTo(t, u, "spec.maintenance", `{node: leaf09, interface: ethernet-1/1, adminState: disable}`)
		}, []string{"maintenance names leaf09 ethernet-1/1, which is not a port of spec.inventory"}},
		{"maintenance[] duplicated port", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			appendTo(t, u, "spec.maintenance", `{node: leaf01, interface: ethernet-1/49, adminState: disable}`)
		}, []string{"spec.maintenance[1]", "Duplicate value"}},
		{"maintenance[] adminState other than disable", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.maintenance[0].adminState", "enable")
		}, []string{"spec.maintenance[0].adminState", "Unsupported value"}},
		{"maintenance[] on an access port accepted", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			appendTo(t, u, "spec.maintenance", `{node: leaf02, interface: ethernet-1/1, adminState: disable}`)
		}, nil},
		{"untaggedAccessPorts a subset of accessPorts accepted", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.inventory[0].untaggedAccessPorts", `[ethernet-1/2]`)
		}, nil},
		{"untaggedAccessPorts naming a port that is not an access port", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.inventory[0].untaggedAccessPorts", `[ethernet-1/2, ethernet-1/49]`)
		}, []string{"inventory leaf01: untaggedAccessPorts lists ethernet-1/49, which is not one of its accessPorts"}},
		{"access and fabric ports not disjoint", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.inventory[1].accessPorts", `[ethernet-1/1, ethernet-1/49]`)
		}, []string{"port ethernet-1/49 is listed in both accessPorts and fabricPorts"}},
		{"spine with access ports", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.inventory[2].accessPorts", `[ethernet-1/9]`)
		}, []string{"a spine inventory entry has no access ports"}},
		{"no spine", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.nodes[0].role", "leaf")
			set(t, u, "spec.nodes[1].role", "leaf")
			del(t, u, "spec.nodes[0].routeReflector")
			del(t, u, "spec.nodes[1].routeReflector")
			del(t, u, "spec.overlay.routeReflectors")
			del(t, u, "spec.inventory[3]")
			del(t, u, "spec.inventory[2]")
			set(t, u, "spec.nodes[1].asn", "65103")
		}, []string{"a Fabric has at least one leaf and one spine"}},
		{"duplicate node names", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.nodes[3].name", "leaf01")
		}, []string{"Duplicate value"}},
		{"route reflector on a leaf", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.nodes[2].routeReflector", "true")
		}, []string{"routeReflector may be set only on a spine"}},
		{"leaf ASN not unique", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.nodes[3].asn", "65101")
		}, []string{"the underlay asn is unique per leaf"}},
		{"spine ASNs differ", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.nodes[1].asn", "65199")
		}, []string{"the underlay asn is shared across spines"}},
		{"systemIPv4 not a /32", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.nodes[2].systemIPv4", "10.0.0.1/24")
		}, []string{"systemIPv4 must be an IPv4 /32"}},
		{"empty underlay address-family list", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.underlay.addressFamilies", `[]`)
		}, []string{"spec.underlay.addressFamilies"}},
		{"tenantIPMTU not portMTU - 64", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.mtu.tenantIPMTU", "9000")
		}, []string{"mtu.tenantIPMTU must equal mtu.portMTU - 64"}},
		{"overlay.interASVPN false accepted (AD-43)", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.overlay.interASVPN", "false")
		}, nil},
		{"unknown field", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			set(t, u, "spec.overlay.routeDistinguisher", `"65000:1"`)
		}, []string{`unknown field "spec.overlay.routeDistinguisher"`}},
		{"metadata.name containing a dot", fabricYAML, func(t *testing.T, u *unstructured.Unstructured) {
			u.SetName("fabric.01")
		}, []string{"metadata.name must not contain a dot"}},
	})
}

// ---------------------------------------------------------------------------------------------
// Updates to an accepted object: transition rules (FR-109, AD-25, AD-32, AD-33, AD-47, AD-51).
//
// "Accepted" is what the API server admitted: a CEL transition rule runs on an update, which
// exists only for an object the server already accepted on create, and it reads spec alone —
// never status (AD-51).

// created really creates the object (not a dry-run) under a unique name in nsUpdates and
// returns what the server stored, so that updates carry its resourceVersion.
func created(t *testing.T, doc, name string) *unstructured.Unstructured {
	t.Helper()
	u := parse(t, doc)
	u.SetNamespace(nsUpdates)
	u.SetName(name)
	if err := k8s.Create(context.Background(), u, strict); err != nil {
		t.Fatalf("creating %s: %v", name, err)
	}
	t.Cleanup(func() { _ = k8s.Delete(context.Background(), u) })
	return u
}

type updateCase struct {
	name   string
	base   string
	setup  func(t *testing.T, u *unstructured.Unstructured) // applied before the real create
	mutate func(t *testing.T, u *unstructured.Unstructured)
	want   []string // nil: accepted
}

func TestNetworkUpdates(t *testing.T) {
	cases := []updateCase{
		{name: "changed l2vni refused naming the field", base: macvrfYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				set(t, u, "spec.bridgeDomains[0].l2vni", "10025")
				set(t, u, "spec.bridgeDomains[0].evpn.routeTargets", `{import: ["target:65000:10025"], export: ["target:65000:10025"]}`)
			},
			want: []string{"spec.bridgeDomains[].l2vni is immutable once the Network is accepted", "changing it is a removal and a new service"}},
		{name: "changed l3vni refused naming the field", base: gatewayYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				set(t, u, "spec.routers[0].l3vni", "10026")
				set(t, u, "spec.routers[0].routeTargets", `{import: ["target:65000:10026"], export: ["target:65000:10026"]}`)
			},
			want: []string{"spec.routers[].l3vni is immutable once the Network is accepted", "changing it is a removal and a new service"}},
		{name: "changed l3vni of an ip-vrf refused naming the field", base: ipvrfYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				set(t, u, "spec.routers[0].l3vni", "10033")
				del(t, u, "spec.routers[0].routeTargets")
			},
			want: []string{"spec.routers[].l3vni is immutable"}},
		{name: "changed service VLAN of a mac-vrf refused naming the field", base: macvrfYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				set(t, u, "spec.bridgeDomains[0].vlan", "101")
				set(t, u, "spec.attachments[0].vlan", "101")
				set(t, u, "spec.attachments[1].vlan", "101")
			},
			want: []string{"spec.bridgeDomains[].vlan is immutable once the Network is accepted", "changing it is a removal and a new service"}},
		{name: "changed service VLAN of a vlan refused naming the field", base: vlanYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				set(t, u, "spec.vlans[0].vlan", "111")
				set(t, u, "spec.attachments[0].vlan", "111")
			},
			want: []string{"spec.vlans[].vlan is immutable once the Network is accepted", "changing it is a removal and a new service"}},
		{name: "renamed bridgeDomains entry refused", base: macvrfYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				set(t, u, "spec.bridgeDomains[0].name", "bd-b")
			},
			want: []string{"spec.bridgeDomains entries cannot be added, removed or renamed once the Network is accepted"}},
		{name: "renamed vlans entry refused", base: vlanYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				set(t, u, "spec.vlans[0].name", "vlan-b")
			},
			want: []string{"spec.vlans entries cannot be added, removed or renamed"}},
		{name: "renamed routers entry refused", base: ipvrfYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				set(t, u, "spec.routers[0].name", "vrf-c")
				set(t, u, "spec.attachments[0].vrf", "vrf-c")
			},
			want: []string{"spec.routers entries cannot be added, removed or renamed"}},
		{name: "routers entry added to a mac-vrf refused", base: macvrfYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				set(t, u, "spec.bridgeDomains[0].irb", `{vrf: vrf-a, gatewayIPv4: 10.10.0.1/24}`)
				set(t, u, "spec.routers", `[{name: vrf-a, l3vni: 10022}]`)
			},
			want: []string{"spec.routers entries cannot be added, removed or renamed"}},

		// The added-attachment rule.
		{name: "added attachment carrying a new allocation-band VLAN refused naming the VLAN and both bands (ip-vrf gaining VLAN 1500)", base: ipvrfYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				appendTo(t, u, "spec.attachments", `{node: leaf02, attachment: ethernet-1/1, vlan: 1500, vrf: vrf-b}`)
			},
			want: []string{"an attachment added to an accepted Network carries VLAN 1500", "allocation band 1000–4000", "naming band 100–999", "is a new service"}},
		{name: "added attachment carrying a new allocation-band VLAN refused on a mac-vrf too", base: macvrfYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				appendTo(t, u, "spec.attachments", `{node: leaf02, attachment: ethernet-1/2, vlan: 2000}`)
			},
			want: []string{"carries VLAN 2000", "allocation band 1000–4000", "naming band 100–999"}},
		{name: "added attachment carrying a naming-band VLAN accepted", base: ipvrfYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				appendTo(t, u, "spec.attachments", `{node: leaf02, attachment: ethernet-1/1, vlan: 300, vrf: vrf-b}`)
			}},
		{name: "added attachment carrying no VLAN accepted", base: ipvrfYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				appendTo(t, u, "spec.attachments", `{node: leaf02, attachment: ethernet-1/2, vrf: vrf-b}`)
			}},
		{name: "added attachment on a mac-vrf whose own VLAN is 1500, carrying 1500, accepted", base: macvrfYAML,
			setup: withVLAN(1500),
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				appendTo(t, u, "spec.attachments", `{node: leaf02, attachment: ethernet-1/2, vlan: 1500}`)
			}},
		{name: "added attachment on a vlan whose own VLAN is 1500, carrying 1500, accepted", base: vlanYAML,
			setup: func(t *testing.T, u *unstructured.Unstructured) {
				set(t, u, "spec.vlans[0].vlan", "1500")
				set(t, u, "spec.attachments[0].vlan", "1500")
			},
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				appendTo(t, u, "spec.attachments", `{node: leaf02, attachment: ethernet-1/1, vlan: 1500}`)
			}},
		{name: "added attachment on an accessLists-only object, carrying 1500, accepted", base: aclYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				appendTo(t, u, "spec.attachments", `{node: leaf02, attachment: ethernet-1/1, vlan: 1500}`)
			}},
		{name: "ip-vrf attachment already carrying 1500 keeps it", base: ipvrfYAML,
			setup: func(t *testing.T, u *unstructured.Unstructured) {
				set(t, u, "spec.attachments[0].vlan", "1500")
			},
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				set(t, u, "spec.routers[0].prefixes", `["10.20.0.0/24", "10.21.0.0/24"]`)
			}},
		{name: "removed attachment accepted", base: macvrfYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				del(t, u, "spec.attachments[1]")
			}},

		// What stays mutable (FR-109, AD-25).
		{name: "accessLists, prefixes and gateway addresses mutable", base: gatewayYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				set(t, u, "spec.accessLists[0].rules[0].priority", "200")
				set(t, u, "spec.accessLists[0].defaultAction", "permit")
				set(t, u, "spec.routers[0].prefixes", `["10.10.0.0/24", "10.11.0.0/24"]`)
				set(t, u, "spec.bridgeDomains[0].irb.gatewayIPv4", "10.10.0.254/24")
				set(t, u, "spec.bridgeDomains[0].irb.gatewayIPv6", `"2001:db8:10::fe/64"`)
			}},
	}
	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			u := parse(t, tc.base)
			if tc.setup != nil {
				tc.setup(t, u)
			}
			u = created(t, unstructuredYAML(t, u), fmt.Sprintf("upd-%02d", i))
			tc.mutate(t, u)
			err := dryRunUpdate(u)
			if tc.want == nil {
				expectAccepted(t, err)
				return
			}
			expectRejected(t, err, tc.want...)
		})
	}
}

func TestFabricUpdates(t *testing.T) {
	cases := []updateCase{
		{name: "changed overlay.fabricASN refused", base: fabricYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) { set(t, u, "spec.overlay.fabricASN", "65001") },
			want:   []string{"spec.overlay.fabricASN is immutable once the Fabric is accepted"}},
		{name: "changed node role refused", base: fabricYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				set(t, u, "spec.nodes[3].role", "spine")
				set(t, u, "spec.nodes[3].asn", "65100")
			},
			want: []string{"spec.nodes[].role is immutable once the Fabric is accepted"}},
		{name: "maintenance entry added and removed accepted", base: fabricYAML,
			mutate: func(t *testing.T, u *unstructured.Unstructured) {
				set(t, u, "spec.maintenance", `[{node: spine01, interface: ethernet-1/1, adminState: disable}]`)
			}},
	}
	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			u := created(t, tc.base, fmt.Sprintf("fab-%02d", i))
			tc.mutate(t, u)
			err := dryRunUpdate(u)
			if tc.want == nil {
				expectAccepted(t, err)
				return
			}
			expectRejected(t, err, tc.want...)
		})
	}
}

// TestIdentifierClaimSpecImmutable: the conditional IdentifierClaim's spec is immutable by CEL
// (data-model.md §23). The CRD is installed here only to test it; provisioning installs it only
// under allocationAuthority.kind: first-party.
func TestIdentifierClaimSpecImmutable(t *testing.T) {
	u := created(t, `
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: IdentifierClaim
metadata: {name: x}
spec: {poolRef: {name: vni-pool}, requested: "10021"}
`, "claim-01")
	set(t, u, "spec.requested", `"10022"`)
	expectRejected(t, dryRunUpdate(u), "IdentifierClaim spec is immutable")
}

func unstructuredYAML(t *testing.T, u *unstructured.Unstructured) string {
	t.Helper()
	b, err := yaml.Marshal(u.Object)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// TestPrinterColumns: the columns of contracts/crd-api.md §Status "Printer columns", read back
// through the API server's own Table rendering (what kubectl get prints).
func TestPrinterColumns(t *testing.T) {
	type table struct {
		ColumnDefinitions []struct{ Name string } `json:"columnDefinitions"`
		Rows              []struct {
			Cells  []any `json:"cells"`
			Object struct {
				Metadata struct{ Name string } `json:"metadata"`
			} `json:"object"`
		} `json:"rows"`
	}
	get := func(t *testing.T, resource string) table {
		t.Helper()
		hc, err := rest.HTTPClientFor(restCfg)
		if err != nil {
			t.Fatal(err)
		}
		url := strings.TrimSuffix(restCfg.Host, "/") + "/apis/fabric.agentic-netops.io/v1alpha1/namespaces/" + nsUpdates + "/" + resource + "?includeObject=Object"
		req, _ := http.NewRequest(http.MethodGet, url, nil)
		req.Header.Set("Accept", "application/json;as=Table;v=v1;g=meta.k8s.io")
		resp, err := hc.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			t.Fatal(err)
		}
		var tb table
		if err := json.Unmarshal(body, &tb); err != nil {
			t.Fatalf("GET %s: %s: %v: %s", url, resp.Status, err, body)
		}
		return tb
	}
	names := func(tb table) []string {
		var out []string
		for _, c := range tb.ColumnDefinitions {
			out = append(out, c.Name)
		}
		return out
	}
	row := func(t *testing.T, tb table, name string) map[string]string {
		t.Helper()
		for _, r := range tb.Rows {
			if r.Object.Metadata.Name == name {
				out := map[string]string{}
				for i, c := range tb.ColumnDefinitions {
					out[c.Name] = fmt.Sprint(r.Cells[i])
				}
				return out
			}
		}
		t.Fatalf("no row %s", name)
		return nil
	}

	gw := parse(t, gatewayYAML)
	gw.SetAnnotations(map[string]string{"agentic-netops.io/service-type": "mac-vrf", "agentic-netops.io/tenant": "acme"})
	created(t, unstructuredYAML(t, gw), "cols-gateway")
	v := parse(t, vlanYAML)
	v.SetAnnotations(map[string]string{"agentic-netops.io/service-type": "vlan", "agentic-netops.io/tenant": "acme"})
	created(t, unstructuredYAML(t, v), "cols-vlan")
	created(t, fabricYAML, "cols-fabric")

	nt := get(t, "networks")
	if got, want := strings.Join(names(nt), ","), "Name,Construct,Tenant,VLAN,L2VNI,L3VNI,Ready,Degraded,Age"; got != want {
		t.Errorf("Network columns = %s, want %s", got, want)
	}
	r := row(t, nt, "cols-gateway")
	if r["Construct"] != "mac-vrf" || r["Tenant"] != "acme" || r["VLAN"] != "100" || r["L2VNI"] != "10021" || r["L3VNI"] != "10022" {
		t.Errorf("mac-vrf row = %v", r)
	}
	r = row(t, nt, "cols-vlan")
	if r["Construct"] != "vlan" || r["VLAN"] != "110" {
		t.Errorf("vlan row = %v", r)
	}
	ft := get(t, "fabrics")
	if got, want := strings.Join(names(ft), ","), "Name,Leaves,Spines,FabricASN,Allocated,Ready,Degraded,Age"; got != want {
		t.Errorf("Fabric columns = %s, want %s", got, want)
	}
	if r := row(t, ft, "cols-fabric"); r["FabricASN"] != "65000" {
		t.Errorf("Fabric row = %v", r)
	}
}
