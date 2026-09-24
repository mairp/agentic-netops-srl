package register_test

// The path-register guard driven through the renderers themselves (T022,
// T057, FR-017): every fabric and service guard fixture is rendered by
// internal/render/srl, and the leaf paths of the documents it would emit are
// checked against the register under the Config that writes them — and are
// exactly the model's WritePaths(), which guard_test.go drives — every
// construct, access-list filters and bindings included (T107): a service's own
// list in its document, and the standalone `acl` fixture, whose document holds
// only its filters and binding entries (AD-68).

import (
	"errors"
	"regexp"
	"slices"
	"sort"
	"strings"
	"testing"

	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/render/srl"
	"github.com/mairp/agentic-netops-srl/pkg/register"
)

// identityKey strips the device's identityref qualification from a key value
// so a rendered path compares with the model's path.
var identityKey = regexp.MustCompile(`=srl_nokia-[a-z-]+:`)

func unqualified(ps []string) []string {
	out := make([]string, 0, len(ps))
	for _, p := range ps {
		out = append(out, identityKey.ReplaceAllString(p, "="))
	}
	sort.Strings(out)
	return out
}

func TestGuardRenderedFabricPathsCovered(t *testing.T) {
	for name, in := range register.FabricFixtures() {
		m, err := model.BuildFabric(in)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		for i := range m.Nodes {
			n := &m.Nodes[i]
			paths, err := srl.FabricLeafPaths(n)
			if err != nil {
				t.Fatalf("%s/%s: %v", name, n.Name, err)
			}
			if err := register.CheckFabricPaths(n.Name, paths); err != nil {
				t.Errorf("%s: %v", name, err)
			}
			if got := unqualified(paths); !slices.Equal(got, n.WritePaths()) {
				t.Errorf("%s/%s: rendered paths are not WritePaths()", name, n.Name)
			}
		}
	}
}

func TestGuardRenderedServicePathsCovered(t *testing.T) {
	rendered, acl := 0, 0
	for name, in := range register.ServiceFixtures() {
		m, err := model.BuildService(in)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		for i := range m.Nodes {
			n := &m.Nodes[i]
			paths, err := srl.ServiceLeafPaths(n)
			if err != nil {
				t.Fatalf("%s/%s: %v", name, n.Node, err)
			}
			if err := register.CheckServicePaths(n.Node, paths); err != nil {
				t.Errorf("%s: %v", name, err)
			}
			if got := unqualified(paths); !slices.Equal(got, n.WritePaths()) {
				t.Errorf("%s/%s: rendered paths are not WritePaths()", name, n.Node)
			}
			if _, err := srl.RenderServiceNode(n); err != nil {
				t.Errorf("%s/%s: %v", name, n.Node, err)
			}
			for _, p := range paths {
				if strings.HasPrefix(p, "/acl/acl-filter[") {
					acl++
					break
				}
			}
			if in.Construct == model.ConstructACL {
				for _, p := range paths {
					if !strings.HasPrefix(p, "/acl/acl-filter[") && !strings.Contains(p, "/input/acl-filter[") && !strings.Contains(p, "/output/acl-filter[") {
						t.Errorf("%s/%s: a standalone acl renders %s", name, n.Node, p)
					}
				}
			}
			rendered++
		}
	}
	if rendered == 0 || acl == 0 {
		t.Fatalf("rendered %d service nodes, %d with an access list", rendered, acl)
	}
}

// TestGuardDetectsUnregisteredACLPath: the guard refuses an access-list render
// once one of its entries is removed from the register (negative control).
func TestGuardDetectsUnregisteredACLPath(t *testing.T) {
	m, err := model.BuildService(register.ServiceFixtures()["acl-standalone"])
	if err != nil {
		t.Fatal(err)
	}
	var paths []string
	for i := range m.Nodes {
		p, err := srl.ServiceLeafPaths(&m.Nodes[i])
		if err != nil {
			t.Fatal(err)
		}
		paths = append(paths, p...)
	}
	const dropped = "/acl/interface[interface-id=*]/input/acl-filter[name=*][type=*]"
	err = register.CheckWriteWithout(paths, dropped)
	var ue *register.UncoveredError
	if !errors.As(err, &ue) {
		t.Fatalf("an access-list binding passed a register without its entry: %v", err)
	}
	if !strings.Contains(strings.Join(ue.Paths, " "), "/input/acl-filter[name=acl-acl-500-ingress]") {
		t.Errorf("the refusal does not name the binding: %v", err)
	}
	if err := register.CheckServicePaths("leaf01", paths); err != nil {
		t.Errorf("the full register refuses the standalone render: %v", err)
	}
}
