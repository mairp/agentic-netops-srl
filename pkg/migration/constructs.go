package migration

import "strings"

// The construct vocabulary (contracts/construct-vocabulary.md §1–§2; FR-024…FR-028, FR-044).
//
//	vlan      a local broadcast domain: a VLAN and the ports in it
//	mac-vrf   a VLAN extended over the fabric by an L2VNI with EVPN route targets
//	ip-vrf    a routed instance: a VRF with an L3VNI and route targets
//	acl       a filter bound to the attachment subinterfaces a service occupies
//
// `mac-vrf` and `ip-vrf` are the device's own names for its bridged and routed network-instance
// types (FR-099; asserted against the pinned srl_nokia model by TestConstructNamesMatchDeviceModel).
const (
	ConstructVLAN   = "vlan"
	ConstructMACVRF = "mac-vrf"
	ConstructIPVRF  = "ip-vrf"
	ConstructACL    = "acl"
)

// Constructs lists the four constructs in the order they are reported to an operator.
func Constructs() []string {
	return []string{ConstructVLAN, ConstructMACVRF, ConstructIPVRF, ConstructACL}
}

// ConstructList renders Constructs() for a refusal.
func ConstructList() string { return strings.Join(Constructs(), ", ") }

// Resolution is what a spelling names: the construct, and — for a migration alias — the arrival
// vocabulary recorded as provenance (never as a type).
type Resolution struct {
	Construct string
	Source    string
}

// catalogue maps the constructs' and synonyms' keys (Key) to the construct they name
// (construct-vocabulary.md §2 table, first seven rows). The migration aliases — the last six rows —
// are aliases.go's catalogue; Canonicalize consults both.
var catalogue = map[string]string{
	"vlan":       ConstructVLAN,
	"macvrf":     ConstructMACVRF,
	"ipvrf":      ConstructIPVRF,
	"acl":        ConstructACL,
	"l2vni":      ConstructMACVRF,
	"l3vni":      ConstructIPVRF,
	"accesslist": ConstructACL,
}

// Key is the name-resolution key: lower-cased, with every '-', '_', ' ', '.' and '+' deleted, so
// `IP-VRF`, `ip_vrf`, `MAC VRF`, `macvrf` and `Mac-Vrf` are one construct each.
func Key(name string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(strings.TrimSpace(name)) {
		switch r {
		case '-', '_', ' ', '.', '+':
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// Canonicalize resolves any accepted spelling of a construct, synonym or migration alias. ok is
// false for a name that is none of them; the caller refuses it listing the four constructs. For a
// migration alias, Source is the arrival vocabulary (FoldAlias); for anything else it is empty.
func Canonicalize(name string) (Resolution, bool) {
	if c, ok := catalogue[Key(name)]; ok {
		return Resolution{Construct: c}, true
	}
	if c, src, ok := FoldAlias(name); ok {
		return Resolution{Construct: c, Source: src}, true
	}
	return Resolution{}, false
}
