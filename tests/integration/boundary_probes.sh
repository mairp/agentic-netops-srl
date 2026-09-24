#!/usr/bin/env bash
# tests/integration/boundary_probes.sh — the intent tier's denial probe suite (T066, T073, T076;
# FR-075, FR-103, FR-108, SC-028, SC-029, R-34, AD-19, AD-49; contracts/kubernetes-objects.md
# §"Identity contract" — the denial table this suite is written from; quickstart.md §15).
#
# Run by the boundary step of IntentTierReady (scripts/lib/rbac.sh boundary, after the boundary is
# applied and BEFORE any agent workload exists) and behind `make test-boundary`. No agent is
# deployed: every pod here is a BARE probe pod — the pinned python image of versions.lock.yaml
# (firstPartyImages supervisor FROM, by digest), bash and coreutils' timeout, no agent code.
# Every check is run-captured (evidence_run), every readiness check after its FAILING negative
# control (NFR-013); the run is `make verify-evidence` clean (sealed at the end).
#
# Order:
#   0  leftovers::scan (tests/lib/leftovers.sh) FIRST, and this suite's own scratch (vt-scratch-
#      pods in the tier namespaces, its control namespace): a leftover refuses the start (FR-108)
#   1  the boundary is in place (T068–T071 objects read back) and NO agent workload exists
#   2  the port set, READ from the contract's one sentence (bp::ports; never retyped here —
#      tests/unit/boundary/port_list_test.sh diffs it, via --print-ports, against the contract and
#      quickstart §15), reconciled against G2's observed non-loopback listeners
#      (tests/gate/observed/mgmt-ports.json network_listeners): a listening port the list does not
#      carry FAILS (R-34). Negative control: the same reconciliation over a copy carrying one extra
#      non-loopback listener must fail
#   3  the EXACT allow-list of FR-075 answers `yes` — deployer: get, list, watch, create, update,
#      patch, delete on networks.fabric.agentic-netops.io and create on events in
#      agentic-netops-intent; allocator: get, list, watch, create, delete on the claim resources the
#      lock file's authority serves (first-party: identifierclaims in agentic-netops-allocation;
#      kuid: vlanclaims + genidclaims in kuid-system, T182). Negative control: the same question
#      as a tier ServiceAccount with no binding (intent-mapper) must answer no
#   4  `kubectl auth can-i --list` for both identities in EVERY namespace shows nothing else (the
#      default rules every authenticated service account holds are filtered — bp::_default_rule,
#      explained there). Negative control: the same comparison for the cluster admin must fail
#   5  every forbidden verb/resource of the denial table answers `no` as each identity (bp::denials).
#      Negative control per check: the same question as the cluster admin answers yes
#   6  the force-release admission probe (FR-103, CD-02): a server-side dry-run CREATE of a scratch
#      Network in agentic-netops-intent that sets fabric.agentic-netops.io/force-release is refused
#      by the ValidatingAdmissionPolicy deny-tier-force-release as intent-deployer; the same object is
#      accepted as the cluster admin (the negative control), and without the annotation as the
#      deployer (the refusal is the annotation's, not RBAC's). Nothing is persisted
#   7  bare pods: vt-scratch-tier-dial (tier-labelled, no token), vt-scratch-tier-deployer and
#      vt-scratch-tier-allocator (tier-labelled, holding each identity's token) in
#      agentic-netops-agents, and vt-scratch-ctl-dial in the unrestricted, gate-labelled control
#      namespace vt-scratch-boundary-ctl. Each identity pod makes one REAL API request with its
#      mounted token (list Secrets → 403); negative control: a request its Role allows (→ 200)
#   8  SC-028's per-source counter (tests/integration/lib/tier_egress_counter.sh) installed — the
#      node's packet-filter front end observed and recorded — and zeroed; its negative control
#      (no tier dial yet: the counter has not moved) recorded
#   9  every TCP dial from vt-scratch-tier-dial to .11/.12/.21/.22 on EVERY contract port times out
#      (a connection neither completed nor refused within BP_DIAL_TIMEOUT); the positive control of
#      each — recorded first as its negative control — is the same dial from the unrestricted pod,
#      which completes (connected or refused). The two identity pods (whose extra policy opens the
#      API server) dial every device's gNMI port too. And the in-cluster paths: every TCP endpoint of
#      the device-configuration layer and the platform's controllers (BP_CLUSTER_NS) times out from
#      the tier pod, each paired with the control pod's completed dial (endpoints that answer no one
#      are recorded as not attemptable); the cluster DNS stays reachable. Node-local destinations
#      (the API server on kind, the node's own management address) are RECORDED: the pinned policy
#      engine does not filter a node's input path (live-findings 2026-09-24-tier-egress-cluster-paths)
#  10  the counter MUST have moved (its positive control: T066's dials from a tier-labelled pod)
#  11  the UDP row: a datagram to 161 on every device from each tier pod is RECORDED, not asserted —
#      no reply is indistinguishable from a silent server — and the counter's udp count, zeroed
#      before and shown not moved first, MUST have moved: the assertion behind the UDP row
#  12  counter removed and read back; scratch pods and the control namespace deleted and read back
#      (also from the exit trap); every artefact sealed into one record
#
# Usage: boundary_probes.sh [run]            the suite (default)
#        boundary_probes.sh --print-ports    the port set the suite dials, "<proto> <port>" per line
#        boundary_probes.sh reconcile <mgmt-ports.json>   step 2 alone (exit 1 names the port)
#        boundary_probes.sh expect <no|yes|timeout|http <code>|admission-denied|accepted|list <json>> -- <cmd…>
#                                            the judged command of one check (what evidence_run runs)
# Environment (beyond tests/lib/lab.sh and suite.sh): BP_CONTRACT (the contract file),
#   BP_OBSERVED (tests/gate/observed/mgmt-ports.json), BP_DIAL_TIMEOUT (5 s), BP_POD_TIMEOUT (180 s),
#   TIER_NS (agentic-netops-agents), INTENT_NS (agentic-netops-intent), BP_CTL_NS
#   (vt-scratch-boundary-ctl). SRL_USER/SRL_PASS are read from agentic-netops-system/srl-credentials
#   when unset (the leftover scan reads the devices; they never reach argv).
# Exit: 0 every denial observed; 1 a denial not observed / check failed; 3 refused (leftovers).
set -euo pipefail

BP_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BP_ROOT="$(cd -- "$BP_HERE/../.." && pwd)"
BP_SELF="$BP_HERE/boundary_probes.sh"
: "${BP_CONTRACT:=$BP_ROOT/specs/004-agentic-netops-composite/contracts/kubernetes-objects.md}"
: "${BP_OBSERVED:=$BP_ROOT/tests/gate/observed/mgmt-ports.json}"
: "${BP_DIAL_TIMEOUT:=5}"
: "${BP_POD_TIMEOUT:=180}"
: "${TIER_NS:=agentic-netops-agents}"
: "${INTENT_NS:=agentic-netops-intent}"
: "${BP_CTL_NS:=vt-scratch-boundary-ctl}"
BP_SA_PREFIX="system:serviceaccount:${TIER_NS}"
BP_DEPLOYER="${BP_SA_PREFIX}:intent-deployer"
BP_ALLOCATOR="${BP_SA_PREFIX}:intent-allocator"
BP_UNBOUND="${BP_SA_PREFIX}:intent-mapper"      # a tier identity with no binding at all
BP_NET_RES="networks.fabric.agentic-netops.io"
BP_FR_ANNOTATION="fabric.agentic-netops.io/force-release"
BP_VAP="deny-tier-force-release"
BP_TIER_LABEL="agentic-netops.io/tier"

# ============================================================== pure logic (unit-tested offline)

# bp::ports [contract] — the TCP and UDP port sets of the contract's one sentence ("the lab image
# exposes **TCP 22, 80, …, and UDP 161**"), "<proto> <port>" per line, TCP first, contract order.
# Fails (naming the file) unless the sentence is found exactly once and both sets are non-empty.
bp::ports() {
  local f="${1:-$BP_CONTRACT}"
  [[ -f "$f" ]] || { echo "boundary_probes: the contract ${f} is not readable — the port set is read from it, never retyped" >&2; return 1; }
  python3 - "$f" <<'PY'
import re, sys
text = re.sub(r"\s+", " ", open(sys.argv[1], encoding="utf-8").read())
hits = re.findall(r"exposes \*\*TCP ([0-9][0-9, and]*?), and UDP ([0-9][0-9, and]*?)\*\*", text)
if len(hits) != 1:
    sys.exit(f"boundary_probes: {sys.argv[1]}: the port sentence ('exposes **TCP …, and UDP …**') was found {len(hits)} times, not once")
tcp = re.findall(r"[0-9]+", hits[0][0]); udp = re.findall(r"[0-9]+", hits[0][1])
if not tcp or not udp:
    sys.exit(f"boundary_probes: {sys.argv[1]}: empty TCP or UDP set in the port sentence")
for p in tcp: print("tcp", int(p))
for p in udp: print("udp", int(p))
PY
}

# bp::reconcile <mgmt-ports.json> [contract] — every listener G2 observed NOT bound to loopback must
# be in the contract's set; prints the verdict per listener; exit 1 naming each uncovered port.
bp::reconcile() {
  local obs="${1:?bp::reconcile <mgmt-ports.json>}" ports
  ports="$(bp::ports "${2:-$BP_CONTRACT}")" || return 1
  [[ -f "$obs" ]] || { echo "RECONCILE FAIL: G2's observation ${obs} is not readable" >&2; return 1; }
  jq -r --arg ports "$ports" '
    ($ports | split("\n") | map(select(length > 0) | split(" ") | {transport: .[0], port: (.[1] | tonumber)})) as $list
    | if (.network_listeners | type) != "array" then
        "RECONCILE FAIL: the observation carries no network_listeners (G2 predates bind-scope recording; re-run G2)"
      elif ((.listeners_unavailable // []) | length) > 0 then
        "RECONCILE FAIL: G2 could not list the sockets of: \(.listeners_unavailable | join(", "))"
      else
        (.network_listeners[] | . as $l
          | if any($list[]; .transport == $l.transport and .port == $l.port)
            then "COVERED \($l.transport)/\($l.port) listening on \($l.addresses | join(",")) — in the contract list"
            else "UNCOVERED \($l.transport)/\($l.port) listening on \($l.addresses | join(",")) — NOT in the contract list" end),
        ((.loopback_listeners // [])[] | "LOOPBACK-ONLY \(.transport)/\(.port) bound to \(.addresses | join(",")) — recorded, unreachable from the network"),
        (. as $o | $list[] | select(. as $p | ($o.network_listeners | any(.transport == $p.transport and .port == $p.port)) | not)
          | "DOCUMENTED-NOT-LISTENING \(.transport)/\(.port) — still probed")
      end' "$obs" | tee /dev/stderr | { ! grep -qE '^(UNCOVERED|RECONCILE FAIL)'; }
}

# bp::parse_list — `kubectl auth can-i --list` table on stdin → a JSON array of
# {resource, nonResourceURLs, resourceNames, verbs}, columns cut at the header's offsets.
bp::parse_list() {
  python3 -c '
import json, sys
lines = [l.rstrip("\n") for l in sys.stdin if l.strip()]
if not lines or not lines[0].startswith("Resources"):
    sys.exit("boundary_probes: not a can-i --list table (no header)")
h = lines[0]
c1, c2, c3 = h.index("Non-Resource URLs"), h.index("Resource Names"), h.index("Verbs")
def lst(s):
    s = s.strip()
    if s.startswith("[") and s.endswith("]"):
        s = s[1:-1]
    return [x for x in s.split() if x]
out = []
for l in lines[1:]:
    l = l.ljust(c3)
    out.append({"resource": l[:c1].strip(), "nonResourceURLs": lst(l[c1:c2]),
                "resourceNames": lst(l[c2:c3]), "verbs": sorted(lst(l[c3:]))})
print(json.dumps(out))'
}

# The rules every authenticated service account holds, whatever its bindings — the only rows
# bp::expect_list removes before comparing (the filter, stated once):
#   * create on selfsubjectaccessreviews / selfsubjectrulesreviews (authorization.k8s.io) and
#     selfsubjectreviews (authentication.k8s.io) — system:basic-user: the identity asking what it
#     may do, which is how this very probe works;
#   * get on the non-resource URLs of system:discovery, system:public-info-viewer and
#     system:service-account-issuer-discovery — /api, /apis (and /*), /healthz, /livez, /readyz,
#     /version, /openapi (and /*), /.well-known/openid-configuration, /openid/v1/jwks (with or
#     without the trailing slash): discovery, health and the token issuer's public keys; no object.
# Anything else — including a rule some namespace grants to every service account — is NOT
# filtered and fails the comparison. The filter is a fixed list, never a diff against another
# identity, precisely so that such a group-wide grant cannot hide.
BP_DEFAULT_RESOURCES='["selfsubjectaccessreviews.authorization.k8s.io","selfsubjectrulesreviews.authorization.k8s.io","selfsubjectreviews.authentication.k8s.io"]'
BP_DEFAULT_URLS='["/api","/api/*","/apis","/apis/*","/healthz","/livez","/readyz","/version","/version/","/openapi","/openapi/*","/.well-known/openid-configuration","/.well-known/openid-configuration/","/openid/v1/jwks","/openid/v1/jwks/"]'

# bp::compare_list <expected-json> — parsed rows (bp::parse_list) on stdin; expected is
# {"<resource>": [verbs…]} (core resources without a group suffix, e.g. "events"). Prints the
# default rows it removed, then OK / UNEXPECTED / MISSING lines; exit 1 on any difference.
bp::compare_list() {
  jq -r --argjson want "$1" --argjson dres "$BP_DEFAULT_RESOURCES" --argjson durl "$BP_DEFAULT_URLS" '
    def default_rule:
      (.resource as $r | ($dres | index($r)) != null and .verbs == ["create"] and (.resourceNames | length) == 0
                          and (.nonResourceURLs | length) == 0)
      or (.resource == "" and .verbs == ["get"] and (.nonResourceURLs | length) > 0
          and all(.nonResourceURLs[]; . as $u | ($durl | index($u)) != null));
    [.[] | select(default_rule)] as $defaults
    | [.[] | select(default_rule | not)] as $rest
    | ($rest | map(select(.resource != "")) | group_by(.resource)
        | map({key: .[0].resource, value: ([.[].verbs[]] | unique)}) | from_entries) as $got
    | ($rest | map(select(.resource == "" or (.resourceNames | length) > 0))) as $odd
    | ($want | map_values(sort)) as $w
    | "FILTERED \($defaults | length) default rule(s) every authenticated service account holds",
      ($got | to_entries[] | . as $e
        | if $w[$e.key] == null then "UNEXPECTED \($e.key) \($e.value | join(","))"
          elif $w[$e.key] != $e.value then "UNEXPECTED \($e.key) \($e.value | join(",")) (want exactly \($w[$e.key] | join(",")))"
          else "OK \($e.key) \($e.value | join(","))" end),
      ($w | to_entries[] | select($got[.key] == null) | "MISSING \(.key) \(.value | join(","))"),
      ($odd[] | "UNEXPECTED rule \(tojson)")' | tee /dev/stderr | { ! grep -qE '^(UNEXPECTED|MISSING)'; }
}

# bp::expect <mode> [arg] -- <cmd…> — the judged command of one check. The command's own output is
# passed through; the verdict is the exit status:
#   no | yes          the command's last stdout line is exactly that (kubectl auth can-i)
#   timeout           the command exited 124 (coreutils timeout: the dial neither completed nor
#                     was refused within the bound)
#   http <code>       the last stdout line is that HTTP status
#   admission-denied  non-zero, and the refusal names the ValidatingAdmissionPolicy deny-tier-force-release
#   accepted          exit 0
#   list <json>       the output, parsed and default-filtered, equals the expected rules exactly
bp::expect() {
  local mode="${1:?mode}" arg="" out rc=0 last
  shift
  case "$mode" in http|list) arg="${1:?$mode needs an argument}"; shift ;; esac
  [[ "${1:-}" == -- ]] && shift
  [[ $# -gt 0 ]] || { echo "bp::expect: no command" >&2; return 2; }
  case "$mode" in
    no|yes|http)
      out="$("$@")" || rc=$?
      printf '%s\n' "$out"
      last="$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -n 1)"
      echo "EXPECT ${mode}${arg:+ $arg}: got '${last}' (exit ${rc})"
      if [[ "$mode" == http ]]; then [[ "$last" == "$arg" ]]; else [[ "$last" == "$mode" ]]; fi ;;
    timeout)
      "$@" || rc=$?
      echo "EXPECT timeout (124): exit ${rc}$( [[ $rc -eq 124 ]] && echo ' — timed out' || echo ' — completed or refused, NOT a timeout')"
      [[ "$rc" -eq 124 ]] ;;
    admission-denied)
      out="$("$@" 2>&1)" || rc=$?
      printf '%s\n' "$out"
      echo "EXPECT admission-denied by ${BP_VAP}: exit ${rc}"
      [[ "$rc" -ne 0 ]] && grep -q "ValidatingAdmissionPolicy '${BP_VAP}'" <<<"$out" && grep -q "denied request" <<<"$out" ;;
    accepted)
      "$@" || rc=$?
      echo "EXPECT accepted: exit ${rc}"
      [[ "$rc" -eq 0 ]] ;;
    list)
      out="$("$@")" || rc=$?
      printf '%s\n' "$out"
      [[ "$rc" -eq 0 ]] || { echo "EXPECT list: the listing failed (exit ${rc})"; return 1; }
      bp::parse_list <<<"$out" | bp::compare_list "$arg" ;;
    *) echo "bp::expect: unknown mode ${mode}" >&2; return 2 ;;
  esac
}

# bp::cid <text…> — a valid evidence/check id from free text
bp::cid() { local s="$*"; s="${s//[^A-Za-z0-9._-]/_}"; printf '%s' "$s"; }

# bp::claim_resources <authority> — "<resource> <namespace>" of the tier's claim resources
bp::claim_resources() {
  case "$1" in
    first-party) echo "identifierclaims.fabric.agentic-netops.io agentic-netops-allocation" ;;
    kuid) echo "vlanclaims.vlan.be.kuid.dev kuid-system"; echo "genidclaims.genid.be.kuid.dev kuid-system" ;;
    *) echo "boundary_probes: unknown authority '$1'" >&2; return 1 ;;
  esac
}

# bp::expected_rules <deployer|allocator> <namespace> <authority> — the exact rule set (JSON)
bp::expected_rules() {
  local who="$1" ns="$2" auth="$3" r n j="{}"
  case "$who" in
    deployer)
      [[ "$ns" == "$INTENT_NS" ]] && j="$(jq -cn --arg n "$BP_NET_RES" '{($n): ["get","list","watch","create","update","patch","delete"], "events": ["create"]}')" ;;
    allocator)
      while read -r r n; do
        [[ "$ns" == "$n" ]] && j="$(jq -c --arg r "$r" '. + {($r): ["get","list","watch","create","delete"]}' <<<"$j")"
      done < <(bp::claim_resources "$auth") ;;
  esac
  printf '%s' "$j"
}

# bp::denials <authority> — the denial table, one attempt per line: "<who>|<verb>|<resource>|<scope>"
# (who: deployer | allocator | both; scope: "-A" or "-n <namespace>"). Written from
# contracts/kubernetes-objects.md §"Identity contract" — its list of what is deliberately absent
# and its table of attempts.
bp::denials() {
  local auth="$1" v ns r
  # Secrets in any namespace, and operator-credentials by name
  echo "both|get|secrets|-A"
  echo "both|list|secrets|-A"
  for ns in "$TIER_NS" "$INTENT_NS" agentic-netops-system sdc-system monitoring; do echo "both|get|secrets|-n $ns"; done
  echo "both|get|secrets/operator-credentials|-n $TIER_NS"
  echo "both|get|secrets/srl-credentials|-n agentic-netops-system"
  # ConfigMaps, the mounted ones through the API included
  echo "both|get|configmaps|-A"
  echo "both|list|configmaps|-n $TIER_NS"
  echo "both|get|configmaps/site-inventory|-n $TIER_NS"
  echo "both|get|configmaps/fabric-qualification|-n $TIER_NS"
  echo "both|get|configmaps/fabric-qualification|-n agentic-netops-system"
  # Pods, pods/exec, Nodes
  echo "both|create|pods/exec|-A"
  echo "both|create|pods/exec|-n $TIER_NS"
  echo "both|get|pods|-n $TIER_NS"
  echo "both|create|pods|-n $TIER_NS"
  echo "both|get|nodes|-A"
  # the fabric design object
  for v in get list create update; do echo "both|$v|fabrics.fabric.agentic-netops.io|-A"; done
  # the device-configuration groups (Target is config.sdcio.dev at v0.0.58; inv.sdcio.dev probed too)
  for r in configs.config.sdcio.dev configsets.config.sdcio.dev; do echo "both|create|$r|-A"; echo "both|update|$r|-n agentic-netops-system"; done
  echo "both|get|targets.config.sdcio.dev|-A"
  echo "both|get|targets.inv.sdcio.dev|-A"
  echo "both|get|schemas.inv.sdcio.dev|-A"
  echo "both|create|discoveryrules.inv.sdcio.dev|-A"
  echo "both|get|targetconnectionprofiles.inv.sdcio.dev|-A"
  # the Fabric reconciler's groups and the allocation indices themselves
  echo "both|create|ipclaims.ipam.be.kuid.dev|-A"
  echo "both|create|asclaims.as.be.kuid.dev|-A"
  echo "both|get|ipindices.ipam.be.kuid.dev|-A"
  echo "both|get|asindices.as.be.kuid.dev|-A"
  echo "both|get|vlanindices.vlan.be.kuid.dev|-A"
  echo "both|get|genidindices.genid.be.kuid.dev|-A"
  for v in get create update delete; do echo "both|$v|identifierpools.fabric.agentic-netops.io|-n agentic-netops-allocation"; done
  # update / patch on claims — whichever authority is selected, both identities
  while read -r r ns; do
    for v in update patch; do echo "both|$v|$r|-n $ns"; done
  done < <(bp::claim_resources "$auth")
  for v in update patch; do
    echo "both|$v|identifierclaims.fabric.agentic-netops.io|-n agentic-netops-allocation"
    echo "both|$v|vlanclaims.vlan.be.kuid.dev|-n kuid-system"
    echo "both|$v|genidclaims.genid.be.kuid.dev|-n kuid-system"
  done
  # the deployer holds no claim verb at all; the allocator none outside its namespace
  echo "deployer|create|identifierclaims.fabric.agentic-netops.io|-n agentic-netops-allocation"
  echo "deployer|get|identifierclaims.fabric.agentic-netops.io|-A"
  echo "deployer|create|vlanclaims.vlan.be.kuid.dev|-n kuid-system"
  echo "allocator|create|identifierclaims.fabric.agentic-netops.io|-n $INTENT_NS"
  echo "allocator|list|identifierclaims.fabric.agentic-netops.io|-A"
  # a Network outside the intent namespace (deployer), and anywhere at all (allocator)
  for ns in agentic-netops-system agentic-netops-services default; do
    for v in get list create update patch delete; do echo "deployer|$v|$BP_NET_RES|-n $ns"; done
  done
  echo "deployer|list|$BP_NET_RES|-A"
  for ns in "$INTENT_NS" agentic-netops-system agentic-netops-services; do
    for v in get list watch create update patch delete; do echo "allocator|$v|$BP_NET_RES|-n $ns"; done
  done
  echo "allocator|list|$BP_NET_RES|-A"
  # every resource in agentic-netops-system, and no path to more permission
  echo "both|get|deployments|-n agentic-netops-system"
  echo "both|update|deployments|-n agentic-netops-system"
  echo "both|create|rolebindings|-n $INTENT_NS"
  echo "both|create|roles|-n $INTENT_NS"
  echo "both|create|serviceaccounts/token|-n $TIER_NS"
  echo "both|impersonate|serviceaccounts|-A"
  echo "both|update|validatingadmissionpolicies|-A"
  echo "both|delete|validatingadmissionpolicybindings|-A"
  echo "both|delete|networkpolicies|-n $TIER_NS"
  # events anywhere but the intent namespace
  echo "deployer|create|events|-n agentic-netops-system"
  echo "allocator|create|events|-n $INTENT_NS"
}

# ============================================================== the live suite

bp::k() { "${KUBECTL:-kubectl}" --context "${KUBE_CONTEXT:-kind-${CLUSTER_NAME}}" "$@"; }
BP_K=()

bp::who() { case "$1" in deployer) printf '%s' "$BP_DEPLOYER" ;; allocator) printf '%s' "$BP_ALLOCATOR" ;; esac; }

# bp::pair <check> <neg-cmd…> ::: <cmd…> — the negative control (must fail) then the readiness run
bp::pair() {
  local check="$1" id rc=0; shift
  local -a neg=() run=() records=()
  while [[ $# -gt 0 && "$1" != ::: ]]; do neg+=("$1"); shift; done
  shift
  while [[ "${1:-}" == --records ]]; do records+=(--records "$2"); shift 2; done
  run=("$@")
  evidence_negative_control "$check" -- "${neg[@]}" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    suite::fail "${check}: its negative control $( [[ $rc -eq 4 ]] && echo PASSED — the check is defective || echo "could not be recorded (rc=$rc)")"
    return 1
  fi
  id="$(gate::id "$check")"
  if evidence_run "$id" --check "$check" --readiness "${records[@]}" -- "${run[@]}" >/dev/null 2>&1; then
    BP_PASSED=$((BP_PASSED + 1)); return 0
  fi
  suite::fail "${check}: NOT observed (evidence ${id}.json)"
  return 1
}

bp::scratch_scan() {
  local found
  found="$(
    bp::k get pods -n "$TIER_NS" -o name 2>/dev/null | grep "/${LAB_SCRATCH_PREFIX}" || true
    bp::k get namespace "$BP_CTL_NS" -o name 2>/dev/null || true
    bp::k get "$BP_NET_RES" -n "$INTENT_NS" -o name 2>/dev/null | grep "/${LAB_SCRATCH_PREFIX}" || true
  )"
  if [[ -n "$found" ]]; then
    printf 'LEFTOVER boundary-scratch %s\n' $found
    return 1
  fi
}

bp::image() {
  python3 - "$BP_ROOT/versions.lock.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
img = next(i for i in d["firstPartyImages"] if i["name"] == "supervisor")["from"][0]
ref = img["ref"] if "/" in img["ref"] else "docker.io/library/" + img["ref"]
print(f'{ref}:{img["tag"]}@{img["digest"]}')
PY
}

bp::manifests() {
  local img="$1" d="$EVIDENCE_DIR/boundary/manifests"
  mkdir -p "$d"
  local common="  automountServiceAccountToken: AUTOMOUNT
  restartPolicy: Never
  activeDeadlineSeconds: 1800
  terminationGracePeriodSeconds: 0
  containers:
  - name: probe
    image: ${img}
    imagePullPolicy: IfNotPresent
    command: [sleep, \"1800\"]"
  {
    cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: vt-scratch-tier-dial
  namespace: ${TIER_NS}
  labels: {${BP_TIER_LABEL}: intent, ${LAB_GATE_LABEL_KEY}: "true", app.kubernetes.io/name: vt-scratch-boundary-probe}
spec:
${common//AUTOMOUNT/false}
---
YAML
    local who
    for who in deployer allocator; do
      cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: vt-scratch-tier-${who}
  namespace: ${TIER_NS}
  labels: {${BP_TIER_LABEL}: intent, agentic-netops.io/identity: intent-${who}, ${LAB_GATE_LABEL_KEY}: "true", app.kubernetes.io/name: vt-scratch-boundary-probe}
spec:
  serviceAccountName: intent-${who}
${common//AUTOMOUNT/true}
---
YAML
    done
  } >"$d/tier-pods.yaml"
  cat >"$d/control.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${BP_CTL_NS}
  labels: {${LAB_GATE_LABEL_KEY}: "true", agentic-netops.io/owned-by: "${CLUSTER_NAME}"}
---
apiVersion: v1
kind: Pod
metadata:
  name: vt-scratch-ctl-dial
  namespace: ${BP_CTL_NS}
  labels: {${LAB_GATE_LABEL_KEY}: "true", app.kubernetes.io/name: vt-scratch-boundary-probe}
spec:
${common//AUTOMOUNT/false}
YAML
  cat >"$d/force-release-network.yaml" <<YAML
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
metadata:
  name: vt-scratch-force-release
  namespace: ${INTENT_NS}
  annotations:
    ${BP_FR_ANNOTATION}: "vt-scratch boundary probe (server-side dry-run only)"
spec:
  description: vt-scratch boundary probe, server-side dry-run only and never persisted
  vlans:
  - name: v998
    vlan: 998
  attachments:
  - {node: leaf02, attachment: ethernet-1/1, vlan: 998}
YAML
  yq 'del(.metadata.annotations)' "$d/force-release-network.yaml" >"$d/force-release-network-no-annotation.yaml"
}

# the python snippet an identity pod runs: one API request with its mounted token (never printed)
BP_API_PY='import os, ssl, sys, urllib.error, urllib.request
d = "/var/run/secrets/kubernetes.io/serviceaccount/"
ctx = ssl.create_default_context(cafile=d + "ca.crt")
url = "https://%s:%s%s" % (os.environ["KUBERNETES_SERVICE_HOST"], os.environ["KUBERNETES_SERVICE_PORT"], sys.argv[1])
req = urllib.request.Request(url, headers={"Authorization": "Bearer " + open(d + "token").read().strip()})
try:
    print(urllib.request.urlopen(req, context=ctx, timeout=10).status)
except urllib.error.HTTPError as e:
    print(e.code)'

bp::cleanup() {
  [[ "${BP_SCRATCH_UP:-0}" == 1 ]] || return 0
  local rc=0 i
  if [[ "${BP_COUNTER_UP:-0}" == 1 ]]; then
    gate::run BP.counter.remove -- bash "$BP_HERE/lib/tier_egress_counter.sh" remove >/dev/null 2>&1 || rc=1
    BP_COUNTER_UP=0
  fi
  bp::k delete pod -n "$TIER_NS" vt-scratch-tier-dial vt-scratch-tier-deployer vt-scratch-tier-allocator \
    --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || rc=1
  bp::k delete namespace "$BP_CTL_NS" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || rc=1
  for i in $(seq 1 60); do
    bp::scratch_scan >/dev/null 2>&1 && break
    sleep 3
  done
  gate::run BP.scratch-removed -- bash -c "$(printf '%q ' "${BP_K[@]}") get pods -n ${TIER_NS} -o name | { ! grep '/${LAB_SCRATCH_PREFIX}'; } && ! $(printf '%q ' "${BP_K[@]}") get namespace ${BP_CTL_NS} -o name 2>/dev/null" \
    >/dev/null 2>&1 || { rc=1; log::error "the boundary probe's scratch pods / control namespace were NOT read back removed"; }
  [[ "$rc" -eq 0 ]] && log::info "scratch pods and ${BP_CTL_NS} removed and read back"
  BP_SCRATCH_UP=0
  return "$rc"
}

# bp::seal — one final record hashing every artefact of this suite that no record references yet
bp::seal() {
  local -a att=()
  local f
  while read -r f; do [[ -n "$f" ]] && att+=(--attach "$f"); done < <(python3 - "$EVIDENCE_DIR" <<'PY'
import json, os, sys
d = sys.argv[1]; ref, files = set(), set()
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
    if isinstance(r, dict) and r.get("schema") == "agentic-netops.evidence/v1":
        ref.add(f)
        for k in ("stdout", "stderr"):
            v = (r.get("raw_output") or {}).get(k) or {}
            if v.get("file"):
                ref.add(os.path.join(os.path.dirname(f), v["file"]))
        for a in r.get("attachments") or []:
            ref.add(a.get("file"))
for f in sorted(files - ref):
    if f.startswith("boundary/"):
        print(f)
PY
)
  [[ ${#att[@]} -gt 0 ]] || return 0
  gate::run BP.seal "${att[@]}" -- ls -1 "$EVIDENCE_DIR/boundary" >/dev/null 2>&1 || true
}

bp::run() {
  # shellcheck source=lib/suite.sh
  source "$BP_HERE/lib/suite.sh"
  # shellcheck source=../../scripts/lib/gate.sh
  source "$BP_ROOT/scripts/lib/gate.sh"       # gate::authority_kind — the lock file's authority
  : "${KUBE_CONTEXT:=kind-${CLUSTER_NAME}}"
  BP_K=("${KUBECTL:-kubectl}" --context "$KUBE_CONTEXT")
  if [[ -z "${SRL_PASS:-}" ]]; then
    SRL_USER="$(bp::k -n agentic-netops-system get secret srl-credentials -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)" || SRL_USER=""
    SRL_PASS="$(bp::k -n agentic-netops-system get secret srl-credentials -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)" || SRL_PASS=""
    export SRL_USER SRL_PASS
  fi
  suite::init BOUNDARY || exit 3
  mkdir -p "$EVIDENCE_DIR/boundary"
  BP_PASSED=0; BP_SCRATCH_UP=0; BP_COUNTER_UP=0
  suite::on_exit bp::cleanup
  log::phase IntentTierReady
  log::info "boundary probes: evidence in ${EVIDENCE_DIR}"

  # ---- 0. leftovers first
  suite::refuse_on_leftovers "boundary_probes.sh" || exit 3
  if ! gate::run BP.scratch-scan -- bash "$BP_SELF" scratch-scan; then
    log::error "boundary_probes.sh REFUSED to start: its own scratch of an earlier run is present (listed above); remove it explicitly"
    exit 3
  fi

  local authority
  authority="$(gate::authority_kind)" || exit 1
  log::info "allocation authority (lock file): $(gate::authority_display "$authority") — the allocator's allow-list and denial table follow it (T182)"

  # ---- 1. the boundary is in place; no agent workload
  gate::run BP.boundary-objects -- "${BP_K[@]}" get namespace/"$TIER_NS" namespace/"$INTENT_NS" \
    -o custom-columns=NAME:.metadata.name,OWNED:.metadata.labels.agentic-netops\\.io/owned-by,TIER:.metadata.labels.agentic-netops\\.io/tier >/dev/null 2>&1 \
    || suite::fail "the tier namespaces are absent: apply the boundary first (scripts/lib/rbac.sh apply)"
  gate::run BP.boundary-rbac -- "${BP_K[@]}" get serviceaccounts,roles,rolebindings,networkpolicies -n "$TIER_NS" -o wide >/dev/null 2>&1 || true
  gate::run BP.boundary-intent-rbac -- "${BP_K[@]}" get roles,rolebindings -n "$INTENT_NS" -o yaml >/dev/null 2>&1 || true
  gate::run BP.boundary-policies -- "${BP_K[@]}" get networkpolicies -n "$TIER_NS" -o yaml >/dev/null 2>&1 \
    || suite::fail "the tier's NetworkPolicies cannot be read"
  local have
  have="$(bp::k get networkpolicies -n "$TIER_NS" -o json | jq -r '[.items[].metadata.name] | sort | join(" ")')" || have=""
  [[ "$have" == "allow-egress-scoped apiserver-egress-cluster-clients deny-all-by-default slim-ingress" ]] \
    || suite::fail "the tier's NetworkPolicies are [${have}], not exactly the four of T070"
  gate::run BP.policy-drops-mgmt-cidr -- bash -c "$(printf '%q ' "${BP_K[@]}") get networkpolicy allow-egress-scoped -n ${TIER_NS} -o json | jq -e --arg c '${MGMT_CIDR}' '[.spec.egress[] | select(any(.to[]?; .ipBlock))] as \$ip | (\$ip | length) == 1 and (\$ip[0].ports == null) and (\$ip[0].to | length) == 1 and \$ip[0].to[0].ipBlock.cidr == \"0.0.0.0/0\" and (\$ip[0].to[0].ipBlock.except | index(\$c) != null)'" >/dev/null 2>&1 \
    || suite::fail "allow-egress-scoped does not drop the whole management CIDR ${MGMT_CIDR} on every port (one ipBlock rule, no port list)"
  gate::run BP.admission-policy -- "${BP_K[@]}" get validatingadmissionpolicy,validatingadmissionpolicybinding "$BP_VAP" -o yaml >/dev/null 2>&1 \
    || suite::fail "the ValidatingAdmissionPolicy ${BP_VAP} or its binding is absent"
  gate::run BP.no-agent-workload -- bash -c "out=\$($(printf '%q ' "${BP_K[@]}") get deployments,statefulsets,daemonsets,replicasets -n ${TIER_NS} -o name) && echo \"workloads: [\${out}]\" && [ -z \"\${out}\" ]" >/dev/null 2>&1 \
    || suite::fail "an agent workload already exists in ${TIER_NS}: the boundary is proven BEFORE any agent is deployed"

  # ---- 2. the port set, from the contract; reconciled against G2
  local -a PORTS=()
  mapfile -t PORTS < <(bp::ports) || true
  if [[ ${#PORTS[@]} -eq 0 ]]; then suite::fail "no port set could be read from ${BP_CONTRACT}"; suite::finish "boundary probes"; exit 1; fi
  printf '%s\n' "${PORTS[@]}" >"$EVIDENCE_DIR/boundary/port-set.txt"
  cp "$BP_OBSERVED" "$EVIDENCE_DIR/boundary/mgmt-ports.observed.json"
  jq '.network_listeners += [{transport: "tcp", port: 23, addresses: ["0.0.0.0"]}]' "$BP_OBSERVED" >"$EVIDENCE_DIR/boundary/mgmt-ports.mutated-extra-listener.json"
  bp::pair BP-reconcile-g2 bash "$BP_SELF" reconcile "$EVIDENCE_DIR/boundary/mgmt-ports.mutated-extra-listener.json" \
    ::: --records SC-029:reconciliation bash "$BP_SELF" reconcile "$EVIDENCE_DIR/boundary/mgmt-ports.observed.json" || true
  log::info "port set (contract): $(printf '%s ' "${PORTS[@]}" | sed 's/tcp /tcp\//g; s/udp /udp\//g')"

  # ---- 3. the exact allow-list answers yes
  local v r ns who sa
  for v in get list watch create update patch delete; do
    bp::pair "$(bp::cid BP.allow.deployer "$v" "$BP_NET_RES" "$INTENT_NS")" \
      bash "$BP_SELF" expect yes -- "${BP_K[@]}" auth can-i "$v" "$BP_NET_RES" -n "$INTENT_NS" --as="$BP_UNBOUND" \
      ::: --records SC-029:allow-list bash "$BP_SELF" expect yes -- "${BP_K[@]}" auth can-i "$v" "$BP_NET_RES" -n "$INTENT_NS" --as="$BP_DEPLOYER" || true
  done
  bp::pair "$(bp::cid BP.allow.deployer create events "$INTENT_NS")" \
    bash "$BP_SELF" expect yes -- "${BP_K[@]}" auth can-i create events -n "$INTENT_NS" --as="$BP_UNBOUND" \
    ::: --records SC-029:allow-list bash "$BP_SELF" expect yes -- "${BP_K[@]}" auth can-i create events -n "$INTENT_NS" --as="$BP_DEPLOYER" || true
  while read -r r ns; do
    for v in get list watch create delete; do
      bp::pair "$(bp::cid BP.allow.allocator "$v" "$r" "$ns")" \
        bash "$BP_SELF" expect yes -- "${BP_K[@]}" auth can-i "$v" "$r" -n "$ns" --as="$BP_UNBOUND" \
        ::: --records SC-029:allow-list bash "$BP_SELF" expect yes -- "${BP_K[@]}" auth can-i "$v" "$r" -n "$ns" --as="$BP_ALLOCATOR" || true
    done
  done < <(bp::claim_resources "$authority")

  # ---- 4. can-i --list in every namespace: nothing else
  local -a NSS=()
  mapfile -t NSS < <(bp::k get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  for who in deployer allocator; do
    sa="$(bp::who "$who")"
    for ns in "${NSS[@]}"; do
      bp::pair "$(bp::cid BP.list "$who" "$ns")" \
        bash "$BP_SELF" expect list "$(bp::expected_rules "$who" "$ns" "$authority")" -- "${BP_K[@]}" auth can-i --list -n "$ns" \
        ::: --records SC-029:list bash "$BP_SELF" expect list "$(bp::expected_rules "$who" "$ns" "$authority")" -- "${BP_K[@]}" auth can-i --list -n "$ns" --as="$sa" || true
    done
  done

  # ---- 5. the denial table
  local verb res scope
  local -a sc
  while IFS='|' read -r who verb res scope; do
    [[ -n "$who" ]] || continue
    read -r -a sc <<<"$scope"
    local w
    for w in deployer allocator; do
      [[ "$who" == both || "$who" == "$w" ]] || continue
      bp::pair "$(bp::cid BP.deny "$w" "$verb" "$res" "${scope/-n /}")" \
        bash "$BP_SELF" expect no -- "${BP_K[@]}" auth can-i "$verb" "$res" "${sc[@]}" \
        ::: --records SC-029:denial bash "$BP_SELF" expect no -- "${BP_K[@]}" auth can-i "$verb" "$res" "${sc[@]}" --as="$(bp::who "$w")" || true
    done
  done < <(bp::denials "$authority" | awk '!seen[$0]++')

  # ---- 6. the force-release admission probe
  bp::manifests "$(bp::image)"
  local frm="$EVIDENCE_DIR/boundary/manifests/force-release-network.yaml"
  local frm0="$EVIDENCE_DIR/boundary/manifests/force-release-network-no-annotation.yaml"
  bp::pair BP-force-release-denied \
    bash "$BP_SELF" expect admission-denied -- "${BP_K[@]}" create --dry-run=server -f "$frm" -o name \
    ::: --records SC-029:force-release bash "$BP_SELF" expect admission-denied -- "${BP_K[@]}" create --dry-run=server -f "$frm" -o name --as="$BP_DEPLOYER" || true
  gate::run BP.force-release.cluster-admin-accepted --attach boundary/manifests/force-release-network.yaml -- \
    bash "$BP_SELF" expect accepted -- "${BP_K[@]}" create --dry-run=server -f "$frm" -o name >/dev/null 2>&1 \
    || suite::fail "the cluster admin's dry-run create of the annotated scratch Network was not accepted"
  gate::run BP.force-release.deployer-without-annotation-accepted --attach boundary/manifests/force-release-network-no-annotation.yaml -- \
    bash "$BP_SELF" expect accepted -- "${BP_K[@]}" create --dry-run=server -f "$frm0" -o name --as="$BP_DEPLOYER" >/dev/null 2>&1 \
    || suite::fail "the deployer's dry-run create WITHOUT the annotation was refused: the refusal is not the annotation's"
  gate::run BP.force-release.allocator-rbac -- \
    bash "$BP_SELF" expect no -- "${BP_K[@]}" auth can-i create "$BP_NET_RES" -n "$INTENT_NS" --as="$BP_ALLOCATOR" >/dev/null 2>&1 \
    || suite::fail "the allocator could create a Network in ${INTENT_NS}"

  # ---- 7. bare pods
  BP_SCRATCH_UP=1
  gate::run BP.pods.control --attach boundary/manifests/control.yaml -- "${BP_K[@]}" apply -f "$EVIDENCE_DIR/boundary/manifests/control.yaml" >/dev/null 2>&1 \
    || { suite::fail "the control namespace/pod could not be created"; suite::finish "boundary probes"; exit 1; }
  gate::run BP.pods.tier --attach boundary/manifests/tier-pods.yaml -- "${BP_K[@]}" apply -f "$EVIDENCE_DIR/boundary/manifests/tier-pods.yaml" >/dev/null 2>&1 \
    || { suite::fail "the bare tier pods could not be created"; suite::finish "boundary probes"; exit 1; }
  if ! gate::run BP.pods.ready -- bash -c "$(printf '%q ' "${BP_K[@]}") wait --for=condition=Ready pod -n ${TIER_NS} -l app.kubernetes.io/name=vt-scratch-boundary-probe --timeout=${BP_POD_TIMEOUT}s && $(printf '%q ' "${BP_K[@]}") wait --for=condition=Ready pod/vt-scratch-ctl-dial -n ${BP_CTL_NS} --timeout=${BP_POD_TIMEOUT}s" >/dev/null 2>&1; then
    suite::fail "the probe pods did not become Ready within ${BP_POD_TIMEOUT}s"; suite::finish "boundary probes"; exit 1
  fi
  gate::run BP.pods.ips -- "${BP_K[@]}" get pods -n "$TIER_NS" -l app.kubernetes.io/name=vt-scratch-boundary-probe -o wide >/dev/null 2>&1 || true
  bp::wait_policy_programmed
  local -a TX=("${BP_K[@]}" exec -n "$TIER_NS")
  local -a CX=("${BP_K[@]}" exec -n "$BP_CTL_NS" vt-scratch-ctl-dial --)
  bp::pair BP-pod-deployer-api-secrets-403 \
    bash "$BP_SELF" expect http 403 -- "${TX[@]}" vt-scratch-tier-deployer -- python3 -c "$BP_API_PY" "/apis/fabric.agentic-netops.io/v1alpha1/namespaces/${INTENT_NS}/networks" \
    ::: --records SC-029:identity-pod bash "$BP_SELF" expect http 403 -- "${TX[@]}" vt-scratch-tier-deployer -- python3 -c "$BP_API_PY" "/api/v1/namespaces/${TIER_NS}/secrets" || true
  local claim_path
  claim_path="$(bp::claim_resources "$authority" | head -n1 | awk '{split($1, a, "."); g=substr($1, length(a[1]) + 2); print "/apis/" g "/v1alpha1/namespaces/" $2 "/" a[1]}')"
  bp::pair BP-pod-allocator-api-secrets-403 \
    bash "$BP_SELF" expect http 403 -- "${TX[@]}" vt-scratch-tier-allocator -- python3 -c "$BP_API_PY" "$claim_path" \
    ::: --records SC-029:identity-pod bash "$BP_SELF" expect http 403 -- "${TX[@]}" vt-scratch-tier-allocator -- python3 -c "$BP_API_PY" "/api/v1/namespaces/${TIER_NS}/secrets" || true
  gate::run BP.pod.allocator.api-networks-403 -- \
    bash "$BP_SELF" expect http 403 -- "${TX[@]}" vt-scratch-tier-allocator -- python3 -c "$BP_API_PY" "/apis/fabric.agentic-netops.io/v1alpha1/namespaces/${INTENT_NS}/networks" >/dev/null 2>&1 \
    || suite::fail "the allocator's pod could read Networks with its own token"

  # ---- 8. the counter: observed, installed, zeroed, shown not moved
  local TEC="$BP_HERE/lib/tier_egress_counter.sh"
  if gate::run BP.counter.install -- bash "$TEC" install >"$EVIDENCE_DIR/boundary/counter-install.json" 2>/dev/null; then
    BP_COUNTER_UP=1
    jq '.observation' "$EVIDENCE_DIR/boundary/counter-install.json" >"$EVIDENCE_DIR/boundary/packet-filter-frontend.json"
    log::info "packet-filter front end: $(jq -r '.decision' "$EVIDENCE_DIR/boundary/packet-filter-frontend.json")"
  else
    suite::fail "the per-source counter could not be installed (front end observation in the evidence)"
  fi
  gate::run BP.counter.zero -- bash "$TEC" read --reset >/dev/null 2>&1 || true
  if ! evidence_negative_control BP-counter-moved -- bash "$TEC" check --proto all --min 1 >/dev/null 2>&1; then
    suite::fail "BP-counter-moved: the counter moved with no tier dial yet (or could not be read) — it is not admitted as evidence"
  fi

  # ---- 9. the dials
  local p proto node addr
  local -a DEV=()
  mapfile -t DEV < <(lab::devices)
  for p in "${PORTS[@]}"; do
    read -r proto p <<<"$p"
    [[ "$proto" == tcp ]] || continue
    for node in "${DEV[@]}"; do
      addr="$(lab::addr "$node")"
      bp::pair "$(bp::cid BP.dial tcp "$node" "$p")" \
        bash "$BP_SELF" expect timeout -- "${CX[@]}" timeout "$BP_DIAL_TIMEOUT" bash -c "exec 3<>/dev/tcp/${addr}/${p}" \
        ::: --records SC-029:dial bash "$BP_SELF" expect timeout -- "${TX[@]}" vt-scratch-tier-dial -- timeout "$BP_DIAL_TIMEOUT" bash -c "exec 3<>/dev/tcp/${addr}/${p}" || true
    done
  done
  for who in deployer allocator; do
    for node in "${DEV[@]}"; do
      addr="$(lab::addr "$node")"
      bp::pair "$(bp::cid BP.dial tcp "$node" "$GNMI_PORT" from-identity "$who")" \
        bash "$BP_SELF" expect timeout -- "${CX[@]}" timeout "$BP_DIAL_TIMEOUT" bash -c "exec 3<>/dev/tcp/${addr}/${GNMI_PORT}" \
        ::: --records SC-029:dial bash "$BP_SELF" expect timeout -- "${TX[@]}" "vt-scratch-tier-${who}" -- timeout "$BP_DIAL_TIMEOUT" bash -c "exec 3<>/dev/tcp/${addr}/${GNMI_PORT}" || true
    done
  done
  bp::cluster_paths "${CX[@]}" ::: "${TX[@]}"

  # ---- 10. the counter MUST have moved
  local cid
  cid="$(gate::id BP.counter.moved)"
  if evidence_run "$cid" --check BP-counter-moved --readiness --records SC-028:positive-control -- bash "$TEC" check --proto all --min 1 >/dev/null 2>&1; then
    log::info "counter positive control: $(sed -n 's/^COUNTER //p' "$EVIDENCE_DIR/$cid.stdout") ($(jq -c '.total' <(sed -n '1,/^}/p' "$EVIDENCE_DIR/$cid.stdout") 2>/dev/null))"
  else
    suite::fail "SC-028 positive control: the per-source counter did NOT move on the tier pod's dials — it is not evidence (T145)"
  fi

  # ---- 11. the UDP row: recorded; the counter asserts it
  gate::run BP.counter.zero-before-udp -- bash "$TEC" read --reset >/dev/null 2>&1 || true
  if ! evidence_negative_control BP-counter-udp -- bash "$TEC" check --proto udp --min 1 >/dev/null 2>&1; then
    suite::fail "BP-counter-udp: the udp count moved before any datagram was sent"
  fi
  for p in "${PORTS[@]}"; do
    read -r proto p <<<"$p"
    [[ "$proto" == udp ]] || continue
    for node in "${DEV[@]}"; do
      addr="$(lab::addr "$node")"
      gate::run "$(bp::cid BP.udp.recorded.control "$node" "$p")" --records SC-029:udp-recorded -- \
        "${CX[@]}" timeout "$BP_DIAL_TIMEOUT" bash -c "printf 'vt-scratch-boundary-probe' > /dev/udp/${addr}/${p}; echo sent" >/dev/null 2>&1 || true
      for who in dial deployer allocator; do
        gate::run "$(bp::cid BP.udp.recorded "$who" "$node" "$p")" --records SC-029:udp-recorded -- \
          "${TX[@]}" "vt-scratch-tier-${who}" -- timeout "$BP_DIAL_TIMEOUT" bash -c "printf 'vt-scratch-boundary-probe' > /dev/udp/${addr}/${p}; echo sent" >/dev/null 2>&1 || true
      done
    done
  done
  cid="$(gate::id BP.counter.udp)"
  if evidence_run "$cid" --check BP-counter-udp --readiness --records SC-029:udp-asserted --records SC-028:udp -- bash "$TEC" check --proto udp --min 1 >/dev/null 2>&1; then
    log::info "UDP row asserted by the counter: $(sed -n 's/^COUNTER //p' "$EVIDENCE_DIR/$cid.stdout")"
  else
    suite::fail "the UDP row: the per-source counter's udp count did NOT move on the tier pods' datagrams"
  fi

  # ---- node-local destinations: recorded (live-findings 2026-09-24-tier-egress-cluster-paths)
  bp::node_local "${TX[@]}"

  # ---- 12. removal, read back
  if [[ "$BP_COUNTER_UP" == 1 ]]; then
    gate::run BP.counter.remove -- bash "$TEC" remove >/dev/null 2>&1 || suite::fail "the counter was not removed and read back"
    BP_COUNTER_UP=0
  fi
  bp::cleanup || suite::fail "scratch removal not read back"

  jq -n --argjson passed "$BP_PASSED" --arg fails "$(printf '%s\n' "${SUITE_FAILS[@]:-}")" --arg auth "$authority" \
    --arg ports "$(printf '%s\n' "${PORTS[@]}")" '
    {suite: "boundary_probes", authority: $auth, readiness_checks_passed: $passed,
     port_set: ($ports | split("\n") | map(select(length > 0))),
     failures: ($fails | split("\n") | map(select(length > 0)))}' >"$EVIDENCE_DIR/boundary/summary.json"
  bp::seal
  suite::finish "boundary probes"
}

# bp::cluster_paths <control exec argv…> ::: <tier exec argv…> — the in-cluster paths to the
# device-configuration layer and the platform's controllers: every TCP endpoint (EndpointSlice
# address and port) in BP_CLUSTER_NS. Each is first dialled from the UNRESTRICTED control pod in
# one captured record; an endpoint that does not answer even there (its own ingress policy, or not
# serving) cannot give a denial meaning and is recorded as not attemptable. Every other one is a
# pair: the control pod's dial completes (its negative control), the tier pod's times out. The
# cluster DNS is shown still reachable from the tier pod (the policy's one in-cluster allowance).
: "${BP_CLUSTER_NS:=sdc-system agentic-netops-system agentic-netops-allocation monitoring cert-manager}"
bp::cluster_paths() {
  local -a cx=() tx=()
  while [[ $# -gt 0 && "$1" != ::: ]]; do cx+=("$1"); shift; done
  shift; tx=("$@")
  local ns f="$EVIDENCE_DIR/boundary/cluster-paths.txt" ep port svc id
  : >"$f"
  for ns in $BP_CLUSTER_NS; do
    bp::k get endpointslices -n "$ns" -o json 2>/dev/null | jq -r --arg ns "$ns" '
      .items[] | (.metadata.labels["kubernetes.io/service-name"] // .metadata.name) as $svc
      | [.ports[]? | select((.protocol // "TCP") == "TCP") | .port] as $ports
      | .endpoints[]? | .addresses[] as $a | $ports[] | "\($a) \(.) \($ns)/\($svc)"' >>"$f"
  done
  sort -u -o "$f" "$f"
  [[ -s "$f" ]] || { suite::fail "no in-cluster endpoint found in ${BP_CLUSTER_NS}"; return 1; }
  local reach="$EVIDENCE_DIR/boundary/cluster-paths.control-reachability.txt"
  # evidence_run gives the command no stdin: the endpoint list travels as one argument
  gate::run BP.cluster-paths.from-control --attach boundary/cluster-paths.txt -- \
    "${cx[@]}" bash -c 'printf "%s\n" "$1" | while read -r a p s; do if timeout '"$BP_DIAL_TIMEOUT"' bash -c "exec 3<>/dev/tcp/$a/$p" 2>/dev/null; then r=0; else r=$?; fi; echo "$a $p $s rc=$r"; done' \
    _ "$(cat "$f")" >"$reach" 2>/dev/null || true
  grep -q 'rc=' "$reach" || { suite::fail "the control pod's reachability of the in-cluster endpoints was not captured"; return 1; }
  while read -r ep port svc rc; do
    [[ -n "$ep" ]] || continue
    id="$(bp::cid BP.cluster-path "$svc" "$ep" "$port")"
    if [[ "$rc" == rc=124 ]]; then
      echo "NOT-ATTEMPTABLE ${svc} ${ep}:${port} — no answer even from the unrestricted control pod" >>"$EVIDENCE_DIR/boundary/cluster-paths.not-attemptable.txt"
      continue
    fi
    bp::pair "$id" \
      bash "$BP_SELF" expect timeout -- "${cx[@]}" timeout "$BP_DIAL_TIMEOUT" bash -c "exec 3<>/dev/tcp/${ep}/${port}" \
      ::: --records SC-029:cluster-path bash "$BP_SELF" expect timeout -- "${tx[@]}" vt-scratch-tier-dial -- timeout "$BP_DIAL_TIMEOUT" bash -c "exec 3<>/dev/tcp/${ep}/${port}" || true
  done <"$reach"
  gate::run BP.cluster-dns-allowed -- "${tx[@]}" vt-scratch-tier-dial -- python3 -c \
    'import socket; a = socket.gethostbyname("kubernetes.default.svc.cluster.local"); print("resolved", a)' >/dev/null 2>&1 \
    || suite::fail "the cluster DNS is not reachable from a tier pod: allow-egress-scoped's DNS allowance does not work"
}

# bp::node_local <tier exec argv…> — destinations local to a node (its addresses: the API server's
# endpoint on kind, the node's own management address) are delivered on the node's INPUT path,
# which the pinned policy engine does not filter (observed: kindnet's chains hook prerouting for DNS
# and postrouting only). RECORDED, never asserted: what answers there requires a credential
# (the API server, the kubelet), and no device is local to a node.
bp::node_local() {
  local -a tx=("$@")
  local n a p
  while read -r a p; do
    [[ -n "$a" ]] || continue
    gate::run "$(bp::cid BP.node-local.recorded apiserver "$a" "$p")" --records SC-029:node-local-recorded -- \
      "${tx[@]}" vt-scratch-tier-dial -- timeout "$BP_DIAL_TIMEOUT" bash -c "exec 3<>/dev/tcp/${a}/${p} && echo 'node-local: connected (not filtered by the policy engine; authentication and RBAC are the boundary)'" >/dev/null 2>&1 || true
  done < <(bp::k get endpointslices -n default -l kubernetes.io/service-name=kubernetes -o json | jq -r '.items[] | (.ports[0].port) as $p | .endpoints[].addresses[] | "\(.) \($p)"')
  for n in $(lab::docker ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" --format '{{.Names}}'); do
    a="$(lab::docker inspect -f "{{with index .NetworkSettings.Networks \"${MGMT_NETWORK}\"}}{{.IPAddress}}{{end}}" "$n" 2>/dev/null)" || a=""
    [[ -n "$a" ]] || continue
    gate::run "$(bp::cid BP.node-local.recorded node-mgmt-address "$n" "$a")" --records SC-029:node-local-recorded -- \
      "${tx[@]}" vt-scratch-tier-dial -- timeout "$BP_DIAL_TIMEOUT" bash -c "exec 3<>/dev/tcp/${a}/6443 && echo 'node-local ${a} (the node itself, not a device): connected'" >/dev/null 2>&1 || true
  done
}

# bp::wait_policy_programmed — the policy engine lists the tier pods before any dial (kindnet keeps
# the addresses of pods under a policy in an nftables set; recorded, bounded; where the node carries
# no such set, a fixed settle interval is recorded instead)
bp::wait_policy_programmed() {
  local ips n i ok
  ips="$(bp::k get pods -n "$TIER_NS" -l app.kubernetes.io/name=vt-scratch-boundary-probe -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}')"
  for i in $(seq 1 30); do
    ok=1
    for n in $(lab::docker ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" --format '{{.Names}}'); do
      if lab::docker exec "$n" nft list set inet kindnet-network-policies podips-v4 >/dev/null 2>&1; then
        local pset ip
        pset="$(lab::docker exec "$n" nft list set inet kindnet-network-policies podips-v4 2>/dev/null)"
        for ip in $ips; do grep -qE "(^|[^0-9.])${ip//./\\.}([^0-9.]|$)" <<<"$pset" || ok=0; done
      else
        sleep 5; break
      fi
    done
    [[ "$ok" == 1 ]] && break
    sleep 1
  done
  gate::run BP.policy-programmed -- bash -c "for n in \$(${DOCKER:-docker} ps --filter label=io.x-k8s.kind.cluster=${CLUSTER_NAME} --format '{{.Names}}'); do echo \"== \$n\"; ${DOCKER:-docker} exec \"\$n\" nft list set inet kindnet-network-policies podips-v4 2>&1 || echo 'no kindnet policy set on this node'; done; echo 'tier probe pod addresses:' ${ips//$'\n'/ }" >/dev/null 2>&1 || true
}

bp::main() {
  case "${1:-run}" in
    run) bp::run ;;
    --print-ports) bp::ports ;;
    reconcile) shift; bp::reconcile "$@" ;;
    scratch-scan) source "$BP_ROOT/tests/lib/lab.sh"; bp::scratch_scan && echo "no boundary-probe scratch present" ;;
    expect) shift; bp::expect "$@" ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' ;;
    *) echo "usage: boundary_probes.sh [run] | --print-ports | reconcile <mgmt-ports.json> | expect <mode> -- <cmd…>" >&2; exit 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  bp::main "$@"
fi
