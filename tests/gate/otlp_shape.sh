#!/usr/bin/env bash
# tests/gate/otlp_shape.sh — T166: the OTLP resource and attribute shape the tier's instrumentation
# emits at the PINNED ioa-observe-sdk (agents/pyproject.toml), which T087/T129/T135/T136 are built
# against — observed, not guessed (research Open item 14, D-37).
#
# A throwaway pair in the gate-labelled scratch namespace vt-scratch-otlp-shape:
#   - the pinned collector (versions.lock.yaml observability.otelCollector) with an OTLP receiver
#     (gRPC 4317, HTTP 4318) and the debug exporter at detailed verbosity, for traces and metrics;
#   - an emitter Pod on the agents' pinned Python base image (versions.lock.yaml firstPartyImages,
#     the supervisor's FROM), which installs exactly the pinned SDK version and emits ONE trace (an
#     SDK-decorated agent call) and ONE metric (a counter), then flushes.
# The collector's debug output is read once and reduced to the shape: resource attribute keys (and
# service.name), span names / kinds / attribute keys, metric names / types / data-point attribute
# keys — no ids, no timestamps. The namespace is removed and its removal read back.
# Writes $EVIDENCE_DIR/gate/qualifications/otlp_shape.json.
set -euo pipefail
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"
evidence::ensure_dir
mkdir -p "$EVIDENCE_DIR/gate/qualifications" "$EVIDENCE_DIR/gate/manifests" "$EVIDENCE_DIR/gate/observed"
GATE_ITEM=OTLP
NS="vt-scratch-otlp-shape"
OUT="$EVIDENCE_DIR/gate/qualifications/otlp_shape.json"

OIMG="$(gate::lock_image observability.otelCollector.pinned)"
PYIMG="$(python3 - "$GATE_REPO_ROOT/versions.lock.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
img = next(i for i in d["firstPartyImages"] if i["name"] == "supervisor")["from"][0]
ref = img["ref"] if "/" in img["ref"] else "docker.io/library/" + img["ref"]
print(f'{ref}:{img["tag"]}@{img["digest"]}')
PY
)"
SDK_VER="$(sed -nE 's/.*"ioa-observe-sdk==([0-9][^"]*)".*/\1/p' "$GATE_REPO_ROOT/agents/pyproject.toml" | head -1)"
if [[ -z "$SDK_VER" ]]; then
  jq -n '{name: "otlp_shape", status: "fail", reason: "ioa-observe-sdk is not pinned in agents/pyproject.toml"}' >"$OUT"; exit 1
fi

# The emitter's Python environment is the supervisor image's own `build` stage — agents/uv.lock
# installed by `uv sync --frozen` (hash-verified), so the SDK is the locked one and nothing is
# fetched from the package index inside the cluster (T151 r8 cycle 3 / T152 r7: the in-Pod
# `pip install` stalled for 7 min twice and failed GateReady). Built on the host (the layer cache
# makes a rebuild a no-op), `kind load`ed, run with imagePullPolicy Never. Only if that build
# fails does the Pod fall back to installing the pinned SDK itself.
EMIMG="vt-scratch-otlp-emitter:sdk-${SDK_VER}"
EMCMD="/app/.venv/bin/python /probe/emit.py"
EMPULL="Never"
if ! gate::run OTLP.emitter-image -- sh -c "docker build -q --target build -f '$GATE_REPO_ROOT/docker/Dockerfile.supervisor' -t '$EMIMG' '$GATE_REPO_ROOT/agents' && ${KIND:-kind} load docker-image '$EMIMG' --name '${CLUSTER_NAME}'" >/dev/null 2>&1; then
  log::warn "OTLP: locked emitter image build/load failed; falling back to installing ioa-observe-sdk==${SDK_VER} in the Pod"
  EMIMG="$PYIMG"; EMPULL="IfNotPresent"
  EMCMD="pip install --no-cache-dir --quiet --retries 10 --timeout 60 'ioa-observe-sdk==${SDK_VER}' && python /probe/emit.py"
fi

MF="$(gate::manifest otlp-shape.yaml)"
cat >"$MF" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels: {${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}", agentic-netops.io/owned-by: "${CLUSTER_NAME}"}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: vt-scratch-otel, namespace: ${NS}, labels: {${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}"}}
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc: {endpoint: 0.0.0.0:4317}
          http: {endpoint: 0.0.0.0:4318}
    exporters:
      debug: {verbosity: detailed}
    extensions:
      health_check: {endpoint: 0.0.0.0:13133}
    service:
      extensions: [health_check]
      pipelines:
        traces: {receivers: [otlp], exporters: [debug]}
        metrics: {receivers: [otlp], exporters: [debug]}
---
apiVersion: v1
kind: Service
metadata: {name: vt-scratch-otel, namespace: ${NS}, labels: {${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}"}}
spec:
  selector: {app: vt-scratch-otel}
  ports: [{name: grpc, port: 4317}, {name: http, port: 4318}]
---
apiVersion: v1
kind: Pod
metadata: {name: vt-scratch-otel, namespace: ${NS}, labels: {app: vt-scratch-otel, ${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}"}}
spec:
  restartPolicy: Never
  containers:
  - name: otelcol
    image: ${OIMG}
    args: ["--config=/etc/otelcol/config.yaml"]
    readinessProbe: {httpGet: {path: /, port: 13133}, periodSeconds: 3}
    volumeMounts: [{name: cfg, mountPath: /etc/otelcol}]
  volumes: [{name: cfg, configMap: {name: vt-scratch-otel}}]
---
apiVersion: v1
kind: ConfigMap
metadata: {name: vt-scratch-emitter, namespace: ${NS}, labels: {${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}"}}
data:
  emit.py: |
    import time
    from ioa_observe.sdk import Observe
    from ioa_observe.sdk.decorators import agent
    from opentelemetry import metrics, trace
    Observe.init("vt-scratch-otlp-shape", api_endpoint="http://vt-scratch-otel.${NS}.svc:4318",
                 telemetry_enabled=False)
    @agent(name="vt-scratch-agent")
    def probe():
        return "ok"
    probe()
    metrics.get_meter("vt-scratch-otlp-shape").create_counter("vt_scratch_probe").add(1, {"probe": "otlp-shape"})
    time.sleep(2)
    for p in (trace.get_tracer_provider(), metrics.get_meter_provider()):
        f = getattr(p, "force_flush", None)
        if f:
            f()
    time.sleep(3)
    print("EMITTED")
YAML
cat >"$(gate::manifest otlp-emitter.yaml)" <<YAML
apiVersion: v1
kind: Pod
metadata: {name: vt-scratch-emitter, namespace: ${NS}, labels: {app: vt-scratch-emitter, ${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}"}}
spec:
  restartPolicy: Never
  containers:
  - name: emitter
    image: ${EMIMG}
    imagePullPolicy: ${EMPULL}
    command: ["sh", "-c", "${EMCMD}"]
    env: [{name: OBSERVE_TELEMETRY, value: "false"}]
    volumeMounts: [{name: app, mountPath: /probe}]
  volumes: [{name: app, configMap: {name: vt-scratch-emitter}}]
YAML

status=pass; reason=""
gate::run OTLP.apply --attach gate/manifests/otlp-shape.yaml -- lab::kubectl apply -f "$MF" >/dev/null || { status=fail; reason="apply failed"; }
gate::run OTLP.collector-ready -- lab::kubectl -n "$NS" wait --for=condition=Ready pod/vt-scratch-otel --timeout=180s >/dev/null || { status=fail; reason="collector not Ready"; }
# The emitter installs the pinned SDK from the package index; a stalled download is a transient
# of the index, not an observation of the shape, so the Pod is replaced once, with its describe
# and log captured first (tierup7: the only failed item of an otherwise passing gate).
emitted=false
for attempt in 1 2; do
  sfx=""; [[ $attempt -eq 1 ]] || sfx=".retry"
  gate::run "OTLP.emitter$sfx" --attach gate/manifests/otlp-emitter.yaml -- lab::kubectl apply -f "$(gate::manifest otlp-emitter.yaml)" >/dev/null || { reason="emitter apply failed"; break; }
  if gate::run "OTLP.emitter-done$sfx" -- lab::kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/vt-scratch-emitter --timeout=420s >/dev/null; then
    emitted=true
  fi
  gate::run "OTLP.emitter-logs$sfx" -- lab::kubectl -n "$NS" logs vt-scratch-emitter --tail=100 >/dev/null 2>&1 || true
  [[ "$emitted" == true ]] && break
  gate::run "OTLP.emitter-describe$sfx" -- lab::kubectl -n "$NS" describe pod vt-scratch-emitter >/dev/null 2>&1 || true
  [[ $attempt -eq 2 ]] || lab::kubectl -n "$NS" delete pod vt-scratch-emitter --wait=true --timeout=120s >/dev/null 2>&1 || true
done
[[ "$emitted" == true ]] || { status=fail; reason="${reason:+$reason; }emitter did not complete in two attempts"; }
sleep 5
DBG="$EVIDENCE_DIR/gate/observed/otlp-collector-debug.txt"
gate::run OTLP.collector-debug -- lab::kubectl -n "$NS" logs vt-scratch-otel >"$DBG" 2>/dev/null || true

shape="$(python3 - "$DBG" <<'PY'
import json, re, sys
res_keys, service = set(), set()
spans, metrics = {}, {}
section, cur = None, None
attr = re.compile(r'^\s*->\s*([^:]+):\s*(\w+)\((.*)\)\s*$')
for line in open(sys.argv[1], errors="replace"):
    line = line.rstrip("\n")
    s = line.strip()
    if s.startswith("Resource attributes:"):
        section, cur = "resource", None; continue
    if re.match(r"^Span #\d+", s):
        section, cur = "span", {"attributes": set()}; continue
    if re.match(r"^Metric #\d+", s):
        section, cur = "metric", {"attributes": set()}; continue
    if s.startswith("Attributes:") and section == "span":
        section = "span-attrs"; continue
    if s.startswith("Data point attributes:") and section in ("metric", "metric-dp"):
        section = "metric-dp"; continue
    if section == "span" or section == "span-attrs":
        m = re.match(r"^(Name|Kind)\s*:\s*(.*)$", s)
        if m and cur is not None:
            cur[m.group(1).lower()] = m.group(2)
            if m.group(1) == "Name":
                spans.setdefault(m.group(2), {"kind": None, "attribute_keys": set()})
                cur["_n"] = m.group(2)
            if m.group(1) == "Kind" and cur.get("_n"):
                spans[cur["_n"]]["kind"] = m.group(2)
        a = attr.match(line)
        if a and section == "span-attrs" and cur and cur.get("_n"):
            spans[cur["_n"]]["attribute_keys"].add(f"{a.group(1).strip()}:{a.group(2)}")
    elif section == "resource":
        a = attr.match(line)
        if a:
            res_keys.add(f"{a.group(1).strip()}:{a.group(2)}")
            if a.group(1).strip() == "service.name":
                service.add(a.group(3))
    elif section in ("metric", "metric-dp"):
        a = attr.match(line)
        m = re.match(r"^->\s*(Name|DataType):\s*(.*)$", s)
        if m and cur is not None:
            if m.group(1) == "Name":
                cur["_n"] = m.group(2); metrics.setdefault(m.group(2), {"type": None, "attribute_keys": set()})
            else:
                if cur.get("_n"): metrics.setdefault(cur["_n"], {"type": None, "attribute_keys": set()})["type"] = m.group(2)
            continue
        if section == "metric-dp" and a and cur and cur.get("_n"):
            metrics.setdefault(cur["_n"], {"type": None, "attribute_keys": set()})["attribute_keys"].add(f"{a.group(1).strip()}:{a.group(2)}")
out = {"resource_attribute_keys": sorted(res_keys), "service_names": sorted(service),
       "spans": [{"name": n, "kind": v["kind"], "attribute_keys": sorted(v["attribute_keys"])} for n, v in sorted(spans.items())],
       "metrics": [{"name": n, "type": v["type"], "attribute_keys": sorted(v["attribute_keys"])} for n, v in sorted(metrics.items())]}
print(json.dumps(out))
PY
)" || shape='{"resource_attribute_keys":[],"spans":[],"metrics":[]}'
jq -e '(.spans | length) > 0 and (.metrics | length) > 0' <<<"$shape" >/dev/null || { status=fail; reason="${reason:+$reason; }no span or no metric reached the debug exporter"; }

gate::run OTLP.teardown -- lab::kubectl delete namespace "$NS" --wait=true --timeout=180s >/dev/null 2>&1 || true
removed=false; gate::wait_ns_gone "$NS" 180 >/dev/null 2>&1 && removed=true
[[ "$removed" == true ]] || { status=fail; reason="${reason:+$reason; }scratch namespace $NS not removed"; }

jq -n --arg s "$status" --arg r "$reason" --argjson shape "$shape" --arg sdk "$SDK_VER" --arg o "$OIMG" --arg py "$PYIMG" --arg em "$EMIMG" --argjson rm "$removed" '
  {name: "otlp_shape", status: $s, reason: (if $r == "" then null else $r end),
   sdk: {package: "ioa-observe-sdk", version: $sdk}, collector_image: $o, emitter_base_image: $py, emitter_image: $em,
   shape: $shape, scratch_namespace_removed: $rm}' >"$OUT"
log::info "[OTLP] status=$status spans=$(jq '.spans | length' <<<"$shape") metrics=$(jq '.metrics | length' <<<"$shape") removed=$removed"
[[ "$status" == pass ]]
