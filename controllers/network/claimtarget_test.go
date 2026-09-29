package network

import (
	"testing"

	fabricv1 "github.com/mairp/agentic-netops-srl/api/fabric/v1alpha1"
	"github.com/mairp/agentic-netops-srl/pkg/kuid"
)

// authorityOnly is a kuid.Claims whose only answered method is Authority.
type authorityOnly struct {
	kuid.Claims
	kind string
}

func (a authorityOnly) Authority() string { return a.kind }

func kuidRefFabric() *fabricv1.Fabric {
	f := &fabricv1.Fabric{}
	f.Name = "fabric01"
	f.Spec.Underlay.ASNPoolRef = &fabricv1.PoolRef{Name: "asn", Namespace: DefaultKuidNamespace}
	return f
}

// T153 §26a: a Fabric carrying kuid-system pool refs on a first-party lab must not send the
// claim resolution (and the finalizer's release) to kuid-system.
func TestClaimTargetFirstPartyIgnoresKuidPoolRefs(t *testing.T) {
	r := &Reconciler{Claims: authorityOnly{kind: kuid.AuthorityFirstParty}}
	if got := r.claimTargetFor(kuidRefFabric()).namespace; got != kuid.FirstPartyNamespace {
		t.Fatalf("first-party claim namespace = %q, want %q", got, kuid.FirstPartyNamespace)
	}
}

// Negative control: under kuid the Fabric's pool refs still decide.
func TestClaimTargetKuidFollowsPoolRefs(t *testing.T) {
	r := &Reconciler{Claims: authorityOnly{kind: "kuid"}}
	if got := r.claimTargetFor(kuidRefFabric()).namespace; got != DefaultKuidNamespace {
		t.Fatalf("kuid claim namespace = %q, want %q", got, DefaultKuidNamespace)
	}
}
