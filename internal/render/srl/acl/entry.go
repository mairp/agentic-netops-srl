package acl

import (
	"fmt"
	"net/netip"

	"github.com/mairp/agentic-netops-srl/internal/model"
)

// Entry sequence-id bounds: rules 1–65534; 65535 is the reserved terminal
// match-all default-action entry (FR-040, FR-041).
const (
	minSequenceID = 1
	maxSequenceID = model.DefaultActionSequenceID
)

// renderEntry builds entry[sequence-id] of a filter: the sequence-id (the
// operator's priority, unchanged), the description (the rule's name), the
// match (the family container, transport ports) and the action presence
// container.
func renderEntry(f *model.ACLFilter, e model.ACLEntry) (Container, error) {
	if e.SequenceID < minSequenceID || e.SequenceID > maxSequenceID {
		return nil, fmt.Errorf("acl-filter %q entry sequence-id %d outside %d..%d", f.Name, e.SequenceID, minSequenceID, maxSequenceID-1)
	}
	var act string
	switch e.Action {
	case model.ActionAccept, model.ActionDrop:
		act = string(e.Action)
	default:
		return nil, fmt.Errorf("acl-filter %q entry %d: action %q is neither accept nor drop", f.Name, e.SequenceID, e.Action)
	}
	c := Container{"sequence-id": e.SequenceID, "action": Container{act: Container{}}}
	if e.Description != "" {
		c["description"] = e.Description
	}
	match, err := MatchTree(f, e)
	if err != nil {
		return nil, err
	}
	if match != nil {
		if e.SequenceID == model.DefaultActionSequenceID {
			return nil, fmt.Errorf("acl-filter %q entry 65535 carries a match: 65535 is reserved for the match-all default action", f.Name)
		}
		c["match"] = match
	}
	return c, nil
}

// MatchTree is the rendered match container of entry e of filter f, or nil
// for a match-all entry. The read-back (internal/verify) compares the running
// datastore against exactly these values.
func MatchTree(f *model.ACLFilter, e model.ACLEntry) (Container, error) {
	fam := Container{}
	protoLeaf := "protocol"
	if f.Type == model.FamilyIPv6 {
		protoLeaf = "next-header"
	}
	var proto any
	if e.Protocol != "" {
		v, err := ProtocolValue(e.Protocol)
		if err != nil {
			return nil, fmt.Errorf("acl-filter %q entry %d: %w", f.Name, e.SequenceID, err)
		}
		proto = v
		fam[protoLeaf] = v
	}
	for leaf, p := range map[string]string{"source-ip": e.SourcePrefix, "destination-ip": e.DestinationPrefix} {
		if p == "" {
			continue
		}
		pf, err := netip.ParsePrefix(p)
		if err != nil {
			return nil, fmt.Errorf("acl-filter %q entry %d: %q is not a prefix", f.Name, e.SequenceID, p)
		}
		if pf.Addr().Is4() != (f.Type == model.FamilyIPv4) {
			return nil, fmt.Errorf("acl-filter %q entry %d: prefix %q is not in the filter's address family %s", f.Name, e.SequenceID, p, f.Type)
		}
		fam[leaf] = Container{"prefix": p}
	}
	transport := Container{}
	for leaf, pm := range map[string]*model.PortMatch{"source-port": e.SourcePort, "destination-port": e.DestinationPort} {
		if pm == nil {
			continue
		}
		if !isTCPOrUDP(proto) {
			return nil, fmt.Errorf("acl-filter %q entry %d: a %s match needs protocol TCP or UDP (the device refuses a port on any other), protocol is %q",
				f.Name, e.SequenceID, leaf, e.Protocol)
		}
		if pm.Hi != 0 {
			if pm.Hi < pm.Lo {
				return nil, fmt.Errorf("acl-filter %q entry %d: %s range %d-%d", f.Name, e.SequenceID, leaf, pm.Lo, pm.Hi)
			}
			transport[leaf] = Container{"range": Container{"start": uint32(pm.Lo), "end": uint32(pm.Hi)}}
		} else {
			transport[leaf] = Container{"operator": "eq", "value": uint32(pm.Lo)}
		}
	}
	if len(fam) == 0 && len(transport) == 0 {
		return nil, nil
	}
	m := Container{}
	if len(fam) > 0 {
		m[string(f.Type)] = fam
	}
	if len(transport) > 0 {
		m["transport"] = transport
	}
	return m, nil
}
