package verify

// The service read-back (T058; data-model.md §13 "Read-back per construct",
// §18 Ready reasons; contracts/reconciliation.md Rule 5; FR-100, FR-107,
// CR-001, AD-40, AD-82).
//
// VerifyService is THE read-back of a Network: the Network reconciler sets
// Ready from it on first convergence and on every scheduled re-verification —
// the same function each time, never a cheaper one (AD-67).
//
// Written side, per node: the node's priority-20 service Config applied by the
// layer at its current generation, no deviation reported against it, and every
// leaf of its rendered document present in the node's running datastore; for a
// `vlan`, also no vxlan-interface and no bgp-evpn child on its network-instance
// (a `vlan` and a `mac-vrf` render to the same network-instance type, so the
// absence is the construct — contracts/network-spec.md §2).
//
// Applied side, per node, read from the device's own state datastore (the
// device metric collector, AD-82) and keyed to THIS service's own objects:
//   - vlan (vlanExpectations): its network-instance and every member interface
//     oper-state up with no oper-down-reason, and each of its subinterfaces
//     oper-state up. NOTHING overlay-related: a `vlan` has no overlay evidence
//     and is never held to any;
//   - mac-vrf (macvrf.go): the vlan set plus its vxlan-interface (network-
//     instance member and tunnel side), its EVPN instance oper-state, the
//     device's own route-distinguisher and route-target origins, and — once the
//     service spans more than one leaf — per remote leaf the multicast
//     destination to that leaf's system0.0 VTEP programmed and the VTEP itself;
//   - ip-vrf (ipvrf.go, also the routed half of a mac-vrf with a gateway): its
//     network-instance, member interfaces, routed subinterfaces, vxlan-interface,
//     EVPN instance and origins, and every prefix it connects or declares in its
//     own route table — a prefix attached on this leaf as a local route, one
//     attached only on another leaf as an active bgp-evpn route.
//
// A device-wide or fabric-wide count is never evidence (FR-100, CR-001): no
// received-routes, active-routes, route-summary or statistics path is ever
// read, and every path requested names this service's network-instance,
// subinterface, vxlan-interface or the remote VTEP it must reach.
//
// A read that cannot be made — a node with no sample in the collector, a reader
// error, a timeout — makes the pass one that could not run (*CouldNotRunError
// naming the node, Ready=Unknown/VerificationFailed), never a missing value.

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"

	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/status"
)

// Service read-back checks. Each names one kind of invariant; the Ready reason
// follows from the checks found missing (ServiceResult.Reason).
const (
	CheckNetworkInstanceOperState   Check = "network-instance-oper-state"
	CheckInstanceInterfaceOperState Check = "network-instance-interface-oper-state"
	CheckSubinterfaceOperState      Check = "subinterface-oper-state"
	CheckVXLANInterfaceOperState    Check = "vxlan-interface-oper-state"
	CheckEVPNInstanceOperState      Check = "evpn-instance-oper-state"
	CheckBGPVPNOrigin               Check = "bgp-vpn-origin"
	CheckLocalPrefixRoute           Check = "local-prefix-route"
	// RoutesMissing: what a spanning service needs from the other leaves.
	CheckRemoteVTEP           Check = "remote-vtep"
	CheckMulticastDestination Check = "multicast-destination"
	CheckRemotePrefixRoute    Check = "remote-prefix-route"
	// NotProgrammed: present, but the device reports it not programmed.
	CheckNotProgrammed Check = "not-programmed"
)

// Device vocabulary of the service read-back (SR Linux 25.7.1, observed live
// 2026-09-21 on vt-scratch- instances; .specstride/…/phase4/verify-probe.md).
const (
	// RouteTypeBGPEVPN / RouteTypeLocal are route-type keys of an ip-vrf's
	// route table (identityrefs srl_nokia-common:bgp-evpn / :local, compared
	// by local name).
	RouteTypeBGPEVPN = "bgp-evpn"
	RouteTypeLocal   = "local"
	// OriginAutoDerivedFromEVI is the route-distinguisher-origin the device
	// reports for the RD it derives (<system0.0 IPv4>:<evi>; never rendered).
	OriginAutoDerivedFromEVI = "auto-derived-from-evi"
	// OriginManual is the route-target origin of an explicitly rendered target.
	OriginManual = "manual"
)

// ServiceNodeInput is one node's written-side input: the node's priority-20
// service Config and the document rendered into it.
type ServiceNodeInput struct {
	Node       string
	ConfigName string
	Rendered   []byte
}

// ServiceInput is everything one service read-back pass needs.
type ServiceInput struct {
	// Model is the canonical service model the Configs were rendered from; its
	// network-instances, subinterfaces, vxlan-interfaces and prefixes key every read.
	Model *model.ServiceModel
	// Prefixes are the ip-vrf's declared prefixes (spec.routers[].prefixes), by
	// routed network-instance name.
	Prefixes map[string][]string
	// Loopbacks is every leaf's allocated system0.0 IPv4 address (the VTEP), by
	// node — the remote VTEPs a spanning service must see. A prefix length, if
	// carried, is ignored.
	Loopbacks map[string]string
	// TargetNamespace is the namespace of the layer's Targets.
	TargetNamespace string
	// Nodes carries the written-side input of every node of Model.
	Nodes []ServiceNodeInput
}

// ServiceResult is a read-back that RAN — completed on both sides — whatever
// it found. A pass that could not run is a *CouldNotRunError instead.
type ServiceResult struct {
	// Missing are the invariants that did not hold, each naming node, check and
	// detail, sorted.
	Missing []Invariant
	// Paths are the state paths read (keyed to this service's own objects), sorted.
	Paths []string
	// ConfigPaths are the paths read from the configuration datastore (the
	// `vlan` no-overlay written-side check), sorted.
	ConfigPaths []string
}

// Passed reports whether every invariant held.
func (r ServiceResult) Passed() bool { return len(r.Missing) == 0 }

// ReasonOf is the Ready=False reason one missing check stands for
// (data-model.md §18): RoutesMissing for a remote VTEP, multicast destination
// or remote prefix a spanning service needs and does not have; NotProgrammed
// for an object the device reports not programmed (a not-programmed-reason, a
// zero destination or VTEP index); NotConverged for everything else.
func ReasonOf(c Check) string {
	switch c {
	case CheckRemoteVTEP, CheckMulticastDestination, CheckRemotePrefixRoute:
		return status.ReasonRoutesMissing
	case CheckNotProgrammed:
		return status.ReasonNotProgrammed
	default:
		return status.ReasonNotConverged
	}
}

// Reason is the Ready=False reason of a pass that found something missing.
// When invariants of several classes are missing the most fundamental one is
// reported — NotConverged, then NotProgrammed, then RoutesMissing — because a
// local object that is not up is the cause of the routes the other leaves then
// lack, never the other way round; the message names every invariant anyway.
// Like FabricResult.Reason it is only meaningful for a pass that did not pass
// (it then reads NotConverged).
func (r ServiceResult) Reason() string {
	seen := map[string]bool{}
	for _, m := range r.Missing {
		seen[ReasonOf(m.Check)] = true
	}
	for _, reason := range []string{status.ReasonNotConverged, status.ReasonNotProgrammed, status.ReasonRoutesMissing} {
		if seen[reason] {
			return reason
		}
	}
	return status.ReasonNotConverged
}

// Message names every missing invariant, or the passing read-back.
func (r ServiceResult) Message() string {
	if r.Passed() {
		return "read-back passed on both sides"
	}
	parts := make([]string, 0, len(r.Missing))
	for _, m := range r.Missing {
		parts = append(parts, m.String())
	}
	return "missing: " + strings.Join(parts, "; ")
}

// Service is the service read-back over the same readers as Fabric.
type Service struct {
	Reader  StateReader
	Configs ConfigReader
	// Timeout bounds one pass; a read still outstanding at the deadline makes
	// the pass one that could not run. Zero means 30 s.
	Timeout time.Duration
}

// VerifyService runs one read-back pass. It returns a ServiceResult (nil
// error) for a pass that ran, whatever it found, and a *CouldNotRunError for a
// pass that could not run against one or more of the service's nodes. Any
// other error is an input the pass cannot key its reads from.
func (s *Service) VerifyService(ctx context.Context, in ServiceInput) (ServiceResult, error) {
	if in.Model == nil {
		return ServiceResult{}, fmt.Errorf("verify service: nil model")
	}
	exps, err := ServiceExpectations(in)
	if err != nil {
		return ServiceResult{}, err
	}
	timeout := s.Timeout
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	written := map[string]ServiceNodeInput{}
	for _, n := range in.Nodes {
		written[n.Node] = n
	}
	var res ServiceResult
	causes := map[string]error{}
	nodes := append([]model.ServiceNode(nil), in.Model.Nodes...)
	sort.Slice(nodes, func(i, j int) bool { return nodes[i].Node < nodes[j].Node })
	for i := range nodes {
		n := &nodes[i]
		target := Target{Namespace: in.TargetNamespace, Name: n.Node}
		missing, paths, cfgPaths, err := s.verifyNode(ctx, target, in.Model.Construct, n, written[n.Node], exps[n.Node])
		if err != nil {
			if ctx.Err() != nil {
				err = fmt.Errorf("read timed out after %s: %w", timeout, err)
			}
			causes[n.Node] = err
			continue
		}
		res.Missing = append(res.Missing, missing...)
		res.Paths = append(res.Paths, paths...)
		res.ConfigPaths = append(res.ConfigPaths, cfgPaths...)
	}
	if len(causes) > 0 {
		return ServiceResult{}, &CouldNotRunError{Causes: causes}
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
	sort.Strings(res.Paths)
	sort.Strings(res.ConfigPaths)
	return res, nil
}

func (s *Service) verifyNode(ctx context.Context, target Target, construct model.Construct, n *model.ServiceNode,
	w ServiceNodeInput, exps []StateExpectation) ([]Invariant, []string, []string, error) {
	var missing []Invariant
	miss := func(c Check, format string, a ...any) {
		missing = append(missing, Invariant{Node: n.Node, Check: c, Detail: fmt.Sprintf(format, a...)})
	}

	// --- written side: the Config applied, no deviation ---
	if w.ConfigName == "" {
		miss(CheckWritten, "no priority-20 service Config recorded for the node")
	} else {
		cfg, err := s.Configs.GetConfig(ctx, w.ConfigName)
		switch {
		case apierrors.IsNotFound(err):
			miss(CheckWritten, "Config %s absent", w.ConfigName)
		case err != nil:
			return nil, nil, nil, fmt.Errorf("read Config %s: %w", w.ConfigName, err)
		default:
			if ok, why := configApplied(cfg); !ok {
				miss(CheckWritten, "Config %s not applied by the layer: %s", w.ConfigName, why)
			}
			dev, err := s.Configs.GetConfigDeviation(ctx, w.ConfigName)
			if err != nil {
				return nil, nil, nil, fmt.Errorf("read Deviation of Config %s: %w", w.ConfigName, err)
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
	running, err := s.Reader.Running(ctx, target)
	if err != nil {
		return nil, nil, nil, err
	}
	var runningDoc any
	if err := json.Unmarshal(running, &runningDoc); err != nil {
		return nil, nil, nil, fmt.Errorf("running configuration of %s is not JSON: %w", n.Node, err)
	}
	if len(w.Rendered) > 0 {
		var want any
		if err := json.Unmarshal(w.Rendered, &want); err != nil {
			return nil, nil, nil, fmt.Errorf("rendered document of %s is not JSON: %w", n.Node, err)
		}
		if absent := missingLeaves(want, runningDoc, ""); len(absent) > 0 {
			shown := absent
			if len(shown) > 5 {
				shown = append(append([]string{}, shown[:5]...), fmt.Sprintf("… %d more", len(absent)-5))
			}
			miss(CheckWritten, "rendered content absent from the running datastore: %s", strings.Join(shown, ", "))
		}
	}
	var cfgPaths []string
	if construct == model.ConstructVLAN {
		// a vlan's network-instance carries no overlay child in the running datastore
		for _, ni := range n.NetworkInstances {
			for _, p := range []string{
				"/network-instance[name=" + ni.Name + "]/vxlan-interface/name",
				"/network-instance[name=" + ni.Name + "]/protocols/bgp-evpn/bgp-instance/id",
			} {
				cfgPaths = append(cfgPaths, p)
				if vals := ConfigValues(runningDoc, p); len(vals) > 0 {
					miss(CheckWritten, "vlan network-instance %s carries an overlay child in the running datastore: %s reads %s, want absent",
						ni.Name, p, show(vals))
				}
			}
		}
	}

	// --- applied side: one state read, keyed to this service's own objects ---
	var paths []string
	for _, e := range exps {
		paths = append(paths, e.Path)
		if e.ReasonPath != "" {
			paths = append(paths, e.ReasonPath)
		}
		if e.RouteEvidencePath != "" {
			paths = append(paths, e.RouteEvidencePath)
		}
	}
	paths = dedupe(paths)
	if len(paths) == 0 {
		return missing, nil, cfgPaths, nil
	}
	got, err := s.Reader.State(ctx, target, paths)
	if err != nil {
		return nil, nil, nil, err
	}
	for _, e := range exps {
		if c, detail, ok := e.evaluate(got); !ok {
			miss(c, "%s", detail)
		}
	}
	return missing, paths, cfgPaths, nil
}

// ---------------------------------------------------------------------------
// Expectations.
// ---------------------------------------------------------------------------

// Expect is how a StateExpectation's value is judged.
type Expect int

const (
	// ExpectEquals: some instance reads Want.
	ExpectEquals Expect = iota
	// ExpectNonZero: present and non-zero (an index). Absent is the
	// expectation's Check; zero is CheckNotProgrammed.
	ExpectNonZero
)

// StateExpectation is one applied-side leaf of one node and what it must read.
type StateExpectation struct {
	Check Check
	// What names the service's own object the leaf belongs to.
	What string
	Path string
	Want string
	Expect
	// ReasonPath is the device's own reason leaf for the object (an
	// oper-down-reason or not-programmed-reason), read with it and surfaced in
	// the condition message when the expectation fails.
	ReasonPath string
	// ReasonAbsent additionally requires ReasonPath to report nothing, even
	// when Path reads as wanted; a reason present is then ReasonCheck.
	ReasonAbsent bool
	// ReasonCheck is the check a present reason is reported under (Check when empty).
	ReasonCheck Check
	// RouteEvidencePath, when set, is the leaf whose presence shows the route
	// this object is derived from (a remote VTEP's multicast destination). A
	// zero index read while that leaf reads nothing is the consequence of the
	// missing route, not a programming failure of this service's own
	// configuration, so it is reported under Check (RoutesMissing) and never
	// as NotProgrammed. Observed live 2026-09-24 (T167, AD-82 finding
	// 2026-09-24-vtep-teardown): after a leaf's uplinks are taken down the
	// remote VTEP reads index 0 for one pass while its multicast destinations
	// are already gone.
	RouteEvidencePath string
}

func (e StateExpectation) evaluate(got map[string][]string) (Check, string, bool) {
	vals := got[e.Path]
	var reasonVals []string
	reason := ""
	if e.ReasonPath != "" {
		if reasonVals = got[e.ReasonPath]; len(reasonVals) > 0 {
			reason = fmt.Sprintf(" (the device reports %s %s)", leafName(e.ReasonPath), strings.Join(reasonVals, ","))
		}
	}
	switch e.Expect {
	case ExpectNonZero:
		if len(vals) == 0 {
			return e.Check, fmt.Sprintf("%s: %s reads nothing, want a non-zero index%s", e.What, e.Path, reason), false
		}
		for _, v := range vals {
			if v == "0" {
				if e.RouteEvidencePath != "" && len(got[e.RouteEvidencePath]) == 0 {
					return e.Check, fmt.Sprintf("%s: %s reads 0 and its route evidence %s reads nothing, want a non-zero index%s",
						e.What, e.Path, e.RouteEvidencePath, reason), false
				}
				return CheckNotProgrammed, fmt.Sprintf("%s: %s reads 0, want a non-zero index%s", e.What, e.Path, reason), false
			}
		}
	default:
		if !contains(vals, e.Want) {
			return e.Check, fmt.Sprintf("%s: %s reads %s, want %s%s", e.What, e.Path, show(vals), e.Want, reason), false
		}
	}
	if e.ReasonAbsent && len(reasonVals) > 0 {
		c := e.ReasonCheck
		if c == "" {
			c = e.Check
		}
		return c, fmt.Sprintf("%s: %s reports %s, want absent", e.What, e.ReasonPath, show(reasonVals)), false
	}
	return "", "", true
}

func leafName(path string) string {
	elems := splitPathElems(path)
	if len(elems) == 0 {
		return path
	}
	name, _ := parseElem(elems[len(elems)-1])
	return name
}

// ServiceExpectations are the applied-side leaves of every node of the
// service, by node: the vlan set on every bridged instance, the mac-vrf
// overlay set on one with a vxlan-interface, the ip-vrf set on every routed
// instance. A `vlan` gets the vlan set alone. It fails only on an input the
// reads cannot be keyed from (a remote leaf with no allocated VTEP address).
func ServiceExpectations(in ServiceInput) (map[string][]StateExpectation, error) {
	out := map[string][]StateExpectation{}
	m := in.Model
	for i := range m.Nodes {
		n := &m.Nodes[i]
		var exps []StateExpectation
		for j := range n.NetworkInstances {
			ni := &n.NetworkInstances[j]
			switch {
			case ni.Type == model.MACVRF && (m.Construct == model.ConstructVLAN || ni.VXLANInterface == ""):
				exps = append(exps, vlanExpectations(n, ni)...)
			case ni.Type == model.MACVRF:
				e, err := macvrfExpectations(m, n, ni, in.Loopbacks)
				if err != nil {
					return nil, err
				}
				exps = append(exps, e...)
			case ni.Type == model.IPVRF:
				exps = append(exps, ipvrfExpectations(m, n, ni, in.Prefixes[ni.Name])...)
			}
		}
		out[n.Node] = exps
	}
	return out, nil
}

// vlanExpectations: the network-instance and every member interface up with no
// oper-down-reason, and each of the instance's own subinterfaces up. Nothing
// overlay-related is ever added here.
func vlanExpectations(n *model.ServiceNode, ni *model.NetworkInstance) []StateExpectation {
	out := instanceExpectations(ni)
	out = append(out, subinterfaceExpectations(n, ni)...)
	return out
}

// instanceExpectations: the network-instance and each member interface.
func instanceExpectations(ni *model.NetworkInstance) []StateExpectation {
	out := []StateExpectation{{Check: CheckNetworkInstanceOperState, What: "network-instance " + ni.Name,
		Path: NetworkInstanceOperStatePath(ni.Name), Want: OperStateUp,
		ReasonPath: NetworkInstanceOperDownReasonPath(ni.Name), ReasonAbsent: true}}
	for _, ifc := range ni.Interfaces {
		out = append(out, StateExpectation{Check: CheckInstanceInterfaceOperState,
			What: fmt.Sprintf("network-instance %s interface %s", ni.Name, ifc),
			Path: InstanceInterfaceOperStatePath(ni.Name, ifc), Want: OperStateUp,
			ReasonPath: InstanceInterfaceOperDownReasonPath(ni.Name, ifc), ReasonAbsent: true})
	}
	return out
}

// subinterfaceExpectations: each of the node's service-owned access-port
// subinterfaces that is a member of ni, oper-state up (its reason surfaced).
func subinterfaceExpectations(n *model.ServiceNode, ni *model.NetworkInstance) []StateExpectation {
	var out []StateExpectation
	for _, s := range n.Subinterfaces {
		if !containsString(ni.Interfaces, s.Name()) {
			continue
		}
		out = append(out, StateExpectation{Check: CheckSubinterfaceOperState, What: "subinterface " + s.Name(),
			Path: SubinterfaceOperStatePath(s.Port, s.Index), Want: OperStateUp,
			ReasonPath: SubinterfaceOperDownReasonPath(s.Port, s.Index)})
	}
	return out
}

// overlayExpectations: the instance's vxlan-interface (member and tunnel
// side), its EVPN instance, and the device's own RD / RT derivation origins —
// the leaves that make the route-distinguisher and route-target checks genuine
// applied-side assertions (data-model.md §13).
func overlayExpectations(ni *model.NetworkInstance, vx *model.VXLANInterface) []StateExpectation {
	var out []StateExpectation
	if ni.VXLANInterface != "" {
		out = append(out, StateExpectation{Check: CheckVXLANInterfaceOperState,
			What: fmt.Sprintf("network-instance %s vxlan-interface %s", ni.Name, ni.VXLANInterface),
			Path: InstanceVXLANInterfaceOperStatePath(ni.Name, ni.VXLANInterface), Want: OperStateUp,
			ReasonPath: InstanceVXLANInterfaceOperDownReasonPath(ni.Name, ni.VXLANInterface), ReasonAbsent: true})
	}
	if vx != nil {
		out = append(out, StateExpectation{Check: CheckVXLANInterfaceOperState, What: "tunnel " + vx.Name(),
			Path: TunnelVXLANInterfaceOperStatePath(vx.Index), Want: OperStateUp,
			ReasonPath: TunnelVXLANInterfaceOperDownReasonPath(vx.Index)})
	}
	if ni.EVPN != nil {
		out = append(out, StateExpectation{Check: CheckEVPNInstanceOperState,
			What: fmt.Sprintf("network-instance %s EVPN instance %d (evi %d)", ni.Name, ni.EVPN.ID, ni.EVPN.EVI),
			Path: EVPNInstanceOperStatePath(ni.Name, ni.EVPN.ID), Want: OperStateUp,
			ReasonPath: EVPNInstanceOperDownReasonPath(ni.Name, ni.EVPN.ID)})
	}
	if ni.BGPVPN != nil {
		what := fmt.Sprintf("network-instance %s bgp-vpn instance %d", ni.Name, ni.BGPVPN.ID)
		out = append(out,
			StateExpectation{Check: CheckBGPVPNOrigin, What: what + " route distinguisher (device-derived)",
				Path: RDOriginPath(ni.Name, ni.BGPVPN.ID), Want: OriginAutoDerivedFromEVI},
			StateExpectation{Check: CheckBGPVPNOrigin, What: what + " export route target " + ni.BGPVPN.ExportRT,
				Path: RTOriginPath(ni.Name, ni.BGPVPN.ID, "export"), Want: OriginManual},
			StateExpectation{Check: CheckBGPVPNOrigin, What: what + " import route target " + ni.BGPVPN.ImportRT,
				Path: RTOriginPath(ni.Name, ni.BGPVPN.ID, "import"), Want: OriginManual})
	}
	return out
}

// vxlanOf is the node's vxlan-interface the instance names, or nil.
func vxlanOf(n *model.ServiceNode, ni *model.NetworkInstance) *model.VXLANInterface {
	for i := range n.VXLANInterfaces {
		if n.VXLANInterfaces[i].Name() == ni.VXLANInterface {
			return &n.VXLANInterfaces[i]
		}
	}
	return nil
}

func containsString(list []string, s string) bool {
	for _, e := range list {
		if e == s {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Paths (native srl_nokia, gNMI string form), every one keyed to one object.
// ---------------------------------------------------------------------------

func niPath(ni string) string { return "/network-instance[name=" + ni + "]" }

// NetworkInstanceOperStatePath is /network-instance[name=<ni>]/oper-state.
func NetworkInstanceOperStatePath(ni string) string { return niPath(ni) + "/oper-state" }

// NetworkInstanceOperDownReasonPath is /network-instance[name=<ni>]/oper-down-reason.
func NetworkInstanceOperDownReasonPath(ni string) string { return niPath(ni) + "/oper-down-reason" }

// InstanceInterfaceOperStatePath is /network-instance[name=<ni>]/interface[name=<if>]/oper-state.
func InstanceInterfaceOperStatePath(ni, ifc string) string {
	return niPath(ni) + "/interface[name=" + ifc + "]/oper-state"
}

// InstanceInterfaceOperDownReasonPath is …/interface[name=<if>]/oper-down-reason.
func InstanceInterfaceOperDownReasonPath(ni, ifc string) string {
	return niPath(ni) + "/interface[name=" + ifc + "]/oper-down-reason"
}

// SubinterfaceOperDownReasonPath is /interface[name=<port>]/subinterface[index=<i>]/oper-down-reason.
func SubinterfaceOperDownReasonPath(port string, index uint32) string {
	return fmt.Sprintf("/interface[name=%s]/subinterface[index=%d]/oper-down-reason", port, index)
}

// InstanceVXLANInterfaceOperStatePath is /network-instance[name=<ni>]/vxlan-interface[name=vxlan0.<i>]/oper-state.
func InstanceVXLANInterfaceOperStatePath(ni, vx string) string {
	return niPath(ni) + "/vxlan-interface[name=" + vx + "]/oper-state"
}

// InstanceVXLANInterfaceOperDownReasonPath is …/vxlan-interface[name=vxlan0.<i>]/oper-down-reason.
func InstanceVXLANInterfaceOperDownReasonPath(ni, vx string) string {
	return niPath(ni) + "/vxlan-interface[name=" + vx + "]/oper-down-reason"
}

func tunnelVXLANPath(index uint32) string {
	return fmt.Sprintf("/tunnel-interface[name=%s]/vxlan-interface[index=%d]", model.TunnelInterface, index)
}

// TunnelVXLANInterfaceOperStatePath is /tunnel-interface[name=vxlan0]/vxlan-interface[index=<i>]/oper-state.
func TunnelVXLANInterfaceOperStatePath(index uint32) string {
	return tunnelVXLANPath(index) + "/oper-state"
}

// TunnelVXLANInterfaceOperDownReasonPath is …/vxlan-interface[index=<i>]/oper-down-reason.
func TunnelVXLANInterfaceOperDownReasonPath(index uint32) string {
	return tunnelVXLANPath(index) + "/oper-down-reason"
}

// EVPNInstanceOperStatePath is /network-instance[name=<ni>]/protocols/bgp-evpn/bgp-instance[id=<id>]/oper-state.
func EVPNInstanceOperStatePath(ni string, id uint32) string {
	return fmt.Sprintf("%s/protocols/bgp-evpn/bgp-instance[id=%d]/oper-state", niPath(ni), id)
}

// EVPNInstanceOperDownReasonPath is …/bgp-evpn/bgp-instance[id=<id>]/oper-down-reason.
func EVPNInstanceOperDownReasonPath(ni string, id uint32) string {
	return fmt.Sprintf("%s/protocols/bgp-evpn/bgp-instance[id=%d]/oper-down-reason", niPath(ni), id)
}

// RDOriginPath is …/protocols/bgp-vpn/bgp-instance[id=<id>]/route-distinguisher/route-distinguisher-origin.
func RDOriginPath(ni string, id uint32) string {
	return fmt.Sprintf("%s/protocols/bgp-vpn/bgp-instance[id=%d]/route-distinguisher/route-distinguisher-origin", niPath(ni), id)
}

// RTOriginPath is …/protocols/bgp-vpn/bgp-instance[id=<id>]/route-target/<export|import>-route-target-origin.
func RTOriginPath(ni string, id uint32, direction string) string {
	return fmt.Sprintf("%s/protocols/bgp-vpn/bgp-instance[id=%d]/route-target/%s-route-target-origin", niPath(ni), id, direction)
}
