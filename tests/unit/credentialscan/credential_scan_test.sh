#!/usr/bin/env bash
# credential_scan suite (T147; SC-031, SC-050, FR-079, NFR-014, R-38).
#
# Every fixture is planted in a scratch directory (never in the tree). NEGATIVE CONTROLS FIRST —
# each must FAIL, naming the file and line, and no planted secret value may appear in the output:
#   auth-basic       `Authorization: Basic dXNlcjpwYXNz`             → authorization-header
#   sk-key           an sk-… key                                      → openai-style-key
#   userinfo         https://user:pass@host                           → url-userinfo
#   json-password    "password": "…" non-redacted                     → credential-pair
#   pem              a PEM private-key block, reported at its first line
#   known-secret     a 32-hex value given by --secrets-from-file / --secret-env (no pattern can
#                    see it: that shape is the correlation id's) → known-secret, value never shown
#   shape-field      a line missing ts / level / component / msg      → log-shape names file:line
#   shape-nonjson    a plain-text line (a third-party logger's)        → not one JSON object
#   shape-request    a request line (thread_id, a non-probe access line, a model call, a
#                    service id) without correlation_id               → request line without …
#   shape-missing    a first-party workload with no log file
#   empty            zero files is not zero hits
# Then the positives: the redacted forms the tier writes (`***`, `[REDACTED]`, `%5BREDACTED%5D`)
# pass; clean fixtures pass both checks; .gz input is read (a hit inside it is found by line,
# a clean one passes); --collect drives a stub kubectl read-only and its output is scanned.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CS="$ROOT/scripts/ci/credential_scan.sh"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

# run <args…> — sets OUT and RC
run() { RC=0; OUT="$(bash "$CS" "$@" 2>&1)" || RC=$?; }

# expect_hit <case> <file> <line> <pattern> [<secret that must not be printed>] -- <args…>
expect_hit() {
  local name="$1" file="$2" line="$3" pat="$4" secret="$5"; shift 6
  run "$@"
  if [[ $RC -ne 1 ]]; then fail "$name: want exit 1, got $RC" "$OUT"; return; fi
  if ! grep -qF "FAIL $file:$line: $pat" <<<"$OUT"; then fail "$name: no finding '$file:$line: $pat'" "$OUT"; return; fi
  if [[ -n "$secret" ]] && grep -qF -- "$secret" <<<"$OUT"; then fail "$name: the secret value was printed" "$OUT"; return; fi
  pass "$name"
}

TS='"ts":"2026-09-25T00:04:21.388Z"'
CID='"correlation_id":"0af7651916cd43dd8448eb211c80319c"'

# ------------------------------------------------------------------ negative controls: scan
d="$SCRATCH/auth"; mkdir -p "$d"
printf 'first line\nGET /v1/prompt HTTP/1.1\nAuthorization: Basic dXNlcjpwYXNz\n' >"$d/trace.txt"
expect_hit auth-basic "$d/trace.txt" 3 authorization-header dXNlcjpwYXNz -- "$d"

d="$SCRATCH/bearer"; mkdir -p "$d"
printf '{"attributes":{"http.headers":"authorization: Bearer abcdefghijklmnop1234"}}\n' >"$d/span.json"
expect_hit auth-bearer "$d/span.json" 1 authorization-header abcdefghijklmnop1234 -- "$d"

d="$SCRATCH/sk"; mkdir -p "$d"
printf 'ok\nok\nmodel key sk-proj-AbCdEfGhIjKlMnOpQrStUv now\n' >"$d/pod.log"
expect_hit sk-key "$d/pod.log" 3 openai-style-key sk-proj-AbCdEfGhIjKlMnOpQrStUv -- "$d/pod.log"

d="$SCRATCH/userinfo"; mkdir -p "$d"
printf 'base url https://alice:s3cretpw@api.example.net/v1\n' >"$d/transcript.txt"
expect_hit userinfo "$d/transcript.txt" 1 url-userinfo s3cretpw -- "$d"

d="$SCRATCH/jsonpw"; mkdir -p "$d"
printf '{\n  "user": "operator",\n  "password": "hunter2hunter2"\n}\n' >"$d/result.json"
expect_hit json-password "$d/result.json" 3 credential-pair hunter2hunter2 -- "$d"

# Credential-named fields whose value is not a credential (live-findings 2026-09-26-t151r7):
# YANG identity names, absent values, nested references, a one-way device password hash.
d="$SCRATCH/benign"; mkdir -p "$d"
{ printf '      "name": "urn:nokia.com:srlinux:aaa:aaa-password:srl_nokia-aaa-password",\n'
  printf '                    "password": "<redacted>",\n'
  printf 'ClientConfig { username: None, password: None, headers: {} }\n'
  printf '  - {name: tls, secret: {secretName: vt-scratch-slim-tls}}\n'; } >"$d/readback.txt"
printf '{\n  "requests": [\n    {"credential": "none", "status": 401}\n  ]\n}\n' >"$d/auth-refusals.json"
printf '  File "/app/common/llm.py", line 90, in call\n    api_key=endpoint.api_key,\n' >"$d/stacktrace.txt"
run "$d"
[[ $RC -eq 0 ]] && pass "benign: identity names, None, references, a code reference and a capture-redacted value are not credentials" \
  || fail "benign values reported as hits (rc=$RC)" "$OUT"
printf '"password": "hunter2hunter2"\n' >>"$d/readback.txt"
expect_hit benign-still-catches "$d/readback.txt" 5 credential-pair hunter2hunter2 -- "$d"
printf '"password": "$y$j9T$Zm9vYmFyYmF6$abcdefghijklmnopqrstuvwxyz0123"\n' >"$d/readback.txt"
expect_hit crypt-hash-is-a-hit "$d/readback.txt" 1 credential-pair 'Zm9vYmFyYmF6' -- "$d"

d="$SCRATCH/jsonkey"; mkdir -p "$d"
printf '{"ts":"x","attrs":{"http.request.header.cookie":"sessionid=zz9plural"}}\n' >"$d/trace.jsonl"
expect_hit json-credential-key "$d/trace.jsonl" 1 credential-key:http.request.header.cookie zz9plural -- "$d"

d="$SCRATCH/pem"; mkdir -p "$d"
printf 'a\nb\n-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEAplanted\n-----END RSA PRIVATE KEY-----\nafter\n' >"$d/k.log"
expect_hit pem "$d/k.log" 3 pem-private-key MIIEpAIBAAKCAQEAplanted -- "$d"
# and a hit after the collapsed block still carries its own line
printf 'z\nz\n-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\nsk-AbCdEfGhIjKlMnOpQrStUv\n' >"$d/k.log"
expect_hit pem-line-numbers "$d/k.log" 6 openai-style-key "" -- "$d"

KEY="5d41402abc4b2a76b9719d911017c592"
d="$SCRATCH/known"; mkdir -p "$d/evidence"
printf '{"msg":"calling model","trace_id":"0af7651916cd43dd8448eb211c80319c"}\n{"msg":"echo %s"}\n' "$KEY" >"$d/evidence/pod.log"
printf '%s\n' "$KEY" >"$d/secrets"
run "$d/evidence"
[[ $RC -eq 0 ]] && pass "known-secret: invisible to the patterns (a 32-hex value is a trace id's shape)" \
  || fail "known-secret: a bare 32-hex value should not be a pattern hit" "$OUT"
expect_hit known-secret-file "$d/evidence/pod.log" 2 "known-secret $d/secrets#1" "$KEY" \
  -- --secrets-from-file "$d/secrets" "$d/evidence"
export CS_TEST_LLM_KEY="$KEY"
expect_hit known-secret-env "$d/evidence/pod.log" 2 'known-secret $CS_TEST_LLM_KEY' "$KEY" \
  -- --secret-env CS_TEST_LLM_KEY "$d/evidence"
RC=0; OUT="$(CREDENTIAL_SCAN_SECRET_ENVS="CS_TEST_LLM_KEY" bash "$CS" "$d/evidence" 2>&1)" || RC=$?
if [[ $RC -eq 1 ]] && ! grep -qF "$KEY" <<<"$OUT"; then pass "known-secret-envs-list"; else fail "known-secret-envs-list" "$OUT"; fi
printf 'Authorization: Basic %s\n' "$(printf 'operator:%s' "$KEY" | base64 -w0)" >"$d/evidence/b64.log"
run --secrets-from-file "$d/secrets" "$d/evidence/b64.log"
if [[ $RC -eq 1 ]] && ! grep -qF "$KEY" <<<"$OUT"; then pass "known-secret: never printed, even inside a header hit"; else fail "known-secret-b64" "$OUT"; fi
run --secret-env CS_TEST_UNSET_VAR "$d/evidence"
[[ $RC -eq 2 ]] && pass "known-secret: an unset --secret-env is a usage error, not a pass" || fail "unset secret env (rc=$RC)" "$OUT"

d="$SCRATCH/empty"; mkdir -p "$d"
run "$d"
[[ $RC -eq 1 ]] && grep -q "zero files scanned" <<<"$OUT" && pass "empty: zero files is not zero hits" || fail "empty (rc=$RC)" "$OUT"

# ------------------------------------------------------------------ negative controls: shape
line_ok() { printf '{%s,"level":"info","component":"%s","msg":"%s"}\n' "$TS" "$1" "$2"; }

d="$SCRATCH/shape-field"; mkdir -p "$d"
{ line_ok supervisor "started"; printf '{"level":"info","component":"supervisor","msg":"no timestamp"}\n'; } >"$d/supervisor.log"
expect_hit shape-missing-ts "$d/supervisor.log" 2 "ts missing" "" -- --log-shape "$d" --expect-workloads supervisor
{ line_ok mapper "started"; line_ok mapper "ok"; printf '{%s,"level":"info","msg":"no component"}\n' "$TS"; } >"$d/mapper.log"
expect_hit shape-missing-component "$d/mapper.log" 3 "component is None" "" -- --log-shape "$d" --expect-workloads supervisor,mapper
{ printf '{%s,"level":"notice","component":"allocator","msg":"x"}\n' "$TS"; } >"$d/allocator.log"
expect_hit shape-bad-level "$d/allocator.log" 1 "level missing" "" -- --log-shape "$d" --expect-workloads allocator
printf '{"ts":"2026-09-25T02:04:21+02:00","level":"info","component":"deployer","msg":"local time"}\n' >"$d/deployer.log"
expect_hit shape-non-utc "$d/deployer.log" 1 "ts missing or not UTC" "" -- --log-shape "$d" --expect-workloads deployer
printf '{%s,"level":"info","component":"srl-provider"}\n' "$TS" >"$d/srl-provider.log"
expect_hit shape-missing-msg "$d/srl-provider.log" 1 "msg missing" "" -- --log-shape "$d" --expect-workloads srl-provider

d="$SCRATCH/shape-nonjson"; mkdir -p "$d"
{ line_ok mapper "ok"; printf '\033[92m23:03:10 - LiteLLM:INFO\033[0m: utils.py:3296 - \n'; } >"$d/mapper.log"
expect_hit shape-nonjson "$d/mapper.log" 2 "not one JSON object" "" -- --log-shape "$d" --expect-workloads mapper
{ line_ok srl-provider "ok"; printf 'I0924 21:19:47.479597       1 leaderelection.go:258] "Attempting to acquire leader lease..."\n'; } >"$d/srl-provider.log"
expect_hit shape-klog "$d/srl-provider.log" 2 "not one JSON object" "" -- --log-shape "$d" --expect-workloads srl-provider

d="$SCRATCH/shape-request"; mkdir -p "$d"
{ line_ok supervisor 'ok'; printf '{%s,"level":"info","component":"supervisor","msg":"stage mapper","thread_id":"t-1"}\n' "$TS"; } >"$d/supervisor.log"
expect_hit shape-request-thread "$d/supervisor.log" 2 "request line without correlation_id (it carries thread_id)" "" \
  -- --log-shape "$d" --expect-workloads supervisor
line_ok supervisor '10.244.0.1:39498 - \"POST /agent/prompt/stream HTTP/1.1\" 200' >"$d/supervisor.log"
expect_hit shape-request-access "$d/supervisor.log" 1 "request line without correlation_id (it serves POST /agent/prompt/stream)" "" \
  -- --log-shape "$d" --expect-workloads supervisor
line_ok mapper 'model call 1: model endpoint: base URL https://api.example.net/v1' >"$d/mapper.log"
expect_hit shape-request-model-call "$d/mapper.log" 1 "request line without correlation_id" "" -- --log-shape "$d" --expect-workloads mapper
line_ok mapper 'mapper: interpreted service 18c43038e0d8487 (vlan)' >"$d/mapper.log"
expect_hit shape-request-service-id "$d/mapper.log" 1 "request line without correlation_id (it names a service identifier in msg)" "" \
  -- --log-shape "$d" --expect-workloads mapper
printf '{%s,"level":"info","component":"srl-provider","msg":"reconciled","kind":"Network","namespace":"default","name":"migr-18c43038e0d8487"}\n' "$TS" >"$d/srl-provider.log"
expect_hit shape-request-provider "$d/srl-provider.log" 1 "request line without correlation_id (it names a service identifier in name)" "" \
  -- --log-shape "$d" --expect-workloads srl-provider
printf '{%s,"level":"info","component":"srl-provider","msg":"x","correlation_id":"ABC"}\n' "$TS" >"$d/srl-provider.log"
expect_hit shape-bad-correlation-id "$d/srl-provider.log" 1 "correlation_id is not 32 lowercase hex" "" \
  -- --log-shape "$d" --expect-workloads srl-provider

d="$SCRATCH/shape-missing"; mkdir -p "$d"
line_ok supervisor ok >"$d/supervisor.log"
run --log-shape "$d"
[[ $RC -eq 1 ]] && grep -q "FAIL mapper: no log file" <<<"$OUT" && pass "shape-missing: every first-party workload must have a log" \
  || fail "shape-missing (rc=$RC)" "$OUT"

# known secrets are masked in shape excerpts too
d="$SCRATCH/shape-mask"; mkdir -p "$d"
printf 'plain text %s\n' "$KEY" >"$d/mapper.log"
expect_hit shape-mask-secret "$d/mapper.log" 1 "not one JSON object" "$KEY" \
  -- --secrets-from-file "$SCRATCH/known/secrets" --log-shape "$d" --expect-workloads mapper

# ------------------------------------------------------------------ positives
d="$SCRATCH/redacted"; mkdir -p "$d"
cat >"$d/redacted.log" <<'EOF'
Authorization: Basic ***
authorization: Bearer ***
{"msg":"header Authorization: Bearer [REDACTED]"}
base url https://***@api.example.net/v1?api_key=***
base url https://%5BREDACTED%5D@api.example.net/v1
password=[REDACTED] token=***
{"password":"***","http.request.header.authorization":"Basic ***","credentials":"[REDACTED]"}
-----BEGIN PRIVATE KEY----- is how a key starts (no block here)
EOF
run "$d"
[[ $RC -eq 0 ]] && pass "redacted forms (***, [REDACTED], %5BREDACTED%5D) pass" || fail "redacted forms (rc=$RC)" "$OUT"

d="$SCRATCH/clean"; mkdir -p "$d"
{
  line_ok supervisor '10.244.0.1:47496 - \"GET /health HTTP/1.1\" 200'
  line_ok supervisor 'Uvicorn running on http://0.0.0.0:9090 (Press CTRL+C to quit)'
  line_ok supervisor '10.244.0.9:5150 - \"GET /suggested-prompts HTTP/1.1\" 200'
  printf '{%s,"level":"warn","component":"supervisor","msg":"worker unreachable: allocator",%s,"thread_id":"t-9"}\n' "$TS" "$CID"
} >"$d/supervisor.log"
printf '{%s,"level":"info","component":"srl-provider","msg":"reconciled","kind":"Network","namespace":"default","name":"migr-18c43038e0d8487",%s}\n' "$TS" "$CID" >"$d/srl-provider.log"
line_ok srl-provider "Starting workers" >"$d/allocation-authority.log"
line_ok intent-translator "intent-translator listening" >"$d/intent-translator.log"
printf '{"ts":"2026-09-24T23:03:16.649834593Z","level":"info","component":"intent-translator","msg":"translation emitted","networks":["migr-5ad7a6e2db884c4"],%s}\n' "$CID" >>"$d/intent-translator.log"
line_ok mapper 'mapper registered on SLIM' >"$d/mapper.log"
printf '{%s,"level":"info","component":"mapper","msg":"model call 1: base URL https://***@api.example.net/v1",%s}\n' "$TS" "$CID" >>"$d/mapper.log"
line_ok allocator 'allocator registered on SLIM' >"$d/allocator.log"
: >"$d/deployer.log"
printf '2026-09-24T19:03:46.123Z ui-server POST /api/agent/prompt/stream -> 200 266ms\n' >"$d/ui.log"
run --log-shape "$d" "$d"
if [[ $RC -eq 0 ]] && grep -q "log-shape: PASS 7 workload(s)" <<<"$OUT" && grep -q "ui.log is not a first-party workload log" <<<"$OUT"; then
  pass "clean: scan and shape pass; ui.log named, not shape-checked"
else
  fail "clean (rc=$RC)" "$OUT"
fi
grep -q "log-shape: supervisor: 1 file(s), 4 line(s), 1 request line(s), 0 violation(s)" <<<"$OUT" \
  && pass "clean: per-workload counts reported (a GET is not a request line)" || fail "clean counts" "$OUT"

# multi-pod and previous-container naming
d2="$SCRATCH/clean-multi"; cp -r "$d" "$d2"; mv "$d2/mapper.log" "$d2/mapper@mapper-abc-1.log"
line_ok mapper 'restarted' >"$d2/mapper@mapper-abc-1.previous.log"
run --log-shape "$d2"
[[ $RC -eq 0 ]] && grep -q "log-shape: mapper: 2 file(s)" <<<"$OUT" && pass "workload@pod and .previous names" || fail "multi-pod names (rc=$RC)" "$OUT"

# gz input
d="$SCRATCH/gz"; mkdir -p "$d/hit" "$d/clean"
printf 'a\nb\nc\nAuthorization: Basic dXNlcjpwYXNz\n' | gzip >"$d/hit/trace.log.gz"
expect_hit gz-hit "$d/hit/trace.log.gz" 4 authorization-header dXNlcjpwYXNz -- "$d/hit"
printf '{"spans":[{"name":"request","attributes":{"correlation_id":"0af7651916cd43dd8448eb211c80319c"}}]}\n' | gzip >"$d/clean/traces.json.gz"
{ line_ok supervisor ok; } | gzip >"$d/clean/supervisor.log.gz"
run --log-shape "$d/clean" --expect-workloads supervisor "$d/clean"
[[ $RC -eq 0 ]] && grep -q "log-shape: supervisor: 1 file(s), 1 line(s)" <<<"$OUT" && pass "gz: clean gz passes both checks" \
  || fail "gz clean (rc=$RC)" "$OUT"
{ line_ok supervisor ok; printf 'not json\n'; } | gzip >"$d/clean/supervisor.log.gz"
expect_hit gz-shape "$d/clean/supervisor.log.gz" 2 "not one JSON object" "" -- --log-shape "$d/clean" --expect-workloads supervisor

# --collect against a stub kubectl: read-only verbs only, output scanned and shape-checked
d="$SCRATCH/collect"; mkdir -p "$d/bin"
cat >"$d/bin/kubectl" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$d/calls"
args=" \$* "
case "\$args" in
  *" get namespace "*) exit 0 ;;
  *" get deploy "*) printf 'app=x,' ;;
  *" get pods "*) echo "pod-1" ;;
  *" logs "*"--previous"*) exit 1 ;;
  *" logs "*" -c ui "*) printf '2026-09-24T19:03:46.123Z ui-server GET / -> 200\n' ;;
  *" logs "*" -c "*) c="\${args##* -c }"; c="\${c%% *}"; [[ "\$c" == allocation-authority ]] && c=srl-provider
                    printf '{"ts":"2026-09-25T00:00:00Z","level":"info","component":"%s","msg":"ok"}\n' "\$c" ;;
  *) echo "unexpected: \$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$d/bin/kubectl"
RC=0; OUT="$(KUBECTL="$d/bin/kubectl" KUBE_CONTEXT=kind-test bash "$CS" --collect "$d/out" 2>&1)" || RC=$?
if [[ $RC -eq 0 ]] && grep -q "log-shape: PASS 7 workload(s)" <<<"$OUT" && [[ -f "$d/out/extra/ui.log" && -f "$d/out/collected.tsv" ]]; then
  pass "collect: writes <workload>.log + extra/ui.log + collected.tsv, then scans and shape-checks"
else
  fail "collect (rc=$RC)" "$OUT"
fi
if grep -vqE -- '--context kind-test( --request-timeout=10s)? (-n [a-z-]+ )?(get|logs) ' "$d/calls"; then
  fail "collect: a kubectl call that is not a read under the given context" "$(cat "$d/calls")"
else
  pass "collect: only get/logs under KUBE_CONTEXT"
fi

# the helper keeps one pattern list: it loads agents/common/guards/redaction.py, it does not copy it
if grep -qE 're\.compile\(r?"\(\?i\)\(\\b\(\?:proxy-\)' "$ROOT/scripts/ci/credential_scan.py"; then
  fail "the helper carries its own copy of the FR-079 patterns"
else
  pass "one FR-079 pattern list (agents/common/guards/redaction.py, loaded by path)"
fi

if [[ $fails -gt 0 ]]; then
  printf 'credential_scan_test: %d case(s) FAILED\n' "$fails"
  exit 1
fi
printf 'credential_scan_test: all cases passed\n'
