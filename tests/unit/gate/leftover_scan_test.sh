#!/usr/bin/env bash
# tests/lib/leftovers.sh suite (T043 iv; FR-108, SC-049, AD-49, AD-64). Offline: gnmic, kubectl,
# docker, nsenter and tc are fakes on PATH; evidence identities are stubbed; everything is written
# under a temp directory.
#
# Four kinds of leftover, one plant of each, each refusing the start NAMING it:
#   - a device datastore carrying one vt-scratch- instance
#   - a cluster carrying one gate-labelled Config
#   - a cluster carrying one gate-labelled scratch namespace
#   - a node missing from the management network — probed on the data path (link carrier and,
#     for a device, a TCP accept on its gNMI port), never on Docker's endpoint record
#   - (first-party authority, T181) a vt-scratch- IdentifierPool and a gate-labelled
#     IdentifierClaim in agentic-netops-allocation; a cluster that does not serve the kinds
#     (kuid selected) is scanned clean
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
if [[ "$a" == *" config get-contexts "* ]]; then
  [[ -f "$FAKE/contexts" ]] || { echo "fake kubectl: no kubeconfig" >&2; exit 1; }; cat "$FAKE/contexts"; exit 0
fi
if [[ "$a" == *" get configs.config.sdcio.dev "* ]]; then cat "$FAKE/configs.json" 2>/dev/null || echo '{"items":[]}'; exit 0; fi
if [[ "$a" == *" get namespaces "* ]]; then cat "$FAKE/namespaces.json"; exit 0; fi
if [[ "$a" == *" get identifierclaims.fabric.agentic-netops.io,identifierpools.fabric.agentic-netops.io -n agentic-netops-allocation "* ]]; then
  # $FAKE/allocation.json present = the first-party CRDs are served; absent = kuid selected
  if [[ -f "$FAKE/allocation.json" ]]; then cat "$FAKE/allocation.json"; exit 0; fi
  echo 'error: the server doesn'"'"'t have a resource type "identifierclaims"' >&2; exit 1
fi
echo "fake kubectl: unexpected: $*" >&2; exit 1
SH
cat >"$BIN/docker" <<'SH'
#!/usr/bin/env bash
# fake docker: network inspect from $FAKE/network.json; inspect -f pid → 4242; exec … ip -o link
case "$1" in
  network) cat "$FAKE/network.json" ;;
  inspect) c="${@: -1}"
    if [[ -f "$FAKE/absent.$c" ]]; then echo "Error: No such object: $c" >&2; exit 1; fi
    cat "$FAKE/pid.$c" 2>/dev/null || echo 4242 ;;
  exec) c="$2"; cat "$FAKE/links.$c" 2>/dev/null || printf '1: lo: <LOOPBACK,UP> mtu 65536\n2: eth1@if5: <UP> mtu 9348\n' ;;
  *) echo "fake docker: unexpected $*" >&2; exit 1 ;;
esac
SH
cat >"$BIN/nsenter" <<'SH'
#!/usr/bin/env bash
# fake nsenter: -t PID -n <cmd…> → run cmd
while [[ "$1" == -* ]]; do case "$1" in -t) export FAKE_PID="$2"; shift 2 ;; *) shift ;; esac; done
exec "$@"
SH
cat >"$BIN/ip" <<'SH'
#!/usr/bin/env bash
# fake ip (inside a container's netns via fake nsenter): the management link carries unless
# $FAKE/nocarrier.<pid> exists
case "$*" in
  "-o link show mgmt0"|"-o link show eth0")
    if [[ -f "$FAKE/nocarrier.${FAKE_PID:-}" ]]; then echo "9: $4@if10: <BROADCAST,MULTICAST,UP> mtu 1514 state LOWERLAYERDOWN"
    else echo "9: $4@if10: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1514 state UP"; fi ;;
  *) exit 1 ;;
esac
SH
cat >"$BIN/tcp-accept" <<'SH'
#!/usr/bin/env bash
# fake TCP accept probe: refused when $FAKE/refuse.<addr> exists
[[ ! -f "$FAKE/refuse.$1" ]]
SH
cat >"$BIN/tc" <<'SH'
#!/usr/bin/env bash
cat "$FAKE/qdisc" 2>/dev/null || echo "qdisc noqueue 0: dev lo root refcnt 2"
SH
chmod +x "$BIN"/*

NODES_NET='{"Containers":{}}'
reset_lab() {
  rm -f "$FAKE"/gnmic/* "$FAKE/configs.json" "$FAKE/qdisc" "$FAKE"/links.* "$FAKE/gnmic.calls" "$FAKE/allocation.json" \
    "$FAKE"/pid.* "$FAKE"/nocarrier.* "$FAKE"/refuse.* "$FAKE"/absent.* "$FAKE/contexts"
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
    CLUSTER_NAME=agentic-netops LAB_NAME=agentic-netops-fabric LAB_TCP_ACCEPT=tcp-accept SRL_USER=admin SRL_PASS='NokiaSrl1!' \
    bash -c "set -uo pipefail; source '$ROOT/tests/lib/leftovers.sh'; ${1:-:}; leftovers::scan; echo rc=\$?" 2>&1
}

scan_nocreds() {
  env -u EVIDENCE_DIR -u SRL_PASS PATH="$BIN:$PATH" FAKE="$FAKE" \
    EVIDENCE_ROOT="$TMP/evidence" EVIDENCE_CLUSTER=agentic-netops EVIDENCE_CLUSTER_UID=uid-1 \
    EVIDENCE_LAB=agentic-netops-fabric EVIDENCE_DEVICE_IMAGE_DIGEST="$DIGEST" EVIDENCE_TOPOLOGY=/nonexistent \
    CLUSTER_NAME=agentic-netops LAB_NAME=agentic-netops-fabric LAB_TCP_ACCEPT=tcp-accept SRL_USER=admin \
    bash -c "set -uo pipefail; source '$ROOT/tests/lib/leftovers.sh'; leftovers::scan; echo rc=\$?" 2>&1
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
echo '{"items":[{"metadata":{"name":"vt-scratch-g13-leaf01","namespace":"agentic-netops-system","labels":{"agentic-netops.io/gate-owned":"true"}}},{"metadata":{"name":"fabric01-leaf01","namespace":"agentic-netops-system","labels":{}}}]}' >"$FAKE/configs.json"
out="$(scan)"
if grep -qx 'rc=1' <<<"$out" && grep -q '^LEFTOVER gate-config cluster Config agentic-netops-system/vt-scratch-g13-leaf01' <<<"$out" \
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

# --- 5. a node whose management data path is down (link carries no signal)
reset_lab
echo 4243 >"$FAKE/pid.clab-agentic-netops-fabric-leaf01"; : >"$FAKE/nocarrier.4243"
out="$(scan)"
if grep -qx 'rc=1' <<<"$out" && grep -q '^LEFTOVER mgmt-detached leaf01 management link mgmt0' <<<"$out" \
   && [[ "$(grep -c '^LEFTOVER' <<<"$out")" -eq 1 ]]; then
  pass "a node whose management link carries no signal refuses the start naming it (and only it)"
else
  fail "a node whose management link carries no signal refuses the start naming it (and only it)" "$out"
fi

# --- 5b. a device whose link carries but whose gNMI port accepts nothing from the host
reset_lab
: >"$FAKE/refuse.172.25.25.22"
out="$(scan)"
if grep -qx 'rc=1' <<<"$out" && grep -q '^LEFTOVER mgmt-detached leaf02 gNMI port 172.25.25.22:57400' <<<"$out"; then
  pass "a device whose gNMI port accepts no connection from the host refuses the start naming it"
else
  fail "a device whose gNMI port accepts no connection from the host refuses the start naming it" "$out"
fi

# --- 5c. regression (2026-09-21): Docker's endpoint record lacks a node whose data path is up —
#         the record is not the probe, so the lab starts
reset_lab
jq '.[0].Containers |= with_entries(select(.value.Name != "clab-agentic-netops-fabric-leaf02"))' \
  "$FAKE/network.json" >"$FAKE/net.tmp" && mv "$FAKE/net.tmp" "$FAKE/network.json"
out="$(scan)"
if grep -qx 'rc=0' <<<"$out" && ! grep -q '^LEFTOVER' <<<"$out"; then
  pass "a node absent from Docker's endpoint record but reachable on its data path is not a leftover"
else
  fail "a node absent from Docker's endpoint record but reachable on its data path is not a leftover" "$out"
fi

# --- 5d. a declared mgmt-link-down fault still in place refuses the start naming it
reset_lab
echo 4244 >"$FAKE/pid.clab-agentic-netops-fabric-leaf02"; : >"$FAKE/nocarrier.4244"
out="$(scan "leftovers::declare_fault vt-scratch-tf-mgmt-leaf02 leaf02 'management link set down' \
  '{\"kind\":\"mgmt-link-down\",\"container\":\"clab-agentic-netops-fabric-leaf02\",\"interface\":\"mgmt0\",\"peer\":\"veth1\"}' \
  '{\"kind\":\"host-link-up\"}'")"
if grep -qx 'rc=1' <<<"$out" && grep -q '^LEFTOVER declared-fault leaf02 vt-scratch-tf-mgmt-leaf02 still in place' <<<"$out"; then
  pass "a declared mgmt-link-down fault still in place refuses the start naming it"
else
  fail "a declared mgmt-link-down fault still in place refuses the start naming it" "$out"
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

# --- 6b. the same fault id declared by two runs, since reverted: one scan probes both declarations
#         without an evidence-id collision (evidence is never overwritten) and the lab starts
reset_lab
cat >"$FAKE/gnmic/172.25.25.21.json" <<'JSON'
[{"source":"172.25.25.21","updates":[{"Path":"interface[name=ethernet-1/55]/description","values":{"interface[name=ethernet-1/55]/description":"vt-intent"}}]}]
JSON
for run in 20260921T084615Z 20260921T085311Z; do
  mkdir -p "$TMP/evidence/agentic-netops_agentic-netops-fabric/$run"
  jq -n '{schema: "agentic-netops.declared-faults/v1", faults: [{id: "vt-scratch-g13-drift", node: "leaf01", change: "drift",
          probe: {kind: "device-leaf", node: "leaf01", path: "/interface[name=ethernet-1/55]/description", faulted_value: "vt-scratch-g13-drift"},
          revert: null}]}' >"$TMP/evidence/agentic-netops_agentic-netops-fabric/$run/declared-faults.json"
done
out="$(scan)"
if grep -qx 'rc=0' <<<"$out" && ! grep -q '^LEFTOVER' <<<"$out" && ! grep -q 'already exists' <<<"$out"; then
  pass "one fault id declared by two runs and since reverted: both declarations probed, no evidence-id collision, the lab starts"
else
  fail "one fault id declared by two runs and since reverted: both declarations probed, no evidence-id collision, the lab starts" "$out"
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

# --- 10. first-party allocation authority: G11's scratch pool and a gate-labelled claim
reset_lab
cat >"$FAKE/allocation.json" <<'JSON'
{"kind":"List","items":[
 {"kind":"IdentifierPool","metadata":{"name":"fabric01-vlan","namespace":"agentic-netops-allocation","labels":{}},"spec":{"type":"vlan"}},
 {"kind":"IdentifierPool","metadata":{"name":"vt-scratch-g11-vlan","namespace":"agentic-netops-allocation","labels":{}},"spec":{"type":"vlan"}},
 {"kind":"IdentifierClaim","metadata":{"name":"g11-dyn","namespace":"agentic-netops-allocation","labels":{"agentic-netops.io/gate-owned":"true"}},"spec":{"poolRef":{"name":"fabric01-vlan"}}},
 {"kind":"IdentifierClaim","metadata":{"name":"fabric01-leaf01-loopback","namespace":"agentic-netops-allocation","labels":{}},"spec":{"poolRef":{"name":"fabric01-loopback"}}}]}
JSON
out="$(scan)"
if grep -qx 'rc=1' <<<"$out" \
   && grep -q '^LEFTOVER gate-allocation cluster IdentifierPool agentic-netops-allocation/vt-scratch-g11-vlan' <<<"$out" \
   && grep -q '^LEFTOVER gate-allocation cluster IdentifierClaim agentic-netops-allocation/g11-dyn' <<<"$out" \
   && ! grep -q 'fabric01-' <<<"$out"; then
  pass "a vt-scratch- IdentifierPool and a gate-labelled IdentifierClaim in agentic-netops-allocation refuse the start naming them (platform pools/claims are not named)"
else
  fail "a vt-scratch- IdentifierPool and a gate-labelled IdentifierClaim in agentic-netops-allocation refuse the start naming them (platform pools/claims are not named)" "$out"
fi
reset_lab
echo '{"kind":"List","items":[{"kind":"IdentifierPool","metadata":{"name":"fabric01-vlan","namespace":"agentic-netops-allocation","labels":{}}}]}' >"$FAKE/allocation.json"
out="$(scan)"
if grep -qx 'rc=0' <<<"$out" && ! grep -q '^LEFTOVER' <<<"$out"; then
  pass "first-party authority with only platform pools: the scan is clean"
else
  fail "first-party authority with only platform pools: the scan is clean" "$out"
fi

# --- redaction: a device user's password hash in the datastore never reaches the scan's evidence
reset_lab
cat >"$FAKE/gnmic/172.25.25.21.json" <<'JSON'
[{"source":"172.25.25.21","updates":[{"Path":"","values":{"":{"srl_nokia-system:system":{"aaa":{"authentication":{"linuxadmin-user":{"password":"$y$j9T$FAKEHASHFAKEHASH","ssh-key":["ssh-ed25519 AAAAPUBLIC"]}}}}}}}]}]
JSON
out="$(scan)"
ev="$(find "$TMP/evidence" -name '*datastore.leaf01.stdout' 2>/dev/null | head -n 1)"
if grep -qx 'rc=0' <<<"$out" && [[ -n "$ev" ]] && ! grep -q 'FAKEHASH' "$ev" && grep -q '<redacted>' "$ev" \
   && grep -q 'ssh-ed25519 AAAAPUBLIC' "$ev"; then
  pass "a device password hash is redacted from the scan's evidence (public keys kept; FR-079)"
else
  fail "a device password hash is redacted from the scan's evidence (public keys kept; FR-079)" "$out ${ev:-no evidence file}"
fi

# --- an ABSENT lab (T151's clean deploy): every node container gone and no kube context — the
# declared faults of earlier runs under the evidence root name nodes that no longer exist; clean
reset_lab
for n in spine01 spine02 leaf01 leaf02 client01 client02; do : >"$FAKE/absent.clab-agentic-netops-fabric-$n"; done
echo kind-agentflow-005 >"$FAKE/contexts"
out="$(scan "leftovers::declare_fault vt-scratch-tf-mgmt-leaf02 leaf02 'management link set down' \
  '{\"kind\":\"mgmt-link-down\",\"container\":\"clab-agentic-netops-fabric-leaf02\",\"interface\":\"mgmt0\",\"peer\":\"veth1\"}' \
  '{\"kind\":\"host-link-up\"}'")"
if grep -qx 'rc=0' <<<"$out" && ! grep -q '^LEFTOVER' <<<"$out" && grep -q 'node leaf02 of declared fault vt-scratch-tf-mgmt-leaf02 absent' <<<"$out" \
   && grep -q 'cluster (no kube context kind-agentic-netops) absent' <<<"$out" && [[ ! -s "$FAKE/gnmic.calls" ]]; then
  pass "an absent lab (no node container, no kube context) holds no leftover: clean, each absence named, no device read"
else
  fail "an absent lab (no node container, no kube context) holds no leftover: clean, each absence named, no device read" "$out"
fi
# ... and with no device credential at all (no generated Secret exists on such a host)
out="$(SRL_PASS= scan_nocreds)"
if grep -qx 'rc=0' <<<"$out" && ! grep -q 'SRL_PASS is not set' <<<"$out"; then
  pass "an absent lab needs no device credential (no Secret to read it from)"
else
  fail "an absent lab needs no device credential (no Secret to read it from)" "$out"
fi
# negative control: a present device with no credential still fails closed
reset_lab
out="$(scan_nocreds)"
if grep -q 'SRL_PASS is not set' <<<"$out" && ! grep -qx 'rc=0' <<<"$out"; then
  pass "negative control: a present lab with no device credential refuses the scan"
else
  fail "negative control: a present lab with no device credential refuses the scan" "$out"
fi
# negative control: a container that EXISTS but is not running still fails closed
reset_lab
echo 0 >"$FAKE/pid.clab-agentic-netops-fabric-leaf02"
out="$(scan)"
if grep -qx 'rc=1' <<<"$out" && grep -q '^LEFTOVER .*leaf02' <<<"$out"; then
  pass "negative control: a node container that exists but is not running still refuses the start (never treated as absent)"
else
  fail "negative control: a node container that exists but is not running still refuses the start (never treated as absent)" "$out"
fi
# a cluster whose context exists is still scanned (a gate-labelled Config refuses)
reset_lab
printf 'kind-agentflow-005\nkind-agentic-netops\n' >"$FAKE/contexts"
echo '{"items":[{"metadata":{"namespace":"default","name":"x","labels":{"agentic-netops.io/gate-owned":"true"}}}]}' >"$FAKE/configs.json"
out="$(scan)"
if grep -qx 'rc=1' <<<"$out" && grep -q '^LEFTOVER gate-config cluster Config' <<<"$out"; then
  pass "a present kube context is still scanned (a gate-labelled Config refuses the start)"
else
  fail "a present kube context is still scanned (a gate-labelled Config refuses the start)" "$out"
fi

if [[ "$fails" -gt 0 ]]; then echo "leftover_scan_test: $fails FAILED"; exit 1; fi
echo "leftover_scan_test: all passed"
