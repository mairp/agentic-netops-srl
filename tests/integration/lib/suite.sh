#!/usr/bin/env bash
# tests/integration/lib/suite.sh — shared plumbing of the US2 fault-making live suites (T064
# target_failure/managed_drift/unmanaged_path/delete_unreachable, T167 reverify; FR-107, FR-108,
# AD-43, AD-49, AD-60, AD-64).
#
#   suite::init <item>                 evidence dir, operator creds, the one EXIT/INT/TERM trap
#   suite::refuse_on_leftovers <name>  leftovers::scan first — a leftover on any node refuses the start
#   suite::on_exit <cmd…>              register a restoration run from the exit trap (LIFO): a
#                                      declarative fault is put back whether a wait was met, timed out
#                                      or the script was interrupted, and a timed-out wait fails the
#                                      run AFTER restoring, never before
#   suite::check <id> <CHECK> [--readiness] -- <service_checks args…>   one run-captured check
#   suite::neg <CHECK> <service_checks args…>   its negative control (must fail; recorded first)
#   suite::summary <evidence-id>       the check's SUMMARY json
#   suite::fields <id> <json>          evidence fields (measured latencies…) hashed into a record
#   suite::seconds <duration>          a Go duration (30s, 1m30s, 5m) in whole seconds; rc 1 if not one
#   suite::reverify_ok <duration>      0 when a test REVERIFY_INTERVAL respects the 30 s floor (§25)
#   suite::intervals                   SUITE_RECONCILE_S / SUITE_REVERIFY_S from the provider settings
#   suite::set_reverify <dur|default>  kubectl set env on the provider (original env restored on exit)
#   suite::mgmt_cut <node> <fault-id>  declare-then-cut the node's management link (host peer down; restored on exit)
#   suite::mgmt_restore <node>         set the link up and read the data path back (carrier + gNMI accept)
#   suite::maint_add <node> <iface…>   append Fabric.spec.maintenance[] entries (restored on exit)
#   suite::maint_restore               put the saved maintenance[] back and read it back
#
# Environment (beyond tests/lib/lab.sh): FABRIC_NAME (fabric01), FABRIC_NAMESPACE / LAB_TARGET_NS
# (agentic-netops-system), SVC_NS (agentic-netops-services), PROVIDER_DEPLOY (srl-provider),
# SUITE_ROLLOUT_WAIT (300 s).
# shellcheck source-path=SCRIPTDIR

[[ -n "${__AGENTIC_NETOPS_SUITE_SH:-}" ]] && return 0
__AGENTIC_NETOPS_SUITE_SH=1

SUITE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../gate/lib/gate.sh
source "$SUITE_ROOT/tests/gate/lib/gate.sh"
# shellcheck source=../../lib/leftovers.sh
source "$SUITE_ROOT/tests/lib/leftovers.sh"

: "${FABRIC_NAME:=fabric01}"
: "${FABRIC_NAMESPACE:=agentic-netops-system}"
: "${SVC_NS:=agentic-netops-services}"
: "${PROVIDER_DEPLOY:=srl-provider}"
: "${SUITE_ROLLOUT_WAIT:=300}"
SVC_CHECKS="$SUITE_ROOT/tests/integration/lib/service_checks.sh"
# shellcheck disable=SC2034  # read by the suites that source this file
SUITE_NET_RES="networks.fabric.agentic-netops.io"
SUITE_FABRIC_RES="fabrics.fabric.agentic-netops.io"
SUITE_FAILS=()
SUITE_CLEANUPS=()
declare -A SUITE_CUT=()
SUITE_ENV_SAVED=""
SUITE_MAINT_SAVED=""

suite::fail() { SUITE_FAILS+=("$1"); log::error "FAIL $1"; }
suite::ok()   { log::info "PASS $1"; }
# suite::judge <rc> <pass-text> <fail-text>
suite::judge() { if [[ "$1" -eq 0 ]]; then suite::ok "$2"; else suite::fail "$3"; fi; }

suite::on_exit() { SUITE_CLEANUPS+=("$*"); }

suite::_exit() {
  local rc="$1" i crc=0
  trap - EXIT INT TERM
  for ((i = ${#SUITE_CLEANUPS[@]} - 1; i >= 0; i--)); do
    log::info "restoring (exit trap): ${SUITE_CLEANUPS[$i]}"
    eval "${SUITE_CLEANUPS[$i]}" || { crc=1; log::error "restoration FAILED: ${SUITE_CLEANUPS[$i]}"; }
  done
  [[ "$rc" -eq 0 && "$crc" -ne 0 ]] && rc=1
  exit "$rc"
}

suite::init() {
  GATE_ITEM="$1"
  gate::init || return $?
  trap 'suite::_exit $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

suite::refuse_on_leftovers() {
  if ! leftovers::scan; then
    log::error "$1 REFUSED to start: leftovers present (listed above); run leftovers::remove explicitly (FR-108)"
    return 3
  fi
}

suite::check() {
  local id="$1" check="$2"; shift 2
  local ro=()
  [[ "${1:-}" == --readiness ]] && { ro=(--readiness); shift; }
  [[ "${1:-}" == -- ]] && shift
  SUITE_LAST_ID="$(gate::id "$id")"
  evidence_run "$SUITE_LAST_ID" --check "$check" "${ro[@]}" -- bash "$SVC_CHECKS" "$@"
}

suite::neg() {
  local check="$1" rc=0; shift
  evidence_negative_control "$check" -- bash "$SVC_CHECKS" "$@" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) log::info "[negative-control] $check failed as it must" ;;
    4) log::error "[negative-control] $check PASSED on a system without what it checks — no pass of it will be admitted" ;;
    *) log::error "[negative-control] $check could not be recorded (rc=$rc)" ;;
  esac
  return "$rc"
}

suite::summary() { sed -n 's/^SUMMARY //p' "$EVIDENCE_DIR/$1.stdout" 2>/dev/null | tail -1; }

suite::fields() {
  local id="$1" json="$2" f
  f="suite-fields/$(gate::id "$id").json"
  mkdir -p "$EVIDENCE_DIR/suite-fields"
  jq -S . <<<"$json" >"$EVIDENCE_DIR/$f"
  evidence_run "$(gate::id "$id")" --attach "$f" -- cat "$EVIDENCE_DIR/$f" >/dev/null
}

# suite::seconds <go-duration> — whole seconds of h/m/s durations (the forms REVERIFY_INTERVAL takes)
suite::seconds() {
  local d="$1" total=0 n u
  [[ "$d" =~ ^([0-9]+(h|m|s))+$ ]] || return 1
  while [[ "$d" =~ ^([0-9]+)(h|m|s)(.*)$ ]]; do
    n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    case "$u" in h) total=$((total + 10#$n * 3600)) ;; m) total=$((total + 10#$n * 60)) ;; s) total=$((total + 10#$n)) ;; esac
  done
  printf '%s' "$total"
}

suite::reverify_ok() { local s; s="$(suite::seconds "$1")" || return 1; (( s >= 30 )); }

suite::_setting() {
  lab::kubectl -n "$FABRIC_NAMESPACE" get configmap "${PROVIDER_DEPLOY}-settings" -o json 2>/dev/null \
    | jq -r --arg k "$1" '.data[$k] // ""'
}

suite::_env_value() {
  lab::kubectl -n "$FABRIC_NAMESPACE" get deploy "$PROVIDER_DEPLOY" -o json \
    | jq -r --arg n "$1" '[.spec.template.spec.containers[0].env[]? | select(.name == $n)] | first | .value // ""'
}

suite::intervals() {
  local r v
  r="$(suite::_env_value RECONCILE_INTERVAL)"; [[ -n "$r" ]] || r="$(suite::_setting reconcile-interval)"
  v="$(suite::_env_value REVERIFY_INTERVAL)"; [[ -n "$v" ]] || v="$(suite::_setting reverify-interval)"
  SUITE_RECONCILE_S="$(suite::seconds "${r:-15s}")" || SUITE_RECONCILE_S=15
  SUITE_REVERIFY_S="$(suite::seconds "${v:-5m}")" || SUITE_REVERIFY_S=300
  log::info "reconciliation interval ${SUITE_RECONCILE_S}s, re-verification interval ${SUITE_REVERIFY_S}s"
}

suite::_rollout() {
  gate::run "SUITE.rollout" -- lab::kubectl -n "$FABRIC_NAMESPACE" rollout status "deploy/${PROVIDER_DEPLOY}" \
    --timeout="${SUITE_ROLLOUT_WAIT}s" >/dev/null
}

suite::env_restore() {
  [[ -n "$SUITE_ENV_SAVED" ]] || return 0
  gate::run "SUITE.provider-env-restore" -- lab::kubectl -n "$FABRIC_NAMESPACE" patch deploy "$PROVIDER_DEPLOY" --type=json \
    -p "$(jq -cn --argjson e "$SUITE_ENV_SAVED" '[{op: "replace", path: "/spec/template/spec/containers/0/env", value: $e}]')" >/dev/null || return 1
  SUITE_ENV_SAVED=""
  suite::_rollout
}

# suite::set_reverify <duration|default> — a test value (never below the 30 s floor) or the default
suite::set_reverify() {
  local v="$1"
  if [[ -z "$SUITE_ENV_SAVED" ]]; then
    SUITE_ENV_SAVED="$(lab::kubectl -n "$FABRIC_NAMESPACE" get deploy "$PROVIDER_DEPLOY" -o json | jq -c '.spec.template.spec.containers[0].env // []')" || return 1
    suite::on_exit suite::env_restore
  fi
  if [[ "$v" == default ]]; then
    [[ -z "$(suite::_setting reverify-interval)" ]] || { log::error "the settings ConfigMap states reverify-interval; the five-minute default cannot be reached by unsetting the override"; return 1; }
    gate::run "SUITE.reverify-default" -- lab::kubectl -n "$FABRIC_NAMESPACE" patch deploy "$PROVIDER_DEPLOY" --type=json \
      -p "$(jq -cn --argjson e "$SUITE_ENV_SAVED" '[{op: "replace", path: "/spec/template/spec/containers/0/env", value: [$e[] | select(.name != "REVERIFY_INTERVAL")]}]')" >/dev/null || return 1
  else
    suite::reverify_ok "$v" || { log::error "REVERIFY_INTERVAL test value '$v' is below the 30 s floor or not a duration"; return 2; }
    gate::run "SUITE.reverify-set" -- lab::kubectl -n "$FABRIC_NAMESPACE" set env "deploy/${PROVIDER_DEPLOY}" "REVERIFY_INTERVAL=${v}" >/dev/null || return 1
  fi
  suite::_rollout && suite::intervals
}

suite::mgmt_cut() {
  local node="$1" id="$2" c peer ifc
  c="$(lab::container "$node")"; ifc="$(lab::mgmt_if "$node")"
  peer="$(lab::mgmt_peer "$node")" || { log::error "cannot find the host-side peer of $c's $ifc"; return 1; }
  leftovers::declare_fault "$id" "$node" "management link of $c ($ifc, host peer $peer) set down" \
    "$(jq -cn --arg c "$c" --arg i "$ifc" --arg p "$peer" '{kind: "mgmt-link-down", container: $c, interface: $i, peer: $p}')" \
    '{"kind":"host-link-up"}' || return 1
  SUITE_CUT[$node]="$peer"
  suite::on_exit suite::mgmt_restore "$node"
  gate::run "SUITE.mgmt-cut.${node}" -- "${IP:-ip}" link set "$peer" down >/dev/null || return 1
  # read the cut back: no carrier on the container side
  local i
  for i in 1 2 3 4 5; do lab::mgmt_carrier "$node" || { log::info "$node cut from the management network (link down, read back)"; return 0; }; sleep 1; done
  log::error "$c's $ifc still carries after its host peer $peer was set down"; return 1
}

suite::mgmt_restore() {
  local node="$1" i why
  [[ -n "${SUITE_CUT[$node]:-}" ]] || return 0
  gate::run "SUITE.mgmt-reconnect.${node}" -- "${IP:-ip}" link set "${SUITE_CUT[$node]}" up >/dev/null || return 1
  for i in $(seq 1 "${SUITE_RESTORE_WAIT:-60}"); do
    if why="$(lab::mgmt_reachable "$node")"; then
      gate::run "SUITE.mgmt-readback.${node}" -- lab::mgmt_link "$node" >/dev/null || true
      unset "SUITE_CUT[$node]"
      log::info "$node's management data path restored (carrier + gNMI accept, read back)"
      return 0
    fi
    sleep 1
  done
  log::error "$node not reachable after restore: $why"; return 1
}

suite::_maint() {
  lab::kubectl -n "$FABRIC_NAMESPACE" get "$SUITE_FABRIC_RES" "$FABRIC_NAME" -o json | jq -c '.spec.maintenance // null'
}

suite::maint_add() {
  local node="$1" cur new; shift
  cur="$(suite::_maint)" || return 1
  if [[ -z "$SUITE_MAINT_SAVED" ]]; then SUITE_MAINT_SAVED="$cur"; suite::on_exit suite::maint_restore; fi
  new="$(jq -c --arg n "$node" --args '($ARGS.positional | map({node: $n, interface: ., adminState: "disable"})) as $add
    | ((. // []) | map(select(. as $e | $add | map(.node == $e.node and .interface == $e.interface) | any | not))) + $add' \
    "$@" <<<"$cur")"
  gate::run "SUITE.maintenance-add" -- lab::kubectl -n "$FABRIC_NAMESPACE" patch "$SUITE_FABRIC_RES" "$FABRIC_NAME" --type=merge \
    -p "$(jq -cn --argjson m "$new" '{spec: {maintenance: $m}}')" >/dev/null
}

suite::maint_restore() {
  [[ -n "$SUITE_MAINT_SAVED" ]] || return 0
  gate::run "SUITE.maintenance-restore" -- lab::kubectl -n "$FABRIC_NAMESPACE" patch "$SUITE_FABRIC_RES" "$FABRIC_NAME" --type=merge \
    -p "$(jq -cn --argjson m "$SUITE_MAINT_SAVED" '{spec: {maintenance: $m}}')" >/dev/null || return 1
  [[ "$(suite::_maint)" == "$SUITE_MAINT_SAVED" ]] || { log::error "Fabric.spec.maintenance did not read back as restored"; return 1; }
  SUITE_MAINT_SAVED=""
  log::info "Fabric.spec.maintenance restored and read back"
}

# suite::apply_macvrf <name> <vlan> <l2vni> — a mac-vrf spanning both leaves in SVC_NS
suite::apply_macvrf() {
  local name="$1" vlan="$2" vni="$3" f
  f="$EVIDENCE_DIR/suite-manifests/${name}.yaml"
  mkdir -p "${f%/*}"
  cat >"$f" <<YAML
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
metadata:
  name: ${name}
  namespace: ${SVC_NS}
spec:
  description: ${name} scratch mac-vrf vlan ${vlan} l2vni ${vni}
  bridgeDomains:
  - name: bd${vlan}
    vlan: ${vlan}
    l2vni: ${vni}
  attachments:
$(for l in $(lab::leaves); do printf '  - {node: %s, attachment: ethernet-1/1, vlan: %s}\n' "$l" "$vlan"; done)
YAML
  gate::run "SUITE.apply.${name}" --attach "suite-manifests/${name}.yaml" -- lab::kubectl apply -f "$f" >/dev/null
}

suite::finish() {
  if [[ ${#SUITE_FAILS[@]} -gt 0 ]]; then
    log::error "$1 FAILED: ${SUITE_FAILS[*]} (evidence: $EVIDENCE_DIR)"; return 1
  fi
  log::info "$1 passed (evidence: $EVIDENCE_DIR)"
}
