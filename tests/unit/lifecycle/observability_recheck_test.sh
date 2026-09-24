#!/usr/bin/env bash
# observability_recheck_test.sh — the ObservabilityReady re-check against the gate's observation
# (T134; AD-55, AD-64, AD-50; FR-087, FR-089). Written before the phase, beside T044's
# g11_stop_test.sh, and driven the same way: scripts/provision.sh is SOURCED from a copy of the tree
# (its test hook defines the phases and runs nothing) and provision::phase_ObservabilityReady runs
# against a fake kubectl (tests/unit/lifecycle/obs_fake_kubectl) that records a call log and answers
# the installed Prometheus's query endpoint from a fixture series store. The generator step (T131
# observability::generate / install_assets), the device collector (T128 device_metrics::ensure) and
# the Grafana assets (T132) are stubs that record when they ran.
#
#   1  a series name of tests/gate/observed/telemetry-series.json the store does not hold →
#      non-zero, the output NAMES the series, the call log shows the alert rules never applied
#      (no apply of deploy/observability/prometheus/rules, no POST /-/reload)
#   2  a shipped naming-relevant setting that differs from the recorded one — gNMIc's otlp output
#      strip-leading-underscore false; the collector's translation_strategy — → non-zero NAMING the
#      setting, rules never applied; the event-processor NAMES are not compared
#   3  the bgp-evpn bgp-instance series absent while no service exists (no Network carrying a
#      bridge domain or a router) → reported "not yet observable", the phase goes on and applies
#      the rules; the same absence while a service exists → non-zero naming the series
#   4  negative control: every name present and every setting equal → the rules are applied, the
#      reload POSTed, and the ten rules waited for; the order is generate → device collector
#      (DEVICE_METRICS_TARGETS_FILE = the generated gnmic-targets.txt) → Prometheus without rules →
#      assets → Grafana → queries → rules
#   5  the series names come from the committed file; OBS_SERIES_FILE overrides it (fixtures), an
#      absent file stops the phase naming it; a query the store cannot answer stops it naming that
#   6  the ten alert rules not all listed by Prometheus in the bound → non-zero naming the missing one
#   7  PROVISION_PHASES orders ObservabilityReady right after FabricReady; AppsReady installs none of it
# Offline: no docker, no cluster; every wait is bounded by small values passed through the environment.
# shellcheck disable=SC2015,SC2317  # `cond && pass … || fail …` is safe (pass returns 0); the stubs are called by the phase
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SERIES_FILE="$ROOT/tests/gate/observed/telemetry-series.json"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 30 | sed 's/^/    /'; }

for tool in jq yq; do command -v "$tool" >/dev/null || { echo "FAIL prerequisite: $tool not on PATH"; exit 1; }; done
[[ -f "$SERIES_FILE" ]] || { echo "FAIL prerequisite: $SERIES_FILE is not committed"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TEN=(FabricLinkDown BGPSessionDown EvpnRoutesLost ReconciliationFailed ReverificationStalled
     DeviceTelemetryTargetDown DeviceSubscriptionStalled OtlpExportFailing OtlpDataPointsRejected DuplicateDeviceSeries)
mapfile -t ALL < <(jq -r '[(.all_series // [])[], ((.series // {})[][]?.name)] | unique[]' "$SERIES_FILE")
mapfile -t INSTANCE < <(jq -r '[(.series.bgp_evpn_instance_evi // [])[].name, (.series.bgp_evpn_instance_oper_state // [])[].name] | unique[]' "$SERIES_FILE")
SESSION="$(jq -r '.series.evpn_session_state[0].name' "$SERIES_FILE")"
[[ ${#ALL[@]} -ge 5 && ${#INSTANCE[@]} -eq 2 && -n "$SESSION" ]] || { echo "FAIL prerequisite: unexpected shape of $SERIES_FILE"; exit 1; }

# make_tree <dir> — the parts of the tree the phase reads, empty kustomizations for the stack
make_tree() {
  local t="$1" d
  mkdir -p "$t/scripts" "$t/tests/gate/observed" "$t/bin" "$t/state"
  cp -r "$ROOT/scripts/lib" "$t/scripts/lib"
  cp "$ROOT/scripts/provision.sh" "$t/scripts/provision.sh"
  cp "$SERIES_FILE" "$t/tests/gate/observed/"
  cp "$ROOT/versions.lock.yaml" "$t/"
  for d in deploy/observability/prometheus deploy/observability/prometheus/rules deploy/observability/grafana; do
    mkdir -p "$t/$d"
    printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n' >"$t/$d/kustomization.yaml"
  done
  cp "$HERE/obs_fake_kubectl" "$t/bin/kubectl"; chmod +x "$t/bin/kubectl"
  printf '%s\n' "${ALL[@]}" >"$t/state/series"
  printf '%s\n' "${TEN[@]}" >"$t/state/rule-names"
  # the shipped settings as recorded (processor names deliberately NOT the recorded ones)
  cat >"$t/state/gnmic.yaml" <<'YAML'
skip-verify: true
encoding: json_ietf
outputs:
  device-metrics:
    type: otlp
    endpoint: device-metrics.monitoring.svc:4317
    protocol: grpc
    metric-prefix: ""
    append-subscription-name: false
    strip-leading-underscore: true
    strings-as-attributes: false
    counter-patterns: []
    event-processors: [session-state-to-int, oper-state-to-int, state-as-int]
YAML
  cat >"$t/state/otel.yaml" <<'YAML'
receivers:
  otlp: {protocols: {grpc: {endpoint: 0.0.0.0:4317}}}
exporters:
  prometheus:
    endpoint: 0.0.0.0:8889
    translation_strategy: UnderscoreEscapingWithoutSuffixes
    metric_expiration: 20s
service:
  pipelines:
    metrics: {receivers: [otlp], exporters: [prometheus]}
YAML
  echo '{"items":[]}' >"$t/state/networks.json"
}

# net_json <kind:vlan|macvrf> — one Network of that shape
net_json() {
  case "$1" in
    vlan) echo '{"items":[{"metadata":{"namespace":"agentic-netops-services","name":"lab-vlan"},"spec":{"vlans":[{"name":"v10","vlan":10}],"attachments":[{"node":"leaf01","attachment":"ethernet-1/1","vlan":10}]}}]}' ;;
    macvrf) echo '{"items":[{"metadata":{"namespace":"agentic-netops-services","name":"lab-macvrf"},"spec":{"bridgeDomains":[{"name":"bd150","vlan":150,"l2vni":10150}],"attachments":[{"node":"leaf01","attachment":"ethernet-1/1","vlan":150}]}}]}' ;;
  esac
}

# run_phase <tree> — ObservabilityReady in a subshell; stdout+stderr to <tree>/out, rc returned
run_phase() {
  local t="$1"
  (
    cd "$t" || exit 99
    export PATH="$t/bin:$PATH" KUBECTL="$t/bin/kubectl" FAKE_OBS="$t/state"
    export EVIDENCE_DIR="$t/evidence" EVIDENCE_LAB=agentic-netops-fabric EVIDENCE_CLUSTER_UID=fake-uid
    export EVIDENCE_DEVICE_IMAGE_DIGEST=sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402
    export CLUSTER_NAME=agentic-netops PROVISION_WAIT_TIMEOUT=2 OBS_WAIT_TIMEOUT=2
    export OBS_RECHECK_TIMEOUT=1 OBS_RECHECK_INTERVAL=1 OBS_RULES_TIMEOUT=2 OBS_RULES_INTERVAL=1 OBS_RUN_DIR="$t/run"
    unset LOG_PHASE
    # shellcheck disable=SC1091
    source scripts/provision.sh
    provision::defaults
    evidence::ensure_dir
    # stubs of the other streams' steps (T131, T128, T132), recording when they ran
    observability::generate() { echo "stub observability::generate $1" >>"$FAKE_OBS/calls"; mkdir -p "$1"; printf 'leaf01 172.25.25.21:57400\n' >"$1/gnmic-targets.txt"; }
    observability::install_assets() { echo "stub observability::install_assets $1" >>"$FAKE_OBS/calls"; }
    device_metrics::ensure() { echo "stub device_metrics::ensure targets=${DEVICE_METRICS_TARGETS_FILE:-}" >>"$FAKE_OBS/calls"; }
    grafana_assets::ensure() { echo "stub grafana_assets::ensure" >>"$FAKE_OBS/calls"; }
    provision::phase_ObservabilityReady
  ) >"$t/out" 2>&1
}

rules_applied() { grep -E '^kubectl .*apply .*-k .*/deploy/observability/prometheus/rules( |$)' "$1/state/calls" 2>/dev/null || true; }
reloads() { grep -E '^kubectl .*create --raw .*/-/reload' "$1/state/calls" 2>/dev/null || true; }
no_rules() { # <tree> <label>
  if [[ -z "$(rules_applied "$1")$(reloads "$1")" ]]; then pass "$2: the call log shows the alert rules never applied (no rules apply, no reload)"
  else fail "$2: the alert rules were applied although the re-check failed" "$(rules_applied "$1"; reloads "$1")"; fi
}

# ------------------------------------------------------------------ 1: a series name absent
t="$TMP/absent-series"; make_tree "$t"
grep -vxF "$SESSION" "$t/state/series" >"$t/state/series.new"; mv "$t/state/series.new" "$t/state/series"
rc=0; run_phase "$t" || rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF "$SESSION" "$t/out" && grep -qiE "absent|not held|missing" "$t/out"; then
  pass "absent series: the phase stops non-zero ($rc) naming $SESSION"
else fail "absent series: expected non-zero naming $SESSION (rc=$rc)" "$(cat "$t/out")"; fi
no_rules "$t" "absent series"
if grep -lq '"exit_status": 1' "$t"/evidence/observability.recheck*.json 2>/dev/null; then
  pass "absent series: the re-check is run-captured (evidence observability.recheck, exit 1)"
else fail "absent series: no failing observability.recheck evidence record" "$(ls "$t/evidence" 2>&1)"; fi
grep -qE 'apply .*-k .*/deploy/observability/prometheus$' "$t/state/calls" \
  && pass "absent series: Prometheus was installed (without rules) before the re-check" \
  || fail "absent series: no apply of deploy/observability/prometheus" "$(cat "$t/state/calls")"

# ------------------------------------------------------------------ 2: a shipped setting differs
t="$TMP/setting-gnmic"; make_tree "$t"
yq -i '.outputs["device-metrics"]["strip-leading-underscore"] = false' "$t/state/gnmic.yaml"
rc=0; run_phase "$t" || rc=$?
if [[ "$rc" -ne 0 ]] && grep -qE 'strip-leading-underscore.*(false).*(true)|strip-leading-underscore.*differs' "$t/out"; then
  pass "gNMIc setting: the phase stops non-zero ($rc) naming strip-leading-underscore (live false, recorded true)"
else fail "gNMIc setting: expected non-zero naming strip-leading-underscore (rc=$rc)" "$(cat "$t/out")"; fi
no_rules "$t" "gNMIc setting"
if grep -qE 'event-processors|processor' <(grep -iE 'differ|mismatch' "$t/out"); then
  fail "gNMIc setting: event-processor names were compared (they are not naming-relevant)" "$(grep -iE 'differ|mismatch' "$t/out")"
else pass "gNMIc setting: the event-processor names (different from the recorded ones) are not compared"; fi

t="$TMP/setting-collector"; make_tree "$t"
yq -i '.exporters.prometheus.translation_strategy = "UnderscoreEscapingWithSuffixes"' "$t/state/otel.yaml"
rc=0; run_phase "$t" || rc=$?
if [[ "$rc" -ne 0 ]] && grep -qE 'translation_strategy.*UnderscoreEscapingWithSuffixes' "$t/out"; then
  pass "collector setting: the phase stops non-zero ($rc) naming translation_strategy"
else fail "collector setting: expected non-zero naming translation_strategy (rc=$rc)" "$(cat "$t/out")"; fi
no_rules "$t" "collector setting"

t="$TMP/setting-absent"; make_tree "$t"
yq -i 'del(.outputs["device-metrics"]["counter-patterns"])' "$t/state/gnmic.yaml"
rc=0; run_phase "$t" || rc=$?
[[ "$rc" -ne 0 ]] && grep -qF 'counter-patterns' "$t/out" \
  && pass "absent setting: a recorded key missing from the live output stops the phase naming counter-patterns" \
  || fail "absent setting: expected non-zero naming counter-patterns (rc=$rc)" "$(cat "$t/out")"
no_rules "$t" "absent setting"

# ------------------------------------------------------------------ 3: bgp-evpn instance, no service
t="$TMP/no-service"; make_tree "$t"
for n in "${INSTANCE[@]}"; do grep -vxF "$n" "$t/state/series" >"$t/state/s" ; mv "$t/state/s" "$t/state/series"; done
net_json vlan >"$t/state/networks.json"
rc=0; run_phase "$t" || rc=$?
if [[ "$rc" -eq 0 ]] && grep -qi 'not yet observable' "$t/out" && grep -qF "${INSTANCE[0]}" "$t/out"; then
  pass "no service: the absent bgp-evpn bgp-instance series is reported not yet observable and the phase goes on"
else fail "no service: expected rc 0 with 'not yet observable' naming ${INSTANCE[0]} (rc=$rc)" "$(cat "$t/out")"; fi
[[ -n "$(rules_applied "$t")" && -n "$(reloads "$t")" ]] \
  && pass "no service: the alert rules are applied and Prometheus reloaded" \
  || fail "no service: the rules were not applied" "$(cat "$t/state/calls")"
if grep -iE 'not yet observable' "$t/out" | grep -qF "$SESSION"; then fail "no service: a non-instance series was excused"; else pass "no service: only the bgp-evpn bgp-instance series are excused"; fi

t="$TMP/service-present"; make_tree "$t"
for n in "${INSTANCE[@]}"; do grep -vxF "$n" "$t/state/series" >"$t/state/s" ; mv "$t/state/s" "$t/state/series"; done
net_json macvrf >"$t/state/networks.json"
rc=0; run_phase "$t" || rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF "${INSTANCE[0]}" "$t/out" && ! grep -qi 'not yet observable' "$t/out"; then
  pass "service present: the absent bgp-evpn bgp-instance series is a mismatch, named (rc=$rc)"
else fail "service present: expected non-zero naming ${INSTANCE[0]} as absent (rc=$rc)" "$(cat "$t/out")"; fi
no_rules "$t" "service present"

# ------------------------------------------------------------------ 4: negative control
t="$TMP/healthy"; make_tree "$t"
rc=0; run_phase "$t" || rc=$?
[[ "$rc" -eq 0 ]] && pass "healthy: every name present and every setting equal → the phase completes" \
  || fail "healthy: the phase should pass (rc=$rc)" "$(cat "$t/out")"
[[ -n "$(rules_applied "$t")" && -n "$(reloads "$t")" ]] \
  && pass "healthy: the alert rules are applied (deploy/observability/prometheus/rules) and POST /-/reload issued" \
  || fail "healthy: the rules were not applied" "$(cat "$t/state/calls")"
grep -qE 'proxy/api/v1/rules' "$t/state/calls" && pass "healthy: the ten rules are read back from /api/v1/rules" \
  || fail "healthy: /api/v1/rules never read"
for n in "${ALL[@]}"; do
  grep -qF "$(jq -rn --arg n "$n" '"count({__name__=\"" + $n + "\"})" | @uri')" "$t/state/calls" || { fail "healthy: $n was never queried"; continue; }
done
pass "healthy: every series name of the committed file was queried from the installed Prometheus"
order="$(awk '
  /^stub observability::generate/ {print "generate"}
  /^stub device_metrics::ensure/ {print "device-metrics"}
  /apply .*-k .*\/deploy\/observability\/prometheus$/ {print "prometheus"}
  /^stub observability::install_assets/ {print "assets"}
  /^stub grafana_assets::ensure/ {print "grafana-assets"}
  /apply .*-k .*\/deploy\/observability\/grafana$/ {print "grafana"}
  /proxy\/api\/v1\/query/ && !q {print "query"; q=1}
  /apply .*-k .*\/deploy\/observability\/prometheus\/rules$/ {print "rules"}
  /create --raw .*\/-\/reload/ && !r {print "reload"; r=1}' "$t/state/calls" | paste -sd' ')"
[[ "$order" == "generate device-metrics prometheus assets grafana-assets grafana query rules reload" ]] \
  && pass "healthy: order generate → device collector → Prometheus (no rules) → assets → Grafana → re-check → rules → reload" \
  || fail "healthy: unexpected order: $order" "$(cat "$t/state/calls")"
grep -qxF "stub device_metrics::ensure targets=$t/run/gnmic-targets.txt" "$t/state/calls" \
  && pass "healthy: the device collector is re-rendered from the generated gnmic-targets.txt (same inventory, same step)" \
  || fail "healthy: DEVICE_METRICS_TARGETS_FILE not the generated target list" "$(grep '^stub device_metrics' "$t/state/calls")"
ls "$t"/evidence/observability.rules-loaded*.json >/dev/null 2>&1 \
  && pass "healthy: the loaded rules are run-captured (observability.rules-loaded)" || fail "healthy: no observability.rules-loaded evidence"

# ------------------------------------------------------------------ 5: the file: override, absent, query failure
t="$TMP/override"; make_tree "$t"
jq '.all_series += ["vt_scratch_fixture_only_series"]' "$SERIES_FILE" >"$t/fixture-series.json"
rc=0; OBS_SERIES_FILE="$t/fixture-series.json" run_phase "$t" || rc=$?
[[ "$rc" -ne 0 ]] && grep -qF vt_scratch_fixture_only_series "$t/out" \
  && pass "override: OBS_SERIES_FILE is read instead of the committed file (its extra name is absent, named)" \
  || fail "override: expected non-zero naming vt_scratch_fixture_only_series (rc=$rc)" "$(cat "$t/out")"
no_rules "$t" "override"

t="$TMP/no-file"; make_tree "$t"; rm -f "$t/tests/gate/observed/telemetry-series.json"
rc=0; run_phase "$t" || rc=$?
[[ "$rc" -ne 0 ]] && grep -qF 'telemetry-series.json' "$t/out" \
  && pass "no file: the phase stops naming tests/gate/observed/telemetry-series.json" \
  || fail "no file: expected non-zero naming the file (rc=$rc)" "$(cat "$t/out")"
no_rules "$t" "no file"

t="$TMP/query-fail"; make_tree "$t"; touch "$t/state/query-fail"
rc=0; run_phase "$t" || rc=$?
[[ "$rc" -ne 0 ]] && grep -qiE 'could not (be )?quer' "$t/out" \
  && pass "query failure: a series Prometheus cannot answer for stops the phase (never read as present)" \
  || fail "query failure: expected non-zero naming the failed query (rc=$rc)" "$(cat "$t/out")"
no_rules "$t" "query failure"

# ------------------------------------------------------------------ 6: the ten rules not all loaded
t="$TMP/nine-rules"; make_tree "$t"
grep -vxF OtlpDataPointsRejected "$t/state/rule-names" >"$t/state/r"; mv "$t/state/r" "$t/state/rule-names"
rc=0; run_phase "$t" || rc=$?
[[ "$rc" -ne 0 ]] && grep -qF OtlpDataPointsRejected "$t/out" \
  && pass "nine rules: the bounded wait for the ten rules fails naming OtlpDataPointsRejected" \
  || fail "nine rules: expected non-zero naming OtlpDataPointsRejected (rc=$rc)" "$(cat "$t/out")"

# ------------------------------------------------------------------ 7: phase order in provision.sh
phases="$(cd "$ROOT" && bash -c 'source scripts/provision.sh; printf "%s " "${PROVISION_PHASES[@]}"')"
[[ "$phases" == *"FabricReady ObservabilityReady "* && "$phases" != *IntentTierReady* ]] \
  && pass "PROVISION_PHASES: ObservabilityReady right after FabricReady, before the --with-intent-tier phase ($phases)" \
  || fail "PROVISION_PHASES: $phases"
if sed -n '/^provision::phase_AppsReady()/,/^}/p' "$ROOT/scripts/provision.sh" | grep -qiE 'observability|monitoring|prometheus|grafana'; then
  fail "AppsReady mentions the observability stack (it is ObservabilityReady's, AD-50)"
else pass "AppsReady installs nothing of the observability stack (AD-50)"; fi

echo "observability_recheck_test: $fails failure(s)"
[[ "$fails" -eq 0 ]]
