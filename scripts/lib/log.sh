#!/usr/bin/env bash
# log.sh — the lifecycle scripts' logger (T024, FR-010, NFR-014).
#
# NFR-014 exempts the lifecycle scripts from JSON logging: they are read by the
# operator watching a run. What it does require is a consistent level and phase
# prefix, which is this file's one job:
#
#   2026-09-21T10:00:00Z [INFO ] [ClusterReady] message
#
# Every line goes to stderr, so a function's stdout stays machine-readable.
# The phase comes from LOG_PHASE (set it with log::phase). LOG_LEVEL filters
# (debug|info|warn|error; default info). Sourcing twice is harmless.
#
# Usage: source scripts/lib/log.sh; log::phase NetworkReady; log::info "…"

[[ -n "${__AGENTIC_NETOPS_LOG_SH:-}" ]] && return 0
__AGENTIC_NETOPS_LOG_SH=1

: "${LOG_PHASE:=-}"
: "${LOG_LEVEL:=info}"

log::_rank() {
  case "$1" in
    debug) echo 10 ;; info) echo 20 ;; warn) echo 30 ;; error) echo 40 ;; *) echo 20 ;;
  esac
}

# log::_emit <level> <message…>
log::_emit() {
  local level="$1"; shift
  [[ "$(log::_rank "$level")" -ge "$(log::_rank "$LOG_LEVEL")" ]] || return 0
  local tag
  case "$level" in
    debug) tag="DEBUG" ;; info) tag="INFO " ;; warn) tag="WARN " ;; error) tag="ERROR" ;;
  esac
  printf '%s [%s] [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$LOG_PHASE" "$*" >&2
}

log::phase() { LOG_PHASE="$1"; export LOG_PHASE; log::_emit info "phase start"; }
log::debug() { log::_emit debug "$@"; }
log::info()  { log::_emit info "$@"; }
log::warn()  { log::_emit warn "$@"; }
log::error() { log::_emit error "$@"; }

# log::die <message…> — log at error level and exit 1 (fail fast, FR-010).
log::die() { log::_emit error "$@"; exit 1; }
