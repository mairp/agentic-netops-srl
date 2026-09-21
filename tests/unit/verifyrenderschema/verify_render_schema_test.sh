#!/usr/bin/env bash
# tests/unit/verifyrenderschema/verify_render_schema_test.sh — `make verify-render-schema`'s
# identityref handling (T187, AD-81; research Open item 21), offline.
#
# scripts/ci/verify_render_schema.sh is run against a FAKE sdc-lite placed where the script caches
# the pinned binary ($VRS_CACHE/sdc-lite-<tag>/sdc-lite) and a Schema with no commit-pinned
# repository (nothing is fetched). The fake behaves like sdc-lite v0.4.0 as observed on
# 2026-09-21: an unknown identity is refused at `config load` ("identity … not found"); a
# module-prefixed afi-safi-name is refused at `config validate` by the bgp admin-state must, which
# compares the BARE name; the bare form validates. Cases:
#   A  the prefixed golden (fixtures/prefixed) PASSES on a normalised copy, says so, and the golden
#      file is byte-for-byte unchanged; the negative control is reported refused
#   B  the wrong-identity fixture (`srl_nokia-common:ipv4-unicats`) as the golden FAILS — the
#      normalisation does not rescue a wrong identity
#   C  a validator that accepts the prefixed form: PASS as is, no normalisation used
#   D  a golden whose error is NOT the defect's must-signature FAILS without normalisation
#   E  a validator lenient enough to accept the wrong identity once normalised: the built-in
#      negative control PASSES, so the whole run FAILS naming it (NFR-013)
#   F  the copy keeps every module-prefixed KEY (only identityref values are normalised)
#   G  a validator that refuses the wrong identity prefixed but accepts it BARE: the control's
#      normalised copy passes, so the whole run FAILS naming the normalisation (NFR-013)
# shellcheck disable=SC2015,SC2016  # `cond && ok … || bad …` is safe: ok always returns 0; jq in single quotes
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIX="$ROOT/tests/unit/verifyrenderschema/fixtures"
SCRIPT="$ROOT/scripts/ci/verify_render_schema.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -20 | sed 's/^/    /'; fails=$((fails + 1)); }

tag="$(yq -r '.platform.sdcLite.release.tag' "$ROOT/versions.lock.yaml")"
export VRS_CACHE="$TMP/cache"
mkdir -p "$VRS_CACHE/sdc-lite-$tag"
cat >"$VRS_CACHE/sdc-lite-$tag/sdc-lite" <<'FAKE'
#!/usr/bin/env bash
# fake sdc-lite: schema load | config load -t T --file F … | config validate -t T
known='^(ipv4-unicast|ipv6-unicast|evpn|default)$'
cmd="$1 $2"; shift 2
t=""; f=""
while [[ $# -gt 0 ]]; do case "$1" in -t) t="$2"; shift 2 ;; --file) f="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$HOME/fake"
case "$cmd" in
  "schema load") exit 0 ;;
  "config load")
    echo "Target: $t"
    if [[ -z "${FAKE_SDC_LITE_LENIENT:-}" ]]; then
      for v in $(jq -r '[.. | objects | .["afi-safi-name"]? // empty, .type? // empty] | .[]' "$f"); do
        [[ -n "${FAKE_SDC_LITE_BARE_LENIENT:-}" && "$v" != *:* ]] && continue
        [[ "${v##*:}" =~ $known ]] || { echo "Error: identity $v not found, possible values are ipv4-unicast, ipv6-unicast, evpn"; exit 1; }
      done
    fi
    cp "$f" "$HOME/fake/$t.json" ;;
  "config validate")
    f="$HOME/fake/$t.json"
    echo "Target: $t"
    errs=""
    jq -e 'has("srl_nokia-network-instance:network-instance")' "$f" >/dev/null \
      || errs+="error path: /, unknown element network-instance (module prefix of a key lost) "
    if [[ -z "${FAKE_SDC_LITE_FIXED:-}" ]] && jq -e '[.. | objects | .["afi-safi-name"]? // empty] | any(test(":"))' "$f" >/dev/null; then
      names="$(jq -r '[.. | objects | .["afi-safi-name"]? // empty | sub("^[^:]*:"; "")] | map("(../afi-safi[afi-safi-name='"'"'\(.)'"'"']/admin-state = '"'"'enable'"'"')") | join(" or ")' "$f")"
      [[ -n "${FAKE_SDC_LITE_LENIENT:-}" ]] || names="(../afi-safi[afi-safi-name='ipv4-unicast']/admin-state = 'enable') or (../afi-safi[afi-safi-name='evpn']/admin-state = 'enable')"
      errs+="error path: /network-instance[name=default]/protocols/bgp/admin-state, must-statement [ (. = 'disable') or ${names}] One of the address families must be enabled. "
    fi
    grep -q '"vt-invalid"' "$f" && errs+="error path: /interface[name=ethernet-1/1]/description, value vt-invalid refused by a pattern "
    [[ -z "$errs" ]] || printf 'Errors:\n%s\n' "$errs"
    exit 0 ;;
  *) echo "fake sdc-lite: unexpected '$cmd'" >&2; exit 2 ;;
esac
FAKE
chmod +x "$VRS_CACHE/sdc-lite-$tag/sdc-lite"

cat >"$TMP/schema.yaml" <<'Y'
apiVersion: inv.sdcio.dev/v1alpha1
kind: Schema
metadata: {name: fixture, namespace: agentic-netops-system}
spec:
  provider: srl.nokia.sdcio.dev
  version: 25.7.1
  repositories:
  - {repoURL: https://example.invalid/models, kind: tag, ref: v0, dirs: [{src: m, dst: .}], schema: {models: [m]}}
Y
vrs() { bash "$SCRIPT" --schema "$TMP/schema.yaml" "$@" >"$TMP/log" 2>&1; }

# A
sum="$(sha256sum "$FIX/prefixed/leaf01.json" | cut -d' ' -f1)"
if vrs --golden-dir "$FIX/prefixed"; then
  if grep -q "PASS leaf01 — on an identityref-normalised COPY" "$TMP/log" && grep -q "negative control .* refused as is AND on its normalised copy, as it must be" "$TMP/log"; then
    ok "A prefixed golden passes on a normalised copy, the defect named, the control refused"
  else bad "A output does not name the normalised copy and the refused control" "$(cat "$TMP/log")"; fi
else bad "A prefixed golden failed" "$(cat "$TMP/log")"; fi
[[ "$(sha256sum "$FIX/prefixed/leaf01.json" | cut -d' ' -f1)" == "$sum" ]] && ok "A golden unmodified" || bad "A the golden was modified"

# B
if vrs --golden-dir "$FIX/wrong-identity"; then bad "B a wrong identity passed" "$(cat "$TMP/log")"
elif grep -q "not valid against the pinned Schema: leaf01" "$TMP/log" && grep -q "ipv4-unicats" "$TMP/log"; then ok "B a wrong identity fails after normalisation, named"
else bad "B failed without naming the golden and the identity" "$(cat "$TMP/log")"; fi

# C
if FAKE_SDC_LITE_FIXED=1 vrs --golden-dir "$FIX/prefixed"; then
  if grep -qE "normalised COPY|validated on an identityref-normalised copy" "$TMP/log"; then bad "C normalisation used though the validator accepts the prefixed form" "$(cat "$TMP/log")"
  else ok "C a validator accepting the prefixed form validates the golden as is"; fi
else bad "C fixed validator failed" "$(cat "$TMP/log")"; fi

# D
mkdir -p "$TMP/other"
jq '. + {"srl_nokia-interfaces:interface": [{"name": "ethernet-1/1", "description": "vt-invalid"}]}' "$FIX/prefixed/leaf01.json" >"$TMP/other/leaf01.json"
if vrs --golden-dir "$TMP/other"; then bad "D a non-identityref error was masked" "$(cat "$TMP/log")"
elif grep -q "normalised COPY" "$TMP/log"; then bad "D normalisation was used on an error that is not the defect" "$(cat "$TMP/log")"
else ok "D an error that is not the defect's signature fails without normalisation"; fi

# E
if FAKE_SDC_LITE_LENIENT=1 vrs --golden-dir "$FIX/prefixed"; then bad "E a control that passes did not fail the run" "$(cat "$TMP/log")"
elif grep -q "negative control PASSED" "$TMP/log"; then ok "E a passing negative control fails the whole run"
else bad "E failed for another reason" "$(cat "$TMP/log")"; fi

# G
if FAKE_SDC_LITE_BARE_LENIENT=1 vrs --golden-dir "$FIX/prefixed"; then bad "G a control passing on its normalised copy did not fail the run" "$(cat "$TMP/log")"
elif grep -q "negative control PASSED on its identityref-normalised copy" "$TMP/log"; then ok "G a wrong identity accepted once normalised fails the whole run"
else bad "G failed for another reason" "$(cat "$TMP/log")"; fi

# F — the fake refuses a copy that lost a module-prefixed key; A passing already shows it kept them,
# and the normalisation is checked directly on a key that LOOKS like an identityref value
got="$(jq -c --arg re '^srl_nokia-[a-z-]+:[a-z0-9-]+$' 'walk(if type == "string" and test($re) then sub("^srl_nokia-[a-z-]+:"; "") else . end)' \
  <<<'{"srl_nokia-common:evpn": {"afi-safi-name": "srl_nokia-common:evpn", "d": "srl_nokia-x: not-an-idref", "n": 1}}')"
[[ "$got" == '{"srl_nokia-common:evpn":{"afi-safi-name":"evpn","d":"srl_nokia-x: not-an-idref","n":1}}' ]] \
  && ok "F only identityref VALUES are normalised (keys and other strings untouched)" || bad "F normalisation touched a key or a non-identityref: $got"
grep -q 'walk(if type == "string" and test($re) then sub("^srl_nokia-\[a-z-\]+:"; "") else . end)' "$SCRIPT" \
  && ok "F the script normalises with the expression tested here" || bad "F the script's normalisation expression differs from the one tested"

[[ $fails -eq 0 ]] || { echo "verify_render_schema_test: $fails failure(s)"; exit 1; }
echo "verify_render_schema_test: all passed"
