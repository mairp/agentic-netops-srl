// Package telemetry holds the provider-side observability wiring. This file is
// the device subscription set the in-cluster gNMIc is configured with (FR-089,
// data-model.md §21): native srl_nokia paths only, sampled by default. It is
// no longer a list of its own: the path register (pkg/register) is the one
// statement of every subscribed path — with its derived metric name, label set
// and stream mode, re-validated against the pinned YANG tag (T128) — and
// Subscriptions() groups it into gNMIc subscriptions; gnmic_config.go writes
// deploy/observability/gnmic/subscriptions.yaml from the same grouping, and
// scripts/lib/device_metrics.sh deploys that file, so the register, this
// function and the collector cannot drift (FR-017, T022).
package telemetry

import "github.com/mairp/agentic-netops-srl/pkg/register"

// StreamMode is a gNMI subscription stream mode (the register's).
type StreamMode = register.StreamMode

const (
	// Sample is the default (data-model.md §21).
	Sample = register.Sample
	// OnChange is used only where an acceptance check (gate item G7) covers it;
	// none does today.
	OnChange = register.OnChange
)

// Subscription is one named gNMIc subscription: one Subscribe stream per target.
type Subscription = register.Subscription

// Subscriptions returns the device subscription set, sorted by name: the
// register's entries grouped by subscription (at most three streams per
// target). Every mode is `sample`: G7 qualified no on-change stream.
func Subscriptions() []Subscription { return register.Subscriptions() }
