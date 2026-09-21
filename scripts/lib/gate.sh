#!/usr/bin/env bash
# gate.sh — the capability gate's early hook and the allocation-authority selection
# (T044, T048; FR-104, FR-109, CD-03, AD-09, R-31, R-44, SC-047; data-model.md §23;
# contracts/kuid-claim-profiles.md §6–§7).
#
# Gate item G11 — the allocation claim round-trip — needs only the cluster and the
# authority, so provisioning evaluates it AS SOON AS the authority is installed
# (quickstart.md §1, AppsReady). On failure provisioning stops, non-zero, naming G11,
# with nothing above the authority installed. Nothing here, and no flag or variable
# anywhere in the lifecycle, selects another allocator: the only selection is the
# lock file's `allocationAuthority.kind` (kuid | first-party), recorded by operator
# decision and refused by `make verify-pins` without its references.
#
#   gate::authority_kind [lock]     print the lock file's allocationAuthority.kind
#   gate::authority_display <kind>  the authority's name as warnings and errors print it
#   gate::warn_substitute [lock]    on `first-party`, warn the substitute BY NAME (every run)
#   gate::g11_early                 run tests/gate/g11_allocation_claim.sh; on failure name
#                                   G11 and return non-zero
#   gate::authority_namespace <kind>  the namespace the authority's pools and claims live in
#   gate::authority_pool_ref <kind> <ip|asn|vlan|vni>
#                                   "<group> <kind> <namespace>" of a pool reference to that
#                                   authority's pool of that type — what a Fabric's pool
#                                   references carry; the name is the same on both sides
#                                   (deploy/allocation/pools is generated from deploy/kuid/indices)
#
# The lock file is the tree's own <repo>/versions.lock.yaml and the round trip the tree's
# own tests/gate/g11_allocation_claim.sh: neither path is overridable by a flag or a
# variable (the offline suite runs a copy of the tree with a fixture lock file instead).
# EVIDENCE_DIR is the run's evidence directory.

[[ -n "${__AGENTIC_NETOPS_GATE_SH:-}" ]] && return 0
__AGENTIC_NETOPS_GATE_SH=1

# shellcheck source=log.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/log.sh"

GATE_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

gate::_lock() { printf '%s' "${1:-$GATE_REPO_ROOT/versions.lock.yaml}"; }

# gate::authority_kind [lock] — the lock file's selection; fails on anything but the two
# admitted values (an absent key is not a default: it is refused).
gate::authority_kind() {
  local lock kind
  lock="$(gate::_lock "${1:-}")"
  [[ -f "$lock" ]] || { log::error "allocation authority: lock file ${lock} not found"; return 2; }
  kind="$(yq -r '.allocationAuthority.kind // ""' "$lock" 2>/dev/null)" || kind=""
  case "$kind" in
    kuid|first-party) printf '%s' "$kind" ;;
    *) log::error "allocation authority: ${lock} allocationAuthority.kind is '${kind:-<absent>}'; admitted: kuid | first-party (data-model.md §23)"
       return 2 ;;
  esac
}

gate::authority_display() {
  case "$1" in
    kuid) printf 'kuid-server (the pinned upstream allocation authority, *.be.kuid.dev)' ;;
    first-party) printf 'the first-party allocator substitute (IdentifierPool/IdentifierClaim in fabric.agentic-netops.io, namespace agentic-netops-allocation)' ;;
    none) printf 'no allocation authority' ;;
    *) printf '%s' "$1" ;;
  esac
}

# gate::authority_namespace <kind>
gate::authority_namespace() {
  case "$1" in
    kuid) printf 'kuid-system' ;;
    first-party) printf 'agentic-netops-allocation' ;;
    *) log::error "allocation authority: unknown kind '$1' (kuid | first-party)"; return 2 ;;
  esac
}

# gate::authority_pool_ref <kind> <ip|asn|vlan|vni> — "<group> <kind> <namespace>" (data-model.md
# §23: under substitution a Fabric's pool references change group and kind — and namespace —
# and nothing else).
gate::authority_pool_ref() {
  local authority="$1" type="${2:-}"
  case "$authority:$type" in
    kuid:ip)   printf 'ipam.be.kuid.dev IPIndex kuid-system' ;;
    kuid:asn)  printf 'as.be.kuid.dev ASIndex kuid-system' ;;
    kuid:vlan) printf 'vlan.be.kuid.dev VLANIndex kuid-system' ;;
    kuid:vni)  printf 'genid.be.kuid.dev GENIDIndex kuid-system' ;;
    first-party:ip|first-party:asn|first-party:vlan|first-party:vni)
               printf 'fabric.agentic-netops.io IdentifierPool agentic-netops-allocation' ;;
    *) log::error "allocation authority: no pool reference for '${authority}' type '${type}' (kuid | first-party; ip | asn | vlan | vni)"
       return 2 ;;
  esac
}

# gate::warn_substitute [lock] — the one pin exception is warned by name on every run.
gate::warn_substitute() {
  local kind
  kind="$(gate::authority_kind "${1:-}")" || return 2
  if [[ "$kind" == first-party ]]; then
    local lock; lock="$(gate::_lock "${1:-}")"
    log::warn "ALLOCATION AUTHORITY SUBSTITUTED: versions.lock.yaml selects $(gate::authority_display first-party)" \
      "instead of kuid-server — the one pin exception (FR-104, CD-03);" \
      "decision record: $(yq -r '.allocationAuthority.decisionRecord // "<absent>"' "$lock")," \
      "failed G11 evidence: $(yq -r '.allocationAuthority.failedGateEvidence.path // "<absent>"' "$lock")"
  fi
  return 0
}

# gate::g11_early — G11, evaluated as soon as the authority is installed.
gate::g11_early() {
  local kind script rc=0
  kind="$(gate::authority_kind)" || return 2
  gate::warn_substitute "" || return 2
  script="$GATE_REPO_ROOT/tests/gate/g11_allocation_claim.sh"
  if [[ ! -f "$script" ]]; then
    log::error "G11 FAILED: the claim round-trip ${script} is missing; provisioning stops with nothing above the allocation authority installed (FR-104)"
    return 1
  fi
  log::info "G11: allocation claim round-trip against $(gate::authority_display "$kind") (contracts/kuid-claim-profiles.md §6)"
  bash "$script" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log::error "G11 FAILED (exit ${rc}): the allocation authority $(gate::authority_display "$kind") failed its claim round-trip on this cluster."
    log::error "G11: provisioning stops here, non-zero, with nothing above the allocation authority installed; no other allocator is selected (FR-104)."
    log::error "G11: evidence: ${EVIDENCE_DIR:-<EVIDENCE_DIR>}/g11-*.json and g11-observations.json;" \
      "see quickstart.md §Diagnosing a failure (\"Provisioning stops naming G11\")."
    return 1
  fi
  log::info "G11 passed: observations (a)–(f) recorded in ${EVIDENCE_DIR:-<EVIDENCE_DIR>}/g11-observations.json"
  return 0
}
