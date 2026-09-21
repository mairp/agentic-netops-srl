package sdc

import (
	"context"
	"sort"

	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// Deviation reasons the layer reports (data-model.md "Device-configuration layer").
const (
	DeviationUnhandled  = "UNHANDLED"
	DeviationNotApplied = "NOT_APPLIED"
	DeviationOverruled  = "OVERRULED"
)

// GetConfigDeviation reads the config-typed Deviation of one Config, named by
// the upstream convention (configv1alpha1.DeviationName). A missing Deviation
// is (nil, nil): no deviation reported.
func (c *Client) GetConfigDeviation(ctx context.Context, configName string) (*configv1alpha1.Deviation, error) {
	d := &configv1alpha1.Deviation{}
	key := client.ObjectKey{
		Namespace: SystemNamespace,
		Name:      configv1alpha1.DeviationName(configv1alpha1.DeviationType_CONFIG, configName),
	}
	if err := c.c.Get(ctx, key, d); err != nil {
		if apierrors.IsNotFound(err) {
			return nil, nil
		}
		return nil, err
	}
	return d, nil
}

// ListDeviationsForTarget lists the Deviations bound to one target, by the
// upstream target labels.
func (c *Client) ListDeviationsForTarget(ctx context.Context, namespace, targetNamespace, node string) ([]configv1alpha1.Deviation, error) {
	l := &configv1alpha1.DeviationList{}
	if err := c.c.List(ctx, l, client.InNamespace(namespace),
		client.MatchingLabels{LabelTargetNamespace: targetNamespace, LabelTargetName: node}); err != nil {
		return nil, err
	}
	return l.Items, nil
}

// PathsWithReason returns the sorted paths of d carrying reason (e.g.
// DeviationOverruled for the overruled-path terminal error, AD-66).
func PathsWithReason(d *configv1alpha1.Deviation, reason string) []string {
	if d == nil {
		return nil
	}
	var out []string
	for _, dev := range d.Spec.Deviations {
		if dev.Reason == reason {
			out = append(out, dev.Path)
		}
	}
	sort.Strings(out)
	return out
}
