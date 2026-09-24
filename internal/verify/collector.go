package verify

// CollectorReader — the StateReader whose state datastore is the device
// metric collector (AD-82 decision 2026-09-21-state-source,
// docs/decisions/live-findings.md).
//
// The pinned device-configuration layer serves no state datastore (see the
// package comment: config-server v0.0.58 / data-server v0.0.72 have no GetData
// RPC and the target sync reads CONFIG only), and FR-107 forbids the read-back
// a device session of its own. FR-086 names exactly two clients of the device
// management server: the layer's data-server and the device metric collector.
// The collector (deploy/observability/device-metrics: gNMIc → OpenTelemetry
// Collector → Prometheus exporter) already samples the device's own state, so
// the applied side reads it there — no third client, the device's own values,
// every read keyed to the Fabric's own objects.
//
// How a requested gNMI path is found among the exported series:
//   - the series name is gNMIc's: the path's element names joined with "_"
//     ("-" → "_"), carrying the YANG module qualifier of each module boundary
//     ("srl_nokia_bgp:"). The qualifiers are removed before comparing, so
//     /network-instance/protocols/bgp/neighbor/session-state matches
//     srl_nokia_network_instance:network_instance_protocols_srl_nokia_bgp:bgp_neighbor_session_state;
//   - each list key becomes the label <element>_<key> ("-" → "_"), e.g.
//     neighbor_peer_address, afi_safi_afi_safi_name; an identityref value is
//     compared without its module prefix ("srl_nokia-common:evpn" ≡ "evpn");
//     a key the path leaves unspecified matches any instance;
//   - the series' `source` label is the node (gNMIc's target name);
//   - a presence query (a list's own key leaf, as DeviceObjectStatePath asks)
//     is answered by the object's oper-state series;
//   - string states are exported as integers by the collector's event
//     processors (gNMIc's OTLP output drops strings) and mapped back here with
//     the same tables (scripts/lib/device_metrics.sh): session-state,
//     oper-state, active, the access-list booleans programming-complete and
//     incomplete (T108), the gateway read-back's (T116) EVPN RIB used-route,
//     interface address status and anycast-gw-mac-origin, and — for the service
//     read-back (T058) — every
//     oper-down-reason / not-programmed-reason and the bgp-vpn RD/RT origins
//     (an enum value neither table knows is exported as 0, decoded
//     UnrecognisedValue: a reason present, never one dropped as absent);
//   - uint64 indexes (a VTEP's, a multicast destination's), which JSON_IETF
//     encodes as strings, are converted to integers the same way and read
//     back as their decimal value.
//
// Freshness: the collector's exporter drops a series not refreshed within its
// metric_expiration (20 s, 4 sample intervals of 5 s), so a value read here is at
// most that old. A node with no sample at all in the collector, or a collector
// that does not answer, is a read that could not be made — the pass could not
// run (Ready=Unknown/VerificationFailed) — never an absent value.

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// CollectorReader reads the state datastore from the device metric
// collector's Prometheus endpoint and the running datastore through Layer.
type CollectorReader struct {
	// Layer serves Running (the device-configuration layer's RunningConfig).
	Layer StateReader
	// URL is the collector's Prometheus endpoint, e.g.
	// http://device-metrics.monitoring.svc:8889/metrics.
	URL string
	// HTTP is the client; nil uses one with a 10 s timeout.
	HTTP *http.Client
}

var _ StateReader = (*CollectorReader)(nil)

// Running is the layer's running datastore.
func (r *CollectorReader) Running(ctx context.Context, t Target) ([]byte, error) {
	return r.Layer.Running(ctx, t)
}

// State reads each path's current values for target t from the collector.
func (r *CollectorReader) State(ctx context.Context, t Target, paths []string) (map[string][]string, error) {
	samples, err := r.fetch(ctx)
	if err != nil {
		return nil, fmt.Errorf("state of %s/%s: the device metric collector could not be read: %w", t.Namespace, t.Name, err)
	}
	var mine []Sample
	for _, s := range samples {
		if s.Labels["source"] == t.Name {
			mine = append(mine, s)
		}
	}
	if len(mine) == 0 {
		return nil, fmt.Errorf("state of %s/%s: the device metric collector holds no sample from %s within its expiration window (the collector cannot read the node)", t.Namespace, t.Name, t.Name)
	}
	return MatchState(mine, paths)
}

// Unreachable is the data-path half of "can this node be read" (SC-008, AD-40, AD-54): a node
// with no sample in the collector, or whose newest sample is older than maxAge at now, cannot
// be read — the collector's subscription to it has stopped delivering. The layer's Target can
// stay Ready for minutes after a management cut (a dead TCP session is not noticed; observed
// 2026-09-21, docs/decisions/live-findings.md 2026-09-21-target-unreachable), so this is what
// lets the reconcile that runs every reconciliation interval see an unreadable target within
// SC-008's two intervals. Samples without a timestamp count as fresh (the exporter's own
// metric_expiration then bounds their age). The error is a collector that cannot be read.
func (r *CollectorReader) Unreachable(ctx context.Context, nodes []string, maxAge time.Duration, now time.Time) (map[string]string, error) {
	samples, err := r.fetch(ctx)
	if err != nil {
		return nil, fmt.Errorf("the device metric collector could not be read: %w", err)
	}
	return StaleNodes(samples, nodes, maxAge, now), nil
}

// StaleNodes returns, for each of nodes with no sample, or whose newest timestamped sample is
// older than maxAge at now, why it cannot be read.
func StaleNodes(samples []Sample, nodes []string, maxAge time.Duration, now time.Time) map[string]string {
	type seen struct {
		any    bool
		newest int64
	}
	by := map[string]*seen{}
	for _, n := range nodes {
		by[n] = &seen{}
	}
	for _, s := range samples {
		e, ok := by[s.Labels["source"]]
		if !ok {
			continue
		}
		e.any = true
		if s.TimestampMs == 0 {
			e.newest = -1 // untimestamped: present within the exporter's expiration
		} else if e.newest != -1 && s.TimestampMs > e.newest {
			e.newest = s.TimestampMs
		}
	}
	out := map[string]string{}
	for _, n := range nodes {
		e := by[n]
		switch {
		case !e.any:
			out[n] = "no sample from " + n + " in the device metric collector"
		case e.newest > 0:
			age := now.Sub(time.UnixMilli(e.newest))
			if age > maxAge {
				out[n] = fmt.Sprintf("newest sample from %s in the device metric collector is %s old (limit %s)", n, age.Round(time.Second), maxAge)
			}
		}
	}
	return out
}

func (r *CollectorReader) fetch(ctx context.Context) ([]Sample, error) {
	hc := r.HTTP
	if hc == nil {
		hc = &http.Client{Timeout: 10 * time.Second}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, r.URL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s answered %s", r.URL, resp.Status)
	}
	return ParseExposition(resp.Body)
}

// Sample is one exported series' current value.
type Sample struct {
	Name   string
	Labels map[string]string
	Value  string
	// TimestampMs is the sample's own timestamp (the device's notification time, exported by
	// the collector with send_timestamps), in Unix milliseconds; 0 when the line carries none.
	TimestampMs int64
}

var (
	sampleLine = regexp.MustCompile(`^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+(\S+)(?:\s+(-?[0-9]+))?$`)
	labelPair  = regexp.MustCompile(`([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"`)
	// a native module qualifier inside a gNMIc series name, e.g. "srl_nokia_bgp_evpn:"
	moduleQualifier = regexp.MustCompile(`srl_nokia_[a-z0-9_]*?:`)
	// an identityref value's module prefix, e.g. "srl_nokia-common:" — a module
	// name carries a hyphen, which no IPv6 address group does ("fd00:" is kept)
	identityPrefix = regexp.MustCompile(`^[a-z][a-z0-9_]*-[a-z0-9_-]*:`)
)

// ParseExposition parses the Prometheus text exposition format.
func ParseExposition(rd io.Reader) ([]Sample, error) {
	var out []Sample
	sc := bufio.NewScanner(rd)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		m := sampleLine.FindStringSubmatch(line)
		if m == nil {
			return nil, fmt.Errorf("unparseable exposition line %q", line)
		}
		s := Sample{Name: m[1], Labels: map[string]string{}, Value: m[3]}
		if m[4] != "" {
			s.TimestampMs, _ = strconv.ParseInt(m[4], 10, 64)
		}
		for _, lp := range labelPair.FindAllStringSubmatch(m[2], -1) {
			v := strings.NewReplacer(`\\`, `\`, `\"`, `"`, `\n`, "\n").Replace(lp[2])
			s.Labels[lp[1]] = v
		}
		out = append(out, s)
	}
	return out, sc.Err()
}

// pathElem is one element of a gNMI string path.
type pathElem struct {
	name string
	keys map[string]string
}

// parsePath splits a gNMI string path; '/' inside a key value (a prefix) is
// not a separator.
func parsePath(p string) ([]pathElem, error) {
	var elems []pathElem
	var cur strings.Builder
	depth := 0
	var parts []string
	for _, c := range strings.TrimPrefix(p, "/") {
		switch {
		case c == '[':
			depth++
		case c == ']':
			depth--
		case c == '/' && depth == 0:
			parts = append(parts, cur.String())
			cur.Reset()
			continue
		}
		cur.WriteRune(c)
	}
	parts = append(parts, cur.String())
	if depth != 0 {
		return nil, fmt.Errorf("unbalanced brackets in %q", p)
	}
	for _, part := range parts {
		i := strings.IndexByte(part, '[')
		e := pathElem{name: part, keys: map[string]string{}}
		if i >= 0 {
			e.name = part[:i]
			rest := part[i:]
			for len(rest) > 0 {
				if rest[0] != '[' {
					return nil, fmt.Errorf("bad key in %q", p)
				}
				j := strings.IndexByte(rest, ']')
				kv := rest[1:j]
				eq := strings.IndexByte(kv, '=')
				if eq < 0 {
					return nil, fmt.Errorf("bad key %q in %q", kv, p)
				}
				e.keys[kv[:eq]] = kv[eq+1:]
				rest = rest[j+1:]
			}
		}
		if k := strings.IndexByte(e.name, ':'); k >= 0 {
			e.name = e.name[k+1:]
		}
		elems = append(elems, e)
	}
	return elems, nil
}

func underscore(s string) string { return strings.ReplaceAll(s, "-", "_") }

// SeriesKey is a series name with its module qualifiers removed.
func SeriesKey(name string) string { return moduleQualifier.ReplaceAllString(name, "") }

func bareIdentity(v string) string { return identityPrefix.ReplaceAllString(v, "") }

// MatchState maps each path onto the samples (one node's) that are instances
// of it, decoding each value; a path with no instance is absent from the map.
func MatchState(samples []Sample, paths []string) (map[string][]string, error) {
	out := map[string][]string{}
	for _, p := range paths {
		elems, err := parsePath(p)
		if err != nil {
			return nil, err
		}
		// A presence query — a list's own key leaf, e.g. …/subinterface[index=1]/index
		// or /network-instance[name=x]/name — is answered by that object's
		// oper-state series: the object exists in state when it reports one.
		presence := false
		if n := len(elems); n >= 2 {
			if _, isKey := elems[n-2].keys[elems[n-1].name]; isKey {
				elems = append(append([]pathElem(nil), elems[:n-1]...), pathElem{name: "oper-state", keys: map[string]string{}})
				presence = true
			}
		}
		var names []string
		want := map[string]string{}
		for _, e := range elems {
			names = append(names, underscore(e.name))
			for k, v := range e.keys {
				if v == "*" {
					continue
				}
				want[underscore(e.name)+"_"+underscore(k)] = bareIdentity(v)
			}
		}
		key := strings.Join(names, "_")
		leaf := elems[len(elems)-1].name
		for _, s := range samples {
			if SeriesKey(s.Name) != key {
				continue
			}
			ok := true
			for l, v := range want {
				if got, has := s.Labels[l]; !has || bareIdentity(got) != v {
					ok = false
					break
				}
			}
			if ok && presence {
				out[p] = append(out[p], "present")
			} else if ok {
				out[p] = append(out[p], decodeValue(leaf, s.Value))
			}
		}
	}
	return out, nil
}

// The collector's integer encodings of string states (scripts/lib/device_metrics.sh;
// TestDecodeTablesMatchCollectorConfig holds the two to the same tables).
var (
	sessionStates = map[int64]string{5: "established", 4: "openconfirm", 3: "opensent", 2: "active", 1: "connect", 0: "idle"}
	operStates    = map[int64]string{1: "up", 0: "down"}
	booleans      = map[int64]string{1: "true", 0: "false"}
	// DEVICE_METRICS_REASONS: every oper-down-reason / not-programmed-reason
	// enum the service read-back's subscriptions reach on SR Linux 25.7.1; 0 is
	// a value the collector's table does not know — still a reason present.
	reasons = map[int64]string{
		0: UnrecognisedValue, 1: "admin-disabled", 2: "admin-down", 3: "associated-ip-vrf-down", 4: "associated-mac-vrf-down",
		5: "bgp-vpn-instance-oper-down", 6: "cfm-ccm-defect", 7: "egress-hash-failed",
		8: "esi-label-required-in-ethernet-segment", 9: "ethernet-segment-multiple-subinterfaces",
		10: "evpn-mh-standby", 11: "ingress-hash-failed", 12: "interface-ref-missing", 13: "ip-addr-missing",
		14: "ip-addr-overlap", 15: "ip-mtu-larger-than-oper-mac-vrf-mtu", 16: "ip-mtu-resource-exceeded",
		17: "ip-mtu-too-large", 18: "ip-vrf-association-missing", 19: "irb-mac-address-not-programmed",
		20: "l2-mtu-too-large", 21: "mac-dup-detected", 22: "mac-failed", 23: "mac-vrf-association-missing",
		24: "missing-xdp-state", 25: "mpls-mtu-resource-exceeded", 26: "mpls-mtu-too-large", 27: "multicast-limit",
		28: "net-inst-down", 29: "network-instance-oper-down", 30: "no-destination-index", 31: "no-evi",
		32: "no-ip-config", 33: "no-irb-hardware-resources", 34: "no-local-attachment-circuit", 35: "no-mcid",
		36: "no-mpls-label", 37: "no-nexthop-address", 38: "no-remote-attachment-circuit",
		39: "no-underlay-egress-next-hop-resources", 40: "no-vxlan-interface", 41: "other", 42: "port-down",
		43: "stp-not-forwarding", 44: "subif-down", 45: "tag-set-not-resolved", 46: "vrf-type-mismatch",
		47: "vxlan-if-default-net-inst-source-address-missing", 48: "vxlan-if-default-net-inst-source-if-down",
		49: "vxlan-tunnel-down", 50: "vxlan_interface_no_source_ip_address", 51: "associations-oper-down",
		52: "no-associations",
	}
	// DEVICE_METRICS_ORIGINS: the bgp-vpn instance's RD / RT origin enums.
	origins = map[int64]string{
		0: UnrecognisedValue, 1: "auto-derived-from-evi", 2: "auto-derived-from-system-ip:0", 3: "manual", 4: "none",
		5: "auto-derived-from-esi-bytes-1-6", 6: "from-export-policy", 7: "from-import-policy",
	}
	// DEVICE_METRICS_ADDRESS_STATUSES: an interface address's status (T116).
	addressStatuses = map[int64]string{
		0: UnrecognisedValue, 1: "preferred", 2: "deprecated", 3: "invalid", 4: "inaccessible", 5: "unknown",
		6: "tentative", 7: "duplicate", 8: "optimistic",
	}
	// DEVICE_METRICS_ANYCAST_ORIGINS: an IRB subinterface's anycast-gw-mac-origin (T116).
	anycastOrigins = map[int64]string{0: UnrecognisedValue, 1: "configured", 2: "vrid-auto-derived"}
)

// UnrecognisedValue is the decoded form of an enumerated leaf whose device
// value the collector's table does not carry (encoded 0).
const UnrecognisedValue = "unrecognised-value"

func decodeValue(leaf, v string) string {
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return v
	}
	n := int64(f)
	var table map[int64]string
	switch leaf {
	case "session-state":
		table = sessionStates
	case "oper-state":
		table = operStates
	case "active", "programming-complete", "incomplete", "used-route":
		table = booleans
	case "status":
		table = addressStatuses
	case "anycast-gw-mac-origin":
		table = anycastOrigins
	case "oper-down-reason", "not-programmed-reason":
		table = reasons
	case "route-distinguisher-origin", "export-route-target-origin", "import-route-target-origin":
		table = origins
	}
	if s, ok := table[n]; ok && float64(n) == f {
		return s
	}
	return strconv.FormatInt(n, 10)
}
