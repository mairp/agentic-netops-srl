// Package fabric is the Fabric reconciler (T040): it waits for the Schema and
// the four Targets, claims the underlay loopbacks, ASNs and /31 links through
// pkg/kuid, asserts the compatibility set, renders, and server-side-applies one
// priority-10 Config per node — spec.revertive stated true from DRIFT_POLICY,
// in agentic-netops-system, with a controller owner reference to the Fabric —
// then sets Ready only from the two-sided read-back of internal/verify, on
// first convergence and on every scheduled re-verification (FR-014, FR-016,
// FR-017, FR-018, FR-100, FR-107; data-model.md §3a, §18, §19, §25).
//
// The read-back is taken as an interface (Verifier) that internal/verify
// implements and cmd/srl-provider wires (AD-67); the renderer (Renderer) and
// the telemetry-health input (TelemetryHealth) likewise. A Fabric has no
// finalizer and no held deletion in this feature (AD-62): its Configs are
// collected through their owner reference.
package fabric

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/go-logr/logr"
	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	invv1alpha1 "github.com/sdcio/config-server/apis/inv/v1alpha1"
	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"k8s.io/utils/clock"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/compat"
	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/status"
	"github.com/mairp/agentic-netops-srl/internal/telemetry"
	"github.com/mairp/agentic-netops-srl/internal/verify"
	"github.com/mairp/agentic-netops-srl/pkg/kuid"
	"github.com/mairp/agentic-netops-srl/pkg/register"
	"github.com/mairp/agentic-netops-srl/pkg/sdc"
)

// Event reasons the reconciler publishes beside the condition transitions that
// internal/status emits.
const (
	EventConfigApplied    = "ConfigApplied"
	EventConfigPruned     = "ConfigPruned"
	EventFindingCleared   = "FindingCleared"
	EventTransientError   = "TransientError"
	EventRetriesExhausted = "RetriesExhausted"
)

// Settings are the reconciler's configuration (data-model.md §25); every
// duration is an environment variable of the provider (cmd/srl-provider).
type Settings struct {
	// Revertive is what DRIFT_POLICY=revertive maps to — the value stated on
	// every generated Config's spec.revertive, never absent (FR-015, AD-17).
	Revertive bool
	// ReconcileInterval is the requeue of a waiting or converging object
	// (RECONCILE_INTERVAL, default 15 s).
	ReconcileInterval time.Duration
	// ReverifyInterval is the scheduled re-verification of an object that has
	// reported Ready (REVERIFY_INTERVAL, default 5 min, floor 30 s).
	ReverifyInterval time.Duration
	// Transient-error backoff: exponential from BackoffBase with full jitter,
	// capped at BackoffCap, at most MaxAttempts fast retries.
	BackoffBase time.Duration
	BackoffCap  time.Duration
	MaxAttempts int
	// TargetNamespace holds the layer's Targets, SchemaNamespace its Schemas.
	TargetNamespace string
	SchemaNamespace string
}

// DefaultSettings are the §25 defaults, with the drift policy stated.
func DefaultSettings() Settings {
	return Settings{
		Revertive:         true,
		ReconcileInterval: 15 * time.Second,
		ReverifyInterval:  5 * time.Minute,
		BackoffBase:       250 * time.Millisecond,
		BackoffCap:        10 * time.Second,
		MaxAttempts:       6,
		TargetNamespace:   "sdc-system",
		SchemaNamespace:   "sdc-system",
	}
}

// Rendered is one node's rendered document (internal/render/srl.Rendered).
type Rendered struct {
	Node string
	JSON []byte
	Hash string
}

// Renderer renders the fabric model, keyed by node.
type Renderer interface {
	RenderFabric(m *model.FabricModel) (map[string]Rendered, error)
}

// Verifier is the Fabric read-back (internal/verify.Fabric). It returns a
// result for a pass that ran and a *verify.CouldNotRunError for one that could
// not.
type Verifier interface {
	VerifyFabric(ctx context.Context, in verify.FabricInput) (verify.FabricResult, error)
}

// TelemetryHealth is the telemetry-health input — the only thing
// Degraded=True/TelemetryUnavailable is ever set from, never a device read
// (data-model.md §18, AD-62).
type TelemetryHealth interface {
	TelemetryHealthy(ctx context.Context) (healthy bool, detail string)
}

// Reconciler reconciles Fabric objects.
type Reconciler struct {
	Client    client.Client
	SDC       *sdc.Client
	Claims    kuid.Claims
	Renderer  Renderer
	Verifier  Verifier
	Telemetry TelemetryHealth
	Compat    *compat.Set
	Recorder  record.EventRecorder
	Clock     clock.Clock
	Settings  Settings
	// Jitter returns a value in [0,1); nil uses a deterministic 1.0 (tests).
	Jitter func() float64

	mu sync.Mutex
	// attempts counts consecutive transient failures per Fabric.
	attempts map[types.UID]int
	// lastPass is when the last read-back pass was attempted (ran or not),
	// which paces the schedule of an object at Ready=Unknown.
	lastPass map[types.UID]time.Time
	// unknownByTarget marks a Ready=Unknown set by the reconcile that saw a
	// target not Ready: the target's return is itself the next pass.
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

// SetupWithManager registers the reconciler: Fabrics (on generation change),
// the Configs it owns, and — mapped to every Fabric — Targets, Schemas and
// Networks (cluster-wide: a changed attachment re-decides the tagging-mode
// rule of AD-68).
func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	all := handler.EnqueueRequestsFromMapFunc(r.allFabrics)
	return ctrl.NewControllerManagedBy(mgr).
		Named("fabric").
		For(&fabricv1.Fabric{}, builder.WithPredicates(predicate.GenerationChangedPredicate{})).
		Owns(&configv1alpha1.Config{}).
		Watches(&configv1alpha1.Target{}, all).
		Watches(&invv1alpha1.Schema{}, all).
		Watches(&fabricv1.Network{}, all, builder.WithPredicates(predicate.GenerationChangedPredicate{})).
		Complete(r)
}

func (r *Reconciler) allFabrics(ctx context.Context, _ client.Object) []reconcile.Request {
	l := &fabricv1.FabricList{}
	if err := r.Client.List(ctx, l, client.InNamespace(sdc.SystemNamespace)); err != nil {
		return nil
	}
	out := make([]reconcile.Request, 0, len(l.Items))
	for _, f := range l.Items {
		out = append(out, reconcile.Request{NamespacedName: types.NamespacedName{Namespace: f.Namespace, Name: f.Name}})
	}
	return out
}

// Reconcile runs one pass over one Fabric and writes its status once, only
// when it changed.
func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	r.init()
	f := &fabricv1.Fabric{}
	if err := r.Client.Get(ctx, req.NamespacedName, f); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}
	log := logr.FromContextOrDiscard(ctx).WithValues(telemetry.ObjectValues("Fabric", f.Namespace, f.Name, f.Labels)...)
	ctx = logr.NewContext(ctx, log)
	if f.DeletionTimestamp != nil {
		// No finalizer, no held deletion (AD-62): the owner references collect
		// the Configs.
		r.forget(f.UID)
		return ctrl.Result{}, nil
	}
	before := f.Status.DeepCopy()
	p := &pass{r: r, f: f, log: log, now: r.Clock.Now(),
		conds: status.For(f, &f.Status.Conditions, r.Recorder).WithNow(r.Clock.Now)}
	res, err := p.run(ctx)
	f.Status.ObservedGeneration = f.Generation
	if !equality.Semantic.DeepEqual(before, &f.Status) {
		if uerr := r.Client.Status().Update(ctx, f); uerr != nil {
			if apierrors.IsConflict(uerr) {
				return ctrl.Result{RequeueAfter: time.Second}, nil
			}
			return ctrl.Result{}, fmt.Errorf("update Fabric status: %w", uerr)
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
	f     *fabricv1.Fabric
	conds *status.Conditions
	log   logr.Logger
	now   time.Time

	// Degraded inputs gathered on the way.
	partial    *status.Aggregate
	passRan    bool
	targetsBad []string
}

func (p *pass) run(ctx context.Context) (ctrl.Result, error) {
	r, f := p.r, p.f
	st := r.Settings

	// --- 1. terminal intent validation (InvalidIntent) ---
	if f.Namespace != sdc.SystemNamespace {
		return p.terminal(p.conds.SetNotAccepted(status.ReasonInvalidIntent,
			fmt.Sprintf("a Fabric lives in %s, where its Configs are generated with an owner reference to it (AD-69)", sdc.SystemNamespace)))
	}
	in, err := analyse(f)
	if err != nil {
		return p.terminal(p.conds.SetNotAccepted(status.ReasonInvalidIntent, err.Error()))
	}
	networks := &fabricv1.NetworkList{}
	if err := r.Client.List(ctx, networks); err != nil {
		return p.transient(ctx, "list Networks cluster-wide", err)
	}
	if flips := tagFlips(in, networks.Items); len(flips) > 0 {
		// Refused before any claim, render or Config write: the last rendered
		// Config is left as it was (AD-68).
		return p.terminal(p.conds.SetNotAccepted(status.ReasonInvalidIntent, flipMessage(flips)))
	}
	hadReady := hadReportedReady(f)

	// --- 2. dependencies: the Schema, the compatibility set, the Targets ---
	schema, err := r.SDC.FindSchema(ctx, st.SchemaNamespace, r.Compat.Schema.Provider, r.Compat.Schema.Version)
	if err != nil {
		return p.transient(ctx, "read Schemas", err)
	}
	var waits []string
	if schema == nil {
		if !hadReady {
			waits = append(waits, fmt.Sprintf("Schema %s/%s not loaded and Ready in %s", r.Compat.Schema.Provider, r.Compat.Schema.Version, st.SchemaNamespace))
		}
	} else if mm := r.Compat.ValidateSchema(schema); len(mm) > 0 {
		return p.terminal(p.conds.SetNotRendered(status.ReasonSchemaMismatch,
			"compatibility set differs from versions.lock.yaml: "+strings.Join(mm, "; ")+"; no changed configuration is emitted"))
	}
	names := sortedNodes(in)
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
		ok, mismatch := r.Compat.ValidateTarget(node, tr.Provider, tr.Version)
		if mismatch != "" {
			return p.terminal(p.conds.SetNotRendered(status.ReasonSchemaMismatch,
				"compatibility set differs from versions.lock.yaml: "+mismatch+"; no changed configuration is emitted"))
		}
		if !ok {
			notReady = append(notReady, node+" (not yet discovered)")
		}
	}
	if len(notReady) > 0 {
		p.targetsBad = notReady
		p.markUnreachable(notReady)
		if hadReady {
			// The reconcile that sees a required target of a Ready object not
			// Ready is a read-back that cannot run (AD-40): Ready=Unknown and
			// Degraded=True, both VerificationFailed, naming the target, at
			// once; lastVerifiedTime frozen.
			r.setUnknownByTarget(f.UID, true)
			msg := "read-back could not run against " + strings.Join(notReady, ", ") + ": target not Ready"
			if err := p.writeReady(readyOutcome{kind: readyUnknown, msg: msg}); err != nil {
				return ctrl.Result{}, err
			}
			return ctrl.Result{RequeueAfter: st.ReverifyInterval}, nil
		}
		waits = append(waits, "targets not Ready: "+strings.Join(notReady, ", "))
		if err := p.conds.SetNotApplied(status.ReasonTargetNotReady, strings.Join(waits, "; ")); err != nil {
			return ctrl.Result{}, err
		}
	}
	if len(waits) > 0 {
		// No Config is written while any dependency is unmet.
		return p.wait(strings.Join(waits, "; "))
	}

	// --- 3. claims through pkg/kuid ---
	cr, err := r.ensureClaims(ctx, f, in)
	if err != nil {
		// An authority that errors has not answered (AD-56).
		return p.transient(ctx, "allocation authority", err)
	}
	f.Status.Allocations = cr.allocations
	if len(cr.conflicts) > 0 {
		return p.terminal(p.conds.SetNotAccepted(status.ReasonAllocationConflict, strings.Join(cr.conflicts, "; ")))
	}
	if len(cr.pending) > 0 {
		return p.wait("waiting for claims to bind: " + strings.Join(cr.pending, ", "))
	}
	f.Status.Allocated = fmt.Sprintf("%d/%d", len(cr.allocations), len(cr.allocations))
	f.Status.Leaves, f.Status.Spines = int32(len(in.leaves)), int32(len(in.spines))

	// --- 4. model, render ---
	m, err := model.BuildFabric(modelInput(f, in, cr))
	if err != nil {
		return p.terminal(p.conds.SetNotAccepted(status.ReasonInvalidIntent, err.Error()))
	}
	if err := p.conds.SetAccepted("design valid; every underlay claim bound"); err != nil {
		return ctrl.Result{}, err
	}
	rendered, err := r.Renderer.RenderFabric(m)
	if err != nil {
		reason := status.ReasonMappingFailed
		if _, ok := err.(*register.UncoveredError); ok {
			reason = status.ReasonRegisterUncovered
		}
		return p.terminal(p.conds.SetNotRendered(reason, err.Error()))
	}
	if err := p.conds.SetRendered(fmt.Sprintf("%d node documents rendered", len(rendered))); err != nil {
		return ctrl.Result{}, err
	}

	// --- 5. server-side apply one priority-10 Config per node ---
	owner := metav1.NewControllerRef(f, fabricv1.GroupVersion.WithKind("Fabric"))
	src := sdc.Source{Kind: sdc.SourceFabric, Namespace: f.Namespace, Name: f.Name, UID: f.UID, Generation: f.Generation}
	desired := map[string]string{}
	for _, node := range names {
		rn, ok := rendered[node]
		if !ok {
			return p.terminal(p.conds.SetNotRendered(status.ReasonMappingFailed, "no document rendered for "+node))
		}
		hash := rn.Hash
		if !strings.HasPrefix(hash, "sha256:") {
			hash = "sha256:" + hash
		}
		res, err := r.SDC.ApplyConfig(ctx, sdc.ConfigRequest{
			Source: src, Node: node, TargetNamespace: st.TargetNamespace,
			Priority: sdc.PriorityFabric, Revertive: st.Revertive,
			Value: rn.JSON, RenderHash: hash, CompatibilitySet: r.Compat.Identifier(), Owner: owner,
		})
		if sdc.IsOwnershipConflict(err) {
			return p.terminal(p.conds.SetNotApplied(status.ReasonOwnershipConflict, err.Error()))
		}
		if err != nil {
			return p.transient(ctx, "apply Config for "+node, err)
		}
		desired[res.Name] = node
		if res.Created || res.Updated {
			verb := "updated"
			if res.Created {
				verb = "created"
			}
			r.event(f, "Normal", EventConfigApplied, "Config %s/%s %s (priority 10, revertive, render %s)", sdc.SystemNamespace, res.Name, verb, short(hash))
		}
	}
	if err := p.prune(ctx, desired); err != nil {
		return p.transient(ctx, "prune Configs", err)
	}

	// --- 6. per-target state from the layer ---
	states, overruled, err := p.targetStates(ctx, names, rendered)
	if err != nil {
		return p.transient(ctx, "read Config status", err)
	}
	if len(overruled) > 0 {
		// An OVERRULED deviation on a platform-owned path is terminal (Rule 4).
		return p.terminal(p.conds.SetNotApplied(status.ReasonOwnershipConflict, strings.Join(overruled, "; ")))
	}
	agg := status.AggregateTargets(states)
	if !agg.Ready {
		if len(agg.Failed) > 0 {
			if err := p.conds.SetNotApplied(status.ReasonTransactionFailed, "transaction failed on "+strings.Join(agg.Failed, ", ")); err != nil {
				return ctrl.Result{}, err
			}
		}
		p.partial = &agg
		msg := "targets not Ready: " + strings.Join(agg.NotReady, ", ")
		if err := p.writeReady(readyOutcome{kind: readyFalse, reason: status.ReasonNotConverged, msg: msg}); err != nil {
			return ctrl.Result{}, err
		}
		r.resetAttempts(f.UID)
		if len(agg.Failed) > 0 && len(agg.Failed) == len(agg.NotReady) {
			// Every outstanding target failed its transaction: terminal until a
			// new generation or a layer change (the Owns watch).
			return ctrl.Result{}, nil
		}
		return ctrl.Result{RequeueAfter: st.ReconcileInterval}, nil
	}
	if err := p.conds.SetApplied("every node's priority-10 Config confirmed by the layer"); err != nil {
		return ctrl.Result{}, err
	}
	if err := p.conds.SetValidated("the layer validated every Config against the loaded Schema"); err != nil {
		return ctrl.Result{}, err
	}
	r.resetAttempts(f.UID)

	// --- 7. the read-back: first convergence, or the scheduled pass ---
	converging := !hadReportedReady(f)
	due, next := r.passDue(f, p.now)
	byTarget := r.getUnknownByTarget(f.UID) && readyStatus(f) == metav1.ConditionUnknown
	if !converging && !due && !byTarget {
		if err := p.writeReady(readyOutcome{kind: readyLeave}); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: next.Sub(p.now)}, nil
	}
	vin := verify.FabricInput{Model: m, InterASVPN: interASVPN(f), TargetNamespace: st.TargetNamespace}
	for _, node := range names {
		name, _ := sdc.ConfigName(f.Name, node)
		vin.Nodes = append(vin.Nodes, verify.FabricNodeInput{Node: node, ConfigName: name, Rendered: rendered[node].JSON})
	}
	for i, fd := range f.Status.Findings {
		if _, in := in.nodeSet[fd.Node]; in {
			vin.Findings = append(vin.Findings, verify.FindingInput{Index: i, Node: fd.Node, DeviceObjects: fd.DeviceObjects})
		}
	}
	r.markPass(f.UID, p.now)
	r.setUnknownByTarget(f.UID, false)
	result, verr := r.Verifier.VerifyFabric(ctx, vin)
	if cnr := verify.AsCouldNotRun(verr); cnr != nil {
		msg := cnr.Error()
		if hadReportedReady(f) {
			// A pass that cannot run: Unknown, never False, never a standing
			// True; lastVerifiedTime frozen (AD-40).
			if err := p.writeReady(readyOutcome{kind: readyUnknown, msg: msg}); err != nil {
				return ctrl.Result{}, err
			}
			return ctrl.Result{RequeueAfter: st.ReverifyInterval}, nil
		}
		// Never reported Ready: it is converging, and stays Ready=False.
		if err := p.writeReady(readyOutcome{kind: readyFalse, reason: status.ReasonNotConverged, msg: msg}); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: st.ReconcileInterval}, nil
	}
	if verr != nil {
		return p.transient(ctx, "read-back", verr)
	}
	// The pass ran: lastVerifiedTime advances whatever it found (AD-54).
	p.passRan = true
	status.RecordVerification(&f.Status.LastVerifiedTime, status.Verification{Ran: true}, p.now)
	p.clearFindings(result.ClearedFindings)
	out := readyOutcome{kind: readyTrue, msg: result.Message()}
	if !result.Passed() {
		out = readyOutcome{kind: readyFalse, reason: result.Reason(), msg: result.Message()}
	}
	if err := p.writeReady(out); err != nil {
		return ctrl.Result{}, err
	}
	if out.kind == readyTrue {
		// A Ready Fabric is requeued at the re-verification interval — the
		// schedule is a requeue, not a second controller.
		return ctrl.Result{RequeueAfter: st.ReverifyInterval}, nil
	}
	return ctrl.Result{RequeueAfter: st.ReconcileInterval}, nil
}

// wait records a dependency wait: nothing written to any device, Ready=False/
// NotConverged naming what is awaited (an object that had reported Ready is
// handled by the caller), requeued at the reconciliation interval — never by
// the schedule.
func (p *pass) wait(msg string) (ctrl.Result, error) {
	p.r.resetAttempts(p.f.UID)
	if hadReportedReady(p.f) {
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

// terminal records a terminal error (the condition was set by the caller): no
// requeue — a new generation or a dependency change (the watches) retries it.
func (p *pass) terminal(setErr error) (ctrl.Result, error) {
	p.r.resetAttempts(p.f.UID)
	if setErr != nil {
		return ctrl.Result{}, setErr
	}
	if err := p.writeReady(readyOutcome{kind: readyLeave}); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, nil
}

// transient schedules a bounded exponential backoff with full jitter
// (data-model.md §25): at most MaxAttempts fast retries, then the
// reconciliation interval, with one RetriesExhausted Event.
func (p *pass) transient(ctx context.Context, what string, err error) (ctrl.Result, error) {
	r, st := p.r, p.r.Settings
	n := r.bumpAttempts(p.f.UID)
	p.log.Error(err, "transient failure; retrying", "step", what, "attempt", n)
	r.event(p.f, "Warning", EventTransientError, "%s: %v (attempt %d)", what, err, n)
	if !hadReportedReady(p.f) {
		if serr := p.writeReady(readyOutcome{kind: readyFalse, reason: status.ReasonNotConverged, msg: "waiting: " + what + " did not answer: " + err.Error()}); serr != nil {
			return ctrl.Result{}, serr
		}
	} else if serr := p.writeReady(readyOutcome{kind: readyLeave}); serr != nil {
		return ctrl.Result{}, serr
	}
	if n > st.MaxAttempts {
		if n == st.MaxAttempts+1 {
			r.event(p.f, "Warning", EventRetriesExhausted, "%s: %d fast retries exhausted; retrying every %s", what, st.MaxAttempts, st.ReconcileInterval)
		}
		return ctrl.Result{RequeueAfter: st.ReconcileInterval}, nil
	}
	return ctrl.Result{RequeueAfter: Backoff(st.BackoffBase, st.BackoffCap, n, r.Jitter)}, nil
}

// Backoff is attempt n's delay: full jitter over min(cap, base·2^(n-1)).
func Backoff(base, cap time.Duration, n int, jitter func() float64) time.Duration {
	d := base
	for i := 1; i < n && d < cap; i++ {
		d *= 2
	}
	if d > cap {
		d = cap
	}
	j := 1.0
	if jitter != nil {
		j = jitter()
	}
	out := time.Duration(float64(d) * j)
	if out < time.Millisecond {
		out = time.Millisecond
	}
	return out
}

// prune deletes this Fabric's Configs for nodes no longer in spec.nodes.
func (p *pass) prune(ctx context.Context, desired map[string]string) error {
	existing, err := p.r.SDC.ListConfigsForFabric(ctx, p.f.Name)
	if err != nil {
		return err
	}
	for _, c := range existing {
		if _, keep := desired[c.Name]; keep {
			continue
		}
		if err := p.r.SDC.DeleteConfig(ctx, c.Name, p.f.UID); err != nil {
			if sdc.IsOwnershipConflict(err) {
				continue // another source's Config is never touched
			}
			return err
		}
		p.r.event(p.f, "Normal", EventConfigPruned, "Config %s/%s deleted: its node left spec.nodes", sdc.SystemNamespace, c.Name)
	}
	return nil
}

// targetStates reads each node's Config as the layer reports it and records
// the per-target status (the per-device status of the Status contract).
func (p *pass) targetStates(ctx context.Context, names []string, rendered map[string]Rendered) ([]status.TargetState, []string, error) {
	var states []status.TargetState
	var overruled []string
	prev := map[string]fabricv1.RenderedConfig{}
	for _, rc := range p.f.Status.RenderedConfigs {
		prev[rc.Node] = rc
	}
	var out []fabricv1.RenderedConfig
	for _, node := range names {
		name, _ := sdc.ConfigName(p.f.Name, node)
		cfg, err := p.r.SDC.GetConfig(ctx, name)
		if err != nil {
			return nil, nil, err
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
		dev, err := p.r.SDC.GetConfigDeviation(ctx, name)
		if err != nil {
			return nil, nil, err
		}
		if paths := sdc.PathsWithReason(dev, sdc.DeviationOverruled); len(paths) > 0 {
			overruled = append(overruled, fmt.Sprintf("Config %s: platform-owned path(s) %s overruled by a higher-precedence intent", name, strings.Join(paths, ", ")))
		}
		states = append(states, status.TargetState{Target: node, Phase: phase})
		rc := fabricv1.RenderedConfig{
			Node: node, Name: name, Namespace: sdc.SystemNamespace, Priority: sdc.PriorityFabric,
			RenderHash: cfg.Annotations[sdc.AnnotationRenderHash], ObservedGeneration: cfg.Generation,
			Phase: fabricv1.TargetPhase(phase), Reason: reason, Message: msg,
		}
		p.stamp(&rc, prev[node])
		out = append(out, rc)
	}
	p.f.Status.RenderedConfigs = out
	return states, overruled, nil
}

// markUnreachable records the not-Ready targets in the per-target status.
func (p *pass) markUnreachable(notReady []string) {
	bad := map[string]string{}
	for _, s := range notReady {
		node, why, _ := strings.Cut(s, " ")
		bad[node] = strings.Trim(why, "()")
	}
	for i := range p.f.Status.RenderedConfigs {
		rc := &p.f.Status.RenderedConfigs[i]
		if why, ok := bad[rc.Node]; ok {
			old := *rc
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

// clearFindings removes the findings a pass that ran read clean, publishing an
// Event for each (data-model.md §3a).
func (p *pass) clearFindings(idx []int) {
	if len(idx) == 0 {
		return
	}
	drop := map[int]bool{}
	for _, i := range idx {
		drop[i] = true
	}
	var keep []fabricv1.Finding
	for i, fd := range p.f.Status.Findings {
		if drop[i] {
			p.r.event(p.f, "Normal", EventFindingCleared,
				"finding for service %s/%s on %s cleared: every device object read absent from the running and the state datastore",
				fd.Service.Namespace, fd.Service.Name, fd.Node)
			continue
		}
		keep = append(keep, fd)
	}
	p.f.Status.Findings = keep
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

func sortedNodes(in *intent) []string {
	out := make([]string, 0, len(in.nodes))
	for _, n := range in.nodes {
		out = append(out, string(n.Name))
	}
	sort.Strings(out)
	return out
}

func interASVPN(f *fabricv1.Fabric) bool {
	return f.Spec.Overlay.InterASVPN == nil || *f.Spec.Overlay.InterASVPN
}

func modelInput(f *fabricv1.Fabric, in *intent, cr *claimsResult) model.FabricInput {
	mi := model.FabricInput{
		Name: f.Name, FabricASN: uint32(f.Spec.Overlay.FabricASN), InterASVPN: interASVPN(f),
		AddressFamilies: in.families,
		MTU: model.FabricMTU{PortMTU: uint32(f.Spec.MTU.PortMTU), UnderlayIPMTU: uint32(f.Spec.MTU.UnderlayIPMTU),
			BridgedL2MTU: uint32(f.Spec.MTU.BridgedL2MTU), TenantIPMTU: uint32(f.Spec.MTU.TenantIPMTU)},
		Links: cr.links,
	}
	for _, name := range sortedNodes(in) {
		n := in.nodeSet[name]
		mi.Nodes = append(mi.Nodes, model.FabricNodeInput{
			Name: name, Role: model.Role(n.Role), SystemIPv4: cr.loopback[name], ASN: cr.asn[name],
			RouteReflector: in.reflectors[name],
		})
	}
	for _, e := range f.Spec.Inventory {
		if _, ok := in.nodeSet[string(e.Node)]; !ok {
			continue
		}
		ie := model.InventoryEntry{Node: string(e.Node)}
		for _, p := range e.AccessPorts {
			ie.AccessPorts = append(ie.AccessPorts, string(p))
		}
		for _, p := range e.UntaggedAccessPorts {
			ie.UntaggedAccessPorts = append(ie.UntaggedAccessPorts, string(p))
		}
		for _, p := range e.FabricPorts {
			ie.FabricPorts = append(ie.FabricPorts, string(p))
		}
		mi.Inventory = append(mi.Inventory, ie)
	}
	for _, m := range f.Spec.Maintenance {
		if _, ok := in.nodeSet[string(m.Node)]; !ok {
			continue
		}
		mi.Maintenance = append(mi.Maintenance, model.MaintenanceEntry{Node: string(m.Node), Interface: string(m.Interface), AdminState: string(m.AdminState)})
	}
	return mi
}

func short(h string) string {
	h = strings.TrimPrefix(h, "sha256:")
	if len(h) > 12 {
		return h[:12]
	}
	return h
}

func (r *Reconciler) event(obj *fabricv1.Fabric, typ, reason, format string, a ...any) {
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

// passDue reports whether the scheduled pass is due at now, and when the next
// one is. The last pass is the last attempt this process made, else the last
// pass that ran (status.lastVerifiedTime); with neither, it is due.
func (r *Reconciler) passDue(f *fabricv1.Fabric, now time.Time) (bool, time.Time) {
	r.mu.Lock()
	last, ok := r.lastPass[f.UID]
	r.mu.Unlock()
	if !ok {
		if f.Status.LastVerifiedTime == nil {
			return true, now
		}
		last = f.Status.LastVerifiedTime.Time
	}
	next := last.Add(r.Settings.ReverifyInterval)
	return !now.Before(next), next
}
