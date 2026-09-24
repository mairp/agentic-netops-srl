package telemetry

// Reconcile tracing (T133; NFR-014, contracts/reconciliation.md Rule 9, data-model.md §21): one
// span per reconcile of the provider's reconcilers, carrying the resource's identity — kind,
// namespace, name, and once the object is read its generation, uid and the correlation label
// where it carries one — and ending with the reconcile's result class. The spans go through the
// global tracer provider, which cmd/srl-provider points at the collector over OTLP when
// OTEL_EXPORTER_OTLP_ENDPOINT is set (controllers send their own OTLP directly to the collector,
// §21) and which is otherwise the no-op provider. Export happens off the reconcile path (the
// SDK's batch span processor): an absent collector never delays or blocks a reconcile (Rule 9).
// Trace identifiers are never metric labels (§21).

import (
	"context"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

// TracerName is the instrumentation scope of the provider's spans.
const TracerName = "github.com/mairp/agentic-netops-srl/srl-provider"

// Span attribute keys (the OpenTelemetry Kubernetes conventions where one exists).
const (
	AttrKind          = "k8s.resource.kind"
	AttrNamespace     = "k8s.namespace.name"
	AttrName          = "k8s.resource.name"
	AttrGeneration    = "k8s.resource.generation"
	AttrUID           = "k8s.resource.uid"
	AttrCorrelationID = "agentic_netops.correlation_id"
	AttrController    = "agentic_netops.controller"
	AttrResult        = "agentic_netops.reconcile.result"
)

// StartReconcile starts the span of one reconcile of controller over the object kind
// namespace/name (the request's identity; the object may not exist).
func StartReconcile(ctx context.Context, controller, kind, namespace, name string) (context.Context, trace.Span) {
	return otel.Tracer(TracerName).Start(ctx, controller+".Reconcile", trace.WithSpanKind(trace.SpanKindInternal),
		trace.WithAttributes(
			attribute.String(AttrController, controller),
			attribute.String(AttrKind, kind),
			attribute.String(AttrNamespace, namespace),
			attribute.String(AttrName, name),
		))
}

// AnnotateObject adds the read object's generation, uid and correlation label (when it carries
// one, LabelCorrelationID) to span.
func AnnotateObject(span trace.Span, generation int64, uid string, labels map[string]string) {
	attrs := []attribute.KeyValue{attribute.Int64(AttrGeneration, generation), attribute.String(AttrUID, uid)}
	if id := labels[LabelCorrelationID]; id != "" {
		attrs = append(attrs, attribute.String(AttrCorrelationID, id))
	}
	span.SetAttributes(attrs...)
}

// EndReconcile ends span with the reconcile's result class; a returned error or an error class
// marks the span's status an error (the message redacted, never a label anywhere).
func EndReconcile(span trace.Span, result string, err error) {
	span.SetAttributes(attribute.String(AttrResult, result))
	switch {
	case err != nil:
		span.SetStatus(codes.Error, RedactString(err.Error()))
	case result == ResultTransient || result == ResultTerminal || result == ResultError:
		span.SetStatus(codes.Error, result)
	default:
		span.SetStatus(codes.Ok, "")
	}
	span.End()
}
