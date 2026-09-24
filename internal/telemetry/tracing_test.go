package telemetry

import (
	"context"
	"errors"
	"strings"
	"testing"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
)

// A reconcile span carries the resource's identity — kind, namespace, name, generation, uid and
// the correlation label where the object carries one — and its result (T133, NFR-014).
func TestReconcileSpanCarriesResourceIdentity(t *testing.T) {
	rec := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(rec))
	prev := otel.GetTracerProvider()
	otel.SetTracerProvider(tp)
	t.Cleanup(func() { otel.SetTracerProvider(prev) })

	_, span := StartReconcile(context.Background(), ControllerNetwork, KindNetwork, "agentic-netops-services", "lab-vlan")
	AnnotateObject(span, 3, "uid-1", map[string]string{LabelCorrelationID: "req-42"})
	EndReconcile(span, ResultSuccess, nil)

	_, span = StartReconcile(context.Background(), ControllerFabric, KindFabric, "sdc-system", "fabric01")
	AnnotateObject(span, 1, "uid-2", nil)
	EndReconcile(span, ResultError, errors.New("update status: password=hunter2 refused"))

	ended := rec.Ended()
	if len(ended) != 2 {
		t.Fatalf("%d spans, want 2", len(ended))
	}
	attrs := func(s sdktrace.ReadOnlySpan) map[string]string {
		m := map[string]string{}
		for _, kv := range s.Attributes() {
			m[string(kv.Key)] = kv.Value.Emit()
		}
		return m
	}
	a := attrs(ended[0])
	for k, want := range map[string]string{AttrKind: "Network", AttrNamespace: "agentic-netops-services", AttrName: "lab-vlan",
		AttrGeneration: "3", AttrUID: "uid-1", AttrCorrelationID: "req-42", AttrResult: ResultSuccess, AttrController: ControllerNetwork} {
		if a[k] != want {
			t.Errorf("span attribute %s = %q, want %q", k, a[k], want)
		}
	}
	if ended[0].Status().Code != codes.Ok {
		t.Errorf("a successful reconcile's span status is %v", ended[0].Status())
	}
	b := attrs(ended[1])
	if _, ok := b[AttrCorrelationID]; ok {
		t.Error("a correlation id attribute on an object without the label")
	}
	if b[AttrKind] != "Fabric" || b[AttrName] != "fabric01" || b[AttrUID] != "uid-2" {
		t.Errorf("fabric span identity %v", b)
	}
	if st := ended[1].Status(); st.Code != codes.Error || st.Description == "" || strings.Contains(st.Description, "hunter2") {
		t.Errorf("an errored reconcile's span status %+v (must be Error, redacted)", st)
	}
}
