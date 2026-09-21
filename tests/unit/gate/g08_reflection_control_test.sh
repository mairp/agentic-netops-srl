#!/usr/bin/env bash
# tests/unit/gate/g08_reflection_control_test.sh — G8's SC-004 negative control as amended by AD-77
# (T187, T045), offline: g08::negative and negctl::G8_reflector_clients_false are run with every
# device-facing gate function stubbed, so what is judged is the ADMISSION logic, not a device:
#   1  every step as it must be (routes reflected before, route-reflector client false applied,
#      withdrawal seen within the bounded wait, sessions up, every negative control FAILED) →
#      reflector-clients-false-stops-reflection passes, reflectorClientsFalseStopsReflection=true in
#      the item record and in the tracked observed file
#   2  one Type-2/3/5 check PASSED with client false (reflection not stopped) → the check FAILS with
#      "NOT observed", the observation is false — G8 fails; nothing is skipped
#   3  no route reflected before the change (the control would be vacuous) → FAILS
#   4  the route still held at the end of the withdrawal wait → FAILS
#   5  a session lost during the control (the stop is not reflection) → FAILS
#   6  the inter-as-vpn removal is RECORDED only: reflection continuing or not changes
#      interASVPNRemovedReflectionContinues, never the control's verdict
#   7  order: client false before the controls; inter-as-vpn removed while client is still false,
#      THEN client restored, THEN the observation, THEN inter-as-vpn put back
# shellcheck disable=SC2015  # `cond && ok … || bad …` is safe: ok always returns 0
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# shellcheck disable=SC2034  # read by the sourced gate scripts
__AGENTIC_NETOPS_TESTS_GATE_SH=1   # the real gate plumbing is replaced by the stubs below
# shellcheck source=../../gate/negative_controls.sh
source "$ROOT/tests/gate/negative_controls.sh"
# shellcheck source=../../gate/g08_evpn.sh
source "$ROOT/tests/gate/g08_evpn.sh"

# ------------------------------------------------------------------ stubs
# shellcheck disable=SC2034  # read by the sourced g08::negative
{
  GATE_CHECKS=/bin/true; GATE_WAIT_ROUTES=1; GATE_WAIT_WITHDRAW=1; GATE_WAIT_NEG=1; G8_DEGRADED=0
  SCRATCH_GW4=203.0.113.1/26; SCRATCH_IPVRF=vt-scratch-ipvrf
}
lab::leaves()  { printf 'leaf01\nleaf02\n'; }
lab::spines()  { printf 'spine01\nspine02\n'; }
lab::devices() { printf 'spine01\nspine02\nleaf01\nleaf02\n'; }
lab::clients() { printf 'client01\nclient02\n'; }
lab::is_spine() { [[ "$1" == spine* ]]; }
scratch::loopback() { case "$1" in leaf01) echo 10.0.0.1 ;; leaf02) echo 10.0.0.2 ;; spine01) echo 10.0.0.11 ;; *) echo 10.0.0.12 ;; esac; }
scratch::spine_loopbacks_csv() { echo 10.0.0.11,10.0.0.12; }
scratch::leaf_loopbacks_csv() { echo 10.0.0.1,10.0.0.2; }
scratch::leaf_index() { echo "${1#leaf0}"; }
scratch::client_addr4() { echo 203.0.113.11; }
scratch::inter_as_vpn_updates() { printf '%s\t%s\n' "/iav" true; }
scratch::reflector_client_updates() { printf '%s\t%s\n' "/rrc" "$1"; }
scratch::apply() { echo "apply $1 $2 $("$3" "${@:4}" | cut -f2)" >>"$TMP/calls"; return 0; }
gate::dev() { echo "dev $1" >>"$TMP/calls"; return 0; }
# gate::record <id> <CHECK> … — the scenario decides the rc per CHECK
gate::record() { echo "record $2" >>"$TMP/calls"; case "$2" in
  G8-control-precondition) return "${RC_PRE:-0}" ;;
  G8-control-withdrawn)    return "${RC_WITHDRAWN:-0}" ;;
  G8-sessions)             return "${RC_SESSIONS:-0}" ;;
  G8-obs-no-inter-as-vpn)  return "${RC_OBS:-0}" ;;
  *) return 0 ;; esac; }
# gate::negative <CHECK> … — 0: failed as it must; 4: PASSED (the control did not hold)
gate::negative() { echo "negative $1" >>"$TMP/calls"; [[ "$1" == "${NEG_PASSES:-none}" ]] && return 4; return 0; }
gate::item_check() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$TMP/checks"; }
gate::item_observe() { printf '%s\t%s\n' "$1" "$2" >>"$TMP/obs"; }
gate::observed() { printf '%s' "$2" >"$TMP/observed-$1"; }

run() { : >"$TMP/calls"; : >"$TMP/checks"; : >"$TMP/obs"; rm -f "$TMP"/observed-*; ( g08::negative ) >/dev/null 2>&1; }
verdict() { awk -F'\t' '$1 == "reflector-clients-false-stops-reflection" {print $2}' "$TMP/checks"; }
obs() { awk -F'\t' -v k="$1" '$1 == k {print $2}' "$TMP/obs"; }

# 1
run
if [[ "$(verdict)" == 0 && "$(obs reflectorClientsFalseStopsReflection)" == true ]] \
   && jq -e '.reflectorClientsFalseStopsReflection == true' "$TMP/observed-reflection-control.json" >/dev/null 2>&1; then
  ok "1 control observed: admitted, recorded true in the item and the observed file"
else bad "1 control observed: verdict=$(verdict) obs=$(obs reflectorClientsFalseStopsReflection)"; fi
for c in G8-type3 G8-type2 G8-type5-v4 G8-type5-v6 G8-t5-installed G8-received-nonzero G8-reflector; do
  grep -qx "negative $c" "$TMP/calls" || bad "1 negative control $c was not run"
done
grep -q "negative G8-type3" "$TMP/calls" && ok "1 every Type-2/3/5, installed, received and reflector control run"

# 2
for c in G8-type3 G8-type2 G8-type5-v6 G8-received-nonzero; do
  NEG_PASSES="$c" run
  if [[ "$(verdict)" == 1 && "$(obs reflectorClientsFalseStopsReflection)" == false ]] \
     && grep -q "NOT observed" "$TMP/checks"; then ok "2 $c passing with client false → G8 fails: control NOT observed"
  else bad "2 $c passing was admitted (verdict=$(verdict))"; fi
done

# 3 4 5
RC_PRE=1 run; [[ "$(verdict)" == 1 ]] && grep -q "precondition" "$TMP/checks" && ok "3 nothing reflected before the change → not admitted" || bad "3 vacuous control admitted"
RC_WITHDRAWN=1 run; [[ "$(verdict)" == 1 ]] && grep -q "still held" "$TMP/checks" && ok "4 route still held after the bounded wait → not admitted" || bad "4 admitted while the route was held"
RC_SESSIONS=1 run; [[ "$(verdict)" == 1 ]] && grep -q "sessions" "$TMP/checks" && ok "5 a lost session during the control → not admitted" || bad "5 admitted with a lost session"

# 6
RC_OBS=0 run; a="$(verdict)/$(obs interASVPNRemovedReflectionContinues)"
RC_OBS=1 run; b="$(verdict)/$(obs interASVPNRemovedReflectionContinues)"
if [[ "$a" == "0/true" && "$b" == "0/false" ]]; then ok "6 inter-as-vpn removal only recorded (continues true/false), never the verdict"
else bad "6 inter-as-vpn observation affects the verdict or is not recorded: $a $b"; fi

# 7
run
order="$(grep -nE '^(apply spine01 G08.rr-client-false|negative G8-type3|dev G08.inter-as-vpn.remove.spine01|apply spine01 G08.rr-client-true|record G8-obs-no-inter-as-vpn|apply spine01 G08.inter-as-vpn.restore)' "$TMP/calls" | cut -d: -f2- | cut -d' ' -f1-3 | paste -sd'|' -)"
want='apply spine01 G08.rr-client-false.spine01|negative G8-type3|dev G08.inter-as-vpn.remove.spine01|apply spine01 G08.rr-client-true.spine01|record G8-obs-no-inter-as-vpn|apply spine01 G08.inter-as-vpn.restore.spine01'
[[ "$order" == "$want" ]] && ok "7 order: client false → controls → inter-as-vpn removed → client restored → observation → inter-as-vpn back" \
  || bad "7 order is: $order"
grep -q "apply spine01 G08.rr-client-false.spine01 false" "$TMP/calls" && grep -q "apply spine01 G08.rr-client-true.spine01 true" "$TMP/calls" \
  && ok "7 the declared change is route-reflector client false, restored true" || bad "7 the change applied is not client false/true"

[[ $fails -eq 0 ]] || { echo "g08_reflection_control_test: $fails failure(s)"; exit 1; }
echo "g08_reflection_control_test: all passed"
