package topologyview

import (
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
)

// Assets are the generated artefacts Parity holds against the inventory.
type Assets struct {
	Targets, SVG, Panel, Rules []byte
	// MgmtCIDR, when set, also holds every target address to the inventory's host offset in it.
	MgmtCIDR string
}

// Parity checks that every generated artefact names exactly what the inventory names (SC-036):
//
//   - the gNMIc target list's node set is the inventory's devices (at their addresses);
//   - the SVG's node cells are the inventory's nodes, and every inventory link is drawn in both
//     directions (port cell and link_id cell) with normalized interface names, and nothing else;
//   - the panel YAML's cells all exist in the SVG, every dataRef instantiates one of the three
//     legends built from exactly `source` and `interface_name`, its source is a device and its
//     interface a normalized inventory endpoint of that device, and every device-side port of
//     every inventory link is addressed in both roles (oper-state and rate);
//   - the recording rules carry one node_info per node and one fabric_link_info per direction of
//     each device↔device link, and nothing else.
//
// All violations are returned together.
func Parity(inv *Inventory, a Assets) error {
	var errs []error
	fail := func(format string, args ...any) { errs = append(errs, fmt.Errorf(format, args...)) }

	devices := map[string]bool{}
	nodes := map[string]bool{}
	for _, n := range inv.Nodes {
		nodes[n.Name] = true
		if n.Device() {
			devices[n.Name] = true
		}
	}
	// endpoints[<node>:<normalized if>]
	endpoints := map[string]bool{}
	links := map[string]DirectedLink{}
	for _, l := range inv.AllDirectedLinks() {
		endpoints[l.Source+":"+l.Interface] = true
		links[l.CellKey()] = l
	}

	// 1. target list
	ts, err := ParseTargets(a.Targets)
	if err != nil {
		fail("targets: %v", err)
	}
	got := map[string]bool{}
	for _, t := range ts {
		if got[t.Name] {
			fail("targets: %s listed twice", t.Name)
		}
		got[t.Name] = true
	}
	diffSets("targets vs inventory devices", got, devices, fail)
	if a.MgmtCIDR != "" && err == nil {
		want, werr := Targets(inv, a.MgmtCIDR)
		if werr != nil {
			fail("targets: %v", werr)
		}
		at := map[string]string{}
		for _, t := range ts {
			at[t.Name] = t.Address.String()
		}
		for _, w := range want {
			if g, ok := at[w.Name]; ok && g != w.Address.String() {
				fail("targets: %s at %s, inventory offset in %s gives %s", w.Name, g, a.MgmtCIDR, w.Address)
			}
		}
	}

	// 2. SVG
	ids, err := svgCellIDs(a.SVG)
	if err != nil {
		fail("svg: %v", err)
	}
	svgNodes := map[string]bool{}
	for id := range ids {
		switch {
		case !strings.Contains(id, ":"):
			svgNodes[id] = true
		case strings.HasPrefix(id, "link_id:"):
			if _, ok := links[strings.TrimPrefix(id, "link_id:")]; !ok {
				fail("svg: link cell %q is not an inventory link", id)
			}
		case strings.HasPrefix(id, "mid:"):
			if _, ok := links[strings.TrimPrefix(id, "mid:")]; !ok {
				fail("svg: midpoint cell %q is not an inventory link", id)
			}
		default:
			if _, ok := links[id]; !ok {
				fail("svg: port cell %q is not an inventory link endpoint", id)
			}
		}
	}
	diffSets("svg nodes vs inventory nodes", svgNodes, nodes, fail)
	for _, l := range inv.AllDirectedLinks() {
		for _, want := range []string{l.CellKey(), "link_id:" + l.CellKey()} {
			if !ids[want] {
				fail("svg: link %s:%s → %s:%s missing cell %q", l.Source, l.Interface, l.PeerSource, l.PeerInterface, CellIDPreamble+want)
			}
		}
	}

	// 3. panel YAML
	pre, cells, err := ParsePanel(a.Panel)
	if err != nil {
		fail("panel: %v", err)
	}
	if err == nil && pre != CellIDPreamble {
		fail("panel: cellIdPreamble %q, want %q", pre, CellIDPreamble)
	}
	panelKeys := map[string]bool{}
	panelSources := map[string]bool{}
	for _, c := range cells {
		panelKeys[c.Key] = true
		if !ids[c.Key] {
			fail("panel: cell %q has no SVG element %q", c.Key, CellIDPreamble+c.Key)
		}
		ref, rerr := ParseDataRef(c.DataRef)
		if rerr != nil {
			fail("panel: cell %q: %v", c.Key, rerr)
			continue
		}
		panelSources[ref.Source] = true
		if !devices[ref.Source] {
			fail("panel: cell %q dataRef %q: source %q is not an inventory device", c.Key, c.DataRef, ref.Source)
		}
		if NormalizeInterface(ref.Interface) != ref.Interface {
			fail("panel: cell %q dataRef %q: interface %q is not normalized", c.Key, c.DataRef, ref.Interface)
		}
		if !endpoints[ref.Source+":"+ref.Interface] {
			fail("panel: cell %q dataRef %q: %s:%s is not an inventory link endpoint", c.Key, c.DataRef, ref.Source, ref.Interface)
		}
		// the key's own port is what the dataRef reads
		key := strings.TrimPrefix(c.Key, "link_id:")
		if l, ok := links[key]; !ok || l.Source != ref.Source || l.Interface != ref.Interface {
			fail("panel: cell %q dataRef %q reads another port than the cell's", c.Key, c.DataRef)
		}
	}
	diffSets("panel dataRef sources vs inventory devices", panelSources, devices, fail)
	for _, l := range inv.AllDirectedLinks() {
		if !devices[l.Source] {
			continue
		}
		for _, want := range []string{l.CellKey(), "link_id:" + l.CellKey()} {
			if !panelKeys[want] {
				fail("panel: link %s:%s → %s:%s missing cell %q", l.Source, l.Interface, l.PeerSource, l.PeerInterface, want)
			}
		}
	}

	// 4. recording rules
	rules, err := ParseRules(a.Rules)
	if err != nil {
		fail("rules: %v", err)
	}
	gotNodes := map[string]bool{}
	gotLinks := map[string]bool{}
	for _, r := range rules {
		if r.Group != RulesGroup {
			fail("rules: group %q, want %q", r.Group, RulesGroup)
		}
		if strings.TrimSpace(r.Expr) != "vector(1)" {
			fail("rules: %s%v expr %q, want vector(1)", r.Record, r.Labels, r.Expr)
		}
		switch r.Record {
		case NodeInfoSeries:
			if !sameKeys(r.Labels, "source", "role") {
				fail("rules: %s labels %v, want exactly source, role", r.Record, r.Labels)
			}
			gotNodes[r.Labels["source"]+"/"+r.Labels["role"]] = true
		case FabricLinkSeries:
			if !sameKeys(r.Labels, "source", "interface_name", "peer_source", "peer_interface") {
				fail("rules: %s labels %v, want exactly source, interface_name, peer_source, peer_interface", r.Record, r.Labels)
			}
			gotLinks[r.Labels["source"]+":"+r.Labels["interface_name"]+":"+r.Labels["peer_source"]+":"+r.Labels["peer_interface"]] = true
		default:
			fail("rules: unexpected record %q", r.Record)
		}
	}
	wantNodes := map[string]bool{}
	for _, n := range inv.Nodes {
		wantNodes[n.Name+"/"+n.Role] = true
	}
	wantLinks := map[string]bool{}
	for _, l := range inv.FabricLinks() {
		wantLinks[l.CellKey()] = true
	}
	diffSets("rules node_info vs inventory nodes", gotNodes, wantNodes, fail)
	diffSets("rules fabric_link_info vs inventory fabric links", gotLinks, wantLinks, fail)

	return errors.Join(errs...)
}

func sameKeys(m map[string]string, keys ...string) bool {
	if len(m) != len(keys) {
		return false
	}
	for _, k := range keys {
		if _, ok := m[k]; !ok {
			return false
		}
	}
	return true
}

func diffSets(what string, got, want map[string]bool, fail func(string, ...any)) {
	var missing, extra []string
	for k := range want {
		if !got[k] {
			missing = append(missing, k)
		}
	}
	for k := range got {
		if !want[k] {
			extra = append(extra, k)
		}
	}
	sort.Strings(missing)
	sort.Strings(extra)
	if len(missing) > 0 {
		fail("%s: missing %v", what, missing)
	}
	if len(extra) > 0 {
		fail("%s: extra %v", what, extra)
	}
}

// svgCellIDs returns the ids (preamble stripped) of every SVG element whose id carries the
// panel's cell preamble.
func svgCellIDs(b []byte) (map[string]bool, error) {
	ids := map[string]bool{}
	dec := xml.NewDecoder(bytes.NewReader(b))
	for {
		tok, err := dec.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		se, ok := tok.(xml.StartElement)
		if !ok {
			continue
		}
		for _, at := range se.Attr {
			if at.Name.Local == "id" && strings.HasPrefix(at.Value, CellIDPreamble) {
				ids[strings.TrimPrefix(at.Value, CellIDPreamble)] = true
			}
		}
	}
	if len(ids) == 0 {
		return nil, fmt.Errorf("no %q element ids", CellIDPreamble)
	}
	return ids, nil
}
