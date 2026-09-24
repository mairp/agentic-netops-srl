// Package network is the Network reconciler (T059) with its provider-side claim resolution
// (T171, claims.go) and its finalizer (T060, finalizer.go).
//
// One pass over one Network: the dependency waits — the Fabric exists and is Accepted (never
// that it is Ready, AD-55), the claim gate (every VNI adopted or claimed for exactly the stated
// value and bound, every allocation-band VLAN adopted, AD-33/AD-42/AD-56), the Schema, the
// compatibility set and the Targets — then the canonical service model, the render, and one
// priority-20 Config per (service, node) server-side-applied through pkg/sdc: spec.revertive
// stated from DRIFT_POLICY on every one, in agentic-netops-system, with NO owner reference (a
// Network never shares that namespace), tied to its source by the source-uid annotation and
// the network-namespace/network-name labels (AD-69). Before any write, on every pass: an
// OVERRULED deviation on one of the object's paths is a terminal
// Applied=False/OwnershipConflict naming the path and the overruling intent, never answered
// with a reapply (Rule 4, AD-66); a Config of the derived name held by another source is never
// overwritten (Applied=False/OwnershipConflict naming the holder); and the object's non-key
// leaf paths are compared with the node's other priority-20 Configs (AD-68).
//
// Status comes from the layer's own report and the two-sided read-back (T058) only; a Network
// that has reported Ready at its current generation is re-verified on the REVERIFY_INTERVAL
// schedule, and a read-back that cannot run — found by the schedule or by the reconcile that
// sees a required target not Ready — is Ready=Unknown/VerificationFailed (AD-40, AD-54). The
// Degraded reason is set through internal/status in §18's total order (AD-62).
//
// The provider never stamps the Network (FR-101): the only write to its metadata is the
// finalizer. The renderer, the read-back and the telemetry-health input are interfaces
// (Renderer, Verifier, TelemetryHealth) that cmd/srl-provider wires.
package network

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/go-logr/logr"
	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"k8s.io/utils/clock"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/controllers/fabric"
	"github.com/mairp/agentic-netops-srl/internal/compat"
	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/status"
	"github.com/mairp/agentic-netops-srl/internal/telemetry"
	"github.com/mairp/agentic-netops-srl/internal/verify"
	"github.com/mairp/agentic-netops-srl/pkg/kuid"
	"github.com/mairp/agentic-netops-srl/pkg/register"
	"github.com/mairp/agentic-netops-srl/pkg/sdc"
)

// Finalizer is the provider's finalizer on a Network: it removes the object's Configs, reads
// the removal back and releases every status.claimRefs entry before the object goes
// (contracts/reconciliation.md Rule 8). A tier-submitted Network carries it from its apply; one
// applied with cluster tooling takes it on its first reconcile.
const Finalizer = "fabric.agentic-netops.io/finalizer"

// Event reasons the reconciler publishes beside the condition transitions internal/status emits.
const (
	EventConfigApplied    = "ConfigApplied"
	EventConfigPruned     = "ConfigPruned"
	EventConfigRemoved    = "ConfigRemoved"
	EventClaimCreated     = "ClaimCreated"
	EventClaimAdopted     = "ClaimAdopted"
	EventClaimReleased    = "ClaimReleased"
	EventTransientError   = "TransientError"
	EventRetriesExhausted = "RetriesExhausted"
)

// Settings are the reconciler's configuration (data-model.md §25): the Fabric reconciler's
// settings — DRIFT_POLICY's Revertive, RECONCILE_INTERVAL, REVERIFY_INTERVAL, the bounded
// backoff, the Target and Schema namespaces — plus where the Network's claims live.
type Settings struct {
	fabric.Settings
	// ClaimNamespace overrides the allocation namespace the claims live in; empty takes the
	// namespace the Fabric's own pool references name.
	ClaimNamespace string
	// VNIIndex and VLANIndex override the service indices; empty takes <fabric>-vni and
	// <fabric>-vlan (deploy/kuid/indices, deploy/allocation/pools).
	VNIIndex  string
	VLANIndex string
}

// DefaultSettings are the §25 defaults, with the drift policy stated.
func DefaultSettings() Settings { return Settings{Settings: fabric.DefaultSettings()} }

// Rendered is one node's rendered service document (internal/render/srl.Rendered).
type Rendered struct {
	Node string
	JSON []byte
	Hash string
}

// Renderer renders the service model, keyed by node (internal/render/srl.RenderService).
type Renderer interface {
	RenderService(m *model.ServiceModel) (map[string]Rendered, error)
}

// Verifier is the service read-back (internal/verify.Service, T058): a result for a pass that
// ran and a *verify.CouldNotRunError for one that could not.
type Verifier interface {
	VerifyService(ctx context.Context, in verify.ServiceInput) (verify.ServiceResult, error)
}

// TelemetryHealth is the telemetry-health input — the only thing Degraded=True/
// TelemetryUnavailable is ever set from, never a device read (data-model.md §18, AD-62).
type TelemetryHealth interface {
	TelemetryHealthy(ctx context.Context) (healthy bool, detail string)
}

// Reachability is the data-path half of "can this node be read" (verify.CollectorReader): the
// nodes, of those given, whose device metric collector holds no sample newer than maxAge at now,
// each with why. The pinned layer keeps a Target Ready for minutes after a management cut (a dead
// session is not noticed; live-findings 2026-09-21-target-unreachable), so the finalizer asks
// this too before it calls a node reachable (FR-103; live-findings 2026-09-24-delete-unreachable).
// An error is a probe that could not run, never an answer.
type Reachability interface {
	Unreachable(ctx context.Context, nodes []string, maxAge time.Duration, now time.Time) (map[string]string, error)
}

// ReachabilityMaxAge is the age past which a node's newest collector sample no longer shows it
// readable: six of the collector's 5 s samples.
const ReachabilityMaxAge = 30 * time.Second

// Reconciler reconciles Network objects.
type Reconciler struct {
	Client   client.Client
	SDC      *sdc.Client
	Claims   kuid.Claims
	Renderer Renderer
	Verifier Verifier
	// Reachability, when set, is asked by the finalizer about every affected node whose Target
	// is Ready; nil trusts the Target alone.
	Reachability Reachability
	Telemetry    TelemetryHealth
	// Compat is the compatibility set asserted before rendering; nil skips the Schema and
	// Target compatibility checks (the Fabric reconciler asserts the same set).
	Compat   *compat.Set
	Recorder record.EventRecorder
	Clock    clock.Clock
	Settings Settings
	// Jitter returns a value in [0,1); nil uses a deterministic 1.0 (tests).
	Jitter func() float64

	mu sync.Mutex
	// attempts counts consecutive transient failures per Network.
	attempts map[types.UID]int
	// lastPass is when the last read-back pass was attempted (ran or not).
	lastPass map[types.UID]time.Time
	// unknownByTarget marks a Ready=Unknown set by the reconcile that saw a target not Ready:
	// the target's return is itself the next pass.
	unknownByTarget map[types.UID]bool
}

func (r *Reconciler) init() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.attempts == nil {
		r.attempts = map[types.UID]int{}
		r.lastPass = map[types.UID]time.Time{}
		r.unknownByTarget = map[types.UID]bool{}
	}
	if r.Clock == nil {
		r.Clock = clock.RealClock{}
	}
}

// SetupWithManager registers the reconciler: Networks cluster-wide (generation and label
// changes — a correlation label decides adoption), and, mapped back to the Networks they
// concern, the Configs (by the network-namespace/network-name labels), the Deviations (by the
// Config they name), the Targets and the Fabrics.
func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	all := handler.EnqueueRequestsFromMapFunc(r.allNetworks)
	return ctrl.NewControllerManagedBy(mgr).
		Named("network").
		For(&fabricv1.Network{}, builder.WithPredicates(predicate.Or(predicate.GenerationChangedPredicate{}, predicate.LabelChangedPredicate{},
			// the force-release annotation is a metadata-only UPDATE (FR-103, AD-61)
			predicate.AnnotationChangedPredicate{}))).
		Watches(&configv1alpha1.Config{}, handler.EnqueueRequestsFromMapFunc(configToNetwork)).
		Watches(&configv1alpha1.Deviation{}, handler.EnqueueRequestsFromMapFunc(r.deviationToNetworks)).
		Watches(&configv1alpha1.Target{}, all).
		Watches(&fabricv1.Fabric{}, all).
		Complete(r)
}

func (r *Reconciler) allNetworks(ctx context.Context, _ client.Object) []reconcile.Request {
	l := &fabricv1.NetworkList{}
	if err := r.Client.List(ctx, l); err != nil {
		return nil
	}
	out := make([]reconcile.Request, 0, len(l.Items))
	for _, n := range l.Items {
		out = append(out, reconcile.Request{NamespacedName: types.NamespacedName{Namespace: n.Namespace, Name: n.Name}})
	}
	return out
}

// configToNetwork maps a Config to its Network by the labels pkg/sdc stamps on it.
func configToNetwork(_ context.Context, o client.Object) []reconcile.Request {
	l := o.GetLabels()
	ns, name := l[sdc.LabelNetworkNamespace], l[sdc.LabelNetworkName]
	if ns == "" || name == "" {
		return nil
	}
	return []reconcile.Request{{NamespacedName: types.NamespacedName{Namespace: ns, Name: name}}}
}

// deviationToNetworks maps a config-typed Deviation to the Networks whose Config it names
// (<network>.<node>): every Network of that name, in any namespace.
func (r *Reconciler) deviationToNetworks(ctx context.Context, o client.Object) []reconcile.Request {
	typ, cfgName, ok := configv1alpha1.ParseDeviationName(o.GetName())
	if !ok || typ != configv1alpha1.DeviationType_CONFIG {
		return nil
	}
	i := strings.LastIndexByte(cfgName, '.')
	if i <= 0 {
		return nil
	}
	name := cfgName[:i]
	l := &fabricv1.NetworkList{}
	if err := r.Client.List(ctx, l); err != nil {
		return nil
	}
	var out []reconcile.Request
	for _, n := range l.Items {
		if n.Name == name {
			out = append(out, reconcile.Request{NamespacedName: types.NamespacedName{Namespace: n.Namespace, Name: n.Name}})
		}
	}
	return out
}

// Reconcile runs one pass over one Network and writes its status once, only when it changed.
func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (res ctrl.Result, rerr error) {
	r.init()
	started, outcome := time.Now(), telemetry.ResultSuccess
	defer func() {
		if rerr != nil {
			outcome = telemetry.ResultError
		}
		telemetry.ObserveReconcile(telemetry.ControllerNetwork, outcome, time.Since(started))
	}()
	n := &fabricv1.Network{}
	if err := r.Client.Get(ctx, req.NamespacedName, n); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}
	log := logr.FromContextOrDiscard(ctx).WithValues(telemetry.ObjectValues("Network", n.Namespace, n.Name, n.Labels)...)
	ctx = logr.NewContext(ctx, log)
	p := &pass{r: r, n: n, log: log, now: r.Clock.Now(),
		conds: status.For(n, &n.Status.Conditions, r.Recorder).WithNow(r.Clock.Now)}

	if n.DeletionTimestamp != nil {
		res, err := r.finalize(ctx, p)
		if p.outcome != "" {
			outcome = p.outcome
		}
		return res, err
	}
	if !controllerutil.ContainsFinalizer(n, Finalizer) {
		// The one write the provider makes to a Network's metadata (FR-101): the finalizer,
		// before anything is claimed or rendered.
		orig := n.DeepCopy()
		controllerutil.AddFinalizer(n, Finalizer)
		if err := r.Client.Patch(ctx, n, client.MergeFromWithOptions(orig, client.MergeFromWithOptimisticLock{})); err != nil {
			if apierrors.IsConflict(err) {
				return ctrl.Result{RequeueAfter: time.Second}, nil
			}
			return ctrl.Result{}, fmt.Errorf("add finalizer: %w", err)
		}
	}

	// The force-release annotation on a live service is ignored with an Event (FR-103).
	r.forceReleaseOnLive(n)

	before := n.Status.DeepCopy()
	res, err := p.run(ctx)
	if p.outcome != "" {
		outcome = p.outcome
	}
	n.Status.ObservedGeneration = n.Generation
	if !equality.Semantic.DeepEqual(before, &n.Status) {
		if uerr := r.Client.Status().Update(ctx, n); uerr != nil {
			if apierrors.IsConflict(uerr) {
				return ctrl.Result{RequeueAfter: time.Second}, nil
			}
			return ctrl.Result{}, fmt.Errorf("update Network status: %w", uerr)
		}
	}
	return res, err
}

func (r *Reconciler) forget(uid types.UID) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.attempts, uid)
	delete(r.lastPass, uid)
	delete(r.unknownByTarget, uid)
}

// ---------------------------------------------------------------------------
// One pass.
// ---------------------------------------------------------------------------

type pass struct {
	r     *Reconciler
	n     *fabricv1.Network
	conds *status.Conditions
	log   logr.Logger
	now   time.Time

	// outcome is the reconcile result recorded in the metrics (telemetry.Result*).
	outcome string

	// Degraded inputs gathered on the way.
	partial    *status.Aggregate
	targetsBad []string
}

func (p *pass) run(ctx context.Context) (ctrl.Result, error) {
	r, n := p.r, p.n
	st := r.Settings

	// --- 1. terminal intent validation (InvalidIntent) ---
	if n.Namespace == sdc.SystemNamespace {
		return p.terminal(p.conds.SetNotAccepted(status.ReasonInvalidIntent,
			fmt.Sprintf("a Network never lives in %s, where its Configs are generated without an owner reference (AD-69)", sdc.SystemNamespace)))
	}
	if strings.Contains(n.Name, ".") {
		return p.terminal(p.conds.SetNotAccepted(status.ReasonInvalidIntent,
			"metadata.name contains a dot: the generated Config <name>.<node> would mis-target the configuration"))
	}
	in, err := analyse(n)
	if err != nil {
		return p.terminal(p.conds.SetNotAccepted(status.ReasonInvalidIntent, err.Error()))
	}
	hadReady := HadReportedReady(n)

	// --- 2. the Fabric: it exists and is Accepted — never that it is Ready (AD-55) ---
	f, why, err := r.findFabric(ctx, in)
	if err != nil {
		return p.transient(ctx, "read Fabrics", err)
	}
	if f == nil {
		return p.wait(why)
	}
	// Every attachment resolves through the Fabric's inventory; one that no longer does — a
	// port removed after allocation — refuses the object naming it, keeps every claim and
	// re-allocates nothing (FR-101).
	if probs := inventoryProblems(in, f); len(probs) > 0 {
		msg := strings.Join(probs, "; ")
		if err := p.conds.SetNotAccepted(status.ReasonReferenceNotFound, msg); err != nil {
			return ctrl.Result{}, err
		}
		return p.terminalReady(msg)
	}

	// --- 3. the claim gate (T171): nothing is rendered on an unbound or refused value ---
	co, err := r.resolveClaims(ctx, n, f, hadReady)
	if err != nil {
		// An authority that errors has not answered (AD-56): a dependency wait with backoff.
		return p.transient(ctx, "allocation authority", err)
	}
	if len(co.conflicts) > 0 {
		msg := strings.Join(co.conflicts, "; ")
		if err := p.conds.SetNotAccepted(status.ReasonAllocationConflict, msg); err != nil {
			return ctrl.Result{}, err
		}
		return p.terminalReady(msg)
	}
	if len(co.pending) > 0 {
		return p.wait("waiting for claims to bind: " + strings.Join(co.pending, ", "))
	}

	// --- 4. model, render ---
	si, err := serviceInput(n, f, in)
	if err != nil {
		return p.terminal(p.conds.SetNotAccepted(status.ReasonInvalidIntent, err.Error()))
	}
	m, err := model.BuildService(si)
	if err != nil {
		return p.terminal(p.conds.SetNotAccepted(status.ReasonInvalidIntent, err.Error()))
	}
	if err := p.conds.SetAccepted("intent valid; every attachment resolves through the Fabric inventory; every claim bound"); err != nil {
		return ctrl.Result{}, err
	}
	rendered, err := r.Renderer.RenderService(m)
	if err != nil {
		reason := status.ReasonMappingFailed
		var unc *register.UncoveredError
		if errors.As(err, &unc) {
			reason = status.ReasonRegisterUncovered
		}
		return p.terminal(p.conds.SetNotRendered(reason, err.Error()))
	}
	names := make([]string, 0, len(m.Nodes))
	for _, sn := range m.Nodes {
		if _, ok := rendered[sn.Node]; !ok {
			return p.terminal(p.conds.SetNotRendered(status.ReasonMappingFailed, "no document rendered for "+sn.Node))
		}
		names = append(names, sn.Node)
	}
	sort.Strings(names)
	if err := p.conds.SetRendered(fmt.Sprintf("%d node documents rendered", len(rendered))); err != nil {
		return ctrl.Result{}, err
	}

	// --- 5. the Schema, the compatibility set, the Targets ---
	var waits []string
	if r.Compat != nil {
		schema, err := r.SDC.FindSchema(ctx, st.SchemaNamespace, r.Compat.Schema.Provider, r.Compat.Schema.Version)
		if err != nil {
			return p.transient(ctx, "read Schemas", err)
		}
		if schema == nil {
			if !hadReady {
				waits = append(waits, fmt.Sprintf("Schema %s/%s not loaded and Ready in %s", r.Compat.Schema.Provider, r.Compat.Schema.Version, st.SchemaNamespace))
			}
		} else if mm := r.Compat.ValidateSchema(schema); len(mm) > 0 {
			return p.terminal(p.conds.SetNotRendered(status.ReasonSchemaMismatch,
				"compatibility set differs from versions.lock.yaml: "+strings.Join(mm, "; ")+"; no changed configuration is emitted"))
		}
	}
	var notReady []string
	for _, node := range names {
		tr, err := r.SDC.TargetReady(ctx, st.TargetNamespace, node)
		switch {
		case apierrors.IsNotFound(err):
			notReady = append(notReady, node+" (Target absent)")
			continue
		case err != nil:
			return p.transient(ctx, "read Target "+node, err)
		}
		if !tr.Ready {
			notReady = append(notReady, fmt.Sprintf("%s (%s)", node, tr.Reason))
			continue
		}
		if r.Compat != nil {
			ok, mismatch := r.Compat.ValidateTarget(node, tr.Provider, tr.Version)
			if mismatch != "" {
				return p.terminal(p.conds.SetNotRendered(status.ReasonSchemaMismatch,
					"compatibility set differs from versions.lock.yaml: "+mismatch+"; no changed configuration is emitted"))
			}
			if !ok {
				notReady = append(notReady, node+" (not yet discovered)")
			}
		}
	}
	if len(notReady) > 0 {
		p.targetsBad = notReady
		p.markUnreachable(notReady)
		if hadReady {
			// The reconcile that sees a required target of a Network Ready at its current
			// generation not Ready is a read-back that cannot run (AD-40, AD-54):
			// Ready=Unknown and Degraded=True, both VerificationFailed, naming the target, at
			// once; lastVerifiedTime frozen.
			r.setUnknownByTarget(n.UID, true)
			msg := "read-back could not run against " + strings.Join(notReady, ", ") + ": target not Ready"
			if err := p.writeReady(readyOutcome{kind: readyUnknown, msg: msg}); err != nil {
				return ctrl.Result{}, err
			}
			return ctrl.Result{RequeueAfter: st.ReconcileInterval}, nil
		}
		// Converging (never Ready at this generation): Applied=False/TargetNotReady naming
		// the target and Ready=False/NotConverged — never Unknown (AD-62).
		waits = append(waits, "targets not Ready: "+strings.Join(notReady, ", "))
		if err := p.conds.SetNotApplied(status.ReasonTargetNotReady, strings.Join(waits, "; ")); err != nil {
			return ctrl.Result{}, err
		}
	}
	if len(waits) > 0 {
		return p.wait(strings.Join(waits, "; "))
	}

	// --- 6. before any write, on every pass: open force-release findings, overruled paths,
	// the name's holder, overlaps ---
	if msgs := staleFindingConflicts(f, m); len(msgs) > 0 {
		// Not terminal: it ends when the Fabric's scheduled re-verification clears the finding
		// (the Fabric watch, and this requeue), with no action on the Network (§18, CD-02).
		msg := strings.Join(msgs, "; ")
		if err := p.conds.SetNotApplied(status.ReasonOwnershipConflict, msg); err != nil {
			return ctrl.Result{}, err
		}
		if _, err := p.terminalReady(msg); err != nil {
			return ctrl.Result{}, err
		}
		p.outcome = telemetry.ResultWait
		return ctrl.Result{RequeueAfter: st.ReconcileInterval}, nil
	}
	if msgs, err := p.overruled(ctx, names); err != nil {
		return p.transient(ctx, "read Deviations", err)
	} else if len(msgs) > 0 {
		// Terminal: never answered with a reapply; the condition stays until the deviation is
		// gone (Rule 4, Rule 6, AD-66).
		msg := strings.Join(msgs, "; ")
		if err := p.conds.SetNotApplied(status.ReasonOwnershipConflict, msg); err != nil {
			return ctrl.Result{}, err
		}
		return p.terminalReady(msg)
	}
	if msgs, err := p.holders(ctx, names); err != nil {
		return p.transient(ctx, "read Configs", err)
	} else if len(msgs) > 0 {
		msg := strings.Join(msgs, "; ")
		if err := p.conds.SetNotApplied(status.ReasonOwnershipConflict, msg); err != nil {
			return ctrl.Result{}, err
		}
		return p.terminalReady(msg)
	}
	if msgs, err := p.overlaps(ctx, names, rendered); err != nil {
		return p.transient(ctx, "compare with the nodes' priority-20 Configs", err)
	} else if len(msgs) > 0 {
		// Two Configs that could touch one leaf at one priority: refused at validation,
		// never an ordering left to the layer (Rule 4, AD-68).
		msg := strings.Join(msgs, "; ")
		if err := p.conds.SetNotApplied(status.ReasonOwnershipConflict, msg); err != nil {
			return ctrl.Result{}, err
		}
		return p.terminalReady(msg)
	}

	// --- 7. server-side apply one priority-20 Config per (service, node) ---
	src := sdc.Source{Kind: sdc.SourceNetwork, Namespace: n.Namespace, Name: n.Name, UID: n.UID, Generation: n.Generation}
	desired := map[string]string{}
	wrote := false
	compatID := ""
	if r.Compat != nil {
		compatID = r.Compat.Identifier()
	}
	for _, node := range names {
		rn := rendered[node]
		hash := rn.Hash
		if !strings.HasPrefix(hash, "sha256:") {
			hash = "sha256:" + hash
		}
		res, err := r.SDC.ApplyConfig(ctx, sdc.ConfigRequest{
			Source: src, Node: node, TargetNamespace: st.TargetNamespace,
			Priority: sdc.PriorityService, Revertive: st.Revertive,
			Value: rn.JSON, RenderHash: hash, CompatibilitySet: compatID,
		})
		if sdc.IsOwnershipConflict(err) {
			msg := p.holderMessage(err)
			if serr := p.conds.SetNotApplied(status.ReasonOwnershipConflict, msg); serr != nil {
				return ctrl.Result{}, serr
			}
			return p.terminalReady(msg)
		}
		if err != nil {
			return p.transient(ctx, "apply Config for "+node, err)
		}
		desired[res.Name] = node
		if res.Created || res.Updated {
			wrote = true
			verb := "updated"
			if res.Created {
				verb = "created"
			}
			r.event(n, "Normal", EventConfigApplied, "Config %s/%s %s (priority 20, revertive, render %s)", sdc.SystemNamespace, res.Name, verb, short(hash))
		}
	}
	if err := p.prune(ctx, desired); err != nil {
		return p.transient(ctx, "prune Configs", err)
	}

	// --- 8. per-target state from the layer ---
	states, err := p.targetStates(ctx, names)
	if err != nil {
		return p.transient(ctx, "read Config status", err)
	}
	agg := status.AggregateTargets(states)
	if !agg.Ready && hadReady && !wrote {
		// The layer no longer confirms, on a target, an intent it confirmed at this very
		// generation, and nothing was written in this reconcile: the intent did not change, the
		// target's side did — the layer's view of the target is what cannot be read. That is a
		// read-back that cannot run, not a convergence: Ready=Unknown and Degraded=True, both
		// VerificationFailed, naming each target with the layer's own reason; lastVerifiedTime
		// frozen; Applied left as it was (AD-40, AD-54, AD-62). This is what keeps SC-008's
		// bound when the layer notices a lost session in its Config status before its Target.
		var bad []string
		for _, rc := range n.Status.RenderedConfigs {
			if rc.Phase == fabricv1.TargetPhase(status.PhaseReady) {
				continue
			}
			why := rc.Reason
			if rc.Message != "" {
				why = strings.TrimSpace(why + ": " + truncate(rc.Message, 256))
			}
			if why == "" {
				why = "the layer no longer confirms its Config"
			}
			bad = append(bad, fmt.Sprintf("%s (%s)", rc.Node, why))
		}
		p.targetsBad = bad
		p.markUnreachable(bad)
		r.setUnknownByTarget(n.UID, true)
		msg := "read-back could not run against " + strings.Join(bad, ", ") + ": the layer no longer confirms this generation's Config there"
		if err := p.writeReady(readyOutcome{kind: readyUnknown, msg: msg}); err != nil {
			return ctrl.Result{}, err
		}
		r.resetAttempts(n.UID)
		return ctrl.Result{RequeueAfter: st.ReconcileInterval}, nil
	}
	if !agg.Ready {
		if len(agg.Failed) > 0 {
			if err := p.conds.SetNotApplied(status.ReasonTransactionFailed, "transaction failed on "+strings.Join(agg.Failed, ", ")); err != nil {
				return ctrl.Result{}, err
			}
		} else if err := p.conds.SetNotApplied(status.ReasonTargetNotReady, "awaiting the layer's confirmation on "+strings.Join(agg.NotReady, ", ")); err != nil {
			return ctrl.Result{}, err
		}
		p.partial = &agg
		msg := "targets not Ready: " + strings.Join(agg.NotReady, ", ")
		if err := p.writeReady(readyOutcome{kind: readyFalse, reason: status.ReasonNotConverged, msg: msg}); err != nil {
			return ctrl.Result{}, err
		}
		r.resetAttempts(n.UID)
		if len(agg.Failed) > 0 && len(agg.Failed) == len(agg.NotReady) {
			// Every outstanding target failed its transaction: terminal until a new
			// generation or a layer change (the Config watch).
			p.outcome = telemetry.ResultTerminal
			return ctrl.Result{}, nil
		}
		return ctrl.Result{RequeueAfter: st.ReconcileInterval}, nil
	}
	if err := p.conds.SetApplied("every node's priority-20 Config confirmed by the layer"); err != nil {
		return ctrl.Result{}, err
	}
	if err := p.conds.SetValidated("the layer validated every Config against the loaded Schema"); err != nil {
		return ctrl.Result{}, err
	}
	r.resetAttempts(n.UID)

	// --- 9. the read-back (T058): first convergence, or the scheduled pass ---
	converging := !HadReportedReady(n)
	due, next := r.passDue(n, p.now)
	byTarget := r.getUnknownByTarget(n.UID) && readyStatus(n) == metav1.ConditionUnknown
	if readyStatus(n) == metav1.ConditionUnknown {
		// A pass that could not run is retried at the reconciliation interval, not the
		// re-verification one: Ready=True returns "at the first pass after the target
		// does" (Rule 5), and the target's return is only seen by a pass. A retry that
		// still cannot run changes nothing — lastVerifiedTime stays frozen (AD-40).
		// Observed live 2026-09-24 (T167; live-findings 2026-09-24-unknown-retry).
		if rdue, rnext := r.retryDue(n, p.now); rdue {
			due = true
		} else if rnext.Before(next) {
			next = rnext
		}
	}
	if !converging && !due && !byTarget {
		if err := p.writeReady(readyOutcome{kind: readyLeave}); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: next.Sub(p.now)}, nil
	}
	prefixes, err := routedPrefixes(n)
	if err != nil {
		return p.terminal(p.conds.SetNotAccepted(status.ReasonInvalidIntent, err.Error()))
	}
	vin := verify.ServiceInput{Model: m, Prefixes: prefixes, Loopbacks: leafLoopbacks(f), TargetNamespace: st.TargetNamespace}
	for _, node := range names {
		name, _ := sdc.ConfigName(n.Name, node)
		vin.Nodes = append(vin.Nodes, verify.ServiceNodeInput{Node: node, ConfigName: name, Rendered: rendered[node].JSON})
	}
	r.markPass(n.UID, p.now)
	r.setUnknownByTarget(n.UID, false)
	result, verr := r.Verifier.VerifyService(ctx, vin)
	if cnr := verify.AsCouldNotRun(verr); cnr != nil {
		msg := cnr.Error()
		p.markUnreachable(cnr.Targets())
		if HadReportedReady(n) {
			// A pass that cannot run: Unknown, never False, never a standing True;
			// lastVerifiedTime frozen (AD-40).
			if err := p.writeReady(readyOutcome{kind: readyUnknown, msg: msg}); err != nil {
				return ctrl.Result{}, err
			}
			return ctrl.Result{RequeueAfter: st.ReconcileInterval}, nil
		}
		// Never reported Ready at this generation: converging, Ready=False.
		if err := p.writeReady(readyOutcome{kind: readyFalse, reason: status.ReasonNotConverged, msg: msg}); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: st.ReconcileInterval}, nil
	}
	if verr != nil {
		return p.transient(ctx, "read-back", verr)
	}
	// The pass ran: lastVerifiedTime advances whatever it found (AD-54).
	status.RecordVerification(&n.Status.LastVerifiedTime, status.Verification{Ran: true}, p.now)
	out := readyOutcome{kind: readyTrue, msg: result.Message()}
	if !result.Passed() {
		out = readyOutcome{kind: readyFalse, reason: result.Reason(), msg: result.Message()}
	}
	if err := p.writeReady(out); err != nil {
		return ctrl.Result{}, err
	}
	if out.kind == readyTrue {
		// A Ready Network is requeued at the re-verification interval — the schedule is a
		// requeue, not a second controller.
		return ctrl.Result{RequeueAfter: st.ReverifyInterval}, nil
	}
	// An invariant missing: converging again, re-read at the reconciliation interval until
	// it returns.
	return ctrl.Result{RequeueAfter: st.ReconcileInterval}, nil
}

// wait records a dependency wait: nothing written to any device, Ready=False/NotConverged
// naming what is awaited (a Network Ready at its current generation keeps its Ready),
// requeued at the reconciliation interval — never by the schedule.
func (p *pass) wait(msg string) (ctrl.Result, error) {
	p.outcome = telemetry.ResultWait
	p.r.resetAttempts(p.n.UID)
	if HadReportedReady(p.n) {
		if err := p.writeReady(readyOutcome{kind: readyLeave}); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: p.r.Settings.ReconcileInterval}, nil
	}
	if err := p.writeReady(readyOutcome{kind: readyFalse, reason: status.ReasonNotConverged, msg: "waiting: " + msg}); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{RequeueAfter: p.r.Settings.ReconcileInterval}, nil
}

// terminal records a terminal error (the condition was set by the caller) and sets
// Ready=False naming it: no requeue — a new generation or a dependency change (the watches)
// retries it (Rule 7).
func (p *pass) terminal(setErr error) (ctrl.Result, error) {
	if setErr != nil {
		return ctrl.Result{}, setErr
	}
	msg := "refused"
	for _, typ := range []string{status.Accepted, status.Rendered, status.Applied} {
		if c := p.conds.Get(typ); c != nil && c.Status == metav1.ConditionFalse && c.ObservedGeneration == p.n.Generation {
			msg = c.Message
			break
		}
	}
	return p.terminalReady(msg)
}

// terminalReady is terminal with the refusal msg on Ready=False/NotConverged: a Network is
// never left Ready=True beside a terminal refusal.
func (p *pass) terminalReady(msg string) (ctrl.Result, error) {
	p.outcome = telemetry.ResultTerminal
	p.r.resetAttempts(p.n.UID)
	if err := p.writeReady(readyOutcome{kind: readyFalse, reason: status.ReasonNotConverged, msg: "refused: " + msg}); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, nil
}

// transient schedules a bounded exponential backoff with full jitter (data-model.md §25): at
// most MaxAttempts fast retries, then the reconciliation interval, with one RetriesExhausted
// Event.
func (p *pass) transient(ctx context.Context, what string, err error) (ctrl.Result, error) {
	r, st := p.r, p.r.Settings
	n := r.bumpAttempts(p.n.UID)
	p.outcome = telemetry.ResultTransient
	telemetry.ObserveRetry(telemetry.ControllerNetwork)
	p.log.Error(err, "transient failure; retrying", "step", what, "attempt", n)
	r.event(p.n, "Warning", EventTransientError, "%s: %v (attempt %d)", what, err, n)
	if p.n.DeletionTimestamp == nil {
		if !HadReportedReady(p.n) {
			if serr := p.writeReady(readyOutcome{kind: readyFalse, reason: status.ReasonNotConverged, msg: "waiting: " + what + " did not answer: " + err.Error()}); serr != nil {
				return ctrl.Result{}, serr
			}
		} else if serr := p.writeReady(readyOutcome{kind: readyLeave}); serr != nil {
			return ctrl.Result{}, serr
		}
	}
	if n > st.MaxAttempts {
		if n == st.MaxAttempts+1 {
			r.event(p.n, "Warning", EventRetriesExhausted, "%s: %d fast retries exhausted; retrying every %s", what, st.MaxAttempts, st.ReconcileInterval)
		}
		return ctrl.Result{RequeueAfter: st.ReconcileInterval}, nil
	}
	return ctrl.Result{RequeueAfter: fabric.Backoff(st.BackoffBase, st.BackoffCap, n, r.Jitter)}, nil
}

// findFabric is the Fabric the Network's attachments resolve through: the Fabric in
// agentic-netops-system whose inventory lists every attachment's node — the first by name
// when several do — or, when exactly one Fabric exists, that one (its inventory then names
// what does not resolve). It must be Accepted; its Ready is never consulted (AD-55). A nil
// Fabric is a dependency wait, why says what is awaited.
func (r *Reconciler) findFabric(ctx context.Context, in *intent) (*fabricv1.Fabric, string, error) {
	l := &fabricv1.FabricList{}
	if err := r.Client.List(ctx, l, client.InNamespace(sdc.SystemNamespace)); err != nil {
		return nil, "", err
	}
	if len(l.Items) == 0 {
		return nil, "no Fabric exists in " + sdc.SystemNamespace, nil
	}
	sort.Slice(l.Items, func(i, j int) bool { return l.Items[i].Name < l.Items[j].Name })
	var chosen *fabricv1.Fabric
	for i := range l.Items {
		f := &l.Items[i]
		nodes := map[string]bool{}
		for _, e := range f.Spec.Inventory {
			nodes[string(e.Node)] = true
		}
		all := true
		for _, node := range in.nodes {
			if !nodes[node] {
				all = false
			}
		}
		if all {
			chosen = f
			break
		}
	}
	if chosen == nil {
		if len(l.Items) != 1 {
			return nil, fmt.Sprintf("no Fabric in %s lists every attachment node (%s) in its inventory", sdc.SystemNamespace, strings.Join(in.nodes, ", ")), nil
		}
		chosen = &l.Items[0]
	}
	if !meta.IsStatusConditionTrue(chosen.Status.Conditions, status.Accepted) {
		return nil, fmt.Sprintf("Fabric %s/%s is not Accepted", chosen.Namespace, chosen.Name), nil
	}
	return chosen, "", nil
}

// overruled reads each node Config's Deviation and names every OVERRULED path with the
// overruling intent (AD-66). A NOT_APPLIED deviation is the layer's revertive repair and sets
// nothing here.
func (p *pass) overruled(ctx context.Context, names []string) ([]string, error) {
	var out []string
	for _, node := range names {
		name, _ := sdc.ConfigName(p.n.Name, node)
		dev, err := p.r.SDC.GetConfigDeviation(ctx, name)
		if err != nil {
			return nil, err
		}
		if dev == nil {
			continue
		}
		for _, d := range dev.Spec.Deviations {
			if d.Reason != sdc.DeviationOverruled {
				continue
			}
			by, err := p.overrulingIntent(ctx, node, name, d)
			if err != nil {
				return nil, err
			}
			out = append(out, fmt.Sprintf("Config %s/%s: platform-owned path %s overruled by %s — an OVERRULED deviation is terminal and never reapplied (Rule 4, AD-66)",
				sdc.SystemNamespace, name, d.Path, by))
		}
	}
	sort.Strings(out)
	return out, nil
}

// overrulingIntent names the intent that overruled path on node: every other Config of the
// node that writes that leaf, else what the layer reports of it.
func (p *pass) overrulingIntent(ctx context.Context, node, own string, d configv1alpha1.ConfigDeviation) (string, error) {
	want := NormalizePath(d.Path)
	cfgs, err := p.r.SDC.ListConfigsForTarget(ctx, p.r.Settings.TargetNamespace, node)
	if err != nil {
		return "", err
	}
	var by []string
	for i := range cfgs {
		c := &cfgs[i]
		if c.Name == own {
			continue
		}
		paths, err := configLeafPaths(c)
		if err != nil {
			continue
		}
		if containsPath(paths, want) {
			by = append(by, fmt.Sprintf("Config %s/%s (priority %d)", c.Namespace, c.Name, c.Spec.Priority))
		}
	}
	if len(by) > 0 {
		sort.Strings(by)
		return "the higher-precedence intent " + strings.Join(by, ", "), nil
	}
	return fmt.Sprintf("a higher-precedence intent the layer reports (desired %s, actual %s)", deref(d.DesiredValue), deref(d.ActualValue)), nil
}

// holders names every Config of a derived name held by another source (AD-69): it is never
// overwritten. Checked for every node before any write, so nothing is written on any node.
func (p *pass) holders(ctx context.Context, names []string) ([]string, error) {
	var out []string
	for _, node := range names {
		name, _ := sdc.ConfigName(p.n.Name, node)
		cfg, err := p.r.SDC.GetConfig(ctx, name)
		if apierrors.IsNotFound(err) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if uid := cfg.Annotations[sdc.AnnotationSourceUID]; uid != string(p.n.UID) {
			out = append(out, holderText(cfg))
		}
	}
	return out, nil
}

func holderText(cfg *configv1alpha1.Config) string {
	holder := "another source"
	if ns, nm := cfg.Labels[sdc.LabelNetworkNamespace], cfg.Labels[sdc.LabelNetworkName]; ns != "" && nm != "" {
		holder = fmt.Sprintf("Network %s/%s", ns, nm)
	} else if f := cfg.Labels[sdc.LabelFabricName]; f != "" {
		holder = fmt.Sprintf("Fabric %s/%s", sdc.SystemNamespace, f)
	}
	return fmt.Sprintf("Config %s/%s is held by %s (source-uid %s) and is never overwritten: two Networks of one name derive one Config name (AD-69)",
		cfg.Namespace, cfg.Name, holder, cfg.Annotations[sdc.AnnotationSourceUID])
}

// holderMessage names the holder of an OwnershipConflictError the apply returned.
func (p *pass) holderMessage(err error) string {
	var oc *sdc.OwnershipConflictError
	if errors.As(err, &oc) {
		if cfg, gerr := p.r.SDC.GetConfig(context.Background(), oc.Name); gerr == nil {
			return holderText(cfg)
		}
	}
	return err.Error()
}

// overlaps compares this object's non-key leaf paths with those of every other priority-20
// Config of each node (AD-68): an overlap names the path and the other Config.
func (p *pass) overlaps(ctx context.Context, names []string, rendered map[string]Rendered) ([]string, error) {
	var out []string
	for _, node := range names {
		mine, err := NonKeyLeafPaths(rendered[node].JSON)
		if err != nil {
			return nil, err
		}
		own, _ := sdc.ConfigName(p.n.Name, node)
		cfgs, err := p.r.SDC.ListConfigsForTarget(ctx, p.r.Settings.TargetNamespace, node)
		if err != nil {
			return nil, err
		}
		for i := range cfgs {
			c := &cfgs[i]
			if c.Name == own || c.Spec.Priority != sdc.PriorityService || c.Annotations[sdc.AnnotationSourceUID] == string(p.n.UID) {
				continue
			}
			theirs, err := configLeafPaths(c)
			if err != nil {
				continue
			}
			var shared []string
			for _, pth := range mine {
				if containsPath(theirs, pth) {
					shared = append(shared, pth)
				}
			}
			if len(shared) == 0 {
				continue
			}
			more := ""
			if len(shared) > 5 {
				more = fmt.Sprintf(" and %d more", len(shared)-5)
				shared = shared[:5]
			}
			out = append(out, fmt.Sprintf("priority collision on %s: leaf %s%s is also written by Config %s/%s at the same priority %d — two Configs that can touch one leaf never share a priority (Rule 4, AD-68)",
				node, strings.Join(shared, ", "), more, c.Namespace, c.Name, sdc.PriorityService))
		}
	}
	return out, nil
}

// configLeafPaths are the non-key leaf paths of a stored Config's value.
func configLeafPaths(c *configv1alpha1.Config) ([]string, error) {
	var out []string
	for _, blob := range c.Spec.Config {
		paths, err := NonKeyLeafPaths(blob.Value.Raw)
		if err != nil {
			return nil, err
		}
		base := strings.TrimSuffix(NormalizePath(blob.Path), "/")
		for _, pth := range paths {
			out = append(out, base+pth)
		}
	}
	sort.Strings(out)
	return out, nil
}

func containsPath(sorted []string, p string) bool {
	i := sort.SearchStrings(sorted, p)
	return i < len(sorted) && sorted[i] == p
}

// prune deletes this Network's Configs for nodes it no longer attaches to.
func (p *pass) prune(ctx context.Context, desired map[string]string) error {
	existing, err := p.r.SDC.ListConfigsForNetwork(ctx, p.n.Namespace, p.n.Name)
	if err != nil {
		return err
	}
	for _, c := range existing {
		if _, keep := desired[c.Name]; keep || c.Annotations[sdc.AnnotationSourceUID] != string(p.n.UID) {
			continue
		}
		if err := p.r.SDC.DeleteConfig(ctx, c.Name, p.n.UID); err != nil {
			if sdc.IsOwnershipConflict(err) {
				continue
			}
			return err
		}
		p.r.event(p.n, "Normal", EventConfigPruned, "Config %s/%s deleted: the Network no longer attaches to its node", sdc.SystemNamespace, c.Name)
	}
	return nil
}

// targetStates reads each node's Config as the layer reports it and records the per-target
// status (the per-device status of the Status contract).
func (p *pass) targetStates(ctx context.Context, names []string) ([]status.TargetState, error) {
	var states []status.TargetState
	prev := map[string]fabricv1.RenderedConfig{}
	for _, rc := range p.n.Status.RenderedConfigs {
		prev[rc.Node] = rc
	}
	var out []fabricv1.RenderedConfig
	for _, node := range names {
		name, _ := sdc.ConfigName(p.n.Name, node)
		cfg, err := p.r.SDC.GetConfig(ctx, name)
		if err != nil {
			return nil, err
		}
		cs := sdc.ConfigStatus(cfg)
		phase, reason, msg := status.PhaseRendered, cs.Reason, cs.Message
		cond := cfg.GetCondition("Ready")
		switch {
		case cs.Ready && (cond.ObservedGeneration == 0 || cond.ObservedGeneration >= cfg.Generation):
			phase = status.PhaseReady
		case cs.Reason == "Failed" || cs.Reason == "Unrecoverable":
			phase = status.PhaseFailed
		}
		states = append(states, status.TargetState{Target: node, Phase: phase})
		rc := fabricv1.RenderedConfig{
			Node: node, Name: name, Namespace: sdc.SystemNamespace, Priority: sdc.PriorityService,
			RenderHash: cfg.Annotations[sdc.AnnotationRenderHash], ObservedGeneration: p.n.Generation,
			Phase: fabricv1.TargetPhase(phase), Reason: reason, Message: truncate(msg, 2048),
		}
		p.stamp(&rc, prev[node])
		out = append(out, rc)
	}
	p.n.Status.RenderedConfigs = out
	return states, nil
}

// markUnreachable records the unreachable targets in the per-target status; the healthy
// targets keep their phase.
func (p *pass) markUnreachable(targets []string) {
	bad := map[string]string{}
	for _, s := range targets {
		node, why, _ := strings.Cut(s, " ")
		bad[node] = strings.Trim(why, "()")
	}
	for i := range p.n.Status.RenderedConfigs {
		rc := &p.n.Status.RenderedConfigs[i]
		if why, ok := bad[rc.Node]; ok {
			old := *rc
			if why == "" {
				why = "read-back could not run"
			}
			rc.Phase, rc.Reason, rc.Message = fabricv1.TargetPhaseUnreachable, status.ReasonTargetNotReady, why
			p.stamp(rc, old)
		}
	}
}

func (p *pass) stamp(rc *fabricv1.RenderedConfig, old fabricv1.RenderedConfig) {
	if old.Phase == rc.Phase && old.LastTransitionTime != nil {
		rc.LastTransitionTime = old.LastTransitionTime
		return
	}
	t := metav1.NewTime(p.now)
	rc.LastTransitionTime = &t
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

func short(h string) string {
	h = strings.TrimPrefix(h, "sha256:")
	if len(h) > 12 {
		return h[:12]
	}
	return h
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

func deref(s *string) string {
	if s == nil {
		return "(none)"
	}
	return *s
}

func (r *Reconciler) event(obj *fabricv1.Network, typ, reason, format string, a ...any) {
	if r.Recorder != nil {
		r.Recorder.Eventf(obj, typ, reason, format, a...)
	}
}

func (r *Reconciler) bumpAttempts(uid types.UID) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.attempts[uid]++
	return r.attempts[uid]
}

func (r *Reconciler) resetAttempts(uid types.UID) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.attempts, uid)
}

func (r *Reconciler) markPass(uid types.UID, t time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lastPass[uid] = t
}

func (r *Reconciler) setUnknownByTarget(uid types.UID, v bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if v {
		r.unknownByTarget[uid] = true
	} else {
		delete(r.unknownByTarget, uid)
	}
}

func (r *Reconciler) getUnknownByTarget(uid types.UID) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.unknownByTarget[uid]
}

// retryDue reports whether the read-back of a Network held at Ready=Unknown is
// due again: one reconciliation interval after the last attempt this process
// made (with none recorded, at once).
func (r *Reconciler) retryDue(n *fabricv1.Network, now time.Time) (bool, time.Time) {
	r.mu.Lock()
	last, ok := r.lastPass[n.UID]
	r.mu.Unlock()
	if !ok {
		return true, now
	}
	next := last.Add(r.Settings.ReconcileInterval)
	return !now.Before(next), next
}

// passDue reports whether the scheduled pass is due at now, and when the next one is. The last
// pass is the last attempt this process made, else the last pass that ran
// (status.lastVerifiedTime); with neither, it is due.
func (r *Reconciler) passDue(n *fabricv1.Network, now time.Time) (bool, time.Time) {
	r.mu.Lock()
	last, ok := r.lastPass[n.UID]
	r.mu.Unlock()
	if !ok {
		if n.Status.LastVerifiedTime == nil {
			return true, now
		}
		last = n.Status.LastVerifiedTime.Time
	}
	next := last.Add(r.Settings.ReverifyInterval)
	return !now.Before(next), next
}
