// Package allocation is the first-party allocation authority (T176; data-model.md §23,
// contracts/kuid-claim-profiles.md §6–§7): the IdentifierPool and IdentifierClaim
// controllers, adopted by the recorded decision docs/decisions/allocator-substitution.md
// and registered only when versions.lock.yaml selects allocationAuthority.kind:
// first-party (cmd/srl-provider, role allocation-authority).
//
// The semantics the platform relies on:
//
//   - A dynamic claim is bound the LOWEST free value of its pool, never one below the
//     pool's minimum; a stated claim (spec.requested) binds exactly that value or is
//     refused — Conflict naming the holding claim, OutOfRange naming the pool's range —
//     and no other value is tried.
//   - The pool's ledger, IdentifierPool.status.allocations, is the one record of what is
//     held. Binding reads the pool fresh from the API server (never the cache), computes
//     against the ledger and writes it back with the resourceVersion read, so two
//     concurrent claims for one value bind exactly one, across workers and processes; an
//     in-process per-pool mutex keeps the workers of one process from colliding at all.
//     Only after the ledger holds the entry is the value reported on the claim.
//   - A claim carries the finalizer Finalizer: its entry is removed from the ledger before
//     the claim goes, so a DELETE that waits for finalizers returns with the value free,
//     and an immediate second claim for it binds.
//   - There is no timer, lease or expiry of a value, and no pool anywhere else.
package allocation

import (
	"context"
	"fmt"
	"sync"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/compat"
)

// Namespace is where the substitute's pools and claims live (data-model.md §23).
const Namespace = "agentic-netops-allocation"

// Finalizer is on every IdentifierClaim: its value is released from the pool's ledger
// before the claim is let go.
const Finalizer = "fabric.agentic-netops.io/identifier-release"

// ConditionReady is the one condition type of a pool and a claim.
const ConditionReady = "Ready"

// Claim Ready reasons.
const (
	// ReasonBound (True): status.value is held by this claim in the pool's ledger.
	ReasonBound = "Bound"
	// ReasonPoolNotFound (Unknown): the named pool does not exist; re-evaluated when it does.
	ReasonPoolNotFound = "PoolNotFound"
	// ReasonConflict (False): the stated value is held by another claim, named.
	ReasonConflict = "Conflict"
	// ReasonOutOfRange (False): the stated value is outside the pool.
	ReasonOutOfRange = "OutOfRange"
	// ReasonExhausted (False): a dynamic claim against a pool with no free value.
	ReasonExhausted = "Exhausted"
	// ReasonInvalid (False): the claim, or its pool, cannot be evaluated as written.
	ReasonInvalid = "Invalid"
)

// Pool Ready reasons.
const (
	ReasonPoolValid   = "Valid"
	ReasonPoolInvalid = ReasonInvalid
)

// poolLocks serializes arbitration per pool within this process.
type poolLocks struct {
	mu    sync.Mutex
	locks map[types.NamespacedName]*sync.Mutex
}

func (p *poolLocks) lock(k types.NamespacedName) func() {
	p.mu.Lock()
	if p.locks == nil {
		p.locks = map[types.NamespacedName]*sync.Mutex{}
	}
	m, ok := p.locks[k]
	if !ok {
		m = &sync.Mutex{}
		p.locks[k] = m
	}
	p.mu.Unlock()
	m.Lock()
	return m.Unlock
}

// ClaimReconciler binds and releases IdentifierClaims against their pool's ledger.
type ClaimReconciler struct {
	// Client is the manager's (cached) client: claims are read from it and written through it.
	Client client.Client
	// APIReader reads pools uncached: arbitration never computes against a cache.
	APIReader client.Reader
	// MaxConcurrentReconciles is the worker count (default 1); arbitration is correct at any.
	MaxConcurrentReconciles int

	locks poolLocks
}

// SetupWithManager registers the claim controller: claims, and pools mapped to their
// claims that are not bound — so a claim waiting for its pool, refused a held value or
// refused by an exhausted pool is re-evaluated on every ledger change, a release included.
func (r *ClaimReconciler) SetupWithManager(mgr ctrl.Manager) error {
	if r.MaxConcurrentReconciles < 1 {
		r.MaxConcurrentReconciles = 1
	}
	return ctrl.NewControllerManagedBy(mgr).
		Named("identifierclaim").
		For(&fabricv1.IdentifierClaim{}).
		Watches(&fabricv1.IdentifierPool{}, handler.EnqueueRequestsFromMapFunc(r.unboundClaimsOfPool)).
		WithOptions(controller.Options{MaxConcurrentReconciles: r.MaxConcurrentReconciles}).
		Complete(r)
}

func (r *ClaimReconciler) unboundClaimsOfPool(ctx context.Context, o client.Object) []reconcile.Request {
	l := &fabricv1.IdentifierClaimList{}
	if err := r.Client.List(ctx, l, client.InNamespace(o.GetNamespace())); err != nil {
		return nil
	}
	var out []reconcile.Request
	for _, c := range l.Items {
		if string(c.Spec.PoolRef.Name) != o.GetName() {
			continue
		}
		if c.Status.Value != "" && meta.IsStatusConditionTrue(c.Status.Conditions, ConditionReady) {
			continue
		}
		out = append(out, reconcile.Request{NamespacedName: types.NamespacedName{Namespace: c.Namespace, Name: c.Name}})
	}
	return out
}

// conflictRetry is how soon a write that lost an optimistic-concurrency race is retried.
const conflictRetry = 100 * time.Millisecond

// Reconcile binds, refuses or releases one claim.
func (r *ClaimReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	c := &fabricv1.IdentifierClaim{}
	if err := r.Client.Get(ctx, req.NamespacedName, c); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	poolKey := types.NamespacedName{Namespace: c.Namespace, Name: string(c.Spec.PoolRef.Name)}

	if c.DeletionTimestamp != nil {
		if !controllerutil.ContainsFinalizer(c, Finalizer) {
			return ctrl.Result{}, nil
		}
		if err := r.release(ctx, poolKey, c); err != nil {
			return ctrl.Result{}, err
		}
		controllerutil.RemoveFinalizer(c, Finalizer)
		return requeueOnConflict(r.Client.Update(ctx, c))
	}

	// The finalizer first: a value is never reported on a claim that could go without
	// releasing it.
	if !controllerutil.ContainsFinalizer(c, Finalizer) {
		controllerutil.AddFinalizer(c, Finalizer)
		if err := r.Client.Update(ctx, c); err != nil {
			return requeueOnConflict(err)
		}
	}

	value, ref, err := r.bind(ctx, poolKey, c)
	if err != nil {
		return ctrl.Result{}, err
	}
	if ref != nil {
		return r.writeStatus(ctx, c, "", ref.status, ref.Reason, ref.Message)
	}
	return r.writeStatus(ctx, c, value, metav1.ConditionTrue, ReasonBound,
		fmt.Sprintf("value %s bound from pool %s/%s", value, poolKey.Namespace, poolKey.Name))
}

// answer is a claim's non-binding outcome and the Ready status it carries.
type answer struct {
	refusal
	status metav1.ConditionStatus
}

// bind arbitrates the claim against the pool's ledger. It returns the value bound, or the
// answer that is not a binding; an error is the API server failing to answer.
func (r *ClaimReconciler) bind(ctx context.Context, poolKey types.NamespacedName, c *fabricv1.IdentifierClaim) (string, *answer, error) {
	unlock := r.locks.lock(poolKey)
	defer unlock()

	var value string
	var ans *answer
	err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		value, ans = "", nil
		pool := &fabricv1.IdentifierPool{}
		if err := r.APIReader.Get(ctx, poolKey, pool); err != nil {
			if apierrors.IsNotFound(err) {
				ans = &answer{status: metav1.ConditionUnknown, refusal: refusal{Reason: ReasonPoolNotFound,
					Message: fmt.Sprintf("IdentifierPool %s/%s does not exist; the claim is evaluated when it does", poolKey.Namespace, poolKey.Name)}}
				return nil
			}
			return err
		}
		s, err := parsePool(pool)
		if err != nil {
			ans = &answer{status: metav1.ConditionFalse, refusal: refusal{Reason: ReasonInvalid,
				Message: fmt.Sprintf("IdentifierPool %s/%s is invalid: %v", poolKey.Namespace, poolKey.Name, err)}}
			return nil
		}

		// The ledger without stale entries of an earlier claim of this name (another UID).
		ledger := make([]fabricv1.IdentifierAllocation, 0, len(pool.Status.Allocations)+1)
		changed := false
		for _, e := range pool.Status.Allocations {
			if e.Claim == c.Name {
				if e.ClaimUID == string(c.UID) || e.ClaimUID == "" {
					// Idempotent after a crash between the ledger write and the claim's.
					value = e.Value
					if e.ClaimUID == "" {
						e.ClaimUID = string(c.UID)
						changed = true
					}
				} else {
					changed = true
					continue
				}
			}
			ledger = append(ledger, e)
		}

		if value == "" {
			var ref *refusal
			value, ref = r.choose(s, c, ledger)
			if ref != nil {
				ans = &answer{status: metav1.ConditionFalse, refusal: *ref}
				value = ""
				if !changed {
					return nil
				}
			} else {
				ledger = append(ledger, fabricv1.IdentifierAllocation{Value: value, Claim: c.Name, ClaimUID: string(c.UID)})
				changed = true
			}
		}
		if !changed {
			return nil
		}
		s.sortLedger(ledger)
		pool.Status.Allocations = ledger
		pool.Status.Allocated = int64(len(ledger))
		return r.Client.Status().Update(ctx, pool)
	})
	if err != nil {
		return "", nil, fmt.Errorf("arbitrate %s/%s in pool %s: %w", c.Namespace, c.Name, poolKey, err)
	}
	return value, ans, nil
}

// choose computes the value a claim not yet in the ledger is bound, or its refusal.
func (r *ClaimReconciler) choose(s *shape, c *fabricv1.IdentifierClaim, ledger []fabricv1.IdentifierAllocation) (string, *refusal) {
	stated := c.Spec.Requested
	if stated == "" && c.Status.Value != "" && meta.IsStatusConditionTrue(c.Status.Conditions, ConditionReady) {
		// A claim that reported a value keeps it: its ledger entry was lost (the pool was
		// re-created), so it is re-recorded if still free, never moved.
		stated = c.Status.Value
	}
	if stated != "" {
		v, ref := s.canonical(stated, c.Spec.PrefixLength)
		if ref != nil {
			return "", ref
		}
		if h := s.holder(v, ledger, c.Name); h != nil {
			msg := fmt.Sprintf("value %s is held by claim %s/%s", v, c.Namespace, h.Claim)
			if h.Value != v {
				msg += fmt.Sprintf(" (it holds %s, which overlaps)", h.Value)
			}
			return "", refuse(ReasonConflict, "%s; no other value is tried", msg)
		}
		return v, nil
	}
	bits, ref := s.dynamicBits(c.Spec.PrefixLength)
	if ref != nil {
		return "", ref
	}
	v, ok := s.lowestFree(ledger, bits)
	if !ok {
		if s.isIP() {
			return "", refuse(ReasonExhausted, "%s is exhausted: no free /%d is left", s, bits)
		}
		return "", refuse(ReasonExhausted, "%s is exhausted: all %s values are held", s, s.size())
	}
	return v, nil
}

// release removes the claim's entries from its pool's ledger: a fresh read and an
// optimistic update, retried on conflict. A pool that is gone holds nothing.
func (r *ClaimReconciler) release(ctx context.Context, poolKey types.NamespacedName, c *fabricv1.IdentifierClaim) error {
	unlock := r.locks.lock(poolKey)
	defer unlock()
	err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		pool := &fabricv1.IdentifierPool{}
		if err := r.APIReader.Get(ctx, poolKey, pool); err != nil {
			return client.IgnoreNotFound(err)
		}
		kept := make([]fabricv1.IdentifierAllocation, 0, len(pool.Status.Allocations))
		for _, e := range pool.Status.Allocations {
			if e.Claim == c.Name && (e.ClaimUID == string(c.UID) || e.ClaimUID == "") {
				continue
			}
			kept = append(kept, e)
		}
		if len(kept) == len(pool.Status.Allocations) {
			return nil
		}
		pool.Status.Allocations = kept
		pool.Status.Allocated = int64(len(kept))
		return r.Client.Status().Update(ctx, pool)
	})
	if err != nil {
		return fmt.Errorf("release %s/%s from pool %s: %w", c.Namespace, c.Name, poolKey, err)
	}
	return nil
}

// writeStatus writes the claim's status when it changed.
func (r *ClaimReconciler) writeStatus(ctx context.Context, c *fabricv1.IdentifierClaim, value string,
	st metav1.ConditionStatus, reason, msg string) (ctrl.Result, error) {
	before := c.Status.DeepCopy()
	c.Status.Value = value
	c.Status.ObservedGeneration = c.Generation
	meta.SetStatusCondition(&c.Status.Conditions, metav1.Condition{Type: ConditionReady, Status: st,
		Reason: reason, Message: msg, ObservedGeneration: c.Generation})
	if statusEqual(before, &c.Status) {
		return ctrl.Result{}, nil
	}
	return requeueOnConflict(r.Client.Status().Update(ctx, c))
}

func statusEqual(a, b *fabricv1.IdentifierClaimStatus) bool {
	if a.Value != b.Value || a.ObservedGeneration != b.ObservedGeneration || len(a.Conditions) != len(b.Conditions) {
		return false
	}
	for i := range a.Conditions {
		x, y := a.Conditions[i], b.Conditions[i]
		if x.Type != y.Type || x.Status != y.Status || x.Reason != y.Reason || x.Message != y.Message || x.ObservedGeneration != y.ObservedGeneration {
			return false
		}
	}
	return true
}

func requeueOnConflict(err error) (ctrl.Result, error) {
	if apierrors.IsConflict(err) {
		return ctrl.Result{RequeueAfter: conflictRetry}, nil
	}
	return ctrl.Result{}, client.IgnoreNotFound(err)
}

// RegisteredUnder says whether the allocation controllers may be registered under the
// lock file's allocationAuthority.kind: only under first-party. Under any other kind the
// error names allocationAuthority.kind — kuid's authority is the one installed, and there
// is never a second (FR-104).
func RegisteredUnder(authorityKind string) error {
	if authorityKind != compat.AuthorityFirstParty {
		return fmt.Errorf("versions.lock.yaml allocationAuthority.kind is %q: the first-party allocation authority is registered only when the lock file selects %s",
			authorityKind, compat.AuthorityFirstParty)
	}
	return nil
}
