package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// DNSLabel is a DNS-1123 label of at most 63 characters: lower-case alphanumerics and '-',
// starting and ending with an alphanumeric, no dot. Entry names of vlans[], bridgeDomains[]
// and routers[] are DNSLabels so that every claim name <namespace>.<name>.<role> is at most
// 63+1+63+1+6+63 = 197 of the 253 characters an object name allows (AD-56).
//
// +kubebuilder:validation:MinLength=1
// +kubebuilder:validation:MaxLength=63
// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
type DNSLabel string

// PortName is a port in the device's own naming, e.g. ethernet-1/1.
//
// +kubebuilder:validation:MinLength=1
// +kubebuilder:validation:MaxLength=32
// +kubebuilder:validation:Pattern=`^[a-z][a-z0-9-]*[0-9](/[0-9]+){0,2}$`
type PortName string

// ObjectRef names an object by namespace and name.
type ObjectRef struct {
	// Name of the object.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	Name string `json:"name"`
	// Namespace of the object; empty for the referring object's own namespace.
	// +kubebuilder:validation:MaxLength=63
	// +optional
	Namespace string `json:"namespace,omitempty"`
}

// TargetPhase is the phase of one required target (device) of a Fabric or a Network.
type TargetPhase string

// Per-target phases reported in status.renderedConfigs[].phase.
const (
	TargetPhasePending     TargetPhase = "Pending"
	TargetPhaseRendered    TargetPhase = "Rendered"
	TargetPhaseValidated   TargetPhase = "Validated"
	TargetPhaseApplied     TargetPhase = "Applied"
	TargetPhaseReady       TargetPhase = "Ready"
	TargetPhaseFailed      TargetPhase = "Failed"
	TargetPhaseRemoving    TargetPhase = "Removing"
	TargetPhaseUnreachable TargetPhase = "Unreachable"
)

// RenderedConfig is the reference to one generated device-configuration resource (the
// device-configuration layer's own Config, named <source>.<node>) with its render hash and the
// target's current phase and reason (contracts/crd-api.md §Status contract).
type RenderedConfig struct {
	// Node is the target the Config binds to.
	// +kubebuilder:validation:MaxLength=63
	Node string `json:"node"`
	// Name of the Config — <source>.<node>.
	// +kubebuilder:validation:MaxLength=253
	Name string `json:"name"`
	// Namespace of the Config — agentic-netops-system, always.
	// +kubebuilder:validation:MaxLength=63
	Namespace string `json:"namespace"`
	// Priority of the Config: 10 for the Fabric-derived per-node Config, 20 per service.
	// +optional
	Priority int32 `json:"priority,omitempty"`
	// RenderHash is the canonical render hash the Config carries, sha256:<hex>.
	// +kubebuilder:validation:MaxLength=80
	// +optional
	RenderHash string `json:"renderHash,omitempty"`
	// ObservedGeneration is the source generation this entry was rendered from.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
	// Phase is the target's current phase.
	// +kubebuilder:validation:MaxLength=32
	// +optional
	Phase TargetPhase `json:"phase,omitempty"`
	// Reason is a stable reason code from the closed set of data-model.md §18.
	// +kubebuilder:validation:MaxLength=64
	// +optional
	Reason string `json:"reason,omitempty"`
	// Message is a concise human-readable message; automation keys on Reason.
	// +kubebuilder:validation:MaxLength=2048
	// +optional
	Message string `json:"message,omitempty"`
	// TransactionRef is the last device transaction reference, when available.
	// +kubebuilder:validation:MaxLength=253
	// +optional
	TransactionRef string `json:"transactionRef,omitempty"`
	// LastTransitionTime is when Phase last changed.
	// +optional
	LastTransitionTime *metav1.Time `json:"lastTransitionTime,omitempty"`
}
