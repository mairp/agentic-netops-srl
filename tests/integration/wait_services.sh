#!/usr/bin/env bash
# tests/integration/wait_services.sh — every example Network reports Ready=True (T064; SC-004,
# FR-100, NFR-013; quickstart.md §5).
#
# Behind `make wait-services`. Reads the Networks declared in examples/constructs/ (non-recursive:
# negative/ is never applied, AD-50) and waits for each one's Ready=True within SV_WAIT. The
# readiness check's negative control is recorded first — the same condition check against a
# Network that does not exist, which MUST fail (NFR-013) — and every result runs through
# evidence_run.
#
# Usage: wait_services.sh [--apply] [<manifest-file|dir>…]
#   --apply   `kubectl apply -f` the manifests first (into agentic-netops-services, never the intent
#             tier's namespace, AD-26)
# Environment: EVIDENCE_DIR, CLUSTER_NAME, SV_WAIT (600 s), SV_CONSTRUCTS (examples/constructs).
set -euo pipefail

WS_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/services.sh
source "$WS_HERE/lib/services.sh"
# shellcheck source=../../scripts/lib/log.sh
source "$SV_ROOT/scripts/lib/log.sh"
# shellcheck source=../../scripts/lib/evidence.sh
source "$SV_ROOT/scripts/lib/evidence.sh"

: "${SV_WAIT:=600}"
WS_ABSENT="vt-absent-network"   # a Network no manifest declares
WS_LIB="$WS_HERE/lib/services.sh"

usage() { echo "usage: $0 [--apply] [<manifest-file|dir>…]" >&2; return 2; }

main() {
  local apply=0 m rc fails=0 ns name
  local -a manifests=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply) apply=1 ;;
      -*) usage; return 2 ;;
      *) [[ -e "$1" ]] || { echo "no such manifest: $1" >&2; usage; return 2; }; manifests+=("$1") ;;
    esac
    shift
  done
  [[ ${#manifests[@]} -gt 0 ]] || manifests=("$SV_CONSTRUCTS")
  log::phase ServicesReady
  evidence::ensure_dir || return 3
  if [[ "$apply" == 1 ]]; then
    for m in "${manifests[@]}"; do
      evidence_run "WS.apply.$(basename "$m" .yaml)" -- sv::k apply -f "$m" || { log::error "apply $m failed"; return 1; }
    done
  fi
  local nets; nets="$(sv::manifest_networks "${manifests[@]}")"
  [[ -n "$nets" ]] || { log::error "no Network in ${manifests[*]}"; return 1; }
  # negative control first: the check must fail on a Network that does not exist
  rc=0; evidence_negative_control WS-ready -- bash "$WS_LIB" condition "$SV_NS" "$WS_ABSENT" Ready True || rc=$?
  [[ "$rc" -eq 0 ]] || { log::error "WS-ready negative control not admitted (rc=$rc)"; return 1; }
  while read -r ns name; do
    ns="${ns:-$SV_NS}"
    rc=0; CHECK_WAIT="$SV_WAIT" evidence_run "WS.ready.${name}" --check WS-ready --readiness --records SC-004:service-ready \
      -- bash "$WS_LIB" condition "$ns" "$name" Ready True || rc=$?
    if [[ "$rc" -eq 0 ]]; then log::info "PASS $ns/$name Ready=True"
    else
      fails=$((fails + 1)); log::error "FAIL $ns/$name not Ready=True within ${SV_WAIT}s"
      sv::k -n "$ns" get "$SV_NET_RES" "$name" \
        -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' >&2 || true
    fi
  done <<<"$nets"
  [[ "$fails" -eq 0 ]] || { log::error "wait-services FAILED: $fails Network(s) not Ready"; return 1; }
  log::info "wait-services passed (evidence: $EVIDENCE_DIR)"
}

main "$@"
