#!/usr/bin/env bash
# tests/integration/unmanaged_path.sh — an unmanaged path is neither overwritten nor claimed
# (T064; SC-007 second half, FR-015, FR-108, AD-49). Behind `make test-unmanaged-path`.
#
# Starts with leftovers::scan (refuses on any leftover). Writes scratch configuration — the value
# vt-scratch-unmanaged on UP_PATH (default the description of UP_PORT, a port no inventory lists
# and no Config renders) on UP_NODE with the operator's gnmic — then, across two reconciliation
# intervals plus one re-verification interval, asserts the value still reads back from the device
# (not overwritten by the revertive layer) and that no Config or Deviation in the Targets'
# namespace names the path (not claimed). The scratch value is then deleted and its removal read
# back. Negative controls first: the read-back against the device before the write (it does not
# carry the value), the unclaimed check against a path a service Config does own.
#
# Usage: unmanaged_path.sh run
# Environment: UP_NODE (leaf01), UP_PORT (ethernet-1/54), UP_PATH, UP_OWNED_NEEDLE (the owned
#   control needle, default macvrf-lab-macvrf), plus suite.sh's.
set -euo pipefail

UP_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/suite.sh
source "$UP_HERE/lib/suite.sh"

: "${UP_NODE:=leaf01}"
: "${UP_PORT:=ethernet-1/54}"
: "${UP_OWNED_NEEDLE:=macvrf-lab-macvrf}"
UP_VALUE="vt-scratch-unmanaged"

up::run() {
  suite::init unmanaged-path || return $?
  suite::refuse_on_leftovers unmanaged-path || return $?
  suite::intervals
  local path="${UP_PATH:-/interface[name=${UP_PORT}]/description}" rc hold
  hold=$((2 * SUITE_RECONCILE_S + SUITE_REVERIFY_S))

  gate::negative UP-kept value_equals "$UP_NODE" CONFIG "$path" "\"$UP_VALUE\"" || true
  suite::neg UP-unclaimed unclaimed "$LAB_TARGET_NS" "$UP_OWNED_NEEDLE" || true

  if ! gate::pre_absent "$UP_NODE" "$path"; then
    suite::fail "$path already carries configuration on $UP_NODE — choose an unused UP_PORT"; suite::finish unmanaged-path; return 1
  fi
  local del="$path"
  [[ -n "${UP_PATH:-}" ]] || del="$(gate::cleanup_path "$UP_NODE" "$UP_PORT")"
  suite::on_exit up::remove "$del"
  rc=0; gate::dev "UP.write" "$UP_NODE" set --delimiter "$LAB_SET_DELIM" --update "$(lab::upd "$path" "\"$UP_VALUE\"")" >/dev/null || rc=$?
  suite::judge "$rc" "scratch value written on $path" "could not write $path"

  log::info "holding ${hold}s (two reconciliation intervals + one re-verification interval)"
  sleep "$hold"
  rc=0; evidence_run "$(gate::id UP.kept)" --check UP-kept --readiness --records SC-007:unmanaged \
    -- bash "$GATE_CHECKS" value_equals "$UP_NODE" CONFIG "$path" "\"$UP_VALUE\"" >/dev/null || rc=$?
  suite::judge "$rc" "$path not overwritten after ${hold}s" "$path was overwritten"
  rc=0; suite::check UP.unclaimed UP-unclaimed --readiness -- unclaimed "$LAB_TARGET_NS" "$UP_PORT" >/dev/null || rc=$?
  suite::judge "$rc" "no Config or Deviation claims $UP_PORT" "$UP_PORT is claimed by a Config or Deviation"
  up::remove "$del" || suite::fail "removal of $del did not read back"
  suite::finish unmanaged-path
}

UP_REMOVED=0
up::remove() {
  local path="$1"
  [[ "$UP_REMOVED" == 0 ]] || return 0
  gate::dev "UP.remove" "$UP_NODE" set --delete "$path" >/dev/null || return 1
  gate::pre_absent "$UP_NODE" "$path" || return 1
  leftovers::scan >/dev/null || return 1
  UP_REMOVED=1
  log::info "$path removed from $UP_NODE (read back)"
}

main() {
  case "${1:-}" in
    run) up::run ;;
    *) echo "usage: $0 run" >&2; return 2 ;;
  esac
}

main "$@"
