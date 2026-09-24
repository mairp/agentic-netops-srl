#!/usr/bin/env bash
# tests/unit/alerts/rules_test.sh — the alert rules' unit test (T130; FR-087, FR-100, FR-107,
# AD-48, AD-55, AD-59; data-model.md §21 "the required alert set"). Written before the rules.
#
# `promtool test rules` from the PINNED Prometheus image itself (docker run --entrypoint promtool at
# the digest of versions.lock.yaml observability.prometheus.pinned — read from the lock file, never
# retyped), over the synthetic series of rules_test.yaml. Needs no lab: a container runtime and that
# one image. Proves, one behaviour per check:
#   - the rule files are valid (promtool check rules) and prometheus.yml is (check config);
#   - the rule set is EXACTLY the ten alerts of §21, in fabric/reconcile/pipeline.yaml as §21 and
#     T130 place them, each with labels.severity (critical|warning), annotations.summary and
#     annotations.next (what to look at next — FR-087);
#   - the EVPN guard's series names in rules/fabric.yaml are EXACTLY those of the committed
#     tests/gate/observed/telemetry-series.json (every srl_nokia_network_instance name the file uses
#     is a recorded one, and all three recorded guard names are used) — AD-55;
#   - rules_test.yaml, its placeholders filled from that same file, passes: every one of the ten
#     rules fires on its signature and clears when it ends, and the no-fire cases (see its header);
#   - every alert is covered by rules_test.yaml with a firing AND a silent evaluation;
#   - negative controls: the same tests FAIL against empty rule files, and against an EvpnRoutesLost
#     with its evi guard removed (the guard is what the no-fire cases prove).
#
# While tests/gate/observed/telemetry-series.json does not exist yet (the gate has not observed the
# series names — T043), it prints "not run: series names not yet observed" and exits 77, which
# scripts/ci/test_shell.sh reports as NOT RUN, named in its summary and never counted as a pass.
#
# env: TELEMETRY_SERIES_JSON (default tests/gate/observed/telemetry-series.json), CONTAINER_RUNTIME
#      (default docker)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RULES="$ROOT/deploy/observability/prometheus/rules"
PROMCFG="$ROOT/deploy/observability/prometheus/prometheus.yml"
SERIES_JSON="${TELEMETRY_SERIES_JSON:-$ROOT/tests/gate/observed/telemetry-series.json}"
RT="${CONTAINER_RUNTIME:-docker}"

if [[ ! -f "$SERIES_JSON" ]]; then
  echo "rules_test: not run: series names not yet observed ($SERIES_JSON is absent — T043's G7 writes it)"
  exit 77
fi

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

command -v "$RT" >/dev/null 2>&1 || { echo "FAIL rules_test: no container runtime '$RT' (the suite runs promtool from the pinned image)"; exit 1; }
for t in yq jq python3; do command -v "$t" >/dev/null 2>&1 || { echo "FAIL rules_test: $t is required"; exit 1; }; done

IMAGE="$(yq -r '.observability.prometheus.pinned' "$ROOT/versions.lock.yaml")"
[[ "$IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] || { echo "FAIL rules_test: observability.prometheus.pinned is not a digest reference: '$IMAGE'"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 755 "$TMP"

# promtool <dir> <args…> — the pinned image's promtool with <dir> as its working directory
promtool() {
  local dir="$1"; shift
  "$RT" run --rm --network none -v "$dir:/t:ro" -w /t --entrypoint promtool "$IMAGE" "$@"
}

FILES=(fabric.yaml reconcile.yaml pipeline.yaml recording.yaml)

# 1. rule files and the scrape configuration are valid for the pinned Prometheus
mkdir -p "$TMP/rules"; cp "${FILES[@]/#/$RULES/}" "$TMP/rules/"
out="$(promtool "$TMP/rules" check rules "${FILES[@]}" 2>&1)" && pass "promtool check rules: ${FILES[*]}" || fail "promtool check rules" "$out"
mkdir -p "$TMP/cfg"; cp "$PROMCFG" "$TMP/cfg/"
# --syntax-only: the sdc job's credentials_file is the Pod's ServiceAccount token, absent here
out="$(promtool "$TMP/cfg" check config --syntax-only prometheus.yml 2>&1)" && pass "promtool check config: prometheus.yml" || fail "promtool check config" "$out"

# 2. exactly the ten alerts of §21, where T130 places them, each with severity, summary and next
declare -A WANT=(
  [FabricLinkDown]=fabric.yaml [BGPSessionDown]=fabric.yaml [EvpnRoutesLost]=fabric.yaml
  [ReconciliationFailed]=reconcile.yaml [ReverificationStalled]=reconcile.yaml
  [DeviceTelemetryTargetDown]=pipeline.yaml [DeviceSubscriptionStalled]=pipeline.yaml
  [OtlpExportFailing]=pipeline.yaml [OtlpDataPointsRejected]=pipeline.yaml [DuplicateDeviceSeries]=pipeline.yaml
)
got="$(for f in "${FILES[@]}"; do yq -r '.groups[].rules[] | select(has("alert")) | .alert + " '"$f"'"' "$RULES/$f"; done | sort)"
want="$(for a in "${!WANT[@]}"; do echo "$a ${WANT[$a]}"; done | sort)"
[[ "$got" == "$want" ]] && pass "exactly the ten alerts of data-model.md §21, by name and file" \
  || fail "the alert set differs from §21" "$(diff <(echo "$want") <(echo "$got"))"
bad="$(for f in "${FILES[@]}"; do yq -r '.groups[].rules[] | select(has("alert"))
  | select((.labels.severity // "") != "critical" and (.labels.severity // "") != "warning"
           or (.annotations.summary // "") == "" or (.annotations.next // "") == "") | .alert' "$RULES/$f"; done)"
[[ -z "$bad" ]] && pass "every alert has labels.severity (critical|warning), annotations.summary and annotations.next" \
  || fail "alerts missing severity/summary/next" "$bad"

# 3. the EVPN guard's names are the recorded ones (AD-55)
SESSION="$(jq -r '.series.evpn_session_state[0].name // empty' "$SERIES_JSON")"
RECEIVED="$(jq -r '.series.evpn_received_routes[0].name // empty' "$SERIES_JSON")"
EVI="$(jq -r '.series.bgp_evpn_instance_evi[0].name // empty' "$SERIES_JSON")"
if [[ -z "$SESSION" || -z "$RECEIVED" || -z "$EVI" ]]; then
  fail "telemetry-series.json records the guard's names (series.{evpn_session_state,evpn_received_routes,bgp_evpn_instance_evi}[0].name)"
  echo "rules_test: $fails failure(s)"; exit 1
fi
evpn_expr="$(yq -r '.groups[].rules[] | select(.alert == "EvpnRoutesLost") | .expr' "$RULES/fabric.yaml")"
missing=""
for n in "$SESSION" "$RECEIVED" "$EVI"; do grep -qF -- "$n" <<<"$evpn_expr" || missing+="$n"$'\n'; done
unrecorded="$(yq -r '.groups[].rules[].expr' "$RULES/fabric.yaml" | grep -oE 'srl_nokia_network_instance:[A-Za-z0-9_:]+' | sort -u \
  | grep -vxF -f <(jq -r '.series[][].name' "$SERIES_JSON") || true)"
if [[ -z "$missing" && -z "$unrecorded" ]]; then
  pass "rules/fabric.yaml uses exactly the recorded EVPN guard series names of telemetry-series.json"
else
  fail "EVPN guard series names differ from telemetry-series.json" "not used: ${missing:-none}"$'\n'"not recorded: ${unrecorded:-none}"
fi

# render the test with the recorded names
render() {  # render <dir>
  sed -e "s|@@EVPN_SESSION_STATE@@|${SESSION}|g" -e "s|@@EVPN_RECEIVED_ROUTES@@|${RECEIVED}|g" \
      -e "s|@@BGP_EVPN_INSTANCE_EVI@@|${EVI}|g" "$HERE/rules_test.yaml" >"$1/rules_test.yaml"
}
render "$TMP/rules"
if grep -q '@@' "$TMP/rules/rules_test.yaml"; then fail "rules_test.yaml has an unfilled placeholder" "$(grep -n '@@' "$TMP/rules/rules_test.yaml")"; fi

# 4. the tests pass against the rules
out="$(promtool "$TMP/rules" test rules rules_test.yaml 2>&1)" && pass "promtool test rules: every rule fires, clears, and stays silent where it must" \
  || fail "promtool test rules" "$out"

# 5. coverage: every alert has a firing and a silent evaluation
cov=""
for a in "${!WANT[@]}"; do
  f="$(yq -r "[.tests[].alert_rule_test[]? | select(.alertname == \"$a\") | select((.exp_alerts | length) > 0)] | length" "$HERE/rules_test.yaml")"
  s="$(yq -r "[.tests[].alert_rule_test[]? | select(.alertname == \"$a\") | select((.exp_alerts | length) == 0)] | length" "$HERE/rules_test.yaml")"
  [[ "$f" -ge 1 && "$s" -ge 1 ]] || cov+="$a (firing $f, silent $s)"$'\n'
done
[[ -z "$cov" ]] && pass "every one of the ten alerts has a firing and a silent evaluation" || fail "alert coverage" "$cov"

# 6. negative control: the same tests against empty rule files fail
mkdir -p "$TMP/empty"; for f in "${FILES[@]}"; do : >"$TMP/empty/$f"; done; render "$TMP/empty"
out="$(promtool "$TMP/empty" test rules rules_test.yaml 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && pass "negative control: the suite fails against empty rule files (exit $rc)" \
  || fail "negative control: the suite passed against empty rule files" "$out"

# 7. negative control: EvpnRoutesLost without its evi guard is caught by the no-fire cases
mkdir -p "$TMP/unguarded"; cp "${FILES[@]/#/$RULES/}" "$TMP/unguarded/"; render "$TMP/unguarded"
python3 - "$TMP/unguarded/fabric.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p))
for g in d["groups"]:
    for r in g["rules"]:
        if r.get("alert") == "EvpnRoutesLost":
            r["expr"] = r["expr"].split("and on (source) agentic_netops_node_info")[0]
open(p, "w").write(yaml.safe_dump(d, sort_keys=False))
PY
out="$(promtool "$TMP/unguarded" test rules rules_test.yaml 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'EvpnRoutesLost' <<<"$out"; then
  pass "negative control: an unguarded EvpnRoutesLost fails the no-fire cases"
else
  fail "negative control: an unguarded EvpnRoutesLost passed" "$out"
fi

echo "rules_test: $fails failure(s)"
[ "$fails" -eq 0 ]
