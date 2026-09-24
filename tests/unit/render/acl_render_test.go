// T104 — the access-list render (contracts/acl-render-contract.md §2, golden
// exemplar §2.1, §3; data-model.md §13; FR-015, FR-017, FR-035–FR-041, FR-043,
// AD-68).
//
// Shared fixtures and checks (flattenService, the goldens loop, the G12 freeze)
// are in vlan_render_test.go; the goldens of this file are
// tests/golden/services/acl_<case>-<node>.json, regenerated with
//
//	go test ./tests/unit/render/ -run TestServiceGoldens -update
//
// and validated offline by `make verify-render-schema` — a standalone list
// layered on its node's fabric golden AND on the service golden that owns the
// subinterface it binds (scripts/ci/verify_render_schema.sh).
package render_test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/render/srl"
	"github.com/mairp/agentic-netops-srl/pkg/register"
)

// ---------------------------------------------------------------------------
// Inputs.
// ---------------------------------------------------------------------------

func action(a model.Action) *model.Action { return &a }

// aclExemplarInput is §2.1: "permit tcp 443 from 10.0.0.0/24, deny everything
// else, ingress, ipv4, on leaf01 ethernet-1/1 vlan 100", service svc-0042,
// tenant tenant1 — as the property of the `vlan` service that creates
// ethernet-1/1.100 (and so renders its interface-ref).
func aclExemplarInput() model.ServiceInput {
	return model.ServiceInput{ServiceID: "svc-0042", Tenant: "tenant1", Construct: model.ConstructVLAN, FabricASN: 65000,
		L2: &model.L2Segment{VLAN: 100, L2MTU: 9412, Attachments: []model.Attachment{{Node: "leaf01", Port: "ethernet-1/1"}}},
		AccessLists: []model.AccessList{{Stage: model.StageIngress, Family: model.FamilyIPv4, DefaultAction: action(model.ActionDrop),
			Rules: []model.ACLRule{{Name: "permit-https", Priority: 100, Action: model.ActionAccept, Protocol: "tcp",
				SourcePrefix: "10.0.0.0/24", DestinationPort: &model.PortMatch{Lo: 443}}},
			Bindings: []model.ACLBinding{{Node: "leaf01", Port: "ethernet-1/1", VLAN: 100}}}}}
}

// aclEgressInput: an egress IPv6 list on a `vlan` spanning both leaves, no
// default action, priorities declared out of order, ICMPv6 by name and by
// number, a TCP port range and a single UDP source port.
func aclEgressInput() model.ServiceInput {
	return model.ServiceInput{ServiceID: "edge", Tenant: "tenant1", Construct: model.ConstructVLAN, FabricASN: 65000,
		L2: &model.L2Segment{VLAN: 160, L2MTU: 9412, Attachments: []model.Attachment{
			{Node: "leaf01", Port: "ethernet-1/1"}, {Node: "leaf02", Port: "ethernet-1/1"}}},
		AccessLists: []model.AccessList{{Stage: model.StageEgress, Family: model.FamilyIPv6,
			Rules: []model.ACLRule{
				{Name: "drop-dns-from-lab", Priority: 300, Action: model.ActionDrop, Protocol: "udp", SourcePrefix: "2001:db8:66::/48", SourcePort: &model.PortMatch{Lo: 53}},
				{Name: "permit-icmpv6", Priority: 100, Action: model.ActionAccept, Protocol: "icmpv6"},
				{Name: "drop-high-tcp", Priority: 200, Action: model.ActionDrop, Protocol: "tcp", DestinationPrefix: "2001:db8:160::/64",
					DestinationPort: &model.PortMatch{Lo: 8000, Hi: 8100}},
				{Name: "permit-nh-58", Priority: 400, Action: model.ActionAccept, Protocol: "58"},
			},
			Bindings: []model.ACLBinding{{Node: "leaf01", Port: "ethernet-1/1", VLAN: 160}, {Node: "leaf02", Port: "ethernet-1/1", VLAN: 160}}}}}
}

// aclStandaloneInput: a standalone `acl` bound on leaf01 ethernet-1/1.110 —
// the subinterface the `vlan` golden (service web, VLAN 110) creates.
func aclStandaloneInput() model.ServiceInput {
	return model.ServiceInput{ServiceID: "guard", Tenant: "tenant2", Construct: model.ConstructACL,
		AccessLists: []model.AccessList{{Stage: model.StageIngress, Family: model.FamilyIPv4, DefaultAction: action(model.ActionAccept),
			Rules: []model.ACLRule{{Name: "drop-rtp", Priority: 20, Action: model.ActionDrop, Protocol: "udp",
				DestinationPrefix: "10.110.0.0/24", DestinationPort: &model.PortMatch{Lo: 5000, Hi: 5100}}},
			Bindings: []model.ACLBinding{{Node: "leaf01", Port: "ethernet-1/1", VLAN: 110}}}}}
}

// aclGoldenInputs are the access-list goldens, keyed by golden-file prefix:
// the three cases above and the two shipped examples (T113).
func aclGoldenInputs(t *testing.T) map[string]model.ServiceInput {
	t.Helper()
	return map[string]model.ServiceInput{
		"acl_exemplar":           aclExemplarInput(),
		"acl_egress":             aclEgressInput(),
		"acl_standalone":         aclStandaloneInput(),
		"acl_example_standalone": exampleInput(t, "acl-standalone.yaml"),
		"acl_example_macvrf":     exampleInput(t, "macvrf-with-acl.yaml"),
	}
}

// exampleInput maps a shipped example Network (examples/constructs/<file>) to
// the canonical service input the provider renders it from — the mapping of
// controllers/network/intent.go (service id := name without the tier's migr-
// prefix, tenant from the annotation, one binding per attachment, `any` = no
// protocol leaf) with the lab Fabric's MTUs and ASN. The goldens of the
// examples are therefore the examples' own renders.
func exampleInput(t *testing.T, file string) model.ServiceInput {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("../../../examples/constructs", file))
	if err != nil {
		t.Fatal(err)
	}
	var n fabricv1.Network
	if err := yaml.UnmarshalStrict(b, &n); err != nil {
		t.Fatalf("%s: %v", file, err)
	}
	s := n.Spec
	in := model.ServiceInput{ServiceID: strings.TrimPrefix(n.Name, "migr-"), Tenant: n.Annotations["agentic-netops.io/tenant"], FabricASN: 65000}
	var atts []model.Attachment
	var binds []model.ACLBinding
	for _, a := range s.Attachments {
		var vlan uint32
		if a.VLAN != nil {
			vlan = uint32(*a.VLAN)
		}
		atts = append(atts, model.Attachment{Node: string(a.Node), Port: string(a.Attachment)})
		binds = append(binds, model.ACLBinding{Node: string(a.Node), Port: string(a.Attachment), VLAN: vlan})
	}
	switch {
	case len(s.VLANs) > 0:
		in.Construct = model.ConstructVLAN
		in.L2 = &model.L2Segment{VLAN: uint32(s.VLANs[0].VLAN), L2MTU: 9412, Attachments: atts}
	case len(s.BridgeDomains) > 0:
		in.Construct = model.ConstructMACVRF
		bd := s.BridgeDomains[0]
		if bd.IRB != nil || len(s.Routers) > 0 {
			t.Fatalf("%s: the example mapping here covers a mac-vrf without a gateway", file)
		}
		in.L2 = &model.L2Segment{VLAN: uint32(bd.VLAN), L2VNI: uint32(bd.L2VNI), L2MTU: 9412, Attachments: atts}
	case len(s.Routers) > 0:
		t.Fatalf("%s: no ip-vrf example carries an access list", file)
	default:
		in.Construct = model.ConstructACL
	}
	for _, al := range s.AccessLists {
		m := model.AccessList{Stage: model.Stage(al.Stage), Family: model.Family(al.Type), Bindings: binds}
		act := func(a string) model.Action {
			if a == "permit" {
				return model.ActionAccept
			}
			return model.ActionDrop
		}
		if al.DefaultAction != "" {
			m.DefaultAction = action(act(al.DefaultAction))
		}
		for _, r := range al.Rules {
			mr := model.ACLRule{Name: r.Name, Priority: uint32(r.Priority), Action: act(r.Action),
				SourcePrefix: string(r.SourcePrefix), DestinationPrefix: string(r.DestinationPrefix),
				SourcePort: port(t, string(r.SourcePort)), DestinationPort: port(t, string(r.DestinationPort))}
			if p := string(r.Protocol); p != "any" {
				mr.Protocol = p
			}
			m.Rules = append(m.Rules, mr)
		}
		in.AccessLists = append(in.AccessLists, m)
	}
	return in
}

func port(t *testing.T, s string) *model.PortMatch {
	t.Helper()
	if s == "" {
		return nil
	}
	var lo, hi uint16
	if strings.Contains(s, "-") {
		if _, err := fmt.Sscanf(s, "%d-%d", &lo, &hi); err != nil {
			t.Fatalf("port %q: %v", s, err)
		}
		return &model.PortMatch{Lo: lo, Hi: hi}
	}
	if _, err := fmt.Sscanf(s, "%d", &lo); err != nil {
		t.Fatalf("port %q: %v", s, err)
	}
	return &model.PortMatch{Lo: lo}
}

// aclSubtree returns the rendered /acl subtree of one node's document.
func aclSubtree(t *testing.T, js []byte) any {
	t.Helper()
	var root map[string]any
	if err := json.Unmarshal(js, &root); err != nil {
		t.Fatal(err)
	}
	return root["srl_nokia-acl:acl"]
}

func mustRenderNode(t *testing.T, n *model.ServiceNode) *srl.Rendered {
	t.Helper()
	r, err := srl.RenderServiceNode(n)
	if err != nil {
		t.Fatalf("render %s: %v", n.Node, err)
	}
	return r
}

// ---------------------------------------------------------------------------
// §2.1 — the golden exemplar.
// ---------------------------------------------------------------------------

// TestACLExemplar: the rendered /acl subtree IS §2.1b — sequence-id 100 from
// priority 100 unchanged, the reserved terminal default-deny at 65535, the
// binding ethernet-1/1.100 with interface-ref {interface, subinterface} and
// input acl-filter[name][type] — with the filter type in the form the device
// returns it (the YANG leaf is an enumeration, never module-qualified in
// JSON_IETF; observed bare on 25.7.1's own datastore).
func TestACLExemplar(t *testing.T) {
	r := renderService(t, aclExemplarInput())
	const exemplar = `{
	  "acl-filter": [{
	    "name": "acl-svc-0042-ingress", "type": "ipv4",
	    "description": "tenant1/svc-0042 ingress", "statistics-per-entry": true,
	    "entry": [
	      {"sequence-id": 100, "description": "permit-https",
	       "match": {"ipv4": {"protocol": "tcp", "source-ip": {"prefix": "10.0.0.0/24"}},
	                 "transport": {"destination-port": {"operator": "eq", "value": 443}}},
	       "action": {"accept": {}}},
	      {"sequence-id": 65535, "description": "default-deny", "action": {"drop": {}}}
	    ]}],
	  "interface": [{
	    "interface-id": "ethernet-1/1.100",
	    "interface-ref": {"interface": "ethernet-1/1", "subinterface": 100},
	    "input": {"acl-filter": [{"name": "acl-svc-0042-ingress", "type": "ipv4"}]}
	  }]
	}`
	var wantTree any
	if err := json.Unmarshal([]byte(exemplar), &wantTree); err != nil {
		t.Fatal(err)
	}
	if got := aclSubtree(t, r["leaf01"].JSON); !reflect.DeepEqual(got, wantTree) {
		g, _ := json.MarshalIndent(got, "", "  ")
		t.Errorf("/acl is not the §2.1b exemplar:\n%s", g)
	}
	// the JSON encodings the golden depends on: presence containers {}, numbers
	js := string(r["leaf01"].JSON)
	for _, s := range []string{`"accept": {}`, `"drop": {}`, `"sequence-id": 65535`, `"value": 443`, `"subinterface": 100`} {
		if !strings.Contains(js, s) {
			t.Errorf("%s missing from the render", s)
		}
	}
	for _, s := range []string{`"accept": true`, `"accept": null`, `"sequence-id": "`, `"value": "`} {
		if strings.Contains(js, s) {
			t.Errorf("%s in the render", s)
		}
	}
}

// ---------------------------------------------------------------------------
// Entries: identity mapping, default action, match forms.
// ---------------------------------------------------------------------------

func TestACLNoDefaultActionNo65535(t *testing.T) {
	in := aclExemplarInput()
	in.AccessLists[0].DefaultAction = nil
	f := flattenService(t, renderService(t, in)["leaf01"].JSON)
	fp := "/acl/acl-filter[name=acl-svc-0042-ingress][type=ipv4]"
	want(t, f, fp+"/entry[sequence-id=100]/action/accept", "{}")
	for p := range f {
		if strings.Contains(p, "65535") {
			t.Errorf("no default action declared, yet %s is rendered", p)
		}
	}
	// permit renders an accept row at 65535 all the same (symmetric check set)
	in.AccessLists[0].DefaultAction = action(model.ActionAccept)
	f = flattenService(t, renderService(t, in)["leaf01"].JSON)
	want(t, f, fp+"/entry[sequence-id=65535]/action/accept", "{}")
	want(t, f, fp+"/entry[sequence-id=65535]/description", `"default-permit"`)
	if _, ok := f[fp+"/entry[sequence-id=65535]/match/ipv4/protocol"]; ok {
		t.Error("the default-action entry is match-all: it carries no match")
	}
}

// TestACLPrioritiesUnchanged: priorities 300, 100, 200 render as entries 300,
// 100, 200 — each rule at its own priority (no renumbering, no inversion),
// emitted in the device's ascending evaluation order.
func TestACLPrioritiesUnchanged(t *testing.T) {
	in := aclExemplarInput()
	in.AccessLists[0].DefaultAction = nil
	in.AccessLists[0].Rules = []model.ACLRule{
		{Name: "third", Priority: 300, Action: model.ActionDrop, Protocol: "udp"},
		{Name: "first", Priority: 100, Action: model.ActionAccept, Protocol: "tcp"},
		{Name: "second", Priority: 200, Action: model.ActionDrop, Protocol: "icmp"},
	}
	r := renderService(t, in)["leaf01"]
	f := flattenService(t, r.JSON)
	fp := "/acl/acl-filter[name=acl-svc-0042-ingress][type=ipv4]"
	for seq, name := range map[string]string{"100": "first", "200": "second", "300": "third"} {
		want(t, f, fp+"/entry[sequence-id="+seq+"]/description", `"`+name+`"`)
	}
	want(t, f, fp+"/entry[sequence-id=300]/action/drop", "{}")
	want(t, f, fp+"/entry[sequence-id=100]/action/accept", "{}")
	var doc struct {
		ACL struct {
			Filters []struct {
				Entries []struct {
					Seq uint32 `json:"sequence-id"`
				} `json:"entry"`
			} `json:"acl-filter"`
		} `json:"srl_nokia-acl:acl"`
	}
	if err := json.Unmarshal(r.JSON, &doc); err != nil {
		t.Fatal(err)
	}
	var seqs []uint32
	for _, e := range doc.ACL.Filters[0].Entries {
		seqs = append(seqs, e.Seq)
	}
	if !slices.Equal(seqs, []uint32{100, 200, 300}) {
		t.Errorf("entries %v, want 100, 200, 300", seqs)
	}
}

// TestACLEgress: stage egress → the output binding and subinterface-specific
// output-only on the filter; no input binding anywhere.
func TestACLEgress(t *testing.T) {
	for _, node := range leaves {
		f := flattenService(t, renderService(t, aclEgressInput())[node].JSON)
		fp := "/acl/acl-filter[name=acl-edge-egress][type=ipv6]"
		want(t, f, fp+"/subinterface-specific", `"output-only"`)
		want(t, f, fp+"/statistics-per-entry", "true")
		want(t, f, fp+"/description", `"tenant1/edge egress"`)
		ai := "/acl/interface[interface-id=ethernet-1/1.160]"
		want(t, f, ai+"/output/acl-filter[name=acl-edge-egress][type=ipv6]", "{}")
		want(t, f, ai+"/interface-ref/interface", `"ethernet-1/1"`)
		want(t, f, ai+"/interface-ref/subinterface", "160")
		for p := range f {
			if strings.Contains(p, "/input") {
				t.Errorf("%s: an egress list renders %s", node, p)
			}
		}
	}
	// ingress renders no subinterface-specific
	f := flattenService(t, renderService(t, aclExemplarInput())["leaf01"].JSON)
	if _, ok := f["/acl/acl-filter[name=acl-svc-0042-ingress][type=ipv4]/subinterface-specific"]; ok {
		t.Error("an ingress filter renders subinterface-specific")
	}
}

// TestACLIPv6ICMPv6Accepted: ICMPv6 is first-class — `icmpv6` renders the
// device's next-header enum icmp6, a number renders as a number (58); the
// prefixes sit under match/ipv6.
func TestACLIPv6ICMPv6Accepted(t *testing.T) {
	f := flattenService(t, renderService(t, aclEgressInput())["leaf01"].JSON)
	fp := "/acl/acl-filter[name=acl-edge-egress][type=ipv6]"
	want(t, f, fp+"/entry[sequence-id=100]/match/ipv6/next-header", `"icmp6"`)
	want(t, f, fp+"/entry[sequence-id=400]/match/ipv6/next-header", "58")
	want(t, f, fp+"/entry[sequence-id=300]/match/ipv6/source-ip/prefix", `"2001:db8:66::/48"`)
	want(t, f, fp+"/entry[sequence-id=200]/match/ipv6/destination-ip/prefix", `"2001:db8:160::/64"`)
	for p := range f {
		if strings.Contains(p, "/match/ipv4") || strings.Contains(p, "/protocol") {
			t.Errorf("an ipv6 filter renders %s", p)
		}
	}
}

// TestACLPortForms: a single port is operator eq + value (numbers); a range
// is range/start + range/end, never both forms.
func TestACLPortForms(t *testing.T) {
	f := flattenService(t, renderService(t, aclEgressInput())["leaf01"].JSON)
	fp := "/acl/acl-filter[name=acl-edge-egress][type=ipv6]"
	want(t, f, fp+"/entry[sequence-id=300]/match/transport/source-port/operator", `"eq"`)
	want(t, f, fp+"/entry[sequence-id=300]/match/transport/source-port/value", "53")
	want(t, f, fp+"/entry[sequence-id=200]/match/transport/destination-port/range/start", "8000")
	want(t, f, fp+"/entry[sequence-id=200]/match/transport/destination-port/range/end", "8100")
	for _, p := range []string{fp + "/entry[sequence-id=300]/match/transport/source-port/range/start",
		fp + "/entry[sequence-id=200]/match/transport/destination-port/operator", fp + "/entry[sequence-id=200]/match/transport/destination-port/value"} {
		if _, ok := f[p]; ok {
			t.Errorf("%s rendered beside the other port form", p)
		}
	}
}

// TestACLUntaggedBinding: an endpoint naming no VLAN binds subinterface 0 —
// ethernet-1/2.0 with interface-ref subinterface 0 (FR-037).
func TestACLUntaggedBinding(t *testing.T) {
	in := model.ServiceInput{ServiceID: "flat", Tenant: "t1", Construct: model.ConstructIPVRF, FabricASN: 65000,
		Routed: &model.RoutedService{L3VNI: 10170, IPMTU: 9348, Attachments: []model.RoutedAttachment{
			{Node: "leaf01", Port: "ethernet-1/2", IPv4: []string{"10.170.1.1/24"}}}},
		AccessLists: []model.AccessList{{Stage: model.StageIngress, Family: model.FamilyIPv4,
			Rules:    []model.ACLRule{{Name: "drop-telnet", Priority: 10, Action: model.ActionDrop, Protocol: "tcp", DestinationPort: &model.PortMatch{Lo: 23}}},
			Bindings: []model.ACLBinding{{Node: "leaf01", Port: "ethernet-1/2"}}}}}
	f := flattenService(t, renderService(t, in)["leaf01"].JSON)
	ai := "/acl/interface[interface-id=ethernet-1/2.0]"
	want(t, f, ai+"/interface-ref/interface", `"ethernet-1/2"`)
	want(t, f, ai+"/interface-ref/subinterface", "0")
	want(t, f, ai+"/input/acl-filter[name=acl-flat-ingress][type=ipv4]", "{}")
	// and standalone, on another service's untagged subinterface: no interface-ref
	sa := model.ServiceInput{ServiceID: "flat-guard", Construct: model.ConstructACL, AccessLists: in.AccessLists}
	f = flattenService(t, renderService(t, sa)["leaf01"].JSON)
	want(t, f, ai+"/input/acl-filter[name=acl-flat-guard-ingress][type=ipv4]", "{}")
	if _, ok := f[ai+"/interface-ref/subinterface"]; ok {
		t.Error("a standalone list renders the interface-ref of a subinterface it does not own")
	}
}

// ---------------------------------------------------------------------------
// Names: device-safe, refused, never rewritten.
// ---------------------------------------------------------------------------

func TestACLDeviceSafeNames(t *testing.T) {
	for stage, want := range map[model.Stage]string{model.StageIngress: "acl-svc-0042-ingress", model.StageEgress: "acl-svc-0042-egress"} {
		if got, err := model.FilterName("svc-0042", stage); err != nil || got != want {
			t.Errorf("FilterName(svc-0042, %s) = %q, %v", stage, got, err)
		}
	}
	if _, err := model.FilterName("Svc_42", model.StageIngress); err == nil {
		t.Error("a service id outside the device-safe alphabet was accepted (it must be refused, never rewritten)")
	}
	m, err := model.BuildService(aclExemplarInput())
	if err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"system", "capture", " leading-space", `acl-"quoted"`, "acl-star*", strings.Repeat("a", 256)} {
		n := cloneNode(m.Node("leaf01"))
		n.ACLFilters[0].Name = bad
		n.ACLInterfaces[0].Input[0].Name = bad
		_, err := srl.RenderServiceNode(n)
		if err == nil {
			t.Errorf("filter name %q rendered", bad)
			continue
		}
		if !strings.Contains(err.Error(), fmt.Sprintf("%q", bad)) {
			t.Errorf("filter name %q: the refusal does not name it unchanged: %v", bad, err)
		}
		if _, err := srl.ServiceLeafPaths(n); err == nil {
			t.Errorf("ServiceLeafPaths accepted filter name %q", bad)
		}
	}
	// a MAC filter is out of scope (FR-038)
	n := cloneNode(m.Node("leaf01"))
	n.ACLFilters[0].Type = "mac"
	n.ACLInterfaces[0].Input[0].Type = "mac"
	if _, err := srl.RenderServiceNode(n); err == nil || !strings.Contains(err.Error(), "mac") {
		t.Errorf("a mac filter was not refused by name: %v", err)
	}
}

// TestACLRendererGuards: what the device would refuse by a must, or what
// would bind nothing, is refused before a document exists.
func TestACLRendererGuards(t *testing.T) {
	m, err := model.BuildService(aclExemplarInput())
	if err != nil {
		t.Fatal(err)
	}
	base := m.Node("leaf01")
	cases := map[string]struct {
		mut  func(n *model.ServiceNode)
		text string
	}{
		"port on icmp":               {func(n *model.ServiceNode) { n.ACLFilters[0].Entries[0].Protocol = "icmp" }, "TCP or UDP"},
		"port with no protocol":      {func(n *model.ServiceNode) { n.ACLFilters[0].Entries[0].Protocol = "" }, "TCP or UDP"},
		"unknown protocol name":      {func(n *model.ServiceNode) { n.ACLFilters[0].Entries[0].Protocol = "carrier-pigeon" }, "carrier-pigeon"},
		"protocol above 255":         {func(n *model.ServiceNode) { n.ACLFilters[0].Entries[0].Protocol = "256" }, "256"},
		"binding without its filter": {func(n *model.ServiceNode) { n.ACLFilters = nil }, "acl-svc-0042-ingress"},
		"egress without subinterface-specific": {func(n *model.ServiceNode) {
			n.ACLInterfaces[0].Output, n.ACLInterfaces[0].Input = n.ACLInterfaces[0].Input, nil
		}, "subinterface-specific"},
		"a second filter of one family in one direction": {func(n *model.ServiceNode) {
			f := n.ACLFilters[0]
			f.Name = "acl-other-ingress"
			n.ACLFilters = append(n.ACLFilters, f)
			n.ACLInterfaces[0].Input = append(n.ACLInterfaces[0].Input, model.FilterRef{Name: "acl-other-ingress", Type: model.FamilyIPv4})
		}, "ethernet-1/1.100"},
		"interface-ref disagreeing with interface-id": {func(n *model.ServiceNode) { n.ACLInterfaces[0].Ref.Subinterface = 101 }, "ethernet-1/1.100"},
		"entry at 0":          {func(n *model.ServiceNode) { n.ACLFilters[0].Entries[0].SequenceID = 0 }, "sequence-id"},
		"wrong-family prefix": {func(n *model.ServiceNode) { n.ACLFilters[0].Entries[0].SourcePrefix = "2001:db8::/32" }, "2001:db8::/32"},
	}
	for name, c := range cases {
		n := cloneNode(base)
		c.mut(n)
		_, err := srl.RenderServiceNode(n)
		if err == nil {
			t.Errorf("%s: rendered", name)
			continue
		}
		if !strings.Contains(err.Error(), c.text) {
			t.Errorf("%s: refusal %q does not name %q", name, err, c.text)
		}
	}
	// and the unmodified node renders
	mustRenderNode(t, cloneNode(base))
}

func cloneNode(n *model.ServiceNode) *model.ServiceNode {
	c := *n
	c.ACLFilters = nil
	for _, f := range n.ACLFilters {
		f.Entries = slices.Clone(f.Entries)
		c.ACLFilters = append(c.ACLFilters, f)
	}
	c.ACLInterfaces = nil
	for _, ai := range n.ACLInterfaces {
		ai.Input, ai.Output = slices.Clone(ai.Input), slices.Clone(ai.Output)
		if ai.Ref != nil {
			r := *ai.Ref
			ai.Ref = &r
		}
		c.ACLInterfaces = append(c.ACLInterfaces, ai)
	}
	return &c
}

// ---------------------------------------------------------------------------
// One transaction for a service; the binding entry only for a standalone list.
// ---------------------------------------------------------------------------

// TestACLServiceSameDocument: a mac-vrf carrying an access list renders the
// filter and its binding in the SAME per-node document as the rest of the
// service — its network-instance, subinterface and interface-ref (FR-036).
func TestACLServiceSameDocument(t *testing.T) {
	in := macvrfInput()
	in.AccessLists = []model.AccessList{{Stage: model.StageIngress, Family: model.FamilyIPv6, DefaultAction: action(model.ActionDrop),
		Rules:    []model.ACLRule{{Name: "permit-icmpv6", Priority: 10, Action: model.ActionAccept, Protocol: "icmp6"}},
		Bindings: []model.ACLBinding{{Node: "leaf01", Port: "ethernet-1/1", VLAN: 200}, {Node: "leaf02", Port: "ethernet-1/1", VLAN: 200}}}}
	r := renderService(t, in)
	for _, node := range leaves {
		f := flattenService(t, r[node].JSON)
		want(t, f, "/network-instance[name=macvrf-app]/interface[name=ethernet-1/1.200]", "{}")
		want(t, f, "/interface[name=ethernet-1/1]/subinterface[index=200]/type", `"srl_nokia-interfaces:bridged"`)
		want(t, f, "/tunnel-interface[name=vxlan0]/vxlan-interface[index=10200]/ingress/vni", "10200")
		want(t, f, "/acl/acl-filter[name=acl-app-ingress][type=ipv6]/entry[sequence-id=10]/match/ipv6/next-header", `"icmp6"`)
		want(t, f, "/acl/acl-filter[name=acl-app-ingress][type=ipv6]/entry[sequence-id=65535]/action/drop", "{}")
		ai := "/acl/interface[interface-id=ethernet-1/1.200]"
		want(t, f, ai+"/interface-ref/interface", `"ethernet-1/1"`)
		want(t, f, ai+"/interface-ref/subinterface", "200")
		want(t, f, ai+"/input/acl-filter[name=acl-app-ingress][type=ipv6]", "{}")
		var top map[string]json.RawMessage
		if err := json.Unmarshal(r[node].JSON, &top); err != nil {
			t.Fatal(err)
		}
		for _, k := range []string{"srl_nokia-acl:acl", "srl_nokia-interfaces:interface", "srl_nokia-network-instance:network-instance", "srl_nokia-tunnel-interfaces:tunnel-interface"} {
			if _, ok := top[k]; !ok {
				t.Errorf("%s: %s not in the one per-node document", node, k)
			}
		}
	}
}

// TestACLStandaloneOnlyFilterAndBinding: a standalone list's document carries
// ONLY its filter and the input|output acl-filter entry under
// /acl/interface[interface-id] — no interface-ref, no interface, no
// network-instance — and shares no leaf with the render of the service that
// owns the subinterface (FR-015, AD-68).
func TestACLStandaloneOnlyFilterAndBinding(t *testing.T) {
	r := renderService(t, aclStandaloneInput())
	if !slices.Equal(sortedKeysR(r), []string{"leaf01"}) {
		t.Fatalf("rendered on %v, want leaf01 only", sortedKeysR(r))
	}
	var top map[string]json.RawMessage
	if err := json.Unmarshal(r["leaf01"].JSON, &top); err != nil {
		t.Fatal(err)
	}
	if len(top) != 1 || top["srl_nokia-acl:acl"] == nil {
		t.Fatalf("a standalone document carries %v, want srl_nokia-acl:acl alone", keysOf(top))
	}
	f := flattenService(t, r["leaf01"].JSON)
	const bind = "/acl/interface[interface-id=ethernet-1/1.110]/input/acl-filter[name=acl-guard-ingress][type=ipv4]"
	want(t, f, bind, "{}")
	for p := range f {
		if p != bind && !strings.HasPrefix(p, "/acl/acl-filter[name=acl-guard-ingress][type=ipv4]/") {
			t.Errorf("a standalone list renders %s", p)
		}
	}
	// the owner (vlan golden service web: ethernet-1/1.110 on leaf01) and the
	// standalone list share no leaf — the owner's interface-ref is the owner's
	owner := flattenService(t, renderService(t, vlanInput())["leaf01"].JSON)
	want(t, owner, "/acl/interface[interface-id=ethernet-1/1.110]/interface-ref/subinterface", "110")
	for p := range f {
		if _, shared := owner[p]; shared {
			t.Errorf("leaf %s is written by both the owner and the standalone list", p)
		}
	}
}

func keysOf(m map[string]json.RawMessage) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	slices.Sort(out)
	return out
}

// ---------------------------------------------------------------------------
// Register and determinism.
// ---------------------------------------------------------------------------

// TestACLRenderedPathsInRegister: every access-list render's leaf paths are
// exactly the model's WritePaths(), which the register guard drives, and are
// covered by the service-owned write register (FR-017).
func TestACLRenderedPathsInRegister(t *testing.T) {
	for name, in := range aclGoldenInputs(t) {
		m, err := model.BuildService(in)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		for i := range m.Nodes {
			n := &m.Nodes[i]
			r := mustRenderNode(t, n)
			got := unqualify(sortedKeys(flattenService(t, r.JSON)))
			if !slices.Equal(got, n.WritePaths()) {
				t.Errorf("%s/%s: rendered paths != WritePaths()\n only rendered: %v\n only WritePaths: %v",
					name, n.Node, minus(got, n.WritePaths()), minus(n.WritePaths(), got))
			}
			tree, err := srl.ServiceLeafPaths(n)
			if err != nil {
				t.Fatal(err)
			}
			if err := register.CheckServicePaths(n.Node, tree); err != nil {
				t.Errorf("%s: %v", name, err)
			}
		}
	}
}

// TestACLStableBytesAndHash: repeated runs and any order of rules and
// bindings give byte-identical documents and hashes (Rule 2, SC-016).
func TestACLStableBytesAndHash(t *testing.T) {
	rng := rand.New(rand.NewSource(104))
	for name, in := range aclGoldenInputs(t) {
		base := renderService(t, in)
		for i := 0; i < 25; i++ {
			p := permute(rng, in)
			p.AccessLists = slices.Clone(p.AccessLists)
			for j := range p.AccessLists {
				al := &p.AccessLists[j]
				al.Rules, al.Bindings = slices.Clone(al.Rules), slices.Clone(al.Bindings)
				rng.Shuffle(len(al.Rules), func(a, b int) { al.Rules[a], al.Rules[b] = al.Rules[b], al.Rules[a] })
				rng.Shuffle(len(al.Bindings), func(a, b int) { al.Bindings[a], al.Bindings[b] = al.Bindings[b], al.Bindings[a] })
			}
			got := renderService(t, p)
			for n, r := range base {
				if got[n].Hash != r.Hash || !bytes.Equal(got[n].JSON, r.JSON) {
					t.Fatalf("%s permutation %d: %s render differs", name, i, n)
				}
			}
		}
	}
}

// TestACLGoldensFilterForm: every access-list golden carries its filter type
// as the device's own enumeration value (ipv4 | ipv6, unqualified — the YANG
// leaf is an enumeration, and the device returns it bare), statistics-per-entry
// true on every filter, and presence-container actions.
func TestACLGoldensFilterForm(t *testing.T) {
	entries, err := filepath.Glob(filepath.Join(serviceGoldenDir, "acl_*.json"))
	if err != nil || len(entries) < 5 {
		t.Fatalf("access-list goldens %v (%v)", entries, err)
	}
	for _, g := range entries {
		b, err := os.ReadFile(g)
		if err != nil {
			t.Fatal(err)
		}
		var doc struct {
			ACL struct {
				Filters []map[string]any `json:"acl-filter"`
			} `json:"srl_nokia-acl:acl"`
		}
		if err := json.Unmarshal(b, &doc); err != nil {
			t.Fatal(err)
		}
		if len(doc.ACL.Filters) == 0 {
			t.Errorf("%s: no filter", g)
		}
		for _, f := range doc.ACL.Filters {
			if ty := f["type"]; ty != "ipv4" && ty != "ipv6" {
				t.Errorf("%s: filter type %v", g, ty)
			}
			if f["statistics-per-entry"] != true {
				t.Errorf("%s: statistics-per-entry %v", g, f["statistics-per-entry"])
			}
			for _, e := range f["entry"].([]any) {
				act := e.(map[string]any)["action"].(map[string]any)
				for k, v := range act {
					if m, ok := v.(map[string]any); !ok || len(m) != 0 || (k != "accept" && k != "drop") {
						t.Errorf("%s: action %s = %v, want a presence container {}", g, k, v)
					}
				}
			}
		}
	}
}
