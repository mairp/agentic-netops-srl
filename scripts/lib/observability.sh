#!/usr/bin/env bash
# observability.sh — the topology generator step (T131; FR-094, FR-096, R-10; data-model.md §21).
#
#   observability::draw <ref> <dir>         the pinned clab-io-draw over <dir>/topology.clab.yml
#   observability::generate <outdir>        from ONE inventory file, in ONE step: the pinned
#                                           clab-io-draw lays the inventory out (draw.io diagram +
#                                           flow-panel YAML), then internal/topologyview reads the
#                                           SAME file and that output and writes into <outdir>:
#                                             gnmic-targets.txt   `<name> <address>` per device
#                                                                 (onboarding::hosts' format)
#                                             topology.svg        flow-panel SVG, cell ids `cell-…`
#                                             topology-panel.yaml flow-panel config (cellIdPreamble cell-)
#                                             topology-rules.yaml recording rules, group
#                                                                 agentic-netops-topology
#                                             inventory-digest.txt `<sha256>  topology.clab.yml`
#                                           and holds them to the inventory (topologyview.Parity)
#                                           before writing anything
#   observability::configmaps <outdir>      the ConfigMaps on stdout, ownership-labelled:
#                                             monitoring/topology-assets  (topology.svg,
#                                               topology-panel.yaml, gnmic-targets.txt,
#                                               inventory-digest.txt) — mounted by Grafana
#                                             monitoring/prometheus-topology-rules (topology.yaml)
#                                               — mounted by Prometheus at /etc/prometheus/rules/topology/
#   observability::install_assets <outdir>  refuse assets generated from another inventory than
#                                           the tree's, refuse ConfigMaps this cluster does not
#                                           own, then apply both server-side
#
# The view joins telemetry on exactly two labels: `source` (the containerlab node name = the gNMIc
# target name) and the normalized `interface_name` (`ethernet-1/49` → `e1-49`; Prometheus rewrites
# the device label the same way at scrape of job `devices`). clab-io-draw decorates node ids with
# the container name (`clab-<lab>-leaf01`) and keeps `ethernet-1/49` in the diagram, and 0.7.1
# does not export SVG (it logs "Grafana SVG export skipped"), so topologyview canonicalizes its
# ids onto the join and renders the SVG from its diagram. The generator image is read from
# versions.lock.yaml observability.topologyGenerator.pinned — tag and digest, never `latest`
# (containerlab graph --drawio would default to latest, evidence/06 §4.3) — and runs offline
# (--network none). 0.7.1 rejects -o together with -g, so it writes next to its input: the
# inventory is copied into a work directory and that copy, whose digest is checked against the
# original after the run, is what both halves read.
#
# env: OBSERVABILITY_TOPOLOGY (lab/topology.clab.yml), MGMT_CIDR (172.25.25.0/24),
#      OBSERVABILITY_LOCK (versions.lock.yaml), DOCKER, GO (or OBSERVABILITY_TOPOLOGYVIEW_BIN, a built
#      internal/topologyview/cmd/topologyview), KUBECTL, KUBE_CONTEXT

# shellcheck source-path=SCRIPTDIR
[[ -n "${__AGENTIC_NETOPS_OBSERVABILITY_SH:-}" ]] && return 0
__AGENTIC_NETOPS_OBSERVABILITY_SH=1

OBSERVABILITY_LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OBSERVABILITY_ROOT="$(cd -- "$OBSERVABILITY_LIB/../.." && pwd)"
# shellcheck source=log.sh
source "$OBSERVABILITY_LIB/log.sh"
# shellcheck source=k8s_wait.sh
source "$OBSERVABILITY_LIB/k8s_wait.sh"
# shellcheck source=ownership.sh
source "$OBSERVABILITY_LIB/ownership.sh"

OBSERVABILITY_NS="monitoring"
OBSERVABILITY_ASSETS_CM="topology-assets"
OBSERVABILITY_RULES_CM="prometheus-topology-rules"
# the one interface normalization of the join (topologyview.InterfaceRelabelRegex), in
# clab-io-draw's --grafana-interface-format syntax
OBSERVABILITY_IFACE_FORMAT='ethernet-{x}/{x}:e{x}-{x}'

observability::_topology() { printf '%s' "${OBSERVABILITY_TOPOLOGY:-$OBSERVABILITY_ROOT/lab/topology.clab.yml}"; }
observability::_lock() { printf '%s' "${OBSERVABILITY_LOCK:-$OBSERVABILITY_ROOT/versions.lock.yaml}"; }

# observability::generator_ref — the pinned clab-io-draw reference from the lock file; refuses a
# reference without a digest, a `latest` tag, or one that disagrees with the entry's own fields.
observability::generator_ref() {
  local lock ref repo tag digest
  lock="$(observability::_lock)"
  [[ -f "$lock" ]] || { log::error "observability: lock file $lock is missing"; return 1; }
  command -v yq >/dev/null 2>&1 || { log::error "observability: yq is required to read $lock"; return 1; }
  ref="$(yq -r '.observability.topologyGenerator.pinned // ""' "$lock")" || ref=""
  repo="$(yq -r '.observability.topologyGenerator.repository // ""' "$lock")" || repo=""
  tag="$(yq -r '.observability.topologyGenerator.tag // ""' "$lock")" || tag=""
  digest="$(yq -r '.observability.topologyGenerator.digest // ""' "$lock")" || digest=""
  if [[ ! "$ref" =~ ^[^@[:space:]]+:[^@:/[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
    log::error "observability: observability.topologyGenerator.pinned '${ref}' in $lock is not <repository>:<tag>@sha256:<digest>"
    return 1
  fi
  if [[ "$tag" == "latest" || "$ref" == *:latest@* ]]; then
    log::error "observability: the topology generator is pinned to 'latest' in $lock (never latest)"
    return 1
  fi
  if [[ "$ref" != "${repo}:${tag}@${digest}" ]]; then
    log::error "observability: observability.topologyGenerator.pinned '${ref}' disagrees with repository/tag/digest '${repo}:${tag}@${digest}'"
    return 1
  fi
  printf '%s' "$ref"
}

observability::_sha256() { sha256sum "$1" | awk '{print $1}'; }

# observability::draw <ref> <dir> — run the pinned clab-io-draw over <dir>/topology.clab.yml, offline,
# as the calling user; it writes topology.clab.drawio, topology.clab.grafana.flow_panel.yaml and
# topology.clab.grafana.json beside it (the committed fixture internal/topologyview/testdata/
# clab-io-draw-0.7.1/ is this function's output over lab/topology.clab.yml).
observability::draw() {
  local ref="${1:?usage: observability::draw <ref> <dir>}" dir="${2:?usage: observability::draw <ref> <dir>}" log rc
  log="$(mktemp "${TMPDIR:-/tmp}/clab-io-draw.XXXXXX.log")" || return 1
  "${DOCKER:-docker}" run --rm --network none --user "$(id -u):$(id -g)" \
    -v "$dir:/data" "$ref" \
    -i topology.clab.yml -g --theme grafana --grafana-interface-format "$OBSERVABILITY_IFACE_FORMAT" \
    >"$log" 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    log::error "observability: clab-io-draw (${ref}) failed (exit $rc):"
    sed 's/^/    /' "$log" >&2
  fi
  rm -f "$log"
  return "$rc"
}

observability::generate() {
  local out="${1:?usage: observability::generate <outdir>}"
  local topo ref work rc cidr="${MGMT_CIDR:-172.25.25.0/24}" digest
  topo="$(observability::_topology)"
  [[ -f "$topo" ]] || { log::error "observability: inventory $topo is missing"; return 1; }
  if ! mkdir -p -- "$out" || ! out="$(cd -- "$out" && pwd)"; then log::error "observability: cannot create $out"; return 1; fi
  ref="$(observability::generator_ref)" || return 1
  work="$(mktemp -d "${TMPDIR:-/tmp}/agentic-netops-topology.XXXXXX")" || return 1
  mkdir -p "$work/draw" || { rm -rf "$work"; return 1; }
  cp -- "$topo" "$work/draw/topology.clab.yml" || { rm -rf "$work"; return 1; }
  digest="$(observability::_sha256 "$topo")"

  log::info "topology view: clab-io-draw ${ref} over $(basename -- "$topo")"
  observability::draw "$ref" "$work/draw" || { rm -rf "$work"; return 1; }
  # the file clab-io-draw read is the file topologyview reads, byte for byte the inventory's
  if [[ "$(observability::_sha256 "$work/draw/topology.clab.yml")" != "$digest" ]]; then
    log::error "observability: the inventory copy changed during generation"
    rm -rf "$work"
    return 1
  fi

  local -a gen=("${GO:-go}" run ./internal/topologyview/cmd/topologyview)
  [[ -n "${OBSERVABILITY_TOPOLOGYVIEW_BIN:-}" ]] && gen=("$OBSERVABILITY_TOPOLOGYVIEW_BIN")
  (cd "$OBSERVABILITY_ROOT" && "${gen[@]}" generate \
    --topology "$work/draw/topology.clab.yml" --mgmt-cidr "$cidr" \
    --drawio-dir "$work/draw" --out "$out" --generator-ref "$ref")
  rc=$?
  rm -rf "$work"
  if [[ $rc -ne 0 ]]; then
    log::error "observability: topologyview generate failed (exit $rc)"
    return 1
  fi
  log::info "topology view generated in $out (inventory sha256:${digest})"
}

# observability::_block <file> — a file as the body of a YAML literal block at data-key depth
observability::_block() {
  sed 's/^/    /' "$1"
}

observability::configmaps() {
  local out="${1:?usage: observability::configmaps <outdir>}" f
  for f in topology.svg topology-panel.yaml gnmic-targets.txt inventory-digest.txt topology-rules.yaml; do
    [[ -s "$out/$f" ]] || { log::error "observability: $out/$f is missing — run observability::generate first"; return 1; }
  done
  local labels
  labels="{app.kubernetes.io/part-of: agentic-netops, app.kubernetes.io/component: topology-view, $(ownership::key): \"$(ownership::value)\"}"
  cat <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${OBSERVABILITY_ASSETS_CM}
  namespace: ${OBSERVABILITY_NS}
  labels: ${labels}
data:
  topology.svg: |
$(observability::_block "$out/topology.svg")
  topology-panel.yaml: |
$(observability::_block "$out/topology-panel.yaml")
  gnmic-targets.txt: |
$(observability::_block "$out/gnmic-targets.txt")
  inventory-digest.txt: |
$(observability::_block "$out/inventory-digest.txt")
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${OBSERVABILITY_RULES_CM}
  namespace: ${OBSERVABILITY_NS}
  labels: ${labels}
data:
  topology.yaml: |
$(observability::_block "$out/topology-rules.yaml")
YAML
}

observability::install_assets() {
  local out="${1:?usage: observability::install_assets <outdir>}" want got cm
  want="$(observability::_sha256 "$(observability::_topology)")" || return 1
  got="$(awk '{print $1; exit}' "$out/inventory-digest.txt" 2>/dev/null)"
  if [[ "$got" != "$want" ]]; then
    log::error "observability: $out was generated from inventory sha256:${got:-<none>}, the tree's is sha256:${want} — run observability::generate again"
    return 1
  fi
  k8s_wait::_kubectl get namespace "$OBSERVABILITY_NS" -o name >/dev/null 2>&1 \
    || { log::error "observability: namespace ${OBSERVABILITY_NS} is missing"; return 1; }
  for cm in "$OBSERVABILITY_ASSETS_CM" "$OBSERVABILITY_RULES_CM"; do
    if k8s_wait::_kubectl get configmap "$cm" -n "$OBSERVABILITY_NS" -o name >/dev/null 2>&1; then
      ownership::require_k8s configmap "$cm" "$OBSERVABILITY_NS" || return 1
    fi
  done
  local rendered
  rendered="$(observability::configmaps "$out")" || return 1
  printf '%s\n' "$rendered" \
    | k8s_wait::_kubectl apply --server-side --field-manager=agentic-netops-provision -f - >/dev/null \
    || { log::error "observability: applying ConfigMaps ${OBSERVABILITY_ASSETS_CM}, ${OBSERVABILITY_RULES_CM} failed"; return 1; }
  log::info "topology view installed: ${OBSERVABILITY_NS}/${OBSERVABILITY_ASSETS_CM}, ${OBSERVABILITY_NS}/${OBSERVABILITY_RULES_CM}"
}

# executed directly: `observability.sh generate <outdir>` / `configmaps <outdir>` / `install <outdir>`
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  case "${1:-}" in
    generate) observability::generate "${2:?outdir}" ;;
    configmaps) observability::configmaps "${2:?outdir}" ;;
    install) observability::install_assets "${2:?outdir}" ;;
    *) echo "usage: $0 generate|configmaps|install <outdir>" >&2; exit 2 ;;
  esac
fi
