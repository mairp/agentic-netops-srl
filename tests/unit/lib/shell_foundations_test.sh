#!/usr/bin/env bash
# Shell foundations suite (T024; FR-010): scripts/lib/{k8s_wait,ownership,dotenv,log}.sh.
# Offline: kubectl is a stub on PATH that answers from files under a temp dir.
#
#   k8s_wait   every wait is bounded: it times out within its bound and the
#              diagnostic names the resource, the bound and the next command;
#              an unbounded (0/absent) timeout is refused.
#   ownership  an object lacking the exact ownership label value — no label, a
#              near-miss value (prefix-extended, case-changed, padded) — is
#              refused naming it, and the guarded command is not run; the owned
#              object is allowed and the command runs.
#   dotenv     loads KEY=VALUE without executing anything, without reading
#              stdin (no prompt), and never overrides an already-set variable;
#              noninteractive exports the no-prompt defaults.
#   log        level filtering, the line format, stderr only, log::die exits 1.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$ROOT/scripts/lib"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/objects"

# Stub kubectl. `get <kind> <name> ... -o json` prints $STUB/objects/<name>.json
# (exit 1 NotFound when absent); `wait` and `rollout status` always time out;
# every call is appended to $STUB/calls.
cat >"$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
STUB="${KUBECTL_STUB_DIR:?}"
echo "$*" >>"$STUB/calls"
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in --context) shift 2 ;; *) args+=("$1"); shift ;; esac
done
set -- "${args[@]}"
case "$1" in
  get)
    if [[ "$2" == events ]]; then echo "LAST SEEN  TYPE  REASON  OBJECT  MESSAGE"; echo "5s  Warning  BackOff  pod/x  stub event"; exit 0; fi
    name="$3"; name="${name#*/}"; [[ -z "$name" || "$name" == -* ]] && name="${2#*/}"
    if [[ -f "$STUB/objects/$name.json" ]]; then cat "$STUB/objects/$name.json"; exit 0; fi
    echo "Error from server (NotFound): $2 \"$name\" not found" >&2; exit 1 ;;
  wait) echo "error: timed out waiting for the condition on $2" >&2; exit 1 ;;
  rollout) echo "error: deployment \"$3\" exceeded its progress deadline" >&2; exit 1 ;;
  delete) echo "deleted $2 $3"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$TMP/bin/kubectl"
export KUBECTL_STUB_DIR="$TMP"

obj() {  # obj <name> [label-value|-]
  local name="$1" val="${2:--}"
  if [[ "$val" == - ]]; then
    printf '{"metadata":{"name":"%s","labels":{"app":"x"}}}\n' "$name" >"$TMP/objects/$name.json"
  else
    jq -n --arg n "$name" --arg v "$val" '{metadata:{name:$n,labels:{"agentic-netops.io/owned-by":$v}}}' >"$TMP/objects/$name.json"
  fi
}

# run <snippet> — a fresh bash with the libraries sourced and the stub first on PATH.
run() {
  env -u OWNERSHIP_LABEL_VALUE -u OWNERSHIP_LABEL_KEY -u KUBE_CONTEXT -u LOG_LEVEL -u LOG_PHASE \
    PATH="$TMP/bin:$PATH" CLUSTER_NAME=agentic-netops \
    bash -c "set -uo pipefail; source '$LIB/log.sh'; source '$LIB/k8s_wait.sh'; source '$LIB/ownership.sh'; source '$LIB/dotenv.sh'; $1"
}

# --- k8s_wait: bounded, diagnostic names the resource
start=$(date +%s)
out="$(run 'k8s_wait::exists deployment/srl-provider agentic-netops-system 3; echo rc=$?' 2>&1)"
elapsed=$(( $(date +%s) - start ))
if grep -qx 'rc=1' <<<"$out" && [[ "$elapsed" -le 6 ]] \
  && grep -q 'timed out after 3s waiting for: deployment/srl-provider in agentic-netops-system to exist' <<<"$out" \
  && grep -q 'not found' <<<"$out"; then
  pass "k8s_wait::exists times out within its 3s bound (${elapsed}s) naming the resource and the probe's last output"
else
  fail "k8s_wait::exists times out within its bound naming the resource (${elapsed}s)" "$out"
fi

start=$(date +%s)
out="$(run 'k8s_wait::until 2 1 "fabric fabric01 Ready" -- false; echo rc=$?' 2>&1)"
elapsed=$(( $(date +%s) - start ))
if grep -qx 'rc=1' <<<"$out" && [[ "$elapsed" -le 4 ]] && grep -q 'waiting for: fabric fabric01 Ready' <<<"$out" \
  && grep -q 'next:' <<<"$out"; then
  pass "k8s_wait::until stops at its bound (${elapsed}s <= 4) with a next-step hint"
else
  fail "k8s_wait::until stops at its bound with a next-step hint (${elapsed}s)" "$out"
fi

obj fabric01 agentic-netops
out="$(run 'k8s_wait::condition fabric/fabric01 Ready - 5; echo rc=$?' 2>&1)"
if grep -qx 'rc=1' <<<"$out" && grep -q 'timed out after 5s waiting for fabric/fabric01 to report condition Ready' <<<"$out" \
  && grep -q 'next: kubectl describe fabric/fabric01' <<<"$out" && grep -q 'recent events' <<<"$out" \
  && grep -q -- '--timeout=5s' "$TMP/calls"; then
  pass "k8s_wait::condition passes its bound to kubectl and diagnoses the named object (state, events, next command)"
else
  fail "k8s_wait::condition passes its bound and diagnoses the named object" "$out"
fi

out="$(run 'k8s_wait::rollout agentic-netops-system deployment/srl-provider 4; echo rc=$?' 2>&1)"
if grep -qx 'rc=1' <<<"$out" && grep -q 'rollout of deployment/srl-provider in agentic-netops-system' <<<"$out"; then
  pass "k8s_wait::rollout fails naming the workload and namespace"
else
  fail "k8s_wait::rollout fails naming the workload and namespace" "$out"
fi

out="$(run 'k8s_wait::until 0 1 "x" -- true; echo rc=$?; k8s_wait::condition fabric/f Ready - ""; echo rc2=$?' 2>&1)"
if grep -qx 'rc=2' <<<"$out" && grep -qx 'rc2=2' <<<"$out" && grep -q 'every wait is bounded' <<<"$out"; then
  pass "an unbounded wait (timeout 0 or empty) is refused (exit 2)"
else
  fail "an unbounded wait (timeout 0 or empty) is refused (exit 2)" "$out"
fi

# --- ownership: exact label value
obj owned agentic-netops
obj unlabelled -
obj near-prefix agentic-netops-2
obj near-case Agentic-Netops
obj near-pad "agentic-netops "
for n in unlabelled near-prefix near-case near-pad missing; do
  rm -f "$TMP/deleted"
  out="$(run "ownership::guard namespace $n - -- touch '$TMP/deleted'; echo rc=\$?" 2>&1)"
  if grep -qx 'rc=1' <<<"$out" && grep -q "refusing to touch namespace/$n" <<<"$out" \
    && grep -q "expected exactly 'agentic-netops'" <<<"$out" && [[ ! -e "$TMP/deleted" ]]; then
    pass "ownership refuses '$n' ($(jq -r '.metadata.labels["agentic-netops.io/owned-by"] // "no label"' "$TMP/objects/$n.json" 2>/dev/null || echo 'not found')) and does not run the command"
  else
    fail "ownership refuses '$n' and does not run the command" "$out"
  fi
done
rm -f "$TMP/deleted"
out="$(run "ownership::guard namespace owned - -- touch '$TMP/deleted'; echo rc=\$?; ownership::k8s_owned namespace owned && echo owned" 2>&1)"
if grep -qx 'rc=0' <<<"$out" && grep -qx 'owned' <<<"$out" && [[ -e "$TMP/deleted" ]]; then
  pass "ownership allows the object carrying exactly agentic-netops.io/owned-by=agentic-netops and runs the command"
else
  fail "ownership allows the owned object and runs the command" "$out"
fi
out="$(run 'CLUSTER_NAME=agentic-netops-2; ownership::k8s_owned namespace owned && echo owned || echo refused; ownership::selector' 2>&1)"
if grep -qx 'refused' <<<"$out" && grep -q 'agentic-netops.io/owned-by=agentic-netops-2' <<<"$out"; then
  pass "another cluster's name never owns this cluster's object (value follows CLUSTER_NAME)"
else
  fail "another cluster's name never owns this cluster's object" "$out"
fi

# --- dotenv: parsed not executed, no prompt, does not override
cat >"$TMP/test.env" <<EOF
# comment
export MGMT_CIDR=172.25.25.0/24
CLUSTER_NAME=from-file
QUOTED="a value with spaces"
INJECT=\$(touch $TMP/injected)
TRAILING=x # comment
not a pair
EOF
# stdin is a FIFO nobody writes to: a prompt (any read of stdin) would block
# until `timeout` kills it, so rc=0 proves nothing was read.
mkfifo "$TMP/stdin"
exec 7<>"$TMP/stdin"
out="$(env -u MGMT_CIDR -u QUOTED -u INJECT -u TRAILING CLUSTER_NAME=from-env PATH="$PATH" \
  timeout 10 bash -c "source '$LIB/dotenv.sh'; dotenv::load '$TMP/test.env'; echo \"M=\$MGMT_CIDR\"; echo \"C=\$CLUSTER_NAME\"; echo \"Q=\$QUOTED\"; echo \"I=\$INJECT\"; echo \"T=\$TRAILING\"" 2>&1 <&7)"
rc=$?
exec 7>&-
if [[ "$rc" -eq 0 ]] && grep -qx 'M=172.25.25.0/24' <<<"$out" && grep -qx 'C=from-env' <<<"$out" \
  && grep -qx 'Q=a value with spaces' <<<"$out" && grep -qxF "I=\$(touch $TMP/injected)" <<<"$out" \
  && grep -qx 'T=x' <<<"$out" && grep -q 'not KEY=VALUE, skipped' <<<"$out" && [[ ! -e "$TMP/injected" ]]; then
  pass "dotenv loads KEY=VALUE, keeps an already-set variable, executes nothing, never reads stdin"
else
  fail "dotenv loads KEY=VALUE, keeps an already-set variable, executes nothing, never reads stdin (rc=$rc)" "$out"
fi
out="$(env -u AGENTIC_NETOPS_ENV_FILE bash -c "source '$LIB/dotenv.sh'; dotenv::load '$TMP/absent.env'; echo rc=\$?")"
[[ "$out" == rc=0 ]] && pass "dotenv: a missing file is not an error (defaults apply)" \
  || fail "dotenv: a missing file is not an error" "$out"
out="$(env -u DEBIAN_FRONTEND -u GIT_TERMINAL_PROMPT -u PAGER bash -c "source '$LIB/dotenv.sh'; dotenv::noninteractive; echo \"\$DEBIAN_FRONTEND \$GIT_TERMINAL_PROMPT \$PAGER \$AGENTIC_NETOPS_NONINTERACTIVE\"")"
[[ "$out" == "noninteractive 0 cat 1" ]] && pass "dotenv::noninteractive exports the no-prompt defaults" \
  || fail "dotenv::noninteractive exports the no-prompt defaults" "$out"

# --- log levels
out="$(env -u LOG_LEVEL -u LOG_PHASE bash -c "source '$LIB/log.sh'; log::debug d1; log::info i1; log::warn w1" 2>&1 >/dev/null)"
if ! grep -q d1 <<<"$out" && grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z \[INFO \] \[-\] i1$' <<<"$out" \
  && grep -q '\[WARN \] \[-\] w1' <<<"$out"; then
  pass "log: default level info hides debug; line format '<UTC> [LEVEL] [phase] msg'"
else
  fail "log: default level info hides debug; line format" "$out"
fi
out="$(LOG_LEVEL=warn bash -c "source '$LIB/log.sh'; log::phase ClusterReady; log::info i2; log::warn w2; log::error e2" 2>&1)"
if ! grep -q i2 <<<"$out" && ! grep -q 'phase start' <<<"$out" && grep -q '\[WARN \] \[ClusterReady\] w2' <<<"$out" \
  && grep -q '\[ERROR\] \[ClusterReady\] e2' <<<"$out"; then
  pass "log: LOG_LEVEL=warn filters info; the phase prefix follows log::phase"
else
  fail "log: LOG_LEVEL=warn filters info; the phase prefix follows log::phase" "$out"
fi
out="$(LOG_LEVEL=debug bash -c "source '$LIB/log.sh'; log::debug d3" 2>/dev/null)"
[[ -z "$out" ]] && pass "log: nothing is written to stdout (stdout stays machine-readable)" \
  || fail "log: nothing is written to stdout" "$out"
out="$(bash -c "source '$LIB/log.sh'; log::die boom; echo after" 2>&1)"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -q '\[ERROR\] \[-\] boom' <<<"$out" && ! grep -q after <<<"$out"; then
  pass "log::die logs at error and exits 1 (fail fast)"
else
  fail "log::die logs at error and exits 1 (rc=$rc)" "$out"
fi

echo "shell_foundations_test: $fails failure(s)"
[ "$fails" -eq 0 ]
