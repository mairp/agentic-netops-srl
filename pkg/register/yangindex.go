package register

// The YANG index (T128, research §Open items 9): the schema nodes of the
// PINNED device models (versions.lock.yaml part 2) that the subscription
// register reaches, written by `go run ./hack/yangindex` into
// testdata/yang-index-v25.7.1.json and committed, so the guard re-validates the
// register offline. From it the guard derives what the pipeline exports for a
// path — the metric name, the label names, each key's type class — and holds
// the register's recorded values to it (CheckIndex).

import (
	"fmt"
	"strings"
)

// YangIndexSchema is the index document's schema identifier.
const YangIndexSchema = "agentic-netops.register.yang-index/v1"

// YangIndex is the committed index document.
type YangIndex struct {
	Schema     string `json:"schema"`
	Repository string `json:"repository"`
	Tag        string `json:"tag"`
	Commit     string `json:"commit"`
	Generator  string `json:"generator"`
	// Paths maps every subscribed register path to the schema nodes it reaches.
	Paths map[string]IndexedPath `json:"paths"`
}

// IndexedPath is one register path resolved in the schema.
type IndexedPath struct {
	// Elements are the schema elements of the path, in order.
	Elements []IndexElem `json:"elements"`
	// Kind is the last element's kind: leaf, container or list.
	Kind string `json:"kind"`
	// Type is a leaf's type.
	Type *YangType `json:"type,omitempty"`
	// Leaves are, for a container or list, every leaf beneath it.
	Leaves []IndexedLeaf `json:"leaves,omitempty"`
	// Lists are, for a container or list, the lists beneath it (relative
	// paths) — refused by the guard: a nested list's keys would be flattened
	// into value names, not labels.
	Lists []string `json:"lists,omitempty"`
}

// IndexElem is one schema element: its name, the module that instantiates it
// (RFC 7951 §4: the namespace a JSON_IETF member name is qualified with) and,
// for a list, its keys in YANG order.
type IndexElem struct {
	Name   string     `json:"name"`
	Module string     `json:"module"`
	Keys   []IndexKey `json:"keys,omitempty"`
}

// IndexKey is one list key leaf.
type IndexKey struct {
	Name string   `json:"name"`
	Type YangType `json:"type"`
}

// YangType is a leaf's type: the typedef (or built-in) name, its resolved
// base kind, a union's members and an enumeration's values.
type YangType struct {
	Name    string     `json:"name"`
	Base    string     `json:"base"`
	Members []YangType `json:"members,omitempty"`
	Enums   []string   `json:"enums,omitempty"`
}

// IndexedLeaf is a leaf beneath a container path: its path relative to it.
type IndexedLeaf struct {
	Path []IndexElem `json:"path"`
	Type YangType    `json:"type"`
}

// qualify joins elements with `/`, prefixing an element with its module where
// the module differs from its parent's (RFC 7951 §4) — the value path gNMIc
// builds from a JSON_IETF notification.
func qualify(elems []IndexElem, parentModule string) string {
	var b strings.Builder
	for i, e := range elems {
		if i > 0 {
			b.WriteByte('/')
		}
		if e.Module != parentModule {
			b.WriteString(e.Module + ":")
			parentModule = e.Module
		}
		b.WriteString(e.Name)
	}
	return b.String()
}

// MetricFromValuePath is gNMIc's OTLP metric name for a value path with the
// output settings G7 recorded (metric-prefix "", append-subscription-name
// false, strip-leading-underscore true): leading `/` dropped, `/` and `-` to
// `_` (gNMIc v0.47.0 otlp buildMetricName). The collector's Prometheus exporter
// (UnderscoreEscapingWithoutSuffixes) keeps `:` and adds no suffix, so this is
// the exported series name.
func MetricFromValuePath(v string) string {
	return strings.NewReplacer("/", "_", "-", "_").Replace(strings.TrimPrefix(v, "/"))
}

// ValuePath is the gNMIc event value name of a leaf path, or of a container
// path (the prefix of its leaves' value names).
func (p IndexedPath) ValuePath() string { return "/" + qualify(p.Elements, "") }

// MetricName is the exported series name (leaf) or name prefix (container).
func (p IndexedPath) MetricName() string { return MetricFromValuePath(p.ValuePath()) }

func (p IndexedPath) lastModule() string {
	if len(p.Elements) == 0 {
		return ""
	}
	return p.Elements[len(p.Elements)-1].Module
}

// LeafValuePaths maps every exported leaf's gNMIc value name to its type: the
// path itself for a leaf, each leaf beneath for a container or list — a list
// path's own key leaves excepted: they are its labels.
func (p IndexedPath) LeafValuePaths() map[string]YangType {
	out := map[string]YangType{}
	if p.Kind == "leaf" {
		if p.Type != nil {
			out[p.ValuePath()] = *p.Type
		}
		return out
	}
	keys := map[string]bool{}
	if p.Kind == "list" {
		for _, k := range p.Elements[len(p.Elements)-1].Keys {
			keys[k.Name] = true
		}
	}
	for _, l := range p.Leaves {
		if len(l.Path) == 1 && keys[l.Path[0].Name] {
			continue
		}
		out[p.ValuePath()+"/"+qualify(l.Path, p.lastModule())] = l.Type
	}
	return out
}

// PathLabels are the labels gNMIc derives from the path: `<list>_<key>` per
// schema key of every list on it, in order, `-` to `_` (evidence/06 §1.4) —
// written or not in the subscription path.
func (p IndexedPath) PathLabels() []string {
	var out []string
	for _, e := range p.Elements {
		for _, k := range e.Keys {
			out = append(out, labelName(e.Name, k.Name))
		}
	}
	return out
}

func labelName(elem, key string) string { return strings.ReplaceAll(elem+"_"+key, "-", "_") }

// KeyClass is the value class of a list key, from its YANG type.
type KeyClass string

const (
	// ClassFixed — the subscription path fixes the key's value.
	ClassFixed KeyClass = "fixed"
	// ClassClosed — enumeration, identityref or boolean: a closed value set.
	ClassClosed KeyClass = "closed"
	// ClassNumber — an integer.
	ClassNumber KeyClass = "number"
	// ClassAddress — an IP address.
	ClassAddress KeyClass = "address"
	// ClassPrefix — an IP prefix or a route distinguisher.
	ClassPrefix KeyClass = "prefix"
	// ClassText — any other string: a free-form name.
	ClassText KeyClass = "text"
)

// Class classifies a type. Every class but ClassClosed is free-form in the
// schema: unbounded unless a lab bound justifies it.
func (t YangType) Class() KeyClass {
	switch t.Base {
	case "enumeration", "identityref", "boolean":
		return ClassClosed
	case "union":
		classes := map[KeyClass]bool{}
		for _, m := range t.Members {
			classes[m.Class()] = true
		}
		for _, c := range []KeyClass{ClassPrefix, ClassAddress, ClassText, ClassNumber} {
			if classes[c] {
				return c
			}
		}
		if len(classes) == 1 && classes[ClassClosed] {
			return ClassClosed
		}
		return ClassText
	}
	n := strings.ToLower(t.Name)
	switch {
	case strings.Contains(n, "prefix") || strings.Contains(n, "route-distinguisher"):
		return ClassPrefix
	case strings.Contains(n, "address"):
		return ClassAddress
	case strings.HasPrefix(t.Base, "int") || strings.HasPrefix(t.Base, "uint"):
		return ClassNumber
	}
	return ClassText
}

// boundAdmits is which key classes each bound can justify.
var boundAdmits = map[Bound][]KeyClass{
	BoundSchema:      {ClassFixed, ClassClosed},
	BoundInventory:   {ClassText, ClassNumber},
	BoundIntent:      {ClassText, ClassNumber, ClassAddress, ClassPrefix},
	BoundFabricPeers: {ClassAddress, ClassNumber},
	BoundLabRoutes:   {ClassText, ClassNumber, ClassAddress, ClassPrefix},
}

// JSONString reports whether JSON_IETF encodes a value of this type as a JSON
// string (RFC 7951 §6): gNMIc's OTLP output drops every string value, so such a
// leaf is exported only when a collector processor converts it to a number.
func (t YangType) JSONString() bool {
	switch t.Base {
	case "int8", "int16", "int32", "uint8", "uint16", "uint32", "boolean", "empty":
		return false
	}
	return true
}

// CheckIndex holds entries to the YANG index: every path is in the pinned
// models; every key the path writes is a schema key; the recorded metric name
// is the derived one; the label set is closed — exactly the path-derived labels
// in order, then the pipeline labels — and bounded — every label's bound admits
// its key's class; and no container path holds a list. It returns one message
// per violation.
func CheckIndex(entries []SubscribeEntry, idx *YangIndex) []string {
	var errs []string
	for _, e := range entries {
		p, ok := idx.Paths[e.Path]
		if !ok {
			errs = append(errs, fmt.Sprintf("subscribe %s: not in the YANG index of %s@%s — the path is not in the pinned models (regenerate with hack/yangindex)", e.Path, idx.Tag, idx.Commit))
			continue
		}
		written := SplitPath(e.Path)
		if len(written) != len(p.Elements) {
			errs = append(errs, fmt.Sprintf("subscribe %s: %d elements, the index has %d", e.Path, len(written), len(p.Elements)))
			continue
		}
		classes := map[string]KeyClass{}
		for i, w := range written {
			se := p.Elements[i]
			if w.Name != se.Name {
				errs = append(errs, fmt.Sprintf("subscribe %s: element %s is %s in the index", e.Path, w.Name, se.Name))
			}
			schemaKeys := map[string]YangType{}
			for _, k := range se.Keys {
				schemaKeys[k.Name] = k.Type
				c := k.Type.Class()
				if v, fixed := w.Keys[k.Name]; fixed && v != "*" {
					c = ClassFixed
				}
				classes[labelName(se.Name, k.Name)] = c
			}
			for k := range w.Keys {
				if _, ok := schemaKeys[k]; !ok {
					errs = append(errs, fmt.Sprintf("subscribe %s: %s has no key %s in the pinned models", e.Path, se.Name, k))
				}
			}
		}
		if m := p.MetricName(); e.Metric != m {
			errs = append(errs, fmt.Sprintf("subscribe %s: metric %q is not the derived %q", e.Path, e.Metric, m))
		}
		want := append(p.PathLabels(), "source", "subscription_name")
		if got := e.LabelNames(); strings.Join(got, ",") != strings.Join(want, ",") {
			errs = append(errs, fmt.Sprintf("subscribe %s: label set %v is not the closed derived set %v", e.Path, got, want))
		}
		for _, l := range e.Labels {
			c, pathLabel := classes[l.Name]
			if !pathLabel {
				continue // a pipeline label, or unlisted (reported above)
			}
			admitted := false
			for _, a := range boundAdmits[l.Bound] {
				admitted = admitted || a == c
			}
			if !admitted {
				errs = append(errs, fmt.Sprintf("subscribe %s: label %s (%s key) is unbounded: bound %q does not justify it (R-09)", e.Path, l.Name, c, l.Bound))
			}
		}
		if p.Kind != "leaf" {
			if len(p.Lists) > 0 {
				errs = append(errs, fmt.Sprintf("subscribe %s: the %s holds the list(s) %v — subscribe their leaves by their own keyed paths", e.Path, p.Kind, p.Lists))
			}
			if len(p.Leaves) == 0 {
				errs = append(errs, fmt.Sprintf("subscribe %s: the %s holds no leaf", e.Path, p.Kind))
			}
		}
	}
	return errs
}
