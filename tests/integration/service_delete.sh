#!/usr/bin/env bash
# shellcheck disable=SC2015
# tests/integration/service_delete.sh — deleting a Network removes everything it owned (T064;
# SC-007, FR-100, FR-109, NFR-013; contracts/reconciliation.md Rules 8, 11; AD-53).
#
# Behind `make test-service-delete`. Deletes SV_DELETE_NET (lab-macvrf) and asserts, each through
# evidence_run: Ready=False/Deleting while the object is held (never True, never Unknown), the
# object removed (finalizer released), zero Configs labelled with it, zero claims labelled with it
# (the selector empty), and each of its network-instances absent from every node's running config.
# The removal checks' negative controls are recorded first, against the still-present service
# (they MUST fail while it exists). With --reapply (the default) the manifest is applied again at
# the end and waited Ready, so the lab is left as found; --no-reapply leaves it deleted.
#
# Usage: service_delete.sh [--no-reapply] [<network>]
# Environment: EVIDENCE_DIR, CLUSTER_NAME, LAB_NAME, SRL_USER, SRL_PASS, SV_WAIT (300 s).
set -euo pipefail

SD_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/services.sh
source "$SD_HERE/lib/services.sh"
# shellcheck source=../gate/lib/gate.sh
source "$SV_ROOT/tests/gate/lib/gate.sh"

: "${SV_WAIT:=300}"
SD_LIB="$SD_HERE/lib/services.sh"
SD_FAILS=()
sd::fail() { SD_FAILS+=("$1"); log::error "FAIL $1"; }
sd::ok()   { log::info "PASS $1"; }
usage() { echo "usage: $0 [--no-reapply] [<network>]" >&2; return 2; }

# sd::manifest_of <network> — the example manifest declaring it
sd::manifest_of() {
  local f
  for f in "$SV_CONSTRUCTS"/*.yaml; do
    sv::manifest_networks "$f" | awk -v n="$1" '$2 == n {found=1} END {exit !found}' && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# sd::instances <network> — "<node> <network-instance>" pairs its Configs write
sd::instances() {
  # A Config carries its whole render at path "/" (observed live), so the network-instances are
  # read from the value: every object with a name and a type under network-instance, any path.
  sv::k -n "$SV_SYS_NS" get "$SV_CONFIG_RES" -l "$(sv::sel "$SV_NS" "$1")" -o json | jq -r '
    .items[] | (.metadata.name | split(".") | last) as $node
    | .spec.config[] | (.value | .. | objects | .["srl_nokia-network-instance:network-instance"]? // empty | .[]? | .name // empty),
                       (.path | [scan("network-instance\\[name=([^\\]]+)\\]")[0]] | .[])
    | "\($node) \(.)"' 2>/dev/null | grep -v ' default$' | sort -u || true
}

sd::watch_deleting() {  # polls until the object is gone; any True/Unknown Ready is a finding
  local deadline=$(( $(date +%s) + SV_WAIT )) st
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    st="$(sv::k -n "$SV_NS" get "$SV_NET_RES" "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}/{.status.conditions[?(@.type=="Ready")].reason}' 2>&1)" \
      || { [[ "$st" == *NotFound* ]] && { echo "removed"; return 0; }; }
    echo "$(date -u +%H:%M:%SZ) Ready=$st"
    [[ "$st" == False/Deleting || "$st" == */ || "$st" == / ]] || { echo "NOT Ready=False/Deleting: $st"; return 1; }
    sleep 2
  done
  echo "not removed within ${SV_WAIT}s"; return 1
}

main() {
  local reapply=1 net="" m rc inst node ni
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-reapply) reapply=0 ;;
      -*) usage; return 2 ;;
      *) [[ -z "$net" ]] || { usage; return 2; }; net="$1" ;;
    esac
    shift
  done
  net="${net:-${SV_DELETE_NET:-lab-macvrf}}"
  m="$(sd::manifest_of "$net")" || { log::error "no manifest in $SV_CONSTRUCTS declares $net"; return 2; }
  log::phase ServiceDelete
  gate::init
  CHECK_WAIT="$SV_WAIT" gate::run "SD.pre-ready.${net}" -- bash "$SD_LIB" condition "$SV_NS" "$net" Ready True \
    || { log::error "$net not Ready=True before deletion"; return 1; }
  inst="$(sd::instances "$net")"
  [[ -n "$inst" ]] || { log::error "no network-instance found in ${net}'s Configs"; return 1; }
  log::info "${net} owns: $(tr '\n' ';' <<<"$inst")"
  # negative controls first, against the still-present service
  evidence_negative_control SD-gone -- bash "$SD_LIB" gone "$SV_NS" "$SV_NET_RES" "$net" || sd::fail "SD-gone control"
  evidence_negative_control SD-no-configs -- bash "$SD_LIB" no_configs "$SV_NS" "$net" || sd::fail "SD-no-configs control"
  evidence_negative_control SD-no-claims -- bash "$SD_LIB" no_claims "$SV_NS" "$net" || sd::fail "SD-no-claims control"
  while read -r node ni; do
    evidence_negative_control SD-ni-absent -- bash "$SD_LIB" ni_absent "$node" "$ni" || sd::fail "SD-ni-absent control $node $ni"
  done <<<"$inst"
  [[ ${#SD_FAILS[@]} -eq 0 ]] || { log::error "negative controls not admitted: ${SD_FAILS[*]}"; return 1; }
  gate::run "SD.delete.${net}" -- sv::k -n "$SV_NS" delete "$SV_NET_RES" "$net" --wait=false || return 1
  rc=0; gate::run "SD.deleting.${net}" --records SC-007 -- sd::watch_deleting "$net" || rc=$?
  [[ "$rc" -eq 0 ]] && sd::ok "$net Ready=False/Deleting at every poll until removed" || sd::fail "$net deletion (see SD.deleting)"
  rc=0; CHECK_WAIT="$SV_WAIT" evidence_run "SD.gone.${net}" --check SD-gone --readiness -- bash "$SD_LIB" gone "$SV_NS" "$SV_NET_RES" "$net" || rc=$?
  [[ "$rc" -eq 0 ]] || sd::fail "$net not removed"
  rc=0; CHECK_WAIT="$SV_WAIT" evidence_run "SD.no-configs.${net}" --check SD-no-configs --readiness --records SC-007 -- bash "$SD_LIB" no_configs "$SV_NS" "$net" || rc=$?
  [[ "$rc" -eq 0 ]] && sd::ok "zero Configs of $net" || sd::fail "Configs of $net remain"
  rc=0; CHECK_WAIT="$SV_WAIT" evidence_run "SD.no-claims.${net}" --check SD-no-claims --readiness -- bash "$SD_LIB" no_claims "$SV_NS" "$net" || rc=$?
  [[ "$rc" -eq 0 ]] && sd::ok "claim selector of $net empty" || sd::fail "claims of $net remain"
  while read -r node ni; do
    rc=0; CHECK_WAIT="$SV_WAIT" evidence_run "$(gate::id "SD.ni-absent.${node}.${ni}")" --check SD-ni-absent --readiness --records SC-007 \
      -- bash "$SD_LIB" ni_absent "$node" "$ni" || rc=$?
    [[ "$rc" -eq 0 ]] && sd::ok "$node: $ni removed (read back from running)" || sd::fail "$node still carries $ni"
  done <<<"$inst"
  if [[ "$reapply" == 1 ]]; then
    gate::run "SD.reapply.${net}" -- sv::k apply -f "$m" || sd::fail "re-apply $m"
    CHECK_WAIT="$SV_WAIT" gate::run "SD.reapply-ready.${net}" -- bash "$SD_LIB" condition "$SV_NS" "$net" Ready True \
      || sd::fail "$net not Ready=True after re-apply"
  fi
  [[ ${#SD_FAILS[@]} -eq 0 ]] || { log::error "test-service-delete FAILED: ${SD_FAILS[*]}"; return 1; }
  log::info "test-service-delete passed (evidence: $EVIDENCE_DIR)"
}

main "$@"
