package telemetry

// The telemetry-health input (T133; data-model.md §18, AD-62, contracts/reconciliation.md Rule 9,
// NFR-005): the provider's own telemetry health, reported separately from configuration
// readiness. It is what the Fabric (T040) and Network (T059) reconcilers are given as their
// TelemetryHealth input and the ONLY thing Degraded=True/TelemetryUnavailable is ever set from —
// last in §18's order, never from a device read. It never blocks configuration: the reconcilers
// only read it to word Degraded; nothing waits on it and nothing is withheld because of it.
//
// ExportHealth follows the provider's OTLP export to the collector: it wraps the trace exporter
// (every export's outcome is recorded) and is the OpenTelemetry global error handler (every error
// the SDK reports). The export is unhealthy from a failed export until the next export succeeds.
// With no OTLP endpoint configured it reports healthy with the detail "OTLP export not
// configured". Its current value is exported as agentic_netops_telemetry_healthy (metrics.go).

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/go-logr/logr"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// DetailNotConfigured is the detail of a provider exporting no OTLP.
const DetailNotConfigured = "OTLP export not configured"

// ExportHealth is the telemetry-health input over the provider's OTLP export.
type ExportHealth struct {
	// Endpoint is the configured collector endpoint (OTEL_EXPORTER_OTLP_ENDPOINT); empty when
	// no OTLP export is configured.
	Endpoint string
	// Log receives one line per transition (healthy → failing, failing → healthy); optional.
	Log logr.Logger
	// Now is the clock; nil is time.Now.
	Now func() time.Time

	mu       sync.Mutex
	failing  bool
	lastErr  error
	since    time.Time
	failures int
}

// NewExportHealth returns the telemetry-health input for endpoint and publishes its initial
// (healthy) value.
func NewExportHealth(endpoint string, log logr.Logger) *ExportHealth {
	h := &ExportHealth{Endpoint: endpoint, Log: log}
	TelemetryHealthy.Set(1)
	return h
}

func (h *ExportHealth) now() time.Time {
	if h.Now != nil {
		return h.Now()
	}
	return time.Now()
}

// TelemetryHealthy implements the reconcilers' TelemetryHealth input.
func (h *ExportHealth) TelemetryHealthy(context.Context) (bool, string) {
	if h.Endpoint == "" {
		return true, DetailNotConfigured
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.failing {
		return false, fmt.Sprintf("OTLP export to %s failing since %s (%d failed exports): %s",
			RedactString(h.Endpoint), h.since.UTC().Format(time.RFC3339), h.failures, RedactString(h.lastErr.Error()))
	}
	return true, "OTLP export to " + RedactString(h.Endpoint) + " healthy"
}

// Handle implements otel.ErrorHandler: an error the SDK reports (a failed export among them)
// marks the export failing.
func (h *ExportHealth) Handle(err error) {
	if err != nil {
		h.record(err)
	}
}

// record notes one export outcome: nil is a success.
func (h *ExportHealth) record(err error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if err == nil {
		if h.failing {
			h.Log.Info("OTLP export healthy again (configuration was never affected)", "endpoint", h.Endpoint, "failedExports", h.failures)
		}
		h.failing, h.lastErr, h.failures = false, nil, 0
		TelemetryHealthy.Set(1)
		return
	}
	if !h.failing {
		h.since = h.now()
		Warn(h.Log, "OTLP export failing; configuration is unaffected (Rule 9)", "endpoint", h.Endpoint, "error", err.Error())
	}
	h.failing, h.lastErr = true, err
	h.failures++
	TelemetryHealthy.Set(0)
}

// WrapExporter returns exp recording every export's outcome in h.
func (h *ExportHealth) WrapExporter(exp sdktrace.SpanExporter) sdktrace.SpanExporter {
	return &healthExporter{SpanExporter: exp, h: h}
}

type healthExporter struct {
	sdktrace.SpanExporter
	h *ExportHealth
}

func (e *healthExporter) ExportSpans(ctx context.Context, spans []sdktrace.ReadOnlySpan) error {
	err := e.SpanExporter.ExportSpans(ctx, spans)
	e.h.record(err)
	return err
}
