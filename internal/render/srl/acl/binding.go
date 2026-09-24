package acl

import (
	"fmt"
	"strings"

	"github.com/mairp/agentic-netops-srl/internal/model"
)

// renderInterfaces builds /acl/interface[interface-id=<port>.<idx>] for every
// ACLInterface of the node: interface-ref {interface, subinterface} only when
// this Config owns the subinterface (Ref set — the model sets it for every
// owned subinterface, AD-68), and the key-only
// input|output/acl-filter[name][type] entry of every filter bound there.
//
// The renderer guard of contracts/acl-render-contract.md §6: one filter of an
// address family per subinterface per direction (the exclusivity unit
// (node, port, subinterface, direction, family), FR-043); a binding names a
// filter this document renders (the binding's name leaf is a leafref); an
// egress binding's filter carries subinterface-specific output-only or
// input-and-output (the device's egress must); interface-ref agrees with the
// interface-id it sits under.
func renderInterfaces(n *model.ServiceNode, filters map[string]*model.ACLFilter) (*List, error) {
	out := newList("interface-id")
	seen := map[string]bool{}
	for _, ai := range n.ACLInterfaces {
		if ai.InterfaceID == "" {
			return nil, fmt.Errorf("acl interface without an interface-id on %s", n.Node)
		}
		if seen[ai.InterfaceID] {
			return nil, fmt.Errorf("acl interface %s rendered twice on %s", ai.InterfaceID, n.Node)
		}
		seen[ai.InterfaceID] = true
		e := Container{"interface-id": ai.InterfaceID}
		if ai.Ref != nil {
			if id := InterfaceID(ai.Ref.Interface, ai.Ref.Subinterface); id != ai.InterfaceID {
				return nil, fmt.Errorf("acl interface %s: interface-ref names %s", ai.InterfaceID, id)
			}
			e["interface-ref"] = Container{"interface": ai.Ref.Interface, "subinterface": ai.Ref.Subinterface}
		}
		for _, d := range []struct {
			dir  Direction
			refs []model.FilterRef
		}{{Input, ai.Input}, {Output, ai.Output}} {
			if len(d.refs) == 0 {
				continue
			}
			l, err := renderBinding(n.Node, ai.InterfaceID, d.dir, d.refs, filters)
			if err != nil {
				return nil, err
			}
			e[string(d.dir)] = Container{"acl-filter": l}
		}
		if len(e) == 1 {
			continue // neither owned nor bound: nothing to write
		}
		out.add(e)
	}
	return out, nil
}

func renderBinding(node, ifid string, dir Direction, refs []model.FilterRef, filters map[string]*model.ACLFilter) (*List, error) {
	l := newList("name", "type")
	byFamily := map[model.Family][]string{}
	for _, r := range refs {
		if err := ValidateFilterRef(r.Name, r.Type); err != nil {
			return nil, err
		}
		f := filters[filterKey(r.Name, r.Type)]
		if f == nil {
			return nil, fmt.Errorf("%s %s %s binds acl-filter %q type %s, which this Config does not render (the binding would name no filter)",
				node, ifid, dir, r.Name, r.Type)
		}
		if dir == Output && f.SubinterfaceSpecific != OutputOnly && f.SubinterfaceSpecific != InputAndOutput {
			return nil, fmt.Errorf("%s %s output binds acl-filter %q type %s without subinterface-specific %s or %s (the device refuses an egress filter without it)",
				node, ifid, r.Name, r.Type, OutputOnly, InputAndOutput)
		}
		byFamily[r.Type] = append(byFamily[r.Type], r.Name)
		l.add(Container{"name": r.Name, "type": string(r.Type)})
	}
	for fam, names := range byFamily {
		if len(names) > 1 {
			return nil, fmt.Errorf("%s %s %s: %d %s filters (%s) — the device accepts one filter of an address family per subinterface per direction",
				node, ifid, dir, len(names), fam, strings.Join(names, ", "))
		}
	}
	return l, nil
}
