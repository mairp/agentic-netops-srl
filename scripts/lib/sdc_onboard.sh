#!/usr/bin/env bash
# sdc_onboard.sh — `make sdc-onboard` (T036; FR-015, FR-086, AD-13, AD-34).
#
# Onboards the four SR Linux nodes into the device-configuration layer by applying
# deploy/sdc/onboarding/ (Schema, TargetConnectionProfile, TargetSyncProfile, DiscoveryRule).
# Before anything is applied it asserts two negatives over every manifest it would apply,
# each failing NAMING THE FILE (and line):
#
#   drift-policy   no onboarding manifest states a drift policy. None of Schema,
#                  TargetConnectionProfile, TargetSyncProfile and DiscoveryRule has a revertive
#                  field at config-server v0.0.58, so a manifest that appears to state one — a
#                  key such as `revertive`, `nonRevertive`, `driftPolicy`, `drift-policy`, or a
#                  value naming a (non-)revertive or drift policy — is written against an API
#                  that does not have one. The policy has exactly one home: the provider's
#                  DRIFT_POLICY, landing on the `revertive` field of every Config it generates.
#   metric-subscription  no subscription-based metric ingestion (FR-086): no Subscription
#                  object, and every TargetSyncProfile sync entry is a Get (`get`/`once`) — a
#                  Subscribe mode (onChange/sample) would hold a Subscribe session on the
#                  device's gNMI server, whose sessions are sized for the metric collector.
#   branch-ref     no Schema repository is loaded by a branch reference (NFR-003, AD-75): every
#                  `spec.repositories[].kind` is `tag` (the CRD default when absent) or `hash`. The
#                  deviation patch is loaded from the in-cluster mirror by the tag named after the
#                  locked commit (deploy/sdc/schema-mirror, scripts/lib/schema_mirror.sh).
#
# Then, unless --check-only: the inv.sdcio.dev CRDs must be Established (bounded wait) and the
# credentials Secret agentic-netops-system/srl-credentials must exist (scripts/lib/lab_secrets.sh
# creates it; the onboarding never carries a credential), and the directory is applied with
#   kubectl apply --server-side -k <dir>
# When MGMT_CIDR differs from the default 172.25.25.0/24, the DiscoveryRule is rendered for it
# (scripts/lib/onboarding.sh) into a temporary copy of the directory, which is checked and
# applied instead; the committed files are never rewritten.
#
# Usage: sdc_onboard.sh [--dir <onboarding dir>] [--check-only]
#   env: MGMT_CIDR, KUBECTL (client), KUBE_CONTEXT (--context), SDC_ONBOARD_TIMEOUT (s, 300)
# Exit: 0 applied (or checked); 1 a negative assertion or a precondition failed; 2 usage.

# shellcheck source-path=SCRIPTDIR
[[ -n "${__AGENTIC_NETOPS_SDC_ONBOARD_SH:-}" ]] && return 0
__AGENTIC_NETOPS_SDC_ONBOARD_SH=1

SDC_ONBOARD_LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SDC_ONBOARD_ROOT="$(cd -- "$SDC_ONBOARD_LIB/../.." && pwd)"
# shellcheck source=log.sh
source "$SDC_ONBOARD_LIB/log.sh"
# shellcheck source=k8s_wait.sh
source "$SDC_ONBOARD_LIB/k8s_wait.sh"
# shellcheck source=onboarding.sh
source "$SDC_ONBOARD_LIB/onboarding.sh"

# The onboarding objects and the credentials Secret are in the Targets' namespace, not the layer's
# (sdc-system): Targets and everything they use live in agentic-netops-system because
# config-server v0.0.58 lists them in the Target's namespace (AD-82 decision
# 2026-09-21-target-namespace).
SDC_ONBOARD_NAMESPACE="agentic-netops-system"
SDC_ONBOARD_SECRET="srl-credentials"
SDC_DATA_SERVER_NAMESPACE="sdc-system"
SDC_DATA_SERVER_POD="data-server-controller-0"
SDC_ONBOARD_RELOADED=0
SDC_ONBOARD_CRDS=(schemas.inv.sdcio.dev targetconnectionprofiles.inv.sdcio.dev
  targetsyncprofiles.inv.sdcio.dev discoveryrules.inv.sdcio.dev)

# sdc_onboard::assert_negatives <dir> — both negative assertions; prints FAIL lines, exit 1 on any.
sdc_onboard::assert_negatives() {
  local dir="${1:?usage: sdc_onboard::assert_negatives <dir>}"
  python3 - "$dir" <<'PY'
import os, re, sys
import yaml

d = sys.argv[1]
KEY = re.compile(r"revert|drift", re.I)
VALUE = re.compile(r"\b(non[-_ ]?)?revertive\b|drift[-_ ]?polic", re.I)
fails = []
def rel(p):
    return os.path.relpath(p, os.getcwd()) if not os.path.relpath(p, os.getcwd()).startswith("..") else p

def walk(node, path, f):
    if isinstance(node, yaml.MappingNode):
        for k, v in node.value:
            key = k.value if isinstance(k, yaml.ScalarNode) else ""
            p = f"{path}.{key}" if path else key
            if KEY.search(key):
                fails.append((f, k.start_mark.line + 1, "drift-policy", f"key '{p}'"))
            walk(v, p, f)
    elif isinstance(node, yaml.SequenceNode):
        for i, x in enumerate(node.value):
            walk(x, f"{path}[{i}]", f)
    elif isinstance(node, yaml.ScalarNode) and isinstance(node.value, str) and VALUE.search(node.value):
        fails.append((f, node.start_mark.line + 1, "drift-policy", f"value '{node.value[:60]}' at '{path}'"))

def get(node, *keys):
    for k in keys:
        if not isinstance(node, yaml.MappingNode):
            return None
        node = next((v for kk, v in node.value if isinstance(kk, yaml.ScalarNode) and kk.value == k), None)
    return node

paths = []
for base, _, names in os.walk(d):
    paths += [os.path.join(base, n) for n in names if n.endswith((".yaml", ".yml", ".json"))]
if not paths:
    print(f"FAIL {d}: no manifest to check"); sys.exit(1)
for p in sorted(paths):
    text = open(p, encoding="utf-8", errors="replace").read()
    try:
        docs = list(yaml.compose_all(text))
    except yaml.YAMLError:
        docs = None
    if docs is None:   # not YAML: scan the non-comment lines
        for i, l in enumerate(text.splitlines(), 1):
            s = l.split("#", 1)[0]
            if re.search(r"^\s*[\"']?[\w.-]*(revert|drift)[\w.-]*[\"']?\s*:", s, re.I) or VALUE.search(s):
                fails.append((p, i, "drift-policy", f"line '{l.strip()[:60]}'"))
        continue
    for doc in docs:
        if doc is None:
            continue
        walk(doc, "", p)
        kind = get(doc, "kind")
        kind = kind.value if isinstance(kind, yaml.ScalarNode) else ""
        if kind == "Schema":
            repos = get(doc, "spec", "repositories")
            for i, r in enumerate(repos.value if isinstance(repos, yaml.SequenceNode) else []):
                rk = get(r, "kind")
                if isinstance(rk, yaml.ScalarNode) and rk.value == "branch":
                    url = get(r, "repoURL")
                    fails.append((p, rk.start_mark.line + 1, "branch-ref",
                                  f"spec.repositories[{i}] ({url.value if isinstance(url, yaml.ScalarNode) else '?'}) kind branch"))
        if kind == "Subscription":
            fails.append((p, doc.start_mark.line + 1, "metric-subscription", "a Subscription object"))
        if kind == "TargetSyncProfile":
            sync = get(doc, "spec", "sync")
            for i, e in enumerate(sync.value if isinstance(sync, yaml.SequenceNode) else []):
                mode = get(e, "mode")
                m = mode.value if isinstance(mode, yaml.ScalarNode) else "get"   # CRD default: get
                if m not in ("get", "once"):
                    fails.append((p, (mode or e).start_mark.line + 1, "metric-subscription",
                                  f"spec.sync[{i}].mode '{m}' is a Subscribe mode"))

for p, line, check, what in fails:
    if check == "drift-policy":
        print(f"FAIL [drift-policy] {rel(p)}:{line}: onboarding manifest states a drift policy ({what}) — "
              "Schema, TargetConnectionProfile, TargetSyncProfile and DiscoveryRule have no such field at "
              "config-server v0.0.58; the policy has one home, the provider's DRIFT_POLICY on the `revertive` "
              "field of every generated Config (FR-015, AD-13, AD-34)")
    elif check == "branch-ref":
        print(f"FAIL [branch-ref] {rel(p)}:{line}: Schema repository loaded by a branch reference ({what}) — "
              "a branch moves; load the pinned commit by tag (the deviation patch from the in-cluster mirror, "
              "deploy/sdc/schema-mirror) (NFR-003, AD-75)")
    else:
        print(f"FAIL [metric-subscription] {rel(p)}:{line}: subscription-based metric ingestion ({what}) — "
              "the device-configuration layer must not subscribe for metrics; the device metric collector "
              "is the only subscriber (FR-086)")
if fails:
    sys.exit(1)
print(f"sdc-onboard: negatives hold — no drift-policy statement, no metric subscription, no branch reference in {len(paths)} manifest(s) under {rel(d)}")
PY
}

# sdc_onboard::recycle_failed_schema <dir> — delete (and wait out) every Schema of <dir> that exists
# and reports Ready=False, so the apply that follows is loaded afresh. config-server v0.0.58 loads a
# Schema only when its directory is absent from the schema store (pkg/reconcilers/schema
# reconciler.go: `if !dirExists`), and a failed download leaves that directory PARTIAL: the Schema
# then stays Ready=False for good, even after its spec is corrected, until it is deleted (its
# finalizer removes the directory). Observed live, pass 37. A Ready Schema is recycled the same way
# only when the repository refs it was loaded from differ from the manifest's: config-server never
# reloads a changed spec either (phase 4 pass 3, 2026-09-21-schema-reload). A Ready Schema whose refs
# match is never touched.
sdc_onboard::recycle_failed_schema() {
  local dir="$1" timeout="${2:-300}" name ns st want_refs live_refs
  while read -r ns name want_refs; do
    [[ -n "$name" ]] || continue
    st="$(k8s_wait::_kubectl get schemas.inv.sdcio.dev "$name" -n "$ns" \
          -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" || continue
    if [[ "$st" == "False" ]]; then
      log::warn "Schema ${ns}/${name} reports Ready=False: deleting it so the apply reloads it (config-server never retries a failed load)"
    else
      live_refs="$(k8s_wait::_kubectl get schemas.inv.sdcio.dev "$name" -n "$ns" \
                   -o 'jsonpath={.spec.repositories[*].ref}' 2>/dev/null)" || continue
      [[ "$live_refs" != "$want_refs" ]] || continue
      log::warn "Schema ${ns}/${name} is loaded from refs [${live_refs}] but the manifest states [${want_refs}]: deleting it so the apply reloads it (config-server never reloads a changed spec)"
    fi
    k8s_wait::_kubectl delete schemas.inv.sdcio.dev "$name" -n "$ns" --wait=true --timeout="${timeout}s" || {
      log::error "sdc_onboard: Schema ${ns}/${name} could not be deleted for a reload"; return 1; }
    SDC_ONBOARD_RELOADED=1
  done < <(python3 - "$dir" "$SDC_ONBOARD_NAMESPACE" <<'PY'
import os, sys, yaml
for base, _, names in os.walk(sys.argv[1]):
    for n in sorted(names):
        if not n.endswith((".yaml", ".yml")):
            continue
        for doc in yaml.safe_load_all(open(os.path.join(base, n))):
            if isinstance(doc, dict) and doc.get("kind") == "Schema":
                md = doc.get("metadata") or {}
                refs = " ".join(str(r.get("ref", "")) for r in (doc.get("spec") or {}).get("repositories") or [])
                print(md.get("namespace", sys.argv[2]), md.get("name", ""), refs)
PY
)
}

# sdc_onboard::restart_data_server <timeout> — after a Schema was reloaded, restart the data server.
# data-server v0.0.72 keeps a per-datastore schema cache: a Schema deleted and re-created with a new
# repository (CreateSchema logged, the new files in the store) is still validated against the old one
# by every existing datastore until the process restarts. Observed live, phase 4 pass 3
# (docs/decisions/live-findings.md, 2026-09-21-schema-reload).
sdc_onboard::restart_data_server() {
  local timeout="$1"
  log::warn "restarting ${SDC_DATA_SERVER_POD} in ${SDC_DATA_SERVER_NAMESPACE} so every datastore validates against the reloaded Schema"
  k8s_wait::_kubectl delete pod "$SDC_DATA_SERVER_POD" -n "$SDC_DATA_SERVER_NAMESPACE" --wait=true --timeout="${timeout}s" || {
    log::error "sdc_onboard: ${SDC_DATA_SERVER_POD} could not be restarted"; return 1; }
  k8s_wait::_kubectl wait "pod/${SDC_DATA_SERVER_POD}" -n "$SDC_DATA_SERVER_NAMESPACE" --for=condition=Ready --timeout="${timeout}s" || {
    log::error "sdc_onboard: ${SDC_DATA_SERVER_POD} not Ready within ${timeout}s after the restart"; return 1; }
}

# sdc_onboard::prepare_dir <dir> <mgmt_cidr> <tmp> — prints the directory to apply.
sdc_onboard::prepare_dir() {
  local dir="$1" cidr="$2" tmp="$3"
  if [[ -z "$cidr" || "$cidr" == "$ONBOARDING_DEFAULT_CIDR" ]]; then
    printf '%s\n' "$dir"; return 0
  fi
  cp -R "$dir" "$tmp/onboarding"
  onboarding::render "$cidr" >"$tmp/onboarding/discovery-rule.yaml" || return 1
  log::info "DiscoveryRule rendered for MGMT_CIDR ${cidr} into ${tmp}/onboarding"
  printf '%s\n' "$tmp/onboarding"
}

sdc_onboard::main() {
  local dir="$SDC_ONBOARD_ROOT/deploy/sdc/onboarding" check_only=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) dir="${2:?--dir needs a directory}"; shift 2 ;;
      --check-only) check_only=true; shift ;;
      -h|--help) sed -n '2,/^\[\[ -n/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; return 0 ;;
      *) log::error "sdc_onboard: unknown argument '$1'"; return 2 ;;
    esac
  done
  [[ -d "$dir" ]] || { log::error "sdc_onboard: onboarding directory $dir not found"; return 2; }
  log::phase SdcOnboard
  local tmp apply_dir timeout="${SDC_ONBOARD_TIMEOUT:-300}" crd
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdc_onboard.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  sdc_onboard::assert_negatives "$dir" || { log::error "sdc_onboard: refused — nothing applied"; return 1; }
  apply_dir="$(sdc_onboard::prepare_dir "$dir" "${MGMT_CIDR:-}" "$tmp")" || return 1
  if [[ "$apply_dir" != "$dir" ]]; then
    sdc_onboard::assert_negatives "$apply_dir" || { log::error "sdc_onboard: refused — nothing applied"; return 1; }
  fi
  [[ "$check_only" == true ]] && return 0

  for crd in "${SDC_ONBOARD_CRDS[@]}"; do
    k8s_wait::condition "crd/$crd" Established - "$timeout" || return 1
  done
  if ! k8s_wait::_kubectl get secret "$SDC_ONBOARD_SECRET" -n "$SDC_ONBOARD_NAMESPACE" -o name >/dev/null 2>&1; then
    log::error "sdc_onboard: Secret ${SDC_ONBOARD_NAMESPACE}/${SDC_ONBOARD_SECRET} is missing — the DiscoveryRule's targets would have no credentials"
    log::error "  next: create it with scripts/lib/lab_secrets.sh (lab_secrets::ensure), then re-run make sdc-onboard"
    return 1
  fi
  sdc_onboard::recycle_failed_schema "$apply_dir" "$timeout" || return 1
  log::info "applying ${apply_dir}"
  k8s_wait::_kubectl apply --server-side -k "$apply_dir" || return 1
  if [[ "$SDC_ONBOARD_RELOADED" == 1 ]]; then
    sdc_onboard::restart_data_server "$timeout" || return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  sdc_onboard::main "$@"
fi
