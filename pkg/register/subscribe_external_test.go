package register_test

// The path-register guard driven through the subscription producers (T022,
// T128; FR-017, FR-089): internal/telemetry.Subscriptions — what the provider
// side states it subscribes — and the committed gNMIc subscriptions file
// deploy/observability/gnmic/subscriptions.yaml — what the collector is
// actually configured with (scripts/lib/device_metrics.sh embeds it) — each
// carry exactly the register's paths under the register's subscription, stream
// mode and interval; an unregistered path or a changed mode is refused.

import (
	"errors"
	"os"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/mairp/agentic-netops-srl/internal/telemetry"
	"github.com/mairp/agentic-netops-srl/pkg/register"
)

func paths(subs []register.Subscription) []string {
	var out []string
	for _, s := range subs {
		out = append(out, s.Paths...)
	}
	sort.Strings(out)
	return out
}

func registered() []string {
	var out []string
	for _, e := range register.SubscribeEntries() {
		out = append(out, e.Path)
	}
	sort.Strings(out)
	return out
}

func TestGuardSubscriptionsCovered(t *testing.T) {
	subs := telemetry.Subscriptions()
	if err := register.CheckSubscriptions(subs); err != nil {
		t.Fatal(err)
	}
	if got, want := paths(subs), registered(); !slices.Equal(got, want) {
		t.Errorf("register and subscriptions drift:\n emitted    %v\n registered %v", got, want)
	}
}

// TestGuardCommittedGnmicSubscriptions: the file the collector is deployed
// with carries exactly the register (its bytes are held to the generator by
// internal/telemetry's golden test; this reads it as gNMIc would).
func TestGuardCommittedGnmicSubscriptions(t *testing.T) {
	doc, err := os.ReadFile("../../" + telemetry.SubscriptionsFile)
	if err != nil {
		t.Fatal(err)
	}
	subs, err := telemetry.ParseGnmicSubscriptions(doc)
	if err != nil {
		t.Fatal(err)
	}
	if err := register.CheckSubscriptions(subs); err != nil {
		t.Fatal(err)
	}
	if got, want := paths(subs), registered(); !slices.Equal(got, want) {
		t.Errorf("%s and the register drift:\n file     %v\n register %v", telemetry.SubscriptionsFile, got, want)
	}
	if len(subs) > register.MaxSubscriptions {
		t.Errorf("%d subscriptions, at most %d", len(subs), register.MaxSubscriptions)
	}
}

func TestGuardDetectsUnregisteredSubscription(t *testing.T) {
	subs := append(telemetry.Subscriptions(), telemetry.Subscription{
		Name: "srl-new", Mode: telemetry.Sample, SampleInterval: 10 * time.Second,
		Paths: []string{"/system/lldp/interface[name=*]/neighbor[id=*]/system-name"},
	})
	err := register.CheckSubscriptions(subs)
	var ue *register.UncoveredError
	if !errors.As(err, &ue) || len(ue.Paths) != 1 || !strings.HasPrefix(ue.Paths[0], "/system/lldp/") {
		t.Fatalf("unregistered subscription not detected: %v", err)
	}
	// A registered path under another stream mode is a mismatch.
	mod := telemetry.Subscriptions()
	mod[0].Mode = telemetry.OnChange
	if err := register.CheckSubscriptions(mod); err == nil {
		t.Error("a stream-mode change passed the guard")
	}
	// A hand edit of the deployed file moving a path to another interval is refused.
	doc, err := os.ReadFile("../../" + telemetry.SubscriptionsFile)
	if err != nil {
		t.Fatal(err)
	}
	edited := strings.Replace(string(doc), "sample-interval: 5s", "sample-interval: 30s", 1)
	subs, err = telemetry.ParseGnmicSubscriptions([]byte(edited))
	if err != nil {
		t.Fatal(err)
	}
	if err := register.CheckSubscriptions(subs); err == nil {
		t.Error("an interval edit of the committed file passed the guard")
	}
}
