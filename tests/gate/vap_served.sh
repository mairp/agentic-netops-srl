#!/usr/bin/env bash
# tests/gate/vap_served.sh — T166: ValidatingAdmissionPolicy is served at the pinned Kubernetes
# minor (research Open item 12, CD-02). P1's force-release denial depends on it; if it is NOT served
# the fallback is a validating webhook in the provider — never a relaxed requirement — and that is
# what this records (the qualification itself passes when the observation was made; the answer is
# data, published in the qualification record).
#
# Observed, each through evidence_run: the server version; the admissionregistration.k8s.io/v1
# discovery document listing validatingadmissionpolicies and validatingadmissionpolicybindings; a
# server-side dry-run create of a gate-labelled vt-scratch- policy (nothing persisted). Its negative
# control: the same discovery check for a resource the group does not serve must fail.
# Writes $EVIDENCE_DIR/gate/qualifications/vap_served.json. No namespace is created.
set -euo pipefail
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"
evidence::ensure_dir
mkdir -p "$EVIDENCE_DIR/gate/qualifications" "$EVIDENCE_DIR/gate/manifests"
GATE_ITEM=VAP
OUT="$EVIDENCE_DIR/gate/qualifications/vap_served.json"
CTX=(--context "${KUBE_CONTEXT:-kind-${CLUSTER_NAME}}")
K="${KUBECTL:-kubectl}"

# the served check, as one command (so it can be its own negative control)
served_cmd() { # <resource>
  printf '%s get --raw /apis/admissionregistration.k8s.io/v1 | jq -e --arg r %q %s' \
    "$K ${CTX[*]}" "$1" "'any(.resources[]; .name == \$r)'"
}

version="$(gate::run VAP.server-version -- lab::kubectl version -o json 2>/dev/null | jq -c '.serverVersion // {}' 2>/dev/null || echo '{}')"
evidence_negative_control VAP-served -- sh -c "$(served_cmd validatingadmissionpolicies-vt-scratch-absent)" >/dev/null 2>&1 || true
served=false; bindings=false
gate::run VAP.discovery --check VAP-served --readiness -- sh -c "$(served_cmd validatingadmissionpolicies)" >/dev/null 2>&1 && served=true
gate::run VAP.discovery-bindings --check VAP-served --readiness -- sh -c "$(served_cmd validatingadmissionpolicybindings)" >/dev/null 2>&1 && bindings=true
mf="$(gate::manifest vap-probe.yaml)"
cat >"$mf" <<YAML
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: vt-scratch-vap-probe
  labels: {${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}"}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups: [""]
      apiVersions: [v1]
      operations: [UPDATE]
      resources: [configmaps]
  validations:
  - expression: "true"
YAML
dry=false
gate::run VAP.dry-run-create --attach gate/manifests/vap-probe.yaml -- lab::kubectl create --dry-run=server -f "$mf" -o name >/dev/null 2>&1 && dry=true
observed=true
[[ "$version" != "{}" ]] || observed=false
jq -n --argjson v "$version" --argjson s "$served" --argjson b "$bindings" --argjson d "$dry" --argjson o "$observed" '
  {name: "vap_served", status: (if $o then "pass" else "fail" end),
   kubernetes_server: {gitVersion: $v.gitVersion, major: $v.major, minor: $v.minor},
   served: ($s and $b), policies_served_v1: $s, bindings_served_v1: $b, dry_run_create_accepted: $d,
   force_release_denial_mechanism: (if ($s and $b) then "ValidatingAdmissionPolicy"
                                    else "provider validating webhook (the fallback; never a relaxed requirement)" end)}' >"$OUT"
log::info "[VAP] served=$served bindings=$bindings dry-run=$dry (server $(jq -r .gitVersion <<<"$version" 2>/dev/null))"
[[ "$observed" == true ]]
