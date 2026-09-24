package verify

// The mac-vrf applied-side read-back (T058; data-model.md §13 "Read-back per
// construct", mac-vrf row; FR-100, CR-001).
//
// On every node: the vlan set (network-instance, member interfaces,
// subinterfaces), plus the bridged vxlan-interface as a network-instance member
// and on the tunnel, the EVPN instance oper-state, and the device's own
// route-distinguisher origin (auto-derived-from-evi) and route-target origins
// (manual). An auto-derived route-target origin means the render dropped the
// target and the service is about to fail to form silently.
//
// Once the service spans more than one leaf, per OTHER leaf of this service,
// keyed to that leaf's allocated system0.0 address (its VTEP) and this
// service's L2VNI:
//
//	/tunnel-interface[name=vxlan0]/vxlan-interface[index=<l2vni>]/bridge-table/
//	    multicast-destinations/destination[vtep=<remote>][vni=<l2vni>]/destination-index  != 0
//	    …/destination[vtep=<remote>][vni=<l2vni>]/not-programmed-reason                   absent
//	/tunnel/vxlan-tunnel/vtep[address=<remote>]/index                                     != 0
//
// The multicast destination exists only because this leaf imported the remote
// leaf's Type-3 (IMET) route for this very EVI, so it is the service's own
// route-exchange evidence; absent is RoutesMissing, a zero index or a
// not-programmed-reason is NotProgrammed. No count of routes is read.

import (
	"fmt"
	"net/netip"
	"sort"
	"strings"

	"github.com/mairp/agentic-netops-srl/internal/model"
)

// macvrfExpectations are the mac-vrf leaves of instance ni on node n.
func macvrfExpectations(m *model.ServiceModel, n *model.ServiceNode, ni *model.NetworkInstance,
	loopbacks map[string]string) ([]StateExpectation, error) {
	vx := vxlanOf(n, ni)
	out := vlanExpectations(n, ni)
	out = append(out, overlayExpectations(ni, vx)...)
	if vx == nil {
		return out, nil
	}
	remotes, err := remoteVTEPs(m, n, ni, loopbacks)
	if err != nil {
		return nil, err
	}
	for _, r := range remotes {
		out = append(out,
			StateExpectation{Check: CheckMulticastDestination,
				What: fmt.Sprintf("%s multicast destination to %s VTEP %s (vni %d)", ni.Name, r.node, r.vtep, vx.VNI),
				Path: MulticastDestinationIndexPath(vx.Index, r.vtep, vx.VNI), Expect: ExpectNonZero,
				ReasonPath: MulticastDestinationNotProgrammedPath(vx.Index, r.vtep, vx.VNI), ReasonAbsent: true,
				ReasonCheck: CheckNotProgrammed},
			StateExpectation{Check: CheckRemoteVTEP,
				What: fmt.Sprintf("%s remote VTEP %s of %s", ni.Name, r.vtep, r.node),
				Path: VTEPIndexPath(r.vtep), Expect: ExpectNonZero,
				RouteEvidencePath: MulticastDestinationIndexPath(vx.Index, r.vtep, vx.VNI)})
	}
	return out, nil
}

type remoteVTEP struct{ node, vtep string }

// remoteVTEPs are the other nodes of this service carrying the same instance
// with the same vxlan-interface, each with its allocated system0.0 address.
func remoteVTEPs(m *model.ServiceModel, n *model.ServiceNode, ni *model.NetworkInstance, loopbacks map[string]string) ([]remoteVTEP, error) {
	var out []remoteVTEP
	for i := range m.Nodes {
		o := &m.Nodes[i]
		if o.Node == n.Node || !carries(o, ni.Name, ni.VXLANInterface) {
			continue
		}
		addr := vtepAddress(loopbacks[o.Node])
		if addr == "" {
			return nil, fmt.Errorf("verify service: no allocated system0.0 address for %s, the remote VTEP of %s on %s cannot be keyed",
				o.Node, ni.Name, n.Node)
		}
		out = append(out, remoteVTEP{node: o.Node, vtep: addr})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].node < out[j].node })
	return out, nil
}

// carries reports whether node o has instance name with vxlan-interface vx.
func carries(o *model.ServiceNode, name, vx string) bool {
	for _, ni := range o.NetworkInstances {
		if ni.Name == name && ni.VXLANInterface == vx {
			return true
		}
	}
	return false
}

// vtepAddress is the address of an allocated loopback, without a prefix length.
func vtepAddress(s string) string {
	s = strings.TrimSpace(s)
	if p, err := netip.ParsePrefix(s); err == nil {
		return p.Addr().String()
	}
	if a, err := netip.ParseAddr(s); err == nil {
		return a.String()
	}
	return s
}

// MulticastDestinationIndexPath is
// /tunnel-interface[name=vxlan0]/vxlan-interface[index=<i>]/bridge-table/multicast-destinations/destination[vtep=<vtep>][vni=<vni>]/destination-index.
func MulticastDestinationIndexPath(index uint32, vtep string, vni uint32) string {
	return fmt.Sprintf("%s/bridge-table/multicast-destinations/destination[vtep=%s][vni=%d]/destination-index", tunnelVXLANPath(index), vtep, vni)
}

// MulticastDestinationNotProgrammedPath is …/destination[vtep=<vtep>][vni=<vni>]/not-programmed-reason.
func MulticastDestinationNotProgrammedPath(index uint32, vtep string, vni uint32) string {
	return fmt.Sprintf("%s/bridge-table/multicast-destinations/destination[vtep=%s][vni=%d]/not-programmed-reason", tunnelVXLANPath(index), vtep, vni)
}

// VTEPIndexPath is /tunnel/vxlan-tunnel/vtep[address=<vtep>]/index.
func VTEPIndexPath(vtep string) string {
	return "/tunnel/vxlan-tunnel/vtep[address=" + vtep + "]/index"
}
