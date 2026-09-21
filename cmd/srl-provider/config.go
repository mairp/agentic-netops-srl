package main

// Start-up settings of the provider (T042; data-model.md §25). Every bound is
// an environment variable of the Deployment, never a constant a change of
// value would need a rebuild for. loadSettings is the one parser; a refused
// setting refuses the start, naming the variable — nothing falls back to a
// default it was not asked for.

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/mairp/agentic-netops-srl/controllers/allocation"
	"github.com/mairp/agentic-netops-srl/controllers/fabric"
	"github.com/mairp/agentic-netops-srl/pkg/sdc"
)

// Setting names and their fixed values.
const (
	// EnvDriftPolicy has NO default and a closed value set of one:
	// DriftPolicyRevertive, the exact string (FR-015, AD-13, AD-17, AD-34).
	EnvDriftPolicy       = "DRIFT_POLICY"
	DriftPolicyRevertive = "revertive"

	// EnvReverifyInterval: unset takes ReverifyDefault; a value below
	// ReverifyFloor, or one that cannot be parsed, refuses the start (FR-107).
	EnvReverifyInterval = "REVERIFY_INTERVAL"
	ReverifyDefault     = 5 * time.Minute
	ReverifyFloor       = 30 * time.Second

	EnvReconcileInterval = "RECONCILE_INTERVAL"   // default 15s
	EnvBackoffBase       = "RETRY_BACKOFF_BASE"   // default 250ms
	EnvBackoffCap        = "RETRY_BACKOFF_CAP"    // default 10s
	EnvMaxAttempts       = "RETRY_MAX_ATTEMPTS"   // default 6
	EnvVerifyTimeout     = "VERIFY_TIMEOUT"       // default 30s: one read-back pass
	EnvTargetNamespace   = "TARGET_NAMESPACE"     // default agentic-netops-system
	EnvSchemaNamespace   = "SCHEMA_NAMESPACE"     // default agentic-netops-system
	EnvCompatLockFile    = "COMPAT_LOCK_FILE"     // default /etc/srl-provider/versions.lock.yaml
	EnvMetricsAddr       = "METRICS_BIND_ADDRESS" // default :8080
	EnvProbeAddr         = "HEALTH_PROBE_BIND_ADDRESS"
	EnvLeaderElect       = "LEADER_ELECT"  // default true
	EnvLeaderElectionNS  = "POD_NAMESPACE" // default agentic-netops-system
	EnvOTLPEndpoint      = "OTEL_EXPORTER_OTLP_ENDPOINT"
	// EnvDeviceMetricsURL names the device metric collector's Prometheus
	// endpoint, from which the read-back reads the state datastore (AD-82).
	EnvDeviceMetricsURL = "DEVICE_METRICS_URL"
	EnvLogLevel         = "LOG_LEVEL" // info (default) | debug

	// EnvNetworkWatchScope is the Network watch scope, first-party
	// configuration (R-15): the one value is "cluster" — Networks live in
	// agentic-netops-intent (the tier's) and agentic-netops-services (the
	// control plane's), neither of them the provider's namespace.
	EnvNetworkWatchScope = "NETWORK_WATCH_SCOPE"
	NetworkWatchCluster  = "cluster"

	LeaderElectionID = "srl-provider.fabric.agentic-netops.io"

	// EnvRole selects what this process runs (T176): RoleProvider — the default when
	// unset — the Fabric reconciler and everything that renders; or
	// RoleAllocationAuthority, the first-party allocation authority's pool and claim
	// controllers and nothing else, admitted only when the lock file selects
	// allocationAuthority.kind: first-party. Any other value, the empty string
	// included, refuses the start.
	EnvRole                 = "SRL_PROVIDER_ROLE"
	RoleProvider            = "provider"
	RoleAllocationAuthority = "allocation-authority"

	// AllocationLeaderElectionID is the allocation authority's lease, in its namespace.
	AllocationLeaderElectionID = "allocation-authority.fabric.agentic-netops.io"
)

// parseRole reads SRL_PROVIDER_ROLE: unset is RoleProvider; set, it must be one of the
// two roles exactly.
func parseRole(lookup func(string) (string, bool)) (string, error) {
	v, ok := lookup(EnvRole)
	if !ok {
		return RoleProvider, nil
	}
	switch v {
	case RoleProvider, RoleAllocationAuthority:
		return v, nil
	}
	return "", fmt.Errorf("%s=%q is not admissible: the admissible values are %q (the default when unset) and %q",
		EnvRole, v, RoleProvider, RoleAllocationAuthority)
}

// registersAllocation says whether a process of role registers the allocation
// controllers under the lock file's allocationAuthority.kind. The provider never does.
// The allocation authority does only under first-party; under any other kind it refuses
// to start, naming allocationAuthority.kind — there is never a second authority beside
// kuid (FR-104).
func registersAllocation(role, authorityKind string) (bool, error) {
	switch role {
	case RoleProvider:
		return false, nil
	case RoleAllocationAuthority:
		if err := allocation.RegisteredUnder(authorityKind); err != nil {
			return false, fmt.Errorf("%s=%s: %w", EnvRole, RoleAllocationAuthority, err)
		}
		return true, nil
	}
	return false, fmt.Errorf("%s=%q is not a role", EnvRole, role)
}

// settings is the parsed configuration.
type settings struct {
	Role              string
	Fabric            fabric.Settings
	DriftPolicy       string
	VerifyTimeout     time.Duration
	CompatLockFile    string
	MetricsAddr       string
	ProbeAddr         string
	LeaderElect       bool
	LeaderElectionNS  string
	NetworkWatchScope string
	OTLPEndpoint      string
	// DeviceMetricsURL is the device metric collector's Prometheus endpoint,
	// the read-back's state datastore (EnvDeviceMetricsURL).
	DeviceMetricsURL string
	Debug            bool
}

// loadSettings parses the environment through lookup (os.LookupEnv, which
// tells unset from empty). Every refusal is collected and returned together.
func loadSettings(lookup func(string) (string, bool)) (settings, error) {
	s := settings{Fabric: fabric.DefaultSettings()}
	var errs []error

	role, err := parseRole(lookup)
	if err != nil {
		errs = append(errs, err)
	}
	s.Role = role

	// DRIFT_POLICY: no default, closed set {revertive}. Required of the provider only:
	// the allocation authority renders nothing and writes no Config, so there is no
	// drift for it to be revertive about, and it neither reads nor states the policy.
	if role == RoleAllocationAuthority {
		// not required, not read
	} else if v, ok := lookup(EnvDriftPolicy); !ok {
		errs = append(errs, fmt.Errorf("%s is not set: it has no default; the one admissible value is %q (FR-015, AD-17)",
			EnvDriftPolicy, DriftPolicyRevertive))
	} else if v != DriftPolicyRevertive {
		errs = append(errs, fmt.Errorf("%s=%q is not admissible: the one admissible value is the exact string %q (FR-015, AD-17)",
			EnvDriftPolicy, v, DriftPolicyRevertive))
	} else {
		s.DriftPolicy = v
		// revertive maps to spec.revertive: true on every generated Config;
		// no member of the set produces false or an absent field (AD-34).
		s.Fabric.Revertive = true
	}

	// REVERIFY_INTERVAL: unset → 5m; below the 30s floor or unparseable → refused.
	if v, ok := lookup(EnvReverifyInterval); !ok {
		s.Fabric.ReverifyInterval = ReverifyDefault
	} else if d, err := time.ParseDuration(strings.TrimSpace(v)); err != nil || strings.TrimSpace(v) == "" {
		errs = append(errs, fmt.Errorf("%s=%q cannot be parsed as a duration: it must be a duration of at least the %s floor (data-model.md §25), or unset for the %s default",
			EnvReverifyInterval, v, ReverifyFloor, ReverifyDefault))
	} else if d < ReverifyFloor {
		errs = append(errs, fmt.Errorf("%s=%q is below the %s floor (data-model.md §25): the provider refuses to start rather than use it or the default",
			EnvReverifyInterval, v, ReverifyFloor))
	} else {
		s.Fabric.ReverifyInterval = d
	}

	dur := func(name string, dst *time.Duration) {
		v, ok := lookup(name)
		if !ok {
			return
		}
		d, err := time.ParseDuration(strings.TrimSpace(v))
		if err != nil || d <= 0 {
			errs = append(errs, fmt.Errorf("%s=%q must be a positive duration (data-model.md §25)", name, v))
			return
		}
		*dst = d
	}
	dur(EnvReconcileInterval, &s.Fabric.ReconcileInterval)
	dur(EnvBackoffBase, &s.Fabric.BackoffBase)
	dur(EnvBackoffCap, &s.Fabric.BackoffCap)
	s.VerifyTimeout = 30 * time.Second
	dur(EnvVerifyTimeout, &s.VerifyTimeout)
	if s.Fabric.BackoffBase > s.Fabric.BackoffCap {
		errs = append(errs, fmt.Errorf("%s (%s) exceeds %s (%s)", EnvBackoffBase, s.Fabric.BackoffBase, EnvBackoffCap, s.Fabric.BackoffCap))
	}
	if v, ok := lookup(EnvMaxAttempts); ok {
		n, err := strconv.Atoi(strings.TrimSpace(v))
		if err != nil || n < 1 {
			errs = append(errs, fmt.Errorf("%s=%q must be a positive integer (data-model.md §25)", EnvMaxAttempts, v))
		} else {
			s.Fabric.MaxAttempts = n
		}
	}

	str := func(name, def string) string {
		if v, ok := lookup(name); ok && strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
		return def
	}
	// Default agentic-netops-system: Targets and everything they use live in
	// agentic-netops-system because config-server v0.0.58 lists them in the Target's
	// namespace (AD-82 decision 2026-09-21-target-namespace).
	s.Fabric.TargetNamespace = str(EnvTargetNamespace, s.Fabric.TargetNamespace)
	s.Fabric.SchemaNamespace = str(EnvSchemaNamespace, s.Fabric.SchemaNamespace)
	s.CompatLockFile = str(EnvCompatLockFile, "/etc/srl-provider/versions.lock.yaml")
	s.MetricsAddr = str(EnvMetricsAddr, ":8080")
	s.ProbeAddr = str(EnvProbeAddr, ":8081")
	s.LeaderElectionNS = str(EnvLeaderElectionNS, sdc.SystemNamespace)
	s.OTLPEndpoint = str(EnvOTLPEndpoint, "")
	s.DeviceMetricsURL = str(EnvDeviceMetricsURL, "")
	if u := s.DeviceMetricsURL; u != "" && !strings.HasPrefix(u, "http://") && !strings.HasPrefix(u, "https://") {
		errs = append(errs, fmt.Errorf("%s=%q is not an http(s) URL of the device metric collector's Prometheus endpoint", EnvDeviceMetricsURL, u))
	}
	switch lvl := str(EnvLogLevel, "info"); lvl {
	case "info":
	case "debug":
		s.Debug = true
	default:
		errs = append(errs, fmt.Errorf("%s=%q: admissible values are info and debug", EnvLogLevel, lvl))
	}
	s.LeaderElect = true
	if v, ok := lookup(EnvLeaderElect); ok {
		b, err := strconv.ParseBool(strings.TrimSpace(v))
		if err != nil {
			errs = append(errs, fmt.Errorf("%s=%q must be true or false", EnvLeaderElect, v))
		} else {
			s.LeaderElect = b
		}
	}
	s.NetworkWatchScope = str(EnvNetworkWatchScope, NetworkWatchCluster)
	if s.NetworkWatchScope != NetworkWatchCluster {
		errs = append(errs, fmt.Errorf("%s=%q: the one admissible value is %q — Networks are watched cluster-wide (R-15)",
			EnvNetworkWatchScope, s.NetworkWatchScope, NetworkWatchCluster))
	}
	return s, errors.Join(errs...)
}
