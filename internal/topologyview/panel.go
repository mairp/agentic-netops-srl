package topologyview

import (
	"bytes"
	"fmt"
	"strings"

	yamlv3 "sigs.k8s.io/yaml/goyaml.v3"
)

// The flow panel's Prometheus queries build every dataRef from their legend format, and the
// legend formats name exactly the two join labels. The dashboard carrying the panel (T130/T132)
// uses these; clab-io-draw 0.7.1 emits the same three in its dashboard JSON.
const (
	LegendOperState = "oper-state:{{source}}:{{interface_name}}"
	LegendOut       = "{{source}}:{{interface_name}}:out"
	LegendIn        = "{{source}}:{{interface_name}}:in"
)

// RewritePanel takes clab-io-draw's flow-panel YAML and puts it on the join: every cell key and
// dataRef is canonicalized (CanonicalID), and the cells whose dataRef reads a client's interface
// are dropped — clients are not telemetry devices, no series carries their `source`, and a dataRef
// no query can produce would only ever render as "no data". The leaf-side cells of the client
// links stay (their dataRef is the leaf's access port). Anchors, thresholds and label
// configuration are kept as clab-io-draw wrote them.
func RewritePanel(b []byte, inv *Inventory, provenance string) ([]byte, error) {
	var doc yamlv3.Node
	if err := yamlv3.Unmarshal(b, &doc); err != nil {
		return nil, fmt.Errorf("panel: %w", err)
	}
	if doc.Kind != yamlv3.DocumentNode || len(doc.Content) != 1 || doc.Content[0].Kind != yamlv3.MappingNode {
		return nil, fmt.Errorf("panel: not a YAML mapping")
	}
	root := doc.Content[0]
	if v := mapGet(root, "cellIdPreamble"); v == nil || v.Value != CellIDPreamble {
		return nil, fmt.Errorf("panel: cellIdPreamble is not %q", CellIDPreamble)
	}
	cells := mapGet(root, "cells")
	if cells == nil || cells.Kind != yamlv3.MappingNode {
		return nil, fmt.Errorf("panel: no cells mapping")
	}
	var kept []*yamlv3.Node
	for i := 0; i+1 < len(cells.Content); i += 2 {
		k, v := cells.Content[i], cells.Content[i+1]
		k.Value = inv.CanonicalID(k.Value)
		dr := mapGet(v, "dataRef")
		if dr == nil {
			return nil, fmt.Errorf("panel: cell %s has no dataRef", k.Value)
		}
		dr.Value = inv.CanonicalID(dr.Value)
		ref, err := ParseDataRef(dr.Value)
		if err != nil {
			return nil, fmt.Errorf("panel: cell %s: %w", k.Value, err)
		}
		if !inv.IsDevice(ref.Source) {
			continue
		}
		kept = append(kept, k, v)
	}
	cells.Content = kept
	if provenance != "" {
		doc.HeadComment = provenance
	}
	var out bytes.Buffer
	enc := yamlv3.NewEncoder(&out)
	enc.SetIndent(2)
	if err := enc.Encode(&doc); err != nil {
		return nil, fmt.Errorf("panel: %w", err)
	}
	if err := enc.Close(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

func mapGet(m *yamlv3.Node, key string) *yamlv3.Node {
	if m == nil || m.Kind != yamlv3.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(m.Content); i += 2 {
		if m.Content[i].Value == key {
			return m.Content[i+1]
		}
	}
	return nil
}

// DataRef is a parsed flow-panel dataRef: the legend it instantiates and the two join labels.
type DataRef struct {
	Legend, Source, Interface string
}

// ParseDataRef matches a dataRef against the three legend formats; anything else is an error.
func ParseDataRef(s string) (DataRef, error) {
	t := strings.Split(s, ":")
	switch {
	case len(t) == 3 && t[0] == "oper-state":
		return DataRef{Legend: LegendOperState, Source: t[1], Interface: t[2]}, nil
	case len(t) == 3 && t[2] == "out":
		return DataRef{Legend: LegendOut, Source: t[0], Interface: t[1]}, nil
	case len(t) == 3 && t[2] == "in":
		return DataRef{Legend: LegendIn, Source: t[0], Interface: t[1]}, nil
	}
	return DataRef{}, fmt.Errorf("dataRef %q is not one of %q, %q, %q", s, LegendOperState, LegendOut, LegendIn)
}

// PanelCell is one cell of a panel YAML.
type PanelCell struct{ Key, DataRef string }

// ParsePanel reads a panel YAML's preamble and cells (aliases resolved).
func ParsePanel(b []byte) (preamble string, cells []PanelCell, err error) {
	var doc yamlv3.Node
	if err := yamlv3.Unmarshal(b, &doc); err != nil {
		return "", nil, fmt.Errorf("panel: %w", err)
	}
	if len(doc.Content) != 1 {
		return "", nil, fmt.Errorf("panel: empty")
	}
	root := doc.Content[0]
	if v := mapGet(root, "cellIdPreamble"); v != nil {
		preamble = v.Value
	}
	cm := mapGet(root, "cells")
	if cm == nil || cm.Kind != yamlv3.MappingNode {
		return "", nil, fmt.Errorf("panel: no cells mapping")
	}
	for i := 0; i+1 < len(cm.Content); i += 2 {
		c := PanelCell{Key: cm.Content[i].Value}
		if dr := mapGet(cm.Content[i+1], "dataRef"); dr != nil {
			c.DataRef = dr.Value
		}
		cells = append(cells, c)
	}
	return preamble, cells, nil
}
