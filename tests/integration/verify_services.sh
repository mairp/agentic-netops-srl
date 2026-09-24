#!/usr/bin/env bash
# shellcheck disable=SC2015
# tests/integration/verify_services.sh — the ROUTE half of SC-004, keyed per service (T064; SC-004,
# SC-044, FR-100, NFR-013; AD-23, AD-31, AD-43, AD-77, R-46).
#
# Behind `make verify-services`. With the example Networks applied and Ready:
#   the Type-2 and Type-3 routes of every mac-vrf spanning both leaves, and the Type-5 route of
#   each ip-vrf prefix in both address families, received on every OTHER leaf of the service
#   THROUGH A REFLECTING SPINE — each keyed to the service by its route distinguisher
#   (<originating VTEP>:<evi>, evi := vni; SR Linux auto-derives it) and, for Type 5, by prefix.
#
# Preceded by its negative control, a DECLARATIVE fault and never a device-side edit (AD-43):
# Fabric.spec.overlay.reflectorClients is patched to false (AD-77 — the field T186 admits as THE
# reflection-stopping declarative fault; interASVPN stays a configuration-integrity case only), so
# the fabric reconciler renders `route-reflector client false` on both reflecting spines through
# the one southbound: every session stays established and nothing is reflected. Then
#   * the spanning service reports Ready=False/RoutesMissing within one re-verification interval
#     plus one reconciliation interval (SC-044; REVERIFY_INTERVAL overridden to SV_REVERIFY and
#     restored from the exit trap, as T167 does),
#   * meanwhile the Fabric reports Ready=False/NotConverged naming each reflecting spine and the
#     setting,
#   * the route checks are recorded as negative controls (they MUST fail with reflection off),
#   * the field is patched back — FROM THE EXIT TRAP, so it is restored whether the wait was met,
#     timed out or the script was interrupted; a control whose wait timed out fails the run after
#     restoring, never before — and the restoration is read back: the spines report route-reflector
#     client true, the Fabric and the service Ready=True again within the same bound,
# before the positive route assertions are admitted. The fault is recorded in declared-faults.json
# before it is made, and the suite starts with leftovers::scan (FR-108, AD-49).
#
# Usage: verify_services.sh [--no-control]   (--no-control only for a run whose EVIDENCE_DIR already
#                                              holds the failing route controls; refused otherwise)
# Environment: EVIDENCE_DIR, CLUSTER_NAME, LAB_NAME, SRL_USER, SRL_PASS, FABRIC_NAME,
#   SV_REVERIFY (30s — the test REVERIFY_INTERVAL, >= the provider's 30 s floor), SV_RECONCILE (15),
#   SV_BOUND_SLACK (30 s of API/rollout slack, recorded), SV_WAIT (180 s, the positive window),
#   SV_SPAN (lab-macvrf), SV_ROUTED (lab-ipvrf-a lab-ipvrf-b).
set -euo pipefail

VS_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/services.sh
source "$VS_HERE/lib/services.sh"
# shellcheck source=../gate/lib/gate.sh
source "$SV_ROOT/tests/gate/lib/gate.sh"
# shellcheck source=../lib/leftovers.sh
source "$SV_ROOT/tests/lib/leftovers.sh"

: "${SV_REVERIFY:=30s}"
: "${SV_RECONCILE:=15}"
: "${SV_BOUND_SLACK:=30}"
: "${SV_WAIT:=180}"
: "${SV_SPAN:=lab-macvrf}"
: "${SV_ROUTED:=lab-ipvrf-a lab-ipvrf-b}"
VS_LIB="$VS_HERE/lib/services.sh"
VS_DEPLOY="deploy/srl-provider"
VS_PROVIDER_NS="agentic-netops-system"
VS_FAILS=()
VS_ORIG_RC=""        # the Fabric's reflectorClients before the fault ("" = unset → true)
VS_ORIG_REVERIFY=""  # the provider's REVERIFY_INTERVAL before the override ("-" = unset)
VS_FAULTED=0
VS_OVERRIDDEN=0

vs::fail() { VS_FAILS+=("$1"); log::error "FAIL $1"; }
vs::ok()   { log::info "PASS $1"; }
usage() { echo "usage: $0 [--no-control]" >&2; return 2; }

vs::reverify_secs() { local v="${1%s}"; [[ "$1" == *m ]] && v=$(( ${1%m} * 60 )); printf '%s' "$v"; }
vs::bound() { printf '%s' $(( $(vs::reverify_secs "$SV_REVERIFY") + SV_RECONCILE + SV_BOUND_SLACK )); }

# ---------------------------------------------------------------- facts

vs::load() {
  local fj
  fj="$(sv::k -n "$FABRIC_NAMESPACE" get "$SV_FABRIC_RES" "$FABRIC_NAME" -o json)" || { log::error "Fabric $FABRIC_NAME not found"; return 1; }
  VS_NODES="$(jq -r '(.status.allocations // []) as $a | .spec.nodes[] | . as $n
    | ([$a[] | select(.node == $n.name and ((.purpose // "") | test("loopback|system")) and (.value // "") != "") | .value] | first
       // $n.systemIPv4 // "") as $lb | "\($n.name) \($n.role) \($lb | split("/")[0])"' <<<"$fj")"
  VS_RR="$(jq -r '(.spec.overlay.routeReflectors // [.spec.nodes[] | select(.routeReflector == true) | .name]) | join(" ")' <<<"$fj")"
  VS_ORIG_RC="$(jq -r '.spec.overlay.reflectorClients // "" | tostring' <<<"$fj")"
  log::info "Fabric $FABRIC_NAME: $(tr '\n' ';' <<<"$VS_NODES") reflectors: $VS_RR reflectorClients=${VS_ORIG_RC:-unset(true)}"
}
vs::lb() { awk -v n="$1" '$1 == n {print $3}' <<<"$VS_NODES"; }
vs::via() { local n o=""; for n in $VS_RR; do o+="${o:+,}$(vs::lb "$n")"; done; printf '%s' "$o"; }

# vs::expectations — "<receiver> <type> <rd> [<prefix>]" per service route, from the Networks' specs:
# every ordered pair of distinct attached leaves (originator a, receiver b)
vs::expectations() {
  local net nj leaves a b vni
  for net in $SV_SPAN; do
    nj="$(sv::k -n "$SV_NS" get "$SV_NET_RES" "$net" -o json)" || { echo "MISSING $net"; continue; }
    leaves="$(jq -r '[.spec.attachments[].node] | unique | .[]' <<<"$nj")"
    for vni in $(jq -r '.spec.bridgeDomains[]?.l2vni // empty' <<<"$nj"); do
      for a in $leaves; do for b in $leaves; do
        [[ "$a" == "$b" ]] && continue
        echo "$net $b 3 $(vs::lb "$a"):$vni"
        echo "$net $b 2 $(vs::lb "$a"):$vni"
      done; done
    done
  done
  for net in $SV_ROUTED; do
    nj="$(sv::k -n "$SV_NS" get "$SV_NET_RES" "$net" -o json)" || { echo "MISSING $net"; continue; }
    # declared prefixes are assigned one per attachment and family in (node, port, vlan) order
    jq -r '.spec.routers[] as $r
      | ([$r.prefixes[] | select(test(":") | not)]) as $v4 | ([$r.prefixes[] | select(test(":"))]) as $v6
      | [.spec.attachments[] | select(.vrf == $r.name)] | sort_by(.node, .attachment, .vlan) | to_entries[]
      | "\(.value.node) \($r.l3vni) \($v4[.key] // "") \($v6[.key] // "")"' <<<"$nj" \
    | while read -r a vni p4 p6; do
        for b in $(jq -r '[.spec.attachments[].node] | unique | .[]' <<<"$nj"); do
          [[ "$a" == "$b" ]] && continue
          [[ -z "$p4" ]] || echo "$net $b 5 $(vs::lb "$a"):$vni $p4"
          [[ -z "$p6" ]] || echo "$net $b 5 $(vs::lb "$a"):$vni $p6"
        done
      done
  done
}

# ---------------------------------------------------------------- the declarative fault

vs::set_reflector_clients() {
  local v="$1"
  gate::run "VS.fabric.reflectorClients-${v}" -- sv::k -n "$FABRIC_NAMESPACE" patch "$SV_FABRIC_RES" "$FABRIC_NAME" \
    --type merge -p "{\"spec\":{\"overlay\":{\"reflectorClients\":${v}}}}"
}

vs::restore() {
  local rc=0
  if [[ "$VS_FAULTED" == 1 ]]; then
    log::info "restoring Fabric.spec.overlay.reflectorClients=${VS_ORIG_RC:-true} (exit trap)"
    if [[ -z "$VS_ORIG_RC" ]]; then
      gate::run "VS.fabric.reflectorClients-restore" -- sv::k -n "$FABRIC_NAMESPACE" patch "$SV_FABRIC_RES" "$FABRIC_NAME" \
        --type json -p '[{"op":"remove","path":"/spec/overlay/reflectorClients"}]' || rc=1
    else vs::set_reflector_clients "$VS_ORIG_RC" || rc=1; fi
    [[ "$rc" == 0 ]] && VS_FAULTED=0
  fi
  if [[ "$VS_OVERRIDDEN" == 1 ]]; then
    log::info "restoring REVERIFY_INTERVAL=${VS_ORIG_REVERIFY} (exit trap)"
    if [[ "$VS_ORIG_REVERIFY" == "-" ]]; then
      gate::run "VS.reverify-restore" -- sv::k -n "$VS_PROVIDER_NS" set env "$VS_DEPLOY" REVERIFY_INTERVAL- || rc=1
    else gate::run "VS.reverify-restore" -- sv::k -n "$VS_PROVIDER_NS" set env "$VS_DEPLOY" "REVERIFY_INTERVAL=${VS_ORIG_REVERIFY}" || rc=1; fi
    sv::k -n "$VS_PROVIDER_NS" rollout status "$VS_DEPLOY" --timeout=180s >&2 || rc=1
    [[ "$rc" == 0 ]] && VS_OVERRIDDEN=0
  fi
  return "$rc"
}

vs::on_exit() {
  local st=$?
  vs::restore || { log::error "RESTORE FAILED — reflectorClients / REVERIFY_INTERVAL may still be faulted; see $EVIDENCE_DIR/declared-faults.json"; st=1; }
  exit "$st"
}

vs::override_reverify() {
  VS_ORIG_REVERIFY="$(sv::k -n "$VS_PROVIDER_NS" get "$VS_DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REVERIFY_INTERVAL")].value}')"
  VS_ORIG_REVERIFY="${VS_ORIG_REVERIFY:--}"
  VS_OVERRIDDEN=1
  gate::run "VS.reverify-override" -- sv::k -n "$VS_PROVIDER_NS" set env "$VS_DEPLOY" "REVERIFY_INTERVAL=${SV_REVERIFY}" || return 1
  sv::k -n "$VS_PROVIDER_NS" rollout status "$VS_DEPLOY" --timeout=180s >&2
}

vs::control() {
  local bound spine rc net node t rd p
  bound="$(vs::bound)"
  if ! leftovers::scan; then
    log::error "verify-services REFUSED to start: leftovers present (listed above)"; return 3
  fi
  trap vs::on_exit EXIT
  trap 'exit 130' INT TERM
  vs::override_reverify || { vs::fail "REVERIFY_INTERVAL override did not roll out"; return 1; }
  # everything Ready before the fault, so the transition observed is the fault's
  for net in $SV_SPAN $SV_ROUTED; do
    CHECK_WAIT="$SV_WAIT" gate::run "VS.pre-ready.${net}" -- bash "$VS_LIB" condition "$SV_NS" "$net" Ready True \
      || { vs::fail "$net not Ready=True before the control"; return 1; }
  done
  for spine in $VS_RR; do
    leftovers::declare_fault "VS.reflectorClients.${spine}" "$spine" \
      "Fabric ${FABRIC_NAMESPACE}/${FABRIC_NAME} spec.overlay.reflectorClients=false (declarative, AD-77)" \
      "{\"kind\":\"device-leaf\",\"node\":\"${spine}\",\"path\":\"/network-instance[name=default]/protocols/bgp/group[group-name=overlay]/route-reflector/client\",\"faulted_value\":false}" \
      "{\"kind\":\"fabric-patch\",\"field\":\"spec.overlay.reflectorClients\",\"value\":${VS_ORIG_RC:-true}}" \
      || { vs::fail "declared-faults.json not written; fault not made"; return 1; }
  done
  VS_FAULTED=1
  vs::set_reflector_clients false || { vs::fail "reflectorClients=false patch"; return 1; }
  local t0; t0="$(date +%s)"
  # the spanning service reports RoutesMissing within the bound
  for net in $SV_SPAN; do
    rc=0; CHECK_WAIT="$bound" gate::run "VS.control.routes-missing.${net}" -- \
      bash "$VS_LIB" condition "$SV_NS" "$net" Ready False RoutesMissing || rc=$?
    [[ "$rc" -eq 0 ]] && vs::ok "$net Ready=False/RoutesMissing $(( $(date +%s) - t0 ))s after the fault (bound ${bound}s)" \
      || vs::fail "$net did not report Ready=False/RoutesMissing within ${bound}s of reflectorClients=false"
  done
  # meanwhile the Fabric names each reflecting spine and the setting
  local -a names=(); for spine in $VS_RR; do names+=("$spine"); done
  rc=0; CHECK_WAIT="$bound" gate::run "VS.control.fabric-notconverged" -- \
    bash "$VS_LIB" fabric_condition Ready False NotConverged "${names[@]}" "route-reflector" || rc=$?
  [[ "$rc" -eq 0 ]] && vs::ok "Fabric Ready=False/NotConverged naming ${names[*]} and route-reflector client" \
    || vs::fail "Fabric did not report Ready=False/NotConverged naming ${names[*]} and the setting"
  # the route checks, recorded as negative controls: with reflection off each MUST fail
  while read -r net node t rd p; do
    [[ "$net" == MISSING ]] && { vs::fail "Network $node missing"; continue; }
    rc=0; evidence_negative_control "VS-route-${net}-${node}-t${t}${p:+-${p//[^0-9a-f]/_}}" -- \
      bash "$VS_LIB" route "$node" "$t" "$rd" "$(vs::via)" "${p:-}" || rc=$?
    [[ "$rc" -eq 0 ]] || vs::fail "route negative control $net $node type-$t $rd $p (rc=$rc: passed with reflection off, or not recorded)"
  done < <(vs::expectations)
  # restore NOW (the trap stays armed for any failure after this point) and read it back
  local t1; t1="$(date +%s)"
  vs::restore || { vs::fail "restoration of reflectorClients"; return 1; }
  for spine in $VS_RR; do
    rc=0; CHECK_WAIT="$bound" gate::ready "VS.restore.reflector.${spine}" FV-reflector reflector "$spine" 2>/dev/null || rc=$?
    if [[ "$rc" -eq 3 ]]; then   # FV-reflector's own control not in this run: record it (a leaf reflects nothing)
      gate::negative FV-reflector reflector "$(awk '$2 == "leaf" {print $1; exit}' <<<"$VS_NODES")" || true
      rc=0; CHECK_WAIT="$bound" gate::ready "VS.restore.reflector.${spine}" FV-reflector reflector "$spine" || rc=$?
    fi
    [[ "$rc" -eq 0 ]] && vs::ok "$spine reads back route-reflector client true" || vs::fail "$spine did not read back route-reflector client true"
  done
  rc=0; CHECK_WAIT="$bound" gate::run "VS.restore.fabric-ready" -- bash "$VS_LIB" fabric_condition Ready True || rc=$?
  [[ "$rc" -eq 0 ]] || vs::fail "Fabric not Ready=True within ${bound}s of the restoration"
  for net in $SV_SPAN; do
    rc=0; CHECK_WAIT="$bound" gate::run "VS.restore.ready.${net}" -- bash "$VS_LIB" condition "$SV_NS" "$net" Ready True || rc=$?
    [[ "$rc" -eq 0 ]] && vs::ok "$net Ready=True $(( $(date +%s) - t1 ))s after the restoration" \
      || vs::fail "$net not Ready=True within ${bound}s of the restoration"
  done
}

vs::positive() {
  local net node t rd p rc
  while read -r net node t rd p; do
    [[ "$net" == MISSING ]] && continue
    rc=0; CHECK_WAIT="$SV_WAIT" evidence_run "$(gate::id "VS.route.${net}.${node}.t${t}")" \
      --check "VS-route-${net}-${node}-t${t}${p:+-${p//[^0-9a-f]/_}}" --records SC-004:route \
      -- bash "$VS_LIB" route "$node" "$t" "$rd" "$(vs::via)" "${p:-}" || rc=$?
    [[ "$rc" -eq 0 ]] && vs::ok "$net: $node received type-$t rd=$rd${p:+ $p} through a reflecting spine" \
      || vs::fail "$net: $node type-$t rd=$rd${p:+ $p} (rc=$rc)"
  done < <(vs::expectations)
}

# vs::learn_macs: a Type-2 route exists only while its MAC is learned, and a MAC ages out of the
# bridge table (300 s default) when its client is quiet. Before the positive assertion each
# client on the spanning mac-vrf pings the other across it (client-side traffic, no device
# session, nothing written to any device), so the Type-2 check reads a MAC that is live now
# rather than one a traffic run left minutes ago. SV_LEARN=0 skips it.
: "${SV_LEARN:=1}"
vs::learn_macs() {
  [[ "$SV_LEARN" == 1 ]] || return 0
  local vlan a b pair
  vlan="$(sv::k -n "$SV_NS" get "$SV_NET_RES" "$SV_SPAN" -o jsonpath='{.spec.bridgeDomains[0].vlan}' 2>/dev/null)" || return 0
  [[ -n "$vlan" ]] || return 0
  for pair in "client01 client02" "client02 client01"; do
    set -- $pair
    b="$("${DOCKER:-docker}" exec "clab-${LAB_NAME:-agentic-netops-fabric}-$2" ip -4 -o addr show dev "eth1.${vlan}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    [[ -n "$b" ]] || { log::info "learn: $2 has no eth1.${vlan} address; Type-2 relies on earlier traffic"; continue; }
    evidence_run "$(gate::id "VS.learn.$1.$vlan")" -- "${DOCKER:-docker}" exec "clab-${LAB_NAME:-agentic-netops-fabric}-$1" ping -c 3 -W 2 "$b" \
      || log::info "learn: $1 -> $b did not answer (the Type-2 check decides)"
  done
}

main() {
  local control=1
  case "${1:-}" in
    "") ;;
    --no-control) control=0 ;;
    *) usage; return 2 ;;
  esac
  log::phase ServicesVerified
  gate::init
  vs::load || return 1
  log::info "expectations: $(vs::expectations | tr '\n' ';')"
  if [[ "$control" == 1 ]]; then vs::control || true; fi
  if [[ ${#VS_FAILS[@]} -gt 0 ]]; then
    log::error "verify-services FAILED before the positive assertion (not admitted): ${VS_FAILS[*]}"
    return 1
  fi
  vs::learn_macs
  vs::positive
  if [[ ${#VS_FAILS[@]} -gt 0 ]]; then log::error "verify-services FAILED: ${VS_FAILS[*]}"; return 1; fi
  log::info "verify-services passed (evidence: $EVIDENCE_DIR)"
}

main "$@"
