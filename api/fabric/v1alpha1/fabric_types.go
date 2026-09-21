package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// The Fabric is the fabric design (data-model.md §3a): node roles and platforms, underlay
// addressing and the ASN plan as references to allocation indices, the fabric-wide overlay AS,
// route-reflecting spines, the MTU policy and the site inventory of attachable ports. One per
// fabric, in agentic-netops-system. Its validation is CEL alone; it needs no webhook.

// NodeRole is leaf or spine.
// +kubebuilder:validation:Enum=leaf;spine
type NodeRole string

const (
	// NodeRoleLeaf may carry attachments.
	NodeRoleLeaf NodeRole = "leaf"
	// NodeRoleSpine carries no access ports and may reflect routes.
	NodeRoleSpine NodeRole = "spine"
)

// FabricNode is one device of the fabric.
//
// +kubebuilder:validation:XValidation:rule="!has(self.routeReflector) || !self.routeReflector || self.role == 'spine'",message="routeReflector may be set only on a spine"
type FabricNode struct {
	// Name of the node; a DNS-1123 label, the map key.
	Name DNSLabel `json:"name"`
	// Role decides what the fabric reconciler renders and what may carry an attachment.
	// Immutable once the Fabric is accepted.
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="spec.nodes[].role is immutable once the Fabric is accepted"
	Role NodeRole `json:"role"`
	// Platform is a licence-free emulated type carrying the full EVPN-VXLAN feature set.
	// +kubebuilder:validation:Enum=ixr-d2l;ixr-d3l
	Platform string `json:"platform"`
	// SystemIPv4 is the system loopback, a /32; may be omitted and claimed from
	// underlay.loopbackPoolRef.
	// +kubebuilder:validation:MaxLength=18
	// +kubebuilder:validation:XValidation:rule="isCIDR(self) && cidr(self).ip().family() == 4 && cidr(self).prefixLength() == 32",message="systemIPv4 must be an IPv4 /32"
	// +optional
	SystemIPv4 string `json:"systemIPv4,omitempty"`
	// ASN is the underlay AS: unique per leaf, identical across spines; may be claimed from
	// underlay.asnPoolRef. Never the route-target AS.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=4294967295
	// +optional
	ASN *int64 `json:"asn,omitempty"`
	// RouteReflector marks a route-reflecting spine.
	// +optional
	RouteReflector *bool `json:"routeReflector,omitempty"`
}

// PoolRef references an allocation index.
type PoolRef struct {
	// Group of the index, e.g. ipam.be.kuid.dev.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	Group string `json:"group"`
	// Kind of the index, e.g. IPIndex.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=63
	Kind string `json:"kind"`
	// Name of the index.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	Name string `json:"name"`
	// Namespace of the index.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=63
	Namespace string `json:"namespace"`
}

// AddressFamily is ipv4 or ipv6.
// +kubebuilder:validation:Enum=ipv4;ipv6
type AddressFamily string

// UnderlaySpec is the underlay addressing and ASN plan.
type UnderlaySpec struct {
	// AddressFamilies is a non-empty subset of ipv4, ipv6.
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=2
	// +listType=set
	AddressFamilies []AddressFamily `json:"addressFamilies"`
	// LoopbackPoolRef is the index system loopbacks are claimed from.
	// +optional
	LoopbackPoolRef *PoolRef `json:"loopbackPoolRef,omitempty"`
	// LinkPoolRef is the index point-to-point link prefixes are claimed from.
	// +optional
	LinkPoolRef *PoolRef `json:"linkPoolRef,omitempty"`
	// ASNPoolRef is the index underlay AS numbers are claimed from.
	// +optional
	ASNPoolRef *PoolRef `json:"asnPoolRef,omitempty"`
}

// OverlaySpec is the fabric-wide overlay.
type OverlaySpec struct {
	// FabricASN is the one constant every route target is rendered from; immutable.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=4294967295
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="spec.overlay.fabricASN is immutable once the Fabric is accepted: every route target is rendered from it"
	FabricASN int64 `json:"fabricASN"`
	// RouteReflectors names the route-reflecting spines.
	// +kubebuilder:validation:MaxItems=8
	// +listType=set
	// +optional
	RouteReflectors []DNSLabel `json:"routeReflectors,omitempty"`
	// InterASVPN is rendered as inter-as-vpn on every reflecting spine; false is accepted —
	// the declarative way to withdraw reflection (AD-43).
	// +optional
	InterASVPN *bool `json:"interASVPN,omitempty"`
	// TunnelInterface is the fabric constant vxlan0.
	// +kubebuilder:validation:Enum=vxlan0
	// +kubebuilder:default=vxlan0
	// +optional
	TunnelInterface string `json:"tunnelInterface,omitempty"`
}

// MTUSpec is the MTU policy, within the platform envelope; tenantIPMTU == portMTU − 64.
//
// +kubebuilder:validation:XValidation:rule="self.tenantIPMTU == self.portMTU - 64",message="mtu.tenantIPMTU must equal mtu.portMTU - 64"
type MTUSpec struct {
	// PortMTU is /interface[name]/mtu.
	// +kubebuilder:validation:Minimum=1500
	// +kubebuilder:validation:Maximum=9500
	PortMTU int32 `json:"portMTU"`
	// UnderlayIPMTU is the routed subinterface ip-mtu.
	// +kubebuilder:validation:Minimum=1280
	// +kubebuilder:validation:Maximum=9486
	UnderlayIPMTU int32 `json:"underlayIPMTU"`
	// BridgedL2MTU is the bridged subinterface l2-mtu.
	// +kubebuilder:validation:Minimum=1450
	// +kubebuilder:validation:Maximum=9500
	BridgedL2MTU int32 `json:"bridgedL2MTU"`
	// TenantIPMTU is portMTU − 64; also the endpoint interface MTU.
	// +kubebuilder:validation:Minimum=1280
	// +kubebuilder:validation:Maximum=9486
	TenantIPMTU int32 `json:"tenantIPMTU"`
}

// InventoryEntry is one node's attachable (access) and fabric-facing ports.
//
// +kubebuilder:validation:XValidation:rule="!has(self.accessPorts) || !has(self.fabricPorts) || self.accessPorts.all(p, !(p in self.fabricPorts))",messageExpression="'inventory ' + self.node + ': port ' + self.accessPorts.filter(p, p in self.fabricPorts)[0] + ' is listed in both accessPorts and fabricPorts; the lists are disjoint'",message="accessPorts and fabricPorts are disjoint"
// +kubebuilder:validation:XValidation:rule="!has(self.untaggedAccessPorts) || self.untaggedAccessPorts.all(p, has(self.accessPorts) && p in self.accessPorts)",messageExpression="'inventory ' + self.node + ': untaggedAccessPorts lists ' + self.untaggedAccessPorts.filter(p, !has(self.accessPorts) || !(p in self.accessPorts))[0] + ', which is not one of its accessPorts'",message="untaggedAccessPorts must be a subset of the same entry's accessPorts"
type InventoryEntry struct {
	// Node the entry describes; the map key.
	Node DNSLabel `json:"node"`
	// AccessPorts are the only ports an attachment may name; a spine has none.
	// +kubebuilder:validation:MaxItems=128
	// +listType=set
	// +optional
	AccessPorts []PortName `json:"accessPorts,omitempty"`
	// UntaggedAccessPorts declares the access ports rendered vlan-tagging false; a subset of
	// accessPorts, empty by default. Every other access port is rendered vlan-tagging true
	// (AD-68).
	// +kubebuilder:validation:MaxItems=128
	// +listType=set
	// +optional
	UntaggedAccessPorts []PortName `json:"untaggedAccessPorts,omitempty"`
	// FabricPorts are the fabric-facing ports.
	// +kubebuilder:validation:MaxItems=128
	// +listType=set
	// +optional
	FabricPorts []PortName `json:"fabricPorts,omitempty"`
}

// AdminState is the administrative state a maintenance entry renders; today only disable.
// +kubebuilder:validation:Enum=disable
type AdminState string

// AdminStateDisable takes the port out of service.
const AdminStateDisable AdminState = "disable"

// MaintenanceEntry takes one inventory port out of service, declaratively.
type MaintenanceEntry struct {
	// Node of the port.
	Node DNSLabel `json:"node"`
	// Interface is the port, access or fabric, as listed in spec.inventory.
	Interface PortName `json:"interface"`
	// AdminState rendered as /interface[name]/admin-state.
	AdminState AdminState `json:"adminState"`
}

// FabricSpec is the fabric design.
//
// +kubebuilder:validation:XValidation:rule="self.nodes.exists(n, n.role == 'leaf') && self.nodes.exists(n, n.role == 'spine')",message="a Fabric has at least one leaf and one spine"
// +kubebuilder:validation:XValidation:rule="has(self.underlay.loopbackPoolRef) || self.nodes.all(n, has(n.systemIPv4))",message="every node needs a systemIPv4 /32 unless underlay.loopbackPoolRef is set"
// +kubebuilder:validation:XValidation:rule="self.nodes.all(n, !has(n.systemIPv4) || self.nodes.exists_one(o, has(o.systemIPv4) && o.systemIPv4 == n.systemIPv4))",message="systemIPv4 is unique across nodes"
// +kubebuilder:validation:XValidation:rule="has(self.underlay.asnPoolRef) || self.nodes.all(n, has(n.asn))",message="every node needs an asn unless underlay.asnPoolRef is set"
// +kubebuilder:validation:XValidation:rule="self.nodes.all(n, n.role != 'leaf' || !has(n.asn) || self.nodes.exists_one(o, has(o.asn) && o.asn == n.asn))",message="the underlay asn is unique per leaf"
// +kubebuilder:validation:XValidation:rule="self.nodes.all(n, n.role != 'spine' || !has(n.asn) || self.nodes.all(o, o.role != 'spine' || !has(o.asn) || o.asn == n.asn))",message="the underlay asn is shared across spines"
// +kubebuilder:validation:XValidation:rule="!has(self.overlay.routeReflectors) || self.overlay.routeReflectors.all(r, self.nodes.exists(n, n.name == r && n.role == 'spine'))",message="overlay.routeReflectors names spines of spec.nodes"
// +kubebuilder:validation:XValidation:rule="self.inventory.all(i, self.nodes.exists(n, n.name == i.node))",messageExpression="'inventory names node ' + self.inventory.map(i, i.node).filter(x, !self.nodes.exists(n, n.name == x))[0] + ', which is not in spec.nodes'",message="every inventory entry names a node of spec.nodes"
// +kubebuilder:validation:XValidation:rule="self.inventory.all(i, !has(i.accessPorts) || size(i.accessPorts) == 0 || !self.nodes.exists(n, n.name == i.node && n.role == 'spine'))",message="a spine inventory entry has no access ports"
// +kubebuilder:validation:XValidation:rule="!has(self.maintenance) || self.maintenance.all(m, self.inventory.exists(i, i.node == m.node && ((has(i.accessPorts) && m.interface in i.accessPorts) || (has(i.fabricPorts) && m.interface in i.fabricPorts))))",messageExpression="'maintenance names ' + self.maintenance.map(m, self.inventory.exists(i, i.node == m.node && ((has(i.accessPorts) && m.interface in i.accessPorts) || (has(i.fabricPorts) && m.interface in i.fabricPorts))) ? '-' : m.node + ' ' + m.interface).filter(x, x != '-')[0] + ', which is not a port of spec.inventory'",message="every maintenance entry names a port of spec.inventory"
type FabricSpec struct {
	// Nodes of the fabric; names unique (map keyed by name).
	// +kubebuilder:validation:MinItems=2
	// +kubebuilder:validation:MaxItems=32
	// +listType=map
	// +listMapKey=name
	Nodes []FabricNode `json:"nodes"`
	// Underlay addressing and ASN plan.
	Underlay UnderlaySpec `json:"underlay"`
	// Overlay constants.
	Overlay OverlaySpec `json:"overlay"`
	// MTU policy.
	MTU MTUSpec `json:"mtu"`
	// Inventory of attachable and fabric ports per node (map keyed by node).
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=32
	// +listType=map
	// +listMapKey=node
	Inventory []InventoryEntry `json:"inventory"`
	// Maintenance is the one declarative administrative-state knob: at most one entry per
	// (node, interface), each naming a port in the inventory.
	// +kubebuilder:validation:MaxItems=64
	// +listType=map
	// +listMapKey=node
	// +listMapKey=interface
	// +optional
	Maintenance []MaintenanceEntry `json:"maintenance,omitempty"`
}

// AllocationRef is a claim reference for a loopback, link prefix or ASN the Fabric reconciler
// claimed.
type AllocationRef struct {
	// Name of the claim.
	// +kubebuilder:validation:MaxLength=253
	Name string `json:"name"`
	// Namespace of the claim.
	// +kubebuilder:validation:MaxLength=63
	Namespace string `json:"namespace"`
	// IndexKind is ipam or as.
	// +kubebuilder:validation:Enum=ipam;as
	IndexKind string `json:"indexKind"`
	// Purpose says what the value is for, e.g. loopback, link, asn.
	// +kubebuilder:validation:MaxLength=63
	// +optional
	Purpose string `json:"purpose,omitempty"`
	// Node the value belongs to, when per node.
	// +kubebuilder:validation:MaxLength=63
	// +optional
	Node string `json:"node,omitempty"`
	// Value reported by the claim, as text (an address, prefix or AS number).
	// +kubebuilder:validation:MaxLength=64
	// +optional
	Value string `json:"value,omitempty"`
	// Bound is true once the claim reports its value.
	// +optional
	Bound bool `json:"bound,omitempty"`
}

// FindingType is the kind of a durable finding; today only StaleConfigurationPossible.
// +kubebuilder:validation:Enum=StaleConfigurationPossible
type FindingType string

// FindingStaleConfigurationPossible — the device may still carry what the service rendered.
const FindingStaleConfigurationPossible FindingType = "StaleConfigurationPossible"

// ServiceRef identifies a force-released Network.
type ServiceRef struct {
	// +kubebuilder:validation:MaxLength=63
	Namespace string `json:"namespace"`
	// +kubebuilder:validation:MaxLength=63
	Name string `json:"name"`
	// +kubebuilder:validation:MaxLength=64
	UID string `json:"uid"`
}

// ReleasedIdentifier is an allocation released without a read-back.
type ReleasedIdentifier struct {
	// Kind of identifier, e.g. vlan, l2vni, l3vni.
	// +kubebuilder:validation:MaxLength=32
	Kind string `json:"kind"`
	// Index the identifier was drawn from.
	// +kubebuilder:validation:MaxLength=253
	// +optional
	Index string `json:"index,omitempty"`
	// Value of the identifier.
	// +kubebuilder:validation:MaxLength=64
	Value string `json:"value"`
}

// Finding is the durable record of a force-release (FR-103, data-model.md §3a).
type Finding struct {
	// Type of the finding.
	Type FindingType `json:"type"`
	// Service is the force-released Network.
	Service ServiceRef `json:"service"`
	// Node is the device that was unreachable.
	// +kubebuilder:validation:MaxLength=63
	Node string `json:"node"`
	// Identifiers released without a read-back.
	// +kubebuilder:validation:MaxItems=16
	// +listType=atomic
	// +optional
	Identifiers []ReleasedIdentifier `json:"identifiers,omitempty"`
	// DeviceObjects are the object names the service had rendered on that node.
	// +kubebuilder:validation:MaxItems=64
	// +listType=atomic
	// +optional
	DeviceObjects []string `json:"deviceObjects,omitempty"`
	// Reason is the operator's stated reason, copied from the annotation.
	// +kubebuilder:validation:MaxLength=1024
	Reason string `json:"reason"`
	// RecordedAt is when the finding was appended.
	RecordedAt metav1.Time `json:"recordedAt"`
}

// FabricStatus is the observed state of a Fabric.
type FabricStatus struct {
	// ObservedGeneration is the generation the status reflects.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
	// LastVerifiedTime is the last scheduled re-verification that ran (FR-107, AD-54).
	// +optional
	LastVerifiedTime *metav1.Time `json:"lastVerifiedTime,omitempty"`
	// Leaves is the number of leaf nodes (printer column).
	// +optional
	Leaves int32 `json:"leaves,omitempty"`
	// Spines is the number of spine nodes (printer column).
	// +optional
	Spines int32 `json:"spines,omitempty"`
	// Allocated summarises the underlay claims as bound/total (printer column).
	// +kubebuilder:validation:MaxLength=32
	// +optional
	Allocated string `json:"allocated,omitempty"`
	// Allocations are claim references for every loopback, link prefix and ASN.
	// +kubebuilder:validation:MaxItems=256
	// +listType=atomic
	// +optional
	Allocations []AllocationRef `json:"allocations,omitempty"`
	// RenderedConfigs are the per-node priority-10 Configs with render hash and phase.
	// +kubebuilder:validation:MaxItems=32
	// +listType=atomic
	// +optional
	RenderedConfigs []RenderedConfig `json:"renderedConfigs,omitempty"`
	// Findings are the durable force-release records (FR-103).
	// +kubebuilder:validation:MaxItems=256
	// +listType=atomic
	// +optional
	Findings []Finding `json:"findings,omitempty"`
	// Conditions are the standard conditions of data-model.md §18.
	// +listType=map
	// +listMapKey=type
	// +kubebuilder:validation:MaxItems=16
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// Fabric is the fabric design.
//
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,path=fabrics,singular=fabric,categories=agentic-netops
// +kubebuilder:printcolumn:name="Leaves",type=integer,JSONPath=".status.leaves"
// +kubebuilder:printcolumn:name="Spines",type=integer,JSONPath=".status.spines"
// +kubebuilder:printcolumn:name="FabricASN",type=integer,JSONPath=".spec.overlay.fabricASN"
// +kubebuilder:printcolumn:name="Allocated",type=string,JSONPath=".status.allocated"
// +kubebuilder:printcolumn:name="Ready",type=string,JSONPath=".status.conditions[?(@.type==\"Ready\")].status"
// +kubebuilder:printcolumn:name="Degraded",type=string,JSONPath=".status.conditions[?(@.type==\"Degraded\")].status"
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=".metadata.creationTimestamp"
// +kubebuilder:validation:XValidation:rule="!self.metadata.name.contains('.')",message="metadata.name must not contain a dot: the generated Config name <source>.<node> is parsed on the last dot"
// +kubebuilder:validation:XValidation:rule="self.metadata.name.size() <= 63",message="metadata.name must be a DNS-1123 label of at most 63 characters"
type Fabric struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	// +required
	Spec FabricSpec `json:"spec"`
	// +optional
	Status FabricStatus `json:"status,omitempty"`
}

// FabricList contains a list of Fabric.
//
// +kubebuilder:object:root=true
type FabricList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Fabric `json:"items"`
}

func init() {
	SchemeBuilder.Register(&Fabric{}, &FabricList{})
}
