package migration

// T090 (FR-025, FR-029…FR-031, SC-016): the construct goldens, deterministic bytes and key order
// (contracts/network-spec.md §2–§3), name resolution regardless of case, hyphen, underscore and
// space, the structural-only VLAN check (a VLAN of the allocation band translates, AD-41), and the
// emitted object decoding strictly into the Network API type (the CRD's own field names).

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
)

const testdata = "../../tests/unit/testdata/migration"

// labOptions is the live site: leaf01/leaf02 with access port ethernet-1/1, two spines, ASN 65000.
func labOptions(t *testing.T) Options {
	t.Helper()
	o, err := ParseOptions(labNodeMap, labPortMap, "65000")
	if err != nil {
		t.Fatal(err)
	}
	return o
}

const (
	labNodeMap = `{"leaf01":"leaf","leaf02":"leaf","spine01":"spine","spine02":"spine"}`
	labPortMap = `{"leaf01":["ethernet-1/1"],"leaf02":["ethernet-1/1"],"spine01":[],"spine02":[]}`
)

func read(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(testdata, name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func mustTranslate(t *testing.T, data []byte, opt Options) *Result {
	t.Helper()
	res, err := TranslateJSON(data, opt)
	if err != nil {
		t.Fatalf("translation refused: %v", err)
	}
	return res
}

var rdKey = regexp.MustCompile(`(?mi)^\s*-?\s*(rd|routeDistinguisher|route-distinguisher):`)

func TestConstructGoldens(t *testing.T) {
	for _, tc := range []struct {
		name  string
		check func(t *testing.T, n Network, y string)
	}{
		{"vlan", func(t *testing.T, n Network, y string) {
			if len(n.Spec.VLANs) != 1 || n.Spec.VLANs[0].Name != "vlan-1a2b3c4d5e6f701" || n.Spec.VLANs[0].VLAN != 100 {
				t.Errorf("vlan: want one vlans[] entry vlan-<sid> VLAN 100, got %+v", n.Spec.VLANs)
			}
			if len(n.Spec.BridgeDomains)+len(n.Spec.Routers) != 0 {
				t.Error("vlan: emitted bridgeDomains or routers")
			}
			for _, forbidden := range []string{"l2vni", "l3vni", "routeTargets", "target:", "evpn", "vxlan", "tunnel", "bridgeDomains", "routers"} {
				if strings.Contains(y, forbidden) {
					t.Errorf("vlan: the emitted object carries %q; a vlan has no L2VNI, route targets, tunnel or EVPN", forbidden)
				}
			}
		}},
		// A mac-vrf with NO anycast gateway emits no routers[] and no irb (T115; FR-032).
		{"macvrf", func(t *testing.T, n Network, y string) {
			if len(n.Spec.BridgeDomains) != 1 || len(n.Spec.Routers) != 0 || len(n.Spec.VLANs) != 0 {
				t.Fatalf("macvrf: want exactly one bridge domain and no routers/vlans, got %+v", n.Spec)
			}
			bd := n.Spec.BridgeDomains[0]
			want := &RouteTargets{Import: []string{"target:65000:10021"}, Export: []string{"target:65000:10021"}}
			if bd.Name != "bd-4b7e19c2a05d3f6" || bd.L2VNI != 10021 || bd.EVPN == nil || !reflect.DeepEqual(bd.EVPN.RouteTargets, want) || bd.IRB != nil {
				t.Errorf("macvrf: bridge domain %+v, want bd-<sid> L2VNI 10021 with derived route targets and no irb", bd)
			}
			if strings.Contains(y, "routers:") || strings.Contains(y, "irb:") || strings.Contains(y, "l3vni") {
				t.Error("macvrf: a mac-vrf without a gateway emitted routers, an irb or an L3VNI")
			}
		}},
		// T115/T116 (FR-032, CR-002): the gateway is a property of the mac-vrf — the bridge domain,
		// its irb pointing at the router, and the router whose prefixes are the masked gateway
		// subnets of the declared families. No fifth construct: no vlans[], no attachment vrf.
		// (A gateway on an ip-vrf is refused naming mac-vrf: refuse_wrong_var_gateway_on_ipvrf,
		// refusal_test.go.)
		{"macvrf_gateway", func(t *testing.T, n Network, y string) {
			checkGateway(t, n, "7e1c3a5b9d2f4a6", 10160, 10161, "10.160.0.1/24", "2001:db8:160::1/64",
				[]string{"10.160.0.0/24", "2001:db8:160::/64"})
		}},
		// A gateway declaring IPv4 only: nothing IPv6 anywhere in the emitted spec.
		{"macvrf_gateway_ipv4", func(t *testing.T, n Network, y string) {
			checkGateway(t, n, "2c4e6a8b0d1f3a5", 10170, 10171, "10.170.0.1/24", "", []string{"10.170.0.0/24"})
			spec := n.Spec.YAML()
			for _, v6 := range []string{"gatewayIPv6", "::", "2001:"} {
				if strings.Contains(spec, v6) || strings.Contains(string(n.JSON()), v6) {
					t.Errorf("macvrf_gateway_ipv4: an IPv4-only gateway emitted %q:\n%s", v6, spec)
				}
			}
		}},
		{"ipvrf", func(t *testing.T, n Network, y string) {
			if len(n.Spec.Routers) != 1 || len(n.Spec.BridgeDomains)+len(n.Spec.VLANs) != 0 {
				t.Fatalf("ipvrf: want exactly one router, got %+v", n.Spec)
			}
			r := n.Spec.Routers[0]
			if r.Name != "vrf-9c3d5e7f1a2b4c6" || r.L3VNI != 10022 || !reflect.DeepEqual(r.Prefixes, []string{"10.50.0.0/24", "2001:db8:50::/64"}) ||
				r.RouteTargets == nil || r.RouteTargets.Import[0] != "target:65000:10022" {
				t.Errorf("ipvrf: router %+v", r)
			}
			for _, a := range n.Spec.Attachments {
				if a.VRF != r.Name {
					t.Errorf("ipvrf: attachment %+v does not name its router", a)
				}
			}
			if rdKey.MatchString(y) || bytes.Contains(n.JSON(), []byte(`"rd"`)) {
				t.Error("ipvrf: a route-distinguisher field was emitted; the device derives it (RD-09)")
			}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res := mustTranslate(t, read(t, "construct_"+tc.name+".json"), labOptions(t))
			if len(res.Manifests) != 1 {
				t.Fatalf("want one manifest, got %d", len(res.Manifests))
			}
			n := res.Manifests[0]
			golden := read(t, "construct_"+tc.name+".spec.golden.yaml")
			if got := n.Spec.YAML(); got != string(golden) {
				t.Errorf("spec block differs from construct_%s.spec.golden.yaml\n--- got\n%s--- want\n%s", tc.name, got, golden)
			}
			if !strings.HasSuffix(res.YAML, string(golden)) {
				t.Error("the emitted document does not end with the golden spec block")
			}
			tc.check(t, n, res.YAML)
		})
	}
}

// checkGateway asserts the emitted shape of a mac-vrf with an anycast gateway (T115).
func checkGateway(t *testing.T, n Network, sid string, l2vni, l3vni int64, v4, v6 string, prefixes []string) {
	t.Helper()
	if len(n.Spec.BridgeDomains) != 1 || len(n.Spec.Routers) != 1 || len(n.Spec.VLANs) != 0 || len(n.Spec.AccessLists) != 0 {
		t.Fatalf("gateway: want one bridge domain and one router, got %+v", n.Spec)
	}
	bd, r := n.Spec.BridgeDomains[0], n.Spec.Routers[0]
	rt := func(v int64) *RouteTargets {
		s := fmt.Sprintf("target:65000:%d", v)
		return &RouteTargets{Import: []string{s}, Export: []string{s}}
	}
	if bd.Name != "bd-"+sid || bd.L2VNI != l2vni || bd.EVPN == nil || !reflect.DeepEqual(bd.EVPN.RouteTargets, rt(l2vni)) {
		t.Errorf("gateway: bridge domain %+v", bd)
	}
	if r.Name != "vrf-"+sid || r.L3VNI != l3vni || !reflect.DeepEqual(r.RouteTargets, rt(l3vni)) || !reflect.DeepEqual(r.Prefixes, prefixes) {
		t.Errorf("gateway: router %+v, want vrf-%s L3VNI %d prefixes %v", r, sid, l3vni, prefixes)
	}
	if want := (&IRB{VRF: r.Name, GatewayIPv4: v4, GatewayIPv6: v6}); !reflect.DeepEqual(bd.IRB, want) {
		t.Errorf("gateway: irb %+v, want %+v", bd.IRB, want)
	}
	for _, a := range n.Spec.Attachments {
		if a.VRF != "" {
			t.Errorf("gateway: attachment %+v names a vrf; the bridged attachment is no member of the router", a)
		}
	}
}

// No emitted type has a route-distinguisher field (RD-09).
func TestNoRouteDistinguisherField(t *testing.T) {
	for _, typ := range []reflect.Type{reflect.TypeOf(Network{}), reflect.TypeOf(NetworkSpec{}), reflect.TypeOf(Router{}),
		reflect.TypeOf(BridgeDomain{}), reflect.TypeOf(EVPN{}), reflect.TypeOf(RouteTargets{}), reflect.TypeOf(Attachment{})} {
		for i := 0; i < typ.NumField(); i++ {
			f := typ.Field(i)
			tag := strings.Split(f.Tag.Get("json"), ",")[0]
			if strings.EqualFold(tag, "rd") || strings.Contains(strings.ToLower(f.Name), "distinguisher") || f.Name == "RD" {
				t.Errorf("%s.%s: a route-distinguisher field", typ.Name(), f.Name)
			}
		}
	}
}

func TestDeterministicBytesAndKeyOrder(t *testing.T) {
	for _, c := range []string{"vlan", "macvrf", "ipvrf", "macvrf_allocated_vlan", "macvrf_gateway", "macvrf_gateway_ipv4"} {
		data := read(t, "construct_"+c+".json")
		a := mustTranslate(t, data, labOptions(t))
		b := mustTranslate(t, data, labOptions(t))
		if a.YAML != b.YAML || !bytes.Equal(a.Manifests[0].JSON(), b.Manifests[0].JSON()) {
			t.Errorf("%s: two translations of one input differ", c)
		}
		assertKeyOrder(t, c, a.YAML)
	}
	// the annotations: the translator's keys, in the §3 order, and no namespace or labels
	y := mustTranslate(t, read(t, "construct_macvrf.json"), labOptions(t)).YAML
	wantHead := `apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
metadata:
  name: migr-4b7e19c2a05d3f6
  annotations:
    agentic-netops.io/translator: agentic-netops-migration-translator
    agentic-netops.io/translator-version: v0.1.0
    agentic-netops.io/mapping-version: v0.1.0
    agentic-netops.io/migration-input-hash: sha256:`
	if !strings.HasPrefix(y, wantHead) {
		t.Errorf("document head:\n%s", y)
	}
	if !regexp.MustCompile(`(?m)^    agentic-netops.io/migration-input-hash: sha256:[0-9a-f]{64}\n    agentic-netops.io/tenant: acme\n    agentic-netops.io/service-type: mac-vrf\nspec:\n`).MatchString(y) {
		t.Errorf("annotations after the hash are not tenant, service-type:\n%s", y)
	}
	for _, forbidden := range []string{"namespace:", "labels:", "source-service-type", "limited-equivalence"} {
		if strings.Contains(y, forbidden) {
			t.Errorf("the emitted object carries %q (the deployer stamps namespace and labels; provenance only for an alias)", forbidden)
		}
	}
}

// assertKeyOrder checks the §3 order: spec lists, then within each entry.
func assertKeyOrder(t *testing.T, name, y string) {
	t.Helper()
	spec := y[strings.Index(y, "\nspec:\n"):]
	order := func(keys ...string) {
		last := -1
		for _, k := range keys {
			i := strings.Index(spec, k)
			if i < 0 {
				continue
			}
			if i < last {
				t.Errorf("%s: %q is out of the network-spec.md §3 order", name, strings.TrimSpace(k))
			}
			last = i
		}
	}
	order("\n  description:", "\n  vlans:", "\n  bridgeDomains:", "\n  routers:", "\n  accessLists:", "\n  attachments:")
	order("  - name: bd-", "\n    vlan:", "\n    l2vni:", "\n    evpn:", "\n    irb:")
	order("  - name: vrf-", "\n    routeTargets:", "\n    l3vni:", "\n    prefixes:")
	att := spec[strings.Index(spec, "\n  attachments:")+len("\n  attachments:"):]
	for _, entry := range strings.Split(att, "\n  - ")[1:] {
		var keys []string
		for _, l := range strings.Split(strings.TrimSpace(entry), "\n") {
			keys = append(keys, strings.SplitN(strings.TrimSpace(l), ":", 2)[0])
		}
		want := []string{"node", "attachment", "vlan", "vrf"}
		j := 0
		for _, k := range keys {
			for j < len(want) && want[j] != k {
				j++
			}
			if j == len(want) {
				t.Errorf("%s: attachment keys %v are not in the order node, attachment, vlan, vrf", name, keys)
				break
			}
		}
	}
}

func TestCanonicalizeResolvesSpellings(t *testing.T) {
	for in, want := range map[string]Resolution{
		"IP-VRF": {Construct: "ip-vrf"}, "ip_vrf": {Construct: "ip-vrf"}, "ip vrf": {Construct: "ip-vrf"}, "IPVRF": {Construct: "ip-vrf"},
		"MAC VRF": {Construct: "mac-vrf"}, "mac-vrf": {Construct: "mac-vrf"}, "Mac-Vrf": {Construct: "mac-vrf"}, "macvrf": {Construct: "mac-vrf"}, "MAC_VRF": {Construct: "mac-vrf"},
		"Vlan": {Construct: "vlan"}, "VLAN": {Construct: "vlan"}, " vlan ": {Construct: "vlan"},
		"ACL": {Construct: "acl"}, "access-list": {Construct: "acl"}, "Access List": {Construct: "acl"},
		"l2vni": {Construct: "mac-vrf"}, "L3VNI": {Construct: "ip-vrf"},
		"VPLS": {Construct: "mac-vrf", Source: "VPLS"}, "vpws": {Construct: "mac-vrf", Source: "VPWS"}, "E-Line": {Construct: "mac-vrf", Source: "VPWS"},
		"L3VPN": {Construct: "ip-vrf", Source: "L3VPN"}, "L2L3-IRB": {Construct: "mac-vrf", Source: "L2L3-IRB"}, "irb": {Construct: "mac-vrf", Source: "L2L3-IRB"},
	} {
		got, ok := Canonicalize(in)
		if !ok || got != want {
			t.Errorf("Canonicalize(%q) = %+v, %v; want %+v", in, got, ok, want)
		}
	}
	for _, bad := range []string{"", "vxlan", "evpn-magic", "vrf", "l2", "bridge"} {
		if r, ok := Canonicalize(bad); ok {
			t.Errorf("Canonicalize(%q) resolved to %+v; want refused", bad, r)
		}
	}
	if got := ConstructList(); got != "vlan, mac-vrf, ip-vrf, acl" {
		t.Errorf("ConstructList() = %q", got)
	}
}

// A spelling variant translates to the golden byte for byte; a migration alias does too, and only
// adds the arrival vocabulary as provenance.
func TestSpellingVariantsEmitTheGolden(t *testing.T) {
	for _, tc := range []struct{ file, typ, source string }{
		{"ipvrf", "IP_VRF", ""}, {"ipvrf", "ip vrf", ""}, {"ipvrf", "L3VPN", "L3VPN"},
		{"macvrf", "MAC VRF", ""}, {"macvrf", "Mac-Vrf", ""}, {"macvrf", "vpls", "VPLS"},
		{"vlan", "Vlan", ""}, {"vlan", "V-L-A-N", ""},
	} {
		var m map[string]any
		if err := json.Unmarshal(read(t, "construct_"+tc.file+".json"), &m); err != nil {
			t.Fatal(err)
		}
		m["type"] = tc.typ
		data, _ := json.Marshal(m)
		res := mustTranslate(t, data, labOptions(t))
		n := res.Manifests[0]
		if got, want := n.Spec.YAML(), string(read(t, "construct_"+tc.file+".spec.golden.yaml")); got != want {
			t.Errorf("type %q: spec differs from the %s golden:\n%s", tc.typ, tc.file, got)
		}
		canonical, _ := Canonicalize(tc.typ)
		if n.Metadata.Annotations[AnnotationServiceType] != canonical.Construct {
			t.Errorf("type %q: service-type %q", tc.typ, n.Metadata.Annotations[AnnotationServiceType])
		}
		if n.Metadata.Annotations[AnnotationSourceServiceType] != tc.source {
			t.Errorf("type %q: source-service-type %q, want %q", tc.typ, n.Metadata.Annotations[AnnotationSourceServiceType], tc.source)
		}
		// the canonical input hash does not depend on the spelling (D-19)
		orig := mustTranslate(t, read(t, "construct_"+tc.file+".json"), labOptions(t)).Manifests[0]
		if n.Metadata.Annotations[AnnotationInputHash] != orig.Metadata.Annotations[AnnotationInputHash] {
			t.Errorf("type %q: the input hash depends on the spelling", tc.typ)
		}
	}
}

// AD-41: the translator's only VLAN-value check is structural; an allocated VLAN translates.
func TestAllocatedVLANTranslates(t *testing.T) {
	res := mustTranslate(t, read(t, "construct_macvrf_allocated_vlan.json"), labOptions(t))
	bd := res.Manifests[0].Spec.BridgeDomains
	if len(bd) != 1 || bd[0].VLAN != 1500 {
		t.Fatalf("want a bridge domain on VLAN 1500, got %+v", bd)
	}
	for _, v := range []int64{100, 999, 1000, 4000} {
		data := bytes.Replace(read(t, "construct_vlan.json"), []byte(`"vlan": 100`), []byte(`"vlan": `+itoa(v)), -1)
		if _, err := TranslateJSON(data, labOptions(t)); err != nil {
			t.Errorf("VLAN %d refused: %v", v, err)
		}
	}
	for _, v := range []int64{1, 99, 4001, 4094} {
		data := bytes.Replace(read(t, "construct_vlan.json"), []byte(`"vlan": 100`), []byte(`"vlan": `+itoa(v)), -1)
		_, err := TranslateJSON(data, labOptions(t))
		if err == nil || !strings.Contains(err.Error(), "100–999") || !strings.Contains(err.Error(), "1000–4000") {
			t.Errorf("VLAN %d: want a refusal stating both bands, got %v", v, err)
		}
	}
}

func itoa(v int64) string { b, _ := json.Marshal(v); return string(b) }

// The emitted object is exactly the Network API type: strict decoding accepts every key.
func TestEmittedDecodesStrictlyIntoNetwork(t *testing.T) {
	for _, c := range []string{"vlan", "macvrf", "ipvrf", "macvrf_allocated_vlan", "macvrf_gateway", "macvrf_gateway_ipv4"} {
		res := mustTranslate(t, read(t, "construct_"+c+".json"), labOptions(t))
		var fromYAML fabricv1.Network
		if err := yaml.UnmarshalStrict([]byte(res.YAML), &fromYAML); err != nil {
			t.Errorf("%s: the YAML does not decode strictly into fabricv1.Network: %v", c, err)
		}
		var fromJSON fabricv1.Network
		dec := json.NewDecoder(bytes.NewReader(res.Manifests[0].JSON()))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&fromJSON); err != nil {
			t.Errorf("%s: the JSON manifest does not decode strictly into fabricv1.Network: %v", c, err)
		}
		if fromYAML.APIVersion != fabricv1.GroupVersion.String() || fromYAML.Kind != "Network" || fromYAML.Name != res.Manifests[0].Metadata.Name {
			t.Errorf("%s: type meta / name %+v", c, fromYAML.TypeMeta)
		}
		if !reflect.DeepEqual(fromYAML.Spec, fromJSON.Spec) || !reflect.DeepEqual(fromYAML.Annotations, fromJSON.Annotations) {
			t.Errorf("%s: the YAML and JSON forms decode to different objects", c)
		}
		if len(fromYAML.Spec.Attachments) != 2 {
			t.Errorf("%s: attachments %+v", c, fromYAML.Spec.Attachments)
		}
	}
}

func TestBatchIsAllOrNothing(t *testing.T) {
	good := read(t, "construct_vlan.json")
	bad := read(t, "refuse_wrong_var_l2vni_on_vlan.json")
	res, err := TranslateJSON([]byte("["+string(good)+","+string(bad)+"]"), labOptions(t))
	if res != nil || err == nil {
		t.Fatal("a batch with one refused service emitted output")
	}
	causes := ErrorCauses(err)
	if len(causes) == 0 || !strings.HasPrefix(causes[0], "input[1].l2vni: ") {
		t.Errorf("causes %q, want the first naming input[1].l2vni", causes)
	}
	for _, c := range causes {
		if !strings.HasPrefix(c, "input[1].") {
			t.Errorf("cause %q does not name input[1]", c)
		}
	}
	res, err = TranslateJSON([]byte("["+string(good)+","+string(read(t, "construct_ipvrf.json"))+"]"), labOptions(t))
	if err != nil || len(res.Manifests) != 2 || strings.Count(res.YAML, "apiVersion:") != 2 || !strings.Contains(res.YAML, "\n---\napiVersion:") {
		t.Errorf("a valid batch: %v", err)
	}
}

func TestRefusalsInProcess(t *testing.T) {
	opt := labOptions(t)
	for name, want := range map[string]string{
		// route targets are derived: another ASN or another VNI is refused
		`{"serviceId":"a1","type":"mac-vrf","tenant":"t","l2vni":10021,"routeTargets":{"importRT":["target:65001:10021"],"exportRT":["target:65000:10021"]},"endpoints":[{"node":"leaf01","attachment":"ethernet-1/1","vlan":100},{"node":"leaf02","attachment":"ethernet-1/1","vlan":100}]}`: "routeTargets.importRT[0]: target:65001:10021 is not the derived route target target:65000:10021",
		`{"serviceId":"a1","type":"ip-vrf","tenant":"t","l3vni":10022,"routeTargets":{"importRT":["target:65000:10023"],"exportRT":["target:65000:10022"]},"addressFamilies":{"ipv4Prefixes":["10.0.0.0/24"]},"endpoints":[{"node":"leaf01","attachment":"ethernet-1/1","vrf":"vrf-a1"}]}`:    "routeTargets.importRT[0]: target:65000:10023 is not the derived route target target:65000:10022",
		`{"serviceId":"a1","type":"mac-vrf","tenant":"t","l2vni":10021,"endpoints":[{"node":"leaf01","attachment":"ethernet-1/1","vlan":100},{"node":"leaf02","attachment":"ethernet-1/1","vlan":100}]}`:                                                                                      "routeTargets: required for a mac-vrf",
		`{"serviceId":"a1","type":"ip-vrf","tenant":"t","l3vni":10022,"routeTargets":{"importRT":["target:65000:10022"],"exportRT":["target:65000:10022"]},"addressFamilies":{"ipv4Prefixes":["10.0.0.0/24"]},"endpoints":[{"node":"leaf01","attachment":"ethernet-1/1","vrf":"blue"}]}`:      `endpoints[0].vrf: "blue" is not this service's routed instance vrf-a1`,
		`{"serviceId":"a1","type":"acl","tenant":"t","acl":{"stage":"ingress","type":"ipv4","rules":[{"name":"r","priority":10,"action":"permit","protocol":1,"destinationPort":"80"}]},"endpoints":[{"node":"leaf01","attachment":"ethernet-1/1"}]}`:                                         "acl.rules[0].destinationPort: rule \"r\": an L4 port match requires protocol tcp (6) or udp (17)",
		`{"serviceId":"a1","type":"vlan","tenant":"t","acl":{"stage":"ingress","type":"ipv4","rules":[{"name":"r","priority":65535,"action":"permit"}]},"endpoints":[{"node":"leaf01","attachment":"ethernet-1/1","vlan":100}]}`:                                                              "acl.rules[0].priority: rule \"r\": priority 65535 is reserved for the default action",
		`{"serviceId":"a1","type":"vlan","tenant":"t","endpoints":[{"node":"spine01","attachment":"ethernet-1/1","vlan":100}]}`:                                                                                                                                                               "endpoints[0].node: spine01 is a spine, and spines are not attachment points; the site's attachment nodes are leaf01, leaf02",
		`{"serviceId":"a1","type":"vlan","tenant":"t","endpoints":[{"node":"leaf01","attachment":"ethernet-1/1","vlan":100},{"node":"leaf01","attachment":"ethernet-1/1","vlan":100}]}`:                                                                                                       "endpoints[1]: duplicates endpoints[0]",
		`{"serviceId":"a1","type":"mac-vrf","tenant":"t","l2vni":10021,"routeTargets":{"importRT":["target:65000:10021"],"exportRT":["target:65000:10021"]},"endpoints":[{"node":"leaf01","attachment":"ethernet-1/1","vlan":100}]}`:                                                          "endpoints: a mac-vrf without an anycastGateway needs at least 2 endpoints",
		`{"serviceId":"A_1","type":"vlan","tenant":"t","endpoints":[{"node":"leaf01","attachment":"ethernet-1/1","vlan":100}]}`:                                                                                                                                                               `serviceId: "A_1" is not a DNS-1123 label`,
		`{"serviceId":"a1","type":"vlan","tenant":"t","endpoints":[{"node":"leaf01","attachment":"ethernet-1/1","vlan":"100"}]}`:                                                                                                                                                              "endpoints[0].vlan: expected an integer",
		`{"serviceId":"a1","type":"vlan","tenant":"t","endpoints":[{"node":"leaf01","attachment":"ethernet-1/1","vlan":100,"rd":"65000:1"}]}`:                                                                                                                                                 `rd: unknown field "rd"`,
		`[]`: "input: an empty array",
	} {
		_, err := TranslateJSON([]byte(name), opt)
		if err == nil {
			t.Errorf("accepted: %s", name)
			continue
		}
		if !strings.Contains(strings.Join(ErrorCauses(err), "\n"), want) {
			t.Errorf("%s\n  causes %q\n  want one containing %q", name, ErrorCauses(err), want)
		}
	}
	for _, malformed := range []string{``, `nope`, `{"serviceId":`, `{} {}`, `42`} {
		if _, err := TranslateJSON([]byte(malformed), opt); ErrorKind(err) != "malformed" {
			t.Errorf("%q: want a malformed error, got %v", malformed, err)
		}
	}
}

// Without an inventory, node and port are not checked; with FABRIC_ASN unset the ASN is the input's.
func TestNoSiteNoASN(t *testing.T) {
	data := bytes.ReplaceAll(read(t, "construct_macvrf.json"), []byte("65000"), []byte("64512"))
	data = bytes.ReplaceAll(data, []byte("leaf02"), []byte("leaf77"))
	res := mustTranslate(t, data, Options{})
	if got := res.Manifests[0].Spec.BridgeDomains[0].EVPN.RouteTargets.Import[0]; got != "target:64512:10021" {
		t.Errorf("route target %q", got)
	}
	if _, err := TranslateJSON(data, labOptions(t)); err == nil {
		t.Error("with the lab inventory and ASN 65000 the same input must be refused")
	}
}

func TestParseOptions(t *testing.T) {
	o, err := ParseOptions("", "", "")
	if err != nil || o.Site != nil || o.FabricASN != 0 {
		t.Errorf("unset: %+v %v", o, err)
	}
	o = labOptions(t)
	if o.FabricASN != 65000 || o.Site.Roles["spine01"] != "spine" || !reflect.DeepEqual(o.Site.Ports["leaf01"], []string{"ethernet-1/1"}) {
		t.Errorf("lab: %+v", o)
	}
	for _, bad := range [][3]string{{"leaf01", "", ""}, {"", `["x"]`, ""}, {"", "", "abc"}, {"", "", "0"}, {"", "", "4294967296"}} {
		if _, err := ParseOptions(bad[0], bad[1], bad[2]); err == nil {
			t.Errorf("ParseOptions(%q) accepted", bad)
		}
	}
}

func TestScalarQuoting(t *testing.T) {
	for in, want := range map[string]string{
		"acme": "acme", "Service 1a (vlan)": "Service 1a (vlan)", "ethernet-1/1": "ethernet-1/1", "2001:db8::/64": "2001:db8::/64",
		"123": `"123"`, "true": `"true"`, "no": `"no"`, "1e5": `"1e5"`, "a: b": `"a: b"`, "#x": `"#x"`, "": `""`, "x:": `"x:"`, "12:30": `"12:30"`,
	} {
		if got := scalar(in); got != want {
			t.Errorf("scalar(%q) = %s, want %s", in, got, want)
		}
	}
}

// The YAML and JSON forms are one object.
func TestYAMLEqualsJSON(t *testing.T) {
	for _, c := range []string{"vlan", "macvrf", "ipvrf", "macvrf_gateway", "macvrf_gateway_ipv4"} {
		n := mustTranslate(t, read(t, "construct_"+c+".json"), labOptions(t)).Manifests[0]
		j, err := yaml.YAMLToJSON([]byte(n.YAML()))
		if err != nil {
			t.Fatal(err)
		}
		var a, b any
		_ = json.Unmarshal(j, &a)
		_ = json.Unmarshal(n.JSON(), &b)
		if !reflect.DeepEqual(a, b) {
			t.Errorf("%s: YAML %s\nJSON %s", c, j, n.JSON())
		}
	}
}

// A mac-vrf with an anycast gateway emits the bridge domain's irb and the router it points at.
func TestMACVRFGateway(t *testing.T) {
	in := `{"serviceId":"4b7e19c2a05d3f6","type":"mac-vrf","tenant":"acme","l2vni":10021,"l3vni":10022,
	  "routeTargets":{"importRT":["target:65000:10021"],"exportRT":["target:65000:10021"]},
	  "anycastGateway":{"gatewayIPv4":"10.10.0.1/24","gatewayIPv6":"2001:db8:10::1/64"},
	  "endpoints":[{"node":"leaf01","attachment":"ethernet-1/1","vlan":100}]}`
	n := mustTranslate(t, []byte(in), labOptions(t)).Manifests[0]
	if len(n.Spec.Routers) != 1 || n.Spec.BridgeDomains[0].IRB == nil || n.Spec.BridgeDomains[0].IRB.VRF != n.Spec.Routers[0].Name ||
		!reflect.DeepEqual(n.Spec.Routers[0].Prefixes, []string{"10.10.0.0/24", "2001:db8:10::/64"}) ||
		n.Spec.Routers[0].RouteTargets.Export[0] != "target:65000:10022" {
		t.Errorf("gateway: %+v", n.Spec)
	}
	var strict fabricv1.Network
	if err := yaml.UnmarshalStrict([]byte(n.YAML()), &strict); err != nil {
		t.Error(err)
	}
}
