#!/usr/bin/env bash
# intent_tier.sh — the intent tier's lifecycle: the rest of IntentTierReady after the boundary step,
# and the steps of `off.sh --purge-intent-tier` (T088, T086's local build step; FR-078, FR-103,
# FR-109, NFR-006, NFR-012, SC-042, AD-24, AD-26, AD-35, AD-36, AD-45, AD-46, AD-64, AD-71, AD-72;
# contracts/kubernetes-objects.md; data-model.md §16, §25).
#
# Up path (scripts/provision.sh provision::phase_IntentTierReady), in this order:
#   intent_tier::preflight   the fabric phase's threshold (preflight::resources, T026) PLUS the sum of
#                            the requests the tier's manifests declare — every Deployment /
#                            StatefulSet / DaemonSet in INTENT_TIER_MANIFEST_DIR, replicas × the
#                            containers' requests (cpu m / cores; memory Ki Mi Gi Ti / K M G T /
#                            bytes), computed with yq, never typed — failing before anything of the
#                            tier is changed and naming the shortfall (NFR-012)
#   (the boundary step — rbac::boundary, T073: boundary applied, denial probes run)
#   intent_tier::install     site-inventory (from the Fabric's spec.inventory, roles from
#                            spec.nodes, fabricASN from spec.overlay: key inventory.json for the agents
#                            and keys FABRIC_NODE_MAP / FABRIC_PORT_MAP / FABRIC_ASN for the translator
#                            sidecar, formats in pkg/migration/site.go) → allocation-authority (keys
#                            ALLOCATION_AUTHORITY, ALLOCATION_NAMESPACE, VLAN_POOL, VNI_POOL from
#                            versions.lock.yaml allocationAuthority.kind and the Fabric's name) →
#                            fabric-qualification copied from agentic-netops-system →
#                            the four agent images, the translator sidecar's and the ui's built
#                            (image_build::build <name> <manifest dir>,
#                            T169: content-hash tag, kind load, kustomization images override,
#                            image ID into evidence) → the rendered manifests applied in groups:
#                            workload NetworkPolicies + the analytics store (clickhouse) and the tier
#                            collector (agent-otel-collector), WAITED READY — the audit record's home
#                            exists before anything can emit an audit event (AD-45) — then the
#                            transport (slim), waited Ready, then the agent workloads (supervisor,
#                            mapper, allocator, deployer), waited Ready, then the chat surface (ui:
#                            ConfigMap ui-env, Deployment and Service ui, T126) — after the supervisor
#                            it proxies to is Ready — waited Ready → the supervisor's and the ui's
#                            NodePorts asserted against the Kind loopback mappings
#                            (config/kind/cluster.yaml: 127.0.0.1 only) and their URLs stated → the
#                            operator-credentials username — never the password — captured through
#                            evidence_run (operator-username-<attempt>) on every provisioning run (SC-042)
#
# Down path steps (orchestrated by scripts/off.sh off::purge_intent_tier):
#   intent_tier::list_networks <evidence id>   the Networks in agentic-netops-intent, through
#                                              evidence_run (a read, itself a record); one name/line
#   intent_tier::refuse <fallback:true|false> <names…>   the refusal text: each service, both
#                                              continuations (and, on the fallback, re-provisioning)
#   intent_tier::quiesce                       supervisor, ui, deployer → 0 replicas; an absent one is
#                                              reported by name and never created (AD-71) — e.g.
#                                              a tier provisioned before T126 added the ui
#   intent_tier::delete_networks <names…>      exactly those, by name
#   intent_tier::wait_networks <names…>        up to TIER_PURGE_WAIT_SECONDS for their finalizers;
#                                              not waiting at all on one already Deleting=True with
#                                              reason TargetUnreachable (or HolderPresent, AD-72);
#                                              a stop names each Network still Deleting and what its
#                                              Deleting condition says is outstanding. Nothing is
#                                              ever force-released: this file writes no annotation
#   intent_tier::remove_workloads / remove_claims / remove_boundary / remove_namespaces
#                                              only once a re-list is empty (off.sh checks it)
#   intent_tier::export_audit_record <cluster> the export hook off.sh calls (scripts/lib/audit_export.sh)
#
# agentic-netops-services and the control plane are never named in a mutating call here.
#
# Settings (environment; defaults): TIER_PURGE_WAIT_SECONDS 300 (data-model.md §25),
# TIER_PURGE_POLL_SECONDS 5, INTENT_TIER_WAIT_TIMEOUT (PROVISION_WAIT_TIMEOUT, else 300),
# INTENT_TIER_MANIFEST_DIR (deploy/agents), INTENT_TIER_KIND_CONFIG (config/kind/cluster.yaml),
# INTENT_TIER_SUPERVISOR_NODEPORT 30990, INTENT_TIER_UI_NODEPORT 30300, CLUSTER_NAME / KUBE_CONTEXT, KUBECTL.
# Command form: intent_tier.sh settings | requests
# Exit: 0 ok; 1 a step failed (named); 2 usage/settings.

[[ -n "${__AGENTIC_NETOPS_INTENT_TIER_SH:-}" ]] && return 0
__AGENTIC_NETOPS_INTENT_TIER_SH=1

INTENT_TIER_LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INTENT_TIER_ROOT="$(cd -- "$INTENT_TIER_LIB/../.." && pwd)"
# shellcheck source=log.sh
source "$INTENT_TIER_LIB/log.sh"
# shellcheck source=evidence.sh
source "$INTENT_TIER_LIB/evidence.sh"
# shellcheck source=k8s_wait.sh
source "$INTENT_TIER_LIB/k8s_wait.sh"
# shellcheck source=ownership.sh
source "$INTENT_TIER_LIB/ownership.sh"
# shellcheck source=gate.sh
source "$INTENT_TIER_LIB/gate.sh"
# shellcheck source=intent_secrets.sh
source "$INTENT_TIER_LIB/intent_secrets.sh"
# shellcheck source=audit_export.sh
source "$INTENT_TIER_LIB/audit_export.sh"

INTENT_TIER_AGENTS_NS="agentic-netops-agents"
INTENT_TIER_INTENT_NS="agentic-netops-intent"
INTENT_TIER_FABRIC_NS="agentic-netops-system"
INTENT_TIER_FIELD_MANAGER="agentic-netops-provision"
INTENT_TIER_PART_OF="agentic-netops-intent-tier"
INTENT_TIER_NETWORKS="networks.fabric.agentic-netops.io"
INTENT_TIER_CORRELATION_LABEL="agentic-netops.io/correlation-id"
INTENT_TIER_VAP="deny-tier-force-release"
INTENT_TIER_CLAIM_ROLE="kuid-claimer"
INTENT_TIER_IMAGES=(supervisor mapper allocator deployer intent-translator ui)  # intent-translator: the deployer's sidecar (T097); ui: the chat surface (T126)
INTENT_TIER_AGENT_WORKLOADS=(supervisor mapper allocator deployer)
INTENT_TIER_QUIESCE=(supervisor ui deployer)                  # the request-accepting workloads (AD-46)
INTENT_TIER_STORE=(statefulset/clickhouse deployment/agent-otel-collector)
INTENT_TIER_ALL_DEPLOYMENTS=(supervisor ui mapper allocator deployer slim agent-otel-collector)
INTENT_TIER_ALL_STATEFULSETS=(clickhouse)

intent_tier::defaults() {
  : "${CLUSTER_NAME:=agentic-netops}"
  : "${TIER_PURGE_WAIT_SECONDS:=300}"
  : "${TIER_PURGE_POLL_SECONDS:=5}"
  : "${INTENT_TIER_WAIT_TIMEOUT:=${PROVISION_WAIT_TIMEOUT:-300}}"
  : "${INTENT_TIER_MANIFEST_DIR:=$INTENT_TIER_ROOT/deploy/agents}"
  : "${INTENT_TIER_KIND_CONFIG:=$INTENT_TIER_ROOT/config/kind/cluster.yaml}"
  : "${INTENT_TIER_SUPERVISOR_NODEPORT:=30990}"
  : "${INTENT_TIER_UI_NODEPORT:=30300}"
  local v
  for v in TIER_PURGE_WAIT_SECONDS TIER_PURGE_POLL_SECONDS INTENT_TIER_WAIT_TIMEOUT INTENT_TIER_SUPERVISOR_NODEPORT INTENT_TIER_UI_NODEPORT; do
    if [[ ! "${!v}" =~ ^[0-9]+$ ]] || [[ "${!v}" -le 0 ]]; then
      log::error "intent tier: ${v} must be a positive integer, got '${!v}'"
      return 2
    fi
  done
}

intent_tier::settings() {
  intent_tier::defaults || return 2
  local v
  for v in TIER_PURGE_WAIT_SECONDS TIER_PURGE_POLL_SECONDS INTENT_TIER_WAIT_TIMEOUT INTENT_TIER_MANIFEST_DIR \
    INTENT_TIER_KIND_CONFIG INTENT_TIER_SUPERVISOR_NODEPORT INTENT_TIER_UI_NODEPORT; do
    printf '%s=%s\n' "$v" "${!v}"
  done
  audit_export::settings
}

intent_tier::_ctx() { printf '%s' "${KUBE_CONTEXT:-kind-${CLUSTER_NAME:-agentic-netops}}"; }
intent_tier::k() { "${KUBECTL:-kubectl}" --context "$(intent_tier::_ctx)" "$@"; }
intent_tier::_exists() { # <kind> <name> [namespace]
  if [[ -n "${3:-}" ]]; then intent_tier::k get "$1" "$2" -n "$3" -o name >/dev/null 2>&1
  else intent_tier::k get "$1" "$2" -o name >/dev/null 2>&1; fi
}
intent_tier::_labels_json() {
  jq -cn --arg k "$(ownership::key)" --arg v "$(ownership::value)" --arg p "$INTENT_TIER_PART_OF" \
    '{($k): $v, "app.kubernetes.io/part-of": $p, "app.kubernetes.io/managed-by": "agentic-netops-lifecycle", "agentic-netops.io/tier": "intent"}'
}
intent_tier::_apply() { # <what> — manifests on stdin, server-side under one field manager
  local what="$1" out
  if ! out="$(intent_tier::k apply --server-side --force-conflicts --field-manager "$INTENT_TIER_FIELD_MANAGER" -f - 2>&1)"; then
    log::error "intent tier: applying ${what} failed:"
    printf '%s\n' "$out" | sed 's/^/    | /' >&2
    return 1
  fi
  log::info "intent tier: applied ${what}"
}

# ================================================================== preflight (NFR-012)
# intent_tier::requests_sum [dir] — "<millicpu> <MiB>" summed over the workload manifests
intent_tier::requests_sum() {
  local dir="${1:-$INTENT_TIER_MANIFEST_DIR}" f
  local -a files=()
  for f in "$dir"/*.yaml "$dir"/*.yml; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == kustomization.y*ml ]] && continue
    files+=("$f")
  done
  if [[ ${#files[@]} -eq 0 ]]; then
    log::error "intent tier: no manifests in ${dir} to sum the tier's requests from"
    return 1
  fi
  local rows
  rows="$(for f in "${files[@]}"; do
    yq -o=json -I=0 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet")
      | {"r": (.spec.replicas // 1), "c": [(.spec.template.spec.containers // [])[] | (.resources.requests // {})
          | {"cpu": ((.cpu // "0") | tostring), "memory": ((.memory // "0") | tostring)}]}' "$f" || exit 1
  done | jq -r '.r as $r | .c[] | "\($r) \(.cpu) \(.memory)"')" || { log::error "intent tier: the manifests in ${dir} do not parse"; return 1; }
  awk '
    function cpu_m(v) {
      if (v ~ /m$/) return substr(v, 1, length(v) - 1) + 0
      return (v + 0) * 1000
    }
    function mem_b(v,   n) {
      if (v ~ /Ki$/) return substr(v, 1, length(v) - 2) * 1024
      if (v ~ /Mi$/) return substr(v, 1, length(v) - 2) * 1048576
      if (v ~ /Gi$/) return substr(v, 1, length(v) - 2) * 1073741824
      if (v ~ /Ti$/) return substr(v, 1, length(v) - 2) * 1099511627776
      if (v ~ /k$/ || v ~ /K$/) return substr(v, 1, length(v) - 1) * 1000
      if (v ~ /M$/) return substr(v, 1, length(v) - 1) * 1000000
      if (v ~ /G$/) return substr(v, 1, length(v) - 1) * 1000000000
      if (v ~ /T$/) return substr(v, 1, length(v) - 1) * 1000000000000
      return v + 0
    }
    NF == 3 { c += $1 * cpu_m($2); m += $1 * mem_b($3) }
    END {
      cm = int(c); if (cm < c) cm++
      mm = m / 1048576; mi = int(mm); if (mi < mm) mi++
      printf "%d %d\n", cm, mi
    }' <<<"$rows"
}

intent_tier::preflight() {
  intent_tier::defaults || return 1
  declare -F preflight::resources >/dev/null || source "$INTENT_TIER_LIB/preflight.sh"
  local sum cpu_m mem vcpu rel
  sum="$(intent_tier::requests_sum "$INTENT_TIER_MANIFEST_DIR")" || { log::error "IntentTierReady preflight: the tier's requests could not be summed — nothing was changed"; return 1; }
  read -r cpu_m mem <<<"$sum"
  vcpu=$(( (cpu_m + 999) / 1000 ))
  rel="${INTENT_TIER_MANIFEST_DIR#"$INTENT_TIER_ROOT"/}"
  log::info "preflight: the intent tier's workloads request ${cpu_m}m CPU (${vcpu} vCPU) and ${mem} MiB, summed from ${rel}/*.yaml"
  if ! PREFLIGHT_EXTRA_VCPU="$vcpu" PREFLIGHT_EXTRA_MEM_MIB="$mem" \
       PREFLIGHT_EXTRA_LABEL="intent tier (${cpu_m}m CPU / ${mem} MiB requested by ${rel})" preflight::resources; then
    log::error "IntentTierReady preflight FAILED: the host cannot hold the fabric plus the intent tier's ${cpu_m}m CPU / ${mem} MiB of requests (shortfall above; NFR-012) — nothing of the tier was changed"
    return 1
  fi
}

# ================================================================== up path
intent_tier::site_inventory() {
  local fab inv
  fab="$(intent_tier::k get fabrics.fabric.agentic-netops.io -n "$INTENT_TIER_FABRIC_NS" -o json 2>/dev/null)" \
    || { log::error "intent tier: reading the Fabric in ${INTENT_TIER_FABRIC_NS} failed"; return 1; }
  [[ "$(jq '.items | length' <<<"$fab")" -gt 0 ]] || { log::error "intent tier: no Fabric in ${INTENT_TIER_FABRIC_NS}: site-inventory has nothing to be written from"; return 1; }
  jq -e '.items[0].spec.overlay.fabricASN | type == "number"' <<<"$fab" >/dev/null \
    || { log::error "intent tier: the Fabric $(jq -r '.items[0].metadata.name' <<<"$fab") has no spec.overlay.fabricASN: every route target is rendered from it"; return 1; }
  inv="$(jq -c '{fabricASN: .items[0].spec.overlay.fabricASN,
      nodes: [.items[] | (.spec.nodes // []) as $n | (.spec.inventory // [])[] | . as $e
      | {name: .node, role: (first($n[] | select(.name == $e.node) | .role) // "unknown"),
         accessPorts: (.accessPorts // []), untaggedAccessPorts: (.untaggedAccessPorts // [])}]}' <<<"$fab")"
  # The translator sidecar's three keys (pkg/migration/site.go): node → role, node → access ports, the ASN.
  jq -n --arg ns "$INTENT_TIER_AGENTS_NS" --argjson l "$(intent_tier::_labels_json)" --argjson inv "$inv" \
    '{apiVersion: "v1", kind: "ConfigMap", metadata: {name: "site-inventory", namespace: $ns, labels: $l},
      data: {"inventory.json": ($inv | tojson),
             "FABRIC_NODE_MAP": ([$inv.nodes[] | {(.name): .role}] | add // {} | tojson),
             "FABRIC_PORT_MAP": ([$inv.nodes[] | {(.name): .accessPorts}] | add // {} | tojson),
             "FABRIC_ASN": ($inv.fabricASN | tostring)}}' \
    | intent_tier::_apply "ConfigMap ${INTENT_TIER_AGENTS_NS}/site-inventory ($(jq '.nodes | length' <<<"$inv") node(s), fabricASN $(jq '.fabricASN' <<<"$inv"), from the Fabric's spec.inventory)"
}

# intent_tier::allocation_authority — ConfigMap allocation-authority: which authority the allocator
# claims from (versions.lock.yaml allocationAuthority.kind, via gate::authority_kind), where its claims
# live, and the Fabric's two pools (<fabric>-vlan, <fabric>-vni). The allocator takes it by envFrom.
intent_tier::allocation_authority() {
  local kind ns fab name
  kind="$(gate::authority_kind)" || { log::error "intent tier: the allocation authority kind could not be read from versions.lock.yaml"; return 1; }
  case "$kind" in
    first-party) ns="agentic-netops-allocation" ;;
    kuid) ns="kuid-system" ;;
  esac
  fab="$(intent_tier::k get fabrics.fabric.agentic-netops.io -n "$INTENT_TIER_FABRIC_NS" -o json 2>/dev/null)" \
    || { log::error "intent tier: reading the Fabric in ${INTENT_TIER_FABRIC_NS} failed"; return 1; }
  name="$(jq -r '.items[0].metadata.name // ""' <<<"$fab")"
  [[ -n "$name" ]] || { log::error "intent tier: no Fabric in ${INTENT_TIER_FABRIC_NS}: allocation-authority has no pools to name"; return 1; }
  jq -n --arg ns "$INTENT_TIER_AGENTS_NS" --argjson l "$(intent_tier::_labels_json)" --arg kind "$kind" --arg cns "$ns" --arg f "$name" \
    '{apiVersion: "v1", kind: "ConfigMap", metadata: {name: "allocation-authority", namespace: $ns, labels: $l},
      data: {ALLOCATION_AUTHORITY: $kind, ALLOCATION_NAMESPACE: $cns, VLAN_POOL: ($f + "-vlan"), VNI_POOL: ($f + "-vni")}}' \
    | intent_tier::_apply "ConfigMap ${INTENT_TIER_AGENTS_NS}/allocation-authority (${kind} in ${ns}; pools ${name}-vlan, ${name}-vni)"
}

intent_tier::copy_qualification() {
  local src
  src="$(intent_tier::k get configmap fabric-qualification -n "$INTENT_TIER_FABRIC_NS" -o json 2>/dev/null)" \
    || { log::error "intent tier: ConfigMap ${INTENT_TIER_FABRIC_NS}/fabric-qualification (published by GateReady) is absent: nothing to copy"; return 1; }
  jq --arg ns "$INTENT_TIER_AGENTS_NS" --argjson l "$(intent_tier::_labels_json)" \
    '{apiVersion: "v1", kind: "ConfigMap", metadata: {name: "fabric-qualification", namespace: $ns,
      labels: ((.metadata.labels // {}) + $l)}} + (if .data then {data: .data} else {} end)
      + (if .binaryData then {binaryData: .binaryData} else {} end)' <<<"$src" \
    | intent_tier::_apply "ConfigMap ${INTENT_TIER_AGENTS_NS}/fabric-qualification (copied from ${INTENT_TIER_FABRIC_NS})"
}

intent_tier::build_images() {
  declare -F image_build::build >/dev/null || source "$INTENT_TIER_LIB/image_build.sh"
  local n tag
  for n in "${INTENT_TIER_IMAGES[@]}"; do
    tag="$(image_build::build "$n" "$INTENT_TIER_MANIFEST_DIR")" || { log::error "intent tier: building the ${n} image failed"; return 1; }
    log::info "intent tier: image ${tag} built and loaded"
  done
}

# intent_tier::render — the tier's manifests, rendered (kustomize when a kustomization exists)
intent_tier::render() {
  if [[ -f "$INTENT_TIER_MANIFEST_DIR/kustomization.yaml" ]]; then
    intent_tier::k kustomize "$INTENT_TIER_MANIFEST_DIR"
  else
    local f first=1
    for f in "$INTENT_TIER_MANIFEST_DIR"/*.yaml; do
      [[ -f "$f" ]] || continue
      [[ $first -eq 1 ]] || echo '---'
      first=0; cat "$f"
    done
  fi
}

# intent_tier::_group <rendered file> <netpol|store|transport|agents|ui> — that group's documents
# (ui: ConfigMap ui-env and the Deployment and Service ui — last, after the supervisor it proxies to)
intent_tier::_group() {
  local file="$1" g="$2" expr
  case "$g" in
    netpol) expr='select(.kind == "NetworkPolicy")' ;;
    store) expr='select(.kind != "NetworkPolicy" and (.metadata.name | test("^(clickhouse|agent-otel-collector)")))' ;;
    transport) expr='select(.kind != "NetworkPolicy" and (.metadata.name | test("^slim")))' ;;
    agents) expr='select(.kind != "NetworkPolicy" and (.metadata.name | test("^(clickhouse|agent-otel-collector|slim|ui$|ui-)") | not))' ;;
    ui) expr='select(.kind != "NetworkPolicy" and (.metadata.name | test("^(ui$|ui-)")))' ;;
    *) return 2 ;;
  esac
  yq "$expr" "$file"
}
intent_tier::_workloads_of() { # <group yaml file> — kind/name of its Deployments and StatefulSets
  yq -r 'select(.kind == "Deployment" or .kind == "StatefulSet") | (.kind | downcase) + "/" + .metadata.name' "$1" | sed '/^---$/d;/^$/d'
}
intent_tier::_apply_and_wait() { # <label> <group file>
  local label="$1" file="$2" w
  grep -q '^kind:' "$file" || { log::info "intent tier: nothing to apply for ${label}"; return 0; }
  intent_tier::_apply "$label" <"$file" || return 1
  while IFS= read -r w; do
    [[ -n "$w" ]] || continue
    KUBE_CONTEXT="$(intent_tier::_ctx)" k8s_wait::rollout "$INTENT_TIER_AGENTS_NS" "$w" "$INTENT_TIER_WAIT_TIMEOUT" \
      || { log::error "intent tier: ${w} (${label}) did not become Ready within ${INTENT_TIER_WAIT_TIMEOUT}s"; return 1; }
    log::info "intent tier: ${w} Ready"
  done < <(intent_tier::_workloads_of "$file")
}

intent_tier::deploy_workloads() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  if ! intent_tier::render >"$tmp/all.yaml"; then log::error "intent tier: rendering ${INTENT_TIER_MANIFEST_DIR} failed"; rm -rf "$tmp"; return 1; fi
  local g
  for g in netpol store transport agents ui; do
    intent_tier::_group "$tmp/all.yaml" "$g" | sed '/^---$/{$d}' >"$tmp/$g.yaml" || { rm -rf "$tmp"; return 1; }
  done
  local w missing=()
  for w in "${INTENT_TIER_STORE[@]}"; do
    intent_tier::_workloads_of "$tmp/store.yaml" | grep -qxF "$w" || missing+=("$w")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log::error "intent tier: the manifests carry no ${missing[*]} — the audit record's store and collector come first (AD-45): no agent workload was created"
    rm -rf "$tmp"; return 1
  fi
  if grep -q '^kind:' "$tmp/netpol.yaml"; then intent_tier::_apply "the workload NetworkPolicies" <"$tmp/netpol.yaml" || { rm -rf "$tmp"; return 1; }; fi
  if ! intent_tier::_apply_and_wait "the analytics store and the tier collector" "$tmp/store.yaml"; then
    log::error "intent tier: the analytics store (clickhouse) or the tier collector (agent-otel-collector) is not Ready —" \
      "no agent workload was created: nothing may emit an audit event with nowhere to keep it (AD-45)"
    rm -rf "$tmp"; return 1
  fi
  intent_tier::_apply_and_wait "the transport (slim)" "$tmp/transport.yaml" || rc=1
  if [[ "$rc" -eq 0 ]]; then intent_tier::_apply_and_wait "the agent workloads" "$tmp/agents.yaml" || rc=1; fi
  if [[ "$rc" -eq 0 ]]; then intent_tier::_apply_and_wait "the chat surface (ui)" "$tmp/ui.yaml" || rc=1; fi
  rm -rf "$tmp"
  return "$rc"
}

# intent_tier::_published <service> <nodePort> — prints the host port: the Service is NodePort on
# exactly that nodePort, and the Kind config maps that nodePort on 127.0.0.1 only
intent_tier::_published() {
  local name="$1" want="$2" svc np map host addr
  svc="$(intent_tier::k get service "$name" -n "$INTENT_TIER_AGENTS_NS" -o json 2>/dev/null)" \
    || { log::error "intent tier: Service ${INTENT_TIER_AGENTS_NS}/${name} is absent"; return 1; }
  np="$(jq -r '[.spec.ports[]?.nodePort | select(. != null)] | map(tostring) | join(",")' <<<"$svc")"
  if [[ "$(jq -r '.spec.type // ""' <<<"$svc")" != NodePort || ",${np}," != *",${want},"* ]]; then
    log::error "intent tier: Service ${name} is type $(jq -r '.spec.type // "?"' <<<"$svc") with nodePort '${np:-none}'," \
      "not NodePort ${want} — the only port the Kind cluster publishes for it, on 127.0.0.1"
    return 1
  fi
  map="$(NP="$want" yq -o=json -I=0 '[.nodes[].extraPortMappings[]? | select(.containerPort == (strenv(NP) | tonumber))][0] // {}' "$INTENT_TIER_KIND_CONFIG" 2>/dev/null)" || map="{}"
  host="$(jq -r '.hostPort // empty' <<<"$map")"; addr="$(jq -r '.listenAddress // empty' <<<"$map")"
  if [[ -z "$host" || "$addr" != 127.0.0.1 ]]; then
    log::error "intent tier: ${INTENT_TIER_KIND_CONFIG#"$INTENT_TIER_ROOT"/} maps NodePort ${want} (Service ${name}) on '${addr:-nothing}', not 127.0.0.1 only"
    return 1
  fi
  printf '%s' "$host"
}

# intent_tier::publish_check — the supervisor and the chat surface on 127.0.0.1 only: each NodePort is
# the one the Kind config maps, and that mapping listens on loopback
intent_tier::publish_check() {
  local host
  host="$(intent_tier::_published supervisor "$INTENT_TIER_SUPERVISOR_NODEPORT")" || return 1
  log::info "intent tier: supervisor published on loopback only — NodePort ${INTENT_TIER_SUPERVISOR_NODEPORT} → http://127.0.0.1:${host}"
  host="$(intent_tier::_published ui "$INTENT_TIER_UI_NODEPORT")" || return 1
  log::info "intent tier: ui (the chat surface) published on loopback only — NodePort ${INTENT_TIER_UI_NODEPORT} → http://127.0.0.1:${host}"
}

intent_tier::capture_username() {
  evidence::ensure_dir || return 1
  export EVIDENCE_DIR
  local id rc=0
  id="operator-username-$(audit_export::attempt_id)"
  evidence_run "$id" -- intent_secrets::username >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log::error "intent tier: capturing the operator-credentials username failed (exit ${rc}) — SC-042's reconciliation needs it on every run"
    return 1
  fi
  log::info "intent tier: operator-credentials username (never the password) captured as ${id}"
}

# intent_tier::install — everything of IntentTierReady after the boundary step
intent_tier::install() {
  intent_tier::defaults || return 1
  intent_tier::site_inventory || return 1
  intent_tier::allocation_authority || return 1
  intent_tier::copy_qualification || return 1
  intent_tier::build_images || return 1
  intent_tier::deploy_workloads || return 1
  intent_tier::publish_check || return 1
  intent_tier::capture_username || return 1
  log::info "intent tier: Ready — store and collector, transport, $(IFS=,; echo "${INTENT_TIER_AGENT_WORKLOADS[*]}"), ui"
}

# ================================================================== down path (off.sh --purge-intent-tier)
intent_tier::export_audit_record() { audit_export::export "${1:-${CLUSTER_NAME:-agentic-netops}}"; }

# intent_tier::list_networks <evidence id> — names, one per line; non-zero when the list fails
intent_tier::list_networks() {
  local id="$1" json
  json="$(evidence_run "$id" -- "${KUBECTL:-kubectl}" --context "$(intent_tier::_ctx)" \
    get "$INTENT_TIER_NETWORKS" -n "$INTENT_TIER_INTENT_NS" -o json 2>/dev/null)" || {
    log::error "tier purge: listing the Networks in ${INTENT_TIER_INTENT_NS} failed (evidence ${id}) — nothing can be decided"
    return 1
  }
  jq -r '.items[]?.metadata.name' <<<"$json"
}

intent_tier::refuse() { # <fallback:true|false> <names…>
  local fallback="$1" n; shift
  if [[ "$fallback" == true ]]; then
    log::error "tier purge refused: a list taken after the scale-down finds the tier's own services in ${INTENT_TIER_INTENT_NS} — nothing was deleted and nothing exported:"
  else
    log::error "tier purge refused: the tier's own services are still in ${INTENT_TIER_INTENT_NS} — nothing was changed:"
  fi
  for n in "$@"; do log::error "  Network ${INTENT_TIER_INTENT_NS}/${n}"; done
  log::error "continue with one of:"
  log::error "  (1) re-run with --remove-services to delete them with the tier: ./scripts/off.sh --purge-intent-tier --remove-services"
  log::error "  (2) remove the services first through the tier (the supervisor) or the cluster tooling" \
    "(kubectl -n ${INTENT_TIER_INTENT_NS} delete ${INTENT_TIER_NETWORKS} <name>), then re-run ./scripts/off.sh --purge-intent-tier"
  if [[ "$fallback" == true ]]; then
    log::error "the workloads $(IFS=,; echo "${INTENT_TIER_QUIESCE[*]}") are left scaled to zero; re-provisioning" \
      "(MGMT_CIDR=<cidr> ./scripts/provision.sh --with-intent-tier --cluster-name ${CLUSTER_NAME}) restores them"
  fi
}

intent_tier::quiesce() {
  local d
  for d in "${INTENT_TIER_QUIESCE[@]}"; do
    if ! intent_tier::_exists deployment "$d" "$INTENT_TIER_AGENTS_NS"; then
      log::info "tier purge: deployment ${d} absent — already at zero; reported, not created (AD-71)"
      continue
    fi
    intent_tier::k -n "$INTENT_TIER_AGENTS_NS" scale deployment "$d" --replicas=0 >/dev/null \
      || { log::error "tier purge: scaling deployment ${INTENT_TIER_AGENTS_NS}/${d} to zero failed"; return 1; }
    log::info "tier purge: deployment ${d} scaled to zero"
  done
}

intent_tier::delete_networks() { # <names…> — exactly these
  [[ $# -gt 0 ]] || return 0
  intent_tier::k -n "$INTENT_TIER_INTENT_NS" delete "$INTENT_TIER_NETWORKS" "$@" --wait=false >/dev/null \
    || { log::error "tier purge: deleting the Networks $* failed"; return 1; }
  log::info "tier purge: delete issued for Network(s) $* in ${INTENT_TIER_INTENT_NS}"
}

# intent_tier::_pending <names…> — JSON array of those still present, with their Deleting condition
intent_tier::_pending() {
  local json
  json="$(intent_tier::k get "$INTENT_TIER_NETWORKS" -n "$INTENT_TIER_INTENT_NS" -o json 2>/dev/null)" || return 1
  jq -c --argjson want "$(printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(. != ""))')" '
    [.items[] | select(.metadata.name as $n | $want | index($n)) |
      {name: .metadata.name,
       deleting: ([.status.conditions[]? | select(.type == "Deleting")][0] // null)}]' <<<"$json"
}

intent_tier::_report_pending() { # <pending json>
  jq -r '.[] | "  Network \(.name) still Deleting: " +
    (if .deleting == null then "no Deleting condition reported yet"
     else "\(.deleting.reason // "?") — \(.deleting.message // "")" end)' <<<"$1" | while IFS= read -r l; do log::error "$l"; done
}

intent_tier::wait_networks() { # <names…>
  [[ $# -gt 0 ]] || return 0
  local deadline pending blocked left
  log::info "tier purge: waiting up to TIER_PURGE_WAIT_SECONDS=${TIER_PURGE_WAIT_SECONDS} s for $# Network(s) to finalize (never force-released)"
  deadline=$(( $(date +%s) + TIER_PURGE_WAIT_SECONDS ))
  while :; do
    pending="$(intent_tier::_pending "$@")" || { log::error "tier purge: reading the Networks back failed"; return 1; }
    [[ "$(jq length <<<"$pending")" -eq 0 ]] && { log::info "tier purge: every deleted Network has finalized"; return 0; }
    blocked="$(jq -c '[.[] | select(.deleting != null and .deleting.status == "True" and (.deleting.reason == "TargetUnreachable" or .deleting.reason == "HolderPresent"))]' <<<"$pending")"
    if [[ "$(jq length <<<"$blocked")" -gt 0 ]]; then
      log::error "tier purge stopped: $(jq -r 'map(.name) | join(", ")' <<<"$blocked") already report Deleting=True with an unreachable target or a holder —" \
        "the wait (TIER_PURGE_WAIT_SECONDS=${TIER_PURGE_WAIT_SECONDS} s) is not spent on them:"
      intent_tier::_report_pending "$pending"
      intent_tier::_stopped_advice
      return 1
    fi
    left=$(( deadline - $(date +%s) ))
    if [[ "$left" -le 0 ]]; then
      log::error "tier purge stopped: still Deleting after TIER_PURGE_WAIT_SECONDS=${TIER_PURGE_WAIT_SECONDS} s:"
      intent_tier::_report_pending "$pending"
      intent_tier::_stopped_advice
      return 1
    fi
    sleep "$(( TIER_PURGE_POLL_SECONDS < left ? TIER_PURGE_POLL_SECONDS : left ))"
  done
}
intent_tier::_stopped_advice() {
  log::error "nothing is force-released (FR-103): the rest of the tier is left in place, scaled down — re-provisioning" \
    "(./scripts/provision.sh --with-intent-tier) restores it; re-run ./scripts/off.sh --purge-intent-tier --remove-services" \
    "once the target returns (or the holder is removed) and it completes"
}

intent_tier::remove_workloads() {
  local -a present=()
  local d
  for d in "${INTENT_TIER_ALL_DEPLOYMENTS[@]}"; do intent_tier::_exists deployment "$d" "$INTENT_TIER_AGENTS_NS" && present+=("$d"); done
  if [[ ${#present[@]} -gt 0 ]]; then
    intent_tier::k -n "$INTENT_TIER_AGENTS_NS" delete deployment "${present[@]}" --ignore-not-found --wait=false >/dev/null \
      || { log::error "tier purge: deleting the tier Deployments failed"; return 1; }
    log::info "tier purge: deleted deployment(s) ${present[*]}"
  fi
  present=()
  for d in "${INTENT_TIER_ALL_STATEFULSETS[@]}"; do intent_tier::_exists statefulset "$d" "$INTENT_TIER_AGENTS_NS" && present+=("$d"); done
  if [[ ${#present[@]} -gt 0 ]]; then
    intent_tier::k -n "$INTENT_TIER_AGENTS_NS" delete statefulset "${present[@]}" --ignore-not-found --wait=false >/dev/null \
      || { log::error "tier purge: deleting the analytics store failed"; return 1; }
    log::info "tier purge: deleted statefulset(s) ${present[*]} (the audit record was exported first)"
  fi
  return 0
}

# intent_tier::remove_claims — the provisional claims of requests never submitted: in the lock's
# authority's namespace, labelled with a correlation id that matches no Network. The claims of
# submitted services are not the purge's (the provider's finalizer releases them, AD-16).
intent_tier::remove_claims() {
  local authority ns nets cids res json names
  authority="$(gate::authority_kind)" || return 1
  ns="$(gate::authority_namespace "$authority")" || return 1
  local -a resources
  case "$authority" in
    first-party) resources=(identifierclaims.fabric.agentic-netops.io) ;;
    kuid) resources=(vlanclaims.vlan.be.kuid.dev genidclaims.genid.be.kuid.dev) ;;
  esac
  nets="$(intent_tier::k get "$INTENT_TIER_NETWORKS" -A -o json 2>/dev/null)" \
    || { log::error "tier purge: listing every Network (to tell provisional claims from submitted ones) failed"; return 1; }
  cids="$(jq -c --arg l "$INTENT_TIER_CORRELATION_LABEL" '[.items[].metadata.labels[$l]? | select(. != null)] | unique' <<<"$nets")"
  for res in "${resources[@]}"; do
    if ! json="$(intent_tier::k get "$res" -n "$ns" -l "$INTENT_TIER_CORRELATION_LABEL" -o json 2>/dev/null)"; then
      log::info "tier purge: ${res} not served in ${ns} — no provisional claim to remove"
      continue
    fi
    names="$(jq -r --arg l "$INTENT_TIER_CORRELATION_LABEL" --argjson c "$cids" \
      '.items[] | select((.metadata.labels[$l] // "") as $v | $v != "" and ($c | index($v) | not)) | .metadata.name' <<<"$json")"
    [[ -n "$names" ]] || continue
    # shellcheck disable=SC2086 # one name per word
    intent_tier::k -n "$ns" delete "$res" $names --ignore-not-found --wait=false >/dev/null \
      || { log::error "tier purge: deleting the provisional ${res} $(tr '\n' ' ' <<<"$names")failed"; return 1; }
    log::info "tier purge: deleted provisional ${res} in ${ns}: $(tr '\n' ' ' <<<"$names")(no Network carries their correlation id)"
  done
}

intent_tier::_delete_if_tier() { # <kind> <name> [namespace] — only the tier's (part-of label)
  local kind="$1" name="$2" ns="${3:-}" json
  local -a nsa=()
  [[ -n "$ns" ]] && nsa=(-n "$ns")
  json="$(intent_tier::k get "$kind" "$name" "${nsa[@]}" -o json 2>/dev/null)" || return 0
  if [[ "$(jq -r '.metadata.labels["app.kubernetes.io/part-of"] // ""' <<<"$json")" != "$INTENT_TIER_PART_OF" ]]; then
    log::error "tier purge: ${kind}/${name}${ns:+ in ${ns}} is not labelled app.kubernetes.io/part-of=${INTENT_TIER_PART_OF}: not the tier's, not removed"
    return 1
  fi
  intent_tier::k "${nsa[@]}" delete "$kind" "$name" --ignore-not-found >/dev/null \
    || { log::error "tier purge: deleting ${kind}/${name} failed"; return 1; }
  log::info "tier purge: deleted ${kind}/${name}${ns:+ in ${ns}}"
}

intent_tier::remove_boundary() {
  local authority ns rc=0
  authority="$(gate::authority_kind)" || return 1
  ns="$(gate::authority_namespace "$authority")" || return 1
  intent_tier::_delete_if_tier rolebinding "$INTENT_TIER_CLAIM_ROLE" "$ns" || rc=1
  intent_tier::_delete_if_tier role "$INTENT_TIER_CLAIM_ROLE" "$ns" || rc=1
  intent_tier::_delete_if_tier validatingadmissionpolicybinding "$INTENT_TIER_VAP" || rc=1
  intent_tier::_delete_if_tier validatingadmissionpolicy "$INTENT_TIER_VAP" || rc=1
  return "$rc"
}

intent_tier::remove_namespaces() {
  local ns
  for ns in "$INTENT_TIER_INTENT_NS" "$INTENT_TIER_AGENTS_NS"; do
    intent_tier::_exists namespace "$ns" || continue
    KUBE_CONTEXT="$(intent_tier::_ctx)" ownership::require_k8s namespace "$ns" || return 1
    intent_tier::k delete namespace "$ns" --ignore-not-found --wait=false >/dev/null \
      || { log::error "tier purge: deleting namespace ${ns} failed"; return 1; }
    KUBE_CONTEXT="$(intent_tier::_ctx)" k8s_wait::until "$TIER_PURGE_WAIT_SECONDS" 2 "namespace ${ns} to be gone" -- \
      bash -c '! "$@"' _ "${KUBECTL:-kubectl}" --context "$(intent_tier::_ctx)" get namespace "$ns" -o name \
      || { log::error "tier purge: namespace ${ns} is still terminating after ${TIER_PURGE_WAIT_SECONDS}s"; return 1; }
    log::info "tier purge: namespace ${ns} removed"
  done
}

intent_tier::main() {
  local cmd="${1:-}"
  case "$cmd" in
    settings) intent_tier::settings ;;
    requests) intent_tier::defaults || return 2; intent_tier::requests_sum "$INTENT_TIER_MANIFEST_DIR" ;;
    -h|--help|help) sed -n '2,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) log::error "usage: intent_tier.sh settings | requests"; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  intent_tier::main "$@"
fi
