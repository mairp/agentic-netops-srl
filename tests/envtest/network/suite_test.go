//go:build envtest

// The shared harness of the Network envtest package (T054, T170; the deletion suite of T060 and
// the webhook suite of T061 live beside it). One API server (envtest) with the first-party CRDs
// from config/crd and the device-configuration layer's own CRDs read unchanged from the
// checked-out config-server v0.0.58 sources (as tests/envtest/fabric does, with the same
// in-memory storage-version fix for crds/config.sdcio.dev_targets.yaml), a test standing in for
// the layer (it sets Target and Config status and writes Deviations), a fake pkg/kuid Claims
// with a holder model and error injection (the allocation authority is an aggregated API with
// no CRDs), a fake read-back behind the reconciler's Verifier, a fake telemetry-health input
// and a fake clock.
//
// The reconciler is driven by direct Reconcile calls (harness.reconcile), as the Fabric suite
// does, so that every RequeueAfter the reconciler returns is asserted under the fake clock;
// TestNetworkManagerWiring runs the same reconciler under a manager (SetupWithManager) to show
// the watches drive it.
//
// Helpers for the other files of this package (deletion_test.go reuses them — the webhook suite
// starts its own environment and uses none of them):
//
//	k8s, restCfg, scheme, lockSet, t0              the client, config, scheme, lock and fake-clock origin
//	nsSystem, nsServices, nsIntent, nsKuid, leaves  namespaces and the fabric's leaves
//	sharedFabric                                  the Accepted Fabric "fabric01" every Network resolves through
//	newHarness(t, ns, name, mutate...)             a reconciler with fresh fakes over one Network name
//	  h.create(spec, mut...) / h.update / h.network / h.cond / h.wantCond / h.reconcile / h.reconcileErr
//	  h.converge(spec, mut...)                    create, render, layer confirms, Ready=True at t0
//	  h.configs() / h.claims / h.verify / h.tele / h.rec / h.clock / h.r
//	setTarget(t, node, ready)                      the layer's Target status
//	confirmConfigs(t, ns, name, failed...)         the layer confirms (or fails) a Network's Configs
//	holdConfig(t, name) / releaseConfig(t, name)   a layer-side finalizer that keeps a Config's removal pending
//	setDeviation(t, cfg, node, devs...) / clearDeviation(t, cfg)
//	plantConfig(t, name, node, priority, value)    a fixture Config of another source
//	setFabricConditions(t, accepted, ready) / updateFabric(t, mut) / restoreFabric(t)
//	vlanSpec / macvrfSpec / gatewaySpec / ipvrfSpec / aclSpec, att / attUntagged / attVRF
//	versionsOf(t, ns, name) / sameVersions         Config resourceVersion+generation snapshots
//	fakeClaims: seed, count, created, calls, setFail, releasedNames, onCreate
//	fakeVerifier: set(node, mode) with modes "" (pass), "missing" (RoutesMissing), "cannot"
package network_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	goruntime "runtime"
	"sort"
	"strconv"
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
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	clocktesting "k8s.io/utils/clock/testing"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	"sigs.k8s.io/yaml"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/controllers/network"
	"github.com/mairp/agentic-netops-srl/internal/compat"
	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/verify"
	"github.com/mairp/agentic-netops-srl/pkg/kuid"
	"github.com/mairp/agentic-netops-srl/pkg/sdc"
)

const (
	nsSystem   = "agentic-netops-system"
	nsServices = "agentic-netops-services"
	nsIntent   = "agentic-netops-intent"
	nsKuid     = "kuid-system"
	// nsTargets holds the layer's Targets and Schema (AD-82 decision 2026-09-21-target-namespace).
	nsTargets = nsSystem

	sharedFabric = "fabric01"
	vniIndex     = sharedFabric + "-vni"
	vlanIndex    = sharedFabric + "-vlan"
	// holdFinalizer is the layer stand-in's own finalizer on a Config: while it is set the
	// Config's removal is not yet read back.
	holdFinalizer = "layer.test.agentic-netops.io/hold"
)

var (
	restCfg  *rest.Config
	k8s      client.Client
	scheme   *k8sruntime.Scheme
	repoRoot string
	lockSet  *compat.Set
	allNodes = []string{"leaf01", "leaf02", "spine01", "spine02"}
	leaves   = []string{"leaf01", "leaf02"}
	t0       = time.Date(2026, 9, 21, 10, 0, 0, 0, time.UTC)
)

func TestMain(m *testing.M) {
	_, file, _, _ := goruntime.Caller(0)
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
		for _, ns := range []string{nsSystem, nsServices, nsIntent, nsKuid} {
			if err := k8s.Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: ns}}); err != nil {
				fmt.Fprintln(os.Stderr, err)
				return 1
			}
		}
		if err := createLayerObjects(ctx); err != nil {
			fmt.Fprintln(os.Stderr, "envtest: layer objects:", err)
			return 1
		}
		if err := createSharedFabric(ctx); err != nil {
			fmt.Fprintln(os.Stderr, "envtest: shared Fabric:", err)
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

func layerCond(typ condv1alpha1.ConditionType, st metav1.ConditionStatus, reason string, gen int64) condv1alpha1.Condition {
	return condv1alpha1.Condition{Condition: metav1.Condition{Type: string(typ), Status: st, Reason: reason,
		Message: reason, LastTransitionTime: metav1.Now(), ObservedGeneration: gen}}
}

func createLayerObjects(ctx context.Context) error {
	sc := &invv1alpha1.Schema{ObjectMeta: metav1.ObjectMeta{Name: "srl.nokia.sdcio.dev-25.7.1", Namespace: nsTargets}}
	sc.Spec.Provider, sc.Spec.Version = lockSet.Schema.Provider, lockSet.Schema.Version
	for i, r := range lockSet.Schema.Repositories {
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
	sc.SetConditions(layerCond(condv1alpha1.ConditionTypeReady, metav1.ConditionTrue, "Ready", 0))
	if err := k8s.Status().Update(ctx, sc); err != nil {
		return err
	}
	for _, n := range allNodes {
		tg := &configv1alpha1.Target{ObjectMeta: metav1.ObjectMeta{Name: n, Namespace: nsTargets}}
		tg.Spec.Provider = lockSet.Schema.Provider
		tg.Spec.Address = "172.25.25.1:57400"
		tg.Spec.ConnectionProfile = "gnmi-tls"
		tg.Spec.Credentials = "srl-credentials"
		if err := k8s.Create(ctx, tg); err != nil {
			return err
		}
		if err := targetStatus(ctx, n, true); err != nil {
			return err
		}
	}
	return nil
}

func targetStatus(ctx context.Context, node string, ready bool) error {
	tg := &configv1alpha1.Target{}
	if err := k8s.Get(ctx, client.ObjectKey{Namespace: nsTargets, Name: node}, tg); err != nil {
		return err
	}
	st, reason := metav1.ConditionTrue, "Ready"
	if !ready {
		st, reason = metav1.ConditionFalse, "Failed"
	}
	tg.Status.Conditions = []condv1alpha1.Condition{
		layerCond(condv1alpha1.ConditionTypeReady, st, reason, 0),
		layerCond(configv1alpha1.ConditionTypeTargetDiscoveryReady, metav1.ConditionTrue, "Ready", 0),
		layerCond(configv1alpha1.ConditionTypeTargetDatastoreReady, st, reason, 0),
		layerCond(configv1alpha1.ConditionTypeTargetConnectionReady, st, reason, 0),
	}
	tg.Status.DiscoveryInfo = &configv1alpha1.DiscoveryInfo{Provider: lockSet.Schema.Provider, Version: lockSet.DeviceImage.Tag, Hostname: node}
	return k8s.Status().Update(ctx, tg)
}

// setTarget sets a Target Ready or not, as the layer reports it; a test that takes one down
// restores it at cleanup.
func setTarget(t *testing.T, node string, ready bool) {
	t.Helper()
	must(t, targetStatus(context.Background(), node, ready))
	if !ready {
		t.Cleanup(func() { _ = targetStatus(context.Background(), node, true) })
	}
}

// confirmConfigs marks every Config of the Network ns/name applied (Ready at its generation),
// except those of the nodes in failed, which report a failed transaction.
func confirmConfigs(t *testing.T, ns, name string, failed ...string) {
	t.Helper()
	for _, c := range listNetworkConfigs(t, ns, name) {
		c := c
		node := c.Labels[sdc.LabelTargetName]
		if contains(failed, node) {
			f := condv1alpha1.Failed("transaction failed on " + node + ": commit rejected")
			f.ObservedGeneration = c.Generation
			c.Status.Conditions = []condv1alpha1.Condition{f}
		} else {
			c.Status.Conditions = []condv1alpha1.Condition{layerCond(condv1alpha1.ConditionTypeReady, metav1.ConditionTrue, "Ready", c.Generation)}
		}
		must(t, k8s.Status().Update(context.Background(), &c))
	}
}

// holdConfig sets the layer stand-in's finalizer on a Config: its removal stays pending.
func holdConfig(t *testing.T, name string) {
	t.Helper()
	c := &configv1alpha1.Config{}
	must(t, k8s.Get(context.Background(), client.ObjectKey{Namespace: nsSystem, Name: name}, c))
	controllerutil.AddFinalizer(c, holdFinalizer)
	must(t, k8s.Update(context.Background(), c))
	t.Cleanup(func() { releaseConfig(t, name) })
}

// releaseConfig removes the layer stand-in's finalizer: a pending removal completes.
func releaseConfig(t *testing.T, name string) {
	c := &configv1alpha1.Config{}
	if err := k8s.Get(context.Background(), client.ObjectKey{Namespace: nsSystem, Name: name}, c); err != nil {
		return
	}
	if controllerutil.RemoveFinalizer(c, holdFinalizer) {
		_ = k8s.Update(context.Background(), c)
	}
}

// setDeviation writes the config-typed Deviation of Config cfg (bound to node) with devs.
func setDeviation(t *testing.T, cfg, node string, devs ...configv1alpha1.ConfigDeviation) {
	t.Helper()
	name := configv1alpha1.DeviationName(configv1alpha1.DeviationType_CONFIG, cfg)
	d := &configv1alpha1.Deviation{}
	err := k8s.Get(context.Background(), client.ObjectKey{Namespace: nsSystem, Name: name}, d)
	if apierrors.IsNotFound(err) {
		typ := configv1alpha1.DeviationType_CONFIG
		d = &configv1alpha1.Deviation{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: nsSystem,
			Labels: map[string]string{sdc.LabelTargetName: node, sdc.LabelTargetNamespace: nsTargets}},
			Spec: configv1alpha1.DeviationSpec{DeviationType: &typ, Deviations: devs}}
		must(t, k8s.Create(context.Background(), d))
		t.Cleanup(func() { clearDeviation(t, cfg) })
		return
	}
	must(t, err)
	d.Spec.Deviations = devs
	must(t, k8s.Update(context.Background(), d))
}

func clearDeviation(t *testing.T, cfg string) {
	d := &configv1alpha1.Deviation{ObjectMeta: metav1.ObjectMeta{Namespace: nsSystem,
		Name: configv1alpha1.DeviationName(configv1alpha1.DeviationType_CONFIG, cfg)}}
	_ = client.IgnoreNotFound(k8s.Delete(context.Background(), d))
}

func deviation(path, reason string) configv1alpha1.ConfigDeviation {
	want, have := "enable", "disable"
	return configv1alpha1.ConfigDeviation{Path: path, DesiredValue: &want, ActualValue: &have, Reason: reason}
}

// plantConfig creates a fixture Config of another source bound to node, at priority, whose
// native value is value; removed at cleanup.
func plantConfig(t *testing.T, name, node string, priority int32, value string) {
	t.Helper()
	rev := true
	c := &configv1alpha1.Config{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: nsSystem,
			Labels:      map[string]string{sdc.LabelTargetName: node, sdc.LabelTargetNamespace: nsTargets},
			Annotations: map[string]string{sdc.AnnotationSourceUID: "fixture-" + name}},
		Spec: configv1alpha1.ConfigSpec{Priority: priority, Revertive: &rev,
			Config: []configv1alpha1.ConfigBlob{{Path: "/", Value: k8sruntime.RawExtension{Raw: []byte(value)}}}},
	}
	must(t, k8s.Create(context.Background(), c))
	t.Cleanup(func() { _ = k8s.Delete(context.Background(), c) })
}

// ---------------------------------------------------------------------------
// The shared Fabric.
// ---------------------------------------------------------------------------

func ptr[T any](v T) *T { return &v }

func defaultFabric() *fabricv1.Fabric {
	pool := func(g, k, n string) *fabricv1.PoolRef {
		return &fabricv1.PoolRef{Group: g, Kind: k, Name: n, Namespace: nsKuid}
	}
	return &fabricv1.Fabric{
		ObjectMeta: metav1.ObjectMeta{Name: sharedFabric, Namespace: nsSystem},
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
				{Node: "leaf01", AccessPorts: []fabricv1.PortName{"ethernet-1/1", "ethernet-1/2"}, FabricPorts: []fabricv1.PortName{"ethernet-1/49", "ethernet-1/50"}},
				{Node: "leaf02", AccessPorts: []fabricv1.PortName{"ethernet-1/1", "ethernet-1/2"}, FabricPorts: []fabricv1.PortName{"ethernet-1/49", "ethernet-1/50"}},
				{Node: "spine01", FabricPorts: []fabricv1.PortName{"ethernet-1/1", "ethernet-1/2"}},
				{Node: "spine02", FabricPorts: []fabricv1.PortName{"ethernet-1/1", "ethernet-1/2"}},
			},
		},
	}
}

func createSharedFabric(ctx context.Context) error {
	f := defaultFabric()
	if err := k8s.Create(ctx, f); err != nil {
		return err
	}
	return fabricStatus(ctx, true, true)
}

// fabricStatus writes the shared Fabric's Accepted and Ready as its reconciler would, with the
// loopback allocations the read-back input carries.
func fabricStatus(ctx context.Context, accepted, ready bool) error {
	f := &fabricv1.Fabric{}
	if err := k8s.Get(ctx, client.ObjectKey{Namespace: nsSystem, Name: sharedFabric}, f); err != nil {
		return err
	}
	now := metav1.NewTime(time.Now())
	c := func(typ string, ok bool, reason string) metav1.Condition {
		st := metav1.ConditionTrue
		if !ok {
			st = metav1.ConditionFalse
		} else {
			reason = "AsExpected"
		}
		return metav1.Condition{Type: typ, Status: st, Reason: reason, Message: typ, LastTransitionTime: now, ObservedGeneration: f.Generation}
	}
	f.Status.Conditions = []metav1.Condition{c("Accepted", accepted, "InvalidIntent"), c("Ready", ready, "NotConverged")}
	f.Status.Allocations = []fabricv1.AllocationRef{
		{Name: "fabric01.leaf01.loopback", Namespace: nsKuid, IndexKind: "ipam", Purpose: "loopback", Node: "leaf01", Value: "10.0.0.1/32", Bound: true},
		{Name: "fabric01.leaf02.loopback", Namespace: nsKuid, IndexKind: "ipam", Purpose: "loopback", Node: "leaf02", Value: "10.0.0.2/32", Bound: true},
	}
	return k8s.Status().Update(ctx, f)
}

// setFabricConditions sets the shared Fabric's Accepted and Ready; restored at cleanup.
func setFabricConditions(t *testing.T, accepted, ready bool) {
	t.Helper()
	must(t, fabricStatus(context.Background(), accepted, ready))
	t.Cleanup(func() { restoreFabric(t) })
}

// updateFabric changes the shared Fabric's spec; restored at cleanup.
func updateFabric(t *testing.T, mut func(*fabricv1.Fabric)) {
	t.Helper()
	f := &fabricv1.Fabric{}
	must(t, k8s.Get(context.Background(), client.ObjectKey{Namespace: nsSystem, Name: sharedFabric}, f))
	mut(f)
	must(t, k8s.Update(context.Background(), f))
	must(t, fabricStatus(context.Background(), true, true))
	t.Cleanup(func() { restoreFabric(t) })
}

// deleteFabric removes the shared Fabric; restored at cleanup.
func deleteFabric(t *testing.T) {
	t.Helper()
	must(t, k8s.Delete(context.Background(), &fabricv1.Fabric{ObjectMeta: metav1.ObjectMeta{Namespace: nsSystem, Name: sharedFabric}}))
	t.Cleanup(func() { restoreFabric(t) })
}

// restoreFabric puts the shared Fabric back to its default spec, Accepted and Ready.
func restoreFabric(t *testing.T) {
	ctx := context.Background()
	f := &fabricv1.Fabric{}
	err := k8s.Get(ctx, client.ObjectKey{Namespace: nsSystem, Name: sharedFabric}, f)
	if apierrors.IsNotFound(err) {
		if err := createSharedFabric(ctx); err != nil {
			t.Errorf("restore Fabric: %v", err)
		}
		return
	}
	if err != nil {
		t.Errorf("restore Fabric: %v", err)
		return
	}
	f.Spec = defaultFabric().Spec
	if err := k8s.Update(ctx, f); err != nil {
		t.Errorf("restore Fabric: %v", err)
	}
	if err := fabricStatus(ctx, true, true); err != nil {
		t.Errorf("restore Fabric status: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Fakes behind the reconciler's interfaces.
// ---------------------------------------------------------------------------

// fakeClaims is the allocation authority behind pkg/kuid's Claims seam, with a holder model:
// a stated value held (bound) by a claim of another name, or outside the index's band, is
// refused with the authority's own message naming the holder or the band; any operation can be
// made to ERROR (not ErrNotFound) — the authority failing to answer (AD-56). Labels are the
// claims' metadata.labels, the only set ListByLabel selects on (AD-32).
type fakeClaims struct {
	mu       sync.Mutex
	claims   map[string]kuid.Claimed
	fail     map[string]bool // "get", "list", "create", "release"
	calls    map[string]int
	released []string
	created  []kuid.Request
	// onCreate runs before a ClaimValue is answered (the "before any Config exists" check).
	onCreate func(req kuid.Request)
}

func newFakeClaims() *fakeClaims {
	return &fakeClaims{claims: map[string]kuid.Claimed{}, fail: map[string]bool{}, calls: map[string]int{}}
}

func claimKey(r kuid.Ref) string { return string(r.Kind) + "/" + r.Namespace + "/" + r.Name }

var errAuthority = errors.New("the aggregated API genid.be.kuid.dev is unavailable (fake)")

func bandOf(index string) (int64, int64) {
	switch {
	case strings.HasSuffix(index, "-vni"):
		return 10000, 20000
	case strings.HasSuffix(index, "-vlan"):
		return 1000, 4000
	}
	return 0, 1 << 32
}

func (f *fakeClaims) Claim(ctx context.Context, req kuid.Request) (kuid.Claimed, error) {
	return kuid.Claimed{}, errors.New("the Network reconciler never makes a dynamic claim")
}

func (f *fakeClaims) ClaimValue(ctx context.Context, req kuid.Request, v string) (kuid.Claimed, error) {
	if f.onCreate != nil {
		f.onCreate(req)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls["create"]++
	if f.fail["create"] {
		return kuid.Claimed{}, errAuthority
	}
	if c, ok := f.claims[claimKey(req.Ref)]; ok {
		if c.Stated == v {
			return c, nil
		}
		return kuid.Claimed{}, fmt.Errorf("%s states %s, not %s: a claim is never moved", req.Ref, c.Stated, v)
	}
	f.created = append(f.created, req)
	c := kuid.Claimed{Ref: req.Ref, Index: req.Index, Labels: copyMap(req.Labels), Stated: v}
	lo, hi := bandOf(req.Index)
	val, _ := strconv.ParseInt(v, 10, 64)
	var holder string
	for _, o := range f.claims {
		if o.Kind == req.Kind && o.Namespace == req.Namespace && o.Bound() && o.Value == v {
			holder = o.Namespace + "/" + o.Name
		}
	}
	switch {
	case val < lo || val > hi:
		c.Reason, c.Message = "Failed", fmt.Sprintf("value %s is outside the range %d–%d of index %s", v, lo, hi, req.Index)
	case holder != "":
		c.Reason, c.Message = "Failed", fmt.Sprintf("value %s is already held by another owner: claim %s", v, holder)
	default:
		c.Ready, c.Value, c.Reason = true, v, "Ready"
	}
	f.claims[claimKey(req.Ref)] = c
	return c, nil
}

func (f *fakeClaims) Release(ctx context.Context, ref kuid.Ref) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls["release"]++
	if f.fail["release"] {
		return errAuthority
	}
	delete(f.claims, claimKey(ref))
	f.released = append(f.released, ref.Name)
	return nil
}

func (f *fakeClaims) Get(ctx context.Context, ref kuid.Ref) (kuid.Claimed, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls["get"]++
	if f.fail["get"] {
		return kuid.Claimed{}, errAuthority
	}
	c, ok := f.claims[claimKey(ref)]
	if !ok {
		return kuid.Claimed{}, fmt.Errorf("%s: %w", ref, kuid.ErrNotFound)
	}
	return c, nil
}

func (f *fakeClaims) ListByLabel(ctx context.Context, kind kuid.Kind, ns string, labels map[string]string) ([]kuid.Claimed, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls["list"]++
	f.calls["list/"+string(kind)]++
	if f.fail["list"] {
		return nil, errAuthority
	}
	var out []kuid.Claimed
	for _, c := range f.claims {
		if c.Kind != kind || c.Namespace != ns {
			continue
		}
		ok := true
		for k, v := range labels {
			if c.Labels[k] != v {
				ok = false
			}
		}
		if ok {
			out = append(out, c)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

func (f *fakeClaims) Index(k kuid.Kind) kuid.IndexType { return kuid.NewUpstream(nil).Index(k) }

func (f *fakeClaims) Authority() string { return kuid.AuthorityKuid }

// seed plants a claim someone else made (the tier, another service), bound to value unless
// unbound is set.
func (f *fakeClaims) seed(kind kuid.Kind, name, value string, labels map[string]string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	idx := vniIndex
	if kind == kuid.KindVLAN {
		idx = vlanIndex
	}
	ref := kuid.Ref{Kind: kind, Namespace: nsKuid, Name: name}
	f.claims[claimKey(ref)] = kuid.Claimed{Ref: ref, Index: idx, Labels: copyMap(labels), Stated: value, Value: value, Ready: true, Reason: "Ready"}
}

func (f *fakeClaims) get(kind kuid.Kind, name string) (kuid.Claimed, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	c, ok := f.claims[claimKey(kuid.Ref{Kind: kind, Namespace: nsKuid, Name: name})]
	return c, ok
}

func (f *fakeClaims) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.claims)
}

func (f *fakeClaims) countKind(k kuid.Kind) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.claims {
		if c.Kind == k {
			n++
		}
	}
	return n
}

func (f *fakeClaims) call(op string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls[op]
}

func (f *fakeClaims) createdCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.created)
}

func (f *fakeClaims) setFail(op string, on bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.fail[op] = on
}

func (f *fakeClaims) releasedNames() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.released...)
}

func copyMap(in map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range in {
		out[k] = v
	}
	return out
}

// fakeVerifier is the service read-back behind the reconciler's Verifier: per node, "" passes,
// "missing" finds a remote VTEP missing (RoutesMissing), "cannot" makes the pass one that could
// not run.
type fakeVerifier struct {
	mu    sync.Mutex
	calls int
	mode  map[string]string
	last  verify.ServiceInput
}

func (v *fakeVerifier) VerifyService(ctx context.Context, in verify.ServiceInput) (verify.ServiceResult, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.calls++
	v.last = in
	cannot := map[string]error{}
	var res verify.ServiceResult
	for _, n := range in.Nodes {
		switch v.mode[n.Node] {
		case "cannot":
			cannot[n.Node] = errors.New("connection refused")
		case "missing":
			res.Missing = append(res.Missing, verify.Invariant{Node: n.Node, Check: verify.CheckRemoteVTEP,
				Detail: "remote VTEP 10.0.0.2 absent from /tunnel/vxlan-tunnel"})
		}
	}
	if len(cannot) > 0 {
		return verify.ServiceResult{}, &verify.CouldNotRunError{Causes: cannot}
	}
	return res, nil
}

func (v *fakeVerifier) set(node, mode string) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.mode == nil {
		v.mode = map[string]string{}
	}
	v.mode[node] = mode
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

// fakeRenderer renders a deterministic native document per node from the service model, with
// the device's list structure — every service object beneath a list entry it alone keys (the
// subinterface, irb0's subinterface, the vxlan-interface, the network-instance, the acl
// interface) — so the overlap check sees the shapes the real render has. It renders no
// access-list filter and refuses a node carrying one: the suites that exercise access lists
// (acl_lifecycle_test.go) drive the real internal/render/srl renderer instead (T106).
type fakeRenderer struct{}

func (fakeRenderer) RenderService(m *model.ServiceModel) (map[string]network.Rendered, error) {
	out := map[string]network.Rendered{}
	for _, n := range m.Nodes {
		if len(n.ACLFilters) > 0 {
			return nil, fmt.Errorf("render service node %s: the fake renderer renders no access-list filter; acl_lifecycle_test.go uses the real renderer", n.Node)
		}
		ports := map[string][]any{}
		var portNames []string
		for _, s := range n.Subinterfaces {
			sub := map[string]any{"index": s.Index, "type": "srl_nokia-interfaces:" + string(s.Type), "admin-state": "enable"}
			if s.VLAN != 0 {
				sub["srl_nokia-interfaces-vlans:vlan"] = map[string]any{"encap": map[string]any{"single-tagged": map[string]any{"vlan-id": s.VLAN}}}
			}
			if _, ok := ports[s.Port]; !ok {
				portNames = append(portNames, s.Port)
			}
			ports[s.Port] = append(ports[s.Port], sub)
		}
		var ifs []any
		for _, p := range portNames {
			ifs = append(ifs, map[string]any{"name": p, "subinterface": ports[p]})
		}
		if len(n.IRB) > 0 {
			var subs []any
			for _, irb := range n.IRB {
				subs = append(subs, map[string]any{"index": irb.Index, "admin-state": "enable", "ip-mtu": irb.IPMTU,
					"anycast-gw": map[string]any{"virtual-router-id": irb.VirtualRouterID}})
			}
			ifs = append(ifs, map[string]any{"name": "irb0", "subinterface": subs})
		}
		doc := map[string]any{}
		if len(ifs) > 0 {
			doc["srl_nokia-interfaces:interface"] = ifs
		}
		if len(n.VXLANInterfaces) > 0 {
			var vx []any
			for _, v := range n.VXLANInterfaces {
				vx = append(vx, map[string]any{"index": v.Index, "type": "srl_nokia-interfaces:" + string(v.Type), "ingress": map[string]any{"vni": v.VNI}})
			}
			doc["srl_nokia-tunnel-interfaces:tunnel-interface"] = []any{map[string]any{"name": "vxlan0", "vxlan-interface": vx}}
		}
		var nis []any
		for _, ni := range n.NetworkInstances {
			e := map[string]any{"name": ni.Name, "type": "srl_nokia-network-instance:" + string(ni.Type), "admin-state": "enable", "description": ni.Description}
			var members []any
			for _, i := range ni.Interfaces {
				members = append(members, map[string]any{"name": i})
			}
			e["interface"] = members
			if ni.VXLANInterface != "" {
				e["vxlan-interface"] = []any{map[string]any{"name": ni.VXLANInterface}}
			}
			nis = append(nis, e)
		}
		if len(nis) > 0 {
			doc["srl_nokia-network-instance:network-instance"] = nis
		}
		var acl []any
		for _, ai := range n.ACLInterfaces {
			if ai.Ref != nil {
				acl = append(acl, map[string]any{"interface-id": ai.InterfaceID,
					"interface-ref": map[string]any{"interface": ai.Ref.Interface, "subinterface": ai.Ref.Subinterface}})
			}
		}
		if len(acl) > 0 {
			doc["srl_nokia-acl:acl"] = map[string]any{"interface": acl}
		}
		b, err := json.Marshal(doc)
		if err != nil {
			return nil, err
		}
		sum := sha256.Sum256(b)
		out[n.Node] = network.Rendered{Node: n.Node, JSON: b, Hash: hex.EncodeToString(sum[:])}
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
	ns     string
	name   string
	r      *network.Reconciler
	clock  *clocktesting.FakeClock
	claims *fakeClaims
	verify *fakeVerifier
	tele   *fakeTelemetry
	rec    *recorder
}

func newHarness(t *testing.T, ns, name string, mutate ...func(*network.Settings)) *harness {
	h := &harness{t: t, ns: ns, name: name, clock: clocktesting.NewFakeClock(t0), claims: newFakeClaims(),
		verify: &fakeVerifier{}, tele: &fakeTelemetry{ok: true}, rec: &recorder{}}
	h.r = h.newReconciler(mutate...)
	return h
}

// with returns a harness over another Network name sharing this one's reconciler and fakes.
func (h *harness) with(ns, name string) *harness {
	o := *h
	o.ns, o.name = ns, name
	return &o
}

func (h *harness) newReconciler(mutate ...func(*network.Settings)) *network.Reconciler {
	st := network.DefaultSettings()
	for _, m := range mutate {
		m(&st)
	}
	return &network.Reconciler{
		Client: k8s, SDC: sdc.New(k8s), Claims: h.claims, Renderer: fakeRenderer{}, Verifier: h.verify,
		Telemetry: h.tele, Compat: lockSet, Recorder: h.rec, Clock: h.clock, Settings: st,
	}
}

func (h *harness) reconcileErr() (ctrl.Result, error) {
	return h.r.Reconcile(context.Background(), ctrl.Request{NamespacedName: types.NamespacedName{Namespace: h.ns, Name: h.name}})
}

func (h *harness) reconcile() ctrl.Result {
	h.t.Helper()
	res, err := h.reconcileErr()
	if err != nil {
		h.t.Fatalf("reconcile %s/%s: %v", h.ns, h.name, err)
	}
	return res
}

func (h *harness) network() *fabricv1.Network {
	h.t.Helper()
	n := &fabricv1.Network{}
	must(h.t, k8s.Get(context.Background(), client.ObjectKey{Namespace: h.ns, Name: h.name}, n))
	return n
}

func (h *harness) gone() bool {
	err := k8s.Get(context.Background(), client.ObjectKey{Namespace: h.ns, Name: h.name}, &fabricv1.Network{})
	return apierrors.IsNotFound(err)
}

func (h *harness) cond(typ string) *metav1.Condition {
	return meta.FindStatusCondition(h.network().Status.Conditions, typ)
}

func (h *harness) wantCond(typ string, st metav1.ConditionStatus, reason string, msgHas ...string) *metav1.Condition {
	h.t.Helper()
	c := h.cond(typ)
	if c == nil {
		h.t.Fatalf("%s/%s: no %s condition", h.ns, h.name, typ)
	}
	if c.Status != st || (reason != "" && c.Reason != reason) {
		h.t.Fatalf("%s/%s: %s=%s/%s (%s), want %s/%s", h.ns, h.name, typ, c.Status, c.Reason, c.Message, st, reason)
	}
	for _, s := range msgHas {
		if !strings.Contains(c.Message, s) {
			h.t.Fatalf("%s/%s: %s message %q lacks %q", h.ns, h.name, typ, c.Message, s)
		}
	}
	return c
}

// notCond asserts typ does not carry reason.
func (h *harness) notCond(typ, reason string) {
	h.t.Helper()
	if c := h.cond(typ); c != nil && c.Reason == reason {
		h.t.Fatalf("%s/%s: %s=%s/%s (%s) must not be set", h.ns, h.name, typ, c.Status, c.Reason, c.Message)
	}
}

// create creates the Network; at cleanup the Network (its finalizer dropped) and its Configs go.
func (h *harness) create(spec fabricv1.NetworkSpec, mut ...func(*fabricv1.Network)) *fabricv1.Network {
	h.t.Helper()
	n := &fabricv1.Network{ObjectMeta: metav1.ObjectMeta{Name: h.name, Namespace: h.ns}, Spec: spec}
	for _, m := range mut {
		m(n)
	}
	must(h.t, k8s.Create(context.Background(), n))
	ns, name := h.ns, h.name
	h.t.Cleanup(func() { cleanupNetwork(h.t, ns, name) })
	return n
}

func cleanupNetwork(t *testing.T, ns, name string) {
	ctx := context.Background()
	n := &fabricv1.Network{}
	if err := k8s.Get(ctx, client.ObjectKey{Namespace: ns, Name: name}, n); err == nil {
		if controllerutil.RemoveFinalizer(n, network.Finalizer) {
			_ = k8s.Update(ctx, n)
		}
		_ = k8s.Delete(ctx, n)
	}
	for _, c := range listNetworkConfigs(t, ns, name) {
		c := c
		if controllerutil.RemoveFinalizer(&c, holdFinalizer) {
			_ = k8s.Update(ctx, &c)
		}
		_ = k8s.Delete(ctx, &c)
	}
}

func (h *harness) update(mut func(*fabricv1.Network)) {
	h.t.Helper()
	n := h.network()
	mut(n)
	must(h.t, k8s.Update(context.Background(), n))
}

func (h *harness) delete() {
	h.t.Helper()
	must(h.t, k8s.Delete(context.Background(), h.network()))
}

func (h *harness) configs() []configv1alpha1.Config { return listNetworkConfigs(h.t, h.ns, h.name) }

// converge creates the Network and reconciles until Ready=True at t0: the reconciler renders,
// the layer confirms, the read-back passes.
func (h *harness) converge(spec fabricv1.NetworkSpec, mut ...func(*fabricv1.Network)) {
	h.t.Helper()
	h.create(spec, mut...)
	h.reconcile()
	if len(h.configs()) == 0 {
		c := h.cond("Ready")
		h.t.Fatalf("%s/%s rendered no Config: %+v", h.ns, h.name, c)
	}
	confirmConfigs(h.t, h.ns, h.name)
	res := h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	if res.RequeueAfter != h.r.Settings.ReverifyInterval {
		h.t.Fatalf("a Ready Network is requeued at %s, want the re-verification interval %s", res.RequeueAfter, h.r.Settings.ReverifyInterval)
	}
}

// ---------------------------------------------------------------------------
// Specs.
// ---------------------------------------------------------------------------

func att(node, port string, vlan int64) fabricv1.NetworkAttachment {
	v := fabricv1.AttachmentVLAN(vlan)
	return fabricv1.NetworkAttachment{Node: fabricv1.DNSLabel(node), Attachment: fabricv1.PortName(port), VLAN: &v}
}

func attUntagged(node, port string) fabricv1.NetworkAttachment {
	return fabricv1.NetworkAttachment{Node: fabricv1.DNSLabel(node), Attachment: fabricv1.PortName(port)}
}

func attVRF(a fabricv1.NetworkAttachment, vrf string) fabricv1.NetworkAttachment {
	a.VRF = fabricv1.DNSLabel(vrf)
	return a
}

func vlanSpec(vlan int64, atts ...fabricv1.NetworkAttachment) fabricv1.NetworkSpec {
	return fabricv1.NetworkSpec{VLANs: []fabricv1.NetworkVLAN{{Name: "v", VLAN: fabricv1.VLANID(vlan)}}, Attachments: atts}
}

func macvrfSpec(vlan, l2vni int64, atts ...fabricv1.NetworkAttachment) fabricv1.NetworkSpec {
	return fabricv1.NetworkSpec{BridgeDomains: []fabricv1.BridgeDomain{{Name: "bd", VLAN: fabricv1.VLANID(vlan), L2VNI: fabricv1.VNI(l2vni)}}, Attachments: atts}
}

func gatewaySpec(vlan, l2vni, l3vni int64, gw string, atts ...fabricv1.NetworkAttachment) fabricv1.NetworkSpec {
	return fabricv1.NetworkSpec{
		BridgeDomains: []fabricv1.BridgeDomain{{Name: "bd", VLAN: fabricv1.VLANID(vlan), L2VNI: fabricv1.VNI(l2vni),
			IRB: &fabricv1.IRBSpec{VRF: "vrf", GatewayIPv4: gw}}},
		Routers:     []fabricv1.NetworkRouter{{Name: "vrf", L3VNI: fabricv1.VNI(l3vni)}},
		Attachments: atts,
	}
}

func ipvrfSpec(l3vni int64, atts ...fabricv1.NetworkAttachment) fabricv1.NetworkSpec {
	for i := range atts {
		atts[i].VRF = "vrf"
	}
	return fabricv1.NetworkSpec{Routers: []fabricv1.NetworkRouter{{Name: "vrf", L3VNI: fabricv1.VNI(l3vni), Prefixes: []fabricv1.IPPrefix{"10.20.0.0/24"}}}, Attachments: atts}
}

func aclSpec(atts ...fabricv1.NetworkAttachment) fabricv1.NetworkSpec {
	return fabricv1.NetworkSpec{AccessLists: []fabricv1.AccessList{{Name: "filter", Stage: "ingress", Type: "ipv4", DefaultAction: "deny",
		Rules: []fabricv1.ACLRule{{Name: "https", Priority: 100, Action: "permit", Protocol: "tcp", DestinationPort: "443"}}}}, Attachments: atts}
}

func withCorrelation(id string) func(*fabricv1.Network) {
	return func(n *fabricv1.Network) {
		if n.Labels == nil {
			n.Labels = map[string]string{}
		}
		n.Labels[kuid.LabelCorrelationID] = id
	}
}

// ---------------------------------------------------------------------------
// Assertions.
// ---------------------------------------------------------------------------

func listNetworkConfigs(t *testing.T, ns, name string) []configv1alpha1.Config {
	t.Helper()
	l := &configv1alpha1.ConfigList{}
	must(t, k8s.List(context.Background(), l, client.InNamespace(nsSystem),
		client.MatchingLabels{sdc.LabelNetworkNamespace: ns, sdc.LabelNetworkName: name}))
	sort.Slice(l.Items, func(i, j int) bool { return l.Items[i].Name < l.Items[j].Name })
	return l.Items
}

// versionsOf snapshots every Config of a Network: resourceVersion and generation.
func versionsOf(t *testing.T, ns, name string) map[string]string {
	out := map[string]string{}
	for _, c := range listNetworkConfigs(t, ns, name) {
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

func phaseOf(n *fabricv1.Network, node string) fabricv1.TargetPhase {
	for _, rc := range n.Status.RenderedConfigs {
		if rc.Node == node {
			return rc.Phase
		}
	}
	return ""
}
