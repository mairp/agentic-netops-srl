#!/usr/bin/env bash
# audit_export.sh — the audit record's export and the usernames record (T088, shared with T049;
# FR-078, NFR-013, SC-040, SC-042, AD-24, AD-36, AD-45, AD-46, AD-55, AD-59, AD-64;
# data-model.md §16, §22, §25).
#
# The audit events live as span events in the agent-analytics store (ClickHouse, StatefulSet
# `clickhouse` in agentic-netops-agents). That stored event IS the record, so it is exported
# before anything removes the store — by `off.sh` and by `off.sh --purge-intent-tier` alike — and a
# failed export stops the removal with the store intact (only --discard-audit-record, off.sh's,
# goes past it).
#
#   audit_export::export [cluster]
#       1. the usernames record (audit_export::usernames_record) — before anything removes the
#          operator-credentials Secret;
#       2. absent store (no StatefulSet) → skipped, success;
#       3. the store is asked — bounded as a whole by AUDIT_EXPORT_TIMEOUT_SECONDS — first until it
#          answers `SELECT 1` (never answering within the bound is the failed export "present but
#          unqueryable"), then for its trace tables and, per table, its row count and newest row
#          timestamp;
#       4. the ONE re-run rule of data-model.md §16: when the lab's evidence root (and an
#          operator-set EVIDENCE_DIR) holds a VERIFIED export — exit status 0, rows written equal to
#          the store's count recorded beside the newest row's timestamp, content hash intact, and the
#          store reporting that same count AND that same newest-row timestamp now — the export is
#          SKIPPED and the skip captured through evidence_run (audit-export-skip-<attempt>) naming
#          the artefact relied on; otherwise
#       5. an export is ADDED under a new attempt identifier, through evidence_run:
#            <EVIDENCE_DIR>/audit-export-<attempt>.ndjson.gz   one JSON object per stored row, gzip
#            <EVIDENCE_DIR>/audit-export-<attempt>.json        its evidence record (NFR-013 fields,
#                                                              the artefact's sha256 as attachment)
#            <EVIDENCE_DIR>/audit-export-<attempt>.stdout      {store_rows, rows_written,
#                                                              newest_row_timestamp, tables, …}
#          failing on a query error, an unwritable artefact or fewer rows written than the store
#          reported; an empty store is a successful empty export (newest_row_timestamp null).
#          Nothing is ever rewritten: an existing artefact path refuses the write.
#   audit_export::usernames_record [attempt]
#       Captures operator-credentials' `username` — never `password` — through evidence_run
#       (operator-username-<attempt>), then writes operator-usernames-<attempt>: the distinct
#       usernames over every username capture of THIS lab (cluster and lab identity equal, record
#       and output hashes intact) found under the lab's evidence root, and username_unchanged —
#       true exactly when that set has one member. No Secret → nothing to capture, no record.
#   audit_export::find_verified <rows> <newest|null>   prints the verified artefact's path, or fails
#   audit_export::settings                             prints the effective settings (KEY=VALUE)
#
# Credentials: the store is asked from INSIDE its pod (`kubectl exec clickhouse-0 -c clickhouse`;
# the NetworkPolicy admits only the collector over the network), and clickhouse-client takes the
# user and password from the container's own environment — CLICKHOUSE_USER / CLICKHOUSE_PASSWORD,
# secretKeyRefs of the generated clickhouse-auth Secret, resolved by the kubelet at run time — so the
# password is never read onto the host, never in a host argv, a log line or an evidence file (the
# access proven live by T087, phase6/clickhouse-live.md). The one function that talks to the store is
# audit_export::_query (the tests' fake store answers behind a fake kubectl exec).
#
# Settings (environment; defaults):
#   AUDIT_EXPORT_TIMEOUT_SECONDS 120 (data-model.md §25)   AUDIT_EXPORT_POLL_SECONDS 2
#   AUDIT_STORE_NAMESPACE agentic-netops-agents   AUDIT_STORE_STATEFULSET clickhouse
#   AUDIT_STORE_POD <statefulset>-0   AUDIT_STORE_CONTAINER clickhouse
#   AUDIT_EXPORT_DATABASE otel   AUDIT_EXPORT_TABLE_PREFIX otel_traces (every non-view table of the
#   database whose name starts with it AND that has the timestamp column — the span tables; the
#   exporter's trace-id lookup table otel_traces_trace_id_ts carries no audit row and no Timestamp)
#   or AUDIT_EXPORT_TABLES (an explicit space-separated list)
#   AUDIT_EXPORT_TS_COLUMN Timestamp (the newest-row column; maxOrNull — NULL for an empty table)
#   AUDIT_EXPORT_ORDER_BY "<ts column>, TraceId, SpanId" (a stable row order for the artefact)
#   AUDIT_EXPORT_ATTEMPT (tests only: a fixed attempt identifier)
#   CLUSTER_NAME / LAB_NAME / EVIDENCE_ROOT / EVIDENCE_DIR as scripts/lib/evidence.sh; KUBECTL.
#
# Command form: audit_export.sh export [cluster] | usernames | settings
#   `export` is the stand-alone invocation (T103 runs it with the tier up): it writes the export
#   and the usernames record and removes nothing.
# Exit: 0 exported / skipped / nothing to export; 1 the export failed (named); 2 usage/settings.

[[ -n "${__AGENTIC_NETOPS_AUDIT_EXPORT_SH:-}" ]] && return 0
__AGENTIC_NETOPS_AUDIT_EXPORT_SH=1

AUDIT_EXPORT_LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=log.sh
source "$AUDIT_EXPORT_LIB/log.sh"
# shellcheck source=evidence.sh
source "$AUDIT_EXPORT_LIB/evidence.sh"
# shellcheck source=intent_secrets.sh
source "$AUDIT_EXPORT_LIB/intent_secrets.sh"

# an operator-set EVIDENCE_DIR (set before anything of this process chose one) is searched too
AUDIT_EXPORT_OPERATOR_EVIDENCE_DIR="${EVIDENCE_DIR:-}"

audit_export::defaults() {
  : "${AUDIT_EXPORT_TIMEOUT_SECONDS:=120}"
  : "${AUDIT_EXPORT_POLL_SECONDS:=2}"
  : "${AUDIT_STORE_NAMESPACE:=agentic-netops-agents}"
  : "${AUDIT_STORE_STATEFULSET:=clickhouse}"
  : "${AUDIT_STORE_POD:=${AUDIT_STORE_STATEFULSET}-0}"
  : "${AUDIT_STORE_CONTAINER:=clickhouse}"
  : "${AUDIT_EXPORT_DATABASE:=otel}"
  : "${AUDIT_EXPORT_TABLE_PREFIX:=otel_traces}"
  : "${AUDIT_EXPORT_TABLES:=}"
  : "${AUDIT_EXPORT_TS_COLUMN:=Timestamp}"
  : "${AUDIT_EXPORT_ORDER_BY:=\`${AUDIT_EXPORT_TS_COLUMN}\`, \`TraceId\`, \`SpanId\`}"
  local v
  for v in AUDIT_EXPORT_TIMEOUT_SECONDS AUDIT_EXPORT_POLL_SECONDS; do
    if [[ ! "${!v}" =~ ^[0-9]+$ ]] || [[ "${!v}" -le 0 ]]; then
      log::error "audit export: ${v} must be a positive number of seconds, got '${!v}'"
      return 2
    fi
  done
  for v in AUDIT_EXPORT_DATABASE AUDIT_EXPORT_TABLE_PREFIX AUDIT_EXPORT_TS_COLUMN; do
    [[ "${!v}" =~ ^[A-Za-z0-9_]+$ ]] || { log::error "audit export: ${v} '${!v}' is not a plain identifier"; return 2; }
  done
}

audit_export::settings() {
  audit_export::defaults || return 2
  local v
  for v in AUDIT_EXPORT_TIMEOUT_SECONDS AUDIT_EXPORT_POLL_SECONDS AUDIT_STORE_NAMESPACE AUDIT_STORE_STATEFULSET \
    AUDIT_STORE_POD AUDIT_STORE_CONTAINER AUDIT_EXPORT_DATABASE AUDIT_EXPORT_TABLE_PREFIX \
    AUDIT_EXPORT_TABLES AUDIT_EXPORT_TS_COLUMN AUDIT_EXPORT_ORDER_BY; do
    printf '%s=%s\n' "$v" "${!v}"
  done
}

audit_export::_ctx() { printf '%s' "${KUBE_CONTEXT:-kind-${CLUSTER_NAME:-agentic-netops}}"; }
audit_export::_k() { "${KUBECTL:-kubectl}" --context "$(audit_export::_ctx)" "$@"; }

# audit_export::attempt_id — unique to the attempt: UTC time + random suffix
audit_export::attempt_id() {
  if [[ -n "${AUDIT_EXPORT_ATTEMPT:-}" ]]; then printf '%s' "$AUDIT_EXPORT_ATTEMPT"; return 0; fi
  printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
}

# audit_export::lab_root — .evidence/<cluster>_<lab>/ (EVIDENCE_ROOT overrides .evidence)
audit_export::lab_root() {
  local lab
  lab="$(evidence::lab_name)" || return 1
  printf '%s/%s_%s' "${EVIDENCE_ROOT:-$EVIDENCE_REPO_ROOT/.evidence}" "$(evidence::cluster_name)" "$lab"
}

# audit_export::_search_dirs — the lab's evidence root, an operator-set EVIDENCE_DIR, this run's
audit_export::_search_dirs() {
  local d
  for d in "$(audit_export::lab_root 2>/dev/null)" "$AUDIT_EXPORT_OPERATOR_EVIDENCE_DIR" "${EVIDENCE_DIR:-}"; do
    if [[ -n "$d" && -d "$d" ]]; then printf '%s\n' "$d"; fi
  done
  return 0
}

# audit_export::_record_intact <record.json> — record_sha256 and stdout hash intact, this lab's identity
audit_export::_record_intact() {
  local rec="$1" dir want got out
  dir="$(dirname "$rec")"
  jq -e --arg c "$(evidence::cluster_name)" --arg l "$(evidence::lab_name)" \
    '.kind == "run" and .exit_status == 0 and .cluster.name == $c and .lab.name == $l' "$rec" >/dev/null 2>&1 || return 1
  want="$(jq -r '.record_sha256 // ""' "$rec")"
  got="$(printf '%s' "$(jq -S -c 'del(.record_sha256)' "$rec")" | sha256sum | awk '{print $1}')"
  [[ -n "$want" && "$want" == "$got" ]] || return 1
  out="$dir/$(jq -r '.raw_output.stdout.file' "$rec")"
  [[ -f "$out" && "$(sha256sum "$out" | awk '{print $1}')" == "$(jq -r '.raw_output.stdout.sha256' "$rec")" ]]
}

# ------------------------------------------------------------------ the store
audit_export::store_present() {
  audit_export::_k get statefulset "$AUDIT_STORE_STATEFULSET" -n "$AUDIT_STORE_NAMESPACE" -o name >/dev/null 2>&1
}

# audit_export::_query <timeout_s> <sql> — THE one call to the store: clickhouse-client inside the
# store's pod, credentials from the container's env (never the host's). stdout = the answer;
# exit 124 = the bound elapsed.
audit_export::_query() {
  local t="$1" sql="$2"
  local -a c=()
  [[ -n "$AUDIT_STORE_CONTAINER" ]] && c=(-c "$AUDIT_STORE_CONTAINER")
  # shellcheck disable=SC2016 # expanded by the pod's shell, not this one
  timeout --kill-after=2 "$t" "${KUBECTL:-kubectl}" --context "$(audit_export::_ctx)" \
    exec -n "$AUDIT_STORE_NAMESPACE" "${c[@]}" "$AUDIT_STORE_POD" -- bash -c \
    'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "$0"' \
    "$sql" </dev/null
}

AE_DEADLINE=0
audit_export::_left() { local l=$(( AE_DEADLINE - $(date +%s) )); (( l > 0 )) || l=0; printf '%s' "$l"; }

# audit_export::_probe — until the store answers SELECT 1, within the bound
audit_export::_probe() {
  local left ans err
  err="$(mktemp)"
  while :; do
    left="$(audit_export::_left)"
    [[ "$left" -gt 0 ]] || break
    ans="$(audit_export::_query "$left" "SELECT 1" 2>"$err")" && [[ "$(tr -d '[:space:]' <<<"$ans")" == 1 ]] && { rm -f "$err"; return 0; }
    left="$(audit_export::_left)"
    [[ "$left" -gt 0 ]] || break
    sleep "$(( AUDIT_EXPORT_POLL_SECONDS < left ? AUDIT_EXPORT_POLL_SECONDS : left ))"
  done
  log::error "audit export FAILED: the analytics store ${AUDIT_STORE_NAMESPACE}/${AUDIT_STORE_STATEFULSET} is present but unqueryable" \
    "within AUDIT_EXPORT_TIMEOUT_SECONDS=${AUDIT_EXPORT_TIMEOUT_SECONDS} s${err:+ (last error: $(tail -n 1 "$err" 2>/dev/null))}"
  rm -f "$err"
  return 1
}

# audit_export::_q <what> <sql> — a bounded query; a failure is a query error, or the bound
audit_export::_q() {
  local what="$1" sql="$2" left rc=0 out err
  left="$(audit_export::_left)"
  if [[ "$left" -le 0 ]]; then
    log::error "audit export FAILED: AUDIT_EXPORT_TIMEOUT_SECONDS=${AUDIT_EXPORT_TIMEOUT_SECONDS} s elapsed before ${what}"
    return 1
  fi
  err="$(mktemp)"
  out="$(audit_export::_query "$left" "$sql" 2>"$err")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
      log::error "audit export FAILED: ${what} did not answer within AUDIT_EXPORT_TIMEOUT_SECONDS=${AUDIT_EXPORT_TIMEOUT_SECONDS} s"
    else
      log::error "audit export FAILED: query error on ${what} (exit ${rc}): $(tail -n 1 "$err")"
    fi
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  printf '%s\n' "$out"
}

AE_TABLES=() AE_ROWS=0 AE_NEWEST="null"
# audit_export::_inspect — AE_TABLES, AE_ROWS, AE_NEWEST (JSON string or null) from the store
audit_export::_inspect() {
  local t out n ts
  AE_TABLES=() AE_ROWS=0 AE_NEWEST="null"
  if [[ -n "$AUDIT_EXPORT_TABLES" ]]; then
    read -r -a AE_TABLES <<<"$AUDIT_EXPORT_TABLES"
  else
    out="$(audit_export::_q "the table list" "SELECT name FROM system.tables WHERE database = '${AUDIT_EXPORT_DATABASE}' AND startsWith(name, '${AUDIT_EXPORT_TABLE_PREFIX}') AND engine NOT LIKE '%View' AND name IN (SELECT table FROM system.columns WHERE database = '${AUDIT_EXPORT_DATABASE}' AND name = '${AUDIT_EXPORT_TS_COLUMN}') ORDER BY name FORMAT TSV")" || return 1
    while IFS= read -r t; do [[ -n "$t" ]] && AE_TABLES+=("$t"); done <<<"$out"
  fi
  local newest=""
  for t in "${AE_TABLES[@]}"; do
    [[ "$t" =~ ^[A-Za-z0-9_]+$ ]] || { log::error "audit export FAILED: table name '$t' is not a plain identifier"; return 1; }
    out="$(audit_export::_q "the row count of ${AUDIT_EXPORT_DATABASE}.${t}" \
      "SELECT count(), maxOrNull(\`${AUDIT_EXPORT_TS_COLUMN}\`) FROM \`${AUDIT_EXPORT_DATABASE}\`.\`${t}\` FORMAT TSV")" || return 1
    IFS=$'\t' read -r n ts <<<"$(head -n 1 <<<"$out")"
    [[ "$n" =~ ^[0-9]+$ ]] || { log::error "audit export FAILED: query error: ${AUDIT_EXPORT_DATABASE}.${t} returned no row count ('${out:0:80}')"; return 1; }
    AE_ROWS=$(( AE_ROWS + n ))
    if [[ "$n" -gt 0 && -n "$ts" && "$ts" != '\N' && ( -z "$newest" || "$ts" > "$newest" ) ]]; then newest="$ts"; fi
  done
  [[ -n "$newest" ]] && AE_NEWEST="$(jq -cn --arg t "$newest" '$t')"
  return 0
}

# audit_export::_write <attempt> — the command evidence_run runs: writes the artefact, prints the
# summary (the record's stdout). Uses AE_TABLES / AE_ROWS / AE_NEWEST from _inspect.
audit_export::_write() {
  local attempt="$1" name final partial t written
  name="audit-export-${attempt}.ndjson.gz"
  final="$EVIDENCE_DIR/$name"
  partial="$(dirname "$final")/.${name}.partial"
  if [[ -e "$final" ]]; then
    echo "audit export: cannot write the artefact ${final}: the path exists — evidence is never rewritten" >&2
    return 1
  fi
  if ! : >"$partial" 2>/dev/null; then
    echo "audit export: cannot write the artefact in ${EVIDENCE_DIR} (not writable)" >&2
    return 1
  fi
  for t in "${AE_TABLES[@]}"; do
    local left
    left="$(audit_export::_left)"
    if [[ "$left" -le 0 ]]; then
      rm -f -- "$partial"
      echo "audit export: AUDIT_EXPORT_TIMEOUT_SECONDS=${AUDIT_EXPORT_TIMEOUT_SECONDS} s elapsed before ${t} was read" >&2
      return 1
    fi
    audit_export::_query "$left" \
      "SELECT * FROM \`${AUDIT_EXPORT_DATABASE}\`.\`${t}\` ORDER BY ${AUDIT_EXPORT_ORDER_BY} FORMAT JSONEachRow" \
      | gzip -c >>"$partial"
    local -a ps=("${PIPESTATUS[@]}")
    if [[ "${ps[0]}" -eq 124 || "${ps[0]}" -eq 137 ]]; then
      rm -f -- "$partial"
      echo "audit export: reading ${AUDIT_EXPORT_DATABASE}.${t} did not finish within AUDIT_EXPORT_TIMEOUT_SECONDS=${AUDIT_EXPORT_TIMEOUT_SECONDS} s" >&2
      return 1
    elif [[ "${ps[0]}" -ne 0 ]]; then
      rm -f -- "$partial"
      echo "audit export: query error reading ${AUDIT_EXPORT_DATABASE}.${t} (exit ${ps[0]})" >&2
      return 1
    elif [[ "${ps[1]}" -ne 0 ]]; then
      rm -f -- "$partial"
      echo "audit export: cannot write the artefact ${final} (gzip exit ${ps[1]})" >&2
      return 1
    fi
  done
  if ! mv -T -- "$partial" "$final" 2>/dev/null; then
    rm -f -- "$partial"
    echo "audit export: cannot write the artefact ${final}" >&2
    return 1
  fi
  written="$(gzip -dc "$final" | grep -c . || true)"
  jq -n --arg a "$name" --arg db "$AUDIT_EXPORT_DATABASE" --arg col "$AUDIT_EXPORT_TS_COLUMN" \
    --arg store "${AUDIT_STORE_NAMESPACE}/statefulset/${AUDIT_STORE_STATEFULSET}" \
    --argjson tables "$(printf '%s\n' "${AE_TABLES[@]}" | jq -R -s -c 'split("\n") | map(select(. != ""))')" \
    --argjson rows "$AE_ROWS" --argjson written "$written" --argjson newest "$AE_NEWEST" \
    --argjson timeout "$AUDIT_EXPORT_TIMEOUT_SECONDS" \
    '{artefact: $a, store: $store, database: $db, tables: $tables, timestamp_column: $col,
      store_rows: $rows, rows_written: $written, newest_row_timestamp: $newest,
      audit_export_timeout_seconds: $timeout, format: "ndjson+gzip, one JSON object per stored row"}'
  if [[ "$written" -lt "$AE_ROWS" ]]; then
    echo "audit export: short row count — ${written} rows written, the store reported ${AE_ROWS} (fewer rows than the store holds)" >&2
    return 1
  fi
  if [[ "$written" -gt "$AE_ROWS" ]]; then
    echo "audit export: ${written} rows written, the store reported ${AE_ROWS} when counted (rows arrived meanwhile); a re-run will not treat this export as verified" >&2
  fi
}

# audit_export::find_verified <rows> <newest JSON|null> — prints the newest verified export's
# artefact path (data-model.md §16's three conditions), or returns 1
audit_export::find_verified() {
  local rows="$1" newest="$2" rec dir art want out best="" best_t=""
  while IFS= read -r rec; do
    [[ -n "$rec" ]] || continue
    audit_export::_record_intact "$rec" || continue
    dir="$(dirname "$rec")"
    out="$dir/$(jq -r '.raw_output.stdout.file' "$rec")"
    jq -e --argjson r "$rows" --argjson n "$newest" \
      '.store_rows == .rows_written and .store_rows == $r and .newest_row_timestamp == $n' "$out" >/dev/null 2>&1 || continue
    art="$(jq -r '.artefact // ""' "$out")"
    [[ -n "$art" && -f "$dir/$art" ]] || continue
    want="$(jq -r --arg a "$art" '[.attachments[]? | select(.file == $a) | .sha256][0] // ""' "$rec")"
    [[ -n "$want" && "$want" == "$(sha256sum "$dir/$art" | awk '{print $1}')" ]] || continue
    if [[ -z "$best" || "$(jq -r .utc_time "$rec")" > "$best_t" ]]; then best="$dir/$art"; best_t="$(jq -r .utc_time "$rec")"; fi
  done < <(audit_export::_search_dirs | while IFS= read -r d; do
             find "$d" -type f -name 'audit-export-*.json' ! -name 'audit-export-skip-*' 2>/dev/null
           done | sort -u)
  [[ -n "$best" ]] || return 1
  printf '%s\n' "$best"
}

# ------------------------------------------------------------------ the usernames record
# audit_export::_usernames_json — the command behind operator-usernames-<attempt>: distinct
# usernames over this lab's username captures (records named *operator-username-*), never a password
audit_export::_usernames_json() {
  local rec dir out u
  local -a names=() captures=()
  while IFS= read -r rec; do
    [[ -n "$rec" ]] || continue
    audit_export::_record_intact "$rec" || continue
    dir="$(dirname "$rec")"
    out="$dir/$(jq -r '.raw_output.stdout.file' "$rec")"
    u="$(sed -n 's/^username: //p' "$out" | head -n 1)"
    [[ -n "$u" ]] || continue
    names+=("$u"); captures+=("${rec#"$(audit_export::lab_root)"/}")
  done < <(audit_export::_search_dirs | while IFS= read -r d; do
             find "$d" -type f -name '*operator-username-*.json' 2>/dev/null
           done | sort -u)
  jq -n --arg c "$(evidence::cluster_name)" --arg l "$(evidence::lab_name)" \
    --argjson names "$(printf '%s\n' "${names[@]}" | jq -R -s -c 'split("\n") | map(select(. != "")) | unique')" \
    --argjson caps "$(printf '%s\n' "${captures[@]}" | jq -R -s -c 'split("\n") | map(select(. != ""))')" \
    '{cluster: $c, lab: $l, usernames: $names, username_unchanged: ($names | length == 1),
      captures: $caps, note: "operator-credentials usernames only — never a password (data-model.md §16, SC-042)"}'
}

audit_export::usernames_record() {
  local attempt="${1:-}" rc=0 rec
  [[ -n "$attempt" ]] || attempt="$(audit_export::attempt_id)"
  evidence::ensure_dir || return 1
  if ! intent_secrets::_exists "$INTENT_SECRETS_OPERATOR"; then
    log::info "usernames record: no ${INTENT_SECRETS_NS}/${INTENT_SECRETS_OPERATOR} Secret — nothing to capture"
    return 0
  fi
  evidence_run "operator-username-${attempt}" -- intent_secrets::username >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log::error "usernames record: capturing the operator username failed (exit ${rc}) — ${INTENT_SECRETS_OPERATOR} is not removed un-captured"
    return 1
  fi
  evidence_run "operator-usernames-${attempt}" -- audit_export::_usernames_json >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log::error "usernames record: writing operator-usernames-${attempt} failed (exit ${rc})"
    return 1
  fi
  rec="$EVIDENCE_DIR/operator-usernames-${attempt}.stdout"
  log::info "usernames record: operator-usernames-${attempt} — usernames $(jq -c .usernames "$rec"), username_unchanged $(jq -r .username_unchanged "$rec")"
}

# ------------------------------------------------------------------ the export
audit_export::export() {
  [[ -n "${1:-}" ]] && CLUSTER_NAME="$1"
  : "${CLUSTER_NAME:=agentic-netops}"
  export CLUSTER_NAME
  audit_export::defaults || return 2
  evidence::ensure_dir || { log::error "audit export: no evidence directory"; return 1; }
  export EVIDENCE_DIR
  local attempt rc=0 verified
  attempt="$(audit_export::attempt_id)"
  evidence::_valid_id "audit-export-${attempt}" || { log::error "audit export: invalid attempt identifier '${attempt}'"; return 2; }

  audit_export::usernames_record "$attempt" || return 1

  if ! audit_export::store_present; then
    log::info "audit export: no analytics store (${AUDIT_STORE_NAMESPACE}/${AUDIT_STORE_STATEFULSET}) — skipped, nothing to export"
    return 0
  fi
  log::info "audit export: store ${AUDIT_STORE_NAMESPACE}/${AUDIT_STORE_STATEFULSET}, bounded by AUDIT_EXPORT_TIMEOUT_SECONDS=${AUDIT_EXPORT_TIMEOUT_SECONDS} s"
  AE_DEADLINE=$(( $(date +%s) + AUDIT_EXPORT_TIMEOUT_SECONDS ))
  audit_export::_probe || return 1
  audit_export::_inspect || return 1
  log::info "audit export: the store reports ${AE_ROWS} row(s) in ${#AE_TABLES[@]} table(s) (${AE_TABLES[*]:-none}), newest row ${AE_NEWEST}"

  if verified="$(audit_export::find_verified "$AE_ROWS" "$AE_NEWEST")"; then
    evidence_run "audit-export-skip-${attempt}" -- printf '%s\n' \
      "audit export skipped (data-model.md §16): a verified export already holds this store's ${AE_ROWS} row(s), newest ${AE_NEWEST}" \
      "artefact relied on: ${verified}" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]]; then log::error "audit export: capturing the skip failed (exit ${rc})"; return 1; fi
    log::info "audit export: SKIPPED — ${verified} is a verified export of this store (count and newest row unchanged); the skip is recorded as audit-export-skip-${attempt}"
    return 0
  fi

  local err
  err="$(mktemp)"
  evidence_run "audit-export-${attempt}" --attach "audit-export-${attempt}.ndjson.gz" -- audit_export::_write "$attempt" >/dev/null 2>"$err" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log::error "audit export FAILED (exit ${rc}): $(grep -v '^evidence:' "$err" | tail -n 3 | tr '\n' ' ')"
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  log::info "audit export: ${AE_ROWS} row(s) written to ${EVIDENCE_DIR}/audit-export-${attempt}.ndjson.gz (record audit-export-${attempt}.json)"
}

audit_export::main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    export) audit_export::export "${1:-}" ;;
    usernames) audit_export::defaults || return 2; audit_export::usernames_record ;;
    settings) audit_export::settings ;;
    -h|--help|help) sed -n '2,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) log::error "usage: audit_export.sh export [cluster] | usernames | settings"; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  audit_export::main "$@"
fi
