package topologyview

import "regexp"

// InterfaceRelabelRegex is the pattern the Prometheus scrape of job `devices` rewrites
// `interface_name` with (replacement InterfaceRelabelReplacement): the one normalization of the
// join (R-10). NormalizeInterface applies exactly this, anchored, so a test can hold the relabel
// configuration and this function to the same rule.
const (
	InterfaceRelabelRegex       = `ethernet-(\d+)/(\d+)`
	InterfaceRelabelReplacement = `e${1}-${2}`
)

var ethernetRe = regexp.MustCompile(`^` + InterfaceRelabelRegex + `$`)

// NormalizeInterface maps an SR Linux interface name onto the containerlab endpoint short name
// the view is keyed by: "ethernet-1/49" → "e1-49". Names already short ("e1-49") and every other
// interface (mgmt0, system0, irb0, lo0, eth1) are returned unchanged.
func NormalizeInterface(name string) string {
	return ethernetRe.ReplaceAllString(name, InterfaceRelabelReplacement)
}
