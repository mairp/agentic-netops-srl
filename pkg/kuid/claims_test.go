package kuid

import (
	"context"
	"errors"
	"testing"

	condv1alpha1 "github.com/kform-dev/choreo/apis/condition/v1alpha1"
	asv1alpha1 "github.com/kuidio/kuid/apis/backend/as/v1alpha1"
	genidv1alpha1 "github.com/kuidio/kuid/apis/backend/genid/v1alpha1"
	ipamv1alpha1 "github.com/kuidio/kuid/apis/backend/ipam/v1alpha1"
	vlanv1alpha1 "github.com/kuidio/kuid/apis/backend/vlan/v1alpha1"
	commonv1alpha1 "github.com/kuidio/kuid/apis/common/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	clienttesting "k8s.io/client-go/testing"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/apiutil"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

const ns = "kuid-system"

func scheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	return s
}

func readyTrue() condv1alpha1.Condition {
	return condv1alpha1.Condition{Condition: metav1.Condition{Type: string(condv1alpha1.ConditionTypeReady),
		Status: metav1.ConditionTrue, Reason: "Ready", LastTransitionTime: metav1.Now()}}
}

// authority simulates the allocation authority on Create: a stated value is
// bound as stated, a dynamic one gets 1000; both report status.id with Ready.
func authority() interceptor.Funcs {
	return interceptor.Funcs{Create: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.CreateOption) error {
		switch o := obj.(type) {
		case *vlanv1alpha1.VLANClaim:
			v := uint32(1000)
			if o.Spec.ID != nil {
				v = *o.Spec.ID
			}
			o.Status.ID = &v
			o.Status.SetConditions(readyTrue())
		case *genidv1alpha1.GENIDClaim:
			v := uint64(10000)
			if o.Spec.ID != nil {
				v = *o.Spec.ID
			}
			o.Status.ID = &v
			o.Status.SetConditions(readyTrue())
		case *asv1alpha1.ASClaim:
			v := uint32(65001)
			if o.Spec.ID != nil {
				v = *o.Spec.ID
			}
			o.Status.ID = &v
			o.Status.SetConditions(readyTrue())
		case *ipamv1alpha1.IPClaim:
			v := "10.0.0.1/32"
			if o.Spec.Address != nil {
				v = *o.Spec.Address
			}
			o.Status.Address = &v
			o.Status.SetConditions(readyTrue())
		}
		return c.Create(ctx, obj, opts...)
	}}
}

// builder returns a fake client builder over a plain object tracker: the
// default managed-fields tracker cannot reflect the upstream GENID claim's
// uint64 fields (a fake-client limitation, not an API one).
func builder(t *testing.T) *fake.ClientBuilder {
	s := scheme(t)
	tr := clienttesting.NewObjectTracker(s, serializer.NewCodecFactory(s).UniversalDecoder())
	return fake.NewClientBuilder().WithScheme(s).WithObjectTracker(tr)
}

func newSeam(t *testing.T, objs ...client.Object) (Claims, client.Client) {
	fc := builder(t).WithInterceptorFuncs(authority()).WithObjects(objs...).Build()
	return NewUpstream(fc), fc
}

func TestUpstreamClaimGVKs(t *testing.T) {
	s := scheme(t)
	want := map[Kind]schema.GroupVersionKind{
		KindIP:    {Group: "ipam.be.kuid.dev", Version: "v1alpha1", Kind: "IPClaim"},
		KindASN:   {Group: "as.be.kuid.dev", Version: "v1alpha1", Kind: "ASClaim"},
		KindVLAN:  {Group: "vlan.be.kuid.dev", Version: "v1alpha1", Kind: "VLANClaim"},
		KindGENID: {Group: "genid.be.kuid.dev", Version: "v1alpha1", Kind: "GENIDClaim"},
	}
	for _, k := range Kinds() {
		obj, err := newClaim(k)
		if err != nil {
			t.Fatal(err)
		}
		gvk, err := apiutil.GVKForObject(obj, s)
		if err != nil || gvk != want[k] {
			t.Errorf("%s: %v %v, want %v", k, gvk, err, want[k])
		}
	}
	// Index and Entry kinds of the served APIs are registered too.
	for _, gvk := range []schema.GroupVersionKind{
		{Group: "vlan.be.kuid.dev", Version: "v1alpha1", Kind: "VLANIndex"},
		{Group: "vlan.be.kuid.dev", Version: "v1alpha1", Kind: "VLANEntry"},
		{Group: "genid.be.kuid.dev", Version: "v1alpha1", Kind: "GENIDIndex"},
		{Group: "ipam.be.kuid.dev", Version: "v1alpha1", Kind: "IPIndex"},
		{Group: "as.be.kuid.dev", Version: "v1alpha1", Kind: "ASIndex"},
	} {
		if !s.Recognizes(gvk) {
			t.Errorf("scheme does not recognize %v", gvk)
		}
	}
}

func TestClaimValueStatesSpecIDAndReadsStatusID(t *testing.T) {
	ctx := context.Background()
	seam, fc := newSeam(t)
	for _, tc := range []struct {
		kind  Kind
		value string
	}{{KindVLAN, "1234"}, {KindGENID, "10021"}, {KindASN, "65010"}, {KindIP, "10.1.1.1/32"}} {
		req := Request{Ref: Ref{Kind: tc.kind, Namespace: ns, Name: "svc.x-" + string(tc.kind)}, Index: "idx",
			Labels: map[string]string{LabelCorrelationID: "c1"}}
		got, err := seam.ClaimValue(ctx, req, tc.value)
		if err != nil {
			t.Fatalf("%s: %v", tc.kind, err)
		}
		if got.Stated != tc.value || got.Value != tc.value || !got.Ready || !got.Bound() {
			t.Errorf("%s: %+v", tc.kind, got)
		}
		// The stored upstream object states the value in spec.id (spec.address for IP).
		obj, _ := newClaim(tc.kind)
		if err := fc.Get(ctx, client.ObjectKey{Namespace: ns, Name: req.Name}, obj); err != nil {
			t.Fatal(err)
		}
		switch o := obj.(type) {
		case *vlanv1alpha1.VLANClaim:
			if o.Spec.ID == nil || *o.Spec.ID != 1234 || o.Spec.Range != nil {
				t.Errorf("VLAN spec %+v", o.Spec)
			}
		case *genidv1alpha1.GENIDClaim:
			if o.Spec.ID == nil || *o.Spec.ID != 10021 || o.Spec.Range != nil {
				t.Errorf("GENID spec %+v", o.Spec)
			}
		case *asv1alpha1.ASClaim:
			if o.Spec.ID == nil || *o.Spec.ID != 65010 || o.Spec.Range != nil {
				t.Errorf("AS spec %+v", o.Spec)
			}
		case *ipamv1alpha1.IPClaim:
			if o.Spec.Address == nil || *o.Spec.Address != "10.1.1.1/32" || o.Spec.Range != nil || o.Spec.Prefix != nil {
				t.Errorf("IP spec %+v", o.Spec)
			}
		}
		if obj.GetLabels()[LabelCorrelationID] != "c1" {
			t.Errorf("%s: labels not in metadata.labels: %v", tc.kind, obj.GetLabels())
		}
		// Same name, same value: idempotent. Same name, another value: never moved.
		if again, err := seam.ClaimValue(ctx, req, tc.value); err != nil || again.Value != tc.value {
			t.Errorf("%s: idempotent re-claim = %+v %v", tc.kind, again, err)
		}
		if _, err := seam.ClaimValue(ctx, req, "4000"); err == nil {
			t.Errorf("%s: a claim was moved to another value", tc.kind)
		}
	}
}

func TestClaimIsDynamicForm(t *testing.T) {
	ctx := context.Background()
	seam, fc := newSeam(t)
	for _, k := range Kinds() {
		req := Request{Ref: Ref{Kind: k, Namespace: ns, Name: "dyn-" + string(k)}, Index: "idx"}
		got, err := seam.Claim(ctx, req)
		if err != nil {
			t.Fatalf("%s: %v", k, err)
		}
		if got.Stated != "" || !got.Bound() {
			t.Errorf("%s: %+v", k, got)
		}
		obj, _ := newClaim(k)
		if err := fc.Get(ctx, client.ObjectKey{Namespace: ns, Name: req.Name}, obj); err != nil {
			t.Fatal(err)
		}
		switch o := obj.(type) {
		case *vlanv1alpha1.VLANClaim:
			if o.Spec.ID != nil || o.Spec.Range != nil {
				t.Errorf("VLAN dynamic claim states %+v", o.Spec)
			}
		case *genidv1alpha1.GENIDClaim:
			if o.Spec.ID != nil || o.Spec.Range != nil {
				t.Errorf("GENID dynamic claim states %+v", o.Spec)
			}
		case *asv1alpha1.ASClaim:
			if o.Spec.ID != nil || o.Spec.Range != nil {
				t.Errorf("AS dynamic claim states %+v", o.Spec)
			}
		case *ipamv1alpha1.IPClaim:
			if o.Spec.Address != nil || o.Spec.Prefix != nil || o.Spec.Range != nil {
				t.Errorf("IP dynamic claim states %+v", o.Spec)
			}
		}
	}
}

func TestNotBoundWithoutReadyOrValue(t *testing.T) {
	ctx := context.Background()
	id := uint32(1500)
	pending := &vlanv1alpha1.VLANClaim{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: "pending"},
		Spec: vlanv1alpha1.VLANClaimSpec{Index: "idx", ID: &id}}
	refused := &vlanv1alpha1.VLANClaim{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: "refused"},
		Spec: vlanv1alpha1.VLANClaimSpec{Index: "idx", ID: &id}}
	refused.Status.SetConditions(condv1alpha1.Failed("held by svc-a"))
	seam, _ := newSeam(t, pending, refused)
	for _, name := range []string{"pending", "refused"} {
		got, err := seam.Get(ctx, Ref{Kind: KindVLAN, Namespace: ns, Name: name})
		if err != nil || got.Bound() || got.Stated != "1500" {
			t.Errorf("%s: %+v %v", name, got, err)
		}
	}
	got, _ := seam.Get(ctx, Ref{Kind: KindVLAN, Namespace: ns, Name: "refused"})
	if got.Message != "held by svc-a" {
		t.Errorf("refusal message not surfaced: %+v", got)
	}
}

// TestListByLabelSelectsOnMetadataLabelsOnly: a claim whose spec.labels match
// but whose metadata.labels do not is never returned (AD-32).
func TestListByLabelSelectsOnMetadataLabelsOnly(t *testing.T) {
	ctx := context.Background()
	sel := map[string]string{LabelCorrelationID: "c1"}
	onMeta := &vlanv1alpha1.VLANClaim{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: "on-meta", Labels: sel},
		Spec: vlanv1alpha1.VLANClaimSpec{Index: "idx"}}
	onSpec := &vlanv1alpha1.VLANClaim{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: "on-spec",
		Labels: map[string]string{LabelCorrelationID: "other"}},
		Spec: vlanv1alpha1.VLANClaimSpec{Index: "idx", ClaimLabels: commonv1alpha1.ClaimLabels{
			UserDefinedLabels: commonv1alpha1.UserDefinedLabels{Labels: sel}}}}
	onSpecOnly := &vlanv1alpha1.VLANClaim{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: "on-spec-only"},
		Spec: vlanv1alpha1.VLANClaimSpec{Index: "idx", ClaimLabels: commonv1alpha1.ClaimLabels{
			UserDefinedLabels: commonv1alpha1.UserDefinedLabels{Labels: sel}}}}
	var seen []client.ListOption
	fc := builder(t).WithObjects(onMeta, onSpec, onSpecOnly).
		WithInterceptorFuncs(interceptor.Funcs{List: func(ctx context.Context, c client.WithWatch, l client.ObjectList, opts ...client.ListOption) error {
			seen = opts
			return c.List(ctx, l, opts...)
		}}).Build()
	got, err := NewUpstream(fc).ListByLabel(ctx, KindVLAN, ns, sel)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Name != "on-meta" {
		t.Fatalf("ListByLabel = %+v; want only on-meta", got)
	}
	// The selector reaches the API as a metadata label selector.
	lo := &client.ListOptions{}
	for _, o := range seen {
		o.ApplyToList(lo)
	}
	if lo.LabelSelector == nil || lo.LabelSelector.String() != LabelCorrelationID+"=c1" || lo.FieldSelector != nil || lo.Namespace != ns {
		t.Errorf("list options %+v", lo)
	}
	if _, err := NewUpstream(fc).ListByLabel(ctx, KindVLAN, ns, nil); err == nil {
		t.Error("an empty selector must be refused")
	}
}

func TestReleaseDeletes(t *testing.T) {
	ctx := context.Background()
	seam, fc := newSeam(t)
	ref := Ref{Kind: KindGENID, Namespace: ns, Name: "svc.l2vni-bd1"}
	if _, err := seam.ClaimValue(ctx, Request{Ref: ref, Index: "vni"}, "10021"); err != nil {
		t.Fatal(err)
	}
	if err := seam.Release(ctx, ref); err != nil {
		t.Fatal(err)
	}
	if err := fc.Get(ctx, client.ObjectKey{Namespace: ns, Name: ref.Name}, &genidv1alpha1.GENIDClaim{}); err == nil {
		t.Fatal("claim still exists after Release")
	}
	if _, err := seam.Get(ctx, ref); !IsNotFound(err) {
		t.Fatalf("Get after release = %v; want ErrNotFound", err)
	}
	if err := seam.Release(ctx, ref); err != nil {
		t.Fatalf("releasing a released claim: %v", err)
	}
}

// TestAuthorityErrorIsNotNotFound: an authority that errors is never read as
// "no such claim" (AD-56).
func TestAuthorityErrorIsNotNotFound(t *testing.T) {
	boom := errors.New("aggregated API unavailable")
	fc := builder(t).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(context.Context, client.WithWatch, client.ObjectKey, client.Object, ...client.GetOption) error {
			return boom
		},
		Delete: func(context.Context, client.WithWatch, client.Object, ...client.DeleteOption) error { return boom },
	}).Build()
	seam := NewUpstream(fc)
	ref := Ref{Kind: KindVLAN, Namespace: ns, Name: "x"}
	if _, err := seam.Get(ctx(), ref); err == nil || IsNotFound(err) || !errors.Is(err, boom) {
		t.Fatalf("Get = %v", err)
	}
	if err := seam.Release(ctx(), ref); err == nil || !errors.Is(err, boom) {
		t.Fatalf("Release = %v", err)
	}
}

func ctx() context.Context { return context.Background() }

// A dynamic /31 link claim is a dynamic PREFIX claim: spec.createPrefix and
// spec.prefixLength set, no address, prefix or range stated.
func TestDynamicPrefixClaimForm(t *testing.T) {
	pl := uint32(31)
	obj, err := buildClaim(Request{Ref: Ref{Kind: KindIP, Namespace: ns, Name: "link"}, Index: "p2p",
		IPPrefix: true, AddressFamily: "ipv4", PrefixLength: &pl, CreatePrefix: true}, nil)
	if err != nil {
		t.Fatal(err)
	}
	c := obj.(*ipamv1alpha1.IPClaim)
	if c.Spec.CreatePrefix == nil || !*c.Spec.CreatePrefix || c.Spec.PrefixLength == nil || *c.Spec.PrefixLength != 31 ||
		c.Spec.Address != nil || c.Spec.Prefix != nil || c.Spec.Range != nil {
		t.Errorf("dynamic prefix claim %+v", c.Spec)
	}
	stated := "10.1.0.0/31"
	obj, _ = buildClaim(Request{Ref: Ref{Kind: KindIP, Namespace: ns, Name: "link"}, Index: "p2p", IPPrefix: true, CreatePrefix: true}, &stated)
	if c := obj.(*ipamv1alpha1.IPClaim); c.Spec.CreatePrefix != nil {
		t.Errorf("a stated prefix never sets createPrefix: %+v", c.Spec)
	}
}
