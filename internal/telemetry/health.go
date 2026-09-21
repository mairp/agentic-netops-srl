package telemetry

import "context"

// UnwiredHealth is the telemetry-health input the Fabric reconciler is given
// until T133 wires the provider's own telemetry health (AD-62, T133). It
// reports the telemetry dependency healthy and never reads a device; it exists
// so that the input is an explicit, replaceable dependency — the reconciler
// never sets Degraded=True/TelemetryUnavailable from anything else.
type UnwiredHealth struct{}

// TelemetryHealthy implements the reconciler's TelemetryHealth input.
func (UnwiredHealth) TelemetryHealthy(context.Context) (bool, string) {
	return true, "telemetry health not wired (T133)"
}
