package main

// T028 (written test-first, passing with T042): DRIFT_POLICY has no default
// and a closed value set of one. Unset, empty, "non-revertive", "Revertive"
// and "true" each refuse the start naming the variable and the one admissible
// value; only the exact string "revertive" starts, and it lands on the
// revertive field of every generated Config as true (FR-015, AD-17, AD-34).

import (
	"context"
	"io"
	"strings"
	"testing"
)

func env(kv map[string]string) func(string) (string, bool) {
	return func(k string) (string, bool) {
		v, ok := kv[k]
		return v, ok
	}
}

func TestDriftPolicyRefusesEverythingButRevertive(t *testing.T) {
	cases := map[string]map[string]string{
		"unset":         {},
		"empty":         {EnvDriftPolicy: ""},
		"non-revertive": {EnvDriftPolicy: "non-revertive"},
		"Revertive":     {EnvDriftPolicy: "Revertive"},
		"true":          {EnvDriftPolicy: "true"},
	}
	for name, kv := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := loadSettings(env(kv))
			if err == nil {
				t.Fatalf("DRIFT_POLICY %s accepted", name)
			}
			msg := err.Error()
			if !strings.Contains(msg, "DRIFT_POLICY") || !strings.Contains(msg, `"revertive"`) {
				t.Errorf("refusal does not name the variable and the admissible value: %s", msg)
			}
			// run refuses before touching any cluster.
			rerr := run(context.Background(), env(kv), io.Discard)
			if rerr == nil || !strings.Contains(rerr.Error(), "refusing to start") || !strings.Contains(rerr.Error(), "DRIFT_POLICY") {
				t.Errorf("run did not refuse the start naming DRIFT_POLICY: %v", rerr)
			}
		})
	}
}

func TestDriftPolicyRevertiveStartsAndStatesRevertiveTrue(t *testing.T) {
	s, err := loadSettings(env(map[string]string{EnvDriftPolicy: "revertive"}))
	if err != nil {
		t.Fatalf("the exact string revertive refused: %v", err)
	}
	if s.DriftPolicy != DriftPolicyRevertive || !s.Fabric.Revertive {
		t.Errorf("revertive must map to spec.revertive true: %+v", s)
	}
}
