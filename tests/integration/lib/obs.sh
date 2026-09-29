#!/usr/bin/env bash
# tests/integration/lib/obs.sh — shared helpers of the US11 observability live suites (T134:
# observability_verify.sh, alerts_fire.sh, topology_parity.sh; FR-087, FR-089, FR-094, FR-096,
# SC-034…SC-037, NFR-013). Sourced after tests/integration/lib/suite.sh. Every read goes through
# lab::kubectl (always --context kind-<cluster>): Prometheus through the API server's service proxy
# (no port-forward, no ingress), Grafana through a port-forward with the administrator credential of
# the monitoring/grafana-admin Secret read into the environment and never echoed (FR-096).
#
# Readers (live):
#   obs::prom_get <path>                 GET <path> under the Prometheus service proxy
#   obs::prom_query <promql>             the /api/v1/query JSON (rc 1 unless status success)
#   obs::prom_vector <promql>            its .data.result as one compact JSON array
#   obs::prom_count <promql>             the number of result series
#   obs::prom_range <promql> <start> <end> <step>   the /api/v1/query_range .data.result
#   obs::alert_state <name>              firing | pending | inactive (from /api/v1/alerts)
#   obs::wait_alert <name> <firing|inactive> <timeout_s>   bounded; OBS_MET_AT = epoch it was met
#   obs::rule_query <name>               the loaded rule's expression (from /api/v1/rules)
#   obs::grafana_api <path>              GET /api/<path> as the provisioned administrator
#   obs::dashboard <regex>               the provisioned dashboard whose uid or title matches
#   obs::replicas <ns> <deploy>          spec.replicas
#   obs::scale <ns> <deploy> <n>         scale, remembering the original (restored from the exit trap)
#   obs::scale_restore <ns> <deploy>     put the original replica count back and wait for the rollout
# Pure (unit-tested offline, tests/unit/integration/obs_lib_test.sh):
#   obs::alert_state_from_json <name>    stdin /api/v1/alerts JSON → firing | pending | inactive
#   obs::rule_query_from_json <name>     stdin /api/v1/rules JSON → the rule's query
#   obs::dashboard_uid_from_json <regex> stdin /api/search JSON → the first uid whose uid/title matches
#   obs::dashboard_queries <value> [var] stdin dashboard JSON (or /api/dashboards/uid response) →
#                                        "<panel title>\t<expr>" per visible target, $var substituted
#   obs::service_networks                stdin Network list → "<ns>/<name>" of each carrying a bridge
#                                        domain or a router
#   obs::spanning_networks <leaf…>       … of those, whose attachments cover every given leaf
#   obs::normalize_iface <name>          ethernet-1/49 → e1-49 (R-10; topologyview.NormalizeInterface)
#   obs::clab_nodes <clab file>          "<node> <kind> <role>" per node
#   obs::clab_device_links <clab file>   "<node> <iface> <peer> <peer iface>" per DIRECTION of every
#                                        device↔device link, interface names normalized
#   obs::vector_pairs <label> <label>    stdin result array → "<v1> <v2>" per series, sorted unique
# Check wrappers: obs::check <id> <CHECK> [--readiness] -- <fn args…>; obs::neg <CHECK> <fn args…>
#   (the function runs in-process under evidence_run — NFR-013 — and prints one SUMMARY line)
#
# Environment: OBS_NS (monitoring), OBS_POLL (poll interval, 5 s), OBS_GF_PORT (local port of the
# Grafana port-forward, 13301), OBS_SERVICE_VAR (the service-path dashboard's variable, service).
# shellcheck source-path=SCRIPTDIR

[[ -n "${__AGENTIC_NETOPS_OBS_SH:-}" ]] && return 0
__AGENTIC_NETOPS_OBS_SH=1

OBS_LIB_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
if ! declare -F lab::kubectl >/dev/null; then
  # shellcheck source=../../lib/lab.sh
  source "$OBS_LIB_ROOT/tests/lib/lab.sh"
fi

: "${OBS_NS:=monitoring}"
: "${OBS_POLL:=5}"
: "${OBS_GF_PORT:=13301}"
: "${OBS_SERVICE_VAR:=service}"
OBS_PROM_PROXY="/api/v1/namespaces/${OBS_NS}/services/prometheus:9090/proxy"
# The required alert set (data-model.md §21, FR-087) — the same list scripts/lib/observability_phase.sh waits for.
# shellcheck disable=SC2034  # read by the suites that source this file
OBS_ALERTS=(FabricLinkDown BGPSessionDown EvpnRoutesLost ReconciliationFailed ReverificationStalled
  DeviceTelemetryTargetDown DeviceSubscriptionStalled OtlpExportFailing OtlpDataPointsRejected DuplicateDeviceSeries)
declare -A OBS_SCALE_SAVED=()

# ================================================================== pure

obs::alert_state_from_json() {
  jq -r --arg n "$1" '[.data.alerts[]? | select(.labels.alertname == $n) | .state] as $s
    | if ($s | index("firing")) then "firing" elif ($s | index("pending")) then "pending" else "inactive" end'
}

obs::rule_query_from_json() {
  jq -r --arg n "$1" '[.data.groups[]?.rules[]? | select(.name == $n) | .query] | first // empty'
}

obs::dashboard_uid_from_json() {
  jq -r --arg x "$1" '[.[]? | select(.type == "dash-db" or .type == null)
    | select((.uid // "" | test($x; "i")) or (.title // "" | test($x; "i"))) | .uid] | first // empty'
}

obs::dashboard_queries() {
  local value="$1" var="${2:-$OBS_SERVICE_VAR}"
  jq -r --arg v "$value" --arg n "$var" '
    (.dashboard // .) as $d
    | [$d | .. | objects | select(has("targets") and (.targets | type) == "array") | . as $p
        | $p.targets[] | select((.hide // false) | not) | select((.expr // "") != "")
        | {t: ($p.title // ""), e: .expr}]
    | .[]
    | .e |= ( gsub("\\$\\{" + $n + "(:[a-z]+)?\\}"; $v) | gsub("\\[\\[" + $n + "\\]\\]"; $v) | gsub("\\$" + $n + "\\b"; $v)
              | gsub("\\$__rate_interval|\\$\\{__rate_interval\\}"; "1m") | gsub("\\$__interval|\\$\\{__interval\\}"; "30s")
              | gsub("\\$__range|\\$\\{__range\\}"; "5m") | gsub("\\s+"; " ") )
    | "\(.t | gsub("\t"; " "))\t\(.e)"'
}

obs::service_networks() {
  jq -r '.items[]? | select(((.spec.bridgeDomains // []) | length) > 0 or ((.spec.routers // []) | length) > 0)
    | "\(.metadata.namespace)/\(.metadata.name)"'
}

obs::spanning_networks() {
  jq -r --args '$ARGS.positional as $leaves | .items[]?
    | select(((.spec.bridgeDomains // []) | length) > 0 or ((.spec.routers // []) | length) > 0)
    | select([(.spec.attachments // [])[].node] as $n | $leaves | all(. as $l | $n | index($l)))
    | "\(.metadata.namespace)/\(.metadata.name)"' "$@"
}

obs::normalize_iface() {
  if [[ "$1" =~ ^ethernet-([0-9]+)/([0-9]+)$ ]]; then printf 'e%s-%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else printf '%s' "$1"; fi
}

obs::clab_nodes() {
  # shellcheck disable=SC2016  # a yq program
  yq -r '(.topology.defaults.kind // "") as $dk | .topology.nodes | to_entries[]
    | .key + " " + (.value.kind // $dk) + " " + (.value.labels["agentic-netops.io/role"] // "none")' "$1"
}

obs::clab_device_links() {
  local file="$1" a ai b bi
  local -A kind=()
  local n k
  while read -r n k _; do kind[$n]="$k"; done < <(obs::clab_nodes "$file")
  while read -r a ai b bi; do
    [[ "${kind[$a]:-}" == nokia_srlinux && "${kind[$b]:-}" == nokia_srlinux ]] || continue
    printf '%s %s %s %s\n' "$a" "$(obs::normalize_iface "$ai")" "$b" "$(obs::normalize_iface "$bi")"
    printf '%s %s %s %s\n' "$b" "$(obs::normalize_iface "$bi")" "$a" "$(obs::normalize_iface "$ai")"
  done < <(yq -r '.topology.links[]?.endpoints | select(length == 2) | map(sub(":"; " ")) | join(" ")' "$file") | LC_ALL=C sort -u
}

# obs::clab_device_endpoints <file> — "<node> <normalized iface>" for the SR Linux side of EVERY link
# (device↔device and device↔client): what the generated drawing shows, clients' own ports excluded
obs::clab_device_endpoints() {
  local file="$1" a ai b bi
  local -A kind=()
  local n k
  while read -r n k _; do kind[$n]="$k"; done < <(obs::clab_nodes "$file")
  while read -r a ai b bi; do
    [[ "${kind[$a]:-}" == nokia_srlinux ]] && printf '%s %s\n' "$a" "$(obs::normalize_iface "$ai")"
    [[ "${kind[$b]:-}" == nokia_srlinux ]] && printf '%s %s\n' "$b" "$(obs::normalize_iface "$bi")"
    true
  done < <(yq -r '.topology.links[]?.endpoints | select(length == 2) | map(sub(":"; " ")) | join(" ")' "$file") | LC_ALL=C sort -u
}

obs::vector_pairs() {
  jq -r --arg a "$1" --arg b "$2" '.[]? | "\(.metric[$a] // "") \(.metric[$b] // "")"' | LC_ALL=C sort -u
}

# ================================================================== Prometheus

obs::prom_get() { lab::kubectl get --raw "${OBS_PROM_PROXY}$1"; }

obs::_uri() { jq -rn --arg q "$1" '$q | @uri'; }

obs::prom_query() {
  local out
  out="$(obs::prom_get "/api/v1/query?query=$(obs::_uri "$1")" 2>/dev/null)" || return 1
  jq -e '.status == "success"' >/dev/null 2>&1 <<<"$out" || return 1
  printf '%s\n' "$out"
}

obs::prom_vector() { local o; o="$(obs::prom_query "$1")" || return 1; jq -c '.data.result' <<<"$o"; }
obs::prom_count()  { local v; v="$(obs::prom_vector "$1")" || return 1; jq 'length' <<<"$v"; }

obs::prom_range() {
  local out
  out="$(obs::prom_get "/api/v1/query_range?query=$(obs::_uri "$1")&start=$2&end=$3&step=$4" 2>/dev/null)" || return 1
  jq -e '.status == "success"' >/dev/null 2>&1 <<<"$out" || return 1
  jq -c '.data.result' <<<"$out"
}

obs::alert_state() {
  local out
  out="$(obs::prom_get /api/v1/alerts 2>/dev/null)" || return 1
  obs::alert_state_from_json "$1" <<<"$out"
}

obs::rule_query() {
  local out
  out="$(obs::prom_get /api/v1/rules 2>/dev/null)" || return 1
  obs::rule_query_from_json "$1" <<<"$out"
}

# obs::wait_alert <name> <firing|inactive> <timeout_s> — polls /api/v1/alerts; OBS_MET_AT is the
# epoch the state was first read, OBS_WAITED the seconds it took. "inactive" means neither firing
# nor pending. rc 1 on timeout (the last state printed).
obs::wait_alert() {
  local name="$1" want="$2" timeout="$3" t0 st="unread"
  t0="$(date +%s)"; OBS_MET_AT=""; OBS_WAITED=""
  while :; do
    st="$(obs::alert_state "$name" 2>/dev/null)" || st="unreadable"
    if [[ "$st" == "$want" ]]; then
      OBS_MET_AT="$(date +%s)"; OBS_WAITED=$((OBS_MET_AT - t0))
      echo "alert ${name} ${want} after ${OBS_WAITED}s"
      return 0
    fi
    (( $(date +%s) - t0 >= timeout )) && break
    sleep "$OBS_POLL"
  done
  echo "alert ${name} not ${want} within ${timeout}s (last state: ${st})"
  return 1
}

# ================================================================== Grafana

# obs::_grafana_creds — the administrator of monitoring/grafana-admin into the environment (never echoed)
obs::_grafana_creds() {
  [[ -n "${OBS_GF_USER:-}" && -n "${OBS_GF_PASS:-}" ]] && return 0
  local j
  j="$(lab::kubectl -n "$OBS_NS" get secret grafana-admin -o json 2>/dev/null)" || { echo "secret ${OBS_NS}/grafana-admin unreadable" >&2; return 1; }
  OBS_GF_USER="$(jq -r '.data["admin-user"] // empty' <<<"$j" | base64 -d)"
  OBS_GF_PASS="$(jq -r '.data["admin-password"] // empty' <<<"$j" | base64 -d)"
  [[ -n "$OBS_GF_USER" && -n "$OBS_GF_PASS" ]] || { echo "secret ${OBS_NS}/grafana-admin lacks admin-user/admin-password" >&2; return 1; }
}

# The Grafana port-forward. obs::grafana_api is called from inside $(…) (obs::dashboard, the
# suites' dashboard readers), so the forward is started in a subshell: its PID is kept in a file
# keyed on the top-level shell ($$ — the same in every subshell), reused while it answers, and
# stopped by obs::grafana_stop, registered on the suite's exit trap when this file is sourced.
# lab::port_forward gives it no descriptor of the caller's (stdin /dev/null, output to a log,
# every other fd closed) and makes the PID kubectl's own.
OBS_GF_PF_REG="${OBS_GF_PF_REG:-${TMPDIR:-/tmp}/obs-grafana-pf.$$.pids}"
OBS_GF_PF_LOG="${OBS_GF_PF_LOG:-${TMPDIR:-/tmp}/obs-grafana-pf.$$.log}"

obs::grafana_stop() {
  lab::port_forward_stop "$OBS_GF_PF_REG"
  rm -f "$OBS_GF_PF_LOG"
}
declare -F suite::on_exit >/dev/null && suite::on_exit obs::grafana_stop

obs::_grafana_answers() { curl -s -o /dev/null --max-time 5 "http://127.0.0.1:${OBS_GF_PORT}/api/health"; }

obs::_grafana_forward() {
  local pid i
  pid="$(tail -n1 "$OBS_GF_PF_REG" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && obs::_grafana_answers; then return 0; fi
  lab::port_forward_stop "$OBS_GF_PF_REG"
  lab::port_forward "$OBS_GF_PF_REG" "$OBS_GF_PF_LOG" -n "$OBS_NS" svc/grafana "${OBS_GF_PORT}:3000"
  for i in $(seq 1 30); do
    obs::_grafana_answers && return 0
    kill -0 "$LAB_PF_PID" 2>/dev/null || break
    sleep 1
  done
  echo "the Grafana port-forward on 127.0.0.1:${OBS_GF_PORT} did not answer: $(tail -2 "$OBS_GF_PF_LOG" 2>/dev/null)" >&2
  lab::port_forward_stop "$OBS_GF_PF_REG"
  return 1
}

# obs::_curl_cfg — a curl config carrying the credential (fed through a file descriptor, so it is
# never in any argv, and so never in an evidence record's command line)
obs::_curl_cfg() {
  local u="${OBS_GF_USER//\\/\\\\}" p="${OBS_GF_PASS//\\/\\\\}"
  u="${u//\"/\\\"}"; p="${p//\"/\\\"}"
  printf 'user = "%s:%s"\n' "$u" "$p"
}

obs::grafana_api() {
  obs::_grafana_creds || return 1
  obs::_grafana_forward || return 1
  curl -sS -f -K <(obs::_curl_cfg) "http://127.0.0.1:${OBS_GF_PORT}/api/${1#/}"
}

# obs::dashboard <regex> — the provisioned dashboard (the /api/dashboards/uid response) whose uid or title matches
obs::dashboard() {
  local uid
  uid="$(obs::grafana_api "search?type=dash-db" | obs::dashboard_uid_from_json "$1")" || return 1
  [[ -n "$uid" ]] || { echo "no provisioned dashboard matches /$1/" >&2; return 1; }
  obs::grafana_api "dashboards/uid/${uid}"
}

# ================================================================== workloads

obs::replicas() { lab::kubectl -n "$1" get deploy "$2" -o jsonpath='{.spec.replicas}'; }

obs::scale() {
  local ns="$1" d="$2" n="$3" key="$1/$2"
  if [[ -z "${OBS_SCALE_SAVED[$key]:-}" ]]; then
    OBS_SCALE_SAVED[$key]="$(obs::replicas "$ns" "$d")" || return 1
    declare -F suite::on_exit >/dev/null && suite::on_exit obs::scale_restore "$ns" "$d"
  fi
  gate::run "OBS.scale.${d}.${n}" -- lab::kubectl -n "$ns" scale "deploy/$d" --replicas="$n" >/dev/null
}

obs::scale_restore() {
  local ns="$1" d="$2" key="$1/$2"
  [[ -n "${OBS_SCALE_SAVED[$key]:-}" ]] || return 0
  gate::run "OBS.scale-restore.${d}" -- lab::kubectl -n "$ns" scale "deploy/$d" --replicas="${OBS_SCALE_SAVED[$key]}" >/dev/null || return 1
  gate::run "OBS.rollout.${d}" -- lab::kubectl -n "$ns" rollout status "deploy/$d" --timeout="${SUITE_ROLLOUT_WAIT:-300}s" >/dev/null || return 1
  unset "OBS_SCALE_SAVED[$key]"
  log::info "deploy/$d in $ns scaled back and rolled out (read back)"
}

# ================================================================== checks (in-process, one SUMMARY line each)

obs::check() {
  local id="$1" check="$2"; shift 2
  local ro=()
  [[ "${1:-}" == --readiness ]] && { ro=(--readiness); shift; }
  [[ "${1:-}" == -- ]] && shift
  OBS_LAST_ID="$(gate::id "$id")"
  evidence_run "$OBS_LAST_ID" --check "$check" "${ro[@]}" -- "$@"
}

obs::neg() {
  local check="$1" rc=0; shift
  evidence_negative_control "$check" -- "$@" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) log::info "[negative-control] $check failed as it must" ;;
    4) log::error "[negative-control] $check PASSED on a system without what it checks — no pass of it will be admitted" ;;
    *) log::error "[negative-control] $check could not be recorded (rc=$rc)" ;;
  esac
  return "$rc"
}

# obs::chk_alert <name> <firing|inactive> <timeout_s>
obs::chk_alert() {
  local rc=0
  obs::wait_alert "$@" || rc=$?
  jq -cn --arg a "$1" --arg w "$2" --arg m "${OBS_MET_AT:-}" --arg s "${OBS_WAITED:-}" --argjson ok "$([[ $rc -eq 0 ]] && echo true || echo false)" \
    '{alert: $a, wanted: $w, met: $ok, met_at: (if $m == "" then null else ($m | tonumber) end), waited_seconds: (if $s == "" then null else ($s | tonumber) end)}' \
    | sed 's/^/SUMMARY /'
  return "$rc"
}

# obs::chk_targets_up <job…> — every job has at least one active target and every one of them is up
obs::chk_targets_up() {
  local out j bad=0 line
  out="$(obs::prom_get '/api/v1/targets?state=active' 2>/dev/null)" || { echo "FAIL /api/v1/targets unreadable"; return 1; }
  for j in "$@"; do
    line="$(jq -r --arg j "$j" '[.data.activeTargets[]? | select(.labels.job == $j)] as $t
      | "\($t | length) \([$t[] | select(.health == "up")] | length) \([$t[] | select(.health != "up") | "\(.scrapeUrl) \(.lastError)"] | join("; "))"' <<<"$out")"
    read -r total up rest <<<"$line"
    if [[ "$total" -gt 0 && "$total" == "$up" ]]; then echo "PASS job ${j}: ${up}/${total} target(s) up"
    else echo "FAIL job ${j}: ${up}/${total} target(s) up ${rest}"; bad=1; fi
  done
  jq -c '[.data.activeTargets[]? | {job: .labels.job, instance: .labels.instance, health}]' <<<"$out" | sed 's/^/SUMMARY /'
  return "$bad"
}

# obs::chk_sources <promql> <source…> — the query's result carries a series of every given source
obs::chk_sources() {
  local q="$1" v s bad=0; shift
  v="$(obs::prom_vector "count by (source) ($q)")" || { echo "FAIL query unreadable: $q"; return 1; }
  for s in "$@"; do
    if jq -e --arg s "$s" 'any(.[]; .metric.source == $s)' >/dev/null <<<"$v"; then echo "PASS source ${s} present"
    else echo "FAIL source ${s} absent from ${q}"; bad=1; fi
  done
  jq -c '{sources: [.[].metric.source]}' <<<"$v" | sed 's/^/SUMMARY /'
  return "$bad"
}

# obs::chk_empty <promql> — the query returns no series (and could be evaluated)
obs::chk_empty() {
  local v
  v="$(obs::prom_vector "$1")" || { echo "FAIL query unreadable: $1"; return 1; }
  jq -c --arg q "$1" '{query: $q, series: length, sample: .[0:5]}' <<<"$v" | sed 's/^/SUMMARY /'
  [[ "$(jq length <<<"$v")" -eq 0 ]]
}

# obs::chk_absent_within <promql> <timeout_s> — the query reads EMPTY (absent, not a last value) in the bound
obs::chk_absent_within() {
  local q="$1" timeout="$2" t0 v="[]" n
  t0="$(date +%s)"
  while :; do
    v="$(obs::prom_vector "$q")" || v="unreadable"
    if [[ "$v" != unreadable ]] && [[ "$(jq length <<<"$v")" -eq 0 ]]; then
      n=$(( $(date +%s) - t0 ))
      echo "PASS ${q} absent after ${n}s"
      jq -cn --arg q "$q" --argjson n "$n" '{query: $q, absent_after_seconds: $n}' | sed 's/^/SUMMARY /'
      return 0
    fi
    (( $(date +%s) - t0 >= timeout )) && break
    sleep "$OBS_POLL"
  done
  echo "FAIL ${q} still reads ${v} after ${timeout}s"
  jq -cn --arg q "$q" --arg v "$v" '{query: $q, absent_after_seconds: null, last: $v}' | sed 's/^/SUMMARY /'
  return 1
}

# obs::chk_present_within <promql> <timeout_s> — the query returns at least one series in the bound
obs::chk_present_within() {
  local q="$1" timeout="$2" t0 n=0
  t0="$(date +%s)"
  while :; do
    n="$(obs::prom_count "$q" 2>/dev/null)" || n=0
    if [[ "$n" -gt 0 ]]; then
      echo "PASS ${q} present (${n} series) after $(( $(date +%s) - t0 ))s"
      jq -cn --arg q "$q" --argjson n "$n" '{query: $q, series: $n}' | sed 's/^/SUMMARY /'
      return 0
    fi
    (( $(date +%s) - t0 >= timeout )) && break
    sleep "$OBS_POLL"
  done
  echo "FAIL ${q} returned no series within ${timeout}s"
  jq -cn --arg q "$q" '{query: $q, series: 0}' | sed 's/^/SUMMARY /'
  return 1
}

# obs::chk_fabric_ready <ns> <fabric> <timeout_s> — Ready=True read back
obs::chk_fabric_ready() {
  local t0 st=""
  t0="$(date +%s)"
  while :; do
    st="$(lab::kubectl -n "$1" get fabrics.fabric.agentic-netops.io "$2" -o json 2>/dev/null \
      | jq -r '[(.status.conditions // [])[] | select(.type == "Ready")] | first | "\(.status // "?")/\(.reason // "?")"')" || st="unreadable"
    [[ "$st" == True/* ]] && { echo "PASS Fabric $1/$2 Ready=${st}"; echo "SUMMARY {\"ready\":\"${st}\"}"; return 0; }
    (( $(date +%s) - t0 >= $3 )) && break
    sleep "$OBS_POLL"
  done
  echo "FAIL Fabric $1/$2 Ready=${st} after $3s"; echo "SUMMARY {\"ready\":\"${st}\"}"
  return 1
}

# obs::chk_fabric_ready_hold <ns> <fabric> <hold_s> — Ready=True at EVERY poll for hold_s
obs::chk_fabric_ready_hold() {
  local t0 st polls=0
  t0="$(date +%s)"
  while (( $(date +%s) - t0 < $3 )); do
    st="$(lab::kubectl -n "$1" get fabrics.fabric.agentic-netops.io "$2" -o json 2>/dev/null \
      | jq -r '[(.status.conditions // [])[] | select(.type == "Ready")] | first | "\(.status // "?")/\(.reason // "?")"')" || st="unreadable"
    polls=$((polls + 1))
    [[ "$st" == True/* ]] || { echo "FAIL Fabric $1/$2 Ready=${st} at poll ${polls}"; echo "SUMMARY {\"held\":false,\"polls\":${polls}}"; return 1; }
    sleep "$OBS_POLL"
  done
  echo "PASS Fabric $1/$2 Ready=True at every one of ${polls} polls over $3s"; echo "SUMMARY {\"held\":true,\"polls\":${polls}}"
  [[ "$polls" -gt 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "tests/integration/lib/obs.sh is a library: source it (tests/integration/{observability_verify,alerts_fire,topology_parity}.sh)" >&2
  exit 2
fi
