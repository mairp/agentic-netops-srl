package main

import (
	"context"
	"fmt"

	corev1ac "k8s.io/client-go/applyconfigurations/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/mairp/agentic-netops-srl/controllers/fabric"
	"github.com/mairp/agentic-netops-srl/internal/compat"
	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/render/srl"
	"github.com/mairp/agentic-netops-srl/pkg/sdc"
)

// srlRenderer adapts internal/render/srl — the provider's only renderer of
// device paths — to the reconciler's Renderer input.
type srlRenderer struct{}

func (srlRenderer) RenderFabric(m *model.FabricModel) (map[string]fabric.Rendered, error) {
	docs, err := srl.RenderFabric(m)
	if err != nil {
		return nil, err
	}
	out := make(map[string]fabric.Rendered, len(docs))
	for node, d := range docs {
		out[node] = fabric.Rendered{Node: d.Node, JSON: d.JSON, Hash: d.Hash}
	}
	return out, nil
}

// CompatConfigMap is where the provider publishes the compatibility set it
// asserts, for make verify-compat (T050) to compare with versions.lock.yaml.
const CompatConfigMap = "srl-provider-compatibility-set"

// publishCompatibility server-side-applies the published compatibility set
// once, at start (it cannot change while the process runs: the lock is part of
// the image).
func publishCompatibility(ctx context.Context, c client.Client, set *compat.Set) error {
	doc, err := set.JSON()
	if err != nil {
		return err
	}
	cm := corev1ac.ConfigMap(CompatConfigMap, sdc.SystemNamespace).
		WithLabels(map[string]string{"app.kubernetes.io/name": "srl-provider", "app.kubernetes.io/component": "compatibility-set"}).
		WithData(map[string]string{"identifier": set.Identifier(), "compatibility-set.json": string(doc)})
	if err := c.Apply(ctx, cm, client.FieldOwner(sdc.FieldManager), client.ForceOwnership); err != nil {
		return fmt.Errorf("publish compatibility set: %w", err)
	}
	<-ctx.Done()
	return nil
}
