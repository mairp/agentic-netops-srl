#!/usr/bin/env bash
# llm_env.sh — map the provider-native LLM settings of .env (the AGNTCY reference apps' layout, see
# .env.example) onto the tier's own inputs AGENTIC_NETOPS_LLM_{MODEL,API_KEY,BASE_URL,GATEWAY},
# which scripts/lib/intent_secrets.sh writes into Secret/llm-provider.
#
# llm_env::resolve
#   Runs after dotenv::load. LLM_MODEL=<provider>/<model> names the model; its prefix picks which
#   provider-native variables hold the key and the base URL:
#
#     litellm_proxy/…   LITELLM_PROXY_API_KEY   LITELLM_PROXY_API_BASE (required; GATEWAY=litellm-proxy)
#     openai/…          OPENAI_API_KEY          OPENAI_BASE_URL or OPENAI_API_BASE (optional)
#     anthropic/…       ANTHROPIC_API_KEY       ANTHROPIC_API_BASE (optional)
#     groq/…            GROQ_API_KEY            —
#     nvidia_nim/…      NVIDIA_NIM_API_KEY      NVIDIA_NIM_API_BASE (optional)
#     gemini/…          GEMINI_API_KEY          —
#
#   An AGENTIC_NETOPS_LLM_* input already set (exported, or written in .env) always wins; only the
#   unset ones are filled. An unset LLM_MODEL leaves everything as it is (the stored Secret keeps
#   its values). A provider this tier's client cannot serve (azure/ needs an API version it does
#   not pass; oauth2/ needs a token flow) is refused, naming the alternatives. Values are never
#   printed: the one info line names the provider and which inputs were filled.
#
# Returns 0, or 1 on a refusal (nothing is exported then).

[[ -n "${__AGENTIC_NETOPS_LLM_ENV_SH:-}" ]] && return 0
__AGENTIC_NETOPS_LLM_ENV_SH=1

llm_env::_log() {
  if declare -F "log::$1" >/dev/null; then "log::$1" "${@:2}"; else printf '[%s] %s\n' "$1" "${*:2}" >&2; fi
}

llm_env::resolve() {
  local model="${LLM_MODEL:-}"
  [[ -n "$model" ]] || return 0
  local provider="${model%%/*}"
  [[ "$model" == */* ]] || provider=""
  local key_var="" base_vars=() gateway=""
  case "$provider" in
    litellm_proxy) key_var=LITELLM_PROXY_API_KEY; base_vars=(LITELLM_PROXY_API_BASE); gateway=litellm-proxy ;;
    openai)        key_var=OPENAI_API_KEY;        base_vars=(OPENAI_BASE_URL OPENAI_API_BASE) ;;
    anthropic)     key_var=ANTHROPIC_API_KEY;     base_vars=(ANTHROPIC_API_BASE) ;;
    groq)          key_var=GROQ_API_KEY ;;
    nvidia_nim)    key_var=NVIDIA_NIM_API_KEY;    base_vars=(NVIDIA_NIM_API_BASE) ;;
    gemini)        key_var=GEMINI_API_KEY ;;
    azure|oauth2)
      llm_env::_log error "llm_env: LLM_MODEL provider '${provider}' is not served by this tier's model client" \
        "(it passes one key and one base URL). Use openai/ against an OpenAI-compatible gateway, or" \
        "litellm_proxy/ in front of it (.env.example). Nothing was changed."
      return 1 ;;
    *)
      llm_env::_log error "llm_env: LLM_MODEL must be <provider>/<model> with a provider of .env.example" \
        "(litellm_proxy, openai, anthropic, groq, nvidia_nim, gemini); got provider '${provider:-none}'. Nothing was changed."
      return 1 ;;
  esac

  local base="" v
  for v in "${base_vars[@]}"; do
    if [[ -n "${!v:-}" ]]; then base="${!v}"; break; fi
  done
  if [[ "$provider" == litellm_proxy && -z "$base" && -z "${AGENTIC_NETOPS_LLM_BASE_URL:-}" ]]; then
    llm_env::_log error "llm_env: LLM_MODEL=${model} goes through a LiteLLM proxy but LITELLM_PROXY_API_BASE is not set. Nothing was changed."
    return 1
  fi

  local filled=()
  if [[ -z "${AGENTIC_NETOPS_LLM_MODEL:-}" ]]; then
    # Passed through as written: LiteLLM routes litellm_proxy/<model> itself, given the proxy as
    # the base URL (which the tier always passes explicitly).
    export AGENTIC_NETOPS_LLM_MODEL="$model"; filled+=(MODEL)
  fi
  if [[ -z "${AGENTIC_NETOPS_LLM_API_KEY:-}" && -n "${!key_var:-}" ]]; then
    export AGENTIC_NETOPS_LLM_API_KEY="${!key_var}"; filled+=(API_KEY)
  fi
  if [[ -z "${AGENTIC_NETOPS_LLM_BASE_URL:-}" && -n "$base" ]]; then
    export AGENTIC_NETOPS_LLM_BASE_URL="$base"; filled+=(BASE_URL)
  fi
  if [[ -n "$gateway" && -z "${AGENTIC_NETOPS_LLM_GATEWAY:-}" ]]; then
    export AGENTIC_NETOPS_LLM_GATEWAY="$gateway"; filled+=(GATEWAY)
  fi
  if [[ -z "${AGENTIC_NETOPS_LLM_API_KEY:-}" ]]; then
    llm_env::_log warn "llm_env: LLM_MODEL=${model} but ${key_var} is not set (nor AGENTIC_NETOPS_LLM_API_KEY):" \
      "the stored llm-provider key, if any, is kept"
  fi
  local list="" f
  for f in "${filled[@]}"; do list+="${list:+, }AGENTIC_NETOPS_LLM_${f}"; done
  llm_env::_log info "llm_env: provider ${provider} from LLM_MODEL; filled ${list:-no input (all were already set)} (values not shown)"
  return 0
}
