#!/usr/bin/env bash
# tier_purge_live.sh — T089's purge half, live (quickstart.md §24's tier purge; FR-078, FR-103,
# SC-042, AD-35, AD-46): the tier is removed around a service it holds, then provisioned again.
#
#   1. a scratch mac-vrf `vt-scratch-tp` spanning both leaves is applied in the tier's intent
#      namespace (agentic-netops-intent) and waited Ready; its claims are snapshotted;
#   2. `off.sh --purge-intent-tier` WITHOUT --remove-services exits non-zero naming it and both
#      continuations, and changes nothing — the Network, its claims and every tier workload's
#      replica count read back identical;
#   3. leaf02 is cut from the management network (a declared injected fault, FR-108) and
#      `off.sh --purge-intent-tier --remove-services` with TIER_PURGE_WAIT_SECONDS=${TP_WAIT_BLOCKED}
#      stops non-zero naming the Network and leaf02; the service's adopted/created claims are still
#      bound (the correct outcome, not a leak) and the tier's workloads are still present (scaled
#      down), never force-released (no force-release annotation on the Network);
#   4. leaf02 is reconnected and the same purge re-run completes: no Network in the intent
#      namespace, no workload left in agentic-netops-agents, no claim labelled with the service;
#      agentic-netops-services untouched throughout;
#   5. `provision.sh --with-intent-tier` provisions the tier again (idempotent), because US4 and
#      every later story start from a live tier.
#
# Usage: tier_purge_live.sh     Environment: TP_LEAF (leaf02), TP_VLAN (192), TP_VNI (10192),
#                                             TP_WAIT_BLOCKED (120), TP_WAIT_DONE (900), suite.sh's.
set -euo pipefail

TP_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SVC_NS="agentic-netops-intent"
# shellcheck source=../integration/lib/suite.sh
source "$TP_HERE/../integration/lib/suite.sh"

: "${TP_LEAF:=leaf02}"
: "${TP_VLAN:=192}"
: "${TP_VNI:=10192}"
: "${TP_WAIT_BLOCKED:=120}"
: "${TP_WAIT_DONE:=900}"
TP_NET="vt-scratch-tp"
TP_AGENTS_NS="agentic-netops-agents"
TP_SERVICES_NS="agentic-netops-services"
TP_ROOT="$SUITE_ROOT"

tp::workloads() {
  lab::kubectl -n "$TP_AGENTS_NS" get deployments,statefulsets -o json 2>/dev/null \
    | jq -r '.items[] | "\(.kind)/\(.metadata.name) \(.spec.replicas)"' | sort
}

tp::services_ns() { lab::kubectl -n "$TP_SERVICES_NS" get "$SUITE_NET_RES" -o name 2>/dev/null | sort; }

tp::purge() {  # tp::purge <evidence id> <wait seconds> [--remove-services]
  local id="$1" wait="$2"; shift 2
  local rc=0 run_id
  run_id="$(gate::id "$id")"
  TIER_PURGE_WAIT_SECONDS="$wait" evidence_run "$run_id" -- "$TP_ROOT/scripts/off.sh" --cluster-name "${CLUSTER_NAME:-agentic-netops}" \
    --purge-intent-tier "$@" >/dev/null 2>&1 || rc=$?
  TP_LAST_OUT="$EVIDENCE_DIR/$run_id.stdout"
  TP_LAST_ERR="$EVIDENCE_DIR/$run_id.stderr"
  return "$rc"
}

tp::said() { cat "$TP_LAST_OUT" "$TP_LAST_ERR" 2>/dev/null | grep -q -- "$1"; }

tp::run() {
  suite::init tier-purge-live || return $?
  suite::refuse_on_leftovers tier-purge-live || return $?
  suite::intervals
  local rc snap bogus before_w services_before ready_wait=$((SUITE_REVERIFY_S + 2 * SUITE_RECONCILE_S))
  snap="$EVIDENCE_DIR/tp-claims-before.txt"; bogus="$EVIDENCE_DIR/tp-claims-bogus.txt"
  echo "vt-scratch-no-such-claim 0" >"$bogus"
  services_before="$(tp::services_ns)"

  # negative controls first: every check below must be able to fail
  suite::neg TP-ready cond "$SVC_NS" vt-scratch-never-ready 5 Ready=True || true
  suite::neg TP-claims-equal claims_equal "$bogus" "$SVC_NS" "$TP_NET" || true

  # 1. a service held by the tier's intent namespace
  suite::apply_macvrf "$TP_NET" "$TP_VLAN" "$TP_VNI" || { suite::fail "could not apply $TP_NET"; suite::finish tier-purge-live; return 1; }
  rc=0; suite::check TP.ready TP-ready --readiness -- cond "$SVC_NS" "$TP_NET" "$ready_wait" Ready=True >/dev/null || rc=$?
  [[ "$rc" -eq 0 ]] || { suite::fail "$TP_NET never became Ready"; suite::finish tier-purge-live; return 1; }
  bash "$SVC_CHECKS" claims "$SVC_NS" "$TP_NET" >"$snap"
  evidence_run "$(gate::id TP.claims-before)" --attach "${snap#"$EVIDENCE_DIR"/}" -- cat "$snap" >/dev/null
  [[ -s "$snap" ]] || suite::fail "no claim labelled $SVC_NS/$TP_NET"
  suite::neg TP-claims-empty claims_empty "$SVC_NS" "$TP_NET" || true   # it holds claims: must fail
  before_w="$(tp::workloads)"
  evidence_run "$(gate::id TP.workloads-before)" -- tp::workloads >/dev/null

  # 2. no --remove-services: refused, nothing changed
  rc=0; tp::purge TP.purge-refused 60 || rc=$?
  if [[ "$rc" -ne 0 ]] && tp::said "$TP_NET" && tp::said "--remove-services"; then
    suite::ok "purge without --remove-services refused (exit $rc) naming $TP_NET and the continuations"
  else
    suite::fail "purge without --remove-services did not refuse naming $TP_NET (exit $rc)"
  fi
  [[ "$(tp::workloads)" == "$before_w" ]] && suite::ok "refused purge: every tier workload's replicas unchanged" \
    || suite::fail "refused purge changed a tier workload: $(diff <(echo "$before_w") <(tp::workloads) | tr '\n' ' ')"
  rc=0; suite::check TP.refused-claims TP-claims-equal -- claims_equal "$snap" "$SVC_NS" "$TP_NET" >/dev/null || rc=$?
  suite::judge "$rc" "refused purge: $TP_NET's claims unchanged" "refused purge changed $TP_NET's claims"
  rc=0; suite::check TP.refused-ready TP-ready -- cond "$SVC_NS" "$TP_NET" 5 Ready=True >/dev/null || rc=$?
  suite::judge "$rc" "refused purge: $TP_NET still present and Ready" "refused purge touched $TP_NET"

  # 3. a blocked finalizer: the purge stops naming the Network and the unreachable target
  suite::mgmt_cut "$TP_LEAF" "vt-scratch-tp-mgmt-${TP_LEAF}" || { suite::fail "could not cut $TP_LEAF"; suite::finish tier-purge-live; return 1; }
  sleep "$((2 * SUITE_RECONCILE_S))"   # let the provider see the target gone before the purge deletes
  rc=0; tp::purge TP.purge-blocked "$TP_WAIT_BLOCKED" --remove-services || rc=$?
  if [[ "$rc" -ne 0 ]] && tp::said "$TP_NET" && tp::said "$TP_LEAF"; then
    suite::ok "blocked purge stopped non-zero (exit $rc) naming $TP_NET and $TP_LEAF"
  else
    suite::fail "blocked purge did not stop naming $TP_NET and $TP_LEAF (exit $rc)"
  fi
  rc=0; suite::check TP.blocked-claims TP-claims-equal -- claims_equal "$snap" "$SVC_NS" "$TP_NET" >/dev/null || rc=$?
  suite::judge "$rc" "blocked purge: $TP_NET's claims still held (not a leak)" "blocked purge released $TP_NET's claims"
  if [[ -n "$(lab::kubectl -n "$TP_AGENTS_NS" get deployments -o name 2>/dev/null)" ]]; then
    suite::ok "blocked purge: the tier's workloads are still present (scaled down)"
  else
    suite::fail "blocked purge removed the tier's workloads"
  fi
  if lab::kubectl -n "$SVC_NS" get "$SUITE_NET_RES" "$TP_NET" -o json | jq -e '.metadata.annotations["fabric.agentic-netops.io/force-release"] == null' >/dev/null; then
    suite::ok "blocked purge: no force-release annotation written"
  else
    suite::fail "blocked purge wrote a force-release annotation"
  fi
  evidence_run "$(gate::id TP.blocked-state)" -- lab::kubectl -n "$SVC_NS" get "$SUITE_NET_RES" "$TP_NET" -o yaml >/dev/null || true

  # 4. the target returns: the re-run completes
  suite::mgmt_restore "$TP_LEAF" || suite::fail "could not restore $TP_LEAF"
  # "once the target returns" is once the platform sees it back: the Network is gone, or its
  # Deleting condition no longer names the unreachable target (a stale reason would stop the
  # re-run at once, by design)
  local i reason
  for i in $(seq 1 "$((TP_WAIT_DONE / 5))"); do
    reason="$(lab::kubectl -n "$SVC_NS" get "$SUITE_NET_RES" "$TP_NET" -o json 2>/dev/null \
      | jq -r '[.status.conditions[]? | select(.type == "Deleting") | .reason][0] // "gone"' 2>/dev/null || echo gone)"
    [[ "$reason" != "TargetUnreachable" ]] && break
    sleep 5
  done
  log::info "after reconnection: $TP_NET Deleting reason ${reason:-gone}"
  rc=0; tp::purge TP.purge-complete "$TP_WAIT_DONE" --remove-services || rc=$?
  suite::judge "$rc" "purge re-run after reconnection completed" "purge re-run after reconnection failed (exit $rc)"
  [[ -z "$(lab::kubectl -n "$SVC_NS" get "$SUITE_NET_RES" -o name 2>/dev/null)" ]] \
    && suite::ok "no Network left in $SVC_NS" || suite::fail "Networks left in $SVC_NS"
  [[ -z "$(lab::kubectl -n "$TP_AGENTS_NS" get deployments,statefulsets,pods -o name 2>/dev/null)" ]] \
    && suite::ok "no workload left in $TP_AGENTS_NS" || suite::fail "workloads left in $TP_AGENTS_NS"
  rc=0; suite::check TP.complete-claims TP-claims-empty -- claims_empty "$SVC_NS" "$TP_NET" >/dev/null || rc=$?
  suite::judge "$rc" "no claim labelled $SVC_NS/$TP_NET remains" "claims of $TP_NET remain after a completed purge"
  [[ "$(tp::services_ns)" == "$services_before" ]] && suite::ok "$TP_SERVICES_NS untouched" \
    || suite::fail "$TP_SERVICES_NS changed during the purge"

  # 5. the tier provisioned again
  rc=0; gate::run TP.reprovision -- env MGMT_CIDR="${MGMT_CIDR:-172.25.25.0/24}" "$TP_ROOT/scripts/provision.sh" \
    --cluster-name "${CLUSTER_NAME:-agentic-netops}" --with-intent-tier >/dev/null 2>&1 || rc=$?
  suite::judge "$rc" "provision.sh --with-intent-tier re-provisioned the tier" "re-provisioning the tier failed (exit $rc)"
  tp::attach_artefacts
  suite::finish tier-purge-live
}

# tp::attach_artefacts — the files this suite wrote beside its records (the declared fault, the
# negative control's bogus snapshot) attached to one record, so every artefact is run-captured
tp::attach_artefacts() {
  local -a attach=()
  local f
  for f in declared-faults.json tp-claims-bogus.txt; do
    [[ -f "$EVIDENCE_DIR/$f" ]] && attach+=(--attach "$f")
  done
  [[ ${#attach[@]} -gt 0 ]] || return 0
  evidence_run "$(gate::id TP.artefacts)" "${attach[@]}" -- ls -1 "$EVIDENCE_DIR" >/dev/null || true
}

tp::run
