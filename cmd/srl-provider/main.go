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
package main

import (
	"context"
	"fmt"
	"io"
	"math/rand/v2"
	"os"

	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	invv1alpha1 "github.com/sdcio/config-server/apis/inv/v1alpha1"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/utils/clock"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
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

	shutdown, err := setupOTLP(ctx, s.OTLPEndpoint)
	if err != nil {
		return fmt.Errorf("refusing to start: %s: %w", EnvOTLPEndpoint, err)
	}
	defer func() { _ = shutdown(context.Background()) }()

	scheme := runtime.NewScheme()
	adds := []func(*runtime.Scheme) error{clientgoscheme.AddToScheme, fabricv1.AddToScheme, sdc.AddToScheme}
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
		Telemetry: telemetry.UnwiredHealth{},
		Compat:    set,
		Recorder:  mgr.GetEventRecorderFor(telemetry.Component), //nolint:staticcheck // record.EventRecorder is what internal/status takes
		Clock:     clock.RealClock{},
		Settings:  s.Fabric,
		Jitter:    rand.Float64,
	}
	if err := r.SetupWithManager(mgr); err != nil {
		return fmt.Errorf("fabric reconciler: %w", err)
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

// setupOTLP installs an OTLP/gRPC trace exporter when an endpoint is set; with
// none, tracing stays the no-op provider. T133 adds the spans (tracing.go).
func setupOTLP(ctx context.Context, endpoint string) (func(context.Context) error, error) {
	if endpoint == "" {
		return func(context.Context) error { return nil }, nil
	}
	exp, err := otlptracegrpc.New(ctx, otlptracegrpc.WithEndpointURL(endpoint))
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(exp))
	otel.SetTracerProvider(tp)
	return tp.Shutdown, nil
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
