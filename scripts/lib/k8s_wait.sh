#!/usr/bin/env bash
# k8s_wait.sh — bounded waits with actionable diagnostics (T024, FR-010).
#
# Every wait has a bound; there is no "wait forever" and no default that hides
# one — a missing or non-positive timeout is refused. On timeout a wait fails
# naming WHAT it waited for, for HOW LONG, the probe's last output, and the
# command an operator runs next to see why. Nothing here retries a mutation:
# the probes are reads.
#
#   k8s_wait::until <timeout_s> <interval_s> <description> -- <probe cmd…>
#       Poll <probe> until it exits 0. On timeout: exit 1 with the diagnostic.
#   k8s_wait::condition <kind/name> <condition> <namespace|-> <timeout_s>
#       `kubectl wait --for=condition=<condition>`, bounded; on timeout the
#       object's `get -o wide`, its conditions and its recent Events are shown.
#   k8s_wait::rollout <namespace> <deployment|statefulset|daemonset>/<name> <timeout_s>
#   k8s_wait::exists <kind/name> <namespace|-> <timeout_s>
#
# KUBECTL overrides the client binary (default: kubectl); KUBE_CONTEXT, when set,
# is passed as --context so a wait never lands on the operator's current context
# by accident.

[[ -n "${__AGENTIC_NETOPS_K8S_WAIT_SH:-}" ]] && return 0
__AGENTIC_NETOPS_K8S_WAIT_SH=1

# shellcheck source=log.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/log.sh"

k8s_wait::_kubectl() {
  local -a ctx=()
  [[ -n "${KUBE_CONTEXT:-}" ]] && ctx=(--context "$KUBE_CONTEXT")
  "${KUBECTL:-kubectl}" "${ctx[@]}" "$@"
}

k8s_wait::_require_bound() {
  local name="$1" value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
    log::error "k8s_wait: $name must be a positive number of seconds, got '${value}' (every wait is bounded)"
    return 2
  fi
}

k8s_wait::_ns_args() {
  if [[ "$1" == "-" || -z "$1" ]]; then echo ""; else echo "-n $1"; fi
}

k8s_wait::until() {
  if [[ $# -lt 5 || "$4" != "--" ]]; then
    log::error "usage: k8s_wait::until <timeout_s> <interval_s> <description> -- <probe cmd…>"
    return 2
  fi
  local timeout="$1" interval="$2" what="$3"; shift 4
  k8s_wait::_require_bound timeout "$timeout" || return 2
  k8s_wait::_require_bound interval "$interval" || return 2

  local start now elapsed last="" rc=1 attempts=0
  start=$(date +%s)
  while :; do
    attempts=$((attempts + 1))
    last="$("$@" 2>&1)" && return 0
    rc=$?
    now=$(date +%s); elapsed=$((now - start))
    if [[ "$elapsed" -ge "$timeout" ]]; then break; fi
    local left=$((timeout - elapsed))
    sleep "$(( interval < left ? interval : left ))"
  done
  log::error "timed out after ${timeout}s waiting for: ${what}"
  log::error "  probe: $* (last exit ${rc}, ${attempts} attempt(s))"
  if [[ -n "$last" ]]; then
    log::error "  probe's last output:"
    printf '%s\n' "$last" | tail -n 20 | sed 's/^/    | /' >&2
  fi
  log::error "  next: re-run the probe by hand to see why it does not succeed"
  return 1
}

k8s_wait::_diagnose() {
  local obj="$1" ns="$2"
  [[ "$ns" == "-" ]] && ns=""
  local -a nsa=()
  [[ "$ns" != "-" && -n "$ns" ]] && nsa=(-n "$ns")
  log::error "  state of ${obj}${ns:+ in ${ns}}:"
  k8s_wait::_kubectl get "$obj" "${nsa[@]}" -o wide 2>&1 | sed 's/^/    | /' >&2 || true
  log::error "  conditions:"
  k8s_wait::_kubectl get "$obj" "${nsa[@]}" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>&1 \
    | sed 's/^/    | /' >&2 || true
  log::error "  recent events:"
  k8s_wait::_kubectl get events "${nsa[@]}" --field-selector "involvedObject.name=${obj#*/}" \
    --sort-by=.lastTimestamp 2>&1 | tail -n 10 | sed 's/^/    | /' >&2 || true
  log::error "  next: ${KUBECTL:-kubectl} describe ${obj}${ns:+ -n ${ns}}"
}

k8s_wait::condition() {
  if [[ $# -ne 4 ]]; then
    log::error "usage: k8s_wait::condition <kind/name> <condition> <namespace|-> <timeout_s>"
    return 2
  fi
  local obj="$1" cond="$2" ns="$3" timeout="$4"
  [[ "$ns" == "-" ]] && ns=""                          # '-' = cluster-scoped
  k8s_wait::_require_bound timeout "$timeout" || return 2
  local -a nsa=()
  [[ "$ns" != "-" && -n "$ns" ]] && nsa=(-n "$ns")
  local out
  if out="$(k8s_wait::_kubectl wait "$obj" "${nsa[@]}" --for="condition=${cond}" --timeout="${timeout}s" 2>&1)"; then
    return 0
  fi
  log::error "timed out after ${timeout}s waiting for ${obj}${ns:+ in ${ns}} to report condition ${cond}"
  printf '%s\n' "$out" | sed 's/^/    | /' >&2
  k8s_wait::_diagnose "$obj" "$ns"
  return 1
}

k8s_wait::rollout() {
  if [[ $# -ne 3 ]]; then
    log::error "usage: k8s_wait::rollout <namespace> <kind>/<name> <timeout_s>"
    return 2
  fi
  local ns="$1" obj="$2" timeout="$3"
  k8s_wait::_require_bound timeout "$timeout" || return 2
  local out
  if out="$(k8s_wait::_kubectl rollout status "$obj" -n "$ns" --timeout="${timeout}s" 2>&1)"; then
    return 0
  fi
  log::error "timed out after ${timeout}s waiting for rollout of ${obj} in ${ns}"
  printf '%s\n' "$out" | sed 's/^/    | /' >&2
  k8s_wait::_diagnose "$obj" "$ns"
  return 1
}

k8s_wait::exists() {
  if [[ $# -ne 3 ]]; then
    log::error "usage: k8s_wait::exists <kind/name> <namespace|-> <timeout_s>"
    return 2
  fi
  local obj="$1" ns="$2" timeout="$3"
  [[ "$ns" == "-" ]] && ns=""                          # '-' = cluster-scoped
  local -a nsa=()
  [[ -n "$ns" ]] && nsa=(-n "$ns")
  k8s_wait::until "$timeout" 2 "${obj}${ns:+ in ${ns}} to exist" -- \
    k8s_wait::_kubectl get "$obj" "${nsa[@]}" -o name
}
