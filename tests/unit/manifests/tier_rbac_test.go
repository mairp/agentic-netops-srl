// The intent tier's safety boundary as manifests (deploy/rbac/, T068–T071; FR-075, FR-103, FR-109,
// AD-32, CD-02; contracts/kubernetes-objects.md §"Identity contract"), decoded strictly with the
// upstream types of the pinned API:
//
//   - intent-writer, in agentic-netops-intent, holds EXACTLY two rules — get, list, watch, create,
//     update, patch, delete on networks.fabric.agentic-netops.io and create on core events — and is
//     bound to intent-deployer and nothing else;
//   - no manifest under deploy/rbac/ binds intent-allocator to anything but kuid-claimer, whose
//     rules (either authority) never name networks; no ClusterRoleBinding names a tier identity;
//   - the supervisor, mapper and UI ServiceAccounts mount no token; the two API identities do;
//   - the namespaces carry the ownership and tier labels;
//   - the four NetworkPolicies, rendered as scripts/lib/rbac.sh renders them, decode strictly; the
//     scoped egress rule drops the whole management CIDR with no port list;
//   - deny-tier-force-release matches networks CREATE/UPDATE, fails closed, names both identities,
//     and its binding denies.
//
// Each check has a negative control: the same predicate refuses a mutated copy.
package manifests_test

import (
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	admissionv1 "k8s.io/api/admissionregistration/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	"sigs.k8s.io/yaml"
)

const (
	tierNS       = "agentic-netops-agents"
	intentNS     = "agentic-netops-intent"
	deployerSA   = "intent-deployer"
	allocatorSA  = "intent-allocator"
	netGroup     = "fabric.agentic-netops.io"
	forceRelease = "fabric.agentic-netops.io/force-release"
)

func rbacFile(t *testing.T, name string) string {
	t.Helper()
	return filepath.Join(repoRoot(t), "deploy", "rbac", name)
}

// kindOf returns the kind of one YAML document.
func kindOf(t *testing.T, path string, doc []byte) string {
	t.Helper()
	var tm typeMeta
	if err := yaml.Unmarshal(doc, &tm); err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	return tm.Kind
}

func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func mustWrite(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

// writerRuleProblems is the exact-rule predicate for intent-writer.
func writerRuleProblems(r rbacv1.Role) []string {
	var msgs []string
	if r.Name != "intent-writer" || r.Namespace != intentNS {
		msgs = append(msgs, "Role is "+r.Namespace+"/"+r.Name+", want "+intentNS+"/intent-writer")
	}
	if len(r.Rules) != 2 {
		msgs = append(msgs, "want exactly 2 rules (networks, events), got "+strconv.Itoa(len(r.Rules)))
	}
	want := map[[2]string][]string{
		{netGroup, "networks"}: {"create", "delete", "get", "list", "patch", "update", "watch"},
		{"", "events"}:         {"create"},
	}
	for gr, verbs := range want {
		got, ok := verbsFor(r, gr[0], gr[1])
		if !ok || !slices.Equal(got, verbs) {
			msgs = append(msgs, gr[1]+"."+gr[0]+": verbs "+strings.Join(got, ",")+", want exactly "+strings.Join(verbs, ","))
		}
	}
	for _, rule := range r.Rules {
		if len(rule.ResourceNames) > 0 || len(rule.NonResourceURLs) > 0 {
			msgs = append(msgs, "a rule is scoped by resource name or non-resource URL")
		}
		for _, x := range append(append(slices.Clone(rule.APIGroups), rule.Resources...), rule.Verbs...) {
			if x == "*" {
				msgs = append(msgs, "a wildcard in "+strings.Join(rule.Resources, ","))
			}
		}
		if len(rule.Resources) != 1 || len(rule.APIGroups) != 1 {
			msgs = append(msgs, "a rule names more than one resource or group: "+strings.Join(rule.Resources, ","))
		}
	}
	return msgs
}

func TestTierWriterRoleExact(t *testing.T) {
	path := rbacFile(t, "roles.yaml")
	var role rbacv1.Role
	var binding rbacv1.RoleBinding
	for _, d := range docs(t, path) {
		switch kindOf(t, path, d) {
		case "Role":
			strict(t, path, d, &role)
		case "RoleBinding":
			strict(t, path, d, &binding)
		default:
			t.Errorf("%s: unexpected kind %s (roles.yaml holds intent-writer only; the claim Role is claims/<authority>/role.yaml)", path, kindOf(t, path, d))
		}
	}
	for _, m := range writerRuleProblems(role) {
		t.Error("intent-writer:", m)
	}
	if binding.Name != "intent-writer" || binding.Namespace != intentNS || binding.RoleRef.Kind != "Role" || binding.RoleRef.Name != "intent-writer" {
		t.Errorf("RoleBinding %s/%s → %s %s, want %s/intent-writer → Role intent-writer", binding.Namespace, binding.Name, binding.RoleRef.Kind, binding.RoleRef.Name, intentNS)
	}
	if len(binding.Subjects) != 1 || binding.Subjects[0].Kind != "ServiceAccount" || binding.Subjects[0].Name != deployerSA || binding.Subjects[0].Namespace != tierNS {
		t.Errorf("intent-writer is bound to %+v, want exactly ServiceAccount %s/%s", binding.Subjects, tierNS, deployerSA)
	}
	// Negative controls: the predicate refuses a third rule, an added verb and a dropped one.
	extra := *role.DeepCopy()
	extra.Rules = append(extra.Rules, rbacv1.PolicyRule{APIGroups: []string{""}, Resources: []string{"secrets"}, Verbs: []string{"get"}})
	if len(writerRuleProblems(extra)) == 0 {
		t.Error("negative control: a writer Role granting get secrets was accepted")
	}
	more := *role.DeepCopy()
	more.Rules[1].Verbs = append(more.Rules[1].Verbs, "list")
	if len(writerRuleProblems(more)) == 0 {
		t.Error("negative control: list on events was accepted")
	}
	less := *role.DeepCopy()
	less.Rules[0].Verbs = []string{"get", "list", "watch", "create", "update", "delete"}
	if len(writerRuleProblems(less)) == 0 {
		t.Error("negative control: a writer Role without patch was accepted")
	}
}

// tierBindings collects every RoleBinding/ClusterRoleBinding under deploy/rbac/ (claims included).
func tierBindings(t *testing.T) (rbs []rbacv1.RoleBinding, crbs []rbacv1.ClusterRoleBinding, roles map[string]rbacv1.Role) {
	t.Helper()
	roles = map[string]rbacv1.Role{}
	files, _ := filepath.Glob(filepath.Join(repoRoot(t), "deploy", "rbac", "*.yaml"))
	more, _ := filepath.Glob(filepath.Join(repoRoot(t), "deploy", "rbac", "claims", "*", "role.yaml"))
	for _, f := range append(files, more...) {
		if strings.HasSuffix(f, "networkpolicies.yaml") {
			continue // a template (placeholders); TestTierNetworkPolicies renders it
		}
		for _, d := range docs(t, f) {
			switch kindOf(t, f, d) {
			case "RoleBinding":
				var b rbacv1.RoleBinding
				strict(t, f, d, &b)
				rbs = append(rbs, b)
			case "ClusterRoleBinding":
				var b rbacv1.ClusterRoleBinding
				strict(t, f, d, &b)
				crbs = append(crbs, b)
			case "Role":
				var r rbacv1.Role
				strict(t, f, d, &r)
				roles[f+"|"+r.Namespace+"/"+r.Name] = r
			}
		}
	}
	return rbs, crbs, roles
}

func namesTier(subjects []rbacv1.Subject, sa string) bool {
	for _, s := range subjects {
		if s.Kind == "ServiceAccount" && s.Name == sa && s.Namespace == tierNS {
			return true
		}
	}
	return false
}

func TestTierIdentitiesBoundOnlyWhereAllowed(t *testing.T) {
	rbs, crbs, roles := tierBindings(t)
	for _, b := range crbs {
		if namesTier(b.Subjects, deployerSA) || namesTier(b.Subjects, allocatorSA) {
			t.Errorf("ClusterRoleBinding %s names a tier identity: the tier holds no cluster-wide permission", b.Name)
		}
	}
	for _, b := range rbs {
		if namesTier(b.Subjects, allocatorSA) && b.RoleRef.Name != "kuid-claimer" {
			t.Errorf("RoleBinding %s/%s binds intent-allocator to %s, want only kuid-claimer", b.Namespace, b.Name, b.RoleRef.Name)
		}
		if namesTier(b.Subjects, deployerSA) && b.RoleRef.Name != "intent-writer" {
			t.Errorf("RoleBinding %s/%s binds intent-deployer to %s, want only intent-writer", b.Namespace, b.Name, b.RoleRef.Name)
		}
		if b.RoleRef.Kind != "Role" && (namesTier(b.Subjects, deployerSA) || namesTier(b.Subjects, allocatorSA)) {
			t.Errorf("RoleBinding %s/%s binds a tier identity to a %s", b.Namespace, b.Name, b.RoleRef.Kind)
		}
	}
	n := 0
	for key, r := range roles {
		if r.Name != "kuid-claimer" {
			continue
		}
		n++
		for _, rule := range r.Rules {
			if slices.Contains(rule.Resources, "networks") || slices.Contains(rule.Resources, "*") {
				t.Errorf("%s grants the allocator a verb on %s: it holds none on networks anywhere (AD-32)", key, strings.Join(rule.Resources, ","))
			}
		}
	}
	if n != 2 {
		t.Errorf("found %d kuid-claimer Roles, want 2 (one per authority, selected by the lock file)", n)
	}
}

func TestTierServiceAccountsAndNamespaces(t *testing.T) {
	path := rbacFile(t, "serviceaccounts.yaml")
	want := map[string]bool{"intent-supervisor": false, "intent-mapper": false, "intent-ui": false, allocatorSA: true, deployerSA: true}
	seen := map[string]bool{}
	for _, d := range docs(t, path) {
		var sa corev1.ServiceAccount
		strict(t, path, d, &sa)
		seen[sa.Name] = true
		w, known := want[sa.Name]
		if !known {
			t.Errorf("unexpected ServiceAccount %s", sa.Name)
			continue
		}
		if sa.Namespace != tierNS {
			t.Errorf("ServiceAccount %s in %s, want %s", sa.Name, sa.Namespace, tierNS)
		}
		if sa.AutomountServiceAccountToken == nil || *sa.AutomountServiceAccountToken != w {
			t.Errorf("ServiceAccount %s automountServiceAccountToken = %v, want explicitly %v", sa.Name, sa.AutomountServiceAccountToken, w)
		}
	}
	if len(seen) != len(want) {
		t.Errorf("ServiceAccounts %v, want exactly %v", seen, want)
	}
	nsPath := rbacFile(t, "namespaces.yaml")
	got := map[string]corev1.Namespace{}
	for _, d := range docs(t, nsPath) {
		var ns corev1.Namespace
		strict(t, nsPath, d, &ns)
		got[ns.Name] = ns
	}
	for _, name := range []string{tierNS, intentNS} {
		ns, ok := got[name]
		if !ok {
			t.Errorf("namespace %s missing", name)
			continue
		}
		if ns.Labels["agentic-netops.io/owned-by"] != "agentic-netops" || ns.Labels["agentic-netops.io/tier"] != "intent" {
			t.Errorf("namespace %s labels %v, want owned-by=agentic-netops and tier=intent", name, ns.Labels)
		}
	}
}

// renderPolicies substitutes the template's placeholders as scripts/lib/rbac.sh does.
func renderPolicies(t *testing.T) string {
	t.Helper()
	raw := string(mustRead(t, rbacFile(t, "networkpolicies.yaml")))
	return strings.NewReplacer(
		"__MGMT_CIDR__", "172.25.25.0/24", "__POD_CIDR__", "10.244.0.0/16", "__SERVICE_CIDR__", "10.96.0.0/16",
		"__APISERVER_CIDRS__", "172.30.0.3/32", "__APISERVER_PEERS__", "{ipBlock: {cidr: 172.30.0.3/32}}",
		"__APISERVER_PORT__", "6443").Replace(raw)
}

// scopedEgressProblems is the predicate for allow-egress-scoped: one ipBlock rule, 0.0.0.0/0
// except the whole management CIDR, no port list; no other rule reaches an ipBlock.
func scopedEgressProblems(p networkingv1.NetworkPolicy, mgmt string) []string {
	var msgs []string
	ipRules := 0
	for _, r := range p.Spec.Egress {
		for _, peer := range r.To {
			if peer.IPBlock == nil {
				continue
			}
			ipRules++
			if peer.IPBlock.CIDR != "0.0.0.0/0" || !slices.Contains(peer.IPBlock.Except, mgmt) {
				msgs = append(msgs, "the ipBlock rule does not drop the whole management CIDR "+mgmt)
			}
			if len(r.Ports) > 0 {
				msgs = append(msgs, "the ipBlock rule carries a port list: the management CIDR must be dropped on every port")
			}
		}
	}
	if ipRules != 1 {
		msgs = append(msgs, "want exactly one ipBlock peer")
	}
	return msgs
}

func TestTierNetworkPolicies(t *testing.T) {
	path := filepath.Join(t.TempDir(), "networkpolicies.rendered.yaml")
	mustWrite(t, path, renderPolicies(t))
	got := map[string]networkingv1.NetworkPolicy{}
	for _, d := range docs(t, path) {
		var p networkingv1.NetworkPolicy
		strict(t, path, d, &p)
		if p.Namespace != tierNS {
			t.Errorf("NetworkPolicy %s in %s, want %s", p.Name, p.Namespace, tierNS)
		}
		got[p.Name] = p
	}
	for _, n := range []string{"deny-all-by-default", "allow-egress-scoped", "slim-ingress", "apiserver-egress-cluster-clients"} {
		if _, ok := got[n]; !ok {
			t.Errorf("NetworkPolicy %s missing", n)
		}
	}
	if len(got) != 4 {
		t.Errorf("%d NetworkPolicies, want exactly the four of T070", len(got))
	}
	d := got["deny-all-by-default"]
	if len(d.Spec.PodSelector.MatchLabels)+len(d.Spec.PodSelector.MatchExpressions) != 0 || len(d.Spec.Ingress)+len(d.Spec.Egress) != 0 ||
		!slices.Equal(d.Spec.PolicyTypes, []networkingv1.PolicyType{networkingv1.PolicyTypeIngress, networkingv1.PolicyTypeEgress}) {
		t.Error("deny-all-by-default must select every pod, both directions, with no rule")
	}
	for _, m := range scopedEgressProblems(got["allow-egress-scoped"], "172.25.25.0/24") {
		t.Error("allow-egress-scoped:", m)
	}
	s := got["slim-ingress"]
	if len(s.Spec.Ingress) != 1 || len(s.Spec.Ingress[0].Ports) != 1 || s.Spec.Ingress[0].Ports[0].Port.IntValue() != 46357 ||
		s.Spec.Ingress[0].From[0].PodSelector.MatchLabels["agentic-netops.io/tier"] != "intent" {
		t.Error("slim-ingress must admit 46357 from tier-labelled pods only")
	}
	// Negative controls of the scoped-egress predicate.
	scoped := got["allow-egress-scoped"]
	bad := *scoped.DeepCopy()
	bad.Spec.Egress[0].Ports = []networkingv1.NetworkPolicyPort{{}}
	if len(scopedEgressProblems(bad, "172.25.25.0/24")) == 0 {
		t.Error("negative control: a port list on the management-CIDR rule was accepted")
	}
	open := *scoped.DeepCopy()
	open.Spec.Egress[0].To[0].IPBlock.Except = []string{"10.244.0.0/16"}
	if len(scopedEgressProblems(open, "172.25.25.0/24")) == 0 {
		t.Error("negative control: an egress rule not dropping the management CIDR was accepted")
	}
}

// vapProblems is the predicate for deny-tier-force-release.
func vapProblems(p admissionv1.ValidatingAdmissionPolicy, b admissionv1.ValidatingAdmissionPolicyBinding) []string {
	var msgs []string
	if p.Spec.FailurePolicy == nil || *p.Spec.FailurePolicy != admissionv1.Fail {
		msgs = append(msgs, "failurePolicy is not Fail")
	}
	if p.Spec.MatchConstraints == nil || len(p.Spec.MatchConstraints.ResourceRules) != 1 {
		msgs = append(msgs, "want one resource rule")
	} else {
		r := p.Spec.MatchConstraints.ResourceRules[0]
		ops := r.Operations
		if !slices.Equal(r.APIGroups, []string{netGroup}) || !slices.Equal(r.Resources, []string{"networks"}) ||
			!slices.Contains(ops, admissionv1.Create) || !slices.Contains(ops, admissionv1.Update) || len(ops) != 2 {
			msgs = append(msgs, "the rule does not match exactly networks."+netGroup+" CREATE and UPDATE")
		}
	}
	mc := ""
	for _, c := range p.Spec.MatchConditions {
		mc += c.Expression
	}
	for _, sa := range []string{deployerSA, allocatorSA} {
		if !strings.Contains(mc, "system:serviceaccount:"+tierNS+":"+sa) {
			msgs = append(msgs, "the match conditions do not name "+sa)
		}
	}
	all := mc
	for _, v := range p.Spec.Variables {
		all += v.Expression
	}
	for _, v := range p.Spec.Validations {
		all += v.Expression
	}
	for _, want := range []string{forceRelease, "oldObject != null", "has(object.metadata.annotations)", "has(oldObject.metadata.annotations)"} {
		if !strings.Contains(all, want) {
			msgs = append(msgs, "the expressions do not carry "+want)
		}
	}
	if b.Spec.PolicyName != p.Name || !slices.Equal(b.Spec.ValidationActions, []admissionv1.ValidationAction{admissionv1.Deny}) {
		msgs = append(msgs, "the binding does not Deny for "+p.Name)
	}
	return msgs
}

func TestDenyTierForceRelease(t *testing.T) {
	path := rbacFile(t, "deny-tier-force-release.yaml")
	var p admissionv1.ValidatingAdmissionPolicy
	var b admissionv1.ValidatingAdmissionPolicyBinding
	for _, d := range docs(t, path) {
		switch kindOf(t, path, d) {
		case "ValidatingAdmissionPolicy":
			strict(t, path, d, &p)
		case "ValidatingAdmissionPolicyBinding":
			strict(t, path, d, &b)
		}
	}
	if p.Name != "deny-tier-force-release" || b.Name != "deny-tier-force-release" {
		t.Fatalf("policy %q / binding %q, want deny-tier-force-release", p.Name, b.Name)
	}
	for _, m := range vapProblems(p, b) {
		t.Error(m)
	}
	warn := *b.DeepCopy()
	warn.Spec.ValidationActions = []admissionv1.ValidationAction{admissionv1.Warn}
	if len(vapProblems(p, warn)) == 0 {
		t.Error("negative control: a binding that only warns was accepted")
	}
	onlyDeployer := *p.DeepCopy()
	onlyDeployer.Spec.MatchConditions = []admissionv1.MatchCondition{{Name: "x", Expression: "request.userInfo.username == 'system:serviceaccount:" + tierNS + ":" + deployerSA + "'"}}
	if len(vapProblems(onlyDeployer, b)) == 0 {
		t.Error("negative control: a policy that does not name the allocator was accepted")
	}
}
