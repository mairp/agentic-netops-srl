package network

// Non-key leaf paths of a Config's native value (T059; contracts/reconciliation.md Rule 4,
// contracts/crd-api.md "Generated device configuration contract", AD-68). The same-priority
// overlap check compares these for this object's rendered documents and for every other
// priority-20 Config of the node, walked from their stored value by the one walker below, so
// the two sides are always in the same form: module qualification stripped from node names,
// list keys written into the path as [key=value], key values kept as stored.
//
// A leaf here is a NON-KEY leaf: a list entry that carries only its keys contributes no path
// (a key is part of a path, not a leaf of it). So two tagged services on one access port —
// each writing only beneath its own subinterface[index] — and a gateway service beside
// another on one leaf — each beneath its own irb0 subinterface, network-instance and
// vxlan-interface — share no leaf, while two Configs writing one subinterface's admin-state do.

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// multiKeys are the lists of the rendered subtrees whose key is more than one leaf.
var multiKeys = map[string][]string{
	"acl-filter": {"name", "type"},
	"prefix":     {"ip-prefix", "mask-length-range"},
}

// singleKeys are the single-leaf keys of the rendered subtrees, in the order they are tried
// against an entry: /interface[name], /subinterface[index], /network-instance[name],
// /tunnel-interface[name], /vxlan-interface[index] (tunnel) or [name] (network-instance),
// /bgp-instance[id], /address[ip-prefix], /entry[sequence-id], /acl/interface[interface-id],
// /populate|advertise[route-type], /neighbor[peer-address], /group[group-name],
// /afi-safi[afi-safi-name], /statement[name].
var singleKeys = []string{"name", "index", "id", "interface-id", "sequence-id", "ip-prefix", "route-type",
	"peer-address", "group-name", "afi-safi-name"}

// NonKeyLeafPaths returns, sorted and distinct, the non-key leaf paths of a native JSON_IETF
// document at "/".
func NonKeyLeafPaths(doc []byte) ([]string, error) {
	var v any
	if err := json.Unmarshal(doc, &v); err != nil {
		return nil, fmt.Errorf("config value is not JSON: %w", err)
	}
	set := map[string]bool{}
	walkLeaves("", v, set)
	out := make([]string, 0, len(set))
	for p := range set {
		out = append(out, p)
	}
	sort.Strings(out)
	return out, nil
}

func walkLeaves(prefix string, v any, out map[string]bool) {
	obj, ok := v.(map[string]any)
	if !ok {
		if prefix != "" {
			out[prefix] = true
		}
		return
	}
	for k, child := range obj {
		name := stripModule(k)
		p := prefix + "/" + name
		switch x := child.(type) {
		case map[string]any:
			walkLeaves(p, x, out)
		case []any:
			if !isObjectList(x) {
				out[p] = true // a leaf-list (or an empty/typed-empty value such as [null])
				continue
			}
			for _, e := range x {
				entry := e.(map[string]any)
				keys := entryKeys(name, entry)
				ep := p
				for _, key := range keys {
					ep += "[" + key + "=" + scalar(entry[key]) + "]"
				}
				skip := map[string]bool{}
				for _, key := range keys {
					skip[key] = true
				}
				rest := map[string]any{}
				for ek, ev := range entry {
					if !skip[stripModule(ek)] {
						rest[ek] = ev
					}
				}
				if len(rest) == 0 {
					continue // key-only list entry: no leaf (AD-68)
				}
				walkLeaves(ep, rest, out)
			}
		default:
			out[p] = true
		}
	}
}

func isObjectList(l []any) bool {
	if len(l) == 0 {
		return false
	}
	for _, e := range l {
		if _, ok := e.(map[string]any); !ok {
			return false
		}
	}
	return true
}

// entryKeys decides the key leaves of one list entry: the known multi-leaf keys, else the
// first known single key the entry carries, else every scalar member (an unknown list is
// treated as key-only, which never manufactures an overlap).
func entryKeys(list string, entry map[string]any) []string {
	has := map[string]string{}
	for k := range entry {
		has[stripModule(k)] = k
	}
	if ks, ok := multiKeys[list]; ok {
		var out []string
		for _, k := range ks {
			if _, ok := has[k]; ok {
				out = append(out, k)
			}
		}
		if len(out) > 0 {
			return out
		}
	}
	for _, k := range singleKeys {
		if _, ok := has[k]; ok {
			return []string{k}
		}
	}
	var out []string
	for k, v := range entry {
		switch v.(type) {
		case map[string]any, []any:
		default:
			out = append(out, stripModule(k))
		}
	}
	sort.Strings(out)
	return out
}

func scalar(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case float64:
		if x == float64(int64(x)) {
			return fmt.Sprintf("%d", int64(x))
		}
		return fmt.Sprint(x)
	case nil:
		return ""
	default:
		return fmt.Sprint(x)
	}
}

func stripModule(name string) string {
	if i := strings.IndexByte(name, ':'); i >= 0 {
		return name[i+1:]
	}
	return name
}

// NormalizePath puts a device path (a Deviation's, say) into the walker's form: a leading
// slash and no module qualification on node names; key values are kept.
func NormalizePath(p string) string {
	p = strings.TrimSpace(p)
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	var b strings.Builder
	depth := 0
	elemStart := true
	for i := 0; i < len(p); i++ {
		c := p[i]
		switch {
		case c == '[':
			depth++
		case c == ']':
			depth--
		case c == '/' && depth == 0:
			elemStart = true
			b.WriteByte(c)
			continue
		}
		if elemStart && depth == 0 {
			// drop a "module:" prefix of this element's name
			rest := p[i:]
			end := strings.IndexAny(rest, "/[")
			if end < 0 {
				end = len(rest)
			}
			if j := strings.IndexByte(rest[:end], ':'); j >= 0 {
				i += j
				elemStart = false
				continue
			}
		}
		elemStart = false
		b.WriteByte(c)
	}
	return b.String()
}
