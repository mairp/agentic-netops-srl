#!/usr/bin/env bash
# tests/gate/run_gate.sh — the capability gate, GateReady (T043, T045, T166; FR-004, FR-097,
# FR-108, NFR-013, SC-040, SC-049; quickstart.md §1; plan.md P0).
#
# Verification tooling under FR-108: it talks to the lab devices from the operator's host with the
# lab operator's credentials (SRL_USER/SRL_PASS, handed to gnmic through its environment only), every
# device call is run-captured (evidence_run), every scratch object is the gate's own, carries the
# vt-scratch- prefix (or the gate-owned label), is removed by the gate, and the removal is read back
# before the gate reports — so FabricReady never starts on a dirty device.
#
# Order:
#   0. leftovers::scan (tests/lib/leftovers.sh) FIRST — any leftover of an earlier, interrupted run
#      refuses the start, non-zero, naming the node and the leftover; nothing is cleaned silently
#   1. the stock negative controls of every selected item (negative_controls.sh) — before any
#      readiness pass can be admitted (evidence_run refuses one without its failing control)
#   2. G11 — its captured result from the AppsReady early run (g11-observations.json in this
#      EVIDENCE_DIR), or, when absent, tests/gate/g11_allocation_claim.sh is run now
#   3. G1 G2 G3 G10 G4(part A) G5 G13 — on the stock nodes
#   4. G8 FIRST of the fabric items: its scratch fabric (setup → pre → tenant → reflectors [+ G4
#      part B] → SC-004's negative control, the declared route-reflector client false, observed to
#      stop reflection (AD-77), with inter-as-vpn removal recorded as an observation → post), then,
#      ON that fabric, G6 G7 G9 G12, then G8's teardown with the removal read back against the
#      pre-gate snapshots
#   5. the three P0 qualifications (T166): slim_tls_keys.sh, otlp_shape.sh, vap_served.sh
#   6. the removal read back once more: leftovers::scan (no vt-scratch- object on any node, no
#      gate-labelled Config — G13's — or namespace in the cluster, no declared fault in place)
#   7. the gate record $EVIDENCE_DIR/gate-record.json (per item pass/fail, checks, observations,
#      properties, negative controls, qualifications, scans), itself run-captured
# A failed item is never skipped or weakened: every selected item runs and is recorded; the exit is
# non-zero naming every failed item. An item that cannot run because its prerequisite failed is
# recorded as failed, naming the prerequisite.
#
# Usage: run_gate.sh [--only G8[,G6,…]] [--no-qualifications] [--publish]
#   --only       run just these items (G4 G6 G7 G9 G12 bring G8 with them — they run on its fabric;
#                SLIM OTLP VAP select single qualifications). Their negative controls still run first.
#   --publish    run tests/gate/publish_qualification.sh on the record (provisioning does this)
# Environment: EVIDENCE_DIR, CLUSTER_NAME, LAB_NAME, SRL_USER, SRL_PASS, MGMT_CIDR, GATE_WAIT_*.
# Exit: 0 gate passed and record written; 1 gate failed (items named); 3 refused (leftover / setup).
set -euo pipefail

GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"
# shellcheck source=../lib/leftovers.sh
source "$GATE_REPO_ROOT/tests/lib/leftovers.sh"
for __f in "$GATE_HERE"/g0[1-9]_*.sh "$GATE_HERE"/g1[023]_*.sh; do
  # shellcheck disable=SC1090
  source "$__f"
done
# shellcheck source=negative_controls.sh
source "$GATE_HERE/negative_controls.sh"
# shellcheck source=lib/tree_hash.sh
source "$GATE_HERE/lib/tree_hash.sh"

ALL_ITEMS=(G1 G2 G3 G4 G5 G6 G7 G8 G9 G10 G11 G12 G13)
ALL_QUALS=(SLIM OTLP VAP)
declare -A QUAL_SCRIPT=([SLIM]=slim_tls_keys.sh [OTLP]=otlp_shape.sh [VAP]=vap_served.sh)
declare -A QUAL_NAME=([SLIM]=slim_tls_keys [OTLP]=otlp_shape [VAP]=vap_served)

only=""; with_quals=1; publish=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) only="${only:+$only,}${2:?--only needs items}"; shift 2 ;;
    --only=*) only="${only:+$only,}${1#--only=}"; shift ;;
    --no-qualifications) with_quals=0; shift ;;
    --publish) publish=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "run_gate: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

SEL=(); QSEL=()
if [[ -z "$only" ]]; then
  SEL=("${ALL_ITEMS[@]}")
  [[ "$with_quals" == 1 ]] && QSEL=("${ALL_QUALS[@]}")
else
  IFS=', ' read -r -a req <<<"${only^^}"
  for r in "${req[@]}"; do
    [[ -n "$r" ]] || continue
    if [[ " ${ALL_ITEMS[*]} " == *" $r "* ]]; then SEL+=("$r")
    elif [[ " ${ALL_QUALS[*]} " == *" $r "* ]]; then QSEL+=("$r")
    else echo "run_gate: unknown item '$r' (items: ${ALL_ITEMS[*]}; qualifications: ${ALL_QUALS[*]})" >&2; exit 2; fi
  done
  for r in G4 G6 G7 G9 G12; do
    if [[ " ${SEL[*]} " == *" $r "* && " ${SEL[*]} " != *" G8 "* ]]; then
      SEL+=(G8); echo "run_gate: $r runs on G8's scratch fabric — G8 added" >&2
    fi
  done
fi
selected() { [[ " ${SEL[*]} " == *" $1 "* ]]; }
GATE_SELECTED="${SEL[*]}"; export GATE_SELECTED

log::phase GateReady
gate::init || { log::error "gate: cannot start (evidence directory or SRL_PASS)"; exit 3; }
GATE_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log::info "capability gate: items [${SEL[*]}] qualifications [${QSEL[*]:-}] — evidence in $EVIDENCE_DIR"
log::info "lab ${LAB_NAME} (mgmt ${MGMT_CIDR}), cluster kind-${CLUSTER_NAME}, image $(evidence::device_image_digest 2>/dev/null || echo '?')"

# ---------------------------------------------------------------- the record

run_gate::record() {
  local result="$1" reason="${2:-}" rec="$EVIDENCE_DIR/gate-record.json" items_json="{}" f quals="{}" q
  for f in "$EVIDENCE_DIR"/gate/items/G*.json; do
    [[ -f "$f" ]] || continue
    items_json="$(jq -c --slurpfile i "$f" '. + {($i[0].item): $i[0]}' <<<"$items_json")"
  done
  for f in "$EVIDENCE_DIR"/gate/qualifications/*.json; do
    [[ -f "$f" ]] || continue
    q="$(basename "$f" .json)"
    quals="$(jq -c --arg q "$q" --slurpfile v "$f" '. + {($q): $v[0]}' <<<"$quals")"
  done
  local negs
  negs="$(for f in "$EVIDENCE_DIR"/*.negative-control*.json; do [[ -f "$f" ]] && jq -c '{check: .check_id, file: (.id + ".json"), failed_as_required: .negative_control_failed}' "$f"; done | jq -s -c '.')"
  jq -n -S --arg schema "agentic-netops.gate-record/v1" --arg result "$result" --arg reason "$reason" \
    --arg started "$GATE_STARTED" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg cluster "$CLUSTER_NAME" --arg lab "$LAB_NAME" --arg digest "$(evidence::device_image_digest 2>/dev/null || true)" \
    --arg dir "$EVIDENCE_DIR" --arg tree "$(gate::tree_hash "$GATE_REPO_ROOT")" --argjson sel "$(printf '%s\n' "${SEL[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
    --argjson items "$items_json" --argjson quals "$quals" --argjson negs "$negs" \
    --argjson scans "$(jq -c . "$EVIDENCE_DIR/gate/scans.json" 2>/dev/null || echo '{}')" \
    '{schema: $schema, result: $result, reason: (if $reason == "" then null else $reason end),
      started_utc: $started, finished_utc: $finished,
      cluster: $cluster, lab: $lab, device_image_digest: $digest, evidence_dir: $dir,
      gate_tree_sha256: $tree,
      items_selected: $sel,
      failed_items: ([$items[] | select(.status != "pass") | .item] | sort_by(ltrimstr("G") | tonumber? // 99)),
      items: $items, qualifications: $quals,
      failed_qualifications: [$quals | to_entries[] | select(.value.status != "pass") | .key],
      negative_controls: $negs, leftover_scans: $scans}' >"$rec"
  printf '%s' "$rec"
}

# run_gate::seal — one final run-captured record attaching (hashing) every artefact the gate wrote
# into EVIDENCE_DIR that no record references yet: the gate record, the item files, snapshots,
# manifests, observation copies, declared-faults.json, scans. make verify-evidence admits nothing
# unreferenced (NFR-013), and after this nothing the gate wrote is.
run_gate::seal() {
  local -a att=()
  local f
  while read -r f; do
    [[ -n "$f" ]] && att+=(--attach "$f")
  done < <(python3 - "$EVIDENCE_DIR" <<'PY'
import json, os, sys
d = sys.argv[1]
ref, files = set(), set()
for base, _, names in os.walk(d):
    for n in names:
        files.add(os.path.relpath(os.path.join(base, n), d))
for f in files:
    if not f.endswith(".json"):
        continue
    try:
        r = json.load(open(os.path.join(d, f)))
    except Exception:
        continue
    if isinstance(r, dict) and r.get("schema") == "agentic-netops.evidence/v1":
        ref.add(f)
        for k in ("stdout", "stderr"):
            v = (r.get("raw_output") or {}).get(k) or {}
            if v.get("file"):
                ref.add(os.path.join(os.path.dirname(f), v["file"]))
        for a in r.get("attachments") or []:
            ref.add(a.get("file"))
for f in sorted(files - ref):
    print(f)
PY
)
  evidence_run "$(gate::id gate-record)" "${att[@]}" -- jq -e '.result == "pass"' "$EVIDENCE_DIR/gate-record.json" >/dev/null 2>&1 || true
}

run_gate::scan() { # <when> — leftovers::scan, captured into gate/scans.json
  local when="$1" out rc=0 f="$EVIDENCE_DIR/gate/scans.json" tmp
  out="$(leftovers::scan 2>&1)" || rc=$?
  printf '%s\n' "$out" >"$EVIDENCE_DIR/gate/leftover-scan-${when}.txt"
  [[ -f "$f" ]] || echo '{}' >"$f"
  tmp="$(mktemp)"
  jq --arg w "$when" --argjson rc "$rc" --arg out "$(grep '^LEFTOVER' <<<"$out" || true)" \
    '.[$w] = {clean: ($rc == 0), leftovers: ($out | split("\n") | map(select(length > 0)))}' "$f" >"$tmp" && mv "$tmp" "$f"
  printf '%s\n' "$out" >&2
  return "$rc"
}

# ---------------------------------------------------------------- 0. the leftover scan, FIRST

if ! run_gate::scan before; then
  log::error "gate REFUSED to start: leftovers of an earlier run are present (listed above)."
  log::error "Nothing was touched. Read the list, then run the explicit clean-up: source tests/lib/leftovers.sh; leftovers::remove [--snapshots <dead-run>/gate/scratch]"
  rec="$(run_gate::record refused "leftover scan found leftovers")"
  run_gate::seal
  log::error "gate record: $rec"
  exit 3
fi

# ---------------------------------------------------------------- cleanup on any exit

G13_UP="${G13_UP:-0}"; G7_UP="${G7_UP:-0}"; G8_SETUP="${G8_SETUP:-0}"; QUAL_RUNNING=""
# shellcheck disable=SC2317  # invoked by the EXIT trap
run_gate::cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ "$G13_UP" == 1 ]]; then log::warn "exit trap: removing G13's gate-owned Config"; gate::item_resume G13; g13::remove || true; fi
  if [[ "$G7_UP" == 1 ]]; then log::warn "exit trap: removing G7's scratch namespace"; g07::teardown || true; fi
  if [[ "$G8_SETUP" == 1 ]]; then log::warn "exit trap: tearing down G8's scratch fabric"; g08::teardown || true; fi
  if [[ -n "$QUAL_RUNNING" ]]; then
    log::warn "exit trap: removing the qualification scratch namespaces"
    lab::kubectl delete namespaces -l "$LAB_GATE_SELECTOR" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap run_gate::cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- 1. stock negative controls

log::info "negative controls: every readiness check of [${SEL[*]}] against the stock lab — each must FAIL (T045)"
negctl::stock "${SEL[@]}" || log::warn "some negative controls were not recorded; the checks they guard will be refused (and fail)"

# ---------------------------------------------------------------- 2. G11

g11::collect() {
  gate::item_begin G11 "Allocation claim round-trip against the allocation authority (observations a–f)"
  local res="$EVIDENCE_DIR/g11-observations.json" source="AppsReady early run" rc
  if [[ ! -f "$res" && -n "${G11_EVIDENCE_DIR:-}" && -f "$G11_EVIDENCE_DIR/g11-observations.json" ]]; then
    res="$G11_EVIDENCE_DIR/g11-observations.json"; source="AppsReady early run ($G11_EVIDENCE_DIR)"
  fi
  if [[ ! -f "$res" ]]; then
    source="run by the gate (no early result in this EVIDENCE_DIR)"
    rc=0; bash "$GATE_HERE/g11_allocation_claim.sh" || rc=$?
    gate::item_check "g11-run" "$rc" "tests/gate/g11_allocation_claim.sh exit $rc" ""
  fi
  if [[ -f "$res" ]]; then
    rc=0; jq -e '.result == "pass"' "$res" >/dev/null || rc=1
    gate::item_check "round-trip-and-observations" "$rc" "g11-observations.json result=$(jq -r .result "$res") ($source)$(jq -r 'if (.failures // []) | length > 0 then "; failures: " + (.failures | join("; ")) else "" end' "$res")" ""
    gate::item_observe g11_observations "$(jq -c . "$res")"
    gate::item_observe source "\"$source\""
  else
    gate::item_check "round-trip-and-observations" 1 "no G11 result was produced ($source)" ""
  fi
  gate::item_end
}

run_gate::prereq_failed() { # <item> <title> <reason>
  gate::item_begin "$1" "$2"
  gate::item_check "prerequisite" 1 "$3" ""
  gate::item_end || true
}

selected G11 && { g11::collect || true; }

# ---------------------------------------------------------------- 3. stock-node items

selected G1  && { g01::run || true; }
selected G2  && { g02::run || true; }
selected G3  && { g03::run || true; }
selected G10 && { g10::run || true; }
selected G4  && { g04::run || true; }
selected G5  && { g05::run || true; }
selected G13 && { g13::run || true; }

# ---------------------------------------------------------------- 4. G8 first, then on its fabric

if selected G8; then
  if g08::setup; then
    g08::pre || true
    g08::tenant || true
    g08::reflectors || true
    g08::negative || true
    g08::post || true
    GATE_ITEM=G8
    selected G6  && { g06::run || true; }
    selected G7  && { g07::run || true; }
    selected G9  && { g09::run || true; }
    selected G12 && { g12::run || true; }
  else
    for i in G6 G7 G9 G12; do
      selected "$i" && run_gate::prereq_failed "$i" "$i (runs on G8's scratch fabric)" "not run: G8's scratch fabric was refused — a device is not a stock node (see G8)"
    done
    if selected G4; then
      gate::item_resume G4; gate::item_check "config-only-leaves-config" 1 "not run: G8's scratch reflectors were refused (see G8)" ""; gate::item_end || true
    fi
  fi
  g08::teardown || true
fi

# ---------------------------------------------------------------- 5. the P0 qualifications (T166)

mkdir -p "$EVIDENCE_DIR/gate/qualifications"
for q in "${QSEL[@]}"; do
  QUAL_RUNNING="$q"
  log::info "=== qualification ${q}: ${QUAL_SCRIPT[$q]}"
  rc=0; bash "$GATE_HERE/${QUAL_SCRIPT[$q]}" || rc=$?
  if [[ ! -f "$EVIDENCE_DIR/gate/qualifications/${QUAL_NAME[$q]}.json" ]]; then
    jq -n --arg n "${QUAL_NAME[$q]}" --argjson rc "$rc" '{name: $n, status: "fail", reason: "the qualification script produced no result (exit \($rc))"}' \
      >"$EVIDENCE_DIR/gate/qualifications/${QUAL_NAME[$q]}.json"
  fi
  QUAL_RUNNING=""
done

# ---------------------------------------------------------------- 6. removal read back

removal_ok=1
if ! run_gate::scan after; then
  removal_ok=0
  log::error "removal read-back FAILED: gate scratch is still present (listed above) — FabricReady must not start"
fi

# ---------------------------------------------------------------- 7. the record

result=pass; reason=""
failed="$(for f in "$EVIDENCE_DIR"/gate/items/G*.json; do [[ -f "$f" ]] || continue; jq -r 'select(.status != "pass") | .item' "$f"; done | sort -V | paste -sd' ' -)"
qfailed="$(for f in "$EVIDENCE_DIR"/gate/qualifications/*.json; do [[ -f "$f" ]] || continue; jq -r --arg n "$(basename "$f" .json)" 'select(.status != "pass") | $n' "$f"; done | paste -sd' ' -)"
if [[ -n "$failed" || -n "$qfailed" || "$removal_ok" == 0 ]]; then
  result=fail
  reason="failed:${failed:+ items $failed}${qfailed:+ qualifications $qfailed}$([[ "$removal_ok" == 0 ]] && echo ' removal-readback')"
fi
rec="$(run_gate::record "$result" "$reason")"
run_gate::seal

log::info "------------------------------------------------------------ gate summary"
jq -r '.items | to_entries | sort_by(.key | ltrimstr("G") | tonumber? // 99)[]
       | "\(.key)\t\(.value.status | ascii_upcase)\t\(.value.title)\(if (.value.failed_checks // []) | length > 0 then "\n\tfailed: " + (.value.failed_checks | join(", ")) else "" end)"' "$rec" >&2
jq -r '.qualifications | to_entries[] | "\(.key)\t\(.value.status | ascii_upcase)"' "$rec" >&2
log::info "gate record: $rec"

if [[ "$publish" == 1 ]]; then
  bash "$GATE_HERE/publish_qualification.sh" --record "$rec" || { log::error "publishing the qualification record failed"; result=fail; }
fi

if [[ "$result" != pass ]]; then
  log::error "GATE FAILED — ${reason}"
  exit 1
fi
log::info "GATE PASSED — every selected item and qualification passed; scratch removed and read back"
exit 0
