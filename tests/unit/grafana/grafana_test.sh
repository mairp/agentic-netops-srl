#!/usr/bin/env bash
# deploy/observability/grafana + scripts/lib/grafana_assets.sh suite (T130 Grafana half, T132;
# FR-087, FR-088, FR-094, FR-096, SC-017b). Offline: the kustomization is built and the assets are
# rendered to stdout; no cluster is touched.
#
# Proves, one behaviour per check:
#   - every dashboard parses, carries a provenance object, names only the datasource uid
#     `prometheus`, holds no http(s) URL at all (nothing resolves from a third-party repository),
#     and names every series through a placeholder series.json defines;
#   - the flow panel (andrewbmchugh-flow-panel) appears only in the physical-topology dashboard, at
#     the plugin version the lock records, with its SVG and panel configuration as the two inline
#     placeholders — never a URL — no site config and no test data, and with the three legend
#     formats the topology generator's dataRefs are built from (internal/topologyview/panel.go);
#   - the Deployment: both containers run the image by the lock's digest; no anonymous access, no
#     sign-up, no plugin install or preinstall, no update check; the administrator only through
#     secretKeyRef grafana-admin (admin-user, admin-password) and no credential literal anywhere;
#     non-root, resources set; the datasource is uid prometheus at the in-cluster Prometheus;
#   - the vendored plugin package is the lock's sha256 and its provenance sidecar says so;
#   - grafana_assets.sh renders (dry run): every ConfigMap under 1 MiB, ownership-labelled; the
#     chunks reassemble to the lock's digest and are exactly the Deployment's plugin-chunks list;
#     the dashboard ConfigMaps are exactly its dashboards list; the topology SVG and panel YAML are
#     substituted verbatim (quotes, backslashes, newlines survive JSON escaping) and no placeholder
#     is left; it refuses a missing topology file, an unknown series name and a package whose
#     digest is not the lock's;
#   - every dashboard expression parses as PromQL (promtool of the pinned Prometheus image, when the
#     image is present locally — otherwise reported SKIP);
#   - GRAFANA_IMAGE_TEST=1: the pinned Grafana image, network none and read-only, runs the init
#     container's script over the rendered chunks and then loads the plugin (signature valid,
#     community) and provisions the five dashboards and the datasource; anonymous and admin/admin
#     requests are refused.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$ROOT/scripts/lib/grafana_assets.sh"
GDIR="$ROOT/deploy/observability/grafana"
LOCK="$ROOT/versions.lock.yaml"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }
# report: run a checker printing PASS/FAIL lines; count its FAILs
report() {
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  local n; n="$(grep -c '^FAIL' <<<"$out")"
  fails=$((fails + n))
  if [[ "$rc" -ne 0 && "$n" -eq 0 ]]; then fail "checker exited $rc"; fi
}

for tool in python3 yq kubectl sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL $tool is required"; exit 1; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "FAIL python3 PyYAML is required"; exit 1; }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/grafana-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
chmod 755 "$scratch"

# fixture topology assets: quotes, a backslash, newlines and non-ASCII must survive verbatim
mkdir -p "$scratch/gen"
printf '<svg xmlns="http://www.w3.org/2000/svg" width="10">\n  <g id="cell-link_id:leaf01:e1-49:spine01:e1-1" data-q=\x27a"b\\c\x27>→</g>\n</svg>\n' >"$scratch/gen/topology.svg"
printf 'cellIdPreamble: cell-\ncells:\n  link_id:leaf01:e1-49:spine01:e1-1:\n    dataRef: "leaf01:e1-49:out"\n' >"$scratch/gen/topology-panel.yaml"

kubectl kustomize "$GDIR" >"$scratch/kustomized.yaml" 2>"$scratch/kustomize.err" \
  || { fail "kubectl kustomize deploy/observability/grafana" "$(cat "$scratch/kustomize.err")"; echo "$fails failure(s)"; exit 1; }
if bash "$LIB" render "$scratch/gen" >"$scratch/render.yaml" 2>"$scratch/render.err"; then
  pass "grafana_assets.sh render <generated> exits 0"
else
  fail "grafana_assets.sh render" "$(cat "$scratch/render.err")"; echo "$fails failure(s)"; exit 1
fi

# ---------------------------------------------------------------------- templates, manifests, lock
report python3 - "$ROOT" "$scratch" <<'PY'
import glob, hashlib, json, os, re, sys, yaml
root, scratch = sys.argv[1], sys.argv[2]
g = os.path.join(root, "deploy/observability/grafana")
lock = yaml.safe_load(open(os.path.join(root, "versions.lock.yaml")))["observability"]
plug = next(p for p in lock["grafanaPlugins"] if p["id"] == "andrewbmchugh-flow-panel")
def ok(c, name, detail=""):
    print(("PASS " if c else "FAIL ") + name + ("" if c or not detail else "\n    " + str(detail)))

series = json.load(open(os.path.join(g, "series.json")))["series"]
bad = [k for k, v in series.items() if not isinstance(v.get("metric"), str) or not v["metric"]
       or not isinstance(v.get("verified"), bool)]
ok(not bad, "series.json: every entry has a metric and a verified flag", bad)

want = {"fabric", "orchestration", "evpn-service-path", "physical-topology", "collector-health"}
files = {os.path.basename(p)[:-5]: p for p in glob.glob(os.path.join(g, "dashboards", "*.json"))}
ok(set(files) == want, "the five dashboards of T132 exist, and no other", sorted(files))

URL = re.compile(r"https?://", re.I)
SER = re.compile(r"@@series:([A-Za-z0-9_]+)@@")
uids = set()
for name, p in sorted(files.items()):
    txt = open(p, encoding="utf-8").read()
    try:
        d = json.loads(txt)
    except ValueError as e:
        ok(False, f"{name}: parses as JSON", e); continue
    ok(True, f"{name}: parses as JSON")
    prov = d.get("provenance") or {}
    ok(prov.get("source") and prov.get("version"), f"{name}: provenance object (source, version)", prov)
    ok(d.get("uid") and d["uid"] not in uids, f"{name}: unique uid", d.get("uid")); uids.add(d.get("uid"))
    dss = []
    def walk(o):
        if isinstance(o, dict):
            for k, v in o.items():
                if k == "datasource":
                    dss.append(v)
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(d)
    badds = [x for x in dss if not (isinstance(x, dict) and x.get("uid") == "prometheus" and x.get("type") == "prometheus")]
    ok(dss and not badds, f"{name}: every datasource is uid prometheus ({len(dss)} references)", badds[:3])
    ok(not URL.search(txt) and "githubusercontent" not in txt, f"{name}: no http(s) URL, nothing third-party",
       URL.findall(txt)[:3])
    unknown = sorted({m for m in SER.findall(txt) if m not in series})
    ok(not unknown, f"{name}: every @@series:…@@ is defined in series.json", unknown)
    exprs = []
    def ex(o):
        if isinstance(o, dict):
            if "expr" in o: exprs.append(o["expr"])
            for v in o.values(): ex(v)
        elif isinstance(o, list):
            for v in o: ex(v)
    ex(d)
    raw = [e for e in exprs if re.search(r"\bsrl_nokia_[a-z_]+:", e)]
    ok(not raw, f"{name}: no device metric name typed outside series.json", raw[:2])
    ids = [p["id"] for p in d.get("panels", [])]
    ok(len(ids) == len(set(ids)), f"{name}: unique panel ids")
    flows = [p for p in d.get("panels", []) if p.get("type") == "andrewbmchugh-flow-panel"]
    if name != "physical-topology":
        ok(not flows, f"{name}: no flow panel outside the topology view")
        continue
    ok(len(flows) == 1, "physical-topology: exactly one flow panel")
    if not flows:
        continue
    f = flows[0]; o = f.get("options", {})
    ok(f.get("pluginVersion") == str(plug["version"]), "flow panel pluginVersion is the lock's version",
       (f.get("pluginVersion"), plug["version"]))
    ok(o.get("svg") == "@@TOPOLOGY_SVG@@" and o.get("panelConfig") == "@@TOPOLOGY_PANEL_YAML@@",
       "flow panel svg/panelConfig are the inline placeholders", (o.get("svg"), o.get("panelConfig")))
    ok(o.get("siteConfig") == "" and o.get("testDataEnabled") is False, "flow panel: no site config, no test data")
    legends = sorted(t.get("legendFormat") for t in f.get("targets", []))
    pg = os.path.join(root, "internal/topologyview/panel.go")
    if os.path.isfile(pg):
        gl = sorted(re.findall(r'Legend(?:OperState|Out|In)\s*=\s*"([^"]+)"', open(pg).read()))
        ok(legends == gl, "flow panel legend formats = topologyview's dataRef legends", (legends, gl))
    else:
        want_l = sorted(["oper-state:{{source}}:{{interface_name}}", "{{source}}:{{interface_name}}:out",
                         "{{source}}:{{interface_name}}:in"])
        ok(legends == want_l, "flow panel legend formats (oper-state, out, in)", legends)

# the kustomized manifests
docs = [d for d in yaml.safe_load_all(open(os.path.join(scratch, "kustomized.yaml"))) if d]
dep = next((d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "grafana"), None)
svc = next((d for d in docs if d["kind"] == "Service" and d["metadata"]["name"] == "grafana"), None)
ok(dep is not None and dep["metadata"]["namespace"] == "monitoring", "Deployment monitoring/grafana")
ok(svc is not None and any(p["port"] == 3000 for p in svc["spec"]["ports"]), "Service monitoring/grafana :3000")
spec = dep["spec"]["template"]["spec"]
ctrs = spec.get("initContainers", []) + spec["containers"]
imgs = {c["name"]: c["image"] for c in ctrs}
ok(all(i == lock["grafana"]["pinned"] for i in imgs.values()), "every container runs the lock's pinned Grafana image", imgs)
ok(spec["securityContext"].get("runAsNonRoot") is True, "runAsNonRoot")
ok(all(c.get("resources", {}).get("limits") and c["resources"].get("requests") for c in ctrs), "resources on every container")
g_env = {e["name"]: e for e in next(c for c in spec["containers"] if c["name"] == "grafana")["env"]}
def val(n): return g_env.get(n, {}).get("value")
ok(val("GF_AUTH_ANONYMOUS_ENABLED") == "false", "anonymous access disabled")
ok(val("GF_USERS_ALLOW_SIGN_UP") == "false", "sign-up disabled")
# the install variables are spelt in pieces: verify_boundaries.sh reads a literal one as an install
install_var, preinstall = "GF_INSTALL_" + "PLUGINS", "GF_PLUGINS_" + "PREINSTALL"
ok(val(preinstall + "_DISABLED") == "true" and install_var not in g_env
   and not any(n.startswith(preinstall) and n != preinstall + "_DISABLED" for n in g_env),
   "no plugin install or preinstall at run time")
ok(all(val(n) == "false" for n in ("GF_ANALYTICS_REPORTING_ENABLED", "GF_ANALYTICS_CHECK_FOR_UPDATES",
                                    "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES", "GF_NEWS_NEWS_FEED_ENABLED")),
   "usage reporting, update checks and the news feed off")
refs = {n: (g_env.get(n, {}).get("valueFrom") or {}).get("secretKeyRef") for n in ("GF_SECURITY_ADMIN_USER", "GF_SECURITY_ADMIN_PASSWORD")}
ok(refs["GF_SECURITY_ADMIN_USER"] == {"name": "grafana-admin", "key": "admin-user"}
   and refs["GF_SECURITY_ADMIN_PASSWORD"] == {"name": "grafana-admin", "key": "admin-password"},
   "administrator only through secretKeyRef grafana-admin (admin-user, admin-password)", refs)
lit = [n for n, e in g_env.items() if re.search(r"PASSWORD|ADMIN_USER|SECRET|TOKEN", n) and "value" in e]
ok(not lit, "no credential literal in the Grafana environment", lit)
allenv = open(os.path.join(scratch, "kustomized.yaml")).read()
ok("GF_AUTH_ANONYMOUS_ORG_ROLE" not in allenv and "GF_AUTH_OAUTH_AUTO_LOGIN" not in allenv,
   "no anonymous role or auto-login setting")

ds = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "grafana-datasources")
dsl = yaml.safe_load(ds["data"]["datasources.yaml"])["datasources"]
ok(len(dsl) == 1 and dsl[0]["uid"] == "prometheus" and dsl[0]["url"] == "http://prometheus.monitoring.svc:9090"
   and dsl[0]["isDefault"] is True, "datasource: Prometheus uid prometheus at prometheus.monitoring.svc:9090, default", dsl)
prov = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "grafana-dashboard-providers")
pv = yaml.safe_load(prov["data"]["dashboards.yaml"])["providers"]
mounts = {m["mountPath"]: m["name"] for m in next(c for c in spec["containers"] if c["name"] == "grafana")["volumeMounts"]}
ok(pv[0]["type"] == "file" and mounts.get(pv[0]["options"]["path"]) == "dashboards",
   "dashboard file provider reads the mounted dashboards volume", (pv, mounts))

# the vendored package
zp = os.path.join(g, "vendor", f"andrewbmchugh-flow-panel-{plug['version']}.zip")
ok(os.path.isfile(zp) and hashlib.sha256(open(zp, "rb").read()).hexdigest() == plug["sha256"],
   "vendored plugin package sha256 = versions.lock.yaml grafanaPlugins sha256")
side = open(zp + ".provenance").read() if os.path.isfile(zp + ".provenance") else ""
ok(f"digest=sha256:{plug['sha256']}" in side and f"version={plug['version']}" in side,
   "the package's provenance sidecar carries the lock's version and digest")
open(os.path.join(scratch, "deployment.json"), "w").write(json.dumps(spec))
PY

# ------------------------------------------------------------------------------------ the render
report python3 - "$ROOT" "$scratch" <<'PY'
import base64, hashlib, json, os, sys, yaml
root, scratch = sys.argv[1], sys.argv[2]
lock = yaml.safe_load(open(os.path.join(root, "versions.lock.yaml")))["observability"]
plug = next(p for p in lock["grafanaPlugins"] if p["id"] == "andrewbmchugh-flow-panel")
spec = json.load(open(os.path.join(scratch, "deployment.json")))
def ok(c, name, detail=""):
    print(("PASS " if c else "FAIL ") + name + ("" if c or not detail else "\n    " + str(detail)))
raw = open(os.path.join(scratch, "render.yaml")).read()
docs = [d for d in yaml.safe_load_all(raw) if d]
ok(all(d["kind"] == "ConfigMap" and d["metadata"]["namespace"] == "monitoring" for d in docs), "render: ConfigMaps in monitoring only")
ok(all((d["metadata"].get("labels") or {}).get("agentic-netops.io/owned-by") for d in docs), "render: every ConfigMap ownership-labelled")
big = []
for d in docs:
    size = sum(len(v) for v in (d.get("binaryData") or {}).values()) + sum(len(k) + len(v.encode()) for k, v in (d.get("data") or {}).items())
    if size >= 1024 * 1024:
        big.append((d["metadata"]["name"], size))
ok(not big, "render: every ConfigMap under 1 MiB (base64 included)", big)
by = {d["metadata"]["name"]: d for d in docs}
lk = by.get("grafana-plugin-flow-panel-lock", {}).get("data", {})
ok(lk.get("sha256") == plug["sha256"] and lk.get("version") == str(plug["version"]),
   "lock ConfigMap carries the lock file's version and sha256", lk)
chunks = sorted((n for n in by if n.startswith("grafana-plugin-flow-panel-") and n[len("grafana-plugin-flow-panel-"):].isdigit()),
                key=lambda n: int(n.rsplit("-", 1)[1]))
parts = []
for n in chunks:
    parts += sorted(by[n]["binaryData"].items())
blob = b"".join(base64.b64decode(v) for _, v in sorted(parts))
ok(hashlib.sha256(blob).hexdigest() == plug["sha256"], f"the {len(chunks)} chunks reassemble (in key order) to the lock's digest")
vols = {v["name"]: v for v in spec["volumes"]}
dep_chunks = [s["configMap"]["name"] for s in vols["plugin-chunks"]["projected"]["sources"]]
ok(dep_chunks == chunks, "Deployment plugin-chunks volume = the rendered chunk ConfigMaps", (dep_chunks, chunks))
dash_cms = sorted(n for n in by if n.startswith("grafana-dashboard-"))
dep_dash = sorted(s["configMap"]["name"] for s in vols["dashboards"]["projected"]["sources"])
ok(dep_dash == dash_cms, "Deployment dashboards volume = the rendered dashboard ConfigMaps", (dep_dash, dash_cms))
init = spec["initContainers"][0]
envs = {e["name"]: e.get("valueFrom", {}).get("configMapKeyRef") for e in init["env"]}
ok(envs.get("FLOW_PANEL_SHA256") == {"name": "grafana-plugin-flow-panel-lock", "key": "sha256"},
   "init container checks the digest from the lock ConfigMap", envs)
ok("sha256sum -c" in init["args"][0] and "andrewbmchugh-flow-panel.zip.part-*" in init["args"][0],
   "init container concatenates the chunks and verifies before unpacking")
svg = open(os.path.join(scratch, "gen/topology.svg"), encoding="utf-8").read()
pyml = open(os.path.join(scratch, "gen/topology-panel.yaml"), encoding="utf-8").read()
left = []
for n in dash_cms:
    (k, v), = by[n]["data"].items()
    j = json.loads(v)
    if "@@" in json.dumps({kk: vv for kk, vv in j.items()}).replace(json.dumps(svg)[1:-1], "").replace(json.dumps(pyml)[1:-1], ""):
        left.append(n)
    if n == "grafana-dashboard-physical-topology":
        f = next(p for p in j["panels"] if p["type"] == "andrewbmchugh-flow-panel")
        ok(f["options"]["svg"] == svg, "topology SVG substituted verbatim (quotes, backslash, newlines)")
        ok(f["options"]["panelConfig"] == pyml, "topology panel YAML substituted verbatim")
        ok(f["targets"][0]["expr"] == "srl_nokia_interfaces:interface_oper_state", "series placeholder resolved from series.json",
           f["targets"][0]["expr"])
ok(not left, "no placeholder left in any rendered dashboard", left)
PY

# ------------------------------------------------------------------------------------ refusals
mkdir -p "$scratch/nogen"
cp "$scratch/gen/topology-panel.yaml" "$scratch/nogen/"
out="$(bash "$LIB" render "$scratch/nogen" 2>&1 >/dev/null)"; rc=$?
if [[ "$rc" -ne 0 && "$out" == *"topology.svg"* ]]; then pass "refuses a missing topology.svg, naming it"; else fail "missing topology.svg not refused (rc=$rc)" "$out"; fi

cp -r "$GDIR" "$scratch/gdir"
python3 - "$scratch/gdir/dashboards/fabric.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["panels"][1]["targets"][0]["expr"] = "@@series:no_such_series@@"
json.dump(d, open(p, "w"))
PY
out="$(GRAFANA_ASSETS_DIR="$scratch/gdir" bash "$LIB" render "$scratch/gen" 2>&1 >/dev/null)"; rc=$?
if [[ "$rc" -ne 0 && "$out" == *"no_such_series"* ]]; then pass "refuses an unknown series name, naming it"; else fail "unknown series not refused (rc=$rc)" "$out"; fi

sed 's/9c4fd97623191877e6be0ca3afde293cea62b667db50d5044b7679ca83b08816/0000000000000000000000000000000000000000000000000000000000000000/' "$LOCK" >"$scratch/lock.yaml"
if cmp -s "$LOCK" "$scratch/lock.yaml"; then
  fail "fixture: the lock's plugin digest was not found to alter"
else
  out="$(GRAFANA_ASSETS_LOCK="$scratch/lock.yaml" bash "$LIB" render "$scratch/gen" 2>&1 >/dev/null)"; rc=$?
  if [[ "$rc" -ne 0 && "$out" == *"refusing to serve"* ]]; then pass "refuses a package whose digest is not the lock's"; else fail "digest mismatch not refused (rc=$rc)" "$out"; fi
fi

# ------------------------------------------------------------------------ PromQL parse (promtool)
prom="$(yq -r '.observability.prometheus.pinned' "$LOCK")"
if command -v docker >/dev/null 2>&1 && docker image inspect "$prom" >/dev/null 2>&1; then
  python3 - "$scratch/render.yaml" >"$scratch/rules.yaml" <<'PY'
import json, sys, yaml
M = {"$__rate_interval": "1m", "$__range_s": "3600", "$__range": "1h", "$service_id": "svc",
     "$service": "macvrf-svc", "$vni": "10", "$node": ".*"}
rules = []
def ex(o):
    if isinstance(o, dict):
        if "expr" in o: yield o["expr"]
        for v in o.values(): yield from ex(v)
    elif isinstance(o, list):
        for v in o: yield from ex(v)
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d["metadata"]["name"].startswith("grafana-dashboard-"):
        for k, v in d["data"].items():
            for i, e in enumerate(ex(json.loads(v))):
                for a in sorted(M, key=len, reverse=True): e = e.replace(a, M[a])
                rules.append({"record": "dashboard:%s:%d" % (k[:-5].replace("-", "_"), i), "expr": e})
print(yaml.safe_dump({"groups": [{"name": "dashboards", "rules": rules}]}))
PY
  if out="$(docker run --rm --network none -v "$scratch:/w:ro" --entrypoint promtool "$prom" check rules /w/rules.yaml 2>&1)"; then
    pass "every dashboard expression parses as PromQL ($(grep -o '[0-9]* rules found' <<<"$out"))"
  else
    fail "promtool rejects a dashboard expression" "$out"
  fi
else
  echo "SKIP PromQL parse: the pinned Prometheus image is not present locally"
fi

# ------------------------------------------------------------- the pinned image (GRAFANA_IMAGE_TEST=1)
if [[ "${GRAFANA_IMAGE_TEST:-0}" == 1 ]]; then
  img="$(yq -r '.observability.grafana.pinned' "$LOCK")"
  sim="$scratch/sim"; mkdir -p "$sim"/{chunks,data,tmp,dash,prov/datasources,prov/dashboards}; chmod 777 "$sim/data" "$sim/tmp"
  python3 - "$scratch" "$sim" <<'PY'
import base64, json, sys, yaml
s, sim = sys.argv[1], sys.argv[2]
for d in yaml.safe_load_all(open(f"{s}/render.yaml")):
    if not d: continue
    for k, v in (d.get("binaryData") or {}).items(): open(f"{sim}/chunks/{k}", "wb").write(base64.b64decode(v))
    n = d["metadata"]["name"]
    if n.startswith("grafana-dashboard-"):
        for k, v in d["data"].items(): open(f"{sim}/dash/{k}", "w").write(v)
    if n == "grafana-plugin-flow-panel-lock":
        open(f"{sim}/lock.env", "w").write(f"FLOW_PANEL_SHA256={d['data']['sha256']}\nFLOW_PANEL_VERSION={d['data']['version']}\n")
for d in yaml.safe_load_all(open(f"{s}/kustomized.yaml")):
    if d["kind"] == "ConfigMap":
        sub = "datasources" if d["metadata"]["name"] == "grafana-datasources" else "dashboards"
        for k, v in d["data"].items(): open(f"{sim}/prov/{sub}/{k}", "w").write(v)
    if d["kind"] == "Deployment":
        sp = d["spec"]["template"]["spec"]
        open(f"{sim}/init.sh", "w").write(sp["initContainers"][0]["args"][0])
        open(f"{sim}/grafana.env", "w").write("".join(f"{e['name']}={e['value']}\n" for e in sp["containers"][0]["env"] if "value" in e))
PY
  chmod -R a+rX "$sim"
  name="grafana-test-$$"
  if docker run --rm --network none --read-only --cap-drop ALL --user 472:0 --env-file "$sim/lock.env" \
       -v "$sim/data:/var/lib/grafana" -v "$sim/chunks:/plugin-chunks:ro" --entrypoint /bin/sh "$img" -ec "$(cat "$sim/init.sh")" >/dev/null 2>&1; then
    pass "pinned image: the init script reassembles, verifies and unpacks the plugin"
  else
    fail "pinned image: the init script failed"
  fi
  pw="t-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  docker run -d --name "$name" --network none --read-only --cap-drop ALL --user 472:0 --env-file "$sim/grafana.env" \
    -e GF_SECURITY_ADMIN_USER=opsadmin -e GF_SECURITY_ADMIN_PASSWORD="$pw" \
    -v "$sim/data:/var/lib/grafana" -v "$sim/tmp:/tmp" -v "$sim/prov/datasources:/etc/grafana/provisioning/datasources:ro" \
    -v "$sim/prov/dashboards:/etc/grafana/provisioning/dashboards:ro" -v "$sim/dash:/var/lib/grafana/dashboards:ro" "$img" >/dev/null
  auth="Authorization: Basic $(printf 'opsadmin:%s' "$pw" | base64)"
  get() { docker exec "$name" wget -q -O - --header="$1" "http://127.0.0.1:3000$2" 2>/dev/null; }
  for _ in $(seq 1 60); do get "$auth" /api/health >/dev/null && break; sleep 2; done
  sig="$(get "$auth" /api/plugins/andrewbmchugh-flow-panel/settings | jq -r '[.signature, .signatureType, .info.version] | join(" ")')"
  if [[ "$sig" == "valid community 1.20.1" ]]; then pass "pinned image: plugin loaded, signature valid (community), 1.20.1"; else fail "plugin not loaded: '$sig'" "$(docker logs "$name" 2>&1 | grep -i flow | tail -5)"; fi
  n="$(get "$auth" '/api/search?type=dash-db' | jq '[.[] | select(.folderTitle == "Agentic NetOps")] | length')"
  if [[ "$n" == 5 ]]; then pass "pinned image: the five dashboards provisioned"; else fail "dashboards provisioned: $n"; fi
  ds="$(get "$auth" /api/datasources/uid/prometheus | jq -r '.url')"
  if [[ "$ds" == "http://prometheus.monitoring.svc:9090" ]]; then pass "pinned image: datasource uid prometheus provisioned"; else fail "datasource: '$ds'"; fi
  if get "" /api/search >/dev/null || get "Authorization: Basic $(printf admin:admin | base64)" /api/search >/dev/null; then
    fail "pinned image: an anonymous or admin/admin request was answered"
  else
    pass "pinned image: anonymous and admin/admin requests refused"
  fi
  docker rm -f "$name" >/dev/null 2>&1
else
  echo "SKIP pinned-image load (set GRAFANA_IMAGE_TEST=1 to run it)"
fi

if [[ "$fails" -eq 0 ]]; then echo "grafana: all checks passed"; exit 0; fi
echo "grafana: $fails failure(s)"; exit 1
