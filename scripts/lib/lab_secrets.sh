#!/usr/bin/env bash
# lab_secrets.sh — the lab's generated Secrets (T037; FR-019, FR-096, AD-50; quickstart.md
# §Prerequisites, §1 TargetsReady; evidence/01 §4.1, §4.4).
#
#   lab_secrets::ensure
#       1. `srl-credentials` in sdc-system — keys `username`, `password` (the lab device
#          credentials: SRL_USER / SRL_PASS, default containerlab's nokia_srlinux defaults) and `ca`
#          (+ `ca.crt`, same PEM): the containerlab-generated lab CA,
#          <lab dir>/.tls/ca/ca.pem, which verifies the devices' gNMI server certificate
#          (authenticate-client is false: no client certificate exists or is needed). `username` /
#          `password` are the keys the device-configuration layer's target credentials read; `ca`
#          the key its TLS secret reads.
#       2. namespace `monitoring`, created here, idempotently, with the ownership label — this step
#          is the first thing that writes into it; the observability stack arrives much later and
#          installs into the namespace it finds (AD-50). An existing `monitoring` that is not owned
#          is refused, never adopted.
#       3. `srl-credentials` in monitoring — the device metric collector's copy (same keys).
#       4. `grafana-admin` in monitoring — `admin-user` (GRAFANA_ADMIN_USER, default `admin`) and
#          `admin-password`, ALWAYS generated (openssl rand), never a default: created once and
#          preserved on re-runs, so a re-provision does not rotate a password in use (FR-096).
#       Every Secret carries the ownership label; one that exists without it is refused. Values
#       never appear in argv, logs or evidence: they travel through the environment into jq and
#       through a pipe into `kubectl apply --server-side`.
#   lab_secrets::remove
#       Deletes the three Secrets above and the `monitoring` namespace — each only when owned;
#       absent is success. Used by scripts/off.sh (FR-019).
#
# CLUSTER_NAME (context kind-<cluster>), KUBE_CONTEXT (overrides the context), KUBECTL (client),
# LAB_SECRETS_CA_FILE (overrides the CA path; default containerlab::lab_dir/.tls/ca/ca.pem).
# No credential is ever written to a file under deploy/ (FR-019, CR-008).

[[ -n "${__AGENTIC_NETOPS_LAB_SECRETS_SH:-}" ]] && return 0
__AGENTIC_NETOPS_LAB_SECRETS_SH=1

# shellcheck source=log.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/log.sh"
# shellcheck source=ownership.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/ownership.sh"
# shellcheck source=containerlab.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/containerlab.sh"

LAB_SECRETS_FIELD_MANAGER="agentic-netops-lifecycle"
LAB_SECRETS_SDC_NS="sdc-system"
LAB_SECRETS_MON_NS="monitoring"
LAB_SECRETS_CREDS="srl-credentials"
LAB_SECRETS_GRAFANA="grafana-admin"

lab_secrets::_context() { printf '%s' "${KUBE_CONTEXT:-kind-${CLUSTER_NAME:-agentic-netops}}"; }
lab_secrets::_kubectl() { "${KUBECTL:-kubectl}" --context "$(lab_secrets::_context)" "$@"; }
lab_secrets::ca_file() { printf '%s' "${LAB_SECRETS_CA_FILE:-$(containerlab::lab_dir)/.tls/ca/ca.pem}"; }

# The ownership helpers read KUBE_CONTEXT; pin it to this cluster for every check made here.
lab_secrets::_owned() { KUBE_CONTEXT="$(lab_secrets::_context)" ownership::k8s_owned "$@"; }
lab_secrets::_require_owned() { KUBE_CONTEXT="$(lab_secrets::_context)" ownership::require_k8s "$@"; }

lab_secrets::_exists() {
  local kind="$1" name="$2" ns="${3:-}"
  local -a nsa=()
  [[ -n "$ns" ]] && nsa=(-n "$ns")
  lab_secrets::_kubectl get "$kind" "$name" "${nsa[@]}" -o name >/dev/null 2>&1
}

# lab_secrets::_apply — server-side apply of the JSON object on stdin.
lab_secrets::_apply() {
  lab_secrets::_kubectl apply --server-side --force-conflicts \
    --field-manager "$LAB_SECRETS_FIELD_MANAGER" -f - >/dev/null
}

lab_secrets::_ensure_namespace() {
  local ns="$1"
  if lab_secrets::_exists namespace "$ns"; then
    lab_secrets::_require_owned namespace "$ns" || return 1
    log::info "lab_secrets: namespace $ns exists and is owned"
    return 0
  fi
  jq -n --arg ns "$ns" --arg k "$(ownership::key)" --arg v "$(ownership::value)" \
    '{apiVersion: "v1", kind: "Namespace", metadata: {name: $ns, labels: {($k): $v}}}' \
    | lab_secrets::_apply || { log::error "lab_secrets: creating namespace $ns failed"; return 1; }
  log::info "lab_secrets: created namespace $ns ($(ownership::selector))"
}

# lab_secrets::_apply_secret <ns> <name> <component> — data from the env vars LS_KEYS names
# (LS_KEYS="k1=VAR1 k2=VAR2 …"); values are read by jq from the environment, never from argv.
lab_secrets::_apply_secret() {
  local ns="$1" name="$2" component="$3"
  if lab_secrets::_exists secret "$name" "$ns"; then
    lab_secrets::_require_owned secret "$name" "$ns" || return 1
  fi
  local pairs="" kv
  for kv in $LS_KEYS; do pairs+="${kv%%=*}=${kv#*=}"$'\n'; done
  LS_PAIRS="$pairs" jq -n --arg ns "$ns" --arg name "$name" --arg k "$(ownership::key)" \
    --arg v "$(ownership::value)" --arg comp "$component" '
    {apiVersion: "v1", kind: "Secret", type: "Opaque",
     metadata: {name: $name, namespace: $ns,
                labels: {($k): $v, "app.kubernetes.io/managed-by": "agentic-netops-lifecycle",
                         "agentic-netops.io/component": $comp}},
     data: ($ENV.LS_PAIRS | split("\n") | map(select(length > 0) | split("=") as [$key, $var]
             | {($key): ($ENV[$var] | @base64)}) | add)}' \
    | lab_secrets::_apply || { log::error "lab_secrets: applying secret $ns/$name failed"; return 1; }
  log::info "lab_secrets: secret $ns/$name applied (keys: $(for kv in $LS_KEYS; do printf '%s ' "${kv%%=*}"; done))"
}

lab_secrets::ensure() {
  local ca_file
  ca_file="$(lab_secrets::ca_file)"
  if [[ ! -s "$ca_file" ]]; then
    log::error "lab_secrets: the containerlab CA $ca_file is missing (LabReady not met, or the lab directory was removed)"
    return 1
  fi
  if ! grep -q 'BEGIN CERTIFICATE' "$ca_file"; then
    log::error "lab_secrets: $ca_file is not a PEM certificate"
    return 1
  fi
  if ! lab_secrets::_exists namespace "$LAB_SECRETS_SDC_NS"; then
    log::error "lab_secrets: namespace $LAB_SECRETS_SDC_NS does not exist (AppsReady not met: deploy/sdc creates it)"
    return 1
  fi
  local LS_USER LS_PASS LS_CA
  LS_USER="${SRL_USER:-admin}"
  LS_PASS="${SRL_PASS:-NokiaSrl1!}"
  LS_CA="$(cat "$ca_file")"
  export LS_USER LS_PASS LS_CA
  local rc=0
  LS_KEYS="username=LS_USER password=LS_PASS ca=LS_CA ca.crt=LS_CA" \
    lab_secrets::_apply_secret "$LAB_SECRETS_SDC_NS" "$LAB_SECRETS_CREDS" device-credentials || rc=1
  if [[ "$rc" -eq 0 ]]; then
    lab_secrets::_ensure_namespace "$LAB_SECRETS_MON_NS" || rc=1
  fi
  if [[ "$rc" -eq 0 ]]; then
    LS_KEYS="username=LS_USER password=LS_PASS ca=LS_CA ca.crt=LS_CA" \
      lab_secrets::_apply_secret "$LAB_SECRETS_MON_NS" "$LAB_SECRETS_CREDS" collector-credentials || rc=1
  fi
  if [[ "$rc" -eq 0 ]]; then
    if lab_secrets::_exists secret "$LAB_SECRETS_GRAFANA" "$LAB_SECRETS_MON_NS"; then
      lab_secrets::_require_owned secret "$LAB_SECRETS_GRAFANA" "$LAB_SECRETS_MON_NS" || rc=1
      [[ "$rc" -eq 0 ]] && log::info "lab_secrets: secret $LAB_SECRETS_MON_NS/$LAB_SECRETS_GRAFANA exists and is owned (password preserved, not rotated)"
    else
      local LS_GUSER LS_GPASS
      LS_GUSER="${GRAFANA_ADMIN_USER:-admin}"
      LS_GPASS="$(openssl rand -base64 32 | tr -d '/+=\n' | cut -c1-32)"
      if [[ ${#LS_GPASS} -lt 24 ]]; then
        log::error "lab_secrets: password generation failed (openssl rand)"
        rc=1
      else
        export LS_GUSER LS_GPASS
        LS_KEYS="admin-user=LS_GUSER admin-password=LS_GPASS" \
          lab_secrets::_apply_secret "$LAB_SECRETS_MON_NS" "$LAB_SECRETS_GRAFANA" grafana-admin || rc=1
        unset LS_GUSER LS_GPASS
      fi
    fi
  fi
  unset LS_USER LS_PASS LS_CA
  return "$rc"
}

lab_secrets::_delete_owned() {
  local kind="$1" name="$2" ns="${3:-}"
  local -a nsa=()
  [[ -n "$ns" ]] && nsa=(-n "$ns")
  if ! lab_secrets::_exists "$kind" "$name" "$ns"; then
    log::info "lab_secrets: ${kind}/${name}${ns:+ in $ns} absent"
    return 0
  fi
  lab_secrets::_require_owned "$kind" "$name" "$ns" || return 1
  lab_secrets::_kubectl delete "$kind" "$name" "${nsa[@]}" --ignore-not-found --wait=false >/dev/null \
    || { log::error "lab_secrets: deleting ${kind}/${name}${ns:+ in $ns} failed"; return 1; }
  log::info "lab_secrets: deleted ${kind}/${name}${ns:+ in $ns}"
}

lab_secrets::remove() {
  local rc=0
  lab_secrets::_delete_owned secret "$LAB_SECRETS_CREDS" "$LAB_SECRETS_SDC_NS" || rc=1
  lab_secrets::_delete_owned secret "$LAB_SECRETS_CREDS" "$LAB_SECRETS_MON_NS" || rc=1
  lab_secrets::_delete_owned secret "$LAB_SECRETS_GRAFANA" "$LAB_SECRETS_MON_NS" || rc=1
  lab_secrets::_delete_owned namespace "$LAB_SECRETS_MON_NS" || rc=1
  return "$rc"
}
