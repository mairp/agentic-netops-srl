package srl

import "github.com/mairp/agentic-netops-srl/internal/model"

// renderVXLANInterfaces builds /tunnel-interface for a service Config: the
// tunnel-interface vxlan0 entry — its key only, the entry itself being the
// fabric Config's (T039) — carrying the vxlan-interface[index := vni] entries
// this service owns: type bridged (an L2VNI) or routed (an L3VNI), with the
// srl_nokia-interfaces identity G12 observed module-qualified, ingress vni,
// and on a bridged interface `egress source-ip use-system-ipv4-address`, the
// system0.0 IPv4 address, the only VTEP source the image supports
// (evidence/02-evpn-constructs.md §1.3, data-model.md §13). It returns nil
// when the node owns no vxlan-interface (a `vlan` has no overlay).
func renderVXLANInterfaces(n *model.ServiceNode) *list {
	if len(n.VXLANInterfaces) == 0 {
		return nil
	}
	vx := newList("index")
	for _, v := range n.VXLANInterfaces {
		e := container{
			"index":   v.Index,
			"type":    identityref(modInterfaces, string(v.Type)),
			"ingress": container{"vni": v.VNI},
		}
		if v.EgressSystemIP {
			e["egress"] = container{"source-ip": "use-system-ipv4-address"}
		}
		vx.add(e)
	}
	return newList("name").add(container{"name": model.TunnelInterface, "vxlan-interface": vx})
}

// renderOverlay adds, to a mac-vrf or ip-vrf network-instance entry, its one
// vxlan-interface member (max-elements 1) and its protocols: the bgp-evpn
// bgp-instance[id=1] — admin-state enable, encapsulation-type vxlan, the
// vxlan-interface reference, evi := vni (mandatory, 1..65535) and ecmp — and
// the bgp-vpn bgp-instance[id=1] the evpn instance's id is a leafref to, with
// both route targets rendered explicitly as target:<fabricASN>:<vni>: a
// device-derived route target would use the per-leaf underlay AS and differ
// on every leaf (Rule 11). The route distinguisher is left to the device.
//
// bgp-evpn is declared in srl_nokia-network-instance, its bgp-instance list is
// augmented in by srl_nokia-bgp-evpn; bgp-vpn is augmented into protocols by
// srl_nokia-bgp-vpn — so the list, respectively the container, is qualified.
func renderOverlay(e container, ni *model.NetworkInstance) {
	e["vxlan-interface"] = newList("name").add(container{"name": ni.VXLANInterface})
	protocols := container{}
	if ev := ni.EVPN; ev != nil {
		protocols["bgp-evpn"] = container{
			modBGPEVPN + ":bgp-instance": newList("id").add(container{
				"id":                 ev.ID,
				"admin-state":        adminState(true),
				"encapsulation-type": "vxlan",
				"vxlan-interface":    ev.VXLANInterface,
				"evi":                ev.EVI,
				"ecmp":               ev.ECMP,
			}),
		}
	}
	if vpn := ni.BGPVPN; vpn != nil {
		protocols[modBGPVPN+":bgp-vpn"] = container{
			"bgp-instance": newList("id").add(container{
				"id": vpn.ID,
				"route-target": container{
					"export-rt": vpn.ExportRT,
					"import-rt": vpn.ImportRT,
				},
			}),
		}
	}
	if len(protocols) > 0 {
		e["protocols"] = protocols
	}
}
