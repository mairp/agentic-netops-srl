#!/usr/bin/env bash
# tests/gate/publish_qualification.sh suite (T046; FR-097, C-21). Offline: a fixture gate record
# (tests/unit/gate/fixtures/gate-record.json) and a fake kubectl that records every apply.
#
# Proves: the ConfigMap is agentic-netops-system/fabric-qualification, applied --server-side; per
# construct and per property (incl. egress ACL, IPv6 anycast gateway, IPv6 Type-5) the values follow
# the gate record — a failed gated property is unqualified while its construct stays qualified, a
# failed required item makes the construct unqualified; qualification.json carries the full
# document; the namespace is created when absent (written whether or not the tier is installed)
# and not touched when present; with an EVIDENCE_DIR the apply is run-captured with the manifest
# attached; a file that is not a gate record is refused.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PUB="$ROOT/tests/gate/publish_qualification.sh"
FIX="$HERE/fixtures/gate-record.json"
DIGEST=sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
# fake kubectl: `get namespace X` succeeds iff $FAKE/ns-present; `apply … -f F` copies F to
# $FAKE/applied.N and logs argv
printf '%s\n' "$*" >>"$FAKE/calls"
a=" $* "
if [[ "$a" == *" get namespace "* ]]; then [[ -f "$FAKE/ns-present" ]]; exit; fi
if [[ "$a" == *" apply "* ]]; then
  f=""; prev=""; for x in "$@"; do [[ "$prev" == -f ]] && f="$x"; prev="$x"; done
  n=$(ls "$FAKE"/applied.* 2>/dev/null | wc -l); cp "$f" "$FAKE/applied.$((n + 1))"; exit 0
fi
echo "fake kubectl: unexpected $*" >&2; exit 1
SH
chmod +x "$TMP/bin/kubectl"

run_pub() { # <fake-dir> [args…]
  local fake="$1"; shift
  env -u EVIDENCE_DIR PATH="$TMP/bin:$PATH" FAKE="$fake" CLUSTER_NAME=agentic-netops bash "$PUB" "$@"
}

# --- 1. content, offline (--dry-run)
F1="$TMP/f1"; mkdir -p "$F1"
cm="$(run_pub "$F1" --record "$FIX" --dry-run 2>/dev/null)"
if jq -e '.kind == "ConfigMap" and .metadata.namespace == "agentic-netops-system" and .metadata.name == "fabric-qualification"
          and .metadata.labels["agentic-netops.io/owned-by"] == "agentic-netops"' <<<"$cm" >/dev/null; then
  pass "the record is ConfigMap agentic-netops-system/fabric-qualification with the ownership label"
else fail "the record is ConfigMap agentic-netops-system/fabric-qualification with the ownership label" "$cm"; fi
if jq -e '.data["acl.egress"] == "unqualified" and .data.acl == "qualified"
          and .data["ip-vrf.evpn-type5-ipv6"] == "unqualified" and .data["ip-vrf"] == "qualified"
          and .data["mac-vrf.anycast-gateway-ipv6"] == "qualified"' <<<"$cm" >/dev/null; then
  pass "gated properties (egress ACL, IPv6 Type-5, IPv6 anycast gateway) follow their own checks; a failed one leaves its construct qualified"
else fail "gated properties (egress ACL, IPv6 Type-5, IPv6 anycast gateway) follow their own checks; a failed one leaves its construct qualified" "$(jq .data <<<"$cm")"; fi
if jq -e '.data["platform.commit-confirmed"] == "unqualified" and .data.vlan == "qualified"
          and .data["mac-vrf.evpn-type2"] == "qualified" and .data["acl.binding-without-filter"] == "qualified"' <<<"$cm" >/dev/null; then
  pass "per-property values follow the gate record (a failed G5 is platform.commit-confirmed unqualified)"
else fail "per-property values follow the gate record" "$(jq .data <<<"$cm")"; fi
q="$(jq -r '.data["qualification.json"]' <<<"$cm")"
if jq -e '.schema == "agentic-netops.fabric-qualification/v1" and .constructs["mac-vrf"].properties["anycast-gateway-ipv6"].gated == true
          and .gate.result == "fail" and .platform["drift-observability"].answer == "restored-without-visible-deviation"
          and .qualifications.slim_tls_keys.client_certificate_verification_exposed == false' <<<"$q" >/dev/null; then
  pass "qualification.json carries the whole document (schema, gated flags, gate result, G13 answer, qualifications)"
else fail "qualification.json carries the whole document" "$q"; fi

# --- 2. a failed required item makes the construct unqualified
jq '.items.G8.status = "fail" | .failed_items += ["G8"]' "$FIX" >"$TMP/g8fail.json"
cm2="$(run_pub "$F1" --record "$TMP/g8fail.json" --dry-run 2>/dev/null)"
if jq -e '.data["mac-vrf"] == "unqualified" and .data["ip-vrf"] == "unqualified" and .data["mac-vrf.anycast-gateway-ipv6"] == "unqualified"
          and .data.acl == "qualified" and .data.vlan == "qualified"' <<<"$cm2" >/dev/null; then
  pass "a failed G8 makes mac-vrf and ip-vrf (and their properties) unqualified, never assumed"
else fail "a failed G8 makes mac-vrf and ip-vrf (and their properties) unqualified" "$(jq .data <<<"$cm2")"; fi

# --- 3. namespace absent: created, then the ConfigMap applied --server-side
F3="$TMP/f3"; mkdir -p "$F3"
if run_pub "$F3" --record "$FIX" >/dev/null 2>&1 \
   && jq -e '.kind == "Namespace" and .metadata.name == "agentic-netops-system"' "$F3/applied.1" >/dev/null 2>&1 \
   && jq -e '.kind == "ConfigMap" and .metadata.name == "fabric-qualification"' "$F3/applied.2" >/dev/null 2>&1 \
   && [[ "$(grep -c -- 'apply --server-side' "$F3/calls")" -eq 2 ]]; then
  pass "with no namespace (tier or not), the namespace is created and the ConfigMap applied --server-side"
else fail "with no namespace, the namespace is created and the ConfigMap applied --server-side" "$(cat "$F3/calls" 2>/dev/null)"; fi

# --- 4. namespace present: only the ConfigMap
F4="$TMP/f4"; mkdir -p "$F4"; : >"$F4/ns-present"
if run_pub "$F4" --record "$FIX" >/dev/null 2>&1 && [[ ! -e "$F4/applied.2" ]] \
   && jq -e '.kind == "ConfigMap"' "$F4/applied.1" >/dev/null 2>&1; then
  pass "an existing namespace is not touched; only the ConfigMap is applied"
else fail "an existing namespace is not touched; only the ConfigMap is applied" "$(cat "$F4/calls" 2>/dev/null)"; fi

# --- 5. run-captured with the manifest attached
F5="$TMP/f5"; mkdir -p "$F5" "$TMP/ev"; : >"$F5/ns-present"
env PATH="$TMP/bin:$PATH" FAKE="$F5" CLUSTER_NAME=agentic-netops EVIDENCE_DIR="$TMP/ev" \
  EVIDENCE_CLUSTER=agentic-netops EVIDENCE_CLUSTER_UID=uid-1 EVIDENCE_LAB=agentic-netops-fabric \
  EVIDENCE_DEVICE_IMAGE_DIGEST="$DIGEST" EVIDENCE_TOPOLOGY=/nonexistent \
  bash "$PUB" --record "$FIX" >/dev/null 2>&1
rec="$(ls "$TMP"/ev/qualification-publish-*.json 2>/dev/null | head -1)"
if [[ -n "$rec" ]] && jq -e '.exit_status == 0 and (.attachments | length) == 1 and (.attachments[0].file | test("^gate/qualification-configmap"))' "$rec" >/dev/null; then
  pass "with an EVIDENCE_DIR the apply is an evidence record with the ConfigMap manifest attached"
else fail "with an EVIDENCE_DIR the apply is an evidence record with the ConfigMap manifest attached" "$(ls -R "$TMP/ev" 2>&1)"; fi

# --- 6. not a gate record
echo '{"schema":"something-else"}' >"$TMP/bogus.json"
if run_pub "$F1" --record "$TMP/bogus.json" --dry-run >/dev/null 2>&1; then
  fail "a file that is not a gate record is refused"
else pass "a file that is not a gate record is refused"; fi

[[ "$fails" -eq 0 ]] || { echo "publish_qualification_test: $fails FAILED"; exit 1; }
echo "publish_qualification_test: all passed"
