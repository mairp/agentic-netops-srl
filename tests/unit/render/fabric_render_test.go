// T027 — the fabric render goldens and the per-construct assertions of the
// priority-10 fabric Config (FR-011, FR-014, FR-015, R-37, AD-06, AD-43, AD-68).
//
// The golden files under tests/golden/fabric/ are frozen (T047) in the
// identityref serialization gate item G12 observed from a real device and
// recorded in tests/gate/observed/serialization.json (R-36, AD-31, AD-81);
// TestFabricGoldensFrozenAgainstG12 holds them to it.
//
// Regenerate the goldens with:
//
//	go test ./tests/unit/render/ -run TestFabricGoldens -update
package render_test

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"testing"

	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/render/srl"
	"github.com/mairp/agentic-netops-srl/pkg/register"
	"github.com/mairp/agentic-netops-srl/pkg/sdc"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

var update = flag.Bool("update", false, "regenerate tests/golden/fabric/*.json")

const (
	goldenDir      = "../../golden/fabric"
	provisional    = "../../golden/fabric/PROVISIONAL.md"
	g12Observation = "../../gate/observed/serialization.json"
)

var nodes = []string{"leaf01", "leaf02", "spine01", "spine02"}

// defaultInput is the default Fabric of data-model.md §3a / examples/fabric/fabric01.yaml
// with its claims bound: loopbacks from fabric01-loopback, ASNs from
// fabric01-underlay, and the four link /31s from fabric01-p2p (10.1.0.0/24),
// the spine end taking the even address.
func defaultInput() model.FabricInput {
	return model.FabricInput{
		Name: "fabric01", FabricASN: 65000, InterASVPN: true, ReflectorClients: true,
		AddressFamilies: []model.AddressFamily{model.FamilyUnderlayIPv4, model.FamilyUnderlayIPv6},
		MTU:             model.FabricMTU{PortMTU: 9412, UnderlayIPMTU: 9398, BridgedL2MTU: 9412, TenantIPMTU: 9348},
		Nodes: []model.FabricNodeInput{
			{Name: "spine01", Role: model.RoleSpine, SystemIPv4: "10.0.0.11/32", ASN: 65100, RouteReflector: true},
			{Name: "spine02", Role: model.RoleSpine, SystemIPv4: "10.0.0.12/32", ASN: 65100, RouteReflector: true},
			{Name: "leaf01", Role: model.RoleLeaf, SystemIPv4: "10.0.0.1/32", ASN: 65101},
			{Name: "leaf02", Role: model.RoleLeaf, SystemIPv4: "10.0.0.2/32", ASN: 65102},
		},
		Links: []model.FabricLink{
			{A: model.LinkEnd{Node: "leaf01", Port: "ethernet-1/49", IPv4: "10.1.0.1/31"}, B: model.LinkEnd{Node: "spine01", Port: "ethernet-1/1", IPv4: "10.1.0.0/31"}},
			{A: model.LinkEnd{Node: "leaf01", Port: "ethernet-1/50", IPv4: "10.1.0.3/31"}, B: model.LinkEnd{Node: "spine02", Port: "ethernet-1/1", IPv4: "10.1.0.2/31"}},
			{A: model.LinkEnd{Node: "leaf02", Port: "ethernet-1/49", IPv4: "10.1.0.5/31"}, B: model.LinkEnd{Node: "spine01", Port: "ethernet-1/2", IPv4: "10.1.0.4/31"}},
			{A: model.LinkEnd{Node: "leaf02", Port: "ethernet-1/50", IPv4: "10.1.0.7/31"}, B: model.LinkEnd{Node: "spine02", Port: "ethernet-1/2", IPv4: "10.1.0.6/31"}},
		},
		Inventory: []model.InventoryEntry{
			{Node: "leaf01", AccessPorts: []string{"ethernet-1/1"}, FabricPorts: []string{"ethernet-1/49", "ethernet-1/50"}},
			{Node: "leaf02", AccessPorts: []string{"ethernet-1/1"}, FabricPorts: []string{"ethernet-1/49", "ethernet-1/50"}},
			{Node: "spine01", FabricPorts: []string{"ethernet-1/1", "ethernet-1/2"}},
			{Node: "spine02", FabricPorts: []string{"ethernet-1/1", "ethernet-1/2"}},
		},
	}
}

// withUntagged adds a second, untagged access port on leaf01.
func withUntagged(in model.FabricInput) model.FabricInput {
	in.Inventory = slices.Clone(in.Inventory)
	in.Inventory[0] = model.InventoryEntry{Node: "leaf01",
		AccessPorts: []string{"ethernet-1/1", "ethernet-1/2"}, UntaggedAccessPorts: []string{"ethernet-1/2"},
		FabricPorts: []string{"ethernet-1/49", "ethernet-1/50"}}
	return in
}

func render(t *testing.T, in model.FabricInput) map[string]*srl.Rendered {
	t.Helper()
	m, err := model.BuildFabric(in)
	if err != nil {
		t.Fatalf("BuildFabric: %v", err)
	}
	r, err := srl.RenderFabric(m)
	if err != nil {
		t.Fatalf("RenderFabric: %v", err)
	}
	if len(r) != len(in.Nodes) {
		t.Fatalf("rendered %d nodes, want %d", len(r), len(in.Nodes))
	}
	return r
}

// ---------------------------------------------------------------------------
// An extractor independent of the renderer: JSON bytes -> concrete leaf paths.
// ---------------------------------------------------------------------------

// listKeys are the keys of every list the fabric render may contain, in key
// order (srl_nokia models @ v25.7.1, evidence/02-evpn-constructs.md).
var listKeys = map[string][]string{
	"interface": {"name"}, "subinterface": {"index"}, "address": {"ip-prefix"},
	"network-instance": {"name"}, "afi-safi": {"afi-safi-name"}, "group": {"group-name"},
	"neighbor": {"peer-address"}, "prefix-set": {"name"}, "prefix": {"ip-prefix", "mask-length-range"},
	"policy": {"name"}, "statement": {"name"}, "tunnel-interface": {"name"}, "vxlan-interface": {"index"},
}

// flatten returns path -> JSON value of every leaf and leaf-list, plus every
// key-only list entry (value "{}"). Node names lose their module qualifier.
func flatten(t *testing.T, doc []byte) map[string]string {
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
				walk(p, x, nil)
			case []any:
				if len(x) > 0 {
					if _, isObj := x[0].(map[string]any); !isObj {
						b, _ := json.Marshal(x)
						out[p] = string(b)
						continue
					}
				}
				keys, ok := listKeys[name]
				if !ok {
					t.Fatalf("%s: a list the fabric render has no business emitting", p)
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

func leaf(t *testing.T, flat map[string]string, path string) string {
	t.Helper()
	v, ok := flat[path]
	if !ok {
		t.Errorf("missing %s", path)
	}
	return v
}

func want(t *testing.T, flat map[string]string, path, value string) {
	t.Helper()
	if v, ok := flat[path]; !ok {
		t.Errorf("missing %s (want %s)", path, value)
	} else if v != value {
		t.Errorf("%s = %s, want %s", path, v, value)
	}
}

type change struct{ node, path, from, to string }

func diff(t *testing.T, a, b map[string]*srl.Rendered) []change {
	t.Helper()
	var out []change
	for _, n := range nodes {
		fa, fb := flatten(t, a[n].JSON), flatten(t, b[n].JSON)
		for p, v := range fa {
			if w, ok := fb[p]; !ok || w != v {
				out = append(out, change{n, p, v, fb[p]})
			}
		}
		for p, w := range fb {
			if _, ok := fa[p]; !ok {
				out = append(out, change{n, p, "", w})
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].node+out[i].path < out[j].node+out[j].path })
	return out
}

const evpnAFI = "/network-instance[name=default]/protocols/bgp/afi-safi[afi-safi-name=srl_nokia-common:evpn]"

// ---------------------------------------------------------------------------
// Goldens.
// ---------------------------------------------------------------------------

func TestFabricGoldens(t *testing.T) {
	r := render(t, defaultInput())
	for _, n := range nodes {
		path := filepath.Join(goldenDir, n+".json")
		if *update {
			if err := os.MkdirAll(goldenDir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, r[n].JSON, 0o644); err != nil {
				t.Fatal(err)
			}
			continue
		}
		golden, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("golden %s: %v (regenerate with -update)", path, err)
		}
		if !bytes.Equal(golden, r[n].JSON) {
			t.Errorf("%s: render differs from golden %s (regenerate with -update after review)\n--- got ---\n%s", n, path, r[n].JSON)
		}
	}
}

// TestFabricGoldensFrozenAgainstG12: the goldens are frozen (T047) in the
// identityref form gate item G12 observed from a real device Get and recorded
// in tests/gate/observed/serialization.json (AD-81). The provisional marker is
// gone, and every identityref the goldens carry that G12 observed — the BGP
// family key and the network-instance type — is in the observed form; a bare
// (unprefixed) value is refused.
func TestFabricGoldensFrozenAgainstG12(t *testing.T) {
	if _, err := os.Stat(provisional); err == nil {
		t.Fatalf("%s still exists: T047 froze the goldens against G12 and removed the marker", provisional)
	}
	b, err := os.ReadFile(g12Observation)
	if err != nil {
		t.Fatalf("G12 observation %s unreadable (%v): the goldens are frozen against it", g12Observation, err)
	}
	var obs struct {
		Summary struct {
			Qualified   bool     `json:"identityref_values_module_qualified"`
			AfiSafiEVPN []string `json:"afi_safi_name_evpn"`
			NIDefault   string   `json:"network_instance_type_default"`
		} `json:"summary"`
	}
	if err := json.Unmarshal(b, &obs); err != nil {
		t.Fatalf("%s: %v", g12Observation, err)
	}
	for _, msg := range checkGoldensAgainstG12(t, obs.Summary.Qualified, obs.Summary.AfiSafiEVPN, obs.Summary.NIDefault, readGoldens(t)) {
		t.Error(msg)
	}
}

// TestFabricGoldensG12CheckNegativeControl: the freeze check fails on a golden
// carrying the bare form, and on an observation that is not module-qualified.
func TestFabricGoldensG12CheckNegativeControl(t *testing.T) {
	bare := map[string]string{"leaf01": `{"afi-safi-name": "evpn", "type": "srl_nokia-network-instance:default"}`}
	if len(checkGoldensAgainstG12(t, true, []string{"srl_nokia-common:evpn"}, "srl_nokia-network-instance:default", bare)) == 0 {
		t.Error("a golden carrying the bare afi-safi-name was accepted")
	}
	good := map[string]string{"leaf01": `{"afi-safi-name": "srl_nokia-common:evpn", "type": "srl_nokia-network-instance:default"}`}
	if len(checkGoldensAgainstG12(t, false, []string{"srl_nokia-common:evpn"}, "srl_nokia-network-instance:default", good)) == 0 {
		t.Error("an observation that is not module-qualified was accepted")
	}
	if msgs := checkGoldensAgainstG12(t, true, []string{"srl_nokia-common:evpn"}, "srl_nokia-network-instance:default", good); len(msgs) != 0 {
		t.Errorf("the observed form was refused: %v", msgs)
	}
}

func readGoldens(t *testing.T) map[string]string {
	t.Helper()
	out := map[string]string{}
	for _, n := range nodes {
		b, err := os.ReadFile(filepath.Join(goldenDir, n+".json"))
		if err != nil {
			t.Fatal(err)
		}
		out[n] = string(b)
	}
	return out
}

var (
	afiSafiNameRE = regexp.MustCompile(`"afi-safi-name":\s*"([^"]*)"`)
	niTypeRE      = regexp.MustCompile(`"type":\s*"([^"]*default)"`)
)

func checkGoldensAgainstG12(t *testing.T, qualified bool, afiEVPN []string, niDefault string, goldens map[string]string) []string {
	t.Helper()
	var msgs []string
	if !qualified || len(afiEVPN) == 0 || niDefault == "" {
		return append(msgs, "G12 observation does not record module-qualified identityrefs (identityref_values_module_qualified, afi_safi_name_evpn, network_instance_type_default)")
	}
	prefix := func(v string) string { return v[:strings.Index(v, ":")+1] }
	afiPrefix, niPrefix := prefix(afiEVPN[0]), prefix(niDefault)
	names := make([]string, 0, len(goldens))
	for k := range goldens {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, n := range names {
		g := goldens[n]
		for _, m := range afiSafiNameRE.FindAllStringSubmatch(g, -1) {
			if afiPrefix == "" || !strings.HasPrefix(m[1], afiPrefix) {
				msgs = append(msgs, fmt.Sprintf("%s: afi-safi-name %q is not in the G12-observed form %q", n, m[1], afiEVPN[0]))
			}
		}
		if strings.Contains(g, `"afi-safi-name"`) && !strings.Contains(g, `"`+afiEVPN[0]+`"`) {
			msgs = append(msgs, fmt.Sprintf("%s: carries no %q, the EVPN family as G12 observed it", n, afiEVPN[0]))
		}
		for _, m := range niTypeRE.FindAllStringSubmatch(g, -1) {
			if !strings.HasPrefix(m[1], niPrefix) || niPrefix == "" {
				msgs = append(msgs, fmt.Sprintf("%s: network-instance type %q is not in the G12-observed form %q", n, m[1], niDefault))
			}
		}
	}
	return msgs
}

// ---------------------------------------------------------------------------
// Per-construct assertions.
// ---------------------------------------------------------------------------

var fabricPorts = map[string][]string{
	"leaf01": {"ethernet-1/49", "ethernet-1/50"}, "leaf02": {"ethernet-1/49", "ethernet-1/50"},
	"spine01": {"ethernet-1/1", "ethernet-1/2"}, "spine02": {"ethernet-1/1", "ethernet-1/2"},
}

func TestFabricPortsMTUAndRoutedSubinterface(t *testing.T) {
	r := render(t, defaultInput())
	for _, n := range nodes {
		f := flatten(t, r[n].JSON)
		for _, p := range fabricPorts[n] {
			ifc := "/interface[name=" + p + "]"
			want(t, f, ifc+"/admin-state", `"enable"`)
			want(t, f, ifc+"/mtu", "9412")
			sub := ifc + "/subinterface[index=0]"
			want(t, f, sub+"/ip-mtu", "9398")
			want(t, f, sub+"/ipv4/admin-state", `"enable"`)
			want(t, f, sub+"/ipv6/admin-state", `"enable"`)
			want(t, f, "/network-instance[name=default]/interface[name="+p+".0]", "{}")
			if f[ifc+"/vlan-tagging"] != "" {
				t.Errorf("%s %s: a fabric port renders no vlan-tagging", n, p)
			}
		}
	}
	// Exact addresses on one link, both ends: IPv4 claimed, IPv6 derived.
	want(t, flatten(t, r["leaf01"].JSON), "/interface[name=ethernet-1/49]/subinterface[index=0]/ipv4/address[ip-prefix=10.1.0.1/31]", "{}")
	want(t, flatten(t, r["leaf01"].JSON), "/interface[name=ethernet-1/49]/subinterface[index=0]/ipv6/address[ip-prefix=fd00:1::a01:1/127]", "{}")
	want(t, flatten(t, r["spine01"].JSON), "/interface[name=ethernet-1/1]/subinterface[index=0]/ipv4/address[ip-prefix=10.1.0.0/31]", "{}")
	want(t, flatten(t, r["spine01"].JSON), "/interface[name=ethernet-1/1]/subinterface[index=0]/ipv6/address[ip-prefix=fd00:1::a01:0/127]", "{}")
}

var systemIPv4 = map[string]string{"leaf01": "10.0.0.1", "leaf02": "10.0.0.2", "spine01": "10.0.0.11", "spine02": "10.0.0.12"}
var systemIPv6 = map[string]string{"leaf01": "fd00::a00:1", "leaf02": "fd00::a00:2", "spine01": "fd00::a00:b", "spine02": "fd00::a00:c"}

func TestSystem0IsVTEPSourceAndRouterID(t *testing.T) {
	r := render(t, defaultInput())
	for _, n := range nodes {
		f := flatten(t, r[n].JSON)
		sub := "/interface[name=system0]/subinterface[index=0]"
		want(t, f, "/interface[name=system0]/admin-state", `"enable"`)
		want(t, f, sub+"/ipv4/address[ip-prefix="+systemIPv4[n]+"/32]", "{}")
		want(t, f, sub+"/ipv6/address[ip-prefix="+systemIPv6[n]+"/128]", "{}")
		want(t, f, "/network-instance[name=default]/interface[name=system0.0]", "{}")
		want(t, f, "/network-instance[name=default]/protocols/bgp/router-id", `"`+systemIPv4[n]+`"`)
		want(t, f, "/network-instance[name=default]/type", `"srl_nokia-network-instance:default"`)
		// Leaves carry the tunnel-interface vxlan0 whose vxlan-interfaces source
		// from system0.0's IPv4 (use-system-ipv4-address, the only source the
		// image supports); spines terminate no tenant VXLAN.
		_, hasVX := f["/tunnel-interface[name=vxlan0]"]
		if strings.HasPrefix(n, "leaf") != hasVX {
			t.Errorf("%s: tunnel-interface vxlan0 rendered=%v", n, hasVX)
		}
		for p := range f {
			if strings.HasPrefix(p, "/tunnel-interface") && p != "/tunnel-interface[name=vxlan0]" {
				t.Errorf("%s: the fabric renders no vxlan-interface: %s", n, p)
			}
		}
	}
}

func TestDualStackPerLinkEBGPUnderlay(t *testing.T) {
	in := defaultInput()
	r := render(t, in)
	asn := map[string]string{"leaf01": "65101", "leaf02": "65102", "spine01": "65100", "spine02": "65100"}
	bgp := "/network-instance[name=default]/protocols/bgp"
	for _, l := range in.Links {
		for _, pair := range [][2]model.LinkEnd{{l.A, l.B}, {l.B, l.A}} {
			self, peer := pair[0], pair[1]
			f := flatten(t, r[self.Node].JSON)
			peer4 := strings.Split(peer.IPv4, "/")[0]
			p6, _ := model.DeriveLinkIPv6(peer.IPv4)
			peer6 := strings.Split(p6, "/")[0]
			want(t, f, bgp+"/neighbor[peer-address="+peer4+"]/peer-group", `"underlay"`)
			want(t, f, bgp+"/neighbor[peer-address="+peer4+"]/peer-as", asn[peer.Node])
			want(t, f, bgp+"/neighbor[peer-address="+peer6+"]/peer-group", `"underlay-v6"`)
			want(t, f, bgp+"/neighbor[peer-address="+peer6+"]/peer-as", asn[peer.Node])
		}
	}
	for _, n := range nodes {
		f := flatten(t, r[n].JSON)
		want(t, f, bgp+"/autonomous-system", asn[n])
		for _, afi := range []string{"ipv4-unicast", "ipv6-unicast", "evpn"} {
			want(t, f, bgp+"/afi-safi[afi-safi-name=srl_nokia-common:"+afi+"]/admin-state", `"enable"`)
		}
		for g, only := range map[string]string{"underlay": "ipv4-unicast", "underlay-v6": "ipv6-unicast", "overlay": "evpn"} {
			for _, afi := range []string{"ipv4-unicast", "ipv6-unicast", "evpn"} {
				st := `"disable"`
				if afi == only {
					st = `"enable"`
				}
				want(t, f, bgp+"/group[group-name="+g+"]/afi-safi[afi-safi-name=srl_nokia-common:"+afi+"]/admin-state", st)
			}
		}
		// The underlay routing policy on both underlay groups.
		for _, g := range []string{"underlay", "underlay-v6"} {
			want(t, f, bgp+"/group[group-name="+g+"]/export-policy", `["system-loopbacks-policy"]`)
			want(t, f, bgp+"/group[group-name="+g+"]/import-policy", `["system-loopbacks-policy"]`)
		}
		st := "/routing-policy/policy[name=system-loopbacks-policy]/statement[name=1]"
		want(t, f, st+"/match/prefix/prefix-set", `"system-loopbacks"`)
		want(t, f, st+"/action/policy-result", `"accept"`)
		for _, m := range nodes {
			want(t, f, "/routing-policy/prefix-set[name=system-loopbacks]/prefix[ip-prefix="+systemIPv4[m]+"/32][mask-length-range=32..32]", "{}")
			want(t, f, "/routing-policy/prefix-set[name=system-loopbacks]/prefix[ip-prefix="+systemIPv6[m]+"/128][mask-length-range=128..128]", "{}")
		}
	}
}

func TestIBGPEVPNOverlayToBothReflectingSpines(t *testing.T) {
	r := render(t, defaultInput())
	bgp := "/network-instance[name=default]/protocols/bgp"
	for _, n := range nodes {
		f := flatten(t, r[n].JSON)
		want(t, f, bgp+"/group[group-name=overlay]/peer-as", "65000")
		want(t, f, bgp+"/group[group-name=overlay]/local-as/as-number", "65000")
		var peers []string
		if strings.HasPrefix(n, "leaf") {
			peers = []string{"spine01", "spine02"}
			if _, ok := f[evpnAFI+"/evpn/inter-as-vpn"]; ok {
				t.Errorf("%s: inter-as-vpn is a reflecting spine's setting", n)
			}
			if _, ok := f[bgp+"/group[group-name=overlay]/route-reflector/client"]; ok {
				t.Errorf("%s: a leaf is no route reflector", n)
			}
		} else {
			peers = []string{"leaf01", "leaf02"}
			want(t, f, evpnAFI+"/evpn/inter-as-vpn", "true")
			want(t, f, bgp+"/group[group-name=overlay]/route-reflector/client", "true")
		}
		for _, p := range peers {
			nb := bgp + "/neighbor[peer-address=" + systemIPv4[p] + "]"
			want(t, f, nb+"/peer-group", `"overlay"`)
			want(t, f, nb+"/transport/local-address", `"`+systemIPv4[n]+`"`)
		}
	}
}

func TestMaintenanceDisablesExactlyThatPort(t *testing.T) {
	base := render(t, defaultInput())
	in := defaultInput()
	in.Maintenance = []model.MaintenanceEntry{{Node: "leaf01", Interface: "ethernet-1/49", AdminState: "disable"}}
	m := render(t, in)
	d := diff(t, base, m)
	if len(d) != 1 || d[0] != (change{"leaf01", "/interface[name=ethernet-1/49]/admin-state", `"enable"`, `"disable"`}) {
		t.Fatalf("maintenance[] must change exactly /interface[name=ethernet-1/49]/admin-state on leaf01, got %+v", d)
	}
	// Removing the entry restores enable, byte for byte.
	in.Maintenance = nil
	restored := render(t, in)
	for _, n := range nodes {
		if restored[n].Hash != base[n].Hash {
			t.Errorf("%s: removing the maintenance entry did not restore the render", n)
		}
	}
	want(t, flatten(t, restored["leaf01"].JSON), "/interface[name=ethernet-1/49]/admin-state", `"enable"`)
}

func TestInterASVPNFalseChangesOnlyThatLeafOnBothSpines(t *testing.T) {
	on := render(t, defaultInput())
	in := defaultInput()
	in.InterASVPN = false
	off := render(t, in)
	d := diff(t, on, off)
	wantD := []change{
		{"spine01", evpnAFI + "/evpn/inter-as-vpn", "true", "false"},
		{"spine02", evpnAFI + "/evpn/inter-as-vpn", "true", "false"},
	}
	if !slices.Equal(d, wantD) {
		t.Fatalf("interASVPN=false must render inter-as-vpn false on both reflecting spines and change nothing else (AD-43):\n got %+v\nwant %+v", d, wantD)
	}
	for _, n := range []string{"leaf01", "leaf02"} {
		if on[n].Hash != off[n].Hash {
			t.Errorf("%s: render changed with interASVPN", n)
		}
	}
	in.InterASVPN = true
	back := render(t, in)
	for _, n := range nodes {
		if back[n].Hash != on[n].Hash {
			t.Errorf("%s: interASVPN=true did not restore the render", n)
		}
	}
}

// reflectorClients=false renders route-reflector client false on the overlay
// group of both reflecting spines — stated, never dropped — and changes nothing
// else; true restores the render byte for byte (AD-77).
func TestReflectorClientsFalseChangesOnlyThatLeafOnBothSpines(t *testing.T) {
	on := render(t, defaultInput())
	in := defaultInput()
	in.ReflectorClients = false
	off := render(t, in)
	d := diff(t, on, off)
	rr := "/network-instance[name=default]/protocols/bgp/group[group-name=overlay]/route-reflector/client"
	wantD := []change{
		{"spine01", rr, "true", "false"},
		{"spine02", rr, "true", "false"},
	}
	if !slices.Equal(d, wantD) {
		t.Fatalf("reflectorClients=false must render route-reflector client false on both reflecting spines and change nothing else (AD-77):\n got %+v\nwant %+v", d, wantD)
	}
	for _, n := range []string{"spine01", "spine02"} {
		want(t, flatten(t, off[n].JSON), rr, "false")
	}
	for _, n := range []string{"leaf01", "leaf02"} {
		if on[n].Hash != off[n].Hash {
			t.Errorf("%s: render changed with reflectorClients", n)
		}
	}
	in.ReflectorClients = true
	back := render(t, in)
	for _, n := range nodes {
		if back[n].Hash != on[n].Hash {
			t.Errorf("%s: reflectorClients=true did not restore the render", n)
		}
	}
}

func TestAccessPortsPortLevelLeavesOnly(t *testing.T) {
	base := render(t, withUntagged(defaultInput()))
	l1 := flatten(t, base["leaf01"].JSON)
	want(t, l1, "/interface[name=ethernet-1/1]/admin-state", `"enable"`)
	want(t, l1, "/interface[name=ethernet-1/1]/vlan-tagging", "true")
	want(t, l1, "/interface[name=ethernet-1/2]/admin-state", `"enable"`)
	want(t, l1, "/interface[name=ethernet-1/2]/vlan-tagging", "false")
	want(t, flatten(t, base["leaf02"].JSON), "/interface[name=ethernet-1/1]/vlan-tagging", "true")
	// the port MTU on every access port too: a service subinterface's tenant
	// ip-mtu (9348) does not fit under the device default of 9232 (live finding
	// 2026-09-21-access-port-mtu)
	want(t, l1, "/interface[name=ethernet-1/1]/mtu", "9412")
	want(t, l1, "/interface[name=ethernet-1/2]/mtu", "9412")
	want(t, flatten(t, base["leaf02"].JSON), "/interface[name=ethernet-1/1]/mtu", "9412")
	for _, n := range []string{"leaf01", "leaf02"} {
		f := flatten(t, base[n].JSON)
		for p := range f {
			for _, port := range []string{"ethernet-1/1", "ethernet-1/2"} {
				ifc := "/interface[name=" + port + "]"
				if strings.HasPrefix(p, ifc) && p != ifc+"/admin-state" && p != ifc+"/vlan-tagging" && p != ifc+"/mtu" {
					t.Errorf("%s: access port %s renders %s — only its port-level leaves are the fabric's (AD-68)", n, port, p)
				}
			}
		}
	}
	// A maintenance entry on an access port is the only thing that renders its
	// admin-state disable.
	in := withUntagged(defaultInput())
	in.Maintenance = []model.MaintenanceEntry{{Node: "leaf01", Interface: "ethernet-1/1", AdminState: "disable"}}
	d := diff(t, base, render(t, in))
	if len(d) != 1 || d[0] != (change{"leaf01", "/interface[name=ethernet-1/1]/admin-state", `"enable"`, `"disable"`}) {
		t.Fatalf("maintenance on an access port: got %+v", d)
	}
	for _, n := range nodes {
		for p, v := range flatten(t, base[n].JSON) {
			if strings.HasSuffix(p, "]/admin-state") && strings.HasPrefix(p, "/interface[") && v != `"enable"` {
				t.Errorf("%s: %s = %s without a maintenance entry", n, p, v)
			}
		}
	}
}

func TestIRB0AdminStateOncePerLeafNoneOnSpines(t *testing.T) {
	r := render(t, withUntagged(defaultInput()))
	for _, n := range nodes {
		f := flatten(t, r[n].JSON)
		var irb []string
		for p := range f {
			if strings.HasPrefix(p, "/interface[name=irb0]") {
				irb = append(irb, p)
			}
		}
		if strings.HasPrefix(n, "leaf") {
			if len(irb) != 1 || irb[0] != "/interface[name=irb0]/admin-state" || f[irb[0]] != `"enable"` {
				t.Errorf("%s: want exactly /interface[name=irb0]/admin-state enable, got %v", n, irb)
			}
			if c := strings.Count(string(r[n].JSON), `"name": "irb0"`); c != 1 {
				t.Errorf("%s: irb0 rendered %d times", n, c)
			}
		} else if len(irb) != 0 {
			t.Errorf("%s: a spine renders no irb0: %v", n, irb)
		}
	}
}

func TestNothingOfAServiceRendered(t *testing.T) {
	r := render(t, withUntagged(defaultInput()))
	for _, n := range nodes {
		f := flatten(t, r[n].JSON)
		for p := range f {
			switch {
			case strings.HasPrefix(p, "/network-instance[") && !strings.HasPrefix(p, "/network-instance[name=default]"):
				t.Errorf("%s: service network-instance rendered: %s", n, p)
			case strings.Contains(p, "/vxlan-interface"):
				t.Errorf("%s: vxlan-interface rendered: %s", n, p)
			case strings.HasPrefix(p, "/acl"):
				t.Errorf("%s: acl rendered: %s", n, p)
			case strings.HasPrefix(p, "/interface[name=irb0]/subinterface"):
				t.Errorf("%s: irb0 subinterface rendered: %s", n, p)
			case strings.Contains(p, "/subinterface[index=") && !strings.Contains(p, "/subinterface[index=0]"):
				t.Errorf("%s: tagged subinterface rendered: %s", n, p)
			case strings.HasPrefix(p, "/interface[name=ethernet-1/1]/subinterface") && strings.HasPrefix(n, "leaf"),
				strings.HasPrefix(p, "/interface[name=ethernet-1/2]/subinterface") && strings.HasPrefix(n, "leaf"):
				t.Errorf("%s: access-port subinterface rendered: %s", n, p)
			}
		}
		for _, s := range []string{"mac-vrf", "ip-vrf", "bgp-evpn", "bgp-vpn", "route-target"} {
			if strings.Contains(string(r[n].JSON), s) {
				t.Errorf("%s: service construct %q in the fabric render", n, s)
			}
		}
	}
}

// TestStableNamesAndHash: repeated runs and any permutation of the input
// (nodes, links, link ends, inventory, access ports) render byte-identical
// documents and hashes (FR-011, FR-014).
func TestStableNamesAndHash(t *testing.T) {
	base := render(t, withUntagged(defaultInput()))
	for i := 0; i < 5; i++ {
		again := render(t, withUntagged(defaultInput()))
		for _, n := range nodes {
			if again[n].Hash != base[n].Hash || !bytes.Equal(again[n].JSON, base[n].JSON) {
				t.Fatalf("run %d: %s render not stable", i, n)
			}
		}
	}
	rng := rand.New(rand.NewSource(42))
	for i := 0; i < 25; i++ {
		in := withUntagged(defaultInput())
		rng.Shuffle(len(in.Nodes), func(a, b int) { in.Nodes[a], in.Nodes[b] = in.Nodes[b], in.Nodes[a] })
		rng.Shuffle(len(in.Links), func(a, b int) { in.Links[a], in.Links[b] = in.Links[b], in.Links[a] })
		for j := range in.Links {
			if rng.Intn(2) == 0 {
				in.Links[j].A, in.Links[j].B = in.Links[j].B, in.Links[j].A
			}
		}
		rng.Shuffle(len(in.Inventory), func(a, b int) { in.Inventory[a], in.Inventory[b] = in.Inventory[b], in.Inventory[a] })
		for j := range in.Inventory {
			ap := slices.Clone(in.Inventory[j].AccessPorts)
			rng.Shuffle(len(ap), func(a, b int) { ap[a], ap[b] = ap[b], ap[a] })
			in.Inventory[j].AccessPorts = ap
		}
		got := render(t, in)
		for _, n := range nodes {
			if got[n].Hash != base[n].Hash {
				t.Fatalf("permutation %d: %s hash %s != %s", i, n, got[n].Hash, base[n].Hash)
			}
		}
	}
	if len(base["leaf01"].Hash) != 64 {
		t.Errorf("hash %q is not a sha256 hex digest", base["leaf01"].Hash)
	}
}

// identityPrefix strips the device's identityref qualification from a key
// value so a rendered path compares with the model's register path.
var identityPrefix = regexp.MustCompile(`=srl_nokia-[a-z-]+:`)

// TestRenderedPathsEqualWritePaths: the leaf paths extracted from the rendered
// JSON bytes are exactly FabricNode.WritePaths(), which the path-register guard
// (pkg/register) drives — so the guard covers the render, not a sibling list.
func TestRenderedPathsEqualWritePaths(t *testing.T) {
	variants := map[string]model.FabricInput{"default": defaultInput(), "untagged": withUntagged(defaultInput())}
	v := defaultInput()
	v.InterASVPN = false
	v.Maintenance = []model.MaintenanceEntry{{Node: "spine02", Interface: "ethernet-1/2", AdminState: "disable"}}
	variants["interASVPN-false+maintenance"] = v
	rc := defaultInput()
	rc.ReflectorClients = false
	variants["reflectorClients-false"] = rc
	v4 := defaultInput()
	v4.AddressFamilies = []model.AddressFamily{model.FamilyUnderlayIPv4}
	variants["ipv4-only"] = v4
	for name, in := range variants {
		m, err := model.BuildFabric(in)
		if err != nil {
			t.Fatal(err)
		}
		for i := range m.Nodes {
			node := &m.Nodes[i]
			r, err := srl.RenderFabricNode(node)
			if err != nil {
				t.Fatal(err)
			}
			var got []string
			for p := range flatten(t, r.JSON) {
				got = append(got, identityPrefix.ReplaceAllString(p, "="))
			}
			sort.Strings(got)
			wantP := node.WritePaths()
			if !slices.Equal(got, wantP) {
				t.Errorf("%s/%s: rendered paths != WritePaths()\n only rendered: %v\n only WritePaths: %v",
					name, node.Name, minus(got, wantP), minus(wantP, got))
			}
			tree, err := srl.FabricLeafPaths(node)
			if err != nil {
				t.Fatal(err)
			}
			var treeN []string
			for _, p := range tree {
				treeN = append(treeN, identityPrefix.ReplaceAllString(p, "="))
			}
			if !slices.Equal(treeN, wantP) {
				t.Errorf("%s/%s: renderer's own path set != WritePaths()", name, node.Name)
			}
			if err := register.CheckFabricPaths(node.Name, tree); err != nil {
				t.Errorf("%s: %v", name, err)
			}
		}
	}
	// ipv4-only renders no IPv6 at all.
	for _, r := range render(t, v4) {
		if strings.Contains(string(r.JSON), "ipv6") || strings.Contains(string(r.JSON), "fd00") || strings.Contains(string(r.JSON), "underlay-v6") {
			t.Errorf("%s: IPv6 rendered on an IPv4-only underlay", r.Node)
		}
	}
}

func minus(a, b []string) []string {
	var out []string
	for _, x := range a {
		if !slices.Contains(b, x) {
			out = append(out, x)
		}
	}
	return out
}

func TestRegisterRefusesAnUncoveredFabricPath(t *testing.T) {
	if err := register.CheckFabricPaths("leaf01", []string{"/network-instance[name=macvrf-x]/protocols/bgp-evpn/bgp-instance[id=1]/evi"}); err == nil {
		t.Error("a service-owned path passed the fabric register check")
	}
}

// TestConfigStampsOnGeneratedConfig: source identity, generation, render hash,
// compatibility set and srl-mapping v0.1.0 are stamped on the generated
// Config built from a render (FR-101) — never on the Fabric, which the
// request only references.
func TestConfigStampsOnGeneratedConfig(t *testing.T) {
	r := render(t, defaultInput())["spine01"]
	src := sdc.Source{Kind: sdc.SourceFabric, Namespace: sdc.SystemNamespace, Name: "fabric01", UID: "3f0c-uid", Generation: 7}
	owner := &metav1.OwnerReference{APIVersion: "fabric.agentic-netops.io/v1alpha1", Kind: "Fabric", Name: "fabric01", UID: "3f0c-uid"}
	req, err := srl.FabricConfigRequest(r, src, sdc.SystemNamespace, "cs-1", owner)
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := sdc.BuildConfig(req)
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range map[string]string{
		sdc.AnnotationSourceUID:        "3f0c-uid",
		sdc.AnnotationSourceGeneration: "7",
		sdc.AnnotationRenderHash:       r.Hash,
		sdc.AnnotationCompatibilitySet: "cs-1",
		sdc.AnnotationMappingVersion:   "srl-mapping v0.1.0",
	} {
		if got := cfg.Annotations[k]; got != v {
			t.Errorf("Config annotation %s = %q, want %q", k, got, v)
		}
	}
	if cfg.Name != "fabric01.spine01" || cfg.Namespace != sdc.SystemNamespace || cfg.Spec.Priority != 10 ||
		cfg.Spec.Revertive == nil || !*cfg.Spec.Revertive || cfg.Labels[sdc.LabelFabricName] != "fabric01" {
		t.Errorf("config identity: %s/%s priority %d labels %v", cfg.Namespace, cfg.Name, cfg.Spec.Priority, cfg.Labels)
	}
	if len(cfg.Spec.Config) != 1 || cfg.Spec.Config[0].Path != "/" || !bytes.Equal(cfg.Spec.Config[0].Value.Raw, r.JSON) {
		t.Error("the Config does not carry the rendered document at /")
	}
	if len(cfg.OwnerReferences) != 1 || cfg.OwnerReferences[0].UID != "3f0c-uid" {
		t.Errorf("owner reference: %+v", cfg.OwnerReferences)
	}
	if _, err := srl.FabricConfigRequest(r, sdc.Source{Kind: sdc.SourceNetwork, Name: "x", UID: "u"}, sdc.SystemNamespace, "cs-1", nil); err == nil {
		t.Error("a fabric render accepted for a Network source")
	}
}
