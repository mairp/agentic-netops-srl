//go:build envtest

// deny-tier-force-release against a real API server (T071, T073; FR-103, CD-02): the shipped
// deploy/rbac/deny-tier-force-release.yaml and the tier's writer Role (deploy/rbac/roles.yaml) are
// installed into envtest with the first-party CRDs, and requests are made AS the tier's identities
// (impersonation, with the groups a ServiceAccount token carries) — real writes, not dry-runs, so
// that the UPDATE half is exercised: the live boundary probe (tests/integration/boundary_probes.sh)
// can only dry-run a CREATE, because persisting a Network on the lab would make the provider
// render it onto the devices.
//
// The deployer is refused whenever the object SETS, CHANGES or REMOVES
// fabric.agentic-netops.io/force-release — on CREATE (oldObject null), on UPDATE and on a merge
// PATCH — and is admitted for every write that leaves the annotation as it was (absent or with the
// same value), which is the negative control proving the refusals are the annotation's and not
// RBAC's. The cluster admin may set, change and remove it.
package boundary_test

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	"sigs.k8s.io/yaml"
)

const (
	intentNS = "agentic-netops-intent"
	tierNS   = "agentic-netops-agents"
	frKey    = "fabric.agentic-netops.io/force-release"
)

func repoRoot() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
}

// applyFile creates every document of a manifest file as the admin.
func applyFile(ctx context.Context, t *testing.T, c client.Client, path string) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range bytes.Split(append([]byte("\n"), raw...), []byte("\n---")) {
		var m map[string]any
		if err := yaml.Unmarshal(d, &m); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		if len(m) == 0 {
			continue
		}
		u := &unstructured.Unstructured{Object: m}
		if err := c.Create(ctx, u); err != nil && !apierrors.IsAlreadyExists(err) {
			t.Fatalf("%s: create %s %s: %v", path, u.GetKind(), u.GetName(), err)
		}
	}
}

func network(name string, ann map[string]string) *unstructured.Unstructured {
	u := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "fabric.agentic-netops.io/v1alpha1",
		"kind":       "Network",
		"metadata":   map[string]any{"name": name, "namespace": intentNS},
		"spec": map[string]any{
			"description": "envtest force-release admission case",
			"vlans":       []any{map[string]any{"name": "v998", "vlan": int64(998)}},
			"attachments": []any{map[string]any{"node": "leaf02", "attachment": "ethernet-1/1", "vlan": int64(998)}},
		},
	}}
	if ann != nil {
		u.SetAnnotations(ann)
	}
	return u
}

func as(t *testing.T, cfg *rest.Config, sa string) client.Client {
	t.Helper()
	c := rest.CopyConfig(cfg)
	c.Impersonate = rest.ImpersonationConfig{
		UserName: "system:serviceaccount:" + tierNS + ":" + sa,
		Groups:   []string{"system:serviceaccounts", "system:serviceaccounts:" + tierNS, "system:authenticated"},
	}
	cl, err := client.New(c, client.Options{})
	if err != nil {
		t.Fatal(err)
	}
	return cl
}

// denied reports whether err is the admission policy's refusal (not RBAC's, not anything else).
func denied(err error) bool {
	return err != nil && strings.Contains(err.Error(), "ValidatingAdmissionPolicy 'deny-tier-force-release'") &&
		strings.Contains(err.Error(), "denied request")
}

func TestDenyTierForceRelease(t *testing.T) {
	root := repoRoot()
	env := &envtest.Environment{
		CRDDirectoryPaths:     []string{filepath.Join(root, "config", "crd")},
		ErrorIfCRDPathMissing: true,
	}
	cfg, err := env.Start()
	if err != nil {
		t.Fatalf("envtest: %v", err)
	}
	t.Cleanup(func() { _ = env.Stop() })
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	admin, err := client.New(cfg, client.Options{})
	if err != nil {
		t.Fatal(err)
	}
	for _, ns := range []string{intentNS, tierNS} {
		u := &unstructured.Unstructured{Object: map[string]any{"apiVersion": "v1", "kind": "Namespace", "metadata": map[string]any{"name": ns}}}
		if err := admin.Create(ctx, u); err != nil {
			t.Fatal(err)
		}
	}
	applyFile(ctx, t, admin, filepath.Join(root, "deploy", "rbac", "roles.yaml"))
	applyFile(ctx, t, admin, filepath.Join(root, "deploy", "rbac", "deny-tier-force-release.yaml"))
	deployer := as(t, cfg, "intent-deployer")

	// The policy takes effect asynchronously: wait (bounded) until the first case is refused.
	deadline := time.Now().Add(60 * time.Second)
	for {
		err := deployer.Create(ctx, network("probe-activation", map[string]string{frKey: "x"}), client.DryRunAll)
		if denied(err) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the policy never refused the deployer's annotated create within 60s (last: %v)", err)
		}
		time.Sleep(time.Second)
	}

	type step struct {
		name      string
		who       client.Client
		do        func(c client.Client) error
		wantDeny  bool
		wantAllow bool
	}
	get := func() *unstructured.Unstructured {
		u := network("n1", nil)
		if err := admin.Get(ctx, types.NamespacedName{Namespace: intentNS, Name: "n1"}, u); err != nil {
			t.Fatal(err)
		}
		return u
	}
	setAnn := func(v *string) func(c client.Client) error {
		return func(c client.Client) error {
			u := get()
			a := u.GetAnnotations()
			if a == nil {
				a = map[string]string{}
			}
			if v == nil {
				delete(a, frKey)
			} else {
				a[frKey] = *v
			}
			u.SetAnnotations(a)
			return c.Update(ctx, u)
		}
	}
	str := func(s string) *string { return &s }
	steps := []step{
		{"deployer CREATE with the annotation (sets)", deployer, func(c client.Client) error {
			return c.Create(ctx, network("n0", map[string]string{frKey: "reason"}))
		}, true, false},
		{"deployer CREATE without it (negative control)", deployer, func(c client.Client) error {
			return c.Create(ctx, network("n1", map[string]string{"other": "v"}))
		}, false, true},
		{"deployer UPDATE adding it (sets)", deployer, setAnn(str("reason")), true, false},
		{"admin UPDATE adding it", admin, setAnn(str("r1")), false, true},
		{"deployer UPDATE of another field, annotation unchanged (negative control)", deployer, func(c client.Client) error {
			u := get()
			l := u.GetLabels()
			if l == nil {
				l = map[string]string{}
			}
			l["agentic-netops.io/correlation-id"] = "c-1"
			u.SetLabels(l)
			return c.Update(ctx, u)
		}, false, true},
		{"deployer UPDATE changing it", deployer, setAnn(str("r2")), true, false},
		{"deployer UPDATE removing it", deployer, setAnn(nil), true, false},
		{"deployer merge PATCH removing it", deployer, func(c client.Client) error {
			return c.Patch(ctx, get(), client.RawPatch(types.MergePatchType, []byte(`{"metadata":{"annotations":{"`+frKey+`":null}}}`)))
		}, true, false},
		{"deployer merge PATCH changing it", deployer, func(c client.Client) error {
			return c.Patch(ctx, get(), client.RawPatch(types.MergePatchType, []byte(`{"metadata":{"annotations":{"`+frKey+`":"r3"}}}`)))
		}, true, false},
		{"admin UPDATE changing it", admin, setAnn(str("r4")), false, true},
		{"admin UPDATE removing it", admin, setAnn(nil), false, true},
		{"deployer UPDATE with it absent before and after (negative control)", deployer, func(c client.Client) error {
			u := get()
			u.SetLabels(map[string]string{"agentic-netops.io/correlation-id": "c-2"})
			return c.Update(ctx, u)
		}, false, true},
	}
	for _, s := range steps {
		err := s.do(s.who)
		switch {
		case s.wantDeny && !denied(err):
			t.Errorf("%s: want the policy's refusal, got %v", s.name, err)
		case s.wantAllow && err != nil:
			t.Errorf("%s: want admitted, got %v", s.name, err)
		}
	}
	if a := get().GetAnnotations(); a[frKey] != "" {
		t.Errorf("after the sequence the annotation is %q, want absent (every tier write of it refused)", a[frKey])
	}
	// The allocator holds no verb on networks: its write is refused by RBAC before admission.
	alloc := as(t, cfg, "intent-allocator")
	err = alloc.Create(ctx, network("n9", nil))
	if !apierrors.IsForbidden(err) || denied(err) {
		t.Errorf("allocator create: want an RBAC Forbidden (no verb on networks), got %v", err)
	}
	var st apierrors.APIStatus
	if errors.As(err, &st) && !strings.Contains(err.Error(), "cannot create resource") {
		t.Errorf("allocator create refused for another reason: %v", err)
	}
}
