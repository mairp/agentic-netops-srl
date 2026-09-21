#!/usr/bin/env bash
# test_envtest.sh — `make test-envtest` (T025; FR-020, AD-28): the API and
# controller suites against a test control plane, no lab.
#
#   1. setup-envtest at the version go.mod pins (tools.go imports it, so
#      `go run` from this module resolves exactly that version) installs — or
#      finds in its cache — the control-plane binaries for the Kubernetes
#      version tools.go names ("envtest runs the <X.Y.Z> control plane");
#      ENVTEST_K8S_VERSION overrides it, ENVTEST_BIN_DIR the cache
#      (default: setup-envtest's own, ~/.local/share/kubebuilder-envtest).
#   2. go test -tags envtest ./tests/envtest/... with KUBEBUILDER_ASSETS set.
#      The envtest files carry `//go:build envtest`, which is what keeps them
#      out of `make test-static`'s `go test ./...`.
#
# No envtest package at all is a failure, never a silent pass.
#
# Usage: test_envtest.sh [--root <module dir>] [--list]
#   --list  print the directories the go test command reaches, one per line,
#           and run nothing (tests/unit/ci/envtest_reach_test.sh reads this —
#           the same package pattern and tags as the real run)
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
list_only=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$(cd -- "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
    --list) list_only=true; shift ;;
    *) echo "test_envtest: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
cd "$ROOT"

# The one package pattern and tag set, shared by --list and the run.
PKGS=(./tests/envtest/...)
TAGS=envtest

reached_dirs() {
  # Packages with at least one (test) Go file under the tags and no load error.
  go list -e -tags "$TAGS" \
    -f '{{if and (not .Error) (or .GoFiles .TestGoFiles .XTestGoFiles)}}{{.Dir}}{{end}}' \
    "${PKGS[@]}" 2>/dev/null | sed '/^$/d' | LC_ALL=C sort
}

if [[ "$list_only" == true ]]; then
  reached_dirs
  exit 0
fi

if [[ -z "$(reached_dirs)" ]]; then
  echo "test_envtest: FAIL no envtest package under ${PKGS[*]} (tags: $TAGS) — nothing would run" >&2
  exit 1
fi

k8s="${ENVTEST_K8S_VERSION:-}"
if [[ -z "$k8s" ]]; then
  # The sentence may wrap across comment lines: join them first.
  k8s="$(sed -E 's|^[[:space:]]*//[[:space:]]?||' tools.go | tr '\n' ' ' | tr -s ' ' \
    | sed -nE 's|.*envtest runs the ([0-9]+\.[0-9]+\.[0-9]+) control plane.*|\1|p')"
fi
if [[ ! "$k8s" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "test_envtest: FAIL no envtest Kubernetes version (tools.go names none; set ENVTEST_K8S_VERSION)" >&2
  exit 1
fi
bindir="${ENVTEST_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/kubebuilder-envtest}"
setup_ver="$(go list -m -f '{{.Version}}' sigs.k8s.io/controller-runtime/tools/setup-envtest)"
echo "test_envtest: setup-envtest ${setup_ver} (go.mod), Kubernetes ${k8s}, cache ${bindir}"
assets="$(go run sigs.k8s.io/controller-runtime/tools/setup-envtest use "$k8s" --bin-dir "$bindir" -p path)"
if [[ -z "$assets" || ! -x "$assets/kube-apiserver" ]]; then
  echo "test_envtest: FAIL setup-envtest returned no usable assets for ${k8s} ('${assets}')" >&2
  exit 1
fi
echo "test_envtest: KUBEBUILDER_ASSETS=${assets}"
KUBEBUILDER_ASSETS="$assets" go test -count=1 -tags "$TAGS" "${PKGS[@]}"
