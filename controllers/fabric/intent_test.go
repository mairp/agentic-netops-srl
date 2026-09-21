package fabric

import (
	"strings"
	"testing"
	"time"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
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
