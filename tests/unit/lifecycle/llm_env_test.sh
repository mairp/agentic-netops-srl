#!/usr/bin/env bash
# llm_env_test.sh — scripts/lib/llm_env.sh maps .env's provider-native LLM settings (.env.example)
# onto AGENTIC_NETOPS_LLM_*: each provider block picks its own key and endpoint, an input already
# set always wins, an unserved provider is refused, and no value is ever printed.
# .env.example is also checked: every provider block it shows is one llm_env.sh maps.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$ROOT/scripts/lib"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    | /'; }

# run <env assignments...> — resolve in a child whose environment is ONLY the given assignments
# (every inherited variable is unset first, so a real key of the host can never take part);
# prints the four inputs and the log.
run() {
  env -i PATH="$PATH" HOME="$HOME" bash -c '
    log="$1"; lib="$2"; shift 2
    for v in $(compgen -e); do case "$v" in PATH|HOME) ;; *) unset "$v" ;; esac; done
    for a in "$@"; do export "$a"; done
    source "$lib/llm_env.sh"
    llm_env::resolve 2>"$log"; rc=$?
    printf "rc=%s\nMODEL=%s\nKEY=%s\nBASE=%s\nGW=%s\n" "$rc" "${AGENTIC_NETOPS_LLM_MODEL:-}" \
      "${AGENTIC_NETOPS_LLM_API_KEY:-}" "${AGENTIC_NETOPS_LLM_BASE_URL:-}" "${AGENTIC_NETOPS_LLM_GATEWAY:-}"
    printf "LOG=%s\n" "$(tr "\n" " " <"$log")"' _ "$(mktemp)" "$LIB" "$@"
}
# A failure shows every field but the key's value: a key never reaches a log, even a test's.
shown() { sed -E 's/^KEY=.+$/KEY=<set, value not shown>/' <<<"$1"; }
expect() { # name, output, want-lines...
  local name="$1" out="$2" w; shift 2
  for w in "$@"; do grep -qxF -- "$w" <<<"$out" || { fail "$name (want '${w%%=*}' to match)" "$(shown "$out")"; return; }; done
  pass "$name"
}

out="$(run LLM_MODEL=openai/gpt-4o OPENAI_API_KEY=sk-test-openai-0001)"
expect "openai: model and OPENAI_API_KEY, no base URL (the provider's default)" "$out" \
  rc=0 MODEL=openai/gpt-4o KEY=sk-test-openai-0001 BASE= GW=

out="$(run LLM_MODEL=openai/gpt-5 OPENAI_API_KEY=gw-key-0002 OPENAI_BASE_URL=https://gw.example.invalid/v1)"
expect "openai-compatible gateway: OPENAI_BASE_URL becomes the base URL" "$out" \
  rc=0 MODEL=openai/gpt-5 KEY=gw-key-0002 BASE=https://gw.example.invalid/v1

out="$(run LLM_MODEL=litellm_proxy/sonnet LITELLM_PROXY_API_KEY=lp-key-0003 LITELLM_PROXY_API_BASE=http://proxy.example.invalid:4000)"
expect "litellm proxy: key, base URL and the gateway name" "$out" \
  rc=0 MODEL=litellm_proxy/sonnet KEY=lp-key-0003 BASE=http://proxy.example.invalid:4000 GW=litellm-proxy

out="$(run LLM_MODEL=nvidia_nim/meta/llama-3.1-8b-instruct NVIDIA_NIM_API_KEY=nim-key-0004 NVIDIA_NIM_API_BASE=https://nim.example.invalid/v1)"
expect "nvidia nim: its own key and base" "$out" rc=0 KEY=nim-key-0004 BASE=https://nim.example.invalid/v1

for p in anthropic:ANTHROPIC_API_KEY groq:GROQ_API_KEY gemini:GEMINI_API_KEY; do
  out="$(run LLM_MODEL="${p%%:*}/m" "${p##*:}=k-${p%%:*}-0005")"
  expect "${p%%:*}: ${p##*:}" "$out" rc=0 "MODEL=${p%%:*}/m" "KEY=k-${p%%:*}-0005"
done

out="$(run LLM_MODEL=openai/gpt-4o OPENAI_API_KEY=from-env-file AGENTIC_NETOPS_LLM_API_KEY=exported-wins AGENTIC_NETOPS_LLM_MODEL=openai/kept)"
expect "an AGENTIC_NETOPS_LLM_* input already set wins over the provider variables" "$out" \
  rc=0 MODEL=openai/kept KEY=exported-wins

out="$(run OPENAI_API_KEY=unused)"
expect "no LLM_MODEL: nothing is filled (the stored Secret keeps its values)" "$out" rc=0 MODEL= KEY=

out="$(run LLM_MODEL=azure/deploy AZURE_API_KEY=az-0006)"
if grep -qx rc=1 <<<"$out" && grep -qx KEY= <<<"$out" && grep -q "litellm_proxy" <<<"$out"; then
  pass "azure/ is refused, nothing exported, the proxy named as the way"
else fail "azure/ is refused" "$(shown "$out")"; fi

out="$(run LLM_MODEL=gpt-4o OPENAI_API_KEY=k)"
if grep -qx rc=1 <<<"$out"; then pass "a model without a provider prefix is refused"; else fail "a bare model is refused" "$(shown "$out")"; fi

out="$(run LLM_MODEL=litellm_proxy/m LITELLM_PROXY_API_KEY=k)"
if grep -qx rc=1 <<<"$out" && grep -q LITELLM_PROXY_API_BASE <<<"$out"; then
  pass "litellm proxy without its base URL is refused, naming LITELLM_PROXY_API_BASE"
else fail "litellm proxy without base is refused" "$(shown "$out")"; fi

out="$(run LLM_MODEL=openai/gpt-4o OPENAI_API_KEY=sk-test-secret-value-0007 OPENAI_BASE_URL=https://u:pw@gw.example.invalid/v1)"
log="$(grep '^LOG=' <<<"$out")"
if [[ "$log" != *sk-test-secret-value-0007* && "$log" != *pw@* && "$log" == *"values not shown"* ]]; then
  pass "the log names what was filled, never a value"
else fail "the log never carries a value (log not shown: it may hold one)"; fi

# .env.example: every LLM_MODEL example's provider is one llm_env.sh maps
bad=""
while IFS= read -r m; do
  prov="${m%%/*}"
  grep -qE "^[[:space:]]+${prov}\)" "$LIB/llm_env.sh" || bad+=" $prov"
done < <(grep -oE '^# LLM_MODEL="[a-z_]+/' "$ROOT/.env.example" | sed 's/^# LLM_MODEL="//')
if [[ -z "$bad" ]]; then pass ".env.example shows only providers llm_env.sh maps"; else fail ".env.example provider not mapped:$bad"; fi
if grep -qE '^[[:space:]]*[A-Z_]*(API_KEY|PASSWORD|SECRET)=[^<[:space:]]' "$ROOT/.env.example"; then
  fail ".env.example carries a live-looking credential value"
else pass ".env.example carries placeholders only, never a credential value"; fi

echo "llm_env_test: $fails failure(s)"
[[ "$fails" -eq 0 ]]
