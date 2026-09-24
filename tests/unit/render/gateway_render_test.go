// T115 — the anycast gateway of a `mac-vrf` (User Story 8; FR-032, FR-100,
// CR-002, CR-010; contracts/reconciliation.md Rule 11; data-model.md §10
// AnycastGateway and §13 the `mac-vrf` + gateway row).
//
// The gateway is a property of the mac-vrf, never a fifth construct: it adds
// irb0.<vlan> carrying the anycast addresses and the fabric-constant
// virtual-router-id, a member of BOTH the bridged macvrf-<id> and the routed
// ipvrf-<id>, with an explicit ip-mtu. Only the declared address families are
// rendered: a v4-only gateway renders nothing IPv6, a v6-only one nothing IPv4.
// A mac-vrf without a gateway renders no routed half at all. `primary` is
// never rendered (live finding 2026-09-24-irb-primary, internal/render/srl/irb.go).
//
// The single-family goldens gateway_ipv4-<node>.json / gateway_ipv6-<node>.json
// and the shipped example's gateway_example-<node>.json sit beside the dual
// family macvrf-gw-<node>.json under tests/golden/services/ and are
// regenerated and validated like every service golden (TestServiceGoldens
// -update; make verify-render-schema validates every file in the directory).
package render_test

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/pkg/register"
)

// gatewayIPv4Input / gatewayIPv6Input: a mac-vrf with a single-family anycast
// gateway on the lab topology.
func gatewayIPv4Input() model.ServiceInput {
	return model.ServiceInput{ServiceID: "gw4", Tenant: "tenant1", Construct: model.ConstructMACVRF, FabricASN: 65000,
		L2: &model.L2Segment{VLAN: 310, L2VNI: 10310, L2MTU: 9412, Attachments: []model.Attachment{
			{Node: "leaf01", Port: "ethernet-1/1"}, {Node: "leaf02", Port: "ethernet-1/1"}}},
		Gateway: &model.Gateway{L3VNI: 10311, IPv4: []string{"10.31.0.1/24"}, IPMTU: 9348}}
}

func gatewayIPv6Input() model.ServiceInput {
	return model.ServiceInput{ServiceID: "gw6", Tenant: "tenant1", Construct: model.ConstructMACVRF, FabricASN: 65000,
		L2: &model.L2Segment{VLAN: 320, L2VNI: 10320, L2MTU: 9412, Attachments: []model.Attachment{
			{Node: "leaf01", Port: "ethernet-1/1"}, {Node: "leaf02", Port: "ethernet-1/1"}}},
		Gateway: &model.Gateway{L3VNI: 10321, IPv6: []string{"2001:db8:32::1/64"}, IPMTU: 9348}}
}

// gatewayExampleInput maps the shipped example examples/constructs/macvrf-gateway.yaml
// to the service input the provider renders it from — the gateway branch of
// controllers/network/intent.go (irb.vrf names the routers entry whose l3vni
// the gateway carries; each declared gatewayIPv4/gatewayIPv6 one address; the
// ip-mtu the Fabric's tenantIPMTU) with the lab Fabric's MTUs
// (examples/fabric/fabric01.yaml) and ASN. Its golden is the example's own
// render, so the example cannot drift from what is validated.
func gatewayExampleInput(t *testing.T) model.ServiceInput {
	t.Helper()
	const file = "macvrf-gateway.yaml"
	b, err := os.ReadFile(filepath.Join("../../../examples/constructs", file))
	if err != nil {
		t.Fatal(err)
	}
	var n fabricv1.Network
	if err := yaml.UnmarshalStrict(b, &n); err != nil {
		t.Fatalf("%s: %v", file, err)
	}
	s := n.Spec
	if len(s.BridgeDomains) != 1 || s.BridgeDomains[0].IRB == nil || len(s.Routers) != 1 || len(s.AccessLists) != 0 {
		t.Fatalf("%s: the mapping here covers one bridge domain with a gateway into one router", file)
	}
	bd, r := s.BridgeDomains[0], s.Routers[0]
	if string(bd.IRB.VRF) != string(r.Name) {
		t.Fatalf("%s: irb.vrf %s names no routers entry", file, bd.IRB.VRF)
	}
	in := model.ServiceInput{ServiceID: strings.TrimPrefix(n.Name, "migr-"), Tenant: n.Annotations["agentic-netops.io/tenant"],
		Construct: model.ConstructMACVRF, FabricASN: 65000,
		L2:      &model.L2Segment{VLAN: uint32(bd.VLAN), L2VNI: uint32(bd.L2VNI), L2MTU: 9412},
		Gateway: &model.Gateway{L3VNI: uint32(r.L3VNI), IPMTU: 9348}}
	for _, a := range s.Attachments {
		in.L2.Attachments = append(in.L2.Attachments, model.Attachment{Node: string(a.Node), Port: string(a.Attachment)})
	}
	if bd.IRB.GatewayIPv4 != "" {
		in.Gateway.IPv4 = []string{bd.IRB.GatewayIPv4}
	}
	if bd.IRB.GatewayIPv6 != "" {
		in.Gateway.IPv6 = []string{bd.IRB.GatewayIPv6}
	}
	return in
}

// TestGatewayExampleFrozen: the shipped example renders the gateway it
// describes (VLAN 160, L2VNI 10160, L3VNI 10161, 10.160.0.1/24 +
// 2001:db8:160::1/64); TestServiceGoldens freezes that render as
// gateway_example-<node>.json.
func TestGatewayExampleFrozen(t *testing.T) {
	in := gatewayExampleInput(t)
	if in.L2.VLAN != 160 || in.L2.L2VNI != 10160 || in.Gateway.L3VNI != 10161 ||
		!slices.Equal(in.Gateway.IPv4, []string{"10.160.0.1/24"}) || !slices.Equal(in.Gateway.IPv6, []string{"2001:db8:160::1/64"}) {
		t.Fatalf("examples/constructs/macvrf-gateway.yaml maps to %+v %+v", in.L2, in.Gateway)
	}
	for _, r := range renderService(t, in) {
		f := flattenService(t, r.JSON)
		irb := "/interface[name=irb0]/subinterface[index=160]"
		want(t, f, irb+"/ipv4/address[ip-prefix=10.160.0.1/24]/anycast-gw", "true")
		want(t, f, irb+"/ipv6/address[ip-prefix=2001:db8:160::1/64]/anycast-gw", "true")
		want(t, f, "/network-instance[name=ipvrf-lab-macvrf-gateway]/interface[name=irb0.160]", "{}")
		want(t, f, "/network-instance[name=macvrf-lab-macvrf-gateway]/interface[name=irb0.160]", "{}")
		want(t, f, "/tunnel-interface[name=vxlan0]/vxlan-interface[index=10161]/type", `"srl_nokia-interfaces:routed"`)
	}
}

// gatewayChecks is the gateway contract every gateway render is held to:
// irb0.<vlan> with the fabric-constant virtual-router-id and an explicit
// ip-mtu, a member of both instances, the routed L3VNI vxlan-interface and
// protect-anycast-gw-mac; and, per family, the family's container exactly
// when the gateway declares it.
func gatewayChecks(t *testing.T, name string, in model.ServiceInput) {
	t.Helper()
	gw, vlan := in.Gateway, in.L2.VLAN
	irb := fmt.Sprintf("/interface[name=irb0]/subinterface[index=%d]", vlan)
	irbName := fmt.Sprintf("irb0.%d", vlan)
	mac, ip := "/network-instance[name=macvrf-"+in.ServiceID+"]", "/network-instance[name=ipvrf-"+in.ServiceID+"]"
	for node, r := range renderService(t, in) {
		f := flattenService(t, r.JSON)
		t.Run(name+"/"+node, func(t *testing.T) {
			want(t, f, irb+"/admin-state", `"enable"`)
			want(t, f, irb+"/anycast-gw/virtual-router-id", fmt.Sprint(model.AnycastVirtualRouterID))
			want(t, f, irb+"/ip-mtu", fmt.Sprint(gw.IPMTU))
			want(t, f, mac+"/interface[name="+irbName+"]", "{}")
			want(t, f, ip+"/interface[name="+irbName+"]", "{}")
			want(t, f, ip+"/type", `"srl_nokia-network-instance:ip-vrf"`)
			want(t, f, mac+"/bridge-table/protect-anycast-gw-mac", "true")
			want(t, f, fmt.Sprintf("/tunnel-interface[name=vxlan0]/vxlan-interface[index=%d]/type", gw.L3VNI), `"srl_nokia-interfaces:routed"`)
			want(t, f, ip+"/vxlan-interface[name="+fmt.Sprintf("vxlan0.%d", gw.L3VNI)+"]", "{}")
			for _, a := range gw.IPv4 {
				want(t, f, irb+"/ipv4/admin-state", `"enable"`)
				want(t, f, irb+"/ipv4/address[ip-prefix="+a+"]/anycast-gw", "true")
				want(t, f, irb+"/ipv4/arp/learn-unsolicited", "true")
				want(t, f, irb+"/ipv4/arp/host-route/populate[route-type=dynamic]", "{}")
				want(t, f, irb+"/ipv4/arp/evpn/advertise[route-type=dynamic]", "{}")
			}
			for _, a := range gw.IPv6 {
				want(t, f, irb+"/ipv6/admin-state", `"enable"`)
				want(t, f, irb+"/ipv6/address[ip-prefix="+a+"]/anycast-gw", "true")
				want(t, f, irb+"/ipv6/neighbor-discovery/learn-unsolicited", `"global"`)
				want(t, f, irb+"/ipv6/neighbor-discovery/host-route/populate[route-type=dynamic]", "{}")
				want(t, f, irb+"/ipv6/neighbor-discovery/evpn/advertise[route-type=dynamic]", "{}")
			}
			// Declared families only (FR-032): no container, no leaf, no
			// address of an undeclared family anywhere in the document.
			for fam, declared := range map[string]bool{"ipv4": len(gw.IPv4) > 0, "ipv6": len(gw.IPv6) > 0} {
				if declared {
					continue
				}
				for p := range f {
					if strings.Contains(p, "/"+fam) {
						t.Errorf("%s is not declared, yet %s is rendered", fam, p)
					}
				}
			}
			if len(gw.IPv6) == 0 {
				if s := string(r.JSON); strings.Contains(s, "ipv6") || strings.Contains(s, "neighbor-discovery") {
					t.Errorf("an IPv4-only gateway's document mentions IPv6:\n%s", s)
				}
			}
			if len(gw.IPv4) == 0 && strings.Contains(string(r.JSON), `:arp"`) {
				t.Error("an IPv6-only gateway renders arp")
			}
		})
	}
}

// TestGatewayDeclaredFamiliesOnly: dual, v4-only and v6-only gateways each
// render exactly their declared families.
func TestGatewayDeclaredFamiliesOnly(t *testing.T) {
	gatewayChecks(t, "dual", macvrfGWInput())
	gatewayChecks(t, "ipv4", gatewayIPv4Input())
	gatewayChecks(t, "ipv6", gatewayIPv6Input())
	gatewayChecks(t, "example", gatewayExampleInput(t))
}

// TestMACVRFWithoutGatewayRendersNoRoutedHalf: a mac-vrf without a gateway
// renders no ipvrf network-instance, no irb0 subinterface, no routed
// vxlan-interface and no bridge-table protect-anycast-gw-mac.
func TestMACVRFWithoutGatewayRendersNoRoutedHalf(t *testing.T) {
	for node, r := range renderService(t, macvrfInput()) {
		f := flattenService(t, r.JSON)
		for p, v := range f {
			switch {
			case strings.HasPrefix(p, "/network-instance[name=") && !strings.HasPrefix(p, "/network-instance[name=macvrf-app]"):
				t.Errorf("%s: an instance other than the mac-vrf: %s", node, p)
			case strings.HasPrefix(p, "/interface[name=irb0]"):
				t.Errorf("%s: an irb0 subinterface: %s", node, p)
			case strings.HasSuffix(p, "/type") && strings.HasPrefix(p, "/tunnel-interface[") && v != `"srl_nokia-interfaces:bridged"`:
				t.Errorf("%s: a %s vxlan-interface: %s", node, v, p)
			case strings.Contains(p, "protect-anycast-gw-mac") || strings.Contains(p, "anycast-gw"):
				t.Errorf("%s: %s", node, p)
			}
		}
		if strings.Contains(string(r.JSON), "ip-vrf") || strings.Contains(string(r.JSON), "irb0") {
			t.Errorf("%s: the document names an ip-vrf or irb0", node)
		}
	}
}

// TestGatewayNeverRendersPrimary: no gateway render, no golden, no write path
// and no register entry carries `primary`. The pinned device-configuration
// layer cannot carry the empty leaf — `[null]` (the G12-observed form) and
// `{}` are refused by the device's parser through the layer and `null` is
// dropped (live finding 2026-09-24-irb-primary) — and with one address per
// family the device makes that address primary by default.
func TestGatewayNeverRendersPrimary(t *testing.T) {
	for name, in := range map[string]model.ServiceInput{"dual": macvrfGWInput(), "ipv4": gatewayIPv4Input(),
		"ipv6": gatewayIPv6Input(), "example": gatewayExampleInput(t)} {
		m, err := model.BuildService(in)
		if err != nil {
			t.Fatal(err)
		}
		for i := range m.Nodes {
			for _, p := range m.Nodes[i].WritePaths() {
				if strings.HasSuffix(p, "/primary") {
					t.Errorf("%s/%s: write path %s", name, m.Nodes[i].Node, p)
				}
			}
		}
		for node, r := range renderService(t, in) {
			if strings.Contains(string(r.JSON), `"primary"`) {
				t.Errorf("%s/%s: primary rendered", name, node)
			}
		}
	}
	entries, err := os.ReadDir(serviceGoldenDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		b, err := os.ReadFile(filepath.Join(serviceGoldenDir, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		var doc any
		if err := json.Unmarshal(b, &doc); err != nil {
			t.Fatalf("%s: %v", e.Name(), err)
		}
		if strings.Contains(string(b), `"primary"`) {
			t.Errorf("golden %s carries primary", e.Name())
		}
	}
	for _, e := range register.WriteEntries() {
		if strings.HasSuffix(e.Path, "/primary") {
			t.Errorf("register entry %s: primary is not written", e.Path)
		}
	}
	p := "/interface[name=irb0]/subinterface[index=300]/ipv4/address[ip-prefix=10.30.0.1/24]/primary"
	if register.CheckWrite([]string{p}) == nil {
		t.Errorf("the register admits %s", p)
	}
}
