// Package migration hosts the optional MigrationPlan controller (T122; FR-048, AD-29,
// data-model.md §5, contracts/crd-api.md §"Optional `MigrationPlan` API").
//
// The controller records; it never translates and never creates or modifies a Network.
// Translation happens in exactly one place — the translator (pkg/migration, FR-060) — and the
// Network it emits is applied by whoever applies Networks. What this controller writes is the
// MigrationPlan's status, through the status subresource only:
//
//   - status.construct and status.sourceVocabulary: the construct the service became and the
//     migration alias it arrived as, resolved by pkg/migration's own vocabulary (Canonicalize);
//   - status.unsupportedFeatures: every exact non-mappable semantic of the source, each with a
//     stable code and the field path — Translated=False/UnsupportedFeature while any stands;
//   - status.generatedNetworkRef: a reference, filled in once the target Network exists (a
//     Get — the controller never creates it), and cleared if it goes;
//   - status.provenanceRef: the Network's provenance annotation KEYS present on it, never their
//     values — the annotations on the Network are the single provenance record (FR-046), which
//     a plan references and never restates (FR-048). A Network whose construct or source
//     vocabulary annotation disagrees with the plan is Translated=False/Collision, naming the
//     keys;
//   - status.perDevice: the Network's per-target phase, read-only;
//   - Ready and Degraded mirroring the Network's own when it exists and translation stands.
//
// Cutover: spec.mappingPolicy.cutover is disabled by default (CRD default) and, whatever its
// value, this controller performs no cutover of any kind — no automatic live cutover exists.
//
// The controller runs under its own ClusterRole (config/rbac/migration/role.yaml): get, list,
// watch and status updates on migrationplans, get, list, watch on networks, Events — no write
// verb on networks at all. It is registered by cmd/srl-provider only when the MigrationPlan CRD
// is served (the CRD is optional, config/crd/optional/, not installed by default — T016).
package migration

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"time"

	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	migrationv1 "github.com/mairp/agentic-netops-srl/api/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/status"
	vocab "github.com/mairp/agentic-netops-srl/pkg/migration"
)

// TargetNetworkIndex is the field index of MigrationPlans by their target Network,
// "<namespace>/<name>" (the namespace defaulted to the plan's own).
const TargetNetworkIndex = "spec.targetNetworkRef"

// Unsupported-feature codes (status.unsupportedFeatures[].code): stable, structured.
const (
	CodeLimitedEquivalenceNotAllowed = "limited-equivalence-not-allowed"
	CodePointToPointEndpoints        = "point-to-point-endpoint-count"
	CodePrefixesOnBridgedService     = "prefixes-on-bridged-service"
	CodeGatewayNotIntegrated         = "gateway-on-non-integrated-service"
	CodeIntegratedWithoutGateway     = "integrated-service-without-gateway"
	CodeUnknownServiceType           = "unknown-service-type"
)

// ProvenanceKeys are the Network provenance annotation keys a plan may reference (keys only).
// The order is the reference order in status.provenanceRef.annotationKeys.
func ProvenanceKeys() []string {
	return []string{vocab.AnnotationServiceType, vocab.AnnotationSourceServiceType, vocab.AnnotationLimitedEquivalence}
}

// LimitedEquivalenceFinding is the durable Translated=True finding of an opted-in VPWS.
const LimitedEquivalenceFinding = "limited equivalence: point-to-point represented by a dedicated L2VNI"

// NoCutover is stated on every Accepted condition: the controller performs no cutover.
const NoCutover = "no automatic live cutover exists: this controller never performs a cutover"

// Reconciler records one MigrationPlan's translation and rollout evidence.
type Reconciler struct {
	// Client reads MigrationPlans and Networks and writes MigrationPlan status only.
	Client   client.Client
	Recorder record.EventRecorder
	// Now stamps condition transitions; time.Now when nil.
	Now func() time.Time
}

// SetupWithManager registers the controller: MigrationPlans on a spec change, and Networks
// mapped to the plans that reference them — so generatedNetworkRef fills in once the Network
// appears and perDevice and Ready follow its status.
func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	if err := mgr.GetFieldIndexer().IndexField(context.Background(), &migrationv1.MigrationPlan{}, TargetNetworkIndex,
		func(o client.Object) []string {
			p, ok := o.(*migrationv1.MigrationPlan)
			if !ok {
				return nil
			}
			return []string{targetKey(p)}
		}); err != nil {
		return fmt.Errorf("migrationplan index: %w", err)
	}
	return ctrl.NewControllerManagedBy(mgr).
		Named("migrationplan").
		For(&migrationv1.MigrationPlan{}, builder.WithPredicates(predicate.GenerationChangedPredicate{})).
		Watches(&fabricv1.Network{}, handler.EnqueueRequestsFromMapFunc(r.plansOfNetwork)).
		Complete(r)
}

func targetRef(p *migrationv1.MigrationPlan) migrationv1.NetworkReference {
	ref := p.Spec.TargetNetworkRef
	if ref.Namespace == "" {
		ref.Namespace = p.Namespace
	}
	return ref
}

func targetKey(p *migrationv1.MigrationPlan) string {
	ref := targetRef(p)
	return ref.Namespace + "/" + ref.Name
}

func (r *Reconciler) plansOfNetwork(ctx context.Context, o client.Object) []reconcile.Request {
	l := &migrationv1.MigrationPlanList{}
	if err := r.Client.List(ctx, l, client.MatchingFields{TargetNetworkIndex: o.GetNamespace() + "/" + o.GetName()}); err != nil {
		return nil
	}
	out := make([]reconcile.Request, 0, len(l.Items))
	for _, p := range l.Items {
		out = append(out, reconcile.Request{NamespacedName: types.NamespacedName{Namespace: p.Namespace, Name: p.Name}})
	}
	return out
}

// Reconcile records one plan's status. It reads the target Network with a Get and writes
// nothing but the plan's status subresource.
func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		plan := &migrationv1.MigrationPlan{}
		if err := r.Client.Get(ctx, req.NamespacedName, plan); err != nil {
			return client.IgnoreNotFound(err)
		}
		if plan.DeletionTimestamp != nil {
			return nil // nothing to release: the plan holds no finalizer and owns nothing
		}
		ref := targetRef(plan)
		var net *fabricv1.Network
		n := &fabricv1.Network{}
		switch err := r.Client.Get(ctx, types.NamespacedName{Namespace: ref.Namespace, Name: ref.Name}, n); {
		case err == nil:
			net = n
		case apierrors.IsNotFound(err):
		default:
			return err
		}
		before := plan.Status.DeepCopy()
		if err := r.record(plan, net); err != nil {
			return err
		}
		if equality.Semantic.DeepEqual(before, &plan.Status) {
			return nil
		}
		return r.Client.Status().Update(ctx, plan)
	})
	return ctrl.Result{}, err
}

// Evaluate is the pure translation review of a plan: the construct, the source vocabulary and
// every unsupported feature, in field order. ok is false for a service type the vocabulary
// does not resolve (the CRD's enum makes that unreachable).
func Evaluate(spec migrationv1.MigrationPlanSpec) (res vocab.Resolution, unsupported []migrationv1.UnsupportedFeature, ok bool) {
	st := string(spec.Source.ServiceType)
	res, ok = vocab.Canonicalize(st)
	if !ok || res.Source == "" {
		return res, []migrationv1.UnsupportedFeature{{Code: CodeUnknownServiceType, FieldPath: "spec.source.serviceType",
			Message: fmt.Sprintf("%q is not a migration alias (VPLS, VPWS, L3VPN, L2L3-IRB)", st)}}, false
	}
	in := spec.Source.NormalizedIntent
	add := func(code, path, msg string) {
		unsupported = append(unsupported, migrationv1.UnsupportedFeature{Code: code, FieldPath: path, Message: msg})
	}
	bridged := res.Source == "VPLS" || res.Source == "VPWS"
	if res.Source == "VPWS" {
		if spec.MappingPolicy.AllowLimitedEquivalence == nil || !*spec.MappingPolicy.AllowLimitedEquivalence {
			add(CodeLimitedEquivalenceNotAllowed, "spec.mappingPolicy.allowLimitedEquivalence",
				"VPWS maps onto mac-vrf only as a limited equivalence (point-to-point represented by a dedicated L2VNI); set allowLimitedEquivalence: true to opt in")
		}
		if len(in.Endpoints) != 2 {
			add(CodePointToPointEndpoints, "spec.source.normalizedIntent.endpoints",
				fmt.Sprintf("a point-to-point service has exactly 2 endpoints, not %d", len(in.Endpoints)))
		}
	}
	if bridged && len(in.Prefixes) > 0 {
		add(CodePrefixesOnBridgedService, "spec.source.normalizedIntent.prefixes",
			fmt.Sprintf("%s folds onto mac-vrf, which carries no prefixes; a routed service is L3VPN, a gateway is L2L3-IRB", res.Source))
	}
	if in.Gateway != nil && (bridged || res.Source == "L3VPN") {
		add(CodeGatewayNotIntegrated, "spec.source.normalizedIntent.gateway",
			fmt.Sprintf("a gateway belongs to the integrated alias L2L3-IRB (mac-vrf with an anycast gateway), not %s", res.Source))
	}
	if res.Source == "L2L3-IRB" && (in.Gateway == nil || (in.Gateway.IPv4 == "" && in.Gateway.IPv6 == "")) {
		add(CodeIntegratedWithoutGateway, "spec.source.normalizedIntent.gateway",
			"L2L3-IRB maps onto mac-vrf with an anycast gateway; the source declares no gateway address")
	}
	return res, unsupported, true
}

// limitedEquivalence reports whether the plan is an opted-in VPWS.
func limitedEquivalence(spec migrationv1.MigrationPlanSpec, res vocab.Resolution) bool {
	return res.Source == "VPWS" && spec.MappingPolicy.AllowLimitedEquivalence != nil && *spec.MappingPolicy.AllowLimitedEquivalence
}

// collisions names the provenance annotation keys of net that disagree with the plan (the
// values are compared, never recorded).
func collisions(net *fabricv1.Network, res vocab.Resolution, limited bool) []string {
	ann := net.GetAnnotations()
	var out []string
	if v, ok := ann[vocab.AnnotationServiceType]; !ok {
		out = append(out, vocab.AnnotationServiceType)
	} else if r, ok := vocab.Canonicalize(v); !ok || r.Construct != res.Construct {
		out = append(out, vocab.AnnotationServiceType)
	}
	if v, ok := ann[vocab.AnnotationSourceServiceType]; !ok {
		out = append(out, vocab.AnnotationSourceServiceType)
	} else if r, ok := vocab.Canonicalize(v); !ok || r.Source != res.Source {
		out = append(out, vocab.AnnotationSourceServiceType)
	}
	if _, ok := ann[vocab.AnnotationLimitedEquivalence]; ok != limited {
		out = append(out, vocab.AnnotationLimitedEquivalence)
	}
	return out
}

// record computes the plan's status from its spec and the Network (nil when absent).
func (r *Reconciler) record(plan *migrationv1.MigrationPlan, net *fabricv1.Network) error {
	st := &plan.Status
	conds := status.For(plan, &st.Conditions, r.Recorder)
	if r.Now != nil {
		conds = conds.WithNow(r.Now)
	}
	st.ObservedGeneration = plan.Generation
	res, unsupported, ok := Evaluate(plan.Spec)
	st.UnsupportedFeatures = unsupported
	st.Construct, st.SourceVocabulary = "", ""
	if ok {
		st.Construct = migrationv1.Construct(res.Construct)
		st.SourceVocabulary = migrationv1.SourceServiceType(res.Source)
	}
	if !ok {
		if err := conds.SetNotAccepted(status.ReasonInvalidIntent, unsupported[0].Message); err != nil {
			return err
		}
	} else if err := conds.SetAccepted("source service recorded; cutover " + string(cutover(plan)) + "; " + NoCutover); err != nil {
		return err
	}

	ref := targetRef(plan)
	limited := ok && limitedEquivalence(plan.Spec, res)
	st.GeneratedNetworkRef, st.ProvenanceRef, st.PerDevice = nil, nil, nil
	var collided []string
	if net != nil {
		st.GeneratedNetworkRef = &migrationv1.NetworkReference{Name: ref.Name, Namespace: ref.Namespace}
		var keys []string
		for _, k := range ProvenanceKeys() {
			if _, has := net.GetAnnotations()[k]; has {
				keys = append(keys, k)
			}
		}
		st.ProvenanceRef = &migrationv1.ProvenanceReference{Network: *st.GeneratedNetworkRef, AnnotationKeys: keys}
		for _, rc := range net.Status.RenderedConfigs {
			st.PerDevice = append(st.PerDevice, migrationv1.PerDeviceStatus{Target: rc.Node, Phase: string(rc.Phase), Reason: rc.Reason, ConfigRef: rc.Name})
		}
		if ok {
			collided = collisions(net, res, limited)
		}
	}

	translated := false
	switch {
	case len(unsupported) > 0:
		codes := make([]string, 0, len(unsupported))
		for _, u := range unsupported {
			codes = append(codes, u.Code+" at "+u.FieldPath)
		}
		if err := conds.SetNotTranslated(status.ReasonUnsupportedFeature, "unsupported: "+strings.Join(codes, "; ")); err != nil {
			return err
		}
	case len(collided) > 0:
		if err := conds.SetNotTranslated(status.ReasonCollision, fmt.Sprintf("Network %s/%s provenance annotations disagree with the plan (%s %s): %s",
			ref.Namespace, ref.Name, res.Source, res.Construct, strings.Join(collided, ", "))); err != nil {
			return err
		}
	default:
		translated = true
		msg := fmt.Sprintf("%s maps onto %s", res.Source, res.Construct)
		if limited {
			msg += "; " + LimitedEquivalenceFinding + " (recorded on the Network as " + vocab.AnnotationLimitedEquivalence + ")"
		}
		if err := conds.SetTranslated(msg); err != nil {
			return err
		}
	}
	return r.readiness(conds, ref, net, translated)
}

func cutover(plan *migrationv1.MigrationPlan) migrationv1.CutoverMode {
	if plan.Spec.MappingPolicy.Cutover == "" {
		return "disabled"
	}
	return plan.Spec.MappingPolicy.Cutover
}

// readiness sets Ready and Degraded: waiting for the Network, not translated, or mirroring
// the Network's own. The order of the two writes keeps §18's coexistence rule at each step.
func (r *Reconciler) readiness(conds *status.Conditions, ref migrationv1.NetworkReference, net *fabricv1.Network, translated bool) error {
	readyStatus, readyReason, readyMsg := metav1.ConditionFalse, status.ReasonNotConverged, ""
	degradedReason, degradedMsg := "", "no impaired dependency recorded"
	switch {
	case net == nil:
		readyMsg = fmt.Sprintf("waiting for Network %s/%s to be applied; this controller never creates it", ref.Namespace, ref.Name)
	case !translated:
		readyMsg = fmt.Sprintf("Network %s/%s exists but the plan is not translated", ref.Namespace, ref.Name)
	default:
		readyMsg = fmt.Sprintf("Network %s/%s reports no Ready condition yet", ref.Namespace, ref.Name)
		if c := meta.FindStatusCondition(net.Status.Conditions, fabricv1.ConditionReady); c != nil {
			readyMsg = fmt.Sprintf("Network %s/%s: %s", ref.Namespace, ref.Name, c.Message)
			switch c.Status {
			case metav1.ConditionTrue:
				readyStatus, readyReason = metav1.ConditionTrue, status.ReasonAsExpected
			case metav1.ConditionUnknown:
				readyStatus, readyReason = metav1.ConditionUnknown, status.ReasonVerificationFailed
			default:
				if slices.Contains([]string{status.ReasonNotConverged, status.ReasonNotProgrammed, status.ReasonRoutesMissing}, c.Reason) {
					readyReason = c.Reason
				}
			}
		}
		if c := meta.FindStatusCondition(net.Status.Conditions, fabricv1.ConditionDegraded); c != nil && c.Status == metav1.ConditionTrue {
			if spec, ok := status.Spec(status.Degraded); ok && slices.Contains(spec.Reasons, c.Reason) {
				degradedReason, degradedMsg = c.Reason, fmt.Sprintf("Network %s/%s: %s", ref.Namespace, ref.Name, c.Message)
			}
		}
	}
	if readyStatus == metav1.ConditionTrue && degradedReason != "" && !status.CoexistsWithReady(degradedReason) {
		readyStatus, readyReason = metav1.ConditionFalse, status.ReasonNotConverged
	}
	setReady := func() error {
		switch readyStatus {
		case metav1.ConditionTrue:
			return conds.SetReady(readyMsg)
		case metav1.ConditionUnknown:
			return conds.SetReadyUnknown(readyMsg)
		}
		return conds.SetNotReady(readyReason, readyMsg)
	}
	setDegraded := func() error {
		if degradedReason == "" {
			return conds.ClearDegraded(degradedMsg)
		}
		return conds.SetDegraded(degradedReason, degradedMsg)
	}
	if readyStatus == metav1.ConditionTrue {
		if err := setDegraded(); err != nil {
			return err
		}
		return setReady()
	}
	if err := setReady(); err != nil {
		return err
	}
	return setDegraded()
}
