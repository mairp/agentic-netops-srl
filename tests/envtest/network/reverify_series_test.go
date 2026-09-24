//go:build envtest

// T133: the re-verification series of the Network reconciler (data-model.md §21; FR-107, AD-53,
// AD-54). reverify_last_success_timestamp_seconds{kind,namespace,name} — the one name for it —
// mirrors status.lastVerifiedTime: it advances on every pass that ran, whatever it found, and a
// pass that could not run leaves it; it is removed when finalization starts and is therefore
// ABSENT for a deleting object and ABSENT for a deleted object, so neither ages into
// ReverificationStalled. The reconciler is driven by direct Reconcile calls under the fake clock
// (the suite's harness); the series is read from the controller-runtime registry without being
// created (telemetry.LastVerifiedSeries).
package network_test

import (
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/mairp/agentic-netops-srl/internal/telemetry"
)

// seriesAt fails unless the object's timestamp series is present at want.
func seriesAt(h *harness, want time.Time) {
	h.t.Helper()
	v, ok := telemetry.LastVerifiedSeries(telemetry.KindNetwork, h.ns, h.name)
	if !ok {
		h.t.Fatalf("%s/%s: no %s series", h.ns, h.name, telemetry.MetricReverifyLastSuccess)
	}
	if v != float64(want.Unix()) {
		h.t.Fatalf("%s/%s: %s = %v, want %d (%s)", h.ns, h.name, telemetry.MetricReverifyLastSuccess, v, want.Unix(), want)
	}
	if lv := h.network().Status.LastVerifiedTime; lv == nil || !lv.Time.Equal(want) {
		h.t.Fatalf("%s/%s: lastVerifiedTime %v, want %s — the series must mirror it", h.ns, h.name, lv, want)
	}
}

// seriesAbsent fails while the object has a timestamp series.
func seriesAbsent(h *harness, what string) {
	h.t.Helper()
	if v, ok := telemetry.LastVerifiedSeries(telemetry.KindNetwork, h.ns, h.name); ok {
		h.t.Fatalf("%s/%s (%s): %s present (%v); it must be absent", h.ns, h.name, what, telemetry.MetricReverifyLastSuccess, v)
	}
}

func reverifyCount(result string) float64 {
	return testutil.ToFloat64(telemetry.ReverifyTotal.WithLabelValues(telemetry.KindNetwork, result))
}

// The series advances on a pass that ran and found an invariant missing, and is frozen by a pass
// that could not run; agentic_netops_reverify_total counts both by result.
func TestReverifySeriesAdvancesOnRanAndFreezesOnCouldNotRun(t *testing.T) {
	h := newHarness(t, nsServices, "svc-series")
	h.converge(macvrfSpec(731, 10731, att("leaf01", "ethernet-1/1", 731), att("leaf02", "ethernet-1/1", 731)))
	seriesAt(h, t0)
	if v, ok := telemetry.ReconcileFailedSeries(telemetry.KindNetwork, h.ns, h.name); !ok || v != 0 {
		t.Fatalf("resource_reconcile_failed of a Ready Network: %v (present %v), want 0", v, ok)
	}
	ran0, cnr0 := reverifyCount(telemetry.ReverifyRan), reverifyCount(telemetry.ReverifyCouldNotRun)

	// A pass that ran and found an invariant missing: advances.
	h.verify.set("leaf01", "missing")
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionFalse, "RoutesMissing")
	seriesAt(h, t0.Add(5*time.Minute))
	if got := reverifyCount(telemetry.ReverifyRan); got != ran0+1 {
		t.Fatalf("reverify_total{ran} %v, want %v", got, ran0+1)
	}

	// Back to Ready at the next pass (it ran: advances again).
	h.verify.set("leaf01", "")
	h.clock.Step(15 * time.Second)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	last := t0.Add(5*time.Minute + 15*time.Second)
	seriesAt(h, last)

	// Passes that could not run: frozen, counted could_not_run.
	h.verify.set("leaf02", "cannot")
	for i := 0; i < 2; i++ {
		h.clock.Step(5 * time.Minute)
		h.reconcile()
		h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed")
		seriesAt(h, last)
	}
	if got := reverifyCount(telemetry.ReverifyCouldNotRun); got < cnr0+2 {
		t.Fatalf("reverify_total{could_not_run} %v, want at least %v", got, cnr0+2)
	}
	if got := reverifyCount(telemetry.ReverifyRan); got != ran0+2 {
		t.Fatalf("a pass that could not run counted as ran: %v, want %v", got, ran0+2)
	}
}

// ABSENT for a deleting object: the series goes at the first reconcile that sees the deletion
// timestamp — finalization start — and stays absent while the deletion is held, through any
// number of re-verification intervals.
func TestReverifySeriesAbsentForDeletingNetwork(t *testing.T) {
	h := newHarness(t, nsServices, "svc-series-deleting")
	h.converge(macvrfSpec(732, 10732, att("leaf01", "ethernet-1/1", 732), att("leaf02", "ethernet-1/1", 732)))
	seriesAt(h, t0)
	holdConfig(t, h.name+".leaf02")
	h.delete()

	delStep(h)
	if h.gone() {
		t.Fatal("the held deletion completed")
	}
	seriesAbsent(h, "deleting")
	for i := 0; i < 3; i++ {
		h.clock.Step(h.r.Settings.ReverifyInterval)
		delStep(h)
		seriesAbsent(h, "deleting, held")
	}
	releaseConfig(t, h.name+".leaf02")
	delStep(h)
	if !h.gone() {
		t.Fatalf("the Network is still there after its removal was read back: %+v", h.cond("Deleting"))
	}
	seriesAbsent(h, "deleted")
}

// ABSENT for a deleted object: once the Network is gone, its timestamp and failed-reconcile
// series are gone, and a reconcile of the absent object creates neither.
func TestReverifySeriesAbsentForDeletedNetwork(t *testing.T) {
	h := newHarness(t, nsServices, "svc-series-deleted")
	h.converge(macvrfSpec(733, 10733, att("leaf01", "ethernet-1/1", 733), att("leaf02", "ethernet-1/1", 733)))
	seriesAt(h, t0)
	h.delete()
	for i := 0; i < 5 && !h.gone(); i++ {
		delStep(h)
		h.clock.Step(h.r.Settings.ReconcileInterval)
	}
	if !h.gone() {
		t.Fatalf("the Network was not removed: %+v", h.cond("Deleting"))
	}
	seriesAbsent(h, "deleted")
	if _, ok := telemetry.ReconcileFailedSeries(telemetry.KindNetwork, h.ns, h.name); ok {
		t.Fatal("resource_reconcile_failed present for a deleted Network")
	}
	// The watch's reconcile of the absent object (NotFound) creates nothing.
	h.reconcile()
	seriesAbsent(h, "deleted, reconciled again")
	if _, ok := telemetry.ReconcileFailedSeries(telemetry.KindNetwork, h.ns, h.name); ok {
		t.Fatal("a reconcile of the absent Network recreated resource_reconcile_failed")
	}
}
