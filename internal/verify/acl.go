package verify

// The access-list read-back (T108; contracts/acl-render-contract.md §4.1–§4.4
// as reconciled by live finding 2026-09-21-acl-binding-state,
// docs/decisions/live-findings.md; data-model.md §13; FR-042, FR-100, R-26).
//
// It is part of VerifyService — a Network carrying accessLists (a service's
// own list or a standalone `acl`) is Ready only when every check below holds
// on every node it binds, and the Ready=False message names the filter, its
// type, the entry and the direction that failed. Every read is keyed by THIS
// filter's name and type (and entry sequence-id); a device-wide or fabric-wide
// count is never evidence — the ~80 control-plane (`cpm`) entries of a stock
// node satisfy nothing here, because no path names them.
//
// Gate, once per node carrying a filter (state):
//
//	G1 /acl/datapath-programming/forwarding-complex[slot-id=*][complex-id=*]/programming-complete
//	   reads true on every forwarding complex (and on at least one)
//
// Written side (the node's running datastore, as the layer holds it):
//
//	C1 /acl/acl-filter[name=F][type=T] exists
//	C2 …/entry[sequence-id=S]/action/{accept|drop}   the declared action, per rendered rule
//	C3 …/entry[sequence-id=S]/match/…                 each rendered match leaf, equal
//	C4 …/entry[sequence-id=65535]/action/…            whenever a default action was declared
//	C5 /acl/interface[interface-id=IF.IDX]/interface-ref/{interface,subinterface} of a bound
//	   subinterface — only where THIS Config owns it (a standalone list does not, AD-68)
//	C6 /acl/interface[interface-id=IF.IDX]/<dir>/acl-filter[name=F][type=T] in the declared
//	   direction, and not in the other. SR Linux 25.7.1 mirrors no part of /acl/interface into
//	   state, so the binding is judged here, in running (live finding 2026-09-21-acl-binding-state)
//	C7 /acl/acl-filter[name=F][type=T]/subinterface-specific, when stage egress
//
// Applied side (state, the device metric collector — AD-82), per rendered entry
// S of each filter F/T bound on the node, including 65535:
//
//	A1 …/entry[sequence-id=S]/tcam-entries/forwarding-complex[complex-identifier=*]/single-instance
//	   > 0 on at least one complex (the entry is programmable)
//	A2 the same path's input-total (bound input) / output-total (bound output) > 0 on at least
//	   one complex — this filter is bound in the declared direction and this entry occupies
//	   real forwarding-table space there
//	A3 the opposite direction's total == 0 on every complex — not bound where the operator did
//	   not ask
//	A5 …/entry[sequence-id=S]/statistics/matched-packets readable, and
//	   …/statistics/incomplete not true (no complex ran out of statistics resources)
//
// A4 — the device's own per-subinterface entry list under
// /acl/interface[…]/<dir>/acl-filter[…]/entry — is NOT judged: 25.7.1 does not
// mirror it into state (the live finding above), so it is recorded by the
// acceptance suites (tests/gate/lib/checks.sh chk_acl_applied's OBSERVATION) and
// never read here. Readiness never depends on matched-packets' VALUE — a
// correctly programmed filter on a quiet link has zero matches (FR-042);
// counter movement is acceptance (SC-041), never readiness.

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/render/srl/acl"
)

// Access-list read-back checks. A missing one reads NotConverged, except an
// entry the device reports costing no TCAM on the declared direction, which is
// CheckNotProgrammed (NotProgrammed).
const (
	CheckACLProgramming Check = "acl-programming-complete" // G1
	CheckACLFilter      Check = "acl-filter"               // C1, C7
	CheckACLEntry       Check = "acl-entry"                // C2, C3, C4
	CheckACLBinding     Check = "acl-binding"              // C5, C6
	CheckACLProgrammed  Check = "acl-entry-programmed"     // A1, A2
	CheckACLDirection   Check = "acl-direction"            // A3
	CheckACLStatistics  Check = "acl-statistics"           // A5
)

// ---------------------------------------------------------------------------
// Paths — every one keyed by this filter's name and type (and entry).
// ---------------------------------------------------------------------------

// ACLProgrammingCompletePath is the G1 gate: every forwarding complex's
// programming-complete.
func ACLProgrammingCompletePath() string {
	return "/acl/datapath-programming/forwarding-complex[slot-id=*][complex-id=*]/programming-complete"
}

// ACLFilterPath is /acl/acl-filter[name=<F>][type=<T>].
func ACLFilterPath(name string, typ model.Family) string {
	return "/acl/acl-filter[name=" + name + "][type=" + string(typ) + "]"
}

// ACLEntryPath is /acl/acl-filter[name=<F>][type=<T>]/entry[sequence-id=<S>].
func ACLEntryPath(name string, typ model.Family, seq uint32) string {
	return fmt.Sprintf("%s/entry[sequence-id=%d]", ACLFilterPath(name, typ), seq)
}

// ACLTCAMPath is …/entry[sequence-id=<S>]/tcam-entries/forwarding-complex[complex-identifier=*]/<leaf>,
// leaf one of single-instance, input-total, output-total.
func ACLTCAMPath(name string, typ model.Family, seq uint32, leaf string) string {
	return ACLEntryPath(name, typ, seq) + "/tcam-entries/forwarding-complex[complex-identifier=*]/" + leaf
}

// ACLStatisticsPath is …/entry[sequence-id=<S>]/statistics/<leaf>.
func ACLStatisticsPath(name string, typ model.Family, seq uint32, leaf string) string {
	return ACLEntryPath(name, typ, seq) + "/statistics/" + leaf
}

// ACLInterfacePath is /acl/interface[interface-id=<IF.IDX>].
func ACLInterfacePath(ifid string) string { return "/acl/interface[interface-id=" + ifid + "]" }

// ACLBindingPath is /acl/interface[interface-id=<IF.IDX>]/<input|output>/acl-filter[name=<F>][type=<T>].
func ACLBindingPath(ifid string, dir acl.Direction, name string, typ model.Family) string {
	return ACLInterfacePath(ifid) + "/" + string(dir) + "/acl-filter[name=" + name + "][type=" + string(typ) + "]"
}

// ---------------------------------------------------------------------------
// Applied side.
// ---------------------------------------------------------------------------

type aclBound struct {
	filter *model.ACLFilter
	dirs   map[acl.Direction][]string // direction -> interface-ids
}

// boundFilters are the node's filters with the directions (and subinterfaces)
// the node binds each one in, sorted by name and type.
func boundFilters(n *model.ServiceNode) []aclBound {
	var out []aclBound
	for i := range n.ACLFilters {
		f := &n.ACLFilters[i]
		b := aclBound{filter: f, dirs: map[acl.Direction][]string{}}
		for _, ai := range n.ACLInterfaces {
			for _, d := range []struct {
				dir  acl.Direction
				refs []model.FilterRef
			}{{acl.Input, ai.Input}, {acl.Output, ai.Output}} {
				for _, r := range d.refs {
					if r.Name == f.Name && r.Type == f.Type {
						b.dirs[d.dir] = append(b.dirs[d.dir], ai.InterfaceID)
					}
				}
			}
		}
		out = append(out, b)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].filter.Name != out[j].filter.Name {
			return out[i].filter.Name < out[j].filter.Name
		}
		return out[i].filter.Type < out[j].filter.Type
	})
	return out
}

func filterLabel(f *model.ACLFilter) string {
	return fmt.Sprintf("acl-filter %s type %s", f.Name, f.Type)
}

// aclExpectations are the applied-side leaves of the access lists on node n:
// the G1 gate once, then A1, A2, A3 and A5 per rendered entry of each bound
// filter. A node carrying no filter gets none.
func aclExpectations(n *model.ServiceNode) []StateExpectation {
	bound := boundFilters(n)
	if len(bound) == 0 {
		return nil
	}
	out := []StateExpectation{{Check: CheckACLProgramming,
		What: "ACL datapath programming (every forwarding complex)",
		Path: ACLProgrammingCompletePath(), Want: "true", Expect: ExpectAllEqual}}
	for _, b := range bound {
		f := b.filter
		for _, e := range f.Entries {
			what := fmt.Sprintf("%s entry %d", filterLabel(f), e.SequenceID)
			out = append(out, StateExpectation{Check: CheckACLProgrammed, What: what + " (programmable, TCAM single-instance)",
				Path: ACLTCAMPath(f.Name, f.Type, e.SequenceID, "single-instance"), Expect: ExpectAnyPositive})
			for _, dir := range []acl.Direction{acl.Input, acl.Output} {
				total := ACLTCAMPath(f.Name, f.Type, e.SequenceID, string(dir)+"-total")
				switch {
				case len(b.dirs[dir]) > 0:
					out = append(out, StateExpectation{Check: CheckACLProgrammed,
						What: fmt.Sprintf("%s bound %s on %s (TCAM %s-total)", what, dir, strings.Join(b.dirs[dir], ","), dir),
						Path: total, Expect: ExpectAnyPositive})
				case len(b.dirs[acl.Input])+len(b.dirs[acl.Output]) > 0:
					out = append(out, StateExpectation{Check: CheckACLDirection,
						What: fmt.Sprintf("%s not bound %s (TCAM %s-total)", what, dir, dir),
						Path: total, Expect: ExpectAllZero})
				}
			}
			out = append(out,
				StateExpectation{Check: CheckACLStatistics, What: what + " statistics (matched-packets readable; its value is never judged)",
					Path: ACLStatisticsPath(f.Name, f.Type, e.SequenceID, "matched-packets"), Expect: ExpectPresent},
				StateExpectation{Check: CheckACLStatistics, What: what + " statistics complete",
					Path: ACLStatisticsPath(f.Name, f.Type, e.SequenceID, "incomplete"), Want: "true", Expect: ExpectNotEqual})
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// Written side.
// ---------------------------------------------------------------------------

// aclWritten runs C1–C7 for node n against its running datastore and returns
// the missing invariants and the configuration paths read.
func aclWritten(n *model.ServiceNode, running any) ([]Invariant, []string) {
	var missing []Invariant
	var paths []string
	miss := func(c Check, format string, a ...any) {
		missing = append(missing, Invariant{Node: n.Node, Check: c, Detail: fmt.Sprintf(format, a...)})
	}
	for _, b := range boundFilters(n) {
		f := b.filter
		fp := ACLFilterPath(f.Name, f.Type)
		paths = append(paths, fp)
		if !configPresent(running, fp) { // C1
			miss(CheckACLFilter, "%s: %s absent from the running datastore", filterLabel(f), fp)
			continue
		}
		if f.SubinterfaceSpecific != "" { // C7
			p := fp + "/subinterface-specific"
			paths = append(paths, p)
			if vals := ConfigValues(running, p); !contains(vals, f.SubinterfaceSpecific) {
				miss(CheckACLFilter, "%s: %s reads %s, want %s", filterLabel(f), p, show(vals), f.SubinterfaceSpecific)
			}
		}
		for _, e := range f.Entries {
			ep := ACLEntryPath(f.Name, f.Type, e.SequenceID)
			what := fmt.Sprintf("%s entry %d", filterLabel(f), e.SequenceID)
			if e.SequenceID == model.DefaultActionSequenceID {
				what += " (the declared default action)"
			}
			ap := ep + "/action/" + string(e.Action)
			paths = append(paths, ap)
			if !configPresent(running, ap) { // C2, C4
				miss(CheckACLEntry, "%s: %s absent from the running datastore", what, ap)
			}
			match, err := acl.MatchTree(f, e)
			if err != nil {
				miss(CheckACLEntry, "%s: %v", what, err)
				continue
			}
			for _, l := range flattenMatch("match", match) { // C3
				p := ep + "/" + l.path
				paths = append(paths, p)
				if vals := ConfigValues(running, p); !contains(vals, l.value) {
					miss(CheckACLEntry, "%s: %s reads %s, want %s", what, p, show(vals), l.value)
				}
			}
		}
		for _, dir := range []acl.Direction{acl.Input, acl.Output} { // C6
			other := acl.Output
			if dir == acl.Output {
				other = acl.Input
			}
			for _, ifid := range b.dirs[dir] {
				bp := ACLBindingPath(ifid, dir, f.Name, f.Type)
				paths = append(paths, bp)
				if !configPresent(running, bp) {
					miss(CheckACLBinding, "%s: not bound %s on %s — %s absent from the running datastore", filterLabel(f), dir, ifid, bp)
				}
				if len(b.dirs[other]) == 0 {
					op := ACLBindingPath(ifid, other, f.Name, f.Type)
					paths = append(paths, op)
					if configPresent(running, op) {
						miss(CheckACLBinding, "%s: bound %s on %s, a direction not declared (%s present)", filterLabel(f), other, ifid, op)
					}
				}
			}
		}
	}
	// C5 — on a bound subinterface, only where this Config owns it (the
	// interface-ref of an owned subinterface no filter binds is part of the
	// rendered document, which the written side reads back whole)
	for _, ai := range n.ACLInterfaces {
		if ai.Ref == nil || len(ai.Input)+len(ai.Output) == 0 {
			continue
		}
		base := ACLInterfacePath(ai.InterfaceID) + "/interface-ref/"
		for leaf, want := range map[string]string{"interface": ai.Ref.Interface, "subinterface": strconv.FormatUint(uint64(ai.Ref.Subinterface), 10)} {
			p := base + leaf
			paths = append(paths, p)
			if vals := ConfigValues(running, p); !contains(vals, want) {
				miss(CheckACLBinding, "acl interface %s: %s reads %s, want %s", ai.InterfaceID, p, show(vals), want)
			}
		}
	}
	sort.Slice(missing, func(i, j int) bool { return missing[i].Detail < missing[j].Detail })
	return missing, paths
}

type matchLeaf struct{ path, value string }

// flattenMatch turns the rendered match tree into relative leaf paths and
// their values as a JSON document reads back (numbers in decimal).
func flattenMatch(prefix string, c acl.Container) []matchLeaf {
	var out []matchLeaf
	keys := make([]string, 0, len(c))
	for k := range c {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		p := prefix + "/" + k
		if sub, ok := c[k].(acl.Container); ok {
			out = append(out, flattenMatch(p, sub)...)
			continue
		}
		out = append(out, matchLeaf{path: p, value: fmt.Sprint(c[k])})
	}
	return out
}

// configPresent reports whether path names at least one node of the
// configuration document — a leaf, a presence container ({}), or a list entry
// — matching object keys by local name and list keys by value (identityrefs
// by local name), as ConfigValues does.
func configPresent(doc any, path string) bool {
	cur := []any{doc}
	for _, el := range splitPathElems(path) {
		name, keys := parseElem(el)
		var next []any
		for _, c := range cur {
			v, ok := lookupOK(asMap(c), name)
			if !ok {
				continue
			}
			if arr, isList := v.([]any); isList {
				for _, e := range arr {
					if m := asMap(e); m != nil && keysMatch(m, keys) {
						next = append(next, e)
					}
				}
				continue
			}
			if len(keys) == 0 {
				next = append(next, v)
			}
		}
		cur = next
		if len(cur) == 0 {
			return false
		}
	}
	return len(cur) > 0
}

// ---------------------------------------------------------------------------
// Judging the access-list expectation kinds (StateExpectation.evaluate).
// ---------------------------------------------------------------------------

func parseCount(v string) (int64, bool) {
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return 0, false
	}
	return int64(f), true
}

// evaluateACL judges the expectation kinds the access-list read-back adds.
func (e StateExpectation) evaluateACL(vals []string) (Check, string, bool) {
	switch e.Expect {
	case ExpectAllEqual:
		if len(vals) == 0 {
			return e.Check, fmt.Sprintf("%s: %s reads nothing, want %s on every instance", e.What, e.Path, e.Want), false
		}
		for _, v := range vals {
			if v != e.Want && localName(v) != e.Want {
				return e.Check, fmt.Sprintf("%s: %s reads %s, want %s on every instance", e.What, e.Path, show(vals), e.Want), false
			}
		}
	case ExpectAnyPositive:
		if len(vals) == 0 {
			return e.Check, fmt.Sprintf("%s: %s reads nothing, want > 0 on at least one forwarding complex", e.What, e.Path), false
		}
		for _, v := range vals {
			if n, ok := parseCount(v); ok && n > 0 {
				return "", "", true
			}
		}
		return CheckNotProgrammed, fmt.Sprintf("%s: %s reads %s, want > 0 on at least one forwarding complex", e.What, e.Path, show(vals)), false
	case ExpectAllZero:
		for _, v := range vals {
			if n, ok := parseCount(v); !ok || n != 0 {
				return e.Check, fmt.Sprintf("%s: %s reads %s, want 0 on every forwarding complex", e.What, e.Path, show(vals)), false
			}
		}
	case ExpectPresent:
		if len(vals) == 0 {
			return e.Check, fmt.Sprintf("%s: %s reads nothing, want a readable value", e.What, e.Path), false
		}
	case ExpectNotEqual:
		if contains(vals, e.Want) {
			return e.Check, fmt.Sprintf("%s: %s reads %s, want not %s", e.What, e.Path, show(vals), e.Want), false
		}
	}
	return "", "", true
}
