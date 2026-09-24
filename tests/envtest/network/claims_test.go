//go:build envtest

// T170: the provider-side claim resolution (T171) against the fake pkg/kuid adapter
// (suite_test.go), per contracts/reconciliation.md Rule 3 and contracts/kuid-claim-profiles.md
// §8. Every label a test here selects claims on is a metadata.label — kuid.Claimed.Labels,
// what pkg/kuid writes to and ListByLabel filters on (AD-32).
package network_test

import (
	"context"
	"reflect"
	"strings"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/controllers/network"
	"github.com/mairp/agentic-netops-srl/pkg/kuid"
)

const cidA = "4f2c1a9e7b6d40518c3e9a2f1d0b7c85"

func claimName(ns, name, role string) string { return network.ClaimName(ns, name, role) }

func refsByName(n *fabricv1.Network) map[string]fabricv1.ClaimRef {
	out := map[string]fabricv1.ClaimRef{}
	for _, r := range n.Status.ClaimRefs {
		out[r.Name] = r
	}
	return out
}

func tierLabels(cid string) map[string]string { return map[string]string{kuid.LabelCorrelationID: cid} }

// A Network with no adoptable claim gets one claim per l2vni/l3vni for exactly the stated
// value, named deterministically from namespace, name and field role, labelled with the object
// in metadata.labels, before any Config exists; status.claimRefs marks each created; a second
// reconcile creates no second claim (FR-109, AD-16, AD-42).
func TestClaimsCreatedForStatedVNIsBeforeAnyConfig(t *testing.T) {
	h := newHarness(t, nsServices, "svc-claims")
	configsAtCreate := -1
	h.claims.onCreate = func(req kuid.Request) {
		if n := len(listNetworkConfigs(t, h.ns, h.name)); configsAtCreate < n {
			configsAtCreate = n
		}
	}
	h.converge(gatewaySpec(250, 10250, 10251, "10.250.0.1/24", att("leaf01", "ethernet-1/1", 250), att("leaf02", "ethernet-1/1", 250)))
	if configsAtCreate != 0 {
		t.Fatalf("a claim was made with %d Configs present, want none (claims precede every Config)", configsAtCreate)
	}
	l2, l3 := claimName(nsServices, h.name, "l2vni-bd"), claimName(nsServices, h.name, "l3vni-vrf")
	for name, v := range map[string]string{l2: "10250", l3: "10251"} {
		c, ok := h.claims.get(kuid.KindGENID, name)
		if !ok {
			t.Fatalf("no claim %s", name)
		}
		if c.Stated != v || c.Value != v || c.Index != vniIndex {
			t.Errorf("%s states %q reports %q in %s, want exactly %s in %s", name, c.Stated, c.Value, c.Index, v, vniIndex)
		}
	}
	// selected by the object's metadata.labels
	got, err := h.claims.ListByLabel(context.Background(), kuid.KindGENID, nsKuid,
		map[string]string{kuid.LabelNetworkNamespace: nsServices, kuid.LabelNetworkName: h.name})
	must(t, err)
	if len(got) != 2 {
		t.Fatalf("%d claims selected by the object's labels, want 2", len(got))
	}
	if n := h.claims.countKind(kuid.KindVLAN); n != 0 {
		t.Errorf("%d VLAN claims for a naming-band VLAN, want 0", n)
	}
	refs := refsByName(h.network())
	if len(refs) != 2 || refs[l2].Origin != fabricv1.ClaimOriginCreated || refs[l3].Origin != fabricv1.ClaimOriginCreated ||
		refs[l2].Value != 10250 || refs[l2].IndexKind != fabricv1.ClaimIndexGENID || refs[l2].Namespace != nsKuid {
		t.Fatalf("claimRefs %+v", refs)
	}
	creates := h.claims.createdCount()
	h.clock.Step(15 * time.Second)
	h.reconcile()
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	if h.claims.createdCount() != creates {
		t.Error("a second reconcile created a second claim")
	}
	if !reflect.DeepEqual(refsByName(h.network()), refs) {
		t.Error("a second reconcile changed claimRefs")
	}
}

// Adoption by the three-part rule (AD-42, R-45): a bound claim carrying the object's
// correlation label, bearing the deterministic name and reporting the value is adopted and none
// is created — VNI and allocation-band VLAN alike; a label match with a different value is not
// adopted, and neither is a label-and-value match under any other name.
func TestClaimsAdoptionThreePartRule(t *testing.T) {
	h := newHarness(t, nsIntent, "migr-adopt")
	h.claims.seed(kuid.KindGENID, claimName(nsIntent, h.name, "l2vni-bd"), "10260", tierLabels(cidA))
	h.claims.seed(kuid.KindVLAN, claimName(nsIntent, h.name, "vlan-bd"), "1260", tierLabels(cidA))
	h.converge(macvrfSpec(1260, 10260, att("leaf01", "ethernet-1/1", 1260)), withCorrelation(cidA))
	refs := refsByName(h.network())
	if len(refs) != 2 || refs[claimName(nsIntent, h.name, "l2vni-bd")].Origin != fabricv1.ClaimOriginAdopted ||
		refs[claimName(nsIntent, h.name, "vlan-bd")].Origin != fabricv1.ClaimOriginAdopted ||
		refs[claimName(nsIntent, h.name, "vlan-bd")].IndexKind != fabricv1.ClaimIndexVLAN {
		t.Fatalf("claimRefs %+v, want the VNI and the VLAN claim adopted", refs)
	}
	if n := h.claims.createdCount(); n != 0 {
		t.Fatalf("%d claims created beside adoptable ones", n)
	}

	// label match, different value: not adopted (the claim of the object's name is not its own)
	v := h.with(nsIntent, "migr-adopt-value")
	v.claims.seed(kuid.KindGENID, claimName(nsIntent, v.name, "l2vni-bd"), "10299", tierLabels("c1c1"))
	v.create(macvrfSpec(262, 10262, att("leaf01", "ethernet-1/1", 262)), withCorrelation("c1c1"))
	v.reconcile()
	for _, r := range v.network().Status.ClaimRefs {
		if r.Origin == fabricv1.ClaimOriginAdopted {
			t.Errorf("a label match with a different value was adopted: %+v", r)
		}
	}
	v.wantCond("Accepted", metav1.ConditionFalse, "AllocationConflict", "10262")
	if len(v.configs()) != 0 {
		t.Error("Configs written on an AllocationConflict")
	}

	// label and value match under another name: not adopted; the value is then the other
	// claim's, and the authority's refusal names it
	o := h.with(nsIntent, "migr-adopt-name")
	o.claims.seed(kuid.KindGENID, claimName(nsIntent, "migr-someone", "l2vni-bd"), "10264", tierLabels("c2c2"))
	o.create(macvrfSpec(264, 10264, att("leaf01", "ethernet-1/1", 264)), withCorrelation("c2c2"))
	o.reconcile()
	for _, r := range o.network().Status.ClaimRefs {
		if r.Origin == fabricv1.ClaimOriginAdopted {
			t.Errorf("a label-and-value match under another name was adopted: %+v", r)
		}
	}
	o.wantCond("Accepted", metav1.ConditionFalse, "AllocationConflict", "10264", claimName(nsIntent, "migr-someone", "l2vni-bd"))
}

// A correlation label copied onto another object adopts none of the original's claims (CHK033):
// the name is the object's own. VLAN half: a bound VLAN claim is not adopted when the value
// differs, when the label is a copy carried by another object, or when the name does not match
// (R-45) — each an AllocationConflict naming the VLAN and both bands.
func TestClaimsCopiedLabelAndVLANMismatchesNotAdopted(t *testing.T) {
	orig := newHarness(t, nsIntent, "migr-orig")
	orig.claims.seed(kuid.KindGENID, claimName(nsIntent, orig.name, "l2vni-bd"), "10270", tierLabels(cidA))
	orig.claims.seed(kuid.KindVLAN, claimName(nsIntent, orig.name, "vlan-bd"), "1270", tierLabels(cidA))

	cp := orig.with(nsIntent, "migr-copy")
	cp.create(macvrfSpec(1270, 10270, att("leaf01", "ethernet-1/1", 1270)), withCorrelation(cidA))
	cp.reconcile()
	for _, r := range cp.network().Status.ClaimRefs {
		if r.Origin == fabricv1.ClaimOriginAdopted {
			t.Fatalf("a copied correlation label adopted %+v", r)
		}
	}
	cp.wantCond("Accepted", metav1.ConditionFalse, "AllocationConflict", "VLAN 1270", "100–999", "1000–4000")
	if len(cp.configs()) != 0 {
		t.Error("Configs written on an AllocationConflict")
	}

	val := orig.with(nsIntent, "migr-vlan-value")
	val.claims.seed(kuid.KindVLAN, claimName(nsIntent, val.name, "vlan-v"), "1299", tierLabels("c3c3"))
	val.create(vlanSpec(1272, att("leaf01", "ethernet-1/1", 1272)), withCorrelation("c3c3"))
	val.reconcile()
	val.wantCond("Accepted", metav1.ConditionFalse, "AllocationConflict", "VLAN 1272", "100–999", "1000–4000")

	nm := orig.with(nsIntent, "migr-vlan-name")
	nm.claims.seed(kuid.KindVLAN, claimName(nsIntent, "migr-other", "vlan-v"), "1274", tierLabels("c4c4"))
	nm.create(vlanSpec(1274, att("leaf01", "ethernet-1/1", 1274)), withCorrelation("c4c4"))
	nm.reconcile()
	nm.wantCond("Accepted", metav1.ConditionFalse, "AllocationConflict", "VLAN 1274", "100–999", "1000–4000")
	for _, x := range []*harness{val, nm} {
		if len(x.network().Status.ClaimRefs) != 0 || len(x.configs()) != 0 {
			t.Errorf("%s: claimRefs %+v configs %d", x.name, x.network().Status.ClaimRefs, len(x.configs()))
		}
	}
	if orig.claims.createdCount() != 0 {
		t.Errorf("%d claims created: the provider never creates a VLAN claim, nor a VNI one past a refused VLAN", orig.claims.createdCount())
	}
}

// A value held by another owner, or outside the allocation band, is Accepted=False/
// AllocationConflict naming the value and the holder or the band, with zero Configs and no
// other value tried.
func TestClaimsRefusalIsAllocationConflict(t *testing.T) {
	h := newHarness(t, nsServices, "svc-held-vni")
	h.claims.seed(kuid.KindGENID, "someone-else.l2vni", "10280", nil)
	h.create(macvrfSpec(280, 10280, att("leaf01", "ethernet-1/1", 280)))
	if res := h.reconcile(); res.RequeueAfter != 0 {
		t.Errorf("an AllocationConflict is terminal, requeued at %s", res.RequeueAfter)
	}
	h.wantCond("Accepted", metav1.ConditionFalse, "AllocationConflict", "10280", nsKuid+"/someone-else.l2vni")
	if len(h.configs()) != 0 {
		t.Fatal("Configs written on an AllocationConflict")
	}
	if h.claims.call("create") != 1 {
		t.Errorf("%d claim attempts, want exactly one for the stated value (no other value tried)", h.claims.call("create"))
	}
	h.reconcile()
	if h.claims.call("create") != 1 {
		t.Error("a second reconcile tried another claim")
	}

	b := h.with(nsServices, "svc-band-vni")
	b.create(macvrfSpec(281, 30281, att("leaf01", "ethernet-1/1", 281)))
	b.reconcile()
	b.wantCond("Accepted", metav1.ConditionFalse, "AllocationConflict", "30281", "10000–20000")
	if len(b.configs()) != 0 {
		t.Fatal("Configs written for a VNI outside the band")
	}
}

// A vlan and an acl make the provider create nothing, and that is a success; a VLAN in 100–999
// is a named VLAN and needs no claim; one in 1000–4000 with no adoptable claim is
// AllocationConflict naming the VLAN and both bands with zero Configs (AD-33).
func TestClaimsVLANBandsAndNothingCreated(t *testing.T) {
	h := newHarness(t, nsServices, "svc-named-vlan")
	h.converge(vlanSpec(290, att("leaf01", "ethernet-1/1", 290)))
	if h.claims.count() != 0 || len(h.network().Status.ClaimRefs) != 0 {
		t.Fatalf("a vlan in the naming band made claims: %d, %+v", h.claims.count(), h.network().Status.ClaimRefs)
	}

	a := h.with(nsServices, "svc-acl")
	a.create(aclSpec(att("leaf01", "ethernet-1/1", 290)))
	a.reconcile()
	a.wantCond("Accepted", metav1.ConditionTrue, "")
	if h.claims.count() != 0 || h.claims.call("list") != 0 || h.claims.call("get") != 0 {
		t.Fatalf("an acl claimed or looked up: claims %d calls %v", h.claims.count(), h.claims.calls)
	}

	band := h.with(nsServices, "svc-band-vlan")
	band.create(vlanSpec(1291, att("leaf01", "ethernet-1/1", 1291)))
	band.reconcile()
	band.wantCond("Accepted", metav1.ConditionFalse, "AllocationConflict", "VLAN 1291", "100–999", "1000–4000")
	if len(band.configs()) != 0 || h.claims.count() != 0 {
		t.Fatal("an unbacked allocation-band VLAN rendered or claimed")
	}
}

// An ip-vrf whose attachment carries VLAN 1500 is Accepted=False/AllocationConflict naming the
// VLAN and both bands with zero Configs — even with a bound vlanclaim carrying its correlation
// label and reporting 1500, with no lookup at all — while one whose attachment carries 200, or
// none, is accepted with zero VLAN claims (AD-51).
func TestClaimsIPVRFAttachmentVLAN(t *testing.T) {
	h := newHarness(t, nsIntent, "migr-ipvrf-1500")
	h.claims.seed(kuid.KindVLAN, claimName(nsIntent, h.name, "vlan-vrf"), "1500", tierLabels("c5c5"))
	h.create(ipvrfSpec(10300, att("leaf01", "ethernet-1/1", 1500)), withCorrelation("c5c5"))
	h.reconcile()
	h.wantCond("Accepted", metav1.ConditionFalse, "AllocationConflict", "VLAN 1500", "100–999", "1000–4000")
	if len(h.configs()) != 0 {
		t.Fatal("Configs written for an ip-vrf attachment VLAN in the allocation band")
	}
	if h.claims.call("list") != 0 || h.claims.createdCount() != 0 {
		t.Errorf("the refusal is by construction, with no lookup and no claim: calls %v", h.claims.calls)
	}

	tagged := h.with(nsServices, "svc-ipvrf-200")
	tagged.converge(ipvrfSpec(10301, att("leaf01", "ethernet-1/1", 200)))
	untagged := h.with(nsServices, "svc-ipvrf-untagged")
	untagged.converge(ipvrfSpec(10302, attUntagged("leaf01", "ethernet-1/2")))
	if n := h.claims.countKind(kuid.KindVLAN); n != 1 { // the seeded one only
		t.Errorf("%d VLAN claims, want none created", n-1)
	}
	for _, x := range []*harness{tagged, untagged} {
		for _, r := range x.network().Status.ClaimRefs {
			if r.IndexKind == fabricv1.ClaimIndexVLAN {
				t.Errorf("%s holds a VLAN claim %+v", x.name, r)
			}
		}
	}
}

// With the fake adapter made to ERROR on the lookup or the create, the object records no
// AllocationConflict, renders nothing, adopts nothing, and is retried with backoff until the
// fake answers — an error is a dependency wait, never an answer (AD-56).
func TestClaimsAuthorityErrorIsAWait(t *testing.T) {
	for _, op := range []string{"list", "create"} {
		t.Run(op, func(t *testing.T) {
			h := newHarness(t, nsIntent, "migr-err-"+op)
			h.claims.seed(kuid.KindVLAN, claimName(nsIntent, h.name, "vlan-bd"), "1310", tierLabels("c6c6"))
			h.create(macvrfSpec(1310, 10310, att("leaf01", "ethernet-1/1", 1310)), withCorrelation("c6c6"))
			h.claims.setFail(op, true)
			var last time.Duration
			for i := 0; i < 3; i++ {
				res, err := h.reconcileErr()
				must(t, err)
				if res.RequeueAfter <= 0 || res.RequeueAfter > 10*time.Second {
					t.Fatalf("attempt %d: backoff %s outside (0, 10s]", i+1, res.RequeueAfter)
				}
				if res.RequeueAfter < last {
					t.Errorf("backoff shrank %s -> %s", last, res.RequeueAfter)
				}
				last = res.RequeueAfter
				h.notCond("Accepted", "AllocationConflict")
				if len(h.configs()) != 0 {
					t.Fatal("rendered while the authority did not answer")
				}
				for _, r := range h.network().Status.ClaimRefs {
					if r.Origin == fabricv1.ClaimOriginAdopted {
						t.Fatalf("adopted while the authority errored (%s): %+v", op, r)
					}
				}
			}
			if len(h.network().Status.ClaimRefs) != 0 {
				t.Errorf("claimRefs %+v while the authority errored (%s)", h.network().Status.ClaimRefs, op)
			}
			h.wantCond("Ready", metav1.ConditionFalse, "NotConverged", "allocation authority")
			if !h.rec.has(network.EventTransientError) {
				t.Error("no TransientError Event")
			}
			h.claims.setFail(op, false)
			h.reconcile()
			h.wantCond("Accepted", metav1.ConditionTrue, "")
			if len(h.configs()) != 1 {
				t.Fatalf("%d Configs once the authority answers, want 1", len(h.configs()))
			}
			refs := refsByName(h.network())
			if refs[claimName(nsIntent, h.name, "vlan-bd")].Origin != fabricv1.ClaimOriginAdopted ||
				refs[claimName(nsIntent, h.name, "l2vni-bd")].Origin != fabricv1.ClaimOriginCreated {
				t.Errorf("claimRefs %+v", refs)
			}
		})
	}
}

// An accessLists-only object whose attachment carries a VLAN in 1000–4000 is accepted with no
// claim looked for: that VLAN is a reference to another service's subinterface (AD-47).
func TestClaimsACLOnlyAllocationBandNoLookup(t *testing.T) {
	h := newHarness(t, nsServices, "svc-acl-1320")
	h.create(aclSpec(att("leaf01", "ethernet-1/1", 1320)))
	h.reconcile()
	h.wantCond("Accepted", metav1.ConditionTrue, "")
	if h.claims.call("list")+h.claims.call("get")+h.claims.call("create") != 0 {
		t.Errorf("a claim was looked for behind a reference VLAN: %v", h.claims.calls)
	}
}

// Adoption is decided once per value (AD-25, AD-32): a mac-vrf whose VLAN was allocated keeps
// its VLAN claim adopted in status.claimRefs after an attachment carrying it is removed — never
// re-evaluated (no lookup), never dropped, released only at finalization; a second reconcile
// un-adopts nothing.
func TestClaimsAdoptionOncePerValue(t *testing.T) {
	h := newHarness(t, nsIntent, "migr-once")
	h.claims.seed(kuid.KindVLAN, claimName(nsIntent, h.name, "vlan-bd"), "1330", tierLabels("c7c7"))
	h.claims.seed(kuid.KindGENID, claimName(nsIntent, h.name, "l2vni-bd"), "10330", tierLabels("c7c7"))
	h.converge(macvrfSpec(1330, 10330, att("leaf01", "ethernet-1/1", 1330), att("leaf02", "ethernet-1/1", 1330)), withCorrelation("c7c7"))
	refs := h.network().Status.ClaimRefs
	if len(refs) != 2 {
		t.Fatalf("claimRefs %+v", refs)
	}
	lookups := h.claims.call("list")

	h.update(func(n *fabricv1.Network) { n.Spec.Attachments = n.Spec.Attachments[:1] })
	h.reconcile()
	confirmConfigs(t, h.ns, h.name)
	h.clock.Step(15 * time.Second)
	h.reconcile()
	h.clock.Step(5 * time.Minute)
	h.reconcile()
	if got := h.network().Status.ClaimRefs; !reflect.DeepEqual(got, refs) {
		t.Fatalf("claimRefs changed after the attachment went: %+v -> %+v", refs, got)
	}
	if h.claims.call("list") != lookups {
		t.Error("an adopted value was re-evaluated")
	}
	if len(h.claims.releasedNames()) != 0 {
		t.Error("a claim was released before finalization")
	}
	if len(h.configs()) != 1 {
		t.Errorf("%d Configs after leaf02's attachment went, want 1", len(h.configs()))
	}
}

// Finalization releases every entry of status.claimRefs only after the removal is read back:
// with a Config's removal pending nothing is released; once it is read back, every claim is
// (zero left).
func TestClaimsFinalizationReleasesAfterRemovalReadBack(t *testing.T) {
	h := newHarness(t, nsServices, "svc-release")
	h.converge(gatewaySpec(340, 10340, 10341, "10.34.0.1/24", att("leaf01", "ethernet-1/1", 340), att("leaf02", "ethernet-1/1", 340)))
	if h.claims.count() != 2 {
		t.Fatalf("%d claims, want 2", h.claims.count())
	}
	holdConfig(t, h.name+".leaf02")
	h.delete()
	h.reconcile()
	if n := len(h.claims.releasedNames()); n != 0 {
		t.Fatalf("%d claims released before the removal was read back", n)
	}
	if len(h.network().Status.ClaimRefs) != 2 {
		t.Fatalf("claimRefs %+v while the removal is pending", h.network().Status.ClaimRefs)
	}
	releaseConfig(t, h.name+".leaf02")
	h.reconcile()
	if h.claims.count() != 0 || len(h.claims.releasedNames()) != 2 {
		t.Fatalf("claims left %d, released %v; want zero left", h.claims.count(), h.claims.releasedNames())
	}
	eventually(t, 5*time.Second, "the Network gone", h.gone)
}

// An object created with the finalizer and its tier claims already present, and deleted before
// the reconciler ever ran, has those claims adopted at finalization by the same three-part rule
// and then released — zero left — and none created on the deleting object (AD-44).
func TestClaimsAdoptedAtFinalizationAndReleased(t *testing.T) {
	h := newHarness(t, nsIntent, "migr-early-delete")
	h.claims.seed(kuid.KindGENID, claimName(nsIntent, h.name, "l2vni-bd"), "10350", tierLabels("c8c8"))
	h.claims.seed(kuid.KindVLAN, claimName(nsIntent, h.name, "vlan-bd"), "1350", tierLabels("c8c8"))
	// a copied label under another name must not be swept in
	h.claims.seed(kuid.KindGENID, claimName(nsIntent, "migr-bystander", "l3vni-vrf"), "10351", tierLabels("c8c8"))
	h.create(gatewaySpec(1350, 10350, 10352, "10.35.0.1/24", att("leaf01", "ethernet-1/1", 1350)), withCorrelation("c8c8"),
		func(n *fabricv1.Network) { controllerutil.AddFinalizer(n, network.Finalizer) })
	h.delete()
	h.reconcile()
	eventually(t, 5*time.Second, "the Network finalized", h.gone)
	released := h.claims.releasedNames()
	want := []string{claimName(nsIntent, h.name, "l2vni-bd"), claimName(nsIntent, h.name, "vlan-bd")}
	for _, w := range want {
		if !contains(released, w) {
			t.Errorf("%s not released: released %v", w, released)
		}
	}
	if len(released) != 2 {
		t.Errorf("released %v, want exactly the object's two tier claims", released)
	}
	if h.claims.createdCount() != 0 {
		t.Errorf("%d claims created on a deleting object (the L3VNI nobody claimed is not claimed to be released)", h.claims.createdCount())
	}
	if _, ok := h.claims.get(kuid.KindGENID, claimName(nsIntent, "migr-bystander", "l3vni-vrf")); !ok {
		t.Error("another object's claim was released")
	}
	for _, w := range want {
		if _, ok := h.claims.get(kuid.KindGENID, w); ok {
			t.Errorf("%s left behind", w)
		}
		if _, ok := h.claims.get(kuid.KindVLAN, w); ok {
			t.Errorf("%s left behind", w)
		}
	}
	if !strings.Contains(strings.Join(released, ","), "migr-early-delete") {
		t.Errorf("released %v", released)
	}
}
