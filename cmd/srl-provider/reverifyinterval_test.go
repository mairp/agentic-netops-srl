package main

// T028 (written test-first, passing with T042): REVERIFY_INTERVAL — "10s",
// "0", "-5m", "five minutes" and "" each refuse the start naming the variable
// and the 30 s floor of data-model.md §25, never falling back to the default;
// "30s" and unset start, and unset takes the five-minute default (FR-107,
// AD-49).

import (
	"context"
	"io"
	"strings"
	"testing"
	"time"
)

func withDrift(kv map[string]string) map[string]string {
	out := map[string]string{EnvDriftPolicy: DriftPolicyRevertive}
	for k, v := range kv {
		out[k] = v
	}
	return out
}

func TestReverifyIntervalRefusals(t *testing.T) {
	for _, v := range []string{"10s", "0", "-5m", "five minutes", ""} {
		t.Run(v, func(t *testing.T) {
			kv := withDrift(map[string]string{EnvReverifyInterval: v})
			_, err := loadSettings(env(kv))
			if err == nil {
				t.Fatalf("REVERIFY_INTERVAL=%q accepted", v)
			}
			msg := err.Error()
			if !strings.Contains(msg, "REVERIFY_INTERVAL") || !strings.Contains(msg, "30s floor") {
				t.Errorf("refusal does not name the variable and the 30s floor: %s", msg)
			}
			if rerr := run(context.Background(), env(kv), io.Discard); rerr == nil || !strings.Contains(rerr.Error(), "REVERIFY_INTERVAL") {
				t.Errorf("run did not refuse the start: %v", rerr)
			}
		})
	}
}

func TestReverifyIntervalAccepted(t *testing.T) {
	s, err := loadSettings(env(withDrift(nil)))
	if err != nil {
		t.Fatalf("unset refused: %v", err)
	}
	if s.Fabric.ReverifyInterval != 5*time.Minute {
		t.Errorf("unset takes %s, want the five-minute default", s.Fabric.ReverifyInterval)
	}
	s, err = loadSettings(env(withDrift(map[string]string{EnvReverifyInterval: "30s"})))
	if err != nil {
		t.Fatalf("30s refused: %v", err)
	}
	if s.Fabric.ReverifyInterval != 30*time.Second {
		t.Errorf("30s parsed as %s", s.Fabric.ReverifyInterval)
	}
	s, err = loadSettings(env(withDrift(map[string]string{EnvReverifyInterval: "2m"})))
	if err != nil || s.Fabric.ReverifyInterval != 2*time.Minute {
		t.Errorf("override not honoured: %s %v", s.Fabric.ReverifyInterval, err)
	}
}
