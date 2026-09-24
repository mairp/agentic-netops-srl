//go:build envtest

// T054: the Network reconciler (T059) against a real API server — every clause of T054, driven
// by direct Reconcile calls under a fake clock (suite_test.go).
package network_test

import (
	"context"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/controllers/network"
	"github.com/mairp/agentic-netops-srl/internal/telemetry"
	"github.com/mairp/agentic-netops-srl/pkg/sdc"
)

// One priority-20 Config per (service, node), each stating spec.revertive true — present and
// true, never absent; in agentic-netops-system with no ownerReferences at all, tied to the
// source by the source-uid annotation and the network-namespace/network-name labels; zero spec
// writes on a second reconcile; the provider never stamps the Network; the Configs survive a
// garbage-collection pass (nothing references the Network, so nothing can collect them — and
// envtest runs no garbage collector, so the assertion is the absence of every owner reference
// plus the Configs still present after the Network's delete while the finalizer holds it) and
// are removed by the finalizer (FR-015, FR-016, FR-101, AD-34, AD-48, AD-69).
func TestNetworkOneConfigPerServiceNode(t *testing.T) {
	h := newHarness(t, nsServices, "svc-configs")
	spec := macvrfSpec(110, 10110, att("leaf01", "ethernet-1/1", 110), att("leaf02", "ethernet-1/1", 110))
	labels := map[string]string{"agentic-netops.io/tier": "cluster-tooling"}
	annotations := map[string]string{"agentic-netops.io/tenant": "acme"}
	metricBefore := testutil.ToFloat64(telemetry.ReconcileTotal.WithLabelValues(telemetry.ControllerNetwork, telemetry.ResultSuccess))
	h.converge(spec, func(n *fabricv1.Network) { n.Labels, n.Annotations = labels, annotations })
	n := h.network()
	cfgs := h.configs()
	if len(cfgs) != 2 {
		t.Fatalf("%d Configs, want one per (service, node) = 2", len(cfgs))
	}
	for _, c := range cfgs {
		node := c.Labels[sdc.LabelTargetName]
		if c.Name != h.name+"."+node {
			t.Errorf("name %s, want %s.%s", c.Name, h.name, node)
		}
		if c.Namespace != nsSystem {
			t.Errorf("%s in %s, want %s (AD-69)", c.Name, c.Namespace, nsSystem)
		}
		if c.Spec.Priority != 20 {
			t.Errorf("%s priority %d, want 20", c.Name, c.Spec.Priority)
		}
		if c.Spec.Revertive == nil || !*c.Spec.Revertive {
			t.Errorf("%s spec.revertive %v, want present and true", c.Name, c.Spec.Revertive)
		}
		u := &unstructured.Unstructured{}
		u.SetGroupVersionKind(configv1alpha1.SchemeGroupVersion.WithKind("Config"))
		must(t, k8s.Get(context.Background(), client.ObjectKeyFromObject(&c), u))
		if v, found, _ := unstructured.NestedBool(u.Object, "spec", "revertive"); !found || !v {
			t.Errorf("%s: spec.revertive on the wire found=%v value=%v", c.Name, found, v)
		}
		if len(c.OwnerReferences) != 0 {
			t.Errorf("%s carries owner references %+v: a service Config carries none (AD-69)", c.Name, c.OwnerReferences)
		}
		if c.Annotations[sdc.AnnotationSourceUID] != string(n.UID) || c.Labels[sdc.LabelNetworkNamespace] != nsServices || c.Labels[sdc.LabelNetworkName] != h.name {
			t.Errorf("%s not tied to its source: annotations %v labels %v", c.Name, c.Annotations, c.Labels)
		}
		if c.Labels[sdc.LabelTargetNamespace] != nsTargets || c.Spec.Lifecycle == nil || c.Spec.Lifecycle.DeletionPolicy != configv1alpha1.DeletionDelete {
			t.Errorf("%s target labels %v lifecycle %+v", c.Name, c.Labels, c.Spec.Lifecycle)
		}
		if c.Annotations[sdc.AnnotationCompatibilitySet] != lockSet.Identifier() || !strings.HasPrefix(c.Annotations[sdc.AnnotationRenderHash], "sha256:") {
			t.Errorf("%s annotations %v", c.Name, c.Annotations)
		}
		ssa := false
		for _, mf := range c.ManagedFields {
			if mf.Manager == sdc.FieldManager && mf.Operation == metav1.ManagedFieldsOperationApply {
				ssa = true
			}
		}
		if !ssa {
			t.Errorf("%s: no server-side apply by %s", c.Name, sdc.FieldManager)
		}
	}
	if len(n.Status.RenderedConfigs) != 2 || n.Status.ObservedGeneration != n.Generation {
		t.Fatalf("status renderedConfigs %+v observedGeneration %d", n.Status.RenderedConfigs, n.Status.ObservedGeneration)
	}
	for _, rc := range n.Status.RenderedConfigs {
		if rc.Phase != fabricv1.TargetPhaseReady || !strings.HasPrefix(rc.RenderHash, "sha256:") || rc.Priority != 20 || rc.Namespace != nsSystem {
			t.Errorf("per-target status %+v", rc)
		}
	}
	if n.Status.LastVerifiedTime == nil || !n.Status.LastVerifiedTime.Time.Equal(t0) {
		t.Errorf("lastVerifiedTime %v, want %v", n.Status.LastVerifiedTime, t0)
	}
	if got := testutil.ToFloat64(telemetry.ReconcileTotal.WithLabelValues(telemetry.ControllerNetwork, telemetry.ResultSuccess)); got <= metricBefore {
		t.Errorf("agentic_netops_reconcile_total{network,success} did not move: %v", got)
	}

	// Zero spec writes on a second reconcile.
	before := versionsOf(t, h.ns, h.name)
	h.reconcile()
	h.reconcile()
	sameVersions(t, "second reconcile", before, versionsOf(t, h.ns, h.name))

	// The provider never stamps the Network: its labels and annotations are what was applied,
	// its spec generation unchanged, its only metadata write the finalizer.
	n = h.network()
	if !reflect.DeepEqual(n.Labels, labels) || !reflect.DeepEqual(n.Annotations, annotations) {
		t.Errorf("the Network was stamped: labels %v annotations %v", n.Labels, n.Annotations)
	}
	if n.Generation != 1 || !reflect.DeepEqual(n.Finalizers, []string{network.Finalizer}) {
		t.Errorf("generation %d finalizers %v, want 1 and [%s]", n.Generation, n.Finalizers, network.Finalizer)
	}

	// Deleting the Network while the finalizer holds it leaves the Configs (no owner reference
	// can collect them); the finalizer removes them.
	h.delete()
	if got := len(h.configs()); got != 2 {
		t.Fatalf("%d Configs after the Network's delete, before the finalizer ran: nothing may collect them", got)
	}
	h.reconcile()
	if got := len(h.configs()); got != 0 {
		t.Fatalf("%d Configs left after the finalizer ran", got)
	}
	eventually(t, 5*time.Second, "the Network gone once finalized", h.gone)
}

// A priority collision: a fixture Config of priority 20 planted on one of the object's own
// non-key leaf paths is refused at validation — Applied=False/OwnershipConflict naming the path
// and the other Config — never ordered; nothing is written. A priority-10 Config on the same
// leaf is the fabric band and no collision (Rule 4, AD-68).
func TestNetworkPriorityCollisionRefused(t *testing.T) {
	h := newHarness(t, nsServices, "svc-collide")
	leaf := `{"srl_nokia-interfaces:interface":[{"name":"ethernet-1/2","subinterface":[{"index":300,"admin-state":"disable"}]}]}`
	plantConfig(t, "fixture-collide.leaf01", "leaf01", 20, leaf)
	plantConfig(t, "fixture-fabric-band.leaf01", "leaf01", 10, leaf)
	h.create(vlanSpec(300, att("leaf01", "ethernet-1/2", 300)))
	if res := h.reconcile(); res.RequeueAfter != 0 {
		t.Errorf("a terminal collision is not requeued, got %s", res.RequeueAfter)
	}
	c := h.wantCond("Applied", metav1.ConditionFalse, "OwnershipConflict",
		"/interface[name=ethernet-1/2]/subinterface[index=300]/admin-state", "Config "+nsSystem+"/fixture-collide.leaf01")
	if strings.Contains(c.Message, "fixture-fabric-band") {
		t.Errorf("a priority-10 Config was compared: %s", c.Message)
	}
	if r := h.cond("Ready"); r == nil || r.Status == metav1.ConditionTrue {
		t.Errorf("Ready %+v beside a refused collision", r)
	}
	if n := len(h.configs()); n != 0 {
		t.Fatalf("%d Configs written despite the collision", n)
	}
}

// The collision is defined on non-key leaf paths (AD-68): two tagged services on one access
// port, and a gateway service beside another on one leaf, share no leaf and are both applied.
func TestNetworkDistinctServicesShareNoLeaf(t *testing.T) {
	a := newHarness(t, nsServices, "svc-port-a")
	b := a.with(nsServices, "svc-port-b")
	a.converge(vlanSpec(120, att("leaf01", "ethernet-1/2", 120)))
	b.converge(vlanSpec(121, att("leaf01", "ethernet-1/2", 121)))

	g := a.with(nsServices, "svc-gateway")
	o := a.with(nsServices, "svc-beside")
	g.converge(gatewaySpec(122, 10122, 10123, "10.122.0.1/24", att("leaf01", "ethernet-1/2", 122)))
	o.converge(gatewaySpec(124, 10124, 10125, "10.124.0.1/24", att("leaf01", "ethernet-1/2", 124)))
	for _, x := range []*harness{a, b, g, o} {
		x.wantCond("Applied", metav1.ConditionTrue, "")
		if len(x.configs()) != 1 {
			t.Errorf("%s: %d Configs, want 1", x.name, len(x.configs()))
		}
	}
}

// An overruled platform-owned path is a terminal error (Rule 4, Rule 6, AD-66): a NOT_APPLIED
// deviation sets no such condition; an OVERRULED one on a path the object's Config owns sets
// Applied=False/OwnershipConflict naming the path and the overruling intent, Ready is not
// True, no Config write follows on that or any later reconcile — a new generation that would
// write included — and the condition stays until the deviation is gone.
func TestNetworkOverruledPathIsTerminal(t *testing.T) {
	h := newHarness(t, nsServices, "svc-overruled")
	h.converge(vlanSpec(130, att("leaf01", "ethernet-1/2", 130)))
	cfg := h.name + ".leaf01"
	path := "/interface[name=ethernet-1/2]/subinterface[index=130]/admin-state"

	setDeviation(t, cfg, "leaf01", deviation(path, sdc.DeviationNotApplied))
	h.clock.Step(15 * time.Second)
	h.reconcile()
	h.notCond("Applied", "OwnershipConflict")
	h.wantCond("Ready", metav1.ConditionTrue, "")

	plantConfig(t, "fixture-overruling.leaf01", "leaf01", 5,
		`{"srl_nokia-interfaces:interface":[{"name":"ethernet-1/2","subinterface":[{"index":130,"admin-state":"disable"}]}]}`)
	setDeviation(t, cfg, "leaf01", deviation(path, sdc.DeviationOverruled))
	before := versionsOf(t, h.ns, h.name)
	if res := h.reconcile(); res.RequeueAfter != 0 {
		t.Errorf("a terminal overruled path is not requeued, got %s", res.RequeueAfter)
	}
	h.wantCond("Applied", metav1.ConditionFalse, "OwnershipConflict", path, "Config "+nsSystem+"/fixture-overruling.leaf01")
	if r := h.cond("Ready"); r.Status == metav1.ConditionTrue {
		t.Fatal("Ready=True beside an overruled path")
	}
	sameVersions(t, "overruled pass", before, versionsOf(t, h.ns, h.name))

	// A later reconcile — a new generation that would write a leaf02 Config included — writes
	// nothing while the deviation persists.
	h.update(func(n *fabricv1.Network) {
		n.Spec.Attachments = append(n.Spec.Attachments, att("leaf02", "ethernet-1/2", 130))
	})
	for i := 0; i < 2; i++ {
		h.clock.Step(5 * time.Minute)
		h.reconcile()
		h.wantCond("Applied", metav1.ConditionFalse, "OwnershipConflict", path)
		sameVersions(t, "reconcile while overruled", before, versionsOf(t, h.ns, h.name))
	}

	// The deviation gone: the object proceeds.
	clearDeviation(t, cfg)
	h.reconcile()
	h.notCond("Applied", "OwnershipConflict")
	if len(h.configs()) != 2 {
		t.Fatalf("%d Configs once the deviation is gone, want 2", len(h.configs()))
	}
}

// A second Network of the same name in the other service namespace derives the same Config
// name: it writes nothing and reports Applied=False/OwnershipConflict naming the holder (FR-016,
// AD-69).
func TestNetworkSameNameOtherNamespace(t *testing.T) {
	first := newHarness(t, nsServices, "svc-dup")
	first.converge(vlanSpec(140, att("leaf01", "ethernet-1/2", 140)))
	before := versionsOf(t, nsServices, "svc-dup")

	second := first.with(nsIntent, "svc-dup")
	second.create(vlanSpec(141, att("leaf01", "ethernet-1/1", 141)))
	second.reconcile()
	second.wantCond("Applied", metav1.ConditionFalse, "OwnershipConflict", "Network "+nsServices+"/svc-dup", "svc-dup.leaf01")
	if n := len(second.configs()); n != 0 {
		t.Fatalf("the second Network wrote %d Configs", n)
	}
	sameVersions(t, "the holder's Configs", before, versionsOf(t, nsServices, "svc-dup"))
}

// All-or-nothing validation strands nothing: one attachment that does not resolve refuses the
// whole object — no Config on any node and no claim made; a target not Ready holds every node.
func TestNetworkAllOrNothing(t *testing.T) {
	h := newHarness(t, nsServices, "svc-allornothing")
	h.create(macvrfSpec(150, 10150, att("leaf01", "ethernet-1/1", 150), att("leaf02", "ethernet-1/9", 150)))
	h.reconcile()
	h.wantCond("Accepted", metav1.ConditionFalse, "ReferenceNotFound", "leaf02 ethernet-1/9")
	if n := len(h.configs()); n != 0 {
		t.Fatalf("%d Configs written for a partially valid object", n)
	}
	if n := h.claims.count(); n != 0 {
		t.Fatalf("%d claims made for a refused object", n)
	}

	w := h.with(nsServices, "svc-allornothing-wait")
	setTarget(t, "leaf02", false)
	w.create(vlanSpec(151, att("leaf01", "ethernet-1/1", 151), att("leaf02", "ethernet-1/1", 151)))
	w.reconcile()
	w.wantCond("Applied", metav1.ConditionFalse, "TargetNotReady", "leaf02")
	if n := len(w.configs()); n != 0 {
		t.Fatalf("%d Configs written while one target was not Ready", n)
	}
}

// Per-target Degraded within two intervals with the healthy target still reported:
// Degraded=True/PartialFailure beside Ready=False (outranking TelemetryUnavailable), the failed
// target Failed and the healthy one Ready in status.renderedConfigs (FR-018, NFR-002).
func TestNetworkPartialFailureDegraded(t *testing.T) {
	h := newHarness(t, nsServices, "svc-partial")
	h.create(macvrfSpec(160, 10160, att("leaf01", "ethernet-1/1", 160), att("leaf02", "ethernet-1/1", 160)))
	if res := h.reconcile(); res.RequeueAfter != h.r.Settings.ReconcileInterval {
		t.Errorf("a converging Network is requeued at %s, want the reconciliation interval", res.RequeueAfter)
	}
	confirmConfigs(t, h.ns, h.name, "leaf02")
	h.tele.set(false)
	h.clock.Step(15 * time.Second) // within two reconciliation intervals of the failure
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionFalse, "NotConverged", "leaf02")
	h.wantCond("Degraded", metav1.ConditionTrue, "PartialFailure", "leaf02")
	h.wantCond("Applied", metav1.ConditionFalse, "TransactionFailed", "leaf02")
	n := h.network()
	if phaseOf(n, "leaf01") != fabricv1.TargetPhaseReady || phaseOf(n, "leaf02") != fabricv1.TargetPhaseFailed {
		t.Errorf("per-target status %+v", n.Status.RenderedConfigs)
	}
	if h.verify.count() != 0 {
		t.Error("a read-back ran although a transaction failed")
	}
}

// Scheduled re-verification with a fake clock (FR-107, AD-54): requeued at the interval,
// lastVerifiedTime advancing, zero Config writes on a clean pass; Ready=False/RoutesMissing
// naming the invariant when the applied side no longer shows it — lastVerifiedTime advancing on
// that pass as on every pass that ran — and back to Ready when it returns.
func TestNetworkScheduledReverification(t *testing.T) {
	h := newHarness(t, nsServices, "svc-reverify")
	if h.r.Settings.ReverifyInterval != 5*time.Minute || h.r.Settings.ReconcileInterval != 15*time.Second {
		t.Fatalf("defaults %s / %s, want 5m / 15s (data-model.md §25)", h.r.Settings.ReverifyInterval, h.r.Settings.ReconcileInterval)
	}
	h.converge(macvrfSpec(170, 10170, att("leaf01", "ethernet-1/1", 170), att("leaf02", "ethernet-1/1", 170)))
	before := versionsOf(t, h.ns, h.name)
	calls := h.verify.count()

	h.clock.Step(time.Minute)
	if res := h.reconcile(); res.RequeueAfter != 4*time.Minute {
		t.Errorf("between passes the requeue is %s, want the 4m left", res.RequeueAfter)
	}
	if h.verify.count() != calls {
		t.Fatal("a read-back ran before the interval elapsed")
	}
	h.clock.Step(4 * time.Minute)
	if res := h.reconcile(); res.RequeueAfter != 5*time.Minute {
		t.Errorf("requeue %s after a scheduled pass, want 5m", res.RequeueAfter)
	}
	if h.verify.count() != calls+1 {
		t.Fatal("no read-back at the interval")
	}
	if lv := h.network().Status.LastVerifiedTime; lv == nil || !lv.Time.Equal(t0.Add(5*time.Minute)) {
		t.Errorf("lastVerifiedTime %v, want %v", lv, t0.Add(5*time.Minute))
	}
	sameVersions(t, "clean scheduled pass", before, versionsOf(t, h.ns, h.name))

	h.verify.set("leaf01", "missing")
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionFalse, "RoutesMissing", "leaf01", "remote-vtep")
	if lv := h.network().Status.LastVerifiedTime; lv == nil || !lv.Time.Equal(t0.Add(10*time.Minute)) {
		t.Errorf("the pass that found an invariant missing must advance lastVerifiedTime: %v", lv)
	}
	sameVersions(t, "pass finding an invariant missing", before, versionsOf(t, h.ns, h.name))
	h.verify.set("leaf01", "")
	h.clock.Step(15 * time.Second)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
}

// A target unreachable under a Ready Network: Ready=Unknown/VerificationFailed and
// Degraded=True/VerificationFailed naming it at the first pass that cannot read it — never
// False, never a True left standing — lastVerifiedTime frozen, the healthy target still
// reported, Ready=True at the first pass after it returns (AD-40); and the same when the target
// goes not Ready between two scheduled passes, at the reconcile that sees it (AD-54).
func TestNetworkPassThatCannotRun(t *testing.T) {
	h := newHarness(t, nsServices, "svc-cannot")
	h.converge(macvrfSpec(180, 10180, att("leaf01", "ethernet-1/1", 180), att("leaf02", "ethernet-1/1", 180)))
	before := versionsOf(t, h.ns, h.name)

	h.verify.set("leaf02", "cannot")
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	neitherTrueNorFalse(t, h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed", "leaf02"))
	h.wantCond("Degraded", metav1.ConditionTrue, "VerificationFailed", "leaf02")
	n := h.network()
	if phaseOf(n, "leaf01") != fabricv1.TargetPhaseReady || phaseOf(n, "leaf02") != fabricv1.TargetPhaseUnreachable {
		t.Errorf("per-target status while leaf02 cannot be read: %+v", n.Status.RenderedConfigs)
	}
	for i := 0; i < 2; i++ {
		h.clock.Step(5 * time.Minute)
		h.reconcile()
		neitherTrueNorFalse(t, h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed", "leaf02"))
		if lv := h.network().Status.LastVerifiedTime; lv == nil || !lv.Time.Equal(t0) {
			t.Fatalf("lastVerifiedTime advanced by a pass that could not run: %v", lv)
		}
	}
	h.verify.set("leaf02", "")
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	h.wantCond("Degraded", metav1.ConditionFalse, "")
	sameVersions(t, "cannot-run passes", before, versionsOf(t, h.ns, h.name))

	// The target goes not Ready between two scheduled passes: the reconcile that sees it —
	// within two reconciliation intervals, not at the next scheduled pass.
	setTarget(t, "leaf01", false)
	h.clock.Step(10 * time.Second)
	h.reconcile()
	neitherTrueNorFalse(t, h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed", "leaf01"))
	h.wantCond("Degraded", metav1.ConditionTrue, "VerificationFailed", "leaf01")
	if phaseOf(h.network(), "leaf02") != fabricv1.TargetPhaseReady {
		t.Errorf("the healthy target is no longer reported: %+v", h.network().Status.RenderedConfigs)
	}
	frozen := h.network().Status.LastVerifiedTime
	h.clock.Step(15 * time.Second)
	h.reconcile()
	neitherTrueNorFalse(t, h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed", "leaf01"))
	if lv := h.network().Status.LastVerifiedTime; !lv.Equal(frozen) {
		t.Fatalf("lastVerifiedTime moved while the target was away: %v -> %v", frozen, lv)
	}
	must(t, targetStatus(context.Background(), "leaf01", true))
	h.clock.Step(10 * time.Second)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	sameVersions(t, "target outage", before, versionsOf(t, h.ns, h.name))

	// The layer loses the session before its Target says so (observed live, 2026-09-21: the
	// Target stayed Ready 315 s after the management link was cut while the Config went
	// Failed at +17 s): the layer's Config for this generation is no longer confirmed while
	// the Target is still Ready and nothing was written. That is a read-back that cannot run
	// — Unknown/VerificationFailed naming the target at the reconcile that sees it, never
	// Ready=False/NotConverged with Applied=False/TransactionFailed (AD-40, AD-54, AD-62).
	confirmConfigs(t, h.ns, h.name, "leaf02")
	faulted := versionsOf(t, h.ns, h.name)
	h.clock.Step(10 * time.Second)
	h.reconcile()
	neitherTrueNorFalse(t, h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed", "leaf02"))
	h.wantCond("Degraded", metav1.ConditionTrue, "VerificationFailed", "leaf02")
	h.notCond("Applied", "TransactionFailed")
	if phaseOf(h.network(), "leaf01") != fabricv1.TargetPhaseReady || phaseOf(h.network(), "leaf02") != fabricv1.TargetPhaseUnreachable {
		t.Errorf("per-target status while the layer does not confirm leaf02: %+v", h.network().Status.RenderedConfigs)
	}
	frozen = h.network().Status.LastVerifiedTime
	h.clock.Step(15 * time.Second)
	h.reconcile()
	neitherTrueNorFalse(t, h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed", "leaf02"))
	if lv := h.network().Status.LastVerifiedTime; !lv.Equal(frozen) {
		t.Fatalf("lastVerifiedTime moved while the layer did not confirm leaf02: %v -> %v", frozen, lv)
	}
	// No reapply while the layer does not confirm: the Unknown is a reading, not a repair.
	sameVersions(t, "layer session loss", faulted, versionsOf(t, h.ns, h.name))
	confirmConfigs(t, h.ns, h.name)
	h.clock.Step(15 * time.Second)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	h.wantCond("Degraded", metav1.ConditionFalse, "")
}

// A pass that could not run is retried at the reconciliation interval, not the
// re-verification one: after the target returns, Ready=True comes at the first retry,
// within one reconciliation interval, never a whole re-verification interval later —
// and a retry that still cannot run leaves lastVerifiedTime frozen. Observed live
// 2026-09-24 (T167 mgmt-cut: with a 60 s interval Ready=True came 78 s after the
// leaf's data path was restored; live-findings 2026-09-24-unknown-retry).
func TestNetworkUnknownRetriedAtReconcileInterval(t *testing.T) {
	h := newHarness(t, nsServices, "svc-unknown-retry")
	h.converge(macvrfSpec(185, 10185, att("leaf01", "ethernet-1/1", 185), att("leaf02", "ethernet-1/1", 185)))
	before := versionsOf(t, h.ns, h.name)

	h.verify.set("leaf02", "cannot")
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	neitherTrueNorFalse(t, h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed", "leaf02"))
	frozen := h.network().Status.LastVerifiedTime
	// A retry one reconciliation interval later that still cannot run.
	h.clock.Step(15 * time.Second)
	h.reconcile()
	neitherTrueNorFalse(t, h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed", "leaf02"))
	if lv := h.network().Status.LastVerifiedTime; !lv.Equal(frozen) {
		t.Fatalf("lastVerifiedTime moved on a retry that could not run: %v -> %v", frozen, lv)
	}
	// The target returns. Before a reconciliation interval has passed no pass is due
	// (negative control: the retry is paced, not a hot loop).
	h.verify.set("leaf02", "")
	h.clock.Step(5 * time.Second)
	h.reconcile()
	neitherTrueNorFalse(t, h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed", "leaf02"))
	// One reconciliation interval after the last retry — far short of the five-minute
	// re-verification interval — the retry runs and settles it.
	h.clock.Step(10 * time.Second)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	h.wantCond("Degraded", metav1.ConditionFalse, "")
	if lv := h.network().Status.LastVerifiedTime; lv == nil || !lv.After(frozen.Time) {
		t.Errorf("the retry that ran must advance lastVerifiedTime: %v", lv)
	}
	sameVersions(t, "unknown retries", before, versionsOf(t, h.ns, h.name))
}

// A Network that has never reported Ready is not requeued by the schedule — it is requeued at
// the reconciliation interval while converging, and not at all on a terminal error — while one
// held in deletion is: the schedule is the finalizer's requeue (FR-107, Rule 5, Rule 8).
func TestNetworkScheduleRequeues(t *testing.T) {
	h := newHarness(t, nsServices, "svc-never-ready")
	setTarget(t, "leaf02", false)
	h.create(vlanSpec(190, att("leaf02", "ethernet-1/1", 190)))
	for i := 0; i < 2; i++ {
		res := h.reconcile()
		if res.RequeueAfter != h.r.Settings.ReconcileInterval {
			t.Fatalf("a never-Ready Network is requeued at %s, want the reconciliation interval %s, never the schedule", res.RequeueAfter, h.r.Settings.ReconcileInterval)
		}
		h.clock.Step(15 * time.Second)
	}
	term := h.with(nsServices, "svc-never-ready-terminal")
	term.create(vlanSpec(191, att("leaf01", "ethernet-1/7", 191)))
	if res := term.reconcile(); res.RequeueAfter != 0 {
		t.Errorf("a terminal never-Ready Network is requeued at %s", res.RequeueAfter)
	}

	held := h.with(nsServices, "svc-held")
	held.converge(vlanSpec(192, att("leaf01", "ethernet-1/1", 192)))
	holdConfig(t, held.name+".leaf01")
	setTarget(t, "leaf01", false)
	held.delete()
	res := held.reconcile()
	if res.RequeueAfter != held.r.Settings.ReverifyInterval {
		t.Fatalf("a Network held in deletion is requeued at %s, want the re-verification interval", res.RequeueAfter)
	}
	held.wantCond("Ready", metav1.ConditionFalse, "Deleting")
	held.wantCond("Deleting", metav1.ConditionTrue, "TargetUnreachable", "leaf01")
	// The target is back and the removal awaits its read-back: still requeued, at the
	// reconciliation interval (live-findings 2026-09-24-delete-unreachable).
	setTarget(t, "leaf01", true)
	held.clock.Step(held.r.Settings.ReverifyInterval)
	if res := held.reconcile(); res.RequeueAfter != held.r.Settings.ReconcileInterval {
		t.Fatalf("a Network awaiting its removal read-back is requeued at %s, want the reconciliation interval", res.RequeueAfter)
	}
	held.wantCond("Deleting", metav1.ConditionTrue, "RemovingConfiguration", held.name+".leaf01")
	releaseConfig(t, held.name+".leaf01")
	held.reconcile()
	eventually(t, 5*time.Second, "the held Network finalized once its removal is read back", held.gone)
}

// "Had reported Ready" is read at the current generation (data-model.md §18, AD-62): a Ready
// Network updated to a new generation while a target is unreachable is Ready=False/NotConverged
// with Applied=False/TargetNotReady naming the target — not Unknown/VerificationFailed — and
// converges to Ready=True when the target returns.
func TestNetworkGenerationSemantics(t *testing.T) {
	h := newHarness(t, nsServices, "svc-generation")
	h.converge(macvrfSpec(200, 10200, att("leaf01", "ethernet-1/1", 200), att("leaf02", "ethernet-1/1", 200)))
	setTarget(t, "leaf02", false)
	h.update(func(n *fabricv1.Network) { n.Spec.Description = "generation two" })
	h.reconcile()
	r := h.wantCond("Ready", metav1.ConditionFalse, "NotConverged", "leaf02")
	if r.Status == metav1.ConditionUnknown || r.Reason == "VerificationFailed" {
		t.Fatal("a new generation is converging, never Unknown")
	}
	h.wantCond("Applied", metav1.ConditionFalse, "TargetNotReady", "leaf02")
	h.notCond("Degraded", "VerificationFailed")

	must(t, targetStatus(context.Background(), "leaf02", true))
	h.clock.Step(15 * time.Second)
	h.reconcile()
	confirmConfigs(t, h.ns, h.name)
	h.clock.Step(15 * time.Second)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	if c := h.cond("Ready"); c.ObservedGeneration != 2 {
		t.Errorf("Ready at generation %d, want 2", c.ObservedGeneration)
	}
}

// The Degraded reason by §18's order (NFR-002, AD-62): TelemetryUnavailable, from the fake
// telemetry-health input alone, beside a Ready=True that does not move and with no other
// condition changed, yielding to VerificationFailed when a target cannot be read.
// (PartialFailure beside Ready=False: TestNetworkPartialFailureDegraded.)
func TestNetworkDegradedOrder(t *testing.T) {
	h := newHarness(t, nsServices, "svc-degraded")
	h.converge(vlanSpec(210, att("leaf01", "ethernet-1/1", 210), att("leaf02", "ethernet-1/1", 210)))
	snapshot := map[string]metav1.Condition{}
	for _, c := range h.network().Status.Conditions {
		snapshot[c.Type] = c
	}
	h.tele.set(false)
	h.reconcile()
	h.wantCond("Degraded", metav1.ConditionTrue, "TelemetryUnavailable")
	for _, c := range h.network().Status.Conditions {
		if c.Type == "Degraded" {
			continue
		}
		if old := snapshot[c.Type]; old.Status != c.Status || old.Reason != c.Reason || old.Message != c.Message || !old.LastTransitionTime.Equal(&c.LastTransitionTime) {
			t.Errorf("a telemetry failure moved %s: %+v -> %+v", c.Type, old, c)
		}
	}
	h.verify.set("leaf02", "cannot")
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	h.wantCond("Degraded", metav1.ConditionTrue, "VerificationFailed", "leaf02")
	h.verify.set("leaf02", "")
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	h.wantCond("Degraded", metav1.ConditionTrue, "TelemetryUnavailable")
	h.tele.set(true)
	h.reconcile()
	h.wantCond("Degraded", metav1.ConditionFalse, "")
}

// The Fabric dependency is that it exists and is Accepted, never that it is Ready (data-model.md
// §19, AD-55): with the Fabric Ready=False/NotConverged and still Accepted a new Network renders
// and applies as under a Ready one, and one that had reported Ready is still requeued at the
// interval and still reports Ready=False/RoutesMissing — neither held in a wait. Negative
// control: a Fabric that is not Accepted, or absent, holds the Network with no Config written.
func TestNetworkFabricAcceptedNeverReady(t *testing.T) {
	ready := newHarness(t, nsServices, "svc-fab-ready")
	ready.converge(macvrfSpec(220, 10220, att("leaf01", "ethernet-1/1", 220), att("leaf02", "ethernet-1/1", 220)))

	setFabricConditions(t, true, false)
	fresh := ready.with(nsServices, "svc-fab-notready")
	fresh.converge(vlanSpec(221, att("leaf01", "ethernet-1/1", 221)))
	fresh.notCond("Ready", "NotConverged")

	ready.verify.set("leaf01", "missing")
	ready.clock.Step(5 * time.Minute)
	ready.reconcile()
	ready.wantCond("Ready", metav1.ConditionFalse, "RoutesMissing", "leaf01")
	ready.verify.set("leaf01", "")
	ready.clock.Step(15 * time.Second)
	if res := ready.reconcile(); res.RequeueAfter != ready.r.Settings.ReverifyInterval {
		t.Errorf("a Ready Network under a not-Ready Fabric is requeued at %s, want the re-verification interval", res.RequeueAfter)
	}
	ready.wantCond("Ready", metav1.ConditionTrue, "")

	// negative control: not Accepted
	must(t, fabricStatus(context.Background(), false, false))
	held := ready.with(nsServices, "svc-fab-notaccepted")
	held.create(vlanSpec(223, att("leaf01", "ethernet-1/1", 223)))
	if res := held.reconcile(); res.RequeueAfter != held.r.Settings.ReconcileInterval {
		t.Errorf("a dependency wait is requeued at %s, want the reconciliation interval", res.RequeueAfter)
	}
	held.wantCond("Ready", metav1.ConditionFalse, "NotConverged", "not Accepted")
	if n := len(held.configs()); n != 0 {
		t.Fatalf("%d Configs written under a Fabric that is not Accepted", n)
	}

	// negative control: absent
	deleteFabric(t)
	absent := ready.with(nsServices, "svc-fab-absent")
	absent.create(vlanSpec(224, att("leaf01", "ethernet-1/1", 224)))
	absent.reconcile()
	absent.wantCond("Ready", metav1.ConditionFalse, "NotConverged", "no Fabric")
	if n := len(absent.configs()); n != 0 {
		t.Fatalf("%d Configs written with no Fabric", n)
	}
}

// Topology change after allocation (FR-101): an attachment whose port is removed from the Fabric
// inventory sets Ready=False naming the attachment, keeps every claim and re-allocates nothing.
func TestNetworkTopologyChangeAfterAllocation(t *testing.T) {
	h := newHarness(t, nsServices, "svc-topology")
	h.converge(macvrfSpec(230, 10230, att("leaf01", "ethernet-1/1", 230), att("leaf02", "ethernet-1/2", 230)))
	refs := h.network().Status.ClaimRefs
	if len(refs) != 1 {
		t.Fatalf("claimRefs %+v, want the L2VNI's", refs)
	}
	claims, creates := h.claims.count(), h.claims.createdCount()
	before := versionsOf(t, h.ns, h.name)

	updateFabric(t, func(f *fabricv1.Fabric) {
		f.Spec.Inventory[1].AccessPorts = []fabricv1.PortName{"ethernet-1/1"}
	})
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionFalse, "", "leaf02 ethernet-1/2")
	h.wantCond("Accepted", metav1.ConditionFalse, "ReferenceNotFound", "leaf02 ethernet-1/2")
	if got := h.network().Status.ClaimRefs; !reflect.DeepEqual(got, refs) {
		t.Errorf("claimRefs changed %+v -> %+v", refs, got)
	}
	if h.claims.count() != claims || h.claims.createdCount() != creates || len(h.claims.releasedNames()) != 0 {
		t.Error("a claim was made or released on a topology change")
	}
	sameVersions(t, "topology change", before, versionsOf(t, h.ns, h.name))
}

// The reconciler registered with a manager (SetupWithManager): the Network watch is
// cluster-wide and the Config watch (by the network-namespace/name labels) drives it to Ready
// once the layer confirms.
func TestNetworkManagerWiring(t *testing.T) {
	h := newHarness(t, nsIntent, "svc-manager")
	r := h.newReconciler()
	r.Clock = nil // the real clock
	mgr, err := ctrl.NewManager(restCfg, ctrl.Options{Scheme: scheme, Metrics: metricsserver.Options{BindAddress: "0"},
		HealthProbeBindAddress: "0", LeaderElection: false})
	must(t, err)
	r.Client = mgr.GetClient()
	r.SDC = sdc.New(mgr.GetClient())
	must(t, r.SetupWithManager(mgr))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = mgr.Start(ctx) }()
	h.create(vlanSpec(240, att("leaf01", "ethernet-1/1", 240), att("leaf02", "ethernet-1/1", 240)))
	eventually(t, 20*time.Second, "two Configs rendered by the managed reconciler", func() bool { return len(h.configs()) == 2 })
	confirmConfigs(t, h.ns, h.name)
	eventually(t, 20*time.Second, "Ready=True after the layer confirms", func() bool {
		c := h.cond("Ready")
		return c != nil && c.Status == metav1.ConditionTrue
	})
	h.delete()
	eventually(t, 20*time.Second, "the finalizer removes the Configs and the Network", func() bool { return h.gone() && len(h.configs()) == 0 })
}
