package sdc

import (
	"context"

	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// TargetReadiness is the readiness of one device target as the layer reports it.
type TargetReadiness struct {
	Namespace string
	Name      string
	// Ready is the upstream Target.IsReady(): Ready, discovery, datastore and
	// connection conditions all True.
	Ready bool
	// DatastoreReady is the upstream Target.IsDatastoreReady().
	DatastoreReady bool
	// Reason is the upstream NotReadyReason() when not Ready.
	Reason string
	// Provider and Version are the discovered schema selection, when discovered.
	Provider string
	Version  string
}

// GetTarget reads one upstream Target.
func (c *Client) GetTarget(ctx context.Context, namespace, name string) (*configv1alpha1.Target, error) {
	t := &configv1alpha1.Target{}
	if err := c.c.Get(ctx, client.ObjectKey{Namespace: namespace, Name: name}, t); err != nil {
		return nil, err
	}
	return t, nil
}

// ListTargets lists the upstream Targets of one namespace.
func (c *Client) ListTargets(ctx context.Context, namespace string) ([]configv1alpha1.Target, error) {
	l := &configv1alpha1.TargetList{}
	if err := c.c.List(ctx, l, client.InNamespace(namespace)); err != nil {
		return nil, err
	}
	return l.Items, nil
}

// TargetReady reads a Target and reports its readiness. An error reading it is
// returned as an error — never as "not Ready" — so a caller can tell an
// unreadable layer from a reported state.
func (c *Client) TargetReady(ctx context.Context, namespace, name string) (TargetReadiness, error) {
	t, err := c.GetTarget(ctx, namespace, name)
	if err != nil {
		return TargetReadiness{Namespace: namespace, Name: name}, err
	}
	return Readiness(t), nil
}

// Readiness derives TargetReadiness from an upstream Target using the upstream helpers.
func Readiness(t *configv1alpha1.Target) TargetReadiness {
	r := TargetReadiness{
		Namespace:      t.Namespace,
		Name:           t.Name,
		Ready:          t.IsReady(),
		DatastoreReady: t.IsDatastoreReady(),
	}
	if !r.Ready {
		r.Reason = t.NotReadyReason()
	}
	if di := t.Status.DiscoveryInfo; di != nil {
		r.Provider = di.Provider
		r.Version = di.Version
	}
	return r
}
