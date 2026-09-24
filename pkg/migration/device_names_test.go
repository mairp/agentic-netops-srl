package migration

// T096 (FR-099, SC-013, quickstart.md §22): the two device-named constructs are the device's own
// names. `mac-vrf` and `ip-vrf` must equal network-instance type identities — identities derived
// from `ni-type`, the base of `network-instance/type` — in the pinned srl_nokia model (SR Linux
// v25.7.1, nokia/srlinux-yang-models commit badcf99). The model is read from the vendored excerpt
// tests/unit/testdata/yang/srl_nokia-network-instance.ni-type.excerpt.yang, so the test runs offline
// inside `go test ./...`; when the full upstream file is cached locally (sdc-lite's schema download,
// populated by make verify-render-schema) its digest and the excerpt's lines are checked against it
// too. If a device release renames either type, this vocabulary changes with it or this test fails.

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

const (
	yangExcerpt   = "../../tests/unit/testdata/yang/srl_nokia-network-instance.ni-type.excerpt.yang"
	pinnedCommit  = "badcf9977fe672437907cdae7daebb27a1361c36"
	pinnedTag     = "v25.7.1"
	upstreamPath  = "srlinux-yang-models/srl_nokia/models/network-instance/srl_nokia-network-instance.yang"
	cachedUpRel   = ".cache/sdc-lite/downloads/nokia/srlinux-yang-models/srlinux-yang-models/srl_nokia/models/network-instance/srl_nokia-network-instance.yang"
	lockModelsRef = "nokia/srlinux-yang-models"
)

var (
	identityBlock = regexp.MustCompile(`(?s)\bidentity\s+([A-Za-z0-9_.-]+)\s*\{(.*?)\n\s*\}`)
	baseStmt      = regexp.MustCompile(`\bbase\s+([A-Za-z0-9_.:-]+)\s*;`)
	typeLeaf      = regexp.MustCompile(`(?s)\bleaf\s+type\s*\{\s*type\s+identityref\s*\{\s*base\s+ni-type\s*;`)
	provenance    = regexp.MustCompile(`provenance: source=https://github.com/nokia/srlinux-yang-models version=(\S+) digest=sha256:([0-9a-f]{64})`)
)

func TestConstructNamesMatchDeviceModel(t *testing.T) {
	raw, err := os.ReadFile(yangExcerpt)
	if err != nil {
		t.Fatalf("the pinned model excerpt is missing: %v", err)
	}
	text := string(raw)
	m := provenance.FindStringSubmatch(text)
	if m == nil || m[1] != pinnedTag || !strings.Contains(text, pinnedCommit) || !strings.Contains(text, upstreamPath) {
		t.Fatalf("the excerpt's provenance header does not name %s at %s (commit %s, file %s)", lockModelsRef, pinnedTag, pinnedCommit, upstreamPath)
	}
	digest := m[2]

	// The pinned tag is the lock's (versions.lock.yaml records the model repository and commit).
	lock, err := os.ReadFile("../../versions.lock.yaml")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(lock), pinnedCommit) || !strings.Contains(string(lock), lockModelsRef) {
		t.Errorf("versions.lock.yaml no longer pins %s at commit %s; re-vendor the excerpt from the new pin", lockModelsRef, pinnedCommit)
	}

	if !strings.Contains(text, "module srl_nokia-network-instance {") {
		t.Fatal("the excerpt is not of module srl_nokia-network-instance")
	}
	if !typeLeaf.MatchString(text) {
		t.Fatal("network-instance/type is not an identityref with base ni-type in the excerpt")
	}
	niTypes := map[string]bool{}
	for _, b := range identityBlock.FindAllStringSubmatch(text, -1) {
		if base := baseStmt.FindStringSubmatch(b[2]); base != nil && base[1] == "ni-type" {
			niTypes[b[1]] = true
		}
	}
	for _, construct := range []string{ConstructMACVRF, ConstructIPVRF} {
		if !niTypes[construct] {
			t.Errorf("construct %q is not a network-instance type identity of the pinned model (ni-type identities: %v)", construct, keys(niTypes))
		}
		if r, ok := Canonicalize(construct); !ok || r.Construct != construct || r.Source != "" {
			t.Errorf("construct %q does not resolve to itself", construct)
		}
	}
	// vlan and acl are operator vocabulary, not network-instance types; a vlan renders as a mac-vrf.
	for _, construct := range []string{ConstructVLAN, ConstructACL} {
		if niTypes[construct] {
			t.Errorf("%q is a network-instance type of the model; the vocabulary's claim that it is operator vocabulary is stale", construct)
		}
	}

	// Offline by default; stronger when the upstream file is cached on this host.
	home, _ := os.UserHomeDir()
	up := filepath.Join(home, cachedUpRel)
	full, err := os.ReadFile(up)
	if err != nil {
		t.Logf("upstream file not cached at %s: the excerpt alone was checked", up)
		return
	}
	sum := sha256.Sum256(full)
	if hex.EncodeToString(sum[:]) != digest {
		t.Logf("the cached %s is not the pinned file (sha256 %x); not compared", up, sum)
		return
	}
	upLines := map[string]bool{}
	for _, l := range strings.Split(string(full), "\n") {
		upLines[l] = true
	}
	sc := bufio.NewScanner(strings.NewReader(text))
	for sc.Scan() {
		l := sc.Text()
		if strings.HasPrefix(l, "//") || strings.TrimSpace(l) == "// …" {
			continue
		}
		if !upLines[l] {
			t.Errorf("excerpt line %q is not a line of the pinned upstream file", l)
		}
	}
}

func keys(m map[string]bool) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}
