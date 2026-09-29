#!/usr/bin/env bash
# tests/integration/lib/service_checks.sh — the read-only control-plane checks of the US2 live
# suites (T064 target_failure/managed_drift/unmanaged_path/delete_unreachable, T167 reverify;
# SC-007, SC-008, SC-043, SC-044, AD-40, AD-53, AD-62, AD-71).
#
# Each check is ONE process that polls the cluster and ends with a verdict, so a suite runs it
# through evidence_run (or evidence_negative_control) and the whole poll trace is one run-captured
# record (NFR-013) — the way tests/gate/lib/checks.sh serves the fabric checks. Nothing here
# mutates anything: every probe is a `kubectl get` through lab::kubectl (always --context
# kind-<cluster>). A check prints one `SUMMARY <json>` line the suite reads its evidence fields
# from, and a `PASS|FAIL <check> <detail>` verdict.
#
#   cond <ns> <network> <timeout_s> <spec>…        poll until every spec holds at once
#   cond_hold <ns> <network> <hold_s> <spec>…      every spec holds at EVERY poll for hold_s
#       spec = <Type>=<Status>[/<Reason>][~<regex over the message>]
#   unknown_hold <ns> <network> <cut_epoch> <bound_s> <stopfile> <max_s> <leaf> [<healthy-leaf>]
#       the first Ready=Unknown/VerificationFailed (with Degraded=True/VerificationFailed, both
#       naming <leaf>) inside <bound_s> of <cut_epoch>, then Ready neither True nor False at every
#       poll until <stopfile> exists (the suite touches it just BEFORE it reconnects); records
#       whether status.lastVerifiedTime moved and the healthy leaf's per-target entry
#   target_notready <target-ns> <target> <cut_epoch> <max_s>   the Target's own not-Ready latency
#   lvt_advancing <ns> <network> <intervals> <interval_s> <slack_s>
#   deleting_hold <ns> <network> held <hold_s> | gone <max_s>
#       Ready=False/Deleting at every poll (never True, never Unknown); `held`: still present after
#       hold_s; `gone`: removed within max_s
#   gens <cfg-ns> <net-ns> <network>               "<config> <generation>" per generated Config
#   gens_equal <file> <cfg-ns> <net-ns> <network>  no Config spec write since the snapshot
#   claims <net-ns> <network>                      the claim-selector listing "<claim> <value>"
#   claims_equal <file> <net-ns> <network> | claims_empty <net-ns> <network>
#   claims_holder <net-ns>                          one Network there that holds a claim (a control subject)
#   finding <fabric-ns> <fabric> <node> <net-ns> <network>   a durable Fabric.status.findings[]
#                                                  entry naming the device and the identifiers
#   finding_cleared <fabric-ns> <fabric> <node> <net-ns> <network> <max_s>
#                                                  the finding is gone from Fabric.status.findings[]
#                                                  within max_s AND a FindingCleared Event names the
#                                                  service and node — the scheduled read-back that
#                                                  read every device object absent (T149, SC-043)
#   event <ns> <object> <reason> <type>            an Event of that reason and type on the object
#   unclaimed <cfg-ns> <needle>                    no Config (and no Deviation) names <needle>
#   config_gone <cfg-ns> <config> <max_s>          the layer's Config is gone from the API within
#                                                  max_s (its own removal, read back; never forced)
#
# Environment: SC_POLL (poll interval, default 2 s), CLUSTER_NAME / KUBE_CONTEXT / KUBECTL.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

SC_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$SC_HERE/../../lib/lab.sh"

: "${SC_POLL:=2}"
SC_NET_RES="networks.fabric.agentic-netops.io"
SC_FABRIC_RES="fabrics.fabric.agentic-netops.io"
SC_CLAIM_RES="identifierclaims.fabric.agentic-netops.io"
: "${SC_CLAIM_NS:=agentic-netops-allocation}"
LABEL_NET_NS="agentic-netops.io/network-namespace"
LABEL_NET_NAME="agentic-netops.io/network-name"

say() { printf '%s\n' "$*"; }
verdict() { say "$1 $2 ${*:3}"; }
now() { date +%s; }

# sc::net <ns> <name> — the Network's JSON, or nothing (rc 1) when it does not exist
sc::net() { lab::kubectl -n "$1" get "$SC_NET_RES" "$2" -o json 2>/dev/null; }

# sc::match <json> <spec> — 0 when the condition spec holds on the object JSON
sc::match() {
  local obj="$1" spec="$2" type want reason="" rx="" rest
  type="${spec%%=*}"; rest="${spec#*=}"
  if [[ "$rest" == *"~"* ]]; then rx="${rest#*~}"; rest="${rest%%~*}"; fi
  want="${rest%%/*}"
  [[ "$rest" == */* ]] && reason="${rest#*/}"
  jq -e --arg t "$type" --arg s "$want" --arg r "$reason" --arg x "$rx" '
    [(.status.conditions // [])[] | select(.type == $t)] | first
    | . != null and .status == $s and ($r == "" or .reason == $r)
      and ($x == "" or ((.message // "") | test($x)))' <<<"$obj" >/dev/null 2>&1
}

# sc::show <json> — one line of every condition
sc::show() { jq -r '[(.status.conditions // [])[] | "\(.type)=\(.status)/\(.reason)"] | join(" ")' <<<"$1" 2>/dev/null; }
sc::lvt()  { jq -r '.status.lastVerifiedTime // ""' <<<"$1" 2>/dev/null; }

chk_cond() {
  local ns="$1" name="$2" timeout="$3"; shift 3
  [[ $# -gt 0 ]] || { say "cond: no condition spec" >&2; return 2; }
  local t0 obj s ok last="absent"
  t0="$(now)"
  while :; do
    if obj="$(sc::net "$ns" "$name")"; then
      ok=1; for s in "$@"; do sc::match "$obj" "$s" || { ok=0; break; }; done
      last="$(sc::show "$obj")"
      say "t+$(( $(now) - t0 ))s $ns/$name: $last"
      if [[ "$ok" == 1 ]]; then
        say "SUMMARY $(jq -cn --argjson e "$(( $(now) - t0 ))" --arg c "$last" '{elapsed_seconds: $e, conditions: $c}')"
        verdict PASS cond "$ns/$name: $* after $(( $(now) - t0 ))s"; return 0
      fi
    else
      say "t+$(( $(now) - t0 ))s $ns/$name: absent"
    fi
    (( $(now) - t0 >= timeout )) && break
    sleep "$SC_POLL"
  done
  say "SUMMARY $(jq -cn --argjson e "$timeout" --arg c "$last" '{elapsed_seconds: $e, conditions: $c, timed_out: true}')"
  verdict FAIL cond "$ns/$name did not report $* within ${timeout}s (last: $last)"; return 1
}

chk_cond_hold() {
  local ns="$1" name="$2" hold="$3"; shift 3
  [[ $# -gt 0 ]] || { say "cond_hold: no condition spec" >&2; return 2; }
  local t0 obj s polls=0
  t0="$(now)"
  while :; do
    polls=$((polls + 1))
    obj="$(sc::net "$ns" "$name")" || { verdict FAIL cond_hold "$ns/$name absent at poll $polls"; return 1; }
    for s in "$@"; do
      if ! sc::match "$obj" "$s"; then
        verdict FAIL cond_hold "$ns/$name broke $s at t+$(( $(now) - t0 ))s (poll $polls): $(sc::show "$obj")"; return 1
      fi
    done
    say "t+$(( $(now) - t0 ))s $ns/$name: $(sc::show "$obj")"
    (( $(now) - t0 >= hold )) && break
    sleep "$SC_POLL"
  done
  say "SUMMARY $(jq -cn --argjson p "$polls" --argjson h "$hold" '{polls: $p, hold_seconds: $h}')"
  verdict PASS cond_hold "$ns/$name held $* at all $polls polls over ${hold}s"
}

chk_unknown_hold() {
  local ns="$1" name="$2" cut="$3" bound="$4" stop="$5" max="$6" leaf="$7" healthy="${8:-}"
  local obj first="" lvt0="" lvt="" polls=0 viol=() healthy_seen="n/a" t
  # phase 1: the first Unknown, inside the bound
  while :; do
    t=$(( $(now) - cut ))
    if obj="$(sc::net "$ns" "$name")"; then
      say "t+${t}s $ns/$name: $(sc::show "$obj")"
      if sc::match "$obj" "Ready=Unknown/VerificationFailed~${leaf}" \
         && sc::match "$obj" "Degraded=True/VerificationFailed~${leaf}"; then
        first="$t"; lvt0="$(sc::lvt "$obj")"; break
      fi
    fi
    (( t >= bound )) && break
    sleep "$SC_POLL"
  done
  if [[ -z "$first" ]]; then
    say "SUMMARY $(jq -cn --argjson b "$bound" '{first_unknown_seconds: null, bound_seconds: $b}')"
    verdict FAIL unknown_hold "$ns/$name: no Ready=Unknown/VerificationFailed + Degraded=True/VerificationFailed naming $leaf within ${bound}s of the cut"
    return 1
  fi
  if [[ -n "$healthy" ]]; then
    healthy_seen="$(jq -r --arg n "$healthy" '[(.status.renderedConfigs // [])[] | select(.node == $n)] | first
      | if . == null then "missing" else "\(.phase // "")/\(.reason // "")" end' <<<"$obj")"
  fi
  # phase 2: never True, never False, until the suite reconnects
  local t_stop=$(( $(now) + max ))
  while [[ ! -e "$stop" ]]; do
    polls=$((polls + 1))
    t=$(( $(now) - cut ))
    if obj="$(sc::net "$ns" "$name")"; then
      lvt="$(sc::lvt "$obj")"
      if ! sc::match "$obj" "Ready=Unknown"; then viol+=("t+${t}s $(sc::show "$obj")"); fi
      say "t+${t}s poll $polls: $(sc::show "$obj") lastVerifiedTime=${lvt}"
    else
      viol+=("t+${t}s object absent")
    fi
    (( $(now) >= t_stop )) && { viol+=("no reconnection signal within ${max}s"); break; }
    sleep "$SC_POLL"
  done
  local vj; vj="$(printf '%s\n' "${viol[@]+"${viol[@]}"}" | jq -R . | jq -sc 'map(select(. != ""))')"
  say "SUMMARY $(jq -cn --argjson f "$first" --argjson b "$bound" --argjson p "$polls" --argjson v "$vj" \
    --arg l0 "$lvt0" --arg l1 "${lvt:-$lvt0}" --arg h "$healthy_seen" \
    '{first_unknown_seconds: $f, bound_seconds: $b, polls_after_first_unknown: $p, violations: $v,
      last_verified_at_first_unknown: $l0, last_verified_at_reconnect: $l1,
      last_verified_advanced: ($l0 != $l1), healthy_target_entry: $h}')"
  if [[ "$healthy_seen" == missing || "$healthy_seen" == "/" ]]; then
    verdict FAIL unknown_hold "the healthy leaf $healthy is not reported per target (renderedConfigs)"; return 1
  fi
  if [[ ${#viol[@]} -gt 0 ]]; then
    verdict FAIL unknown_hold "Ready left Unknown before reconnection: ${viol[*]}"; return 1
  fi
  verdict PASS unknown_hold "$ns/$name Unknown naming $leaf at t+${first}s (bound ${bound}s), held at all $polls polls until reconnection"
}

chk_target_notready() {
  local ns="$1" target="$2" cut="$3" max="$4" st t
  while :; do
    t=$(( $(now) - cut ))
    st="$(lab::kubectl -n "$ns" get targets.config.sdcio.dev "$target" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" || st="unreadable"
    say "t+${t}s Target $ns/$target Ready=${st}"
    if [[ "$st" != True ]]; then
      say "SUMMARY $(jq -cn --argjson t "$t" --arg s "$st" '{target_notready_seconds: $t, target_ready: $s}')"
      verdict PASS target_notready "Target $ns/$target not Ready ($st) at t+${t}s"; return 0
    fi
    (( t >= max )) && break
    sleep "$SC_POLL"
  done
  say "SUMMARY $(jq -cn '{target_notready_seconds: null}')"
  verdict FAIL target_notready "Target $ns/$target still Ready ${max}s after the cut"; return 1
}

chk_lvt_advancing() {
  local ns="$1" name="$2" n="$3" iv="$4" slack="$5" obj prev cur i t0
  obj="$(sc::net "$ns" "$name")" || { verdict FAIL lvt_advancing "$ns/$name absent"; return 1; }
  prev="$(sc::lvt "$obj")"
  say "lastVerifiedTime at start: ${prev:-unset}"
  for ((i = 1; i <= n; i++)); do
    t0="$(now)"
    while :; do
      cur="$(sc::lvt "$(sc::net "$ns" "$name" || true)")"
      [[ -n "$cur" && "$cur" != "$prev" ]] && break
      if (( $(now) - t0 >= iv + slack )); then
        verdict FAIL lvt_advancing "interval $i: lastVerifiedTime stayed ${prev:-unset} for $((iv + slack))s"; return 1
      fi
      sleep "$SC_POLL"
    done
    say "interval $i: lastVerifiedTime ${prev:-unset} -> $cur after $(( $(now) - t0 ))s"
    prev="$cur"
  done
  say "SUMMARY $(jq -cn --argjson n "$n" --arg l "$prev" '{intervals: $n, last_verified: $l}')"
  verdict PASS lvt_advancing "$ns/$name lastVerifiedTime advanced on each of $n intervals (<= ${iv}s + ${slack}s)"
}

chk_deleting_hold() {
  local ns="$1" name="$2" mode="$3" secs="$4" t0 obj polls=0 dc
  t0="$(now)"
  while :; do
    if ! obj="$(sc::net "$ns" "$name")"; then
      if [[ "$mode" == gone ]]; then
        say "SUMMARY $(jq -cn --argjson e "$(( $(now) - t0 ))" --argjson p "$polls" '{removed_after_seconds: $e, polls: $p}')"
        verdict PASS deleting_hold "$ns/$name removed after $(( $(now) - t0 ))s, Ready=False/Deleting at all $polls polls"; return 0
      fi
      verdict FAIL deleting_hold "$ns/$name was removed at t+$(( $(now) - t0 ))s while a target was unreachable (nothing read back)"; return 1
    fi
    polls=$((polls + 1))
    dc="$(jq -r '[(.status.conditions // [])[] | select(.type == "Deleting")] | first | if . == null then "-" else "\(.status)/\(.reason): \(.message)" end' <<<"$obj")"
    say "t+$(( $(now) - t0 ))s poll $polls: $(sc::show "$obj") | Deleting ${dc}"
    if ! sc::match "$obj" "Ready=False/Deleting"; then
      verdict FAIL deleting_hold "$ns/$name not Ready=False/Deleting at poll $polls: $(sc::show "$obj")"; return 1
    fi
    if (( $(now) - t0 >= secs )); then
      if [[ "$mode" == held ]]; then
        say "SUMMARY $(jq -cn --argjson p "$polls" --argjson h "$secs" --arg d "$dc" '{polls: $p, held_seconds: $h, deleting: $d}')"
        verdict PASS deleting_hold "$ns/$name held Ready=False/Deleting at all $polls polls over ${secs}s"; return 0
      fi
      verdict FAIL deleting_hold "$ns/$name not removed within ${secs}s"; return 1
    fi
    sleep "$SC_POLL"
  done
}

sc::gens() {
  lab::kubectl -n "$1" get configs.config.sdcio.dev -l "${LABEL_NET_NS}=$2,${LABEL_NET_NAME}=$3" -o json \
    | jq -r '.items[] | "\(.metadata.name) \(.metadata.generation)"' | sort
}
chk_gens() { sc::gens "$@"; }
chk_gens_equal() {
  local f="$1"; shift
  local cur; cur="$(sc::gens "$@")"
  say "before:"; cat "$f"; say "now:"; say "$cur"
  if [[ -z "$cur" ]]; then verdict FAIL gens_equal "no generated Config found for $2/$3"; return 1; fi
  if [[ "$cur" == "$(cat "$f")" ]]; then verdict PASS gens_equal "zero Config spec writes"; return 0; fi
  # who wrote: the managers and times of every field set, and the render hash now — so a
  # recurrence names the writer instead of leaving a bare generation number (T152 r9)
  say "managedFields (who wrote the spec, and when):"
  lab::kubectl -n "$1" get configs.config.sdcio.dev -l "${LABEL_NET_NS}=$2,${LABEL_NET_NAME}=$3" -o json \
    --show-managed-fields 2>/dev/null \
    | jq -c '.items[] | {name: .metadata.name, generation: .metadata.generation,
        renderHash: (.metadata.annotations // {} | to_entries | map(select(.key | test("render-hash"))) | from_entries),
        managers: [.metadata.managedFields[]? | {manager, operation, time, subresource}]}' 2>/dev/null || true
  verdict FAIL gens_equal "a Config generation advanced (a spec write)"; return 1
}

sc::claims() {
  lab::kubectl -n "$SC_CLAIM_NS" get "$SC_CLAIM_RES" -l "${LABEL_NET_NS}=$1,${LABEL_NET_NAME}=$2" -o json \
    | jq -r '.items[] | "\(.metadata.name) \(.status.value // .spec.requested // "")"' | sort
}
chk_claims() { sc::claims "$@"; }
# claims_holder <net-ns> — the name of one Network in <net-ns> that holds at least one claim
chk_claims_holder() {
  local n
  for n in $(lab::kubectl -n "$1" get "$SC_NET_RES" -o jsonpath='{.items[*].metadata.name}'); do
    [[ -n "$(sc::claims "$1" "$n")" ]] && { printf '%s\n' "$n"; return 0; }
  done
  return 1
}
chk_claims_equal() {
  local f="$1"; shift
  local cur; cur="$(sc::claims "$@")"
  say "before:"; cat "$f"; say "now:"; say "$cur"
  if [[ -n "$cur" && "$cur" == "$(cat "$f")" ]]; then verdict PASS claims_equal "zero identifiers released"; return 0; fi
  verdict FAIL claims_equal "the claim selector changed: $(diff <(cat "$f") <(printf '%s\n' "$cur") | tr '\n' ' ')"; return 1
}
chk_claims_empty() {
  local cur; cur="$(sc::claims "$@")"
  say "$cur"
  if [[ -z "$cur" ]]; then verdict PASS claims_empty "no claim labelled $1/$2"; return 0; fi
  verdict FAIL claims_empty "claims still labelled $1/$2: $(tr '\n' ' ' <<<"$cur")"; return 1
}

chk_finding() {
  local fns="$1" fab="$2" node="$3" nns="$4" nn="$5" out
  out="$(lab::kubectl -n "$fns" get "$SC_FABRIC_RES" "$fab" -o json | jq -c --arg d "$node" --arg ns "$nns" --arg n "$nn" '
    [(.status.findings // [])[] | select(.node == $d and .service.namespace == $ns and .service.name == $n)] | first')"
  say "finding: $out"
  if [[ "$out" != null ]] && jq -e '(.identifiers // []) | length > 0' <<<"$out" >/dev/null; then
    verdict PASS finding "Fabric.status.findings[] names $node and $(jq -c '.identifiers' <<<"$out")"; return 0
  fi
  verdict FAIL finding "no durable finding naming $node and the identifiers of $nns/$nn"; return 1
}

chk_finding_cleared() {
  local fns="$1" fab="$2" node="$3" nns="$4" nn="$5" secs="$6" t0 out ev
  t0="$(now)"
  while :; do
    out="$(lab::kubectl -n "$fns" get "$SC_FABRIC_RES" "$fab" -o json | jq -c --arg d "$node" --arg ns "$nns" --arg n "$nn" '
      [(.status.findings // [])[] | select(.node == $d and .service.namespace == $ns and .service.name == $n)] | first')"
    ev="$(lab::kubectl -n "$fns" get events --field-selector "involvedObject.name=${fab},reason=FindingCleared" \
          -o jsonpath='{range .items[*]}{.lastTimestamp} {.message}{"\n"}{end}' 2>/dev/null | grep -F "${nns}/${nn} on ${node}" || true)"
    say "t+$(( $(now) - t0 ))s finding: $out; FindingCleared: ${ev:-none}"
    if [[ "$out" == null && -n "$ev" ]]; then
      say "SUMMARY $(jq -cn --argjson e "$(( $(now) - t0 ))" --arg ev "$ev" '{cleared_after_seconds: $e, event: $ev}')"
      verdict PASS finding_cleared "finding for $nns/$nn on $node cleared by a clean read-back after $(( $(now) - t0 ))s: $ev"; return 0
    fi
    (( $(now) - t0 >= secs )) && break
    sleep "$SC_POLL"
  done
  verdict FAIL finding_cleared "finding for $nns/$nn on $node not cleared by a read-back within ${secs}s"; return 1
}

chk_event() {
  local ns="$1" obj="$2" reason="$3" type="$4" out
  out="$(lab::kubectl -n "$ns" get events --field-selector "involvedObject.name=${obj},reason=${reason},type=${type}" \
         -o jsonpath='{range .items[*]}{.type} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true)"
  say "$out"
  if [[ -n "$out" ]]; then verdict PASS event "$type $reason on $ns/$obj"; return 0; fi
  verdict FAIL event "no $type Event $reason on $ns/$obj"; return 1
}

chk_unclaimed() {
  local ns="$1" needle="$2" hits
  # A Config naming the needle claims it. A Deviation entry does only when its reason is not
  # UNHANDLED: the layer's target-level Deviation lists every path no intent owns as UNHANDLED
  # (observed live, 2026-09-21), which is the definition of unclaimed, not a claim.
  hits="$( { lab::kubectl -n "$ns" get configs.config.sdcio.dev -o json \
               | jq -r --arg n "$needle" '.items[]? | select(tostring | contains($n)) | "\(.kind)/\(.metadata.name)"'
             lab::kubectl -n "$ns" get deviations.config.sdcio.dev -o json \
               | jq -r --arg n "$needle" '.items[]? | select([.spec.deviations[]? | select((.path // "" | contains($n)) and (.reason != "UNHANDLED"))] | length > 0) | "\(.kind)/\(.metadata.name)"'
           } 2>/dev/null || true)"
  say "${hits:-no Config or Deviation names $needle}"
  if [[ -z "$hits" ]]; then verdict PASS unclaimed "nothing in $ns claims $needle"; return 0; fi
  verdict FAIL unclaimed "$needle is named by: $(tr '\n' ' ' <<<"$hits")"; return 1
}

chk_config_gone() {
  local ns="$1" cfg="$2" secs="$3" t0 out
  t0="$(now)"
  while :; do
    if ! out="$(lab::kubectl -n "$ns" get configs.config.sdcio.dev "$cfg" -o json 2>/dev/null)"; then
      say "SUMMARY $(jq -cn --argjson e "$(( $(now) - t0 ))" '{gone_after_seconds: $e}')"
      verdict PASS config_gone "$ns/$cfg gone after $(( $(now) - t0 ))s"; return 0
    fi
    say "t+$(( $(now) - t0 ))s $ns/$cfg: $(jq -c '{deletionTimestamp: .metadata.deletionTimestamp, conditions: [.status.conditions[]? | "\(.type)=\(.status)/\(.reason)"]}' <<<"$out")"
    (( $(now) - t0 >= secs )) && break
    sleep "$SC_POLL"
  done
  verdict FAIL config_gone "$ns/$cfg still present after ${secs}s"; return 1
}

usage() { sed -n '/^#   cond /,/^#                                                  max_s/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; return 2; }

main() {
  local c="${1:-}"; shift || true
  case "$c" in
    cond|cond_hold|unknown_hold|target_notready|lvt_advancing|deleting_hold|gens|gens_equal|claims|claims_holder|claims_equal|claims_empty|finding|finding_cleared|event|unclaimed|config_gone)
      "chk_${c}" "$@" ;;
    *) usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
