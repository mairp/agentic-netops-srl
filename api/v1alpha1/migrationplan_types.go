package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// The MigrationPlan records source translation and cutover evidence for a migrated service
// (contracts/crd-api.md §"Optional `MigrationPlan` API", data-model.md §5). It never replaces
// the Network and never creates or modifies one: translation happens in exactly one place
// (FR-060).
//
// It has no route-target, VLAN or VNI policy field of its own — those are derived or allocated
// for a migrated service exactly as for any other (FR-012, AD-29); the field
// preserveRouteTargets does not exist. It references the Network's provenance annotations —
// the single provenance record (FR-046) — and never restates them (FR-048). It carries no raw
// CLI or configuration blob: every field is structured, every string bounded and single-line.

// SourcePlatform is the normalized legacy origin, with no vendor coupling.
// +kubebuilder:validation:Enum=legacy-router
type SourcePlatform string

// SourceServiceType is the migration alias the service arrived as.
// +kubebuilder:validation:Enum=VPLS;VPWS;L3VPN;L2L3-IRB
type SourceServiceType string

// Construct is one of the four constructs.
// +kubebuilder:validation:Enum=vlan;mac-vrf;ip-vrf;acl
type Construct string

// SingleLine is a bounded single-line string: no newline, carriage return or tab, so no raw
// CLI or configuration blob can be carried.
//
// +kubebuilder:validation:MaxLength=256
// +kubebuilder:validation:XValidation:rule="!self.matches('[\\n\\r\\t]')",message="must be a single line: raw CLI or configuration blobs are refused"
type SingleLine string

// MigrationEndpoint is a source attachment point in normalized form.
type MigrationEndpoint struct {
	// Node is the target leaf.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=63
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	Node string `json:"node"`
	// Attachment is the port in the device's own naming.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=32
	// +kubebuilder:validation:Pattern=`^[a-z][a-z0-9-]*[0-9](/[0-9]+){0,2}$`
	Attachment string `json:"attachment"`
}

// MigrationGateway is the source's gateway addresses, if any.
type MigrationGateway struct {
	// IPv4 gateway address with a prefix length.
	// +kubebuilder:validation:MaxLength=18
	// +kubebuilder:validation:XValidation:rule="isCIDR(self) && cidr(self).ip().family() == 4",message="must be an IPv4 address with a prefix length"
	// +optional
	IPv4 string `json:"ipv4,omitempty"`
	// IPv6 gateway address with a prefix length; not link-local.
	// +kubebuilder:validation:MaxLength=43
	// +kubebuilder:validation:XValidation:rule="isCIDR(self) && cidr(self).ip().family() == 6 && !cidr(self).ip().isLinkLocalUnicast()",message="must be a non-link-local IPv6 address with a prefix length"
	// +optional
	IPv6 string `json:"ipv6,omitempty"`
}

// NormalizedIntent carries only fields the translator understands. It has no free-form field.
type NormalizedIntent struct {
	// Tenant of the service.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=63
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	Tenant string `json:"tenant"`
	// Description of the source service.
	// +optional
	Description SingleLine `json:"description,omitempty"`
	// Endpoints of the source service.
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=64
	// +listType=atomic
	Endpoints []MigrationEndpoint `json:"endpoints"`
	// Prefixes the source service routes.
	// +kubebuilder:validation:MaxItems=32
	// +listType=set
	// +optional
	Prefixes []MigrationPrefix `json:"prefixes,omitempty"`
	// Gateway addresses of the source service.
	// +optional
	Gateway *MigrationGateway `json:"gateway,omitempty"`
}

// MigrationPrefix is a CIDR prefix.
//
// +kubebuilder:validation:MaxLength=43
// +kubebuilder:validation:XValidation:rule="isCIDR(self)",message="must be a CIDR prefix"
type MigrationPrefix string

// MigrationSource identifies the source service. Its identity is immutable after acceptance.
type MigrationSource struct {
	// Platform is the normalized legacy origin.
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="spec.source.platform is immutable once the MigrationPlan is accepted"
	Platform SourcePlatform `json:"platform"`
	// ServiceType is the migration alias; selects an explicit mapping onto a construct.
	ServiceType SourceServiceType `json:"serviceType"`
	// ServiceID is the stable external correlation key; immutable.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=128
	// +kubebuilder:validation:Pattern=`^[A-Za-z0-9][A-Za-z0-9._:/-]*$`
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="spec.source.serviceID is immutable once the MigrationPlan is accepted"
	ServiceID string `json:"serviceID"`
	// NormalizedIntent is the structured source intent; raw CLI is forbidden.
	NormalizedIntent NormalizedIntent `json:"normalizedIntent"`
}

// NetworkReference names the target Network.
type NetworkReference struct {
	// Name of the Network; a DNS-1123 label.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=63
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	Name string `json:"name"`
	// Namespace of the Network; empty for the plan's own namespace.
	// +kubebuilder:validation:MaxLength=63
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	// +optional
	Namespace string `json:"namespace,omitempty"`
}

// CutoverMode — no automatic live cutover exists.
// +kubebuilder:validation:Enum=manual;disabled
type CutoverMode string

// MappingPolicy holds the explicit opt-ins.
type MappingPolicy struct {
	// AllowLimitedEquivalence is the explicit opt-in for the point-to-point limited
	// equivalence.
	// +kubebuilder:default=false
	// +optional
	AllowLimitedEquivalence *bool `json:"allowLimitedEquivalence,omitempty"`
	// Cutover is manual or disabled; disabled by default.
	// +kubebuilder:default=disabled
	// +optional
	Cutover CutoverMode `json:"cutover,omitempty"`
}

// MigrationPlanSpec is the migration record's desired state.
type MigrationPlanSpec struct {
	// Source identifies and describes the source service.
	Source MigrationSource `json:"source"`
	// TargetNetworkRef is the stable generated Network.
	TargetNetworkRef NetworkReference `json:"targetNetworkRef"`
	// MappingPolicy holds the explicit opt-ins.
	// +optional
	MappingPolicy MappingPolicy `json:"mappingPolicy,omitempty"`
}

// UnsupportedFeature is one exact non-mappable semantic.
type UnsupportedFeature struct {
	// Code is a structured, stable code.
	// +kubebuilder:validation:MaxLength=64
	Code string `json:"code"`
	// FieldPath is the source field path.
	// +kubebuilder:validation:MaxLength=256
	FieldPath string `json:"fieldPath"`
	// Message is a concise human-readable message.
	// +kubebuilder:validation:MaxLength=1024
	// +optional
	Message string `json:"message,omitempty"`
}

// ProvenanceReference points at the Network's provenance annotations by key; the values live
// on the Network only (FR-046, FR-048).
type ProvenanceReference struct {
	// Network holding the annotations.
	Network NetworkReference `json:"network"`
	// AnnotationKeys are the provenance annotation keys referenced, e.g.
	// agentic-netops.io/service-type, agentic-netops.io/source-service-type,
	// agentic-netops.io/limited-equivalence. Keys only, never values.
	// +kubebuilder:validation:MaxItems=8
	// +listType=set
	// +optional
	AnnotationKeys []string `json:"annotationKeys,omitempty"`
}

// PerDeviceStatus is one target's rollout evidence.
type PerDeviceStatus struct {
	// Target (node) name.
	// +kubebuilder:validation:MaxLength=63
	Target string `json:"target"`
	// Phase of the target.
	// +kubebuilder:validation:MaxLength=32
	// +optional
	Phase string `json:"phase,omitempty"`
	// Reason code from the closed set.
	// +kubebuilder:validation:MaxLength=64
	// +optional
	Reason string `json:"reason,omitempty"`
	// ConfigRef is the Config name.
	// +kubebuilder:validation:MaxLength=253
	// +optional
	ConfigRef string `json:"configRef,omitempty"`
}

// MigrationPlanStatus is what the controller records.
type MigrationPlanStatus struct {
	// ObservedGeneration is the generation the status reflects.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
	// Construct is the construct the service became.
	// +optional
	Construct Construct `json:"construct,omitempty"`
	// SourceVocabulary is the alias it arrived as, recorded beside the construct.
	// +optional
	SourceVocabulary SourceServiceType `json:"sourceVocabulary,omitempty"`
	// UnsupportedFeatures enumerates exact non-mappable semantics.
	// +kubebuilder:validation:MaxItems=64
	// +listType=atomic
	// +optional
	UnsupportedFeatures []UnsupportedFeature `json:"unsupportedFeatures,omitempty"`
	// GeneratedNetworkRef is the Network the translator's output was applied as, recorded
	// once that object exists and validates; the controller never creates it.
	// +optional
	GeneratedNetworkRef *NetworkReference `json:"generatedNetworkRef,omitempty"`
	// ProvenanceRef references the Network's provenance annotations.
	// +optional
	ProvenanceRef *ProvenanceReference `json:"provenanceRef,omitempty"`
	// PerDevice is the aggregated rollout evidence.
	// +kubebuilder:validation:MaxItems=64
	// +listType=atomic
	// +optional
	PerDevice []PerDeviceStatus `json:"perDevice,omitempty"`
	// Conditions (Accepted, Translated, Ready, Degraded — data-model.md §18).
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// MigrationPlan is the optional migration record.
//
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,path=migrationplans,singular=migrationplan
// +kubebuilder:printcolumn:name="Construct",type=string,JSONPath=".status.construct"
// +kubebuilder:printcolumn:name="Network",type=string,JSONPath=".spec.targetNetworkRef.name"
// +kubebuilder:printcolumn:name="Ready",type=string,JSONPath=".status.conditions[?(@.type==\"Ready\")].status"
// +kubebuilder:printcolumn:name="Degraded",type=string,JSONPath=".status.conditions[?(@.type==\"Degraded\")].status"
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=".metadata.creationTimestamp"
type MigrationPlan struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	// +required
	Spec MigrationPlanSpec `json:"spec"`
	// +optional
	Status MigrationPlanStatus `json:"status,omitempty"`
}

// MigrationPlanList contains a list of MigrationPlan.
//
// +kubebuilder:object:root=true
type MigrationPlanList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []MigrationPlan `json:"items"`
}

func init() {
	SchemeBuilder.Register(&MigrationPlan{}, &MigrationPlanList{})
}
