#!/usr/bin/env bash
# tests/integration/acl_enforcement_probe.sh — SC-041: the access lists this platform writes are
# ENFORCED by the device, per qualified direction (T114; quickstart.md §12 "The enforcement probe";
# contracts/acl-render-contract.md §4.7; SC-041, SC-040, FR-042, NFR-013; AD-82 decision
# 2026-09-21-acl-binding-state — A4 is per-entry matched-packets moved by traffic that can only meet
# this filter on its binding).
#
# Behind `make test-acl-enforcement`. Acceptance, never readiness: nothing here feeds a condition.
#
# The directions probed are read from the qualification record agentic-netops-system/
# fabric-qualification (`acl.ingress-ipv4`, `acl.egress`); a direction the record does not show
# qualified is SKIPPED with that reason (never probed, never failed); no qualified direction at
# all refuses the run (exit 3).
#
# A scratch Network pair — platform objects in agentic-netops-services, named as the platform names
# (no vt-scratch- prefix: they are Networks the provider renders like any other, and the exit trap
# removes them):
#   acl-probe-svc     mac-vrf VLAN AP_VLAN (360, naming band, used by no example or other suite)
#                     L2VNI AP_VNI (10360) on leaf01 and leaf02 ethernet-1/1, carrying the INGRESS
#                     ipv4 list (filter acl-acl-probe-svc-ingress, bound input on both leaves):
#                       10 deny   icmp to AP_IN_DENY  (client02 .21)
#                       20 permit icmp to AP_IN_PERMIT (client02 .22)
#                       30 deny   tcp port 23          (never met by the probes)
#                       65535 default permit
#   acl-probe-egress  a standalone acl on leaf02 ethernet-1/1.360 (the subinterface acl-probe-svc
#                     creates), the EGRESS ipv4 list (filter acl-acl-probe-egress-egress, output):
#                       10 deny   icmp to AP_EG_DENY  (client02 .23)
#                       20 permit icmp to AP_EG_PERMIT (client02 .24)
#                       30 deny   tcp port 23
#                       65535 default permit
# client01 (behind leaf01) is 10.36.0.11/24 on eth1.360; client02 (behind leaf02) carries .21–.24 on
# eth1.360 — both brought up by the endpoint's own /setup.sh (MTU 9348); the addresses, and the
# eth1.360 links when this run created them, are removed by the exit trap.
#
# Order (NFR-013): leftovers::scan and "no acl-probe-* Network exists" first; apply; AP-ready's
# control (a Network that does not exist) then Ready=True; then EVERY other check's negative control
# recorded failing before any pass of it:
#   AP-applied  tests/gate/lib/checks.sh acl_applied  (a) stock spine01, real filter (b) leaf, a
#               filter that does not exist
#   AP-deny     "100% loss" — to the address that answers (AP_IN_PERMIT)
#   AP-permit   "answered"  — to an address nobody holds (AP_NOBODY)
#   AP-delta    the counter check — (a) stock spine01, real filter (b) leaf, a filter that does not exist
#   AP-gone     the removal read-back — against the filter while it is still present
# then per qualified direction: keyed A1–A3 read-back; baseline matched-packets of exactly the
# entries the platform wrote (keyed name/type/sequence-id, per node); the denied probe (100% loss)
# and the permitted probe (answered), `ping -c 3 -i 0.5` — low rate, never a flood; after: the
# denied entry and the permitted entry moved by >= 3 and every other entry did NOT move:
#   ingress  leaf01 filter: 10 +3, 20 +3, 30 unmoved, 65535 unmoved
#            leaf02 filter: 10, 20, 30 unmoved; 65535 +3 (the echo replies of the permitted probe
#            enter leaf02 on its binding and match only the default entry)
#   egress   leaf02 filter: 10 +3, 20 +3, 30 unmoved, 65535 unmoved
# finally both Networks are deleted (the standalone list first), read back gone from the API, and
# each filter and its binding read back absent from running on every leaf.
#
# Usage: acl_enforcement_probe.sh [run]
# Environment: EVIDENCE_DIR, CLUSTER_NAME, LAB_NAME, SRL_USER, SRL_PASS (required), AP_VLAN (360),
#   AP_VNI (10360), AP_WAIT (240 s: Ready, and the re-read window of a positive device check),
#   AP_COUNTER_WAIT (30 s: counters refresh with a lag), AP_NEG_WAIT (10 s), AP_DELETE_WAIT (240 s),
#   DOCKER / KUBECTL / GNMIC overrides (tests put fakes on PATH).
# Exit: 0 every probed direction enforced; 1 a check failed (named); 2 usage; 3 refused (leftovers,
#   a probe Network already present, no qualified direction, a negative control that passed).
set -euo pipefail

AP_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AP_ROOT="$(cd -- "$AP_HERE/../.." && pwd)"
AP_SELF="$AP_HERE/$(basename -- "${BASH_SOURCE[0]}")"
AP_LIB="$AP_HERE/lib/acl.sh"
AP_SV="$AP_HERE/lib/services.sh"
AP_CHECKS="$AP_ROOT/tests/gate/lib/checks.sh"
# shellcheck source=lib/acl.sh
source "$AP_LIB"
# shellcheck source=../../scripts/lib/log.sh
source "$AP_ROOT/scripts/lib/log.sh"
# shellcheck source=../../scripts/lib/evidence.sh
source "$AP_ROOT/scripts/lib/evidence.sh"
LOG_PHASE="${LOG_PHASE:-acl-enforcement}"

: "${AP_VLAN:=360}" "${AP_VNI:=10360}"
: "${AP_WAIT:=240}" "${AP_COUNTER_WAIT:=30}" "${AP_NEG_WAIT:=10}" "${AP_DELETE_WAIT:=240}"
AP_NS="agentic-netops-services"
AP_QUAL_NS="agentic-netops-system"
AP_SVC="acl-probe-svc"
AP_EGR="acl-probe-egress"
AP_PORT="ethernet-1/1"
AP_IFID="${AP_PORT}.${AP_VLAN}"
AP_IN_FILTER="acl-${AP_SVC}-ingress"
AP_EG_FILTER="acl-${AP_EGR}-egress"
AP_SEQS="10,20,30,65535"
AP_STOCK_NODE="spine01"
AP_ABSENT_FILTER="acl-does-not-exist-ingress"
AP_NET="10.36.0"
AP_C1="${AP_NET}.11"
AP_IN_DENY="${AP_NET}.21"; AP_IN_PERMIT="${AP_NET}.22"
AP_EG_DENY="${AP_NET}.23"; AP_EG_PERMIT="${AP_NET}.24"
AP_NOBODY="${AP_NET}.99"
AP_FAILS=()
AP_SKIPS=()
AP_UNDO=()            # client-side undo commands, newest first
AP_APPLIED=()         # Networks this run created (the trap deletes them, standalone first)
AP_DIRS=""            # the qualified directions probed: "ingress egress"

usage() { sed -n '/^# Usage:/,/^set -euo/p' "$AP_SELF" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }
ap::fail() { AP_FAILS+=("$1"); log::error "FAIL $1"; }
ap::ok()   { log::info "PASS $1"; }
ap::id() {
  local stem id n=1
  stem="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
  id="$stem"
  while [[ -e "$EVIDENCE_DIR/$id.json" ]]; do n=$((n + 1)); id="${stem}-${n}"; done
  printf '%s' "$id"
}
ap::k() { lab::kubectl "$@"; }

# ap::neg <check-id> <what> -- <cmd…>: MUST fail; a pass refuses the run
ap::neg() {
  local chk="$1" what="$2" rc=0; shift 3
  evidence_negative_control "$chk" -- "$@" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) log::info "negative control $chk failed as it must: $what" ;;
    4) log::error "negative control $chk PASSED ($what): the check is defective — no pass of it is admitted"; return 3 ;;
    *) log::error "negative control $chk could not be recorded (exit $rc): $what"; return 3 ;;
  esac
}
# ap::chk <check-id> <what> <stem> -- <cmd…>: a readiness-flagged, run-captured pass (0/1)
ap::chk() {
  local chk="$1" what="$2" id rc=0; id="$(ap::id "$3")"; shift 4
  evidence_run "$id" --check "$chk" --readiness --records SC-041 -- "$@" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then ap::ok "$what"; return 0; fi
  ap::fail "$what [evidence $id]"
  grep '^CHECK ' "$EVIDENCE_DIR/${id}.stdout" 2>/dev/null | tail -n 2 | sed 's/^/    | /' >&2 || true
  return 1
}

# ---------------------------------------------------------------- manifests

ap::rules() { # <deny-dst> <permit-dst>
  cat <<EOF
    defaultAction: permit
    rules:
    - {name: probe-deny, priority: 10, action: deny, protocol: icmp, destinationPrefix: "$1/32"}
    - {name: probe-permit, priority: 20, action: permit, protocol: icmp, destinationPrefix: "$2/32"}
    - {name: never-hit-telnet, priority: 30, action: deny, protocol: tcp, destinationPort: "23"}
EOF
}
ap::manifest_svc() { # [with-ingress]
  cat <<EOF
# SC-041 enforcement probe (tests/integration/acl_enforcement_probe.sh): removed by its exit trap
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
metadata:
  name: ${AP_SVC}
  namespace: ${AP_NS}
spec:
  description: acl enforcement probe mac-vrf vlan ${AP_VLAN} across leaf01 and leaf02
  bridgeDomains:
  - name: bd${AP_VLAN}
    vlan: ${AP_VLAN}
    l2vni: ${AP_VNI}
EOF
  if [[ "${1:-}" == with-ingress ]]; then
    printf '  accessLists:\n  - name: %s-ingress\n    stage: ingress\n    type: ipv4\n' "$AP_SVC"
    ap::rules "$AP_IN_DENY" "$AP_IN_PERMIT"
  fi
  cat <<EOF
  attachments:
  - {node: leaf01, attachment: ${AP_PORT}, vlan: ${AP_VLAN}}
  - {node: leaf02, attachment: ${AP_PORT}, vlan: ${AP_VLAN}}
EOF
}
ap::manifest_egress() {
  cat <<EOF
# SC-041 enforcement probe (tests/integration/acl_enforcement_probe.sh): removed by its exit trap
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
metadata:
  name: ${AP_EGR}
  namespace: ${AP_NS}
spec:
  description: acl enforcement probe egress list on leaf02 ${AP_IFID}
  accessLists:
  - name: ${AP_EGR}-egress
    stage: egress
    type: ipv4
EOF
  ap::rules "$AP_EG_DENY" "$AP_EG_PERMIT"
  cat <<EOF
  attachments:
  - {node: leaf02, attachment: ${AP_PORT}, vlan: ${AP_VLAN}}
EOF
}

# ---------------------------------------------------------------- client plumbing (tests/ only)

ap::cexec() { local c="$1"; shift; lab::docker exec "$(lab::container "$c")" "$@"; }
ap::undo() { AP_UNDO=("$*" "${AP_UNDO[@]}"); }

ap::client() { # <client> <addr/len…>: eth1.<vlan> through the endpoint's own /setup.sh, addresses added
  local c="$1" a; shift
  if ! ap::cexec "$c" ip link show dev "eth1.${AP_VLAN}" >/dev/null 2>&1; then
    ap::undo "ap::remove_link $c eth1.${AP_VLAN}"
  fi
  ap::cexec "$c" sh /setup.sh "$AP_VLAN" >/dev/null
  for a in "$@"; do
    if ! ap::cexec "$c" ip addr show dev "eth1.${AP_VLAN}" 2>/dev/null | grep -q " ${a} "; then
      ap::cexec "$c" ip addr add "$a" dev "eth1.${AP_VLAN}"
      ap::undo "ap::cexec $c ip addr del $a dev eth1.${AP_VLAN}"
    fi
  done
}
ap::remove_link() {
  ap::cexec "$1" ip link del "$2" || true
  if ap::cexec "$1" ip link show dev "$2" >/dev/null 2>&1; then log::error "$2 still present on $1 after removal"; return 1; fi
  log::info "$2 removed from $1 (read back absent)"
}

# ---------------------------------------------------------------- the Networks

ap::apply() { # <name> <manifest-file>
  local id; id="$(ap::id "AP.apply.$1")"
  AP_APPLIED=("$1" "${AP_APPLIED[@]}")   # newest first: the standalone list is removed first
  evidence_run "$id" --attach "${2#"$EVIDENCE_DIR"/}" -- ap::k apply -f "$2" >/dev/null 2>&1 \
    || { ap::fail "apply $AP_NS/$1 refused or failed [evidence $id]"; tail -n 3 "$EVIDENCE_DIR/$id.stderr" >&2 || true; return 1; }
  log::info "applied $AP_NS/$1"
}

ap::delete() { # <name> — delete, wait, read back gone from the API (run-captured)
  local n="$1" id
  id="$(ap::id "AP.delete.$n")"
  evidence_run "$id" -- ap::k -n "$AP_NS" delete networks.fabric.agentic-netops.io "$n" \
    --ignore-not-found --wait=true --timeout="${AP_DELETE_WAIT}s" >/dev/null 2>&1 || true
  id="$(ap::id "AP.deleted.$n")"
  if evidence_run "$id" -- env CHECK_WAIT="$AP_DELETE_WAIT" bash "$AP_SV" gone "$AP_NS" networks.fabric.agentic-netops.io "$n" >/dev/null 2>&1; then
    local -a keep=(); local x
    for x in "${AP_APPLIED[@]}"; do [[ "$x" == "$n" ]] || keep+=("$x"); done
    AP_APPLIED=("${keep[@]}")
    log::info "$AP_NS/$n deleted (read back gone)"; return 0
  fi
  log::error "$AP_NS/$n still exists after ${AP_DELETE_WAIT}s [evidence $id]"; return 1
}

ap::cleanup() {
  local rc=$? n u
  set +e
  for n in "${AP_APPLIED[@]}"; do
    log::info "exit trap: removing $AP_NS/$n"
    ap::delete "$n" || rc=1
  done
  for u in "${AP_UNDO[@]}"; do eval "$u" >/dev/null 2>&1; done
  AP_UNDO=()
  exit "$rc"
}

# ---------------------------------------------------------------- phases

ap::qualification() {
  local id cm
  id="$(ap::id AP.qualification)"
  cm="$(evidence_run "$id" -- ap::k -n "$AP_QUAL_NS" get configmap fabric-qualification -o json 2>/dev/null)" \
    || { log::error "the qualification record $AP_QUAL_NS/fabric-qualification is not readable [evidence $id]"; return 3; }
  q() { jq -r --arg k "$1" '.data[$k] // "absent"' <<<"$cm"; }
  if [[ "$(q acl)" != qualified ]]; then log::error "construct acl is $(q acl) in the qualification record"; return 3; fi
  if [[ "$(q acl.ingress-ipv4)" == qualified ]]; then AP_DIRS+=" ingress"
  else AP_SKIPS+=("ingress: acl.ingress-ipv4 is $(q acl.ingress-ipv4) in $AP_QUAL_NS/fabric-qualification"); fi
  if [[ "$(q acl.egress)" == qualified && -n "${ACL_PROBE_EGRESS_EXCLUDED:-}" ]]; then
    # Qualified on the device (G9) but excluded from this run BY NAME, with the stated reason, which the
    # run prints and keeps as a SKIP: never a pass, never silent (the reason is the operator's to state).
    AP_SKIPS+=("egress: qualified in $AP_QUAL_NS/fabric-qualification but EXCLUDED from this run: ${ACL_PROBE_EGRESS_EXCLUDED}")
  elif [[ "$(q acl.egress)" == qualified ]]; then AP_DIRS+=" egress"
  else AP_SKIPS+=("egress: acl.egress is $(q acl.egress) in $AP_QUAL_NS/fabric-qualification"); fi
  local s; for s in "${AP_SKIPS[@]}"; do log::warn "SKIP $s"; done
  [[ -n "$AP_DIRS" ]] || { log::error "no access-list direction is qualified: SC-041 cannot be probed"; return 3; }
  log::info "qualified directions probed:${AP_DIRS}"
}

ap::has() { [[ " $AP_DIRS " == *" $1 "* ]]; }

# ap::baseline <node> <filter> — "seq:value" terms of every entry the platform wrote (keyed)
ap::baseline() {
  local id out
  id="$(ap::id "AP.baseline.$1.$2")"
  out="$(evidence_run "$id" --check AP-delta -- bash "$AP_LIB" counters "$1" "$2" ipv4 "$AP_SEQS" 2>/dev/null)" || true
  awk '{print $1 ":" $2}' <<<"$out" | tr '\n' ' '
}
# ap::terms <baseline-terms> <seq=min…> — "<seq>:<baseline>:<min>" per entry
ap::terms() {
  local base="$1" t s b m out=""; shift
  for t in "$@"; do
    s="${t%%=*}"; m="${t#*=}"
    b="$(tr ' ' '\n' <<<"$base" | awk -F: -v s="$s" '$1 == s {print $2}')"
    out+="${s}:${b:-null}:${m} "
  done
  printf '%s' "$out"
}

ap::controls() {
  log::phase ACLEnforcementNegativeControls
  local f leaf=leaf01
  if ap::has ingress; then f="$AP_IN_FILTER"; else f="$AP_EG_FILTER"; leaf=leaf02; fi
  local dir=input; ap::has ingress || dir=output
  ap::neg AP-applied "stock $AP_STOCK_NODE ${f}/ipv4" -- env CHECK_WAIT="$AP_NEG_WAIT" bash "$AP_CHECKS" acl_applied "$AP_STOCK_NODE" "$f" ipv4 "$AP_IFID" "$dir" "$AP_SEQS" || return 3
  ap::neg AP-applied "$leaf ${AP_ABSENT_FILTER}/ipv4" -- env CHECK_WAIT="$AP_NEG_WAIT" bash "$AP_CHECKS" acl_applied "$leaf" "$AP_ABSENT_FILTER" ipv4 "$AP_IFID" "$dir" "$AP_SEQS" || return 3
  local answers="$AP_IN_PERMIT"; ap::has ingress || answers="$AP_EG_PERMIT"
  ap::neg AP-deny "100% loss to $answers, which answers" -- env CHECK_WAIT=0 bash "$AP_LIB" ping client01 "$answers" fail || return 3
  ap::neg AP-permit "an answer from $AP_NOBODY, which nobody holds" -- env CHECK_WAIT=0 bash "$AP_LIB" ping client01 "$AP_NOBODY" ok || return 3
  ap::neg AP-delta "stock $AP_STOCK_NODE ${f}/ipv4 entry 10" -- env CHECK_WAIT="$AP_NEG_WAIT" bash "$AP_LIB" delta "$AP_STOCK_NODE" "$f" ipv4 10:0:1 || return 3
  ap::neg AP-delta "$leaf ${AP_ABSENT_FILTER}/ipv4 entry 10" -- env CHECK_WAIT="$AP_NEG_WAIT" bash "$AP_LIB" delta "$leaf" "$AP_ABSENT_FILTER" ipv4 10:0:1 || return 3
  ap::neg AP-gone "$leaf ${f}/ipv4 while it is present" -- env CHECK_WAIT=0 bash "$AP_LIB" gone "$leaf" "$f" ipv4 "$AP_IFID" "$dir" || return 3
}

# ap::direction <ingress|egress>
ap::direction() {
  local d="$1" f dir deny permit n b1 b2
  if [[ "$d" == ingress ]]; then f="$AP_IN_FILTER"; dir=input; deny="$AP_IN_DENY"; permit="$AP_IN_PERMIT"
  else f="$AP_EG_FILTER"; dir=output; deny="$AP_EG_DENY"; permit="$AP_EG_PERMIT"; fi
  log::phase "ACLEnforcement-${d}"
  local nodes="leaf01 leaf02"; [[ "$d" == egress ]] && nodes="leaf02"
  local ok=1
  for n in $nodes; do
    ap::chk AP-applied "$d: $n ${f}/ipv4 entries $AP_SEQS in TCAM on $dir only, bound $dir on $AP_IFID (A1–A3)" \
      "AP.applied.$n.$f" -- env CHECK_WAIT="$AP_WAIT" bash "$AP_CHECKS" acl_applied "$n" "$f" ipv4 "$AP_IFID" "$dir" "$AP_SEQS" || ok=0
  done
  [[ "$ok" == 1 ]] || { ap::fail "$d: the list is not applied; its probe is not run"; return 0; }
  b1="$(ap::baseline leaf01 "$f")"; b2="$(ap::baseline leaf02 "$f")"
  log::info "$d baseline matched-packets: leaf01 [$b1] leaf02 [$b2]"
  ap::chk AP-deny "$d: client01 → $deny denied by entry 10 (100% loss)" "AP.deny.$d" -- \
    env CHECK_WAIT=0 bash "$AP_LIB" ping client01 "$deny" fail || true
  ap::chk AP-permit "$d: client01 → $permit permitted by entry 20 (answered)" "AP.permit.$d" -- \
    env CHECK_WAIT="$AP_WAIT" bash "$AP_LIB" ping client01 "$permit" ok || true
  if [[ "$d" == ingress ]]; then
    # shellcheck disable=SC2046 # the terms are words by design
    ap::chk AP-delta "ingress: leaf01 ${f} — entries 10 and 20 moved, 30 and 65535 did not" "AP.delta.ingress.leaf01" -- \
      env CHECK_WAIT="$AP_COUNTER_WAIT" CHECK_INTERVAL=3 bash "$AP_LIB" delta leaf01 "$f" ipv4 $(ap::terms "$b1" 10=3 20=3 30=0 65535=0) || true
    # shellcheck disable=SC2046
    ap::chk AP-delta "ingress: leaf02 ${f} — only 65535 moved (the permitted probe's replies)" "AP.delta.ingress.leaf02" -- \
      env CHECK_WAIT="$AP_COUNTER_WAIT" CHECK_INTERVAL=3 bash "$AP_LIB" delta leaf02 "$f" ipv4 $(ap::terms "$b2" 10=0 20=0 30=0 65535=3) || true
  else
    # shellcheck disable=SC2046
    ap::chk AP-delta "egress: leaf02 ${f} — entries 10 and 20 moved, 30 and 65535 did not" "AP.delta.egress.leaf02" -- \
      env CHECK_WAIT="$AP_COUNTER_WAIT" CHECK_INTERVAL=3 bash "$AP_LIB" delta leaf02 "$f" ipv4 $(ap::terms "$b2" 10=3 20=3 30=0 65535=0) || true
  fi
}

ap::withdraw() {
  log::phase ACLEnforcementWithdrawal
  local n
  if ap::has egress; then ap::delete "$AP_EGR" || ap::fail "$AP_NS/$AP_EGR not removed"; fi
  ap::delete "$AP_SVC" || ap::fail "$AP_NS/$AP_SVC not removed"
  for n in leaf01 leaf02; do
    if ap::has ingress; then
      ap::chk AP-gone "$n: ${AP_IN_FILTER}/ipv4 and its input binding on $AP_IFID gone from running" "AP.gone.$n.$AP_IN_FILTER" -- \
        env CHECK_WAIT="$AP_WAIT" bash "$AP_LIB" gone "$n" "$AP_IN_FILTER" ipv4 "$AP_IFID" input || true
    fi
  done
  if ap::has egress; then
    ap::chk AP-gone "leaf02: ${AP_EG_FILTER}/ipv4 and its output binding on $AP_IFID gone from running" "AP.gone.leaf02.$AP_EG_FILTER" -- \
      env CHECK_WAIT="$AP_WAIT" bash "$AP_LIB" gone leaf02 "$AP_EG_FILTER" ipv4 "$AP_IFID" output || true
  fi
}

ap::run() {
  evidence::ensure_dir || return 3
  lab::export_creds || return 3
  # shellcheck source=../lib/leftovers.sh
  source "$AP_ROOT/tests/lib/leftovers.sh"
  if ! leftovers::scan; then log::error "acl enforcement probe REFUSED to start: leftovers present (listed above)"; return 3; fi
  local n
  for n in "$AP_SVC" "$AP_EGR"; do
    if ap::k -n "$AP_NS" get networks.fabric.agentic-netops.io "$n" -o name >/dev/null 2>&1; then
      log::error "REFUSED: Network $AP_NS/$n already exists (a previous probe's leftover?) — delete it explicitly first:" \
        "kubectl --context kind-${CLUSTER_NAME:-agentic-netops} -n $AP_NS delete networks.fabric.agentic-netops.io $n"
      return 3
    fi
  done
  ap::qualification || return 3
  trap ap::cleanup EXIT
  trap 'exit 130' INT TERM

  # the endpoints
  ap::client client01 "${AP_C1}/24"
  ap::client client02 "${AP_IN_DENY}/24" "${AP_IN_PERMIT}/24" "${AP_EG_DENY}/24" "${AP_EG_PERMIT}/24"

  # the Networks (the service first: the standalone list binds on the subinterface it creates)
  local dir="$EVIDENCE_DIR/acl-probe"; mkdir -p "$dir"
  if ap::has ingress; then ap::manifest_svc with-ingress >"$dir/$AP_SVC.yaml"; else ap::manifest_svc >"$dir/$AP_SVC.yaml"; fi
  ap::apply "$AP_SVC" "$dir/$AP_SVC.yaml" || return 1
  if ap::has egress; then
    ap::manifest_egress >"$dir/$AP_EGR.yaml"
    ap::apply "$AP_EGR" "$dir/$AP_EGR.yaml" || return 1
  fi

  ap::neg AP-ready "a Network that does not exist" -- env CHECK_WAIT=0 bash "$AP_SV" condition "$AP_NS" acl-does-not-exist Ready True || return 3
  local ready=1
  for n in "${AP_APPLIED[@]}"; do
    ap::chk AP-ready "$AP_NS/$n Ready=True" "AP.ready.$n" -- env CHECK_WAIT="$AP_WAIT" bash "$AP_SV" condition "$AP_NS" "$n" Ready True || ready=0
  done
  [[ "$ready" == 1 ]] || { log::error "the probe Networks did not converge: no probe run"; return 1; }

  # warm-up (not a check): ARP/MAC learning across the mac-vrf before the one-shot controls
  local id; id="$(ap::id AP.warmup)"
  evidence_run "$id" -- env CHECK_WAIT=60 bash "$AP_LIB" ping client01 "$( ap::has ingress && echo "$AP_IN_PERMIT" || echo "$AP_EG_PERMIT")" ok >/dev/null 2>&1 \
    || log::warn "warm-up ping did not answer within 60 s [evidence $id] (the checks decide)"

  ap::controls || { log::error "acl enforcement probe REFUSED: a negative control passed or was not recorded (evidence: $EVIDENCE_DIR)"; return 3; }
  ap::has ingress && ap::direction ingress
  ap::has egress && ap::direction egress
  ap::withdraw
  local s; for s in "${AP_SKIPS[@]}"; do log::warn "SKIPPED $s"; done
  if [[ ${#AP_FAILS[@]} -gt 0 ]]; then
    log::error "acl enforcement probe FAILED (${#AP_FAILS[@]}): ${AP_FAILS[*]}"
    return 1
  fi
  log::info "acl enforcement probe passed for:${AP_DIRS} (evidence: $EVIDENCE_DIR)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-run}" in
    run) [[ $# -le 1 ]] || usage; ap::run ;;
    *) usage ;;
  esac
fi
