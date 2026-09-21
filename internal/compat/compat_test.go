package compat

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"

	invv1alpha1 "github.com/sdcio/config-server/apis/inv/v1alpha1"
)

func lock(t *testing.T) *Set {
	t.Helper()
	_, file, _, _ := runtime.Caller(0)
	s, err := Load(filepath.Join(filepath.Dir(file), "..", "..", "versions.lock.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// MatchingSchema is the Schema CR of compatibility-set part 4 as the lock states it.
func matchingSchema(s *Set) *invv1alpha1.Schema {
	sc := &invv1alpha1.Schema{}
	sc.Name = "srl.nokia.sdcio.dev-25.7.1"
	sc.Spec.Provider, sc.Spec.Version = s.Schema.Provider, s.Schema.Version
	for i, r := range s.Schema.Repositories {
		rep := &invv1alpha1.SchemaSpecRepository{}
		lf := r.LoadedFrom()
		rep.RepoURL, rep.Kind, rep.Ref = lf.RepoURL, invv1alpha1.BranchTagKind(lf.Kind), lf.Ref
		if i == 0 {
			rep.Schema = invv1alpha1.SchemaSpecSchema{Models: s.Schema.Models, Includes: s.Schema.Includes, Excludes: s.Schema.Excludes}
		} else {
			// the deviation patch carries its own models (deploy/sdc/onboarding/schema.yaml)
			rep.Schema = invv1alpha1.SchemaSpecSchema{Models: []string{"deviations"}}
		}
		sc.Spec.Repositories = append(sc.Spec.Repositories, rep)
	}
	return sc
}

func TestLockParsesAllNineParts(t *testing.T) {
	s := lock(t)
	id := s.Identifier()
	for i := 1; i <= 9; i++ {
		if !strings.Contains(id, string(rune('0'+i))+"=") {
			t.Errorf("identifier lacks part %d: %s", i, id)
		}
	}
	for _, want := range []string{"ghcr.io/nokia/srlinux:25.7.1@sha256:", "srl.nokia.sdcio.dev/25.7.1", "srl-mapping@v0.1.0"} {
		if !strings.Contains(id, want) {
			t.Errorf("identifier lacks %q: %s", want, id)
		}
	}
	if _, err := s.JSON(); err != nil {
		t.Fatal(err)
	}
}

func TestSchemaValidation(t *testing.T) {
	s := lock(t)
	if m := s.ValidateSchema(matchingSchema(s)); len(m) != 0 {
		t.Fatalf("matching schema refused: %v", m)
	}
	sc := matchingSchema(s)
	sc.Spec.Version = "24.10.1"
	if m := s.ValidateSchema(sc); len(m) == 0 || !strings.Contains(m[0], "part 4") {
		t.Errorf("version mismatch not found: %v", m)
	}
	sc = matchingSchema(s)
	sc.Spec.Repositories[1].Ref = "0000000"
	if m := strings.Join(s.ValidateSchema(sc), "|"); !strings.Contains(m, "part 3") {
		t.Errorf("deviation patch mismatch not found: %s", m)
	}
	sc = matchingSchema(s)
	sc.Spec.Repositories[0].Schema.Models = append(sc.Spec.Repositories[0].Schema.Models, "extra/models")
	if m := strings.Join(s.ValidateSchema(sc), "|"); !strings.Contains(m, "part 4") || !strings.Contains(m, "models") {
		t.Errorf("extra native models not refused: %s", m)
	}
	sc = matchingSchema(s)
	sc.Spec.Repositories[0].Kind, sc.Spec.Repositories[0].Ref = "branch", "main"
	if m := strings.Join(s.ValidateSchema(sc), "|"); !strings.Contains(m, "part 2") {
		t.Errorf("models branch not refused: %s", m)
	}
}

// TestSchemaLoadsPatchFromMirror: the deviation patch is loaded from the
// in-cluster mirror by the tag named after the locked commit (AD-75); loading
// it from upstream, or by a branch, is a mismatch.
func TestSchemaLoadsPatchFromMirror(t *testing.T) {
	s := lock(t)
	patch := s.Schema.Repositories[1]
	if patch.Mirror == nil || patch.Mirror.Kind != "tag" || patch.Mirror.Ref != s.DeviationPatch.Commit {
		t.Fatalf("lock part 4 repositories[1] has no tag mirror of the part 3 commit: %+v", patch)
	}
	sc := matchingSchema(s)
	if sc.Spec.Repositories[1].RepoURL != patch.Mirror.RepoURL {
		t.Fatalf("matching schema does not load from the mirror: %s", sc.Spec.Repositories[1].RepoURL)
	}
	sc.Spec.Repositories[1].RepoURL, sc.Spec.Repositories[1].Kind = patch.RepoURL, "hash"
	if m := strings.Join(s.ValidateSchema(sc), "|"); !strings.Contains(m, "has no repository "+patch.Mirror.RepoURL) {
		t.Errorf("upstream patch URL not refused: %s", m)
	}
	sc = matchingSchema(s)
	sc.Spec.Repositories[1].Kind, sc.Spec.Repositories[1].Ref = "branch", "v25.7"
	if m := strings.Join(s.ValidateSchema(sc), "|"); !strings.Contains(m, "part 4") || !strings.Contains(m, "part 3") {
		t.Errorf("mirror by branch not refused: %s", m)
	}
}

func TestTargetValidation(t *testing.T) {
	s := lock(t)
	if ok, m := s.ValidateTarget("leaf01", s.Schema.Provider, s.DeviceImage.Tag); !ok || m != "" {
		t.Errorf("matching target: %v %q", ok, m)
	}
	if ok, m := s.ValidateTarget("leaf01", s.Schema.Provider, "24.10.1"); ok || !strings.Contains(m, "part 1") {
		t.Errorf("version mismatch: %v %q", ok, m)
	}
	if ok, m := s.ValidateTarget("leaf01", "", ""); ok || m != "" {
		t.Errorf("undiscovered target is a wait, not a mismatch: %v %q", ok, m)
	}
}

// Part 6 follows allocationAuthority.kind; any other kind, or none, refuses the lock.
func TestAllocationAuthorityKind(t *testing.T) {
	_, file, _, _ := runtime.Caller(0)
	b, err := os.ReadFile(filepath.Join(filepath.Dir(file), "..", "..", "versions.lock.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	withKind := func(kind string) []byte {
		re := regexp.MustCompile(`(?m)^allocationAuthority:\n  kind: [a-z-]+\n`)
		if !re.Match(b) {
			t.Fatal("versions.lock.yaml has no top-level allocationAuthority.kind")
		}
		if kind == "" {
			return re.ReplaceAll(b, []byte("allocationAuthorityGone:\n  kind: x\n"))
		}
		return re.ReplaceAll(b, []byte("allocationAuthority:\n  kind: "+kind+"\n"))
	}
	s, err := Parse(withKind("kuid"))
	if err != nil {
		t.Fatal(err)
	}
	if s.AuthorityKind() != AuthorityKuid || !strings.Contains(s.Identifier(), ";6=kuid-server@"+s.AllocationAuthorityRelease.KuidServer.Tag+";") {
		t.Errorf("kuid: %s %s", s.AuthorityKind(), s.Identifier())
	}
	s, err = Parse(withKind("first-party"))
	if err != nil {
		t.Fatal(err)
	}
	if s.AuthorityKind() != AuthorityFirstParty || !strings.Contains(s.Identifier(), ";6=first-party@fabric.agentic-netops.io/v1alpha1;") ||
		strings.Contains(s.Identifier(), "kuid-server") {
		t.Errorf("first-party: %s %s", s.AuthorityKind(), s.Identifier())
	}
	// The published document is unchanged in shape: the kind is not a field of it.
	doc, err := s.JSON()
	if err != nil || strings.Contains(string(doc), "authorityKind") {
		t.Errorf("published document: %s %v", doc, err)
	}
	for _, bad := range []string{"local", "Kuid", ""} {
		if _, err := Parse(withKind(bad)); err == nil || !strings.Contains(err.Error(), "allocationAuthority") {
			t.Errorf("kind %q: %v", bad, err)
		}
	}
	if got := lock(t).AuthorityKind(); got != AuthorityKuid && got != AuthorityFirstParty {
		t.Errorf("the repository's lock selects %q", got)
	}
}
