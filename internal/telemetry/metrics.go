package telemetry

// Reconcile metrics (T059; AD-50, contracts/reconciliation.md Rule 7, data-model.md §21): the
// reconcile result, latency and retry series of the provider's reconcilers, registered on
// controller-runtime's metrics registry — the one the manager's metrics endpoint (T042,
// METRICS_BIND_ADDRESS) serves. The Network reconciler (T059) and the Fabric reconciler (T040)
// both increment them. T133 extends this file with the queue, error and re-verification series
// and adds tracing beside it (tracing.go).
//
// Labels are bounded identity labels only (data-model.md §21): the controller name, the resource
// kind/namespace/name (bounded by the reference lab) and the closed value sets below. No path,
// error message or trace identifier is ever a label.
//
// The per-object series (T133; FR-107, AD-53, AD-54): reverify_last_success_timestamp_seconds —
// the one name for it (data-model.md §21), a timestamp, from which ReverificationStalled
// computes the age — mirrors status.lastVerifiedTime, which advances on every pass that RAN
// whatever it found and is left by a pass that could not run. It and
// agentic_netops_resource_reconcile_failed live exactly as long as the object is inside the
// read-back schedule: the reconcilers remove the re-verification series when finalization starts
// (ForgetReverification) and every per-object series once the object is gone (ForgetObject), so a
// deleting or deleted object never ages into ReverificationStalled.

import (
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
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

	// T133.
	MetricReverifyLastSuccess = "reverify_last_success_timestamp_seconds" // data-model.md §21: no prefix, the one name
	MetricReverifyTotal       = "agentic_netops_reverify_total"
	MetricReconcileErrors     = "agentic_netops_reconcile_errors_total"
	MetricResourceFailed      = "agentic_netops_resource_reconcile_failed"
	MetricReconcileRequeues   = "agentic_netops_reconcile_requeues_total"
	MetricReverifyInterval    = "agentic_netops_reverify_interval_seconds"
	MetricReconcileInterval   = "agentic_netops_reconcile_interval_seconds"
	MetricTelemetryHealthy    = "agentic_netops_telemetry_healthy"
)

// Resource kinds — the kind label's closed value set.
const (
	KindFabric  = "Fabric"
	KindNetwork = "Network"
)

// Re-verification results — agentic_netops_reverify_total's result label (FR-107, AD-54).
const (
	// ReverifyRan: the pass ran its read-back on both sides, whatever it found.
	ReverifyRan = "ran"
	// ReverifyCouldNotRun: the pass could not run (a target unreadable); lastVerifiedTime left.
	ReverifyCouldNotRun = "could_not_run"
)

// Requeue reasons — agentic_netops_reconcile_requeues_total's reason label (the queue series;
// controller-runtime's workqueue_* series are exported beside them).
const (
	RequeueInterval   = "interval"   // the reconciliation interval (converging, awaiting the layer)
	RequeueReverify   = "reverify"   // the re-verification schedule
	RequeueBackoff    = "backoff"    // a transient error's bounded backoff, or a write conflict
	RequeueDependency = "dependency" // a dependency wait
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

var (
	// ReverifyLastSuccess is the Unix time of status.lastVerifiedTime per object — the last pass
	// that ran to completion, whatever it found (data-model.md §21, AD-54).
	ReverifyLastSuccess = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: MetricReverifyLastSuccess,
		Help: "Unix time of status.lastVerifiedTime: the last re-verification pass that ran to completion, whatever it found (FR-107). Absent for a deleting or deleted object.",
	}, []string{"kind", "namespace", "name"})
	// ReverifyTotal counts re-verification passes by kind and result (ran, could_not_run).
	ReverifyTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: MetricReverifyTotal,
		Help: "Re-verification passes by kind and result (ran: the read-back ran, whatever it found; could_not_run).",
	}, []string{"kind", "result"})
	// ReconcileErrors counts reconciles that ended in an error class, by controller and class.
	ReconcileErrors = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: MetricReconcileErrors,
		Help: "Reconciles that ended in an error, by controller and class (transient, terminal, error).",
	}, []string{"controller", "class"})
	// ResourceFailed is 1 while the last reconcile of the object ended error or terminal.
	ResourceFailed = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: MetricResourceFailed,
		Help: "1 when the last reconcile of the object ended in an error or a terminal condition, 0 otherwise. Absent once the object is gone.",
	}, []string{"kind", "namespace", "name"})
	// ReconcileRequeues counts requeues by controller and reason.
	ReconcileRequeues = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: MetricReconcileRequeues,
		Help: "Requeues scheduled by the provider's reconcilers, by controller and reason (interval, reverify, backoff, dependency).",
	}, []string{"controller", "reason"})
	// ReverifyIntervalSeconds and ReconcileIntervalSeconds are the configured intervals
	// (data-model.md §25); the ReverificationStalled bound reads them.
	ReverifyIntervalSeconds = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: MetricReverifyInterval,
		Help: "The configured re-verification interval (REVERIFY_INTERVAL), in seconds.",
	})
	ReconcileIntervalSeconds = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: MetricReconcileInterval,
		Help: "The configured reconciliation interval (RECONCILE_INTERVAL), in seconds.",
	})
	// TelemetryHealthy is the telemetry-health input's current value (health.go).
	TelemetryHealthy = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: MetricTelemetryHealthy,
		Help: "1 while the provider's own telemetry export is healthy, 0 otherwise; never blocks configuration (Rule 9).",
	})
)

func init() {
	metrics.Registry.MustRegister(ReconcileTotal, ReconcileDuration, ReconcileRetries,
		ReverifyLastSuccess, ReverifyTotal, ReconcileErrors, ResourceFailed, ReconcileRequeues,
		ReverifyIntervalSeconds, ReconcileIntervalSeconds, TelemetryHealthy)
	TelemetryHealthy.Set(1)
}

// objects serializes the per-object series' set-and-remove so that a removal is never undone by
// a concurrent write of the same object's series (the reconcilers never run one object twice at
// once, but the Fabric and Network reconcilers share this registry).
var objects sync.Mutex

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

// ObserveErrorClass counts one reconcile of controller that ended in an error class; a result
// that is not one (success, wait) counts nothing.
func ObserveErrorClass(controller, result string) {
	switch result {
	case ResultTransient, ResultTerminal, ResultError:
		ReconcileErrors.WithLabelValues(controller, result).Inc()
	}
}

// ObserveRequeue counts one requeue of controller by reason; a reason outside the closed set is
// counted as interval, never as a new label value.
func ObserveRequeue(controller, reason string) {
	switch reason {
	case RequeueInterval, RequeueReverify, RequeueBackoff, RequeueDependency:
	default:
		reason = RequeueInterval
	}
	ReconcileRequeues.WithLabelValues(controller, reason).Inc()
}

// RequeueReason classifies a requeue from the reconcile's result class: a transient error's
// retry is backoff, a dependency wait is dependency, a requeue at the re-verification interval
// (or the scheduled pass's remainder, reverifyScheduled) is reverify, the rest interval.
func RequeueReason(result string, reverifyScheduled bool) string {
	switch {
	case result == ResultTransient:
		return RequeueBackoff
	case result == ResultWait:
		return RequeueDependency
	case reverifyScheduled:
		return RequeueReverify
	}
	return RequeueInterval
}

// SetIntervals publishes the configured re-verification and reconciliation intervals.
func SetIntervals(reverify, reconcile time.Duration) {
	ReverifyIntervalSeconds.Set(reverify.Seconds())
	ReconcileIntervalSeconds.Set(reconcile.Seconds())
}

// RecordReverification records one re-verification pass of the object: a pass that ran counts
// result=ran and advances the timestamp to lastVerified (status.lastVerifiedTime, which that pass
// set, whatever it found); a pass that could not run counts result=could_not_run and leaves the
// timestamp where it was (AD-54).
func RecordReverification(kind, namespace, name string, ran bool, lastVerified time.Time) {
	if !ran {
		ReverifyTotal.WithLabelValues(kind, ReverifyCouldNotRun).Inc()
		return
	}
	ReverifyTotal.WithLabelValues(kind, ReverifyRan).Inc()
	SyncLastVerified(kind, namespace, name, &lastVerified)
}

// SyncLastVerified sets the object's timestamp to lastVerified (status.lastVerifiedTime) when the
// object has one, so that the series is present — and ages — from the first reconcile after a
// provider restart, not only from the next pass that runs. A nil lastVerified (never verified)
// leaves the series as it is.
func SyncLastVerified(kind, namespace, name string, lastVerified *time.Time) {
	if lastVerified == nil || lastVerified.IsZero() {
		return
	}
	objects.Lock()
	defer objects.Unlock()
	ReverifyLastSuccess.WithLabelValues(kind, namespace, name).Set(float64(lastVerified.UnixNano()) / 1e9)
}

// SetReconcileFailed sets the object's agentic_netops_resource_reconcile_failed: 1 when the
// reconcile ended error or terminal, 0 otherwise.
func SetReconcileFailed(kind, namespace, name, result string) {
	v := 0.0
	if result == ResultError || result == ResultTerminal {
		v = 1
	}
	objects.Lock()
	defer objects.Unlock()
	ResourceFailed.WithLabelValues(kind, namespace, name).Set(v)
}

// ForgetReverification removes the object's re-verification timestamp: called when its
// finalization starts — from then on nothing is re-verified (AD-53) — so a held-in-deletion
// object never ages into ReverificationStalled (AD-54).
func ForgetReverification(kind, namespace, name string) {
	objects.Lock()
	defer objects.Unlock()
	ReverifyLastSuccess.DeleteLabelValues(kind, namespace, name)
}

// ForgetObject removes every per-object series of the object: called once it is gone (or, for a
// Fabric, which has no finalizer, once its deletion is seen).
func ForgetObject(kind, namespace, name string) {
	objects.Lock()
	defer objects.Unlock()
	ReverifyLastSuccess.DeleteLabelValues(kind, namespace, name)
	ResourceFailed.DeleteLabelValues(kind, namespace, name)
}

// LastVerifiedSeries reports the object's reverify_last_success_timestamp_seconds without
// creating it: its value and whether the series exists.
func LastVerifiedSeries(kind, namespace, name string) (float64, bool) {
	return gaugeValue(ReverifyLastSuccess, kind, namespace, name)
}

// ReconcileFailedSeries reports the object's agentic_netops_resource_reconcile_failed without
// creating it.
func ReconcileFailedSeries(kind, namespace, name string) (float64, bool) {
	return gaugeValue(ResourceFailed, kind, namespace, name)
}

func gaugeValue(v *prometheus.GaugeVec, kind, namespace, name string) (float64, bool) {
	ch := make(chan prometheus.Metric, 64)
	go func() { v.Collect(ch); close(ch) }()
	var (
		val   float64
		found bool
	)
	for m := range ch {
		var d dto.Metric
		if err := m.Write(&d); err != nil {
			continue
		}
		l := map[string]string{}
		for _, lp := range d.GetLabel() {
			l[lp.GetName()] = lp.GetValue()
		}
		if l["kind"] == kind && l["namespace"] == namespace && l["name"] == name {
			val, found = d.GetGauge().GetValue(), true
		}
	}
	return val, found
}
