#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2086  # SC2086: SV_MANIFESTS is a space-separated list
# tests/integration/idempotence.sh — re-reconciling unchanged intent writes nothing (T064; SC-006,
# FR-100, NFR-013; contracts/reconciliation.md Rule 2).
#
# Behind `make test-idempotence`. With the example Networks Ready, snapshots
#   (a) the metadata.generation of every Config labelled with a Network in agentic-netops-services
#   (b) every leaf's device commit history, /system/configuration/commit (state)
# then forces a re-reconciliation of every Network (an annotation touch — no spec change) and waits
# SV_IDEM_WAIT (two reconciliation intervals plus one re-verification by default); asserts ZERO
# Config generation advance AND NO new device commit.
#
# Negative control first (NFR-013): the same comparison across a REAL intent change — one
# attachment (SV_IDEM_CONTROL_NODE ethernet-1/1, the Network's own VLAN) is added to SV_IDEM_NET
# (lab-vlan), so a Config appears or advances and a device commit lands, and the comparison MUST
# fail. (spec.description is not rendered to the device — the device description is derived from
# the service id — so patching it is itself a no-op and no control.) The original attachments are
# restored from an exit trap and the Network is Ready=True again before the baseline is taken.
#
# Usage: idempotence.sh
# Environment: EVIDENCE_DIR, CLUSTER_NAME, LAB_NAME, SRL_USER, SRL_PASS, SV_IDEM_WAIT (60 s),
#   SV_IDEM_NET (lab-vlan), SV_IDEM_CONTROL_NODE (leaf02), SV_WAIT (300 s), SV_MANIFESTS (the manifests whose Networks are
#   asserted; default examples/constructs/, space-separated).
set -euo pipefail

ID_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/services.sh
source "$ID_HERE/lib/services.sh"
# shellcheck source=../gate/lib/gate.sh
source "$SV_ROOT/tests/gate/lib/gate.sh"

: "${SV_IDEM_WAIT:=60}"
: "${SV_IDEM_NET:=lab-vlan}"
: "${SV_IDEM_CONTROL_NODE:=leaf02}"
: "${SV_WAIT:=300}"
ID_LIB="$ID_HERE/lib/services.sh"
ID_ORIG_ATT=""
ID_PATCHED=0

usage() { echo "usage: $0" >&2; return 2; }

# id::snapshot <file> — "<key> <value>" lines: config/<name> <generation>, commit/<leaf> <id-list>
id::snapshot() {
  local out="$1" leaf ids
  sv::k -n "$SV_SYS_NS" get "$SV_CONFIG_RES" -l "$SV_LBL_NS=$SV_NS" \
    -o jsonpath='{range .items[*]}config/{.metadata.name} {.metadata.generation}{"\n"}{end}' >"$out"
  for leaf in $(lab::leaves); do
    lab::gnmic_argv "$leaf" || return 1
    ids="$("${LAB_ARGV[@]}" get --type state --path /system/configuration/commit 2>/dev/null \
      | jq -r "$(lab::jq_lib)"' [gvalues[] | strip | (.commit // .configuration.commit // [.])[]? | .id // empty | tostring] | sort_by(tonumber? // .) | join(",")')" || return 1
    printf 'commit/%s %s\n' "$leaf" "${ids:-none}" >>"$out"
  done
}

id::touch() {
  local ns name stamp; stamp="$(date -u +%s)"
  while read -r ns name; do
    sv::k -n "${ns:-$SV_NS}" annotate --overwrite "$SV_NET_RES" "$name" "agentic-netops.io/idempotence-touch=${stamp}" >/dev/null
  done < <(sv::manifest_networks ${SV_MANIFESTS:-$SV_CONSTRUCTS})
}

id::restore() {
  [[ "$ID_PATCHED" == 1 ]] || return 0
  log::info "restoring ${SV_IDEM_NET} attachments (exit trap)"
  sv::k -n "$SV_NS" patch "$SV_NET_RES" "$SV_IDEM_NET" --type merge \
    -p "$(jq -nc --argjson a "$ID_ORIG_ATT" '{spec: {attachments: $a}}')" >/dev/null && ID_PATCHED=0
}
id::on_exit() { local st=$?; id::restore || { log::error "RESTORE FAILED: ${SV_IDEM_NET} attachments"; st=1; }; exit "$st"; }

main() {
  [[ $# -eq 0 ]] || { usage; return 2; }
  log::phase Idempotence
  gate::init
  local d="$EVIDENCE_DIR/idempotence" rc gen0
  mkdir -p "$d"
  # ---- negative control: a real change must be seen by the comparison
  ID_ORIG_ATT="$(sv::k -n "$SV_NS" get "$SV_NET_RES" "$SV_IDEM_NET" -o json | jq -c '.spec.attachments')" \
    || { log::error "Network ${SV_NS}/${SV_IDEM_NET} not found"; return 1; }
  CHECK_WAIT="$SV_WAIT" gate::run ID.pre-ready -- bash "$ID_LIB" condition "$SV_NS" "$SV_IDEM_NET" Ready True || { log::error "$SV_IDEM_NET not Ready"; return 1; }
  id::snapshot "$d/control-before.txt"
  trap id::on_exit EXIT
  trap 'exit 130' INT TERM
  ID_PATCHED=1
  gen0="$(sv::k -n "$SV_NS" get "$SV_NET_RES" "$SV_IDEM_NET" -o jsonpath='{.metadata.generation}')"
  gate::run ID.control.patch -- sv::k -n "$SV_NS" patch "$SV_NET_RES" "$SV_IDEM_NET" --type merge \
    -p "$(jq -nc --argjson a "$ID_ORIG_ATT" --arg n "$SV_IDEM_CONTROL_NODE" \
          '{spec: {attachments: ($a + [{node: $n, attachment: "ethernet-1/1", vlan: $a[0].vlan}])}}')"
  log::info "control: ${SV_IDEM_NET} generation ${gen0} -> $(sv::k -n "$SV_NS" get "$SV_NET_RES" "$SV_IDEM_NET" -o jsonpath='{.metadata.generation}')"
  # the change must reach the Config and the device before the comparison is taken (bounded);
  # a change that never lands leaves the snapshots equal and the control is reported defective
  local deadline=$(( $(date +%s) + SV_WAIT ))
  while :; do
    id::snapshot "$d/control-after.txt"
    sv::snapshot_diff "$d/control-before.txt" "$d/control-after.txt" >/dev/null || break
    [[ "$(date +%s)" -lt "$deadline" ]] || break
    sleep 5
  done
  rc=0; evidence_negative_control ID-unchanged --attach "idempotence/control-before.txt" --attach "idempotence/control-after.txt" -- \
    bash "$ID_LIB" snapshot_diff "$d/control-before.txt" "$d/control-after.txt" || rc=$?
  [[ "$rc" -eq 0 ]] || { log::error "ID-unchanged negative control did not fail across a real change (rc=$rc): the check is defective"; return 1; }
  id::restore
  CHECK_WAIT="$SV_WAIT" gate::run ID.restore.ready -- bash "$ID_LIB" condition "$SV_NS" "$SV_IDEM_NET" Ready True \
    || { log::error "$SV_IDEM_NET not Ready=True after restoring its attachments"; return 1; }
  # ---- the assertion
  local ns name
  while read -r ns name; do
    CHECK_WAIT="$SV_WAIT" gate::run "ID.ready.${name}" -- bash "$ID_LIB" condition "${ns:-$SV_NS}" "$name" Ready True \
      || { log::error "$name not Ready=True: idempotence is asserted on Ready services only"; return 1; }
  done < <(sv::manifest_networks ${SV_MANIFESTS:-$SV_CONSTRUCTS})
  id::snapshot "$d/before.txt"
  id::touch
  log::info "re-reconciliation forced (annotation touch); waiting ${SV_IDEM_WAIT}s"
  sleep "$SV_IDEM_WAIT"
  id::snapshot "$d/after.txt"
  rc=0; evidence_run ID.unchanged --check ID-unchanged --readiness --records SC-006 \
    --attach idempotence/before.txt --attach idempotence/after.txt -- \
    bash "$ID_LIB" snapshot_diff "$d/before.txt" "$d/after.txt" || rc=$?
  [[ "$rc" -eq 0 ]] && log::info "PASS zero Config generation advance and no new device commit over ${SV_IDEM_WAIT}s" \
    || { log::error "FAIL idempotence: Config generation advanced or a device commit landed (see above)"; return 1; }
}

main "$@"
