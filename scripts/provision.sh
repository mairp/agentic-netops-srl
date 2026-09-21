#!/usr/bin/env bash
# provision.sh — the sole lifecycle up-path (T048; FR-010, FR-015, FR-104, NFR-003, C-18;
# quickstart.md §1 — the one statement of the phase order, AD-50; data-model.md §23).
#
#   MGMT_CIDR=172.25.25.0/24 ./scripts/provision.sh --cluster-name agentic-netops [--with-intent-tier]
#
# Phases, in this order, each waiting with a bounded timeout before the next starts:
#   NetworkReady   pins (scripts/lib/verify_pins.sh — `make verify-pins`) and host preflight
#                  (preflight::run) pass; the owned docker network agentic-netops-mgmt exists
#                  on MGMT_CIDR (docker_net::ensure)
#   ClusterReady   the pinned kind cluster exists — never recreated when it does — and every
#                  node is attached to the management network (kind::ensure_cluster,
#                  kind::attach_mgmt)
#   LabReady       the containerlab topology is deployed and every device's gNMI port accepts
#                  a connection (containerlab::deploy, containerlab::wait_gnmi_accept)
#   AppsReady      cert-manager → the allocation authority the lock file selects (KUID) →
#                  gate item G11 (gate::g11_early: on failure provisioning STOPS here, non-zero,
#                  naming G11, with nothing above the authority installed) → the
#                  device-configuration layer (SDC) → the SR Linux provider (DRIFT_POLICY set to
#                  `revertive` explicitly, the image built from the tree). NOT the observability
#                  stack: that is ObservabilityReady's, after FabricReady (T134, AD-50).
#   TargetsReady   lab secrets (lab_secrets::ensure), deploy/sdc/onboarding/ (scripts/lib/
#                  sdc_onboard.sh), the four device Targets (targets.config.sdcio.dev — the group
#                  v0.0.58 serves) Ready (scripts/lib/wait_targets.sh)
#   GateReady      tests/gate/run_gate.sh wrote the gate record; tests/gate/publish_qualification.sh
#   FabricReady    examples/fabric/ applied; every Fabric in it reports Ready
#   IntentTierReady  (--with-intent-tier) not built yet: the run FAILS naming it — it is never
#                  silently skipped
#
# Flags / environment:
#   --cluster-name <name>   (env CLUSTER_NAME, default agentic-netops; context kind-<name>)
#   --with-intent-tier      request the intent-tier phase
#   MGMT_CIDR               the management network CIDR (default 172.25.25.0/24)
#   SRL_USER / SRL_PASS     the lab operator's device credentials, handed to the lab-secret step
#                           and the gate (default: containerlab's nokia_srlinux defaults)
#   PROVISION_WAIT_TIMEOUT  seconds, every rollout/availability wait (default 300)
#   PROVISION_TARGETS_TIMEOUT / PROVISION_FABRIC_TIMEOUT  seconds (default 600 / 900)
#   KUBECTL                 the kubectl binary (default kubectl)
# There is no device-profile flag and no allocator flag, and no variable selects either: the
# allocation authority is the lock file's `allocationAuthority.kind` and nothing else (FR-104).
# The substitute (`first-party`) is warned by name on every run.
#
# Allocation authority (FR-104, AD-49): exactly one is installed — the lock file's. When the
# lock selects an authority other than the one installed (in either direction), AppsReady lists
# the bound claims the installed one holds and, if there is any, stops non-zero BEFORE touching
# either authority, naming each service that rests on one: those services are removed first
# and re-created after the switch — no claim survives a change of authority, none is migrated.
#
# Idempotent: a re-run converges — the cluster is never recreated, every object is applied
# server-side under one field manager (an unchanged object is not rewritten, so nothing
# churns), and the provider reissues no unchanged device configuration (render-hash compare).
#
# Test hook (tests only): sourcing this file defines every phase as a function
# (provision::phase_<Phase>) and runs nothing; the offline suites call provision::defaults
# and then one phase directly, against fake binaries in a copy of the tree. The script run
# as a command always drives every phase in order — there is no flag or variable that
# skips, reorders or selects phases, and none that skips a gate.
set -euo pipefail

PROVISION_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROVISION_LIB="$PROVISION_ROOT/scripts/lib"

# shellcheck source=lib/log.sh
source "$PROVISION_LIB/log.sh"
# shellcheck source=lib/dotenv.sh
source "$PROVISION_LIB/dotenv.sh"
# shellcheck source=lib/evidence.sh
source "$PROVISION_LIB/evidence.sh"
# shellcheck source=lib/k8s_wait.sh
source "$PROVISION_LIB/k8s_wait.sh"
# shellcheck source=lib/ownership.sh
source "$PROVISION_LIB/ownership.sh"
# shellcheck source=lib/gate.sh
source "$PROVISION_LIB/gate.sh"
# The lifecycle libraries (stream A1). A missing one fails the phase that needs it, naming it.
for __lib in preflight docker_net kind containerlab lab_secrets image_build; do
  # shellcheck disable=SC1090
  if [[ -f "$PROVISION_LIB/${__lib}.sh" ]]; then source "$PROVISION_LIB/${__lib}.sh"; fi
done
unset __lib

PROVISION_PHASES=(NetworkReady ClusterReady LabReady AppsReady TargetsReady GateReady FabricReady)
PROVISION_FIELD_MANAGER="agentic-netops-provision"
MGMT_NETWORK="agentic-netops-mgmt"
PROVIDER_NS="agentic-netops-system"
PROVIDER_DEPLOYMENT="srl-provider"
PROVIDER_IMAGE_NAME="srl-provider"
KUID_APISERVICES=(v1alpha1.vlan.be.kuid.dev v1alpha1.genid.be.kuid.dev v1alpha1.ipam.be.kuid.dev v1alpha1.as.be.kuid.dev)
KUID_CLAIM_RESOURCES="vlanclaims.vlan.be.kuid.dev,genidclaims.genid.be.kuid.dev,ipclaims.ipam.be.kuid.dev,asclaims.as.be.kuid.dev"
FIRSTPARTY_CRDS=(identifierpools.fabric.agentic-netops.io identifierclaims.fabric.agentic-netops.io)
FIRSTPARTY_NS="agentic-netops-allocation"

provision::defaults() {
  : "${CLUSTER_NAME:=agentic-netops}"
  : "${LAB_NAME:=agentic-netops-fabric}"
  : "${MGMT_CIDR:=172.25.25.0/24}"
  : "${SRL_USER:=admin}"
  : "${SRL_PASS:=NokiaSrl1!}"
  : "${PROVISION_WAIT_TIMEOUT:=300}"
  : "${PROVISION_TARGETS_TIMEOUT:=600}"
  : "${PROVISION_FABRIC_TIMEOUT:=900}"
  KUBE_CONTEXT="kind-${CLUSTER_NAME}"
  export CLUSTER_NAME LAB_NAME MGMT_CIDR SRL_USER SRL_PASS KUBE_CONTEXT
}

provision::k() { "${KUBECTL:-kubectl}" --context "kind-${CLUSTER_NAME}" "$@"; }

# provision::need <function> <library> — the lifecycle library function must exist.
provision::need() {
  declare -F "$1" >/dev/null && return 0
  log::error "$1 is not available: scripts/lib/$2.sh is missing or does not define it"
  return 1
}

# provision::apply_k <dir> — server-side apply of one kustomization (unchanged → no write).
provision::apply_k() {
  local dir="$1"
  [[ -f "$dir/kustomization.yaml" ]] || { log::error "no kustomization.yaml in ${dir}"; return 1; }
  log::info "apply --server-side -k ${dir#"$PROVISION_ROOT"/}"
  provision::k apply --server-side --field-manager="$PROVISION_FIELD_MANAGER" -k "$dir"
}

# provision::apply_stdin — server-side apply of the manifest on stdin.
provision::apply_stdin() {
  provision::k apply --server-side --field-manager="$PROVISION_FIELD_MANAGER" -f -
}

provision::wait_deployments() {  # <namespace>
  local ns="$1" out
  if ! out="$(provision::k wait deployment --all -n "$ns" --for=condition=Available --timeout="${PROVISION_WAIT_TIMEOUT}s" 2>&1)"; then
    log::error "timed out after ${PROVISION_WAIT_TIMEOUT}s waiting for every Deployment in ${ns} to be Available"
    printf '%s\n' "$out" | sed 's/^/    | /' >&2
    log::error "  next: ${KUBECTL:-kubectl} --context kind-${CLUSTER_NAME} -n ${ns} get deploy,pods"
    return 1
  fi
}

provision::wait_apiservice() {  # <name>
  k8s_wait::condition "apiservice/$1" Available - "$PROVISION_WAIT_TIMEOUT"
}

# ============================================================== allocation authority

# provision::authority_installed — kuid | first-party | none (both at once is refused).
provision::authority_installed() {
  local kuid=false fp=false
  provision::k get apiservice v1alpha1.vlan.be.kuid.dev -o name >/dev/null 2>&1 && kuid=true
  provision::k get crd identifierclaims.fabric.agentic-netops.io -o name >/dev/null 2>&1 && fp=true
  if [[ "$kuid" == true && "$fp" == true ]]; then
    log::error "two allocation authorities are installed at once — $(gate::authority_display kuid) and $(gate::authority_display first-party); exactly one may exist (FR-104). Remove the one versions.lock.yaml does not select by hand after checking it holds no bound claim."
    return 1
  fi
  if [[ "$kuid" == true ]]; then echo kuid; elif [[ "$fp" == true ]]; then echo first-party; else echo none; fi
}

# provision::bound_claims <authority> — one line per bound claim:
#   <kind> <namespace>/<name> value=<v> rests-on=<service>
provision::bound_claims() {
  local authority="$1" json
  case "$authority" in
    kuid)
      json="$(provision::k get "$KUID_CLAIM_RESOURCES" -A -o json)" || return 1
      jq -r '.items[]
        | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
        | select((.status.id // .status.address // .status.prefix // "") | tostring | length > 0)
        | [ .kind, "\(.metadata.namespace)/\(.metadata.name)",
            "value=\(.status.id // .status.address // .status.prefix)",
            "rests-on=" + ( (.metadata.labels // {}) as $l
              | if $l["agentic-netops.io/network-name"] then "Network \($l["agentic-netops.io/network-namespace"] // "?")/\($l["agentic-netops.io/network-name"])"
                elif $l["agentic-netops.io/correlation-id"] then "intent-tier service correlation-id \($l["agentic-netops.io/correlation-id"])"
                elif $l["agentic-netops.io/fabric-name"] then "Fabric \($l["agentic-netops.io/fabric-namespace"] // "?")/\($l["agentic-netops.io/fabric-name"])"
                else "unlabelled claim \(.metadata.namespace)/\(.metadata.name)" end ) ]
        | join(" ")' <<<"$json" ;;
    first-party)
      json="$(provision::k get identifierclaims.fabric.agentic-netops.io -A -o json)" || return 1
      jq -r '.items[]
        | select((.status.value // "") | tostring | length > 0)
        | [ .kind, "\(.metadata.namespace)/\(.metadata.name)", "value=\(.status.value)",
            "rests-on=" + ( (.metadata.labels // {}) as $l
              | if $l["agentic-netops.io/network-name"] then "Network \($l["agentic-netops.io/network-namespace"] // "?")/\($l["agentic-netops.io/network-name"])"
                elif $l["agentic-netops.io/correlation-id"] then "intent-tier service correlation-id \($l["agentic-netops.io/correlation-id"])"
                elif $l["agentic-netops.io/fabric-name"] then "Fabric \($l["agentic-netops.io/fabric-namespace"] // "?")/\($l["agentic-netops.io/fabric-name"])"
                else "unlabelled claim \(.metadata.namespace)/\(.metadata.name)" end ) ]
        | join(" ")' <<<"$json" ;;
    *) return 0 ;;
  esac
}

# provision::change_of_authority <installed> <selected> — AD-49: stop while any claim is
# bound, touching neither authority; otherwise remove the installed one.
provision::change_of_authority() {
  local installed="$1" selected="$2" bound
  log::warn "allocation authority change: installed is $(gate::authority_display "$installed"), versions.lock.yaml selects $(gate::authority_display "$selected")"
  if ! bound="$(provision::bound_claims "$installed")"; then
    log::error "cannot list the claims $(gate::authority_display "$installed") holds; a change of authority is refused while that is unknown (nothing touched)"
    return 1
  fi
  if [[ -n "$bound" ]]; then
    log::error "change of allocation authority REFUSED: $(gate::authority_display "$installed") holds $(wc -l <<<"$bound") bound claim(s); neither authority was touched (FR-104, AD-49)."
    local line svc
    while IFS= read -r line; do
      svc="${line#*rests-on=}"
      log::error "  ${svc} rests on ${line%% rests-on=*}"
    done <<<"$bound"
    log::error "Each service named above is to be removed first and re-created after the switch: no claim survives a change of authority and none is migrated."
    return 1
  fi
  log::info "no bound claim held by $(gate::authority_display "$installed"); proceeding with the change of authority"
  case "$installed" in
    kuid)
      [[ -f "$PROVISION_ROOT/deploy/kuid/indices/kustomization.yaml" ]] \
        && { provision::k delete -k "$PROVISION_ROOT/deploy/kuid/indices" --ignore-not-found || return 1; }
      provision::k delete -k "$PROVISION_ROOT/deploy/kuid" --ignore-not-found || return 1 ;;
    first-party)
      if provision::k get namespace "$FIRSTPARTY_NS" -o name >/dev/null 2>&1; then
        ownership::require_k8s namespace "$FIRSTPARTY_NS" || return 1
        provision::k delete namespace "$FIRSTPARTY_NS" --ignore-not-found || return 1
      fi
      provision::k delete crd "${FIRSTPARTY_CRDS[@]}" --ignore-not-found || return 1 ;;
  esac
}

provision::install_authority() {  # <selected>
  case "$1" in
    kuid)
      provision::apply_k "$PROVISION_ROOT/deploy/kuid" || return 1
      provision::wait_deployments kuid-system || return 1
      local svc
      for svc in "${KUID_APISERVICES[@]}"; do provision::wait_apiservice "$svc" || return 1; done ;;
    first-party)
      provision::apply_k "$PROVISION_ROOT/deploy/allocation" || return 1
      provision::wait_deployments "$FIRSTPARTY_NS" || return 1 ;;
  esac
}

# provision::assert_one_authority <selected> — the other authority is absent (data-model.md §23).
provision::assert_one_authority() {
  local crd
  case "$1" in
    kuid)
      for crd in "${FIRSTPARTY_CRDS[@]}"; do
        if provision::k get crd "$crd" -o name >/dev/null 2>&1; then
          log::error "two allocation authorities: kuid is selected and installed, yet CRD ${crd} exists (FR-104)"; return 1
        fi
      done ;;
    first-party)
      if provision::k get apiservice -o name 2>/dev/null | grep -q 'be\.kuid\.dev$'; then
        log::error "two allocation authorities: first-party is selected, yet a *.be.kuid.dev APIService exists (FR-104)"; return 1
      fi ;;
  esac
}

# ============================================================== the provider

# provision::compat_json — parts 1–9 of versions.lock.yaml, canonical (sorted keys, compact).
provision::compat_json() {
  yq -o=json '.compatibilitySet' "$PROVISION_ROOT/versions.lock.yaml" | jq -S -c .
}
provision::compat_id() { printf 'sha256:%s' "$(provision::compat_json | tr -d '\n' | sha256sum | awk '{print $1}')"; }

provision::provider_settings() {
  local owner; owner="$(ownership::selector)"
  provision::k create namespace "$PROVIDER_NS" --dry-run=client -o yaml \
    | yq ".metadata.labels.\"${owner%%=*}\" = \"${owner#*=}\"" | provision::apply_stdin || return 1
  # DRIFT_POLICY has no default in the provider; the lab states its only admissible value
  # explicitly (FR-015, AD-17, AD-34). Written BEFORE the provider is applied.
  provision::k create configmap srl-provider-settings -n "$PROVIDER_NS" \
    --from-literal=drift-policy=revertive --dry-run=client -o yaml | provision::apply_stdin || return 1
  # The compatibility set the provider validates against and stamps on every Config it
  # generates (annotation agentic-netops.io/compatibility-set = id); checked by verify-compat.
  local tmp; tmp="$(mktemp -d)"
  provision::compat_json >"$tmp/compatibility-set.json"
  provision::compat_id >"$tmp/id"
  provision::k create configmap srl-provider-compat -n "$PROVIDER_NS" \
    --from-file=compatibility-set.json="$tmp/compatibility-set.json" --from-file=id="$tmp/id" \
    --dry-run=client -o yaml | provision::apply_stdin || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}

provision::install_provider() {
  local ref
  provision::need image_build::build image_build || return 1
  provision::need kind::load_image kind || return 1
  # Builds srl-provider:<contentHash> from the tree (pinned FROMs, verify-pins), loads it into the
  # kind cluster, writes the tag into deploy/agentic-netops/kustomization.yaml's images: stanza and
  # records the image ID in this run's evidence (scripts/lib/image_build.sh).
  ref="$(image_build::build "$PROVIDER_IMAGE_NAME")" || { log::error "building ${PROVIDER_IMAGE_NAME} failed"; return 1; }
  [[ "$ref" == "${PROVIDER_IMAGE_NAME}:"* ]] || { log::error "image_build::build printed '${ref}', expected ${PROVIDER_IMAGE_NAME}:<contentHash>"; return 1; }
  log::info "provider image ${ref}"
  provision::provider_settings || return 1
  provision::apply_k "$PROVISION_ROOT/deploy/agentic-netops" || return 1
  k8s_wait::rollout "$PROVIDER_NS" "deployment/${PROVIDER_DEPLOYMENT}" "$PROVISION_WAIT_TIMEOUT" || return 1
}

# ============================================================== phases

provision::phase_NetworkReady() {
  log::phase NetworkReady
  bash "$PROVISION_LIB/verify_pins.sh" || { log::error "pin check failed (make verify-pins)"; return 1; }
  provision::need preflight::run preflight || return 1
  preflight::run || return 1
  provision::need docker_net::ensure docker_net || return 1
  docker_net::ensure "$MGMT_NETWORK" "$MGMT_CIDR" || return 1
}

provision::phase_ClusterReady() {
  log::phase ClusterReady
  provision::need kind::ensure_cluster kind || return 1
  kind::ensure_cluster "$CLUSTER_NAME" || return 1
  kind::attach_mgmt "$CLUSTER_NAME" "$MGMT_NETWORK" || return 1
}

provision::phase_LabReady() {
  log::phase LabReady
  provision::need containerlab::deploy containerlab || return 1
  containerlab::deploy || return 1
  containerlab::wait_gnmi_accept || return 1
}

provision::phase_AppsReady() {
  log::phase AppsReady
  local selected installed
  selected="$(gate::authority_kind)" || return 1
  gate::warn_substitute "" || return 1
  installed="$(provision::authority_installed)" || return 1
  if [[ "$selected" == first-party && ! -f "$PROVISION_ROOT/deploy/allocation/kustomization.yaml" ]]; then
    log::error "versions.lock.yaml selects $(gate::authority_display first-party), which is not built in this tree" \
      "(deploy/allocation/ is absent — it is built only on a recorded decision, data-model.md §23); nothing was touched"
    return 1
  fi
  if [[ "$installed" != none && "$installed" != "$selected" ]]; then
    provision::change_of_authority "$installed" "$selected" || return 1
  fi

  log::info "cert-manager"
  provision::apply_k "$PROVISION_ROOT/deploy/cert-manager" || return 1
  provision::wait_deployments cert-manager || return 1

  log::info "allocation authority: $(gate::authority_display "$selected")"
  provision::install_authority "$selected" || return 1
  # G11 — as soon as the authority is installed; nothing above it before it passes.
  gate::g11_early || return 1
  provision::assert_one_authority "$selected" || return 1
  if [[ "$selected" == kuid ]]; then
    provision::apply_k "$PROVISION_ROOT/deploy/kuid/indices" || return 1
  fi

  log::info "device-configuration layer (SDC)"
  provision::apply_k "$PROVISION_ROOT/deploy/sdc" || return 1
  provision::wait_deployments sdc-system || return 1
  provision::wait_apiservice v1alpha1.config.sdcio.dev || return 1

  log::info "SR Linux provider"
  provision::install_provider || return 1
  provision::assert_one_authority "$selected" || return 1
}

provision::phase_TargetsReady() {
  log::phase TargetsReady
  provision::need lab_secrets::ensure lab_secrets || return 1
  lab_secrets::ensure || return 1
  # `make sdc-onboard`: deploy/sdc/onboarding/ server-side (rendered for MGMT_CIDR when it is
  # not the default), after its drift-policy and metric-subscription negatives.
  bash "$PROVISION_LIB/sdc_onboard.sh" || { log::error "onboarding the devices (scripts/lib/sdc_onboard.sh) failed"; return 1; }
  # `make wait-targets`: the four targets.config.sdcio.dev Ready, bounded.
  bash "$PROVISION_LIB/wait_targets.sh" --timeout "$PROVISION_TARGETS_TIMEOUT" || return 1
}

provision::phase_GateReady() {
  log::phase GateReady
  local s
  for s in run_gate.sh publish_qualification.sh; do
    [[ -f "$PROVISION_ROOT/tests/gate/$s" ]] || { log::error "tests/gate/${s} is missing: the capability gate cannot run"; return 1; }
  done
  bash "$PROVISION_ROOT/tests/gate/run_gate.sh" || { log::error "the capability gate failed (tests/gate/run_gate.sh); see ${EVIDENCE_DIR}"; return 1; }
  bash "$PROVISION_ROOT/tests/gate/publish_qualification.sh" || { log::error "publishing the qualification record failed"; return 1; }
}

provision::phase_FabricReady() {
  log::phase FabricReady
  local dir="$PROVISION_ROOT/examples/fabric" f names=() n
  log::info "apply --server-side -f examples/fabric/"
  provision::k apply --server-side --field-manager="$PROVISION_FIELD_MANAGER" -f "$dir" || return 1
  for f in "$dir"/*.yaml; do
    while IFS= read -r n; do [[ -n "$n" ]] && names+=("$n"); done \
      < <(yq -r 'select(.kind == "Fabric") | (.metadata.namespace // "agentic-netops-system") + "/" + .metadata.name' "$f")
  done
  [[ "${#names[@]}" -gt 0 ]] || { log::error "examples/fabric/ holds no Fabric"; return 1; }
  for n in "${names[@]}"; do
    k8s_wait::condition "fabrics.fabric.agentic-netops.io/${n#*/}" Ready "${n%%/*}" "$PROVISION_FABRIC_TIMEOUT" || return 1
  done
}

provision::phase_IntentTierReady() {
  log::phase IntentTierReady
  log::error "--with-intent-tier: the IntentTierReady phase is not implemented yet (it arrives with the intent-tier story);" \
    "the lab is provisioned through FabricReady, but the intent tier you asked for was NOT installed"
  return 1
}

# ============================================================== main

provision::usage() { sed -n '/^#   MGMT_CIDR=/p; /^# Flags \/ environment:/,/^# The substitute/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

provision::main() {
  local with_tier=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-name) [[ $# -ge 2 && -n "$2" ]] || { provision::usage >&2; exit 2; }; CLUSTER_NAME="$2"; shift 2 ;;
      --cluster-name=*) CLUSTER_NAME="${1#*=}"; shift ;;
      --with-intent-tier) with_tier=true; shift ;;
      -h|--help) provision::usage; exit 0 ;;
      *) log::error "unknown argument: $1"; provision::usage >&2; exit 2 ;;
    esac
  done
  dotenv::load
  dotenv::noninteractive
  provision::defaults
  evidence::ensure_dir || exit 1
  log::info "cluster ${CLUSTER_NAME}, lab ${LAB_NAME}, management ${MGMT_NETWORK} ${MGMT_CIDR}, evidence ${EVIDENCE_DIR}"
  gate::warn_substitute "" || exit 1
  local phase
  for phase in "${PROVISION_PHASES[@]}"; do
    if ! "provision::phase_${phase}"; then
      log::error "provisioning stopped at ${phase}"
      exit 1
    fi
  done
  if [[ "$with_tier" == true ]]; then
    provision::phase_IntentTierReady || { log::error "provisioning stopped at IntentTierReady"; exit 1; }
  fi
  LOG_PHASE="-" log::info "converged through ${PROVISION_PHASES[-1]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  provision::main "$@"
fi
