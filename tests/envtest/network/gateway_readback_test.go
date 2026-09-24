//go:build envtest

// T115 (CR-010's envtest tester; T116's read-back): the anycast gateway of a `mac-vrf` is never
// Ready on its IPv4 half alone. The Network reconciler runs against a real API server in the
// fake-state pattern of T054 (suite_test.go: a test standing in for the layer, fake claims, a
// fake clock), but behind its Verifier sits the REAL read-back (internal/verify.Service, so
// internal/verify/gateway.go is exercised) over a fake StateReader: a fake device whose running
// datastore holds what was rendered and whose state datastore reports every object of the
// service up — the IRB subinterface, its anycast gateway and anycast addresses included — and
// whose EVPN RIB is a set of exported collector series answered through verify.MatchState, the
// collector's own key matching.
//
// The gateway declares IPv4 and IPv6; the qualification record
// (agentic-netops-system/fabric-qualification) qualifies ip-vrf.evpn-type5-ipv4 and -ipv6. The
// IPv4 Type-5 routes are present on both leaves, leaf02's IPv6 Type-5 is absent from leaf01's
// RIB: Ready=False/RoutesMissing naming that route — its prefix, the leaf it comes from and its
// RD — on every pass; once the route appears, Ready=True at the next pass; and when it is
// withdrawn again, the scheduled re-verification pass reports it (FR-032, FR-100, CR-010,
// AD-40). With the record NOT qualifying ip-vrf.evpn-type5-ipv6, the IPv6 Type-5 is never read.
package network_test

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/controllers/network"
	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/verify"
	"github.com/mairp/agentic-netops-srl/internal/webhook"
	"github.com/mairp/agentic-netops-srl/pkg/sdc"
)

// gwDevice is the fake device behind the read-back: the running datastore is what the
// renderer rendered for the node; the state datastore answers by leaf and, for the EVPN RIB,
// from the node's exported series.
type gwDevice struct {
	mu        sync.Mutex
	rendered  map[string][]byte
	rib       map[string]map[string]verify.Sample // node -> series identity -> sample
	requested map[string][]string
	passes    int
}

func newGWDevice() *gwDevice {
	return &gwDevice{rendered: map[string][]byte{}, rib: map[string]map[string]verify.Sample{}, requested: map[string][]string{}}
}

// RenderService is the suite's fake renderer, recording each node's document as the running
// datastore the layer would then hold.
func (d *gwDevice) RenderService(m *model.ServiceModel) (map[string]network.Rendered, error) {
	out, err := fakeRenderer{}.RenderService(m)
	if err != nil {
		return nil, err
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	for node, r := range out {
		d.rendered[node] = r.JSON
	}
	return out, nil
}

func (d *gwDevice) Running(_ context.Context, t verify.Target) ([]byte, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if doc, ok := d.rendered[t.Name]; ok {
		return doc, nil
	}
	return []byte(`{}`), nil
}

func (d *gwDevice) State(_ context.Context, t verify.Target, paths []string) (map[string][]string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.passes++
	d.requested[t.Name] = append(d.requested[t.Name], paths...)
	var rib []verify.Sample
	for _, s := range d.rib[t.Name] {
		rib = append(rib, s)
	}
	out := map[string][]string{}
	for _, p := range paths {
		if strings.HasPrefix(p, verify.EVPNIPPrefixRoutePath) {
			got, err := verify.MatchState(rib, []string{p})
			if err != nil {
				return nil, err
			}
			if v := got[p]; len(v) > 0 {
				out[p] = v
			}
			continue
		}
		if v := deviceLeaf(p); v != "" {
			out[p] = []string{v}
		}
	}
	return out, nil
}

// deviceLeaf is a converged device's value of one state leaf: every object up, no reason
// reported, the device's own derivation origins, non-zero indexes, local routes active, every
// configured address preferred and the anycast gateway MAC derived from the virtual-router-id.
func deviceLeaf(p string) string {
	switch {
	case strings.HasSuffix(p, "/oper-down-reason"), strings.HasSuffix(p, "/not-programmed-reason"):
		return ""
	case strings.HasSuffix(p, "/oper-state"):
		return "up"
	case strings.HasSuffix(p, "/route-distinguisher-origin"):
		return verify.OriginAutoDerivedFromEVI
	case strings.HasSuffix(p, "-route-target-origin"):
		return verify.OriginManual
	case strings.HasSuffix(p, "/destination-index"), strings.HasSuffix(p, "/index"):
		return "103476342706"
	case strings.HasSuffix(p, "/active"):
		return "true"
	case strings.HasSuffix(p, "/status"):
		return verify.AddressStatusPreferred
	case strings.HasSuffix(p, "/anycast-gw/anycast-gw-mac-origin"):
		return verify.AnycastOriginVRIDAutoDerived
	}
	return ""
}

// advertise puts into node's EVPN RIB the Type-5 route (rd, prefix) as the collector exports it
// (T116's live observation: one path per spine, the one via the first spine used).
func (d *gwDevice) advertise(t *testing.T, node, rd, prefix string) {
	t.Helper()
	length := prefix[strings.IndexByte(prefix, '/')+1:]
	var lines []string
	for _, nb := range []struct {
		addr string
		used int
	}{{"10.0.0.11", 1}, {"10.0.0.12", 0}} {
		lines = append(lines, fmt.Sprintf(`srl_nokia_network_instance:network_instance_srl_nokia_rib_bgp:bgp_rib_afi_safi_srl_nokia_rib_bgp_evpn:evpn_rib_in_out_rib_in_post_ip_prefix_route_used_route{afi_safi_afi_safi_name="srl_nokia-common:evpn",ip_prefix_route_ethernet_tag_id="0",ip_prefix_route_ip_prefix=%q,ip_prefix_route_ip_prefix_length=%q,ip_prefix_route_neighbor=%q,ip_prefix_route_path_id="0",ip_prefix_route_route_distinguisher=%q,network_instance_name="default",source=%q,subscription_name="device-state"} %d`,
			prefix, length, nb.addr, rd, node, nb.used))
	}
	samples, err := verify.ParseExposition(strings.NewReader(strings.Join(lines, "\n") + "\n"))
	if err != nil {
		t.Fatal(err)
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.rib[node] == nil {
		d.rib[node] = map[string]verify.Sample{}
	}
	for _, s := range samples {
		d.rib[node][rd+"|"+prefix+"|"+s.Labels["ip_prefix_route_neighbor"]] = s
	}
}

// withdraw removes the Type-5 route (rd, prefix) from node's EVPN RIB.
func (d *gwDevice) withdraw(node, rd, prefix string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	for k := range d.rib[node] {
		if strings.HasPrefix(k, rd+"|"+prefix+"|") {
			delete(d.rib[node], k)
		}
	}
}

func (d *gwDevice) passCount() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.passes
}

func (d *gwDevice) read(node, fragment string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, p := range d.requested[node] {
		if strings.Contains(p, fragment) {
			return true
		}
	}
	return false
}

// setQualification writes the qualification record with keys; removed at cleanup.
func setQualification(t *testing.T, keys map[string]string) {
	t.Helper()
	ctx := context.Background()
	cm := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Namespace: webhook.QualificationNamespace, Name: webhook.QualificationName}}
	err := k8s.Get(ctx, client.ObjectKeyFromObject(cm), cm)
	switch {
	case apierrors.IsNotFound(err):
		cm.Data = keys
		must(t, k8s.Create(ctx, cm))
	case err != nil:
		t.Fatal(err)
	default:
		cm.Data = keys
		must(t, k8s.Update(ctx, cm))
	}
	t.Cleanup(func() {
		_ = k8s.Delete(context.Background(), &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{
			Namespace: webhook.QualificationNamespace, Name: webhook.QualificationName}})
	})
}

// gatewayHarness is the suite's harness with the real read-back over the fake device, and the
// qualification record read as the provider reads it (uncached: here the suite's client).
func gatewayHarness(t *testing.T, name string) (*harness, *gwDevice) {
	h := newHarness(t, nsServices, name)
	dev := newGWDevice()
	h.r.Renderer = dev
	h.r.Verifier = &verify.Service{Reader: dev, Configs: sdc.New(k8s)}
	h.r.QualificationReader = k8s
	return h, dev
}

func dualStackGateway(vlan, l2vni, l3vni int64, v4, v6 string) fabricv1.NetworkSpec {
	spec := gatewaySpec(vlan, l2vni, l3vni, v4, att("leaf01", "ethernet-1/1", vlan), att("leaf02", "ethernet-1/1", vlan))
	spec.BridgeDomains[0].IRB.GatewayIPv6 = v6
	return spec
}

var gatewayQualified = map[string]string{
	"mac-vrf": "qualified", "mac-vrf.anycast-gateway-ipv4": "qualified", "mac-vrf.anycast-gateway-ipv6": "qualified",
	"ip-vrf.evpn-type5-ipv4": "qualified", "ip-vrf.evpn-type5-ipv6": "qualified", "acl.binding-without-filter": "qualified",
}

func TestGatewayReadbackIPv6Type5Missing(t *testing.T) {
	setQualification(t, gatewayQualified)
	h, dev := gatewayHarness(t, "gw-readback")
	const (
		v4, v6         = "10.153.0.0/24", "2001:db8:153::/64"
		rdOf01, rdOf02 = "10.0.0.1:11531", "10.0.0.2:11531"
	)
	// every Type-5 present but leaf02's IPv6 one in leaf01's RIB
	dev.advertise(t, "leaf01", rdOf02, v4)
	dev.advertise(t, "leaf02", rdOf01, v4)
	dev.advertise(t, "leaf02", rdOf01, v6)

	h.create(dualStackGateway(530, 11530, 11531, "10.153.0.1/24", "2001:db8:153::1/64"))
	h.reconcile()
	if len(h.configs()) != 2 {
		t.Fatalf("%d Configs rendered, want one per leaf", len(h.configs()))
	}
	confirmConfigs(t, h.ns, h.name)

	missing := "EVPN IP-prefix (Type-5) route 2001:db8:153::/64 from leaf02 (RD 10.0.0.2:11531)"
	// Several passes — first convergence and the retries at the reconciliation interval: each
	// runs the read-back and none is Ready on the IPv4 half alone.
	for i := 0; i < 3; i++ {
		before := dev.passCount()
		res := h.reconcile()
		if dev.passCount() == before {
			t.Fatalf("pass %d: the read-back did not run", i)
		}
		c := h.wantCond("Ready", metav1.ConditionFalse, "RoutesMissing", missing)
		if strings.Contains(c.Message, "10.153.0.0/24") {
			t.Errorf("pass %d: the present IPv4 Type-5 is named missing: %s", i, c.Message)
		}
		if strings.Contains(c.Message, "leaf02 evpn-type5-route") {
			t.Errorf("pass %d: leaf02 holds every route it needs: %s", i, c.Message)
		}
		if res.RequeueAfter != h.r.Settings.ReconcileInterval {
			t.Errorf("pass %d: requeued at %s, want the reconciliation interval %s", i, res.RequeueAfter, h.r.Settings.ReconcileInterval)
		}
		h.clock.Step(res.RequeueAfter)
	}
	// the gateway's own leaves were read on both leaves, keyed to irb0.530, and the route read
	// is the one the other leaf advertises
	for _, node := range leaves {
		for _, frag := range []string{
			verify.SubinterfaceOperStatePath("irb0", 530),
			verify.AnycastGWMACOriginPath("irb0", 530),
			verify.AddressStatusPath("irb0", 530, "10.153.0.1/24"),
			verify.AddressStatusPath("irb0", 530, "2001:db8:153::1/64"),
		} {
			if !dev.read(node, frag) {
				t.Errorf("%s: %s not read", node, frag)
			}
		}
	}
	if !dev.read("leaf01", verify.Type5UsedRoutePath(rdOf02, v6)) || !dev.read("leaf02", verify.Type5UsedRoutePath(rdOf01, v6)) {
		t.Error("the IPv6 Type-5 routes were not read keyed to the other leaf's RD")
	}

	// The route appears: Ready=True at the next pass.
	dev.advertise(t, "leaf01", rdOf02, v6)
	res := h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	if res.RequeueAfter != h.r.Settings.ReverifyInterval {
		t.Errorf("a Ready Network is requeued at %s, want the re-verification interval %s", res.RequeueAfter, h.r.Settings.ReverifyInterval)
	}

	// Withdrawn again: the scheduled re-verification pass (never a cheaper one) reports it.
	dev.withdraw("leaf01", rdOf02, v6)
	h.clock.Step(h.r.Settings.ReverifyInterval)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionFalse, "RoutesMissing", missing)
}

// The record does not qualify ip-vrf.evpn-type5-ipv6: the IPv6 Type-5 is never read, so its
// absence holds nothing back; the IPv4 one still is read.
func TestGatewayReadbackIPv6Type5Unqualified(t *testing.T) {
	keys := map[string]string{}
	for k, v := range gatewayQualified {
		keys[k] = v
	}
	keys["ip-vrf.evpn-type5-ipv6"] = "unqualified"
	setQualification(t, keys)
	h, dev := gatewayHarness(t, "gw-readback-unq")
	dev.advertise(t, "leaf01", "10.0.0.2:11541", "10.154.0.0/24")
	dev.advertise(t, "leaf02", "10.0.0.1:11541", "10.154.0.0/24")

	h.create(dualStackGateway(540, 11540, 11541, "10.154.0.1/24", "2001:db8:154::1/64"))
	h.reconcile()
	confirmConfigs(t, h.ns, h.name)
	h.reconcile()
	h.wantCond("Ready", metav1.ConditionTrue, "")
	for _, node := range leaves {
		if dev.read(node, "ip-prefix=2001:db8:154::/64]") {
			t.Errorf("%s: the unqualified IPv6 Type-5 was read", node)
		}
		if !dev.read(node, "ip-prefix=10.154.0.0/24]") {
			t.Errorf("%s: the qualified IPv4 Type-5 was not read", node)
		}
		// the IPv6 anycast address itself is declared: still read
		if !dev.read(node, verify.AddressStatusPath("irb0", 540, "2001:db8:154::1/64")) {
			t.Errorf("%s: the declared IPv6 anycast address was not read", node)
		}
	}
}
