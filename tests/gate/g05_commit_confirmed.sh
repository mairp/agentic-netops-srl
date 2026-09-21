#!/usr/bin/env bash
# tests/gate/g05_commit_confirmed.sh — G5: transactional rollback of a rejected change,
# commit-confirmed (then confirm or cancel), the failure confined to its own transaction
# (T043; quickstart.md §1, evidence/01 §6.4, §7 G5).
#
# SR Linux implements the OpenConfig commit-confirmed extension over gNMI; gnmic drives it with
# `set --commit-request --commit-id <id> --rollback-duration <d>` then `--commit-confirm` or
# `--commit-cancel`. If the pinned image does not support it, the checks below fail and that is
# recorded — never worked around. All values written are vt-scratch- descriptions on unused ports:
#   (a) atomicity: one Set carrying a valid description and an out-of-range MTU is rejected whole,
#       and the description is absent afterwards;
#   (b) cancel: a commit-request is applied (readiness), /system/configuration/commit is recorded,
#       a plain Set on ANOTHER port is attempted while it is pending (its outcome recorded), the
#       commit is cancelled, and the value is gone while the other transaction's value (if it was
#       accepted) survives;
#   (c) expiry: a commit-request with a short rollback-duration and no confirm reverts on its own;
#   (d) confirm: a confirmed commit outlives its rollback-duration.
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then exec bash "$GATE_HERE/run_gate.sh" --only G5 "$@"; fi
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"

: "${G5_NODE:=leaf01}"
: "${G5_PORT:=ethernet-1/57}"
: "${G5_OTHER_PORT:=ethernet-1/56}"
: "${G5_ROLLBACK:=20}"

g05::run() {
  gate::item_begin G5 "Commit-confirmed rollback, confined to its own transaction"
  local n="$G5_NODE" rc d="/interface[name=${G5_PORT}]/description" o="/interface[name=${G5_OTHER_PORT}]/description"
  local c1 c2 out
  c1="$(gate::cleanup_path "$n" "$G5_PORT")"; c2="$(gate::cleanup_path "$n" "$G5_OTHER_PORT")"

  # (a) a rejected change leaves nothing: the whole Set is refused
  rc=0; gate::dev "G05.atomic.set" "$n" set --delimiter "$LAB_SET_DELIM" \
    --update "$(lab::upd "$d" '"vt-scratch-g5-atomic"')" --update "$(lab::upd "/interface[name=${G5_PORT}]/mtu" 9413)" >/dev/null && rc=1
  gate::item_check "atomic-rejected" "$rc" "a Set with one out-of-range leaf is refused as a whole"
  rc=0; gate::record "G05.atomic.absent" G5-cc-pending absent "$n" CONFIG "$d" || rc=$?
  gate::item_check "atomic-nothing-applied" "$rc" "the valid leaf of the refused Set was not applied"

  # (b) commit-request, a concurrent plain Set, cancel
  rc=0; gate::dev "G05.cancel.request" "$n" set --commit-request --commit-id vt-scratch-g5-cancel \
    --rollback-duration 120s --delimiter "$LAB_SET_DELIM" --update "$(lab::upd "$d" '"vt-scratch-g5-cc"')" >/dev/null || rc=$?
  gate::item_check "commit-request-accepted" "$rc" "commit-confirmed request accepted"
  rc=0; gate::ready "G05.cancel.pending" G5-cc-pending value_equals "$n" CONFIG "$d" '"vt-scratch-g5-cc"' || rc=$?
  gate::item_check "commit-request-applied" "$rc" "the pending commit's value is in running"
  out="$(gate::dev "G05.cancel.commit-list" "$n" get --type state --path /system/configuration/commit 2>/dev/null)" || out="[]"
  gate::item_observe commit_list_while_pending "$(jq -c "$(lab::jq_lib)"' gvalues | .[0] // null | if . == null then null else (strip | unwrap("commit") | if type == "object" and has("commit") then .commit else . end | aslist | map({type, status, name}) | .[-3:]) end' <<<"$out" 2>/dev/null || echo null)"
  local other=accepted
  gate::dev "G05.cancel.concurrent-set" "$n" set --delimiter "$LAB_SET_DELIM" --update "$(lab::upd "$o" '"vt-scratch-g5-other"')" >/dev/null || other=rejected
  gate::item_observe concurrent_set_while_pending "\"$other\""
  rc=0; gate::dev "G05.cancel.cancel" "$n" set --commit-cancel --commit-id vt-scratch-g5-cancel >/dev/null || rc=$?
  gate::item_check "commit-cancel-accepted" "$rc" "commit cancel accepted"
  rc=0; CHECK_WAIT=20 gate::record "G05.cancel.reverted" G5-cc-pending absent "$n" CONFIG "$d" || rc=$?
  gate::item_check "cancel-reverted" "$rc" "the cancelled commit's value is gone from running"
  if [[ "$other" == accepted ]]; then
    rc=0; gate::ready "G05.cancel.other-survives" G5-other-survives value_equals "$n" CONFIG "$o" '"vt-scratch-g5-other"' || rc=$?
    gate::item_check "rollback-confined" "$rc" "the rollback touched only its own transaction: the concurrent Set survived"
  else
    gate::item_check "rollback-confined" 0 "a plain Set was refused while the confirmed commit was pending: no other transaction could be affected (recorded)" ""
  fi

  # (c) no confirm → the device reverts on its own when the rollback-duration expires
  rc=0; gate::dev "G05.expiry.request" "$n" set --commit-request --commit-id vt-scratch-g5-expiry \
    --rollback-duration "${G5_ROLLBACK}s" --delimiter "$LAB_SET_DELIM" --update "$(lab::upd "$d" '"vt-scratch-g5-expiry"')" >/dev/null || rc=$?
  gate::item_check "expiry-request-accepted" "$rc" "commit-confirmed request with a ${G5_ROLLBACK}s rollback-duration accepted"
  rc=0; gate::ready "G05.expiry.pending" G5-cc-pending value_equals "$n" CONFIG "$d" '"vt-scratch-g5-expiry"' || rc=$?
  gate::item_check "expiry-applied" "$rc" "the unconfirmed value is in running"
  rc=0; CHECK_WAIT=$((G5_ROLLBACK + 40)) gate::record "G05.expiry.reverted" G5-cc-pending absent "$n" CONFIG "$d" || rc=$?
  gate::item_check "expiry-reverted" "$rc" "with no confirm the device reverted it when the rollback-duration expired"

  # (d) confirm → the value outlives the rollback-duration
  rc=0; gate::dev "G05.confirm.request" "$n" set --commit-request --commit-id vt-scratch-g5-confirm \
    --rollback-duration "${G5_ROLLBACK}s" --delimiter "$LAB_SET_DELIM" --update "$(lab::upd "$d" '"vt-scratch-g5-confirm"')" >/dev/null || rc=$?
  gate::item_check "confirm-request-accepted" "$rc" "commit-confirmed request accepted"
  rc=0; gate::dev "G05.confirm.confirm" "$n" set --commit-confirm --commit-id vt-scratch-g5-confirm >/dev/null || rc=$?
  gate::item_check "commit-confirm-accepted" "$rc" "commit confirm accepted"
  sleep $((G5_ROLLBACK + 10))
  rc=0; gate::ready "G05.confirm.kept" G5-cc-pending value_equals "$n" CONFIG "$d" '"vt-scratch-g5-confirm"' || rc=$?
  gate::item_check "confirm-kept" "$rc" "the confirmed value outlived its rollback-duration"

  # cleanup, read back
  rc=0; gate::dev "G05.cleanup" "$n" set --delete "$c1" --delete "$c2" >/dev/null || rc=$?
  gate::item_check "cleanup" "$rc" "scratch descriptions removed"
  rc=0; gate::record "G05.cleanup.absent" G5-cc-pending absent "$n" CONFIG "$d" || rc=$?
  gate::item_check "cleanup-readback" "$rc" "removal read back"
  gate::item_end
}
