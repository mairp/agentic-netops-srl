package status

import (
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
)

// Object is what the setters need of the object whose status they write.
type Object interface {
	metav1.Object
	runtime.Object
}

// Conditions writes the conditions of one object through the §18 rules.
type Conditions struct {
	obj   Object
	conds *[]metav1.Condition
	rec   record.EventRecorder
	now   func() time.Time
}

// For returns the setters over conds, the condition list of obj's status.
// With a non-nil recorder, every condition transition emits an Event.
func For(obj Object, conds *[]metav1.Condition, rec record.EventRecorder) *Conditions {
	return &Conditions{obj: obj, conds: conds, rec: rec, now: time.Now}
}

// WithNow sets the clock that stamps lastTransitionTime (an injected clock in
// the reconcilers and their tests). It returns c.
func (c *Conditions) WithNow(now func() time.Time) *Conditions {
	if now != nil {
		c.now = now
	}
	return c
}

// RuleError is a refused condition write.
type RuleError struct{ Msg string }

func (e *RuleError) Error() string { return "status: " + e.Msg }

func refuse(format string, a ...any) error { return &RuleError{Msg: fmt.Sprintf(format, a...)} }

func (c *Conditions) deleting() bool { return c.obj.GetDeletionTimestamp() != nil }

// Get returns the current condition of typ, or nil.
func (c *Conditions) Get(typ string) *metav1.Condition {
	return meta.FindStatusCondition(*c.conds, typ)
}

// Validate checks one condition write against §18 and the object's state
// without writing it.
func (c *Conditions) Validate(typ string, st metav1.ConditionStatus, reason string) error {
	spec, ok := Spec(typ)
	if !ok {
		return refuse("condition type %q is not defined by data-model.md §18", typ)
	}
	switch st {
	case metav1.ConditionUnknown:
		if len(spec.UnknownReasons) == 0 {
			return refuse("%s cannot be Unknown: Ready is the only condition with three states (AD-40)", typ)
		}
		if !contains(spec.UnknownReasons, reason) {
			return refuse("%s=Unknown takes only reason %v, not %q (AD-40)", typ, spec.UnknownReasons, reason)
		}
	case metav1.ConditionTrue, metav1.ConditionFalse:
		reasonStatus := metav1.ConditionFalse
		if spec.Polarity == TrueReasons {
			reasonStatus = metav1.ConditionTrue
		}
		if st == reasonStatus {
			if !contains(spec.Reasons, reason) {
				return refuse("%s=%s takes a reason of %v, not %q (data-model.md §18)", typ, st, spec.Reasons, reason)
			}
		} else if reason != ReasonAsExpected {
			return refuse("%s=%s is the nominal state and takes reason %q, not %q", typ, st, ReasonAsExpected, reason)
		}
	default:
		return refuse("condition status %q", st)
	}
	// Deletion (AD-53): Ready is False/Deleting and nothing else; no
	// VerificationFailed anywhere on a deleting object.
	if c.deleting() {
		if typ == Ready && (st != metav1.ConditionFalse || reason != ReasonDeleting) {
			return refuse("object %s is being deleted: Ready is False/Deleting only, not %s/%s (AD-53)", c.obj.GetName(), st, reason)
		}
		if reason == ReasonVerificationFailed {
			return refuse("object %s is being deleted: VerificationFailed is never set on it (AD-53)", c.obj.GetName())
		}
	} else {
		if typ == Ready && reason == ReasonDeleting {
			return refuse("Ready=False/Deleting needs a deletion timestamp on %s", c.obj.GetName())
		}
		if typ == Deleting && st == metav1.ConditionTrue {
			return refuse("Deleting=True needs a deletion timestamp on %s", c.obj.GetName())
		}
	}
	// Degraded may stand beside Ready=True only for the closed list (§18).
	if typ == Ready && st == metav1.ConditionTrue {
		if d := c.Get(Degraded); d != nil && d.Status == metav1.ConditionTrue && !CoexistsWithReady(d.Reason) {
			return refuse("Ready=True cannot stand beside Degraded=True/%s (§18)", d.Reason)
		}
	}
	if typ == Degraded && st == metav1.ConditionTrue && !CoexistsWithReady(reason) {
		if r := c.Get(Ready); r != nil && r.Status == metav1.ConditionTrue {
			return refuse("Degraded=True/%s cannot stand beside Ready=True (§18); set Ready first", reason)
		}
	}
	return nil
}

// Set writes one condition after Validate, stamping observedGeneration, and
// emits an Event when the condition changed.
func (c *Conditions) Set(typ string, st metav1.ConditionStatus, reason, message string) error {
	if err := c.Validate(typ, st, reason); err != nil {
		return err
	}
	changed := meta.SetStatusCondition(c.conds, metav1.Condition{
		Type:               typ,
		Status:             st,
		Reason:             reason,
		Message:            message,
		ObservedGeneration: c.obj.GetGeneration(),
		LastTransitionTime: metav1.NewTime(c.now()),
	})
	if changed {
		c.emit(typ, st, reason, message)
	}
	return nil
}

// EventType is the Event type of a condition write: Normal for a nominal
// state or an in-progress deletion, Warning otherwise.
func EventType(typ string, st metav1.ConditionStatus, reason string) string {
	switch {
	case reason == ReasonAsExpected:
		return corev1.EventTypeNormal
	case typ == Deleting && reason == ReasonRemovingConfiguration, typ == Ready && reason == ReasonDeleting:
		return corev1.EventTypeNormal
	}
	return corev1.EventTypeWarning
}

func (c *Conditions) emit(typ string, st metav1.ConditionStatus, reason, message string) {
	if c.rec == nil {
		return
	}
	c.rec.Eventf(c.obj, EventType(typ, st, reason), reason, "%s=%s: %s", typ, st, message)
}

// ---------------------------------------------------------------------------
// Typed setters.
// ---------------------------------------------------------------------------

func (c *Conditions) nominal(typ, msg string) error {
	spec, _ := Spec(typ)
	st := metav1.ConditionTrue
	if spec.Polarity == TrueReasons {
		st = metav1.ConditionFalse
	}
	return c.Set(typ, st, ReasonAsExpected, msg)
}

func (c *Conditions) failed(typ, reason, msg string) error {
	spec, _ := Spec(typ)
	st := metav1.ConditionFalse
	if spec.Polarity == TrueReasons {
		st = metav1.ConditionTrue
	}
	return c.Set(typ, st, reason, msg)
}

func (c *Conditions) SetAccepted(msg string) error            { return c.nominal(Accepted, msg) }
func (c *Conditions) SetNotAccepted(reason, msg string) error { return c.failed(Accepted, reason, msg) }
func (c *Conditions) SetRendered(msg string) error            { return c.nominal(Rendered, msg) }
func (c *Conditions) SetNotRendered(reason, msg string) error { return c.failed(Rendered, reason, msg) }
func (c *Conditions) SetValidated(msg string) error           { return c.nominal(Validated, msg) }
func (c *Conditions) SetNotValidated(reason, msg string) error {
	return c.failed(Validated, reason, msg)
}
func (c *Conditions) SetApplied(msg string) error            { return c.nominal(Applied, msg) }
func (c *Conditions) SetNotApplied(reason, msg string) error { return c.failed(Applied, reason, msg) }
func (c *Conditions) SetReady(msg string) error              { return c.nominal(Ready, msg) }
func (c *Conditions) SetDegraded(reason, msg string) error   { return c.failed(Degraded, reason, msg) }
func (c *Conditions) ClearDegraded(msg string) error         { return c.nominal(Degraded, msg) }
func (c *Conditions) SetDeletingCondition(reason, msg string) error {
	return c.failed(Deleting, reason, msg)
}

// SetTranslated / SetNotTranslated are for the MigrationPlan controller (T122)
// only; the provider never sets Translated on a Fabric or a Network.
func (c *Conditions) SetTranslated(msg string) error { return c.nominal(Translated, msg) }
func (c *Conditions) SetNotTranslated(reason, msg string) error {
	return c.failed(Translated, reason, msg)
}

// SetNotReady sets Ready=False with one of NotConverged, NotProgrammed,
// RoutesMissing; the message names the missing invariant. Deleting has its own
// setter, SetReadyDeleting.
func (c *Conditions) SetNotReady(reason, msg string) error {
	if reason == ReasonDeleting {
		return refuse("use SetReadyDeleting for Ready=False/Deleting")
	}
	return c.failed(Ready, reason, msg)
}

// SetReadyDeleting sets Ready=False/Deleting — the finalization path's first
// act, kept until the object is gone (AD-53).
func (c *Conditions) SetReadyDeleting(msg string) error {
	return c.Set(Ready, metav1.ConditionFalse, ReasonDeleting, msg)
}

// SetReadyUnknown is the one setter that takes Unknown: Ready=Unknown with
// VerificationFailed, the message naming the target.
func (c *Conditions) SetReadyUnknown(msg string) error {
	return c.Set(Ready, metav1.ConditionUnknown, ReasonVerificationFailed, msg)
}

// SetVerificationFailed is what a re-verification that could not run sets, at
// that pass: Ready=Unknown and Degraded=True, both VerificationFailed, both
// naming the target (§18).
func (c *Conditions) SetVerificationFailed(msg string) error {
	if err := c.SetReadyUnknown(msg); err != nil {
		return err
	}
	return c.SetDegraded(ReasonVerificationFailed, msg)
}
