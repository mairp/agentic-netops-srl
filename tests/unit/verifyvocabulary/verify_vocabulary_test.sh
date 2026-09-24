#!/usr/bin/env bash
# verify_vocabulary suite (T142; SC-033, FR-084, FR-085, FR-027, FR-028).
#
# Each case plants a miniature repository root in a scratch directory (never in the tree, so the
# planted retired names are not themselves a finding of the scans that run on this repository),
# runs scripts/ci/verify_vocabulary.sh on it with --root, and asserts the verdict it was planted
# for, NAMING THE SURFACE AND THE FILE:
#   clean                          a tree with every surface in construct vocabulary passes
#   prompts                        a suggestion naming a retired service fails; one that does not
#                                  name its construct fails; a missing suggestion file fails
#   refusals                       an unlabelled retired name in a refusal producer fails; the same
#                                  name under a migration-alias comment passes
#   ui                             a retired name in the chat bundle fails, whatever the label
#   docs                           an unlabelled retired name fails; one on a line saying
#                                  "migration alias", or under a "Migration aliases" heading, passes
#   dashboards                     a retired name in a dashboard panel title fails
#   reporting                      an unlabelled retired name in the status reporter fails
#   nearest                        a translator whose unknown-construct refusal does not list the four
#                                  construct names fails; one offering a retired name fails
# Finally the scan passes on this repository itself (with its run checks). Offline: python3; the
# repository run needs the Go toolchain, as `make verify-boundaries` does.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
VV="$ROOT/scripts/ci/verify_vocabulary.sh"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

# a clean miniature tree
plant() {
  local d="$SCRATCH/$1"
  mkdir -p "$d/agents/supervisors/provisioning/prompts" "$d/agents/common/guards" \
    "$d/agents/provisioning/deployer" "$d/ui/src" "$d/docs/reference" \
    "$d/deploy/observability/grafana/dashboards" "$d/pkg/fabricapi" "$d/tests/unit/testdata/migration"
  cp "$ROOT/agents/supervisors/provisioning/suggested_prompts.json" "$d/agents/supervisors/provisioning/"
  printf 'Confirm this {construct}?\n' >"$d/agents/supervisors/provisioning/prompts/confirm.md"
  printf 'CONSTRUCTS: tuple[str, ...] = ("vlan", "mac-vrf", "ip-vrf", "acl")\n' >"$d/agents/common/guards/refusals.py"
  printf 'def report(view):\n    return f"{view.construct} (provenance: {view.provenance})"\n' >"$d/agents/provisioning/deployer/status.py"
  printf 'export const label = "mac-vrf";\n' >"$d/ui/src/App.tsx"
  printf '# Constructs\n\nAsk for a mac-vrf.\n' >"$d/docs/reference/constructs.md"
  printf '{"title": "EVPN service path", "panels": [{"title": "mac-vrf tunnels"}]}\n' \
    >"$d/deploy/observability/grafana/dashboards/evpn.json"
  printf 'package fabricapi\n' >"$d/pkg/fabricapi/construct.go"
  for f in refuse_unknown_construct refuse_wrong_var_l2vni_on_vlan refuse_wrong_var_gateway_on_ipvrf; do
    echo '{}' >"$d/tests/unit/testdata/migration/$f.json"
  done
  printf '%s' "$d"
}

# a fake translator: refuses every request with the given cause
fake_translator() {
  local f="$SCRATCH/translator-$1"
  cat >"$f" <<EOF
#!/usr/bin/env bash
echo '{"error":"validation","causes":["$2"]}' >&2
exit 1
EOF
  chmod +x "$f"; printf '%s' "$f"
}
GOOD_TR="$(fake_translator good 'type: evpn-magic is not a construct; the constructs are vlan, mac-vrf, ip-vrf, acl — ask for a mac-vrf')"

# expect <root> <want-rc> <label> [<fixed string the output must contain>…]
expect() {
  local dir="$1" want="$2" label="$3"; shift 3
  local out rc p
  out="$(VOCAB_TRANSLATOR="${TR:-$GOOD_TR}" bash "$VV" --root "$dir" --no-derivation-tests 2>&1)"; rc=$?
  if [[ "$rc" -ne "$want" ]]; then fail "$label (rc=$rc, want $want)" "$out"; return; fi
  for p in "$@"; do
    grep -qF -- "$p" <<<"$out" || { fail "$label (output lacks '$p')" "$out"; return; }
  done
  if [[ "$want" -ne 0 ]]; then
    local n_fail; n_fail="$(grep -c '^FAIL \[' <<<"$out")"
    [[ "$n_fail" -eq $# ]] || { fail "$label ($n_fail FAIL line(s), want $#)" "$out"; return; }
  fi
  pass "$label"
}

d="$(plant clean)"; expect "$d" 0 "clean tree passes" "PASS — one vocabulary"

# prompts
d="$(plant prompt-retired)"
sed -i 's/for tenant acme"/for tenant acme as a VPLS"/' "$d/agents/supervisors/provisioning/suggested_prompts.json"
expect "$d" 1 "a retired name in a suggestion fails" \
  "FAIL [prompts] agents/supervisors/provisioning/suggested_prompts.json:15: retired service name 'VPLS' in a suggestion"
d="$(plant prompt-no-construct)"
sed -i 's/Create an ip-vrf for tenant initech/Create a routed instance for tenant initech/' \
  "$d/agents/supervisors/provisioning/suggested_prompts.json"
expect "$d" 1 "a suggestion that does not name its construct fails" \
  "FAIL [prompts] agents/supervisors/provisioning/suggested_prompts.json:29: prompts[2] does not name its construct 'ip-vrf'"
d="$(plant prompt-missing)"; rm "$d/agents/supervisors/provisioning/suggested_prompts.json"
expect "$d" 1 "a missing suggestion file fails" "FAIL [prompts] agents/supervisors/provisioning/suggested_prompts.json: missing"

# refusals
d="$(plant refusal-unlabelled)"
printf 'MSG = "ask for an L3VPN instead"\n' >>"$d/agents/common/guards/refusals.py"
expect "$d" 1 "an unlabelled retired name in a refusal fails" "FAIL [refusals] agents/common/guards/refusals.py:2"
d="$(plant refusal-labelled)"
printf '# migration aliases, input only\nALIASES = {"l3vpn": "ip-vrf"}\n' >>"$d/agents/common/guards/refusals.py"
expect "$d" 0 "a retired name under a migration-alias comment passes"

# ui
d="$(plant ui)"; printf 'export const alias = "VPWS"; // migration alias\n' >>"$d/ui/src/App.tsx"
expect "$d" 1 "a retired name in the chat surface fails even when labelled" "FAIL [ui] ui/src/App.tsx:2"

# docs
d="$(plant docs-unlabelled)"; printf '\nYou can ask for an E-Line.\n' >>"$d/docs/reference/constructs.md"
expect "$d" 1 "an unlabelled retired name in documentation fails" "FAIL [docs] docs/reference/constructs.md:5"
d="$(plant docs-labelled)"
printf '\n`vpls` is a migration alias of mac-vrf.\n\n## Migration aliases\n\n| l3vpn | ip-vrf |\n' >>"$d/docs/reference/constructs.md"
expect "$d" 0 "labelled documentation lines and a labelled heading pass"

# dashboards
d="$(plant dashboards)"
printf '{"panels": [{"title": "L2L3-IRB gateways"}]}\n' >"$d/deploy/observability/grafana/dashboards/gw.json"
expect "$d" 1 "a retired name in a dashboard fails" "FAIL [dashboards] deploy/observability/grafana/dashboards/gw.json:1"

# reporting
d="$(plant reporting)"
printf '\n\n\n\n\n\n\n\ndef kind():\n    return "VPLS service"\n' >>"$d/agents/provisioning/deployer/status.py"
expect "$d" 1 "an unlabelled retired name in pre-vocabulary reporting fails" \
  "FAIL [reporting] agents/provisioning/deployer/status.py:12"

# nearest
d="$(plant nearest)"
TR="$(fake_translator bare 'type: evpn-magic is not supported')" \
  expect "$d" 1 "a refusal that does not offer the construct names fails" \
  "FAIL [nearest] tests/unit/testdata/migration/refuse_unknown_construct.json" \
  "FAIL [nearest] tests/unit/testdata/migration/refuse_wrong_var_l2vni_on_vlan.json" \
  "FAIL [nearest] tests/unit/testdata/migration/refuse_wrong_var_gateway_on_ipvrf.json"
TR="$(fake_translator retired 'the constructs are vlan, mac-vrf, ip-vrf, acl; ask for a mac-vrf or a VPLS')" \
  expect "$d" 1 "a refusal offering a retired name fails" \
  "FAIL [nearest] tests/unit/testdata/migration/refuse_unknown_construct.json" \
  "FAIL [nearest] tests/unit/testdata/migration/refuse_wrong_var_l2vni_on_vlan.json" \
  "FAIL [nearest] tests/unit/testdata/migration/refuse_wrong_var_gateway_on_ipvrf.json"
d="$(plant nearest-order)"
printf 'CONSTRUCTS: tuple[str, ...] = ("vlan", "ip-vrf", "mac-vrf", "acl")\n' >"$d/agents/common/guards/refusals.py"
expect "$d" 1 "a refusal construct list out of contract order fails" "FAIL [nearest] agents/common/guards/refusals.py:1"

# this repository, with its run checks
if command -v go >/dev/null; then
  out="$(bash "$VV" 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]]; then pass "this repository passes the vocabulary scan"; else fail "this repository (rc=$rc)" "$out"; fi
else
  echo "SKIP this repository's run checks: no go toolchain on PATH"
fi

if ((fails)); then echo "verify_vocabulary_test: $fails failure(s)"; exit 1; fi
echo "verify_vocabulary_test: PASS"
