package migration

import "fmt"

// The migration alias catalogue (contracts/construct-vocabulary.md §2, last six rows; FR-044).
//
// A migration alias is a name from the retired service-provider vocabulary the migration path
// exists to read. It is accepted on INPUT ONLY: foldOnEntry (input.go) replaces it with the
// construct it becomes before any validator or translator sees the request, and records the
// vocabulary it arrived in as provenance (provenance.go) — never as a type. No output anywhere
// emits an alias as a type (FR-026, FR-044, FR-085).
//
// Two aliases may share an arrival vocabulary (`vpws` and `eline` are both the point-to-point L2
// vocabulary VPWS); the vocabulary, not the spelling, is what is recorded and what the
// source-scoped constraints key on.

// The arrival vocabularies, as recorded in agentic-netops.io/source-service-type.
const (
	SourceVPLS    = "VPLS"
	SourceVPWS    = "VPWS"
	SourceL3VPN   = "L3VPN"
	SourceL2L3IRB = "L2L3-IRB"
)

// Alias is one row of the catalogue: the resolution key an alias spelling folds to (Key), the
// construct it becomes, and the arrival vocabulary recorded for it.
type Alias struct {
	Key       string
	Construct string
	Source    string
}

// aliases is the catalogue in the contract's table order.
var aliases = []Alias{
	{Key: "vpls", Construct: ConstructMACVRF, Source: SourceVPLS},
	{Key: "vpws", Construct: ConstructMACVRF, Source: SourceVPWS},
	{Key: "eline", Construct: ConstructMACVRF, Source: SourceVPWS},
	{Key: "l3vpn", Construct: ConstructIPVRF, Source: SourceL3VPN},
	{Key: "l2l3irb", Construct: ConstructMACVRF, Source: SourceL2L3IRB},
	{Key: "irb", Construct: ConstructMACVRF, Source: SourceL2L3IRB},
}

// Aliases lists the migration alias catalogue in the contract's table order (a copy).
func Aliases() []Alias {
	return append([]Alias(nil), aliases...)
}

// FoldAlias resolves any spelling of a migration alias (`VPLS`, `E-Line`, `l2l3_irb`, …, by Key)
// to the construct it becomes and the arrival vocabulary to record. ok is false for a name that is
// not an alias — a construct, a synonym and an unknown name alike.
func FoldAlias(name string) (construct, source string, ok bool) {
	k := Key(name)
	for _, a := range aliases {
		if a.Key == k {
			return a.Construct, a.Source, true
		}
	}
	return "", "", false
}

// sourceScopedCauses are the constraints that belong to a source vocabulary rather than to the
// construct (construct-vocabulary.md §6; FR-047). They apply when and only when the recorded
// arrival vocabulary says the request came that way: a request naming `mac-vrf` directly is subject
// to none of them. validateService calls this only for an input whose SourceType is set.
//
// The point-to-point L2 vocabulary (VPWS) maps onto a mac-vrf only as a limited equivalence —
// a pseudowire becomes a dedicated L2VNI between exactly two attachments (reconciliation.md Rule 1).
// So it carries exactly 2 endpoints, and the request must opt into the equivalence explicitly;
// the opted-in result carries the limited-equivalence annotation (provenance.go), the durable
// finding the MigrationPlan controller surfaces.
func sourceScopedCauses(in *ServiceInput, p string) []string {
	var causes []string
	add := func(format string, a ...any) { causes = append(causes, p+fmt.Sprintf(format, a...)) }
	switch in.SourceType {
	case SourceVPWS:
		if len(in.Endpoints) != 2 {
			add("endpoints: the point-to-point migration alias (VPWS) requires exactly 2 endpoints, got %d", len(in.Endpoints))
		}
		if in.Policies == nil || in.Policies.VPWSLimitedEquivalence == nil || !*in.Policies.VPWSLimitedEquivalence {
			add("policies.vpwsLimitedEquivalence: must be true — a point-to-point source maps onto a mac-vrf only as a limited equivalence the request opts into")
		}
	}
	return causes
}
