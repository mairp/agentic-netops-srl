// Package jsonlog is the NFR-014 structured logger, dependency-free (logr only) so that a workload
// with no cluster client — the intent-translator sidecar — logs in exactly the provider's format
// without importing internal/telemetry's metrics (and through them controller-runtime).
// internal/telemetry re-exports it for the provider.
package jsonlog

// Structured logging (T042, T097; NFR-014, data-model.md §27, AD-14): every line a
// first-party Go workload writes is ONE JSON object on standard output with the fields
//
//	ts             UTC, RFC 3339 (nanosecond precision)
//	level          debug | info | warn | error
//	component      the workload: srl-provider, intent-translator
//	msg            one sentence, written for an operator
//	kind, namespace, name   the resource the line is about, when there is one
//	correlation_id on every line about an object that carries the correlation label
//
// in that order, followed by the line's other key/value pairs sorted by key.
// Every value passes the FR-079 redaction below before it is written. A log line
// is never the only record of an outcome — conditions, Events and metrics carry
// that (NFR-005). T133 changes this file only if a field is missing (AD-50).

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/go-logr/logr"
)

// LabelCorrelationID is the correlation label a submitted object carries
// (contracts/kubernetes-objects.md §Resource stamping).
const LabelCorrelationID = "agentic-netops.io/correlation-id"

// Fixed field names.
const (
	FieldTS            = "ts"
	FieldLevel         = "level"
	FieldComponent     = "component"
	FieldMsg           = "msg"
	FieldKind          = "kind"
	FieldNamespace     = "namespace"
	FieldName          = "name"
	FieldCorrelationID = "correlation_id"
)

// levelKey is the key/value marker Warn uses to emit level "warn" (logr has
// no warn level of its own).
const levelKey = "__level"

// ObjectValues are the key/values naming the resource a line is about, with
// its correlation id when the object carries the correlation label.
func ObjectValues(kind, namespace, name string, labels map[string]string) []any {
	kv := []any{FieldKind, kind, FieldNamespace, namespace, FieldName, name}
	if id := labels[LabelCorrelationID]; id != "" {
		kv = append(kv, FieldCorrelationID, id)
	}
	return kv
}

// Warn writes one line at level warn.
func Warn(l logr.Logger, msg string, kv ...any) {
	l.Info(msg, append(append([]any{}, kv...), levelKey, "warn")...)
}

// NewLogger returns a logr.Logger writing NFR-014 JSON lines to w. debug
// enables V(1)+ lines (level debug); otherwise they are dropped.
func NewLogger(w io.Writer, component string, debug bool, now func() time.Time) logr.Logger {
	if now == nil {
		now = time.Now
	}
	return logr.New(&sink{w: w, mu: &sync.Mutex{}, component: component, debug: debug, now: now})
}

type sink struct {
	w         io.Writer
	mu        *sync.Mutex
	component string
	debug     bool
	now       func() time.Time
	names     []string
	values    []any
}

func (s *sink) Init(logr.RuntimeInfo) {}

func (s *sink) Enabled(level int) bool { return level == 0 || s.debug }

func (s *sink) Info(level int, msg string, kv ...any) {
	lvl := "info"
	if level > 0 {
		lvl = "debug"
	}
	s.write(lvl, msg, nil, kv)
}

func (s *sink) Error(err error, msg string, kv ...any) { s.write("error", msg, err, kv) }

func (s *sink) WithValues(kv ...any) logr.LogSink {
	c := *s
	c.values = append(append([]any{}, s.values...), kv...)
	return &c
}

func (s *sink) WithName(name string) logr.LogSink {
	c := *s
	c.names = append(append([]string{}, s.names...), name)
	return &c
}

func (s *sink) write(level, msg string, err error, kv []any) {
	fields := map[string]any{}
	all := append(append([]any{}, s.values...), kv...)
	for i := 0; i+1 < len(all); i += 2 {
		k, ok := all[i].(string)
		if !ok {
			k = fmt.Sprint(all[i])
		}
		if k == levelKey {
			if v, ok := all[i+1].(string); ok && v == "warn" && level == "info" {
				level = "warn"
			}
			continue
		}
		fields[k] = all[i+1]
	}
	if len(all)%2 == 1 {
		fields["_odd"] = all[len(all)-1]
	}
	if err != nil {
		fields["error"] = err.Error()
	}
	if len(s.names) > 0 {
		fields["logger"] = strings.Join(s.names, ".")
	}
	// controller-runtime names the reconciled object under its Kind (e.g.
	// "Fabric": {"name":…,"namespace":…}); lift it into kind/namespace/name.
	if _, has := fields[FieldKind]; !has {
		if ck, ok := fields["controllerKind"].(string); ok {
			if ref, ok := fields[ck]; ok {
				if name, ns, ok := objectRef(ref); ok {
					fields[FieldKind], fields[FieldName], fields[FieldNamespace] = ck, name, ns
				}
			}
		}
	}

	var b bytes.Buffer
	b.WriteByte('{')
	first := true
	put := func(k string, v any) {
		if !first {
			b.WriteByte(',')
		}
		first = false
		kb, _ := json.Marshal(k)
		b.Write(kb)
		b.WriteByte(':')
		vb, e := json.Marshal(redactValue(k, v))
		if e != nil {
			vb, _ = json.Marshal(fmt.Sprint(v))
		}
		b.Write(vb)
	}
	put(FieldTS, s.now().UTC().Format(time.RFC3339Nano))
	put(FieldLevel, level)
	put(FieldComponent, s.component)
	put(FieldMsg, msg)
	for _, k := range []string{FieldKind, FieldNamespace, FieldName, FieldCorrelationID} {
		if v, ok := fields[k]; ok {
			put(k, v)
			delete(fields, k)
		}
	}
	rest := make([]string, 0, len(fields))
	for k := range fields {
		rest = append(rest, k)
	}
	sort.Strings(rest)
	for _, k := range rest {
		put(k, fields[k])
	}
	b.WriteString("}\n")
	s.mu.Lock()
	defer s.mu.Unlock()
	_, _ = s.w.Write(b.Bytes())
}

func objectRef(v any) (name, namespace string, ok bool) {
	switch r := v.(type) {
	case map[string]any:
		n, _ := r["name"].(string)
		ns, _ := r["namespace"].(string)
		return n, ns, n != ""
	case fmt.Stringer:
		s := r.String()
		if i := strings.Index(s, "/"); i >= 0 {
			return s[i+1:], s[:i], true
		}
		return s, "", s != ""
	}
	b, err := json.Marshal(v)
	if err != nil {
		return "", "", false
	}
	var m map[string]any
	if json.Unmarshal(b, &m) != nil {
		return "", "", false
	}
	n, _ := m["name"].(string)
	ns, _ := m["namespace"].(string)
	return n, ns, n != ""
}

// ---------------------------------------------------------------------------
// FR-079 redaction: a value under a credential-like key is replaced, and a URL
// carrying userinfo, a bearer token or a key=secret pair in any string value
// is masked.
// ---------------------------------------------------------------------------

// Redacted replaces a removed value.
const Redacted = "[REDACTED]"

var (
	secretKey  = regexp.MustCompile(`(?i)(pass(word|wd)?|secret|token|api[-_]?key|authorization|credential|private[-_]?key)`)
	bearer     = regexp.MustCompile(`(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}`)
	kvSecret   = regexp.MustCompile(`(?i)\b(pass(word|wd)?|secret|token|api[-_]?key)=([^\s&;,]+)`)
	urlWithTok = regexp.MustCompile(`[a-zA-Z][a-zA-Z0-9+.-]*://[^\s/@]+:[^\s/@]*@[^\s]+`)
)

func redactValue(key string, v any) any {
	if secretKey.MatchString(key) {
		return Redacted
	}
	s, ok := v.(string)
	if !ok {
		return v
	}
	return RedactString(s)
}

// RedactString masks credentials embedded in a string value.
func RedactString(s string) string {
	s = urlWithTok.ReplaceAllStringFunc(s, func(m string) string {
		u, err := url.Parse(m)
		if err != nil || u.User == nil {
			return Redacted
		}
		u.User = url.User(Redacted)
		return u.String()
	})
	s = bearer.ReplaceAllString(s, "$1 "+Redacted)
	return kvSecret.ReplaceAllString(s, "$1="+Redacted)
}
