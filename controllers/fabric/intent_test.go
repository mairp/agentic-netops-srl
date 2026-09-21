package fabric

import (
	"strings"
	"testing"
	"time"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/pkg/kuid"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestDeriveLinksIsTheLabTopology(t *testing.T) {
	links, err := deriveLinks([]string{"leaf01", "leaf02"}, []string{"spine01", "spine02"}, map[string][]string{
		"leaf01": {"ethernet-1/49", "ethernet-1/50"}, "leaf02": {"ethernet-1/49", "ethernet-1/50"},
		"spine01": {"ethernet-1/1", "ethernet-1/2"}, "spine02": {"ethernet-1/1", "ethernet-1/2"},
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []linkPlan{
		{"leaf01", "ethernet-1/49", "spine01", "ethernet-1/1"}, {"leaf01", "ethernet-1/50", "spine02", "ethernet-1/1"},
		{"leaf02", "ethernet-1/49", "spine01", "ethernet-1/2"}, {"leaf02", "ethernet-1/50", "spine02", "ethernet-1/2"},
	}
	if len(links) != len(want) {
		t.Fatalf("%v", links)
	}
	for i := range want {
		if links[i] != want[i] {
			t.Errorf("link %d = %+v, want %+v", i, links[i], want[i])
		}
	}
	if s := links[0].ClaimSuffix(); s != "link.leaf01-ethernet-1-49.spine01-ethernet-1-1" {
		t.Errorf("claim suffix %s", s)
	}
	if _, err := deriveLinks([]string{"leaf01"}, []string{"spine01", "spine02"}, map[string][]string{"leaf01": {"e1"}, "spine01": {"e1"}, "spine02": {"e1"}}); err == nil {
		t.Error("a leaf with fewer uplinks than spines accepted")
	}
}

func TestTagFlipsNamePortAndServices(t *testing.T) {
	in := &intent{access: map[string]map[string]bool{"leaf01": {"ethernet-1/1": true, "ethernet-1/2": false}}}
	vlan := fabricv1.AttachmentVLAN(100)
	nets := []fabricv1.Network{
		{ObjectMeta: metav1.ObjectMeta{Namespace: "ns-a", Name: "tagged"}, Spec: fabricv1.NetworkSpec{Attachments: []fabricv1.NetworkAttachment{{Node: "leaf01", Attachment: "ethernet-1/1", VLAN: &vlan}}}},
		{ObjectMeta: metav1.ObjectMeta{Namespace: "ns-b", Name: "untagged-ok"}, Spec: fabricv1.NetworkSpec{Attachments: []fabricv1.NetworkAttachment{{Node: "leaf01", Attachment: "ethernet-1/1"}}}},
		{ObjectMeta: metav1.ObjectMeta{Namespace: "ns-c", Name: "untagged-bad"}, Spec: fabricv1.NetworkSpec{Attachments: []fabricv1.NetworkAttachment{{Node: "leaf01", Attachment: "ethernet-1/2"}}}},
	}
	got := tagFlips(in, nets)
	if len(got) != 2 {
		t.Fatalf("%+v", got)
	}
	msg := flipMessage(got)
	for _, s := range []string{"leaf01 ethernet-1/1 would become untagged", "ns-a/tagged", "leaf01 ethernet-1/2 would become tagged", "ns-c/untagged-bad"} {
		if !strings.Contains(msg, s) {
			t.Errorf("message lacks %q: %s", s, msg)
		}
	}
	if strings.Contains(msg, "untagged-ok") {
		t.Errorf("a matching attachment named: %s", msg)
	}
}

func TestBackoffIsBoundedExponential(t *testing.T) {
	base, cap := 250*time.Millisecond, 10*time.Second
	want := []time.Duration{250 * time.Millisecond, 500 * time.Millisecond, time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 10 * time.Second, 10 * time.Second}
	for i, w := range want {
		if got := Backoff(base, cap, i+1, nil); got != w {
			t.Errorf("attempt %d: %s, want %s", i+1, got, w)
		}
	}
	if got := Backoff(base, cap, 3, func() float64 { return 0.5 }); got != 500*time.Millisecond {
		t.Errorf("full jitter: %s", got)
	}
}

func TestSplitP2PAndLoopback(t *testing.T) {
	a, b, err := splitP2P("10.1.0.4/31")
	if err != nil || a != "10.1.0.4/31" || b != "10.1.0.5/31" {
		t.Errorf("%s %s %v", a, b, err)
	}
	if _, _, err := splitP2P("10.1.0.4/30"); err == nil {
		t.Error("/30 accepted as a link")
	}
	if p, err := hostPrefix32("10.0.0.7/24"); err != nil || p != "10.0.0.7/32" {
		t.Errorf("%s %v", p, err)
	}
}

// T182: a pool reference must name the index the installed authority serves, as the
// adapter reports it; a mismatch names the field, what it states and what is served.
func TestPoolRefsFollowTheAuthority(t *testing.T) {
	f := &fabricv1.Fabric{}
	ref := func(g, k string) *fabricv1.PoolRef {
		return &fabricv1.PoolRef{Group: g, Kind: k, Name: "p", Namespace: "n"}
	}
	f.Spec.Underlay.LoopbackPoolRef = ref("ipam.be.kuid.dev", "IPIndex")
	f.Spec.Underlay.LinkPoolRef = ref("ipam.be.kuid.dev", "IPIndex")
	f.Spec.Underlay.ASNPoolRef = ref("as.be.kuid.dev", "ASIndex")
	if err := checkPoolRefs(f, kuid.NewUpstream(nil)); err != nil {
		t.Fatalf("kuid refs under kuid: %v", err)
	}
	err := checkPoolRefs(f, kuid.NewFirstParty(nil))
	if err == nil {
		t.Fatal("kuid refs accepted under first-party")
	}
	for _, s := range []string{"spec.underlay.loopbackPoolRef names ipam.be.kuid.dev/IPIndex", "spec.underlay.asnPoolRef names as.be.kuid.dev/ASIndex",
		"spec.underlay.linkPoolRef", "(first-party)", "fabric.agentic-netops.io/IdentifierPool"} {
		if !strings.Contains(err.Error(), s) {
			t.Errorf("message lacks %q: %v", s, err)
		}
	}
	fp := ref("fabric.agentic-netops.io", "IdentifierPool")
	f.Spec.Underlay.LoopbackPoolRef, f.Spec.Underlay.LinkPoolRef, f.Spec.Underlay.ASNPoolRef = fp, fp, fp
	if err := checkPoolRefs(f, kuid.NewFirstParty(nil)); err != nil {
		t.Fatalf("first-party refs under first-party: %v", err)
	}
	if err := checkPoolRefs(f, kuid.NewUpstream(nil)); err == nil || !strings.Contains(err.Error(), "(kuid) serves IP claims from ipam.be.kuid.dev/IPIndex") {
		t.Fatalf("first-party refs under kuid: %v", err)
	}
}
