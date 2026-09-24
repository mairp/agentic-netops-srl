package topologyview

import (
	"bytes"
	"compress/flate"
	"encoding/base64"
	"encoding/xml"
	"fmt"
	"io"
	"net/url"
	"strconv"
	"strings"
)

// Cell is one mxGraph cell of the clab-io-draw diagram, with the id and endpoints already
// canonicalized (Canonical).
type Cell struct {
	ID, Label, Parent, Source, Target string
	Style                             map[string]string
	Vertex, Edge                      bool
	X, Y, W, H                        float64
}

// Diagram is the parsed .drawio (first page) in document order.
type Diagram struct{ Cells []Cell }

type mxFile struct {
	Diagrams []struct {
		Inner []byte `xml:",innerxml"`
	} `xml:"diagram"`
}

// mxItem is either an <mxCell> or an <object>/<UserObject> wrapping one.
type mxItem struct {
	XMLName xml.Name
	Attrs   []xml.Attr `xml:",any,attr"`
	Cell    *mxItem    `xml:"mxCell"`
	Geo     *struct {
		X      string `xml:"x,attr"`
		Y      string `xml:"y,attr"`
		Width  string `xml:"width,attr"`
		Height string `xml:"height,attr"`
	} `xml:"mxGeometry"`
}

func (m *mxItem) attr(k string) string {
	for _, a := range m.Attrs {
		if a.Name.Local == k {
			return a.Value
		}
	}
	return ""
}

// ParseDrawio reads a .drawio file: plain mxGraphModel XML, or the compressed form (the diagram
// text is base64 of raw-deflated, URL-encoded XML).
func ParseDrawio(b []byte) (*Diagram, error) {
	var f mxFile
	if err := xml.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("drawio: %w", err)
	}
	if len(f.Diagrams) == 0 {
		return nil, fmt.Errorf("drawio: no <diagram>")
	}
	model := bytes.TrimSpace(f.Diagrams[0].Inner)
	if !bytes.HasPrefix(model, []byte("<")) {
		raw, err := base64.StdEncoding.DecodeString(string(model))
		if err != nil {
			return nil, fmt.Errorf("drawio: compressed diagram: %w", err)
		}
		inflated, err := io.ReadAll(flate.NewReader(bytes.NewReader(raw)))
		if err != nil {
			return nil, fmt.Errorf("drawio: compressed diagram: %w", err)
		}
		s, err := url.QueryUnescape(string(inflated))
		if err != nil {
			return nil, fmt.Errorf("drawio: compressed diagram: %w", err)
		}
		model = []byte(s)
	}
	var g struct {
		Root struct {
			Items []mxItem `xml:",any"`
		} `xml:"root"`
	}
	if err := xml.Unmarshal(model, &g); err != nil {
		return nil, fmt.Errorf("drawio: mxGraphModel: %w", err)
	}
	d := &Diagram{}
	for i := range g.Root.Items {
		it := &g.Root.Items[i]
		c := Cell{ID: it.attr("id")}
		cell := it
		if it.XMLName.Local != "mxCell" {
			c.Label = it.attr("label")
			if it.Cell == nil {
				return nil, fmt.Errorf("drawio: <%s id=%q> has no mxCell", it.XMLName.Local, c.ID)
			}
			cell = it.Cell
		} else {
			c.Label = it.attr("value")
		}
		c.Parent, c.Source, c.Target = cell.attr("parent"), cell.attr("source"), cell.attr("target")
		c.Vertex, c.Edge = cell.attr("vertex") == "1", cell.attr("edge") == "1"
		c.Style = parseStyle(cell.attr("style"))
		if cell.Geo != nil {
			c.X, c.Y, c.W, c.H = num(cell.Geo.X), num(cell.Geo.Y), num(cell.Geo.Width), num(cell.Geo.Height)
		}
		d.Cells = append(d.Cells, c)
	}
	return d, nil
}

func num(s string) float64 { v, _ := strconv.ParseFloat(s, 64); return v }

func parseStyle(s string) map[string]string {
	m := map[string]string{}
	for _, kv := range strings.Split(s, ";") {
		if kv == "" {
			continue
		}
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			m[kv] = ""
			continue
		}
		m[k] = v
	}
	return m
}

// CanonicalID rewrites a clab-io-draw id onto the join: every node token loses clab-io-draw's
// container-name decoration ("clab-<lab>-leaf01" → "leaf01", "group-clab-<lab>-leaf01" →
// "group-leaf01") and every interface token is normalized ("ethernet-1/49" → "e1-49"), so
// "link_id:clab-<lab>-leaf01:ethernet-1/49:clab-<lab>-spine01:ethernet-1/1" becomes
// "link_id:leaf01:e1-49:spine01:e1-1". Tokens are ':'-separated; neither node names nor
// interface names contain ':'.
func (inv *Inventory) CanonicalID(id string) string {
	marker := inv.drawioMarker()
	toks := strings.Split(id, ":")
	for i, t := range toks {
		if marker != "" {
			switch {
			case strings.HasPrefix(t, marker):
				t = strings.TrimPrefix(t, marker)
			case strings.HasPrefix(t, "group-"+marker):
				t = "group-" + strings.TrimPrefix(t, "group-"+marker)
			}
		}
		toks[i] = NormalizeInterface(t)
	}
	return strings.Join(toks, ":")
}

// Canonical returns the diagram with every id, parent, source and target canonicalized.
func (d *Diagram) Canonical(inv *Inventory) *Diagram {
	out := &Diagram{Cells: make([]Cell, len(d.Cells))}
	for i, c := range d.Cells {
		c.ID, c.Parent = inv.CanonicalID(c.ID), inv.CanonicalID(c.Parent)
		c.Source, c.Target = inv.CanonicalID(c.Source), inv.CanonicalID(c.Target)
		out.Cells[i] = c
	}
	return out
}
