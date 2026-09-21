package status

import (
	"sort"
	"strings"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Phase is the phase of one required target (mirrors the per-target phase of
// the Fabric and Network status).
type Phase string

const (
	PhasePending     Phase = "Pending"
	PhaseRendered    Phase = "Rendered"
	PhaseValidated   Phase = "Validated"
	PhaseApplied     Phase = "Applied"
	PhaseReady       Phase = "Ready"
	PhaseFailed      Phase = "Failed"
	PhaseRemoving    Phase = "Removing"
	PhaseUnreachable Phase = "Unreachable"
)

// TargetState is one required target's phase.
type TargetState struct {
	Target string
	Phase  Phase
}

// Aggregate is the per-target phases folded into one object-level answer.
type Aggregate struct {
	// Ready is true only when there is at least one target and every one is Ready.
	Ready bool
	// PartialFailure is true when some target failed or is unreachable while
	// another progressed: never aggregate Ready (FR-018).
	PartialFailure bool
	// NotReady, Failed and Unreachable name the targets in each state, sorted.
	NotReady    []string
	Failed      []string
	Unreachable []string
}

// AggregateTargets folds per-target phases. Partial success is never Ready.
func AggregateTargets(ts []TargetState) Aggregate {
	var a Aggregate
	progressed := 0
	for _, t := range ts {
		switch t.Phase {
		case PhaseReady:
			progressed++
			continue
		case PhaseFailed:
			a.Failed = append(a.Failed, t.Target)
		case PhaseUnreachable:
			a.Unreachable = append(a.Unreachable, t.Target)
		case PhaseApplied, PhaseValidated, PhaseRendered:
			progressed++
		}
		a.NotReady = append(a.NotReady, t.Target)
	}
	sort.Strings(a.NotReady)
	sort.Strings(a.Failed)
	sort.Strings(a.Unreachable)
	a.Ready = len(ts) > 0 && len(a.NotReady) == 0
	a.PartialFailure = len(a.Failed)+len(a.Unreachable) > 0 && progressed > 0
	return a
}

// ApplyAggregate writes the aggregate's Ready and Degraded: Ready=False/
// NotConverged naming the targets not Ready (and Degraded=True/PartialFailure
// when partial) unless every target is Ready. It never sets Ready=True: that
// needs the two-sided read-back as well (FR-100) — see ApplyVerification.
func (c *Conditions) ApplyAggregate(a Aggregate) error {
	if a.Ready {
		return nil
	}
	msg := "targets not Ready: " + strings.Join(a.NotReady, ", ")
	if len(a.NotReady) == 0 {
		msg = "no required target"
	}
	if err := c.SetNotReady(ReasonNotConverged, msg); err != nil {
		return err
	}
	if a.PartialFailure {
		bad := append(append([]string{}, a.Failed...), a.Unreachable...)
		sort.Strings(bad)
		return c.SetDegraded(ReasonPartialFailure, "failed or unreachable: "+strings.Join(bad, ", "))
	}
	return nil
}

// Verification is the outcome of one re-verification pass.
type Verification struct {
	// Ran is true when the pass completed its read-back on both sides, whatever
	// it found. False when a required target was unreachable or the read timed
	// out — the pass could not run.
	Ran bool
	// Unreachable names the targets that stopped the pass when Ran is false.
	Unreachable []string
	// MissingReason and Missing name the missing invariant when the pass ran
	// and found one (NotProgrammed or RoutesMissing, or NotConverged).
	MissingReason string
	Missing       string
}

// RecordVerification advances *lastVerified to now only for a pass that ran
// (AD-54). It returns whether it wrote.
func RecordVerification(lastVerified **metav1.Time, v Verification, now time.Time) bool {
	if !v.Ran {
		return false
	}
	t := metav1.NewTime(now)
	*lastVerified = &t
	return true
}

// ApplyVerification writes a re-verification pass: a pass that could not run
// sets Ready=Unknown and Degraded=True, both VerificationFailed naming the
// targets, and leaves lastVerifiedTime; a pass that ran advances
// lastVerifiedTime and sets Ready=True, or Ready=False naming the missing
// invariant. No read-back is run on a deleting object (AD-53), so one is refused.
func (c *Conditions) ApplyVerification(lastVerified **metav1.Time, v Verification, now time.Time) error {
	if c.deleting() {
		return refuse("object %s is being deleted: no read-back is run on it (AD-53)", c.obj.GetName())
	}
	if !v.Ran {
		targets := append([]string{}, v.Unreachable...)
		sort.Strings(targets)
		return c.SetVerificationFailed("read-back could not run against: " + strings.Join(targets, ", "))
	}
	RecordVerification(lastVerified, v, now)
	if v.MissingReason != "" {
		if err := c.SetNotReady(v.MissingReason, v.Missing); err != nil {
			return err
		}
	}
	// The pass ran, so a VerificationFailed Degraded is settled; it is cleared
	// before Ready is raised, which it could not stand beside.
	if d := c.Get(Degraded); d != nil && d.Status == metav1.ConditionTrue && d.Reason == ReasonVerificationFailed {
		if err := c.ClearDegraded("read-back ran"); err != nil {
			return err
		}
	}
	if v.MissingReason != "" {
		return nil
	}
	return c.SetReady("read-back passed on both sides")
}
