// Package telemetry holds the provider-side observability wiring. This file is
// the device subscription set the in-cluster gNMIc is configured with (FR-089,
// data-model.md §21): native srl_nokia paths only, sampled by default. The
// path register (pkg/register) must cover every path returned here, with the
// same stream mode and interval; its CI guard drives Subscriptions() to prove it
// (FR-017, T022). T128 re-validates the set against the pinned YANG tag and
// generates deploy/observability/gnmic/subscriptions.yaml from it.
package telemetry

import (
	"sort"
	"time"
)

// StreamMode is a gNMI subscription stream mode.
type StreamMode string

const (
	// Sample is the default (data-model.md §21).
	Sample StreamMode = "sample"
	// OnChange is used only where an acceptance check (gate item G7) covers it;
	// none does today.
	OnChange StreamMode = "on-change"
)

// Subscription is one named gNMIc subscription.
type Subscription struct {
	Name           string
	Paths          []string
	Mode           StreamMode
	SampleInterval time.Duration
}

// Subscriptions returns the device subscription set, sorted by name
// (evidence/06-telemetry-visualization.md §2.1, re-cut to FR-089's list).
// Every mode is `sample`: the on-change candidates fall back to their sampled
// form until G7 qualifies on-change for them.
func Subscriptions() []Subscription {
	const fast, slow = 5 * time.Second, 10 * time.Second
	subs := []Subscription{
		{Name: "srl-if-state", Mode: Sample, SampleInterval: fast, Paths: []string{
			"/interface[name=*]/admin-state",
			"/interface[name=*]/oper-state",
		}},
		{Name: "srl-if-rate", Mode: Sample, SampleInterval: fast, Paths: []string{
			"/interface[name=*]/traffic-rate",
		}},
		{Name: "srl-if-stats", Mode: Sample, SampleInterval: slow, Paths: []string{
			"/interface[name=*]/statistics",
		}},
		{Name: "srl-subif-stats", Mode: Sample, SampleInterval: slow, Paths: []string{
			"/interface[name=*]/subinterface[index=*]/statistics",
			"/interface[name=*]/subinterface[index=*]/oper-state",
		}},
		{Name: "srl-bgp-neighbor", Mode: Sample, SampleInterval: fast, Paths: []string{
			"/network-instance[name=*]/protocols/bgp/neighbor[peer-address=*]/session-state",
		}},
		{Name: "srl-bgp-afisafi", Mode: Sample, SampleInterval: slow, Paths: []string{
			"/network-instance[name=*]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=*]/received-routes",
			"/network-instance[name=*]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=*]/active-routes",
		}},
		{Name: "srl-net-instance", Mode: Sample, SampleInterval: fast, Paths: []string{
			"/network-instance[name=*]/oper-state",
		}},
		{Name: "srl-bgp-evpn", Mode: Sample, SampleInterval: slow, Paths: []string{
			"/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/oper-state",
		}},
		{Name: "srl-vxlan", Mode: Sample, SampleInterval: slow, Paths: []string{
			"/tunnel/vxlan-tunnel/vtep[address=*]/statistics",
			"/tunnel-interface[name=*]/vxlan-interface[index=*]/oper-state",
		}},
		{Name: "srl-bridge-table", Mode: Sample, SampleInterval: slow, Paths: []string{
			"/network-instance[name=*]/bridge-table/statistics",
		}},
		{Name: "srl-route-table", Mode: Sample, SampleInterval: slow, Paths: []string{
			"/network-instance[name=*]/route-table/ipv4-unicast/statistics",
			"/network-instance[name=*]/route-table/ipv6-unicast/statistics",
			"/network-instance[name=*]/tunnel-table/ipv4/statistics",
		}},
		// per-entry counters, per-entry TCAM cost by direction and the datapath
		// programming gate — the access-list read-back's applied side (T108,
		// contracts/acl-render-contract.md §4.1, §4.3), every value keyed by
		// filter name, type and sequence-id
		{Name: "srl-acl", Mode: Sample, SampleInterval: slow, Paths: []string{
			"/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/statistics",
			"/acl/acl-filter[name=*][type=*]/entry[sequence-id=*]/tcam-entries",
			"/acl/datapath-programming",
		}},
		// the anycast-gateway read-back (T116, internal/verify/gateway.go): the IRB
		// subinterface's anycast-gw MAC origin, each anycast address's status, and the
		// EVPN RIB's IP-prefix (Type-5) routes keyed by route distinguisher and prefix
		{Name: "srl-anycast-gw", Mode: Sample, SampleInterval: slow, Paths: []string{
			"/interface[name=*]/subinterface[index=*]/anycast-gw/anycast-gw-mac-origin",
			"/interface[name=*]/subinterface[index=*]/ipv4/address[ip-prefix=*]/status",
			"/interface[name=*]/subinterface[index=*]/ipv6/address[ip-prefix=*]/status",
			"/network-instance[name=default]/bgp-rib/afi-safi[afi-safi-name=evpn]/evpn/rib-in-out/rib-in-post/ip-prefix-route[route-distinguisher=*][ethernet-tag-id=*][ip-prefix-length=*][ip-prefix=*][neighbor=*][path-id=*]/used-route",
		}},
		{Name: "srl-platform", Mode: Sample, SampleInterval: slow, Paths: []string{
			"/platform/control[slot=*]/cpu[index=all]/total",
			"/platform/control[slot=*]/memory",
		}},
		{Name: "srl-apps", Mode: Sample, SampleInterval: slow, Paths: []string{
			"/system/app-management/application[name=*]/state",
		}},
	}
	sort.Slice(subs, func(i, j int) bool { return subs[i].Name < subs[j].Name })
	return subs
}
