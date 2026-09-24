// T053 — the `mac-vrf` construct, with and without an anycast gateway
// (contracts/reconciliation.md Rule 11; data-model.md §13; FR-029, FR-031).
// Shared fixtures and checks are in vlan_render_test.go.
package render_test

import (
	"strings"
	"testing"
)

// TestMACVRFConstruct: bridged ethernet-1/N.<vlan>, vxlan0.<l2vni> type
// bridged sourcing from the system IPv4, bgp-evpn bgp-instance 1 with
// evi := vni, and explicit bgp-vpn route targets target:<fabricASN>:<vni>.
func TestMACVRFConstruct(t *testing.T) {
	r := renderService(t, macvrfInput())
	for _, node := range leaves {
		f := flattenService(t, r[node].JSON)
		sub := "/interface[name=ethernet-1/1]/subinterface[index=200]"
		want(t, f, sub+"/type", `"srl_nokia-interfaces:bridged"`)
		want(t, f, sub+"/admin-state", `"enable"`)
		want(t, f, sub+"/vlan/encap/single-tagged/vlan-id", "200")
		want(t, f, sub+"/l2-mtu", "9412") // bridgedL2MTU (data-model.md §20); the device default drops a tenant-MTU frame
		vx := "/tunnel-interface[name=vxlan0]/vxlan-interface[index=10200]"
		want(t, f, vx+"/type", `"srl_nokia-interfaces:bridged"`)
		want(t, f, vx+"/ingress/vni", "10200")
		want(t, f, vx+"/egress/source-ip", `"use-system-ipv4-address"`)
		ni := "/network-instance[name=macvrf-app]"
		want(t, f, ni+"/type", `"srl_nokia-network-instance:mac-vrf"`)
		want(t, f, ni+"/admin-state", `"enable"`)
		want(t, f, ni+"/description", `"Service app (mac-vrf)"`)
		want(t, f, ni+"/interface[name=ethernet-1/1.200]", "{}")
		want(t, f, ni+"/vxlan-interface[name=vxlan0.10200]", "{}")
		evpn := ni + "/protocols/bgp-evpn/bgp-instance[id=1]"
		want(t, f, evpn+"/admin-state", `"enable"`)
		want(t, f, evpn+"/encapsulation-type", `"vxlan"`)
		want(t, f, evpn+"/vxlan-interface", `"vxlan0.10200"`)
		want(t, f, evpn+"/evi", "10200")
		want(t, f, evpn+"/ecmp", "8")
		vpn := ni + "/protocols/bgp-vpn/bgp-instance[id=1]"
		want(t, f, vpn+"/route-target/export-rt", `"target:65000:10200"`)
		want(t, f, vpn+"/route-target/import-rt", `"target:65000:10200"`)
		for p := range f {
			if strings.Contains(p, "irb0") || strings.Contains(p, "ip-vrf") || strings.Contains(p, "bridge-table") ||
				strings.Contains(p, "route-distinguisher") || strings.Contains(p, "/ipv4") || strings.Contains(p, "/ipv6") {
				t.Errorf("%s: a mac-vrf without a gateway renders %s", node, p)
			}
		}
		// The module qualification of the augmented nodes (RFC 7951).
		js := string(r[node].JSON)
		for _, k := range []string{`"srl_nokia-bgp-evpn:bgp-instance"`, `"srl_nokia-bgp-vpn:bgp-vpn"`, `"srl_nokia-interfaces-vlans:vlan"`,
			`"srl_nokia-tunnel-interfaces:tunnel-interface"`, `"bgp-evpn"`} {
			if !strings.Contains(js, k) {
				t.Errorf("%s: member %s missing", node, k)
			}
		}
		if strings.Contains(js, `"srl_nokia-bgp-evpn:bgp-evpn"`) {
			t.Errorf("%s: bgp-evpn is srl_nokia-network-instance's own container and carries no qualification", node)
		}
	}
}

// TestMACVRFGatewayConstruct: a mac-vrf with an anycast gateway renders
// irb0.<vlan> in both the mac-vrf and the ip-vrf, the anycast-gw container
// with virtual-router-id 1, each declared family's address anycast (IPv4
// primary), unsolicited learning, host-route population and EVPN
// advertisement, an explicit ip-mtu, protect-anycast-gw-mac on the mac-vrf,
// and the routed L3VNI vxlan-interface with its own EVPN instance — and never
// irb0's own admin-state (AD-68).
func TestMACVRFGatewayConstruct(t *testing.T) {
	r := renderService(t, macvrfGWInput())
	for _, node := range leaves {
		f := flattenService(t, r[node].JSON)
		irb := "/interface[name=irb0]/subinterface[index=300]"
		want(t, f, irb+"/admin-state", `"enable"`)
		want(t, f, irb+"/anycast-gw/virtual-router-id", "1")
		want(t, f, irb+"/ip-mtu", "9348")
		want(t, f, irb+"/ipv4/admin-state", `"enable"`)
		want(t, f, irb+"/ipv4/address[ip-prefix=10.30.0.1/24]/anycast-gw", "true")
		want(t, f, irb+"/ipv4/address[ip-prefix=10.30.0.1/24]/primary", "[null]")
		want(t, f, irb+"/ipv4/arp/learn-unsolicited", "true")
		want(t, f, irb+"/ipv4/arp/host-route/populate[route-type=dynamic]", "{}")
		want(t, f, irb+"/ipv4/arp/evpn/advertise[route-type=dynamic]", "{}")
		want(t, f, irb+"/ipv6/admin-state", `"enable"`)
		want(t, f, irb+"/ipv6/address[ip-prefix=2001:db8:30::1/64]/anycast-gw", "true")
		want(t, f, irb+"/ipv6/neighbor-discovery/learn-unsolicited", `"global"`)
		want(t, f, irb+"/ipv6/neighbor-discovery/host-route/populate[route-type=dynamic]", "{}")
		want(t, f, irb+"/ipv6/neighbor-discovery/evpn/advertise[route-type=dynamic]", "{}")
		if _, ok := f["/interface[name=irb0]/admin-state"]; ok {
			t.Errorf("%s: irb0's own admin-state is the fabric Config's", node)
		}
		mac, ip := "/network-instance[name=macvrf-4b7e19c2a05d3f6]", "/network-instance[name=ipvrf-4b7e19c2a05d3f6]"
		want(t, f, mac+"/interface[name=irb0.300]", "{}")
		want(t, f, mac+"/interface[name=ethernet-1/1.300]", "{}")
		want(t, f, mac+"/bridge-table/protect-anycast-gw-mac", "true")
		want(t, f, mac+"/vxlan-interface[name=vxlan0.10300]", "{}")
		want(t, f, mac+"/protocols/bgp-evpn/bgp-instance[id=1]/evi", "10300")
		want(t, f, mac+"/protocols/bgp-vpn/bgp-instance[id=1]/route-target/export-rt", `"target:65000:10300"`)
		want(t, f, ip+"/type", `"srl_nokia-network-instance:ip-vrf"`)
		want(t, f, ip+"/interface[name=irb0.300]", "{}")
		want(t, f, ip+"/vxlan-interface[name=vxlan0.10301]", "{}")
		want(t, f, ip+"/protocols/bgp-evpn/bgp-instance[id=1]/evi", "10301")
		want(t, f, ip+"/protocols/bgp-evpn/bgp-instance[id=1]/vxlan-interface", `"vxlan0.10301"`)
		want(t, f, ip+"/protocols/bgp-vpn/bgp-instance[id=1]/route-target/export-rt", `"target:65000:10301"`)
		want(t, f, ip+"/protocols/bgp-vpn/bgp-instance[id=1]/route-target/import-rt", `"target:65000:10301"`)
		want(t, f, "/tunnel-interface[name=vxlan0]/vxlan-interface[index=10300]/type", `"srl_nokia-interfaces:bridged"`)
		vx3 := "/tunnel-interface[name=vxlan0]/vxlan-interface[index=10301]"
		want(t, f, vx3+"/type", `"srl_nokia-interfaces:routed"`)
		want(t, f, vx3+"/ingress/vni", "10301")
		if _, ok := f[vx3+"/egress/source-ip"]; ok {
			t.Errorf("%s: the routed L3VNI interface renders no egress source-ip", node)
		}
		if _, ok := f[ip+"/interface[name=ethernet-1/1.300]"]; ok {
			t.Errorf("%s: the bridged attachment is no member of the ip-vrf", node)
		}
		// The irb0 subinterface carries no interface-ref: it is no access-port
		// subinterface and no access list binds it here.
		for p := range f {
			if strings.HasPrefix(p, "/acl/interface[interface-id=irb0") {
				t.Errorf("%s: %s", node, p)
			}
		}
	}
}
