// Package kuid is the provider's one adapter seam to the allocation authority
// (FR-062, FR-104, CD-03). Everything above the seam — the Fabric reconciler's
// underlay claims, the Network reconciler's claim resolution (T171) and its
// finalizer (T060) — speaks only the Claims interface of this file. The
// implementation over the pinned kuid-server's served `*.be.kuid.dev`
// Index/Claim/Entry APIs lives in upstream.go, using the upstream Go types
// unchanged; the recorded substitute of data-model.md §23 would be a second
// implementation of the same interface and nothing above it would change.
//
// There is no local pool, lease or fallback here: every value comes from a
// claim against the authority and is reported by it (FR-104).
package kuid

import (
	"context"
	"errors"
	"fmt"
)

// Kind is an identifier kind the platform claims.
type Kind string

const (
	// KindIP is an address or prefix from an ipam.be.kuid.dev IPIndex.
	KindIP Kind = "IP"
	// KindASN is an AS number from an as.be.kuid.dev ASIndex.
	KindASN Kind = "ASN"
	// KindVLAN is a VLAN from a vlan.be.kuid.dev VLANIndex.
	KindVLAN Kind = "VLAN"
	// KindGENID is a generic id (the VNI) from a genid.be.kuid.dev GENIDIndex.
	KindGENID Kind = "GENID"
)

// Kinds is every kind the seam serves.
func Kinds() []Kind { return []Kind{KindIP, KindASN, KindVLAN, KindGENID} }

// Canonical metadata.labels selectors (kuid-claim-profiles.md §3, AD-32).
const (
	LabelCorrelationID    = "agentic-netops.io/correlation-id"
	LabelNetworkNamespace = "agentic-netops.io/network-namespace"
	LabelNetworkName      = "agentic-netops.io/network-name"
)

// Ref names one claim.
type Ref struct {
	Kind      Kind
	Namespace string
	Name      string
}

func (r Ref) String() string { return fmt.Sprintf("%s claim %s/%s", r.Kind, r.Namespace, r.Name) }

// Request is a claim to create.
type Request struct {
	Ref
	// Index is the index (pool) the claim is made against.
	Index string
	// Labels are written to the claim's metadata.labels — the only label set the
	// authority's List filters on (AD-32). They are never written to spec.labels.
	Labels map[string]string

	// IP only. IPPrefix says a stated IP value is a prefix (spec.prefix) rather
	// than an address (spec.address). AddressFamily ("ipv4"/"ipv6") and
	// PrefixLength shape a dynamic IP claim.
	IPPrefix      bool
	AddressFamily string
	PrefixLength  *uint32
	// CreatePrefix makes a dynamic IP claim a dynamic PREFIX claim
	// (spec.createPrefix; the authority then needs PrefixLength) — the
	// Fabric reconciler's /31 link prefixes. Without it a dynamic IP claim is
	// a dynamic address claim.
	CreatePrefix bool
}

// Claimed is a claim as the authority reports it.
type Claimed struct {
	Ref
	Index string
	// Labels are the claim's metadata.labels.
	Labels map[string]string
	// Stated is the value the claim states in spec (spec.id, or spec.address /
	// spec.prefix for IP); empty for a dynamic claim.
	Stated string
	// Value is the value the authority reports in status (status.id, or
	// status.address / status.prefix for IP); empty until allocated.
	Value string
	// Ready is the claim's Ready condition being True.
	Ready bool
	// Reason and Message are the Ready condition's, e.g. the authority's refusal
	// naming the holder when it is False.
	Reason  string
	Message string
}

// Bound reports whether the claim is Ready and reports a value. A claim that
// reports no value is never proceeded on (R-31).
func (c Claimed) Bound() bool { return c.Ready && c.Value != "" }

// ErrNotFound is the authority's ANSWER that no such claim exists. Any other
// error is the authority failing to answer and must never be read as "no
// such claim" nor mapped to AllocationConflict (AD-56).
var ErrNotFound = errors.New("claim not found")

// IsNotFound reports whether err is the authority's not-found answer.
func IsNotFound(err error) bool { return errors.Is(err, ErrNotFound) }

// Claims is the adapter seam over the allocation authority.
type Claims interface {
	// Claim creates a dynamic claim: it states neither spec.id nor spec.range
	// (for IP neither an address, a prefix nor a range), so the authority
	// chooses the value. The returned Claimed is what the authority reports
	// after the create; callers wait on Bound().
	Claim(ctx context.Context, req Request) (Claimed, error)
	// ClaimValue creates a claim stating value in spec.id (spec.address or
	// spec.prefix for IP) — FR-109. The authority binds it (status.id with
	// Ready=True) or refuses it (Ready=False naming the holder). An existing
	// claim of the same name stating the same value is returned unchanged; one
	// stating another value is an error, never moved.
	ClaimValue(ctx context.Context, req Request, value string) (Claimed, error)
	// Release deletes the claim. A claim already gone is not an error.
	Release(ctx context.Context, ref Ref) error
	// Get reads one claim; ErrNotFound when there is none.
	Get(ctx context.Context, ref Ref) (Claimed, error)
	// ListByLabel lists the claims of kind in namespace whose metadata.labels
	// carry every key/value of labels. It never selects on spec.labels (AD-32).
	ListByLabel(ctx context.Context, kind Kind, namespace string, labels map[string]string) ([]Claimed, error)
	// Index is the group and kind of the index (pool) a claim of kind k is made against
	// under this authority: what a Fabric's pool references must name (T182). Consumers
	// read it here and never write a literal.
	Index(k Kind) IndexType
	// Authority is the allocationAuthority.kind this implementation serves: AuthorityKuid
	// or AuthorityFirstParty.
	Authority() string
}

// IndexType is the API group and kind of an allocation index.
type IndexType struct {
	Group string
	Kind  string
}

func (t IndexType) String() string { return t.Group + "/" + t.Kind }

// The allocationAuthority.kind values of versions.lock.yaml (data-model.md §23).
const (
	AuthorityKuid       = "kuid"
	AuthorityFirstParty = "first-party"
)
