package network

import (
	"context"
	"sort"
	"strings"

	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/status"
)

type readyKind int

const (
	// readyLeave keeps Ready as it is (no read-back ran in this reconcile).
	readyLeave readyKind = iota
	readyTrue
	readyFalse
	// readyUnknown is Ready=Unknown/VerificationFailed: a read-back that could not run on an
	// object that had reported Ready at its current generation (AD-40).
	readyUnknown
)

type readyOutcome struct {
	kind   readyKind
	reason string
	msg    string
}

// HadReportedReady is "had reported Ready at the current generation" (data-model.md §18,
// AD-62): Ready True, or Unknown (a pass that could not run after a Ready), stamped with the
// object's current generation. A Network updated to a new generation is converging again —
// Ready=False/NotConverged with Applied=False/TargetNotReady while a target is away — never
// Unknown.
func HadReportedReady(n *fabricv1.Network) bool {
	c := meta.FindStatusCondition(n.Status.Conditions, status.Ready)
	return c != nil && c.ObservedGeneration == n.Generation &&
		(c.Status == metav1.ConditionTrue || c.Status == metav1.ConditionUnknown)
}

func readyStatus(n *fabricv1.Network) metav1.ConditionStatus {
	if c := meta.FindStatusCondition(n.Status.Conditions, status.Ready); c != nil {
		return c.Status
	}
	return ""
}

// writeReady writes Ready and the one Degraded condition together through internal/status
// (T023's setters), the Degraded reason chosen by status.SelectDegradedReason in §18's total
// order: PartialFailure (from the per-target aggregation, beside Ready=False) >
// VerificationFailed (beside Ready=Unknown) > TelemetryUnavailable (from the telemetry-health
// input alone, only when nothing else is impaired, changing no other condition). The writes
// are ordered so that Ready=True never stands beside a Degraded reason that cannot coexist
// with it.
func (p *pass) writeReady(out readyOutcome) error {
	n, c := p.n, p.conds
	final := out
	if out.kind == readyLeave {
		switch cur := meta.FindStatusCondition(n.Status.Conditions, status.Ready); {
		case cur == nil:
			final = readyOutcome{kind: readyLeave}
		case cur.Status == metav1.ConditionUnknown:
			final = readyOutcome{kind: readyUnknown, msg: cur.Message}
		case cur.Status == metav1.ConditionTrue:
			final = readyOutcome{kind: readyTrue, msg: cur.Message}
		default:
			final = readyOutcome{kind: readyFalse, reason: cur.Reason, msg: cur.Message}
		}
	}

	var impaired []string
	msgs := map[string]string{}
	add := func(reason, msg string) {
		impaired = append(impaired, reason)
		msgs[reason] = msg
	}
	otherImpairment := len(p.targetsBad) > 0
	if a := p.partial; a != nil {
		bad := append(append([]string{}, a.Failed...), a.Unreachable...)
		sort.Strings(bad)
		if a.PartialFailure {
			add(status.ReasonPartialFailure, "partial success is never aggregate Ready; failed or unreachable: "+strings.Join(bad, ", "))
		}
		if len(bad) > 0 {
			otherImpairment = true
		}
	}
	if final.kind == readyUnknown {
		add(status.ReasonVerificationFailed, final.msg)
	}
	if p.r.Telemetry != nil && !otherImpairment {
		if ok, detail := p.r.Telemetry.TelemetryHealthy(context.Background()); !ok {
			add(status.ReasonTelemetryUnavailable, "telemetry dependency impaired (configuration unaffected): "+detail)
		}
	}
	reason, degraded := status.SelectDegradedReason(impaired...)

	setDegraded := func() error {
		switch {
		case degraded:
			return c.SetDegraded(reason, msgs[reason])
		case otherImpairment:
			return nil // an impairment with no Degraded reason of its own: leave the condition
		default:
			return c.ClearDegraded("no required target or telemetry dependency impaired")
		}
	}
	setReady := func() error {
		switch out.kind {
		case readyTrue:
			return c.SetReady(out.msg)
		case readyFalse:
			return c.SetNotReady(out.reason, out.msg)
		case readyUnknown:
			return c.SetReadyUnknown(out.msg)
		}
		return nil
	}
	if final.kind == readyTrue {
		if err := setDegraded(); err != nil {
			return err
		}
		return setReady()
	}
	if err := setReady(); err != nil {
		return err
	}
	return setDegraded()
}
