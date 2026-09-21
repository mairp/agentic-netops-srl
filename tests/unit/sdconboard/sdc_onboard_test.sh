#!/usr/bin/env bash
# sdc-onboard / wait-targets suite (T036; FR-015, FR-086, AD-13, AD-34).
#
# Offline: a fake kubectl (KUBECTL=…) records every call; no cluster.
#   the committed deploy/sdc/onboarding passes the negative assertions
#   a manifest carrying `revertive:` fails NAMING THE FILE and line; nothing is applied
#   a drift-policy annotation key / a Subscription / an onChange sync each fail naming the file
#   discovery-rule.yaml is exactly `onboarding::render 172.25.25.0/24` (no hand edits)
#   a non-default MGMT_CIDR renders .11/.12/.21/.22 of it; a too-small one is refused
#   a full run applies `apply --server-side -k <dir>` after the CRD waits and the Secret check
#   a missing srl-credentials Secret fails naming it; nothing is applied
#   a non-default MGMT_CIDR applies a rendered temporary copy, never the committed file
#   wait-targets: four Ready Targets pass; a not-Ready or missing one times out naming it
# shellcheck disable=SC2015 # pass() always succeeds, so `cond && pass || fail` is if-then-else here
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
ONB="$ROOT/deploy/sdc/onboarding"
SO="$ROOT/scripts/lib/sdc_onboard.sh"
WT="$ROOT/scripts/lib/wait_targets.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

cat >"$TMP/kubectl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_KUBECTL_LOG"
args=("$@"); [[ "${args[0]}" == "--context" ]] && args=("${args[@]:2}")
case "${args[0]} ${args[1]:-}" in
  "wait "*) exit 0 ;;
  "get secret") exit "${FAKE_SECRET_RC:-0}" ;;
  "get targets.config.sdcio.dev") cat "$FAKE_TARGETS_JSON"; exit 0 ;;
  "apply --server-side") cp "${args[3]}/discovery-rule.yaml" "$FAKE_APPLIED"; exit 0 ;;
esac
echo "fake kubectl: unexpected: $*" >&2; exit 9
SH
chmod +x "$TMP/kubectl"
export KUBECTL="$TMP/kubectl" FAKE_KUBECTL_LOG="$TMP/kubectl.log" FAKE_APPLIED="$TMP/applied.yaml"
: >"$FAKE_KUBECTL_LOG"

# case <name> — a copy of the committed onboarding dir to plant into.
case_dir() { rm -rf "${TMP:?}/$1"; cp -R "$ONB" "$TMP/$1"; printf '%s\n' "$TMP/$1"; }
applied_nothing() { ! grep -q '^apply' "$FAKE_KUBECTL_LOG"; }

# 1 — committed dir
out="$(bash "$SO" --check-only 2>&1)"; rc=$?
[[ "$rc" -eq 0 ]] && grep -qF "negatives hold" <<<"$out" && pass "committed onboarding manifests: no drift-policy statement, no metric subscription" \
  || fail "committed onboarding (rc=$rc)" "$out"

# 2 — revertive: planted (the negative control of the assertion)
d="$(case_dir revertive)"; : >"$FAKE_KUBECTL_LOG"
sed -i 's/^  validate: true$/  validate: true\n  revertive: true/' "$d/target-sync-profile.yaml"
line="$(grep -n '^  revertive: true' "$d/target-sync-profile.yaml" | cut -d: -f1)"
out="$(bash "$SO" --dir "$d" 2>&1)"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -qF "FAIL [drift-policy] $d/target-sync-profile.yaml:$line: onboarding manifest states a drift policy (key 'spec.revertive')" <<<"$out" \
   && [[ "$(grep -c '^FAIL' <<<"$out")" -eq 1 ]] && grep -qF "nothing applied" <<<"$out" && applied_nothing; then
  pass "a manifest with 'revertive:' fails naming the file and line; nothing applied"
else fail "revertive planted (rc=$rc)" "$out"; fi

# 3 — a drift-policy annotation key (value names the policy too)
d="$(case_dir annotation)"
sed -i 's/^  namespace: sdc-system$/  namespace: sdc-system\n  annotations:\n    agentic-netops.io\/drift-policy: non-revertive/' "$d/discovery-rule.yaml"
out="$(bash "$SO" --dir "$d" --check-only 2>&1)"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -qF "FAIL [drift-policy] $d/discovery-rule.yaml:" <<<"$out" && grep -qF "key 'metadata.annotations.agentic-netops.io/drift-policy'" <<<"$out" \
   && grep -qF "value 'non-revertive'" <<<"$out"; then
  pass "a drift-policy annotation fails naming the file (key and value both reported)"
else fail "annotation planted (rc=$rc)" "$out"; fi

# 4 — a Subscription object
d="$(case_dir subscription)"
printf '# provenance: source=first-party version=v0.1.0\napiVersion: inv.sdcio.dev/v1alpha1\nkind: Subscription\nmetadata: {name: ifstats, namespace: sdc-system}\nspec:\n  target: {targetSelector: {}}\n  protocol: gnmi\n  port: 57400\n  subscriptions: [{name: if, mode: sample, paths: [/interface]}]\n' >"$d/subscription.yaml"
out="$(bash "$SO" --dir "$d" --check-only 2>&1)"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -qF "FAIL [metric-subscription] $d/subscription.yaml:2: subscription-based metric ingestion (a Subscription object)" <<<"$out"; then
  pass "a Subscription object fails naming the file (FR-086)"
else fail "subscription planted (rc=$rc)" "$out"; fi

# 5 — an onChange sync
d="$(case_dir onchange)"; sed -i 's/^    mode: get$/    mode: onChange/' "$d/target-sync-profile.yaml"
out="$(bash "$SO" --dir "$d" --check-only 2>&1)"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -qF "FAIL [metric-subscription] $d/target-sync-profile.yaml:" <<<"$out" && grep -qF "spec.sync[0].mode 'onChange' is a Subscribe mode" <<<"$out"; then
  pass "an onChange sync entry fails naming the file"
else fail "onChange planted (rc=$rc)" "$out"; fi

# 6 — the committed DiscoveryRule is the default render
# shellcheck source=../../../scripts/lib/onboarding.sh
source "$ROOT/scripts/lib/onboarding.sh"
if diff <(onboarding::render 172.25.25.0/24) "$ONB/discovery-rule.yaml" >/dev/null; then
  pass "discovery-rule.yaml == onboarding::render 172.25.25.0/24"
else fail "discovery-rule.yaml drifted from onboarding::render 172.25.25.0/24" "$(diff <(onboarding::render 172.25.25.0/24) "$ONB/discovery-rule.yaml")"; fi
got="$(onboarding::hosts 10.44.8.0/24 | tr '\n' ' ')"
[[ "$got" == "spine01 10.44.8.11 spine02 10.44.8.12 leaf01 10.44.8.21 leaf02 10.44.8.22 " ]] \
  && pass "non-default MGMT_CIDR renders .11/.12/.21/.22 of it" || fail "hosts for 10.44.8.0/24: $got"
out="$(onboarding::render 10.44.8.0/28 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && grep -qF "too small for leaf01" <<<"$out" && ! grep -q "kind: DiscoveryRule" <<<"$out" \
  && pass "a MGMT_CIDR too small for the host offsets is refused, nothing rendered" || fail "small CIDR (rc=$rc)" "$out"

# 7 — full run
: >"$FAKE_KUBECTL_LOG"; rm -f "$FAKE_APPLIED"
out="$(bash "$SO" 2>&1)"; rc=$?
if [[ "$rc" -eq 0 ]] && grep -qF "wait crd/discoveryrules.inv.sdcio.dev --for=condition=Established" "$FAKE_KUBECTL_LOG" \
   && grep -qF "get secret srl-credentials -n sdc-system" "$FAKE_KUBECTL_LOG" \
   && grep -qxF "apply --server-side -k $ONB" "$FAKE_KUBECTL_LOG" && cmp -s "$FAKE_APPLIED" "$ONB/discovery-rule.yaml"; then
  pass "full run: CRDs Established, Secret present, then 'kubectl apply --server-side -k deploy/sdc/onboarding'"
else fail "full run (rc=$rc)" "$out
$(cat "$FAKE_KUBECTL_LOG")"; fi

# 8 — Secret missing
: >"$FAKE_KUBECTL_LOG"
out="$(FAKE_SECRET_RC=1 bash "$SO" 2>&1)"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -qF "Secret sdc-system/srl-credentials is missing" <<<"$out" && applied_nothing; then
  pass "missing srl-credentials Secret fails naming it; nothing applied"
else fail "missing secret (rc=$rc)" "$out"; fi

# 9 — non-default MGMT_CIDR applies a rendered copy
: >"$FAKE_KUBECTL_LOG"; rm -f "$FAKE_APPLIED"
before="$(sha256sum "$ONB/discovery-rule.yaml")"
out="$(MGMT_CIDR=10.44.8.0/24 bash "$SO" 2>&1)"; rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "^apply --server-side -k /.*/onboarding$" "$FAKE_KUBECTL_LOG" && ! grep -qxF "apply --server-side -k $ONB" "$FAKE_KUBECTL_LOG" \
   && grep -qF "address: 10.44.8.22" "$FAKE_APPLIED" && [[ "$before" == "$(sha256sum "$ONB/discovery-rule.yaml")" ]]; then
  pass "non-default MGMT_CIDR: a rendered temporary copy is applied; the committed file is untouched"
else fail "non-default MGMT_CIDR (rc=$rc)" "$out
$(cat "$FAKE_KUBECTL_LOG")"; fi

# 10 — wait-targets
target() { # name address status-of-TargetConnectionReady
  printf '{"metadata":{"name":"%s"},"spec":{"address":"%s"},"status":{"conditions":[{"type":"Ready","status":"True"},{"type":"TargetDiscoveryReady","status":"True"},{"type":"TargetDatastoreReady","status":"True"},{"type":"TargetConnectionReady","status":"%s","message":"%s"}]}}' "$1" "$2" "$3" "${4:-}"
}
printf '{"items":[%s,%s,%s,%s]}' "$(target spine01 172.25.25.11 True)" "$(target spine02 172.25.25.12 True)" \
  "$(target leaf01 172.25.25.21 True)" "$(target leaf02 172.25.25.22 True)" >"$TMP/ready.json"
printf '{"items":[%s,%s,%s]}' "$(target spine01 172.25.25.11 True)" "$(target spine02 172.25.25.12 True)" \
  "$(target leaf02 172.25.25.22 False 'rpc error: connection refused')" >"$TMP/notready.json"
out="$(FAKE_TARGETS_JSON="$TMP/ready.json" bash "$WT" --timeout 5 --interval 1 2>&1)"; rc=$?
[[ "$rc" -eq 0 ]] && grep -qF "leaf02 (172.25.25.22): Ready" <<<"$out" && grep -qF "get targets.config.sdcio.dev -n sdc-system -o json" "$FAKE_KUBECTL_LOG" \
  && pass "wait-targets: four Ready config.sdcio.dev Targets pass" || fail "wait-targets ready (rc=$rc)" "$out"
out="$(FAKE_TARGETS_JSON="$TMP/notready.json" bash "$WT" --timeout 2 --interval 1 2>&1)"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -qF "timed out after 2s" <<<"$out" && grep -qF "leaf01: MISSING" <<<"$out" \
   && grep -qF "leaf02 (172.25.25.22): NOT READY: TargetConnectionReady=False (rpc error: connection refused)" <<<"$out"; then
  pass "wait-targets: bounded; times out naming the missing and the not-Ready Target with its condition"
else fail "wait-targets not ready (rc=$rc)" "$out"; fi
out="$(bash "$WT" --timeout 0 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && grep -qF "must be a positive number of seconds" <<<"$out" && pass "wait-targets: an unbounded wait is refused" \
  || fail "wait-targets unbounded (rc=$rc)" "$out"

echo "sdc_onboard_test: $([[ $fails -eq 0 ]] && echo PASS || echo "FAIL ($fails)")"
[[ "$fails" -eq 0 ]]
