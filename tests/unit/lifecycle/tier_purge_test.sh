#!/usr/bin/env bash
# tier_purge_test.sh — the intent tier's removal and the audit-record export (T174 for T088/T049;
# FR-078, FR-103, NFR-006, SC-040, SC-042, AD-24, AD-26, AD-35, AD-36, AD-46, AD-55, AD-64, AD-71,
# AD-72; data-model.md §16, §25). Offline: the REAL scripts/off.sh is run against the fake
# docker / kind / containerlab of fakes.sh and the fake kubectl + fake analytics store of
# tier_fakes.sh, which record every call. Evidence goes to a temporary EVIDENCE_ROOT, never .evidence/.
#
# Clauses (T174) → sections below:
#   S1  AUDIT_EXPORT_TIMEOUT_SECONDS default 120 / TIER_PURGE_WAIT_SECONDS default 300 read from the
#       effective settings, overrides honoured (and S6/S8 run the overrides for real)
#   S2  --purge-intent-tier, Networks present, no --remove-services: non-zero, no delete / scale /
#       export, every Network and both continuations named; (a) is captured through evidence_run;
#       planted evidence byte-identical after the refused purge
#   S3  --purge-intent-tier --remove-services: the only call before the scale-down is list (a), a
#       read; supervisor + deployer scaled to zero BEFORE list (c) and BEFORE the export; an absent `ui`
#       (a tier provisioned before T126) reported and never created; exactly (c)'s Networks deleted, none before (c); export before the
#       store is deleted, NFR-013 fields, unique attempt id; the usernames record before the Secret is
#       deleted, username never password; namespace only after a re-list is empty; provisional claims
#       (correlation id matching no Network) removed, submitted services' claims not the purge's;
#       deny-tier-force-release + binding removed; agentic-netops-services untouched; no force-release
#       annotation; the lab's evidence root survives; the second run is a no-op
#   S4  no flag, empty (a): goes on, the scale-down still precedes the export; a present `ui` (T126)
#       is scaled to zero with supervisor and deployer, before the export, and removed with the workloads
#   S5  no flag, a Network appearing between (a) and (c): refusal fallback — non-zero, named, both
#       continuations, no delete, no export, workloads left at zero, re-provisioning named
#   S6  export failures stop with the store intact: unqueryable within the timeout (override
#       honoured), query error, unwritable artefact, short row count; absent store skipped; empty
#       store a successful empty export; --discard-audit-record goes past, printed and recorded
#   S7  the full off.sh: exports before the store goes, with and without --preserve-evidence, never
#       asks for --remove-services; the usernames record before the Secret goes, username_unchanged
#       false when the lab's captures differ; a failed export stops it with the store intact
#   S8  the wait: a Network still Deleting after TIER_PURGE_WAIT_SECONDS (override honoured) stops
#       non-zero naming it and what is outstanding, tier left in place, no namespace deleted; one
#       already Deleting=True/TargetUnreachable is not waited on; HolderPresent names the holder
#   S9  the re-run rule of data-model.md §16: verified → skip (captured, naming the artefact, found
#       under the lab's evidence root from a new per-run EVIDENCE_DIR); a changed hash / more rows /
#       same count under a different newest-row timestamp → add under a new attempt id; the first
#       artefact's hash never changes
#   S10 the stand-alone `scripts/lib/audit_export.sh export` writes the export and the usernames
#       record and removes nothing
#   S11 static: no force-release annotation writer anywhere in the purge's code (the one patch verb is
#       the Grafana two-line patch of Deployment monitoring/grafana, R-19)
# shellcheck disable=SC2034,SC2207 # the variables are read inside check's eval strings
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=fakes.sh
source "$ROOT/tests/unit/lifecycle/fakes.sh"
# shellcheck source=tier_fakes.sh
source "$ROOT/tests/unit/lifecycle/tier_fakes.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; [[ -n "${out:-}" ]] && printf '%s\n' "$out" | tail -n 12 | sed 's/^/    | /'; fi; }

CL=agentic-netops LAB=agentic-netops-fabric NET=agentic-netops-mgmt
AG=agentic-netops-agents IN=agentic-netops-intent SV=agentic-netops-services AL=agentic-netops-allocation
OPW='Op3rator-password-never-shown-7x'
CHPW='Cl1ckhouse-password-never-shown-9q'
ORIG_PATH="$PATH"
LABROOT_REL="${CL}_${LAB}"

b64() { printf '%s' "$1" | base64 -w0; }
dep() { # <name> — a tier Deployment at one replica
  tier_fakes::obj "$CL" "$AG" deployment "$(jq -cn --arg n "$1" --arg ns "$AG" --arg o "$CL" \
    '{apiVersion: "apps/v1", kind: "Deployment", metadata: {name: $n, namespace: $ns,
      labels: {"agentic-netops.io/tier": "intent", "agentic-netops.io/owned-by": $o, "app.kubernetes.io/name": $n}},
      spec: {replicas: 1}}')"
}
net() { # <ns> <name> <correlation id> [finalize]
  tier_fakes::obj "$CL" "$1" network "$(jq -cn --arg ns "$1" --arg n "$2" --arg c "$3" --arg f "${4:-ok}" \
    '{apiVersion: "fabric.agentic-netops.io/v1alpha1", kind: "Network", metadata: {name: $n, namespace: $ns,
      labels: {"agentic-netops.io/correlation-id": $c}}, spec: {}, fake: {finalize: $f},
      status: {conditions: [{type: "Ready", status: "True", reason: "Ready"}]}}')"
}
claim() { # <name> [correlation id]
  tier_fakes::obj "$CL" "$AL" identifierclaim "$(jq -cn --arg n "$1" --arg ns "$AL" --arg c "${2:-}" \
    '{apiVersion: "fabric.agentic-netops.io/v1alpha1", kind: "IdentifierClaim", metadata: {name: $n, namespace: $ns,
      labels: (if $c == "" then {} else {"agentic-netops.io/correlation-id": $c, "agentic-netops.io/tier": "intent"} end)}}')"
}
row() { # <table> <timestamp> <event> — one stored span row
  jq -cn --arg t "$2" --arg e "$3" '{Timestamp: $t, TraceId: "t1", SpanName: "audit", Events: {Name: [$e]}}' \
    >>"$FAKE_STATE/store/tables/$1.ndjson"
}
tier_label() { jq -cn '{"app.kubernetes.io/part-of": "agentic-netops-intent-tier", "agentic-netops.io/tier": "intent"}'; }

# setup <case> — a fresh fake world: the owned lab, cluster and network; the control plane; the
# tier (workloads, store with three rows, Secrets, boundary objects); two tier-submitted Networks;
# one Network in agentic-netops-services; claims; a planted file under the lab's evidence root.
setup() {
  W="$T/$1"
  rm -rf "$W"; mkdir -p "$W"
  fakes::install "$W"
  tier_fakes::install "$W"
  export FAKE_STATE="$W/state"
  export PATH="$W/bin:$ORIG_PATH"
  export EVIDENCE_ROOT="$W/evidence" CLAB_LABDIR_BASE="$W/labdir" AGENTIC_NETOPS_ENV_FILE="$W/no.env"
  unset EVIDENCE_DIR CLUSTER_NAME OFF_AUDIT_EXPORT_CMD AUDIT_EXPORT_TIMEOUT_SECONDS TIER_PURGE_WAIT_SECONDS \
    AUDIT_EXPORT_ATTEMPT FAKE_APPEAR_ON_SCALE || true
  fakes::network "$NET" 172.25.25.0/24 "$CL"
  local n
  for n in spine01 spine02 leaf01 leaf02; do fakes::container "clab-$LAB-$n" "$LAB" nokia_srlinux "$CL"; done
  for n in client01 client02; do fakes::container "clab-$LAB-$n" "$LAB" linux "$CL"; done
  fakes::cluster "$CL" "$CL"
  fakes::k8s "$CL" _ namespace agentic-netops-system "$CL"
  fakes::k8s "$CL" _ namespace "$SV" "$CL"
  fakes::k8s "$CL" _ namespace "$AL" "$CL"
  fakes::k8s "$CL" _ namespace "$AG" "$CL" '{"metadata":{"labels":{"agentic-netops.io/owned-by":"agentic-netops","agentic-netops.io/tier":"intent"}}}'
  fakes::k8s "$CL" _ namespace "$IN" "$CL" '{"metadata":{"labels":{"agentic-netops.io/owned-by":"agentic-netops","agentic-netops.io/tier":"intent"}}}'
  for n in supervisor mapper allocator deployer slim agent-otel-collector; do dep "$n"; done   # no `ui` here (AD-71); S4 adds one
  fakes::k8s "$CL" "$AG" statefulset clickhouse "$CL"
  fakes::k8s "$CL" "$AG" secret operator-credentials "$CL" "$(jq -cn --arg u "$(b64 operator)" --arg p "$(b64 "$OPW")" '{data: {username: $u, password: $p}}')"
  fakes::k8s "$CL" "$AG" secret clickhouse-auth "$CL" "$(jq -cn --arg u "$(b64 otel)" --arg p "$(b64 "$CHPW")" '{data: {username: $u, password: $p}}')"
  fakes::k8s "$CL" "$AG" secret llm-provider "$CL"
  fakes::k8s "$CL" "$AG" secret slim-gateway "$CL"
  fakes::k8s "$CL" agentic-netops-system configmap fabric-qualification "$CL"
  tier_fakes::obj "$CL" _ validatingadmissionpolicy "$(jq -cn --argjson l "$(tier_label)" '{kind: "ValidatingAdmissionPolicy", metadata: {name: "deny-tier-force-release", labels: $l}}')"
  tier_fakes::obj "$CL" _ validatingadmissionpolicybinding "$(jq -cn --argjson l "$(tier_label)" '{kind: "ValidatingAdmissionPolicyBinding", metadata: {name: "deny-tier-force-release", labels: $l}}')"
  tier_fakes::obj "$CL" "$AL" role "$(jq -cn --arg ns "$AL" --argjson l "$(tier_label)" '{kind: "Role", metadata: {name: "kuid-claimer", namespace: $ns, labels: $l}}')"
  tier_fakes::obj "$CL" "$AL" rolebinding "$(jq -cn --arg ns "$AL" --argjson l "$(tier_label)" '{kind: "RoleBinding", metadata: {name: "kuid-claimer", namespace: $ns, labels: $l}}')"
  row otel_traces "2026-09-24 10:00:01.000000000" confirm
  row otel_traces "2026-09-24 10:00:02.000000000" submit
  row otel_traces "2026-09-24 10:00:03.000000000" remove
  net "$IN" svc-a c-a
  net "$IN" svc-b c-b
  net "$SV" cp-net c-cp
  claim claim-a c-a            # adopted by svc-a: the provider's finalizer releases it (AD-16)
  claim claim-prov c-never     # a request never submitted: provisional, the purge's to delete
  claim claim-cp c-cp          # rests on a control-plane service: never the purge's
  claim claim-plain            # no correlation label: not the tier's
  PLANT="$EVIDENCE_ROOT/$LABROOT_REL/20260101T000000Z/planted.bin"
  mkdir -p "$(dirname "$PLANT")"
  head -c 4096 /dev/urandom >"$PLANT"
  PLANT_SUM="$(sha256sum "$PLANT" | cut -d' ' -f1)"
  SV_SUM="$(sv_sum)"
}
sv_sum() { (cd "$FAKE_STATE/k8s/$CL" && { find "$SV" -type f -print0 | sort -z | xargs -0 cat; cat "$AL/identifierclaim/claim-cp.json"; } 2>/dev/null | sha256sum | cut -d' ' -f1); }

run_off() { : >"$FAKE_STATE/calls.log"; local s; s=$(date +%s); out="$(bash "$ROOT/scripts/off.sh" "$@" 2>&1)"; rc=$?; elapsed=$(( $(date +%s) - s )); }
calls() { cat "$FAKE_STATE/calls.log"; }
kcalls() { grep -E '^(kubectl|APPLY)' "$FAKE_STATE/calls.log" || true; }
line_of() { grep -nE -m1 -- "$1" "$FAKE_STATE/calls.log" | cut -d: -f1; }
lines_of() { grep -nE -- "$1" "$FAKE_STATE/calls.log" | cut -d: -f1; }
MUT='^(APPLY |kubectl .* (delete|scale|apply|patch|annotate|label|edit|replace|create|set) )'
mutating() { grep -E "$MUT" "$FAKE_STATE/calls.log" || true; }
deletes() { grep -E '^(kubectl .* delete |kind delete|containerlab destroy|docker network rm)' "$FAKE_STATE/calls.log" || true; }
exports() { grep -E '^kubectl .* exec .*JSONEachRow' "$FAKE_STATE/calls.log" || true; }
NETLIST='^kubectl .* get networks\.fabric\.agentic-netops\.io .*-n agentic-netops-intent'
planted_intact() { [[ -f "$PLANT" && "$(sha256sum "$PLANT" | cut -d' ' -f1)" == "$PLANT_SUM" ]]; }
exists() { [[ -f "$FAKE_STATE/k8s/$CL/$1.json" ]]; }
replicas() { jq -r '.spec.replicas' "$FAKE_STATE/k8s/$CL/$AG/deployment/$1.json"; }
artefacts() { find "$EVIDENCE_ROOT" -name 'audit-export-*.ndjson.gz' | sort; }
records() { find "$EVIDENCE_ROOT" -name 'audit-export-*.json' ! -name 'audit-export-skip-*' | sort; }
no_force_release() { ! grep -qE '^kubectl .* (annotate|patch) ' "$FAKE_STATE/calls.log" && ! grep -rqF 'fabric.agentic-netops.io/force-release' "$FAKE_STATE/k8s"; }
sv_untouched() { ! grep -E "$MUT" "$FAKE_STATE/calls.log" | grep -q "$SV" && [[ "$(sv_sum)" == "$SV_SUM" ]]; }
store_intact() { exists "$AG/statefulset/clickhouse" && [[ -s "$FAKE_STATE/store/tables/otel_traces.ndjson" ]] && [[ -z "$(deletes)" ]]; }
stdout_of() { local j="$1"; cat "$(dirname "$j")/$(jq -r '.raw_output.stdout.file' "$j")"; }
lt() { [[ -n "$1" && -n "$2" && "$1" -lt "$2" ]]; }

# ================================================================== S1 — the two bounds
s="$(env -u AUDIT_EXPORT_TIMEOUT_SECONDS bash "$ROOT/scripts/lib/audit_export.sh" settings 2>&1)"
check "S1 AUDIT_EXPORT_TIMEOUT_SECONDS: the effective default is 120 s" 'grep -qx "AUDIT_EXPORT_TIMEOUT_SECONDS=120" <<<"$s"'
s="$(AUDIT_EXPORT_TIMEOUT_SECONDS=7 bash "$ROOT/scripts/lib/audit_export.sh" settings 2>&1)"
check "S1 AUDIT_EXPORT_TIMEOUT_SECONDS: an override is the effective value" 'grep -qx "AUDIT_EXPORT_TIMEOUT_SECONDS=7" <<<"$s"'
s="$(env -u TIER_PURGE_WAIT_SECONDS bash "$ROOT/scripts/lib/intent_tier.sh" settings 2>&1)"
check "S1 TIER_PURGE_WAIT_SECONDS: the effective default is 300 s" 'grep -qx "TIER_PURGE_WAIT_SECONDS=300" <<<"$s"'
s="$(TIER_PURGE_WAIT_SECONDS=9 bash "$ROOT/scripts/lib/intent_tier.sh" settings 2>&1)"
check "S1 TIER_PURGE_WAIT_SECONDS: an override is the effective value" 'grep -qx "TIER_PURGE_WAIT_SECONDS=9" <<<"$s"'
s="$(AUDIT_EXPORT_TIMEOUT_SECONDS=abc bash "$ROOT/scripts/lib/audit_export.sh" settings 2>&1)"; src=$?
check "S1 a non-numeric AUDIT_EXPORT_TIMEOUT_SECONDS is refused, naming the variable" '[[ $src -ne 0 ]] && grep -q AUDIT_EXPORT_TIMEOUT_SECONDS <<<"$s"'

# ================================================================== S2 — refusal at (a)
setup refuse
run_off --purge-intent-tier
check "S2 refusal: Networks present and no --remove-services → non-zero" '[[ $rc -ne 0 ]]'
check "S2 refusal: every tier-submitted Network is named" 'grep -q "svc-a" <<<"$out" && grep -q "svc-b" <<<"$out"'
check "S2 refusal: continuation 1 named — re-run with --remove-services" 'grep -q -- "--remove-services" <<<"$out"'
check "S2 refusal: continuation 2 named — remove the services first through the tier or cluster tooling" 'grep -qi "remove the services first" <<<"$out"'
check "S2 refusal: no delete, no scale, no apply — nothing mutated" '[[ -z "$(mutating)" ]]'
check "S2 refusal: no export was issued" '[[ -z "$(exports)" && -z "$(artefacts)" ]]'
check "S2 refusal: list (a) is the one Network list, captured through evidence_run" \
  '[[ "$(lines_of "$NETLIST" | wc -l)" -eq 1 ]] && f="$(find "$EVIDENCE_ROOT" -name "tier-purge-refusal-list-*.json" | head -1)" && [[ -n "$f" ]] && stdout_of "$f" | grep -q svc-a'
check "S2 refusal: supervisor and deployer still at one replica" '[[ "$(replicas supervisor)" == 1 && "$(replicas deployer)" == 1 ]]'
check "S2 refusal: the planted file under .evidence/<cluster>_<lab>/ is byte-identical" 'planted_intact'

# ================================================================== S3 — the purge with --remove-services
setup flag
run_off --purge-intent-tier --remove-services
check "S3 flag: exits 0" '[[ $rc -eq 0 ]]'
first_mut="$(grep -nE "$MUT" "$FAKE_STATE/calls.log" | head -1)"
first_scale="$(line_of '^kubectl .* scale ')"
check "S3 flag: the first mutation is a scale-down" '[[ "$first_mut" == *" scale "* ]]'
check "S3 flag: the ONLY Network list before the scale-down is (a), and every kubectl call before it is a read" \
  '[[ "$(head -n $((first_scale - 1)) "$FAKE_STATE/calls.log" | grep -cE "$NETLIST")" -eq 1 ]] && ! head -n $((first_scale - 1)) "$FAKE_STATE/calls.log" | grep -E "^kubectl" | grep -vqE "^kubectl .* get "'
netlists=($(lines_of "$NETLIST"))
scale_sup="$(line_of '^kubectl .* scale deployment supervisor .*--replicas=0')"
scale_dep="$(line_of '^kubectl .* scale deployment deployer .*--replicas=0')"
first_export="$(line_of '^kubectl .* exec .*JSONEachRow')"
check "S3 flag: supervisor and deployer are scaled to zero (--replicas=0)" '[[ -n "$scale_sup" && -n "$scale_dep" ]]'
check "S3 flag: the scale-down precedes the authoritative list (c)" 'lt "$scale_sup" "${netlists[1]:-}" && lt "$scale_dep" "${netlists[1]:-}"'
check "S3 flag: the scale-down precedes the export" 'lt "$scale_sup" "$first_export" && lt "$scale_dep" "$first_export"'
check "S3 flag: (c) is taken before the export" 'lt "${netlists[1]:-}" "$first_export"'
check "S3 flag: an absent ui (a tier provisioned before T126) is reported absent by name and never created (AD-71)" \
  'grep -qiE "ui.*absent|absent.*ui" <<<"$out" && ! grep -qE "scale deployment ui|APPLY Deployment/ui" "$FAKE_STATE/calls.log"'
net_deletes="$(grep -E '^kubectl .* delete networks\.fabric\.agentic-netops\.io' "$FAKE_STATE/calls.log")"
check "S3 flag: exactly the Networks of (c) are deleted (svc-a, svc-b)" \
  '[[ "$(grep -oE "svc-[a-z]+" <<<"$net_deletes" | sort -u | paste -sd,)" == "svc-a,svc-b" ]] && ! grep -q cp-net <<<"$net_deletes"'
check "S3 flag: no Network is deleted before (c) is taken" 'lt "${netlists[1]:-}" "$(line_of "^kubectl .* delete networks")"'
check "S3 flag: no Network is deleted before the export" 'lt "$first_export" "$(line_of "^kubectl .* delete networks")"'
A="$(artefacts | head -1)"; R="${A%.ndjson.gz}.json"
check "S3 export: audit-export-<attempt>.ndjson.gz beside its evidence record audit-export-<attempt>.json" '[[ -n "$A" && -f "$R" ]]'
check "S3 export: one JSON object per stored row (3)" '[[ "$(zcat "$A" | grep -c .)" -eq 3 ]] && zcat "$A" | jq -e .Timestamp >/dev/null'
check "S3 export: the record carries the NFR-013 fields (command, UTC time, exit 0, device digest, cluster + lab identity)" \
  'jq -e ".schema == \"agentic-netops.evidence/v1\" and (.command|length>0) and (.utc_time|test(\"Z$\")) and .exit_status == 0 and (.device_image_digest|test(\"^sha256:\")) and .cluster.name == \"'$CL'\" and .lab.name == \"'$LAB'\"" "$R" >/dev/null'
check "S3 export: the artefact is hashed into the record" '[[ "$(jq -r ".attachments[0].sha256" "$R")" == "$(sha256sum "$A" | cut -d" " -f1)" ]]'
check "S3 export: the record carries the store's row count, rows written and the newest row's timestamp" \
  'stdout_of "$R" | jq -e ".store_rows == 3 and .rows_written == 3 and .newest_row_timestamp == \"2026-09-24 10:00:03.000000000\"" >/dev/null'
check "S3 export: the identifier is unique to the attempt (audit-export-<attempt>)" '[[ "$(basename "$A")" =~ ^audit-export-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+\.ndjson\.gz$ ]]'
check "S3 export: bounded by AUDIT_EXPORT_TIMEOUT_SECONDS at its default 120 s" 'grep -q "AUDIT_EXPORT_TIMEOUT_SECONDS=120" <<<"$out"'
check "S3 export: taken before the store was deleted" \
  'lt "$first_export" "$(line_of "delete statefulset clickhouse|delete namespace agentic-netops-agents")" && ! grep -q "MARK audit-export-present=no" "$FAKE_STATE/calls.log"'
check "S3 export: the store's password never appears in argv, output or evidence" \
  '! grep -qF "$CHPW" "$FAKE_STATE/calls.log" && ! grep -qF "$CHPW" <<<"$out" && ! grep -rqF "$CHPW" "$EVIDENCE_ROOT"'
U="$(find "$EVIDENCE_ROOT" -name 'operator-usernames-*.json' | head -1)"
check "S3 usernames: the usernames record is written (operator-usernames-<attempt>)" '[[ -n "$U" ]]'
check "S3 usernames: …before operator-credentials was deleted" 'grep -q "MARK usernames-record-present=yes" "$FAKE_STATE/calls.log"'
check "S3 usernames: it carries the username and username_unchanged true" 'stdout_of "$U" | jq -e ".usernames == [\"operator\"] and .username_unchanged == true" >/dev/null'
check "S3 usernames: the operator password is nowhere — evidence, output or call log" \
  '! grep -rqF "$OPW" "$EVIDENCE_ROOT" && ! grep -qF "$OPW" <<<"$out" && ! grep -qF "$OPW" "$FAKE_STATE/calls.log"'
check "S3 wait: bounded by TIER_PURGE_WAIT_SECONDS at its default 300 s" 'grep -q "TIER_PURGE_WAIT_SECONDS=300" <<<"$out"'
check "S3 re-list: a third Network list (the re-list) is taken, empty, before agentic-netops-intent is deleted" \
  '[[ "${#netlists[@]}" -ge 3 ]] && lt "${netlists[2]}" "$(line_of "delete namespace agentic-netops-intent")" && f="$(find "$EVIDENCE_ROOT" -name "tier-purge-relist-*.json" | head -1)" && [[ -n "$f" ]] && [[ "$(stdout_of "$f" | jq ".items | length")" == 0 ]]'
check "S3 removed: both tier namespaces" '! exists "_/namespace/$IN" && ! exists "_/namespace/$AG"'
check "S3 removed: the tier workloads (explicitly, before the namespaces)" 'grep -qE "delete deployment .*supervisor|delete deployment supervisor" "$FAKE_STATE/calls.log" && grep -q "delete statefulset clickhouse" "$FAKE_STATE/calls.log"'
check "S3 removed: the tier Secrets" 'grep -q "delete secret operator-credentials" "$FAKE_STATE/calls.log" && grep -q "delete secret clickhouse-auth" "$FAKE_STATE/calls.log"'
check "S3 removed: deny-tier-force-release and its binding (cluster-scoped, the tier's)" \
  '! exists "_/validatingadmissionpolicy/deny-tier-force-release" && ! exists "_/validatingadmissionpolicybinding/deny-tier-force-release"'
check "S3 removed: the borrowed kuid-claimer Role and RoleBinding in the allocation namespace" '! exists "$AL/role/kuid-claimer" && ! exists "$AL/rolebinding/kuid-claimer"'
check "S3 claims: the provisional claim (correlation id matching no Network) is deleted by the purge" \
  '! exists "$AL/identifierclaim/claim-prov" && grep -qE "delete identifierclaims\.fabric\.agentic-netops\.io claim-prov" "$FAKE_STATE/calls.log"'
check "S3 claims: a submitted service's claim is never the purge's (released by the provider's finalizer)" \
  '! grep -qE "delete identifierclaims.* claim-a( |$)" "$FAKE_STATE/calls.log"'
check "S3 claims: the claim resting on a control-plane Network and an unlabelled claim remain" 'exists "$AL/identifierclaim/claim-cp" && exists "$AL/identifierclaim/claim-plain"'
check "S3 untouched: nothing in agentic-netops-services" 'sv_untouched'
check "S3 untouched: the control plane (agentic-netops-system, the allocation namespace)" 'exists "_/namespace/agentic-netops-system" && exists "_/namespace/$AL" && exists "agentic-netops-system/configmap/fabric-qualification"'
check "S3 never: a force-release annotation" 'no_force_release'
check "S3 the lab's evidence root survives: the planted file is byte-identical after a completed purge" 'planted_intact'
check "S3 the cluster, lab and network are not the purge's" '[[ -e "$FAKE_STATE/kind/$CL" && -e "$FAKE_STATE/docker/networks/$NET.json" ]] && ! grep -qE "^(kind delete|containerlab destroy)" "$FAKE_STATE/calls.log"'
run_off --purge-intent-tier --remove-services
check "S3 second run: exits 0" '[[ $rc -eq 0 ]]'
check "S3 second run: a no-op — no mutation, no export" '[[ -z "$(mutating)" && -z "$(exports)" ]]'
check "S3 second run: the planted evidence is byte-identical" 'planted_intact'

# ================================================================== S4 — no flag, empty (a)
setup noflag-empty
rm -f "$FAKE_STATE/k8s/$CL/$IN/network/"*.json
dep ui                         # the chat surface of T126, present
run_off --purge-intent-tier
check "S4 a present ui is scaled to zero (--replicas=0) with supervisor and deployer, before the export" \
  'lt "$(line_of "^kubectl .* scale deployment ui .*--replicas=0")" "$(line_of "^kubectl .* exec .*JSONEachRow")"'
check "S4 …and removed with the tier workloads" 'grep -qE "delete deployment .*\bui\b" "$FAKE_STATE/calls.log"'
check "S4 no flag, empty (a): the purge goes on and completes" '[[ $rc -eq 0 ]] && ! exists "_/namespace/$AG"'
check "S4 no flag, empty (a): the scale-down still precedes the export" \
  'lt "$(line_of "^kubectl .* scale deployment supervisor")" "$(line_of "^kubectl .* exec .*JSONEachRow")"'
check "S4 no flag, empty (a): the scale-down precedes (c)" '[[ "$(lines_of "$NETLIST" | sed -n 2p)" -gt "$(line_of "^kubectl .* scale ")" ]]'

# ================================================================== S5 — no flag, a Network appears between (a) and (c)
setup appear
rm -f "$FAKE_STATE/k8s/$CL/$IN/network/"*.json
jq -cn --arg ns "$IN" '{apiVersion: "fabric.agentic-netops.io/v1alpha1", kind: "Network", metadata: {name: "svc-late", namespace: $ns, labels: {"agentic-netops.io/correlation-id": "c-late"}}, fake: {finalize: "ok"}}' >"$W/late.json"
FAKE_APPEAR_ON_SCALE="$W/late.json" run_off --purge-intent-tier
check "S5 fallback: non-zero" '[[ $rc -ne 0 ]]'
check "S5 fallback: the Network that appeared is named" 'grep -q "svc-late" <<<"$out"'
check "S5 fallback: both continuations named" 'grep -q -- "--remove-services" <<<"$out" && grep -qi "remove the services first" <<<"$out"'
check "S5 fallback: no delete and no export issued" '[[ -z "$(deletes)" && -z "$(exports)" && -z "$(artefacts)" ]]'
check "S5 fallback: the workloads are left at zero" '[[ "$(replicas supervisor)" == 0 && "$(replicas deployer)" == 0 ]]'
check "S5 fallback: re-provisioning is named as what restores them" 'grep -q "provision.sh --with-intent-tier" <<<"$out"'
check "S5 fallback: the planted evidence is byte-identical" 'planted_intact'

# ================================================================== S6 — export failures stop with the store intact
setup unqueryable
echo unqueryable >"$FAKE_STATE/store/mode"
AUDIT_EXPORT_TIMEOUT_SECONDS=2 run_off --purge-intent-tier --remove-services
check "S6 unqueryable within AUDIT_EXPORT_TIMEOUT_SECONDS (override 2 s honoured): non-zero, promptly" '[[ $rc -ne 0 && $elapsed -ge 2 && $elapsed -lt 30 ]]'
check "S6 unqueryable: the failure names the bound" 'grep -q "AUDIT_EXPORT_TIMEOUT_SECONDS=2" <<<"$out" && grep -qi "unqueryable" <<<"$out"'
check "S6 unqueryable: the store is intact, nothing deleted" 'store_intact'
check "S6 unqueryable: --discard-audit-record is named as the only way past" 'grep -q -- "--discard-audit-record" <<<"$out"'

setup query-error
echo query-error >"$FAKE_STATE/store/mode"
run_off --purge-intent-tier --remove-services
check "S6 query error: non-zero, named, store intact" '[[ $rc -ne 0 ]] && grep -qi "query" <<<"$out" && store_intact'

setup short
echo short >"$FAKE_STATE/store/mode"
run_off --purge-intent-tier --remove-services
check "S6 short row count: non-zero, both counts named, store intact" '[[ $rc -ne 0 ]] && grep -qE "2 row.*3|fewer" <<<"$out" && store_intact'

setup unwritable
export EVIDENCE_DIR="$EVIDENCE_ROOT/$LABROOT_REL/20260201T000000Z"
mkdir -p "$EVIDENCE_DIR/audit-export-fixedattempt.ndjson.gz"
AUDIT_EXPORT_ATTEMPT=fixedattempt run_off --purge-intent-tier --remove-services
unset EVIDENCE_DIR
check "S6 unwritable artefact: non-zero, named, store intact" '[[ $rc -ne 0 ]] && grep -qiE "writ" <<<"$out" && store_intact'

setup discard
echo query-error >"$FAKE_STATE/store/mode"
run_off --purge-intent-tier --remove-services --discard-audit-record
check "S6 --discard-audit-record: goes past the failed export and completes" '[[ $rc -eq 0 ]] && ! exists "_/namespace/$AG"'
check "S6 --discard-audit-record: its use is printed" 'grep -q -- "--discard-audit-record was given" <<<"$out"'
check "S6 --discard-audit-record: its use is written to the run's evidence" \
  'f="$(find "$EVIDENCE_ROOT" -name "*discard-audit-record*.json" | head -1)" && [[ -n "$f" ]] && stdout_of "$f" | grep -q "FAILED"'

setup absent-store
rm -f "$FAKE_STATE/k8s/$CL/$AG/statefulset/clickhouse.json"
run_off --purge-intent-tier --remove-services
check "S6 absent store: skipped, the purge completes" '[[ $rc -eq 0 && -z "$(artefacts)" ]] && grep -qiE "no analytics store|store.*absent" <<<"$out"'

setup empty-store
: >"$FAKE_STATE/store/tables/otel_traces.ndjson"
run_off --purge-intent-tier --remove-services
A="$(artefacts | head -1)"
check "S6 empty store: a successful empty export" '[[ $rc -eq 0 && -n "$A" ]] && [[ "$(zcat "$A" | grep -c .)" -eq 0 ]]'
check "S6 empty store: the record says 0 rows and no newest row" 'stdout_of "${A%.ndjson.gz}.json" | jq -e ".store_rows == 0 and .rows_written == 0 and .newest_row_timestamp == null" >/dev/null'

# ================================================================== S7 — the full off.sh
for mode in plain preserve; do
  setup "full-$mode"
  # an earlier provisioning run's capture under the lab's evidence root with a different username
  ( unset EVIDENCE_DIR; export CLUSTER_NAME="$CL" LAB_NAME="$LAB"
    source "$ROOT/scripts/lib/evidence.sh"
    evidence_run operator-username-20260101T000000Z-early -- printf 'username: alice\n' >/dev/null )
  if [[ "$mode" == preserve ]]; then run_off --preserve-evidence; else run_off; fi
  check "S7 full off.sh ($mode): exits 0 with tier Networks present — it never asks for --remove-services" \
    '[[ $rc -eq 0 ]] && ! grep -q -- "--remove-services" <<<"$out"'
  check "S7 full off.sh ($mode): the export runs whether or not evidence capture was requested" '[[ -n "$(exports)" && -n "$(artefacts)" ]]'
  check "S7 full off.sh ($mode): the export precedes the store's deletion (the cluster, clickhouse-auth)" \
    'lt "$(line_of "^kubectl .* exec .*JSONEachRow")" "$(line_of "^kind delete cluster")" && lt "$(line_of "^kubectl .* exec .*JSONEachRow")" "$(line_of "delete secret clickhouse-auth")" && grep -q "MARK audit-export-present=yes" "$FAKE_STATE/calls.log"'
  check "S7 full off.sh ($mode): the usernames record is written before operator-credentials is deleted" 'grep -q "MARK usernames-record-present=yes" "$FAKE_STATE/calls.log"'
  U="$(find "$EVIDENCE_ROOT" -name 'operator-usernames-*.json' | head -1)"
  check "S7 full off.sh ($mode): the lab's captures differ → username_unchanged false, both names listed" \
    '[[ -n "$U" ]] && stdout_of "$U" | jq -e ".usernames == [\"alice\",\"operator\"] and .username_unchanged == false" >/dev/null'
  check "S7 full off.sh ($mode): no password in the evidence" '! grep -rqF "$OPW" "$EVIDENCE_ROOT" && ! grep -rqF "$CHPW" "$EVIDENCE_ROOT"'
  check "S7 full off.sh ($mode): the planted evidence is byte-identical" 'planted_intact'
done
setup full-fail
echo query-error >"$FAKE_STATE/store/mode"
run_off
check "S7 full off.sh: a failed export stops it non-zero with the store intact" '[[ $rc -ne 0 ]] && store_intact && [[ -e "$FAKE_STATE/kind/$CL" ]]'

# ================================================================== S8 — the wait
setup slow
net "$IN" svc-a c-a slow
TIER_PURGE_WAIT_SECONDS=2 run_off --purge-intent-tier --remove-services
check "S8 still Deleting after TIER_PURGE_WAIT_SECONDS (override 2 s honoured): non-zero after the bound" '[[ $rc -ne 0 && $elapsed -ge 2 && $elapsed -lt 30 ]]'
check "S8 the Network and what is outstanding are named" 'grep -q "svc-a" <<<"$out" && grep -q "leaf02" <<<"$out" && grep -q "TIER_PURGE_WAIT_SECONDS=2" <<<"$out"'
check "S8 the tier stays in place (workloads, store), scaled down" 'exists "$AG/deployment/mapper" && exists "$AG/deployment/supervisor" && exists "$AG/statefulset/clickhouse" && [[ "$(replicas supervisor)" == 0 ]]'
check "S8 no namespace deleted, no Secret deleted, before a re-list is empty" '! grep -qE "delete (namespace|secret) " "$FAKE_STATE/calls.log" && exists "_/namespace/$IN"'
check "S8 never force-released" 'no_force_release'
check "S8 the planted evidence is byte-identical after a stopped purge" 'planted_intact'

setup unreachable
net "$IN" svc-a c-a unreachable
TIER_PURGE_WAIT_SECONDS=60 run_off --purge-intent-tier --remove-services
check "S8 already Deleting=True/TargetUnreachable: the wait is not spent on it (stops at once)" '[[ $rc -ne 0 && $elapsed -lt 15 ]]'
check "S8 TargetUnreachable: the Network and its unreachable target are named" 'grep -q "svc-a" <<<"$out" && grep -q "TargetUnreachable" <<<"$out" && grep -q "leaf02" <<<"$out"'
check "S8 TargetUnreachable: tier left in place, no namespace deleted, no force-release" \
  'exists "$AG/statefulset/clickhouse" && ! grep -q "delete namespace" "$FAKE_STATE/calls.log" && no_force_release'

setup holder
net "$IN" svc-b c-b holder
TIER_PURGE_WAIT_SECONDS=60 run_off --purge-intent-tier --remove-services
check "S8 HolderPresent: stops at once naming the Network and its holder (AD-72)" \
  '[[ $rc -ne 0 && $elapsed -lt 15 ]] && grep -q "svc-b" <<<"$out" && grep -q "HolderPresent" <<<"$out" && grep -q "acl-holder" <<<"$out"'

# ================================================================== S9 — the one re-run rule
# blocked <case> — a purge that exported (A1) and then stopped on an unreachable target
blocked() {
  setup "$1"
  net "$IN" svc-a c-a unreachable
  run_off --purge-intent-tier --remove-services
  A1="$(artefacts | head -1)"; A1_RUN="$(dirname "$A1")"
  [[ $rc -ne 0 && -n "$A1" ]] || { bad "S9 $1: the blocked first attempt did not export and stop (rc=$rc)"; printf '%s\n' "$out" | tail -5; }
  jq '.fake.finalize = "ok"' "$FAKE_STATE/k8s/$CL/$IN/network/svc-a.json" >"$W/n" && mv "$W/n" "$FAKE_STATE/k8s/$CL/$IN/network/svc-a.json"   # the target returns
  sleep 1   # the re-run's per-run EVIDENCE_DIR is a new directory
}
blocked rerun-skip
A1_SUM="$(sha256sum "$A1" | cut -d' ' -f1)"
run_off --purge-intent-tier --remove-services
SK="$(find "$EVIDENCE_ROOT" -name 'audit-export-skip-*.json' | head -1)"
check "S9 verified: the re-run completes" '[[ $rc -eq 0 ]] && ! exists "_/namespace/$IN"'
check "S9 verified: it SKIPS — no second artefact" '[[ "$(artefacts | wc -l)" -eq 1 ]]'
check "S9 verified: the skip is captured through evidence_run, naming the artefact relied on" '[[ -n "$SK" ]] && stdout_of "$SK" | grep -qF "$(basename "$A1")"'
check "S9 verified: found under the lab's evidence root although this run's EVIDENCE_DIR is new" '[[ "$(dirname "$SK")" != "$A1_RUN" ]]'
check "S9 verified: the first artefact's hash is unchanged" '[[ "$(sha256sum "$A1" | cut -d" " -f1)" == "$A1_SUM" ]]'
check "S9 verified: the usernames record is still written before the Secret goes" 'grep -q "MARK usernames-record-present=yes" "$FAKE_STATE/calls.log"'

for brk in hash rows newest; do
  blocked "rerun-$brk"
  case "$brk" in
    hash) printf 'x' >>"$A1" ;;                                                      # a changed hash
    rows) row otel_traces "2026-09-24 10:00:04.000000000" confirm ;;                 # more rows now
    newest) echo "2026-09-25 08:00:00.000000000" >"$FAKE_STATE/store/newest" ;;      # same count, other store
  esac
  A1_SUM="$(sha256sum "$A1" | cut -d' ' -f1)"
  run_off --purge-intent-tier --remove-services
  A2="$(artefacts | grep -vxF "$A1" | head -1)"
  check "S9 broken ($brk): the re-run ADDS an artefact" '[[ $rc -eq 0 && "$(artefacts | wc -l)" -eq 2 && -n "$A2" ]]'
  check "S9 broken ($brk): …under a new attempt identifier" '[[ "$(basename "$A2")" != "$(basename "$A1")" ]]'
  check "S9 broken ($brk): no skip is recorded" '[[ -z "$(find "$EVIDENCE_ROOT" -name "audit-export-skip-*.json")" ]]'
  check "S9 broken ($brk): the first artefact's hash is unchanged by the re-run" '[[ "$(sha256sum "$A1" | cut -d" " -f1)" == "$A1_SUM" ]]'
done

# ================================================================== S10 — the stand-alone export
setup standalone
out="$(cd "$ROOT" && CLUSTER_NAME="$CL" LAB_NAME="$LAB" bash scripts/lib/audit_export.sh export 2>&1)"; rc=$?
check "S10 stand-alone export: exits 0, writes the export and the usernames record" \
  '[[ $rc -eq 0 && -n "$(artefacts)" && -n "$(find "$EVIDENCE_ROOT" -name "operator-usernames-*.json")" ]]'
check "S10 stand-alone export: removes nothing" '[[ -z "$(mutating)" ]] && exists "$AG/secret/operator-credentials" && exists "$AG/statefulset/clickhouse"'

# ================================================================== S11 — static
# the one patch verb allowed is the Grafana two-line patch of R-19 (T137): Deployment monitoring/grafana
# only, never a Network, never an annotation
check "S11 static: the purge's code writes no force-release annotation (no annotate; no patch but the Grafana two-line patch)" \
  '! grep -nE "(^|[^[:alnum:]_])annotate[[:space:]]|fabric\.agentic-netops\.io/force-release" "$ROOT/scripts/off.sh" "$ROOT/scripts/lib/intent_tier.sh" "$ROOT/scripts/lib/audit_export.sh" \
   && ! grep -nE "(^|[^[:alnum:]_])patch[[:space:]]" "$ROOT/scripts/off.sh" "$ROOT/scripts/lib/audit_export.sh" \
   && ! grep -nE "(kubectl|::k)[[:space:]]+(.*[^[:alnum:]_])?patch[[:space:]]" "$ROOT/scripts/lib/intent_tier.sh" | grep -vF "patch deployment \"\$INTENT_TIER_GRAFANA_DEPLOYMENT\" -n \"\$INTENT_TIER_GRAFANA_NS\"" | grep -q .'
check "S11 static: nothing under .evidence is ever removed by the purge's code" \
  '! grep -nE "rm .*(\.evidence|EVIDENCE_(ROOT|DIR))" "$ROOT/scripts/off.sh" "$ROOT/scripts/lib/intent_tier.sh" "$ROOT/scripts/lib/audit_export.sh"'

printf '\ntier_purge_test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
