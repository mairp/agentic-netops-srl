//go:build envtest

// T106: the access-list lifecycle (contracts/acl-render-contract.md §1, §5, §6;
// contracts/network-spec.md §5 rules 7–9; FR-035, FR-036, FR-037, FR-043; AD-47, AD-68).
//
// Two halves, each decided by the layer that holds the rule:
//
//   - Admission (TestACLLifecycleAdmission): a real API server with the shipped
//     ValidatingWebhookConfiguration calling internal/webhook's handler (the webhook suite's
//     whStart harness, its own control plane). Binding exclusivity on (node, port, subinterface,
//     direction, family) names the holder, a holder with a deletion timestamp still holds and the
//     refusal says it is being removed; IPv4+IPv6 on one subinterface and two lists on different
//     subinterfaces of one port do not conflict; a standalone list needs a subinterface another
//     service created — the untagged `.0` bound when another service's untagged attachment
//     created it and refused naming `<port>.0` when none did — and a standalone list naming
//     another service's allocated VLAN 1500 is admitted.
//   - Reconciliation (TestACLLifecycle*): the package's shared harness (suite_test.go) with the
//     provider's OWN renderer (internal/render/srl, as cmd/srl-provider wires it) in place of the
//     suite's fake, so every Config value asserted is the one the device would receive. A service's
//     list rides in that service's own priority-20 Config per node — one transaction with the
//     subinterface it protects; a standalone list is its own priority-20 Config that writes only
//     its filter and its key-only binding entry, never an interface, a subinterface or an
//     interface-ref; its VLAN-1500 reference claims and looks up nothing, while the same VLAN on a
//     `vlan` object with no adoptable claim is AllocationConflict; withdrawal removes the binding
//     with (never after) its filter — every Config value the reconciler applies is checked — and a
//     service whose subinterface carries another object's list waits Deleting=True/HolderPresent
//     naming it, the holder's Config removed before the owner's (the delObservingClient approach
//     of deletion_test.go).
package network_test

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"

	configv1alpha1 "github.com/sdcio/config-server/apis/config/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/controllers/network"
	"github.com/mairp/agentic-netops-srl/internal/model"
	"github.com/mairp/agentic-netops-srl/internal/render/srl"
	"github.com/mairp/agentic-netops-srl/pkg/kuid"
	"github.com/mairp/agentic-netops-srl/pkg/sdc"
)

// ---------------------------------------------------------------------------------------------
// Admission

func TestACLLifecycleAdmission(t *testing.T) {
	h := whStart(t)
	ctx := context.Background()

	t.Run("binding exclusivity names the holder; a family or a subinterface apart does not conflict", func(t *testing.T) {
		h.create(t, whVLANNet(whNSServices, "acl-owner-400", 400, whTag("leaf01", "ethernet-1/1", 400)))
		h.create(t, whVLANNet(whNSServices, "acl-owner-401", 401, whTag("leaf01", "ethernet-1/1", 401)))
		t.Cleanup(func() { h.remove(t, whNSServices, "acl-owner-400"); h.remove(t, whNSServices, "acl-owner-401") })
		h.create(t, whACL(whNSIntent, "acl-list-a", "ingress", "ipv4", whTag("leaf01", "ethernet-1/1", 400)), whFinalizer)
		t.Cleanup(func() { h.release(t, whNSIntent, "acl-list-a") })

		err := h.c.Create(ctx, whACL(whNSIntent, "acl-list-b", "ingress", "ipv4", whTag("leaf01", "ethernet-1/1", 400)))
		whDenied(t, err, "BindingConflict", "leaf01 ethernet-1/1.400", "ingress ipv4", "Network agentic-netops-intent/acl-list-a")

		// IPv6 on the same subinterface and direction, IPv4 at the other direction, IPv4 on
		// another subinterface of the same port: none shares the unit.
		h.create(t, whACL(whNSIntent, "acl-list-v6", "ingress", "ipv6", whTag("leaf01", "ethernet-1/1", 400)))
		h.create(t, whACL(whNSIntent, "acl-list-egress", "egress", "ipv4", whTag("leaf01", "ethernet-1/1", 400)))
		h.create(t, whACL(whNSIntent, "acl-list-401", "ingress", "ipv4", whTag("leaf01", "ethernet-1/1", 401)))
		t.Cleanup(func() {
			h.remove(t, whNSIntent, "acl-list-v6")
			h.remove(t, whNSIntent, "acl-list-egress")
			h.remove(t, whNSIntent, "acl-list-401")
		})

		// A service's own list holds the unit too, and is named.
		own := whVLANNet(whNSServices, "acl-own-list-402", 402, whTag("leaf02", "ethernet-1/1", 402))
		own.Spec.AccessLists = whACL("", "", "ingress", "ipv4").Spec.AccessLists
		h.create(t, own)
		t.Cleanup(func() { h.remove(t, whNSServices, "acl-own-list-402") })
		err = h.c.Create(ctx, whACL(whNSIntent, "acl-list-on-402", "ingress", "ipv4", whTag("leaf02", "ethernet-1/1", 402)))
		whDenied(t, err, "BindingConflict", "leaf02 ethernet-1/1.402", "Network agentic-netops-services/acl-own-list-402")

		// A holder with a deletion timestamp still holds, and the refusal says it is being removed.
		h.deleteHeld(t, whNSIntent, "acl-list-a")
		err = h.c.Create(ctx, whACL(whNSIntent, "acl-list-c", "ingress", "ipv4", whTag("leaf01", "ethernet-1/1", 400)))
		whDenied(t, err, "BindingConflict", "Network agentic-netops-intent/acl-list-a", "being removed", "still holds its bindings")
	})

	t.Run("a standalone list needs an existing subinterface and never creates one: the untagged .0", func(t *testing.T) {
		// leaf01 ethernet-1/3 is declared untagged; no Network has an attachment on it.
		err := h.c.Create(ctx, whACL(whNSIntent, "acl-untagged-early", "ingress", "ipv4", whUntag("leaf01", "ethernet-1/3")))
		whDenied(t, err, "SubinterfaceMissing", "leaf01 ethernet-1/3.0", "never creates one")
		if strings.Contains(err.Error(), "AttachmentUnresolved") {
			t.Errorf("the attachment resolves (the port is declared untagged); only the missing subinterface may refuse it: %v", err)
		}
		// Another service's untagged attachment creates ethernet-1/3.0: the list binds.
		h.create(t, whIPVRF(whNSServices, "acl-untagged-owner", 5400, whUntag("leaf01", "ethernet-1/3")))
		t.Cleanup(func() { h.remove(t, whNSServices, "acl-untagged-owner") })
		h.create(t, whACL(whNSIntent, "acl-untagged", "ingress", "ipv4", whUntag("leaf01", "ethernet-1/3")))
		t.Cleanup(func() { h.remove(t, whNSIntent, "acl-untagged") })
		// A tagged subinterface nobody created on a tagged port: refused naming it.
		err = h.c.Create(ctx, whACL(whNSIntent, "acl-no-subif", "ingress", "ipv4", whTag("leaf02", "ethernet-1/1", 409)))
		whDenied(t, err, "SubinterfaceMissing", "leaf02 ethernet-1/1.409")
	})

	t.Run("an owner may not remove the subinterface a standalone list is bound to", func(t *testing.T) {
		h.create(t, whVLANNet(whNSServices, "acl-owner-410", 410, whTag("leaf01", "ethernet-1/2", 410), whTag("leaf03", "ethernet-1/1", 410)))
		t.Cleanup(func() { h.remove(t, whNSServices, "acl-owner-410") })
		h.create(t, whACL(whNSIntent, "acl-list-410", "ingress", "ipv4", whTag("leaf01", "ethernet-1/2", 410)))
		whDenied(t, h.update(t, whNSServices, "acl-owner-410", func(n *fabricv1.Network) {
			n.Spec.Attachments = n.Spec.Attachments[1:]
		}), "SubinterfaceMissing", "leaf01 ethernet-1/2.410", "Network agentic-netops-intent/acl-list-410", "withdraw that list first")
		// The attachment no list binds to is removable; once the list is gone, so is the other.
		whAdmitted(t, h.update(t, whNSServices, "acl-owner-410", func(n *fabricv1.Network) {
			n.Spec.Attachments = n.Spec.Attachments[:1]
		}), "removing the attachment no list binds to")
		h.remove(t, whNSIntent, "acl-list-410")
		whAdmitted(t, h.update(t, whNSServices, "acl-owner-410", func(n *fabricv1.Network) {
			n.Spec.Attachments = []fabricv1.NetworkAttachment{whTag("leaf03", "ethernet-1/1", 410)}
		}), "removing the attachment once the list is withdrawn")
	})

	t.Run("a standalone list naming another service's allocated VLAN 1500 is admitted", func(t *testing.T) {
		owner := &fabricv1.Network{
			ObjectMeta: metav1.ObjectMeta{Namespace: whNSIntent, Name: "migr-acl-owner-1500"},
			Spec: fabricv1.NetworkSpec{
				BridgeDomains: []fabricv1.BridgeDomain{{Name: "bd-acl-owner-1500", VLAN: 1500, L2VNI: 10500}},
				Attachments:   []fabricv1.NetworkAttachment{whTag("leaf02", "ethernet-1/1", 1500), whTag("leaf03", "ethernet-1/1", 1500)},
			},
		}
		h.create(t, owner)
		t.Cleanup(func() { h.remove(t, whNSIntent, "migr-acl-owner-1500") })
		h.create(t, whACL(whNSIntent, "migr-acl-ref-1500", "ingress", "ipv4", whTag("leaf02", "ethernet-1/1", 1500)))
		t.Cleanup(func() { h.remove(t, whNSIntent, "migr-acl-ref-1500") })
	})
}

// ---------------------------------------------------------------------------------------------
// Reconciliation, with the provider's own renderer

// aclRealRenderer is cmd/srl-provider's adapter over internal/render/srl.RenderService.
type aclRealRenderer struct{}

func (aclRealRenderer) RenderService(m *model.ServiceModel) (map[string]network.Rendered, error) {
	docs, err := srl.RenderService(m)
	if err != nil {
		return nil, err
	}
	out := make(map[string]network.Rendered, len(docs))
	for node, d := range docs {
		out[node] = network.Rendered{Node: d.Node, JSON: d.JSON, Hash: d.Hash}
	}
	return out, nil
}

// aclHarness is newHarness with the provider's own renderer.
func aclHarness(t *testing.T, ns, name string) *harness {
	h := newHarness(t, ns, name)
	h.r.Renderer = aclRealRenderer{}
	return h
}

// aclListSpec is one ipv4 ingress list with a default action.
func aclList(stage, fam, prefix string) []fabricv1.AccessList {
	return []fabricv1.AccessList{{Name: "web", Stage: stage, Type: fam, DefaultAction: "deny",
		Rules: []fabricv1.ACLRule{{Name: "allow-https", Priority: 100, Action: "permit", Protocol: "tcp",
			SourcePrefix: fabricv1.IPPrefix(prefix), DestinationPort: "443"}}}}
}

// aclView is what a native Config value holds under /acl, read generically: the filters it
// defines (name/type), the bindings it writes (interface-id, direction → filter name/type), the
// interface-refs it writes, and whether it writes any /interface or /network-instance.
type aclView struct {
	filters      map[string]bool
	bindings     map[string]bool // "<interface-id> <input|output> <name>/<type>"
	refs         map[string]bool // interface-ids carrying an interface-ref
	interfaces   bool
	instances    bool
	bindingNames []string // "<name>/<type>" of every binding, for the leafref check
}

func localName(k string) string {
	if i := strings.LastIndex(k, ":"); i >= 0 {
		return k[i+1:]
	}
	return k
}

func readACLView(t *testing.T, raw []byte) aclView {
	t.Helper()
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("Config value is not JSON: %v\n%s", err, raw)
	}
	v := aclView{filters: map[string]bool{}, bindings: map[string]bool{}, refs: map[string]bool{}}
	for k, val := range doc {
		switch localName(k) {
		case "interface":
			v.interfaces = true
		case "network-instance":
			v.instances = true
		case "acl":
			acl, _ := val.(map[string]any)
			for ak, av := range acl {
				switch localName(ak) {
				case "acl-filter":
					for _, f := range av.([]any) {
						m := f.(map[string]any)
						v.filters[m["name"].(string)+"/"+localName(m["type"].(string))] = true
					}
				case "interface":
					for _, e := range av.([]any) {
						m := e.(map[string]any)
						id := m["interface-id"].(string)
						for ek, ev := range m {
							switch localName(ek) {
							case "interface-ref":
								v.refs[id] = true
							case "input", "output":
								for _, b := range ev.(map[string]any)["acl-filter"].([]any) {
									bm := b.(map[string]any)
									nt := bm["name"].(string) + "/" + localName(bm["type"].(string))
									v.bindings[id+" "+localName(ek)+" "+nt] = true
									v.bindingNames = append(v.bindingNames, nt)
								}
							}
						}
					}
				}
			}
		}
	}
	return v
}

func configValue(t *testing.T, c *configv1alpha1.Config) []byte {
	t.Helper()
	if len(c.Spec.Config) != 1 {
		t.Fatalf("Config %s carries %d blobs, want 1", c.Name, len(c.Spec.Config))
	}
	return c.Spec.Config[0].Value.Raw
}

// aclApplyObserver records every Config value the reconciler applies and every Config it deletes,
// in order; each applied value is checked at once: no binding without its filter in the same
// value (the binding's name is a leafref — it never outlives the filter).
type aclApplyObserver struct {
	client.Client
	t       *testing.T
	mu      sync.Mutex
	applied map[string]int
	deleted []string
	values  map[string][]byte // the last value applied or stored before a delete, per Config
}

func newACLApplyObserver(t *testing.T) *aclApplyObserver {
	return &aclApplyObserver{Client: k8s, t: t, applied: map[string]int{}, values: map[string][]byte{}}
}

func (o *aclApplyObserver) Apply(ctx context.Context, obj k8sruntime.ApplyConfiguration, opts ...client.ApplyOption) error {
	b, err := json.Marshal(obj)
	if err == nil {
		var cfg configv1alpha1.Config
		if json.Unmarshal(b, &cfg) == nil && cfg.Kind == "Config" && len(cfg.Spec.Config) == 1 {
			raw := cfg.Spec.Config[0].Value.Raw
			v := readACLView(o.t, raw)
			for _, nt := range v.bindingNames {
				if !v.filters[nt] {
					o.t.Errorf("Config %s applied with a binding to %s but not that filter: the binding would outlive its filter", cfg.Name, nt)
				}
			}
			o.mu.Lock()
			o.applied[cfg.Name]++
			o.values[cfg.Name] = raw
			o.mu.Unlock()
		}
	}
	return o.Client.Apply(ctx, obj, opts...)
}

func (o *aclApplyObserver) Delete(ctx context.Context, obj client.Object, opts ...client.DeleteOption) error {
	if c, ok := obj.(*configv1alpha1.Config); ok {
		stored := &configv1alpha1.Config{}
		if err := k8s.Get(ctx, client.ObjectKeyFromObject(c), stored); err == nil && len(stored.Spec.Config) == 1 {
			o.mu.Lock()
			o.values[c.Name] = stored.Spec.Config[0].Value.Raw
			o.mu.Unlock()
		}
		o.mu.Lock()
		o.deleted = append(o.deleted, c.Name)
		o.mu.Unlock()
	}
	return o.Client.Delete(ctx, obj, opts...)
}

func (o *aclApplyObserver) reset() {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.applied, o.deleted = map[string]int{}, nil
}

// A service's own list is a field of that service's Network: the filter and its binding ride in
// the SAME priority-20 Config per node as the subinterface they protect — one transaction —
// bound to that node's own subinterfaces. Withdrawing the list is one write per node removing the
// binding and the filter together while the subinterface and its interface-ref stay; deleting the
// service removes binding, filter and subinterface in one Config delete per node.
func TestACLLifecycleServiceListSameTransaction(t *testing.T) {
	h := aclHarness(t, nsIntent, "migr-acl-svc461")
	spec := macvrfSpec(461, 10461, att("leaf01", "ethernet-1/1", 461), att("leaf02", "ethernet-1/1", 461))
	spec.AccessLists = aclList("ingress", "ipv4", "10.0.0.0/24")
	h.converge(spec)

	filter := "acl-acl-svc461-ingress/ipv4"
	cfgs := h.configs()
	if len(cfgs) != 2 {
		t.Fatalf("Configs %d, want one per node", len(cfgs))
	}
	for _, c := range cfgs {
		if c.Spec.Priority != sdc.PriorityService {
			t.Errorf("Config %s at priority %d, want the service band %d", c.Name, c.Spec.Priority, sdc.PriorityService)
		}
		v := readACLView(t, configValue(t, &c))
		if !v.interfaces || !v.instances || !v.filters[filter] || !v.bindings["ethernet-1/1.461 input "+filter] || !v.refs["ethernet-1/1.461"] {
			t.Errorf("Config %s does not carry the subinterface, the network-instance, the filter and its input binding together: %+v", c.Name, v)
		}
		if len(v.bindings) != 1 {
			t.Errorf("Config %s binds %v; the list binds this node's own subinterface only", c.Name, v.bindings)
		}
	}

	// Withdrawal of the list alone: one write per node, binding and filter leave together.
	obs := newACLApplyObserver(t)
	h.r.SDC = sdc.New(obs)
	h.update(func(n *fabricv1.Network) { n.Spec.AccessLists = nil })
	h.reconcile()
	for _, c := range h.configs() {
		if obs.applied[c.Name] != 1 {
			t.Errorf("Config %s written %d times for the withdrawal; binding and filter leave in one transaction", c.Name, obs.applied[c.Name])
		}
		v := readACLView(t, configValue(t, &c))
		if len(v.filters) != 0 || len(v.bindings) != 0 {
			t.Errorf("Config %s still carries %v / %v after the list was withdrawn", c.Name, v.filters, v.bindings)
		}
		if !v.interfaces || !v.refs["ethernet-1/1.461"] {
			t.Errorf("Config %s lost the subinterface or its interface-ref when only the list was withdrawn: %+v", c.Name, v)
		}
	}
	confirmConfigs(t, h.ns, h.name)
	h.reconcile()

	// The list back, then the service deleted: one Config delete per node, the value deleted
	// carrying binding, filter and subinterface — nothing of the list outlives the subinterface.
	h.update(func(n *fabricv1.Network) { n.Spec.AccessLists = aclList("ingress", "ipv4", "10.0.0.0/24") })
	h.reconcile()
	confirmConfigs(t, h.ns, h.name)
	h.reconcile()
	obs.reset()
	h.delete()
	for i := 0; i < 3 && !h.gone(); i++ {
		delStep(h)
	}
	if !h.gone() {
		t.Fatalf("not finalized: %+v", h.cond("Deleting"))
	}
	if len(obs.deleted) != 2 {
		t.Fatalf("Config deletes %v, want one per node", obs.deleted)
	}
	for _, name := range obs.deleted {
		v := readACLView(t, obs.values[name])
		if !v.filters[filter] || !v.bindings["ethernet-1/1.461 input "+filter] || !v.interfaces {
			t.Errorf("the deleted Config %s did not carry binding, filter and subinterface together: %+v", name, v)
		}
	}
}

// A standalone list binds to another service's subinterface and never creates one: its own
// priority-20 Config writes the filter and the key-only binding entry and nothing else — no
// interface, no subinterface, no interface-ref — for a tagged reference and for the untagged
// `.0`. Its VLAN 1500, the allocated VLAN of the owner's subinterface, is a reference: no
// AllocationConflict and no claim looked for; the same VLAN on a `vlan` object with no adoptable
// claim is still AllocationConflict (AD-47).
func TestACLLifecycleStandaloneBindsWithoutCreating(t *testing.T) {
	owner := aclHarness(t, nsIntent, "migr-acl-own1500")
	owner.claims.seed(kuid.KindVLAN, claimName(nsIntent, owner.name, "vlan-bd"), "1500", tierLabels("acl1500"))
	owner.claims.seed(kuid.KindGENID, claimName(nsIntent, owner.name, "l2vni-bd"), "10500", tierLabels("acl1500"))
	owner.converge(macvrfSpec(1500, 10500, att("leaf01", "ethernet-1/1", 1500), att("leaf02", "ethernet-1/1", 1500)), withCorrelation("acl1500"))

	list := aclHarness(t, nsIntent, "migr-acl-ref1500") // fresh fakes: its authority sees only this object
	list.converge(aclSpec(att("leaf01", "ethernet-1/1", 1500)))
	list.wantCond("Accepted", metav1.ConditionTrue, "")
	list.notCond("Accepted", "AllocationConflict")
	if n := list.claims.call("list") + list.claims.call("get") + list.claims.call("create") + list.claims.call("release"); n != 0 || list.claims.count() != 0 {
		t.Fatalf("a claim was looked for behind the reference VLAN 1500: calls %v, claims %d", list.claims.calls, list.claims.count())
	}
	if refs := list.network().Status.ClaimRefs; len(refs) != 0 {
		t.Fatalf("claimRefs %+v on a standalone list", refs)
	}
	cfgs := list.configs()
	if len(cfgs) != 1 || cfgs[0].Spec.Priority != sdc.PriorityService {
		t.Fatalf("Configs %+v, want one priority-20 Config for leaf01", cfgs)
	}
	filter := "acl-acl-ref1500-ingress/ipv4"
	v := readACLView(t, configValue(t, &cfgs[0]))
	if v.interfaces || v.instances || len(v.refs) != 0 {
		t.Errorf("the standalone list's Config writes an interface, a network-instance or an interface-ref: %+v", v)
	}
	if !v.filters[filter] || !v.bindings["ethernet-1/1.1500 input "+filter] || len(v.bindings) != 1 {
		t.Errorf("the standalone list's Config does not bind %s on ethernet-1/1.1500: %+v", filter, v)
	}

	// The same VLAN on a vlan object with no adoptable claim: AllocationConflict, nothing written.
	band := list.with(nsIntent, "migr-acl-vlan1500")
	band.create(vlanSpec(1500, att("leaf02", "ethernet-1/2", 1500)))
	band.reconcile()
	band.wantCond("Accepted", metav1.ConditionFalse, "AllocationConflict", "VLAN 1500", "100–999", "1000–4000")
	if len(band.configs()) != 0 {
		t.Fatal("an unbacked allocation-band VLAN rendered")
	}

	// The untagged `.0`: another service's untagged attachment created it; the list binds there
	// and creates nothing.
	routed := aclHarness(t, nsIntent, "migr-acl-own-untag")
	routed.converge(ipvrfSpec(10462, attUntagged("leaf01", "ethernet-1/2")))
	untagged := routed.with(nsIntent, "migr-acl-ref-untag")
	untagged.converge(aclSpec(attUntagged("leaf01", "ethernet-1/2")))
	cfgs = untagged.configs()
	if len(cfgs) != 1 {
		t.Fatalf("Configs %d", len(cfgs))
	}
	uf := "acl-acl-ref-untag-ingress/ipv4"
	v = readACLView(t, configValue(t, &cfgs[0]))
	if v.interfaces || v.instances || len(v.refs) != 0 || !v.bindings["ethernet-1/2.0 input "+uf] {
		t.Errorf("the untagged standalone list: %+v", v)
	}
	ov := readACLView(t, configValue(t, &routed.configs()[0]))
	if !ov.refs["ethernet-1/2.0"] || len(ov.bindings) != 0 {
		t.Errorf("the owner's Config must carry the interface-ref of ethernet-1/2.0 and no binding of the list: %+v", ov)
	}
}

// Dependency order across objects (contracts/acl-render-contract.md §5): a service whose
// attachment subinterface carries another object's standalone list removes nothing and waits
// Deleting=True/HolderPresent naming the holder; a holder being removed still holds and the
// condition says so; the holder's Config — binding and filter in one delete — goes first, and
// only then the owner's.
func TestACLLifecycleWithdrawalOrderAcrossObjects(t *testing.T) {
	owner := aclHarness(t, nsIntent, "migr-acl-own463")
	owner.converge(macvrfSpec(463, 10463, att("leaf02", "ethernet-1/2", 463)))
	list := owner.with(nsIntent, "migr-acl-hold463")
	list.converge(aclSpec(att("leaf02", "ethernet-1/2", 463)))
	ownerCfg := owner.configs()[0].Name
	listCfg := list.configs()[0].Name
	before := versionsOf(t, owner.ns, owner.name)

	obs := newACLApplyObserver(t)
	owner.r.SDC = sdc.New(obs) // owner and list share the reconciler

	owner.delete()
	delStep(owner)
	owner.wantCond("Deleting", metav1.ConditionTrue, "HolderPresent", "Network "+nsIntent+"/migr-acl-hold463", "leaf02 ethernet-1/2 vlan 463")
	sameVersions(t, "while the holder is present", before, versionsOf(t, owner.ns, owner.name))
	if len(obs.deleted) != 0 {
		t.Fatalf("Configs deleted while a binding still references the subinterface: %v", obs.deleted)
	}

	list.delete()
	delStep(owner)
	owner.wantCond("Deleting", metav1.ConditionTrue, "HolderPresent", "migr-acl-hold463", "being removed")
	if len(obs.deleted) != 0 {
		t.Fatalf("the owner's Config deleted while the deleting holder still holds: %v", obs.deleted)
	}

	delStep(list) // the binding and its filter first: the holder owns no subinterface
	if !list.gone() {
		t.Fatalf("the standalone list did not finalize: %+v", list.cond("Deleting"))
	}
	delStep(owner)
	if !owner.gone() {
		t.Fatalf("the owner did not finalize once the holder was gone: %+v", owner.cond("Deleting"))
	}
	if len(obs.deleted) != 2 || obs.deleted[0] != listCfg || obs.deleted[1] != ownerCfg {
		t.Fatalf("Config deletes %v, want the holder's %s before the owner's %s", obs.deleted, listCfg, ownerCfg)
	}
	lv := readACLView(t, obs.values[listCfg])
	if len(lv.bindings) != 1 || len(lv.filters) != 1 || lv.interfaces {
		t.Errorf("the holder's deleted Config: %+v; want its binding and filter only", lv)
	}
	if ov := readACLView(t, obs.values[ownerCfg]); !ov.interfaces || !ov.refs["ethernet-1/2.463"] {
		t.Errorf("the owner's deleted Config: %+v; want the subinterface and its interface-ref", ov)
	}
}
