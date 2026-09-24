#!/usr/bin/env bash
# grafana_assets.sh — the Grafana assets rendered from the repository (T130, T132; FR-088, FR-094,
# FR-096, SC-017b). Everything Grafana shows comes from the cluster; nothing resolves from a
# third-party repository at run time.
#
#   grafana_assets::plugin                  the flow-panel plugin on stdout: ConfigMap
#                                           grafana-plugin-flow-panel-lock (id, version, sha256 — read
#                                           from versions.lock.yaml observability.grafanaPlugins, never
#                                           retyped) and the chunk ConfigMaps grafana-plugin-flow-panel-<n>
#                                           (binaryData key andrewbmchugh-flow-panel.zip.part-<nn>, at
#                                           most GRAFANA_ASSETS_CHUNK_BYTES each: a ConfigMap holds at
#                                           most 1 MiB) of the vendored release package
#                                           deploy/observability/grafana/vendor/<id>-<version>.zip —
#                                           refused when its sha256 is not the lock's
#   grafana_assets::chunk_count             how many chunk ConfigMaps that package takes (the
#                                           Deployment's plugin-chunks volume lists exactly these)
#   grafana_assets::dashboards <generated>  one ConfigMap grafana-dashboard-<name> per
#                                           deploy/observability/grafana/dashboards/<name>.json, with
#                                             @@series:<logical>@@   → series.json .series[logical].metric
#                                                                      (an unknown logical name fails)
#                                             @@TOPOLOGY_SVG@@       → <generated>/topology.svg
#                                             @@TOPOLOGY_PANEL_YAML@@→ <generated>/topology-panel.yaml
#                                           substituted inside the parsed JSON (the file contents become
#                                           JSON strings, escaped by the encoder); a placeholder left
#                                           over, a missing or empty topology file fails naming it
#                                           — every dashboard EXCEPT the intent tier's (below)
#   grafana_assets::agents_dashboards       ConfigMap grafana-dashboards-agents (T137, FR-095, R-19):
#                                           dashboards/intent-tier.json with the same series
#                                           substitution, labelled app.kubernetes.io/part-of
#                                           agentic-netops-intent-tier. Never part of the fabric set:
#                                           the tier phase applies it and the purge deletes it
#                                           (scripts/lib/intent_tier.sh intent_tier::grafana_patch)
#   grafana_assets::render <generated>      plugin + dashboards, stdout (no cluster)
#   grafana_assets::ensure [generated]      apply the render server-side (the chunks are too large for
#                                           the client-side last-applied annotation), refusing any of
#                                           these ConfigMaps this cluster does not own. Without
#                                           <generated> (or GRAFANA_ASSETS_GENERATED_DIR) the topology
#                                           files are read from the installed ConfigMap
#                                           monitoring/topology-assets (T131, observability::install_assets)
#
# Every rendered ConfigMap carries the platform's ownership label (scripts/lib/ownership.sh).
# env: GRAFANA_ASSETS_LOCK (versions.lock.yaml), GRAFANA_ASSETS_DIR (deploy/observability/grafana),
#      GRAFANA_ASSETS_CHUNK_BYTES (716800), GRAFANA_ASSETS_GENERATED_DIR, KUBECTL, KUBE_CONTEXT

# shellcheck source-path=SCRIPTDIR
[[ -n "${__AGENTIC_NETOPS_GRAFANA_ASSETS_SH:-}" ]] && return 0
__AGENTIC_NETOPS_GRAFANA_ASSETS_SH=1

GRAFANA_ASSETS_LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GRAFANA_ASSETS_ROOT="$(cd -- "$GRAFANA_ASSETS_LIB/../.." && pwd)"
# shellcheck source=log.sh
source "$GRAFANA_ASSETS_LIB/log.sh"
# shellcheck source=k8s_wait.sh
source "$GRAFANA_ASSETS_LIB/k8s_wait.sh"
# shellcheck source=ownership.sh
source "$GRAFANA_ASSETS_LIB/ownership.sh"

GRAFANA_ASSETS_NS="monitoring"
GRAFANA_ASSETS_PLUGIN_ID="andrewbmchugh-flow-panel"
GRAFANA_ASSETS_PLUGIN_CM="grafana-plugin-flow-panel"
GRAFANA_ASSETS_TOPOLOGY_CM="topology-assets"
# the intent tier's dashboards: rendered into ONE ConfigMap by agents_dashboards, never into the fabric set
GRAFANA_ASSETS_AGENTS_CM="grafana-dashboards-agents"
GRAFANA_ASSETS_AGENTS_DASHBOARDS="intent-tier"
# 700 KiB of package per chunk: base64 makes it ~934 KiB, under the 1 MiB ConfigMap bound
GRAFANA_ASSETS_DEFAULT_CHUNK_BYTES=716800

grafana_assets::_lock() { printf '%s' "${GRAFANA_ASSETS_LOCK:-$GRAFANA_ASSETS_ROOT/versions.lock.yaml}"; }
grafana_assets::_dir() { printf '%s' "${GRAFANA_ASSETS_DIR:-$GRAFANA_ASSETS_ROOT/deploy/observability/grafana}"; }
grafana_assets::_chunk_bytes() { printf '%s' "${GRAFANA_ASSETS_CHUNK_BYTES:-$GRAFANA_ASSETS_DEFAULT_CHUNK_BYTES}"; }
grafana_assets::_labels() {
  printf '{app.kubernetes.io/name: grafana, app.kubernetes.io/part-of: agentic-netops, %s: "%s"}' \
    "$(ownership::key)" "$(ownership::value)"
}

# grafana_assets::plugin_lock — `<version> <sha256>` of the flow panel's lock entry
grafana_assets::plugin_lock() {
  local lock version sha
  lock="$(grafana_assets::_lock)"
  [[ -f "$lock" ]] || { log::error "grafana_assets: lock file $lock is missing"; return 1; }
  command -v yq >/dev/null 2>&1 || { log::error "grafana_assets: yq is required to read $lock"; return 1; }
  version="$(GA_ID="$GRAFANA_ASSETS_PLUGIN_ID" yq -r '.observability.grafanaPlugins[] | select(.id == strenv(GA_ID)) | .version' "$lock")" || version=""
  sha="$(GA_ID="$GRAFANA_ASSETS_PLUGIN_ID" yq -r '.observability.grafanaPlugins[] | select(.id == strenv(GA_ID)) | .sha256' "$lock")" || sha=""
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    log::error "grafana_assets: observability.grafanaPlugins[${GRAFANA_ASSETS_PLUGIN_ID}] in $lock has no pinned version and sha256 (version '${version}', sha256 '${sha}')"
    return 1
  fi
  printf '%s %s\n' "$version" "$sha"
}

# grafana_assets::plugin_zip — the vendored package of the locked version, digest-checked
grafana_assets::plugin_zip() {
  local lk version sha zip got
  lk="$(grafana_assets::plugin_lock)" || return 1
  read -r version sha <<<"$lk"
  zip="$(grafana_assets::_dir)/vendor/${GRAFANA_ASSETS_PLUGIN_ID}-${version}.zip"
  [[ -f "$zip" ]] || { log::error "grafana_assets: the vendored plugin package $zip is missing"; return 1; }
  got="$(sha256sum "$zip" | awk '{print $1}')"
  if [[ "$got" != "$sha" ]]; then
    log::error "grafana_assets: $zip is sha256:${got}, versions.lock.yaml pins sha256:${sha} — refusing to serve it"
    return 1
  fi
  printf '%s\n' "$zip"
}

grafana_assets::chunk_count() {
  local zip size chunk
  zip="$(grafana_assets::plugin_zip)" || return 1
  size="$(stat -c %s "$zip")"; chunk="$(grafana_assets::_chunk_bytes)"
  printf '%s\n' $(( (size + chunk - 1) / chunk ))
}

grafana_assets::plugin() {
  local lk version sha zip
  lk="$(grafana_assets::plugin_lock)" || return 1
  read -r version sha <<<"$lk"
  zip="$(grafana_assets::plugin_zip)" || return 1
  cat <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${GRAFANA_ASSETS_PLUGIN_CM}-lock
  namespace: ${GRAFANA_ASSETS_NS}
  labels: $(grafana_assets::_labels)
data:
  id: "${GRAFANA_ASSETS_PLUGIN_ID}"
  version: "${version}"
  sha256: "${sha}"
YAML
  python3 - "$zip" "$(grafana_assets::_chunk_bytes)" "$GRAFANA_ASSETS_PLUGIN_CM" "$GRAFANA_ASSETS_NS" \
    "$GRAFANA_ASSETS_PLUGIN_ID" "$(grafana_assets::_labels)" <<'PY'
import base64, sys
zip_path, chunk, cm, ns, pid, labels = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
data = open(zip_path, "rb").read()
for n, off in enumerate(range(0, len(data), chunk)):
    b64 = base64.b64encode(data[off:off + chunk]).decode()
    print("---")
    print("apiVersion: v1\nkind: ConfigMap\nmetadata:")
    print(f"  name: {cm}-{n}\n  namespace: {ns}\n  labels: {labels}")
    print(f"binaryData:\n  {pid}.zip.part-{n:02d}: {b64}")
PY
}

# grafana_assets::dashboards <generated>
grafana_assets::dashboards() {
  local gen="${1:?usage: grafana_assets::dashboards <generated topology dir>}" dir f
  dir="$(grafana_assets::_dir)"
  for f in topology.svg topology-panel.yaml; do
    [[ -s "$gen/$f" ]] || { log::error "grafana_assets: $gen/$f is missing or empty (the generator step, observability::generate, writes it)"; return 1; }
  done
  grafana_assets::_render_dashboards fabric "$dir" "$gen" "$(grafana_assets::_labels)"
}

# grafana_assets::agents_dashboards — ConfigMap grafana-dashboards-agents (no topology files needed)
grafana_assets::agents_dashboards() {
  local labels
  labels="$(printf '{app.kubernetes.io/name: grafana, app.kubernetes.io/part-of: agentic-netops-intent-tier, %s: "%s"}' \
    "$(ownership::key)" "$(ownership::value)")"
  grafana_assets::_render_dashboards agents "$(grafana_assets::_dir)" "" "$labels"
}

# grafana_assets::_render_dashboards <fabric|agents> <dir> <generated|""> <labels>
#   fabric: one ConfigMap grafana-dashboard-<name> per dashboard not in GRAFANA_ASSETS_AGENTS_DASHBOARDS
#   agents: one ConfigMap GRAFANA_ASSETS_AGENTS_CM holding exactly those dashboards
grafana_assets::_render_dashboards() {
  python3 - "$1" "$2" "$3" "$GRAFANA_ASSETS_NS" "$4" "$GRAFANA_ASSETS_AGENTS_CM" "$GRAFANA_ASSETS_AGENTS_DASHBOARDS" <<'PY'
import glob, json, os, re, sys
mode, d, gen, ns, labels, agents_cm, agents = sys.argv[1:8]
agents = set(agents.split())
series = json.load(open(os.path.join(d, "series.json")))["series"]
subst = {}
if gen:
    subst = {"@@TOPOLOGY_SVG@@": open(os.path.join(gen, "topology.svg"), encoding="utf-8").read(),
             "@@TOPOLOGY_PANEL_YAML@@": open(os.path.join(gen, "topology-panel.yaml"), encoding="utf-8").read()}
SERIES = re.compile(r"@@series:([A-Za-z0-9_]+)@@")
LEFT = re.compile(r"@@[A-Za-z0-9_:]+@@")
errors = []

def series_of(s, where):
    def one(m):
        e = series.get(m.group(1))
        if not e or not e.get("metric"):
            errors.append(f"{where}: unknown series '{m.group(1)}' (deploy/observability/grafana/series.json)")
            return m.group(0)
        return e["metric"]
    return SERIES.sub(one, s)

def topology_of(s, where):
    for k, v in subst.items():
        s = s.replace(k, v)   # the file text stays verbatim; the JSON encoder escapes it
    return s

def walk(o, f, where):
    if isinstance(o, dict):
        return {k: walk(v, f, where) for k, v in o.items()}
    if isinstance(o, list):
        return [walk(v, f, where) for v in o]
    return f(o, where) if isinstance(o, str) else o

out = []
files = [p for p in sorted(glob.glob(os.path.join(d, "dashboards", "*.json")))
         if (os.path.basename(p)[:-len(".json")] in agents) == (mode == "agents")]
if not files:
    errors.append(f"no {mode} dashboards under {d}/dashboards")
for p in files:
    name = os.path.basename(p)[:-len(".json")]
    doc = walk(json.load(open(p, encoding="utf-8")), series_of, name)
    # checked before the topology text goes in: that text is data, never a placeholder
    for m in LEFT.finditer(json.dumps(doc)):
        if m.group(0) not in subst:
            errors.append(f"{name}: placeholder {m.group(0)} left unresolved")
    doc = walk(doc, topology_of, name)
    out.append((name, json.dumps(doc, indent=1, ensure_ascii=False)))
if errors:
    for e in sorted(set(errors)):
        print("grafana_assets: " + e, file=sys.stderr)
    sys.exit(1)
if mode == "agents":
    print("---")
    print("apiVersion: v1\nkind: ConfigMap\nmetadata:")
    print(f"  name: {agents_cm}\n  namespace: {ns}\n  labels: {labels}")
    print("data:")
for name, text in out:
    if mode != "agents":
        print("---")
        print("apiVersion: v1\nkind: ConfigMap\nmetadata:")
        print(f"  name: grafana-dashboard-{name}\n  namespace: {ns}\n  labels: {labels}")
        print("data:")
    print(f"  {name}.json: " + json.dumps(text, ensure_ascii=False))
PY
}

grafana_assets::render() {
  local gen="${1:?usage: grafana_assets::render <generated topology dir>}"
  grafana_assets::plugin || return 1
  grafana_assets::dashboards "$gen" || return 1
}

# grafana_assets::_from_cluster <dir> — the topology files from monitoring/topology-assets
grafana_assets::_from_cluster() {
  local dir="$1" f
  k8s_wait::_kubectl get configmap "$GRAFANA_ASSETS_TOPOLOGY_CM" -n "$GRAFANA_ASSETS_NS" -o name >/dev/null 2>&1 \
    || { log::error "grafana_assets: no generated topology directory given and ${GRAFANA_ASSETS_NS}/${GRAFANA_ASSETS_TOPOLOGY_CM} is not installed (observability::install_assets)"; return 1; }
  ownership::require_k8s configmap "$GRAFANA_ASSETS_TOPOLOGY_CM" "$GRAFANA_ASSETS_NS" || return 1
  for f in topology.svg topology-panel.yaml; do
    k8s_wait::_kubectl get configmap "$GRAFANA_ASSETS_TOPOLOGY_CM" -n "$GRAFANA_ASSETS_NS" -o json \
      | jq -er --arg k "$f" '.data[$k]' >"$dir/$f" \
      || { log::error "grafana_assets: ${GRAFANA_ASSETS_NS}/${GRAFANA_ASSETS_TOPOLOGY_CM} has no key $f"; return 1; }
  done
}

grafana_assets::ensure() {
  local gen="${1:-${GRAFANA_ASSETS_GENERATED_DIR:-}}" tmp="" rendered names n rc=0
  if [[ -z "$gen" ]]; then
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/grafana-assets.XXXXXX")"
    grafana_assets::_from_cluster "$tmp" || { rm -rf "$tmp"; return 1; }
    gen="$tmp"
  fi
  rendered="$(grafana_assets::render "$gen")" || rc=1
  [[ -n "$tmp" ]] && rm -rf "$tmp"
  [[ "$rc" -eq 0 ]] || return 1
  k8s_wait::_kubectl get namespace "$GRAFANA_ASSETS_NS" -o name >/dev/null 2>&1 \
    || { log::error "grafana_assets: namespace ${GRAFANA_ASSETS_NS} is missing"; return 1; }
  names="$(awk '/^  name: /{print $2}' <<<"$rendered")"
  for n in $names; do
    if k8s_wait::_kubectl get configmap "$n" -n "$GRAFANA_ASSETS_NS" -o name >/dev/null 2>&1; then
      ownership::require_k8s configmap "$n" "$GRAFANA_ASSETS_NS" || return 1
    fi
  done
  printf '%s\n' "$rendered" \
    | k8s_wait::_kubectl apply --server-side --field-manager=agentic-netops-provision -f - >/dev/null \
    || { log::error "grafana_assets: applying the Grafana ConfigMaps failed"; return 1; }
  log::info "Grafana assets installed in ${GRAFANA_ASSETS_NS}: $(tr '\n' ' ' <<<"$names")"
}

# executed directly: `grafana_assets.sh render <generated>` / `agents` / `ensure [generated]` / `chunk-count`
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  case "${1:-}" in
    render) grafana_assets::render "${2:?generated topology dir}" ;;
    agents) grafana_assets::agents_dashboards ;;
    ensure) grafana_assets::ensure "${2:-}" ;;
    chunk-count) grafana_assets::chunk_count ;;
    *) echo "usage: $0 render <generated>|agents|ensure [generated]|chunk-count" >&2; exit 2 ;;
  esac
fi
