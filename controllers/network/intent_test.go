package network

import (
	"reflect"
	"strings"
	"testing"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
)

func router(prefixes ...string) fabricv1.NetworkRouter {
	r := fabricv1.NetworkRouter{Name: "vrf-a", L3VNI: 10130}
	for _, p := range prefixes {
		r.Prefixes = append(r.Prefixes, fabricv1.IPPrefix(p))
	}
	return r
}

var twoLeaves = []attachment{
	{Node: "leaf02", Port: "ethernet-1/1", VLAN: 130, VLANSet: true, VRF: "vrf-a"},
	{Node: "leaf01", Port: "ethernet-1/1", VLAN: 130, VLANSet: true, VRF: "vrf-a"},
}

// One prefix per attachment, assigned in (node, port, vlan) order and address order,
// whatever order the spec lists them in; each attachment carries the first host address.
func TestRoutedAddressesOnePerAttachment(t *testing.T) {
	got, err := routedAddresses(router("2001:db8:130:2::/64", "10.130.2.0/24", "10.130.1.0/24", "2001:db8:130:1::/64"), twoLeaves)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]routedAddress{
		"leaf01 ethernet-1/1 vlan 130": {v4: []string{"10.130.1.1/24"}, v6: []string{"2001:db8:130:1::1/64"}},
		"leaf02 ethernet-1/1 vlan 130": {v4: []string{"10.130.2.1/24"}, v6: []string{"2001:db8:130:2::1/64"}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v, want %#v", got, want)
	}
}

// One prefix: every attachment is its gateway.
func TestRoutedAddressesOneShared(t *testing.T) {
	got, err := routedAddresses(router("10.53.0.0/24"), twoLeaves)
	if err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"leaf01 ethernet-1/1 vlan 130", "leaf02 ethernet-1/1 vlan 130"} {
		if !reflect.DeepEqual(got[k].v4, []string{"10.53.0.1/24"}) || got[k].v6 != nil {
			t.Fatalf("%s: got %#v", k, got[k])
		}
	}
}

func TestRoutedAddressesRefusals(t *testing.T) {
	three := append(append([]attachment(nil), twoLeaves...), attachment{Node: "leaf01", Port: "ethernet-1/1", VLAN: 131, VLANSet: true, VRF: "vrf-a"})
	for name, tc := range map[string]struct {
		r    fabricv1.NetworkRouter
		atts []attachment
		want string
	}{
		"no prefix":      {router(), twoLeaves, "declares no prefix"},
		"host bits":      {router("10.130.1.5/24"), twoLeaves, "host bits set"},
		"no host":        {router("10.130.1.1/32"), twoLeaves, "holds no host address"},
		"overlap":        {router("10.130.0.0/16", "10.130.1.0/24"), twoLeaves, "overlap"},
		"count mismatch": {router("10.130.1.0/24", "10.130.2.0/24"), three, "declares 2 ipv4 prefixes for 3 attachments"},
		"not a prefix":   {router("banana"), twoLeaves, "is not a prefix"},
	} {
		if _, err := routedAddresses(tc.r, tc.atts); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: got %v, want an error containing %q", name, err, tc.want)
		}
	}
}
