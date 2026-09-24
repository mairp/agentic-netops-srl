#!/usr/bin/env bash
# tests/unit/boundary/port_list_test.sh — the one device port list, and its copies (T066; FR-075,
# SC-029, AD-49; contracts/kubernetes-objects.md §"Identity contract", quickstart.md §15).
#
# The contract states the port set ONCE, in one sentence: "the lab image exposes **TCP 22, 80, …,
# and UDP 161**". This test extracts the TCP and UDP sets from that sentence with its OWN extractor
# (not the suite's, so a bug in the suite's cannot agree with itself) and fails when
#   1. the set the probe suite would actually dial — `boundary_probes.sh --print-ports`, the same
#      function its dial loop iterates — differs from it by a single port, either protocol;
#   2. the runnable copy in quickstart.md §15 — the `for P in …` TCP loop and the /dev/udp line —
#      differs from it by a single port;
#   3. the suite carries the list retyped: its source names no contract port literal, and a copy of
#      the contract with one more port makes --print-ports print that port (the suite READS it);
#   4. the suite accepts a contract without the sentence (it must refuse, naming the file).
# Mutation negative controls: a copy of quickstart §15 with one TCP port removed, and one with the
# UDP port changed, must make comparison 2 fail; a suite output with one port dropped must make
# comparison 1 fail. The comparison is shown able to fail before a pass of it counts.
#
# specs/ is the specification tree, local to the working copy (.gitignore): where it is absent the
# test says so, loudly, and checks what it can without it (3 against a fixture contract).
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
SUITE="$ROOT/tests/integration/boundary_probes.sh"
CONTRACT="$ROOT/specs/004-agentic-netops-composite/contracts/kubernetes-objects.md"
QUICKSTART="$ROOT/specs/004-agentic-netops-composite/quickstart.md"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok()  { printf 'PASS %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

# contract_sets <file> — "tcp <p>" / "udp <p>" lines from the one sentence, sorted; rc 1 if not once
contract_sets() {
  local flat hits
  flat="$(tr '\n' ' ' <"$1" | tr -s ' ')"
  hits="$(grep -oE 'exposes \*\*TCP [0-9][0-9, and]*, and UDP [0-9][0-9, and]*\*\*' <<<"$flat")"
  [[ "$(grep -c . <<<"$hits")" -eq 1 ]] || return 1
  local tcp udp
  tcp="$(sed -E 's/.*TCP (.*), and UDP.*/\1/' <<<"$hits")"
  udp="$(sed -E 's/.*and UDP ([^*]*)\*\*.*/\1/' <<<"$hits")"
  { grep -oE '[0-9]+' <<<"$tcp" | sed 's/^/tcp /'; grep -oE '[0-9]+' <<<"$udp" | sed 's/^/udp /'; } | LC_ALL=C sort -u
}

# quickstart_sets <file> — the runnable copy in §15: the `for P in …; do` TCP loop and every
# /dev/udp/<addr>/<port> of the section, sorted
quickstart_sets() {
  local sec
  sec="$(awk '/^## 15\./{f=1; next} /^## /{f=0} f' "$1")"
  [[ -n "$sec" ]] || return 1
  {
    grep -E '^[[:space:]]*for P in [0-9 ]+; do' <<<"$sec" | sed -E 's/.*for P in ([0-9 ]+); do.*/\1/' | grep -oE '[0-9]+' | sed 's/^/tcp /'
    grep -oE '/dev/udp/[0-9.]+/[0-9]+' <<<"$sec" | sed -E 's|.*/||; s/^/udp /'
  } | LC_ALL=C sort -u
}

suite_sets() { "$@" bash "$SUITE" --print-ports | LC_ALL=C sort -u; }

# same <a> <b> — 0 when both sets are equal and non-empty; prints the difference
same() {
  local d
  [[ -n "$1" && -n "$2" ]] || { echo "an empty set"; return 1; }
  d="$(diff <(printf '%s\n' "$1") <(printf '%s\n' "$2"))" && return 0
  printf '%s\n' "$d"; return 1
}

# ---- fixture contract (always available): the suite reads whatever the contract says
cat >"$T/contract.md" <<'EOF'
# fixture
Taken from the report, the lab image exposes
**TCP 22, 80, 443, 830, 50052, 57400, 57401, 57410 and 57411, and UDP 161**. The platform speaks
EOF
sed 's/57411, and UDP 161/57411 and 23, and UDP 161 and 162/' "$T/contract.md" >"$T/contract-plus.md"
sed 's/exposes/documents/' "$T/contract.md" >"$T/contract-none.md"
fx="$(contract_sets "$T/contract.md")"
fxplus="$(contract_sets "$T/contract-plus.md")"
[[ "$(grep -c . <<<"$fx")" -eq 10 ]] && ok "the fixture sentence yields 9 TCP + 1 UDP ports" || bad "fixture extraction" "$fx"
got="$(BP_CONTRACT="$T/contract-plus.md" suite_sets env 2>&1)"
if same "$fxplus" "$got" >/dev/null && grep -qx 'tcp 23' <<<"$got" && grep -qx 'udp 162' <<<"$got"; then
  ok "the suite READS the contract: one more port in it (tcp/23, udp/162) is one more port dialled"
else
  bad "the suite does not follow the contract it is given" "$got"
fi
if BP_CONTRACT="$T/contract-none.md" bash "$SUITE" --print-ports >"$T/none.out" 2>&1; then
  bad "the suite accepted a contract without the port sentence" "$(cat "$T/none.out")"
else
  grep -q "contract-none.md" "$T/none.out" && ok "a contract without the sentence is refused, naming the file" \
    || bad "the refusal does not name the contract file" "$(cat "$T/none.out")"
fi
# the list is never retyped in the suite: no contract-only port literal in its source
if grep -nE '\b(50052|57401|57410|57411)\b' "$SUITE" | grep -v '^\s*#' >"$T/lit"; then
  bad "the suite retypes the port list (a literal port of the contract in its source)" "$(cat "$T/lit")"
else
  ok "the suite's source carries no literal of the contract's port list"
fi

# ---- the real contract, the real suite, the real quickstart
if [[ ! -d "$ROOT/specs" ]]; then
  echo "NOTE specs/ is absent from this working copy (local, git-ignored): the contract and quickstart comparisons cannot run here — they run wherever the specification is present"
  echo "port_list_test: $fails failure(s)"
  [[ "$fails" -eq 0 ]]; exit
fi
[[ -f "$CONTRACT" ]] || { bad "the contract ${CONTRACT#"$ROOT"/} is missing"; echo "port_list_test: $fails failure(s)"; exit 1; }
[[ -f "$QUICKSTART" ]] || { bad "quickstart ${QUICKSTART#"$ROOT"/} is missing"; echo "port_list_test: $fails failure(s)"; exit 1; }

C="$(contract_sets "$CONTRACT")" || { bad "the contract's port sentence is not found exactly once"; C=""; }
[[ -n "$C" ]] && ok "contract: TCP {$(sed -n 's/^tcp //p' <<<"$C" | paste -sd, -)} UDP {$(sed -n 's/^udp //p' <<<"$C" | paste -sd, -)}"
S="$(suite_sets env 2>/dev/null)"
Q="$(quickstart_sets "$QUICKSTART")"

# negative controls first: each comparison must be able to fail
S_minus="$(grep -vx 'tcp 57410' <<<"$S")"
if same "$C" "$S_minus" >/dev/null; then bad "negative control: a suite set missing tcp/57410 compared equal"; else ok "negative control: the suite comparison fails on a set one port short"; fi
awk '/^## 15\./{f=1} f && /^[[:space:]]*for P in /{sub(/ 57401/, "")} {print}' "$QUICKSTART" >"$T/qs-minus.md"
awk '/^## 15\./{f=1} f{gsub(/\/dev\/udp\/172\.25\.25\.21\/161/, "/dev/udp/172.25.25.21/162")} {print}' "$QUICKSTART" >"$T/qs-udp.md"
if cmp -s "$QUICKSTART" "$T/qs-minus.md"; then
  bad "negative control: the mutation did not remove a port from the quickstart loop (the loop moved?)"
elif same "$C" "$(quickstart_sets "$T/qs-minus.md")" >/dev/null; then
  bad "negative control: a quickstart copy with tcp/57401 removed compared equal"
else
  ok "negative control: a quickstart copy with one TCP port removed fails the comparison"
fi
if cmp -s "$QUICKSTART" "$T/qs-udp.md"; then
  bad "negative control: the mutation did not change the quickstart's UDP port"
elif same "$C" "$(quickstart_sets "$T/qs-udp.md")" >/dev/null; then
  bad "negative control: a quickstart copy with UDP 162 for 161 compared equal"
else
  ok "negative control: a quickstart copy with the UDP port changed fails the comparison"
fi

# the comparisons
if d="$(same "$C" "$S")"; then ok "the probe suite dials exactly the contract's set (TCP and UDP)"; else bad "the probe suite's set differs from the contract" "$d"; fi
if d="$(same "$C" "$Q")"; then ok "quickstart §15's runnable copy equals the contract's set (TCP loop and UDP line)"; else bad "quickstart §15 differs from the contract" "$d"; fi

echo "port_list_test: $fails failure(s)"
[[ "$fails" -eq 0 ]]
