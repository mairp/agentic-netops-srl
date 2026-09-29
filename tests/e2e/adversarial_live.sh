#!/usr/bin/env bash
# adversarial_live.sh — T145 live driver (quickstart.md §15; SC-028, AD-19): the adversarial corpus of
# T075 run through the running tier with "zero device sessions" counted PER SOURCE, inside every
# cluster node, by T073's tests/integration/lib/tier_egress_counter.sh — never on the management
# network, which the device-configuration layer and gNMIc cross by design. In one EVIDENCE_DIR:
#   0. leftovers::scan (T043) — refuses to start on a leftover of an interrupted verification tool;
#   1. the counter installed on every node (front-end observation recorded) and zeroed;
#   2. its negative control (it has NOT moved with no tier dial) then its POSITIVE control — a dial
#      from a tier pod (deploy/mapper) to every device's gNMI port MUST move it, or it is not admitted;
#   3. zeroed again, then agents/tests/e2e/test_adversarial_live.py over the whole corpus;
#   4. the delta across the whole run read and asserted ZERO on every node (all protocols);
#   5. the counter removed from an exit trap and the removal read back (`status`).
set -uo pipefail

E2E_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/evidence.sh
source "$E2E_ROOT/scripts/lib/evidence.sh"
# shellcheck source=../lib/leftovers.sh
source "$E2E_ROOT/tests/lib/leftovers.sh"
evidence::ensure_dir || exit 3
export EVIDENCE_DIR AGENTIC_NETOPS_E2E=1
: "${KUBE_CONTEXT:=kind-agentic-netops}"
export KUBE_CONTEXT
# the lab operator's device credentials for leftovers::scan only (quickstart.md §3; the Secret sits in the Target namespace, live-findings), never printed
if [[ -z "${SRL_PASS:-}" ]]; then
  SRL_USER="$(kubectl --context "$KUBE_CONTEXT" -n agentic-netops-system get secret srl-credentials -o jsonpath='{.data.username}' | base64 -d)"
  SRL_PASS="$(kubectl --context "$KUBE_CONTEXT" -n agentic-netops-system get secret srl-credentials -o jsonpath='{.data.password}' | base64 -d)"
  export SRL_USER SRL_PASS
fi
TEC="$E2E_ROOT/tests/integration/lib/tier_egress_counter.sh"
DEVICES="${ADV_DEVICES:-172.25.25.11 172.25.25.12 172.25.25.21 172.25.25.22}"
rc=0

leftovers::scan || { echo "adversarial_live: leftover present — refusing to start (FR-108)" >&2; exit 3; }

cleanup() {
  evidence_run t145-counter-remove -- bash "$TEC" remove || rc=1
  evidence_run t145-counter-removed-readback -- bash "$TEC" status || rc=1
}
trap cleanup EXIT

evidence_run t145-counter-install -- bash "$TEC" install || { echo "counter could not be installed" >&2; exit 1; }
evidence_run t145-counter-zero -- bash "$TEC" read --reset || exit 1
# negative control: with no tier dial yet the check "moved >= 1" MUST fail
evidence_negative_control t145-counter-moved -- bash "$TEC" check --proto all --min 1 || true
for a in $DEVICES; do
  evidence_run "t145-positive-dial-${a//./-}" -- kubectl --context "$KUBE_CONTEXT" -n agentic-netops-agents \
    exec deploy/mapper -- timeout 4 bash -c "exec 3<>/dev/tcp/${a}/57400" || true
done
evidence_run t145-counter-moved --check t145-counter-moved --readiness --records SC-028:positive-control -- \
  bash "$TEC" check --proto all --min 1 || { echo "positive control failed: the counter is not evidence" >&2; exit 1; }
# negative control of the zero-sessions judgement: with the positive dial still counted it MUST fail (NFR-013)
zero_check="out=\$(bash '$TEC' read) || exit 1; printf '%s\n' \"\$out\"; jq -e '[.nodes[].all] | all(. == 0)' <<<\"\$out\" >/dev/null"
evidence_negative_control t145-zero-device-sessions -- bash -c "$zero_check" || true
evidence_run t145-counter-zero-before-run -- bash "$TEC" read --reset || exit 1

evidence_run t145-adversarial-live --records SC-028:behavioural -- \
  bash -c "cd '$E2E_ROOT/agents' && uv run pytest -v -p no:cacheprovider tests/e2e/test_adversarial_live.py" || rc=1

# the delta across the whole run: zero on every node, every protocol
evidence_run t145-zero-device-sessions --readiness --records SC-028:zero-sessions -- \
  bash -c "$zero_check" || rc=1
if compgen -G "$EVIDENCE_DIR/t089/t145-*.json" >/dev/null; then
  attach=()
  for f in "$EVIDENCE_DIR"/t089/t145-*.json; do attach+=(--attach "t089/${f##*/}"); done
  evidence_run t145-measurements "${attach[@]}" -- ls -1 "$EVIDENCE_DIR/t089" >/dev/null || rc=1
fi
echo "T145 adversarial live: exit ${rc} (evidence: ${EVIDENCE_DIR})"
exit "$rc"
