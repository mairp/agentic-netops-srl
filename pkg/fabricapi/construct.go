package fabricapi

import (
	gostrings "strings"

	"github.com/mairp/agentic-netops-srl/pkg/migration"
)

// ConstructView is what a Network is reported as: its construct, derived when it is read
// (FR-026, FR-027; contracts/construct-vocabulary.md §2, network-spec.md §1).
//
// A service that converged before the vocabulary changed may carry a retired service type in its
// agentic-netops.io/service-type annotation (L2VNI, L3VNI, VPLS, VPWS, L3VPN, L2L3-IRB, …). That
// stored record is never rewritten for a naming change: the construct is derived from it here, at
// read time, and the stored vocabulary is carried as provenance — never as a type.
type ConstructView struct {
	// Construct is one of vlan, mac-vrf, ip-vrf, acl; "" when the stored type names none of them
	// (Unknown) or nothing in the object says what it is.
	Construct string
	// StoredType is the service-type annotation exactly as stored ("" when absent).
	StoredType string
	// SourceServiceType is the source-service-type annotation exactly as stored ("" when absent).
	SourceServiceType string
	// Provenance is the vocabulary the service was created in, when it is not the construct's own
	// name: the source-service-type annotation, else the migration alias the stored type is, else
	// the retired name stored as the type. "" when the service was created as its construct.
	Provenance string
	// LimitedEquivalence is the limited-equivalence marker as stored ("" when absent).
	LimitedEquivalence string
	// Retired is true when the stored service type is a spelling other than a construct's name —
	// a synonym or a migration alias the vocabulary no longer offers as a type.
	Retired bool
	// Derived is true when no service type is stored and the construct was read from the spec's
	// shape instead.
	Derived bool
	// Unknown is true when a service type is stored but names no construct: it is reported as
	// unknown, never guessed.
	Unknown bool
}

// Construct derives the construct of the Network from its stored annotations — or, when no
// service type is stored, from the shape of its spec. It is a pure read: n.Object is never
// modified, and nothing is written back.
func (n *Network) Construct() ConstructView {
	anns := n.annotations()
	v := ConstructView{
		StoredType:         anns[migration.AnnotationServiceType],
		SourceServiceType:  anns[migration.AnnotationSourceServiceType],
		LimitedEquivalence: anns[migration.AnnotationLimitedEquivalence],
	}
	v.Provenance = v.SourceServiceType
	if gostrings.TrimSpace(v.StoredType) == "" {
		v.Construct = n.shapeConstruct()
		v.Derived = v.Construct != ""
		return v
	}
	r, ok := migration.Canonicalize(v.StoredType)
	if !ok || !isConstruct(r.Construct) {
		v.Unknown = true
		return v
	}
	v.Construct = r.Construct
	v.Retired = nameKey(v.StoredType) != nameKey(r.Construct)
	if v.Provenance == "" {
		switch {
		case r.Source != "":
			v.Provenance = r.Source
		case v.Retired:
			v.Provenance = v.StoredType
		}
	}
	return v
}

// shapeConstruct reads the construct from which spec lists are populated: a local VLAN is vlan, a
// bridge domain (with or without a gateway router) is mac-vrf, a routed instance alone is ip-vrf,
// access lists alone are acl.
func (n *Network) shapeConstruct() string {
	switch {
	case len(n.list("vlans")) > 0:
		return migration.ConstructVLAN
	case len(n.list("bridgeDomains")) > 0:
		return migration.ConstructMACVRF
	case len(n.list("routers")) > 0:
		return migration.ConstructIPVRF
	case len(n.list("accessLists")) > 0:
		return migration.ConstructACL
	}
	return ""
}

// annotations returns metadata.annotations' string entries; nil when the shape is not a map.
// The returned map is a fresh copy, so no caller can reach the object through it.
func (n *Network) annotations() map[string]string {
	if n == nil || n.Object == nil {
		return nil
	}
	meta, ok := n.Object["metadata"].(map[string]any)
	if !ok {
		return nil
	}
	out := map[string]string{}
	switch raw := meta["annotations"].(type) {
	case map[string]any:
		for k, e := range raw {
			if s, ok := e.(string); ok {
				out[k] = s
			}
		}
	case map[string]string:
		for k, s := range raw {
			out[k] = s
		}
	}
	return out
}

func isConstruct(name string) bool {
	for _, c := range migration.Constructs() {
		if c == name {
			return true
		}
	}
	return false
}

// nameKey is the name-resolution key of construct-vocabulary.md §2: lower-cased, with every '-',
// '_', ' ', '.' and '+' deleted.
func nameKey(name string) string {
	var b gostrings.Builder
	for _, r := range gostrings.ToLower(gostrings.TrimSpace(name)) {
		switch r {
		case '-', '_', ' ', '.', '+':
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}
