package telemetry

// Reconcile metrics (T059; AD-50, contracts/reconciliation.md Rule 7, data-model.md §21): the
// reconcile result, latency and retry series of the provider's reconcilers, registered on
// controller-runtime's metrics registry — the one the manager's metrics endpoint (T042,
// METRICS_BIND_ADDRESS) serves. The Network reconciler (T059) and the Fabric reconciler (T040)
// both increment them. T133 extends this file with the queue, error and re-verification series
// and adds tracing beside it.
//
// Labels are bounded identity labels only (data-model.md §21): the controller name and the
// closed result set below. No object name, path, error message or trace identifier is ever a
// label.

import (
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

// Controller names — the controller label's closed value set.
const (
	ControllerFabric  = "fabric"
	ControllerNetwork = "network"
)

// Reconcile results — the result label's closed value set (Rule 7's classes).
const (
	// ResultSuccess: the pass completed; the object is converged or converging and was requeued
	// by the schedule or the reconciliation interval.
	ResultSuccess = "success"
	// ResultWait: a dependency wait (a dependency absent or not Ready, a claim unbound, an
	// authority that answered nothing yet); nothing was written to a device.
	ResultWait = "wait"
	// ResultTransient: a transient error retried with bounded backoff.
	ResultTransient = "transient"
	// ResultTerminal: a terminal error (schema, mapping, ownership, allocation conflict, …)
	// that waits for a new generation or a dependency change.
	ResultTerminal = "terminal"
	// ResultError: the reconcile returned an error to the manager.
	ResultError = "error"
)

// Metric names.
const (
	MetricReconcileTotal    = "agentic_netops_reconcile_total"
	MetricReconcileDuration = "agentic_netops_reconcile_duration_seconds"
	MetricReconcileRetries  = "agentic_netops_reconcile_retries_total"
)

var (
	// ReconcileTotal counts reconciles by controller and result.
	ReconcileTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: MetricReconcileTotal,
		Help: "Reconciles of the provider's reconcilers, by controller and result (success, wait, transient, terminal, error).",
	}, []string{"controller", "result"})
	// ReconcileDuration is the reconcile latency by controller.
	ReconcileDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    MetricReconcileDuration,
		Help:    "Latency of one reconcile of the provider's reconcilers, by controller.",
		Buckets: prometheus.ExponentialBuckets(0.005, 2, 14),
	}, []string{"controller"})
	// ReconcileRetries counts transient-error retries (bounded backoff) by controller.
	ReconcileRetries = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: MetricReconcileRetries,
		Help: "Transient-error retries scheduled with bounded exponential backoff, by controller.",
	}, []string{"controller"})
)

func init() {
	metrics.Registry.MustRegister(ReconcileTotal, ReconcileDuration, ReconcileRetries)
}

// ObserveReconcile records one reconcile of controller: its result and its latency.
func ObserveReconcile(controller, result string, d time.Duration) {
	switch result {
	case ResultSuccess, ResultWait, ResultTransient, ResultTerminal, ResultError:
	default:
		// A result outside the closed set is recorded as an error, never as a new label value.
		result = ResultError
	}
	ReconcileTotal.WithLabelValues(controller, result).Inc()
	ReconcileDuration.WithLabelValues(controller).Observe(d.Seconds())
}

// ObserveRetry records one transient-error retry of controller.
func ObserveRetry(controller string) {
	ReconcileRetries.WithLabelValues(controller).Inc()
}
