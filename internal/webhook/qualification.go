package webhook

// The qualification rule (FR-097; contracts/crd-api.md row "Qualification";
// docs/reference/qualification-record.md): every construct and gated property a Network asks
// for must appear as qualified in agentic-netops-system/fabric-qualification, whose flat keys
// `<construct>` and `<construct>.<property>` carry exactly "qualified" or "unqualified". A key
// that is absent is unqualified — nothing is assumed the record does not state.

import (
	"fmt"
	"sort"
	"strings"

	corev1 "k8s.io/api/core/v1"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
)

// The record's location and its one qualified value.
const (
	QualificationNamespace = "agentic-netops-system"
	QualificationName      = "fabric-qualification"
	qualified              = "qualified"
)

// Qualification is the record's flat keys. Found is false when the ConfigMap does not exist:
// then nothing is qualified.
type Qualification struct {
	Found bool
	Keys  map[string]string
}

// QualificationFromConfigMap reads the record; a nil ConfigMap is an absent record.
func QualificationFromConfigMap(cm *corev1.ConfigMap) Qualification {
	if cm == nil {
		return Qualification{}
	}
	return Qualification{Found: true, Keys: cm.Data}
}

// Qualified says whether the record shows key as qualified.
func (q Qualification) Qualified(key string) bool {
	return q.Found && q.Keys[key] == qualified
}

// Requirements lists the record keys a spec asks for, in a stable order: its construct
// (network-spec.md §2) and every property it uses — the gated ones by name (an IPv6 anycast
// gateway, an IPv6 Type-5 route, an egress access list) and the per-family ones beside them.
// Every subinterface a service owns brings an ACL interface-ref with no filter (AD-68), so a
// service that owns one needs acl.binding-without-filter.
func Requirements(s *fabricv1.NetworkSpec) []string {
	set := map[string]bool{}
	add := func(k string) { set[k] = true }
	switch {
	case len(s.VLANs) > 0:
		add("vlan")
		add("vlan.bridged-subinterface")
	case len(s.BridgeDomains) > 0:
		add("mac-vrf")
		for _, b := range s.BridgeDomains {
			if b.IRB == nil {
				continue
			}
			if b.IRB.GatewayIPv4 != "" {
				add("mac-vrf.anycast-gateway-ipv4")
			}
			if b.IRB.GatewayIPv6 != "" {
				add("mac-vrf.anycast-gateway-ipv6")
			}
		}
	case len(s.Routers) > 0:
		add("ip-vrf")
	}
	for _, r := range s.Routers {
		for _, p := range r.Prefixes {
			if strings.Contains(string(p), ":") {
				add("ip-vrf.evpn-type5-ipv6")
			} else {
				add("ip-vrf.evpn-type5-ipv4")
			}
		}
	}
	if !StandaloneACL(s) {
		add("acl.binding-without-filter")
	}
	for _, l := range s.AccessLists {
		add("acl")
		if l.Stage == "egress" {
			add("acl.egress")
		} else {
			add("acl.ingress-" + l.Type)
		}
	}
	keys := make([]string, 0, len(set))
	for k := range set {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// CheckQualified is the row "Qualification": one Unqualified refusal naming every construct
// and property the record does not show as qualified.
func CheckQualified(s *fabricv1.NetworkSpec, q Qualification) []Violation {
	var missing []string
	for _, k := range Requirements(s) {
		if !q.Qualified(k) {
			missing = append(missing, k)
		}
	}
	if len(missing) == 0 {
		return nil
	}
	where := fmt.Sprintf("the qualification record %s/%s does not show", QualificationNamespace, QualificationName)
	if !q.Found {
		where = fmt.Sprintf("the qualification record %s/%s does not exist, so it shows none of", QualificationNamespace, QualificationName)
	}
	return []Violation{{RuleQualification, fmt.Sprintf("%s %s as qualified; the capability gate has not qualified what this Network asks for (FR-097)",
		where, strings.Join(missing, ", "))}}
}
