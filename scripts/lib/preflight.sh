#!/usr/bin/env bash
# preflight.sh — the host preflight of the NetworkReady phase (T034 for T026; FR-008, NFR-004,
# R-08, R-12, R-13; quickstart.md §Prerequisites, evidence/01 §4.6, §5).
#
# Every check here is a READ. Nothing is created, connected, pulled or started, so a failing
# preflight leaves the host exactly as it found it — "fails before any mutation" (R-08, R-13).
#
#   preflight::run          all of the below, in order; exit 1 naming every failed item
#   preflight::cpu_kernel   the CPU exposes SSSE3 (the emulated SR Linux datapath needs it) and the
#                           kernel is >= 4.10 (containerlab's requiredKernelVersion for the kind)
#   preflight::resources    available vCPU / RAM cover ≈2 vCPU and 2 GiB per SR Linux node (×4),
#                           the endpoints, and the Kind cluster's own budget — minus whatever of
#                           that this platform already runs (a re-run is not double-counted)
#   preflight::mgmt_cidr    MGMT_CIDR overlaps no Docker network (the colliding network is NAMED),
#                           no host route, not the pod CIDR and not the service CIDR; the owned
#                           management network itself, on exactly MGMT_CIDR, is not a collision
#   preflight::tools        docker, kind, containerlab, kubectl, jq present; kind and containerlab
#                           at the versions versions.lock.yaml pins
#   preflight::host_ports   the loopback ports config/kind/cluster.yaml publishes are free (only
#                           checked when the cluster does not exist yet)
#
# Inputs (environment): CLUSTER_NAME (agentic-netops), LAB_NAME (agentic-netops-fabric),
# MGMT_NET (agentic-netops-mgmt), MGMT_CIDR (172.25.25.0/24), POD_CIDR / SERVICE_CIDR (default:
# read from config/kind/cluster.yaml). Budget knobs (defaults in brackets):
#   PREFLIGHT_SRL_NODES [4]  PREFLIGHT_SRL_VCPU [2]  PREFLIGHT_SRL_MEM_MIB [2048]
#   PREFLIGHT_CLIENT_NODES [2]  PREFLIGHT_CLIENT_MEM_MIB [64]
#   PREFLIGHT_KIND_VCPU [4]  PREFLIGHT_KIND_MEM_MIB [6144]   (the Kind cluster and AppsReady's apps)
#   PREFLIGHT_EXTRA_VCPU [0] PREFLIGHT_EXTRA_MEM_MIB [0]     (a later phase's addition, e.g. the tier)
#   PREFLIGHT_EXTRA_LABEL [extra] (how that addition is named)  PREFLIGHT_NPROC (the host vCPUs; default nproc)
# Host views, overridable for tests: DOCKER, KIND, CONTAINERLAB (clients), `ip` and `nproc` from
# PATH, PREFLIGHT_MEMINFO (/proc/meminfo), PREFLIGHT_CPUINFO (/proc/cpuinfo), PREFLIGHT_OSRELEASE
# (/proc/sys/kernel/osrelease), PREFLIGHT_KIND_CONFIG, PREFLIGHT_LOCK_FILE, PREFLIGHT_SS (ss).

[[ -n "${__AGENTIC_NETOPS_PREFLIGHT_SH:-}" ]] && return 0
__AGENTIC_NETOPS_PREFLIGHT_SH=1

# shellcheck source=log.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/log.sh"
# shellcheck source=ownership.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/ownership.sh"

PREFLIGHT_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

preflight::_docker() { "${DOCKER:-docker}" "$@"; }
preflight::_kind() { "${KIND:-kind}" "$@"; }
preflight::_cluster() { printf '%s' "${CLUSTER_NAME:-agentic-netops}"; }
preflight::_lab() { printf '%s' "${LAB_NAME:-agentic-netops-fabric}"; }
preflight::_mgmt_net() { printf '%s' "${MGMT_NET:-agentic-netops-mgmt}"; }
preflight::_mgmt_cidr() { printf '%s' "${MGMT_CIDR:-172.25.25.0/24}"; }
preflight::_kind_config() { printf '%s' "${PREFLIGHT_KIND_CONFIG:-$PREFLIGHT_REPO_ROOT/config/kind/cluster.yaml}"; }

# ------------------------------------------------------------------ IPv4 arithmetic
preflight::_valid_cidr() {
  local re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$'
  [[ "$1" =~ $re ]] || return 1
  local i
  for i in 1 2 3 4; do (( BASH_REMATCH[i] <= 255 )) || return 1; done
  (( BASH_REMATCH[5] <= 32 ))
}

preflight::_ip2int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# preflight::_range <cidr|ip> — prints "<first> <last>" as integers (a bare address is a /32).
preflight::_range() {
  local cidr="$1" ip mask
  if [[ "$cidr" == */* ]]; then ip="${cidr%/*}"; mask="${cidr#*/}"; else ip="$cidr"; mask=32; fi
  local n m first
  n="$(preflight::_ip2int "$ip")"
  if (( mask == 0 )); then m=0; else m=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF )); fi
  first=$(( n & m ))
  echo "$first $(( first | (~m & 0xFFFFFFFF) ))"
}

# preflight::cidrs_overlap <a> <b> — exit 0 when the two ranges share any address.
preflight::cidrs_overlap() {
  local a1 a2 b1 b2
  read -r a1 a2 < <(preflight::_range "$1")
  read -r b1 b2 < <(preflight::_range "$2")
  (( a1 <= b2 && b1 <= a2 ))
}

# preflight::_kind_subnet <podSubnet|serviceSubnet> — from the declarative Kind config.
preflight::_kind_subnet() {
  local key="$1" f
  f="$(preflight::_kind_config)"
  [[ -f "$f" ]] || return 1
  awk -v k="$key" '$1 == k":" { v = $2; gsub(/["'\'']/, "", v); print v; exit }' "$f"
}

# ------------------------------------------------------------------ management CIDR
preflight::mgmt_cidr() {
  local cidr net pod svc
  cidr="$(preflight::_mgmt_cidr)"
  net="$(preflight::_mgmt_net)"
  if ! preflight::_valid_cidr "$cidr"; then
    log::error "preflight: MGMT_CIDR '$cidr' is not an IPv4 CIDR (e.g. 172.25.25.0/24)"
    return 1
  fi
  local mask="${cidr#*/}"
  if (( mask > 24 || mask < 8 )); then
    log::error "preflight: MGMT_CIDR '$cidr' must be a /8–/24: the lab uses host addresses .11–.32 of its first /24"
    return 1
  fi
  local lo _hi
  read -r lo _hi < <(preflight::_range "$cidr")
  if [[ "$(preflight::_ip2int "${cidr%/*}")" != "$lo" ]]; then
    log::error "preflight: MGMT_CIDR '$cidr' has host bits set; state the network address"
    return 1
  fi
  pod="${POD_CIDR:-$(preflight::_kind_subnet podSubnet || true)}"
  svc="${SERVICE_CIDR:-$(preflight::_kind_subnet serviceSubnet || true)}"
  local -a problems=()

  if [[ -z "$pod" || -z "$svc" ]]; then
    problems+=("pod or service CIDR unknown: set POD_CIDR/SERVICE_CIDR or provide networking.podSubnet/serviceSubnet in $(preflight::_kind_config)")
  else
    preflight::cidrs_overlap "$cidr" "$pod" && problems+=("overlaps the pod CIDR $pod")
    preflight::cidrs_overlap "$cidr" "$svc" && problems+=("overlaps the service CIDR $svc")
  fi

  # Docker networks: every IPv4 subnet of every network, by name.
  local nets_json="[]" ids
  ids="$(preflight::_docker network ls -q 2>/dev/null)" || {
    log::error "preflight: cannot list Docker networks (is the daemon reachable?)"
    return 1
  }
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086 # one argument per network id
    nets_json="$(preflight::_docker network inspect $ids 2>/dev/null)" || {
      log::error "preflight: cannot inspect Docker networks"
      return 1
    }
  fi
  local own_bridge="" docker_bridges name subnet labelled bridge
  docker_bridges="$(jq -r '.[] | ((.Options // {})["com.docker.network.bridge.name"] // ("br-" + (.Id // "")[0:12]))' <<<"$nets_json")"
  while IFS=$'\t' read -r name subnet labelled bridge; do
    [[ -n "$name" ]] || continue
    if [[ "$name" == "$net" ]]; then
      if [[ "$labelled" != "$(ownership::value)" ]]; then
        problems+=("Docker network '$name' ($subnet) already exists and is not owned by this platform (label $(ownership::key) is '${labelled:-<absent>}', expected '$(ownership::value)')")
      elif [[ "$subnet" != "$cidr" ]]; then
        problems+=("the owned Docker network '$name' exists on $subnet, not $cidr: re-run with MGMT_CIDR=$subnet or remove it with scripts/off.sh")
      else
        own_bridge="$bridge"
      fi
      continue
    fi
    [[ "$subnet" == *:* || -z "$subnet" ]] && continue
    preflight::cidrs_overlap "$cidr" "$subnet" \
      && problems+=("overlaps Docker network '$name' ($subnet)")
  done < <(jq -r --arg k "$(ownership::key)" '.[] | . as $n
      | ((.Options // {})["com.docker.network.bridge.name"] // ("br-" + (.Id // "")[0:12])) as $br
      | (.IPAM.Config // [])[]? | [$n.Name, (.Subnet // ""), (($n.Labels // {})[$k] // ""), $br] | @tsv' <<<"$nets_json")

  # Host routing table: routes on a Docker bridge were reported by network name above.
  local line dst dev
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    read -r dst _ <<<"$line"
    [[ "$dst" == "default" || "$dst" == "unreachable" || "$dst" == "blackhole" || "$dst" == "prohibit" ]] && continue
    [[ "$dst" =~ ^[0-9.]+(/[0-9]+)?$ ]] || continue
    dev="$(awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}' <<<"$line")"
    [[ -n "$dev" && -n "$own_bridge" && "$dev" == "$own_bridge" ]] && continue
    if [[ -n "$dev" ]] && grep -qxF -- "$dev" <<<"$docker_bridges"; then continue; fi
    preflight::cidrs_overlap "$cidr" "$dst" \
      && problems+=("overlaps the host route '$dst${dev:+ dev $dev}'")
  done < <(ip -4 route show 2>/dev/null || true)

  if [[ ${#problems[@]} -gt 0 ]]; then
    local p
    for p in "${problems[@]}"; do
      log::error "preflight: management CIDR $cidr $p"
    done
    log::error "preflight: choose a free range and re-run with MGMT_CIDR=<free /24> (FR-008)"
    return 1
  fi
  log::info "preflight: management CIDR $cidr is free (pod $pod, service $svc, Docker networks, host routes)"
}

# ------------------------------------------------------------------ CPU and kernel
preflight::cpu_kernel() {
  local cpuinfo="${PREFLIGHT_CPUINFO:-/proc/cpuinfo}" osrel="${PREFLIGHT_OSRELEASE:-/proc/sys/kernel/osrelease}"
  local rc=0 rel major minor
  if [[ ! -r "$cpuinfo" ]] || ! grep -m1 -E '^flags[[:space:]]*:' "$cpuinfo" | grep -qw ssse3; then
    log::error "preflight: the CPU does not expose SSSE3 (read $cpuinfo): the emulated SR Linux datapath requires it and containerlab aborts without it; a hypervisor guest needs a host-passthrough CPU model (NFR-004)"
    rc=1
  fi
  rel="$(cat "$osrel" 2>/dev/null || true)"
  if [[ "$rel" =~ ^([0-9]+)\.([0-9]+) ]]; then
    major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"
    if (( major < 4 || (major == 4 && minor < 10) )); then
      log::error "preflight: kernel $rel is older than 4.10, the minimum containerlab enforces for SR Linux (NFR-004)"
      rc=1
    fi
  else
    log::error "preflight: cannot read the kernel release from $osrel"
    rc=1
  fi
  [[ "$rc" -eq 0 ]] && log::info "preflight: CPU exposes SSSE3; kernel $rel >= 4.10"
  return "$rc"
}

# ------------------------------------------------------------------ resources
# preflight::_present_lab_nodes <clab kind> — how many of this platform's SR Linux / client containers exist.
preflight::_present_lab_nodes() {
  local kind="$1"
  preflight::_docker ps -a --filter "label=containerlab=$(preflight::_lab)" \
    --filter "label=$(ownership::selector)" --filter "label=clab-node-kind=$kind" \
    --format '{{.Names}}' 2>/dev/null | grep -c . || true
}

preflight::_cluster_exists() {
  preflight::_kind get clusters 2>/dev/null | grep -qxF -- "$(preflight::_cluster)"
}

preflight::resources() {
  local srl_n="${PREFLIGHT_SRL_NODES:-4}" srl_cpu="${PREFLIGHT_SRL_VCPU:-2}" srl_mem="${PREFLIGHT_SRL_MEM_MIB:-2048}"
  local cl_n="${PREFLIGHT_CLIENT_NODES:-2}" cl_mem="${PREFLIGHT_CLIENT_MEM_MIB:-64}"
  local k_cpu="${PREFLIGHT_KIND_VCPU:-4}" k_mem="${PREFLIGHT_KIND_MEM_MIB:-6144}"
  local x_cpu="${PREFLIGHT_EXTRA_VCPU:-0}" x_mem="${PREFLIGHT_EXTRA_MEM_MIB:-0}"
  local v
  for v in "$srl_n" "$srl_cpu" "$srl_mem" "$cl_n" "$cl_mem" "$k_cpu" "$k_mem" "$x_cpu" "$x_mem"; do
    [[ "$v" =~ ^[0-9]+$ ]] || { log::error "preflight: resource budget values must be non-negative integers, got '$v'"; return 1; }
  done

  # What already runs is already paid for: only the absent part must fit.
  local srl_present cl_present
  srl_present="$(preflight::_present_lab_nodes nokia_srlinux)"
  cl_present="$(preflight::_present_lab_nodes linux)"
  local srl_need=$(( srl_n - srl_present )); (( srl_need < 0 )) && srl_need=0
  local cl_need=$(( cl_n - cl_present )); (( cl_need < 0 )) && cl_need=0
  local kind_cpu_need="$k_cpu" kind_mem_need="$k_mem" kind_note="absent"
  if preflight::_cluster_exists; then kind_cpu_need=0; kind_mem_need=0; kind_note="present"; fi

  local need_cpu=$(( srl_need * srl_cpu + kind_cpu_need + x_cpu ))
  local need_mem=$(( srl_need * srl_mem + cl_need * cl_mem + kind_mem_need + x_mem ))

  local have_cpu have_mem_kb have_mem
  have_cpu="${PREFLIGHT_NPROC:-$(nproc 2>/dev/null || echo 0)}"
  have_mem_kb="$(awk '$1 == "MemAvailable:" { print $2; exit }' "${PREFLIGHT_MEMINFO:-/proc/meminfo}" 2>/dev/null || true)"
  [[ "$have_cpu" =~ ^[0-9]+$ ]] || have_cpu=0
  [[ "$have_mem_kb" =~ ^[0-9]+$ ]] || have_mem_kb=0
  have_mem=$(( have_mem_kb / 1024 ))

  local breakdown="SR Linux ${srl_need}x(${srl_cpu} vCPU, ${srl_mem} MiB) [${srl_present} already running], endpoints ${cl_need}x${cl_mem} MiB, Kind cluster ${kind_cpu_need} vCPU/${kind_mem_need} MiB [cluster ${kind_note}], ${PREFLIGHT_EXTRA_LABEL:-extra} ${x_cpu} vCPU/${x_mem} MiB"
  local rc=0
  if (( have_cpu < need_cpu )); then
    log::error "preflight: ${have_cpu} vCPU available, ${need_cpu} required, $(( need_cpu - have_cpu )) vCPU short — ${breakdown} (NFR-004, R-08)"
    rc=1
  fi
  if (( have_mem < need_mem )); then
    log::error "preflight: ${have_mem} MiB of RAM available (MemAvailable), ${need_mem} MiB required, $(( need_mem - have_mem )) MiB short — ${breakdown} (NFR-004, R-13)"
    rc=1
  fi
  [[ "$rc" -eq 0 ]] && log::info "preflight: resources ok — ${have_cpu} vCPU / ${have_mem} MiB available, ${need_cpu} vCPU / ${need_mem} MiB required (${breakdown})"
  return "$rc"
}

# ------------------------------------------------------------------ tools
preflight::_lock_value() {
  local path="$1" lock="${PREFLIGHT_LOCK_FILE:-$PREFLIGHT_REPO_ROOT/versions.lock.yaml}"
  command -v yq >/dev/null 2>&1 || return 1
  yq -r "$path // \"\"" "$lock" 2>/dev/null
}

preflight::tools() {
  local rc=0 t
  for t in "${DOCKER:-docker}" "${KIND:-kind}" "${CONTAINERLAB:-containerlab}" "${KUBECTL:-kubectl}" jq yq; do
    if ! command -v "$t" >/dev/null 2>&1; then
      log::error "preflight: required command '$t' not found"
      rc=1
    fi
  done
  [[ "$rc" -eq 0 ]] || return 1
  local want got esc
  want="$(preflight::_lock_value '.platform.kind.version')" || want=""
  got="$(preflight::_kind version 2>/dev/null | awk '{print $2}')" || got=""
  if [[ -z "$want" || "$got" != "$want" ]]; then
    log::error "preflight: kind is '${got:-<unknown>}', versions.lock.yaml pins '${want:-<unreadable>}'"
    rc=1
  fi
  want="$(preflight::_lock_value '.compatibilitySet.containerlab.version')" || want=""
  esc=$'\033'
  got="$("${CONTAINERLAB:-containerlab}" version 2>/dev/null | sed "s/${esc}\[[0-9;]*[a-zA-Z]//g" \
    | awk -F': *' 'tolower($1) ~ /^[[:space:]]*version$/ { v = $2; gsub(/[^0-9.]/, "", v); print v; exit }')" || got=""
  if [[ -z "$want" || "$got" != "$want" ]]; then
    log::error "preflight: containerlab is '${got:-<unknown>}', versions.lock.yaml pins '${want:-<unreadable>}'"
    rc=1
  fi
  [[ "$rc" -eq 0 ]] && log::info "preflight: tools present; kind and containerlab at the pinned versions"
  return "$rc"
}

# ------------------------------------------------------------------ host ports
preflight::host_ports() {
  if preflight::_cluster_exists; then
    log::info "preflight: cluster $(preflight::_cluster) exists; its published ports are its own"
    return 0
  fi
  local f ports p rc=0 listening
  f="$(preflight::_kind_config)"
  ports="$(awk '$1 == "hostPort:" || $2 == "hostPort:" { print $NF }' "$f" 2>/dev/null)"
  [[ -n "$ports" ]] || return 0
  listening="$("${PREFLIGHT_SS:-ss}" -ltnH 2>/dev/null | awk '{print $4}')" || listening=""
  for p in $ports; do
    if grep -Eq "(^|[:.])(127\.0\.0\.1|0\.0\.0\.0|\*|\[::\]|\[::ffff:127\.0\.0\.1\]):${p}$" <<<"$listening"; then
      log::error "preflight: host port 127.0.0.1:${p}, which $(basename "$f") publishes, is already in use"
      rc=1
    fi
  done
  [[ "$rc" -eq 0 ]] && log::info "preflight: published loopback ports free ($(tr '\n' ' ' <<<"$ports"))"
  return "$rc"
}

# ------------------------------------------------------------------ all
preflight::run() {
  local rc=0 f
  for f in preflight::tools preflight::cpu_kernel preflight::resources preflight::mgmt_cidr preflight::host_ports; do
    "$f" || rc=1
  done
  if [[ "$rc" -ne 0 ]]; then
    log::error "preflight: FAILED — nothing was created or changed"
    return 1
  fi
  log::info "preflight: passed"
}
