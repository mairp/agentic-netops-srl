#!/usr/bin/env bash
# tests/gate/lib/gate.sh — shared plumbing of the capability gate items (T043, T045, T166).
#
# Every item script sources this file. It gives:
#   gate::id <stem>                  a fresh evidence id (<stem>, <stem>-2, …; evidence is never
#                                    overwritten)
#   gate::dev <id> <node> <rpc…>     one gnmic call, run-captured (evidence_run), operator creds
#                                    through the environment only
#   gate::run <id> [opts] -- <cmd…>  any other command, run-captured
#   gate::ready <id> <CHECK> <check-args…>   a READINESS check (tests/gate/lib/checks.sh): refused
#                                    by evidence_run unless <CHECK>'s failing negative control is
#                                    already recorded in this run (NFR-013, T045)
#   gate::record <id> <CHECK> <check-args…>  a check recorded without the readiness flag (the
#                                    absence / expected-failure halves whose control is the paired
#                                    presence check)
#   gate::negative <CHECK> <check-args…>     a negative control: the check against a stock node or
#                                    a service that does not exist — it MUST fail
#   gate::item_begin <G> <title> / gate::item_check <name> <rc> <summary> [<evidence-id>]
#   gate::item_observe <key> <json> / gate::item_end   → $EVIDENCE_DIR/gate/items/<G>.json
#   gate::observed <file> <json>     a tracked observation under tests/gate/observed/ (no timestamp,
#                                    no run id — sorted keys), copied into the evidence and hashed
#   gate::target_of <node>           "<namespace> <name>" of the node's SDC Target
#   gate::pre_absent <node> <path>   0 when the path is absent from running (evidence-captured)
#   gate::step <text>                a visible progress line
#
# Environment: EVIDENCE_DIR (set by run_gate.sh or on first use), CLUSTER_NAME, LAB_NAME,
# SRL_USER/SRL_PASS, GATE_OBSERVED_DIR (default tests/gate/observed), CHECK_WAIT_* windows.

[[ -n "${__AGENTIC_NETOPS_TESTS_GATE_SH:-}" ]] && return 0
__AGENTIC_NETOPS_TESTS_GATE_SH=1

GATE_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../lib/lab.sh
source "$GATE_REPO_ROOT/tests/lib/lab.sh"
# shellcheck source=../../../scripts/lib/log.sh
source "$GATE_REPO_ROOT/scripts/lib/log.sh"
# shellcheck source=../../../scripts/lib/evidence.sh
source "$GATE_REPO_ROOT/scripts/lib/evidence.sh"
# shellcheck source=scratch_fabric.sh
source "$GATE_REPO_ROOT/tests/gate/lib/scratch_fabric.sh"

GATE_CHECKS="$GATE_REPO_ROOT/tests/gate/lib/checks.sh"
: "${GATE_OBSERVED_DIR:=$GATE_REPO_ROOT/tests/gate/observed}"
: "${GATE_WAIT_BGP:=180}"      # sessions / EVPN oper-state
: "${GATE_WAIT_ROUTES:=120}"   # EVPN routes through the reflectors
: "${GATE_WAIT_NEG:=45}"       # the window a mid-item negative control is watched for
: "${GATE_WAIT_WITHDRAW:=90}"  # the bounded wait for EVPN routes to withdraw after G8's declared
                               # reflection-stopping change, before its negative control is run
: "${GATE_PINNED_VERSION:=25.7.1}"
export CHECK_INTERVAL="${CHECK_INTERVAL:-5}"

gate::init() {
  evidence::ensure_dir || return 3
  mkdir -p "$EVIDENCE_DIR/gate/items" "$EVIDENCE_DIR/gate/manifests" "$EVIDENCE_DIR/gate/observed"
  lab::export_creds || return 1
}

gate::step() { log::info "[${GATE_ITEM:-gate}] $*"; }

gate::id() {
  local stem="$1" id n=1
  id="$stem"
  while [[ -e "$EVIDENCE_DIR/$id.json" ]]; do n=$((n + 1)); id="${stem}-${n}"; done
  printf '%s' "$id"
}

gate::dev() {
  local id="$1" node="$2"; shift 2
  lab::gnmic_argv "$node" || return 1
  evidence_run "$(gate::id "$id")" -- "${LAB_ARGV[@]}" "$@"
}

gate::run() {
  local id="$1"; shift
  evidence_run "$(gate::id "$id")" "$@"
}

# gate::_check <mode> <id> <CHECK> <checks.sh args…>
gate::_check() {
  local mode="$1" id="$2" check="$3"; shift 3
  local eid rc=0
  eid="$(gate::id "$id")"
  case "$mode" in
    ready)  evidence_run "$eid" --check "$check" --readiness -- bash "$GATE_CHECKS" "$@" || rc=$? ;;
    record) evidence_run "$eid" --check "$check" -- bash "$GATE_CHECKS" "$@" || rc=$? ;;
  esac
  GATE_LAST_EVIDENCE="$eid"
  if [[ "$rc" -eq 3 ]]; then
    log::error "[${GATE_ITEM:-gate}] $check was REFUSED by the evidence layer (no failing negative control recorded, or the control passed): see $EVIDENCE_DIR"
  fi
  return "$rc"
}
gate::ready()  { local id="$1" c="$2"; shift 2; gate::_check ready "$id" "$c" "$@"; }
gate::record() { local id="$1" c="$2"; shift 2; gate::_check record "$id" "$c" "$@"; }

gate::negative() {
  local check="$1"; shift
  local rc=0
  evidence_negative_control "$check" -- bash "$GATE_CHECKS" "$@" || rc=$?
  case "$rc" in
    0) log::info "[negative-control] $check failed as it must on a system without what it checks" ;;
    4) log::error "[negative-control] $check PASSED on a system without what it checks — the check is defective; no pass of it will be admitted" ;;
    *) log::error "[negative-control] $check could not be recorded (rc=$rc)" ;;
  esac
  return "$rc"
}

# ---------------------------------------------------------------- the item record

gate::item_begin() {
  GATE_ITEM="$1"
  local f="$EVIDENCE_DIR/gate/items/$1.json"
  jq -n --arg i "$1" --arg t "$2" --arg u "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{item: $i, title: $t, status: "running", started_utc: $u, checks: [], observations: {}}' >"$f"
  log::info "=== ${1}: ${2}"
}

# gate::item_resume <G> — append to an item already begun (G4's config-only leaf is read during G8)
gate::item_resume() {
  GATE_ITEM="$1"
  [[ -f "$EVIDENCE_DIR/gate/items/$1.json" ]] || gate::item_begin "$1" "${2:-$1}"
}

# gate::item_check <name> <rc> <summary> [<evidence-id>]
# A check named "property:<p>" records a qualification PROPERTY (e.g. egress filtering): its result
# is published per property and refused by name when unqualified, but it is not an item failure.
gate::item_check() {
  local name="$1" rc="$2" summary="$3" eid="${4:-${GATE_LAST_EVIDENCE:-}}" f tmp st=pass
  [[ "$rc" -eq 0 ]] || st=fail
  f="$EVIDENCE_DIR/gate/items/${GATE_ITEM}.json"; tmp="$(mktemp)"
  jq --arg n "$name" --arg s "$st" --arg m "$summary" --arg e "$eid" --argjson rc "$rc" \
    '.checks += [{name: $n, status: $s, exit_status: $rc, summary: $m, evidence: (if $e == "" then null else ($e + ".json") end)}]' \
    "$f" >"$tmp" && mv "$tmp" "$f"
  if [[ "$st" == pass ]]; then log::info "[${GATE_ITEM}] PASS ${name} — ${summary}"
  else log::error "[${GATE_ITEM}] FAIL ${name} — ${summary}"; fi
  return 0
}

gate::item_observe() {
  local key="$1" json="$2" f tmp
  f="$EVIDENCE_DIR/gate/items/${GATE_ITEM}.json"; tmp="$(mktemp)"
  jq --arg k "$key" --argjson v "$json" '.observations[$k] = $v' "$f" >"$tmp" && mv "$tmp" "$f"
}

# gate::item_end — status fail if any check failed or none ran; prints and returns 0/1
gate::item_end() {
  local f tmp st
  f="$EVIDENCE_DIR/gate/items/${GATE_ITEM}.json"; tmp="$(mktemp)"
  jq --arg u "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '([.checks[] | select(.name | startswith("property:") | not)]) as $req
     | .status = (if ($req | length) == 0 then "fail" elif any($req[]; .status == "fail") then "fail" else "pass" end)
     | .finished_utc = $u
     | .failed_checks = [$req[] | select(.status == "fail") | .name]
     | .properties = ([.checks[] | select(.name | startswith("property:"))
                       | {key: (.name | ltrimstr("property:")), value: (.status == "pass")}] | from_entries)' "$f" >"$tmp" && mv "$tmp" "$f"
  st="$(jq -r .status "$f")"
  if [[ "$st" == pass ]]; then log::info "=== ${GATE_ITEM}: PASS"; return 0; fi
  log::error "=== ${GATE_ITEM}: FAIL ($(jq -r '.failed_checks | join(", ")' "$f"))"
  return 1
}

# gate::observed <file> <json> — the tracked observation file (committed after the gate run that
# wrote it, AD-64). Refuses a run-specific field.
gate::observed() {
  local file="$1" json="$2" dst ev
  if jq -e '[paths(type == "string") as $p | getpath($p)] | any(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+"))
            or ([paths | .[] | strings] | any(test("(^|_)(utc|timestamp|time|run_?id)$")))' <<<"$json" >/dev/null 2>&1; then
    log::error "observed file $file would carry a run-specific field (timestamp / run id): refused"
    return 1
  fi
  mkdir -p "$GATE_OBSERVED_DIR"
  dst="$GATE_OBSERVED_DIR/$file"
  jq -S . <<<"$json" >"$dst"
  ev="$EVIDENCE_DIR/gate/observed/$file"
  cp "$dst" "$ev"
  log::info "[${GATE_ITEM:-gate}] observation written: ${dst#"$GATE_REPO_ROOT"/} (sha256 $(sha256sum "$dst" | cut -c1-12)…)"
}

# ---------------------------------------------------------------- cluster helpers

# gate::target_of <node> — "<namespace> <name>" of the SDC Target whose name is the node or whose
# address is the node's management address, looked up in LAB_TARGET_NS (tests/lib/lab.sh) — the
# namespace a gate-owned Config must then be created in, since config-server v0.0.58 lists a
# Target's Configs in the Target's own namespace (AD-82 decision 2026-09-21-target-namespace)
gate::target_of() {
  local node="$1" addr out
  addr="$(lab::addr "$node")"
  out="$(lab::kubectl get targets.config.sdcio.dev -n "$LAB_TARGET_NS" -o json 2>/dev/null)" || return 1
  jq -r --arg n "$node" --arg a "$addr" '
    [.items[] | select(.metadata.name == $n or (.metadata.name | endswith("-" + $n))
                       or ((.spec.address // "") | split(":")[0]) == $a)]
    | first | if . == null then empty else "\(.metadata.namespace) \(.metadata.name)" end' <<<"$out"
}

# gate::pre_absent <node> <path> — read running; 0 when nothing is configured at the path
gate::pre_absent() {
  local node="$1" path="$2" out
  out="$(gate::dev "${GATE_ITEM:-gate}.pre.${node}" "$node" get --type config --path "$path" 2>/dev/null)" || return 0
  jq -e "$(lab::jq_lib)"' gvalues | (length == 0) or (.[0] == null) or (.[0] == {})' <<<"$out" >/dev/null
}

# gate::cleanup_path <node> <iface> — what removes a scratch description written on <iface>: the
# whole interface entry when the gate created it, otherwise just the description leaf
gate::cleanup_path() {
  local node="$1" ifc="$2"
  if gate::pre_absent "$node" "/interface[name=${ifc}]"; then
    printf '/interface[name=%s]' "$ifc"
  else
    printf '/interface[name=%s]/description' "$ifc"
  fi
}

# gate::wait_ns_gone <namespace> <seconds> — the namespace is NotFound (removal read back)
gate::wait_ns_gone() {
  local ns="$1" secs="${2:-180}" deadline
  deadline=$((SECONDS + secs))
  while lab::kubectl get namespace "$ns" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || return 1
    sleep 3
  done
  gate::run "${GATE_ITEM:-gate}.ns-gone.${ns}" -- sh -c "! ${KUBECTL:-kubectl} --context ${KUBE_CONTEXT:-kind-${CLUSTER_NAME}} get namespace ${ns}"
}

# gate::lock_image <yq-like path> — a pinned image reference from versions.lock.yaml
gate::lock_image() {
  python3 - "$GATE_REPO_ROOT/versions.lock.yaml" "$1" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
cur = doc
for k in sys.argv[2].split("."):
    cur = cur[k]
print(cur)
PY
}

# gate::manifest <name> — a path under the run's evidence for a non-secret manifest
gate::manifest() { printf '%s/gate/manifests/%s' "$EVIDENCE_DIR" "$1"; }
