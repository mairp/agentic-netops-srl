package fabric

import (
	"context"
	"fmt"
	"net/netip"
	"sort"
	"strconv"
	"strings"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/pkg/kuid"
)

// Claim labels (metadata.labels — the only set the authority selects on).
const (
	LabelClaimFabric  = "agentic-netops.io/fabric-name"
	LabelClaimPurpose = "agentic-netops.io/claim-purpose"
)

// Claim purposes, recorded in status.allocations[].purpose.
const (
	PurposeLoopback = "loopback"
	PurposeASN      = "asn"
	PurposeLink     = "link"
)

// claimSpec is one underlay claim the Fabric makes through pkg/kuid.
type claimSpec struct {
	purpose string
	node    string // the node (loopback, leaf ASN), "spines" (shared spine ASN), or the link suffix
	req     kuid.Request
	stated  string // the value spec states; empty for a dynamic claim
	link    *linkPlan
}

// claimsResult is what ensureClaims found.
type claimsResult struct {
	allocations []fabricv1.AllocationRef
	pending     []string // claims not yet bound
	conflicts   []string // the authority's refusals, naming the value and the holder
	loopback    map[string]string
	asn         map[string]uint32
	links       []model.FabricLink
}

// plannedClaims is every claim of the Fabric, in a stable order: one loopback
// per node, one ASN per leaf, one ASN shared by the spines, one /31 per link.
// A stated systemIPv4 or asn is claimed for exactly that value (ClaimValue);
// an omitted one is claimed dynamically (Claim).
func plannedClaims(f *fabricv1.Fabric, in *intent) []claimSpec {
	fab := f.Name
	lp, ap, kp := f.Spec.Underlay.LoopbackPoolRef, f.Spec.Underlay.ASNPoolRef, f.Spec.Underlay.LinkPoolRef
	labels := func(purpose string) map[string]string {
		return map[string]string{LabelClaimFabric: fab, LabelClaimPurpose: purpose}
	}
	var out []claimSpec
	names := make([]string, 0, len(in.nodes))
	for _, n := range in.nodes {
		names = append(names, string(n.Name))
	}
	sort.Strings(names)
	for _, name := range names {
		n := in.nodeSet[name]
		out = append(out, claimSpec{
			purpose: PurposeLoopback, node: name, stated: n.SystemIPv4,
			req: kuid.Request{
				Ref:   kuid.Ref{Kind: kuid.KindIP, Namespace: lp.Namespace, Name: fab + "." + name + ".loopback"},
				Index: lp.Name, Labels: labels(PurposeLoopback), AddressFamily: "ipv4",
			},
		})
	}
	var spineASN string
	for _, s := range in.spines {
		if a := in.nodeSet[s].ASN; a != nil {
			spineASN = strconv.FormatInt(*a, 10)
		}
	}
	out = append(out, claimSpec{
		purpose: PurposeASN, node: "spines", stated: spineASN,
		req: kuid.Request{Ref: kuid.Ref{Kind: kuid.KindASN, Namespace: ap.Namespace, Name: fab + ".spines.asn"},
			Index: ap.Name, Labels: labels(PurposeASN)},
	})
	for _, l := range in.leaves {
		stated := ""
		if a := in.nodeSet[l].ASN; a != nil {
			stated = strconv.FormatInt(*a, 10)
		}
		out = append(out, claimSpec{
			purpose: PurposeASN, node: l, stated: stated,
			req: kuid.Request{Ref: kuid.Ref{Kind: kuid.KindASN, Namespace: ap.Namespace, Name: fab + "." + l + ".asn"},
				Index: ap.Name, Labels: labels(PurposeASN)},
		})
	}
	pl := uint32(31)
	for i := range in.links {
		l := in.links[i]
		out = append(out, claimSpec{
			purpose: PurposeLink, node: l.ClaimSuffix(), link: &l,
			req: kuid.Request{Ref: kuid.Ref{Kind: kuid.KindIP, Namespace: kp.Namespace, Name: fab + "." + l.ClaimSuffix()},
				Index: kp.Name, Labels: labels(PurposeLink), IPPrefix: true, AddressFamily: "ipv4",
				PrefixLength: &pl, CreatePrefix: true},
		})
	}
	return out
}

// ensureClaims gets or makes every claim. An error is the authority failing to
// answer (AD-56) — a dependency wait retried with backoff, never read as "no
// such claim" nor as AllocationConflict. A claim the authority refused is a
// conflict (its Ready=False message names the holder); one not yet bound is
// pending.
func (r *Reconciler) ensureClaims(ctx context.Context, f *fabricv1.Fabric, in *intent) (*claimsResult, error) {
	res := &claimsResult{loopback: map[string]string{}, asn: map[string]uint32{}}
	for _, cs := range plannedClaims(f, in) {
		got, err := r.Claims.Get(ctx, cs.req.Ref)
		switch {
		case kuid.IsNotFound(err):
			if cs.stated != "" {
				got, err = r.Claims.ClaimValue(ctx, cs.req, cs.stated)
			} else {
				got, err = r.Claims.Claim(ctx, cs.req)
			}
			if err != nil {
				return nil, fmt.Errorf("claim %s: %w", cs.req.Ref, err)
			}
		case err != nil:
			return nil, fmt.Errorf("read %s: %w", cs.req.Ref, err)
		default:
			if cs.stated != "" && got.Stated != cs.stated {
				res.conflicts = append(res.conflicts, fmt.Sprintf("%s states %q but spec states %q; a claim is never moved — release it or restore the value",
					cs.req.Ref, got.Stated, cs.stated))
				continue
			}
		}
		ref := fabricv1.AllocationRef{
			Name: cs.req.Name, Namespace: cs.req.Namespace, IndexKind: indexKind(cs.req.Kind),
			Purpose: cs.purpose, Value: got.Value, Bound: got.Bound(),
		}
		if cs.link == nil && cs.node != "spines" {
			ref.Node = cs.node
		}
		res.allocations = append(res.allocations, ref)
		if !got.Bound() {
			if !got.Ready && got.Reason != "" && got.Message != "" {
				v := cs.stated
				if v == "" {
					v = "a dynamic value"
				}
				res.conflicts = append(res.conflicts, fmt.Sprintf("%s for %s refused by the authority: %s", cs.req.Ref, v, got.Message))
			} else {
				res.pending = append(res.pending, cs.req.Ref.String())
			}
			continue
		}
		switch cs.purpose {
		case PurposeLoopback:
			p, err := hostPrefix32(got.Value)
			if err != nil {
				return nil, fmt.Errorf("%s reports %q: %w", cs.req.Ref, got.Value, err)
			}
			res.loopback[cs.node] = p
		case PurposeASN:
			v, err := strconv.ParseUint(got.Value, 10, 32)
			if err != nil {
				return nil, fmt.Errorf("%s reports %q: not an AS number", cs.req.Ref, got.Value)
			}
			if cs.node == "spines" {
				for _, s := range in.spines {
					res.asn[s] = uint32(v)
				}
			} else {
				res.asn[cs.node] = uint32(v)
			}
		case PurposeLink:
			a, b, err := splitP2P(got.Value)
			if err != nil {
				return nil, fmt.Errorf("%s reports %q: %w", cs.req.Ref, got.Value, err)
			}
			res.links = append(res.links, model.FabricLink{
				A: model.LinkEnd{Node: cs.link.Leaf, Port: cs.link.LeafPort, IPv4: b},
				B: model.LinkEnd{Node: cs.link.Spine, Port: cs.link.SpinePort, IPv4: a},
			})
		}
	}
	return res, nil
}

// indexKind is status.allocations[].indexKind: ipam or as.
func indexKind(k kuid.Kind) string {
	if k == kuid.KindASN {
		return "as"
	}
	return "ipam"
}

// hostPrefix32 turns a claimed address ("10.0.0.11/32", or an address the
// authority reports with its parent prefix length) into the node's /32.
func hostPrefix32(v string) (string, error) {
	if !strings.Contains(v, "/") {
		a, err := netip.ParseAddr(v)
		if err != nil {
			return "", err
		}
		return netip.PrefixFrom(a, 32).String(), nil
	}
	p, err := netip.ParsePrefix(v)
	if err != nil {
		return "", err
	}
	if !p.Addr().Is4() {
		return "", fmt.Errorf("not an IPv4 address")
	}
	return netip.PrefixFrom(p.Addr(), 32).String(), nil
}

// splitP2P turns a claimed /31 into its two ends: the spine takes the first
// address, the leaf the second (a, b as "<addr>/31").
func splitP2P(v string) (string, string, error) {
	p, err := netip.ParsePrefix(v)
	if err != nil {
		return "", "", err
	}
	if !p.Addr().Is4() || p.Bits() != 31 {
		return "", "", fmt.Errorf("not an IPv4 /31")
	}
	first := p.Masked().Addr()
	return netip.PrefixFrom(first, 31).String(), netip.PrefixFrom(first.Next(), 31).String(), nil
}
