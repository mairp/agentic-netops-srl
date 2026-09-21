package sdc

import (
	"context"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"

	condv1alpha1 "github.com/sdcio/config-server/apis/condition/v1alpha1"
	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	invv1alpha1 "github.com/sdcio/config-server/apis/inv/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/apiutil"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

func newScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	return s
}

// TestUpstreamGVKs proves the objects this package reads and writes are the
// upstream types, registered under the upstream groups at the pinned version.
func TestUpstreamGVKs(t *testing.T) {
	s := newScheme(t)
	for _, tc := range []struct {
		obj  runtime.Object
		want schema.GroupVersionKind
	}{
		{&configv1alpha1.Config{}, schema.GroupVersionKind{Group: "config.sdcio.dev", Version: "v1alpha1", Kind: "Config"}},
		{&configv1alpha1.Target{}, schema.GroupVersionKind{Group: "config.sdcio.dev", Version: "v1alpha1", Kind: "Target"}},
		{&configv1alpha1.Deviation{}, schema.GroupVersionKind{Group: "config.sdcio.dev", Version: "v1alpha1", Kind: "Deviation"}},
		{&invv1alpha1.Schema{}, schema.GroupVersionKind{Group: "inv.sdcio.dev", Version: "v1alpha1", Kind: "Schema"}},
	} {
		got, err := apiutil.GVKForObject(tc.obj, s)
		if err != nil {
			t.Fatalf("%T: %v", tc.obj, err)
		}
		if got != tc.want {
			t.Errorf("%T: GVK %v, want %v", tc.obj, got, tc.want)
		}
	}
}

func req() ConfigRequest {
	return ConfigRequest{
		Source:           Source{Kind: SourceNetwork, Namespace: "agentic-netops-intent", Name: "migr-4b7e19c2a05d3f6", UID: "uid-1", Generation: 3},
		Node:             "leaf01",
		TargetNamespace:  "sdc-system",
		Priority:         PriorityService,
		Revertive:        true,
		Value:            []byte(`{"srl_nokia-interfaces:interface":[]}`),
		RenderHash:       "sha256:aaa",
		CompatibilitySet: "cs-1",
	}
}

func TestApplyConfigCreatesUpstreamConfigWithContract(t *testing.T) {
	ctx := context.Background()
	s := newScheme(t)
	fc := fake.NewClientBuilder().WithScheme(s).Build()
	c := New(fc)
	res, err := c.ApplyConfig(ctx, req())
	if err != nil || !res.Created || res.Name != "migr-4b7e19c2a05d3f6.leaf01" {
		t.Fatalf("ApplyConfig = %+v, %v", res, err)
	}
	// Read it back as the upstream type, then as unstructured-free GVK check.
	got := &configv1alpha1.Config{}
	if err := fc.Get(ctx, client.ObjectKey{Namespace: SystemNamespace, Name: res.Name}, got); err != nil {
		t.Fatal(err)
	}
	gvk, _ := apiutil.GVKForObject(got, s)
	if gvk.Group != "config.sdcio.dev" || gvk.Kind != "Config" {
		t.Errorf("stored GVK %v", gvk)
	}
	if got.Labels[LabelTargetName] != "leaf01" || got.Labels[LabelTargetNamespace] != "sdc-system" {
		t.Errorf("target labels %v", got.Labels)
	}
	if got.Labels[LabelNetworkNamespace] != "agentic-netops-intent" || got.Labels[LabelNetworkName] != "migr-4b7e19c2a05d3f6" {
		t.Errorf("ownership labels %v", got.Labels)
	}
	if got.Annotations[AnnotationSourceUID] != "uid-1" || got.Annotations[AnnotationRenderHash] != "sha256:aaa" ||
		got.Annotations[AnnotationMappingVersion] != MappingVersion || got.Annotations[AnnotationSourceGeneration] != "3" {
		t.Errorf("annotations %v", got.Annotations)
	}
	if len(got.OwnerReferences) != 0 {
		t.Errorf("a Network Config carries no ownerReferences, got %v", got.OwnerReferences)
	}
	if got.Spec.Priority != 20 || got.Spec.Revertive == nil || !*got.Spec.Revertive ||
		got.Spec.Lifecycle == nil || got.Spec.Lifecycle.DeletionPolicy != configv1alpha1.DeletionDelete ||
		len(got.Spec.Config) != 1 || got.Spec.Config[0].Path != "/" {
		t.Errorf("spec %+v", got.Spec)
	}
}

func TestApplyConfigHashShortCircuitAndUpdate(t *testing.T) {
	ctx := context.Background()
	fc := fake.NewClientBuilder().WithScheme(newScheme(t)).Build()
	c := New(fc)
	if _, err := c.ApplyConfig(ctx, req()); err != nil {
		t.Fatal(err)
	}
	before, _ := c.GetConfig(ctx, "migr-4b7e19c2a05d3f6.leaf01")
	res, err := c.ApplyConfig(ctx, req())
	if err != nil || res.Created || res.Updated {
		t.Fatalf("unchanged hash wrote: %+v %v", res, err)
	}
	after, _ := c.GetConfig(ctx, "migr-4b7e19c2a05d3f6.leaf01")
	if before.ResourceVersion != after.ResourceVersion {
		t.Errorf("unchanged hash changed resourceVersion %s -> %s", before.ResourceVersion, after.ResourceVersion)
	}
	r2 := req()
	r2.RenderHash = "sha256:bbb"
	r2.Source.Generation = 4
	res, err = c.ApplyConfig(ctx, r2)
	if err != nil || !res.Updated {
		t.Fatalf("changed hash: %+v %v", res, err)
	}
	after, _ = c.GetConfig(ctx, "migr-4b7e19c2a05d3f6.leaf01")
	if after.Annotations[AnnotationRenderHash] != "sha256:bbb" || after.Annotations[AnnotationSourceGeneration] != "4" {
		t.Errorf("annotations after update %v", after.Annotations)
	}
}

func TestApplyConfigNeverOverwritesAnotherSource(t *testing.T) {
	ctx := context.Background()
	fc := fake.NewClientBuilder().WithScheme(newScheme(t)).Build()
	c := New(fc)
	if _, err := c.ApplyConfig(ctx, req()); err != nil {
		t.Fatal(err)
	}
	r2 := req()
	r2.Source.UID = "uid-other"
	r2.RenderHash = "sha256:ccc"
	_, err := c.ApplyConfig(ctx, r2)
	if !IsOwnershipConflict(err) {
		t.Fatalf("want OwnershipConflictError, got %v", err)
	}
	if err := c.DeleteConfig(ctx, "migr-4b7e19c2a05d3f6.leaf01", "uid-other"); !IsOwnershipConflict(err) {
		t.Fatalf("delete by another source: %v", err)
	}
	if err := c.DeleteConfig(ctx, "migr-4b7e19c2a05d3f6.leaf01", "uid-1"); err != nil {
		t.Fatal(err)
	}
	if err := c.DeleteConfig(ctx, "migr-4b7e19c2a05d3f6.leaf01", "uid-1"); err != nil {
		t.Fatalf("delete of a missing config: %v", err)
	}
}

func TestBuildConfigRefusals(t *testing.T) {
	for name, mut := range map[string]func(*ConfigRequest){
		"dot in source":       func(r *ConfigRequest) { r.Source.Name = "a.b" },
		"non-revertive":       func(r *ConfigRequest) { r.Revertive = false },
		"wrong priority":      func(r *ConfigRequest) { r.Priority = 10 },
		"network owner ref":   func(r *ConfigRequest) { r.Owner = &metav1.OwnerReference{Name: "x"} },
		"no target namespace": func(r *ConfigRequest) { r.TargetNamespace = "" },
		"no render hash":      func(r *ConfigRequest) { r.RenderHash = "" },
		"no source uid":       func(r *ConfigRequest) { r.Source.UID = "" },
		"unknown source kind": func(r *ConfigRequest) { r.Source.Kind = "Other" },
	} {
		r := req()
		mut(&r)
		if _, err := BuildConfig(r); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	// A Fabric config is priority 10 and carries its owner reference.
	r := req()
	r.Source = Source{Kind: SourceFabric, Namespace: SystemNamespace, Name: "default", UID: "fuid"}
	r.Priority = PriorityFabric
	ctrl := true
	r.Owner = &metav1.OwnerReference{APIVersion: "fabric.agentic-netops.io/v1alpha1", Kind: "Fabric", Name: "default", UID: "fuid", Controller: &ctrl}
	cfg, err := BuildConfig(r)
	if err != nil || len(cfg.OwnerReferences) != 1 || cfg.Labels[LabelFabricName] != "default" {
		t.Fatalf("fabric config: %v %v", cfg, err)
	}
}

func TestListConfigsByLabel(t *testing.T) {
	ctx := context.Background()
	fc := fake.NewClientBuilder().WithScheme(newScheme(t)).Build()
	c := New(fc)
	for _, node := range []string{"leaf01", "leaf02"} {
		r := req()
		r.Node = node
		if _, err := c.ApplyConfig(ctx, r); err != nil {
			t.Fatal(err)
		}
	}
	other := req()
	other.Source.Name, other.Source.UID = "svc2", "uid-2"
	if _, err := c.ApplyConfig(ctx, other); err != nil {
		t.Fatal(err)
	}
	got, err := c.ListConfigsForNetwork(ctx, "agentic-netops-intent", "migr-4b7e19c2a05d3f6")
	if err != nil || len(got) != 2 {
		t.Fatalf("ListConfigsForNetwork = %d, %v", len(got), err)
	}
	got, err = c.ListConfigsForTarget(ctx, "sdc-system", "leaf01")
	if err != nil || len(got) != 2 {
		t.Fatalf("ListConfigsForTarget = %d, %v", len(got), err)
	}
}

func readyCond(typ condv1alpha1.ConditionType, st metav1.ConditionStatus) condv1alpha1.Condition {
	return condv1alpha1.Condition{Condition: metav1.Condition{Type: string(typ), Status: st, Reason: "x", LastTransitionTime: metav1.Now()}}
}

func TestTargetReadinessUsesUpstreamConditions(t *testing.T) {
	ctx := context.Background()
	ready := &configv1alpha1.Target{ObjectMeta: metav1.ObjectMeta{Namespace: "sdc-system", Name: "leaf01"}}
	ready.SetConditions(
		readyCond(condv1alpha1.ConditionTypeReady, metav1.ConditionTrue),
		readyCond(configv1alpha1.ConditionTypeTargetDiscoveryReady, metav1.ConditionTrue),
		readyCond(configv1alpha1.ConditionTypeTargetDatastoreReady, metav1.ConditionTrue),
		readyCond(configv1alpha1.ConditionTypeTargetConnectionReady, metav1.ConditionTrue),
	)
	notReady := &configv1alpha1.Target{ObjectMeta: metav1.ObjectMeta{Namespace: "sdc-system", Name: "leaf02"}}
	notReady.SetConditions(readyCond(condv1alpha1.ConditionTypeReady, metav1.ConditionTrue),
		readyCond(configv1alpha1.ConditionTypeTargetConnectionReady, metav1.ConditionFalse))
	fc := fake.NewClientBuilder().WithScheme(newScheme(t)).WithObjects(ready, notReady).Build()
	c := New(fc)
	r, err := c.TargetReady(ctx, "sdc-system", "leaf01")
	if err != nil || !r.Ready {
		t.Fatalf("leaf01: %+v %v", r, err)
	}
	r, err = c.TargetReady(ctx, "sdc-system", "leaf02")
	if err != nil || r.Ready || r.Reason == "" {
		t.Fatalf("leaf02: %+v %v", r, err)
	}
	if _, err := c.TargetReady(ctx, "sdc-system", "missing"); err == nil {
		t.Fatal("a missing target must be an error, not a not-Ready report")
	}
	ts, err := c.ListTargets(ctx, "sdc-system")
	if err != nil || len(ts) != 2 {
		t.Fatalf("ListTargets = %d %v", len(ts), err)
	}
}

func TestSchemaAndDeviationReads(t *testing.T) {
	ctx := context.Background()
	sch := &invv1alpha1.Schema{ObjectMeta: metav1.ObjectMeta{Namespace: "sdc-system", Name: "srl.nokia.sdcio.dev-25.10.1"},
		Spec: invv1alpha1.SchemaSpec{Provider: "srl.nokia.sdcio.dev", Version: "25.10.1"}}
	sch.SetConditions(readyCond(condv1alpha1.ConditionTypeReady, metav1.ConditionTrue))
	dev := &configv1alpha1.Deviation{
		ObjectMeta: metav1.ObjectMeta{Namespace: SystemNamespace,
			Name:   configv1alpha1.DeviationName(configv1alpha1.DeviationType_CONFIG, "svc.leaf01"),
			Labels: map[string]string{LabelTargetName: "leaf01", LabelTargetNamespace: "sdc-system"}},
		Spec: configv1alpha1.DeviationSpec{Deviations: []configv1alpha1.ConfigDeviation{
			{Path: "/b", Reason: DeviationOverruled}, {Path: "/a", Reason: DeviationOverruled}, {Path: "/c", Reason: DeviationNotApplied},
		}},
	}
	fc := fake.NewClientBuilder().WithScheme(newScheme(t)).WithObjects(sch, dev).Build()
	c := New(fc)
	got, err := c.FindSchema(ctx, "sdc-system", "srl.nokia.sdcio.dev", "25.10.1")
	if err != nil || got == nil {
		t.Fatalf("FindSchema = %v %v", got, err)
	}
	if got, _ := c.FindSchema(ctx, "sdc-system", "srl.nokia.sdcio.dev", "0.0"); got != nil {
		t.Fatal("found a schema of another version")
	}
	d, err := c.GetConfigDeviation(ctx, "svc.leaf01")
	if err != nil || d == nil {
		t.Fatalf("GetConfigDeviation = %v %v", d, err)
	}
	if p := PathsWithReason(d, DeviationOverruled); len(p) != 2 || p[0] != "/a" || p[1] != "/b" {
		t.Errorf("overruled paths %v", p)
	}
	if d, err := c.GetConfigDeviation(ctx, "none.leaf01"); d != nil || err != nil {
		t.Errorf("missing deviation = %v %v", d, err)
	}
	ds, err := c.ListDeviationsForTarget(ctx, SystemNamespace, "sdc-system", "leaf01")
	if err != nil || len(ds) != 1 {
		t.Fatalf("ListDeviationsForTarget = %d %v", len(ds), err)
	}
}

// TestNoUpstreamKindRedeclared scans every Go file of this package for a struct
// type that re-declares an upstream Kind (FR-013, FR-098).
func TestNoUpstreamKindRedeclared(t *testing.T) {
	upstream := map[string]bool{}
	for _, k := range []string{"Config", "ConfigSet", "RunningConfig", "Deviation", "ConfigBlame", "Target", "Schema",
		"TargetConnectionProfile", "TargetSyncProfile", "DiscoveryRule", "DiscoveryVendorProfile", "Subscription", "Rollout", "Workspace"} {
		upstream[strings.ToLower(k)] = true
		upstream[strings.ToLower(k)+"list"] = true
		upstream[strings.ToLower(k)+"spec"] = true
		upstream[strings.ToLower(k)+"status"] = true
	}
	files, err := filepath.Glob("*.go")
	if err != nil || len(files) == 0 {
		t.Fatalf("glob: %v", err)
	}
	fset := token.NewFileSet()
	for _, f := range files {
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		af, err := parser.ParseFile(fset, f, src, 0)
		if err != nil {
			t.Fatal(err)
		}
		ast.Inspect(af, func(n ast.Node) bool {
			ts, ok := n.(*ast.TypeSpec)
			if !ok {
				return true
			}
			if _, isStruct := ts.Type.(*ast.StructType); isStruct && upstream[strings.ToLower(ts.Name.Name)] {
				t.Errorf("%s: type %s struct re-declares an upstream Kind", f, ts.Name.Name)
			}
			return true
		})
	}
}

// TestApplyConfigIsServerSideApplyUnderTheFieldManager proves ApplyConfig is a
// server-side apply owned by the dedicated field manager (contracts/crd-api.md,
// Rule 4), and that an unchanged render hash sends no request at all.
func TestApplyConfigIsServerSideApplyUnderTheFieldManager(t *testing.T) {
	ctx := context.Background()
	var applies, writes int
	fc := fake.NewClientBuilder().WithScheme(newScheme(t)).WithReturnManagedFields().
		WithInterceptorFuncs(interceptor.Funcs{
			Apply: func(ctx context.Context, c client.WithWatch, obj runtime.ApplyConfiguration, opts ...client.ApplyOption) error {
				applies++
				return c.Apply(ctx, obj, opts...)
			},
			Create: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.CreateOption) error {
				writes++
				return c.Create(ctx, obj, opts...)
			},
			Update: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.UpdateOption) error {
				writes++
				return c.Update(ctx, obj, opts...)
			},
		}).Build()
	c := New(fc)
	if _, err := c.ApplyConfig(ctx, req()); err != nil {
		t.Fatal(err)
	}
	got, err := c.GetConfig(ctx, "migr-4b7e19c2a05d3f6.leaf01")
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, mf := range got.ManagedFields {
		if mf.Manager == FieldManager && mf.Operation == metav1.ManagedFieldsOperationApply {
			found = true
		}
	}
	if !found {
		t.Errorf("no Apply managedFields entry for %q: %+v", FieldManager, got.ManagedFields)
	}
	if _, err := c.ApplyConfig(ctx, req()); err != nil {
		t.Fatal(err)
	}
	if applies != 1 || writes != 0 {
		t.Errorf("applies=%d writes=%d; want 1 apply for the create, none for an unchanged hash, no Create/Update", applies, writes)
	}
	r2 := req()
	r2.RenderHash = "sha256:ddd"
	if _, err := c.ApplyConfig(ctx, r2); err != nil {
		t.Fatal(err)
	}
	if applies != 2 {
		t.Errorf("changed hash: applies=%d, want 2", applies)
	}
}
