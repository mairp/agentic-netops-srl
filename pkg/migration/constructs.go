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

// catalogue maps every accepted key (Key) to what it names (construct-vocabulary.md §2 table).
var catalogue = map[string]Resolution{
	"vlan":       {Construct: ConstructVLAN},
	"macvrf":     {Construct: ConstructMACVRF},
	"ipvrf":      {Construct: ConstructIPVRF},
	"acl":        {Construct: ConstructACL},
	"l2vni":      {Construct: ConstructMACVRF},
	"l3vni":      {Construct: ConstructIPVRF},
	"accesslist": {Construct: ConstructACL},
	// Migration aliases: accepted on input only, folded before anything else sees them.
	"vpls":    {Construct: ConstructMACVRF, Source: "VPLS"},
	"vpws":    {Construct: ConstructMACVRF, Source: "VPWS"},
	"eline":   {Construct: ConstructMACVRF, Source: "VPWS"},
	"l3vpn":   {Construct: ConstructIPVRF, Source: "L3VPN"},
	"l2l3irb": {Construct: ConstructMACVRF, Source: "L2L3-IRB"},
	"irb":     {Construct: ConstructMACVRF, Source: "L2L3-IRB"},
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
// false for a name that is none of them; the caller refuses it listing the four constructs.
func Canonicalize(name string) (Resolution, bool) {
	r, ok := catalogue[Key(name)]
	return r, ok
}

// canonicalize folds the input's vocabulary on entry: the type becomes the construct and a migration
// alias is recorded as the arrival vocabulary; an access list's family, stage and protocol
// spellings are folded (acl.go). An unresolvable value is left as written, for validation to
// refuse by name.
func (in *ServiceInput) canonicalize() {
	if r, ok := Canonicalize(in.Type); ok {
		in.Type = r.Construct
		if r.Source != "" {
			in.SourceType = r.Source
		}
	}
	in.ACL.canonicalize()
}
