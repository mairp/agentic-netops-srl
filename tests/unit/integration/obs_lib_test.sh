#!/usr/bin/env bash
# obs_lib_test.sh — the US11 observability live suites offline (T134): tests/integration/lib/obs.sh's
# pure functions and the structure of tests/integration/{observability_verify,alerts_fire,
# topology_parity}.sh. No lab, no cluster: a fake kubectl serves Prometheus's alert endpoint.
#
# Asserts:
#   - every suite is executable, bash -n clean, and refuses bad arguments with its usage (exit 2)
#     before touching anything; the library refuses to be executed
#   - alert state parsing: firing wins over pending, pending over nothing; another alert's state
#     never leaks; an empty alert list is inactive
#   - obs::wait_alert over a fake /api/v1/alerts sequence: met on the read that shows the state
#     (OBS_MET_AT set), a bounded timeout otherwise naming the last state
#   - rule query extraction from /api/v1/rules; dashboard uid lookup from /api/search
#   - dashboard query extraction: nested row panels, hidden targets skipped, $service / ${service} /
#     [[service]] substituted, Grafana's interval variables made concrete
#   - service detection: a Network with a bridge domain or a router is a service, a plain vlan is
#     not; spanning = its attachments cover every leaf given
#   - interface normalization agrees with R-10 (ethernet-1/49 → e1-49; mgmt0 unchanged)
#   - the committed containerlab topology yields the four fabric links in both directions, normalized,
#     and no client link
#   - in every suite, every check id run with --readiness has its negative control issued (obs::neg /
#     suite::neg) in the same script
#   - alerts_fire.sh starts with the leftover refusal and runs the rule unit test before any fault, and
#     treats its exit 77 as a failure; every declarative change it makes is registered for the exit trap
# shellcheck disable=SC2015,SC2016 # ok/bad never fail (`A && ok || bad`); jq/PromQL bodies are single-quoted on purpose
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
IT="$ROOT/tests/integration"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 12 | sed 's/^/    | /'; fails=$((fails + 1)); return 0; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got:      $2"$'\n'"expected: $3"; fi; }

# ---------------------------------------------------------------- structure, usage
for s in observability_verify alerts_fire topology_parity; do
  f="$IT/$s.sh"
  if [[ -x "$f" ]] && bash -n "$f"; then ok "$s: executable, bash -n clean"; else bad "$s: not executable or bash -n fails"; fi
  rc=0; out="$(bash "$f" bogus 2>&1)" || rc=$?
  if [[ "$rc" == 2 && "$out" == *Usage:* ]]; then ok "$s: usage on a bad argument (exit 2)"; else bad "$s: bad argument rc=$rc" "$out"; fi
done
rc=0; bash "$IT/lib/obs.sh" >/dev/null 2>&1 || rc=$?
eq "lib/obs.sh refuses to be executed" "$rc" 2

# shellcheck source=../../integration/lib/obs.sh
source "$IT/lib/obs.sh"

# ---------------------------------------------------------------- alert state
ALERTS='{"status":"success","data":{"alerts":[
  {"labels":{"alertname":"FabricLinkDown","source":"leaf01"},"state":"pending"},
  {"labels":{"alertname":"FabricLinkDown","source":"leaf02"},"state":"firing"},
  {"labels":{"alertname":"BGPSessionDown"},"state":"pending"},
  {"labels":{"alertname":"OtlpExportFailing"},"state":"firing"}]}}'
eq "alert state: firing wins over pending" "$(obs::alert_state_from_json FabricLinkDown <<<"$ALERTS")" firing
eq "alert state: pending alone" "$(obs::alert_state_from_json BGPSessionDown <<<"$ALERTS")" pending
eq "alert state: an absent alert is inactive (no leak from others)" "$(obs::alert_state_from_json EvpnRoutesLost <<<"$ALERTS")" inactive
eq "alert state: an empty list is inactive" "$(obs::alert_state_from_json FabricLinkDown <<<'{"data":{"alerts":[]}}')" inactive

# ---------------------------------------------------------------- wait_alert over a fake endpoint
mkdir -p "$T/bin" "$T/alerts"
cat >"$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# serves $FAKE/alerts/<n>.json for the n-th /api/v1/alerts read (the last repeats)
[[ "$*" == *"/proxy/api/v1/alerts"* ]] || exit 1
n=$(( $(cat "$FAKE/n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$FAKE/n"
f="$FAKE/alerts/$n.json"; [[ -f "$f" ]] || f="$(ls "$FAKE"/alerts/*.json | sort -V | tail -1)"
cat "$f"
EOF
chmod +x "$T/bin/kubectl"
export FAKE="$T" KUBECTL="$T/bin/kubectl" OBS_POLL=0.1
echo '{"status":"success","data":{"alerts":[]}}' >"$T/alerts/1.json"
echo '{"status":"success","data":{"alerts":[{"labels":{"alertname":"FabricLinkDown"},"state":"pending"}]}}' >"$T/alerts/2.json"
echo '{"status":"success","data":{"alerts":[{"labels":{"alertname":"FabricLinkDown"},"state":"firing"}]}}' >"$T/alerts/3.json"
rc=0; out="$(obs::wait_alert FabricLinkDown firing 10; echo "met=$OBS_MET_AT")" || rc=$?
[[ "$rc" == 0 && "$(cat "$T/n")" == 3 && "$out" == *"met="[0-9]* ]] && ok "wait_alert: met on the third read, OBS_MET_AT set" || bad "wait_alert firing rc=$rc reads=$(cat "$T/n")" "$out"
rm -f "$T/n" "$T/alerts/1.json" "$T/alerts/2.json"
rc=0; out="$(obs::wait_alert FabricLinkDown inactive 1)" || rc=$?
[[ "$rc" != 0 && "$out" == *"last state: firing"* ]] && ok "wait_alert: bounded timeout naming the last state" || bad "wait_alert timeout rc=$rc" "$out"
rm -f "$T/n" "$T"/alerts/*.json
echo '{"status":"success","data":{"alerts":[]}}' >"$T/alerts/1.json"
rc=0; out="$(obs::wait_alert FabricLinkDown inactive 1)" || rc=$?
eq "wait_alert: no alert reads inactive" "$rc" 0
unset KUBECTL

# ---------------------------------------------------------------- rules, search
RULES='{"status":"success","data":{"groups":[{"name":"pipeline","rules":[
  {"name":"DuplicateDeviceSeries","type":"alerting","query":"count without(job) ({__name__=~\"srl_nokia_.+\"}) > 1"},
  {"name":"agentic_netops_node_info","type":"recording","query":"vector(1)"}]}]}}'
eq "rule query extraction" "$(obs::rule_query_from_json DuplicateDeviceSeries <<<"$RULES")" 'count without(job) ({__name__=~"srl_nokia_.+"}) > 1'
eq "rule query: an absent rule is empty" "$(obs::rule_query_from_json NoSuch <<<"$RULES")" ""
SEARCH='[{"uid":"fabric","title":"Fabric","type":"dash-db"},{"uid":"svc-path","title":"EVPN service path","type":"dash-db"},{"uid":"f1","title":"General","type":"dash-folder"}]'
eq "dashboard uid by title" "$(obs::dashboard_uid_from_json 'evpn.?service' <<<"$SEARCH")" svc-path
eq "dashboard uid: folders are not dashboards" "$(obs::dashboard_uid_from_json general <<<"$SEARCH")" ""

# ---------------------------------------------------------------- dashboard queries
DASH='{"dashboard":{"uid":"svc-path","templating":{"list":[{"name":"service"}]},"panels":[
  {"title":"Tunnel path","type":"row","panels":[
    {"title":"VTEPs","targets":[{"refId":"A","expr":"srl_nokia_tunnel:x{network_instance_name=\"$service\"}"},
                                {"refId":"B","expr":"hidden_q","hide":true}]}]},
  {"title":"EVI","targets":[{"refId":"A","expr":"bgp_instance_evi{network_instance_name=\"${service}\"}"}]},
  {"title":"ACL hits","targets":[{"refId":"A","expr":"sum by (acl_filter_name) (rate(matched_packets{ni=\"[[service]]\"}[$__rate_interval]))"}]},
  {"title":"Text","type":"text"}]}}'
q="$(obs::dashboard_queries macvrf-lab <<<"$DASH")"
eq "dashboard queries: three visible targets (nested row, hidden skipped)" "$(wc -l <<<"$q" | tr -d ' ')" 3
[[ "$q" == *$'VTEPs\tsrl_nokia_tunnel:x{network_instance_name="macvrf-lab"}'* ]] && ok "dashboard queries: \$service substituted, panel title kept" || bad "dashboard queries: \$service" "$q"
[[ "$q" == *'bgp_instance_evi{network_instance_name="macvrf-lab"}'* ]] && ok "dashboard queries: \${service} substituted" || bad "dashboard queries: \${service}" "$q"
[[ "$q" == *'ni="macvrf-lab"}[1m]'* ]] && ok "dashboard queries: [[service]] and \$__rate_interval substituted" || bad "dashboard queries: [[service]]/__rate_interval" "$q"
[[ "$q" != *hidden_q* ]] && ok "dashboard queries: a hidden target is not a shown identifier" || bad "hidden target extracted"

# ---------------------------------------------------------------- service / spanning detection
NETS='{"items":[
  {"metadata":{"namespace":"s","name":"lab-vlan"},"spec":{"vlans":[{"vlan":10}],"attachments":[{"node":"leaf01"},{"node":"leaf02"}]}},
  {"metadata":{"namespace":"s","name":"one-leaf"},"spec":{"bridgeDomains":[{"vlan":20}],"attachments":[{"node":"leaf01"}]}},
  {"metadata":{"namespace":"s","name":"span-mac"},"spec":{"bridgeDomains":[{"vlan":30}],"attachments":[{"node":"leaf01"},{"node":"leaf02"}]}},
  {"metadata":{"namespace":"t","name":"span-ip"},"spec":{"routers":[{"name":"r"}],"attachments":[{"node":"leaf02"},{"node":"leaf01"}]}}]}'
eq "services: bridge domains or routers, never a plain vlan" "$(obs::service_networks <<<"$NETS" | paste -sd' ')" "s/one-leaf s/span-mac t/span-ip"
eq "spanning: attachments cover both leaves" "$(obs::spanning_networks leaf01 leaf02 <<<"$NETS" | paste -sd' ')" "s/span-mac t/span-ip"
eq "spanning: none when nothing spans" "$(obs::spanning_networks leaf01 leaf02 <<<'{"items":[]}')" ""

# ---------------------------------------------------------------- normalization, inventory
eq "normalize ethernet-1/49" "$(obs::normalize_iface ethernet-1/49)" e1-49
eq "normalize ethernet-10/2" "$(obs::normalize_iface ethernet-10/2)" e10-2
eq "normalize mgmt0 unchanged" "$(obs::normalize_iface mgmt0)" mgmt0
links="$(obs::clab_device_links "$ROOT/lab/topology.clab.yml")"
eq "clab links: 4 fabric links × 2 directions" "$(wc -l <<<"$links" | tr -d ' ')" 8
grep -qxF "leaf01 e1-49 spine01 e1-1" <<<"$links" && grep -qxF "spine01 e1-1 leaf01 e1-49" <<<"$links" \
  && ok "clab links: leaf01 e1-49 ↔ spine01 e1-1, both directions, normalized" || bad "clab links" "$links"
grep -q client <<<"$links" && bad "clab links carry a client link" "$links" || ok "clab links: no client (linux) link"
eq "clab nodes: roles from the lab labels" "$(obs::clab_nodes "$ROOT/lab/topology.clab.yml" | grep -E '^(leaf01|client01) ' | paste -sd';')" "leaf01 nokia_srlinux leaf;client01 linux client"

# ---------------------------------------------------------------- negative controls precede readiness
for s in observability_verify alerts_fire topology_parity; do
  f="$IT/$s.sh"
  missing=""
  while read -r chk; do
    grep -qE "(obs|suite)::neg ${chk} " "$f" || missing+=" $chk"
  done < <(grep -oE '(obs|suite)::check [^ ]+ [A-Za-z]+-[A-Za-z-]+ --readiness' "$f" | awk '{print $3}' | sort -u)
  [[ -z "$missing" ]] && ok "$s: every readiness check has its negative control in the script" || bad "$s: no negative control for:$missing"
done

# ---------------------------------------------------------------- alerts_fire.sh's FR-108 convention
AF="$IT/alerts_fire.sh"
run_body="$(sed -n '/^af::run() {/,/^}/p' "$AF")"
order="$(grep -noE 'suite::refuse_on_leftovers|af::rule_unit_test|af::link|af::reconcile|af::evpn|af::stalled|af::stage' <<<"$run_body" | sed 's/^[0-9]*://' | paste -sd' ')"
eq "alerts_fire: leftovers refusal, then the rule unit test, then the live faults" "$order" "suite::refuse_on_leftovers af::rule_unit_test af::link af::reconcile af::evpn af::stalled af::stage"
grep -qE '77\) suite::fail' "$AF" && ok "alerts_fire: the rule unit test's not-run (77) is a failure" || bad "alerts_fire: exit 77 not failed"
grep -q 'suite::on_exit af::reflect_restore' "$AF" && grep -q 'suite::on_exit af::delete_negative' "$AF" && grep -q 'suite::maint_add' "$AF" \
  && grep -q 'suite::mgmt_cut' "$AF" && ok "alerts_fire: reflectorClients, the negative Network, maintenance[] and the cut are restored from the exit trap" \
  || bad "alerts_fire: a declarative change is not registered for the exit trap"
grep -q 'reflectorClients":false' "$AF" && ! grep -v '^ *#' "$AF" | grep -qE 'interASVPN"?: ?false' \
  && ok "alerts_fire: the EvpnRoutesLost fault is reflectorClients=false (AD-77), never interASVPN=false" || bad "alerts_fire: EvpnRoutesLost fault"
grep -q 'EvpnRoutesLost NOT RUN' "$AF" && ok "alerts_fire: no spanning service → NOT RUN, never a pass" || bad "alerts_fire: not-run wording"

echo "obs_lib_test: $fails failure(s)"
[[ "$fails" -eq 0 ]]
