#!/usr/bin/env bash
# credential_scan.sh — the credential scan and the log-shape check (T147; SC-031, SC-050, FR-079,
# NFR-014, R-38; data-model.md §27; plan.md SC-031/SC-050 rows).
#
# Usage:
#   credential_scan.sh [scan options] [--log-shape <dir>] [<path>…]
#   credential_scan.sh --collect <out-dir> [--log-shape <out-dir>] [scan options] [<path>…]
#   credential_scan.sh --evidence [--collect <out-dir>] [--log-shape <dir>] [scan options] [<path>…]
#
# (1) Credential scan — over every <path> (file or directory, recursive; .gz is read gunzipped;
#     binary files are named and skipped): traces exported from the analytics store, pod logs,
#     transcripts, corpus result JSON. Zero hits or exit 1. A hit is printed as
#         credential-scan: FAIL <file>:<line>: <pattern name>
#     and NEVER with the matched text. The pattern set is the tier's one FR-079 list,
#     agents/common/guards/redaction.py, loaded by scripts/ci/credential_scan.py (no copy here):
#     a hit is a span its redact() would change — Authorization/Proxy-Authorization headers of
#     any scheme with a value, bare bearer tokens, URL userinfo scheme://user:pass@, credential
#     query parameters, name=value / "name": "value" credential pairs (password, token, secret,
#     api_key …), sk-… keys, AWS/GitHub/Slack/Google keys, JWTs, PEM private-key blocks — plus a
#     JSON key redact_mapping() treats as a credential (authorization, cookie, x-api-key,
#     credentials, *_token …) holding a non-redacted string. The markers the tier writes —
#     `***` (Python, scripts/lib/intent_secrets.sh) and `[REDACTED]` / `%5BREDACTED%5D` (Go,
#     internal/telemetry/jsonlog) — are redacted values, never hits.
#     A bare 32-hex string (the shape of the llm API key) is NOT a pattern: the correlation id
#     and every trace id have exactly that shape. The live key is caught as a KNOWN SECRET:
#       --secrets-from-file <f>   one secret value per line (repeatable)
#       --secret-env <NAME>       the value of environment variable NAME (repeatable);
#                                 CREDENTIAL_SCAN_SECRET_ENVS="A B C" adds more names
#     A known secret is matched raw, URL-encoded and base64-encoded, and reported as
#     `known-secret <file>#<line>` or `known-secret $NAME` — the value itself is never printed.
#       --max-violations <n>      print at most n findings per check (default 50; all are counted)
#
# (2) Log shape (NFR-014) — `--log-shape <dir>`: every <workload>[@<pod>][.previous].log[.gz] in
#     <dir> whose workload is first-party — srl-provider, allocation-authority (the srl-provider
#     binary; component srl-provider), intent-translator, supervisor, mapper, allocator, deployer —
#     is read line by line; EVERY line must be one JSON object with
#       ts          UTC RFC 3339 (…Z)          level  debug|info|warn|error
#       component   the workload's §27 value    msg    a non-empty string
#       kind/namespace/name strings when present; correlation_id 32 lowercase hex when present;
#       thread_id only on an intent-tier component;
#     and every line that belongs to a request must carry correlation_id. A line is taken to
#     belong to a request when it carries thread_id; is an access line of a request-bearing
#     method (POST|PUT|PATCH|DELETE — a read such as GET /suggested-prompts opens no request and
#     has no correlation id) on a non-probe path (not /health, /v1/health, /healthz, /livez,
#     /readyz, /ready, /metrics); is an outbound mutating call (`HTTP Request: POST|PUT|PATCH|DELETE`); is a model call
#     (`model call N:`), a worker retry (`attempt N of M`) or a translation (`/v1/translate`);
#     or names a service identifier (15 lowercase hex, e.g. in migr-<id>) in any field.
#     Counts are reported per workload; violations as `log-shape: FAIL <file>:<line>: <why> |
#     <excerpt>` — the excerpt passed through the FR-079 redaction with every known secret
#     masked. Every first-party workload must have a log file (a missing one fails);
#       --expect-workloads a,b    narrow that list (fixtures; never the acceptance run)
#     Other *.log files (e.g. ui.log) are named and not shape-checked; the credential scan still
#     reads them when <dir> is also a <path>.
#
# (3) --collect <out-dir> — read-only collection from the live cluster, through
#     kubectl --context "${KUBE_CONTEXT:-kind-agentic-netops}": for every pod of every
#     first-party Deployment, `kubectl logs` of its first-party container into
#     <out-dir>/<workload>.log (<workload>@<pod>.log when a Deployment has several pods), the
#     previous container's log as <workload>@<pod>.previous.log when there is one, the chat
#     surface's log into <out-dir>/extra/ui.log (credential scan only; it is not a §27 component),
#     and <out-dir>/collected.tsv. Nothing in the cluster is changed. <out-dir> is then also
#     scanned for credentials (and shape-checked, when --log-shape is not given another dir).
#
# (4) --evidence — run-captured evidence (NFR-013, SC-050's "negative control first"): the
#     negative control `credential-scan` — this script over a planted fixture holding an
#     Authorization header and a line missing its §27 fields — is recorded with
#     evidence_negative_control and must fail; then the real run is recorded with
#     `evidence_run credential-scan --readiness --records SC-031 --records SC-050`.
#
# Exit: 0 clean; 1 a hit, a violation or nothing to scan; 2 usage or collection error;
#       3/4 from evidence.sh (refused / defective control).
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/scripts/ci/credential_scan.py"
PY="${PYTHON:-python3}"
KUBECTL="${KUBECTL:-kubectl}"
KCTX="${KUBE_CONTEXT:-kind-agentic-netops}"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
die() { printf 'credential-scan: %s\n' "$*" >&2; exit 2; }

scan_args=() paths=() shape_dir="" collect_dir="" expect="" maxv=50 evidence=false
orig_args=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --secrets-from-file) [[ -r "${2:-}" ]] || die "--secrets-from-file needs a readable file"
                         scan_args+=(--secrets-from-file "$2"); shift 2 ;;
    --secret-env) scan_args+=(--secret-env "${2:?--secret-env needs a variable name}"); shift 2 ;;
    --log-shape) shape_dir="${2:?--log-shape needs a directory}"; shift 2 ;;
    --expect-workloads) expect="${2:?--expect-workloads needs a list}"; shift 2 ;;
    --collect) collect_dir="${2:?--collect needs a directory}"; shift 2 ;;
    --max-violations) maxv="${2:?--max-violations needs a number}"; shift 2 ;;
    --evidence) evidence=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; paths+=("$@"); break ;;
    -*) die "unknown option '$1' (see --help)" ;;
    *) paths+=("$1"); shift ;;
  esac
done
for name in ${CREDENTIAL_SCAN_SECRET_ENVS:-}; do scan_args+=(--secret-env "$name"); done

# ------------------------------------------------------------------------------ evidence mode
if [[ "$evidence" == true ]]; then
  # shellcheck source=scripts/lib/evidence.sh
  source "$ROOT/scripts/lib/evidence.sh"
  rest=()
  for a in "${orig_args[@]}"; do [[ "$a" == --evidence ]] || rest+=("$a"); done
  nc="$(mktemp -d)"; trap 'rm -rf "$nc"' EXIT
  printf '{"ts":"2026-01-01T00:00:00Z","level":"info","component":"supervisor","msg":"x"}\n' >"$nc/supervisor.log"
  printf 'GET / Authorization: Basic %s\n' "dXNlcjpwYXNz" >>"$nc/supervisor.log"
  printf '{"level":"info","component":"supervisor","msg":"no ts"}\n' >>"$nc/supervisor.log"
  nc_rc=0
  evidence_negative_control credential-scan -- \
    "$0" --log-shape "$nc" --expect-workloads supervisor "$nc" || nc_rc=$?
  [[ $nc_rc -eq 4 ]] && exit 4
  scan_rc=0
  evidence_run credential-scan --readiness --records SC-031 --records SC-050 -- "$0" "${rest[@]}" \
    || scan_rc=$?
  if [[ -n "$collect_dir" && -d "$collect_dir" ]]; then
    # The logs the scan collected are artefacts of this run: a second record hashes and attaches
    # every one of them, so none is an unreferenced file under EVIDENCE_DIR (NFR-013).
    att=() files=()
    while IFS= read -r f; do att+=(--attach "$f"); files+=("$f"); done \
      < <(find "$collect_dir" -type f | LC_ALL=C sort)
    [[ ${#files[@]} -eq 0 ]] \
      || evidence_run credential-scan-collected "${att[@]}" -- sha256sum "${files[@]}" || scan_rc=1
  fi
  exit "$scan_rc"
fi

# ------------------------------------------------------------------------------ collection
collect() {
  local out="$1" ns dep ctr workload sel pods pod n
  mkdir -p "$out/extra"
  : >"$out/collected.tsv"
  "$KUBECTL" --context "$KCTX" --request-timeout=10s get namespace kube-system >/dev/null 2>&1 \
    || die "--collect: cluster context $KCTX does not answer"
  # namespace deployment container workload
  local plan=(
    "agentic-netops-system srl-provider srl-provider srl-provider"
    "agentic-netops-allocation allocation-authority allocation-authority allocation-authority"
    "agentic-netops-agents supervisor supervisor supervisor"
    "agentic-netops-agents mapper mapper mapper"
    "agentic-netops-agents allocator allocator allocator"
    "agentic-netops-agents deployer deployer deployer"
    "agentic-netops-agents deployer intent-translator intent-translator"
    "agentic-netops-agents ui ui extra/ui"
  )
  local entry rc=0
  for entry in "${plan[@]}"; do
    read -r ns dep ctr workload <<<"$entry"
    sel="$("$KUBECTL" --context "$KCTX" -n "$ns" get deploy "$dep" \
      -o 'go-template={{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null)" \
      || { echo "credential-scan: collect: FAIL deployment $ns/$dep not found"; rc=1; continue; }
    mapfile -t pods < <("$KUBECTL" --context "$KCTX" -n "$ns" get pods -l "${sel%,}" \
      -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}')
    [[ ${#pods[@]} -gt 0 ]] || { echo "credential-scan: collect: FAIL no pod for $ns/$dep"; rc=1; continue; }
    for pod in "${pods[@]}"; do
      [[ -n "$pod" ]] || continue
      local f="$out/$workload.log"
      [[ ${#pods[@]} -gt 1 ]] && f="$out/$workload@$pod.log"
      "$KUBECTL" --context "$KCTX" -n "$ns" logs "$pod" -c "$ctr" >"$f" \
        || { echo "credential-scan: collect: FAIL logs $ns/$pod -c $ctr"; rc=1; continue; }
      n="$(wc -l <"$f")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ns" "$pod" "$ctr" "current" "$n" "${f#"$out"/}" >>"$out/collected.tsv"
      local p="$out/$workload@$pod.previous.log"
      if "$KUBECTL" --context "$KCTX" -n "$ns" logs "$pod" -c "$ctr" --previous >"$p" 2>/dev/null; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ns" "$pod" "$ctr" "previous" "$(wc -l <"$p")" "${p#"$out"/}" >>"$out/collected.tsv"
      else
        rm -f "$p"
      fi
      echo "credential-scan: collected $ns/$pod -c $ctr: $n line(s)"
    done
  done
  return "$rc"
}

command -v "$PY" >/dev/null 2>&1 || die "python3 is required"
overall=0
if [[ -n "$collect_dir" ]]; then
  collect "$collect_dir" || overall=1
  paths+=("$collect_dir")
  [[ -n "$shape_dir" ]] || shape_dir="$collect_dir"
fi
[[ ${#paths[@]} -gt 0 || -n "$shape_dir" ]] || { usage >&2; exit 2; }

if [[ ${#paths[@]} -gt 0 ]]; then
  rc=0; "$PY" "$HELPER" scan --max-violations "$maxv" "${scan_args[@]}" -- "${paths[@]}" || rc=$?
  [[ $rc -le 1 ]] || exit "$rc"
  [[ $rc -eq 0 ]] || overall=1
fi
if [[ -n "$shape_dir" ]]; then
  shape_args=(--max-violations "$maxv" "${scan_args[@]}")  # known secrets: masked in excerpts
  [[ -n "$expect" ]] && shape_args+=(--expect-workloads "$expect")
  rc=0; "$PY" "$HELPER" shape "${shape_args[@]}" "$shape_dir" || rc=$?
  [[ $rc -le 1 ]] || exit "$rc"
  [[ $rc -eq 0 ]] || overall=1
fi
exit "$overall"
