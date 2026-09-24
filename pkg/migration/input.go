// Package migration is the single translator (FR-060, D-30): it turns a normalized service intent —
// the allocator's output, contracts/normalized-service-intent.schema.json — into the fabric intent
// object `fabric.agentic-netops.io/v1alpha1` `Network` (contracts/network-spec.md).
//
// One path, called by both front ends: the CLI cmd/migration-translator and the pod-local sidecar
// cmd/intent-translator (contracts/translator-api.md). It is strict parse (unknown fields rejected)
// → canonicalization on entry (construct names and migration aliases folded, contracts/
// construct-vocabulary.md §2) → all-or-nothing validation over the whole batch, every cause
// collected and each naming its property path → deterministic emission (network-spec.md §3).
// Nothing here talks to a cluster: JSON in, YAML and JSON out.
package migration

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// Provenance the translator stamps on every object it emits (network-spec.md §1, §3). These are the
// translator's own annotation keys; the intent tier's keys are disjoint and stamped by the deployer.
const (
	TranslatorName    = "agentic-netops-migration-translator"
	TranslatorVersion = "v0.1.0"
	MappingVersion    = "v0.1.0"

	APIVersion = "fabric.agentic-netops.io/v1alpha1"
	Kind       = "Network"

	AnnotationTranslator         = "agentic-netops.io/translator"
	AnnotationTranslatorVersion  = "agentic-netops.io/translator-version"
	AnnotationMappingVersion     = "agentic-netops.io/mapping-version"
	AnnotationInputHash          = "agentic-netops.io/migration-input-hash"
	AnnotationTenant             = "agentic-netops.io/tenant"
	AnnotationServiceType        = "agentic-netops.io/service-type"
	AnnotationSourceServiceType  = "agentic-netops.io/source-service-type"
	AnnotationLimitedEquivalence = "agentic-netops.io/limited-equivalence"
)

// annotationOrder is the emission order of the translator's keys (network-spec.md §3). The intent
// tier's keys follow them, stamped later by the deployer.
var annotationOrder = []string{
	AnnotationTranslator, AnnotationTranslatorVersion, AnnotationMappingVersion, AnnotationInputHash,
	AnnotationTenant, AnnotationServiceType, AnnotationSourceServiceType, AnnotationLimitedEquivalence,
}

// ServiceInput is one normalized service intent. Every object rejects unknown fields (the parser
// decodes with DisallowUnknownFields); optional integers are pointers so an absent value is never
// confused with a zero one.
type ServiceInput struct {
	ServiceID string `json:"serviceId"`
	// Type is the construct. On entry it may be any spelling Canonicalize resolves; after parsing it
	// is canonical when it resolved and left as written when it did not (validation names it).
	Type   string `json:"type"`
	Tenant string `json:"tenant"`

	// SourceType is the arrival vocabulary of a request that came as a migration alias (VPLS, VPWS,
	// L3VPN, L2L3-IRB). Provenance only: never serialized, so it is excluded from the canonical
	// hash and the same service hashes identically in either vocabulary (D-19).
	SourceType string `json:"-"`

	RouteTargets    *InputRouteTargets `json:"routeTargets,omitempty"`
	L2VNI           *int64             `json:"l2vni,omitempty"`
	L3VNI           *int64             `json:"l3vni,omitempty"`
	AddressFamilies *AddressFamilies   `json:"addressFamilies,omitempty"`
	AnycastGateway  *AnycastGateway    `json:"anycastGateway,omitempty"`
	ACL             *ACL               `json:"acl,omitempty"`
	Endpoints       []Endpoint         `json:"endpoints"`
	Policies        *Policies          `json:"policies,omitempty"`
	// Unsupported: any key present is terminal and named (FR-045).
	Unsupported map[string]json.RawMessage `json:"unsupported,omitempty"`
}

// InputRouteTargets are the derived, read-only route targets the allocator shows the operator:
// each must be target:<fabricASN>:<vni> for this service's own VNI.
type InputRouteTargets struct {
	ImportRT []string `json:"importRT"`
	ExportRT []string `json:"exportRT"`
}

// AddressFamilies are an ip-vrf's prefixes.
type AddressFamilies struct {
	IPv4Prefixes []string `json:"ipv4Prefixes,omitempty"`
	IPv6Prefixes []string `json:"ipv6Prefixes,omitempty"`
}

// AnycastGateway makes a mac-vrf route: the bridge domain's irb carries the gateway into the
// service's own ip-vrf (FR-032).
type AnycastGateway struct {
	IPVRF       string `json:"ipVrf,omitempty"`
	GatewayIPv4 string `json:"gatewayIPv4,omitempty"`
	GatewayIPv6 string `json:"gatewayIPv6,omitempty"`
}

// ACL is parsed so that a schema-valid request is never mistaken for a malformed one; its
// translation arrives with the access-list story (T110) and until then it is refused by name.
type ACL struct {
	Name             string    `json:"name,omitempty"`
	Stage            string    `json:"stage"`
	Type             string    `json:"type"`
	DefaultAction    string    `json:"defaultAction,omitempty"`
	EvaluationOrder  string    `json:"evaluationOrder,omitempty"`
	UnmatchedTraffic string    `json:"unmatchedTraffic,omitempty"`
	Rules            []ACLRule `json:"rules"`
}

// ACLRule is one rule of an ACL.
type ACLRule struct {
	Name              string   `json:"name"`
	Priority          int64    `json:"priority"`
	Action            string   `json:"action"`
	Protocol          Protocol `json:"protocol,omitempty"`
	SourcePrefix      string   `json:"sourcePrefix,omitempty"`
	DestinationPrefix string   `json:"destinationPrefix,omitempty"`
	SourcePort        string   `json:"sourcePort,omitempty"`
	DestinationPort   string   `json:"destinationPort,omitempty"`
	Description       string   `json:"description,omitempty"`
}

// Protocol is a known protocol name or an IP protocol number; the wire admits either.
type Protocol string

// UnmarshalJSON accepts a JSON string or a JSON integer.
func (p *Protocol) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err == nil {
		*p = Protocol(s)
		return nil
	}
	var n int64
	if err := json.Unmarshal(b, &n); err != nil {
		return fmt.Errorf("protocol: a protocol name or an IP protocol number, got %s", string(b))
	}
	*p = Protocol(strconv.FormatInt(n, 10))
	return nil
}

// Endpoint is one attachment: a node, one of its access ports, and the VLAN / VRF context.
type Endpoint struct {
	Node       string `json:"node"`
	Attachment string `json:"attachment"`
	VLAN       *int64 `json:"vlan,omitempty"`
	VRF        string `json:"vrf,omitempty"`
}

// Policies are explicit opt-ins, meaningful only for a point-to-point migration alias (FR-047).
type Policies struct {
	VPWSLimitedEquivalence *bool `json:"vpwsLimitedEquivalence,omitempty"`
}

// CanonicalHash is the sha256 of the canonical input: the typed struct after canonicalization,
// marshalled in its fixed field order (map keys sorted by encoding/json). SourceType is excluded.
func (in *ServiceInput) CanonicalHash() string {
	b, err := json.Marshal(in)
	if err != nil { // a struct of strings, integers and raw JSON cannot fail to marshal
		panic(fmt.Sprintf("migration: marshalling a parsed input failed: %v", err))
	}
	sum := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(sum[:])
}

// ValidationError is a refusal: all-or-nothing, every cause naming its property path.
type ValidationError struct {
	Causes []string `json:"causes"`
}

func (e *ValidationError) Error() string {
	return "validation failed: " + strings.Join(e.Causes, "; ")
}

// MalformedError is input that is not a JSON object or array at all (the sidecar answers 400).
type MalformedError struct {
	Cause string
}

func (e *MalformedError) Error() string { return "malformed input: " + e.Cause }

// ErrorKind is the structured error's "error" value: "validation" or "malformed".
func ErrorKind(err error) string {
	var m *MalformedError
	if errors.As(err, &m) {
		return "malformed"
	}
	return "validation"
}

// ErrorCauses lists an error's causes.
func ErrorCauses(err error) []string {
	var v *ValidationError
	var m *MalformedError
	switch {
	case err == nil:
		return nil
	case errors.As(err, &v):
		return v.Causes
	case errors.As(err, &m):
		return []string{m.Cause}
	default:
		return []string{err.Error()}
	}
}

// StructuredError is the refusal object both front ends write: {"error": …, "causes": […]}.
type StructuredError struct {
	Error  string   `json:"error"`
	Causes []string `json:"causes"`
}

// MarshalError renders err as one line of JSON, HTML escaping off so causes read as written.
func MarshalError(err error) []byte {
	var b strings.Builder
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(StructuredError{Error: ErrorKind(err), Causes: ErrorCauses(err)})
	return []byte(b.String())
}
