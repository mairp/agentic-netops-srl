package model

import (
	"fmt"
	"net/netip"
	"strconv"
)

// The IPv6 half of the dual-stack underlay (data-model.md §3a
// `spec.underlay.addressFamilies`, research D-01 "IPv4 /31 plus IPv6 underlay
// links").
//
// The spec names no allocation source for underlay IPv6 addresses: the
// Fabric's KUID indices are IPv4 only (deploy/kuid/indices: fabric01-loopback
// 10.0.0.0/24, fabric01-p2p 10.1.0.0/24) and the Fabric API carries no IPv6
// field. The IPv6 addresses are therefore DERIVED — a pure function of the
// allocated IPv4 value — and, per contracts/kuid-claim-profiles.md ("Values the
// platform derives are not claims and are not released"), they are not claims:
// nothing is reserved for them and nothing is released. The derivation embeds
// the IPv4 address in the low 32 bits of a fixed unique-local /96:
//
//	system loopback  10.0.0.1/32   -> fd00::a00:1/128          (SystemIPv6Base + v4, /96+32)
//	link end         10.1.0.1/31   -> fd00:1::a01:1/127        (LinkIPv6Base  + v4, /96+31)
//
// so the /31 pairing is preserved exactly as a /127 (RFC 6164), both ends of a
// link derive the two addresses of one /127, and two distinct IPv4 values can
// never derive the same IPv6 value. The VXLAN tunnel endpoint stays IPv4
// (evidence/02-evpn-constructs.md §1.3): system0.0's IPv6 address is a BGP
// underlay reachability address, never a tunnel source.
const (
	// SystemIPv6Base is the /96 system0.0 IPv6 addresses are derived in.
	SystemIPv6Base = "fd00::/96"
	// LinkIPv6Base is the /96 point-to-point link IPv6 addresses are derived in.
	LinkIPv6Base = "fd00:1::/96"
	// UnderlayV6Group is the BGP peer-group of the per-link IPv6 eBGP sessions.
	UnderlayV6Group = "underlay-v6"
)

// DeriveSystemIPv6 derives system0.0's IPv6 /128 from its IPv4 /32.
func DeriveSystemIPv6(systemIPv4 string) (string, error) {
	p, err := hostPrefix(systemIPv4)
	if err != nil {
		return "", err
	}
	return embed(SystemIPv6Base, p)
}

// DeriveLinkIPv6 derives a link end's IPv6 address (prefix length 96 + the
// IPv4 prefix length) from its IPv4 address with prefix length.
func DeriveLinkIPv6(linkIPv4 string) (string, error) {
	p, err := netip.ParsePrefix(linkIPv4)
	if err != nil {
		return "", err
	}
	if !p.Addr().Is4() {
		return "", fmt.Errorf("%q is not an IPv4 prefix", linkIPv4)
	}
	return embed(LinkIPv6Base, p)
}

func embed(base string, v4 netip.Prefix) (string, error) {
	b := netip.MustParsePrefix(base)
	a16 := b.Addr().As16()
	a4 := v4.Addr().As4()
	copy(a16[12:], a4[:])
	return netip.PrefixFrom(netip.AddrFrom16(a16), 96+v4.Bits()).String(), nil
}

// MaskLengthRange is the exact-length range of a loopback prefix-set entry:
// `32..32` for an IPv4 /32, `128..128` for an IPv6 /128.
func MaskLengthRange(prefix string) string {
	p, err := netip.ParsePrefix(prefix)
	if err != nil {
		return ""
	}
	b := strconv.Itoa(p.Bits())
	return b + ".." + b
}

func underlayIPv6(fams []AddressFamily) (bool, error) {
	if len(fams) == 0 {
		return true, nil // both by default (data-model.md §3a)
	}
	var v4, v6 bool
	for _, f := range fams {
		switch f {
		case FamilyUnderlayIPv4:
			v4 = true
		case FamilyUnderlayIPv6:
			v6 = true
		default:
			return false, fmt.Errorf("underlay address family %q", f)
		}
	}
	if !v4 {
		return false, fmt.Errorf("underlay address families %v: ipv4 is required, the VXLAN tunnel endpoint is IPv4-only", fams)
	}
	return v6, nil
}
