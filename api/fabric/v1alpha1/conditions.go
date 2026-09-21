package v1alpha1

// Standard conditions and the closed reason-code set (data-model.md §18).
//
// Every platform-owned status uses Kubernetes conditions with type, status, reason, message,
// observedGeneration and lastTransitionTime. Messages may aid humans; automation keys on the
// reason codes below, which are a closed set: a reason not listed for a condition here is a
// defect, never an extension.

// Condition types.
const (
	// ConditionAccepted is True when schema and references are valid and every requested
	// construct and property is qualified.
	ConditionAccepted = "Accepted"
	// ConditionTranslated is True when a complete, non-lossy mapping exists. MigrationPlan
	// only: the provider never sets it on a Fabric or a Network.
	ConditionTranslated = "Translated"
	// ConditionRendered is True when the provider emitted deterministic configuration for
	// every affected node.
	ConditionRendered = "Rendered"
	// ConditionValidated is True when every rendered path passed the pinned device schema.
	ConditionValidated = "Validated"
	// ConditionApplied is True when every required device transaction was confirmed.
	ConditionApplied = "Applied"
	// ConditionReady is True when applied state and both sides of the read-back pass
	// (FR-100). It is the one condition with three states: Unknown, with the reason
	// VerificationFailed and no other, when the read-back of an object that had reported
	// Ready at the current generation could not run (FR-107, AD-40).
	ConditionReady = "Ready"
	// ConditionDegraded is True when any required target or telemetry dependency is
	// impaired. One Degraded condition carries one reason (DegradedReasonOrder).
	ConditionDegraded = "Degraded"
	// ConditionDeleting is True while the object carries a deletion timestamp and
	// finalization has not finished. Its polarity is deliberate: True while work remains,
	// the reason saying what is outstanding.
	ConditionDeleting = "Deleting"
)

// Accepted=False reasons.
const (
	ReasonInvalidIntent     = "InvalidIntent"
	ReasonReferenceNotFound = "ReferenceNotFound"
	ReasonUnqualified       = "Unqualified"
	// ReasonAllocationConflict is an answer, never an error: a VNI the authority refused
	// (held by another owner, or outside the allocation band), or a VLAN in 1000–4000 that
	// no adoptable claim backs. An authority that errors is a dependency wait (AD-56).
	ReasonAllocationConflict = "AllocationConflict"
)

// Translated=False reasons (MigrationPlan only).
const (
	ReasonUnsupportedFeature = "UnsupportedFeature"
	ReasonCollision          = "Collision"
)

// Rendered=False reasons (ReasonSchemaMismatch is shared with Validated).
const (
	ReasonSchemaMismatch    = "SchemaMismatch"
	ReasonMappingFailed     = "MappingFailed"
	ReasonRegisterUncovered = "RegisterUncovered"
)

// Validated=False reasons (plus ReasonSchemaMismatch).
const (
	ReasonYangValidationFailed = "YangValidationFailed"
)

// Applied=False reasons.
const (
	ReasonTargetNotReady    = "TargetNotReady"
	ReasonTransactionFailed = "TransactionFailed"
	ReasonOwnershipConflict = "OwnershipConflict"
)

// Ready=False reasons, and the one Ready=Unknown reason.
const (
	ReasonNotConverged  = "NotConverged"
	ReasonNotProgrammed = "NotProgrammed"
	ReasonRoutesMissing = "RoutesMissing"
	// ReasonDeleting is the Ready=False reason of an object being removed (AD-53); not to
	// be confused with the Deleting condition, which it always accompanies.
	ReasonDeleting = "Deleting"
	// ReasonVerificationFailed is the only reason Ready=Unknown ever carries; it is also a
	// Degraded=True reason, set at the same pass.
	ReasonVerificationFailed = "VerificationFailed"
)

// Degraded=True reasons (plus ReasonVerificationFailed).
const (
	ReasonPartialFailure       = "PartialFailure"
	ReasonTelemetryUnavailable = "TelemetryUnavailable"
	// ReasonStaleConfigurationPossible is set on the Fabric only, for an open force-release
	// finding (FR-103).
	ReasonStaleConfigurationPossible = "StaleConfigurationPossible"
)

// Deleting=True reasons.
const (
	ReasonRemovingConfiguration = "RemovingConfiguration"
	ReasonTargetUnreachable     = "TargetUnreachable"
	ReasonHolderPresent         = "HolderPresent"
	ReasonForceReleased         = "ForceReleased"
)

// ConditionPolarity says which status value a condition's closed reasons accompany.
type ConditionPolarity string

const (
	// PolarityFalseReasons: the listed reasons accompany status False.
	PolarityFalseReasons ConditionPolarity = "False"
	// PolarityTrueReasons: the listed reasons accompany status True (Degraded, Deleting).
	PolarityTrueReasons ConditionPolarity = "True"
)

// AllConditionTypes returns every condition type of data-model.md §18, in the table's order.
func AllConditionTypes() []string {
	return []string{
		ConditionAccepted,
		ConditionTranslated,
		ConditionRendered,
		ConditionValidated,
		ConditionApplied,
		ConditionReady,
		ConditionDegraded,
		ConditionDeleting,
	}
}

// ProviderConditionTypes returns the condition types the provider sets on a Fabric or a
// Network: every type except Translated, which is MigrationPlan only. Deleting is set on a
// Network only (a Fabric carries no finalization conditions of its own).
func ProviderConditionTypes() []string {
	return []string{
		ConditionAccepted,
		ConditionRendered,
		ConditionValidated,
		ConditionApplied,
		ConditionReady,
		ConditionDegraded,
		ConditionDeleting,
	}
}

// ReasonsByCondition returns, per condition type, its closed set of reason codes.
//
// For Accepted, Translated, Rendered, Validated, Applied and Ready the reasons are the
// False reasons, plus — for Ready only — VerificationFailed, which it carries with status
// Unknown (UnknownReasonsByCondition). For Degraded and Deleting they are the True reasons.
// A fresh map is returned on every call; callers may not share mutations.
func ReasonsByCondition() map[string][]string {
	return map[string][]string{
		ConditionAccepted:   {ReasonInvalidIntent, ReasonReferenceNotFound, ReasonUnqualified, ReasonAllocationConflict},
		ConditionTranslated: {ReasonUnsupportedFeature, ReasonCollision},
		ConditionRendered:   {ReasonSchemaMismatch, ReasonMappingFailed, ReasonRegisterUncovered},
		ConditionValidated:  {ReasonYangValidationFailed, ReasonSchemaMismatch},
		ConditionApplied:    {ReasonTargetNotReady, ReasonTransactionFailed, ReasonOwnershipConflict},
		ConditionReady:      {ReasonNotConverged, ReasonNotProgrammed, ReasonRoutesMissing, ReasonDeleting, ReasonVerificationFailed},
		ConditionDegraded:   {ReasonPartialFailure, ReasonTelemetryUnavailable, ReasonVerificationFailed, ReasonStaleConfigurationPossible},
		ConditionDeleting:   {ReasonRemovingConfiguration, ReasonTargetUnreachable, ReasonHolderPresent, ReasonForceReleased},
	}
}

// UnknownReasonsByCondition returns the reasons a condition may carry with status Unknown:
// only Ready, only with VerificationFailed (data-model.md §18, AD-40).
func UnknownReasonsByCondition() map[string][]string {
	return map[string][]string{
		ConditionReady: {ReasonVerificationFailed},
	}
}

// PolarityByCondition says, per condition type, which status its closed reasons accompany.
func PolarityByCondition() map[string]ConditionPolarity {
	return map[string]ConditionPolarity{
		ConditionAccepted:   PolarityFalseReasons,
		ConditionTranslated: PolarityFalseReasons,
		ConditionRendered:   PolarityFalseReasons,
		ConditionValidated:  PolarityFalseReasons,
		ConditionApplied:    PolarityFalseReasons,
		ConditionReady:      PolarityFalseReasons,
		ConditionDegraded:   PolarityTrueReasons,
		ConditionDeleting:   PolarityTrueReasons,
	}
}

// IsValidReason reports whether reason belongs to conditionType's closed set.
func IsValidReason(conditionType, reason string) bool {
	for _, r := range ReasonsByCondition()[conditionType] {
		if r == reason {
			return true
		}
	}
	return false
}

// DegradedReasonOrder returns the total order of Degraded reasons, highest precedence first
// (data-model.md §18, AD-54, AD-62): PartialFailure and VerificationFailed follow Ready and
// never compete; then StaleConfigurationPossible (Fabric only); last TelemetryUnavailable,
// the reason only when telemetry is the only thing impaired.
func DegradedReasonOrder() []string {
	return []string{
		ReasonPartialFailure,
		ReasonVerificationFailed,
		ReasonStaleConfigurationPossible,
		ReasonTelemetryUnavailable,
	}
}

// ReasonsCoexistingWithReady returns the Degraded=True reasons that may stand beside
// Ready=True — exactly two, and the list is closed (data-model.md §18).
func ReasonsCoexistingWithReady() []string {
	return []string{ReasonTelemetryUnavailable, ReasonStaleConfigurationPossible}
}
