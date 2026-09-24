package migration

// T105 (FR-035…FR-040, FR-097, SC-015; contracts/acl-render-contract.md §3, §6;
// contracts/network-spec.md §2–§3; contracts/translator-api.md): the access-list refusal fixtures,
// run through the BUILT CLI exactly as quickstart.md §6 runs them — non-zero exit, the structured
// {"error":"validation","causes":[…]} on stderr, NO YAML on stdout, every cause naming its property
// path and the offending rule — and the two positive goldens: the standalone `acl` construct, and a
// standalone `acl` naming VLAN 1500, which translates because an acl attachment's VLAN is a
// reference held to the structural 100–4000 alone (AD-47).
//
// Where each refusal is decided. The translator sees the request and the site inventory
// (FABRIC_NODE_MAP / FABRIC_PORT_MAP / FABRIC_ASN) and nothing else — never the cluster. So:
//
//   - every per-list rule (priorities, names, families, ports, type, stage, reserved names, a
//     reference by name, a network-instance binding, no endpoints) is decided here, per service;
//   - a cross-service rule is decided here exactly as far as the request itself decides it, the way
//     refuse_node_port_vlan_taken is (two services of one request deriving one subinterface):
//     refuse_acl_second_list_same_subinterface is two lists of one request on one (node, port,
//     subinterface, direction, family); refuse_acl_standalone_no_attachment and
//     refuse_acl_standalone_untagged_no_attachment are standalone lists naming a subinterface the
//     same request makes impossible — the request puts the port in the other tagging mode (one mode
//     per port, AD-20), so no service can have created it. Against the Networks already in the
//     cluster the same two rules are the admission webhook's (internal/webhook
//     CheckBindings / CheckStandaloneSubinterface, contracts/network-spec.md §5 rules 8–9), which
//     TestACLRulesTheTranslatorCannotSee drives on the translator's own output;
//   - refuse_acl_egress_unqualified: the translator is never given the qualification record (the
//     sidecar reads only the site inventory), so it cannot decide FR-097. The contract puts that
//     refusal at interpretation (the mapper, before any claim) and the webhook's Unqualified row
//     is its backstop; this suite translates the fixture and proves the webhook's rule refuses the
//     result naming acl.egress — and admits it once the record shows egress qualified. It is the one
//     refuse_* fixture the CLI translates, and TestEveryTranslatorRefusalFixtureRefuses says so.

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/yaml"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/webhook"
)

// decidedByTheWebhook are the refuse_* fixtures whose refusal needs data the translator is never
// given; each is proved against the layer that holds it in TestACLRulesTheTranslatorCannotSee.
var decidedByTheWebhook = map[string]string{
	"refuse_acl_egress_unqualified.json": "FR-097: the qualification record is the mapper's and the webhook's input, never the translator's",
}

func TestACLRefusalFixturesThroughTheCLI(t *testing.T) {
	for _, tc := range []struct {
		fixture string
		// path: the property path one cause starts with; want: substrings that cause holds;
		// never: substrings no cause may hold.
		path  string
		want  []string
		never []string
	}{
		{"dup_priority", "acl.rules[1].priority: ", []string{`"deny-telnet"`, `"allow-https"`, "100", "distinct", "ascending priority, first match wins"}, nil},
		{"dup_name", "acl.rules[1].name: ", []string{`"allow-web"`, "acl.rules[0]", "distinct"}, nil},
		{"family_mismatch", "acl.rules[0].sourcePrefix: ", []string{`"allow-v6-mgmt"`, "2001:db8:ffff::/48", "IPv6", "ipv4"}, nil},
		{"l4_on_non_tcp_udp", "acl.rules[0].destinationPort: ", []string{`"allow-sctp-sig"`, "sctp", "tcp (6)", "udp (17)"}, nil},
		{"no_rules", "acl.rules: ", []string{"at least one rule"}, nil},
		{"type_mac", "acl.type: ", []string{"mac", "out of scope", "address families"}, []string{"lacks", "does not support", "not supported by the device", "unsupported by the device"}},
		{"priority_reserved", "acl.rules[1].priority: ", []string{`"deny-rest"`, "65535", "reserved for the default action", "1–65534", "ascending priority, first match wins"}, nil},
		{"reserved_name", "acl.name: ", []string{`"system"`, "reserved"}, nil},
		{"reference_by_name", "acl: ", []string{`"corp-web-filter"`, "reference", "cannot be referenced by another"}, nil},
		{"binding_network_instance", "endpoints[0].vrf: ", []string{"vrf-4b7e19c2a05d3f6", "network instance", "leaf01 ethernet-1/1.100"}, nil},
		{"no_stage", "acl.stage: ", []string{"required", "ingress", "egress"}, nil},
		{"port_range_inverted", "acl.rules[0].destinationPort: ", []string{`"allow-alt-https"`, "8443-443", "inverted"}, nil},
		{"no_endpoints", "endpoints: ", []string{"attachment subinterface", "never fabric-wide"}, nil},
		{"standalone_no_attachment", "input[1].endpoints[0]: ", []string{"leaf01 ethernet-1/1.300", "does not exist", "never creates", "untagged", "input[0].endpoints[0]"}, nil},
		{"standalone_untagged_no_attachment", "input[1].endpoints[0]: ", []string{"leaf01 ethernet-1/1.0", "does not exist", "never creates", "tagged", "input[0].endpoints[0]"}, nil},
		{"second_list_same_subinterface", "input[1].endpoints[0]: ", []string{"leaf01 ethernet-1/1.100", "ingress", "ipv4", "held by service 5e8c2a4b6d1f3c7", "one list per subinterface, direction and address family"}, nil},
	} {
		t.Run(tc.fixture, func(t *testing.T) {
			r := runCLI(t, "refuse_acl_"+tc.fixture+".json")
			if r.code != 1 {
				t.Fatalf("exit %d; want 1, a refusal (stdout %q, stderr %s)", r.code, r.stdout, r.stderr)
			}
			if len(r.stdout) != 0 {
				t.Errorf("stdout is not empty — no YAML may be emitted on a refusal:\n%s", r.stdout)
			}
			var e StructuredError
			dec := json.NewDecoder(bytes.NewReader(r.stderr))
			dec.DisallowUnknownFields()
			if err := dec.Decode(&e); err != nil {
				t.Fatalf("stderr is not the structured error: %v\n%s", err, r.stderr)
			}
			if e.Error != "validation" || len(e.Causes) == 0 {
				t.Fatalf("stderr %s; want error validation with causes", r.stderr)
			}
			found := false
			for _, c := range e.Causes {
				if !strings.Contains(c, ": ") || strings.HasPrefix(c, " ") {
					t.Errorf("cause %q does not start with a property path", c)
				}
				for _, n := range tc.never {
					if strings.Contains(c, n) {
						t.Errorf("cause %q says %q", c, n)
					}
				}
				if !strings.HasPrefix(c, tc.path) {
					continue
				}
				all := true
				for _, w := range tc.want {
					all = all && strings.Contains(c, w)
				}
				found = found || all
			}
			if !found {
				t.Errorf("no cause starts with %q and holds %q; causes:\n  %s", tc.path, tc.want, strings.Join(e.Causes, "\n  "))
			}
		})
	}
}

// The standalone construct and the allocated-VLAN reference translate, through the CLI and in
// process, to their goldens byte for byte; the emitted object carries accessLists[] and
// attachments[] only and decodes strictly into the Network API type.
func TestACLGoldens(t *testing.T) {
	for _, c := range []string{"acl", "acl_references_allocated_vlan"} {
		t.Run(c, func(t *testing.T) {
			golden := read(t, "construct_"+c+".spec.golden.yaml")
			r := runCLI(t, "construct_"+c+".json")
			if r.code != 0 || len(r.stderr) != 0 {
				t.Fatalf("exit %d, stderr %s", r.code, r.stderr)
			}
			if !bytes.HasSuffix(r.stdout, golden) {
				t.Errorf("the CLI output does not end with the golden spec block:\n%s", r.stdout)
			}
			res := mustTranslate(t, read(t, "construct_"+c+".json"), labOptions(t))
			n := res.Manifests[0]
			if got := n.Spec.YAML(); got != string(golden) {
				t.Errorf("spec differs from construct_%s.spec.golden.yaml\n--- got\n%s--- want\n%s", c, got, golden)
			}
			if len(n.Spec.VLANs)+len(n.Spec.BridgeDomains)+len(n.Spec.Routers) != 0 || len(n.Spec.AccessLists) != 1 {
				t.Errorf("a standalone acl emits accessLists[] and attachments[] only, got %+v", n.Spec)
			}
			for _, forbidden := range []string{"vlans:", "bridgeDomains:", "routers:", "vrf:", "l2vni", "l3vni", "routeTargets"} {
				if strings.Contains(res.YAML, forbidden) {
					t.Errorf("the emitted object carries %q", forbidden)
				}
			}
			if n.Metadata.Annotations[AnnotationServiceType] != ConstructACL {
				t.Errorf("service-type %q", n.Metadata.Annotations[AnnotationServiceType])
			}
			var strict fabricv1.Network
			if err := yaml.UnmarshalStrict([]byte(res.YAML), &strict); err != nil {
				t.Errorf("the YAML does not decode strictly into fabricv1.Network: %v", err)
			}
			var fromJSON fabricv1.Network
			dec := json.NewDecoder(bytes.NewReader(n.JSON()))
			dec.DisallowUnknownFields()
			if err := dec.Decode(&fromJSON); err != nil {
				t.Errorf("the JSON manifest does not decode strictly into fabricv1.Network: %v", err)
			}
			if !webhook.StandaloneACL(&strict.Spec) {
				t.Error("the provider does not read the emitted object as a standalone access list")
			}
			again := mustTranslate(t, read(t, "construct_"+c+".json"), labOptions(t))
			if again.YAML != res.YAML || !bytes.Equal(again.Manifests[0].JSON(), n.JSON()) {
				t.Error("two translations of one input differ")
			}
			assertKeyOrder(t, c, res.YAML)
			assertACLKeyOrder(t, c, res.YAML)
		})
	}
	// AD-47: the reference VLAN is held to the structural 100–4000 only.
	for _, v := range []int64{100, 999, 1000, 1500, 4000} {
		data := bytes.ReplaceAll(read(t, "construct_acl.json"), []byte(`"vlan": 100`), []byte(`"vlan": `+itoa(v)))
		if _, err := TranslateJSON(data, labOptions(t)); err != nil {
			t.Errorf("acl reference VLAN %d refused: %v", v, err)
		}
	}
	for _, v := range []int64{99, 4001} {
		data := bytes.ReplaceAll(read(t, "construct_acl.json"), []byte(`"vlan": 100`), []byte(`"vlan": `+itoa(v)))
		_, err := TranslateJSON(data, labOptions(t))
		if err == nil || !strings.Contains(err.Error(), "100–999") || !strings.Contains(err.Error(), "1000–4000") {
			t.Errorf("acl reference VLAN %d: want the structural refusal stating both bands, got %v", v, err)
		}
	}
}

// assertACLKeyOrder checks network-spec.md §3 within an access list and a rule.
func assertACLKeyOrder(t *testing.T, name, y string) {
	t.Helper()
	i := strings.Index(y, "\n  accessLists:\n")
	if i < 0 {
		t.Fatalf("%s: no accessLists", name)
	}
	block := y[i:strings.Index(y, "\n  attachments:")]
	order := func(s string, keys ...string) {
		last := -1
		for _, k := range keys {
			j := strings.Index(s, k)
			if j < 0 {
				continue
			}
			if j < last {
				t.Errorf("%s: %q is out of the network-spec.md §3 order", name, strings.TrimSpace(k))
			}
			last = j
		}
	}
	order(block, "\n  - name:", "\n    stage:", "\n    type:", "\n    defaultAction:", "\n    rules:")
	for _, r := range strings.Split(block, "\n    - ")[1:] {
		order("\n      "+r, "\n      name:", "\n      priority:", "\n      action:", "\n      protocol:", "\n      sourcePrefix:",
			"\n      destinationPrefix:", "\n      sourcePort:", "\n      destinationPort:", "\n      description:")
	}
}

// An acl as a property of another construct is a field on that construct's own Network (FR-036,
// FR-060): the same object, the same attachments, one accessLists[] entry named
// acl-<serviceId>-<stage>; nothing else in the object changes.
func TestACLOnAConstruct(t *testing.T) {
	const list = `"acl":{"name":"web","stage":"ingress","type":"ipv4","defaultAction":"deny","evaluationOrder":"ascending-first-match","unmatchedTraffic":"deny",
	  "rules":[{"name":"allow-https","priority":100,"action":"permit","protocol":"tcp","sourcePrefix":"10.0.0.0/24","destinationPort":"443","description":"operator https allowance"}]},`
	for _, c := range []string{"vlan", "macvrf", "ipvrf"} {
		t.Run(c, func(t *testing.T) {
			plain := read(t, "construct_"+c+".json")
			with := bytes.Replace(plain, []byte(`"endpoints"`), []byte(list+`"endpoints"`), 1)
			base := mustTranslate(t, plain, labOptions(t)).Manifests[0]
			res := mustTranslate(t, with, labOptions(t))
			n := res.Manifests[0]
			sid := n.Metadata.Name[len("migr-"):]
			if len(n.Spec.AccessLists) != 1 {
				t.Fatalf("accessLists %+v", n.Spec.AccessLists)
			}
			al := n.Spec.AccessLists[0]
			if al.Name != "acl-"+sid+"-ingress" || al.Stage != "ingress" || al.Type != "ipv4" || al.DefaultAction != "deny" ||
				len(al.Rules) != 1 || al.Rules[0].Priority != 100 || al.Rules[0].DestinationPort != "443" {
				t.Errorf("access list %+v", al)
			}
			withoutACL := n.Spec
			withoutACL.AccessLists = nil
			if withoutACL.YAML() != base.Spec.YAML() {
				t.Errorf("the access list changed the rest of the object:\n%s\nvs\n%s", withoutACL.YAML(), base.Spec.YAML())
			}
			if n.Metadata.Annotations[AnnotationServiceType] != base.Metadata.Annotations[AnnotationServiceType] {
				t.Error("the access list changed the service type")
			}
			var strict fabricv1.Network
			if err := yaml.UnmarshalStrict([]byte(res.YAML), &strict); err != nil {
				t.Fatalf("strict decode: %v", err)
			}
			if webhook.StandaloneACL(&strict.Spec) {
				t.Error("an acl on a construct was emitted as a standalone list")
			}
			assertKeyOrder(t, c, res.YAML)
			assertACLKeyOrder(t, c, res.YAML)
		})
	}
	// ... and a list carried by a request that states an order other than the platform's is refused.
	bad := bytes.Replace(read(t, "construct_vlan.json"), []byte(`"endpoints"`),
		[]byte(`"acl":{"stage":"ingress","type":"ipv4","evaluationOrder":"descending","unmatchedTraffic":"deny","rules":[{"name":"r","priority":1,"action":"permit"}]},"endpoints"`), 1)
	_, err := TranslateJSON(bad, labOptions(t))
	causes := strings.Join(ErrorCauses(err), "\n")
	if !strings.Contains(causes, "acl.evaluationOrder: ") || !strings.Contains(causes, "ascending priority, first match wins") ||
		!strings.Contains(causes, "acl.unmatchedTraffic: ") {
		t.Errorf("causes %s", causes)
	}
}

// The spellings l3 / ip fold to ipv4 and l3v6 / ipv6 to ipv6, in/inbound to ingress and
// out/outbound to egress, icmpv6 to icmp6 — on entry, so the emitted spec and the canonical input
// hash do not depend on the spelling (FR-038, translator-api.md).
func TestACLTypeStageAndProtocolFolding(t *testing.T) {
	base := func(typ, stage, proto, prefix string) []byte {
		return []byte(`{"serviceId":"5c8a2e4f6b1d3a7","type":"acl","tenant":"acme","acl":{"stage":"` + stage + `","type":"` + typ + `",
		  "rules":[{"name":"r","priority":10,"action":"permit","protocol":"` + proto + `","sourcePrefix":"` + prefix + `"}]},
		  "endpoints":[{"node":"leaf01","attachment":"ethernet-1/1","vlan":100}]}`)
	}
	for _, tc := range []struct {
		fam, prefix, proto, wantProto string
		types, stages                 []string
		stage                         string
	}{
		{"ipv4", "10.0.0.0/8", "tcp", "tcp", []string{"ipv4", "l3", "ip", "L3", "IPv4", "IP"}, []string{"ingress", "in", "inbound", "Ingress"}, "ingress"},
		{"ipv6", "2001:db8::/32", "icmpv6", "icmp6", []string{"ipv6", "l3v6", "L3v6", "IPv6", "l3-v6"}, []string{"egress", "out", "outbound", "EGRESS"}, "egress"},
	} {
		want := mustTranslate(t, base(tc.fam, tc.stage, tc.wantProto, tc.prefix), labOptions(t)).Manifests[0]
		for _, typ := range tc.types {
			for _, st := range tc.stages {
				n := mustTranslate(t, base(typ, st, tc.proto, tc.prefix), labOptions(t)).Manifests[0]
				al := n.Spec.AccessLists[0]
				if al.Type != tc.fam || al.Stage != tc.stage || al.Rules[0].Protocol != tc.wantProto {
					t.Errorf("type %q stage %q protocol %q: emitted %s/%s/%s", typ, st, tc.proto, al.Type, al.Stage, al.Rules[0].Protocol)
				}
				if n.Spec.YAML() != want.Spec.YAML() || n.Metadata.Annotations[AnnotationInputHash] != want.Metadata.Annotations[AnnotationInputHash] {
					t.Errorf("type %q stage %q: the spec or the input hash depends on the spelling", typ, st)
				}
			}
		}
	}
	// A protocol the Network API names only by number is emitted as its number; any 0–255 is valid.
	for proto, want := range map[string]string{"egp": "8", "rsvp": "46", "l2tp": "115", "ipv6-hop": "0", "gre": "gre", "sctp": "sctp", "58": "58", "255": "255"} {
		n := mustTranslate(t, base("ipv4", "ingress", proto, "10.0.0.0/8"), labOptions(t)).Manifests[0]
		if got := n.Spec.AccessLists[0].Rules[0].Protocol; got != want {
			t.Errorf("protocol %q emitted as %q, want %q", proto, got, want)
		}
	}
	numeric := bytes.Replace(base("ipv4", "ingress", "x", "10.0.0.0/8"), []byte(`"protocol":"x"`), []byte(`"protocol":6,"destinationPort":"443"`), 1)
	if n := mustTranslate(t, numeric, labOptions(t)).Manifests[0]; n.Spec.AccessLists[0].Rules[0].Protocol != "6" {
		t.Errorf("protocol 6: %+v", n.Spec.AccessLists[0].Rules[0])
	}
}

// In-process refusals the fixture set does not cover, each naming the offending rule.
func TestACLRefusalsInProcess(t *testing.T) {
	std := func(aclJSON, eps string) string {
		return `{"serviceId":"a1","type":"acl","tenant":"t","acl":` + aclJSON + `,"endpoints":` + eps + `}`
	}
	ep := `[{"node":"leaf01","attachment":"ethernet-1/1","vlan":100}]`
	for in, want := range map[string]string{
		std(`{"stage":"ingress","type":"ipv4","rules":[{"name":"r0","priority":0,"action":"permit"}]}`, ep):                                                                                                                   `acl.rules[0].priority: rule "r0": priority 0 is outside the usable range 1–65534`,
		std(`{"stage":"ingress","type":"ipv4","rules":[{"name":"r9","priority":70000,"action":"permit"}]}`, ep):                                                                                                               `acl.rules[0].priority: rule "r9": priority 70000 is outside the usable range 1–65534`,
		std(`{"stage":"sideways","type":"ipv4","rules":[{"name":"r","priority":1,"action":"permit"}]}`, ep):                                                                                                                   `acl.stage: "sideways" is not a stage`,
		std(`{"stage":"ingress","type":"ipv9","rules":[{"name":"r","priority":1,"action":"permit"}]}`, ep):                                                                                                                    `acl.type: "ipv9" is not an access-list type`,
		std(`{"stage":"ingress","type":"ipv4","defaultAction":"drop","rules":[{"name":"r","priority":1,"action":"permit"}]}`, ep):                                                                                             `acl.defaultAction: "drop" is not permit or deny`,
		std(`{"stage":"ingress","type":"ipv4","rules":[{"name":"r","priority":1,"action":"accept"}]}`, ep):                                                                                                                    `acl.rules[0].action: rule "r": "accept" is not permit or deny`,
		std(`{"stage":"ingress","type":"ipv4","rules":[{"name":"r","priority":1,"action":"permit","protocol":"quic"}]}`, ep):                                                                                                  `acl.rules[0].protocol: rule "r": "quic" is not an IP protocol`,
		std(`{"stage":"ingress","type":"ipv4","rules":[{"name":"r","priority":1,"action":"permit","protocol":300}]}`, ep):                                                                                                     `acl.rules[0].protocol: rule "r": 300 is not an IP protocol`,
		std(`{"stage":"ingress","type":"ipv4","rules":[{"name":"r","priority":1,"action":"permit","destinationPort":"443"}]}`, ep):                                                                                            `acl.rules[0].destinationPort: rule "r": an L4 port match requires protocol tcp (6) or udp (17)`,
		std(`{"stage":"ingress","type":"ipv4","rules":[{"name":"r","priority":1,"action":"permit","protocol":"udp","sourcePort":"70000"}]}`, ep):                                                                              `acl.rules[0].sourcePort: rule "r": "70000" is not a port 0–65535`,
		std(`{"stage":"ingress","type":"ipv4","rules":[{"name":"r","priority":1,"action":"permit","destinationPrefix":"10.0.0.1/8"}]}`, ep):                                                                                   `acl.rules[0].destinationPrefix: rule "r": 10.0.0.1/8 has host bits set`,
		std(`{"stage":"ingress","type":"ipv6","rules":[{"name":"r","priority":1,"action":"permit","destinationPrefix":"10.0.0.0/8"}]}`, ep):                                                                                   `acl.rules[0].destinationPrefix: rule "r": 10.0.0.0/8 is an IPv4 prefix in an ipv6 access list`,
		std(`{"stage":"ingress","type":"ipv4","rules":[{"name":"","priority":1,"action":"permit"}]}`, ep):                                                                                                                     `acl.rules[0].name: required`,
		std(`{"stage":"ingress","type":"ipv4","name":"CAPTURE","rules":[{"name":"r","priority":1,"action":"permit"}]}`, ep):                                                                                                   `acl.name: "CAPTURE" is reserved`,
		std(`{"stage":"ingress","type":"ipv4","rules":[{"name":"r","priority":1,"action":"permit"}]}`, `[{"node":"leaf01","attachment":"irb0","vlan":100}]`):                                                                  `endpoints[0].attachment: irb0 is an integrated-routing (IRB) interface`,
		std(`{"stage":"ingress","type":"ipv4","rules":[{"name":"r","priority":1,"action":"permit"}]}`, `[{"node":"leaf01","attachment":"ethernet-1/1","vlan":100},{"node":"leaf01","attachment":"ethernet-1/1","vlan":100}]`): "endpoints[1]: duplicates endpoints[0]",
		`{"serviceId":"a1","type":"acl","tenant":"t","l2vni":10021,"acl":{"stage":"ingress","type":"ipv4","rules":[{"name":"r","priority":1,"action":"permit"}]},"endpoints":` + ep + `}`:                                     "l2vni: an acl carries no L2VNI",
		`{"serviceId":"a1","type":"acl","tenant":"t","endpoints":` + ep + `}`:                                                                                                                                                 "acl: required for an acl",
	} {
		_, err := TranslateJSON([]byte(in), labOptions(t))
		if err == nil {
			t.Errorf("accepted: %s", in)
			continue
		}
		if !strings.Contains(strings.Join(ErrorCauses(err), "\n"), want) {
			t.Errorf("%s\n  causes %q\n  want one containing %q", in, ErrorCauses(err), want)
		}
	}
	// ICMPv6 is accepted (FR-040): no refusal is reinstated for it.
	ok := std(`{"stage":"ingress","type":"ipv6","rules":[{"name":"nd","priority":1,"action":"permit","protocol":"icmpv6"},{"name":"v6","priority":2,"action":"permit","protocol":58}]}`, ep)
	if _, err := TranslateJSON([]byte(ok), labOptions(t)); err != nil {
		t.Errorf("icmpv6 refused: %v", err)
	}
}

// Exclusivity is (node, port, subinterface, direction, family): an IPv4 and an IPv6 list on one
// subinterface, two lists on different subinterfaces of one port, and one list per direction do
// not conflict; a standalone list on a subinterface another service of the request creates is
// bound (contracts/acl-render-contract.md §6).
func TestACLExclusivityUnitInOneRequest(t *testing.T) {
	svc := string(read(t, "construct_macvrf.json")) // leaf01/leaf02 ethernet-1/1 VLAN 100, no list
	list := func(sid, stage, typ, prefix string, eps string) string {
		return `{"serviceId":"` + sid + `","type":"acl","tenant":"acme","acl":{"stage":"` + stage + `","type":"` + typ + `",
		  "rules":[{"name":"r","priority":10,"action":"deny","sourcePrefix":"` + prefix + `"}]},"endpoints":` + eps + `}`
	}
	on100 := `[{"node":"leaf01","attachment":"ethernet-1/1","vlan":100}]`
	vlan200 := `{"serviceId":"c1","type":"vlan","tenant":"acme","endpoints":[{"node":"leaf01","attachment":"ethernet-1/1","vlan":200}]}`
	for name, batch := range map[string]string{
		"ipv4 and ipv6 on one subinterface":      "[" + svc + "," + list("b1", "ingress", "ipv4", "10.0.0.0/8", on100) + "," + list("b2", "ingress", "ipv6", "2001:db8::/32", on100) + "]",
		"ingress and egress on one subinterface": "[" + svc + "," + list("b1", "ingress", "ipv4", "10.0.0.0/8", on100) + "," + list("b2", "egress", "ipv4", "10.0.0.0/8", on100) + "]",
		"different subinterfaces of one port": "[" + svc + "," + vlan200 + "," +
			list("b1", "ingress", "ipv4", "10.0.0.0/8", on100) + "," + list("b2", "ingress", "ipv4", "10.0.0.0/8", `[{"node":"leaf01","attachment":"ethernet-1/1","vlan":200}]`) + "]",
	} {
		if _, err := TranslateJSON([]byte(batch), labOptions(t)); err != nil {
			t.Errorf("%s: refused: %v", name, err)
		}
	}
	// The same family and direction twice on one subinterface: refused naming the holder.
	_, err := TranslateJSON([]byte("["+svc+","+list("b1", "ingress", "ipv4", "10.0.0.0/8", on100)+","+list("b2", "ingress", "ipv4", "10.1.0.0/16", on100)+"]"), labOptions(t))
	if c := strings.Join(ErrorCauses(err), "\n"); !strings.Contains(c, "input[2].endpoints[0]: leaf01 ethernet-1/1.100 already carries the ingress ipv4 access list of service b1") ||
		!strings.Contains(c, "held by service b1") {
		t.Errorf("causes %s", c)
	}
}

// TestACLRulesTheTranslatorCannotSee drives the translator's own output through the layer that
// holds what the translator is never given — the admission webhook's rules over the other
// Networks and the qualification record — so every refusal of the set is proved where it is decided.
func TestACLRulesTheTranslatorCannotSee(t *testing.T) {
	decode := func(file string, mutate func([]byte) []byte) fabricv1.Network {
		t.Helper()
		data := read(t, file)
		if mutate != nil {
			data = mutate(data)
		}
		res := mustTranslate(t, data, labOptions(t))
		var n fabricv1.Network
		if err := yaml.UnmarshalStrict([]byte(res.YAML), &n); err != nil {
			t.Fatal(err)
		}
		n.Namespace = "agentic-netops-intent"
		return n
	}
	record := func(egress bool) webhook.Qualification {
		cm := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Namespace: webhook.QualificationNamespace, Name: webhook.QualificationName},
			Data: map[string]string{"acl": "qualified", "acl.ingress-ipv4": "qualified", "acl.ingress-ipv6": "qualified",
				"acl.binding-without-filter": "qualified", "acl.egress": "unqualified"}}
		if egress {
			cm.Data["acl.egress"] = "qualified"
		}
		return webhook.QualificationFromConfigMap(cm)
	}

	t.Run("egress_unqualified: translated, then refused by the Unqualified rule naming acl.egress", func(t *testing.T) {
		n := decode("refuse_acl_egress_unqualified.json", nil)
		if n.Spec.AccessLists[0].Stage != "egress" {
			t.Fatalf("stage %q", n.Spec.AccessLists[0].Stage)
		}
		vs := webhook.CheckQualified(&n.Spec, record(false))
		if len(vs) != 1 || vs[0].Rule != webhook.RuleQualification || !strings.Contains(vs[0].Message, "acl.egress") {
			t.Fatalf("violations %v; want one Unqualified naming acl.egress", vs)
		}
		if vs := webhook.CheckQualified(&n.Spec, record(true)); len(vs) != 0 {
			t.Errorf("egress qualified, still refused: %v", vs)
		}
	})

	owner := decode("construct_macvrf.json", nil) // leaf01/leaf02 ethernet-1/1.100
	owner.Name = "migr-4b7e19c2a05d3f6"
	t.Run("standalone list alone in its request: bound where a Network created the subinterface, refused naming it where none did", func(t *testing.T) {
		acl := decode("construct_acl.json", nil)
		vs := webhook.CheckStandaloneSubinterface(&acl, nil)
		if len(vs) != 2 || !strings.Contains(vs[0].Message, "leaf01 ethernet-1/1.100 does not exist") || !strings.Contains(vs[0].Message, "never creates one") {
			t.Fatalf("violations %v", vs)
		}
		if vs := webhook.CheckStandaloneSubinterface(&acl, []fabricv1.Network{owner}); len(vs) != 0 {
			t.Errorf("the owner exists, still refused: %v", vs)
		}
		untagged := decode("construct_acl.json", func(b []byte) []byte {
			var m map[string]any
			if err := json.Unmarshal(b, &m); err != nil {
				t.Fatal(err)
			}
			for _, e := range m["endpoints"].([]any) {
				delete(e.(map[string]any), "vlan")
			}
			out, _ := json.Marshal(m)
			return out
		})
		vs = webhook.CheckStandaloneSubinterface(&untagged, []fabricv1.Network{owner})
		if len(vs) != 2 || !strings.Contains(vs[0].Message, "leaf01 ethernet-1/1.0 does not exist") {
			t.Fatalf("untagged: violations %v", vs)
		}
		// The allocated-VLAN reference binds like any other (AD-47).
		ref := decode("construct_acl_references_allocated_vlan.json", nil)
		held := decode("construct_macvrf_allocated_vlan.json", nil)
		if vs := webhook.CheckStandaloneSubinterface(&ref, []fabricv1.Network{held}); len(vs) != 0 {
			t.Errorf("VLAN 1500 reference refused: %v", vs)
		}
	})
	t.Run("second list against a Network already in the cluster: refused naming the holder", func(t *testing.T) {
		first := decode("construct_acl.json", nil)
		first.Name = "migr-5c8a2e4f6b1d3a7"
		second := decode("construct_acl.json", func(b []byte) []byte {
			return bytes.Replace(b, []byte("5c8a2e4f6b1d3a7"), []byte("5c8a2e4f6b1d3a8"), 1)
		})
		vs := webhook.CheckBindings(&second, []fabricv1.Network{first})
		if len(vs) != 2 || !strings.Contains(vs[0].Message, "Network agentic-netops-intent/migr-5c8a2e4f6b1d3a7") {
			t.Fatalf("violations %v", vs)
		}
		v6 := decode("construct_acl.json", func(b []byte) []byte {
			b = bytes.Replace(b, []byte("5c8a2e4f6b1d3a7"), []byte("5c8a2e4f6b1d3a9"), 1)
			b = bytes.Replace(b, []byte(`"type": "ipv4"`), []byte(`"type": "ipv6"`), 1)
			return bytes.Replace(b, []byte("10.0.0.0/24"), []byte("2001:db8::/64"), 1)
		})
		if vs := webhook.CheckBindings(&v6, []fabricv1.Network{first}); len(vs) != 0 {
			t.Errorf("ipv6 beside ipv4 refused: %v", vs)
		}
	})
}

// Every refuse_acl_* fixture named by T105 exists (quickstart.md §6 runs them by name).
func TestACLFixtureSetIsComplete(t *testing.T) {
	for _, f := range []string{"dup_priority", "dup_name", "family_mismatch", "l4_on_non_tcp_udp", "no_rules", "type_mac",
		"priority_reserved", "reserved_name", "reference_by_name", "binding_network_instance", "no_stage", "port_range_inverted",
		"no_endpoints", "standalone_no_attachment", "standalone_untagged_no_attachment", "egress_unqualified", "second_list_same_subinterface"} {
		if _, err := os.Stat(filepath.Join(testdata, "refuse_acl_"+f+".json")); err != nil {
			t.Error(err)
		}
	}
}
