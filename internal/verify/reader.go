// Package verify is the provider's two-sided read-back (FR-100, FR-107,
// contracts/reconciliation.md Rule 5). fabric.go is the Fabric's read-back
// (T041); the Network's (T058) will sit beside it.
//
// How device state is read. The provider holds NO device session of its own:
// the only processes with a session to the device management server (gNMI,
// 57400) are the device-configuration layer's data-server and the metric
// collector (FR-086, FR-107 — "re-verification adds no client of the device
// management server"). Everything here therefore reads through the StateReader
// interface below, whose implementations are clients of the device-
// configuration layer, never of a device.
//
// What the pinned layer serves (config-server v0.0.58 / data-server v0.0.66,
// read from the checked-out sources, never assumed):
//
//   - the RUNNING datastore: yes. The config-server's aggregated API serves
//     config.sdcio.dev/v1alpha1 RunningConfig (one per Target, same name and
//     namespace), built from the data-server's GetIntent(intent="running")
//     over the data-server's own target session
//     (config-server/pkg/registry/runningconfig/strategy_resource.go).
//     LayerReader.Running reads it.
//   - the STATE datastore: NO. The data-server's gRPC service DataServer at
//     v0.0.66 has no GetData RPC (data-server/pkg/server: ListDataStore,
//     GetDataStore, Create/DeleteDataStore, TransactionSet/Confirm/Cancel,
//     ListIntent, GetIntent, WatchDeviations, BlameConfig, plus the schema
//     service) — sdcpb.GetDataRequest with its DataType STATE exists only as
//     the data-server's internal target-driver call — and its target sync
//     (TargetSyncProfile, gnmi get/once/stream) requests DataType CONFIG or
//     the gNMI ConfigSubscription extension only
//     (data-server/pkg/datastore/target/gnmi/{get,stream}.go). No state leaf
//     reaches any API the layer exposes. LayerReader.State therefore returns
//     ErrStateNotServed, which the read-back classes as a pass that could not
//     run — never as a pass that passed. The applied side is NOT weakened to
//     the written side: until a state source that holds to FR-086 exists, a
//     Fabric read-back through LayerReader cannot run to completion, and the
//     Fabric never reports Ready=True on the strength of the running datastore
//     alone (design question recorded for the operator; see the stream's
//     report).
package verify

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
)

// Target names one device target of the device-configuration layer.
type Target struct {
	Namespace string
	Name      string
}

func (t Target) String() string { return t.Name }

// StateReader reads one device's datastores through the device-configuration
// layer. An implementation MUST NOT open a device session of its own.
//
// Any error it returns means the read could not be made — the target is
// unreachable, the layer did not answer, the read timed out or the datastore
// is not served — and the read-back that asked for it could not run. A value
// the device does not report is an absent entry, never an error.
type StateReader interface {
	// Running returns the target's running configuration as the layer holds
	// it: one JSON_IETF document at "/".
	Running(ctx context.Context, target Target) ([]byte, error)
	// State reads each path from the target's state datastore (the running
	// configuration plus operational data). The result maps each requested
	// path to the values of every instance it matched — a list key the path
	// leaves unspecified matches any instance — and a path the device does
	// not report is absent from the map.
	State(ctx context.Context, target Target, paths []string) (map[string][]string, error)
}

// ErrStateNotServed is a StateReader's answer that the state datastore is not
// served by the layer it reads through. It makes the read-back a pass that
// could not run.
var ErrStateNotServed = errors.New("the state datastore is not served by the pinned device-configuration layer " +
	"(data-server v0.0.66 exposes no GetData RPC; its sync reads CONFIG only)")

// CouldNotRunError is a read-back that could not run: a required target was
// unreachable, the layer did not answer, or the read timed out (FR-107,
// AD-40). It is distinct from a read-back that ran and found an invariant
// missing, which is a FabricResult with Missing entries and a nil error.
type CouldNotRunError struct {
	// Causes maps each target that stopped the pass to why.
	Causes map[string]error
}

// Targets are the targets that stopped the pass, sorted.
func (e *CouldNotRunError) Targets() []string {
	out := make([]string, 0, len(e.Causes))
	for t := range e.Causes {
		out = append(out, t)
	}
	sort.Strings(out)
	return out
}

func (e *CouldNotRunError) Error() string {
	var parts []string
	for _, t := range e.Targets() {
		parts = append(parts, fmt.Sprintf("%s: %v", t, e.Causes[t]))
	}
	return "read-back could not run against " + strings.Join(parts, "; ")
}

// Unwrap exposes every cause, so errors.Is(err, ErrStateNotServed) holds when
// that was why.
func (e *CouldNotRunError) Unwrap() []error {
	out := make([]error, 0, len(e.Causes))
	for _, t := range e.Targets() {
		out = append(out, e.Causes[t])
	}
	return out
}

// IsCouldNotRun reports whether err is a read-back that could not run.
func IsCouldNotRun(err error) bool {
	var e *CouldNotRunError
	return errors.As(err, &e)
}

// AsCouldNotRun returns err as a CouldNotRunError, or nil.
func AsCouldNotRun(err error) *CouldNotRunError {
	var e *CouldNotRunError
	if errors.As(err, &e) {
		return e
	}
	return nil
}
