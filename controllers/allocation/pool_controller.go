package allocation

import (
	"context"
	"fmt"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
)

// PoolReconciler validates IdentifierPools and keeps their status: Ready, allocated =
// len(ledger), and a ledger holding no entry whose claim (by name and UID) is gone — an
// entry only a claim whose finalizer was removed by hand can leave behind.
type PoolReconciler struct {
	Client    client.Client
	APIReader client.Reader
}

// SetupWithManager registers the pool controller: pools on a spec change (the claim
// controller keeps the ledger and the count; a status write needs no pool pass), and
// claims going away mapped to their pool (what makes an orphaned entry collectable).
func (r *PoolReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		Named("identifierpool").
		For(&fabricv1.IdentifierPool{}, builder.WithPredicates(predicate.GenerationChangedPredicate{})).
		Watches(&fabricv1.IdentifierClaim{}, handler.EnqueueRequestsFromMapFunc(func(_ context.Context, o client.Object) []reconcile.Request {
			c, ok := o.(*fabricv1.IdentifierClaim)
			if !ok || c.DeletionTimestamp == nil {
				return nil
			}
			return []reconcile.Request{{NamespacedName: types.NamespacedName{Namespace: c.Namespace, Name: string(c.Spec.PoolRef.Name)}}}
		})).
		Complete(r)
}

// Reconcile validates one pool and writes its status.
func (r *PoolReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		pool := &fabricv1.IdentifierPool{}
		if err := r.APIReader.Get(ctx, req.NamespacedName, pool); err != nil {
			return client.IgnoreNotFound(err)
		}
		before := pool.Status.DeepCopy()

		kept := make([]fabricv1.IdentifierAllocation, 0, len(pool.Status.Allocations))
		for _, e := range pool.Status.Allocations {
			live, err := r.claimLive(ctx, pool.Namespace, e)
			if err != nil {
				return err
			}
			if live {
				kept = append(kept, e)
			}
		}
		pool.Status.Allocations = kept
		pool.Status.Allocated = int64(len(kept))
		pool.Status.ObservedGeneration = pool.Generation

		cond := metav1.Condition{Type: ConditionReady, ObservedGeneration: pool.Generation}
		if s, err := parsePool(pool); err != nil {
			cond.Status, cond.Reason, cond.Message = metav1.ConditionFalse, ReasonPoolInvalid, err.Error()
		} else {
			cond.Status, cond.Reason = metav1.ConditionTrue, ReasonPoolValid
			cond.Message = fmt.Sprintf("%s is valid; status.allocations is its ledger", s)
		}
		meta.SetStatusCondition(&pool.Status.Conditions, cond)
		if poolStatusEqual(before, &pool.Status) {
			return nil
		}
		return r.Client.Status().Update(ctx, pool)
	})
	if apierrors.IsNotFound(err) {
		return ctrl.Result{}, nil
	}
	return ctrl.Result{}, err
}

// claimLive reports whether the entry's claim exists: the same name with another UID is
// another claim, and the entry is not its. The cache answers "live" cheaply; only an entry
// the cache calls orphaned is confirmed uncached before it is dropped.
func (r *PoolReconciler) claimLive(ctx context.Context, ns string, e fabricv1.IdentifierAllocation) (bool, error) {
	key := types.NamespacedName{Namespace: ns, Name: e.Claim}
	c := &fabricv1.IdentifierClaim{}
	if err := r.Client.Get(ctx, key, c); err == nil && (e.ClaimUID == "" || string(c.UID) == e.ClaimUID) {
		return true, nil
	}
	if err := r.APIReader.Get(ctx, key, c); err != nil {
		if apierrors.IsNotFound(err) {
			return false, nil
		}
		return false, err
	}
	return e.ClaimUID == "" || string(c.UID) == e.ClaimUID, nil
}

func poolStatusEqual(a, b *fabricv1.IdentifierPoolStatus) bool {
	if a.Allocated != b.Allocated || a.ObservedGeneration != b.ObservedGeneration ||
		len(a.Allocations) != len(b.Allocations) || len(a.Conditions) != len(b.Conditions) {
		return false
	}
	for i := range a.Allocations {
		if a.Allocations[i] != b.Allocations[i] {
			return false
		}
	}
	for i := range a.Conditions {
		x, y := a.Conditions[i], b.Conditions[i]
		if x.Type != y.Type || x.Status != y.Status || x.Reason != y.Reason || x.Message != y.Message || x.ObservedGeneration != y.ObservedGeneration {
			return false
		}
	}
	return true
}
