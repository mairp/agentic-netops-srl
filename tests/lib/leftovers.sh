#!/usr/bin/env bash
# tests/lib/leftovers.sh — the leftover convention and the scan every FR-108 tool starts with
# (T043 i–iv; FR-108, SC-049, AD-49, AD-64).
#
# A verification tool can die between writing and removing. So everything it leaves behind must
# be FINDABLE by a later run, and every gate / acceptance run refuses to start while any of it is
# present — naming the node and the leftover, never cleaning up silently, never assuming the tool
# that wrote it survived.
#
#   (i)   Every named device object written as scratch configuration carries the reserved prefix
#         vt-scratch- (LAB_SCRATCH_PREFIX). An unnamed scratch object (a subinterface, an interface
#         setting) carries it in its description. No platform render ever emits the prefix —
#         tests/unit/gate/golden_scratch_prefix_test.sh asserts it over every golden under
#         tests/golden/.
#   (ii)  The gate-owned scratch Config and every scratch namespace a gate item starts carry the
#         label agentic-netops.io/gate-owned=true (LAB_GATE_SELECTOR).
#   (iii) leftovers::declare_fault writes a declared injected fault to
#         <EVIDENCE_DIR>/declared-faults.json BEFORE the fault is made: the node, what is changed
#         and the probe that finds it still in place.
#   (iv)  leftovers::scan reads every device's running datastore for a vt-scratch- object (and
#         every client container for a vt-scratch- link), the cluster for a gate-labelled Config,
#         a gate-labelled namespace and — where the first-party allocation authority's CRDs exist
#         (FR-104, T181) — a vt-scratch- or gate-labelled IdentifierPool / IdentifierClaim in
#         agentic-netops-allocation (G11's scratch pools and claims), and runs the probe of every
#         fault class on every node:
#           mgmt-detached     the node's container is not on the management network
#                             (docker network inspect <MGMT_NETWORK>)
#           link-impairment   a netem/tbf qdisc on one of the node's links (tc qdisc, read from
#                             the host inside the container's network namespace)
#           device-leaf       a device-side administrative state still holding the value a
#                             declared fault set (the declared fault's own probe; every
#                             declared-faults.json of this cluster/lab's evidence root is read)
#         and returns non-zero naming each leftover. It fails closed: a datastore it cannot read
#         is reported as unscannable, which also refuses the start.
#   leftovers::remove — the separate, explicit, evidence-captured clean-up an operator runs. Never
#         called implicitly by any tool.
#
# Output: one line per finding on stdout —  LEFTOVER <kind> <where> <detail>  — and a summary on
# stderr. Device, cluster and docker reads go through evidence_run when scripts/lib/evidence.sh is
# loaded (it is, in every caller), so the scan itself is run-captured evidence.
#
# Usage:
#   source tests/lib/leftovers.sh
#   leftovers::scan            || exit 1     # refuse the start
#   leftovers::declare_fault <id> <node> <change> <probe-json> [<revert-json>]
#   leftovers::remove [--snapshots <gate-scratch-dir>]

[[ -n "${__AGENTIC_NETOPS_LEFTOVERS_SH:-}" ]] && return 0
__AGENTIC_NETOPS_LEFTOVERS_SH=1

LEFTOVERS_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lab.sh
source "$LEFTOVERS_REPO_ROOT/tests/lib/lab.sh"
if ! declare -F evidence_run >/dev/null; then
  # shellcheck source=../../scripts/lib/evidence.sh
  source "$LEFTOVERS_REPO_ROOT/scripts/lib/evidence.sh"
fi

leftovers::prefix()   { printf '%s' "$LAB_SCRATCH_PREFIX"; }
leftovers::selector() { printf '%s' "$LAB_GATE_SELECTOR"; }

# leftovers::_run <id-stem> -- <cmd…> — run-captured when evidence is available.
LEFTOVERS_SCAN_ID=""
leftovers::_run() {
  local stem="$1"; shift; [[ "$1" == "--" ]] && shift
  if declare -F evidence_run >/dev/null && [[ "${LEFTOVERS_NO_EVIDENCE:-0}" != 1 ]]; then
    evidence_run "${LEFTOVERS_SCAN_ID}.${stem}" -- "$@"
  else
    "$@"
  fi
}

leftovers::_new_scan_id() {
  LEFTOVERS_SCAN_ID="leftover-scan-$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}"
}

# ---------------------------------------------------------------- (iii) declared faults

# leftovers::declare_fault <id> <node> <change> <probe-json> [<revert-json>]
#   probe-json is one of
#     {"kind":"mgmt-detached","container":"clab-…-leaf01","network":"agentic-netops-mgmt"}
#     {"kind":"link-impairment","container":"clab-…-leaf01","interface":"e1-49"}
#     {"kind":"device-leaf","node":"leaf01","path":"/interface[name=ethernet-1/49]/admin-state",
#      "faulted_value":"disable"}
#   revert-json (optional) is what leftovers::remove does to undo it, e.g.
#     {"kind":"docker-network-connect","ip":"172.25.25.21"} | {"kind":"tc-qdisc-del"} |
#     {"kind":"device-leaf-set","value":"enable"}
# Written BEFORE the fault is made; the caller makes the fault only if this returns 0.
leftovers::declare_fault() {
  local id="${1:?id}" node="${2:?node}" change="${3:?change}" probe="${4:?probe-json}" revert="${5:-null}"
  evidence::ensure_dir || return 3
  jq -e 'type == "object" and (.kind | IN("mgmt-detached","link-impairment","device-leaf"))' \
    <<<"$probe" >/dev/null || { echo "leftovers: probe must be a JSON object of a known kind: $probe" >&2; return 2; }
  local f="$EVIDENCE_DIR/declared-faults.json" tmp
  [[ -f "$f" ]] || jq -n '{schema: "agentic-netops.declared-faults/v1", faults: []}' >"$f"
  tmp="$(mktemp)"
  jq --arg id "$id" --arg node "$node" --arg change "$change" --argjson probe "$probe" \
     --argjson revert "$revert" --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --arg by "${0##*/}" \
     '.faults += [{id: $id, node: $node, change: $change, probe: $probe, revert: $revert,
                   declared_utc: $utc, declared_by: $by}]' "$f" >"$tmp" && mv "$tmp" "$f"
}

# leftovers::_declared_faults — every declared fault of this cluster/lab, as JSON lines
leftovers::_declared_faults() {
  local root base f
  root="${EVIDENCE_ROOT:-$LEFTOVERS_REPO_ROOT/.evidence}"
  base="$root/${CLUSTER_NAME}_${LAB_NAME}"
  {
    [[ -n "${EVIDENCE_DIR:-}" && -f "$EVIDENCE_DIR/declared-faults.json" ]] && echo "$EVIDENCE_DIR/declared-faults.json"
    [[ -d "$base" ]] && find "$base" -mindepth 2 -maxdepth 2 -name declared-faults.json 2>/dev/null
  } | sort -u | while read -r f; do
    jq -c --arg f "$f" '.faults[]? + {file: $f}' "$f" 2>/dev/null
  done
}

# ---------------------------------------------------------------- probes

# leftovers::_scratch_paths — read a gnmic get response on stdin; print "<json-path>\t<value>" of
# every string value (or object key value) carrying the prefix.
leftovers::_scratch_paths() {
  jq -r --arg p "$LAB_SCRATCH_PREFIX" "$(lab::jq_lib)"'
    [ .[]? | .updates[]? | .values | to_entries[] | .value ] as $vals
    | $vals[] | paths(type == "string" and startswith($p)) as $q
    | [$q, getpath($q)] | "\(.[0] | map(tostring) | join("/"))\t\(.[1])"' 2>/dev/null
}

# leftovers::_probe_mgmt — prints "<container>" for every lab container missing from MGMT_NETWORK
leftovers::_probe_mgmt() {
  local out node c
  if ! out="$(leftovers::_run "mgmt-network" -- lab::docker network inspect "$MGMT_NETWORK")"; then
    echo "LEFTOVER mgmt-detached network:$MGMT_NETWORK cannot inspect the management network (every node detached?)"
    return 1
  fi
  local members
  members="$(jq -r '.[0].Containers // {} | to_entries[] | .value.Name' <<<"$out" 2>/dev/null)"
  local rc=0
  for node in $(lab::all_nodes); do
    c="$(lab::container "$node")"
    if ! grep -qxF "$c" <<<"$members"; then
      echo "LEFTOVER mgmt-detached $node container $c is not attached to $MGMT_NETWORK"
      rc=1
    fi
  done
  return "$rc"
}

# leftovers::_probe_netem <node> — a netem/tbf qdisc on any link of the node's container
leftovers::_probe_netem() {
  local node="$1" c pid out
  c="$(lab::container "$node")"
  pid="$(lab::docker inspect -f '{{.State.Pid}}' "$c" 2>/dev/null)" || pid=""
  if [[ -z "$pid" || "$pid" == 0 ]]; then
    echo "LEFTOVER unscannable $node container $c is not running: link impairment cannot be probed"
    return 1
  fi
  out="$(leftovers::_run "tc.${node}" -- "${NSENTER:-nsenter}" -t "$pid" -n "${TC:-tc}" qdisc show)" || {
    echo "LEFTOVER unscannable $node tc qdisc could not be read in $c's network namespace"
    return 1
  }
  local line rc=0
  while read -r line; do
    [[ "$line" =~ (netem|tbf) ]] || continue
    echo "LEFTOVER link-impairment $node ${line}"
    rc=1
  done <<<"$out"
  return "$rc"
}

# leftovers::_probe_declared <fault-json> [<seq>] — 0 when the fault is no longer in place. <seq>
# keeps the evidence id unique: two runs under the evidence root may declare the same fault id,
# and one scan probes every run's declaration (evidence is never overwritten).
leftovers::_probe_declared() {
  local f="$1" kind node id stem
  kind="$(jq -r '.probe.kind' <<<"$f")"; node="$(jq -r '.node' <<<"$f")"; id="$(jq -r '.id' <<<"$f")"
  stem="declared.${2:+$2.}${id}"
  case "$kind" in
    mgmt-detached)
      local c net out
      c="$(jq -r '.probe.container' <<<"$f")"; net="$(jq -r '.probe.network // empty' <<<"$f")"
      out="$(leftovers::_run "$stem" -- lab::docker network inspect "${net:-$MGMT_NETWORK}")" || {
        echo "LEFTOVER declared-fault $node $id: network ${net:-$MGMT_NETWORK} cannot be inspected"; return 1; }
      if ! jq -e --arg c "$c" '[.[0].Containers // {} | to_entries[] | .value.Name] | index($c)' <<<"$out" >/dev/null; then
        echo "LEFTOVER declared-fault $node $id still in place: $c detached from ${net:-$MGMT_NETWORK} ($(jq -r .change <<<"$f"))"
        return 1
      fi ;;
    link-impairment)
      local c ifc pid out
      c="$(jq -r '.probe.container' <<<"$f")"; ifc="$(jq -r '.probe.interface' <<<"$f")"
      pid="$(lab::docker inspect -f '{{.State.Pid}}' "$c" 2>/dev/null)" || pid=""
      [[ -n "$pid" && "$pid" != 0 ]] || { echo "LEFTOVER declared-fault $node $id: $c not running, impairment cannot be probed"; return 1; }
      out="$(leftovers::_run "$stem" -- "${NSENTER:-nsenter}" -t "$pid" -n "${TC:-tc}" qdisc show dev "$ifc")" || {
        echo "LEFTOVER declared-fault $node $id: tc qdisc on $ifc unreadable"; return 1; }
      if grep -Eq 'netem|tbf' <<<"$out"; then
        echo "LEFTOVER declared-fault $node $id still in place: impairment on $c $ifc ($(jq -r .change <<<"$f"))"
        return 1
      fi ;;
    device-leaf)
      local path faulted out val
      path="$(jq -r '.probe.path' <<<"$f")"; faulted="$(jq -r '.probe.faulted_value | tostring' <<<"$f")"
      lab::gnmic_argv "$(jq -r '.probe.node // .node' <<<"$f")" || return 1
      out="$(leftovers::_run "$stem" -- "${LAB_ARGV[@]}" get --type config --path "$path")" || {
        echo "LEFTOVER declared-fault $node $id: $path unreadable"; return 1; }
      val="$(jq -r "$(lab::jq_lib)"' gvalues | map(if type == "object" then (to_entries[0].value) else . end) | .[0] // empty | tostring' <<<"$out")"
      if [[ "$val" == "$faulted" ]]; then
        echo "LEFTOVER declared-fault $node $id still in place: $path = $val ($(jq -r .change <<<"$f"))"
        return 1
      fi ;;
    *) echo "LEFTOVER declared-fault $node $id has an unknown probe kind '$kind'"; return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------- (iv) the scan

leftovers::_scan_devices() {
  local node out rc=0 line
  for node in $(lab::devices); do
    lab::gnmic_argv "$node" || { rc=1; continue; }
    if ! out="$(leftovers::_run "datastore.${node}" -- "${LAB_ARGV[@]}" get --type config --path /)"; then
      echo "LEFTOVER unscannable $node the running datastore could not be read (gNMI Get failed)"
      rc=1; continue
    fi
    while IFS=$'\t' read -r line val; do
      [[ -n "$line" ]] || continue
      echo "LEFTOVER vt-scratch-object $node ${line} = ${val}"
      rc=1
    done < <(leftovers::_scratch_paths <<<"$out")
  done
  return "$rc"
}

leftovers::_scan_clients() {
  local node out rc=0 l
  for node in $(lab::clients); do
    if ! out="$(leftovers::_run "links.${node}" -- lab::docker exec "$(lab::container "$node")" ip -o link show)"; then
      echo "LEFTOVER unscannable $node the client's links could not be listed"
      rc=1; continue
    fi
    while read -r l; do
      [[ -n "$l" ]] || continue
      echo "LEFTOVER vt-scratch-object $node link ${l}"
      rc=1
    done < <(grep -oE "${LAB_SCRATCH_PREFIX}[A-Za-z0-9._-]*" <<<"$out" | sort -u)
  done
  return "$rc"
}

# a resource type the API server does not serve cannot hold a leftover; anything else fails closed
leftovers::_kubectl_list() {
  local stem="$1"; shift
  local out rc=0
  out="$(leftovers::_run "$stem" -- lab::kubectl "$@" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if grep -q "the server doesn't have a resource type" <<<"$out"; then return 0; fi
    printf '%s\n' "$out" >&2
    return 2
  fi
  printf '%s\n' "$out"
}

LEFTOVERS_ALLOC_NS="agentic-netops-allocation"
LEFTOVERS_ALLOC_RES="identifierclaims.fabric.agentic-netops.io,identifierpools.fabric.agentic-netops.io"

leftovers::_scan_cluster() {
  local out rc=0 l
  out="$(leftovers::_kubectl_list "configs" get configs.config.sdcio.dev -A -o json)" || {
    echo "LEFTOVER unscannable cluster the Configs could not be listed (kind-${CLUSTER_NAME})"; return 1; }
  if [[ -n "$out" ]]; then
    while read -r l; do
      [[ -n "$l" ]] || continue
      echo "LEFTOVER gate-config cluster Config ${l}"
      rc=1
    done < <(jq -r --arg k "$LAB_GATE_LABEL_KEY" --arg v "$LAB_GATE_LABEL_VALUE" --arg p "$LAB_SCRATCH_PREFIX" \
      '.items[]? | select((.metadata.labels[$k] // "") == $v or (.metadata.name | startswith($p)))
       | "\(.metadata.namespace)/\(.metadata.name)"' <<<"$out" 2>/dev/null)
  fi
  out="$(leftovers::_kubectl_list "namespaces" get namespaces -o json)" || {
    echo "LEFTOVER unscannable cluster the namespaces could not be listed (kind-${CLUSTER_NAME})"; return 1; }
  while read -r l; do
    [[ -n "$l" ]] || continue
    echo "LEFTOVER gate-namespace cluster namespace ${l}"
    rc=1
  done < <(jq -r --arg k "$LAB_GATE_LABEL_KEY" --arg v "$LAB_GATE_LABEL_VALUE" --arg p "$LAB_SCRATCH_PREFIX" \
    '.items[]? | select((.metadata.labels[$k] // "") == $v or (.metadata.name | startswith($p)))
     | "\(.metadata.name) (phase \(.status.phase // "?"))"' <<<"$out" 2>/dev/null)
  # the first-party allocation authority's scratch pools and claims (G11); a cluster that does not
  # serve the kinds (kuid selected) holds none
  out="$(leftovers::_kubectl_list "allocation" get "$LEFTOVERS_ALLOC_RES" -n "$LEFTOVERS_ALLOC_NS" -o json)" || {
    echo "LEFTOVER unscannable cluster the IdentifierPools/IdentifierClaims in ${LEFTOVERS_ALLOC_NS} could not be listed (kind-${CLUSTER_NAME})"; return 1; }
  if [[ -n "$out" ]]; then
    while read -r l; do
      [[ -n "$l" ]] || continue
      echo "LEFTOVER gate-allocation cluster ${l}"
      rc=1
    done < <(jq -r --arg k "$LAB_GATE_LABEL_KEY" --arg v "$LAB_GATE_LABEL_VALUE" --arg p "$LAB_SCRATCH_PREFIX" \
      '.items[]? | select((.metadata.labels[$k] // "") == $v or (.metadata.name | startswith($p))
                          or ((.spec.poolRef.name // "") | startswith($p)))
       | "\(.kind) \(.metadata.namespace)/\(.metadata.name)"' <<<"$out" 2>/dev/null)
  fi
  return "$rc"
}

leftovers::_scan_faults() {
  local rc=0 node f
  leftovers::_probe_mgmt || rc=1
  for node in $(lab::all_nodes); do
    leftovers::_probe_netem "$node" || rc=1
  done
  local seq=0
  while read -r f; do
    [[ -n "$f" ]] || continue
    seq=$((seq + 1))
    leftovers::_probe_declared "$f" "$seq" || rc=1
  done < <(leftovers::_declared_faults)
  return "$rc"
}

# leftovers::scan — non-zero, naming each leftover, when any of the four kinds is present.
leftovers::scan() {
  local rc=0 findings
  leftovers::_new_scan_id
  if [[ "${LEFTOVERS_NO_EVIDENCE:-0}" != 1 ]]; then evidence::ensure_dir || return 3; fi
  lab::export_creds || return 1
  findings="$(
    leftovers::_scan_faults
    leftovers::_scan_devices
    leftovers::_scan_clients
    leftovers::_scan_cluster
  )"
  if [[ -n "$findings" ]]; then
    printf '%s\n' "$findings"
    local n
    n="$(grep -c '^LEFTOVER ' <<<"$findings")"
    echo "leftovers: ${n} leftover(s) found — refusing to start. Nothing was cleaned up; run" \
         "leftovers::remove explicitly after reading the list above (FR-108)." >&2
    rc=1
  else
    echo "leftovers: clean — no vt-scratch- object, gate-labelled Config or namespace, detached node," \
         "link impairment or declared fault in place (scan ${LEFTOVERS_SCAN_ID})" >&2
  fi
  return "$rc"
}

# ---------------------------------------------------------------- the explicit clean-up

# leftovers::_gnmi_path <json-path-with-slashes> <values-json> — the gNMI path of the nearest list
# entry enclosing a found vt-scratch- value (the object to delete).
leftovers::_entry_path() {
  local jpath="$1" doc="$2"
  jq -r --arg jp "$jpath" "$(lab::jq_lib)"'
    ($jp | split("/") | map(if test("^[0-9]+$") then tonumber else . end)) as $p
    | . as $root
    # last array index in the path: the enclosing list entry
    | ([range(0; $p | length) | select(($p[.] | type) == "number")] | last) as $li
    | if $li == null then empty else
      reduce range(0; $li + 1) as $i ({out: "", cur: $root};
        ($p[$i]) as $k
        | if ($k | type) == "number" then
            (.cur[$k]) as $e
            | (["name","index","interface-id","group-name","peer-address","sequence-id","id","ip-prefix"]
               | map(select($e[.] != null)) ) as $keys
            | (if ($keys | index("name")) and ($e.type != null) and ((.out | endswith("acl-filter")))
                 then ["name","type"] else [$keys[0]] end) as $use
            | .out += ($use | map("[\(.)=\($e[.] | tostring)]") | join(""))
            | .cur = $e
          else
            .out += "/" + ($k | sub("^[^:]+:"; "")) | .cur = .cur[$k]
          end)
      | .out end' <<<"$doc"
}

# leftovers::remove [--snapshots <dir>] — explicit, evidence-captured clean-up.
#   1. with --snapshots <EVIDENCE_DIR-of-the-dead-run>/gate/scratch: restore every device root the
#      gate had snapshotted before writing (tests/gate/lib/scratch_fabric.sh layout);
#   2. delete every list entry enclosing a vt-scratch- value on every device (one Set per node);
#   3. delete vt-scratch- links on the clients, gate-labelled Configs and namespaces;
#   4. revert every declared fault still in place that carries a revert action;
#   5. scan again and return its verdict.
leftovers::remove() {
  local snapshots=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --snapshots) snapshots="${2:?}"; shift 2 ;;
      *) echo "leftovers::remove: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  leftovers::_new_scan_id
  LEFTOVERS_SCAN_ID="${LEFTOVERS_SCAN_ID/leftover-scan/leftover-remove}"
  evidence::ensure_dir || return 3
  lab::export_creds || return 1
  local node out
  if [[ -n "$snapshots" ]]; then
    # shellcheck source=../gate/lib/scratch_fabric.sh
    source "$LEFTOVERS_REPO_ROOT/tests/gate/lib/scratch_fabric.sh"
    for node in $(lab::devices); do
      [[ -d "$snapshots/$node" ]] || continue
      SCRATCH_SNAPSHOT_DIR="$snapshots" scratch::restore_node "$node" "leftovers-remove" || \
        echo "leftovers: restore of $node from $snapshots failed; continuing with marker deletion" >&2
    done
  fi
  for node in $(lab::devices); do
    lab::gnmic_argv "$node" || continue
    out="$(leftovers::_run "read.${node}" -- "${LAB_ARGV[@]}" get --type config --path /)" || continue
    local doc jp val ep
    doc="$(jq "$(lab::jq_lib)"' gvalues | .[0] // {}' <<<"$out")"
    local -a eps=()
    while IFS=$'\t' read -r jp val; do
      [[ -n "$jp" ]] || continue
      ep="$(leftovers::_entry_path "$jp" "$doc")"
      [[ -n "$ep" ]] && eps+=("$ep")
    done < <(leftovers::_scratch_paths <<<"$out")
    # what references a deleted entry must go in the same transaction: network-instance interface
    # entries naming a deleted subinterface, and the vxlan-interfaces a deleted instance used
    if [[ ${#eps[@]} -gt 0 ]]; then
      while read -r ep; do [[ -n "$ep" ]] && eps+=("$ep"); done < <(
        printf '%s\n' "${eps[@]}" | jq -R -s -r --argjson doc "$doc" "$(lab::jq_lib)"'
          (split("\n") | map(select(length > 0))) as $del
          | ($del | map(capture("^/interface\\[name=(?<i>[^]]+)\\]/subinterface\\[index=(?<n>[0-9]+)\\]$")
                        | "\(.i).\(.n)")) as $subifs
          | ($del | map(capture("^/network-instance\\[name=(?<n>[^]]+)\\]$") | .n)) as $nis
          | ($doc | strip) as $d
          | (($d["network-instance"] // [])[]
             | . as $ni
             | ((.interface // [])[] | select(.name as $x | $subifs | index($x))
                | "/network-instance[name=\($ni.name)]/interface[name=\(.name)]"),
               (select(.name as $x | $nis | index($x)) | (.["vxlan-interface"] // [])[]
                | .name | capture("^(?<t>[^.]+)\\.(?<i>[0-9]+)$")
                | "/tunnel-interface[name=\(.t)]/vxlan-interface[index=\(.i)]")),
            (($d.acl.interface // [])[] | select(.["interface-ref"].interface != null)
             | select("\(.["interface-ref"].interface).\(.["interface-ref"].subinterface)" as $x | $subifs | index($x))
             | "/acl/interface[interface-id=\(.["interface-id"])]")')
    fi
    # scratch BGP whose every group is vt-scratch-: the whole instance is scratch
    if jq -e --arg p "$LAB_SCRATCH_PREFIX" "$(lab::jq_lib)"'
         strip | (.["network-instance"] // [])[] | select(.name == "default") | .protocols.bgp.group // []
         | length > 0 and all(.["group-name"] | startswith($p))' <<<"$doc" >/dev/null 2>&1; then
      eps+=("/network-instance[name=default]/protocols/bgp")
    fi
    if [[ ${#eps[@]} -gt 0 ]]; then
      local -a dels=()
      while read -r ep; do dels+=(--delete "$ep"); done < <(printf '%s\n' "${eps[@]}" | sort -u)
      leftovers::_run "delete.${node}" -- "${LAB_ARGV[@]}" set "${dels[@]}" || \
        echo "leftovers: deleting the marked objects on $node failed — see the evidence record" >&2
    fi
  done
  for node in $(lab::clients); do
    out="$(lab::docker exec "$(lab::container "$node")" ip -o link show 2>/dev/null)" || continue
    local l
    while read -r l; do
      [[ -n "$l" ]] || continue
      leftovers::_run "link-del.${node}.${l}" -- lab::docker exec "$(lab::container "$node")" ip link del "$l" || true
    done < <(grep -oE "${LAB_SCRATCH_PREFIX}[A-Za-z0-9._-]*" <<<"$out" | sort -u)
  done
  leftovers::_run "delete-configs" -- lab::kubectl delete configs.config.sdcio.dev -A -l "$LAB_GATE_SELECTOR" --ignore-not-found --wait=true || true
  leftovers::_run "delete-namespaces" -- lab::kubectl delete namespaces -l "$LAB_GATE_SELECTOR" --ignore-not-found --wait=true || true
  # G11's scratch claims before their pools (a claim's release finalizer needs its pool)
  leftovers::_run "delete-allocation-claims" -- lab::kubectl delete identifierclaims.fabric.agentic-netops.io \
    -n "$LEFTOVERS_ALLOC_NS" -l "$LAB_GATE_SELECTOR" --ignore-not-found --wait=true || true
  leftovers::_run "delete-allocation-pools" -- lab::kubectl delete identifierpools.fabric.agentic-netops.io \
    -n "$LEFTOVERS_ALLOC_NS" -l "$LAB_GATE_SELECTOR" --ignore-not-found --wait=true || true
  local f kind seq=0 rid
  while read -r f; do
    [[ -n "$f" ]] || continue
    seq=$((seq + 1)); rid="revert.${seq}.$(jq -r .id <<<"$f")"
    leftovers::_probe_declared "$f" "$seq" >/dev/null && continue
    kind="$(jq -r '.revert.kind // empty' <<<"$f")"
    case "$kind" in
      docker-network-connect)
        local -a ipf=()
        [[ -n "$(jq -r '.revert.ip // empty' <<<"$f")" ]] && ipf=(--ip "$(jq -r '.revert.ip' <<<"$f")")
        leftovers::_run "$rid" -- lab::docker network connect "${ipf[@]}" \
          "$(jq -r '.probe.network // env.MGMT_NETWORK' <<<"$f")" "$(jq -r '.probe.container' <<<"$f")" || true ;;
      tc-qdisc-del)
        local pid
        pid="$(lab::docker inspect -f '{{.State.Pid}}' "$(jq -r '.probe.container' <<<"$f")")"
        leftovers::_run "$rid" -- "${NSENTER:-nsenter}" -t "$pid" -n "${TC:-tc}" qdisc del dev \
          "$(jq -r '.probe.interface' <<<"$f")" root || true ;;
      device-leaf-set)
        lab::gnmic_argv "$(jq -r '.probe.node // .node' <<<"$f")"
        leftovers::_run "$rid" -- "${LAB_ARGV[@]}" set --delimiter "$LAB_SET_DELIM" \
          --update "$(lab::upd "$(jq -r '.probe.path' <<<"$f")" "$(jq -c '.revert.value' <<<"$f")")" || true ;;
      *) echo "leftovers: declared fault $(jq -r .id <<<"$f") has no revert action; revert it by hand: $(jq -r .change <<<"$f")" >&2 ;;
    esac
  done < <(leftovers::_declared_faults)
  leftovers::scan
}

# leftovers::check_goldens [<dir>] — (i): no golden may carry the reserved scratch prefix, because
# no platform render ever emits it. Non-zero naming every file:line that does.
leftovers::check_goldens() {
  local dir="${1:-$LEFTOVERS_REPO_ROOT/tests/golden}" hits
  [[ -d "$dir" ]] || { echo "leftovers: no golden directory at $dir" >&2; return 2; }
  hits="$(grep -rnF --exclude=.gitkeep -- "$LAB_SCRATCH_PREFIX" "$dir" 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    printf 'golden carries the reserved scratch prefix %s: %s\n' "$LAB_SCRATCH_PREFIX" "$hits" | sed 's/^/FAIL /'
    return 1
  fi
  return 0
}
