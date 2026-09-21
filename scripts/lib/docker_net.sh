#!/usr/bin/env bash
# docker_net.sh — the owned, labelled management network (T034; FR-008, FR-010, R-12,
# data-model.md §2, evidence/01 §4.5).
#
#   docker_net::ensure <name> <cidr>
#       Creates the bridge network <name> on <cidr> labelled agentic-netops.io/owned-by=<cluster>.
#       Idempotent: an existing network that is OWNED and on exactly <cidr> is success with no
#       change; an existing network that is not owned is refused (never adopted, never modified);
#       an owned network on another CIDR is refused naming both. Dynamic address assignment is
#       limited to the upper half of <cidr> (--ip-range) so the Kind node attachments never take
#       the fixed lab addresses (.11/.12 spines, .21/.22 leaves, .31/.32 endpoints). No MTU option
#       is set: the management network stays at Docker's default (R-12).
#   docker_net::remove <name>
#       Removes <name> only when it is owned. Absent is success (a teardown from any phase). A
#       network with containers still attached is refused naming them — nothing is disconnected
#       on its behalf.
#   docker_net::exists <name>
#
# DOCKER overrides the client (tests). CLUSTER_NAME selects the ownership value.

[[ -n "${__AGENTIC_NETOPS_DOCKER_NET_SH:-}" ]] && return 0
__AGENTIC_NETOPS_DOCKER_NET_SH=1

# shellcheck source=log.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/log.sh"
# shellcheck source=ownership.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/ownership.sh"
# shellcheck source=preflight.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/preflight.sh"

docker_net::_docker() { "${DOCKER:-docker}" "$@"; }

docker_net::exists() { docker_net::_docker network inspect "$1" >/dev/null 2>&1; }

# docker_net::_int2ip <int>
docker_net::_int2ip() {
  local n="$1"
  printf '%d.%d.%d.%d' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) $(( (n >> 8) & 255 )) $(( n & 255 ))
}

# docker_net::_plan <cidr> — prints "<gateway> <ip-range>": gateway .1, dynamic range = upper half.
docker_net::_plan() {
  local cidr="$1" first last mask
  mask="${cidr#*/}"
  read -r first last < <(preflight::_range "$cidr")
  printf '%s %s/%d\n' "$(docker_net::_int2ip $(( first + 1 )))" \
    "$(docker_net::_int2ip $(( first + (last - first + 1) / 2 )))" $(( mask + 1 ))
}

docker_net::ensure() {
  if [[ $# -ne 2 ]]; then log::error "usage: docker_net::ensure <name> <cidr>"; return 2; fi
  local name="$1" cidr="$2"
  if ! preflight::_valid_cidr "$cidr"; then
    log::error "docker_net: '$cidr' is not an IPv4 CIDR"
    return 2
  fi
  if docker_net::exists "$name"; then
    ownership::require_docker_network "$name" || return 1
    local have
    have="$(docker_net::_docker network inspect "$name" | jq -r '[.[0].IPAM.Config[]?.Subnet | select(contains(":") | not)] | join(",")')"
    if [[ "$have" != "$cidr" ]]; then
      log::error "docker_net: owned network $name exists on '${have:-<none>}', requested $cidr:" \
        "re-run with MGMT_CIDR=${have} or remove it first (scripts/off.sh)"
      return 1
    fi
    log::info "docker_net: $name exists, owned, on $cidr (no change)"
    return 0
  fi
  local gw range
  read -r gw range < <(docker_net::_plan "$cidr")
  docker_net::_docker network create --driver bridge \
    --subnet "$cidr" --gateway "$gw" --ip-range "$range" \
    --label "$(ownership::selector)" --label "agentic-netops.io/role=management" \
    "$name" >/dev/null || { log::error "docker_net: creating $name on $cidr failed"; return 1; }
  log::info "docker_net: created $name on $cidr (gateway $gw, dynamic range $range, label $(ownership::selector))"
}

docker_net::remove() {
  if [[ $# -ne 1 ]]; then log::error "usage: docker_net::remove <name>"; return 2; fi
  local name="$1"
  if ! docker_net::exists "$name"; then
    log::info "docker_net: $name absent (nothing to remove)"
    return 0
  fi
  ownership::require_docker_network "$name" || return 1
  local attached
  attached="$(docker_net::_docker network inspect "$name" | jq -r '[.[0].Containers // {} | .[] | .Name] | join(" ")')"
  if [[ -n "$attached" ]]; then
    log::error "docker_net: refusing to remove $name: containers still attached: $attached" \
      "(remove the lab and the cluster first; nothing is disconnected on their behalf)"
    return 1
  fi
  docker_net::_docker network rm "$name" >/dev/null || { log::error "docker_net: removing $name failed"; return 1; }
  log::info "docker_net: removed $name"
}
