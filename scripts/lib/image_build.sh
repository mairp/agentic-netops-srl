#!/usr/bin/env bash
# image_build.sh — the first-party image build (T169; NFR-003, AD-05, R-43; data-model.md §26).
#
#   image_build::build <name> [kustomization-dir]
#       Builds the first-party image <name> of versions.lock.yaml firstPartyImages and prints
#       `<name>:<contentHash>` on stdout (logs go to stderr):
#         1. refuses unless every external image the Dockerfile builds from (every FROM that is not
#            an earlier stage, every COPY --from=<image>) is `<ref>[:tag]@sha256:<digest>` and
#            equals, in order, the lock entry's from[] (ref, digest, and tag/track when named) — a
#            tag-only FROM is refused;
#         2. refuses when `make verify-pins` (scripts/lib/verify_pins.sh) fails for this image — any
#            FAIL line naming firstPartyImages[<name>] — or cannot run at all (exit 2: fail closed);
#         3. contentHash = image_build::content_hash (below); tag <name>:<contentHash> — the full
#            64-hex SHA-256, never `latest`, never a reusable tag;
#         4. `docker build` from a staged copy of exactly the hashed files (so the image is built
#            from what the tag names, nothing else) — skipped when that tag already exists locally;
#         5. `kind load docker-image` into the cluster (CLUSTER_NAME);
#         6. writes the tag into the manifest it belongs to through the kustomization's `images:`
#            override (name <name>, newTag <contentHash>) — only that stanza is touched, with yq;
#            never a hand edit of a Deployment;
#         7. records the built image ID through evidence_run (never into the lock file).
#       The kustomization defaults: srl-provider → deploy/agentic-netops; any other image needs the
#       second argument or IMAGE_BUILD_KUSTOMIZATION (a directory holding kustomization.yaml).
#
#   image_build::content_hash <name>   prints the contentHash only (no build)
#   image_build::context_files <name>  prints the hashed file list (context-relative, sorted)
#
# contentHash — "the SHA-256 of the build context's tracked files plus the Dockerfile". The tree is
# not required to be a git checkout, so "tracked" is defined here, deterministically:
#   a file under the entry's `context` directory is tracked unless
#     * a path component is `.git`, `node_modules`, `__pycache__`, `.venv`, `.pytest_cache`,
#       `.ruff_cache` or `.mypy_cache`;
#     * it lies in a nested repository — a directory other than the tree root holding its own
#       `.git` (the upstream reference checkouts config-server/, data-server/, kuid/, sdcio-docs/ are
#       such repositories and are never part of this tree's content);
#     * relative to the tree root it is under bin/, .evidence/, prompts/, .specstride/, .specify/,
#       .mixture-of-loops/, or a containerlab lab directory lab/clab-*/;
#     * a .gitignore pattern matches it — the root .gitignore and any nested .gitignore, each
#       relative to its own directory; `#` comments, `dir/`, leading-`/` anchoring, `*`, `?`, `[…]`
#       and `**` are honoured; negation (`!`) is NOT (the fixed rules above cover the one negated
#       block the repository has);
#     * a .dockerignore pattern at the context root matches it (anchored at the context root, a
#       matched directory excludes everything below it), as docker itself would exclude it.
#   Each tracked file contributes the line `<context-relative path> NUL <x|-> NUL <sha256>` (x = the
#   executable bit; a symlink hashes its target text); the lines are sorted bytewise (LC_ALL=C);
#   then one line `Dockerfile NUL <sha256 of the Dockerfile>` is appended; contentHash is the
#   SHA-256 of the whole. Same tree → same tag; one changed byte → a different tag.
#
# Environment: IMAGE_BUILD_ROOT (tree root; default the repository), IMAGE_BUILD_LOCK (default
# <root>/versions.lock.yaml), IMAGE_BUILD_VERIFY_PINS (the pin check command, called with
# `--root <root> --lock <lock>`; default <repo>/scripts/lib/verify_pins.sh), IMAGE_BUILD_KUSTOMIZATION,
# CLUSTER_NAME, DOCKER / KIND (clients; tests).

[[ -n "${__AGENTIC_NETOPS_IMAGE_BUILD_SH:-}" ]] && return 0
__AGENTIC_NETOPS_IMAGE_BUILD_SH=1

# shellcheck source=log.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/log.sh"
# shellcheck source=evidence.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/evidence.sh"
# shellcheck source=kind.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/kind.sh"

IMAGE_BUILD_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

image_build::_root() { printf '%s' "${IMAGE_BUILD_ROOT:-$IMAGE_BUILD_REPO_ROOT}"; }
image_build::_lock() { printf '%s' "${IMAGE_BUILD_LOCK:-$(image_build::_root)/versions.lock.yaml}"; }
image_build::_docker() { "${DOCKER:-docker}" "$@"; }

# image_build::_entry <name> — the lock entry as compact JSON (exit 1 when absent).
image_build::_entry() {
  local name="$1" lock json
  lock="$(image_build::_lock)"
  [[ -f "$lock" ]] || { log::error "image_build: lock file $lock not found"; return 1; }
  command -v yq >/dev/null 2>&1 || { log::error "image_build: yq is required"; return 1; }
  json="$(IB_NAME="$name" yq -o=json -I=0 '[.firstPartyImages[]? | select(.name == strenv(IB_NAME))] | .[0] // ""' "$lock")" || json=""
  if [[ -z "$json" || "$json" == '""' || "$json" == null ]]; then
    log::error "image_build: '$name' has no firstPartyImages entry in $lock"
    return 1
  fi
  printf '%s' "$json"
}

# image_build::_normalize_repo <ref> — docker.io/library/x form, as the pin check normalizes.
image_build::_normalize_repo() {
  local r="$1" first
  r="${r#index.docker.io/}"
  if [[ "$r" != */* ]]; then printf 'docker.io/library/%s' "$r"; return; fi
  first="${r%%/*}"
  if [[ "$first" != *.* && "$first" != *:* && "$first" != localhost ]]; then
    r="docker.io/$r"
  fi
  printf '%s' "$r"
}

# image_build::_split_ref <image> — prints "<repo>\t<tag>\t<digest>".
image_build::_split_ref() {
  local img="$1" digest="" tag="" last
  if [[ "$img" == *@* ]]; then digest="${img#*@}"; img="${img%%@*}"; fi
  last="${img##*/}"
  if [[ "$last" == *:* ]]; then tag="${last##*:}"; img="${img%:*}"; fi
  printf '%s\t%s\t%s\n' "$img" "$tag" "$digest"
}

# image_build::dockerfile_images <dockerfile> — "<lineno>\t<kind>\t<image>" for every external image.
image_build::dockerfile_images() {
  awk '
    function lower(s) { return tolower(s) }
    { line = $0 }
    cont != "" { line = cont " " line; cont = "" }
    /\\[[:space:]]*$/ { sub(/\\[[:space:]]*$/, "", line); cont = line; if (!start) start = NR; next }
    {
      n = (start ? start : NR); start = 0
      sub(/^[[:space:]]+/, "", line)
      if (line == "" || substr(line, 1, 1) == "#") next
      nt = split(line, t, /[[:space:]]+/)
      if (lower(t[1]) == "from") {
        img = ""; alias = ""; j = 0
        for (i = 2; i <= nt; i++) { if (substr(t[i], 1, 2) == "--") continue; toks[++j] = t[i] }
        if (j == 0) next
        img = toks[1]
        if (j >= 3 && lower(toks[2]) == "as") alias = lower(toks[3])
        if (!(lower(img) in stages) && lower(img) != "scratch") print n "\tFROM\t" img
        if (alias != "") stages[alias] = 1
        delete toks
      } else if (lower(t[1]) == "copy" || lower(t[1]) == "add") {
        for (i = 2; i <= nt; i++) if (substr(t[i], 1, 7) == "--from=") {
          src = substr(t[i], 8)
          if (!(lower(src) in stages) && src !~ /^[0-9]+$/) print n "\tCOPY --from\t" src
        }
      }
    }' "$1"
}

# image_build::check_froms <name> — refuses (naming the line) any FROM not equal to the lock.
image_build::check_froms() {
  local name="$1" entry root df
  entry="$(image_build::_entry "$name")" || return 1
  root="$(image_build::_root)"
  df="$root/$(jq -r '.dockerfile // ""' <<<"$entry")"
  if [[ ! -f "$df" ]]; then
    log::error "image_build: $name is pending — its Dockerfile $(jq -r '.dockerfile // "<unset>"' <<<"$entry") is absent (AD-71): nothing to build"
    return 1
  fi
  local -a found=()
  mapfile -t found < <(image_build::dockerfile_images "$df")
  local nlock rc=0 i ln kind img repo tag digest want_ref want_tag want_track want_digest where
  nlock="$(jq '.from | length' <<<"$entry")"
  if [[ "${#found[@]}" -ne "$nlock" ]]; then
    log::error "image_build: $df has ${#found[@]} external image(s), the lock pins $nlock for $name"
    rc=1
  fi
  for i in "${!found[@]}"; do
    IFS=$'\t' read -r ln kind img <<<"${found[$i]}"
    where="${df#"$root"/}:$ln"
    if [[ "$img" == *'$'* ]]; then
      log::error "image_build: $kind at $where uses a build argument ($img) — every FROM is <ref>@sha256:<digest>"
      rc=1; continue
    fi
    IFS=$'\t' read -r repo tag digest < <(image_build::_split_ref "$img")
    if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      log::error "image_build: refusing tag-only $kind at $where: '$img' is not pinned by digest (<ref>@sha256:<digest>, NFR-003)"
      rc=1; continue
    fi
    (( i < nlock )) || continue
    want_ref="$(jq -r --argjson i "$i" '.from[$i].ref // ""' <<<"$entry")"
    want_tag="$(jq -r --argjson i "$i" '.from[$i].tag // ""' <<<"$entry")"
    want_track="$(jq -r --argjson i "$i" '.from[$i].track // ""' <<<"$entry")"
    want_digest="$(jq -r --argjson i "$i" '.from[$i].digest // ""' <<<"$entry")"
    if [[ "$(image_build::_normalize_repo "$repo")" != "$(image_build::_normalize_repo "$want_ref")" ]]; then
      log::error "image_build: $where names $repo, the lock pins $want_ref for $name from[$i]"
      rc=1
    fi
    if [[ -n "$tag" && "$tag" != "$want_tag" && ( -z "$want_track" || "$tag" != "$want_track" ) ]]; then
      log::error "image_build: $where tag $tag differs from the lock's $want_tag for $name from[$i]"
      rc=1
    fi
    if [[ "$digest" != "$want_digest" ]]; then
      log::error "image_build: $where digest $digest differs from the lock's ${want_digest:-<empty>} for $name from[$i]"
      rc=1
    fi
  done
  return "$rc"
}

# image_build::verify_pins <name> — the pin check, scoped to this image; fails closed.
image_build::verify_pins() {
  local name="$1" cmd out rc=0 mine
  cmd="${IMAGE_BUILD_VERIFY_PINS:-$IMAGE_BUILD_REPO_ROOT/scripts/lib/verify_pins.sh}"
  out="$("$cmd" --root "$(image_build::_root)" --lock "$(image_build::_lock)" 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    log::info "image_build: verify-pins passed"
    return 0
  fi
  mine="$(grep -F "firstPartyImages[$name]" <<<"$out" | grep -E '(^|[[:space:]])FAIL' || true)"
  if [[ -n "$mine" ]]; then
    log::error "image_build: refusing to build $name: verify-pins fails for it:"
    printf '%s\n' "$mine" | sed 's/^/    | /' >&2
    return 1
  fi
  if [[ "$rc" -ne 1 ]]; then
    log::error "image_build: refusing to build $name: verify-pins could not run (exit $rc) — the pins are unverified:"
    printf '%s\n' "$out" | tail -n 10 | sed 's/^/    | /' >&2
    return 1
  fi
  log::warn "image_build: verify-pins reports failures, none of them for $name (build proceeds; fix them before acceptance)"
}

# image_build::_list <root> <context-abs> — NUL-separated context-relative paths of tracked files.
image_build::_list() {
  python3 - "$1" "$2" <<'PY'
import os, re, sys

root = os.path.realpath(sys.argv[1])
ctx = os.path.realpath(sys.argv[2])
ALWAYS_NAMES = {".git", "node_modules", "__pycache__", ".venv", ".pytest_cache", ".ruff_cache", ".mypy_cache"}
ROOT_REL = ["bin", ".evidence", "prompts", ".specstride", ".specify", ".mixture-of-loops", "lab/clab-*"]

def glob_re(p):
    i, out = 0, ""
    while i < len(p):
        c = p[i]
        if p.startswith("**/", i):
            out += "(?:.*/)?"; i += 3; continue
        if p.startswith("/**", i) and i + 3 == len(p):
            out += "(?:/.*)?"; i += 3; continue
        if p.startswith("**", i):
            out += ".*"; i += 2; continue
        if c == "*":
            out += "[^/]*"
        elif c == "?":
            out += "[^/]"
        elif c == "[":
            j = p.find("]", i + 1)
            if j == -1:
                out += re.escape(c)
            else:
                cls = p[i + 1:j].replace("\\", "\\\\")
                if cls.startswith("!"):
                    cls = "^" + cls[1:]
                out += "[" + cls + "]"; i = j
        else:
            out += re.escape(c)
        i += 1
    return re.compile(out + r"\Z")

def parse_ignore(path, docker=False):
    rules = []
    try:
        with open(path, errors="replace") as f:
            for raw in f:
                line = raw.rstrip("\n").rstrip("\r")
                if docker:
                    line = line.strip()
                elif not line.endswith("\\ "):
                    line = line.rstrip()
                if not line or line.startswith("#") or line.startswith("!"):
                    continue
                dir_only = line.endswith("/")
                line = line.rstrip("/")
                if docker:
                    line = os.path.normpath(line.lstrip("/"))
                    if line in (".", ""):
                        continue
                    anchored = True
                else:
                    anchored = "/" in line.lstrip("/") or line.startswith("/")
                    line = line.lstrip("/")
                rules.append((glob_re(line), anchored, dir_only))
    except OSError:
        pass
    return rules

def ignored(rel, is_dir, rules):
    base = rel.rsplit("/", 1)[-1]
    for rx, anchored, dir_only in rules:
        if dir_only and not is_dir:
            continue
        if rx.match(rel if anchored else base):
            return True
    return False

root_rules = [glob_re(p) for p in ROOT_REL]
docker_rules = parse_ignore(os.path.join(ctx, ".dockerignore"), docker=True)
out = []
# ignore stack: (dir-abs, rules) for every .gitignore from the tree root down to the context
stack = []
if ctx == root or ctx.startswith(root + os.sep):
    d = root
    parts = [] if ctx == root else os.path.relpath(ctx, root).split(os.sep)
    stack.append((root, parse_ignore(os.path.join(root, ".gitignore"))))
    for p in parts:
        d = os.path.join(d, p)
        stack.append((d, parse_ignore(os.path.join(d, ".gitignore"))))
else:
    stack.append((ctx, parse_ignore(os.path.join(ctx, ".gitignore"))))

def excluded(abs_path, is_dir, gstack):
    name = os.path.basename(abs_path)
    if name in ALWAYS_NAMES:
        return True
    if abs_path == root or abs_path.startswith(root + os.sep):
        rrel = os.path.relpath(abs_path, root).replace(os.sep, "/")
        if any(rx.match(rrel) or any(rx.match("/".join(rrel.split("/")[:k])) for k in range(1, rrel.count("/") + 1)) for rx in root_rules):
            return True
    for d, rules in gstack:
        rel = os.path.relpath(abs_path, d).replace(os.sep, "/")
        if ignored(rel, is_dir, rules):
            return True
    crel = os.path.relpath(abs_path, ctx).replace(os.sep, "/")
    if crel != "." and ignored(crel, is_dir, docker_rules):
        return True
    return False

def walk(d, gstack):
    try:
        entries = sorted(os.listdir(d))
    except OSError:
        return
    for e in entries:
        a = os.path.join(d, e)
        is_dir = os.path.isdir(a) and not os.path.islink(a)
        if excluded(a, is_dir, gstack):
            continue
        if is_dir:
            if os.path.exists(os.path.join(a, ".git")):
                continue          # a nested repository is not this tree's content
            walk(a, gstack + [(a, parse_ignore(os.path.join(a, ".gitignore")))])
        elif os.path.isfile(a) or os.path.islink(a):
            out.append(os.path.relpath(a, ctx).replace(os.sep, "/"))

walk(ctx, stack)
for p in sorted(set(out), key=lambda s: s.encode()):
    sys.stdout.write(p + "\0")
PY
}

# image_build::_paths <name> — prints "<root>\t<context-abs>\t<dockerfile-abs>".
image_build::_paths() {
  local name="$1" entry root ctx df
  entry="$(image_build::_entry "$name")" || return 1
  root="$(image_build::_root)"
  ctx="$root/$(jq -r '.context // "."' <<<"$entry")"
  df="$root/$(jq -r '.dockerfile // ""' <<<"$entry")"
  [[ -d "$ctx" ]] || { log::error "image_build: build context $ctx does not exist"; return 1; }
  [[ -f "$df" ]] || { log::error "image_build: Dockerfile $df does not exist ($name is pending)"; return 1; }
  printf '%s\t%s\t%s\n' "$root" "$(cd "$ctx" && pwd)" "$df"
}

image_build::context_files() {
  local root ctx df
  IFS=$'\t' read -r root ctx df < <(image_build::_paths "$1") || return 1
  [[ -n "$ctx" ]] || return 1
  image_build::_list "$root" "$ctx" | tr '\0' '\n'
}

image_build::content_hash() {
  local root ctx df
  IFS=$'\t' read -r root ctx df < <(image_build::_paths "$1") || return 1
  [[ -n "$ctx" ]] || return 1
  (
    cd "$ctx" || exit 1
    local f sum x
    while IFS= read -r -d '' f; do
      if [[ -L "$f" ]]; then
        sum="$(printf 'symlink:%s' "$(readlink "$f")" | sha256sum | cut -d' ' -f1)"; x="l"
      else
        sum="$(sha256sum -- "$f" | cut -d' ' -f1)"
        if [[ -x "$f" ]]; then x="x"; else x="-"; fi
      fi
      printf '%s\0%s\0%s\n' "$f" "$x" "$sum"
    done < <(image_build::_list "$root" "$ctx")
    printf 'Dockerfile\0%s\n' "$(sha256sum -- "$df" | cut -d' ' -f1)"
  ) | LC_ALL=C sha256sum | cut -d' ' -f1
}

# image_build::_kustomization <name> [dir] — the kustomization.yaml the tag is written into.
image_build::_kustomization() {
  local name="$1" dir="${2:-${IMAGE_BUILD_KUSTOMIZATION:-}}"
  if [[ -z "$dir" ]]; then
    case "$name" in
      srl-provider) dir="deploy/agentic-netops" ;;
      *) log::error "image_build: no kustomization is known for $name: pass it as the second argument or set IMAGE_BUILD_KUSTOMIZATION"; return 1 ;;
    esac
  fi
  [[ "$dir" == /* ]] || dir="$(image_build::_root)/$dir"
  [[ -f "$dir/kustomization.yaml" ]] || { log::error "image_build: $dir/kustomization.yaml not found"; return 1; }
  printf '%s' "$dir/kustomization.yaml"
}

# image_build::set_image <kustomization.yaml> <name> <tag> — only the images: stanza changes.
image_build::set_image() {
  local k="$1" name="$2" tag="$3" n
  n="$(IB_NAME="$name" yq '[.images[]? | select(.name == strenv(IB_NAME))] | length' "$k")" || return 1
  if [[ "$n" -gt 0 ]]; then
    IB_NAME="$name" IB_TAG="$tag" yq -i '(.images[] | select(.name == strenv(IB_NAME))).newTag = strenv(IB_TAG)' "$k"
  else
    IB_NAME="$name" IB_TAG="$tag" yq -i '.images += [{"name": strenv(IB_NAME), "newTag": strenv(IB_TAG)}]' "$k"
  fi
}

image_build::build() {
  if [[ $# -lt 1 || $# -gt 2 ]]; then log::error "usage: image_build::build <name> [kustomization-dir]"; return 2; fi
  local name="$1" kdir="${2:-}" root ctx df hash tag k
  image_build::check_froms "$name" || { log::error "image_build: refusing to build $name: its FROM lines do not equal the lock (NFR-003)"; return 1; }
  image_build::verify_pins "$name" || return 1
  k="$(image_build::_kustomization "$name" "$kdir")" || return 1
  IFS=$'\t' read -r root ctx df < <(image_build::_paths "$name") || return 1
  hash="$(image_build::content_hash "$name")" || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || { log::error "image_build: content hash computation failed"; return 1; }
  tag="${name}:${hash}"

  if image_build::_docker image inspect "$tag" >/dev/null 2>&1; then
    log::info "image_build: $tag already built (same content): not rebuilt"
  else
    local stage
    stage="$(mktemp -d)"
    if ! ( cd "$ctx" && image_build::_list "$root" "$ctx" | tar --null -T - -cf - ) | tar -C "$stage" -xf -; then
      rm -rf "$stage"; log::error "image_build: staging the build context failed"; return 1
    fi
    log::info "image_build: building $tag from $(image_build::_list "$root" "$ctx" | tr -cd '\0' | wc -c) tracked file(s)"
    if ! image_build::_docker build -f "$df" -t "$tag" \
        --label "agentic-netops.io/image=$name" --label "agentic-netops.io/content-hash=$hash" "$stage" >&2; then
      rm -rf "$stage"; log::error "image_build: docker build of $tag failed"; return 1
    fi
    rm -rf "$stage"
  fi
  kind::load_image "${CLUSTER_NAME:-agentic-netops}" "$tag" \
    || { log::error "image_build: kind load of $tag into ${CLUSTER_NAME:-agentic-netops} failed"; return 1; }
  image_build::set_image "$k" "$name" "$hash" || { log::error "image_build: writing the tag into $k failed"; return 1; }
  log::info "image_build: ${k#"$root"/} images: $name newTag $hash"

  evidence::ensure_dir || return 1
  local id="image-build.${name}.${hash:0:12}" n=1 base
  base="$id"
  while [[ -e "$EVIDENCE_DIR/$id.json" ]]; do n=$((n + 1)); id="${base}-${n}"; done
  evidence_run "$id" -- "${DOCKER:-docker}" image inspect --format '{{.Id}}' "$tag" >/dev/null \
    || { log::error "image_build: recording the image ID of $tag failed"; return 1; }
  printf '%s\n' "$tag"
}
