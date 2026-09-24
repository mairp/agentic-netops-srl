#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016 # ok/bad never fail (`A && ok || bad`); bash -c bodies are single-quoted on purpose
# acl_suites_test.sh — the US5 access-list live suites offline (T114): tests/integration/
# {acl_verify,acl_enforcement_probe,acl_conflict}.sh and tests/integration/lib/acl.sh, with fake
# gnmic / kubectl on PATH. No lab, no cluster.
#
# Asserts:
#   - every suite is executable, bash -n clean, and refuses bad arguments with its usage (exit 2)
#     before touching anything
#   - acl::plan derives, from the examples, the filter acl-<serviceId>-<stage>, the entry
#     sequence-ids (declared priorities ascending, +65535 exactly with a defaultAction), the binding
#     interface-id <port>.<vlan> per attachment and the direction
#   - the written-side judgement passes the render goldens and fails, named, on: an entry out of
#     ascending order, a changed action, a changed match field, a missing 65535, a missing filter,
#     an egress filter without subinterface-specific output-only
#   - the device checks judge a faithful fake: binding with interface-ref; statistics readable vs
#     incomplete; the counter delta (moved by >= min, unmoved); removal read-back (NotFound and an
#     empty read are absent, an erroring read is not)
#   - acl_verify.sh over a faithful fake fabric passes with every keyed check's negative control
#     recorded failing BEFORE its first readiness run; a stock node that carries the filter (a
#     defective control) refuses the run (exit 3) with no readiness run recorded; a changed entry
#     action on one leaf fails the run, named
#   - the enforcement probe's scratch Networks: platform-named (no vt-scratch-), on a VLAN no example
#     uses, deny/permit/never-hit entries 10/20/30 + 65535; the egress list output-only
#   - the conflict candidate takes exactly the holder's key; its other-family twin differs only in type
#   - in every suite each check's negative control is issued on an earlier line than its readiness run
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
IT="$ROOT/tests/integration"
LIB="$IT/lib/acl.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 12 | sed 's/^/    | /'; fails=$((fails + 1)); return 0; }
expect() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
refuse() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi; }
y2j() { python3 -c 'import json,sys,yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$1"; }

# ---------------------------------------------------------------- structure, usage

for s in acl_verify acl_enforcement_probe acl_conflict; do
  f="$IT/$s.sh"
  [[ -x "$f" ]] && bash -n "$f" && ok "$s: executable, bash -n clean" || bad "$s: not executable or bash -n fails"
done
bash -n "$LIB" && ok "lib/acl.sh: bash -n clean" || bad "lib/acl.sh: bash -n fails"
for args in "--bogus" "not-a-ref" "Upper/Case"; do
  rc=0; out="$(bash "$IT/acl_verify.sh" "$args" 2>&1)" || rc=$?
  [[ "$rc" == 2 && "$out" == *Usage:* ]] && ok "acl_verify: usage on '$args'" || bad "acl_verify: '$args' rc=$rc" "$out"
done
rc=0; out="$(bash "$IT/acl_enforcement_probe.sh" bogus 2>&1)" || rc=$?
[[ "$rc" == 2 && "$out" == *Usage:* ]] && ok "acl_enforcement_probe: usage on bad args" || bad "acl_enforcement_probe: rc=$rc" "$out"
rc=0; out="$(bash "$IT/acl_conflict.sh" a/b c/d 2>&1)" || rc=$?
[[ "$rc" == 2 && "$out" == *Usage:* ]] && ok "acl_conflict: usage on two holders" || bad "acl_conflict: rc=$rc" "$out"
rc=0; bash "$LIB" bogus >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] && ok "lib/acl.sh: unknown check rc 2" || bad "lib/acl.sh: unknown check rc=$rc"

# ---------------------------------------------------------------- plan and written judgement (pure)

MV="$(y2j "$ROOT/examples/constructs/macvrf-with-acl.yaml")"
SA="$(y2j "$ROOT/examples/constructs/acl-standalone.yaml")"
plan_mv="$(bash -c 'source "$1"; acl::plan "$2"' _ "$LIB" "$MV")"
got="$(cut -f1-7 <<<"$plan_mv" | tr '\t' ' ' | tr '\n' ';')"
want="leaf01 acl-lab-macvrf-acl-ingress ipv4 ingress input ethernet-1/1.150 100,200,300,65535;leaf02 acl-lab-macvrf-acl-ingress ipv4 ingress input ethernet-1/1.150 100,200,300,65535;"
[[ "$got" == "$want" ]] && ok "plan: lab-macvrf-acl (filter, seqs, binding per attachment)" || bad "plan lab-macvrf-acl" "$got"
plan_sa="$(bash -c 'source "$1"; acl::plan "$2"' _ "$LIB" "$SA")"
got="$(cut -f1-7 <<<"$plan_sa" | tr '\t' ' ')"
[[ "$got" == "leaf01 acl-lab-acl-ingress ipv6 ingress input ethernet-1/1.110 10,20,65535" ]] && ok "plan: lab-acl (standalone ipv6)" || bad "plan lab-acl" "$got"
nodef="$(jq -c 'del(.spec.accessLists[0].defaultAction) | .metadata.name = "migr-svc42"' <<<"$MV")"
got="$(bash -c 'source "$1"; acl::plan "$2"' _ "$LIB" "$nodef" | head -1 | cut -f2,7 | tr '\t' ' ')"
[[ "$got" == "acl-svc42-ingress 100,200,300" ]] && ok "plan: no defaultAction → no 65535; migr- prefix dropped from the service id" || bad "plan nodef" "$got"

EXP_MV="$(head -1 <<<"$plan_mv" | cut -f8)"
G_MV="$(jq -c '.["srl_nokia-acl:acl"]["acl-filter"][0]' "$ROOT/tests/golden/services/acl_example_macvrf-leaf01.json")"
G_SA="$(jq -c '.["srl_nokia-acl:acl"]["acl-filter"][0]' "$ROOT/tests/golden/services/acl_example_standalone-leaf01.json")"
judge() { bash -c 'source "$1"; acl::judge_written "$2" "$3"' _ "$LIB" "$1" "$2"; }
expect "written: macvrf golden = declared"            judge "$G_MV" "$EXP_MV"
expect "written: standalone golden = declared"        judge "$G_SA" "$(cut -f8 <<<"$plan_sa")"
expect "written: wrapped + module-prefixed identities" judge "$(jq -c '{"srl_nokia-acl:acl-filter": [.]} | .["srl_nokia-acl:acl-filter"][0].entry[0].match.ipv4.protocol = "srl_nokia-packet-match-types:tcp"' <<<"$G_MV")" "$EXP_MV"
expect "written: uint64 as strings"                   judge "$(jq -c '.entry[0]["sequence-id"] = "100" | .entry[0].match.transport["destination-port"].value = "23"' <<<"$G_MV")" "$EXP_MV"
refuse "written: entries out of ascending order"      judge "$(jq -c '.entry |= reverse' <<<"$G_MV")" "$EXP_MV"
refuse "written: an action changed"                   judge "$(jq -c '.entry[2].action = {"drop": {}}' <<<"$G_MV")" "$EXP_MV"
refuse "written: a match field changed"               judge "$(jq -c '.entry[1].match.ipv4["source-ip"].prefix = "10.151.0.0/24"' <<<"$G_MV")" "$EXP_MV"
refuse "written: a match field missing"               judge "$(jq -c 'del(.entry[0].match.transport)' <<<"$G_MV")" "$EXP_MV"
refuse "written: 65535 missing"                       judge "$(jq -c 'del(.entry[3])' <<<"$G_MV")" "$EXP_MV"
refuse "written: an extra entry"                      judge "$(jq -c '.entry += [{"sequence-id": 400, "action": {"accept": {}}}]' <<<"$G_MV")" "$EXP_MV"
refuse "written: filter absent"                       judge null "$EXP_MV"
refuse "written: statistics-per-entry off"            judge "$(jq -c '.["statistics-per-entry"] = false' <<<"$G_MV")" "$EXP_MV"
EG_EXP="$(jq -c '.stage = "egress" | .subinterfaceSpecific = "output-only"' <<<"$EXP_MV")"
refuse "written: egress without output-only"          judge "$G_MV" "$EG_EXP"
expect "written: egress with output-only"             judge "$(jq -c '.["subinterface-specific"] = "output-only"' <<<"$G_MV")" "$EG_EXP"

# ---------------------------------------------------------------- a faithful fake fabric

FAKE="$T/fake"; BIN="$T/bin"; mkdir -p "$FAKE/net" "$BIN"
export FAKE PATH="$BIN:$PATH" CHECK_WAIT=0 CHECK_INTERVAL=0
export EVIDENCE_ROOT="$T/evroot" EVIDENCE_DEVICE_IMAGE_DIGEST=sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402
export EVIDENCE_CLUSTER_UID=offline SRL_PASS=offline-secret CLUSTER_NAME=agentic-netops LAB_TCP_ACCEPT=true
# gnmic: answers from $FAKE/table ("<node>|<TYPE>|<path>\t<json>"); an unknown path reads empty, or
# NotFound with FAKE_NOTFOUND=1, or an error with FAKE_ERROR=1
cat >"$BIN/gnmic" <<'EOF'
#!/usr/bin/env bash
addr="" type="" path=""
while [[ $# -gt 0 ]]; do case "$1" in
  -a) addr="${2%%:*}"; shift 2 ;; --type) type="${2^^}"; shift 2 ;; --path) path="$2"; shift 2 ;; *) shift ;; esac; done
case "$addr" in *.11) node=spine01 ;; *.12) node=spine02 ;; *.21) node=leaf01 ;; *.22) node=leaf02 ;; *) node=unknown ;; esac
echo "$node $type $path" >>"$FAKE/gnmic.calls"
[[ -n "${FAKE_ERROR:-}" ]] && { echo "rpc error: code = Unavailable desc = connection refused" >&2; exit 1; }
v="$(awk -F'\t' -v k="$node|$type|$path" '$1 == k {print $2; exit}' "$FAKE/table")"
if [[ -z "$v" ]]; then
  [[ -n "${FAKE_NOTFOUND:-}" ]] && { echo "rpc error: code = NotFound desc = path not found" >&2; exit 1; }
  echo '[]'; exit 0
fi
printf '[{"source":"%s","updates":[{"Path":"p","values":{"p":%s}}]}]\n' "$addr" "$v"
EOF
# kubectl: `get networks… <name> -o json` serves $FAKE/net/<name>.json, NotFound otherwise
cat >"$BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/kubectl.calls"
args=" $* "
if [[ "$args" == *" get networks.fabric.agentic-netops.io "* ]]; then
  for a in "$@"; do [[ -f "$FAKE/net/$a.json" ]] && { cat "$FAKE/net/$a.json"; exit 0; }; done
  echo 'Error from server (NotFound): networks.fabric.agentic-netops.io "x" not found' >&2; exit 1
fi
if [[ "$args" == *" get namespace kube-system "* ]]; then echo offline; exit 0; fi
echo "fake kubectl: unexpected $*" >&2; exit 1
EOF
chmod +x "$BIN/gnmic" "$BIN/kubectl"

F=acl-lab-macvrf-acl-ingress
IFJ="$(jq -c '.["srl_nokia-acl:acl"].interface[0]' "$ROOT/tests/golden/services/acl_example_macvrf-leaf01.json")"
table() { # the faithful fabric: both leaves hold the filter, bound input on ethernet-1/1.150
  local n s
  : >"$FAKE/table"
  for n in leaf01 leaf02; do
    printf '%s|CONFIG|/acl/acl-filter[name=%s][type=ipv4]\t%s\n' "$n" "$F" "$G_MV"
    printf '%s|CONFIG|/acl/interface[interface-id=ethernet-1/1.150]\t%s\n' "$n" "$IFJ"
    printf '%s|CONFIG|/acl/interface[interface-id=ethernet-1/1.150]/input/acl-filter[name=%s][type=ipv4]\t{"name":"%s","type":"ipv4"}\n' "$n" "$F" "$F"
    printf '%s|STATE|/acl/datapath-programming\t{"forwarding-complex":[{"slot-id":1,"complex-id":0,"programming-complete":true}]}\n' "$n"
    for s in 100 200 300 65535; do
      printf '%s|STATE|/acl/acl-filter[name=%s][type=ipv4]/entry[sequence-id=%s]/tcam-entries\t{"forwarding-complex":[{"complex-identifier":"1/0","input-total":2,"output-total":0,"single-instance":1}]}\n' "$n" "$F" "$s"
      printf '%s|STATE|/acl/acl-filter[name=%s][type=ipv4]/entry[sequence-id=%s]/statistics\t{"matched-packets":"8","incomplete":false}\n' "$n" "$F" "$s"
      printf '%s|STATE|/acl/acl-filter[name=%s][type=ipv4]/entry[sequence-id=%s]/statistics/matched-packets\t"8"\n' "$n" "$F" "$s"
    done
  done >>"$FAKE/table"
}
table
jq -c '. + {status: {conditions: [{type: "Ready", status: "True", reason: "Converged", message: "all checks pass"}]}}' <<<"$MV" >"$FAKE/net/lab-macvrf-acl.json"

expect "binding: interface-ref + input key in running"    bash "$LIB" binding leaf01 ethernet-1/1.150 input "$F" ipv4
refuse "binding: wrong direction"                          bash "$LIB" binding leaf01 ethernet-1/1.150 output "$F" ipv4
refuse "binding: stock spine01"                            bash "$LIB" binding spine01 ethernet-1/1.150 input "$F" ipv4
expect "written: runner PASS on the fake leaf"             bash "$LIB" written leaf01 "$F" ipv4 "$EXP_MV"
refuse "written: runner on the stock node"                 bash "$LIB" written spine01 "$F" ipv4 "$EXP_MV"
refuse "written: runner for a filter that does not exist" bash "$LIB" written leaf01 acl-does-not-exist-ingress ipv4 "$EXP_MV"
expect "stats: readable, not incomplete"                   bash "$LIB" stats leaf01 "$F" ipv4 100,200,300,65535
refuse "stats: stock node"                                 bash "$LIB" stats spine01 "$F" ipv4 100
expect "programmed: G1 complete"                           bash "$LIB" programmed leaf01
refuse "programmed: none listed"                           bash "$LIB" programmed spine01
expect "delta: moved >= min and unmoved"                   bash "$LIB" delta leaf01 "$F" ipv4 100:5:3 200:8:0
refuse "delta: moved less than min"                        bash "$LIB" delta leaf01 "$F" ipv4 100:6:3
refuse "delta: an entry that must not move moved"          bash "$LIB" delta leaf01 "$F" ipv4 100:7:0
refuse "delta: a filter that does not exist"               bash "$LIB" delta leaf01 acl-does-not-exist-ingress ipv4 10:0:1
refuse "delta: an unreadable baseline"                     bash "$LIB" delta leaf01 "$F" ipv4 100:null:1
got="$(bash "$LIB" counters leaf01 "$F" ipv4 100,999 2>/dev/null | tr '\n' ';')"
[[ "$got" == "100 8;999 null;" ]] && ok "counters: keyed read per entry, null when absent" || bad "counters" "$got"
refuse "gone: the filter is present"                       bash "$LIB" gone leaf01 "$F" ipv4 ethernet-1/1.150 input
expect "gone: empty read on the stock node"                bash "$LIB" gone spine01 "$F" ipv4 ethernet-1/1.150 input
expect "gone: NotFound is absent"                          env FAKE_NOTFOUND=1 bash "$LIB" gone spine01 "$F" ipv4
refuse "gone: an erroring read is never absent"            env FAKE_ERROR=1 bash "$LIB" gone spine01 "$F" ipv4
sed -i "s/^leaf02|STATE|\/acl\/acl-filter\[name=$F\]\[type=ipv4\]\/entry\[sequence-id=100\]\/statistics\t.*/leaf02|STATE|\/acl\/acl-filter[name=$F][type=ipv4]\/entry[sequence-id=100]\/statistics\t{\"matched-packets\":\"8\",\"incomplete\":true}/" "$FAKE/table"
refuse "stats: incomplete true"                            bash "$LIB" stats leaf02 "$F" ipv4 100
table

# acl_verify.sh end to end over the fake
run_av() { EVIDENCE_DIR="$T/ev.$1" AV_WAIT=0 AV_NEG_WAIT=0 bash "$IT/acl_verify.sh" agentic-netops-services/lab-macvrf-acl >"$T/av.$1.out" 2>&1; }
rc=0; run_av pass || rc=$?
[[ "$rc" == 0 ]] && ok "acl_verify: passes over a faithful fabric" || bad "acl_verify pass rc=$rc" "$(cat "$T/av.pass.out")"
ctl_before() { # <dir> <check>: every failing control of <check> precedes its first readiness run
  local dir="$1" c="$2" first_ctl first_run
  first_ctl="$(jq -r --arg c "$c" 'select(.kind == "negative_control" and .check_id == $c and .exit_status != 0) | .utc_time' "$dir"/*.json 2>/dev/null | sort | head -1)"
  first_run="$(jq -r --arg c "$c" 'select(.kind == "run" and .check_id == $c and .readiness) | .utc_time' "$dir"/*.json 2>/dev/null | sort | head -1)"
  [[ -n "$first_ctl" && -n "$first_run" && ! "$first_run" < "$first_ctl" ]] \
    && [[ "$(jq -r --arg c "$c" 'select(.kind == "negative_control" and .check_id == $c) | .id' "$dir"/*.json | grep -c .)" -ge 1 ]]
}
for c in AV-written AV-binding AV-applied AV-stats AV-ready; do
  ctl_before "$T/ev.pass" "$c" && ok "acl_verify: $c control recorded failing before its readiness runs" || bad "acl_verify: $c control order"
done
n="$(jq -r 'select(.kind == "negative_control") | .check_id' "$T/ev.pass"/*.json | grep -c .)"
[[ "$n" == 9 ]] && ok "acl_verify: 9 negative controls (stock node + absent filter per keyed check, absent Network)" || bad "acl_verify: $n controls"
grep -q "spine01 CONFIG /acl/acl-filter\[name=$F\]\[type=ipv4\]" "$FAKE/gnmic.calls" && ok "acl_verify: the stock-node control read the real filter key" || bad "acl_verify: no stock read"
grep -q "leaf01 CONFIG /acl/acl-filter\[name=acl-does-not-exist-ingress\]\[type=ipv4\]" "$FAKE/gnmic.calls" && ok "acl_verify: the absent-filter control read a keyed path" || bad "acl_verify: no absent-filter read"
# a defective control: the stock node carries the filter
printf 'spine01|CONFIG|/acl/acl-filter[name=%s][type=ipv4]\t%s\n' "$F" "$G_MV" >>"$FAKE/table"
rc=0; run_av defective || rc=$?
runs="$(jq -r 'select(.kind == "run" and .readiness) | .id' "$T/ev.defective"/*.json 2>/dev/null | grep -c . || true)"
[[ "$rc" == 3 && "$runs" == 0 ]] && ok "acl_verify: a control that passes refuses the run, no readiness run recorded" || bad "acl_verify defective rc=$rc runs=$runs" "$(cat "$T/av.defective.out")"
table
# a changed action on leaf02
sed -i "s/^\(leaf02|CONFIG|\/acl\/acl-filter\[name=$F\]\[type=ipv4\]\t\).*/\1$(jq -c '.entry[2].action = {"drop": {}}' <<<"$G_MV" | sed 's/[&/\]/\\&/g')/" "$FAKE/table"
rc=0; run_av changed || rc=$?
[[ "$rc" == 1 ]] && grep -q "FAIL .*leaf02 acl-lab-macvrf-acl-ingress/ipv4: entries" "$T/av.changed.out" \
  && ok "acl_verify: a changed action on leaf02 fails the run, named" || bad "acl_verify changed rc=$rc" "$(cat "$T/av.changed.out")"
table

# ---------------------------------------------------------------- the probe's and the conflict's objects

PM="$(bash -c 'source "$1"; ap::manifest_svc with-ingress' _ "$IT/acl_enforcement_probe.sh")"
PE="$(bash -c 'source "$1"; ap::manifest_egress' _ "$IT/acl_enforcement_probe.sh")"
printf '%s\n' "$PM" >"$T/svc.yaml"; printf '%s\n' "$PE" >"$T/egr.yaml"
p_svc="$(bash -c 'source "$1"; acl::plan "$2"' _ "$LIB" "$(y2j "$T/svc.yaml")" | cut -f1-7 | tr '\t' ' ' | tr '\n' ';')"
[[ "$p_svc" == "leaf01 acl-acl-probe-svc-ingress ipv4 ingress input ethernet-1/1.360 10,20,30,65535;leaf02 acl-acl-probe-svc-ingress ipv4 ingress input ethernet-1/1.360 10,20,30,65535;" ]] \
  && ok "probe: acl-probe-svc ingress list on both leaves, entries 10,20,30,65535" || bad "probe svc plan" "$p_svc"
p_egr="$(bash -c 'source "$1"; acl::plan "$2"' _ "$LIB" "$(y2j "$T/egr.yaml")")"
[[ "$(cut -f1-7 <<<"$p_egr" | tr '\t' ' ')" == "leaf02 acl-acl-probe-egress-egress ipv4 egress output ethernet-1/1.360 10,20,30,65535" ]] \
  && jq -e '.subinterfaceSpecific == "output-only" and .entries[0].action == "drop" and .entries[1].action == "accept" and .entries[0].match.dst == "10.36.0.23/32"' <<<"$(cut -f8 <<<"$p_egr")" >/dev/null \
  && ok "probe: acl-probe-egress standalone egress list on leaf02, output-only, deny .23 / permit .24" || bad "probe egress plan" "$p_egr"
jq -e '(.spec | has("accessLists") and has("attachments") and (has("bridgeDomains") or has("vlans") or has("routers") | not))' <<<"$(y2j "$T/egr.yaml")" >/dev/null \
  && ok "probe: the egress Network is the standalone acl shape" || bad "probe: egress Network shape"
! grep -q 'vt-scratch-' "$T/svc.yaml" "$T/egr.yaml" && ok "probe: platform-named objects (no vt-scratch- prefix)" || bad "probe: vt-scratch- in a Network"
! grep -rqE 'vlan: 360\b|10\.36\.0\.' "$ROOT/examples/constructs" "$ROOT/agents/tests/e2e" "$IT/traffic.sh" && ok "probe: VLAN 360 / 10.36.0.0/24 used by no example, e2e or traffic suite" || bad "probe: VLAN 360 collides"
got="$(bash -c 'source "$1"; ac::manifest agentic-netops-services ingress ipv6 leaf01 ethernet-1/1 110' _ "$IT/acl_conflict.sh" >"$T/c.yaml"; bash -c 'source "$1"; acl::plan "$2"' _ "$LIB" "$(y2j "$T/c.yaml")" | cut -f1-6 | tr '\t' ' ')"
[[ "$got" == "leaf01 acl-acl-conflict-probe-ingress ipv6 ingress input ethernet-1/1.110" ]] && ok "conflict: candidate takes the holder's (node, port, subinterface, direction, family)" || bad "conflict candidate" "$got"

# ---------------------------------------------------------------- control before readiness (source order)
order() { local c r; c="$(grep -n -m1 -F -- "$2" "$1" | cut -d: -f1)"; r="$(grep -n -m1 -F -- "$3" "$1" | cut -d: -f1)"; [[ -n "$c" && -n "$r" && "$c" -lt "$r" ]]; }
for c in AV-written AV-binding AV-applied AV-stats; do
  expect "acl_verify: $c control before readiness (source)" order "$IT/acl_verify.sh" "av::neg $c" "av::chk $c"
done
expect "acl_verify: AV-ready control before readiness (source)" order "$IT/acl_verify.sh" "av::neg AV-ready" "--check AV-ready --readiness"
expect "acl_verify: controls before the positive pass" order "$IT/acl_verify.sh" "av::controls ||" "  av::positive"
for c in AP-applied AP-deny AP-permit AP-delta AP-gone AP-ready; do
  expect "acl_enforcement_probe: $c control before readiness (source)" order "$IT/acl_enforcement_probe.sh" "ap::neg $c" "ap::chk $c"
done
expect "acl_enforcement_probe: controls before any probe" order "$IT/acl_enforcement_probe.sh" "  ap::controls ||" "ap::has ingress && ap::direction"
expect "acl_enforcement_probe: exit trap removes the Networks" grep -q "trap ap::cleanup EXIT" "$IT/acl_enforcement_probe.sh"
expect "acl_enforcement_probe: low-rate probes only" grep -q 'ping -c 3 -i 0.5 -W 2' "$LIB"
refuse "acl_enforcement_probe: never a flood" grep -qE 'ping [^#]*-f( |$)' "$LIB" "$IT/acl_enforcement_probe.sh"
for c in AC-refused AC-accepted; do
  expect "acl_conflict: $c control before readiness (source)" order "$IT/acl_conflict.sh" "ac::neg $c" "ac::chk $c"
done

[[ "$fails" -eq 0 ]] || { echo "acl_suites_test: $fails failure(s)"; exit 1; }
echo "acl_suites_test: all passed"
