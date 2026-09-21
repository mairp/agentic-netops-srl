#!/usr/bin/env bash
# preflight_test.sh — the host preflight, offline (T026; FR-008, NFR-004, R-08, R-12, R-13).
#
# Asserts against scripts/lib/preflight.sh with fake `docker`, `ip`, `nproc`, `kind`,
# `containerlab`, `kubectl`, `ss` on PATH and fake /proc files through env overrides:
#   * the management-CIDR check fails NAMING the colliding Docker network, and also fails on an
#     overlap with the host routing table, the pod CIDR and the service CIDR; a free CIDR and the
#     owned management network itself pass; an unowned network of the same name fails
#   * the host-resource check fails when ≈2 vCPU / 2 GiB per SR Linux node (×4) plus the Kind budget
#     is not available, and counts what the platform already runs only once
#   * SSSE3 and kernel >= 4.10 are checked
#   * a failing preflight performs NO mutation (the fakes record every call; none mutates)
# No docker, no network, no cluster.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# ------------------------------------------------------------------ fakes
mkdir -p "$T/bin"
cat >"$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$FAKE_CALLS"
case "$1 ${2:-}" in
  "network ls") jq -r '.[].Id' "$FAKE_NETS" ;;
  "network inspect") jq '.' "$FAKE_NETS" ;;
  "ps -a") printf '%s' "${FAKE_PS:-}" | while IFS= read -r l; do
             want=""; for a in "$@"; do [[ "$a" == label=clab-node-kind=* ]] && want="${a#label=clab-node-kind=}"; done
             [[ -z "$want" || "$l" == *"$want"* ]] && [[ -n "$l" ]] && echo "${l%% *}"; done; true ;;
  *) exit 0 ;;
esac
EOF
cat >"$T/bin/ip" <<'EOF'
#!/usr/bin/env bash
printf 'ip %s\n' "$*" >>"$FAKE_CALLS"
cat "$FAKE_ROUTES"
EOF
cat >"$T/bin/nproc" <<'EOF'
#!/usr/bin/env bash
echo "${FAKE_NPROC:-22}"
EOF
cat >"$T/bin/kind" <<'EOF'
#!/usr/bin/env bash
printf 'kind %s\n' "$*" >>"$FAKE_CALLS"
case "$1" in
  version) echo "kind ${FAKE_KIND_VERSION:-v0.27.0} go1.23.6 linux/amd64" ;;
  get) printf '%s' "${FAKE_CLUSTERS:-}" ;;
  *) exit 0 ;;
esac
EOF
cat >"$T/bin/containerlab" <<'EOF'
#!/usr/bin/env bash
printf 'containerlab %s\n' "$*" >>"$FAKE_CALLS"
[[ "$1" == version ]] && printf '  banner\n    version: \033[1m%s\033[0m\n     commit: x\n' "${FAKE_CLAB_VERSION:-0.79.0}"
exit 0
EOF
cat >"$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$FAKE_CALLS"
exit 1
EOF
cat >"$T/bin/ss" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_SS:-LISTEN 0 4096 0.0.0.0:3000 0.0.0.0:*}"
EOF
chmod +x "$T/bin"/*

cat >"$T/nets.json" <<'EOF'
[
 {"Name":"bridge","Id":"742b6d151641aaaa","Labels":{},"Options":{"com.docker.network.bridge.name":"docker0"},"IPAM":{"Config":[{"Subnet":"172.17.0.0/16"}]}},
 {"Name":"host","Id":"545c62f4df64aaaa","Labels":{},"IPAM":{"Config":[]}},
 {"Name":"sovereign_lane_a_noegress","Id":"0540d6e2ffa8aaaa","Labels":{},"IPAM":{"Config":[{"Subnet":"172.31.0.0/16"}]}},
 {"Name":"kind","Id":"18c92ae48b3aaaaa","Labels":{},"IPAM":{"Config":[{"Subnet":"172.30.0.0/16"},{"Subnet":"fc00:f853:ccd:e793::/64"}]}}
]
EOF
cat >"$T/routes" <<'EOF'
default via 10.254.252.57 dev vmbr0 proto kernel onlink
10.8.0.0/24 dev wg0 proto kernel scope link src 10.8.0.1
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1
172.30.0.0/16 dev br-18c92ae48b3a proto kernel scope link src 172.30.0.1
172.31.0.0/16 dev br-0540d6e2ffa8 proto kernel scope link src 172.31.0.1
EOF
printf 'processor\t: 0\nflags\t\t: fpu vme sse sse2 ssse3 sse4_1 avx2\n' >"$T/cpuinfo.ok"
printf 'processor\t: 0\nflags\t\t: fpu vme sse sse2 sse4_1\n' >"$T/cpuinfo.nossse3"
printf 'MemTotal:       98376568 kB\nMemAvailable:   35118668 kB\n' >"$T/meminfo.ok"
printf 'MemTotal:       16000000 kB\nMemAvailable:    9000000 kB\n' >"$T/meminfo.low"
echo "7.0.14-15-pve" >"$T/osrelease.ok"

# base environment for every case
base_env() {
  export PATH="$T/bin:$PATH" FAKE_CALLS="$T/calls" FAKE_NETS="$T/nets.json" FAKE_ROUTES="$T/routes"
  export PREFLIGHT_CPUINFO="$T/cpuinfo.ok" PREFLIGHT_MEMINFO="$T/meminfo.ok" PREFLIGHT_OSRELEASE="$T/osrelease.ok"
  export CLUSTER_NAME=agentic-netops MGMT_CIDR=172.25.25.0/24
  unset POD_CIDR SERVICE_CIDR FAKE_NPROC FAKE_PS FAKE_CLUSTERS FAKE_SS DOCKER KIND CONTAINERLAB KUBECTL || true
}

# run_pf <fn> [VAR=value…] — run a preflight function in a clean subshell; sets $rc, $out.
run_pf() {
  local fn="$1"; shift
  : >"$T/calls"
  set +e
  out="$( ( base_env; for kv in "$@"; do export "${kv?}"; done
            source "$ROOT/scripts/lib/preflight.sh"; "$fn" ) 2>&1 )"
  rc=$?
  set -e
}
expect_rc() { # <name> <want 0|nonzero>
  if { [[ "$2" == 0 && "$rc" -eq 0 ]] || [[ "$2" != 0 && "$rc" -ne 0 ]]; }; then ok "$1"; else bad "$1 (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/    | /'; fi
}
expect_out() { # <name> <regex>
  if grep -Eq -- "$2" <<<"$out"; then ok "$1"; else bad "$1 (output lacks /$2/)"; printf '%s\n' "$out" | sed 's/^/    | /'; fi
}
no_mutation() { # <name>
  if grep -Eq '^(docker (network (create|connect|rm)|run|create|start|pull|rm)|kind (create|delete|load)|containerlab (deploy|destroy)|kubectl (apply|create|delete))' "$T/calls"; then
    bad "$1: a mutating call was made"; sed 's/^/    | /' "$T/calls"
  else ok "$1"; fi
}

# ------------------------------------------------------------------ management CIDR
run_pf preflight::mgmt_cidr
expect_rc "mgmt: free default CIDR 172.25.25.0/24 passes" 0

run_pf preflight::mgmt_cidr MGMT_CIDR=172.31.5.0/24
expect_rc "mgmt: overlap with a Docker network fails" 1
expect_out "mgmt: the colliding Docker network is NAMED" "overlaps Docker network 'sovereign_lane_a_noegress' \(172\.31\.0\.0/16\)"
if grep -q "host route '172.31.0.0/16" <<<"$out"; then bad "mgmt: a Docker bridge route is reported by network name, not twice"; else ok "mgmt: a Docker bridge route is reported by network name, not twice"; fi
no_mutation "mgmt: overlap refusal mutates nothing"

run_pf preflight::mgmt_cidr MGMT_CIDR=172.16.0.0/12
expect_out "mgmt: every colliding network is named (bridge)" "Docker network 'bridge'"
expect_out "mgmt: every colliding network is named (kind)" "Docker network 'kind'"

run_pf preflight::mgmt_cidr MGMT_CIDR=10.8.0.0/24
expect_rc "mgmt: overlap with a host route fails" 1
expect_out "mgmt: the host route is named" "host route '10\.8\.0\.0/24 dev wg0'"

run_pf preflight::mgmt_cidr MGMT_CIDR=10.244.3.0/24
expect_rc "mgmt: overlap with the pod CIDR (from config/kind/cluster.yaml) fails" 1
expect_out "mgmt: pod CIDR named" "pod CIDR 10\.244\.0\.0/16"

run_pf preflight::mgmt_cidr MGMT_CIDR=10.96.8.0/24
expect_rc "mgmt: overlap with the service CIDR fails" 1
expect_out "mgmt: service CIDR named" "service CIDR 10\.96\.0\.0/16"

run_pf preflight::mgmt_cidr MGMT_CIDR=192.168.50.0/24 POD_CIDR=192.168.0.0/16
expect_rc "mgmt: POD_CIDR override is honoured" 1

run_pf preflight::mgmt_cidr MGMT_CIDR=10.9.0.0/16
expect_rc "mgmt: the default route never counts as an overlap" 0

run_pf preflight::mgmt_cidr MGMT_CIDR=not-a-cidr
expect_rc "mgmt: a malformed CIDR is refused" 1
run_pf preflight::mgmt_cidr MGMT_CIDR=172.25.25.7/24
expect_rc "mgmt: a CIDR with host bits set is refused" 1
run_pf preflight::mgmt_cidr MGMT_CIDR=172.25.25.0/28
expect_rc "mgmt: a CIDR too small for the fixed addresses is refused" 1

# the owned management network on exactly MGMT_CIDR (a re-run) passes, its bridge route included
jq '. + [{"Name":"agentic-netops-mgmt","Id":"abcdef123456ffff","Labels":{"agentic-netops.io/owned-by":"agentic-netops"},"IPAM":{"Config":[{"Subnet":"172.25.25.0/24"}]}}]' \
  "$T/nets.json" >"$T/nets.owned.json"
cp "$T/routes" "$T/routes.owned"; echo "172.25.25.0/24 dev br-abcdef123456 proto kernel scope link src 172.25.25.1" >>"$T/routes.owned"
run_pf preflight::mgmt_cidr FAKE_NETS="$T/nets.owned.json" FAKE_ROUTES="$T/routes.owned"
expect_rc "mgmt: the owned network on exactly MGMT_CIDR is not a collision (re-run)" 0
run_pf preflight::mgmt_cidr FAKE_NETS="$T/nets.owned.json" FAKE_ROUTES="$T/routes.owned" CLUSTER_NAME=agentic-netops-2
expect_rc "mgmt: the same network owned by ANOTHER cluster is refused" 1
expect_out "mgmt: the unowned network is named" "'agentic-netops-mgmt'.*not owned"
run_pf preflight::mgmt_cidr FAKE_NETS="$T/nets.owned.json" FAKE_ROUTES="$T/routes.owned" MGMT_CIDR=172.26.0.0/24
expect_rc "mgmt: the owned network on a different CIDR is refused" 1
expect_out "mgmt: the refusal names the existing CIDR" "exists on 172\.25\.25\.0/24"
jq '. + [{"Name":"agentic-netops-mgmt","Id":"abcdef123456ffff","Labels":{},"IPAM":{"Config":[{"Subnet":"172.25.25.0/24"}]}}]' \
  "$T/nets.json" >"$T/nets.unlabelled.json"
run_pf preflight::mgmt_cidr FAKE_NETS="$T/nets.unlabelled.json"
expect_rc "mgmt: an unlabelled network named agentic-netops-mgmt is refused" 1

# ------------------------------------------------------------------ resources
run_pf preflight::resources
expect_rc "resources: 22 vCPU / 34 GiB available passes" 0

run_pf preflight::resources FAKE_NPROC=8
expect_rc "resources: 8 vCPU < 4x2 + Kind budget fails" 1
expect_out "resources: the vCPU shortfall is stated" "8 vCPU available, 12 required"

run_pf preflight::resources PREFLIGHT_MEMINFO="$T/meminfo.low"
expect_rc "resources: 8789 MiB available < 4x2048 + endpoints + Kind budget fails" 1
expect_out "resources: the RAM shortfall is stated" "MiB of RAM available \(MemAvailable\), 14464 MiB required"
no_mutation "resources: the refusal mutates nothing"

run_pf preflight::resources FAKE_NPROC=8 PREFLIGHT_KIND_VCPU=0
expect_rc "resources: exactly 2 vCPU per SR Linux node (8) passes" 0
run_pf preflight::resources FAKE_NPROC=7 PREFLIGHT_KIND_VCPU=0
expect_rc "resources: one vCPU short of 2 per node fails" 1

# a re-run: the lab and cluster already run, so only the extra budget must fit
ps_all=$'clab-agentic-netops-fabric-spine01 nokia_srlinux\nclab-agentic-netops-fabric-spine02 nokia_srlinux\nclab-agentic-netops-fabric-leaf01 nokia_srlinux\nclab-agentic-netops-fabric-leaf02 nokia_srlinux\nclab-agentic-netops-fabric-client01 linux\nclab-agentic-netops-fabric-client02 linux'
run_pf preflight::resources FAKE_NPROC=2 PREFLIGHT_MEMINFO="$T/meminfo.low" FAKE_PS="$ps_all" FAKE_CLUSTERS=agentic-netops
expect_rc "resources: what the platform already runs is not counted twice" 0
run_pf preflight::resources FAKE_NPROC=2 FAKE_PS="$ps_all" FAKE_CLUSTERS=agentic-netops PREFLIGHT_EXTRA_VCPU=4
expect_rc "resources: an extra (tier) budget extends the threshold" 1

# ------------------------------------------------------------------ CPU and kernel
run_pf preflight::cpu_kernel
expect_rc "cpu/kernel: SSSE3 + kernel 7.0 passes" 0
run_pf preflight::cpu_kernel PREFLIGHT_CPUINFO="$T/cpuinfo.nossse3"
expect_rc "cpu/kernel: no SSSE3 fails" 1
expect_out "cpu/kernel: SSSE3 named" "SSSE3"
for k in 4.9.337 3.18.0 4.9; do
  echo "$k" >"$T/osrelease.k"
  run_pf preflight::cpu_kernel PREFLIGHT_OSRELEASE="$T/osrelease.k"
  expect_rc "cpu/kernel: kernel $k < 4.10 fails" 1
done
for k in 4.10.0 4.19.0-25-amd64 5.4.0 10.0.1; do
  echo "$k" >"$T/osrelease.k"
  run_pf preflight::cpu_kernel PREFLIGHT_OSRELEASE="$T/osrelease.k"
  expect_rc "cpu/kernel: kernel $k >= 4.10 passes" 0
done

# ------------------------------------------------------------------ tools and ports
run_pf preflight::tools
expect_rc "tools: kind v0.27.0 and containerlab 0.79.0 (banner + ANSI) pass" 0
run_pf preflight::tools FAKE_CLAB_VERSION=0.70.0
expect_rc "tools: a containerlab other than the pin fails" 1
run_pf preflight::tools FAKE_KIND_VERSION=v0.26.0
expect_rc "tools: a kind other than the pin fails" 1

run_pf preflight::host_ports
expect_rc "ports: 13000/19090 free passes" 0
run_pf preflight::host_ports FAKE_SS="LISTEN 0 4096 127.0.0.1:19090 0.0.0.0:*"
expect_rc "ports: a taken published port fails" 1
expect_out "ports: the port is named" "127\.0\.0\.1:19090"
run_pf preflight::host_ports FAKE_SS="LISTEN 0 4096 127.0.0.1:19090 0.0.0.0:*" FAKE_CLUSTERS=agentic-netops
expect_rc "ports: an existing cluster's own ports are not a conflict" 0

# ------------------------------------------------------------------ the whole run
run_pf preflight::run
expect_rc "run: a clean host passes" 0
run_pf preflight::run FAKE_NPROC=4 MGMT_CIDR=172.31.9.0/24 PREFLIGHT_CPUINFO="$T/cpuinfo.nossse3"
expect_rc "run: failures are reported together" 1
expect_out "run: names the network" "sovereign_lane_a_noegress"
expect_out "run: names the CPU" "SSSE3"
expect_out "run: names the vCPU shortfall" "4 vCPU available"
expect_out "run: states nothing was changed" "nothing was created or changed"
no_mutation "run: a failed preflight performs no mutation"

printf '\npreflight_test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
