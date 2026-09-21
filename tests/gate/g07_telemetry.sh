#!/usr/bin/env bash
# G7_UP is read by run_gate.sh's exit trap (SC2034).
# shellcheck disable=SC2034
# tests/gate/g07_telemetry.sh — G7: Subscribe in sample mode and an on-change probe within the
# server's path-per-request limit (36), and the series names the device-metric pipeline actually
# generates for the per-neighbour EVPN session state, the per-neighbour EVPN received-route counter
# and the bgp-evpn bgp-instance presence and evi — written with the naming-relevant settings they
# were observed under to the tracked tests/gate/observed/telemetry-series.json, where T130's
# EvpnRoutesLost guard takes its names from (T043; AD-31, AD-48, AD-50, AD-55).
#
# The pipeline is ObservabilityReady's and does not exist at GateReady, so the names are observed
# the way T166 observes the OTLP shape: a throwaway Pod pair of the PINNED gNMIc and collector
# images (versions.lock.yaml) in the gate-labelled scratch namespace vt-scratch-g07-telemetry.
# gNMIc subscribes on the leaves with the lab operator's credentials (a Secret created for the
# pair's lifetime from a 0600 file under /tmp — never argv, never the monitoring copy), its native
# `type: otlp` output feeding the collector's Prometheus exporter, which the script reads once
# through the API server's pod proxy. G8's scratch EVPN instances are in place (run_gate.sh orders
# it) so the bgp-evpn bgp-instance series exists to be named. The namespace is removed and its
# removal read back before the item reports.
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then exec bash "$GATE_HERE/run_gate.sh" --only G7 "$@"; fi
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"

G7_NS="vt-scratch-g07-telemetry"
G7_SUB_PATHS=(
  "/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/session-state"
  "/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=*]/received-routes"
  "/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=*]/oper-state"
  "/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/evi"
  "/network-instance[name=*]/protocols/bgp-evpn/bgp-instance[id=*]/oper-state"
)
# the series the guard needs, as regexes over the exported names
G7_REQUIRED_SERIES=("session_state$" "afi_safi_received_routes$" "bgp_evpn_bgp_instance_evi$")

# the naming-relevant settings (T129 ships these unchanged; T134 re-checks them live)
g07::otlp_output() {
  cat <<'YAML'
    type: otlp
    endpoint: vt-scratch-otel.vt-scratch-g07-telemetry.svc:4317
    protocol: grpc
    metric-prefix: ""
    append-subscription-name: false
    strip-leading-underscore: true
    strings-as-attributes: false
    counter-patterns: []
    event-processors: [vt-scratch-session-state-to-int, vt-scratch-oper-state-to-int]
YAML
}
g07::processors() {
  cat <<'YAML'
  vt-scratch-session-state-to-int:
    event-strings:
      value-names: [".*session-state$"]
      transforms:
        - replace: {apply-on: value, old: "^established$", new: "5"}
        - replace: {apply-on: value, old: "^openconfirm$", new: "4"}
        - replace: {apply-on: value, old: "^opensent$", new: "3"}
        - replace: {apply-on: value, old: "^active$", new: "2"}
        - replace: {apply-on: value, old: "^connect$", new: "1"}
        - replace: {apply-on: value, old: "^idle$", new: "0"}
  vt-scratch-oper-state-to-int:
    event-strings:
      value-names: [".*oper-state$"]
      transforms:
        - replace: {apply-on: value, old: "^up$", new: "1"}
        - replace: {apply-on: value, old: "^down$", new: "0"}
YAML
}
g07::prom_exporter() {
  cat <<'YAML'
    endpoint: 0.0.0.0:8889
    translation_strategy: UnderscoreEscapingWithoutSuffixes
YAML
}

g07::manifests() {
  local gimg oimg leaf targets=""
  gimg="$(gate::lock_image compatibilitySet.gnmic.image.pinned)"
  oimg="$(gate::lock_image observability.otelCollector.pinned)"
  for leaf in $(lab::leaves); do
    targets+="      ${leaf}: {address: \"$(lab::addr "$leaf"):${GNMI_PORT}\"}"$'\n'
  done
  local paths=""; local p
  for p in "${G7_SUB_PATHS[@]}"; do paths+="        - \"${p}\""$'\n'; done
  cat >"$(gate::manifest g07-pair.yaml)" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${G7_NS}
  labels: {${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}", agentic-netops.io/owned-by: "${CLUSTER_NAME}"}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: vt-scratch-gnmic, namespace: ${G7_NS}, labels: {${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}"}}
data:
  gnmic.yaml: |
    skip-verify: true
    encoding: json_ietf
    log: true
    targets:
${targets}    subscriptions:
      vt-scratch-evpn:
        mode: stream
        stream-mode: sample
        sample-interval: 10s
        paths:
${paths}    outputs:
      vt-scratch-otlp:
$(g07::otlp_output | sed 's/^/    /')
    processors:
$(g07::processors | sed 's/^/    /')
---
apiVersion: v1
kind: ConfigMap
metadata: {name: vt-scratch-otel, namespace: ${G7_NS}, labels: {${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}"}}
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc: {endpoint: 0.0.0.0:4317}
    exporters:
      prometheus:
$(g07::prom_exporter | sed 's/^/    /')
    extensions:
      health_check: {endpoint: 0.0.0.0:13133}
    service:
      extensions: [health_check]
      pipelines:
        metrics: {receivers: [otlp], exporters: [prometheus]}
---
apiVersion: v1
kind: Service
metadata: {name: vt-scratch-otel, namespace: ${G7_NS}, labels: {${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}"}}
spec:
  selector: {app: vt-scratch-otel}
  ports: [{name: otlp-grpc, port: 4317, targetPort: 4317}]
---
apiVersion: v1
kind: Pod
metadata: {name: vt-scratch-otel, namespace: ${G7_NS}, labels: {app: vt-scratch-otel, ${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}"}}
spec:
  restartPolicy: Never
  containers:
  - name: otelcol
    image: ${oimg}
    args: ["--config=/etc/otelcol/config.yaml"]
    ports: [{containerPort: 4317}, {containerPort: 8889}, {containerPort: 13133}]
    readinessProbe: {httpGet: {path: /, port: 13133}, periodSeconds: 3}
    volumeMounts: [{name: cfg, mountPath: /etc/otelcol}]
  volumes: [{name: cfg, configMap: {name: vt-scratch-otel}}]
YAML
  cat >"$(gate::manifest g07-gnmic-pod.yaml)" <<YAML
apiVersion: v1
kind: Pod
metadata: {name: vt-scratch-gnmic, namespace: ${G7_NS}, labels: {app: vt-scratch-gnmic, ${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}"}}
spec:
  restartPolicy: Never
  containers:
  - name: gnmic
    image: ${gimg}
    args: ["--config", "/etc/gnmic/gnmic.yaml", "subscribe"]
    envFrom: [{secretRef: {name: vt-scratch-device-credentials}}]
    volumeMounts: [{name: cfg, mountPath: /etc/gnmic}]
  volumes: [{name: cfg, configMap: {name: vt-scratch-gnmic}}]
YAML
}

# the credentials Secret, from a 0600 file outside the evidence (never argv, never evidence)
g07::secret() {
  local d f rc=0
  d="$(mktemp -d)"; chmod 700 "$d"; f="$d/secret.yaml"
  ( umask 077
    jq -n --arg ns "$G7_NS" --arg k "$LAB_GATE_LABEL_KEY" --arg v "$LAB_GATE_LABEL_VALUE" \
      --arg u "$SRL_USER" --arg p "$SRL_PASS" \
      '{apiVersion: "v1", kind: "Secret", type: "Opaque",
        metadata: {name: "vt-scratch-device-credentials", namespace: $ns, labels: {($k): $v}},
        stringData: {GNMIC_USERNAME: $u, GNMIC_PASSWORD: $p}}' >"$f" )
  gate::run "G07.secret" -- lab::kubectl apply -f "$f" >/dev/null || rc=$?
  rm -rf "$d"
  return "$rc"
}

g07::teardown() {
  lab::kubectl get namespace "$G7_NS" >/dev/null 2>&1 || { G7_UP=0; return 0; }
  local rc=0
  gate::run "G07.teardown" -- lab::kubectl delete namespace "$G7_NS" --wait=true --timeout=180s >/dev/null || rc=$?
  gate::wait_ns_gone "$G7_NS" 180 >/dev/null || rc=1
  G7_UP=0
  return "$rc"
}

# g07::names <metrics-text-file> — the observed series (names, label keys, the afi-safi values)
g07::names() {
  python3 - "$1" <<'PY'
import json, re, sys
want = {
  "evpn_session_state": r"_neighbor_session_state$",
  "evpn_received_routes": r"_neighbor_afi_safi_received_routes$",
  "evpn_family_oper_state": r"_neighbor_afi_safi_oper_state$",
  "bgp_evpn_instance_evi": r"_bgp_evpn_bgp_instance_evi$",
  "bgp_evpn_instance_oper_state": r"_bgp_evpn_bgp_instance_oper_state$",
}
series = {}
line_re = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{(.*)\})?\s')
lab_re = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"')
for line in open(sys.argv[1]):
    if line.startswith("#"):
        continue
    m = line_re.match(line)
    if not m:
        continue
    labels = dict(lab_re.findall(m.group(3) or ""))
    s = series.setdefault(m.group(1), {"labels": set(), "afi": set()})
    s["labels"].update(labels)
    for k, v in labels.items():
        if k.endswith("afi_safi_name"):
            s["afi"].add(v)
out = {}
for key, rx in want.items():
    names = sorted(n for n in series if re.search(rx, n))
    out[key] = [{"name": n, "labels": sorted(series[n]["labels"]),
                 **({"afi_safi_values": sorted(series[n]["afi"])} if series[n]["afi"] else {})} for n in names]
print(json.dumps({"series": out,
                  "all_series": sorted(n for n in series if n.startswith("network_instance_"))}))
PY
}

# read by run_gate.sh's exit trap (a pair still up is torn down)
# shellcheck disable=SC2034
G7_UP=0
g07::run() {
  gate::item_begin G7 "Subscribe sample + on-change, and the generated EVPN series names"
  local leaf rc sub_paths=() p
  leaf="$(lab::leaves | head -1)"
  # --- host-side Subscribe (sample, then on-change), within the 36-path limit
  for p in "${G7_SUB_PATHS[@]:0:2}"; do sub_paths+=("$p"); done
  rc=0; gate::ready "G07.sample" G7-sample subscribe_sample "$leaf" 30 "${sub_paths[@]}" || rc=$?
  gate::item_check "subscribe-sample" "$rc" "sample-mode Subscribe delivers repeated updates for the EVPN session paths"
  local sd="/interface[name=${SCRATCH_ACCESS_PORT}]/subinterface[index=${SCRATCH_VLAN}]/description"
  rc=0; gate::ready "G07.on-change" G7-onchange subscribe_onchange "$leaf" "$sd" "$sd" '"vt-scratch-g7-onchange"' "\"$SCRATCH_DESC\"" || rc=$?
  gate::item_check "subscribe-on-change" "$rc" "on-change Subscribe delivers an update after the leaf is disturbed"

  # --- the throwaway pair
  g07::manifests
  gate::run "G07.images" -- sh -c "grep -h 'image:' '$(gate::manifest g07-pair.yaml)' '$(gate::manifest g07-gnmic-pod.yaml)'" >/dev/null || true
  G7_UP=1
  rc=0
  gate::run "G07.apply-collector" --attach "gate/manifests/g07-pair.yaml" -- lab::kubectl apply -f "$(gate::manifest g07-pair.yaml)" >/dev/null || rc=$?
  [[ "$rc" -eq 0 ]] && { g07::secret || rc=$?; }
  [[ "$rc" -eq 0 ]] && { gate::run "G07.collector-ready" -- lab::kubectl -n "$G7_NS" wait --for=condition=Ready pod/vt-scratch-otel --timeout=180s >/dev/null || rc=$?; }
  gate::item_check "collector-up" "$rc" "pinned collector Pod Ready in $G7_NS"
  # negative control: before gNMIc runs, the required series are NOT exposed
  negctl::G7_no_series "$G7_NS"
  rc=0
  gate::run "G07.apply-gnmic" --attach "gate/manifests/g07-gnmic-pod.yaml" -- lab::kubectl apply -f "$(gate::manifest g07-gnmic-pod.yaml)" >/dev/null || rc=$?
  [[ "$rc" -eq 0 ]] && { gate::run "G07.gnmic-ready" -- lab::kubectl -n "$G7_NS" wait --for=condition=Ready pod/vt-scratch-gnmic --timeout=180s >/dev/null || rc=$?; }
  gate::item_check "gnmic-up" "$rc" "pinned gNMIc Pod Ready, subscribed to the leaves"
  rc=0; CHECK_WAIT=120 gate::ready "G07.series" G7-series otel_series "$G7_NS" vt-scratch-otel 8889 "${G7_REQUIRED_SERIES[@]}" || rc=$?
  gate::item_check "series-exposed" "$rc" "the collector exposes the session-state, received-routes and bgp-instance evi series"
  # read once, keep the raw exposition as evidence
  local mf="$EVIDENCE_DIR/gate/observed/g07-metrics.txt" names
  gate::run "G07.metrics" -- lab::kubectl get --raw "/api/v1/namespaces/${G7_NS}/pods/vt-scratch-otel:8889/proxy/metrics" >"$mf" 2>/dev/null || true
  gate::run "G07.gnmic-logs" -- lab::kubectl -n "$G7_NS" logs vt-scratch-gnmic --tail=200 >/dev/null 2>&1 || true
  names="$(g07::names "$mf" 2>/dev/null || echo '{"series":{},"all_series":[]}')"
  local obs
  obs="$(jq -n --argjson n "$names" \
    --arg gimg "$(gate::lock_image compatibilitySet.gnmic.image.pinned)" \
    --arg oimg "$(gate::lock_image observability.otelCollector.pinned)" \
    --argjson paths "$(printf '%s\n' "${G7_SUB_PATHS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
    --argjson out "$(g07::otlp_output | python3 -c 'import sys,yaml,json; print(json.dumps(yaml.safe_load(sys.stdin)))')" \
    --argjson procs "$(g07::processors | python3 -c 'import sys,yaml,json; print(json.dumps(yaml.safe_load(sys.stdin)))')" \
    --argjson prom "$(g07::prom_exporter | python3 -c 'import sys,yaml,json; print(json.dumps(yaml.safe_load(sys.stdin)))')" \
    '{schema: "agentic-netops.gate.telemetry-series/v1",
      observed_with: {gnmic_image: $gimg, collector_image: $oimg, subscription_paths: $paths,
                      subscription_mode: "stream/sample 10s", encoding: "json_ietf"},
      settings: {gnmic_otlp_output: ($out | del(.endpoint)), gnmic_event_processors: $procs,
                 collector_prometheus_exporter: ($prom | del(.endpoint))},
      series: $n.series, all_series: $n.all_series}')"
  rc=0; jq -e '.series.evpn_session_state | length > 0' <<<"$obs" >/dev/null && \
        jq -e '.series.evpn_received_routes | length > 0' <<<"$obs" >/dev/null && \
        jq -e '.series.bgp_evpn_instance_evi | length > 0' <<<"$obs" >/dev/null || rc=1
  gate::item_check "series-named" "$rc" "series names derived from the exposition: $(jq -c '[.series[] | .[].name]' <<<"$obs")" ""
  gate::observed telemetry-series.json "$obs" || gate::item_check "observed-file" 1 "telemetry-series.json refused"
  rc=0; g07::teardown || rc=$?
  gate::item_check "pair-removed" "$rc" "scratch namespace $G7_NS and its Pods removed, removal read back"
  gate::item_end
}
