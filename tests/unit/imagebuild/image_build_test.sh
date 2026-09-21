#!/usr/bin/env bash
# image_build_test.sh — scripts/lib/image_build.sh on temporary fixture trees with fake docker /
# kind (T169; NFR-003, AD-05, R-43; data-model.md §26).
#
# Asserts: same tree → same tag (and path-independent); one changed byte → a different tag (in a
# tracked file, in the Dockerfile, in the executable bit); a change in an untracked file (ignored by
# .gitignore / .dockerignore, node_modules, a nested repository) → the same tag; a tag-only FROM is
# refused, as are a digest or ref differing from the lock, a build-argument FROM and a tag-only
# COPY --from; a verify-pins failure for this image (or a pin check that cannot run) refuses the
# build, one for another image does not; a build prints <name>:<64-hex>, builds from exactly the
# hashed files, `kind load`s the tag, writes only the kustomization's images: override and records
# the image ID through evidence_run; a re-run does not rebuild. No docker, no network, no cluster.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../lifecycle/fakes.sh
source "$ROOT/tests/unit/lifecycle/fakes.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; [[ -n "${out:-}" ]] && printf '%s\n' "$out" | tail -n 12 | sed 's/^/    | /'; fi; }

ALP="sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6"
GOL="sha256:4cb7ac979db5fcc41cae44b2227ba5ab8a51e8807f40d9ba4dee20a0ad960b5b"
IMG=demo-img

# make_tree <dir> — a fixture tree: lock entry, Dockerfile, build context, kustomization.
make_tree() {
  local d="$1"
  mkdir -p "$d/docker" "$d/app/sub" "$d/app/node_modules/x" "$d/app/build" "$d/app/vendored/.git" "$d/deploy/demo" "$d/bin"
  cat >"$d/versions.lock.yaml" <<EOF
lockVersion: 1
firstPartyImages:
  - name: $IMG
    dockerfile: docker/Dockerfile.$IMG
    context: app
    from:
      - {ref: golang, tag: "1.27.1-alpine", digest: "$GOL"}
      - {ref: alpine, tag: 3.24.2, digest: "$ALP"}
  - name: other-img
    dockerfile: docker/Dockerfile.other-img
    context: app
    from:
      - {ref: alpine, tag: 3.24.2, digest: "$ALP"}
EOF
  cat >"$d/docker/Dockerfile.$IMG" <<EOF
# fixture
FROM golang:1.27.1-alpine@$GOL AS build
WORKDIR /src
COPY . .
FROM alpine:3.24.2@$ALP
COPY --from=build /src/main.txt /main.txt
EOF
  printf 'hello\n' >"$d/app/main.txt"
  printf '#!/bin/sh\necho hi\n' >"$d/app/sub/run.sh"; chmod +x "$d/app/sub/run.sh"
  printf 'debug\n' >"$d/app/debug.log"
  printf 'dep\n' >"$d/app/node_modules/x/index.js"
  printf 'artefact\n' >"$d/app/build/out.bin"
  printf 'upstream\n' >"$d/app/vendored/README"
  printf 'secret-ish\n' >"$d/app/local.env"
  printf 'build/\n*.env\n' >"$d/app/.dockerignore"
  printf '*.log\nbin/\n' >"$d/.gitignore"
  cat >"$d/deploy/demo/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# owned by another stream: only images: may change
resources:
  - deployment.yaml
images:
  - name: unrelated
    newTag: keepme
EOF
}

setup() {
  W="$T/$1"; rm -rf "$W"; mkdir -p "$W"
  fakes::install "$W"
  export FAKE_STATE="$W/state" PATH="$W/bin:$ORIG_PATH" CLUSTER_NAME=agentic-netops
  export EVIDENCE_ROOT="$W/evidence" EVIDENCE_LAB=agentic-netops-fabric EVIDENCE_CLUSTER_UID=test-uid
  unset EVIDENCE_DIR IMAGE_BUILD_KUSTOMIZATION || true
  fakes::cluster agentic-netops agentic-netops
  make_tree "$W/tree"
  export IMAGE_BUILD_ROOT="$W/tree"
  printf '#!/usr/bin/env bash\necho "verify_pins $*" >>"$FAKE_STATE/calls.log"\necho "OK: all pins resolve"\n' >"$W/bin/vp-ok"
  printf '#!/usr/bin/env bash\necho "FAIL versions.lock.yaml: firstPartyImages[%s].from[1]: alpine: digest does not resolve"; exit 1\n' "$IMG" >"$W/bin/vp-mine"
  printf '#!/usr/bin/env bash\necho "FAIL versions.lock.yaml: firstPartyImages[someone-else].from[0]: x: no"; exit 1\n' >"$W/bin/vp-other"
  printf '#!/usr/bin/env bash\necho "verify_pins.sh: skopeo is required" >&2; exit 2\n' >"$W/bin/vp-cannot"
  chmod +x "$W/bin"/vp-*
  export IMAGE_BUILD_VERIFY_PINS="$W/bin/vp-ok"
}
ORIG_PATH="$PATH"

ib() { # <fn> [args…] — run in a subshell; sets rc/out (stdout only in $out_stdout)
  : >"$FAKE_STATE/calls.log"
  set +e
  out_stdout="$( ( source "$ROOT/scripts/lib/image_build.sh"; "$@" ) 2>"$W/stderr" )"
  rc=$?
  set -e
  out="$out_stdout
$(cat "$W/stderr")"
}
hash_of() { ib image_build::content_hash "$IMG"; printf '%s' "$out_stdout"; }

# ------------------------------------------------------------------ the content hash
setup hash
H0="$(hash_of)"
check "hash: a 64-hex SHA-256" '[[ "$H0" =~ ^[0-9a-f]{64}$ ]]'
check "hash: same tree → same hash" '[[ "$(hash_of)" == "$H0" ]]'
cp -a "$W/tree" "$W/tree-copy"
check "hash: path-independent (the same tree elsewhere → same hash)" '[[ "$(IMAGE_BUILD_ROOT="$W/tree-copy" hash_of)" == "$H0" ]]'
ib image_build::context_files "$IMG"
check "files: tracked files listed, sorted" '[[ "$out_stdout" == $'"'"'.dockerignore\nmain.txt\nsub/run.sh'"'"' ]]'

printf 'hellp\n' >"$W/tree/app/main.txt"
H1="$(hash_of)"
check "hash: one changed byte in a tracked file → a different hash" '[[ "$H1" != "$H0" ]]'
printf 'hello\n' >"$W/tree/app/main.txt"
check "hash: reverting the byte → the original hash" '[[ "$(hash_of)" == "$H0" ]]'

sed -i 's/^# fixture$/# fixturf/' "$W/tree/docker/Dockerfile.$IMG"
check "hash: one changed byte in the Dockerfile → a different hash" '[[ "$(hash_of)" != "$H0" ]]'
sed -i 's/^# fixturf$/# fixture/' "$W/tree/docker/Dockerfile.$IMG"

chmod -x "$W/tree/app/sub/run.sh"
check "hash: the executable bit is content" '[[ "$(hash_of)" != "$H0" ]]'
chmod +x "$W/tree/app/sub/run.sh"

printf 'new\n' >"$W/tree/app/new-file.txt"
check "hash: a new tracked file → a different hash" '[[ "$(hash_of)" != "$H0" ]]'
rm -f "$W/tree/app/new-file.txt"

for f in app/debug.log app/node_modules/x/index.js app/build/out.bin app/vendored/README app/local.env; do
  printf 'changed\n' >>"$W/tree/$f"
  check "hash: a change in untracked $f → the same hash" '[[ "$(hash_of)" == "$H0" ]]'
done
mkdir -p "$W/tree/app/.git"; printf 'x' >"$W/tree/app/.git/HEAD"
check "hash: a .git directory is never content" '[[ "$(hash_of)" == "$H0" ]]'
rm -rf "$W/tree/app/.git"

# ------------------------------------------------------------------ the build
setup build
H="$(hash_of)"
K="$W/tree/deploy/demo/kustomization.yaml"
ib image_build::build "$IMG" deploy/demo
check "build: exits 0" '[[ $rc -eq 0 ]]'
check "build: prints <name>:<contentHash> on stdout, nothing else" '[[ "$out_stdout" == "$IMG:$H" ]]'
check "build: verify-pins was consulted for the tree" 'grep -q "^verify_pins --root $W/tree --lock $W/tree/versions.lock.yaml" "$FAKE_STATE/calls.log"'
check "build: docker build tagged <name>:<contentHash> with the Dockerfile" \
  'grep -q "^docker build -f $W/tree/docker/Dockerfile.$IMG -t $IMG:$H " "$FAKE_STATE/calls.log"'
check "build: the build context is exactly the hashed files" \
  '[[ "$(cat "$FAKE_STATE/last_build_context")" == $'"'"'./.dockerignore\n./main.txt\n./sub/run.sh'"'"' ]]'
check "build: kind load docker-image into the cluster" 'grep -q "^kind load docker-image $IMG:$H --name agentic-netops" "$FAKE_STATE/calls.log"'
check "build: the kustomization images: override carries the new tag" \
  '[[ "$(IB=$IMG yq ".images[] | select(.name == strenv(IB)) | .newTag" "$K")" == "$H" ]]'
check "build: the rest of the kustomization is untouched" \
  '[[ "$(yq ".images[] | select(.name == \"unrelated\") | .newTag" "$K")" == keepme && "$(yq ".resources[0]" "$K")" == deployment.yaml ]] && grep -q "^# owned by another stream" "$K"'
REC="$(find "$EVIDENCE_ROOT" -name "image-build.$IMG.${H:0:12}.json" | head -1)"
check "build: the image ID is recorded through evidence_run" \
  '[[ -n "$REC" ]] && jq -e --arg t "$IMG:$H" ".command[-1] == \$t and .exit_status == 0 and (.command | index(\"inspect\"))" "$REC" >/dev/null'
check "build: the recorded stdout is the image ID" \
  '[[ "$(cat "${REC%.json}.stdout")" == "$(cat "$(fakes::image_file "$IMG:$H")")" ]]'
check "build: the lock file is not rewritten by a build" '! grep -q "$H" "$W/tree/versions.lock.yaml"'
cp "$K" "$W/k.before"
ib image_build::build "$IMG" deploy/demo
check "build (re-run): same tag, no rebuild" '[[ $rc -eq 0 && "$out_stdout" == "$IMG:$H" ]] && ! grep -q "^docker build" "$FAKE_STATE/calls.log"'
check "build (re-run): the kustomization is unchanged" 'cmp -s "$K" "$W/k.before"'
check "build (re-run): a second evidence record, never an overwrite" \
  '[[ "$(find "$EVIDENCE_ROOT" -name "image-build.$IMG.${H:0:12}*.json" | wc -l)" -eq 2 ]]'
printf 'v2\n' >"$W/tree/app/main.txt"
ib image_build::build "$IMG" deploy/demo
check "build: one changed byte → a new tag, built and written" \
  '[[ $rc -eq 0 && "$out_stdout" != "$IMG:$H" && "$out_stdout" == "$IMG:"* ]] && grep -q "^docker build" "$FAKE_STATE/calls.log" && [[ "$(IB=$IMG yq ".images[] | select(.name == strenv(IB)) | .newTag" "$K")" == "${out_stdout#*:}" ]]'
check "build: exactly one images: entry for the image" '[[ "$(IB=$IMG yq "[.images[] | select(.name == strenv(IB))] | length" "$K")" == 1 ]]'

# ------------------------------------------------------------------ refusals
refused() { # <name> — rc non-zero and no docker build, no kind load, no kustomization change
  [[ $rc -ne 0 ]] && ! grep -qE "^(docker build|kind load)" "$FAKE_STATE/calls.log" && ! grep -q "name: $IMG" "$K"
}
setup tag-only
K="$W/tree/deploy/demo/kustomization.yaml"
sed -i "s|^FROM alpine:3.24.2@$ALP|FROM alpine:3.24.2|" "$W/tree/docker/Dockerfile.$IMG"
ib image_build::build "$IMG" deploy/demo
check "refuse: a tag-only FROM" 'refused'
check "refuse: the tag-only FROM is named with its line" 'grep -q "refusing tag-only FROM at docker/Dockerfile.$IMG:5" <<<"$out"'

setup digest-differs
K="$W/tree/deploy/demo/kustomization.yaml"
sed -i "s|^FROM alpine:3.24.2@$ALP|FROM alpine:3.24.2@sha256:$(printf '0%.0s' {1..64})|" "$W/tree/docker/Dockerfile.$IMG"
ib image_build::build "$IMG" deploy/demo
check "refuse: a FROM digest differing from the lock" 'refused && grep -q "digest .* differs from the lock" <<<"$out"'

setup ref-differs
K="$W/tree/deploy/demo/kustomization.yaml"
sed -i "s|^FROM alpine:3.24.2@$ALP|FROM docker.io/library/debian:3.24.2@$ALP|" "$W/tree/docker/Dockerfile.$IMG"
ib image_build::build "$IMG" deploy/demo
check "refuse: a FROM naming another repository" 'refused && grep -q "the lock pins alpine" <<<"$out"'

setup normalized
K="$W/tree/deploy/demo/kustomization.yaml"
sed -i "s|^FROM alpine:3.24.2@$ALP|FROM docker.io/library/alpine:3.24.2@$ALP|" "$W/tree/docker/Dockerfile.$IMG"
ib image_build::build "$IMG" deploy/demo
check "accept: docker.io/library/alpine equals the lock's alpine" '[[ $rc -eq 0 ]]'

setup build-arg
K="$W/tree/deploy/demo/kustomization.yaml"
sed -i "s|^FROM alpine:3.24.2@$ALP|FROM \${BASE}|" "$W/tree/docker/Dockerfile.$IMG"
ib image_build::build "$IMG" deploy/demo
check "refuse: a build-argument FROM" 'refused && grep -q "uses a build argument" <<<"$out"'

setup copy-from
K="$W/tree/deploy/demo/kustomization.yaml"
echo "COPY --from=busybox:1.36 /bin/sh /sh" >>"$W/tree/docker/Dockerfile.$IMG"
ib image_build::build "$IMG" deploy/demo
check "refuse: a tag-only COPY --from=<image>" 'refused && grep -q "refusing tag-only COPY --from" <<<"$out"'

setup count
K="$W/tree/deploy/demo/kustomization.yaml"
sed -i "/^FROM golang/d; /^COPY --from=build/d" "$W/tree/docker/Dockerfile.$IMG"
ib image_build::build "$IMG" deploy/demo
check "refuse: a Dockerfile with fewer external images than the lock pins" 'refused && grep -q "has 1 external image(s), the lock pins 2" <<<"$out"'

setup pending
K="$W/tree/deploy/demo/kustomization.yaml"
ib image_build::build other-img deploy/demo
check "refuse: a pending image (Dockerfile absent)" '[[ $rc -ne 0 ]] && grep -q "pending" <<<"$out" && ! grep -q "^docker build" "$FAKE_STATE/calls.log"'
ib image_build::build no-such-img deploy/demo
check "refuse: an image with no lock entry" '[[ $rc -ne 0 ]] && grep -q "no firstPartyImages entry" <<<"$out"'

setup vp-mine
K="$W/tree/deploy/demo/kustomization.yaml"
IMAGE_BUILD_VERIFY_PINS="$W/bin/vp-mine" ib image_build::build "$IMG" deploy/demo
check "refuse: verify-pins fails for this image" 'refused && grep -q "verify-pins fails for it" <<<"$out"'
IMAGE_BUILD_VERIFY_PINS="$W/bin/vp-cannot" ib image_build::build "$IMG" deploy/demo
check "refuse: verify-pins cannot run (fail closed)" 'refused && grep -q "could not run" <<<"$out"'
IMAGE_BUILD_VERIFY_PINS="$W/bin/vp-other" ib image_build::build "$IMG" deploy/demo
check "accept: a verify-pins failure for ANOTHER image does not block this one" '[[ $rc -eq 0 ]] && grep -q "none of them for $IMG" <<<"$out"'

setup no-kustomization
ib image_build::build "$IMG"
check "refuse: no kustomization known for the image (nothing built)" '[[ $rc -ne 0 ]] && ! grep -q "^docker build" "$FAKE_STATE/calls.log"'

setup no-cluster
K="$W/tree/deploy/demo/kustomization.yaml"
rm -f "$FAKE_STATE/kind/agentic-netops"
ib image_build::build "$IMG" deploy/demo
check "refuse: kind load fails without the cluster, the kustomization untouched" '[[ $rc -ne 0 ]] && ! grep -q "name: $IMG" "$K"'

# ------------------------------------------------------------------ the real tree
if [[ -f "$ROOT/versions.lock.yaml" ]]; then
  set +e
  real="$( ( unset IMAGE_BUILD_ROOT; source "$ROOT/scripts/lib/image_build.sh"; image_build::dockerfile_images /dev/stdin ) <<'EOF'
FROM --platform=$BUILDPLATFORM golang:1.27.1-alpine@sha256:aaaa AS builder
FROM builder AS test
FROM scratch
FROM alpine:3.24.2@sha256:bbbb
COPY --from=builder /x /x
COPY --from=0 /y /y
EOF
)"
  set -e
  check "parse: stages, scratch and numeric COPY --from are not external images" \
    '[[ "$(cut -f3 <<<"$real" | tr "\n" " ")" == "golang:1.27.1-alpine@sha256:aaaa alpine:3.24.2@sha256:bbbb " ]]'
fi

printf '\nimage_build_test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
