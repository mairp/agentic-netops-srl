#!/usr/bin/env bash
# phrasing_providers.sh — T144 live driver (SC-020, SC-022, SC-027, NFR-008, FR-106): the phrasing
# corpus and the unsupported-construct corpus of T143 (agents/tests/corpus/run_corpus.py) run through
# the RUNNING tier against two distinct model providers, with ONLY the `llm-provider` Secret changed
# between them — by merge patch (scripts/lib/intent_secrets.sh llm-provider, the provisioning path of
# T072), never a whole-object replace. In one EVIDENCE_DIR:
#   0. the Secret's NON-secret fields captured (model, gateway, base-URL host) and the stored base
#      URL's SHA-256 recorded — the value itself is not written, and the API key is never read;
#   1. provider 1 (the one stored): phrasings (>=90% correct first attempt, the rest clarifying
#      questions) and unsupported (every request refused naming its properties, zero resources);
#   2. provider 2, operator-supplied (Stop-and-ask — never guessed): LLM2_MODEL and LLM2_API_KEY, and
#      LLM2_BASE_URL ONLY when that provider needs a different endpoint (LLM2_GATEWAY likewise). The
#      merge sets those keys and nothing else; the stored base URL is then asserted byte-identical
#      (hash) unless LLM2_BASE_URL was given, in which case it is asserted equal to the new value —
#      changed explicitly, never by omission (FR-106). Every agent's mounted copy is waited on until
#      it carries the new model (the agents resolve the endpoint from the mount on every call, T080);
#   3. both corpora again, labelled with provider 2;
#   4. provider 1 restored from an exit trap (the pre-run Secret data, held in a 0600 file outside
#      the evidence root and deleted), the restoration read back by hash.
# Without LLM2_MODEL the second half is reported "not run: second provider not supplied by the
# operator" and the run exits 4 — never counted as a pass.
set -uo pipefail

E2E_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/evidence.sh
source "$E2E_ROOT/scripts/lib/evidence.sh"
evidence::ensure_dir || exit 3
export EVIDENCE_DIR AGENTIC_NETOPS_E2E=1
: "${KUBE_CONTEXT:=kind-agentic-netops}"
export KUBE_CONTEXT
NS=agentic-netops-agents SECRET=llm-provider
AGENTS="${T144_AGENTS:-supervisor mapper allocator deployer}"
k() { kubectl --context "$KUBE_CONTEXT" "$@"; }
field() { k -n "$NS" get secret "$SECRET" -o "jsonpath={.data.$1}" | base64 -d; }
url_sha() { field BASE_URL | sha256sum | cut -d' ' -f1; }
mkdir -p "$EVIDENCE_DIR/t144"
rc=0

corpora() { # <label>
  local label="$1" c part
  # --records admits [a-z0-9-] only; a model name such as gemini-2.5-pro carries a dot (t144r8)
  part="$(tr 'A-Z' 'a-z' <<<"$label" | sed -E 's/[^a-z0-9-]+/-/g; s/^-+|-+$//g')"
  for c in phrasings unsupported; do
    evidence_run "t144-${c}-${part}" --records "SC-0$([[ $c == phrasings ]] && echo 20 || echo 27):${part}" \
      --attach "t144/${c}-${label}.json" -- \
      bash -c "cd '$E2E_ROOT/agents' && uv run python tests/corpus/run_corpus.py --corpus $c \
        --provider-label '$label' --out '$EVIDENCE_DIR/t144/${c}-${label}.json'" || rc=1
  done
}
fields() { # <label> — the non-secret fields only
  evidence_run "t144-secret-fields-$1" -- bash -c "set -o pipefail
    printf 'model=%s\ngateway=%s\n' \"\$(kubectl --context '$KUBE_CONTEXT' -n $NS get secret $SECRET -o jsonpath='{.data.LLM_MODEL}' | base64 -d)\" \
      \"\$(kubectl --context '$KUBE_CONTEXT' -n $NS get secret $SECRET -o jsonpath='{.data.GATEWAY}' | base64 -d)\"
    u=\$(kubectl --context '$KUBE_CONTEXT' -n $NS get secret $SECRET -o jsonpath='{.data.BASE_URL}' | base64 -d)
    printf 'base_url_host=%s\nbase_url_sha256=%s\n' \"\$(sed -E 's#^[a-z]+://([^@/]*@)?([^/:?]+).*#\\2#' <<<\"\$u\")\" \"\$(printf '%s' \"\$u\" | sha256sum | cut -d' ' -f1)\"" || rc=1
}
wait_mounted() { # <model> — every agent's mounted copy carries it
  local a deadline=$((SECONDS + 240))
  for a in $AGENTS; do
    until [[ "$(k -n "$NS" exec "deploy/$a" -c "$a" -- cat /var/run/secrets/agentic-netops/llm-provider/LLM_MODEL 2>/dev/null)" == "$1" ]]; do
      (( SECONDS > deadline )) && { echo "t144: $a's mounted llm-provider never carried model $1" >&2; return 1; }
      sleep 5
    done
  done
}

fields provider1
P1_SHA="$(url_sha)"; P1_MODEL="$(field LLM_MODEL)"; P1_LABEL="${T144_PROVIDER1_LABEL:-${P1_MODEL%%/*}-$(field GATEWAY)}"
corpora "$P1_LABEL"

if [[ -z "${LLM2_MODEL:-}" || -z "${LLM2_API_KEY:-}" ]]; then
  evidence_run t144-provider2-not-run -- bash -c 'echo "not run: second provider not supplied by the operator (Stop-and-ask, T144)"; exit 4' || true
  echo "T144: provider-1 half exit ${rc}; provider 2 NOT RUN — the operator has not supplied it (evidence: ${EVIDENCE_DIR})"
  exit 4
fi
[[ "$LLM2_MODEL" != "$P1_MODEL" ]] || { echo "t144: LLM2_MODEL equals the stored model — not a second provider" >&2; exit 2; }

SNAP="$(mktemp)"; chmod 600 "$SNAP"
k -n "$NS" get secret "$SECRET" -o json | jq '{data: .data}' >"$SNAP" || exit 1
restore() {
  evidence_run t144-restore-provider1 -- bash -c "kubectl --context '$KUBE_CONTEXT' -n $NS patch secret $SECRET --type merge --patch-file '$SNAP' >/dev/null && echo restored" || rc=1
  rm -f "$SNAP"
  evidence_run t144-restore-readback -- bash -c "test \"\$(kubectl --context '$KUBE_CONTEXT' -n $NS get secret $SECRET -o jsonpath='{.data.BASE_URL}' | base64 -d | sha256sum | cut -d' ' -f1)\" = '$P1_SHA' && echo base-url-restored" || rc=1
  wait_mounted "$P1_MODEL" || rc=1
}
trap restore EXIT

# the merge: model and key, and base URL / gateway only when the second provider needs them
# The inputs travel in the ENVIRONMENT of the recorded command, never on its argv: evidence_run
# writes the argv into the record, and t144r8 recorded the second provider's key that way (caught
# by T147's credential scan). The key is never part of any evidence artefact.
( export AGENTIC_NETOPS_LLM_MODEL="$LLM2_MODEL" AGENTIC_NETOPS_LLM_API_KEY="$LLM2_API_KEY" \
    AGENTIC_NETOPS_LLM_BASE_URL="${LLM2_BASE_URL:-}" AGENTIC_NETOPS_LLM_GATEWAY="${LLM2_GATEWAY:-}" KUBE_CONTEXT
  evidence_run t144-merge-provider2 -- bash "$E2E_ROOT/scripts/lib/intent_secrets.sh" llm-provider ) || { echo "merge refused" >&2; exit 1; }
if [[ -z "${LLM2_BASE_URL:-}" ]]; then
  evidence_run t144-base-url-untouched --readiness -- bash -c "test '$(url_sha)' = '$P1_SHA' && echo 'stored base URL byte-identical (sha256 $P1_SHA)'" || rc=1
else
  want="$(printf '%s' "$LLM2_BASE_URL" | sha256sum | cut -d' ' -f1)"
  evidence_run t144-base-url-changed-explicitly -- bash -c "test '$(url_sha)' = '$want' && echo 'base URL changed explicitly to the second provider'\''s (sha256 $want)'" || rc=1
fi
fields provider2
wait_mounted "$LLM2_MODEL" || exit 1
corpora "${T144_PROVIDER2_LABEL:-${LLM2_MODEL%%/*}}"
echo "T144 two providers: exit ${rc} (evidence: ${EVIDENCE_DIR})"
exit "$rc"
