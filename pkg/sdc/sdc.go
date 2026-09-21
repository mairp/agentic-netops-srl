// Package sdc is the provider's typed client over the device-configuration
// layer's APIs — `config.sdcio.dev` (Config, Target, Deviation) and
// `inv.sdcio.dev` (Schema) — consumed UNCHANGED from the upstream module
// github.com/sdcio/config-server at the version the lock file pins (v0.0.58).
//
// Nothing in this package re-declares an upstream Kind (FR-013, FR-098): every
// object read or written is the upstream Go type, registered into the scheme
// by the upstream package's own AddToScheme. The package only adds the
// platform's contract on top — deterministic names, target binding labels,
// ownership labels and annotations, the reserved priority band, an always
// stated `revertive`, `deletionPolicy: delete` and the render-hash short
// circuit (contracts/crd-api.md "Generated device configuration contract").
//
// Note on groups at the pinned version: at config-server v0.0.58 the `Target`
// kind is served in `config.sdcio.dev/v1alpha1` (apis/config/v1alpha1/
// target_types.go), not in `inv.sdcio.dev`; `Schema` is `inv.sdcio.dev/v1alpha1`.
// This package follows the upstream types, so the GVKs are whatever the pinned
// module registers.
package sdc

import (
	"fmt"

	sdcconfig "github.com/sdcio/config-server/apis/config"
	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	invv1alpha1 "github.com/sdcio/config-server/apis/inv/v1alpha1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// Platform constants of the generated device configuration contract.
const (
	// FieldManager is the dedicated field manager of every write.
	FieldManager = "agentic-netops-srl-provider"
	// SystemNamespace is where every generated Config lives, always (AD-69).
	SystemNamespace = "agentic-netops-system"

	// PriorityFabric and PriorityService are the reserved priority band.
	PriorityFabric  int32 = 10
	PriorityService int32 = 20

	// Labels.
	LabelNetworkNamespace = "agentic-netops.io/network-namespace"
	LabelNetworkName      = "agentic-netops.io/network-name"
	// LabelSourceKind distinguishes a Fabric Config from a Network Config.
	LabelSourceKind = "agentic-netops.io/source-kind"
	// LabelFabricName names the owning Fabric of a priority-10 Config.
	LabelFabricName = "agentic-netops.io/fabric-name"

	// Annotations the provider stamps on the Config (never on the source, FR-101).
	AnnotationSourceUID        = "agentic-netops.io/source-uid"
	AnnotationSourceGeneration = "agentic-netops.io/source-generation"
	AnnotationRenderHash       = "agentic-netops.io/render-hash"
	AnnotationMappingVersion   = "agentic-netops.io/mapping-version"
	AnnotationCompatibilitySet = "agentic-netops.io/compatibility-set"

	// MappingVersion is the provider's mapping version.
	MappingVersion = "srl-mapping v0.1.0"
)

// Upstream label keys for target binding, taken from the pinned module (the
// v1alpha1 helpers read exactly these keys).
const (
	LabelTargetName      = sdcconfig.TargetNameKey
	LabelTargetNamespace = sdcconfig.TargetNamespaceKey
)

// AddToScheme registers the upstream config.sdcio.dev and inv.sdcio.dev types.
func AddToScheme(s *runtime.Scheme) error {
	if err := configv1alpha1.AddToScheme(s); err != nil {
		return fmt.Errorf("register %s: %w", configv1alpha1.SchemeGroupVersion, err)
	}
	if err := invv1alpha1.AddToScheme(s); err != nil {
		return fmt.Errorf("register %s: %w", invv1alpha1.SchemeGroupVersion, err)
	}
	return nil
}

// Client is the typed device-configuration client. It wraps a
// controller-runtime client whose scheme carries AddToScheme.
type Client struct {
	c client.Client
}

// New returns a Client over c.
func New(c client.Client) *Client { return &Client{c: c} }
