#!/usr/bin/env bash
# tests/integration/managed_drift.sh — drift on a managed path (T064; SC-007, FR-015, FR-108,
# AD-34, AD-66, R-48). Behind `make test-managed-drift`.
#
# It asserts exactly what gate item G13 observed to be assertable, read from
# tests/gate/observed/deviation.json (md::plan below), and nothing it did not:
#   - restoration: drift injected (a declared fault, recorded in declared-faults.json BEFORE it is
#     made, the run having started with leftovers::scan) on a path the service's priority-20 Config
#     owns — MD_PATH on MD_NODE, default the description of lab-macvrf's network-instance — is gone
#     and the intended value is read back from the device;
#   - the Deviation with reason NOT_APPLIED: asserted only where G13 found it durably visible
#     (assertable_by_managed_drift.deviation_not_applied); otherwise it is REPORTED, not asserted —
#     never an artefact G13 found the revertive policy reapplies away first;
#   - the terminal handling of OVERRULED (Applied=False/OwnershipConflict naming the path, no
#     reapply): asserted only if "OVERRULED" is among G13's reason_strings_seen; otherwise reported
#     as "not demonstrated live; envtest-covered" (T054), never as passed and never by inventing a
#     way to make one.
#
# Usage: managed_drift.sh run | plan [<deviation.json>]
# Environment: MD_NETWORK (lab-macvrf), MD_NODE (leaf01), MD_PATH, MD_WINDOW (180 s),
#   DEVIATION_OBSERVED (tests/gate/observed/deviation.json), plus suite.sh's.
set -euo pipefail

MD_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MD_ROOT="$(cd -- "$MD_HERE/../.." && pwd)"
: "${DEVIATION_OBSERVED:=$MD_ROOT/tests/gate/observed/deviation.json}"
: "${MD_NETWORK:=lab-macvrf}"
: "${MD_NODE:=leaf01}"
: "${MD_WINDOW:=180}"
MD_DRIFT="vt-scratch-drift"
MD_NOT_DEMONSTRATED="not demonstrated live; envtest-covered"

# md::plan <deviation.json> — what G13 recorded as assertable, one "<item> <mode>" per line:
#   restoration assert|not-assertable, deviation assert|report, overruled assert|not-demonstrated
md::plan() {
  local f="$1"
  [[ -r "$f" ]] || { echo "managed_drift: G13's observation $f is missing — run the gate first" >&2; return 2; }
  jq -er '
    if .schema != "agentic-netops.gate.deviation/v1" then error("unexpected schema \(.schema)") else . end
    | (.assertable_by_managed_drift // {}) as $a
    | "restoration \(if ($a.restoration // .restoration_observed // false) then "assert" else "not-assertable" end)",
      "deviation \(if ($a.deviation_not_applied // false) and (.deviation_visible_before_restore // false) then "assert" else "report" end)",
      "overruled \(if ((.reason_strings_seen // []) | index("OVERRULED")) != null then "assert" else "not-demonstrated" end)"' "$f"
}

md::mode() { awk -v k="$1" '$1 == k {print $2}' <<<"$MD_PLAN"; }

md::run() {
  # shellcheck source=lib/suite.sh
  source "$MD_HERE/lib/suite.sh"
  MD_PLAN="$(md::plan "$DEVIATION_OBSERVED")" || return $?
  suite::init managed-drift || return $?
  suite::refuse_on_leftovers managed-drift || return $?
  suite::intervals
  log::info "G13 plan: $(tr '\n' ';' <<<"$MD_PLAN")"
  local ni="macvrf-${MD_NETWORK}" path cfg intent rc id sum
  path="${MD_PATH:-/network-instance[name=${ni}]/description}"
  cfg="${MD_NETWORK}.${MD_NODE}"

  # the negative controls first: a value the device does not carry; a service never Ready
  suite::neg MD-ready cond "$SVC_NS" vt-scratch-never-ready 5 Ready=True || true
  gate::negative MD-restored value_equals "$MD_NODE" CONFIG "$path" "\"vt-scratch-absent\"" || true

  rc=0; suite::check MD.ready MD-ready --readiness -- cond "$SVC_NS" "$MD_NETWORK" "$((SUITE_REVERIFY_S + SUITE_RECONCILE_S))" Ready=True Applied=True || rc=$?
  [[ "$rc" -eq 0 ]] || { suite::fail "$MD_NETWORK is not Ready/Applied"; suite::finish managed-drift; return 1; }
  intent="$(bash "$GATE_CHECKS" value_equals "$MD_NODE" CONFIG "$path" '"-"' 2>/dev/null | sed -n 's/^read CONFIG .* = \(.*\) (want .*/\1/p' | tail -1 || true)"  # the read is a deliberately failing compare; only its 'read' line is used (pipefail)
  if [[ -z "$intent" || "$intent" == null ]]; then
    suite::fail "the managed path $path carries nothing on $MD_NODE — set MD_PATH to a leaf Config $cfg owns"
    suite::finish managed-drift; return 1
  fi
  log::info "managed path $path on $MD_NODE, intended value $intent (Config $LAB_TARGET_NS/$cfg)"

  leftovers::declare_fault "vt-scratch-md-drift" "$MD_NODE" "drift on the managed path $path ($MD_DRIFT)" \
    "$(jq -cn --arg n "$MD_NODE" --arg p "$path" --arg v "$MD_DRIFT" '{kind: "device-leaf", node: $n, path: $p, faulted_value: $v}')" \
    "$(jq -cn --argjson v "$intent" '{kind: "device-leaf-set", value: $v}')" || return 1
  rc=0; gate::dev "MD.drift" "$MD_NODE" set --delimiter "$LAB_SET_DELIM" --update "$(lab::upd "$path" "\"$MD_DRIFT\"")" >/dev/null || rc=$?
  suite::judge "$rc" "drift injected on $path" "the drift could not be injected on $path"
  id="$(gate::id MD.watch)"
  evidence_run "$id" --check MD-watch -- bash "$GATE_CHECKS" deviation_watch "$LAB_TARGET_NS" "$cfg" "$MD_NODE" "$path" "$intent" "$MD_WINDOW" >/dev/null 2>&1 || true
  sum="$(suite::summary "$id")"; [[ -n "$sum" ]] || sum="{}"

  # restoration, read back from the device with the injected value gone
  if [[ "$(md::mode restoration)" == assert ]]; then
    rc=0; CHECK_WAIT="$MD_WINDOW" evidence_run "$(gate::id MD.restored)" --check MD-restored --readiness --records SC-007:drift \
      -- bash "$GATE_CHECKS" value_equals "$MD_NODE" CONFIG "$path" "$intent" >/dev/null || rc=$?
    suite::judge "$rc" "restored to $intent on $MD_NODE (after $(jq -r '.time_to_restoration_seconds // "?"' <<<"$sum")s)" "$path not restored on $MD_NODE"
  else
    suite::fail "SC-007 not demonstrated: G13 recorded restoration as not assertable (never waived)"
  fi
  # the deviation: asserted or reported, as G13 recorded
  if [[ "$(md::mode deviation)" == assert ]]; then
    rc=0; jq -e '.deviation_visible_before_restore == true' <<<"$sum" >/dev/null || rc=$?
    suite::judge "$rc" "Deviation NOT_APPLIED recorded before restoration" "no NOT_APPLIED Deviation visible before restoration"
  else
    log::info "Deviation (reported, NOT asserted — G13 found it not durably visible): $(jq -c '{deviation_visible_before_restore, reason_strings_seen}' <<<"$sum")"
  fi
  # OVERRULED
  if [[ "$(md::mode overruled)" == assert ]]; then md::overruled "$path" "$cfg"
  else log::info "OVERRULED terminal handling: ${MD_NOT_DEMONSTRATED} (G13 recorded no OVERRULED reason on the pinned layer)"; fi
  suite::fields MD.outcome "$(jq -cn --arg p "$path" --arg plan "$MD_PLAN" --argjson s "$sum" --arg o "$(md::mode overruled)" --arg nd "$MD_NOT_DEMONSTRATED" \
    '{criterion: "SC-007", path: $p, g13_plan: ($plan | split("\n")), watch: $s,
      overruled: (if $o == "assert" then "asserted" else $nd end)}')"
  suite::finish managed-drift
}

# md::overruled <path> <config> — only reached when G13 recorded OVERRULED: a gate-owned scratch
# Config at a higher priority states another value on the service's path; the service must report
# Applied=False/OwnershipConflict naming the path, and its Config must not be rewritten.
md::overruled() {
  local path="$1" cfg="$2" name="vt-scratch-md-overrule" f rc gens
  f="$EVIDENCE_DIR/suite-manifests/${name}.json"; mkdir -p "${f%/*}"
  jq -n --arg n "$name" --arg ns "$LAB_TARGET_NS" --arg t "$MD_NODE" --arg p "${path%/*}" --arg l "${path##*/}" \
        --arg k "$LAB_GATE_LABEL_KEY" --arg v "$LAB_GATE_LABEL_VALUE" '
    {apiVersion: "config.sdcio.dev/v1alpha1", kind: "Config",
     metadata: {name: $n, namespace: $ns, labels: {($k): $v, "config.sdcio.dev/targetName": $t, "config.sdcio.dev/targetNamespace": $ns}},
     spec: {priority: 5, revertive: true, config: [{path: $p, value: {($l): "vt-scratch-overrule"}}]}}' >"$f"
  gens="$EVIDENCE_DIR/suite-manifests/md-gens.txt"
  bash "$SVC_CHECKS" gens "$LAB_TARGET_NS" "$SVC_NS" "$MD_NETWORK" >"$gens"
  suite::neg MD-overruled cond "$SVC_NS" "$MD_NETWORK" 5 "Applied=False/OwnershipConflict" || true
  suite::on_exit "gate::run MD.overrule-delete -- lab::kubectl -n '$LAB_TARGET_NS' delete configs.config.sdcio.dev '$name' --ignore-not-found --wait=true >/dev/null"
  gate::run "MD.overrule-apply" --attach "suite-manifests/${name}.json" -- lab::kubectl apply -f "$f" >/dev/null || { suite::fail "could not apply $name"; return 0; }
  rc=0; suite::check MD.overruled MD-overruled --readiness -- cond "$SVC_NS" "$MD_NETWORK" "$((SUITE_REVERIFY_S + 2 * SUITE_RECONCILE_S))" \
    "Applied=False/OwnershipConflict~${path##*/}" || rc=$?
  suite::judge "$rc" "OVERRULED handled terminally: Applied=False/OwnershipConflict naming the path" "no Applied=False/OwnershipConflict naming $path"
  sleep "$((2 * SUITE_RECONCILE_S))"
  rc=0; suite::check MD.no-reapply MD-no-reapply -- gens_equal "$gens" "$LAB_TARGET_NS" "$SVC_NS" "$MD_NETWORK" >/dev/null || rc=$?
  suite::judge "$rc" "no reapply of $cfg" "$cfg was rewritten after OVERRULED"
}

main() {
  case "${1:-}" in
    run) md::run ;;
    plan) md::plan "${2:-$DEVIATION_OBSERVED}" ;;
    *) echo "usage: $0 run | plan [<deviation.json>]" >&2; return 2 ;;
  esac
}

main "$@"
