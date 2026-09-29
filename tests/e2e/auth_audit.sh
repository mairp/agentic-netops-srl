#!/usr/bin/env bash
# auth_audit.sh — T148 live driver (quickstart.md §25; SC-042, FR-102): runs
# agents/tests/e2e/test_auth_audit.py through evidence_run into one EVIDENCE_DIR — both surfaces
# (supervisor :19090 and the chat surface's /api proxy :13000) refused 100% with no or a wrong
# credential and zero threads, model calls and claims; `principal` refused by name; every audit
# principal reconciled against the usernames the tier-phase captures record (never username_unchanged).
# Needs the lab provisioned with --with-intent-tier. Exit non-zero when the suite failed.
set -uo pipefail

E2E_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/evidence.sh
source "$E2E_ROOT/scripts/lib/evidence.sh"
evidence::ensure_dir || exit 3
export EVIDENCE_DIR AGENTIC_NETOPS_E2E=1
rc=0
evidence_run t148-auth-audit --records SC-042:auth-audit -- \
  bash -c "cd '$E2E_ROOT/agents' && uv run pytest -v -p no:cacheprovider tests/e2e/test_auth_audit.py" || rc=$?
if compgen -G "$EVIDENCE_DIR/t089/t148-*.json" >/dev/null; then
  attach=()
  for f in "$EVIDENCE_DIR"/t089/t148-*.json; do attach+=(--attach "t089/${f##*/}"); done
  evidence_run t148-measurements "${attach[@]}" -- ls -1 "$EVIDENCE_DIR/t089" >/dev/null || rc=1
fi
echo "T148 auth audit: exit ${rc} (evidence: ${EVIDENCE_DIR})"
exit "$rc"
