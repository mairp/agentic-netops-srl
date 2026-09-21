package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// The conditional kinds of the recorded allocator substitution (FR-104, CD-03,
// data-model.md §23). They are defined now so that nothing above the allocation seam changes,
// and their CRDs are generated under config/crd/conditional/ — never into the default
// kustomization — to be installed only when versions.lock.yaml selects
// allocationAuthority.kind: first-party under a recorded decision. With kind: kuid, the default,
// neither CRD exists in the cluster. They are never served in, or shaped to imitate, an
// upstream API group (FR-098).

// IdentifierType is the kind of identifier a pool hands out.
// +kubebuilder:validation:Enum=ip;asn;vlan;vni;genid
type IdentifierType string

// Identifier types.
const (
	IdentifierTypeIP    IdentifierType = "ip"
	IdentifierTypeASN   IdentifierType = "asn"
	IdentifierTypeVLAN  IdentifierType = "vlan"
	IdentifierTypeVNI   IdentifierType = "vni"
	IdentifierTypeGENID IdentifierType = "genid"
)

// IdentifierRange is an inclusive numeric range.
//
// +kubebuilder:validation:XValidation:rule="self.start <= self.end",message="range.start must not exceed range.end"
type IdentifierRange struct {
	// Start of the range, inclusive.
	// +kubebuilder:validation:Minimum=0
	Start int64 `json:"start"`
	// End of the range, inclusive.
	// +kubebuilder:validation:Minimum=0
	End int64 `json:"end"`
}

// IdentifierPoolSpec is a pool of identifiers: a numeric range, or an address prefix for ip.
//
// +kubebuilder:validation:XValidation:rule="has(self.range) != has(self.prefix)",message="exactly one of range or prefix is set"
// +kubebuilder:validation:XValidation:rule="!has(self.prefix) || self.type == 'ip'",message="prefix is set only on a pool of type ip"
// +kubebuilder:validation:XValidation:rule="!has(self.range) || self.type != 'ip'",message="a pool of type ip carries a prefix, not a range"
type IdentifierPoolSpec struct {
	// Type of identifier the pool hands out.
	Type IdentifierType `json:"type"`
	// Range of a numeric pool (asn, vlan, vni, genid).
	// +optional
	Range *IdentifierRange `json:"range,omitempty"`
	// Prefix of an ip pool.
	// +kubebuilder:validation:MaxLength=43
	// +kubebuilder:validation:XValidation:rule="isCIDR(self)",message="prefix must be a CIDR prefix"
	// +optional
	Prefix string `json:"prefix,omitempty"`
}

// IdentifierPoolStatus is the observed state of an IdentifierPool.
type IdentifierPoolStatus struct {
	// ObservedGeneration is the generation the status reflects.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
	// Allocated is the number of identifiers currently claimed.
	// +optional
	Allocated int64 `json:"allocated,omitempty"`
	// Conditions of the pool.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// IdentifierPool is the substitute allocator's pool (conditional kind).
//
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,path=identifierpools,singular=identifierpool
// +kubebuilder:printcolumn:name="Type",type=string,JSONPath=".spec.type"
// +kubebuilder:printcolumn:name="Allocated",type=integer,JSONPath=".status.allocated"
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=".metadata.creationTimestamp"
type IdentifierPool struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	// +required
	Spec IdentifierPoolSpec `json:"spec"`
	// +optional
	Status IdentifierPoolStatus `json:"status,omitempty"`
}

// IdentifierPoolList contains a list of IdentifierPool.
//
// +kubebuilder:object:root=true
type IdentifierPoolList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []IdentifierPool `json:"items"`
}

// IdentifierPoolRef names the pool a claim draws from, in the claim's namespace.
type IdentifierPoolRef struct {
	// Name of the IdentifierPool.
	Name DNSLabel `json:"name"`
}

// IdentifierClaimSpec is immutable by CEL: a claim is created and deleted, never updated —
// an update would move the allocation and silently release the previous value.
//
// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="IdentifierClaim spec is immutable: delete the claim and create a new one"
type IdentifierClaimSpec struct {
	// PoolRef names the pool the claim draws from.
	PoolRef IdentifierPoolRef `json:"poolRef"`
	// Requested is the stated value to claim, as text (a number, or an address/prefix for
	// an ip pool); absent for a dynamic claim.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=64
	// +optional
	Requested string `json:"requested,omitempty"`
}

// IdentifierClaimStatus reports the allocation.
type IdentifierClaimStatus struct {
	// ObservedGeneration is the generation the status reflects.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
	// Value is the allocated identifier, as text; empty until allocated.
	// +kubebuilder:validation:MaxLength=64
	// +optional
	Value string `json:"value,omitempty"`
	// Conditions of the claim.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// IdentifierClaim is the substitute allocator's claim (conditional kind). It carries the
// tier's correlation label in metadata.labels.
//
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,path=identifierclaims,singular=identifierclaim
// +kubebuilder:printcolumn:name="Pool",type=string,JSONPath=".spec.poolRef.name"
// +kubebuilder:printcolumn:name="Value",type=string,JSONPath=".status.value"
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=".metadata.creationTimestamp"
type IdentifierClaim struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	// +required
	Spec IdentifierClaimSpec `json:"spec"`
	// +optional
	Status IdentifierClaimStatus `json:"status,omitempty"`
}

// IdentifierClaimList contains a list of IdentifierClaim.
//
// +kubebuilder:object:root=true
type IdentifierClaimList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []IdentifierClaim `json:"items"`
}

func init() {
	SchemeBuilder.Register(&IdentifierPool{}, &IdentifierPoolList{}, &IdentifierClaim{}, &IdentifierClaimList{})
}
