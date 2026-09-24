#!/usr/bin/env bash
# tests/integration/show_rendered_config.sh — the operator read-out of what the provider rendered
# for each Network (T064; FR-100, quickstart.md §5; contracts/crd-api.md "generated config").
#
# Behind `make show-rendered-config`. For each Network (all of agentic-netops-services by default)
# prints its conditions, status.renderedConfigs and every Config it lists (the SDC Configs in
# agentic-netops-system named <network>.<node>, AD-82) — plus any Config labelled with the Network
# that the status does not list, flagged as such. A read-out: captured through evidence_run, never
# asserted.
#
# Usage: show_rendered_config.sh [<network>…]
# Environment: EVIDENCE_DIR, CLUSTER_NAME, SV_NS (agentic-netops-services).
set -euo pipefail

SR_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/services.sh
source "$SR_HERE/lib/services.sh"
# shellcheck source=../../scripts/lib/log.sh
source "$SV_ROOT/scripts/lib/log.sh"
# shellcheck source=../../scripts/lib/evidence.sh
source "$SV_ROOT/scripts/lib/evidence.sh"

usage() { echo "usage: $0 [<network>…]" >&2; return 2; }

sr::one() {
  local net="$1" listed labelled line ns name
  printf '\n==== Network %s/%s\n' "$SV_NS" "$net"
  evidence_run "SR.network.${net}" -- sv::k -n "$SV_NS" get "$SV_NET_RES" "$net" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}{"lastVerifiedTime: "}{.status.lastVerifiedTime}{"\n"}' || return 1
  listed="$(sv::k -n "$SV_NS" get "$SV_NET_RES" "$net" \
    -o jsonpath='{range .status.renderedConfigs[*]}{.namespace} {.name}{"\n"}{end}')"
  while read -r line; do
    [[ -n "$line" ]] || continue
    ns="${line%% *}"; name="${line##* }"
    printf '\n== Config %s/%s\n' "$ns" "$name"
    evidence_run "SR.config.${name}" -- sv::k -n "$ns" get "$SV_CONFIG_RES" "$name" -o yaml || true
  done <<<"$listed"
  labelled="$(sv::k -n "$SV_SYS_NS" get "$SV_CONFIG_RES" -l "$(sv::sel "$SV_NS" "$net")" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
  while read -r name; do
    [[ -n "$name" ]] || continue
    grep -qx "$SV_SYS_NS $name" <<<"$listed" || printf '!! Config %s/%s is labelled with %s but not in its status.renderedConfigs\n' "$SV_SYS_NS" "$name" "$net"
  done <<<"$labelled"
}

main() {
  local -a nets=("$@") n
  for n in "${nets[@]}"; do [[ "$n" != -* ]] || { usage; return 2; }; done
  evidence::ensure_dir || return 3
  if [[ ${#nets[@]} -eq 0 ]]; then
    mapfile -t nets < <(sv::k -n "$SV_NS" get "$SV_NET_RES" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  fi
  [[ ${#nets[@]} -gt 0 ]] || { log::warn "no Network in $SV_NS"; return 0; }
  local rc=0
  for n in "${nets[@]}"; do sr::one "$n" || rc=1; done
  return "$rc"
}

main "$@"
