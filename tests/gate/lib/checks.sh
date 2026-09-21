#!/usr/bin/env bash
# Judgement functions are defined inside each check and invoked through _poll (SC2317).
# shellcheck disable=SC2317
# tests/gate/lib/checks.sh — the device assertions of the capability gate and the fabric checks
# (T043, T045, T051; FR-004, FR-108, NFR-013, SC-040).
#
# Every check is ONE command that reads the device (and, for the few that must, writes to it),
# prints the raw gNMI output it judged, prints a verdict line, and exits 0 on PASS and 1 on FAIL.
# That shape is what lets the same command be
#   * the readiness run:      evidence_run <id> --check <CHECK> --readiness -- bash checks.sh …
#   * its negative control:   evidence_negative_control <CHECK> -- bash checks.sh … (stock node /
#                             a service that does not exist) — which MUST exit non-zero
# so the device call and the judgement are captured together by the run that claims them.
#
# CHECK_WAIT=<seconds> makes a check re-read until it passes or the window closes (every attempt
# is printed); 0 (default) reads once. A negative control is run with the same window, so it shows
# the property was never observed during it.
#
# Credentials: GNMIC_USERNAME / GNMIC_PASSWORD in the environment (lab::export_creds), never argv.
#
# Usage: checks.sh <check> [args…]   (checks.sh help lists them)
set -euo pipefail

CHECKS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../lib/lab.sh
source "$CHECKS_ROOT/tests/lib/lab.sh"

: "${CHECK_WAIT:=0}"
: "${CHECK_INTERVAL:=5}"
JQLIB="$(lab::jq_lib)"

say()  { printf '%s\n' "$*"; }
verdict() { # verdict PASS|FAIL <check> <detail>
  printf 'CHECK %s: %s — %s\n' "$2" "$1" "$3"
}

# _get <node> <type> <path…> — gnmic get, raw JSON on stdout; returns gnmic's status
_get() {
  local node="$1" type="$2"; shift 2
  local -a paths=()
  local p
  for p in "$@"; do paths+=(--path "$p"); done
  lab::gnmic_argv "$node"
  "${LAB_ARGV[@]}" get --type "$type" "${paths[@]}"
}

# _read <node> <type> <path> — the first update value, module prefixes stripped; "null" if absent.
# The raw response is echoed to stderr->stdout of the check for the evidence record.
_read() {
  local node="$1" type="$2" path="$3" out rc=0
  out="$(_get "$node" "$type" "$path" 2>&1)" || rc=$?
  say "--- gnmic get --type $type --path '$path' @ $node (rc=$rc)" >&2
  printf '%s\n' "$out" >&2
  if [[ "$rc" -ne 0 ]]; then echo null; return 0; fi
  jq -c "$JQLIB"' gvalues | if length == 0 then null else (.[0] | strip) end' <<<"$out" 2>/dev/null || echo null
}

# _read_all <node> <type> <path> — every update as {path, value} (wildcard reads)
_read_all() {
  local node="$1" type="$2" path="$3" out rc=0
  out="$(_get "$node" "$type" "$path" 2>&1)" || rc=$?
  say "--- gnmic get --type $type --path '$path' @ $node (rc=$rc)" >&2
  printf '%s\n' "$out" >&2
  if [[ "$rc" -ne 0 ]]; then echo '[]'; return 0; fi
  jq -c "$JQLIB"' [ .[]? | .updates[]? | .values | to_entries[] | {path: .key, value: (.value | strip)} ]' <<<"$out" 2>/dev/null || echo '[]'
}

# _poll <fn> <args…> — run a judgement function until it passes or CHECK_WAIT elapses
_poll() {
  local deadline=$((SECONDS + CHECK_WAIT)) attempt=0
  while :; do
    attempt=$((attempt + 1))
    say "=== attempt ${attempt} ($(date -u +%H:%M:%SZ))"
    if "$@"; then return 0; fi
    (( SECONDS < deadline )) || return 1
    sleep "$CHECK_INTERVAL"
  done
}

# ============================================================================ G1 G2 G3

# capabilities <node> <expected-models.tsv> [extra-required-module…]
chk_capabilities() {
  local node="$1" tsv="$2"; shift 2
  local out rc=0
  lab::gnmic_argv "$node"
  out="$("${LAB_ARGV[@]}" --format json capabilities 2>&1)" || rc=$?
  printf '%s\n' "$out"
  [[ "$rc" -eq 0 ]] || { verdict FAIL capabilities "$node: Capabilities RPC failed (rc=$rc)"; return 1; }
  local caps
  caps="$(jq -c '
    def pick(re): [to_entries[] | select(.key | ascii_downcase | test(re)) | .value] | first;
    { version: (pick("version") // ""),
      models: ((pick("model") // []) | map({name: (.name // .Name // ""), org: (.organization // .Organization // ""), version: (.version // .Version // "")})),
      encodings: ((pick("encoding") // []) | map(tostring | ascii_upcase)) }' <<<"$out" 2>/dev/null)" || {
    verdict FAIL capabilities "$node: Capabilities output is not JSON"; return 1; }
  local bad=0 m r got
  if ! jq -e '.encodings | any(. == "JSON_IETF" or . == "4")' <<<"$caps" >/dev/null; then
    say "missing: JSON_IETF encoding"; bad=1
  fi
  if ! jq -e '.version | length > 0' <<<"$caps" >/dev/null; then say "missing: gNMI version"; bad=1; fi
  while IFS=$'\t' read -r m r; do
    [[ -z "$m" || "$m" == \#* ]] && continue
    got="$(jq -r --arg m "$m" '[.models[] | select(.name == $m or (.name | endswith(":" + $m)))] | first | .version // "ABSENT"' <<<"$caps")"
    if [[ "$got" == ABSENT ]]; then say "missing model: $m"; bad=1
    elif [[ -n "$r" && "$got" != "$r" ]]; then say "model $m at revision '$got', pinned '$r'"; bad=1
    else say "model $m revision $got: ok"; fi
  done <"$tsv"
  for m in "$@"; do
    jq -e --arg m "$m" 'any(.models[]; .name == $m or (.name | endswith(":" + $m)))' <<<"$caps" >/dev/null \
      || { say "missing model: $m"; bad=1; }
  done
  say "gNMI version: $(jq -r .version <<<"$caps"); models: $(jq '.models | length' <<<"$caps"); encodings: $(jq -c .encodings <<<"$caps")"
  if [[ "$bad" -eq 0 ]]; then verdict PASS capabilities "$node advertises the pinned model set and JSON_IETF"; return 0; fi
  verdict FAIL capabilities "$node: see the lines above"; return 1
}

# identity <node> <version-prefix> <chassis-type>
chk_identity() {
  local node="$1" want_v="$2" want_t="$3" v t
  v="$(_read "$node" STATE /system/information/version | jq -r "$JQLIB"' unwrap("version") | if type == "object" then .version else . end // ""')"
  t="$(_read "$node" STATE /platform/chassis/type | jq -r "$JQLIB"' unwrap("type") | if type == "object" then .type else . end // ""')"
  say "version=$v chassis-type=$t"
  if [[ "${v#v}" == "${want_v#v}"* && "$t" == "$want_t" ]]; then
    verdict PASS identity "$node runs $v on $t"; return 0
  fi
  verdict FAIL identity "$node: version '$v' (want ${want_v}*), chassis '$t' (want '$want_t')"; return 1
}

# features <node> <feature…> — each must be present in /system/features
chk_features() {
  local node="$1"; shift
  local f have missing=()
  have="$(_read "$node" STATE /system/features | jq -r "$JQLIB"' unwrap("features") | if type == "object" then .features else . end | aslist[]' 2>/dev/null)"
  say "features advertised: $(wc -l <<<"$have")"
  for f in "$@"; do grep -qxF "$f" <<<"$have" || missing+=("$f"); done
  if [[ ${#missing[@]} -eq 0 ]]; then verdict PASS features "$node advertises: $*"; return 0; fi
  verdict FAIL features "$node lacks: ${missing[*]}"; return 1
}

# ============================================================================ generic leaves

# value_equals <node> <CONFIG|STATE> <path> <json> — the leaf reads back exactly <json>
chk_value_equals() {
  local node="$1" type="$2" path="$3" want="$4" leaf got
  leaf="${path##*/}"; leaf="${leaf%%\[*}"
  _judge() {
    got="$(_read "$node" "$type" "$path" | jq -c --arg l "$leaf" "$JQLIB"' unwrap($l) | if type == "object" and has($l) then .[$l] else . end')"
    say "read $type $path = $got (want $want)"
    [[ "$(jq -c . <<<"$got")" == "$(jq -c . <<<"$want")" ]] && return 0
    # numbers may arrive as strings (uint64) — compare as text too
    [[ "$(jq -r . <<<"$got")" == "$(jq -r . <<<"$want")" ]]
  }
  if _poll _judge; then verdict PASS value "$node $type $path = $want"; return 0; fi
  verdict FAIL value "$node $type $path reads $got, not $want"; return 1
}

# absent <node> <CONFIG|STATE> <path> — nothing at the path (NotFound, no update, or null)
chk_absent() {
  local node="$1" type="$2" path="$3" got
  _judge() {
    got="$(_read "$node" "$type" "$path")"
    say "read $type $path = $got"
    [[ "$got" == null || "$got" == "{}" || "$got" == "[]" ]]
  }
  if _poll _judge; then verdict PASS absent "$node $type $path is absent"; return 0; fi
  verdict FAIL absent "$node $type $path is present: $got"; return 1
}

# present <node> <CONFIG|STATE> <path> — something exists at the path
chk_present() {
  local node="$1" type="$2" path="$3" got
  _judge() {
    got="$(_read "$node" "$type" "$path")"
    say "read $type $path = $got"
    [[ "$got" != null && "$got" != "{}" && "$got" != "[]" ]]
  }
  if _poll _judge; then verdict PASS present "$node $type $path exists"; return 0; fi
  verdict FAIL present "$node $type $path is absent"; return 1
}

# _restore <path> <json|DELETE|DELETE:<path>> — put a leaf back (LAB_ARGV already set)
_restore() {
  local path="$1" how="$2"
  case "$how" in
    "") return 0 ;;
    DELETE) "${LAB_ARGV[@]}" set --delete "$path" || true ;;
    DELETE:*) "${LAB_ARGV[@]}" set --delete "${how#DELETE:}" || true ;;
    *) "${LAB_ARGV[@]}" set --delimiter "$LAB_SET_DELIM" --update "$(lab::upd "$path" "$how")" || true ;;
  esac
}

# set_rejected <node> <path> <json> [<restore-json|DELETE|DELETE:path>] — the device refuses the Set; if it accepts
# it, the check FAILS and the previous value is written back (so a failure leaves nothing behind)
chk_set_rejected() {
  local node="$1" path="$2" val="$3" restore="${4:-}" out rc=0
  lab::gnmic_argv "$node"
  out="$("${LAB_ARGV[@]}" set --delimiter "$LAB_SET_DELIM" --update "$(lab::upd "$path" "$val")" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  if [[ "$rc" -ne 0 ]]; then
    verdict PASS rejected "$node refused $path = $val: $(grep -oE 'desc = .*|InvalidArgument.*|Error.*' <<<"$out" | head -1)"
    return 0
  fi
  _restore "$path" "$restore"
  verdict FAIL rejected "$node ACCEPTED $path = $val (restored to ${restore:-<nothing>})"; return 1
}

# ============================================================================ BGP / EVPN (G8, T051)

_bgp_state() { _read "$1" STATE "/network-instance[name=default]/protocols/bgp" | jq -c "$JQLIB"' unwrap("bgp")'; }

# bgp_sessions <node> [--evpn-up <ip,ip,…>] — every configured neighbour established; with
# --evpn-up, the EVPN family's own oper-state is up on each listed (overlay) neighbour
chk_bgp_sessions() {
  local node="$1"; shift
  local evpn_list=""
  [[ "${1:-}" == --evpn-up ]] && { evpn_list="$2"; shift 2; }
  local st rep
  _judge() {
    st="$(_bgp_state "$node")"
    rep="$(jq -r --arg ev "$evpn_list" "$JQLIB"'
      ($ev | split(",") | map(select(length > 0))) as $ov
      | (.neighbor // []) as $n
      | if ($n | length) == 0 then "NONE no neighbour configured" else
        ($n[] | . as $x
          | ((.["afi-safi"] // []) | map(select(.["afi-safi-name"] | idname == "evpn")) | first) as $e
          | "\(if .["session-state"] == "established" then "OK" else "BAD" end) \(.["peer-address"]) session=\(.["session-state"] // "?")"
            + (if ($ov | index($x["peer-address"])) then
                 " evpn-oper-state=\($e["oper-state"] // "absent")" + (if ($e["oper-state"] // "") == "up" then "" else " BADEVPN" end)
               else "" end)),
        ($ov[] | select(. as $a | ($n | map(.["peer-address"]) | index($a)) | not) | "BAD \(.) not configured")
        end' <<<"$st")"
    say "$rep"
    ! grep -qE '^(BAD|NONE)|BADEVPN' <<<"$rep"
  }
  if _poll _judge; then verdict PASS bgp-sessions "$node: every neighbour established${evpn_list:+, EVPN oper-state up on $evpn_list}"; return 0; fi
  verdict FAIL bgp-sessions "$node: $(grep -E '^(BAD|NONE)|BADEVPN' <<<"$rep" | tr '\n' ';')"; return 1
}

# evpn_received <node> zero|nonzero <ip,ip,…> — per-neighbour EVPN received-routes counter
chk_evpn_received() {
  local node="$1" want="$2" list="$3" st rep
  _judge() {
    st="$(_bgp_state "$node")"
    rep="$(jq -r --arg l "$list" "$JQLIB"'
      ($l | split(",")) as $ov
      | [(.neighbor // [])[] | select(.["peer-address"] as $a | $ov | index($a))
         | {a: .["peer-address"], r: ((.["afi-safi"] // []) | map(select(.["afi-safi-name"] | idname == "evpn")) | first | .["received-routes"] // null)}]
      | if length == 0 then "none" else map("\(.a) evpn received-routes=\(.r)") | join("\n") end' <<<"$st")"
    say "$rep"
    [[ "$rep" != none ]] || return 1
    case "$want" in
      zero)    ! grep -qvE 'received-routes=0$' <<<"$rep" ;;
      nonzero) ! grep -qE 'received-routes=(0|null)$' <<<"$rep" ;;
    esac
  }
  if _poll _judge; then verdict PASS evpn-received "$node: EVPN received-routes $want on $list"; return 0; fi
  verdict FAIL evpn-received "$node: EVPN received-routes not $want: $(tr '\n' ';' <<<"$rep")"; return 1
}

# evpn_route <node> <type 2|3|5> <originator-loopback> <via-ip,ip> [<prefix>] — the route type,
# originated by <originator>, received from a reflecting spine (the rib-in-post neighbor is one of
# <via>). Type 3 is matched on originating-router; 2 and 5 on the RD's address part; 5 on prefix.
chk_evpn_route() {
  local node="$1" rtype="$2" orig="$3" via="$4" prefix="${5:-}" rib rep
  _judge() {
    rib="$(_read "$node" STATE "/network-instance[name=default]/bgp-rib" | jq -c "$JQLIB"' unwrap("bgp-rib")')"
    rep="$(jq -r --arg t "$rtype" --arg o "$orig" --arg v "$via" --arg p "$prefix" "$JQLIB"'
      ($v | split(",")) as $via
      | [(.["afi-safi"] // [])[] | select(.["afi-safi-name"] | idname == "evpn") | .evpn["rib-in-out"]["rib-in-post"] // {}] | first // {}
      | (if $t == "3" then (.["imet-route"] // []) | map(select(.["originating-router"] == $o))
         elif $t == "2" then (.["mac-ip-route"] // []) | map(select(.["route-distinguisher"] | startswith($o + ":")))
         else (.["ip-prefix-route"] // []) | map(select((.["route-distinguisher"] | startswith($o + ":"))
                and ($p == "" or ("\(.["ip-prefix"])" | split("/")[0]) == ($p | split("/")[0]))))
         end)
      | map(. + {via_spine: (.neighbor as $n | $via | index($n) != null)})
      | if length == 0 then "none" else
          map("\(if .via_spine then "OK" else "NOTVIA" end) type-\($t) rd=\(.["route-distinguisher"]) neighbor=\(.neighbor)"
              + (if .["ip-prefix"] then " prefix=\(.["ip-prefix"])/\(.["ip-prefix-length"] // "")" else "" end)
              + (if .["mac-address"] then " mac=\(.["mac-address"]) ip=\(.["ip-address"] // "")" else "" end)) | join("\n") end' <<<"$rib")"
    say "$rep"
    grep -q '^OK ' <<<"$rep"
  }
  if _poll _judge; then verdict PASS evpn-route "$node received type-$rtype from $orig${prefix:+ ($prefix)} through a reflecting spine ($via)"; return 0; fi
  verdict FAIL evpn-route "$node: no type-$rtype from $orig${prefix:+ for $prefix} received through $via ($(head -3 <<<"$rep" | tr '\n' ';'))"; return 1
}

# route_active <node> <network-instance> <ipv4|ipv6> <route-type-regex> <prefix…> — each prefix
# present and active in the instance's route table with a route type matching the regex
chk_route_active() {
  local node="$1" ni="$2" afi="$3" rt="$4"; shift 4
  local tbl rep p missing
  local -a prefixes=("$@")   # _judge is called with no arguments: its "$@" would be empty
  [[ ${#prefixes[@]} -gt 0 ]] || { verdict FAIL route-active "$node $ni: no prefix to check"; return 1; }
  _judge() {
    tbl="$(_read "$node" STATE "/network-instance[name=${ni}]/route-table/${afi}-unicast" | jq -c "$JQLIB"' unwrap("'"$afi"'-unicast")')"
    missing=()
    for p in "${prefixes[@]}"; do
      rep="$(jq -r --arg p "$p" --arg rt "$rt" --arg k "${afi}-prefix" "$JQLIB"'
        [(.route // [])[] | select(.[$k] == $p and ((.["route-type"] | idname) | test($rt)))]
        | if length == 0 then "absent" else map("\(.["route-type"] | idname) active=\(.active)") | join(",") end' <<<"$tbl")"
      say "$ni $afi $p: $rep"
      grep -q 'active=true' <<<"$rep" || missing+=("$p")
    done
    [[ ${#missing[@]} -eq 0 ]]
  }
  if _poll _judge; then verdict PASS route-active "$node $ni: $* active ($rt)"; return 0; fi
  verdict FAIL route-active "$node $ni: not active ($rt): ${missing[*]}"; return 1
}

# reflector <spine> — inter-as-vpn and route-reflector client read back true from the CONFIGURATION
# datastore (--type config). A configuration-integrity check, never applied-side behaviour: SR Linux
# 25.7.1 does not mirror either leaf into state (AD-76; G4 part B records that), so the state read
# AD-31 first described cannot see them. The output lines keep the form "inter-as-vpn=… …".
chk_reflector() {
  local node="$1" st iav rrc
  st="$(_read "$node" CONFIG "/network-instance[name=default]/protocols/bgp" | jq -c "$JQLIB"' unwrap("bgp")')"
  iav="$(jq -r "$JQLIB"' [(.["afi-safi"] // [])[] | select(.["afi-safi-name"] | idname == "evpn") | .evpn["inter-as-vpn"]] | first // "absent"' <<<"$st")"
  rrc="$(jq -r "$JQLIB"' [(.group // [])[] | select(.["route-reflector"].client == true) | .["group-name"]] | join(",")' <<<"$st")"
  say "inter-as-vpn=$iav route-reflector-client-groups=${rrc:-none} (configuration datastore)"
  if [[ "$iav" == true && -n "$rrc" ]]; then
    verdict PASS reflector "$node: inter-as-vpn true, route-reflector client true on $rrc (configuration-integrity, read from config)"; return 0
  fi
  verdict FAIL reflector "$node: inter-as-vpn=$iav, route-reflector client groups=${rrc:-none} (read from config)"; return 1
}

# evpn_route_withdrawn <node> <type 2|3|5> <originator-loopback> <via-ip,ip> [<prefix>] — the
# inverse of evpn_route: NO such route is held from a reflecting spine. Polled with CHECK_WAIT, so
# it is the bounded wait for a withdrawal after a reflection-stopping change (G8, AD-77) — a record,
# never the negative control itself (that is evpn_route, run to FAIL, after this has passed).
chk_evpn_route_withdrawn() {
  local out
  local -a args=("$@")   # _judge is called with no arguments: its "$@" would be empty
  _judge() {
    # a subshell: chk_evpn_route defines its own _judge, which must not replace this one
    out="$(CHECK_WAIT=0 chk_evpn_route "${args[@]}" 2>&1 || true)"
    say "$out"
    # a failed read is never taken for a withdrawal
    grep -q -- '^--- gnmic get .*(rc=0)$' <<<"$out" || return 1
    ! grep -q '^CHECK evpn-route: PASS' <<<"$out"
  }
  if _poll _judge; then verdict PASS evpn-route-withdrawn "$1: no type-$2 from $3${5:+ ($5)} held through $4"; return 0; fi
  verdict FAIL evpn-route-withdrawn "$1: type-$2 from $3${5:+ ($5)} still held through $4 at the end of the window"; return 1
}

# no_tenant <spine> — no mac-vrf / ip-vrf and no vxlan-interface on the node
chk_no_tenant() {
  local node="$1" nis tun
  nis="$(_read "$node" CONFIG /network-instance | jq -r "$JQLIB"' aslist | map(if has("network-instance") then .["network-instance"][] else . end) | .[]? | select((.type // "" | idname) | IN("mac-vrf","ip-vrf")) | select((.["vxlan-interface"] // []) | length > 0) | .name' 2>/dev/null || true)"
  tun="$(_read "$node" CONFIG /tunnel-interface | jq -r "$JQLIB"' aslist | map(if has("tunnel-interface") then .["tunnel-interface"][] else . end) | .[]? | select((.["vxlan-interface"] // []) | length > 0) | .name' 2>/dev/null || true)"
  if [[ -z "$nis" && -z "$tun" ]]; then verdict PASS no-tenant "$node terminates no tenant VXLAN (no mac-vrf/ip-vrf bound to a vxlan-interface, no vxlan-interface)"; return 0; fi
  verdict FAIL no-tenant "$node carries tenant objects: ${nis//$'\n'/,} ${tun//$'\n'/,}"; return 1
}

# vtep_source <leaf> <system0-ipv4> <remote-leaf> <vni> — the remote leaf's flooding list for <vni>
# carries this leaf's system0.0 address as the VTEP, and the vxlan-interface egress source is
# use-system-ipv4-address
chk_vtep_source() {
  local leaf="$1" addr="$2" remote="$3" vni="$4" src mc
  src="$(_read "$leaf" CONFIG "/tunnel-interface[name=vxlan0]/vxlan-interface[index=${vni}]/egress/source-ip" | jq -r "$JQLIB"' unwrap("source-ip") | if type == "object" then .["source-ip"] else . end // "default"')"
  mc="$(_read "$remote" STATE "/tunnel-interface[name=vxlan0]/vxlan-interface[index=${vni}]/bridge-table/multicast-destinations" | jq -r "$JQLIB"' unwrap("multicast-destinations") | [(.destination // [])[] | .vtep] | join(",")')"
  say "egress source-ip=$src; $remote flooding list for vni $vni: $mc"
  if [[ ( "$src" == use-system-ipv4-address || "$src" == default ) && ",$mc," == *",$addr,"* ]]; then
    verdict PASS vtep-source "$leaf uses system0.0 ($addr) as its VTEP source"; return 0
  fi
  verdict FAIL vtep-source "$leaf: source-ip=$src, remote flooding list '$mc' lacks $addr"; return 1
}

# ============================================================================ clients (G6, G8)

# ping <client> <4|6> <dst> <payload|-> ok|fail — from the client's scratch VLAN interface.
# A sized probe needs Don't-Fragment (-M do). The endpoints' busybox ping has no -M, so a sized
# probe runs iputils ping (CHECK_PING, default the host's) INSIDE the client's network namespace
# (nsenter -n on the container's pid): same interfaces, addresses and MTU as the client, but a
# ping that can set DF. A tool error (unknown option, usage, no such binary) is never a verdict in
# either direction — it FAILs, so a probe that did not run cannot pass as "fail" (negative control).
chk_ping() {
  local client="$1" fam="$2" dst="$3" size="$4" want="$5" out rc=0 pid
  local -a cmd=(ping -c 3 -i 0.3 -W 2) run
  [[ "$fam" == 6 ]] && cmd=(ping -6 -c 3 -i 0.3 -W 2)
  if [[ "$size" != - ]]; then
    cmd=("${CHECK_PING:-ping}" "${cmd[@]:1}" -M "do" -s "$size")
    pid="$(lab::docker inspect -f '{{.State.Pid}}' "$(lab::container "$client")" 2>/dev/null)" || pid=""
    if [[ -z "$pid" || "$pid" == 0 ]]; then verdict FAIL ping "$client: no running container to enter"; return 1; fi
    say "sized probe: $("${CHECK_PING:-ping}" -V 2>&1 | head -1) in the network namespace of $client (pid $pid)"
    run=(nsenter -t "$pid" -n --)
  else
    run=(lab::docker exec "$(lab::container "$client")")
  fi
  cmd+=("$dst")
  _judge() {
    rc=0
    out="$("${run[@]}" "${cmd[@]}" 2>&1)" || rc=$?
    say "\$ ${cmd[*]}  (rc=$rc)"; say "$out"
    if grep -qiE 'unrecognized option|invalid option|usage:|not found|no such file' <<<"$out"; then
      say "tool error — the probe did not run"; return 1
    fi
    if [[ "$want" == ok ]]; then [[ "$rc" -eq 0 ]]; else [[ "$rc" -ne 0 ]]; fi
  }
  if _poll _judge; then verdict PASS ping "$client ${cmd[*]} → $want"; return 0; fi
  verdict FAIL ping "$client ${cmd[*]} did not $want"; return 1
}

# ============================================================================ ACL (G9)

# acl_applied <node> <filter> <ipv4|ipv6> <interface-id> <input|output> <seq,seq,…> — keyed
# read-back of THIS filter, type, entry and direction: the keyed binding — this filter's name and
# type under this subinterface's input or output — is in the running (configuration) datastore;
# each entry occupies TCAM on the bound direction and none on the other (A1–A3, keyed by filter
# name, type and sequence-id); and ACL programming is complete. The applied side of the binding
# itself (A4) is acl_matched below: SR Linux 25.7.1 mirrors no part of /acl/interface into state
# (neither the binding nor interface-ref — observed live 2026-09-21, AD-82 decision
# 2026-09-21-acl-binding-state, which corrects AD-79's premise), so the keyed binding in state and
# the per-subinterface entry list under it are printed as OBSERVATION lines, never judged.
chk_acl_applied() {
  local node="$1" f="$2" t="$3" ifid="$4" dir="$5" seqs="$6" rep="" s bad=0
  _judge() {
    bad=0; rep=""
    local bind sbind prog
    bind="$(_read "$node" CONFIG "/acl/interface[interface-id=${ifid}]/${dir}/acl-filter[name=${f}][type=${t}]")"
    [[ "$bind" != null ]] || { rep+="binding ${ifid} ${dir} ${f}/${t} absent from running; "; bad=1; }
    # observation only: the keyed binding in state (not mirrored on 25.7.1; A4 is acl_matched)
    sbind="$(_read "$node" STATE "/acl/interface[interface-id=${ifid}]/${dir}/acl-filter[name=${f}][type=${t}]" | jq -r --arg n "$f" --arg t "$t" "$JQLIB"'
      unwrap("acl-filter") | aslist | map(select(. != null and . != {})) | .[0]
      | if . == null then "absent"
        elif type == "object" and ((has("name") and .name != $n) or (has("type") and (.type | idname) != $t)) then "absent"
        else "present" end' 2>/dev/null || echo absent)"
    say "OBSERVATION state-binding ${ifid} ${dir} ${f}/${t} ${sbind}"
    for s in ${seqs//,/ }; do
      local tc per
      tc="$(_read "$node" STATE "/acl/acl-filter[name=${f}][type=${t}]/entry[sequence-id=${s}]/tcam-entries" | jq -c "$JQLIB"'
        unwrap("tcam-entries") | [(.["forwarding-complex"] // [])[] | {i: (.["input-total"] | num), o: (.["output-total"] | num), s: (.["single-instance"] | num)}]
        | {i: (map(.i) | add // 0), o: (map(.o) | add // 0), s: (map(.s) | add // 0)}')"
      rep+="entry ${s}: tcam ${tc}; "
      if [[ "$dir" == input ]]; then
        jq -e '.i > 0 and .o == 0' <<<"$tc" >/dev/null || bad=1
      else
        jq -e '.o > 0 and .i == 0' <<<"$tc" >/dev/null || bad=1
      fi
      # observation only (AD-79): the per-subinterface entry list under this binding
      per="$(_read "$node" STATE "/acl/interface[interface-id=${ifid}]/${dir}/acl-filter[name=${f}][type=${t}]/entry[sequence-id=${s}]")"
      if [[ "$per" == null || "$per" == "{}" ]]; then say "OBSERVATION per-subinterface-entry ${ifid} ${dir} ${f}/${t} ${s} absent"
      else say "OBSERVATION per-subinterface-entry ${ifid} ${dir} ${f}/${t} ${s} present"; fi
    done
    prog="$(_read "$node" STATE "/acl/datapath-programming" | jq -r "$JQLIB"' unwrap("datapath-programming") | [(.["forwarding-complex"] // [])[] | .["programming-complete"]] | if length == 0 then "unknown" else (all(. == true) | tostring) end')"
    rep+="programming-complete=${prog}"
    [[ "$prog" == false ]] && bad=1
    say "$rep"
    [[ "$bad" -eq 0 ]]
  }
  if _poll _judge; then verdict PASS acl-applied "$node ${f}/${t} bound ${dir} on ${ifid} (keyed binding in running), entries ${seqs} in TCAM on ${dir} only"; return 0; fi
  verdict FAIL acl-applied "$node ${f}/${t} ${dir} ${ifid}: $rep"; return 1
}

# acl_counter <node> <filter> <ipv4|ipv6> <seq> — prints this filter entry's matched-packets
# (keyed by filter name, type and sequence-id), or "null" when the device reports none.
chk_acl_counter() {
  local node="$1" f="$2" t="$3" s="$4"
  _read "$node" STATE "/acl/acl-filter[name=${f}][type=${t}]/entry[sequence-id=${s}]/statistics/matched-packets" 2>/dev/null \
    | jq -r 'if . == null then "null" else (tostring | tonumber? // "null") end' 2>/dev/null || echo null
}

# acl_matched <node> <filter> <ipv4|ipv6> <seq> <baseline> — A4, the applied side of a binding
# (AD-82 decision 2026-09-21-acl-binding-state): after traffic that can only have met this filter on
# its one binding, this filter entry's own matched-packets counter (keyed by filter name, type and
# sequence-id) is above the baseline read before the traffic. A filter that is not programmed, not
# bound where the traffic flows, or absent reads no counter or no increase and fails.
chk_acl_matched() {
  local node="$1" f="$2" t="$3" s="$4" base="$5" now=null
  _judge() {
    now="$(_read "$node" STATE "/acl/acl-filter[name=${f}][type=${t}]/entry[sequence-id=${s}]/statistics/matched-packets" \
      | jq -r 'if . == null then "null" else (tostring | tonumber? // "null") end' 2>/dev/null || echo null)"
    say "matched-packets ${f}/${t} entry ${s}: baseline ${base}, now ${now}"
    [[ "$now" =~ ^[0-9]+$ && "$base" =~ ^[0-9]+$ ]] && (( now > base ))
  }
  if _poll _judge; then verdict PASS acl-matched "$node ${f}/${t} entry ${s} matched traffic on its binding (${base} → ${now})"; return 0; fi
  verdict FAIL acl-matched "$node ${f}/${t} entry ${s}: matched-packets ${base} → ${now} (no traffic met this entry)"; return 1
}

# ============================================================================ SDC schema (G10)

# sdc_rejects <manifest> / sdc_accepts <manifest> — a server-side dry-run create of a Config: the
# config-server runs a data-server TransactionSet{DryRun:true} against the deviated schema
chk_sdc_rejects() {
  local f="$1" out rc=0
  cat "$f"
  out="$(lab::kubectl create --dry-run=server -o name -f "$f" 2>&1)" || rc=$?
  say "\$ kubectl create --dry-run=server -f $(basename "$f")  (rc=$rc)"; say "$out"
  if [[ "$rc" -ne 0 ]]; then verdict PASS sdc-rejects "$(basename "$f"): refused by the deviated schema"; return 0; fi
  verdict FAIL sdc-rejects "$(basename "$f"): ACCEPTED by the deviated schema"; return 1
}
chk_sdc_accepts() {
  local f="$1" out rc=0
  cat "$f"
  out="$(lab::kubectl create --dry-run=server -o name -f "$f" 2>&1)" || rc=$?
  say "\$ kubectl create --dry-run=server -f $(basename "$f")  (rc=$rc)"; say "$out"
  if [[ "$rc" -eq 0 ]]; then verdict PASS sdc-accepts "$(basename "$f"): accepted"; return 0; fi
  verdict FAIL sdc-accepts "$(basename "$f"): refused"; return 1
}

# ============================================================================ Subscribe (G7)

# subscribe_sample <node> <seconds> <path…> — a sample-mode stream delivers >= 2 updates per path
chk_subscribe_sample() {
  local node="$1" secs="$2"; shift 2
  local -a paths=()
  local p out n
  for p in "$@"; do paths+=(--path "$p"); done
  [[ $# -le 36 ]] || { verdict FAIL subscribe-sample "more than 36 paths requested"; return 1; }
  lab::gnmic_argv "$node"
  local err; err="$(mktemp)"
  # gnmic prints "received signal 'terminated'. terminating..." on STDOUT when timeout stops it (observed
  # live, gnmic 0.47.0); left in, it made the whole stream unparseable and the count 0. Its stderr is kept
  # apart, and that one line is shown but dropped from the parse.
  out="$(timeout "$secs" "${LAB_ARGV[@]}" --format event subscribe --mode stream --stream-mode sample \
    --sample-interval 5s "${paths[@]}" 2>"$err")" || true
  printf '%s\n' "$out"; cat "$err"; rm -f "$err"
  out="$(grep -v "^received signal " <<<"$out" || true)"
  # "repeated": the most updates any ONE leaf instance (path + keys) received — several neighbours in a
  # single sample round are not a repeat
  n="$(jq -s '[.[] | if type == "array" then .[] else . end | select(.values != null)
             | (.tags | del(.["subscription-name"]) | tostring) as $k | .values | keys[] | "\($k) \(.)"]
             | group_by(.) | map(length) | max // 0' <<<"$out" 2>/dev/null || echo 0)"
  if [[ "$n" -ge 2 ]]; then verdict PASS subscribe-sample "$node: one leaf sampled $n times in ${secs}s for $# path(s)"; return 0; fi
  verdict FAIL subscribe-sample "$node: no leaf sampled more than ${n:-0} time(s) in ${secs}s"; return 1
}

# subscribe_onchange <node> <path> <set-path> <value> <restore-value|DELETE|DELETE:path> — an on-change stream
# delivers an update after the leaf is disturbed (the disturbance is scratch: vt-scratch- values)
chk_subscribe_onchange() {
  local node="$1" path="$2" spath="$3" val="$4" restore="$5" tmp out
  tmp="$(mktemp)"
  lab::gnmic_argv "$node"
  timeout 25 "${LAB_ARGV[@]}" --format event subscribe --mode stream --stream-mode on-change \
    --heartbeat-interval 60s --path "$path" >"$tmp" 2>&1 &
  local pid=$!
  sleep 6
  say "--- disturbing: set $spath = $val"
  "${LAB_ARGV[@]}" set --delimiter "$LAB_SET_DELIM" --update "$(lab::upd "$spath" "$val")" || true
  sleep 6
  say "--- restoring $spath ($restore)"
  _restore "$spath" "$restore"
  wait "$pid" || true
  out="$(cat "$tmp")"; rm -f "$tmp"
  printf '%s\n' "$out"
  local plain="${val//\"/}"
  if grep -qF -- "$plain" <<<"$out"; then verdict PASS subscribe-onchange "$node: on-change update for $path observed after the disturbance"; return 0; fi
  verdict FAIL subscribe-onchange "$node: no on-change update carrying '$plain' for $path"; return 1
}

# ============================================================================ G4 durability

# startup_contains <node> <string> / startup_lacks <node> <string> — the saved startup
# configuration (/etc/opt/srlinux/config.json inside the node) does / does not carry <string>
chk_startup_contains() {
  local node="$1" str="$2" n
  _judge() {
    n="$(lab::docker exec "$(lab::container "$node")" grep -c -F -- "$str" /etc/opt/srlinux/config.json 2>&1 || true)"
    say "grep -c '$str' /etc/opt/srlinux/config.json @ $node → $n"
    [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]]
  }
  if _poll _judge; then verdict PASS startup-contains "$node's saved startup configuration carries '$str' (durable)"; return 0; fi
  verdict FAIL startup-contains "$node's saved startup configuration does not carry '$str'"; return 1
}
chk_startup_lacks() {
  local node="$1" str="$2" n
  _judge() {
    n="$(lab::docker exec "$(lab::container "$node")" grep -c -F -- "$str" /etc/opt/srlinux/config.json 2>&1 || true)"
    say "grep -c '$str' /etc/opt/srlinux/config.json @ $node → $n"
    [[ "$n" == 0 ]]
  }
  if _poll _judge; then verdict PASS startup-lacks "$node's saved startup configuration no longer carries '$str'"; return 0; fi
  verdict FAIL startup-lacks "$node's saved startup configuration still carries '$str' ($n)"; return 1
}

# ============================================================================ G6 tenant MTU

# mtu_commit_probe <leaf> <irb-subif-path> <over> <ok> — an OBSERVATION, not a readiness check
# (AD-78): the device's response at commit to an IRB ip-mtu one byte above the tenant IP MTU. The
# tenant boundary itself is asserted on the data plane (G6's 9320/9300 payload probes); SR Linux
# 25.7.1 was observed to accept 9349 and keep the IRB up. Prints one line
#   OBSERVATION {"value":…,"accepted_at_commit":…,"irb_oper_state":…,"restored":…}
# and writes the tenant MTU back either way. Exit 0 once the observation is made and nothing is left
# changed; 1 only when the tenant MTU could not be written back (a leftover, never an answer).
chk_mtu_commit_probe() {
  local leaf="$1" sub="$2" over="$3" ok="$4" out rc=0 st='{}' accepted=false restored=true back
  lab::gnmic_argv "$leaf"
  out="$("${LAB_ARGV[@]}" set --delimiter "$LAB_SET_DELIM" --update "$(lab::upd "$sub/ip-mtu" "$over")" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  if [[ "$rc" -eq 0 ]]; then
    accepted=true
    sleep 3
    st="$(_read "$leaf" STATE "$sub" | jq -c "$JQLIB"' {oper: .["oper-state"], reason: .["oper-down-reason"], mtu: .["ip-mtu"]}')"
    say "accepted at commit; IRB state now: $st"
    _restore "$sub/ip-mtu" "$ok"
    back="$(_read "$leaf" CONFIG "$sub/ip-mtu" | jq -r "$JQLIB"' unwrap("ip-mtu") | if type == "object" then .["ip-mtu"] else . end')"
    [[ "$back" == "$ok" ]] || restored=false
  else
    say "rejected at commit: $(grep -oE 'desc = .*' <<<"$out" | head -1)"
  fi
  say "OBSERVATION $(jq -cn --argjson v "$over" --argjson a "$accepted" --argjson st "$st" --argjson r "$restored" \
    '{value: $v, accepted_at_commit: $a, irb_oper_state: ($st.oper // null), irb_oper_down_reason: ($st.reason // null), restored: $r}')"
  if [[ "$restored" == true ]]; then
    verdict PASS mtu-commit-probe "$leaf ip-mtu $over on ${sub}: accepted_at_commit=$accepted (observation); tenant MTU $ok in place"; return 0
  fi
  verdict FAIL mtu-commit-probe "$leaf: ip-mtu $over was accepted and could NOT be written back to $ok on $sub"; return 1
}

# ============================================================================ G7 collector

# otel_series <namespace> <pod> <port> <regex…> — the collector's Prometheus exporter, read once
# through the API server's pod proxy, exposes a series whose name matches each regex
chk_otel_series() {
  local ns="$1" pod="$2" port="$3"; shift 3
  local out names re missing=()
  local -a regexes=("$@")   # _judge is called with no arguments: its "$@" would be empty
  [[ ${#regexes[@]} -gt 0 ]] || { verdict FAIL otel-series "no series to check"; return 1; }
  _judge() {
    out="$(lab::kubectl get --raw "/api/v1/namespaces/${ns}/pods/${pod}:${port}/proxy/metrics" 2>&1)" || out=""
    names="$(grep -vE '^#' <<<"$out" | sed -nE 's/^([a-zA-Z_:][a-zA-Z0-9_:]*).*/\1/p' | sort -u)"
    say "series names exposed: $(wc -l <<<"$names")"; say "$names"
    missing=()
    for re in "${regexes[@]}"; do grep -qE "$re" <<<"$names" || missing+=("$re"); done
    [[ ${#missing[@]} -eq 0 ]]
  }
  if _poll _judge; then verdict PASS otel-series "every required series is exposed: $*"; return 0; fi
  verdict FAIL otel-series "missing series matching: ${missing[*]}"; return 1
}

# ============================================================================ G13 deviation

# deviation_watch <namespace> <config> <node> <path> <intent-json> <window-seconds> — after drift
# was injected: poll (1 s) the Config's Deviation and the device value until the intent is back or
# the window closes. Prints the timeline and, last, one JSON summary line. Exit 0 unless neither a
# deviation nor a restoration was observed (the only G13 failure, AD-34).
chk_deviation_watch() {
  local ns="$1" cfg="$2" node="$3" path="$4" intent="$5" window="$6"
  local start=$SECONDS t dev reasons val seen_dev=false first_dev=null restored=false t_restore=null all_reasons="[]"
  local leaf="${path##*/}"
  while (( SECONDS - start <= window )); do
    t=$((SECONDS - start))
    dev="$(lab::kubectl -n "$ns" get deviations.config.sdcio.dev "config-${cfg}" -o json 2>/dev/null || echo '{}')"
    reasons="$(jq -c '[.spec.deviations[]? | .reason] | unique' <<<"$dev" 2>/dev/null || echo '[]')"
    all_reasons="$(jq -c --argjson a "$all_reasons" --argjson b "$reasons" -n '$a + $b | unique')"
    val="$(_read "$node" CONFIG "$path" 2>/dev/null | jq -c --arg l "$leaf" "$JQLIB"' unwrap($l) | if type == "object" and has($l) then .[$l] else . end')"
    say "t=${t}s deviation-reasons=${reasons} device=${val}"
    if [[ "$seen_dev" == false ]] && jq -e 'index("NOT_APPLIED") != null' <<<"$reasons" >/dev/null; then
      seen_dev=true; first_dev="$t"
    fi
    if [[ "$(jq -c . <<<"$val")" == "$(jq -c . <<<"$intent")" ]]; then
      restored=true; t_restore="$t"; break
    fi
    sleep 1
  done
  local summary
  summary="$(jq -cn --argjson v "$seen_dev" --argjson fd "$first_dev" --argjson r "$restored" --argjson tr "$t_restore"     --argjson reasons "$all_reasons" --argjson w "$window"     '{deviation_visible_before_restore: ($v and ($fd != null) and ($tr == null or $fd <= $tr)),
      not_applied_first_seen_after_seconds: $fd, restoration_observed: $r, time_to_restoration_seconds: $tr,
      reason_strings_seen: $reasons, observation_window_seconds: $w, poll_interval_seconds: 1}')"
  say "SUMMARY $summary"
  if [[ "$seen_dev" == true || "$restored" == true ]]; then
    verdict PASS deviation-watch "deviation visible=$seen_dev, restoration observed=$restored"; return 0
  fi
  verdict FAIL deviation-watch "neither a NOT_APPLIED deviation nor a restoration was observed in ${window}s"; return 1
}

# ============================================================================ dispatch

usage() {
  sed -n 's/^chk_\([a-z_]*\)().*/\1/p' "${BASH_SOURCE[0]}" | sort
}

main() {
  local name="${1:-help}"; shift || true
  if [[ "$name" == help || "$name" == -h ]]; then usage; return 0; fi
  if ! declare -F "chk_${name}" >/dev/null; then echo "checks.sh: unknown check '$name'" >&2; usage >&2; return 2; fi
  [[ -n "${GNMIC_PASSWORD:-}" ]] || lab::export_creds
  "chk_${name}" "$@"
}

main "$@"
