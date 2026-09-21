package status

import (
	"errors"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	fabricv1alpha1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/record"
)

// section18 is data-model.md §18 transcribed literally from the table, row by
// row: condition → reason codes (the non-nominal status's reasons, plus Ready's
// one Unknown reason). The helper's data must equal it exactly — a condition
// or reason §18 does not define cannot appear.
var section18 = map[string][]string{
	"Accepted":   {"InvalidIntent", "ReferenceNotFound", "Unqualified", "AllocationConflict"},
	"Translated": {"UnsupportedFeature", "Collision"},
	"Rendered":   {"SchemaMismatch", "MappingFailed", "RegisterUncovered"},
	"Validated":  {"YangValidationFailed", "SchemaMismatch"},
	"Applied":    {"TargetNotReady", "TransactionFailed", "OwnershipConflict"},
	"Ready":      {"NotConverged", "NotProgrammed", "RoutesMissing", "Deleting", "VerificationFailed"},
	"Degraded":   {"PartialFailure", "TelemetryUnavailable", "VerificationFailed", "StaleConfigurationPossible"},
	"Deleting":   {"RemovingConfiguration", "TargetUnreachable", "HolderPresent", "ForceReleased"},
}

func sorted(s []string) []string {
	out := append([]string(nil), s...)
	sort.Strings(out)
	return out
}

func TestConditionSetEqualsSection18(t *testing.T) {
	got := map[string][]string{}
	for _, s := range Table() {
		got[s.Type] = append(append([]string{}, s.Reasons...), s.UnknownReasons...)
	}
	if len(got) != len(section18) {
		t.Fatalf("condition types %v, want exactly %v", sorted(Types()), len(section18))
	}
	for typ, want := range section18 {
		if !slices.Equal(sorted(got[typ]), sorted(want)) {
			t.Errorf("%s reasons %v, want %v", typ, sorted(got[typ]), sorted(want))
		}
	}
	if _, ok := Spec("Allocated"); ok {
		t.Error("there is no Allocated condition")
	}
	// Only Ready carries an Unknown reason, and only VerificationFailed.
	for _, s := range Table() {
		if s.Type == Ready {
			if !slices.Equal(s.UnknownReasons, []string{ReasonVerificationFailed}) {
				t.Errorf("Ready unknown reasons %v", s.UnknownReasons)
			}
		} else if len(s.UnknownReasons) != 0 {
			t.Errorf("%s has unknown reasons %v", s.Type, s.UnknownReasons)
		}
	}
	// The nominal reason is not a §18 reason code.
	if slices.Contains(AllReasons(), ReasonAsExpected) {
		t.Error("AsExpected must not be one of §18's reason codes")
	}
}

// TestConditionSetMatchesAPIConstants: the api package's reason table agrees
// with §18 (reported, not edited, if it ever does not).
func TestConditionSetMatchesAPIConstants(t *testing.T) {
	api := fabricv1alpha1.ReasonsByCondition()
	if !slices.Equal(sorted(fabricv1alpha1.AllConditionTypes()), sorted(Types())) {
		t.Errorf("api condition types %v vs %v", fabricv1alpha1.AllConditionTypes(), Types())
	}
	for typ, want := range section18 {
		if !slices.Equal(sorted(api[typ]), sorted(want)) {
			t.Errorf("api %s reasons %v, §18 %v", typ, sorted(api[typ]), sorted(want))
		}
	}
}

// newObj is any object carrying ObjectMeta; the setters use only its
// generation, name and deletion timestamp.
func newObj(deleting bool) *corev1.ConfigMap {
	o := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: "svc", Namespace: "ns", Generation: 7}}
	if deleting {
		now := metav1.Now()
		o.DeletionTimestamp = &now
		o.Finalizers = []string{"fabric.agentic-netops.io/finalizer"}
	}
	return o
}

func setters(deleting bool) (*Conditions, *[]metav1.Condition, *record.FakeRecorder) {
	var conds []metav1.Condition
	rec := record.NewFakeRecorder(64)
	return For(newObj(deleting), &conds, rec), &conds, rec
}

func isRule(err error) bool {
	var re *RuleError
	return errors.As(err, &re)
}

func TestUnknownOnlyOnReadyWithVerificationFailed(t *testing.T) {
	c, _, _ := setters(false)
	for _, typ := range Types() {
		if typ == Ready {
			continue
		}
		for _, r := range append(AllReasons(), ReasonAsExpected) {
			if err := c.Set(typ, metav1.ConditionUnknown, r, "x"); !isRule(err) {
				t.Errorf("%s=Unknown/%s accepted", typ, r)
			}
		}
	}
	for _, r := range append(AllReasons(), ReasonAsExpected) {
		err := c.Set(Ready, metav1.ConditionUnknown, r, "leaf01 unreachable")
		if r == ReasonVerificationFailed {
			if err != nil {
				t.Errorf("Ready=Unknown/VerificationFailed refused: %v", err)
			}
		} else if !isRule(err) {
			t.Errorf("Ready=Unknown/%s accepted", r)
		}
	}
}

func TestReasonsOutsideSection18Refused(t *testing.T) {
	c, _, _ := setters(false)
	if err := c.Set("Allocated", metav1.ConditionFalse, "AllocationConflict", ""); !isRule(err) {
		t.Error("Allocated condition accepted")
	}
	if err := c.SetNotAccepted("SomethingElse", ""); !isRule(err) {
		t.Error("unknown Accepted reason accepted")
	}
	if err := c.SetNotApplied(ReasonRoutesMissing, ""); !isRule(err) {
		t.Error("a Ready reason accepted on Applied")
	}
	if err := c.Set(Accepted, metav1.ConditionTrue, ReasonInvalidIntent, ""); !isRule(err) {
		t.Error("Accepted=True with a failure reason accepted")
	}
	if err := c.SetDegraded(ReasonNotConverged, ""); !isRule(err) {
		t.Error("Degraded with a Ready reason accepted")
	}
	// Every §18 pair is accepted by its setter (on a live object, Deleting reasons aside).
	for _, s := range Table() {
		for _, r := range s.Reasons {
			if r == ReasonDeleting || s.Type == Deleting {
				continue
			}
			c2, _, _ := setters(false)
			if err := c2.failed(s.Type, r, "m"); err != nil {
				t.Errorf("%s/%s refused: %v", s.Type, r, err)
			}
		}
	}
}

// TestDeletingObjectOnlyReadyFalseDeleting: an object carrying a deletion
// timestamp can be given no other Ready status or reason (AD-53).
func TestDeletingObjectOnlyReadyFalseDeleting(t *testing.T) {
	c, conds, _ := setters(true)
	if err := c.SetReadyDeleting("finalization started"); err != nil {
		t.Fatal(err)
	}
	if err := c.SetDeletingCondition(ReasonTargetUnreachable, "leaf02"); err != nil {
		t.Fatal(err)
	}
	for _, try := range []struct {
		st     metav1.ConditionStatus
		reason string
	}{
		{metav1.ConditionTrue, ReasonAsExpected},
		{metav1.ConditionUnknown, ReasonVerificationFailed},
		{metav1.ConditionFalse, ReasonNotConverged},
		{metav1.ConditionFalse, ReasonNotProgrammed},
		{metav1.ConditionFalse, ReasonRoutesMissing},
	} {
		if err := c.Set(Ready, try.st, try.reason, "x"); !isRule(err) {
			t.Errorf("deleting object accepted Ready=%s/%s", try.st, try.reason)
		}
	}
	for _, fn := range []func() error{
		func() error { return c.SetReady("x") },
		func() error { return c.SetReadyUnknown("x") },
		func() error { return c.SetVerificationFailed("x") },
		func() error { return c.SetNotReady(ReasonRoutesMissing, "x") },
		func() error { return c.SetDegraded(ReasonVerificationFailed, "x") },
		func() error {
			var lv *metav1.Time
			return c.ApplyVerification(&lv, Verification{Ran: true}, time.Now())
		},
	} {
		if err := fn(); !isRule(err) {
			t.Errorf("deleting object accepted a write: %v", err)
		}
	}
	r := c.Get(Ready)
	if r == nil || r.Status != metav1.ConditionFalse || r.Reason != ReasonDeleting {
		t.Fatalf("Ready = %+v", r)
	}
	if len(*conds) != 2 {
		t.Errorf("conditions %+v", *conds)
	}
}

func TestReadyDeletingNeedsDeletionTimestamp(t *testing.T) {
	c, _, _ := setters(false)
	if err := c.SetReadyDeleting("x"); !isRule(err) {
		t.Error("Ready=False/Deleting accepted on a live object")
	}
	if err := c.SetDeletingCondition(ReasonRemovingConfiguration, "x"); !isRule(err) {
		t.Error("Deleting=True accepted on a live object")
	}
	if err := c.SetNotReady(ReasonDeleting, "x"); !isRule(err) {
		t.Error("SetNotReady took Deleting")
	}
}

func TestObservedGenerationAndEvents(t *testing.T) {
	c, conds, rec := setters(false)
	if err := c.SetNotApplied(ReasonTargetNotReady, "leaf01 not Ready"); err != nil {
		t.Fatal(err)
	}
	if (*conds)[0].ObservedGeneration != 7 {
		t.Errorf("observedGeneration %d", (*conds)[0].ObservedGeneration)
	}
	ev := <-rec.Events
	if !strings.HasPrefix(ev, "Warning TargetNotReady Applied=False") {
		t.Errorf("event %q", ev)
	}
	// An unchanged write emits nothing.
	_ = c.SetNotApplied(ReasonTargetNotReady, "leaf01 not Ready")
	select {
	case e := <-rec.Events:
		t.Errorf("unchanged write emitted %q", e)
	default:
	}
	_ = c.SetApplied("all confirmed")
	if ev := <-rec.Events; !strings.HasPrefix(ev, "Normal AsExpected Applied=True") {
		t.Errorf("event %q", ev)
	}
}

func TestPartialSuccessNeverAggregateReady(t *testing.T) {
	a := AggregateTargets([]TargetState{{"leaf01", PhaseReady}, {"leaf02", PhaseFailed}})
	if a.Ready || !a.PartialFailure || !slices.Equal(a.Failed, []string{"leaf02"}) {
		t.Fatalf("aggregate %+v", a)
	}
	a = AggregateTargets([]TargetState{{"leaf01", PhaseReady}, {"leaf02", PhaseUnreachable}})
	if a.Ready || !a.PartialFailure {
		t.Fatalf("aggregate %+v", a)
	}
	a = AggregateTargets([]TargetState{{"leaf01", PhaseReady}, {"leaf02", PhaseApplied}})
	if a.Ready || a.PartialFailure {
		t.Fatalf("converging aggregate %+v", a)
	}
	if a := AggregateTargets(nil); a.Ready {
		t.Fatal("no targets is not Ready")
	}
	if a := AggregateTargets([]TargetState{{"leaf01", PhaseReady}, {"leaf02", PhaseReady}}); !a.Ready {
		t.Fatalf("all Ready: %+v", a)
	}
	c, _, _ := setters(false)
	_ = c.SetReady("was ready")
	a = AggregateTargets([]TargetState{{"leaf01", PhaseReady}, {"leaf02", PhaseFailed}})
	if err := c.ApplyAggregate(a); err != nil {
		t.Fatal(err)
	}
	if r := c.Get(Ready); r.Status != metav1.ConditionFalse || r.Reason != ReasonNotConverged || !strings.Contains(r.Message, "leaf02") {
		t.Errorf("Ready %+v", r)
	}
	if d := c.Get(Degraded); d.Status != metav1.ConditionTrue || d.Reason != ReasonPartialFailure {
		t.Errorf("Degraded %+v", d)
	}
	// Ready=True cannot stand beside Degraded=True/PartialFailure.
	if err := c.SetReady("x"); !isRule(err) {
		t.Error("Ready=True accepted beside PartialFailure")
	}
}

func TestDegradedOrderAndCoexistence(t *testing.T) {
	if r, _ := SelectDegradedReason(ReasonTelemetryUnavailable, ReasonStaleConfigurationPossible, ReasonVerificationFailed); r != ReasonVerificationFailed {
		t.Errorf("got %s", r)
	}
	if r, _ := SelectDegradedReason(ReasonTelemetryUnavailable, ReasonStaleConfigurationPossible); r != ReasonStaleConfigurationPossible {
		t.Errorf("got %s", r)
	}
	if _, ok := SelectDegradedReason(); ok {
		t.Error("no impairment selected a reason")
	}
	c, _, _ := setters(false)
	_ = c.SetReady("ok")
	if err := c.SetDegraded(ReasonTelemetryUnavailable, "collector down"); err != nil {
		t.Errorf("TelemetryUnavailable beside Ready=True refused: %v", err)
	}
	if err := c.SetDegraded(ReasonVerificationFailed, "x"); !isRule(err) {
		t.Error("VerificationFailed accepted beside Ready=True")
	}
}

// TestLastVerifiedTimeOnlyForAPassThatRan (AD-54).
func TestLastVerifiedTimeOnlyForAPassThatRan(t *testing.T) {
	t0 := time.Date(2026, 9, 21, 10, 0, 0, 0, time.UTC)
	prev := metav1.NewTime(t0)

	// A pass that could not run writes nothing, and sets Ready=Unknown +
	// Degraded=True, both VerificationFailed.
	c, _, _ := setters(false)
	_ = c.SetReady("was ready")
	last := &prev
	if err := c.ApplyVerification(&last, Verification{Ran: false, Unreachable: []string{"leaf02"}}, t0.Add(5*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if !last.Equal(&prev) {
		t.Errorf("a pass that could not run advanced lastVerifiedTime to %v", last)
	}
	r, d := c.Get(Ready), c.Get(Degraded)
	if r.Status != metav1.ConditionUnknown || r.Reason != ReasonVerificationFailed || !strings.Contains(r.Message, "leaf02") ||
		d.Status != metav1.ConditionTrue || d.Reason != ReasonVerificationFailed {
		t.Errorf("Ready %+v Degraded %+v", r, d)
	}
	if RecordVerification(&last, Verification{Ran: false}, t0.Add(time.Hour)) || !last.Equal(&prev) {
		t.Error("RecordVerification wrote for a pass that did not run")
	}

	// A pass that ran and found an invariant missing writes it, and sets
	// Ready=False naming the invariant.
	t1 := t0.Add(10 * time.Minute)
	if err := c.ApplyVerification(&last, Verification{Ran: true, MissingReason: ReasonRoutesMissing,
		Missing: "type-2 routes for vni 10021 absent on leaf02"}, t1); err != nil {
		t.Fatal(err)
	}
	if last == nil || !last.Time.Equal(t1) {
		t.Errorf("a pass that ran with a missing invariant did not write lastVerifiedTime: %v", last)
	}
	if r := c.Get(Ready); r.Status != metav1.ConditionFalse || r.Reason != ReasonRoutesMissing {
		t.Errorf("Ready %+v", r)
	}
	if d := c.Get(Degraded); d.Status != metav1.ConditionFalse {
		t.Errorf("Degraded not cleared by a pass that ran: %+v", d)
	}

	// A clean pass writes it and returns Ready=True.
	t2 := t1.Add(5 * time.Minute)
	if err := c.ApplyVerification(&last, Verification{Ran: true}, t2); err != nil {
		t.Fatal(err)
	}
	if !last.Time.Equal(t2) || c.Get(Ready).Status != metav1.ConditionTrue {
		t.Errorf("clean pass: last=%v ready=%+v", last, c.Get(Ready))
	}
}
