#!/usr/bin/env bash
# tests/integration/delete_unreachable.sh — deleting a service while one of its targets is
# unreachable (T064, the suite T149 runs in both modes; SC-043, FR-103, FR-108, AD-26, AD-53,
# AD-71, research §Open items 11). Behind `make test-delete-unreachable`.
#
# Runs with no intent tier installed: the scratch mac-vrf vt-scratch-du (VLAN DU_VLAN, L2VNI DU_VNI,
# both leaves) is applied in agentic-netops-services (SC-043 is a control-plane criterion). After
# leftovers::scan (refuses on any leftover) and the negative controls, the service is made Ready,
# DU_LEAF is cut from the management network (declared in declared-faults.json BEFORE the cut) and
# the Network is deleted. It then asserts Ready=False/Deleting at EVERY poll from the deletion to
# the object's removal — never True, never Unknown — with the object HELD for >= 10 reconciliation
# intervals, and OBSERVES (records, never asserts) what SDC does with the Config deleted during the
# outage.
#   unaided mode (default): the leaf is reconnected; the object is removed, still Ready=False/
#     Deleting at every poll; the claim selector is empty; the device objects are gone (read back).
#   --force-release: during the outage, first an EMPTY reason on fabric.agentic-netops.io/
#     force-release — a claim-selector diff shows zero identifiers released and the object still
#     held — then a stated one: the Warning Event ForceReleased and the durable
#     Fabric.status.findings[] entry naming the device and the identifiers, the object removed and
#     the selector empty. After reconnection the stale configuration the finding warns of is
#     recorded, then the suite's own scratch device objects are removed and the removal read back.
#
# Usage: delete_unreachable.sh run [--force-release]
# Environment: DU_LEAF (leaf02), DU_VLAN (191), DU_VNI (10191), DU_HOLD_INTERVALS (10), plus suite.sh's.
set -euo pipefail

DU_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/suite.sh
source "$DU_HERE/lib/suite.sh"

: "${DU_LEAF:=leaf02}"
: "${DU_VLAN:=191}"
: "${DU_VNI:=10191}"
: "${DU_HOLD_INTERVALS:=10}"
DU_NET="vt-scratch-du"
DU_ABSENT="vt-scratch-never-ready"
DU_ANN="fabric.agentic-netops.io/force-release"

du::observe_config() {
  local cfg="${DU_NET}.${DU_LEAF}" out
  if out="$(gate::run "DU.observe-config" -- lab::kubectl -n "$LAB_TARGET_NS" get configs.config.sdcio.dev "$cfg" -o json 2>/dev/null)"; then
    log::info "observed (Open item 11, reported): Config $cfg $(jq -c '{deletionTimestamp: .metadata.deletionTimestamp, finalizers: .metadata.finalizers, conditions: [.status.conditions[]? | "\(.type)=\(.status)/\(.reason)"]}' <<<"$out")"
  else
    log::info "observed (Open item 11, reported): Config $cfg is gone from the API during the outage"
  fi
}

du::device_cleanup() {
  local p
  for p in "/network-instance[name=macvrf-${DU_NET}]" "/acl/interface[interface-id=ethernet-1/1.${DU_VLAN}]" \
           "/tunnel-interface[name=vxlan0]/vxlan-interface[index=${DU_VNI}]" "/interface[name=ethernet-1/1]/subinterface[index=${DU_VLAN}]"; do
    gate::pre_absent "$DU_LEAF" "$p" && continue
    gate::dev "DU.device-cleanup" "$DU_LEAF" set --delete "$p" >/dev/null || return 1
    gate::pre_absent "$DU_LEAF" "$p" || return 1
  done
}

du::run() {
  local force=0
  case "${1:-}" in "") ;; --force-release) force=1 ;; *) echo "usage: $0 run [--force-release]" >&2; return 2 ;; esac
  suite::init delete-unreachable || return $?
  suite::refuse_on_leftovers delete-unreachable || return $?
  suite::intervals
  local rc hold=$((DU_HOLD_INTERVALS * SUITE_RECONCILE_S)) ready_wait=$((SUITE_REVERIFY_S + 2 * SUITE_RECONCILE_S)) snap bogus
  local remove_wait=$((SUITE_REVERIFY_S + DU_HOLD_INTERVALS * SUITE_RECONCILE_S))
  snap="$EVIDENCE_DIR/du-claims-before.txt"; bogus="$EVIDENCE_DIR/du-claims-bogus.txt"
  echo "vt-scratch-no-such-claim 0" >"$bogus"
  evidence_run "$(gate::id DU.claims-bogus)" --attach "${bogus#"$EVIDENCE_DIR"/}" -- cat "$bogus" >/dev/null
  # the claims_empty control needs a service that DOES hold claims: the first one found in the
  # service namespace (a name that no longer exists would pass the check and prove nothing)
  local holder
  holder="$(bash "$SVC_CHECKS" claims_holder "$SVC_NS" 2>/dev/null || true)"
  [[ -n "$holder" ]] || { suite::fail "no service in $SVC_NS holds a claim: the claims_empty negative control has nothing to fail on"; suite::finish delete-unreachable; return 1; }

  # negative controls first
  suite::neg DU-ready cond "$SVC_NS" "$DU_ABSENT" 5 Ready=True || true
  suite::neg DU-deleting deleting_hold "$SVC_NS" "$DU_ABSENT" held 2 || true
  suite::neg DU-claims-equal claims_equal "$bogus" "$SVC_NS" "$DU_NET" || true
  suite::neg DU-claims-empty claims_empty "$SVC_NS" "$holder" || true
  suite::neg DU-event event "$SVC_NS" "$DU_ABSENT" ForceReleased Warning || true
  suite::neg DU-unreachable cond "$SVC_NS" "$DU_ABSENT" 5 "Deleting=True/TargetUnreachable~${DU_LEAF}" || true
  suite::neg DU-layer-gone config_gone "$LAB_TARGET_NS" "${FABRIC_NAME}.${DU_LEAF}" 5 || true
  suite::neg DU-finding finding "$FABRIC_NAMESPACE" "$FABRIC_NAME" "$DU_LEAF" "$SVC_NS" "$DU_ABSENT" || true
  suite::neg DU-finding-cleared finding_cleared "$FABRIC_NAMESPACE" "$FABRIC_NAME" "$DU_LEAF" "$SVC_NS" "$DU_ABSENT" 5 || true

  suite::on_exit du::teardown
  suite::apply_macvrf "$DU_NET" "$DU_VLAN" "$DU_VNI" || { suite::fail "could not apply $DU_NET"; suite::finish delete-unreachable; return 1; }
  rc=0; suite::check DU.ready DU-ready --readiness -- cond "$SVC_NS" "$DU_NET" "$ready_wait" Ready=True >/dev/null || rc=$?
  [[ "$rc" -eq 0 ]] || { suite::fail "$DU_NET never became Ready"; suite::finish delete-unreachable; return 1; }
  bash "$SVC_CHECKS" claims "$SVC_NS" "$DU_NET" >"$snap"
  evidence_run "$(gate::id DU.claims-before)" --attach "${snap#"$EVIDENCE_DIR"/}" -- cat "$snap" >/dev/null
  [[ -s "$snap" ]] || suite::fail "no claim labelled $SVC_NS/$DU_NET before deletion"

  suite::mgmt_cut "$DU_LEAF" "vt-scratch-du-mgmt-${DU_LEAF}" || { suite::fail "could not cut $DU_LEAF"; suite::finish delete-unreachable; return 1; }
  gate::run "DU.delete" -- lab::kubectl -n "$SVC_NS" delete "$SUITE_NET_RES" "$DU_NET" --wait=false >/dev/null || suite::fail "delete $DU_NET"
  rc=0; suite::check DU.held DU-deleting --readiness -- deleting_hold "$SVC_NS" "$DU_NET" held "$hold" >/dev/null || rc=$?
  suite::judge "$rc" "held Ready=False/Deleting for ${DU_HOLD_INTERVALS} reconciliation intervals while $DU_LEAF is unreachable" "not held Ready=False/Deleting while $DU_LEAF was unreachable"
  # Rule 8 step 5 names the unreachable target, in both modes (FR-103): the layer's Target may
  # stay Ready through a cut, so this is what shows the provider noticed at all.
  rc=0; suite::check DU.unreachable DU-unreachable --readiness -- cond "$SVC_NS" "$DU_NET" "$((2 * SUITE_RECONCILE_S))" \
    "Deleting=True/TargetUnreachable~${DU_LEAF}" "Ready=False/Deleting" >/dev/null || rc=$?
  suite::judge "$rc" "Deleting=True/TargetUnreachable naming $DU_LEAF" "Deleting is not TargetUnreachable naming $DU_LEAF"
  du::observe_config

  if [[ "$force" == 1 ]]; then
    gate::run "DU.force-empty" -- lab::kubectl -n "$SVC_NS" annotate --overwrite "$SUITE_NET_RES" "$DU_NET" "${DU_ANN}=" >/dev/null || suite::fail "annotate empty reason"
    rc=0; suite::check DU.force-empty-held DU-deleting --readiness -- deleting_hold "$SVC_NS" "$DU_NET" held "$((3 * SUITE_RECONCILE_S))" >/dev/null || rc=$?
    suite::judge "$rc" "an empty reason: the object is still held" "an empty reason released the object"
    rc=0; suite::check DU.force-empty-claims DU-claims-equal --readiness -- claims_equal "$snap" "$SVC_NS" "$DU_NET" >/dev/null || rc=$?
    suite::judge "$rc" "an empty reason: zero identifiers released (claim-selector diff)" "an empty reason released identifiers"
    gate::run "DU.force-refused-event" -- bash "$SVC_CHECKS" event "$SVC_NS" "$DU_NET" ForceReleaseRefused Warning >/dev/null \
      || log::warn "no ForceReleaseRefused Event observed (reported)"
    gate::run "DU.force-stated" -- lab::kubectl -n "$SVC_NS" annotate --overwrite "$SUITE_NET_RES" "$DU_NET" \
      "${DU_ANN}=${DU_LEAF} unreachable: delete_unreachable suite force-release" >/dev/null || suite::fail "annotate stated reason"
    rc=0; suite::check DU.gone DU-deleting --readiness -- deleting_hold "$SVC_NS" "$DU_NET" gone "$((4 * SUITE_RECONCILE_S))" >/dev/null || rc=$?
    suite::judge "$rc" "force-released: removed, Ready=False/Deleting at every poll" "not removed after a stated force-release reason"
    rc=0; suite::check DU.event DU-event --readiness -- event "$SVC_NS" "$DU_NET" ForceReleased Warning >/dev/null || rc=$?
    suite::judge "$rc" "Warning Event ForceReleased" "no Warning Event ForceReleased"
    rc=0; suite::check DU.finding DU-finding --readiness -- finding "$FABRIC_NAMESPACE" "$FABRIC_NAME" "$DU_LEAF" "$SVC_NS" "$DU_NET" >/dev/null || rc=$?
    suite::judge "$rc" "Fabric.status.findings[] names $DU_LEAF and the identifiers" "no durable finding naming $DU_LEAF"
    rc=0; suite::check DU.claims-empty DU-claims-empty --readiness -- claims_empty "$SVC_NS" "$DU_NET" >/dev/null || rc=$?
    suite::judge "$rc" "claim selector empty after force-release" "claims left after force-release"
    suite::mgmt_restore "$DU_LEAF" || suite::fail "reconnection of $DU_LEAF"
    # the finding outlives the outage: still open at reconnection, cleared only by a scheduled
    # read-back that finds every device object absent (T149, SC-043)
    rc=0; suite::check DU.finding-after-return DU-finding --readiness -- finding "$FABRIC_NAMESPACE" "$FABRIC_NAME" "$DU_LEAF" "$SVC_NS" "$DU_NET" >/dev/null || rc=$?
    suite::judge "$rc" "the finding is still open at reconnection" "the finding was gone before any read-back of $DU_LEAF could run"
    leftovers::scan || log::info "stale configuration on $DU_LEAF after force-release (the finding's warning, recorded above)"
    # The layer still holds the deleted Config and finishes its own removal once the node is
    # back (Open item 11). The device is never edited under a Config the layer still holds:
    # doing so on 2026-09-24 left the layer's tree and the device diverged and every leaf02
    # Config unapplied (live-findings 2026-09-24-delete-unreachable).
    rc=0; suite::check DU.layer-config-gone DU-layer-gone --readiness -- config_gone "$LAB_TARGET_NS" "${DU_NET}.${DU_LEAF}" "$remove_wait" >/dev/null || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      log::info "the layer removed its deleted Config ${DU_NET}.${DU_LEAF} itself after reconnection"
      du::device_cleanup || suite::fail "removal of the scratch device objects on $DU_LEAF did not read back"
      rc=0; suite::check DU.finding-cleared DU-finding-cleared --readiness -- finding_cleared "$FABRIC_NAMESPACE" "$FABRIC_NAME" "$DU_LEAF" "$SVC_NS" "$DU_NET" "$((SUITE_REVERIFY_S + 2 * SUITE_RECONCILE_S))" >/dev/null || rc=$?
      suite::judge "$rc" "the finding cleared only after a clean read-back of $DU_LEAF (FindingCleared Event)" "the finding was not cleared by a read-back"
    else
      suite::fail "the layer still holds Config ${DU_NET}.${DU_LEAF} ${remove_wait}s after reconnection; the device is left untouched"
    fi
  else
    suite::mgmt_restore "$DU_LEAF" || suite::fail "reconnection of $DU_LEAF"
    rc=0; suite::check DU.gone DU-deleting --readiness -- deleting_hold "$SVC_NS" "$DU_NET" gone "$remove_wait" >/dev/null || rc=$?
    suite::judge "$rc" "removed after reconnection, Ready=False/Deleting at every poll" "not removed (Ready=False/Deleting throughout) within ${remove_wait}s of reconnection"
    rc=0; suite::check DU.claims-empty DU-claims-empty --readiness -- claims_empty "$SVC_NS" "$DU_NET" >/dev/null || rc=$?
    suite::judge "$rc" "claim selector empty after removal" "claims left after removal"
  fi
  leftovers::scan >/dev/null || suite::fail "scratch left on a node after $DU_NET was removed"
  suite::finish delete-unreachable
}

# du::teardown — exit trap: never leave the scratch Network behind (the mgmt cut is restored by its
# own trap, registered later and so run first)
du::teardown() {
  lab::kubectl -n "$SVC_NS" get "$SUITE_NET_RES" "$DU_NET" >/dev/null 2>&1 || return 0
  gate::run "DU.teardown" -- lab::kubectl -n "$SVC_NS" delete "$SUITE_NET_RES" "$DU_NET" --wait=true --timeout=300s >/dev/null
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    run) du::run "$@" ;;
    *) echo "usage: $0 run [--force-release]" >&2; return 2 ;;
  esac
}

main "$@"
