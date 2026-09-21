#!/usr/bin/env bash
# Builds the verify-evidence fixtures (T012) into <out-dir>, one run directory
# per case, through the real capture library scripts/lib/evidence.sh — then
# damages each copy in exactly one way. The committed fixtures/ tree is this
# script's output (`make_fixtures.sh tests/unit/verifyevidence/fixtures`), and
# verifyevidence_test.sh also rebuilds it into a temp dir on every run, so the
# library and the verifier are checked against each other both ways.
#
# Where a case damages something other than a hash, the record's record_sha256
# is recomputed, so the fixture fails for its one stated reason only.
set -euo pipefail

out="${1:?usage: make_fixtures.sh <out-dir>}"
LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../scripts/lib" && pwd)"

export EVIDENCE_CLUSTER=agentic-netops EVIDENCE_LAB=fixture-lab EVIDENCE_CLUSTER_UID=00000000-fixture-uid
export EVIDENCE_DEVICE_IMAGE_DIGEST=sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402
export EVIDENCE_TOPOLOGY=/nonexistent

# rehash <record.json> — recompute record_sha256 after a deliberate edit.
rehash() {
  local f="$1" body
  body="$(jq -S -c 'del(.record_sha256)' "$f")"
  jq -S --arg r "$(printf '%s' "$body" | sha256sum | awk '{print $1}')" '. + {record_sha256: $r}' <<<"$body" >"$f.tmp"
  mv "$f.tmp" "$f"
}

# build <case> <steps-function>
build() {
  local name="$1" fn="$2"
  rm -rf "${out:?}/$name"
  mkdir -p "$out/$name"
  ( export EVIDENCE_DIR="$out/$name"
    # shellcheck source=/dev/null
    source "$LIB/evidence.sh"
    "$fn" >/dev/null 2>&1 ) || { echo "make_fixtures: case $name failed to build" >&2; return 1; }
}

complete_run() {
  evidence_run cluster-nodes -- echo "3 nodes Ready"
  evidence_negative_control fabric-sessions -- sh -c 'echo "0/8 sessions established"; exit 1'
  evidence_run fabric-sessions --readiness --records SC-004:session -- echo "8/8 sessions established, evpn up, inter-as-vpn true"
  evidence_negative_control service-routes -- sh -c 'echo "Ready=False: missing type-2/3 routes"; exit 1'
  evidence_run service-routes --records SC-004:route -- echo "type-2/3/5 routes present for mac-vrf-a, ip-vrf-b"
}
good() { complete_run; }
missing_field() { complete_run; }
post_edit_output() { complete_run; }
post_edit_record() { complete_run; }
hand_placed() { complete_run; }
readiness_without_nc() {
  evidence_run cluster-nodes -- echo "3 nodes Ready"
  evidence_run targets-ready -- echo "4/4 targets Ready"
}
nc_passed() {
  evidence_negative_control targets-ready -- echo "4/4 targets Ready (on a stock fabric: the check is defective)" || true
}
sc004_missing_session() {
  evidence_negative_control service-routes -- sh -c 'echo "Ready=False"; exit 1'
  evidence_run service-routes --records SC-004:route -- echo "routes present"
}
sc004_missing_route() {
  evidence_run fabric-sessions --records SC-004:session -- echo "8/8 sessions established"
}
sc004_missing_route_nc() {
  evidence_run fabric-sessions --records SC-004:session -- echo "8/8 sessions established"
  # A route half recorded without --records' implied readiness gate cannot be
  # captured by evidence.sh; this is the shape a hand-assembled directory has.
  evidence_run service-routes --records SC-004:session -- echo "routes present"
}

build good good
build missing-field missing_field
jq 'del(.device_image_digest)' "$out/missing-field/cluster-nodes.json" >"$out/missing-field/x" && mv "$out/missing-field/x" "$out/missing-field/cluster-nodes.json"
rehash "$out/missing-field/cluster-nodes.json"
build post-edit-output post_edit_output
printf '8/8 sessions established (edited)\n' >"$out/post-edit-output/fabric-sessions.stdout"
build post-edit-record post_edit_record
jq '.exit_status = 0' "$out/post-edit-record/service-routes.negative-control.json" >"$out/post-edit-record/x" \
  && mv "$out/post-edit-record/x" "$out/post-edit-record/service-routes.negative-control.json"
build hand-placed hand_placed
printf '{"proof": "sessions up"}\n' >"$out/hand-placed/handwritten-proof.json"
build readiness-without-nc readiness_without_nc
jq '.readiness = true' "$out/readiness-without-nc/targets-ready.json" >"$out/readiness-without-nc/x" \
  && mv "$out/readiness-without-nc/x" "$out/readiness-without-nc/targets-ready.json"
rehash "$out/readiness-without-nc/targets-ready.json"
build nc-passed nc_passed
build sc004-missing-session sc004_missing_session
build sc004-missing-route sc004_missing_route
build sc004-missing-route-nc sc004_missing_route_nc
jq '.records = ["SC-004:route"]' "$out/sc004-missing-route-nc/service-routes.json" >"$out/sc004-missing-route-nc/x" \
  && mv "$out/sc004-missing-route-nc/x" "$out/sc004-missing-route-nc/service-routes.json"
rehash "$out/sc004-missing-route-nc/service-routes.json"
echo "make_fixtures: wrote $(find "$out" -mindepth 1 -maxdepth 1 -type d | wc -l) cases to $out"
