package verify

// The Fabric read-back (T041; data-model.md §3a, contracts/reconciliation.md
// Rule 5; FR-100, FR-107, SC-004, AD-23, AD-31, AD-43, R-37).
//
// VerifyFabric is THE read-back: the Fabric reconciler sets Ready from it on
// first convergence and on every scheduled re-verification — the same function
// each time, never a cheaper one (AD-67).
//
// Written side, per node: the node's priority-10 Config applied by the layer at
// its current generation, no deviation reported against it, and every leaf of
// its rendered document present in the node's running datastore.
//
// Applied side, per node, read from the device's own state datastore and keyed
// to the Fabric's own objects:
//   - every fabric port and its routed subinterface 0, and system0.0,
//     oper-state up (an access port's oper-state is NOT a Fabric invariant,
//     AD-68);
//   - every underlay and overlay BGP neighbour of the model session-state
//     established;
//   - on every overlay neighbour the EVPN family negotiated, read from the
//     family's own operational state —
//     …/neighbor[peer-address=<ip>]/afi-safi[afi-safi-name=srl_nokia-common:evpn]/oper-state == up —
//     never inferred from session-state;
//   - every OTHER node's allocated system0.0 address present and active in
//     this node's route table (ipv4-unicast, and ipv6-unicast where the family
//     is enabled), keyed to the loopbacks the Fabric itself allocated.
//
// Configuration integrity, on every reflecting spine: inter-as-vpn and
// route-reflector client read back as the Fabric declares them
// (spec.overlay.interASVPN, spec.overlay.reflectorClients). Both are
// CONFIGURATION leaves, read from the CONFIGURATION datastore — the node's
// running configuration as the layer holds it — because SR Linux 25.7.1's
// state datastore does not mirror them (AD-76). This is a configuration-
// integrity check: it shows the setting is applied, never that reflection
// works (AD-31; reflection is shown by G8, T051's probe and the first spanning
// service). A spine whose read-back differs from the declaration is
// NotConverged naming the spine and the setting; and a Fabric that declares
// overlay.reflectorClients false — SC-004's declarative negative control — is
// NotConverged naming each reflecting spine and route-reflector client
// whatever the device reads (AD-77). overlay.interASVPN false is no longer a
// convergence rule of its own: it is checked as declared equals read back
// only (AD-77).
//
// It NEVER counts EVPN routes (FR-100, AD-23): no received-routes, active-routes
// or RIB path is ever read. The Fabric converges before any service exists,
// so zero EVPN routes is then correct; route exchange is each spanning
// Network's invariant (RoutesMissing, T058).

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	condv1alpha1 "github.com/sdcio/config-server/apis/condition/v1alpha1"
	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/status"
)

// State-path vocabulary. The identityref form of the EVPN address family is
// held in this ONE constant, because gate item G12 confirms the form the device
// returns on a read before any path is frozen (R-36, AD-31): if G12 observes
// another form, this constant is the only thing that changes.
const (
	// EVPNAFISAFIName is the afi-safi-name key of the EVPN family.
	EVPNAFISAFIName = "srl_nokia-common:evpn"
	// RouteTypeBGP is the route-type key of a BGP-learnt route-table entry
	// (data-model.md §3a writes it `route-type=bgp`; G12 confirms the form).
	RouteTypeBGP = "bgp"

	// Expected values.
	OperStateUp        = "up"
	SessionEstablished = "established"
	LeafTrue           = "true"
)

// Check names one kind of read-back invariant; the condition message carries it.
type Check string

const (
	CheckWritten                Check = "written"
	CheckInterfaceOperState     Check = "interface-oper-state"
	CheckSessionState           Check = "bgp-session-state"
	CheckEVPNFamily             Check = "evpn-family-oper-state"
	CheckLoopbackRoute          Check = "loopback-route"
	CheckConfigurationIntegrity Check = "configuration-integrity"
)

// ConfigReader is what the written side reads of the layer's Kubernetes objects
// (pkg/sdc.Client satisfies it).
type ConfigReader interface {
	GetConfig(ctx context.Context, name string) (*configv1alpha1.Config, error)
	GetConfigDeviation(ctx context.Context, configName string) (*configv1alpha1.Deviation, error)
}

// FabricNodeInput is one node's written-side input.
type FabricNodeInput struct {
	// Node is the node (and Target) name.
	Node string
	// ConfigName is the node's priority-10 Config.
	ConfigName string
	// Rendered is the document the provider rendered for the node (the
	// Config's value at "/").
	Rendered []byte
}

// FindingInput is one open force-release finding whose node is in spec.nodes
// (a finding whose node left spec.nodes is never read, AD-71).
type FindingInput struct {
	// Index is the finding's index in Fabric.status.findings[].
	Index int
	// Node is the device the finding names.
	Node string
	// DeviceObjects are the object names the service had rendered there.
	DeviceObjects []string
}

// FabricInput is everything one read-back pass needs.
type FabricInput struct {
	// Model is the canonical fabric model the Configs were rendered from; its
	// nodes, ports, neighbours and allocated loopbacks key every read.
	Model *model.FabricModel
	// InterASVPN is spec.overlay.interASVPN as declared; the configuration-
	// integrity check expects it read back on every reflecting spine.
	InterASVPN bool
	// ReflectorClients is spec.overlay.reflectorClients as declared (true when
	// absent); the configuration-integrity check expects it read back on every
	// reflecting spine, and false makes the Fabric NotConverged (AD-77).
	ReflectorClients bool
	// TargetNamespace is the namespace of the layer's Targets.
	TargetNamespace string
	// Nodes carries the written-side input of every node of Model.
	Nodes []FabricNodeInput
	// Findings are the open findings to try to clear in this pass.
	Findings []FindingInput
}

// Invariant is one missing invariant.
type Invariant struct {
	Node   string
	Check  Check
	Detail string
}

func (i Invariant) String() string { return fmt.Sprintf("%s %s: %s", i.Node, i.Check, i.Detail) }

// FabricResult is a read-back that RAN — completed on both sides — whatever it
// found. A pass that could not run is a *CouldNotRunError instead.
type FabricResult struct {
	// Missing are the invariants found missing, sorted.
	Missing []Invariant
	// ClearedFindings are the indexes of the findings whose every device object
	// was read absent from both the running and the state datastore.
	ClearedFindings []int
	// Paths are every state path this pass read, sorted (evidence, and what
	// the no-route-count test inspects).
	Paths []string
	// ConfigPaths are every path this pass read from the configuration
	// datastore (the configuration-integrity leaves, AD-76), sorted.
	ConfigPaths []string
}

// Passed reports whether no invariant is missing.
func (r FabricResult) Passed() bool { return len(r.Missing) == 0 }

// Reason is the Ready=False reason of a pass that found an invariant missing:
// NotConverged, the Fabric's one (data-model.md §3a).
func (r FabricResult) Reason() string { return status.ReasonNotConverged }

// Message names every missing invariant; the configuration-integrity ones say
// they are a configuration-integrity check.
func (r FabricResult) Message() string {
	if r.Passed() {
		return "read-back passed on both sides"
	}
	parts := make([]string, 0, len(r.Missing))
	for _, m := range r.Missing {
		parts = append(parts, m.String())
	}
	return "missing: " + strings.Join(parts, "; ")
}

// Fabric is the read-back over a StateReader (device state through the layer)
// and a ConfigReader (the layer's Config and Deviation objects).
type Fabric struct {
	Reader  StateReader
	Configs ConfigReader
	// Timeout bounds one pass; a read still outstanding at the deadline makes
	// the pass one that could not run. Zero means 30 s.
	Timeout time.Duration
}

// VerifyFabric runs one read-back pass. It returns a FabricResult (nil error)
// for a pass that ran, whatever it found, and a *CouldNotRunError for a pass
// that could not run against one or more required targets.
func (f *Fabric) VerifyFabric(ctx context.Context, in FabricInput) (FabricResult, error) {
	if in.Model == nil {
		return FabricResult{}, fmt.Errorf("verify fabric: nil model")
	}
	timeout := f.Timeout
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	written := map[string]FabricNodeInput{}
	for _, n := range in.Nodes {
		written[n.Node] = n
	}
	findings := map[string][]FindingInput{}
	for _, fi := range in.Findings {
		findings[fi.Node] = append(findings[fi.Node], fi)
	}

	var res FabricResult
	causes := map[string]error{}
	nodes := append([]model.FabricNode(nil), in.Model.Nodes...)
	sort.Slice(nodes, func(i, j int) bool { return nodes[i].Name < nodes[j].Name })
	for i := range nodes {
		n := &nodes[i]
		target := Target{Namespace: in.TargetNamespace, Name: n.Name}
		missing, cleared, paths, cfgPaths, err := f.verifyNode(ctx, target, n, in, written[n.Name], findings[n.Name])
		if err != nil {
			if ctx.Err() != nil {
				err = fmt.Errorf("read timed out after %s: %w", timeout, err)
			}
			causes[n.Name] = err
			continue
		}
		res.Missing = append(res.Missing, missing...)
		res.ClearedFindings = append(res.ClearedFindings, cleared...)
		res.Paths = append(res.Paths, paths...)
		res.ConfigPaths = append(res.ConfigPaths, cfgPaths...)
	}
	if len(causes) > 0 {
		return FabricResult{}, &CouldNotRunError{Causes: causes}
	}
	sort.Slice(res.Missing, func(i, j int) bool {
		a, b := res.Missing[i], res.Missing[j]
		if a.Node != b.Node {
			return a.Node < b.Node
		}
		if a.Check != b.Check {
			return a.Check < b.Check
		}
		return a.Detail < b.Detail
	})
	sort.Ints(res.ClearedFindings)
	sort.Strings(res.Paths)
	sort.Strings(res.ConfigPaths)
	return res, nil
}

// Datastore is the datastore an Expectation is read from.
type Datastore string

const (
	// DatastoreState is the device's state datastore (applied side).
	DatastoreState Datastore = "state"
	// DatastoreConfiguration is the node's running configuration as the
	// layer holds it — where a configuration-integrity leaf is read, because
	// the state datastore does not mirror it (AD-76).
	DatastoreConfiguration Datastore = "configuration"
)

// Expectation is one leaf, the datastore it is read from and the value it
// must read.
type Expectation struct {
	Path      string
	Want      string
	Check     Check
	What      string
	Datastore Datastore
}

func (f *Fabric) verifyNode(ctx context.Context, target Target, n *model.FabricNode, in FabricInput,
	w FabricNodeInput, fs []FindingInput) ([]Invariant, []int, []string, []string, error) {
	var missing []Invariant
	miss := func(c Check, format string, a ...any) {
		missing = append(missing, Invariant{Node: n.Name, Check: c, Detail: fmt.Sprintf(format, a...)})
	}

	// --- written side: the Config applied, no deviation ---
	if w.ConfigName == "" {
		miss(CheckWritten, "no priority-10 Config recorded for the node")
	} else {
		cfg, err := f.Configs.GetConfig(ctx, w.ConfigName)
		switch {
		case apierrors.IsNotFound(err):
			miss(CheckWritten, "Config %s absent", w.ConfigName)
		case err != nil:
			return nil, nil, nil, nil, fmt.Errorf("read Config %s: %w", w.ConfigName, err)
		default:
			if ok, why := configApplied(cfg); !ok {
				miss(CheckWritten, "Config %s not applied by the layer: %s", w.ConfigName, why)
			}
			dev, err := f.Configs.GetConfigDeviation(ctx, w.ConfigName)
			if err != nil {
				return nil, nil, nil, nil, fmt.Errorf("read Deviation of Config %s: %w", w.ConfigName, err)
			}
			if dev != nil && len(dev.Spec.Deviations) > 0 {
				var ps []string
				for _, d := range dev.Spec.Deviations {
					ps = append(ps, fmt.Sprintf("%s (%s)", d.Path, d.Reason))
				}
				sort.Strings(ps)
				miss(CheckWritten, "Config %s reports deviation at %s", w.ConfigName, strings.Join(ps, ", "))
			}
		}
	}

	// --- written side: the rendered content in the running datastore ---
	running, err := f.Reader.Running(ctx, target)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	var runningDoc any
	if err := json.Unmarshal(running, &runningDoc); err != nil {
		return nil, nil, nil, nil, fmt.Errorf("running configuration of %s is not JSON: %w", n.Name, err)
	}
	if len(w.Rendered) > 0 {
		var want any
		if err := json.Unmarshal(w.Rendered, &want); err != nil {
			return nil, nil, nil, nil, fmt.Errorf("rendered document of %s is not JSON: %w", n.Name, err)
		}
		if absent := missingLeaves(want, runningDoc, ""); len(absent) > 0 {
			shown := absent
			if len(shown) > 5 {
				shown = append(append([]string{}, shown[:5]...), fmt.Sprintf("… %d more", len(absent)-5))
			}
			miss(CheckWritten, "rendered content absent from the running datastore: %s", strings.Join(shown, ", "))
		}
	}

	// --- configuration integrity: read from the configuration datastore ---
	// (AD-76: the state datastore of SR Linux 25.7.1 does not mirror these
	// configuration leaves, so they are read from the running configuration;
	// still a configuration-integrity check, never applied-side evidence)
	exps := Expectations(in.Model, n, in.InterASVPN, in.ReflectorClients)
	var paths, cfgPaths []string
	for _, e := range exps {
		if e.Datastore == DatastoreConfiguration {
			cfgPaths = append(cfgPaths, e.Path)
			if vals := ConfigValues(runningDoc, e.Path); !contains(vals, e.Want) {
				miss(e.Check, "%s: %s reads %s in the configuration datastore, want %s", e.What, e.Path, show(vals), e.Want)
			}
			continue
		}
		paths = append(paths, e.Path)
	}
	if n.BGP.RouteReflectorClient != nil && !in.ReflectorClients {
		miss(CheckConfigurationIntegrity,
			"configuration-integrity check (read from the configuration datastore): reflecting spine %s — route-reflector client is declared false by spec.overlay.reflectorClients; a reflector declared not to reflect is not converged", n.Name)
	}

	// --- applied side: one state read ---
	objPaths := map[int][]string{}
	for _, fi := range fs {
		for _, o := range fi.DeviceObjects {
			p := DeviceObjectStatePath(o)
			objPaths[fi.Index] = append(objPaths[fi.Index], p)
			paths = append(paths, p)
		}
	}
	paths = dedupe(paths)
	got, err := f.Reader.State(ctx, target, paths)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	for _, e := range exps {
		if e.Datastore != DatastoreState {
			continue
		}
		vals := got[e.Path]
		if !contains(vals, e.Want) {
			miss(e.Check, "%s: %s reads %s, want %s", e.What, e.Path, show(vals), e.Want)
		}
	}

	// --- findings: cleared only when every object is absent from both datastores ---
	var cleared []int
	for _, fi := range fs {
		clean := true
		for i, o := range fi.DeviceObjects {
			if deviceObjectInRunning(runningDoc, o) || len(got[objPaths[fi.Index][i]]) > 0 {
				clean = false
				break
			}
		}
		if clean {
			cleared = append(cleared, fi.Index)
		}
	}
	return missing, cleared, paths, cfgPaths, nil
}

// Expectations are the applied-side leaves (state datastore) and the
// configuration-integrity leaves (configuration datastore, AD-76) of node n and
// the value each must read; the configuration-integrity ones read back as
// declared. Every path is keyed to the Fabric's own objects; none is a route
// count.
func Expectations(m *model.FabricModel, n *model.FabricNode, interASVPNDeclared, reflectorClientsDeclared bool) []Expectation {
	var out []Expectation
	add := func(c Check, what, path, want string) {
		ds := DatastoreState
		if c == CheckConfigurationIntegrity {
			ds = DatastoreConfiguration
		}
		out = append(out, Expectation{Path: path, Want: want, Check: c, What: what, Datastore: ds})
	}
	for _, p := range n.FabricPorts {
		add(CheckInterfaceOperState, "interface "+p.Name, InterfaceOperStatePath(p.Name), OperStateUp)
		add(CheckInterfaceOperState, "subinterface "+model.SubinterfaceName(p.Name, 0), SubinterfaceOperStatePath(p.Name, 0), OperStateUp)
	}
	add(CheckInterfaceOperState, "subinterface "+model.SubinterfaceName(model.SystemInterface, 0),
		SubinterfaceOperStatePath(model.SystemInterface, 0), OperStateUp)

	for _, nb := range n.BGP.Neighbors {
		add(CheckSessionState, fmt.Sprintf("%s session %s", nb.PeerGroup, nb.PeerAddress), SessionStatePath(nb.PeerAddress), SessionEstablished)
		if nb.PeerGroup == model.OverlayGroup {
			add(CheckEVPNFamily, "EVPN family on "+nb.PeerAddress, EVPNFamilyOperStatePath(nb.PeerAddress), OperStateUp)
		}
	}

	others := append([]model.FabricNode(nil), m.Nodes...)
	sort.Slice(others, func(i, j int) bool { return others[i].Name < others[j].Name })
	for _, o := range others {
		if o.Name == n.Name {
			continue
		}
		if v4 := hostPrefix(o.SystemIPv4, 32); v4 != "" {
			add(CheckLoopbackRoute, fmt.Sprintf("%s system0.0 %s", o.Name, v4), RouteActivePath("ipv4-unicast", "ipv4-prefix", v4), LeafTrue)
		}
		if n.BGP.IPv6Unicast {
			if v6 := hostPrefix(o.SystemIPv6, 128); v6 != "" {
				add(CheckLoopbackRoute, fmt.Sprintf("%s system0.0 %s", o.Name, v6), RouteActivePath("ipv6-unicast", "ipv6-prefix", v6), LeafTrue)
			}
		}
	}

	if n.BGP.RouteReflectorClient != nil || n.BGP.InterASVPN != nil {
		add(CheckConfigurationIntegrity, "configuration-integrity check (read from the configuration datastore): reflecting spine "+n.Name+" setting inter-as-vpn",
			InterASVPNPath(), strconv.FormatBool(interASVPNDeclared))
		add(CheckConfigurationIntegrity, "configuration-integrity check (read from the configuration datastore): reflecting spine "+n.Name+" setting route-reflector client",
			RouteReflectorClientPath(model.OverlayGroup), strconv.FormatBool(reflectorClientsDeclared))
	}
	return out
}

// ---------------------------------------------------------------------------
// Paths (native srl_nokia, gNMI string form).
// ---------------------------------------------------------------------------

func bgpPath() string {
	return "/network-instance[name=" + model.DefaultNetworkInstance + "]/protocols/bgp"
}

// InterfaceOperStatePath is /interface[name=<port>]/oper-state.
func InterfaceOperStatePath(port string) string { return "/interface[name=" + port + "]/oper-state" }

// SubinterfaceOperStatePath is /interface[name=<port>]/subinterface[index=<i>]/oper-state.
func SubinterfaceOperStatePath(port string, index uint32) string {
	return fmt.Sprintf("/interface[name=%s]/subinterface[index=%d]/oper-state", port, index)
}

// SessionStatePath is …/protocols/bgp/neighbor[peer-address=<ip>]/session-state.
func SessionStatePath(peer string) string {
	return bgpPath() + "/neighbor[peer-address=" + peer + "]/session-state"
}

// EVPNFamilyOperStatePath is
// …/neighbor[peer-address=<ip>]/afi-safi[afi-safi-name=srl_nokia-common:evpn]/oper-state,
// the config-false leaf "Negotiated operational state of the address family is up".
func EVPNFamilyOperStatePath(peer string) string {
	return bgpPath() + "/neighbor[peer-address=" + peer + "]/afi-safi[afi-safi-name=" + EVPNAFISAFIName + "]/oper-state"
}

// RouteActivePath is
// /network-instance[name=default]/route-table/<family>/route[<key>=<prefix>][route-type=bgp]/active;
// the route's other keys are left unspecified and match any instance.
func RouteActivePath(family, key, prefix string) string {
	return "/network-instance[name=" + model.DefaultNetworkInstance + "]/route-table/" + family +
		"/route[" + key + "=" + prefix + "][route-type=" + RouteTypeBGP + "]/active"
}

// InterASVPNPath is …/protocols/bgp/afi-safi[afi-safi-name=srl_nokia-common:evpn]/evpn/inter-as-vpn
// — a configuration leaf the state datastore does not mirror, read from the
// configuration datastore (configuration integrity, AD-76).
func InterASVPNPath() string {
	return bgpPath() + "/afi-safi[afi-safi-name=" + EVPNAFISAFIName + "]/evpn/inter-as-vpn"
}

// RouteReflectorClientPath is …/protocols/bgp/group[group-name=<g>]/route-reflector/client
// — a configuration leaf the state datastore does not mirror, read from the
// configuration datastore (configuration integrity, AD-76).
func RouteReflectorClientPath(group string) string {
	return bgpPath() + "/group[group-name=" + group + "]/route-reflector/client"
}

// DeviceObjectStatePath is the state path whose presence says a force-release
// finding's device object still exists on the node. The object names follow
// data-model.md §3a status.findings[].deviceObjects: a subinterface
// "<port>.<index>", a tunnel sub-interface "vxlan0.<index>", an access-list
// filter "acl-…", otherwise a network-instance name.
func DeviceObjectStatePath(obj string) string {
	if port, idx, ok := splitSub(obj); ok {
		if strings.HasPrefix(port, "vxlan") {
			return "/tunnel-interface[name=" + port + "]/vxlan-interface[index=" + idx + "]/index"
		}
		return "/interface[name=" + port + "]/subinterface[index=" + idx + "]/index"
	}
	if strings.HasPrefix(obj, "acl-") {
		return "/acl/acl-filter[name=" + obj + "]/name"
	}
	return "/network-instance[name=" + obj + "]/name"
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

// configApplied reports whether the layer reports cfg applied at its current
// generation: Ready=True whose observedGeneration (when the layer stamps one)
// is the Config's generation.
func configApplied(cfg *configv1alpha1.Config) (bool, string) {
	c := cfg.GetCondition(condv1alpha1.ConditionTypeReady)
	if c.Status != metav1.ConditionTrue {
		if c.Reason == "" {
			return false, "no Ready condition reported yet"
		}
		return false, fmt.Sprintf("Ready=%s/%s %s", c.Status, c.Reason, c.Message)
	}
	if c.ObservedGeneration != 0 && c.ObservedGeneration < cfg.Generation {
		return false, fmt.Sprintf("Ready reported for generation %d, the Config is at %d", c.ObservedGeneration, cfg.Generation)
	}
	return true, ""
}

func splitSub(obj string) (string, string, bool) {
	i := strings.LastIndex(obj, ".")
	if i <= 0 || i == len(obj)-1 {
		return "", "", false
	}
	idx := obj[i+1:]
	for _, r := range idx {
		if r < '0' || r > '9' {
			return "", "", false
		}
	}
	return obj[:i], idx, true
}

// deviceObjectInRunning reports whether obj exists in the running document.
func deviceObjectInRunning(doc any, obj string) bool {
	if port, idx, ok := splitSub(obj); ok {
		listName := "interface"
		childName := "subinterface"
		if strings.HasPrefix(port, "vxlan") {
			listName, childName = "tunnel-interface", "vxlan-interface"
		}
		for _, e := range findList(doc, listName) {
			if fmt.Sprint(e["name"]) != port {
				continue
			}
			for _, s := range asList(lookup(e, childName)) {
				if fmt.Sprint(s["index"]) == idx {
					return true
				}
			}
		}
		return false
	}
	if strings.HasPrefix(obj, "acl-") {
		if acl, ok := lookup(asMap(doc), "acl").(map[string]any); ok {
			for _, e := range asList(lookup(acl, "acl-filter")) {
				if fmt.Sprint(e["name"]) == obj {
					return true
				}
			}
		}
		return false
	}
	for _, e := range findList(doc, "network-instance") {
		if fmt.Sprint(e["name"]) == obj {
			return true
		}
	}
	return false
}

// ConfigValues reads path (gNMI string form) from a configuration document —
// the node's running configuration as the layer holds it — and returns the
// value of every leaf instance it matches, in document order. Object keys
// match by local name (module qualification may be omitted), list keys by
// value with identityrefs compared by local name; a list the path leaves
// unkeyed matches every entry. A path the document does not hold is nil.
func ConfigValues(doc any, path string) []string {
	cur := []any{doc}
	for _, el := range splitPathElems(path) {
		name, keys := parseElem(el)
		var next []any
		for _, c := range cur {
			v, ok := lookupOK(asMap(c), name)
			if !ok {
				continue
			}
			if arr, isList := v.([]any); isList {
				for _, e := range arr {
					if keysMatch(asMap(e), keys) {
						next = append(next, e)
					}
				}
				continue
			}
			if len(keys) == 0 {
				next = append(next, v)
			}
		}
		cur = next
	}
	var out []string
	for _, c := range cur {
		switch c.(type) {
		case map[string]any, []any:
			continue
		case nil:
			out = append(out, "")
		default:
			out = append(out, fmt.Sprint(c))
		}
	}
	return out
}

// splitPathElems splits a gNMI string path on the slashes outside key brackets.
func splitPathElems(path string) []string {
	var out []string
	depth, start := 0, 0
	for i := 0; i < len(path); i++ {
		switch path[i] {
		case '[':
			depth++
		case ']':
			depth--
		case '/':
			if depth == 0 {
				if i > start {
					out = append(out, path[start:i])
				}
				start = i + 1
			}
		}
	}
	if start < len(path) {
		out = append(out, path[start:])
	}
	return out
}

// parseElem splits one path element name[k=v][k2=v2] into its name and keys.
func parseElem(el string) (string, map[string]string) {
	i := strings.IndexByte(el, '[')
	if i < 0 {
		return el, nil
	}
	name, rest := el[:i], el[i:]
	keys := map[string]string{}
	for len(rest) > 0 && rest[0] == '[' {
		j := strings.IndexByte(rest, ']')
		if j < 0 {
			break
		}
		if k, v, ok := strings.Cut(rest[1:j], "="); ok {
			keys[k] = v
		}
		rest = rest[j+1:]
	}
	return name, keys
}

func keysMatch(e map[string]any, keys map[string]string) bool {
	if e == nil {
		return false
	}
	for k, want := range keys {
		v, ok := lookupOK(e, k)
		if !ok || !scalarEqual(v, want) {
			return false
		}
	}
	return true
}

func findList(doc any, name string) []map[string]any {
	return asList(lookup(asMap(doc), name))
}

// lookup finds key in m by local name (module qualification ignored).
func lookup(m map[string]any, key string) any {
	v, _ := lookupOK(m, key)
	return v
}

func lookupOK(m map[string]any, key string) (any, bool) {
	if m == nil {
		return nil, false
	}
	if v, ok := m[key]; ok {
		return v, true
	}
	for k, v := range m {
		if localName(k) == key {
			return v, true
		}
	}
	return nil, false
}

func asMap(v any) map[string]any {
	m, _ := v.(map[string]any)
	return m
}

func asList(v any) []map[string]any {
	arr, _ := v.([]any)
	out := make([]map[string]any, 0, len(arr))
	for _, e := range arr {
		if m, ok := e.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

func localName(s string) string {
	if i := strings.LastIndex(s, ":"); i >= 0 {
		return s[i+1:]
	}
	return s
}

// missingLeaves returns the leaf paths of want absent from (or different in)
// have. Object keys match by local name (RFC 7951 module qualification may be
// omitted by the layer); a list entry of want must be a subset of some entry of
// have; scalar values compare by their string form, identityrefs by local name.
func missingLeaves(want, have any, path string) []string {
	switch w := want.(type) {
	case map[string]any:
		h, ok := have.(map[string]any)
		if !ok {
			return []string{path + "/"}
		}
		keys := make([]string, 0, len(w))
		for k := range w {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		var out []string
		for _, k := range keys {
			hv, found := lookupOK(h, localName(k))
			if !found {
				out = append(out, path+"/"+localName(k))
				continue
			}
			out = append(out, missingLeaves(w[k], hv, path+"/"+localName(k))...)
		}
		return out
	case []any:
		h, _ := have.([]any)
		var out []string
		for _, we := range w {
			found := false
			for _, he := range h {
				if len(missingLeaves(we, he, "")) == 0 {
					found = true
					break
				}
			}
			if !found {
				out = append(out, path+entryLabel(we))
			}
		}
		return out
	case nil:
		return nil // an empty leaf ([null]) needs presence only
	default:
		if !scalarEqual(w, have) {
			return []string{path}
		}
		return nil
	}
}

func entryLabel(e any) string {
	m, ok := e.(map[string]any)
	if !ok {
		return fmt.Sprintf("[%v]", e)
	}
	for _, k := range []string{"name", "index", "peer-address", "group-name", "afi-safi-name", "ip-prefix", "sequence-id", "interface-id"} {
		if v, ok := m[k]; ok {
			return fmt.Sprintf("[%s=%v]", k, v)
		}
	}
	return "[…]"
}

func scalarEqual(a, b any) bool {
	sa, sb := fmt.Sprint(a), fmt.Sprint(b)
	if sa == sb {
		return true
	}
	return localName(sa) == localName(sb)
}

func hostPrefix(addr string, bits int) string {
	if addr == "" {
		return ""
	}
	if strings.Contains(addr, "/") {
		return addr
	}
	return fmt.Sprintf("%s/%d", addr, bits)
}

func contains(vals []string, want string) bool {
	for _, v := range vals {
		if v == want || localName(v) == want {
			return true
		}
	}
	return false
}

func show(vals []string) string {
	if len(vals) == 0 {
		return "nothing"
	}
	return strings.Join(vals, ",")
}

func dedupe(in []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(in))
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}
