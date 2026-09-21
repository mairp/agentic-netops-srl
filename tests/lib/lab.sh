#!/usr/bin/env bash
# tests/lib/lab.sh — the lab's identity for verification tooling (T043, T051; FR-108).
#
# Verification tooling (the capability gate, the fabric checks, the fault-making suites) is the
# only code in this repository allowed to open a device session, and only from under tests/
# (make verify-boundaries). This file is the one place that tooling learns WHERE the lab is:
#
#   LAB_NAME        containerlab lab name        (default agentic-netops-fabric)
#   CLUSTER_NAME    Kind cluster name            (default agentic-netops; context kind-<cluster>)
#   MGMT_NETWORK    docker management network    (default agentic-netops-mgmt)
#   MGMT_CIDR       management /24               (default 172.25.25.0/24)
#   LAB_SPINES / LAB_LEAVES / LAB_CLIENTS   node names (defaults spine01 spine02 / leaf01 leaf02 /
#                   client01 client02)
#   LAB_ADDR_<node> overrides one node's management address (e.g. LAB_ADDR_leaf01=10.9.9.9)
#   SRL_USER / SRL_PASS  the lab operator's device credentials. They reach gnmic ONLY through the
#                   GNMIC_USERNAME / GNMIC_PASSWORD environment variables (lab::export_creds), never
#                   through argv — so no evidence record (which captures argv) ever holds them.
#   GNMIC / KUBECTL / DOCKER   client overrides (tests put fakes on PATH instead)
#   KUBE_CONTEXT    overrides kind-<cluster>
#
# Addresses follow the brief's fixed plan: spines .11/.12, leaves .21/.22, clients .31/.32 of
# MGMT_CIDR. containerlab names containers clab-<lab>-<node>.
#
# Functions: lab::devices lab::spines lab::leaves lab::clients lab::all_nodes lab::container
#   lab::addr lab::host_octet lab::export_creds lab::gnmic_argv (fills the LAB_ARGV array)
#   lab::kubectl lab::docker lab::role lab::is_spine lab::is_leaf

# Node lists are space-separated words by design (SC2086); the LAB_* constants and LAB_ARGV are
# read by the files that source this one (SC2034).
# shellcheck disable=SC2086,SC2034
[[ -n "${__AGENTIC_NETOPS_TESTS_LAB_SH:-}" ]] && return 0
__AGENTIC_NETOPS_TESTS_LAB_SH=1

: "${LAB_NAME:=agentic-netops-fabric}"
: "${CLUSTER_NAME:=agentic-netops}"
: "${MGMT_NETWORK:=agentic-netops-mgmt}"
: "${MGMT_CIDR:=172.25.25.0/24}"
: "${LAB_SPINES:=spine01 spine02}"
: "${LAB_LEAVES:=leaf01 leaf02}"
: "${LAB_CLIENTS:=client01 client02}"
: "${SRL_USER:=admin}"
: "${GNMI_PORT:=57400}"
: "${GNMIC_TIMEOUT:=30s}"
export LAB_NAME CLUSTER_NAME MGMT_NETWORK MGMT_CIDR

# The reserved scratch prefix and the gate-owned label (T043 i, ii). Declared here because every
# FR-108 tool names its scratch with them; tests/lib/leftovers.sh is where they are enforced.
LAB_SCRATCH_PREFIX="vt-scratch-"
LAB_GATE_LABEL_KEY="agentic-netops.io/gate-owned"
LAB_GATE_LABEL_VALUE="true"
LAB_GATE_SELECTOR="${LAB_GATE_LABEL_KEY}=${LAB_GATE_LABEL_VALUE}"

lab::spines()    { printf '%s\n' $LAB_SPINES; }
lab::leaves()    { printf '%s\n' $LAB_LEAVES; }
lab::clients()   { printf '%s\n' $LAB_CLIENTS; }
lab::devices()   { printf '%s\n' $LAB_SPINES $LAB_LEAVES; }
lab::all_nodes() { printf '%s\n' $LAB_SPINES $LAB_LEAVES $LAB_CLIENTS; }

lab::is_spine() { [[ " $LAB_SPINES " == *" $1 "* ]]; }
lab::is_leaf()  { [[ " $LAB_LEAVES " == *" $1 "* ]]; }
lab::role() {
  if lab::is_spine "$1"; then echo spine
  elif lab::is_leaf "$1"; then echo leaf
  else echo client; fi
}

lab::container() { printf 'clab-%s-%s' "$LAB_NAME" "$1"; }

# lab::host_octet <node> — the fixed host part: spines 11.., leaves 21.., clients 31..
lab::host_octet() {
  local node="$1" i=0 n
  for n in $LAB_SPINES;  do i=$((i + 1)); [[ "$n" == "$node" ]] && { echo $((10 + i)); return 0; }; done
  i=0; for n in $LAB_LEAVES;  do i=$((i + 1)); [[ "$n" == "$node" ]] && { echo $((20 + i)); return 0; }; done
  i=0; for n in $LAB_CLIENTS; do i=$((i + 1)); [[ "$n" == "$node" ]] && { echo $((30 + i)); return 0; }; done
  return 1
}

lab::addr() {
  local node="$1" var="LAB_ADDR_${1//-/_}" octet net
  if [[ -n "${!var:-}" ]]; then printf '%s' "${!var}"; return 0; fi
  octet="$(lab::host_octet "$node")" || { echo "lab: unknown node '$node'" >&2; return 1; }
  net="${MGMT_CIDR%/*}"
  printf '%s.%s' "${net%.*}" "$octet"
}

# lab::export_creds — hand the operator credentials to gnmic through its environment only.
lab::export_creds() {
  if [[ -z "${SRL_PASS:-}" ]]; then
    echo "lab: SRL_PASS is not set (read it from the generated Secret; see quickstart.md §3)" >&2
    return 1
  fi
  export GNMIC_USERNAME="$SRL_USER" GNMIC_PASSWORD="$SRL_PASS"
}

# lab::gnmic_argv <node> — LAB_ARGV=(gnmic -a <addr>:57400 --skip-verify -e json_ietf --timeout …)
# The caller appends the RPC and its flags. -e json_ietf is not optional on this platform.
lab::gnmic_argv() {
  local addr
  addr="$(lab::addr "$1")" || return 1
  LAB_ARGV=("${GNMIC:-gnmic}" -a "${addr}:${GNMI_PORT}" --skip-verify -e json_ietf --timeout "$GNMIC_TIMEOUT")
}

# Set values go as --update "<path><D>json_ietf<D><json>" with this delimiter: gnmic's
# --update-value mangles a top-level JSON array (a leaf-list, an empty leaf's [null]), and the
# default ":::" delimiter is one colon away from an IPv6 literal.
LAB_SET_DELIM=";;;"
# lab::upd <path> <json> — one --update argument
lab::upd() { printf '%s' "${1}${LAB_SET_DELIM}json_ietf${LAB_SET_DELIM}${2}"; }

lab::kubectl() {
  "${KUBECTL:-kubectl}" --context "${KUBE_CONTEXT:-kind-${CLUSTER_NAME}}" "$@"
}

lab::docker() { "${DOCKER:-docker}" "$@"; }

# lab::jq_lib — jq definitions shared by every reader of gnmic output:
#   strip     remove the module prefix from every object key (JSON_IETF qualifies augments)
#   gvalues   the values of every update of a gnmic `get` (json format) response
#   unwrap(n) descend into key n when the value is still wrapped in its own container name
#   num       uint64 counters arrive as JSON strings under JSON_IETF; make them numbers
#   idname    the identity name of an identityref value, with or without its module prefix
lab::jq_lib() {
  cat <<'JQ'
def strip: walk(if type == "object" then with_entries(.key |= sub("^[^:/\\[]+:"; "")) else . end);
def gvalues: [ .[]? | .updates[]? | .values | to_entries[] | .value ];
def unwrap(n): if type == "object" and (keys == [n]) then .[n] else . end;
def num: if type == "string" then (tonumber? // 0) elif type == "number" then . else 0 end;
def idname: if type == "string" then sub("^.*:"; "") else . end;
def aslist: if type == "array" then . elif . == null then [] else [.] end;
JQ
}
