#!/usr/bin/env bash
# dotenv.sh — load a .env file without executing it, and set the lifecycle
# scripts' non-interactive defaults (T024, FR-010).
#
# dotenv::load [file]
#   Reads KEY=VALUE lines (optional `export ` prefix, `#` comments, optional
#   matching single or double quotes). The file is PARSED, never sourced: a
#   value such as $(rm -rf ~) or `id` is stored as that literal text and no
#   expansion or command substitution ever happens. Keys must match
#   [A-Za-z_][A-Za-z0-9_]*; any other line is reported and skipped. A variable
#   already set in the environment wins over the file (an explicit export or a
#   flag's variable is never silently overridden). A missing file is not an
#   error — the scripts run on defaults. Default file: <repo root>/.env,
#   overridden by AGENTIC_NETOPS_ENV_FILE.
#
# dotenv::noninteractive
#   Exports the defaults that keep every tool the scripts call from prompting:
#   no terminal prompt from git, no apt/dpkg dialog, no pager. The scripts must
#   never wait on a human (FR-010); anything that needs a decision is a flag.

[[ -n "${__AGENTIC_NETOPS_DOTENV_SH:-}" ]] && return 0
__AGENTIC_NETOPS_DOTENV_SH=1

dotenv::load() {
  local file="${1:-${AGENTIC_NETOPS_ENV_FILE:-}}"
  if [[ -z "$file" ]]; then
    file="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/.env"
  fi
  [[ -f "$file" ]] || return 0

  local line key value n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"                 # ltrim
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == export[[:space:]]* ]] && line="${line#export}" && line="${line#"${line%%[![:space:]]*}"}"
    if [[ "$line" != *=* ]]; then
      printf 'dotenv: %s:%d: not KEY=VALUE, skipped\n' "$file" "$n" >&2
      continue
    fi
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"                     # rtrim key
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      printf 'dotenv: %s:%d: invalid key, skipped\n' "$file" "$n" >&2
      continue
    fi
    value="${value#"${value%%[![:space:]]*}"}"
    if [[ ${#value} -ge 2 && "$value" == \"*\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ ${#value} -ge 2 && "$value" == \'*\' ]]; then
      value="${value:1:${#value}-2}"
    else
      value="${value%%[[:space:]]#*}"                        # trailing comment
      value="${value%"${value##*[![:space:]]}"}"
    fi
    if [[ -z "${!key+x}" ]]; then
      printf -v "$key" '%s' "$value"                         # literal assignment, no expansion
      export "${key?}"
    fi
  done <"$file"
  DOTENV_LOADED_FROM="$file"
  export DOTENV_LOADED_FROM
}

dotenv::noninteractive() {
  export DEBIAN_FRONTEND=noninteractive
  export GIT_TERMINAL_PROMPT=0
  export PAGER=cat
  export SYSTEMD_PAGER=cat
  export KUBECTL_EXTERNAL_DIFF="${KUBECTL_EXTERNAL_DIFF:-diff -u}"
  # A script that reads a confirmation would block; stdin is never the operator.
  export AGENTIC_NETOPS_NONINTERACTIVE=1
}
