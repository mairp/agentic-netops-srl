package sdc

import (
	"context"

	condv1alpha1 "github.com/sdcio/config-server/apis/condition/v1alpha1"
	invv1alpha1 "github.com/sdcio/config-server/apis/inv/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// GetSchema reads one upstream inv.sdcio.dev Schema.
func (c *Client) GetSchema(ctx context.Context, namespace, name string) (*invv1alpha1.Schema, error) {
	s := &invv1alpha1.Schema{}
	if err := c.c.Get(ctx, client.ObjectKey{Namespace: namespace, Name: name}, s); err != nil {
		return nil, err
	}
	return s, nil
}

// ListSchemas lists the upstream Schemas of one namespace.
func (c *Client) ListSchemas(ctx context.Context, namespace string) ([]invv1alpha1.Schema, error) {
	l := &invv1alpha1.SchemaList{}
	if err := c.c.List(ctx, l, client.InNamespace(namespace)); err != nil {
		return nil, err
	}
	return l.Items, nil
}

// SchemaReady reports whether a Schema reports Ready.
func SchemaReady(s *invv1alpha1.Schema) bool {
	return s.GetCondition(condv1alpha1.ConditionTypeReady).Status == metav1.ConditionTrue
}

// FindSchema returns the Ready Schema of namespace for (provider, version), or
// nil when none is loaded and Ready — what the Fabric reconciler waits on.
func (c *Client) FindSchema(ctx context.Context, namespace, provider, version string) (*invv1alpha1.Schema, error) {
	items, err := c.ListSchemas(ctx, namespace)
	if err != nil {
		return nil, err
	}
	for i := range items {
		s := &items[i]
		if s.Spec.Provider == provider && s.Spec.Version == version && SchemaReady(s) {
			return s, nil
		}
	}
	return nil, nil
}
