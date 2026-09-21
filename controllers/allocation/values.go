package allocation

// The pure arithmetic of the first-party allocation authority: what a pool holds, what a
// stated value means against it, and which value a dynamic claim is bound. Nothing here
// reads or writes the cluster; the controllers apply it to the pool's ledger
// (IdentifierPool.status.allocations), which is the only record of what is held.

import (
	"fmt"
	"math/big"
	"net/netip"
	"sort"
	"strconv"
	"strings"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
)

// refusal is a claim's answer that is not a binding: a Ready=False reason and its message.
type refusal struct {
	Reason  string
	Message string
}

func (r *refusal) Error() string { return r.Reason + ": " + r.Message }

func refuse(reason, format string, a ...any) *refusal {
	return &refusal{Reason: reason, Message: fmt.Sprintf(format, a...)}
}

// typeMax is the largest value a numeric pool of each type may hand out.
var typeMax = map[fabricv1.IdentifierType]int64{
	fabricv1.IdentifierTypeASN:   4294967295, // 32-bit AS numbers
	fabricv1.IdentifierTypeVLAN:  4094,       // 0 and 4095 are reserved (IEEE 802.1Q)
	fabricv1.IdentifierTypeVNI:   16777215,   // 24-bit VXLAN network identifier
	fabricv1.IdentifierTypeGENID: 1<<63 - 1,
}

// shape is a validated pool: an inclusive numeric range, or an address prefix.
type shape struct {
	ns, name string
	typ      fabricv1.IdentifierType
	lo, hi   int64
	prefix   netip.Prefix // ip pools only; masked
}

// parsePool validates a pool's spec. Its error is the Invalid message.
func parsePool(p *fabricv1.IdentifierPool) (*shape, error) {
	s := &shape{ns: p.Namespace, name: p.Name, typ: p.Spec.Type}
	if p.Spec.Type == fabricv1.IdentifierTypeIP {
		if p.Spec.Range != nil {
			return nil, fmt.Errorf("a pool of type ip carries a prefix, not a range")
		}
		pfx, err := netip.ParsePrefix(strings.TrimSpace(p.Spec.Prefix))
		if err != nil {
			return nil, fmt.Errorf("prefix %q is not a CIDR prefix", p.Spec.Prefix)
		}
		if pfx.Addr().Zone() != "" || pfx.Addr().Is4In6() {
			return nil, fmt.Errorf("prefix %q is not a plain IPv4 or IPv6 prefix", p.Spec.Prefix)
		}
		if pfx != pfx.Masked() {
			return nil, fmt.Errorf("prefix %q has host bits set; the pool is %s", p.Spec.Prefix, pfx.Masked())
		}
		s.prefix = pfx
		return s, nil
	}
	max, ok := typeMax[p.Spec.Type]
	if !ok {
		return nil, fmt.Errorf("type %q is not one of ip, asn, vlan, vni, genid", p.Spec.Type)
	}
	if p.Spec.Prefix != "" || p.Spec.Range == nil {
		return nil, fmt.Errorf("a pool of type %s carries a range, not a prefix", p.Spec.Type)
	}
	r := p.Spec.Range
	if r.Start < 0 || r.Start > r.End {
		return nil, fmt.Errorf("range %d-%d is empty", r.Start, r.End)
	}
	if r.End > max {
		return nil, fmt.Errorf("range %d-%d exceeds the largest %s, %d", r.Start, r.End, p.Spec.Type, max)
	}
	if p.Spec.Type == fabricv1.IdentifierTypeVLAN && r.Start < 1 {
		return nil, fmt.Errorf("range %d-%d includes VLAN 0, which is reserved", r.Start, r.End)
	}
	s.lo, s.hi = r.Start, r.End
	return s, nil
}

func (s *shape) isIP() bool { return s.typ == fabricv1.IdentifierTypeIP }

// String names the pool with its range or prefix, for messages.
func (s *shape) String() string {
	if s.isIP() {
		return fmt.Sprintf("pool %s/%s (prefix %s)", s.ns, s.name, s.prefix)
	}
	return fmt.Sprintf("pool %s/%s (range %d-%d)", s.ns, s.name, s.lo, s.hi)
}

// size is the number of values the pool can hand out as host addresses or numbers.
func (s *shape) size() string {
	if s.isIP() {
		n := new(big.Int).Lsh(big.NewInt(1), uint(s.prefix.Addr().BitLen()-s.prefix.Bits()))
		return n.String()
	}
	return strconv.FormatInt(s.hi-s.lo+1, 10)
}

// canonical parses a stated value against the pool: its canonical text, or a refusal —
// Invalid when the text is not a value of the pool's type, OutOfRange when it is one
// outside the pool.
func (s *shape) canonical(requested string, prefixLength *int32) (string, *refusal) {
	v := strings.TrimSpace(requested)
	if !s.isIP() {
		if prefixLength != nil {
			return "", refuse(ReasonInvalid, "spec.prefixLength is set, but %s is of type %s; it is meaningful only on an ip pool", s, s.typ)
		}
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			return "", refuse(ReasonInvalid, "spec.requested %q is not a non-negative integer, as a value of %s must be", requested, s)
		}
		c := strconv.FormatInt(n, 10)
		if n < s.lo || n > s.hi {
			return "", refuse(ReasonOutOfRange, "value %s is outside %s", c, s)
		}
		return c, nil
	}
	var p netip.Prefix
	if strings.Contains(v, "/") {
		var err error
		if p, err = netip.ParsePrefix(v); err != nil {
			return "", refuse(ReasonInvalid, "spec.requested %q is not an address or a prefix", requested)
		}
		if p != p.Masked() {
			return "", refuse(ReasonInvalid, "spec.requested %q has host bits set: state the address alone, or the prefix %s", requested, p.Masked())
		}
	} else {
		a, err := netip.ParseAddr(v)
		if err != nil {
			return "", refuse(ReasonInvalid, "spec.requested %q is not an address or a prefix", requested)
		}
		p = netip.PrefixFrom(a, a.BitLen())
	}
	if p.Addr().Zone() != "" || p.Addr().Is4In6() {
		return "", refuse(ReasonInvalid, "spec.requested %q is not a plain IPv4 or IPv6 value", requested)
	}
	if prefixLength != nil && int(*prefixLength) != p.Bits() {
		return "", refuse(ReasonInvalid, "spec.prefixLength %d contradicts spec.requested %s", *prefixLength, p)
	}
	if p.Addr().Is4() != s.prefix.Addr().Is4() || p.Bits() < s.prefix.Bits() || !s.prefix.Contains(p.Addr()) {
		return "", refuse(ReasonOutOfRange, "value %s is outside %s", p, s)
	}
	return p.String(), nil
}

// holder returns the ledger entry that holds value (for ip: overlaps it), skipping the
// entries of the claim itself (same name).
func (s *shape) holder(value string, ledger []fabricv1.IdentifierAllocation, self string) *fabricv1.IdentifierAllocation {
	var vp netip.Prefix
	if s.isIP() {
		vp, _ = netip.ParsePrefix(value)
	}
	for i := range ledger {
		e := &ledger[i]
		if e.Claim == self {
			continue
		}
		if !s.isIP() {
			if e.Value == value {
				return e
			}
			continue
		}
		if ep, err := netip.ParsePrefix(e.Value); err == nil && ep.Overlaps(vp) {
			return e
		}
	}
	return nil
}

// lowestFree is the value a dynamic claim is bound: the lowest free number of the range,
// or the lowest aligned block of length bits (0 = one host address) in the prefix that
// overlaps no ledger entry. ok is false when the pool is exhausted.
func (s *shape) lowestFree(ledger []fabricv1.IdentifierAllocation, bits int) (string, bool) {
	if !s.isIP() {
		held := make([]int64, 0, len(ledger))
		for _, e := range ledger {
			if n, err := strconv.ParseInt(e.Value, 10, 64); err == nil {
				held = append(held, n)
			}
		}
		sort.Slice(held, func(i, j int) bool { return held[i] < held[j] })
		cand := s.lo
		for _, h := range held {
			if h < cand {
				continue
			}
			if h > cand {
				break
			}
			cand++
		}
		if cand > s.hi {
			return "", false
		}
		return strconv.FormatInt(cand, 10), true
	}
	width := s.prefix.Addr().BitLen()
	if bits == 0 {
		bits = width
	}
	var held []netip.Prefix
	for _, e := range ledger {
		if p, err := netip.ParsePrefix(e.Value); err == nil {
			held = append(held, p)
		}
	}
	sort.Slice(held, func(i, j int) bool { return held[i].Addr().Less(held[j].Addr()) })
	block := new(big.Int).Lsh(big.NewInt(1), uint(width-bits))
	poolEnd := lastAddr(s.prefix)
	cand := addrInt(s.prefix.Addr())
	for {
		if cand.Cmp(poolEnd) > 0 {
			return "", false
		}
		p := netip.PrefixFrom(intAddr(cand, width), bits)
		blockEnd := new(big.Int).Add(cand, new(big.Int).Sub(block, big.NewInt(1)))
		if blockEnd.Cmp(poolEnd) > 0 {
			return "", false
		}
		var next *big.Int
		for _, h := range held {
			if h.Overlaps(p) {
				// Skip past the holder, then align up to the block size.
				n := new(big.Int).Add(lastAddr(h), big.NewInt(1))
				if next == nil || n.Cmp(next) > 0 {
					next = n
				}
			}
		}
		if next == nil {
			return p.String(), true
		}
		rem := new(big.Int).Mod(next, block)
		if rem.Sign() != 0 {
			next.Add(next, new(big.Int).Sub(block, rem))
		}
		cand = next
	}
}

// dynamicBits is the prefix length of a dynamic ip claim: spec.prefixLength, or one host.
func (s *shape) dynamicBits(prefixLength *int32) (int, *refusal) {
	if !s.isIP() {
		if prefixLength != nil {
			return 0, refuse(ReasonInvalid, "spec.prefixLength is set, but %s is of type %s; it is meaningful only on an ip pool", s, s.typ)
		}
		return 0, nil
	}
	width := s.prefix.Addr().BitLen()
	if prefixLength == nil {
		return width, nil
	}
	b := int(*prefixLength)
	if b > width {
		return 0, refuse(ReasonInvalid, "spec.prefixLength %d exceeds the %d bits of %s", b, width, s)
	}
	if b < s.prefix.Bits() {
		return 0, refuse(ReasonInvalid, "spec.prefixLength %d is shorter than %s", b, s)
	}
	return b, nil
}

// sortLedger orders entries by value: numerically, or by address then length.
func (s *shape) sortLedger(l []fabricv1.IdentifierAllocation) {
	sort.SliceStable(l, func(i, j int) bool {
		if s.isIP() {
			a, ea := netip.ParsePrefix(l[i].Value)
			b, eb := netip.ParsePrefix(l[j].Value)
			if ea == nil && eb == nil {
				if a.Addr() != b.Addr() {
					return a.Addr().Less(b.Addr())
				}
				return a.Bits() < b.Bits()
			}
		} else {
			a, ea := strconv.ParseInt(l[i].Value, 10, 64)
			b, eb := strconv.ParseInt(l[j].Value, 10, 64)
			if ea == nil && eb == nil {
				return a < b
			}
		}
		return l[i].Value < l[j].Value
	})
}

func addrInt(a netip.Addr) *big.Int { return new(big.Int).SetBytes(a.AsSlice()) }

func intAddr(n *big.Int, width int) netip.Addr {
	b := make([]byte, width/8)
	n.FillBytes(b)
	a, _ := netip.AddrFromSlice(b)
	return a
}

func lastAddr(p netip.Prefix) *big.Int {
	width := p.Addr().BitLen()
	span := new(big.Int).Lsh(big.NewInt(1), uint(width-p.Bits()))
	return new(big.Int).Sub(new(big.Int).Add(addrInt(p.Masked().Addr()), span), big.NewInt(1))
}
