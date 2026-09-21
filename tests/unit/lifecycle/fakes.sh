#!/usr/bin/env bash
# fakes.sh — stateful fake docker / kind / containerlab / kubectl for the offline lifecycle suites
# (T029, T037, T034 unit tests). Not a suite itself (no _test.sh suffix): sourced by them.
#
#   fakes::install <dir>   writes the four fakes into <dir>/bin and initialises the state
#                          <dir>/state; prepend <dir>/bin to PATH and export FAKE_STATE=<dir>/state.
#   fakes::calls           the recorded call log (one "<tool> <args…>" line per call)
#   fakes::network <name> <cidr> [label-value|-]      plant a docker network ('-' = unlabelled)
#   fakes::container <name> <lab> <kind> [label-value|-] plant a lab container
#   fakes::cluster <name> [label-value|-]             plant a Kind cluster (control-plane node label)
#   fakes::k8s <cluster> <ns|_> <kind> <name> [label-value|-] [json-extra]   plant an object
#   fakes::image <tag>                                plant a local image
#   fakes::image_file <tag>                           its state file (tags contain '/', stored as %2F)
#
# State is plain files, so a suite can assert on it directly:
#   state/docker/networks/<name>.json, state/docker/containers/<name>.json, state/docker/images/<tag with / as %2F>
#   state/kind/<cluster>, state/k8s/<cluster>/<namespace|_>/<kind>/<name>.json

FAKES_OWNER_KEY="agentic-netops.io/owned-by"

fakes::install() {
  local d="$1"
  mkdir -p "$d/bin" "$d/state/docker/networks" "$d/state/docker/containers" "$d/state/docker/images" \
    "$d/state/kind" "$d/state/k8s"
  : >"$d/state/calls.log"

  cat >"$d/bin/docker" <<'EOF'
#!/usr/bin/env bash
S="$FAKE_STATE/docker"
printf 'docker %s\n' "$*" >>"$FAKE_STATE/calls.log"
[[ -n "${FAKE_DOCKER_FAIL:-}" && "$*" == *"$FAKE_DOCKER_FAIL"* ]] && { echo "fake docker: forced failure" >&2; exit 1; }
labels_match() { # <json-file> <filters…>
  local f="$1"; shift
  local flt k v
  for flt in "$@"; do
    k="${flt%%=*}"; v="${flt#*=}"
    [[ "$flt" == *=* ]] || v=""
    jq -e --arg k "$k" --arg v "$v" --arg has "$([[ "$flt" == *=* ]] && echo 1)" \
      '((.Labels // .Config.Labels // {}) + (.Config.Labels // {})) as $l | if $has == "1" then $l[$k] == $v else ($l | has($k)) end' \
      "$f" >/dev/null || return 1
  done
}
case "$1" in
  network)
    sub="$2"; shift 2
    case "$sub" in
      ls) for f in "$S"/networks/*.json; do [[ -f "$f" ]] && jq -r '.Id' "$f"; done; exit 0 ;;
      inspect)
        files=()
        for n in "$@"; do
          [[ "$n" == -* ]] && continue
          f="$S/networks/$n.json"
          [[ -f "$f" ]] || { g="$(grep -l "\"Id\": *\"$n\"" "$S"/networks/*.json 2>/dev/null | head -1)"; f="${g:-$f}"; }
          [[ -f "$f" ]] || { echo "Error: No such network: $n" >&2; exit 1; }
          files+=("$f")
        done
        jq -s '.' "${files[@]}" ;;
      create)
        subnet="" labels="{}" name=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --subnet) subnet="$2"; shift 2 ;;
            --label) labels="$(jq -c --arg k "${2%%=*}" --arg v "${2#*=}" '. + {($k): $v}' <<<"$labels")"; shift 2 ;;
            --gateway|--ip-range|--driver|-d|-o|--opt) shift 2 ;;
            -*) shift ;;
            *) name="$1"; shift ;;
          esac
        done
        [[ -f "$S/networks/$name.json" ]] && { echo "Error: network with name $name already exists" >&2; exit 1; }
        jq -n --arg n "$name" --arg s "$subnet" --argjson l "$labels" \
          '{Name: $n, Id: ($n + "000000000000"), Labels: $l, IPAM: {Config: [{Subnet: $s}]}, Containers: {}}' \
          >"$S/networks/$name.json" ;;
      rm)
        f="$S/networks/$1.json"
        [[ -f "$f" ]] || { echo "Error: No such network: $1" >&2; exit 1; }
        [[ "$(jq '.Containers | length' "$f")" == 0 ]] || { echo "Error: network $1 has active endpoints" >&2; exit 1; }
        rm -f "$f" ;;
      connect)
        net="$1" ctr="$2" nf="$S/networks/$1.json" cf="$S/containers/$2.json"
        [[ -f "$nf" && -f "$cf" ]] || { echo "Error: no such network or container" >&2; exit 1; }
        jq --arg c "$ctr" '.Containers[$c] = {Name: $c}' "$nf" >"$nf.t" && mv "$nf.t" "$nf"
        jq --arg n "$net" '.NetworkSettings.Networks[$n] = {}' "$cf" >"$cf.t" && mv "$cf.t" "$cf" ;;
      *) exit 0 ;;
    esac ;;
  container|inspect)
    [[ "$1" == container ]] && shift
    shift
    files=()
    for n in "$@"; do
      [[ "$n" == -* ]] && continue
      f="$S/containers/$n.json"
      [[ -f "$f" ]] || { echo "Error: No such container: $n" >&2; exit 1; }
      files+=("$f")
    done
    jq -s '.' "${files[@]}" ;;
  exec)
    # docker exec [-i] <node> cat /etc/resolv.conf | sh -c 'cat > /etc/resolv.conf' — the node's
    # resolv.conf is state/docker/resolv/<node> (default: a host search domain, as observed).
    shift; [[ "$1" == -i ]] && shift
    node="$1"; shift
    mkdir -p "$S/resolv"; rf="$S/resolv/$node"
    [[ -f "$rf" ]] || printf 'search ai\nnameserver 172.30.0.1\noptions ndots:0\n' >"$rf"
    case "$*" in
      "cat /etc/resolv.conf") cat "$rf" ;;
      "sh -c cat > /etc/resolv.conf") cat >"$rf" ;;
      *) exit 0 ;;
    esac ;;
  ps)
    shift
    filters=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --filter) [[ "$2" == label=* ]] && filters+=("${2#label=}"); shift 2 ;;
        --format) shift 2 ;;
        *) shift ;;
      esac
    done
    for f in "$S"/containers/*.json; do
      [[ -f "$f" ]] || continue
      labels_match "$f" "${filters[@]}" && jq -r '.Name' "$f"
    done
    exit 0 ;;
  image)
    case "$2" in
      inspect)
        tag="${*: -1}"
        [[ -f "$S/images/${tag//\//%2F}" ]] || { echo "Error: No such image: $tag" >&2; exit 1; }
        cat "$S/images/${tag//\//%2F}" ;;
      *) exit 0 ;;
    esac ;;
  build)
    tag="" ctx="" dockerfile=""
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t|--tag) tag="$2"; shift 2 ;;
        -f|--file) dockerfile="$2"; shift 2 ;;
        --label|--build-arg|--platform|--progress) shift 2 ;;
        -*) shift ;;
        *) ctx="$1"; shift ;;
      esac
    done
    [[ -n "$tag" && -d "$ctx" && -f "$dockerfile" ]] || { echo "fake docker build: need -t, -f and a context dir" >&2; exit 1; }
    # record what the build saw: the context listing
    (cd "$ctx" && find . -type f | LC_ALL=C sort) >"$FAKE_STATE/last_build_context"
    printf 'sha256:%s\n' "$(printf '%s' "$tag" | sha256sum | cut -c1-64)" >"$S/images/${tag//\//%2F}" ;;
  *) exit 0 ;;
esac
EOF

  cat >"$d/bin/kind" <<'EOF'
#!/usr/bin/env bash
printf 'kind %s\n' "$*" >>"$FAKE_STATE/calls.log"
name=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[i]}" == --name ]] && name="${args[i+1]}"; done
case "$1 ${2:-}" in
  "version ") echo "kind v0.27.0 go1.23.6 linux/amd64" ;;
  "get clusters") ls "$FAKE_STATE/kind" 2>/dev/null; exit 0 ;;
  "get nodes") [[ -f "$FAKE_STATE/kind/$name" ]] && echo "${name}-control-plane"; exit 0 ;;
  "create cluster")
    cfg=""; for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[i]}" == --config ]] && cfg="${args[i+1]}"; done
    [[ -f "$FAKE_STATE/kind/$name" ]] && { echo "ERROR: node(s) already exist for a cluster with the name \"$name\"" >&2; exit 1; }
    label="$(awk -F': *' '/agentic-netops.io\/owned-by:/ {print $2; exit}' "$cfg")"
    [[ -n "${FAKE_KIND_CONFIG_COPY:-}" ]] && cp "$cfg" "$FAKE_KIND_CONFIG_COPY"
    touch "$FAKE_STATE/kind/$name"
    k="$FAKE_STATE/k8s/$name"
    mkdir -p "$k/_/node" "$k/_/namespace"
    jq -n --arg n "${name}-control-plane" --arg v "$label" \
      '{apiVersion: "v1", kind: "Node", metadata: {name: $n, labels: {"node-role.kubernetes.io/control-plane": "", "agentic-netops.io/owned-by": $v}}}' \
      >"$k/_/node/${name}-control-plane.json"
    for ns in kube-system default; do
      jq -n --arg n "$ns" '{apiVersion: "v1", kind: "Namespace", metadata: {name: $n, labels: {}}}' >"$k/_/namespace/$ns.json"
    done
    jq -n --arg n "${name}-control-plane" --arg c "$name" \
      '{Name: $n, Config: {Labels: {"io.x-k8s.kind.cluster": $c}}, State: {Running: true}, NetworkSettings: {Networks: {kind: {}}}}' \
      >"$FAKE_STATE/docker/containers/${name}-control-plane.json" ;;
  "delete cluster")
    rm -f "$FAKE_STATE/kind/$name"; rm -rf "$FAKE_STATE/k8s/$name"
    for f in "$FAKE_STATE"/docker/networks/*.json; do
      [[ -f "$f" ]] && jq --arg c "${name}-control-plane" 'del(.Containers[$c])' "$f" >"$f.t" && mv "$f.t" "$f"
    done
    rm -f "$FAKE_STATE/docker/containers/${name}-control-plane.json" ;;
  "load docker-image")
    [[ -f "$FAKE_STATE/kind/$name" ]] || { echo "ERROR: no nodes found for cluster \"$name\"" >&2; exit 1; }
    [[ -f "$FAKE_STATE/docker/images/${3//\//%2F}" ]] || { echo "ERROR: image: \"$3\" not present locally" >&2; exit 1; } ;;
  *) exit 0 ;;
esac
EOF

  cat >"$d/bin/containerlab" <<'EOF'
#!/usr/bin/env bash
printf 'containerlab %s\n' "$*" >>"$FAKE_STATE/calls.log"
topo=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[i]}" == -t || "${args[i]}" == --topo ]] && topo="${args[i+1]}"; done
lab="$(awk '/^name:/ {print $2; exit}' "$topo" 2>/dev/null)"
labdir="${CLAB_LABDIR_BASE:-$(dirname "$topo")}/clab-$lab"
C="$FAKE_STATE/docker/containers"
case "$1" in
  version) printf '    version: 0.79.0\n' ;;
  deploy)
    prefix="${CLAB_MGMT_PREFIX:-172.25.25}"
    for spec in spine01:nokia_srlinux:11 spine02:nokia_srlinux:12 leaf01:nokia_srlinux:21 leaf02:nokia_srlinux:22 client01:linux:31 client02:linux:32; do
      IFS=: read -r node kind host <<<"$spec"
      n="clab-$lab-$node"
      jq -n --arg n "$n" --arg lab "$lab" --arg kind "$kind" --arg owner "${CLUSTER_NAME:-agentic-netops}" \
        --arg ip "$prefix.$host" \
        '{Name: $n, Config: {Labels: {containerlab: $lab, "clab-node-kind": $kind, "agentic-netops.io/owned-by": $owner}},
          State: {Running: true}, NetworkSettings: {Networks: {"agentic-netops-mgmt": {IPAddress: $ip}}}}' >"$C/$n.json"
    done
    mkdir -p "$labdir/.tls/ca"
    [[ -f "$labdir/.tls/ca/ca.pem" ]] || printf -- '-----BEGIN CERTIFICATE-----\nZmFrZSBjYQ==\n-----END CERTIFICATE-----\n' >"$labdir/.tls/ca/ca.pem" ;;
  destroy)
    for f in "$C"/*.json; do
      [[ -f "$f" ]] || continue
      [[ "$(jq -r '.Config.Labels.containerlab // ""' "$f")" == "$lab" ]] && rm -f "$f"
    done
    [[ " $* " == *" --cleanup "* ]] && rm -rf "$labdir" ;;
  *) exit 0 ;;
esac
EOF

  cat >"$d/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$FAKE_STATE/calls.log"
ctx="" ns="" sel="" out="" verb="" ignore_nf=false
pos=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) ctx="$2"; shift 2 ;;
    --context=*) ctx="${1#*=}"; shift ;;
    -n|--namespace) ns="$2"; shift 2 ;;
    -l|--selector) sel="$2"; shift 2 ;;
    -o|--output) out="$2"; shift 2 ;;
    -o*) out="${1#-o}"; out="${out#=}"; shift ;;
    --ignore-not-found|--ignore-not-found=true) ignore_nf=true; shift ;;
    -f) shift 2 ;;
    --request-timeout|--field-manager) shift 2 ;;
    -*) shift ;;
    *) pos+=("$1"); shift ;;
  esac
done
verb="${pos[0]:-}"
if [[ "$verb" == config ]]; then
  case "${pos[1]:-}" in
    current-context) [[ -n "${FAKE_CURRENT_CONTEXT:-}" ]] && echo "$FAKE_CURRENT_CONTEXT" || exit 1 ;;
  esac
  exit 0
fi
cluster="${ctx#kind-}"
K="$FAKE_STATE/k8s/$cluster"
[[ -n "$cluster" && -d "$K" ]] || { echo "error: context \"$ctx\" does not exist or the cluster is unreachable" >&2; exit 1; }
norm() {
  case "$1" in
    ns|namespace|namespaces) echo namespace ;; secret|secrets) echo secret ;; node|nodes) echo node ;;
    sts|statefulset|statefulsets|statefulset.apps) echo statefulset ;;
    deploy|deployment|deployments|deployment.apps) echo deployment ;; *) echo "$1" ;;
  esac
}
scope() { case "$1" in namespace|node) echo _ ;; *) echo "${ns:-default}" ;; esac; }
sel_match() { # <file>
  [[ -z "$sel" ]] && return 0
  local IFS=, s
  for s in $sel; do
    if [[ "$s" == *=* ]]; then
      jq -e --arg k "${s%%=*}" --arg v "${s#*=}" '(.metadata.labels // {})[$k] == $v' "$1" >/dev/null || return 1
    else
      jq -e --arg k "$s" '(.metadata.labels // {}) | has($k)' "$1" >/dev/null || return 1
    fi
  done
}
case "$verb" in
  get)
    kind="$(norm "${pos[1]}")" name="${pos[2]:-}" dir="$K/$(scope "$(norm "${pos[1]}")")/$kind"
    if [[ -n "$name" ]]; then
      f="$dir/$name.json"
      [[ -f "$f" ]] || { echo "Error from server (NotFound): $kind \"$name\" not found" >&2; exit 1; }
      case "$out" in
        json) cat "$f" ;;
        name) echo "$kind/$name" ;;
        jsonpath=*metadata.uid*) echo "uid-$cluster-$name" ;;
        *) echo "$name" ;;
      esac
    else
      for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        sel_match "$f" || continue
        case "$out" in name) echo "$kind/$(basename "$f" .json)" ;; *) basename "$f" .json ;; esac
      done
    fi ;;
  apply)
    obj="$(cat)"
    kind="$(jq -r '.kind | ascii_downcase' <<<"$obj")" name="$(jq -r '.metadata.name' <<<"$obj")"
    ons="$(jq -r '.metadata.namespace // "default"' <<<"$obj")"
    [[ "$kind" == namespace ]] && ons=_
    if [[ "$ons" != _ && ! -f "$K/_/namespace/$ons.json" ]]; then
      echo "Error from server (NotFound): namespaces \"$ons\" not found" >&2; exit 1
    fi
    mkdir -p "$K/$ons/$kind"
    printf '%s\n' "$obj" >"$K/$ons/$kind/$name.json"
    echo "$kind/$name serverside-applied" ;;
  delete)
    kind="$(norm "${pos[1]}")" name="${pos[2]}" dir="$K/$(scope "$kind")/$kind"
    if [[ ! -f "$dir/$name.json" ]]; then
      $ignore_nf && exit 0
      echo "Error from server (NotFound): $kind \"$name\" not found" >&2; exit 1
    fi
    rm -f "$dir/$name.json"
    [[ "$kind" == namespace ]] && rm -rf "${K:?}/$name"
    echo "$kind \"$name\" deleted" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$d/bin"/*
}

fakes::calls() { cat "$FAKE_STATE/calls.log"; }

fakes::_label_json() { # <value|-> → labels JSON object with the owner key (or none)
  if [[ "${1:--}" == "-" ]]; then echo '{}'; else jq -cn --arg k "$FAKES_OWNER_KEY" --arg v "$1" '{($k): $v}'; fi
}

fakes::network() {
  jq -n --arg n "$1" --arg s "$2" --argjson l "$(fakes::_label_json "${3:--}")" \
    '{Name: $n, Id: ($n + "000000000000"), Labels: $l, IPAM: {Config: [{Subnet: $s}]}, Containers: {}}' \
    >"$FAKE_STATE/docker/networks/$1.json"
}

fakes::container() {
  jq -n --arg n "$1" --arg lab "$2" --arg kind "$3" --argjson l "$(fakes::_label_json "${4:--}")" \
    '{Name: $n, Config: {Labels: ({containerlab: $lab, "clab-node-kind": $kind} + $l)}, State: {Running: true}, NetworkSettings: {Networks: {}}}' \
    >"$FAKE_STATE/docker/containers/$1.json"
}

fakes::cluster() {
  local name="$1" v="${2:--}" k="$FAKE_STATE/k8s/$1"
  touch "$FAKE_STATE/kind/$name"
  mkdir -p "$k/_/node" "$k/_/namespace"
  jq -n --arg n "${name}-control-plane" --argjson l "$(fakes::_label_json "$v")" \
    '{apiVersion: "v1", kind: "Node", metadata: {name: $n, labels: ({"node-role.kubernetes.io/control-plane": ""} + $l)}}' \
    >"$k/_/node/${name}-control-plane.json"
  local ns
  for ns in kube-system default; do
    jq -n --arg n "$ns" '{apiVersion: "v1", kind: "Namespace", metadata: {name: $n, labels: {}}}' >"$k/_/namespace/$ns.json"
  done
  jq -n --arg n "${name}-control-plane" --arg c "$name" \
    '{Name: $n, Config: {Labels: {"io.x-k8s.kind.cluster": $c}}, State: {Running: true}, NetworkSettings: {Networks: {}}}' \
    >"$FAKE_STATE/docker/containers/${name}-control-plane.json"
}

fakes::k8s() {
  local cluster="$1" ns="$2" kind="$3" name="$4" v="${5:--}" extra="${6:-{\}}"
  local d="$FAKE_STATE/k8s/$cluster/$ns/$kind"
  mkdir -p "$d"
  local kindname
  case "$kind" in namespace) kindname=Namespace ;; secret) kindname=Secret ;; statefulset) kindname=StatefulSet ;; *) kindname="$kind" ;; esac
  jq -n --arg k "$kindname" --arg n "$name" --arg ns "$ns" --argjson l "$(fakes::_label_json "$v")" --argjson x "$extra" \
    '{apiVersion: "v1", kind: $k, metadata: ({name: $n, labels: $l} + (if $ns == "_" then {} else {namespace: $ns} end))} + $x' \
    >"$d/$name.json"
}

fakes::image() {
  printf 'sha256:%s\n' "$(printf '%s' "$1" | sha256sum | cut -c1-64)" >"$FAKE_STATE/docker/images/${1//\//%2F}"
}
fakes::image_file() { printf '%s' "$FAKE_STATE/docker/images/${1//\//%2F}"; }
