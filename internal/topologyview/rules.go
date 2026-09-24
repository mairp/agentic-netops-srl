package topologyview

import (
	"bytes"
	"fmt"

	yamlv3 "sigs.k8s.io/yaml/goyaml.v3"
)

// Recording-rule group and series names (data-model.md §21; the Phase 12 brief). FabricLinkDown
// joins interface_oper_state on(source, interface_name) with the fabric-link series, so it is
// scoped to fabric ports; EvpnRoutesLost and DeviceSubscriptionStalled select by node role.
const (
	RulesGroup       = "agentic-netops-topology"
	NodeInfoSeries   = "agentic_netops_node_info"
	FabricLinkSeries = "agentic_netops_fabric_link_info"
)

// Rules renders topology.yaml: one agentic_netops_node_info{source,role} per inventory node and
// one agentic_netops_fabric_link_info{source,interface_name,peer_source,peer_interface} per
// direction of every device↔device link, each `vector(1)` with its labels.
func Rules(inv *Inventory, provenance string) []byte {
	var b bytes.Buffer
	if provenance != "" {
		fmt.Fprintf(&b, "# %s\n", provenance)
	}
	fmt.Fprintf(&b, "groups:\n  - name: %s\n    rules:\n", RulesGroup)
	for _, n := range inv.Nodes {
		fmt.Fprintf(&b, "      - record: %s\n        expr: vector(1)\n        labels: {source: %q, role: %q}\n", NodeInfoSeries, n.Name, n.Role)
	}
	for _, l := range inv.FabricLinks() {
		fmt.Fprintf(&b, "      - record: %s\n        expr: vector(1)\n        labels: {source: %q, interface_name: %q, peer_source: %q, peer_interface: %q}\n",
			FabricLinkSeries, l.Source, l.Interface, l.PeerSource, l.PeerInterface)
	}
	return b.Bytes()
}

// RecordingRule is one parsed rule of a rules file.
type RecordingRule struct {
	Group, Record, Expr string
	Labels              map[string]string
}

// ParseRules reads a Prometheus rules file.
func ParseRules(b []byte) ([]RecordingRule, error) {
	var f struct {
		Groups []struct {
			Name  string `yaml:"name"`
			Rules []struct {
				Record string            `yaml:"record"`
				Alert  string            `yaml:"alert"`
				Expr   string            `yaml:"expr"`
				Labels map[string]string `yaml:"labels"`
			} `yaml:"rules"`
		} `yaml:"groups"`
	}
	if err := yamlv3.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("rules: %w", err)
	}
	var out []RecordingRule
	for _, g := range f.Groups {
		for _, r := range g.Rules {
			if r.Alert != "" {
				return nil, fmt.Errorf("rules: group %s carries alert %s (topology.yaml records only)", g.Name, r.Alert)
			}
			out = append(out, RecordingRule{Group: g.Name, Record: r.Record, Expr: r.Expr, Labels: r.Labels})
		}
	}
	return out, nil
}
