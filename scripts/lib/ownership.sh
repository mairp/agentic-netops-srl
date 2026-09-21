#!/usr/bin/env bash
# ownership.sh — exact ownership-label checks (T024, FR-010, data-model.md §2).
#
# The lifecycle scripts refuse to touch a resource they do not own. A resource
# is owned when it carries the ownership label with EXACTLY the expected value:
#
#   agentic-netops.io/owned-by=<cluster name>
#
# The comparison is a full string equality — never a prefix, glob, substring
# or case-folded match — so a cluster named `agentic-netops` never claims the
# resources of `agentic-netops-2`, and a resource with no label is unowned. An
# object that cannot be read is unowned too: the check fails closed.
#
#   ownership::key / ownership::value / ownership::selector
#   ownership::k8s_owned <kind> <name> [namespace]           exit 0 when owned
#   ownership::require_k8s <kind> <name> [namespace]         refuses (exit 1, names it)
#   ownership::docker_network_owned <name> / ownership::require_docker_network <name>
#   ownership::docker_container_owned <name> / ownership::require_docker_container <name>
#   ownership::guard <kind> <name> <namespace|-> -- <cmd…>   runs cmd only when owned
#
# OWNERSHIP_LABEL_KEY and OWNERSHIP_LABEL_VALUE override the key and value; the
# value defaults to CLUSTER_NAME, then to the lab's default cluster name.
# KUBECTL / DOCKER override the clients (for tests); KUBE_CONTEXT pins --context.

[[ -n "${__AGENTIC_NETOPS_OWNERSHIP_SH:-}" ]] && return 0
__AGENTIC_NETOPS_OWNERSHIP_SH=1

# shellcheck source=log.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/log.sh"

ownership::key()   { printf '%s' "${OWNERSHIP_LABEL_KEY:-agentic-netops.io/owned-by}"; }
ownership::value() { printf '%s' "${OWNERSHIP_LABEL_VALUE:-${CLUSTER_NAME:-agentic-netops}}"; }
ownership::selector() { printf '%s=%s' "$(ownership::key)" "$(ownership::value)"; }

ownership::_kubectl() {
  local -a ctx=()
  [[ -n "${KUBE_CONTEXT:-}" ]] && ctx=(--context "$KUBE_CONTEXT")
  "${KUBECTL:-kubectl}" "${ctx[@]}" "$@"
}

# ownership::_label_of_k8s <kind> <name> [namespace] — prints the label value.
ownership::_label_of_k8s() {
  local kind="$1" name="$2" ns="${3:-}"
  local -a nsa=()
  [[ -n "$ns" && "$ns" != "-" ]] && nsa=(-n "$ns")
  ownership::_kubectl get "$kind" "$name" "${nsa[@]}" -o json 2>/dev/null \
    | jq -er --arg k "$(ownership::key)" '.metadata.labels[$k] // empty'
}

ownership::k8s_owned() {
  local got
  got="$(ownership::_label_of_k8s "$@")" || return 1
  [[ "$got" == "$(ownership::value)" ]]
}

ownership::require_k8s() {
  local kind="$1" name="$2" ns="${3:-}"
  local got
  got="$(ownership::_label_of_k8s "$kind" "$name" "$ns")" || got=""
  if [[ "$got" == "$(ownership::value)" ]]; then return 0; fi
  log::error "refusing to touch ${kind}/${name}${ns:+ in ${ns}}: not owned by this platform" \
    "(label $(ownership::key) is '${got:-<absent>}', expected exactly '$(ownership::value)')"
  return 1
}

ownership::_label_of_docker() {
  local what="$1" name="$2"
  "${DOCKER:-docker}" "$what" inspect "$name" 2>/dev/null \
    | jq -er --arg k "$(ownership::key)" '.[0].Labels[$k] // .[0].Config.Labels[$k] // empty'
}

ownership::docker_network_owned() {
  local got; got="$(ownership::_label_of_docker network "$1")" || return 1
  [[ "$got" == "$(ownership::value)" ]]
}

ownership::docker_container_owned() {
  local got; got="$(ownership::_label_of_docker container "$1")" || return 1
  [[ "$got" == "$(ownership::value)" ]]
}

ownership::_require_docker() {
  local what="$1" name="$2" got
  got="$(ownership::_label_of_docker "$what" "$name")" || got=""
  if [[ "$got" == "$(ownership::value)" ]]; then return 0; fi
  log::error "refusing to touch docker ${what} ${name}: not owned by this platform" \
    "(label $(ownership::key) is '${got:-<absent>}', expected exactly '$(ownership::value)')"
  return 1
}
ownership::require_docker_network()   { ownership::_require_docker network "$1"; }
ownership::require_docker_container() { ownership::_require_docker container "$1"; }

ownership::guard() {
  if [[ $# -lt 5 || "$4" != "--" ]]; then
    log::error "usage: ownership::guard <kind> <name> <namespace|-> -- <cmd…>"
    return 2
  fi
  local kind="$1" name="$2" ns="$3"; shift 4
  [[ "$ns" == "-" ]] && ns=""
  ownership::require_k8s "$kind" "$name" "$ns" || return 1
  "$@"
}
