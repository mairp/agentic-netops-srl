package register_test

// The path-register guard driven through the renderers themselves (T022,
// T057, FR-017): every fabric and service guard fixture is rendered by
// internal/render/srl, and the leaf paths of the documents it would emit are
// checked against the register under the Config that writes them — and are
// exactly the model's WritePaths(), which guard_test.go drives. Access-list
// filters and bindings are User Story 5's renderer: the service renderer
// refuses them (srl.UnsupportedError), so they are stripped here and the
// standalone `acl` fixture is covered by guard_test.go alone.

import (
	"errors"
	"regexp"
	"slices"
	"sort"
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
	rendered := 0
	for name, in := range register.ServiceFixtures() {
		if in.Construct == model.ConstructACL {
			continue
		}
		withACL, err := model.BuildService(in)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if len(in.AccessLists) > 0 {
			_, err := srl.RenderService(withACL)
			var ue *srl.UnsupportedError
			if !errors.As(err, &ue) {
				t.Errorf("%s: a service with an access list was not refused as unsupported: %v", name, err)
			}
		}
		in.AccessLists = nil
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
			rendered++
		}
	}
	if rendered == 0 {
		t.Fatal("no service fixture rendered")
	}
}
