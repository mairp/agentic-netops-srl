package network

// Provider-side claim resolution (T171; contracts/reconciliation.md Rule 3,
// contracts/kuid-claim-profiles.md §5 and §8; FR-109, FR-104, AD-09, AD-16, AD-32, AD-33,
// AD-42, AD-44, AD-47, AD-51, AD-56) over the one adapter seam, pkg/kuid. There is no local
// pool: every value is the object's own stated value, arbitrated by the allocation authority.
//
//   - Adopt, VNI and VLAN alike, on three things together: the claim carries the object's
//     correlation label (metadata.labels agentic-netops.io/correlation-id — the only label set
//     the authority selects on, AD-32), bears the deterministic name
//     <namespace>.<name>.<role> — l2vni-<bridgeDomain>, l3vni-<router>, vlan-<entry> — and
//     is bound reporting exactly the value the object carries in that field (AD-42, R-45). A
//     copied correlation label adopts nothing (CHK033): the name is the object's own.
//   - A VLAN claim is matched only against spec.vlans[].vlan or spec.bridgeDomains[].vlan
//     (AD-51). A VLAN in 100–999 is a named VLAN and needs no claim; one in 1000–4000 must be
//     backed by an adoptable claim, else Accepted=False/AllocationConflict naming the VLAN and
//     both bands (AD-33). An ip-vrf attachment's VLAN in 1000–4000 is that refusal by
//     construction, with no lookup. An accessLists-only object is outside the band rule: its
//     attachment VLAN is a reference (AD-47).
//   - Otherwise, for a VNI only and never on a deleting object, the stated value is claimed
//     under the deterministic name, labelled with the object (network-namespace, network-name,
//     and the correlation label when it carries one), before any Config exists. The authority
//     arbitrates: its refusal (held by another owner, or outside the index's band) is
//     AllocationConflict naming the value and the holder it names; no other value is tried.
//   - The decision is recorded once per value in status.claimRefs (origin adopted|created)
//     and never re-evaluated or dropped; only finalization releases an entry (T060).
//   - A pkg/kuid error — as opposed to its ErrNotFound answer — is a dependency wait retried
//     with backoff: nothing adopted, nothing refused, nothing rendered (AD-56).
//
// Where the claims live. The allocation namespace is the one the Fabric's own pool
// references name (spec.underlay.*PoolRef.namespace — kuid-system under kuid,
// agentic-netops-allocation under first-party), and the indices are the Fabric's service
// indices <fabric>-vni and <fabric>-vlan (deploy/kuid/indices, deploy/allocation/pools).
// Settings.ClaimNamespace / VNIIndex / VLANIndex override either.

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/pkg/kuid"
)

// The platform's VLAN bands (AD-33) — stated in every band refusal.
const (
	NamingBandLow      = 100
	NamingBandHigh     = 999
	AllocationBandLow  = 1000
	AllocationBandHigh = 4000
)

// Role prefixes of the deterministic claim name <namespace>.<name>.<role> (kuid-claim-profiles
// §5): one scheme, whoever made the claim.
const (
	RoleL2VNI = "l2vni-"
	RoleL3VNI = "l3vni-"
	RoleVLAN  = "vlan-"
)

// ClaimName is the deterministic claim name of one field of one object.
func ClaimName(namespace, name, role string) string { return namespace + "." + name + "." + role }

// bandsText names both VLAN bands.
func bandsText() string {
	return fmt.Sprintf("the naming band %d–%d is named from and claims nothing; the allocation band %d–%d is the allocation authority's and must be backed by an adoptable claim",
		NamingBandLow, NamingBandHigh, AllocationBandLow, AllocationBandHigh)
}

func inAllocationBand(v int64) bool { return v >= AllocationBandLow && v <= AllocationBandHigh }

// carried is one allocated value an object carries: a VNI of a bridgeDomains[]/routers[]
// entry, or an allocation-band VLAN of a vlans[]/bridgeDomains[] entry.
type carried struct {
	kind  fabricv1.ClaimIndexKind
	role  string // l2vni-<bd>, l3vni-<router>, vlan-<entry>
	field string // the spec field, for messages
	value int64
}

// claimTarget is where one Network's claims live.
type claimTarget struct {
	namespace string
	vniIndex  string
	vlanIndex string
}

// claimTargetFor derives the allocation namespace and the service indices from the Fabric
// (overridable by Settings).
func (r *Reconciler) claimTargetFor(f *fabricv1.Fabric) claimTarget {
	ct := claimTarget{namespace: r.Settings.ClaimNamespace, vniIndex: r.Settings.VNIIndex, vlanIndex: r.Settings.VLANIndex}
	// Under the first-party substitute every claim lives in its one namespace, whatever the
	// Fabric's pool references say: a Fabric re-applied with kuid-system refs (and refused) must
	// not send the finalizer's release to a namespace the provider cannot read (T153 §26a).
	if ct.namespace == "" && r.Claims != nil && r.Claims.Authority() == kuid.AuthorityFirstParty {
		ct.namespace = kuid.FirstPartyNamespace
	}
	if ct.namespace == "" && f != nil {
		for _, p := range []*fabricv1.PoolRef{f.Spec.Underlay.ASNPoolRef, f.Spec.Underlay.LoopbackPoolRef, f.Spec.Underlay.LinkPoolRef} {
			if p != nil && p.Namespace != "" {
				ct.namespace = p.Namespace
				break
			}
		}
	}
	if ct.namespace == "" {
		if r.Claims != nil && r.Claims.Authority() == kuid.AuthorityFirstParty {
			ct.namespace = kuid.FirstPartyNamespace
		} else {
			ct.namespace = DefaultKuidNamespace
		}
	}
	if f != nil {
		if ct.vniIndex == "" {
			ct.vniIndex = f.Name + "-vni"
		}
		if ct.vlanIndex == "" {
			ct.vlanIndex = f.Name + "-vlan"
		}
	}
	return ct
}

// DefaultKuidNamespace is kuid's namespace (deploy/kuid/indices).
const DefaultKuidNamespace = "kuid-system"

// carriedValues are the values of n that a claim backs: every L2VNI and L3VNI, and every VLAN
// of a vlans[] or bridgeDomains[] entry that lies in the allocation band. An accessLists-only
// object carries none (AD-47); an attachment's VLAN is never one (AD-51).
func carriedValues(n *fabricv1.Network) []carried {
	var out []carried
	for _, v := range n.Spec.VLANs {
		if inAllocationBand(int64(v.VLAN)) {
			out = append(out, carried{kind: fabricv1.ClaimIndexVLAN, role: RoleVLAN + string(v.Name),
				field: fmt.Sprintf("spec.vlans[%s].vlan", v.Name), value: int64(v.VLAN)})
		}
	}
	for _, bd := range n.Spec.BridgeDomains {
		if inAllocationBand(int64(bd.VLAN)) {
			out = append(out, carried{kind: fabricv1.ClaimIndexVLAN, role: RoleVLAN + string(bd.Name),
				field: fmt.Sprintf("spec.bridgeDomains[%s].vlan", bd.Name), value: int64(bd.VLAN)})
		}
		out = append(out, carried{kind: fabricv1.ClaimIndexGENID, role: RoleL2VNI + string(bd.Name),
			field: fmt.Sprintf("spec.bridgeDomains[%s].l2vni", bd.Name), value: int64(bd.L2VNI)})
	}
	for _, rt := range n.Spec.Routers {
		out = append(out, carried{kind: fabricv1.ClaimIndexGENID, role: RoleL3VNI + string(rt.Name),
			field: fmt.Sprintf("spec.routers[%s].l3vni", rt.Name), value: int64(rt.L3VNI)})
	}
	return out
}

// isACLOnly is an accessLists-only object (AD-47).
func isACLOnly(n *fabricv1.Network) bool {
	s := &n.Spec
	return len(s.AccessLists) > 0 && len(s.VLANs) == 0 && len(s.BridgeDomains) == 0 && len(s.Routers) == 0
}

// ipvrfBandConflicts are the ip-vrf attachments carrying an allocation-band VLAN: no claim is
// ever allocated behind one and none has a name, so each is AllocationConflict by
// construction, with no lookup (AD-51).
func ipvrfBandConflicts(n *fabricv1.Network) []string {
	s := &n.Spec
	if len(s.Routers) == 0 || len(s.BridgeDomains) > 0 {
		return nil
	}
	var out []string
	for _, a := range s.Attachments {
		if a.VLAN != nil && inAllocationBand(int64(*a.VLAN)) {
			out = append(out, fmt.Sprintf("VLAN %d of the ip-vrf attachment %s %s lies in the allocation band %d–%d: an ip-vrf attachment's VLAN is named or absent and never allocated, so no claim can back it (AD-51); %s",
				*a.VLAN, a.Node, a.Attachment, AllocationBandLow, AllocationBandHigh, bandsText()))
		}
	}
	return out
}

// claimOutcome is what the claim gate found.
type claimOutcome struct {
	// conflicts are the AllocationConflict answers, each naming the value and the holder or
	// the band(s).
	conflicts []string
	// pending are the claims the authority has not yet bound.
	pending []string
}

func refKind(k fabricv1.ClaimIndexKind) kuid.Kind {
	if k == fabricv1.ClaimIndexVLAN {
		return kuid.KindVLAN
	}
	return kuid.KindGENID
}

func findRef(refs []fabricv1.ClaimRef, kind fabricv1.ClaimIndexKind, name string) *fabricv1.ClaimRef {
	for i := range refs {
		if refs[i].IndexKind == kind && refs[i].Name == name {
			return &refs[i]
		}
	}
	return nil
}

// adoptable looks for the claim the three-part rule adopts: carrying the object's
// correlation label, named name, bound and reporting value. An object with no correlation
// label adopts nothing. The error is the authority failing to answer (AD-56).
func (r *Reconciler) adoptable(ctx context.Context, n *fabricv1.Network, ct claimTarget, c carried) (*kuid.Claimed, error) {
	cid := n.Labels[kuid.LabelCorrelationID]
	if cid == "" {
		return nil, nil
	}
	name := ClaimName(n.Namespace, n.Name, c.role)
	list, err := r.Claims.ListByLabel(ctx, refKind(c.kind), ct.namespace, map[string]string{kuid.LabelCorrelationID: cid})
	if err != nil {
		return nil, fmt.Errorf("list %s claims labelled %s=%s in %s: %w", refKind(c.kind), kuid.LabelCorrelationID, cid, ct.namespace, err)
	}
	want := strconv.FormatInt(c.value, 10)
	for i := range list {
		cl := list[i]
		if cl.Name == name && cl.Labels[kuid.LabelCorrelationID] == cid && cl.Bound() && cl.Value == want {
			return &cl, nil
		}
	}
	return nil, nil
}

// ResolveAdoption runs the adoption rule — and only it — for every value n carries that is
// not yet in status.claimRefs, and returns the entries it adopts (origin adopted). It never
// claims. The finalizer (T060) runs it on a deleting object before it releases anything
// (AD-44); the reconciler runs it first on a live one. A non-nil error is the authority
// failing to answer: nothing is adopted (AD-56).
func (r *Reconciler) ResolveAdoption(ctx context.Context, n *fabricv1.Network, f *fabricv1.Fabric) ([]fabricv1.ClaimRef, error) {
	if isACLOnly(n) {
		return nil, nil
	}
	ct := r.claimTargetFor(f)
	var out []fabricv1.ClaimRef
	for _, c := range carriedValues(n) {
		name := ClaimName(n.Namespace, n.Name, c.role)
		if findRef(n.Status.ClaimRefs, c.kind, name) != nil {
			continue // decided once per value, never re-evaluated
		}
		cl, err := r.adoptable(ctx, n, ct, c)
		if err != nil {
			return nil, err
		}
		if cl != nil {
			out = append(out, fabricv1.ClaimRef{Name: name, Namespace: ct.namespace, IndexKind: c.kind, Value: c.value, Origin: fabricv1.ClaimOriginAdopted})
		}
	}
	return out, nil
}

// resolveClaims is the claim gate of a live object (T171). It records every decision in
// n.Status.ClaimRefs (appending only) and returns the conflicts and the pending claims; an
// error is a dependency wait (AD-56).
func (r *Reconciler) resolveClaims(ctx context.Context, n *fabricv1.Network, f *fabricv1.Fabric, hadReady bool) (*claimOutcome, error) {
	out := &claimOutcome{}
	if isACLOnly(n) {
		return out, nil // the attachment VLAN is a reference; nothing is claimed or looked for (AD-47)
	}
	// An ip-vrf attachment's allocation-band VLAN: refused by construction, no lookup (AD-51).
	if cs := ipvrfBandConflicts(n); len(cs) > 0 {
		out.conflicts = cs
		return out, nil
	}
	ct := r.claimTargetFor(f)

	// 1. Adoption, all lookups first: an error adopts nothing (AD-56).
	adopted, err := r.ResolveAdoption(ctx, n, f)
	if err != nil {
		return nil, err
	}
	refs := append(append([]fabricv1.ClaimRef{}, n.Status.ClaimRefs...), adopted...)

	// 2. The VLAN band gate: an allocation-band VLAN with no adoptable claim is refused.
	var vnis []carried
	for _, c := range carriedValues(n) {
		name := ClaimName(n.Namespace, n.Name, c.role)
		if c.kind == fabricv1.ClaimIndexGENID {
			vnis = append(vnis, c)
			continue
		}
		if findRef(refs, c.kind, name) == nil {
			out.conflicts = append(out.conflicts, fmt.Sprintf("VLAN %d of %s lies in the allocation band and no adoptable claim backs it: none named %s/%s carries this object's %s label and reports %d; %s",
				c.value, c.field, ct.namespace, name, kuid.LabelCorrelationID, c.value, bandsText()))
		}
	}
	if len(out.conflicts) > 0 {
		// Refused before any claim is made: nothing is stranded.
		n.Status.ClaimRefs = refs
		return out, nil
	}

	// 3. The VNIs with no adopted claim: claim exactly the stated value (never on a deleting
	// object — the finalizer never calls this). An error here records no adoption of this pass
	// (AD-56) — only the claims already made, so that finalization releases them.
	orig := append([]fabricv1.ClaimRef{}, n.Status.ClaimRefs...)
	var made []fabricv1.ClaimRef
	for _, c := range vnis {
		name := ClaimName(n.Namespace, n.Name, c.role)
		ref := kuid.Ref{Kind: kuid.KindGENID, Namespace: ct.namespace, Name: name}
		existing := findRef(refs, c.kind, name)
		if existing != nil && existing.Origin == fabricv1.ClaimOriginAdopted {
			continue
		}
		if existing != nil && hadReady {
			continue // bound when the object became Ready at this generation; a claim never moves
		}
		want := strconv.FormatInt(c.value, 10)
		got, err := r.Claims.Get(ctx, ref)
		switch {
		case kuid.IsNotFound(err):
			req := kuid.Request{Ref: ref, Index: ct.vniIndex, Labels: claimLabels(n)}
			got, err = r.Claims.ClaimValue(ctx, req, want)
			if err != nil {
				n.Status.ClaimRefs = append(orig, made...)
				return nil, fmt.Errorf("claim %s for %s: %w", ref, want, err)
			}
		case err != nil:
			n.Status.ClaimRefs = append(orig, made...)
			return nil, fmt.Errorf("read %s: %w", ref, err)
		default:
			if !ownClaim(n, got) {
				out.conflicts = append(out.conflicts, fmt.Sprintf("VNI %d of %s: the claim %s/%s of this object's deterministic name exists but is not adoptable and not this object's (it states %q, reports %q, labels %s); no other value is tried",
					c.value, c.field, ct.namespace, name, got.Stated, got.Value, showLabels(got.Labels)))
				continue
			}
			if got.Stated != "" && got.Stated != want {
				out.conflicts = append(out.conflicts, fmt.Sprintf("VNI %d of %s: the claim %s/%s states %s; a claim is never moved", c.value, c.field, ct.namespace, name, got.Stated))
				continue
			}
		}
		if existing == nil {
			// Recorded at once, bound or not, so finalization releases it whatever happens next.
			cr := fabricv1.ClaimRef{Name: name, Namespace: ct.namespace, IndexKind: c.kind, Value: c.value, Origin: fabricv1.ClaimOriginCreated}
			refs = append(refs, cr)
			made = append(made, cr)
		}
		switch {
		case got.Bound() && got.Value == want:
		case got.Bound():
			out.conflicts = append(out.conflicts, fmt.Sprintf("VNI %d of %s: the authority bound %s/%s to %s; a claim reporting another value is never proceeded on", c.value, c.field, ct.namespace, name, got.Value))
		case !got.Ready && got.Message != "":
			out.conflicts = append(out.conflicts, fmt.Sprintf("VNI %d of %s refused by the allocation authority (claim %s/%s): %s; no other value is tried",
				c.value, c.field, ct.namespace, name, got.Message))
		default:
			out.pending = append(out.pending, fmt.Sprintf("%s/%s (VNI %d)", ct.namespace, name, c.value))
		}
	}
	n.Status.ClaimRefs = refs
	return out, nil
}

// claimLabels are the metadata.labels of a claim the provider creates for n (AD-32).
func claimLabels(n *fabricv1.Network) map[string]string {
	l := map[string]string{kuid.LabelNetworkNamespace: n.Namespace, kuid.LabelNetworkName: n.Name}
	if cid := n.Labels[kuid.LabelCorrelationID]; cid != "" {
		l[kuid.LabelCorrelationID] = cid
	}
	return l
}

// ownClaim is a claim the provider made for n on an earlier pass (its status write lost).
func ownClaim(n *fabricv1.Network, c kuid.Claimed) bool {
	return c.Labels[kuid.LabelNetworkNamespace] == n.Namespace && c.Labels[kuid.LabelNetworkName] == n.Name
}

func showLabels(l map[string]string) string {
	if len(l) == 0 {
		return "none"
	}
	keys := make([]string, 0, len(l))
	for k := range l {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, k+"="+l[k])
	}
	return strings.Join(parts, ",")
}
