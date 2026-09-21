#!/usr/bin/env bash
# wait_targets.sh — `make wait-targets` (T036; FR-015, FR-010).
#
# Waits, bounded, until the DiscoveryRule's four Targets exist and are Ready. At config-server
# v0.0.58 the Target is served by the aggregated api-server as config.sdcio.dev/v1alpha1
# (`targets.config.sdcio.dev`; there is no inv.sdcio.dev Target at this version). A Target
# counts as Ready exactly when upstream's own Target.IsReady() would say so — all four of
#   Ready, TargetDiscoveryReady, TargetDatastoreReady, TargetConnectionReady  == "True"
# On timeout the wait fails naming every Target that is missing or not Ready, with the
# conditions that are not True and their messages, and the command to look further.
#
#   wait_targets::probe     one read: exit 0 when every expected Target is Ready; prints the
#                           state of each (used by the bounded wait; never mutates)
#
# Usage: wait_targets.sh [--timeout <s>] [--interval <s>]
#   env: WAIT_TARGETS_TIMEOUT (s, default 600), WAIT_TARGETS_INTERVAL (s, default 10),
#        WAIT_TARGETS_NAMES (default "spine01 spine02 leaf01 leaf02"),
#        WAIT_TARGETS_NAMESPACE (default sdc-system), KUBECTL, KUBE_CONTEXT
# Exit: 0 all Ready; 1 timed out (named); 2 usage.

# shellcheck source-path=SCRIPTDIR
[[ -n "${__AGENTIC_NETOPS_WAIT_TARGETS_SH:-}" ]] && return 0
__AGENTIC_NETOPS_WAIT_TARGETS_SH=1

WAIT_TARGETS_LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=log.sh
source "$WAIT_TARGETS_LIB/log.sh"
# shellcheck source=k8s_wait.sh
source "$WAIT_TARGETS_LIB/k8s_wait.sh"

WAIT_TARGETS_RESOURCE="targets.config.sdcio.dev"

wait_targets::probe() {
  local ns="${WAIT_TARGETS_NAMESPACE:-sdc-system}" names="${WAIT_TARGETS_NAMES:-spine01 spine02 leaf01 leaf02}" json
  json="$(k8s_wait::_kubectl get "$WAIT_TARGETS_RESOURCE" -n "$ns" -o json 2>&1)" \
    || { printf 'cannot list %s in %s: %s\n' "$WAIT_TARGETS_RESOURCE" "$ns" "$json"; return 1; }
  python3 -c '
import json, sys
names = sys.argv[1].split()
try:
    items = {i["metadata"]["name"]: i for i in json.loads(sys.stdin.read()).get("items", [])}
except ValueError as e:
    print(f"unreadable target list: {e}"); sys.exit(1)
WANT = ("Ready", "TargetDiscoveryReady", "TargetDatastoreReady", "TargetConnectionReady")
bad = 0
for n in names:
    t = items.get(n)
    if t is None:
        print(f"{n}: MISSING (no Target yet — is the DiscoveryRule applied? make sdc-onboard)"); bad += 1; continue
    conds = {c.get("type"): c for c in (t.get("status") or {}).get("conditions") or []}
    notok = []
    for w in WANT:
        c = conds.get(w) or {}
        if c.get("status") != "True":
            msg = c.get("message")
            notok.append(w + "=" + str(c.get("status", "absent")) + (" (" + msg + ")" if msg else ""))
    addr = (t.get("spec") or {}).get("address", "?")
    if notok:
        print(f"{n} ({addr}): NOT READY: " + "; ".join(notok)); bad += 1
    else:
        print(f"{n} ({addr}): Ready")
sys.exit(1 if bad else 0)
' "$names" <<<"$json"
}

wait_targets::main() {
  local timeout="${WAIT_TARGETS_TIMEOUT:-600}" interval="${WAIT_TARGETS_INTERVAL:-10}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout="${2:?}"; shift 2 ;;
      --interval) interval="${2:?}"; shift 2 ;;
      -h|--help) sed -n '2,/^# shellcheck source-path/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; return 0 ;;
      *) log::error "wait_targets: unknown argument '$1'"; return 2 ;;
    esac
  done
  log::phase TargetsReady
  local ns="${WAIT_TARGETS_NAMESPACE:-sdc-system}" names="${WAIT_TARGETS_NAMES:-spine01 spine02 leaf01 leaf02}" out
  if k8s_wait::until "$timeout" "$interval" "Ready Targets ${names} (${WAIT_TARGETS_RESOURCE}) in ${ns}" -- wait_targets::probe; then
    out="$(wait_targets::probe)"
    printf '%s\n' "$out"
    log::info "all Targets Ready: ${names}"
    return 0
  fi
  log::error "  next: ${KUBECTL:-kubectl} get ${WAIT_TARGETS_RESOURCE} -n ${ns} -o wide; ${KUBECTL:-kubectl} describe discoveryrules.inv.sdcio.dev -n ${ns}; ${KUBECTL:-kubectl} logs -n ${ns} statefulset/data-server-controller -c controller"
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  wait_targets::main "$@"
fi
