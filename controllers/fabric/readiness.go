package fabric

import (
	"context"
	"fmt"
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
	// readyUnknown is Ready=Unknown/VerificationFailed: a read-back that
	// could not run on an object that had reported Ready (AD-40).
	readyUnknown
)

type readyOutcome struct {
	kind   readyKind
	reason string
	msg    string
}

// hadReportedReady is "had reported Ready at the current generation" (AD-62):
// Ready True, or Unknown (a pass that could not run after a Ready), stamped
// with the object's current generation. An object updated to a new generation
// is converging again, never Unknown.
func hadReportedReady(f *fabricv1.Fabric) bool {
	c := meta.FindStatusCondition(f.Status.Conditions, status.Ready)
	return c != nil && c.ObservedGeneration == f.Generation &&
		(c.Status == metav1.ConditionTrue || c.Status == metav1.ConditionUnknown)
}

func readyStatus(f *fabricv1.Fabric) metav1.ConditionStatus {
	if c := meta.FindStatusCondition(f.Status.Conditions, status.Ready); c != nil {
		return c.Status
	}
	return ""
}

// countingFindings are the open findings that count toward Degraded: those
// whose node is in spec.nodes. A finding whose node left spec.nodes stays in
// status.findings[] as the record and does not count until the node returns
// (AD-71).
func countingFindings(f *fabricv1.Fabric) []fabricv1.Finding {
	nodes := map[string]bool{}
	for _, n := range f.Spec.Nodes {
		nodes[string(n.Name)] = true
	}
	var out []fabricv1.Finding
	for _, fd := range f.Status.Findings {
		if nodes[fd.Node] {
			out = append(out, fd)
		}
	}
	return out
}

// writeReady writes Ready and the one Degraded condition together, through
// internal/status (T023's setters), with the Degraded reason chosen by
// status.SelectDegradedReason in §18's total order: PartialFailure (beside
// Ready=False) > VerificationFailed (beside Ready=Unknown) >
// StaleConfigurationPossible > TelemetryUnavailable (only when the telemetry
// input is the one thing impaired, changing no other condition). The writes
// are ordered so that Ready=True never stands beside a Degraded reason that
// cannot coexist with it.
func (p *pass) writeReady(out readyOutcome) error {
	f, c := p.f, p.conds
	final := out
	if out.kind == readyLeave {
		switch cur := meta.FindStatusCondition(f.Status.Conditions, status.Ready); {
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

	impaired := []string{}
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
	if open := countingFindings(f); len(open) > 0 && final.kind != readyUnknown {
		cur := meta.FindStatusCondition(f.Status.Conditions, status.Degraded)
		standing := cur != nil && cur.Status == metav1.ConditionTrue && cur.Reason == status.ReasonStaleConfigurationPossible
		if p.passRan || standing {
			var names []string
			for _, fd := range open {
				names = append(names, fmt.Sprintf("service %s/%s on %s", fd.Service.Namespace, fd.Service.Name, fd.Node))
			}
			add(status.ReasonStaleConfigurationPossible, "open force-release finding(s): the device may still carry stale configuration of "+strings.Join(names, "; "))
		}
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
