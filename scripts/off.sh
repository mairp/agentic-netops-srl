#!/usr/bin/env bash
# off.sh — the full teardown (T049 for T029; FR-010, FR-019, FR-078, SC-003, AD-24, AD-35, AD-46,
# AD-64; data-model.md §2, §16).
#
# Usage: scripts/off.sh [--cluster-name <name>] [--preserve-evidence] [--discard-audit-record]
#                       [--purge-intent-tier [--remove-services]]
#   --cluster-name <name>   the cluster (and ownership value) to tear down; default CLUSTER_NAME or
#                           agentic-netops
#   --preserve-evidence     ADD an evidence capture, through evidence_run, of the state this
#                           teardown is about to remove. It is never what keeps evidence: nothing
#                           under the lab's evidence root .evidence/<cluster>_<lab>/ is ever deleted,
#                           with or without this flag (AD-64)
#   --discard-audit-record  let the teardown continue past a FAILED audit-record export (the store is
#                           then removed with the cluster); the flag's use is printed and recorded
#   --purge-intent-tier     remove the intent tier ONLY (T088, User Story 7) — the cluster, the lab,
#                           the control plane and everything in agentic-netops-services stay. In order
#                           (AD-35, AD-46): (a) the refusal-decision list of the Networks in
#                           agentic-netops-intent, through evidence_run — a read; any present and no
#                           --remove-services → stop non-zero having changed nothing, naming each and
#                           both continuations; (b) supervisor, ui and deployer scaled to zero (an
#                           absent one reported by name, never created); (c) the authoritative list —
#                           without --remove-services a non-empty one falls back to the refusal,
#                           nothing deleted or exported, the workloads left at zero; then the
#                           audit-record export and the usernames record (scripts/lib/audit_export.sh;
#                           a failure stops with the store intact unless --discard-audit-record); the
#                           Networks of (c) deleted and waited on for up to TIER_PURGE_WAIT_SECONDS
#                           (300) — never force-released, a stop naming each Network still Deleting and
#                           its unreachable target or holder, the tier left in place scaled down; only
#                           once a re-list is empty: the workloads, the tier Secrets (username captured
#                           first), the provisional claims (correlation id matching no Network), the
#                           borrowed claim Role/RoleBinding, deny-tier-force-release and its binding,
#                           agentic-netops-intent, agentic-netops-agents. A second run is a no-op
#   --remove-services       with --purge-intent-tier only: delete the tier-submitted Networks too
#
# Order (data-model.md §2): ownership plan (read-only; any present-but-unowned target refuses the
# whole run with nothing deleted) → optional evidence capture → audit-record export, whenever the
# analytics store exists, requested or not, before anything deletes it (a failed export stops here
# with the store intact unless --discard-audit-record) → containerlab lab → generated Secrets (the
# lab's, then the intent tier's: llm-provider, operator-credentials — its `username`, never the
# `password`, captured through evidence_run first, and a failed capture stops the teardown with the
# Secret intact (FR-102, data-model.md §22) — slim-gateway, clickhouse-auth) →
# the first-party allocation authority's namespace agentic-netops-allocation (when present; its
# ownership label checked in the plan) → Kind cluster → owned Docker management network. No
# --remove-services is needed or asked for: the cluster goes, and every Network with it (AD-35).
#
# Idempotent: every step treats an absent owned resource as success, so a second run is a success
# no-op. Never deleted, by construction: container images (pinned or built — no image removal
# command exists in this script or its libraries), anything under .evidence/, and any resource whose
# ownership label is not exactly agentic-netops.io/owned-by=<cluster>. The audit-record export
# (scripts/lib/audit_export.sh) writes audit-export-<attempt>.ndjson.gz + its record under the run's
# EVIDENCE_DIR, bounded by AUDIT_EXPORT_TIMEOUT_SECONDS (120), and never rewrites an earlier one.
#
# Exit: 0 torn down (or nothing to do); 1 refused or a step failed (named); 2 usage.
set -euo pipefail

OFF_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/log.sh
source "$OFF_ROOT/scripts/lib/log.sh"
# shellcheck source=lib/dotenv.sh
source "$OFF_ROOT/scripts/lib/dotenv.sh"
# shellcheck source=lib/ownership.sh
source "$OFF_ROOT/scripts/lib/ownership.sh"
# shellcheck source=lib/evidence.sh
source "$OFF_ROOT/scripts/lib/evidence.sh"
# shellcheck source=lib/docker_net.sh
source "$OFF_ROOT/scripts/lib/docker_net.sh"
# shellcheck source=lib/kind.sh
source "$OFF_ROOT/scripts/lib/kind.sh"
# shellcheck source=lib/containerlab.sh
source "$OFF_ROOT/scripts/lib/containerlab.sh"
# shellcheck source=lib/lab_secrets.sh
source "$OFF_ROOT/scripts/lib/lab_secrets.sh"
# shellcheck source=lib/intent_secrets.sh
source "$OFF_ROOT/scripts/lib/intent_secrets.sh"
# The audit-record export arrives with T088 (scripts/lib/intent_tier.sh); sourced when present.
if [[ -f "$OFF_ROOT/scripts/lib/intent_tier.sh" ]]; then
  # shellcheck source=/dev/null
  source "$OFF_ROOT/scripts/lib/intent_tier.sh"
fi

off::usage() { sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

PRESERVE_EVIDENCE=false
DISCARD_AUDIT=false
PURGE_TIER=false
REMOVE_SERVICES=false
cluster_flag=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name) [[ $# -ge 2 ]] || { off::usage >&2; exit 2; }; cluster_flag="$2"; shift 2 ;;
    --cluster-name=*) cluster_flag="${1#*=}"; shift ;;
    --preserve-evidence) PRESERVE_EVIDENCE=true; shift ;;
    --discard-audit-record) DISCARD_AUDIT=true; shift ;;
    --purge-intent-tier) PURGE_TIER=true; shift ;;
    --remove-services) REMOVE_SERVICES=true; shift ;;
    -h|--help) off::usage; exit 0 ;;
    *) echo "off.sh: unknown argument '$1'" >&2; off::usage >&2; exit 2 ;;
  esac
done

dotenv::load ""
dotenv::noninteractive
CLUSTER_NAME="${cluster_flag:-${CLUSTER_NAME:-agentic-netops}}"
LAB_NAME="${LAB_NAME:-agentic-netops-fabric}"
MGMT_NET="${MGMT_NET:-agentic-netops-mgmt}"
export CLUSTER_NAME LAB_NAME MGMT_NET

if [[ "$REMOVE_SERVICES" == true && "$PURGE_TIER" != true ]]; then
  echo "off.sh: --remove-services is used only with --purge-intent-tier (the full teardown removes the cluster and every Network with it)" >&2
  exit 2
fi

AUDIT_STORE_NS="${AUDIT_STORE_NAMESPACE:-agentic-netops-agents}"
AUDIT_STORE_STS="${AUDIT_STORE_STATEFULSET:-clickhouse}"

# ------------------------------------------------------------------ plan (read-only)
HAVE_LAB=false HAVE_CLUSTER=false HAVE_NET=false HAVE_ALLOC_NS=false
ALLOC_NS="agentic-netops-allocation"
off::plan() {
  log::phase TeardownPlan
  local rc=0 c
  local -a lab=()
  mapfile -t lab < <(containerlab::lab_containers | sed '/^$/d')
  if [[ ${#lab[@]} -gt 0 ]]; then
    HAVE_LAB=true
    for c in "${lab[@]}"; do ownership::require_docker_container "$c" || rc=1; done
  fi
  if kind::cluster_exists "$CLUSTER_NAME"; then
    HAVE_CLUSTER=true
    kind::_require_owned "$CLUSTER_NAME" || rc=1
    # the first-party allocation authority's namespace (FR-104, data-model.md §23)
    if "${KUBECTL:-kubectl}" --context "kind-${CLUSTER_NAME}" get namespace "$ALLOC_NS" -o name >/dev/null 2>&1; then
      HAVE_ALLOC_NS=true
      KUBE_CONTEXT="kind-${CLUSTER_NAME}" ownership::require_k8s namespace "$ALLOC_NS" || rc=1
    fi
  fi
  if docker_net::exists "$MGMT_NET"; then
    HAVE_NET=true
    ownership::require_docker_network "$MGMT_NET" || rc=1
  fi
  if [[ "$rc" -ne 0 ]]; then
    log::error "off.sh: refusing to tear down: a target above is present but not owned by '${CLUSTER_NAME}' — nothing was deleted"
    return 1
  fi
  log::info "plan: lab ${LAB_NAME} $([[ $HAVE_LAB == true ]] && echo present || echo absent)," \
    "cluster ${CLUSTER_NAME} $([[ $HAVE_CLUSTER == true ]] && echo present || echo absent)," \
    "network ${MGMT_NET} $([[ $HAVE_NET == true ]] && echo present || echo absent)"
}

# ------------------------------------------------------------------ optional evidence capture
off::_capture() { # <id> -- <cmd…>: a capture that fails is recorded, never fatal
  local id="$1"; shift 2
  local rc=0
  evidence_run "$id" -- "$@" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 3 || "$rc" -eq 2 ]]; then
    log::warn "evidence: capture '$id' was refused by evidence_run (exit $rc)"
  else
    log::info "evidence: captured '$id' (command exit $rc)"
  fi
}

off::capture_evidence() {
  [[ "$PRESERVE_EVIDENCE" == true ]] || return 0
  log::phase TeardownEvidence
  local kctx="kind-${CLUSTER_NAME}"
  if [[ "$HAVE_NET" == true ]]; then
    off::_capture teardown-docker-network -- "${DOCKER:-docker}" network inspect "$MGMT_NET"
  fi
  if [[ "$HAVE_LAB" == true ]]; then
    off::_capture teardown-lab-containers -- "${DOCKER:-docker}" ps -a \
      --filter "label=containerlab=${LAB_NAME}" --format '{{.Names}} {{.Image}} {{.Status}} {{.Labels}}'
  fi
  if [[ "$HAVE_CLUSTER" == true ]]; then
    off::_capture teardown-cluster-workloads -- "${KUBECTL:-kubectl}" --context "$kctx" \
      get namespaces,deployments,statefulsets,daemonsets,services -A -o wide
    # names only — never a Secret's data
    off::_capture teardown-cluster-secret-names -- "${KUBECTL:-kubectl}" --context "$kctx" \
      get secrets -A -l "$(ownership::selector)" -o name
  fi
  log::info "evidence: written to ${EVIDENCE_DIR:-<none>}"
}

# ------------------------------------------------------------------ audit-record export hook
off::_record_discard() { # <outcome text>
  [[ "$DISCARD_AUDIT" == true ]] || return 0
  log::warn "--discard-audit-record was given: $1"
  local rc=0
  evidence_run teardown-discard-audit-record -- printf '%s\n' \
    "off.sh --discard-audit-record given by the operator; cluster=${CLUSTER_NAME}; outcome: $1" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]] || log::warn "evidence: recording the --discard-audit-record use failed (exit $rc)"
}

off::analytics_store_exists() {
  [[ "$HAVE_CLUSTER" == true ]] || return 1
  "${KUBECTL:-kubectl}" --context "kind-${CLUSTER_NAME}" get namespace "$AUDIT_STORE_NS" -o name >/dev/null 2>&1 || return 1
  "${KUBECTL:-kubectl}" --context "kind-${CLUSTER_NAME}" get statefulset "$AUDIT_STORE_STS" \
    -n "$AUDIT_STORE_NS" -o name >/dev/null 2>&1
}

# off::export_audit_record — runs the export whenever the store exists (requested or not). The
# export itself (and the usernames record of data-model.md §16 written with it, before any
# generated Secret is removed) is T088's: OFF_AUDIT_EXPORT_CMD (a command) or the function
# intent_tier::export_audit_record. With the store present and neither available, the export has
# failed — the store is the audit record and is never removed un-exported by default.
off::export_audit_record() {
  log::phase TeardownAuditExport
  if ! off::analytics_store_exists; then
    log::info "audit record: no analytics store (${AUDIT_STORE_NS}/${AUDIT_STORE_STS}) in this cluster — nothing to export"
    # the usernames record of data-model.md §16 is still written before the Secret goes
    if [[ "$HAVE_CLUSTER" == true ]] && declare -F audit_export::usernames_record >/dev/null; then
      audit_export::usernames_record || { log::error "audit record: the usernames record failed: operator-credentials is not removed un-recorded"; return 1; }
    fi
    off::_record_discard "no analytics store existed; nothing was discarded"
    return 0
  fi
  local rc=0 why=""
  if [[ -n "${OFF_AUDIT_EXPORT_CMD:-}" ]]; then
    "$OFF_AUDIT_EXPORT_CMD" "$CLUSTER_NAME" || { rc=$?; why="the export command exited $rc"; }
  elif declare -F intent_tier::export_audit_record >/dev/null; then
    intent_tier::export_audit_record "$CLUSTER_NAME" || { rc=$?; why="the export exited $rc"; }
  else
    rc=1
    why="the analytics store exists but no audit-record export is available in this tree (T088)"
  fi
  if [[ "$rc" -eq 0 ]]; then
    log::info "audit record: exported before teardown"
    off::_record_discard "the export succeeded; nothing was discarded"
    return 0
  fi
  if [[ "$DISCARD_AUDIT" == true ]]; then
    off::_record_discard "the audit-record export FAILED ($why); the store ${AUDIT_STORE_NS}/${AUDIT_STORE_STS} is removed with the cluster, un-exported"
    return 0
  fi
  log::error "audit record: export FAILED ($why): the teardown stops here with the store intact." \
    "Fix the export and re-run, or re-run with --discard-audit-record to remove it un-exported (FR-078)"
  return 1
}

# off::capture_operator_username — data-model.md §22: operator-credentials is removed only AFTER
# its username (never its password) is in the run's evidence, so SC-042 stays reconcilable once the
# Secret is gone. Absent Secret → nothing to capture. (The usernames record beside the audit export
# is T088's; this capture is what off.sh itself guarantees before its own removal.)
off::capture_operator_username() {
  intent_secrets::_exists "$INTENT_SECRETS_OPERATOR" || return 0
  local rc=0
  evidence_run teardown-operator-username -- intent_secrets::username >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log::error "off.sh: capturing the operator username into evidence failed (exit $rc):" \
      "${INTENT_SECRETS_NS}/${INTENT_SECRETS_OPERATOR} is not removed un-captured (FR-102, data-model.md §22)"
    return 1
  fi
  log::info "evidence: captured the operator username (never the password) before removing ${INTENT_SECRETS_OPERATOR}"
}

# ------------------------------------------------------------------ the tier's removal (T088)
# off::purge_intent_tier — see --purge-intent-tier above; every step's detail is in
# scripts/lib/intent_tier.sh. Returns non-zero on a refusal or a stop, having named it.
off::purge_intent_tier() {
  log::phase TierPurge
  declare -F intent_tier::quiesce >/dev/null \
    || { log::error "--purge-intent-tier: scripts/lib/intent_tier.sh (T088) is not in this tree: nothing was touched"; return 1; }
  intent_tier::defaults || return 1
  if ! kind::cluster_exists "$CLUSTER_NAME"; then
    log::info "tier purge: no cluster ${CLUSTER_NAME} — no intent tier to remove"
    return 0
  fi
  kind::_require_owned "$CLUSTER_NAME" || return 1
  HAVE_CLUSTER=true
  KUBE_CONTEXT="kind-${CLUSTER_NAME}"
  export KUBE_CONTEXT
  evidence::ensure_dir || { log::error "tier purge: no evidence directory"; return 1; }
  export EVIDENCE_DIR
  local attempt listing
  local -a a=() c=() r=()
  attempt="$(audit_export::attempt_id)"
  # one attempt identifier for every record of this removal — the lists, the export and the
  # usernames record — so the re-list is found beside the export it followed (T152 r6, R6)
  export AUDIT_EXPORT_ATTEMPT="$attempt"

  # (a) the refusal-decision list — a read, itself a record
  listing="$(intent_tier::list_networks "tier-purge-refusal-list-${attempt}")" || return 1
  mapfile -t a < <(sed '/^$/d' <<<"$listing")
  if [[ ${#a[@]} -gt 0 && "$REMOVE_SERVICES" != true ]]; then
    intent_tier::refuse false "${a[@]}"
    return 1
  fi
  # (b) the quiesce
  intent_tier::quiesce || return 1
  # (c) the authoritative list, after the scale-down
  listing="$(intent_tier::list_networks "tier-purge-authoritative-list-${attempt}")" || return 1
  mapfile -t c < <(sed '/^$/d' <<<"$listing")
  if [[ ${#c[@]} -gt 0 && "$REMOVE_SERVICES" != true ]]; then
    intent_tier::refuse true "${c[@]}"
    return 1
  fi
  # the audit record, before anything removes the store or the operator Secret
  off::export_audit_record || return 1
  # the Networks of (c), and nothing else
  log::phase TierPurgeNetworks
  intent_tier::delete_networks "${c[@]}" || return 1
  intent_tier::wait_networks "${c[@]}" || return 1
  # only once a re-list is empty
  listing="$(intent_tier::list_networks "tier-purge-relist-${attempt}")" || return 1
  mapfile -t r < <(sed '/^$/d' <<<"$listing")
  if [[ ${#r[@]} -gt 0 ]]; then
    log::error "tier purge stopped: a re-list of ${INTENT_TIER_INTENT_NS} is not empty (${r[*]}) — the namespace and the rest of the tier stay; re-run once they are gone"
    return 1
  fi
  log::phase TierPurgeRemove
  intent_tier::grafana_unpatch || return 1
  intent_tier::remove_workloads || return 1
  off::capture_operator_username || return 1
  intent_secrets::remove || { log::error "tier purge: removing the tier's generated Secrets failed"; return 1; }
  intent_tier::remove_claims || return 1
  intent_tier::remove_boundary || return 1
  intent_tier::remove_namespaces || return 1
  log::phase TierAbsent
  log::info "tier purge complete: no tier workload, Secret, provisional claim, admission policy or namespace remains;" \
    "the control plane, agentic-netops-services and the lab's evidence root are untouched"
}

# ------------------------------------------------------------------ run
main() {
  if [[ "$PURGE_TIER" == true ]]; then
    off::purge_intent_tier || exit 1
    return 0
  fi
  off::plan || exit 1
  off::capture_evidence
  off::export_audit_record || exit 1

  log::phase TeardownLab
  containerlab::destroy || { log::error "off.sh: lab removal failed"; exit 1; }

  log::phase TeardownSecrets
  if [[ "$HAVE_CLUSTER" == true ]]; then
    lab_secrets::remove || { log::error "off.sh: removing the generated Secrets failed"; exit 1; }
    off::capture_operator_username || exit 1
    intent_secrets::remove || { log::error "off.sh: removing the intent tier's generated Secrets failed"; exit 1; }
  else
    log::info "no cluster: no generated Secrets to remove"
  fi

  log::phase TeardownAllocation
  if [[ "$HAVE_ALLOC_NS" == true ]]; then
    # owned (checked in the plan); --wait=false: the cluster that holds it goes next
    "${KUBECTL:-kubectl}" --context "kind-${CLUSTER_NAME}" delete namespace "$ALLOC_NS" --ignore-not-found --wait=false >/dev/null \
      || { log::error "off.sh: removing namespace ${ALLOC_NS} (the first-party allocation authority) failed"; exit 1; }
    log::info "removed namespace ${ALLOC_NS} (the first-party allocation authority)"
  else
    log::info "no namespace ${ALLOC_NS}: no first-party allocation authority to remove"
  fi

  log::phase TeardownCluster
  kind::delete_cluster "$CLUSTER_NAME" || { log::error "off.sh: cluster deletion failed"; exit 1; }

  log::phase TeardownNetwork
  docker_net::remove "$MGMT_NET" || { log::error "off.sh: network removal failed"; exit 1; }

  log::phase Absent
  log::info "teardown complete: cluster ${CLUSTER_NAME}, lab ${LAB_NAME}, network ${MGMT_NET} absent; evidence under .evidence/ untouched"
}

main
