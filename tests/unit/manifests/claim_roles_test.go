// The provider's claim Roles, one per allocation authority, selected by the lock file at
// provisioning (config/rbac/claims/<kind>/, T042, T182; FR-075, FR-104, FR-109, AD-16):
//
//   - first-party: exactly get, list, watch, create, delete on identifierclaims in
//     agentic-netops-allocation — no update, no patch — and read-only on identifierpools;
//   - kuid: the same verbs on ipclaims, asclaims and genidclaims in kuid-system, and
//     get, list, watch, delete — no create — on vlanclaims (the tier's claim is adopted, AD-16);
//   - on neither authority does any rule grant update, patch or a wildcard.
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

// claimRole reads the Role document of config/rbac/claims/<kind>/role.yaml.
func claimRole(t *testing.T, kind string) rbacv1.Role {
	t.Helper()
	return roleAt(t, filepath.Join(repoRoot(t), "config", "rbac", "claims", kind, "role.yaml"))
}

// tierClaimRole reads the intent tier's kuid-claimer Role of deploy/rbac/claims/<kind>/role.yaml.
func tierClaimRole(t *testing.T, kind string) rbacv1.Role {
	t.Helper()
	return roleAt(t, filepath.Join(repoRoot(t), "deploy", "rbac", "claims", kind, "role.yaml"))
}

func roleAt(t *testing.T, path string) rbacv1.Role {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, doc := range bytes.Split(b, []byte("\n---")) {
		var r rbacv1.Role
		if err := yaml.UnmarshalStrict(doc, &r); err != nil {
			continue
		}
		if r.Kind == "Role" {
			return r
		}
	}
	t.Fatalf("%s: no Role", path)
	return rbacv1.Role{}
}

// verbsFor returns the sorted verbs the Role grants on group/resource, and whether any rule for
// it exists.
func verbsFor(r rbacv1.Role, group, resource string) ([]string, bool) {
	var out []string
	found := false
	for _, rule := range r.Rules {
		if slices.Contains(rule.APIGroups, group) && slices.Contains(rule.Resources, resource) {
			found = true
			out = append(out, rule.Verbs...)
		}
	}
	slices.Sort(out)
	return slices.Compact(out), found
}

func checkClaimRole(r rbacv1.Role, ns string, want map[[2]string][]string) []string {
	var msgs []string
	if r.Namespace != ns {
		msgs = append(msgs, "Role "+r.Name+" is in namespace "+r.Namespace+", not "+ns)
	}
	for gr, verbs := range want {
		got, ok := verbsFor(r, gr[0], gr[1])
		w := slices.Clone(verbs)
		slices.Sort(w)
		if !ok || !slices.Equal(got, w) {
			msgs = append(msgs, gr[1]+"."+gr[0]+": verbs "+strings.Join(got, ",")+", want exactly "+strings.Join(w, ","))
		}
	}
	for _, rule := range r.Rules {
		for _, v := range rule.Verbs {
			if v == "update" || v == "patch" || v == "*" {
				msgs = append(msgs, "a rule on "+strings.Join(rule.Resources, ",")+" grants "+v+": a claim is never moved")
			}
		}
		if slices.Contains(rule.Resources, "*") || slices.Contains(rule.APIGroups, "*") {
			msgs = append(msgs, "a rule grants a wildcard resource or group")
		}
	}
	return msgs
}

var (
	firstPartyClaimVerbs = map[[2]string][]string{
		{"fabric.agentic-netops.io", "identifierclaims"}: {"get", "list", "watch", "create", "delete"},
		{"fabric.agentic-netops.io", "identifierpools"}:  {"get", "list", "watch"},
	}
	kuidClaimVerbs = map[[2]string][]string{
		{"ipam.be.kuid.dev", "ipclaims"}:     {"get", "list", "watch", "create", "delete"},
		{"as.be.kuid.dev", "asclaims"}:       {"get", "list", "watch", "create", "delete"},
		{"genid.be.kuid.dev", "genidclaims"}: {"get", "list", "watch", "create", "delete"},
		{"vlan.be.kuid.dev", "vlanclaims"}:   {"get", "list", "watch", "delete"},
	}
)

// The tier's kuid-claimer, one per authority (T069, T182): claim objects only, no update/patch.
var (
	tierFirstPartyClaimVerbs = map[[2]string][]string{
		{"fabric.agentic-netops.io", "identifierclaims"}: {"get", "list", "watch", "create", "delete"},
	}
	tierKuidClaimVerbs = map[[2]string][]string{
		{"vlan.be.kuid.dev", "vlanclaims"}:   {"get", "list", "watch", "create", "delete"},
		{"genid.be.kuid.dev", "genidclaims"}: {"get", "list", "watch", "create", "delete"},
	}
)

func TestTierClaimRoleVerbs(t *testing.T) {
	for kind, c := range map[string]struct {
		ns   string
		want map[[2]string][]string
	}{
		"first-party": {"agentic-netops-allocation", tierFirstPartyClaimVerbs},
		"kuid":        {"kuid-system", tierKuidClaimVerbs},
	} {
		r := tierClaimRole(t, kind)
		if r.Name != "kuid-claimer" {
			t.Errorf("%s: Role is %q, want kuid-claimer", kind, r.Name)
		}
		for _, m := range checkClaimRole(r, c.ns, c.want) {
			t.Error("tier "+kind+":", m)
		}
		if len(r.Rules) != len(c.want) {
			t.Errorf("tier %s: %d rules, want exactly %d (claim objects only)", kind, len(r.Rules), len(c.want))
		}
	}
	// Negative control: the same check refuses the tier's Role granting update.
	fp := tierClaimRole(t, "first-party")
	bad := *fp.DeepCopy()
	bad.Rules[0].Verbs = append(bad.Rules[0].Verbs, "update")
	if len(checkClaimRole(bad, "agentic-netops-allocation", tierFirstPartyClaimVerbs)) == 0 {
		t.Error("a tier Role granting update on identifierclaims was accepted")
	}
}

func TestFirstPartyClaimRoleVerbs(t *testing.T) {
	for _, m := range checkClaimRole(claimRole(t, "first-party"), "agentic-netops-allocation", firstPartyClaimVerbs) {
		t.Error("first-party:", m)
	}
}

func TestKuidClaimRoleVerbs(t *testing.T) {
	for _, m := range checkClaimRole(claimRole(t, "kuid"), "kuid-system", kuidClaimVerbs) {
		t.Error("kuid:", m)
	}
}

// TestClaimRoleCheckNegativeControl: the check refuses a Role granting patch on identifierclaims,
// one missing delete, and one in another namespace.
func TestClaimRoleCheckNegativeControl(t *testing.T) {
	base := claimRole(t, "first-party")
	patched := *base.DeepCopy()
	patched.Rules[0].Verbs = append(patched.Rules[0].Verbs, "patch")
	if len(checkClaimRole(patched, "agentic-netops-allocation", firstPartyClaimVerbs)) == 0 {
		t.Error("a Role granting patch on identifierclaims was accepted")
	}
	short := *base.DeepCopy()
	short.Rules[0].Verbs = []string{"get", "list", "watch", "create"}
	if len(checkClaimRole(short, "agentic-netops-allocation", firstPartyClaimVerbs)) == 0 {
		t.Error("a Role without delete on identifierclaims was accepted")
	}
	if len(checkClaimRole(base, "kuid-system", firstPartyClaimVerbs)) == 0 {
		t.Error("a first-party Role in the wrong namespace was accepted")
	}
	creating := claimRole(t, "kuid")
	for i, rule := range creating.Rules {
		if slices.Contains(rule.Resources, "vlanclaims") {
			creating.Rules[i].Verbs = append(creating.Rules[i].Verbs, "create")
		}
	}
	if len(checkClaimRole(creating, "kuid-system", kuidClaimVerbs)) == 0 {
		t.Error("a kuid Role granting create on vlanclaims was accepted (AD-16)")
	}
}
