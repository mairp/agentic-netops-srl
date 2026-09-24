// T053 — the `ip-vrf` construct (contracts/reconciliation.md Rule 11;
// data-model.md §13; FR-030). Shared fixtures and checks are in
// vlan_render_test.go.
package render_test

import (
	"strings"
	"testing"
)

// TestIPVRFConstruct: routed subinterfaces carrying the attachment addresses
// (the declared prefixes, advertised in Type-5 routes because they are in the
// routed instance's route table — no route-table, policy or redistribution is
// rendered), the L3VNI vxlan-interface type routed, and an interface-less
// EVPN instance (evi := l3vni) with explicit route targets.
func TestIPVRFConstruct(t *testing.T) {
	r := renderService(t, ipvrfInput())
	addr := map[string][2]string{"leaf01": {"10.40.1.1/24", "2001:db8:40:1::1/64"}, "leaf02": {"10.40.2.1/24", "2001:db8:40:2::1/64"}}
	for _, node := range leaves {
		f := flattenService(t, r[node].JSON)
		sub := "/interface[name=ethernet-1/1]/subinterface[index=400]"
		want(t, f, sub+"/type", `"srl_nokia-interfaces:routed"`)
		want(t, f, sub+"/admin-state", `"enable"`)
		want(t, f, sub+"/vlan/encap/single-tagged/vlan-id", "400")
		// the tenant IP MTU (data-model.md §20) — the device default would drop a
		// 9320-byte payload that the probe of T065 must pass
		want(t, f, sub+"/ip-mtu", "9348")
		want(t, f, sub+"/ipv4/admin-state", `"enable"`)
		want(t, f, sub+"/ipv4/address[ip-prefix="+addr[node][0]+"]", "{}")
		want(t, f, sub+"/ipv6/admin-state", `"enable"`)
		want(t, f, sub+"/ipv6/address[ip-prefix="+addr[node][1]+"]", "{}")
		vx := "/tunnel-interface[name=vxlan0]/vxlan-interface[index=10400]"
		want(t, f, vx+"/type", `"srl_nokia-interfaces:routed"`)
		want(t, f, vx+"/ingress/vni", "10400")
		ni := "/network-instance[name=ipvrf-db]"
		want(t, f, ni+"/type", `"srl_nokia-network-instance:ip-vrf"`)
		want(t, f, ni+"/admin-state", `"enable"`)
		want(t, f, ni+"/description", `"Service db (ip-vrf)"`)
		want(t, f, ni+"/interface[name=ethernet-1/1.400]", "{}")
		want(t, f, ni+"/vxlan-interface[name=vxlan0.10400]", "{}")
		evpn := ni + "/protocols/bgp-evpn/bgp-instance[id=1]"
		want(t, f, evpn+"/encapsulation-type", `"vxlan"`)
		want(t, f, evpn+"/vxlan-interface", `"vxlan0.10400"`)
		want(t, f, evpn+"/evi", "10400")
		want(t, f, evpn+"/ecmp", "8")
		vpn := ni + "/protocols/bgp-vpn/bgp-instance[id=1]"
		want(t, f, vpn+"/route-target/export-rt", `"target:65000:10400"`)
		want(t, f, vpn+"/route-target/import-rt", `"target:65000:10400"`)
		// Only this node's own attachment address; interface-less: no irb, no
		// bridged member, no supplementary broadcast domain; no route-table,
		// static route or policy — the addresses are the declared prefixes.
		other := addr["leaf01"][0]
		if node == "leaf01" {
			other = addr["leaf02"][0]
		}
		for p := range f {
			switch {
			case strings.Contains(p, other):
				t.Errorf("%s: another node's attachment address rendered: %s", node, p)
			case strings.Contains(p, "egress/source-ip"):
				t.Errorf("%s: a routed vxlan-interface renders no egress source-ip: %s", node, p)
			case strings.Contains(p, "irb0"), strings.Contains(p, "bridge-table"), strings.Contains(p, "supplementary"),
				strings.Contains(p, "/routes/"), strings.Contains(p, "route-table"), strings.Contains(p, "static-routes"),
				strings.Contains(p, "routing-policy"), strings.Contains(p, "mac-vrf"):
				t.Errorf("%s: an interface-less ip-vrf renders %s", node, p)
			}
		}
	}
}
