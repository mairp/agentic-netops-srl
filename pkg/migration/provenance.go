package migration

// Provenance (contracts/network-spec.md §1, §3; FR-046, FR-048; D-19).
//
// The annotations on the emitted Network are the SINGLE provenance record — construct provenance
// (which construct the service is, from which canonical input, by which translator and mapping)
// and migration provenance (the vocabulary it arrived in, and whether it is a limited equivalence)
// alike. No second record of the same fact exists: a MigrationPlan, when used, references these
// annotations by key rather than restating them (FR-048).
//
// Each key has exactly one owner. The translator owns the keys below and stamps them here, once, at
// translation; the intent tier owns its audit keys (agentic-netops.io/intent-thread-id,
// intent-principal, intent-submitted-at, intent-submitted-spec-sha256) and the deployer stamps them
// after these. The two sets are disjoint (TranslatorAnnotationKeys; asserted by
// TestAliasProvenanceAnnotations), and no provider key ever appears on the object.

// The translator's identity, stamped as provenance on every object it emits.
const (
	TranslatorName    = "agentic-netops-migration-translator"
	TranslatorVersion = "v0.1.0"
	MappingVersion    = "v0.1.0"
)

// The translator's annotation keys.
const (
	AnnotationTranslator        = "agentic-netops.io/translator"
	AnnotationTranslatorVersion = "agentic-netops.io/translator-version"
	AnnotationMappingVersion    = "agentic-netops.io/mapping-version"
	AnnotationInputHash         = "agentic-netops.io/migration-input-hash"
	AnnotationTenant            = "agentic-netops.io/tenant"
	// AnnotationServiceType is the construct — never a migration alias (FR-044).
	AnnotationServiceType = "agentic-netops.io/service-type"
	// AnnotationSourceServiceType is the arrival vocabulary (aliases.go), only for a request that
	// arrived as a migration alias.
	AnnotationSourceServiceType = "agentic-netops.io/source-service-type"
	// AnnotationLimitedEquivalence carries LimitedEquivalenceVPWS, only for a point-to-point source.
	AnnotationLimitedEquivalence = "agentic-netops.io/limited-equivalence"
)

// LimitedEquivalenceVPWS is the limited-equivalence marker: a point-to-point L2 service (VPWS)
// represented by a dedicated L2VNI on a mac-vrf (reconciliation.md Rule 1; FR-045). The request
// opted into it explicitly (sourceScopedCauses); the annotation is the durable finding on the
// Network, which the MigrationPlan controller surfaces in its status.
const LimitedEquivalenceVPWS = "vpws-to-mac-vrf"

// annotationOrder is the emission order of the translator's keys (network-spec.md §3). The intent
// tier's keys follow them, stamped later by the deployer.
var annotationOrder = []string{
	AnnotationTranslator, AnnotationTranslatorVersion, AnnotationMappingVersion, AnnotationInputHash,
	AnnotationTenant, AnnotationServiceType, AnnotationSourceServiceType, AnnotationLimitedEquivalence,
}

// TranslatorAnnotationKeys lists the translator's annotation keys in emission order (a copy). They
// are the translator's alone; the intent tier's keys are disjoint from them.
func TranslatorAnnotationKeys() []string {
	return append([]string(nil), annotationOrder...)
}

// Provenance is the translator's provenance record of one service, as its annotations carry it.
type Provenance struct {
	Translator        string
	TranslatorVersion string
	MappingVersion    string
	// InputHash is the sha256 of the canonical input; the arrival vocabulary is excluded from it,
	// so a service hashes identically in either vocabulary (D-19).
	InputHash string
	Tenant    string
	// ServiceType is the construct.
	ServiceType string
	// SourceServiceType is the arrival vocabulary; empty for a request that named the construct.
	SourceServiceType string
	// LimitedEquivalence is LimitedEquivalenceVPWS for a point-to-point source; otherwise empty.
	LimitedEquivalence string
}

// provenanceOf is the provenance of a folded, validated input.
func provenanceOf(in *ServiceInput) Provenance {
	p := Provenance{
		Translator:        TranslatorName,
		TranslatorVersion: TranslatorVersion,
		MappingVersion:    MappingVersion,
		InputHash:         in.CanonicalHash(),
		Tenant:            in.Tenant,
		ServiceType:       in.Type,
		SourceServiceType: in.SourceType,
	}
	if in.SourceType == SourceVPWS {
		p.LimitedEquivalence = LimitedEquivalenceVPWS
	}
	return p
}

// Annotations stamps the record as the translator's annotations: the six keys every object carries,
// and the two migration keys only when set. The emitter writes them in annotationOrder.
func (p Provenance) Annotations() map[string]string {
	a := map[string]string{
		AnnotationTranslator:        p.Translator,
		AnnotationTranslatorVersion: p.TranslatorVersion,
		AnnotationMappingVersion:    p.MappingVersion,
		AnnotationInputHash:         p.InputHash,
		AnnotationTenant:            p.Tenant,
		AnnotationServiceType:       p.ServiceType,
	}
	if p.SourceServiceType != "" {
		a[AnnotationSourceServiceType] = p.SourceServiceType
	}
	if p.LimitedEquivalence != "" {
		a[AnnotationLimitedEquivalence] = p.LimitedEquivalence
	}
	return a
}

// ProvenanceFromAnnotations reads the translator's provenance back off an object's annotations —
// the one record there is. Keys it does not own (the intent tier's) are ignored.
func ProvenanceFromAnnotations(a map[string]string) Provenance {
	return Provenance{
		Translator:         a[AnnotationTranslator],
		TranslatorVersion:  a[AnnotationTranslatorVersion],
		MappingVersion:     a[AnnotationMappingVersion],
		InputHash:          a[AnnotationInputHash],
		Tenant:             a[AnnotationTenant],
		ServiceType:        a[AnnotationServiceType],
		SourceServiceType:  a[AnnotationSourceServiceType],
		LimitedEquivalence: a[AnnotationLimitedEquivalence],
	}
}

// Migrated reports whether the service arrived as a migration alias.
func (p Provenance) Migrated() bool { return p.SourceServiceType != "" }
