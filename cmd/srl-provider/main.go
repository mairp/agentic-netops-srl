// Command srl-provider is the SR Linux provider (T042; plan.md C-05): one
// binary running the Fabric reconciler (controllers/fabric) — and, with later
// tasks, the Network reconciler and the admission webhook — under a
// controller-runtime manager with leader election, a Prometheus metrics
// endpoint, health probes, optional OTLP trace export and NFR-014 JSON logs.
//
// Start-up refuses, naming the variable, on a DRIFT_POLICY other than the
// exact string "revertive" and on a REVERIFY_INTERVAL below the 30 s floor or
// unparseable (config.go) — before anything connects to the cluster.
//
// SRL_PROVIDER_ROLE selects what the process runs: "provider" (the default) is
// the above, its allocation authority chosen by versions.lock.yaml's
// allocationAuthority.kind through pkg/kuid.New and nothing else;
// "allocation-authority" hosts the first-party allocation authority's pool and
// claim controllers (controllers/allocation, T176) and nothing else, and refuses
// to start unless the lock selects first-party (allocation.go).
//
// The provider also hosts the optional MigrationPlan controller (controllers/migration, T122),
// registered only when the MigrationPlan CRD is served (migration.go).
package main

import (
	"context"
	"fmt"
	"io"
	"math/rand/v2"
	"os"

	"github.com/go-logr/logr"
	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	invv1alpha1 "github.com/sdcio/config-server/apis/inv/v1alpha1"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/discovery"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/utils/clock"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	migrationv1 "github.com/mairp/agentic-netops-srl/api/v1alpha1"
	"github.com/mairp/agentic-netops-srl/controllers/fabric"
	"github.com/mairp/agentic-netops-srl/internal/compat"
	"github.com/mairp/agentic-netops-srl/internal/telemetry"
	"github.com/mairp/agentic-netops-srl/internal/verify"
	"github.com/mairp/agentic-netops-srl/pkg/kuid"
	"github.com/mairp/agentic-netops-srl/pkg/sdc"
)

func main() {
	ctx := ctrl.SetupSignalHandler()
	if err := run(ctx, os.LookupEnv, os.Stdout); err != nil {
		telemetry.NewLogger(os.Stdout, telemetry.Component, false, nil).Error(err, "srl-provider refused to start or stopped")
		os.Exit(1)
	}
}

// run starts the provider. Settings are parsed first: a refused setting
// returns before any cluster connection.
func run(ctx context.Context, lookup func(string) (string, bool), out io.Writer) error {
	s, err := loadSettings(lookup)
	if err != nil {
		return fmt.Errorf("refusing to start: %w", err)
	}
	log := telemetry.NewLogger(out, telemetry.Component, s.Debug, nil)
	ctrl.SetLogger(log)

	set, err := compat.Load(s.CompatLockFile)
	if err != nil {
		return fmt.Errorf("refusing to start: %s: %w", EnvCompatLockFile, err)
	}
	allocation, err := registersAllocation(s.Role, set.AuthorityKind())
	if err != nil {
		return fmt.Errorf("refusing to start: %w", err)
	}
	if allocation {
		return runAllocationAuthority(ctx, s, set)
	}

	// The configured intervals, which the ReverificationStalled bound reads (T133, FR-107).
	telemetry.SetIntervals(s.Fabric.ReverifyInterval, s.Fabric.ReconcileInterval)
	health, shutdown, err := setupOTLP(ctx, s.OTLPEndpoint, log)
	if err != nil {
		return fmt.Errorf("refusing to start: %s: %w", EnvOTLPEndpoint, err)
	}
	defer func() { _ = shutdown(context.Background()) }()

	scheme := runtime.NewScheme()
	// migrationv1: the optional MigrationPlan, whose controller registers only when its CRD is
	// served (migration.go).
	adds := []func(*runtime.Scheme) error{clientgoscheme.AddToScheme, fabricv1.AddToScheme, migrationv1.AddToScheme, sdc.AddToScheme}
	if set.AuthorityKind() == kuid.AuthorityKuid {
		// The upstream claim types only where kuid is the authority; the first-party
		// kinds are in fabricv1.
		adds = append(adds, kuid.AddToScheme)
	}
	for _, add := range adds {
		if err := add(scheme); err != nil {
			return err
		}
	}
	cfg, err := ctrl.GetConfig()
	if err != nil {
		return fmt.Errorf("cluster config: %w", err)
	}
	ns := func(n string) map[string]cache.Config { return map[string]cache.Config{n: {}} }
	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:                  scheme,
		Metrics:                 metricsserver.Options{BindAddress: s.MetricsAddr},
		HealthProbeBindAddress:  s.ProbeAddr,
		LeaderElection:          s.LeaderElect,
		LeaderElectionID:        LeaderElectionID,
		LeaderElectionNamespace: s.LeaderElectionNS,
		Cache: cache.Options{ByObject: map[client.Object]cache.ByObject{
			// Least privilege: each kind is cached only where it lives. The
			// Network watch is cluster-wide by design (NETWORK_WATCH_SCOPE, R-15).
			&fabricv1.Fabric{}:          {Namespaces: ns(sdc.SystemNamespace)},
			&configv1alpha1.Config{}:    {Namespaces: ns(sdc.SystemNamespace)},
			&configv1alpha1.Deviation{}: {Namespaces: ns(sdc.SystemNamespace)},
			&configv1alpha1.Target{}:    {Namespaces: ns(s.Fabric.TargetNamespace)},
			&invv1alpha1.Schema{}:       {Namespaces: ns(s.Fabric.SchemaNamespace)},
		}},
	})
	if err != nil {
		return fmt.Errorf("manager: %w", err)
	}
	// Claims are read and written uncached, in the authority's namespace only
	// (kuid's are an aggregated API).
	direct, err := client.New(cfg, client.Options{Scheme: scheme})
	if err != nil {
		return fmt.Errorf("allocation client: %w", err)
	}
	claims, err := kuid.New(set.AuthorityKind(), direct)
	if err != nil {
		return fmt.Errorf("refusing to start: %w", err)
	}
	sdcClient := sdc.New(mgr.GetClient())
	r := &fabric.Reconciler{
		Client:   mgr.GetClient(),
		SDC:      sdcClient,
		Claims:   claims,
		Renderer: srlRenderer{},
		// T041's read-back, wired here: the running datastore through the
		// device-configuration layer, the state datastore through the device
		// metric collector (DEVICE_METRICS_URL) — never a device session.
		Verifier: &verify.Fabric{
			Reader:  stateReader(s, &verify.LayerReader{Client: mgr.GetAPIReader()}),
			Configs: sdcClient,
			Timeout: s.VerifyTimeout,
		},
		// The telemetry-health input (T133, AD-62): the provider's own OTLP export — the only
		// thing Degraded=True/TelemetryUnavailable is set from; it never blocks configuration.
		Telemetry: health,
		Compat:    set,
		Recorder:  mgr.GetEventRecorderFor(telemetry.Component), //nolint:staticcheck // record.EventRecorder is what internal/status takes
		Clock:     clock.RealClock{},
		Settings:  s.Fabric,
		Jitter:    rand.Float64,
	}
	if err := r.SetupWithManager(mgr); err != nil {
		return fmt.Errorf("fabric reconciler: %w", err)
	}
	deps := providerDeps{Settings: s, Compat: set, SDC: sdcClient, Claims: claims, APIReader: mgr.GetAPIReader(), Health: health}
	if err := setupNetwork(mgr, deps); err != nil {
		return fmt.Errorf("network reconciler: %w", err)
	}
	disco, err := discovery.NewDiscoveryClientForConfig(cfg)
	if err != nil {
		return fmt.Errorf("discovery client: %w", err)
	}
	if _, err := setupMigration(mgr, disco); err != nil {
		return fmt.Errorf("migrationplan controller: %w", err)
	}
	if err := setupWebhook(mgr, lookup); err != nil {
		return fmt.Errorf("network webhook: %w", err)
	}
	if err := mgr.Add(manager.RunnableFunc(func(ctx context.Context) error {
		return publishCompatibility(ctx, direct, set)
	})); err != nil {
		return err
	}
	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		return err
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		return err
	}
	log.Info("srl-provider starting", "driftPolicy", s.DriftPolicy, "reverifyInterval", s.Fabric.ReverifyInterval.String(),
		"reconcileInterval", s.Fabric.ReconcileInterval.String(), "networkWatchScope", s.NetworkWatchScope,
		"compatibilitySet", set.Identifier(), "allocationAuthority", claims.Authority())
	return mgr.Start(ctx)
}

// providerDeps are what the provider's reconcilers share, built once in run.
type providerDeps struct {
	Settings  settings
	Compat    *compat.Set
	SDC       *sdc.Client
	Claims    kuid.Claims
	APIReader client.Reader
	// Health is the telemetry-health input both reconcilers are given (T133).
	Health *telemetry.ExportHealth
}

// setupOTLP installs an OTLP/gRPC trace exporter when an endpoint is set — the provider's own
// OTLP, direct to the collector (data-model.md §21) — and returns the telemetry-health input
// over it (T133): the exporter is wrapped so that every export's outcome is recorded, and the
// health is the OpenTelemetry error handler. With no endpoint tracing stays the no-op provider
// and the health reports "OTLP export not configured". The exporter connects lazily and exports
// from the batch processor's own goroutine, dropping spans when its queue is full: an absent or
// refusing collector never delays a reconcile — it only turns the health unhealthy (Rule 9).
func setupOTLP(ctx context.Context, endpoint string, log logr.Logger) (*telemetry.ExportHealth, func(context.Context) error, error) {
	health := telemetry.NewExportHealth(endpoint, log)
	if endpoint == "" {
		return health, func(context.Context) error { return nil }, nil
	}
	exp, err := otlptracegrpc.New(ctx, otlptracegrpc.WithEndpointURL(endpoint))
	if err != nil {
		return nil, nil, err
	}
	otel.SetErrorHandler(health)
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(health.WrapExporter(exp)),
		sdktrace.WithResource(resource.NewSchemaless(attribute.String("service.name", telemetry.Component))),
	)
	otel.SetTracerProvider(tp)
	return health, tp.Shutdown, nil
}

// stateReader is the read-back's StateReader: the running datastore always
// through the device-configuration layer; the state datastore through the
// device metric collector when DEVICE_METRICS_URL names it (AD-82 decision
// 2026-09-21-state-source) — else the layer's, which serves none, so every
// pass could not run (never a pass that passed on the running datastore).
func stateReader(s settings, layer *verify.LayerReader) verify.StateReader {
	if s.DeviceMetricsURL == "" {
		return layer
	}
	return &verify.CollectorReader{Layer: layer, URL: s.DeviceMetricsURL}
}
