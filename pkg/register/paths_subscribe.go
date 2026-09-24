package register

// The subscription side of the path register (T022, completed by T128; FR-017,
// FR-089, R-09, data-model.md §21). It is the ONE statement of what the
// in-cluster gNMIc subscribes to: internal/telemetry generates
// deploy/observability/gnmic/subscriptions.yaml from SubscribeEntries, and
// scripts/lib/device_metrics.sh renders the deployed gNMIc configuration from
// that file — so the register, the collector and the provider's read-back
// (internal/verify/collector.go, which reads device state from the collector)
// cannot drift.
//
// Every entry is re-validated against the PINNED YANG models
// (versions.lock.yaml part 2, nokia/srlinux-yang-models v25.7.1): the committed
// index testdata/yang-index-v25.7.1.json, written by `go run ./hack/yangindex`
// from a checkout of that commit, carries the schema nodes each path reaches,
// and the guard derives from it the metric name and the label set recorded here
// (subscribe_guard_test.go).

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

// StreamMode is a gNMI subscription stream mode.
type StreamMode string

const (
	// Sample is the default (data-model.md §21).
	Sample StreamMode = "sample"
	// OnChange is used only where an acceptance check (gate item G7) covers it.
	// G7 observed sampled streams only (tests/gate/observed/telemetry-series.json,
	// "stream/sample"), so no entry uses it today.
	OnChange StreamMode = "on-change"
)

// Bound says why a label's cardinality is bounded (R-09; data-model.md §21:
// "Service identifiers are allowed only where cardinality is bounded by the
// reference lab"). The set is closed: a label carries exactly one of these, and
// the guard refuses any other value, a path-derived label without one, and a
// lab bound that cannot justify the label's key type (boundAdmits).
type Bound string

const (
	// BoundSchema — the key's YANG type is closed (enumeration, identityref,
	// boolean) or the path fixes its value (`[name=default]`, `[index=all]`).
	// The guard checks the claim against the YANG index.
	BoundSchema Bound = "schema"
	// BoundPipeline — a label the pipeline adds, not the path: `source` (the
	// gNMIc target name, one per node) and `subscription_name` (the register's
	// own subscription names).
	BoundPipeline Bound = "pipeline"
	// BoundInventory — one value per port, slot, forwarding complex or
	// application of a reference-lab node: fixed by the containerlab topology and
	// the pinned SR Linux image, never by traffic or intent.
	BoundInventory Bound = "lab-inventory"
	// BoundIntent — one value per object the platform renders from the
	// reference lab's declared Fabric and Network intent (network-instances,
	// subinterfaces, EVPN / BGP-VPN instances, vxlan-interfaces, ACL filters and
	// entries, interface addresses).
	BoundIntent Bound = "declared-intent"
	// BoundFabricPeers — one value per BGP neighbour, VTEP or VNI of the
	// reference lab's fabric (its loopbacks, link addresses and declared VNIs).
	BoundFabricPeers Bound = "fabric-peers"
	// BoundLabRoutes — one value per route of the reference lab: every prefix,
	// route distinguisher, path and owner is a fabric address or a declared
	// service's subnet; the lab has no external route feed. It is the only bound
	// that admits a route-table or RIB key.
	BoundLabRoutes Bound = "lab-routes"
)

// Bounds is the closed set of label bounds.
var Bounds = []Bound{BoundSchema, BoundPipeline, BoundInventory, BoundIntent, BoundFabricPeers, BoundLabRoutes}

// Label is one label of a subscribed path's series with the reason its value
// set is bounded.
type Label struct {
	Name  string
	Bound Bound
}

// PipelineLabels are the labels every device series carries beside the
// path-derived ones: gNMIc's `source` and `subscription-name` tags
// (evidence/06 §1.4). The collector adds `otel_scope_{name,version,schema_url}`
// (gNMIc's instrumentation scope, three constants) — not path labels.
var PipelineLabels = []Label{{"source", BoundPipeline}, {"subscription_name", BoundPipeline}}

// ScopeLabels are the collector's instrumentation-scope labels (constant per
// gNMIc build) that the Prometheus exporter adds to every series.
var ScopeLabels = []string{"otel_scope_name", "otel_scope_schema_url", "otel_scope_version"}

// SubscribeEntry registers one subscribed path (FR-089). Path is the exact
// subscription path, list keys as written in the subscription (a fixed value
// such as `cpu[index=all]` is part of it; a list the path names without keys,
// `route`, is wildcarded by gNMI and still yields its key labels).
type SubscribeEntry struct {
	Path  string
	Model Model
	// Justification is required, and only allowed, when Model is not Native.
	Justification string
	// Subscription is the gNMIc subscription (one Subscribe stream per target)
	// that carries the path.
	Subscription string
	// Mode and SampleInterval are the stream mode (sample by default; on-change
	// only where acceptance item G7 covers it — none today) and its interval.
	Mode           StreamMode
	SampleInterval time.Duration
	// Metric is the exported series name: the path's schema elements, each
	// qualified with its YANG module where the module differs from its
	// parent's (RFC 7951 §4, JSON_IETF) — the value path gNMIc's OTLP output
	// names the metric after — `/` and `-` to `_`, no leading underscore, no
	// prefix, `:` kept by the collector's UnderscoreEscapingWithoutSuffixes
	// (G7; evidence/06 §1.3). For a container path it is the prefix of every
	// leaf beneath (`<Metric>_<leaf>`, the leaf qualified only if it crosses a
	// module boundary).
	Metric string
	// Labels is the closed label set, in order: `<list>_<key>` for every list on
	// the schema path, its keys in YANG order (evidence/06 §1.4, `-` to `_`),
	// then PipelineLabels.
	Labels []Label
	// ReadBack marks a path the provider's read-back (internal/verify) reads
	// from the collector: removing it breaks Fabric/Network readiness, and it is
	// sampled every 5 s because the collector's metric_expiration (20 s, four
	// intervals) is the read-back's freshness bound.
	ReadBack bool
}

// LabelNames returns the entry's label names in order.
func (e SubscribeEntry) LabelNames() []string {
	out := make([]string, 0, len(e.Labels))
	for _, l := range e.Labels {
		out = append(out, l.Name)
	}
	return out
}

// The three subscriptions — three gNMI Subscribe streams per target, the most
// the device's gRPC session budget grants the collector beside the
// device-configuration layer (evidence/06 §2.4, FR-086).
const (
	// SubState is the read-back's state set plus FR-089's link and session
	// state, every 5 s. Its name is the one deployed since AD-82, so the live
	// series keep their subscription_name.
	SubState = "device-state"
	// SubCounters is FR-089's counters and summaries, every 10 s.
	SubCounters = "device-counters"
	// SubHealth is FR-089's platform CPU, memory and application health, every 10 s.
	SubHealth = "device-health"
	// MaxSubscriptions is the per-target Subscribe stream budget.
	MaxSubscriptions = 3
)

const (
	fast = 5 * time.Second
	slow = 10 * time.Second
)

// label constructors, one per bound
func sch(n string) Label { return Label{n, BoundSchema} }
func inv(n string) Label { return Label{n, BoundInventory} }
func dcl(n string) Label { return Label{n, BoundIntent} }
func pee(n string) Label { return Label{n, BoundFabricPeers} }
func rte(n string) Label { return Label{n, BoundLabRoutes} }

func entry(sub string, iv time.Duration, readBack bool, path, metric string, labels ...Label) SubscribeEntry {
	return SubscribeEntry{Path: path, Model: Native, Subscription: sub, Mode: Sample, SampleInterval: iv,
		Metric: metric, Labels: append(labels, PipelineLabels...), ReadBack: readBack}
}

// rb is a read-back path of the state subscription; st an FR-089 state path
// of it; ct a counter path; hl a health path.
func rb(path, metric string, labels ...Label) SubscribeEntry {
	return entry(SubState, fast, true, path, metric, labels...)
}
func st(path, metric string, labels ...Label) SubscribeEntry {
	return entry(SubState, fast, false, path, metric, labels...)
}
func ct(path, metric string, labels ...Label) SubscribeEntry {
	return entry(SubCounters, slow, false, path, metric, labels...)
}
func hl(path, metric string, labels ...Label) SubscribeEntry {
	return entry(SubHealth, slow, false, path, metric, labels...)
}

// the module qualifiers of the exported names
const (
	qIf   = "srl_nokia_interfaces:"
	qNI   = "srl_nokia_network_instance:"
	qBGP  = "srl_nokia_network_instance:network_instance_protocols_srl_nokia_bgp:bgp_neighbor"
	qACL  = "srl_nokia_acl:acl_acl_filter_entry"
	qTIf  = "srl_nokia_tunnel_interfaces:tunnel_interface_vxlan_interface"
	qBVPN = "srl_nokia_network_instance:network_instance_protocols_srl_nokia_bgp_vpn:bgp_vpn_bgp_instance"
	qEVPN = "srl_nokia_network_instance:network_instance_protocols_bgp_evpn_srl_nokia_bgp_evpn:bgp_instance"
	qMcd  = qTIf + "_bridge_table_srl_nokia_tunnel_interfaces_vxlan_interface_bridge_table_multicast_destinations:multicast_destinations_destination"
)

// SubscribeEntries is the subscription side of the register: the union of
// FR-089's path set and every path the provider's read-back depends on, native
// srl_nokia throughout (no exception today), sampled throughout.
func SubscribeEntries() []SubscribeEntry {
	ifn, sub := inv("interface_name"), dcl("subinterface_index")
	ni, niDefault := dcl("network_instance_name"), sch("network_instance_name")
	peer, afi := pee("neighbor_peer_address"), sch("afi_safi_afi_safi_name")
	aclKeys := []Label{dcl("acl_filter_name"), sch("acl_filter_type"), dcl("entry_sequence_id")}
	acl := func(ls ...Label) []Label { return append(append([]Label(nil), aclKeys...), ls...) }
	tif, vxi := dcl("tunnel_interface_name"), dcl("vxlan_interface_index")
	mcast := []Label{tif, vxi, pee("destination_vtep"), pee("destination_vni")}
	route := func(fam string) []Label {
		return []Label{ni, rte("route_" + fam + "_prefix"), sch("route_route_type"), rte("route_route_owner"),
			rte("route_id"), dcl("route_origin_network_instance")}
	}
	return []SubscribeEntry{
		// ---- device-state (5 s): the read-back (T039/T058/T108/T116, internal/verify) ----
		// the Fabric read-back's applied-side leaves and the services' own objects,
		// with the device's down reasons
		rb("/interface[name=*]/oper-state", qIf+"interface_oper_state", ifn),
		rb("/interface[name=*]/subinterface[index=*]/oper-state", qIf+"interface_subinterface_oper_state", ifn, sub),
		rb("/interface[name=*]/subinterface[index=*]/oper-down-reason", qIf+"interface_subinterface_oper_down_reason", ifn, sub),
		rb("/tunnel-interface[name=*]/vxlan-interface[index=*]/oper-state", qTIf+"_oper_state", tif, vxi),
		rb("/tunnel-interface[name=*]/vxlan-interface[index=*]/oper-down-reason", qTIf+"_oper_down_reason", tif, vxi),
		// the remote VTEPs and per-VTEP multicast destinations a spanning mac-vrf needs
		rb("/tunnel-interface[name=*]/vxlan-interface[index=*]/bridge-table/multicast-destinations/destination[vtep=*][vni=*]/destination-index",
			qMcd+"_destination_index", mcast...),
		rb("/tunnel-interface[name=*]/vxlan-interface[index=*]/bridge-table/multicast-destinations/destination[vtep=*][vni=*]/not-programmed-reason",
			qMcd+"_not_programmed_reason", mcast...),
		rb("/tunnel/vxlan-tunnel/vtep[address=*]/index", "srl_nokia_tunnel:tunnel_srl_nokia_vxlan_tunnel_vtep:vxlan_tunnel_vtep_index", pee("vtep_address")),
		rb("/network-instance[name=*]/oper-state", qNI+"network_instance_oper_state", ni),
		rb("/network-instance[name=*]/oper-down-reason", qNI+"network_instance_oper_down_reason", ni),
		rb("/network-instance[name=*]/interface[name=*]/oper-state", qNI+"network_instance_interface_oper_state", ni, dcl("interface_name")),
		rb("/network-instance[name=*]/interface[name=*]/oper-down-reason", qNI+"network_instance_interface_oper_down_reason", ni, dcl("interface_name")),
		rb("/network-instance[name=*]/vxlan-interface[name=*]/oper-state", qNI+"network_instance_vxlan_interface_oper_state", ni, dcl("vxlan_interface_name")),
		rb("/network-instance[name=*]/vxlan-interface[name=*]/oper-down-reason", qNI+"network_instance_vxlan_interface_oper_down_reason", ni, dcl("vxlan_interface_name")),
		// the fabric's BGP sessions and per-family state and counts (G7's EVPN
		// series; BGP runs only in the default instance — the fabric renderer's)
		rb("/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/session-state", qBGP+"_session_state", niDefault, peer),
		rb("/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=*]/oper-state", qBGP+"_afi_safi_oper_state", niDefault, peer, afi),
		rb("/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=*]/received-routes", qBGP+"_afi_safi_received_routes", niDefault, peer, afi),
		// every instance's route table, a spanning ip-vrf's remote prefixes read per
		// prefix (never a count)
		rb("/network-instance[name=*]/route-table/ipv4-unicast/route/active",
			qNI+"network_instance_route_table_srl_nokia_ip_route_tables:ipv4_unicast_route_active", route("ipv4")...),
		rb("/network-instance[name=*]/route-table/ipv6-unicast/route/active",
			qNI+"network_instance_route_table_srl_nokia_ip_route_tables:ipv6_unicast_route_active", route("ipv6")...),
		// the EVPN and BGP-VPN instances (G7's evi / oper-state; RD/RT origins)
		rb("/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/evi", qEVPN+"_evi", ni, dcl("bgp_instance_id")),
		rb("/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/oper-state", qEVPN+"_oper_state", ni, dcl("bgp_instance_id")),
		rb("/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/oper-down-reason", qEVPN+"_oper_down_reason", ni, dcl("bgp_instance_id")),
		rb("/network-instance[name=*]/protocols/bgp-vpn/bgp-instance[id=*]/route-distinguisher/route-distinguisher-origin",
			qBVPN+"_route_distinguisher_route_distinguisher_origin", ni, dcl("bgp_instance_id")),
		rb("/network-instance[name=*]/protocols/bgp-vpn/bgp-instance[id=*]/route-target/export-route-target-origin",
			qBVPN+"_route_target_export_route_target_origin", ni, dcl("bgp_instance_id")),
		rb("/network-instance[name=*]/protocols/bgp-vpn/bgp-instance[id=*]/route-target/import-route-target-origin",
			qBVPN+"_route_target_import_route_target_origin", ni, dcl("bgp_instance_id")),
		// the access-list read-back's applied side (T108; contracts/acl-render-contract.md
		// §4.1, §4.3): the datapath programming gate per forwarding complex, and per
		// filter entry its TCAM cost by direction and its statistics — FR-089's
		// per-entry access-list counters
		rb("/acl/datapath-programming/forwarding-complex[slot-id=*][complex-id=*]/programming-complete",
			"srl_nokia_acl:acl_datapath_programming_forwarding_complex_programming_complete",
			inv("forwarding_complex_slot_id"), inv("forwarding_complex_complex_id")),
		rb("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/tcam-entries/forwarding-complex[complex-identifier=*]/single-instance",
			qACL+"_tcam_entries_forwarding_complex_single_instance", acl(inv("forwarding_complex_complex_identifier"))...),
		rb("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/tcam-entries/forwarding-complex[complex-identifier=*]/input-total",
			qACL+"_tcam_entries_forwarding_complex_input_total", acl(inv("forwarding_complex_complex_identifier"))...),
		rb("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/tcam-entries/forwarding-complex[complex-identifier=*]/output-total",
			qACL+"_tcam_entries_forwarding_complex_output_total", acl(inv("forwarding_complex_complex_identifier"))...),
		rb("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/statistics/matched-packets", qACL+"_statistics_matched_packets", acl()...),
		rb("/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/statistics/incomplete", qACL+"_statistics_incomplete", acl()...),
		// the anycast-gateway read-back (T116): the IRB subinterface's anycast-gw MAC
		// origin, each address's status, and the default instance's EVPN RIB
		// IP-prefix (Type-5) routes, read per route distinguisher and prefix
		rb("/interface[name=*]/subinterface[index=*]/anycast-gw/anycast-gw-mac-origin", qIf+"interface_subinterface_anycast_gw_anycast_gw_mac_origin", ifn, sub),
		rb("/interface[name=*]/subinterface[index=*]/ipv4/address[ip-prefix=*]/status", qIf+"interface_subinterface_ipv4_address_status", ifn, sub, dcl("address_ip_prefix")),
		rb("/interface[name=*]/subinterface[index=*]/ipv6/address[ip-prefix=*]/status", qIf+"interface_subinterface_ipv6_address_status", ifn, sub, dcl("address_ip_prefix")),
		rb("/network-instance[name=default]/bgp-rib/afi-safi[afi-safi-name=evpn]/evpn/rib-in-out/rib-in-post/ip-prefix-route[route-distinguisher=*][ethernet-tag-id=*][ip-prefix-length=*][ip-prefix=*][neighbor=*][path-id=*]/used-route",
			qNI+"network_instance_srl_nokia_rib_bgp:bgp_rib_afi_safi_evpn_rib_in_out_rib_in_post_ip_prefix_route_used_route",
			niDefault, sch("afi_safi_afi_safi_name"), rte("ip_prefix_route_route_distinguisher"), rte("ip_prefix_route_ethernet_tag_id"),
			rte("ip_prefix_route_ip_prefix_length"), rte("ip_prefix_route_ip_prefix"), rte("ip_prefix_route_neighbor"), rte("ip_prefix_route_path_id")),
		// ---- device-state (5 s): FR-089's link state beside the read-back's ----
		st("/interface[name=*]/admin-state", qIf+"interface_admin_state", ifn),

		// ---- device-counters (10 s): FR-089's traffic rate, statistics and summaries ----
		ct("/interface[name=*]/traffic-rate", qIf+"interface_traffic_rate", ifn),
		ct("/interface[name=*]/statistics", qIf+"interface_statistics", ifn),
		ct("/interface[name=*]/subinterface[index=*]/statistics", qIf+"interface_subinterface_statistics", ifn, sub),
		ct("/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=*]/active-routes", qBGP+"_afi_safi_active_routes", niDefault, peer, afi),
		// the VTEP carries the VXLAN packet counters; the tunnel interface has none (evidence/06 §2.1)
		ct("/tunnel/vxlan-tunnel/vtep[address=*]/statistics", "srl_nokia_tunnel:tunnel_srl_nokia_vxlan_tunnel_vtep:vxlan_tunnel_vtep_statistics", pee("vtep_address")),
		// bridge-table MAC counts: the three totals as leaves and the per-learn-type
		// list as its own path — a container holding a list is never subscribed
		// whole (its entries' keys would not become labels predictably)
		ct("/network-instance[name=*]/bridge-table/statistics/total-entries", qNI+"network_instance_bridge_table_srl_nokia_bridge_table_mac_table:statistics_total_entries", ni),
		ct("/network-instance[name=*]/bridge-table/statistics/active-entries", qNI+"network_instance_bridge_table_srl_nokia_bridge_table_mac_table:statistics_active_entries", ni),
		ct("/network-instance[name=*]/bridge-table/statistics/failed-entries", qNI+"network_instance_bridge_table_srl_nokia_bridge_table_mac_table:statistics_failed_entries", ni),
		ct("/network-instance[name=*]/bridge-table/statistics/mac-type[type=*]", qNI+"network_instance_bridge_table_srl_nokia_bridge_table_mac_table:statistics_mac_type", ni, sch("mac_type_type")),
		// route-table and tunnel-table summaries
		ct("/network-instance[name=*]/route-table/ipv4-unicast/statistics", qNI+"network_instance_route_table_srl_nokia_ip_route_tables:ipv4_unicast_statistics", ni),
		ct("/network-instance[name=*]/route-table/ipv6-unicast/statistics", qNI+"network_instance_route_table_srl_nokia_ip_route_tables:ipv6_unicast_statistics", ni),
		ct("/network-instance[name=*]/tunnel-table/ipv4/statistics", qNI+"network_instance_tunnel_table_srl_nokia_tunnel_tables:ipv4_statistics", ni),

		// ---- device-health (10 s): FR-089's platform CPU, memory and application health ----
		hl("/platform/control[slot=*]/cpu[index=all]/total", "srl_nokia_platform:platform_srl_nokia_platform_control:control_srl_nokia_platform_cpu:cpu_total", inv("control_slot"), sch("cpu_index")),
		hl("/platform/control[slot=*]/memory", "srl_nokia_platform:platform_srl_nokia_platform_control:control_srl_nokia_platform_memory:memory", inv("control_slot")),
		hl("/system/app-management/application[name=*]/state", "srl_nokia_system:system_srl_nokia_app_mgmt:app_management_application_state", inv("application_name")),
	}
}

// Subscription is one named gNMIc subscription: one Subscribe stream per target.
type Subscription struct {
	Name           string
	Paths          []string
	Mode           StreamMode
	SampleInterval time.Duration
}

// Subscriptions groups SubscribeEntries by subscription, sorted by name, each
// subscription's paths in register order.
func Subscriptions() []Subscription {
	by := map[string]*Subscription{}
	var names []string
	for _, e := range SubscribeEntries() {
		s, ok := by[e.Subscription]
		if !ok {
			s = &Subscription{Name: e.Subscription, Mode: e.Mode, SampleInterval: e.SampleInterval}
			by[e.Subscription] = s
			names = append(names, e.Subscription)
		}
		s.Paths = append(s.Paths, e.Path)
	}
	sort.Strings(names)
	out := make([]Subscription, 0, len(names))
	for _, n := range names {
		out = append(out, *by[n])
	}
	return out
}

// CheckSubscriptions returns an *UncoveredError naming every subscribed path of
// subs that the register does not carry under the same subscription name,
// stream mode and sample interval. The guard calls it on
// internal/telemetry.Subscriptions() and on the committed
// deploy/observability/gnmic/subscriptions.yaml.
func CheckSubscriptions(subs []Subscription) error {
	return checkSubscriptionsAgainst(subs, SubscribeEntries())
}

func checkSubscriptionsAgainst(subs []Subscription, entries []SubscribeEntry) error {
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

// validateSubscribe checks the subscription side without the YANG index:
// required fields, a known stream mode, the closed bound set, no duplicate
// label, the pipeline labels last, one mode and interval per subscription, at
// most MaxSubscriptions streams, and no two entries covering the same or an
// overlapping path (a duplicate series, DuplicateDeviceSeries).
func validateSubscribe(entries []SubscribeEntry) []string {
	var errs []string
	seen := map[string]bool{}
	type streamKey struct {
		mode StreamMode
		iv   time.Duration
	}
	streams := map[string]streamKey{}
	for _, e := range entries {
		errs = append(errs, validateCommon("subscribe", e.Path, e.Model, e.Justification, seen)...)
		if e.Metric == "" || len(e.Labels) == 0 || e.Mode == "" || e.Subscription == "" || e.SampleInterval <= 0 {
			errs = append(errs, fmt.Sprintf("subscribe %s: metric, labels, mode, interval and subscription are required", e.Path))
		}
		if e.Mode != Sample && e.Mode != OnChange {
			errs = append(errs, fmt.Sprintf("subscribe %s: stream mode %q", e.Path, e.Mode))
		}
		if k, ok := streams[e.Subscription]; ok && (k.mode != e.Mode || k.iv != e.SampleInterval) {
			errs = append(errs, fmt.Sprintf("subscribe %s: subscription %s mixes %s/%s with %s/%s", e.Path, e.Subscription, k.mode, k.iv, e.Mode, e.SampleInterval))
		}
		streams[e.Subscription] = streamKey{e.Mode, e.SampleInterval}
		if e.ReadBack && e.SampleInterval != fast {
			errs = append(errs, fmt.Sprintf("subscribe %s: a read-back path is sampled every %s — the collector's 20 s metric_expiration needs 5 s", e.Path, e.SampleInterval))
		}
		errs = append(errs, validateLabels(e)...)
	}
	if len(streams) > MaxSubscriptions {
		errs = append(errs, fmt.Sprintf("subscribe: %d subscriptions, at most %d Subscribe streams per target", len(streams), MaxSubscriptions))
	}
	for i := range entries {
		for j := i + 1; j < len(entries); j++ {
			if Overlaps(entries[i].Path, entries[j].Path) {
				errs = append(errs, fmt.Sprintf("subscribe %s and %s overlap: the same series would be subscribed twice", entries[i].Path, entries[j].Path))
			}
		}
	}
	return errs
}

func validateLabels(e SubscribeEntry) []string {
	var errs []string
	names := map[string]bool{}
	for _, l := range e.Labels {
		if names[l.Name] {
			errs = append(errs, fmt.Sprintf("subscribe %s: label %s twice (gNMIc keeps one tag of a name)", e.Path, l.Name))
		}
		names[l.Name] = true
		known := false
		for _, b := range Bounds {
			known = known || l.Bound == b
		}
		if !known {
			errs = append(errs, fmt.Sprintf("subscribe %s: label %s: bound %q is not one of %v (R-09)", e.Path, l.Name, l.Bound, Bounds))
		}
	}
	n := len(e.Labels)
	if n < len(PipelineLabels) || fmt.Sprint(e.Labels[n-len(PipelineLabels):]) != fmt.Sprint(PipelineLabels) {
		errs = append(errs, fmt.Sprintf("subscribe %s: labels must end with the pipeline labels %v", e.Path, PipelineLabels))
	} else {
		for _, l := range e.Labels[:n-len(PipelineLabels)] {
			if l.Bound == BoundPipeline {
				errs = append(errs, fmt.Sprintf("subscribe %s: path label %s claims the pipeline bound", e.Path, l.Name))
			}
		}
	}
	return errs
}

// Elem is one element of a subscription path: its name and its keys as
// written (a key not written is absent).
type Elem struct {
	Name string
	Keys map[string]string
}

// SplitPath splits a gNMI string path into its elements; `/` inside a key
// value is not a separator.
func SplitPath(path string) []Elem {
	var out []Elem
	for _, raw := range splitElems(path) {
		e := Elem{Name: raw, Keys: map[string]string{}}
		if i := strings.IndexByte(raw, '['); i >= 0 {
			e.Name = raw[:i]
			rest := raw[i:]
			for len(rest) > 0 && rest[0] == '[' {
				end := strings.IndexByte(rest, ']')
				if end < 0 {
					break
				}
				kv := rest[1:end]
				if eq := strings.IndexByte(kv, '='); eq >= 0 {
					e.Keys[kv[:eq]] = kv[eq+1:]
				}
				rest = rest[end+1:]
			}
		}
		out = append(out, e)
	}
	return out
}

// Overlaps reports whether two subscription paths can select a common data
// node: one's elements are a prefix of the other's (or equal), and no list
// key is fixed to two different values.
func Overlaps(a, b string) bool {
	ea, eb := SplitPath(a), SplitPath(b)
	if len(eb) < len(ea) {
		ea, eb = eb, ea
	}
	for i := range ea {
		if ea[i].Name != eb[i].Name {
			return false
		}
		for k, va := range ea[i].Keys {
			if vb, ok := eb[i].Keys[k]; ok && va != "*" && vb != "*" && va != vb {
				return false
			}
		}
	}
	return true
}

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
