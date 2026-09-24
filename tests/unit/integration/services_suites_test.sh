#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
# Offline test of the service live suites (T064, T172): no cluster, no lab. Exercises the pure
# helpers of tests/integration/lib/services.sh (condition judgement, manifest parsing, snapshot
# diff), the check runner against a fake kubectl on PATH, every suite's bad-args usage, and that
# each suite records its negative control before the readiness run it admits (NFR-013).
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
IT="$ROOT/tests/integration"
LIB="$IT/lib/services.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
expect() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
refuse() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi; }

# shellcheck source=../../integration/lib/services.sh
source "$LIB"

obj='{"status":{"conditions":[
  {"type":"Ready","status":"False","reason":"RoutesMissing","message":"leaf01 lacks type-3 from 10.0.0.2 for evi 10120"},
  {"type":"Accepted","status":"False","reason":"AllocationConflict","message":"VLAN 1500 lies in the allocation band 1000-4000; the naming band is 100-999"}]}}'
expect "judge: status+reason+substrings match"  bash -c "source '$LIB'; sv::judge_condition Ready False RoutesMissing leaf01 10120 <<<'$obj'"
refuse "judge: wrong status"                    bash -c "source '$LIB'; sv::judge_condition Ready True <<<'$obj'"
refuse "judge: wrong reason"                    bash -c "source '$LIB'; sv::judge_condition Ready False NotConverged <<<'$obj'"
refuse "judge: missing substring"               bash -c "source '$LIB'; sv::judge_condition Ready False RoutesMissing leaf02 <<<'$obj'"
refuse "judge: absent condition"                bash -c "source '$LIB'; sv::judge_condition Degraded True <<<'$obj'"
expect "judge: VLAN half names 1500 and both bands" bash -c "source '$LIB'; sv::judge_condition Accepted False AllocationConflict 1500 100 999 1000 4000 <<<'$obj'"

got="$(sv::manifest_networks "$ROOT/examples/constructs" | sort | tr '\n' ';')"
want="agentic-netops-services lab-acl;agentic-netops-services lab-ipvrf-a;agentic-netops-services lab-ipvrf-b;agentic-netops-services lab-macvrf;agentic-netops-services lab-macvrf-acl;agentic-netops-services lab-vlan;"
[[ "$got" == "$want" ]] && ok "manifest_networks: examples/constructs (non-recursive: negative/ excluded)" || bad "manifest_networks: got '$got'"
got="$(sv::manifest_networks "$ROOT/examples/constructs/negative/vlan-unclaimed-band.yaml")"
[[ "$got" == "agentic-netops-services lab-vlan-unclaimed" ]] && ok "manifest_networks: negative fixture by its own path" || bad "manifest_networks negative: '$got'"

printf 'config/a 3\ncommit/leaf01 1,2,3\n' >"$TMP/b"; printf 'commit/leaf01 1,2,3\nconfig/a 3\n' >"$TMP/same"
printf 'config/a 4\ncommit/leaf01 1,2,3,4\n' >"$TMP/adv"; printf 'config/a 3\n' >"$TMP/gone"
expect "snapshot_diff: identical (order-insensitive)" sv::snapshot_diff "$TMP/b" "$TMP/same"
refuse "snapshot_diff: generation advance + new commit" sv::snapshot_diff "$TMP/b" "$TMP/adv"
refuse "snapshot_diff: a vanished key"                  sv::snapshot_diff "$TMP/b" "$TMP/gone"

# the check runner against a fake kubectl
mkdir -p "$TMP/bin"
cat >"$TMP/bin/kubectl" <<FAKE
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"get networks.fabric.agentic-netops.io lab-vlan -o json"*) printf '%s' '$obj' ;;
  *"get networks.fabric.agentic-netops.io"*) echo 'Error from server (NotFound): networks "x" not found' >&2; exit 1 ;;
  *"get configs.config.sdcio.dev"*"network-name=lab-vlan"*"-o name"*) echo "config.config.sdcio.dev/lab-vlan.leaf01" ;;
  *"get configs.config.sdcio.dev"*"-o name"*) : ;;
  *) echo "fake kubectl: unexpected \$args" >&2; exit 1 ;;
esac
FAKE
chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$PATH" CHECK_WAIT=0
expect "runner: condition PASS"                bash "$LIB" condition agentic-netops-services lab-vlan Ready False RoutesMissing
refuse "runner: condition on an absent Network" bash "$LIB" condition agentic-netops-services vt-absent Ready True
refuse "runner: no_configs with a Config"       bash "$LIB" no_configs agentic-netops-services lab-vlan
expect "runner: no_configs with none"           bash "$LIB" no_configs agentic-netops-services lab-other
out="$(bash "$LIB" condition agentic-netops-services lab-vlan Ready True 2>&1 || true)"
grep -q '^CHECK condition: FAIL' <<<"$out" && ok "runner: verdict line printed" || bad "runner: verdict line missing: $out"
rc=0; bash "$LIB" bogus >/dev/null 2>&1 || rc=$?; [[ "$rc" == 2 ]] && ok "runner: usage on bad check (rc 2)" || bad "runner: bad check rc=$rc"

# every suite: executable, bash -n clean, usage (rc 2) on bad args — before any cluster call
for s in wait_services verify_services idempotence service_delete show_rendered_config provider_claims; do
  f="$IT/$s.sh"
  [[ -x "$f" ]] && bash -n "$f" && ok "$s: executable, bash -n clean" || bad "$s: not executable or bash -n fails"
  rc=0; out="$(bash "$f" --bogus-flag 2>&1)" || rc=$?
  [[ "$rc" == 2 && "$out" == *usage:* ]] && ok "$s: usage on bad args" || bad "$s: bad args rc=$rc out=$(head -c 200 <<<"$out")"
done

# negative control recorded before the readiness run it admits (source order within each suite)
order() { # order <file> <control-pattern> <readiness-pattern>
  local c r; c="$(grep -n -m1 -- "$2" "$1" | cut -d: -f1)"; r="$(grep -n -m1 -- "$3" "$1" | cut -d: -f1)"
  [[ -n "$c" && -n "$r" && "$c" -lt "$r" ]]
}
expect "wait_services: WS-ready control before readiness"  order "$IT/wait_services.sh" "evidence_negative_control WS-ready" "--check WS-ready --readiness"
expect "verify_services: route controls before SC-004:route" order "$IT/verify_services.sh" 'evidence_negative_control "VS-route-' "--records SC-004:route"
expect "verify_services: fault restored from an exit trap"  grep -q "trap vs::on_exit EXIT" "$IT/verify_services.sh"
expect "verify_services: declared before the fault"         order "$IT/verify_services.sh" "leftovers::declare_fault" "vs::set_reflector_clients false"
expect "verify_services: leftovers::scan first"             order "$IT/verify_services.sh" "if ! leftovers::scan" "leftovers::declare_fault"
expect "verify_services: the fault is reflectorClients (AD-77)" grep -qF 'reflectorClients\":${v}' "$IT/verify_services.sh"
expect "idempotence: control before readiness"              order "$IT/idempotence.sh" "evidence_negative_control ID-unchanged" "--check ID-unchanged --readiness"
expect "service_delete: controls before deletion"           order "$IT/service_delete.sh" "evidence_negative_control SD-gone" 'delete "$SV_NET_RES" "$net"'
expect "provider_claims: control before readiness"          order "$IT/provider_claims.sh" "evidence_negative_control PC-claims-bound" "--check PC-claims-bound --readiness"

[[ "$fails" -eq 0 ]] || { echo "services_suites_test: $fails failure(s)"; exit 1; }
echo "services_suites_test: all passed"
