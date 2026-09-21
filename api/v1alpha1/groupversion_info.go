// Package v1alpha1 is the optional first-party group agentic-netops.io/v1alpha1, which
// holds only the MigrationPlan (contracts/crd-api.md §"Optional `MigrationPlan` API",
// data-model.md §5). Its CRD is generated under config/crd/optional/, outside the default
// kustomization, and lab provisioning never applies it (AD-29).
//
// +kubebuilder:object:generate=true
// +groupName=agentic-netops.io
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	// GroupVersion is the group version used to register these objects.
	GroupVersion = schema.GroupVersion{Group: "agentic-netops.io", Version: "v1alpha1"}

	// SchemeBuilder is used to add go types to the GroupVersionKind scheme.
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	// AddToScheme adds the types in this group-version to the given scheme.
	AddToScheme = SchemeBuilder.AddToScheme
)
