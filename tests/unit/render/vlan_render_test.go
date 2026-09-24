// T053 — the service render goldens and the per-construct assertions of the
// priority-20 service Config (contracts/reconciliation.md Rule 2, Rule 11;
// data-model.md §13; FR-015, FR-017, FR-029, FR-030, FR-031, SC-016, AD-68).
//
// This file holds the shared service fixtures and checks — goldens, the G12
// freeze (T063), no port-level leaf, the interface-ref of every subinterface,
// the register, stable bytes and hash — and the `vlan` construct;
// macvrf_render_test.go and ipvrf_render_test.go hold the `mac-vrf` (with and
// without an anycast gateway) and `ip-vrf` constructs.
//
// The golden files under tests/golden/services/ are named <service>-<node>.json
// and are frozen (T063) in the identityref serialization gate item G12
// observed from a real device (tests/gate/observed/serialization.json; R-36,
// AD-81); `make verify-render-schema` validates each one layered on the fabric
// golden of the same node.
//
// Regenerate the goldens with:
//
//	go test ./tests/unit/render/ -run TestServiceGoldens -update
package render_test

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"testing"

	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/render/srl"
	"github.com/mairp/agentic-netops-srl/pkg/register"
)

const serviceGoldenDir = "../../golden/services"

var leaves = []string{"leaf01", "leaf02"}

// Representative services on the lab topology: leaf01/leaf02, access port
// ethernet-1/1 (tagged in the fabric golden), fabric ASN 65000, VLANs in
// 100–999 and VNIs in 10000–20000 (kuid-claim-profiles.md §1).
func vlanInput() model.ServiceInput {
	return model.ServiceInput{ServiceID: "web", Tenant: "tenant1", Construct: model.ConstructVLAN, FabricASN: 65000,
		L2: &model.L2Segment{VLAN: 110, L2MTU: 9412, Attachments: []model.Attachment{
			{Node: "leaf01", Port: "ethernet-1/1"}, {Node: "leaf02", Port: "ethernet-1/1"}}}}
}

func macvrfInput() model.ServiceInput {
	return model.ServiceInput{ServiceID: "app", Tenant: "tenant1", Construct: model.ConstructMACVRF, FabricASN: 65000,
		L2: &model.L2Segment{VLAN: 200, L2VNI: 10200, L2MTU: 9412, Attachments: []model.Attachment{
			{Node: "leaf01", Port: "ethernet-1/1"}, {Node: "leaf02", Port: "ethernet-1/1"}}}}
}

func macvrfGWInput() model.ServiceInput {
	return model.ServiceInput{ServiceID: "4b7e19c2a05d3f6", Tenant: "tenant1", Construct: model.ConstructMACVRF, FabricASN: 65000,
		L2: &model.L2Segment{VLAN: 300, L2VNI: 10300, L2MTU: 9412, Attachments: []model.Attachment{
			{Node: "leaf01", Port: "ethernet-1/1"}, {Node: "leaf02", Port: "ethernet-1/1"}}},
		Gateway: &model.Gateway{L3VNI: 10301, IPv4: []string{"10.30.0.1/24"}, IPv6: []string{"2001:db8:30::1/64"}, IPMTU: 9348}}
}

func ipvrfInput() model.ServiceInput {
	return model.ServiceInput{ServiceID: "db", Tenant: "tenant1", Construct: model.ConstructIPVRF, FabricASN: 65000,
		Routed: &model.RoutedService{L3VNI: 10400, Attachments: []model.RoutedAttachment{
			{Node: "leaf01", Port: "ethernet-1/1", VLAN: 400, IPv4: []string{"10.40.1.1/24"}, IPv6: []string{"2001:db8:40:1::1/64"}},
			{Node: "leaf02", Port: "ethernet-1/1", VLAN: 400, IPv4: []string{"10.40.2.1/24"}, IPv6: []string{"2001:db8:40:2::1/64"}},
		}, IPMTU: 9348}}
}

// serviceInputs are the golden services, keyed by the golden-file prefix.
func serviceInputs() map[string]model.ServiceInput {
	return map[string]model.ServiceInput{
		"vlan": vlanInput(), "macvrf": macvrfInput(), "macvrf-gw": macvrfGWInput(), "ipvrf": ipvrfInput(),
		// the single-family anycast gateways (gateway_render_test.go, T115)
		"gateway_ipv4": gatewayIPv4Input(), "gateway_ipv6": gatewayIPv6Input(),
	}
}

func renderService(t *testing.T, in model.ServiceInput) map[string]*srl.Rendered {
	t.Helper()
	m, err := model.BuildService(in)
	if err != nil {
		t.Fatalf("BuildService %s: %v", in.ServiceID, err)
	}
	r, err := srl.RenderService(m)
	if err != nil {
		t.Fatalf("RenderService %s: %v", in.ServiceID, err)
	}
	if len(r) != len(m.Nodes) {
		t.Fatalf("rendered %d nodes, want %d", len(r), len(m.Nodes))
	}
	return r
}

// ---------------------------------------------------------------------------
// An extractor independent of the renderer: JSON bytes -> concrete leaf paths.
// ---------------------------------------------------------------------------

// serviceListKeys are the keys of every list a service render may contain
// (srl_nokia models @ v25.7.1); /acl/interface is keyed by interface-id and a
// network-instance's vxlan-interface by name.
var serviceListKeys = map[string][]string{
	"interface": {"name"}, "subinterface": {"index"}, "address": {"ip-prefix"},
	"network-instance": {"name"}, "tunnel-interface": {"name"}, "vxlan-interface": {"index"},
	"bgp-instance": {"id"}, "populate": {"route-type"}, "advertise": {"route-type"},
	"acl-filter": {"name", "type"}, "entry": {"sequence-id"},
}

// flattenService returns path -> JSON value of every leaf and leaf-list, plus
// every key-only list entry and every empty presence container (value "{}").
// Node names lose their module qualifier. A list the service render has no
// business emitting fails.
func flattenService(t *testing.T, doc []byte) map[string]string {
	t.Helper()
	dec := json.NewDecoder(bytes.NewReader(doc))
	dec.UseNumber()
	var root map[string]any
	if err := dec.Decode(&root); err != nil {
		t.Fatalf("rendered document is not JSON: %v", err)
	}
	out := map[string]string{}
	var walk func(prefix string, obj map[string]any, skip map[string]bool)
	walk = func(prefix string, obj map[string]any, skip map[string]bool) {
		for k, v := range obj {
			if skip[k] {
				continue
			}
			name := k
			if i := strings.IndexByte(k, ':'); i >= 0 {
				name = k[i+1:]
			}
			p := prefix + "/" + name
			switch x := v.(type) {
			case map[string]any:
				if len(x) == 0 {
					out[p] = "{}" // a presence container (an access-list action)
					continue
				}
				walk(p, x, nil)
			case []any:
				if len(x) > 0 {
					if _, isObj := x[0].(map[string]any); !isObj {
						b, _ := json.Marshal(x)
						out[p] = string(b)
						continue
					}
				}
				keys, ok := serviceListKeys[name]
				switch {
				case p == "/acl/interface":
					keys, ok = []string{"interface-id"}, true
				case name == "vxlan-interface" && strings.HasPrefix(p, "/network-instance["):
					keys, ok = []string{"name"}, true
				}
				if !ok {
					t.Fatalf("%s: a list the service render has no business emitting", p)
				}
				for _, e := range x {
					entry := e.(map[string]any)
					ep := p
					sk := map[string]bool{}
					for _, key := range keys {
						ep += fmt.Sprintf("[%s=%v]", key, entry[key])
						sk[key] = true
					}
					if _, dup := out[ep]; dup {
						t.Fatalf("duplicate list entry %s", ep)
					}
					if len(entry) == len(keys) {
						out[ep] = "{}"
						continue
					}
					walk(ep, entry, sk)
				}
			default:
				b, _ := json.Marshal(x)
				out[p] = string(b)
			}
		}
	}
	walk("", root, nil)
	return out
}

func sortedKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// ---------------------------------------------------------------------------
// Goldens and their G12 freeze (T063).
// ---------------------------------------------------------------------------

func TestServiceGoldens(t *testing.T) {
	wantFiles := map[string]bool{}
	goldens := serviceInputs()
	for name, in := range aclGoldenInputs(t) { // acl_render_test.go (T104, T113)
		goldens[name] = in
	}
	goldens["gateway_example"] = gatewayExampleInput(t) // gateway_render_test.go (T115)
	for name, in := range goldens {
		r := renderService(t, in)
		for node, rn := range r {
			file := name + "-" + node + ".json"
			wantFiles[file] = true
			path := filepath.Join(serviceGoldenDir, file)
			if *update {
				if err := os.MkdirAll(serviceGoldenDir, 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, rn.JSON, 0o644); err != nil {
					t.Fatal(err)
				}
				continue
			}
			golden, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("golden %s: %v (regenerate with -update)", path, err)
			}
			if !bytes.Equal(golden, rn.JSON) {
				t.Errorf("%s/%s: render differs from golden %s (regenerate with -update after review)\n--- got ---\n%s", name, node, path, rn.JSON)
			}
		}
	}
	// No golden without a render behind it: make verify-render-schema
	// validates every file in the directory.
	entries, err := os.ReadDir(serviceGoldenDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if !wantFiles[e.Name()] {
			t.Errorf("%s: a golden no service render produces", filepath.Join(serviceGoldenDir, e.Name()))
		}
	}
	for f := range wantFiles {
		node := f[strings.LastIndex(f, "-")+1 : len(f)-len(".json")]
		if !slices.Contains(leaves, node) {
			t.Errorf("%s: golden name does not end in -<node>.json (verify-render-schema layers it on tests/golden/fabric/<node>.json)", f)
		}
	}
}

// g12Service is what G12 observed of the identityrefs and the empty leaf a
// service render carries.
type g12Service struct {
	Qualified        bool   `json:"identityref_values_module_qualified"`
	NIMACVRF         string `json:"network_instance_type_mac_vrf"`
	NIIPVRF          string `json:"network_instance_type_ip_vrf"`
	SubifBridged     string `json:"subinterface_type_bridged"`
	VXLANRouted      string `json:"vxlan_interface_type_routed"`
	EmptyLeafPrimary []any  `json:"empty_leaf_primary"`
}

// TestServiceGoldensFrozenAgainstG12: the service goldens are frozen (T063) in
// the identityref form gate item G12 observed from a real device Get
// (AD-81): every network-instance, subinterface and vxlan-interface type is
// the observed module-qualified identity, and the empty leaf `primary`, WHERE
// a golden carries it, is the observed [null]. No golden carries it today:
// irb0's IPv4 address renders no `primary` (live finding 2026-09-24-irb-primary,
// internal/render/srl/irb.go) — the check keeps validating the form so a
// primary reintroduced in any other shape fails.
func TestServiceGoldensFrozenAgainstG12(t *testing.T) {
	b, err := os.ReadFile(g12Observation)
	if err != nil {
		t.Fatalf("G12 observation %s unreadable (%v): the goldens are frozen against it", g12Observation, err)
	}
	var obs struct {
		Summary g12Service `json:"summary"`
	}
	if err := json.Unmarshal(b, &obs); err != nil {
		t.Fatalf("%s: %v", g12Observation, err)
	}
	goldens := map[string][]byte{}
	entries, err := os.ReadDir(serviceGoldenDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		g, err := os.ReadFile(filepath.Join(serviceGoldenDir, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		goldens[e.Name()] = g
	}
	if len(goldens) == 0 {
		t.Fatal("no service golden to freeze")
	}
	for _, msg := range checkServiceGoldensAgainstG12(obs.Summary, goldens) {
		t.Error(msg)
	}
	// The goldens carry every kind of identity G12 observed for a service.
	all := ""
	for _, g := range goldens {
		all += string(g)
	}
	for _, v := range []string{obs.Summary.NIMACVRF, obs.Summary.NIIPVRF, obs.Summary.SubifBridged, obs.Summary.VXLANRouted} {
		if !strings.Contains(all, `"`+v+`"`) {
			t.Errorf("no service golden carries %q as G12 observed it", v)
		}
	}
}

// TestServiceGoldensG12CheckNegativeControl: the freeze check refuses a bare
// type, a wrong module, a primary that is not [null], and an observation
// that is not module-qualified.
func TestServiceGoldensG12CheckNegativeControl(t *testing.T) {
	obs := g12Service{Qualified: true, NIMACVRF: "srl_nokia-network-instance:mac-vrf", NIIPVRF: "srl_nokia-network-instance:ip-vrf",
		SubifBridged: "srl_nokia-interfaces:bridged", VXLANRouted: "srl_nokia-interfaces:routed", EmptyLeafPrimary: []any{nil}}
	good := `{"srl_nokia-network-instance:network-instance": [{"name": "x", "type": "srl_nokia-network-instance:mac-vrf"}],
	  "srl_nokia-interfaces:interface": [{"name": "irb0", "subinterface": [{"index": 1, "type": "srl_nokia-interfaces:routed",
	    "ipv4": {"address": [{"ip-prefix": "10.0.0.1/24", "primary": [null]}]}}]}]}`
	if msgs := checkServiceGoldensAgainstG12(obs, map[string][]byte{"good": []byte(good)}); len(msgs) != 0 {
		t.Errorf("the observed form was refused: %v", msgs)
	}
	for name, bad := range map[string]string{
		"bare ni type":    strings.Replace(good, `"srl_nokia-network-instance:mac-vrf"`, `"mac-vrf"`, 1),
		"wrong module":    strings.Replace(good, `"srl_nokia-interfaces:routed"`, `"srl_nokia-if:routed"`, 1),
		"bare subif type": strings.Replace(good, `"srl_nokia-interfaces:routed"`, `"routed"`, 1),
		"primary true":    strings.Replace(good, `[null]`, `true`, 1),
	} {
		if len(checkServiceGoldensAgainstG12(obs, map[string][]byte{name: []byte(bad)})) == 0 {
			t.Errorf("%s: accepted", name)
		}
	}
	unq := obs
	unq.Qualified = false
	if len(checkServiceGoldensAgainstG12(unq, map[string][]byte{"good": []byte(good)})) == 0 {
		t.Error("an observation that is not module-qualified was accepted")
	}
}

func checkServiceGoldensAgainstG12(obs g12Service, goldens map[string][]byte) []string {
	var msgs []string
	if !obs.Qualified || obs.NIMACVRF == "" || obs.NIIPVRF == "" || obs.SubifBridged == "" || obs.VXLANRouted == "" || len(obs.EmptyLeafPrimary) == 0 {
		return append(msgs, "G12 observation does not record the module-qualified service identities (network_instance_type_mac_vrf/ip_vrf, subinterface_type_bridged, vxlan_interface_type_routed, empty_leaf_primary)")
	}
	prefix := func(v string) string {
		if i := strings.Index(v, ":"); i >= 0 {
			return v[:i+1]
		}
		return ""
	}
	niTypes := []string{obs.NIMACVRF, obs.NIIPVRF}
	// The si-type identities: bridged observed on a subinterface, routed on a
	// vxlan-interface — one leaf type (srl_nokia-interfaces si-type) for both.
	siTypes := []string{obs.SubifBridged, obs.VXLANRouted, prefix(obs.SubifBridged) + "routed", prefix(obs.VXLANRouted) + "bridged"}
	primary, _ := json.Marshal(obs.EmptyLeafPrimary)
	names := make([]string, 0, len(goldens))
	for k := range goldens {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, n := range names {
		var root any
		if err := json.Unmarshal(goldens[n], &root); err != nil {
			msgs = append(msgs, fmt.Sprintf("%s: not JSON: %v", n, err))
			continue
		}
		var walk func(path string, v any)
		walk = func(path string, v any) {
			switch x := v.(type) {
			case map[string]any:
				for k, c := range x {
					name := k[strings.IndexByte(k, ':')+1:]
					switch {
					case name == "type" && strings.HasSuffix(path, "/network-instance"):
						if s, _ := c.(string); !slices.Contains(niTypes, s) {
							msgs = append(msgs, fmt.Sprintf("%s: network-instance type %v is not a G12-observed form %v", n, c, niTypes))
						}
					case name == "type" && (strings.HasSuffix(path, "/subinterface") || strings.HasSuffix(path, "/vxlan-interface")):
						if s, _ := c.(string); !slices.Contains(siTypes, s) {
							msgs = append(msgs, fmt.Sprintf("%s: %s type %v is not in the G12-observed form %v", n, path, c, siTypes))
						}
					case name == "primary":
						if b, _ := json.Marshal(c); !bytes.Equal(b, primary) {
							msgs = append(msgs, fmt.Sprintf("%s: empty leaf primary %s is not the G12-observed %s", n, b, primary))
						}
					}
					walk(path+"/"+name, c)
				}
			case []any:
				for _, e := range x {
					walk(path, e)
				}
			}
		}
		walk("", root)
	}
	return msgs
}

// ---------------------------------------------------------------------------
// Checks every service construct is held to.
// ---------------------------------------------------------------------------

// TestServiceWritesNoPortLevelLeaf: no service render carries a port-level
// leaf — no /interface[name=ethernet-1/N]/admin-state, vlan-tagging or mtu —
// and none of irb0's own: the first leaf written on an interface is under
// subinterface[index] (FR-015, AD-68).
func TestServiceWritesNoPortLevelLeaf(t *testing.T) {
	for name, in := range serviceInputs() {
		for node, r := range renderService(t, in) {
			for _, p := range sortedKeys(flattenService(t, r.JSON)) {
				if !strings.HasPrefix(p, "/interface[") {
					continue
				}
				rest := p[strings.Index(p, "]")+1:]
				if !strings.HasPrefix(rest, "/subinterface[index=") {
					t.Errorf("%s/%s: %s is a port-level leaf — the fabric Config's (AD-68)", name, node, p)
				}
			}
			// The raw document too: an interface entry carries its name and its
			// subinterfaces, nothing else.
			var raw map[string]json.RawMessage
			if err := json.Unmarshal(r.JSON, &raw); err != nil {
				t.Fatal(err)
			}
			var ifs []map[string]json.RawMessage
			if err := json.Unmarshal(raw["srl_nokia-interfaces:interface"], &ifs); err != nil || len(ifs) == 0 {
				t.Fatalf("%s/%s: no interface list: %v", name, node, err)
			}
			for _, e := range ifs {
				for k := range e {
					if k != "name" && k != "subinterface" {
						t.Errorf("%s/%s: interface entry carries %q", name, node, k)
					}
				}
			}
		}
	}
}

// TestServiceInterfaceRefOnEverySubinterface: every subinterface a service
// renders on an access port brings /acl/interface[interface-id=<port>.<idx>]/
// interface-ref {interface, subinterface}, filter or none; and a service
// carrying no access list renders no other acl leaf (FR-015, AD-68).
func TestServiceInterfaceRefOnEverySubinterface(t *testing.T) {
	for name, in := range serviceInputs() {
		for node, r := range renderService(t, in) {
			f := flattenService(t, r.JSON)
			subs := map[string][2]string{}
			for _, p := range sortedKeys(f) {
				if !strings.HasPrefix(p, "/interface[name=ethernet-") {
					continue
				}
				port := p[len("/interface[name="):strings.Index(p, "]")]
				rest := p[strings.Index(p, "]")+1:]
				idx := rest[len("/subinterface[index="):strings.Index(rest, "]")]
				subs[port+"."+idx] = [2]string{port, idx}
			}
			if len(subs) == 0 {
				t.Fatalf("%s/%s: no subinterface rendered", name, node)
			}
			refs := 0
			for id, pi := range subs {
				ai := "/acl/interface[interface-id=" + id + "]/interface-ref"
				want(t, f, ai+"/interface", `"`+pi[0]+`"`)
				want(t, f, ai+"/subinterface", pi[1])
				refs += 2
			}
			n := 0
			for p := range f {
				if strings.HasPrefix(p, "/acl") {
					n++
				}
			}
			if n != refs {
				t.Errorf("%s/%s: %d acl leaves rendered, want exactly the %d interface-ref leaves", name, node, n, refs)
			}
		}
	}
}

// unqualify strips the device's identityref qualification from key
// values so a rendered path compares with the model's register path.
func unqualify(ps []string) []string {
	out := make([]string, 0, len(ps))
	for _, p := range ps {
		out = append(out, identityPrefix.ReplaceAllString(p, "="))
	}
	sort.Strings(out)
	return out
}

// TestServiceRenderedPathsInRegister: the leaf paths extracted from the
// rendered bytes are exactly the renderer's own path set and exactly
// ServiceNode.WritePaths(), which the path-register guard drives, and every
// one is a registered service-owned write path (FR-017).
func TestServiceRenderedPathsInRegister(t *testing.T) {
	for name, in := range serviceInputs() {
		m, err := model.BuildService(in)
		if err != nil {
			t.Fatal(err)
		}
		for i := range m.Nodes {
			node := &m.Nodes[i]
			r, err := srl.RenderServiceNode(node)
			if err != nil {
				t.Fatal(err)
			}
			got := unqualify(sortedKeys(flattenService(t, r.JSON)))
			wantP := node.WritePaths()
			if !slices.Equal(got, wantP) {
				t.Errorf("%s/%s: rendered paths != WritePaths()\n only rendered: %v\n only WritePaths: %v",
					name, node.Node, minus(got, wantP), minus(wantP, got))
			}
			tree, err := srl.ServiceLeafPaths(node)
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(unqualify(tree), got) {
				t.Errorf("%s/%s: renderer's own path set != the rendered document's", name, node.Node)
			}
			if err := register.CheckServicePaths(node.Node, tree); err != nil {
				t.Errorf("%s: %v", name, err)
			}
			if err := register.CheckWrite(tree); err != nil {
				t.Errorf("%s: %v", name, err)
			}
		}
	}
}

// TestServiceRegisterRefusesFabricLeaf: the service check refuses a
// port-level leaf and irb0's admin-state, and an unregistered path.
func TestServiceRegisterRefusesFabricLeaf(t *testing.T) {
	for _, p := range []string{
		"/interface[name=ethernet-1/1]/admin-state", "/interface[name=ethernet-1/1]/vlan-tagging",
		"/interface[name=ethernet-1/1]/mtu", "/interface[name=irb0]/admin-state",
		"/network-instance[name=macvrf-x]/protocols/bgp-evpn/bgp-instance[id=1]/routes/bridge-table/mac-ip/advertise",
	} {
		err := register.CheckServicePaths("leaf01", []string{p})
		var ue *register.UncoveredError
		if !errors.As(err, &ue) || len(ue.Paths) != 1 || ue.Paths[0] != p {
			t.Errorf("%s: not refused as uncovered for a service Config: %v", p, err)
		}
	}
}

// permute returns in with every slice of its intent shuffled.
func permute(rng *rand.Rand, in model.ServiceInput) model.ServiceInput {
	if in.L2 != nil {
		l2 := *in.L2
		l2.Attachments = slices.Clone(l2.Attachments)
		rng.Shuffle(len(l2.Attachments), func(a, b int) { l2.Attachments[a], l2.Attachments[b] = l2.Attachments[b], l2.Attachments[a] })
		in.L2 = &l2
	}
	if in.Gateway != nil {
		gw := *in.Gateway
		gw.IPv4, gw.IPv6 = slices.Clone(gw.IPv4), slices.Clone(gw.IPv6)
		rng.Shuffle(len(gw.IPv4), func(a, b int) { gw.IPv4[a], gw.IPv4[b] = gw.IPv4[b], gw.IPv4[a] })
		rng.Shuffle(len(gw.IPv6), func(a, b int) { gw.IPv6[a], gw.IPv6[b] = gw.IPv6[b], gw.IPv6[a] })
		in.Gateway = &gw
	}
	if in.Routed != nil {
		rs := *in.Routed
		rs.Attachments = slices.Clone(rs.Attachments)
		rng.Shuffle(len(rs.Attachments), func(a, b int) { rs.Attachments[a], rs.Attachments[b] = rs.Attachments[b], rs.Attachments[a] })
		for i := range rs.Attachments {
			a := &rs.Attachments[i]
			a.IPv4, a.IPv6 = slices.Clone(a.IPv4), slices.Clone(a.IPv6)
			rng.Shuffle(len(a.IPv4), func(x, y int) { a.IPv4[x], a.IPv4[y] = a.IPv4[y], a.IPv4[x] })
			rng.Shuffle(len(a.IPv6), func(x, y int) { a.IPv6[x], a.IPv6[y] = a.IPv6[y], a.IPv6[x] })
		}
		in.Routed = &rs
	}
	return in
}

// TestServiceStableBytesAndHash: repeated runs and any permutation of the
// input order render byte-identical documents and hashes (Rule 2, SC-016).
func TestServiceStableBytesAndHash(t *testing.T) {
	rng := rand.New(rand.NewSource(53))
	for name, mk := range map[string]func() model.ServiceInput{
		"vlan": vlanInput, "macvrf": macvrfInput, "macvrf-gw": macvrfGWInput, "ipvrf": ipvrfInput,
	} {
		base := renderService(t, mk())
		for i := 0; i < 5; i++ {
			again := renderService(t, mk())
			for n, r := range base {
				if again[n].Hash != r.Hash || !bytes.Equal(again[n].JSON, r.JSON) {
					t.Fatalf("%s run %d: %s render not stable", name, i, n)
				}
			}
		}
		// More addresses than one make the address order observable.
		in := mk()
		if in.Gateway != nil {
			in.Gateway.IPv4 = []string{"10.30.0.1/24", "10.31.0.1/24", "10.32.0.1/24"}
		}
		if in.Routed != nil {
			in.Routed.Attachments[0].IPv4 = []string{"10.40.1.1/24", "10.40.9.1/24", "10.40.5.1/24"}
		}
		base = renderService(t, in)
		for i := 0; i < 25; i++ {
			got := renderService(t, permute(rng, in))
			for n, r := range base {
				if got[n].Hash != r.Hash || !bytes.Equal(got[n].JSON, r.JSON) {
					t.Fatalf("%s permutation %d: %s hash %s != %s", name, i, n, got[n].Hash, r.Hash)
				}
			}
		}
		for n, r := range base {
			if len(r.Hash) != 64 {
				t.Errorf("%s/%s: hash %q is not a sha256 hex digest", name, n, r.Hash)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// The `vlan` construct.
// ---------------------------------------------------------------------------

// TestVLANConstruct: a `vlan` renders a mac-vrf network-instance vlan-<id>
// with bridged subinterfaces and never a vxlan-interface, an EVPN instance or
// a route target (Rule 11).
func TestVLANConstruct(t *testing.T) {
	r := renderService(t, vlanInput())
	if !slices.Equal(sortedKeysR(r), leaves) {
		t.Fatalf("rendered on %v, want %v", sortedKeysR(r), leaves)
	}
	for _, node := range leaves {
		f := flattenService(t, r[node].JSON)
		ni := "/network-instance[name=vlan-web]"
		want(t, f, ni+"/type", `"srl_nokia-network-instance:mac-vrf"`)
		want(t, f, ni+"/admin-state", `"enable"`)
		want(t, f, ni+"/description", `"Service web (vlan)"`)
		want(t, f, ni+"/interface[name=ethernet-1/1.110]", "{}")
		sub := "/interface[name=ethernet-1/1]/subinterface[index=110]"
		want(t, f, sub+"/type", `"srl_nokia-interfaces:bridged"`)
		want(t, f, sub+"/admin-state", `"enable"`)
		want(t, f, sub+"/vlan/encap/single-tagged/vlan-id", "110")
		want(t, f, sub+"/l2-mtu", "9412") // bridgedL2MTU (data-model.md §20)
		for p := range f {
			for _, forbidden := range []string{"vxlan-interface", "bgp-evpn", "bgp-vpn", "route-target", "/tunnel-interface", "irb0", "/ipv4", "/ipv6"} {
				if strings.Contains(p, forbidden) {
					t.Errorf("%s: a vlan renders no %s: %s", node, forbidden, p)
				}
			}
		}
		for _, s := range []string{"vxlan", "bgp-evpn", "bgp-vpn", "target:"} {
			if strings.Contains(string(r[node].JSON), s) {
				t.Errorf("%s: %q in a vlan render", node, s)
			}
		}
		// Exactly one network-instance.
		n := 0
		for p := range f {
			if strings.HasPrefix(p, "/network-instance[") && strings.HasSuffix(p, "]/type") {
				n++
			}
		}
		if n != 1 {
			t.Errorf("%s: %d network-instances, want 1", node, n)
		}
	}
}

func sortedKeysR(m map[string]*srl.Rendered) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
