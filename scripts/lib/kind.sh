#!/usr/bin/env bash
# kind.sh — the pinned Kind cluster and its management attachment (T034; FR-006, FR-008, FR-010,
# data-model.md §2, evidence/01 §4.5).
#
#   kind::ensure_cluster <name>
#       Creates the cluster from config/kind/cluster.yaml (the declarative config: pinned node
#       image by digest, pod/service CIDRs, loopback-only port mappings). The config's `name:` and
#       its ownership node label are rendered to <name> in a temporary copy, so the label always
#       equals the cluster (agentic-netops.io/owned-by=<name>). Idempotent: an existing cluster
#       that is owned is success with no change — never recreated; one that is not owned is
#       refused. The operator's current kubectl context is restored after creation: scripts use
#       --context kind-<name> and never rely on the current context.
#   kind::attach_mgmt <cluster> <network>
#       Connects every node container of <cluster> to the owned <network> (idempotent: an attached
#       node is left alone). Refuses an unowned network.
#   kind::isolate_dns <cluster>
#       Removes the host's `search`/`domain` lines from every node's /etc/resolv.conf, which the
#       kubelet hands to every ClusterFirst pod. With them, a host search domain that carries a
#       wildcard record (observed: `search ai`, where `github.com.ai` resolves) makes a pod's
#       `github.com` (ndots:5) resolve to the wildcard host, and TLS fails with "unrecognized
#       name" — the device-configuration layer then cannot fetch the pinned YANG repositories
#       and no Schema, hence no Target, is ever Ready. The lab must not depend on the host's
#       search list, so the nodes carry none. Nameservers and options are kept. Idempotent: a
#       node without such lines is left untouched, and CoreDNS is restarted only when a node
#       changed. Docker does not rewrite a resolv.conf it generated once edited.
#   kind::delete_cluster <name>
#       Deletes <name> only when owned. Absent is success.
#   kind::cluster_exists <name> / kind::cluster_owned <name>
#   kind::load_image <cluster> <image>   `kind load docker-image` (used by image_build.sh)
#
# Ownership of a cluster is its control-plane node's Kubernetes label, read through
# `kubectl --context kind-<name>`; a cluster that cannot be read is unowned (fail closed — a
# half-created cluster that never answered is left for the operator, named).
# KIND, KUBECTL, DOCKER override the clients (tests); KIND_CONFIG overrides the config path.

[[ -n "${__AGENTIC_NETOPS_KIND_SH:-}" ]] && return 0
__AGENTIC_NETOPS_KIND_SH=1

# shellcheck source=log.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/log.sh"
# shellcheck source=ownership.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/ownership.sh"

KIND_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

kind::_kind() { "${KIND:-kind}" "$@"; }
kind::_docker() { "${DOCKER:-docker}" "$@"; }
kind::_kubectl() { "${KUBECTL:-kubectl}" "$@"; }
kind::_config() { printf '%s' "${KIND_CONFIG:-$KIND_REPO_ROOT/config/kind/cluster.yaml}"; }

kind::cluster_exists() {
  kind::_kind get clusters 2>/dev/null | grep -qxF -- "$1"
}

kind::_owned_nodes() {
  kind::_kubectl --context "kind-${1}" --request-timeout=10s get nodes \
    -l "$(ownership::key)=${1},node-role.kubernetes.io/control-plane" -o name 2>/dev/null
}

# A `kind create` interrupted after the node started and before the kubeconfig was written
# (T151 r5's cycle 2, stopped by SIGTERM) leaves a cluster kind lists but no context reads. The
# context is re-exported from kind itself — the operator's current context restored — and
# ownership is still decided by the node label alone, never by the container's kind label.
kind::_reexport_context() {
  local name="$1" prev_ctx
  kind::cluster_exists "$name" || return 1
  prev_ctx="$(kind::_kubectl config current-context 2>/dev/null || true)"
  kind::_kind export kubeconfig --name "$name" >/dev/null 2>&1 || return 1
  if [[ -n "$prev_ctx" && "$prev_ctx" != "kind-${name}" ]]; then
    kind::_kubectl config use-context "$prev_ctx" >/dev/null 2>&1 || true
  fi
  log::info "kind: context kind-${name} was missing; re-exported from kind to read ownership"
}

kind::cluster_owned() {
  local name="$1" nodes
  if ! nodes="$(kind::_owned_nodes "$name")"; then
    kind::_reexport_context "$name" || return 1
    nodes="$(kind::_owned_nodes "$name")" || return 1
  fi
  [[ -n "$nodes" ]]
}

kind::_require_owned() {
  local name="$1"
  if ! kind::cluster_owned "$name"; then
    log::error "refusing to touch Kind cluster ${name}: not owned by this platform" \
      "(its control-plane node does not carry $(ownership::key)=${name}, or the cluster cannot be read" \
      "through context kind-${name})"
    return 1
  fi
}

# kind::_render_config <name> <out> — the declarative config with name and ownership label = <name>.
kind::_render_config() {
  local name="$1" out="$2" src
  src="$(kind::_config)"
  [[ -f "$src" ]] || { log::error "kind: config $src not found"; return 1; }
  awk -v n="$name" -v k="$(ownership::key)" '
    /^name:/ { print "name: " n; next }
    { line = $0 }
    index(line, k ":") { sub(k ":.*$", k ": " n, line) }
    { print line }' "$src" >"$out"
  grep -q "^name: ${name}\$" "$out" || { log::error "kind: could not render the cluster name into $src"; return 1; }
}

kind::ensure_cluster() {
  if [[ $# -ne 1 ]]; then log::error "usage: kind::ensure_cluster <name>"; return 2; fi
  local name="$1"
  if kind::cluster_exists "$name"; then
    kind::_require_owned "$name" || return 1
    log::info "kind: cluster $name exists and is owned (not recreated)"
    return 0
  fi
  local tmp prev_ctx rc=0
  tmp="$(mktemp -d)"
  kind::_render_config "$name" "$tmp/cluster.yaml" || { rm -rf "$tmp"; return 1; }
  prev_ctx="$(kind::_kubectl config current-context 2>/dev/null || true)"
  log::info "kind: creating cluster $name from $(kind::_config)"
  kind::_kind create cluster --name "$name" --config "$tmp/cluster.yaml" --wait 180s >&2 || rc=$?
  rm -rf "$tmp"
  if [[ -n "$prev_ctx" && "$prev_ctx" != "kind-${name}" ]]; then
    kind::_kubectl config use-context "$prev_ctx" >/dev/null 2>&1 \
      || log::warn "kind: could not restore the previous kubectl context '$prev_ctx'"
  fi
  if [[ "$rc" -ne 0 ]]; then
    log::error "kind: creating cluster $name failed (exit $rc); inspect with: kind get clusters; docker ps -a --filter label=io.x-k8s.kind.cluster=${name}"
    return 1
  fi
  kind::_require_owned "$name" || return 1
  log::info "kind: cluster $name created (context kind-${name})"
}

kind::attach_mgmt() {
  if [[ $# -ne 2 ]]; then log::error "usage: kind::attach_mgmt <cluster> <network>"; return 2; fi
  local cluster="$1" net="$2" node nodes attached
  ownership::require_docker_network "$net" || return 1
  kind::cluster_exists "$cluster" || { log::error "kind: cluster $cluster does not exist"; return 1; }
  nodes="$(kind::_kind get nodes --name "$cluster" 2>/dev/null)" || nodes=""
  [[ -n "$nodes" ]] || { log::error "kind: cluster $cluster has no node containers"; return 1; }
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    attached="$(kind::_docker container inspect "$node" 2>/dev/null \
      | jq -r --arg n "$net" '.[0].NetworkSettings.Networks // {} | has($n)')" || attached=false
    if [[ "$attached" == true ]]; then
      log::info "kind: node $node already attached to $net"
      continue
    fi
    kind::_docker network connect "$net" "$node" >/dev/null \
      || { log::error "kind: attaching $node to $net failed"; return 1; }
    log::info "kind: attached node $node to $net"
  done <<<"$nodes"
}

kind::isolate_dns() {
  if [[ $# -ne 1 ]]; then log::error "usage: kind::isolate_dns <cluster>"; return 2; fi
  local cluster="$1" node nodes cur new changed=false
  kind::_require_owned "$cluster" || return 1
  nodes="$(kind::_kind get nodes --name "$cluster" 2>/dev/null)" || nodes=""
  [[ -n "$nodes" ]] || { log::error "kind: cluster $cluster has no node containers"; return 1; }
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    cur="$(kind::_docker exec "$node" cat /etc/resolv.conf)" \
      || { log::error "kind: reading /etc/resolv.conf of $node failed"; return 1; }
    new="$(grep -v -E '^[[:space:]]*(search|domain)([[:space:]]|$)' <<<"$cur" || true)"
    if [[ "$new" == "$cur" ]]; then
      log::info "kind: node $node carries no host search domain"
      continue
    fi
    # Written in place (cat >): the file is a bind mount and cannot be replaced by rename.
    printf '%s\n' "$new" | kind::_docker exec -i "$node" sh -c 'cat > /etc/resolv.conf' \
      || { log::error "kind: rewriting /etc/resolv.conf of $node failed"; return 1; }
    log::info "kind: removed the host search domain(s) from $node: $(grep -E '^[[:space:]]*(search|domain)' <<<"$cur" | tr '\n' ' ')"
    changed=true
  done <<<"$nodes"
  if [[ "$changed" == true ]]; then
    kind::_kubectl --context "kind-${cluster}" -n kube-system rollout restart deployment/coredns >/dev/null \
      || { log::error "kind: restarting CoreDNS after the resolv.conf change failed"; return 1; }
    kind::_kubectl --context "kind-${cluster}" -n kube-system rollout status deployment/coredns --timeout=120s >/dev/null \
      || { log::error "kind: CoreDNS did not roll out after the resolv.conf change"; return 1; }
  fi
}

kind::delete_cluster() {
  if [[ $# -ne 1 ]]; then log::error "usage: kind::delete_cluster <name>"; return 2; fi
  local name="$1"
  if ! kind::cluster_exists "$name"; then
    log::info "kind: cluster $name absent (nothing to delete)"
    return 0
  fi
  kind::_require_owned "$name" || return 1
  kind::_kind delete cluster --name "$name" >&2 || { log::error "kind: deleting cluster $name failed"; return 1; }
  log::info "kind: deleted cluster $name"
}

kind::load_image() {
  if [[ $# -ne 2 ]]; then log::error "usage: kind::load_image <cluster> <image>"; return 2; fi
  kind::_kind load docker-image "$2" --name "$1" >&2
}
