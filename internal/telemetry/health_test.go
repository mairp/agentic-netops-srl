package telemetry

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/go-logr/logr"
	"github.com/prometheus/client_golang/prometheus/testutil"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
)

// No OTLP endpoint: healthy, "OTLP export not configured" (T133).
func TestExportHealthNotConfigured(t *testing.T) {
	h := NewExportHealth("", logr.Discard())
	ok, detail := h.TelemetryHealthy(context.Background())
	if !ok || detail != DetailNotConfigured {
		t.Fatalf("(%v, %q), want (true, %q)", ok, detail, DetailNotConfigured)
	}
}

// failingExporter fails while fail is set.
type failingExporter struct {
	tracetest.InMemoryExporter
	fail bool
}

func (e *failingExporter) ExportSpans(ctx context.Context, s []sdktrace.ReadOnlySpan) error {
	if e.fail {
		return errors.New("rpc error: code = Unavailable desc = connection refused")
	}
	return e.InMemoryExporter.ExportSpans(ctx, s)
}

// A failed export turns the input unhealthy naming the endpoint and the error, with the
// agentic_netops_telemetry_healthy gauge at 0; the next export that succeeds turns it healthy
// again. The SDK's error handler path does the same (AD-62, Rule 9).
func TestExportHealthFollowsExports(t *testing.T) {
	const ep = "http://device-metrics.monitoring.svc:4317"
	h := NewExportHealth(ep, logr.Discard())
	h.Now = func() time.Time { return time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC) }
	inner := &failingExporter{fail: true}
	exp := h.WrapExporter(inner)

	if ok, _ := h.TelemetryHealthy(context.Background()); !ok {
		t.Fatal("unhealthy before any export")
	}
	if err := exp.ExportSpans(context.Background(), nil); err == nil {
		t.Fatal("the wrapped exporter swallowed the error")
	}
	ok, detail := h.TelemetryHealthy(context.Background())
	if ok || !strings.Contains(detail, ep) || !strings.Contains(detail, "connection refused") || !strings.Contains(detail, "2026-09-24T12:00:00Z") {
		t.Fatalf("after a failed export: (%v, %q)", ok, detail)
	}
	if v := testutil.ToFloat64(TelemetryHealthy); v != 0 {
		t.Errorf("telemetry_healthy = %v while failing", v)
	}
	inner.fail = false
	if err := exp.ExportSpans(context.Background(), nil); err != nil {
		t.Fatal(err)
	}
	if ok, detail := h.TelemetryHealthy(context.Background()); !ok || !strings.Contains(detail, ep) {
		t.Fatalf("after a successful export: (%v, %q)", ok, detail)
	}
	if v := testutil.ToFloat64(TelemetryHealthy); v != 1 {
		t.Errorf("telemetry_healthy = %v after recovery", v)
	}

	h.Handle(errors.New("traces export: context deadline exceeded"))
	if ok, detail := h.TelemetryHealthy(context.Background()); ok || !strings.Contains(detail, "deadline exceeded") {
		t.Fatalf("after an SDK-reported error: (%v, %q)", ok, detail)
	}
	h.Handle(nil)
	if ok, _ := h.TelemetryHealthy(context.Background()); ok {
		t.Fatal("a nil error cleared the failure")
	}
}

// The export never blocks the caller: a span ends at once whatever the exporter does — the
// batch processor exports off the reconcile path, so configuration is never held by telemetry.
func TestExportNeverBlocksSpanEnd(t *testing.T) {
	h := NewExportHealth("http://127.0.0.1:1", logr.Discard())
	block := make(chan struct{})
	t.Cleanup(func() { close(block) })
	tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(h.WrapExporter(&blockingExporter{block: block}),
		sdktrace.WithBatchTimeout(time.Millisecond), sdktrace.WithMaxQueueSize(2)))
	tr := tp.Tracer("t")
	done := make(chan struct{})
	go func() {
		for i := 0; i < 100; i++ {
			_, s := tr.Start(context.Background(), "reconcile")
			s.End()
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("ending spans blocked on a stuck exporter")
	}
}

type blockingExporter struct {
	tracetest.InMemoryExporter
	block chan struct{}
}

func (e *blockingExporter) ExportSpans(ctx context.Context, _ []sdktrace.ReadOnlySpan) error {
	select {
	case <-e.block:
	case <-ctx.Done():
	}
	return ctx.Err()
}
