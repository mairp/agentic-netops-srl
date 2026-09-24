package network

// The operator force-release (T060; contracts/reconciliation.md Rule 8 "Force-release is the
// only other exit", contracts/crd-api.md, data-model.md §3a status.findings[] and §18;
// FR-103, CD-02, AD-49, AD-54, AD-61, AD-71).
//
// The annotation fabric.agentic-netops.io/force-release: "<reason>" on a Network — its value is
// the operator's stated reason — is set with cluster tooling; the intent tier cannot set it
// (an admission policy, not this code). The provider reads it and never writes it.
//
//   - An empty (or blank) reason is refused with a Warning Event ForceReleaseRefused and
//     nothing is released, whatever the object's state.
//   - It is honoured ONLY on an object that is being deleted AND is blocked on
//     TargetUnreachable. On a live service, on a deleting one whose targets are all reachable,
//     one waiting on an access-list holder or on an allocation authority that has not answered,
//     it is ignored with a Warning Event ForceReleaseIgnored and nothing is released — it is
//     never a way to delete.
//   - Honoured: for each unreachable target one finding per (service, device) is appended to
//     Fabric.status.findings[] (type StaleConfigurationPossible, the service's namespace, name
//     and UID, the node, every identifier released — kind vlan|l2vni|l3vni, index, value — the
//     device object names the service rendered on that node, the reason, the time), a Warning
//     Event ForceReleased per finding, all BEFORE anything is released; then Deleting=True/
//     ForceReleased, every status.claimRefs entry released, the finalizer removed.
//   - It does not depend on the Fabric's inventory: a device removed from the Fabric completes
//     nothing and releases nothing by itself (the object stays blocked naming it), and the
//     force-release still records its finding once the device has left (the never-returning
//     target, where it is the only exit). The finding is recorded on the Fabric the object's
//     claims derive from.
//   - The finding outlives the Network. The Fabric reconciler's scheduled re-verification
//     removes it after reading every named object absent (controllers/fabric clearFindings);
//     while it is open a render that would produce one of its objects on that node is refused
//     Applied=False/OwnershipConflict naming the finding (staleFindingConflicts), which ends
//     with the finding, with no action on the Network.

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/status"
)

// AnnotationForceRelease is the operator break-glass of FR-103; its value is the stated reason.
const AnnotationForceRelease = "fabric.agentic-netops.io/force-release"

// Event reasons of the force-release.
const (
	EventForceReleased       = "ForceReleased"
	EventForceReleaseRefused = "ForceReleaseRefused"
	EventForceReleaseIgnored = "ForceReleaseIgnored"
)

// Identifier kinds of a finding (data-model.md §3a).
const (
	IdentifierVLAN  = "vlan"
	IdentifierL2VNI = "l2vni"
	IdentifierL3VNI = "l3vni"
)

// The CRD bounds of a finding's lists (api/fabric/v1alpha1 Finding).
const (
	maxFindingIdentifiers   = 16
	maxFindingDeviceObjects = 64
)

// ForceReleaseReason returns the annotation's reason (trimmed) and whether it is set at all.
func ForceReleaseReason(n *fabricv1.Network) (reason string, set bool) {
	v, ok := n.Annotations[AnnotationForceRelease]
	return strings.TrimSpace(v), ok
}

// forceReleaseOnLive answers the annotation on a live Network: refused when its reason is
// empty, otherwise ignored — never a way to delete.
func (r *Reconciler) forceReleaseOnLive(n *fabricv1.Network) {
	r.forceReleaseNotHonoured(n, "the Network is not being deleted; the force-release is never a way to delete")
}

// forceReleaseNotHonoured publishes the refusal (empty reason) or the ignore Event (why) when
// the annotation is set on an object it cannot be honoured on. Nothing is released.
func (r *Reconciler) forceReleaseNotHonoured(n *fabricv1.Network, why string) {
	reason, set := ForceReleaseReason(n)
	switch {
	case !set:
	case reason == "":
		r.event(n, "Warning", EventForceReleaseRefused, "%s refused: the reason is required and the annotation's value is empty; nothing is released", AnnotationForceRelease)
	default:
		r.event(n, "Warning", EventForceReleaseIgnored, "%s ignored: it is honoured only on a Network being deleted and blocked on TargetUnreachable — %s; nothing is released", AnnotationForceRelease, why)
	}
}

// forceRelease is called on an object blocked on TargetUnreachable (rm.unreachableNodes). When
// the annotation is absent or refused it returns done=false and the caller keeps waiting. When
// honoured it records the findings, publishes the Events, releases every claim and removes the
// finalizer (done=true); a write that fails returns done=true with the backoff and nothing
// released.
func (r *Reconciler) forceRelease(ctx context.Context, p *pass, before *fabricv1.NetworkStatus, f *fabricv1.Fabric, rm removal) (bool, ctrl.Result, error) {
	n := p.n
	reason, set := ForceReleaseReason(n)
	if !set {
		return false, ctrl.Result{}, nil
	}
	if reason == "" {
		r.forceReleaseNotHonoured(n, "")
		return false, ctrl.Result{}, nil
	}
	if f == nil {
		r.event(n, "Warning", EventForceReleaseRefused, "%s refused: no Fabric exists to record the durable finding on; nothing is released", AnnotationForceRelease)
		return false, ctrl.Result{}, nil
	}
	objs, err := renderedObjects(n, f)
	if err != nil {
		r.event(n, "Warning", EventForceReleaseRefused, "%s refused: the device objects the service rendered cannot be stated (%v); nothing is released", AnnotationForceRelease, err)
		return false, ctrl.Result{}, nil
	}
	ids := r.releasedIdentifiers(n, f)
	now := metav1.NewTime(r.Clock.Now())
	var findings []fabricv1.Finding
	for _, node := range rm.unreachableNodes {
		dev := objs[node]
		if len(dev) == 0 {
			r.event(n, "Warning", EventForceReleaseRefused, "%s refused: no device object of the service on %s can be stated, so no finding could ever be read clean; nothing is released", AnnotationForceRelease, node)
			return false, ctrl.Result{}, nil
		}
		findings = append(findings, fabricv1.Finding{
			Type:          fabricv1.FindingStaleConfigurationPossible,
			Service:       fabricv1.ServiceRef{Namespace: n.Namespace, Name: n.Name, UID: string(n.UID)},
			Node:          node,
			Identifiers:   ids,
			DeviceObjects: dev,
			Reason:        truncate(reason, 1024),
			RecordedAt:    now,
		})
	}

	// Before anything is released: the durable findings, then one Event per finding.
	if err := r.recordFindings(ctx, client.ObjectKeyFromObject(f), findings); err != nil {
		if serr := r.writeStatus(ctx, n, before); serr != nil {
			return true, ctrl.Result{}, serr
		}
		res, err := p.transient(ctx, "record the force-release finding on Fabric "+f.Namespace+"/"+f.Name, err)
		return true, res, err
	}
	for _, fd := range findings {
		r.event(n, "Warning", EventForceReleased,
			"force-released on %s (reason: %s): the device may still carry stale configuration — %s; identifiers released without a read-back: %s; finding recorded on Fabric %s/%s",
			fd.Node, fd.Reason, strings.Join(fd.DeviceObjects, ", "), identifiersText(fd.Identifiers), f.Namespace, f.Name)
	}
	if err := p.conds.SetDeletingCondition(status.ReasonForceReleased,
		fmt.Sprintf("force-released by the operator (reason: %s) with %s unreachable; findings recorded on Fabric %s/%s; releasing every claim and removing the finalizer",
			truncate(reason, 256), strings.Join(rm.unreachableNodes, ", "), f.Namespace, f.Name)); err != nil {
		return true, ctrl.Result{}, err
	}
	if err := r.writeStatus(ctx, n, before); err != nil {
		return true, ctrl.Result{}, err
	}
	if ok, res, err := r.releaseAll(ctx, p, before, "released by the operator force-release, without a read-back (FR-103)"); !ok {
		return true, res, err
	}
	if err := r.writeStatus(ctx, n, before); err != nil {
		return true, ctrl.Result{}, err
	}
	res, err := r.removeFinalizer(ctx, n)
	return true, res, err
}

// recordFindings appends findings to the Fabric's status.findings[], once per (service UID,
// node), with conflict retry.
func (r *Reconciler) recordFindings(ctx context.Context, key client.ObjectKey, findings []fabricv1.Finding) error {
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		f := &fabricv1.Fabric{}
		if err := r.Client.Get(ctx, key, f); err != nil {
			return err
		}
		added := false
		for _, fd := range findings {
			dup := false
			for _, ex := range f.Status.Findings {
				if ex.Service.UID == fd.Service.UID && ex.Node == fd.Node {
					dup = true
					break
				}
			}
			if !dup {
				f.Status.Findings = append(f.Status.Findings, fd)
				added = true
			}
		}
		if !added {
			return nil
		}
		return r.Client.Status().Update(ctx, f)
	})
}

// releasedIdentifiers are every status.claimRefs entry as a finding identifier.
func (r *Reconciler) releasedIdentifiers(n *fabricv1.Network, f *fabricv1.Fabric) []fabricv1.ReleasedIdentifier {
	ct := r.claimTargetFor(f)
	prefix := n.Namespace + "." + n.Name + "."
	var out []fabricv1.ReleasedIdentifier
	for _, ref := range n.Status.ClaimRefs {
		role := strings.TrimPrefix(ref.Name, prefix)
		id := fabricv1.ReleasedIdentifier{Kind: string(ref.IndexKind), Value: strconv.FormatInt(ref.Value, 10)}
		switch {
		case strings.HasPrefix(role, RoleL2VNI):
			id.Kind = IdentifierL2VNI
		case strings.HasPrefix(role, RoleL3VNI):
			id.Kind = IdentifierL3VNI
		case strings.HasPrefix(role, RoleVLAN):
			id.Kind = IdentifierVLAN
		}
		if ref.IndexKind == fabricv1.ClaimIndexVLAN {
			id.Index = ct.vlanIndex
		} else {
			id.Index = ct.vniIndex
		}
		out = append(out, id)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Kind != out[j].Kind {
			return out[i].Kind < out[j].Kind
		}
		return out[i].Value < out[j].Value
	})
	if len(out) > maxFindingIdentifiers {
		out = out[:maxFindingIdentifiers]
	}
	return out
}

func identifiersText(ids []fabricv1.ReleasedIdentifier) string {
	if len(ids) == 0 {
		return "none (the service claimed nothing)"
	}
	parts := make([]string, 0, len(ids))
	for _, id := range ids {
		parts = append(parts, fmt.Sprintf("%s %s (%s)", id.Kind, id.Value, id.Index))
	}
	return strings.Join(parts, ", ")
}

// renderedObjects are the device object names the service renders on each node, through the
// canonical service model.
func renderedObjects(n *fabricv1.Network, f *fabricv1.Fabric) (map[string][]string, error) {
	in, err := analyse(n)
	if err != nil {
		return nil, err
	}
	si, err := serviceInput(n, f, in)
	if err != nil {
		return nil, err
	}
	m, err := model.BuildService(si)
	if err != nil {
		return nil, err
	}
	out := map[string][]string{}
	for i := range m.Nodes {
		out[m.Nodes[i].Node] = DeviceObjects(&m.Nodes[i])
	}
	return out, nil
}

// DeviceObjects are the device object names one service renders on one node, in the naming
// of data-model.md §3a status.findings[].deviceObjects (internal/verify.DeviceObjectStatePath
// reads them): network instances by name, subinterfaces "<port>.<index>" (irb0's included),
// tunnel sub-interfaces "vxlan0.<index>", access-list filters by name. Sorted, distinct.
func DeviceObjects(sn *model.ServiceNode) []string {
	seen := map[string]bool{}
	var out []string
	add := func(s string) {
		if s != "" && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	for _, ni := range sn.NetworkInstances {
		add(ni.Name)
	}
	for _, s := range sn.Subinterfaces {
		add(s.Name())
	}
	for _, s := range sn.IRB {
		add(s.Name())
	}
	for _, v := range sn.VXLANInterfaces {
		add(v.Name())
	}
	for _, a := range sn.ACLFilters {
		add(a.Name)
	}
	sort.Strings(out)
	if len(out) > maxFindingDeviceObjects {
		out = out[:maxFindingDeviceObjects]
	}
	return out
}

// staleFindingConflicts names every open force-release finding of f whose node is in
// f.spec.nodes and which names a device object this render would produce on that node
// (FR-103, CD-02, data-model.md §18 OwnershipConflict). A finding whose node left spec.nodes
// counts for nothing (AD-71): no Network can attach there.
func staleFindingConflicts(f *fabricv1.Fabric, m *model.ServiceModel) []string {
	if len(f.Status.Findings) == 0 {
		return nil
	}
	inSpec := map[string]bool{}
	for _, nd := range f.Spec.Nodes {
		inSpec[string(nd.Name)] = true
	}
	var out []string
	for _, fd := range f.Status.Findings {
		if !inSpec[fd.Node] {
			continue
		}
		sn := m.Node(fd.Node)
		if sn == nil {
			continue
		}
		mine := map[string]bool{}
		for _, o := range DeviceObjects(sn) {
			mine[o] = true
		}
		var hit []string
		for _, o := range fd.DeviceObjects {
			if mine[o] {
				hit = append(hit, o)
			}
		}
		if len(hit) == 0 {
			continue
		}
		sort.Strings(hit)
		out = append(out, fmt.Sprintf("open force-release finding on Fabric %s/%s for service %s/%s (uid %s) on %s names device object(s) %s that this render would produce there; the device may still carry them, so the render is refused until the Fabric's scheduled re-verification reads them absent (FR-103, CD-02)",
			f.Namespace, f.Name, fd.Service.Namespace, fd.Service.Name, fd.Service.UID, fd.Node, strings.Join(hit, ", ")))
	}
	return out
}
