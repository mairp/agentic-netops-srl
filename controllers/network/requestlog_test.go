package network

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/telemetry/jsonlog"
)

// The framework's own line about a request ("Reconciler error") carries the correlation id of a
// labelled Network and none for an unlabelled one (NFR-014, data-model.md §27).
func TestRequestLoggerCarriesCorrelationID(t *testing.T) {
	scheme := runtime.NewScheme()
	if err := fabricv1.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	cid := "0123456789abcdef0123456789abcdef"
	labelled := &fabricv1.Network{ObjectMeta: metav1.ObjectMeta{Namespace: "agentic-netops-intent", Name: "migr-0123456789abcde",
		Labels: map[string]string{jsonlog.LabelCorrelationID: cid}}}
	plain := &fabricv1.Network{ObjectMeta: metav1.ObjectMeta{Namespace: "agentic-netops-services", Name: "lab-macvrf"}}
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(labelled, plain).Build()
	var buf bytes.Buffer
	ctor := requestLogger(jsonlog.NewLogger(&buf, "srl-provider", false, func() time.Time { return time.Unix(0, 0) }), c)
	for _, n := range []*fabricv1.Network{labelled, plain} {
		req := &reconcile.Request{NamespacedName: types.NamespacedName{Namespace: n.Namespace, Name: n.Name}}
		ctor(req).Error(nil, "Reconciler error")
	}
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("want 2 lines, got %d: %s", len(lines), buf.String())
	}
	for i, want := range []string{cid, ""} {
		var m map[string]any
		if err := json.Unmarshal([]byte(lines[i]), &m); err != nil {
			t.Fatal(err)
		}
		got, _ := m[jsonlog.FieldCorrelationID].(string)
		if got != want {
			t.Errorf("line %d correlation_id = %q, want %q (%s)", i, got, want, lines[i])
		}
		if m["name"] == nil || m["namespace"] == nil {
			t.Errorf("line %d lacks namespace/name: %s", i, lines[i])
		}
	}
	// the Network is deleted between two requests: the second line keeps the id last seen
	buf.Reset()
	if err := c.Delete(context.Background(), labelled); err != nil {
		t.Fatal(err)
	}
	ctor(&reconcile.Request{NamespacedName: types.NamespacedName{Namespace: labelled.Namespace, Name: labelled.Name}}).Error(nil, "Reconciler error")
	var m map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(buf.Bytes()), &m); err != nil {
		t.Fatal(err)
	}
	if m[jsonlog.FieldCorrelationID] != cid {
		t.Errorf("after deletion correlation_id = %v, want %q", m[jsonlog.FieldCorrelationID], cid)
	}
	if ctor(nil).GetSink() == nil {
		t.Error("nil request must still yield a logger")
	}
}
