package telemetry

// The gNMIc subscriptions file (T128; FR-017, FR-089): the `subscriptions:`
// section of the device metric collector's gNMIc configuration, generated from
// the path register and committed as deploy/observability/gnmic/subscriptions.yaml.
// scripts/lib/device_metrics.sh embeds it verbatim into the ConfigMap
// monitoring/device-metrics-gnmic beside the targets, the TLS settings, the
// api-server, the OTLP output and the event processors it renders itself.
//
// gnmic_config_test.go holds the committed file to GnmicSubscriptionsYAML()
// byte for byte. Regenerate after changing the register:
//
//	go test ./internal/telemetry -run TestGnmicSubscriptionsGolden -update

import (
	"bytes"
	"fmt"
	"sort"
	"time"

	"sigs.k8s.io/yaml"
)

// SubscriptionsFile is the committed file, relative to the repository root.
const SubscriptionsFile = "deploy/observability/gnmic/subscriptions.yaml"

const subscriptionsHeader = `# GENERATED from the path register (pkg/register SubscribeEntries; T128, FR-017, FR-089) by
# internal/telemetry/gnmic_config.go — do not edit by hand. Regenerate after changing the register:
#   go test ./internal/telemetry -run TestGnmicSubscriptionsGolden -update
# scripts/lib/device_metrics.sh embeds the subscriptions section below into the gNMIc configuration
# (ConfigMap monitoring/device-metrics-gnmic). Every path is native srl_nokia, re-validated against
# the pinned YANG models (pkg/register/testdata/yang-index-v25.7.1.json); each subscription is one
# gNMI Subscribe stream per target (at most three), sampled (G7 qualified no on-change stream).
`

// GnmicSubscriptionsYAML renders the subscriptions file from Subscriptions().
func GnmicSubscriptionsYAML() []byte {
	var b bytes.Buffer
	b.WriteString(subscriptionsHeader)
	b.WriteString("subscriptions:\n")
	for _, s := range Subscriptions() {
		fmt.Fprintf(&b, "  %s:\n", s.Name)
		b.WriteString("    mode: stream\n")
		fmt.Fprintf(&b, "    stream-mode: %s\n", s.Mode)
		if s.Mode == Sample {
			fmt.Fprintf(&b, "    sample-interval: %s\n", s.SampleInterval)
		}
		b.WriteString("    paths:\n")
		for _, p := range s.Paths {
			fmt.Fprintf(&b, "      - %q\n", p)
		}
	}
	return b.Bytes()
}

// ParseGnmicSubscriptions reads a gNMIc `subscriptions:` section (the
// committed file, or the section of a rendered gNMIc configuration) back into
// Subscriptions, sorted by name — what the path-register guard checks against
// the register (register.CheckSubscriptions).
func ParseGnmicSubscriptions(doc []byte) ([]Subscription, error) {
	var cfg struct {
		Subscriptions map[string]struct {
			Mode           string   `json:"mode"`
			StreamMode     string   `json:"stream-mode"`
			SampleInterval string   `json:"sample-interval"`
			Paths          []string `json:"paths"`
		} `json:"subscriptions"`
	}
	if err := yaml.UnmarshalStrict(doc, &cfg); err != nil {
		return nil, err
	}
	out := make([]Subscription, 0, len(cfg.Subscriptions))
	for name, s := range cfg.Subscriptions {
		if s.Mode != "stream" {
			return nil, fmt.Errorf("subscription %s: mode %q, want stream", name, s.Mode)
		}
		sub := Subscription{Name: name, Mode: StreamMode(s.StreamMode), Paths: s.Paths}
		if s.SampleInterval != "" {
			iv, err := time.ParseDuration(s.SampleInterval)
			if err != nil {
				return nil, fmt.Errorf("subscription %s: %w", name, err)
			}
			sub.SampleInterval = iv
		}
		out = append(out, sub)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}
