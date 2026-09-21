#!/usr/bin/env bash
# Regenerate the first-party API's deepcopy code and CRDs with the controller-gen pinned in
# go.mod (tools.go), and place each CRD where its installation policy puts it:
#
#   config/crd/               Fabric, Network — the default kustomization (always installed)
#   config/crd/conditional/   IdentifierPool, IdentifierClaim — installed only when
#                             versions.lock.yaml selects allocationAuthority.kind: first-party
#                             (FR-104, data-model.md §23)
#   config/crd/optional/      MigrationPlan — never applied by lab provisioning (AD-29)
#
# Usage: hack/gen-crds.sh            regenerate in place
#        hack/gen-crds.sh --verify   regenerate, fail (restoring the previous files) on any diff
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

VERIFY=0
case "${1:-}" in
  "") ;;
  --verify) VERIFY=1 ;;
  *) echo "usage: $0 [--verify]" >&2; exit 2 ;;
esac

controller_gen() { go run sigs.k8s.io/controller-tools/cmd/controller-gen "$@"; }

# Where each generated CRD belongs. Anything controller-gen emits that is not listed here is an
# error: a new Kind is placed deliberately, and never lands in the default set by accident.
declare -A PLACE=(
  [fabric.agentic-netops.io_fabrics.yaml]=config/crd
  [fabric.agentic-netops.io_networks.yaml]=config/crd
  [fabric.agentic-netops.io_identifierpools.yaml]=config/crd/conditional
  [fabric.agentic-netops.io_identifierclaims.yaml]=config/crd/conditional
  [agentic-netops.io_migrationplans.yaml]=config/crd/optional
)
DEEPCOPY=(api/fabric/v1alpha1/zz_generated.deepcopy.go api/v1alpha1/zz_generated.deepcopy.go)

SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT

generated_files() {
  printf '%s\n' "${DEEPCOPY[@]}"
  for f in "${!PLACE[@]}"; do printf '%s/%s\n' "${PLACE[$f]}" "$f"; done
}

if [[ ${VERIFY} -eq 1 ]]; then
  mkdir -p "${SCRATCH}/before"
  while read -r f; do
    if [[ -f "$f" ]]; then mkdir -p "${SCRATCH}/before/$(dirname "$f")"; cp "$f" "${SCRATCH}/before/$f"; fi
  done < <(generated_files)
fi

# 1. Deepcopy, next to the types.
controller_gen object paths=./api/...

# 2. CRDs, into a scratch directory, then placed.
mkdir -p "${SCRATCH}/crd"
controller_gen crd paths=./api/... output:crd:artifacts:config="${SCRATCH}/crd"
for f in "${SCRATCH}"/crd/*.yaml; do
  base="$(basename "$f")"
  dest="${PLACE[$base]:-}"
  if [[ -z "${dest}" ]]; then
    echo "gen-crds: controller-gen emitted ${base}, which has no placement in $0" >&2
    exit 1
  fi
  mkdir -p "${dest}"
  cp "$f" "${dest}/${base}"
done
for f in "${!PLACE[@]}"; do
  [[ -f "${SCRATCH}/crd/$f" ]] || { echo "gen-crds: expected ${f} was not generated" >&2; exit 1; }
done

if [[ ${VERIFY} -eq 1 ]]; then
  drift=0
  while read -r f; do
    if ! cmp -s "$f" "${SCRATCH}/before/$f" 2>/dev/null; then
      echo "gen-crds: ${f} is not what the types generate" >&2
      diff -u "${SCRATCH}/before/$f" "$f" >&2 || true
      drift=1
    fi
  done < <(generated_files)
  if [[ ${drift} -ne 0 ]]; then
    # Put the committed files back: verification must not rewrite the tree.
    while read -r f; do
      if [[ -f "${SCRATCH}/before/$f" ]]; then cp "${SCRATCH}/before/$f" "$f"; else rm -f "$f"; fi
    done < <(generated_files)
    echo "gen-crds: run hack/gen-crds.sh and commit the result" >&2
    exit 1
  fi
  echo "gen-crds: generated code and CRDs are up to date"
fi
