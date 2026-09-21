package srl

import (
	"fmt"

	"github.com/mairp/agentic-netops-srl/pkg/sdc"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// FabricConfigRequest turns a fabric render into the request for its
// priority-10 generated Config. sdc.BuildConfig — the one constructor of a
// generated Config — stamps, on the Config and never on the Fabric (FR-101):
// the source identity (agentic-netops.io/source-uid, plus the source-kind and
// fabric-name labels), the source generation, the render hash, the
// compatibility set and the mapping version `srl-mapping v0.1.0`
// (sdc.MappingVersion). The Fabric is referenced by an owner reference only.
func FabricConfigRequest(r *Rendered, fabric sdc.Source, targetNamespace, compatibilitySet string, owner *metav1.OwnerReference) (sdc.ConfigRequest, error) {
	if r == nil {
		return sdc.ConfigRequest{}, fmt.Errorf("fabric config request: nil render")
	}
	if fabric.Kind != sdc.SourceFabric {
		return sdc.ConfigRequest{}, fmt.Errorf("fabric config request for %s: source kind %q is not %q", r.Node, fabric.Kind, sdc.SourceFabric)
	}
	return sdc.ConfigRequest{
		Source:           fabric,
		Node:             r.Node,
		TargetNamespace:  targetNamespace,
		Priority:         sdc.PriorityFabric,
		Revertive:        true,
		Value:            r.JSON,
		RenderHash:       r.Hash,
		CompatibilitySet: compatibilitySet,
		Owner:            owner,
	}, nil
}
