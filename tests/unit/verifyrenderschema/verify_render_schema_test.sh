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
# The service goldens (T063) are validated layered on the fabric golden of their node; the fake
# additionally loads a schema whose vxlan-interface type carries the pinned YANG's two
# feature-guarded musts (`srl_nokia-ext:if-feature "not srl_nokia-feat:…"`), which, like sdc-lite
# v0.4.0, it applies regardless of the guard:
#   H  the service fixtures (fixtures/services) PASS layered, on the normalised pair, with each
#      feature-guarded must excused and printed; the service negative control is reported refused
#   I  a feature-guarded must whose feature G3 does NOT require is never excused: the golden FAILS
#   J  a validator that accepts a vxlan-interface type of the wrong kind: the service negative
#      control PASSES, so the whole run FAILS naming it (NFR-013)
#   K  a service golden with no fabric golden of its node to layer on FAILS, named
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
known='^(ipv4-unicast|ipv6-unicast|evpn|default|mac-vrf|ip-vrf|bridged|routed|local-mirror-dest)$'
cmd="$1 $2"; shift 2
t=""; f=""
while [[ $# -gt 0 ]]; do case "$1" in -t) t="$2"; shift 2 ;; --file) f="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$HOME/fake"
case "$cmd" in
  "schema load")
    # the vxlan-interface type musts of the pinned YANG, two of them feature-guarded
    y="$HOME/.cache/sdc-lite/schemas/fake/1/srl_nokia-tunnel-interfaces.yang"; mkdir -p "$(dirname "$y")"
    cat >"$y" <<YANG
      leaf type {
        must ".='srl_nokia-if:bridged' or .='srl_nokia-if:routed'" {
          error-message "unsupported type.";
        }
        must "not(.='srl_nokia-if:bridged')" {
          error-message "unsupported type.";
          srl_nokia-ext:if-feature "not srl_nokia-feat:evpn-vxlan-mac-vrf";
        }
        must "not(.='srl_nokia-if:routed')" {
          error-message "unsupported type.";
          srl_nokia-ext:if-feature "not srl_nokia-feat:${FAKE_SDC_LITE_ROUTED_FEATURE:-evpn-vxlan-ifl}";
        }
      }
YANG
    exit 0 ;;
  "config load")
    echo "Target: $t"
    if [[ -z "${FAKE_SDC_LITE_LENIENT:-}" ]]; then
      for v in $(jq -r '[.. | objects | .["afi-safi-name"]? // empty, .type? // empty] | .[]' "$f"); do
        [[ -n "${FAKE_SDC_LITE_BARE_LENIENT:-}" && "$v" != *:* ]] && continue
        [[ "${v##*:}" =~ $known ]] || { echo "Error: identity $v not found, possible values are ipv4-unicast, ipv6-unicast, evpn"; exit 1; }
      done
    fi
    n="$(find "$HOME/fake" -name "$t.load.*" | wc -l)"; cp "$f" "$HOME/fake/$t.load.$n" ;;
  "config validate")
    # the intents of the target, merged (lists concatenated), priority order
    f="$HOME/fake/$t.json"
    jq -s 'def m(a; b): if (a|type) == "object" and (b|type) == "object" then reduce (b|keys[]) as $k (a; .[$k] = (if has($k) then m(.[$k]; b[$k]) else b[$k] end)) elif (a|type) == "array" and (b|type) == "array" then a + b else b end; reduce .[] as $x ({}; m(.; $x))' \
      $(find "$HOME/fake" -name "$t.load.*" | sort) >"$f"
    echo "Target: $t"
    errs=""
    jq -e 'has("srl_nokia-network-instance:network-instance")' "$f" >/dev/null \
      || errs+="error path: /, unknown element network-instance (module prefix of a key lost) "
    if [[ -z "${FAKE_SDC_LITE_FIXED:-}" ]] && jq -e '[.. | objects | .["afi-safi-name"]? // empty] | any(test(":"))' "$f" >/dev/null; then
      names="$(jq -r '[.. | objects | .["afi-safi-name"]? // empty | sub("^[^:]*:"; "")] | map("(../afi-safi[afi-safi-name='"'"'\(.)'"'"']/admin-state = '"'"'enable'"'"')") | join(" or ")' "$f")"
      [[ -n "${FAKE_SDC_LITE_LENIENT:-}" ]] || names="(../afi-safi[afi-safi-name='ipv4-unicast']/admin-state = 'enable') or (../afi-safi[afi-safi-name='evpn']/admin-state = 'enable')"
      errs+="error path: /network-instance[name=default]/protocols/bgp/admin-state, must-statement [ (. = 'disable') or ${names}] One of the address families must be enabled. "
    fi
    for v in $(jq -r '[.. | objects | .["vxlan-interface"]? // empty | .[]? | .type? // empty] | .[]' "$f"); do
      case "${v##*:}" in
        bridged) errs+="error path: /tunnel-interface[name=vxlan0]/vxlan-interface[index=1]/type, must-statement [not(.='srl_nokia-if:bridged')] unsupported type. " ;;
        routed) errs+="error path: /tunnel-interface[name=vxlan0]/vxlan-interface[index=2]/type, must-statement [not(.='srl_nokia-if:routed')] unsupported type. " ;;
        *) [[ -n "${FAKE_SDC_LITE_ANY_VXLAN_TYPE:-}" ]] || errs+="error path: /tunnel-interface[name=vxlan0]/vxlan-interface[index=3]/type, must-statement [.='srl_nokia-if:bridged' or .='srl_nokia-if:routed'] unsupported type. " ;;
      esac
    done
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
SVC="$FIX/services"
vrs() { bash "$SCRIPT" --schema "$TMP/schema.yaml" --service-golden-dir "$SVC" "$@" >"$TMP/log" 2>&1; }

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

# H
if vrs --golden-dir "$FIX/prefixed"; then
  if grep -q "PASS macvrf-leaf01 (layered on .*prefixed/leaf01.json) — on an identityref-normalised COPY" "$TMP/log" \
    && grep -q "PASS ipvrf-leaf01 (layered on" "$TMP/log" \
    && grep -q "must-statement \[not(.='srl_nokia-if:bridged')\] unsupported type. — guarded by srl_nokia-ext:if-feature \"not srl_nokia-feat:evpn-vxlan-mac-vrf\"; G3 requires evpn-vxlan-mac-vrf" "$TMP/log" \
    && grep -q "guarded by srl_nokia-ext:if-feature \"not srl_nokia-feat:evpn-vxlan-ifl\"" "$TMP/log" \
    && grep -q "service negative control .* refused as is AND on its normalised pair" "$TMP/log" \
    && grep -q "1 fabric, 2 service layered on its node's fabric golden.*2 with feature-guarded musts excused" "$TMP/log"; then
    ok "H service goldens pass layered on their node's fabric golden, each excused must printed, the service control refused"
  else bad "H output does not show the layered passes, the excused musts and the refused service control" "$(cat "$TMP/log")"; fi
else bad "H service goldens failed" "$(cat "$TMP/log")"; fi

# I
if FAKE_SDC_LITE_ROUTED_FEATURE=srv6 vrs --golden-dir "$FIX/prefixed"; then bad "I a must guarded by a feature G3 does not require was excused" "$(cat "$TMP/log")"
elif grep -q "not valid against the pinned Schema: ipvrf-leaf01" "$TMP/log" && ! grep -q "not valid against the pinned Schema:.*macvrf-leaf01" "$TMP/log"; then
  ok "I a must guarded by a feature G3 does not require is not excused: that golden fails, named"
else bad "I failed for another reason" "$(cat "$TMP/log")"; fi

# J
if FAKE_SDC_LITE_ANY_VXLAN_TYPE=1 vrs --golden-dir "$FIX/prefixed"; then bad "J a service control that passes did not fail the run" "$(cat "$TMP/log")"
elif grep -q "service negative control PASSED" "$TMP/log"; then ok "J a passing service negative control fails the whole run"
else bad "J failed for another reason" "$(cat "$TMP/log")"; fi

# K
mkdir -p "$TMP/svc-orphan"; cp "$FIX/services/macvrf-leaf01.json" "$TMP/svc-orphan/macvrf-leaf09.json"
if SVC="$TMP/svc-orphan" vrs --golden-dir "$FIX/prefixed"; then bad "K a service golden with no fabric golden to layer on passed" "$(cat "$TMP/log")"
elif grep -q "not valid against the pinned Schema: macvrf-leaf09" "$TMP/log"; then ok "K a service golden with no fabric golden of its node fails, named"
else bad "K failed for another reason" "$(cat "$TMP/log")"; fi

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
