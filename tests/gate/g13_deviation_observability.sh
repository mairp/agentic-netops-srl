#!/usr/bin/env bash
# tests/gate/g13_deviation_observability.sh — G13: what a managed-path deviation leaves OBSERVABLE
# under the revertive drift policy the platform runs (T043; AD-34, AD-48; research Open item 18,
# R-48; FR-108's named exception to FR-013).
#
# A gate-owned scratch Config is applied THROUGH the device-configuration layer, because that
# layer's behaviour is what is observed:
#   name vt-scratch-g13-<node>, label agentic-netops.io/gate-owned=true (so a label selector finds a
#   leftover), priority 5, spec.revertive:
#   true stated by the Config itself, on /interface[name=ethernet-1/55]/description — a path no
#   fabric or service renders (an unused port's description).
#   Priority 5 is neither the fabric band (10) nor the service band (20): no platform Config uses it.
# Drift is injected on that path with gnmic (declared first in declared-faults.json, drift class of
# FR-108: the platform restores it and the tool reads the restoration back rather than removing
# anything). Then the Config's Deviation (config-<name>) and the device value are polled every
# second: whether a Deviation with reason NOT_APPLIED becomes visible before the layer reapplies,
# the reason strings seen, and the time to restoration are written to the tracked
# tests/gate/observed/deviation.json, which T064's managed_drift.sh asserts against.
# G13 RECORDS WHAT IT SAW and fails on neither answer — only an unobservable deviation AND an
# unobserved restoration is a failure. Removal is read back both ways: the Config (and its
# Deviation) gone from the cluster, its content gone from the node's running datastore.
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then exec bash "$GATE_HERE/run_gate.sh" --only G13 "$@"; fi
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"
# shellcheck source=../lib/leftovers.sh
source "$GATE_REPO_ROOT/tests/lib/leftovers.sh"

: "${G13_NODE:=leaf01}"
: "${G13_PORT:=ethernet-1/55}"
: "${G13_PRIORITY:=5}"
: "${G13_WINDOW:=180}"
G13_INTENT="vt-scratch-g13-intent"
G13_DRIFT="vt-scratch-g13-drift"
G13_UP=0

g13::name() { printf 'vt-scratch-g13-%s' "$G13_NODE"; }

g13::manifest() {
  local f
  f="$(gate::manifest g13-config.json)"
  jq -n --arg n "$(g13::name)" --arg ns "$G13_TARGET_NS" --arg t "$G13_TARGET" \
    --arg k "$LAB_GATE_LABEL_KEY" --arg v "$LAB_GATE_LABEL_VALUE" --argjson p "$G13_PRIORITY" \
    --arg port "$G13_PORT" --arg d "$G13_INTENT" \
    '{apiVersion: "config.sdcio.dev/v1alpha1", kind: "Config",
      metadata: {name: $n, namespace: $ns,
                 labels: {($k): $v, "config.sdcio.dev/targetName": $t, "config.sdcio.dev/targetNamespace": $ns}},
      spec: {priority: $p, revertive: true,
             config: [{path: "/", value: {interface: [{name: $port, description: $d}]}}]}}' >"$f"
  printf '%s' "$f"
}

# g13::remove — the Config deleted and the removal read back in the cluster and on the node
g13::remove() {
  local rc=0 name ns
  [[ "$G13_UP" == 1 ]] || return 0
  name="$(g13::name)"; ns="$G13_TARGET_NS"
  gate::run "G13.delete" -- lab::kubectl -n "$ns" delete configs.config.sdcio.dev "$name" --ignore-not-found --wait=true --timeout=120s >/dev/null || rc=$?
  gate::item_check "config-deleted" "$rc" "gate-owned Config $ns/$name deleted"
  rc=0; gate::run "G13.gone-from-cluster" -- sh -c "for i in \$(seq 1 60); do ${KUBECTL:-kubectl} --context ${KUBE_CONTEXT:-kind-${CLUSTER_NAME}} -n $ns get configs.config.sdcio.dev $name >/dev/null 2>&1 || exit 0; sleep 2; done; exit 1" >/dev/null || rc=$?
  gate::item_check "config-gone-from-cluster" "$rc" "the Config reads back NotFound"
  rc=0; gate::run "G13.deviation-gone" -- sh -c "for i in \$(seq 1 60); do ${KUBECTL:-kubectl} --context ${KUBE_CONTEXT:-kind-${CLUSTER_NAME}} -n $ns get deviations.config.sdcio.dev config-$name >/dev/null 2>&1 || exit 0; sleep 2; done; exit 1" >/dev/null || rc=$?
  gate::item_check "deviation-gone-from-cluster" "$rc" "its Deviation config-$name reads back NotFound"
  rc=0; CHECK_WAIT=60 gate::record "G13.content-gone" G13-intent-on-device absent "$G13_NODE" CONFIG "/interface[name=${G13_PORT}]/description" || rc=$?
  gate::item_check "content-gone-from-node" "$rc" "the Config's content is gone from ${G13_NODE}'s running datastore"
  # an interface entry the layer created and left empty is the gate's to remove
  if [[ "$G13_PORT_PRE_ABSENT" == 1 ]] && ! gate::pre_absent "$G13_NODE" "/interface[name=${G13_PORT}]"; then
    gate::item_observe layer_left_empty_list_entry true
    rc=0; gate::dev "G13.entry-remove" "$G13_NODE" set --delete "/interface[name=${G13_PORT}]" >/dev/null || rc=$?
    gate::item_check "empty-entry-removed" "$rc" "the empty /interface[name=${G13_PORT}] entry the layer left is removed"
  fi
  G13_UP=0
}

g13::run() {
  gate::item_begin G13 "What a managed-path deviation leaves observable under the revertive policy"
  local t rc path out summary
  path="/interface[name=${G13_PORT}]/description"
  t="$(gate::target_of "$G13_NODE")" || t=""
  if [[ -z "$t" ]]; then
    gate::item_check "target-resolved" 1 "no SDC Target found for $G13_NODE" ""; gate::item_end; return 1
  fi
  G13_TARGET_NS="${t%% *}"; G13_TARGET="${t##* }"
  G13_PORT_PRE_ABSENT=0; gate::pre_absent "$G13_NODE" "/interface[name=${G13_PORT}]" && G13_PORT_PRE_ABSENT=1

  G13_UP=1
  rc=0; gate::run "G13.apply" --attach gate/manifests/g13-config.json -- lab::kubectl create -f "$(g13::manifest)" >/dev/null || rc=$?
  gate::item_check "config-created" "$rc" "gate-owned Config $(g13::name) (priority ${G13_PRIORITY}, revertive true, label ${LAB_GATE_SELECTOR}) created in $G13_TARGET_NS"
  rc=0; gate::run "G13.ready" -- lab::kubectl -n "$G13_TARGET_NS" wait --for=condition=Ready "configs.config.sdcio.dev/$(g13::name)" --timeout=180s >/dev/null || rc=$?
  gate::item_check "config-ready" "$rc" "the Config reports Ready"
  rc=0; CHECK_WAIT=60 gate::ready "G13.intent" G13-intent-on-device value_equals "$G13_NODE" CONFIG "$path" "\"$G13_INTENT\"" || rc=$?
  gate::item_check "intent-on-device" "$rc" "the device carries the Config's intent"

  # declared BEFORE it is made (FR-108)
  leftovers::declare_fault "vt-scratch-g13-drift" "$G13_NODE" "drift on the gate-owned path $path (${G13_DRIFT})" \
    "$(jq -cn --arg n "$G13_NODE" --arg p "$path" --arg v "$G13_DRIFT" '{kind: "device-leaf", node: $n, path: $p, faulted_value: $v}')" \
    "$(jq -cn --arg v "$G13_INTENT" '{kind: "device-leaf-set", value: $v}')"
  rc=0; gate::dev "G13.drift" "$G13_NODE" set --delimiter "$LAB_SET_DELIM" --update "$(lab::upd "$path" "\"$G13_DRIFT\"")" >/dev/null || rc=$?
  gate::item_check "drift-injected" "$rc" "drift injected with gnmic on $path"
  local eid; eid="$(gate::id G13.watch)"
  rc=0; out="$(evidence_run "$eid" --check G13-deviation-watch -- bash "$GATE_CHECKS" deviation_watch \
          "$G13_TARGET_NS" "$(g13::name)" "$G13_NODE" "$path" "\"$G13_INTENT\"" "$G13_WINDOW" 2>/dev/null)" || rc=$?
  summary="$(sed -n 's/^SUMMARY //p' <<<"$out" | tail -1)"
  [[ -n "$summary" ]] || summary='{"deviation_visible_before_restore":false,"restoration_observed":false,"reason_strings_seen":[]}'
  gate::item_check "deviation-or-restoration-observable" "$rc" "$(jq -r '"deviation visible before restore: \(.deviation_visible_before_restore); restored: \(.restoration_observed) after \(.time_to_restoration_seconds // "n/a")s; reasons \(.reason_strings_seen)"' <<<"$summary")" "$eid"
  local answer obs
  answer="$(jq -r 'if .deviation_visible_before_restore and .restoration_observed then "deviation-visible-then-restored"
                   elif .restoration_observed then "restored-without-visible-deviation"
                   elif .deviation_visible_before_restore then "deviation-visible-not-restored"
                   else "neither-observable" end' <<<"$summary")"
  obs="$(jq -n --argjson s "$summary" --arg a "$answer" --argjson p "$G13_PRIORITY" --arg path "$path" '
    {schema: "agentic-netops.gate.deviation/v1",
     config: {priority: $p, revertive: true, owner: "gate-owned scratch Config", path: $path},
     answer: $a,
     deviation_visible_before_restore: $s.deviation_visible_before_restore,
     reason_strings_seen: ($s.reason_strings_seen // []),
     restoration_observed: $s.restoration_observed,
     time_to_restoration_seconds: $s.time_to_restoration_seconds,
     poll_interval_seconds: ($s.poll_interval_seconds // 1),
     observation_window_seconds: $s.observation_window_seconds,
     assertable_by_managed_drift: {deviation_not_applied: $s.deviation_visible_before_restore,
                                   restoration: $s.restoration_observed,
                                   overruled_producible: (($s.reason_strings_seen // []) | index("OVERRULED") != null)}}')"
  gate::observed deviation.json "$obs" || gate::item_check "observed-file" 1 "deviation.json refused"
  gate::item_observe answer "\"$answer\""
  g13::remove
  gate::item_end
}
