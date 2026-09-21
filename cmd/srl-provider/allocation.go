package main

import (
	"context"
	"fmt"

	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/controllers/allocation"
	"github.com/mairp/agentic-netops-srl/internal/compat"
	"github.com/mairp/agentic-netops-srl/internal/telemetry"
)

// ClaimWorkers is the claim controller's worker count: arbitration is serialized per pool
// by the ledger's optimistic update, so claims of different pools proceed in parallel.
const ClaimWorkers = 4

// runAllocationAuthority hosts the first-party allocation authority (T176): a manager
// whose cache holds only the authority's namespace, its own leader-election lease there,
// the provider's metrics and probe endpoints, and the pool and claim controllers — and
// nothing else. The caller has established that the lock selects first-party.
func runAllocationAuthority(ctx context.Context, s settings, set *compat.Set) error {
	log := ctrl.Log
	scheme := runtime.NewScheme()
	for _, add := range []func(*runtime.Scheme) error{clientgoscheme.AddToScheme, fabricv1.AddToScheme} {
		if err := add(scheme); err != nil {
			return err
		}
	}
	cfg, err := ctrl.GetConfig()
	if err != nil {
		return fmt.Errorf("cluster config: %w", err)
	}
	mgr, err := newAllocationManager(cfg, scheme, s)
	if err != nil {
		return fmt.Errorf("manager: %w", err)
	}
	if err := setupAllocationControllers(mgr); err != nil {
		return err
	}
	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		return err
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		return err
	}
	log.Info("allocation authority starting", "role", s.Role, "namespace", allocation.Namespace,
		"allocationAuthority", set.AuthorityKind(), "compatibilitySet", set.Identifier(), "component", telemetry.Component)
	return mgr.Start(ctx)
}

func newAllocationManager(cfg *rest.Config, scheme *runtime.Scheme, s settings) (ctrl.Manager, error) {
	return ctrl.NewManager(cfg, ctrl.Options{
		Scheme:                  scheme,
		Metrics:                 metricsserver.Options{BindAddress: s.MetricsAddr},
		HealthProbeBindAddress:  s.ProbeAddr,
		LeaderElection:          s.LeaderElect,
		LeaderElectionID:        AllocationLeaderElectionID,
		LeaderElectionNamespace: allocation.Namespace,
		Cache:                   cache.Options{DefaultNamespaces: map[string]cache.Config{allocation.Namespace: {}}},
	})
}

// setupAllocationControllers registers the pool and claim controllers, and only them.
func setupAllocationControllers(mgr ctrl.Manager) error {
	if err := (&allocation.PoolReconciler{Client: mgr.GetClient(), APIReader: mgr.GetAPIReader()}).SetupWithManager(mgr); err != nil {
		return fmt.Errorf("identifier pool controller: %w", err)
	}
	if err := (&allocation.ClaimReconciler{Client: mgr.GetClient(), APIReader: mgr.GetAPIReader(),
		MaxConcurrentReconciles: ClaimWorkers}).SetupWithManager(mgr); err != nil {
		return fmt.Errorf("identifier claim controller: %w", err)
	}
	return nil
}
