#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2046  # SC2046: the VNI list is split into arguments on purpose
# tests/integration/provider_claims.sh — the provider claims every VNI itself, before any Config
# (T172; FR-109, SC-045, NFR-013; AD-32, AD-33, AD-50; contracts/kuid-claim-profiles.md §8).
#
# Behind `make test-provider-claims`; run with NO intent tier installed. Against the first-party
# allocation authority (IdentifierClaim in agentic-netops-allocation):
#   (0) negative control first: the claim check against a Network whose claim was deleted by hand —
#       the recreated claim is younger than the Network's first Config, so the check MUST fail
#   (1) examples/constructs/{macvrf,ipvrf}.yaml applied: a claim-selector diff shows ONE bound claim
#       per VNI labelled with its Network, created no later than that Network's first Config
#   (2) a second Network naming the same L2VNI: Accepted=False/AllocationConflict naming the value
#       and the first Network, zero Configs (deleted again)
#   (3) the VLAN half: examples/constructs/negative/vlan-unclaimed-band.yaml, applied by its own
#       path: Accepted=False/AllocationConflict naming VLAN 1500 and both bands, zero Configs, zero
#       claims (deleted again); the naming-band VLANs of (1) accepted with ZERO VLAN claims
#   (4) after deleting the Networks of (1) the selector is empty; with --reapply (default) they are
#       applied again and waited Ready, so the lab is left as found.
#
# Usage: provider_claims.sh [--no-reapply]
# Environment: EVIDENCE_DIR, CLUSTER_NAME, SV_WAIT (300 s), SV_INTENT_NS (agentic-netops-intent).
set -euo pipefail

PC_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/services.sh
source "$PC_HERE/lib/services.sh"
# shellcheck source=../gate/lib/gate.sh
source "$SV_ROOT/tests/gate/lib/gate.sh"

: "${SV_WAIT:=300}"
: "${SV_INTENT_NS:=agentic-netops-intent}"
PC_LIB="$PC_HERE/lib/services.sh"
PC_MANIFESTS=("$SV_CONSTRUCTS/macvrf.yaml" "$SV_CONSTRUCTS/ipvrf.yaml")
PC_UNCLAIMED="$SV_CONSTRUCTS/negative/vlan-unclaimed-band.yaml"
PC_DUP="vt-scratch-dup-l2vni"
PC_FAILS=()
pc::fail() { PC_FAILS+=("$1"); log::error "FAIL $1"; }
pc::ok()   { log::info "PASS $1"; }
usage() { echo "usage: $0 [--no-reapply]" >&2; return 2; }

# pc::vnis <network> — the VNIs its spec states
pc::vnis() { sv::k -n "$SV_NS" get "$SV_NET_RES" "$1" -o json | jq -r '[.spec.bridgeDomains[]?.l2vni, .spec.routers[]?.l3vni] | map(select(. != null)) | .[]'; }

pc::dup_manifest() {
  cat <<YAML
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
metadata: {name: ${PC_DUP}, namespace: ${SV_NS}}
spec:
  description: provider-claims check — a second Network naming lab-macvrf's L2VNI 10120
  bridgeDomains:
  - {name: bd121, vlan: 121, l2vni: 10120}
  attachments:
  - {node: leaf02, attachment: ethernet-1/1, vlan: 121}
YAML
}

pc::cleanup() {
  sv::k -n "$SV_NS" delete "$SV_NET_RES" "$PC_DUP" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
  sv::k delete -f "$PC_UNCLAIMED" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
}

main() {
  local reapply=1 m ns name rc n cl
  case "${1:-}" in "") ;; --no-reapply) reapply=0 ;; *) usage; return 2 ;; esac
  [[ $# -le 1 ]] || { usage; return 2; }
  log::phase ProviderClaims
  gate::init
  if sv::k get ns "$SV_INTENT_NS" >/dev/null 2>&1; then
    log::error "an intent tier is installed (namespace $SV_INTENT_NS): this check runs with none (T172)"; return 3
  fi
  trap pc::cleanup EXIT
  local nets; nets="$(sv::manifest_networks "${PC_MANIFESTS[@]}")"
  # start from nothing, so "before its first Config" is observed on a fresh claim
  while read -r ns name; do
    gate::run "PC.pre-delete.${name}" -- sv::k -n "$ns" delete "$SV_NET_RES" "$name" --ignore-not-found --wait=true --timeout=300s || return 1
    CHECK_WAIT="$SV_WAIT" gate::run "PC.pre-empty.${name}" -- bash "$PC_LIB" no_claims "$ns" "$name" || { log::error "claims of $name not released"; return 1; }
  done <<<"$nets"
  for m in "${PC_MANIFESTS[@]}"; do gate::run "PC.apply.$(basename "$m" .yaml)" -- sv::k apply -f "$m" || return 1; done
  # (0) negative control: hand-delete the first Network's claim once its Config exists
  read -r ns name <<<"$(head -1 <<<"$nets")"
  CHECK_WAIT="$SV_WAIT" gate::run "PC.control.configs.${name}" -- bash "$PC_LIB" configs "$ns" "$name" 1 || { pc::fail "$name has no Config"; return 1; }
  cl="$(sv::claims_json "$ns" "$name" | jq -r '.[0].name // empty')"
  [[ -n "$cl" ]] || { pc::fail "$name has no claim to delete for the control"; return 1; }
  gate::run "PC.control.delete-claim" -- sv::k -n "$SV_ALLOC_NS" delete "$SV_CLAIM_RES" "$cl" --wait=true --timeout=120s || return 1
  rc=0; evidence_negative_control PC-claims-bound -- bash "$PC_LIB" claims_bound "$ns" "$name" $(pc::vnis "$name") || rc=$?
  [[ "$rc" -eq 0 ]] || { pc::fail "PC-claims-bound negative control not admitted (rc=$rc)"; return 1; }
  # re-create the first Network so its claim again precedes its Config
  gate::run "PC.control.recreate.${name}" -- sv::k -n "$ns" delete "$SV_NET_RES" "$name" --wait=true --timeout=300s || return 1
  CHECK_WAIT="$SV_WAIT" gate::run "PC.control.empty.${name}" -- bash "$PC_LIB" no_claims "$ns" "$name" || return 1
  gate::run "PC.control.reapply.${name}" -- sv::k apply -f "$(grep -l "name: ${name}$" "${PC_MANIFESTS[@]}")" || return 1
  # (1) one bound claim per VNI, before the first Config; zero VLAN claims (naming band)
  while read -r ns name; do
    rc=0; CHECK_WAIT="$SV_WAIT" evidence_run "PC.claims-bound.${name}" --check PC-claims-bound --readiness --records SC-045 \
      -- bash "$PC_LIB" claims_bound "$ns" "$name" $(pc::vnis "$name") || rc=$?
    [[ "$rc" -eq 0 ]] && pc::ok "$name: one bound claim per VNI before its first Config" || pc::fail "$name claims"
    rc=0; evidence_run "PC.no-vlan-claims.${name}" -- bash "$PC_LIB" no_claims "$ns" "$name" vlan || rc=$?
    [[ "$rc" -eq 0 ]] && pc::ok "$name: zero VLAN claims (naming band)" || pc::fail "$name has VLAN claims"
  done <<<"$nets"
  # (2) the same L2VNI named twice
  pc::dup_manifest >"$EVIDENCE_DIR/provider-claims-dup.yaml"
  gate::run PC.dup.apply --attach provider-claims-dup.yaml -- sv::k apply -f "$EVIDENCE_DIR/provider-claims-dup.yaml" || pc::fail "dup apply"
  rc=0; CHECK_WAIT="$SV_WAIT" evidence_run PC.dup.conflict --records SC-045 -- \
    bash "$PC_LIB" condition "$SV_NS" "$PC_DUP" Accepted False AllocationConflict 10120 lab-macvrf || rc=$?
  [[ "$rc" -eq 0 ]] && pc::ok "$PC_DUP Accepted=False/AllocationConflict naming 10120 and lab-macvrf" || pc::fail "duplicate L2VNI not refused as stated"
  rc=0; evidence_run PC.dup.no-configs -- bash "$PC_LIB" no_configs "$SV_NS" "$PC_DUP" || rc=$?
  [[ "$rc" -eq 0 ]] || pc::fail "$PC_DUP has Configs"
  gate::run PC.dup.delete -- sv::k -n "$SV_NS" delete "$SV_NET_RES" "$PC_DUP" --wait=true --timeout=120s || pc::fail "dup delete"
  # (3) the VLAN half: an allocation-band VLAN with no claim
  gate::run PC.unclaimed.apply -- sv::k apply -f "$PC_UNCLAIMED" || pc::fail "apply $PC_UNCLAIMED"
  rc=0; CHECK_WAIT="$SV_WAIT" evidence_run PC.unclaimed.conflict --records SC-045 -- \
    bash "$PC_LIB" condition "$SV_NS" lab-vlan-unclaimed Accepted False AllocationConflict 1500 100 999 1000 4000 || rc=$?
  [[ "$rc" -eq 0 ]] && pc::ok "lab-vlan-unclaimed Accepted=False/AllocationConflict naming VLAN 1500 and both bands" || pc::fail "unclaimed-band VLAN not refused as stated"
  rc=0; evidence_run PC.unclaimed.no-configs -- bash "$PC_LIB" no_configs "$SV_NS" lab-vlan-unclaimed || rc=$?
  [[ "$rc" -eq 0 ]] || pc::fail "lab-vlan-unclaimed has Configs"
  rc=0; evidence_run PC.unclaimed.no-claims -- bash "$PC_LIB" no_claims "$SV_NS" lab-vlan-unclaimed || rc=$?
  [[ "$rc" -eq 0 ]] || pc::fail "lab-vlan-unclaimed has claims"
  gate::run PC.unclaimed.delete -- sv::k delete -f "$PC_UNCLAIMED" --wait=true --timeout=120s || pc::fail "delete $PC_UNCLAIMED"
  # (4) after deletion the selector is empty
  while read -r ns name; do
    gate::run "PC.delete.${name}" -- sv::k -n "$ns" delete "$SV_NET_RES" "$name" --wait=true --timeout=300s || pc::fail "delete $name"
    rc=0; CHECK_WAIT="$SV_WAIT" evidence_run "PC.released.${name}" --records SC-045 -- bash "$PC_LIB" no_claims "$ns" "$name" || rc=$?
    [[ "$rc" -eq 0 ]] && pc::ok "$name: claim selector empty after deletion" || pc::fail "$name claims remain after deletion"
  done <<<"$nets"
  if [[ "$reapply" == 1 ]]; then
    for m in "${PC_MANIFESTS[@]}"; do gate::run "PC.reapply.$(basename "$m" .yaml)" -- sv::k apply -f "$m" || pc::fail "re-apply $m"; done
    while read -r ns name; do
      CHECK_WAIT="$SV_WAIT" gate::run "PC.reapply-ready.${name}" -- bash "$PC_LIB" condition "$ns" "$name" Ready True || pc::fail "$name not Ready after re-apply"
    done <<<"$nets"
  fi
  n=${#PC_FAILS[@]}
  [[ "$n" -eq 0 ]] || { log::error "test-provider-claims FAILED: ${PC_FAILS[*]}"; return 1; }
  log::info "test-provider-claims passed (evidence: $EVIDENCE_DIR)"
}

main "$@"
