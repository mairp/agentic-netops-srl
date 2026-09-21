package kuid

// The second implementation behind the one seam (T178; data-model.md §23,
// contracts/kuid-claim-profiles.md §7): the first-party allocation authority's
// IdentifierClaims (fabric.agentic-netops.io/v1alpha1), adopted by the recorded decision
// docs/decisions/allocator-substitution.md and selected by versions.lock.yaml's
// allocationAuthority.kind through New — from nothing else. The deterministic claim names,
// the adoption rule and the error semantics above the seam are unchanged: a create that
// errors, or a read that errors with anything but NotFound, is the authority failing to
// answer (AD-56), never "no such claim".

import (
	"context"
	"fmt"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
)

// FirstPartyNamespace is where the substitute's pools and claims live.
const FirstPartyNamespace = "agentic-netops-allocation"

// firstPartyIndex is the one index kind of the substitute, for every claim kind.
var firstPartyIndex = IndexType{Group: fabricv1.GroupVersion.Group, Kind: "IdentifierPool"}

// poolTypes is which IdentifierPool spec.type serves each claim kind.
var poolTypes = map[Kind][]fabricv1.IdentifierType{
	KindIP:    {fabricv1.IdentifierTypeIP},
	KindASN:   {fabricv1.IdentifierTypeASN},
	KindVLAN:  {fabricv1.IdentifierTypeVLAN},
	KindGENID: {fabricv1.IdentifierTypeVNI, fabricv1.IdentifierTypeGENID},
}

// FirstParty implements Claims over IdentifierClaims in the Request's namespace.
type FirstParty struct {
	c client.Client
}

var _ Claims = (*FirstParty)(nil)

// NewFirstParty returns the first-party implementation of Claims over c, whose scheme must
// carry fabric.agentic-netops.io/v1alpha1.
func NewFirstParty(c client.Client) *FirstParty { return &FirstParty{c: c} }

// New selects the implementation for the lock file's allocationAuthority.kind: "kuid" or
// "first-party". Anything else is refused.
func New(authorityKind string, c client.Client) (Claims, error) {
	switch authorityKind {
	case AuthorityKuid:
		return NewUpstream(c), nil
	case AuthorityFirstParty:
		return NewFirstParty(c), nil
	}
	return nil, fmt.Errorf("allocationAuthority.kind %q is not %q or %q", authorityKind, AuthorityKuid, AuthorityFirstParty)
}

// Index implements Claims: every kind is claimed from an IdentifierPool.
func (f *FirstParty) Index(Kind) IndexType { return firstPartyIndex }

// Authority implements Claims.
func (f *FirstParty) Authority() string { return AuthorityFirstParty }

// Claim implements Claims: a dynamic claim, no spec.requested. A dynamic IP PREFIX claim
// (CreatePrefix) carries spec.prefixLength; a dynamic IP address claim carries none.
func (f *FirstParty) Claim(ctx context.Context, req Request) (Claimed, error) {
	obj, err := buildIdentifierClaim(req, "")
	if err != nil {
		return Claimed{}, err
	}
	if req.Kind == KindIP && req.CreatePrefix {
		if req.PrefixLength == nil {
			return Claimed{}, fmt.Errorf("%s: a dynamic prefix claim needs a prefix length", req.Ref)
		}
		pl := int32(*req.PrefixLength)
		obj.Spec.PrefixLength = &pl
	}
	return f.create(ctx, req, obj, "")
}

// ClaimValue implements Claims: a claim stating value in spec.requested.
func (f *FirstParty) ClaimValue(ctx context.Context, req Request, value string) (Claimed, error) {
	if value == "" {
		return Claimed{}, fmt.Errorf("%s: a stated value is required", req.Ref)
	}
	obj, err := buildIdentifierClaim(req, value)
	if err != nil {
		return Claimed{}, err
	}
	return f.create(ctx, req, obj, value)
}

func (f *FirstParty) create(ctx context.Context, req Request, obj *fabricv1.IdentifierClaim, stated string) (Claimed, error) {
	err := f.c.Create(ctx, obj)
	if apierrors.IsAlreadyExists(err) {
		existing, gerr := f.Get(ctx, req.Ref)
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
	return f.Get(ctx, req.Ref)
}

// Release implements Claims. The claim's finalizer frees its value before the claim goes.
func (f *FirstParty) Release(ctx context.Context, ref Ref) error {
	obj := &fabricv1.IdentifierClaim{ObjectMeta: metav1.ObjectMeta{Namespace: ref.Namespace, Name: ref.Name}}
	if err := f.c.Delete(ctx, obj); err != nil && !apierrors.IsNotFound(err) {
		return fmt.Errorf("release %s: %w", ref, err)
	}
	return nil
}

// Get implements Claims.
func (f *FirstParty) Get(ctx context.Context, ref Ref) (Claimed, error) {
	obj := &fabricv1.IdentifierClaim{}
	if err := f.c.Get(ctx, client.ObjectKey{Namespace: ref.Namespace, Name: ref.Name}, obj); err != nil {
		if apierrors.IsNotFound(err) {
			return Claimed{}, fmt.Errorf("%s: %w", ref, ErrNotFound)
		}
		return Claimed{}, fmt.Errorf("get %s: %w", ref, err)
	}
	return identifierClaimed(ref.Kind, obj), nil
}

// ListByLabel implements Claims: client.MatchingLabels selects on metadata.labels (the
// kind has no other label set), and a claim is of kind when its pool's spec.type serves
// it — ip for IP, asn for ASN, vlan for VLAN, vni or genid for GENID.
func (f *FirstParty) ListByLabel(ctx context.Context, kind Kind, namespace string, labels map[string]string) ([]Claimed, error) {
	if len(labels) == 0 {
		return nil, fmt.Errorf("ListByLabel %s: an empty selector would list every claim", kind)
	}
	types, ok := poolTypes[kind]
	if !ok {
		return nil, fmt.Errorf("unknown claim kind %q", kind)
	}
	claims := &fabricv1.IdentifierClaimList{}
	if err := f.c.List(ctx, claims, client.InNamespace(namespace), client.MatchingLabels(labels)); err != nil {
		return nil, fmt.Errorf("list %s claims in %s: %w", kind, namespace, err)
	}
	if len(claims.Items) == 0 {
		return nil, nil
	}
	pools := &fabricv1.IdentifierPoolList{}
	if err := f.c.List(ctx, pools, client.InNamespace(namespace)); err != nil {
		return nil, fmt.Errorf("list pools in %s: %w", namespace, err)
	}
	serves := map[string]bool{}
	for _, p := range pools.Items {
		for _, t := range types {
			if p.Spec.Type == t {
				serves[p.Name] = true
			}
		}
	}
	out := make([]Claimed, 0, len(claims.Items))
	for i := range claims.Items {
		c := &claims.Items[i]
		if serves[string(c.Spec.PoolRef.Name)] {
			out = append(out, identifierClaimed(kind, c))
		}
	}
	return out, nil
}

func buildIdentifierClaim(req Request, stated string) (*fabricv1.IdentifierClaim, error) {
	if req.Name == "" || req.Namespace == "" || req.Index == "" {
		return nil, fmt.Errorf("%s: name, namespace and index are required", req.Ref)
	}
	if _, ok := poolTypes[req.Kind]; !ok {
		return nil, fmt.Errorf("unknown claim kind %q", req.Kind)
	}
	return &fabricv1.IdentifierClaim{
		ObjectMeta: metav1.ObjectMeta{Namespace: req.Namespace, Name: req.Name, Labels: copyLabels(req.Labels)},
		Spec: fabricv1.IdentifierClaimSpec{
			PoolRef:   fabricv1.IdentifierPoolRef{Name: fabricv1.DNSLabel(req.Index)},
			Requested: stated,
		},
	}, nil
}

// identifierClaimed maps a claim to the seam. Reason and Message are carried only for
// Ready=False — the authority's answer (Conflict naming the holder, OutOfRange, Exhausted,
// Invalid); Ready=Unknown (pending, e.g. PoolNotFound) leaves them empty, so nothing above
// the seam reads a wait as a refusal.
func identifierClaimed(k Kind, o *fabricv1.IdentifierClaim) Claimed {
	c := Claimed{
		Ref:    Ref{Kind: k, Namespace: o.Namespace, Name: o.Name},
		Index:  string(o.Spec.PoolRef.Name),
		Labels: copyLabels(o.Labels),
		Stated: o.Spec.Requested,
		Value:  o.Status.Value,
	}
	if ready := meta.FindStatusCondition(o.Status.Conditions, "Ready"); ready != nil {
		c.Ready = ready.Status == metav1.ConditionTrue
		if ready.Status == metav1.ConditionFalse {
			c.Reason, c.Message = ready.Reason, ready.Message
		}
	}
	return c
}
