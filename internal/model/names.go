// Package model is the canonical intermediate model between the first-party
// intent (a Fabric or a Network) and the native srl_nokia render (data-model.md
// §13, FR-012). It is pure: every function here is deterministic, performs no
// I/O and allocates nothing. Every derived identifier is a pure function of an
// allocated value, the service identifier or a fabric constant
// (contracts/reconciliation.md Rule 2); nothing is separately allocated at
// render time.
//
// The model depends on no API package: it takes its own input structs so that
// it can be driven by the Fabric and Network reconcilers, the golden tests and
// the path-register guard (T022) alike.
package model

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// Fabric constants (data-model.md §13 "Derivations", §3a). They are constants
// rather than configuration because the golden files depend on them.
const (
	// TunnelInterface is the one tunnel-interface every VXLAN interface lives
	// under (spec.overlay.tunnelInterface is fixed to it).
	TunnelInterface = "vxlan0"
	// IRBInterface is the integrated-routing interface.
	IRBInterface = "irb0"
	// SystemInterface is the loopback carrying the VTEP source and router-id.
	SystemInterface = "system0"
	// DefaultNetworkInstance is the underlay network-instance.
	DefaultNetworkInstance = "default"
	// BGPInstanceID is the only bgp-evpn / bgp-vpn instance id rendered.
	BGPInstanceID uint32 = 1
	// EVPNECMP is the ecmp value on every bgp-evpn instance; the device caps
	// it at 8 on a mac-vrf.
	EVPNECMP uint32 = 8
	// AnycastVirtualRouterID is the anycast-gw virtual-router-id on irb0.
	AnycastVirtualRouterID uint32 = 1
	// DefaultActionSequenceID is the reserved terminal ACL entry
	// (acl-render-contract.md §2).
	DefaultActionSequenceID uint32 = 65535
	// UnderlayGroup and OverlayGroup are the BGP peer-group names.
	UnderlayGroup = "underlay"
	OverlayGroup  = "overlay"
	// LoopbackPrefixSet and LoopbackPolicy name the underlay export/import
	// policy that advertises the system loopbacks.
	LoopbackPrefixSet = "system-loopbacks"
	LoopbackPolicy    = "system-loopbacks-policy"
)

// Device value ranges read off the pinned model set (evidence/02-evpn-constructs.md §2.3).
const (
	minEVI            = 1
	maxEVI            = 65535
	minVNI            = 1
	maxVNI            = 16777215
	maxVXLANIfIndex   = 99999999
	minVLAN           = 1
	maxVLAN           = 4094
	maxSubifIndex     = 9999
	maxNINameLen      = 247 // srl_nokia-comm:restricted-name
	maxFilterNameLen  = 255 // srl_nokia-comm:name
	minSequenceID     = 1
	maxRuleSequenceID = 65534 // 65535 is reserved for the default action
)

var (
	// restrictedNameRE is srl_nokia-comm:restricted-name (network-instance
	// names): no '/', no '*', no quotes, no leading space.
	restrictedNameRE = regexp.MustCompile("^[A-Za-z0-9!@#$%^&()|+=`~.,_:;?-][A-Za-z0-9 !@#$%^&()|+=`~.,_:;?-]*$")
	// nameRE is srl_nokia-comm:name (ACL filter names): as above plus '/'.
	nameRE = regexp.MustCompile("^[A-Za-z0-9!@#$%^&()|+=`~.,/_:;?-][A-Za-z0-9 !@#$%^&()|+=`~.,/_:;?-]*$")
	// serviceIDRE bounds a service identifier to a DNS-1123 label, which is
	// what both the tier's JSON schemas and a Network's metadata.name admit.
	// It is strictly inside both device alphabets, so a derived name is
	// device-safe by construction and is never rewritten.
	serviceIDRE = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`)
)

// maxServiceIDLen is the DNS-1123 label bound (Network metadata.name, crd-api.md
// "Name shape"); the longest derived name, `macvrf-<id>` / `acl-<id>-ingress`,
// then stays far inside the device bounds of 247 and 255.
const maxServiceIDLen = 63

// reservedFilterNames are the ACL filter names the device reserves for its own
// filters (PC-S-12, acl-render-contract.md §2).
var reservedFilterNames = map[string]bool{"system": true, "capture": true}

// Stage is an access-list direction.
type Stage string

const (
	StageIngress Stage = "ingress"
	StageEgress  Stage = "egress"
)

// ValidateServiceID refuses — never rewrites — a service identifier that is not
// a DNS-1123 label of at most 63 characters. Rewriting would break the
// apply/verify/rollback name agreement (D-13, acl-render-contract.md §2).
func ValidateServiceID(id string) error {
	if id == "" {
		return fmt.Errorf("service id is empty")
	}
	if len(id) > maxServiceIDLen {
		return fmt.Errorf("service id %q is %d characters; at most %d", id, len(id), maxServiceIDLen)
	}
	if !serviceIDRE.MatchString(id) {
		return fmt.Errorf("service id %q is not a DNS-1123 label (lower-case alphanumerics and '-')", id)
	}
	return nil
}

// ValidateNetworkInstanceName checks a name against srl_nokia-comm:restricted-name.
func ValidateNetworkInstanceName(name string) error {
	if len(name) < 1 || len(name) > maxNINameLen {
		return fmt.Errorf("network-instance name %q: length %d outside 1..%d", name, len(name), maxNINameLen)
	}
	if !restrictedNameRE.MatchString(name) {
		return fmt.Errorf("network-instance name %q: character outside srl_nokia-comm:restricted-name", name)
	}
	return nil
}

// ValidateFilterName checks a name against srl_nokia-comm:name and refuses the
// device-reserved names.
func ValidateFilterName(name string) error {
	if len(name) < 1 || len(name) > maxFilterNameLen {
		return fmt.Errorf("acl-filter name %q: length %d outside 1..%d", name, len(name), maxFilterNameLen)
	}
	if !nameRE.MatchString(name) {
		return fmt.Errorf("acl-filter name %q: character outside srl_nokia-comm:name", name)
	}
	if reservedFilterNames[name] {
		return fmt.Errorf("acl-filter name %q is reserved by the device for its own filters", name)
	}
	return nil
}

func instanceName(prefix, serviceID string) (string, error) {
	if err := ValidateServiceID(serviceID); err != nil {
		return "", err
	}
	n := prefix + serviceID
	if err := ValidateNetworkInstanceName(n); err != nil {
		return "", err
	}
	return n, nil
}

// VLANInstanceName is `vlan-<serviceId>`, the mac-vrf of a `vlan` construct.
func VLANInstanceName(serviceID string) (string, error) { return instanceName("vlan-", serviceID) }

// MACVRFName is `macvrf-<serviceId>`.
func MACVRFName(serviceID string) (string, error) { return instanceName("macvrf-", serviceID) }

// IPVRFName is `ipvrf-<serviceId>`.
func IPVRFName(serviceID string) (string, error) { return instanceName("ipvrf-", serviceID) }

// FilterName is `acl-<serviceId>-<ingress|egress>` (data-model.md §13).
func FilterName(serviceID string, stage Stage) (string, error) {
	if err := ValidateServiceID(serviceID); err != nil {
		return "", err
	}
	if stage != StageIngress && stage != StageEgress {
		return "", fmt.Errorf("acl stage %q is neither %q nor %q", stage, StageIngress, StageEgress)
	}
	n := "acl-" + serviceID + "-" + string(stage)
	if err := ValidateFilterName(n); err != nil {
		return "", err
	}
	return n, nil
}

// ValidateVNI checks the device VNI range 1..16777215.
func ValidateVNI(vni uint32) error {
	if vni < minVNI || vni > maxVNI {
		return fmt.Errorf("vni %d outside the device range %d..%d", vni, minVNI, maxVNI)
	}
	return nil
}

// EVI is the EVPN instance identifier: evi := vni. The device's evi is
// 1..65535, so a VNI above that cannot derive one and is refused here rather
// than at the device (kuid-claim-profiles.md §1).
func EVI(vni uint32) (uint32, error) {
	if vni < minEVI || vni > maxEVI {
		return 0, fmt.Errorf("vni %d cannot derive an evi: evi := vni must be within %d..%d", vni, minEVI, maxEVI)
	}
	return vni, nil
}

// RouteTarget is `target:<fabricASN>:<vni>`, rendered explicitly for import
// and export alike. It never uses a per-leaf underlay AS (data-model.md §13).
func RouteTarget(fabricASN, vni uint32) (string, error) {
	if fabricASN == 0 {
		return "", fmt.Errorf("fabric ASN must be non-zero")
	}
	if err := ValidateVNI(vni); err != nil {
		return "", err
	}
	// A 4-byte ASN leaves a 2-byte local administrator.
	if fabricASN > 65535 && vni > 65535 {
		return "", fmt.Errorf("route target with 4-byte ASN %d needs a vni <= 65535, got %d", fabricASN, vni)
	}
	return "target:" + strconv.FormatUint(uint64(fabricASN), 10) + ":" + strconv.FormatUint(uint64(vni), 10), nil
}

// VXLANInterfaceIndex is the vxlan-interface index: := vni.
func VXLANInterfaceIndex(vni uint32) (uint32, error) {
	if err := ValidateVNI(vni); err != nil {
		return 0, err
	}
	if vni > maxVXLANIfIndex {
		return 0, fmt.Errorf("vxlan-interface index %d above %d", vni, maxVXLANIfIndex)
	}
	return vni, nil
}

// VXLANInterfaceName is `vxlan0.<index>`.
func VXLANInterfaceName(index uint32) string {
	return TunnelInterface + "." + strconv.FormatUint(uint64(index), 10)
}

// SubinterfaceIndex is := vlan; an untagged attachment (vlan 0) is index 0.
func SubinterfaceIndex(vlan uint32) (uint32, error) {
	if vlan == 0 {
		return 0, nil
	}
	if vlan < minVLAN || vlan > maxVLAN {
		return 0, fmt.Errorf("vlan %d outside the device range %d..%d", vlan, minVLAN, maxVLAN)
	}
	if vlan > maxSubifIndex {
		return 0, fmt.Errorf("subinterface index %d above %d", vlan, maxSubifIndex)
	}
	return vlan, nil
}

// SubinterfaceName is `<port>.<index>`, the device's subinterface reference and
// the ACL binding's interface-id.
func SubinterfaceName(port string, index uint32) string {
	return port + "." + strconv.FormatUint(uint64(index), 10)
}

// IRBSubinterfaceName is `irb0.<vlan>`.
func IRBSubinterfaceName(vlan uint32) (string, error) {
	if vlan < minVLAN || vlan > maxVLAN {
		return "", fmt.Errorf("irb vlan %d outside %d..%d", vlan, minVLAN, maxVLAN)
	}
	return SubinterfaceName(IRBInterface, vlan), nil
}

// SequenceID is := priority, unchanged; 65535 is reserved for the default action.
func SequenceID(priority uint32) (uint32, error) {
	if priority < minSequenceID || priority > maxRuleSequenceID {
		return 0, fmt.Errorf("acl rule priority %d outside %d..%d (65535 is reserved)", priority, minSequenceID, maxRuleSequenceID)
	}
	return priority, nil
}

// ServiceDescription is the network-instance description, e.g.
// "Service 4b7e19c2a05d3f6 (mac-vrf)" (crd-api.md exemplar).
func ServiceDescription(serviceID string, construct Construct) string {
	return fmt.Sprintf("Service %s (%s)", serviceID, construct)
}

// FilterDescription is `<tenant>/<serviceId> <stage>` (acl-render-contract.md §2).
func FilterDescription(tenant, serviceID string, stage Stage) string {
	if tenant == "" {
		return fmt.Sprintf("%s %s", serviceID, stage)
	}
	return fmt.Sprintf("%s/%s %s", tenant, serviceID, stage)
}

// NormalizeInterfaceLabel is the registered topology join label
// (`ethernet-1/49` → `e1-49`, data-model.md §21).
func NormalizeInterfaceLabel(name string) string {
	if rest, ok := strings.CutPrefix(name, "ethernet-"); ok {
		return "e" + strings.ReplaceAll(rest, "/", "-")
	}
	return strings.ReplaceAll(name, "/", "-")
}
