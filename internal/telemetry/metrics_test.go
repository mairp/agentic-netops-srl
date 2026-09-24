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
