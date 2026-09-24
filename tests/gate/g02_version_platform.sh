#!/usr/bin/env bash
# tests/gate/g02_version_platform.sh — G2: version and platform identity — the pinned release train
# (25.7.1), 7220 IXR-D2L on the leaves and 7220 IXR-D3L on the spines — and the management ports
# the pinned image actually listens on, read from /system/grpc-server, /system/json-rpc-server,
# /system/ssh-server, /system/netconf-server and /system/snmp state and written to the tracked
# tests/gate/observed/mgmt-ports.json, against which T066's denial probe set is reconciled — the
# documented list is checked, never trusted (T043; quickstart.md §1, §15).
#
# The observed file carries no timestamp or run id. As corroboration the listening sockets of the
# node's management namespace (srbase-mgmt) are listed too (docker exec, a device client allowed
# here under tests/); a node where that listing is unavailable says so. Each socket is recorded with
# its bind address and scope — `loopback` (127.0.0.0/8, ::1: reachable only from inside the node),
# `any` (0.0.0.0, ::, *) or `specific` — because a loopback-only listener is not a door on the
# management network while every other one is (live-findings 2026-09-24-loopback-listeners). The
# union over every device of the listeners NOT bound to loopback is `network_listeners`, the set
# T066's boundary probe reconciles against the contract's port list; the loopback-only ones are
# `loopback_listeners`, recorded and never a probe target.
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then exec bash "$GATE_HERE/run_gate.sh" --only G2 "$@"; fi
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"

: "${G2_LEAF_TYPE:=7220 IXR-D2L}"
: "${G2_SPINE_TYPE:=7220 IXR-D3L}"

# g02::ports <node> — one JSON object: the node's management services and their ports
g02::ports() {
  local node="$1" p out j="{}"
  for p in /system/grpc-server /system/json-rpc-server /system/ssh-server /system/netconf-server /system/snmp; do
    out="$(gate::dev "G02.mgmt.${node}.${p##*/}" "$node" get --type state --path "$p" 2>/dev/null)" || out="[]"
    j="$(jq -c --arg k "${p##*/}" --argjson r "$(jq -c "$(lab::jq_lib)"' gvalues | .[0] // null | if . == null then null else strip end' <<<"$out" 2>/dev/null || echo null)" \
      '. + {($k): $r}' <<<"$j")"
  done
  jq -c "$(lab::jq_lib)"'
    def st(x): (x // "unknown");
    [ ((.["grpc-server"] | unwrap("grpc-server") | aslist)[]? | select(. != null)
       | {service: "grpc", instance: .name, transport: "tcp", port: (.port // 57400), port_source: (if .port then "state" else "yang-default" end),
          network_instance: .["network-instance"], admin_state: st(.["admin-state"]), oper_state: st(.["oper-state"]),
          services: ((.services // []) | map(tostring) | sort)} ),
      ((.["json-rpc-server"] | unwrap("json-rpc-server")) as $j | ($j["network-instance"] // [])[]?
       | . as $ni
       | ((if .http then {service: "json-rpc-http", port: (.http.port // 80), port_source: (if .http.port then "state" else "yang-default" end), admin_state: st(.http["admin-state"]), oper_state: st(.http["oper-state"])} else empty end),
          (if .https then {service: "json-rpc-https", port: (.https.port // 443), port_source: (if .https.port then "state" else "yang-default" end), admin_state: st(.https["admin-state"]), oper_state: st(.https["oper-state"])} else empty end))
       | . + {instance: "json-rpc", transport: "tcp", network_instance: $ni.name, services: []}),
      ((.["ssh-server"] | unwrap("ssh-server") | aslist)[]? | select(. != null)
       | {service: "ssh", instance: .name, transport: "tcp", port: (.port // 22), port_source: (if .port then "state" else "yang-default" end),
          network_instance: .["network-instance"], admin_state: st(.["admin-state"]), oper_state: st(.["oper-state"]), services: []}),
      ((.["netconf-server"] | unwrap("netconf-server") | aslist)[]? | select(. != null)
       | {service: "netconf", instance: .name, transport: "tcp", port: null, port_source: "via ssh-server \(.["ssh-server"] // "?")",
          network_instance: null, admin_state: st(.["admin-state"]), oper_state: st(.["oper-state"]), services: [], ssh_server: .["ssh-server"]}),
      ((.snmp | unwrap("snmp") | .["network-instance"] // [])[]?
       | {service: "snmp", instance: "snmp", transport: "udp", port: 161, port_source: "protocol-default (no port leaf in the model)",
          network_instance: .name, admin_state: st(.["admin-state"]), oper_state: st(.["oper-state"]), services: []})
    ] as $svc
    # a netconf server listens on the port of the ssh-server it names
    | [$svc[] | if .service == "netconf" then (.ssh_server as $s | . + {port: ([$svc[] | select(.service == "ssh" and .instance == $s) | .port] | first)} | del(.ssh_server)) else . end]
    | sort_by(.service, .instance, .network_instance // "")' <<<"$j"
}

# g02::parse_listeners — `ss -Hltun` text on stdin → a JSON array of
# {transport, port, address, scope}, sorted and unique. The local address column ($5) is
# `<addr>:<port>`, `[<v6>]:<port>` or `*:<port>`, the address optionally carrying `%<interface>`.
# scope: loopback (127.0.0.0/8, ::1, ::ffff:127.x), any (*, 0.0.0.0, ::), specific (anything else).
g02::parse_listeners() {
  awk 'NF >= 5 { print $1 "\t" $5 }' | jq -R -s -c '
    split("\n") | map(select(length > 0) | split("\t")
      | .[0] as $t | .[1] as $local
      | ($local | capture("^(?<a>.*):(?<p>[0-9]+|\\*)$")) as $m
      | ($m.a | ltrimstr("[") | rtrimstr("]") | sub("%.*$"; "")) as $addr
      | {transport: $t, port: ($m.p | tonumber? // $m.p), address: $addr,
         scope: (if ($addr | test("^(127\\.|::1$|::ffff:127\\.)")) then "loopback"
                 elif ($addr | IN("*", "0.0.0.0", "::", "")) then "any"
                 else "specific" end)})
    | unique | sort_by(.transport, .port, .address)'
}

g02::listeners() {
  local node="$1" out
  out="$(gate::run "G02.listeners.${node}" -- lab::docker exec "$(lab::container "$node")" \
    ip netns exec srbase-mgmt ss -Hltun 2>/dev/null)" || { echo '"unavailable"'; return 0; }
  g02::parse_listeners <<<"$out"
}

# g02::observation <image-release> <nodes-json> — the tracked observation (mgmt-ports.json).
#   listening           the management services read from state that are enabled or up, by port
#   network_listeners   every socket of the management namespace NOT bound to loopback, over every
#                       device — what the boundary probe (T066) reconciles against the contract
#   loopback_listeners  the loopback-only sockets: recorded, unreachable from the network
#   listeners_unavailable  the devices whose socket listing could not be read (reconciliation
#                       refuses an observation with any)
g02::observation() {
  jq -n --arg v "$1" --argjson n "$2" '
    def socks: [$n[] | .mgmt_namespace_listeners | select(type == "array") | .[]];
    {schema: "agentic-netops.gate.mgmt-ports/v1", image_release: $v,
     source: "gNMI Get --type state of /system/{grpc-server,json-rpc-server,ssh-server,netconf-server,snmp} on every device, and ss -Hltun in each device'"'"'s srbase-mgmt namespace (G2)",
     nodes: $n,
     listening: ([$n[] | .services[] | select((.admin_state == "enable" or .oper_state == "up") and .port != null)
                  | {transport, port, service}] | group_by([.transport, .port])
                 | map({transport: .[0].transport, port: .[0].port, services: (map(.service) | unique)})),
     network_listeners: ([socks[] | select(.scope != "loopback")] | group_by([.transport, .port])
                 | map({transport: .[0].transport, port: .[0].port, addresses: (map(.address) | unique)})),
     loopback_listeners: ([socks[] | select(.scope == "loopback")] | group_by([.transport, .port])
                 | map({transport: .[0].transport, port: .[0].port, addresses: (map(.address) | unique)})),
     listeners_unavailable: ([$n | to_entries[] | select(.value.mgmt_namespace_listeners | type != "array") | .key] | sort)}'
}

g02::run() {
  gate::item_begin G2 "Version and platform identity, and the management ports the image listens on"
  local node rc want check nodes="{}" svc lis
  for node in $(lab::devices); do
    if lab::is_spine "$node"; then want="$G2_SPINE_TYPE"; check=G2-identity-spine; else want="$G2_LEAF_TYPE"; check=G2-identity-leaf; fi
    rc=0; gate::ready "G02.identity.${node}" "$check" identity "$node" "v${GATE_PINNED_VERSION}" "$want" || rc=$?
    gate::item_check "identity:${node}" "$rc" "$node runs v${GATE_PINNED_VERSION} on ${want}"
    svc="$(g02::ports "$node")" || svc="[]"
    lis="$(g02::listeners "$node")"
    nodes="$(jq -c --arg n "$node" --arg r "$(lab::role "$node")" --argjson s "$svc" --argjson l "$lis" \
      '. + {($n): {role: $r, services: $s, mgmt_namespace_listeners: $l}}' <<<"$nodes")"
    rc=0; jq -e 'any(.[]; .service == "grpc" and .port == 57400)' <<<"$svc" >/dev/null || rc=1
    gate::item_check "mgmt-ports:${node}" "$rc" "$node management services read from state ($(jq -r 'map("\(.service)/\(.port)") | join(" ")' <<<"$svc"))" ""
  done
  local obs
  obs="$(g02::observation "$GATE_PINNED_VERSION" "$nodes")"
  gate::observed mgmt-ports.json "$obs" || gate::item_check "observed-file" 1 "mgmt-ports.json refused"
  gate::item_observe listening "$(jq -c .listening <<<"$obs")"
  gate::item_observe network_listeners "$(jq -c .network_listeners <<<"$obs")"
  gate::item_observe loopback_listeners "$(jq -c .loopback_listeners <<<"$obs")"
  gate::item_end
}
