#!/usr/bin/env bash
# chat_surface_e2e.sh — T127 live driver (SC-019, NFR-003, AD-21; quickstart.md §9): the scripted
# browser session over the operator chat surface, each step through evidence_run into ONE per-run
# EVIDENCE_DIR:
#   1. make verify-pins VERIFY_PINS_FLAGS=--host-tooling — the browser-automation package and the
#      browser build it fixes are checked against versions.lock.yaml hostTooling FIRST; a ranged,
#      missing or different entry stops the run before any browser starts;
#   2. the versions actually used — the installed playwright package and the browser revision
#      directory it runs — recorded as their own evidence record (t127-host-tooling-versions);
#   3. agents/tests/e2e/test_chat_surface.py (Playwright, headless chromium) against the ui on the
#      Kind loopback mapping (UI_URL, default http://127.0.0.1:13000);
#   4. the session's own measurements and screenshots under t127/ attached to a record, so each is
#      run-captured proof with its hash (NFR-013, make verify-evidence).
# Needs the lab provisioned with --with-intent-tier (the ui Deployment, T126). Exit non-zero when a
# step failed.
set -uo pipefail

E2E_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/evidence.sh
source "$E2E_ROOT/scripts/lib/evidence.sh"
evidence::ensure_dir || exit 3
export EVIDENCE_DIR AGENTIC_NETOPS_E2E=1
rc=0

if ! evidence_run t127-verify-pins-host-tooling -- make -C "$E2E_ROOT" verify-pins VERIFY_PINS_FLAGS=--host-tooling; then
  echo "T127: make verify-pins --host-tooling failed — no browser session is run (NFR-003, AD-21)" >&2
  exit 1
fi

evidence_run t127-host-tooling-versions -- bash -c "
  cd '$E2E_ROOT/agents' || exit 1
  uv run python - <<'PY'
import json, pathlib
from importlib.metadata import version
from playwright.sync_api import sync_playwright
with sync_playwright() as pw:
    exe = pathlib.Path(pw.chromium.executable_path)
    b = pw.chromium.launch(headless=True)
    out = {'playwright': version('playwright'), 'browser': 'chromium',
           'browser_version': b.version,
           'browser_dir': next(p.name for p in exe.parents if p.parent.name == 'ms-playwright'),
           'executable': str(exe)}
    b.close()
print(json.dumps(out, sort_keys=True))
PY
" || rc=1

r=0
evidence_run t127-chat-surface -- bash -c "cd '$E2E_ROOT/agents' && uv run pytest -v -p no:cacheprovider tests/e2e/test_chat_surface.py ${CHAT_SURFACE_PYTEST_ARGS:-}" || r=$?
echo "T127 test_chat_surface: exit ${r} (evidence: ${EVIDENCE_DIR}/t127-chat-surface.stdout)"
[[ "$r" -eq 0 ]] || rc=1

if compgen -G "$EVIDENCE_DIR/t127/*" >/dev/null; then
  attach=()
  for f in "$EVIDENCE_DIR"/t127/*; do attach+=(--attach "t127/${f##*/}"); done
  evidence_run t127-measurements "${attach[@]}" -- ls -1 "$EVIDENCE_DIR/t127" >/dev/null || rc=1
fi
echo "T127 evidence: ${EVIDENCE_DIR} rc=${rc}"
exit "$rc"
