#!/usr/bin/env bash
# tests/integration/footprint.sh — the measured per-node footprint of the SR Linux nodes at idle
# after convergence (T052; NFR-004). The ONLY source T141 and T164 may quote for NFR-004.
#
# Precondition, checked and never assumed: the default Fabric reports Ready=True (converged) and no
# Network exists (idle: no service on the fabric). Then, through evidence_run, SAMPLES+1 reads,
# INTERVAL seconds apart, of each of the four SR Linux containers' own cgroup (v2) accounting on the
# host — memory.stat `anon` (resident anonymous memory: the RSS), memory.current (everything charged,
# page cache included) and cpu.stat usage_usec with the wall clock — and one summary record
# footprint.summary with, per node, RSS and charged memory (MiB) per read and CPU (% of one CPU)
# per interval, with their mean and max. The SR Linux containers are found by the containerlab
# labels of this lab (clab-node-kind=nokia_srlinux), never by a name list; four are required.
#
# Why the cgroup files and not `docker stats`: SR Linux runs its processes in child cgroups of the
# container's scope, and `docker stats` reports 0 B / 0 % / 0 PIDs for it (observed 2026-09-21, and
# recorded here once as footprint.docker-stats so the reading is kept), while the scope itself is
# charged — its memory.current and cpu.stat include every descendant.
#
# The cgroup files are the host kernel's accounting: no device client and
# no device session (FR-108 does not apply; nothing here touches a management port).
#
# Usage: footprint.sh
# Environment: EVIDENCE_DIR, CLUSTER_NAME (agentic-netops), LAB_NAME (agentic-netops-fabric),
#   FABRIC_NAME (fabric01), FABRIC_NAMESPACE (agentic-netops-system), SAMPLES (5), INTERVAL (10).
# Exit: 0 recorded; 1 a precondition failed (named); 2 a tool is missing.
set -euo pipefail

FP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/log.sh
source "$FP_ROOT/scripts/lib/log.sh"
# shellcheck source=../../scripts/lib/evidence.sh
source "$FP_ROOT/scripts/lib/evidence.sh"
LOG_PHASE="${LOG_PHASE:-footprint}"

: "${CLUSTER_NAME:=agentic-netops}" "${LAB_NAME:=agentic-netops-fabric}"
: "${FABRIC_NAME:=fabric01}" "${FABRIC_NAMESPACE:=agentic-netops-system}"
: "${SAMPLES:=5}" "${INTERVAL:=10}"
DOCKER="${DOCKER:-docker}"; KUBECTL="${KUBECTL:-kubectl}"
for t in jq "$DOCKER" "$KUBECTL"; do command -v "$t" >/dev/null 2>&1 || { echo "footprint: $t is required" >&2; exit 2; }; done
k() { "$KUBECTL" --context "kind-${CLUSTER_NAME}" "$@"; }

evidence::ensure_dir >/dev/null

# ---------------------------------------------------------------- preconditions
ready="$(k get fabrics.fabric.agentic-netops.io "$FABRIC_NAME" -n "$FABRIC_NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [[ "$ready" != True ]]; then
  log::error "footprint: Fabric ${FABRIC_NAMESPACE}/${FABRIC_NAME} is not Ready=True (${ready:-absent}) — not converged, nothing measured"
  exit 1
fi
nets="$(k get networks.fabric.agentic-netops.io -A -o name 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$nets" != 0 ]]; then
  log::error "footprint: ${nets} Network(s) exist — the fabric is not idle, nothing measured"
  exit 1
fi
mapfile -t CTRS < <("$DOCKER" ps --filter "label=containerlab=${LAB_NAME}" --filter "label=clab-node-kind=nokia_srlinux" \
  --format '{{.Names}}' | sort)
if [[ "${#CTRS[@]}" -ne 4 ]]; then
  log::error "footprint: ${#CTRS[@]} SR Linux container(s) of lab ${LAB_NAME} running, 4 required: ${CTRS[*]:-none}"
  exit 1
fi
log::info "footprint: Fabric Ready, no Network, SR Linux nodes: ${CTRS[*]} — ${SAMPLES} rounds, ${INTERVAL} s apart"

# ---------------------------------------------------------------- samples
evidence_run footprint.docker-stats -- "$DOCKER" stats --no-stream --format '{{json .}}' "${CTRS[@]}" >/dev/null || true
# fp::read <container> — one JSON line: the scope's accounting at this instant
fp::read() {
  local c="$1" pid cg dir
  pid="$("$DOCKER" inspect -f '{{.State.Pid}}' "$c")"
  cg="$(sed -n 's/^0:://p' "/proc/${pid}/cgroup")"
  dir="/sys/fs/cgroup${cg}"
  jq -n -c --arg c "$c" --arg cg "$cg" \
    --argjson t "$(date +%s%6N)" \
    --argjson cur "$(cat "$dir/memory.current")" \
    --argjson anon "$(awk '$1 == "anon" {print $2}' "$dir/memory.stat")" \
    --argjson usage "$(awk '$1 == "usage_usec" {print $2}' "$dir/cpu.stat")" \
    '{container: $c, cgroup: $cg, t_usec: $t, memory_current: $cur, anon: $anon, cpu_usage_usec: $usage}'
}
export -f fp::read; export DOCKER
rounds=()
for ((i = 0; i <= SAMPLES; i++)); do
  id="footprint.read-${i}"
  evidence_run "$id" -- bash -c 'for c in "$@"; do fp::read "$c"; done' _ "${CTRS[@]}" >/dev/null
  rounds+=("$EVIDENCE_DIR/${id}.stdout")
  (( i < SAMPLES )) && sleep "$INTERVAL"
done

# ---------------------------------------------------------------- summary
summary="$(cat "${rounds[@]}" | jq -s -c --arg lab "$LAB_NAME" '
  group_by(.container) | map(sort_by(.t_usec) | . as $r | {
    node: (.[0].container | ltrimstr("clab-" + $lab + "-")),
    container: .[0].container,
    cgroup: .[0].cgroup,
    rss_mib: [.[] | .anon / 1048576],
    charged_mib: [.[] | .memory_current / 1048576],
    cpu_percent: [range(1; length) as $i | (($r[$i].cpu_usage_usec - $r[$i-1].cpu_usage_usec) / ($r[$i].t_usec - $r[$i-1].t_usec) * 100)]
  } | . + {rss_mib_mean: ((.rss_mib | add) / (.rss_mib | length)), rss_mib_max: (.rss_mib | max),
           charged_mib_mean: ((.charged_mib | add) / (.charged_mib | length)),
           cpu_percent_mean: ((.cpu_percent | add) / (.cpu_percent | length)), cpu_percent_max: (.cpu_percent | max)})')"
if [[ "$(jq '[.[] | select(.rss_mib_max <= 0)] | length' <<<"$summary")" != 0 ]]; then
  log::error "footprint: a node reads no resident memory from its cgroup — nothing is recorded as a measurement"
  exit 1
fi
evidence_run footprint.summary -- jq -n --argjson nodes "$summary" --arg samples "$SAMPLES" --arg interval "$INTERVAL" \
  '{schema: "agentic-netops.footprint/v1", state: "idle after convergence (Fabric Ready, no Network)",
    source: "host cgroup v2 of each container scope: memory.stat anon (RSS), memory.current, cpu.stat usage_usec",
    samples: ($samples | tonumber), interval_seconds: ($interval | tonumber), nodes: $nodes}' >/dev/null
jq -r '.nodes[] | "\(.container)\tRSS mean \(.rss_mib_mean | floor) MiB (max \(.rss_mib_max | floor)), charged \(.charged_mib_mean | floor) MiB\tCPU mean \(.cpu_percent_mean * 100 | floor / 100) % of one CPU (max \(.cpu_percent_max * 100 | floor / 100))"' \
  "$EVIDENCE_DIR/footprint.summary.stdout" >&2
log::info "footprint: recorded in ${EVIDENCE_DIR}/footprint.summary.json"
