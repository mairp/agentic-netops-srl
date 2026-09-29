#!/usr/bin/env bash
# removability.sh — T152's removability proof (User Story 7 scenarios 4a/4b; SC-025, SC-030,
# SC-042, NFR-006, NFR-007, FR-007, FR-013, FR-078, AD-24, AD-26, AD-35, AD-36, AD-46, AD-55, AD-57).
#
#   0. leftovers::scan first (FR-108).
#   1. `provision.sh --with-intent-tier` on the same pinned artefacts (skipped with
#      RM_SKIP_PROVISION=1 on a lab already provisioned so) — its operator-credentials `username`
#      capture (T088) lands in this run's evidence and is one of the captures the usernames record
#      is built from (AD-57);
#   2. RM_TIER_SERVICES (default 1) mac-vrf services submitted THROUGH THE TIER (both
#      confirmations, tests/e2e's tierflow client) and one Network applied with kubectl in
#      agentic-netops-services (RM_SVC_NET, vlan RM_SVC_VLAN, l2vni RM_SVC_VNI), all waited Ready;
#   3. scenario 4a — `off.sh --purge-intent-tier` WITHOUT --remove-services, kubectl recorded by
#      tests/e2e/lib/kubectl_calllog.sh: non-zero, every tier Network named, each still present
#      and Ready, no workload scaled (replicas read back, no `scale` call), no export ran (no exec,
#      no new audit-export-* under the lab's evidence root);
#   4. scenario 4b — `off.sh --purge-intent-tier --remove-services`, recorded the same way, its
#      order asserted by tests/e2e/lib/purge_order.py (R1…R7); the export's record carries the
#      NFR-013 fields; the policy deny-tier-force-release is gone; the services Network is Ready;
#   5. with the store and the Secret gone, the read-back: T103's test_audit_reconcile.py in its
#      file-source mode over the exported artefact and the usernames record alone — the stream
#      half of SC-030/SC-042 passing, the live-object half "not run: objects removed";
#   6. `CONTROL_PLANE_ONLY=1 tests/e2e/acceptance.sh` — the full control-plane gate run with the
#      tier absent, 100% pass (SC-025);
#   7. the two-line Grafana patch reverted; runtime inventory — every platform application a Pod,
#      none a Compose or standalone container; no CronJob in any platform namespace; no workflow-
#      or pipeline-engine API group served (scripts/ci/orchestration.denylist's groups);
#   8. the services Network is deleted again unless RM_KEEP_SERVICE=1.
#
# Usage: removability.sh      Environment: RM_SKIP_PROVISION, RM_TIER_SERVICES, RM_SVC_NET
#   (rm-kept-macvrf — a kept service, never a vt-scratch- name: its Configs would read as a
#   gate leftover to the control-plane-only run of step 6), RM_SVC_VLAN (131), RM_SVC_VNI (10131), RM_TIER_VLAN_BASE (140),
#   RM_KEEP_SERVICE, RM_SKIP_ACCEPTANCE (debug only: the run then FAILS step 6), suite.sh's.
set -euo pipefail

RM_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../integration/lib/suite.sh
source "$RM_HERE/../integration/lib/suite.sh"

: "${RM_TIER_SERVICES:=1}"
: "${RM_SVC_NET:=rm-kept-macvrf}"
: "${RM_SVC_VLAN:=131}"
: "${RM_SVC_VNI:=10131}"
: "${RM_TIER_VLAN_BASE:=140}"
RM_ROOT="$SUITE_ROOT"
RM_INTENT_NS="agentic-netops-intent"
RM_AGENTS_NS="agentic-netops-agents"
RM_SERVICES_NS="agentic-netops-services"
RM_PLATFORM_NS=(agentic-netops-system agentic-netops-services agentic-netops-allocation agentic-netops-agents
  agentic-netops-intent sdc-system kuid-system monitoring cert-manager)
# A platform image is one of THIS platform's artefacts, never an image that merely shares a
# product name (the host runs unrelated Compose stacks of its own — grafana, prometheus, clickhouse —
# which T152 r6 misread as findings): an image carrying a digest versions.lock.yaml pins, a
# first-party image name of its firstPartyImages block, or a container carrying the platform's
# ownership label agentic-netops.io/owned-by.
rm::platform_refs() {
  { grep -oE 'sha256:[0-9a-f]{64}' "$RM_ROOT/versions.lock.yaml"
    yq -r '.firstPartyImages[].name | "name:" + .' "$RM_ROOT/versions.lock.yaml"; } | sort -u
}
RM_TIER_NETS=()

rm::workloads() {
  lab::kubectl -n "$RM_AGENTS_NS" get deployments,statefulsets -o json 2>/dev/null \
    | jq -r '.items[] | "\(.kind)/\(.metadata.name) \(.spec.replicas)"' | sort
}
rm::root() { dirname "$EVIDENCE_DIR"; }   # the lab's evidence root .evidence/<cluster>_<lab>
rm::exports() { find "$(rm::root)" -name 'audit-export-*.ndjson.gz' 2>/dev/null | sort; }

# rm::purge <evidence id> <calllog> [--remove-services] — off.sh, kubectl recorded
rm::purge() {
  local id="$1" calllog="$2"; shift 2
  local rc=0
  : >"$calllog"
  RM_LAST_ID="$(gate::id "$id")"
  # shellcheck disable=SC2097,SC2098 # KUBECTL_REAL is the caller's kubectl, KUBECTL the recording shim
  KUBECTL_CALLLOG="$calllog" KUBECTL_REAL="${KUBECTL:-kubectl}" KUBECTL="$RM_HERE/lib/kubectl_calllog.sh" \
    evidence_run "$RM_LAST_ID" --attach "${calllog#"$EVIDENCE_DIR"/}" -- "$RM_ROOT/scripts/off.sh" \
    --cluster-name "${CLUSTER_NAME:-agentic-netops}" --purge-intent-tier "$@" >/dev/null 2>&1 || rc=$?
  RM_LAST_OUT="$EVIDENCE_DIR/$RM_LAST_ID.stdout"
  RM_LAST_ERR="$EVIDENCE_DIR/$RM_LAST_ID.stderr"
  return "$rc"
}
rm::said() { cat "$RM_LAST_OUT" "$RM_LAST_ERR" 2>/dev/null | grep -q -- "$1"; }

# rm::submit <n> — one mac-vrf through the tier; prints the Network name
rm::submit() {
  local vlan=$((RM_TIER_VLAN_BASE + $1))
  (cd "$RM_ROOT/agents/tests/e2e" && uv run --project "$RM_ROOT/agents" python -c "
import sys, tierflow
svc = tierflow.provision('Create a mac-vrf for tenant rm$1 that extends VLAN $vlan across leaf01 ethernet-1/1 and leaf02 ethernet-1/1')
assert svc.network, 'no Network reported'
print(svc.network)
")
}

# rm::submit_and_remove <n> — one mac-vrf through the tier, then removed THROUGH THE TIER under both
# confirmations, so the exported stream holds a removal and its confirmations beside the
# submissions (the stream half of SC-030 reads audit.submit, audit.remove and audit.confirm; T152 r6
# exported none: its only removal was the purge's kubectl delete, which the tier does not record).
# Prints the Network name; rc 1 unless the Network is gone afterwards.
rm::submit_and_remove() {
  local vlan=$((RM_TIER_VLAN_BASE + $1))
  (cd "$RM_ROOT/agents/tests/e2e" && uv run --project "$RM_ROOT/agents" python -c "
import tierflow
svc = tierflow.provision('Create a mac-vrf for tenant rm$1 that extends VLAN $vlan across leaf01 ethernet-1/1 and leaf02 ethernet-1/1')
assert svc.network, 'no Network reported'
turns = tierflow.remove(svc.network)
final = turns[-1].last()
tierflow.wait_gone(svc.network, timeout=600)
print('removed through the tier:', final.get('status'))
print(svc.network)
")
}

# rm::grafana_patched — 0 when monitoring/grafana mounts the tier's dashboards ConfigMap
rm::grafana_patched() {
  lab::kubectl -n monitoring get deployment grafana -o json \
    | jq -e '[.spec.template.spec.volumes[]? | .configMap.name?, .secret.secretName?,
               (.projected.sources[]? | .configMap.name?, .secret.name?)] | index("grafana-dashboards-agents") != null' >/dev/null
}
rm::grafana_unpatched() {
  lab::kubectl -n monitoring get deployment grafana -o name >/dev/null 2>&1 || return 0
  ! rm::grafana_patched
}

# rm::inventory — FR-007/NFR-007 and FR-013's runtime half. Prints what it read; rc 1 on a finding.
rm::inventory() {
  local bad=0 ns groups deny
  echo "== platform workloads as Pods (namespaces present)"
  for ns in "${RM_PLATFORM_NS[@]}"; do
    lab::kubectl get namespace "$ns" -o name >/dev/null 2>&1 || continue
    lab::kubectl -n "$ns" get pods -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,PHASE:.status.phase,IMAGE:.spec.containers[*].image --no-headers
  done
  echo "== containers outside the cluster and the lab (kind nodes, clab-* nodes excluded)"
  local others refs line name image digest repo owned found=""
  others="$(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "agentic-netops.io/owned-by"}}' \
    | awk -F'\t' '$2 !~ /^kindest\/node/ && $1 !~ /^clab-/')"
  printf '%s\n' "$others"
  refs="$(rm::platform_refs)"
  while IFS=$'\t' read -r name image _ owned; do
    [[ -n "$name" ]] || continue
    # the image's repo digests as well as its reference: a container started by tag still runs the digest
    digest="$(docker image inspect --format '{{join .RepoDigests " "}}' \
                "$(docker inspect --format '{{.Image}}' "$name" 2>/dev/null)" 2>/dev/null
              grep -oE 'sha256:[0-9a-f]{64}' <<<"$image")"
    repo="${image##*/}"; repo="${repo%%[:@]*}"
    if [[ -n "$owned" ]] || grep -qxF "name:$repo" <<<"$refs" \
       || grep -qxF -f <(grep -oE 'sha256:[0-9a-f]{64}' <<<"$digest") <<<"$refs"; then
      found+="$name	$image	${owned:+owned-by=$owned}"$'\n'
    fi
  done <<<"$others"
  if [[ -n "$found" ]]; then
    echo "FINDING a platform image runs as a standalone or Compose container:"; printf '%s' "$found"; bad=1
  else
    echo "no container outside the cluster and the lab runs a pinned or first-party platform image or carries the ownership label"
  fi
  echo "== CronJobs in platform namespaces"
  for ns in "${RM_PLATFORM_NS[@]}"; do
    if [[ -n "$(lab::kubectl -n "$ns" get cronjobs -o name 2>/dev/null)" ]]; then
      echo "FINDING CronJob(s) in $ns: $(lab::kubectl -n "$ns" get cronjobs -o name | tr '\n' ' ')"; bad=1
    fi
  done
  echo "== workflow/pipeline-engine API groups served"
  groups="$(lab::kubectl api-versions | cut -d/ -f1 | sort -u)"
  deny="$( { awk '$1 == "group" {print $2}' "$RM_ROOT/scripts/ci/orchestration.denylist"
             awk '$1 == "kind" && $2 ~ /\// {split($2, a, "/"); print a[1]}' "$RM_ROOT/scripts/ci/orchestration.denylist"; } | sort -u)"
  local g
  for g in $deny; do
    if grep -qx "$g" <<<"$groups"; then echo "FINDING API group $g is served"; bad=1; fi
  done
  echo "denied groups checked: $(tr '\n' ' ' <<<"$deny")"
  [[ "$bad" -eq 0 ]] && echo "inventory clean"
  return "$bad"
}

rm::run() {
  local rc i name
  # 1. provisioned --with-intent-tier on the pinned artefacts — before suite::init, which reads the
  #    lab's credentials: after T151's last destroy nothing is standing (RM_SKIP_PROVISION=1 on a
  #    lab already provisioned so). Its operator-credentials username capture (T088) lands in this
  #    run's EVIDENCE_DIR.
  evidence::ensure_dir || return 3
  if [[ "${RM_SKIP_PROVISION:-0}" != 1 ]]; then
    rc=0; evidence_run "$(gate::id RM.provision)" -- env MGMT_CIDR="${MGMT_CIDR:-172.25.25.0/24}" "$RM_ROOT/scripts/provision.sh" \
      --cluster-name "${CLUSTER_NAME:-agentic-netops}" --with-intent-tier >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 0 ]] || { log::error "FAIL provision.sh --with-intent-tier failed (exit $rc) — nothing else run"; return 1; }
    log::info "PASS provision.sh --with-intent-tier"
  fi
  suite::init removability || return $?
  suite::refuse_on_leftovers removability || return $?
  suite::intervals
  local ready_wait=$((SUITE_REVERIFY_S + 2 * SUITE_RECONCILE_S))
  if [[ "${RM_SKIP_PROVISION:-0}" == 1 ]] || compgen -G "$EVIDENCE_DIR/operator-username-*.json" >/dev/null; then
    suite::ok "operator-credentials username capture(s) in this run: $(cd "$EVIDENCE_DIR" && find . -maxdepth 1 -name 'operator-username-*.json' -printf '%f ')"
  else
    suite::fail "the provisioning run left no operator-username capture in $EVIDENCE_DIR"
  fi
  rc=0; rm::grafana_patched || rc=$?
  suite::judge "$rc" "monitoring/grafana carries the two-line tier patch before the removal" "grafana not patched by --with-intent-tier"

  # 2. services the first step has to find, and one it must leave
  for i in $(seq 1 "$RM_TIER_SERVICES"); do
    name="$(gate::run "RM.submit-$i" -- rm::submit "$i" | tail -n 1)" || true
    if [[ -n "$name" ]] && lab::kubectl -n "$RM_INTENT_NS" get "$SUITE_NET_RES" "$name" -o name >/dev/null 2>&1; then
      RM_TIER_NETS+=("$name"); suite::ok "submitted through the tier: $RM_INTENT_NS/$name"
    else
      suite::fail "tier submission $i produced no Network"
    fi
  done
  [[ ${#RM_TIER_NETS[@]} -gt 0 ]] || { suite::finish removability; return 1; }
  # and one removed through the tier before the purge: the export must hold a tier removal
  i=$((RM_TIER_SERVICES + 1))
  name="$(gate::run "RM.submit-remove-$i" -- rm::submit_and_remove "$i" | tail -n 1)" || true
  if [[ -n "$name" ]] && ! lab::kubectl -n "$RM_INTENT_NS" get "$SUITE_NET_RES" "$name" -o name >/dev/null 2>&1; then
    suite::ok "submitted and removed through the tier: $RM_INTENT_NS/$name"
  else
    suite::fail "tier submission and removal $i did not end with the Network gone"
  fi
  suite::neg RM-ready cond "$RM_SERVICES_NS" vt-scratch-never-ready 5 Ready=True || true
  SVC_NS="$RM_SERVICES_NS" suite::apply_macvrf "$RM_SVC_NET" "$RM_SVC_VLAN" "$RM_SVC_VNI" \
    || { suite::fail "could not apply $RM_SERVICES_NS/$RM_SVC_NET"; suite::finish removability; return 1; }
  [[ "${RM_KEEP_SERVICE:-0}" == 1 ]] || suite::on_exit "lab::kubectl -n $RM_SERVICES_NS delete $SUITE_NET_RES $RM_SVC_NET --ignore-not-found --wait=true --timeout=600s >/dev/null"
  rc=0; suite::check RM.svc-ready RM-ready --readiness -- cond "$RM_SERVICES_NS" "$RM_SVC_NET" "$ready_wait" Ready=True >/dev/null || rc=$?
  suite::judge "$rc" "$RM_SERVICES_NS/$RM_SVC_NET (kubectl) Ready" "$RM_SERVICES_NS/$RM_SVC_NET never Ready"
  for name in "${RM_TIER_NETS[@]}"; do
    rc=0; suite::check "RM.tier-ready.$name" RM-ready -- cond "$RM_INTENT_NS" "$name" "$ready_wait" Ready=True >/dev/null || rc=$?
    suite::judge "$rc" "$RM_INTENT_NS/$name Ready" "$RM_INTENT_NS/$name not Ready"
  done
  local before_w exports_before
  before_w="$(rm::workloads)"; exports_before="$(rm::exports)"
  evidence_run "$(gate::id RM.workloads-before)" -- rm::workloads >/dev/null

  # 3. scenario 4a — refused, nothing changed
  rc=0; rm::purge RM.purge-refused "$EVIDENCE_DIR/rm-calllog-refused.tsv" || rc=$?
  [[ "$rc" -ne 0 ]] && suite::ok "4a: purge without --remove-services exited $rc" || suite::fail "4a: purge without --remove-services exited 0"
  for name in "${RM_TIER_NETS[@]}"; do
    rm::said "$name" && suite::ok "4a: refusal names $name" || suite::fail "4a: refusal does not name $name"
    rc=0; suite::check "RM.4a-ready.$name" RM-ready -- cond "$RM_INTENT_NS" "$name" 5 Ready=True >/dev/null || rc=$?
    suite::judge "$rc" "4a: $name still present and Ready" "4a: $name not present/Ready after the refusal"
  done
  [[ "$(rm::workloads)" == "$before_w" ]] && suite::ok "4a: no tier workload scaled (replicas read back identical)" \
    || suite::fail "4a: a tier workload changed: $(diff <(echo "$before_w") <(rm::workloads) | tr '\n' ' ')"
  [[ "$(rm::exports)" == "$exports_before" ]] && suite::ok "4a: no export ran (no new audit-export-* under $(rm::root))" \
    || suite::fail "4a: an export was written by the refused purge"
  rc=0; gate::run RM.4a-order -- python3 "$RM_HERE/lib/purge_order.py" refused --calllog "$EVIDENCE_DIR/rm-calllog-refused.tsv" >/dev/null || rc=$?
  suite::judge "$rc" "4a: call log — no mutating call, no scale, no exec, the refusal-decision list taken" "4a: call-log order check failed (RM.4a-order)"

  # 4. scenario 4b — removed with its services
  rc=0; rm::purge RM.purge-remove "$EVIDENCE_DIR/rm-calllog-remove.tsv" --remove-services || rc=$?
  suite::judge "$rc" "4b: purge --remove-services exited 0" "4b: purge --remove-services exited $rc"
  local attempt
  # the attempt this purge exported under, from its own log line ("… written to …/audit-export-<attempt>.ndjson.gz")
  attempt="$(cat "$RM_LAST_OUT" "$RM_LAST_ERR" 2>/dev/null | sed -n 's|.*written to .*/audit-export-\(.*\)\.ndjson\.gz.*|\1|p' | tail -n 1)"
  rc=0; gate::run RM.4b-order -- python3 "$RM_HERE/lib/purge_order.py" remove --calllog "$EVIDENCE_DIR/rm-calllog-remove.tsv" \
    --evidence-dir "$EVIDENCE_DIR" --attempt "${attempt:-none}" --networks "$(IFS=,; echo "${RM_TIER_NETS[*]}")" \
    --stderr "$RM_LAST_ERR" >/dev/null || rc=$?
  suite::judge "$rc" "4b: order R1–R7 (quiesce first, lists, export before store, usernames before Secret, re-list before namespace, policy gone)" \
    "4b: order check failed (RM.4b-order)"
  rc=0; jq -e '.command and .utc_time and (.exit_status == 0) and .device_image_digest and .cluster.name and .lab.name and (.attachments | length > 0)' \
    "$EVIDENCE_DIR/audit-export-${attempt:-none}.json" >/dev/null || rc=$?
  suite::judge "$rc" "4b: audit-export-${attempt} record carries the NFR-013 fields" "4b: the export record lacks NFR-013 fields"
  if lab::kubectl get validatingadmissionpolicy deny-tier-force-release -o name >/dev/null 2>&1 \
     || lab::kubectl get validatingadmissionpolicybinding deny-tier-force-release -o name >/dev/null 2>&1; then
    suite::fail "4b: deny-tier-force-release still present"
  else
    suite::ok "4b: deny-tier-force-release policy and binding gone"
  fi
  for name in "${RM_TIER_NETS[@]}"; do
    lab::kubectl -n "$RM_INTENT_NS" get "$SUITE_NET_RES" "$name" -o name >/dev/null 2>&1 \
      && suite::fail "4b: $name still present" || suite::ok "4b: $name removed"
  done
  rc=0; suite::check RM.4b-svc-ready RM-ready -- cond "$RM_SERVICES_NS" "$RM_SVC_NET" 30 Ready=True >/dev/null || rc=$?
  suite::judge "$rc" "4b: $RM_SERVICES_NS/$RM_SVC_NET still Ready" "4b: $RM_SERVICES_NS/$RM_SVC_NET not Ready after the removal"

  # 5. the read-back from the exported artefact alone
  if lab::kubectl -n "$RM_AGENTS_NS" get statefulset clickhouse -o name >/dev/null 2>&1 \
     || lab::kubectl -n "$RM_AGENTS_NS" get secret operator-credentials -o name >/dev/null 2>&1; then
    suite::fail "5: the store or operator-credentials is still present — not a read-back from the file alone"
  else
    suite::ok "5: the analytics store and operator-credentials are gone"
  fi
  rc=0; gate::run RM.audit-reconcile-file -- bash -c "cd '$RM_ROOT/agents' && AGENTIC_NETOPS_E2E=1 uv run pytest -v -rs -p no:cacheprovider \
    tests/e2e/test_audit_reconcile.py --audit-export '$EVIDENCE_DIR/audit-export-${attempt:-none}.ndjson.gz'" >/dev/null || rc=$?
  suite::judge "$rc" "5: file-source reconciliation (stream half of SC-030/SC-042) passed; live-object half not run" \
    "5: file-source reconciliation failed (RM.audit-reconcile-file)"
  grep -q "not run: objects removed" "$EVIDENCE_DIR/RM.audit-reconcile-file.stdout" \
    && suite::ok "5: live-object half reported 'not run: objects removed'" || suite::fail "5: live-object half not reported as not run"

  # 6. the full control-plane gate run with the tier absent
  if [[ "${RM_SKIP_ACCEPTANCE:-0}" == 1 ]]; then
    suite::fail "6: CONTROL_PLANE_ONLY acceptance skipped by RM_SKIP_ACCEPTANCE (debug)"
  else
    rc=0; gate::run RM.control-plane-only -- env CONTROL_PLANE_ONLY=1 COMPAT_BUILD_EVIDENCE_DIR="$EVIDENCE_DIR" bash "$RM_ROOT/tests/e2e/acceptance.sh" >/dev/null 2>&1 || rc=$?
    suite::judge "$rc" "6: make test-acceptance CONTROL_PLANE_ONLY=1 — 100% of the control-plane criteria pass" \
      "6: control-plane-only acceptance failed (exit $rc)"
  fi

  # 7. dashboard patch reverted; runtime inventory
  rc=0; gate::run RM.grafana-unpatched -- rm::grafana_unpatched >/dev/null || rc=$?
  suite::judge "$rc" "7: the two-line Grafana patch is reverted" "7: grafana still mounts the tier's dashboards"
  rc=0; gate::run RM.runtime-inventory -- rm::inventory >/dev/null || rc=$?
  suite::judge "$rc" "7: every platform application a Pod; no Compose/standalone container; no CronJob; no workflow-engine API group" \
    "7: runtime inventory finding (RM.runtime-inventory)"

  rm::attach_artefacts
  suite::finish removability
}

rm::attach_artefacts() {
  local -a attach=()
  local f
  for f in declared-faults.json "suite-manifests/${RM_SVC_NET}.yaml"; do
    [[ -f "$EVIDENCE_DIR/$f" ]] && attach+=(--attach "$f")
  done
  [[ ${#attach[@]} -gt 0 ]] && { evidence_run "$(gate::id RM.artefacts)" "${attach[@]}" -- ls -1 "$EVIDENCE_DIR" >/dev/null || true; }
  # whatever else a step wrote beside its own record — the file-source read-back's
  # t103/audit-reconcile-file.json among them (T152 r9) — sealed by one run-captured record
  evidence_seal "$(gate::id RM.sealed)" >/dev/null || true
}

rm::run
