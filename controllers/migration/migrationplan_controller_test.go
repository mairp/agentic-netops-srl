package migration

import (
	"context"
	"slices"
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	migrationv1 "github.com/mairp/agentic-netops-srl/api/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/status"
	vocab "github.com/mairp/agentic-netops-srl/pkg/migration"
)

func ptr[T any](v T) *T { return &v }

func spec(st string, eps int, opts ...func(*migrationv1.MigrationPlanSpec)) migrationv1.MigrationPlanSpec {
	s := migrationv1.MigrationPlanSpec{
		Source: migrationv1.MigrationSource{Platform: "legacy-router", ServiceType: migrationv1.SourceServiceType(st), ServiceID: "svc-1",
			NormalizedIntent: migrationv1.NormalizedIntent{Tenant: "t1"}},
		TargetNetworkRef: migrationv1.NetworkReference{Name: "net"},
	}
	for i := 0; i < eps; i++ {
		s.Source.NormalizedIntent.Endpoints = append(s.Source.NormalizedIntent.Endpoints,
			migrationv1.MigrationEndpoint{Node: "leaf0" + string(rune('1'+i)), Attachment: "ethernet-1/1"})
	}
	for _, o := range opts {
		o(&s)
	}
	return s
}

func optIn(s *migrationv1.MigrationPlanSpec) { s.MappingPolicy.AllowLimitedEquivalence = ptr(true) }
func prefixes(s *migrationv1.MigrationPlanSpec) {
	s.Source.NormalizedIntent.Prefixes = []migrationv1.MigrationPrefix{"10.0.0.0/24"}
}
func gateway(s *migrationv1.MigrationPlanSpec) {
	s.Source.NormalizedIntent.Gateway = &migrationv1.MigrationGateway{IPv4: "10.0.0.1/24"}
}

func codes(u []migrationv1.UnsupportedFeature) []string {
	var out []string
	for _, f := range u {
		out = append(out, f.Code)
	}
	return out
}

func TestEvaluate(t *testing.T) {
	for _, tc := range []struct {
		name      string
		spec      migrationv1.MigrationPlanSpec
		construct string
		codes     []string
	}{
		{"VPLS", spec("VPLS", 2), vocab.ConstructMACVRF, nil},
		{"VPWS opted in", spec("VPWS", 2, optIn), vocab.ConstructMACVRF, nil},
		{"VPWS without opt-in", spec("VPWS", 2), vocab.ConstructMACVRF, []string{CodeLimitedEquivalenceNotAllowed}},
		{"VPWS with three endpoints", spec("VPWS", 3, optIn), vocab.ConstructMACVRF, []string{CodePointToPointEndpoints}},
		{"VPLS with prefixes", spec("VPLS", 2, prefixes), vocab.ConstructMACVRF, []string{CodePrefixesOnBridgedService}},
		{"VPWS with gateway", spec("VPWS", 2, optIn, gateway), vocab.ConstructMACVRF, []string{CodeGatewayNotIntegrated}},
		{"L3VPN", spec("L3VPN", 1, prefixes), vocab.ConstructIPVRF, nil},
		{"L3VPN with gateway", spec("L3VPN", 1, prefixes, gateway), vocab.ConstructIPVRF, []string{CodeGatewayNotIntegrated}},
		{"L2L3-IRB", spec("L2L3-IRB", 2, gateway), vocab.ConstructMACVRF, nil},
		{"L2L3-IRB without gateway", spec("L2L3-IRB", 2), vocab.ConstructMACVRF, []string{CodeIntegratedWithoutGateway}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res, u, ok := Evaluate(tc.spec)
			if !ok || res.Construct != tc.construct || res.Source != string(tc.spec.Source.ServiceType) {
				t.Fatalf("Evaluate = %+v %v", res, ok)
			}
			if !slices.Equal(codes(u), tc.codes) {
				t.Fatalf("unsupported = %v, want %v", codes(u), tc.codes)
			}
			for _, f := range u {
				if !strings.HasPrefix(f.FieldPath, "spec.") || f.Message == "" {
					t.Errorf("feature %+v lacks a field path or message", f)
				}
			}
		})
	}
}

func scheme(t *testing.T) *runtime.Scheme {
	s := runtime.NewScheme()
	for _, add := range []func(*runtime.Scheme) error{fabricv1.AddToScheme, migrationv1.AddToScheme} {
		if err := add(s); err != nil {
			t.Fatal(err)
		}
	}
	return s
}

func network(ann map[string]string) *fabricv1.Network {
	return &fabricv1.Network{ObjectMeta: metav1.ObjectMeta{Namespace: "ns", Name: "net", Annotations: ann}}
}

// runPass runs one pass over a plan (and a Network when non-nil) with a fake client that fails
// the test on any write other than the plan's status.
func runPass(t *testing.T, s migrationv1.MigrationPlanSpec, net *fabricv1.Network) *migrationv1.MigrationPlan {
	t.Helper()
	plan := &migrationv1.MigrationPlan{ObjectMeta: metav1.ObjectMeta{Namespace: "ns", Name: "p", Generation: 1}, Spec: s}
	objs := []client.Object{plan}
	if net != nil {
		objs = append(objs, net)
	}
	forbid := func(verb string) func(context.Context, client.WithWatch, client.Object, ...any) error {
		return func(context.Context, client.WithWatch, client.Object, ...any) error {
			t.Fatalf("the controller called %s: it writes the plan's status only", verb)
			return nil
		}
	}
	c := fake.NewClientBuilder().WithScheme(scheme(t)).WithObjects(objs...).WithStatusSubresource(&migrationv1.MigrationPlan{}).
		WithInterceptorFuncs(interceptor.Funcs{
			Create: func(ctx context.Context, _ client.WithWatch, o client.Object, _ ...client.CreateOption) error {
				return forbid("Create")(ctx, nil, o)
			},
			Update: func(ctx context.Context, _ client.WithWatch, o client.Object, _ ...client.UpdateOption) error {
				return forbid("Update")(ctx, nil, o)
			},
			Patch: func(ctx context.Context, _ client.WithWatch, o client.Object, _ client.Patch, _ ...client.PatchOption) error {
				return forbid("Patch")(ctx, nil, o)
			},
			Delete: func(ctx context.Context, _ client.WithWatch, o client.Object, _ ...client.DeleteOption) error {
				return forbid("Delete")(ctx, nil, o)
			},
		}).Build()
	r := &Reconciler{Client: c}
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: types.NamespacedName{Namespace: "ns", Name: "p"}}); err != nil {
		t.Fatal(err)
	}
	out := &migrationv1.MigrationPlan{}
	if err := c.Get(context.Background(), types.NamespacedName{Namespace: "ns", Name: "p"}, out); err != nil {
		t.Fatal(err)
	}
	return out
}

func cond(t *testing.T, p *migrationv1.MigrationPlan, typ string) metav1.Condition {
	t.Helper()
	c := meta.FindStatusCondition(p.Status.Conditions, typ)
	if c == nil {
		t.Fatalf("no %s condition: %+v", typ, p.Status.Conditions)
	}
	return *c
}

func TestReconcileWithoutNetworkWaits(t *testing.T) {
	p := runPass(t, spec("VPLS", 2), nil)
	if p.Status.GeneratedNetworkRef != nil || p.Status.ProvenanceRef != nil {
		t.Fatalf("refs recorded without a Network: %+v", p.Status)
	}
	if p.Status.Construct != vocab.ConstructMACVRF || p.Status.SourceVocabulary != "VPLS" {
		t.Fatalf("construct/vocabulary = %q/%q", p.Status.Construct, p.Status.SourceVocabulary)
	}
	if r := cond(t, p, status.Ready); r.Status != metav1.ConditionFalse || r.Reason != status.ReasonNotConverged ||
		!strings.Contains(r.Message, "never creates it") {
		t.Fatalf("Ready = %+v", r)
	}
	if a := cond(t, p, status.Accepted); a.Status != metav1.ConditionTrue || !strings.Contains(a.Message, "cutover disabled") {
		t.Fatalf("Accepted = %+v", a)
	}
}

func TestReconcileRecordsKeysOnly(t *testing.T) {
	net := network(map[string]string{
		vocab.AnnotationServiceType:        vocab.ConstructMACVRF,
		vocab.AnnotationSourceServiceType:  "VPWS",
		vocab.AnnotationLimitedEquivalence: "vpws-to-mac-vrf",
		vocab.AnnotationTranslator:         vocab.TranslatorName,
	})
	net.Status.Conditions = []metav1.Condition{{Type: status.Ready, Status: metav1.ConditionTrue, Reason: status.ReasonAsExpected, Message: "ok"}}
	net.Status.RenderedConfigs = []fabricv1.RenderedConfig{{Node: "leaf01", Name: "net.leaf01", Phase: fabricv1.TargetPhaseReady}}
	p := runPass(t, spec("VPWS", 2, optIn), net)
	if p.Status.GeneratedNetworkRef == nil || *p.Status.GeneratedNetworkRef != (migrationv1.NetworkReference{Name: "net", Namespace: "ns"}) {
		t.Fatalf("generatedNetworkRef = %+v", p.Status.GeneratedNetworkRef)
	}
	want := []string{vocab.AnnotationServiceType, vocab.AnnotationSourceServiceType, vocab.AnnotationLimitedEquivalence}
	if !slices.Equal(p.Status.ProvenanceRef.AnnotationKeys, want) {
		t.Fatalf("annotationKeys = %v, want %v", p.Status.ProvenanceRef.AnnotationKeys, want)
	}
	if tr := cond(t, p, status.Translated); tr.Status != metav1.ConditionTrue || !strings.Contains(tr.Message, LimitedEquivalenceFinding) ||
		!strings.Contains(tr.Message, vocab.AnnotationLimitedEquivalence) || strings.Contains(tr.Message, "vpws-to-mac-vrf") {
		t.Fatalf("Translated = %+v", tr)
	}
	if r := cond(t, p, status.Ready); r.Status != metav1.ConditionTrue {
		t.Fatalf("Ready does not mirror the Network: %+v", r)
	}
	if len(p.Status.PerDevice) != 1 || p.Status.PerDevice[0].Target != "leaf01" || p.Status.PerDevice[0].ConfigRef != "net.leaf01" {
		t.Fatalf("perDevice = %+v", p.Status.PerDevice)
	}
}

func TestReconcileCollisionNamesKeys(t *testing.T) {
	net := network(map[string]string{vocab.AnnotationServiceType: vocab.ConstructIPVRF, vocab.AnnotationSourceServiceType: "L3VPN"})
	p := runPass(t, spec("VPLS", 2), net)
	tr := cond(t, p, status.Translated)
	if tr.Status != metav1.ConditionFalse || tr.Reason != status.ReasonCollision ||
		!strings.Contains(tr.Message, vocab.AnnotationServiceType) || !strings.Contains(tr.Message, vocab.AnnotationSourceServiceType) {
		t.Fatalf("Translated = %+v", tr)
	}
}

func TestReconcileUnsupported(t *testing.T) {
	p := runPass(t, spec("VPWS", 2), nil)
	if tr := cond(t, p, status.Translated); tr.Status != metav1.ConditionFalse || tr.Reason != status.ReasonUnsupportedFeature {
		t.Fatalf("Translated = %+v", tr)
	}
	if len(p.Status.UnsupportedFeatures) != 1 || p.Status.UnsupportedFeatures[0].FieldPath != "spec.mappingPolicy.allowLimitedEquivalence" {
		t.Fatalf("unsupportedFeatures = %+v", p.Status.UnsupportedFeatures)
	}
}
