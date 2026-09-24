#!/usr/bin/env bash
# Judgement functions are defined inside each check and invoked through sv::poll (SC2317).
# shellcheck disable=SC2317
# tests/integration/lib/services.sh — shared plumbing of the service live suites (T064, T172;
# SC-004 route half, SC-006, SC-045, FR-100, FR-109, NFR-013).
#
# Sourced by tests/integration/{wait_services,verify_services,idempotence,service_delete,
# show_rendered_config,provider_claims}.sh. Executed directly it is a CHECK runner, exactly as
# tests/gate/lib/checks.sh is: ONE command that reads the cluster (or a device), prints what it
# judged, prints a verdict line and exits 0 on PASS / 1 on FAIL — so the same command is both the
# readiness run (evidence_run --readiness) and its negative control (evidence_negative_control).
#
#   services.sh condition <ns> <network> <type> <status> [<reason>] [<message-substring>…]
#   services.sh no_configs <network-ns> <network>          zero Configs labelled with the Network
#   services.sh configs <network-ns> <network> <min>       at least <min> Configs labelled with it
#   services.sh claims_bound <network-ns> <network> <vni…> one bound claim per VNI labelled with the
#                                                          Network, created no later than the
#                                                          Network's first Config
#   services.sh no_claims <network-ns> <network> [vlan]    zero claims (zero VLAN claims with 'vlan')
#   services.sh route <node> <2|3|5> <rd> <via-csv> [<prefix>]  an EVPN route of THIS service
#                                                          (keyed by its RD <vtep>:<evi>) received
#                                                          from a reflecting spine
#   services.sh gone <ns> <kind> <name>                    the object does not exist
#   services.sh ni_absent <node> <network-instance>        absent from the device's running config
#   services.sh snapshot_diff <before> <after>             two snapshots identical (idempotence)
#
# CHECK_WAIT=<s> re-reads until PASS or the window closes (CHECK_INTERVAL, default 5 s).
# Pure helpers (no cluster): sv::judge_condition, sv::manifest_networks, sv::snapshot_diff.
set -euo pipefail

SV_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SV_ROOT="$(cd -- "$SV_LIB_DIR/../../.." && pwd)"

: "${SV_NS:=agentic-netops-services}"          # where the example Networks live (AD-26)
: "${SV_SYS_NS:=agentic-netops-system}"        # where their Configs live (AD-82)
: "${SV_ALLOC_NS:=agentic-netops-allocation}"  # the first-party allocation authority's namespace
: "${SV_CONSTRUCTS:=$SV_ROOT/examples/constructs}"
: "${FABRIC_NAME:=fabric01}"
: "${FABRIC_NAMESPACE:=agentic-netops-system}"
: "${CHECK_WAIT:=0}"
: "${CHECK_INTERVAL:=5}"
SV_NET_RES="networks.fabric.agentic-netops.io"
SV_FABRIC_RES="fabrics.fabric.agentic-netops.io"
SV_CONFIG_RES="configs.config.sdcio.dev"
SV_CLAIM_RES="identifierclaims.fabric.agentic-netops.io"
SV_LBL_NS="agentic-netops.io/network-namespace"
SV_LBL_NAME="agentic-netops.io/network-name"

# ---------------------------------------------------------------- pure helpers (unit-tested)

# sv::judge_condition <type> <status> [<reason>] [<substr>…] — reads an object's JSON on stdin;
# prints "<type>=<status>/<reason>: <message>" and returns 0 when the condition matches (every
# substring present in its message), 1 otherwise ("<type> absent" when there is none).
sv::judge_condition() {
  local type="$1" want="$2" reason="${3:-}"; shift 2; [[ $# -gt 0 ]] && shift
  local line st rs msg s
  line="$(jq -r --arg t "$type" '[(.status.conditions // [])[] | select(.type == $t)] | first
         | if . == null then "" else "\(.status)\t\(.reason // "")\t\(.message // "")" end')"
  if [[ -z "$line" ]]; then printf '%s absent\n' "$type"; return 1; fi
  IFS=$'\t' read -r st rs msg <<<"$line"
  printf '%s=%s/%s: %s\n' "$type" "$st" "$rs" "$msg"
  [[ "$st" == "$want" ]] || return 1
  [[ -z "$reason" || "$rs" == "$reason" ]] || return 1
  for s in "$@"; do [[ "$msg" == *"$s"* ]] || return 1; done
  return 0
}

# sv::manifest_networks <file|dir…> — "<namespace> <name>" of every Network in the manifests
# (a directory is read non-recursively, as `kubectl apply -f <dir>` does).
sv::manifest_networks() {
  local p f
  for p in "$@"; do
    if [[ -d "$p" ]]; then for f in "$p"/*.yaml; do [[ -f "$f" ]] && sv::manifest_networks "$f"; done; continue; fi
    awk '
      /^---/ { if (kind == "Network" && name != "") print ns " " name; kind = ""; name = ""; ns = ""; inmeta = 0; next }
      /^kind:/ { kind = $2 }
      /^metadata:/ { inmeta = 1; next }
      /^[^ #]/ { inmeta = 0 }
      inmeta && /^  name:/ { name = $2 }
      inmeta && /^  namespace:/ { ns = $2 }
      END { if (kind == "Network" && name != "") print ns " " name }' "$p"
  done
}

# sv::snapshot_diff <before> <after> — two snapshot files of "<key> <value>" lines; prints every
# key whose value changed, appeared or vanished; returns 0 when identical, 1 otherwise.
sv::snapshot_diff() {
  local d
  d="$(join -a1 -a2 -e '<absent>' -o 0,1.2,2.2 <(sort "$1") <(sort "$2") | awk '$2 != $3 {print "CHANGED " $1 ": " $2 " -> " $3}')"
  if [[ -n "$d" ]]; then printf '%s\n' "$d"; return 1; fi
  echo "UNCHANGED $(wc -l <"$1") key(s)"
}

# ---------------------------------------------------------------- cluster helpers

sv::k() { "${KUBECTL:-kubectl}" --context "${KUBE_CONTEXT:-kind-${CLUSTER_NAME:-agentic-netops}}" "$@"; }

sv::sel() { printf '%s=%s,%s=%s' "$SV_LBL_NS" "$1" "$SV_LBL_NAME" "$2"; }

sv::say() { printf '%s\n' "$*"; }
sv::verdict() { printf 'CHECK %s: %s — %s\n' "$2" "$1" "$3"; }

# sv::poll <judge-fn> — CHECK_WAIT semantics of checks.sh
sv::poll() {
  local deadline=$(( $(date +%s) + CHECK_WAIT )) n=0
  while :; do
    n=$((n + 1)); sv::say "--- attempt $n ($(date -u +%H:%M:%SZ))"
    if "$1"; then return 0; fi
    [[ "$(date +%s)" -lt "$deadline" ]] || return 1
    sleep "$CHECK_INTERVAL"
  done
}

# ---------------------------------------------------------------- the checks

chk_condition() {
  local ns="$1" name="$2" type="$3" want="$4"; shift 4
  local -a rest=("$@")
  _judge() {
    local j
    j="$(sv::k -n "$ns" get "$SV_NET_RES" "$name" -o json 2>&1)" || { sv::say "get $ns/$name: $j"; return 1; }
    sv::judge_condition "$type" "$want" "${rest[@]}" <<<"$j"
  }
  if sv::poll _judge; then sv::verdict PASS condition "$ns/$name $type=$want${rest[0]:+/${rest[0]}}"; return 0; fi
  sv::verdict FAIL condition "$ns/$name never reported $type=$want${rest[0]:+/${rest[0]}}${rest[1]:+ naming ${rest[*]:1}}"; return 1
}

chk_fabric_condition() {
  local type="$1" want="$2"; shift 2
  local -a rest=("$@")
  _judge() {
    local j
    j="$(sv::k -n "$FABRIC_NAMESPACE" get "$SV_FABRIC_RES" "$FABRIC_NAME" -o json 2>&1)" || { sv::say "$j"; return 1; }
    sv::judge_condition "$type" "$want" "${rest[@]}" <<<"$j"
  }
  if sv::poll _judge; then sv::verdict PASS fabric-condition "$FABRIC_NAME $type=$want${rest[0]:+/${rest[0]}}"; return 0; fi
  sv::verdict FAIL fabric-condition "$FABRIC_NAME never reported $type=$want${rest[0]:+/${rest[0]}}${rest[1]:+ naming ${rest[*]:1}}"; return 1
}

chk_configs() {
  local ns="$1" name="$2" min="$3"
  _judge() {
    local out n
    out="$(sv::k -n "$SV_SYS_NS" get "$SV_CONFIG_RES" -l "$(sv::sel "$ns" "$name")" \
      -o custom-columns=NAME:.metadata.name,GEN:.metadata.generation,READY:.status.conditions[0].status --no-headers 2>&1)" || { sv::say "$out"; return 1; }
    sv::say "${out:-<no Configs>}"
    n="$(grep -c . <<<"$out" || true)"
    [[ "$n" -ge "$min" ]]
  }
  if sv::poll _judge; then sv::verdict PASS configs "$ns/$name has >= $min Config(s) in $SV_SYS_NS"; return 0; fi
  sv::verdict FAIL configs "$ns/$name has fewer than $min Config(s) in $SV_SYS_NS"; return 1
}

chk_no_configs() {
  local ns="$1" name="$2"
  _judge() {
    local out
    out="$(sv::k -n "$SV_SYS_NS" get "$SV_CONFIG_RES" -l "$(sv::sel "$ns" "$name")" -o name 2>&1)" || { sv::say "$out"; return 1; }
    sv::say "Configs: ${out:-none}"
    [[ -z "$out" ]]
  }
  if sv::poll _judge; then sv::verdict PASS no-configs "$ns/$name has zero Configs"; return 0; fi
  sv::verdict FAIL no-configs "$ns/$name has Configs"; return 1
}

# the claims of a Network as JSON: [{name, pool, requested, value, bound, created}]
sv::claims_json() {
  sv::k -n "$SV_ALLOC_NS" get "$SV_CLAIM_RES" -l "$(sv::sel "$1" "$2")" -o json | jq -c '[.items[] | {
      name: .metadata.name, pool: (.spec.poolRef.name // ""), requested: (.spec.requested // null),
      value: ((.status.value // "") | tostring), created: .metadata.creationTimestamp,
      bound: ([(.status.conditions // [])[] | select(.type == "Ready" and .status == "True")] | length > 0)}]'
}

chk_claims_bound() {
  local ns="$1" name="$2"; shift 2
  local -a vnis=("$@")
  _judge() {
    local cj first v ok=0 n
    cj="$(sv::claims_json "$ns" "$name" 2>&1)" || { sv::say "claims: $cj"; return 1; }
    first="$(sv::k -n "$SV_SYS_NS" get "$SV_CONFIG_RES" -l "$(sv::sel "$ns" "$name")" -o json 2>/dev/null \
      | jq -r '[.items[].metadata.creationTimestamp] | sort | first // ""')"
    sv::say "claims: $cj"; sv::say "first Config created: ${first:-none}"
    for v in "${vnis[@]}"; do
      n="$(jq --arg v "$v" --arg f "$first" '[.[] | select(.value == $v and .bound and ($f == "" or .created <= $f))] | length' <<<"$cj")"
      sv::say "VNI $v: $n bound claim(s) labelled $ns/$name created no later than the first Config"
      [[ "$n" == 1 ]] || ok=1
    done
    return "$ok"
  }
  if sv::poll _judge; then sv::verdict PASS claims-bound "$ns/$name: one bound claim per VNI (${vnis[*]}) before its first Config"; return 0; fi
  sv::verdict FAIL claims-bound "$ns/$name: not exactly one bound claim per VNI (${vnis[*]}) preceding its first Config"; return 1
}

chk_no_claims() {
  local ns="$1" name="$2" only="${3:-}"
  _judge() {
    local cj n
    cj="$(sv::claims_json "$ns" "$name" 2>&1)" || { sv::say "claims: $cj"; return 1; }
    sv::say "claims: $cj"
    if [[ "$only" == vlan ]]; then n="$(jq '[.[] | select(.pool | test("vlan"; "i"))] | length' <<<"$cj")"
    else n="$(jq 'length' <<<"$cj")"; fi
    [[ "$n" == 0 ]]
  }
  if sv::poll _judge; then sv::verdict PASS no-claims "$ns/$name: zero ${only:+VLAN }claims"; return 0; fi
  sv::verdict FAIL no-claims "$ns/$name: ${only:+VLAN }claims present"; return 1
}

chk_gone() {
  local ns="$1" kind="$2" name="$3"
  _judge() {
    local out rc=0
    out="$(sv::k -n "$ns" get "$kind" "$name" -o name 2>&1)" || rc=$?
    sv::say "$out"
    [[ "$rc" -ne 0 && "$out" == *NotFound* ]]
  }
  if sv::poll _judge; then sv::verdict PASS gone "$kind $ns/$name does not exist"; return 0; fi
  sv::verdict FAIL gone "$kind $ns/$name still exists"; return 1
}

# route <node> <type> <rd> <via-csv> [prefix] — keyed to THIS service by its route distinguisher
# (auto-derived <vtep>:<evi>, evi := vni) and, for Type 5, the prefix
chk_route() {
  local node="$1" rtype="$2" rd="$3" via="$4" prefix="${5:-}"
  # shellcheck source=SCRIPTDIR/../../lib/lab.sh
  source "$SV_ROOT/tests/lib/lab.sh"
  local jql; jql="$(lab::jq_lib)"
  _judge() {
    local out rc=0 rep
    lab::gnmic_argv "$node" || return 1
    out="$("${LAB_ARGV[@]}" get --type state --path "/network-instance[name=default]/bgp-rib" 2>&1)" || rc=$?
    [[ "$rc" -eq 0 ]] || { sv::say "gnmic @ $node rc=$rc: $out"; return 1; }
    rep="$(jq -r --arg t "$rtype" --arg rd "$rd" --arg v "$via" --arg p "$prefix" "$jql"'
      gvalues | .[0] // {} | strip | unwrap("bgp-rib")
      | ($v | split(",")) as $via
      | [(.["afi-safi"] // [])[] | select(.["afi-safi-name"] | idname == "evpn") | .evpn["rib-in-out"]["rib-in-post"] // {}] | first // {}
      | (if $t == "3" then .["imet-route"] elif $t == "2" then .["mac-ip-route"] else .["ip-prefix-route"] end) // []
      | map(select(.["route-distinguisher"] == $rd
                   and ($p == "" or ("\(.["ip-prefix"])" | split("/")[0]) == ($p | split("/")[0]))))
      | if length == 0 then "none" else
          map("\(if (.neighbor as $n | $via | index($n)) != null then "OK" else "NOTVIA" end) type-\($t) rd=\(.["route-distinguisher"]) neighbor=\(.neighbor)"
              + (if .["ip-prefix"] then " prefix=\(.["ip-prefix"])" else "" end)
              + (if .["mac-address"] then " mac=\(.["mac-address"])" else "" end)) | join("\n") end' <<<"$out" 2>&1)"
    sv::say "$rep"
    grep -q '^OK ' <<<"$rep"
  }
  if sv::poll _judge; then sv::verdict PASS route "$node received type-$rtype rd=$rd${prefix:+ $prefix} through a reflecting spine ($via)"; return 0; fi
  sv::verdict FAIL route "$node: no type-$rtype rd=$rd${prefix:+ for $prefix} received through $via"; return 1
}

chk_ni_absent() {
  local node="$1" ni="$2"
  # shellcheck source=SCRIPTDIR/../../lib/lab.sh
  source "$SV_ROOT/tests/lib/lab.sh"
  local jql; jql="$(lab::jq_lib)"
  _judge() {
    local out rc=0 n
    lab::gnmic_argv "$node" || return 1
    out="$("${LAB_ARGV[@]}" get --type config --path "/network-instance[name=${ni}]" 2>&1)" || rc=$?
    sv::say "gnmic get config /network-instance[name=${ni}] @ $node rc=$rc"; sv::say "$out"
    [[ "$rc" -eq 0 ]] || return 1
    n="$(jq -r "$jql"' [gvalues[] | select(. != null and . != {})] | length' <<<"$out" 2>/dev/null || echo 1)"
    [[ "$n" == 0 ]]
  }
  if sv::poll _judge; then sv::verdict PASS ni-absent "$node has no network-instance $ni"; return 0; fi
  sv::verdict FAIL ni-absent "$node still carries network-instance $ni"; return 1
}

sv::main() {
  local c="${1:-}"; shift || true
  case "$c" in
    condition|fabric_condition|configs|no_configs|claims_bound|no_claims|gone|route|ni_absent) "chk_$c" "$@" ;;
    snapshot_diff) [[ $# -eq 2 ]] || { echo "usage: services.sh snapshot_diff <before> <after>" >&2; return 2; }; sv::snapshot_diff "$@" ;;
    *) echo "usage: services.sh condition|fabric_condition|configs|no_configs|claims_bound|no_claims|gone|route|ni_absent <args…>" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then sv::main "$@"; fi
