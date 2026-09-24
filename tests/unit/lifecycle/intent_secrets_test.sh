#!/usr/bin/env bash
# intent_secrets_test.sh — T168's shell half: scripts/lib/intent_secrets.sh and the in-cluster
# generator deploy/rbac/intent-secret-generator.yaml against a stateful fake kubectl (T072; FR-106,
# FR-102, FR-079, FR-019, CR-008, SC-048, AD-01, AD-49, AD-67). Offline: the fake stores objects as
# JSON files under a temp dir and records every call's argv in a call log.
#
# Asserts:
#   * the endpoint scanner's NEGATIVE CONTROL first: it fails on an unredacted line (userinfo, and a
#     key in the query string) and on a line that no longer names the host;
#   * intent_secrets::redact_url — userinfo → `***@`, a credential query/fragment parameter
#     (key|api_key|apikey|token|access_token|secret|password|sig|signature) → `name=***`;
#   * llm-provider: a declared gateway with no base URL (given or stored) is refused non-zero
#     BEFORE anything is created, naming the gateway; a run that sets model and key but omits the
#     base URL leaves the stored BASE_URL byte-identical (a merge patch, never a whole-object
#     replace — a key written out of band survives too); only AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=1
#     clears it (an empty AGENTIC_NETOPS_LLM_BASE_URL= or CLEAR=yes does not); the endpoint model
#     calls will use is printed — the base URL, or "the provider's own default" named as such;
#     with the userinfo fixture and with the query-key fixture every line naming the endpoint
#     carries zero credential characters while still naming the host; no API key value appears in
#     any output or any kubectl argv;
#   * operator-credentials: username `operator`, overridable by OPERATOR_USERNAME; the password
#     always generated — OPERATOR_PASSWORD ignored and absent from the Secret, --password /
#     --password-file refused with nothing created — and byte-identical across re-provisioning;
#   * slim-gateway and clickhouse-auth generated and preserved; every Secret carries the ownership
#     label; an unowned Secret is refused and left untouched; removal deletes the owned four;
#   * the Job: its own ServiceAccount/Role/RoleBinding in agentic-netops-agents only, an image
#     pinned by digest in versions.lock.yaml, and a command that runs THIS script mounted from the
#     scripts ConfigMap (byte-identical) — run as the manifest declares it against the fake, its
#     printed endpoint line is redacted the same way.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$ROOT/scripts/lib/intent_secrets.sh"
JOB_YAML="$ROOT/deploy/rbac/intent-secret-generator.yaml"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; [[ -n "${out:-}" ]] && printf '%s\n' "$out" | tail -n 12 | sed 's/^/    | /'; fi; return 0; }
ORIG_PATH="$PATH"
CL=agentic-netops
NS=agentic-netops-agents
OWNER_KEY="agentic-netops.io/owned-by"

KEY1='sk-fixture-KEYONE-7f3a9c2e1b4d'
KEY2='sk-fixture-KEYTWO-0c9d8e7f6a5b'
URL_UI='https://user:s3cret@gateway.example/v1'
URL_Q='https://gateway.example/v1?api_key=abc123&x=1'
URL_PLAIN='https://gateway.example/v1'
ENV_PW='EnvPassw0rd-must-never-be-used-42'
ALL_OUT=""
ALL_CALLS=""

# ------------------------------------------------------------------ the fake kubectl
install_fake() { # <dir>
  local d="$1"
  mkdir -p "$d/bin" "$d/state/k8s"
  : >"$d/state/calls.log"
  cat >"$d/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$FAKE_STATE/calls.log"
ctx="" ns="" out="" ptype="" pfile="" ignore_nf=false
pos=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) ctx="$2"; shift 2 ;;
    --context=*) ctx="${1#*=}"; shift ;;
    -n|--namespace) ns="$2"; shift 2 ;;
    --namespace=*) ns="${1#*=}"; shift ;;
    -o|--output) out="$2"; shift 2 ;;
    -o*) out="${1#-o}"; out="${out#=}"; shift ;;
    --type) ptype="$2"; shift 2 ;;
    --type=*) ptype="${1#*=}"; shift ;;
    --patch-file) pfile="$2"; shift 2 ;;
    --patch-file=*) pfile="${1#*=}"; shift ;;
    -p|--patch|--patch=*) echo "fake kubectl: an inline patch puts values in argv" >&2; exit 97 ;;
    -f|--filename) [[ "$2" == - ]] || { echo "fake kubectl: -f supports stdin only" >&2; exit 1; }; shift 2 ;;
    --ignore-not-found|--ignore-not-found=true) ignore_nf=true; shift ;;
    --field-manager|--request-timeout|--timeout) shift 2 ;;
    -*) shift ;;
    *) pos+=("$1"); shift ;;
  esac
done
cluster="${ctx#kind-}"
[[ -z "$ctx" ]] && cluster="in-cluster"
K="$FAKE_STATE/k8s/$cluster"
[[ -d "$K" ]] || { echo "error: context \"$ctx\" does not exist or the cluster is unreachable" >&2; exit 1; }
norm() {
  case "$1" in
    ns|namespace|namespaces) echo namespace ;; secret|secrets) echo secret ;;
    cm|configmap|configmaps) echo configmap ;; job|jobs|job.batch) echo job ;; *) echo "$1" ;;
  esac
}
path_of() { # <kind> <name> [ns]
  if [[ "$1" == namespace ]]; then echo "$K/_/namespace/$2.json"; else echo "$K/${3:-default}/$1/$2.json"; fi
}
verb="${pos[0]:-}"
case "$verb" in
  get)
    kind="$(norm "${pos[1]}")" name="${pos[2]:-}"
    f="$(path_of "$kind" "$name" "$ns")"
    [[ -f "$f" ]] || { echo "Error from server (NotFound): $kind \"$name\" not found" >&2; exit 1; }
    case "$out" in json) cat "$f" ;; name) echo "$kind/$name" ;; *) echo "$name" ;; esac ;;
  apply)
    obj="$(cat)"
    kind="$(jq -r '.kind | ascii_downcase' <<<"$obj")" name="$(jq -r '.metadata.name' <<<"$obj")"
    ons="$(jq -r '.metadata.namespace // "default"' <<<"$obj")"
    if [[ "$kind" != namespace && ! -f "$K/_/namespace/$ons.json" ]]; then
      echo "Error from server (NotFound): namespaces \"$ons\" not found" >&2; exit 1
    fi
    f="$(path_of "$kind" "$name" "$ons")"
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$obj" >"$f"
    echo "$kind/$name serverside-applied" ;;
  patch)
    kind="$(norm "${pos[1]}")" name="${pos[2]:-}"
    [[ "$ptype" == merge && -n "$pfile" ]] || { echo "fake kubectl: only --type merge --patch-file is supported" >&2; exit 1; }
    f="$(path_of "$kind" "$name" "$ns")"
    [[ -f "$f" ]] || { echo "Error from server (NotFound): $kind \"$name\" not found" >&2; exit 1; }
    p="$(cat "$pfile")"
    jq --argjson p "$p" '
      def mp($q): if ($q | type) == "object"
        then reduce ($q | to_entries[]) as $e (if type == "object" then . else {} end;
               if $e.value == null then del(.[$e.key]) else .[$e.key] = (.[$e.key] | mp($e.value)) end)
        else $q end;
      mp($p)' "$f" >"$f.t" && mv "$f.t" "$f"
    echo "$kind/$name patched" ;;
  delete)
    kind="$(norm "${pos[1]}")" name="${pos[2]:-}"
    f="$(path_of "$kind" "$name" "$ns")"
    if [[ ! -f "$f" ]]; then
      $ignore_nf && exit 0
      echo "Error from server (NotFound): $kind \"$name\" not found" >&2; exit 1
    fi
    rm -f "$f"; echo "$kind \"$name\" deleted" ;;
  create|replace)
    echo "fake kubectl: '$verb' is not how this step writes" >&2; exit 98 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$d/bin/kubectl"
}

plant_ns() { # <cluster-dir-name> <ns> [owner|-]
  local d="$FAKE_STATE/k8s/$1/_/namespace"
  mkdir -p "$d"
  jq -n --arg n "$2" --arg k "$OWNER_KEY" --arg v "${3:-$CL}" \
    '{apiVersion: "v1", kind: "Namespace", metadata: {name: $n, labels: (if $v == "-" then {} else {($k): $v} end)}}' \
    >"$d/$2.json"
}

setup() { # <case>
  W="$T/$1"; rm -rf "$W"; mkdir -p "$W"
  install_fake "$W"
  export FAKE_STATE="$W/state" PATH="$W/bin:$ORIG_PATH" CLUSTER_NAME="$CL"
  unset KUBE_CONTEXT KUBECTL AGENTIC_NETOPS_GENERATOR_IN_CLUSTER || true
  mkdir -p "$FAKE_STATE/k8s/$CL"
  plant_ns "$CL" "$NS" "$CL"
}

INPUT_VARS=(AGENTIC_NETOPS_LLM_MODEL AGENTIC_NETOPS_LLM_API_KEY AGENTIC_NETOPS_LLM_BASE_URL
  AGENTIC_NETOPS_LLM_GATEWAY AGENTIC_NETOPS_LLM_BASE_URL_CLEAR OPERATOR_USERNAME OPERATOR_PASSWORD)

# run_is <fn> [VAR=v…] [-- args…] — source the library in a subshell and run <fn>
run_is() {
  local fn="$1"; shift
  local -a kvs=() args=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == -- ]]; then shift; args=("$@"); break; fi
    kvs+=("$1"); shift
  done
  : >"$FAKE_STATE/calls.log"
  set +e
  out="$( ( unset "${INPUT_VARS[@]}"; for kv in "${kvs[@]}"; do export "${kv?}"; done
            source "$LIB" || exit 90; "$fn" "${args[@]}" ) 2>&1 )"
  rc=$?
  set -e
  ALL_OUT+="$out"$'\n'
  ALL_CALLS+="$(cat "$FAKE_STATE/calls.log")"$'\n'
}
# run_cmd [VAR=v…] -- args… — the library as a command
run_cmd() {
  local -a kvs=() args=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == -- ]]; then shift; args=("$@"); break; fi
    kvs+=("$1"); shift
  done
  : >"$FAKE_STATE/calls.log"
  set +e
  out="$( ( unset "${INPUT_VARS[@]}"; for kv in "${kvs[@]}"; do export "${kv?}"; done
            bash "$LIB" "${args[@]}" ) 2>&1 )"
  rc=$?
  set -e
  ALL_OUT+="$out"$'\n'
  ALL_CALLS+="$(cat "$FAKE_STATE/calls.log")"$'\n'
}
sec() { printf '%s' "$FAKE_STATE/k8s/${2:-$CL}/$NS/secret/$1.json"; }
b64d() { jq -r --arg k "$2" '.data[$k] // empty' "$1" | base64 -d; }
raw()  { jq -r --arg k "$2" '.data[$k] // "<absent>"' "$1"; }
has_key() { jq -e --arg k "$2" '.data | has($k)' "$1" >/dev/null; }
owner_of() { jq -r --arg k "$OWNER_KEY" '.metadata.labels[$k] // ""' "$1"; }
all_exist()  { local c="$1" s; shift; for s in "$@"; do [[ -f "$(sec "$s" "$c")" ]] || return 1; done; }
none_exist() { local c="$1" s; shift; for s in "$@"; do [[ ! -e "$(sec "$s" "$c")" ]] || return 1; done; }
wrote() { grep -Eq '^kubectl .*( apply | patch | create | replace )' "$FAKE_STATE/calls.log"; }

# endpoint_clean <line> — 0 when the line names gateway.example and carries no credential
# character of either fixture: the scan every endpoint line must pass (SC-048).
endpoint_clean() {
  local l="$1"
  [[ "$l" == *gateway.example* ]] || return 1
  [[ "$l" != *s3cret* && "$l" != *user:* && "$l" != *abc123* ]]
}
# endpoint_lines_clean <text> — every line naming the endpoint passes; at least one exists
endpoint_lines_clean() {
  local text="$1" l n=0
  while IFS= read -r l; do
    [[ "$l" == *gateway.example* || "$l" == *"model calls"* ]] || continue
    n=$((n + 1))
    endpoint_clean "$l" || return 1
  done <<<"$text"
  [[ "$n" -gt 0 ]]
}

# ================================================================== negative control FIRST
out=""
check "negative control: the scanner FAILS an unredacted userinfo line" \
  '! endpoint_clean "llm-provider: model calls will go to https://user:s3cret@gateway.example/v1"'
check "negative control: the scanner FAILS an unredacted query-key line" \
  '! endpoint_clean "llm-provider: model calls will go to https://gateway.example/v1?api_key=abc123&x=1"'
check "negative control: the scanner FAILS a line that redacted the host away" \
  '! endpoint_clean "llm-provider: model calls will go to https://***"'
check "negative control: the whole-output scan FAILS an output holding one unredacted line" \
  '! endpoint_lines_clean "$(printf "ok https://***@gateway.example/v1\nbad %s\n" "$URL_UI")"'
check "positive control: the scanner passes a redacted line that names the host" \
  'endpoint_clean "llm-provider: model calls will go to https://***@gateway.example/v1"'

# ================================================================== the library exists
check "intent_secrets.sh exists" '[[ -f "$LIB" ]]'
check "the Job manifest exists" '[[ -f "$JOB_YAML" ]]'

# ================================================================== redact_url
setup redact
red() { ( source "$LIB" 2>/dev/null && intent_secrets::redact_url "$1" ) 2>/dev/null || echo "<no redact_url>"; }
check "redact: userinfo → ***@, host and path kept" '[[ "$(red "$URL_UI")" == "https://***@gateway.example/v1" ]]'
check "redact: a username alone is userinfo too" '[[ "$(red "https://user@gateway.example/v1")" == "https://***@gateway.example/v1" ]]'
check "redact: an unencoded @ in the password is swallowed with the userinfo" \
  '[[ "$(red "https://u:p@ss@gateway.example/v1")" == "https://***@gateway.example/v1" ]]'
check "redact: api_key in the query → api_key=***, other parameters kept" \
  '[[ "$(red "$URL_Q")" == "https://gateway.example/v1?api_key=***&x=1" ]]'
check "redact: every named parameter (key apikey token access_token secret password sig signature)" \
  '[[ "$(red "https://h.example/?key=a1&apikey=a2&token=a3&access_token=a4&secret=a5&password=a6&sig=a7&signature=a8&keep=z")" == "https://h.example/?key=***&apikey=***&token=***&access_token=***&secret=***&password=***&sig=***&signature=***&keep=z" ]]'
check "redact: parameter names match case-insensitively" \
  '[[ "$(red "https://h.example/v1?API_KEY=Zz9&Token=Yy8")" == "https://h.example/v1?API_KEY=***&Token=***" ]]'
check "redact: a key in the fragment is redacted too" \
  '[[ "$(red "https://h.example/cb#access_token=Qq7&state=s")" == "https://h.example/cb#access_token=***&state=s" ]]'
check "redact: userinfo and query together" \
  '[[ "$(red "https://user:s3cret@gateway.example/v1?token=abc123")" == "https://***@gateway.example/v1?token=***" ]]'
check "redact: a parameter merely containing a name is kept (monkey=, keyboard=)" \
  '[[ "$(red "https://h.example/?monkey=1&keyboard=2")" == "https://h.example/?monkey=1&keyboard=2" ]]'
check "redact: a URL without credentials is unchanged" '[[ "$(red "$URL_PLAIN")" == "$URL_PLAIN" ]]'

# ================================================================== llm-provider: the gateway refusal
setup gw-refused
run_is intent_secrets::llm_provider AGENTIC_NETOPS_LLM_GATEWAY=corp-gw AGENTIC_NETOPS_LLM_MODEL=openai/gpt-x \
  AGENTIC_NETOPS_LLM_API_KEY="$KEY1"
check "gateway: declared with no base URL (given or stored) → refused non-zero" '[[ $rc -ne 0 ]]'
check "gateway: the refusal names the gateway and the missing base URL" \
  'grep -q "corp-gw" <<<"$out" && grep -qi "base URL" <<<"$out"'
check "gateway: nothing was created — no apply/patch/create in the call log" '! wrote && [[ ! -e "$(sec llm-provider)" ]]'

setup gw-refused-all
run_is intent_secrets::ensure_all AGENTIC_NETOPS_LLM_GATEWAY=corp-gw AGENTIC_NETOPS_LLM_MODEL=openai/gpt-x \
  AGENTIC_NETOPS_LLM_API_KEY="$KEY1"
check "gateway (ensure_all): refused before ANY Secret exists" \
  '[[ $rc -ne 0 ]] && ! wrote && [[ ! -d "$FAKE_STATE/k8s/$CL/$NS/secret" ]]'

setup gw-empty-url
run_is intent_secrets::llm_provider AGENTIC_NETOPS_LLM_GATEWAY=corp-gw AGENTIC_NETOPS_LLM_BASE_URL= \
  AGENTIC_NETOPS_LLM_MODEL=openai/gpt-x AGENTIC_NETOPS_LLM_API_KEY="$KEY1"
check "gateway: an empty base URL is no base URL — refused, nothing written" '[[ $rc -ne 0 ]] && ! wrote'

setup gw-stored-url
run_is intent_secrets::llm_provider AGENTIC_NETOPS_LLM_GATEWAY=corp-gw AGENTIC_NETOPS_LLM_BASE_URL="$URL_PLAIN" \
  AGENTIC_NETOPS_LLM_MODEL=openai/gpt-x AGENTIC_NETOPS_LLM_API_KEY="$KEY1"
check "gateway: declared with a base URL → accepted" '[[ $rc -eq 0 && "$(b64d "$(sec llm-provider)" GATEWAY)" == corp-gw ]]'
run_is intent_secrets::llm_provider AGENTIC_NETOPS_LLM_GATEWAY=corp-gw AGENTIC_NETOPS_LLM_MODEL=openai/gpt-y
check "gateway: a STORED base URL satisfies a declared gateway on a later run" '[[ $rc -eq 0 ]]'
run_is intent_secrets::llm_provider AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=1
check "gateway: clearing the base URL of a Secret that declares a gateway is refused" \
  '[[ $rc -ne 0 ]] && grep -q "corp-gw" <<<"$out" && ! wrote && [[ "$(b64d "$(sec llm-provider)" BASE_URL)" == "$URL_PLAIN" ]]'

# ================================================================== llm-provider: the merge (SC-048)
setup merge
run_is intent_secrets::llm_provider AGENTIC_NETOPS_LLM_MODEL=openai/gpt-x AGENTIC_NETOPS_LLM_API_KEY="$KEY1" \
  AGENTIC_NETOPS_LLM_BASE_URL="$URL_UI"
S="$(sec llm-provider)"
check "merge: first run exits 0 and writes the Secret" '[[ $rc -eq 0 && -f "$S" ]]'
check "merge: first run stores LLM_MODEL, API_KEY and BASE_URL" \
  '[[ "$(b64d "$S" LLM_MODEL)" == openai/gpt-x && "$(b64d "$S" API_KEY)" == "$KEY1" && "$(b64d "$S" BASE_URL)" == "$URL_UI" ]]'
check "merge: no GATEWAY key when no gateway is declared" '! has_key "$S" GATEWAY'
check "merge: the Secret carries the ownership label" '[[ "$(owner_of "$S")" == "$CL" ]]'
check "endpoint: the first run prints the (redacted) base URL model calls will use" \
  'grep -q "model calls will go to https://\*\*\*@gateway.example/v1" <<<"$out"'
check "endpoint (userinfo fixture): every line naming the endpoint carries zero credential characters" \
  'endpoint_lines_clean "$out" && ! grep -Fq "s3cret" <<<"$out" && ! grep -Fq "user:" <<<"$out"'
BASE_RAW="$(raw "$S" BASE_URL)"
# a key written out of band — a whole-object replace would drop it
[[ -f "$S" ]] && jq '.data.OUT_OF_BAND = "a2VwdA=="' "$S" >"$S.t" && mv "$S.t" "$S"
run_is intent_secrets::llm_provider AGENTIC_NETOPS_LLM_MODEL=anthropic/claude-z AGENTIC_NETOPS_LLM_API_KEY="$KEY2"
check "merge: second run (model + key, no base URL) exits 0" '[[ $rc -eq 0 ]]'
check "merge: the stored BASE_URL is byte-identical" '[[ "$(raw "$S" BASE_URL)" == "$BASE_RAW" ]]'
check "merge: model and key take the new values" \
  '[[ "$(b64d "$S" LLM_MODEL)" == anthropic/claude-z && "$(b64d "$S" API_KEY)" == "$KEY2" ]]'
check "merge: a key the run does not own survives (never a whole-object replace)" '[[ "$(raw "$S" OUT_OF_BAND)" == "a2VwdA==" ]]'
check "merge: the existing Secret is written by a merge patch, never apply/replace/create" \
  'grep -Eq "^kubectl .* patch secret llm-provider .*--type[= ]merge" "$FAKE_STATE/calls.log" && ! grep -Eq "^kubectl .*( apply | replace | create )" "$FAKE_STATE/calls.log"'
check "endpoint: the second run prints the preserved (redacted) base URL" \
  'grep -q "model calls will go to https://\*\*\*@gateway.example/v1" <<<"$out" && endpoint_lines_clean "$out"'
run_is intent_secrets::llm_provider AGENTIC_NETOPS_LLM_BASE_URL=
check "clear: an empty AGENTIC_NETOPS_LLM_BASE_URL= does NOT clear" '[[ $rc -eq 0 && "$(raw "$S" BASE_URL)" == "$BASE_RAW" ]]'
run_is intent_secrets::llm_provider AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=yes
check "clear: AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=yes (not 1) does NOT clear" '[[ "$(raw "$S" BASE_URL)" == "$BASE_RAW" ]]'
run_is intent_secrets::llm_provider AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=0
check "clear: AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=0 does NOT clear" '[[ "$(raw "$S" BASE_URL)" == "$BASE_RAW" ]]'
run_is intent_secrets::llm_provider AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=1 AGENTIC_NETOPS_LLM_BASE_URL="$URL_PLAIN"
check "clear: CLEAR=1 together with a new base URL is refused as contradictory, nothing written" \
  '[[ $rc -ne 0 ]] && ! wrote && [[ "$(raw "$S" BASE_URL)" == "$BASE_RAW" ]]'
run_is intent_secrets::llm_provider AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=1
check "clear: AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=1 removes BASE_URL" '[[ $rc -eq 0 ]] && ! has_key "$S" BASE_URL'
check "clear: …and nothing else (model, key, out-of-band key intact)" \
  '[[ "$(b64d "$S" LLM_MODEL)" == anthropic/claude-z && "$(b64d "$S" API_KEY)" == "$KEY2" && "$(raw "$S" OUT_OF_BAND)" == "a2VwdA==" ]]'
check "endpoint: with no base URL stored the provider's own default is named as such" \
  'grep -q "the provider'"'"'s own default" <<<"$out"'
run_is intent_secrets::llm_provider AGENTIC_NETOPS_LLM_MODEL=anthropic/claude-z
check "endpoint: a later run without a base URL still names the provider's own default" \
  '[[ $rc -eq 0 ]] && ! has_key "$S" BASE_URL && grep -q "the provider'"'"'s own default" <<<"$out"'

setup query-fixture
run_is intent_secrets::llm_provider AGENTIC_NETOPS_LLM_MODEL=openai/gpt-x AGENTIC_NETOPS_LLM_API_KEY="$KEY1" \
  AGENTIC_NETOPS_LLM_BASE_URL="$URL_Q"
check "endpoint (query-key fixture): stored verbatim" '[[ $rc -eq 0 && "$(b64d "$(sec llm-provider)" BASE_URL)" == "$URL_Q" ]]'
check "endpoint (query-key fixture): printed as api_key=***, host named, zero credential characters" \
  'grep -Fq "gateway.example/v1?api_key=***&x=1" <<<"$out" && endpoint_lines_clean "$out" && ! grep -Fq abc123 <<<"$out"'

setup foreign-llm
mkdir -p "$FAKE_STATE/k8s/$CL/$NS/secret"
jq -n --arg ns "$NS" '{apiVersion: "v1", kind: "Secret", metadata: {name: "llm-provider", namespace: $ns, labels: {}}, data: {BASE_URL: "eA=="}}' \
  >"$(sec llm-provider)"
run_is intent_secrets::llm_provider AGENTIC_NETOPS_LLM_MODEL=openai/gpt-x AGENTIC_NETOPS_LLM_API_KEY="$KEY1"
check "ownership: an unowned llm-provider is refused and left untouched" \
  '[[ $rc -ne 0 ]] && ! wrote && [[ "$(raw "$(sec llm-provider)" BASE_URL)" == "eA==" ]]'

setup no-ns
rm -f "$FAKE_STATE/k8s/$CL/_/namespace/$NS.json"
run_is intent_secrets::ensure_all AGENTIC_NETOPS_LLM_MODEL=openai/gpt-x AGENTIC_NETOPS_LLM_API_KEY="$KEY1"
check "namespace: a missing $NS fails naming it, nothing written" '[[ $rc -ne 0 ]] && grep -q "$NS" <<<"$out" && ! wrote'

# ================================================================== operator-credentials (FR-102)
setup operator
run_is intent_secrets::operator_credentials OPERATOR_PASSWORD="$ENV_PW"
O="$(sec operator-credentials)"
OP1="$(b64d "$O" password 2>/dev/null || true)"
check "operator: exits 0 and writes the Secret" '[[ $rc -eq 0 && -f "$O" ]]'
check "operator: username defaults to operator" '[[ "$(b64d "$O" username)" == operator ]]'
check "operator: the password is generated (>= 24 chars)" '[[ ${#OP1} -ge 24 ]]'
check "operator: OPERATOR_PASSWORD from the environment is ignored — not the password, nowhere in the Secret" \
  '[[ "$OP1" != "$ENV_PW" ]] && ! grep -Fq "$ENV_PW" "$O" && ! grep -Fq "$(printf "%s" "$ENV_PW" | base64 -w0)" "$O"'
check "operator: …and never echoed" '! grep -Fq "$ENV_PW" <<<"$out" && ! grep -Fq "$ENV_PW" "$FAKE_STATE/calls.log"'
check "operator: the generated password is never echoed or put in argv" \
  '! grep -Fq "$OP1" <<<"$out" && ! grep -Fq "$OP1" "$FAKE_STATE/calls.log"'
check "operator: carries the ownership label" '[[ "$(owner_of "$O")" == "$CL" ]]'
run_is intent_secrets::operator_credentials OPERATOR_USERNAME=alice
check "operator (re-run): OPERATOR_USERNAME overrides the username" '[[ $rc -eq 0 && "$(b64d "$O" username)" == alice ]]'
check "operator (re-run): the password survives byte-identical" '[[ "$(b64d "$O" password)" == "$OP1" ]]'
run_is intent_secrets::operator_credentials OPERATOR_PASSWORD="$ENV_PW"
check "operator (re-run): an absent OPERATOR_USERNAME keeps the stored one, password preserved" \
  '[[ $rc -eq 0 && "$(b64d "$O" username)" == alice && "$(b64d "$O" password)" == "$OP1" ]]'

setup operator-flags
for a in "--password=hunter2hunter2" "--password hunter2hunter2" "--password-file /tmp/pw" "--password-file=/tmp/pw"; do
  # shellcheck disable=SC2086
  run_cmd -- operator-credentials $a
  check "operator: '$a' is refused non-zero, nothing created" \
    '[[ $rc -ne 0 ]] && ! wrote && [[ ! -e "$(sec operator-credentials)" ]] && grep -qi "always generated" <<<"$out"'
done
# shellcheck disable=SC2086
run_cmd -- ensure --password=hunter2hunter2
check "operator: a password argument to 'ensure' is refused too, nothing created" '[[ $rc -ne 0 ]] && ! wrote'

setup op-two
run_is intent_secrets::operator_credentials
OPA="$(b64d "$(sec operator-credentials)" password)"
setup op-three
run_is intent_secrets::operator_credentials
OPB="$(b64d "$(sec operator-credentials)" password)"
check "operator: two fresh labs get different generated passwords" '[[ -n "$OPA" && "$OPA" != "$OPB" ]]'

# ================================================================== slim-gateway, clickhouse-auth
setup generated
run_is intent_secrets::ensure_all AGENTIC_NETOPS_LLM_MODEL=openai/gpt-x AGENTIC_NETOPS_LLM_API_KEY="$KEY1" \
  AGENTIC_NETOPS_LLM_BASE_URL="$URL_UI"
check "ensure_all: exits 0" '[[ $rc -eq 0 ]]'
declare -A GP=()
for s in slim-gateway clickhouse-auth operator-credentials; do
  GP[$s]="$(b64d "$(sec $s)" password 2>/dev/null || true)"
  check "ensure_all: $s generated with a username and a >= 24-char password" \
    '[[ -n "$(b64d "$(sec $s)" username)" && ${#GP[$s]} -ge 24 ]]'
  check "ensure_all: $s carries the ownership label" '[[ "$(owner_of "$(sec $s)")" == "$CL" ]]'
  check "ensure_all: the $s password never appears in output or argv" \
    '! grep -Fq "${GP[$s]}" <<<"$out" && ! grep -Fq "${GP[$s]}" "$FAKE_STATE/calls.log"'
done
check "ensure_all: llm-provider written and labelled" '[[ "$(owner_of "$(sec llm-provider)")" == "$CL" ]]'
check "ensure_all: every line naming the endpoint is redacted" 'endpoint_lines_clean "$out"'
check "ensure_all: the generated passwords differ from one another" \
  '[[ "${GP[slim-gateway]}" != "${GP[clickhouse-auth]}" && "${GP[slim-gateway]}" != "${GP[operator-credentials]}" ]]'
run_is intent_secrets::ensure_all AGENTIC_NETOPS_LLM_MODEL=openai/gpt-x
check "ensure_all (re-run): exits 0" '[[ $rc -eq 0 ]]'
for s in slim-gateway clickhouse-auth operator-credentials; do
  check "ensure_all (re-run): $s password preserved byte-identical" '[[ "$(b64d "$(sec $s)" password)" == "${GP[$s]}" ]]'
done
check "ensure_all (re-run): the base URL is preserved" '[[ "$(b64d "$(sec llm-provider)" BASE_URL)" == "$URL_UI" ]]'

setup foreign-generated
mkdir -p "$FAKE_STATE/k8s/$CL/$NS/secret"
jq -n --arg ns "$NS" '{apiVersion: "v1", kind: "Secret", metadata: {name: "clickhouse-auth", namespace: $ns, labels: {}}, data: {password: "eA=="}}' \
  >"$(sec clickhouse-auth)"
run_is intent_secrets::generated clickhouse-auth
check "ownership: an unowned clickhouse-auth is refused and untouched" \
  '[[ $rc -ne 0 ]] && ! wrote && [[ "$(raw "$(sec clickhouse-auth)" password)" == "eA==" ]]'

# ================================================================== remove (off.sh)
setup remove
run_is intent_secrets::ensure_all AGENTIC_NETOPS_LLM_MODEL=openai/gpt-x AGENTIC_NETOPS_LLM_API_KEY="$KEY1"
mkdir -p "$FAKE_STATE/k8s/$CL/$NS/secret"
jq -n --arg ns "$NS" '{apiVersion: "v1", kind: "Secret", metadata: {name: "someone-elses", namespace: $ns, labels: {}}}' \
  >"$(sec someone-elses)"
run_is intent_secrets::remove
check "remove: exits 0 and deletes the four generated Secrets" \
  '[[ $rc -eq 0 ]] && none_exist "$CL" llm-provider operator-credentials slim-gateway clickhouse-auth'
check "remove: an unowned Secret in the namespace is kept" '[[ -f "$(sec someone-elses)" ]]'
run_is intent_secrets::remove
check "remove (re-run): success, no delete issued" '[[ $rc -eq 0 ]] && ! grep -q " delete " "$FAKE_STATE/calls.log"'
check "off.sh: removes the intent-tier Secrets (operator-credentials included) with the other generated Secrets" \
  'grep -q "intent_secrets::remove" "$ROOT/scripts/off.sh"'

# ================================================================== the in-cluster Job
JOB_JSON="$T/job.json"
if python3 - "$JOB_YAML" >"$JOB_JSON" 2>"$T/job.err" <<'PY'
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
print(json.dumps(docs))
PY
then parsed=true; else parsed=false; cat "$T/job.err"; fi
out=""
check "job: the manifest parses" '$parsed'
jd() { jq -r "$@" "$JOB_JSON" 2>/dev/null; }
check "job: ServiceAccount, Role, RoleBinding and Job named intent-secret-generator in $NS" \
  '[[ "$(jd --arg ns "$NS" "[.[] | select(.metadata.name == \"intent-secret-generator\" and .metadata.namespace == \$ns) | .kind] | sort | join(\",\")")" == "Job,Role,RoleBinding,ServiceAccount" ]]'
check "job: no cluster-scoped grant (no ClusterRole / ClusterRoleBinding)" \
  '[[ "$(jd "[.[] | select(.kind | test(\"^Cluster\"))] | length")" == 0 ]]'
check "job: the Role grants Secrets only" \
  '[[ "$(jd "[.[] | select(.kind == \"Role\") | .rules[] | .resources[]] | unique | join(\",\")")" == secrets ]]'
check "job: get/patch are limited to the four generated Secrets by name" \
  '[[ "$(jd "[.[] | select(.kind == \"Role\") | .rules[] | select(.verbs | index(\"patch\")) | .resourceNames[]] | sort | join(\",\")")" == "clickhouse-auth,llm-provider,operator-credentials,slim-gateway" ]]'
check "job: no delete, list or watch verb" \
  '[[ "$(jd "[.[] | select(.kind == \"Role\") | .rules[] | .verbs[] | select(. == \"delete\" or . == \"list\" or . == \"watch\" or . == \"*\")] | length")" == 0 ]]'
check "job: the binding binds the generator identity, none of the five tier identities" \
  '[[ "$(jd "[.[] | select(.kind == \"RoleBinding\") | .subjects[].name] | join(\",\")")" == intent-secret-generator ]] && [[ "$(jd "[.[] | select(.kind == \"Job\") | .spec.template.spec.serviceAccountName] | join(\",\")")" == intent-secret-generator ]]'
JOB_IMG="$(jd '[.[] | select(.kind == "Job") | .spec.template.spec.containers[0].image][0] // ""')"
check "job: the image is pinned by digest and is a pinned: entry of versions.lock.yaml" \
  '[[ "$JOB_IMG" == *@sha256:* ]] && grep -Fq "pinned: \"$JOB_IMG\"" "$ROOT/versions.lock.yaml"'
MOUNT="$(jd '[.[] | select(.kind == "Job") | .spec.template.spec.containers[0].volumeMounts[] | select(.name == "scripts") | .mountPath][0] // ""')"
CMVOL="$(jd '[.[] | select(.kind == "Job") | .spec.template.spec.volumes[] | select(.name == "scripts") | .configMap.name][0] // ""')"
check "job: the scripts volume is the ConfigMap intent-secret-generator-scripts" \
  '[[ -n "$MOUNT" && "$CMVOL" == intent-secret-generator-scripts ]]'
check "job: its command runs the mounted intent_secrets.sh" \
  'jd "[.[] | select(.kind == \"Job\") | .spec.template.spec.containers[0] | (.command // []) + (.args // [])][0] | join(\" \")" | grep -Fq "$MOUNT/intent_secrets.sh"'

setup job
CM="$T/cm.json"
set +e
( source "$LIB" && intent_secrets::scripts_configmap ) >"$CM" 2>/dev/null
cmrc=$?
set -e
check "job: intent_secrets::scripts_configmap renders the scripts ConfigMap, labelled" \
  '[[ $cmrc -eq 0 && "$(jq -r .metadata.name "$CM")" == intent-secret-generator-scripts && "$(owner_of "$CM")" == "$CL" ]]'
MNT="$T/mnt"; mkdir -p "$MNT"
jq -r '.data | keys[]' "$CM" 2>/dev/null | while IFS= read -r k; do jq -j --arg k "$k" '.data[$k]' "$CM" >"$MNT/$k"; done
check "job: the mounted intent_secrets.sh is byte-identical to scripts/lib/intent_secrets.sh (one code path)" \
  'cmp -s "$MNT/intent_secrets.sh" "$LIB" && cmp -s "$MNT/log.sh" "$ROOT/scripts/lib/log.sh" && cmp -s "$MNT/ownership.sh" "$ROOT/scripts/lib/ownership.sh"'
# run the Job's container as the manifest declares it: its env (literal values + the optional
# input Secret's keys), its command with the mount path pointed at the materialised ConfigMap,
# in-cluster (no --context), against the fake
mkdir -p "$FAKE_STATE/k8s/in-cluster"
plant_ns in-cluster "$NS" "$CL"
declare -A JOB_INPUT=([AGENTIC_NETOPS_LLM_MODEL]=openai/gpt-x [AGENTIC_NETOPS_LLM_API_KEY]="$KEY1"
  [AGENTIC_NETOPS_LLM_BASE_URL]="$URL_UI")
mapfile -t JOB_CMD < <(jd '[.[] | select(.kind == "Job") | .spec.template.spec.containers[0] | (.command // []) + (.args // [])][0][]')
JOB_ENV_LIT="$(jd '[.[] | select(.kind == "Job") | .spec.template.spec.containers[0].env[] | select(.value != null) | "\(.name)=\(.value)"][]')"
JOB_ENV_REF="$(jd '[.[] | select(.kind == "Job") | .spec.template.spec.containers[0].env[] | select(.valueFrom.secretKeyRef != null) | "\(.name)=\(.valueFrom.secretKeyRef.name)/\(.valueFrom.secretKeyRef.key)/\(.valueFrom.secretKeyRef.optional // false)"][]')"
check "job: the LLM inputs come from optional secretKeyRefs of the input Secret, never literals" \
  '[[ "$(grep -c "^AGENTIC_NETOPS_LLM_[A-Z_]*=intent-secret-generator-input/AGENTIC_NETOPS_LLM_[A-Z_]*/true$" <<<"$JOB_ENV_REF")" -ge 4 ]]'
: >"$FAKE_STATE/calls.log"
set +e
out="$( (
  unset "${INPUT_VARS[@]}" CLUSTER_NAME
  while IFS= read -r kv; do [[ -n "$kv" ]] && export "${kv?}"; done <<<"$JOB_ENV_LIT"
  while IFS= read -r kv; do
    [[ -n "$kv" ]] || continue
    n="${kv%%=*}"
    [[ -n "${JOB_INPUT[$n]:-}" ]] && export "$n=${JOB_INPUT[$n]}"
  done <<<"$JOB_ENV_REF"
  cmd=(); for a in "${JOB_CMD[@]}"; do cmd+=("${a//$MOUNT/$MNT}"); done
  "${cmd[@]}"
) 2>&1 )"
jrc=$?
set -e
ALL_OUT+="$out"$'\n'; ALL_CALLS+="$(cat "$FAKE_STATE/calls.log")"$'\n'
JS="$(sec llm-provider in-cluster)"
check "job: run as declared, it exits 0 in-cluster (no --context) and writes llm-provider" \
  '[[ $jrc -eq 0 && -f "$JS" ]] && ! grep -q -- "--context" "$FAKE_STATE/calls.log"'
check "job: it writes all four Secrets" \
  'all_exist in-cluster llm-provider operator-credentials slim-gateway clickhouse-auth'
check "job: its printed endpoint line is redacted the same way (userinfo fixture), host named" \
  'grep -q "model calls will go to https://\*\*\*@gateway.example/v1" <<<"$out" && endpoint_lines_clean "$out" && ! grep -Fq s3cret <<<"$out"'

# ================================================================== no key value ever echoed
out=""
check "no API key value in any output of this suite" '! grep -Fq "$KEY1" <<<"$ALL_OUT" && ! grep -Fq "$KEY2" <<<"$ALL_OUT"'
check "no API key value in any kubectl argv of this suite" '! grep -Fq "$KEY1" <<<"$ALL_CALLS" && ! grep -Fq "$KEY2" <<<"$ALL_CALLS"'
check "no embedded credential of the fixtures in any output of this suite" \
  '! grep -Fq s3cret <<<"$ALL_OUT" && ! grep -Fq abc123 <<<"$ALL_OUT" && ! grep -Fq "user:" <<<"$ALL_OUT"'

printf '\nintent_secrets_test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
