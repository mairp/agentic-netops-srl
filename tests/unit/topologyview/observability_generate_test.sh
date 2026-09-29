#!/usr/bin/env bash
# scripts/lib/observability.sh topology generator step suite (T131; FR-094, FR-096, R-10).
#
# Offline: a fake `docker` on PATH records its arguments and writes the committed clab-io-draw
# 0.7.1 fixture (internal/topologyview/testdata/clab-io-draw-0.7.1) where the real image would;
# the Go half (internal/topologyview/cmd/topologyview) is built once and run for real; a fake
# kubectl (KUBECTL=…) records every call; no cluster, no registry.
#
# Proves, one behaviour per check:
#   - generate runs the generator image exactly as versions.lock.yaml pins it (tag@digest, the
#     lock's own string), offline, over topology.clab.yml with the Grafana bundle and the e1-N
#     interface format — never `latest`, never an unpinned reference;
#   - it writes gnmic-targets.txt (onboarding::hosts' lines), topology.svg, topology-panel.yaml,
#     topology-rules.yaml and inventory-digest.txt (the sha256 of the inventory it read);
#   - a lock pinning `latest`, or a reference without a digest, is refused before docker runs;
#   - a failing generator fails the step and writes nothing;
#   - configmaps renders monitoring/topology-assets and monitoring/prometheus-topology-rules,
#     ownership-labelled, whose data are the generated files byte for byte;
#   - install applies both server-side under KUBE_CONTEXT; assets of another inventory, or an
#     existing ConfigMap another cluster owns, are refused and nothing is applied.
# shellcheck disable=SC2015 # pass() always succeeds, so `cond && pass || fail` is if-then-else here
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$ROOT/scripts/lib/observability.sh"
FIXTURE="$ROOT/internal/topologyview/testdata/clab-io-draw-0.7.1"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

GO_BIN="${GO:-$(command -v go || echo /usr/lib/go-1.24/bin/go)}"
(cd "$ROOT" && "$GO_BIN" build -o "$TMP/topologyview" ./internal/topologyview/cmd/topologyview) \
  || { echo "FAIL building internal/topologyview/cmd/topologyview"; exit 1; }
export OBSERVABILITY_TOPOLOGYVIEW_BIN="$TMP/topologyview"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
# fake docker: image/pull/tag (observability::ensure_image) go to their own log; `run` records
# the argv (one arg per line, then a separator) and plays clab-io-draw
case "${1:-}" in
  image) echo "image $*" >>"$FAKE_DOCKER_LOG.aux"; [[ "${FAKE_IMAGE_ABSENT:-}" == 1 && ! -e "$FAKE_DOCKER_LOG.pulled" ]] && exit 1; exit 0 ;;
  pull)
    n=$(( $(cat "$FAKE_DOCKER_LOG.pulls" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$FAKE_DOCKER_LOG.pulls"
    echo "pull $2" >>"$FAKE_DOCKER_LOG.aux"
    (( n <= ${FAKE_PULL_FAILS:-0} )) && exit 1
    : >"$FAKE_DOCKER_LOG.pulled"; exit 0 ;;
  tag) echo "tag $2 $3" >>"$FAKE_DOCKER_LOG.aux"; exit 0 ;;
esac
{ printf '%s\n' "$@"; echo '--'; } >>"$FAKE_DOCKER_LOG"
[[ "${FAKE_DOCKER_FAIL:-}" == 1 ]] && { echo "boom" >&2; exit 3; }
dir=""; prev=""
for a in "$@"; do [[ "$prev" == "-v" ]] && dir="${a%%:/data}"; prev="$a"; done
[[ -f "$dir/topology.clab.yml" ]] || { echo "no input in $dir" >&2; exit 4; }
cp "$FAKE_FIXTURE"/topology.clab.* "$dir/"
SH
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH" FAKE_DOCKER_LOG="$TMP/docker.log" FAKE_FIXTURE="$FIXTURE"
unset DOCKER

REF="$(yq -r '.observability.topologyGenerator.pinned' "$ROOT/versions.lock.yaml")"

# 1. generate: the pinned reference, verbatim from the lock, offline, never latest
: >"$FAKE_DOCKER_LOG"
out="$TMP/out"
log="$(bash -c "source '$LIB'; observability::generate '$out'" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then pass "generate exits 0"; else fail "generate exit $rc" "$log"; fi
argv="$(cat "$FAKE_DOCKER_LOG")"
runs="$(grep -c '^--$' "$FAKE_DOCKER_LOG")"
[[ "$runs" == 1 ]] && pass "docker runs once" || fail "docker ran $runs times" "$argv"
[[ "$(sed -n 1p "$FAKE_DOCKER_LOG")" == run ]] && pass "docker run" || fail "not docker run" "$argv"
grep -qxF -- "$REF" "$FAKE_DOCKER_LOG" && [[ "$REF" == *:0.7.1@sha256:* ]] \
  && pass "image is the lock's pinned ref ($REF)" || fail "image is not the lock's pinned ref $REF" "$argv"
! grep -qi 'latest' "$FAKE_DOCKER_LOG" && pass "no 'latest' anywhere in the docker argv" || fail "'latest' in argv" "$argv"
imgs="$(grep -c 'clab-io-draw' "$FAKE_DOCKER_LOG")"
[[ "$imgs" == 1 ]] && pass "exactly one image reference" || fail "$imgs image references" "$argv"
want_seq=$'--network\nnone'
[[ "$argv" == *"$want_seq"* ]] && pass "runs offline (--network none)" || fail "not --network none" "$argv"
for seq in $'-i\ntopology.clab.yml' $'-g' $'--theme\ngrafana' $'--grafana-interface-format\nethernet-{x}/{x}:e{x}-{x}'; do
  [[ "$argv" == *"$seq"* ]] && pass "argv carries ${seq//$'\n'/ }" || fail "argv lacks ${seq//$'\n'/ }" "$argv"
done

# 1b. the pinned image held locally (T151 r9): present → no pull, tagged under its pinned tag so
#     a dangling-image prune cannot remove it; absent → pulled by the pinned ref, with retries;
#     every pull failing → the step fails before docker run
aux="$FAKE_DOCKER_LOG.aux"
grep -q '^pull ' "$aux" && fail "a present image was pulled" "$(cat "$aux")" || pass "present image: not pulled"
grep -qxF "tag $REF ${REF%@sha256:*}" "$aux" && pass "present image held under its pinned tag ${REF%@sha256:*}" \
  || fail "pinned image not held under its tag" "$(cat "$aux")"
: >"$FAKE_DOCKER_LOG"; : >"$aux"; rm -f "$FAKE_DOCKER_LOG.pulls" "$FAKE_DOCKER_LOG.pulled"
log="$(FAKE_IMAGE_ABSENT=1 FAKE_PULL_FAILS=2 OBSERVABILITY_PULL_BACKOFF_S=0 bash -c "source '$LIB'; observability::generate '$TMP/out-pull'" 2>&1)"; rc=$?
pulls="$(grep -c "^pull $REF\$" "$aux")"
[[ $rc -eq 0 && "$pulls" == 3 && "$(grep -c '^--$' "$FAKE_DOCKER_LOG")" == 1 ]] \
  && pass "absent image: pulled by the pinned ref, two failures retried, then run" \
  || fail "absent image: exit $rc, $pulls pull(s)" "$log"$'\n'"$(cat "$aux")"
: >"$FAKE_DOCKER_LOG"; : >"$aux"; rm -f "$FAKE_DOCKER_LOG.pulls" "$FAKE_DOCKER_LOG.pulled"
log="$(FAKE_IMAGE_ABSENT=1 FAKE_PULL_FAILS=99 OBSERVABILITY_PULL_ATTEMPTS=3 OBSERVABILITY_PULL_BACKOFF_S=0 bash -c "source '$LIB'; observability::generate '$TMP/out-nopull'" 2>&1)"; rc=$?
[[ $rc -ne 0 && ! -s "$FAKE_DOCKER_LOG" && "$(grep -c '^pull ' "$aux")" == 3 && "$log" == *"3 pull attempt(s) failed"* ]] \
  && pass "unpullable image: 3 attempts, the step fails naming it, docker run never reached" \
  || fail "unpullable image: exit $rc" "$log"$'\n'"$(cat "$aux")"
: >"$aux"

# 2. the outputs
for f in gnmic-targets.txt topology.svg topology-panel.yaml topology-rules.yaml inventory-digest.txt; do
  [[ -s "$out/$f" ]] && pass "writes $f" || fail "missing $f" "$(ls -la "$out" 2>&1)"
done
want="$(bash -c "source '$ROOT/scripts/lib/onboarding.sh'; onboarding::hosts 172.25.25.0/24")"
[[ "$(cat "$out/gnmic-targets.txt" 2>/dev/null)" == "$want" ]] \
  && pass "gnmic-targets.txt is onboarding::hosts' address plan" || fail "gnmic-targets.txt differs" "$(cat "$out/gnmic-targets.txt" 2>&1)"$'\n'"want:"$'\n'"$want"
digest="$(sha256sum "$ROOT/lab/topology.clab.yml" | awk '{print $1}')"
[[ "$(cat "$out/inventory-digest.txt" 2>/dev/null)" == "$digest  topology.clab.yml" ]] \
  && pass "inventory-digest.txt is the inventory's sha256" || fail "inventory digest" "$(cat "$out/inventory-digest.txt" 2>&1) vs $digest"
grep -q 'id="cell-link_id:leaf01:e1-49:spine01:e1-1"' "$out/topology.svg" 2>/dev/null \
  && pass "svg cells are on the join (cell-link_id:leaf01:e1-49:…)" || fail "svg cell ids"
grep -q 'record: agentic_netops_fabric_link_info' "$out/topology-rules.yaml" 2>/dev/null \
  && pass "rules record agentic_netops_fabric_link_info" || fail "rules"

# 3. a lock pinning latest, or no digest, is refused before docker runs
for bad in 'ghcr.io/srl-labs/clab-io-draw:latest' 'ghcr.io/srl-labs/clab-io-draw:0.7.1'; do
  sed "s|pinned: \"${REF}\"|pinned: \"${bad}\"|" "$ROOT/versions.lock.yaml" >"$TMP/lock.yaml"
  grep -qF "pinned: \"${bad}\"" "$TMP/lock.yaml" || { fail "lock mutation to $bad did not apply"; continue; }
  : >"$FAKE_DOCKER_LOG"; rm -rf "$TMP/bad"
  log="$(OBSERVABILITY_LOCK="$TMP/lock.yaml" bash -c "source '$LIB'; observability::generate '$TMP/bad'" 2>&1)"; rc=$?
  [[ $rc -ne 0 && ! -s "$FAKE_DOCKER_LOG" ]] && pass "lock pinning $bad refused, docker not run" \
    || fail "lock pinning $bad: exit $rc, docker log $(wc -l <"$FAKE_DOCKER_LOG")" "$log"
done
sed 's|^    tag: 0.7.1$|    tag: latest|' "$ROOT/versions.lock.yaml" >"$TMP/lock.yaml"
: >"$FAKE_DOCKER_LOG"
log="$(OBSERVABILITY_LOCK="$TMP/lock.yaml" bash -c "source '$LIB'; observability::generate '$TMP/bad'" 2>&1)"; rc=$?
[[ $rc -ne 0 && ! -s "$FAKE_DOCKER_LOG" ]] && pass "tag latest in the lock refused" || fail "tag latest: exit $rc" "$log"

# 4. a failing generator fails the step and writes nothing
: >"$FAKE_DOCKER_LOG"; rm -rf "$TMP/fail"
log="$(FAKE_DOCKER_FAIL=1 bash -c "source '$LIB'; observability::generate '$TMP/fail'" 2>&1)"; rc=$?
[[ $rc -ne 0 && -z "$(ls -A "$TMP/fail" 2>/dev/null)" && "$log" == *boom* ]] \
  && pass "failing clab-io-draw fails the step, its output shown, nothing written" || fail "failing generator: exit $rc" "$log"

# 5. configmaps
cms="$(bash -c "source '$LIB'; observability::configmaps '$out'" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && pass "configmaps renders" || fail "configmaps exit $rc" "$cms"
if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
  chk="$(printf '%s\n' "$cms" | python3 -c '
import sys, yaml
out = sys.argv[1]
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
names = {d["metadata"]["name"]: d for d in docs}
want = {"topology-assets": {"topology.svg": "topology.svg", "topology-panel.yaml": "topology-panel.yaml", "gnmic-targets.txt": "gnmic-targets.txt", "inventory-digest.txt": "inventory-digest.txt"},
        "prometheus-topology-rules": {"topology.yaml": "topology-rules.yaml"}}
assert set(names) == set(want), sorted(names)
for n, keys in want.items():
    d = names[n]
    assert d["kind"] == "ConfigMap" and d["metadata"]["namespace"] == "monitoring", n
    assert d["metadata"]["labels"]["agentic-netops.io/owned-by"] == "agentic-netops", n
    assert set(d["data"]) == set(keys), (n, sorted(d["data"]))
    for k, f in keys.items():
        assert d["data"][k] == open(out + "/" + f, encoding="utf-8").read(), (n, k)
print("ok")' "$out" 2>&1)"
  [[ "$chk" == ok ]] && pass "ConfigMaps topology-assets + prometheus-topology-rules carry the files byte for byte, ownership-labelled" || fail "configmaps content" "$chk"
else
  grep -q '^  name: topology-assets$' <<<"$cms" && grep -q '^  name: prometheus-topology-rules$' <<<"$cms" \
    && pass "ConfigMap names (PyYAML absent: names only)" || fail "configmap names" "$cms"
fi

# 6. install: server-side under KUBE_CONTEXT; refusals apply nothing
cat >"$TMP/kubectl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_KUBECTL_LOG"
args=" $* "
case "$args" in
  *" get namespace "*) exit 0 ;;
  *" get configmap "*" -o name "*) [[ -n "${FAKE_CM_OWNER:-}" ]] && { echo configmap/x; exit 0; }; exit 1 ;;
  *" get configmap "*" -o json "*) printf '{"metadata":{"labels":{"agentic-netops.io/owned-by":"%s"}}}\n' "$FAKE_CM_OWNER"; exit 0 ;;
  *" apply "*) cat >>"$FAKE_KUBECTL_LOG.apply"; exit 0 ;;
esac
exit 1
SH
chmod +x "$TMP/kubectl"
export KUBECTL="$TMP/kubectl" KUBE_CONTEXT=kind-test FAKE_KUBECTL_LOG="$TMP/kubectl.log"

: >"$FAKE_KUBECTL_LOG"; rm -f "$FAKE_KUBECTL_LOG.apply"
log="$(bash -c "source '$LIB'; observability::install_assets '$out'" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q -- '--context kind-test apply --server-side --field-manager=agentic-netops-provision -f -' "$FAKE_KUBECTL_LOG" \
  && [[ "$(grep -c '^kind: ConfigMap$' "$FAKE_KUBECTL_LOG.apply" 2>/dev/null)" == 2 ]]; then
  pass "install applies both ConfigMaps server-side under KUBE_CONTEXT"
else
  fail "install: exit $rc" "$log"$'\n'"$(cat "$FAKE_KUBECTL_LOG")"
fi

: >"$FAKE_KUBECTL_LOG"; rm -f "$FAKE_KUBECTL_LOG.apply"
log="$(FAKE_CM_OWNER=agentic-netops bash -c "source '$LIB'; observability::install_assets '$out'" 2>&1)"; rc=$?
[[ $rc -eq 0 && -s "$FAKE_KUBECTL_LOG.apply" ]] && pass "install updates ConfigMaps this cluster owns" || fail "owned update: exit $rc" "$log"

: >"$FAKE_KUBECTL_LOG"; rm -f "$FAKE_KUBECTL_LOG.apply"
log="$(FAKE_CM_OWNER=agentic-netops-2 bash -c "source '$LIB'; observability::install_assets '$out'" 2>&1)"; rc=$?
[[ $rc -ne 0 && ! -e "$FAKE_KUBECTL_LOG.apply" ]] && pass "a ConfigMap another cluster owns is refused, nothing applied" || fail "foreign owner: exit $rc" "$log"

cp -r "$out" "$TMP/stale"
echo "0000000000000000000000000000000000000000000000000000000000000000  topology.clab.yml" >"$TMP/stale/inventory-digest.txt"
: >"$FAKE_KUBECTL_LOG"; rm -f "$FAKE_KUBECTL_LOG.apply"
log="$(bash -c "source '$LIB'; observability::install_assets '$TMP/stale'" 2>&1)"; rc=$?
[[ $rc -ne 0 && ! -s "$FAKE_KUBECTL_LOG" && "$log" == *"run observability::generate again"* ]] \
  && pass "assets of another inventory are refused before kubectl" || fail "stale assets: exit $rc" "$log"

if [[ $fails -eq 0 ]]; then echo "all passed"; exit 0; fi
echo "$fails failure(s)"; exit 1
