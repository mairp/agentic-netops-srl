//go:build envtest

// T133: the re-verification series of the Fabric reconciler (data-model.md §21; FR-107, AD-54,
// AD-62). reverify_last_success_timestamp_seconds{kind="Fabric",…} mirrors
// status.lastVerifiedTime — advanced by a pass that ran whatever it found, left by one that
// could not run — and, a Fabric having no finalizer, goes as soon as its deletion is seen: absent
// for a deleting Fabric (held here by a foreign finalizer) and for a deleted one.
package fabric_test

import (
	"context"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/telemetry"
)

const holdFinalizer = "test.agentic-netops.io/hold"

func fabricSeries(t *testing.T, name string) (float64, bool) {
	t.Helper()
	return telemetry.LastVerifiedSeries(telemetry.KindFabric, nsSystem, name)
}

func TestFabricReverifySeriesLifecycle(t *testing.T) {
	h := newHarness(t, "fab-series")
	h.converge()
	if v, ok := fabricSeries(t, h.name); !ok || v != float64(t0.Unix()) {
		t.Fatalf("after convergence: %v (present %v), want %d", v, ok, t0.Unix())
	}

	// A pass that ran and found an invariant missing advances it.
	h.verify.set("missing", "leaf01")
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionFalse, "")
	if v, _ := fabricSeries(t, h.name); v != float64(t0.Add(5*time.Minute).Unix()) {
		t.Fatalf("a pass that ran and found an invariant missing did not advance the series: %v", v)
	}
	h.verify.set("", "")
	h.clock.Step(15 * time.Second)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	last := float64(t0.Add(5*time.Minute + 15*time.Second).Unix())

	// Passes that could not run leave it.
	h.verify.set("cannot", "leaf02")
	for i := 0; i < 2; i++ {
		h.clock.Step(5 * time.Minute)
		h.reconcile()
		h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed")
		if v, _ := fabricSeries(t, h.name); v != last {
			t.Fatalf("a pass that could not run moved the series: %v, want %v", v, last)
		}
	}

	// Deleting (held by a foreign finalizer): absent at the reconcile that sees it.
	f := h.fabric()
	controllerutil.AddFinalizer(f, holdFinalizer)
	must(t, k8s.Update(context.Background(), f))
	must(t, k8s.Delete(context.Background(), f))
	h.reconcile()
	if v, ok := fabricSeries(t, h.name); ok {
		t.Fatalf("series present (%v) for a deleting Fabric", v)
	}
	if _, ok := telemetry.ReconcileFailedSeries(telemetry.KindFabric, nsSystem, h.name); ok {
		t.Fatal("resource_reconcile_failed present for a deleting Fabric")
	}
	h.clock.Step(10 * time.Minute)
	h.reconcile()
	if _, ok := fabricSeries(t, h.name); ok {
		t.Fatal("series reappeared for a deleting Fabric")
	}

	// Deleted: absent, and a reconcile of the absent object creates nothing.
	f = h.fabric()
	controllerutil.RemoveFinalizer(f, holdFinalizer)
	must(t, k8s.Update(context.Background(), f))
	if err := k8s.Get(context.Background(), client.ObjectKey{Namespace: nsSystem, Name: h.name}, &fabricv1.Fabric{}); err == nil {
		t.Fatal("the Fabric is still there")
	}
	h.reconcile()
	if _, ok := fabricSeries(t, h.name); ok {
		t.Fatal("series present for a deleted Fabric")
	}
	if _, ok := telemetry.ReconcileFailedSeries(telemetry.KindFabric, nsSystem, h.name); ok {
		t.Fatal("resource_reconcile_failed present for a deleted Fabric")
	}
}
