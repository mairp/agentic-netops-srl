package srl

import "github.com/mairp/agentic-netops-srl/internal/model"

// renderTunnelInterfaces builds /tunnel-interface for the fabric Config: the
// tunnel-interface vxlan0 entry (spec.overlay.tunnelInterface, a fabric
// constant) on a leaf, and nothing on a spine — spines terminate no tenant
// VXLAN (evidence/02-evpn-constructs.md §1.1). The fabric renders no
// vxlan-interface: each one, with its `egress source-ip
// use-system-ipv4-address` (the system0.0 IPv4 address, the only VTEP source
// the image supports, §1.3), belongs to the service that keys it
// (data-model.md §13, AD-68). It returns nil when nothing is rendered.
func renderTunnelInterfaces(n *model.FabricNode) *list {
	if !n.VXLANTunnel {
		return nil
	}
	return newList("name").add(container{"name": model.TunnelInterface})
}
