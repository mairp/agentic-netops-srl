#!/usr/bin/env bash
# tests/integration/topology_parity.sh — the two views' identifiers against the inventory, the
# rendered objects and direct metric queries, live (T134; FR-094, FR-096, R-10, SC-017, SC-036;
# quickstart.md §21). Behind `make verify-topology-view` (physical) and
# `make verify-evpn-service-view` (service-path).
#
# physical — the join is exactly two labels, `source` and the normalized `interface_name`
#   (ethernet-1/49 → e1-49, R-10):
#   * the inventory: lab/topology.clab.yml's nodes and device↔device links (one row per direction),
#     its node set equal to the LIVE containerlab lab's (containers labelled containerlab=<lab>)
#   * the generated assets installed in ConfigMap monitoring/topology-assets (T131): every dataRef of
#     the panel YAML names an inventory (source, e<slot>-<port>) endpoint and every endpoint is named
#     by one; every node appears; no un-normalized ethernet-N/M anywhere in a dataRef
#   * the metric side: agentic_netops_fabric_link_info == the inventory's directed links;
#     agentic_netops_node_info == the inventory's nodes and roles; the device interface series carry
#     every inventory endpoint; every (source, interface_name) the provisioned physical-topology
#     dashboard's queries return is an inventory endpoint (queries read through the Grafana API)
#   * under normal traffic every fabric endpoint's oper-state reads 1; under a forced link failure
#     (TP_LEAF TP_LINK admin-disabled through Fabric.spec.maintenance[], restored from the exit trap)
#     that endpoint reads 0 — through the dashboard's own oper-state query too — while every endpoint
#     outside that link reads 1; after the restore all read 1 again
# service-path — for a chosen mac-vrf / ip-vrf Network (TP_NETWORK, default lab-macvrf-acl, else the
#   first spanning one), the identifiers the evpn-service-path dashboard shows — its queries taken
#   from the provisioned dashboard JSON (Grafana API /api/dashboards/uid/<uid>), $service substituted
#   (TP_SERVICE_VALUE, default the Network's network-instance name), executed against Prometheus —
#   equal the Network's rendered objects: the leaves carrying the instance (status.renderedConfigs /
#   the Configs), their VTEP addresses (the Fabric's systemIPv4), the EVI / VNI (the Configs'
#   bgp-evpn evi and vxlan-interface ingress vni) and the ACL filter names (the Configs' acl-filter);
#   the leaves ⊆ the inventory's leaves
# Every result through evidence_run, each readiness check after its failing negative control.
#
# Usage: topology_parity.sh physical | service-path
# Environment: TP_CLAB (lab/topology.clab.yml), TP_ASSETS_CM (topology-assets), TP_LEAF (leaf01),
#   TP_LINK (ethernet-1/49), TP_WAIT (s, 180), TP_NETWORK, TP_SERVICE_VALUE, TP_PHYSICAL_DASHBOARD
#   (regex, physical), TP_SERVICE_DASHBOARD (regex, evpn.?service), plus suite.sh's and obs.sh's.
set -euo pipefail

TP_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/suite.sh
source "$TP_HERE/lib/suite.sh"
# shellcheck source=lib/obs.sh
source "$TP_HERE/lib/obs.sh"

: "${TP_CLAB:=$SUITE_ROOT/lab/topology.clab.yml}"
: "${TP_ASSETS_CM:=topology-assets}"
: "${TP_LEAF:=leaf01}"
: "${TP_LINK:=ethernet-1/49}"
: "${TP_WAIT:=180}"
: "${TP_PHYSICAL_DASHBOARD:=physical}"
: "${TP_SERVICE_DASHBOARD:=evpn.?service}"
TP_OPER="srl_nokia_interfaces:interface_oper_state"
TP_FABRIC_OPER="${TP_OPER} and on(source, interface_name) agentic_netops_fabric_link_info"

# tp::f <name> — a working file of this run, OUTSIDE the evidence directory (verify-evidence refuses
# any file there no evidence record references); what is evidence is copied in and attached (tp::attach)
TP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/topology-parity.XXXXXX")"
tp::f() { printf '%s/%s' "$TP_WORK" "$1"; }
# tp::attach <working file> — copy it under the evidence directory; prints the path relative to it
tp::attach() {
  mkdir -p "$EVIDENCE_DIR/topology-parity"
  cp "$1" "$EVIDENCE_DIR/topology-parity/${1##*/}"
  printf 'topology-parity/%s' "${1##*/}"
}

# tp::sets_equal <label> <expected-file> <actual-file> — lines compared as sets; differences named
tp::sets_equal() {
  local missing extra a b
  # both sides are read more than once below, and a caller may pass a process substitution, which
  # can be read only once: materialize them first
  a="$(tp::f "set-$(tr -c 'a-zA-Z0-9' '_' <<<"$1")expected")"; b="${a%expected}shown"
  LC_ALL=C sort -u "$2" >"$a"; LC_ALL=C sort -u "$3" >"$b"
  set -- "$1" "$a" "$b"
  missing="$(LC_ALL=C comm -23 "$2" "$3" | paste -sd';')"
  extra="$(LC_ALL=C comm -13 "$2" "$3" | paste -sd';')"
  jq -cn --arg l "$1" --arg m "$missing" --arg e "$extra" '{set: $l, missing: ($m | split(";") | map(select(. != ""))), unexpected: ($e | split(";") | map(select(. != "")))}' | sed 's/^/SUMMARY /'
  if [[ -z "$missing" && -z "$extra" ]]; then echo "PASS $1: equal ($(LC_ALL=C sort -u "$2" | wc -l) entries)"; return 0; fi
  [[ -n "$missing" ]] && echo "FAIL $1: missing ${missing}"
  [[ -n "$extra" ]] && echo "FAIL $1: unexpected ${extra}"
  return 1
}

# ================================================================== physical

# tp::inventory — writes inv-nodes (node role), inv-links (node iface peer peeriface), inv-endpoints (node iface)
tp::inventory() {
  obs::clab_nodes "$TP_CLAB" | awk '{print $1, $3}' | LC_ALL=C sort -u >"$(tp::f inv-nodes)"
  obs::clab_device_links "$TP_CLAB" >"$(tp::f inv-links)"
  obs::clab_device_endpoints "$TP_CLAB" >"$(tp::f inv-drawn-endpoints)"
  awk '{print $1, $2}' "$(tp::f inv-links)" | LC_ALL=C sort -u >"$(tp::f inv-endpoints)"
  [[ -s "$(tp::f inv-links)" ]] || { log::error "no device↔device link in ${TP_CLAB}"; return 1; }
}

# tp::chk_live_nodes <expected nodes file> — the live lab's containers == the file's nodes
tp::chk_live_nodes() {
  local live; live="$(tp::f live-nodes)"
  lab::docker ps --filter "label=containerlab=${LAB_NAME}" --format '{{.Label "clab-node-name"}}' | grep . | LC_ALL=C sort -u >"$live" \
    || { echo "FAIL no running container of lab ${LAB_NAME}"; return 1; }
  awk '{print $1}' "$1" >"$(tp::f expect-live-nodes)"
  tp::sets_equal "live containerlab nodes" "$(tp::f expect-live-nodes)" "$live"
}

# tp::asset_refs — every dataRef (and cell id) of the YAML documents in ConfigMap topology-assets
tp::asset_refs() {
  local cm k
  cm="$(lab::kubectl -n "$OBS_NS" get configmap "$TP_ASSETS_CM" -o json)" || return 1
  for k in $(jq -r '.data // {} | keys[]' <<<"$cm"); do
    case "$k" in *.yaml|*.yml|*.json)
      jq -r --arg k "$k" '.data[$k]' <<<"$cm" | yq -r '.. | select(tag == "!!map" and has("dataRef")) | .dataRef' 2>/dev/null || true ;;
    esac
  done | grep . | LC_ALL=C sort -u
}

# tp::chk_assets <endpoints file> <nodes file> — the installed assets name exactly the inventory
tp::chk_assets() {
  local refs got text n bad=0 r node ifc parts
  refs="$(tp::asset_refs)" || { echo "FAIL ConfigMap ${OBS_NS}/${TP_ASSETS_CM} unreadable"; return 1; }
  [[ -n "$refs" ]] || { echo "FAIL ConfigMap ${OBS_NS}/${TP_ASSETS_CM} carries no dataRef"; return 1; }
  got="$(tp::f asset-endpoints)"; : >"$got"
  while IFS= read -r r; do
    [[ "$r" =~ ethernet-[0-9]+/[0-9]+ ]] && { echo "FAIL dataRef '${r}' carries an un-normalized interface name"; bad=1; }
    # a dataRef is "<node>:<iface>:<direction>" (traffic) or "oper-state:<node>:<iface>" (state)
    IFS=: read -r -a parts <<<"${r#oper-state:}"
    node="${parts[0]:-}"; ifc="${parts[1]:-}"
    [[ "$ifc" =~ ^e[0-9]+-[0-9]+$ ]] || ifc=""
    awk '{print $1}' "$2" | grep -qxF -- "$node" || node=""
    if [[ -z "$node" || -z "$ifc" ]]; then echo "FAIL dataRef '${r}' names no inventory node and normalized interface"; bad=1; continue; fi
    echo "$node $ifc" >>"$got"
  done <<<"$refs"
  text="$(lab::kubectl -n "$OBS_NS" get configmap "$TP_ASSETS_CM" -o json | jq -r '.data // {} | .[]')"
  while read -r n _; do grep -qw -- "$n" <<<"$text" || { echo "FAIL node ${n} appears nowhere in the assets"; bad=1; }; done <"$2"
  tp::sets_equal "asset dataRef endpoints" "$1" "$got" || bad=1
  return "$bad"
}

# tp::chk_prom_set <label> <expected file> <promql> <label…> — the query's label tuples == the file
tp::chk_prom_set() {
  local label="$1" exp="$2" q="$3" v got; shift 3
  v="$(obs::prom_vector "$q")" || { echo "FAIL query unreadable: $q"; return 1; }
  got="$(tp::f "prom-$(tr -c 'a-zA-Z0-9' '_' <<<"$label")")"
  jq -r --args '.[] | .metric as $m | [$ARGS.positional[] | $m[.] // ""] | join(" ")' "$@" <<<"$v" | LC_ALL=C sort -u >"$got"
  tp::sets_equal "$label" "$exp" "$got"
}

# tp::chk_values <promql> <expect-file: "source iface value"> — each listed endpoint reads that value
tp::chk_values() {
  local v bad=0 s i want have
  v="$(obs::prom_vector "$1")" || { echo "FAIL query unreadable: $1"; return 1; }
  while read -r s i want; do
    have="$(jq -r --arg s "$s" --arg i "$i" '[.[] | select(.metric.source == $s and .metric.interface_name == $i) | .value[1]] | first // "absent"' <<<"$v")"
    if [[ "$want" == any || "$have" == "$want" ]]; then echo "PASS ${s} ${i} reads ${have}"; else echo "FAIL ${s} ${i} reads ${have}, expected ${want}"; bad=1; fi
  done <"$2"
  jq -c '{values: [.[] | {source: .metric.source, interface_name: .metric.interface_name, value: .value[1]}]}' <<<"$v" | sed 's/^/SUMMARY /'
  return "$bad"
}

# tp::chk_values_within <promql> <expect-file> <timeout_s>
tp::chk_values_within() {
  local t0 out rc
  t0="$(date +%s)"
  while :; do
    rc=0; out="$(tp::chk_values "$1" "$2")" || rc=$?
    [[ "$rc" -eq 0 ]] && { printf '%s\n' "$out"; echo "PASS after $(( $(date +%s) - t0 ))s"; return 0; }
    (( $(date +%s) - t0 >= $3 )) && break
    sleep "$OBS_POLL"
  done
  printf '%s\n' "$out"; return 1
}

# tp::chk_dashboard_ids <regex> <endpoints file> <nodes file> — every (source, interface_name) the
# dashboard's queries return is an inventory endpoint, every source an inventory node; at least one
# query answers
tp::chk_dashboard_ids() {
  local d q v bad=0 answered=0 pairs title flows
  d="$(obs::dashboard "$1")" || { echo "FAIL no provisioned dashboard matches /$1/ (Grafana API)"; return 1; }
  # a flow panel DISPLAYS only the cells its panel configuration maps (the dataRefs TP.assets checked
  # against the inventory); the series its queries return beyond those are never drawn. So for a flow
  # panel the check is the other way round: every drawn endpoint is fed by the query
  flows="$(jq -r '(.dashboard // .) | .. | objects | select(.type? == "andrewbmchugh-flow-panel") | .title // ""' <<<"$d")"
  while IFS=$'\t' read -r title q; do
    [[ -n "$q" ]] || continue
    v="$(obs::prom_vector "$q" 2>/dev/null)" || { echo "FAIL dashboard query unreadable: $q"; bad=1; continue; }
    [[ "$(jq length <<<"$v")" -gt 0 ]] && answered=$((answered + 1))
    pairs="$(jq -r '.[] | select(.metric.interface_name != null) | "\(.metric.source // "") \(.metric.interface_name)"' <<<"$v" | sort -u)"
    if grep -qxF -- "$title" <<<"$flows"; then
      while read -r s i; do
        grep -qxF "$s $i" <<<"$pairs" || { echo "FAIL flow panel '${title}': drawn endpoint ${s} ${i} has no series (query: ${q})"; bad=1; }
      done <"$2"
      echo "PASS flow panel '${title}': every drawn endpoint fed (query: ${q})"
      continue
    fi
    while read -r s i; do
      [[ -n "$s$i" ]] || continue
      grep -qxF "$s $i" "$2" || { echo "FAIL dashboard shows ${s} ${i}, not an inventory fabric endpoint (query: ${q})"; bad=1; }
    done <<<"$pairs"
    while read -r s; do
      [[ -n "$s" ]] || continue
      awk '{print $1}' "$3" | grep -qxF "$s" || { echo "FAIL dashboard shows source ${s}, not an inventory node (query: ${q})"; bad=1; }
    done < <(jq -r '.[].metric.source // empty' <<<"$v" | sort -u)
  done < <(obs::dashboard_queries "" <<<"$d")
  echo "SUMMARY {\"answered_queries\":${answered}}"
  [[ "$answered" -gt 0 ]] || { echo "FAIL no query of the dashboard returned a series"; bad=1; }
  return "$bad"
}

# tp::dashboard_oper_query <regex> — the physical dashboard's oper-state query (the link colour)
tp::dashboard_oper_query() {
  local d; d="$(obs::dashboard "$1")" || return 1
  obs::dashboard_queries "" <<<"$d" | cut -f2 | grep -F 'interface_oper_state' | head -1
}

tp::physical_negatives() {
  local bogus; bogus="$(tp::f bogus-endpoints)"
  printf 'vt-scratch-node e9-99\n' >"$bogus"
  printf 'vt-scratch-node none\n' >"$(tp::f bogus-nodes)"
  printf 'vt-scratch-node e9-99 1\n' >"$(tp::f bogus-values)"
  obs::neg TP-live-nodes tp::chk_live_nodes "$(tp::f bogus-nodes)" || true
  obs::neg TP-assets tp::chk_assets "$bogus" "$(tp::f bogus-nodes)" || true
  obs::neg TP-link-info tp::chk_prom_set "link info (control)" "$bogus" agentic_netops_fabric_link_info source interface_name || true
  obs::neg TP-node-info tp::chk_prom_set "node info (control)" "$(tp::f bogus-nodes)" agentic_netops_node_info source role || true
  obs::neg TP-endpoints tp::chk_prom_set "endpoints (control)" "$bogus" "count by (source, interface_name) (${TP_FABRIC_OPER})" source interface_name || true
  obs::neg TP-dashboard-ids tp::chk_dashboard_ids vt-scratch-no-such-dashboard "$bogus" "$(tp::f bogus-nodes)" || true
  obs::neg TP-values tp::chk_values_within "$TP_FABRIC_OPER" "$(tp::f bogus-values)" 1 || true
}

tp::physical() {
  local rc peer ifc exp_up exp_down oq
  suite::init topology-parity || return $?
  tp::inventory || { suite::fail "the inventory ${TP_CLAB#"$SUITE_ROOT"/} could not be read"; suite::finish topology-parity; return 1; }
  tp::physical_negatives
  local ends nodes links
  ends="$(tp::f inv-endpoints)"; nodes="$(tp::f inv-nodes)"; links="$(tp::f inv-links)"
  rc=0; obs::check TP.live-nodes TP-live-nodes --readiness -- tp::chk_live_nodes "$nodes" >/dev/null || rc=$?
  suite::judge "$rc" "the live containerlab lab's nodes == the inventory's" "the live lab's nodes differ from ${TP_CLAB##*/}"
  rc=0; obs::check TP.assets TP-assets --readiness -- tp::chk_assets "$(tp::f inv-drawn-endpoints)" "$nodes" >/dev/null || rc=$?
  suite::judge "$rc" "the installed topology assets name exactly the inventory's nodes and endpoints" "topology assets ≠ inventory: $(grep -h '^FAIL' "$EVIDENCE_DIR/$OBS_LAST_ID.stdout" | head -3 | paste -sd';')"
  rc=0; obs::check TP.link-info TP-link-info --readiness -- tp::chk_prom_set "agentic_netops_fabric_link_info" "$links" agentic_netops_fabric_link_info source interface_name peer_source peer_interface >/dev/null || rc=$?
  suite::judge "$rc" "agentic_netops_fabric_link_info == the inventory's directed links" "agentic_netops_fabric_link_info ≠ inventory"
  rc=0; obs::check TP.node-info TP-node-info --readiness -- tp::chk_prom_set "agentic_netops_node_info" "$nodes" agentic_netops_node_info source role >/dev/null || rc=$?
  suite::judge "$rc" "agentic_netops_node_info == the inventory's nodes and roles" "agentic_netops_node_info ≠ inventory"
  rc=0; obs::check TP.endpoints TP-endpoints --readiness -- tp::chk_prom_set "device interface series on fabric links" "$ends" "count by (source, interface_name) (${TP_FABRIC_OPER})" source interface_name >/dev/null || rc=$?
  suite::judge "$rc" "the device series carry every inventory endpoint under the join labels" "device series ≠ inventory endpoints"
  rc=0; obs::check TP.dashboard-ids TP-dashboard-ids --readiness -- tp::chk_dashboard_ids "$TP_PHYSICAL_DASHBOARD" "$(tp::f inv-drawn-endpoints)" "$nodes" >/dev/null || rc=$?
  suite::judge "$rc" "every identifier the physical-topology dashboard shows is an inventory identifier" "the physical-topology dashboard shows identifiers outside the inventory"

  # normal traffic: every endpoint up
  exp_up="$(tp::f expect-up)"; awk '{print $1, $2, 1}' "$ends" >"$exp_up"
  rc=0; obs::check TP.values.normal TP-values --readiness -- tp::chk_values_within "$TP_FABRIC_OPER" "$exp_up" "$TP_WAIT" >/dev/null || rc=$?
  suite::judge "$rc" "normal: every fabric endpoint reads 1" "normal: a fabric endpoint does not read 1"

  # forced link failure (intent; restored from the exit trap)
  ifc="$(obs::normalize_iface "$TP_LINK")"
  peer="$(awk -v n="$TP_LEAF" -v i="$ifc" '$1 == n && $2 == i {print $3, $4}' "$links")"
  [[ -n "$peer" ]] || { suite::fail "${TP_LEAF} ${TP_LINK} is not a fabric link of the inventory"; suite::finish topology-parity; return 1; }
  exp_down="$(tp::f expect-down)"
  awk -v n="$TP_LEAF" -v i="$ifc" -v p="$peer" '{ k = $1 " " $2; if (k == n " " i) print k, 0; else if (k == p) print k, "any"; else print k, 1 }' "$ends" >"$exp_down"
  suite::maint_add "$TP_LEAF" "$TP_LINK" || { suite::fail "maintenance[] patch refused"; suite::finish topology-parity; return 1; }
  rc=0; obs::check TP.values.failed TP-values --readiness -- tp::chk_values_within "$TP_FABRIC_OPER" "$exp_down" "$TP_WAIT" >/dev/null || rc=$?
  suite::judge "$rc" "forced failure: ${TP_LEAF} ${ifc} reads 0, every endpoint outside the link reads 1 (peer ${peer} recorded)" "forced failure: the link's endpoint does not read 0 or another endpoint left 1"
  oq="$(tp::dashboard_oper_query "$TP_PHYSICAL_DASHBOARD" 2>/dev/null || true)"
  if [[ -n "$oq" ]]; then
    printf '%s %s 0\n' "$TP_LEAF" "$ifc" >"$(tp::f expect-panel-down)"
    rc=0; obs::check TP.values.panel TP-values --readiness -- tp::chk_values_within "$oq" "$(tp::f expect-panel-down)" "$TP_WAIT" >/dev/null || rc=$?
    suite::judge "$rc" "forced failure: the physical view's own oper-state query reads 0 for ${TP_LEAF} ${ifc}" "forced failure: the physical view's query does not read 0 for the link"
  else
    suite::fail "the physical-topology dashboard has no interface_oper_state query (the link state is not shown)"
  fi
  suite::maint_restore || suite::fail "maintenance[] restoration"
  rc=0; obs::check TP.values.restored TP-values --readiness -- tp::chk_values_within "$TP_FABRIC_OPER" "$exp_up" "$TP_WAIT" >/dev/null || rc=$?
  suite::judge "$rc" "restored: every fabric endpoint reads 1 again" "restored: a fabric endpoint does not read 1 after the entry was removed"
  suite::finish topology-parity
}

# ================================================================== service path

# tp::expected_service <ns> <name> — the Network's rendered identifiers, one "<kind> <value>" per line:
#   leaf <node>, ni <network-instance>, evi <n>, vni <n>, vtep <address>, acl <filter>
tp::expected_service() {
  local ns="$1" name="$2" net cfgs fab c node
  net="$(lab::kubectl -n "$ns" get "$SUITE_NET_RES" "$name" -o json)" || return 1
  fab="$(lab::kubectl -n "$FABRIC_NAMESPACE" get "$SUITE_FABRIC_RES" "$FABRIC_NAME" -o json)" || return 1
  cfgs="$(jq -r '.status.renderedConfigs[]? | "\(.namespace) \(.name) \(.node)"' <<<"$net")"
  while read -r c_ns c node; do
    [[ -n "$c" ]] || continue
    lab::kubectl -n "$c_ns" get configs.config.sdcio.dev "$c" -o json | jq -r --arg node "$node" '
      [.spec.config[]?.value] as $v
      | ([$v[] | .["srl_nokia-network-instance:network-instance"]?[]? | select(.protocols["bgp-evpn"] != null)]) as $nis
      | if ($nis | length) > 0 then
          "leaf \($node)",
          ($nis[] | "ni \(.name)"),
          ($nis[] | .protocols["bgp-evpn"][]?[]? | "evi \(.evi)"),
          ($v[] | .["srl_nokia-tunnel-interfaces:tunnel-interface"]?[]? | .["vxlan-interface"][]? | "vni \(.ingress.vni)")
        else empty end,
      ($v[] | .["srl_nokia-acl:acl"]?["acl-filter"]?[]? | "acl \(.name)")'
  done <<<"$cfgs"
  jq -r --argjson f "$fab" '[.status.renderedConfigs[]?.node] | unique[] as $n
    | $f.spec.nodes[]? | select(.name == $n) | "vtepcand \(.name) \(.systemIPv4 | split("/")[0])"' <<<"$net"
}

# tp::shown_service <dashboard regex> <value> — the identifiers the dashboard's queries return, same kinds:
# the leaves are the sources of series of the service's own network-instance; the default and mgmt
# instances (fabric-wide route/session panels) are not service identifiers
tp::shown_service() {
  local d q v id isevi vnis
  d="$(obs::dashboard "$1")" || return 1
  # the view's two derived variables, resolved as Grafana resolves them: $service_id by the variable's
  # own regex over $service (^(?:vlan|macvrf|ipvrf)-(.+)$), $vni at its "All" value ([0-9]+)
  id="$(sed -E 's/^(vlan|macvrf|ipvrf)-//' <<<"$2")"
  # $vni: the variable's options are this service's own vxlan-interfaces (label_values over
  # network_instance_vxlan_interface_oper_state{network_instance_name="$service"}, regex ^[^.]+\.([0-9]+)$)
  vnis="$(obs::prom_vector "srl_nokia_network_instance:network_instance_vxlan_interface_oper_state{network_instance_name=\"$2\"}" 2>/dev/null \
    | jq -r '.[].metric.vxlan_interface_name // empty' | sed -nE 's/^[^.]+\.([0-9]+)$/\1/p' | sort -u | paste -sd'|')"
  vnis="(${vnis:-none})"
  while IFS=$'\t' read -r _ q; do
    [[ -n "$q" ]] || continue
    q="${q//\$\{service_id\}/$id}"; q="${q//\$service_id/$id}"
    q="${q//\$\{vni\}/$vnis}"; q="${q//\$vni/$vnis}"
    v="$(obs::prom_vector "$q" 2>/dev/null)" || { echo "unreadable ${q}"; continue; }
    # a panel over the EVI series shows the EVI as its VALUE (max by (source) drops the name)
    isevi=false; [[ "$q" =~ ^max\ by\ \(source\)\ \([^\(\)]*bgp_instance_evi\{[^\}]*\}\)$ ]] && isevi=true
    jq -r --arg ni "$2" --argjson isevi "$isevi" '.[] | .metric as $m | .value[1] as $val
      | (if ($m.network_instance_name // "") == $ni then ($m.source // empty | "source \(.)") else empty end),
        ($m.network_instance_name // empty | select(. != "default" and . != "mgmt") | "ni \(.)"),
        ($m.vtep_address // $m.vtep // $m.destination_vtep // empty | "vtep \(.)"),
        ($m | to_entries[] | select(.key | test("(^|_)vni$")) | "vni \(.value)"),
        ($m.acl_filter_name // empty | "acl \(.)"),
        (if (($m.__name__ // "" | test("bgp_instance_evi$")) or $isevi) then "evi \($val)" else empty end)' <<<"$v"
  done < <(obs::dashboard_queries "$2" <<<"$d")
}

# tp::chk_service <expected file> <dashboard regex> <value> — shown == rendered, per kind
tp::chk_service() {
  local exp="$1" shown bad=0 k e s leaves
  shown="$(tp::f shown-service)"
  tp::shown_service "$2" "$3" | LC_ALL=C sort -u >"$shown" || { echo "FAIL the service-path dashboard could not be read"; return 1; }
  if grep -q '^unreadable ' "$shown"; then grep '^unreadable ' "$shown" | sed 's/^/FAIL query /'; bad=1; fi
  # the leaves: the sources the view shows for this service's instance == the leaves carrying it
  leaves="$(awk '$1 == "leaf" {print $2}' "$exp" | sort -u)"
  tp::sets_equal "leaves carrying the instance" <(printf '%s\n' "$leaves") <(awk '$1 == "source" {print $2}' "$shown") || bad=1
  for k in ni evi vni acl; do
    e="$(awk -v k="$k" '$1 == k {print $2}' "$exp" | sort -u)"
    s="$(awk -v k="$k" '$1 == k {print $2}' "$shown" | sort -u)"
    [[ -z "$e" && "$k" == acl ]] && continue
    if [[ "$k" == acl ]]; then   # the view may show the cpm/system filters beside the bound one: rendered ⊆ shown
      if [[ -z "$(comm -23 <(printf '%s\n' "$e") <(printf '%s\n' "$s"))" ]]; then echo "PASS acl filters ${e//$'\n'/ } shown"
      else echo "FAIL acl filters rendered '${e//$'\n'/ }', shown '${s//$'\n'/ }'"; bad=1; fi
      continue
    fi
    tp::sets_equal "$k" <(printf '%s\n' "$e") <(printf '%s\n' "$s") || bad=1
  done
  # VTEPs: with two or more leaves every leaf's VTEP (its system address) is shown
  e="$(awk '$1 == "vtepcand" {print $3}' "$exp" | sort -u)"
  s="$(awk '$1 == "vtep" {print $2}' "$shown" | sort -u)"
  if [[ "$(wc -l <<<"$leaves")" -ge 2 ]]; then tp::sets_equal "VTEPs" <(printf '%s\n' "$e") <(printf '%s\n' "$s") || bad=1; fi
  while read -r l; do [[ -z "$l" ]] || lab::is_leaf "$l" || { echo "FAIL ${l} carries the instance but is not an inventory leaf"; bad=1; }; done <<<"$leaves"
  return "$bad"
}

tp::service_path() {
  local ns name nets value exp rc bogus
  suite::init topology-parity || return $?
  nets="$(lab::kubectl get "$SUITE_NET_RES" -A -o json)" || { suite::fail "Networks unreadable"; suite::finish topology-parity; return 1; }
  if [[ -n "${TP_NETWORK:-}" ]]; then
    ns="${SVC_NS}"; name="$TP_NETWORK"; [[ "$TP_NETWORK" == */* ]] && { ns="${TP_NETWORK%%/*}"; name="${TP_NETWORK#*/}"; }
  elif jq -e --arg ns "$SVC_NS" 'any(.items[]; .metadata.namespace == $ns and .metadata.name == "lab-macvrf-acl")' >/dev/null <<<"$nets"; then
    ns="$SVC_NS"; name=lab-macvrf-acl
  else
    # shellcheck disable=SC2046  # the leaves are words
    read -r ref < <(obs::spanning_networks $(lab::leaves) <<<"$nets") || true
    [[ -n "${ref:-}" ]] || { suite::fail "no mac-vrf/ip-vrf Network to show (TP_NETWORK unset, no spanning service)"; suite::finish topology-parity; return 1; }
    ns="${ref%%/*}"; name="${ref#*/}"
  fi
  exp="$(tp::f expected-service)"
  tp::expected_service "$ns" "$name" | LC_ALL=C sort -u >"$exp" || { suite::fail "the rendered objects of ${ns}/${name} could not be read"; suite::finish topology-parity; return 1; }
  evidence_run "$(gate::id TP.service.rendered)" --attach "$(tp::attach "$exp")" -- cat "$exp" >/dev/null
  value="${TP_SERVICE_VALUE:-$(awk '$1 == "ni" {print $2; exit}' "$exp")}"
  [[ -n "$value" ]] || { suite::fail "${ns}/${name} renders no EVPN network-instance"; suite::finish topology-parity; return 1; }
  log::info "service path of ${ns}/${name}: \$${OBS_SERVICE_VAR}=${value}"
  bogus="$(tp::f bogus-service)"
  printf 'leaf vt-scratch-node\nni vt-scratch-ni\nevi 1\nvni 1\n' >"$bogus"
  obs::neg TP-service tp::chk_service "$bogus" "$TP_SERVICE_DASHBOARD" vt-scratch-ni || true
  rc=0; obs::check TP.service TP-service --readiness -- tp::chk_service "$exp" "$TP_SERVICE_DASHBOARD" "$value" >/dev/null || rc=$?
  suite::judge "$rc" "the EVPN service-path view of ${ns}/${name} shows exactly its rendered leaves, VTEPs, EVI/VNI and ACL filters" \
    "the service-path view ≠ the rendered objects: $(grep -h '^FAIL' "$EVIDENCE_DIR/$OBS_LAST_ID.stdout" 2>/dev/null | head -4 | paste -sd';')"
  suite::finish topology-parity
}

main() {
  case "${1:-}" in
    physical) tp::physical ;;
    service-path) tp::service_path ;;
    *) echo "Usage: $0 physical | service-path" >&2; return 2 ;;
  esac
}

main "$@"
