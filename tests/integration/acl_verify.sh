#!/usr/bin/env bash
# tests/integration/acl_verify.sh — per-node KEYED read-back of every access list of the given
# Networks: the written side (running/CONFIG) and the applied side (STATE), read directly from the
# device (T114; quickstart.md §12 "Device-level assertions"; contracts/acl-render-contract.md §4;
# SC-014, SC-040, FR-042, FR-100, NFR-013; AD-82 decision 2026-09-21-acl-binding-state).
#
# Behind `make verify-acl`. For each Network (default: the examples lab-macvrf-acl and lab-acl in
# agentic-netops-services), for every spec.accessLists[] entry and every node it binds on:
#   AV-written   C1–C4, C7 (running): filter acl-<serviceId>-<stage> of the declared type exists;
#                its entries read in ascending sequence-id order, the sequence-ids equal the declared
#                priorities (+65535 exactly when defaultAction is declared); each entry's action and
#                match fields as declared; statistics-per-entry true; output-only on egress
#   AV-binding   C5/C6 (running): /acl/interface[interface-id=<port>.<vlan|0>] carries interface-ref
#                {port, index} and the filter under the declared direction (25.7.1 mirrors nothing of
#                /acl/interface into state, so the binding is judged here)
#   AV-applied   A1–A3 (state): tests/gate/lib/checks.sh acl_applied — each entry's TCAM on the bound
#                direction (input-total or output-total > 0) and 0 on the other, programming complete
#   AV-stats     A5 (state): per-entry statistics readable, incomplete not true
#   AV-ready     the Network's Ready condition (reported; Ready=True is required)
#   AV-programmed G1 (state): programming-complete on every forwarding complex, once per node before
#                the per-filter checks — a node-wide gate, not evidence of any service, so it is
#                recorded (evidence_run) but carries no negative control (a stock node is complete too)
# A4 (the binding APPLIED, counters moved by traffic) is acceptance, not readiness: see
# acl_enforcement_probe.sh.
#
# NEGATIVE CONTROL FIRST (NFR-013, SC-040, §4.5): before any positive run, each keyed check is run
#   (a) against the stock node (AV_STOCK_NODE, spine01 — it carries only its own `cpm` filters) with
#       the real filter, binding and entries, and
#   (b) on the leaf, with a filter name that does not exist (AV_ABSENT_FILTER),
# through evidence_negative_control; each MUST fail. A control that passes (the check is defective)
# or cannot be recorded refuses the run (exit 3) before any pass is admitted; every positive run is
# `evidence_run --readiness`, which the evidence layer itself refuses without the failing control.
# Read-only: nothing is written to any device or object.
#
# Usage: acl_verify.sh [<namespace>/<name>…]
# Environment: EVIDENCE_DIR, CLUSTER_NAME, LAB_NAME, SRL_USER, SRL_PASS (required), AV_STOCK_NODE
#   (spine01), AV_ABSENT_FILTER (acl-does-not-exist-ingress), AV_WAIT (60 s: the re-read window of
#   a positive check), AV_NEG_WAIT (10 s: the same window for a control, in its argv).
# Exit: 0 every check passed; 1 a check failed (named); 2 usage; 3 refused (a control passed or
#   was not recorded, a Network unreadable or carrying no access list, no credentials).
set -euo pipefail

AV_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AV_ROOT="$(cd -- "$AV_HERE/../.." && pwd)"
AV_SELF="$AV_HERE/$(basename -- "${BASH_SOURCE[0]}")"
AV_LIB="$AV_HERE/lib/acl.sh"
AV_SV="$AV_HERE/lib/services.sh"
AV_CHECKS="$AV_ROOT/tests/gate/lib/checks.sh"
# shellcheck source=lib/acl.sh
source "$AV_LIB"
# shellcheck source=../../scripts/lib/log.sh
source "$AV_ROOT/scripts/lib/log.sh"
# shellcheck source=../../scripts/lib/evidence.sh
source "$AV_ROOT/scripts/lib/evidence.sh"
LOG_PHASE="${LOG_PHASE:-verify-acl}"

: "${AV_STOCK_NODE:=spine01}"
: "${AV_ABSENT_FILTER:=acl-does-not-exist-ingress}"
: "${AV_WAIT:=60}"
: "${AV_NEG_WAIT:=10}"
AV_DEFAULT_NETWORKS="agentic-netops-services/lab-macvrf-acl agentic-netops-services/lab-acl"
AV_FAILS=()
AV_PLAN=""   # "<ns>/<name>\t<acl::plan row>" per (network, list, attachment)

usage() { sed -n '/^# Usage:/,/^set -euo/p' "$AV_SELF" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }
av::fail() { AV_FAILS+=("$1"); log::error "FAIL $1"; }
av::ok()   { log::info "PASS $1"; }
av::id() {  # a fresh evidence id from a stem (interface names carry '/')
  local stem id n=1
  stem="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
  id="$stem"
  while [[ -e "$EVIDENCE_DIR/$id.json" ]]; do n=$((n + 1)); id="${stem}-${n}"; done
  printf '%s' "$id"
}

# av::neg <check-id> <what> -- <cmd…>: a control that MUST fail; a pass refuses the run
av::neg() {
  local chk="$1" what="$2" rc=0; shift 3
  evidence_negative_control "$chk" -- "$@" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) log::info "negative control $chk failed as it must: $what" ;;
    4) log::error "negative control $chk PASSED ($what): the check is defective — no pass of it is admitted"; return 3 ;;
    *) log::error "negative control $chk could not be recorded (exit $rc): $what"; return 3 ;;
  esac
}

# av::chk <check-id> <what> <stem> -- <cmd…>: a readiness-flagged, run-captured pass
av::chk() {
  local chk="$1" what="$2" id; id="$(av::id "$3")"; shift 4
  if evidence_run "$id" --check "$chk" --readiness --records SC-014 -- "$@" >/dev/null 2>&1; then
    av::ok "$what"
  else
    av::fail "$what [evidence $id]"
    grep '^CHECK ' "$EVIDENCE_DIR/${id}.stdout" 2>/dev/null | tail -n 2 | sed 's/^/    | /' >&2 || true
  fi
}

av::load() {
  local ref ns name nj id row
  for ref in "$@"; do
    ns="${ref%%/*}"; name="${ref#*/}"
    id="$(av::id "AV.network.${ns}.${name}")"
    if ! nj="$(evidence_run "$id" -- lab::kubectl -n "$ns" get "$ACL_NET_RES" "$name" -o json 2>/dev/null)"; then
      log::error "Network $ref is not readable (evidence $id)"; return 3
    fi
    local rows; rows="$(acl::plan "$nj")"
    if [[ -z "$rows" ]]; then log::error "Network $ref carries no spec.accessLists[] with attachments"; return 3; fi
    while IFS= read -r row; do AV_PLAN+="${ref}"$'\t'"${row}"$'\n'; done <<<"$rows"
    log::info "Network $ref: $(cut -f1,2,3,5,6 <<<"$rows" | tr '\t' ' ' | tr '\n' ';')"
  done
}

# av::controls — every keyed check fails on the stock node and for a filter that does not exist
av::controls() {
  log::phase VerifyACLNegativeControls
  local ref node f t _st dir ifid seqs exp ns
  IFS=$'\t' read -r ref node f t _st dir ifid seqs exp <<<"$(head -1 <<<"$AV_PLAN")"
  ns="${ref%%/*}"
  local s="$AV_STOCK_NODE" x="$AV_ABSENT_FILTER"
  av::neg AV-written "stock $s ${f}/${t}" -- env CHECK_WAIT="$AV_NEG_WAIT" bash "$AV_LIB" written "$s" "$f" "$t" "$exp" || return 3
  av::neg AV-written "$node ${x}/${t}"   -- env CHECK_WAIT="$AV_NEG_WAIT" bash "$AV_LIB" written "$node" "$x" "$t" "$exp" || return 3
  av::neg AV-binding "stock $s $ifid $dir ${f}/${t}" -- env CHECK_WAIT="$AV_NEG_WAIT" bash "$AV_LIB" binding "$s" "$ifid" "$dir" "$f" "$t" || return 3
  av::neg AV-binding "$node $ifid $dir ${x}/${t}"   -- env CHECK_WAIT="$AV_NEG_WAIT" bash "$AV_LIB" binding "$node" "$ifid" "$dir" "$x" "$t" || return 3
  av::neg AV-applied "stock $s ${f}/${t} $dir"      -- env CHECK_WAIT="$AV_NEG_WAIT" bash "$AV_CHECKS" acl_applied "$s" "$f" "$t" "$ifid" "$dir" "$seqs" || return 3
  av::neg AV-applied "$node ${x}/${t} $dir"         -- env CHECK_WAIT="$AV_NEG_WAIT" bash "$AV_CHECKS" acl_applied "$node" "$x" "$t" "$ifid" "$dir" "$seqs" || return 3
  av::neg AV-stats "stock $s ${f}/${t} entries $seqs" -- env CHECK_WAIT="$AV_NEG_WAIT" bash "$AV_LIB" stats "$s" "$f" "$t" "$seqs" || return 3
  av::neg AV-stats "$node ${x}/${t} entries $seqs"    -- env CHECK_WAIT="$AV_NEG_WAIT" bash "$AV_LIB" stats "$node" "$x" "$t" "$seqs" || return 3
  av::neg AV-ready "a Network that does not exist"   -- env CHECK_WAIT=0 bash "$AV_SV" condition "$ns" acl-does-not-exist Ready True || return 3
}

av::positive() {
  log::phase VerifyACL
  local ref node f t _st dir ifid seqs exp n seen=" "
  # G1 once per node, before the per-filter checks
  # shellcheck disable=SC2013 # node names are words
  for n in $(cut -f2 <<<"$AV_PLAN" | sort -u); do
    local id; id="$(av::id "AV.programmed.${n}")"
    if evidence_run "$id" --check AV-programmed -- env CHECK_WAIT="$AV_WAIT" bash "$AV_LIB" programmed "$n" >/dev/null 2>&1; then
      av::ok "$n: ACL programming complete (G1)"
    else av::fail "$n: ACL programming not complete (G1) [evidence $id]"; fi
  done
  while IFS=$'\t' read -r ref node f t _st dir ifid seqs exp; do
    [[ -n "$ref" ]] || continue
    if [[ "$seen" != *" ${node}/${f}/${t} "* ]]; then
      seen+="${node}/${f}/${t} "
      av::chk AV-written "$ref $node ${f}/${t}: entries ${seqs} in declared order, actions and matches as declared (running)" \
        "AV.written.${node}.${f}.${t}" -- env CHECK_WAIT="$AV_WAIT" bash "$AV_LIB" written "$node" "$f" "$t" "$exp"
      av::chk AV-stats "$ref $node ${f}/${t}: per-entry statistics readable, none incomplete (A5)" \
        "AV.stats.${node}.${f}.${t}" -- env CHECK_WAIT="$AV_WAIT" bash "$AV_LIB" stats "$node" "$f" "$t" "$seqs"
    fi
    av::chk AV-binding "$ref $node ${ifid} ${dir} ${f}/${t} with interface-ref (running, C5/C6)" \
      "AV.binding.${node}.${ifid}.${dir}.${f}" -- env CHECK_WAIT="$AV_WAIT" bash "$AV_LIB" binding "$node" "$ifid" "$dir" "$f" "$t"
    av::chk AV-applied "$ref $node ${f}/${t} entries ${seqs}: TCAM on ${dir} only, programming complete (A1–A3)" \
      "AV.applied.${node}.${ifid}.${dir}.${f}" -- env CHECK_WAIT="$AV_WAIT" bash "$AV_CHECKS" acl_applied "$node" "$f" "$t" "$ifid" "$dir" "$seqs"
  done <<<"$AV_PLAN"
}

av::ready() {
  local ref id line
  for ref in "$@"; do
    id="$(av::id "AV.ready.${ref%%/*}.${ref#*/}")"
    if evidence_run "$id" --check AV-ready --readiness -- env CHECK_WAIT="$AV_WAIT" bash "$AV_SV" condition "${ref%%/*}" "${ref#*/}" Ready True >/dev/null 2>&1; then
      av::ok "$ref Ready=True"
    else av::fail "$ref is not Ready=True [evidence $id]"; fi
    line="$(grep -E '^Ready' "$EVIDENCE_DIR/${id}.stdout" 2>/dev/null | tail -1)"
    log::info "$ref reports ${line:-no Ready condition}"
  done
}

main() {
  local -a nets=()
  local a
  for a in "$@"; do
    case "$a" in
      -h|--help|help) usage ;;
      -*) usage ;;
    esac
    [[ "$a" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?/[a-z0-9]([-.a-z0-9]*[a-z0-9])?$ ]] || usage
    nets+=("$a")
  done
  [[ ${#nets[@]} -gt 0 ]] || read -r -a nets <<<"$AV_DEFAULT_NETWORKS"
  evidence::ensure_dir || return 3
  lab::export_creds || return 3
  av::load "${nets[@]}" || return 3
  av::controls || { log::error "verify-acl REFUSED: a negative control passed or was not recorded (evidence: $EVIDENCE_DIR)"; return 3; }
  av::positive
  av::ready "${nets[@]}"
  if [[ ${#AV_FAILS[@]} -gt 0 ]]; then
    log::error "verify-acl FAILED (${#AV_FAILS[@]}): ${AV_FAILS[*]}"
    return 1
  fi
  log::info "verify-acl passed for ${nets[*]} (evidence: $EVIDENCE_DIR)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
