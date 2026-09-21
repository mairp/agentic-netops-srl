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
	EnvTargetNamespace   = "TARGET_NAMESPACE"     // default sdc-system
	EnvSchemaNamespace   = "SCHEMA_NAMESPACE"     // default sdc-system
	EnvCompatLockFile    = "COMPAT_LOCK_FILE"     // default /etc/srl-provider/versions.lock.yaml
	EnvMetricsAddr       = "METRICS_BIND_ADDRESS" // default :8080
	EnvProbeAddr         = "HEALTH_PROBE_BIND_ADDRESS"
	EnvLeaderElect       = "LEADER_ELECT"  // default true
	EnvLeaderElectionNS  = "POD_NAMESPACE" // default agentic-netops-system
	EnvOTLPEndpoint      = "OTEL_EXPORTER_OTLP_ENDPOINT"
	EnvLogLevel          = "LOG_LEVEL" // info (default) | debug

	// EnvNetworkWatchScope is the Network watch scope, first-party
	// configuration (R-15): the one value is "cluster" — Networks live in
	// agentic-netops-intent (the tier's) and agentic-netops-services (the
	// control plane's), neither of them the provider's namespace.
	EnvNetworkWatchScope = "NETWORK_WATCH_SCOPE"
	NetworkWatchCluster  = "cluster"

	LeaderElectionID = "srl-provider.fabric.agentic-netops.io"
)

// settings is the parsed configuration.
type settings struct {
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
	Debug             bool
}

// loadSettings parses the environment through lookup (os.LookupEnv, which
// tells unset from empty). Every refusal is collected and returned together.
func loadSettings(lookup func(string) (string, bool)) (settings, error) {
	s := settings{Fabric: fabric.DefaultSettings()}
	var errs []error

	// DRIFT_POLICY: no default, closed set {revertive}.
	if v, ok := lookup(EnvDriftPolicy); !ok {
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
	s.Fabric.TargetNamespace = str(EnvTargetNamespace, s.Fabric.TargetNamespace)
	s.Fabric.SchemaNamespace = str(EnvSchemaNamespace, s.Fabric.SchemaNamespace)
	s.CompatLockFile = str(EnvCompatLockFile, "/etc/srl-provider/versions.lock.yaml")
	s.MetricsAddr = str(EnvMetricsAddr, ":8080")
	s.ProbeAddr = str(EnvProbeAddr, ":8081")
	s.LeaderElectionNS = str(EnvLeaderElectionNS, sdc.SystemNamespace)
	s.OTLPEndpoint = str(EnvOTLPEndpoint, "")
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
