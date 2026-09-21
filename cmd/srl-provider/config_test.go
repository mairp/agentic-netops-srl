package main

import (
	"strings"
	"testing"
	"time"
)

// The other §25 bounds: defaults asserted, overrides honoured, nonsense refused.
func TestOtherSettings(t *testing.T) {
	s, err := loadSettings(env(withDrift(nil)))
	if err != nil {
		t.Fatal(err)
	}
	f := s.Fabric
	if f.ReconcileInterval != 15*time.Second || f.BackoffBase != 250*time.Millisecond || f.BackoffCap != 10*time.Second ||
		f.MaxAttempts != 6 || f.TargetNamespace != "sdc-system" || s.NetworkWatchScope != "cluster" || !s.LeaderElect {
		t.Errorf("defaults: %+v %+v", f, s)
	}
	s, err = loadSettings(env(withDrift(map[string]string{EnvReconcileInterval: "20s", EnvMaxAttempts: "3",
		EnvBackoffBase: "100ms", EnvBackoffCap: "2s"})))
	if err != nil || s.Fabric.ReconcileInterval != 20*time.Second || s.Fabric.MaxAttempts != 3 ||
		s.Fabric.BackoffBase != 100*time.Millisecond || s.Fabric.BackoffCap != 2*time.Second {
		t.Errorf("overrides: %+v %v", s.Fabric, err)
	}
	for k, v := range map[string]string{EnvReconcileInterval: "0", EnvMaxAttempts: "zero", EnvNetworkWatchScope: "namespace",
		EnvLeaderElect: "maybe", EnvBackoffBase: "20s"} {
		if _, err := loadSettings(env(withDrift(map[string]string{k: v}))); err == nil || !strings.Contains(err.Error(), k) {
			t.Errorf("%s=%q: %v", k, v, err)
		}
	}
}
