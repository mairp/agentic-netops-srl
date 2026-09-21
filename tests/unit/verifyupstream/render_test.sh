#!/usr/bin/env bash
# Offline render of every kustomization T035/T036/T038 add (FR-009, FR-098, FR-086, NFR-003):
# `kubectl kustomize` (or `kustomize build`) of deploy/cert-manager, deploy/sdc, deploy/kuid,
# deploy/kuid/indices and deploy/sdc/onboarding must succeed with no cluster, and the render must
#   pin every container image as <repo>:<tag>@sha256:… equal to a versions.lock.yaml `pinned:`;
#   put every namespaced sdc object in sdc-system and every kuid object in kuid-system (the
#     auth-reader RoleBindings and cert-manager's leader-election Roles excepted: they belong in
#     kube-system), and stamp no namespace on a
#     cluster-scoped object (kustomize does not know ClusterIssuer is cluster-scoped);
#   ship no Secret (the upstream static TLS keys are replaced by cert-manager Certificates);
#   disable config-server's Subscription reconciler (ENABLE_SUBSCRIPTION=false, FR-086);
#   register no vxlan APIService (no vxlan backend at kuid v0.0.13);
#   substitute the credentials Secret NAME into the DiscoveryRule and apply no local-config object.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

if command -v kubectl >/dev/null; then build() { kubectl kustomize "$1"; }
elif command -v kustomize >/dev/null; then build() { kustomize build "$1"; }
else echo "FAIL render_test: neither kubectl nor kustomize is on PATH (an offline render needs one)"; exit 1; fi

for d in cert-manager sdc kuid kuid/indices sdc/onboarding; do
  out="$TMP/${d//\//_}.yaml"
  if build "$ROOT/deploy/$d" >"$out" 2>"$TMP/err"; then pass "offline render deploy/$d ($(grep -c '^kind:' "$out") object(s))"
  else fail "offline render deploy/$d" "$(cat "$TMP/err")"; fi
done

if out="$(python3 - "$TMP" "$ROOT/versions.lock.yaml" <<'PY' 2>&1
import os, sys, yaml
tmp, lock = sys.argv[1], sys.argv[2]
L = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
pinned = set()
def collect(n):
    if isinstance(n, dict):
        for k, v in n.items():
            if k == "pinned" and isinstance(v, str): pinned.add(v)
            collect(v)
    elif isinstance(n, list):
        for x in n: collect(x)
collect(yaml.safe_load(open(lock)))
CLUSTER = {"Namespace", "CustomResourceDefinition", "APIService", "ClusterRole", "ClusterRoleBinding",
           "ClusterIssuer", "MutatingWebhookConfiguration", "ValidatingWebhookConfiguration"}
errs = []
def load(name):
    return [d for d in yaml.load_all(open(os.path.join(tmp, name + ".yaml")), Loader=L) if d]
def containers(d):
    spec = ((d.get("spec") or {}).get("template") or {}).get("spec") or {}
    return (spec.get("initContainers") or []) + (spec.get("containers") or [])
for name, ns in (("cert-manager", "cert-manager"), ("sdc", "sdc-system"), ("kuid", "kuid-system"),
                 ("kuid_indices", "kuid-system"), ("sdc_onboarding", "sdc-system")):
    for d in load(name):
        k, md = d["kind"], d["metadata"]
        where = f"deploy/{name.replace('_', '/')}: {k} {md['name']}"
        if k in CLUSTER:
            if "namespace" in md: errs.append(f"{where}: cluster-scoped object carries namespace {md['namespace']}")
        elif k == "RoleBinding" and md.get("namespace") == "kube-system" and d["roleRef"]["name"] == "extension-apiserver-authentication-reader":
            pass
        elif name == "cert-manager" and md.get("namespace") == "kube-system" and md["name"].endswith(":leaderelection"):
            pass   # upstream cert-manager leader election lives in kube-system
        elif md.get("namespace") != ns:
            errs.append(f"{where}: namespace {md.get('namespace')!r}, want {ns}")
        if k == "Secret": errs.append(f"{where}: a Secret is shipped")
        for c in containers(d):
            img = c.get("image", "")
            if "@sha256:" not in img or img not in pinned:
                errs.append(f"{where}: container {c['name']} image {img!r} is not a digest pin of versions.lock.yaml")
            if c.get("imagePullPolicy") == "Always":
                errs.append(f"{where}: container {c['name']} pulls Always")
        if name == "sdc" and k == "StatefulSet" and md["name"] == "data-server-controller":
            env = {e["name"]: e.get("value") for e in containers(d)[0].get("env", [])}
            if env.get("ENABLE_SUBSCRIPTION") != "false":
                errs.append(f"{where}: ENABLE_SUBSCRIPTION={env.get('ENABLE_SUBSCRIPTION')!r}, want \"false\" (FR-086)")
        if name == "kuid" and k == "APIService" and "vxlan" in md["name"]:
            errs.append(f"{where}: vxlan has no backend at kuid v0.0.13")
        if name == "sdc_onboarding":
            if k == "ConfigMap": errs.append(f"{where}: the build-time reference ConfigMap is applied")
            if k == "DiscoveryRule":
                creds = [p["credentials"] for p in d["spec"]["targetConnectionProfiles"]]
                if creds != ["srl-credentials"]: errs.append(f"{where}: credentials {creds}, want the Secret name srl-credentials")
cm = [c["image"] for d in load("cert-manager") for c in containers(d)]
if len(cm) != 3: errs.append(f"deploy/cert-manager: {len(cm)} containers, want controller, webhook, cainjector")
print("\n".join(errs))
sys.exit(1 if errs else 0)
PY
)"; then pass "renders: images digest-pinned to the lock, namespaces, no Secret, subscription off, no vxlan, credentials name substituted"
else fail "render assertions" "$out"; fi

echo "render_test: $([[ $fails -eq 0 ]] && echo PASS || echo "FAIL ($fails)")"
[[ "$fails" -eq 0 ]]
