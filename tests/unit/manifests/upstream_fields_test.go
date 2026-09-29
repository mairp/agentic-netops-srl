// Package manifests_test decodes the first-party manifests written against upstream APIs with the
// upstream Go types of the pinned versions, rejecting unknown fields — a misspelt or invented
// field fails here, offline, instead of at apply time (T036, T038; FR-012, FR-015, AD-33, AD-10):
//
//   - deploy/sdc/onboarding/*.yaml against config-server v0.0.58 inv.sdcio.dev/v1alpha1, and the
//     Schema CR against versions.lock.yaml compatibilitySet part 4 exactly (tag/hash refs, never a
//     branch), gNMI JSON_IETF + TLS on 57400, Get-only sync, four static addresses;
//   - deploy/kuid/indices/*.yaml against kuid v0.0.13 (the ipam/as/vlan/genid backends), with the
//     index names and bands of contracts/kuid-claim-profiles.md §1; the generated infra.kuid.dev
//     inventory is counted here and field-checked by tests/unit/inventory.
package manifests_test

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"

	asv1alpha1 "github.com/kuidio/kuid/apis/backend/as/v1alpha1"
	genidv1alpha1 "github.com/kuidio/kuid/apis/backend/genid/v1alpha1"
	ipamv1alpha1 "github.com/kuidio/kuid/apis/backend/ipam/v1alpha1"
	vlanv1alpha1 "github.com/kuidio/kuid/apis/backend/vlan/v1alpha1"
	invv1alpha1 "github.com/sdcio/config-server/apis/inv/v1alpha1"
	"sigs.k8s.io/yaml"
)

func repoRoot(t *testing.T) string {
	t.Helper()
	_, file, _, _ := runtime.Caller(0)
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
}

type typeMeta struct {
	APIVersion string `json:"apiVersion"`
	Kind       string `json:"kind"`
}

// docs splits a manifest file into its YAML documents (comments and empty documents dropped).
func docs(t *testing.T, path string) [][]byte {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	var out [][]byte
	for _, d := range bytes.Split(append([]byte("\n"), raw...), []byte("\n---")) {
		var m map[string]any
		if err := yaml.Unmarshal(d, &m); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		if len(m) > 0 {
			out = append(out, d)
		}
	}
	return out
}

// strict decodes one document into a typed object, failing on any unknown field.
func strict(t *testing.T, path string, doc []byte, into any) {
	t.Helper()
	if err := yaml.UnmarshalStrict(doc, into); err != nil {
		t.Fatalf("%s: does not decode strictly into %T: %v", path, into, err)
	}
}

func TestOnboardingManifestsDecodeAsConfigServerV0058(t *testing.T) {
	root := repoRoot(t)
	dir := filepath.Join(root, "deploy", "sdc", "onboarding")
	seen := map[string]int{}
	var schema invv1alpha1.Schema
	var tcp invv1alpha1.TargetConnectionProfile
	var tsp invv1alpha1.TargetSyncProfile
	var dr invv1alpha1.DiscoveryRule
	for _, f := range []string{"schema.yaml", "target-connection-profile.yaml", "target-sync-profile.yaml", "discovery-rule.yaml"} {
		p := filepath.Join(dir, f)
		for _, d := range docs(t, p) {
			var tm typeMeta
			strict(t, p, d, &map[string]any{})
			if err := yaml.Unmarshal(d, &tm); err != nil {
				t.Fatal(err)
			}
			if tm.APIVersion != "inv.sdcio.dev/v1alpha1" {
				t.Errorf("%s: apiVersion %q, want inv.sdcio.dev/v1alpha1", p, tm.APIVersion)
			}
			seen[tm.Kind]++
			switch tm.Kind {
			case "Schema":
				strict(t, p, d, &schema)
			case "TargetConnectionProfile":
				strict(t, p, d, &tcp)
			case "TargetSyncProfile":
				strict(t, p, d, &tsp)
			case "DiscoveryRule":
				strict(t, p, d, &dr)
			default:
				t.Errorf("%s: unexpected kind %q in the onboarding set", p, tm.Kind)
			}
		}
	}
	for _, k := range []string{"Schema", "TargetConnectionProfile", "TargetSyncProfile", "DiscoveryRule"} {
		if seen[k] != 1 {
			t.Errorf("onboarding carries %d %s object(s), want exactly 1", seen[k], k)
		}
	}

	// Schema == versions.lock.yaml compatibilitySet part 4.
	var lock struct {
		CompatibilitySet struct {
			Schema struct {
				Provider     string   `json:"provider"`
				Version      string   `json:"version"`
				Models       []string `json:"models"`
				Includes     []string `json:"includes"`
				Excludes     []string `json:"excludes"`
				Repositories []struct {
					RepoURL string `json:"repoURL"`
					Kind    string `json:"kind"`
					Ref     string `json:"ref"`
					// Mirror: where the Schema loads the repository from (AD-75).
					Mirror *struct {
						RepoURL string `json:"repoURL"`
						Kind    string `json:"kind"`
						Ref     string `json:"ref"`
					} `json:"mirror"`
				} `json:"repositories"`
			} `json:"schema"`
		} `json:"compatibilitySet"`
	}
	raw, err := os.ReadFile(filepath.Join(root, "versions.lock.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if err := yaml.Unmarshal(raw, &lock); err != nil {
		t.Fatal(err)
	}
	want := lock.CompatibilitySet.Schema
	if schema.Spec.Provider != want.Provider || schema.Spec.Version != want.Version {
		t.Errorf("Schema provider/version %s/%s, lock part 4 says %s/%s", schema.Spec.Provider, schema.Spec.Version, want.Provider, want.Version)
	}
	if len(schema.Spec.Repositories) != len(want.Repositories) {
		t.Fatalf("Schema has %d repositories, lock part 4 has %d", len(schema.Spec.Repositories), len(want.Repositories))
	}
	for i, r := range schema.Spec.Repositories {
		w := want.Repositories[i]
		if m := w.Mirror; m != nil {
			w.RepoURL, w.Kind, w.Ref = m.RepoURL, m.Kind, m.Ref
		}
		if r.RepoURL != w.RepoURL || string(r.Kind) != w.Kind || r.Ref != w.Ref {
			t.Errorf("Schema repository %d = %s %s %s, lock part 4 says %s %s %s", i, r.RepoURL, r.Kind, r.Ref, w.RepoURL, w.Kind, w.Ref)
		}
		if r.Kind != invv1alpha1.BranchTagKindTag && r.Kind != invv1alpha1.BranchTagKindHash {
			t.Errorf("Schema repository %s is pinned by %q: only tag or hash, never a branch", r.RepoURL, r.Kind)
		}
	}
	native := schema.Spec.Repositories[0].Schema
	if !reflect.DeepEqual(native.Models, want.Models) || !reflect.DeepEqual(native.Includes, want.Includes) || !reflect.DeepEqual(native.Excludes, want.Excludes) {
		t.Errorf("Schema models/includes/excludes %v/%v/%v, lock part 4 says %v/%v/%v",
			native.Models, native.Includes, native.Excludes, want.Models, want.Includes, want.Excludes)
	}

	// gNMI, JSON_IETF, TLS on 57400.
	if tcp.Spec.Protocol != "gnmi" || tcp.Spec.Port != 57400 || tcp.Spec.Encoding == nil || *tcp.Spec.Encoding != "JSON_IETF" {
		t.Errorf("TargetConnectionProfile: protocol %s port %d encoding %v, want gnmi 57400 JSON_IETF", tcp.Spec.Protocol, tcp.Spec.Port, tcp.Spec.Encoding)
	}
	if tcp.Spec.Insecure == nil || *tcp.Spec.Insecure {
		t.Errorf("TargetConnectionProfile: insecure must be stated false (TLS on the wire)")
	}
	// Get-only sync over the same port (no Subscribe: FR-086).
	for _, s := range tsp.Spec.Sync {
		if s.Mode != "get" && s.Mode != "once" {
			t.Errorf("TargetSyncProfile sync %s: mode %s is a Subscribe mode", s.Name, s.Mode)
		}
		if s.Port != 57400 || s.Encoding == nil || *s.Encoding != "JSON_IETF" {
			t.Errorf("TargetSyncProfile sync %s: port %d encoding %v, want 57400 JSON_IETF", s.Name, s.Port, s.Encoding)
		}
	}
	// Four static targets, the default schema, the two profiles by name.
	names := map[string]string{}
	for _, a := range dr.Spec.Addresses {
		names[a.HostName] = a.Address
	}
	wantAddr := map[string]string{"spine01": "172.25.25.11", "spine02": "172.25.25.12", "leaf01": "172.25.25.21", "leaf02": "172.25.25.22"}
	if !reflect.DeepEqual(names, wantAddr) {
		t.Errorf("DiscoveryRule addresses %v, want %v", names, wantAddr)
	}
	if dr.Spec.DefaultSchema == nil || dr.Spec.DefaultSchema.Provider != want.Provider || dr.Spec.DefaultSchema.Version != want.Version {
		t.Errorf("DiscoveryRule defaultSchema %+v, want %s %s", dr.Spec.DefaultSchema, want.Provider, want.Version)
	}
	if dr.Spec.DiscoveryProfile != nil {
		t.Errorf("DiscoveryRule has a discoveryProfile: the targets are static, nothing is probed")
	}
	if len(dr.Spec.TargetConnectionProfiles) != 1 {
		t.Fatalf("DiscoveryRule: %d target profiles, want 1", len(dr.Spec.TargetConnectionProfiles))
	}
	tp := dr.Spec.TargetConnectionProfiles[0]
	if tp.ConnectionProfile != tcp.Name || tp.SyncProfile == nil || *tp.SyncProfile != tsp.Name {
		t.Errorf("DiscoveryRule target profile %s/%v does not name the onboarding profiles %s/%s", tp.ConnectionProfile, tp.SyncProfile, tcp.Name, tsp.Name)
	}
	for _, o := range []string{schema.Namespace, tcp.Namespace, tsp.Namespace, dr.Namespace} {
		// Targets and everything they use live in agentic-netops-system because config-server
		// v0.0.58 lists them in the Target's namespace (AD-82 decision 2026-09-21-target-namespace).
		if o != "agentic-netops-system" {
			t.Errorf("onboarding object in namespace %q, want agentic-netops-system", o)
		}
	}
}

func TestKuidSeedManifestsDecodeAsKuidV0013(t *testing.T) {
	dir := filepath.Join(repoRoot(t), "deploy", "kuid", "indices")
	files, err := filepath.Glob(filepath.Join(dir, "*.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	ip := map[string]ipamv1alpha1.IPIndex{}
	var as []asv1alpha1.ASIndex
	var vlan []vlanv1alpha1.VLANIndex
	var genid []genidv1alpha1.GENIDIndex
	infra := map[string]int{}
	for _, p := range files {
		if filepath.Base(p) == "kustomization.yaml" {
			continue
		}
		for _, d := range docs(t, p) {
			var tm typeMeta
			if err := yaml.Unmarshal(d, &tm); err != nil {
				t.Fatal(err)
			}
			switch tm.APIVersion + "/" + tm.Kind {
			case "ipam.be.kuid.dev/v1alpha1/IPIndex":
				var o ipamv1alpha1.IPIndex
				strict(t, p, d, &o)
				ip[o.Name] = o
			case "as.be.kuid.dev/v1alpha1/ASIndex":
				var o asv1alpha1.ASIndex
				strict(t, p, d, &o)
				as = append(as, o)
			case "vlan.be.kuid.dev/v1alpha1/VLANIndex":
				var o vlanv1alpha1.VLANIndex
				strict(t, p, d, &o)
				vlan = append(vlan, o)
			case "genid.be.kuid.dev/v1alpha1/GENIDIndex":
				var o genidv1alpha1.GENIDIndex
				strict(t, p, d, &o)
				genid = append(genid, o)
			case "infra.kuid.dev/v1alpha1/Node", "infra.kuid.dev/v1alpha1/Endpoint", "infra.kuid.dev/v1alpha1/Link":
				// The infra Go package pulls a module this repository does not require
				// (kubenet-dev/apis); its field names are checked by tests/unit/inventory.
				infra[tm.Kind]++
			default:
				t.Errorf("%s: unexpected %s %s in the KUID seed", p, tm.APIVersion, tm.Kind)
			}
		}
	}
	prefix := func(name string) string {
		o, ok := ip[name]
		if !ok || len(o.Spec.Prefixes) != 1 {
			return "<absent>"
		}
		return o.Spec.Prefixes[0].Prefix
	}
	if got := prefix("fabric01-loopback"); got != "10.0.0.0/24" {
		t.Errorf("IPIndex fabric01-loopback prefix %s, want 10.0.0.0/24", got)
	}
	if got := prefix("fabric01-p2p"); got != "10.1.0.0/24" {
		t.Errorf("IPIndex fabric01-p2p prefix %s, want 10.1.0.0/24", got)
	}
	u32 := func(p *uint32) uint32 {
		if p == nil {
			return 0
		}
		return *p
	}
	if len(as) != 1 || as[0].Name != "fabric01-underlay" || u32(as[0].Spec.MinID) != 65100 || u32(as[0].Spec.MaxID) != 65199 {
		t.Errorf("want one ASIndex fabric01-underlay 65100–65199, got %+v", as)
	}
	// AD-33: the allocation band is the index's own minID/maxID; the naming band 100–999 is outside.
	if len(vlan) != 1 || u32(vlan[0].Spec.MinID) != 1000 || u32(vlan[0].Spec.MaxID) != 4000 {
		t.Errorf("want one VLANIndex with minID 1000, maxID 4000, got %+v", vlan)
	}
	// AD-10: the VNI band 10000–20000, a subset of 1..65535 (evi := vni).
	if len(genid) != 1 || genid[0].Spec.Type != "32bit" || genid[0].Spec.MinID == nil || genid[0].Spec.MaxID == nil ||
		*genid[0].Spec.MinID != 10000 || *genid[0].Spec.MaxID != 20000 {
		t.Errorf("want one GENIDIndex 32bit 10000–20000, got %+v", genid)
	} else if *genid[0].Spec.MaxID > 65535 {
		t.Errorf("GENIDIndex band exceeds the device evi range 1..65535")
	}
	// 11 endpoints: 8 fabric ports and 3 access ports — leaf02 ethernet-1/2, client02's untagged
	// second link, among them (AD-51, AD-68; live-findings 2026-09-26-t151r7)
	if infra["Node"] != 4 || infra["Link"] != 4 || infra["Endpoint"] != 11 {
		t.Errorf("inventory: %v, want 4 Node, 4 Link, 11 Endpoint (the reference lab)", infra)
	}
	for _, n := range []string{"fabric01-loopback", "fabric01-p2p"} {
		if o, ok := ip[n]; ok && !strings.EqualFold(o.Namespace, "kuid-system") {
			t.Errorf("IPIndex %s in namespace %q, want kuid-system", n, o.Namespace)
		}
	}
}
