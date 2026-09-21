// Package status holds the shared status helpers of the provider (T023):
// the closed condition and reason-code set of data-model.md §18 as data, the
// condition setters that refuse anything outside it, Event emission, the
// per-target phase aggregation and the lastVerifiedTime writer.
//
// The rules enforced here, not left to callers:
//   - a condition type or reason §18 does not define cannot be set;
//   - there is no Allocated condition;
//   - Ready is the one condition that takes Unknown, and only with
//     VerificationFailed (AD-40);
//   - an object carrying a deletion timestamp can be given no Ready status or
//     reason other than False/Deleting, and VerificationFailed is never set on
//     it (AD-53);
//   - Ready=False/Deleting is set only on an object carrying a deletion
//     timestamp;
//   - partial success is never aggregate Ready (FR-018);
//   - lastVerifiedTime is written only by a re-verification pass that ran
//     (AD-54).
package status

import "sort"

// Condition types (data-model.md §18). There is no Allocated condition.
const (
	Accepted   = "Accepted"
	Translated = "Translated" // MigrationPlan only (T122); never on a Fabric or a Network
	Rendered   = "Rendered"
	Validated  = "Validated"
	Applied    = "Applied"
	Ready      = "Ready"
	Degraded   = "Degraded"
	Deleting   = "Deleting"
)

// Reason codes (data-model.md §18).
const (
	// Accepted=False
	ReasonInvalidIntent      = "InvalidIntent"
	ReasonReferenceNotFound  = "ReferenceNotFound"
	ReasonUnqualified        = "Unqualified"
	ReasonAllocationConflict = "AllocationConflict"
	// Translated=False
	ReasonUnsupportedFeature = "UnsupportedFeature"
	ReasonCollision          = "Collision"
	// Rendered=False (SchemaMismatch shared with Validated)
	ReasonSchemaMismatch    = "SchemaMismatch"
	ReasonMappingFailed     = "MappingFailed"
	ReasonRegisterUncovered = "RegisterUncovered"
	// Validated=False
	ReasonYangValidationFailed = "YangValidationFailed"
	// Applied=False
	ReasonTargetNotReady    = "TargetNotReady"
	ReasonTransactionFailed = "TransactionFailed"
	ReasonOwnershipConflict = "OwnershipConflict"
	// Ready=False
	ReasonNotConverged  = "NotConverged"
	ReasonNotProgrammed = "NotProgrammed"
	ReasonRoutesMissing = "RoutesMissing"
	ReasonDeleting      = "Deleting"
	// Ready=Unknown (the only one) and Degraded=True
	ReasonVerificationFailed = "VerificationFailed"
	// Degraded=True
	ReasonPartialFailure             = "PartialFailure"
	ReasonTelemetryUnavailable       = "TelemetryUnavailable"
	ReasonStaleConfigurationPossible = "StaleConfigurationPossible" // Fabric only
	// Deleting=True
	ReasonRemovingConfiguration = "RemovingConfiguration"
	ReasonTargetUnreachable     = "TargetUnreachable"
	ReasonHolderPresent         = "HolderPresent"
	ReasonForceReleased         = "ForceReleased"
)

// ReasonAsExpected is the reason of a condition in its nominal state
// (Accepted..Ready True, Degraded False). §18 lists no reason for the nominal
// state, and metav1.Condition requires one; this single constant is used for
// all of them and is not one of §18's reason codes.
const ReasonAsExpected = "AsExpected"

// Polarity says which status a condition's §18 reason codes accompany.
type Polarity string

const (
	// FalseReasons: the reason codes accompany status False; True is nominal.
	FalseReasons Polarity = "False"
	// TrueReasons: the reason codes accompany status True (Degraded, Deleting);
	// False is nominal.
	TrueReasons Polarity = "True"
)

// ConditionSpec is one row of data-model.md §18.
type ConditionSpec struct {
	Type     string
	Polarity Polarity
	// Reasons are the §18 reason codes for the non-nominal status.
	Reasons []string
	// UnknownReasons are the reasons allowed with status Unknown; empty for
	// every condition except Ready.
	UnknownReasons []string
}

// Table is data-model.md §18 as data, in the table's order.
func Table() []ConditionSpec {
	return []ConditionSpec{
		{Type: Accepted, Polarity: FalseReasons, Reasons: []string{ReasonInvalidIntent, ReasonReferenceNotFound, ReasonUnqualified, ReasonAllocationConflict}},
		{Type: Translated, Polarity: FalseReasons, Reasons: []string{ReasonUnsupportedFeature, ReasonCollision}},
		{Type: Rendered, Polarity: FalseReasons, Reasons: []string{ReasonSchemaMismatch, ReasonMappingFailed, ReasonRegisterUncovered}},
		{Type: Validated, Polarity: FalseReasons, Reasons: []string{ReasonYangValidationFailed, ReasonSchemaMismatch}},
		{Type: Applied, Polarity: FalseReasons, Reasons: []string{ReasonTargetNotReady, ReasonTransactionFailed, ReasonOwnershipConflict}},
		{Type: Ready, Polarity: FalseReasons, Reasons: []string{ReasonNotConverged, ReasonNotProgrammed, ReasonRoutesMissing, ReasonDeleting},
			UnknownReasons: []string{ReasonVerificationFailed}},
		{Type: Degraded, Polarity: TrueReasons, Reasons: []string{ReasonPartialFailure, ReasonTelemetryUnavailable, ReasonVerificationFailed, ReasonStaleConfigurationPossible}},
		{Type: Deleting, Polarity: TrueReasons, Reasons: []string{ReasonRemovingConfiguration, ReasonTargetUnreachable, ReasonHolderPresent, ReasonForceReleased}},
	}
}

// Spec returns the §18 row of typ.
func Spec(typ string) (ConditionSpec, bool) {
	for _, s := range Table() {
		if s.Type == typ {
			return s, true
		}
	}
	return ConditionSpec{}, false
}

// Types returns every condition type of §18.
func Types() []string {
	var out []string
	for _, s := range Table() {
		out = append(out, s.Type)
	}
	return out
}

// AllReasons returns every §18 reason code, sorted and de-duplicated.
func AllReasons() []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range Table() {
		for _, r := range append(append([]string{}, s.Reasons...), s.UnknownReasons...) {
			if !seen[r] {
				seen[r] = true
				out = append(out, r)
			}
		}
	}
	sort.Strings(out)
	return out
}

// DegradedOrder is the total order of Degraded reasons, highest first
// (§18, AD-54, AD-62).
func DegradedOrder() []string {
	return []string{ReasonPartialFailure, ReasonVerificationFailed, ReasonStaleConfigurationPossible, ReasonTelemetryUnavailable}
}

// SelectDegradedReason returns the one Degraded reason for the given
// impairments, by DegradedOrder; ok is false when there are none.
func SelectDegradedReason(impaired ...string) (reason string, ok bool) {
	has := map[string]bool{}
	for _, r := range impaired {
		has[r] = true
	}
	for _, r := range DegradedOrder() {
		if has[r] {
			return r, true
		}
	}
	return "", false
}

// CoexistsWithReady is the closed list of Degraded=True reasons that may stand
// beside Ready=True.
func CoexistsWithReady(reason string) bool {
	return reason == ReasonTelemetryUnavailable || reason == ReasonStaleConfigurationPossible
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}
