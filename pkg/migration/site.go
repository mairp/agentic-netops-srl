package migration

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

// The site inventory and the fabric constant the translator validates against, from the environment
// (quickstart.md §5). scripts/lib/intent_tier.sh writes all three into the ConfigMap site-inventory
// (keys of the same names) from the Fabric, and the intent-translator sidecar reads them through
// configMapKeyRef; the CLI reads whatever the shell exports.
//
//	FABRIC_NODE_MAP  a JSON object: node name → role, one entry per node of the Fabric
//	                 (spec.nodes[].role), e.g.
//	                 {"leaf01":"leaf","leaf02":"leaf","spine01":"spine","spine02":"spine"}
//	FABRIC_PORT_MAP  a JSON object: node name → its access ports (spec.inventory[].accessPorts, the
//	                 device's own port names), e.g.
//	                 {"leaf01":["ethernet-1/1"],"leaf02":["ethernet-1/1"],"spine01":[],"spine02":[]}
//	FABRIC_ASN       the Fabric's spec.overlay.fabricASN, a decimal integer 1–4294967295, e.g. 65000
//
// Both maps unset (or empty) → no inventory: no node or port is checked, so the offline CLI and the
// unit tests translate without a site. With either set, every endpoint's node must be a node of the
// site and not a spine — spines are never attachment points — and its attachment one of that node's
// access ports; every refusal enumerates the site's real names. A node present in only one of the
// two maps is taken as known, with role "leaf" when FABRIC_NODE_MAP is absent. FABRIC_ASN unset →
// route targets are checked for this service's VNI and one consistent ASN, and emitted with that
// ASN; set → the ASN must be it. A value that does not parse is a configuration error, never a
// silently absent inventory.
const (
	EnvNodeMap   = "FABRIC_NODE_MAP"
	EnvPortMap   = "FABRIC_PORT_MAP"
	EnvFabricASN = "FABRIC_ASN"
)

// SiteInventory is the site's attachment points.
type SiteInventory struct {
	// Roles maps every node to its role (leaf, spine, …).
	Roles map[string]string
	// Ports maps a node to its access ports, in inventory order.
	Ports map[string][]string
}

// Options are the translator's inputs besides the request itself.
type Options struct {
	// Site is nil when no inventory is configured.
	Site *SiteInventory
	// FabricASN is 0 when unset.
	FabricASN int64
}

// OptionsFromEnv reads FABRIC_NODE_MAP, FABRIC_PORT_MAP and FABRIC_ASN.
func OptionsFromEnv() (Options, error) {
	return ParseOptions(os.Getenv(EnvNodeMap), os.Getenv(EnvPortMap), os.Getenv(EnvFabricASN))
}

// ParseOptions parses the three values in the formats documented above.
func ParseOptions(nodeMap, portMap, fabricASN string) (Options, error) {
	var o Options
	var roles map[string]string
	var ports map[string][]string
	if s := strings.TrimSpace(nodeMap); s != "" {
		if err := json.Unmarshal([]byte(s), &roles); err != nil {
			return o, fmt.Errorf(`%s: not a JSON object of node name to role (e.g. {"leaf01":"leaf","spine01":"spine"}): %v`, EnvNodeMap, err)
		}
	}
	if s := strings.TrimSpace(portMap); s != "" {
		if err := json.Unmarshal([]byte(s), &ports); err != nil {
			return o, fmt.Errorf(`%s: not a JSON object of node name to access ports (e.g. {"leaf01":["ethernet-1/1"]}): %v`, EnvPortMap, err)
		}
	}
	if len(roles) > 0 || len(ports) > 0 {
		site := &SiteInventory{Roles: map[string]string{}, Ports: map[string][]string{}}
		for n, r := range roles {
			site.Roles[n] = r
		}
		for n, p := range ports {
			site.Ports[n] = append([]string(nil), p...)
			if _, ok := site.Roles[n]; !ok {
				site.Roles[n] = "leaf"
			}
		}
		o.Site = site
	}
	if s := strings.TrimSpace(fabricASN); s != "" {
		n, err := strconv.ParseInt(s, 10, 64)
		if err != nil || n < 1 || n > 4294967295 {
			return o, fmt.Errorf("%s: %q is not an autonomous-system number 1–4294967295", EnvFabricASN, s)
		}
		o.FabricASN = n
	}
	return o, nil
}

// attachmentNodes are the nodes an endpoint may name: every node that is not a spine, sorted.
func (s *SiteInventory) attachmentNodes() []string {
	var out []string
	for n, r := range s.Roles {
		if r != "spine" {
			out = append(out, n)
		}
	}
	sort.Strings(out)
	return out
}

func orNone(names []string) string {
	if len(names) == 0 {
		return "none"
	}
	return strings.Join(names, ", ")
}

// endpointCauses names every way endpoint i fails the inventory; nil when the site has no inventory.
func (s *SiteInventory) endpointCauses(path string, ep Endpoint) []string {
	if s == nil {
		return nil
	}
	if ep.Node == "" {
		return nil // the required-field cause is already stated
	}
	role, known := s.Roles[ep.Node]
	switch {
	case !known:
		return []string{fmt.Sprintf("%s.node: %q is not a node at this site; the site's attachment nodes are %s",
			path, ep.Node, orNone(s.attachmentNodes()))}
	case role == "spine":
		return []string{fmt.Sprintf("%s.node: %s is a spine, and spines are not attachment points; the site's attachment nodes are %s",
			path, ep.Node, orNone(s.attachmentNodes()))}
	}
	if ep.Attachment == "" {
		return nil
	}
	for _, p := range s.Ports[ep.Node] {
		if p == ep.Attachment {
			return nil
		}
	}
	return []string{fmt.Sprintf("%s.attachment: %s has no access port %q; this site's access ports on %s are %s",
		path, ep.Node, ep.Attachment, ep.Node, orNone(s.Ports[ep.Node]))}
}
