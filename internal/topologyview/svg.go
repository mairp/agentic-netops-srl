package topologyview

import (
	"bytes"
	"fmt"
	"html"
	"math"
	"strings"
)

// CellIDPreamble is the flow panel's cellIdPreamble: an SVG element id is the panel cell key
// prefixed with it (clab-io-draw writes the same preamble into the panel YAML).
const CellIDPreamble = "cell-"

// RenderSVG draws the canonical diagram as the flow panel's SVG. clab-io-draw 0.7.1 does not
// export SVG itself (it logs "Grafana SVG export skipped. Export … manually using draw.io"), so
// the diagram it laid out is rendered here, keeping its geometry, styles and node icons, with
// every cell as a <g id="cell-<id>"> the panel YAML's cell keys address:
//
//	cell-<node>                          node icon + name
//	cell-<node>:<if>:<peer>:<peerif>     port on <node> (oper-state fill)
//	cell-mid:<a>:<if>:<b>:<if>           link midpoint
//	cell-link_id:<node>:<if>:<peer>:<if> directed half-link, port → midpoint (rate stroke + label)
//
// Group cells carry no drawing and are omitted. provenance goes into a leading XML comment.
func RenderSVG(d *Diagram, provenance string) []byte {
	byID := map[string]*Cell{}
	for i := range d.Cells {
		byID[d.Cells[i].ID] = &d.Cells[i]
	}
	var abs func(c *Cell, depth int) (float64, float64)
	abs = func(c *Cell, depth int) (float64, float64) {
		p, ok := byID[c.Parent]
		if !ok || !p.Vertex || depth > 16 {
			return c.X, c.Y
		}
		px, py := abs(p, depth+1)
		return px + c.X, py + c.Y
	}
	center := func(id string) (float64, float64, bool) {
		c, ok := byID[id]
		if !ok || !c.Vertex {
			return 0, 0, false
		}
		x, y := abs(c, 0)
		return x + c.W/2, y + c.H/2, true
	}

	minX, minY, maxX, maxY := math.Inf(1), math.Inf(1), math.Inf(-1), math.Inf(-1)
	for i := range d.Cells {
		c := &d.Cells[i]
		if !c.Vertex || hasKey(c.Style, "group") {
			continue
		}
		x, y := abs(c, 0)
		minX, minY = math.Min(minX, x), math.Min(minY, y)
		maxX, maxY = math.Max(maxX, x+c.W), math.Max(maxY, y+c.H)
	}
	if math.IsInf(minX, 1) {
		minX, minY, maxX, maxY = 0, 0, 1, 1
	}
	const margin = 80.0
	vx, vy := minX-margin, minY-margin
	vw, vh := maxX-minX+2*margin, maxY-minY+2*margin

	var edges, mids, nodes, ports bytes.Buffer
	for i := range d.Cells {
		c := &d.Cells[i]
		id := html.EscapeString(CellIDPreamble + c.ID)
		switch {
		case c.Edge:
			sx, sy, ok1 := center(c.Source)
			tx, ty, ok2 := center(c.Target)
			if !ok1 || !ok2 {
				continue
			}
			fmt.Fprintf(&edges, "  <g id=\"%s\">\n    <path d=\"M %s %s L %s %s\" fill=\"none\" stroke=\"%s\" stroke-width=\"%s\" stroke-miterlimit=\"10\"/>\n",
				id, f(sx), f(sy), f(tx), f(ty), color(c.Style["strokeColor"], "#98A2AE"), orDefault(c.Style["strokeWidth"], "1"))
			if lbl := strings.TrimSpace(c.Label); lbl != "" {
				mx, my := (sx+tx)/2, (sy+ty)/2
				fmt.Fprintf(&edges, "    <text x=\"%s\" y=\"%s\" fill=\"%s\" font-family=\"Helvetica\" font-size=\"%s\" text-anchor=\"middle\" dominant-baseline=\"middle\" fill-opacity=\"%s\">%s</text>\n",
					f(mx), f(my), color(c.Style["fontColor"], "#FFFFFF"), orDefault(c.Style["fontSize"], "11"), opacity(c.Style["textOpacity"]), html.EscapeString(c.Label))
			}
			edges.WriteString("  </g>\n")
		case !c.Vertex || hasKey(c.Style, "group"):
			continue
		case c.Style["shape"] == "image":
			x, y := abs(c, 0)
			img := c.Style["image"]
			if strings.HasPrefix(img, "data:image/svg+xml,") {
				img = "data:image/svg+xml;base64," + strings.TrimPrefix(img, "data:image/svg+xml,")
			}
			fmt.Fprintf(&nodes, "  <g id=\"%s\">\n    <image x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" preserveAspectRatio=\"xMidYMid meet\" href=\"%s\"/>\n",
				id, f(x), f(y), f(c.W), f(c.H), html.EscapeString(img))
			// labelPosition=left + verticalLabelPosition=top + align=right: above-left of the icon
			fmt.Fprintf(&nodes, "    <text x=\"%s\" y=\"%s\" fill=\"%s\" font-family=\"Helvetica\" font-size=\"12\" text-anchor=\"end\">%s</text>\n  </g>\n",
				f(x-2), f(y-2), color(c.Style["fontColor"], "#FFFFFF"), html.EscapeString(c.Label))
		case hasKey(c.Style, "ellipse"):
			x, y := abs(c, 0)
			buf := &ports
			if strings.HasPrefix(c.ID, "mid:") {
				buf = &mids
			}
			fmt.Fprintf(buf, "  <g id=\"%s\">\n    <ellipse cx=\"%s\" cy=\"%s\" rx=\"%s\" ry=\"%s\" fill=\"%s\" stroke=\"%s\"/>\n",
				id, f(x+c.W/2), f(y+c.H/2), f(c.W/2), f(c.H/2), color(c.Style["fillColor"], "#BEC8D2"), color(c.Style["strokeColor"], "none"))
			if lbl := strings.TrimSpace(strings.ReplaceAll(c.Label, "​", "")); lbl != "" && !hasKey(c.Style, "noLabel") {
				fmt.Fprintf(buf, "    <text x=\"%s\" y=\"%s\" fill=\"%s\" font-family=\"Helvetica\" font-size=\"%s\" text-anchor=\"middle\" dominant-baseline=\"central\">%s</text>\n",
					f(x+c.W/2), f(y+c.H/2), color(c.Style["fontColor"], "#FFFFFF"), orDefault(c.Style["fontSize"], "8"), html.EscapeString(lbl))
			}
			buf.WriteString("  </g>\n")
		}
	}

	var b bytes.Buffer
	b.WriteString("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
	if provenance != "" {
		fmt.Fprintf(&b, "<!-- %s -->\n", strings.ReplaceAll(provenance, "--", "- -"))
	}
	fmt.Fprintf(&b, "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" version=\"1.1\" width=\"%s\" height=\"%s\" viewBox=\"%s %s %s %s\">\n",
		f(vw), f(vh), f(vx), f(vy), f(vw), f(vh))
	b.Write(edges.Bytes())
	b.Write(mids.Bytes())
	b.Write(nodes.Bytes())
	b.Write(ports.Bytes())
	b.WriteString("</svg>\n")
	return b.Bytes()
}

func hasKey(m map[string]string, k string) bool { _, ok := m[k]; return ok }

func orDefault(v, d string) string {
	if v == "" {
		return d
	}
	return v
}

func color(v, d string) string {
	if v == "" || v == "default" {
		return d
	}
	return v
}

// opacity turns draw.io's 0–100 textOpacity into SVG's 0–1.
func opacity(v string) string {
	if v == "" {
		return "1"
	}
	return f(num(v) / 100)
}

func f(v float64) string {
	s := fmt.Sprintf("%.2f", v)
	s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	if s == "-0" {
		return "0"
	}
	return s
}
