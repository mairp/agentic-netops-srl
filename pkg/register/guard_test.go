package register

// The path-register CI guard (T022, FR-017, FR-089, R-05). It drives the
// ACTUAL producers of device paths — internal/model's WritePaths, which the
// renderers of T039/T057 emit exactly, via CheckFabric/CheckService, and
// internal/telemetry.Subscriptions via CheckSubscriptions — over
// representative intent covering every construct, and fails on any emitted
// path the register does not carry.

import (
	"errors"
	"strings"
	"testing"

	"github.com/mairp/agentic-netops-srl/internal/model"
)

func buildFixtures(t *testing.T) (fabs map[string]*model.FabricModel, svcs map[string]*model.ServiceModel) {
	t.Helper()
	fabs, svcs = map[string]*model.FabricModel{}, map[string]*model.ServiceModel{}
	for name, in := range fabricFixtures() {
		m, err := model.BuildFabric(in)
		if err != nil {
			t.Fatalf("fabric fixture %s: %v", name, err)
		}
		fabs[name] = m
	}
	for name, in := range serviceFixtures() {
		m, err := model.BuildService(in)
		if err != nil {
			t.Fatalf("service fixture %s: %v", name, err)
		}
		svcs[name] = m
	}
	return fabs, svcs
}

// TestGuardRegisterIsValid: native by default, no exception without a
// justification, and metric names and labels are the derived ones.
func TestGuardRegisterIsValid(t *testing.T) {
	if err := Validate(); err != nil {
		t.Fatal(err)
	}
	for _, e := range WriteEntries() {
		if e.Model != Native {
			t.Errorf("write %s: model %s — there is no recorded exception today", e.Path, e.Model)
		}
	}
	for _, e := range SubscribeEntries() {
		if e.Model != Native {
			t.Errorf("subscribe %s: model %s — there is no recorded exception today", e.Path, e.Model)
		}
		if e.Mode != Sample {
			t.Errorf("subscribe %s: mode %s — on-change only where G7 covers it, none today", e.Path, e.Mode)
		}
	}
}

// TestGuardFixturesCoverEveryConstruct: the guard's inputs exercise every
// construct, so "no uncovered path" is not vacuous.
func TestGuardFixturesCoverEveryConstruct(t *testing.T) {
	seen := map[model.Construct]bool{}
	for _, in := range serviceFixtures() {
		seen[in.Construct] = true
	}
	for _, c := range []model.Construct{model.ConstructVLAN, model.ConstructMACVRF, model.ConstructIPVRF, model.ConstructACL} {
		if !seen[c] {
			t.Errorf("no guard fixture for construct %s", c)
		}
	}
}

// TestGuardWritePathsCovered drives the real render path functions.
func TestGuardWritePathsCovered(t *testing.T) {
	fabs, svcs := buildFixtures(t)
	for name, m := range fabs {
		if err := CheckFabric(m); err != nil {
			t.Errorf("fabric %s: %v", name, err)
		}
	}
	for name, m := range svcs {
		if err := CheckService(m); err != nil {
			t.Errorf("service %s: %v", name, err)
		}
	}
}

// TestGuardNoStaleWriteEntry: every registered write pattern is produced by
// some fixture under each owner it names — the register states what is
// rendered, not what might be.
func TestGuardNoStaleWriteEntry(t *testing.T) {
	fabs, svcs := buildFixtures(t)
	emitted := map[Owner]map[string]bool{OwnerFabric: {}, OwnerService: {}}
	for _, m := range fabs {
		for i := range m.Nodes {
			for _, p := range m.Nodes[i].WritePaths() {
				emitted[OwnerFabric][Normalize(p)] = true
			}
		}
	}
	for _, m := range svcs {
		for i := range m.Nodes {
			for _, p := range m.Nodes[i].WritePaths() {
				emitted[OwnerService][Normalize(p)] = true
			}
		}
	}
	for _, e := range WriteEntries() {
		for _, o := range e.Owners {
			if !emitted[o][e.Path] {
				t.Errorf("register entry %s (owner %s) is produced by no fixture", e.Path, o)
			}
		}
	}
}

// --- negative controls: the guard detects what it must ---

func TestGuardDetectsUnregisteredWritePath(t *testing.T) {
	_, svcs := buildFixtures(t)
	// Remove one registered entry: the same real render must now be refused,
	// naming the concrete path.
	const dropped = "/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/evi"
	var entries []WriteEntry
	for _, e := range WriteEntries() {
		if e.Path != dropped {
			entries = append(entries, e)
		}
	}
	var paths []string
	for i := range svcs["mac-vrf"].Nodes {
		paths = append(paths, svcs["mac-vrf"].Nodes[i].WritePaths()...)
	}
	err := checkWriteAgainst(paths, entries)
	var ue *UncoveredError
	if !errors.As(err, &ue) {
		t.Fatalf("an unregistered path passed the guard: %v", err)
	}
	if len(ue.Paths) == 0 || !strings.Contains(ue.Paths[0], "/protocols/bgp-evpn/bgp-instance[id=1]/evi") {
		t.Errorf("uncovered paths %v do not name the evi leaf", ue.Paths)
	}
	// A path no construct emits today is refused by the live register.
	if err := CheckWrite([]string{"/network-instance[name=macvrf-x]/protocols/bgp-evpn/bgp-instance[id=1]/routes/bridge-table/mac-ip/advertise"}); err == nil {
		t.Error("CheckWrite accepted an unregistered path")
	}
	// A fabric render reaching a service-only leaf is uncovered for the fabric.
	if err := checkOwned([]string{"/acl/acl-filter[name=a][type=ipv4]/description"}, OwnerFabric); err == nil {
		t.Error("a fabric render writing a service-only path passed")
	}
	// And a service render reaching a port-level leaf of the fabric (AD-68).
	if err := checkOwned([]string{"/interface[name=ethernet-1/1]/vlan-tagging"}, OwnerService); err == nil {
		t.Error("a service render writing a fabric-owned leaf passed")
	}
}

func TestGuardDetectsInvalidRegisterEntry(t *testing.T) {
	errs := validateCommon("write", "/x", OpenConfig, "", map[string]bool{})
	if len(errs) == 0 {
		t.Error("an openconfig entry without justification passed")
	}
	if errs := validateCommon("write", "/x", Native, "because", map[string]bool{}); len(errs) == 0 {
		t.Error("a native entry with a justification passed")
	}
}

func TestNormalize(t *testing.T) {
	for in, want := range map[string]string{
		"/interface[name=ethernet-1/1]/subinterface[index=100]/admin-state":                         "/interface[name=*]/subinterface[index=*]/admin-state",
		"/routing-policy/prefix-set[name=p]/prefix[ip-prefix=10.0.0.0/8][mask-length-range=32..32]": "/routing-policy/prefix-set[name=*]/prefix[ip-prefix=*][mask-length-range=*]",
		"/acl/acl-filter[name=acl-a-ingress][type=ipv4]/description":                                "/acl/acl-filter[name=*][type=*]/description",
	} {
		if got := Normalize(in); got != want {
			t.Errorf("Normalize(%s) = %s", in, got)
		}
	}
}
