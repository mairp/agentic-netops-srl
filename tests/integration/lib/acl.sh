#!/usr/bin/env bash
# Judgement functions are defined inside each check and invoked through acl::poll (SC2317).
# shellcheck disable=SC2317
# tests/integration/lib/acl.sh — the per-node, KEYED access-list checks of the US5 live suites
# (T114; quickstart.md §12 "Device-level assertions" and §13; contracts/acl-render-contract.md §4,
# §4.7; SC-014, SC-015, SC-041, FR-042, FR-043, FR-100, NFR-013; AD-82 decision
# 2026-09-21-acl-binding-state).
#
# Sourced by tests/integration/{acl_verify,acl_enforcement_probe,acl_conflict}.sh for its pure
# helpers. Executed directly it is a CHECK runner, exactly as tests/gate/lib/checks.sh is: ONE
# command that reads a device (or the cluster), prints the raw reads it judged, prints a verdict
# line `CHECK <check>: PASS|FAIL — <detail>` and exits 0 on PASS / 1 on FAIL — so the same command
# is both the readiness run (evidence_run --readiness) and its negative control
# (evidence_negative_control): a stock node (spine01, which carries only its own `cpm` filters)
# or a filter name that does not exist.
#
# Every device read is keyed by filter name, filter type and entry sequence-id (and, for a
# binding, by interface-id and direction): no check here counts filters or entries across a device
# (a stock node carries dozens of `cpm` entries — §4.5). The applied side of a BINDING is not read
# from state: SR Linux 25.7.1 mirrors no part of /acl/interface into state, so the binding is
# judged in running (C5/C6) and each entry's TCAM on the bound direction (A1–A3, the gate's
# tests/gate/lib/checks.sh acl_applied, reused by the suites as is); A4 — the binding applied — is
# per-entry matched-packets moved by traffic that can only meet the filter on its binding (`delta`
# below, acceptance only, never readiness).
#
#   acl.sh written  <node> <filter> <ipv4|ipv6> <expect-json>
#       C1–C4, C7 in RUNNING: the filter exists; its entries read in ascending sequence-id order and
#       their sequence-ids equal the declared priorities (plus 65535 exactly when a default action is
#       declared); each entry's action and match fields equal the declared ones; statistics-per-entry
#       true; subinterface-specific output-only on an egress filter
#   acl.sh binding  <node> <interface-id> <input|output> <filter> <ipv4|ipv6>
#       C5/C6 in RUNNING: /acl/interface[interface-id] carries interface-ref {port, index} and the
#       filter's key under the declared direction
#   acl.sh stats    <node> <filter> <ipv4|ipv6> <seq,seq,…>
#       A5 in STATE: each entry's statistics readable (matched-packets present), incomplete not true
#   acl.sh programmed <node>
#       G1 in STATE: programming-complete true on every forwarding complex (at least one listed)
#   acl.sh gone     <node> <filter> <ipv4|ipv6> [<interface-id> <input|output>]
#       withdrawal read-back: the filter (and its key under the binding) absent from running; a read
#       that errors is never "absent"
#   acl.sh counters <node> <filter> <ipv4|ipv6> <seq,seq,…>
#       prints "<seq> <matched-packets|null>" per entry (a baseline read; never a verdict)
#   acl.sh delta    <node> <filter> <ipv4|ipv6> <seq>:<baseline>:<min>…
#       A4 / SC-041: <min> > 0 — the entry's matched-packets moved by at least <min> above the
#       baseline; <min> 0 — it did NOT move. Every term holds on one read (re-read within CHECK_WAIT:
#       the device refreshes statistics with a lag)
#   acl.sh ping     <client> <dst> ok|fail
#       low-rate probe from the client (ping -c 3 -i 0.5 -W 2, never a flood): ok — answered;
#       fail — 100% loss. A tool error is never a verdict in either direction
#   acl.sh refused  <manifest> <namespace> <name> <holder ns/name>
#       admission refuses the create, naming `Network <holder>` and the occupied binding, and the
#       object does not exist afterwards (kubectl get: NotFound). ACL_DRY_RUN=1 sends
#       --dry-run=server (nothing is ever persisted — the negative control's form); an object a
#       real create DID persist is deleted again and the check fails
#   acl.sh accepted <manifest>
#       admission accepts the object (server-side dry-run only: nothing is created)
#
# Pure helpers (no device, unit-tested): acl::plan <network-json>, acl::expect_canon,
# acl::device_canon, acl::judge_written <filter-json> <expect-json>.
#
# CHECK_WAIT=<s> re-reads until PASS or the window closes (CHECK_INTERVAL, default 5 s).
# Credentials: GNMIC_USERNAME / GNMIC_PASSWORD (lab::export_creds), never argv.
set -euo pipefail

ACL_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ACL_ROOT="$(cd -- "$ACL_LIB_DIR/../../.." && pwd)"
# shellcheck source=../../lib/lab.sh
source "$ACL_ROOT/tests/lib/lab.sh"

: "${CHECK_WAIT:=0}"
: "${CHECK_INTERVAL:=5}"
ACL_NET_RES="networks.fabric.agentic-netops.io"
ACL_JQLIB="$(lab::jq_lib)"

acl::say() { printf '%s\n' "$*"; }
acl::verdict() { printf 'CHECK %s: %s — %s\n' "$2" "$1" "$3"; }

acl::poll() {
  local deadline=$((SECONDS + CHECK_WAIT)) n=0
  while :; do
    n=$((n + 1)); acl::say "=== attempt $n ($(date -u +%H:%M:%SZ))"
    if "$@"; then return 0; fi
    (( SECONDS < deadline )) || return 1
    sleep "$CHECK_INTERVAL"
  done
}

# ---------------------------------------------------------------- pure helpers

# acl::service_id <network-name> — controllers/network/intent.go ServiceID: the name without the
# tier's migr- prefix
acl::service_id() { local id="${1#migr-}"; printf '%s' "${id:-$1}"; }

# jq definitions of the canonical entry form both sides are reduced to:
#   {seq, action: accept|drop, match: {proto?, src?, dst?, sport?, dport?}}
# ports are "eq:<n>" or "range:<lo>-<hi>"; a protocol is its device enum name (icmpv6 → icmp6) or
# its number, as a string. The expectation is computed from the Network spec the way
# controllers/network/intent.go maps it and internal/render/srl/acl renders it (entry.go MatchTree).
acl::_jq_canon() {
  cat <<'JQ'
def drop_empty: with_entries(select(.value != null and .value != ""));
def canon_proto: if . == null or . == "" or . == "any" then null
  else (tostring | ascii_downcase) as $p | ({"icmpv6": "icmp6"}[$p] // $p) end;
def canon_port: if . == null or . == "" then null
  else tostring | if test("-") then "range:" + . else "eq:" + . end end;
def spec_entry: {seq: (.priority | tonumber), action: (if .action == "permit" then "accept" else "drop" end),
  match: ({proto: (.protocol | canon_proto), src: .sourcePrefix, dst: .destinationPrefix,
           sport: (.sourcePort | canon_port), dport: (.destinationPort | canon_port)} | drop_empty)};
def dev_port: if . == null then null
  elif has("range") then "range:\(.range.start | num)-\(.range.end | num)"
  elif has("value") then ((.operator // "eq") | idname) as $o | if $o == "eq" then "eq:\(.value | num)" else "\($o):\(.value | num)" end
  else tojson end;
def dev_entry($t): . as $e | ((.match // {})) as $m | ($m[$t] // {}) as $f
  | (if $t == "ipv6" then "next-header" else "protocol" end) as $pl
  | {seq: (.["sequence-id"] | num),
     action: ((.action // {}) | keys | map(select(. == "accept" or . == "drop")) | first // "none"),
     match: ({proto: ($f[$pl] | if . == null then null else (idname | tostring) end),
              src: ($f["source-ip"].prefix // null), dst: ($f["destination-ip"].prefix // null),
              sport: (($m.transport // {})["source-port"] | dev_port),
              dport: (($m.transport // {})["destination-port"] | dev_port)} | drop_empty)};
JQ
}

# acl::plan <network-json> — one TSV line per (access list, attachment):
#   <node> <filter> <type> <stage> <input|output> <interface-id> <seq,…> <expect-json>
# the expectation carries {filter, type, stage, entries[] (canonical, ascending), subinterfaceSpecific}
acl::plan() {
  local sid
  sid="$(acl::service_id "$(jq -r '.metadata.name' <<<"$1")")"
  jq -r --arg sid "$sid" "$ACL_JQLIB $(acl::_jq_canon)"'
    .spec as $s
    | ($s.accessLists // [])[] as $l
    | ("acl-" + $sid + "-" + $l.stage) as $f
    | ([$l.rules[] | spec_entry]
       + (if ($l.defaultAction // "") != "" then [{seq: 65535, action: (if $l.defaultAction == "permit" then "accept" else "drop" end), match: {}}] else [] end)
       | sort_by(.seq)) as $entries
    | {filter: $f, type: $l.type, stage: $l.stage, entries: $entries,
       subinterfaceSpecific: (if $l.stage == "egress" then "output-only" else null end)} as $exp
    | ($s.attachments // [])[] as $a
    | [$a.node, $f, $l.type, $l.stage, (if $l.stage == "ingress" then "input" else "output" end),
       ($a.attachment + "." + (($a.vlan // 0) | tostring)),
       ($entries | map(.seq | tostring) | join(",")), ($exp | tojson)] | @tsv' <<<"$1"
}

# acl::judge_written <filter-value-json> <expect-json> — the running filter against the
# expectation; prints one line per finding and "OK <n> entries" / returns 1 on any mismatch
acl::judge_written() {
  local out l bad=0
  out="$(jq -r --argjson exp "$2" "$ACL_JQLIB $(acl::_jq_canon)"'
    strip | unwrap("acl-filter") | aslist
    | map(select(. != null and . != {} and ((has("name") | not) or .name == $exp.filter))) | first
    | if . == null then ["MISSING filter \($exp.filter) type \($exp.type) is absent from running (C1)"]
      else . as $f
      | ((.entry // []) | aslist | map(dev_entry($exp.type))) as $dev
      | ($dev | map(.seq)) as $ds | ($exp.entries | map(.seq)) as $es
      | [ (if ($f.type // $exp.type | idname) != $exp.type then "TYPE \($f.type) is not \($exp.type)" else empty end),
          (if $ds != ($ds | sort) then "ORDER entries read as \($ds), not ascending" else empty end),
          (if ($ds | sort) != $es then "SEQUENCE running \($ds | sort) != declared \($es) (priorities unchanged; 65535 only with a default action)" else empty end),
          ($exp.entries[] as $e | ($dev | map(select(.seq == $e.seq)) | first) as $d
            | if $d == null then empty
              elif $d.action != $e.action then "ACTION entry \($e.seq): \($d.action) != declared \($e.action) (C2/C4)"
              elif $d.match != $e.match then "MATCH entry \($e.seq): \($d.match | tojson) != declared \($e.match | tojson) (C3)"
              else empty end),
          (if ($f["statistics-per-entry"] | tostring) != "true" then "STATISTICS statistics-per-entry is \($f["statistics-per-entry"]), not true" else empty end),
          (if $exp.subinterfaceSpecific != null and (($f["subinterface-specific"] // "") | idname) != $exp.subinterfaceSpecific
             then "SUBINTERFACE-SPECIFIC \($f["subinterface-specific"]) != \($exp.subinterfaceSpecific) (C7)" else empty end)
        ] + ["ENTRIES " + ($dev | map("\(.seq)=\(.action)\(.match | tojson)") | join(" "))]
      end | .[]' <<<"$1" 2>&1)" || { acl::say "UNREADABLE the running read is not a filter: $out"; return 1; }
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    acl::say "$l"
    [[ "$l" == ENTRIES* ]] || bad=1
  done <<<"$out"
  return "$bad"
}

# ---------------------------------------------------------------- device reads

# acl::read <node> <CONFIG|STATE> <path> — the first update value (module prefixes stripped) or
# null; the raw gnmic response goes to stdout of the check (the evidence record) via stderr
acl::read() {
  local node="$1" type="$2" path="$3" out rc=0
  lab::gnmic_argv "$node" || { echo null; return 0; }
  out="$("${LAB_ARGV[@]}" get --type "$type" --path "$path" 2>&1)" || rc=$?
  acl::say "--- gnmic get --type $type --path '$path' @ $node (rc=$rc)" >&2
  printf '%s\n' "$out" >&2
  if [[ "$rc" -ne 0 ]]; then echo null; return 0; fi
  jq -c "$ACL_JQLIB"' gvalues | if length == 0 then null else (.[0] | strip) end' <<<"$out" 2>/dev/null || echo null
}

acl::counter() { # <node> <filter> <type> <seq> — matched-packets or null
  acl::read "$1" STATE "/acl/acl-filter[name=$2][type=$3]/entry[sequence-id=$4]/statistics/matched-packets" \
    | jq -r "$ACL_JQLIB"' unwrap("matched-packets") | if . == null or . == {} then "null" else (num | tostring) end' 2>/dev/null || echo null
}

# ---------------------------------------------------------------- the checks

chk_written() {
  local node="$1" f="$2" t="$3" exp="$4" v rep=""
  jq -e --arg f "$f" --arg t "$t" '.filter == $f and .type == $t' <<<"$exp" >/dev/null 2>&1 \
    || exp="$(jq -c --arg f "$f" --arg t "$t" '.filter = $f | .type = $t' <<<"$exp")"
  _judge() {
    v="$(acl::read "$node" CONFIG "/acl/acl-filter[name=${f}][type=${t}]")"
    rep="$(acl::judge_written "$v" "$exp")" && { acl::say "$rep"; return 0; }
    acl::say "$rep"; return 1
  }
  if acl::poll _judge; then acl::verdict PASS written "$node ${f}/${t}: entries $(jq -r '[.entries[].seq] | join(",")' <<<"$exp") in declared order, actions and matches as declared (running)"; return 0; fi
  acl::verdict FAIL written "$node ${f}/${t}: $(grep -v '^ENTRIES' <<<"$rep" | tr '\n' ';')"; return 1
}

chk_binding() {
  local node="$1" ifid="$2" dir="$3" f="$4" t="$5" port idx v rep=""
  port="${ifid%.*}"; idx="${ifid##*.}"
  _judge() {
    v="$(acl::read "$node" CONFIG "/acl/interface[interface-id=${ifid}]")"
    rep="$(jq -r --arg d "$dir" --arg f "$f" --arg t "$t" --arg p "$port" --arg i "$idx" "$ACL_JQLIB"'
      unwrap("interface") | aslist | map(select(. != null and . != {})) | first
      | if . == null then "MISSING /acl/interface[interface-id] absent from running"
        else [ (if ((.[$d] // {})["acl-filter"] // [] | aslist | any(.name == $f and ((.type // "") | idname) == $t))
                then "BOUND \($f)/\($t) under \($d)" else "UNBOUND \($f)/\($t) not under \($d) (C6)" end),
               (if ((.["interface-ref"] // {}).interface // "") == $p and ((((.["interface-ref"] // {}).subinterface) // -1) | num | tostring) == $i
                then "REF interface-ref \($p) \($i)" else "NOREF interface-ref \((.["interface-ref"] // null) | tojson) != {\($p), \($i)} (C5)" end),
               "RUNNING input=\(((.input // {})["acl-filter"] // []) | aslist | map(.name) | join(",")) output=\(((.output // {})["acl-filter"] // []) | aslist | map(.name) | join(","))"
             ] | join("; ") end' <<<"$v" 2>/dev/null || echo "UNREADABLE")"
    acl::say "$rep"
    [[ "$rep" == BOUND*"; REF "* ]]
  }
  if acl::poll _judge; then acl::verdict PASS binding "$node ${ifid} ${dir} ${f}/${t} with interface-ref ${port}.${idx} (running)"; return 0; fi
  acl::verdict FAIL binding "$node ${ifid} ${dir} ${f}/${t}: $rep"; return 1
}

chk_stats() {
  local node="$1" f="$2" t="$3" seqs="$4" rep="" bad=0
  _judge() {
    local s v r
    bad=0; rep=""
    for s in ${seqs//,/ }; do
      v="$(acl::read "$node" STATE "/acl/acl-filter[name=${f}][type=${t}]/entry[sequence-id=${s}]/statistics")"
      r="$(jq -r "$ACL_JQLIB"' unwrap("statistics")
        | if . == null or . == {} or (type == "object" and (has("matched-packets") | not)) then "absent"
          elif ((.incomplete // false) | tostring) == "true" then "incomplete"
          else "readable(matched-packets=\(.["matched-packets"] | num))" end' <<<"$v" 2>/dev/null || echo absent)"
      rep+="entry ${s}: ${r}; "
      [[ "$r" == readable* ]] || bad=1
    done
    acl::say "$rep"
    [[ "$bad" -eq 0 ]]
  }
  if acl::poll _judge; then acl::verdict PASS stats "$node ${f}/${t} per-entry statistics readable, none incomplete: $rep"; return 0; fi
  acl::verdict FAIL stats "$node ${f}/${t}: $rep"; return 1
}

chk_programmed() {
  local node="$1" prog=""
  _judge() {
    prog="$(acl::read "$node" STATE "/acl/datapath-programming" | jq -r "$ACL_JQLIB"' unwrap("datapath-programming")
      | [((. // {})["forwarding-complex"] // [])[] | .["programming-complete"] | tostring]
      | if length == 0 then "none-listed" elif all(. == "true") then "true(\(length))" else "false(\(join(",")))" end' 2>/dev/null || echo unreadable)"
    acl::say "programming-complete: $prog"
    [[ "$prog" == true* ]]
  }
  if acl::poll _judge; then acl::verdict PASS programmed "$node ACL programming complete on every forwarding complex ($prog)"; return 0; fi
  acl::verdict FAIL programmed "$node programming-complete $prog (G1)"; return 1
}

# gone <node> <filter> <type> [<interface-id> <input|output>] — the filter is absent from running
# and (given an interface-id) so is its key under that binding. A read that ERRORS is never
# "absent": the device must answer and hold nothing there.
chk_gone() {
  local node="$1" f="$2" t="$3" ifid="${4:-}" dir="${5:-}" rep=""
  local -a paths=("/acl/acl-filter[name=${f}][type=${t}]")
  [[ -n "$ifid" ]] && paths+=("/acl/interface[interface-id=${ifid}]/${dir}/acl-filter[name=${f}][type=${t}]")
  _judge() {
    local p out rc v bad=0
    rep=""
    for p in "${paths[@]}"; do
      rc=0
      lab::gnmic_argv "$node" || return 1
      out="$("${LAB_ARGV[@]}" get --type CONFIG --path "$p" 2>&1)" || rc=$?
      acl::say "--- gnmic get --type CONFIG --path '$p' @ $node (rc=$rc)"; acl::say "$out"
      if [[ "$rc" -ne 0 ]]; then
        if grep -qiE 'NotFound|not found' <<<"$out"; then rep+="$p absent (NotFound); "; continue; fi
        rep+="$p unreadable (rc=$rc); "; bad=1; continue
      fi
      v="$(jq -c "$ACL_JQLIB"' [gvalues[] | strip | select(. != null and . != {} and . != [])] | length' <<<"$out" 2>/dev/null || echo 1)"
      if [[ "$v" == 0 ]]; then rep+="$p absent; "; else rep+="$p PRESENT; "; bad=1; fi
    done
    acl::say "$rep"
    [[ "$bad" -eq 0 ]]
  }
  if acl::poll _judge; then acl::verdict PASS gone "$node: $rep"; return 0; fi
  acl::verdict FAIL gone "$node: $rep"; return 1
}

chk_counters() {
  local node="$1" f="$2" t="$3" s
  for s in ${4//,/ }; do printf '%s %s\n' "$s" "$(acl::counter "$node" "$f" "$t" "$s" 2>/dev/null)"; done
}

chk_delta() {
  local node="$1" f="$2" t="$3"; shift 3
  [[ $# -gt 0 ]] || { acl::say "delta: no <seq>:<baseline>:<min> term" >&2; return 2; }
  local -a terms=("$@")
  local rep=""
  _judge() {
    local term s b m now bad=0
    rep=""
    for term in "${terms[@]}"; do
      IFS=: read -r s b m <<<"$term"
      now="$(acl::counter "$node" "$f" "$t" "$s" 2>/dev/null)"
      if [[ ! "$b" =~ ^[0-9]+$ || ! "$now" =~ ^[0-9]+$ ]]; then
        rep+="entry ${s}: baseline ${b} now ${now} (unreadable); "; bad=1; continue
      fi
      if [[ "$m" -gt 0 ]]; then
        rep+="entry ${s}: ${b} → ${now} moved $((now - b)) (want >= ${m}); "
        (( now - b >= m )) || bad=1
      else
        rep+="entry ${s}: ${b} → ${now} (want unmoved); "
        (( now == b )) || bad=1
      fi
    done
    acl::say "$node ${f}/${t}: $rep"
    [[ "$bad" -eq 0 ]]
  }
  if acl::poll _judge; then acl::verdict PASS delta "$node ${f}/${t}: exactly the expected entries moved — $rep"; return 0; fi
  acl::verdict FAIL delta "$node ${f}/${t}: $rep"; return 1
}

chk_ping() {
  local client="$1" dst="$2" want="$3" out rc rx
  [[ "$want" == ok || "$want" == fail ]] || { acl::say "ping: want ok|fail" >&2; return 2; }
  _judge() {
    rc=0
    out="$(lab::docker exec "$(lab::container "$client")" ping -c 3 -i 0.5 -W 2 "$dst" 2>&1)" || rc=$?
    acl::say "\$ ping -c 3 -i 0.5 -W 2 $dst @ $client (rc=$rc)"; acl::say "$out"
    if grep -qiE 'unrecognized option|invalid option|usage:|not found|no such file|network is unreachable|bad address' <<<"$out"; then
      acl::say "tool or route error — the probe did not run as a probe"; return 1
    fi
    rx="$(grep -oE '[0-9]+ (packets )?received' <<<"$out" | grep -oE '^[0-9]+' | tail -1)"
    rx="${rx:-0}"
    acl::say "received=${rx} of 3"
    if [[ "$want" == ok ]]; then [[ "$rc" -eq 0 && "$rx" -gt 0 ]]
    else grep -qE '(^| )3 packets transmitted' <<<"$out" && [[ "$rx" -eq 0 ]]; fi
  }
  if acl::poll _judge; then acl::verdict PASS ping "$client → $dst: $( [[ $want == ok ]] && echo answered || echo '100% loss' )"; return 0; fi
  acl::verdict FAIL ping "$client → $dst did not $( [[ $want == ok ]] && echo answer || echo 'lose every probe' ) (received ${rx:-?})"; return 1
}

chk_refused() {
  local manifest="$1" ns="$2" name="$3" holder="$4" out rc=0 got grc=0
  local -a dry=()
  [[ "${ACL_DRY_RUN:-0}" == 1 ]] && dry=(--dry-run=server)
  cat "$manifest"
  out="$(lab::kubectl create "${dry[@]}" -o name -f "$manifest" 2>&1)" || rc=$?
  acl::say "\$ kubectl create ${dry[*]} -f $(basename "$manifest")  (rc=$rc)"; acl::say "$out"
  got="$(lab::kubectl -n "$ns" get "$ACL_NET_RES" "$name" -o name 2>&1)" || grc=$?
  acl::say "\$ kubectl -n $ns get $ACL_NET_RES $name  (rc=$grc)"; acl::say "$got"
  if [[ "$rc" -eq 0 ]]; then
    if [[ "${#dry[@]}" -eq 0 ]]; then
      lab::kubectl -n "$ns" delete "$ACL_NET_RES" "$name" --wait=true --timeout=120s 2>&1 || true
      acl::say "the object admission accepted was deleted again"
    fi
    acl::verdict FAIL refused "$ns/$name was ACCEPTED by admission (holder $holder not enforced)"; return 1
  fi
  if [[ "$out" != *"Network ${holder}"* || "$out" != *"already carries"* ]]; then
    acl::verdict FAIL refused "$ns/$name refused, but not for the binding held by Network $holder: $(tail -1 <<<"$out")"; return 1
  fi
  if [[ "$grc" -eq 0 || "$got" != *NotFound* && "$got" != *"not found"* ]]; then
    acl::verdict FAIL refused "$ns/$name refused, yet kubectl get finds it: $got"; return 1
  fi
  acl::verdict PASS refused "$ns/$name refused by admission naming Network $holder; no object exists"
}

chk_accepted() {
  local manifest="$1" out rc=0
  cat "$manifest"
  out="$(lab::kubectl create --dry-run=server -o name -f "$manifest" 2>&1)" || rc=$?
  acl::say "\$ kubectl create --dry-run=server -f $(basename "$manifest")  (rc=$rc)"; acl::say "$out"
  if [[ "$rc" -eq 0 ]]; then acl::verdict PASS accepted "$(basename "$manifest"): admitted (server dry-run, nothing created)"; return 0; fi
  acl::verdict FAIL accepted "$(basename "$manifest"): refused: $(tail -1 <<<"$out")"; return 1
}

# ---------------------------------------------------------------- dispatch

acl::main() {
  local name="${1:-help}"; shift || true
  if [[ "$name" == help || "$name" == -h ]]; then sed -n 's/^chk_\([a-z_]*\)().*/\1/p' "${BASH_SOURCE[0]}" | sort; return 0; fi
  if ! declare -F "chk_${name}" >/dev/null; then echo "acl.sh: unknown check '$name'" >&2; return 2; fi
  case "$name" in
    refused|accepted|ping) ;;
    *) [[ -n "${GNMIC_PASSWORD:-}" ]] || lab::export_creds ;;
  esac
  "chk_${name}" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then acl::main "$@"; fi
