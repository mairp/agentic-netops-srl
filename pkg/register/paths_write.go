package register

import (
	"errors"
	"fmt"

	"github.com/mairp/agentic-netops-srl/internal/model"
)

// Construct groups used by the write register.
var (
	fabric   = []string{"fabric"}
	l2svc    = []string{"vlan", "mac-vrf", "ip-vrf"} // constructs that own a subinterface
	overlay  = []string{"mac-vrf", "ip-vrf"}         // constructs with a VXLAN overlay
	gateway  = []string{"mac-vrf"}                   // the anycast gateway of a mac-vrf
	anyACL   = []string{"vlan", "mac-vrf", "ip-vrf", "acl"}
	fabOnly  = []Owner{OwnerFabric}
	svcOnly  = []Owner{OwnerService}
	fabAndSv = []Owner{OwnerFabric, OwnerService}
)

func w(path string, owners []Owner, constructs ...[]string) WriteEntry {
	var cs []string
	for _, c := range constructs {
		cs = append(cs, c...)
	}
	return WriteEntry{Path: path, Model: Native, Owners: owners, Constructs: cs}
}

// WriteEntries is the write side of the register: every schema node a
// generated Config writes, native srl_nokia throughout (no exception today).
// T039 (fabric) and T057 (services) add an entry here with every new path.
func WriteEntries() []WriteEntry {
	return []WriteEntry{
		// --- interfaces: port-level leaves (fabric only, AD-68) ---
		w("/interface[name=*]/admin-state", fabOnly, fabric),
		w("/interface[name=*]/mtu", fabOnly, fabric),
		w("/interface[name=*]/vlan-tagging", fabOnly, fabric),
		// --- subinterfaces ---
		w("/interface[name=*]/subinterface[index=*]/admin-state", fabAndSv, fabric, l2svc),
		w("/interface[name=*]/subinterface[index=*]/type", svcOnly, l2svc),
		w("/interface[name=*]/subinterface[index=*]/vlan/encap/single-tagged/vlan-id", svcOnly, l2svc),
		w("/interface[name=*]/subinterface[index=*]/ip-mtu", fabAndSv, fabric, gateway),
		w("/interface[name=*]/subinterface[index=*]/ipv4/admin-state", fabAndSv, fabric, overlay),
		w("/interface[name=*]/subinterface[index=*]/ipv4/address[ip-prefix=*]", fabAndSv, fabric, []string{"ip-vrf"}),
		// the model default stated: the validator evaluates the address's unnumbered must
		// against the absent node (internal/render/srl/interfaces.go addressFamilies)
		w("/interface[name=*]/subinterface[index=*]/ipv4/unnumbered/admin-state", fabOnly, fabric),
		w("/interface[name=*]/subinterface[index=*]/ipv6/admin-state", fabAndSv, fabric, overlay),
		w("/interface[name=*]/subinterface[index=*]/ipv6/address[ip-prefix=*]", fabAndSv, fabric, []string{"ip-vrf"}),
		// --- irb0 anycast gateway ---
		w("/interface[name=*]/subinterface[index=*]/anycast-gw/virtual-router-id", svcOnly, gateway),
		w("/interface[name=*]/subinterface[index=*]/ipv4/address[ip-prefix=*]/anycast-gw", svcOnly, gateway),
		w("/interface[name=*]/subinterface[index=*]/ipv4/address[ip-prefix=*]/primary", svcOnly, gateway),
		w("/interface[name=*]/subinterface[index=*]/ipv4/arp/learn-unsolicited", svcOnly, gateway),
		w("/interface[name=*]/subinterface[index=*]/ipv4/arp/host-route/populate[route-type=*]", svcOnly, gateway),
		w("/interface[name=*]/subinterface[index=*]/ipv4/arp/evpn/advertise[route-type=*]", svcOnly, gateway),
		w("/interface[name=*]/subinterface[index=*]/ipv6/address[ip-prefix=*]/anycast-gw", svcOnly, gateway),
		w("/interface[name=*]/subinterface[index=*]/ipv6/neighbor-discovery/learn-unsolicited", svcOnly, gateway),
		w("/interface[name=*]/subinterface[index=*]/ipv6/neighbor-discovery/host-route/populate[route-type=*]", svcOnly, gateway),
		w("/interface[name=*]/subinterface[index=*]/ipv6/neighbor-discovery/evpn/advertise[route-type=*]", svcOnly, gateway),
		// --- tunnel interface ---
		// The tunnel-interface entry itself (vxlan0, leaves only) is the
		// fabric's; every vxlan-interface beneath it is a service's.
		w("/tunnel-interface[name=*]", fabOnly, fabric),
		w("/tunnel-interface[name=*]/vxlan-interface[index=*]/type", svcOnly, overlay),
		w("/tunnel-interface[name=*]/vxlan-interface[index=*]/ingress/vni", svcOnly, overlay),
		w("/tunnel-interface[name=*]/vxlan-interface[index=*]/egress/source-ip", svcOnly, gateway),
		// --- network instances ---
		w("/network-instance[name=*]/type", fabAndSv, fabric, l2svc),
		w("/network-instance[name=*]/admin-state", fabAndSv, fabric, l2svc),
		w("/network-instance[name=*]/description", svcOnly, l2svc),
		w("/network-instance[name=*]/interface[name=*]", fabAndSv, fabric, l2svc),
		w("/network-instance[name=*]/vxlan-interface[name=*]", svcOnly, overlay),
		w("/network-instance[name=*]/bridge-table/protect-anycast-gw-mac", svcOnly, gateway),
		w("/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/admin-state", svcOnly, overlay),
		w("/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/encapsulation-type", svcOnly, overlay),
		w("/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/vxlan-interface", svcOnly, overlay),
		w("/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/evi", svcOnly, overlay),
		w("/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/ecmp", svcOnly, overlay),
		w("/network-instance[name=*]/protocols/bgp-vpn/bgp-instance[id=*]/route-target/export-rt", svcOnly, overlay),
		w("/network-instance[name=*]/protocols/bgp-vpn/bgp-instance[id=*]/route-target/import-rt", svcOnly, overlay),
		// --- underlay / overlay BGP (fabric) ---
		w("/network-instance[name=*]/protocols/bgp/admin-state", fabOnly, fabric),
		w("/network-instance[name=*]/protocols/bgp/autonomous-system", fabOnly, fabric),
		w("/network-instance[name=*]/protocols/bgp/router-id", fabOnly, fabric),
		w("/network-instance[name=*]/protocols/bgp/afi-safi[afi-safi-name=*]/admin-state", fabOnly, fabric),
		w("/network-instance[name=*]/protocols/bgp/afi-safi[afi-safi-name=*]/evpn/inter-as-vpn", fabOnly, fabric),
		w("/network-instance[name=*]/protocols/bgp/group[group-name=*]/export-policy", fabOnly, fabric),
		w("/network-instance[name=*]/protocols/bgp/group[group-name=*]/import-policy", fabOnly, fabric),
		w("/network-instance[name=*]/protocols/bgp/group[group-name=*]/peer-as", fabOnly, fabric),
		w("/network-instance[name=*]/protocols/bgp/group[group-name=*]/local-as/as-number", fabOnly, fabric),
		w("/network-instance[name=*]/protocols/bgp/group[group-name=*]/afi-safi[afi-safi-name=*]/admin-state", fabOnly, fabric),
		w("/network-instance[name=*]/protocols/bgp/group[group-name=*]/route-reflector/client", fabOnly, fabric),
		w("/network-instance[name=*]/protocols/bgp/group[group-name=*]/as-path-options/allow-own-as", fabOnly, fabric),
		w("/network-instance[name=*]/protocols/bgp/neighbor[peer-address=*]/peer-group", fabOnly, fabric),
		w("/network-instance[name=*]/protocols/bgp/neighbor[peer-address=*]/peer-as", fabOnly, fabric),
		w("/network-instance[name=*]/protocols/bgp/neighbor[peer-address=*]/transport/local-address", fabOnly, fabric),
		// --- routing policy (fabric) ---
		w("/routing-policy/prefix-set[name=*]/prefix[ip-prefix=*][mask-length-range=*]", fabOnly, fabric),
		w("/routing-policy/policy[name=*]/statement[name=*]/match/prefix/prefix-set", fabOnly, fabric),
		w("/routing-policy/policy[name=*]/statement[name=*]/action/policy-result", fabOnly, fabric),
		// --- access lists ---
		w("/acl/acl-filter[name=*][type=*]/description", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/statistics-per-entry", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/subinterface-specific", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/description", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/action/accept", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/action/drop", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/match/ipv4/protocol", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/match/ipv4/source-ip/prefix", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/match/ipv4/destination-ip/prefix", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/match/ipv6/next-header", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/match/ipv6/source-ip/prefix", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/match/ipv6/destination-ip/prefix", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/match/transport/source-port/operator", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/match/transport/source-port/value", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/match/transport/source-port/range/start", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/match/transport/source-port/range/end", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/match/transport/destination-port/operator", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/match/transport/destination-port/value", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/match/transport/destination-port/range/start", svcOnly, anyACL),
		w("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/match/transport/destination-port/range/end", svcOnly, anyACL),
		w("/acl/interface[interface-id=*]/interface-ref/interface", svcOnly, l2svc),
		w("/acl/interface[interface-id=*]/interface-ref/subinterface", svcOnly, l2svc),
		w("/acl/interface[interface-id=*]/input/acl-filter[name=*][type=*]", svcOnly, anyACL),
		w("/acl/interface[interface-id=*]/output/acl-filter[name=*][type=*]", svcOnly, anyACL),
	}
}

// CheckFabric runs every node of a fabric model through the register: the
// fabric renderer (T039) calls it before emitting a Config, and the guard
// drives it over representative designs.
func CheckFabric(m *model.FabricModel) error {
	var errs []error
	for i := range m.Nodes {
		if err := checkOwned(m.Nodes[i].WritePaths(), OwnerFabric); err != nil {
			errs = append(errs, fmt.Errorf("fabric node %s: %w", m.Nodes[i].Name, err))
		}
	}
	return errors.Join(errs...)
}

// CheckFabricPaths checks the concrete leaf paths a fabric render actually
// emits (extracted from the rendered document, not from the model) against
// the entries the fabric Config may write. The fabric renderer (T039) calls it
// on every node before returning a document (Rendered=False/RegisterUncovered).
func CheckFabricPaths(node string, paths []string) error {
	if err := checkOwned(paths, OwnerFabric); err != nil {
		return fmt.Errorf("fabric node %s: %w", node, err)
	}
	return nil
}

// CheckService runs every node of a service model through the register: the
// service renderers (T057) call it before emitting, and the guard drives it
// over a representative service of every construct.
func CheckService(m *model.ServiceModel) error {
	var errs []error
	for i := range m.Nodes {
		if err := checkOwned(m.Nodes[i].WritePaths(), OwnerService); err != nil {
			errs = append(errs, fmt.Errorf("service node %s: %w", m.Nodes[i].Node, err))
		}
	}
	return errors.Join(errs...)
}

// checkOwned is CheckWrite restricted to the entries owner may write, so a
// service render reaching a fabric-owned leaf is uncovered too (AD-68).
func checkOwned(paths []string, owner Owner) error {
	var entries []WriteEntry
	for _, e := range WriteEntries() {
		for _, o := range e.Owners {
			if o == owner {
				entries = append(entries, e)
				break
			}
		}
	}
	err := checkWriteAgainst(paths, entries)
	var ue *UncoveredError
	if errors.As(err, &ue) {
		ue.Kind = string(owner) + " write"
	}
	return err
}
