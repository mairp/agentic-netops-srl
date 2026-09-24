package telemetry

import (
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

// The reconcile result, latency and retry series are registered on the manager's registry and
// move by exactly what the reconcilers record (T059, AD-50).
func TestReconcileSeriesAreRegisteredAndCount(t *testing.T) {
	ObserveReconcile(ControllerNetwork, ResultSuccess, 20*time.Millisecond)
	ObserveRetry(ControllerNetwork)
	mfs, err := metrics.Registry.Gather()
	if err != nil {
		t.Fatal(err)
	}
	have := map[string]bool{}
	for _, mf := range mfs {
		have[mf.GetName()] = true
	}
	for _, n := range []string{MetricReconcileTotal, MetricReconcileDuration, MetricReconcileRetries} {
		if !have[n] {
			t.Errorf("%s is not registered on the controller-runtime metrics registry", n)
		}
	}

	before := testutil.ToFloat64(ReconcileTotal.WithLabelValues(ControllerFabric, ResultTerminal))
	ObserveReconcile(ControllerFabric, ResultTerminal, time.Millisecond)
	ObserveReconcile(ControllerFabric, ResultTerminal, time.Millisecond)
	if got := testutil.ToFloat64(ReconcileTotal.WithLabelValues(ControllerFabric, ResultTerminal)); got != before+2 {
		t.Errorf("reconcile_total{fabric,terminal} = %v, want %v", got, before+2)
	}
	r0 := testutil.ToFloat64(ReconcileRetries.WithLabelValues(ControllerFabric))
	ObserveRetry(ControllerFabric)
	if got := testutil.ToFloat64(ReconcileRetries.WithLabelValues(ControllerFabric)); got != r0+1 {
		t.Errorf("retries_total{fabric} = %v, want %v", got, r0+1)
	}
	if n := testutil.CollectAndCount(ReconcileDuration, MetricReconcileDuration); n < 2 {
		t.Errorf("duration histogram has %d series, want one per controller observed", n)
	}
}

// A result outside the closed set never becomes a new label value (bounded labels, §21).
func TestUnknownResultIsRecordedAsError(t *testing.T) {
	before := testutil.ToFloat64(ReconcileTotal.WithLabelValues(ControllerNetwork, ResultError))
	ObserveReconcile(ControllerNetwork, "something-else", time.Millisecond)
	if got := testutil.ToFloat64(ReconcileTotal.WithLabelValues(ControllerNetwork, ResultError)); got != before+1 {
		t.Errorf("an unknown result was not recorded as error: %v -> %v", before, got)
	}
	mfs, err := metrics.Registry.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, mf := range mfs {
		for _, m := range mf.GetMetric() {
			for _, l := range m.GetLabel() {
				if l.GetValue() == "something-else" {
					t.Errorf("%s: an unbounded result value became a label", mf.GetName())
				}
			}
		}
	}
}

// The T133 series are registered on the manager's registry under exactly the names of the brief
// and data-model.md §21 — reverify_last_success_timestamp_seconds with no prefix, the one name.
func TestT133SeriesRegistered(t *testing.T) {
	SetIntervals(5*time.Minute, 15*time.Second)
	RecordReverification(KindNetwork, "ns", "reg", true, time.Unix(1000, 0))
	SetReconcileFailed(KindNetwork, "ns", "reg", ResultSuccess)
	ObserveErrorClass(ControllerNetwork, ResultTerminal)
	ObserveRequeue(ControllerNetwork, RequeueReverify)
	t.Cleanup(func() { ForgetObject(KindNetwork, "ns", "reg") })
	mfs, err := metrics.Registry.Gather()
	if err != nil {
		t.Fatal(err)
	}
	have := map[string]bool{}
	for _, mf := range mfs {
		have[mf.GetName()] = true
	}
	for _, n := range []string{"reverify_last_success_timestamp_seconds", "agentic_netops_reverify_total",
		"agentic_netops_reconcile_errors_total", "agentic_netops_resource_reconcile_failed",
		"agentic_netops_reconcile_requeues_total", "agentic_netops_reverify_interval_seconds",
		"agentic_netops_reconcile_interval_seconds", "agentic_netops_telemetry_healthy"} {
		if !have[n] {
			t.Errorf("%s is not registered", n)
		}
	}
	if got := testutil.ToFloat64(ReverifyIntervalSeconds); got != 300 {
		t.Errorf("reverify interval %v, want 300", got)
	}
	if got := testutil.ToFloat64(ReconcileIntervalSeconds); got != 15 {
		t.Errorf("reconcile interval %v, want 15", got)
	}
}

// A pass that ran advances the timestamp to lastVerifiedTime whatever it found and counts
// result=ran; a pass that could not run counts could_not_run and leaves the timestamp (AD-54).
func TestReverificationSeriesAdvancesOnlyOnAPassThatRan(t *testing.T) {
	const ns, name = "unit", "svc-reverify"
	t.Cleanup(func() { ForgetObject(KindNetwork, ns, name) })
	ran0 := testutil.ToFloat64(ReverifyTotal.WithLabelValues(KindNetwork, ReverifyRan))
	cnr0 := testutil.ToFloat64(ReverifyTotal.WithLabelValues(KindNetwork, ReverifyCouldNotRun))

	t1 := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	RecordReverification(KindNetwork, ns, name, true, t1)
	if v, ok := LastVerifiedSeries(KindNetwork, ns, name); !ok || v != float64(t1.Unix()) {
		t.Fatalf("after a pass that ran: %v (present %v), want %d", v, ok, t1.Unix())
	}
	// The next pass ran and found an invariant missing: it still advances.
	t2 := t1.Add(5 * time.Minute)
	RecordReverification(KindNetwork, ns, name, true, t2)
	if v, _ := LastVerifiedSeries(KindNetwork, ns, name); v != float64(t2.Unix()) {
		t.Fatalf("a pass that ran and found something missing must advance: %v", v)
	}
	// A pass that could not run leaves it.
	RecordReverification(KindNetwork, ns, name, false, t2.Add(5*time.Minute))
	if v, _ := LastVerifiedSeries(KindNetwork, ns, name); v != float64(t2.Unix()) {
		t.Fatalf("a pass that could not run moved the timestamp: %v", v)
	}
	if got := testutil.ToFloat64(ReverifyTotal.WithLabelValues(KindNetwork, ReverifyRan)); got != ran0+2 {
		t.Errorf("reverify_total{ran} = %v, want %v", got, ran0+2)
	}
	if got := testutil.ToFloat64(ReverifyTotal.WithLabelValues(KindNetwork, ReverifyCouldNotRun)); got != cnr0+1 {
		t.Errorf("reverify_total{could_not_run} = %v, want %v", got, cnr0+1)
	}
}

// Absent for a deleting object: finalization start removes the timestamp (the failed-reconcile
// series stays with the finalizer); absent for a deleted object: every per-object series goes
// (data-model.md §21, AD-53, AD-54).
func TestReverificationSeriesAbsentForDeletingAndDeletedObject(t *testing.T) {
	const ns, name = "unit", "svc-deleting"
	RecordReverification(KindNetwork, ns, name, true, time.Unix(2000, 0))
	SetReconcileFailed(KindNetwork, ns, name, ResultTerminal)
	if v, ok := ReconcileFailedSeries(KindNetwork, ns, name); !ok || v != 1 {
		t.Fatalf("resource_reconcile_failed after a terminal reconcile: %v (present %v), want 1", v, ok)
	}

	ForgetReverification(KindNetwork, ns, name) // finalization starts
	if _, ok := LastVerifiedSeries(KindNetwork, ns, name); ok {
		t.Fatal("reverify_last_success_timestamp_seconds present for a deleting object")
	}
	ForgetObject(KindNetwork, ns, name) // the object is gone
	if _, ok := LastVerifiedSeries(KindNetwork, ns, name); ok {
		t.Fatal("reverify_last_success_timestamp_seconds present for a deleted object")
	}
	if _, ok := ReconcileFailedSeries(KindNetwork, ns, name); ok {
		t.Fatal("resource_reconcile_failed present for a deleted object")
	}
	// A deleted object that never had a series stays absent (Forget is idempotent).
	ForgetObject(KindFabric, "sdc-system", "never")
	if _, ok := LastVerifiedSeries(KindFabric, "sdc-system", "never"); ok {
		t.Fatal("a series appeared for an object never verified")
	}
}

// resource_reconcile_failed is 1 only for error and terminal; the requeue reason and the error
// class stay in their closed sets.
func TestReconcileFailedAndClosedSets(t *testing.T) {
	const ns, name = "unit", "svc-failed"
	t.Cleanup(func() { ForgetObject(KindNetwork, ns, name) })
	for res, want := range map[string]float64{ResultSuccess: 0, ResultWait: 0, ResultTransient: 0, ResultTerminal: 1, ResultError: 1} {
		SetReconcileFailed(KindNetwork, ns, name, res)
		if v, _ := ReconcileFailedSeries(KindNetwork, ns, name); v != want {
			t.Errorf("%s: resource_reconcile_failed = %v, want %v", res, v, want)
		}
	}
	e0 := testutil.ToFloat64(ReconcileErrors.WithLabelValues(ControllerFabric, ResultTransient))
	ObserveErrorClass(ControllerFabric, ResultTransient)
	ObserveErrorClass(ControllerFabric, ResultSuccess)
	ObserveErrorClass(ControllerFabric, ResultWait)
	if got := testutil.ToFloat64(ReconcileErrors.WithLabelValues(ControllerFabric, ResultTransient)); got != e0+1 {
		t.Errorf("errors_total{transient} = %v, want %v", got, e0+1)
	}
	for _, tc := range []struct {
		result   string
		reverify bool
		want     string
	}{
		{ResultTransient, false, RequeueBackoff}, {ResultWait, false, RequeueDependency},
		{ResultSuccess, true, RequeueReverify}, {ResultSuccess, false, RequeueInterval},
	} {
		if got := RequeueReason(tc.result, tc.reverify); got != tc.want {
			t.Errorf("RequeueReason(%s,%v) = %s, want %s", tc.result, tc.reverify, got, tc.want)
		}
	}
	i0 := testutil.ToFloat64(ReconcileRequeues.WithLabelValues(ControllerFabric, RequeueInterval))
	ObserveRequeue(ControllerFabric, "made-up")
	if got := testutil.ToFloat64(ReconcileRequeues.WithLabelValues(ControllerFabric, RequeueInterval)); got != i0+1 {
		t.Errorf("an unknown reason was not counted as interval")
	}
}
