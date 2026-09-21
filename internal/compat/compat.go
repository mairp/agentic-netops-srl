// Package compat is the provider's view of the nine-part compatibility set of
// contracts/crd-api.md "Version contract", read from versions.lock.yaml.
//
// Where the lock comes from at run time (T040's choice): the lock file is
// COPIED INTO THE PROVIDER IMAGE at build time (docker/Dockerfile.srl-provider
// → /etc/srl-provider/versions.lock.yaml; COMPAT_LOCK_FILE overrides the path).
// It is part of the image's build context, so it is covered by the image's
// content-hash tag (data-model.md §26): the provider running and the lock it
// asserts cannot drift apart without the tag changing. A mounted ConfigMap was
// rejected because a kustomization cannot read a file outside its own root and
// a hand-copied ConfigMap is a second copy to keep equal.
//
// What is asserted before rendering (Rule 3 item 5): parts 2–4 against the
// Schema the target's schema was loaded from, and part 1 against each Target's
// discovered provider and version. A mismatch is Rendered=False/SchemaMismatch
// and no Config changes (data-model.md §18).
//
// What is published: Identifier() on every generated Config
// (pkg/sdc.AnnotationCompatibilitySet) and JSON() in the ConfigMap
// srl-provider-compatibility-set, so that make verify-compat (T050) can compare
// what the provider asserts with versions.lock.yaml.
package compat

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	invv1alpha1 "github.com/sdcio/config-server/apis/inv/v1alpha1"
	"sigs.k8s.io/yaml"
)

// Repository is one Schema repository entry of part 4.
type Repository struct {
	RepoURL string `json:"repoURL"`
	Kind    string `json:"kind"`
	Ref     string `json:"ref"`
}

// Set is the nine-part compatibility set.
type Set struct {
	DeviceImage struct {
		Repository string `json:"repository"`
		Tag        string `json:"tag"`
		Digest     string `json:"digest"`
		Pinned     string `json:"pinned"`
	} `json:"deviceImage"`
	YANGModels struct {
		Repository string `json:"repository"`
		Tag        string `json:"tag"`
		Commit     string `json:"commit"`
	} `json:"yangModels"`
	DeviationPatch struct {
		Repository string `json:"repository"`
		Commit     string `json:"commit"`
	} `json:"deviationPatch"`
	Schema struct {
		Provider     string       `json:"provider"`
		Version      string       `json:"version"`
		Models       []string     `json:"models"`
		Includes     []string     `json:"includes"`
		Excludes     []string     `json:"excludes"`
		Repositories []Repository `json:"repositories"`
	} `json:"schema"`
	DeviceConfiguration struct {
		ConfigServer struct {
			Tag string `json:"tag"`
		} `json:"configServer"`
		DataServer struct {
			Tag string `json:"tag"`
		} `json:"dataServer"`
	} `json:"deviceConfiguration"`
	AllocationAuthorityRelease struct {
		KuidServer struct {
			Tag    string `json:"tag"`
			Digest string `json:"digest"`
		} `json:"kuidServer"`
	} `json:"allocationAuthorityRelease"`
	Containerlab struct {
		Version string `json:"version"`
	} `json:"containerlab"`
	Gnmic struct {
		Version string `json:"version"`
	} `json:"gnmic"`
	SRLMapping struct {
		Version string `json:"version"`
	} `json:"srlMapping"`
}

type lockFile struct {
	CompatibilitySet *Set `json:"compatibilitySet"`
}

// Load reads the compatibility set from a versions.lock.yaml file.
func Load(path string) (*Set, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("compatibility set: read %s: %w", path, err)
	}
	s, err := Parse(b)
	if err != nil {
		return nil, fmt.Errorf("compatibility set: %s: %w", path, err)
	}
	return s, nil
}

// Parse reads the compatibilitySet block of a versions.lock.yaml document and
// refuses one with an empty part 1–4 or 9 value.
func Parse(b []byte) (*Set, error) {
	var lf lockFile
	if err := yaml.Unmarshal(b, &lf); err != nil {
		return nil, err
	}
	s := lf.CompatibilitySet
	if s == nil {
		return nil, fmt.Errorf("no compatibilitySet block")
	}
	for name, v := range map[string]string{
		"deviceImage.tag": s.DeviceImage.Tag, "deviceImage.digest": s.DeviceImage.Digest,
		"yangModels.tag": s.YANGModels.Tag, "yangModels.commit": s.YANGModels.Commit,
		"deviationPatch.commit": s.DeviationPatch.Commit,
		"schema.provider":       s.Schema.Provider, "schema.version": s.Schema.Version,
		"srlMapping.version": s.SRLMapping.Version,
	} {
		if strings.TrimSpace(v) == "" {
			return nil, fmt.Errorf("compatibilitySet.%s is empty", name)
		}
	}
	if len(s.Schema.Repositories) == 0 {
		return nil, fmt.Errorf("compatibilitySet.schema.repositories is empty")
	}
	return s, nil
}

// Identifier is the nine-part set as one line, stamped on every generated
// Config (contracts/crd-api.md: "the nine-part compatibility set").
func (s *Set) Identifier() string {
	parts := []string{
		"1=" + s.DeviceImage.Repository + ":" + s.DeviceImage.Tag + "@" + s.DeviceImage.Digest,
		"2=" + trimURL(s.YANGModels.Repository) + "@" + s.YANGModels.Tag + "/" + s.YANGModels.Commit,
		"3=" + trimURL(s.DeviationPatch.Repository) + "@" + s.DeviationPatch.Commit,
		"4=" + s.Schema.Provider + "/" + s.Schema.Version,
		"5=config-server@" + s.DeviceConfiguration.ConfigServer.Tag + ",data-server@" + s.DeviceConfiguration.DataServer.Tag,
		"6=kuid-server@" + s.AllocationAuthorityRelease.KuidServer.Tag,
		"7=containerlab@" + s.Containerlab.Version,
		"8=gnmic@" + s.Gnmic.Version,
		"9=srl-mapping@" + s.SRLMapping.Version,
	}
	return strings.Join(parts, ";")
}

// JSON is the published document: the identifier and every part as read.
func (s *Set) JSON() ([]byte, error) {
	return json.MarshalIndent(struct {
		Identifier string `json:"identifier"`
		*Set
	}{s.Identifier(), s}, "", "  ")
}

// ValidateSchema compares a loaded Schema CR with parts 2, 3 and 4 and returns
// every mismatch, each naming the part; none means it matches.
func (s *Set) ValidateSchema(sc *invv1alpha1.Schema) []string {
	var out []string
	if sc.Spec.Provider != s.Schema.Provider {
		out = append(out, fmt.Sprintf("part 4: Schema %s provider %q, lock %q", sc.Name, sc.Spec.Provider, s.Schema.Provider))
	}
	if sc.Spec.Version != s.Schema.Version {
		out = append(out, fmt.Sprintf("part 4: Schema %s version %q, lock %q", sc.Name, sc.Spec.Version, s.Schema.Version))
	}
	var models, includes, excludes []string
	have := map[string]*invv1alpha1.SchemaSpecRepository{}
	for _, r := range sc.Spec.Repositories {
		if r == nil {
			continue
		}
		have[trimURL(r.RepoURL)] = r
		models = append(models, r.Schema.Models...)
		includes = append(includes, r.Schema.Includes...)
		excludes = append(excludes, r.Schema.Excludes...)
	}
	for _, want := range s.Schema.Repositories {
		r, ok := have[trimURL(want.RepoURL)]
		switch {
		case !ok:
			out = append(out, fmt.Sprintf("part 4: Schema %s has no repository %s", sc.Name, want.RepoURL))
		case string(r.Kind) != want.Kind || r.Ref != want.Ref:
			out = append(out, fmt.Sprintf("part 4: Schema %s repository %s is %s %q, lock %s %q", sc.Name, want.RepoURL, r.Kind, r.Ref, want.Kind, want.Ref))
		}
	}
	if r, ok := have[trimURL(s.YANGModels.Repository)]; ok && r.Ref != s.YANGModels.Tag && r.Ref != s.YANGModels.Commit {
		out = append(out, fmt.Sprintf("part 2: Schema %s loads %s at %q, lock %s = %s", sc.Name, s.YANGModels.Repository, r.Ref, s.YANGModels.Tag, s.YANGModels.Commit))
	}
	if r, ok := have[trimURL(s.DeviationPatch.Repository)]; ok && r.Ref != s.DeviationPatch.Commit {
		out = append(out, fmt.Sprintf("part 3: Schema %s loads %s at %q, lock commit %s", sc.Name, s.DeviationPatch.Repository, r.Ref, s.DeviationPatch.Commit))
	}
	for _, c := range []struct {
		name       string
		have, want []string
	}{{"models", models, s.Schema.Models}, {"includes", includes, s.Schema.Includes}, {"excludes", excludes, s.Schema.Excludes}} {
		if !sameSet(c.have, c.want) {
			out = append(out, fmt.Sprintf("part 4: Schema %s %s %v, lock %v", sc.Name, c.name, c.have, c.want))
		}
	}
	return out
}

// ValidateTarget compares a Target's discovered provider and version with
// parts 1 and 4. An empty discovered version is reported as not yet
// discovered (ok false, mismatch empty): a dependency wait, never a mismatch.
func (s *Set) ValidateTarget(name, provider, version string) (ok bool, mismatch string) {
	if version == "" {
		return false, ""
	}
	if provider != "" && provider != s.Schema.Provider {
		return false, fmt.Sprintf("part 4: target %s discovered provider %q, lock %q", name, provider, s.Schema.Provider)
	}
	if version != s.DeviceImage.Tag {
		return false, fmt.Sprintf("part 1: target %s runs version %q, lock device image %s", name, version, s.DeviceImage.Pinned)
	}
	return true, ""
}

func trimURL(u string) string {
	u = strings.TrimSuffix(strings.TrimSuffix(strings.TrimSpace(u), "/"), ".git")
	u = strings.TrimPrefix(u, "https://")
	return strings.TrimPrefix(u, "github.com/")
}

func sameSet(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	x := append([]string(nil), a...)
	y := append([]string(nil), b...)
	sort.Strings(x)
	sort.Strings(y)
	for i := range x {
		if x[i] != y[i] {
			return false
		}
	}
	return true
}
