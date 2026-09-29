#!/usr/bin/env bash
# verify_compat.sh — `make verify-compat` (T050; FR-017, FR-104, NFR-003, R-43, SC-047;
# data-model.md §23, §26; contracts/crd-api.md "Version contract").
#
# Against the running lab (reads only), three checks, every failure NAMED:
#
#   compat     the compatibility set the provider publishes equals versions.lock.yaml parts
#              1–9 (`.compatibilitySet`):
#                * ConfigMap agentic-netops-system/srl-provider-compatibility-set — written
#                  by the PROVIDER itself at start (cmd/srl-provider/wiring.go
#                  publishCompatibility) from the lock file baked into its image, never by
#                  provisioning — key `compatibility-set.json`: every value it publishes equals
#                  versions.lock.yaml `.compatibilitySet` at the same path (the lock projected
#                  onto the published shape; a differing part is named, "part 5
#                  (deviceConfiguration)"); key `identifier`: the nine-part identifier
#                  (internal/compat Identifier), which must name the lock's device digest,
#                  model and patch commits, data/config-server tags and srl-mapping version;
#                * every Config the provider generated (config.sdcio.dev Configs carrying the
#                  annotation agentic-netops.io/compatibility-set) carries exactly that
#                  identifier; a Config stamped with another set is named.
#   authority  exactly one allocation authority is installed, and it is the lock file's
#              `allocationAuthority.kind`:
#                kuid        → the *.be.kuid.dev APIServices exist and NO IdentifierPool /
#                              IdentifierClaim CRD (fabric.agentic-netops.io) exists
#                first-party → the IdentifierPool / IdentifierClaim CRDs exist and NO
#                              *.be.kuid.dev APIService exists
#   images     every running first-party workload (a container whose image is one of
#              versions.lock.yaml firstPartyImages[].name) runs `<name>:<contentHash of the
#              current tree>` (image_build::content_hash) AND the image ID this run's build
#              recorded in evidence — the stdout of the passing record
#              image-build.<name>.<hash:0:12>[-N].json that image_build::build writes into
#              EVIDENCE_DIR (the newest such record, when the build ran more than once); when
#              this run built nothing (an acceptance pass on a standing lab), the record of the
#              run that provisioned it: COMPAT_BUILD_EVIDENCE_DIR, else the newest record in
#              any run directory of this lab stamped with the live cluster's UID
#              (kube-system's namespace UID; records of another cluster never count);
#              a workload running anything else fails naming it. The provider
#              (agentic-netops-system/srl-provider) must be among them, and under first-party
#              so must the allocation authority (agentic-netops-allocation/allocation-authority,
#              which runs the provider's image with SRL_PROVIDER_ROLE=allocation-authority).
#
# Usage: scripts/ci/verify_compat.sh
#   env: CLUSTER_NAME (default agentic-netops; context kind-<cluster>), KUBECTL,
#        COMPAT_BUILD_EVIDENCE_DIR (optional: the run that provisioned a standing lab — read for
#        its image build records when EVIDENCE_DIR holds none; CONTROL_PLANE_ONLY acceptance on
#        T152's re-provisioned lab, whose images that run built — T152 r8; without it the lab's
#        run directories are searched for records stamped with the live cluster's UID),
#        EVIDENCE_ROOT (default .evidence),
#        EVIDENCE_DIR (default: the most recently modified run under .evidence/<cluster>_<lab>/
#        holding an image build record),
#        LAB_NAME (default agentic-netops-fabric)
# Exit: 0 all hold; 1 a check failed (named); 2 a prerequisite is missing.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK="$ROOT/versions.lock.yaml"
# shellcheck source=../lib/log.sh
source "$ROOT/scripts/lib/log.sh"
if [[ -f "$ROOT/scripts/lib/image_build.sh" ]]; then
  # shellcheck source=../lib/image_build.sh
  source "$ROOT/scripts/lib/image_build.sh"
fi
export LOG_PHASE="verify-compat"

: "${CLUSTER_NAME:=agentic-netops}"
: "${LAB_NAME:=agentic-netops-fabric}"
PROVIDER_NS="agentic-netops-system"
COMPAT_CM="srl-provider-compatibility-set"   # written by the provider (cmd/srl-provider/wiring.go)
ANNOTATION="agentic-netops.io/compatibility-set"
FP_NS="agentic-netops-allocation"
FP_DEPLOYMENT="allocation-authority"
FP_CRDS=(identifierpools.fabric.agentic-netops.io identifierclaims.fabric.agentic-netops.io)
KUID_APISERVICES=(v1alpha1.vlan.be.kuid.dev v1alpha1.genid.be.kuid.dev v1alpha1.ipam.be.kuid.dev v1alpha1.as.be.kuid.dev)

for tool in jq yq sha256sum "${KUBECTL:-kubectl}"; do
  command -v "$tool" >/dev/null 2>&1 || { echo "verify_compat: $tool is required" >&2; exit 2; }
done

k() { "${KUBECTL:-kubectl}" --context "kind-${CLUSTER_NAME}" "$@"; }

FAILS=0
bad()  { log::error "FAIL $*"; FAILS=$((FAILS + 1)); }
good() { log::info "PASS $*"; }

# ------------------------------------------------------------------ compat
lock_compat="$(yq -o=json '.compatibilitySet' "$LOCK" | jq -S -c .)"

check_compat() {
  local cm published pid part
  if ! cm="$(k get configmap "$COMPAT_CM" -n "$PROVIDER_NS" -o json 2>&1)"; then
    bad "compat: ConfigMap ${PROVIDER_NS}/${COMPAT_CM} (the compatibility set the provider publishes) cannot be read: ${cm}"
    return
  fi
  published="$(jq -r '.data["compatibility-set.json"] // empty' <<<"$cm")"
  pid="$(jq -r '.data.identifier // empty' <<<"$cm")"
  if [[ -z "$published" ]] || ! published="$(jq -S -c 'del(.identifier)' <<<"$published" 2>/dev/null)"; then
    bad "compat: ${PROVIDER_NS}/${COMPAT_CM} carries no parseable compatibility-set.json"
    return
  fi
  # the lock projected onto the published shape; "", [], {} and null are one "unset"
  local proj
  proj="$(jq -S -c --argjson p "$published" '
    def unset: walk(if . == "" or . == [] or . == {} then null else . end);
    def shape($p):
      if ($p | type) == "object" then . as $l
        | reduce ($p | keys[]) as $k ({}; .[$k] = ($l | (if type == "object" then .[$k] else null end) | shape($p[$k])))
      elif ($p | type) == "array" then . as $l
        | [range(0; ([($l | if type == "array" then length else 0 end), ($p | length)] | max)) as $i
           | ($l | if type == "array" then .[$i] else null end) | shape($p[$i])]
      else . end;
    shape($p) | unset' <<<"$lock_compat")"
  local pubn; pubn="$(jq -S -c 'walk(if . == "" or . == [] or . == {} then null else . end)' <<<"$published")"
  if [[ "$(jq -r 'keys | length' <<<"$published")" -eq 0 ]]; then
    bad "compat: ${PROVIDER_NS}/${COMPAT_CM} publishes no part"
  elif [[ "$proj" == "$pubn" ]]; then
    good "compat: every part the provider publishes ($(jq -r 'keys | join(", ")' <<<"$published")) equals versions.lock.yaml"
  else
    for part in $(jq -r 'keys[]' <<<"$published"); do
      if [[ "$(jq -S -c --arg p "$part" '.[$p]' <<<"$proj")" != "$(jq -S -c --arg p "$part" '.[$p]' <<<"$pubn")" ]]; then
        bad "compat: part $(jq -r --arg p "$part" '.[$p].part // "?"' <<<"$lock_compat") (${part}) published by the provider differs from versions.lock.yaml"
      fi
    done
  fi
  if [[ -z "$pid" ]]; then
    bad "compat: ${PROVIDER_NS}/${COMPAT_CM} publishes no identifier"
  else
    local v missing=""
    for v in $(jq -r '[.deviceImage.digest, .yangModels.commit, .deviationPatch.commit,
                       ("config-server@" + .deviceConfiguration.configServer.tag),
                       ("data-server@" + .deviceConfiguration.dataServer.tag),
                       ("srl-mapping@" + .srlMapping.version)] | .[] | select(. != null)' <<<"$lock_compat"); do
      [[ "$pid" == *"$v"* ]] || missing+=" $v"
    done
    if [[ -n "$missing" ]]; then bad "compat: the published identifier '${pid}' does not name the lock's${missing}"
    else good "compat: the published identifier names the lock's parts: ${pid}"; fi
  fi
  local configs stale
  if ! configs="$(k get configs.config.sdcio.dev -A -o json 2>&1)"; then
    bad "compat: Configs (config.sdcio.dev) cannot be listed: ${configs}"
    return
  fi
  stale="$(jq -r --arg a "$ANNOTATION" --arg id "$pid" '
    .items[] | select(.metadata.annotations[$a] != null) | select(.metadata.annotations[$a] != $id)
    | "\(.metadata.namespace)/\(.metadata.name) stamped \(.metadata.annotations[$a])"' <<<"$configs")"
  local n; n="$(jq -r --arg a "$ANNOTATION" '[.items[] | select(.metadata.annotations[$a] != null)] | length' <<<"$configs")"
  if [[ -n "$stale" ]]; then
    while IFS= read -r line; do bad "compat: Config ${line}, not the provider's published identifier"; done <<<"$stale"
  else
    good "compat: all ${n} provider-generated Config(s) carry the published compatibility identifier"
  fi
}

# ------------------------------------------------------------------ authority
check_authority() {
  local kind crd svc present
  kind="$(yq -r '.allocationAuthority.kind // ""' "$LOCK")"
  case "$kind" in
    kuid)
      for svc in "${KUID_APISERVICES[@]}"; do
        k get apiservice "$svc" -o name >/dev/null 2>&1 || bad "authority: kuid is selected, but APIService ${svc} is not installed"
      done
      present=""
      for crd in "${FP_CRDS[@]}"; do
        k get crd "$crd" -o name >/dev/null 2>&1 && present+=" $crd"
      done
      if [[ -n "$present" ]]; then
        bad "authority: two allocation authorities — kuid is selected and the first-party CRD(s)${present} exist (FR-104)"
      else
        good "authority: exactly one allocation authority — kuid; no IdentifierPool/IdentifierClaim CRD exists"
      fi ;;
    first-party)
      for crd in "${FP_CRDS[@]}"; do
        k get crd "$crd" -o name >/dev/null 2>&1 || bad "authority: first-party is selected, but CRD ${crd} is not installed"
      done
      present="$(k get apiservice -o name 2>/dev/null | grep -E 'be\.kuid\.dev$' | paste -sd' ' - || true)"
      if [[ -n "$present" ]]; then
        bad "authority: two allocation authorities — first-party is selected and ${present} exist (FR-104)"
      else
        good "authority: exactly one allocation authority — first-party; no *.be.kuid.dev APIService exists"
      fi ;;
    *) bad "authority: versions.lock.yaml allocationAuthority.kind is '${kind:-<absent>}' (kuid | first-party)" ;;
  esac
}

# ------------------------------------------------------------------ images
resolve_evidence_dir() {
  if [[ -n "${EVIDENCE_DIR:-}" ]]; then printf '%s' "$EVIDENCE_DIR"; return 0; fi
  local base="${EVIDENCE_ROOT:-$ROOT/.evidence}/${CLUSTER_NAME}_${LAB_NAME}"
  [[ -d "$base" ]] || return 1
  # the most recently modified run that holds an image build record (a name sort would pick a
  # gate-debug-* directory over a timestamped provisioning run)
  local d
  while IFS= read -r d; do
    compgen -G "$d/image-build.*.json" >/dev/null && { printf '%s' "$d"; return 0; }
  done < <(ls -1dt "$base"/*/ 2>/dev/null | sed 's:/$::')
  return 1
}

# lab_uid — the live cluster's identity: kube-system's namespace UID, the value evidence_run
# stamps into every record as .cluster.uid (scripts/lib/evidence.sh evidence::cluster_uid);
# empty when it cannot be read.
LAB_UID=""
lab_uid() {
  if [[ -z "$LAB_UID" ]]; then
    LAB_UID="$(k get namespace kube-system -o json 2>/dev/null | jq -r '.metadata.uid // empty' 2>/dev/null || true)"
    [[ -n "$LAB_UID" ]] || LAB_UID="-"
  fi
  [[ "$LAB_UID" == "-" ]] || printf '%s' "$LAB_UID"
}

# newest_record <uid|""> <file>... — the newest passing build record among <file>s (kind run,
# exit 0; with <uid>, only a record stamped .cluster.uid == <uid>); the utc_time wins, then the
# path. Prints its path; nothing when none.
newest_record() {
  local uid="$1" f best="" t bt=""; shift
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    jq -e --arg u "$uid" '.kind == "run" and .exit_status == 0 and ($u == "" or .cluster.uid == $u)' "$f" >/dev/null 2>&1 || continue
    t="$(jq -r '.utc_time // ""' "$f")"
    if [[ -z "$best" || "$t" > "$bt" || ( "$t" == "$bt" && "$f" > "$best" ) ]]; then best="$f"; bt="$t"; fi
  done
  [[ -z "$best" ]] || printf '%s' "$best"
}

# recorded_image_id <name> <hash> — the image ID a build of THIS lab recorded for <name>:<hash>
# (record image-build.<name>.<hash:0:12>[-N].json, exit 0, its stdout the `docker image inspect
# --format {{.Id}}` output); empty when none. Looked for, in order:
#   1. EVIDENCE_DIR (this run built the image);
#   2. COMPAT_BUILD_EVIDENCE_DIR (the run that provisioned the standing lab, when named);
#   3. every run directory of this lab (${EVIDENCE_ROOT:-.evidence}/<cluster>_<lab>/*/), keeping
#      only records stamped with the live cluster's UID — a standing lab provisioned by an
#      earlier run (a quickstart walk's §1 provisioning, then a later acceptance pass whose own
#      directory builds nothing) keeps its build records there. A record from another cluster
#      (an earlier lab of the same name, same content hash) never counts: its image ID is not
#      what was loaded into this one.
# Within a source the newest record wins.
recorded_image_id() {
  local name="$1" hash="$2" best="" out dir uid base
  [[ -n "$hash" ]] || return 0
  local pat="image-build.${name}.${hash:0:12}"
  for dir in "$EVIDENCE_DIR" "${COMPAT_BUILD_EVIDENCE_DIR:-}"; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    best="$(newest_record "" "$dir/$pat.json" "$dir/$pat"-*.json)"
    [[ -z "$best" ]] || break
  done
  if [[ -z "$best" ]] && uid="$(lab_uid)" && [[ -n "$uid" ]]; then
    base="${EVIDENCE_ROOT:-$ROOT/.evidence}/${CLUSTER_NAME}_${LAB_NAME}"
    if [[ -d "$base" ]]; then
      local -a cands=()
      mapfile -t cands < <(compgen -G "$base/*/$pat.json"; compgen -G "$base/*/$pat-*.json")
      [[ "${#cands[@]}" -eq 0 ]] || best="$(newest_record "$uid" "${cands[@]}")"
    fi
  fi
  [[ -n "$best" ]] || return 0
  out="$(dirname -- "$best")/$(jq -r '.raw_output.stdout.file' "$best")"
  [[ -f "$out" ]] && grep -oE 'sha256:[0-9a-f]{64}' "$out" | head -n1
  return 0
}

check_images() {
  local names pods evdir hash want_id rows provider_seen=false authority_seen=false
  if ! declare -F image_build::content_hash >/dev/null; then
    bad "images: scripts/lib/image_build.sh (image_build::content_hash) is required"
    return
  fi
  if ! evdir="$(resolve_evidence_dir)" || [[ -z "$evdir" || ! -d "$evdir" ]]; then
    bad "images: no evidence directory for this run (set EVIDENCE_DIR, or provision first)"
    return
  fi
  export EVIDENCE_DIR="$evdir"
  names="$(yq -r '.firstPartyImages[].name' "$LOCK")"
  if ! pods="$(k get pods -A -o json 2>&1)"; then bad "images: pods cannot be listed: ${pods}"; return; fi
  # one row per running first-party container: ns pod container image imageID
  rows="$(jq -r --arg names "$names" '
    ($names | split("\n") | map(select(length > 0))) as $fp
    | .items[] | select(.status.phase == "Running") as $p
    | ($p.status.containerStatuses // [])[] as $cs
    | ($p.spec.containers[] | select(.name == $cs.name) | .image) as $img
    | ($img | sub("@.*$"; "") | sub(":[^:/]*$"; "") | split("/") | last) as $repo
    | select($fp | index($repo))
    | [$p.metadata.namespace, $p.metadata.name, $cs.name, $repo, $img, ($cs.imageID // "")] | @tsv' <<<"$pods")"
  if [[ -z "$rows" ]]; then
    bad "images: no running first-party workload found (the provider ${PROVIDER_NS}/srl-provider must run)"
    return
  fi
  local ns pod ctr repo img iid tag got_id
  declare -A HASH=() RID=()
  while IFS=$'\t' read -r ns pod ctr repo img iid; do
    [[ "$ns" == "$PROVIDER_NS" && "$repo" == srl-provider ]] && provider_seen=true
    [[ "$ns" == "$FP_NS" && "$repo" == srl-provider && "$pod" == "${FP_DEPLOYMENT}-"* ]] && authority_seen=true
    if [[ -z "${HASH[$repo]+x}" ]]; then
      HASH[$repo]="$(image_build::content_hash "$repo" 2>/dev/null || true)"
      RID[$repo]="$(recorded_image_id "$repo" "${HASH[$repo]}")"
    fi
    hash="${HASH[$repo]}"; want_id="${RID[$repo]}"
    tag="${img##*:}"; [[ "$img" == *@* ]] && tag="${img%%@*}" && tag="${tag##*:}"
    local who="workload ${ns}/${pod} container ${ctr}"
    if [[ -z "$hash" ]]; then bad "images: ${who}: the content hash of ${repo} for the current tree could not be computed"; continue; fi
    if [[ "$tag" != "$hash" ]]; then
      bad "images: ${who} runs ${img}, not ${repo}:${hash} (the content hash of the current tree)"; continue
    fi
    if [[ -z "$want_id" ]]; then
      bad "images: ${who}: this run's evidence (${EVIDENCE_DIR}${COMPAT_BUILD_EVIDENCE_DIR:+, or the provisioning run ${COMPAT_BUILD_EVIDENCE_DIR}}) records no image ID for ${repo}:${hash}, and no run of this lab (cluster uid $(u="$(lab_uid)"; printf '%s' "${u:-unreadable}")) under ${EVIDENCE_ROOT:-$ROOT/.evidence}/${CLUSTER_NAME}_${LAB_NAME} recorded one"; continue
    fi
    got_id="$(grep -oE 'sha256:[0-9a-f]{64}' <<<"$iid" | tail -n1 || true)"
    if [[ "$got_id" != "$want_id" ]]; then
      bad "images: ${who} runs image ID ${got_id:-<unknown>}, not ${want_id} (the ID this run's build recorded)"; continue
    fi
    good "images: ${who} runs ${repo}:${hash} (${want_id})"
  done <<<"$rows"
  [[ "$provider_seen" == true ]] || bad "images: the provider ${PROVIDER_NS}/srl-provider is not running"
  if [[ "$(yq -r '.allocationAuthority.kind // ""' "$LOCK")" == first-party && "$authority_seen" != true ]]; then
    bad "images: first-party is selected, but the allocation authority ${FP_NS}/${FP_DEPLOYMENT}, which runs the srl-provider image, is not running"
  fi
}

check_compat
check_authority
check_images
if [[ "$FAILS" -gt 0 ]]; then
  log::error "verify-compat: ${FAILS} failure(s)"
  exit 1
fi
log::info "verify-compat: compatibility set, single allocation authority and first-party images hold"
