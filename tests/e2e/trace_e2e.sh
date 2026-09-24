#!/usr/bin/env bash
# trace_e2e.sh — T138 live driver (quickstart.md §27; SC-038, SC-039): runs, each through evidence_run
# into ONE per-run EVIDENCE_DIR,
#   1. agents/tests/e2e/test_trace_per_request.py — one trace per request in both sinks; one sink down
#                                                   while the other stays healthy, visible;
#   2. agents/tests/e2e/test_failure_injection.py — a failure per stage named from the trace alone;
#   3. agents/tests/e2e/test_correlation_links.py — fabric service view ⇄ conversation, no timestamp.
# The session fixture provisions one service through the tier and removes it at the end. Exit non-zero
# when any suite failed. Needs the lab provisioned with --with-intent-tier and ObservabilityReady.
set -uo pipefail

E2E_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/evidence.sh
source "$E2E_ROOT/scripts/lib/evidence.sh"
evidence::ensure_dir || exit 3
export EVIDENCE_DIR AGENTIC_NETOPS_E2E=1
suites="${TRACE_E2E_SUITES:-test_trace_per_request test_failure_injection test_correlation_links}"
paths=()
for s in $suites; do paths+=("tests/e2e/${s}.py"); done
rc=0
evidence_run t138-trace-e2e -- bash -c "cd '$E2E_ROOT/agents' && uv run pytest -v -p no:cacheprovider ${paths[*]}" || rc=$?
echo "T138 suites: exit ${rc} (evidence: ${EVIDENCE_DIR}/t138-trace-e2e.stdout)"
# the measurements the suites wrote under t089/ are attached to a record (NFR-013, make verify-evidence)
if compgen -G "$EVIDENCE_DIR/t089/t138-*.json" >/dev/null; then
  attach=()
  for f in "$EVIDENCE_DIR"/t089/t138-*.json; do attach+=(--attach "t089/${f##*/}"); done
  evidence_run t138-measurements "${attach[@]}" -- ls -1 "$EVIDENCE_DIR/t089" >/dev/null || rc=1
fi
echo "T138 evidence: ${EVIDENCE_DIR} rc=${rc}"
exit "$rc"
