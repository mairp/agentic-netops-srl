package fabric

import (
	"fmt"
	"sort"
	"strings"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/pkg/kuid"
)

// intent is the Fabric spec resolved into what the reconciler claims and
// renders: nodes, reflectors, derived links and the declared tagging modes.
type intent struct {
	nodes      []fabricv1.FabricNode
	nodeSet    map[string]fabricv1.FabricNode
	leaves     []string
	spines     []string
	reflectors map[string]bool
	links      []linkPlan
	// untagged[node][port] is the declared tagging mode of an access port:
	// true when listed in untaggedAccessPorts (AD-68).
	access   map[string]map[string]bool
	families []model.AddressFamily
}

// linkPlan is one leaf–spine link before its /31 is claimed.
type linkPlan struct {
	Leaf, LeafPort, Spine, SpinePort string
}

// ClaimSuffix is the link's claim-name suffix: a DNS-subdomain rendition of
// both ends ("/" becomes "-").
func (l linkPlan) ClaimSuffix() string {
	r := strings.NewReplacer("/", "-", "_", "-")
	return "link." + r.Replace(l.Leaf+"-"+l.LeafPort) + "." + r.Replace(l.Spine+"-"+l.SpinePort)
}

// analyse resolves the spec. Its errors are InvalidIntent: terminal until a new
// generation.
func analyse(f *fabricv1.Fabric) (*intent, error) {
	in := &intent{nodeSet: map[string]fabricv1.FabricNode{}, reflectors: map[string]bool{}, access: map[string]map[string]bool{}}
	for _, n := range f.Spec.Nodes {
		name := string(n.Name)
		if _, dup := in.nodeSet[name]; dup {
			return nil, fmt.Errorf("spec.nodes: %s declared twice", name)
		}
		if strings.Contains(name, ".") {
			return nil, fmt.Errorf("spec.nodes: %s contains a dot, which mis-targets a generated Config", name)
		}
		in.nodeSet[name] = n
		in.nodes = append(in.nodes, n)
		switch n.Role {
		case fabricv1.NodeRoleLeaf:
			in.leaves = append(in.leaves, name)
		case fabricv1.NodeRoleSpine:
			in.spines = append(in.spines, name)
			if n.RouteReflector != nil && *n.RouteReflector {
				in.reflectors[name] = true
			}
		}
	}
	if len(in.leaves) == 0 || len(in.spines) == 0 {
		return nil, fmt.Errorf("spec.nodes: a fabric needs at least one leaf and one spine")
	}
	for _, r := range f.Spec.Overlay.RouteReflectors {
		n, ok := in.nodeSet[string(r)]
		if !ok {
			return nil, fmt.Errorf("spec.overlay.routeReflectors names %s, which is not in spec.nodes", r)
		}
		if n.Role != fabricv1.NodeRoleSpine {
			return nil, fmt.Errorf("spec.overlay.routeReflectors names %s, which is not a spine", r)
		}
		in.reflectors[string(r)] = true
	}
	sort.Strings(in.leaves)
	sort.Strings(in.spines)

	fabricPorts := map[string][]string{}
	for _, e := range f.Spec.Inventory {
		node := string(e.Node)
		if _, ok := in.nodeSet[node]; !ok {
			// An inventory entry for a node that left spec.nodes renders nothing.
			continue
		}
		modes := map[string]bool{}
		for _, p := range e.AccessPorts {
			modes[string(p)] = false
		}
		for _, p := range e.UntaggedAccessPorts {
			if _, ok := modes[string(p)]; !ok {
				return nil, fmt.Errorf("spec.inventory[%s].untaggedAccessPorts: %s is not one of its accessPorts", node, p)
			}
			modes[string(p)] = true
		}
		in.access[node] = modes
		for _, p := range e.FabricPorts {
			fabricPorts[node] = append(fabricPorts[node], string(p))
		}
	}
	links, err := deriveLinks(in.leaves, in.spines, fabricPorts)
	if err != nil {
		return nil, err
	}
	in.links = links

	for _, af := range f.Spec.Underlay.AddressFamilies {
		in.families = append(in.families, model.AddressFamily(af))
	}
	if f.Spec.Underlay.LoopbackPoolRef == nil {
		return nil, fmt.Errorf("spec.underlay.loopbackPoolRef is required: every system address is claimed from it, stated or not")
	}
	if f.Spec.Underlay.ASNPoolRef == nil {
		return nil, fmt.Errorf("spec.underlay.asnPoolRef is required: every underlay AS is claimed from it, stated or not")
	}
	if f.Spec.Underlay.LinkPoolRef == nil {
		return nil, fmt.Errorf("spec.underlay.linkPoolRef is required: every /31 link prefix is claimed from it")
	}
	var spineASN *int64
	for _, s := range in.spines {
		a := in.nodeSet[s].ASN
		if a == nil {
			continue
		}
		if spineASN != nil && *spineASN != *a {
			return nil, fmt.Errorf("spec.nodes[].asn: the spines state %d and %d; the spine AS is identical across spines", *spineASN, *a)
		}
		spineASN = a
	}
	return in, nil
}

// checkPoolRefs refuses a pool reference whose group and kind are not the index the
// installed allocation authority serves for that claim kind (T182). What it serves is
// read from the adapter (Claims.Index) — never a literal here — so the same Fabric names
// IPIndex/ASIndex under kuid and IdentifierPool under first-party. Its error is
// InvalidIntent, before any claim or Config write.
func checkPoolRefs(f *fabricv1.Fabric, claims kuid.Claims) error {
	u := f.Spec.Underlay
	var bad []string
	for _, ref := range []struct {
		field string
		ref   *fabricv1.PoolRef
		kind  kuid.Kind
	}{
		{"spec.underlay.loopbackPoolRef", u.LoopbackPoolRef, kuid.KindIP},
		{"spec.underlay.linkPoolRef", u.LinkPoolRef, kuid.KindIP},
		{"spec.underlay.asnPoolRef", u.ASNPoolRef, kuid.KindASN},
	} {
		if ref.ref == nil {
			continue
		}
		want := claims.Index(ref.kind)
		if ref.ref.Group != want.Group || ref.ref.Kind != want.Kind {
			bad = append(bad, fmt.Sprintf("%s names %s/%s, but the installed allocation authority (%s) serves %s claims from %s",
				ref.field, ref.ref.Group, ref.ref.Kind, claims.Authority(), ref.kind, want))
		}
	}
	if len(bad) > 0 {
		return fmt.Errorf("%s", strings.Join(bad, "; "))
	}
	return nil
}

// deriveLinks pairs the fabric ports into leaf–spine links. The rule is the
// lab topology's, stated once: the i-th fabric port of a leaf (inventory
// order) connects to the i-th spine (sorted by name), on that spine's j-th
// fabric port, where j is the leaf's position among the leaves (sorted by
// name) — leafNN ethernet-1/49 → spine01 ethernet-1/N, ethernet-1/50 →
// spine02 ethernet-1/N (brief "Links"; lab/topology.clab.yml).
func deriveLinks(leaves, spines []string, ports map[string][]string) ([]linkPlan, error) {
	var out []linkPlan
	for j, leaf := range leaves {
		lp := ports[leaf]
		if len(lp) < len(spines) {
			return nil, fmt.Errorf("spec.inventory[%s].fabricPorts: %d port(s) for %d spine(s); each leaf has one uplink per spine", leaf, len(lp), len(spines))
		}
		for i, spine := range spines {
			sp := ports[spine]
			if j >= len(sp) {
				return nil, fmt.Errorf("spec.inventory[%s].fabricPorts: %d port(s) for %d leaf/leaves; each spine has one downlink per leaf", spine, len(sp), len(leaves))
			}
			out = append(out, linkPlan{Leaf: leaf, LeafPort: lp[i], Spine: spine, SpinePort: sp[j]})
		}
	}
	return out, nil
}

// flipConflict is an access port whose declared mode differs from the mode a
// Network still attaches to it in.
type flipConflict struct {
	Node, Port string
	Declared   string
	Services   []string
}

// tagFlips returns every access port of the declaration whose tagging mode a
// Network still attaching to it would see flipped (AD-68): an attachment with
// no VLAN is untagged (subinterface 0), one with a VLAN is tagged. Networks
// are listed cluster-wide, a deleting one included — it still holds its
// subinterface until finalization.
func tagFlips(in *intent, networks []fabricv1.Network) []flipConflict {
	type key struct{ node, port string }
	holders := map[key]map[string]bool{}
	for i := range networks {
		nw := &networks[i]
		svc := nw.Namespace + "/" + nw.Name
		for _, a := range nw.Spec.Attachments {
			node, port := string(a.Node), string(a.Attachment)
			untagged, declared := in.access[node][port]
			if !declared {
				continue
			}
			attachedUntagged := a.VLAN == nil
			if attachedUntagged == untagged {
				continue
			}
			k := key{node, port}
			if holders[k] == nil {
				holders[k] = map[string]bool{}
			}
			holders[k][svc] = true
		}
	}
	var out []flipConflict
	for k, svcs := range holders {
		c := flipConflict{Node: k.node, Port: k.port, Declared: "tagged"}
		if in.access[k.node][k.port] {
			c.Declared = "untagged"
		}
		for s := range svcs {
			c.Services = append(c.Services, s)
		}
		sort.Strings(c.Services)
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Node != out[j].Node {
			return out[i].Node < out[j].Node
		}
		return out[i].Port < out[j].Port
	})
	return out
}

func flipMessage(cs []flipConflict) string {
	var parts []string
	for _, c := range cs {
		parts = append(parts, fmt.Sprintf("port %s %s would become %s while still attached by %s",
			c.Node, c.Port, c.Declared, strings.Join(c.Services, ", ")))
	}
	return "spec.inventory[].untaggedAccessPorts changes the tagging mode of an access port a Network still attaches to: " +
		strings.Join(parts, "; ") + " — the last rendered Config is left as it was (AD-68)"
}
