#!/usr/bin/env bash
# g11_allocation_claim.sh — capability-gate item G11: the allocation claim round-trip
# (T044, T181; FR-104, FR-108, FR-109, CD-03, AD-09, AD-32, AD-33, AD-47, AD-56, R-31, R-44,
# NFR-013, SC-047; contracts/kuid-claim-profiles.md §4, §6, §7; quickstart.md §1 gate table).
#
# Live, against whichever allocation authority versions.lock.yaml selects
# (allocationAuthority.kind — read here through gate::authority_kind, never a flag or a
# variable), on the pinned cluster, with kubectl only; every kubectl call runs inside
# `evidence_run` / `evidence_negative_control` (NFR-013). There is no third authority: a
# failure here stops provisioning exactly the same way on either.
#
#   kuid         the pinned kuid-server's *.be.kuid.dev claims in kuid-system. Scratch
#                indices: a VLANIndex 1000–4000 (the allocation band), a GENIDIndex
#                10000–20000 (the VNI band) and a narrow GENIDIndex 10000–10009.
#   first-party  the recorded substitute's IdentifierClaims (fabric.agentic-netops.io) in
#                agentic-netops-allocation. Scratch pools with the same ranges: IdentifierPool
#                vlan 1000–4000, vni 10000–20000 and a narrow vni 10000–10009.
# Every scratch object is named `vt-scratch-g11-…` (FR-108) and labelled
# agentic-netops.io/verification-scratch=g11 — on first-party also with the gate-owned label
# agentic-netops.io/gate-owned=true (tests/lib/lab.sh), so tests/lib/leftovers.sh finds any that
# an interrupted run left behind. The script refuses to start while any `vt-scratch-g11-` object
# is present, and it removes everything it created and reads the removal back.
#
# What it establishes (the six observations are contracts/kuid-claim-profiles.md §6 — the one
# list and the one count, AD-56 — each RECORDED, never assumed):
#   API        kuid: the aggregated APIServices v1alpha1.{vlan,genid}.be.kuid.dev are Available;
#              first-party: both CRDs Established and the Deployment allocation-authority Available
#   round trip a dynamic VLAN claim and a dynamic VNI claim each report their value in status
#              (kuid status.id, first-party status.value) with Ready=True, and are released (the
#              removal read back); a claim whose status reports no value is TERMINAL (R-31) — G11
#              fails, nothing proceeds on it
#   (a)        a claim for a STATED value binds exactly that value
#              negative control: the same check against an index/pool not containing the value
#              (first-party: refused OutOfRange)
#   (b)        a second claim for the same value is refused and the refusal NAMES the holder
#              (first-party: Ready=False Conflict, the message naming <namespace>/<holder>)
#              negative control: the same check for a value nobody holds (it binds)
#   (c)        which value three consecutive dynamic claims return (lowest free or arbitrary)
#   (d)        no dynamic claim is handed a value below the index's minID / the pool's start
#              negative control: the same check with a floor above the values seen
#   (e)        a claim's metadata.labels are selectable with -l
#              negative control: the label written somewhere else — kuid: the authority's own
#              spec.labels; first-party (no spec.labels exists): an annotation — selects nothing
#   (f)        deleting a claim frees its value synchronously: the stated-value claim is deleted
#              (kubectl delete returns once it is gone) and an IMMEDIATE second claim binds
#              negative control: that same second claim while the first still exists
# The result — every observation, the values seen, the refusal text, pass/fail, and
# authority.kind — is written to $EVIDENCE_DIR/g11-observations.json and attached to the recorded
# run `g11-result`. Exit 0 = G11 holds; non-zero = G11 failed (the reason is named).
#
# Environment: CLUSTER_NAME (default agentic-netops; context kind-<cluster>), LAB_NAME,
# EVIDENCE_DIR, KUBECTL (default kubectl), G11_NAMESPACE (default: the selected authority's
# namespace), G11_POLL_ATTEMPTS (default 30) and G11_POLL_INTERVAL (seconds, default 1) bound
# every read-back; G11_SETTLE_READS / G11_SETTLE_INTERVAL the clean reads of the removal. The
# lock file is the tree's own versions.lock.yaml (not overridable).
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../.." && pwd)"
# shellcheck source=../../scripts/lib/log.sh
source "$ROOT/scripts/lib/log.sh"
# shellcheck source=../../scripts/lib/evidence.sh
source "$ROOT/scripts/lib/evidence.sh"
# shellcheck source=../../scripts/lib/gate.sh
source "$ROOT/scripts/lib/gate.sh"
# shellcheck source=../lib/lab.sh
source "$ROOT/tests/lib/lab.sh"

: "${CLUSTER_NAME:=agentic-netops}"
: "${LAB_NAME:=agentic-netops-fabric}"
export CLUSTER_NAME LAB_NAME
ATTEMPTS="${G11_POLL_ATTEMPTS:-30}"
INTERVAL="${G11_POLL_INTERVAL:-1}"
LOCK="$ROOT/versions.lock.yaml"
[[ -n "${LOG_PHASE:-}" && "$LOG_PHASE" != "-" ]] || LOG_PHASE="G11"

VLAN_MIN=1000 VLAN_MAX=4000 VNI_MIN=10000 VNI_MAX=20000
NARROW_MIN=10000 NARROW_MAX=10009
STATED=15000                        # inside the VNI band, outside the narrow index/pool
FREE_STATED=15001                   # a value nobody holds, for (b)'s negative control
RUN_LABEL_KEY="agentic-netops.io/g11-probe"
SCRATCH_LABEL_KEY="agentic-netops.io/verification-scratch"
IDX_VLAN="vt-scratch-g11-vlan"      # 1000–4000
IDX_VNI="vt-scratch-g11-vni"        # 10000–20000
IDX_NARROW="vt-scratch-g11-narrow"  # 10000–10009 (negative control only)

evidence::ensure_dir
RUN_TAG="$(basename "$EVIDENCE_DIR" | tr -c 'a-zA-Z0-9\n' '-' | tr '[:upper:]' '[:lower:]' | cut -c1-40)"
RUN_TAG="${RUN_TAG%-}"; RUN_TAG="${RUN_TAG:-run}"
# Claim manifests are scratch (each is printed into the recorded stdout of the run that
# applies it); the index/pool manifest is written once and attached to the run that applies
# it, so nothing unreferenced is ever left in EVIDENCE_DIR (make verify-evidence).
MAN="$(mktemp -d)"
RESULT="$EVIDENCE_DIR/g11-observations.json"
FAILURES=()
ERRF="$(mktemp)"   # a kubectl call's stderr, kept apart from the JSON it prints on stdout

k() { "${KUBECTL:-kubectl}" --context "kind-${CLUSTER_NAME}" "$@"; }

fail() { FAILURES+=("$*"); log::error "G11: $*"; }

# obs <jq-path> <json-value> — record a value into the result document as it is observed.
OBS='{}'
obs() { OBS="$(jq -c --argjson v "$2" "$1 = \$v" <<<"$OBS")"; }

# ---------------------------------------------------------------- the selected authority
AUTH="$(gate::authority_kind)" || AUTH=""   # an inadmissible lock is logged by gate.sh
case "$AUTH" in
  kuid)
    NS="${G11_NAMESPACE:-kuid-system}"
    VLAN_RES="vlanclaims.vlan.be.kuid.dev"
    GENID_RES="genidclaims.genid.be.kuid.dev"
    VLAN_IDX_RES="vlanindices.vlan.be.kuid.dev"
    GENID_IDX_RES="genidindices.genid.be.kuid.dev"
    INDICES_NAME="g11-indices.yaml"
    VALUE_FIELD="id"
    WHAT_POOL="index" ;;
  first-party)
    NS="${G11_NAMESPACE:-$(gate::authority_namespace first-party)}"
    VLAN_RES="identifierclaims.fabric.agentic-netops.io"
    GENID_RES="$VLAN_RES"
    VLAN_IDX_RES="identifierpools.fabric.agentic-netops.io"
    GENID_IDX_RES="$VLAN_IDX_RES"
    INDICES_NAME="g11-pools.yaml"
    VALUE_FIELD="value"
    WHAT_POOL="pool"
    FP_DEPLOYMENT="allocation-authority"
    FP_CRDS=(identifierpools.fabric.agentic-netops.io identifierclaims.fabric.agentic-netops.io) ;;
  *)
    NS="${G11_NAMESPACE:-kuid-system}"; INDICES_NAME="g11-indices.yaml"; VALUE_FIELD="id"; WHAT_POOL="index" ;;
esac
INDICES="$EVIDENCE_DIR/$INDICES_NAME"

# ---------------------------------------------------------------- manifests
claim_manifest() {  # claim_manifest <file> <kind VLAN|GENID> <name> <index> <stated|-> [misplaced-label]
  local file="$1" kind="$2" name="$3" index="$4" stated="$5" misplaced="${6:-}" group
  if [[ "$AUTH" == first-party ]]; then
    {
      printf 'apiVersion: fabric.agentic-netops.io/v1alpha1\nkind: IdentifierClaim\nmetadata:\n'
      printf '  name: %s\n  namespace: %s\n  labels:\n' "$name" "$NS"
      printf '    %s: g11\n' "$SCRATCH_LABEL_KEY"
      printf '    %s: "%s"\n' "$LAB_GATE_LABEL_KEY" "$LAB_GATE_LABEL_VALUE"
      # the selector label lives in metadata.labels — except for (e)'s control, where it is
      # written as an annotation (IdentifierClaim has no spec.labels: its schema is structural)
      [[ -z "$misplaced" ]] && printf '    %s: %s\n' "$RUN_LABEL_KEY" "$RUN_TAG"
      [[ -n "$misplaced" ]] && printf '  annotations:\n    %s: %s\n' "$RUN_LABEL_KEY" "$misplaced"
      printf 'spec:\n  poolRef:\n    name: %s\n' "$index"
      [[ "$stated" != "-" ]] && printf '  requested: "%s"\n' "$stated"
      :
    } >"$file"
    return 0
  fi
  case "$kind" in VLAN) group=vlan ;; GENID) group=genid ;; esac
  {
    printf 'apiVersion: %s.be.kuid.dev/v1alpha1\nkind: %sClaim\nmetadata:\n' "$group" "$kind"
    printf '  name: %s\n  namespace: %s\n  labels:\n' "$name" "$NS"
    printf '    %s: g11\n' "$SCRATCH_LABEL_KEY"
    # the selector label lives in metadata.labels — except for the spec.labels control
    [[ -z "$misplaced" ]] && printf '    %s: %s\n' "$RUN_LABEL_KEY" "$RUN_TAG"
    printf 'spec:\n  index: %s\n' "$index"
    [[ "$stated" != "-" ]] && printf '  id: %s\n' "$stated"
    [[ -n "$misplaced" ]] && printf '  labels:\n    %s: %s\n' "$RUN_LABEL_KEY" "$misplaced"
    :
  } >"$file"
}

resource_of() { case "$1" in VLAN) echo "$VLAN_RES" ;; GENID) echo "$GENID_RES" ;; esac; }

write_pools_manifest() {
  if [[ "$AUTH" == first-party ]]; then
    local p name t lo hi
    for p in "$IDX_VLAN vlan $VLAN_MIN $VLAN_MAX" "$IDX_VNI vni $VNI_MIN $VNI_MAX" "$IDX_NARROW vni $NARROW_MIN $NARROW_MAX"; do
      read -r name t lo hi <<<"$p"
      cat <<YAML
---
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: IdentifierPool
metadata:
  name: ${name}
  namespace: ${NS}
  labels: {${SCRATCH_LABEL_KEY}: g11, ${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}"}
spec:
  type: ${t}
  range: {start: ${lo}, end: ${hi}}
YAML
    done
    return 0
  fi
  cat <<YAML
apiVersion: vlan.be.kuid.dev/v1alpha1
kind: VLANIndex
metadata:
  name: ${IDX_VLAN}
  namespace: ${NS}
  labels: {${SCRATCH_LABEL_KEY}: g11}
spec:
  minID: ${VLAN_MIN}
  maxID: ${VLAN_MAX}
---
apiVersion: genid.be.kuid.dev/v1alpha1
kind: GENIDIndex
metadata:
  name: ${IDX_VNI}
  namespace: ${NS}
  labels: {${SCRATCH_LABEL_KEY}: g11}
spec:
  type: 32bit
  minID: ${VNI_MIN}
  maxID: ${VNI_MAX}
---
apiVersion: genid.be.kuid.dev/v1alpha1
kind: GENIDIndex
metadata:
  name: ${IDX_NARROW}
  namespace: ${NS}
  labels: {${SCRATCH_LABEL_KEY}: g11}
spec:
  type: 32bit
  minID: ${NARROW_MIN}
  maxID: ${NARROW_MAX}
YAML
}

# ---------------------------------------------------------------- check functions
# Each is run INSIDE evidence_run, so its kubectl calls and their raw output are the
# record. Each prints one JSON line (the observation) as its last stdout line.

# claim_readback <res> <name> — bounded poll: prints the claim JSON once it reports a
# value (status.id / status.value) or a Ready=False refusal; exit 0 = value, 3 = refused,
# 4 = no value (terminal, R-31), 5 = the claim does not exist. A first-party claim waiting
# for its pool (Ready=Unknown PoolNotFound) is read again until the bound runs out.
claim_readback() {
  local res="$1" name="$2" i out val ready
  for ((i = 1; i <= ATTEMPTS; i++)); do
    if out="$(k get "$res" "$name" -n "$NS" -o json 2>"$ERRF")"; then
      val="$(jq -r --arg f "$VALUE_FIELD" '.status[$f] // empty' <<<"$out")"
      ready="$(jq -r '[.status.conditions[]? | select(.type=="Ready")][0].status // ""' <<<"$out")"
      if [[ "$ready" == True && -n "$val" ]]; then printf '%s\n' "$out"; return 0; fi
      if [[ "$ready" == False && -z "$val" ]]; then printf '%s\n' "$out"; return 3; fi
      if [[ "$ready" == True && -z "$val" ]]; then
        printf '%s\n' "$out"; echo "claim ${name} is Ready but reports no value in status.${VALUE_FIELD}" >&2; return 4
      fi
    elif grep -q NotFound "$ERRF"; then
      cat "$ERRF" >&2; return 5
    fi
    cat "$ERRF" >&2
    [[ "$i" -lt "$ATTEMPTS" ]] && sleep "$INTERVAL"
  done
  printf '%s\n' "${out:-}"
  echo "claim ${name} reported no value within ${ATTEMPTS} read-back(s): terminal (R-31)" >&2
  return 4
}

# claim_create_readback <kind> <name> <index> <stated|-> [misplaced-label] — create the claim
# and read it back; prints {"name","created","value","ready","reason","message"} as the last
# line. exit 0 bound, 3 refused (at create or Ready=False), 4 no value (terminal).
claim_create_readback() {
  local kind="$1" name="$2" index="$3" stated="$4" misplaced="${5:-}" res file out rc=0 msg=""
  res="$(resource_of "$kind")"
  file="$MAN/${name}.yaml"
  claim_manifest "$file" "$kind" "$name" "$index" "$stated" "$misplaced"
  echo "--- manifest ${name}"; cat "$file"; echo "---"
  if ! out="$(k create -f "$file" -o json 2>"$ERRF")"; then
    msg="$(cat "$ERRF")"
    printf '%s\n' "$msg"
    jq -n -c --arg n "$name" --arg m "$msg" '{name: $n, created: false, value: null, ready: false, reason: "CreateRefused", message: $m}'
    return 3
  fi
  printf '%s\n' "$out"
  out="$(claim_readback "$res" "$name")" || rc=$?
  printf '%s\n' "$out"
  if [[ "$rc" -eq 5 ]]; then
    jq -n -c --arg n "$name" '{name: $n, created: true, value: null, ready: false, reason: "", message: "claim vanished after create"}'
    return 4
  fi
  jq -c --arg n "$name" --arg f "$VALUE_FIELD" \
    '([.status.conditions[]? | select(.type=="Ready")][0]) as $r
     | {name: $n, created: true, value: (.status[$f] // null), ready: ($r.status == "True"),
        reason: ($r.reason // ""), message: ($r.message // "")}' \
    <<<"$out" 2>/dev/null || jq -n -c --arg n "$name" '{name: $n, created: true, value: null, ready: false, reason: "", message: ""}'
  return "$rc"
}

# check_dynamic <kind> <name> <index> — a dynamic claim (no stated value) reports a value; the
# value is not checked against the band here (that is (d)).
check_dynamic() { claim_create_readback "$1" "$2" "$3" -; }

# check_stated_binds <kind> <name> <index> <value> — (a): the claim stating <value> binds
# exactly <value>.
check_stated_binds() {
  local kind="$1" name="$2" index="$3" value="$4" last rc=0 got
  last="$(claim_create_readback "$kind" "$name" "$index" "$value" | tee /dev/stderr | tail -n1)" || rc=$?
  got="$(jq -r '.value // empty' <<<"$last" 2>/dev/null || true)"
  if [[ "$rc" -ne 0 ]]; then
    echo "stated-value claim ${name} for ${value} did not bind (exit ${rc}; $(jq -r '[.reason, .message] | map(select(. != "")) | join(": ")' <<<"$last" 2>/dev/null))" >&2
    return 1
  fi
  if [[ "$got" != "$value" ]]; then echo "stated-value claim ${name} for ${value} bound ${got:-nothing} instead" >&2; return 1; fi
  echo "stated-value claim ${name} bound exactly ${value}"
}

# check_refused_naming_holder <kind> <name> <index> <value> <holder> — (b): a second claim
# for <value> is refused and the refusal names <holder> (first-party: as <namespace>/<holder>).
check_refused_naming_holder() {
  local kind="$1" name="$2" index="$3" value="$4" holder="$5" last rc=0 msg want
  last="$(claim_create_readback "$kind" "$name" "$index" "$value" | tail -n1)" || rc=$?
  printf '%s\n' "$last"
  if [[ "$rc" -eq 0 ]]; then echo "second claim ${name} for ${value} was NOT refused: it bound $(jq -r '.value' <<<"$last")" >&2; return 1; fi
  if [[ "$rc" -eq 4 ]]; then echo "second claim ${name} for ${value} neither bound nor was refused: no value, no refusal" >&2; return 1; fi
  msg="$(jq -r '.message // ""' <<<"$last")"
  want="$holder"; [[ "$AUTH" == first-party ]] && want="${NS}/${holder}"
  if [[ "$msg" != *"$want"* ]]; then echo "second claim ${name} for ${value} was refused, but the refusal does not name the holder ${want}: ${msg}" >&2; return 1; fi
  echo "second claim ${name} for ${value} refused naming the holder ${want}"
}

# check_selected <res> <selector> <expected names…> — (e): `get -l <selector>` returns exactly
# the expected claims.
check_selected() {
  local res="$1" sel="$2"; shift 2
  local out got want
  out="$(k get "$res" -n "$NS" -l "$sel" -o json)" || return 1
  got="$(jq -r '[.items[].metadata.name] | sort | join(",")' <<<"$out")"
  want="$(printf '%s\n' "$@" | sort | paste -sd, -)"
  echo "selector ${sel} returned: [${got}] expected: [${want}]"
  [[ "$got" == "$want" ]]
}

# check_values_at_least <floor> <values…> — (d)
check_values_at_least() {
  local floor="$1" v; shift
  for v in "$@"; do
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "value '${v}' is not an integer" >&2; return 1; }
    if [[ "$v" -lt "$floor" ]]; then echo "value ${v} is below ${floor}" >&2; return 1; fi
  done
  echo "every value of [$*] is >= ${floor}"
}

# check_absent <res> <name> — the removal read back
check_absent() {
  local out
  if out="$(k get "$1" "$2" -n "$NS" -o name 2>&1)"; then echo "$1/$2 still present" >&2; return 1; fi
  grep -q NotFound <<<"$out" || { echo "$out" >&2; return 1; }
  echo "$1/$2 absent"
}

# scratch_objects — every vt-scratch-g11- index/pool or claim in the namespace (one per line,
# <resource>/<name>); on first-party also every claim of a scratch pool and every gate-labelled
# claim or pool, whatever its name.
scratch_objects() {
  if [[ "$AUTH" == first-party ]]; then
    local res out
    for res in identifierclaims.fabric.agentic-netops.io identifierpools.fabric.agentic-netops.io; do
      out="$(k get "$res" -n "$NS" -o json)" || return 1
      jq -r --arg r "${res%%s.*}.${res#*.}" --arg k "$LAB_GATE_LABEL_KEY" --arg v "$LAB_GATE_LABEL_VALUE" '
        .items[]? | select((.metadata.name | startswith("vt-scratch-g11-"))
                           or ((.spec.poolRef.name // "") | startswith("vt-scratch-g11-"))
                           or ((.metadata.labels // {})[$k] == $v))
        | "\($r)/\(.metadata.name)"' <<<"$out"
    done
    return 0
  fi
  k get "vlanclaims.vlan.be.kuid.dev,genidclaims.genid.be.kuid.dev,vlanindices.vlan.be.kuid.dev,genidindices.genid.be.kuid.dev" \
    -n "$NS" -o name | grep 'vt-scratch-g11-' || true
}
check_no_scratch() {
  # The authority deletes asynchronously and re-creates its own reserved-range claims from an index
  # reconcile (observed on kuid v0.0.13: vt-scratch-g11-vlan.rangereservedmax reappeared after one
  # clean read), so absence is admitted only after G11_SETTLE_READS consecutive clean reads
  # G11_SETTLE_INTERVAL seconds apart — one immediate read is not a read-back.
  local left n reads="${G11_SETTLE_READS:-3}" gap="${G11_SETTLE_INTERVAL:-3}"
  for ((n = 1; n <= reads; n++)); do
    left="$(scratch_objects)" || { echo "the ${WHAT_POOL}s and claims in ${NS} could not be listed"; return 1; }
    if [[ -n "$left" ]]; then echo "vt-scratch-g11 objects present (read ${n}/${reads}):"; echo "$left"; return 1; fi
    [[ "$n" -lt "$reads" ]] && sleep "$gap"
  done
  echo "no vt-scratch-g11 object in ${NS} (${reads} consecutive reads, ${gap}s apart)"
}

check_api_available() {
  local out
  if [[ "$AUTH" == first-party ]]; then
    out="$(k get crd "${FP_CRDS[@]}" -o json)" || return 1
    printf '%s\n' "$out"
    jq -e '(.items | length) == 2 and all(.items[]; any(.status.conditions[]?; .type == "Established" and .status == "True"))' <<<"$out" >/dev/null \
      || { echo "CRDs ${FP_CRDS[*]} are not both Established" >&2; return 1; }
    out="$(k get deployment "$FP_DEPLOYMENT" -n "$NS" -o json)" || return 1
    printf '%s\n' "$out"
    jq -e 'any(.status.conditions[]?; .type == "Available" and .status == "True")' <<<"$out" >/dev/null \
      || { echo "Deployment ${NS}/${FP_DEPLOYMENT} is not Available" >&2; return 1; }
    return 0
  fi
  out="$(k get apiservice v1alpha1.vlan.be.kuid.dev v1alpha1.genid.be.kuid.dev -o json)" || return 1
  printf '%s\n' "$out"
  jq -e '(.items | length) == 2 and all(.items[]; any(.status.conditions[]?; .type == "Available" and .status == "True"))' <<<"$out" >/dev/null
}

check_index_ready() {  # check_index_ready <res> <name>
  local i out
  for ((i = 1; i <= ATTEMPTS; i++)); do
    out="$(k get "$1" "$2" -n "$NS" -o json 2>"$ERRF")" || { cat "$ERRF" >&2; out=""; }
    if jq -e 'any(.status.conditions[]?; .type == "Ready" and .status == "True")' <<<"$out" >/dev/null 2>&1; then
      printf '%s\n' "$out"; return 0
    fi
    [[ "$i" -lt "$ATTEMPTS" ]] && sleep "$INTERVAL"
  done
  printf '%s\n' "$out"; echo "$1/$2 not Ready within ${ATTEMPTS} read-back(s)" >&2; return 1
}

# delete_claim <kind> <name> — release (idempotent), recorded
N_DEL=0
delete_claim() {
  N_DEL=$((N_DEL + 1))
  evidence_run "g11-release-${N_DEL}-$2" -- k delete "$(resource_of "$1")" "$2" -n "$NS" --ignore-not-found >/dev/null || true
}

last_json() { tail -n1 "$EVIDENCE_DIR/$1.stdout" 2>/dev/null || echo '{}'; }

# ---------------------------------------------------------------- result and cleanup
write_result() {
  local result=pass failures_json='[]'
  [[ "${#FAILURES[@]}" -eq 0 ]] || { result=fail; failures_json="$(printf '%s\n' "${FAILURES[@]}" | jq -R . | jq -s -c .)"; }
  jq -n -S --argjson o "$OBS" --arg r "$result" --argjson f "$failures_json" \
    --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$CLUSTER_NAME" --arg ns "$NS" --arg a "${AUTH:-}" \
    '$o + {schema: "agentic-netops.g11/v1", gate_item: "G11", utc_time: $utc, cluster: $c, namespace: $ns,
           contract: "contracts/kuid-claim-profiles.md §6 (a)–(f)", result: $r, failures: $f}
        | .authority = ((.authority // {}) + {kind: (if $a == "" then null else $a end)})' >"$RESULT"
  evidence_run g11-result --attach g11-observations.json -- jq -e '.result == "pass"' "$RESULT" >/dev/null 2>&1 || true
  [[ "$result" == pass ]]
}

CREATED_INDICES=false
finish() {
  local rc=$?
  set +e
  trap - EXIT
  local obj name
  if [[ "$CREATED_INDICES" == true ]]; then
    # claims first (a first-party claim's release finalizer needs its pool), then the pools
    for obj in $(scratch_objects 2>/dev/null | grep -E '^(vlanclaim|genidclaim|identifierclaim)'); do
      name="${obj#*/}"
      evidence_run "g11-cleanup-${name}" -- k delete "${obj%%/*}" "$name" -n "$NS" --ignore-not-found >/dev/null 2>&1
    done
    evidence_run g11-cleanup-indices -- k delete -f "$INDICES" --ignore-not-found >/dev/null 2>&1
    if ! evidence_run g11-cleanup-readback -- check_no_scratch >/dev/null 2>&1; then
      fail "scratch objects remain after cleanup (see $EVIDENCE_DIR/g11-cleanup-readback.stdout)"
    else
      obs '.cleanup' '{"removed": true, "read_back": "no vt-scratch-g11 object remains"}'
    fi
  fi
  rm -rf "$ERRF" "$MAN"
  [[ "$rc" -eq 0 && "${#FAILURES[@]}" -gt 0 ]] && rc=1
  [[ "$rc" -ne 0 && "${#FAILURES[@]}" -eq 0 ]] && FAILURES+=("G11 stopped with exit ${rc} before completing (see the g11-*.json records)")
  if write_result && [[ "$rc" -eq 0 ]]; then
    log::info "G11 holds on ${AUTH}: API healthy, round trip and observations (a)–(f) recorded in ${RESULT}"
    exit 0
  fi
  log::error "G11 failed on ${AUTH:-an unknown authority}: ${#FAILURES[@]} item(s); see ${RESULT}"
  exit 1
}
trap finish EXIT

# ================================================================ run
case "$AUTH" in
  kuid)
    obs '.authority' "$(jq -n -c --arg img "$(yq -r '.compatibilitySet.allocationAuthorityRelease.kuidServer.pinned // ""' "$LOCK")" \
      '{kind: "kuid", image: $img}')" ;;
  first-party)
    obs '.authority' "$(jq -n -c \
      --arg img "srl-provider:$(yq -r '.images[]? | select(.name == "srl-provider") | .newTag' "$ROOT/deploy/allocation/kustomization.yaml" 2>/dev/null)" \
      --arg rec "$(yq -r '.allocationAuthority.decisionRecord // ""' "$LOCK")" \
      --arg ev "$(yq -r '.allocationAuthority.failedGateEvidence.path // ""' "$LOCK")" \
      --arg ns "$NS" \
      '{kind: "first-party", image: $img, role: "SRL_PROVIDER_ROLE=allocation-authority", namespace: $ns,
        decision_record: $rec, failed_gate_evidence: $ev}')" ;;
  *)
    fail "the lock file's allocationAuthority.kind is not admitted (kuid | first-party) — there is no third authority (data-model.md §23)"
    exit 1 ;;
esac

# 0. leftovers of an interrupted run refuse the start (FR-108)
if ! evidence_run g11-leftover-scan -- check_no_scratch >/dev/null 2>&1; then
  if grep -q 'could not be listed' "$EVIDENCE_DIR/g11-leftover-scan.stdout" 2>/dev/null; then
    fail "refusing to start: the ${WHAT_POOL}s and claims in ${NS} cannot be listed, so no leftover of an interrupted run can be ruled out (see $EVIDENCE_DIR/g11-leftover-scan.*)"
    exit 1
  fi
  fail "refusing to start: a leftover of an interrupted run is present in ${NS}: $(grep vt-scratch "$EVIDENCE_DIR/g11-leftover-scan.stdout" | paste -sd' ' -) — remove it explicitly (kubectl -n ${NS} delete <object>); nothing is removed implicitly"
  exit 1
fi

# 1. the authority's API healthy
if evidence_run g11-aggregated-api -- check_api_available >/dev/null 2>&1; then
  if [[ "$AUTH" == first-party ]]; then
    obs '.aggregated_api' "$(jq -n -c --arg d "$FP_DEPLOYMENT" '{healthy: true, served_by: "CustomResourceDefinitions (no aggregated API): identifierpools, identifierclaims Established; Deployment \($d) Available"}')"
  else
    obs '.aggregated_api' '{"healthy": true}'
  fi
else
  obs '.aggregated_api' '{"healthy": false}'
  if [[ "$AUTH" == first-party ]]; then
    fail "the first-party authority is not healthy: CRDs ${FP_CRDS[*]} Established and Deployment ${NS}/${FP_DEPLOYMENT} Available are required"
  else
    fail "the aggregated APIServices v1alpha1.vlan.be.kuid.dev / v1alpha1.genid.be.kuid.dev are not Available"
  fi
  exit 1
fi

CREATED_INDICES=true
write_pools_manifest >"$INDICES"
if ! evidence_run g11-index-create --attach "$INDICES_NAME" -- k apply --server-side --field-manager=agentic-netops-g11 -f "$INDICES" >/dev/null 2>&1; then
  fail "the scratch ${WHAT_POOL}s could not be created"; exit 1
fi
for pair in "$VLAN_IDX_RES:$IDX_VLAN" "$GENID_IDX_RES:$IDX_VNI" "$GENID_IDX_RES:$IDX_NARROW"; do
  if ! evidence_run "g11-index-ready-${pair#*:}" -- check_index_ready "${pair%%:*}" "${pair#*:}" >/dev/null 2>&1; then
    fail "scratch ${WHAT_POOL} ${pair#*:} never reported Ready"; exit 1
  fi
done

no_value_terminal() {  # no_value_terminal <what> <rc>
  fail "$1 reported no value in status.${VALUE_FIELD} (exit $2) — terminal (R-31): the platform never proceeds on an unknown identifier"
  obs '.round_trip.no_value_terminal' '"observed: a claim reported no value and was treated as terminal"'
  exit 1
}

# 2. the round trip and (c): three consecutive dynamic VLAN claims, one dynamic VNI claim
DYN_VALUES=()
DYN_NAMES=()
for n in 1 2 3; do
  name="vt-scratch-g11-vlan-dyn-${n}"
  rc=0; evidence_run "g11-dynamic-vlan-${n}" -- check_dynamic VLAN "$name" "$IDX_VLAN" >/dev/null 2>&1 || rc=$?
  v="$(last_json "g11-dynamic-vlan-${n}" | jq -r '.value // empty' 2>/dev/null || true)"
  [[ "$rc" -eq 0 && "$v" =~ ^[0-9]+$ ]] || no_value_terminal "dynamic VLAN claim ${name}" "$rc"
  DYN_VALUES+=("$v"); DYN_NAMES+=("$name")
done
obs '.round_trip.vlan' "$(jq -n -c --arg n "${DYN_NAMES[0]}" --argjson v "${DYN_VALUES[0]}" --arg f "$VALUE_FIELD" \
  '{claim: $n, ready: true} + {("status_" + $f): $v}')"

rc=0; evidence_run g11-dynamic-vni -- check_dynamic GENID vt-scratch-g11-vni-dyn "$IDX_VNI" >/dev/null 2>&1 || rc=$?
VNI_DYN="$(last_json g11-dynamic-vni | jq -r '.value // empty' 2>/dev/null || true)"
[[ "$rc" -eq 0 && "$VNI_DYN" =~ ^[0-9]+$ ]] || no_value_terminal "dynamic VNI claim vt-scratch-g11-vni-dyn" "$rc"
obs '.round_trip.vni' "$(jq -n -c --argjson v "$VNI_DYN" --arg f "$VALUE_FIELD" \
  '{claim: "vt-scratch-g11-vni-dyn", ready: true} + {("status_" + $f): $v}')"
obs '.round_trip.no_value_terminal' "$(jq -n -c --arg f "$VALUE_FIELD" '"enforced: every claim is read back until it reports status.\($f); one that does not stops G11"')"

values_json="$(printf '%s\n' "${DYN_VALUES[@]}" | jq -s -c 'map(tonumber)')"
if [[ "$values_json" == "[$VLAN_MIN,$((VLAN_MIN + 1)),$((VLAN_MIN + 2))]" ]]; then alloc="lowest-free"; else alloc="arbitrary"; fi
obs '.observations.c' "$(jq -n -c --argjson v "$values_json" --arg a "$alloc" --argjson min "$VLAN_MIN" \
  '{recorded: true, observed: "three consecutive dynamic claims on a fresh index", values: $v, index_min_id: $min, allocation: $a}')"

# (d) no dynamic value below minID — negative control first: a floor above every value seen
max_seen="$(jq -r 'max' <<<"$values_json")"
nc_rc=0; evidence_negative_control g11-min-id -- check_values_at_least "$((max_seen + 1))" "${DYN_VALUES[@]}" >/dev/null 2>&1 || nc_rc=$?
[[ "$nc_rc" -eq 0 ]] || fail "(d) negative control did not fail (exit ${nc_rc})"
d_held=true
evidence_run g11-min-id --readiness -- check_values_at_least "$VLAN_MIN" "${DYN_VALUES[@]}" >/dev/null 2>&1 || d_held=false
evidence_run g11-min-id-vni --check g11-min-id -- check_values_at_least "$VNI_MIN" "$VNI_DYN" >/dev/null 2>&1 || d_held=false
[[ "$d_held" == true ]] || fail "(d) a dynamic claim was handed a value below its ${WHAT_POOL}'s minimum: VLAN ${values_json} (min ${VLAN_MIN}), VNI ${VNI_DYN} (min ${VNI_MIN})"
obs '.observations.d' "$(jq -n -c --argjson h "$d_held" --argjson v "$values_json" --argjson vni "$VNI_DYN" \
  --argjson vmin "$VLAN_MIN" --argjson nmin "$VNI_MIN" \
  '{held: $h, vlan_values: $v, vlan_min_id: $vmin, vni_values: [$vni], vni_min_id: $nmin}')"

# (e) metadata.labels selectable — negative control first: the same label written somewhere
# other than metadata.labels (kuid: spec.labels; first-party: an annotation)
SPEC_TAG="speclabel-${RUN_TAG}"; SPEC_TAG="${SPEC_TAG:0:63}"; SPEC_TAG="${SPEC_TAG%-}"
if [[ "$AUTH" == first-party ]]; then E_MISPLACED="metadata.annotations"; else E_MISPLACED="spec.labels"; fi
evidence_run g11-speclabel-claim -- claim_create_readback VLAN vt-scratch-g11-vlan-speclabel "$IDX_VLAN" - "$SPEC_TAG" >/dev/null 2>&1 || true
nc_rc=0; evidence_negative_control g11-label-selector -- check_selected "$VLAN_RES" "${RUN_LABEL_KEY}=${SPEC_TAG}" vt-scratch-g11-vlan-speclabel >/dev/null 2>&1 || nc_rc=$?
[[ "$nc_rc" -eq 0 ]] || fail "(e) negative control did not fail: a label written into ${E_MISPLACED} was selectable (exit ${nc_rc})"
# every claim carrying the run label in metadata.labels: the three dynamic VLAN claims — and on
# first-party, where VLAN and VNI claims are one resource, the dynamic VNI claim too
E_WANT=("${DYN_NAMES[@]}"); [[ "$AUTH" == first-party ]] && E_WANT+=(vt-scratch-g11-vni-dyn)
e_held=true
evidence_run g11-label-selector --readiness -- check_selected "$VLAN_RES" "${RUN_LABEL_KEY}=${RUN_TAG}" "${E_WANT[@]}" >/dev/null 2>&1 || e_held=false
[[ "$e_held" == true ]] || fail "(e) metadata.labels are not selectable with -l ${RUN_LABEL_KEY}=${RUN_TAG}"
obs '.observations.e' "$(jq -n -c --argjson h "$e_held" --arg s "${RUN_LABEL_KEY}=${RUN_TAG}" \
  --arg out "$(head -n1 "$EVIDENCE_DIR/g11-label-selector.stdout" 2>/dev/null)" --arg m "$E_MISPLACED" \
  '{held: $h, selector: $s, result: $out, spec_labels_selectable: false, negative_control_label_in: $m}')"
delete_claim VLAN vt-scratch-g11-vlan-speclabel

# release the dynamic claims and read each removal back
for name in "${DYN_NAMES[@]}"; do delete_claim VLAN "$name"; done
delete_claim GENID vt-scratch-g11-vni-dyn
rel_ok=true
for name in "${DYN_NAMES[@]}"; do evidence_run "g11-released-${name}" -- check_absent "$VLAN_RES" "$name" >/dev/null 2>&1 || rel_ok=false; done
evidence_run g11-released-vt-scratch-g11-vni-dyn -- check_absent "$GENID_RES" vt-scratch-g11-vni-dyn >/dev/null 2>&1 || rel_ok=false
[[ "$rel_ok" == true ]] || fail "a released dynamic claim is still present after its delete"
obs '.round_trip.released' "$rel_ok"

# (a) a stated value binds exactly — negative control first: an index/pool not containing it
nc_rc=0; evidence_negative_control g11-stated-value -- check_stated_binds GENID vt-scratch-g11-stated-nc "$IDX_NARROW" "$STATED" >/dev/null 2>&1 || nc_rc=$?
[[ "$nc_rc" -eq 0 ]] || fail "(a) negative control did not fail: a claim for ${STATED} bound on ${IDX_NARROW} (${NARROW_MIN}–${NARROW_MAX})"
a_nc_reason="$(grep -h -o '"reason":"[A-Za-z]*"' "$EVIDENCE_DIR"/g11-stated-value.negative-control*.stderr 2>/dev/null | tail -n1 | cut -d'"' -f4 || true)"
delete_claim GENID vt-scratch-g11-stated-nc
a_held=true
evidence_run g11-stated-value --readiness -- check_stated_binds GENID vt-scratch-g11-stated-a "$IDX_VNI" "$STATED" >/dev/null 2>&1 || a_held=false
[[ "$a_held" == true ]] || fail "(a) a claim stating ${STATED} did not bind exactly ${STATED}: $(tail -n1 "$EVIDENCE_DIR/g11-stated-value.stderr" 2>/dev/null)"
obs '.observations.a' "$(jq -n -c --argjson h "$a_held" --argjson v "$STATED" \
  --arg got "$(tail -n1 "$EVIDENCE_DIR/g11-stated-value.stdout" 2>/dev/null)" --arg ncr "${a_nc_reason:-}" \
  --arg nci "${IDX_NARROW} ${NARROW_MIN}–${NARROW_MAX}" \
  '{held: $h, stated: $v, claim: "vt-scratch-g11-stated-a", result: $got,
    negative_control: {against: $nci, refused_reason: (if $ncr == "" then null else $ncr end)}}')"

# (b) a second claim for the value is refused naming the holder — negative control first:
# the same check for a value nobody holds (it binds, so "refused" must not hold)
nc_rc=0; evidence_negative_control g11-stated-conflict -- check_refused_naming_holder GENID vt-scratch-g11-stated-free "$IDX_VNI" "$FREE_STATED" vt-scratch-g11-stated-a >/dev/null 2>&1 || nc_rc=$?
[[ "$nc_rc" -eq 0 ]] || fail "(b) negative control did not fail: a claim for the free value ${FREE_STATED} was reported refused"
delete_claim GENID vt-scratch-g11-stated-free
b_held=true
evidence_run g11-stated-conflict --readiness -- check_refused_naming_holder GENID vt-scratch-g11-stated-b "$IDX_VNI" "$STATED" vt-scratch-g11-stated-a >/dev/null 2>&1 || b_held=false
b_last="$(sed -n '1p' "$EVIDENCE_DIR/g11-stated-conflict.stdout" 2>/dev/null || true)"
b_msg="$(jq -r '.message // ""' <<<"$b_last" 2>/dev/null || true)"
b_reason="$(jq -r '.reason // ""' <<<"$b_last" 2>/dev/null || true)"
[[ "$b_held" == true ]] || fail "(b) a second claim for ${STATED} was not refused naming the holder vt-scratch-g11-stated-a: $(tail -n1 "$EVIDENCE_DIR/g11-stated-conflict.stderr" 2>/dev/null)"
b_holder="vt-scratch-g11-stated-a"; [[ "$AUTH" == first-party ]] && b_holder="${NS}/vt-scratch-g11-stated-a"
obs '.observations.b' "$(jq -n -c --argjson h "$b_held" --argjson v "$STATED" --arg m "$b_msg" --arg r "$b_reason" --arg ho "$b_holder" \
  '{held: $h, value: $v, holder: $ho, refusal_message: $m, refusal_reason: (if $r == "" then null else $r end)}')"
# the refused claim goes BEFORE the holder is released: a refused first-party claim binds once
# the value is free, and (f) needs that value for its own second claim
delete_claim GENID vt-scratch-g11-stated-b

# (f) deleting a claim frees its value synchronously — negative control first: the same
# second claim while the first still exists
nc_rc=0; evidence_negative_control g11-release-synchronous -- check_stated_binds GENID vt-scratch-g11-stated-c "$IDX_VNI" "$STATED" >/dev/null 2>&1 || nc_rc=$?
[[ "$nc_rc" -eq 0 ]] || fail "(f) negative control did not fail: a second claim for ${STATED} bound while vt-scratch-g11-stated-a still held it"
delete_claim GENID vt-scratch-g11-stated-c
f_held=true
# kubectl delete waits (its default): it returns once the claim — and on first-party its release
# finalizer — is gone
evidence_run g11-release-stated-a -- k delete "$GENID_RES" vt-scratch-g11-stated-a -n "$NS" >/dev/null 2>&1 || f_held=false
# immediately: nothing waits or polls between the DELETE returning and the second create
evidence_run g11-release-synchronous --readiness -- check_stated_binds GENID vt-scratch-g11-stated-c "$IDX_VNI" "$STATED" >/dev/null 2>&1 || f_held=false
[[ "$f_held" == true ]] || fail "(f) deleting vt-scratch-g11-stated-a did not free ${STATED} synchronously: the immediate second claim did not bind"
obs '.observations.f' "$(jq -n -c --argjson h "$f_held" --argjson v "$STATED" \
  '{held: $h, value: $v, deleted: "vt-scratch-g11-stated-a", rebound_by: "vt-scratch-g11-stated-c", wait_between: "none"}')"
delete_claim GENID vt-scratch-g11-stated-c
evidence_run g11-released-vt-scratch-g11-stated-c -- check_absent "$GENID_RES" vt-scratch-g11-stated-c >/dev/null 2>&1 \
  || fail "released claim vt-scratch-g11-stated-c is still present"

exit 0
