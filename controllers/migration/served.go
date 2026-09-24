package migration

import (
	"fmt"
	"slices"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/discovery"

	migrationv1 "github.com/mairp/agentic-netops-srl/api/v1alpha1"
)

// Resource is the plural the optional MigrationPlan CRD serves.
const Resource = "migrationplans"

// Served reports whether the API server serves the MigrationPlan resource of
// agentic-netops.io/v1alpha1 — the condition under which cmd/srl-provider registers this
// controller (AD-29). A group-version the server does not know is "not served", never an
// error; any other discovery failure is returned.
func Served(d discovery.ServerResourcesInterface) (bool, error) {
	list, err := d.ServerResourcesForGroupVersion(migrationv1.GroupVersion.String())
	if apierrors.IsNotFound(err) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("discovering %s: %w", migrationv1.GroupVersion, err)
	}
	return list != nil && slices.ContainsFunc(list.APIResources, func(r metav1.APIResource) bool { return r.Name == Resource }), nil
}
