package migration

// Access-list translation (T110; FR-035…FR-041, FR-060; contracts/acl-render-contract.md §3, §6,
// contracts/network-spec.md §2–§3, contracts/translator-api.md).
//
// An access list is a FIELD on the one Network the translator emits, never a second render path:
//
//   - as a property of a vlan, a mac-vrf or an ip-vrf (FR-036) it adds one accessLists[] entry to
//     that construct's own Network, bound — by the provider — to that service's own attachment
//     subinterfaces, and changes nothing else in the object;
//   - as the standalone `acl` construct (FR-035) it emits accessLists[] and attachments[] ONLY: each
//     attachment names a node, a port and optionally the VLAN of a subinterface another service
//     already created — a reference, held to the structural 100–4000 alone and claiming nothing
//     (AD-47) — and never a vrf.
//
// Folding happens on entry (foldOnEntry, input.go), so neither the emitted spec nor the canonical
// input hash depends on a spelling: the family l3 / ip → ipv4 and l3v6 / ipv6 → ipv6, the stage
// in / inbound → ingress and out / outbound → egress, the protocol icmpv6 → icmp6. On emission a
// protocol name the Network API does not spell is written as its IANA number, and the rules are
// written in ascending priority — the device's evaluation order.
//
// Every refusal of contracts/acl-render-contract.md §3 the request itself can decide is decided
// here, each cause naming its property path and the offending rule. The rules that need the
// Networks already in the cluster (a standalone list's subinterface, binding exclusivity against
// another object) or the qualification record (egress, FR-097) are not the translator's to decide
// beyond the request: the admission webhook holds them (internal/webhook), and the interpretation
// stage refuses an unqualified property before any claim.

import (
	"fmt"
	"net/netip"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// The access-list ranges (contracts/acl-render-contract.md §2–§3; api/fabric/v1alpha1 AccessList).
const (
	ACLPriorityMin      = 1
	ACLPriorityMax      = 65534
	ACLPriorityReserved = 65535
	aclMaxRules         = 64
	aclMaxRuleName      = 64
	aclMaxDescription   = 255

	// evaluationOrderText is how every refusal that touches order states it (FR-039).
	evaluationOrderText = "rules are evaluated in ascending priority, first match wins"
)

// aclTypes folds the operator spellings of the address family (Key applied) onto the device's own.
var aclTypes = map[string]string{
	"ipv4": "ipv4", "ip": "ipv4", "l3": "ipv4", "ip4": "ipv4", "inet": "ipv4",
	"ipv6": "ipv6", "l3v6": "ipv6", "ip6": "ipv6", "inet6": "ipv6",
}

// aclLayer2 are the spellings of a Layer 2 list: refused as out of scope (FR-038).
var aclLayer2 = map[string]bool{"mac": true, "l2": true, "ethernet": true, "layer2": true}

// aclStages folds the stage spellings (Key applied).
var aclStages = map[string]string{
	"ingress": "ingress", "in": "ingress", "inbound": "ingress", "input": "ingress",
	"egress": "egress", "out": "egress", "outbound": "egress", "output": "egress",
}

// aclProtocols are the protocol names the normalized intent admits, with their IANA numbers
// (normalized-service-intent.schema.json acl.rules[].protocol).
var aclProtocols = map[string]int{
	"ipv6-hop": 0, "icmp": 1, "igmp": 2, "ggp": 3, "ipv4": 4, "st": 5, "tcp": 6, "egp": 8, "igp": 9,
	"udp": 17, "ipv6": 41, "idrp": 45, "rsvp": 46, "gre": 47, "esp": 50, "ah": 51, "icmp6": 58,
	"no-next-hdr": 59, "ipv6-dest-opts": 60, "eigrp": 88, "ospf": 89, "pim": 103, "vrrp": 112,
	"l2tp": 115, "sctp": 132, "mpls-in-ip": 137, "rohc": 142,
}

// apiProtocolNames are the names the Network API's ACLProtocol pattern spells; any other name is
// emitted as its number.
var apiProtocolNames = map[string]bool{
	"any": true, "tcp": true, "udp": true, "icmp": true, "icmp6": true, "igmp": true, "gre": true,
	"esp": true, "ah": true, "ospf": true, "pim": true, "vrrp": true, "sctp": true,
}

var (
	aclPortPattern = regexp.MustCompile(`^([0-9]{1,5})(-([0-9]{1,5}))?$`)
	aclNumber      = regexp.MustCompile(`^[0-9]+$`)
)

// aclListName is the emitted list name, acl-<serviceId>-<stage> (internal/model names.go
// FilterName derives the device filter name the same way).
func aclListName(sid, stage string) string { return "acl-" + sid + "-" + stage }

// canonicalizeACL folds the list's spellings on entry. An unresolvable value is left as written,
// for validation to refuse by name.
func (a *ACL) canonicalize() {
	if a == nil {
		return
	}
	if f, ok := aclTypes[Key(a.Type)]; ok {
		a.Type = f
	}
	if s, ok := aclStages[Key(a.Stage)]; ok {
		a.Stage = s
	}
	for i := range a.Rules {
		p := strings.ToLower(strings.TrimSpace(string(a.Rules[i].Protocol)))
		if p == "icmpv6" {
			p = "icmp6"
		}
		if p != "" && !aclNumber.MatchString(p) {
			a.Rules[i].Protocol = Protocol(p)
		}
	}
}

// l4Protocol says whether a (folded) protocol admits an L4 port match: TCP (6) or UDP (17) only.
func l4Protocol(p Protocol) bool {
	switch p {
	case "tcp", "udp", "6", "17":
		return true
	}
	return false
}

// validateACL returns every cause of one access list, each prefixed with p and starting with its
// property path under acl.
func validateACL(a *ACL, p string) []string {
	var causes []string
	add := func(format string, args ...any) { causes = append(causes, p+fmt.Sprintf(format, args...)) }

	if n := strings.ToLower(strings.TrimSpace(a.Name)); n == "system" || n == "capture" {
		add("acl.name: %q is reserved on this platform for the device's own %s filters, which the platform neither writes nor counts; name the list otherwise (FR-040)", a.Name, n)
	}
	switch {
	case a.Stage == "":
		add("acl.stage: required — ingress or egress, the direction the list filters in (rendered as the device's input or output binding)")
	case a.Stage != "ingress" && a.Stage != "egress":
		add("acl.stage: %q is not a stage; the stages are ingress and egress", a.Stage)
	}
	switch {
	case a.Type == "":
		add("acl.type: required — the address family, ipv4 or ipv6")
	case aclLayer2[Key(a.Type)]:
		add("acl.type: %s — a Layer 2 (MAC) access list is out of scope: the acl construct is defined over the address families ipv4 and ipv6. The refusal is one of scope, not of capability: the device does offer a MAC filter type, and admitting it would also make the binding unit coarser, since a MAC and an IP filter cannot share a subinterface and direction (FR-038)", a.Type)
	case a.Type != "ipv4" && a.Type != "ipv6":
		add("acl.type: %q is not an access-list type; the types are ipv4 and ipv6 (l3 and ip fold to ipv4, l3v6 to ipv6)", a.Type)
	}
	switch a.DefaultAction {
	case "", "permit", "deny":
	default:
		add("acl.defaultAction: %q is not permit or deny; declared, it is rendered as the terminal entry at the reserved position %d, and absent, the device accepts unmatched traffic", a.DefaultAction, ACLPriorityReserved)
	}
	if a.EvaluationOrder != "" && a.EvaluationOrder != "ascending-first-match" {
		add("acl.evaluationOrder: %q is not this platform's order; %s (ascending-first-match) and no other order is offered", a.EvaluationOrder, evaluationOrderText)
	}
	if u := a.UnmatchedTraffic; u != "" {
		want := "accept-platform-default"
		if a.DefaultAction != "" {
			want = a.DefaultAction
		}
		if u != want {
			add("acl.unmatchedTraffic: %q contradicts the list: with defaultAction %q unmatched traffic is %s", u, a.DefaultAction, want)
		}
	}

	switch n := len(a.Rules); {
	case n == 0:
		add("acl.rules: at least one rule is required; a list of no rules filters nothing but its default action")
	case n > aclMaxRules:
		add("acl.rules: %d rules; a list carries at most %d", n, aclMaxRules)
	}
	names := map[string]int{}
	prios := map[int64]int{}
	for i, r := range a.Rules {
		path := fmt.Sprintf("acl.rules[%d]", i)
		rule := func(field, format string, args ...any) {
			causes = append(causes, p+fmt.Sprintf("%s.%s: rule %q: ", path, field, r.Name)+fmt.Sprintf(format, args...))
		}
		switch {
		case r.Name == "":
			add("%s.name: required; a rule's name labels its device entry", path)
		case len(r.Name) > aclMaxRuleName:
			rule("name", "longer than %d characters", aclMaxRuleName)
		default:
			if j, dup := names[r.Name]; dup {
				add("%s.name: %q is also the name of acl.rules[%d]; rule names are distinct within a list", path, r.Name, j)
			} else {
				names[r.Name] = i
			}
		}
		switch {
		case r.Priority == ACLPriorityReserved:
			rule("priority", "priority %d is reserved for the default action, the last position in the evaluation order; %d–%d is usable, and %s", ACLPriorityReserved, ACLPriorityMin, ACLPriorityMax, evaluationOrderText)
		case r.Priority < ACLPriorityMin || r.Priority > ACLPriorityMax:
			rule("priority", "priority %d is outside the usable range %d–%d (%d is reserved for the default action); %s", r.Priority, ACLPriorityMin, ACLPriorityMax, ACLPriorityReserved, evaluationOrderText)
		default:
			if j, dup := prios[r.Priority]; dup {
				rule("priority", "priority %d is also the priority of rule %q (acl.rules[%d]); priorities are distinct within a list, because %s and which of the two would win is otherwise arbitrary", r.Priority, a.Rules[j].Name, j, evaluationOrderText)
			} else {
				prios[r.Priority] = i
			}
		}
		if r.Action != "permit" && r.Action != "deny" {
			rule("action", "%q is not permit or deny", r.Action)
		}
		if pr := string(r.Protocol); pr != "" && pr != "any" {
			if aclNumber.MatchString(pr) {
				if n, err := strconv.Atoi(pr); err != nil || n > 255 {
					rule("protocol", "%s is not an IP protocol number 0–255", pr)
				}
			} else if _, ok := aclProtocols[pr]; !ok {
				rule("protocol", "%q is not an IP protocol this platform matches; give a known name (tcp, udp, icmp, icmp6, …) or a number 0–255", pr)
			}
		}
		for _, pf := range []struct{ field, v string }{{"sourcePrefix", r.SourcePrefix}, {"destinationPrefix", r.DestinationPrefix}} {
			if pf.v == "" {
				continue
			}
			pfx, err := netip.ParsePrefix(pf.v)
			switch {
			case err != nil:
				rule(pf.field, "%q is not a CIDR prefix", pf.v)
			case a.Type == "ipv4" && !pfx.Addr().Is4():
				rule(pf.field, "%s is an IPv6 prefix in an ipv4 access list; a match is in the list's own address family, and a wrong-family entry would be programmed and never match", pf.v)
			case a.Type == "ipv6" && pfx.Addr().Is4():
				rule(pf.field, "%s is an IPv4 prefix in an ipv6 access list; a match is in the list's own address family, and a wrong-family entry would be programmed and never match", pf.v)
			case pfx.Masked() != pfx:
				rule(pf.field, "%s has host bits set; the prefix is %s", pf.v, pfx.Masked())
			}
		}
		for _, pt := range []struct{ field, v string }{{"sourcePort", r.SourcePort}, {"destinationPort", r.DestinationPort}} {
			if pt.v == "" {
				continue
			}
			if !l4Protocol(r.Protocol) {
				proto := string(r.Protocol)
				if proto == "" {
					proto = "none"
				}
				rule(pt.field, "an L4 port match requires protocol tcp (6) or udp (17), and this rule's protocol is %s — the device admits a port only with those two, which excludes sctp although it has ports", proto)
			}
			m := aclPortPattern.FindStringSubmatch(pt.v)
			if m == nil {
				rule(pt.field, "%q is not a port or a lo-hi range", pt.v)
				continue
			}
			lo, _ := strconv.Atoi(m[1])
			if lo > 65535 {
				rule(pt.field, "%q is not a port 0–65535", pt.v)
				continue
			}
			if m[3] != "" {
				hi, _ := strconv.Atoi(m[3])
				switch {
				case hi > 65535:
					rule(pt.field, "%q is not a port 0–65535", pt.v)
				case hi < lo:
					rule(pt.field, "the range %s is inverted: a range is lo-hi with lo ≤ hi (%d-%d)", pt.v, hi, lo)
				}
			}
		}
		if len(r.Description) > aclMaxDescription {
			rule("description", "longer than %d characters", aclMaxDescription)
		}
	}
	return causes
}

// bindingPointCauses refuses an endpoint that is not a named attachment subinterface: a network
// instance (vrf) or an integrated-routing interface (FR-037).
func bindingPointCauses(in *ServiceInput, p string) []string {
	var causes []string
	for i, ep := range in.Endpoints {
		sub := fmt.Sprintf("%s %s.%d", ep.Node, ep.Attachment, vlanOf(ep))
		if ep.VRF != "" {
			causes = append(causes, fmt.Sprintf("%sendpoints[%d].vrf: an access list binds to a named attachment subinterface (here %s), never to a network instance such as %s, to a VLAN as such, or fabric-wide; a standalone acl endpoint carries a node, a port and optionally the VLAN of an existing subinterface, and no vrf",
				p, i, sub, ep.VRF))
		}
		if a := strings.ToLower(ep.Attachment); strings.HasPrefix(a, "irb") {
			causes = append(causes, fmt.Sprintf("%sendpoints[%d].attachment: %s is an integrated-routing (IRB) interface; IRB subinterfaces are not in the operator vocabulary and are never bound implicitly — an access list binds to an attachment subinterface of an access port", p, i, ep.Attachment))
		}
	}
	return causes
}

func vlanOf(ep Endpoint) int64 {
	if ep.VLAN == nil {
		return 0
	}
	return *ep.VLAN
}

// validateStandaloneACL is the standalone `acl` construct: its list, its binding points, and no
// variable another construct carries.
func validateStandaloneACL(in *ServiceInput, p string) []string {
	var causes []string
	add := func(format string, a ...any) { causes = append(causes, p+fmt.Sprintf(format, a...)) }
	if in.ACL == nil {
		add("acl: required for an acl — the list itself: stage, type and rules")
	}
	if in.L2VNI != nil {
		add("l2vni: an acl carries no L2VNI; it binds to subinterfaces other services created, and the L2VNI belongs to a mac-vrf")
	}
	if in.L3VNI != nil {
		add("l3vni: an acl carries no L3VNI; the L3VNI belongs to an ip-vrf, or to a mac-vrf with an anycastGateway")
	}
	if in.RouteTargets != nil {
		add("routeTargets: an acl is not advertised by EVPN and has no route targets; route targets belong to a mac-vrf or an ip-vrf")
	}
	if in.AnycastGateway != nil {
		add("anycastGateway: an acl carries no anycast gateway; the gateway belongs to a mac-vrf")
	}
	if in.AddressFamilies != nil {
		add("addressFamilies: an acl carries no prefixes of its own; its matches are its rules' prefixes, and routed prefixes belong to an ip-vrf")
	}
	causes = append(causes, bindingPointCauses(in, p)...)
	seen := map[[3]string]int{}
	for i, ep := range in.Endpoints {
		if ep.Node == "" || ep.Attachment == "" {
			continue
		}
		k := [3]string{ep.Node, ep.Attachment, strconv.FormatInt(vlanOf(ep), 10)}
		if j, dup := seen[k]; dup {
			add("endpoints[%d]: duplicates endpoints[%d] — %s %s.%d is already a binding point of this list", i, j, ep.Node, ep.Attachment, vlanOf(ep))
			continue
		}
		seen[k] = i
	}
	causes = append(causes, policyCauses(in, p)...)
	return causes
}

// aclBinding is the unit of exclusivity within one request: (node, port, subinterface index,
// direction, family) — contracts/acl-render-contract.md §6.
type aclBinding struct {
	sub        subinterface
	stage, fam string
}

// aclBatchCauses are the access-list rules that span the services of one request, decided as far
// as the request decides them (the webhook holds them against the cluster):
//
//   - one list per (node, port, subinterface, direction, family): a second is refused naming the
//     service that holds the unit; an IPv4 and an IPv6 list, or lists on different subinterfaces
//     of one port, do not conflict;
//   - a standalone list binds to a subinterface another service created and never creates one: a
//     subinterface the request itself makes impossible — its port put in the other tagging mode by
//     a service of the same request (one mode per port, AD-20) — is refused naming it.
func aclBatchCauses(inputs []ServiceInput, prefix func(int) string, owners map[subinterface]where) []string {
	var causes []string
	held := map[aclBinding]where{}
	// modes: (node, port) → the first owner endpoint of each mode in this request.
	type modes struct{ tagged, untagged *where }
	portModes := map[[2]string]*modes{}
	for key, w := range owners {
		pk := [2]string{key.node, key.port}
		m := portModes[pk]
		if m == nil {
			m = &modes{}
			portModes[pk] = m
		}
		w := w
		pick := func(cur **where) {
			if *cur == nil || w.svc < (*cur).svc || (w.svc == (*cur).svc && w.ep < (*cur).ep) {
				*cur = &w
			}
		}
		if key.vlan == 0 {
			pick(&m.untagged)
		} else {
			pick(&m.tagged)
		}
	}
	for i := range inputs {
		in := &inputs[i]
		if in.ACL == nil {
			continue
		}
		stage, fam := in.ACL.Stage, in.ACL.Type
		validUnit := (stage == "ingress" || stage == "egress") && (fam == "ipv4" || fam == "ipv6")
		for e, ep := range in.Endpoints {
			if ep.Node == "" || ep.Attachment == "" {
				continue
			}
			sub := subinterface{ep.Node, ep.Attachment, vlanOf(ep)}
			name := fmt.Sprintf("%s %s.%d", ep.Node, ep.Attachment, sub.vlan)
			if in.Type == ConstructACL {
				if m := portModes[[2]string{ep.Node, ep.Attachment}]; m != nil {
					if _, owned := owners[sub]; !owned {
						var other *where
						mode := "tagged"
						if sub.vlan == 0 && m.tagged != nil {
							other = m.tagged
						} else if sub.vlan != 0 && m.untagged != nil {
							other, mode = m.untagged, "untagged"
						}
						if other != nil {
							causes = append(causes, fmt.Sprintf("%sendpoints[%d]: subinterface %s does not exist and cannot: %sendpoints[%d] (service %s) makes port %s on %s %s in this same request, and a port carries one tagging mode; a standalone access list binds only to a subinterface another service already created — it never creates one",
								prefix(i), e, name, prefix(other.svc), other.ep, inputs[other.svc].ServiceID, ep.Attachment, ep.Node, mode))
						}
					}
				}
			}
			if !validUnit {
				continue
			}
			k := aclBinding{sub: sub, stage: stage, fam: fam}
			if h, ok := held[k]; ok && h.svc != i {
				holder := inputs[h.svc].ServiceID
				causes = append(causes, fmt.Sprintf("%sendpoints[%d]: %s already carries the %s %s access list of service %s (%sendpoints[%d]) in this request — the unit is held by service %s; one list per subinterface, direction and address family, and a second is refused, never merged, joined or displaced",
					prefix(i), e, name, stage, fam, holder, prefix(h.svc), h.ep, holder))
				continue
			}
			held[k] = where{i, e}
		}
	}
	return causes
}

// accessList is the emitted accessLists[] entry of a validated list: name acl-<serviceId>-<stage>,
// rules in ascending priority, protocol names the Network API does not spell as numbers.
func accessList(sid string, a *ACL) AccessList {
	out := AccessList{Name: aclListName(sid, a.Stage), Stage: a.Stage, Type: a.Type, DefaultAction: a.DefaultAction}
	for _, r := range a.Rules {
		proto := string(r.Protocol)
		if n, known := aclProtocols[proto]; known && !apiProtocolNames[proto] {
			proto = strconv.Itoa(n)
		}
		out.Rules = append(out.Rules, ACLRuleOut{
			Name: r.Name, Priority: r.Priority, Action: r.Action, Protocol: proto,
			SourcePrefix: r.SourcePrefix, DestinationPrefix: r.DestinationPrefix,
			SourcePort: r.SourcePort, DestinationPort: r.DestinationPort, Description: r.Description,
		})
	}
	sort.SliceStable(out.Rules, func(i, j int) bool { return out.Rules[i].Priority < out.Rules[j].Priority })
	return out
}
