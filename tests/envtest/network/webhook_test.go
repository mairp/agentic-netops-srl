//go:build envtest

// Webhook tests (T056; contracts/crd-api.md §"Required Fabric and Network API", §"The webhook
// fails closed", §"What the webhook evaluates, and what it lets through unread"; FR-034, FR-097,
// FR-103, CR-003, AD-20, AD-52, AD-61, AD-68).
//
// Every case is decided by a real API server's admission: the generated CRDs (config/crd, CEL
// included) and the SHIPPED ValidatingWebhookConfiguration — deploy/agentic-netops/webhook.yaml,
// loaded from the file with only its clientConfig pointed at envtest's local server (envtest's
// own WebhookInstallOptions does that and nothing else) — calling internal/webhook's handler,
// registered by webhook.Register exactly as the provider registers it, in a controller-runtime
// webhook server. Nothing calls the handler directly.
//
// This file shares package network_test with the Network controller suites, which own the
// package's TestMain: every package-level identifier here carries the `wh` prefix, and each
// TestWebhook* function starts — and stops, through t.Cleanup — its own control plane
// (whStart), so no process outlives the test binary and nothing depends on the other suites.
//
// Run: KUBEBUILDER_ASSETS=... go test -tags envtest ./tests/envtest/network/ -run TestWebhook

package network_test

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
	utilyaml "k8s.io/apimachinery/pkg/util/yaml"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	ctrlwebhook "sigs.k8s.io/controller-runtime/pkg/webhook"
	"sigs.k8s.io/yaml"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/internal/webhook"
)

const (
	whNSSystem   = "agentic-netops-system"
	whNSIntent   = "agentic-netops-intent"
	whNSServices = "agentic-netops-services"
	// whFinalizer is the provider's Network finalizer (controllers/network.Finalizer); the value is
	// immaterial to admission — any finalizer holds a deleted object.
	whFinalizer    = "fabric.agentic-netops.io/finalizer"
	whForceRelease = "fabric.agentic-netops.io/force-release"
	whWebhookName  = "networks.fabric.agentic-netops.io"
	whShippedPath  = "deploy/agentic-netops/webhook.yaml"
	whFabricName   = "fabric01"
	whTimeout      = 20 * time.Second
)

// whFabricYAML: three leaves and one spine. leaf01 declares ethernet-1/3 untagged, leaf02
// declares ethernet-1/2 untagged, leaf03 declares nothing untagged (AD-68).
const whFabricYAML = `
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Fabric
metadata: {name: fabric01, namespace: agentic-netops-system}
spec:
  nodes:
  - {name: spine01, role: spine, platform: ixr-d3l, systemIPv4: 10.0.0.11/32, asn: 65100, routeReflector: true}
  - {name: leaf01, role: leaf, platform: ixr-d2l, systemIPv4: 10.0.0.1/32, asn: 65101}
  - {name: leaf02, role: leaf, platform: ixr-d2l, systemIPv4: 10.0.0.2/32, asn: 65102}
  - {name: leaf03, role: leaf, platform: ixr-d2l, systemIPv4: 10.0.0.3/32, asn: 65103}
  underlay:
    addressFamilies: [ipv4]
  overlay: {fabricASN: 65000, routeReflectors: [spine01], interASVPN: true}
  mtu: {portMTU: 9412, underlayIPMTU: 9398, bridgedL2MTU: 9412, tenantIPMTU: 9348}
  inventory:
  - {node: leaf01, accessPorts: [ethernet-1/1, ethernet-1/2, ethernet-1/3], untaggedAccessPorts: [ethernet-1/3], fabricPorts: [ethernet-1/49]}
  - {node: leaf02, accessPorts: [ethernet-1/1, ethernet-1/2], untaggedAccessPorts: [ethernet-1/2], fabricPorts: [ethernet-1/49]}
  - {node: leaf03, accessPorts: [ethernet-1/1], fabricPorts: [ethernet-1/49]}
  - {node: spine01, fabricPorts: [ethernet-1/1, ethernet-1/2, ethernet-1/3]}
`

// The valid names each refusal must list: the access ports declared in the mode asked for.
const (
	whTaggedPorts   = "leaf01 [ethernet-1/1, ethernet-1/2], leaf02 [ethernet-1/1], leaf03 [ethernet-1/1]"
	whUntaggedPorts = "leaf01 [ethernet-1/3], leaf02 [ethernet-1/2], leaf03 [none]"
)

// whQualified is the live record's flat keys (agentic-netops-system/fabric-qualification), all
// qualified.
var whQualified = []string{
	"vlan", "vlan.bridged-subinterface",
	"mac-vrf", "mac-vrf.evpn-type2", "mac-vrf.evpn-type3", "mac-vrf.reflection", "mac-vrf.tenant-mtu",
	"mac-vrf.anycast-gateway-ipv4", "mac-vrf.anycast-gateway-ipv6",
	"ip-vrf", "ip-vrf.evpn-type5-ipv4", "ip-vrf.evpn-type5-ipv6", "ip-vrf.tenant-mtu",
	"acl", "acl.ingress-ipv4", "acl.ingress-ipv6", "acl.binding-without-filter", "acl.per-entry-statistics", "acl.egress",
}

// ---------------------------------------------------------------------------------------------
// Harness

type whHarness struct {
	env     *envtest.Environment
	c       client.Client
	scheme  *k8sruntime.Scheme
	stopSrv func()
}

func whRepoRoot() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
}

// whShippedDocs reads every document of the shipped webhook.yaml.
func whShippedDocs(t *testing.T) [][]byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(whRepoRoot(), whShippedPath))
	if err != nil {
		t.Fatal(err)
	}
	r := utilyaml.NewYAMLReader(bufio.NewReader(bytes.NewReader(b)))
	var docs [][]byte
	for {
		d, err := r.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if len(bytes.TrimSpace(d)) > 0 {
			docs = append(docs, d)
		}
	}
	return docs
}

// whShippedVWC is the shipped ValidatingWebhookConfiguration, exactly as the file states it.
func whShippedVWC(t *testing.T) *admissionregistrationv1.ValidatingWebhookConfiguration {
	t.Helper()
	var found *admissionregistrationv1.ValidatingWebhookConfiguration
	for _, d := range whShippedDocs(t) {
		var tm metav1.TypeMeta
		if err := yaml.Unmarshal(d, &tm); err != nil {
			t.Fatal(err)
		}
		if tm.Kind != "ValidatingWebhookConfiguration" {
			continue
		}
		if found != nil {
			t.Fatalf("%s states more than one ValidatingWebhookConfiguration", whShippedPath)
		}
		found = &admissionregistrationv1.ValidatingWebhookConfiguration{}
		if err := yaml.UnmarshalStrict(d, found); err != nil {
			t.Fatal(err)
		}
	}
	if found == nil {
		t.Fatalf("%s states no ValidatingWebhookConfiguration", whShippedPath)
	}
	return found
}

// whStart starts a control plane with the CRDs and the shipped webhook configuration, the
// provider's handler served behind it, the namespaces, the Fabric and the qualification record.
func whStart(t *testing.T) *whHarness {
	t.Helper()
	root := whRepoRoot()
	env := &envtest.Environment{
		CRDDirectoryPaths:     []string{filepath.Join(root, "config", "crd")},
		ErrorIfCRDPathMissing: true,
		WebhookInstallOptions: envtest.WebhookInstallOptions{
			// Only the clientConfig is adapted — envtest replaces the Service with its local URL
			// and the cert-manager-injected caBundle with its own CA.
			ValidatingWebhooks: []*admissionregistrationv1.ValidatingWebhookConfiguration{whShippedVWC(t)},
		},
	}
	cfg, err := env.Start()
	if err != nil {
		t.Fatalf("envtest: starting the control plane (is KUBEBUILDER_ASSETS set?): %v", err)
	}
	h := &whHarness{env: env}
	t.Cleanup(func() {
		if h.stopSrv != nil {
			h.stopSrv()
		}
		if err := env.Stop(); err != nil {
			t.Logf("envtest stop: %v", err)
		}
	})
	h.scheme = k8sruntime.NewScheme()
	for _, add := range []func(*k8sruntime.Scheme) error{clientgoscheme.AddToScheme, fabricv1.AddToScheme} {
		if err := add(h.scheme); err != nil {
			t.Fatal(err)
		}
	}
	if h.c, err = client.New(cfg, client.Options{Scheme: h.scheme}); err != nil {
		t.Fatal(err)
	}
	h.startServer(t)

	ctx := context.Background()
	for _, ns := range []string{whNSSystem, whNSIntent, whNSServices} {
		if err := h.c.Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: ns}}); err != nil {
			t.Fatal(err)
		}
	}
	f := &fabricv1.Fabric{}
	if err := yaml.UnmarshalStrict([]byte(whFabricYAML), f); err != nil {
		t.Fatal(err)
	}
	if err := h.c.Create(ctx, f); err != nil {
		t.Fatalf("creating the Fabric: %v", err)
	}
	data := map[string]string{}
	for _, k := range whQualified {
		data[k] = "qualified"
	}
	if err := h.c.Create(ctx, &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Namespace: webhook.QualificationNamespace, Name: webhook.QualificationName},
		Data:       data,
	}); err != nil {
		t.Fatal(err)
	}
	h.waitReachable(t)
	return h
}

// startServer serves the provider's handler — registered by webhook.Register, as the provider
// does — on envtest's local serving address, reading through an uncached client as the
// provider's API reader does.
func (h *whHarness) startServer(t *testing.T) {
	t.Helper()
	o := h.env.WebhookInstallOptions
	srv := ctrlwebhook.NewServer(ctrlwebhook.Options{Host: o.LocalServingHost, Port: o.LocalServingPort, CertDir: o.LocalServingCertDir})
	webhook.Register(srv, h.c, h.scheme)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		if err := srv.Start(ctx); err != nil {
			t.Logf("webhook server: %v", err)
		}
	}()
	h.stopSrv = func() { cancel(); <-done; h.stopSrv = nil }
	addr := net.JoinHostPort(o.LocalServingHost, strconv.Itoa(o.LocalServingPort))
	whEventually(t, "the webhook server serves TLS", func() error {
		conn, err := tls.DialWithDialer(&net.Dialer{Timeout: time.Second}, "tcp", addr, &tls.Config{InsecureSkipVerify: true}) //nolint:gosec // readiness probe of a local test server
		if err != nil {
			return err
		}
		return conn.Close()
	})
}

// stopServer makes the webhook's endpoint unreachable: the provider is down.
func (h *whHarness) stopServer(t *testing.T) {
	t.Helper()
	if h.stopSrv != nil {
		h.stopSrv()
	}
}

// waitReachable waits until the API server's call reaches the handler: a dry-run create of a
// resolvable Network is admitted.
func (h *whHarness) waitReachable(t *testing.T) {
	t.Helper()
	probe := whVLANNet(whNSServices, "wh-probe", 999, whTag("leaf03", "ethernet-1/1", 999))
	whEventually(t, "the webhook admits through the API server", func() error {
		return h.c.Create(context.Background(), probe.DeepCopy(), client.DryRunAll)
	})
}

func whEventually(t *testing.T, what string, f func() error) {
	t.Helper()
	deadline := time.Now().Add(whTimeout)
	var err error
	for time.Now().Before(deadline) {
		if err = f(); err == nil {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s: %v", what, err)
}

// ---------------------------------------------------------------------------------------------
// Fixtures and assertions

func whVID(v int64) *fabricv1.AttachmentVLAN { a := fabricv1.AttachmentVLAN(v); return &a }

func whTag(node, port string, v int64) fabricv1.NetworkAttachment {
	return fabricv1.NetworkAttachment{Node: fabricv1.DNSLabel(node), Attachment: fabricv1.PortName(port), VLAN: whVID(v)}
}

func whUntag(node, port string) fabricv1.NetworkAttachment {
	return fabricv1.NetworkAttachment{Node: fabricv1.DNSLabel(node), Attachment: fabricv1.PortName(port)}
}

// whVLANNet is a vlan service on VLAN v (named band).
func whVLANNet(ns, name string, v int64, atts ...fabricv1.NetworkAttachment) *fabricv1.Network {
	return &fabricv1.Network{
		ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name},
		Spec: fabricv1.NetworkSpec{
			VLANs:       []fabricv1.NetworkVLAN{{Name: fabricv1.DNSLabel(fmt.Sprintf("vlan-%d", v)), VLAN: fabricv1.VLANID(v)}},
			Attachments: atts,
		},
	}
}

// whIPVRF is an ip-vrf; its attachments may be untagged.
func whIPVRF(ns, name string, l3vni int64, atts ...fabricv1.NetworkAttachment) *fabricv1.Network {
	for i := range atts {
		atts[i].VRF = "vrf-a"
	}
	return &fabricv1.Network{
		ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name},
		Spec: fabricv1.NetworkSpec{
			Routers:     []fabricv1.NetworkRouter{{Name: "vrf-a", L3VNI: fabricv1.VNI(l3vni)}},
			Attachments: atts,
		},
	}
}

// whACL is an accessLists-only (standalone) object.
func whACL(ns, name, stage, typ string, atts ...fabricv1.NetworkAttachment) *fabricv1.Network {
	return &fabricv1.Network{
		ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name},
		Spec: fabricv1.NetworkSpec{
			AccessLists: []fabricv1.AccessList{{Name: "filter-a", Stage: stage, Type: typ,
				Rules: []fabricv1.ACLRule{{Name: "r1", Priority: 10, Action: "permit"}}}},
			Attachments: atts,
		},
	}
}

func (h *whHarness) create(t *testing.T, n *fabricv1.Network, finalizers ...string) *fabricv1.Network {
	t.Helper()
	n.Finalizers = append(n.Finalizers, finalizers...)
	if err := h.c.Create(context.Background(), n); err != nil {
		t.Fatalf("creating Network %s/%s: %v", n.Namespace, n.Name, err)
	}
	return n
}

func (h *whHarness) get(t *testing.T, ns, name string) *fabricv1.Network {
	t.Helper()
	n := &fabricv1.Network{}
	if err := h.c.Get(context.Background(), client.ObjectKey{Namespace: ns, Name: name}, n); err != nil {
		t.Fatalf("reading Network %s/%s: %v", ns, name, err)
	}
	return n
}

// update re-reads the object, applies mutate and writes it.
func (h *whHarness) update(t *testing.T, ns, name string, mutate func(*fabricv1.Network)) error {
	n := h.get(t, ns, name)
	mutate(n)
	return h.c.Update(context.Background(), n)
}

// deleteHeld deletes a Network that carries a finalizer and returns it held.
func (h *whHarness) deleteHeld(t *testing.T, ns, name string) *fabricv1.Network {
	t.Helper()
	if err := h.c.Delete(context.Background(), h.get(t, ns, name)); err != nil {
		t.Fatalf("deleting Network %s/%s: %v", ns, name, err)
	}
	n := h.get(t, ns, name)
	if n.DeletionTimestamp == nil {
		t.Fatalf("Network %s/%s has no deletion timestamp after its delete", ns, name)
	}
	return n
}

// release removes every finalizer (admitted: the object is deleting) and waits for it to go.
func (h *whHarness) release(t *testing.T, ns, name string) {
	t.Helper()
	if err := h.update(t, ns, name, func(n *fabricv1.Network) { n.Finalizers = nil }); err != nil {
		t.Fatalf("removing the finalizer of %s/%s: %v", ns, name, err)
	}
	whEventually(t, "the released Network to be gone", func() error {
		err := h.c.Get(context.Background(), client.ObjectKey{Namespace: ns, Name: name}, &fabricv1.Network{})
		if apierrors.IsNotFound(err) {
			return nil
		}
		return fmt.Errorf("still present (%v)", err)
	})
}

func (h *whHarness) remove(t *testing.T, ns, name string) {
	t.Helper()
	n := &fabricv1.Network{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name}}
	if err := h.c.Delete(context.Background(), n); err != nil && !apierrors.IsNotFound(err) {
		t.Fatal(err)
	}
	whEventually(t, "the Network to be gone", func() error {
		err := h.c.Get(context.Background(), client.ObjectKey{Namespace: ns, Name: name}, &fabricv1.Network{})
		if apierrors.IsNotFound(err) {
			return nil
		}
		return fmt.Errorf("still present (%v)", err)
	})
}

// mutateFabric changes the Fabric and restores its spec when the (sub)test ends.
func (h *whHarness) mutateFabric(t *testing.T, mutate func(*fabricv1.FabricSpec)) {
	t.Helper()
	ctx := context.Background()
	f := &fabricv1.Fabric{}
	if err := h.c.Get(ctx, client.ObjectKey{Namespace: whNSSystem, Name: whFabricName}, f); err != nil {
		t.Fatal(err)
	}
	orig := f.Spec.DeepCopy()
	mutate(&f.Spec)
	if err := h.c.Update(ctx, f); err != nil {
		t.Fatalf("updating the Fabric: %v", err)
	}
	t.Cleanup(func() {
		g := &fabricv1.Fabric{}
		if err := h.c.Get(ctx, client.ObjectKey{Namespace: whNSSystem, Name: whFabricName}, g); err != nil {
			t.Errorf("restoring the Fabric: %v", err)
			return
		}
		g.Spec = *orig
		if err := h.c.Update(ctx, g); err != nil {
			t.Errorf("restoring the Fabric: %v", err)
		}
	})
}

// setUntagged declares a node's untagged access ports.
func (h *whHarness) setUntagged(t *testing.T, node string, ports ...fabricv1.PortName) {
	t.Helper()
	h.mutateFabric(t, func(s *fabricv1.FabricSpec) {
		for i := range s.Inventory {
			if string(s.Inventory[i].Node) == node {
				s.Inventory[i].UntaggedAccessPorts = ports
			}
		}
	})
}

// removeNode takes a node out of the Fabric: out of spec.nodes and out of the inventory.
func (h *whHarness) removeNode(t *testing.T, node string) {
	t.Helper()
	h.mutateFabric(t, func(s *fabricv1.FabricSpec) {
		var nodes []fabricv1.FabricNode
		for _, n := range s.Nodes {
			if string(n.Name) != node {
				nodes = append(nodes, n)
			}
		}
		var inv []fabricv1.InventoryEntry
		for _, e := range s.Inventory {
			if string(e.Node) != node {
				inv = append(inv, e)
			}
		}
		s.Nodes, s.Inventory = nodes, inv
	})
}

// setQualification sets one key of the qualification record and restores it afterwards.
func (h *whHarness) setQualification(t *testing.T, key, value string) {
	t.Helper()
	ctx := context.Background()
	cm := &corev1.ConfigMap{}
	k := client.ObjectKey{Namespace: webhook.QualificationNamespace, Name: webhook.QualificationName}
	if err := h.c.Get(ctx, k, cm); err != nil {
		t.Fatal(err)
	}
	prev, had := cm.Data[key]
	cm.Data[key] = value
	if err := h.c.Update(ctx, cm); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		g := &corev1.ConfigMap{}
		if err := h.c.Get(ctx, k, g); err != nil {
			t.Errorf("restoring the qualification record: %v", err)
			return
		}
		if had {
			g.Data[key] = prev
		} else {
			delete(g.Data, key)
		}
		if err := h.c.Update(ctx, g); err != nil {
			t.Errorf("restoring the qualification record: %v", err)
		}
	})
}

// whDenied asserts err is the webhook's refusal — not a CEL/schema one, not a failure to call
// it — carrying every want.
func whDenied(t *testing.T, err error, wants ...string) {
	t.Helper()
	if err == nil {
		t.Fatalf("admitted; want a refusal by the webhook containing %q", wants)
	}
	msg := err.Error()
	if !strings.Contains(msg, fmt.Sprintf("admission webhook %q denied the request", whWebhookName)) {
		t.Fatalf("not refused by the webhook: %v", err)
	}
	for _, w := range wants {
		if !strings.Contains(msg, w) {
			t.Errorf("refusal does not contain %q:\n%s", w, msg)
		}
	}
}

// whUnreachable asserts err is the API server refusing because the webhook could not be called.
func whUnreachable(t *testing.T, err error) {
	t.Helper()
	if err == nil {
		t.Fatal("admitted while the webhook is unreachable; want the API server to refuse (failurePolicy Fail)")
	}
	if !strings.Contains(err.Error(), fmt.Sprintf("failed calling webhook %q", whWebhookName)) {
		t.Fatalf("not a failure to call the webhook: %v", err)
	}
}

func whAdmitted(t *testing.T, err error, what string) {
	t.Helper()
	if err != nil {
		t.Fatalf("%s refused: %v", what, err)
	}
}

// ---------------------------------------------------------------------------------------------
// The shipped configuration (AD-52, AD-61)

// TestWebhookShippedConfiguration: the shipped registration states failurePolicy Fail on CREATE
// and UPDATE of `networks`, never DELETE, never `networks/status`, no matchConditions, no
// timeoutSeconds; its path is the handler's; and no mutating webhook ships beside it.
func TestWebhookShippedConfiguration(t *testing.T) {
	vwc := whShippedVWC(t)
	if len(vwc.Webhooks) != 1 {
		t.Fatalf("want one webhook, got %d", len(vwc.Webhooks))
	}
	w := vwc.Webhooks[0]
	if w.Name != whWebhookName {
		t.Errorf("webhook name %q, want %q", w.Name, whWebhookName)
	}
	if w.FailurePolicy == nil || *w.FailurePolicy != admissionregistrationv1.Fail {
		t.Errorf("failurePolicy %v, want Fail", w.FailurePolicy)
	}
	if w.TimeoutSeconds != nil {
		t.Errorf("timeoutSeconds is stated (%d); the API server's default applies", *w.TimeoutSeconds)
	}
	if len(w.MatchConditions) != 0 {
		t.Errorf("matchConditions are stated (%v); the AD-61 exemption is the handler's", w.MatchConditions)
	}
	if w.SideEffects == nil || *w.SideEffects != admissionregistrationv1.SideEffectClassNone {
		t.Errorf("sideEffects %v, want None", w.SideEffects)
	}
	if strings.Join(w.AdmissionReviewVersions, ",") != "v1" {
		t.Errorf("admissionReviewVersions %v, want [v1]", w.AdmissionReviewVersions)
	}
	if w.NamespaceSelector != nil || w.ObjectSelector != nil {
		t.Errorf("a selector narrows the registration: namespaceSelector %v objectSelector %v", w.NamespaceSelector, w.ObjectSelector)
	}
	if w.ClientConfig.Service == nil || w.ClientConfig.Service.Path == nil || *w.ClientConfig.Service.Path != webhook.Path {
		t.Errorf("clientConfig.service.path is not the handler's %s: %+v", webhook.Path, w.ClientConfig.Service)
	}
	if len(w.Rules) != 1 {
		t.Fatalf("want one rule, got %v", w.Rules)
	}
	r := w.Rules[0]
	ops := map[admissionregistrationv1.OperationType]bool{}
	for _, o := range r.Operations {
		ops[o] = true
	}
	if len(r.Operations) != 2 || !ops[admissionregistrationv1.Create] || !ops[admissionregistrationv1.Update] {
		t.Errorf("operations %v, want exactly CREATE and UPDATE", r.Operations)
	}
	if ops[admissionregistrationv1.Delete] || ops[admissionregistrationv1.OperationAll] {
		t.Errorf("operations %v list DELETE", r.Operations)
	}
	if strings.Join(r.Resources, ",") != "networks" {
		t.Errorf("resources %v, want exactly [networks] (never networks/status)", r.Resources)
	}
	if strings.Join(r.APIGroups, ",") != fabricv1.GroupVersion.Group || strings.Join(r.APIVersions, ",") != fabricv1.GroupVersion.Version {
		t.Errorf("rule names %v/%v, want %s", r.APIGroups, r.APIVersions, fabricv1.GroupVersion)
	}
	for _, d := range whShippedDocs(t) {
		if bytes.Contains(d, []byte("kind: MutatingWebhookConfiguration")) {
			t.Errorf("%s ships a MutatingWebhookConfiguration", whShippedPath)
		}
	}
	if vwc.Annotations["cert-manager.io/inject-ca-from"] == "" {
		t.Errorf("the configuration carries no cert-manager.io/inject-ca-from annotation")
	}
}

// ---------------------------------------------------------------------------------------------
// The cross-object rules (FR-034, FR-097, CR-003, AD-20, AD-68)

func TestWebhookCrossObjectRules(t *testing.T) {
	h := whStart(t)
	ctx := context.Background()

	t.Run("resolvability: never a spine, valid names listed", func(t *testing.T) {
		err := h.c.Create(ctx, whVLANNet(whNSIntent, "on-spine", 100, whTag("spine01", "ethernet-1/1", 100)))
		whDenied(t, err, "AttachmentUnresolved", "spine01 ethernet-1/1", "never on a spine", whTaggedPorts)
	})
	t.Run("resolvability: unknown node, valid names listed", func(t *testing.T) {
		err := h.c.Create(ctx, whVLANNet(whNSIntent, "on-leaf09", 100, whTag("leaf09", "ethernet-1/1", 100)))
		whDenied(t, err, "AttachmentUnresolved", "leaf09", whTaggedPorts)
	})
	t.Run("resolvability: a fabric port is not an access port", func(t *testing.T) {
		err := h.c.Create(ctx, whVLANNet(whNSIntent, "on-fabric-port", 100, whTag("leaf01", "ethernet-1/49", 100)))
		whDenied(t, err, "AttachmentUnresolved", "ethernet-1/49", "not an access port of leaf01", whTaggedPorts)
	})

	t.Run("declared mode: untagged on a port not in untaggedAccessPorts", func(t *testing.T) {
		err := h.c.Create(ctx, whIPVRF(whNSIntent, "untagged-on-tagged", 5001, whUntag("leaf01", "ethernet-1/1")))
		whDenied(t, err, "AttachmentUnresolved", "untagged attachment leaf01 ethernet-1/1", "untaggedAccessPorts", whUntaggedPorts)
		if strings.Contains(err.Error(), whTaggedPorts) {
			t.Errorf("an untagged request lists the tagged ports: %v", err)
		}
	})
	t.Run("declared mode: tagged on a port in untaggedAccessPorts", func(t *testing.T) {
		err := h.c.Create(ctx, whVLANNet(whNSIntent, "tagged-on-untagged", 100, whTag("leaf01", "ethernet-1/3", 100)))
		whDenied(t, err, "AttachmentUnresolved", "tagged attachment leaf01 ethernet-1/3", "untaggedAccessPorts", whTaggedPorts)
		if strings.Contains(err.Error(), whUntaggedPorts) {
			t.Errorf("a tagged request lists the untagged ports: %v", err)
		}
	})
	t.Run("declared mode: each mode admitted where declared", func(t *testing.T) {
		h.create(t, whIPVRF(whNSIntent, "untagged-ok", 5002, whUntag("leaf01", "ethernet-1/3")))
		h.create(t, whVLANNet(whNSIntent, "tagged-ok", 101, whTag("leaf01", "ethernet-1/1", 101)))
		t.Cleanup(func() { h.remove(t, whNSIntent, "untagged-ok"); h.remove(t, whNSIntent, "tagged-ok") })
	})

	t.Run("one owner per (node, port, vlan), holder named, across namespaces", func(t *testing.T) {
		h.create(t, whVLANNet(whNSServices, "holder", 110, whTag("leaf02", "ethernet-1/1", 110)))
		t.Cleanup(func() { h.remove(t, whNSServices, "holder") })
		err := h.c.Create(ctx, whVLANNet(whNSIntent, "second", 110, whTag("leaf02", "ethernet-1/1", 110), whTag("leaf03", "ethernet-1/1", 110)))
		whDenied(t, err, "SubinterfaceOwned", "leaf02 ethernet-1/1.110", "agentic-netops-services/holder")
		// Another VLAN on the same port is another subinterface, and no VLAN value is arbitrated
		// here: the same named VLAN elsewhere is admitted.
		h.create(t, whVLANNet(whNSIntent, "other-vlan", 111, whTag("leaf02", "ethernet-1/1", 111)))
		h.create(t, whVLANNet(whNSIntent, "same-vlan-elsewhere", 110, whTag("leaf03", "ethernet-1/1", 110)))
		t.Cleanup(func() { h.remove(t, whNSIntent, "other-vlan"); h.remove(t, whNSIntent, "same-vlan-elsewhere") })
	})

	// One tagging mode per port across objects. With the mode declared on the port (AD-68) this
	// rule is the backstop across a change of the declaration, so each direction changes it
	// between the holder's admission and the candidate's.
	t.Run("one tagging mode: tagged added to a port carrying another's untagged", func(t *testing.T) {
		h.create(t, whIPVRF(whNSServices, "untagged-holder", 5003, whUntag("leaf02", "ethernet-1/2")))
		t.Cleanup(func() { h.remove(t, whNSServices, "untagged-holder") })
		h.setUntagged(t, "leaf02") // ethernet-1/2 now declared tagged
		err := h.c.Create(ctx, whVLANNet(whNSIntent, "tagged-candidate", 120, whTag("leaf02", "ethernet-1/2", 120)))
		whDenied(t, err, "TaggingModeConflict", "port leaf02 ethernet-1/2", "agentic-netops-intent/tagged-candidate", "agentic-netops-services/untagged-holder")
		if strings.Contains(err.Error(), "AttachmentUnresolved") {
			t.Errorf("the candidate matches the declaration; only the mode rule may refuse it: %v", err)
		}
	})
	t.Run("one tagging mode: untagged added to a port carrying another's tagged", func(t *testing.T) {
		h.create(t, whVLANNet(whNSServices, "tagged-holder", 121, whTag("leaf03", "ethernet-1/1", 121)))
		t.Cleanup(func() { h.remove(t, whNSServices, "tagged-holder") })
		h.setUntagged(t, "leaf03", "ethernet-1/1") // ethernet-1/1 now declared untagged
		err := h.c.Create(ctx, whIPVRF(whNSIntent, "untagged-candidate", 5004, whUntag("leaf03", "ethernet-1/1")))
		whDenied(t, err, "TaggingModeConflict", "port leaf03 ethernet-1/1", "agentic-netops-intent/untagged-candidate", "agentic-netops-services/tagged-holder")
		if strings.Contains(err.Error(), "AttachmentUnresolved") {
			t.Errorf("the candidate matches the declaration; only the mode rule may refuse it: %v", err)
		}
	})
	t.Run("one tagging mode: a holder with a deletion timestamp still holds its mode", func(t *testing.T) {
		h.create(t, whIPVRF(whNSServices, "deleting-holder", 5005, whUntag("leaf01", "ethernet-1/3")), whFinalizer)
		t.Cleanup(func() { h.release(t, whNSServices, "deleting-holder") })
		h.deleteHeld(t, whNSServices, "deleting-holder")
		h.setUntagged(t, "leaf01") // ethernet-1/3 now declared tagged
		err := h.c.Create(ctx, whVLANNet(whNSIntent, "after-deleting", 122, whTag("leaf01", "ethernet-1/3", 122)))
		whDenied(t, err, "TaggingModeConflict", "port leaf01 ethernet-1/3", "agentic-netops-services/deleting-holder", "being deleted and still holds")
	})
	t.Run("one tagging mode: a standalone access list is not a second mode or owner", func(t *testing.T) {
		h.create(t, whIPVRF(whNSServices, "acl-owner", 5006, whUntag("leaf02", "ethernet-1/2")))
		// The standalone list binds on the owner's untagged subinterface: admitted, the
		// subinterface existing.
		h.create(t, whACL(whNSIntent, "standalone", "ingress", "ipv4", whUntag("leaf02", "ethernet-1/2")))
		t.Cleanup(func() { h.remove(t, whNSIntent, "standalone") })
		// The owner's own spec-changing update is evaluated and does not see the list as a
		// second owner of leaf02 ethernet-1/2.0.
		whAdmitted(t, h.update(t, whNSServices, "acl-owner", func(n *fabricv1.Network) {
			n.Spec.Description = "owner, changed"
		}), "the owner's spec change beside a standalone list")
		// With the owner gone and the port declared tagged, the list's untagged attachment is no
		// mode: a tagged attachment on the port is admitted.
		h.remove(t, whNSServices, "acl-owner")
		h.setUntagged(t, "leaf02")
		h.create(t, whVLANNet(whNSIntent, "tagged-beside-list", 123, whTag("leaf02", "ethernet-1/2", 123)))
		t.Cleanup(func() { h.remove(t, whNSIntent, "tagged-beside-list") })
	})

	t.Run("standalone access list: needs its subinterface; bindings are exclusive", func(t *testing.T) {
		h.create(t, whVLANNet(whNSServices, "filtered", 130, whTag("leaf01", "ethernet-1/2", 130)))
		t.Cleanup(func() { h.remove(t, whNSServices, "filtered") })
		err := h.c.Create(ctx, whACL(whNSIntent, "no-subif", "ingress", "ipv4", whTag("leaf01", "ethernet-1/2", 131)))
		whDenied(t, err, "SubinterfaceMissing", "leaf01 ethernet-1/2.131")
		h.create(t, whACL(whNSIntent, "list-a", "ingress", "ipv4", whTag("leaf01", "ethernet-1/2", 130)), whFinalizer)
		err = h.c.Create(ctx, whACL(whNSIntent, "list-b", "ingress", "ipv4", whTag("leaf01", "ethernet-1/2", 130)))
		whDenied(t, err, "BindingConflict", "leaf01 ethernet-1/2.130", "agentic-netops-intent/list-a")
		h.create(t, whACL(whNSIntent, "list-v6", "ingress", "ipv6", whTag("leaf01", "ethernet-1/2", 130)))
		t.Cleanup(func() { h.remove(t, whNSIntent, "list-v6") })
		h.deleteHeld(t, whNSIntent, "list-a")
		err = h.c.Create(ctx, whACL(whNSIntent, "list-c", "ingress", "ipv4", whTag("leaf01", "ethernet-1/2", 130)))
		whDenied(t, err, "BindingConflict", "agentic-netops-intent/list-a", "being deleted and still holds its bindings")
		h.release(t, whNSIntent, "list-a")
	})

	t.Run("Unqualified: a construct absent from the qualification record", func(t *testing.T) {
		h.setQualification(t, "ip-vrf", "unqualified")
		err := h.c.Create(ctx, whIPVRF(whNSIntent, "ipvrf-unqualified", 5007, whUntag("leaf01", "ethernet-1/3")))
		whDenied(t, err, "Unqualified", "ip-vrf", webhook.QualificationNamespace+"/"+webhook.QualificationName)
	})
	t.Run("Unqualified: a gated property absent from the qualification record", func(t *testing.T) {
		h.create(t, whVLANNet(whNSServices, "egress-target", 140, whTag("leaf03", "ethernet-1/1", 140)))
		t.Cleanup(func() { h.remove(t, whNSServices, "egress-target") })
		h.setQualification(t, "acl.egress", "unqualified")
		err := h.c.Create(ctx, whACL(whNSIntent, "egress-list", "egress", "ipv4", whTag("leaf03", "ethernet-1/1", 140)))
		whDenied(t, err, "Unqualified", "acl.egress")
		// The same list at ingress is qualified.
		h.create(t, whACL(whNSIntent, "ingress-list", "ingress", "ipv4", whTag("leaf03", "ethernet-1/1", 140)))
		t.Cleanup(func() { h.remove(t, whNSIntent, "ingress-list") })
		// A gated property the record does not state at all is unqualified too.
		h.mutateQualificationDelete(t, "mac-vrf.anycast-gateway-ipv6")
		gw := &fabricv1.Network{
			ObjectMeta: metav1.ObjectMeta{Namespace: whNSIntent, Name: "gw-v6"},
			Spec: fabricv1.NetworkSpec{
				BridgeDomains: []fabricv1.BridgeDomain{{Name: "bd-a", VLAN: 141, L2VNI: 10141,
					IRB: &fabricv1.IRBSpec{VRF: "vrf-a", GatewayIPv6: "2001:db8:141::1/64"}}},
				Routers:     []fabricv1.NetworkRouter{{Name: "vrf-a", L3VNI: 20141}},
				Attachments: []fabricv1.NetworkAttachment{whTag("leaf01", "ethernet-1/1", 141)},
			},
		}
		whDenied(t, h.c.Create(ctx, gw), "Unqualified", "mac-vrf.anycast-gateway-ipv6")
	})

	t.Run("topology changed before submission: server-side dry-run refused, nothing submitted", func(t *testing.T) {
		proposed := whVLANNet(whNSIntent, "proposed", 150, whTag("leaf03", "ethernet-1/1", 150))
		whAdmitted(t, h.c.Create(ctx, proposed.DeepCopy(), client.DryRunAll), "the dry-run of the proposal")
		h.removeNode(t, "leaf03")
		err := h.c.Create(ctx, proposed.DeepCopy(), client.DryRunAll)
		whDenied(t, err, "AttachmentUnresolved", "leaf03 ethernet-1/1",
			"leaf01 [ethernet-1/1, ethernet-1/2], leaf02 [ethernet-1/1]")
		if strings.Contains(err.Error(), "leaf03 [") {
			t.Errorf("the refusal lists the removed node as valid: %v", err)
		}
		if gerr := h.c.Get(ctx, client.ObjectKeyFromObject(proposed), &fabricv1.Network{}); !apierrors.IsNotFound(gerr) {
			t.Errorf("the refused proposal exists: %v", gerr)
		}
	})
}

// mutateQualificationDelete removes one key of the record (absent is unqualified) and restores it.
func (h *whHarness) mutateQualificationDelete(t *testing.T, key string) {
	t.Helper()
	ctx := context.Background()
	k := client.ObjectKey{Namespace: webhook.QualificationNamespace, Name: webhook.QualificationName}
	cm := &corev1.ConfigMap{}
	if err := h.c.Get(ctx, k, cm); err != nil {
		t.Fatal(err)
	}
	prev, had := cm.Data[key]
	delete(cm.Data, key)
	if err := h.c.Update(ctx, cm); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if !had {
			return
		}
		g := &corev1.ConfigMap{}
		if err := h.c.Get(ctx, k, g); err != nil {
			t.Errorf("restoring the qualification record: %v", err)
			return
		}
		g.Data[key] = prev
		if err := h.c.Update(ctx, g); err != nil {
			t.Errorf("restoring the qualification record: %v", err)
		}
	})
}

// ---------------------------------------------------------------------------------------------
// Fails closed (AD-52)

// TestWebhookFailsClosed: with the webhook's endpoint unreachable — the provider down — a
// Network create, a spec update and a metadata-only update are each refused by the API server,
// while a delete of an existing Network is accepted and blocks on its finalizer.
func TestWebhookFailsClosed(t *testing.T) {
	h := whStart(t)
	ctx := context.Background()
	h.create(t, whVLANNet(whNSIntent, "existing", 200, whTag("leaf01", "ethernet-1/1", 200)), whFinalizer)

	h.stopServer(t)

	err := h.c.Create(ctx, whVLANNet(whNSIntent, "created-while-down", 201, whTag("leaf01", "ethernet-1/2", 201)))
	whUnreachable(t, err)
	if gerr := h.c.Get(ctx, client.ObjectKey{Namespace: whNSIntent, Name: "created-while-down"}, &fabricv1.Network{}); !apierrors.IsNotFound(gerr) {
		t.Errorf("a Network was created while the webhook was unreachable: %v", gerr)
	}
	whUnreachable(t, h.update(t, whNSIntent, "existing", func(n *fabricv1.Network) {
		n.Spec.Attachments = append(n.Spec.Attachments, whTag("leaf02", "ethernet-1/1", 200))
	}))
	// The AD-61 exemption lives behind the call: a metadata-only UPDATE is refused like any other.
	whUnreachable(t, h.update(t, whNSIntent, "existing", func(n *fabricv1.Network) {
		n.Labels = map[string]string{"example": "metadata-only"}
	}))
	if got := h.get(t, whNSIntent, "existing"); len(got.Spec.Attachments) != 1 || got.Labels["example"] != "" {
		t.Errorf("an update was persisted while the webhook was unreachable: %+v", got)
	}

	// DELETE is not registered: accepted, and the finalizer holds the object.
	whAdmitted(t, h.c.Delete(ctx, h.get(t, whNSIntent, "existing")), "the delete while the webhook is unreachable")
	held := h.get(t, whNSIntent, "existing")
	if held.DeletionTimestamp == nil || len(held.Finalizers) != 1 || held.Finalizers[0] != whFinalizer {
		t.Fatalf("the deleted Network is not held by its finalizer: deletionTimestamp %v finalizers %v", held.DeletionTimestamp, held.Finalizers)
	}
	// Still no update while down — the finalizer's removal included.
	whUnreachable(t, h.update(t, whNSIntent, "existing", func(n *fabricv1.Network) { n.Finalizers = nil }))

	// The provider back: the finalizer's removal is admitted and the object goes.
	h.startServer(t)
	h.waitReachable(t)
	h.release(t, whNSIntent, "existing")
}

// ---------------------------------------------------------------------------------------------
// What the webhook does not evaluate (AD-61)

func TestWebhookUnevaluatedUpdates(t *testing.T) {
	h := whStart(t)
	ctx := context.Background()

	t.Run("deleting Network whose node left the Fabric: force-release and finalizer removal admitted", func(t *testing.T) {
		h.create(t, whVLANNet(whNSIntent, "stranded", 300, whTag("leaf03", "ethernet-1/1", 300)), whFinalizer)
		h.deleteHeld(t, whNSIntent, "stranded")
		h.removeNode(t, "leaf03")
		// A spec-changing create on the removed node is refused: the rules do run on it.
		whDenied(t, h.c.Create(ctx, whVLANNet(whNSIntent, "probe-leaf03", 301, whTag("leaf03", "ethernet-1/1", 301))), "AttachmentUnresolved", "leaf03")
		whAdmitted(t, h.update(t, whNSIntent, "stranded", func(n *fabricv1.Network) {
			if n.Annotations == nil {
				n.Annotations = map[string]string{}
			}
			n.Annotations[whForceRelease] = "leaf03 decommissioned; ticket 42"
		}), "the force-release annotation on a deleting Network whose node left the Fabric")
		if got := h.get(t, whNSIntent, "stranded"); got.Annotations[whForceRelease] == "" {
			t.Fatalf("the force-release annotation was not persisted")
		}
		// Rule 8 step 7: the provider removes its finalizer.
		h.release(t, whNSIntent, "stranded")
	})

	t.Run("live Network whose attachment no longer resolves: label and annotation admitted, spec change evaluated", func(t *testing.T) {
		h.create(t, whVLANNet(whNSServices, "unresolved", 310, whTag("leaf03", "ethernet-1/1", 310)), whFinalizer)
		t.Cleanup(func() { h.deleteHeld(t, whNSServices, "unresolved"); h.release(t, whNSServices, "unresolved") })
		h.removeNode(t, "leaf03")
		whAdmitted(t, h.update(t, whNSServices, "unresolved", func(n *fabricv1.Network) {
			n.Labels = map[string]string{"tier": "gold"}
		}), "a label change on a live Network whose attachment no longer resolves")
		whAdmitted(t, h.update(t, whNSServices, "unresolved", func(n *fabricv1.Network) {
			n.Annotations = map[string]string{"note": "leaf03 is gone"}
		}), "an annotation change on a live Network whose attachment no longer resolves")
		whDenied(t, h.update(t, whNSServices, "unresolved", func(n *fabricv1.Network) {
			n.Spec.Description = "restated"
		}), "AttachmentUnresolved", "leaf03 ethernet-1/1")
	})

	t.Run("live Network whose construct is no longer qualified: label and annotation admitted, spec change evaluated", func(t *testing.T) {
		h.create(t, whIPVRF(whNSServices, "no-longer-qualified", 5100, whUntag("leaf02", "ethernet-1/2")), whFinalizer)
		t.Cleanup(func() {
			h.deleteHeld(t, whNSServices, "no-longer-qualified")
			h.release(t, whNSServices, "no-longer-qualified")
		})
		h.setQualification(t, "ip-vrf", "unqualified")
		whAdmitted(t, h.update(t, whNSServices, "no-longer-qualified", func(n *fabricv1.Network) {
			n.Labels = map[string]string{"tier": "silver"}
		}), "a label change on a live Network whose construct is no longer qualified")
		whAdmitted(t, h.update(t, whNSServices, "no-longer-qualified", func(n *fabricv1.Network) {
			n.Annotations = map[string]string{"note": "requalify"}
		}), "an annotation change on a live Network whose construct is no longer qualified")
		whDenied(t, h.update(t, whNSServices, "no-longer-qualified", func(n *fabricv1.Network) {
			n.Spec.Routers[0].Prefixes = []fabricv1.IPPrefix{"10.51.0.0/24"}
		}), "Unqualified", "ip-vrf")
	})

	t.Run("spec-changing UPDATE on a live object is evaluated: attachment moved onto another's subinterface", func(t *testing.T) {
		h.create(t, whVLANNet(whNSServices, "owner", 320, whTag("leaf01", "ethernet-1/1", 320)))
		h.create(t, whVLANNet(whNSIntent, "mover", 320, whTag("leaf01", "ethernet-1/2", 320)))
		t.Cleanup(func() { h.remove(t, whNSServices, "owner"); h.remove(t, whNSIntent, "mover") })
		whDenied(t, h.update(t, whNSIntent, "mover", func(n *fabricv1.Network) {
			n.Spec.Attachments[0].Attachment = "ethernet-1/1"
		}), "SubinterfaceOwned", "leaf01 ethernet-1/1.320", "agentic-netops-services/owner")
		// A deleting object still holds its bindings against the others: the owner deleting,
		// the move is still refused naming it.
		whAdmitted(t, h.update(t, whNSServices, "owner", func(n *fabricv1.Network) {
			n.Finalizers = []string{whFinalizer}
		}), "adding the finalizer (a metadata-only UPDATE)")
		h.deleteHeld(t, whNSServices, "owner")
		whDenied(t, h.update(t, whNSIntent, "mover", func(n *fabricv1.Network) {
			n.Spec.Attachments[0].Attachment = "ethernet-1/1"
		}), "SubinterfaceOwned", "agentic-netops-services/owner", "being deleted")
		h.release(t, whNSServices, "owner")
	})
}
