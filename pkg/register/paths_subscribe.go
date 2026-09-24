package register

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/mairp/agentic-netops-srl/internal/telemetry"
)

// SubscribeEntry registers one subscribed path (FR-089). Path is the exact
// subscription path, list keys included (a fixed key value such as
// `cpu[index=all]` is part of it).
type SubscribeEntry struct {
	Path  string
	Model Model
	// Justification is required, and only allowed, when Model is not Native.
	Justification string
	// Subscription is the gNMIc subscription name that carries the path.
	Subscription string
	// Mode and SampleInterval are the stream mode (sample by default; on-change
	// only where acceptance item G7 covers it — none today).
	Mode           telemetry.StreamMode
	SampleInterval time.Duration
	// Metric is the derived metric name (evidence/06 §1.3: key-stripped value
	// path, `/` and `-` to `_`, no leading underscore, no prefix). For a
	// container path it is the prefix of every leaf metric beneath it.
	Metric string
	// Labels are the derived label names: `<element>_<key>` per list key in
	// path order (evidence/06 §1.4, sanitized), then `source` and
	// `subscription_name`.
	Labels []string
}

const (
	fast = 5 * time.Second
	slow = 10 * time.Second
)

func sub(name string, iv time.Duration, path, metric string, labels ...string) SubscribeEntry {
	return SubscribeEntry{Path: path, Model: Native, Subscription: name, Mode: telemetry.Sample,
		SampleInterval: iv, Metric: metric, Labels: append(labels, "source", "subscription_name")}
}

// SubscribeEntries is the subscription side of the register. T128 completes it
// against the pinned YANG tag and generates the gNMIc configuration from it.
func SubscribeEntries() []SubscribeEntry {
	return []SubscribeEntry{
		sub("srl-if-state", fast, "/interface[name=*]/admin-state", "interface_admin_state", "interface_name"),
		sub("srl-if-state", fast, "/interface[name=*]/oper-state", "interface_oper_state", "interface_name"),
		sub("srl-if-rate", fast, "/interface[name=*]/traffic-rate", "interface_traffic_rate", "interface_name"),
		sub("srl-if-stats", slow, "/interface[name=*]/statistics", "interface_statistics", "interface_name"),
		sub("srl-subif-stats", slow, "/interface[name=*]/subinterface[index=*]/statistics", "interface_subinterface_statistics", "interface_name", "subinterface_index"),
		sub("srl-subif-stats", slow, "/interface[name=*]/subinterface[index=*]/oper-state", "interface_subinterface_oper_state", "interface_name", "subinterface_index"),
		sub("srl-bgp-neighbor", fast, "/network-instance[name=*]/protocols/bgp/neighbor[peer-address=*]/session-state",
			"network_instance_protocols_bgp_neighbor_session_state", "network_instance_name", "neighbor_peer_address"),
		sub("srl-bgp-afisafi", slow, "/network-instance[name=*]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=*]/received-routes",
			"network_instance_protocols_bgp_neighbor_afi_safi_received_routes", "network_instance_name", "neighbor_peer_address", "afi_safi_afi_safi_name"),
		sub("srl-bgp-afisafi", slow, "/network-instance[name=*]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=*]/active-routes",
			"network_instance_protocols_bgp_neighbor_afi_safi_active_routes", "network_instance_name", "neighbor_peer_address", "afi_safi_afi_safi_name"),
		sub("srl-net-instance", fast, "/network-instance[name=*]/oper-state", "network_instance_oper_state", "network_instance_name"),
		sub("srl-bgp-evpn", slow, "/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/oper-state",
			"network_instance_protocols_bgp_evpn_bgp_instance_oper_state", "network_instance_name", "bgp_instance_id"),
		sub("srl-vxlan", slow, "/tunnel/vxlan-tunnel/vtep[address=*]/statistics", "tunnel_vxlan_tunnel_vtep_statistics", "vtep_address"),
		sub("srl-vxlan", slow, "/tunnel-interface[name=*]/vxlan-interface[index=*]/oper-state",
			"tunnel_interface_vxlan_interface_oper_state", "tunnel_interface_name", "vxlan_interface_index"),
		sub("srl-bridge-table", slow, "/network-instance[name=*]/bridge-table/statistics", "network_instance_bridge_table_statistics", "network_instance_name"),
		sub("srl-route-table", slow, "/network-instance[name=*]/route-table/ipv4-unicast/statistics",
			"network_instance_route_table_ipv4_unicast_statistics", "network_instance_name"),
		sub("srl-route-table", slow, "/network-instance[name=*]/route-table/ipv6-unicast/statistics",
			"network_instance_route_table_ipv6_unicast_statistics", "network_instance_name"),
		sub("srl-route-table", slow, "/network-instance[name=*]/tunnel-table/ipv4/statistics",
			"network_instance_tunnel_table_ipv4_statistics", "network_instance_name"),
		// the access-list read-back (T108): matched-packets / incomplete (A5),
		// the per-entry TCAM cost by direction (A1–A3) and the programming gate (G1)
		sub("srl-acl", slow, "/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/statistics",
			"acl_acl_filter_entry_statistics", "acl_filter_name", "acl_filter_type", "entry_sequence_id"),
		sub("srl-acl", slow, "/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/tcam-entries",
			"acl_acl_filter_entry_tcam_entries", "acl_filter_name", "acl_filter_type", "entry_sequence_id"),
		sub("srl-acl", slow, "/acl/datapath-programming", "acl_datapath_programming"),
		sub("srl-platform", slow, "/platform/control[slot=*]/cpu[index=all]/total", "platform_control_cpu_total", "control_slot", "cpu_index"),
		sub("srl-platform", slow, "/platform/control[slot=*]/memory", "platform_control_memory", "control_slot"),
		sub("srl-apps", slow, "/system/app-management/application[name=*]/state", "system_app_management_application_state", "application_name"),
	}
}

// DeriveMetricName is the metric name the pipeline derives from a subscribed
// path: list keys stripped, the leading `/` dropped, `/` and `-` to `_`.
func DeriveMetricName(path string) string {
	var b strings.Builder
	depth := 0
	for _, r := range strings.TrimPrefix(path, "/") {
		switch {
		case r == '[':
			depth++
		case r == ']':
			depth--
		case depth > 0:
		case r == '/' || r == '-':
			b.WriteByte('_')
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// DeriveLabels is the label-name list the pipeline derives from a subscribed
// path: `<element>_<key>` per key, sanitized, then `source` and `subscription_name`.
func DeriveLabels(path string) []string {
	var out []string
	for _, el := range splitElems(path) {
		name := el
		i := strings.IndexByte(el, '[')
		if i < 0 {
			continue
		}
		name = el[:i]
		rest := el[i:]
		for len(rest) > 0 && rest[0] == '[' {
			end := strings.IndexByte(rest, ']')
			kv := rest[1:end]
			k := kv
			if eq := strings.IndexByte(kv, '='); eq >= 0 {
				k = kv[:eq]
			}
			out = append(out, sanitize(name+"_"+k))
			rest = rest[end+1:]
		}
	}
	return append(out, "source", "subscription_name")
}

func sanitize(s string) string { return strings.NewReplacer("-", "_", ":", "_").Replace(s) }

// splitElems splits a path on `/` outside brackets.
func splitElems(path string) []string {
	var out []string
	depth, start := 0, 0
	p := strings.TrimPrefix(path, "/")
	for i := 0; i < len(p); i++ {
		switch p[i] {
		case '[':
			depth++
		case ']':
			depth--
		case '/':
			if depth == 0 {
				out = append(out, p[start:i])
				start = i + 1
			}
		}
	}
	return append(out, p[start:])
}

// CheckSubscriptions returns an *UncoveredError naming every subscribed path of
// subs that the register does not carry under the same subscription name,
// stream mode and sample interval. gNMIc configuration generation (T128) and
// the guard call it on telemetry.Subscriptions().
func CheckSubscriptions(subs []telemetry.Subscription) error {
	return checkSubscriptionsAgainst(subs, SubscribeEntries())
}

func checkSubscriptionsAgainst(subs []telemetry.Subscription, entries []SubscribeEntry) error {
	reg := make(map[string]SubscribeEntry, len(entries))
	for _, e := range entries {
		reg[e.Path] = e
	}
	var bad []string
	for _, s := range subs {
		for _, p := range s.Paths {
			e, ok := reg[p]
			switch {
			case !ok:
				bad = append(bad, p)
			case e.Subscription != s.Name || e.Mode != s.Mode || e.SampleInterval != s.SampleInterval:
				bad = append(bad, fmt.Sprintf("%s (registered %s/%s/%s, emitted %s/%s/%s)", p,
					e.Subscription, e.Mode, e.SampleInterval, s.Name, s.Mode, s.SampleInterval))
			}
		}
	}
	if len(bad) > 0 {
		sort.Strings(bad)
		return &UncoveredError{Kind: "subscribe", Paths: bad}
	}
	return nil
}
