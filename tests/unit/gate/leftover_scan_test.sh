#!/usr/bin/env bash
# tests/lib/leftovers.sh suite (T043 iv; FR-108, SC-049, AD-49, AD-64). Offline: gnmic, kubectl,
# docker, nsenter and tc are fakes on PATH; evidence identities are stubbed; everything is written
# under a temp directory.
#
# Four kinds of leftover, one plant of each, each refusing the start NAMING it:
#   - a device datastore carrying one vt-scratch- instance
#   - a cluster carrying one gate-labelled Config
#   - a cluster carrying one gate-labelled scratch namespace
#   - a node missing from the management network
# and a clean lab starts. Also: a declared fault still in place refuses the start, a declared fault
# is written before it is made, a link impairment is found, an unreadable datastore fails closed,
# and the scan captures its device reads as evidence without the credentials in argv.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DIGEST=sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; FAKE="$TMP/fake"
mkdir -p "$BIN" "$FAKE/gnmic"

# --- fakes ------------------------------------------------------------------------------------
cat >"$BIN/gnmic" <<'SH'
#!/usr/bin/env bash
# fake gnmic: `get` answers from $FAKE/gnmic/<addr>.json (default: a clean datastore);
# $FAKE/gnmic/<addr>.fail makes the RPC fail. Records argv and whether a password was on it.
addr=""; while [[ $# -gt 0 ]]; do case "$1" in -a) addr="${2%:*}"; shift 2 ;; *) args+=("$1"); shift ;; esac; done
printf '%s\n' "${args[*]}" >>"$FAKE/gnmic.calls"
[[ " ${args[*]} " == *" -p "* || " ${args[*]} " == *"--password"* ]] && echo "password-on-argv" >>"$FAKE/gnmic.calls"
[[ -n "${GNMIC_PASSWORD:-}" ]] || { echo "fake gnmic: no GNMIC_PASSWORD in env" >&2; exit 1; }
if [[ -f "$FAKE/gnmic/$addr.fail" ]]; then echo "rpc error: code = Unavailable" >&2; exit 1; fi
if [[ -f "$FAKE/gnmic/$addr.json" ]]; then cat "$FAKE/gnmic/$addr.json"; exit 0; fi
cat <<JSON
[{"source":"$addr","updates":[{"Path":"","values":{"":{"srl_nokia-interfaces:interface":[{"name":"mgmt0","description":"management"}],"srl_nokia-network-instance:network-instance":[{"name":"mgmt","type":"srl_nokia-network-instance:ip-vrf"}]}}}]}]
JSON
SH
cat >"$BIN/kubectl" <<'SH'
#!/usr/bin/env bash
# fake kubectl: `get configs…` / `get namespaces` answer from $FAKE/configs.json / namespaces.json
a=" $* "
if [[ "$a" == *" get configs.config.sdcio.dev "* ]]; then cat "$FAKE/configs.json" 2>/dev/null || echo '{"items":[]}'; exit 0; fi
if [[ "$a" == *" get namespaces "* ]]; then cat "$FAKE/namespaces.json"; exit 0; fi
echo "fake kubectl: unexpected: $*" >&2; exit 1
SH
cat >"$BIN/docker" <<'SH'
#!/usr/bin/env bash
# fake docker: network inspect from $FAKE/network.json; inspect -f pid → 4242; exec … ip -o link
case "$1" in
  network) cat "$FAKE/network.json" ;;
  inspect) echo 4242 ;;
  exec) c="$2"; cat "$FAKE/links.$c" 2>/dev/null || printf '1: lo: <LOOPBACK,UP> mtu 65536\n2: eth1@if5: <UP> mtu 9348\n' ;;
  *) echo "fake docker: unexpected $*" >&2; exit 1 ;;
esac
SH
cat >"$BIN/nsenter" <<'SH'
#!/usr/bin/env bash
# fake nsenter: -t PID -n <cmd…> → run cmd
while [[ "$1" == -* ]]; do case "$1" in -t) shift 2 ;; *) shift ;; esac; done
exec "$@"
SH
cat >"$BIN/tc" <<'SH'
#!/usr/bin/env bash
cat "$FAKE/qdisc" 2>/dev/null || echo "qdisc noqueue 0: dev lo root refcnt 2"
SH
chmod +x "$BIN"/*

NODES_NET='{"Containers":{}}'
reset_lab() {
  rm -f "$FAKE"/gnmic/* "$FAKE/configs.json" "$FAKE/qdisc" "$FAKE"/links.* "$FAKE/gnmic.calls"
  local n containers="{}"
  for n in spine01 spine02 leaf01 leaf02 client01 client02; do
    containers="$(jq -c --arg n "clab-agentic-netops-fabric-$n" '. + {("id-" + $n): {Name: $n}}' <<<"$containers")"
  done
  jq -n --argjson c "$containers" '[{Name: "agentic-netops-mgmt", Containers: $c}]' >"$FAKE/network.json"
  echo '{"items":[{"metadata":{"name":"sdc-system","labels":{}},"status":{"phase":"Active"}},{"metadata":{"name":"agentic-netops-system","labels":{"agentic-netops.io/owned-by":"agentic-netops"}},"status":{"phase":"Active"}}]}' >"$FAKE/namespaces.json"
  rm -rf "$TMP/evidence"
}

# scan [extra snippet] — run leftovers::scan with the library sourced; prints output, then rc=N
scan() {
  env -u EVIDENCE_DIR PATH="$BIN:$PATH" FAKE="$FAKE" \
    EVIDENCE_ROOT="$TMP/evidence" EVIDENCE_CLUSTER=agentic-netops EVIDENCE_CLUSTER_UID=uid-1 \
    EVIDENCE_LAB=agentic-netops-fabric EVIDENCE_DEVICE_IMAGE_DIGEST="$DIGEST" EVIDENCE_TOPOLOGY=/nonexistent \
    CLUSTER_NAME=agentic-netops LAB_NAME=agentic-netops-fabric SRL_USER=admin SRL_PASS='NokiaSrl1!' \
    bash -c "set -uo pipefail; source '$ROOT/tests/lib/leftovers.sh'; ${1:-:}; leftovers::scan; echo rc=\$?" 2>&1
}

# --- 1. a clean lab starts
reset_lab
out="$(scan)"
if grep -qx 'rc=0' <<<"$out" && ! grep -q '^LEFTOVER' <<<"$out"; then
  pass "a clean lab starts (scan exit 0, no leftover named)"
else
  fail "a clean lab starts (scan exit 0, no leftover named)" "$out"
fi
if [[ -f "$FAKE/gnmic.calls" ]] && ! grep -q 'password-on-argv' "$FAKE/gnmic.calls" \
   && grep -q -- '--type config --path /' "$FAKE/gnmic.calls" \
   && [[ "$(grep -c -- 'get --type config --path /' "$FAKE/gnmic.calls")" -eq 4 ]]; then
  pass "every device's running datastore is read (4 gNMI Gets of / --type config), credentials never on argv"
else
  fail "every device's running datastore is read (4 gNMI Gets of / --type config), credentials never on argv" "$(cat "$FAKE/gnmic.calls" 2>/dev/null)"
fi
if ls "$TMP"/evidence/agentic-netops_agentic-netops-fabric/*/leftover-scan-*.datastore.leaf01.json >/dev/null 2>&1 \
   && ! grep -rq 'NokiaSrl1!' "$TMP/evidence"; then
  pass "the scan's device reads are run-captured evidence (and no evidence file holds the password)"
else
  fail "the scan's device reads are run-captured evidence (and no evidence file holds the password)" "$(ls -R "$TMP/evidence" 2>&1 | head -20)"
fi

# --- 2. one vt-scratch- instance in a datastore
reset_lab
cat >"$FAKE/gnmic/172.25.25.22.json" <<'JSON'
[{"source":"172.25.25.22","updates":[{"Path":"","values":{"":{"srl_nokia-network-instance:network-instance":[{"name":"mgmt"},{"name":"vt-scratch-macvrf","type":"srl_nokia-network-instance:mac-vrf"}]}}}]}]
JSON
out="$(scan)"
if grep -qx 'rc=1' <<<"$out" && grep -q '^LEFTOVER vt-scratch-object leaf02 .*vt-scratch-macvrf' <<<"$out"; then
  pass "a datastore carrying one vt-scratch- instance refuses the start naming the node and the object"
else
  fail "a datastore carrying one vt-scratch- instance refuses the start naming the node and the object" "$out"
fi

# --- 3. one gate-labelled Config
reset_lab
echo '{"items":[{"metadata":{"name":"vt-scratch-g13-leaf01","namespace":"sdc-system","labels":{"agentic-netops.io/gate-owned":"true"}}},{"metadata":{"name":"fabric01-leaf01","namespace":"sdc-system","labels":{}}}]}' >"$FAKE/configs.json"
out="$(scan)"
if grep -qx 'rc=1' <<<"$out" && grep -q '^LEFTOVER gate-config cluster Config sdc-system/vt-scratch-g13-leaf01' <<<"$out" \
   && ! grep -q 'fabric01-leaf01' <<<"$out"; then
  pass "a cluster carrying one gate-labelled Config refuses the start naming it (a platform Config is not named)"
else
  fail "a cluster carrying one gate-labelled Config refuses the start naming it (a platform Config is not named)" "$out"
fi

# --- 4. one gate-labelled scratch namespace
reset_lab
jq '.items += [{"metadata":{"name":"vt-scratch-g07-telemetry","labels":{"agentic-netops.io/gate-owned":"true"}},"status":{"phase":"Active"}}]' \
  "$FAKE/namespaces.json" >"$FAKE/ns.tmp" && mv "$FAKE/ns.tmp" "$FAKE/namespaces.json"
out="$(scan)"
if grep -qx 'rc=1' <<<"$out" && grep -q '^LEFTOVER gate-namespace cluster namespace vt-scratch-g07-telemetry' <<<"$out"; then
  pass "a cluster carrying one gate-labelled scratch namespace refuses the start naming it"
else
  fail "a cluster carrying one gate-labelled scratch namespace refuses the start naming it" "$out"
fi

# --- 5. a node missing from the management network
reset_lab
jq '.[0].Containers |= with_entries(select(.value.Name != "clab-agentic-netops-fabric-leaf01"))' \
  "$FAKE/network.json" >"$FAKE/net.tmp" && mv "$FAKE/net.tmp" "$FAKE/network.json"
out="$(scan)"
if grep -qx 'rc=1' <<<"$out" && grep -q '^LEFTOVER mgmt-detached leaf01 ' <<<"$out" \
   && [[ "$(grep -c '^LEFTOVER' <<<"$out")" -eq 1 ]]; then
  pass "a node missing from the management network refuses the start naming it (and only it)"
else
  fail "a node missing from the management network refuses the start naming it (and only it)" "$out"
fi

# --- 6. declared faults: written before, and a fault still in place refuses the start
reset_lab
cat >"$FAKE/gnmic/172.25.25.21.json" <<'JSON'
[{"source":"172.25.25.21","updates":[{"Path":"interface[name=ethernet-1/49]/admin-state","values":{"interface[name=ethernet-1/49]/admin-state":"disable"}}]}]
JSON
out="$(scan "leftovers::declare_fault vt-scratch-f1 leaf01 'ethernet-1/49 admin-state disable' \
  '{\"kind\":\"device-leaf\",\"node\":\"leaf01\",\"path\":\"/interface[name=ethernet-1/49]/admin-state\",\"faulted_value\":\"disable\"}' \
  '{\"kind\":\"device-leaf-set\",\"value\":\"enable\"}' || echo DECLARE-FAILED; \
  jq -e '.faults[0].node == \"leaf01\" and .faults[0].probe.kind == \"device-leaf\"' \"\$EVIDENCE_DIR/declared-faults.json\" >/dev/null && echo DECLARED-OK")"
if grep -q 'DECLARED-OK' <<<"$out" && grep -qx 'rc=1' <<<"$out" \
   && grep -q '^LEFTOVER declared-fault leaf01 vt-scratch-f1 still in place' <<<"$out"; then
  pass "declare_fault writes declared-faults.json (node, change, probe) and a fault still in place refuses the start"
else
  fail "declare_fault writes declared-faults.json (node, change, probe) and a fault still in place refuses the start" "$out"
fi

# --- 7. a host-side link impairment is found
reset_lab
printf 'qdisc noqueue 0: dev lo root refcnt 2\nqdisc netem 8001: dev e1-49 root refcnt 2 limit 1000 delay 100ms\n' >"$FAKE/qdisc"
out="$(scan)"
if grep -qx 'rc=1' <<<"$out" && grep -q '^LEFTOVER link-impairment spine01 qdisc netem' <<<"$out"; then
  pass "a link impairment (netem qdisc) left on a node's link refuses the start naming the node"
else
  fail "a link impairment (netem qdisc) left on a node's link refuses the start naming the node" "$out"
fi

# --- 8. fail closed: an unreadable datastore refuses the start
reset_lab
: >"$FAKE/gnmic/172.25.25.11.fail"
out="$(scan)"
if grep -qx 'rc=1' <<<"$out" && grep -q '^LEFTOVER unscannable spine01' <<<"$out"; then
  pass "a datastore that cannot be read is reported unscannable and refuses the start (fails closed)"
else
  fail "a datastore that cannot be read is reported unscannable and refuses the start (fails closed)" "$out"
fi

# --- 9. a vt-scratch- link left on a client
reset_lab
printf '1: lo: <LOOPBACK>\n7: vt-scratch-3990@eth1: <UP> mtu 9348\n' >"$FAKE/links.clab-agentic-netops-fabric-client02"
out="$(scan)"
if grep -qx 'rc=1' <<<"$out" && grep -q '^LEFTOVER vt-scratch-object client02 link vt-scratch-3990' <<<"$out"; then
  pass "a vt-scratch- link left on a client container refuses the start naming it"
else
  fail "a vt-scratch- link left on a client container refuses the start naming it" "$out"
fi

if [[ "$fails" -gt 0 ]]; then echo "leftover_scan_test: $fails FAILED"; exit 1; fi
echo "leftover_scan_test: all passed"
