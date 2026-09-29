//go:build envtest

// T028: the Fabric reconciler (T040) against a real API server (envtest), with
// the device-configuration layer's own CRDs installed and a test standing in
// for the layer (it sets Target, Schema and Config status), a fake pkg/kuid
// Claims (the allocation authority is an aggregated API with no CRDs), a fake
// read-back behind the reconciler's Verifier interface, a fake telemetry-health
// input and a fake clock.
//
// Run: make test-envtest (scripts/ci/test_envtest.sh → go test -tags envtest
// ./tests/envtest/...).
//
// Upstream CRDs: config.sdcio.dev Config/Target/Deviation/RunningConfig from
// config-server/crds/ and inv.sdcio.dev Schema from config-server/artifacts/,
// read unchanged from the checked-out v0.0.58 sources. One in-memory fix is
// made and only here: crds/config.sdcio.dev_targets.yaml marks BOTH its
// versions `storage: true`, which an API server refuses; the internal `config`
// version is set storage=false before installing (the file is never edited).
package fabric_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	condv1alpha1 "github.com/sdcio/config-server/apis/condition/v1alpha1"
	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	invv1alpha1 "github.com/sdcio/config-server/apis/inv/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	clocktesting "k8s.io/utils/clock/testing"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/yaml"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/controllers/fabric"
	"github.com/mairp/agentic-netops-srl/internal/compat"
	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/verify"
	"github.com/mairp/agentic-netops-srl/pkg/kuid"
	"github.com/mairp/agentic-netops-srl/pkg/sdc"
)

const (
	nsSystem   = "agentic-netops-system"
	nsServices = "agentic-netops-services"
	nsKuid     = "kuid-system"
	// nsTargets holds the layer's Targets and Schemas: Targets and everything they use live in
	// agentic-netops-system because config-server v0.0.58 lists them in the Target's namespace
	// (AD-82 decision 2026-09-21-target-namespace).
	nsTargets = nsSystem
)

var (
	restCfg  *rest.Config
	k8s      client.Client
	scheme   *k8sruntime.Scheme
	repoRoot string
	lockSet  *compat.Set
	nodes    = []string{"leaf01", "leaf02", "spine01", "spine02"}
	t0       = time.Date(2026, 9, 21, 10, 0, 0, 0, time.UTC)
)

func TestMain(m *testing.M) {
	_, file, _, _ := runtime.Caller(0)
	repoRoot = filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	var err error
	if lockSet, err = compat.Load(filepath.Join(repoRoot, "versions.lock.yaml")); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	crds, err := upstreamCRDs()
	if err != nil {
		fmt.Fprintln(os.Stderr, "envtest: upstream CRDs:", err)
		os.Exit(1)
	}
	env := &envtest.Environment{
		CRDDirectoryPaths:     []string{filepath.Join(repoRoot, "config", "crd")},
		CRDs:                  crds,
		ErrorIfCRDPathMissing: true,
	}
	cfg, err := env.Start()
	if err != nil {
		fmt.Fprintf(os.Stderr, "envtest: starting the control plane (is KUBEBUILDER_ASSETS set?): %v\n", err)
		os.Exit(1)
	}
	restCfg = cfg
	code := func() int {
		scheme = k8sruntime.NewScheme()
		for _, add := range []func(*k8sruntime.Scheme) error{clientgoscheme.AddToScheme, fabricv1.AddToScheme, sdc.AddToScheme} {
			if err := add(scheme); err != nil {
				fmt.Fprintln(os.Stderr, err)
				return 1
			}
		}
		if k8s, err = client.New(cfg, client.Options{Scheme: scheme}); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		ctx := context.Background()
		for _, ns := range []string{nsSystem, nsServices, nsKuid} {
			if err := k8s.Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: ns}}); err != nil {
				fmt.Fprintln(os.Stderr, err)
				return 1
			}
		}
		if err := createLayerObjects(ctx); err != nil {
			fmt.Fprintln(os.Stderr, "envtest: layer objects:", err)
			return 1
		}
		return m.Run()
	}()
	_ = env.Stop()
	os.Exit(code)
}

func upstreamCRDs() ([]*apiextensionsv1.CustomResourceDefinition, error) {
	files := []string{
		"config-server/crds/config.sdcio.dev_configs.yaml",
		"config-server/crds/config.sdcio.dev_targets.yaml",
		"config-server/crds/config.sdcio.dev_deviations.yaml",
		"config-server/crds/config.sdcio.dev_runningconfigs.yaml",
		"config-server/artifacts/inv.sdcio.dev_schemas.yaml",
	}
	var out []*apiextensionsv1.CustomResourceDefinition
	for _, f := range files {
		b, err := os.ReadFile(filepath.Join(repoRoot, f))
		if err != nil {
			return nil, err
		}
		crd := &apiextensionsv1.CustomResourceDefinition{}
		if err := yaml.Unmarshal(b, crd); err != nil {
			return nil, fmt.Errorf("%s: %w", f, err)
		}
		storage := 0
		for _, v := range crd.Spec.Versions {
			if v.Storage {
				storage++
			}
		}
		if storage > 1 {
			for i := range crd.Spec.Versions {
				crd.Spec.Versions[i].Storage = crd.Spec.Versions[i].Name == "v1alpha1"
			}
		}
		out = append(out, crd)
	}
	return out, nil
}

// ---------------------------------------------------------------------------
// The test standing in for the device-configuration layer.
// ---------------------------------------------------------------------------

func cond(typ condv1alpha1.ConditionType, st metav1.ConditionStatus, reason string, gen int64) condv1alpha1.Condition {
	return condv1alpha1.Condition{Condition: metav1.Condition{Type: string(typ), Status: st, Reason: reason,
		Message: reason, LastTransitionTime: metav1.Now(), ObservedGeneration: gen}}
}

func createLayerObjects(ctx context.Context) error {
	sc := &invv1alpha1.Schema{ObjectMeta: metav1.ObjectMeta{Name: "srl.nokia.sdcio.dev-25.7.1", Namespace: nsTargets}}
	sc.Spec.Provider, sc.Spec.Version = lockSet.Schema.Provider, lockSet.Schema.Version
	for i, r := range lockSet.Schema.Repositories {
		// the Schema states where it loads the repository from: its mirror when
		// the lock names one (AD-75)
		r := r.LoadedFrom()
		rep := &invv1alpha1.SchemaSpecRepository{}
		rep.RepoURL, rep.Kind, rep.Ref = r.RepoURL, invv1alpha1.BranchTagKind(r.Kind), r.Ref
		if i == 0 {
			rep.Schema = invv1alpha1.SchemaSpecSchema{Models: lockSet.Schema.Models, Includes: lockSet.Schema.Includes, Excludes: lockSet.Schema.Excludes}
		}
		sc.Spec.Repositories = append(sc.Spec.Repositories, rep)
	}
	if err := k8s.Create(ctx, sc); err != nil {
		return err
	}
	for _, n := range nodes {
		tg := &configv1alpha1.Target{ObjectMeta: metav1.ObjectMeta{Name: n, Namespace: nsTargets}}
		tg.Spec.Provider = lockSet.Schema.Provider
		tg.Spec.Address = "172.25.25.1:57400"
		tg.Spec.ConnectionProfile = "gnmi-tls"
		tg.Spec.Credentials = "srl-credentials"
		if err := k8s.Create(ctx, tg); err != nil {
			return err
		}
	}
	return nil
}

func setSchemaReady(t *testing.T, ready bool) {
	t.Helper()
	sc := &invv1alpha1.Schema{}
	must(t, k8s.Get(context.Background(), client.ObjectKey{Namespace: nsTargets, Name: "srl.nokia.sdcio.dev-25.7.1"}, sc))
	st := metav1.ConditionFalse
	if ready {
		st = metav1.ConditionTrue
	}
	sc.SetConditions(cond(condv1alpha1.ConditionTypeReady, st, "Ready", 0))
	must(t, k8s.Status().Update(context.Background(), sc))
}

func setTarget(t *testing.T, node string, ready bool) {
	t.Helper()
	tg := &configv1alpha1.Target{}
	must(t, k8s.Get(context.Background(), client.ObjectKey{Namespace: nsTargets, Name: node}, tg))
	st, reason := metav1.ConditionTrue, "Ready"
	if !ready {
		st, reason = metav1.ConditionFalse, "Failed"
	}
	tg.SetConditions(
		cond(condv1alpha1.ConditionTypeReady, st, reason, 0),
		cond(configv1alpha1.ConditionTypeTargetDiscoveryReady, metav1.ConditionTrue, "Ready", 0),
		cond(configv1alpha1.ConditionTypeTargetDatastoreReady, st, reason, 0),
		cond(configv1alpha1.ConditionTypeTargetConnectionReady, st, reason, 0),
	)
	tg.Status.DiscoveryInfo = &configv1alpha1.DiscoveryInfo{Provider: lockSet.Schema.Provider, Version: lockSet.DeviceImage.Tag, Hostname: node}
	must(t, k8s.Status().Update(context.Background(), tg))
}

func layerReady(t *testing.T) {
	t.Helper()
	setSchemaReady(t, true)
	for _, n := range nodes {
		setTarget(t, n, true)
	}
}

// confirmConfigs marks every Config of fabric applied (Ready at its generation),
// except the nodes in failed, which report a failed transaction.
func confirmConfigs(t *testing.T, fab string, failed ...string) {
	t.Helper()
	for _, c := range listConfigs(t, fab) {
		c := c
		node := c.Labels[sdc.LabelTargetName]
		// the conditions are replaced outright: the upstream SetConditions
		// keeps an "equal" condition (it ignores observedGeneration)
		if contains(failed, node) {
			f := condv1alpha1.Failed("transaction failed on " + node + ": commit rejected")
			f.ObservedGeneration = c.Generation
			c.Status.Conditions = []condv1alpha1.Condition{f}
		} else {
			c.Status.Conditions = []condv1alpha1.Condition{cond(condv1alpha1.ConditionTypeReady, metav1.ConditionTrue, "Ready", c.Generation)}
		}
		must(t, k8s.Status().Update(context.Background(), &c))
	}
}

// ---------------------------------------------------------------------------
// Fakes behind the reconciler's interfaces.
// ---------------------------------------------------------------------------

type fakeClaims struct {
	mu     sync.Mutex
	claims map[string]kuid.Claimed
	mode   string // "" bind, "pending", "refuse", "error"
	next   map[string]int
}

func newFakeClaims() *fakeClaims {
	return &fakeClaims{claims: map[string]kuid.Claimed{}, next: map[string]int{}}
}

func (f *fakeClaims) key(r kuid.Ref) string { return r.Namespace + "/" + r.Name }

func (f *fakeClaims) Claim(ctx context.Context, req kuid.Request) (kuid.Claimed, error) {
	return f.make(req, "")
}

func (f *fakeClaims) ClaimValue(ctx context.Context, req kuid.Request, v string) (kuid.Claimed, error) {
	return f.make(req, v)
}

func (f *fakeClaims) make(req kuid.Request, stated string) (kuid.Claimed, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.mode == "error" {
		return kuid.Claimed{}, errors.New("the aggregated API is unavailable")
	}
	c := kuid.Claimed{Ref: req.Ref, Index: req.Index, Labels: req.Labels, Stated: stated}
	switch f.mode {
	case "pending":
	case "refuse":
		c.Reason, c.Message = "Failed", "value held by another owner (claim kuid-system/someone-else)"
	default:
		c.Ready, c.Value = true, stated
		if stated == "" {
			f.next[req.Index]++
			n := f.next[req.Index]
			switch {
			case req.CreatePrefix:
				c.Value = fmt.Sprintf("10.1.0.%d/31", (n-1)*2)
			case req.Kind == kuid.KindIP:
				c.Value = fmt.Sprintf("10.0.0.%d/32", 100+n)
			default:
				c.Value = fmt.Sprintf("%d", 65200+n)
			}
		}
	}
	f.claims[f.key(req.Ref)] = c
	return c, nil
}

func (f *fakeClaims) Release(ctx context.Context, ref kuid.Ref) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.claims, f.key(ref))
	return nil
}

func (f *fakeClaims) Get(ctx context.Context, ref kuid.Ref) (kuid.Claimed, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.mode == "error" {
		return kuid.Claimed{}, errors.New("the aggregated API is unavailable")
	}
	c, ok := f.claims[f.key(ref)]
	if !ok {
		return kuid.Claimed{}, fmt.Errorf("%s: %w", ref, kuid.ErrNotFound)
	}
	return c, nil
}

func (f *fakeClaims) ListByLabel(ctx context.Context, kind kuid.Kind, ns string, labels map[string]string) ([]kuid.Claimed, error) {
	return nil, nil
}

// Index and Authority are the kuid implementation's: the fixtures' pool references
// (defaultFabric) name the kuid index kinds, and the reconciler reads them from here.
func (f *fakeClaims) Index(k kuid.Kind) kuid.IndexType { return kuid.NewUpstream(nil).Index(k) }

func (f *fakeClaims) Authority() string { return kuid.AuthorityKuid }

func (f *fakeClaims) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.claims)
}

func (f *fakeClaims) bindAll() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.mode = ""
	for k, c := range f.claims {
		if !c.Ready {
			c.Ready, c.Reason, c.Message = true, "", ""
			if c.Value = c.Stated; c.Value == "" {
				c.Value = "10.1.0.250/31"
			}
			f.claims[k] = c
		}
	}
}

// fakeVerifier is the read-back behind the reconciler's Verifier interface.
type fakeVerifier struct {
	mu      sync.Mutex
	calls   int
	mode    string // "" pass, "missing", "cannot"
	target  string
	cleared []int
	last    verify.FabricInput
}

func (v *fakeVerifier) VerifyFabric(ctx context.Context, in verify.FabricInput) (verify.FabricResult, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.calls++
	v.last = in
	switch v.mode {
	case "cannot":
		return verify.FabricResult{}, &verify.CouldNotRunError{Causes: map[string]error{v.target: errors.New("connection refused")}}
	case "missing":
		return verify.FabricResult{Missing: []verify.Invariant{{Node: v.target, Check: verify.CheckSessionState,
			Detail: "overlay session 10.0.0.11 reads idle, want established"}}}, nil
	}
	res := verify.FabricResult{}
	for _, i := range v.cleared {
		for _, f := range in.Findings {
			if f.Index == i {
				res.ClearedFindings = append(res.ClearedFindings, i)
			}
		}
	}
	return res, nil
}

func (v *fakeVerifier) set(mode, target string) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.mode, v.target = mode, target
}

func (v *fakeVerifier) count() int {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.calls
}

type fakeTelemetry struct {
	mu sync.Mutex
	ok bool
}

func (f *fakeTelemetry) TelemetryHealthy(context.Context) (bool, string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.ok, "collector unreachable (fake)"
}

func (f *fakeTelemetry) set(ok bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ok = ok
}

// fakeRenderer renders a small deterministic document per node from the model.
type fakeRenderer struct{}

func (fakeRenderer) RenderFabric(m *model.FabricModel) (map[string]fabric.Rendered, error) {
	out := map[string]fabric.Rendered{}
	for _, n := range m.Nodes {
		doc := map[string]any{"srl_nokia-interfaces:interface": []any{map[string]any{"name": "system0", "admin-state": "enable"}},
			"x-node": n.Name, "x-system": n.SystemIPv4, "x-asn": n.BGP.AutonomousSystem, "x-ports": n.FabricPorts, "x-access": n.AccessPorts}
		if n.BGP.InterASVPN != nil {
			doc["x-inter-as-vpn"] = *n.BGP.InterASVPN
		}
		if n.BGP.RouteReflectorClient != nil {
			// a reflecting spine's configuration-integrity leaves, at the paths
			// the read-back reads from the configuration datastore (AD-76)
			bgp := map[string]any{"group": []any{map[string]any{"group-name": model.OverlayGroup,
				"route-reflector": map[string]any{"client": *n.BGP.RouteReflectorClient}}}}
			if n.BGP.InterASVPN != nil {
				bgp["afi-safi"] = []any{map[string]any{"afi-safi-name": verify.EVPNAFISAFIName,
					"evpn": map[string]any{"inter-as-vpn": *n.BGP.InterASVPN}}}
			}
			doc["srl_nokia-network-instance:network-instance"] = []any{map[string]any{"name": model.DefaultNetworkInstance,
				"protocols": map[string]any{"srl_nokia-bgp:bgp": bgp}}}
		}
		b, err := json.Marshal(doc)
		if err != nil {
			return nil, err
		}
		sum := sha256.Sum256(b)
		out[n.Name] = fabric.Rendered{Node: n.Name, JSON: b, Hash: hex.EncodeToString(sum[:])}
	}
	return out, nil
}

// configReader is a verify.StateReader standing in for a device that holds
// exactly what the layer applied: its running configuration is the node's
// priority-10 Config value, and every applied-side state leaf reads healthy.
// With it the reconciler runs the REAL read-back (verify.Fabric).
type configReader struct{ fabric string }

func (r configReader) Running(ctx context.Context, t verify.Target) ([]byte, error) {
	name, err := sdc.ConfigName(r.fabric, t.Name)
	if err != nil {
		return nil, err
	}
	cfg := &configv1alpha1.Config{}
	if err := k8s.Get(ctx, client.ObjectKey{Namespace: sdc.SystemNamespace, Name: name}, cfg); err != nil {
		return nil, err
	}
	if len(cfg.Spec.Config) == 0 {
		return []byte(`{}`), nil
	}
	return cfg.Spec.Config[0].Value.Raw, nil
}

func (configReader) State(_ context.Context, _ verify.Target, paths []string) (map[string][]string, error) {
	out := map[string][]string{}
	for _, p := range paths {
		switch {
		case strings.HasSuffix(p, "/oper-state"):
			out[p] = []string{verify.OperStateUp}
		case strings.HasSuffix(p, "/session-state"):
			out[p] = []string{verify.SessionEstablished}
		case strings.HasSuffix(p, "/active"):
			out[p] = []string{verify.LeafTrue}
		}
	}
	return out, nil
}

type recorder struct {
	mu     sync.Mutex
	events []string
}

func (r *recorder) Event(o k8sruntime.Object, typ, reason, msg string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, typ+" "+reason+" "+msg)
}
func (r *recorder) Eventf(o k8sruntime.Object, typ, reason, f string, a ...any) {
	r.Event(o, typ, reason, fmt.Sprintf(f, a...))
}
func (r *recorder) AnnotatedEventf(o k8sruntime.Object, _ map[string]string, typ, reason, f string, a ...any) {
	r.Eventf(o, typ, reason, f, a...)
}
func (r *recorder) has(reason string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, e := range r.events {
		if strings.Contains(e, " "+reason+" ") {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Harness.
// ---------------------------------------------------------------------------

type harness struct {
	t      *testing.T
	name   string
	r      *fabric.Reconciler
	clock  *clocktesting.FakeClock
	claims *fakeClaims
	verify *fakeVerifier
	tele   *fakeTelemetry
	rec    *recorder
}

func newHarness(t *testing.T, name string, mutate ...func(*fabric.Settings)) *harness {
	h := &harness{t: t, name: name, clock: clocktesting.NewFakeClock(t0), claims: newFakeClaims(),
		verify: &fakeVerifier{}, tele: &fakeTelemetry{ok: true}, rec: &recorder{}}
	h.r = h.newReconciler(mutate...)
	return h
}

func (h *harness) newReconciler(mutate ...func(*fabric.Settings)) *fabric.Reconciler {
	st := fabric.DefaultSettings()
	for _, m := range mutate {
		m(&st)
	}
	return &fabric.Reconciler{
		Client: k8s, SDC: sdc.New(k8s), Claims: h.claims, Renderer: fakeRenderer{}, Verifier: h.verify,
		Telemetry: h.tele, Compat: lockSet, Recorder: h.rec, Clock: h.clock, Settings: st,
	}
}

// restart replaces the reconciler with a fresh one (no in-memory state).
func (h *harness) restart() { h.r = h.newReconciler() }

func (h *harness) reconcile() ctrl.Result {
	h.t.Helper()
	res, err := h.r.Reconcile(context.Background(), ctrl.Request{NamespacedName: types.NamespacedName{Namespace: nsSystem, Name: h.name}})
	if err != nil {
		h.t.Fatalf("reconcile %s: %v", h.name, err)
	}
	return res
}

func (h *harness) fabric() *fabricv1.Fabric {
	h.t.Helper()
	f := &fabricv1.Fabric{}
	must(h.t, k8s.Get(context.Background(), client.ObjectKey{Namespace: nsSystem, Name: h.name}, f))
	return f
}

func (h *harness) cond(typ string) *metav1.Condition {
	return meta.FindStatusCondition(h.fabric().Status.Conditions, typ)
}

func (h *harness) wantCond(typ string, st metav1.ConditionStatus, reason string, msgHas ...string) *metav1.Condition {
	h.t.Helper()
	c := h.cond(typ)
	if c == nil {
		h.t.Fatalf("%s: no %s condition", h.name, typ)
	}
	if c.Status != st || (reason != "" && c.Reason != reason) {
		h.t.Fatalf("%s: %s=%s/%s (%s), want %s/%s", h.name, typ, c.Status, c.Reason, c.Message, st, reason)
	}
	for _, s := range msgHas {
		if !strings.Contains(c.Message, s) {
			h.t.Fatalf("%s: %s message %q lacks %q", h.name, typ, c.Message, s)
		}
	}
	return c
}

// converge creates the Fabric, readies the layer, confirms the Configs and
// reconciles until Ready=True at t0.
func (h *harness) converge(spec ...func(*fabricv1.Fabric)) {
	h.t.Helper()
	layerReady(h.t)
	h.create(spec...)
	h.reconcile()
	confirmConfigs(h.t, h.name)
	res := h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	if res.RequeueAfter != h.r.Settings.ReverifyInterval {
		h.t.Fatalf("a Ready Fabric is requeued at %s, want the re-verification interval %s", res.RequeueAfter, h.r.Settings.ReverifyInterval)
	}
}

func (h *harness) create(spec ...func(*fabricv1.Fabric)) {
	h.t.Helper()
	f := defaultFabric(h.name)
	for _, s := range spec {
		s(f)
	}
	must(h.t, k8s.Create(context.Background(), f))
	h.t.Cleanup(func() {
		_ = k8s.Delete(context.Background(), f)
		for _, c := range listConfigs(h.t, h.name) {
			c := c
			_ = k8s.Delete(context.Background(), &c)
		}
	})
}

func (h *harness) update(mut func(*fabricv1.Fabric)) {
	h.t.Helper()
	f := h.fabric()
	mut(f)
	must(h.t, k8s.Update(context.Background(), f))
}

func (h *harness) updateStatus(mut func(*fabricv1.Fabric)) {
	h.t.Helper()
	f := h.fabric()
	mut(f)
	must(h.t, k8s.Status().Update(context.Background(), f))
}

func ptr[T any](v T) *T { return &v }

// defaultFabric is data-model.md §3a's fabric01 under another name.
func defaultFabric(name string) *fabricv1.Fabric {
	pool := func(g, k, n string) *fabricv1.PoolRef {
		return &fabricv1.PoolRef{Group: g, Kind: k, Name: n, Namespace: nsKuid}
	}
	return &fabricv1.Fabric{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: nsSystem},
		Spec: fabricv1.FabricSpec{
			Nodes: []fabricv1.FabricNode{
				{Name: "spine01", Role: "spine", Platform: "ixr-d3l", SystemIPv4: "10.0.0.11/32", ASN: ptr[int64](65100), RouteReflector: ptr(true)},
				{Name: "spine02", Role: "spine", Platform: "ixr-d3l", SystemIPv4: "10.0.0.12/32", ASN: ptr[int64](65100), RouteReflector: ptr(true)},
				{Name: "leaf01", Role: "leaf", Platform: "ixr-d2l", SystemIPv4: "10.0.0.1/32", ASN: ptr[int64](65101)},
				{Name: "leaf02", Role: "leaf", Platform: "ixr-d2l", SystemIPv4: "10.0.0.2/32", ASN: ptr[int64](65102)},
			},
			Underlay: fabricv1.UnderlaySpec{
				AddressFamilies: []fabricv1.AddressFamily{"ipv4", "ipv6"},
				LoopbackPoolRef: pool("ipam.be.kuid.dev", "IPIndex", "fabric01-loopback"),
				LinkPoolRef:     pool("ipam.be.kuid.dev", "IPIndex", "fabric01-p2p"),
				ASNPoolRef:      pool("as.be.kuid.dev", "ASIndex", "fabric01-underlay"),
			},
			Overlay: fabricv1.OverlaySpec{FabricASN: 65000, RouteReflectors: []fabricv1.DNSLabel{"spine01", "spine02"},
				InterASVPN: ptr(true), TunnelInterface: "vxlan0"},
			MTU: fabricv1.MTUSpec{PortMTU: 9412, UnderlayIPMTU: 9398, BridgedL2MTU: 9412, TenantIPMTU: 9348},
			Inventory: []fabricv1.InventoryEntry{
				{Node: "leaf01", AccessPorts: []fabricv1.PortName{"ethernet-1/1"}, FabricPorts: []fabricv1.PortName{"ethernet-1/49", "ethernet-1/50"}},
				{Node: "leaf02", AccessPorts: []fabricv1.PortName{"ethernet-1/1"}, FabricPorts: []fabricv1.PortName{"ethernet-1/49", "ethernet-1/50"}},
				{Node: "spine01", FabricPorts: []fabricv1.PortName{"ethernet-1/1", "ethernet-1/2"}},
				{Node: "spine02", FabricPorts: []fabricv1.PortName{"ethernet-1/1", "ethernet-1/2"}},
			},
		},
	}
}

func listConfigs(t *testing.T, fab string) []configv1alpha1.Config {
	t.Helper()
	l := &configv1alpha1.ConfigList{}
	must(t, k8s.List(context.Background(), l, client.InNamespace(nsSystem), client.MatchingLabels{sdc.LabelFabricName: fab}))
	sort.Slice(l.Items, func(i, j int) bool { return l.Items[i].Name < l.Items[j].Name })
	return l.Items
}

// versions snapshots every Config's resourceVersion and generation.
func versions(t *testing.T, fab string) map[string]string {
	out := map[string]string{}
	for _, c := range listConfigs(t, fab) {
		out[c.Name] = fmt.Sprintf("rv=%s gen=%d", c.ResourceVersion, c.Generation)
	}
	return out
}

func sameVersions(t *testing.T, what string, a, b map[string]string) {
	t.Helper()
	if len(a) != len(b) {
		t.Fatalf("%s: Config set changed %v -> %v", what, a, b)
	}
	for k, v := range a {
		if b[k] != v {
			t.Fatalf("%s: Config %s written (%s -> %s)", what, k, v, b[k])
		}
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func neitherTrueNorFalse(t *testing.T, c *metav1.Condition) {
	t.Helper()
	if c.Status == metav1.ConditionTrue || c.Status == metav1.ConditionFalse {
		t.Fatalf("Ready is %s; a pass that cannot run is neither True nor False (AD-40)", c.Status)
	}
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

// Dependency waits: Schema, Targets and claims not ready → no Config.
func TestDependencyWaitsWriteNoConfig(t *testing.T) {
	h := newHarness(t, "fab-waits")
	setSchemaReady(t, false)
	for _, n := range nodes {
		setTarget(t, n, false)
	}
	h.create()

	res := h.reconcile()
	if n := len(listConfigs(t, h.name)); n != 0 {
		t.Fatalf("%d Configs written with the Schema and Targets not Ready", n)
	}
	h.wantCond("Ready", metav1.ConditionFalse, "NotConverged", "Schema", "not loaded and Ready")
	if res.RequeueAfter != 15*time.Second {
		t.Errorf("a waiting object is requeued at the reconciliation interval, got %s", res.RequeueAfter)
	}

	setSchemaReady(t, true)
	h.reconcile()
	if n := len(listConfigs(t, h.name)); n != 0 {
		t.Fatalf("%d Configs written with the Targets not Ready", n)
	}
	h.wantCond("Applied", metav1.ConditionFalse, "TargetNotReady", "leaf01", "spine02")

	for _, n := range nodes {
		setTarget(t, n, true)
	}
	h.claims.mode = "pending"
	h.reconcile()
	if n := len(listConfigs(t, h.name)); n != 0 {
		t.Fatalf("%d Configs written with the claims unbound", n)
	}
	h.wantCond("Ready", metav1.ConditionFalse, "NotConverged", "waiting for claims to bind")
	if c := h.cond("Accepted"); c != nil && c.Status == metav1.ConditionTrue {
		t.Error("Accepted=True with the underlay claims unbound")
	}

	h.claims.bindAll()
	h.reconcile()
	if n := len(listConfigs(t, h.name)); n != 4 {
		t.Fatalf("%d Configs once every dependency is met, want 4", n)
	}
	h.wantCond("Accepted", metav1.ConditionTrue, "")
	alloc := h.fabric().Status.Allocations
	if len(alloc) != 4+3+4 { // 4 loopbacks, 3 ASN claims (spines share one), 4 links
		t.Errorf("allocations %d: %+v", len(alloc), alloc)
	}
}

// An allocation authority that errors is a wait retried with bounded backoff,
// never AllocationConflict (AD-56); a refusal is AllocationConflict.
func TestAuthorityErrorIsBackoffAndRefusalIsConflict(t *testing.T) {
	h := newHarness(t, "fab-authority")
	layerReady(t)
	h.create()
	h.claims.mode = "error"
	res := h.reconcile()
	if res.RequeueAfter <= 0 || res.RequeueAfter > 10*time.Second {
		t.Errorf("transient backoff %s outside (0, 10s]", res.RequeueAfter)
	}
	if c := h.cond("Accepted"); c != nil && c.Reason == "AllocationConflict" {
		t.Fatal("an authority error was reported as AllocationConflict")
	}
	if len(listConfigs(t, h.name)) != 0 {
		t.Fatal("Configs written while the authority did not answer")
	}
	if !h.rec.has(fabric.EventTransientError) {
		t.Error("no TransientError Event")
	}
	h.claims.mode = "refuse"
	h.reconcile()
	h.wantCond("Accepted", metav1.ConditionFalse, "AllocationConflict", "held by another owner")
	if len(listConfigs(t, h.name)) != 0 {
		t.Fatal("Configs written on an AllocationConflict")
	}
}

// One priority-10 Config per node, in agentic-netops-system, with a controller
// owner reference to the Fabric, spec.revertive present and true, stable
// names, the dedicated SSA field manager, and zero spec writes on a second
// reconcile.
func TestOneConfigPerNodeWithTheContract(t *testing.T) {
	h := newHarness(t, "fab-configs")
	h.converge()
	f := h.fabric()
	cfgs := listConfigs(t, h.name)
	if len(cfgs) != 4 {
		t.Fatalf("%d Configs, want one per node (4)", len(cfgs))
	}
	var names []string
	for _, c := range cfgs {
		names = append(names, c.Name)
		node := c.Labels[sdc.LabelTargetName]
		if c.Name != h.name+"."+node {
			t.Errorf("name %s, want %s.%s", c.Name, h.name, node)
		}
		if c.Namespace != nsSystem {
			t.Errorf("%s in %s, want %s (AD-69)", c.Name, c.Namespace, nsSystem)
		}
		if c.Spec.Priority != 10 {
			t.Errorf("%s priority %d, want 10", c.Name, c.Spec.Priority)
		}
		if c.Spec.Revertive == nil || !*c.Spec.Revertive {
			t.Errorf("%s spec.revertive %v, want present and true", c.Name, c.Spec.Revertive)
		}
		if c.Spec.Lifecycle == nil || c.Spec.Lifecycle.DeletionPolicy != configv1alpha1.DeletionDelete {
			t.Errorf("%s deletionPolicy %+v", c.Name, c.Spec.Lifecycle)
		}
		if c.Labels[sdc.LabelTargetNamespace] != nsTargets {
			t.Errorf("%s target labels %v", c.Name, c.Labels)
		}
		// config-server v0.0.58 lists a Target's Configs in the Target's own namespace only.
		if c.Namespace != c.Labels[sdc.LabelTargetNamespace] {
			t.Errorf("%s in namespace %q, its Target in %q: the layer would never apply it", c.Name, c.Namespace, c.Labels[sdc.LabelTargetNamespace])
		}
		if len(c.OwnerReferences) != 1 {
			t.Fatalf("%s owner references %+v", c.Name, c.OwnerReferences)
		}
		o := c.OwnerReferences[0]
		if o.UID != f.UID || o.Kind != "Fabric" || o.Name != h.name || o.Controller == nil || !*o.Controller {
			t.Errorf("%s owner reference %+v is not a controller reference to the Fabric", c.Name, o)
		}
		if c.Annotations[sdc.AnnotationCompatibilitySet] != lockSet.Identifier() || !strings.HasPrefix(c.Annotations[sdc.AnnotationRenderHash], "sha256:") ||
			c.Annotations[sdc.AnnotationSourceUID] != string(f.UID) || c.Annotations[sdc.AnnotationMappingVersion] != sdc.MappingVersion {
			t.Errorf("%s annotations %v", c.Name, c.Annotations)
		}
		manager := false
		for _, mf := range c.ManagedFields {
			if mf.Manager == sdc.FieldManager && mf.Operation == metav1.ManagedFieldsOperationApply {
				manager = true
			}
		}
		if !manager {
			t.Errorf("%s: no server-side-apply managedFields entry for %q: %+v", c.Name, sdc.FieldManager, c.ManagedFields)
		}
		// present on the wire, never absent (an absent field inherits the layer's default)
		u := &unstructured.Unstructured{}
		u.SetGroupVersionKind(configv1alpha1.SchemeGroupVersion.WithKind("Config"))
		must(t, k8s.Get(context.Background(), client.ObjectKeyFromObject(&c), u))
		if v, found, _ := unstructured.NestedBool(u.Object, "spec", "revertive"); !found || !v {
			t.Errorf("%s: spec.revertive on the wire found=%v value=%v", c.Name, found, v)
		}
	}
	if f.Status.LastVerifiedTime == nil || !f.Status.LastVerifiedTime.Time.Equal(t0) {
		t.Errorf("lastVerifiedTime %v, want %v", f.Status.LastVerifiedTime, t0)
	}
	if len(f.Status.RenderedConfigs) != 4 || f.Status.RenderedConfigs[0].Phase != fabricv1.TargetPhaseReady {
		t.Errorf("per-target status %+v", f.Status.RenderedConfigs)
	}

	before := versions(t, h.name)
	h.reconcile()
	h.reconcile()
	sameVersions(t, "second reconcile", before, versions(t, h.name))
	var again []string
	for _, c := range listConfigs(t, h.name) {
		again = append(again, c.Name)
	}
	if strings.Join(names, ",") != strings.Join(again, ",") {
		t.Errorf("names not stable: %v -> %v", names, again)
	}
}

// One fake target failing its transaction: per-target status, Degraded=True/
// PartialFailure beside Ready=False, never an aggregate Ready.
func TestPartialFailureIsNeverAggregateReady(t *testing.T) {
	h := newHarness(t, "fab-partial")
	layerReady(t)
	h.create()
	h.reconcile()
	confirmConfigs(t, h.name, "leaf02")
	h.tele.set(false) // PartialFailure outranks TelemetryUnavailable
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionFalse, "NotConverged", "leaf02")
	h.wantCond("Degraded", metav1.ConditionTrue, "PartialFailure", "leaf02")
	h.wantCond("Applied", metav1.ConditionFalse, "TransactionFailed", "leaf02")
	for _, rc := range h.fabric().Status.RenderedConfigs {
		want := fabricv1.TargetPhaseReady
		if rc.Node == "leaf02" {
			want = fabricv1.TargetPhaseFailed
		}
		if rc.Phase != want {
			t.Errorf("per-target %s phase %s, want %s", rc.Node, rc.Phase, want)
		}
	}
	if h.verify.count() != 0 {
		t.Error("a read-back ran although a transaction failed")
	}
}

// A controller restart between render and confirmation converges safely and
// writes no Config spec.
func TestRestartBetweenRenderAndConfirmation(t *testing.T) {
	h := newHarness(t, "fab-restart")
	layerReady(t)
	h.create()
	h.reconcile()
	if len(listConfigs(t, h.name)) != 4 {
		t.Fatal("Configs not rendered before the restart")
	}
	h.wantCond("Ready", metav1.ConditionFalse, "NotConverged")
	h.restart() // the provider restarts; the layer confirms meanwhile
	confirmConfigs(t, h.name)
	before := versions(t, h.name)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	sameVersions(t, "reconcile after restart", before, versions(t, h.name))
	for _, c := range listConfigs(t, h.name) {
		if c.Generation != 1 {
			t.Errorf("%s at generation %d after a restart, want 1", c.Name, c.Generation)
		}
	}
}

// Scheduled re-verification with a fake clock: default 5 min asserted, an
// override honoured; a pass advances lastVerifiedTime and writes no Config; a
// pass that finds an invariant missing sets Ready=False with its reason AND
// advances lastVerifiedTime (AD-54).
func TestScheduledReverification(t *testing.T) {
	h := newHarness(t, "fab-reverify")
	if h.r.Settings.ReverifyInterval != 5*time.Minute {
		t.Fatalf("default re-verification interval %s, want 5m", h.r.Settings.ReverifyInterval)
	}
	h.converge()
	before := versions(t, h.name)
	calls := h.verify.count()

	h.clock.Step(time.Minute)
	if res := h.reconcile(); res.RequeueAfter != 4*time.Minute {
		t.Errorf("between passes the requeue is %s, want the 4m left of the interval", res.RequeueAfter)
	}
	if h.verify.count() != calls {
		t.Fatal("a read-back ran before the interval elapsed")
	}

	h.clock.Step(4 * time.Minute)
	res := h.reconcile()
	if h.verify.count() != calls+1 {
		t.Fatal("no read-back at the interval")
	}
	if lv := h.fabric().Status.LastVerifiedTime; lv == nil || !lv.Time.Equal(t0.Add(5*time.Minute)) {
		t.Errorf("lastVerifiedTime %v, want %v", lv, t0.Add(5*time.Minute))
	}
	if res.RequeueAfter != 5*time.Minute {
		t.Errorf("requeue %s, want 5m", res.RequeueAfter)
	}
	sameVersions(t, "scheduled pass", before, versions(t, h.name))
	h.wantCond("Ready", metav1.ConditionTrue, "")

	// a pass that finds an invariant missing
	h.verify.set("missing", "leaf01")
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionFalse, "NotConverged", "leaf01", "bgp-session-state")
	if lv := h.fabric().Status.LastVerifiedTime; lv == nil || !lv.Time.Equal(t0.Add(10*time.Minute)) {
		t.Errorf("a pass that ran and found an invariant missing must advance lastVerifiedTime: %v", lv)
	}
	sameVersions(t, "pass finding a missing invariant", before, versions(t, h.name))
	h.verify.set("", "")
	h.clock.Step(15 * time.Second)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")

	// the override is honoured
	o := newHarness(t, "fab-reverify-override", func(s *fabric.Settings) { s.ReverifyInterval = 2 * time.Minute })
	o.converge()
	o.clock.Step(2 * time.Minute)
	o.reconcile()
	if lv := o.fabric().Status.LastVerifiedTime; lv == nil || !lv.Time.Equal(t0.Add(2*time.Minute)) {
		t.Errorf("override: lastVerifiedTime %v, want %v", lv, t0.Add(2*time.Minute))
	}
}

// A pass that cannot run: Ready=Unknown/VerificationFailed and Degraded=True/
// VerificationFailed naming the target, neither True nor False, lastVerifiedTime
// frozen across further intervals, Ready=True back at the first pass after the
// target returns; and the same when the target goes not Ready between passes.
func TestPassThatCannotRun(t *testing.T) {
	h := newHarness(t, "fab-cannot")
	h.converge()
	before := versions(t, h.name)

	h.verify.set("cannot", "leaf02")
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	r := h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed", "leaf02")
	neitherTrueNorFalse(t, r)
	h.wantCond("Degraded", metav1.ConditionTrue, "VerificationFailed", "leaf02")
	for i := 0; i < 2; i++ {
		h.clock.Step(5 * time.Minute)
		h.reconcile()
		neitherTrueNorFalse(t, h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed", "leaf02"))
		if lv := h.fabric().Status.LastVerifiedTime; lv == nil || !lv.Time.Equal(t0) {
			t.Fatalf("lastVerifiedTime advanced by a pass that could not run: %v", lv)
		}
	}
	h.verify.set("", "")
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	h.wantCond("Degraded", metav1.ConditionFalse, "")
	if lv := h.fabric().Status.LastVerifiedTime; lv == nil || !lv.Time.Equal(t0.Add(20*time.Minute)) {
		t.Errorf("lastVerifiedTime after the target returned: %v", lv)
	}
	sameVersions(t, "cannot-run passes", before, versions(t, h.name))

	// the target goes not Ready between two passes
	setTarget(t, "leaf01", false)
	h.clock.Step(10 * time.Second)
	h.reconcile()
	neitherTrueNorFalse(t, h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed", "leaf01"))
	h.wantCond("Degraded", metav1.ConditionTrue, "VerificationFailed", "leaf01")
	frozen := h.fabric().Status.LastVerifiedTime
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	neitherTrueNorFalse(t, h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed", "leaf01"))
	if lv := h.fabric().Status.LastVerifiedTime; !lv.Equal(frozen) {
		t.Fatalf("lastVerifiedTime moved while the target was away: %v -> %v", frozen, lv)
	}
	setTarget(t, "leaf01", true)
	h.clock.Step(10 * time.Second)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	sameVersions(t, "target outage", before, versions(t, h.name))
}

// The layer stops confirming, at the same generation, a Config it had confirmed —
// its Target still reported Ready (the layer notices a lost session in its Config
// status first): a read-back that cannot run, Ready=Unknown/VerificationFailed and
// Degraded=True naming the node, never Ready=False/NotConverged; lastVerifiedTime
// frozen; zero Config writes; Ready=True again once the layer confirms (AD-40, AD-54,
// AD-62; T151 r9's management cut read as NotConverged on the Fabric).
func TestLayerUnconfirmsAtSameGenerationIsUnknown(t *testing.T) {
	h := newHarness(t, "fab-unconfirm")
	h.converge()
	frozen := h.fabric().Status.LastVerifiedTime

	for _, c := range listConfigs(t, h.name) {
		c := c
		if c.Labels[sdc.LabelTargetName] != "leaf02" {
			continue
		}
		c.Status.Conditions = []condv1alpha1.Condition{cond(condv1alpha1.ConditionTypeReady, metav1.ConditionFalse, "NotReady", c.Generation)}
		must(t, k8s.Status().Update(context.Background(), &c))
	}
	before := versions(t, h.name)
	h.clock.Step(10 * time.Second)
	h.reconcile()
	neitherTrueNorFalse(t, h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed", "leaf02"))
	h.wantCond("Degraded", metav1.ConditionTrue, "VerificationFailed", "leaf02")
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	neitherTrueNorFalse(t, h.wantCond("Ready", metav1.ConditionUnknown, "VerificationFailed", "leaf02"))
	if lv := h.fabric().Status.LastVerifiedTime; !lv.Equal(frozen) {
		t.Fatalf("lastVerifiedTime moved while the layer did not confirm: %v -> %v", frozen, lv)
	}
	sameVersions(t, "layer unconfirmed", before, versions(t, h.name))

	confirmConfigs(t, h.name)
	before = versions(t, h.name)
	h.clock.Step(10 * time.Second)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	h.wantCond("Degraded", metav1.ConditionFalse, "")
	sameVersions(t, "layer confirmed again", before, versions(t, h.name))
}

// The Degraded reason in §18's total order: TelemetryUnavailable beside a
// Ready=True that does not move, yielding to VerificationFailed and to
// StaleConfigurationPossible whenever either applies. (PartialFailure beside
// Ready=False: TestPartialFailureIsNeverAggregateReady.)
func TestDegradedTotalOrder(t *testing.T) {
	h := newHarness(t, "fab-order")
	h.converge()
	ready := h.cond("Ready")

	h.tele.set(false)
	h.reconcile()
	h.wantCond("Degraded", metav1.ConditionTrue, "TelemetryUnavailable")
	r := h.wantCond("Ready", metav1.ConditionTrue, "")
	if !r.LastTransitionTime.Equal(&ready.LastTransitionTime) || r.Message != ready.Message {
		t.Errorf("a telemetry failure moved Ready: %+v -> %+v", ready, r)
	}
	for _, typ := range []string{"Accepted", "Rendered", "Applied", "Validated"} {
		h.wantCond(typ, metav1.ConditionTrue, "")
	}

	h.verify.set("cannot", "spine01")
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	h.wantCond("Degraded", metav1.ConditionTrue, "VerificationFailed", "spine01")

	h.verify.set("", "")
	h.updateStatus(func(f *fabricv1.Fabric) {
		f.Status.Findings = []fabricv1.Finding{finding("leaf01")}
	})
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	h.wantCond("Degraded", metav1.ConditionTrue, "StaleConfigurationPossible", "leaf01")

	h.verify.cleared = []int{0}
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	h.wantCond("Degraded", metav1.ConditionTrue, "TelemetryUnavailable")
	if len(h.fabric().Status.Findings) != 0 {
		t.Error("a finding read clean was not cleared")
	}
	if !h.rec.has(fabric.EventFindingCleared) {
		t.Error("no FindingCleared Event")
	}
	h.tele.set(true)
	h.reconcile()
	h.wantCond("Degraded", metav1.ConditionFalse, "")
}

func finding(node string) fabricv1.Finding {
	return fabricv1.Finding{
		Type:          fabricv1.FindingStaleConfigurationPossible,
		Service:       fabricv1.ServiceRef{Namespace: nsServices, Name: "svc-gone", UID: "uid-gone"},
		Node:          node,
		Identifiers:   []fabricv1.ReleasedIdentifier{{Kind: "GENID", Index: "vni", Value: "10021"}},
		DeviceObjects: []string{"macvrf-svc-gone", "ethernet-1/1.100", "vxlan0.10021"},
		Reason:        "leaf removed from the rack",
		RecordedAt:    metav1.NewTime(t0),
	}
}

// A force-release finding: VerificationFailed while its target is away, the
// finding visible throughout, StaleConfigurationPossible from the first pass
// that runs; once its node has left spec.nodes it stays in status.findings[],
// sets no StaleConfigurationPossible, and counts again from the first pass
// after the node is back (AD-54, AD-71).
func TestForceReleaseFindingAndNodeLeavingTheFabric(t *testing.T) {
	h := newHarness(t, "fab-finding")
	h.converge()

	setTarget(t, "leaf02", false)
	h.updateStatus(func(f *fabricv1.Fabric) { f.Status.Findings = []fabricv1.Finding{finding("leaf02")} })
	h.reconcile()
	h.wantCond("Degraded", metav1.ConditionTrue, "VerificationFailed", "leaf02")
	if len(h.fabric().Status.Findings) != 1 {
		t.Fatal("the finding is not visible while its target is away")
	}
	setTarget(t, "leaf02", true)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	h.wantCond("Degraded", metav1.ConditionTrue, "StaleConfigurationPossible", "leaf02")

	// the node leaves spec.nodes
	h.update(func(f *fabricv1.Fabric) {
		f.Spec.Nodes = f.Spec.Nodes[:3]
		f.Spec.Inventory = []fabricv1.InventoryEntry{f.Spec.Inventory[0], f.Spec.Inventory[2], f.Spec.Inventory[3]}
	})
	h.reconcile()
	confirmConfigs(t, h.name)
	h.clock.Step(15 * time.Second)
	h.reconcile()
	f := h.fabric()
	if len(f.Status.Findings) != 1 || f.Status.Findings[0].Node != "leaf02" {
		t.Fatalf("the finding of a node that left spec.nodes must stay: %+v", f.Status.Findings)
	}
	if d := h.cond("Degraded"); d != nil && d.Status == metav1.ConditionTrue && d.Reason == "StaleConfigurationPossible" {
		t.Fatal("a finding whose node left spec.nodes still counts toward Degraded")
	}
	h.wantCond("Ready", metav1.ConditionTrue, "")
	if n := len(listConfigs(t, h.name)); n != 3 {
		t.Errorf("%d Configs after leaf02 left, want 3", n)
	}
	for _, fi := range h.verify.last.Findings {
		if fi.Node == "leaf02" {
			t.Error("the read-back was asked to clear a finding whose node left spec.nodes")
		}
	}

	// the node returns: the finding counts again from the first pass that runs
	h.update(func(f *fabricv1.Fabric) {
		d := defaultFabric(h.name)
		f.Spec.Nodes, f.Spec.Inventory = d.Spec.Nodes, d.Spec.Inventory
	})
	h.reconcile()
	confirmConfigs(t, h.name)
	h.clock.Step(15 * time.Second)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	h.wantCond("Degraded", metav1.ConditionTrue, "StaleConfigurationPossible", "leaf02")
}

// SC-004's declarative negative control (AD-77): overlay.reflectorClients
// defaults to true; declared false it is rendered as route-reflector client
// false on both reflecting spines' Configs and the real read-back reports
// Ready=False/NotConverged naming each spine and the setting, as a
// configuration-integrity check read from the configuration datastore (AD-76);
// declared true again, the Fabric is Ready. overlay.interASVPN false is a
// configuration-integrity case only: it converges.
func TestReflectorClientsFalseIsNotConverged(t *testing.T) {
	h := newHarness(t, "fab-rrclients")
	h.r.Verifier = &verify.Fabric{Reader: configReader{fabric: h.name}, Configs: sdc.New(k8s)}
	h.converge()
	if v := h.fabric().Spec.Overlay.ReflectorClients; v == nil || !*v {
		t.Fatalf("spec.overlay.reflectorClients defaults to true, got %v", v)
	}

	rr := func(node string) any {
		t.Helper()
		name, _ := sdc.ConfigName(h.name, node)
		cfg := &configv1alpha1.Config{}
		must(t, k8s.Get(context.Background(), client.ObjectKey{Namespace: sdc.SystemNamespace, Name: name}, cfg))
		var doc map[string]any
		must(t, json.Unmarshal(cfg.Spec.Config[0].Value.Raw, &doc))
		v := verify.ConfigValues(doc, verify.RouteReflectorClientPath(model.OverlayGroup))
		if len(v) != 1 {
			return nil
		}
		return v[0]
	}
	redeclare := func(v bool) {
		t.Helper()
		h.update(func(f *fabricv1.Fabric) { f.Spec.Overlay.ReflectorClients = ptr(v) })
		h.reconcile()
		confirmConfigs(t, h.name)
		h.clock.Step(15 * time.Second)
		h.reconcile()
	}

	redeclare(false)
	c := h.wantCond("Ready", metav1.ConditionFalse, "NotConverged", "spine01", "spine02", "route-reflector client",
		"spec.overlay.reflectorClients", "configuration-integrity check (read from the configuration datastore)")
	if strings.Contains(c.Message, "leaf01") || strings.Contains(c.Message, "leaf02") || strings.Contains(c.Message, "inter-as-vpn") {
		t.Errorf("only the reflecting spines and route-reflector client are named: %s", c.Message)
	}
	for _, sp := range []string{"spine01", "spine02"} {
		if got := rr(sp); got != "false" {
			t.Errorf("%s: route-reflector client rendered %v, want false stated (never dropped)", sp, got)
		}
	}

	redeclare(true)
	h.wantCond("Ready", metav1.ConditionTrue, "")
	for _, sp := range []string{"spine01", "spine02"} {
		if got := rr(sp); got != "true" {
			t.Errorf("%s: route-reflector client rendered %v, want true", sp, got)
		}
	}

	// interASVPN false: a configuration-integrity case only, it converges
	h.update(func(f *fabricv1.Fabric) { f.Spec.Overlay.InterASVPN = ptr(false) })
	h.reconcile()
	confirmConfigs(t, h.name)
	h.clock.Step(15 * time.Second)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
}

// A declaration that changes the tagging mode of an access port a Network still
// attaches to: Accepted=False/InvalidIntent naming the port and the services,
// zero Config writes (AD-68).
func TestUntaggedFlipRefusedWithZeroConfigWrites(t *testing.T) {
	h := newHarness(t, "fab-flip")
	h.converge()
	nw := &fabricv1.Network{
		ObjectMeta: metav1.ObjectMeta{Name: "svc-tagged", Namespace: nsServices},
		Spec: fabricv1.NetworkSpec{
			VLANs:       []fabricv1.NetworkVLAN{{Name: "v110", VLAN: 110}},
			Attachments: []fabricv1.NetworkAttachment{{Node: "leaf01", Attachment: "ethernet-1/1", VLAN: ptr(fabricv1.AttachmentVLAN(110))}},
		},
	}
	must(t, k8s.Create(context.Background(), nw))
	t.Cleanup(func() { _ = k8s.Delete(context.Background(), nw) })
	before := versions(t, h.name)

	h.update(func(f *fabricv1.Fabric) {
		f.Spec.Inventory[0].UntaggedAccessPorts = []fabricv1.PortName{"ethernet-1/1"}
	})
	h.reconcile()
	h.wantCond("Accepted", metav1.ConditionFalse, "InvalidIntent", "leaf01 ethernet-1/1", nsServices+"/svc-tagged")
	sameVersions(t, "refused tagging-mode flip", before, versions(t, h.name))
	for _, c := range listConfigs(t, h.name) {
		if c.Annotations[sdc.AnnotationSourceGeneration] != "1" {
			t.Errorf("%s re-rendered for the refused generation", c.Name)
		}
	}

	// the Network is gone: the declaration is admissible and renders
	must(t, k8s.Delete(context.Background(), nw))
	if err := k8s.Get(context.Background(), client.ObjectKeyFromObject(nw), &fabricv1.Network{}); !apierrors.IsNotFound(err) {
		t.Fatalf("network still present: %v", err)
	}
	h.reconcile()
	h.wantCond("Accepted", metav1.ConditionTrue, "")
	changed := false
	after := versions(t, h.name)
	for k := range before {
		if after[k] != before[k] {
			changed = true
		}
	}
	if !changed {
		t.Error("the admitted declaration was not rendered")
	}
}

// T182: pool references naming an index the installed authority does not serve are
// Accepted=False/InvalidIntent naming the field, the stated group/kind and the served
// one — before any claim, and with zero Config writes.
func TestPoolRefsNotServedByTheAuthorityAreInvalidIntent(t *testing.T) {
	h := newHarness(t, "fab-poolrefs")
	layerReady(t)
	h.create(func(f *fabricv1.Fabric) {
		f.Spec.Underlay.LoopbackPoolRef.Group, f.Spec.Underlay.LoopbackPoolRef.Kind = "fabric.agentic-netops.io", "IdentifierPool"
		f.Spec.Underlay.ASNPoolRef.Kind = "VLANIndex"
	})
	if res := h.reconcile(); res.RequeueAfter != 0 {
		t.Errorf("a terminal InvalidIntent is not requeued, got %s", res.RequeueAfter)
	}
	h.wantCond("Accepted", metav1.ConditionFalse, "InvalidIntent",
		"spec.underlay.loopbackPoolRef names fabric.agentic-netops.io/IdentifierPool",
		"serves IP claims from ipam.be.kuid.dev/IPIndex",
		"spec.underlay.asnPoolRef names as.be.kuid.dev/VLANIndex", "serves ASN claims from as.be.kuid.dev/ASIndex")
	if c := h.cond("Accepted"); strings.Contains(c.Message, "linkPoolRef") {
		t.Errorf("a matching reference named: %s", c.Message)
	}
	if n := len(listConfigs(t, h.name)); n != 0 {
		t.Fatalf("%d Configs written for refused pool references", n)
	}
	if n := h.claims.count(); n != 0 {
		t.Fatalf("%d claims made for refused pool references", n)
	}
}

// The compatibility set is asserted before rendering: a Schema that differs
// from versions.lock.yaml is Rendered=False/SchemaMismatch with no Config.
func TestSchemaMismatchWritesNoConfig(t *testing.T) {
	h := newHarness(t, "fab-mismatch")
	layerReady(t)
	sc := &invv1alpha1.Schema{}
	must(t, k8s.Get(context.Background(), client.ObjectKey{Namespace: nsTargets, Name: "srl.nokia.sdcio.dev-25.7.1"}, sc))
	orig := sc.Spec.Repositories[1].Ref
	sc.Spec.Repositories[1].Ref = "0123456789abcdef0123456789abcdef01234567"
	must(t, k8s.Update(context.Background(), sc))
	t.Cleanup(func() {
		s := &invv1alpha1.Schema{}
		_ = k8s.Get(context.Background(), client.ObjectKeyFromObject(sc), s)
		s.Spec.Repositories[1].Ref = orig
		_ = k8s.Update(context.Background(), s)
	})
	h.create()
	if res := h.reconcile(); res.RequeueAfter != 0 {
		t.Errorf("a terminal SchemaMismatch is not requeued, got %s", res.RequeueAfter)
	}
	h.wantCond("Rendered", metav1.ConditionFalse, "SchemaMismatch", "part 3")
	if len(listConfigs(t, h.name)) != 0 {
		t.Fatal("Configs written on a SchemaMismatch")
	}
}

// The reconciler registered with a manager (SetupWithManager: the Fabric, the
// Configs it owns, Targets/Schemas/Networks mapped to every Fabric) renders the
// Configs and reacts to the layer's confirmation through the Owns watch.
func TestManagerWiring(t *testing.T) {
	layerReady(t)
	h := newHarness(t, "fab-manager")
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
	h.create()
	eventually(t, 20*time.Second, "four Configs rendered by the managed reconciler", func() bool { return len(listConfigs(t, h.name)) == 4 })
	confirmConfigs(t, h.name)
	eventually(t, 20*time.Second, "Ready=True after the layer confirms", func() bool {
		c := h.cond("Ready")
		return c != nil && c.Status == metav1.ConditionTrue
	})
}

func eventually(t *testing.T, d time.Duration, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// examples/fabric/default-fabric.yaml (data-model.md §3a) is admitted by the CRD.
func TestDefaultFabricExampleIsAdmitted(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(repoRoot, "examples", "fabric", "default-fabric.yaml"))
	must(t, err)
	u := &unstructured.Unstructured{}
	must(t, yaml.Unmarshal(b, &u.Object))
	if u.GetName() != "fabric01" || u.GetNamespace() != nsSystem {
		t.Fatalf("default fabric is %s/%s", u.GetNamespace(), u.GetName())
	}
	must(t, k8s.Create(context.Background(), u, client.DryRunAll, client.FieldValidation("Strict")))
}
