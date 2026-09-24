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
#   AppsReady      cert-manager → the allocation authority the lock file selects → gate item
#                  G11 (gate::g11_early: on failure provisioning STOPS here, non-zero, naming
#                  G11, with nothing above the authority installed) → the authority's seed
#                  indices/pools → the device-configuration layer (SDC) → the SR Linux provider
#                  (its claim Role for the selected authority, DRIFT_POLICY set to `revertive`
#                  explicitly, the image built from the tree). NOT the observability stack:
#                  that is ObservabilityReady's, after FabricReady (T134, AD-50).
#                    kuid         deploy/kuid (APIServices Available) → G11 → deploy/kuid/indices
#                    first-party  the srl-provider image built and loaded (its tag written into
#                                 deploy/agentic-netops AND deploy/allocation) → deploy/allocation
#                                 (CRDs Established, Deployment allocation-authority rolled out)
#                                 → G11 → deploy/allocation/pools; deploy/kuid/ is never applied
#   TargetsReady   lab secrets (lab_secrets::ensure), the schema mirror of the deviation patch
#                  (scripts/lib/schema_mirror.sh, AD-75), deploy/sdc/onboarding/ (scripts/lib/
#                  sdc_onboard.sh), the four device Targets (targets.config.sdcio.dev — the group
#                  v0.0.58 serves) Ready (scripts/lib/wait_targets.sh), then the device metric
#                  collector (scripts/lib/device_metrics.sh; the Fabric read-back's state source).
#                  The onboarding set, the credentials Secret and so the Targets are in
#                  agentic-netops-system (created by deploy/agentic-netops in AppsReady), not
#                  sdc-system: Targets and everything they use live in agentic-netops-system
#                  because config-server v0.0.58 lists them in the Target's namespace (AD-82
#                  decision 2026-09-21-target-namespace). The layer's workloads stay in sdc-system.
#   GateReady      tests/gate/run_gate.sh wrote the gate record; tests/gate/publish_qualification.sh.
#                  On a lab already carrying the platform fabric (a re-run) the published record is
#                  reused only if it is this gate's pass for this cluster, lab and device image;
#                  otherwise the run stops (re-qualify on stock nodes: off.sh, then provision)
#   FabricReady    examples/fabric/ applied — its pool references rewritten to the selected
#                  authority's group/kind/namespace (gate::authority_pool_ref; names unchanged,
#                  the example files untouched); every Fabric in it reports Ready
#   ObservabilityReady  (T134, scripts/lib/observability_phase.sh; AD-50, AD-55) the observability
#                  stack installed into monitoring (T037's namespace): T131's generator step (gNMIc
#                  target list, topology SVG/panel YAML, topology recording rules — one inventory,
#                  one step), the device collector re-rendered from that target list, Prometheus
#                  WITHOUT alert rules, the generated assets, Grafana and its assets; all waited
#                  Ready. Then the RE-CHECK against the gate's observation (tests/gate/observed/
#                  telemetry-series.json): every recorded series name queried from the installed
#                  Prometheus and the shipped naming-relevant settings compared with the recorded
#                  ones — an absent name or a differing setting stops the phase non-zero naming it,
#                  and the alert rules are never loaded (the bgp-evpn bgp-instance series absent
#                  while no service exists is reported "not yet observable" and the phase goes on).
#                  Only then T130's rules applied, Prometheus reloaded, the ten rules read back
#   IntentTierReady  (--with-intent-tier) its boundary step first (scripts/lib/rbac.sh boundary,
#                  T073): the safety boundary applied — the tier's namespaces, ServiceAccounts,
#                  intent-writer, the claim Role the lock file's authority selects, the four
#                  NetworkPolicies templated from the real management subnet, the admission policy
#                  deny-tier-force-release, the tier's Secrets — then the denial probes
#                  (tests/integration/boundary_probes.sh, T066) BEFORE any agent workload exists;
#                  any denial not observed aborts the phase non-zero. Around it (T088,
#                  scripts/lib/intent_tier.sh): FIRST the extended host preflight — the fabric
#                  threshold plus the requests summed from deploy/agents/*.yaml, failing before
#                  anything of the tier is changed and naming the shortfall (NFR-012); AFTER the
#                  probes: site-inventory (from the Fabric's inventory), fabric-qualification copied
#                  into agentic-netops-agents, the four agent images built (image_build.sh), the
#                  analytics store (clickhouse) and tier collector (agent-otel-collector) applied
#                  and WAITED READY before any agent workload exists (AD-45), slim, then
#                  supervisor/mapper/allocator/deployer waited Ready; the supervisor published on
#                  127.0.0.1 only (NodePort 30990 → 127.0.0.1:19090); the operator-credentials
#                  username (never the password) captured through evidence_run on every run.
#                  Without scripts/lib/intent_tier.sh in the tree the run still FAILS after the
#                  boundary step, naming what is not installed — never silently skipped
#
# Flags / environment:
#   --cluster-name <name>   (env CLUSTER_NAME, default agentic-netops; context kind-<name>)
#   --with-intent-tier      request the intent-tier phase
#   MGMT_CIDR               the management network CIDR (default 172.25.25.0/24)
#   SRL_USER / SRL_PASS     the lab operator's device credentials, handed to the lab-secret step
#                           and the gate (default: containerlab's nokia_srlinux defaults)
#   PROVISION_WAIT_TIMEOUT  seconds, every rollout/availability wait (default 300)
#   PROVISION_TARGETS_TIMEOUT / PROVISION_FABRIC_TIMEOUT  seconds (default 600 / 900)
#   OBS_WAIT_TIMEOUT / OBS_RECHECK_TIMEOUT / OBS_RULES_TIMEOUT  seconds, ObservabilityReady's
#                           bounded waits (default 300 / 180 / 180; scripts/lib/observability_phase.sh)
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
for __lib in preflight docker_net kind containerlab lab_secrets image_build intent_tier; do
  # shellcheck disable=SC1090
  if [[ -f "$PROVISION_LIB/${__lib}.sh" ]]; then source "$PROVISION_LIB/${__lib}.sh"; fi
done
unset __lib

PROVISION_PHASES=(NetworkReady ClusterReady LabReady AppsReady TargetsReady GateReady FabricReady ObservabilityReady)
PROVISION_FIELD_MANAGER="agentic-netops-provision"
MGMT_NETWORK="agentic-netops-mgmt"
PROVIDER_NS="agentic-netops-system"
PROVIDER_DEPLOYMENT="srl-provider"
PROVIDER_IMAGE_NAME="srl-provider"
KUID_APISERVICES=(v1alpha1.vlan.be.kuid.dev v1alpha1.genid.be.kuid.dev v1alpha1.ipam.be.kuid.dev v1alpha1.as.be.kuid.dev)
KUID_CLAIM_RESOURCES="vlanclaims.vlan.be.kuid.dev,genidclaims.genid.be.kuid.dev,ipclaims.ipam.be.kuid.dev,asclaims.as.be.kuid.dev"
FIRSTPARTY_CRDS=(identifierpools.fabric.agentic-netops.io identifierclaims.fabric.agentic-netops.io)
FIRSTPARTY_NS="agentic-netops-allocation"
FIRSTPARTY_DEPLOYMENT="allocation-authority"

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

# provision::build_provider_image — build srl-provider:<contentHash> from the tree (pinned FROMs,
# verify-pins), load it into the kind cluster, write the tag into deploy/agentic-netops's images:
# stanza and record the image ID in this run's evidence (scripts/lib/image_build.sh). Prints the
# reference. The first-party allocation authority runs the same image (SRL_PROVIDER_ROLE).
provision::build_provider_image() {
  local ref
  provision::need image_build::build image_build || return 1
  provision::need kind::load_image kind || return 1
  ref="$(image_build::build "$PROVIDER_IMAGE_NAME")" || { log::error "building ${PROVIDER_IMAGE_NAME} failed"; return 1; }
  [[ "$ref" == "${PROVIDER_IMAGE_NAME}:"* ]] || { log::error "image_build::build printed '${ref}', expected ${PROVIDER_IMAGE_NAME}:<contentHash>"; return 1; }
  printf '%s' "$ref"
}

# provision::wait_crds_established <crd…>
provision::wait_crds_established() {
  local out
  if ! out="$(provision::k wait --for=condition=Established --timeout="${PROVISION_WAIT_TIMEOUT}s" "${@/#/crd/}" 2>&1)"; then
    log::error "timed out after ${PROVISION_WAIT_TIMEOUT}s waiting for CRD(s) $* to be Established"
    printf '%s\n' "$out" | sed 's/^/    | /' >&2
    return 1
  fi
}

provision::install_authority() {  # <selected>
  case "$1" in
    kuid)
      provision::apply_k "$PROVISION_ROOT/deploy/kuid" || return 1
      provision::wait_deployments kuid-system || return 1
      local svc
      for svc in "${KUID_APISERVICES[@]}"; do provision::wait_apiservice "$svc" || return 1; done ;;
    first-party)
      # The authority's controllers run in the provider's binary and image: build and load it
      # first, and give deploy/allocation the very tag deploy/agentic-netops gets.
      local ref
      ref="$(provision::build_provider_image)" || return 1
      provision::need image_build::set_image image_build || return 1
      image_build::set_image "$PROVISION_ROOT/deploy/allocation/kustomization.yaml" "$PROVIDER_IMAGE_NAME" "${ref#*:}" \
        || { log::error "writing ${ref} into deploy/allocation/kustomization.yaml failed"; return 1; }
      log::info "allocation authority image ${ref} (deploy/allocation images: ${PROVIDER_IMAGE_NAME} newTag ${ref#*:})"
      provision::apply_k "$PROVISION_ROOT/deploy/allocation" || return 1
      # the manifest carries the default cluster name; the ownership label is this cluster's
      provision::k label namespace "$FIRSTPARTY_NS" "$(ownership::selector)" --overwrite >/dev/null || return 1
      provision::wait_crds_established "${FIRSTPARTY_CRDS[@]}" || return 1
      k8s_wait::rollout "$FIRSTPARTY_NS" "deployment/${FIRSTPARTY_DEPLOYMENT}" "$PROVISION_WAIT_TIMEOUT" || return 1 ;;
  esac
}

# provision::seed_authority <selected> — the seed indices / pools, applied only after G11 passed.
provision::seed_authority() {
  case "$1" in
    kuid) provision::apply_k "$PROVISION_ROOT/deploy/kuid/indices" ;;
    first-party) provision::apply_k "$PROVISION_ROOT/deploy/allocation/pools" ;;
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

provision::provider_settings() {
  local owner; owner="$(ownership::selector)"
  provision::k create namespace "$PROVIDER_NS" --dry-run=client -o yaml \
    | yq ".metadata.labels.\"${owner%%=*}\" = \"${owner#*=}\"" | provision::apply_stdin || return 1
  # DRIFT_POLICY has no default in the provider; the lab states its only admissible value
  # explicitly (FR-015, AD-17, AD-34). Written BEFORE the provider is applied.
  provision::k create configmap srl-provider-settings -n "$PROVIDER_NS" \
    --from-literal=drift-policy=revertive --dry-run=client -o yaml | provision::apply_stdin || return 1
  # The compatibility set is NOT written here: the provider publishes the set it asserts itself
  # (ConfigMap srl-provider-compatibility-set, from the lock baked into its image), and
  # make verify-compat compares that with versions.lock.yaml (T050).
}

provision::install_provider() {  # <selected authority>
  local selected="$1" ref
  # Builds srl-provider:<contentHash> from the tree (an unchanged tree is not rebuilt: under
  # first-party the authority's build of the same tree already made it), loads it into the kind
  # cluster, writes the tag into deploy/agentic-netops/kustomization.yaml's images: stanza and
  # records the image ID in this run's evidence (scripts/lib/image_build.sh).
  ref="$(provision::build_provider_image)" || return 1
  log::info "provider image ${ref}"
  provision::provider_settings || return 1
  # The provider's claim Role — in the selected authority's namespace, on its claim resources,
  # never both (config/rbac/claims/<kind>; data-model.md §23).
  provision::apply_k "$PROVISION_ROOT/config/rbac/claims/${selected}" || return 1
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
  kind::isolate_dns "$CLUSTER_NAME" || return 1
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
  provision::seed_authority "$selected" || return 1

  log::info "device-configuration layer (SDC)"
  provision::apply_k "$PROVISION_ROOT/deploy/sdc" || return 1
  # The layer's own workloads (api-server, controller, data-server) run in sdc-system; its
  # Targets and their onboarding set are in agentic-netops-system (TargetsReady).
  provision::wait_deployments sdc-system || return 1
  provision::wait_apiservice v1alpha1.config.sdcio.dev || return 1

  log::info "SR Linux provider"
  provision::install_provider "$selected" || return 1
  provision::assert_one_authority "$selected" || return 1
}

provision::phase_TargetsReady() {
  log::phase TargetsReady
  provision::need lab_secrets::ensure lab_secrets || return 1
  lab_secrets::ensure || return 1
  # The Schema loads the deviation patch from the in-cluster mirror by the tag named after the
  # locked commit (AD-75): cloned, asserted equal to the lock, served read-only, read back.
  bash "$PROVISION_LIB/schema_mirror.sh" ensure || { log::error "the schema mirror (scripts/lib/schema_mirror.sh) failed: the Schema cannot load the deviation patch"; return 1; }
  # `make sdc-onboard`: deploy/sdc/onboarding/ server-side (rendered for MGMT_CIDR when it is
  # not the default), after its drift-policy and metric-subscription negatives.
  bash "$PROVISION_LIB/sdc_onboard.sh" || { log::error "onboarding the devices (scripts/lib/sdc_onboard.sh) failed"; return 1; }
  # `make wait-targets`: the four targets.config.sdcio.dev Ready, bounded.
  bash "$PROVISION_LIB/wait_targets.sh" --timeout "$PROVISION_TARGETS_TIMEOUT" || return 1
  # The device metric collector — the Fabric read-back's state datastore, the second and last
  # client of the device management server (FR-086, FR-107; AD-82 decision 2026-09-21-state-source).
  bash "$PROVISION_LIB/device_metrics.sh" ensure || { log::error "the device metric collector (scripts/lib/device_metrics.sh) failed: the Fabric read-back has no state to read"; return 1; }
}

provision::phase_GateReady() {
  log::phase GateReady
  local s
  for s in run_gate.sh publish_qualification.sh; do
    [[ -f "$PROVISION_ROOT/tests/gate/$s" ]] || { log::error "tests/gate/${s} is missing: the capability gate cannot run"; return 1; }
  done
  # The gate qualifies STOCK nodes (G8 builds its own scratch fabric and requires none before it).
  # On a re-run over a lab that already carries the platform fabric, re-running it would fail or
  # disturb the fabric (SC-002), so GateReady instead requires the published record to be one this
  # gate made for this lab: pass, same cluster, lab and device image digest, same gate code
  # (gate_tree_sha256). Anything else stops, naming what differs — never a silent pass (AD-82
  # decision 2026-09-21-gate-rerun).
  if [[ -n "$(provision::platform_configs)" ]]; then
    local q why
    q="$(provision::k get configmap fabric-qualification -n "$PROVIDER_NS" -o jsonpath='{.data.qualification\.json}' 2>/dev/null || true)"
    source "$PROVISION_ROOT/tests/gate/lib/tree_hash.sh"
    if why="$(provision::gate_record_matches "$q" "$CLUSTER_NAME" "$LAB_NAME" "$(evidence::device_image_digest 2>/dev/null || true)" "$(gate::tree_hash "$PROVISION_ROOT")")"; then
      evidence_run gate.reused -- "${KUBECTL:-kubectl}" --context "kind-${CLUSTER_NAME}" get configmap fabric-qualification -n "$PROVIDER_NS" -o json >/dev/null \
        || { log::error "capturing the reused gate record failed"; return 1; }
      log::info "capability gate: the lab carries the platform fabric and the published record is this gate's pass for this lab (${why}) — reused, not re-run on the converged fabric"
      return 0
    fi
    log::error "capability gate: the lab already carries the platform fabric, and the published qualification record cannot be reused: ${why}"
    log::error "  the gate runs on stock nodes only: remove the lab (scripts/off.sh) and provision again to re-qualify it"
    return 1
  fi
  bash "$PROVISION_ROOT/tests/gate/run_gate.sh" || { log::error "the capability gate failed (tests/gate/run_gate.sh); see ${EVIDENCE_DIR}"; return 1; }
  bash "$PROVISION_ROOT/tests/gate/publish_qualification.sh" || { log::error "publishing the qualification record failed"; return 1; }
}

# provision::platform_configs — the provider's device Configs present (not gate-owned), one per line.
provision::platform_configs() {
  provision::k get configs.config.sdcio.dev -n "$PROVIDER_NS" -l '!agentic-netops.io/gate-owned' -o name 2>/dev/null || true
}

# provision::gate_record_matches <qualification.json> <cluster> <lab> <device digest> <gate tree sha256>
# — exit 0 (printing what matched) when the published record is a pass by this gate for this lab;
# else exit 1 printing what differs.
provision::gate_record_matches() {
  local q="$1" cluster="$2" lab="$3" digest="$4" tree="$5"
  if [[ -z "$q" ]] || ! jq -e . >/dev/null 2>&1 <<<"$q"; then
    echo "no published record (ConfigMap ${PROVIDER_NS}/fabric-qualification absent or unreadable)"; return 1
  fi
  jq -r --arg c "$cluster" --arg l "$lab" --arg d "$digest" --arg t "$tree" '
    . as $q
    | [ (if .gate.result != "pass" then "gate result \(.gate.result // "absent"), not pass" else empty end),
      (if .cluster != $c then "cluster \(.cluster // "absent") ≠ \($c)" else empty end),
      (if .lab != $l then "lab \(.lab // "absent") ≠ \($l)" else empty end),
      (if ($d == "" or .gate.device_image_digest != $d) then "device image digest \(.gate.device_image_digest // "absent") ≠ \(if $d == "" then "unknown" else $d end)" else empty end),
      (if .gate.gate_tree_sha256 != $t then "gate code \(.gate.gate_tree_sha256 // "absent") ≠ \($t)" else empty end) ]
    | if length == 0 then "pass of \($q.gate.finished_utc), evidence \($q.gate.evidence_dir)" else join("; ") end' <<<"$q"
  jq -e --arg c "$cluster" --arg l "$lab" --arg d "$digest" --arg t "$tree" \
    '.gate.result == "pass" and .cluster == $c and .lab == $l and $d != "" and .gate.device_image_digest == $d and .gate.gate_tree_sha256 == $t' \
    >/dev/null <<<"$q"
}

# provision::fabric_for_authority <file> <authority> — the manifest on stdout with every Fabric pool
# reference pointing at the selected authority's pool of the same type: group, kind and namespace
# from gate::authority_pool_ref, the name unchanged (deploy/allocation/pools is generated from
# deploy/kuid/indices under the same names). loopbackPoolRef and linkPoolRef are ip pools,
# asnPoolRef an asn pool. The example file itself is never edited.
provision::fabric_for_authority() {
  local file="$1" authority="$2" ip asn
  ip="$(gate::authority_pool_ref "$authority" ip)" || return 1
  asn="$(gate::authority_pool_ref "$authority" asn)" || return 1
  PR_IP="$ip" PR_ASN="$asn" yq '
    (strenv(PR_IP) | split(" ")) as $ip | (strenv(PR_ASN) | split(" ")) as $asn
    | (select(.kind == "Fabric") | .spec.underlay | (.loopbackPoolRef, .linkPoolRef) | select(. != null))
        |= (.group = $ip[0] | .kind = $ip[1] | .namespace = $ip[2])
    | (select(.kind == "Fabric") | .spec.underlay.asnPoolRef | select(. != null))
        |= (.group = $asn[0] | .kind = $asn[1] | .namespace = $asn[2])' "$file"
}

provision::phase_FabricReady() {
  log::phase FabricReady
  local dir="$PROVISION_ROOT/examples/fabric" f names=() n authority
  authority="$(gate::authority_kind)" || return 1
  for f in "$dir"/*.yaml; do
    log::info "apply --server-side -f examples/fabric/${f##*/} (pool references: $(gate::authority_display "$authority"))"
    provision::fabric_for_authority "$f" "$authority" | provision::apply_stdin || return 1
  done
  for f in "$dir"/*.yaml; do
    while IFS= read -r n; do [[ -n "$n" ]] && names+=("$n"); done \
      < <(yq -r 'select(.kind == "Fabric") | (.metadata.namespace // "agentic-netops-system") + "/" + .metadata.name' "$f")
  done
  [[ "${#names[@]}" -gt 0 ]] || { log::error "examples/fabric/ holds no Fabric"; return 1; }
  for n in "${names[@]}"; do
    k8s_wait::condition "fabrics.fabric.agentic-netops.io/${n#*/}" Ready "${n%%/*}" "$PROVISION_FABRIC_TIMEOUT" || return 1
  done
}

# provision::phase_ObservabilityReady — T134: install the stack, re-check the live pipeline against
# the gate's observation, and only then load the alert rules (scripts/lib/observability_phase.sh).
provision::phase_ObservabilityReady() {
  log::phase ObservabilityReady
  [[ -f "$PROVISION_LIB/observability_phase.sh" ]] || { log::error "scripts/lib/observability_phase.sh is missing: the observability stack cannot be installed"; return 1; }
  # shellcheck source=lib/observability_phase.sh
  source "$PROVISION_LIB/observability_phase.sh"
  observability_phase::run
}

# provision::boundary_step — IntentTierReady's first step (T073): apply the safety boundary and
# prove it with the denial probes before any agent workload is created (scripts/lib/rbac.sh).
provision::boundary_step() {
  # shellcheck source=lib/rbac.sh
  source "$PROVISION_LIB/rbac.sh"
  rbac::boundary
}

provision::phase_IntentTierReady() {
  log::phase IntentTierReady
  local have_tier=false
  declare -F intent_tier::install >/dev/null && have_tier=true
  if [[ "$have_tier" == true ]] && ! intent_tier::preflight; then
    log::error "--with-intent-tier: the preflight failed — nothing of the tier was changed; the intent tier was NOT installed"
    return 1
  fi
  if ! provision::boundary_step; then
    log::error "--with-intent-tier: the boundary step failed — no agent workload was created; the intent tier was NOT installed"
    return 1
  fi
  if [[ "$have_tier" != true ]]; then
    log::error "--with-intent-tier: the safety boundary is applied and proven, but the rest of IntentTierReady — the tier's" \
      "workloads (scripts/lib/intent_tier.sh, T088) — is not built yet in this tree;" \
      "the intent tier you asked for was NOT installed"
    return 1
  fi
  if ! intent_tier::install; then
    log::error "--with-intent-tier: the tier's workloads did not come up (above) — the intent tier is NOT Ready"
    return 1
  fi
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
