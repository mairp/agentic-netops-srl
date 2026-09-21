package compat

import (
	"path/filepath"
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
		rep.RepoURL, rep.Kind, rep.Ref = r.RepoURL, invv1alpha1.BranchTagKind(r.Kind), r.Ref
		if i == 0 {
			rep.Schema = invv1alpha1.SchemaSpecSchema{Models: s.Schema.Models, Includes: s.Schema.Includes, Excludes: s.Schema.Excludes}
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
	sc.Spec.Repositories[0].Kind, sc.Spec.Repositories[0].Ref = "branch", "main"
	if m := strings.Join(s.ValidateSchema(sc), "|"); !strings.Contains(m, "part 2") {
		t.Errorf("models branch not refused: %s", m)
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
