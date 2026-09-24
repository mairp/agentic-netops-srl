package main

// T122: the MigrationPlan controller is registered only when its CRD is served (AD-29). The
// decision is discovery's: a group-version the server does not know, or one that serves no
// migrationplans, is "not served" and registers nothing; a discovery failure is an error.

import (
	"errors"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	fakediscovery "k8s.io/client-go/discovery/fake"
	k8stesting "k8s.io/client-go/testing"
)

func fakeDiscovery(lists ...*metav1.APIResourceList) *fakediscovery.FakeDiscovery {
	return &fakediscovery.FakeDiscovery{Fake: &k8stesting.Fake{Resources: lists}}
}

func TestMigrationPlanServed(t *testing.T) {
	fabric := &metav1.APIResourceList{GroupVersion: "fabric.agentic-netops.io/v1alpha1",
		APIResources: []metav1.APIResource{{Name: "networks", Namespaced: true, Kind: "Network"}}}
	plans := &metav1.APIResourceList{GroupVersion: "agentic-netops.io/v1alpha1",
		APIResources: []metav1.APIResource{{Name: "migrationplans", Namespaced: true, Kind: "MigrationPlan"},
			{Name: "migrationplans/status", Namespaced: true, Kind: "MigrationPlan"}}}
	other := &metav1.APIResourceList{GroupVersion: "agentic-netops.io/v1alpha1",
		APIResources: []metav1.APIResource{{Name: "somethingelse", Namespaced: true, Kind: "SomethingElse"}}}
	for _, tc := range []struct {
		name  string
		lists []*metav1.APIResourceList
		want  bool
	}{
		{"CRD not installed (group-version unknown)", []*metav1.APIResourceList{fabric}, false},
		{"group-version served without migrationplans", []*metav1.APIResourceList{fabric, other}, false},
		{"CRD served", []*metav1.APIResourceList{fabric, plans}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := migrationPlanServed(fakeDiscovery(tc.lists...))
			if err != nil || got != tc.want {
				t.Fatalf("migrationPlanServed = %v, %v; want %v", got, err, tc.want)
			}
		})
	}
}

func TestMigrationPlanServedDiscoveryError(t *testing.T) {
	d := fakeDiscovery()
	d.PrependReactor("*", "*", func(k8stesting.Action) (bool, runtime.Object, error) {
		return true, nil, errors.New("connection refused")
	})
	if ok, err := migrationPlanServed(d); ok || err == nil {
		t.Fatalf("a discovery failure = %v, %v; want an error", ok, err)
	}
}

// Not served: setupMigration registers nothing — it does not even touch the manager.
func TestSetupMigrationNotServedRegistersNothing(t *testing.T) {
	ok, err := setupMigration(nil, fakeDiscovery())
	if ok || err != nil {
		t.Fatalf("setupMigration without the CRD = %v, %v; want not registered", ok, err)
	}
}
