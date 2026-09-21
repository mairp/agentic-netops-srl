package kuid

import (
	"context"
	"fmt"
	"strconv"

	"github.com/henderiw/iputil"
	condv1alpha1 "github.com/kform-dev/choreo/apis/condition/v1alpha1"
	asv1alpha1 "github.com/kuidio/kuid/apis/backend/as/v1alpha1"
	genidv1alpha1 "github.com/kuidio/kuid/apis/backend/genid/v1alpha1"
	ipamv1alpha1 "github.com/kuidio/kuid/apis/backend/ipam/v1alpha1"
	vlanv1alpha1 "github.com/kuidio/kuid/apis/backend/vlan/v1alpha1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// AddToScheme registers the upstream ipam, as, vlan and genid be.kuid.dev
// v1alpha1 types (Index, Claim and Entry of each) at the pinned v0.0.13.
func AddToScheme(s *runtime.Scheme) error {
	for _, add := range []func(*runtime.Scheme) error{
		ipamv1alpha1.AddToScheme, asv1alpha1.AddToScheme, vlanv1alpha1.AddToScheme, genidv1alpha1.AddToScheme,
	} {
		if err := add(s); err != nil {
			return err
		}
	}
	return nil
}

// Upstream implements Claims over the pinned kuid-server's served APIs, using
// the upstream types unchanged (FR-098).
type Upstream struct {
	c client.Client
}

var _ Claims = (*Upstream)(nil)

// NewUpstream returns the kuid implementation of Claims over c, whose scheme
// must carry AddToScheme.
func NewUpstream(c client.Client) *Upstream { return &Upstream{c: c} }

// Claim implements Claims: a dynamic claim, neither spec.id nor spec.range.
func (u *Upstream) Claim(ctx context.Context, req Request) (Claimed, error) {
	obj, err := buildClaim(req, nil)
	if err != nil {
		return Claimed{}, err
	}
	return u.create(ctx, req, obj, "")
}

// ClaimValue implements Claims: a claim stating value in spec.id.
func (u *Upstream) ClaimValue(ctx context.Context, req Request, value string) (Claimed, error) {
	if value == "" {
		return Claimed{}, fmt.Errorf("%s: a stated value is required", req.Ref)
	}
	obj, err := buildClaim(req, &value)
	if err != nil {
		return Claimed{}, err
	}
	return u.create(ctx, req, obj, value)
}

func (u *Upstream) create(ctx context.Context, req Request, obj client.Object, stated string) (Claimed, error) {
	err := u.c.Create(ctx, obj)
	if apierrors.IsAlreadyExists(err) {
		existing, gerr := u.Get(ctx, req.Ref)
		if gerr != nil {
			return Claimed{}, gerr
		}
		if existing.Stated != stated {
			return existing, fmt.Errorf("%s already exists stating %q, not %q; a claim is never moved", req.Ref, existing.Stated, stated)
		}
		return existing, nil
	}
	if err != nil {
		return Claimed{}, fmt.Errorf("create %s: %w", req.Ref, err)
	}
	// Read back what the authority reports (status.id and Ready).
	return u.Get(ctx, req.Ref)
}

// Release implements Claims.
func (u *Upstream) Release(ctx context.Context, ref Ref) error {
	obj, err := newClaim(ref.Kind)
	if err != nil {
		return err
	}
	obj.SetNamespace(ref.Namespace)
	obj.SetName(ref.Name)
	if err := u.c.Delete(ctx, obj); err != nil && !apierrors.IsNotFound(err) {
		return fmt.Errorf("release %s: %w", ref, err)
	}
	return nil
}

// Get implements Claims.
func (u *Upstream) Get(ctx context.Context, ref Ref) (Claimed, error) {
	obj, err := newClaim(ref.Kind)
	if err != nil {
		return Claimed{}, err
	}
	if err := u.c.Get(ctx, client.ObjectKey{Namespace: ref.Namespace, Name: ref.Name}, obj); err != nil {
		if apierrors.IsNotFound(err) {
			return Claimed{}, fmt.Errorf("%s: %w", ref, ErrNotFound)
		}
		return Claimed{}, fmt.Errorf("get %s: %w", ref, err)
	}
	return toClaimed(ref.Kind, obj)
}

// ListByLabel implements Claims. The selector is client.MatchingLabels, which
// the aggregated apiserver matches against metadata.labels; spec.labels are
// never consulted (AD-32).
func (u *Upstream) ListByLabel(ctx context.Context, kind Kind, namespace string, labels map[string]string) ([]Claimed, error) {
	if len(labels) == 0 {
		return nil, fmt.Errorf("ListByLabel %s: an empty selector would list every claim", kind)
	}
	list, err := newClaimList(kind)
	if err != nil {
		return nil, err
	}
	if err := u.c.List(ctx, list, client.InNamespace(namespace), client.MatchingLabels(labels)); err != nil {
		return nil, fmt.Errorf("list %s claims in %s: %w", kind, namespace, err)
	}
	items, err := listItems(kind, list)
	if err != nil {
		return nil, err
	}
	out := make([]Claimed, 0, len(items))
	for _, it := range items {
		c, err := toClaimed(kind, it)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, nil
}

// ---------------------------------------------------------------------------
// Mapping between the seam and the upstream types.
// ---------------------------------------------------------------------------

func newClaim(k Kind) (client.Object, error) {
	switch k {
	case KindIP:
		return &ipamv1alpha1.IPClaim{}, nil
	case KindASN:
		return &asv1alpha1.ASClaim{}, nil
	case KindVLAN:
		return &vlanv1alpha1.VLANClaim{}, nil
	case KindGENID:
		return &genidv1alpha1.GENIDClaim{}, nil
	}
	return nil, fmt.Errorf("unknown claim kind %q", k)
}

func newClaimList(k Kind) (client.ObjectList, error) {
	switch k {
	case KindIP:
		return &ipamv1alpha1.IPClaimList{}, nil
	case KindASN:
		return &asv1alpha1.ASClaimList{}, nil
	case KindVLAN:
		return &vlanv1alpha1.VLANClaimList{}, nil
	case KindGENID:
		return &genidv1alpha1.GENIDClaimList{}, nil
	}
	return nil, fmt.Errorf("unknown claim kind %q", k)
}

func listItems(k Kind, l client.ObjectList) ([]client.Object, error) {
	var out []client.Object
	switch k {
	case KindIP:
		for i := range l.(*ipamv1alpha1.IPClaimList).Items {
			out = append(out, &l.(*ipamv1alpha1.IPClaimList).Items[i])
		}
	case KindASN:
		for i := range l.(*asv1alpha1.ASClaimList).Items {
			out = append(out, &l.(*asv1alpha1.ASClaimList).Items[i])
		}
	case KindVLAN:
		for i := range l.(*vlanv1alpha1.VLANClaimList).Items {
			out = append(out, &l.(*vlanv1alpha1.VLANClaimList).Items[i])
		}
	case KindGENID:
		for i := range l.(*genidv1alpha1.GENIDClaimList).Items {
			out = append(out, &l.(*genidv1alpha1.GENIDClaimList).Items[i])
		}
	default:
		return nil, fmt.Errorf("unknown claim kind %q", k)
	}
	return out, nil
}

// buildClaim renders the upstream claim of req. stated == nil is the dynamic
// form: spec.id and spec.range are both left unset.
func buildClaim(req Request, stated *string) (client.Object, error) {
	if req.Name == "" || req.Namespace == "" || req.Index == "" {
		return nil, fmt.Errorf("%s: name, namespace and index are required", req.Ref)
	}
	meta := metav1.ObjectMeta{Namespace: req.Namespace, Name: req.Name, Labels: copyLabels(req.Labels)}
	switch req.Kind {
	case KindIP:
		c := &ipamv1alpha1.IPClaim{ObjectMeta: meta, Spec: ipamv1alpha1.IPClaimSpec{Index: req.Index}}
		if req.AddressFamily != "" {
			af := iputil.AddressFamily(req.AddressFamily)
			c.Spec.AddressFamily = &af
		}
		c.Spec.PrefixLength = req.PrefixLength
		if req.CreatePrefix && stated == nil {
			t := true
			c.Spec.CreatePrefix = &t
		}
		if stated != nil {
			v := *stated
			if req.IPPrefix {
				c.Spec.Prefix = &v
			} else {
				c.Spec.Address = &v
			}
		}
		return c, nil
	case KindASN:
		c := &asv1alpha1.ASClaim{ObjectMeta: meta, Spec: asv1alpha1.ASClaimSpec{Index: req.Index}}
		if stated != nil {
			v, err := parse32(req.Ref, *stated)
			if err != nil {
				return nil, err
			}
			c.Spec.ID = &v
		}
		return c, nil
	case KindVLAN:
		c := &vlanv1alpha1.VLANClaim{ObjectMeta: meta, Spec: vlanv1alpha1.VLANClaimSpec{Index: req.Index}}
		if stated != nil {
			v, err := parse32(req.Ref, *stated)
			if err != nil {
				return nil, err
			}
			c.Spec.ID = &v
		}
		return c, nil
	case KindGENID:
		c := &genidv1alpha1.GENIDClaim{ObjectMeta: meta, Spec: genidv1alpha1.GENIDClaimSpec{Index: req.Index}}
		if stated != nil {
			v, err := strconv.ParseUint(*stated, 10, 64)
			if err != nil {
				return nil, fmt.Errorf("%s: value %q is not an unsigned integer", req.Ref, *stated)
			}
			c.Spec.ID = &v
		}
		return c, nil
	}
	return nil, fmt.Errorf("unknown claim kind %q", req.Kind)
}

func toClaimed(k Kind, obj client.Object) (Claimed, error) {
	c := Claimed{
		Ref:    Ref{Kind: k, Namespace: obj.GetNamespace(), Name: obj.GetName()},
		Labels: copyLabels(obj.GetLabels()),
	}
	var ready condv1alpha1.Condition
	switch o := obj.(type) {
	case *ipamv1alpha1.IPClaim:
		c.Index = o.Spec.Index
		c.Stated = firstOf(o.Spec.Address, o.Spec.Prefix)
		c.Value = firstOf(o.Status.Address, o.Status.Prefix)
		ready = o.Status.GetCondition(condv1alpha1.ConditionTypeReady)
	case *asv1alpha1.ASClaim:
		c.Index = o.Spec.Index
		c.Stated = fmt32(o.Spec.ID)
		c.Value = fmt32(o.Status.ID)
		ready = o.Status.GetCondition(condv1alpha1.ConditionTypeReady)
	case *vlanv1alpha1.VLANClaim:
		c.Index = o.Spec.Index
		c.Stated = fmt32(o.Spec.ID)
		c.Value = fmt32(o.Status.ID)
		ready = o.Status.GetCondition(condv1alpha1.ConditionTypeReady)
	case *genidv1alpha1.GENIDClaim:
		c.Index = o.Spec.Index
		c.Stated = fmt64(o.Spec.ID)
		c.Value = fmt64(o.Status.ID)
		ready = o.Status.GetCondition(condv1alpha1.ConditionTypeReady)
	default:
		return Claimed{}, fmt.Errorf("unexpected claim object %T", obj)
	}
	c.Ready = ready.Status == metav1.ConditionTrue
	c.Reason = ready.Reason
	c.Message = ready.Message
	return c, nil
}

func parse32(ref Ref, s string) (uint32, error) {
	v, err := strconv.ParseUint(s, 10, 32)
	if err != nil {
		return 0, fmt.Errorf("%s: value %q is not a 32-bit unsigned integer", ref, s)
	}
	return uint32(v), nil
}

func fmt32(p *uint32) string {
	if p == nil {
		return ""
	}
	return strconv.FormatUint(uint64(*p), 10)
}

func fmt64(p *uint64) string {
	if p == nil {
		return ""
	}
	return strconv.FormatUint(*p, 10)
}

func firstOf(ps ...*string) string {
	for _, p := range ps {
		if p != nil && *p != "" {
			return *p
		}
	}
	return ""
}

func copyLabels(in map[string]string) map[string]string {
	if in == nil {
		return nil
	}
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}
