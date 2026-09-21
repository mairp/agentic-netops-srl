package main

// T176: SRL_PROVIDER_ROLE — unset is the provider; "allocation-authority" is admitted and
// needs no DRIFT_POLICY (it renders nothing); any other value, the explicit empty string
// included, refuses the start naming the variable and both values. The allocation
// controllers are registered only by the allocation authority, and only when the lock
// selects first-party: under kuid that role refuses naming allocationAuthority.kind.

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/mairp/agentic-netops-srl/internal/compat"
)

func TestRoleDefaultsToProvider(t *testing.T) {
	s, err := loadSettings(env(withDrift(nil)))
	if err != nil || s.Role != RoleProvider {
		t.Fatalf("unset role = %q %v, want provider", s.Role, err)
	}
	s, err = loadSettings(env(withDrift(map[string]string{EnvRole: RoleProvider})))
	if err != nil || s.Role != RoleProvider {
		t.Fatalf("provider = %q %v", s.Role, err)
	}
	// The provider still requires DRIFT_POLICY.
	if _, err := loadSettings(env(map[string]string{EnvRole: RoleProvider})); err == nil || !strings.Contains(err.Error(), EnvDriftPolicy) {
		t.Errorf("provider without DRIFT_POLICY: %v", err)
	}
}

func TestAllocationAuthorityRoleNeedsNoDriftPolicy(t *testing.T) {
	s, err := loadSettings(env(map[string]string{EnvRole: RoleAllocationAuthority}))
	if err != nil || s.Role != RoleAllocationAuthority {
		t.Fatalf("allocation-authority = %q %v", s.Role, err)
	}
}

func TestRoleRefusals(t *testing.T) {
	for _, v := range []string{"", "Provider", "kuid", "allocation", "first-party", " provider"} {
		t.Run(v, func(t *testing.T) {
			kv := withDrift(map[string]string{EnvRole: v})
			_, err := loadSettings(env(kv))
			if err == nil {
				t.Fatalf("%s=%q accepted", EnvRole, v)
			}
			for _, s := range []string{EnvRole, `"provider"`, `"allocation-authority"`} {
				if !strings.Contains(err.Error(), s) {
					t.Errorf("refusal lacks %s: %v", s, err)
				}
			}
			if rerr := run(context.Background(), env(kv), io.Discard); rerr == nil || !strings.Contains(rerr.Error(), "refusing to start") ||
				!strings.Contains(rerr.Error(), EnvRole) {
				t.Errorf("run did not refuse naming %s: %v", EnvRole, rerr)
			}
		})
	}
}

func TestRegistersAllocation(t *testing.T) {
	for _, kind := range []string{compat.AuthorityKuid, compat.AuthorityFirstParty} {
		if ok, err := registersAllocation(RoleProvider, kind); ok || err != nil {
			t.Errorf("provider under %s registers the allocation controllers: %v %v", kind, ok, err)
		}
	}
	if ok, err := registersAllocation(RoleAllocationAuthority, compat.AuthorityFirstParty); !ok || err != nil {
		t.Errorf("allocation-authority under first-party: %v %v", ok, err)
	}
	ok, err := registersAllocation(RoleAllocationAuthority, compat.AuthorityKuid)
	if ok || err == nil || !strings.Contains(err.Error(), "allocationAuthority.kind") || !strings.Contains(err.Error(), "registered only when the lock file selects first-party") {
		t.Errorf("allocation-authority under kuid: %v %v", ok, err)
	}
}

// run itself refuses the allocation-authority role under a kuid lock before any cluster
// connection.
func TestRunRefusesAllocationAuthorityUnderKuid(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "..", "versions.lock.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(`(?m)^allocationAuthority:\n  kind: [a-z-]+\n`)
	lock := filepath.Join(t.TempDir(), "versions.lock.yaml")
	if err := os.WriteFile(lock, re.ReplaceAll(b, []byte("allocationAuthority:\n  kind: kuid\n")), 0o600); err != nil {
		t.Fatal(err)
	}
	err = run(context.Background(), env(map[string]string{EnvRole: RoleAllocationAuthority, EnvCompatLockFile: lock}), io.Discard)
	if err == nil || !strings.Contains(err.Error(), "refusing to start") || !strings.Contains(err.Error(), "allocationAuthority.kind") {
		t.Fatalf("run = %v", err)
	}
}
