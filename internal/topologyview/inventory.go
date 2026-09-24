// Package topologyview generates the physical topology view from the containerlab inventory
// (T131; FR-094, FR-096, R-10; data-model.md §21): the gNMIc target list, the flow-panel SVG and
// panel YAML (from the pinned clab-io-draw's output over the same inventory), and the Prometheus
// recording rules carrying the topology info series — all from ONE parse of ONE inventory file, so
// node names, `source` labels, cell ids and the fabric-link set cannot drift apart.
//
// The join between telemetry and the view is exactly two labels: `source` (the containerlab node
// name, which is the gNMIc target name) and the normalized `interface_name` (`ethernet-1/49` →
// `e1-49`, NormalizeInterface; Prometheus rewrites the device label the same way at scrape of job
// `devices`). Nothing else is part of the join.
package topologyview

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/netip"
	"os"
	"regexp"
	"strings"

	yamlv3 "sigs.k8s.io/yaml/goyaml.v3"
)

// RoleLabel is the inventory label that states a node's role (lab/topology.clab.yml).
const RoleLabel = "agentic-netops.io/role"

// Roles of the view. Spines and leaves are the telemetry devices (gNMIc targets); clients are the
// Linux endpoints, drawn but never subscribed.
const (
	RoleSpine  = "spine"
	RoleLeaf   = "leaf"
	RoleClient = "client"
)

// Node is one inventory node.
type Node struct {
	Name string
	Kind string
	Role string
	// MgmtOffset is the node's host offset inside the management subnet, derived from its
	// mgmt-ipv4 relative to the inventory's mgmt ipv4-subnet (spines .11/.12, leaves .21/.22).
	MgmtOffset uint32
}

// Device reports whether the node is a telemetry device (a gNMIc target).
func (n Node) Device() bool { return n.Role == RoleSpine || n.Role == RoleLeaf }

// Endpoint is one side of an inventory link, the interface as the inventory names it.
type Endpoint struct {
	Node      string
	Interface string
}

// Link is one inventory link.
type Link struct{ A, B Endpoint }

// DirectedLink is one direction of a link with normalized interface names — the label set of
// agentic_netops_fabric_link_info.
type DirectedLink struct {
	Source, Interface, PeerSource, PeerInterface string
}

// Inventory is the parsed containerlab topology.
type Inventory struct {
	Name   string
	Prefix string // containerlab `prefix` (absent → "clab")
	Nodes  []Node
	Links  []Link
	// Digest is the sha256 of the inventory bytes this was parsed from.
	Digest string
}

type clabFile struct {
	Name   string  `yaml:"name"`
	Prefix *string `yaml:"prefix"`
	Mgmt   struct {
		IPv4Subnet string `yaml:"ipv4-subnet"`
	} `yaml:"mgmt"`
	Topology struct {
		Nodes yamlv3.Node `yaml:"nodes"`
		Links []struct {
			Endpoints []string `yaml:"endpoints"`
		} `yaml:"links"`
	} `yaml:"topology"`
}

type clabNode struct {
	Kind     string            `yaml:"kind"`
	MgmtIPv4 string            `yaml:"mgmt-ipv4"`
	Labels   map[string]string `yaml:"labels"`
}

// LoadInventory reads and parses a containerlab topology file.
func LoadInventory(path string) (*Inventory, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return ParseInventory(b)
}

// ParseInventory parses containerlab topology bytes. Node order is the file's order.
func ParseInventory(b []byte) (*Inventory, error) {
	var f clabFile
	if err := yamlv3.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("inventory: %w", err)
	}
	sum := sha256.Sum256(b)
	inv := &Inventory{Name: f.Name, Prefix: "clab", Digest: hex.EncodeToString(sum[:])}
	if f.Prefix != nil {
		inv.Prefix = *f.Prefix
	}
	if inv.Name == "" {
		return nil, fmt.Errorf("inventory: no lab name")
	}
	subnet, err := netip.ParsePrefix(expandDefaults(f.Mgmt.IPv4Subnet))
	if err != nil || !subnet.Addr().Is4() {
		return nil, fmt.Errorf("inventory: mgmt ipv4-subnet %q is not an IPv4 prefix", f.Mgmt.IPv4Subnet)
	}
	subnet = subnet.Masked()
	if f.Topology.Nodes.Kind != yamlv3.MappingNode {
		return nil, fmt.Errorf("inventory: topology.nodes is not a mapping")
	}
	seen := map[string]bool{}
	for i := 0; i+1 < len(f.Topology.Nodes.Content); i += 2 {
		name := f.Topology.Nodes.Content[i].Value
		var cn clabNode
		if err := f.Topology.Nodes.Content[i+1].Decode(&cn); err != nil {
			return nil, fmt.Errorf("inventory: node %s: %w", name, err)
		}
		role, err := roleOf(name, cn)
		if err != nil {
			return nil, err
		}
		off, err := mgmtOffset(name, cn.MgmtIPv4, subnet)
		if err != nil {
			return nil, err
		}
		inv.Nodes = append(inv.Nodes, Node{Name: name, Kind: cn.Kind, Role: role, MgmtOffset: off})
		seen[name] = true
	}
	for i, l := range f.Topology.Links {
		if len(l.Endpoints) != 2 {
			return nil, fmt.Errorf("inventory: link %d has %d endpoints, want 2", i, len(l.Endpoints))
		}
		var eps [2]Endpoint
		for j, e := range l.Endpoints {
			node, iface, ok := strings.Cut(e, ":")
			if !ok || !seen[node] || iface == "" {
				return nil, fmt.Errorf("inventory: link %d endpoint %q is not <known node>:<interface>", i, e)
			}
			eps[j] = Endpoint{Node: node, Interface: iface}
		}
		inv.Links = append(inv.Links, Link{A: eps[0], B: eps[1]})
	}
	return inv, nil
}

// roleOf takes the role from the inventory's role label, else from the name (spine*/leaf*) or the
// kind (linux → client). An SR Linux node whose role cannot be told is an error, never a guess.
func roleOf(name string, n clabNode) (string, error) {
	role := n.Labels[RoleLabel]
	if role == "" {
		switch {
		case strings.HasPrefix(name, RoleSpine):
			role = RoleSpine
		case strings.HasPrefix(name, RoleLeaf):
			role = RoleLeaf
		case n.Kind == "linux":
			role = RoleClient
		}
	}
	switch role {
	case RoleSpine, RoleLeaf:
		if n.Kind != "nokia_srlinux" {
			return "", fmt.Errorf("inventory: node %s has role %s but kind %q (want nokia_srlinux)", name, role, n.Kind)
		}
	case RoleClient:
	default:
		return "", fmt.Errorf("inventory: node %s (kind %q) has no role spine|leaf|client", name, n.Kind)
	}
	return role, nil
}

// ${VAR:=default}, ${VAR:-default} → default; containerlab expands them the same way when the
// variable is unset. The host offset is what matters here, and it is independent of the prefix.
var envRef = regexp.MustCompile(`\$\{[A-Za-z_][A-Za-z0-9_]*(?::[=-]([^}]*))?\}`)

func expandDefaults(s string) string {
	return envRef.ReplaceAllStringFunc(s, func(m string) string {
		return envRef.FindStringSubmatch(m)[1]
	})
}

func mgmtOffset(name, raw string, subnet netip.Prefix) (uint32, error) {
	if raw == "" {
		return 0, fmt.Errorf("inventory: node %s has no mgmt-ipv4", name)
	}
	a, err := netip.ParseAddr(expandDefaults(raw))
	if err != nil || !a.Is4() || !subnet.Contains(a) {
		return 0, fmt.Errorf("inventory: node %s mgmt-ipv4 %q is not an IPv4 address of %s", name, raw, subnet)
	}
	return ip4(a) - ip4(subnet.Addr()), nil
}

func ip4(a netip.Addr) uint32 {
	b := a.As4()
	return uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
}

// Node returns the named node.
func (inv *Inventory) Node(name string) (Node, bool) {
	for _, n := range inv.Nodes {
		if n.Name == name {
			return n, true
		}
	}
	return Node{}, false
}

// Devices returns the telemetry devices (spines and leaves) in inventory order.
func (inv *Inventory) Devices() []Node {
	var out []Node
	for _, n := range inv.Nodes {
		if n.Device() {
			out = append(out, n)
		}
	}
	return out
}

// IsDevice reports whether name is a telemetry device of the inventory.
func (inv *Inventory) IsDevice(name string) bool {
	n, ok := inv.Node(name)
	return ok && n.Device()
}

// FabricLinks returns every device↔device link once per direction, normalized, in inventory order
// (A→B, then B→A). Client links are not fabric links.
func (inv *Inventory) FabricLinks() []DirectedLink {
	var out []DirectedLink
	for _, l := range inv.Links {
		if !inv.IsDevice(l.A.Node) || !inv.IsDevice(l.B.Node) {
			continue
		}
		out = append(out, directed(l.A, l.B), directed(l.B, l.A))
	}
	return out
}

// AllDirectedLinks returns every inventory link (client links included) once per direction.
func (inv *Inventory) AllDirectedLinks() []DirectedLink {
	var out []DirectedLink
	for _, l := range inv.Links {
		out = append(out, directed(l.A, l.B), directed(l.B, l.A))
	}
	return out
}

func directed(a, b Endpoint) DirectedLink {
	return DirectedLink{Source: a.Node, Interface: NormalizeInterface(a.Interface), PeerSource: b.Node, PeerInterface: NormalizeInterface(b.Interface)}
}

// CellKey is the flow-panel/SVG cell key of the link's port on Source: <src>:<if>:<peer>:<peerif>.
func (d DirectedLink) CellKey() string {
	return d.Source + ":" + d.Interface + ":" + d.PeerSource + ":" + d.PeerInterface
}

// drawioMarker is the node-name decoration clab-io-draw 0.7.1 puts on every id
// (NodeLinkBuilder.format_node_name: "<prefix>-<lab>-<node>", nothing when prefix is ""). It is
// the containerlab container name, not the node name the devices report as `source`.
func (inv *Inventory) drawioMarker() string {
	if inv.Prefix == "" {
		return ""
	}
	return inv.Prefix + "-" + inv.Name + "-"
}
