#!/usr/bin/env bash
# degradation_e2e.sh — T146 live driver (NFR-010, AD-52): the legible-degradation cases of
# agents/tests/e2e/test_degradation.py, each through evidence_run into ONE per-run EVIDENCE_DIR:
#   0. leftovers::scan (tests/lib/leftovers.sh, T043) FIRST — the suite makes injected faults and a
#      gate-owned scratch namespace, so it refuses to start while a leftover of an interrupted
#      verification tool is present anywhere (FR-108, AD-49); plus the one scratch kind the scan does
#      not read: a gate-labelled NetworkPolicy in agentic-netops-agents (the fake provider's egress);
#   1. the NEGATIVE CONTROL, stated first: the suite's single judgement (assert_names) run over the
#      tier's generic failure ("internal error: APIConnectionError") must FAIL — a judgement that
#      passes a failure naming no dependency is defective and no run of it is admitted (NFR-013);
#   2. the fault fingerprint before: sha256 of llm-provider BASE_URL and of the mapper card, the
#      slim and srl-provider replica counts, gate-labelled NetworkPolicies in the tier namespace;
#   3. the suite (live: AGENTIC_NETOPS_E2E=1) — every fault is put back in a finally inside it;
#   4. the fault fingerprint after, which must equal the one before — the restoration read back
#      from outside the suite too — and leftovers::scan again;
#   5. the suite's own measurements (t089/t146-*.json) attached to a record.
# Needs the lab provisioned with --with-intent-tier. Serial with T144/T145/T147 (it shares the lab).
# Exit non-zero when any step failed. Extra pytest args: DEGRADATION_PYTEST_ARGS (e.g. -k transport).
set -uo pipefail

E2E_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/evidence.sh
source "$E2E_ROOT/scripts/lib/evidence.sh"
# shellcheck source=../lib/leftovers.sh
source "$E2E_ROOT/tests/lib/leftovers.sh"
evidence::ensure_dir || exit 3
export EVIDENCE_DIR AGENTIC_NETOPS_E2E=1
CTX="${KUBE_CONTEXT:-kind-agentic-netops}"
AGENTS_NS=agentic-netops-agents
rc=0
# the lab operator's device credentials for leftovers::scan only (quickstart.md §3; the Secret sits in the Target namespace, live-findings), never printed
if [[ -z "${SRL_PASS:-}" ]]; then
  SRL_USER="$(kubectl --context "$CTX" -n agentic-netops-system get secret srl-credentials -o jsonpath='{.data.username}' | base64 -d)"
  SRL_PASS="$(kubectl --context "$CTX" -n agentic-netops-system get secret srl-credentials -o jsonpath='{.data.password}' | base64 -d)"
  export SRL_USER SRL_PASS
fi

if ! leftovers::scan; then
  echo "T146: leftovers present — refusing to start (FR-108)" >&2
  exit 1
fi

# the fault fingerprint: what the suite changes, as hashes and counts — never a secret's value
# shellcheck disable=SC2317  # invoked indirectly, through evidence_run's bash -c
fingerprint() {
  local url card slim provider policies
  url="$(kubectl --context "$CTX" -n "$AGENTS_NS" get secret llm-provider -o jsonpath='{.data.BASE_URL}' | sha256sum | cut -d' ' -f1)" || return 1
  card="$(kubectl --context "$CTX" -n "$AGENTS_NS" get configmap agent-cards -o jsonpath='{.data.mapper\.json}' | sha256sum | cut -d' ' -f1)" || return 1
  slim="$(kubectl --context "$CTX" -n "$AGENTS_NS" get deployment slim -o jsonpath='{.spec.replicas}/{.status.readyReplicas}')" || return 1
  provider="$(kubectl --context "$CTX" -n agentic-netops-system get deployment srl-provider -o jsonpath='{.spec.replicas}/{.status.readyReplicas}')" || return 1
  policies="$(kubectl --context "$CTX" -n "$AGENTS_NS" get networkpolicies -l "$LAB_GATE_SELECTOR" -o name)" || return 1
  jq -n --arg url "$url" --arg card "$card" --arg slim "$slim" --arg provider "$provider" \
        --arg policies "$policies" \
    '{llm_provider_base_url_sha256: $url, mapper_card_sha256: $card, slim: $slim,
      srl_provider: $provider, gate_networkpolicies: ($policies | split("\n") | map(select(. != "")))}'
}
export -f fingerprint
export CTX AGENTS_NS LAB_GATE_SELECTOR

nc=0
evidence_negative_control t146-degradation -- bash -c "cd '$E2E_ROOT/agents/tests/e2e' && uv run python -c '
import test_degradation as t
t.assert_names(\"model provider\", \"internal error: APIConnectionError\",
               forbid=(\"transport\", \"cluster API\", \"worker\"))
'" || nc=$?
if [[ "$nc" -ne 0 ]]; then
  echo "T146: the negative control did not fail as it must (rc=${nc}) — not running the suite" >&2
  exit 1
fi

# the fingerprint is the run's captured stdout — never a file of the record's own name, which
# evidence_run writes over with the record itself
before="$EVIDENCE_DIR/t146-fingerprint-before.stdout"
evidence_run t146-fingerprint-before -- bash -c fingerprint || rc=1
if [[ "$(jq -r '.gate_networkpolicies | length' "$before" 2>/dev/null)" != 0 ]]; then
  echo "T146: a gate-labelled NetworkPolicy is already in ${AGENTS_NS} (or no fingerprint) — refusing to start" >&2
  exit 1
fi

r=0
evidence_run t146-degradation -- bash -c "cd '$E2E_ROOT/agents' && uv run pytest -v -p no:cacheprovider tests/e2e/test_degradation.py ${DEGRADATION_PYTEST_ARGS:-}" || r=$?
echo "T146 test_degradation: exit ${r} (evidence: ${EVIDENCE_DIR}/t146-degradation.stdout)"
[[ "$r" -eq 0 ]] || rc=1

# stdout: the diff of the fingerprint now against the one before — empty when restored
evidence_run t146-fingerprint-after -- bash -c "diff <(jq -S . '$before') <(fingerprint | jq -S .)" || {
  echo "T146: the lab is not as the suite found it — see ${EVIDENCE_DIR}/t146-fingerprint-after.stdout" >&2
  rc=1
}
leftovers::scan || { echo "T146: the suite left something behind" >&2; rc=1; }

if compgen -G "$EVIDENCE_DIR/t089/t146-*.json" >/dev/null; then
  attach=()
  for f in "$EVIDENCE_DIR"/t089/t146-*.json; do attach+=(--attach "t089/${f##*/}"); done
  evidence_run t146-measurements "${attach[@]}" -- ls -1 "$EVIDENCE_DIR/t089" >/dev/null || rc=1
fi
echo "T146 evidence: ${EVIDENCE_DIR} rc=${rc}"
exit "$rc"
