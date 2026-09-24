package migration

// T119 (FR-044…FR-047, SC-018, R-07, R-27; contracts/construct-vocabulary.md §2, §6,
// contracts/network-spec.md §1, §3, contracts/reconciliation.md Rule 1, quickstart.md §7): the
// migration aliases — the brownfield vocabulary this path exists to read — are folded on entry
// before any validator sees them; the emitted type is the construct and the arrival vocabulary is
// provenance only, in the fixed annotation order with one owner per key; the emitted `spec:` block
// is byte-identical to the same service named by its construct (TestConstructLegacyEquivalence, the
// test quickstart.md §7 runs by name, AD-66); the point-to-point limited equivalence needs an
// explicit opt-in and leaves a durable finding; source-scoped constraints bind alias inputs only;
// unmapped source properties reject the whole request naming the exact field; raw device CLI is
// never an accepted input.

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
)

// aliasFixtures are the four supported_*.json fixtures: each names a migration alias and translates.
var aliasFixtures = []struct {
	file      string // supported_<file>.json and supported_<file>.spec.golden.yaml
	alias     string // the type as the fixture spells it
	construct string // what it folds to
	source    string // the arrival vocabulary recorded
}{
	{"supported_vpls", "VPLS", ConstructMACVRF, SourceVPLS},
	{"supported_vpws_optin", "VPWS", ConstructMACVRF, SourceVPWS},
	{"supported_l3vpn", "L3VPN", ConstructIPVRF, SourceL3VPN},
	{"supported_irb", "L2L3-IRB", ConstructMACVRF, SourceL2L3IRB},
}

// intentTierAnnotationKeys are the intent tier's audit keys (network-spec.md §1, §3): stamped by the
// deployer after the translator's, never by the translator.
var intentTierAnnotationKeys = []string{
	"agentic-netops.io/intent-thread-id",
	"agentic-netops.io/intent-principal",
	"agentic-netops.io/intent-submitted-at",
	"agentic-netops.io/intent-submitted-spec-sha256",
}

// withField returns the JSON object data with key set to value (nil deletes it).
func withField(t *testing.T, data []byte, key string, value any) []byte {
	t.Helper()
	var m map[string]json.RawMessage
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatal(err)
	}
	if value == nil {
		delete(m, key)
	} else {
		b, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		m[key] = b
	}
	out, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// asConstruct is the same service expressed with the construct name. A direct construct request
// neither needs nor accepts the point-to-point opt-in (policyCauses), so it is dropped.
func asConstruct(t *testing.T, data []byte, construct string) []byte {
	t.Helper()
	return withField(t, withField(t, data, "type", construct), "policies", nil)
}

func mustRefuse(t *testing.T, data []byte, opt Options) []string {
	t.Helper()
	res, err := TranslateJSON(data, opt)
	if err == nil {
		t.Fatalf("accepted; want a refusal:\n%s", data)
	}
	if res != nil {
		t.Errorf("a refusal emitted output: %+v", res)
	}
	return ErrorCauses(err)
}

func hasCause(causes []string, prefix string, want ...string) bool {
	for _, c := range causes {
		if !strings.HasPrefix(c, prefix) {
			continue
		}
		all := true
		for _, w := range want {
			all = all && strings.Contains(c, w)
		}
		if all {
			return true
		}
	}
	return false
}

// SC-018: every alias fixture emits, byte for byte, the `spec:` block of the same service named by
// its construct — compared directly, and against the golden file.
func TestConstructLegacyEquivalence(t *testing.T) {
	for _, f := range aliasFixtures {
		t.Run(f.file, func(t *testing.T) {
			legacy := read(t, f.file+".json")
			a := mustTranslate(t, legacy, labOptions(t))
			c := mustTranslate(t, asConstruct(t, legacy, f.construct), labOptions(t))
			if len(a.Manifests) != 1 || len(c.Manifests) != 1 {
				t.Fatalf("want one manifest each, got %d and %d", len(a.Manifests), len(c.Manifests))
			}
			aliasSpec, constructSpec := []byte(a.Manifests[0].Spec.YAML()), []byte(c.Manifests[0].Spec.YAML())
			if !bytes.Equal(aliasSpec, constructSpec) {
				t.Errorf("the spec: block differs between the %s and %s vocabularies\n--- %s\n%s--- %s\n%s", f.alias, f.construct, f.alias, aliasSpec, f.construct, constructSpec)
			}
			golden := read(t, f.file+".spec.golden.yaml")
			if !bytes.Equal(aliasSpec, golden) {
				t.Errorf("spec block differs from %s.spec.golden.yaml\n--- got\n%s--- want\n%s", f.file, aliasSpec, golden)
			}
			if !strings.HasSuffix(a.YAML, string(golden)) || !strings.HasSuffix(c.YAML, string(golden)) {
				t.Error("an emitted document does not end with the golden spec block")
			}
			// the same fabric outcome: the whole object differs only in the migration provenance
			if !reflect.DeepEqual(a.Manifests[0].Spec, c.Manifests[0].Spec) || a.Manifests[0].Metadata.Name != c.Manifests[0].Metadata.Name {
				t.Error("the alias and construct forms emit different objects")
			}
			for _, k := range []string{AnnotationServiceType, AnnotationTenant, AnnotationInputHash} {
				if k == AnnotationInputHash && f.source == SourceVPWS {
					continue // the construct form drops the opt-in, which is part of the request as submitted
				}
				if a.Manifests[0].Metadata.Annotations[k] != c.Manifests[0].Metadata.Annotations[k] {
					t.Errorf("%s: %q (alias) vs %q (construct)", k, a.Manifests[0].Metadata.Annotations[k], c.Manifests[0].Metadata.Annotations[k])
				}
			}
		})
	}
}

// The catalogue is the contract's six rows, and every spelling of an alias folds by Key.
func TestAliasCatalogue(t *testing.T) {
	want := []Alias{
		{"vpls", ConstructMACVRF, "VPLS"}, {"vpws", ConstructMACVRF, "VPWS"}, {"eline", ConstructMACVRF, "VPWS"},
		{"l3vpn", ConstructIPVRF, "L3VPN"}, {"l2l3irb", ConstructMACVRF, "L2L3-IRB"}, {"irb", ConstructMACVRF, "L2L3-IRB"},
	}
	if got := Aliases(); !reflect.DeepEqual(got, want) {
		t.Errorf("Aliases() = %+v\nwant %+v", got, want)
	}
	for spelling, w := range map[string]Alias{
		"VPLS": want[0], "vpws": want[1], "E-Line": want[2], "e_line": want[2], "L3VPN": want[3], "l3-vpn": want[3],
		"L2L3-IRB": want[4], "l2l3 irb": want[4], "IRB": want[5],
	} {
		c, s, ok := FoldAlias(spelling)
		if !ok || c != w.Construct || s != w.Source {
			t.Errorf("FoldAlias(%q) = %q, %q, %v; want %q, %q", spelling, c, s, ok, w.Construct, w.Source)
		}
		if r, ok := Canonicalize(spelling); !ok || r != (Resolution{Construct: w.Construct, Source: w.Source}) {
			t.Errorf("Canonicalize(%q) = %+v, %v", spelling, r, ok)
		}
	}
	// constructs and synonyms are not aliases: they fold with no arrival vocabulary
	for _, name := range []string{"mac-vrf", "ip-vrf", "vlan", "acl", "l2vni", "l3vni", "access-list", "evpn-magic", ""} {
		if c, s, ok := FoldAlias(name); ok {
			t.Errorf("FoldAlias(%q) = %q, %q; a construct, synonym or unknown name is no alias", name, c, s)
		}
		if r, ok := Canonicalize(name); ok && r.Source != "" {
			t.Errorf("Canonicalize(%q) recorded an arrival vocabulary %q", name, r.Source)
		}
	}
}

// FR-044: an alias is folded before any validator sees it. The parser's output already carries the
// construct as its type and the vocabulary as provenance; a construct-level error in an alias
// request names the construct, never the alias as a type.
func TestAliasFoldedBeforeValidation(t *testing.T) {
	for _, f := range aliasFixtures {
		inputs, _, err := ParseStrictBatch(read(t, f.file+".json"))
		if err != nil {
			t.Fatalf("%s: %v", f.file, err)
		}
		if inputs[0].Type != f.construct || inputs[0].SourceType != f.source {
			t.Errorf("%s: parsed type %q source %q; want %q, %q", f.file, inputs[0].Type, inputs[0].SourceType, f.construct, f.source)
		}
		// folding again (TranslateBatch does) changes nothing
		again := inputs[0]
		foldOnEntry(&again)
		if !reflect.DeepEqual(again, inputs[0]) {
			t.Errorf("%s: foldOnEntry is not idempotent: %+v", f.file, again)
		}
	}
	// every alias spelling, in a batch: each item folded on entry
	var items []string
	for _, a := range Aliases() {
		items = append(items, `{"serviceId":"x","type":"`+strings.ToUpper(a.Key)+`","tenant":"t","endpoints":[]}`)
	}
	inputs, _, err := ParseStrictBatch([]byte("[" + strings.Join(items, ",") + "]"))
	if err != nil {
		t.Fatal(err)
	}
	for i, a := range Aliases() {
		if inputs[i].Type != a.Construct || inputs[i].SourceType != a.Source {
			t.Errorf("%s: parsed %q / %q", a.Key, inputs[i].Type, inputs[i].SourceType)
		}
	}

	opt := labOptions(t)
	for _, tc := range []struct {
		name, file string
		edit       func([]byte) []byte
		prefix     string
		want       []string
	}{
		{"VPLS carrying an L3VNI without a gateway", "supported_vpls", func(b []byte) []byte { return withField(t, b, "l3vni", 10039) },
			"l3vni: ", []string{"a mac-vrf carries an L3VNI only with an anycastGateway"}},
		{"VPLS without its L2VNI", "supported_vpls", func(b []byte) []byte { return withField(t, b, "l2vni", nil) },
			"l2vni: ", []string{"required for a mac-vrf"}},
		{"L3VPN carrying an L2VNI", "supported_l3vpn", func(b []byte) []byte { return withField(t, b, "l2vni", 10039) },
			"l2vni: ", []string{"an ip-vrf carries no bridge domain"}},
		{"L3VPN carrying a gateway", "supported_l3vpn", func(b []byte) []byte {
			return withField(t, b, "anycastGateway", map[string]string{"gatewayIPv4": "10.33.0.1/24"})
		}, "anycastGateway: ", []string{"an ip-vrf carries no anycast gateway", "mac-vrf"}},
		{"L2L3-IRB gateway without its L3VNI", "supported_irb", func(b []byte) []byte { return withField(t, b, "l3vni", nil) },
			"l3vni: ", []string{"required for a mac-vrf with an anycastGateway"}},
		{"VPWS without route targets", "supported_vpws_optin", func(b []byte) []byte { return withField(t, b, "routeTargets", nil) },
			"routeTargets: ", []string{"required for a mac-vrf"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			causes := mustRefuse(t, tc.edit(read(t, tc.file+".json")), opt)
			if !hasCause(causes, tc.prefix, tc.want...) {
				t.Errorf("no cause starts with %q and holds %q:\n  %s", tc.prefix, tc.want, strings.Join(causes, "\n  "))
			}
			for _, c := range causes {
				if strings.HasPrefix(c, "type:") {
					t.Errorf("the alias reached the type check: %q", c)
				}
				for _, alias := range []string{"VPLS", "L3VPN", "L2L3-IRB"} {
					if strings.Contains(c, alias) {
						t.Errorf("cause %q names the alias %s; a validator only ever sees the construct", c, alias)
					}
				}
			}
		})
	}

	// The arrival vocabulary is recorded by folding only; a request cannot claim it.
	for _, key := range []string{"SourceType", "sourceType", "source-service-type"} {
		causes := mustRefuse(t, withField(t, read(t, "construct_macvrf.json"), key, "VPLS"), opt)
		if !hasCause(causes, key+": ", `unknown field "`+key+`"`) {
			t.Errorf("%s: causes %q", key, causes)
		}
	}
}

var aliasAsType = regexp.MustCompile(`(?mi)^\s*agentic-netops\.io/service-type:\s*"?(vpls|vpws|e-?line|l3vpn|l2l3-?irb|irb)"?\s*$`)

// FR-044, FR-085: the emitted type is the construct; no output — YAML, JSON, description — carries
// an alias as a type. The arrival vocabulary appears once, as the source-service-type annotation.
func TestAliasEmitsConstructType(t *testing.T) {
	for _, f := range aliasFixtures {
		res := mustTranslate(t, read(t, f.file+".json"), labOptions(t))
		n := res.Manifests[0]
		if got := n.Metadata.Annotations[AnnotationServiceType]; got != f.construct {
			t.Errorf("%s: service-type %q, want the construct %q", f.file, got, f.construct)
		}
		if got := n.Metadata.Annotations[AnnotationSourceServiceType]; got != f.source {
			t.Errorf("%s: source-service-type %q, want %q", f.file, got, f.source)
		}
		if aliasAsType.MatchString(res.YAML) {
			t.Errorf("%s: the YAML carries an alias as the service type:\n%s", f.file, res.YAML)
		}
		if !strings.Contains(res.YAML, "\n    "+AnnotationServiceType+": "+f.construct+"\n") {
			t.Errorf("%s: the YAML does not carry service-type %s", f.file, f.construct)
		}
		if want := "  description: Service " + strings.TrimPrefix(n.Metadata.Name, "migr-") + " (" + f.construct + ")\n"; !strings.Contains(res.YAML, want) {
			t.Errorf("%s: the description does not name the construct:\n%s", f.file, res.YAML)
		}
		// The vocabulary appears exactly once, and only on the provenance line — in the YAML and the
		// JSON alike; never in the spec.
		if strings.Count(res.YAML, f.source) != 1 || !strings.Contains(res.YAML, "\n    "+AnnotationSourceServiceType+": "+f.source+"\n") {
			t.Errorf("%s: %q appears other than once, on the source-service-type line:\n%s", f.file, f.source, res.YAML)
		}
		if strings.Contains(n.Spec.YAML(), f.source) || strings.Contains(strings.ToLower(n.Spec.YAML()), strings.ToLower(f.alias)) {
			t.Errorf("%s: the spec carries the alias or its vocabulary", f.file)
		}
		j := string(n.JSON())
		if strings.Count(j, f.source) != 1 || !strings.Contains(j, `"`+AnnotationSourceServiceType+`":"`+f.source+`"`) ||
			!strings.Contains(j, `"`+AnnotationServiceType+`":"`+f.construct+`"`) {
			t.Errorf("%s: JSON manifest %s", f.file, j)
		}
	}
}

// FR-046, network-spec.md §1, §3: the annotations are the single provenance record. The translator's
// keys appear in the fixed emission order, each exactly once; the migration keys only for an alias;
// the intent tier's keys are disjoint from the translator's and never stamped here.
func TestAliasProvenanceAnnotations(t *testing.T) {
	keys := TranslatorAnnotationKeys()
	wantOrder := []string{
		"agentic-netops.io/translator", "agentic-netops.io/translator-version", "agentic-netops.io/mapping-version",
		"agentic-netops.io/migration-input-hash", "agentic-netops.io/tenant", "agentic-netops.io/service-type",
		"agentic-netops.io/source-service-type", "agentic-netops.io/limited-equivalence",
	}
	if !reflect.DeepEqual(keys, wantOrder) {
		t.Errorf("TranslatorAnnotationKeys() = %q\nwant %q", keys, wantOrder)
	}
	for _, k := range intentTierAnnotationKeys {
		for _, own := range keys {
			if k == own {
				t.Errorf("%s is the intent tier's key and also the translator's; each key has one owner", k)
			}
		}
	}

	annotationLine := regexp.MustCompile(`^    (agentic-netops\.io/[a-z0-9-]+): (.*)$`)
	for _, f := range aliasFixtures {
		res := mustTranslate(t, read(t, f.file+".json"), labOptions(t))
		n := res.Manifests[0]
		// the annotation lines of the YAML document, in the order written
		var got []string
		head := res.YAML[:strings.Index(res.YAML, "\nspec:\n")]
		for _, l := range strings.Split(head[strings.Index(head, "  annotations:\n")+len("  annotations:\n"):], "\n") {
			m := annotationLine.FindStringSubmatch(l)
			if m == nil {
				t.Errorf("%s: %q in the annotations block is not an annotation", f.file, l)
				continue
			}
			got = append(got, m[1])
		}
		want := wantOrder[:7]
		if f.source == SourceVPWS {
			want = wantOrder
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s: annotation keys in the order written\n  %q\nwant\n  %q", f.file, got, want)
		}
		for _, k := range append(append([]string{}, keys...), intentTierAnnotationKeys...) {
			if c := strings.Count(res.YAML, "\n    "+k+": "); c > 1 {
				t.Errorf("%s: %s appears %d times", f.file, k, c)
			}
		}
		for _, k := range intentTierAnnotationKeys {
			if _, ok := n.Metadata.Annotations[k]; ok || strings.Contains(res.YAML, k) {
				t.Errorf("%s: the translator stamped the intent tier's %s", f.file, k)
			}
		}
		if len(n.Metadata.Annotations) != len(want) {
			t.Errorf("%s: %d annotations, want %d: %v", f.file, len(n.Metadata.Annotations), len(want), n.Metadata.Annotations)
		}

		// The record reads back off the annotations, and stamps back to them.
		p := ProvenanceFromAnnotations(n.Metadata.Annotations)
		wantP := Provenance{
			Translator: TranslatorName, TranslatorVersion: TranslatorVersion, MappingVersion: MappingVersion,
			InputHash: n.Metadata.Annotations[AnnotationInputHash], Tenant: n.Metadata.Annotations[AnnotationTenant],
			ServiceType: f.construct, SourceServiceType: f.source,
		}
		if f.source == SourceVPWS {
			wantP.LimitedEquivalence = LimitedEquivalenceVPWS
		}
		if p != wantP || !p.Migrated() || !strings.HasPrefix(p.InputHash, "sha256:") || p.Tenant == "" {
			t.Errorf("%s: ProvenanceFromAnnotations = %+v\nwant %+v", f.file, p, wantP)
		}
		if !reflect.DeepEqual(p.Annotations(), n.Metadata.Annotations) {
			t.Errorf("%s: the record does not round-trip: %v", f.file, p.Annotations())
		}
		// keys the translator does not own are ignored on read
		withTier := map[string]string{}
		for k, v := range n.Metadata.Annotations {
			withTier[k] = v
		}
		for _, k := range intentTierAnnotationKeys {
			withTier[k] = "x"
		}
		if ProvenanceFromAnnotations(withTier) != p {
			t.Errorf("%s: an intent-tier key changed the translator's provenance", f.file)
		}
	}

	// A direct construct request: construct provenance only, no migration keys.
	n := mustTranslate(t, read(t, "construct_macvrf.json"), labOptions(t)).Manifests[0]
	if p := ProvenanceFromAnnotations(n.Metadata.Annotations); p.Migrated() || p.LimitedEquivalence != "" || p.ServiceType != ConstructMACVRF {
		t.Errorf("direct mac-vrf: %+v", p)
	}
}

// D-19: the arrival vocabulary is excluded from the canonical hash, so a service hashes identically
// in either vocabulary.
func TestAliasCanonicalHashIsVocabularyIndependent(t *testing.T) {
	hash := func(data []byte) string {
		return mustTranslate(t, data, labOptions(t)).Manifests[0].Metadata.Annotations[AnnotationInputHash]
	}
	for _, f := range aliasFixtures {
		legacy := read(t, f.file+".json")
		h := hash(legacy)
		if f.source != SourceVPWS {
			if c := hash(asConstruct(t, legacy, f.construct)); c != h {
				t.Errorf("%s: input hash %s (alias) vs %s (construct)", f.file, h, c)
			}
		}
		// every spelling of the same vocabulary, and of its sibling alias, hashes alike
		for _, a := range Aliases() {
			if a.Source != f.source {
				continue
			}
			for _, spelling := range []string{a.Key, strings.ToUpper(a.Key)} {
				if s := hash(withField(t, legacy, "type", spelling)); s != h {
					t.Errorf("%s as %q: input hash %s, want %s", f.file, spelling, s, h)
				}
			}
		}
	}
}

// FR-045, FR-047, reconciliation.md Rule 1: the point-to-point L2 source maps onto a mac-vrf only
// as a limited equivalence the request explicitly opts into. Without the opt-in (absent or false)
// the whole request is refused naming policies.vpwsLimitedEquivalence and nothing is emitted. With
// it, the Network carries the limited-equivalence annotation — the durable status finding: it lives
// on the service intent object for as long as the object does, and the MigrationPlan controller
// surfaces it (by key, never restating it) rather than recording it a second time.
func TestVPWSLimitedEquivalenceOptIn(t *testing.T) {
	opt := labOptions(t)
	optin := read(t, "supported_vpws_optin.json")
	for name, data := range map[string][]byte{
		"no policies":                    withField(t, optin, "policies", nil),
		"policies without the opt-in":    withField(t, optin, "policies", map[string]any{}),
		"opt-in false":                   withField(t, optin, "policies", map[string]any{"vpwsLimitedEquivalence": false}),
		"E-Line without the opt-in":      withField(t, withField(t, optin, "type", "E-Line"), "policies", nil),
		"batch: VPWS without the opt-in": []byte("[" + string(read(t, "supported_vpls.json")) + "," + string(withField(t, optin, "policies", nil)) + "]"),
	} {
		t.Run(name, func(t *testing.T) {
			causes := mustRefuse(t, data, opt)
			prefix := "policies.vpwsLimitedEquivalence: "
			if strings.HasPrefix(name, "batch") {
				prefix = "input[1]." + prefix
			}
			if !hasCause(causes, prefix, "must be true", "limited equivalence") {
				t.Errorf("causes %q; want one naming %s", causes, prefix)
			}
		})
	}

	res := mustTranslate(t, optin, opt)
	n := res.Manifests[0]
	if LimitedEquivalenceVPWS != "vpws-to-mac-vrf" {
		t.Errorf("the limited-equivalence marker is %q, want vpws-to-mac-vrf", LimitedEquivalenceVPWS)
	}
	if got := n.Metadata.Annotations[AnnotationLimitedEquivalence]; got != LimitedEquivalenceVPWS {
		t.Errorf("limited-equivalence %q, want %q", got, LimitedEquivalenceVPWS)
	}
	if !strings.Contains(res.YAML, "\n    agentic-netops.io/limited-equivalence: vpws-to-mac-vrf\nspec:\n") {
		t.Errorf("the finding is not the last translator annotation:\n%s", res.YAML)
	}
	// no other vocabulary is a limited equivalence
	for _, f := range aliasFixtures {
		if f.source == SourceVPWS {
			continue
		}
		if v, ok := mustTranslate(t, read(t, f.file+".json"), opt).Manifests[0].Metadata.Annotations[AnnotationLimitedEquivalence]; ok {
			t.Errorf("%s: limited-equivalence %q", f.file, v)
		}
	}
	// the opt-in belongs to the point-to-point vocabulary alone: on any other request it is refused
	for _, tc := range []struct{ file, typ string }{
		{"supported_vpls.json", ""}, {"supported_l3vpn.json", ""}, {"supported_irb.json", ""}, {"construct_macvrf.json", ""},
		{"supported_vpws_optin.json", ConstructMACVRF},
	} {
		data := withField(t, read(t, tc.file), "policies", map[string]any{"vpwsLimitedEquivalence": true})
		if tc.typ != "" {
			data = withField(t, data, "type", tc.typ)
		}
		if causes := mustRefuse(t, data, opt); !hasCause(causes, "policies.vpwsLimitedEquivalence: ", "meaningful only for a request that arrived as the point-to-point migration alias") {
			t.Errorf("%s %s: causes %q", tc.file, tc.typ, causes)
		}
	}
}

// FR-047, construct-vocabulary.md §6: constraints that belong to a source vocabulary bind the
// requests that arrived in it, and never a request naming the construct directly.
func TestSourceScopedConstraints(t *testing.T) {
	// a site with a third leaf, so three distinct attachments exist
	opt, err := ParseOptions(`{"leaf01":"leaf","leaf02":"leaf","leaf03":"leaf","spine01":"spine"}`,
		`{"leaf01":["ethernet-1/1"],"leaf02":["ethernet-1/1"],"leaf03":["ethernet-1/1"],"spine01":[]}`, "65000")
	if err != nil {
		t.Fatal(err)
	}
	vpws := read(t, "supported_vpws_optin.json")
	ep := func(node string) map[string]any {
		return map[string]any{"node": node, "attachment": "ethernet-1/1", "vlan": 132}
	}
	three := withField(t, vpws, "endpoints", []any{ep("leaf01"), ep("leaf02"), ep("leaf03")})
	one := withField(t, vpws, "endpoints", []any{ep("leaf01")})

	for name, data := range map[string][]byte{"3 endpoints": three, "1 endpoint": one} {
		causes := mustRefuse(t, data, opt)
		n := strings.Split(name, " ")[0]
		if !hasCause(causes, "endpoints: ", "the point-to-point migration alias (VPWS) requires exactly 2 endpoints, got "+n) {
			t.Errorf("VPWS with %s: causes %q", name, causes)
		}
	}
	// E-Line is the same vocabulary, and the same constraint
	if causes := mustRefuse(t, withField(t, three, "type", "eline"), opt); !hasCause(causes, "endpoints: ", "exactly 2 endpoints, got 3") {
		t.Errorf("E-Line with 3 endpoints: causes %q", causes)
	}

	// The same service naming mac-vrf directly: neither constraint applies.
	direct := asConstruct(t, three, ConstructMACVRF)
	inputs, _, err := ParseStrictBatch(direct)
	if err != nil || inputs[0].SourceType != "" {
		t.Fatalf("direct mac-vrf parsed with source %q: %v", inputs[0].SourceType, err)
	}
	res := mustTranslate(t, direct, opt)
	n := res.Manifests[0]
	if len(n.Spec.Attachments) != 3 || n.Metadata.Annotations[AnnotationServiceType] != ConstructMACVRF {
		t.Errorf("direct mac-vrf with 3 endpoints: %+v", n)
	}
	for _, k := range []string{AnnotationSourceServiceType, AnnotationLimitedEquivalence} {
		if v, ok := n.Metadata.Annotations[k]; ok || strings.Contains(res.YAML, k) {
			t.Errorf("direct mac-vrf carries %s %q; migration provenance is only for an alias", k, v)
		}
	}
	// … and another multipoint vocabulary is not bound by the point-to-point one's constraints.
	vpls := withField(t, withField(t, three, "type", "VPLS"), "policies", nil)
	if n := mustTranslate(t, vpls, opt).Manifests[0]; len(n.Spec.Attachments) != 3 || n.Metadata.Annotations[AnnotationSourceServiceType] != SourceVPLS {
		t.Errorf("VPLS with 3 endpoints: %+v", n)
	}
}

// FR-045, Rule 1: a source property with no qualified target equivalent — traffic engineering,
// pseudowire OAM, multicast VPN, QoS the platform does not map — rejects the entire request, naming
// the exact field and the feature, and nothing is emitted.
func TestAliasUnmappedPropertiesRejected(t *testing.T) {
	opt := labOptions(t)
	unsupported := []struct{ key, feature string }{
		{"trafficEngineering", "traffic-engineering"},
		{"pseudowireOam", "pseudowire-oam"},
		{"controlWord", "control-word"},
		{"multicastVpn", "multicast-vpn"},
		{"qos", "complex-qos"},
	}
	for _, f := range aliasFixtures {
		for _, u := range unsupported {
			t.Run(f.file+"/"+u.key, func(t *testing.T) {
				data := withField(t, read(t, f.file+".json"), "unsupported", map[string]any{u.key: map[string]any{"from": "the source service"}})
				causes := mustRefuse(t, data, opt)
				want := "unsupported." + u.key + ": unsupported feature: " + u.feature + "; the platform refuses it rather than translating the rest without it"
				if len(causes) != 1 || causes[0] != want {
					t.Errorf("causes %q\nwant exactly [%q]", causes, want)
				}
			})
		}
	}
	// every unsupported property of one request is named, each by its own path
	data := withField(t, read(t, "supported_vpws_optin.json"), "unsupported", map[string]any{"pseudowireOam": true, "trafficEngineering": true, "mvpn": true})
	causes := mustRefuse(t, data, opt)
	for _, want := range []string{"unsupported.mvpn: unsupported feature: multicast-vpn", "unsupported.pseudowireOam: unsupported feature: pseudowire-oam", "unsupported.trafficEngineering: unsupported feature: traffic-engineering"} {
		if !hasCause(causes, want) {
			t.Errorf("causes %q; want one starting %q", causes, want)
		}
	}
	// a source property outside the normalized intent altogether is an unknown field, never ignored
	for _, key := range []string{"pseudowire", "qosPolicy", "multicast", "teTunnel"} {
		causes := mustRefuse(t, withField(t, read(t, "supported_vpls.json"), key, map[string]any{"x": 1}), opt)
		if !hasCause(causes, key+": ", `unknown field "`+key+`"`, "never ignored") {
			t.Errorf("%s: causes %q", key, causes)
		}
	}
	// all-or-nothing: a valid alias beside one carrying TE emits nothing
	te := withField(t, withField(t, read(t, "supported_l3vpn.json"), "serviceId", "7c3e5a9b1d2f4c7"), "unsupported", map[string]any{"trafficEngineering": map[string]any{"policy": "rsvp-te"}})
	batch := []byte("[" + string(read(t, "supported_vpls.json")) + "," + string(te) + "]")
	causes = mustRefuse(t, batch, opt)
	if len(causes) == 0 {
		t.Fatal("no causes")
	}
	for _, c := range causes {
		if !strings.HasPrefix(c, "input[1].") {
			t.Errorf("cause %q does not name input[1]", c)
		}
	}
	if !hasCause(causes, "input[1].unsupported.trafficEngineering: ", "traffic-engineering") {
		t.Errorf("causes %q", causes)
	}
}

// FR-045, Rule 1: raw device CLI is never an accepted source format — not as the body, not as a
// value the request carries, not as a field.
func TestRawDeviceCLINeverAccepted(t *testing.T) {
	opt := labOptions(t)
	cli := "interface ethernet-1/1\n vlan-tagging true\n subinterface 132 {\n  vlan encap single-tagged vlan-id 132\n }\n"
	for name, body := range map[string]string{
		"CLI text":          cli,
		"set commands":      "set / network-instance bd-1 type mac-vrf\nset / network-instance bd-1 interface ethernet-1/1.132\n",
		"CLI as a JSON str": `"` + strings.ReplaceAll(cli, "\n", `\n`) + `"`,
	} {
		res, err := TranslateJSON([]byte(body), opt)
		var m *MalformedError
		if res != nil || !errors.As(err, &m) || ErrorKind(err) != "malformed" {
			t.Errorf("%s: result %v, error %v; want a malformed error and nothing emitted", name, res, err)
		}
	}
	// an array of CLI lines is not a batch of service intents
	if causes := mustRefuse(t, []byte(`["interface ethernet-1/1", "vlan-tagging true"]`), opt); !hasCause(causes, "input[0]: ", "expected a normalized service intent object") {
		t.Errorf("CLI lines in an array: causes %q", causes)
	}
	// CLI carried inside a request: refused by name, the whole request with it
	for _, key := range []string{"rawCli", "cli", "raw-device-cli"} {
		data := withField(t, read(t, "supported_vpls.json"), "unsupported", map[string]string{key: cli})
		if causes := mustRefuse(t, data, opt); len(causes) != 1 || !strings.HasPrefix(causes[0], "unsupported."+key+": unsupported feature: raw-device-cli;") {
			t.Errorf("unsupported.%s: causes %q", key, causes)
		}
	}
	for _, key := range []string{"cli", "config", "rawCli", "commands"} {
		data := withField(t, read(t, "supported_vpls.json"), key, cli)
		if causes := mustRefuse(t, data, opt); !hasCause(causes, key+": ", `unknown field "`+key+`"`) {
			t.Errorf("top-level %s: causes %q", key, causes)
		}
	}

	// through the built CLI: exit 1, the structured malformed error, nothing on stdout
	file := filepath.Join(t.TempDir(), "device.cli")
	if err := os.WriteFile(file, []byte(cli), 0o600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(buildCLI(t), "--file", file)
	var so, se bytes.Buffer
	cmd.Stdout, cmd.Stderr = &so, &se
	err := cmd.Run()
	if ee, ok := err.(*exec.ExitError); !ok || ee.ExitCode() != 1 || so.Len() != 0 || !bytes.HasPrefix(se.Bytes(), []byte(`{"error":"malformed","causes":[`)) {
		t.Errorf("CLI on raw device CLI: %v, stdout %q, stderr %s", err, so.String(), se.String())
	}
}

// quickstart.md §7: the built CLI translates each alias fixture, the service-type is the construct,
// the source-service-type the vocabulary, and the output ends with the golden spec block.
func TestAliasFixturesThroughTheCLI(t *testing.T) {
	for _, f := range aliasFixtures {
		r := runCLI(t, f.file+".json")
		if r.code != 0 || len(r.stderr) != 0 {
			t.Errorf("%s: exit %d, stderr %s", f.file, r.code, r.stderr)
			continue
		}
		golden := read(t, f.file+".spec.golden.yaml")
		if !bytes.HasSuffix(r.stdout, golden) {
			t.Errorf("%s: the CLI output does not end with the golden spec block:\n%s", f.file, r.stdout)
		}
		for _, line := range []string{"\n    agentic-netops.io/service-type: " + f.construct + "\n", "\n    agentic-netops.io/source-service-type: " + f.source + "\n"} {
			if !bytes.Contains(r.stdout, []byte(line)) {
				t.Errorf("%s: no %q", f.file, strings.TrimSpace(line))
			}
		}
	}
}
