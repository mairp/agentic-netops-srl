//go:build envtest

// T122: the optional MigrationPlan controller (controllers/migration) against a real API server
// (envtest) with RBAC enforced. The controller runs in a manager whose client IMPERSONATES the
// provider's ServiceAccount, agentic-netops-system/srl-provider, bound only to the ClusterRole of
// config/rbac/migration/role.yaml (applied from that file) — so every pass below also proves it
// works under that role, and the role's denials prove it cannot write a Network. Asserted:
//
//   - registration: before the optional CRD is installed, discovery reports the MigrationPlan
//     not served (the provider registers nothing); after, served;
//   - a plan before its Network: no Network is created, generatedNetworkRef stays nil and
//     Ready=False/NotConverged says it waits for the Network to be applied;
//   - the Network applied (as translator output, provenance annotations included) by someone
//     else: generatedNetworkRef filled, construct + sourceVocabulary recorded,
//     provenanceRef naming annotation keys only — never a value — and the Network's
//     resourceVersion and generation untouched by the controller;
//   - VPWS without the opt-in: unsupportedFeatures + Translated=False/UnsupportedFeature;
//     VPWS with it: Translated=True carrying the limited-equivalence finding;
//   - a Network whose provenance disagrees: Translated=False/Collision naming the keys;
//   - cutover defaults to disabled, limited equivalence to false;
//   - the impersonated identity is Forbidden to create, update, patch, delete and
//     delete-collection Networks, and to update a plan's spec;
//   - every examples/migrations/*.yaml is accepted by the CRD (server-side dry-run create).
//
// Run: make test-envtest (scripts/ci/test_envtest.sh → go test -tags envtest ./tests/envtest/...).
package migration_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	utilyaml "k8s.io/apimachinery/pkg/util/yaml"
	"k8s.io/client-go/discovery"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/yaml"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	migrationv1 "github.com/mairp/agentic-netops-srl/api/v1alpha1"
	"github.com/mairp/agentic-netops-srl/controllers/migration"
	"github.com/mairp/agentic-netops-srl/internal/status"
	vocab "github.com/mairp/agentic-netops-srl/pkg/migration"
)

const (
	ns          = "agentic-netops-services"
	nsSystem    = "agentic-netops-system"
	providerSA  = "system:serviceaccount:agentic-netops-system:srl-provider"
	inputHash   = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	timeout     = 30 * time.Second
	pollEvery   = 100 * time.Millisecond
	settleDelay = 2 * time.Second
)

var (
	admin    client.Client // the test's own (cluster-admin) identity: applies Networks and plans
	provider client.Client // the impersonated provider identity, bound only to the migration role
	repoRoot string

	// Discovery before and after the optional CRD is installed (TestMain).
	servedBefore, servedAfter bool
	servedErr                 error
)

func TestMain(m *testing.M) {
	_, file, _, _ := runtime.Caller(0)
	repoRoot = filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	// The default CRDs only: the optional MigrationPlan is installed below, after discovery has
	// been asked whether it is served.
	env := &envtest.Environment{
		CRDDirectoryPaths:     []string{filepath.Join(repoRoot, "config", "crd")},
		ErrorIfCRDPathMissing: true,
	}
	cfg, err := env.Start()
	if err != nil {
		fmt.Fprintf(os.Stderr, "envtest: starting the control plane (is KUBEBUILDER_ASSETS set?): %v\n", err)
		os.Exit(1)
	}
	ctx, cancel := context.WithCancel(context.Background())
	code := func() int {
		fail := func(err error) int { fmt.Fprintln(os.Stderr, "envtest:", err); return 1 }
		disco, err := discovery.NewDiscoveryClientForConfig(cfg)
		if err != nil {
			return fail(err)
		}
		if servedBefore, servedErr = migration.Served(disco); servedErr != nil {
			return fail(servedErr)
		}
		if _, err := envtest.InstallCRDs(cfg, envtest.CRDInstallOptions{
			Paths: []string{filepath.Join(repoRoot, "config", "crd", "optional")}, ErrorIfPathMissing: true,
		}); err != nil {
			return fail(fmt.Errorf("installing config/crd/optional: %w", err))
		}
		deadline := time.Now().Add(timeout)
		for !servedAfter && time.Now().Before(deadline) {
			if servedAfter, servedErr = migration.Served(disco); servedErr != nil {
				return fail(servedErr)
			}
			if !servedAfter {
				time.Sleep(pollEvery)
			}
		}

		scheme := k8sruntime.NewScheme()
		for _, add := range []func(*k8sruntime.Scheme) error{clientgoscheme.AddToScheme, fabricv1.AddToScheme, migrationv1.AddToScheme} {
			if err := add(scheme); err != nil {
				return fail(err)
			}
		}
		if admin, err = client.New(cfg, client.Options{Scheme: scheme}); err != nil {
			return fail(err)
		}
		for _, n := range []string{ns, nsSystem} {
			if err := admin.Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: n}}); err != nil {
				return fail(err)
			}
		}
		if err := applyRBAC(ctx, filepath.Join(repoRoot, "config", "rbac", "migration", "role.yaml")); err != nil {
			return fail(err)
		}

		// The provider's identity: impersonated, so the API server authorizes every request of
		// the controller against config/rbac/migration/role.yaml alone.
		pcfg := rest.CopyConfig(cfg)
		pcfg.Impersonate = rest.ImpersonationConfig{UserName: providerSA}
		if provider, err = client.New(pcfg, client.Options{Scheme: scheme}); err != nil {
			return fail(err)
		}
		mgr, err := ctrl.NewManager(pcfg, ctrl.Options{Scheme: scheme, Metrics: metricsserver.Options{BindAddress: "0"},
			HealthProbeBindAddress: "0", LeaderElection: false})
		if err != nil {
			return fail(err)
		}
		r := &migration.Reconciler{Client: mgr.GetClient(), Recorder: mgr.GetEventRecorderFor("srl-provider")} //nolint:staticcheck // as cmd/srl-provider
		if err := r.SetupWithManager(mgr); err != nil {
			return fail(err)
		}
		done := make(chan struct{})
		go func() {
			defer close(done)
			if err := mgr.Start(ctx); err != nil {
				fmt.Fprintln(os.Stderr, "manager:", err)
			}
		}()
		code := m.Run()
		cancel()
		<-done
		return code
	}()
	cancel()
	_ = env.Stop()
	os.Exit(code)
}

// applyRBAC creates every document of a manifest file with the admin identity.
func applyRBAC(ctx context.Context, path string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	dec := utilyaml.NewYAMLOrJSONDecoder(bytes.NewReader(raw), 4096)
	for {
		obj := map[string]any{}
		if err := dec.Decode(&obj); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return fmt.Errorf("%s: %w", path, err)
		}
		if len(obj) == 0 {
			continue
		}
		if err := admin.Create(ctx, &unstructured.Unstructured{Object: obj}); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
	}
}

// ---------------------------------------------------------------------------------------------
// Fixtures and helpers.

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

type planOpt func(*migrationv1.MigrationPlan)

func optIn(p *migrationv1.MigrationPlan) {
	v := true
	p.Spec.MappingPolicy.AllowLimitedEquivalence = &v
}

func plan(t *testing.T, name, serviceType, network string, opts ...planOpt) *migrationv1.MigrationPlan {
	t.Helper()
	p := &migrationv1.MigrationPlan{
		ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name},
		Spec: migrationv1.MigrationPlanSpec{
			Source: migrationv1.MigrationSource{
				Platform: "legacy-router", ServiceType: migrationv1.SourceServiceType(serviceType), ServiceID: "legacy/" + name,
				NormalizedIntent: migrationv1.NormalizedIntent{Tenant: "tenant-a", Endpoints: []migrationv1.MigrationEndpoint{
					{Node: "leaf01", Attachment: "ethernet-1/1"}, {Node: "leaf02", Attachment: "ethernet-1/1"}}},
			},
			TargetNetworkRef: migrationv1.NetworkReference{Name: network},
		},
	}
	for _, o := range opts {
		o(p)
	}
	must(t, admin.Create(context.Background(), p))
	t.Cleanup(func() { _ = admin.Delete(context.Background(), p) })
	return p
}

// macvrfNetwork is the translator's output for a folded alias: a valid mac-vrf Network carrying
// the provenance annotations (pkg/migration, network-spec.md §3).
func macvrfNetwork(t *testing.T, name string, vlan int, ann map[string]string) *fabricv1.Network {
	t.Helper()
	doc := fmt.Sprintf(`
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
metadata: {name: %[1]s, namespace: %[2]s}
spec:
  description: migrated mac-vrf vlan %[3]d
  bridgeDomains:
  - name: bd%[3]d
    vlan: %[3]d
    l2vni: 10%[3]d
    evpn:
      routeTargets:
        import: ["target:65000:10%[3]d"]
        export: ["target:65000:10%[3]d"]
  attachments:
  - {node: leaf01, attachment: ethernet-1/1, vlan: %[3]d}
  - {node: leaf02, attachment: ethernet-1/1, vlan: %[3]d}
`, name, ns, vlan)
	n := &fabricv1.Network{}
	must(t, yaml.UnmarshalStrict([]byte(doc), n))
	n.Annotations = ann
	must(t, admin.Create(context.Background(), n))
	t.Cleanup(func() { _ = admin.Delete(context.Background(), n) })
	return n
}

func translatorAnnotations(construct, source string) map[string]string {
	a := map[string]string{
		vocab.AnnotationTranslator:        vocab.TranslatorName,
		vocab.AnnotationTranslatorVersion: vocab.TranslatorVersion,
		vocab.AnnotationMappingVersion:    vocab.MappingVersion,
		vocab.AnnotationInputHash:         inputHash,
		vocab.AnnotationTenant:            "tenant-a",
		vocab.AnnotationServiceType:       construct,
		vocab.AnnotationSourceServiceType: source,
	}
	return a
}

// eventually polls the plan (read by the admin identity) until check passes.
func eventually(t *testing.T, name string, check func(*migrationv1.MigrationPlan) error) *migrationv1.MigrationPlan {
	t.Helper()
	var last error
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		p := &migrationv1.MigrationPlan{}
		must(t, admin.Get(context.Background(), types.NamespacedName{Namespace: ns, Name: name}, p))
		if last = check(p); last == nil {
			return p
		}
		time.Sleep(pollEvery)
	}
	t.Fatalf("plan %s: %v", name, last)
	return nil
}

func condition(p *migrationv1.MigrationPlan, typ string, st metav1.ConditionStatus, reason string) error {
	c := meta.FindStatusCondition(p.Status.Conditions, typ)
	if c == nil {
		return fmt.Errorf("no %s condition yet: %+v", typ, p.Status.Conditions)
	}
	if c.Status != st || c.Reason != reason {
		return fmt.Errorf("%s = %s/%s (%s), want %s/%s", typ, c.Status, c.Reason, c.Message, st, reason)
	}
	if c.ObservedGeneration != p.Generation {
		return fmt.Errorf("%s observedGeneration %d, generation %d", typ, c.ObservedGeneration, p.Generation)
	}
	return nil
}

func message(p *migrationv1.MigrationPlan, typ string) string {
	if c := meta.FindStatusCondition(p.Status.Conditions, typ); c != nil {
		return c.Message
	}
	return ""
}

// ---------------------------------------------------------------------------------------------
// Registration.

func TestRegistrationOnlyWhenCRDServed(t *testing.T) {
	if servedErr != nil {
		t.Fatal(servedErr)
	}
	if servedBefore {
		t.Error("discovery reports migrationplans served before config/crd/optional is installed: the controller would register")
	}
	if !servedAfter {
		t.Error("discovery does not report migrationplans served after config/crd/optional is installed")
	}
}

// ---------------------------------------------------------------------------------------------
// Recording.

func TestPlanBeforeNetworkThenNetworkApplied(t *testing.T) {
	ctx := context.Background()
	plan(t, "vpls-a", "VPLS", "net-vpls-a")
	p := eventually(t, "vpls-a", func(p *migrationv1.MigrationPlan) error {
		if err := condition(p, status.Ready, metav1.ConditionFalse, status.ReasonNotConverged); err != nil {
			return err
		}
		return condition(p, status.Translated, metav1.ConditionTrue, status.ReasonAsExpected)
	})
	if p.Status.GeneratedNetworkRef != nil || p.Status.ProvenanceRef != nil {
		t.Fatalf("a reference recorded before the Network exists: %+v %+v", p.Status.GeneratedNetworkRef, p.Status.ProvenanceRef)
	}
	if m := message(p, status.Ready); !strings.Contains(m, "waiting for Network "+ns+"/net-vpls-a to be applied") || !strings.Contains(m, "never creates it") {
		t.Errorf("Ready message = %q", m)
	}
	if p.Status.Construct != migrationv1.Construct(vocab.ConstructMACVRF) || p.Status.SourceVocabulary != "VPLS" {
		t.Errorf("construct/sourceVocabulary = %q/%q, want mac-vrf/VPLS", p.Status.Construct, p.Status.SourceVocabulary)
	}
	time.Sleep(settleDelay) // give a (wrong) controller the chance to create it
	nets := &fabricv1.NetworkList{}
	must(t, admin.List(ctx, nets))
	for _, n := range nets.Items {
		if n.Name == "net-vpls-a" {
			t.Fatalf("Network %s/%s exists: the controller never creates one", n.Namespace, n.Name)
		}
	}

	// The translator's output is applied — by someone else.
	net := macvrfNetwork(t, "net-vpls-a", 130, translatorAnnotations(vocab.ConstructMACVRF, "VPLS"))
	rv, gen := net.ResourceVersion, net.Generation
	p = eventually(t, "vpls-a", func(p *migrationv1.MigrationPlan) error {
		if p.Status.GeneratedNetworkRef == nil {
			return errors.New("generatedNetworkRef not filled in")
		}
		return nil
	})
	if *p.Status.GeneratedNetworkRef != (migrationv1.NetworkReference{Name: "net-vpls-a", Namespace: ns}) {
		t.Errorf("generatedNetworkRef = %+v", *p.Status.GeneratedNetworkRef)
	}
	if p.Status.ProvenanceRef == nil || p.Status.ProvenanceRef.Network != *p.Status.GeneratedNetworkRef {
		t.Fatalf("provenanceRef = %+v", p.Status.ProvenanceRef)
	}
	if want := []string{vocab.AnnotationServiceType, vocab.AnnotationSourceServiceType}; !slices.Equal(p.Status.ProvenanceRef.AnnotationKeys, want) {
		t.Errorf("provenanceRef.annotationKeys = %v, want %v", p.Status.ProvenanceRef.AnnotationKeys, want)
	}
	// Keys only: no annotation value of the Network is restated anywhere in the plan's status.
	st, _ := json.Marshal(p.Status)
	for _, v := range []string{vocab.TranslatorName, inputHash, vocab.TranslatorVersion} {
		if bytes.Contains(st, []byte(v)) {
			t.Errorf("status restates the annotation value %q: %s", v, st)
		}
	}
	// Ready is the Network's, which has none yet: still not Ready, now for that reason.
	if m := message(p, status.Ready); strings.Contains(m, "waiting") {
		t.Errorf("Ready still says waiting once the Network exists: %q", m)
	}
	time.Sleep(settleDelay)
	got := &fabricv1.Network{}
	must(t, admin.Get(ctx, client.ObjectKeyFromObject(net), got))
	if got.ResourceVersion != rv || got.Generation != gen || len(got.Finalizers) != 0 {
		t.Errorf("the Network was modified: resourceVersion %s→%s, generation %d→%d, finalizers %v", rv, got.ResourceVersion, gen, got.Generation, got.Finalizers)
	}
}

func TestVPWSWithoutOptInUnsupported(t *testing.T) {
	plan(t, "vpws-no", "VPWS", "net-vpws-no")
	p := eventually(t, "vpws-no", func(p *migrationv1.MigrationPlan) error {
		return condition(p, status.Translated, metav1.ConditionFalse, status.ReasonUnsupportedFeature)
	})
	want := []migrationv1.UnsupportedFeature{{Code: migration.CodeLimitedEquivalenceNotAllowed, FieldPath: "spec.mappingPolicy.allowLimitedEquivalence"}}
	if len(p.Status.UnsupportedFeatures) != 1 || p.Status.UnsupportedFeatures[0].Code != want[0].Code ||
		p.Status.UnsupportedFeatures[0].FieldPath != want[0].FieldPath || p.Status.UnsupportedFeatures[0].Message == "" {
		t.Fatalf("unsupportedFeatures = %+v, want %+v (with a message)", p.Status.UnsupportedFeatures, want)
	}
}

func TestVPWSWithOptInLimitedEquivalence(t *testing.T) {
	ann := translatorAnnotations(vocab.ConstructMACVRF, "VPWS")
	ann[vocab.AnnotationLimitedEquivalence] = "vpws-to-mac-vrf"
	macvrfNetwork(t, "net-vpws-yes", 140, ann)
	plan(t, "vpws-yes", "VPWS", "net-vpws-yes", optIn)
	p := eventually(t, "vpws-yes", func(p *migrationv1.MigrationPlan) error {
		if p.Status.ProvenanceRef == nil {
			return errors.New("provenanceRef not recorded")
		}
		return condition(p, status.Translated, metav1.ConditionTrue, status.ReasonAsExpected)
	})
	if len(p.Status.UnsupportedFeatures) != 0 {
		t.Errorf("unsupportedFeatures = %+v", p.Status.UnsupportedFeatures)
	}
	m := message(p, status.Translated)
	if !strings.Contains(m, migration.LimitedEquivalenceFinding) || !strings.Contains(m, vocab.AnnotationLimitedEquivalence) || strings.Contains(m, "vpws-to-mac-vrf") {
		t.Errorf("Translated message = %q: want the limited-equivalence finding by key, not by value", m)
	}
	if !slices.Contains(p.Status.ProvenanceRef.AnnotationKeys, vocab.AnnotationLimitedEquivalence) {
		t.Errorf("annotationKeys = %v, want %s among them", p.Status.ProvenanceRef.AnnotationKeys, vocab.AnnotationLimitedEquivalence)
	}
	if p.Status.Construct != migrationv1.Construct(vocab.ConstructMACVRF) || p.Status.SourceVocabulary != "VPWS" {
		t.Errorf("construct/sourceVocabulary = %q/%q", p.Status.Construct, p.Status.SourceVocabulary)
	}
}

func TestProvenanceCollision(t *testing.T) {
	macvrfNetwork(t, "net-collide", 150, translatorAnnotations(vocab.ConstructIPVRF, "L3VPN"))
	plan(t, "collide", "VPLS", "net-collide")
	p := eventually(t, "collide", func(p *migrationv1.MigrationPlan) error {
		return condition(p, status.Translated, metav1.ConditionFalse, status.ReasonCollision)
	})
	m := message(p, status.Translated)
	for _, k := range []string{vocab.AnnotationServiceType, vocab.AnnotationSourceServiceType} {
		if !strings.Contains(m, k) {
			t.Errorf("Collision message does not name %s: %q", k, m)
		}
	}
	if p.Status.GeneratedNetworkRef == nil {
		t.Error("generatedNetworkRef not recorded for an existing Network")
	}
}

func TestCutoverDefaultsDisabled(t *testing.T) {
	plan(t, "defaults", "L3VPN", "net-defaults", func(p *migrationv1.MigrationPlan) {
		p.Spec.Source.NormalizedIntent.Prefixes = []migrationv1.MigrationPrefix{"10.30.0.0/24"}
	})
	got := &migrationv1.MigrationPlan{}
	must(t, admin.Get(context.Background(), types.NamespacedName{Namespace: ns, Name: "defaults"}, got))
	if got.Spec.MappingPolicy.Cutover != "disabled" {
		t.Errorf("spec.mappingPolicy.cutover = %q, want disabled by default", got.Spec.MappingPolicy.Cutover)
	}
	if got.Spec.MappingPolicy.AllowLimitedEquivalence == nil || *got.Spec.MappingPolicy.AllowLimitedEquivalence {
		t.Errorf("spec.mappingPolicy.allowLimitedEquivalence = %v, want false by default", got.Spec.MappingPolicy.AllowLimitedEquivalence)
	}
	p := eventually(t, "defaults", func(p *migrationv1.MigrationPlan) error {
		return condition(p, status.Accepted, metav1.ConditionTrue, status.ReasonAsExpected)
	})
	if m := message(p, status.Accepted); !strings.Contains(m, "cutover disabled") || !strings.Contains(m, migration.NoCutover) {
		t.Errorf("Accepted message = %q", m)
	}
	if p.Status.Construct != migrationv1.Construct(vocab.ConstructIPVRF) || p.Status.SourceVocabulary != "L3VPN" {
		t.Errorf("construct/sourceVocabulary = %q/%q", p.Status.Construct, p.Status.SourceVocabulary)
	}
}

// ---------------------------------------------------------------------------------------------
// The role: the impersonated provider identity cannot write a Network.

func TestProviderIdentityCannotWriteNetworks(t *testing.T) {
	ctx := context.Background()
	existing := macvrfNetwork(t, "net-rbac", 160, translatorAnnotations(vocab.ConstructMACVRF, "VPLS"))

	// Reading is granted.
	must(t, provider.Get(ctx, client.ObjectKeyFromObject(existing), &fabricv1.Network{}))
	must(t, provider.List(ctx, &fabricv1.NetworkList{}))

	forbidden := func(verb string, err error) {
		t.Helper()
		if !apierrors.IsForbidden(err) {
			t.Errorf("%s a Network as %s: %v, want Forbidden", verb, providerSA, err)
		}
	}
	fresh := existing.DeepCopy()
	fresh.ObjectMeta = metav1.ObjectMeta{Namespace: ns, Name: "net-rbac-new"}
	forbidden("create", provider.Create(ctx, fresh))

	upd := &fabricv1.Network{}
	must(t, admin.Get(ctx, client.ObjectKeyFromObject(existing), upd))
	upd.Annotations["example.com/touched"] = "yes"
	forbidden("update", provider.Update(ctx, upd))

	patch := client.RawPatch(types.MergePatchType, []byte(`{"metadata":{"labels":{"touched":"yes"}}}`))
	forbidden("patch", provider.Patch(ctx, existing.DeepCopy(), patch))
	forbidden("patch status of", provider.Status().Patch(ctx, existing.DeepCopy(), client.RawPatch(types.MergePatchType, []byte(`{"status":{"observedGeneration":7}}`))))
	forbidden("delete", provider.Delete(ctx, existing.DeepCopy()))
	forbidden("delete-collection", provider.DeleteAllOf(ctx, &fabricv1.Network{}, client.InNamespace(ns)))

	// Nor a plan's spec: status updates only.
	p := plan(t, "rbac-plan", "VPLS", "net-rbac")
	got := &migrationv1.MigrationPlan{}
	must(t, admin.Get(ctx, client.ObjectKeyFromObject(p), got))
	got.Spec.MappingPolicy.Cutover = "manual"
	if err := provider.Update(ctx, got); !apierrors.IsForbidden(err) {
		t.Errorf("update a MigrationPlan's spec as %s: %v, want Forbidden", providerSA, err)
	}
	if err := provider.Create(ctx, &migrationv1.MigrationPlan{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: "x"}, Spec: got.Spec}); !apierrors.IsForbidden(err) {
		t.Errorf("create a MigrationPlan as %s: %v, want Forbidden", providerSA, err)
	}

	after := &fabricv1.Network{}
	must(t, admin.Get(ctx, client.ObjectKeyFromObject(existing), after))
	if after.ResourceVersion != existing.ResourceVersion {
		t.Errorf("the Network changed: resourceVersion %s→%s", existing.ResourceVersion, after.ResourceVersion)
	}
}

// ---------------------------------------------------------------------------------------------
// Shipped examples.

func TestShippedMigrationExamplesAccepted(t *testing.T) {
	dir := filepath.Join(repoRoot, "examples", "migrations")
	files, err := filepath.Glob(filepath.Join(dir, "*.yaml"))
	must(t, err)
	aliases := map[string]bool{}
	for _, f := range files {
		raw, err := os.ReadFile(f)
		must(t, err)
		u := &unstructured.Unstructured{}
		must(t, yaml.Unmarshal(raw, &u.Object))
		t.Run(filepath.Base(f), func(t *testing.T) {
			if u.GetKind() != "MigrationPlan" || u.GetAPIVersion() != migrationv1.GroupVersion.String() {
				t.Fatalf("%s is a %s %s, want a MigrationPlan", f, u.GetAPIVersion(), u.GetKind())
			}
			if err := admin.Create(context.Background(), u.DeepCopy(), client.DryRunAll, client.FieldValidation("Strict")); err != nil {
				t.Fatalf("refused: %v", err)
			}
			typed := &migrationv1.MigrationPlan{}
			must(t, k8sruntime.DefaultUnstructuredConverter.FromUnstructured(u.Object, typed))
			res, unsupported, ok := migration.Evaluate(typed.Spec)
			if !ok || len(unsupported) != 0 {
				t.Errorf("the example is not translatable: %+v %+v", res, unsupported)
			}
			aliases[res.Source] = true
		})
	}
	for _, a := range []string{"VPLS", "VPWS", "L3VPN", "L2L3-IRB"} {
		if !aliases[a] {
			t.Errorf("examples/migrations/ ships no plan for %s", a)
		}
	}
}
