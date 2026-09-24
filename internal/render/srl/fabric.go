// Package srl is the provider's only renderer of device paths (R-02): it turns
// the canonical model (internal/model) into native srl_nokia JSON_IETF
// documents at path "/", one per node, which the provider places into the
// generated SDC Configs (data-model.md §13, FR-012, FR-017).
//
// This file holds the fabric entry points (T039), the canonical JSON writer,
// the render hash, and the one place the identityref serialization form is
// decided. interfaces.go, bgp.go, policy.go and vxlan.go build the subtrees.
//
// The golden files the output is compared against (tests/golden/fabric/) are
// frozen (T047) in the module-qualified identityref form gate item G12
// observed from a real device Get (tests/gate/observed/serialization.json;
// R-36, AD-31, AD-81).
package srl

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/pkg/register"
)

// Rendered is one node's canonical document.
type Rendered struct {
	Node string
	// JSON is the canonical JSON_IETF document at "/": module-qualified
	// top-level keys, object keys sorted, list entries sorted by their keys,
	// two-space indentation and a trailing newline.
	JSON []byte
	// Hash is the sha256 hex digest of JSON — the render hash stamped on the
	// generated Config; an unchanged hash causes no Config update.
	Hash string
}

// RenderFabric renders every node of m, keyed by node name.
func RenderFabric(m *model.FabricModel) (map[string]*Rendered, error) {
	if m == nil {
		return nil, fmt.Errorf("render fabric: nil model")
	}
	out := make(map[string]*Rendered, len(m.Nodes))
	for i := range m.Nodes {
		r, err := RenderFabricNode(&m.Nodes[i])
		if err != nil {
			return nil, err
		}
		if _, dup := out[r.Node]; dup {
			return nil, fmt.Errorf("render fabric %s: node %s appears twice", m.Name, r.Node)
		}
		out[r.Node] = r
	}
	return out, nil
}

// RenderFabricNode renders the priority-10 fabric Config document of one node:
// fabric ports and their routed subinterface 0 (mtu, ip-mtu, IPv4 and the
// derived IPv6 address), system0.0 (VTEP source and router-id), the port-level
// leaves of every access port and irb0's admin-state (leaves, AD-68), the
// maintenance[] admin-state (AD-06), the default network-instance with the
// dual-stack eBGP underlay and the iBGP EVPN overlay — inter-as-vpn on every
// reflecting spine exactly as stated (AD-43) — the loopback routing policy,
// and the tunnel-interface vxlan0 on leaves. It renders nothing of a service.
//
// Before returning, every leaf path of the document is checked against the
// path register (FR-017); an uncovered path is an error
// (Rendered=False/RegisterUncovered).
func RenderFabricNode(n *model.FabricNode) (*Rendered, error) {
	if n == nil || n.Name == "" {
		return nil, fmt.Errorf("render fabric node: node without a name")
	}
	doc, err := fabricTree(n)
	if err != nil {
		return nil, fmt.Errorf("render fabric node %s: %w", n.Name, err)
	}
	paths, err := leafPaths(doc)
	if err != nil {
		return nil, fmt.Errorf("render fabric node %s: %w", n.Name, err)
	}
	if err := register.CheckFabricPaths(n.Name, paths); err != nil {
		return nil, err
	}
	js, err := canonicalJSON(doc)
	if err != nil {
		return nil, fmt.Errorf("render fabric node %s: %w", n.Name, err)
	}
	sum := sha256.Sum256(js)
	return &Rendered{Node: n.Name, JSON: js, Hash: hex.EncodeToString(sum[:])}, nil
}

// FabricLeafPaths returns, sorted, the concrete leaf paths of the document
// RenderFabricNode emits for n, with the device's module qualification
// removed from node names (identityref key values are kept as rendered).
// Paths of list entries that carry only their keys are included.
func FabricLeafPaths(n *model.FabricNode) ([]string, error) {
	doc, err := fabricTree(n)
	if err != nil {
		return nil, err
	}
	return leafPaths(doc)
}

func fabricTree(n *model.FabricNode) (container, error) {
	doc := container{
		modInterfaces + ":interface":             renderInterfaces(n),
		modNetworkInstance + ":network-instance": newList("name").add(renderDefaultNI(n)),
		modRoutingPolicy + ":routing-policy":     renderRoutingPolicy(n),
	}
	if t := renderTunnelInterfaces(n); t != nil {
		doc[modTunnelInterfaces+":tunnel-interface"] = t
	}
	return doc, nil
}

// ---------------------------------------------------------------------------
// Module names (RFC 7951 member names use the module NAME, never the prefix;
// evidence/02-evpn-constructs.md §0, §2.5).
// ---------------------------------------------------------------------------

const (
	modInterfaces       = "srl_nokia-interfaces"
	modInterfacesVLANs  = "srl_nokia-interfaces-vlans"
	modNetworkInstance  = "srl_nokia-network-instance"
	modBGP              = "srl_nokia-bgp"
	modRoutingPolicy    = "srl_nokia-routing-policy"
	modTunnelInterfaces = "srl_nokia-tunnel-interfaces"
	modCommon           = "srl_nokia-common"
)

// qualifyIdentityrefs decides the identityref JSON_IETF serialization form —
// the ONE place it is decided. RFC 7951 §6.8 requires the module-qualified
// form `<module-name>:<identity>` when the identity is defined in another
// module than the leaf (afi-safi-name: leaf in srl_nokia-bgp, identities in
// srl_nokia-common) and permits it otherwise; the qualified form is used
// throughout (evidence/02-evpn-constructs.md §2.5). Gate item G12 observed
// the device return exactly this form on a Get (identityref values module-
// qualified, e.g. afi-safi-name "srl_nokia-common:evpn";
// tests/gate/observed/serialization.json), and T047 froze the golden files in
// it (AD-81).
const qualifyIdentityrefs = true

func identityref(module, identity string) string {
	if !qualifyIdentityrefs {
		return identity
	}
	return module + ":" + identity
}

func adminState(enabled bool) string {
	if enabled {
		return "enable"
	}
	return "disable"
}

// ---------------------------------------------------------------------------
// The document tree and its canonical form.
// ---------------------------------------------------------------------------

// container is a YANG container or a list entry. Member names of nodes from
// another module than their parent carry the module name ("mod:name").
type container map[string]any

// list is a YANG list; entries are emitted sorted by their key values.
type list struct {
	keys    []string
	entries []container
}

// leafList is a YANG leaf-list; its order is the user's (ordered-by user).
type leafList []any

func newList(keys ...string) *list { return &list{keys: keys} }

func (l *list) add(e ...container) *list {
	l.entries = append(l.entries, e...)
	return l
}

func (l *list) sorted() []container {
	out := append([]container(nil), l.entries...)
	sort.SliceStable(out, func(i, j int) bool {
		for _, k := range l.keys {
			if c := compareKey(out[i][k], out[j][k]); c != 0 {
				return c < 0
			}
		}
		return false
	})
	return out
}

func (l *list) MarshalJSON() ([]byte, error) {
	return json.Marshal(l.sorted())
}

func compareKey(a, b any) int {
	an, aNum := asUint(a)
	bn, bNum := asUint(b)
	if aNum && bNum {
		switch {
		case an < bn:
			return -1
		case an > bn:
			return 1
		}
		return 0
	}
	return strings.Compare(keyString(a), keyString(b))
}

func asUint(v any) (uint64, bool) {
	switch x := v.(type) {
	case uint32:
		return uint64(x), true
	case int:
		return uint64(x), true
	}
	return 0, false
}

func keyString(v any) string {
	if n, ok := asUint(v); ok {
		return strconv.FormatUint(n, 10)
	}
	return fmt.Sprint(v)
}

// canonicalJSON writes the document with sorted object keys (encoding/json
// sorts map keys), sorted list entries, no HTML escaping, two-space indent
// and a trailing newline — byte-identical for identical input.
func canonicalJSON(doc container) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(doc); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// leafPaths walks the tree and returns every leaf / leaf-list path, and every
// path of a list entry that carries only its keys, as concrete gNMI paths
// with the module qualification of node names removed. A duplicate list
// entry is an error (two constructs rendering the same entry).
func leafPaths(doc container) ([]string, error) {
	var out []string
	seen := map[string]bool{}
	var walk func(prefix string, c container, skip map[string]bool) error
	walk = func(prefix string, c container, skip map[string]bool) error {
		for k, v := range c {
			if skip[k] {
				continue
			}
			p := prefix + "/" + stripModule(k)
			switch x := v.(type) {
			case container:
				if len(x) == 0 {
					out = append(out, p) // a presence container (an access-list action)
					continue
				}
				if err := walk(p, x, nil); err != nil {
					return err
				}
			case *list:
				for _, e := range x.sorted() {
					ep := p
					keys := map[string]bool{}
					for _, key := range x.keys {
						kv, ok := e[key]
						if !ok {
							return fmt.Errorf("%s: list entry without key %s", p, key)
						}
						ep += "[" + key + "=" + keyString(kv) + "]"
						keys[key] = true
					}
					if seen[ep] {
						return fmt.Errorf("duplicate list entry %s", ep)
					}
					seen[ep] = true
					if len(e) == len(x.keys) {
						out = append(out, ep)
						continue
					}
					if err := walk(ep, e, keys); err != nil {
						return err
					}
				}
			default:
				out = append(out, p)
			}
		}
		return nil
	}
	if err := walk("", doc, nil); err != nil {
		return nil, err
	}
	sort.Strings(out)
	return out, nil
}

func stripModule(name string) string {
	if i := strings.IndexByte(name, ':'); i >= 0 {
		return name[i+1:]
	}
	return name
}
