//go:build envtest

// T055: ordered deletion and recoverable finalization of a Network (contracts/reconciliation.md
// Rule 8, every step; data-model.md §3a status.findings[], §18; FR-043, FR-103, FR-107, FR-109;
// CD-02; AD-32, AD-44, AD-49, AD-53, AD-54, AD-56, AD-61, AD-71), against the finalizer and the
// force-release of controllers/network (T060).
//
// Every deletion test reconciles through delStep, which reads the object back after EVERY
// reconcile and fails on any observation of Ready other than False/Deleting (never True,
// never Unknown/VerificationFailed) while the object exists. A Config delete is observed
// through delObservingClient, which reads the Network from the API server at the moment the
// finalizer removes its first Config: Ready=False/Deleting is already written then.
//
// The Fabric side (findings during the outage beside Ready=Unknown/VerificationFailed,
// StaleConfigurationPossible beside Ready=True at the first pass after the target returns,
// clearance only by a clean scheduled read-back) drives the real Fabric reconciler
// (controllers/fabric) over the shared Fabric with its own fakes (delFabricHarness), the way
// tests/envtest/fabric does; its Configs and status are put back at cleanup.
package network_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	condv1alpha1 "github.com/sdcio/config-server/apis/condition/v1alpha1"
	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	clocktesting "k8s.io/utils/clock/testing"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/controllers/fabric"
	"github.com/mairp/agentic-netops-srl/controllers/network"
	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/verify"
	"github.com/mairp/agentic-netops-srl/pkg/kuid"
	"github.com/mairp/agentic-netops-srl/pkg/sdc"
)

// ---------------------------------------------------------------------------
// Helpers of this file.
// ---------------------------------------------------------------------------

// delAssertDeleting fails unless the Network carries Ready=False/Deleting beside Deleting=True
// and no VerificationFailed anywhere (AD-53).
func delAssertDeleting(h *harness) {
	h.t.Helper()
	n := h.network()
	for _, c := range n.Status.Conditions {
		if c.Reason == "VerificationFailed" {
			h.t.Fatalf("%s/%s: %s=%s/VerificationFailed on a deleting object (AD-53)", h.ns, h.name, c.Type, c.Status)
		}
	}
	h.wantCond("Ready", metav1.ConditionFalse, "Deleting")
	h.wantCond("Deleting", metav1.ConditionTrue, "")
}

// delStep reconciles once and, while the object exists, asserts Ready=False/Deleting.
func delStep(h *harness) ctrl.Result {
	h.t.Helper()
	res := h.reconcile()
	if !h.gone() {
		delAssertDeleting(h)
	}
	return res
}

// delObservingClient calls onDelete before every Delete it passes on: the finalizer's Config
// deletions go through it (pkg/sdc over this client).
type delObservingClient struct {
	client.Client
	onDelete func(obj client.Object)
}

func (c delObservingClient) Delete(ctx context.Context, obj client.Object, opts ...client.DeleteOption) error {
	if c.onDelete != nil {
		c.onDelete(obj)
	}
	return c.Client.Delete(ctx, obj, opts...)
}

// delObserveFirstConfigDelete makes h's reconciler record, at its first Config delete, the
// Network's Ready condition as the API server holds it then.
func delObserveFirstConfigDelete(h *harness) func() (seen bool, ready string) {
	var mu sync.Mutex
	seen, ready := false, ""
	h.r.SDC = sdc.New(delObservingClient{Client: k8s, onDelete: func(obj client.Object) {
		if _, ok := obj.(*configv1alpha1.Config); !ok {
			return
		}
		mu.Lock()
		defer mu.Unlock()
		if seen {
			return
		}
		seen = true
		n := &fabricv1.Network{}
		if err := k8s.Get(context.Background(), client.ObjectKey{Namespace: h.ns, Name: h.name}, n); err != nil {
			ready = "read failed: " + err.Error()
			return
		}
		for _, c := range n.Status.Conditions {
			if c.Type == "Ready" {
				ready = string(c.Status) + "/" + c.Reason
			}
		}
	}})
	return func() (bool, string) {
		mu.Lock()
		defer mu.Unlock()
		return seen, ready
	}
}

func delAnnotate(h *harness, value string) {
	h.t.Helper()
	h.update(func(n *fabricv1.Network) {
		if n.Annotations == nil {
			n.Annotations = map[string]string{}
		}
		n.Annotations[network.AnnotationForceRelease] = value
	})
}

func delEvents(r *recorder, reason string) []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []string
	for _, e := range r.events {
		if strings.Contains(e, " "+reason+" ") {
			out = append(out, e)
		}
	}
	return out
}

// delForceReleasedEvents are the per-finding ForceReleased Events (not the Deleting=True/
// ForceReleased condition transition, which shares the reason).
func delForceReleasedEvents(r *recorder) []string {
	var out []string
	for _, e := range delEvents(r, network.EventForceReleased) {
		if strings.Contains(e, "force-released on ") {
			out = append(out, e)
		}
	}
	return out
}

// delEventIndex is the position of the first Event with reason, or -1.
func delEventIndex(r *recorder, reason string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	for i, e := range r.events {
		if strings.Contains(e, " "+reason+" ") {
			return i
		}
	}
	return -1
}

func delSharedFabric(t *testing.T) *fabricv1.Fabric {
	t.Helper()
	f := &fabricv1.Fabric{}
	must(t, k8s.Get(context.Background(), client.ObjectKey{Namespace: nsSystem, Name: sharedFabric}, f))
	return f
}

// delFindingsOf are the shared Fabric's findings naming the service uid.
func delFindingsOf(t *testing.T, uid types.UID) []fabricv1.Finding {
	t.Helper()
	var out []fabricv1.Finding
	for _, fd := range delSharedFabric(t).Status.Findings {
		if fd.Service.UID == string(uid) {
			out = append(out, fd)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Node < out[j].Node })
	return out
}

// delResetFabricAtCleanup puts the shared Fabric's status back (no findings, no rendered
// Configs, no lastVerifiedTime) and removes any priority-10 Config a Fabric reconciler wrote.
func delResetFabricAtCleanup(t *testing.T) {
	t.Cleanup(func() {
		ctx := context.Background()
		l := &configv1alpha1.ConfigList{}
		if err := k8s.List(ctx, l, client.InNamespace(nsSystem), client.MatchingLabels{sdc.LabelFabricName: sharedFabric}); err == nil {
			for i := range l.Items {
				_ = k8s.Delete(ctx, &l.Items[i])
			}
		}
		f := &fabricv1.Fabric{}
		if err := k8s.Get(ctx, client.ObjectKey{Namespace: nsSystem, Name: sharedFabric}, f); err == nil {
			f.Status = fabricv1.FabricStatus{}
			_ = k8s.Status().Update(ctx, f)
		}
		restoreFabric(t)
	})
}

func delHasFinalizer(h *harness) bool {
	return controllerutil.ContainsFinalizer(h.network(), network.Finalizer)
}

// ---------------------------------------------------------------------------
// A Fabric reconciler over the shared Fabric, with its own fakes.
// ---------------------------------------------------------------------------

// delFabricClaims binds every underlay claim at once (the stated value, or a generated one).
type delFabricClaims struct {
	mu     sync.Mutex
	claims map[string]kuid.Claimed
	next   int
}

func (f *delFabricClaims) Claim(ctx context.Context, req kuid.Request) (kuid.Claimed, error) {
	return f.make(req, "")
}

func (f *delFabricClaims) ClaimValue(ctx context.Context, req kuid.Request, v string) (kuid.Claimed, error) {
	return f.make(req, v)
}

func (f *delFabricClaims) make(req kuid.Request, v string) (kuid.Claimed, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if c, ok := f.claims[req.Namespace+"/"+req.Name]; ok {
		return c, nil
	}
	c := kuid.Claimed{Ref: req.Ref, Index: req.Index, Labels: req.Labels, Stated: v, Ready: true, Value: v}
	if v == "" {
		f.next++
		switch {
		case req.CreatePrefix:
			c.Value = fmt.Sprintf("10.1.0.%d/31", (f.next-1)*2)
		case req.Kind == kuid.KindIP:
			c.Value = fmt.Sprintf("10.0.0.%d/32", 100+f.next)
		default:
			c.Value = fmt.Sprintf("%d", 65200+f.next)
		}
	}
	f.claims[req.Namespace+"/"+req.Name] = c
	return c, nil
}

func (f *delFabricClaims) Release(ctx context.Context, ref kuid.Ref) error { return nil }

func (f *delFabricClaims) Get(ctx context.Context, ref kuid.Ref) (kuid.Claimed, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if c, ok := f.claims[ref.Namespace+"/"+ref.Name]; ok {
		return c, nil
	}
	return kuid.Claimed{}, fmt.Errorf("%s: %w", ref, kuid.ErrNotFound)
}

func (f *delFabricClaims) ListByLabel(context.Context, kuid.Kind, string, map[string]string) ([]kuid.Claimed, error) {
	return nil, nil
}

func (f *delFabricClaims) Index(k kuid.Kind) kuid.IndexType { return kuid.NewUpstream(nil).Index(k) }
func (f *delFabricClaims) Authority() string                { return kuid.AuthorityKuid }

// delFabricVerifier is the Fabric read-back: it cannot run while any of its nodes is marked
// down, and reports every finding it is given cleared when clean is set (every named object
// read absent from both datastores).
type delFabricVerifier struct {
	mu    sync.Mutex
	down  map[string]bool
	clean bool
	calls int
	last  verify.FabricInput
}

func (v *delFabricVerifier) VerifyFabric(ctx context.Context, in verify.FabricInput) (verify.FabricResult, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.calls++
	v.last = in
	causes := map[string]error{}
	for _, n := range in.Nodes {
		if v.down[n.Node] {
			causes[n.Node] = errors.New("connection refused")
		}
	}
	if len(causes) > 0 {
		return verify.FabricResult{}, &verify.CouldNotRunError{Causes: causes}
	}
	res := verify.FabricResult{}
	if v.clean {
		for _, fi := range in.Findings {
			res.ClearedFindings = append(res.ClearedFindings, fi.Index)
		}
	}
	return res, nil
}

func (v *delFabricVerifier) set(node string, down bool) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.down == nil {
		v.down = map[string]bool{}
	}
	v.down[node] = down
}

func (v *delFabricVerifier) setClean(c bool) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.clean = c
}

type delFabricRenderer struct{}

func (delFabricRenderer) RenderFabric(m *model.FabricModel) (map[string]fabric.Rendered, error) {
	out := map[string]fabric.Rendered{}
	for _, n := range m.Nodes {
		b, err := json.Marshal(map[string]any{"srl_nokia-interfaces:interface": []any{map[string]any{"name": "system0", "admin-state": "enable"}},
			"x-node": n.Name, "x-system": n.SystemIPv4})
		if err != nil {
			return nil, err
		}
		sum := sha256.Sum256(b)
		out[n.Name] = fabric.Rendered{Node: n.Name, JSON: b, Hash: hex.EncodeToString(sum[:])}
	}
	return out, nil
}

type delFabricHarness struct {
	t      *testing.T
	r      *fabric.Reconciler
	clock  *clocktesting.FakeClock
	verify *delFabricVerifier
	rec    *recorder
}

// newDelFabricHarness is a Fabric reconciler over the shared Fabric; the Fabric's Configs and
// status are put back at cleanup.
func newDelFabricHarness(t *testing.T) *delFabricHarness {
	delResetFabricAtCleanup(t)
	h := &delFabricHarness{t: t, clock: clocktesting.NewFakeClock(t0), verify: &delFabricVerifier{}, rec: &recorder{}}
	h.r = &fabric.Reconciler{Client: k8s, SDC: sdc.New(k8s), Claims: &delFabricClaims{claims: map[string]kuid.Claimed{}},
		Renderer: delFabricRenderer{}, Verifier: h.verify, Telemetry: &fakeTelemetry{ok: true}, Compat: lockSet,
		Recorder: h.rec, Clock: h.clock, Settings: fabric.DefaultSettings()}
	return h
}

func (h *delFabricHarness) reconcile() ctrl.Result {
	h.t.Helper()
	res, err := h.r.Reconcile(context.Background(), ctrl.Request{NamespacedName: types.NamespacedName{Namespace: nsSystem, Name: sharedFabric}})
	if err != nil {
		h.t.Fatalf("reconcile Fabric: %v", err)
	}
	return res
}

func (h *delFabricHarness) wantCond(typ string, st metav1.ConditionStatus, reason string, msgHas ...string) {
	h.t.Helper()
	var c *metav1.Condition
	for _, x := range delSharedFabric(h.t).Status.Conditions {
		if x.Type == typ {
			x := x
			c = &x
		}
	}
	if c == nil {
		h.t.Fatalf("Fabric: no %s condition", typ)
	}
	if c.Status != st || (reason != "" && c.Reason != reason) {
		h.t.Fatalf("Fabric: %s=%s/%s (%s), want %s/%s", typ, c.Status, c.Reason, c.Message, st, reason)
	}
	for _, s := range msgHas {
		if !strings.Contains(c.Message, s) {
			h.t.Fatalf("Fabric: %s message %q lacks %q", typ, c.Message, s)
		}
	}
}

// converge renders the shared Fabric, confirms its Configs as the layer would, and reads it
// back to Ready=True.
func (h *delFabricHarness) converge() {
	h.t.Helper()
	h.reconcile()
	l := &configv1alpha1.ConfigList{}
	must(h.t, k8s.List(context.Background(), l, client.InNamespace(nsSystem), client.MatchingLabels{sdc.LabelFabricName: sharedFabric}))
	if len(l.Items) != len(allNodes) {
		h.t.Fatalf("the Fabric reconciler wrote %d Configs, want %d", len(l.Items), len(allNodes))
	}
	for i := range l.Items {
		c := &l.Items[i]
		c.Status.Conditions = []condv1alpha1.Condition{layerCond(condv1alpha1.ConditionTypeReady, metav1.ConditionTrue, "Ready", c.Generation)}
		must(h.t, k8s.Status().Update(context.Background(), c))
	}
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

// Every target reachable: Ready=False/Deleting is written before the first Config is removed,
// beside Deleting=True/RemovingConfiguration while the removal is not yet read back; the
// re-verification requeue drives only the finalizer — no read-back runs, Unknown is never set;
// the force-release annotation on this deleting object with every target reachable is ignored
// with an Event and releases nothing; the removal read back, every claim is released and the
// object goes (Rule 8 steps 1, 5, 6, 7; FR-103, FR-107, AD-49, AD-53).
func TestDeletionAllReachableReadyDeletingFirst(t *testing.T) {
	h := newHarness(t, nsServices, "del-reachable")
	h.converge(macvrfSpec(410, 10410, att("leaf01", "ethernet-1/1", 410), att("leaf02", "ethernet-1/1", 410)))
	if h.claims.count() != 1 {
		t.Fatalf("%d claims, want the created l2vni", h.claims.count())
	}
	observed := delObserveFirstConfigDelete(h)
	holdConfig(t, h.name+".leaf02")
	verifies := h.verify.count()
	h.delete()

	res := delStep(h)
	if seen, ready := observed(); !seen || ready != "False/Deleting" {
		t.Fatalf("at the first Config delete Ready was %q (seen %v): Ready=False/Deleting must be written before anything is removed", ready, seen)
	}
	h.wantCond("Deleting", metav1.ConditionTrue, "RemovingConfiguration", h.name+".leaf02")
	// A removal awaiting its read-back is re-checked at the reconciliation interval (the
	// reachability probe is asked again on each pass; live-findings 2026-09-24-delete-unreachable).
	if res.RequeueAfter != h.r.Settings.ReconcileInterval {
		t.Fatalf("a Network awaiting its removal read-back is requeued at %s, want the reconciliation interval", res.RequeueAfter)
	}

	// The force-release on a deleting object whose every target is reachable: ignored.
	delAnnotate(h, "operator wants it gone now")
	for i := 0; i < 3; i++ {
		h.clock.Step(h.r.Settings.ReverifyInterval)
		if res := delStep(h); res.RequeueAfter != h.r.Settings.ReconcileInterval {
			t.Fatalf("the requeue of an object awaiting its removal read-back is %s, want %s", res.RequeueAfter, h.r.Settings.ReconcileInterval)
		}
	}
	if h.verify.count() != verifies {
		t.Fatalf("%d read-backs ran on a deleting object; none may (AD-53)", h.verify.count()-verifies)
	}
	if len(delEvents(h.rec, network.EventForceReleaseIgnored)) == 0 {
		t.Fatal("no ForceReleaseIgnored Event for the annotation on a deleting object with every target reachable")
	}
	if len(h.claims.releasedNames()) != 0 || h.claims.count() != 1 || !delHasFinalizer(h) {
		t.Fatalf("released %v, %d claims left, finalizer %v: the ignored force-release released something", h.claims.releasedNames(), h.claims.count(), delHasFinalizer(h))
	}
	if fs := delFindingsOf(t, h.network().UID); len(fs) != 0 {
		t.Fatalf("an ignored force-release recorded findings %+v", fs)
	}

	releaseConfig(t, h.name+".leaf02")
	delStep(h)
	if !h.gone() {
		t.Fatalf("the Network is still there after its removal was read back: %+v", h.cond("Deleting"))
	}
	if h.claims.count() != 0 || len(h.claims.releasedNames()) != 1 {
		t.Fatalf("claims left %d, released %v", h.claims.count(), h.claims.releasedNames())
	}
}

// A target unreachable: Ready=False/Deleting from the first reconcile, before anything is
// removed; the configuration is removed from the reachable target; Deleting=True/
// TargetUnreachable names the target; every claim stays bound — created and adopted, the
// adopted VLAN claim of a mac-vrf from which an attachment carrying that VLAN was removed
// while it lived among them — through any number of re-verification requeues and any length
// of time (no timer); the return of the target completes the removal unaided once the removal
// is read back (Rule 8 steps 1, 5, 6; FR-103, AD-32, AD-51, AD-53, AD-61).
func TestDeletionTargetUnreachableHoldsEveryClaim(t *testing.T) {
	h := newHarness(t, nsIntent, "migr-del-unreach")
	const cid = "del-unreach-cid"
	h.claims.seed(kuid.KindVLAN, claimName(nsIntent, h.name, "vlan-bd"), "1380", tierLabels(cid))
	h.claims.seed(kuid.KindGENID, claimName(nsIntent, h.name, "l2vni-bd"), "11380", tierLabels(cid))
	h.converge(gatewaySpec(1380, 11380, 11381, "10.138.0.1/24",
		att("leaf01", "ethernet-1/1", 1380), att("leaf01", "ethernet-1/2", 1380), att("leaf02", "ethernet-1/1", 1380)), withCorrelation(cid))

	// An attachment carrying the VLAN is removed while the object lives: the VLAN claim stays.
	h.update(func(n *fabricv1.Network) {
		n.Spec.Attachments = []fabricv1.NetworkAttachment{att("leaf01", "ethernet-1/1", 1380), att("leaf02", "ethernet-1/1", 1380)}
	})
	h.reconcile()
	confirmConfigs(t, h.ns, h.name)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	refs := refsByName(h.network())
	want := map[string]fabricv1.ClaimOrigin{
		claimName(nsIntent, h.name, "vlan-bd"):   fabricv1.ClaimOriginAdopted,
		claimName(nsIntent, h.name, "l2vni-bd"):  fabricv1.ClaimOriginAdopted,
		claimName(nsIntent, h.name, "l3vni-vrf"): fabricv1.ClaimOriginCreated,
	}
	for name, origin := range want {
		if refs[name].Origin != origin {
			t.Fatalf("claimRefs %+v: %s is not %s", refs, name, origin)
		}
	}

	setTarget(t, "leaf02", false)
	holdConfig(t, h.name+".leaf02") // the layer cannot remove it from an unreachable device
	observed := delObserveFirstConfigDelete(h)
	verifies := h.verify.count()
	uid := h.network().UID
	h.delete()

	res := delStep(h)
	if seen, ready := observed(); !seen || ready != "False/Deleting" {
		t.Fatalf("at the first Config delete Ready was %q (seen %v)", ready, seen)
	}
	h.wantCond("Deleting", metav1.ConditionTrue, "TargetUnreachable", "leaf02")
	if c := h.cond("Deleting"); strings.Contains(c.Message, "leaf01") {
		t.Fatalf("TargetUnreachable names a reachable target: %s", c.Message)
	}
	cfgs := h.configs()
	if len(cfgs) != 1 || cfgs[0].Labels[sdc.LabelTargetName] != "leaf02" {
		t.Fatalf("Configs %d: the reachable target's configuration must be removed, the unreachable one's remain", len(cfgs))
	}
	if res.RequeueAfter != h.r.Settings.ReverifyInterval {
		t.Fatalf("requeue %s, want the re-verification interval", res.RequeueAfter)
	}

	holding := func(when string) {
		t.Helper()
		if n := h.claims.count(); n != 3 {
			t.Fatalf("%s: %d claims bound, want all 3", when, n)
		}
		if r := h.claims.releasedNames(); len(r) != 0 {
			t.Fatalf("%s: released %v while a target is unreachable", when, r)
		}
		if got := refsByName(h.network()); len(got) != 3 || got[claimName(nsIntent, h.name, "vlan-bd")].Origin != fabricv1.ClaimOriginAdopted {
			t.Fatalf("%s: claimRefs %+v, want all three with the VLAN claim still adopted", when, got)
		}
		if !delHasFinalizer(h) {
			t.Fatalf("%s: the finalizer is gone", when)
		}
	}
	holding("first pass")
	// No timer: the re-verification requeue only retries the finalizer, for as long as it takes.
	for i, step := range []time.Duration{h.r.Settings.ReverifyInterval, h.r.Settings.ReverifyInterval, 400 * 24 * time.Hour} {
		h.clock.Step(step)
		if res := delStep(h); res.RequeueAfter != h.r.Settings.ReverifyInterval {
			t.Fatalf("pass %d: requeue %s", i, res.RequeueAfter)
		}
		h.wantCond("Deleting", metav1.ConditionTrue, "TargetUnreachable", "leaf02")
		holding(fmt.Sprintf("pass %d after %s", i, step))
	}
	if h.verify.count() != verifies {
		t.Fatal("a read-back ran on a deleting object")
	}

	// The target returns; the layer has not yet removed the configuration: still nothing released.
	setTarget(t, "leaf02", true)
	delStep(h)
	h.wantCond("Deleting", metav1.ConditionTrue, "RemovingConfiguration", h.name+".leaf02")
	holding("target back, removal not yet read back")
	// The removal is read back: completion with no operator action.
	releaseConfig(t, h.name+".leaf02")
	delStep(h)
	if !h.gone() {
		t.Fatalf("not finalized after the removal was read back: %+v", h.cond("Deleting"))
	}
	if h.claims.count() != 0 || len(h.claims.releasedNames()) != 3 {
		t.Fatalf("claims left %d, released %v; want all three released", h.claims.count(), h.claims.releasedNames())
	}
	if fs := delFindingsOf(t, uid); len(fs) != 0 {
		t.Fatalf("findings %+v without a force-release", fs)
	}
}

// Dependency order across objects: a service whose attachment subinterface carries another
// object's standalone access list removes nothing — Deleting=True/HolderPresent naming the
// holder — until that holder is gone, a holder that is itself being deleted still holding; its
// Configs are removed only after (Rule 8 steps 2–4; FR-043).
func TestDeletionOrderHolderPresent(t *testing.T) {
	h := newHarness(t, nsServices, "del-held-svc")
	h.converge(macvrfSpec(420, 10420, att("leaf01", "ethernet-1/2", 420)))
	acl := h.with(nsServices, "del-acl-holder")
	acl.create(aclSpec(att("leaf01", "ethernet-1/2", 420)))
	acl.reconcile() // takes the finalizer; its render is User Story 5's
	if !delHasFinalizer(acl) {
		t.Fatal("the acl object carries no finalizer after its first reconcile")
	}
	var aclGoneAtRemoval []bool
	h.r.SDC = sdc.New(delObservingClient{Client: k8s, onDelete: func(obj client.Object) {
		if _, ok := obj.(*configv1alpha1.Config); ok {
			aclGoneAtRemoval = append(aclGoneAtRemoval, acl.gone())
		}
	}})

	h.delete()
	delStep(h)
	h.wantCond("Deleting", metav1.ConditionTrue, "HolderPresent", "Network "+nsServices+"/del-acl-holder")
	if len(h.configs()) != 1 || len(aclGoneAtRemoval) != 0 {
		t.Fatal("the subinterface owner's configuration was removed while an access-list binding still references it")
	}
	if len(h.claims.releasedNames()) != 0 {
		t.Fatal("claims released while a holder is present")
	}

	// The holder is being deleted: it still holds until it is gone (Rule 8 step 4).
	acl.delete()
	delStep(h)
	h.wantCond("Deleting", metav1.ConditionTrue, "HolderPresent", "del-acl-holder", "being removed")
	if len(h.configs()) != 1 {
		t.Fatal("configuration removed while the deleting holder still holds its binding")
	}
	delStep(acl) // the binding first: the acl object finalizes, it owns no subinterface
	if !acl.gone() {
		t.Fatalf("the acl object did not finalize: %+v", acl.cond("Deleting"))
	}
	delStep(h)
	if !h.gone() || len(h.configs()) != 0 {
		t.Fatalf("the service did not finalize once the holder was gone: %+v", h.cond("Deleting"))
	}
	if len(aclGoneAtRemoval) == 0 || !aclGoneAtRemoval[0] {
		t.Fatalf("the service's Config was removed before the holder was gone: %v", aclGoneAtRemoval)
	}
	if len(h.claims.releasedNames()) != 1 {
		t.Fatalf("released %v, want the l2vni", h.claims.releasedNames())
	}
}

// A Network carrying the finalizer and a deletion timestamp that was never reconciled —
// status.claimRefs empty, its tier claims present under their deterministic names — has them
// adopted first (every lookup before any release) and released after the read-back, none
// orphaned and none created (Rule 8 steps 1 and 6; AD-44).
func TestDeletionNeverReconciledAdoptsFirst(t *testing.T) {
	h := newHarness(t, nsIntent, "migr-del-never")
	const cid = "del-never-cid"
	mine := []string{claimName(nsIntent, h.name, "l2vni-bd"), claimName(nsIntent, h.name, "vlan-bd"), claimName(nsIntent, h.name, "l3vni-vrf")}
	h.claims.seed(kuid.KindGENID, mine[0], "10430", tierLabels(cid))
	h.claims.seed(kuid.KindVLAN, mine[1], "1430", tierLabels(cid))
	h.claims.seed(kuid.KindGENID, mine[2], "10431", tierLabels(cid))
	bystander := claimName(nsIntent, "migr-del-bystander", "l2vni-bd")
	h.claims.seed(kuid.KindGENID, bystander, "10432", tierLabels(cid))
	spy := &delClaimsSpy{Claims: h.claims}
	h.r.Claims = spy
	spy.onRelease = func() {
		if len(spy.ops) == 0 || spy.ops[0] != "list" {
			return
		}
		n := h.network()
		for _, c := range n.Status.Conditions {
			if c.Type == "Ready" {
				spy.readyAtRelease = string(c.Status) + "/" + c.Reason
			}
		}
	}

	h.create(gatewaySpec(1430, 10430, 10431, "10.143.0.1/24", att("leaf01", "ethernet-1/1", 1430)), withCorrelation(cid),
		func(n *fabricv1.Network) { controllerutil.AddFinalizer(n, network.Finalizer) })
	h.delete()
	if len(h.network().Status.ClaimRefs) != 0 {
		t.Fatal("precondition: status.claimRefs must be empty")
	}
	delStep(h)
	if !h.gone() {
		t.Fatalf("not finalized: %+v", h.cond("Deleting"))
	}
	firstRelease := -1
	for i, op := range spy.ops {
		if op == "release" && firstRelease < 0 {
			firstRelease = i
		}
		if op == "list" && firstRelease >= 0 {
			t.Fatalf("an adoption lookup after a release: %v", spy.ops)
		}
	}
	if firstRelease < 0 {
		t.Fatalf("nothing released: %v", spy.ops)
	}
	if spy.readyAtRelease != "False/Deleting" {
		t.Fatalf("Ready at the first release was %q", spy.readyAtRelease)
	}
	if a, r := delEventIndex(h.rec, network.EventClaimAdopted), delEventIndex(h.rec, network.EventClaimReleased); a < 0 || r < 0 || a > r {
		t.Fatalf("ClaimAdopted at %d, ClaimReleased at %d: adoption comes first", a, r)
	}
	released := h.claims.releasedNames()
	sort.Strings(released)
	sort.Strings(mine)
	if strings.Join(released, ",") != strings.Join(mine, ",") {
		t.Fatalf("released %v, want exactly the object's own %v", released, mine)
	}
	if h.claims.createdCount() != 0 {
		t.Fatalf("%d claims created on a deleting object", h.claims.createdCount())
	}
	if _, ok := h.claims.get(kuid.KindGENID, bystander); !ok {
		t.Fatal("another object's claim was released")
	}
	if h.claims.count() != 1 {
		t.Fatalf("%d claims left, want only the bystander's: one of the object's was orphaned", h.claims.count())
	}
}

// delClaimsSpy records the order of the authority calls the finalizer makes.
type delClaimsSpy struct {
	kuid.Claims
	ops            []string
	onRelease      func()
	readyAtRelease string
}

func (s *delClaimsSpy) ListByLabel(ctx context.Context, k kuid.Kind, ns string, l map[string]string) ([]kuid.Claimed, error) {
	s.ops = append(s.ops, "list")
	return s.Claims.ListByLabel(ctx, k, ns, l)
}

func (s *delClaimsSpy) Release(ctx context.Context, ref kuid.Ref) error {
	if s.onRelease != nil && s.readyAtRelease == "" {
		s.onRelease()
	}
	s.ops = append(s.ops, "release")
	return s.Claims.Release(ctx, ref)
}

// The allocation authority ERRORS — on the adoption lookup of step 1, then on the DELETE of
// step 6: the finalizer stays, Deleting=True/RemovingConfiguration names the authority,
// configuration is still removed (steps 2–5 do not wait on it), nothing is adopted from the
// empty answer and nothing is released, across repeated reconciles with bounded backoff; once
// the fake answers, removal completes unaided. An error is never "nothing adoptable" (Rule 8
// steps 1 and 6; AD-56).
func TestDeletionAuthorityErrorKeepsFinalizer(t *testing.T) {
	h := newHarness(t, nsIntent, "migr-del-authority")
	const cid = "del-authority-cid"
	h.claims.seed(kuid.KindVLAN, claimName(nsIntent, h.name, "vlan-bd"), "1440", tierLabels(cid))
	h.claims.seed(kuid.KindGENID, claimName(nsIntent, h.name, "l2vni-bd"), "10440", tierLabels(cid))
	h.converge(gatewaySpec(1440, 10440, 10441, "10.144.0.1/24", att("leaf01", "ethernet-1/1", 1440), att("leaf02", "ethernet-1/1", 1440)), withCorrelation(cid))
	if h.claims.count() != 3 {
		t.Fatalf("%d claims, want 3", h.claims.count())
	}
	// The provider restarted between its apply and its status write: the Configs exist,
	// status.claimRefs is empty, and the claims are the object's own under their names.
	n := h.network()
	n.Status.ClaimRefs = nil
	must(t, k8s.Status().Update(context.Background(), n))
	if len(h.configs()) != 2 {
		t.Fatal("precondition: the Configs exist")
	}

	h.claims.setFail("list", true)
	h.delete()
	var last time.Duration
	for i := 0; i < 3; i++ {
		res := delStep(h)
		h.wantCond("Deleting", metav1.ConditionTrue, "RemovingConfiguration", "allocation authority (kuid)", errAuthority.Error())
		if len(h.configs()) != 0 {
			t.Fatalf("pass %d: configuration not removed while the authority errors (steps 2–5 do not wait on it)", i)
		}
		if refs := h.network().Status.ClaimRefs; len(refs) != 0 {
			t.Fatalf("pass %d: claimRefs %+v adopted from an authority that did not answer", i, refs)
		}
		if r := h.claims.releasedNames(); len(r) != 0 || h.claims.count() != 3 || !delHasFinalizer(h) {
			t.Fatalf("pass %d: released %v, %d claims, finalizer %v", i, r, h.claims.count(), delHasFinalizer(h))
		}
		if res.RequeueAfter <= 0 || res.RequeueAfter > h.r.Settings.BackoffCap || res.RequeueAfter < last {
			t.Fatalf("pass %d: requeue %s, want a bounded exponential backoff (previous %s, cap %s)", i, res.RequeueAfter, last, h.r.Settings.BackoffCap)
		}
		last = res.RequeueAfter
		h.clock.Step(res.RequeueAfter)
	}
	if len(delEvents(h.rec, network.EventTransientError)) == 0 {
		t.Fatal("no TransientError Event for the authority's failure")
	}
	// The force-release is not an exit from an authority that has not answered (AD-56).
	delAnnotate(h, "authority is down, just drop it")
	delStep(h)
	if len(delEvents(h.rec, network.EventForceReleaseIgnored)) == 0 || !delHasFinalizer(h) || len(h.claims.releasedNames()) != 0 {
		t.Fatal("the force-release was honoured while the authority had not answered")
	}

	// The lookup answers; the DELETE of step 6 errors.
	h.claims.setFail("list", false)
	h.claims.setFail("release", true)
	for i := 0; i < 2; i++ {
		res := delStep(h)
		h.wantCond("Deleting", metav1.ConditionTrue, "RemovingConfiguration", "allocation authority (kuid)", errAuthority.Error())
		if refs := h.network().Status.ClaimRefs; len(refs) != 3 {
			t.Fatalf("release pass %d: claimRefs %+v, want the three adopted entries kept", i, refs)
		}
		if h.claims.count() != 3 || !delHasFinalizer(h) {
			t.Fatalf("release pass %d: %d claims, finalizer %v", i, h.claims.count(), delHasFinalizer(h))
		}
		if res.RequeueAfter <= 0 || res.RequeueAfter > h.r.Settings.BackoffCap {
			t.Fatalf("release pass %d: requeue %s, want backoff", i, res.RequeueAfter)
		}
		h.clock.Step(res.RequeueAfter)
	}

	// The authority answers: completion unaided.
	h.claims.setFail("release", false)
	delStep(h)
	if !h.gone() {
		t.Fatalf("not finalized once the authority answered: %+v", h.cond("Deleting"))
	}
	if h.claims.count() != 0 || len(h.claims.releasedNames()) != 3 || h.claims.createdCount() != 1 {
		t.Fatalf("claims left %d, released %v, created %d (only the live l3vni)", h.claims.count(), h.claims.releasedNames(), h.claims.createdCount())
	}
}

// The force-release annotation on a live service is ignored with an Event and releases
// nothing — it is never a way to delete; an empty value is refused (FR-103, AD-49).
func TestDeletionForceReleaseIgnoredOnLive(t *testing.T) {
	h := newHarness(t, nsServices, "del-live")
	h.converge(macvrfSpec(450, 10450, att("leaf01", "ethernet-1/1", 450)))
	delAnnotate(h, "please delete this")
	h.reconcile()
	if len(delEvents(h.rec, network.EventForceReleaseIgnored)) == 0 {
		t.Fatal("no ForceReleaseIgnored Event for the annotation on a live service")
	}
	delAnnotate(h, "   ")
	h.reconcile()
	if len(delEvents(h.rec, network.EventForceReleaseRefused)) == 0 {
		t.Fatal("no ForceReleaseRefused Event for an empty reason")
	}
	n := h.network()
	if n.DeletionTimestamp != nil || !delHasFinalizer(h) || len(h.configs()) != 1 {
		t.Fatal("the force-release on a live service deleted or unpinned something")
	}
	h.wantCond("Ready", metav1.ConditionTrue, "")
	if len(h.claims.releasedNames()) != 0 || h.claims.count() != 1 || len(n.Status.ClaimRefs) != 1 {
		t.Fatalf("released %v on a live service", h.claims.releasedNames())
	}
	if fs := delFindingsOf(t, n.UID); len(fs) != 0 {
		t.Fatalf("findings %+v for a live service", fs)
	}
}

// The force-release on an object blocked on TargetUnreachable, while the target is away and
// the Fabric reads Ready=Unknown with its one Degraded condition at VerificationFailed: an
// empty reason is refused with zero identifiers released; a stated one records a durable
// finding naming the service, the device, every identifier and the rendered object names,
// publishes a Warning Event, releases every claim and removes the finalizer. The finding is
// present during the outage beside the Fabric's VerificationFailed; at the first pass after
// the target returns the Fabric is Ready=True with Degraded=True/StaleConfigurationPossible;
// while it is open a render that would produce one of its objects on that node is refused
// Applied=False/OwnershipConflict naming it; it clears only after a clean scheduled read-back,
// and the refused render then proceeds with no action on it (FR-103, CD-02, AD-54, R-39).
func TestDeletionForceReleaseFindingLifecycle(t *testing.T) {
	fh := newDelFabricHarness(t)
	fh.converge()

	h := newHarness(t, nsServices, "del-stale")
	const cid = "del-stale-cid"
	h.claims.seed(kuid.KindVLAN, claimName(nsServices, h.name, "vlan-bd"), "1460", tierLabels(cid))
	h.converge(gatewaySpec(1460, 11460, 11461, "10.146.0.1/24", att("leaf01", "ethernet-1/1", 1460), att("leaf02", "ethernet-1/1", 1460)), withCorrelation(cid))
	uid := h.network().UID
	if h.claims.count() != 3 {
		t.Fatalf("%d claims, want 3", h.claims.count())
	}

	// leaf02 goes away: the Fabric reads Ready=Unknown, Degraded=VerificationFailed.
	setTarget(t, "leaf02", false)
	fh.verify.set("leaf02", true)
	fh.reconcile()
	fh.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed", "leaf02")
	fh.wantCond("Degraded", metav1.ConditionTrue, "VerificationFailed", "leaf02")

	holdConfig(t, h.name+".leaf02")
	h.delete()
	delStep(h)
	h.wantCond("Deleting", metav1.ConditionTrue, "TargetUnreachable", "leaf02")

	// An empty reason: refused, nothing released, no finding.
	delAnnotate(h, "")
	delStep(h)
	h.wantCond("Deleting", metav1.ConditionTrue, "TargetUnreachable", "leaf02")
	if len(delEvents(h.rec, network.EventForceReleaseRefused)) == 0 {
		t.Fatal("no ForceReleaseRefused Event for an empty reason")
	}
	if len(h.claims.releasedNames()) != 0 || h.claims.count() != 3 || !delHasFinalizer(h) || len(delFindingsOf(t, uid)) != 0 {
		t.Fatalf("the empty-reason force-release released %v / recorded %d findings", h.claims.releasedNames(), len(delFindingsOf(t, uid)))
	}

	// A stated reason: honoured.
	const why = "leaf02 chassis failed; RMA opened"
	delAnnotate(h, why)
	delStep(h)
	if !h.gone() {
		t.Fatalf("the force-released Network is still there: %+v", h.cond("Deleting"))
	}
	if h.claims.count() != 0 || len(h.claims.releasedNames()) != 3 {
		t.Fatalf("claims left %d, released %v, want all three", h.claims.count(), h.claims.releasedNames())
	}
	evs := delForceReleasedEvents(h.rec)
	if len(evs) != 1 || !strings.HasPrefix(evs[0], "Warning ") || !strings.Contains(evs[0], "leaf02") || !strings.Contains(evs[0], "stale") {
		t.Fatalf("ForceReleased Events %v, want one Warning naming leaf02 and the stale configuration", evs)
	}
	fs := delFindingsOf(t, uid)
	if len(fs) != 1 {
		t.Fatalf("findings %+v, want one for (service, leaf02)", fs)
	}
	fd := fs[0]
	if fd.Type != fabricv1.FindingStaleConfigurationPossible || fd.Node != "leaf02" || fd.Reason != why || fd.RecordedAt.IsZero() ||
		fd.Service != (fabricv1.ServiceRef{Namespace: nsServices, Name: h.name, UID: string(uid)}) {
		t.Fatalf("finding %+v", fd)
	}
	ids := map[string]fabricv1.ReleasedIdentifier{}
	for _, id := range fd.Identifiers {
		ids[id.Kind] = id
	}
	if len(fd.Identifiers) != 3 || ids["vlan"].Value != "1460" || ids["vlan"].Index != vlanIndex ||
		ids["l2vni"].Value != "11460" || ids["l2vni"].Index != vniIndex || ids["l3vni"].Value != "11461" {
		t.Fatalf("finding identifiers %+v", fd.Identifiers)
	}
	objs := strings.Join(fd.DeviceObjects, ",")
	for _, o := range []string{"macvrf-" + h.name, "ipvrf-" + h.name, "ethernet-1/1.1460", "irb0.1460", "vxlan0."} {
		if !strings.Contains(objs, o) {
			t.Fatalf("finding deviceObjects %v lack %s", fd.DeviceObjects, o)
		}
	}

	// During the outage: the finding is visible while the one Degraded reason is VerificationFailed.
	fh.clock.Step(fh.r.Settings.ReverifyInterval)
	fh.reconcile()
	fh.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed")
	fh.wantCond("Degraded", metav1.ConditionTrue, "VerificationFailed")
	if len(delFindingsOf(t, uid)) != 1 {
		t.Fatal("the finding is not visible during the outage")
	}

	// The target returns (the layer removes the deleted Config): the first pass is Ready=True
	// with Degraded=StaleConfigurationPossible, the finding still open.
	setTarget(t, "leaf02", true)
	releaseConfig(t, h.name+".leaf02")
	fh.verify.set("leaf02", false)
	fh.reconcile()
	fh.wantCond("Ready", metav1.ConditionTrue, "")
	fh.wantCond("Degraded", metav1.ConditionTrue, "StaleConfigurationPossible", h.name, "leaf02")
	if len(delFindingsOf(t, uid)) != 1 {
		t.Fatal("the finding cleared without a clean read-back")
	}

	// While it is open, a render that would produce one of its objects on leaf02 is refused.
	col := h.with(nsServices, "del-collide")
	h.claims.seed(kuid.KindVLAN, claimName(nsServices, col.name, "vlan-v"), "1460", tierLabels("del-collide-cid"))
	col.create(vlanSpec(1460, att("leaf02", "ethernet-1/1", 1460)), withCorrelation("del-collide-cid"))
	res := col.reconcile()
	col.wantCond("Applied", metav1.ConditionFalse, "OwnershipConflict", "force-release finding", h.name, "leaf02", "ethernet-1/1.1460")
	col.wantCond("Ready", metav1.ConditionFalse, "NotConverged")
	if len(col.configs()) != 0 {
		t.Fatal("a Config was written for a render colliding with an open finding")
	}
	if res.RequeueAfter != col.r.Settings.ReconcileInterval {
		t.Fatalf("the refusal is requeued at %s; it is not terminal and ends with the finding", res.RequeueAfter)
	}

	// A pass that ran but read the objects present keeps the finding; a clean read that is
	// not a scheduled pass does not run at all.
	fh.clock.Step(fh.r.Settings.ReverifyInterval)
	fh.reconcile()
	if len(delFindingsOf(t, uid)) != 1 {
		t.Fatal("the finding cleared on a read-back that was not clean")
	}
	fh.verify.setClean(true)
	fh.reconcile() // no pass due
	if len(delFindingsOf(t, uid)) != 1 {
		t.Fatal("the finding cleared with no scheduled read-back")
	}
	col.reconcile()
	col.wantCond("Applied", metav1.ConditionFalse, "OwnershipConflict", "force-release finding")

	// The clean scheduled read-back clears it, with an Event; the Fabric's Degraded clears.
	fh.clock.Step(fh.r.Settings.ReverifyInterval)
	fh.reconcile()
	if len(delFindingsOf(t, uid)) != 0 {
		t.Fatal("a clean scheduled read-back left the finding")
	}
	if !fh.rec.has(fabric.EventFindingCleared) {
		t.Fatal("no FindingCleared Event")
	}
	fh.wantCond("Ready", metav1.ConditionTrue, "")
	fh.wantCond("Degraded", metav1.ConditionFalse, "")

	// The refused render proceeds with no action on it.
	col.reconcile()
	col.notCond("Applied", "OwnershipConflict")
	if len(col.configs()) != 1 {
		t.Fatalf("%d Configs for the render once the finding cleared, want 1", len(col.configs()))
	}
}

// The never-returning target: two targets unreachable are each named individually; removing
// one device from the Fabric inventory completes nothing and releases nothing — the object
// stays blocked naming it; the force-release annotation set AFTER the device left the
// inventory (a metadata-only UPDATE, admitted unread — T056) is honoured: one finding per
// service and device, a Warning Event per finding, every claim released, the finalizer removed
// (FR-103, AD-61, AD-71).
func TestDeletionNeverReturningTarget(t *testing.T) {
	h := newHarness(t, nsServices, "del-lost")
	h.converge(macvrfSpec(470, 10470, att("leaf01", "ethernet-1/2", 470), att("leaf02", "ethernet-1/2", 470)))
	uid := h.network().UID
	t.Cleanup(func() {
		f := delSharedFabric(t)
		var keep []fabricv1.Finding
		for _, fd := range f.Status.Findings {
			if fd.Service.UID != string(uid) {
				keep = append(keep, fd)
			}
		}
		f.Status.Findings = keep
		_ = k8s.Status().Update(context.Background(), f)
	})
	setTarget(t, "leaf01", false)
	setTarget(t, "leaf02", false)
	holdConfig(t, h.name+".leaf01")
	holdConfig(t, h.name+".leaf02")
	h.delete()
	delStep(h)
	h.wantCond("Deleting", metav1.ConditionTrue, "TargetUnreachable", "leaf01 (", "leaf02 (")

	// The device leaves the Fabric: nothing completes, nothing is released.
	updateFabric(t, func(f *fabricv1.Fabric) {
		var nodes []fabricv1.FabricNode
		for _, n := range f.Spec.Nodes {
			if n.Name != "leaf02" {
				nodes = append(nodes, n)
			}
		}
		var inv []fabricv1.InventoryEntry
		for _, e := range f.Spec.Inventory {
			if e.Node != "leaf02" {
				inv = append(inv, e)
			}
		}
		f.Spec.Nodes, f.Spec.Inventory = nodes, inv
	})
	for i := 0; i < 3; i++ {
		h.clock.Step(30 * 24 * time.Hour)
		if res := delStep(h); res.RequeueAfter != h.r.Settings.ReverifyInterval {
			t.Fatalf("requeue %s", res.RequeueAfter)
		}
		h.wantCond("Deleting", metav1.ConditionTrue, "TargetUnreachable", "leaf01 (", "leaf02 (")
		if len(h.claims.releasedNames()) != 0 || h.claims.count() != 1 || !delHasFinalizer(h) {
			t.Fatalf("the device's removal from the Fabric released %v", h.claims.releasedNames())
		}
	}
	if len(delFindingsOf(t, uid)) != 0 {
		t.Fatal("a finding without a force-release")
	}

	// The operator's force-release, set after the device left the inventory.
	delAnnotate(h, "leaf02 decommissioned; leaf01 isolated for rebuild")
	delStep(h)
	if !h.gone() {
		t.Fatalf("not finalized by the force-release: %+v", h.cond("Deleting"))
	}
	fs := delFindingsOf(t, uid)
	if len(fs) != 2 || fs[0].Node != "leaf01" || fs[1].Node != "leaf02" {
		t.Fatalf("findings %+v, want one per unreachable device (leaf01, leaf02)", fs)
	}
	for _, fd := range fs {
		if len(fd.Identifiers) != 1 || fd.Identifiers[0].Kind != "l2vni" || fd.Identifiers[0].Value != "10470" {
			t.Fatalf("finding %s identifiers %+v", fd.Node, fd.Identifiers)
		}
		objs := strings.Join(fd.DeviceObjects, ",")
		if !strings.Contains(objs, "macvrf-"+h.name) || !strings.Contains(objs, "ethernet-1/2.470") {
			t.Fatalf("finding %s deviceObjects %v", fd.Node, fd.DeviceObjects)
		}
	}
	if evs := delForceReleasedEvents(h.rec); len(evs) != 2 {
		t.Fatalf("ForceReleased Events %v, want one per finding", evs)
	}
	if h.claims.count() != 0 || len(h.claims.releasedNames()) != 1 {
		t.Fatalf("claims left %d, released %v", h.claims.count(), h.claims.releasedNames())
	}
}

// delReach is a fake data-path reachability probe (verify.CollectorReader.Unreachable).
type delReach struct {
	mu     sync.Mutex
	stale  map[string]string
	err    error
	asked  [][]string
	maxAge time.Duration
}

func (d *delReach) Unreachable(_ context.Context, nodes []string, maxAge time.Duration, _ time.Time) (map[string]string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.asked = append(d.asked, append([]string(nil), nodes...))
	d.maxAge = maxAge
	if d.err != nil {
		return nil, d.err
	}
	out := map[string]string{}
	for _, n := range nodes {
		if why, ok := d.stale[n]; ok {
			out[n] = why
		}
	}
	return out, nil
}

func (d *delReach) set(stale map[string]string, err error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.stale, d.err = stale, err
}

// The pinned layer keeps a Target Ready for minutes after a management cut (observed live
// 2026-09-24 in SC-043's force run: Target leaf02 Ready throughout while the data server's
// deletion transaction timed out dialling it). A node whose Config is still listed and whose
// collector samples have stopped is unreachable all the same: Deleting=True/TargetUnreachable
// naming it, every claim held, and a stated force-release honoured. A probe that errors answers
// nothing (RemovingConfiguration, never TargetUnreachable on a guess), and a fresh node whose
// Config is merely slow to go is pending, not unreachable (FR-103, live-findings
// 2026-09-24-delete-unreachable).
func TestDeletionTargetReadyButUnreadable(t *testing.T) {
	delResetFabricAtCleanup(t)
	h := newHarness(t, nsServices, "del-unreadable")
	reach := &delReach{}
	h.r.Reachability = reach
	h.converge(macvrfSpec(470, 10470, att("leaf01", "ethernet-1/1", 470), att("leaf02", "ethernet-1/1", 470)))
	uid := h.network().UID
	if h.claims.count() != 1 {
		t.Fatalf("%d claims, want the L2VNI claim", h.claims.count())
	}
	t.Cleanup(func() { releaseConfig(t, h.name+".leaf02") })

	// The Target stays Ready; the layer cannot remove the Config from leaf02.
	holdConfig(t, h.name+".leaf02")
	h.delete()

	// Negative control 1: the probe finds leaf02 fresh — the Config is pending, not unreachable.
	delStep(h)
	h.wantCond("Deleting", metav1.ConditionTrue, "RemovingConfiguration", h.name+".leaf02")
	if len(reach.asked) == 0 || strings.Join(reach.asked[len(reach.asked)-1], ",") != "leaf02" {
		t.Fatalf("the probe was asked %v, want only the node whose Config is still listed", reach.asked)
	}
	if reach.maxAge != network.ReachabilityMaxAge {
		t.Fatalf("maxAge %s, want %s", reach.maxAge, network.ReachabilityMaxAge)
	}
	// Negative control 2: a probe that errors is not an answer.
	reach.set(nil, fmt.Errorf("collector down"))
	delStep(h)
	h.wantCond("Deleting", metav1.ConditionTrue, "RemovingConfiguration")
	delAnnotate(h, "leaf02 unreachable: stated")
	delStep(h)
	if h.gone() || len(h.claims.releasedNames()) != 0 || len(delFindingsOf(t, uid)) != 0 {
		t.Fatal("a force-release was honoured on an object not blocked on TargetUnreachable")
	}
	delAnnotate(h, "")

	// The collector has no sample from leaf02: TargetUnreachable naming it, everything held.
	reach.set(map[string]string{"leaf02": "no sample from leaf02 in the device metric collector"}, nil)
	res := delStep(h)
	h.wantCond("Deleting", metav1.ConditionTrue, "TargetUnreachable", "leaf02", "no sample from leaf02")
	h.wantCond("Ready", metav1.ConditionFalse, "Deleting")
	if c := h.cond("Deleting"); strings.Contains(c.Message, "leaf01") {
		t.Fatalf("TargetUnreachable names a reachable target: %s", c.Message)
	}
	if res.RequeueAfter != h.r.Settings.ReverifyInterval {
		t.Fatalf("requeue %s, want the re-verification interval", res.RequeueAfter)
	}
	if h.claims.count() != 1 || len(h.claims.releasedNames()) != 0 || !delHasFinalizer(h) {
		t.Fatal("a claim was released or the finalizer removed while leaf02 is unreadable")
	}

	// A stated force-release is honoured on it.
	delAnnotate(h, "leaf02 unreachable: stated")
	delStep(h)
	if !h.gone() {
		t.Fatalf("the force-released Network is still there: %+v", h.cond("Deleting"))
	}
	if h.claims.count() != 0 || len(h.claims.releasedNames()) != 1 {
		t.Fatalf("claims left %d, released %v", h.claims.count(), h.claims.releasedNames())
	}
	if evs := delForceReleasedEvents(h.rec); len(evs) != 1 || !strings.Contains(evs[0], "leaf02") {
		t.Fatalf("ForceReleased Events %v", evs)
	}
	if fs := delFindingsOf(t, uid); len(fs) != 1 || fs[0].Node != "leaf02" {
		t.Fatalf("findings %+v, want one naming leaf02", fs)
	}
}
