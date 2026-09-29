#!/usr/bin/env bash
# rbac.sh — the intent tier's structural safety boundary (T073; FR-075, FR-103, FR-109, SC-028,
# SC-029, AD-19, AD-32, CD-02; contracts/kubernetes-objects.md §"Identity contract").
#
# The boundary step of the IntentTierReady phase (scripts/provision.sh): apply T068–T072, then run
# the denial probes (tests/integration/boundary_probes.sh, T066) BEFORE any agent workload exists,
# and abort the tier phase non-zero on any denial not observed. Sourceable (functions below) and
# runnable:
#
#   rbac.sh apply      apply the boundary, in this order, server-side under one field manager (an
#                      unchanged object is not rewritten):
#                        deploy/rbac/namespaces.yaml             (T068)
#                        deploy/rbac/serviceaccounts.yaml        (T068)
#                        deploy/rbac/roles.yaml                  (T069, intent-writer)
#                        deploy/rbac/claims/<authority>/role.yaml (T069/T182, kuid-claimer — the one
#                                               versions.lock.yaml's allocationAuthority.kind selects)
#                        deploy/rbac/networkpolicies.yaml        (T070, rendered: rbac::render_policies)
#                        deploy/rbac/deny-tier-force-release.yaml (T071; waited type-checked clean)
#                        the tier's Secrets (T072): scripts/lib/intent_secrets.sh
#                                               intent_secrets::ensure_all when that library exists;
#                                               its absence is reported by name, never silent
#   rbac.sh boundary   apply (run-captured: evidence_run rbac.apply, in the run's EVIDENCE_DIR), then
#                      tests/integration/boundary_probes.sh in the same EVIDENCE_DIR; non-zero on any
#                      failure
#   rbac.sh render     print the rendered NetworkPolicies (nothing applied)
#
#   rbac::mgmt_cidr               the real containerlab management subnet: the IPv4 subnet of the
#                                 docker network MGMT_NETWORK; MGMT_CIDR, when set, must equal it
#   rbac::apiserver_endpoints     "<address> <port>" of every API server endpoint (EndpointSlice
#                                 of default/kubernetes); refused when one lies inside the CIDR
#   rbac::cluster_cidrs           "<pod subnet> <service subnet>" (kube-system/kubeadm-config)
#   rbac::render_policies <cidr>  networkpolicies.yaml with every placeholder substituted; refuses
#                                 a placeholder left unsubstituted
#   rbac::claim_role_file         deploy/rbac/claims/<gate::authority_kind>/role.yaml
#   rbac::apply / rbac::boundary  as above
#
# Environment: CLUSTER_NAME (agentic-netops; context kind-<cluster>), KUBE_CONTEXT, MGMT_NETWORK
# (agentic-netops-mgmt), MGMT_CIDR, RBAC_WAIT_TIMEOUT (seconds, 60), KUBECTL / DOCKER (fakes in
# tests), RBAC_PROBES (the probe suite; default tests/integration/boundary_probes.sh).
# Exit (runnable): 0 applied / boundary proven; 1 apply or probe failure; 2 usage.

[[ -n "${__AGENTIC_NETOPS_RBAC_SH:-}" ]] && return 0
__AGENTIC_NETOPS_RBAC_SH=1

RBAC_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=log.sh
source "$RBAC_ROOT/scripts/lib/log.sh"
# shellcheck source=gate.sh
source "$RBAC_ROOT/scripts/lib/gate.sh"

RBAC_DIR="$RBAC_ROOT/deploy/rbac"
RBAC_FIELD_MANAGER="agentic-netops-provision"
RBAC_VAP="deny-tier-force-release"

rbac::defaults() {
  : "${CLUSTER_NAME:=agentic-netops}"
  : "${MGMT_NETWORK:=agentic-netops-mgmt}"
  : "${RBAC_WAIT_TIMEOUT:=60}"
  : "${RBAC_PROBES:=$RBAC_ROOT/tests/integration/boundary_probes.sh}"
  KUBE_CONTEXT="${KUBE_CONTEXT:-kind-${CLUSTER_NAME}}"
}

rbac::k() { "${KUBECTL:-kubectl}" --context "${KUBE_CONTEXT:-kind-${CLUSTER_NAME:-agentic-netops}}" "$@"; }

rbac::_apply_file() { # <file> — server-side apply of one manifest file
  log::info "apply --server-side -f ${1#"$RBAC_ROOT"/}"
  rbac::k apply --server-side --field-manager="$RBAC_FIELD_MANAGER" -f "$1"
}

rbac::_apply_stdin() { # <label>
  log::info "apply --server-side -f - (${1})"
  rbac::k apply --server-side --field-manager="$RBAC_FIELD_MANAGER" -f -
}

# rbac::_norm_cidr <cidr> — the network in canonical form, or non-zero when not an IPv4 network
rbac::_norm_cidr() {
  python3 -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1], strict=False); assert n.version == 4; print(n)' "$1" 2>/dev/null
}

# rbac::_in_cidr <address> <cidr> — 0 when the address lies inside the network
rbac::_in_cidr() {
  python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) else 1)' "$1" "$2"
}

rbac::mgmt_cidr() {
  local net real
  net="$("${DOCKER:-docker}" network inspect "${MGMT_NETWORK:-agentic-netops-mgmt}" 2>/dev/null \
    | jq -r '[.[0].IPAM.Config[]?.Subnet | select(contains(":") | not)] | first // ""' 2>/dev/null)" || net=""
  if [[ -z "$net" ]]; then
    log::error "cannot read the management subnet from the docker network ${MGMT_NETWORK:-agentic-netops-mgmt}: the scoped egress policy is templated from the real containerlab subnet, never assumed"
    return 1
  fi
  real="$(rbac::_norm_cidr "$net")" || { log::error "docker network ${MGMT_NETWORK:-agentic-netops-mgmt} carries no IPv4 subnet (read '${net}')"; return 1; }
  if [[ -n "${MGMT_CIDR:-}" ]]; then
    local want
    want="$(rbac::_norm_cidr "$MGMT_CIDR")" || { log::error "MGMT_CIDR='${MGMT_CIDR}' is not an IPv4 network"; return 1; }
    if [[ "$want" != "$real" ]]; then
      log::error "MGMT_CIDR=${MGMT_CIDR} but the docker network ${MGMT_NETWORK:-agentic-netops-mgmt} is ${real}: refusing to template the egress policy from a CIDR the lab does not use"
      return 1
    fi
  fi
  printf '%s' "$real"
}

rbac::apiserver_endpoints() {
  local json out
  json="$(rbac::k get endpointslices -n default -l kubernetes.io/service-name=kubernetes -o json 2>/dev/null)" || json=""
  [[ -n "$json" ]] || json='{}'
  out="$(jq -r '.items[]? | (.ports // [] | map(select(.name == "https" or .name == null)) | first | .port // empty) as $p
                | .endpoints[]? | select(.conditions.ready != false) | .addresses[]? | "\(.) \($p)"' <<<"$json" 2>/dev/null | grep -E '^[0-9.]+ [0-9]+$' | LC_ALL=C sort -u)" || out=""
  if [[ -z "$out" ]]; then
    json="$(rbac::k get endpoints kubernetes -n default -o json 2>/dev/null)" || json=""
    [[ -n "$json" ]] || json='{}'
    out="$(jq -r '.subsets[]? | (.ports // [] | first | .port) as $p | .addresses[]? | "\(.ip) \($p)"' <<<"$json" 2>/dev/null \
      | grep -E '^[0-9.]+ [0-9]+$' | LC_ALL=C sort -u)" || out=""
  fi
  [[ -n "$out" ]] || { log::error "cannot read the API server endpoints (default/kubernetes EndpointSlice)"; return 1; }
  printf '%s\n' "$out"
}

# rbac::cluster_cidrs — "<pod subnet> <service subnet>" from kube-system/kubeadm-config
rbac::cluster_cidrs() {
  local cc pod svc
  cc="$(rbac::k get configmap kubeadm-config -n kube-system -o json 2>/dev/null | jq -r '.data.ClusterConfiguration // ""' 2>/dev/null)" || cc=""
  pod="$(yq -r '.networking.podSubnet // ""' <<<"$cc" 2>/dev/null)" || pod=""
  svc="$(yq -r '.networking.serviceSubnet // ""' <<<"$cc" 2>/dev/null)" || svc=""
  pod="$(rbac::_norm_cidr "${pod%%,*}")" || pod=""
  svc="$(rbac::_norm_cidr "${svc%%,*}")" || svc=""
  if [[ -z "$pod" || -z "$svc" ]]; then
    log::error "cannot read the cluster's pod and service subnets (kube-system/kubeadm-config networking.podSubnet/serviceSubnet): the scoped egress policy excludes both and is never applied with a guess"
    return 1
  fi
  printf '%s %s' "$pod" "$svc"
}

rbac::render_policies() {
  local cidr="${1:?rbac::render_policies <mgmt-cidr>}" eps a p port="" cidrs="" peers="" out podnet svcnet
  read -r podnet svcnet < <(rbac::cluster_cidrs; echo) || true
  [[ -n "$podnet" && -n "$svcnet" ]] || return 1
  eps="$(rbac::apiserver_endpoints)" || return 1
  while read -r a p; do
    [[ -n "$a" ]] || continue
    if rbac::_in_cidr "$a" "$cidr"; then
      log::error "the API server endpoint ${a} lies inside the management CIDR ${cidr}: the scoped egress policy would have to open part of the CIDR it drops — refused"
      return 1
    fi
    if [[ -n "$port" && "$p" != "$port" ]]; then
      log::error "the API server endpoints use different ports (${port}, ${p}): not representable as one policy port"
      return 1
    fi
    port="$p"
    cidrs+="${cidrs:+, }${a}/32"
    peers+="${peers:+, }{ipBlock: {cidr: ${a}/32}}"
  done <<<"$eps"
  out="$(sed -e "s|__MGMT_CIDR__|${cidr}|g" -e "s|__POD_CIDR__|${podnet}|g" -e "s|__SERVICE_CIDR__|${svcnet}|g" -e "s|__APISERVER_CIDRS__|${cidrs}|g" \
             -e "s|__APISERVER_PEERS__|${peers}|g" -e "s|__APISERVER_PORT__|${port}|g" "$RBAC_DIR/networkpolicies.yaml")"
  if grep -v '^#' <<<"$out" | grep -qE '__[A-Z_]+__'; then
    log::error "deploy/rbac/networkpolicies.yaml: a placeholder is left unsubstituted: $(grep -v '^#' <<<"$out" | grep -oE '__[A-Z_]+__' | sort -u | paste -sd' ' -)"
    return 1
  fi
  printf '%s\n' "$out"
}

rbac::claim_role_file() {
  local kind f
  kind="$(gate::authority_kind)" || return 1
  f="$RBAC_DIR/claims/${kind}/role.yaml"
  [[ -f "$f" ]] || { log::error "no claim Role for the selected authority ${kind}: ${f#"$RBAC_ROOT"/} is missing"; return 1; }
  printf '%s' "$f"
}

# rbac::wait_policy — the admission policy exists, is observed at its generation and type-checks
# with no warning (a typo in a field path would make it a silent no-op)
rbac::wait_policy() {
  local deadline json
  deadline=$((SECONDS + ${RBAC_WAIT_TIMEOUT:-60}))
  while :; do
    json="$(rbac::k get validatingadmissionpolicy "$RBAC_VAP" -o json 2>/dev/null)" || json=""
    if [[ -n "$json" ]] && jq -e '(.status.observedGeneration // 0) >= .metadata.generation' <<<"$json" >/dev/null 2>&1; then
      if jq -e '(.status.typeChecking.expressionWarnings // []) | length > 0' <<<"$json" >/dev/null 2>&1; then
        log::error "ValidatingAdmissionPolicy ${RBAC_VAP} does not type-check cleanly: $(jq -c '.status.typeChecking.expressionWarnings' <<<"$json")"
        return 1
      fi
      rbac::k get validatingadmissionpolicybinding "$RBAC_VAP" -o name >/dev/null 2>&1 \
        || { log::error "ValidatingAdmissionPolicyBinding ${RBAC_VAP} is missing"; return 1; }
      log::info "ValidatingAdmissionPolicy ${RBAC_VAP} observed at generation $(jq -r .metadata.generation <<<"$json"), type-checked with no warning; binding present"
      return 0
    fi
    (( SECONDS < deadline )) || { log::error "ValidatingAdmissionPolicy ${RBAC_VAP} was not observed within ${RBAC_WAIT_TIMEOUT:-60}s"; return 1; }
    sleep 2
  done
}

# rbac::apply_secrets — T072's generator, coordinated by existence (it is built beside this file)
rbac::apply_secrets() {
  local lib="$RBAC_ROOT/scripts/lib/intent_secrets.sh"
  if [[ ! -f "$lib" ]]; then
    log::warn "T072 not present: scripts/lib/intent_secrets.sh is absent — the tier's Secrets (slim-gateway, clickhouse-auth, llm-provider, operator-credentials) were NOT generated"
    return 0
  fi
  (
    # shellcheck disable=SC1090
    source "$lib" || exit 1
    declare -F intent_secrets::ensure_all >/dev/null \
      || { log::error "scripts/lib/intent_secrets.sh defines no intent_secrets::ensure_all"; exit 1; }
    intent_secrets::ensure_all
  ) || { log::error "the tier's secret step (scripts/lib/intent_secrets.sh intent_secrets::ensure_all) failed"; return 1; }
}

rbac::apply() {
  rbac::defaults
  local cidr claim rendered
  cidr="$(rbac::mgmt_cidr)" || return 1
  claim="$(rbac::claim_role_file)" || return 1
  rendered="$(rbac::render_policies "$cidr")" || return 1
  log::info "safety boundary: management CIDR ${cidr} (docker network ${MGMT_NETWORK}), claim Role $(gate::authority_display "$(gate::authority_kind)")"
  rbac::_apply_file "$RBAC_DIR/namespaces.yaml" || return 1
  rbac::_apply_file "$RBAC_DIR/serviceaccounts.yaml" || return 1
  rbac::_apply_file "$RBAC_DIR/roles.yaml" || return 1
  rbac::_apply_file "$claim" || return 1
  printf '%s\n' "$rendered" | rbac::_apply_stdin "deploy/rbac/networkpolicies.yaml rendered for ${cidr}" || return 1
  rbac::_apply_file "$RBAC_DIR/deny-tier-force-release.yaml" || return 1
  rbac::wait_policy || return 1
  rbac::apply_secrets || return 1
  log::info "safety boundary applied (T068–T072); nothing of the tier's workloads exists yet"
}

rbac::boundary() {
  rbac::defaults
  # the apply is run-captured into the same evidence directory the probes write (NFR-013)
  if ! declare -F evidence_run >/dev/null; then
    # shellcheck source=evidence.sh
    source "$RBAC_ROOT/scripts/lib/evidence.sh"
  fi
  evidence::ensure_dir || { log::error "boundary step: no evidence directory"; return 1; }
  export EVIDENCE_DIR
  local id="rbac.apply" n=1
  while [[ -e "$EVIDENCE_DIR/$id.json" ]]; do n=$((n + 1)); id="rbac.apply-${n}"; done
  evidence_run "$id" -- bash "$RBAC_ROOT/scripts/lib/rbac.sh" apply \
    || { log::error "boundary step: applying the safety boundary failed — the tier phase is aborted"; return 1; }
  # an idempotent re-run on a STANDING tier (quickstart §1, §20): the agents already exist, so the
  # probes run in their standing-tier mode (BP_TIER_DEPLOYED=1, T150) — T070's four policies present,
  # every other one declared by a tier manifest, the denials re-proven with the agents running —
  # rather than refusing a re-run the phase is required to accept (FR-010)
  local standing=""
  standing="$(rbac::k get deployments,statefulsets -n "${TIER_NS:-agentic-netops-agents}" -o name 2>/dev/null)" || standing=""
  if [[ -n "$standing" ]]; then
    export BP_TIER_DEPLOYED=1
    log::info "boundary step: the tier is already standing ($(echo "$standing" | wc -l) workloads) — re-proving the denials in standing-tier mode (BP_TIER_DEPLOYED=1)"
  else
    log::info "boundary step: running the denial probes (${RBAC_PROBES#"$RBAC_ROOT"/}) before any agent workload is created"
  fi
  if ! bash "$RBAC_PROBES"; then
    log::error "boundary step: a denial was NOT observed (see the probe evidence) — the tier phase is aborted before any agent workload is created"
    return 1
  fi
  log::info "boundary step: every denial observed, the allow-list exact, every dial timed out, the counter moved"
}

rbac::main() {
  local cmd="${1:-}"
  case "$cmd" in
    apply) rbac::apply ;;
    boundary) rbac::boundary ;;
    render) rbac::defaults; local c; c="$(rbac::mgmt_cidr)" || return 1; rbac::render_policies "$c" ;;
    -h|--help|help) sed -n '2,/^\[\[ -n/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' ;;
    *) log::error "usage: rbac.sh apply|boundary|render"; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  rbac::main "$@"
fi
