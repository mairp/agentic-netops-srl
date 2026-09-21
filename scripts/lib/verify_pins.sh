#!/usr/bin/env bash
# verify_pins.sh — `make verify-pins` (T010; NFR-003, CR-006, FR-104, AD-05, AD-12, AD-21, AD-49,
# AD-50, AD-71; data-model.md §23, §26, §28; plan.md C-01).
#
# Checks versions.lock.yaml against the registries, the repositories, the tree and (with
# --host-tooling) the host. Resolution is real — never a shape check:
#   * every image digest is fetched from its registry (`skopeo inspect --raw <repo>@<digest>`) and
#     the manifest's own SHA-256 must equal it;
#   * every commit is looked up in its repository (`git ls-remote`, then `git fetch <sha>`), and a
#     tag's commit must be the tag's peeled target;
#   * every release-asset checksum must be the one the release's checksum file states, the Grafana
#     plugin hash the one grafana.com serves, kind's node image the pinned kind release's default.
# Fails (non-zero, naming the entry) on: latest / floating / omitted tags or versions, branch refs,
# any exception-, allow- or skip-style key (AD-12), the allocator decision-record rules (§23), a Go
# toolchain differing from go.mod (both values named), and the first-party build-input rules
# (§26): every FROM `<ref>@sha256:…` equal to the lock and resolving, dependency-lock hashes, no
# reference by a mutable tag, pending entries (Dockerfile absent) referenced anywhere, a docker/
# Dockerfile with no entry. A locally built image is never resolved against a registry.
#
# Usage: scripts/lib/verify_pins.sh [--lock FILE] [--root DIR] [--no-pending] [--host-tooling]
#   --lock FILE      lock file (default <root>/versions.lock.yaml)
#   --root DIR       tree root holding go.mod, docker/, the manifests (default: the repository)
#   --no-pending     the acceptance run: any pending first-party entry fails
#   --host-tooling   also check the host (browser-automation package + browser, capture tools)
# Exit: 0 all pins resolve; 1 a pin failed; 2 usage or missing prerequisite.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"

usage() { sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

args=(verify)
root="${repo_root}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lock) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; args+=(--lock "$2"); shift 2 ;;
    --root) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; root="$2"; shift 2 ;;
    --no-pending) args+=(--no-pending); shift ;;
    --host-tooling) args+=(--host-tooling); shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "verify_pins.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in python3 skopeo git; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "verify_pins.sh: ${tool} is required" >&2; exit 2; }
done
python3 -c 'import yaml, tomllib' 2>/dev/null \
  || { echo "verify_pins.sh: python3 >= 3.11 with PyYAML is required" >&2; exit 2; }

exec python3 "${here}/pins/pins.py" "${args[@]}" --root "${root}"
