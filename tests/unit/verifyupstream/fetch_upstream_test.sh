#!/usr/bin/env bash
# fetch_upstream.sh suite (T035; FR-098): the fetcher fails NAMING THE ARTEFACT it
# could not fetch or verify and NEVER writes a stand-in — nothing lands in the
# tree unless every artefact of the run was fetched and verified.
#
# Offline: a fake `curl` (CURL=…) serves a URL → file map and answers 404 for
# anything else, the way `curl -f` does.
#   every request fails                     → exit 1 naming cert-manager's artefact; nothing written
#   release served, asset download fails    → names the artefact and its URL; nothing written
#   asset bytes differ from the release's published digest → "sha256 mismatch"; nothing written
#   a failed run leaves an existing vendored file byte-for-byte untouched
#   config-server tree lacks a vendored path → names sdc:<path>@<tag>; nothing written
#   config-server tag peels to another commit than the lock's → names sdc:tag <tag>
#   everything served and verified          → the file is written behind its provenance header
#                                             and verify_upstream_artefacts.sh accepts it
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
FU="$ROOT/scripts/lib/fetch_upstream.sh"
VU="$ROOT/scripts/ci/verify_upstream_artefacts.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

# The fake curl: `-o <out> <url>`; URL looked up in $FAKE_CURL_MAP ("<url> <file>" lines).
cat >"$TMP/curl" <<'SH'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H|--retry|--connect-timeout) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
file="$(awk -v u="$url" '$1 == u {print $2; exit}' "${FAKE_CURL_MAP:-/dev/null}")"
if [[ -z "$file" || ! -f "$file" ]]; then
  echo "curl: (22) The requested URL returned error: 404" >&2; exit 22
fi
cp "$file" "$out"
SH
chmod +x "$TMP/curl"
export CURL="$TMP/curl"

CS_COMMIT=bcc56b045a689032c5123a9f50bcf56ed8c630dc
CM_COMMIT=0b9448974868c5669d4f3e7499f5afd393889e22
API=https://api.github.com/repos
F="$TMP/files"; mkdir -p "$F"

# fixture responses
printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: cert-manager\n' >"$F/cm.yaml"
CM_SUM="$(sha256sum "$F/cm.yaml" | cut -d' ' -f1)"
printf '{"ref":"refs/tags/v1.20.4","object":{"type":"commit","sha":"%s"}}' "$CM_COMMIT" >"$F/cm-ref.json"
printf '{"tag_name":"v1.20.4","assets":[{"name":"cert-manager.yaml","browser_download_url":"https://github.com/cert-manager/cert-manager/releases/download/v1.20.4/cert-manager.yaml","digest":"sha256:%s"}]}' "$CM_SUM" >"$F/cm-release.json"
printf '{"tag_name":"v1.20.4","assets":[{"name":"cert-manager.yaml","browser_download_url":"https://github.com/cert-manager/cert-manager/releases/download/v1.20.4/cert-manager.yaml","digest":"sha256:%064d"}]}' 0 >"$F/cm-release-bad.json"
printf '{"ref":"refs/tags/v0.0.58","object":{"type":"commit","sha":"%s"}}' "$CS_COMMIT" >"$F/cs-ref.json"
printf '{"ref":"refs/tags/v0.0.58","object":{"type":"commit","sha":"%040d"}}' 1 >"$F/cs-ref-moved.json"
printf '{"sha":"%s","truncated":false,"tree":[{"path":"artifacts/apiservice.yaml","type":"blob","sha":"%040d"}]}' "$CS_COMMIT" 2 >"$F/cs-tree.json"

lockfile() {
  cat >"$1/versions.lock.yaml" <<YAML
compatibilitySet:
  deviceConfiguration:
    configServer: {repository: https://github.com/sdcio/config-server, tag: v0.0.58, commit: "$CS_COMMIT"}
  allocationAuthorityRelease:
    kuid: {repository: https://github.com/kuidio/kuid, tag: v0.0.13, commit: "7528e81528c2e9f586b6fe657907424ad93c7ead"}
platform:
  certManager:
    version: v1.20.4
    images:
      controller: {pinned: "quay.io/jetstack/cert-manager-controller:v1.20.4@sha256:d4d576c7e6ed3cfe5730f5458fa096b7d8713368d2ccb7ff01b2951861483838"}
YAML
}
# map <file> <url file>… — write the URL map for one case.
map() { local m="$1"; shift; : >"$m"; while [[ $# -gt 0 ]]; do printf '%s %s\n' "$1" "$2" >>"$m"; shift 2; done; }
CM_REF="$API/cert-manager/cert-manager/git/ref/tags/v1.20.4"
CM_REL="$API/cert-manager/cert-manager/releases/tags/v1.20.4"
CM_DL="https://github.com/cert-manager/cert-manager/releases/download/v1.20.4/cert-manager.yaml"

# run_case <name> <--only arg> — sets $out $rc $r (the case root).
run_case() {
  r="$TMP/$1"; mkdir -p "$r"; lockfile "$r"
  out="$(FAKE_CURL_MAP="$TMP/$1.map" bash "$FU" --root "$r" --only "$2" 2>&1)"; rc=$?
}
nothing_written() { [[ -z "$(find "$r/deploy" -type f 2>/dev/null)" && -z "$(find "$r/deploy" -name '.upstream.*' 2>/dev/null)" ]]; }

# 1 — every request fails
map "$TMP/c1.map"
run_case c1 cert-manager
if [[ "$rc" -eq 1 ]] && grep -qF "FAIL artefact 'cert-manager:cert-manager.yaml@v1.20.4' could not be fetched from $CM_REF" <<<"$out" \
   && grep -qF "nothing was written" <<<"$out" && nothing_written; then
  pass "every request fails: exit 1 naming the artefact, nothing written"
else fail "every request fails (rc=$rc)" "$out"; fi

# 2 — asset download fails
map "$TMP/c2.map" "$CM_REF" "$F/cm-ref.json" "$CM_REL" "$F/cm-release.json"
run_case c2 cert-manager
if [[ "$rc" -eq 1 ]] && grep -qF "FAIL artefact 'cert-manager:cert-manager.yaml@v1.20.4' could not be fetched from $CM_DL: curl: (22)" <<<"$out" && nothing_written; then
  pass "asset download fails: names the artefact and its URL, nothing written"
else fail "asset download fails (rc=$rc)" "$out"; fi

# 3 — digest mismatch
map "$TMP/c3.map" "$CM_REF" "$F/cm-ref.json" "$CM_REL" "$F/cm-release-bad.json" "$CM_DL" "$F/cm.yaml"
run_case c3 cert-manager
if [[ "$rc" -eq 1 ]] && grep -qF "'cert-manager:cert-manager.yaml@v1.20.4'" <<<"$out" && grep -qF "sha256 mismatch" <<<"$out" && nothing_written; then
  pass "asset bytes differ from the published digest: fails naming the artefact, nothing written"
else fail "digest mismatch (rc=$rc)" "$out"; fi

# 4 — a failed run leaves the existing vendored file untouched
map "$TMP/c4.map" "$CM_REF" "$F/cm-ref.json" "$CM_REL" "$F/cm-release.json"
r="$TMP/c4"; mkdir -p "$r/deploy/cert-manager/upstream"; printf 'previous vendored bytes\n' >"$r/deploy/cert-manager/upstream/cert-manager.yaml"
before="$(sha256sum "$r/deploy/cert-manager/upstream/cert-manager.yaml")"
run_case c4 cert-manager
after="$(sha256sum "$r/deploy/cert-manager/upstream/cert-manager.yaml")"
if [[ "$rc" -eq 1 && "$before" == "$after" ]] && [[ -z "$(find "$r/deploy" -name '.upstream.*')" ]]; then
  pass "failed run: the existing vendored file is byte-for-byte untouched"
else fail "failed run touched the tree (rc=$rc)" "$out"; fi

# 5 — config-server tree lacks a vendored path
map "$TMP/c5.map" "$API/sdcio/config-server/git/ref/tags/v0.0.58" "$F/cs-ref.json" \
  "$API/sdcio/config-server/git/trees/$CS_COMMIT?recursive=1" "$F/cs-tree.json"
run_case c5 sdc
if [[ "$rc" -eq 1 ]] && grep -qF "FAIL artefact 'sdc:artifacts/ns.yaml@v0.0.58'" <<<"$out" && grep -qF "not present in the tag's tree" <<<"$out" && nothing_written; then
  pass "a path missing at the tag: fails naming sdc:artifacts/ns.yaml@v0.0.58, nothing written"
else fail "missing path (rc=$rc)" "$out"; fi

# 6 — tag moved
map "$TMP/c6.map" "$API/sdcio/config-server/git/ref/tags/v0.0.58" "$F/cs-ref-moved.json"
run_case c6 sdc
if [[ "$rc" -eq 1 ]] && grep -qF "FAIL artefact 'sdc:tag v0.0.58'" <<<"$out" && grep -qF "the lock records $CS_COMMIT" <<<"$out" && nothing_written; then
  pass "tag peels to another commit than the lock's: fails naming sdc:tag v0.0.58"
else fail "moved tag (rc=$rc)" "$out"; fi

# 7 — success
map "$TMP/c7.map" "$CM_REF" "$F/cm-ref.json" "$CM_REL" "$F/cm-release.json" "$CM_DL" "$F/cm.yaml"
run_case c7 cert-manager
v="$r/deploy/cert-manager/upstream/cert-manager.yaml"
printf 'resources: [upstream/cert-manager.yaml]\n' >"$r/deploy/cert-manager/kustomization.yaml"
if [[ "$rc" -eq 0 && -f "$v" ]] \
   && head -n1 "$v" | grep -qF "# provenance: source=$CM_DL version=v1.20.4 commit=$CM_COMMIT digest=sha256:$CM_SUM" \
   && [[ "$(tail -n +4 "$v" | sha256sum | cut -d' ' -f1)" == "$CM_SUM" ]] \
   && vout="$(bash "$VU" --root "$r" 2>&1)"; then
  pass "all served and verified: written behind its provenance header, body unmodified, verify_upstream_artefacts accepts it"
else fail "success path (rc=$rc)" "$out
${vout:-}"; fi

echo "fetch_upstream_test: $([[ $fails -eq 0 ]] && echo PASS || echo "FAIL ($fails)")"
[[ "$fails" -eq 0 ]]
