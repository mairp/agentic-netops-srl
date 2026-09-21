#!/usr/bin/env bash
# tests/integration/fabric_verify.sh — the fabric checks (T051; SC-004 session half, FR-011,
# FR-012, FR-013, FR-015, FR-100, FR-108; quickstart.md §3–§4; AD-23, AD-31, R-46).
#
# Behind the make targets (recipes in the stream report):
#   wait-fabric                   the default Fabric (fabric01) reports Ready=True
#   verify-fabric-control-plane   (a)  every configured BGP session established AND the EVPN
#                                      family's own oper-state up per overlay neighbour
#                                 (a2) every other node's allocated system0.0 loopback active in
#                                      each node's route table (keyed to the Fabric's allocations)
#                                 (c)  inter-as-vpn and route-reflector client read back true from
#                                      every reflecting spine — a CONFIGURATION-INTEGRITY check
#                                      (both are configuration leaves the state datastore mirrors)
#                                 (b)  the per-neighbour EVPN received-route counters — REPORTED,
#                                      NOT ASSERTED: with no service on the fabric zero is correct;
#                                      T064's verify_services.sh asserts them per service
#                                      spines terminate no tenant VXLAN; leaves use system0.0 as
#                                      the VTEP source (shown by the probe below)
#                                 (d)  the post-render reflection probe (FR-108), once per bring-up,
#                                      after every fabric Config is Applied and BEFORE any Network
#                                      exists: leftovers::scan first (refuses on any leftover), a
#                                      scratch EVPN instance vt-scratch-probe-<evi> on each leaf,
#                                      the other leaf's Type-3 observed RECEIVED THROUGH THE
#                                      SPINES, then removed with the removal read back on every
#                                      node. Reported and evidence-captured, NEVER an input to
#                                      Fabric.status: it proves reflection on the provider-rendered
#                                      fabric rather than on the gate's scratch configuration.
#   show-bgp / show-evpn / show-allocations / show-rendered-config   operator read-outs
#
# Every device call runs through evidence_run with the lab operator's credentials (SRL_USER /
# SRL_PASS through gnmic's environment only). Every readiness check has its negative control
# recorded first (against a service / neighbour that does not exist, or a node that is not a
# reflector), so its pass is admitted (NFR-013, SC-040).
#
# Usage: fabric_verify.sh <subcommand> [--no-probe]
# Environment: EVIDENCE_DIR, CLUSTER_NAME, LAB_NAME, MGMT_CIDR, SRL_USER, SRL_PASS,
#   FABRIC_NAME (fabric01), FABRIC_NAMESPACE (agentic-netops-system), FABRIC_WAIT (900 s),
#   FV_WAIT (180 s, the per-check window), FV_PROBE_EVI (19990).
set -euo pipefail

FV_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FV_ROOT="$(cd -- "$FV_HERE/../.." && pwd)"
# shellcheck source=../gate/lib/gate.sh
source "$FV_ROOT/tests/gate/lib/gate.sh"
# shellcheck source=../lib/leftovers.sh
source "$FV_ROOT/tests/lib/leftovers.sh"

: "${FABRIC_NAME:=fabric01}"
: "${FABRIC_NAMESPACE:=agentic-netops-system}"
: "${FABRIC_WAIT:=900}"
: "${FV_WAIT:=180}"
: "${FV_PROBE_EVI:=19990}"
FV_FABRIC_RES="fabrics.fabric.agentic-netops.io"
FV_ABSENT_PEER="192.0.2.250"   # a neighbour / loopback no fabric allocates (TEST-NET-1)
FV_FAILS=()

fv::fail() { FV_FAILS+=("$1"); log::error "FAIL $1"; }
fv::ok()   { log::info "PASS $1"; }

# ---------------------------------------------------------------- the Fabric's own facts

fv::fabric_json() {
  gate::run "FV.fabric" -- lab::kubectl -n "$FABRIC_NAMESPACE" get "$FV_FABRIC_RES" "$FABRIC_NAME" -o json
}

# fv::load — FV_NODES (name role loopback), from the Fabric's allocations (status) with the spec's
# stated systemIPv4 as the fallback; FV_RR (the reflectors)
fv::load() {
  local fj
  fj="$(fv::fabric_json 2>/dev/null)" || { log::error "Fabric ${FABRIC_NAMESPACE}/${FABRIC_NAME} not found"; return 1; }
  FV_NODES="$(jq -r '
    (.status.allocations // []) as $a
    | .spec.nodes[]
    | . as $n
    | ([$a[] | select(.node == $n.name and ((.purpose // "") | test("loopback|system")) and (.value // "") != "") | .value] | first
       // $n.systemIPv4 // "") as $lb
    | "\($n.name) \($n.role) \($lb | split("/")[0])"' <<<"$fj")"
  FV_RR="$(jq -r '(.spec.overlay.routeReflectors // [.spec.nodes[] | select(.routeReflector == true) | .name]) | join(" ")' <<<"$fj")"
  FV_INTERASVPN="$(jq -r '.spec.overlay.interASVPN // "unset"' <<<"$fj")"
  log::info "Fabric ${FABRIC_NAME}: $(tr '\n' ';' <<<"$FV_NODES") reflectors: ${FV_RR}; spec.overlay.interASVPN=${FV_INTERASVPN}"
}
fv::lb()    { awk -v n="$1" '$1 == n {print $3}' <<<"$FV_NODES"; }
fv::role()  { awk -v n="$1" '$1 == n {print $2}' <<<"$FV_NODES"; }
fv::names() { awk '{print $1}' <<<"$FV_NODES"; }
fv::by_role() { awk -v r="$1" '$2 == r {print $1}' <<<"$FV_NODES"; }
fv::csv_lb() { local n o=""; for n in "$@"; do o+="${o:+,}$(fv::lb "$n")"; done; printf '%s' "$o"; }
fv::overlay_peers() {
  if [[ "$(fv::role "$1")" == spine ]]; then fv::csv_lb $(fv::by_role leaf); else fv::csv_lb $FV_RR; fi
}

# ---------------------------------------------------------------- subcommands

fv::wait_fabric() {
  log::phase FabricReady
  gate::init
  local rc=0
  gate::run "FV.wait-fabric" -- lab::kubectl -n "$FABRIC_NAMESPACE" wait --for=condition=Ready \
    "${FV_FABRIC_RES}/${FABRIC_NAME}" --timeout="${FABRIC_WAIT}s" || rc=$?
  gate::run "FV.fabric-status" -- lab::kubectl -n "$FABRIC_NAMESPACE" get "$FV_FABRIC_RES" "$FABRIC_NAME" -o wide || true
  if [[ "$rc" -ne 0 ]]; then
    lab::kubectl -n "$FABRIC_NAMESPACE" get "$FV_FABRIC_RES" "$FABRIC_NAME" \
      -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' >&2 || true
    log::error "Fabric ${FABRIC_NAME} did not report Ready=True within ${FABRIC_WAIT}s"
    return 1
  fi
  log::info "Fabric ${FABRIC_NAME} is Ready"
}

fv::negative_controls() {
  local leaf spine n
  leaf="$(fv::by_role leaf | head -1)"; spine="$(fv::by_role spine | head -1)"
  gate::negative FV-sessions bgp_sessions "$leaf" --evpn-up "$FV_ABSENT_PEER" || true
  gate::negative FV-loopbacks route_active "$leaf" default ipv4 '^bgp$' "${FV_ABSENT_PEER}/32" || true
  gate::negative FV-reflector reflector "$leaf" || true       # a leaf reflects nothing
  n="$(fv::by_role leaf | sed -n 2p)"
  gate::negative FV-probe-type3 evpn_route "$n" 3 "$FV_ABSENT_PEER" "$(fv::csv_lb $FV_RR)" || true
}

fv::verify() {
  local probe=1
  [[ "${1:-}" == --no-probe ]] && probe=0
  log::phase FabricReady
  gate::init
  GATE_ITEM=fabric
  # the leftover scan first: a leftover of an earlier, interrupted run refuses the start (FR-108)
  if ! leftovers::scan; then
    log::error "verify-fabric-control-plane REFUSED to start: leftovers present (listed above); run leftovers::remove explicitly"
    return 3
  fi
  fv::load || return 1
  fv::negative_controls

  local n rc lbs=() peers
  # (a) sessions + EVPN family oper-state per overlay neighbour
  for n in $(fv::names); do
    peers="$(fv::overlay_peers "$n")"
    rc=0; CHECK_WAIT="$FV_WAIT" evidence_run "$(gate::id "FV.a.sessions.${n}")" --check FV-sessions --readiness --records SC-004:session \
      -- bash "$GATE_CHECKS" bgp_sessions "$n" --evpn-up "$peers" || rc=$?
    [[ "$rc" -eq 0 ]] && fv::ok "(a) $n: sessions established, EVPN oper-state up on $peers" || fv::fail "(a) sessions/EVPN oper-state on $n"
  done
  # (a2) every other node's allocated loopback active in this node's route table
  for n in $(fv::names); do
    lbs=(); local m
    for m in $(fv::names); do [[ "$m" == "$n" ]] || lbs+=("$(fv::lb "$m")/32"); done
    rc=0; CHECK_WAIT="$FV_WAIT" evidence_run "$(gate::id "FV.a2.loopbacks.${n}")" --check FV-loopbacks --readiness \
      -- bash "$GATE_CHECKS" route_active "$n" default ipv4 '^bgp$' "${lbs[@]}" || rc=$?
    [[ "$rc" -eq 0 ]] && fv::ok "(a2) $n: every other node's loopback active" || fv::fail "(a2) loopbacks on $n"
  done
  # (c) configuration-integrity on the reflectors
  for n in $FV_RR; do
    rc=0; evidence_run "$(gate::id "FV.c.reflector.${n}")" --check FV-reflector --readiness \
      -- bash "$GATE_CHECKS" reflector "$n" || rc=$?
    [[ "$rc" -eq 0 ]] && fv::ok "(c) $n: inter-as-vpn + route-reflector client true (configuration-integrity)" || fv::fail "(c) reflector settings on $n"
  done
  # spines terminate no tenant VXLAN
  for n in $(fv::by_role spine); do
    rc=0; evidence_run "$(gate::id "FV.no-tenant.${n}")" --check FV-no-tenant -- bash "$GATE_CHECKS" no_tenant "$n" || rc=$?
    [[ "$rc" -eq 0 ]] && fv::ok "$n terminates no tenant VXLAN" || fv::fail "tenant VXLAN on spine $n"
  done
  # (b) reported, not asserted
  for n in $(fv::by_role leaf); do
    evidence_run "$(gate::id "FV.b.received.${n}")" --check FV-received-report \
      -- bash "$GATE_CHECKS" evpn_received "$n" zero "$(fv::csv_lb $FV_RR)" >/dev/null 2>&1 || true
    log::info "(b) $n EVPN received-routes (reported, not asserted): $(grep -h 'evpn received-routes' "$EVIDENCE_DIR/$(ls -t "$EVIDENCE_DIR" | grep -m1 "^FV.b.received.${n}.*\.stdout$")" 2>/dev/null | tail -"$(wc -w <<<"$FV_RR")" | tr '\n' ' ')"
  done
  # (d) the post-render reflection probe
  if [[ "$probe" == 1 ]]; then fv::probe || true; fi

  if [[ ${#FV_FAILS[@]} -gt 0 ]]; then
    log::error "verify-fabric-control-plane FAILED: ${FV_FAILS[*]}"
    return 1
  fi
  log::info "verify-fabric-control-plane passed (evidence: $EVIDENCE_DIR)"
}

fv::probe() {
  local nets leaves a b rc spines evi="$FV_PROBE_EVI" prev_desc
  nets="$(lab::kubectl get networks.fabric.agentic-netops.io -A -o name 2>/dev/null || true)"
  if [[ -n "$nets" ]]; then
    log::warn "(d) reflection probe not run: a Network already exists (the probe runs once per bring-up, before any Network)"
    return 0
  fi
  mapfile -t leaves < <(fv::by_role leaf)
  spines="$(fv::csv_lb $FV_RR)"
  SCRATCH_SNAPSHOT_DIR="$EVIDENCE_DIR/fabric-probe/scratch"; export SCRATCH_SNAPSHOT_DIR
  prev_desc="$SCRATCH_DESC"; SCRATCH_DESC="vt-scratch-probe"
  log::info "(d) reflection probe: vt-scratch-probe-${evi} on ${leaves[*]}, Type-3 through the spines ($spines)"
  local wrote=0
  for a in "${leaves[@]}"; do
    scratch::snapshot_node "$a" probe FV.probe
    rc=0; scratch::apply "$a" "FV.probe.apply.${a}" scratch::probe_updates "$a" "$evi" >/dev/null || rc=$?
    wrote=1
    [[ "$rc" -eq 0 ]] || fv::fail "(d) probe instance not committed on $a"
  done
  local seen=0
  for a in "${leaves[@]}"; do
    for b in "${leaves[@]}"; do
      [[ "$a" == "$b" ]] && continue
      rc=0; CHECK_WAIT="$FV_WAIT" evidence_run "$(gate::id "FV.d.type3.${b}")" --check FV-probe-type3 --readiness \
        -- bash "$GATE_CHECKS" evpn_route "$b" 3 "$(fv::lb "$a")" "$spines" || rc=$?
      if [[ "$rc" -eq 0 ]]; then seen=$((seen + 1)); fv::ok "(d) $b received ${a}'s Type-3 through a reflecting spine"
      else fv::fail "(d) reflection probe: $b received no Type-3 from $a through the spines"; fi
      rc=0; evidence_run "$(gate::id "FV.d.vtep-source.${a}")" --check FV-vtep-source \
        -- bash "$GATE_CHECKS" vtep_source "$a" "$(fv::lb "$a")" "$b" "$evi" || rc=$?
      [[ "$rc" -eq 0 ]] && fv::ok "$a uses system0.0 ($(fv::lb "$a")) as its VTEP source" || fv::fail "VTEP source of $a"
    done
  done
  # removal, read back on every node
  if [[ "$wrote" == 1 ]]; then
    for a in "${leaves[@]}"; do
      rc=0; scratch::restore_node "$a" FV.probe "$evi" >/dev/null || rc=$?
      [[ "$rc" -eq 0 ]] || fv::fail "(d) probe removal transaction on $a"
      rc=0; scratch::verify_restored "$a" FV.probe || rc=$?
      [[ "$rc" -eq 0 ]] || fv::fail "(d) probe removal read-back on $a"
    done
    if leftovers::scan >/dev/null; then fv::ok "(d) probe removed, read back on every node"
    else fv::fail "(d) scratch left behind after the probe"; fi
  fi
  SCRATCH_DESC="$prev_desc"
  log::info "(d) reflection probe: ${seen} Type-3 route(s) observed through the reflectors — reported, never an input to Fabric.status"
}

fv::show_bgp() {
  gate::init
  fv::load || return 1
  local n out
  for n in $(fv::names); do
    out="$(gate::dev "FV.show-bgp.${n}" "$n" get --type state --path "/network-instance[name=default]/protocols/bgp" 2>/dev/null)" || out="[]"
    printf '\n== %s (%s)\n' "$n" "$(fv::role "$n")"
    jq -r "$(lab::jq_lib)"'
      gvalues | .[0] // {} | strip | unwrap("bgp")
      | "AS \(.["autonomous-system"] // "?")  router-id \(.["router-id"] // "?")",
        ((.neighbor // [])[] | "  \(.["peer-address"])\t\(.["peer-group"] // "-")\t\(.["session-state"] // "?")\t"
          + ([(.["afi-safi"] // [])[] | "\(.["afi-safi-name"] | idname):\(.["oper-state"] // "?") rx=\(.["received-routes"] // "?") act=\(.["active-routes"] // "?")"] | join("  ")))' <<<"$out"
  done
}

fv::show_evpn() {
  gate::init
  fv::load || return 1
  local n out rib
  for n in $(fv::names); do
    printf '\n== %s (%s)\n' "$n" "$(fv::role "$n")"
    out="$(gate::dev "FV.show-evpn.ni.${n}" "$n" get --type state --path "/network-instance" 2>/dev/null)" || out="[]"
    jq -r "$(lab::jq_lib)"'
      gvalues | map(strip | if has("network-instance") then .["network-instance"][] else . end) | .[]
      | select(.protocols["bgp-evpn"] != null)
      | "  \(.name) \(.type | idname) evi=\([.protocols["bgp-evpn"]["bgp-instance"][]?.evi] | join(",")) oper=\(.["oper-state"] // "?")"' <<<"$out" 2>/dev/null || true
    rib="$(gate::dev "FV.show-evpn.rib.${n}" "$n" get --type state --path "/network-instance[name=default]/bgp-rib" 2>/dev/null)" || rib="[]"
    jq -r "$(lab::jq_lib)"'
      gvalues | .[0] // {} | strip | unwrap("bgp-rib")
      | [(.["afi-safi"] // [])[] | select(.["afi-safi-name"] | idname == "evpn") | .evpn["rib-in-out"]["rib-in-post"] // {}] | first // {}
      | "  EVPN rib-in-post: type2=\((.["mac-ip-route"] // []) | length) type3=\((.["imet-route"] // []) | length) type5=\((.["ip-prefix-route"] // []) | length)"' <<<"$rib" 2>/dev/null || true
    if [[ "$(fv::role "$n")" == spine ]]; then
      bash "$GATE_CHECKS" reflector "$n" 2>/dev/null | sed -n 's/^inter-as-vpn/  inter-as-vpn/p' || true
    fi
  done
}

fv::show_allocations() {
  gate::init
  gate::run "FV.show-allocations.fabric" -- lab::kubectl -n "$FABRIC_NAMESPACE" get "$FV_FABRIC_RES" "$FABRIC_NAME" \
    -o jsonpath='{range .status.allocations[*]}{.purpose}{"\t"}{.node}{"\t"}{.value}{"\t"}{.indexKind}{"\t"}{.namespace}/{.name}{"\t"}bound={.bound}{"\n"}{end}' || true
  gate::run "FV.show-allocations.claims" -- lab::kubectl get \
    ipclaims.ipam.be.kuid.dev,asclaims.as.be.kuid.dev,vlanclaims.vlan.be.kuid.dev,genidclaims.genid.be.kuid.dev -A || true
}

fv::show_rendered_config() {
  gate::init
  local line ns name
  while read -r line; do
    [[ -n "$line" ]] || continue
    ns="${line%% *}"; name="${line##* }"
    printf '\n== Config %s/%s\n' "$ns" "$name"
    gate::run "FV.show-rendered.${name}" -- lab::kubectl -n "$ns" get configs.config.sdcio.dev "$name" -o yaml || true
  done < <(lab::kubectl -n "$FABRIC_NAMESPACE" get "$FV_FABRIC_RES" "$FABRIC_NAME" \
            -o jsonpath='{range .status.renderedConfigs[*]}{.namespace} {.name}{"\n"}{end}' 2>/dev/null)
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    wait-fabric) fv::wait_fabric "$@" ;;
    verify-fabric-control-plane|verify) fv::verify "$@" ;;
    show-bgp) fv::show_bgp ;;
    show-evpn) fv::show_evpn ;;
    show-allocations) fv::show_allocations ;;
    show-rendered-config) fv::show_rendered_config ;;
    *) echo "usage: $0 wait-fabric | verify-fabric-control-plane [--no-probe] | show-bgp | show-evpn | show-allocations | show-rendered-config" >&2; return 2 ;;
  esac
}

main "$@"
