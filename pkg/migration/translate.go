package migration

import (
	"fmt"
	"net/netip"
	"strings"
)

// Result is one translation: one Network per service, in input order, and the same objects as a
// YAML stream (documents separated by "---").
type Result struct {
	Manifests []Network
	YAML      string
}

// TranslateJSON is the whole translator: strict parse → canonicalize → validate the whole batch →
// translate. On any refusal it returns a *ValidationError (or *MalformedError) and no manifest.
func TranslateJSON(data []byte, opt Options) (*Result, error) {
	inputs, batch, err := ParseStrictBatch(data)
	if err != nil {
		return nil, err
	}
	return TranslateBatch(inputs, batch, opt)
}

// TranslateBatch validates every input before translating any (all-or-nothing, FR-045) and returns
// every cause of every input. batch prefixes each cause with input[i]. (the request was an array).
func TranslateBatch(inputs []ServiceInput, batch bool, opt Options) (*Result, error) {
	var causes []string
	asns := make([]int64, len(inputs))
	prefix := func(i int) string {
		if batch {
			return fmt.Sprintf("input[%d].", i)
		}
		return ""
	}
	for i := range inputs {
		inputs[i].canonicalize()
		c, asn := validateService(&inputs[i], prefix(i), opt)
		causes = append(causes, c...)
		asns[i] = asn
	}
	causes = append(causes, batchCauses(inputs, prefix)...)
	if len(causes) > 0 {
		return nil, &ValidationError{Causes: causes}
	}
	res := &Result{}
	var docs []string
	for i := range inputs {
		n := translate(&inputs[i], asns[i])
		res.Manifests = append(res.Manifests, n)
		docs = append(docs, n.YAML())
	}
	res.YAML = strings.Join(docs, "---\n")
	return res, nil
}

// subinterface is the one-owner key: (node, port, vlan), vlan 0 for the untagged subinterface.
type subinterface struct {
	node, port string
	vlan       int64
}

type where struct{ svc, ep int }

// batchCauses are the rules that span services: a serviceId is unique in the batch, a (node, port,
// vlan) has one owner (FR-034) and a port carries one tagging mode (AD-20).
func batchCauses(inputs []ServiceInput, prefix func(int) string) []string {
	var causes []string
	ids := map[string]int{}
	for i, in := range inputs {
		if in.ServiceID == "" {
			continue
		}
		if j, ok := ids[in.ServiceID]; ok {
			causes = append(causes, fmt.Sprintf("%sserviceId: %q is also the serviceId of input[%d]; a serviceId is unique within a request", prefix(i), in.ServiceID, j))
			continue
		}
		ids[in.ServiceID] = i
	}

	owners := map[subinterface]where{}
	type modeSeen struct {
		tagged, untagged *where
		reported         bool
	}
	modes := map[[2]string]*modeSeen{}
	for i, in := range inputs {
		switch in.Type {
		case ConstructVLAN, ConstructMACVRF, ConstructIPVRF:
		default:
			continue
		}
		for e, ep := range in.Endpoints {
			if ep.Node == "" || ep.Attachment == "" {
				continue
			}
			var vlan int64
			if ep.VLAN != nil {
				vlan = *ep.VLAN
			}
			key := subinterface{ep.Node, ep.Attachment, vlan}
			sub := fmt.Sprintf("%s.%d", ep.Attachment, vlan)
			here := where{i, e}
			if held, ok := owners[key]; ok {
				if held.svc == i {
					causes = append(causes, fmt.Sprintf("%sendpoints[%d]: duplicates endpoints[%d] — %s subinterface %s is already an attachment of this service", prefix(i), e, held.ep, ep.Node, sub))
				} else {
					holder := inputs[held.svc].ServiceID
					causes = append(causes, fmt.Sprintf("%sendpoints[%d]: %s port %s VLAN %d (subinterface %s) is already held by service %s (%sendpoints[%d]) in this request; one owner per (node, port, vlan)",
						prefix(i), e, ep.Node, ep.Attachment, vlan, sub, holder, prefix(held.svc), held.ep))
				}
			} else {
				owners[key] = here
			}

			pk := [2]string{ep.Node, ep.Attachment}
			m := modes[pk]
			if m == nil {
				m = &modeSeen{}
				modes[pk] = m
			}
			if ep.VLAN == nil {
				if m.untagged == nil {
					m.untagged = &here
				}
			} else if m.tagged == nil {
				m.tagged = &here
			}
			if m.tagged != nil && m.untagged != nil && !m.reported {
				m.reported = true
				other := m.tagged
				mode, otherMode := "untagged", "tagged"
				if ep.VLAN != nil {
					other, mode, otherMode = m.untagged, "tagged", "untagged"
				}
				causes = append(causes, fmt.Sprintf("%sendpoints[%d]: port %s on %s is asked for %s here and %s at %sendpoints[%d] in the same request; a port carries one tagging mode — every subinterface on it tagged, or only the untagged one",
					prefix(i), e, ep.Attachment, ep.Node, mode, otherMode, prefix(other.svc), other.ep))
			}
		}
	}
	return causes
}

func translate(in *ServiceInput, asn int64) Network {
	sid := in.ServiceID
	n := Network{
		APIVersion: APIVersion,
		Kind:       Kind,
		Metadata: Metadata{
			Name: "migr-" + sid,
			Annotations: map[string]string{
				AnnotationTranslator:        TranslatorName,
				AnnotationTranslatorVersion: TranslatorVersion,
				AnnotationMappingVersion:    MappingVersion,
				AnnotationInputHash:         in.CanonicalHash(),
				AnnotationTenant:            in.Tenant,
				AnnotationServiceType:       in.Type,
			},
		},
		Spec: NetworkSpec{Description: fmt.Sprintf("Service %s (%s)", sid, in.Type)},
	}
	if in.SourceType != "" {
		n.Metadata.Annotations[AnnotationSourceServiceType] = in.SourceType
	}
	if in.SourceType == "VPWS" {
		n.Metadata.Annotations[AnnotationLimitedEquivalence] = "vpws-to-mac-vrf"
	}

	rts := func(vni int64) *RouteTargets {
		t := fmt.Sprintf("target:%d:%d", asn, vni)
		return &RouteTargets{Import: []string{t}, Export: []string{t}}
	}
	switch in.Type {
	case ConstructVLAN:
		n.Spec.VLANs = []NetworkVLAN{{Name: vlanName(sid), VLAN: *in.Endpoints[0].VLAN}}
		n.Spec.Attachments = attachments(in.Endpoints, "")
	case ConstructMACVRF:
		bd := BridgeDomain{
			Name:  bridgeDomainName(sid),
			VLAN:  *in.Endpoints[0].VLAN,
			L2VNI: *in.L2VNI,
			EVPN:  &EVPN{RouteTargets: rts(*in.L2VNI)},
		}
		if gw := in.AnycastGateway; gw != nil {
			r := Router{Name: routerName(sid), RouteTargets: rts(*in.L3VNI), L3VNI: *in.L3VNI}
			bd.IRB = &IRB{VRF: r.Name, GatewayIPv4: gw.GatewayIPv4, GatewayIPv6: gw.GatewayIPv6}
			// The routed instance advertises the gateway subnets (network-spec.md §6): declared
			// families only.
			for _, g := range []string{gw.GatewayIPv4, gw.GatewayIPv6} {
				if g != "" {
					r.Prefixes = append(r.Prefixes, netip.MustParsePrefix(g).Masked().String())
				}
			}
			n.Spec.Routers = []Router{r}
		}
		n.Spec.BridgeDomains = []BridgeDomain{bd}
		n.Spec.Attachments = attachments(in.Endpoints, "")
	case ConstructIPVRF:
		r := Router{Name: routerName(sid), RouteTargets: rts(*in.L3VNI), L3VNI: *in.L3VNI}
		r.Prefixes = append(append(r.Prefixes, in.AddressFamilies.IPv4Prefixes...), in.AddressFamilies.IPv6Prefixes...)
		n.Spec.Routers = []Router{r}
		n.Spec.Attachments = attachments(in.Endpoints, r.Name)
	}
	return n
}

func attachments(eps []Endpoint, vrf string) []Attachment {
	out := make([]Attachment, 0, len(eps))
	for _, ep := range eps {
		a := Attachment{Node: ep.Node, Attachment: ep.Attachment, VRF: vrf}
		if ep.VLAN != nil {
			v := *ep.VLAN
			a.VLAN = &v
		}
		out = append(out, a)
	}
	return out
}
