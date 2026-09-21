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
//     the same tables (scripts/lib/device_metrics.sh).
//
// Freshness: the collector's exporter drops a series not refreshed within its
// metric_expiration (45 s, 4.5 sample intervals), so a value read here is at
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
}

var (
	sampleLine = regexp.MustCompile(`^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+(\S+)(?:\s+\S+)?$`)
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

// The collector's integer encodings of string states (scripts/lib/device_metrics.sh).
var (
	sessionStates = map[int64]string{5: "established", 4: "openconfirm", 3: "opensent", 2: "active", 1: "connect", 0: "idle"}
	operStates    = map[int64]string{1: "up", 0: "down"}
	booleans      = map[int64]string{1: "true", 0: "false"}
)

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
	case "active":
		table = booleans
	}
	if s, ok := table[n]; ok && float64(n) == f {
		return s
	}
	return strconv.FormatInt(n, 10)
}
