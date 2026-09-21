// Package v1alpha1 is the first-party fabric API group fabric.agentic-netops.io/v1alpha1:
// the Fabric (the fabric design) and the Network (the service intent object), both with
// structural schemas and same-object CEL validation (contracts/crd-api.md §"Required
// `Fabric` and `Network` API", contracts/network-spec.md, data-model.md §3a, §12, §18),
// and the conditional allocation kinds IdentifierPool and IdentifierClaim, which are
// defined here and installed only under the recorded allocator substitution
// (data-model.md §23, FR-104).
//
// +kubebuilder:object:generate=true
// +groupName=fabric.agentic-netops.io
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	// GroupVersion is the group version used to register these objects.
	GroupVersion = schema.GroupVersion{Group: "fabric.agentic-netops.io", Version: "v1alpha1"}

	// SchemeBuilder is used to add go types to the GroupVersionKind scheme.
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	// AddToScheme adds the types in this group-version to the given scheme.
	AddToScheme = SchemeBuilder.AddToScheme
)
