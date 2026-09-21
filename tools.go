//go:build tools

// Package tools pins, in go.mod, the Kubernetes/controller-runtime matrix the
// Go toolchain was selected from and the code-generation and test-control-plane
// binaries run with `go run` (plan.md §Technical Context, T002).
//
// Matrix: kind v0.27.0 → Kubernetes 1.32 node image (envtest runs the 1.32.0
// control plane). The Go client libraries are set by the device-configuration
// layer's own module, consumed unchanged at the locked version (T018, FR-098):
// github.com/sdcio/config-server v0.0.58 requires client-go/apimachinery/api
// v0.35.3 and controller-runtime v0.23.1, which minimal version selection then
// fixes for this module too → controller-tools v0.20.x (built on apimachinery
// v0.35) and setup-envtest from controller-runtime's release-0.23 branch.
// client-go v0.35 against a 1.32 API server is inside the supported skew.
package tools

import (
	_ "k8s.io/apimachinery/pkg/runtime"
	_ "k8s.io/client-go/kubernetes"
	_ "sigs.k8s.io/controller-runtime"
	_ "sigs.k8s.io/yaml"

	_ "sigs.k8s.io/controller-runtime/tools/setup-envtest"
	_ "sigs.k8s.io/controller-tools/cmd/controller-gen"
)
