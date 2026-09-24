package main

// The Network reconciler's wiring (T059): the reconciler of controllers/network with the
// provider's only renderer (internal/render/srl), the service read-back of internal/verify
// (T058) over the same readers the Fabric's read-back uses — the running datastore through the
// device-configuration layer, the state datastore through the device metric collector — the
// telemetry-health input, the allocation authority chosen by the lock file (pkg/kuid) and the
// §25 settings the Fabric reconciler is given. The Network watch is cluster-wide: the manager
// cache carries no ByObject restriction for Network (NETWORK_WATCH_SCOPE=cluster, R-15).

import (
	"errors"
	"math/rand/v2"

	"k8s.io/utils/clock"
	ctrl "sigs.k8s.io/controller-runtime"

	"github.com/mairp/agentic-netops-srl/controllers/network"
	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/render/srl"
	"github.com/mairp/agentic-netops-srl/internal/telemetry"
	"github.com/mairp/agentic-netops-srl/internal/verify"
)

// setupNetwork registers the Network reconciler (T059).
func setupNetwork(mgr ctrl.Manager, deps providerDeps) error {
	if deps.SDC == nil || deps.Claims == nil || deps.Compat == nil {
		return errors.New("network reconciler: the device-configuration client, the allocation authority and the compatibility set are required")
	}
	st := network.DefaultSettings()
	st.Settings = deps.Settings.Fabric
	reader := stateReader(deps.Settings, &verify.LayerReader{Client: deps.APIReader})
	r := &network.Reconciler{
		Client:   mgr.GetClient(),
		SDC:      deps.SDC,
		Claims:   deps.Claims,
		Renderer: srlServiceRenderer{},
		// T058's read-back: the running datastore through the layer, the state datastore
		// through the device metric collector (DEVICE_METRICS_URL) — never a device session.
		Verifier: &verify.Service{
			Reader:  reader,
			Configs: deps.SDC,
			Timeout: deps.Settings.VerifyTimeout,
		},
		Telemetry: telemetry.UnwiredHealth{},
		Compat:    deps.Compat,
		Recorder:  mgr.GetEventRecorderFor(telemetry.Component), //nolint:staticcheck // record.EventRecorder is what internal/status takes
		Clock:     clock.RealClock{},
		Settings:  st,
		Jitter:    rand.Float64,
	}
	// The finalizer's data-path reachability probe (FR-103): the collector's sample freshness,
	// when the state datastore is read through it.
	if cr, ok := reader.(*verify.CollectorReader); ok {
		r.Reachability = cr
	}
	return r.SetupWithManager(mgr)
}

// srlServiceRenderer adapts internal/render/srl's service entry point to the Network
// reconciler's Renderer input. An *srl.UnsupportedError (access-list rendering, User Story 5)
// is returned as it is: the reconciler reports it Rendered=False/MappingFailed.
type srlServiceRenderer struct{}

func (srlServiceRenderer) RenderService(m *model.ServiceModel) (map[string]network.Rendered, error) {
	docs, err := srl.RenderService(m)
	if err != nil {
		return nil, err
	}
	out := make(map[string]network.Rendered, len(docs))
	for node, d := range docs {
		out[node] = network.Rendered{Node: d.Node, JSON: d.JSON, Hash: d.Hash}
	}
	return out, nil
}
