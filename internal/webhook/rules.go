package webhook

// The cross-object rules of contracts/crd-api.md §"Required Fabric and Network API", as pure
// functions over the candidate Network, the other Networks and the Fabric (T061). Each returns
// the refusals it finds, each one sentence naming what the operator needs to act on — the
// port, the holding service, the valid alternatives (CR-003). None of them arbitrates a VNI or
// a VLAN value: that is the allocation authority's, and nothing here duplicates it.

import (
	"fmt"
	"sort"
	"strings"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
)

// Rule names a row of the contract's rule table; it prefixes every refusal.
type Rule string

// The rows marked "webhook" in contracts/crd-api.md.
const (
	RuleResolvability       Rule = "AttachmentUnresolved"
	RuleOwner               Rule = "SubinterfaceOwned"
	RuleTaggingMode         Rule = "TaggingModeConflict"
	RuleBindingExclusivity  Rule = "BindingConflict"
	RuleStandaloneNeedsSubi Rule = "SubinterfaceMissing"
	RuleQualification       Rule = "Unqualified"
)

// Violation is one refusal: the rule and the sentence stating it.
type Violation struct {
	Rule    Rule
	Message string
}

func (v Violation) String() string { return string(v.Rule) + ": " + v.Message }

// Key renders a Network's identity as <namespace>/<name> — generateName when no name is set yet.
func Key(n *fabricv1.Network) string {
	name := n.Name
	if name == "" && n.GenerateName != "" {
		name = n.GenerateName + "*"
	}
	return n.Namespace + "/" + name
}

// StandaloneACL is an accessLists-only object (contracts/network-spec.md §2, shape acl): its
// attachments reference subinterfaces other Networks own; it owns none and holds no tagging
// mode (AD-47, AD-20).
func StandaloneACL(s *fabricv1.NetworkSpec) bool {
	return len(s.AccessLists) > 0 && len(s.VLANs) == 0 && len(s.BridgeDomains) == 0 && len(s.Routers) == 0
}

// subinterface is the (node, port, vlan) an attachment resolves to; vlan 0 is the untagged
// subinterface <port>.0.
type subinterface struct {
	node, port string
	vlan       int64
}

func subOf(a fabricv1.NetworkAttachment) subinterface {
	s := subinterface{node: string(a.Node), port: string(a.Attachment)}
	if a.VLAN != nil {
		s.vlan = int64(*a.VLAN)
	}
	return s
}

func (s subinterface) String() string { return fmt.Sprintf("%s %s.%d", s.node, s.port, s.vlan) }

func tagged(a fabricv1.NetworkAttachment) bool { return a.VLAN != nil }

func modeName(isTagged bool) string {
	if isTagged {
		return "tagged"
	}
	return "untagged"
}

// holderNote is what a refusal adds when the holder is being deleted: it still holds (AD-61).
func holderNote(n *fabricv1.Network, what string) string {
	if n.DeletionTimestamp == nil {
		return ""
	}
	return fmt.Sprintf(" (%s is being deleted and still holds its %s until its removal completes)", Key(n), what)
}

// ---------------------------------------------------------------------------------------------
// Attachment resolvability (CR-003, AD-68)

// Inventory is the Fabric's attachable surface: per node its role and access ports with the
// tagging mode the inventory declares for each.
type Inventory struct {
	// Found is false when no Fabric exists to resolve against.
	Found bool
	role  map[string]fabricv1.NodeRole
	// access maps node → port → declared untagged.
	access map[string]map[string]bool
}

// NewInventory merges the Fabrics of the system namespace (there is exactly one per fabric,
// data-model.md §1) into one Inventory.
func NewInventory(fabrics []fabricv1.Fabric) Inventory {
	inv := Inventory{Found: len(fabrics) > 0, role: map[string]fabricv1.NodeRole{}, access: map[string]map[string]bool{}}
	for i := range fabrics {
		f := &fabrics[i]
		for _, n := range f.Spec.Nodes {
			inv.role[string(n.Name)] = n.Role
		}
		for _, e := range f.Spec.Inventory {
			ports := inv.access[string(e.Node)]
			if ports == nil {
				ports = map[string]bool{}
				inv.access[string(e.Node)] = ports
			}
			for _, p := range e.AccessPorts {
				ports[string(p)] = false
			}
			for _, p := range e.UntaggedAccessPorts {
				if _, ok := ports[string(p)]; ok {
					ports[string(p)] = true
				}
			}
		}
	}
	return inv
}

// attachable says whether node is a leaf of spec.nodes with an inventory entry.
func (inv Inventory) attachable(node string) bool {
	_, listed := inv.access[node]
	return listed && inv.role[node] == fabricv1.NodeRoleLeaf
}

// PortsInMode lists, for every attachable node, the access ports the inventory declares in the
// given mode: "leaf01 [ethernet-1/1, ethernet-1/2], leaf02 [none]".
func (inv Inventory) PortsInMode(isTagged bool) string {
	var nodes []string
	for n := range inv.access {
		if inv.attachable(n) {
			nodes = append(nodes, n)
		}
	}
	sort.Strings(nodes)
	if len(nodes) == 0 {
		return "none (the Fabric inventory lists no leaf with access ports)"
	}
	parts := make([]string, 0, len(nodes))
	for _, n := range nodes {
		var ports []string
		for p, untagged := range inv.access[n] {
			if untagged != isTagged {
				ports = append(ports, p)
			}
		}
		sort.Strings(ports)
		list := "none"
		if len(ports) > 0 {
			list = strings.Join(ports, ", ")
		}
		parts = append(parts, fmt.Sprintf("%s [%s]", n, list))
	}
	return strings.Join(parts, ", ")
}

// CheckResolvable is the row "Attachment resolvability": every attachment names a leaf and an
// access port the Fabric inventory lists, never a spine, in the tagging mode the inventory
// declares for that port — an untagged attachment only on a port listed in
// untaggedAccessPorts, a tagged one only on a port that is not. Each refusal lists the ports
// declared in the mode that was asked for.
func CheckResolvable(cand *fabricv1.Network, inv Inventory, fabricNamespace string) []Violation {
	var out []Violation
	for _, a := range cand.Spec.Attachments {
		node, port, want := string(a.Node), string(a.Attachment), tagged(a)
		valid := func() string {
			return fmt.Sprintf("the access ports the Fabric inventory declares %s are: %s", modeName(want), inv.PortsInMode(want))
		}
		var msg string
		switch {
		case !inv.Found:
			msg = fmt.Sprintf("attachment %s %s cannot resolve: no Fabric exists in %s to resolve it against", node, port, fabricNamespace)
		case inv.role[node] == fabricv1.NodeRoleSpine:
			msg = fmt.Sprintf("attachment %s %s names a spine: an attachment is never on a spine; %s", node, port, valid())
		case !inv.attachable(node):
			msg = fmt.Sprintf("attachment %s %s names node %s, which is not a leaf of the Fabric inventory; %s", node, port, node, valid())
		default:
			untagged, ok := inv.access[node][port]
			switch {
			case !ok:
				msg = fmt.Sprintf("attachment %s %s names port %s, which is not an access port of %s in the Fabric inventory; %s", node, port, port, node, valid())
			case !want && !untagged:
				msg = fmt.Sprintf("untagged attachment %s %s: the Fabric inventory does not list %s in %s's untaggedAccessPorts, so it is a tagged port; %s", node, port, port, node, valid())
			case want && untagged:
				msg = fmt.Sprintf("tagged attachment %s %s (vlan %d): the Fabric inventory lists %s in %s's untaggedAccessPorts, so it carries no VLAN; %s", node, port, *a.VLAN, port, node, valid())
			}
		}
		if msg != "" {
			out = append(out, Violation{RuleResolvability, msg})
		}
	}
	return out
}

// ---------------------------------------------------------------------------------------------
// One owner per (node, port, vlan) and one tagging mode per port (FR-034, AD-20)

// CheckOwner is the row "One owner per (node, port, vlan)": no other Network already owns the
// subinterface an attachment of cand derives; the refusal names the holder. An
// accessLists-only object is neither checked nor counted as a holder.
func CheckOwner(cand *fabricv1.Network, others []fabricv1.Network) []Violation {
	if StandaloneACL(&cand.Spec) {
		return nil
	}
	var out []Violation
	for _, a := range cand.Spec.Attachments {
		s := subOf(a)
		for i := range others {
			o := &others[i]
			if StandaloneACL(&o.Spec) {
				continue
			}
			for _, b := range o.Spec.Attachments {
				if subOf(b) == s {
					out = append(out, Violation{RuleOwner, fmt.Sprintf(
						"subinterface %s is already owned by Network %s: one owner per (node, port, vlan)%s",
						s, Key(o), holderNote(o, "subinterfaces"))})
				}
			}
		}
	}
	return out
}

// CheckTaggingMode is the row "One tagging mode per port": no other Network holds an
// attachment on the same (node, port) in the other tagging mode. A Network with a deletion
// timestamp still holds its mode; a standalone access list inherits the mode of the attachment
// it binds to and is not a second mode.
func CheckTaggingMode(cand *fabricv1.Network, others []fabricv1.Network) []Violation {
	if StandaloneACL(&cand.Spec) {
		return nil
	}
	var out []Violation
	seen := map[string]bool{}
	for _, a := range cand.Spec.Attachments {
		for i := range others {
			o := &others[i]
			if StandaloneACL(&o.Spec) {
				continue
			}
			for _, b := range o.Spec.Attachments {
				if a.Node != b.Node || a.Attachment != b.Attachment || tagged(a) == tagged(b) {
					continue
				}
				k := string(a.Node) + " " + string(a.Attachment) + " " + Key(o)
				if seen[k] {
					continue
				}
				seen[k] = true
				out = append(out, Violation{RuleTaggingMode, fmt.Sprintf(
					"port %s %s: Network %s asks for a %s attachment while Network %s holds a %s one; tagging is a property of the port, one tagging mode per port%s",
					a.Node, a.Attachment, Key(cand), modeName(tagged(a)), Key(o), modeName(tagged(b)), holderNote(o, "tagging mode"))})
			}
		}
	}
	return out
}

// ---------------------------------------------------------------------------------------------
// Access lists (data-model.md §11)

// binding is the unit of exclusivity: (node, port, subinterface index, direction, family).
type binding struct {
	sub        subinterface
	stage, fam string
	list       string
}

func bindingsOf(n *fabricv1.Network) []binding {
	var out []binding
	for _, l := range n.Spec.AccessLists {
		for _, a := range n.Spec.Attachments {
			out = append(out, binding{sub: subOf(a), stage: l.Stage, fam: l.Type, list: string(l.Name)})
		}
	}
	return out
}

// CheckBindings is the row "Access-list binding exclusivity": no other Network holds a binding
// on the same (node, port, subinterface, direction, address family); a Network with a deletion
// timestamp still holds its bindings, and the refusal says so.
func CheckBindings(cand *fabricv1.Network, others []fabricv1.Network) []Violation {
	var out []Violation
	for _, b := range bindingsOf(cand) {
		for i := range others {
			o := &others[i]
			for _, h := range bindingsOf(o) {
				if h.sub == b.sub && h.stage == b.stage && h.fam == b.fam {
					out = append(out, Violation{RuleBindingExclusivity, fmt.Sprintf(
						"access list %s: subinterface %s already carries the %s %s access list %s of Network %s; one list per subinterface, direction and address family%s",
						b.list, b.sub, b.stage, b.fam, h.list, Key(o), holderNote(o, "bindings"))})
				}
			}
		}
	}
	return out
}

// CheckStandaloneSubinterface is the row "Standalone list needs its subinterface": an
// accessLists-only object binds only where another Network's attachment already created the
// subinterface; otherwise it is refused naming the missing subinterface. A Network being
// deleted does not provide one: its subinterfaces are being removed.
func CheckStandaloneSubinterface(cand *fabricv1.Network, others []fabricv1.Network) []Violation {
	if !StandaloneACL(&cand.Spec) {
		return nil
	}
	var out []Violation
	for _, a := range cand.Spec.Attachments {
		s := subOf(a)
		found := false
		for i := range others {
			o := &others[i]
			if StandaloneACL(&o.Spec) || o.DeletionTimestamp != nil {
				continue
			}
			for _, b := range o.Spec.Attachments {
				if subOf(b) == s {
					found = true
				}
			}
		}
		if !found {
			out = append(out, Violation{RuleStandaloneNeedsSubi, fmt.Sprintf(
				"subinterface %s does not exist: no live Network's attachment creates it, and a standalone access list binds only to a subinterface another service already owns — it never creates one", s)})
		}
	}
	return out
}

// Evaluate runs every cross-object rule on cand against others (every other Network, deleting
// ones included), the Fabric inventory and the qualification record.
func Evaluate(cand *fabricv1.Network, others []fabricv1.Network, inv Inventory, fabricNamespace string, q Qualification) []Violation {
	var out []Violation
	out = append(out, CheckResolvable(cand, inv, fabricNamespace)...)
	out = append(out, CheckOwner(cand, others)...)
	out = append(out, CheckTaggingMode(cand, others)...)
	out = append(out, CheckBindings(cand, others)...)
	out = append(out, CheckStandaloneSubinterface(cand, others)...)
	out = append(out, CheckQualified(&cand.Spec, q)...)
	return out
}
