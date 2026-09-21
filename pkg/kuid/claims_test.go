package kuid

// The adapter's contract suite (T178): every test here runs against BOTH implementations
// of Claims — the kuid one (upstream.go) and the first-party one (firstparty.go) — over
// the controller-runtime fake client, with interceptors simulating each authority's
// binding, so that nothing above the seam can tell them apart. What differs is only how
// each stores a claim (kuidImpl, firstPartyImpl); what is asserted is the same.

import (
	"context"
	"errors"
	"strings"
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

// impl is one implementation of Claims as the contract suite drives it.
type impl struct {
	name string
	// ns is the namespace the authority's claims live in.
	ns string
	// newSeam returns the seam over a fake client whose Create binds like the authority
	// (a stated value as stated, a dynamic one a fixed value; status reports it, Ready);
	// extra interceptors wrap the result; seeds are pre-existing claims.
	newSeam func(t *testing.T, bind bool, extra *interceptor.Funcs, seeds ...client.Object) (Claims, client.Client)
	// stored reads the claim as the authority stores it: the value it states, whether
	// it states anything else (a range, another field), and its metadata.labels.
	stored func(t *testing.T, c client.Client, k Kind, name string) (stated string, other string, labels map[string]string)
	// gone reports whether the claim no longer exists.
	gone func(c client.Client, k Kind, name string) bool
	// seed returns a pre-existing VLAN claim stating stated: "pending" (no Ready, no
	// value), or "refused" (Ready=False with msg); labels on metadata.labels.
	seed func(name, stated, state, msg string, labels map[string]string) client.Object
	// seedSpecLabelsOnly returns a VLAN claim carrying labels anywhere BUT metadata.labels
	// (kuid: spec.labels), with metaLabels on metadata; nil when the kind has no such set.
	seedSpecLabelsOnly func(name string, labels, metaLabels map[string]string) client.Object
}

func implementations() []impl { return []impl{kuidImpl(), firstPartyImpl()} }

// index is the index (pool) name the suite claims kind k against.
func index(k Kind) string { return "idx-" + strings.ToLower(string(k)) }

func ctx() context.Context { return context.Background() }

// chain runs extra's hook (if any) after the binding hook.
func chain(bind interceptor.Funcs, extra *interceptor.Funcs) interceptor.Funcs {
	if extra == nil {
		return bind
	}
	out := *extra
	if out.Create == nil {
		out.Create = bind.Create
	}
	return out
}

// ---------------------------------------------------------------------------
// The contract.
// ---------------------------------------------------------------------------

func TestContract(t *testing.T) {
	for _, im := range implementations() {
		t.Run(im.name, func(t *testing.T) {
			t.Run("ClaimValueBindsTheStatedValue", func(t *testing.T) { contractClaimValue(t, im) })
			t.Run("ClaimIsDynamicForm", func(t *testing.T) { contractDynamic(t, im) })
			t.Run("NotBoundWithoutReadyOrValue", func(t *testing.T) { contractNotBound(t, im) })
			t.Run("ListByLabelSelectsOnMetadataLabelsOnly", func(t *testing.T) { contractListByLabel(t, im) })
			t.Run("ReleaseDeletesAndGoneIsNotAnError", func(t *testing.T) { contractRelease(t, im) })
			t.Run("AuthorityErrorIsNotNotFound", func(t *testing.T) { contractAuthorityError(t, im) })
			t.Run("NewSelectsIt", func(t *testing.T) {
				seam, fc := im.newSeam(t, true, nil)
				got, err := New(seam.Authority(), fc)
				if err != nil || got.Authority() != seam.Authority() {
					t.Fatalf("New(%q) = %v %v", seam.Authority(), got, err)
				}
				for _, k := range Kinds() {
					if got.Index(k) != seam.Index(k) || seam.Index(k).Group == "" || seam.Index(k).Kind == "" {
						t.Errorf("%s: Index %v / %v", k, got.Index(k), seam.Index(k))
					}
				}
			})
		})
	}
}

func contractClaimValue(t *testing.T, im impl) {
	seam, fc := im.newSeam(t, true, nil)
	for _, tc := range []struct {
		kind  Kind
		value string
	}{{KindVLAN, "1234"}, {KindGENID, "10021"}, {KindASN, "65010"}, {KindIP, "10.1.1.1/32"}} {
		req := Request{Ref: Ref{Kind: tc.kind, Namespace: im.ns, Name: "svc.x-" + strings.ToLower(string(tc.kind))},
			Index: index(tc.kind), Labels: map[string]string{LabelCorrelationID: "c1"}}
		got, err := seam.ClaimValue(ctx(), req, tc.value)
		if err != nil {
			t.Fatalf("%s: %v", tc.kind, err)
		}
		if got.Stated != tc.value || got.Value != tc.value || !got.Ready || !got.Bound() || got.Index != req.Index {
			t.Errorf("%s: %+v", tc.kind, got)
		}
		stated, other, labels := im.stored(t, fc, tc.kind, req.Name)
		if stated != tc.value || other != "" {
			t.Errorf("%s: stored stating %q (and %q)", tc.kind, stated, other)
		}
		if labels[LabelCorrelationID] != "c1" {
			t.Errorf("%s: labels not in metadata.labels: %v", tc.kind, labels)
		}
		// Same name, same value: idempotent. Same name, another value: never moved.
		if again, err := seam.ClaimValue(ctx(), req, tc.value); err != nil || again.Value != tc.value {
			t.Errorf("%s: idempotent re-claim = %+v %v", tc.kind, again, err)
		}
		if _, err := seam.ClaimValue(ctx(), req, "4000"); err == nil {
			t.Errorf("%s: a claim was moved to another value", tc.kind)
		}
		if _, err := seam.ClaimValue(ctx(), req, ""); err == nil {
			t.Errorf("%s: an empty stated value accepted", tc.kind)
		}
	}
}

func contractDynamic(t *testing.T, im impl) {
	seam, fc := im.newSeam(t, true, nil)
	for _, k := range Kinds() {
		req := Request{Ref: Ref{Kind: k, Namespace: im.ns, Name: "dyn-" + strings.ToLower(string(k))}, Index: index(k)}
		got, err := seam.Claim(ctx(), req)
		if err != nil {
			t.Fatalf("%s: %v", k, err)
		}
		if got.Stated != "" || !got.Bound() {
			t.Errorf("%s: %+v", k, got)
		}
		if stated, other, _ := im.stored(t, fc, k, req.Name); stated != "" || other != "" {
			t.Errorf("%s: dynamic claim stored stating %q (and %q)", k, stated, other)
		}
		// A dynamic claim re-made under its name is the same claim; a stated one is not.
		if _, err := seam.Claim(ctx(), req); err != nil {
			t.Errorf("%s: idempotent dynamic re-claim: %v", k, err)
		}
		if _, err := seam.ClaimValue(ctx(), req, "1500"); err == nil {
			t.Errorf("%s: a dynamic claim was turned into a stated one", k)
		}
	}
}

func contractNotBound(t *testing.T, im impl) {
	seam, _ := im.newSeam(t, true, nil,
		im.seed("pending", "1500", "pending", "", nil),
		im.seed("refused", "1500", "refused", "held by svc-a", nil))
	for _, name := range []string{"pending", "refused"} {
		got, err := seam.Get(ctx(), Ref{Kind: KindVLAN, Namespace: im.ns, Name: name})
		if err != nil || got.Bound() || got.Ready || got.Stated != "1500" || got.Value != "" {
			t.Errorf("%s: %+v %v", name, got, err)
		}
	}
	got, _ := seam.Get(ctx(), Ref{Kind: KindVLAN, Namespace: im.ns, Name: "refused"})
	if got.Message != "held by svc-a" || got.Reason == "" {
		t.Errorf("refusal not surfaced: %+v", got)
	}
	// A pending claim is no refusal: nothing above the seam may read it as one.
	if got, _ := seam.Get(ctx(), Ref{Kind: KindVLAN, Namespace: im.ns, Name: "pending"}); got.Reason != "" && got.Message != "" {
		t.Errorf("a pending claim reads as a refusal: %+v", got)
	}
}

func contractListByLabel(t *testing.T, im impl) {
	sel := map[string]string{LabelCorrelationID: "c1"}
	seeds := []client.Object{
		im.seed("on-meta", "1501", "pending", "", sel),
		im.seed("other", "1502", "pending", "", map[string]string{LabelCorrelationID: "other"}),
		im.seed("unlabelled", "1503", "pending", "", nil),
	}
	if im.seedSpecLabelsOnly != nil {
		seeds = append(seeds,
			im.seedSpecLabelsOnly("on-spec", sel, map[string]string{LabelCorrelationID: "other"}),
			im.seedSpecLabelsOnly("on-spec-only", sel, nil))
	}
	var calls []*client.ListOptions
	spy := &interceptor.Funcs{List: func(ctx context.Context, c client.WithWatch, l client.ObjectList, opts ...client.ListOption) error {
		lo := &client.ListOptions{}
		for _, o := range opts {
			o.ApplyToList(lo)
		}
		calls = append(calls, lo)
		return c.List(ctx, l, opts...)
	}}
	seam, _ := im.newSeam(t, true, spy, seeds...)
	got, err := seam.ListByLabel(ctx(), KindVLAN, im.ns, sel)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Name != "on-meta" || got[0].Kind != KindVLAN || got[0].Labels[LabelCorrelationID] != "c1" {
		t.Fatalf("ListByLabel = %+v; want only on-meta", got)
	}
	// The selector reaches the API as a metadata label selector, in the namespace.
	selected := false
	for _, lo := range calls {
		if lo.FieldSelector != nil {
			t.Errorf("a field selector was sent: %v", lo.FieldSelector)
		}
		if lo.LabelSelector != nil && lo.LabelSelector.String() == LabelCorrelationID+"=c1" && lo.Namespace == im.ns {
			selected = true
		}
	}
	if !selected {
		t.Errorf("no list carried the metadata label selector in %s: %+v", im.ns, calls)
	}
	if none, err := seam.ListByLabel(ctx(), KindVLAN, im.ns, map[string]string{"not-a-label": "x"}); err != nil || len(none) != 0 {
		t.Errorf("a label no claim carries selected %+v %v", none, err)
	}
	if _, err := seam.ListByLabel(ctx(), KindVLAN, im.ns, nil); err == nil {
		t.Error("an empty selector must be refused")
	}
}

func contractRelease(t *testing.T, im impl) {
	seam, fc := im.newSeam(t, true, nil)
	ref := Ref{Kind: KindGENID, Namespace: im.ns, Name: "svc.l2vni-bd1"}
	if _, err := seam.ClaimValue(ctx(), Request{Ref: ref, Index: index(KindGENID)}, "10021"); err != nil {
		t.Fatal(err)
	}
	if err := seam.Release(ctx(), ref); err != nil {
		t.Fatal(err)
	}
	if !im.gone(fc, KindGENID, ref.Name) {
		t.Fatal("claim still exists after Release")
	}
	if _, err := seam.Get(ctx(), ref); !IsNotFound(err) {
		t.Fatalf("Get after release = %v; want ErrNotFound", err)
	}
	if err := seam.Release(ctx(), ref); err != nil {
		t.Fatalf("releasing a released claim: %v", err)
	}
}

// contractAuthorityError: an authority that errors is never read as "no such claim" (AD-56).
func contractAuthorityError(t *testing.T, im impl) {
	boom := errors.New("authority unavailable")
	seam, _ := im.newSeam(t, false, &interceptor.Funcs{
		Get: func(context.Context, client.WithWatch, client.ObjectKey, client.Object, ...client.GetOption) error {
			return boom
		},
		Delete: func(context.Context, client.WithWatch, client.Object, ...client.DeleteOption) error { return boom },
		List: func(context.Context, client.WithWatch, client.ObjectList, ...client.ListOption) error {
			return boom
		},
		Create: func(context.Context, client.WithWatch, client.Object, ...client.CreateOption) error { return boom },
	})
	ref := Ref{Kind: KindVLAN, Namespace: im.ns, Name: "x"}
	if _, err := seam.Get(ctx(), ref); err == nil || IsNotFound(err) || !errors.Is(err, boom) {
		t.Fatalf("Get = %v", err)
	}
	if err := seam.Release(ctx(), ref); err == nil || !errors.Is(err, boom) {
		t.Fatalf("Release = %v", err)
	}
	if _, err := seam.ListByLabel(ctx(), KindVLAN, im.ns, map[string]string{LabelCorrelationID: "c1"}); err == nil || !errors.Is(err, boom) {
		t.Fatalf("ListByLabel = %v", err)
	}
	if _, err := seam.ClaimValue(ctx(), Request{Ref: ref, Index: index(KindVLAN)}, "1500"); err == nil || IsNotFound(err) || !errors.Is(err, boom) {
		t.Fatalf("ClaimValue = %v", err)
	}
}

func TestNewRefusesAnyOtherAuthority(t *testing.T) {
	for _, k := range []string{"", "Kuid", "firstparty", "local"} {
		if _, err := New(k, nil); err == nil || !strings.Contains(err.Error(), "allocationAuthority.kind") {
			t.Errorf("New(%q) = %v", k, err)
		}
	}
}

// ---------------------------------------------------------------------------
// The kuid implementation, as the suite drives it.
// ---------------------------------------------------------------------------

const kuidNS = "kuid-system"

func kuidScheme(t *testing.T) *runtime.Scheme {
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

// kuidAuthority simulates kuid-server on Create: a stated value is bound as stated, a
// dynamic one gets a fixed value; both report status.id with Ready.
func kuidAuthority() interceptor.Funcs {
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

// kuidBuilder returns a fake client builder over a plain object tracker: the default
// managed-fields tracker cannot reflect the upstream GENID claim's uint64 fields (a
// fake-client limitation, not an API one).
func kuidBuilder(t *testing.T) *fake.ClientBuilder {
	s := kuidScheme(t)
	tr := clienttesting.NewObjectTracker(s, serializer.NewCodecFactory(s).UniversalDecoder())
	return fake.NewClientBuilder().WithScheme(s).WithObjectTracker(tr)
}

func kuidImpl() impl {
	return impl{
		name: AuthorityKuid,
		ns:   kuidNS,
		newSeam: func(t *testing.T, bind bool, extra *interceptor.Funcs, seeds ...client.Object) (Claims, client.Client) {
			f := interceptor.Funcs{}
			if bind {
				f = kuidAuthority()
			}
			fc := kuidBuilder(t).WithInterceptorFuncs(chain(f, extra)).WithObjects(seeds...).Build()
			return NewUpstream(fc), fc
		},
		stored: func(t *testing.T, c client.Client, k Kind, name string) (string, string, map[string]string) {
			t.Helper()
			obj, _ := newClaim(k)
			if err := c.Get(ctx(), client.ObjectKey{Namespace: kuidNS, Name: name}, obj); err != nil {
				t.Fatal(err)
			}
			var stated, other string
			switch o := obj.(type) {
			case *vlanv1alpha1.VLANClaim:
				stated = fmt32(o.Spec.ID)
				if o.Spec.Range != nil {
					other = "spec.range"
				}
			case *genidv1alpha1.GENIDClaim:
				stated = fmt64(o.Spec.ID)
				if o.Spec.Range != nil {
					other = "spec.range"
				}
			case *asv1alpha1.ASClaim:
				stated = fmt32(o.Spec.ID)
				if o.Spec.Range != nil {
					other = "spec.range"
				}
			case *ipamv1alpha1.IPClaim:
				stated = firstOf(o.Spec.Address)
				if o.Spec.Range != nil || o.Spec.Prefix != nil {
					other = "spec.range/spec.prefix"
				}
			}
			return stated, other, obj.GetLabels()
		},
		gone: func(c client.Client, k Kind, name string) bool {
			obj, _ := newClaim(k)
			return c.Get(ctx(), client.ObjectKey{Namespace: kuidNS, Name: name}, obj) != nil
		},
		seed: func(name, stated, state, msg string, labels map[string]string) client.Object {
			v, _ := parse32(Ref{}, stated)
			o := &vlanv1alpha1.VLANClaim{ObjectMeta: metav1.ObjectMeta{Namespace: kuidNS, Name: name, Labels: labels},
				Spec: vlanv1alpha1.VLANClaimSpec{Index: index(KindVLAN), ID: &v}}
			if state == "refused" {
				o.Status.SetConditions(condv1alpha1.Failed(msg))
			}
			return o
		},
		seedSpecLabelsOnly: func(name string, labels, metaLabels map[string]string) client.Object {
			return &vlanv1alpha1.VLANClaim{ObjectMeta: metav1.ObjectMeta{Namespace: kuidNS, Name: name, Labels: metaLabels},
				Spec: vlanv1alpha1.VLANClaimSpec{Index: index(KindVLAN), ClaimLabels: commonv1alpha1.ClaimLabels{
					UserDefinedLabels: commonv1alpha1.UserDefinedLabels{Labels: labels}}}}
		},
	}
}

// ---------------------------------------------------------------------------
// kuid-only: the upstream types and their claim forms.
// ---------------------------------------------------------------------------

func TestUpstreamClaimGVKs(t *testing.T) {
	s := kuidScheme(t)
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
	// Index and Entry kinds of the served APIs are registered too, and Index() names them.
	u := NewUpstream(nil)
	for k, gvk := range map[Kind]schema.GroupVersionKind{
		KindVLAN:  {Group: "vlan.be.kuid.dev", Version: "v1alpha1", Kind: "VLANIndex"},
		KindGENID: {Group: "genid.be.kuid.dev", Version: "v1alpha1", Kind: "GENIDIndex"},
		KindIP:    {Group: "ipam.be.kuid.dev", Version: "v1alpha1", Kind: "IPIndex"},
		KindASN:   {Group: "as.be.kuid.dev", Version: "v1alpha1", Kind: "ASIndex"},
	} {
		if !s.Recognizes(gvk) {
			t.Errorf("scheme does not recognize %v", gvk)
		}
		if got := u.Index(k); got.Group != gvk.Group || got.Kind != gvk.Kind {
			t.Errorf("Index(%s) = %v, want %v", k, got, gvk)
		}
	}
	if !s.Recognizes(schema.GroupVersionKind{Group: "vlan.be.kuid.dev", Version: "v1alpha1", Kind: "VLANEntry"}) {
		t.Error("scheme does not recognize VLANEntry")
	}
	if u.Authority() != AuthorityKuid {
		t.Errorf("Authority = %s", u.Authority())
	}
}

// A dynamic /31 link claim is a dynamic PREFIX claim: spec.createPrefix and
// spec.prefixLength set, no address, prefix or range stated.
func TestDynamicPrefixClaimForm(t *testing.T) {
	pl := uint32(31)
	obj, err := buildClaim(Request{Ref: Ref{Kind: KindIP, Namespace: kuidNS, Name: "link"}, Index: "p2p",
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
	obj, _ = buildClaim(Request{Ref: Ref{Kind: KindIP, Namespace: kuidNS, Name: "link"}, Index: "p2p", IPPrefix: true, CreatePrefix: true}, &stated)
	if c := obj.(*ipamv1alpha1.IPClaim); c.Spec.CreatePrefix != nil {
		t.Errorf("a stated prefix never sets createPrefix: %+v", c.Spec)
	}
}
