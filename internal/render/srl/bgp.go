package srl

import (
	"github.com/mairp/agentic-netops-srl/internal/model"
)

// renderDefaultNI builds /network-instance[name=default]: its routed
// interfaces (every fabric port's subinterface 0 and system0.0) and BGP.
func renderDefaultNI(n *model.FabricNode) container {
	ifs := newList("name")
	for _, p := range n.FabricPorts {
		ifs.add(container{"name": model.SubinterfaceName(p.Name, 0)})
	}
	ifs.add(container{"name": model.SubinterfaceName(model.SystemInterface, 0)})
	return container{
		"name":        model.DefaultNetworkInstance,
		"type":        identityref(modNetworkInstance, "default"),
		"admin-state": adminState(true),
		"interface":   ifs,
		"protocols":   container{modBGP + ":bgp": renderBGP(&n.BGP)},
	}
}

// renderBGP builds the default instance's BGP (evidence/02-evpn-constructs.md
// §1.1–§1.2, option (a)): the per-node underlay AS and router-id = system0.0
// IPv4; per-link eBGP in both families — group `underlay` (IPv4 sessions,
// ipv4-unicast only) and `underlay-v6` (IPv6 sessions, ipv6-unicast only),
// both exporting and importing the loopback policy; and the iBGP EVPN overlay,
// group `overlay` with peer-as and local-as = the fabric ASN, evpn only, to
// both reflecting spines from a leaf, and `route-reflector client` on a
// reflecting spine. Every group states every enabled family explicitly, so no
// session carries a family it was not meant to.
//
// inter-as-vpn is rendered on a reflecting spine exactly as the Fabric states
// it — true, or false rendered as false and never dropped — because a
// reflecting spine that is not a VTEP rejects every EVPN route without it
// (R-37); it is a configuration-integrity setting, no longer SC-004's control
// (AD-77).
//
// route-reflector client is rendered on every reflecting spine's overlay group
// exactly as spec.overlay.reflectorClients states it — true by default, or
// false rendered as false and never dropped: the declared false is SC-004's
// negative control (AD-77).
//
// `as-path-options allow-own-as` is rendered on the underlay groups of a node
// whose AS another node shares (the spines), so each learns the other's
// loopback through a leaf — the loopback-route invariant of the read-back,
// observed by G8 on exactly this setting.
func renderBGP(b *model.FabricBGP) container {
	fams := b.Families()
	afis := newList("afi-safi-name")
	for _, f := range fams {
		e := container{"afi-safi-name": afiSafi(f), "admin-state": adminState(true)}
		if f == model.AFIEVPN && b.InterASVPN != nil {
			e["evpn"] = container{"inter-as-vpn": *b.InterASVPN}
		}
		afis.add(e)
	}

	groups := newList("group-name")
	for _, g := range b.Groups() {
		e := container{"group-name": g}
		ga := newList("afi-safi-name")
		for _, f := range fams {
			ga.add(container{"afi-safi-name": afiSafi(f), "admin-state": adminState(b.GroupFamilyEnabled(g, f))})
		}
		e["afi-safi"] = ga
		if g == model.OverlayGroup {
			e["peer-as"] = b.OverlayAS
			e["local-as"] = container{"as-number": b.OverlayAS}
			if b.RouteReflectorClient != nil {
				e["route-reflector"] = container{"client": *b.RouteReflectorClient}
			}
		} else {
			e["export-policy"] = leafList{model.LoopbackPolicy}
			e["import-policy"] = leafList{model.LoopbackPolicy}
			if b.AllowOwnAS > 0 {
				e["as-path-options"] = container{"allow-own-as": b.AllowOwnAS}
			}
		}
		groups.add(e)
	}

	nbrs := newList("peer-address")
	for _, nb := range b.Neighbors {
		e := container{"peer-address": nb.PeerAddress, "peer-group": nb.PeerGroup}
		if nb.PeerAS != 0 {
			e["peer-as"] = nb.PeerAS
		}
		if nb.LocalAddress != "" {
			e["transport"] = container{"local-address": nb.LocalAddress}
		}
		nbrs.add(e)
	}

	return container{
		"admin-state":       adminState(true),
		"autonomous-system": b.AutonomousSystem,
		"router-id":         b.RouterID,
		"afi-safi":          afis,
		"group":             groups,
		"neighbor":          nbrs,
	}
}

// afiSafi is the afi-safi-name identityref; the identities live in
// srl_nokia-common, so RFC 7951 requires the qualified form.
func afiSafi(f string) string { return identityref(modCommon, f) }
