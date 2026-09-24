package topologyview

import (
	"bufio"
	"bytes"
	"fmt"
	"net/netip"
	"strings"
)

// Target is one gNMIc target: the node name (the `source` label every exported series carries)
// and its management address.
type Target struct {
	Name    string
	Address netip.Addr
}

// Targets places every device at its inventory host offset inside mgmtCIDR — the addresses
// scripts/lib/onboarding.sh's onboarding::hosts derives (spines .11/.12, leaves .21/.22), so an
// overridden MGMT_CIDR moves the targets with the lab.
func Targets(inv *Inventory, mgmtCIDR string) ([]Target, error) {
	p, err := netip.ParsePrefix(mgmtCIDR)
	if err != nil || !p.Addr().Is4() {
		return nil, fmt.Errorf("targets: MGMT_CIDR %q is not an IPv4 network", mgmtCIDR)
	}
	if p.Masked() != p {
		return nil, fmt.Errorf("targets: MGMT_CIDR %q is not a network address", mgmtCIDR)
	}
	size := uint64(1) << (32 - p.Bits())
	base := ip4(p.Addr())
	var out []Target
	for _, n := range inv.Devices() {
		if uint64(n.MgmtOffset) >= size-1 || n.MgmtOffset == 0 {
			return nil, fmt.Errorf("targets: MGMT_CIDR %s is too small for %s at host offset .%d", p, n.Name, n.MgmtOffset)
		}
		v := base + n.MgmtOffset
		out = append(out, Target{Name: n.Name, Address: netip.AddrFrom4([4]byte{byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)})})
	}
	return out, nil
}

// FormatTargets renders the target list: one line `<name> <address>` per device, inventory order —
// the format of onboarding::hosts, which device_metrics.sh reads (the gNMI port, 57400, is added
// by the consumer).
func FormatTargets(ts []Target) []byte {
	var b bytes.Buffer
	for _, t := range ts {
		fmt.Fprintf(&b, "%s %s\n", t.Name, t.Address)
	}
	return b.Bytes()
}

// ParseTargets reads a target list written by FormatTargets.
func ParseTargets(b []byte) ([]Target, error) {
	var out []Target
	sc := bufio.NewScanner(bytes.NewReader(b))
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		f := strings.Fields(line)
		if len(f) != 2 {
			return nil, fmt.Errorf("targets: line %d %q is not `<name> <address>`", n, line)
		}
		a, err := netip.ParseAddr(f[1])
		if err != nil {
			return nil, fmt.Errorf("targets: line %d: %w", n, err)
		}
		out = append(out, Target{Name: f[0], Address: a})
	}
	return out, sc.Err()
}
