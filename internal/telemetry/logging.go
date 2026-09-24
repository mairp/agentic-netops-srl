package telemetry

// Structured logging (T042; NFR-014, data-model.md §27, AD-14): the implementation is
// internal/telemetry/jsonlog — one JSON object per line on standard output with ts, level,
// component, msg, then kind/namespace/name/correlation_id, then the rest sorted by key, every value
// passed through the FR-079 redaction. It lives in its own dependency-free package so the
// intent-translator sidecar logs identically without a cluster client; these names are the
// provider's view of it.

import (
	"io"
	"time"

	"github.com/go-logr/logr"

	"github.com/mairp/agentic-netops-srl/internal/telemetry/jsonlog"
)

// Component is this workload's component value.
const Component = "srl-provider"

// Field names, the correlation label and the redaction marker (see jsonlog).
const (
	LabelCorrelationID = jsonlog.LabelCorrelationID
	FieldTS            = jsonlog.FieldTS
	FieldLevel         = jsonlog.FieldLevel
	FieldComponent     = jsonlog.FieldComponent
	FieldMsg           = jsonlog.FieldMsg
	FieldKind          = jsonlog.FieldKind
	FieldNamespace     = jsonlog.FieldNamespace
	FieldName          = jsonlog.FieldName
	FieldCorrelationID = jsonlog.FieldCorrelationID
	Redacted           = jsonlog.Redacted
)

// ObjectValues are the key/values naming the resource a line is about (jsonlog.ObjectValues).
func ObjectValues(kind, namespace, name string, labels map[string]string) []any {
	return jsonlog.ObjectValues(kind, namespace, name, labels)
}

// Warn writes one line at level warn (jsonlog.Warn).
func Warn(l logr.Logger, msg string, kv ...any) { jsonlog.Warn(l, msg, kv...) }

// NewLogger returns a logr.Logger writing NFR-014 JSON lines to w (jsonlog.NewLogger).
func NewLogger(w io.Writer, component string, debug bool, now func() time.Time) logr.Logger {
	return jsonlog.NewLogger(w, component, debug, now)
}

// RedactString masks credentials embedded in a string value (jsonlog.RedactString).
func RedactString(s string) string { return jsonlog.RedactString(s) }
