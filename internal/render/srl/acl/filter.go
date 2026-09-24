package acl

import (
	"fmt"

	"github.com/mairp/agentic-netops-srl/internal/model"
)

// Render builds the /acl subtree of one node's service document: every filter
// the node carries and every /acl/interface[interface-id] entry — the
// interface-ref where this Config owns the subinterface, the input|output
// acl-filter[name][type] bindings where it binds a filter. It returns nil when
// the node renders no /acl leaf, and a refusal naming the offending object
// when the node carries something the device would refuse or that would bind
// nothing (package comment).
func Render(n *model.ServiceNode) (Container, error) {
	filters := newList("name", "type")
	byKey := map[string]*model.ACLFilter{}
	for i := range n.ACLFilters {
		f := &n.ACLFilters[i]
		c, err := renderFilter(f)
		if err != nil {
			return nil, err
		}
		k := filterKey(f.Name, f.Type)
		if byKey[k] != nil {
			return nil, fmt.Errorf("acl-filter %q type %s rendered twice", f.Name, f.Type)
		}
		byKey[k] = f
		filters.add(c)
	}
	ifs, err := renderInterfaces(n, byKey)
	if err != nil {
		return nil, err
	}
	out := Container{}
	if len(filters.Entries) > 0 {
		out["acl-filter"] = filters
	}
	if len(ifs.Entries) > 0 {
		out["interface"] = ifs
	}
	if len(out) == 0 {
		return nil, nil
	}
	return out, nil
}

// renderFilter builds /acl/acl-filter[name][type]: its description,
// statistics-per-entry (always true — without it no per-entry counter exists,
// and the read-back's A5 has nothing to read), subinterface-specific when set
// (output-only on egress), and its entries.
func renderFilter(f *model.ACLFilter) (Container, error) {
	if err := ValidateFilterRef(f.Name, f.Type); err != nil {
		return nil, err
	}
	if !f.StatisticsPerEntry {
		return nil, fmt.Errorf("acl-filter %q type %s: statistics-per-entry must be true on every rendered filter (per-entry counters)", f.Name, f.Type)
	}
	c := Container{"name": f.Name, "type": string(f.Type), "statistics-per-entry": true}
	if f.Description != "" {
		if len(f.Description) > 255 {
			return nil, fmt.Errorf("acl-filter %q: description longer than 255 characters", f.Name)
		}
		c["description"] = f.Description
	}
	switch f.SubinterfaceSpecific {
	case "":
	case OutputOnly, InputAndOutput:
		c["subinterface-specific"] = f.SubinterfaceSpecific
	default:
		return nil, fmt.Errorf("acl-filter %q: subinterface-specific %q is not rendered (output-only or input-and-output)", f.Name, f.SubinterfaceSpecific)
	}
	if len(f.Entries) == 0 {
		return nil, fmt.Errorf("acl-filter %q type %s has no entry", f.Name, f.Type)
	}
	entries := newList("sequence-id")
	seen := map[uint32]bool{}
	for _, e := range f.Entries {
		if seen[e.SequenceID] {
			return nil, fmt.Errorf("acl-filter %q: two entries at sequence-id %d", f.Name, e.SequenceID)
		}
		seen[e.SequenceID] = true
		ec, err := renderEntry(f, e)
		if err != nil {
			return nil, err
		}
		entries.add(ec)
	}
	c["entry"] = entries
	return c, nil
}

func filterKey(name string, typ model.Family) string { return name + "\x00" + string(typ) }
