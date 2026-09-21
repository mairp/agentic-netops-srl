package srl

import "github.com/mairp/agentic-netops-srl/internal/model"

// renderRoutingPolicy builds /routing-policy: the system-loopbacks prefix-set
// — every node's system0.0 IPv4 /32 (mask-length-range 32..32) and derived
// IPv6 /128 (128..128) — and the system-loopbacks-policy accepting it, the
// export and import policy of both underlay groups. eBGP rejects everything
// without a policy (ebgp-default-policy import/export-reject-all default true),
// and the prefix-set form never leaks a tenant prefix into the underlay
// (evidence/02-evpn-constructs.md §1.2).
func renderRoutingPolicy(n *model.FabricNode) container {
	prefixes := newList("ip-prefix", "mask-length-range")
	for _, p := range n.LoopbackBlock {
		prefixes.add(container{"ip-prefix": p, "mask-length-range": model.MaskLengthRange(p)})
	}
	return container{
		"prefix-set": newList("name").add(container{
			"name":   model.LoopbackPrefixSet,
			"prefix": prefixes,
		}),
		"policy": newList("name").add(container{
			"name": model.LoopbackPolicy,
			"statement": newList("name").add(container{
				"name":   "1",
				"match":  container{"prefix": container{"prefix-set": model.LoopbackPrefixSet}},
				"action": container{"policy-result": "accept"},
			}),
		}),
	}
}
