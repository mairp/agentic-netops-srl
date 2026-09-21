#!/usr/bin/env bash
# verify-pins suite (T009 against T010; NFR-003, FR-104, CR-006, AD-05, AD-12, AD-21, AD-49, AD-50,
# AD-71; data-model.md §23, §26, §28).
#
# Every fixture under testdata/cases/ differs from the valid base (testdata/base/) in ONE defect
# and must make scripts/lib/verify_pins.sh exit non-zero NAMING the offending entry; the zero-exit
# cases (the base itself, whose seven first-party entries are all pending, and the valid variants)
# must pass. Resolution is real: every digest and commit is looked up in its registry or
# repository, so the suite needs the network. Positive lookups are cached for the suite's own run
# in a temp dir (PINS_CACHE_DIR) to keep it quick; nothing is written outside that temp dir.
#
# A negative control closes the suite: the checker is copied and broken (its registry lookup
# replaced by a digest-shaped-string check) and the placeholder-digest case must then no longer
# pass — proving the suite detects a checker that does not resolve.
#
# Usage: bash tests/unit/verifypins/verify_pins_test.sh      (exit 0 only if every case passed)
#        VERIFY_PINS_TEST_VERBOSE=1 … also prints each passing case's verdict lines
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
TD="$HERE/testdata"
VERIFY="$ROOT/scripts/lib/verify_pins.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PINS_CACHE_DIR="$TMP/cache"
export PINS_AGENTS_VENV="$TD/host/venv"
export PLAYWRIGHT_BROWSERS_PATH="$TD/host/browsers"
export PINS_HOST_PATH="$TD/host/bin"
JOBS="${VERIFY_PINS_TEST_JOBS:-6}"

fails=0
passes=0
pass() { printf 'PASS %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
indent() { sed 's/^/    /'; }

for tool in python3 skopeo git yq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL prerequisite: $tool not installed"; exit 1; }
done

# ---- the case table -------------------------------------------------------------------------
# name | verify flags | host variant (bin dir, browsers dir) | want rc | patterns the output must
# contain (grep -E, separated by ' && ')
CASES=(
  "base-pending-only||bin,browsers|0|^pending: srl-provider — Dockerfile absent$ && ^pending: ui — Dockerfile absent$ && ^verify-pins: OK — [1-9][0-9]* registry/repository lookups resolved, 7 pending"
  "base-no-pending|--no-pending|bin,browsers|1|FAIL .*firstPartyImages\[ui\]: docker/Dockerfile.ui: pending — Dockerfile absent; --no-pending"
  "base-host-tooling|--host-tooling|bin,browsers|0|verify-pins: OK — .*host tooling checked"
  "placeholder-digest||bin,browsers|1|FAIL .*observability.prometheus.digest: .*sha256:0{64}.*does not resolve"
  "latest-tag||bin,browsers|1|FAIL .*observability.grafana.tag: .*'latest' is forbidden"
  "floating-minor-tag||bin,browsers|1|FAIL .*observability.prometheus.tag: quay.io/prometheus/prometheus:v3.14@.*floating"
  "schema-branch-ref||bin,browsers|1|FAIL .*compatibilitySet.schema.repositories\[0\].kind: .*@branch:main: branch reference"
  "grafana-plugin-no-version||bin,browsers|1|FAIL .*observability.grafanaPlugins\[andrewbmchugh-flow-panel\].version: .*no version"
  "topology-generator-no-version||bin,browsers|1|FAIL .*observability.topologyGenerator.tag: ghcr.io/srl-labs/clab-io-draw:<no tag>.*omitted"
  "digest-not-resolving||bin,browsers|1|FAIL .*platform.slim.digest: ghcr.io/agntcy/slim:0.6.1@sha256:.*does not resolve"
  "allocator-first-party-no-refs||bin,browsers|1|FAIL .*allocationAuthority.decisionRecord: <missing> && FAIL .*allocationAuthority.failedGateEvidence: <missing>"
  "allocator-first-party-no-evidence||bin,browsers|1|FAIL .*allocationAuthority.failedGateEvidence: <missing>"
  "allocator-first-party-record-unresolvable||bin,browsers|1|FAIL .*allocationAuthority.decisionRecord: docs/decisions/allocator-substitution-missing.md: does not resolve"
  "allocator-first-party-evidence-unresolvable||bin,browsers|1|FAIL .*allocationAuthority.failedGateEvidence.path: evidence/g11-missing.json: evidence file does not exist"
  "allocator-first-party-evidence-hash-differs||bin,browsers|1|FAIL .*allocationAuthority.failedGateEvidence.sha256: 0{64}: differs"
  "allocator-first-party-ok||bin,browsers|0|verify-pins: OK"
  "allocator-return-missing||bin,browsers|1|FAIL .*allocationAuthority.kind: kuid: .*records an adoption .* no later dated return entry"
  "allocator-return-no-date||bin,browsers|1|FAIL docs/decisions/allocator-substitution.md: allocationAuthority: .*return entry at line 6 has no date"
  "allocator-return-no-reason||bin,browsers|1|FAIL docs/decisions/allocator-substitution.md: allocationAuthority: .*return entry at line 6 states no reason"
  "allocator-return-ok||bin,browsers|0|verify-pins: OK"
  "exception-exceptions-field||bin,browsers|1|FAIL .*: exceptions: <block>: declares a pin exception"
  "exception-allow-unpinned||bin,browsers|1|FAIL .*platform.clickhouse.allowUnpinned: true: declares a pin exception"
  "exception-skip-verify||bin,browsers|1|FAIL .*compatibilitySet.gnmic.image.skipVerify: true: declares a pin exception"
  "host-browser-automation-ranged|--host-tooling|bin,browsers|1|FAIL .*hostTooling.browserAutomation.version: playwright >=1.63.0: .*ranged"
  "host-browser-revision-recorded-differs|--host-tooling|bin,browsers|1|FAIL .*hostTooling.browserAutomation.browserRevision: 1234: the locked package fixes chromium revision 1243"
  "host-browser-revision-installed-differs|--host-tooling|bin,browsers-other|1|FAIL .*hostTooling.browserAutomation.browserRevision: chromium-1243: installed browser revision differs.*installed: chromium-1234"
  "host-capture-tool-missing|--host-tooling|bin-no-xvfb,browsers|1|FAIL .*hostTooling.capture\[Xvfb\].version: Xvfb: capture tool missing"
  "host-capture-tool-different-version|--host-tooling|bin-other-ffmpeg,browsers|1|FAIL .*hostTooling.capture\[ffmpeg\].version: ffmpeg 6.1.1-3ubuntu5: host version differs from the recorded 7.1.5-0\+deb13u1"
  "first-party-built-ok||bin,browsers|0|verify-pins: OK — .*, 6 pending && ^pending: mapper — "
  "first-party-from-tag-only||bin,browsers|1|FAIL docker/Dockerfile.supervisor: firstPartyImages\[supervisor\].from\[0\]: python:3.13.0-slim: FROM at docker/Dockerfile.supervisor:1 is not pinned by digest"
  "first-party-from-digest-differs||bin,browsers|1|FAIL docker/Dockerfile.supervisor: firstPartyImages\[supervisor\].from\[0\].digest: .*digest differs from the lock file's"
  "first-party-dependency-lock-differs||bin,browsers|1|FAIL .*firstPartyImages\[supervisor\].dependencyLocks\[agents/uv.lock\].sha256: agents/uv.lock: file SHA-256 is"
  "first-party-manifest-latest||bin,browsers|1|FAIL deploy/supervisor.yaml: firstPartyImages\[supervisor\]: deploy/supervisor.yaml:9: references supervisor:latest"
  "first-party-manifest-mutable-tag||bin,browsers|1|FAIL deploy/supervisor.yaml: firstPartyImages\[supervisor\]: deploy/supervisor.yaml:9: references supervisor:v1.2.0"
  "go-toolchain-differs||bin,browsers|1|FAIL .*goToolchain.toolchain: go1.26.3: lock file records go1.26.3, go.mod states go1.27.1"
  "pending-referenced-by-manifest||bin,browsers|1|^pending: mapper — Dockerfile absent$ && FAIL deploy/mapper.yaml: firstPartyImages\[mapper\]: deploy/mapper.yaml:9: references image mapper while its Dockerfile docker/Dockerfile.mapper is absent"
  "pending-referenced-by-script||bin,browsers|1|FAIL scripts/build_images.sh: firstPartyImages\[allocator\]: scripts/build_images.sh:2: references image allocator"
  "pending-referenced-by-makefile||bin,browsers|1|FAIL Makefile: firstPartyImages\[deployer\]: Makefile:2: references image deployer"
  "pending-docker-dockerfile-without-entry||bin,browsers|1|FAIL docker/Dockerfile.telemetry-bridge: firstPartyImages: docker/Dockerfile.telemetry-bridge: Dockerfile under docker/ has no firstPartyImages entry"
  "pending-from-digest-unresolvable||bin,browsers|1|^pending: ui — Dockerfile absent$ && FAIL .*firstPartyImages\[ui\].from\[0\].digest: node:20.*sha256:0{64}: digest does not resolve"
)

# setup_case <name> <dir>: base tree + the case's overlay; prints the lock path to use
setup_case() {
  local name="$1" dir="$2"
  mkdir -p "$dir/root"
  cp -R "$TD/base/." "$dir/root/"
  if [[ -d "$TD/cases/$name/tree" ]]; then cp -R "$TD/cases/$name/tree/." "$dir/root/"; fi
  if [[ -f "$TD/cases/$name/lock.yaml" ]]; then cp "$TD/cases/$name/lock.yaml" "$dir/root/versions.lock.yaml"; fi
}

# run_case <name> <flags> <host> <verify script>: output to $TMP/out/<name>.{out,rc}
run_case() {
  local name="$1" flags="$2" host="$3" verify="$4"
  local dir="$TMP/work/$name" bin="${host%%,*}" browsers="${host##*,}"
  rm -rf "$dir"
  setup_case "$name" "$dir"
  # shellcheck disable=SC2086
  PINS_HOST_PATH="$TD/host/$bin" PLAYWRIGHT_BROWSERS_PATH="$TD/host/$browsers" \
    bash "$verify" --lock "$dir/root/versions.lock.yaml" --root "$dir/root" $flags \
    >"$TMP/out/$name.out" 2>&1
  echo $? >"$TMP/out/$name.rc"
}

# check_case <label> <name> <want rc> <patterns>
check_case() {
  local label="$1" name="$2" want="$3" pats="$4" rc out p
  rc="$(cat "$TMP/out/$name.rc")"
  out="$(cat "$TMP/out/$name.out")"
  if [[ "$rc" != "$want" ]]; then
    fail "$label (rc=$rc, want $want)"; indent <<<"$out"; return 1
  fi
  while IFS= read -r p; do
    if ! grep -qE -- "$p" <<<"$out"; then
      fail "$label (output lacks /$p/)"; indent <<<"$out"; return 1
    fi
  done < <(printf '%s\n' "${pats// && /$'\n'}")
  pass "$label"
  if [[ -n "${VERIFY_PINS_TEST_VERBOSE:-}" ]]; then grep -E '^(FAIL|pending:|verify-pins:)' <<<"$out" | indent; fi
}

mkdir -p "$TMP/out" "$TMP/work"

# 0. fixture integrity: every case directory is in the table and vice versa
declare -A listed=()
for c in "${CASES[@]}"; do listed["${c%%|*}"]=1; done
for d in "$TD"/cases/*/; do
  n="$(basename "$d")"
  [[ -n "${listed[$n]:-}" ]] || fail "fixture testdata/cases/$n has no case in the table"
done
for n in "${!listed[@]}"; do
  [[ "$n" == base-* || -d "$TD/cases/$n" ]] || fail "case $n has no fixture directory"
done

# 1. the CLI: an unknown option is a usage error (exit 2), not a pass
bash "$VERIFY" --no-such-flag >"$TMP/out/cli.out" 2>&1; rc=$?
if [[ "$rc" -eq 2 ]] && grep -q 'unknown argument: --no-such-flag' "$TMP/out/cli.out"; then
  pass "cli: unknown option exits 2"
else
  fail "cli: unknown option (rc=$rc)"; sed 's/^/    /' "$TMP/out/cli.out"
fi

# 2. warm the cache with the base, then every case in parallel, then judge them in table order
run_case base-pending-only "" "bin,browsers" "$VERIFY"
running=0
for c in "${CASES[@]}"; do
  IFS='|' read -r name flags host want pats <<<"$c"
  [[ "$name" == base-pending-only ]] && continue
  run_case "$name" "$flags" "$host" "$VERIFY" &
  running=$((running + 1))
  if [[ "$running" -ge "$JOBS" ]]; then wait -n; running=$((running - 1)); fi
done
wait
for c in "${CASES[@]}"; do
  IFS='|' read -r name flags host want pats <<<"$c"
  check_case "$name${flags:+ ($flags)}: exit $want" "$name" "$want" "$pats"
done

# 3. negative control: a checker whose registry lookup is a digest-shaped-string check must NOT
#    pass the placeholder-digest case — the suite has to catch it.
mkdir -p "$TMP/broken/scripts/lib"
cp -R "$ROOT/scripts/lib/pins" "$TMP/broken/scripts/lib/"
cp "$VERIFY" "$TMP/broken/scripts/lib/verify_pins.sh"
python3 - "$TMP/broken/scripts/lib/pins/pins.py" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
old = "    def image_digest_resolves(self, repo: str, digest: str) -> tuple[bool, str]:\n"
assert old in t, "negative control: sabotage point not found"
t = t.replace(old, old + "        return (True, digest) if DIGEST_RE.match(digest) else (False, 'not a digest')  # SABOTAGE\n")
open(p, "w").write(t)
PY
PINS_CACHE_DIR="$TMP/broken-cache" run_case placeholder-digest "" "bin,browsers" "$TMP/broken/scripts/lib/verify_pins.sh"
if ( check_case "negative-control probe" placeholder-digest 1 "does not resolve" ) >"$TMP/out/nc.txt" 2>&1; then
  fail "negative control: a shape-checking verifier passed the placeholder-digest case — the suite cannot tell"
else
  pass "negative control: a verifier that only checks digest shape is caught by placeholder-digest (probe output: $(head -1 "$TMP/out/nc.txt"))"
fi

echo "verify_pins_test: $passes passed, $fails failed"
[[ "$fails" -eq 0 ]]
