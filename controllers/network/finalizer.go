package network

// The Network's finalizer (T060; contracts/reconciliation.md Rule 8, data-model.md §18, §19;
// FR-043, FR-103, FR-107, FR-109, AD-25, AD-32, AD-44, AD-53, AD-56, AD-61).
//
//  0. The finalizer is placed at the first reconcile of an object applied with cluster tooling
//     (Reconcile) and honoured when the tier's deployer applied the object with it already set:
//     either way this path is the only one that removes it.
//  1. At once, whatever the reachability of the targets and before anything is removed:
//     Ready=False/Deleting through T023's setter beside Deleting=True/<what is outstanding>,
//     written to the API server before any other step (AD-53). It is never changed until the
//     object is gone: no read-back is ever run on a deleting object, VerificationFailed is never
//     set on it, and the re-verification schedule keeps it only as the finalizer's requeue.
//     Then adoption is resolved before anything is released: ResolveAdoption — the three-part
//     rule of T171 and nothing looser — for every carried value not yet in status.claimRefs,
//     recording what it adopts and claiming nothing (AD-44). An authority that errors has not
//     answered (AD-56): nothing is adopted from it, the finalizer stays,
//     Deleting=True/RemovingConfiguration names the authority, the pass is requeued with
//     bounded backoff, steps 2–5 still run, and steps 6–7 never run on a list this step could
//     not complete.
//  2. Dependency order — the access-list binding, then the filter, then anything that owns the
//     subinterface. Within one object the binding, the filter and the subinterface are one
//     Config per node, deleted by the layer as one transaction; across objects,
//  3. a service whose attachment subinterface still carries another object's standalone access
//     list does not remove anything until that holder is gone: Deleting=True/HolderPresent
//     names the holder (FR-043; the hook User Story 5 renders against). A holder that is itself
//     being deleted still holds (Rule 8 step 4).
//  4. Every Config of the object (its network-namespace/network-name labels and its source-uid)
//     is deleted.
//  5. The removal is read back from every affected device: a node is done when its Config is no
//     longer listed and its Target is Ready. A node whose Target is not Ready (or absent), or
//     whose Config is still listed while the Reachability probe finds it unreadable, is
//     unreachable: Deleting=True/TargetUnreachable names EACH such target, the configuration
//     already removable from the reachable ones is removed, every allocation stays claimed,
//     and the pass is requeued at the re-verification interval — there is no timer and no
//     deadline on this path; the target's return completes it unaided (FR-103, CD-02).
//  6. Only then every entry of status.claimRefs is released — the whole list and the only
//     list, adopted and created alike, an adopted VLAN claim of a mac-vrf whose attachment was
//     removed while it lived included: adoption is never re-evaluated, so nothing on the list
//     is dropped before this step (AD-25, AD-32, AD-61). A Release that errors keeps its entry,
//     the finalizer and the reason RemovingConfiguration naming the authority, retried with
//     backoff; a claim already gone counts as released.
//  7. The finalizer is removed — an UPDATE the admission webhook admits unread (AD-61), so an
//     object whose node has left the Fabric still finalizes.
//
// The only other exit is the force-release of force_release.go, honoured only on an object
// blocked in step 5.

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/status"
	"github.com/mairp/agentic-netops-srl/internal/telemetry"
	"github.com/mairp/agentic-netops-srl/pkg/kuid"
	"github.com/mairp/agentic-netops-srl/pkg/sdc"
)

// conflictRequeue is the requeue of a status write that lost an optimistic-lock race.
const conflictRequeue = time.Second

// readyDeletingMessage is the message of Ready=False/Deleting.
const readyDeletingMessage = "the Network is being removed and is no longer offered; nothing is read back to decide it (AD-53)"

// removal is what steps 2–5 found on one pass.
type removal struct {
	// unreachable are the affected nodes whose Target is not Ready or absent, each with why,
	// sorted: "leaf02 (Failed)".
	unreachable []string
	// unreachableNodes are the same nodes, bare.
	unreachableNodes []string
	// pending are the Configs still listed on reachable nodes (their removal not yet read back).
	pending []string
}

func (r *Reconciler) finalize(ctx context.Context, p *pass) (ctrl.Result, error) {
	n := p.n
	if !controllerutil.ContainsFinalizer(n, Finalizer) {
		r.forget(n.UID)
		return ctrl.Result{}, nil
	}
	before := n.Status.DeepCopy()
	st := r.Settings

	// Step 1: Ready=False/Deleting, at once and written before anything is removed.
	if err := p.conds.SetReadyDeleting(readyDeletingMessage); err != nil {
		return ctrl.Result{}, err
	}
	if d := p.conds.Get(status.Degraded); d != nil && d.Reason == status.ReasonVerificationFailed {
		if err := p.conds.ClearDegraded("the Network is being removed; no read-back is run on it"); err != nil {
			return ctrl.Result{}, err
		}
	}
	if p.conds.Get(status.Deleting) == nil {
		if err := p.conds.SetDeletingCondition(status.ReasonRemovingConfiguration, "finalization started: removing configuration"); err != nil {
			return ctrl.Result{}, err
		}
	}
	if err := r.writeStatus(ctx, n, before); err != nil {
		if apierrors.IsConflict(err) {
			return ctrl.Result{RequeueAfter: conflictRequeue}, nil
		}
		return ctrl.Result{}, err
	}

	// Step 1: adoption before anything is released (AD-44), by the same three-part rule; never
	// a claim. An error adopts nothing and settles nothing (AD-56).
	f := r.fabricForClaims(ctx, n)
	adopted, adoptErr := r.ResolveAdoption(ctx, n, f)
	if adoptErr == nil && len(adopted) > 0 {
		n.Status.ClaimRefs = append(n.Status.ClaimRefs, adopted...)
		for _, a := range adopted {
			r.event(n, "Normal", EventClaimAdopted, "claim %s/%s (%s %d) adopted at finalization", a.Namespace, a.Name, a.IndexKind, a.Value)
		}
	}

	// Steps 2–3: nothing that owns a subinterface is removed while another object's
	// standalone access list is still bound to it.
	holders, err := r.aclHolders(ctx, n)
	if err != nil {
		return r.finalizeTransient(ctx, p, before, "list Networks for access-list holders", err, "")
	}
	if len(holders) > 0 {
		msg := "waiting for the access-list binding(s) of " + strings.Join(holders, "; ") +
			" to be withdrawn first: the binding, then the filter, and only then the subinterface owner (FR-043); nothing removed yet"
		r.forceReleaseNotHonoured(n, "the Network is blocked on HolderPresent, not TargetUnreachable")
		if adoptErr != nil {
			return r.finalizeTransient(ctx, p, before, r.authorityName(), adoptErr, msg)
		}
		if err := p.conds.SetDeletingCondition(status.ReasonHolderPresent, msg); err != nil {
			return ctrl.Result{}, err
		}
		if err := r.writeStatus(ctx, n, before); err != nil {
			return ctrl.Result{}, err
		}
		p.outcome = telemetry.ResultWait
		return ctrl.Result{RequeueAfter: st.ReconcileInterval}, nil
	}

	// Steps 4–5: remove every Config of the object and read the removal back.
	rm, err := r.removeConfigs(ctx, n)
	if err != nil {
		return r.finalizeTransient(ctx, p, before, "remove Configs", err, "")
	}
	if adoptErr != nil {
		// Steps 6 and 7 never run on a list step 1 could not complete; the force-release is
		// not an exit from an authority that has not answered (AD-56).
		r.forceReleaseNotHonoured(n, "the allocation authority has not answered the adoption lookup")
		return r.finalizeTransient(ctx, p, before, r.authorityName(), adoptErr, rm.summary())
	}
	if len(rm.unreachable) > 0 {
		msg := "configuration removed from every reachable target; unreachable: " + strings.Join(rm.unreachable, ", ") +
			"; every allocation stays claimed until the removal is read back from each (no deadline, FR-103)"
		if len(rm.pending) > 0 {
			msg += "; removal not yet read back from " + strings.Join(rm.pending, ", ")
		}
		if err := p.conds.SetDeletingCondition(status.ReasonTargetUnreachable, msg); err != nil {
			return ctrl.Result{}, err
		}
		if done, res, err := r.forceRelease(ctx, p, before, f, rm); done || err != nil {
			return res, err
		}
		if err := r.writeStatus(ctx, n, before); err != nil {
			return ctrl.Result{}, err
		}
		p.outcome = telemetry.ResultWait
		return ctrl.Result{RequeueAfter: st.ReverifyInterval}, nil
	}
	if len(rm.pending) > 0 {
		r.forceReleaseNotHonoured(n, "every target is reachable; the removal completes without it")
		msg := "removing configuration; waiting for the removal of " + strings.Join(rm.pending, ", ") + " to be read back"
		if err := p.conds.SetDeletingCondition(status.ReasonRemovingConfiguration, msg); err != nil {
			return ctrl.Result{}, err
		}
		if err := r.writeStatus(ctx, n, before); err != nil {
			return ctrl.Result{}, err
		}
		p.outcome = telemetry.ResultWait
		// A removal awaiting its read-back on a node the layer still calls Ready is re-checked
		// at the reconciliation interval: the pinned layer reports no change when that node's
		// session is dead, so only another pass — asking the reachability probe again — turns
		// it into TargetUnreachable within SC-008's two intervals of the node going away
		// (observed live 2026-09-24: the first pass ran while the collector's samples from the
		// cut node were still fresh, and the next was a re-verification interval later). The
		// TargetUnreachable hold above keeps the re-verification requeue.
		return ctrl.Result{RequeueAfter: st.ReconcileInterval}, nil
	}
	r.forceReleaseNotHonoured(n, "the removal has been read back from every target; the Network finalizes without it")

	// Step 6: release every entry, only now that the removal is read back.
	if ok, res, err := r.releaseAll(ctx, p, before, "released after the removal was read back"); !ok {
		return res, err
	}
	if err := p.conds.SetDeletingCondition(status.ReasonRemovingConfiguration, "configuration removed and read back; every claim released; removing the finalizer"); err != nil {
		return ctrl.Result{}, err
	}
	if err := r.writeStatus(ctx, n, before); err != nil {
		return ctrl.Result{}, err
	}
	// Step 7.
	return r.removeFinalizer(ctx, n)
}

// releaseAll releases every status.claimRefs entry. A Release that errors keeps its entry and
// the finalizer: ok is false and res/err are the backoff (AD-56). A claim already gone counts
// as released.
func (r *Reconciler) releaseAll(ctx context.Context, p *pass, before *fabricv1.NetworkStatus, why string) (bool, ctrl.Result, error) {
	n := p.n
	var keep []fabricv1.ClaimRef
	var relErr error
	for _, ref := range n.Status.ClaimRefs {
		kr := kuid.Ref{Kind: refKind(ref.IndexKind), Namespace: ref.Namespace, Name: ref.Name}
		if err := r.Claims.Release(ctx, kr); err != nil && !kuid.IsNotFound(err) {
			keep = append(keep, ref)
			if relErr == nil {
				relErr = fmt.Errorf("release %s: %w", kr, err)
			}
			continue
		}
		r.event(n, "Normal", EventClaimReleased, "claim %s/%s (%s %d, %s) %s", ref.Namespace, ref.Name, ref.IndexKind, ref.Value, ref.Origin, why)
	}
	n.Status.ClaimRefs = keep
	if relErr != nil {
		res, err := r.finalizeTransient(ctx, p, before, r.authorityName(), relErr, "configuration removed; releasing the claims")
		return false, res, err
	}
	return true, ctrl.Result{}, nil
}

// removeFinalizer is step 7.
func (r *Reconciler) removeFinalizer(ctx context.Context, n *fabricv1.Network) (ctrl.Result, error) {
	orig := n.DeepCopy()
	controllerutil.RemoveFinalizer(n, Finalizer)
	if err := r.Client.Patch(ctx, n, client.MergeFrom(orig)); err != nil && !apierrors.IsNotFound(err) {
		return ctrl.Result{}, fmt.Errorf("remove finalizer: %w", err)
	}
	r.forget(n.UID)
	return ctrl.Result{}, nil
}

// summary says what steps 2–5 left outstanding, for a message.
func (rm removal) summary() string {
	var parts []string
	if len(rm.unreachable) > 0 {
		parts = append(parts, "unreachable: "+strings.Join(rm.unreachable, ", "))
	}
	if len(rm.pending) > 0 {
		parts = append(parts, "removal not yet read back from "+strings.Join(rm.pending, ", "))
	}
	if len(parts) == 0 {
		return "configuration removed and read back"
	}
	return "configuration removed from every reachable target; " + strings.Join(parts, "; ")
}

// removeConfigs deletes every Config of n still present and reads the removal back: every
// affected node — one with a Config of n still listed, or one n's status says it rendered on —
// whose Target is not Ready is unreachable; a Config still listed on a reachable node is
// pending.
func (r *Reconciler) removeConfigs(ctx context.Context, n *fabricv1.Network) (removal, error) {
	var rm removal
	cfgs, err := r.SDC.ListConfigsForNetwork(ctx, n.Namespace, n.Name)
	if err != nil {
		return rm, err
	}
	for i := range cfgs {
		c := &cfgs[i]
		if c.Annotations[sdc.AnnotationSourceUID] != string(n.UID) {
			continue // a same-named Network's in another namespace is never touched
		}
		if c.DeletionTimestamp == nil {
			if err := r.SDC.DeleteConfig(ctx, c.Name, n.UID); err != nil {
				return rm, err
			}
			r.event(n, "Normal", EventConfigRemoved, "Config %s/%s deleted", c.Namespace, c.Name)
		}
	}
	// Read the removal back.
	cfgs, err = r.SDC.ListConfigsForNetwork(ctx, n.Namespace, n.Name)
	if err != nil {
		return rm, err
	}
	affected := map[string][]string{}
	for _, rc := range n.Status.RenderedConfigs {
		if _, ok := affected[rc.Node]; !ok {
			affected[rc.Node] = nil
		}
	}
	for _, c := range cfgs {
		if c.Annotations[sdc.AnnotationSourceUID] != string(n.UID) {
			continue
		}
		node := c.Labels[sdc.LabelTargetName]
		affected[node] = append(affected[node], c.Namespace+"/"+c.Name)
	}
	nodes := make([]string, 0, len(affected))
	for node := range affected {
		nodes = append(nodes, node)
	}
	sort.Strings(nodes)
	var readyNodes []string
	for _, node := range nodes {
		why := ""
		if node == "" {
			why = "no target label"
		} else {
			tr, err := r.SDC.TargetReady(ctx, r.Settings.TargetNamespace, node)
			switch {
			case apierrors.IsNotFound(err):
				why = "Target absent"
			case err != nil:
				return rm, fmt.Errorf("read Target %s: %w", node, err)
			case !tr.Ready:
				why = tr.Reason
				if why == "" {
					why = "not Ready"
				}
			}
		}
		if why != "" {
			rm.unreachable = append(rm.unreachable, fmt.Sprintf("%s (%s)", node, why))
			rm.unreachableNodes = append(rm.unreachableNodes, node)
			continue
		}
		readyNodes = append(readyNodes, node)
	}
	// A Target the layer still calls Ready is not proof the node can be reached: the pinned
	// layer does not notice a dead session for minutes (observed 2026-09-24, SC-043's force
	// run: Target leaf02 Ready throughout a management cut while the data server's deletion
	// transaction timed out dialling it). A node whose Config is still listed and whose
	// collector samples have stopped is unreachable too. A probe that errors answers nothing:
	// the node stays pending — RemovingConfiguration, never TargetUnreachable on a guess.
	stale := map[string]string{}
	if r.Reachability != nil {
		var ask []string
		for _, node := range readyNodes {
			if len(affected[node]) > 0 {
				ask = append(ask, node)
			}
		}
		if len(ask) > 0 {
			if got, err := r.Reachability.Unreachable(ctx, ask, ReachabilityMaxAge, r.Clock.Now()); err == nil {
				stale = got
			}
		}
	}
	for _, node := range readyNodes {
		if why, ok := stale[node]; ok {
			rm.unreachable = append(rm.unreachable, fmt.Sprintf("%s (Target Ready but unreadable: %s)", node, why))
			rm.unreachableNodes = append(rm.unreachableNodes, node)
			continue
		}
		rm.pending = append(rm.pending, affected[node]...)
	}
	sort.Strings(rm.pending)
	return rm, nil
}

// aclHolders names every OTHER object whose standalone access list (an accessLists-only
// Network, AD-47) is bound to a subinterface n owns — every attachment of a service that is
// not itself accessLists-only. A holder that is being deleted still holds until it is gone
// (Rule 8 step 4).
func (r *Reconciler) aclHolders(ctx context.Context, n *fabricv1.Network) ([]string, error) {
	if isACLOnly(n) {
		return nil, nil // it owns no subinterface: its binding is what is removed first
	}
	in, err := analyse(n)
	if err != nil {
		return nil, nil // an object that never resolved owns no subinterface
	}
	owned := map[string]bool{}
	for _, a := range in.attachments {
		owned[a.String()] = true
	}
	l := &fabricv1.NetworkList{}
	if err := r.Client.List(ctx, l); err != nil {
		return nil, err
	}
	var out []string
	for i := range l.Items {
		h := &l.Items[i]
		if h.UID == n.UID || !isACLOnly(h) {
			continue
		}
		hin, err := analyse(h)
		if err != nil {
			continue
		}
		var bound []string
		for _, a := range hin.attachments {
			if owned[a.String()] {
				bound = append(bound, a.String())
			}
		}
		if len(bound) == 0 {
			continue
		}
		sort.Strings(bound)
		s := fmt.Sprintf("Network %s/%s (bound to %s)", h.Namespace, h.Name, strings.Join(bound, ", "))
		if h.DeletionTimestamp != nil {
			s += " — itself being removed, it holds its bindings until it is gone"
		}
		out = append(out, s)
	}
	sort.Strings(out)
	return out, nil
}

// fabricForClaims is the Fabric the claims' namespace and indices derive from — and the one a
// force-release finding is recorded on: the Fabric in agentic-netops-system whose inventory
// lists every attachment node, else the first by name (a node may have left the inventory),
// or nil when none exists.
func (r *Reconciler) fabricForClaims(ctx context.Context, n *fabricv1.Network) *fabricv1.Fabric {
	l := &fabricv1.FabricList{}
	if err := r.Client.List(ctx, l, client.InNamespace(sdc.SystemNamespace)); err != nil || len(l.Items) == 0 {
		return nil
	}
	sort.Slice(l.Items, func(i, j int) bool { return l.Items[i].Name < l.Items[j].Name })
	in, err := analyse(n)
	if err != nil {
		return &l.Items[0]
	}
	for i := range l.Items {
		nodes := map[string]bool{}
		for _, e := range l.Items[i].Spec.Inventory {
			nodes[string(e.Node)] = true
		}
		all := true
		for _, node := range in.nodes {
			all = all && nodes[node]
		}
		if all {
			return &l.Items[i]
		}
	}
	return &l.Items[0]
}

// authorityName names the allocation authority in a Deleting message.
func (r *Reconciler) authorityName() string {
	name := "the allocation authority"
	if r.Claims != nil && r.Claims.Authority() != "" {
		name += " (" + r.Claims.Authority() + ")"
	}
	return name
}

// finalizeTransient keeps the finalizer and Deleting=True/RemovingConfiguration naming what
// did not answer (and, in state, what else is outstanding), and requeues with bounded backoff.
func (r *Reconciler) finalizeTransient(ctx context.Context, p *pass, before *fabricv1.NetworkStatus, what string, err error, state string) (ctrl.Result, error) {
	msg := "removing configuration; " + what + " did not answer: " + err.Error() +
		"; the finalizer stays and nothing is released until it does (AD-56)"
	if state != "" {
		msg += "; " + state
	}
	if serr := p.conds.SetDeletingCondition(status.ReasonRemovingConfiguration, msg); serr != nil {
		return ctrl.Result{}, serr
	}
	if serr := r.writeStatus(ctx, p.n, before); serr != nil {
		return ctrl.Result{}, serr
	}
	return p.transient(ctx, what, err)
}

// writeStatus writes n's status when it changed.
func (r *Reconciler) writeStatus(ctx context.Context, n *fabricv1.Network, before *fabricv1.NetworkStatus) error {
	n.Status.ObservedGeneration = n.Generation
	if equality.Semantic.DeepEqual(before, &n.Status) {
		return nil
	}
	if err := r.Client.Status().Update(ctx, n); err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		if apierrors.IsConflict(err) {
			return err
		}
		return fmt.Errorf("update Network status: %w", err)
	}
	*before = *n.Status.DeepCopy()
	return nil
}
