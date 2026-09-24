// Package acl renders an access list — its filter, entries and bindings — into
// the native srl_nokia /acl subtree of a service Config document (T107;
// contracts/acl-render-contract.md §2, §3; data-model.md §13; FR-015, FR-017,
// FR-035–FR-041, FR-043, AD-68).
//
// It is called by the service renderer (internal/render/srl RenderServiceNode)
// for every node, so a filter carried by a service reaches the device in the
// same per-node document — one gNMI SetRequest — as the network-instance and
// the subinterfaces it protects (FR-036), and a standalone `acl` is its own
// document carrying only /acl/acl-filter[name][type] and the
// input|output/acl-filter[name][type] entry beneath
// /acl/interface[interface-id]. The binding entry's interface-ref is written by
// the Config that renders the subinterface, always, filter or none, and never
// by a standalone list, so the two share no leaf (AD-68): a model
// ACLInterface.Ref is present exactly on the subinterfaces this Config owns.
//
// Every path, key and value is the pinned model's (srl_nokia-acl.yang,
// srl_nokia-packet-match-types.yang @ v25.7.1): the filter key is the pair
// (name, type); `type` is an enumeration and is emitted bare ("ipv4", as the
// device returns it — RFC 7951 qualifies identities, never enum values); the
// actions accept/drop are presence containers ({}); sequence-ids and ports are
// JSON numbers; a protocol / next-header is the device's enum name or a number.
//
// The renderer refuses and never rewrites (D-13): a name that is not
// device-safe, a reserved name (system, capture), a MAC filter, a port match on
// a protocol other than TCP or UDP, a prefix of the wrong family, an entry
// outside 1–65534 (65535 only as the match-all default action), a binding whose
// filter this document does not carry, an egress binding of a filter without
// subinterface-specific output-only|input-and-output, and a second filter of
// one address family in one direction on one subinterface (FR-043) — each
// refusal names what it refuses, unchanged.
package acl

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/mairp/agentic-netops-srl/internal/model"
)

// Container is a YANG container or a list entry of the rendered tree; the
// service renderer converts it into its own canonical writer's form.
type Container map[string]any

// List is a YANG list; the service renderer emits its entries sorted by Keys.
type List struct {
	Keys    []string
	Entries []Container
}

func newList(keys ...string) *List { return &List{Keys: keys} }

func (l *List) add(e Container) { l.Entries = append(l.Entries, e) }

// Direction is a binding direction under /acl/interface: input (stage
// ingress) or output (stage egress).
type Direction string

const (
	Input  Direction = "input"
	Output Direction = "output"
)

// DirectionOf maps a stage to its binding direction: ingress → input,
// egress → output.
func DirectionOf(s model.Stage) (Direction, error) {
	switch s {
	case model.StageIngress:
		return Input, nil
	case model.StageEgress:
		return Output, nil
	}
	return "", fmt.Errorf("acl stage %q is neither %q nor %q", s, model.StageIngress, model.StageEgress)
}

// Subinterface-specific values that satisfy the device's egress must
// ("subinterface-specific must be set to output-only or input-and-output for
// egress filters").
const (
	OutputOnly     = "output-only"
	InputAndOutput = "input-and-output"
)

// ValidateFilterRef refuses — never rewrites — a filter key the device would
// refuse or the platform does not offer: a name outside srl_nokia-comm:name
// (1–255 characters, no leading space, the device alphabet), the reserved
// names system and capture, and any type but ipv4 / ipv6 (a MAC filter is
// out of scope, FR-038).
func ValidateFilterRef(name string, typ model.Family) error {
	if err := model.ValidateFilterName(name); err != nil {
		return err
	}
	if typ != model.FamilyIPv4 && typ != model.FamilyIPv6 {
		return fmt.Errorf("acl-filter %q type %q: only ipv4 and ipv6 filters are rendered (a mac filter is out of scope)", name, typ)
	}
	return nil
}

// InterfaceID is the /acl/interface key `<interface>.<subinterface-index>`.
func InterfaceID(port string, index uint32) string { return model.SubinterfaceName(port, index) }

// protocolNames are the ip-protocol-type enumeration names the device accepts
// (srl_nokia-packet-match-types.yang @ v25.7.1), by the operator's spelling;
// `icmpv6` is the operator's name for the device's icmp6 (next-header 58).
var protocolNames = map[string]string{
	"icmp": "icmp", "igmp": "igmp", "tcp": "tcp", "udp": "udp", "gre": "gre", "esp": "esp", "ah": "ah",
	"icmp6": "icmp6", "icmpv6": "icmp6", "ospf": "ospf", "pim": "pim", "vrrp": "vrrp", "sctp": "sctp",
}

// ProtocolValue is the rendered value of match/ipv4/protocol or
// match/ipv6/next-header: the device's enum name for a known name, a JSON
// number for a number 0–255. Anything else is refused by name.
func ProtocolValue(p string) (any, error) {
	if v, ok := protocolNames[strings.ToLower(p)]; ok {
		return v, nil
	}
	n, err := strconv.ParseUint(p, 10, 8)
	if err != nil {
		return nil, fmt.Errorf("protocol %q is neither an IP protocol number 0–255 nor a protocol name the device matches", p)
	}
	return uint32(n), nil
}

// isTCPOrUDP: the device admits a port match only with protocol / next-header
// TCP (6) or UDP (17).
func isTCPOrUDP(p any) bool {
	switch v := p.(type) {
	case string:
		return v == "tcp" || v == "udp"
	case uint32:
		return v == 6 || v == 17
	}
	return false
}
