package main

// The optional MigrationPlan controller's wiring (T122; AD-29, FR-048). The MigrationPlan CRD
// lives under config/crd/optional/, outside the default kustomization and never applied by lab
// provisioning (T016); the controller is registered only when the API server serves it —
// decided once, at start-up, by discovery — and runs under its own ClusterRole
// (config/rbac/migration/), which grants no write verb on networks.

import (
	"k8s.io/client-go/discovery"
	ctrl "sigs.k8s.io/controller-runtime"

	migrationv1 "github.com/mairp/agentic-netops-srl/api/v1alpha1"
	"github.com/mairp/agentic-netops-srl/controllers/migration"
	"github.com/mairp/agentic-netops-srl/internal/telemetry"
)

// migrationPlanServed reports whether the API server serves the MigrationPlan resource
// (controllers/migration.Served): a group-version it does not know is "not served".
func migrationPlanServed(d discovery.ServerResourcesInterface) (bool, error) {
	return migration.Served(d)
}

// setupMigration registers the MigrationPlan controller when, and only when, its CRD is served.
// It reports whether it registered.
func setupMigration(mgr ctrl.Manager, d discovery.ServerResourcesInterface) (bool, error) {
	served, err := migrationPlanServed(d)
	if err != nil {
		return false, err
	}
	if !served {
		ctrl.Log.Info("migrationplan controller not registered: CRD not served", "groupVersion", migrationv1.GroupVersion.String(),
			"resource", migration.Resource)
		return false, nil
	}
	r := &migration.Reconciler{
		Client:   mgr.GetClient(),
		Recorder: mgr.GetEventRecorderFor(telemetry.Component), //nolint:staticcheck // record.EventRecorder is what internal/status takes
	}
	if err := r.SetupWithManager(mgr); err != nil {
		return false, err
	}
	ctrl.Log.Info("migrationplan controller registered", "groupVersion", migrationv1.GroupVersion.String())
	return true, nil
}
