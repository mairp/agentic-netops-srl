package migration

import (
	"fmt"
	"net/netip"
	"regexp"
	"sort"
	"strconv"
)

// The bands (contracts/kuid-claim-profiles.md §1, AD-33, AD-10). The translator's VLAN check is
// structural and only structural (AD-41): a VLAN outside 100–4000 is refused stating both bands, and
// nothing else is said about a VLAN's value — its input cannot tell a named VLAN from an allocated
// one, so a VLAN of 1000–4000 translates. The naming band is the mapper's rule.
const (
	VLANMin        = 100
	VLANNamingMax  = 999
	VLANAllocMin   = 1000
	VLANMax        = 4000
	VNIBandMin     = 10000
	VNIBandMax     = 20000
	maxServiceID   = 15
	maxRouterPrefs = 32
)

var (
	dnsLabel    = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`)
	routeTarget = regexp.MustCompile(`^target:([0-9]{1,10}):([0-9]{1,5})$`)
)

// unsupportedNames folds the spellings of the unsupported claims (construct-vocabulary.md §5) onto
// the name a refusal states. A key not listed is refused under its own name.
var unsupportedNames = map[string]string{
	"te": "traffic-engineering", "tepolicy": "traffic-engineering", "trafficengineering": "traffic-engineering",
	"pseudowireoam": "pseudowire-oam", "pwoam": "pseudowire-oam",
	"controlword":  "control-word",
	"multicastvpn": "multicast-vpn", "mvpn": "multicast-vpn",
	"complexqos": "complex-qos", "qos": "complex-qos",
	"servicechain": "service-chaining", "servicechaining": "service-chaining",
	"rawcli": "raw-device-cli", "cli": "raw-device-cli", "rawdevicecli": "raw-device-cli",
}

func vlanOutOfSpace(path string, v int64) string {
	return fmt.Sprintf("%s: VLAN %d is outside the platform VLAN space %d–%d: the naming band %d–%d is for a VLAN an operator names, and the allocation band %d–%d is the allocation authority's",
		path, v, VLANMin, VLANMax, VLANMin, VLANNamingMax, VLANAllocMin, VLANMax)
}

func vniOutOfBand(path string, v int64) string {
	return fmt.Sprintf("%s: VNI %d is outside the VNI allocation band %d–%d; the band sits inside the device's EVPN instance identifier range 1–65535, because the instance identifier is derived from the VNI",
		path, v, VNIBandMin, VNIBandMax)
}

// routerName, bridgeDomainName and vlanName are the entry names the translator emits (and the
// allocator names its claims after: kuid-claim-profiles.md §2, AD-42).
func routerName(sid string) string       { return "vrf-" + sid }
func bridgeDomainName(sid string) string { return "bd-" + sid }
func vlanName(sid string) string         { return "vlan-" + sid }

// validateService returns every cause of one service, each prefixed with p ("" or "input[i].").
// asn is the ASN its route targets are emitted with (0 when it carries none).
func validateService(in *ServiceInput, p string, opt Options) (causes []string, asn int64) {
	add := func(format string, a ...any) { causes = append(causes, p+fmt.Sprintf(format, a...)) }

	switch {
	case in.ServiceID == "":
		add("serviceId: required; the mapper generates it")
	case len(in.ServiceID) > maxServiceID || !dnsLabel.MatchString(in.ServiceID):
		add("serviceId: %q is not a DNS-1123 label of at most %d characters; it becomes the Network name migr-<serviceId>", in.ServiceID, maxServiceID)
	}
	switch {
	case in.Tenant == "":
		add("tenant: required, never defaulted")
	case !dnsLabel.MatchString(in.Tenant):
		add("tenant: %q is not an RFC 1123 label", in.Tenant)
	}

	keys := make([]string, 0, len(in.Unsupported))
	for k := range in.Unsupported {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		name := unsupportedNames[Key(k)]
		if name == "" {
			name = k
		}
		add("unsupported.%s: unsupported feature: %s; the platform refuses it rather than translating the rest without it", k, name)
	}

	switch {
	case len(in.Endpoints) == 0 && in.Type == ConstructACL:
		add("endpoints: at least one endpoint is required — an access list binds to named attachment subinterfaces (a node, a port and optionally the VLAN of an existing subinterface), never fabric-wide, never to a network instance or a VLAN as such")
	case len(in.Endpoints) == 0:
		add("endpoints: at least one endpoint is required")
	}
	for i, ep := range in.Endpoints {
		path := fmt.Sprintf("endpoints[%d]", i)
		if ep.Node == "" {
			add("%s.node: required", path)
		}
		if ep.Attachment == "" {
			add("%s.attachment: required", path)
		}
		if ep.VLAN != nil && (*ep.VLAN < VLANMin || *ep.VLAN > VLANMax) {
			causes = append(causes, p+vlanOutOfSpace(path+".vlan", *ep.VLAN))
		}
		for _, c := range opt.Site.endpointCauses(path, ep) {
			causes = append(causes, p+c)
		}
	}

	// An access list, on any construct: validated the same way wherever it stands (acl.go).
	if in.ACL != nil {
		causes = append(causes, validateACL(in.ACL, p)...)
	}

	switch in.Type {
	case "":
		add("type: required; the constructs are %s", ConstructList())
	case ConstructVLAN:
		causes = append(causes, validateVLAN(in, p)...)
	case ConstructMACVRF:
		c, a := validateMACVRF(in, p, opt)
		causes, asn = append(causes, c...), a
	case ConstructIPVRF:
		c, a := validateIPVRF(in, p, opt)
		causes, asn = append(causes, c...), a
	case ConstructACL:
		causes = append(causes, validateStandaloneACL(in, p)...)
	default:
		add("type: %q is not a construct this platform offers; the constructs are %s", in.Type, ConstructList())
	}
	// The constraints of the vocabulary the request arrived in, only when it arrived as a migration
	// alias; a request naming the construct directly is subject to none of them (FR-047, aliases.go).
	if in.SourceType != "" {
		causes = append(causes, sourceScopedCauses(in, p)...)
	}
	return causes, asn
}

// sharedVLANCauses: vlan and mac-vrf are ONE broadcast domain, so every endpoint carries the same VLAN.
func sharedVLANCauses(in *ServiceInput, p, construct string) []string {
	var causes []string
	var first *int64
	firstAt := 0
	for i, ep := range in.Endpoints {
		if ep.VLAN == nil {
			causes = append(causes, fmt.Sprintf("%sendpoints[%d].vlan: required for a %s — every endpoint carries the service VLAN", p, i, construct))
			continue
		}
		if first == nil {
			first, firstAt = ep.VLAN, i
			continue
		}
		if *ep.VLAN != *first {
			causes = append(causes, fmt.Sprintf("%sendpoints[%d].vlan: %d differs from endpoints[%d].vlan %d; a %s is one bridge domain, and one bridge domain is one broadcast domain with one VLAN",
				p, i, *ep.VLAN, firstAt, *first, construct))
		}
	}
	return causes
}

func noVRFOnEndpoints(in *ServiceInput, p, construct string) []string {
	var causes []string
	for i, ep := range in.Endpoints {
		if ep.VRF != "" {
			causes = append(causes, fmt.Sprintf("%sendpoints[%d].vrf: a %s endpoint carries no vrf; vrf belongs to an ip-vrf endpoint", p, i, construct))
		}
	}
	return causes
}

func validateVLAN(in *ServiceInput, p string) []string {
	var causes []string
	add := func(format string, a ...any) { causes = append(causes, p+fmt.Sprintf(format, a...)) }
	if in.L2VNI != nil {
		add("l2vni: a vlan is local to its node and carries no L2VNI; the L2VNI belongs to a mac-vrf — ask for a mac-vrf to extend the VLAN over the fabric")
	}
	if in.L3VNI != nil {
		add("l3vni: a vlan is not routed and carries no L3VNI; the L3VNI belongs to an ip-vrf, or to a mac-vrf with an anycastGateway")
	}
	if in.RouteTargets != nil {
		add("routeTargets: a vlan is not advertised by EVPN and has no route targets; route targets belong to a mac-vrf or an ip-vrf")
	}
	if in.AnycastGateway != nil {
		add("anycastGateway: a vlan carries no anycast gateway; the gateway belongs to a mac-vrf")
	}
	if in.AddressFamilies != nil {
		add("addressFamilies: a vlan carries no prefixes; prefixes belong to an ip-vrf")
	}
	causes = append(causes, noVRFOnEndpoints(in, p, ConstructVLAN)...)
	causes = append(causes, sharedVLANCauses(in, p, ConstructVLAN)...)
	causes = append(causes, policyCauses(in, p)...)
	return causes
}

func validateMACVRF(in *ServiceInput, p string, opt Options) ([]string, int64) {
	var causes []string
	add := func(format string, a ...any) { causes = append(causes, p+fmt.Sprintf(format, a...)) }
	gw := in.AnycastGateway
	if in.L2VNI == nil {
		add("l2vni: required for a mac-vrf — the VNI that extends the VLAN over the fabric, claimed from the VNI allocation band %d–%d", VNIBandMin, VNIBandMax)
	} else if *in.L2VNI < VNIBandMin || *in.L2VNI > VNIBandMax {
		causes = append(causes, p+vniOutOfBand("l2vni", *in.L2VNI))
	}
	if in.AddressFamilies != nil {
		add("addressFamilies: a mac-vrf carries no prefixes of its own; prefixes belong to an ip-vrf (a mac-vrf's gateway subnets are its anycastGateway addresses)")
	}
	if gw == nil && in.L3VNI != nil {
		add("l3vni: a mac-vrf carries an L3VNI only with an anycastGateway; the L3VNI belongs to an ip-vrf — ask for an ip-vrf, or add the gateway")
	}
	if gw != nil {
		if in.L3VNI == nil {
			add("l3vni: required for a mac-vrf with an anycastGateway — the L3VNI of the ip-vrf its irb routes into")
		} else {
			if *in.L3VNI < VNIBandMin || *in.L3VNI > VNIBandMax {
				causes = append(causes, p+vniOutOfBand("l3vni", *in.L3VNI))
			}
			if in.L2VNI != nil && *in.L2VNI == *in.L3VNI {
				add("l3vni: %d equals l2vni; a service's L2VNI and L3VNI are two different VNIs", *in.L3VNI)
			}
		}
		if gw.GatewayIPv4 == "" && gw.GatewayIPv6 == "" {
			add("anycastGateway: at least one of gatewayIPv4, gatewayIPv6 is required; an unrequested family is never added")
		}
		if gw.GatewayIPv4 != "" {
			if c := gatewayCause("anycastGateway.gatewayIPv4", gw.GatewayIPv4, true); c != "" {
				causes = append(causes, p+c)
			}
		}
		if gw.GatewayIPv6 != "" {
			if c := gatewayCause("anycastGateway.gatewayIPv6", gw.GatewayIPv6, false); c != "" {
				causes = append(causes, p+c)
			}
		}
		if gw.IPVRF != "" && in.ServiceID != "" && gw.IPVRF != routerName(in.ServiceID) {
			add("anycastGateway.ipVrf: %q is not this service's routed instance %s; a mac-vrf's gateway routes into its own ip-vrf", gw.IPVRF, routerName(in.ServiceID))
		}
	}
	minEndpoints := 2
	if gw != nil {
		minEndpoints = 1
	}
	if n := len(in.Endpoints); n > 0 && n < minEndpoints {
		add("endpoints: a mac-vrf without an anycastGateway needs at least 2 endpoints to bridge between, got %d; a single-node broadcast domain is a vlan", n)
	}
	causes = append(causes, policyCauses(in, p)...)
	causes = append(causes, noVRFOnEndpoints(in, p, ConstructMACVRF)...)
	causes = append(causes, sharedVLANCauses(in, p, ConstructMACVRF)...)

	var vnis []int64
	var primary int64
	if in.L2VNI != nil {
		primary = *in.L2VNI
		vnis = append(vnis, primary)
	}
	if gw != nil && in.L3VNI != nil {
		vnis = append(vnis, *in.L3VNI)
	}
	c, asn := routeTargetCauses(in, p, opt, primary, vnis)
	return append(causes, c...), asn
}

func validateIPVRF(in *ServiceInput, p string, opt Options) ([]string, int64) {
	var causes []string
	add := func(format string, a ...any) { causes = append(causes, p+fmt.Sprintf(format, a...)) }
	if in.L2VNI != nil {
		add("l2vni: an ip-vrf carries no bridge domain and no L2VNI; the L2VNI belongs to a mac-vrf (a mac-vrf with an anycastGateway gives both)")
	}
	if in.AnycastGateway != nil {
		add("anycastGateway: an ip-vrf carries no anycast gateway; the gateway belongs to a mac-vrf, whose irb routes into its own ip-vrf")
	}
	if in.L3VNI == nil {
		add("l3vni: required for an ip-vrf — the VNI of the routed instance, claimed from the VNI allocation band %d–%d", VNIBandMin, VNIBandMax)
	} else if *in.L3VNI < VNIBandMin || *in.L3VNI > VNIBandMax {
		causes = append(causes, p+vniOutOfBand("l3vni", *in.L3VNI))
	}
	af := in.AddressFamilies
	if af == nil || len(af.IPv4Prefixes)+len(af.IPv6Prefixes) == 0 {
		add("addressFamilies: an ip-vrf requires at least one prefix, in ipv4Prefixes or ipv6Prefixes")
	} else {
		for i, s := range af.IPv4Prefixes {
			if c := prefixCause(fmt.Sprintf("addressFamilies.ipv4Prefixes[%d]", i), s, true); c != "" {
				causes = append(causes, p+c)
			}
		}
		for i, s := range af.IPv6Prefixes {
			if c := prefixCause(fmt.Sprintf("addressFamilies.ipv6Prefixes[%d]", i), s, false); c != "" {
				causes = append(causes, p+c)
			}
		}
		if n := len(af.IPv4Prefixes) + len(af.IPv6Prefixes); n > maxRouterPrefs {
			add("addressFamilies: %d prefixes; a routed instance carries at most %d", n, maxRouterPrefs)
		}
	}
	for i, ep := range in.Endpoints {
		switch {
		case ep.VRF == "":
			add("endpoints[%d].vrf: required for an ip-vrf endpoint — this service's routed instance %s", i, routerName(in.ServiceID))
		case in.ServiceID != "" && ep.VRF != routerName(in.ServiceID):
			add("endpoints[%d].vrf: %q is not this service's routed instance %s; an ip-vrf's endpoints attach to its own routed instance", i, ep.VRF, routerName(in.ServiceID))
		}
	}
	causes = append(causes, policyCauses(in, p)...)
	var vnis []int64
	var primary int64
	if in.L3VNI != nil {
		primary = *in.L3VNI
		vnis = append(vnis, primary)
	}
	c, asn := routeTargetCauses(in, p, opt, primary, vnis)
	return append(causes, c...), asn
}

// policyCauses refuses the point-to-point opt-in on any request that did not arrive as the
// point-to-point alias; on one that did, the opt-in is sourceScopedCauses' to judge (aliases.go).
func policyCauses(in *ServiceInput, p string) []string {
	if in.SourceType == SourceVPWS {
		return nil
	}
	if in.Policies != nil && in.Policies.VPWSLimitedEquivalence != nil {
		return []string{p + "policies.vpwsLimitedEquivalence: meaningful only for a request that arrived as the point-to-point migration alias (VPWS); this one did not"}
	}
	return nil
}

func gatewayCause(path, s string, v4 bool) string {
	pfx, err := netip.ParsePrefix(s)
	switch {
	case err != nil:
		return fmt.Sprintf("%s: %q is not an address with a prefix length (e.g. 10.10.0.1/24)", path, s)
	case v4 && !pfx.Addr().Is4():
		return fmt.Sprintf("%s: %s is not an IPv4 address", path, s)
	case !v4 && (pfx.Addr().Is4() || pfx.Addr().Is4In6()):
		return fmt.Sprintf("%s: %s is not an IPv6 address", path, s)
	case !v4 && pfx.Addr().IsLinkLocalUnicast():
		return fmt.Sprintf("%s: %s is link-local; an anycast gateway needs a routable address", path, s)
	case pfx.Masked().Addr() == pfx.Addr():
		return fmt.Sprintf("%s: %s is the subnet's own network address, not a gateway host address", path, s)
	}
	return ""
}

func prefixCause(path, s string, v4 bool) string {
	pfx, err := netip.ParsePrefix(s)
	switch {
	case err != nil:
		return fmt.Sprintf("%s: %q is not a CIDR prefix", path, s)
	case v4 && !pfx.Addr().Is4():
		return fmt.Sprintf("%s: %s is not an IPv4 prefix", path, s)
	case !v4 && pfx.Addr().Is4():
		return fmt.Sprintf("%s: %s is not an IPv6 prefix", path, s)
	case pfx.Masked() != pfx:
		return fmt.Sprintf("%s: %s has host bits set; the prefix is %s", path, s, pfx.Masked())
	}
	return ""
}

// routeTargetCauses checks the derived, read-only route targets: required; every value
// target:<fabricASN>:<vni> for one of this service's own VNIs, the primary VNI's among them in both
// lists, one ASN throughout (FABRIC_ASN when configured). It returns the ASN to emit with.
func routeTargetCauses(in *ServiceInput, p string, opt Options, primary int64, vnis []int64) ([]string, int64) {
	rts := in.RouteTargets
	if rts == nil {
		return []string{p + fmt.Sprintf("routeTargets: required for a %s — the derived target:<fabricASN>:<vni>, shown in the assignment so the second confirmation covers it", in.Type)}, 0
	}
	var causes []string
	asn := opt.FabricASN
	derived := func(vni int64) string {
		if asn != 0 {
			return fmt.Sprintf("target:%d:%d", asn, vni)
		}
		return fmt.Sprintf("target:<fabricASN>:%d", vni)
	}
	check := func(field string, list []string) {
		if len(list) == 0 {
			causes = append(causes, p+fmt.Sprintf("routeTargets.%s: at least one route target is required", field))
			return
		}
		hasPrimary := false
		for i, rt := range list {
			path := fmt.Sprintf("routeTargets.%s[%d]", field, i)
			m := routeTarget.FindStringSubmatch(rt)
			if m == nil {
				causes = append(causes, p+fmt.Sprintf("%s: %q is not a route target of the form target:<fabricASN>:<vni>", path, rt))
				continue
			}
			a, _ := strconv.ParseInt(m[1], 10, 64)
			v, _ := strconv.ParseInt(m[2], 10, 64)
			if asn == 0 {
				asn = a
			}
			own := false
			for _, x := range vnis {
				own = own || x == v
			}
			switch {
			case a != asn || !own:
				want := derived(primary)
				causes = append(causes, p+fmt.Sprintf("%s: %s is not the derived route target %s; route targets are target:<fabricASN>:<vni> for this service's own VNI — derived, never chosen", path, rt, want))
			case v == primary:
				hasPrimary = true
			}
		}
		if !hasPrimary && primary != 0 && len(causes) == 0 {
			causes = append(causes, p+fmt.Sprintf("routeTargets.%s: the derived route target %s is missing", field, derived(primary)))
		}
	}
	check("importRT", rts.ImportRT)
	check("exportRT", rts.ExportRT)
	return causes, asn
}
