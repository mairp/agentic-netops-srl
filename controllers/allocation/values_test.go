package allocation

import (
	"strings"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
)

func numPool(t *testing.T, typ fabricv1.IdentifierType, lo, hi int64) *shape {
	t.Helper()
	s, err := parsePool(&fabricv1.IdentifierPool{ObjectMeta: metav1.ObjectMeta{Namespace: Namespace, Name: "p"},
		Spec: fabricv1.IdentifierPoolSpec{Type: typ, Range: &fabricv1.IdentifierRange{Start: lo, End: hi}}})
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func ipPool(t *testing.T, prefix string) *shape {
	t.Helper()
	s, err := parsePool(&fabricv1.IdentifierPool{ObjectMeta: metav1.ObjectMeta{Namespace: Namespace, Name: "p"},
		Spec: fabricv1.IdentifierPoolSpec{Type: fabricv1.IdentifierTypeIP, Prefix: prefix}})
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func ledger(kv ...string) []fabricv1.IdentifierAllocation {
	var out []fabricv1.IdentifierAllocation
	for i := 0; i < len(kv); i += 2 {
		out = append(out, fabricv1.IdentifierAllocation{Value: kv[i], Claim: kv[i+1]})
	}
	return out
}

func i32(v int32) *int32 { return &v }

func TestParsePoolRefusesInvalidPools(t *testing.T) {
	for name, spec := range map[string]fabricv1.IdentifierPoolSpec{
		"vlan beyond 4094": {Type: "vlan", Range: &fabricv1.IdentifierRange{Start: 1000, End: 4095}},
		"vlan 0":           {Type: "vlan", Range: &fabricv1.IdentifierRange{Start: 0, End: 10}},
		"vni beyond 24bit": {Type: "vni", Range: &fabricv1.IdentifierRange{Start: 1, End: 1 << 24}},
		"reversed":         {Type: "asn", Range: &fabricv1.IdentifierRange{Start: 10, End: 5}},
		"ip host bits":     {Type: "ip", Prefix: "10.0.0.1/24"},
		"ip with range":    {Type: "ip", Range: &fabricv1.IdentifierRange{Start: 1, End: 2}},
		"asn with prefix":  {Type: "asn", Prefix: "10.0.0.0/24"},
		"unknown type":     {Type: "mac", Range: &fabricv1.IdentifierRange{Start: 1, End: 2}},
	} {
		if _, err := parsePool(&fabricv1.IdentifierPool{Spec: spec}); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestLowestFreeNumeric(t *testing.T) {
	s := numPool(t, fabricv1.IdentifierTypeVLAN, 1000, 4000)
	var l []fabricv1.IdentifierAllocation
	var got []string
	for i := 0; i < 3; i++ {
		v, ok := s.lowestFree(l, 0)
		if !ok {
			t.Fatal("exhausted")
		}
		got = append(got, v)
		l = append(l, fabricv1.IdentifierAllocation{Value: v, Claim: v})
	}
	if strings.Join(got, ",") != "1000,1001,1002" {
		t.Errorf("three dynamic values %v, want the three lowest", got)
	}
	// A hole is filled first; values below the minimum in the ledger are ignored.
	if v, _ := s.lowestFree(ledger("999", "x", "1000", "a", "1002", "b"), 0); v != "1001" {
		t.Errorf("lowest free with a hole = %s", v)
	}
	small := numPool(t, fabricv1.IdentifierTypeGENID, 5, 6)
	if _, ok := small.lowestFree(ledger("5", "a", "6", "b"), 0); ok {
		t.Error("a full pool is not exhausted")
	}
}

func TestLowestFreeIP(t *testing.T) {
	s := ipPool(t, "10.1.0.0/24")
	var l []fabricv1.IdentifierAllocation
	for _, want := range []string{"10.1.0.0/31", "10.1.0.2/31", "10.1.0.4/31"} {
		v, ok := s.lowestFree(l, 31)
		if !ok || v != want {
			t.Fatalf("dynamic /31 = %s %v, want %s", v, ok, want)
		}
		l = append(l, fabricv1.IdentifierAllocation{Value: v, Claim: v})
	}
	// Host addresses skip the held blocks; an unaligned holder pushes to the next block.
	if v, _ := s.lowestFree(l, 32); v != "10.1.0.6/32" {
		t.Errorf("host after three /31s = %s", v)
	}
	if v, _ := s.lowestFree(ledger("10.1.0.1/32", "a"), 30); v != "10.1.0.4/30" {
		t.Errorf("/30 past a held host = %s", v)
	}
	tiny := ipPool(t, "10.0.0.0/31")
	if _, ok := tiny.lowestFree(ledger("10.0.0.0/32", "a", "10.0.0.1/32", "b"), 32); ok {
		t.Error("a full /31 is not exhausted")
	}
	if _, ok := tiny.lowestFree(nil, 30); ok {
		t.Error("a /30 fits in a /31")
	}
	v6 := ipPool(t, "fd00::/64")
	if v, _ := v6.lowestFree(ledger("fd00::/128", "a"), 128); v != "fd00::1/128" {
		t.Errorf("v6 host = %s", v)
	}
	if v, _ := v6.lowestFree(ledger("fd00::/127", "a"), 127); v != "fd00::2/127" {
		t.Errorf("v6 /127 = %s", v)
	}
}

func TestCanonical(t *testing.T) {
	s := numPool(t, fabricv1.IdentifierTypeVLAN, 1000, 4000)
	if v, r := s.canonical("1234", nil); r != nil || v != "1234" {
		t.Errorf("1234: %s %v", v, r)
	}
	if _, r := s.canonical("999", nil); r == nil || r.Reason != ReasonOutOfRange ||
		!strings.Contains(r.Message, "value 999") || !strings.Contains(r.Message, "range 1000-4000") {
		t.Errorf("999: %v", r)
	}
	for _, bad := range []string{"abc", "-1", "10.0.0.1"} {
		if _, r := s.canonical(bad, nil); r == nil || r.Reason != ReasonInvalid {
			t.Errorf("%q: %v", bad, r)
		}
	}
	if _, r := s.canonical("1234", i32(31)); r == nil || r.Reason != ReasonInvalid {
		t.Errorf("prefixLength on a vlan pool: %v", r)
	}

	ip := ipPool(t, "10.0.0.0/24")
	for in, want := range map[string]string{"10.0.0.11": "10.0.0.11/32", "10.0.0.11/32": "10.0.0.11/32", "10.0.0.4/31": "10.0.0.4/31"} {
		if v, r := ip.canonical(in, nil); r != nil || v != want {
			t.Errorf("%s: %s %v, want %s", in, v, r, want)
		}
	}
	for in, reason := range map[string]string{"10.0.1.1": ReasonOutOfRange, "10.0.0.0/16": ReasonOutOfRange, "fd00::1": ReasonOutOfRange,
		"10.0.0.5/31": ReasonInvalid, "ten": ReasonInvalid} {
		if _, r := ip.canonical(in, nil); r == nil || r.Reason != reason {
			t.Errorf("%s: %v, want %s", in, r, reason)
		}
	}
	if _, r := ip.canonical("10.0.0.4/31", i32(30)); r == nil || r.Reason != ReasonInvalid {
		t.Errorf("contradicting prefixLength: %v", r)
	}
}

func TestHolderAndDynamicBits(t *testing.T) {
	s := numPool(t, fabricv1.IdentifierTypeVLAN, 1000, 4000)
	if h := s.holder("1234", ledger("1234", "a"), "b"); h == nil || h.Claim != "a" {
		t.Errorf("holder = %v", h)
	}
	if h := s.holder("1234", ledger("1234", "a"), "a"); h != nil {
		t.Error("a claim is its own holder")
	}
	ip := ipPool(t, "10.1.0.0/24")
	if h := ip.holder("10.1.0.0/30", ledger("10.1.0.2/31", "a"), "b"); h == nil {
		t.Error("an overlapping prefix is not held")
	}
	if b, r := ip.dynamicBits(nil); r != nil || b != 32 {
		t.Errorf("default bits %d %v", b, r)
	}
	for _, pl := range []int32{16, 33} {
		if _, r := ip.dynamicBits(i32(pl)); r == nil || r.Reason != ReasonInvalid {
			t.Errorf("prefixLength %d: %v", pl, r)
		}
	}
	if _, r := s.dynamicBits(i32(31)); r == nil || r.Reason != ReasonInvalid {
		t.Errorf("prefixLength on a numeric pool: %v", r)
	}
	l := ledger("10", "a", "9", "b", "100", "c")
	numPool(t, fabricv1.IdentifierTypeGENID, 1, 1000).sortLedger(l)
	if l[0].Value != "9" || l[2].Value != "100" {
		t.Errorf("ledger not sorted numerically: %v", l)
	}
}
