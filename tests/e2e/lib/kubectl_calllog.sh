#!/usr/bin/env bash
# kubectl_calllog.sh — a pass-through kubectl that records every invocation, in order, to
# $KUBECTL_CALLLOG as `<epoch s.ns>\t<argv>` before running $KUBECTL_REAL (default kubectl).
# T152 sets KUBECTL to this file around `off.sh --purge-intent-tier` so tests/e2e/lib/purge_order.py
# can assert the order of the purge's calls from what was actually called.
set -uo pipefail
if [[ -n "${KUBECTL_CALLLOG:-}" ]]; then
  printf '%s\t%s\n' "$(date +%s.%N)" "$*" >>"$KUBECTL_CALLLOG"
fi
exec "${KUBECTL_REAL:-kubectl}" "$@"
