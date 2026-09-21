package kuid

// T178: the first-party implementation as the contract suite (claims_test.go, TestContract)
// drives it — the same suite that runs against kuid — plus what only it has: the pool-type
// filter of ListByLabel, spec.prefixLength on a dynamic prefix claim, and Ready=Unknown
// read as pending, never as a refusal.

import (
	"context"
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
)

const fpNS = FirstPartyNamespace

// fpPools is one pool per claim kind, named index(kind), of the type that serves it.
func fpPools() []client.Object {
	num := func(k Kind, typ fabricv1.IdentifierType, lo, hi int64) client.Object {
		return &fabricv1.IdentifierPool{ObjectMeta: metav1.ObjectMeta{Namespace: fpNS, Name: index(k)},
			Spec: fabricv1.IdentifierPoolSpec{Type: typ, Range: &fabricv1.IdentifierRange{Start: lo, End: hi}}}
	}
	return []client.Object{
		num(KindVLAN, fabricv1.IdentifierTypeVLAN, 1000, 4000),
		num(KindASN, fabricv1.IdentifierTypeASN, 65000, 65535),
		num(KindGENID, fabricv1.IdentifierTypeVNI, 10000, 20000),
		&fabricv1.IdentifierPool{ObjectMeta: metav1.ObjectMeta{Namespace: fpNS, Name: index(KindIP)},
			Spec: fabricv1.IdentifierPoolSpec{Type: fabricv1.IdentifierTypeIP, Prefix: "10.0.0.0/16"}},
	}
}

// firstPartyAuthority simulates the claim controller on Create: a stated value is bound
// as stated, a dynamic one a fixed value of its pool; status.value with Ready=True/Bound.
func firstPartyAuthority() interceptor.Funcs {
	dynamic := map[string]string{index(KindVLAN): "1000", index(KindASN): "65001", index(KindGENID): "10000", index(KindIP): "10.0.0.1/32"}
	return interceptor.Funcs{Create: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.CreateOption) error {
		if o, ok := obj.(*fabricv1.IdentifierClaim); ok {
			v := o.Spec.Requested
			if v == "" {
				v = dynamic[string(o.Spec.PoolRef.Name)]
			}
			o.Status.Value = v
			meta.SetStatusCondition(&o.Status.Conditions, metav1.Condition{Type: "Ready", Status: metav1.ConditionTrue, Reason: "Bound", Message: "bound"})
		}
		return c.Create(ctx, obj, opts...)
	}}
}

func fpScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := fabricv1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	return s
}

func firstPartyImpl() impl {
	return impl{
		name: AuthorityFirstParty,
		ns:   fpNS,
		newSeam: func(t *testing.T, bind bool, extra *interceptor.Funcs, seeds ...client.Object) (Claims, client.Client) {
			f := interceptor.Funcs{}
			if bind {
				f = firstPartyAuthority()
			}
			fc := fake.NewClientBuilder().WithScheme(fpScheme(t)).WithInterceptorFuncs(chain(f, extra)).
				WithObjects(append(fpPools(), seeds...)...).Build()
			return NewFirstParty(fc), fc
		},
		stored: func(t *testing.T, c client.Client, k Kind, name string) (string, string, map[string]string) {
			t.Helper()
			o := &fabricv1.IdentifierClaim{}
			if err := c.Get(ctx(), client.ObjectKey{Namespace: fpNS, Name: name}, o); err != nil {
				t.Fatal(err)
			}
			other := ""
			if o.Spec.PrefixLength != nil {
				other = "spec.prefixLength"
			}
			if string(o.Spec.PoolRef.Name) != index(k) {
				other += " spec.poolRef " + string(o.Spec.PoolRef.Name)
			}
			return o.Spec.Requested, other, o.Labels
		},
		gone: func(c client.Client, _ Kind, name string) bool {
			return c.Get(ctx(), client.ObjectKey{Namespace: fpNS, Name: name}, &fabricv1.IdentifierClaim{}) != nil
		},
		seed: func(name, stated, state, msg string, labels map[string]string) client.Object {
			o := &fabricv1.IdentifierClaim{ObjectMeta: metav1.ObjectMeta{Namespace: fpNS, Name: name, Labels: labels},
				Spec: fabricv1.IdentifierClaimSpec{PoolRef: fabricv1.IdentifierPoolRef{Name: fabricv1.DNSLabel(index(KindVLAN))}, Requested: stated}}
			if state == "refused" {
				o.Status.Conditions = []metav1.Condition{{Type: "Ready", Status: metav1.ConditionFalse, Reason: "Conflict", Message: msg,
					LastTransitionTime: metav1.Now()}}
			}
			return o
		},
		// IdentifierClaim has no label set but metadata.labels.
		seedSpecLabelsOnly: nil,
	}
}

func TestFirstPartyIndexAndAuthority(t *testing.T) {
	fp := NewFirstParty(nil)
	for _, k := range Kinds() {
		if got := fp.Index(k); got.Group != "fabric.agentic-netops.io" || got.Kind != "IdentifierPool" {
			t.Errorf("Index(%s) = %v", k, got)
		}
		if strings.Contains(fp.Index(k).Group, "kuid.dev") {
			t.Errorf("the substitute names an upstream group: %v", fp.Index(k))
		}
	}
	if fp.Authority() != AuthorityFirstParty {
		t.Errorf("Authority = %s", fp.Authority())
	}
}

// A dynamic /31 link claim carries spec.prefixLength; a dynamic address claim none.
func TestFirstPartyDynamicPrefixClaimForm(t *testing.T) {
	seam, fc := firstPartyImpl().newSeam(t, true, nil)
	pl := uint32(31)
	link := Request{Ref: Ref{Kind: KindIP, Namespace: fpNS, Name: "link"}, Index: index(KindIP), IPPrefix: true,
		AddressFamily: "ipv4", PrefixLength: &pl, CreatePrefix: true}
	if _, err := seam.Claim(ctx(), link); err != nil {
		t.Fatal(err)
	}
	o := &fabricv1.IdentifierClaim{}
	if err := fc.Get(ctx(), client.ObjectKey{Namespace: fpNS, Name: "link"}, o); err != nil {
		t.Fatal(err)
	}
	if o.Spec.PrefixLength == nil || *o.Spec.PrefixLength != 31 || o.Spec.Requested != "" {
		t.Errorf("dynamic prefix claim %+v", o.Spec)
	}
	addr := Request{Ref: Ref{Kind: KindIP, Namespace: fpNS, Name: "lo"}, Index: index(KindIP), AddressFamily: "ipv4", PrefixLength: &pl}
	if _, err := seam.Claim(ctx(), addr); err != nil {
		t.Fatal(err)
	}
	if err := fc.Get(ctx(), client.ObjectKey{Namespace: fpNS, Name: "lo"}, o); err != nil {
		t.Fatal(err)
	}
	if o.Spec.PrefixLength != nil {
		t.Errorf("a dynamic address claim states a prefix length: %+v", o.Spec)
	}
	if _, err := seam.Claim(ctx(), Request{Ref: Ref{Kind: KindIP, Namespace: fpNS, Name: "nolen"}, Index: index(KindIP), CreatePrefix: true}); err == nil {
		t.Error("a dynamic prefix claim without a length accepted")
	}
}

// ListByLabel returns a claim as the kind its pool's type serves, and no other.
func TestFirstPartyListByLabelFiltersOnPoolType(t *testing.T) {
	sel := map[string]string{LabelCorrelationID: "c1"}
	claim := func(name, pool string) client.Object {
		return &fabricv1.IdentifierClaim{ObjectMeta: metav1.ObjectMeta{Namespace: fpNS, Name: name, Labels: sel},
			Spec: fabricv1.IdentifierClaimSpec{PoolRef: fabricv1.IdentifierPoolRef{Name: fabricv1.DNSLabel(pool)}}}
	}
	genid := &fabricv1.IdentifierPool{ObjectMeta: metav1.ObjectMeta{Namespace: fpNS, Name: "gen"},
		Spec: fabricv1.IdentifierPoolSpec{Type: fabricv1.IdentifierTypeGENID, Range: &fabricv1.IdentifierRange{Start: 1, End: 9}}}
	seam, _ := firstPartyImpl().newSeam(t, true, nil, genid,
		claim("v", index(KindVLAN)), claim("n", index(KindGENID)), claim("g", "gen"), claim("i", index(KindIP)),
		claim("a", index(KindASN)), claim("orphan", "no-such-pool"))
	for k, want := range map[Kind]string{KindVLAN: "v", KindGENID: "g,n", KindIP: "i", KindASN: "a"} {
		got, err := seam.ListByLabel(ctx(), k, fpNS, sel)
		if err != nil {
			t.Fatal(err)
		}
		var names []string
		for _, c := range got {
			names = append(names, c.Name)
			if c.Kind != k {
				t.Errorf("%s: %s reported as %s", k, c.Name, c.Kind)
			}
		}
		if strings.Join(names, ",") != want {
			t.Errorf("%s: %v, want %s", k, names, want)
		}
	}
}

// Ready=Unknown (e.g. PoolNotFound) is pending: no reason or message crosses the seam, so
// the Fabric reconciler never reads it as a refusal; Ready=False does.
func TestFirstPartyUnknownIsPending(t *testing.T) {
	c := &fabricv1.IdentifierClaim{ObjectMeta: metav1.ObjectMeta{Namespace: fpNS, Name: "wait"},
		Spec: fabricv1.IdentifierClaimSpec{PoolRef: fabricv1.IdentifierPoolRef{Name: "later"}, Requested: "1500"},
		Status: fabricv1.IdentifierClaimStatus{Conditions: []metav1.Condition{{Type: "Ready", Status: metav1.ConditionUnknown,
			Reason: "PoolNotFound", Message: "IdentifierPool agentic-netops-allocation/later does not exist", LastTransitionTime: metav1.Now()}}}}
	seam, _ := firstPartyImpl().newSeam(t, true, nil, c)
	got, err := seam.Get(ctx(), Ref{Kind: KindVLAN, Namespace: fpNS, Name: "wait"})
	if err != nil || got.Ready || got.Bound() || got.Reason != "" || got.Message != "" || got.Index != "later" {
		t.Errorf("Ready=Unknown claim = %+v %v", got, err)
	}
}
