#!/usr/bin/env bash
# intent_secrets.sh — the intent tier's generated Secrets (T072; FR-106, FR-102, FR-079, FR-019,
# CR-008, SC-048, AD-01, AD-49, AD-67; contracts/kubernetes-objects.md; data-model.md §22).
#
# Every Secret lives in agentic-netops-agents (INTENT_SECRETS_NAMESPACE overrides), carries the
# ownership label (scripts/lib/ownership.sh) and is refused when it exists without it. Values never
# appear in argv, logs or evidence: they travel through the environment into jq and through a pipe
# into kubectl (apply for a new Secret, a merge patch read from stdin for an existing one).
#
#   intent_secrets::llm_provider
#       `llm-provider` — keys LLM_MODEL, API_KEY, BASE_URL and, when a shared gateway is declared,
#       GATEWAY — from AGENTIC_NETOPS_LLM_{MODEL,API_KEY,BASE_URL,GATEWAY}. An input that is unset
#       OR EMPTY is absent from the run and keeps its stored value: an existing Secret is written by
#       a merge patch of the keys this run sets, never a whole-object replace (AD-01). Clearing the
#       base URL takes AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=1 exactly (anything else is not a clear);
#       together with a new base URL it is refused as contradictory. A declared gateway whose
#       effective base URL (given, else stored) is empty is REFUSED before anything is written —
#       ensure_all runs this first, so nothing of the tier exists yet (FR-106, SC-048). Prints the
#       endpoint model calls will use — the base URL through intent_secrets::redact_url, or "the
#       provider's own default" named as such.
#   intent_secrets::operator_credentials
#       `operator-credentials` — `username` (default `operator`, OPERATOR_USERNAME overrides; an
#       unset one keeps the stored name) and `password`, ALWAYS generated: OPERATOR_PASSWORD is
#       ignored (a warning, never its value), and any password argument (--password, --password-file,
#       …) is refused with nothing written. An existing password is preserved byte-identical (FR-102).
#   intent_secrets::generated <slim-gateway|clickhouse-auth>
#       `username` + a generated `password` — never a default pair (D-23); preserved on re-runs.
#   intent_secrets::ensure_all
#       The four above, llm-provider first (its refusal precedes every write).
#   intent_secrets::remove
#       Deletes the four (and the Job's transient input Secret), each only when owned; absent is
#       success. Called by scripts/off.sh with the other generated Secrets (FR-019, FR-102).
#   intent_secrets::username
#       Prints operator-credentials' username (never the password) — off.sh's evidence capture.
#   intent_secrets::redact_url <url>
#       The shell implementation of the FR-079 pattern set for an endpoint (AD-67): userinfo →
#       `***@`; a query or fragment parameter named key|api_key|apikey|token|access_token|secret|
#       password|sig|signature (any case) → `<name>=***`. The host, port and path stay visible, so
#       redaction never hides which endpoint is in use. agents/common/guards/redaction.py is the
#       tier's implementation of the same markers; T168's fixture keeps the two equal.
#   intent_secrets::scripts_configmap
#       Prints the ConfigMap `intent-secret-generator-scripts` (this file, log.sh, ownership.sh,
#       byte-for-byte) that deploy/rbac/intent-secret-generator.yaml mounts: the in-cluster Job runs
#       THIS script, so its printed lines go through the same redaction.
#   intent_secrets::input_secret
#       Prints the Job's transient input Secret `intent-secret-generator-input` holding the
#       AGENTIC_NETOPS_LLM_* inputs this run sets (unset/empty ones omitted, so the Job's optional
#       secretKeyRefs leave them absent and the merge keeps the stored values).
#
# Command form: intent_secrets.sh [ensure|llm-provider|operator-credentials|generated <name>|remove|
#                                  redact-url <url>|scripts-configmap|input-secret]
# Environment: CLUSTER_NAME (context kind-<cluster>, ownership value), KUBE_CONTEXT (overrides the
# context), KUBECTL (client), AGENTIC_NETOPS_GENERATOR_IN_CLUSTER=1 (inside the Job: no --context, the pod's
# service account, no namespace read — the Role grants Secrets only).
# Exit: 0 written/preserved; 1 refused or failed (named); 2 usage.

[[ -n "${__AGENTIC_NETOPS_INTENT_SECRETS_SH:-}" ]] && return 0
__AGENTIC_NETOPS_INTENT_SECRETS_SH=1

# shellcheck source=log.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/log.sh"
# shellcheck source=ownership.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/ownership.sh"

INTENT_SECRETS_SELF="${BASH_SOURCE[0]}"
INTENT_SECRETS_FIELD_MANAGER="agentic-netops-lifecycle"
INTENT_SECRETS_NS="${INTENT_SECRETS_NAMESPACE:-agentic-netops-agents}"
INTENT_SECRETS_LLM="llm-provider"
INTENT_SECRETS_OPERATOR="operator-credentials"
INTENT_SECRETS_SLIM="slim-gateway"
INTENT_SECRETS_CLICKHOUSE="clickhouse-auth"
INTENT_SECRETS_INPUT="intent-secret-generator-input"
INTENT_SECRETS_SCRIPTS_CM="intent-secret-generator-scripts"
# The FR-079 credential parameter names (AD-67) — one list, used by redact_url.
INTENT_SECRETS_CRED_PARAMS="key|api_key|apikey|token|access_token|secret|password|sig|signature"

# ------------------------------------------------------------------ plumbing
intent_secrets::_in_cluster() { [[ "${AGENTIC_NETOPS_GENERATOR_IN_CLUSTER:-}" == 1 ]]; }
intent_secrets::_context() {
  if intent_secrets::_in_cluster; then printf ''; else printf '%s' "${KUBE_CONTEXT:-kind-${CLUSTER_NAME:-agentic-netops}}"; fi
}
intent_secrets::_kubectl() {
  if intent_secrets::_in_cluster; then
    "${KUBECTL:-kubectl}" "$@"
  else
    "${KUBECTL:-kubectl}" --context "$(intent_secrets::_context)" "$@"
  fi
}
intent_secrets::_require_owned() { KUBE_CONTEXT="$(intent_secrets::_context)" ownership::require_k8s "$@"; }
intent_secrets::_exists() { # <name> — a Secret in the tier namespace
  intent_secrets::_kubectl get secret "$1" -n "$INTENT_SECRETS_NS" -o name >/dev/null 2>&1
}
# intent_secrets::_stored <name> — the Secret's .data (base64 values) as compact JSON; {} when absent.
# Refuses (1) a Secret that exists and is not owned.
intent_secrets::_stored() {
  local name="$1" json
  if ! intent_secrets::_exists "$name"; then printf '{}'; return 0; fi
  intent_secrets::_require_owned secret "$name" "$INTENT_SECRETS_NS" || return 1
  json="$(intent_secrets::_kubectl get secret "$name" -n "$INTENT_SECRETS_NS" -o json)" \
    || { log::error "intent_secrets: reading secret $INTENT_SECRETS_NS/$name failed"; return 1; }
  jq -c '.data // {}' <<<"$json"
}
intent_secrets::_val() { # <data-json> <key> — the decoded value, empty when absent
  jq -r --arg k "$2" '.[$k] // empty | @base64d' <<<"$1"
}

intent_secrets::_require_namespace() {
  # Inside the Job the Role grants Secrets only; the Job's own namespace exists by construction.
  intent_secrets::_in_cluster && return 0
  if ! intent_secrets::_kubectl get namespace "$INTENT_SECRETS_NS" -o name >/dev/null 2>&1; then
    log::error "intent_secrets: namespace $INTENT_SECRETS_NS (the intent tier's) does not exist: nothing was written"
    return 1
  fi
}

# intent_secrets::_refuse_password_args <args…> — FR-102: the operator password is never taken from
# a flag or a file. Any password-shaped argument refuses the whole run before anything is written.
intent_secrets::_refuse_password_args() {
  local a
  for a in "$@"; do
    case "$a" in
      --password*|--pass|--pass=*|--passwd*|--pw|--pw=*|-p)
        log::error "intent_secrets: '${a%%=*}' refused: the operator password is always generated —" \
          "never accepted from a flag, the environment or a file (FR-102). Nothing was written"
        return 1 ;;
    esac
  done
}

intent_secrets::_labels_json() { # <component>
  jq -cn --arg k "$(ownership::key)" --arg v "$(ownership::value)" --arg c "$1" \
    '{($k): $v, "app.kubernetes.io/managed-by": "agentic-netops-lifecycle",
      "app.kubernetes.io/part-of": "agentic-netops", "agentic-netops.io/component": $c}'
}

# intent_secrets::_data_json — {KEY: base64(value)} for the keys IS_KEYS names ("K1 K2 …", each value
# in env IS_V_<K>), plus {KEY: null} for the keys IS_NULLS names. Values are read from the
# environment, never from argv.
intent_secrets::_data_json() {
  jq -cn '
    ($ENV.IS_KEYS // "" | split(" ") | map(select(length > 0))
      | map({(.): ($ENV["IS_V_" + .] | @base64)}) | add // {})
    + ($ENV.IS_NULLS // "" | split(" ") | map(select(length > 0)) | map({(.): null}) | add // {})'
}

# intent_secrets::_write <name> <component> <exists:true|false> — create (server-side apply of the
# whole new object) or merge-patch the keys of IS_KEYS / IS_NULLS into the existing one.
intent_secrets::_write() {
  local name="$1" comp="$2" exists="$3" data
  data="$(intent_secrets::_data_json)" || return 1
  if [[ "$exists" == true ]]; then
    jq -cn --argjson d "$data" '{data: $d}' \
      | intent_secrets::_kubectl patch secret "$name" -n "$INTENT_SECRETS_NS" --type merge --patch-file /dev/stdin >/dev/null \
      || { log::error "intent_secrets: merge-patching secret $INTENT_SECRETS_NS/$name failed"; return 1; }
  else
    jq -cn --arg ns "$INTENT_SECRETS_NS" --arg name "$name" --argjson l "$(intent_secrets::_labels_json "$comp")" \
      --argjson d "$data" \
      '{apiVersion: "v1", kind: "Secret", type: "Opaque", metadata: {name: $name, namespace: $ns, labels: $l},
        data: ($d | with_entries(select(.value != null)))}' \
      | intent_secrets::_kubectl apply --server-side --force-conflicts \
          --field-manager "$INTENT_SECRETS_FIELD_MANAGER" -f - >/dev/null \
      || { log::error "intent_secrets: creating secret $INTENT_SECRETS_NS/$name failed"; return 1; }
  fi
}

# intent_secrets::_gen_password — 32 characters from openssl rand; fails below 24.
intent_secrets::_gen_password() {
  local p
  p="$(openssl rand -base64 48 2>/dev/null | tr -d '/+=\n' | cut -c1-32)"
  if [[ ${#p} -lt 24 ]]; then
    log::error "intent_secrets: password generation failed (openssl rand)"
    return 1
  fi
  printf '%s' "$p"
}

# ------------------------------------------------------------------ redaction (FR-079, AD-67)
intent_secrets::redact_url() {
  printf '%s' "${1-}" | sed -E \
    -e 's%^([A-Za-z][A-Za-z0-9+.-]*://)[^/?#]*@%\1***@%' \
    -e '/^[A-Za-z][A-Za-z0-9+.-]*:\/\//! s%^[^/?#]*@%***@%' \
    -e "s%([?&;#])(${INTENT_SECRETS_CRED_PARAMS})=[^&;#]*%\\1\\2=***%Ig"
}

# intent_secrets::endpoint_line <base-url> [gateway] — the one line naming the endpoint.
intent_secrets::endpoint_line() {
  local url="${1-}" gw="${2-}" via=""
  [[ -n "$gw" ]] && via=" (declared gateway '${gw}')"
  if [[ -n "$url" ]]; then
    printf 'llm-provider: model calls will go to %s%s' "$(intent_secrets::redact_url "$url")" "$via"
  else
    printf "llm-provider: model calls will go to the provider's own default endpoint (no base URL is stored; the model-name prefix selects the provider)"
  fi
}

# ------------------------------------------------------------------ llm-provider (FR-106)
intent_secrets::llm_provider() {
  local name="$INTENT_SECRETS_LLM"
  local in_model="${AGENTIC_NETOPS_LLM_MODEL:-}" in_key="${AGENTIC_NETOPS_LLM_API_KEY:-}"
  local in_url="${AGENTIC_NETOPS_LLM_BASE_URL:-}" in_gw="${AGENTIC_NETOPS_LLM_GATEWAY:-}"
  local clear=false
  [[ "${AGENTIC_NETOPS_LLM_BASE_URL_CLEAR:-}" == 1 ]] && clear=true
  if [[ "$clear" == true && -n "$in_url" ]]; then
    log::error "intent_secrets: AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=1 and a new AGENTIC_NETOPS_LLM_BASE_URL were both given —" \
      "contradictory; nothing was written"
    return 1
  fi
  intent_secrets::_require_namespace || return 1
  local stored exists=false
  if intent_secrets::_exists "$name"; then exists=true; fi
  stored="$(intent_secrets::_stored "$name")" || return 1
  local eff_url eff_gw eff_model
  # --- the merge: an input absent from this run keeps its stored value
  if [[ "$clear" == true ]]; then
    eff_url=""
  elif [[ -n "$in_url" ]]; then
    eff_url="$in_url"
  else
    eff_url="$(intent_secrets::_val "$stored" BASE_URL)"
  fi
  eff_gw="${in_gw:-$(intent_secrets::_val "$stored" GATEWAY)}"
  eff_model="${in_model:-$(intent_secrets::_val "$stored" LLM_MODEL)}"
  # --- the gateway refusal, before anything is written (FR-106, CR-008)
  if [[ -n "$eff_gw" && -z "$eff_url" ]]; then
    local why="no base URL is given (AGENTIC_NETOPS_LLM_BASE_URL) or stored"
    [[ "$clear" == true ]] && why="AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=1 would leave it without a base URL"
    log::error "intent_secrets: the model gateway '${eff_gw}' is declared (AGENTIC_NETOPS_LLM_GATEWAY) but ${why}:" \
      "refused before any tier workload is created, so the model library's default endpoint is never used silently" \
      "(FR-106, CR-008). Set AGENTIC_NETOPS_LLM_BASE_URL to the gateway's base URL. Nothing was written"
    return 1
  fi
  [[ -n "$eff_model" ]] || log::warn "intent_secrets: no model is configured (AGENTIC_NETOPS_LLM_MODEL given or stored)"
  # --- key by key: only what this run sets, plus the explicit clear
  local IS_KEYS="" IS_NULLS="" IS_V_LLM_MODEL="$in_model" IS_V_API_KEY="$in_key" IS_V_BASE_URL="$in_url" IS_V_GATEWAY="$in_gw"
  [[ -n "$in_model" ]] && IS_KEYS+=" LLM_MODEL"
  [[ -n "$in_key" ]] && IS_KEYS+=" API_KEY"
  [[ -n "$in_url" ]] && IS_KEYS+=" BASE_URL"
  [[ -n "$in_gw" ]] && IS_KEYS+=" GATEWAY"
  if [[ "$clear" == true && "$exists" == true ]] && jq -e 'has("BASE_URL")' <<<"$stored" >/dev/null; then
    IS_NULLS="BASE_URL"
  fi
  export IS_KEYS IS_NULLS IS_V_LLM_MODEL IS_V_API_KEY IS_V_BASE_URL IS_V_GATEWAY
  local rc=0
  if [[ -z "${IS_KEYS// /}" && -z "$IS_NULLS" && "$exists" == true ]]; then
    log::info "intent_secrets: secret $INTENT_SECRETS_NS/$name unchanged (no input set; stored values kept)"
  else
    intent_secrets::_write "$name" llm-provider "$exists" || rc=1
    [[ "$rc" -eq 0 ]] && log::info "intent_secrets: secret $INTENT_SECRETS_NS/$name $([[ $exists == true ]] && echo merged || echo created)" \
      "(keys set:${IS_KEYS:- none}${IS_NULLS:+; cleared: $IS_NULLS}; every other stored key kept)"
  fi
  unset IS_KEYS IS_NULLS IS_V_LLM_MODEL IS_V_API_KEY IS_V_BASE_URL IS_V_GATEWAY
  [[ "$rc" -eq 0 ]] || return 1
  log::info "$(intent_secrets::endpoint_line "$eff_url" "$eff_gw")"
}

# ------------------------------------------------------------------ operator-credentials (FR-102)
intent_secrets::operator_credentials() {
  intent_secrets::_refuse_password_args "$@" || return 1
  if [[ $# -gt 0 ]]; then
    log::error "intent_secrets: operator-credentials takes no argument (got '$1'); OPERATOR_USERNAME sets the username"
    return 2
  fi
  local name="$INTENT_SECRETS_OPERATOR"
  if [[ -n "${OPERATOR_PASSWORD+x}" ]]; then
    log::warn "intent_secrets: OPERATOR_PASSWORD is set and IGNORED: the operator password is always generated (FR-102)"
  fi
  intent_secrets::_require_namespace || return 1
  local stored exists=false
  if intent_secrets::_exists "$name"; then exists=true; fi
  stored="$(intent_secrets::_stored "$name")" || return 1
  local IS_KEYS="" IS_NULLS="" IS_V_username="" IS_V_password=""
  local user="${OPERATOR_USERNAME:-}"
  if [[ "$exists" == true ]]; then
    [[ -n "$user" && "$user" != "$(intent_secrets::_val "$stored" username)" ]] && { IS_KEYS+=" username"; IS_V_username="$user"; }
    if ! jq -e 'has("password") and (.password | length > 0)' <<<"$stored" >/dev/null; then
      IS_V_password="$(intent_secrets::_gen_password)" || return 1
      IS_KEYS+=" password"
    fi
  else
    IS_V_username="${user:-operator}"
    IS_V_password="$(intent_secrets::_gen_password)" || return 1
    IS_KEYS="username password"
  fi
  export IS_KEYS IS_NULLS IS_V_username IS_V_password
  local rc=0
  if [[ -n "${IS_KEYS// /}" ]]; then
    intent_secrets::_write "$name" operator-credentials "$exists" || rc=1
  fi
  unset IS_KEYS IS_NULLS IS_V_username IS_V_password
  [[ "$rc" -eq 0 ]] || return 1
  if [[ "$exists" == true ]]; then
    log::info "intent_secrets: secret $INTENT_SECRETS_NS/$name exists and is owned (password preserved, not rotated${user:+; username set from OPERATOR_USERNAME})"
  else
    log::info "intent_secrets: secret $INTENT_SECRETS_NS/$name created (username and a generated password)"
  fi
}

# ------------------------------------------------------------------ slim-gateway, clickhouse-auth (D-23)
intent_secrets::generated() {
  local name="${1:-}" user comp
  case "$name" in
    "$INTENT_SECRETS_SLIM") user="slim"; comp="slim-gateway" ;;
    "$INTENT_SECRETS_CLICKHOUSE") user="agentic_netops"; comp="agent-analytics" ;;
    *) log::error "intent_secrets: generated: unknown secret '${name}' (slim-gateway | clickhouse-auth)"; return 2 ;;
  esac
  intent_secrets::_require_namespace || return 1
  if intent_secrets::_exists "$name"; then
    intent_secrets::_require_owned secret "$name" "$INTENT_SECRETS_NS" || return 1
    log::info "intent_secrets: secret $INTENT_SECRETS_NS/$name exists and is owned (password preserved, not rotated)"
    return 0
  fi
  local IS_KEYS="username password" IS_NULLS="" IS_V_username="$user" IS_V_password rc=0
  IS_V_password="$(intent_secrets::_gen_password)" || return 1
  export IS_KEYS IS_NULLS IS_V_username IS_V_password
  intent_secrets::_write "$name" "$comp" false || rc=1
  unset IS_KEYS IS_NULLS IS_V_username IS_V_password
  [[ "$rc" -eq 0 ]] || return 1
  log::info "intent_secrets: secret $INTENT_SECRETS_NS/$name created (username and a generated password)"
}

# ------------------------------------------------------------------ all four
intent_secrets::ensure_all() {
  intent_secrets::_refuse_password_args "$@" || return 1
  [[ $# -eq 0 ]] || { log::error "intent_secrets: ensure takes no argument (got '$1')"; return 2; }
  intent_secrets::_require_namespace || return 1
  # llm-provider first: its gateway refusal precedes every write of this step (FR-106)
  intent_secrets::llm_provider || return 1
  intent_secrets::operator_credentials || return 1
  intent_secrets::generated "$INTENT_SECRETS_SLIM" || return 1
  intent_secrets::generated "$INTENT_SECRETS_CLICKHOUSE" || return 1
}

# ------------------------------------------------------------------ removal (off.sh)
intent_secrets::remove() {
  local rc=0 name
  for name in "$INTENT_SECRETS_LLM" "$INTENT_SECRETS_OPERATOR" "$INTENT_SECRETS_SLIM" \
    "$INTENT_SECRETS_CLICKHOUSE" "$INTENT_SECRETS_INPUT"; do
    if ! intent_secrets::_exists "$name"; then
      log::debug "intent_secrets: secret $INTENT_SECRETS_NS/$name absent"
      continue
    fi
    if ! intent_secrets::_require_owned secret "$name" "$INTENT_SECRETS_NS"; then rc=1; continue; fi
    if intent_secrets::_kubectl delete secret "$name" -n "$INTENT_SECRETS_NS" --ignore-not-found --wait=false >/dev/null; then
      log::info "intent_secrets: deleted secret $INTENT_SECRETS_NS/$name"
    else
      log::error "intent_secrets: deleting secret $INTENT_SECRETS_NS/$name failed"; rc=1
    fi
  done
  return "$rc"
}

# intent_secrets::username — prints operator-credentials' `username` (never the password): what
# off.sh captures through evidence_run before the Secret is removed (data-model.md §22).
intent_secrets::username() {
  local stored u
  intent_secrets::_exists "$INTENT_SECRETS_OPERATOR" \
    || { log::error "intent_secrets: secret $INTENT_SECRETS_NS/$INTENT_SECRETS_OPERATOR absent"; return 1; }
  stored="$(intent_secrets::_stored "$INTENT_SECRETS_OPERATOR")" || return 1
  u="$(intent_secrets::_val "$stored" username)"
  [[ -n "$u" ]] || { log::error "intent_secrets: $INTENT_SECRETS_OPERATOR carries no username"; return 1; }
  printf 'username: %s\n' "$u"
}

# ------------------------------------------------------------------ the in-cluster Job's inputs
intent_secrets::scripts_configmap() {
  local dir
  dir="$(cd -- "$(dirname -- "$INTENT_SECRETS_SELF")" && pwd)"
  jq -n --arg ns "$INTENT_SECRETS_NS" --arg name "$INTENT_SECRETS_SCRIPTS_CM" \
    --argjson l "$(intent_secrets::_labels_json intent-secret-generator)" \
    --rawfile s "$dir/intent_secrets.sh" --rawfile lg "$dir/log.sh" --rawfile o "$dir/ownership.sh" \
    '{apiVersion: "v1", kind: "ConfigMap", metadata: {name: $name, namespace: $ns, labels: $l},
      data: {"intent_secrets.sh": $s, "log.sh": $lg, "ownership.sh": $o}}'
}

intent_secrets::input_secret() {
  jq -n --arg ns "$INTENT_SECRETS_NS" --arg name "$INTENT_SECRETS_INPUT" \
    --argjson l "$(intent_secrets::_labels_json intent-secret-generator)" '
    {apiVersion: "v1", kind: "Secret", type: "Opaque", metadata: {name: $name, namespace: $ns, labels: $l},
     data: (["AGENTIC_NETOPS_LLM_MODEL", "AGENTIC_NETOPS_LLM_API_KEY", "AGENTIC_NETOPS_LLM_BASE_URL",
             "AGENTIC_NETOPS_LLM_GATEWAY", "AGENTIC_NETOPS_LLM_BASE_URL_CLEAR", "OPERATOR_USERNAME"]
            | map(select(($ENV[.] // "") != "") | {(.): ($ENV[.] | @base64)}) | add // {})}'
}

intent_secrets::main() {
  intent_secrets::_refuse_password_args "$@" || return 1
  local cmd="${1:-ensure}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    ensure) intent_secrets::ensure_all "$@" ;;
    llm-provider) intent_secrets::llm_provider ;;
    operator-credentials) intent_secrets::operator_credentials "$@" ;;
    generated) intent_secrets::generated "${1:-}" ;;
    remove) intent_secrets::remove ;;
    redact-url) intent_secrets::redact_url "${1:?usage: intent_secrets.sh redact-url <url>}"; printf '\n' ;;
    scripts-configmap) intent_secrets::scripts_configmap ;;
    input-secret) intent_secrets::input_secret ;;
    -h|--help) sed -n '2,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) log::error "intent_secrets: unknown command '$cmd'"; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  intent_secrets::main "$@"
fi
