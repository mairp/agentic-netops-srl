package sdc

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"

	condv1alpha1 "github.com/sdcio/config-server/apis/condition/v1alpha1"
	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// SourceKind is the kind of the first-party object a Config is generated from.
type SourceKind string

const (
	SourceFabric  SourceKind = "Fabric"
	SourceNetwork SourceKind = "Network"
)

// Source identifies the first-party object a Config is generated from.
type Source struct {
	Kind       SourceKind
	Namespace  string
	Name       string
	UID        types.UID
	Generation int64
}

// ConfigRequest is one per-(source, node) generated Config.
type ConfigRequest struct {
	Source Source
	// Node is the target (device) name; TargetNamespace the namespace of its Target.
	Node            string
	TargetNamespace string
	// Priority is PriorityFabric or PriorityService.
	Priority int32
	// Revertive is the value stated from DRIFT_POLICY; it is always stated, never absent.
	Revertive bool
	// Value is the native JSON_IETF document at path "/".
	Value []byte
	// RenderHash is the canonical render hash; an unchanged hash causes no update.
	RenderHash       string
	CompatibilitySet string
	// Owner is set for a Fabric Config only: a controller owner reference to the Fabric.
	// A Network Config carries none (AD-69).
	Owner *metav1.OwnerReference
}

// OwnershipConflictError reports a Config of the derived name held by another source.
type OwnershipConflictError struct {
	Name      string
	HolderUID string
}

func (e *OwnershipConflictError) Error() string {
	return fmt.Sprintf("config %s/%s is held by source uid %q", SystemNamespace, e.Name, e.HolderUID)
}

// IsOwnershipConflict reports whether err is an OwnershipConflictError.
func IsOwnershipConflict(err error) bool {
	var oc *OwnershipConflictError
	return errors.As(err, &oc)
}

// ConfigName is the deterministic `<source>.<node>`. The layer parses the node
// as the text after the last dot, so a source name with a dot is refused.
func ConfigName(source, node string) (string, error) {
	if source == "" || node == "" {
		return "", fmt.Errorf("config name needs a source and a node (got %q, %q)", source, node)
	}
	if strings.Contains(source, ".") {
		return "", fmt.Errorf("source name %q contains a dot: the layer would mis-target the configuration", source)
	}
	return source + "." + node, nil
}

// BuildConfig renders the upstream Config object for req. It is pure.
func BuildConfig(req ConfigRequest) (*configv1alpha1.Config, error) {
	name, err := ConfigName(req.Source.Name, req.Node)
	if err != nil {
		return nil, err
	}
	if req.TargetNamespace == "" {
		return nil, fmt.Errorf("config %s: target namespace is empty", name)
	}
	if req.Source.UID == "" {
		return nil, fmt.Errorf("config %s: source uid is empty", name)
	}
	if req.RenderHash == "" {
		return nil, fmt.Errorf("config %s: render hash is empty", name)
	}
	labels := map[string]string{
		LabelTargetName:      req.Node,
		LabelTargetNamespace: req.TargetNamespace,
		LabelSourceKind:      string(req.Source.Kind),
	}
	switch req.Source.Kind {
	case SourceFabric:
		if req.Priority != PriorityFabric {
			return nil, fmt.Errorf("config %s: a Fabric config is priority %d, got %d", name, PriorityFabric, req.Priority)
		}
		labels[LabelFabricName] = req.Source.Name
	case SourceNetwork:
		if req.Priority != PriorityService {
			return nil, fmt.Errorf("config %s: a Network config is priority %d, got %d", name, PriorityService, req.Priority)
		}
		if req.Owner != nil {
			return nil, fmt.Errorf("config %s: a Network config carries no owner reference (AD-69)", name)
		}
		labels[LabelNetworkNamespace] = req.Source.Namespace
		labels[LabelNetworkName] = req.Source.Name
	default:
		return nil, fmt.Errorf("config %s: unknown source kind %q", name, req.Source.Kind)
	}
	if !req.Revertive {
		// DRIFT_POLICY has a closed value set of one, `revertive` (FR-015, AD-34).
		return nil, fmt.Errorf("config %s: revertive must be stated true; DRIFT_POLICY admits only %q", name, "revertive")
	}
	revertive := req.Revertive
	cfg := &configv1alpha1.Config{
		TypeMeta: metav1.TypeMeta{
			APIVersion: configv1alpha1.SchemeGroupVersion.String(),
			Kind:       configv1alpha1.ConfigKind,
		},
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: SystemNamespace,
			Labels:    labels,
			Annotations: map[string]string{
				AnnotationSourceUID:        string(req.Source.UID),
				AnnotationSourceGeneration: strconv.FormatInt(req.Source.Generation, 10),
				AnnotationRenderHash:       req.RenderHash,
				AnnotationMappingVersion:   MappingVersion,
				AnnotationCompatibilitySet: req.CompatibilitySet,
			},
		},
		Spec: configv1alpha1.ConfigSpec{
			Lifecycle: &configv1alpha1.Lifecycle{DeletionPolicy: configv1alpha1.DeletionDelete},
			Priority:  req.Priority,
			Revertive: &revertive,
			Config: []configv1alpha1.ConfigBlob{{
				Path:  "/",
				Value: runtime.RawExtension{Raw: append([]byte(nil), req.Value...)},
			}},
		},
	}
	if req.Owner != nil {
		cfg.OwnerReferences = []metav1.OwnerReference{*req.Owner}
	}
	return cfg, nil
}

// ApplyResult says what ApplyConfig did.
type ApplyResult struct {
	Name    string
	Created bool
	Updated bool // false with Created false: the render hash was unchanged, nothing written
}

// ApplyConfig server-side-applies the Config of req under the provider's one
// dedicated field manager, FieldManager, forcing ownership of the fields it
// states (contracts/reconciliation.md Rule 4, contracts/crd-api.md "the
// dedicated server-side-apply field manager"). A Config of the derived name
// whose source-uid is another object's is never overwritten
// (OwnershipConflictError). An unchanged render hash writes nothing — no
// apply request is sent at all — so no spec write and no device transaction
// is caused (Rule 2).
func (c *Client) ApplyConfig(ctx context.Context, req ConfigRequest) (ApplyResult, error) {
	desired, err := BuildConfig(req)
	if err != nil {
		return ApplyResult{}, err
	}
	res := ApplyResult{Name: desired.Name}
	existing := &configv1alpha1.Config{}
	err = c.c.Get(ctx, client.ObjectKeyFromObject(desired), existing)
	switch {
	case apierrors.IsNotFound(err):
		if err := c.apply(ctx, desired); err != nil {
			return res, fmt.Errorf("apply (create) config %s: %w", desired.Name, err)
		}
		res.Created = true
		return res, nil
	case err != nil:
		return res, fmt.Errorf("get config %s: %w", desired.Name, err)
	}
	if holder := existing.Annotations[AnnotationSourceUID]; holder != string(req.Source.UID) {
		return res, &OwnershipConflictError{Name: existing.Name, HolderUID: holder}
	}
	if existing.Annotations[AnnotationRenderHash] == req.RenderHash {
		return res, nil
	}
	if err := c.apply(ctx, desired); err != nil {
		return res, fmt.Errorf("apply (update) config %s: %w", desired.Name, err)
	}
	res.Updated = true
	return res, nil
}

// apply sends one server-side apply of cfg as FieldManager with
// ForceOwnership. The apply configuration carries exactly what BuildConfig
// states: no status, no resourceVersion, no managedFields.
func (c *Client) apply(ctx context.Context, cfg *configv1alpha1.Config) error {
	u, err := runtime.DefaultUnstructuredConverter.ToUnstructured(cfg)
	if err != nil {
		return err
	}
	delete(u, "status")
	if md, ok := u["metadata"].(map[string]any); ok {
		delete(md, "creationTimestamp")
		delete(md, "resourceVersion")
		delete(md, "managedFields")
	}
	ac := client.ApplyConfigurationFromUnstructured(&unstructured.Unstructured{Object: u})
	return c.c.Apply(ctx, ac, client.FieldOwner(FieldManager), client.ForceOwnership)
}

// GetConfig reads one Config from the system namespace.
func (c *Client) GetConfig(ctx context.Context, name string) (*configv1alpha1.Config, error) {
	cfg := &configv1alpha1.Config{}
	if err := c.c.Get(ctx, client.ObjectKey{Namespace: SystemNamespace, Name: name}, cfg); err != nil {
		return nil, err
	}
	return cfg, nil
}

// ListConfigsForNetwork lists the Configs generated from one Network, by label.
func (c *Client) ListConfigsForNetwork(ctx context.Context, namespace, name string) ([]configv1alpha1.Config, error) {
	return c.listConfigs(ctx, client.MatchingLabels{LabelNetworkNamespace: namespace, LabelNetworkName: name})
}

// ListConfigsForFabric lists the Configs generated from one Fabric, by label.
func (c *Client) ListConfigsForFabric(ctx context.Context, name string) ([]configv1alpha1.Config, error) {
	return c.listConfigs(ctx, client.MatchingLabels{LabelFabricName: name})
}

// ListConfigsForTarget lists every Config bound to one target (all sources and
// priorities) — what the same-priority overlap check compares against.
func (c *Client) ListConfigsForTarget(ctx context.Context, targetNamespace, node string) ([]configv1alpha1.Config, error) {
	return c.listConfigs(ctx, client.MatchingLabels{LabelTargetNamespace: targetNamespace, LabelTargetName: node})
}

func (c *Client) listConfigs(ctx context.Context, sel client.MatchingLabels) ([]configv1alpha1.Config, error) {
	l := &configv1alpha1.ConfigList{}
	if err := c.c.List(ctx, l, client.InNamespace(SystemNamespace), sel); err != nil {
		return nil, err
	}
	return l.Items, nil
}

// DeleteConfig deletes one Config; a missing one is not an error. It refuses to
// delete a Config held by another source uid.
func (c *Client) DeleteConfig(ctx context.Context, name string, sourceUID types.UID) error {
	cfg, err := c.GetConfig(ctx, name)
	if apierrors.IsNotFound(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if holder := cfg.Annotations[AnnotationSourceUID]; holder != string(sourceUID) {
		return &OwnershipConflictError{Name: name, HolderUID: holder}
	}
	if err := c.c.Delete(ctx, cfg); err != nil && !apierrors.IsNotFound(err) {
		return err
	}
	return nil
}

// ConfigState is the layer's own report on one Config.
type ConfigState struct {
	Ready   bool
	Reason  string
	Message string
}

// ConfigStatus reads the layer's Ready condition of cfg.
func ConfigStatus(cfg *configv1alpha1.Config) ConfigState {
	cond := cfg.GetCondition(condv1alpha1.ConditionTypeReady)
	st := ConfigState{
		Ready:   cond.Status == metav1.ConditionTrue,
		Reason:  cond.Reason,
		Message: cond.Message,
	}
	return st
}
