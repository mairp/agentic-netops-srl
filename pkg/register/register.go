// Package register is the native-first path register (FR-017, FR-089, C-09,
// R-05): the one statement of every device path the platform writes and every
// device path it subscribes to. Per path it records the model chosen — native
// `srl_nokia` by default — and a justification for any exception (there are
// none today); per subscribed path, additionally, the derived metric name, the
// label names and the stream mode.
//
// Paths are registered as key-wildcarded patterns: every list-key value is
// `*` (`/interface[name=*]/admin-state`). A concrete path is covered when its
// normalized form (Normalize) is a registered pattern.
//
// The register is enforced where paths are produced, not beside them:
// CheckWrite is what the renderer calls on the path set it is about to emit
// (a miss is `Rendered=False/RegisterUncovered`, data-model.md §18), and
// guard_test.go drives the actual producers — internal/model's WritePaths over
// representative intent covering every construct, and
// internal/telemetry.Subscriptions — through the same functions, so a new
// construct or a new metric cannot pass uncovered.
package register

import (
	"fmt"
	"sort"
	"strings"
)

// Model is the YANG model family a path is taken from.
type Model string

const (
	// Native is the device vendor's own srl_nokia model set — the default.
	Native Model = "srl_nokia"
	// OpenConfig is a standard model; using it is an exception and needs a
	// recorded justification.
	OpenConfig Model = "openconfig"
)

// Owner says which generated Config writes a path.
type Owner string

const (
	// OwnerFabric is the priority-10 per-node fabric Config.
	OwnerFabric Owner = "fabric"
	// OwnerService is a priority-20 per-(service, node) Config.
	OwnerService Owner = "service"
)

// WriteEntry registers one written path pattern.
type WriteEntry struct {
	Path  string
	Model Model
	// Justification is required, and only allowed, when Model is not Native.
	Justification string
	// Owners are the generated Configs that write it; a pattern may be written
	// by both, on disjoint concrete keys (AD-68).
	Owners []Owner
	// Constructs names what writes it: "fabric", or the service constructs.
	Constructs []string
}

// Normalize replaces every list-key value of a concrete gNMI path with `*`:
// `/interface[name=ethernet-1/1]/subinterface[index=100]/admin-state` becomes
// `/interface[name=*]/subinterface[index=*]/admin-state`. Key values may
// themselves contain `/` (`ethernet-1/1`, `10.0.0.0/24`); a key value ends at
// the first `]`, which no key value this platform renders contains.
func Normalize(path string) string {
	var b strings.Builder
	b.Grow(len(path))
	for i := 0; i < len(path); i++ {
		ch := path[i]
		if ch != '[' {
			b.WriteByte(ch)
			continue
		}
		end := strings.IndexByte(path[i:], ']')
		if end < 0 { // malformed; keep verbatim so it cannot match a pattern
			b.WriteString(path[i:])
			break
		}
		kv := path[i+1 : i+end]
		if eq := strings.IndexByte(kv, '='); eq >= 0 {
			b.WriteString("[" + kv[:eq] + "=*]")
		} else {
			b.WriteString(path[i : i+end+1])
		}
		i += end
	}
	return b.String()
}

// Uncovered returns, sorted and de-duplicated, every path of paths whose
// normalized form is not in registered.
func uncovered(paths []string, registered map[string]bool) []string {
	seen := map[string]bool{}
	var out []string
	for _, p := range paths {
		if !registered[Normalize(p)] && !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out
}

// UncoveredError names every emitted path the register does not cover.
type UncoveredError struct {
	Kind  string // "write" or "subscribe"
	Paths []string
}

func (e *UncoveredError) Error() string {
	return fmt.Sprintf("%d %s path(s) not in the path register (FR-017): %s", len(e.Paths), e.Kind, strings.Join(e.Paths, ", "))
}

// CheckWrite returns an *UncoveredError when any of paths — concrete paths a
// render is about to emit — is not a registered write path. The renderer calls
// it on every node's path set before emitting (Rendered=False/RegisterUncovered).
func CheckWrite(paths []string) error {
	return checkWriteAgainst(paths, WriteEntries())
}

func checkWriteAgainst(paths []string, entries []WriteEntry) error {
	reg := make(map[string]bool, len(entries))
	for _, e := range entries {
		reg[e.Path] = true
	}
	if u := uncovered(paths, reg); len(u) > 0 {
		return &UncoveredError{Kind: "write", Paths: u}
	}
	return nil
}

// Validate checks the register itself: every entry native or justified, no
// justification on a native entry, no duplicate pattern, every pattern already
// normalized, and every subscribed entry carrying a metric name, labels and a
// stream mode.
func Validate() error {
	var errs []string
	seen := map[string]bool{}
	for _, e := range WriteEntries() {
		errs = append(errs, validateCommon("write", e.Path, e.Model, e.Justification, seen)...)
		if Normalize(e.Path) != e.Path {
			errs = append(errs, fmt.Sprintf("write %s: not a normalized pattern", e.Path))
		}
		if len(e.Owners) == 0 {
			errs = append(errs, fmt.Sprintf("write %s: no owner", e.Path))
		}
		for _, o := range e.Owners {
			if o != OwnerFabric && o != OwnerService {
				errs = append(errs, fmt.Sprintf("write %s: owner %q", e.Path, o))
			}
		}
		if len(e.Constructs) == 0 {
			errs = append(errs, fmt.Sprintf("write %s: no construct", e.Path))
		}
	}
	seen = map[string]bool{}
	for _, e := range SubscribeEntries() {
		errs = append(errs, validateCommon("subscribe", e.Path, e.Model, e.Justification, seen)...)
		if e.Metric == "" || len(e.Labels) == 0 || e.Mode == "" || e.Subscription == "" || e.SampleInterval <= 0 {
			errs = append(errs, fmt.Sprintf("subscribe %s: metric, labels, mode, interval and subscription are required", e.Path))
		}
		if m := DeriveMetricName(e.Path); e.Metric != m {
			errs = append(errs, fmt.Sprintf("subscribe %s: metric %q is not the derived %q", e.Path, e.Metric, m))
		}
		if l := DeriveLabels(e.Path); strings.Join(e.Labels, ",") != strings.Join(l, ",") {
			errs = append(errs, fmt.Sprintf("subscribe %s: labels %v are not the derived %v", e.Path, e.Labels, l))
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("path register invalid:\n  %s", strings.Join(errs, "\n  "))
	}
	return nil
}

func validateCommon(kind, path string, m Model, just string, seen map[string]bool) []string {
	var errs []string
	if seen[path] {
		errs = append(errs, fmt.Sprintf("%s %s: duplicate", kind, path))
	}
	seen[path] = true
	switch {
	case m == Native && just != "":
		errs = append(errs, fmt.Sprintf("%s %s: a native path carries no justification", kind, path))
	case m != Native && strings.TrimSpace(just) == "":
		errs = append(errs, fmt.Sprintf("%s %s: model %q is an exception to the native default and needs a justification", kind, path, m))
	}
	return errs
}
