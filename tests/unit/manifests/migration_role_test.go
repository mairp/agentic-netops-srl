// The optional MigrationPlan controller's ClusterRole (config/rbac/migration/role.yaml, T122;
// AD-29, FR-048, data-model.md §5): exactly get, list, watch on migrationplans; get, update,
// patch on migrationplans/status; get, list, watch on networks — no create, update, patch or
// delete on networks, nor on anything else of either group — Events; bound to the provider's
// ServiceAccount; and outside the default config/rbac/kustomization.yaml.
package manifests_test

import (
	"bytes"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	rbacv1 "k8s.io/api/rbac/v1"
	"sigs.k8s.io/yaml"
)

func migrationRBAC(t *testing.T) (rbacv1.ClusterRole, rbacv1.ClusterRoleBinding) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(repoRoot(t), "config", "rbac", "migration", "role.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var role rbacv1.ClusterRole
	var binding rbacv1.ClusterRoleBinding
	for _, doc := range bytes.Split(b, []byte("\n---")) {
		var tm struct{ Kind string }
		if err := yaml.Unmarshal(doc, &tm); err != nil {
			t.Fatal(err)
		}
		switch tm.Kind {
		case "ClusterRole":
			if err := yaml.UnmarshalStrict(doc, &role); err != nil {
				t.Fatal(err)
			}
		case "ClusterRoleBinding":
			if err := yaml.UnmarshalStrict(doc, &binding); err != nil {
				t.Fatal(err)
			}
		default:
			t.Fatalf("unexpected document kind %q", tm.Kind)
		}
	}
	return role, binding
}

func TestMigrationPlanRoleIsExactly(t *testing.T) {
	role, _ := migrationRBAC(t)
	want := map[string][]string{
		"agentic-netops.io/migrationplans":        {"get", "list", "watch"},
		"agentic-netops.io/migrationplans/status": {"get", "patch", "update"},
		"fabric.agentic-netops.io/networks":       {"get", "list", "watch"},
		"/events":                                 {"create", "patch"},
		"events.k8s.io/events":                    {"create", "patch"},
	}
	got := map[string][]string{}
	for _, r := range role.Rules {
		if len(r.ResourceNames) > 0 || len(r.NonResourceURLs) > 0 {
			t.Errorf("rule %+v: resourceNames/nonResourceURLs are not part of this role", r)
		}
		for _, g := range r.APIGroups {
			for _, res := range r.Resources {
				k := g + "/" + res
				got[k] = append(got[k], r.Verbs...)
			}
		}
	}
	for k := range got {
		slices.Sort(got[k])
		got[k] = slices.Compact(got[k])
		if slices.Contains(got[k], "*") || strings.Contains(k, "*") {
			t.Errorf("%s: a wildcard is granted", k)
		}
	}
	for k, v := range want {
		if !slices.Equal(got[k], v) {
			t.Errorf("%s: verbs %v, want exactly %v", k, got[k], v)
		}
	}
	for k := range got {
		if _, ok := want[k]; !ok {
			t.Errorf("%s: granted %v, which the role does not need", k, got[k])
		}
	}
	for _, v := range []string{"create", "update", "patch", "delete", "deletecollection"} {
		if slices.Contains(got["fabric.agentic-netops.io/networks"], v) {
			t.Errorf("networks: %s granted — the controller never creates or modifies a Network (AD-29)", v)
		}
		for k, vs := range got {
			if strings.HasPrefix(k, "fabric.agentic-netops.io/networks") && slices.Contains(vs, v) {
				t.Errorf("%s: %s granted", k, v)
			}
		}
	}
}

func TestMigrationPlanRoleBoundToProvider(t *testing.T) {
	role, b := migrationRBAC(t)
	if b.RoleRef.Kind != "ClusterRole" || b.RoleRef.Name != role.Name {
		t.Fatalf("binding roleRef = %+v, want ClusterRole %s", b.RoleRef, role.Name)
	}
	if len(b.Subjects) != 1 || b.Subjects[0] != (rbacv1.Subject{Kind: "ServiceAccount", Name: "srl-provider", Namespace: "agentic-netops-system"}) {
		t.Fatalf("subjects = %+v, want only ServiceAccount agentic-netops-system/srl-provider", b.Subjects)
	}
}

// Outside the default set: applied only with config/crd/optional/ by an operator who wants it.
func TestMigrationPlanRoleNotInDefaultRBAC(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(repoRoot(t), "config", "rbac", "kustomization.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var k struct {
		Resources []string `json:"resources"`
	}
	if err := yaml.Unmarshal(b, &k); err != nil {
		t.Fatal(err)
	}
	for _, r := range k.Resources {
		if strings.Contains(r, "migration") {
			t.Errorf("config/rbac/kustomization.yaml includes %q: the MigrationPlan grant is optional (AD-29)", r)
		}
	}
	for _, f := range []string{"clusterrole.yaml", "role_system.yaml", "role_sdc.yaml"} {
		raw, err := os.ReadFile(filepath.Join(repoRoot(t), "config", "rbac", f))
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(raw, []byte("migrationplans")) {
			t.Errorf("config/rbac/%s grants migrationplans: only config/rbac/migration/ does", f)
		}
	}
}
