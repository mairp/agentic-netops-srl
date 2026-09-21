#!/usr/bin/env bash
# resolve_pins.sh — fill the unresolved fields of versions.lock.yaml (T010; NFR-003, AD-05,
# AD-21, AD-50, AD-71; data-model.md §26, §28).
#
# Writes only what it observes, never input text:
#   * an empty image `digest:` from the registry — the SHA-256 of the manifest the registry serves
#     for the entry's exact `tag:` (`skopeo inspect --raw`); `pinned:` from repository:tag@digest;
#     an empty `tag:` with a `track:` line becomes the exact release tag sharing that digest;
#   * an empty `commit:` from the repository — the peeled target of the entry's tag (`git ls-remote`);
#   * an empty `assetSha256:` from the release's own checksum file; the Grafana plugin `sha256:`
#     from grafana.com; kind's node image from the pinned kind commit's defaults;
#   * `goToolchain` from go.mod (T002 selected it; it is recorded, never chosen here) and the golang
#     base tag of first-party images from it;
#   * every `firstPartyImages[].dependencyLocks[].sha256` computed from the tree;
#   * the browser-automation package version from its lock file;
#   * with --host-tooling: the browser revision the installed locked package fixes and each capture
#     tool's version, as observed on this host. A tool that is absent stays empty and
#     `verify_pins.sh --host-tooling` fails on it.
# A field already filled is never rewritten; clear it to re-resolve. A locally built image is
# never resolved (first-party images carry no digest). Comments are preserved (yq v4).
#
# Usage: scripts/lib/resolve_pins.sh [--lock FILE] [--root DIR] [--host-tooling]
# Exit: 0 everything resolved; 1 something left unresolved (listed); 2 usage or prerequisite.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"

usage() { sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

args=(resolve)
root="${repo_root}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lock) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; args+=(--lock "$2"); shift 2 ;;
    --root) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; root="$2"; shift 2 ;;
    --host-tooling) args+=(--host-tooling); shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "resolve_pins.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in python3 skopeo git yq; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "resolve_pins.sh: ${tool} is required" >&2; exit 2; }
done
yq --version 2>/dev/null | grep -q 'mikefarah' \
  || { echo "resolve_pins.sh: yq must be mikefarah/yq v4 (comment-preserving writes)" >&2; exit 2; }
python3 -c 'import yaml, tomllib' 2>/dev/null \
  || { echo "resolve_pins.sh: python3 >= 3.11 with PyYAML is required" >&2; exit 2; }

exec python3 "${here}/pins/pins.py" "${args[@]}" --root "${root}"
