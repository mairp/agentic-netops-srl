// Package api_test asserts where each generated CRD is installed from (T015, T016):
//
//   - the default kustomization config/crd/kustomization.yaml — what lab provisioning applies —
//     carries Fabric and Network and, followed recursively through every resource it lists,
//     never IdentifierPool, IdentifierClaim (conditional kinds, FR-104, FR-013) or MigrationPlan
//     (optional, AD-29);
//   - IdentifierPool and IdentifierClaim live under config/crd/conditional/, installed only when
//     versions.lock.yaml selects allocationAuthority.kind: first-party; IdentifierClaim.spec is
//     immutable by CEL and the allocation is reported in status.value (data-model.md §23);
//   - MigrationPlan lives under config/crd/optional/ and its schema has no route-target, VLAN or
//     VNI policy field — preserveRouteTargets does not exist (FR-012) — and rejects unknown
//     fields and raw CLI blobs (contracts/crd-api.md §"Optional MigrationPlan API").
package api_test

import (
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"
)

func repoRoot(t *testing.T) string {
	t.Helper()
	_, file, _, _ := runtime.Caller(0)
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
}

func readYAML(t *testing.T, path string) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading %s: %v", path, err)
	}
	out := map[string]any{}
	if err := yaml.Unmarshal(raw, &out); err != nil {
		t.Fatalf("parsing %s: %v", path, err)
	}
	return out
}

// crdFile is one CRD a kustomization reaches.
type crdFile struct {
	path string
	kind string
	crd  map[string]any
}

// kustomizationCRDs follows a kustomization's resources recursively — a directory by its
// kustomization.yaml, a file as a manifest — and returns every CRD it reaches.
func kustomizationCRDs(t *testing.T, dir string, seen map[string]bool) []crdFile {
	t.Helper()
	kpath := filepath.Join(dir, "kustomization.yaml")
	if seen[kpath] {
		return nil
	}
	seen[kpath] = true
	k := readYAML(t, kpath)
	var out []crdFile
	for _, key := range []string{"resources", "bases", "crds", "components"} {
		list, _ := k[key].([]any)
		for _, r := range list {
			rel, ok := r.(string)
			if !ok {
				t.Fatalf("%s: %s entry %v is not a path", kpath, key, r)
			}
			if strings.Contains(rel, "://") {
				t.Fatalf("%s: remote resource %q in the CRD kustomization", kpath, rel)
			}
			p := filepath.Join(dir, rel)
			st, err := os.Stat(p)
			if err != nil {
				t.Fatalf("%s: resource %q: %v", kpath, rel, err)
			}
			if st.IsDir() {
				out = append(out, kustomizationCRDs(t, p, seen)...)
				continue
			}
			obj := readYAML(t, p)
			if obj["kind"] != "CustomResourceDefinition" {
				continue
			}
			out = append(out, crdFile{path: p, kind: crdKind(obj), crd: obj})
		}
	}
	return out
}

func crdKind(crd map[string]any) string {
	spec, _ := crd["spec"].(map[string]any)
	names, _ := spec["names"].(map[string]any)
	k, _ := names["kind"].(string)
	return k
}

func kinds(files []crdFile) []string {
	var out []string
	for _, f := range files {
		out = append(out, f.kind)
	}
	sort.Strings(out)
	return out
}

func has(list []string, s string) bool {
	for _, e := range list {
		if e == s {
			return true
		}
	}
	return false
}

func TestDefaultKustomizationExcludesConditionalAndOptionalKinds(t *testing.T) {
	root := repoRoot(t)
	def := kustomizationCRDs(t, filepath.Join(root, "config", "crd"), map[string]bool{})
	got := kinds(def)
	t.Logf("default kustomization config/crd/ installs: %v", got)
	for _, want := range []string{"Fabric", "Network"} {
		if !has(got, want) {
			t.Errorf("default kustomization must install %s; it installs %v", want, got)
		}
	}
	for _, never := range []string{"IdentifierPool", "IdentifierClaim", "MigrationPlan"} {
		if has(got, never) {
			t.Errorf("default kustomization must NOT install %s (FR-104/FR-013, AD-29); it installs %v", never, got)
		}
	}
	for _, f := range def {
		rel, _ := filepath.Rel(root, f.path)
		if strings.HasPrefix(rel, filepath.Join("config", "crd", "conditional")) || strings.HasPrefix(rel, filepath.Join("config", "crd", "optional")) {
			t.Errorf("default kustomization reaches %s", rel)
		}
	}
}

func TestConditionalKindsUnderConditional(t *testing.T) {
	root := repoRoot(t)
	files := kustomizationCRDs(t, filepath.Join(root, "config", "crd", "conditional"), map[string]bool{})
	got := kinds(files)
	if len(got) != 2 || !has(got, "IdentifierPool") || !has(got, "IdentifierClaim") {
		t.Fatalf("config/crd/conditional/ must carry exactly IdentifierPool and IdentifierClaim; it carries %v", got)
	}
	for _, f := range files {
		if g := group(f.crd); g != "fabric.agentic-netops.io" {
			t.Errorf("%s is served in %q; the conditional kinds are never served in an upstream group (FR-098)", f.kind, g)
		}
		assertNoPreserveUnknown(t, f)
	}
	claim := byKind(t, files, "IdentifierClaim")
	schema := openAPISchema(t, claim)
	spec := prop(t, schema, "spec")
	if !hasRule(spec, "self == oldSelf") {
		t.Errorf("IdentifierClaim.spec must be immutable by CEL (x-kubernetes-validations rule self == oldSelf); has %v", spec["x-kubernetes-validations"])
	}
	value := prop(t, prop(t, schema, "status"), "value")
	if value["type"] != "string" {
		t.Errorf("IdentifierClaim.status.value must report the allocation; got %v", value)
	}
	pool := openAPISchema(t, byKind(t, files, "IdentifierPool"))
	typ := prop(t, prop(t, pool, "spec"), "type")
	enum, _ := typ["enum"].([]any)
	if len(enum) != 5 {
		t.Errorf("IdentifierPool.spec.type enum must be ip, asn, vlan, vni, genid; got %v", enum)
	}
}

func TestMigrationPlanUnderOptional(t *testing.T) {
	root := repoRoot(t)
	files := kustomizationCRDs(t, filepath.Join(root, "config", "crd", "optional"), map[string]bool{})
	got := kinds(files)
	if len(got) != 1 || got[0] != "MigrationPlan" {
		t.Fatalf("config/crd/optional/ must carry exactly MigrationPlan; it carries %v", got)
	}
	mp := files[0]
	if g := group(mp.crd); g != "agentic-netops.io" {
		t.Errorf("MigrationPlan group = %q, want agentic-netops.io", g)
	}
	assertNoPreserveUnknown(t, mp)

	// No route-target, VLAN or VNI policy field of its own (FR-012, AD-29): preserveRouteTargets
	// does not exist, anywhere in the CRD.
	raw, err := os.ReadFile(mp.path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(strings.ToLower(string(raw)), "preserveroutetargets") {
		t.Errorf("%s mentions preserveRouteTargets", mp.path)
	}
	forbidden := map[string]bool{
		"preserveroutetargets": true, "routetargets": true, "routetarget": true, "rd": true,
		"routedistinguisher": true, "vlan": true, "vlans": true, "vlanid": true, "vni": true,
		"l2vni": true, "l3vni": true, "vnis": true,
	}
	walkProps(openAPISchema(t, mp), "", func(path, name string) {
		if forbidden[strings.ToLower(name)] {
			t.Errorf("MigrationPlan schema carries a route-target/VLAN/VNI policy field %s", path)
		}
	})
	// No raw CLI or configuration blob: every free-text string under spec is bounded, and the
	// only description field refuses newlines.
	spec := prop(t, openAPISchema(t, mp), "spec")
	walkSchemas(spec, "spec", func(path string, s map[string]any) {
		if s["type"] == "string" && s["maxLength"] == nil && s["enum"] == nil {
			t.Errorf("MigrationPlan %s is an unbounded string — a raw blob could be carried", path)
		}
	})
	desc := prop(t, prop(t, prop(t, prop(t, spec, "source"), "normalizedIntent"), "description"), "")
	if !hasRuleContaining(desc, `\n`) {
		t.Errorf("spec.source.normalizedIntent.description must refuse multi-line (raw CLI) text; has %v", desc["x-kubernetes-validations"])
	}
	// Source identity immutable; limited equivalence false and cutover disabled by default.
	source := prop(t, spec, "source")
	if !hasRule(prop(t, source, "serviceID"), "self == oldSelf") {
		t.Errorf("spec.source.serviceID must be immutable by CEL")
	}
	policy := prop(t, spec, "mappingPolicy")
	if d := prop(t, policy, "allowLimitedEquivalence")["default"]; d != false {
		t.Errorf("mappingPolicy.allowLimitedEquivalence default = %v, want false", d)
	}
	if d := prop(t, policy, "cutover")["default"]; d != "disabled" {
		t.Errorf("mappingPolicy.cutover default = %v, want disabled", d)
	}
	// It references the Network's provenance annotations by key, never restating them.
	status := prop(t, openAPISchema(t, mp), "status")
	keys := prop(t, prop(t, status, "provenanceRef"), "annotationKeys")
	if keys["type"] != "array" {
		t.Errorf("status.provenanceRef.annotationKeys must reference the Network's provenance annotations by key")
	}
	for _, restated := range []string{"tenant", "serviceType", "sourceServiceType", "limitedEquivalence", "mappingVersion", "translatorVersion", "annotations"} {
		if _, ok := propsOf(status)[restated]; ok {
			t.Errorf("MigrationPlan status restates provenance field %q instead of referencing the Network's annotations", restated)
		}
	}
}

// TestDefaultCRDsAreStructural: no CRD this repository generates carries
// x-kubernetes-preserve-unknown-fields under spec, so unknown fields are rejected.
func TestDefaultCRDsAreStructural(t *testing.T) {
	root := repoRoot(t)
	for _, f := range kustomizationCRDs(t, filepath.Join(root, "config", "crd"), map[string]bool{}) {
		assertNoPreserveUnknown(t, f)
	}
}

// --- schema helpers ---------------------------------------------------------------------------

func group(crd map[string]any) string {
	spec, _ := crd["spec"].(map[string]any)
	g, _ := spec["group"].(string)
	return g
}

func byKind(t *testing.T, files []crdFile, kind string) crdFile {
	t.Helper()
	for _, f := range files {
		if f.kind == kind {
			return f
		}
	}
	t.Fatalf("no CRD of kind %s", kind)
	return crdFile{}
}

func openAPISchema(t *testing.T, f crdFile) map[string]any {
	t.Helper()
	spec, _ := f.crd["spec"].(map[string]any)
	versions, _ := spec["versions"].([]any)
	if len(versions) != 1 {
		t.Fatalf("%s: want exactly one version, got %d", f.path, len(versions))
	}
	v, _ := versions[0].(map[string]any)
	s, _ := v["schema"].(map[string]any)
	o, ok := s["openAPIV3Schema"].(map[string]any)
	if !ok {
		t.Fatalf("%s: no openAPIV3Schema", f.path)
	}
	return o
}

func propsOf(s map[string]any) map[string]any {
	p, _ := s["properties"].(map[string]any)
	return p
}

// prop returns the named property schema; an empty name returns s itself.
func prop(t *testing.T, s map[string]any, name string) map[string]any {
	t.Helper()
	if name == "" {
		return s
	}
	p, ok := propsOf(s)[name].(map[string]any)
	if !ok {
		t.Fatalf("schema has no property %q", name)
	}
	return p
}

func rules(s map[string]any) []string {
	var out []string
	list, _ := s["x-kubernetes-validations"].([]any)
	for _, r := range list {
		if m, ok := r.(map[string]any); ok {
			if rule, ok := m["rule"].(string); ok {
				out = append(out, rule)
			}
		}
	}
	return out
}

func hasRule(s map[string]any, rule string) bool {
	for _, r := range rules(s) {
		if r == rule {
			return true
		}
	}
	return false
}

func hasRuleContaining(s map[string]any, sub string) bool {
	for _, r := range rules(s) {
		if strings.Contains(r, sub) {
			return true
		}
	}
	return false
}

// walkSchemas visits every schema node under s (properties and array items).
func walkSchemas(s map[string]any, path string, visit func(path string, s map[string]any)) {
	visit(path, s)
	for name, p := range propsOf(s) {
		if m, ok := p.(map[string]any); ok {
			walkSchemas(m, path+"."+name, visit)
		}
	}
	if items, ok := s["items"].(map[string]any); ok {
		walkSchemas(items, path+"[]", visit)
	}
}

func walkProps(s map[string]any, path string, visit func(path, name string)) {
	for name, p := range propsOf(s) {
		visit(path+"."+name, name)
		if m, ok := p.(map[string]any); ok {
			walkProps(m, path+"."+name, visit)
			if items, ok := m["items"].(map[string]any); ok {
				walkProps(items, path+"."+name+"[]", visit)
			}
		}
	}
}

func assertNoPreserveUnknown(t *testing.T, f crdFile) {
	t.Helper()
	spec := prop(t, openAPISchema(t, f), "spec")
	walkSchemas(spec, "spec", func(path string, s map[string]any) {
		if v, ok := s["x-kubernetes-preserve-unknown-fields"]; ok && v == true {
			t.Errorf("%s: %s carries x-kubernetes-preserve-unknown-fields", f.kind, path)
		}
	})
	if len(propsOf(spec)) == 0 {
		t.Errorf("%s: spec has no declared properties — not a real structural schema", f.kind)
	}
}
