package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// The Network is the service intent object (contracts/network-spec.md §1–§3, data-model.md
// §12). Its schema is structural, rejects unknown fields and carries every same-object rule of
// contracts/crd-api.md's rule table as a CEL rule; the cross-object rules (attachment
// resolvability, one owner per (node, port, vlan), one tagging mode per port across objects,
// binding exclusivity, a standalone list's subinterface, qualification) are the admission
// webhook's, and the band a VLAN falls in is decided by the mapper (tier path) and the
// provider's claim gate (cluster-tooling path) — never by CEL, which cannot see a claim
// (AD-33, AD-41).

// VLANID is a service VLAN. Structurally 1..4094; the platform's whole VLAN space 100..4000 is
// enforced with both bands stated — 100–999 to name from, 1000–4000 the allocation
// authority's (AD-33). Which band a value falls in is not a CEL question.
//
// +kubebuilder:validation:Minimum=1
// +kubebuilder:validation:Maximum=4094
// +kubebuilder:validation:XValidation:rule="self >= 100 && self <= 4000",messageExpression="'VLAN ' + ((self >= 1000 ? ['0','1','2','3','4','5','6','7','8','9'][self / 1000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self % 10] : (self >= 100 ? ['0','1','2','3','4','5','6','7','8','9'][self / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self % 10] : (self >= 10 ? ['0','1','2','3','4','5','6','7','8','9'][self / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self % 10] : ['0','1','2','3','4','5','6','7','8','9'][self % 10])))) + ' is outside the platform VLAN space 100–4000: name a VLAN from the naming band 100–999; the band 1000–4000 belongs to the allocation authority'",message="VLAN is outside the platform VLAN space 100–4000: name a VLAN from the naming band 100–999; the band 1000–4000 belongs to the allocation authority"
type VLANID int64

// AttachmentVLAN is the VLAN of an attachment: structurally 1..4094. The platform VLAN space
// 100..4000 is enforced on it by a NetworkSpec rule, except on an accessLists-only object, whose
// attachment VLAN is a reference to another service's subinterface and is held to the
// structural range alone (AD-47).
//
// +kubebuilder:validation:Minimum=1
// +kubebuilder:validation:Maximum=4094
type AttachmentVLAN int64

// VNI is a VXLAN network identifier within the device range 1..65535, because the EVPN
// instance identifier is derived from it. The allocation band is the VNI index's own range
// and is enforced by the translator and the allocation authority, not here (AD-10).
//
// +kubebuilder:validation:XValidation:rule="self >= 1 && self <= 65535",messageExpression="'VNI ' + (self >= 0 && self < 1000000 ? ((self >= 100000 ? ['0','1','2','3','4','5','6','7','8','9'][self / 100000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 10000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 1000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self % 10] : (self >= 10000 ? ['0','1','2','3','4','5','6','7','8','9'][self / 10000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 1000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self % 10] : (self >= 1000 ? ['0','1','2','3','4','5','6','7','8','9'][self / 1000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self % 10] : (self >= 100 ? ['0','1','2','3','4','5','6','7','8','9'][self / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self % 10] : (self >= 10 ? ['0','1','2','3','4','5','6','7','8','9'][self / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self % 10] : ['0','1','2','3','4','5','6','7','8','9'][self % 10])))))) : 'value') + ' is outside the device range 1..65535 (the EVPN instance identifier is derived from the VNI)'",message="VNI is outside the device range 1..65535 (the EVPN instance identifier is derived from the VNI)"
type VNI int64

// RouteTarget is a derived route target, target:<fabricASN>:<vni>.
//
// +kubebuilder:validation:MaxLength=24
// +kubebuilder:validation:Pattern=`^target:[0-9]{1,10}:[0-9]{1,5}$`
type RouteTarget string

// IPPrefix is a CIDR prefix, IPv4 or IPv6.
//
// +kubebuilder:validation:MaxLength=43
// +kubebuilder:validation:XValidation:rule="isCIDR(self)",message="must be a CIDR prefix"
type IPPrefix string

// RouteTargets are the explicitly rendered route targets of one EVPN instance. They are
// derived — target:<fabricASN>:<vni> for this object's own VNI — and never chosen.
type RouteTargets struct {
	// Import route targets.
	// +kubebuilder:validation:MaxItems=4
	// +listType=set
	// +optional
	Import []RouteTarget `json:"import,omitempty"`
	// Export route targets.
	// +kubebuilder:validation:MaxItems=4
	// +listType=set
	// +optional
	Export []RouteTarget `json:"export,omitempty"`
}

// NetworkVLAN is a local VLAN — a bridge domain with no overlay (the vlan construct). It is
// its own list, never a bridge domain with a zero L2VNI (D-11).
type NetworkVLAN struct {
	// Name of the entry; a DNS-1123 label, the map key.
	Name DNSLabel `json:"name"`
	// VLAN of the local bridge domain. Immutable once the Network is accepted.
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="spec.vlans[].vlan is immutable once the Network is accepted: changing it is a removal and a new service (FR-109)"
	VLAN VLANID `json:"vlan"`
}

// EVPNSpec is the EVPN half of a bridge domain.
type EVPNSpec struct {
	// RouteTargets rendered explicitly as target:<fabricASN>:<l2vni>.
	// +optional
	RouteTargets *RouteTargets `json:"routeTargets,omitempty"`
}

// IRBSpec is the anycast gateway of a mac-vrf: the integrated-routing subinterface irb0.<vlan>
// attached to the bridge domain and to the routed instance named by VRF.
//
// +kubebuilder:validation:XValidation:rule="has(self.gatewayIPv4) || has(self.gatewayIPv6)",message="irb declares at least one address family: gatewayIPv4, gatewayIPv6 or both"
type IRBSpec struct {
	// VRF names the routers[] entry of this object the gateway routes into.
	VRF DNSLabel `json:"vrf"`
	// GatewayIPv4 is an IPv4 address with a prefix length, e.g. 10.10.0.1/24.
	// +kubebuilder:validation:MaxLength=18
	// +kubebuilder:validation:XValidation:rule="isCIDR(self) && cidr(self).ip().family() == 4",message="gatewayIPv4 must be an IPv4 address with a prefix length"
	// +optional
	GatewayIPv4 string `json:"gatewayIPv4,omitempty"`
	// GatewayIPv6 is an IPv6 address with a prefix length; never link-local.
	// +kubebuilder:validation:MaxLength=43
	// +kubebuilder:validation:XValidation:rule="isCIDR(self) && cidr(self).ip().family() == 6",message="gatewayIPv6 must be an IPv6 address with a prefix length"
	// +kubebuilder:validation:XValidation:rule="!isCIDR(self) || !cidr(self).ip().isLinkLocalUnicast()",message="gatewayIPv6 must not be a link-local address"
	// +optional
	GatewayIPv6 string `json:"gatewayIPv6,omitempty"`
}

// BridgeDomain is a fabric-wide bridge domain (the mac-vrf construct): one VLAN, a non-zero
// L2VNI, explicitly rendered route targets and, with an anycast gateway, an irb.
//
// +kubebuilder:validation:XValidation:rule="!has(self.evpn) || !has(self.evpn.routeTargets) || ((!has(self.evpn.routeTargets.__import__) || self.evpn.routeTargets.__import__.all(t, !t.matches('^target:[0-9]{1,10}:[0-9]{1,5}$') || int(t.substring(t.lastIndexOf(':') + 1)) == self.l2vni)) && (!has(self.evpn.routeTargets.export) || self.evpn.routeTargets.export.all(t, !t.matches('^target:[0-9]{1,10}:[0-9]{1,5}$') || int(t.substring(t.lastIndexOf(':') + 1)) == self.l2vni)))",message="bridgeDomains[].evpn.routeTargets must be target:<fabricASN>:<l2vni> for this bridge domain's own l2vni: route targets are derived, never chosen"
type BridgeDomain struct {
	// Name of the entry; a DNS-1123 label, the map key.
	Name DNSLabel `json:"name"`
	// VLAN of the bridge domain; every attachment carries it. Immutable once accepted.
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="spec.bridgeDomains[].vlan is immutable once the Network is accepted: changing it is a removal and a new service (FR-109)"
	VLAN VLANID `json:"vlan"`
	// L2VNI of the bridge domain. Immutable once accepted.
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="spec.bridgeDomains[].l2vni is immutable once the Network is accepted: changing it is a removal and a new service (FR-109)"
	L2VNI VNI `json:"l2vni"`
	// EVPN is the EVPN instance of the bridge domain.
	// +optional
	EVPN *EVPNSpec `json:"evpn,omitempty"`
	// IRB is present iff the mac-vrf declares an anycast gateway.
	// +optional
	IRB *IRBSpec `json:"irb,omitempty"`
}

// NetworkRouter is a routed instance (the ip-vrf construct, or the routed half of a mac-vrf
// with a gateway). There is no route-distinguisher field: the device derives it.
//
// +kubebuilder:validation:XValidation:rule="!has(self.routeTargets) || ((!has(self.routeTargets.__import__) || self.routeTargets.__import__.all(t, !t.matches('^target:[0-9]{1,10}:[0-9]{1,5}$') || int(t.substring(t.lastIndexOf(':') + 1)) == self.l3vni)) && (!has(self.routeTargets.export) || self.routeTargets.export.all(t, !t.matches('^target:[0-9]{1,10}:[0-9]{1,5}$') || int(t.substring(t.lastIndexOf(':') + 1)) == self.l3vni)))",message="routers[].routeTargets must be target:<fabricASN>:<l3vni> for this router's own l3vni: route targets are derived, never chosen"
type NetworkRouter struct {
	// Name of the entry; a DNS-1123 label, the map key.
	Name DNSLabel `json:"name"`
	// RouteTargets rendered explicitly as target:<fabricASN>:<l3vni>.
	// +optional
	RouteTargets *RouteTargets `json:"routeTargets,omitempty"`
	// L3VNI of the routed instance. Immutable once accepted.
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="spec.routers[].l3vni is immutable once the Network is accepted: changing it is a removal and a new service (FR-109)"
	L3VNI VNI `json:"l3vni"`
	// Prefixes the routed instance declares; mutable.
	// +kubebuilder:validation:MaxItems=32
	// +listType=set
	// +optional
	Prefixes []IPPrefix `json:"prefixes,omitempty"`
}

// ACLName is an access-list name: a label unique within its service, sanitised for the device's
// own name rule; the names the device reserves for its own filters are refused by name.
//
// +kubebuilder:validation:MinLength=1
// +kubebuilder:validation:MaxLength=64
// +kubebuilder:validation:Pattern=`^[A-Za-z0-9][A-Za-z0-9_-]*$`
// +kubebuilder:validation:XValidation:rule="!(self.lowerAscii() in ['system', 'capture'])",messageExpression="'access-list name ' + self + ' is reserved by the device for its own filters'",message="access-list name is reserved by the device for its own filters (system, capture)"
type ACLName string

// ACLProtocol is any, an IP protocol number 0–255, or a known protocol name.
//
// +kubebuilder:validation:MaxLength=8
// +kubebuilder:validation:Pattern=`^(any|tcp|udp|icmp|icmp6|icmpv6|igmp|gre|esp|ah|ospf|pim|vrrp|sctp|[0-9]{1,3})$`
// +kubebuilder:validation:XValidation:rule="!self.matches('^[0-9]+$') || int(self) <= 255",message="an IP protocol number lies in 0–255"
type ACLProtocol string

// ACLPort is a port or an inclusive lo-hi range within 0–65535, hi >= lo.
//
// +kubebuilder:validation:MaxLength=11
// +kubebuilder:validation:Pattern=`^[0-9]{1,5}(-[0-9]{1,5})?$`
// +kubebuilder:validation:XValidation:rule="!self.matches('^[0-9]{1,5}(-[0-9]{1,5})?$') || (self.split('-').all(p, int(p) <= 65535) && (self.split('-').size() == 1 || int(self.split('-')[0]) <= int(self.split('-')[1])))",message="a port is 0–65535 and a range lo-hi has hi >= lo"
type ACLPort string

// ACLRule is one ordered rule. Rules are evaluated in ascending priority and the first match
// wins; priority 65535 is reserved for the default action.
//
// +kubebuilder:validation:XValidation:rule="(!has(self.sourcePort) && !has(self.destinationPort)) || (has(self.protocol) && self.protocol in ['tcp', 'udp', '6', '17'])",messageExpression="'rule ' + self.name + ': an L4 port is allowed only with protocol tcp or udp'",message="an L4 port is allowed only with protocol tcp or udp"
type ACLRule struct {
	// Name of the rule, unique within the list; the map key.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=64
	Name string `json:"name"`
	// Priority is rendered unchanged as the device's entry sequence number; 1–65534.
	// +kubebuilder:validation:XValidation:rule="self >= 1 && self <= 65534",messageExpression="'priority ' + (self >= 0 && self < 1000000 ? ((self >= 100000 ? ['0','1','2','3','4','5','6','7','8','9'][self / 100000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 10000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 1000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self % 10] : (self >= 10000 ? ['0','1','2','3','4','5','6','7','8','9'][self / 10000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 1000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self % 10] : (self >= 1000 ? ['0','1','2','3','4','5','6','7','8','9'][self / 1000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self % 10] : (self >= 100 ? ['0','1','2','3','4','5','6','7','8','9'][self / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self % 10] : (self >= 10 ? ['0','1','2','3','4','5','6','7','8','9'][self / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][self % 10] : ['0','1','2','3','4','5','6','7','8','9'][self % 10])))))) : 'value') + ' is outside the usable range 1–65534: 65535 is reserved for the default action'",message="priority is outside the usable range 1–65534: 65535 is reserved for the default action"
	Priority int64 `json:"priority"`
	// Action is permit or deny.
	// +kubebuilder:validation:Enum=permit;deny
	Action string `json:"action"`
	// Protocol matched; any, a number 0–255 or a known name.
	// +optional
	Protocol ACLProtocol `json:"protocol,omitempty"`
	// SourcePrefix in the list's address family.
	// +optional
	SourcePrefix IPPrefix `json:"sourcePrefix,omitempty"`
	// DestinationPrefix in the list's address family.
	// +optional
	DestinationPrefix IPPrefix `json:"destinationPrefix,omitempty"`
	// SourcePort, TCP and UDP only.
	// +optional
	SourcePort ACLPort `json:"sourcePort,omitempty"`
	// DestinationPort, TCP and UDP only.
	// +optional
	DestinationPort ACLPort `json:"destinationPort,omitempty"`
	// Description carried into the rendered entry's description.
	// +kubebuilder:validation:MaxLength=255
	// +optional
	Description string `json:"description,omitempty"`
}

// AccessList is a named, staged, address-family-scoped, ordered set of rules bound to the
// subinterfaces of its service's attachments.
//
// +kubebuilder:validation:XValidation:rule="self.rules.all(r, self.rules.exists_one(o, o.priority == r.priority))",messageExpression="'access list ' + self.name + ': rule priorities must be distinct; priority ' + self.rules.map(r, !self.rules.exists_one(o, o.priority == r.priority) ? (r.priority >= 0 && r.priority < 1000000 ? ((r.priority >= 100000 ? ['0','1','2','3','4','5','6','7','8','9'][r.priority / 100000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][r.priority / 10000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][r.priority / 1000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][r.priority / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][r.priority / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][r.priority % 10] : (r.priority >= 10000 ? ['0','1','2','3','4','5','6','7','8','9'][r.priority / 10000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][r.priority / 1000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][r.priority / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][r.priority / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][r.priority % 10] : (r.priority >= 1000 ? ['0','1','2','3','4','5','6','7','8','9'][r.priority / 1000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][r.priority / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][r.priority / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][r.priority % 10] : (r.priority >= 100 ? ['0','1','2','3','4','5','6','7','8','9'][r.priority / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][r.priority / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][r.priority % 10] : (r.priority >= 10 ? ['0','1','2','3','4','5','6','7','8','9'][r.priority / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][r.priority % 10] : ['0','1','2','3','4','5','6','7','8','9'][r.priority % 10])))))) : 'value') : '-').filter(p, p != '-')[0] + ' is used more than once'",message="rule priorities must be distinct within an access list"
// +kubebuilder:validation:XValidation:rule="self.rules.all(r, (!has(r.sourcePrefix) || !isCIDR(r.sourcePrefix) || cidr(r.sourcePrefix).ip().family() == (self.type == 'ipv4' ? 4 : 6)) && (!has(r.destinationPrefix) || !isCIDR(r.destinationPrefix) || cidr(r.destinationPrefix).ip().family() == (self.type == 'ipv4' ? 4 : 6)))",messageExpression="'access list ' + self.name + ' is of type ' + self.type + ': every prefix must be in that address family'",message="every prefix of an access list must be in the list's address family"
type AccessList struct {
	// Name of the list.
	Name ACLName `json:"name"`
	// Stage is ingress or egress.
	// +kubebuilder:validation:Enum=ingress;egress
	Stage string `json:"stage"`
	// Type is the address family, ipv4 or ipv6.
	// +kubebuilder:validation:Enum=ipv4;ipv6
	Type string `json:"type"`
	// DefaultAction, when declared, renders a terminal match-all entry at 65535.
	// +kubebuilder:validation:Enum=permit;deny
	// +optional
	DefaultAction string `json:"defaultAction,omitempty"`
	// Rules, at least one; names distinct (map keyed by name).
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=64
	// +listType=map
	// +listMapKey=name
	Rules []ACLRule `json:"rules"`
}

// NetworkAttachment is a node, a port and optionally a VLAN; it resolves through the Fabric
// site inventory to exactly one subinterface, <port>.<vlan>, or <port>.0 when none is named.
type NetworkAttachment struct {
	// Node the attachment is on.
	Node DNSLabel `json:"node"`
	// Attachment is the port, in the device's own naming.
	Attachment PortName `json:"attachment"`
	// VLAN of the subinterface; absent for the untagged subinterface.
	// +optional
	VLAN *AttachmentVLAN `json:"vlan,omitempty"`
	// VRF names the routers[] entry of an ip-vrf attachment.
	// +optional
	VRF DNSLabel `json:"vrf,omitempty"`
}

// NetworkSpec is the service intent. Exactly one of the five shapes of
// contracts/network-spec.md §2 is present: vlans, bridgeDomains, bridgeDomains+routers with an
// irb, routers, or accessLists alone — any of the first four may carry accessLists too.
//
// +kubebuilder:validation:XValidation:rule="has(self.vlans) || has(self.bridgeDomains) || has(self.routers) || has(self.accessLists)",message="one of vlans, bridgeDomains, routers or accessLists must be present"
// +kubebuilder:validation:XValidation:rule="!(has(self.vlans) && has(self.bridgeDomains))",message="vlans and bridgeDomains cannot both be present: a local VLAN and a fabric-wide bridge domain are different constructs"
// +kubebuilder:validation:XValidation:rule="!(has(self.vlans) && has(self.routers))",message="vlans and routers cannot both be present: a vlan is not routed; ask for a mac-vrf with an irb, or an ip-vrf"
// +kubebuilder:validation:XValidation:rule="!(has(self.bridgeDomains) && has(self.routers)) || self.bridgeDomains.all(b, has(b.irb))",message="bridgeDomains and routers can both be present only when the bridge domain carries an irb pointing at the router"
// +kubebuilder:validation:XValidation:rule="!has(self.bridgeDomains) || self.bridgeDomains.all(b, !has(b.irb) || (has(self.routers) && self.routers.exists(r, r.name == b.irb.vrf)))",message="bridgeDomains[].irb requires a routers entry: irb.vrf must name a routers entry of this object"
// +kubebuilder:validation:XValidation:rule="!(has(self.bridgeDomains) && has(self.routers)) || self.bridgeDomains.all(b, self.routers.all(r, b.l2vni != r.l3vni))",message="a service's L2VNI and L3VNI differ: bridgeDomains[].l2vni equals routers[].l3vni"
// +kubebuilder:validation:XValidation:rule="(has(self.accessLists) && !has(self.vlans) && !has(self.bridgeDomains) && !has(self.routers)) || self.attachments.all(a, !has(a.vlan) || (a.vlan >= 100 && a.vlan <= 4000))",messageExpression="'attachment VLAN ' + self.attachments.map(a, has(a.vlan) && (a.vlan < 100 || a.vlan > 4000) ? ((a.vlan >= 1000 ? ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 1000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan % 10] : (a.vlan >= 100 ? ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan % 10] : (a.vlan >= 10 ? ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan % 10] : ['0','1','2','3','4','5','6','7','8','9'][a.vlan % 10])))) : '-').filter(x, x != '-')[0] + ' is outside the platform VLAN space 100–4000: name a VLAN from the naming band 100–999; the band 1000–4000 belongs to the allocation authority'",message="an attachment VLAN is outside the platform VLAN space 100–4000: name a VLAN from the naming band 100–999; the band 1000–4000 belongs to the allocation authority"
// +kubebuilder:validation:XValidation:rule="!has(self.vlans) || self.attachments.all(a, has(a.vlan) && self.vlans.exists(v, v.vlan == a.vlan))",message="one VLAN per bridge domain: every attachment of a vlan service carries the VLAN of its vlans[] entry"
// +kubebuilder:validation:XValidation:rule="!has(self.bridgeDomains) || self.attachments.all(a, has(a.vlan) && self.bridgeDomains.exists(b, b.vlan == a.vlan))",message="one VLAN per bridge domain: every attachment of a bridgeDomains service carries the VLAN of its bridgeDomains[] entry"
// +kubebuilder:validation:XValidation:rule="self.attachments.all(a, !has(a.vrf) || (has(self.routers) && !has(self.bridgeDomains) && self.routers.exists(r, r.name == a.vrf)))",message="attachments[].vrf is set only on an ip-vrf attachment and names a routers entry of this object"
// +kubebuilder:validation:XValidation:rule="!(has(self.routers) && !has(self.bridgeDomains)) || self.attachments.all(a, has(a.vrf))",message="every attachment of an ip-vrf carries vrf naming its routers entry"
// +kubebuilder:validation:XValidation:rule="has(self.vlans) == has(oldSelf.vlans) && (!has(self.vlans) || sets.equivalent(self.vlans.map(e, e.name), oldSelf.vlans.map(e, e.name)))",message="spec.vlans entries cannot be added, removed or renamed once the Network is accepted: changing them is a removal and a new service (FR-109)"
// +kubebuilder:validation:XValidation:rule="has(self.bridgeDomains) == has(oldSelf.bridgeDomains) && (!has(self.bridgeDomains) || sets.equivalent(self.bridgeDomains.map(e, e.name), oldSelf.bridgeDomains.map(e, e.name)))",message="spec.bridgeDomains entries cannot be added, removed or renamed once the Network is accepted: changing them is a removal and a new service (FR-109)"
// +kubebuilder:validation:XValidation:rule="has(self.routers) == has(oldSelf.routers) && (!has(self.routers) || sets.equivalent(self.routers.map(e, e.name), oldSelf.routers.map(e, e.name)))",message="spec.routers entries cannot be added, removed or renamed once the Network is accepted: changing them is a removal and a new service (FR-109)"
// +kubebuilder:validation:XValidation:rule="(has(self.accessLists) && !has(self.vlans) && !has(self.bridgeDomains) && !has(self.routers)) || self.attachments.all(a, !(has(a.vlan) && a.vlan >= 1000 && a.vlan <= 4000 && !oldSelf.attachments.exists(o, o.node == a.node && o.attachment == a.attachment && has(o.vlan) && o.vlan == a.vlan) && !(has(self.vlans) && self.vlans.exists(v, v.vlan == a.vlan)) && !(has(self.bridgeDomains) && self.bridgeDomains.exists(b, b.vlan == a.vlan))))",messageExpression="'an attachment added to an accepted Network carries VLAN ' + self.attachments.map(a, has(a.vlan) && a.vlan >= 1000 && a.vlan <= 4000 && !oldSelf.attachments.exists(o, o.node == a.node && o.attachment == a.attachment && has(o.vlan) && o.vlan == a.vlan) && !(has(self.vlans) && self.vlans.exists(v, v.vlan == a.vlan)) && !(has(self.bridgeDomains) && self.bridgeDomains.exists(b, b.vlan == a.vlan)) ? ((a.vlan >= 1000 ? ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 1000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan % 10] : (a.vlan >= 100 ? ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan % 10] : (a.vlan >= 10 ? ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan % 10] : ['0','1','2','3','4','5','6','7','8','9'][a.vlan % 10])))) : '-').filter(x, x != '-')[0] + ', which lies in the allocation band 1000–4000 and is not a VLAN this object already carries in vlans[] or bridgeDomains[]: an added attachment may carry a VLAN from the naming band 100–999, or none; an attachment on a new allocation-band VLAN is a new service'",message="an attachment added to an accepted Network carries a VLAN in the allocation band 1000–4000 that the object does not already carry in vlans[] or bridgeDomains[]: an added attachment may carry a VLAN from the naming band 100–999, or none; an attachment on a new allocation-band VLAN is a new service"
type NetworkSpec struct {
	// Description of the service.
	// +kubebuilder:validation:MaxLength=255
	// +optional
	Description string `json:"description,omitempty"`
	// VLANs — the vlan construct; entries immutable once accepted (map keyed by name).
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=1
	// +listType=map
	// +listMapKey=name
	// +optional
	VLANs []NetworkVLAN `json:"vlans,omitempty"`
	// BridgeDomains — the mac-vrf construct; entries immutable once accepted.
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=1
	// +listType=map
	// +listMapKey=name
	// +optional
	BridgeDomains []BridgeDomain `json:"bridgeDomains,omitempty"`
	// Routers — the ip-vrf construct, or the routed half of a mac-vrf with a gateway.
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=1
	// +listType=map
	// +listMapKey=name
	// +optional
	Routers []NetworkRouter `json:"routers,omitempty"`
	// AccessLists — the acl construct alone, or the filter of another construct; mutable.
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=1
	// +listType=map
	// +listMapKey=name
	// +optional
	AccessLists []AccessList `json:"accessLists,omitempty"`
	// Attachments, at least one; mutable, except that an added attachment may not bring a
	// new allocation-band VLAN (AD-47).
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=64
	// +listType=atomic
	// +kubebuilder:validation:XValidation:rule="self.all(a, self.exists_one(b, b.node == a.node && b.attachment == a.attachment && has(a.vlan) == has(b.vlan) && (!has(a.vlan) || a.vlan == b.vlan)))",messageExpression="'two attachments resolve to one subinterface: ' + self.map(a, !self.exists_one(b, b.node == a.node && b.attachment == a.attachment && has(a.vlan) == has(b.vlan) && (!has(a.vlan) || a.vlan == b.vlan)) ? a.node + ' ' + a.attachment + '.' + (has(a.vlan) ? ((a.vlan >= 1000 ? ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 1000 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan % 10] : (a.vlan >= 100 ? ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 100 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan % 10] : (a.vlan >= 10 ? ['0','1','2','3','4','5','6','7','8','9'][a.vlan / 10 % 10] + ['0','1','2','3','4','5','6','7','8','9'][a.vlan % 10] : ['0','1','2','3','4','5','6','7','8','9'][a.vlan % 10])))) : '0') : '-').filter(x, x != '-')[0] + ' is named more than once'",message="two attachments resolve to one subinterface (node, port, vlan)"
	// +kubebuilder:validation:XValidation:rule="self.all(a, !self.exists(b, b.node == a.node && b.attachment == a.attachment && has(a.vlan) != has(b.vlan)))",messageExpression="'port ' + self.map(a, self.exists(b, b.node == a.node && b.attachment == a.attachment && has(a.vlan) != has(b.vlan)) ? a.node + ' ' + a.attachment : '-').filter(x, x != '-')[0] + ' carries an untagged and a tagged attachment in this object: tagging is a property of the port, one tagging mode per port'",message="a port carries an untagged and a tagged attachment in this object: one tagging mode per port"
	Attachments []NetworkAttachment `json:"attachments"`
}

// ClaimOrigin says who made a claim backing an allocated value (FR-109).
// +kubebuilder:validation:Enum=adopted;created
type ClaimOrigin string

const (
	// ClaimOriginAdopted — the tier made the claim and the provider adopted it.
	ClaimOriginAdopted ClaimOrigin = "adopted"
	// ClaimOriginCreated — the provider made the claim.
	ClaimOriginCreated ClaimOrigin = "created"
)

// ClaimIndexKind is the index a claim draws from.
// +kubebuilder:validation:Enum=vlan;genid
type ClaimIndexKind string

const (
	// ClaimIndexVLAN is the VLAN index.
	ClaimIndexVLAN ClaimIndexKind = "vlan"
	// ClaimIndexGENID is the generic-identifier (VNI) index.
	ClaimIndexGENID ClaimIndexKind = "genid"
)

// ClaimRef is one entry of status.claimRefs[] — exactly the five fields of
// contracts/crd-api.md §Status, the one list (AD-56).
type ClaimRef struct {
	// Name is the claim object's name — deterministic, <namespace>.<name>.<role>.
	// +kubebuilder:validation:MaxLength=253
	Name string `json:"name"`
	// Namespace is the allocation namespace the claim lives in.
	// +kubebuilder:validation:MaxLength=63
	Namespace string `json:"namespace"`
	// IndexKind is the index the claim draws from: the VLAN index or the VNI index.
	IndexKind ClaimIndexKind `json:"indexKind"`
	// Value is the identifier the claim reports.
	Value int64 `json:"value"`
	// Origin is adopted (the tier made it) or created (the provider did). Written once.
	Origin ClaimOrigin `json:"origin"`
}

// NetworkStatus is the observed state of a Network.
type NetworkStatus struct {
	// ObservedGeneration is the generation the status reflects.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
	// LastVerifiedTime is the last scheduled re-verification that ran — completed its
	// read-back, whatever it found (FR-107, AD-54).
	// +optional
	LastVerifiedTime *metav1.Time `json:"lastVerifiedTime,omitempty"`
	// Conditions are the standard conditions of data-model.md §18.
	// +listType=map
	// +listMapKey=type
	// +kubebuilder:validation:MaxItems=16
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
	// ClaimRefs are the claims backing every allocated value, each adopted or created.
	// +kubebuilder:validation:MaxItems=16
	// +listType=atomic
	// +optional
	ClaimRefs []ClaimRef `json:"claimRefs,omitempty"`
	// RenderedConfigs are the generated Config references with their render hashes and
	// per-target phase and reason.
	// +kubebuilder:validation:MaxItems=64
	// +listType=atomic
	// +optional
	RenderedConfigs []RenderedConfig `json:"renderedConfigs,omitempty"`
}

// Network is the service intent object — one per service, the only object the intent tier
// writes.
//
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,path=networks,singular=network,categories=agentic-netops
// +kubebuilder:printcolumn:name="Construct",type=string,JSONPath=".metadata.annotations.agentic-netops\\.io/service-type"
// +kubebuilder:printcolumn:name="Tenant",type=string,JSONPath=".metadata.annotations.agentic-netops\\.io/tenant"
// +kubebuilder:printcolumn:name="VLAN",type=integer,JSONPath=".spec['vlans','bridgeDomains'][0].vlan"
// +kubebuilder:printcolumn:name="L2VNI",type=integer,JSONPath=".spec.bridgeDomains[0].l2vni"
// +kubebuilder:printcolumn:name="L3VNI",type=integer,JSONPath=".spec.routers[0].l3vni"
// +kubebuilder:printcolumn:name="Ready",type=string,JSONPath=".status.conditions[?(@.type==\"Ready\")].status"
// +kubebuilder:printcolumn:name="Degraded",type=string,JSONPath=".status.conditions[?(@.type==\"Degraded\")].status"
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=".metadata.creationTimestamp"
// +kubebuilder:validation:XValidation:rule="!self.metadata.name.contains('.')",message="metadata.name must not contain a dot: the generated Config name <source>.<node> is parsed on the last dot"
// +kubebuilder:validation:XValidation:rule="self.metadata.name.size() <= 63",message="metadata.name must be a DNS-1123 label of at most 63 characters, so every claim name <namespace>.<name>.<role> stays within 253"
// +kubebuilder:validation:XValidation:rule="self.metadata.name.matches('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')",message="metadata.name must be a DNS-1123 label: lower-case alphanumerics and '-', starting and ending with an alphanumeric"
type Network struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	// +required
	Spec NetworkSpec `json:"spec"`
	// +optional
	Status NetworkStatus `json:"status,omitempty"`
}

// NetworkList contains a list of Network.
//
// +kubebuilder:object:root=true
type NetworkList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Network `json:"items"`
}

func init() {
	SchemeBuilder.Register(&Network{}, &NetworkList{})
}
