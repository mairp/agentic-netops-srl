#!/usr/bin/env bash
# Offline suite of the US2 fault-making live suites (T064 target_failure/managed_drift/
# unmanaged_path/delete_unreachable, T167 reverify) and their shared libraries
# tests/integration/lib/{suite.sh,service_checks.sh}. No lab: kubectl and docker are fakes on PATH,
# evidence identities are stubbed, everything is written under a temp directory. Asserts:
#   - every script refuses bad arguments with a usage (exit 2) without touching anything
#   - managed_drift's plan is read from G13's observation: the recorded file gives restoration
#     asserted, the deviation reported, OVERRULED "not demonstrated"; a file recording OVERRULED
#     and a durable NOT_APPLIED gives both asserted; a missing file refuses
#   - REVERIFY_INTERVAL test values honour the 30 s floor
#   - the polling checks judge real sequences: cond, the Unknown hold (a True or False after the
#     first Unknown fails it; no Unknown within the bound fails it), the Deleting hold
#   - in every script each readiness check's negative control is issued on an earlier line
#   - a management cut is declared in declared-faults.json BEFORE docker disconnects the node, and
#     a declarative maintenance[] fault is restored by the exit trap when the run fails, the run
#     still failing
# check() evals its assertion, so the single-quoted expressions are deliberate (SC2016).
# shellcheck disable=SC2016 source-path=SCRIPTDIR
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
IT="$ROOT/tests/integration"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; FAKE="$TMP/fake"
mkdir -p "$BIN" "$FAKE/net"
export FAKE PATH="$BIN:$PATH" SC_POLL=0.2
export EVIDENCE_DIR="$TMP/ev" EVIDENCE_ROOT="$TMP/evroot" EVIDENCE_DEVICE_IMAGE_DIGEST=sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402 EVIDENCE_CLUSTER_UID=offline
export SRL_PASS=offline-secret CLUSTER_NAME=agentic-netops LAB_TCP_ACCEPT=true

# fake kubectl: `get networks… <name> -o json` serves $FAKE/net/<name>/<n>.json in call order (the
# last one repeats; a step reading ABSENT is NotFound); fabrics serve $FAKE/fabric.json; every
# other call is logged to $FAKE/kubectl.calls.
cat >"$BIN/kubectl" <<'SH'
#!/usr/bin/env bash
args=("$@"); printf '%s\n' "${args[*]}" >>"$FAKE/kubectl.calls"
res=""; name=""
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == get ]]; then res="${args[$((i + 1))]}"; name="${args[$((i + 2))]:-}"; break; fi
done
case "$res" in
  networks.fabric.agentic-netops.io)
    d="$FAKE/net/$name"; [[ -d "$d" ]] || { echo "NotFound" >&2; exit 1; }
    n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$d/count"
    last="$(ls "$d" | grep -E '^[0-9]+\.json$' | sort -n | tail -1)"
    f="$d/$n.json"; [[ -f "$f" ]] || f="$d/$last"
    grep -q '^ABSENT' "$f" && { echo "NotFound" >&2; exit 1; }
    cat "$f" ;;
  fabrics.fabric.agentic-netops.io) cat "$FAKE/fabric.json" ;;
  configs.config.sdcio.dev)
    f="$FAKE/cfg/$name"; [[ -f "$f" ]] || { echo "NotFound" >&2; exit 1; }
    cat "$f" ;;
  *) [[ " ${args[*]} " == *" patch "* && -f "$FAKE/fabric.patch-writes" ]] && \
       printf '%s' "${args[-1]}" | jq -c '.spec.maintenance' >"$FAKE/fabric.maint" 2>/dev/null
     exit 0 ;;
esac
SH
# fake docker: inspect → a pid; every call recorded
cat >"$BIN/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE/docker.calls"
[[ "$1" == inspect ]] && echo 4242
exit 0
SH
# fake nsenter: -t PID -n <cmd…> → run cmd
cat >"$BIN/nsenter" <<'SH'
#!/usr/bin/env bash
while [[ "$1" == -* ]]; do case "$1" in -t) shift 2 ;; *) shift ;; esac; done
exec "$@"
SH
# fake ip: the container's mgmt0 (carrier unless the host peer is down), the host's link list, and
# `link set <peer> up|down` — which records whether the fault was already declared
cat >"$BIN/ip" <<'SH'
#!/usr/bin/env bash
printf 'ip %s\n' "$*" >>"$FAKE/docker.calls"
case "$*" in
  "-o link show mgmt0"|"-o link show eth0")
    if [[ -f "$FAKE/peer-down" ]]; then echo "9652: $4@if9653: <BROADCAST,MULTICAST,UP> mtu 1514 state LOWERLAYERDOWN"
    else echo "9652: $4@if9653: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1514 state UP"; fi ;;
  "-o link show") printf '1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536\n9653: veth6f1a2b@if9652: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1514\n' ;;
  "link set "*" down")
    if [[ -f "$EVIDENCE_DIR/declared-faults.json" ]] && jq -e '.faults | length > 0' "$EVIDENCE_DIR/declared-faults.json" >/dev/null; then
      echo "declared-before-disconnect" >>"$FAKE/docker.calls"
    else
      echo "UNDECLARED-disconnect" >>"$FAKE/docker.calls"
    fi
    : >"$FAKE/peer-down" ;;
  "link set "*" up") rm -f "$FAKE/peer-down" ;;
esac
exit 0
SH
chmod +x "$BIN/nsenter" "$BIN/ip"
chmod +x "$BIN/kubectl" "$BIN/docker"

# net <name> <step> <json|ABSENT> — one step of a Network's status sequence
net() { mkdir -p "$FAKE/net/$1"; rm -f "$FAKE/net/$1/count"; printf '%s\n' "$3" >"$FAKE/net/$1/$2.json"; }
conds() { # conds <Ready status/reason> [<Degraded status/reason>] [lvt]
  jq -cn --arg r "$1" --arg d "${2:-}" --arg l "${3:-2026-09-21T00:00:00Z}" '
    {metadata: {name: "x"}, status: {lastVerifiedTime: $l,
      renderedConfigs: [{node: "leaf01", phase: "Applied"}, {node: "leaf02", phase: "Unknown"}],
      conditions: ([{type: "Ready", status: ($r | split("/")[0]), reason: ($r | split("/")[1]), message: "target leaf02 cannot be read"}]
        + (if $d == "" then [] else [{type: "Degraded", status: ($d | split("/")[0]), reason: ($d | split("/")[1]), message: "leaf02 unreachable"}] end))}}'
}
SC="$IT/lib/service_checks.sh"

# ---------------------------------------------------------------- usage on bad arguments
for s in target_failure managed_drift unmanaged_path delete_unreachable reverify; do
  rc=0; out="$(bash "$IT/$s.sh" bogus 2>&1)" || rc=$?
  check "$s: bad args -> usage, exit 2" '[[ $rc -eq 2 ]] && grep -q "^usage:" <<<"$out"' "$out"
done
rc=0; out="$(bash "$IT/delete_unreachable.sh" run --bogus 2>&1)" || rc=$?
check "delete_unreachable: unknown mode -> usage, exit 2" '[[ $rc -eq 2 ]] && grep -q "force-release" <<<"$out"' "$out"
rc=0; out="$(bash "$IT/reverify.sh" maintenance sometimes 2>&1)" || rc=$?
check "reverify: maintenance without test|default -> usage, exit 2" '[[ $rc -eq 2 ]]' "$out"
check "no kubectl or docker call on bad args" '[[ ! -s "$FAKE/kubectl.calls" && ! -s "$FAKE/docker.calls" ]]'

# ---------------------------------------------------------------- managed_drift's G13 plan
out="$(bash "$IT/managed_drift.sh" plan "$ROOT/tests/gate/observed/deviation.json" 2>&1)"
check "plan from the recorded G13 observation: restoration asserted, deviation reported, OVERRULED not demonstrated" \
  '[[ "$out" == $'"'"'restoration assert\ndeviation report\noverruled not-demonstrated'"'"' ]]' "$out"
check "the not-demonstrated wording is the task's" 'grep -q "not demonstrated live; envtest-covered" "$IT/managed_drift.sh"'
jq '.assertable_by_managed_drift.deviation_not_applied = true | .deviation_visible_before_restore = true
    | .reason_strings_seen = ["NOT_APPLIED","OVERRULED"]' "$ROOT/tests/gate/observed/deviation.json" >"$TMP/dev-all.json"
out="$(bash "$IT/managed_drift.sh" plan "$TMP/dev-all.json" 2>&1)"
check "plan when G13 recorded a durable NOT_APPLIED and OVERRULED: both asserted" \
  '[[ "$out" == $'"'"'restoration assert\ndeviation assert\noverruled assert'"'"' ]]' "$out"
jq '.assertable_by_managed_drift.deviation_not_applied = true | .deviation_visible_before_restore = false' \
  "$ROOT/tests/gate/observed/deviation.json" >"$TMP/dev-raced.json"
out="$(bash "$IT/managed_drift.sh" plan "$TMP/dev-raced.json" 2>&1)"
check "a deviation G13 saw raced away is reported, never asserted" 'grep -qx "deviation report" <<<"$out"' "$out"
rc=0; bash "$IT/managed_drift.sh" plan "$TMP/none.json" >/dev/null 2>&1 || rc=$?
check "a missing G13 observation refuses (exit 2)" '[[ $rc -eq 2 ]]'

# ---------------------------------------------------------------- the REVERIFY_INTERVAL floor
# shellcheck source=../../integration/lib/suite.sh
( source "$IT/lib/suite.sh"
  for v in 30s 1m 1m30s 5m 1h; do suite::reverify_ok "$v" || { echo "refused $v"; exit 1; }; done
  for v in 10s 29s 0 -5m "five minutes" "" 30; do suite::reverify_ok "$v" && { echo "accepted '$v'"; exit 1; }; done
  [[ "$(suite::seconds 1m30s)" == 90 && "$(suite::seconds 5m)" == 300 ]] || { echo "seconds wrong"; exit 1; }
) >"$TMP/floor.out" 2>&1; rc=$?
check "REVERIFY_INTERVAL: 30s/1m/1m30s/5m/1h accepted, 10s/29s/0/-5m/'five minutes'/''/30 refused" '[[ $rc -eq 0 ]]' "$(cat "$TMP/floor.out")"

# ---------------------------------------------------------------- the polling checks
net n1 1 ABSENT; net n1 2 "$(conds False/NotConverged)"; net n1 3 "$(conds True/AsExpected)"
rc=0; out="$(bash "$SC" cond ns n1 10 Ready=True 2>&1)" || rc=$?
check "cond: passes once Ready=True is reported" '[[ $rc -eq 0 ]] && grep -q "^PASS cond" <<<"$out"' "$out"
rc=0; out="$(bash "$SC" cond ns nothere 1 Ready=True 2>&1)" || rc=$?
check "cond: fails on timeout for a service that was never Ready" '[[ $rc -eq 1 ]] && grep -q "timed_out" <<<"$out"' "$out"
net n2 1 "$(conds False/RoutesMissing)"
rc=0; out="$(bash "$SC" cond ns n2 1 "Ready=False/RoutesMissing~leaf03" 2>&1)" || rc=$?
check "cond: the message regex must match (a message not naming the leaf fails)" '[[ $rc -eq 1 ]]' "$out"

stop="$TMP/stop"
unknown_case() { # unknown_case <name> <bound> — run unknown_hold, the stop signal after ~2 s
  rm -f "$stop"; ( sleep 2; touch "$stop" ) & local bg=$!
  rc=0; out="$(bash "$SC" unknown_hold ns "$1" "$(date +%s)" "$2" "$stop" 20 leaf02 leaf01 2>&1)" || rc=$?
  wait "$bg"
}
net u1 1 "$(conds True/AsExpected)"; net u1 2 "$(conds Unknown/VerificationFailed True/VerificationFailed)"
unknown_case u1 10
check "unknown_hold: Unknown+Degraded naming the leaf, held until reconnection -> PASS with its latency" \
  '[[ $rc -eq 0 ]] && grep -q "first_unknown_seconds" <<<"$out" && grep -q "\"last_verified_advanced\":false" <<<"$out"' "$out"
net u2 1 "$(conds Unknown/VerificationFailed True/VerificationFailed)"; net u2 2 "$(conds Unknown/VerificationFailed True/VerificationFailed)"
net u2 4 "$(conds True/AsExpected)"
unknown_case u2 10
check "unknown_hold: a Ready=True after the first Unknown (before reconnection) fails" '[[ $rc -eq 1 ]] && grep -q "left Unknown" <<<"$out"' "$out"
net u3 1 "$(conds Unknown/VerificationFailed True/VerificationFailed)"; net u3 3 "$(conds False/RoutesMissing)"
unknown_case u3 10
check "unknown_hold: a Ready=False after the first Unknown fails" '[[ $rc -eq 1 ]]' "$out"
net u4 1 "$(conds True/AsExpected)"
unknown_case u4 1
check "unknown_hold: no Unknown within the bound fails" '[[ $rc -eq 1 ]] && grep -q "within 1s of the cut" <<<"$out"' "$out"
net u5 1 "$(conds Unknown/VerificationFailed True/VerificationFailed 2026-09-21T00:00:00Z)"
net u5 3 "$(conds Unknown/VerificationFailed True/VerificationFailed 2026-09-21T00:05:00Z)"
unknown_case u5 10
check "unknown_hold: records lastVerifiedTime advancing while unreadable" '[[ "$out" == *"\"last_verified_advanced\":true"* ]]' "$out"
# reverify.sh judges that summary field: a recorded `false` must read "false", never "null"
# (jq's `//` treats false as absent — the 2026-09-24 live run failed on exactly that).
adv_expr="$(grep -o "jq -r '.last_verified_advanced[^']*'" "$ROOT/tests/integration/reverify.sh" | head -1 | sed "s/^jq -r '//; s/'\$//")"
check "reverify: its lastVerifiedTime judge reads a recorded false as false" \
  '[[ -n "$adv_expr" && "$(jq -r "$adv_expr" <<<"{\"last_verified_advanced\":false}")" == false && "$(jq -r "$adv_expr" <<<"{}")" == null ]]' "expr=$adv_expr"
check "reverify: negative control — the '//' form reads false as null" \
  '[[ "$(jq -r ".last_verified_advanced // \"null\"" <<<"{\"last_verified_advanced\":false}")" == null ]]'

net d1 1 "$(conds False/Deleting)"; net d1 4 ABSENT
rc=0; out="$(bash "$SC" deleting_hold ns d1 gone 10 2>&1)" || rc=$?
check "deleting_hold gone: Ready=False/Deleting until removal -> PASS" '[[ $rc -eq 0 ]]' "$out"
net d2 1 "$(conds False/Deleting)"; net d2 3 "$(conds Unknown/VerificationFailed)"
rc=0; out="$(bash "$SC" deleting_hold ns d2 held 10 2>&1)" || rc=$?
check "deleting_hold: an Unknown during deletion fails" '[[ $rc -eq 1 ]]' "$out"
net d3 1 "$(conds False/Deleting)"; net d3 2 ABSENT
rc=0; out="$(bash "$SC" deleting_hold ns d3 held 10 2>&1)" || rc=$?
check "deleting_hold held: removal while the target is unreachable fails" '[[ $rc -eq 1 ]] && grep -q "nothing read back" <<<"$out"' "$out"

# config_gone: the layer's own removal, read back — never forced (delete_unreachable --force-release)
mkdir -p "$FAKE/cfg"
echo '{"metadata":{"deletionTimestamp":"2026-09-24T05:19:26Z"},"status":{"conditions":[{"type":"Ready","status":"False","reason":"Failed"}]}}' >"$FAKE/cfg/held.leaf02"
rc=0; out="$(bash "$SC" config_gone agentic-netops-system held.leaf02 1 2>&1)" || rc=$?
check "config_gone: a Config the layer still holds fails" '[[ $rc -eq 1 ]] && grep -q "still present" <<<"$out"' "$out"
rc=0; out="$(bash "$SC" config_gone agentic-netops-system gone.leaf02 1 2>&1)" || rc=$?
check "config_gone: an absent Config passes" '[[ $rc -eq 0 ]]' "$out"
du_src="$IT/delete_unreachable.sh"
gone_line="$(grep -n 'config_gone "\$LAB_TARGET_NS" "\${DU_NET}' "$du_src" | head -1 | cut -d: -f1)"
clean_line="$(grep -n '^      du::device_cleanup' "$du_src" | head -1 | cut -d: -f1)"
check "delete_unreachable: the device is cleaned only after the layer's Config is gone" \
  '[[ -n "$gone_line" && -n "$clean_line" && "$gone_line" -lt "$clean_line" ]] && [[ $(grep -c "du::device_cleanup ||" "$du_src") -eq 1 ]]' "gone=$gone_line clean=$clean_line"
check "delete_unreachable: asserts Deleting=True/TargetUnreachable naming the leaf in both modes" \
  'grep -q "Deleting=True/TargetUnreachable~\${DU_LEAF}\" \"Ready=False/Deleting\"" "$du_src"' ""

# ---------------------------------------------------------------- negative control before pass
for s in target_failure managed_drift unmanaged_path delete_unreachable reverify; do
  bad="$(awk '
    /(suite::neg|gate::negative) [A-Z]/ { for (i = 1; i <= NF; i++) if ($i == "suite::neg" || $i == "gate::negative") neg[$(i + 1)] = 1 }
    /--readiness/ { c = ""
      for (i = 1; i <= NF; i++) { if ($i == "suite::check") c = $(i + 2); if ($i == "--check") c = $(i + 1) }
      if (c != "" && !(c in neg)) print FILENAME ":" NR " " c }' "$IT/$s.sh")"
  check "$s: every readiness check has its negative control issued first" '[[ -z "$bad" ]]' "$bad"
done

# ---------------------------------------------------------------- declared before cut; exit-trap restore
jq -n '{spec: {inventory: [], maintenance: null}}' >"$FAKE/fabric.json"
: >"$FAKE/fabric.patch-writes"
rc=0; out="$(bash -c '
  source "'"$IT"'/lib/suite.sh"
  suite::init unit-test || exit 9
  suite::mgmt_cut leaf02 vt-scratch-unit-cut
  suite::maint_add leaf01 ethernet-1/49 ethernet-1/50
  exit 1   # a wait that timed out
' 2>&1)" || rc=$?
check "the management cut is declared before the node's management link is set down" \
  'grep -q declared-before-disconnect "$FAKE/docker.calls" && ! grep -q UNDECLARED "$FAKE/docker.calls"' "$(cat "$FAKE/docker.calls" 2>/dev/null)"
check "the declared fault names the node, its mgmt-link-down probe and the host peer" \
  'jq -e ".faults[0] | .node == \"leaf02\" and .probe.kind == \"mgmt-link-down\" and .probe.peer == \"veth6f1a2b\" and .probe.interface == \"mgmt0\"" "$EVIDENCE_DIR/declared-faults.json" >/dev/null'
check "the cut is link-level (host peer set down), never a docker network disconnect" 'grep -q "^ip link set veth6f1a2b down" "$FAKE/docker.calls" && ! grep -q "network disconnect" "$FAKE/docker.calls"'
check "the exit trap sets the link up again and reads carrier back" 'grep -q "^ip link set veth6f1a2b up" "$FAKE/docker.calls" && [[ ! -f "$FAKE/peer-down" ]]'
check "the exit trap restores Fabric.spec.maintenance (last patch writes the saved null back)" '[[ "$(cat "$FAKE/fabric.maint")" == null ]]' "$(grep patch "$FAKE/kubectl.calls")"
check "a timed-out wait still fails the run after restoring" '[[ $rc -ne 0 && $rc -ne 9 ]]' "rc=$rc $out"
check "kubectl always carries --context kind-agentic-netops" '! grep -v -- "--context kind-agentic-netops" "$FAKE/kubectl.calls" | grep -q .' "$(grep -v -- "--context kind-agentic-netops" "$FAKE/kubectl.calls")"

echo
if [[ "$fails" -gt 0 ]]; then echo "live_suites_test: $fails failure(s)"; exit 1; fi
echo "live_suites_test: all passed"
