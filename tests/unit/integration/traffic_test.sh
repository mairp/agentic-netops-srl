#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok/bad never fail: `A && ok || bad` is this file's idiom
# traffic_test.sh — tests/integration/traffic.sh offline, with fake docker / nsenter / ping /
# gnmic / kubectl on PATH (T065; SC-005, CR-009, NFR-013). No lab, no cluster.
#
# Asserts: bad arguments print the usage and exit 2; probes are sent with DF set (`-M do`) at the
# requested ICMP payload; a counter read of an absent subinterface fails and a movement below the
# probe count fails; the whole suite passes over a faithful fake fabric with every check's negative
# control recorded failing BEFORE any pass (three consecutive clean runs); a negative control that
# passes (the stock node answering) refuses the suite (exit 3) before any pass is run; a payload one
# byte over the boundary getting through fails the suite, named; client-side scratch links are
# removed and the addresses the run added are deleted on exit.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
SUT="$ROOT/tests/integration/traffic.sh"
T="$(mktemp -d)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 15 | while IFS= read -r l; do printf '    | %s\n' "$l"; done; return 0; }

mkdir -p "$T/bin"
# docker: inspect -> a pid; network inspect -> every lab container attached; exec -> the client's ip
cat >"$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  inspect) echo 4242 ;;
  network)
    printf '[{"Containers":{'
    i=0; for n in spine01 spine02 leaf01 leaf02 client01 client02; do
      [[ $i -gt 0 ]] && printf ','; i=1; printf '"%s":{"Name":"clab-agentic-netops-fabric-%s"}' "$n" "$n"; done
    printf '}}]\n' ;;
  exec)
    c="${2#clab-agentic-netops-fabric-}"; shift 2
    a="$*"
    echo "$c $a" >>"$FAKE/calls"
    case "$*" in
      "ip -o link show") cat "$FAKE/links.$c" 2>/dev/null; echo "2: eth1@if9: <UP> mtu 9348" ;;
      "ip link show dev "*) grep -qx "${*##* }" "$FAKE/links.$c" 2>/dev/null ;;
      "ip link add link eth1 name "*) echo "$7" >>"$FAKE/links.$c" ;;
      "ip link del "*) sed -i "/^${4}\$/d" "$FAKE/links.$c"; awk -v d="$4" '$2 != d' "$FAKE/addrs.$c" >"$FAKE/tmp" 2>/dev/null; mv "$FAKE/tmp" "$FAKE/addrs.$c" ;;
      *"addr add "*) echo "${a#* addr add }" | awk '{print $1" "$3}' >>"$FAKE/addrs.$c" ;;
      *"addr del "*) a="$(echo "${a#* addr del }" | awk '{print $1" "$3}')"; grep -vxF "$a" "$FAKE/addrs.$c" >"$FAKE/tmp" || true; mv "$FAKE/tmp" "$FAKE/addrs.$c" ;;
      "ip addr show dev "*|"ip -6 addr show dev "*) awk -v d="${*##* }" '$2 == d {print "    inet " $1 " scope global"}' "$FAKE/addrs.$c" 2>/dev/null ;;
      *"route show "*) exit 0 ;;
      "ip -"?" neigh show "*)   # the anycast gateway resolves on the gateway service's subinterface only
        dst="$5"; dev="$7"
        case "$dst:$dev" in
          10.160.0.1:eth1.160|2001:db8:160::1:eth1.160) echo "$dst lladdr ${FAKE_GW_MAC:-00:00:5e:00:01:01} REACHABLE" ;;
        esac ;;
      *) exit 0 ;;
    esac ;;
esac
EOF
# nsenter -t <pid> -n <cmd…>: run the command (tc / ping) as if inside the namespace
cat >"$T/bin/nsenter" <<'EOF'
#!/usr/bin/env bash
shift 3; exec "$@"
EOF
# ip (host side, via nsenter): the management link of every node carries (leftovers::scan's
# data-path probe); nothing else in the suite calls host ip
cat >"$T/bin/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-o link show mgmt0"|"-o link show eth0") echo "9: $4@if10: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1514 state UP" ;;
  *) echo "fake ip: unexpected $*" >&2; exit 1 ;;
esac
EOF
cat >"$T/bin/tc" <<'EOF'
#!/usr/bin/env bash
echo "qdisc noqueue 0: dev eth1 root refcnt 2"
EOF
# ping -4|-6 -M do -c N -i x -W y -s <payload> <dst>: a faithful fabric — the service pairs answer up
# to the boundary payload; scratch VLANs, the other instance and over-boundary probes do not
cat >"$T/bin/ping" <<'EOF'
#!/usr/bin/env bash
echo "ping $*" >>"$FAKE/pings"
fam="${1#-}"; size="${11}"; dst="${12}"; cnt="${5}"
[[ "$2 $3" == "-M do" ]] || { echo "fake ping: DF not set" >&2; exit 2; }
lim=9320; [[ "$fam" == 6 ]] && lim=9300
[[ -n "${FAKE_OVER:-}" ]] && lim=$((lim + 1))
rx=0
case "$dst" in
  10.120.0.12|2001:db8:120::12|10.130.2.10|2001:db8:130:2::10) rx="$cnt" ;;
  10.160.0.1|2001:db8:160::1|10.160.0.12|2001:db8:160::12) [[ -z "${FAKE_NO_GW:-}" ]] && rx="$cnt" ;;
  10.110.0.1|10.199.0.1) [[ -n "${FAKE_GW_EVERYWHERE:-}" ]] && rx="$cnt" ;;
  10.140.2.10|2001:db8:140:2::10)   # unanswered while a host route steers it into lab-ipvrf-a
    grep -E "route (add|del) ${dst}/" "$FAKE/calls" | tail -1 | grep -q "route add" || rx="$cnt" ;;
esac
[[ "$size" -gt "$lim" ]] && { echo "ping: local error: message too long, mtu=9348"; rx=0; }
echo "$cnt packets transmitted, $rx packets received"
[[ "$rx" -gt 0 ]]
EOF
# gnmic: running datastore clean; oper-state up on the leaves for the three service instances;
# subinterface counters that move by 10 per read on the leaves; absent anywhere else
cat >"$T/bin/gnmic" <<'EOF'
#!/usr/bin/env bash
addr="$2"; path="${*: -1}"
upd() { printf '[{"source":"%s","updates":[{"Path":"%s","values":{"%s":%s}}]}]\n' "$addr" "$path" "x" "$1"; }
none() { printf '[{"source":"%s"}]\n' "$addr"; }
leaf=0; [[ "$addr" == 172.25.25.2[12]:* ]] && leaf=1
[[ -n "${FAKE_STOCK_UP:-}" && "$addr" == 172.25.25.11:* ]] && leaf=1
case "$path" in
  /) echo '[]' ;;
  "/network-instance[name="*"]/oper-state")
    case "$path" in *lab-macvrf*|*lab-ipvrf-a*|*lab-ipvrf-b*) [[ $leaf == 1 ]] && upd '"up"' || none ;; *) none ;; esac ;;
  "/interface[name=ethernet-1/1]/subinterface[index="*"]/statistics")
    case "$path" in *index=120*|*index=130*|*index=140*|*index=160*) ;; *) none; exit 0 ;; esac
    [[ $leaf == 1 ]] || { none; exit 0; }
    f="$FAKE/ctr.${addr%%:*}"; n=$(( $(cat "$f" 2>/dev/null || echo 100) + 10 )); echo "$n" >"$f"
    upd "{\"in-packets\":\"$n\",\"out-packets\":\"$n\"}" ;;
  *) none ;;
esac
EOF
# kubectl: the three Networks Ready=True; no gate-labelled Config / namespace / allocation
cat >"$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"get networks.fabric.agentic-netops.io"*) printf 'True' ;;
  *"get namespace kube-system"*) printf 'uid-1' ;;
  *" -o json"*) echo '{"items":[]}' ;;
esac
EOF
chmod +x "$T/bin/"*

reset() { rm -rf "$T/fake" "$T/ev"; mkdir -p "$T/fake"; : >"$T/fake/calls"; : >"$T/fake/pings"; }
run() {
  set +e
  out="$(env -u EVIDENCE_DIR PATH="$T/bin:$PATH" FAKE="$T/fake" EVIDENCE_ROOT="$T/ev" EVIDENCE_CLUSTER=agentic-netops \
    EVIDENCE_CLUSTER_UID=uid-1 EVIDENCE_LAB=agentic-netops-fabric EVIDENCE_DEVICE_IMAGE_DIGEST="sha256:$(printf '0%.0s' {1..64})" \
    EVIDENCE_TOPOLOGY=/nonexistent SRL_PASS=x LAB_TCP_ACCEPT=true TR_WAIT=0 TR_NEG_WAIT=0 TR_COUNT=3 TR_COUNTER_WAIT="${TR_COUNTER_WAIT:-0}" TR_COUNTER_INTERVAL=0 "$@" 2>&1)"
  rc=$?
  set -e
  EV="$(find "$T/ev" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | head -1 || true)"
}

# --- usage
reset; run bash "$SUT" bogus
[[ $rc -eq 2 && "$out" == *"Usage: traffic.sh"* ]] && ok "bad subcommand: usage, exit 2" || bad "bad subcommand: usage, exit 2" "$out"
reset; run bash "$SUT" _reach client01 4
[[ $rc -eq 2 ]] && ok "bad check arity: exit 2" || bad "bad check arity: exit 2" "$out"

# --- the pure checks
reset; run bash "$SUT" _reach client01 4 10.120.0.12 9320
[[ $rc -eq 0 ]] && grep -q -- "-4 -M do -c 3 .* -s 9320 10.120.0.12" "$T/fake/pings" \
  && ok "_reach: DF set at the requested payload, passes when every probe is answered" || bad "_reach at 9320" "$out"
reset; run bash "$SUT" _reach client01 4 10.120.0.12 9321
[[ $rc -ne 0 ]] && ok "_reach: payload 9321 with DF fails" || bad "_reach at 9321 must fail" "$out"
reset; run bash "$SUT" _unreach client01 6 2001:db8:130:2::10 9301
[[ $rc -eq 0 ]] && ok "_unreach: IPv6 payload 9301 with DF is not answered" || bad "_unreach IPv6 9301" "$out"
reset; run bash "$SUT" _counters spine01 ethernet-1/1 120
[[ $rc -ne 0 ]] && ok "_counters: a stock node's absent subinterface fails" || bad "_counters on a stock node must fail" "$out"
reset; run bash "$SUT" _counters leaf01 ethernet-1/1 120
[[ $rc -eq 0 && "$out" == "110 110" ]] && ok "_counters: in/out packets read as numbers" || bad "_counters on leaf01" "$out"
reset; run bash "$SUT" _moved leaf01 leaf02 ethernet-1/1 120 105 105 3
[[ $rc -eq 0 ]] && ok "_moved: movement >= probes on both leaves passes" || bad "_moved 105->110 min 3" "$out"
reset; run bash "$SUT" _moved leaf01 leaf02 ethernet-1/1 120 105 109 3
[[ $rc -ne 0 ]] && ok "_moved: movement below the probe count fails (movement, never a rate)" || bad "_moved 109->110 min 3 must fail" "$out"
# a lagging counter (the fake moves 10 per read): the bounded re-read admits it once it has moved,
# and the same read with no wait still fails
reset; TR_COUNTER_WAIT=5 run bash "$SUT" _moved leaf01 leaf02 ethernet-1/1 120 105 119 3
[[ $rc -eq 0 ]] && grep -q "before 119 now 130 moved 11" <<<"$out" \
  && ok "_moved: a lagging counter is re-read within TR_COUNTER_WAIT until it has moved" || bad "_moved lagging counter" "$out"
reset; run bash "$SUT" _moved leaf01 leaf02 ethernet-1/1 120 105 119 3
[[ $rc -ne 0 ]] && ok "_moved: with no wait the lagging counter fails (the bound is the only allowance)" || bad "_moved lagging, no wait" "$out"

# --- the suite over a faithful fake fabric
reset; run env RUNS=1 bash "$SUT" run
if [[ $rc -eq 0 && "$out" == *"1 consecutive clean runs"* ]]; then ok "suite: a clean run (RUNS=1 offline; the lab default is 3)"; else bad "suite: clean run (rc=$rc)" "$out"; fi
nc_ok=1
for c in TR-instance TR-reach TR-mtu TR-isolated TR-mtu-over TR-counters; do
  n="$(jq -s --arg c "$c" '[.[] | select(.check_id == $c and .kind == "negative_control" and .negative_control_failed == true)] | length' "$EV"/*.json 2>/dev/null || echo 0)"
  [[ "$n" -ge 1 ]] || { nc_ok=0; echo "    | no failing negative control for $c"; }
done
[[ $nc_ok == 1 ]] && ok "suite: every check has a failing negative control recorded" || bad "suite: negative controls"
first_pass="$(jq -rs '[.[] | select(.kind == "run" and (.id | startswith("TR.")))] | min_by(.utc_time) | .utc_time' "$EV"/*.json 2>/dev/null)"
last_nc="$(jq -rs '[.[] | select(.kind == "negative_control")] | max_by(.utc_time) | .utc_time' "$EV"/*.json 2>/dev/null)"
[[ -n "$first_pass" && "$last_nc" < "$first_pass" || "$last_nc" == "$first_pass" ]] \
  && ok "suite: negative controls precede the first pass" || bad "suite: order ($last_nc vs $first_pass)"
runs="$(find "$EV" -maxdepth 1 -name 'TR.*.json' -printf '%f\n' | grep -oE '^TR\.[0-9]+\.' | sort -u | wc -l)"
[[ "$runs" -eq 1 ]] && ok "suite: exactly RUNS runs recorded" || bad "suite: $runs runs recorded"
grep -q -- "-s 9320 10.130.2.10" "$T/fake/pings" && grep -q -- "-6 .*-s 9300 2001:db8:130:2::10" "$T/fake/pings" \
  && grep -q -- "-s 9321 10.120.0.12" "$T/fake/pings" && grep -q -- "-6 .*-s 9301 2001:db8:120::12" "$T/fake/pings" \
  && ok "suite: the MTU boundary is probed at 9320/9300 and one byte more" || bad "suite: boundary probes"
grep -q "route add 10.140.2.10/32 via 10.130.1.1" "$T/fake/calls" && ok "suite: isolation steered into lab-ipvrf-a's gateway" || bad "suite: isolation route"
[[ ! -s "$T/fake/links.client01" && ! -s "$T/fake/links.client02" ]] && grep -q "ip link del vt-scratch-199" "$T/fake/calls" \
  && ok "suite: vt-scratch- links removed (read back)" || bad "suite: scratch links left" "$(cat "$T"/fake/links.* 2>/dev/null)"
[[ ! -s "$T/fake/addrs.client01" && ! -s "$T/fake/addrs.client02" ]] && ok "suite: addresses the run added are deleted on exit" \
  || bad "suite: addresses left" "$(cat "$T"/fake/addrs.* 2>/dev/null)"
grep -q "client01 sh /setup.sh 130" "$T/fake/calls" && ok "suite: subinterfaces brought up by the endpoint's own setup.sh" || bad "suite: setup.sh"

# --- a negative control that passes refuses the suite before any pass
reset; run env FAKE_STOCK_UP=1 RUNS=1 bash "$SUT" run
if [[ $rc -eq 3 ]] && [[ -z "$(find "$EV" -maxdepth 1 -name 'TR.1.*' 2>/dev/null)" ]]; then ok "stock node answering: refused (exit 3), no pass run"; else bad "stock node answering must refuse (rc=$rc)" "$out"; fi

# --- one byte over the boundary getting through: the over-boundary check fails
reset; run env FAKE_OVER=1 bash "$SUT" _unreach client01 4 10.130.2.10 9321
[[ $rc -ne 0 ]] && ok "over-boundary payload answered: the TR-mtu-over check fails" || bad "over-boundary must fail (rc=$rc)" "$out"
# --- the anycast-gateway case (T118, US8 scenario 1): its own mode over lab-macvrf-gateway
reset; run bash "$SUT" _gwmac client01 160 10.160.0.1 00:00:5e:00:01:01
[[ $rc -eq 0 && "$out" == *"lladdr: 00:00:5e:00:01:01"* ]] && ok "_gwmac: the gateway resolves to the anycast MAC" || bad "_gwmac anycast MAC" "$out"
reset; run env FAKE_GW_MAC=aa:bb:cc:00:00:01 bash "$SUT" _gwmac client01 160 10.160.0.1 00:00:5e:00:01:01
[[ $rc -ne 0 ]] && ok "_gwmac: a gateway answering with another MAC fails" || bad "_gwmac other MAC must fail" "$out"
reset; run bash "$SUT" _gwmac client01 199 10.199.0.1 00:00:5e:00:01:01
[[ $rc -ne 0 ]] && ok "_gwmac: no neighbour entry fails" || bad "_gwmac no entry must fail" "$out"
reset; run env RUNS=1 bash "$SUT" gateway
if [[ $rc -eq 0 && "$out" == *"traffic suite (gateway) passed: 1 consecutive clean runs"* ]]; then ok "gateway: a clean run"; else bad "gateway: clean run (rc=$rc)" "$out"; fi
nc_ok=1
for c in TR-instance TR-gw-reach TR-gw-mac; do
  n="$(jq -s --arg c "$c" '[.[] | select(.check_id == $c and .kind == "negative_control" and .negative_control_failed == true)] | length' "$EV"/*.json 2>/dev/null || echo 0)"
  [[ "$n" -ge 1 ]] || { nc_ok=0; echo "    | no failing negative control for $c"; }
done
[[ $nc_ok == 1 ]] && ok "gateway: every check has a failing negative control recorded" || bad "gateway: negative controls"
for c in client01 client02; do
  for gw in "-4 .*10.160.0.1$" "-6 .*2001:db8:160::1$"; do
    grep -qE -- "$gw" "$T/fake/pings" || { bad "gateway: $c probe $gw missing"; continue 2; }
  done
done
grep -q "client02 sh /setup.sh 160" "$T/fake/calls" && ok "gateway: probed in both families from both attached ports" || bad "gateway: setup.sh 160 on client02"
[[ -z "$(find "$EV" -maxdepth 1 -name 'TR.1.TR-gw-*' 2>/dev/null | head -1)" ]] && bad "gateway: no TR-gw pass recorded" || ok "gateway: TR-gw-reach / TR-gw-mac passes recorded"
reset; run env FAKE_NO_GW=1 RUNS=1 bash "$SUT" gateway
[[ $rc -eq 1 && "$out" == *"anycast gateway 10.160.0.1 answers"* ]] && ok "gateway: an unanswered gateway fails the suite, named" || bad "gateway: unanswered gateway must fail (rc=$rc)" "$out"
reset; run env FAKE_GW_EVERYWHERE=1 RUNS=1 bash "$SUT" gateway
if [[ $rc -eq 3 ]] && [[ -z "$(find "$EV" -maxdepth 1 -name 'TR.1.*' 2>/dev/null)" ]]; then ok "gateway: a gateway answering where no service has one refuses (exit 3), no pass run"; else bad "gateway: answering negative control must refuse (rc=$rc)" "$out"; fi

# shellcheck disable=SC2016 # the literal default assignment is what is searched for
grep -q "RUNS (3)" "$SUT" && grep -qF ': "${RUNS:=3}"' "$SUT" && ok "the suite's default is three consecutive runs" || bad "RUNS default"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
