#!/usr/bin/env bash
# containerlab.sh — deploy, wait for and destroy the one reference lab (T034; FR-001, FR-002,
# FR-008, FR-010, FR-108, AD-57; evidence/01 §4, §6.1).
#
#   containerlab::deploy
#       Deploys lab/topology.clab.yml onto the owned management network (which must already
#       exist — NetworkReady). Exports CLUSTER_NAME (the containers' ownership label), MGMT_CIDR and
#       CLAB_MGMT_PREFIX (the fixed addresses follow MGMT_CIDR). Idempotent: all six nodes present,
#       running and owned → no change; none present → `containerlab deploy`; some present (a
#       half-finished deploy) and all owned → `containerlab deploy --reconfigure`. Any lab
#       container that is not owned is refused and nothing is touched.
#   containerlab::wait_gnmi_accept [timeout_s]
#       Waits (bounded; default CONTAINERLAB_GNMI_TIMEOUT or 600 s — boot to gNMI-ready is ~3 min)
#       until TCP port 57400 of every SR Linux node ACCEPTS a connection from the host. The probe
#       is a credential-less TCP connect through bash's /dev/tcp — no gNMI RPC, no TLS handshake
#       with credentials, and no device client: scripts/ may not invoke one (FR-108), and that the
#       devices ANSWER gNMI is what TargetsReady shows through the device-configuration layer's own
#       session (AD-57).
#   containerlab::destroy
#       `containerlab destroy --cleanup` (which also removes the lab directory, CA included) when
#       every lab container is owned; absent is success; any unowned lab container is refused.
#   containerlab::device_addresses   "<node> <ip>" per SR Linux node, from MGMT_CIDR
#   containerlab::lab_dir            the lab directory containerlab writes (.tls/ca/ca.pem lives there)
#   containerlab::lab_containers     names of the lab's containers (label containerlab=<lab>)
#
# LAB_NAME (agentic-netops-fabric), MGMT_NET (agentic-netops-mgmt), MGMT_CIDR (172.25.25.0/24),
# CLAB_TOPOLOGY (lab/topology.clab.yml), CLAB_LABDIR_BASE (containerlab's own variable: the
# directory the lab directory is created in; default the topology's directory).
# CONTAINERLAB, DOCKER override the clients; CONTAINERLAB_ACCEPT_PROBE overrides the accept probe
# (a command given <ip> <port>; tests only).

[[ -n "${__AGENTIC_NETOPS_CONTAINERLAB_SH:-}" ]] && return 0
__AGENTIC_NETOPS_CONTAINERLAB_SH=1

# shellcheck source=log.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/log.sh"
# shellcheck source=ownership.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/ownership.sh"
# shellcheck source=k8s_wait.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/k8s_wait.sh"
# shellcheck source=preflight.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/preflight.sh"

CONTAINERLAB_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTAINERLAB_GNMI_PORT=57400
CONTAINERLAB_NODES=(spine01 spine02 leaf01 leaf02 client01 client02)
CONTAINERLAB_DEVICES=(spine01:11 spine02:12 leaf01:21 leaf02:22)

containerlab::_clab() { "${CONTAINERLAB:-containerlab}" "$@"; }
containerlab::_docker() { "${DOCKER:-docker}" "$@"; }
containerlab::lab_name() { printf '%s' "${LAB_NAME:-agentic-netops-fabric}"; }
containerlab::topology() { printf '%s' "${CLAB_TOPOLOGY:-$CONTAINERLAB_REPO_ROOT/lab/topology.clab.yml}"; }
containerlab::_mgmt_net() { printf '%s' "${MGMT_NET:-agentic-netops-mgmt}"; }
containerlab::_mgmt_cidr() { printf '%s' "${MGMT_CIDR:-172.25.25.0/24}"; }

containerlab::lab_dir() {
  local base
  base="${CLAB_LABDIR_BASE:-$(dirname -- "$(containerlab::topology)")}"
  printf '%s/clab-%s' "$base" "$(containerlab::lab_name)"
}

# containerlab::mgmt_prefix — the first three octets of MGMT_CIDR's network address.
containerlab::mgmt_prefix() {
  local cidr first
  cidr="$(containerlab::_mgmt_cidr)"
  preflight::_valid_cidr "$cidr" || { log::error "containerlab: MGMT_CIDR '$cidr' is not an IPv4 CIDR"; return 1; }
  read -r first _ < <(preflight::_range "$cidr")
  printf '%d.%d.%d' $(( (first >> 24) & 255 )) $(( (first >> 16) & 255 )) $(( (first >> 8) & 255 ))
}

containerlab::device_addresses() {
  local prefix d
  prefix="$(containerlab::mgmt_prefix)" || return 1
  for d in "${CONTAINERLAB_DEVICES[@]}"; do
    printf '%s %s.%s\n' "${d%%:*}" "$prefix" "${d##*:}"
  done
}

containerlab::_container() { printf 'clab-%s-%s' "$(containerlab::lab_name)" "$1"; }

containerlab::lab_containers() {
  containerlab::_docker ps -a --filter "label=containerlab=$(containerlab::lab_name)" --format '{{.Names}}' 2>/dev/null
}

# containerlab::_require_all_owned <names…> — refuses (naming them) when any is not owned.
containerlab::_require_all_owned() {
  local c rc=0
  for c in "$@"; do
    [[ -n "$c" ]] || continue
    ownership::require_docker_container "$c" || rc=1
  done
  if [[ "$rc" -ne 0 ]]; then
    log::error "containerlab: lab $(containerlab::lab_name) has containers this platform does not own: nothing touched"
  fi
  return "$rc"
}

containerlab::_export_env() {
  local prefix
  prefix="$(containerlab::mgmt_prefix)" || return 1
  export CLUSTER_NAME="${CLUSTER_NAME:-agentic-netops}"
  export MGMT_CIDR
  MGMT_CIDR="$(containerlab::_mgmt_cidr)"
  export CLAB_MGMT_PREFIX="$prefix"
}

containerlab::deploy() {
  local net topo
  net="$(containerlab::_mgmt_net)"
  topo="$(containerlab::topology)"
  [[ -f "$topo" ]] || { log::error "containerlab: topology $topo not found"; return 1; }
  if ! containerlab::_docker network inspect "$net" >/dev/null 2>&1; then
    log::error "containerlab: management network $net does not exist (NetworkReady not met): run docker_net::ensure first"
    return 1
  fi
  ownership::require_docker_network "$net" || return 1
  containerlab::_export_env || return 1

  local -a present=()
  mapfile -t present < <(containerlab::lab_containers | sed '/^$/d')
  if [[ ${#present[@]} -gt 0 ]]; then
    containerlab::_require_all_owned "${present[@]}" || return 1
  fi
  local n missing=0 stopped=0 running
  for n in "${CONTAINERLAB_NODES[@]}"; do
    running="$(containerlab::_docker container inspect "$(containerlab::_container "$n")" 2>/dev/null \
      | jq -r '.[0].State.Running // false')" || running=""
    if [[ -z "$running" ]]; then missing=$((missing + 1))
    elif [[ "$running" != true ]]; then stopped=$((stopped + 1)); fi
  done
  if [[ "$missing" -eq 0 && "$stopped" -eq 0 ]]; then
    log::info "containerlab: lab $(containerlab::lab_name) deployed, all ${#CONTAINERLAB_NODES[@]} nodes running and owned (no change)"
    return 0
  fi
  local -a args=(deploy -t "$topo")
  if [[ ${#present[@]} -gt 0 ]]; then
    args+=(--reconfigure)
    log::warn "containerlab: lab $(containerlab::lab_name) is partial (${missing} missing, ${stopped} stopped): redeploying with --reconfigure"
  else
    log::info "containerlab: deploying $(containerlab::lab_name) from $topo on $net ($MGMT_CIDR)"
  fi
  containerlab::_clab "${args[@]}" >&2 || { log::error "containerlab: deploy failed; inspect with: containerlab inspect -t $topo"; return 1; }
  mapfile -t present < <(containerlab::lab_containers | sed '/^$/d')
  containerlab::_require_all_owned "${present[@]}" || return 1
  log::info "containerlab: lab $(containerlab::lab_name) deployed (lab dir $(containerlab::lab_dir))"
}

# containerlab::accept_probe <ip> <port> — exit 0 when a TCP connection is accepted.
# A bare TCP connect: no credentials, no gNMI, no TLS session with anyone's identity.
containerlab::accept_probe() {
  local ip="$1" port="$2"
  if [[ -n "${CONTAINERLAB_ACCEPT_PROBE:-}" ]]; then
    "$CONTAINERLAB_ACCEPT_PROBE" "$ip" "$port"
    return
  fi
  # shellcheck disable=SC2016 # $1/$2 expand in the child shell, from its arguments
  timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2" && exec 3>&-' _ "$ip" "$port" 2>/dev/null
}

# containerlab::_all_accept — probe every device; prints the ones that did not accept.
containerlab::_all_accept() {
  local node ip rc=0
  while read -r node ip; do
    if ! containerlab::accept_probe "$ip" "$CONTAINERLAB_GNMI_PORT"; then
      printf '%s (%s:%s) does not accept yet\n' "$node" "$ip" "$CONTAINERLAB_GNMI_PORT"
      rc=1
    fi
  done < <(containerlab::device_addresses)
  return "$rc"
}

containerlab::wait_gnmi_accept() {
  local timeout="${1:-${CONTAINERLAB_GNMI_TIMEOUT:-600}}" interval="${CONTAINERLAB_GNMI_INTERVAL:-5}"
  k8s_wait::until "$timeout" "$interval" \
    "TCP ${CONTAINERLAB_GNMI_PORT} of every SR Linux node to accept a connection" -- containerlab::_all_accept || return 1
  log::info "containerlab: TCP ${CONTAINERLAB_GNMI_PORT} accepts on all ${#CONTAINERLAB_DEVICES[@]} devices"
}

containerlab::destroy() {
  local topo
  topo="$(containerlab::topology)"
  local -a present=()
  mapfile -t present < <(containerlab::lab_containers | sed '/^$/d')
  if [[ ${#present[@]} -eq 0 ]]; then
    local dir
    dir="$(containerlab::lab_dir)"
    # A lab directory with no lab (a deploy that died early): it holds the generated lab CA and
    # node keys, so it goes too. Its path is deterministic (<base>/clab-<lab>), never a glob.
    if [[ -d "$dir" && "$(basename -- "$dir")" == "clab-$(containerlab::lab_name)" ]]; then
      rm -rf -- "$dir"
      log::info "containerlab: removed the orphaned lab directory $dir"
    fi
    log::info "containerlab: lab $(containerlab::lab_name) absent (nothing to destroy)"
    return 0
  fi
  containerlab::_require_all_owned "${present[@]}" || return 1
  containerlab::_export_env || return 1
  containerlab::_clab destroy -t "$topo" --cleanup >&2 \
    || { log::error "containerlab: destroy failed; inspect with: containerlab inspect -t $topo"; return 1; }
  mapfile -t present < <(containerlab::lab_containers | sed '/^$/d')
  if [[ ${#present[@]} -gt 0 ]]; then
    log::error "containerlab: containers remain after destroy: ${present[*]}"
    return 1
  fi
  log::info "containerlab: lab $(containerlab::lab_name) destroyed"
}
