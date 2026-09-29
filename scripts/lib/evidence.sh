#!/usr/bin/env bash
# evidence.sh — run-captured evidence (T011, NFR-013, SC-040).
#
# NFR-013: every gate and acceptance result is evidence captured by the run
# that claims it — the command, its UTC time, its exit status, the device image
# digest and the cluster and lab identity, recorded together with the raw
# output. A hand-authored or post-edited proof is non-conforming, and a
# readiness check counts only after it has been shown to FAIL on a stock fabric.
#
#   evidence_run <id> [options] -- <cmd…>
#       Runs <cmd>, captures its stdout and stderr, and writes
#         <EVIDENCE_DIR>/<id>.json    the record (schema below)
#         <EVIDENCE_DIR>/<id>.stdout  raw stdout      <id>.stderr  raw stderr
#       then replays stdout/stderr to the caller and returns <cmd>'s exit status.
#       Options:
#         --check <check-id>   the check this run is a result of (default: <id>)
#         --readiness          this run is a readiness/acceptance check: it is
#                              REFUSED (exit 3, command not run) unless a
#                              failing negative control for <check-id> is
#                              already recorded in EVIDENCE_DIR
#         --records <SC>[:<part>]  the criterion this run records, e.g.
#                              SC-004:session or SC-004:route (repeatable).
#                              SC-004:route implies --readiness (SC-004, AD-31)
#         --attach <file>      an artefact the command wrote inside EVIDENCE_DIR,
#                              hashed into the record after the run (repeatable)
#
#   evidence_negative_control <check-id> [--attach <file>] -- <cmd…>
#       Runs <cmd> against a system that does NOT carry what <check-id> checks
#       for. It MUST fail. Written as <check-id>.negative-control[-N].json. A
#       control that passes is recorded (negative_control_failed=false), the
#       check is reported as defective, and the call returns 4 — and every
#       later `evidence_run` of <check-id> (readiness-flagged or not) is refused
#       (exit 3, command not run) until a failing control is recorded.
#
# EVIDENCE_DIR defaults to .evidence/<cluster>_<lab>/<UTC run id>/ under the
# repository root (EVIDENCE_ROOT overrides .evidence). It is chosen once per
# process and exported, so every call of one run — and its children — writes
# the same directory. .evidence/ is git-ignored; nothing in it is ever edited
# by hand, and scripts/lib/verify_evidence.sh (make verify-evidence) proves it.
#
# Identity (all recorded; a missing one refuses the run, exit 3):
#   device image digest  EVIDENCE_DEVICE_IMAGE_DIGEST, else the SR Linux image
#                        digest versions.lock.yaml pins
#   cluster              EVIDENCE_CLUSTER, else CLUSTER_NAME, else agentic-netops;
#                        its uid is kube-system's namespace UID read through
#                        kubectl --context kind-<cluster>, or the literal
#                        "unavailable" when no such cluster answers (recorded,
#                        never omitted — e.g. a teardown from the Absent state)
#   lab                  EVIDENCE_LAB, else LAB_NAME, else the `name:` of
#                        lab/topology.clab.yml; plus that file's sha256
#
# Record schema (agentic-netops.evidence/v1) — the NFR-013 fields are the ones
# verify_evidence.sh requires (see its NFR013_FIELDS):
#   id, kind (run|negative_control), check_id, readiness, records[],
#   command[] + command_line, cwd, utc_time, utc_finished, exit_status,
#   device_image_digest, cluster{name,uid}, lab{name,topology_sha256},
#   raw_output{stdout{file,sha256},stderr{file,sha256}}, attachments[{file,sha256}],
#   negative_control_failed (negative controls only),
#   record_sha256 — sha256 of the canonical (jq -S -c) record without this field,
#   so an edit to the JSON itself is detected as surely as an edit to the output.

[[ -n "${__AGENTIC_NETOPS_EVIDENCE_SH:-}" ]] && return 0
__AGENTIC_NETOPS_EVIDENCE_SH=1

EVIDENCE_SCHEMA="agentic-netops.evidence/v1"
EVIDENCE_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

evidence::_err() { printf 'evidence: %s\n' "$*" >&2; }

evidence::_sha256() { sha256sum "$1" | awk '{print $1}'; }

evidence::cluster_name() { printf '%s' "${EVIDENCE_CLUSTER:-${CLUSTER_NAME:-agentic-netops}}"; }

evidence::cluster_uid() {
  if [[ -n "${EVIDENCE_CLUSTER_UID:-}" ]]; then printf '%s' "$EVIDENCE_CLUSTER_UID"; return 0; fi
  local uid=""
  if command -v "${KUBECTL:-kubectl}" >/dev/null 2>&1; then
    uid="$("${KUBECTL:-kubectl}" --context "kind-$(evidence::cluster_name)" --request-timeout=5s \
      get namespace kube-system -o 'jsonpath={.metadata.uid}' 2>/dev/null)" || uid=""
  fi
  printf '%s' "${uid:-unavailable}"
}

evidence::_topology() { printf '%s' "${EVIDENCE_TOPOLOGY:-$EVIDENCE_REPO_ROOT/lab/topology.clab.yml}"; }

evidence::lab_name() {
  if [[ -n "${EVIDENCE_LAB:-${LAB_NAME:-}}" ]]; then printf '%s' "${EVIDENCE_LAB:-$LAB_NAME}"; return 0; fi
  local topo; topo="$(evidence::_topology)"
  [[ -f "$topo" ]] || return 1
  awk -F: '/^name:/ {gsub(/[[:space:]"'\'']/, "", $2); print $2; exit}' "$topo"
}

evidence::device_image_digest() {
  if [[ -n "${EVIDENCE_DEVICE_IMAGE_DIGEST:-}" ]]; then printf '%s' "$EVIDENCE_DEVICE_IMAGE_DIGEST"; return 0; fi
  local lock="${EVIDENCE_LOCK_FILE:-$EVIDENCE_REPO_ROOT/versions.lock.yaml}"
  [[ -f "$lock" ]] || return 1
  # The digest on the srlinux image line, or the first digest within the few
  # lines after a line naming srlinux (the lock's entry shape is T010's).
  awk '
    /srlinux/ { window = 8 }
    window > 0 {
      if (match($0, /sha256:[0-9a-f]{64}/)) { print substr($0, RSTART, RLENGTH); exit }
      window--
    }' "$lock"
}

# evidence::ensure_dir — resolve (and create, once per process) the run's
# directory into EVIDENCE_DIR. Call it in the current shell, not in $(…), so the
# choice persists for the rest of the run.
evidence::ensure_dir() {
  if [[ -z "${EVIDENCE_DIR:-}" ]]; then
    local cluster lab root run base n=1
    cluster="$(evidence::cluster_name)"
    lab="$(evidence::lab_name)" || lab=""
    if [[ -z "$lab" ]]; then
      evidence::_err "lab identity unknown: set EVIDENCE_LAB (or LAB_NAME), or provide lab/topology.clab.yml with a name:"
      return 3
    fi
    root="${EVIDENCE_ROOT:-$EVIDENCE_REPO_ROOT/.evidence}"
    run="$(date -u +%Y%m%dT%H%M%SZ)"
    base="$root/${cluster}_${lab}/$run"
    EVIDENCE_DIR="$base"
    mkdir -p "$(dirname "$base")"
    until mkdir "$EVIDENCE_DIR" 2>/dev/null; do     # atomic: two runs never share a directory
      n=$((n + 1)); EVIDENCE_DIR="${base}-${n}"
    done
    export EVIDENCE_DIR
  else
    mkdir -p "$EVIDENCE_DIR"
  fi
}

# evidence::dir — ensure_dir, then print the path.
evidence::dir() { evidence::ensure_dir || return 3; printf '%s' "$EVIDENCE_DIR"; }

# evidence::_candidates <dir> <check-id> — the record files that can carry <check-id>: every *.json
# in <dir> that contains the quoted id as a string at all. A strict superset of the records whose
# check_id is <check-id> (jq still decides each one), found by ONE grep instead of one jq per
# record — the per-record scan made every evidence_run cost O(records in the run), which put
# minutes on a 1000-record tier phase (T153/SC-032).
evidence::_candidates() {
  [[ -d "$1" ]] || return 0
  find "$1" -maxdepth 1 -type f -name '*.json' -exec grep -lF -e "\"$2\"" {} + 2>/dev/null
  return 0
}

# evidence::has_failing_negative_control <dir> <check-id>
evidence::has_failing_negative_control() {
  local dir="$1" check="$2" f
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    jq -e --arg c "$check" \
      '.kind == "negative_control" and .check_id == $c and (.exit_status | type == "number") and .exit_status != 0' \
      "$f" >/dev/null 2>&1 && return 0
  done < <(evidence::_candidates "$dir" "$check")
  return 1
}

# evidence::has_passing_negative_control <dir> <check-id>
evidence::has_passing_negative_control() {
  local dir="$1" check="$2" f
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    jq -e --arg c "$check" '.kind == "negative_control" and .check_id == $c and .exit_status == 0' \
      "$f" >/dev/null 2>&1 && return 0
  done < <(evidence::_candidates "$dir" "$check")
  return 1
}

# evidence::_capture <kind> <id> <file-stem> <check> <readiness> <records-json> <attach-json> -- <cmd…>
evidence::_capture() {
  local kind="$1" id="$2" stem="$3" check="$4" readiness="$5" records="$6"; shift 6
  local -a attach=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do attach+=("$1"); shift; done
  shift  # --
  EVIDENCE_LAST_RECORD=""
  local dir digest cluster uid lab topo topo_sha=""
  evidence::ensure_dir || return 3
  dir="$EVIDENCE_DIR"
  digest="$(evidence::device_image_digest)" || digest=""
  if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    evidence::_err "device image digest unavailable (no SR Linux digest in versions.lock.yaml; set EVIDENCE_DEVICE_IMAGE_DIGEST): refusing to capture '${id}'"
    return 3
  fi
  cluster="$(evidence::cluster_name)"
  uid="$(evidence::cluster_uid)"
  lab="$(evidence::lab_name)" || lab=""
  [[ -n "$lab" ]] || { evidence::_err "lab identity unknown: refusing to capture '${id}'"; return 3; }
  topo="$(evidence::_topology)"
  [[ -f "$topo" ]] && topo_sha="$(evidence::_sha256 "$topo")"

  local json="$dir/$stem.json" out="$dir/$stem.stdout" err="$dir/$stem.stderr"
  if [[ -e "$json" ]]; then
    evidence::_err "$json already exists: evidence is never overwritten; use a new id"
    return 3
  fi
  local started finished rc
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  "$@" >"$out" 2>"$err" </dev/null && rc=0 || rc=$?
  finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local att_json="[]" a rel
  for a in "${attach[@]}"; do
    [[ "$a" == /* ]] || a="$dir/$a"
    rel="${a#"$dir"/}"
    if [[ "$rel" == "$a" || ! -f "$a" ]]; then
      evidence::_err "attachment '$a' is not a file inside $dir: not recorded"
      continue
    fi
    att_json="$(jq -c --arg f "$rel" --arg s "$(evidence::_sha256 "$a")" '. + [{file: $f, sha256: $s}]' <<<"$att_json")"
  done

  local cmdline
  cmdline="$(printf '%q ' "$@")"; cmdline="${cmdline% }"
  local body argv
  argv="$(printf '%s\0' "$@" | jq -R -s -c 'split("\u0000") | .[:-1]')"
  body="$(jq -n -S -c --argjson argv "$argv" \
    --arg schema "$EVIDENCE_SCHEMA" --arg id "$id" --arg kind "$kind" --arg check "$check" \
    --argjson readiness "$readiness" --argjson records "$records" \
    --arg cmdline "$cmdline" --arg cwd "$PWD" \
    --arg started "$started" --arg finished "$finished" --argjson rc "$rc" \
    --arg digest "$digest" --arg cluster "$cluster" --arg uid "$uid" \
    --arg lab "$lab" --arg topo_sha "$topo_sha" \
    --arg out "$(basename "$out")" --arg out_sha "$(evidence::_sha256 "$out")" \
    --arg err "$(basename "$err")" --arg err_sha "$(evidence::_sha256 "$err")" \
    --argjson attachments "$att_json" \
    '{schema: $schema, id: $id, kind: $kind, check_id: $check, readiness: $readiness,
      records: $records, command: $argv, command_line: $cmdline, cwd: $cwd,
      utc_time: $started, utc_finished: $finished, exit_status: $rc,
      device_image_digest: $digest,
      cluster: {name: $cluster, uid: $uid},
      lab: {name: $lab, topology_sha256: $topo_sha},
      raw_output: {stdout: {file: $out, sha256: $out_sha}, stderr: {file: $err, sha256: $err_sha}},
      attachments: $attachments}
     + (if $kind == "negative_control" then {negative_control_failed: ($rc != 0)} else {} end)')"
  local rsha
  rsha="$(printf '%s' "$body" | sha256sum | awk '{print $1}')"
  jq -S --arg r "$rsha" '. + {record_sha256: $r}' <<<"$body" >"$json"
  EVIDENCE_LAST_RECORD="$json"

  cat "$out"
  cat "$err" >&2
  return "$rc"
}

evidence::_valid_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

evidence_run() {
  local id="${1:-}"
  if [[ -z "$id" ]] || ! evidence::_valid_id "$id"; then
    evidence::_err "usage: evidence_run <id> [--check <id>] [--readiness] [--records SC-NNN[:part]] [--attach f] -- <cmd…>"
    return 2
  fi
  shift
  local check="$id" readiness=false records="[]"
  local -a attach=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    case "$1" in
      --check) check="${2:?--check needs a value}"; shift 2 ;;
      --readiness) readiness=true; shift ;;
      --records)
        [[ "${2:-}" =~ ^SC-[0-9]{3}(:[a-z0-9-]+)?$ ]] || { evidence::_err "--records takes SC-NNN[:part], got '${2:-}'"; return 2; }
        records="$(jq -c --arg r "$2" '. + [$r]' <<<"$records")"
        [[ "$2" == "SC-004:route" ]] && readiness=true
        shift 2 ;;
      --attach) attach+=("${2:?--attach needs a file}"); shift 2 ;;
      *) evidence::_err "evidence_run: unknown option '$1'"; return 2 ;;
    esac
  done
  if [[ "${1:-}" != "--" || $# -lt 2 ]]; then
    evidence::_err "evidence_run: missing '-- <cmd…>'"
    return 2
  fi
  evidence::_valid_id "$check" || { evidence::_err "invalid check id '$check'"; return 2; }
  evidence::ensure_dir || return 3
  # A check whose negative control PASSED is defective: no later run of it is
  # admitted as a result, readiness-flagged or not (NFR-013).
  if evidence::has_passing_negative_control "$EVIDENCE_DIR" "$check" \
    && ! evidence::has_failing_negative_control "$EVIDENCE_DIR" "$check"; then
    evidence::_err "refusing '${id}': check '${check}' is defective — its negative control passed on a system without what it checks (NFR-013)"
    return 3
  fi
  if [[ "$readiness" == true ]]; then
    local dir="$EVIDENCE_DIR"
    if ! evidence::has_failing_negative_control "$dir" "$check"; then
      evidence::_err "refusing '${id}': readiness check '${check}' has no recorded failing negative control in ${dir}" \
        "(NFR-013: run evidence_negative_control ${check} -- <cmd> against a fabric without it first)"
      return 3
    fi
  fi
  evidence::_capture run "$id" "$id" "$check" "$readiness" "$records" "${attach[@]}" "$@"
}

evidence_negative_control() {
  local check="${1:-}"
  if [[ -z "$check" ]] || ! evidence::_valid_id "$check"; then
    evidence::_err "usage: evidence_negative_control <check-id> [--attach f] -- <cmd…>"
    return 2
  fi
  shift
  local -a attach=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    case "$1" in
      --attach) attach+=("${2:?--attach needs a file}"); shift 2 ;;
      *) evidence::_err "evidence_negative_control: unknown option '$1'"; return 2 ;;
    esac
  done
  if [[ "${1:-}" != "--" || $# -lt 2 ]]; then
    evidence::_err "evidence_negative_control: missing '-- <cmd…>'"
    return 2
  fi
  local dir stem n=1
  evidence::ensure_dir || return 3
  dir="$EVIDENCE_DIR"
  stem="${check}.negative-control"
  while [[ -e "$dir/$stem.json" ]]; do n=$((n + 1)); stem="${check}.negative-control-${n}"; done
  local rc=0
  evidence::_capture negative_control "$stem" "$stem" "$check" false "[]" "${attach[@]}" "$@" || rc=$?
  [[ -n "$EVIDENCE_LAST_RECORD" ]] || return 3       # refused before running: nothing recorded
  if [[ "$rc" -eq 0 ]]; then
    evidence::_err "negative control for '${check}' PASSED on a system without what it checks: the check is defective, no pass of it will be admitted (NFR-013)"
    return 4
  fi
  return 0
}

# evidence_seal <id> — one run-captured record attaching (hashing) every file in EVIDENCE_DIR that
# no record references yet: what a command run under evidence_run wrote on its own (a suite's
# measurements, its scratch manifests) and did not name with --attach. make verify-evidence admits
# nothing unreferenced (NFR-013); called right after the command that wrote them, so the hash is
# the file as that command left it. Skipped: the live declared-faults ledger (admitted through its
# snapshots) and raw outputs whose record does not exist yet (an evidence_run still in flight).
# Writes nothing when nothing is unreferenced. (T151 r9: 22+ suite files refused per cycle.)
evidence_seal() {
  local id="${1:?usage: evidence_seal <id>}" f
  evidence::ensure_dir || return 3
  local -a att=() abs=()
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    att+=(--attach "$f"); abs+=("$EVIDENCE_DIR/$f")
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
    if not (isinstance(r, dict) and r.get("schema") == "agentic-netops.evidence/v1"):
        continue
    rdir = os.path.dirname(f)
    ref.add(f)
    for k in ("stdout", "stderr"):
        v = (r.get("raw_output") or {}).get(k) or {}
        if v.get("file"):
            ref.add(os.path.normpath(os.path.join(rdir, v["file"])))
    for a in r.get("attachments") or []:
        if isinstance(a, dict) and a.get("file"):
            ref.add(os.path.normpath(os.path.join(rdir, a["file"])))
for f in sorted(files - ref):
    if os.path.basename(f) == "declared-faults.json":
        continue
    stem, ext = os.path.splitext(f)
    if ext in (".stdout", ".stderr") and not os.path.exists(os.path.join(d, stem + ".json")):
        continue
    print(f)
PY
)
  [[ ${#abs[@]} -gt 0 ]] || return 0
  evidence_run "$id" "${att[@]}" -- sha256sum -- "${abs[@]}" >/dev/null
}
