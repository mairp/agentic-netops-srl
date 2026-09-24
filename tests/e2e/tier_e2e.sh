#!/usr/bin/env bash
# tier_e2e.sh — T089 live driver (quickstart.md §10, §16, §25, §24's tier purge): runs, each through
# evidence_run into ONE per-run EVIDENCE_DIR,
#   1. agents/tests/e2e/test_operator_auth.py  — every pipeline-reaching route refused, zero deltas;
#   2. agents/tests/e2e/test_tier_health.py    — health, NFR-012 measure, fabric undisturbed (+ its
#                                                negative control), a worker down and the thread resumed;
#   3. tests/e2e/tier_purge_live.sh            — refused / blocked / completed purge, then the tier
#                                                provisioned again (skipped with TIER_E2E_SKIP_PURGE=1).
# Exit non-zero when any of them failed. Needs the lab provisioned with --with-intent-tier.
set -uo pipefail

E2E_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/evidence.sh
source "$E2E_ROOT/scripts/lib/evidence.sh"
evidence::ensure_dir || exit 3
export EVIDENCE_DIR AGENTIC_NETOPS_E2E=1
rc=0
for suite in test_operator_auth test_tier_health; do
  r=0
  evidence_run "t089-${suite//_/-}" -- bash -c "cd '$E2E_ROOT/agents' && uv run pytest -v -p no:cacheprovider tests/e2e/${suite}.py" || r=$?
  echo "T089 ${suite}: exit ${r} (evidence: ${EVIDENCE_DIR}/t089-${suite//_/-}.stdout)"
  [[ "$r" -eq 0 ]] || rc=1
done
# the measurements the suites wrote under t089/ are attached to a record, so each is run-captured
# proof with its hash, never a hand-placed file (NFR-013, make verify-evidence)
if compgen -G "$EVIDENCE_DIR/t089/*.json" >/dev/null; then
  attach=()
  for f in "$EVIDENCE_DIR"/t089/*.json; do attach+=(--attach "t089/${f##*/}"); done
  evidence_run t089-measurements "${attach[@]}" -- ls -1 "$EVIDENCE_DIR/t089" >/dev/null || rc=1
fi
if [[ "${TIER_E2E_SKIP_PURGE:-0}" != 1 ]]; then
  r=0; bash "$E2E_ROOT/tests/e2e/tier_purge_live.sh" || r=$?
  echo "T089 tier_purge_live: exit ${r}"
  [[ "$r" -eq 0 ]] || rc=1
fi
echo "T089 evidence: ${EVIDENCE_DIR} rc=${rc}"
exit "$rc"
