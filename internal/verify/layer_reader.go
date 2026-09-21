package verify

import (
	"context"
	"fmt"

	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// LayerReader is the StateReader over the device-configuration layer's own
// Kubernetes API (config-server v0.0.58), through the provider's ordinary API
// client — the data-server's session to the device is the only one used. See
// the package comment for what the pinned layer does and does not serve.
type LayerReader struct {
	// Client should be an uncached reader (the manager's APIReader): a
	// RunningConfig is computed by the aggregated API server on every GET and
	// is not watchable.
	Client client.Reader
}

var _ StateReader = (*LayerReader)(nil)

// Running reads config.sdcio.dev/v1alpha1 RunningConfig <target> in the
// target's namespace. The layer answers NotFound for a target that is not
// Ready, so NotFound is "unreachable", never "empty running configuration".
func (r *LayerReader) Running(ctx context.Context, t Target) ([]byte, error) {
	rc := &configv1alpha1.RunningConfig{}
	if err := r.Client.Get(ctx, client.ObjectKey{Namespace: t.Namespace, Name: t.Name}, rc); err != nil {
		if apierrors.IsNotFound(err) {
			return nil, fmt.Errorf("running configuration of %s/%s not served (target not Ready at the layer): %w", t.Namespace, t.Name, err)
		}
		return nil, fmt.Errorf("read running configuration of %s/%s: %w", t.Namespace, t.Name, err)
	}
	if len(rc.Status.Value.Raw) == 0 {
		return nil, fmt.Errorf("running configuration of %s/%s is empty: the layer has not synchronized it", t.Namespace, t.Name)
	}
	return rc.Status.Value.Raw, nil
}

// State always returns ErrStateNotServed: the pinned layer exposes no state
// read (package comment). It never falls back to the running datastore.
func (r *LayerReader) State(_ context.Context, t Target, _ []string) (map[string][]string, error) {
	return nil, fmt.Errorf("state of %s/%s: %w", t.Namespace, t.Name, ErrStateNotServed)
}
