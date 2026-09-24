#!/usr/bin/env bash
# tests/unit/observability/manifests_test.sh — the device metric pipeline and metrics store
# manifests (T129, T130; FR-089, CR-005, FR-019, AD-55, AD-66, D-37; data-model.md §21). Offline
# except the collector configuration check, which runs the pinned collector image's `validate`.
#
# Proves, one behaviour per check:
#   - every image of deploy/observability/{gnmic,otel-collector,prometheus} is by digest and equals
#     the lock file's pinned reference (read from versions.lock.yaml, never retyped here);
#   - gNMIc's otlp output, as scripts/lib/device_metrics.sh renders it, carries exactly the
#     naming-relevant settings G7 recorded (tests/gate/observed/telemetry-series.json
#     settings.gnmic_otlp_output; the event-processor NAMES excepted — the gate's scratch names);
#   - the collector's Prometheus exporter carries G7's settings.collector_prometheus_exporter (and
#     the read-back's metric_expiration 20s, send_timestamps true);
#   - the collector's metric filter admits the tier prefix of data-model.md §21 and the device
#     prefix as LITERAL HasPrefix strings (never a regex, never an inherited pattern — AD-66);
#     traces are accepted; its own telemetry is on :8888 (port telemetry, Service port 8888);
#   - tier spans (T136): traces/tier keeps only resource service.namespace == agentic-netops-agents
#     and feeds the spanmetrics connector (namespace agentic_netops_agent_spans, exemplars on, the
#     stage/worker/model/outcome dimensions), whose metrics/spans pipeline leaves through its own
#     prometheus/spans exporter on :8890 in OpenMetrics (container and Service port `spans`);
#   - the collector configuration validates with the pinned image;
#   - gNMIc: the CA of monitoring/srl-credentials mounted read-only at /etc/gnmic-tls/ca.crt, the
#     rendered configuration's tls-ca is that file and its api-server is :7890 with metrics, the
#     container port `metrics` 7890 and Service gnmic-self → metrics;
#   - Prometheus: `kubectl kustomize deploy/observability/prometheus` has NO rules ConfigMap, the
#     rules/ kustomization produces prometheus-rules with the four rule files and nothing else, the
#     Deployment mounts it optional, runs --web.enable-lifecycle as non-root; prometheus.yml has
#     the eight jobs and the devices interface-name normalization; tier-spans scrapes :8890 preferring
#     OpenMetrics with --enable-feature=exemplar-storage, agent-otel-collector discovers the tier
#     collector by DNS A record on :8888 (zero targets while the tier is absent);
#   - no credential literal in any of these manifests (credentials come from secretKeyRef / Secret
#     volumes only).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OBS="$ROOT/deploy/observability"
LOCK="$ROOT/versions.lock.yaml"
SERIES_JSON="$ROOT/tests/gate/observed/telemetry-series.json"
RT="${CONTAINER_RUNTIME:-docker}"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }
for t in kubectl yq jq; do command -v "$t" >/dev/null 2>&1 || { echo "FAIL manifests_test: $t is required"; exit 1; }; done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 755 "$TMP"
build() { kubectl kustomize "$1" 2>&1; }

gnmic="$(build "$OBS/gnmic")" || { fail "kustomize gnmic" "$gnmic"; gnmic=""; }
otel="$(build "$OBS/otel-collector")" || { fail "kustomize otel-collector" "$otel"; otel=""; }
prom="$(build "$OBS/prometheus")" || { fail "kustomize prometheus" "$prom"; prom=""; }
rules="$(build "$OBS/prometheus/rules")" || { fail "kustomize prometheus/rules" "$rules"; rules=""; }
render="$(bash "$ROOT/scripts/lib/device_metrics.sh" render 172.25.25.0/24 2>&1)" || { fail "device_metrics.sh render" "$render"; render=""; }
gcfg="$(yq -r '.data["gnmic.yaml"]' <<<"$render")"
ocfg="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "device-metrics-otel") | .data["config.yaml"]' <<<"$otel")"

# 1. images by digest, equal to the lock file
check_images() {  # check_images <label> <built> <lock path>
  local want got
  want="$(yq -r "$3" "$LOCK")"
  got="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[].image' <<<"$2" | sort -u)"
  if [[ "$want" =~ @sha256:[0-9a-f]{64}$ && "$got" == "$want" ]]; then
    pass "$1 image by digest = versions.lock.yaml $3"
  else
    fail "$1 image is not the lock file's pinned digest reference" "want: $want"$'\n'"got:  $got"
  fi
}
check_images gnmic "$gnmic" .compatibilitySet.gnmic.image.pinned
check_images otel-collector "$otel" .observability.otelCollector.pinned
check_images prometheus "$prom" .observability.prometheus.pinned

# 2. gNMIc otlp output = G7's recorded naming-relevant settings (event-processor names excepted)
if [[ -f "$SERIES_JSON" ]]; then
  diffs="$(jq -r '.settings.gnmic_otlp_output | del(.["event-processors"]) | to_entries[] | "\(.key)\t\(.value | tojson)"' "$SERIES_JSON" \
    | while IFS=$'\t' read -r k v; do
        g="$(yq -o=json -I=0 ".outputs[] | select(.type == \"otlp\") | .[\"$k\"]" <<<"$gcfg")"
        [[ "$(jq -c . <<<"$g")" == "$(jq -c . <<<"$v")" ]] || echo "$k: recorded $v, rendered $g"
      done)"
  n="$(yq '[.outputs[] | select(.type == "otlp")] | length' <<<"$gcfg")"
  [[ "$n" == 1 && -z "$diffs" ]] && pass "gNMIc's one otlp output carries G7's recorded settings (telemetry-series.json settings.gnmic_otlp_output)" \
    || fail "gNMIc otlp output differs from G7's recorded settings (otlp outputs: $n)" "$diffs"
  diffs="$(jq -r '.settings.collector_prometheus_exporter | to_entries[] | "\(.key)\t\(.value | tojson)"' "$SERIES_JSON" \
    | while IFS=$'\t' read -r k v; do
        g="$(yq -o=json -I=0 ".exporters.prometheus[\"$k\"]" <<<"$ocfg")"
        [[ "$(jq -c . <<<"$g")" == "$(jq -c . <<<"$v")" ]] || echo "$k: recorded $v, configured $g"
      done)"
  [[ -z "$diffs" ]] && pass "collector Prometheus exporter carries G7's recorded settings (translation_strategy)" \
    || fail "collector Prometheus exporter differs from G7's recorded settings" "$diffs"
else
  echo "NOT RUN G7 settings comparison: $SERIES_JSON is absent (series names not yet observed)"
fi
[[ "$(yq -r '.exporters.prometheus.metric_expiration' <<<"$ocfg")" == 20s && "$(yq -r '.exporters.prometheus.send_timestamps' <<<"$ocfg")" == true ]] \
  && pass "collector exporter keeps metric_expiration 20s and send_timestamps true (the read-back's freshness bound)" \
  || fail "collector exporter metric_expiration / send_timestamps changed" "$(yq '.exporters.prometheus' <<<"$ocfg")"

# 3. the filter: literal prefixes, no pattern
prefix="$(grep -oE '`agentic_netops_agent_`' "$ROOT/specs/004-agentic-netops-composite/data-model.md" | head -1 | tr -d '`')"
conds="$(yq -r '.processors[] | select(has("metrics")) | .metrics.metric[]' <<<"$ocfg")"
if [[ "$prefix" == agentic_netops_agent_ ]] \
  && grep -qF "HasPrefix(name, \"$prefix\")" <<<"$conds" && grep -qF 'HasPrefix(name, "srl_nokia_")' <<<"$conds" \
  && ! grep -qE 'IsMatch|regexp|match_type|\.\*|\^' <<<"$conds"; then
  pass "collector filter admits the literal prefixes '$prefix' (data-model.md §21) and 'srl_nokia_' — HasPrefix, no pattern"
else
  fail "collector filter is not the two literal HasPrefix prefixes" "prefix in §21: '$prefix'"$'\n'"$conds"
fi
pipes="$(yq -o=json -I=0 '.service.pipelines' <<<"$ocfg")"
if jq -e '.metrics.processors == ["filter/tier-and-device"] and .metrics.receivers == ["otlp"] and .metrics.exporters == ["prometheus"] and .traces.receivers == ["otlp"]' <<<"$pipes" >/dev/null \
  && [[ "$(yq -r '.processors | keys | .[]' <<<"$ocfg" | tr '\n' ' ')" == "filter/tier-and-device filter/tier-spans " ]]; then
  pass "metrics pipeline otlp → filter → prometheus; traces pipeline accepts OTLP"
else
  fail "collector pipelines" "$pipes"
fi
tport="$(yq -r '.service.telemetry.metrics.readers[0].pull.exporter.prometheus.port' <<<"$ocfg")"
sport="$(yq -r 'select(.kind == "Service" and .metadata.name == "device-metrics") | .spec.ports[] | select(.name == "telemetry") | .port' <<<"$otel")"
cport="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[].ports[] | select(.name == "telemetry") | .containerPort' <<<"$otel")"
lvl="$(yq -r '.service.telemetry.metrics.level' <<<"$ocfg")"
[[ "$tport" == 8888 && "$sport" == 8888 && "$cport" == 8888 && "$lvl" == detailed ]] \
  && pass "collector self telemetry pulled on :8888 (level detailed), container and Service port 'telemetry'" \
  || fail "collector self telemetry" "reader $tport, service $sport, container $cport, level $lvl"

# 3b. tier spans → spanmetrics → prometheus/spans :8890 (T136)
tspan="$(yq -r '.processors["filter/tier-spans"].traces.span[]' <<<"$ocfg")"
sm="$(yq -o=json -I=0 '.connectors.spanmetrics' <<<"$ocfg")"
pspans="$(yq -o=json -I=0 '.exporters["prometheus/spans"]' <<<"$ocfg")"
s8890="$(yq -r 'select(.kind == "Service" and .metadata.name == "device-metrics") | .spec.ports[] | select(.name == "spans") | .port' <<<"$otel")"
c8890="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[].ports[] | select(.name == "spans") | .containerPort' <<<"$otel")"
if [[ "$tspan" == 'resource.attributes["service.namespace"] != "agentic-netops-agents"' ]] \
  && jq -e '.namespace == "agentic_netops_agent_spans" and .exemplars.enabled == true
      and ([.dimensions[].name] == ["agentic_netops.stage", "agentic_netops.worker", "gen_ai.request.model", "agentic_netops.outcome"])' <<<"$sm" >/dev/null \
  && jq -e '.endpoint == "0.0.0.0:8890" and .enable_open_metrics == true' <<<"$pspans" >/dev/null \
  && jq -e '.["traces/tier"] == {"receivers": ["otlp"], "processors": ["filter/tier-spans"], "exporters": ["spanmetrics"]}
      and .["metrics/spans"] == {"receivers": ["spanmetrics"], "exporters": ["prometheus/spans"]}' <<<"$pipes" >/dev/null \
  && [[ "$s8890" == 8890 && "$c8890" == 8890 ]]; then
  pass "tier spans: traces/tier (service.namespace agentic-netops-agents) → spanmetrics (exemplars) → prometheus/spans :8890 OpenMetrics"
else
  fail "tier spans pipeline" "filter: $tspan"$'\n'"spanmetrics: $sm"$'\n'"prometheus/spans: $pspans"$'\n'"pipelines: $pipes"$'\n'"ports: service $s8890 container $c8890"
fi

# 4. the collector configuration validates with the pinned image
if command -v "$RT" >/dev/null 2>&1; then
  mkdir -p "$TMP/otel"; printf '%s\n' "$ocfg" >"$TMP/otel/config.yaml"; chmod 644 "$TMP/otel/config.yaml"
  out="$("$RT" run --rm --network none -v "$TMP/otel:/cfg:ro" "$(yq -r .observability.otelCollector.pinned "$LOCK")" validate --config=/cfg/config.yaml 2>&1)" \
    && pass "collector configuration validates with the pinned image" || fail "collector validate" "$out"
else
  fail "no container runtime '$RT' to validate the collector configuration"
fi

# 5. gNMIc: TLS CA mount, api-server, gnmic-self
dep="$(yq -o=json -I=0 'select(.kind == "Deployment")' <<<"$gnmic")"
if jq -e '.spec.template.spec as $s
    | ($s.volumes[] | select(.name == "tls") | .secret | .secretName == "srl-credentials" and .items == [{"key": "ca.crt", "path": "ca.crt"}])
      and ($s.containers[0].volumeMounts[] | select(.name == "tls") | .mountPath == "/etc/gnmic-tls" and .readOnly == true)
      and ([$s.containers[0].ports[] | select(.name == "metrics" and .containerPort == 7890)] | length == 1)
      and ([$s.containers[0].env[] | select(.value != null)] | length == 0)' <<<"$dep" >/dev/null; then
  pass "gNMIc mounts monitoring/srl-credentials ca.crt read-only at /etc/gnmic-tls/ca.crt, port metrics 7890, no literal env"
else
  fail "gNMIc TLS mount / metrics port" "$(jq '.spec.template.spec | {volumes, c: .containers[0] | {volumeMounts, ports, env}}' <<<"$dep")"
fi
svc="$(yq -o=json -I=0 'select(.kind == "Service" and .metadata.name == "gnmic-self")' <<<"$gnmic")"
jq -e '.metadata.namespace == "monitoring" and .spec.ports == [{"name": "metrics", "port": 7890, "targetPort": "metrics"}]
       and .spec.selector == {"app.kubernetes.io/name": "device-metrics-gnmic"}' <<<"$svc" >/dev/null \
  && pass "Service monitoring/gnmic-self :7890 → gNMIc port metrics" || fail "Service gnmic-self" "$svc"
tca="$(yq -r '.["tls-ca"] // ""' <<<"$gcfg")"; api="$(yq -o=json -I=0 '.["api-server"] // {}' <<<"$gcfg")"
if [[ "$tca" == /etc/gnmic-tls/ca.crt ]] && [[ "$(yq -r '.["skip-verify"] // false' <<<"$gcfg")" != true ]] \
  && jq -e '.address == ":7890" and .["enable-metrics"] == true' <<<"$api" >/dev/null; then
  pass "rendered gNMIc configuration: tls-ca /etc/gnmic-tls/ca.crt (verified, no skip-verify), api-server :7890 with metrics"
else
  fail "rendered gNMIc configuration does not match the Deployment's mount and gnmic-self (scripts/lib/device_metrics.sh, T128/T129)" \
    "tls-ca: '${tca}' skip-verify: $(yq -r '.["skip-verify"] // false' <<<"$gcfg") api-server: $api"
fi

# 6. Prometheus: install without rules, rules separately, optional mount, lifecycle, non-root
if ! yq -e 'select(.kind == "ConfigMap" and .metadata.name == "prometheus-rules")' <<<"$prom" >/dev/null 2>&1 \
  && [[ "$(yq -r 'select(.kind == "ConfigMap") | .metadata.name' <<<"$prom")" == prometheus-config ]]; then
  pass "kubectl kustomize deploy/observability/prometheus installs no rules (ConfigMap prometheus-config only)"
else
  fail "the Prometheus install carries a rules ConfigMap" "$(yq -r '.kind + "/" + .metadata.name' <<<"$prom")"
fi
rk="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "prometheus-rules" and .metadata.namespace == "monitoring") | .data | keys | .[]' <<<"$rules" | sort | tr '\n' ' ')"
[[ "$rk" == "fabric.yaml pipeline.yaml reconcile.yaml recording.yaml " && "$(yq -r '.kind' <<<"$rules" | sort -u)" == ConfigMap ]] \
  && pass "deploy/observability/prometheus/rules produces only monitoring/prometheus-rules {fabric,pipeline,reconcile,recording}.yaml" \
  || fail "rules kustomization" "$rk"
pdep="$(yq -o=json -I=0 'select(.kind == "Deployment" and .metadata.name == "prometheus")' <<<"$prom")"
if jq -e '.spec.template.spec as $s | $s.serviceAccountName == "prometheus" and $s.securityContext.runAsNonRoot == true
    and ([$s.volumes[] | select(.name == "rules") | .projected.sources[].configMap | select(.optional == true) | .name] | sort == ["prometheus-rules", "prometheus-topology-rules"])
    and ($s.containers[0].volumeMounts[] | select(.mountPath == "/etc/prometheus/rules")) != null
    and ($s.containers[0].args | index("--web.enable-lifecycle")) != null
    and ($s.containers[0].resources.limits.memory != null)' <<<"$pdep" >/dev/null; then
  pass "Prometheus Deployment: SA prometheus, non-root, alert + topology rules projected optional at /etc/prometheus/rules, --web.enable-lifecycle, resources"
else
  fail "Prometheus Deployment" "$pdep"
fi
pcfg="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "prometheus-config") | .data["prometheus.yml"]' <<<"$prom")"
jobs="$(yq -r '.scrape_configs[].job_name' <<<"$pcfg" | sort | tr '\n' ' ')"
[[ "$jobs" == "agent-otel-collector devices gnmic-self otel-collector prometheus sdc srl-provider tier-spans " ]] && pass "prometheus.yml scrape jobs: $jobs" || fail "scrape jobs" "$jobs"
tjobs="$(yq -o=json -I=0 '[.scrape_configs[] | select(.job_name == "tier-spans" or .job_name == "agent-otel-collector")]' <<<"$pcfg")"
if jq -e '(.[] | select(.job_name == "tier-spans") | .static_configs == [{"targets": ["device-metrics.monitoring.svc:8890"]}] and .scrape_protocols[0] == "OpenMetricsText1.0.0")
    and (.[] | select(.job_name == "agent-otel-collector") | .dns_sd_configs == [{"names": ["agent-otel-collector.agentic-netops-agents.svc"], "type": "A", "port": 8888, "refresh_interval": "30s"}] and (has("static_configs") | not))' <<<"$tjobs" >/dev/null \
  && jq -e '.spec.template.spec.containers[0].args | index("--enable-feature=exemplar-storage") != null' <<<"$pdep" >/dev/null; then
  pass "tier-spans :8890 OpenMetrics first with exemplar storage; agent-otel-collector by DNS A record :8888 (no static target)"
else
  fail "tier scrape jobs / exemplar storage" "$tjobs"
fi
relabel="$(yq -o=json -I=0 '.scrape_configs[] | select(.job_name == "devices") | .metric_relabel_configs[0]' <<<"$pcfg")"
jq -e '.source_labels == ["interface_name"] and .target_label == "interface_name" and .regex == "ethernet-(\\d+)/(\\d+)" and .replacement == "e${1}-${2}"' <<<"$relabel" >/dev/null \
  && [[ "$(yq -r '.rule_files[0]' <<<"$pcfg")" == '/etc/prometheus/rules/*.yaml' ]] \
  && pass "devices: interface_name ethernet-N/M → eN-M at scrape; rule_files /etc/prometheus/rules/*.yaml" \
  || fail "devices relabel / rule_files" "$relabel"
# the collector sends timestamps: the devices job must track their staleness, or a stopped source
# reads at its last value for the whole lookback (SC-037)
[[ "$(yq -r '.scrape_configs[] | select(.job_name == "devices") | .track_timestamps_staleness' <<<"$pcfg")" == true ]] \
  && pass "devices: track_timestamps_staleness: true (a stopped source goes stale, never read at its last value)" \
  || fail "devices track_timestamps_staleness" "$(yq -r '.scrape_configs[] | select(.job_name == "devices")' <<<"$pcfg")"
crole="$(yq -o=json -I=0 'select(.kind == "ClusterRole" and .metadata.name == "agentic-netops-prometheus-metrics-reader")' <<<"$prom")"
jq -e '.rules == [{"nonResourceURLs": ["/metrics"], "verbs": ["get"]}]' <<<"$crole" >/dev/null \
  && pass "ClusterRole grants only get on nonResourceURLs /metrics" || fail "ClusterRole" "$crole"
# the SDC controller's metrics-auth role: create on the two review resources, nothing else, bound to
# sdc-system/controller only
arole="$(yq -o=json -I=0 'select(.kind == "ClusterRole" and .metadata.name == "agentic-netops-sdc-metrics-auth")' <<<"$prom")"
abind="$(yq -o=json -I=0 'select(.kind == "ClusterRoleBinding" and .metadata.name == "agentic-netops-sdc-metrics-auth")' <<<"$prom")"
jq -e '.rules == [{"apiGroups": ["authentication.k8s.io"], "resources": ["tokenreviews"], "verbs": ["create"]},
                  {"apiGroups": ["authorization.k8s.io"], "resources": ["subjectaccessreviews"], "verbs": ["create"]}]' <<<"$arole" >/dev/null \
  && jq -e '.subjects == [{"kind": "ServiceAccount", "name": "controller", "namespace": "sdc-system"}]' <<<"$abind" >/dev/null \
  && pass "sdc metrics-auth ClusterRole: only create on tokenreviews/subjectaccessreviews, bound to sdc-system/controller" \
  || fail "sdc metrics-auth ClusterRole" "$arole $abind"

# 7. no credential literal
lit="$(printf '%s\n---\n' "$gnmic" "$otel" "$prom" "$rules" | grep -nEi '^\s*-?\s*"?[a-z_-]*(password|passwd|token|api[_-]?key|secret)"?\s*:\s*[^ {]' \
  | grep -vE 'secretName|secretKeyRef|credentials_file|_file:|automountServiceAccountToken' || true)"
[[ -z "$lit" ]] && pass "no credential literal in the gnmic, otel-collector and prometheus manifests" || fail "credential literal" "$lit"

echo "manifests_test: $fails failure(s)"
[ "$fails" -eq 0 ]
