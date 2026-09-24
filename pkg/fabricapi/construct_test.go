package fabricapi_test

import (
	"reflect"
	"testing"

	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/yaml"

	"github.com/mairp/agentic-netops-srl/pkg/fabricapi"
	"github.com/mairp/agentic-netops-srl/pkg/migration"
)

// macvrfSpec is a mac-vrf body; the construct derivation must not read it when a type is stored.
const macvrfSpec = `
spec:
  bridgeDomains:
  - {name: bd-x, vlan: 120, l2vni: 10120, evpn: {routeTargets: {import: ["target:65000:10120"], export: ["target:65000:10120"]}}}
  attachments:
  - {node: leaf01, attachment: ethernet-1/1, vlan: 120}
`

func withAnnotations(t *testing.T, body string, anns map[string]any) *fabricapi.Network {
	t.Helper()
	obj := map[string]any{}
	if err := yaml.Unmarshal([]byte(body), &obj); err != nil {
		t.Fatal(err)
	}
	obj["apiVersion"] = "fabric.agentic-netops.io/v1alpha1"
	obj["kind"] = "Network"
	meta := map[string]any{"name": "migr-x", "namespace": "agentic-netops-intent"}
	if anns != nil {
		meta["annotations"] = anns
	}
	obj["metadata"] = meta
	return fabricapi.New(obj)
}

// FR-027 / quickstart.md §14: a service stored under a retired type is reported by its construct,
// the stored vocabulary as provenance; a construct is reported as itself; an unknown stored type is
// reported unknown, never guessed; no stored type is derived from the spec's shape.
func TestConstructIsDerivedAtReadTimeFromTheStoredRecord(t *testing.T) {
	type want struct {
		construct, provenance     string
		retired, derived, unknown bool
	}
	cases := []struct {
		name   string
		stored string // "" = annotation absent
		source string
		body   string
		want   want
	}{
		// every retired value the predecessor could have stored, and the synonyms
		{"L2VNI", "L2VNI", "", macvrfSpec, want{"mac-vrf", "L2VNI", true, false, false}},
		{"l2vni", "l2vni", "", macvrfSpec, want{"mac-vrf", "l2vni", true, false, false}},
		{"L3VNI", "L3VNI", "", macvrfSpec, want{"ip-vrf", "L3VNI", true, false, false}},
		{"access-list", "access-list", "", macvrfSpec, want{"acl", "access-list", true, false, false}},
		{"VPLS", "VPLS", "", macvrfSpec, want{"mac-vrf", "VPLS", true, false, false}},
		{"VPWS", "VPWS", "", macvrfSpec, want{"mac-vrf", "VPWS", true, false, false}},
		{"E-LINE", "E-LINE", "", macvrfSpec, want{"mac-vrf", "VPWS", true, false, false}},
		{"L3VPN", "L3VPN", "", macvrfSpec, want{"ip-vrf", "L3VPN", true, false, false}},
		{"L2L3-IRB", "L2L3-IRB", "", macvrfSpec, want{"mac-vrf", "L2L3-IRB", true, false, false}},
		{"IRB", "IRB", "", macvrfSpec, want{"mac-vrf", "L2L3-IRB", true, false, false}},
		// a construct, as written and in another spelling: no provenance
		{"construct", "mac-vrf", "", macvrfSpec, want{"mac-vrf", "", false, false, false}},
		{"construct spelling", "MAC_VRF", "", macvrfSpec, want{"mac-vrf", "", false, false, false}},
		// the translator's current record: the construct plus the alias it arrived as
		{"alias with source", "mac-vrf", "VPLS", macvrfSpec, want{"mac-vrf", "VPLS", false, false, false}},
		// no stored type: the spec's shape
		{"absent: bridge domain", "", "", macvrfSpec, want{"mac-vrf", "", false, true, false}},
		{"absent: vlan", "", "", "spec: {vlans: [{name: v, vlan: 130}]}", want{"vlan", "", false, true, false}},
		{"absent: router", "", "", "spec: {routers: [{name: r, l3vni: 10200}]}", want{"ip-vrf", "", false, true, false}},
		{"absent: access list", "", "", "spec: {accessLists: [{name: a, stage: ingress}]}", want{"acl", "", false, true, false}},
		{"absent: nothing", "", "", "spec: {}", want{"", "", false, false, false}},
		// an unknown stored type is reported unknown, not guessed from the spec
		{"unknown", "EVPN-VPWS-FXC", "", macvrfSpec, want{"", "", false, false, true}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var anns map[string]any
			if tc.stored != "" || tc.source != "" {
				anns = map[string]any{"agentic-netops.io/tenant": "blue"}
				if tc.stored != "" {
					anns[migration.AnnotationServiceType] = tc.stored
				}
				if tc.source != "" {
					anns[migration.AnnotationSourceServiceType] = tc.source
				}
			}
			n := withAnnotations(t, tc.body, anns)
			before := runtime.DeepCopyJSON(n.Object)
			got := n.Construct()
			if !reflect.DeepEqual(n.Object, before) {
				t.Fatalf("Construct() modified the object:\nbefore %v\nafter  %v", before, n.Object)
			}
			if got.Construct != tc.want.construct || got.Provenance != tc.want.provenance ||
				got.Retired != tc.want.retired || got.Derived != tc.want.derived || got.Unknown != tc.want.unknown {
				t.Fatalf("Construct() = %+v, want %+v", got, tc.want)
			}
			if got.StoredType != tc.stored || got.SourceServiceType != tc.source {
				t.Fatalf("stored vocabulary not carried verbatim: %+v", got)
			}
		})
	}
}

func TestConstructCarriesTheLimitedEquivalenceMarker(t *testing.T) {
	n := withAnnotations(t, macvrfSpec, map[string]any{
		migration.AnnotationServiceType:        "mac-vrf",
		migration.AnnotationSourceServiceType:  "VPWS",
		migration.AnnotationLimitedEquivalence: "point-to-point",
	})
	got := n.Construct()
	if got.Construct != "mac-vrf" || got.Provenance != "VPWS" || got.LimitedEquivalence != "point-to-point" {
		t.Fatalf("Construct() = %+v", got)
	}
}

// The tolerance discipline: a missing or mistyped metadata/annotations shape is not a failure.
func TestConstructToleratesUnexpectedShapes(t *testing.T) {
	for name, n := range map[string]*fabricapi.Network{
		"nil network":         nil,
		"nil object":          fabricapi.New(nil),
		"metadata not a map":  fabricapi.New(map[string]any{"metadata": "x"}),
		"annotations not map": fabricapi.New(map[string]any{"metadata": map[string]any{"annotations": []any{"x"}}}),
		"mistyped type":       fabricapi.New(map[string]any{"metadata": map[string]any{"annotations": map[string]any{migration.AnnotationServiceType: 7}}}),
	} {
		if got := n.Construct(); got.Construct != "" || got.Unknown || got.Provenance != "" {
			t.Errorf("%s: Construct() = %+v, want the zero view", name, got)
		}
	}
	typed := fabricapi.New(map[string]any{"metadata": map[string]any{
		"annotations": map[string]string{migration.AnnotationServiceType: "L3VNI"}}})
	if got := typed.Construct(); got.Construct != "ip-vrf" || got.Provenance != "L3VNI" {
		t.Errorf("map[string]string annotations: Construct() = %+v", got)
	}
}
