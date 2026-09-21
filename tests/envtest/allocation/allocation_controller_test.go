//go:build envtest

// T177: the first-party allocation authority (controllers/allocation, T176) against a real
// API server (envtest) with the conditional CRDs of config/crd/conditional/ installed, the
// pool and claim controllers running in a manager (four claim workers, so that arbitration
// is exercised under concurrency), asserting the six observations (a)–(f) of
// contracts/kuid-claim-profiles.md §6 against the substitute, plus: IdentifierClaim.spec
// immutable by CEL; two concurrent claims for one value binding exactly one (four workers
// of one manager, and two independent reconcilers with no shared lock); an exhausted
// pool refusing by name, and its refused claim binding once a holder goes; ip pools; a
// claim waiting for its pool; and the controllers not registered when the lock says kuid.
//
// Run: make test-envtest (scripts/ci/test_envtest.sh → go test -tags envtest ./tests/envtest/...).
package allocation_test

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/controllers/allocation"
	"github.com/mairp/agentic-netops-srl/internal/compat"
	"github.com/mairp/agentic-netops-srl/pkg/kuid"
)

const ns = allocation.Namespace

var (
	k8s      client.Client
	repoRoot string
	timeout  = 30 * time.Second
)

func TestMain(m *testing.M) {
	_, file, _, _ := runtime.Caller(0)
	repoRoot = filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	env := &envtest.Environment{
		CRDDirectoryPaths:     []string{filepath.Join(repoRoot, "config", "crd", "conditional")},
		ErrorIfCRDPathMissing: true,
	}
	cfg, err := env.Start()
	if err != nil {
		fmt.Fprintf(os.Stderr, "envtest: starting the control plane (is KUBEBUILDER_ASSETS set?): %v\n", err)
		os.Exit(1)
	}
	ctx, cancel := context.WithCancel(context.Background())
	code := func() int {
		scheme := k8sruntime.NewScheme()
		for _, add := range []func(*k8sruntime.Scheme) error{clientgoscheme.AddToScheme, fabricv1.AddToScheme} {
			if err := add(scheme); err != nil {
				fmt.Fprintln(os.Stderr, err)
				return 1
			}
		}
		if k8s, err = client.New(cfg, client.Options{Scheme: scheme}); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		if err := k8s.Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: ns}}); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		// The manager as cmd/srl-provider's allocation-authority role builds it: its cache
		// holds the authority's namespace only.
		mgr, err := ctrl.NewManager(cfg, ctrl.Options{Scheme: scheme, Metrics: metricsserver.Options{BindAddress: "0"},
			HealthProbeBindAddress: "0", LeaderElection: false,
			Cache: cache.Options{DefaultNamespaces: map[string]cache.Config{ns: {}}}})
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		if err := (&allocation.PoolReconciler{Client: mgr.GetClient(), APIReader: mgr.GetAPIReader()}).SetupWithManager(mgr); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		if err := (&allocation.ClaimReconciler{Client: mgr.GetClient(), APIReader: mgr.GetAPIReader(),
			MaxConcurrentReconciles: 4}).SetupWithManager(mgr); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		done := make(chan struct{})
		go func() {
			defer close(done)
			if err := mgr.Start(ctx); err != nil {
				fmt.Fprintln(os.Stderr, "manager:", err)
			}
		}()
		code := m.Run()
		cancel()
		<-done
		return code
	}()
	cancel()
	_ = env.Stop()
	os.Exit(code)
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func numPool(t *testing.T, name string, typ fabricv1.IdentifierType, lo, hi int64) {
	t.Helper()
	p := &fabricv1.IdentifierPool{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name},
		Spec: fabricv1.IdentifierPoolSpec{Type: typ, Range: &fabricv1.IdentifierRange{Start: lo, End: hi}}}
	must(t, k8s.Create(context.Background(), p))
	t.Cleanup(func() { _ = k8s.Delete(context.Background(), p) })
}

func ipPool(t *testing.T, name, prefix string) {
	t.Helper()
	p := &fabricv1.IdentifierPool{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name},
		Spec: fabricv1.IdentifierPoolSpec{Type: fabricv1.IdentifierTypeIP, Prefix: prefix}}
	must(t, k8s.Create(context.Background(), p))
	t.Cleanup(func() { _ = k8s.Delete(context.Background(), p) })
}

type claimOpt func(*fabricv1.IdentifierClaim)

func requested(v string) claimOpt { return func(c *fabricv1.IdentifierClaim) { c.Spec.Requested = v } }
func prefixLen(n int32) claimOpt {
	return func(c *fabricv1.IdentifierClaim) { c.Spec.PrefixLength = &n }
}
func labels(l map[string]string) claimOpt {
	return func(c *fabricv1.IdentifierClaim) { c.Labels = l }
}
func annotations(a map[string]string) claimOpt {
	return func(c *fabricv1.IdentifierClaim) { c.Annotations = a }
}

func newClaim(name, pool string, opts ...claimOpt) *fabricv1.IdentifierClaim {
	c := &fabricv1.IdentifierClaim{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name},
		Spec: fabricv1.IdentifierClaimSpec{PoolRef: fabricv1.IdentifierPoolRef{Name: fabricv1.DNSLabel(pool)}}}
	for _, o := range opts {
		o(c)
	}
	return c
}

func claim(t *testing.T, name, pool string, opts ...claimOpt) {
	t.Helper()
	must(t, k8s.Create(context.Background(), newClaim(name, pool, opts...)))
	t.Cleanup(func() { deleteGone(t, name) })
}

func get(t *testing.T, name string) *fabricv1.IdentifierClaim {
	t.Helper()
	c := &fabricv1.IdentifierClaim{}
	must(t, k8s.Get(context.Background(), client.ObjectKey{Namespace: ns, Name: name}, c))
	return c
}

func eventually(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// answered waits until the claim's Ready condition is at its generation with the status,
// and returns the claim.
func answered(t *testing.T, name string, st metav1.ConditionStatus, reason string) *fabricv1.IdentifierClaim {
	t.Helper()
	var last *fabricv1.IdentifierClaim
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		c := &fabricv1.IdentifierClaim{}
		if err := k8s.Get(context.Background(), client.ObjectKey{Namespace: ns, Name: name}, c); err == nil {
			last = c
			r := meta.FindStatusCondition(c.Status.Conditions, "Ready")
			if r != nil && r.Status == st && r.Reason == reason && r.ObservedGeneration == c.Generation {
				return c
			}
		}
		time.Sleep(25 * time.Millisecond)
	}
	if last == nil {
		t.Fatalf("claim %s never readable", name)
	}
	t.Fatalf("claim %s never reached Ready=%s/%s; last status %+v", name, st, reason, last.Status)
	return nil
}

func bound(t *testing.T, name string) string {
	t.Helper()
	c := answered(t, name, metav1.ConditionTrue, allocation.ReasonBound)
	if c.Status.Value == "" {
		t.Fatalf("claim %s is Ready without a value", name)
	}
	return c.Status.Value
}

func wantBound(t *testing.T, name, value string) {
	t.Helper()
	if got := bound(t, name); got != value {
		t.Fatalf("claim %s bound %s, want %s", name, got, value)
	}
}

func refused(t *testing.T, name, reason string, msgHas ...string) *metav1.Condition {
	t.Helper()
	c := answered(t, name, metav1.ConditionFalse, reason)
	if c.Status.Value != "" {
		t.Fatalf("refused claim %s reports value %s", name, c.Status.Value)
	}
	r := meta.FindStatusCondition(c.Status.Conditions, "Ready")
	for _, s := range msgHas {
		if !strings.Contains(r.Message, s) {
			t.Fatalf("claim %s: message %q lacks %q", name, r.Message, s)
		}
	}
	return r
}

// deleteGone deletes the claim and waits until it no longer exists — what kubectl delete
// does, finalizers included.
func deleteGone(t *testing.T, name string) {
	t.Helper()
	c := &fabricv1.IdentifierClaim{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name}}
	if err := k8s.Delete(context.Background(), c); err != nil && !apierrors.IsNotFound(err) {
		t.Fatal(err)
	}
	eventually(t, "claim "+name+" gone", func() bool {
		return apierrors.IsNotFound(k8s.Get(context.Background(), client.ObjectKeyFromObject(c), &fabricv1.IdentifierClaim{}))
	})
}

func ledger(t *testing.T, pool string) map[string]string {
	t.Helper()
	p := &fabricv1.IdentifierPool{}
	must(t, k8s.Get(context.Background(), client.ObjectKey{Namespace: ns, Name: pool}, p))
	out := map[string]string{}
	for _, e := range p.Status.Allocations {
		out[e.Value] = e.Claim
	}
	if int(p.Status.Allocated) != len(p.Status.Allocations) {
		t.Errorf("pool %s: allocated %d with %d ledger entries", pool, p.Status.Allocated, len(p.Status.Allocations))
	}
	return out
}

// ---------------------------------------------------------------------------
// The six observations of kuid-claim-profiles.md §6.
// ---------------------------------------------------------------------------

// (a) a stated-value claim binds exactly that value; (b) a second claim for the same
// value is refused naming the holder, no other value tried — and binds once the holder
// is gone.
func TestObservationAB_StatedValueAndHolderNamed(t *testing.T) {
	numPool(t, "ab", fabricv1.IdentifierTypeVLAN, 1000, 4000)
	claim(t, "ab-first", "ab", requested("1234"))
	wantBound(t, "ab-first", "1234")
	c := get(t, "ab-first")
	if !containsString(c.Finalizers, allocation.Finalizer) {
		t.Errorf("bound claim lacks the finalizer %s: %v", allocation.Finalizer, c.Finalizers)
	}
	if l := ledger(t, "ab"); l["1234"] != "ab-first" || len(l) != 1 {
		t.Errorf("ledger %v", l)
	}

	claim(t, "ab-second", "ab", requested("1234"))
	refused(t, "ab-second", allocation.ReasonConflict, "value 1234 is held by claim "+ns+"/ab-first")
	time.Sleep(500 * time.Millisecond)
	refused(t, "ab-second", allocation.ReasonConflict, "value 1234 is held by claim "+ns+"/ab-first")
	if l := ledger(t, "ab"); len(l) != 1 {
		t.Errorf("a refused claim was given another value: %v", l)
	}

	deleteGone(t, "ab-first")
	wantBound(t, "ab-second", "1234")
}

// (c) three consecutive dynamic claims return the three lowest free values; (d) never
// one below the pool's minimum, and a stated value below it is OutOfRange.
func TestObservationCD_LowestFreeAndMinimum(t *testing.T) {
	numPool(t, "cd", fabricv1.IdentifierTypeVLAN, 1000, 4000)
	var got []string
	for i := 1; i <= 3; i++ {
		name := fmt.Sprintf("cd-dyn-%d", i)
		claim(t, name, "cd")
		got = append(got, bound(t, name))
	}
	t.Logf("(c) three consecutive dynamic claims returned %v", got)
	if strings.Join(got, ",") != "1000,1001,1002" {
		t.Fatalf("(c) three dynamic values %v, want the three lowest free, 1000,1001,1002", got)
	}
	claim(t, "cd-below", "cd", requested("999"))
	refused(t, "cd-below", allocation.ReasonOutOfRange, "value 999", "range 1000-4000", ns+"/cd")
	claim(t, "cd-above", "cd", requested("4001"))
	refused(t, "cd-above", allocation.ReasonOutOfRange, "value 4001")

	// The lowest FREE value: a hole left by a release is filled first.
	deleteGone(t, "cd-dyn-2")
	claim(t, "cd-dyn-4", "cd")
	wantBound(t, "cd-dyn-4", "1001")
}

// (e) metadata.labels are selectable with a label selector; a label that is not in
// metadata.labels selects nothing.
func TestObservationE_MetadataLabelsSelectable(t *testing.T) {
	numPool(t, "e", fabricv1.IdentifierTypeVNI, 10000, 20000)
	sel := map[string]string{kuid.LabelCorrelationID: "corr-e"}
	claim(t, "e-labelled", "e", labels(sel), annotations(map[string]string{"example.org/only-annotated": "yes"}))
	claim(t, "e-other", "e", labels(map[string]string{kuid.LabelCorrelationID: "corr-other"}))
	claim(t, "e-bare", "e")
	bound(t, "e-labelled")

	l := &fabricv1.IdentifierClaimList{}
	must(t, k8s.List(context.Background(), l, client.InNamespace(ns), client.MatchingLabels(sel)))
	if len(l.Items) != 1 || l.Items[0].Name != "e-labelled" {
		t.Fatalf("(e) selector %v selected %d claims", sel, len(l.Items))
	}
	must(t, k8s.List(context.Background(), l, client.InNamespace(ns), client.MatchingLabels{"example.org/only-annotated": "yes"}))
	if len(l.Items) != 0 {
		t.Fatalf("(e) a key carried outside metadata.labels selected %d claims", len(l.Items))
	}
	// The same through the seam's first-party implementation.
	got, err := kuid.NewFirstParty(k8s).ListByLabel(context.Background(), kuid.KindGENID, ns, sel)
	if err != nil || len(got) != 1 || got[0].Name != "e-labelled" || !got[0].Bound() {
		t.Fatalf("(e) ListByLabel through the seam = %+v %v", got, err)
	}
}

// (f) deleting a claim frees its value synchronously: once the DELETE has completed (the
// claim is gone), the ledger no longer holds the value and an immediate claim for it
// binds — with the negative control that the same claim is refused while the first exists.
func TestObservationF_DeleteFreesSynchronously(t *testing.T) {
	numPool(t, "f", fabricv1.IdentifierTypeVLAN, 1000, 4000)
	claim(t, "f-first", "f", requested("2000"))
	wantBound(t, "f-first", "2000")

	// Negative control: the second claim, while the first exists.
	must(t, k8s.Create(context.Background(), newClaim("f-second", "f", requested("2000"))))
	refused(t, "f-second", allocation.ReasonConflict, "value 2000 is held by claim "+ns+"/f-first")
	deleteGone(t, "f-second")

	deleteGone(t, "f-first")
	if l := ledger(t, "f"); len(l) != 0 {
		t.Fatalf("(f) the value is still held once the DELETE completed: %v", l)
	}
	claim(t, "f-second", "f", requested("2000"))
	wantBound(t, "f-second", "2000")
}

// ---------------------------------------------------------------------------
// Beyond the six.
// ---------------------------------------------------------------------------

func TestClaimSpecImmutableByCEL(t *testing.T) {
	numPool(t, "cel", fabricv1.IdentifierTypeVLAN, 1000, 4000)
	claim(t, "cel-a", "cel", requested("1500"))
	wantBound(t, "cel-a", "1500")
	c := get(t, "cel-a")
	c.Spec.Requested = "1501"
	err := k8s.Update(context.Background(), c)
	if err == nil || !apierrors.IsInvalid(err) || !strings.Contains(err.Error(), "IdentifierClaim spec is immutable") {
		t.Fatalf("an update moving spec.requested = %v; want rejected by CEL", err)
	}
	c = get(t, "cel-a")
	c.Spec.PrefixLength = ptr[int32](31)
	if err := k8s.Update(context.Background(), c); err == nil {
		t.Fatal("an update adding spec.prefixLength was admitted")
	}
	wantBound(t, "cel-a", "1500")
}

// Two claims for one value, created at once, bind exactly one; the other is refused
// naming it. Repeated to give the race a chance.
func TestConcurrentClaimsBindExactlyOne(t *testing.T) {
	numPool(t, "conc", fabricv1.IdentifierTypeVLAN, 1000, 4000)
	for round := 0; round < 5; round++ {
		value := fmt.Sprint(3000 + round)
		names := []string{fmt.Sprintf("conc-%d-a", round), fmt.Sprintf("conc-%d-b", round)}
		var wg sync.WaitGroup
		start := make(chan struct{})
		errs := make([]error, 2)
		for i, n := range names {
			wg.Add(1)
			go func(i int, n string) {
				defer wg.Done()
				<-start
				errs[i] = k8s.Create(context.Background(), newClaim(n, "conc", requested(value)))
			}(i, n)
		}
		close(start)
		wg.Wait()
		for i, n := range names {
			must(t, errs[i])
			t.Cleanup(func() { deleteGone(t, n) })
		}
		var winners, losers []string
		eventually(t, "both claims answered", func() bool {
			winners, losers = nil, nil
			for _, n := range names {
				c := get(t, n)
				r := meta.FindStatusCondition(c.Status.Conditions, "Ready")
				switch {
				case r == nil || r.ObservedGeneration != c.Generation:
					return false
				case r.Status == metav1.ConditionTrue && c.Status.Value == value:
					winners = append(winners, n)
				case r.Status == metav1.ConditionFalse && r.Reason == allocation.ReasonConflict:
					losers = append(losers, n)
				default:
					return false
				}
			}
			return true
		})
		if len(winners) != 1 || len(losers) != 1 {
			t.Fatalf("round %d: bound %v, refused %v; want exactly one of each", round, winners, losers)
		}
		refused(t, losers[0], allocation.ReasonConflict, "value "+value+" is held by claim "+ns+"/"+winners[0])
		if l := ledger(t, "conc"); l[value] != winners[0] {
			t.Fatalf("round %d: ledger holds %s for %q, want %s", round, value, l[value], winners[0])
		}
	}
}

// Two processes: two independent reconcilers — no shared mutex — racing on one value
// (beside the manager's own) still bind exactly one: the ledger's optimistic update is the
// arbiter, not the in-process lock.
func TestTwoProcessesBindExactlyOne(t *testing.T) {
	numPool(t, "procs", fabricv1.IdentifierTypeVLAN, 1000, 4000)
	for round := 0; round < 5; round++ {
		value := fmt.Sprint(3500 + round)
		names := []string{fmt.Sprintf("procs-%d-a", round), fmt.Sprintf("procs-%d-b", round)}
		for _, n := range names {
			claim(t, n, "procs", requested(value))
		}
		var wg sync.WaitGroup
		for i := 0; i < 2; i++ {
			proc := &allocation.ClaimReconciler{Client: k8s, APIReader: k8s}
			for _, n := range names {
				wg.Add(1)
				go func(n string) {
					defer wg.Done()
					for j := 0; j < 3; j++ {
						_, _ = proc.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Namespace: ns, Name: n}})
					}
				}(n)
			}
		}
		wg.Wait()
		eventually(t, "exactly one bound, the other refused", func() bool {
			var b, r int
			for _, n := range names {
				c := get(t, n)
				cond := meta.FindStatusCondition(c.Status.Conditions, "Ready")
				switch {
				case cond == nil:
				case cond.Status == metav1.ConditionTrue && c.Status.Value == value:
					b++
				case cond.Status == metav1.ConditionFalse && cond.Reason == allocation.ReasonConflict:
					r++
				}
			}
			return b == 1 && r == 1
		})
		if l := ledger(t, "procs"); !containsString(names, l[value]) || len(l) != round+1 {
			t.Fatalf("round %d: ledger %v", round, l)
		}
	}
}

// A pool with no free value refuses a dynamic claim by name; the refused claim binds once
// a holder is deleted.
func TestExhaustedPoolRefusesByNameAndRecovers(t *testing.T) {
	numPool(t, "tiny", fabricv1.IdentifierTypeGENID, 5, 6)
	claim(t, "tiny-1", "tiny")
	wantBound(t, "tiny-1", "5")
	claim(t, "tiny-2", "tiny")
	wantBound(t, "tiny-2", "6")
	claim(t, "tiny-3", "tiny")
	refused(t, "tiny-3", allocation.ReasonExhausted, "pool "+ns+"/tiny", "exhausted")
	deleteGone(t, "tiny-1")
	wantBound(t, "tiny-3", "5")
}

// ip pools: dynamic /31 prefixes are the lowest aligned free blocks; an address states a
// host; overlap is a conflict naming the holder.
func TestIPPool(t *testing.T) {
	ipPool(t, "p2p", "10.1.0.0/24")
	claim(t, "p2p-1", "p2p", prefixLen(31))
	wantBound(t, "p2p-1", "10.1.0.0/31")
	claim(t, "p2p-2", "p2p", prefixLen(31))
	wantBound(t, "p2p-2", "10.1.0.2/31")
	claim(t, "p2p-host", "p2p", requested("10.1.0.4"))
	wantBound(t, "p2p-host", "10.1.0.4/32")
	claim(t, "p2p-dynhost", "p2p")
	wantBound(t, "p2p-dynhost", "10.1.0.5/32")
	claim(t, "p2p-overlap", "p2p", requested("10.1.0.0/30"))
	refused(t, "p2p-overlap", allocation.ReasonConflict, "value 10.1.0.0/30 is held by claim "+ns+"/p2p-1")
	claim(t, "p2p-out", "p2p", requested("10.2.0.1/32"))
	refused(t, "p2p-out", allocation.ReasonOutOfRange, "10.2.0.1/32", "prefix 10.1.0.0/24")
	claim(t, "p2p-bad", "p2p", requested("ten"))
	refused(t, "p2p-bad", allocation.ReasonInvalid)

	numPool(t, "vl", fabricv1.IdentifierTypeVLAN, 1000, 4000)
	claim(t, "vl-prefixlen", "vl", prefixLen(31))
	refused(t, "vl-prefixlen", allocation.ReasonInvalid, "prefixLength")
}

// A claim naming a pool that does not exist waits (Ready=Unknown/PoolNotFound) and binds
// when the pool appears.
func TestClaimWaitsForItsPool(t *testing.T) {
	claim(t, "late-1", "late", requested("1500"))
	answered(t, "late-1", metav1.ConditionUnknown, allocation.ReasonPoolNotFound)
	got, err := kuid.NewFirstParty(k8s).Get(context.Background(), kuid.Ref{Kind: kuid.KindVLAN, Namespace: ns, Name: "late-1"})
	if err != nil || got.Bound() || got.Reason != "" || got.Message != "" {
		t.Fatalf("a claim waiting for its pool reads across the seam as %+v %v; want pending, no refusal", got, err)
	}
	numPool(t, "late", fabricv1.IdentifierTypeVLAN, 1000, 4000)
	wantBound(t, "late-1", "1500")
	p := &fabricv1.IdentifierPool{}
	eventually(t, "pool Ready", func() bool {
		must(t, k8s.Get(context.Background(), client.ObjectKey{Namespace: ns, Name: "late"}, p))
		return meta.IsStatusConditionTrue(p.Status.Conditions, "Ready") && p.Status.Allocated == 1
	})
}

// A ledger entry whose claim is gone without a release (finalizer removed by hand) is
// collected by the pool controller.
func TestOrphanedLedgerEntryCollected(t *testing.T) {
	numPool(t, "gc", fabricv1.IdentifierTypeVLAN, 1000, 4000)
	claim(t, "gc-a", "gc", requested("1100"))
	wantBound(t, "gc-a", "1100")
	c := get(t, "gc-a")
	must(t, k8s.Delete(context.Background(), c))
	// Remove the finalizer by hand racing the controller: whichever wins, the value ends free.
	eventually(t, "finalizer removed", func() bool {
		c := &fabricv1.IdentifierClaim{}
		if err := k8s.Get(context.Background(), client.ObjectKey{Namespace: ns, Name: "gc-a"}, c); apierrors.IsNotFound(err) {
			return true
		}
		c.Finalizers = nil
		return k8s.Update(context.Background(), c) == nil
	})
	eventually(t, "ledger empty", func() bool { return len(ledger(t, "gc")) == 0 })
}

// The controllers are registered only when the lock file selects first-party
// (cmd/srl-provider's allocation-authority role calls this rule; role_test.go asserts
// the role refuses under kuid).
func TestNotRegisteredUnderKuid(t *testing.T) {
	err := allocation.RegisteredUnder(compat.AuthorityKuid)
	if err == nil || !strings.Contains(err.Error(), "allocationAuthority.kind") {
		t.Fatalf("under kuid: %v", err)
	}
	if err := allocation.RegisteredUnder(compat.AuthorityFirstParty); err != nil {
		t.Fatalf("under first-party: %v", err)
	}
	set, err := compat.Load(filepath.Join(repoRoot, "versions.lock.yaml"))
	must(t, err)
	if (allocation.RegisteredUnder(set.AuthorityKind()) == nil) != (set.AuthorityKind() == compat.AuthorityFirstParty) {
		t.Fatalf("the repository's lock (%s) and the registration rule disagree", set.AuthorityKind())
	}
}

func ptr[T any](v T) *T { return &v }

func containsString(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}
