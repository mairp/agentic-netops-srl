#!/usr/bin/env bash
# intent_tier_patch_test.sh — the intent tier's reversible two-line Grafana patch and its dashboard's
# links (T137; FR-095, R-19). Offline: scripts/lib/intent_tier.sh is sourced and
# intent_tier::grafana_patch / grafana_unpatch run against a stateful fake kubectl (JSON patch with
# `test` semantics, server-side apply by kind/name, managedFields per field manager) seeded with the
# control plane's own Deployment monitoring/grafana (kubectl kustomize deploy/observability/grafana).
#
#   P1  the patch adds exactly two sources — configMap grafana-dashboards-agents at the end of the
#       projected `dashboards` volume, secret grafana-agents-datasource at the end of the projected
#       `datasources` volume — and nothing else of the Deployment changes
#   P2  ConfigMap grafana-dashboards-agents (intent-tier.json) and Secret grafana-agents-datasource are
#       applied: the datasource file is agent-analytics (uid agent-analytics, mysql, the ClickHouse pod
#       DNS name on 9004, database otel) with the user and password of clickhouse-auth — the password
#       on no command line, in no output
#   P3  a re-run adds no source and issues no patch
#   P4  the patch leaves no field manager behind (the control plane's next apply meets no conflict)
#   R1  the revert removes exactly those two sources: the volumes are identical to before; the
#       ConfigMap and the Secret are deleted
#   R2  a revert when nothing is patched is a no-op (no patch, exit 0)
#   N1  no monitoring/grafana (no observability stack): patch and revert are reported no-ops
#   N2  a Deployment whose datasources volume is not projected is refused, naming it; nothing patched
#   L1  every link of intent-tier.json and of evpn-service-path's "Created by conversation" panel names
#       its target by uid, carries var-correlation_id (→ intent-tier) or var-service (→ the fabric
#       service view), and carries no time (from= / to= / ${__url_time_range} / time / __from / __to)
#   L2  the conversation-trace SQL filters on TraceId = '$correlation_id' and has no $__timeFilter
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 12 | sed 's/^/    | /'; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${out:-}"; fi; }

for tool in python3 jq yq kubectl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL $tool is required"; exit 1; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "FAIL python3 PyYAML is required"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/intent-tier-patch.XXXXXX")"
trap 'rm -rf "$T"' EXIT
CH_USER="agentic_netops" CH_PW='Ch-pw-never-on-argv-9q'

# ------------------------------------------------------------------------------ the fake kubectl
mkdir -p "$T/bin"
cat >"$T/bin/fake_kubectl.py" <<'PY'
import base64, json, os, sys, yaml
S = os.environ["FAKE_STATE"]
args = sys.argv[1:]
with open(os.path.join(S, "calls.log"), "a") as f:
    f.write("kubectl " + " ".join(args) + "\n")
def opt(name, default=None):
    for i, a in enumerate(args):
        if a == name:
            v = args[i + 1]; del args[i:i + 2]; return v
        if a.startswith(name + "="):
            del args[i]; return a.split("=", 1)[1]
    return default
opt("--context")
ns = opt("-n") or "_"
out = opt("-o")
fm = opt("--field-manager")
ptype = opt("--type")
patch = opt("-p")
fname = opt("-f")
flags = {a for a in args if a.startswith("--")}
args = [a for a in args if not a.startswith("--")]
KIND = {"deployment": "deployment", "deploy": "deployment", "secret": "secret", "configmap": "configmap",
        "namespace": "namespace", "cm": "configmap"}
def path(kind, name, n=None):
    return os.path.join(S, "k8s", n or ns, kind, name + ".json")
def load(kind, name, n=None):
    p = path(kind, name, n)
    return json.load(open(p)) if os.path.isfile(p) else None
def save(obj, kind, name, n=None):
    p = path(kind, name, n); os.makedirs(os.path.dirname(p), exist_ok=True); json.dump(obj, open(p, "w"))
verb = args[0] if args else ""
if verb == "get":
    kind = KIND[args[1]]; n = "_" if kind == "namespace" else ns
    o = load(kind, args[2], n)
    if o is None:
        print(f'Error from server (NotFound): {args[1]} "{args[2]}" not found', file=sys.stderr); sys.exit(1)
    if out == "name":
        print(f"{kind}/{args[2]}")
    else:
        if "--show-managed-fields" not in flags:
            o.get("metadata", {}).pop("managedFields", None)
        print(json.dumps(o))
elif verb == "apply":
    docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
    for d in docs:
        kind = d["kind"].lower(); n = d["metadata"].get("namespace", ns)
        save(d, kind, d["metadata"]["name"], n)
        with open(os.path.join(S, "calls.log"), "a") as f:
            f.write(f"APPLY {d['kind']}/{d['metadata']['name']}\n")
elif verb == "patch":
    kind = KIND[args[1]]; o = load(kind, args[2])
    if o is None:
        print("not found", file=sys.stderr); sys.exit(1)
    assert ptype == "json", ptype
    ops = json.loads(patch)
    def walk(doc, p):
        parts = [x.replace("~1", "/").replace("~0", "~") for x in p.lstrip("/").split("/")]
        for x in parts[:-1]:
            doc = doc[int(x)] if isinstance(doc, list) else doc[x]
        return doc, parts[-1]
    touched_mf = False
    for op in ops:
        if op["path"].startswith("/metadata/managedFields"):
            touched_mf = True
        parent, key = walk(o, op["path"])
        if op["op"] == "test":
            cur = parent[int(key)] if isinstance(parent, list) else parent.get(key)
            if cur != op["value"]:
                print(f"The request is invalid: the server rejected our request due to an error in our request (test {op['path']})", file=sys.stderr); sys.exit(1)
        elif op["op"] == "add":
            if isinstance(parent, list):
                parent.append(op["value"]) if key == "-" else parent.insert(int(key), op["value"])
            else:
                parent[key] = op["value"]
        elif op["op"] == "remove":
            if isinstance(parent, list): del parent[int(key)]
            else: del parent[key]
        else:
            sys.exit(f"fake: op {op['op']} unsupported")
    if fm and not touched_mf:
        mf = o.setdefault("metadata", {}).setdefault("managedFields", [])
        if not any(e["manager"] == fm and e["operation"] == "Update" for e in mf):
            mf.append({"manager": fm, "operation": "Update"})
    save(o, kind, args[2])
    print(f"{kind}.apps/{args[2]} patched")
elif verb == "delete":
    kind = KIND[args[1]]
    for name in args[2:]:
        p = path(kind, name)
        if os.path.isfile(p):
            os.remove(p); print(f'{kind} "{name}" deleted')
        elif "--ignore-not-found" not in flags:
            print("not found", file=sys.stderr); sys.exit(1)
elif verb == "rollout":
    print("successfully rolled out")
else:
    sys.exit(f"fake kubectl: unsupported {sys.argv[1:]}")
PY
printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$T/bin/fake_kubectl.py" >"$T/bin/kubectl"
chmod +x "$T/bin/kubectl"
REAL_KUBECTL="$(command -v kubectl)"
"$REAL_KUBECTL" kustomize "$ROOT/deploy/observability/grafana" >"$T/grafana.yaml" 2>"$T/kustomize.err" \
  || { echo "FAIL kubectl kustomize deploy/observability/grafana"; cat "$T/kustomize.err"; exit 1; }

# setup <case> [grafana:yes|no]
setup() {
  export FAKE_STATE="$T/$1"
  rm -rf "$FAKE_STATE"; mkdir -p "$FAKE_STATE"; : >"$FAKE_STATE/calls.log"
  if [[ "${2:-yes}" == yes ]]; then
    python3 - "$T/grafana.yaml" "$FAKE_STATE" <<'PY'
import json, os, sys, yaml
src, st = sys.argv[1], sys.argv[2]
for d in yaml.safe_load_all(open(src)):
    if d and d["kind"] == "Deployment":
        d["metadata"]["managedFields"] = [{"manager": "agentic-netops-provision", "operation": "Apply"}]
        os.makedirs(f"{st}/k8s/monitoring/deployment", exist_ok=True)
        json.dump(d, open(f"{st}/k8s/monitoring/deployment/grafana.json", "w"))
os.makedirs(f"{st}/k8s/_/namespace", exist_ok=True)
json.dump({"metadata": {"name": "monitoring"}}, open(f"{st}/k8s/_/namespace/monitoring.json", "w"))
PY
  fi
  mkdir -p "$FAKE_STATE/k8s/agentic-netops-agents/secret"
  jq -n --arg u "$(printf '%s' "$CH_USER" | base64)" --arg p "$(printf '%s' "$CH_PW" | base64)" \
    '{metadata: {name: "clickhouse-auth", namespace: "agentic-netops-agents"}, data: {username: $u, password: $p}}' \
    >"$FAKE_STATE/k8s/agentic-netops-agents/secret/clickhouse-auth.json"
}
# run <function> — the function in a fresh shell against the fake
run() {
  out="$(cd "$ROOT" && PATH="$T/bin:$PATH" KUBECTL="$T/bin/kubectl" KUBE_CONTEXT=kind-test CLUSTER_NAME=agentic-netops \
    INTENT_TIER_WAIT_TIMEOUT=5 bash -c 'source scripts/lib/intent_tier.sh; "$1"' _ "$1" 2>&1)"
  rc=$?
}
dep() { jq -c "$1" "$FAKE_STATE/k8s/monitoring/deployment/grafana.json"; }
vols() { dep '.spec.template.spec.volumes'; }
patches() { grep -c '^kubectl .* patch ' "$FAKE_STATE/calls.log"; }

# ====================================================================== P1–P4
setup patch
before="$(vols)"; before_dep="$(dep 'del(.spec.template.spec.volumes) | del(.metadata.managedFields)')"
run intent_tier::grafana_patch
check "P1 grafana_patch exits 0" '[[ $rc -eq 0 ]]'
diff_json="$(python3 - "$before" "$(vols)" <<'PY'
import json, sys
a = {v["name"]: v for v in json.loads(sys.argv[1])}; b = {v["name"]: v for v in json.loads(sys.argv[2])}
out = {}
for n in sorted(set(a) | set(b)):
    sa = (a.get(n) or {}).get("projected", {}).get("sources"); sb = (b.get(n) or {}).get("projected", {}).get("sources")
    if a.get(n) == b.get(n):
        continue
    if sa is not None and sb is not None and sb[:len(sa)] == sa and {k: v for k, v in a[n].items() if k != "projected"} == {k: v for k, v in b[n].items() if k != "projected"}:
        out[n] = sb[len(sa):]
    else:
        out[n] = "CHANGED OTHERWISE"
print(json.dumps(out, sort_keys=True, separators=(",", ":")))
PY
)"
check "P1 exactly two sources appended: configMap grafana-dashboards-agents to dashboards, secret grafana-agents-datasource to datasources" \
  '[[ "$diff_json" == "{\"dashboards\":[{\"configMap\":{\"name\":\"grafana-dashboards-agents\"}}],\"datasources\":[{\"secret\":{\"name\":\"grafana-agents-datasource\"}}]}" ]] || { out="$diff_json"; false; }'
check "P1 nothing else of the Deployment changed" '[[ "$(dep "del(.spec.template.spec.volumes) | del(.metadata.managedFields)")" == "$before_dep" ]]'
check "P1 the patch is a JSON patch guarded by a test of each volume's name" \
  'grep -q "^kubectl .* patch deployment grafana .*--type=json" "$FAKE_STATE/calls.log" && grep "patch deployment grafana" "$FAKE_STATE/calls.log" | head -1 | grep -q "\"op\":\"test\",\"path\":\"/spec/template/spec/volumes/[0-9]*/name\",\"value\":\"dashboards\""'
check "P1 the rollout of monitoring/grafana is waited" 'grep -q "rollout status deployment/grafana -n monitoring" "$FAKE_STATE/calls.log"'
CM="$FAKE_STATE/k8s/monitoring/configmap/grafana-dashboards-agents.json"
SEC="$FAKE_STATE/k8s/monitoring/secret/grafana-agents-datasource.json"
check "P2 ConfigMap grafana-dashboards-agents applied with intent-tier.json (uid intent-tier), tier-labelled" \
  '[[ -f "$CM" ]] && [[ "$(jq -r ".data[\"intent-tier.json\"] | fromjson | .uid" "$CM")" == intent-tier && "$(jq -r ".metadata.labels[\"app.kubernetes.io/part-of\"]" "$CM")" == agentic-netops-intent-tier ]]'
dsfile="$( [[ -f "$SEC" ]] && jq -r '.data["agent-analytics.yaml"] | @base64d' "$SEC")"
check "P2 Secret grafana-agents-datasource: agent-analytics, uid agent-analytics, mysql at the ClickHouse pod on 9004, database otel, clickhouse-auth's user and password" \
  '[[ "$(yq -o=json -I=0 ".datasources[0] | [.name, .uid, .type, .url, .jsonData.database, .user, .secureJsonData.password]" <<<"$dsfile")" == "[\"agent-analytics\",\"agent-analytics\",\"mysql\",\"clickhouse-0.clickhouse-headless.agentic-netops-agents.svc:9004\",\"otel\",\"$CH_USER\",\"$CH_PW\"]" ]] || { out="$dsfile"; false; }'
check "P2 the Secret is tier-labelled (part-of agentic-netops-intent-tier) and ownership-labelled" \
  '[[ "$(jq -r ".metadata.labels[\"app.kubernetes.io/part-of\"]" "$SEC")" == agentic-netops-intent-tier && "$(jq -r ".metadata.labels[\"agentic-netops.io/owned-by\"]" "$SEC")" == agentic-netops ]]'
check "P2 the ClickHouse password is on no command line and in no output" '! grep -qF "$CH_PW" "$FAKE_STATE/calls.log" && ! grep -qF "$CH_PW" <<<"$out"'
patched="$(vols)"; n_patch="$(patches)"
run intent_tier::grafana_patch
check "P3 a re-run exits 0, adds no source and issues no patch" '[[ $rc -eq 0 && "$(vols)" == "$patched" && "$(patches)" -eq "$n_patch" ]] && grep -q "already carries" <<<"$out"'
check "P4 no field manager of the patch is left on the Deployment (only the control plane's Apply)" \
  '[[ "$(dep "[.metadata.managedFields[] | .manager + \"/\" + .operation]")" == "[\"agentic-netops-provision/Apply\"]" ]]'

# ====================================================================== R1–R2
run intent_tier::grafana_unpatch
check "R1 grafana_unpatch exits 0" '[[ $rc -eq 0 ]]'
check "R1 the control-plane volumes are identical to before the patch" '[[ "$(vols)" == "$before" ]] || { out="$(vols)"; false; }'
check "R1 ConfigMap grafana-dashboards-agents and Secret grafana-agents-datasource are deleted" '[[ ! -f "$CM" && ! -f "$SEC" ]]'
check "R1 the revert's removes are each guarded by a test of the source" \
  'grep "patch deployment grafana" "$FAKE_STATE/calls.log" | tail -2 | head -1 | grep -q "\"op\":\"test\",\"path\":\"/spec/template/spec/volumes/[0-9]*/projected/sources/[0-9]*\",\"value\":{\"secret\":{\"name\":\"grafana-agents-datasource\"}}"'
n_patch="$(patches)"
run intent_tier::grafana_unpatch
check "R2 a revert when nothing is patched: exit 0, no patch, volumes unchanged" '[[ $rc -eq 0 && "$(patches)" -eq "$n_patch" && "$(vols)" == "$before" ]]'

# a tier source listed twice (a hand edit) is removed in full, the control plane's sources kept
setup twice
jq '(.spec.template.spec.volumes[] | select(.name == "dashboards") | .projected.sources) |= (.[:2] + [{"configMap": {"name": "grafana-dashboards-agents"}}] + .[2:] + [{"configMap": {"name": "grafana-dashboards-agents"}}])' \
  "$FAKE_STATE/k8s/monitoring/deployment/grafana.json" >"$T/twice.json" && mv "$T/twice.json" "$FAKE_STATE/k8s/monitoring/deployment/grafana.json"
run intent_tier::grafana_unpatch
check "R1 a tier source present twice (at any position) is removed in full; the control plane's sources and their order kept" \
  '[[ $rc -eq 0 && "$(vols)" == "$before" ]] || { out="$(vols)"; false; }'

# ====================================================================== N1–N2
setup nografana no
run intent_tier::grafana_patch
check "N1 no monitoring/grafana: grafana_patch exits 0, reports the no-op, applies and patches nothing" \
  '[[ $rc -eq 0 ]] && grep -q "no observability stack" <<<"$out" && ! grep -qE "^APPLY|patch " "$FAKE_STATE/calls.log"'
run intent_tier::grafana_unpatch
check "N1 no monitoring/grafana: grafana_unpatch exits 0, reports the no-op, deletes and patches nothing" \
  '[[ $rc -eq 0 ]] && grep -q "no Grafana patch to revert" <<<"$out" && ! grep -qE " delete | patch " "$FAKE_STATE/calls.log"'

setup notprojected
jq '(.spec.template.spec.volumes[] | select(.name == "datasources")) |= {name: "datasources", configMap: {name: "grafana-datasources"}}' \
  "$FAKE_STATE/k8s/monitoring/deployment/grafana.json" >"$T/np.json" && mv "$T/np.json" "$FAKE_STATE/k8s/monitoring/deployment/grafana.json"
np_before="$(vols)"
run intent_tier::grafana_patch
check "N2 a datasources volume that is not projected: refused non-zero naming it, the Deployment unchanged" \
  '[[ $rc -ne 0 && "$(vols)" == "$np_before" ]] && grep -q "datasources is not projected" <<<"$out" && [[ "$(patches)" -eq 0 ]]'

# ====================================================================== L1–L2 the dashboard lint
out="$(python3 - "$ROOT/deploy/observability/grafana/dashboards" <<'PY'
import json, os, re, sys
d = sys.argv[1]
tier = json.load(open(os.path.join(d, "intent-tier.json")))
evpn = json.load(open(os.path.join(d, "evpn-service-path.json")))
def ok(c, name, detail=""):
    print(("PASS " if c else "FAIL ") + name + ("" if c or not detail else "\n    " + str(detail)))
def panels(dash):
    for p in dash.get("panels", []):
        yield p
        yield from p.get("panels", [])
def links(p):
    fc = p.get("fieldConfig") or {}
    ls = list((fc.get("defaults") or {}).get("links") or []) + list(p.get("links") or [])
    for ov in fc.get("overrides") or []:
        for prop in ov.get("properties") or []:
            if prop.get("id") == "links":
                ls += prop.get("value") or []
    return ls
TIME = re.compile(r"(^|[?&])(from|to|time|time\.window)=|__url_time_range|\$\{?__from|\$\{?__to", re.I)
VARS = {"intent-tier": {v["name"] for v in tier["templating"]["list"]},
        "agentic-netops-evpn-service-path": {v["name"] for v in evpn["templating"]["list"]}}
created = [p for p in panels(evpn) if p.get("title") == "Created by conversation"]
ok(len(created) == 1, "evpn-service-path has one 'Created by conversation' panel")
all_links = [("intent-tier", p["title"], l) for p in panels(tier) for l in links(p)] + \
            [("evpn-service-path", p["title"], l) for p in created for l in links(p)]
ok(len(all_links) >= 4, f"the links exist ({len(all_links)}: the services table's two, the trace's one, the evpn panel's one)")
bad_time, bad_target, bad_var = [], [], []
for src, title, l in all_links:
    url = l.get("url", "")
    if TIME.search(url) or l.get("keepTime") or l.get("includeVars"):
        bad_time.append((src, title, url))
    m = re.match(r"^/d/([A-Za-z0-9_-]+)(/[A-Za-z0-9_-]+)?\?(.*)$", url)
    if not m or m.group(1) not in VARS:
        bad_target.append((src, title, url)); continue
    params = dict(kv.split("=", 1) for kv in m.group(3).split("&"))
    names = {k[len("var-"):] for k in params if k.startswith("var-")}
    if not names or not names <= VARS[m.group(1)] or any(not k.startswith("var-") for k in params):
        bad_var.append((src, title, url))
    if m.group(1) == "intent-tier" and params.get("var-correlation_id") != "${__data.fields.correlation_id}":
        bad_var.append((src, title, url))
    if m.group(1) == "agentic-netops-evpn-service-path" and params.get("var-service") != "${__data.fields.service}":
        bad_var.append((src, title, url))
ok(not bad_time, "L1 no link carries a time range (from= / to= / time / ${__url_time_range} / __from / __to / keepTime)", bad_time)
ok(not bad_target, "L1 every link names intent-tier or the fabric service view by uid, relative (no host)", bad_target)
ok(not bad_var, "L1 → intent-tier carries var-correlation_id=${__data.fields.correlation_id}; → the service view var-service=${__data.fields.service}; only variables the target defines", bad_var)
svc = [p for p in panels(tier) if p.get("title") == "Services created by conversation"]
ok(svc and {("intent-tier" in l["url"]), ("evpn-service-path" in l["url"])} == {True, False} and len(links(svc[0])) == 2,
   "L1 the services table links both ways: this dashboard by correlation id and the fabric service view")
ok(all("intent-tier?var-correlation_id=" in l["url"] for p in created for l in links(p)),
   "L1 'Created by conversation' links to intent-tier by correlation id")
sqls = [t.get("rawSql", "") for p in panels(tier) for t in p.get("targets", []) if (t.get("datasource") or {}).get("uid") == "agent-analytics"]
ok(len(sqls) == 1, "L2 one conversation-trace query on agent-analytics", len(sqls))
for s in sqls:
    ok("$__timeFilter" not in s and "$__time" not in s and "$__unixEpoch" not in s, "L2 the trace SQL has no $__timeFilter (no time macro at all)")
    ok(re.search(r"WHERE TraceId = '\$correlation_id'\s*ORDER BY Timestamp", s) is not None, "L2 the trace SQL filters on TraceId = '$correlation_id' ORDER BY Timestamp")
    ok(all(c in s for c in ("AS stage", "AS failure_reason", "AS failure_payload", "AS duration_ms", "AS audit_events", "AS service_id", "AS service")),
       "L2 the trace SQL returns stage, failure reason and payload, duration, audit events and the service-link columns")
trace = [p for p in panels(tier) if (p.get("datasource") or {}).get("uid") == "agent-analytics"]
ok(trace and any("evpn-service-path?var-service=${__data.fields.service}" in l["url"] for l in links(trace[0])),
   "L1 the trace links back to the fabric service view")
PY
)"
printf '%s\n' "$out"
pass=$((pass + $(grep -c '^PASS' <<<"$out"))); fail=$((fail + $(grep -c '^FAIL' <<<"$out")))

printf '\nintent_tier_patch_test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
