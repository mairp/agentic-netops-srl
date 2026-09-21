#!/usr/bin/env bash
# tests/unit/gate/checks_args_test.sh — regression for the nested-_judge argument defect found live on
# 2026-09-21: chk_route_active (and chk_otel_series) looped over "$@" inside _judge, which _poll calls
# with no arguments, so the loop ran zero times and the check PASSED on an empty route table — caught by
# the gate's own negative control (NFR-013). Against a fake gnmic: an empty table FAILS, a table carrying
# the prefix active PASSES, one carrying it inactive FAILS, and no prefix at all FAILS. Plus subscribe_sample
# (below), and the T187 criteria (AD-76, AD-78, AD-79, AD-77) against a fake that answers per --type and
# --path: reflector reads the CONFIG datastore (state carrying the leaves is not enough, config carrying
# them is); acl_applied judges the running binding + TCAM, A4 is acl_matched, and the per-subinterface entry list is only an
# OBSERVATION line; evpn_route_withdrawn passes on an empty RIB, fails while the route is held and never
# takes a failed read for a withdrawal; mtu_commit_probe records accepted/rejected and fails only when the
# tenant MTU is not back.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gnmic" <<'G'
#!/usr/bin/env bash
# FAKE_GNMIC_MAP: lines "<TYPE|*><TAB><ERE on the path><TAB><file>" — first match answers a get
# (no match: a response with no update); a missing file answers rc 1. A set exits FAKE_GNMIC_SET_RC.
if [[ -n "${FAKE_GNMIC_MAP:-}" ]]; then
  type=""; path=""; op=""
  for ((i = 1; i <= $#; i++)); do
    case "${!i}" in
      get|set) op="${!i}" ;;
      --type) j=$((i + 1)); type="${!j}" ;;
      --path) j=$((i + 1)); path="${!j}" ;;
    esac
  done
  if [[ "$op" == set ]]; then echo "fake set: $*"; exit "${FAKE_GNMIC_SET_RC:-0}"; fi
  while IFS=$'\t' read -r t re f; do
    [[ -n "$t" ]] || continue
    [[ "$t" == "*" || "${t,,}" == "${type,,}" ]] || continue
    grep -qE -- "$re" <<<"$path" || continue
    [[ -f "$f" ]] || { echo "rpc error: code = NotFound" >&2; exit 1; }
    cat "$f"; exit 0
  done <"$FAKE_GNMIC_MAP"
  echo '[{"source":"x:57400","timestamp":1}]'; exit 0
fi
cat "$FAKE_GNMIC_OUT"
[[ -n "${FAKE_GNMIC_ERR:-}" ]] && echo "$FAKE_GNMIC_ERR" >&2
[[ -n "${FAKE_GNMIC_TAIL:-}" ]] && echo "$FAKE_GNMIC_TAIL"
exit 0
G
chmod +x "$TMP/bin/gnmic"
export PATH="$TMP/bin:$PATH" GNMIC_USERNAME=u GNMIC_PASSWORD=p CHECK_WAIT=0 CLUSTER_NAME=t LAB_NAME=t
empty='[{"source":"x:57400","timestamp":1}]'
route() { # <active>
  printf '[{"source":"x:57400","updates":[{"Path":"network-instance[name=default]/route-table/ipv4-unicast","values":{"srl_nokia-network-instance:network-instance/route-table/srl_nokia-ip-route-tables:ipv4-unicast":{"route":[{"ipv4-prefix":"10.0.0.11/32","route-type":"srl_nokia-common:bgp","route-owner":"bgp_mgr","id":0,"origin-network-instance":"default","active":%s}]}}}]}]' "$1"
}
run() { FAKE_GNMIC_OUT="$TMP/out" bash "$ROOT/tests/gate/lib/checks.sh" route_active leaf01 default ipv4 '^bgp$' "$@" >"$TMP/log" 2>&1; }
printf '%s' "$empty" >"$TMP/out"; if run 10.0.0.11/32; then bad "empty route table passed"; else ok "empty route table fails"; fi
route true >"$TMP/out"; if run 10.0.0.11/32; then ok "active prefix passes"; else bad "active prefix failed: $(tail -3 "$TMP/log")"; fi
route false >"$TMP/out"; if run 10.0.0.11/32; then bad "inactive prefix passed"; else ok "inactive prefix fails"; fi
route true >"$TMP/out"; if run 10.0.0.11/32 10.0.0.12/32; then bad "missing second prefix passed"; else ok "missing second prefix fails"; fi
route true >"$TMP/out"; if run; then bad "no prefix passed"; else ok "no prefix fails"; fi
# subscribe_sample (Pass 36, live): gnmic prints "received signal 'terminated'. terminating..." on stdout when
# timeout stops it; left in the JSON stream, jq failed and the count read 0 on a device that WAS sampling;
# and one sample round over several neighbours was counted as "repeated". Now: that line is dropped from
# the parse, stderr is kept apart, and one leaf must repeat.
ev() { printf '[{"name":"d","timestamp":%s,"tags":{"neighbor_peer-address":"%s","subscription-name":"d"},"values":{"/p/session-state":"established"}}]\n' "$1" "$2"; }
srun() { FAKE_GNMIC_OUT="$TMP/out" FAKE_GNMIC_TAIL="received signal 'terminated'. terminating..." FAKE_GNMIC_ERR="stderr noise" \
  bash "$ROOT/tests/gate/lib/checks.sh" subscribe_sample leaf01 5 /p >"$TMP/log" 2>&1; }
{ ev 1 a; ev 1 b; ev 2 a; ev 2 b; } >"$TMP/out"; if srun; then ok "two sample rounds pass despite the signal line"; else bad "two sample rounds failed: $(tail -2 "$TMP/log")"; fi
{ ev 1 a; ev 1 b; ev 1 c; } >"$TMP/out"; if srun; then bad "one round over three neighbours passed as repeated"; else ok "one round is not repeated"; fi
: >"$TMP/out"; if srun; then bad "no update passed"; else ok "no update fails"; fi

# ---------------------------------------------------------------- T187 criteria (path-aware fake)
upd() { printf '[{"source":"x:57400","updates":[{"Path":"p","values":{"p":%s}}]}]' "$1" >"$TMP/$2"; }
chk() { FAKE_GNMIC_MAP="$TMP/map" bash "$ROOT/tests/gate/lib/checks.sh" "$@" >"$TMP/log" 2>&1; }
BGP='/network-instance\[name=default\]/protocols/bgp$'
both='{"afi-safi":[{"afi-safi-name":"srl_nokia-common:evpn","evpn":{"inter-as-vpn":true}}],"group":[{"group-name":"vt-scratch-overlay","route-reflector":{"client":true}}]}'
ops='{"afi-safi":[{"afi-safi-name":"srl_nokia-common:evpn","active-routes":0}],"group":[{"group-name":"vt-scratch-overlay"}]}'
upd "$both" bgp-both.json; upd "$ops" bgp-ops.json
upd '{"afi-safi":[{"afi-safi-name":"srl_nokia-common:evpn","evpn":{"inter-as-vpn":true}}],"group":[{"group-name":"vt-scratch-overlay","route-reflector":{"client":false}}]}' bgp-rrfalse.json
# AD-76: state carries only operational leaves; the config datastore carries both
printf 'STATE\t%s\t%s\nCONFIG\t%s\t%s\n' "$BGP" "$TMP/bgp-ops.json" "$BGP" "$TMP/bgp-both.json" >"$TMP/map"
if chk reflector spine01; then ok "reflector passes from the config datastore when state does not mirror the leaves (AD-76)"
else bad "reflector failed with both leaves in config: $(tail -3 "$TMP/log")"; fi
printf 'STATE\t%s\t%s\nCONFIG\t%s\t%s\n' "$BGP" "$TMP/bgp-both.json" "$BGP" "$TMP/bgp-ops.json" >"$TMP/map"
if chk reflector spine01; then bad "reflector passed from STATE alone (it must read config)"; else ok "reflector does not accept the state datastore"; fi
printf 'CONFIG\t%s\t%s\n' "$BGP" "$TMP/bgp-rrfalse.json" >"$TMP/map"
if chk reflector spine01; then bad "reflector passed with route-reflector client false"; else ok "reflector fails on route-reflector client false (the declared control, AD-77)"; fi

# AD-82 (2026-09-21-acl-binding-state): acl_applied judges the keyed binding in RUNNING and the
# TCAM (A1–A3); the keyed binding in state and the per-subinterface entry list are observations,
# because 25.7.1 mirrors neither; A4 is acl_matched (the entry's own counter rising with traffic)
F='vt-scratch-g9-in4'; IF='ethernet-1/1.3990'
upd '{"name":"vt-scratch-g9-in4","type":"ipv4"}' bind.json
upd '{"forwarding-complex":[{"name":"0","input-total":2,"output-total":0,"single-instance":0}]}' tcam.json
upd '{"forwarding-complex":[{"name":"0","input-total":0,"output-total":2,"single-instance":0}]}' tcam-out.json
upd '{"forwarding-complex":[{"name":"0","programming-complete":true}]}' prog.json
printf 'CONFIG\t%s\t%s\nSTATE\t%s\t%s\nSTATE\t%s\t%s\n' \
  'acl-filter\[name=vt-scratch-g9-in4\]\[type=ipv4\]$' "$TMP/bind.json" 'tcam-entries$' "$TMP/tcam.json" 'datapath-programming$' "$TMP/prog.json" >"$TMP/map"
if chk acl_applied leaf01 "$F" ipv4 "$IF" input 10,65535; then
  if grep -q "^OBSERVATION per-subinterface-entry $IF input $F/ipv4 10 absent$" "$TMP/log" \
     && grep -q "^OBSERVATION state-binding $IF input $F/ipv4 absent$" "$TMP/log"; then
    ok "acl_applied passes on the keyed binding in running + TCAM, recording the unmirrored state binding and entry list"
  else bad "acl_applied did not record the state observations: $(grep OBSERVATION "$TMP/log")"; fi
else bad "acl_applied failed with the running binding and TCAM present: $(tail -3 "$TMP/log")"; fi
# negative controls of A1–A3: no binding in running; TCAM on the wrong direction
printf 'STATE\t%s\t%s\nSTATE\t%s\t%s\n' 'tcam-entries$' "$TMP/tcam.json" 'datapath-programming$' "$TMP/prog.json" >"$TMP/map"
if chk acl_applied leaf01 "$F" ipv4 "$IF" input 10,65535; then bad "acl_applied passed with no binding in running"
else ok "acl_applied fails when the keyed binding is absent from running"; fi
printf 'CONFIG\t%s\t%s\nSTATE\t%s\t%s\nSTATE\t%s\t%s\n' \
  'acl-filter\[name=vt-scratch-g9-in4\]\[type=ipv4\]$' "$TMP/bind.json" 'tcam-entries$' "$TMP/tcam-out.json" 'datapath-programming$' "$TMP/prog.json" >"$TMP/map"
if chk acl_applied leaf01 "$F" ipv4 "$IF" input 10,65535; then bad "acl_applied passed with TCAM on output for an input binding"
else ok "acl_applied fails when the TCAM is on the other direction"; fi
# A4: acl_matched — the entry's own matched-packets above the baseline
CNT='/acl/acl-filter\[name=vt-scratch-g9-in4\]\[type=ipv4\]/entry\[sequence-id=10\]/statistics/matched-packets$'
upd '"7"' cnt7.json
printf 'STATE\t%s\t%s\n' "$CNT" "$TMP/cnt7.json" >"$TMP/map"
if chk acl_matched leaf01 "$F" ipv4 10 3; then ok "acl_matched passes when the entry's counter rose (3 → 7)"; else bad "acl_matched failed on a risen counter: $(tail -3 "$TMP/log")"; fi
if chk acl_matched leaf01 "$F" ipv4 10 7; then bad "acl_matched passed with no increase"; else ok "acl_matched fails when no traffic met the entry (7 → 7)"; fi
printf 'STATE\t%s\t%s\n' "$CNT" "$TMP/no-such-file" >"$TMP/map"
if chk acl_matched leaf01 "$F" ipv4 10 0; then bad "acl_matched passed with no counter (absent filter)"; else ok "acl_matched fails when the filter reports no counter"; fi
printf 'STATE\t%s\t%s\n' "$CNT" "$TMP/cnt7.json" >"$TMP/map"
if [[ "$(FAKE_GNMIC_MAP="$TMP/map" bash "$ROOT/tests/gate/lib/checks.sh" acl_counter leaf01 "$F" ipv4 10 2>/dev/null | tail -1)" == 7 ]]; then ok "acl_counter prints the entry's matched-packets"; else bad "acl_counter did not print 7"; fi

# AD-77: the bounded withdrawal wait
RIB='/network-instance\[name=default\]/bgp-rib$'
upd '{"afi-safi":[{"afi-safi-name":"srl_nokia-common:evpn","evpn":{"rib-in-out":{"rib-in-post":{"imet-route":[{"originating-router":"10.0.0.1","route-distinguisher":"10.0.0.1:1","neighbor":"10.0.0.11"}]}}}}]}' rib-held.json
upd '{"afi-safi":[{"afi-safi-name":"srl_nokia-common:evpn","evpn":{"rib-in-out":{"rib-in-post":{}}}}]}' rib-empty.json
printf 'STATE\t%s\t%s\n' "$RIB" "$TMP/rib-held.json" >"$TMP/map"
if chk evpn_route_withdrawn leaf02 3 10.0.0.1 10.0.0.11,10.0.0.12; then bad "withdrawn passed while the Type-3 is held"; else ok "evpn_route_withdrawn fails while the route is held through a spine"; fi
printf 'STATE\t%s\t%s\n' "$RIB" "$TMP/rib-empty.json" >"$TMP/map"
if chk evpn_route_withdrawn leaf02 3 10.0.0.1 10.0.0.11,10.0.0.12; then ok "evpn_route_withdrawn passes once the route is gone"; else bad "withdrawn failed on an empty RIB: $(tail -3 "$TMP/log")"; fi
printf 'STATE\t%s\t%s\n' "$RIB" "$TMP/no-such-file" >"$TMP/map"
if chk evpn_route_withdrawn leaf02 3 10.0.0.1 10.0.0.11,10.0.0.12; then bad "a failed read was taken for a withdrawal"; else ok "a failed read is never a withdrawal"; fi

# AD-78: the tenant 9349 commit is an observation
IRB='/interface[name=irb0]/subinterface[index=3990]'
upd '{"oper-state":"up","ip-mtu":9349}' irb.json; upd '9348' mtu-back.json; upd '9349' mtu-stuck.json
printf 'STATE\t%s\t%s\nCONFIG\t%s\t%s\n' 'subinterface\[index=3990\]$' "$TMP/irb.json" 'ip-mtu$' "$TMP/mtu-back.json" >"$TMP/map"
if chk mtu_commit_probe leaf01 "$IRB" 9349 9348 && grep -q '^OBSERVATION .*"accepted_at_commit":true.*"irb_oper_state":"up"' "$TMP/log"; then
  ok "mtu_commit_probe records an accepted 9349 with the IRB up, and passes once 9348 is back"
else bad "mtu_commit_probe (accepted): $(tail -3 "$TMP/log")"; fi
if FAKE_GNMIC_SET_RC=1 chk mtu_commit_probe leaf01 "$IRB" 9349 9348 && grep -q '^OBSERVATION .*"accepted_at_commit":false' "$TMP/log"; then
  ok "mtu_commit_probe records a rejected commit as an observation, not a failure"
else bad "mtu_commit_probe (rejected): $(tail -3 "$TMP/log")"; fi
printf 'STATE\t%s\t%s\nCONFIG\t%s\t%s\n' 'subinterface\[index=3990\]$' "$TMP/irb.json" 'ip-mtu$' "$TMP/mtu-stuck.json" >"$TMP/map"
if chk mtu_commit_probe leaf01 "$IRB" 9349 9348; then bad "mtu_commit_probe passed with 9349 left in place"; else ok "mtu_commit_probe fails when the tenant MTU is not written back"; fi

[[ $fails -eq 0 ]] || { echo "checks_args_test: $fails failure(s)"; exit 1; }
echo "checks_args_test: all passed"
