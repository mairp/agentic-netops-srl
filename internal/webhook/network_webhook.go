// Package webhook is the provider's validating admission webhook for Network (T061;
// contracts/crd-api.md §"Required Fabric and Network API"; FR-034, FR-097, FR-103, CR-003,
// R-40). It holds the cross-object rows of the rule table — attachment resolvability in the
// port's declared tagging mode (AD-68), one owner per (node, port, vlan), one tagging mode per
// port across objects (AD-20), access-list binding exclusivity, a standalone list's
// subinterface (it must exist at the list's admission, and an owner's UPDATE may not remove it
// while the list is bound), qualification — and nothing same-object, which is CEL in the CRD. There is no
// mutating webhook, and no rule arbitrates a VNI or VLAN value: that is the allocation
// authority's.
//
// The handler's first step decides whether anything is evaluated at all (AD-61): the rules run
// on a CREATE and on an UPDATE whose object.spec differs semantically from oldObject.spec on
// an object with no deletion timestamp. An UPDATE that leaves spec unchanged — a finalizer, a
// label, an annotation, the force-release annotation included — and any UPDATE of an object
// carrying a deletion timestamp are admitted with no rule evaluated. The exemption is this
// code, never a narrower rules entry or a matchConditions expression: the
// ValidatingWebhookConfiguration (deploy/agentic-netops/webhook.yaml) still sends every CREATE
// and UPDATE of networks here with failurePolicy Fail (AD-52), so while the webhook cannot be
// reached every one of them is refused by the API server. A deleting object still holds its
// subinterfaces, its mode and its bindings against every other object's admission.
//
// Every read is live through an uncached reader, so two admissions in quick succession see
// each other's stored object; a read that fails refuses the request (fail closed).
package webhook

import (
	"context"
	"fmt"
	"net/http"
	"strings"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrlwebhook "sigs.k8s.io/controller-runtime/pkg/webhook"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
)

// Path is where the handler is served; the shipped ValidatingWebhookConfiguration's
// clientConfig.service.path names it.
const Path = "/validate-fabric-agentic-netops-io-v1alpha1-network"

// DefaultFabricNamespace is where the Fabric lives (agentic-netops-system).
const DefaultFabricNamespace = "agentic-netops-system"

// NetworkValidator is the admission.Handler.
type NetworkValidator struct {
	// Reader reads Networks cluster-wide, Fabrics in FabricNamespace and the qualification
	// ConfigMap — uncached (the manager's API reader).
	Reader client.Reader
	// Decoder decodes the request's objects.
	Decoder admission.Decoder
	// FabricNamespace is where the Fabric is read; DefaultFabricNamespace when empty.
	FabricNamespace string
}

var _ admission.Handler = &NetworkValidator{}

// Register serves a NetworkValidator at Path on srv.
func Register(srv ctrlwebhook.Server, reader client.Reader, scheme *runtime.Scheme) {
	srv.Register(Path, &ctrlwebhook.Admission{Handler: &NetworkValidator{
		Reader:  reader,
		Decoder: admission.NewDecoder(scheme),
	}})
}

// Evaluates is the handler's first step (AD-61): whether the rules run on this request at all,
// and, when they do not, why. old is nil on a CREATE.
func Evaluates(op admissionv1.Operation, obj, old *fabricv1.Network) (bool, string) {
	switch op {
	case admissionv1.Create:
		return true, ""
	case admissionv1.Update:
		if obj.DeletionTimestamp != nil || old.DeletionTimestamp != nil {
			return false, "an UPDATE of a Network carrying a deletion timestamp is admitted with no rule evaluated (AD-61)"
		}
		if equality.Semantic.DeepEqual(obj.Spec, old.Spec) {
			return false, "an UPDATE that leaves spec unchanged is admitted with no rule evaluated (AD-61)"
		}
		return true, ""
	}
	return false, fmt.Sprintf("operation %s is not evaluated", op)
}

// Handle implements admission.Handler.
func (v *NetworkValidator) Handle(ctx context.Context, req admission.Request) admission.Response {
	obj := &fabricv1.Network{}
	if err := v.Decoder.DecodeRaw(req.Object, obj); err != nil {
		return admission.Errored(http.StatusBadRequest, fmt.Errorf("decoding the Network: %w", err))
	}
	var old *fabricv1.Network
	if req.Operation == admissionv1.Update {
		old = &fabricv1.Network{}
		if err := v.Decoder.DecodeRaw(req.OldObject, old); err != nil {
			return admission.Errored(http.StatusBadRequest, fmt.Errorf("decoding the stored Network: %w", err))
		}
	}
	if eval, why := Evaluates(req.Operation, obj, old); !eval {
		return admission.Allowed(why)
	}
	if obj.Namespace == "" {
		obj.Namespace = req.Namespace
	}
	if obj.Name == "" {
		obj.Name = req.Name
	}

	others, inv, q, err := v.read(ctx, obj)
	if err != nil {
		// Fail closed: a rule that cannot be evaluated admits nothing.
		return admission.Errored(http.StatusInternalServerError, err)
	}
	violations := Evaluate(obj, old, others, inv, v.fabricNamespace(), q)
	if len(violations) == 0 {
		return admission.Allowed("")
	}
	msgs := make([]string, len(violations))
	for i, vi := range violations {
		msgs[i] = vi.String()
	}
	return admission.Denied(fmt.Sprintf("Network %s refused: %s", Key(obj), strings.Join(msgs, "; ")))
}

func (v *NetworkValidator) fabricNamespace() string {
	if v.FabricNamespace != "" {
		return v.FabricNamespace
	}
	return DefaultFabricNamespace
}

// read gathers what the rules read: every other Network (deleting ones included), the Fabric
// inventory and the qualification record.
func (v *NetworkValidator) read(ctx context.Context, obj *fabricv1.Network) ([]fabricv1.Network, Inventory, Qualification, error) {
	var nets fabricv1.NetworkList
	if err := v.Reader.List(ctx, &nets); err != nil {
		return nil, Inventory{}, Qualification{}, fmt.Errorf("listing Networks: %w", err)
	}
	others := make([]fabricv1.Network, 0, len(nets.Items))
	for _, n := range nets.Items {
		if obj.Name != "" && n.Namespace == obj.Namespace && n.Name == obj.Name {
			continue
		}
		others = append(others, n)
	}
	var fabrics fabricv1.FabricList
	if err := v.Reader.List(ctx, &fabrics, client.InNamespace(v.fabricNamespace())); err != nil {
		return nil, Inventory{}, Qualification{}, fmt.Errorf("listing Fabrics in %s: %w", v.fabricNamespace(), err)
	}
	cm := &corev1.ConfigMap{}
	err := v.Reader.Get(ctx, client.ObjectKey{Namespace: QualificationNamespace, Name: QualificationName}, cm)
	switch {
	case apierrors.IsNotFound(err):
		cm = nil
	case err != nil:
		return nil, Inventory{}, Qualification{}, fmt.Errorf("reading the qualification record %s/%s: %w", QualificationNamespace, QualificationName, err)
	}
	return others, NewInventory(fabrics.Items), QualificationFromConfigMap(cm), nil
}
