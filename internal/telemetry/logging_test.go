package telemetry

import (
	"bytes"
	"encoding/json"
	"errors"
	stdlog "log"
	"strings"
	"testing"
	"time"
)

func lines(t *testing.T, b *bytes.Buffer) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(b.String()), "\n") {
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatalf("not one JSON object per line: %q: %v", l, err)
		}
		out = append(out, m)
	}
	return out
}

func TestLogRecordFieldsOfDataModel27(t *testing.T) {
	var b bytes.Buffer
	now := func() time.Time { return time.Date(2026, 9, 21, 12, 0, 0, 5, time.FixedZone("CEST", 7200)) }
	l := NewLogger(&b, Component, true, now)
	l.WithValues(ObjectValues("Fabric", "agentic-netops-system", "fabric01", map[string]string{LabelCorrelationID: "abc123"})...).
		Info("fabric configuration applied to every node", "configs", 4)
	l.V(1).Info("debug line")
	Warn(l, "telemetry dependency impaired")
	l.Error(errors.New("boom"), "reconcile failed", "kind", "Network", "namespace", "ns", "name", "n1")

	got := lines(t, &b)
	if len(got) != 4 {
		t.Fatalf("%d lines", len(got))
	}
	first := got[0]
	if first["ts"] != "2026-09-21T10:00:00.000000005Z" {
		t.Errorf("ts not UTC RFC 3339: %v", first["ts"])
	}
	if _, err := time.Parse(time.RFC3339, first["ts"].(string)); err != nil {
		t.Errorf("ts: %v", err)
	}
	for k, v := range map[string]any{"level": "info", "component": "srl-provider", "msg": "fabric configuration applied to every node",
		"kind": "Fabric", "namespace": "agentic-netops-system", "name": "fabric01", "correlation_id": "abc123", "configs": float64(4)} {
		if first[k] != v {
			t.Errorf("%s = %v, want %v", k, first[k], v)
		}
	}
	if got[1]["level"] != "debug" || got[2]["level"] != "warn" || got[3]["level"] != "error" || got[3]["error"] != "boom" {
		t.Errorf("levels: %v %v %v", got[1]["level"], got[2]["level"], got[3])
	}
	if _, ok := got[2]["__level"]; ok {
		t.Error("warn marker leaked into the line")
	}
	// fixed field order: ts, level, component, msg first
	raw := strings.SplitN(b.String(), "\n", 2)[0]
	if !strings.HasPrefix(raw, `{"ts":`) || strings.Index(raw, `"level"`) > strings.Index(raw, `"component"`) ||
		strings.Index(raw, `"component"`) > strings.Index(raw, `"msg"`) {
		t.Errorf("field order: %s", raw)
	}
}

func TestDebugDroppedUnlessEnabledAndNoCorrelationWithoutLabel(t *testing.T) {
	var b bytes.Buffer
	l := NewLogger(&b, Component, false, nil)
	l.V(1).Info("hidden")
	l.WithValues(ObjectValues("Fabric", "ns", "f", nil)...).Info("shown")
	got := lines(t, &b)
	if len(got) != 1 || got[0]["msg"] != "shown" {
		t.Fatalf("%v", got)
	}
	if _, ok := got[0]["correlation_id"]; ok {
		t.Error("correlation_id on an object without the label")
	}
}

func TestControllerRuntimeObjectLifted(t *testing.T) {
	var b bytes.Buffer
	l := NewLogger(&b, Component, false, nil)
	l.Info("Reconciler error", "controllerKind", "Fabric", "Fabric", map[string]any{"name": "fabric01", "namespace": "agentic-netops-system"})
	g := lines(t, &b)[0]
	if g["kind"] != "Fabric" || g["name"] != "fabric01" || g["namespace"] != "agentic-netops-system" {
		t.Errorf("%v", g)
	}
}

func TestRedaction(t *testing.T) {
	var b bytes.Buffer
	l := NewLogger(&b, Component, false, nil)
	l.Info("connecting", "password", "NokiaSrl1!", "endpoint", "https://admin:NokiaSrl1!@10.0.0.1:57400/x",
		"header", "Authorization: Bearer abcdefghijklmnop", "q", "user=a token=s3cr3t")
	out := b.String()
	for _, secret := range []string{"NokiaSrl1!", "abcdefghijklmnop", "s3cr3t"} {
		if strings.Contains(out, secret) {
			t.Errorf("secret %q written: %s", secret, out)
		}
	}
	if !strings.Contains(out, Redacted) {
		t.Errorf("no redaction marker: %s", out)
	}
}

// T147 r8: net/http's "TLS handshake error" went through the standard library's log package as a
// bare text line. Routed through StdlogWriter it is one JSON object carrying the NFR-014 fields.
func TestStdlibLogLinesBecomeJSON(t *testing.T) {
	var b bytes.Buffer
	l := NewLogger(&b, Component, false, nil)
	std := stdlog.New(StdlogWriter(l), "", 0)
	std.Printf("http: TLS handshake error from %s: EOF", "10.244.0.33:49424")
	got := lines(t, &b)
	if len(got) != 1 {
		t.Fatalf("%d lines", len(got))
	}
	if got[0]["msg"] != "http: TLS handshake error from 10.244.0.33:49424: EOF" || got[0]["level"] != "warn" ||
		got[0]["component"] != Component || got[0]["ts"] == nil {
		t.Fatalf("record %v", got[0])
	}
}
